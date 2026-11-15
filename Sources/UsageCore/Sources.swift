import CryptoKit
import Foundation

public protocol UsageSource: Sendable {
    func fetch() async throws -> UsageReport
}

/// `~/x` → absolute path; an empty string gives nil (default directory).
func expandedDir(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
    return (path as NSString).expandingTildeInPath
}

// MARK: Claude Code

/// The token comes from the Keychain through `/usr/bin/security`: it is already in the ACL of the item
/// Claude Code creates, so no access prompt appears.
/// We never refresh the token: the refresh token is single-use, and refreshing behind
/// the CLI's back would log it out. If it expired, we ask the user to run claude.
public struct ClaudeSource: UsageSource {
    let configDir: String?
    public init(configDir: String? = nil) { self.configDir = expandedDir(configDir) }

    /// Keychain item name, built the way Claude Code (2.1.x) does: with CLAUDE_CONFIG_DIR set,
    /// the first 8 hex characters of sha256 of the NFC path are appended to the name.
    static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Name variants: the path as entered and without a trailing "/". Whether Claude Code normalizes the path
    /// itself cannot be told from the minified binary, so we try both.
    static func keychainServices(configDir: String?) -> [String] {
        guard let configDir else { return [keychainService(configDir: nil)] }
        let names = [configDir, (configDir as NSString).standardizingPath].map { keychainService(configDir: $0) }
        return names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public func fetch() async throws -> UsageReport {
        var found: Data?
        for service in Self.keychainServices(configDir: configDir) {
            // No item: security exits with code 44; not an error, try the next variant.
            if let data = try? await ProcessRunner.run(
                "/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 5) {
                found = data
                break
            }
        }
        guard let raw = found else {
            throw UsageError.message(configDir == nil ? L("not signed in to Claude Code")
                                                      : L("not signed in to Claude Code for this directory"))
        }
        guard let creds = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let token = creds["accessToken"] as? String
        else { throw UsageError.message(L("not signed in to Claude Code")) }

        if let expiresMs = Parsers.number(creds["expiresAt"]), Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
            throw UsageError.message(L("token expired, run claude"))
        }

        let data = try await HTTP.get("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ], errors: [401: L("token expired, run claude")], timeout: 5)
        let plan = Parsers.claudePlan(subscription: creds["subscriptionType"] as? String,
                                      tier: creds["rateLimitTier"] as? String)
        return try Parsers.claude(data, plan: plan)
    }
}

/// GET with common errors. `errors` holds custom texts per status code (401: what the user should do).
enum HTTP {
    /// Ephemeral: no disk cache and no cookies, less memory, nothing left on disk.
    static let session = URLSession(configuration: .ephemeral)

    static func get(_ url: String, headers: [String: String], errors: [Int: String] = [:],
                    timeout: TimeInterval = 10) async throws -> Data {
        let (data, status) = try await request(url, headers: headers, timeout: timeout)
        return try check(data, status, errors)
    }

    /// `body` makes it a POST.
    static func request(_ url: String, headers: [String: String], body: Data? = nil,
                        timeout: TimeInterval = 10) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.setValue("usage-widget/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func check(_ data: Data, _ status: Int, _ errors: [Int: String]) throws -> Data {
        if status == 200 { return data }
        if let text = errors[status] { throw UsageError.message(text) }
        throw UsageError.message(status == 429 ? L("API: too many requests (429)") : "API: HTTP \(status)")
    }
}

// MARK: GitHub Copilot

/// The token comes from the GitHub CLI (`gh auth token`; gh keeps it in the Keychain and refreshes it).
/// Internal endpoint, the same one the Copilot editor extension uses: it does not answer without editor headers.
public struct CopilotSource: UsageSource {
    public init() {}

    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "~/.local/bin/gh"]

    public func fetch() async throws -> UsageReport {
        guard let gh = ProcessRunner.locate(Self.candidates) else {
            throw UsageError.message(L("GitHub CLI (gh) not found. Copilot signs in through it"))
        }
        guard let raw = try? await ProcessRunner.run(gh, ["auth", "token"], timeout: 5),
              case let token = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw UsageError.message(L("not signed in to gh. Run gh auth login")) }
        let data = try await HTTP.get("https://api.github.com/copilot_internal/user", headers: [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ], errors: [401: L("gh rejected the sign-in. Run gh auth login"), 404: L("this account has no Copilot")])
        return try Parsers.copilot(data)
    }
}

// MARK: Codex

/// `codex app-server` over stdio: Codex itself holds the auth and refreshes the token.
/// The three messages can be sent at once; the server handles them in order.
public struct CodexSource: UsageSource {
    let codexHome: String?
    public init(codexHome: String? = nil) { self.codexHome = expandedDir(codexHome) }

    static let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]

    public func fetch() async throws -> UsageReport {
        guard let codex = ProcessRunner.locate(Self.candidates) else { throw UsageError.message(L("%@ not installed", "codex")) }
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "usage-widget", "title": "Usage Widget", "version": "1.0"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
        ]
        var input = Data()
        for m in messages {
            input.append(try JSONSerialization.data(withJSONObject: m))
            input.append(0x0A)
        }
        let env = codexHome.map { ["CODEX_HOME": $0] } ?? [:]
        let output = try await ProcessRunner.run(codex, ["app-server"], input: input, environment: env, timeout: 10,
                                                 until: { Self.response(id: 2, in: $0) != nil })
        guard let line = Self.response(id: 2, in: output) else { throw UsageError.message(L("app-server didn't respond")) }
        return try Parsers.codex(line)
    }

    /// The JSON-RPC response line with the given id from a stream of lines (an incomplete last line is skipped).
    static func response(id: Int, in output: Data) -> Data? {
        for line in output.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == id else { continue }
            return Data(line)
        }
        return nil
    }
}

// MARK: Cursor

/// The token comes from the Cursor state database (`state.vscdb`, read-only); Cursor refreshes it itself.
/// The web API takes it in the site session cookie: `<userId>%3A%3A<jwt>`, userId is the tail of `sub` from the JWT.
public struct CursorSource: UsageSource {
    public init() {}

    static let database = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    public func fetch() async throws -> UsageReport {
        let path = (Self.database as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw UsageError.message(L("%@ not installed", "Cursor")) }
        let raw = try await ProcessRunner.run("/usr/bin/sqlite3", [
            "-readonly", path, "select value from ItemTable where key = 'cursorAuth/accessToken'",
        ], timeout: 5)
        let jwt = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = Self.userID(jwt: jwt) else { throw UsageError.message(L("not signed in to Cursor. Sign in in the app")) }
        let data = try await HTTP.get("https://cursor.com/api/usage-summary", headers: [
            "Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(jwt)",
            "Accept": "application/json",
        ], errors: [401: L("Cursor sign-in expired. Open Cursor")])
        return try Parsers.cursor(data)
    }

    /// `sub` like `auth0|user_…` → `user_…`.
    static func userID(jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let sub = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sub"] as? String,
              let user = sub.split(separator: "|").last, !user.isEmpty
        else { return nil }
        return String(user)
    }
}

// MARK: API key: Kimi Code, OpenRouter, Moonshot

/// The account key from the Keychain; if missing, a hint on where to set it.
func apiKey(_ id: UUID) async throws -> String {
    guard let key = try await KeyStore.lookup(id) else { throw UsageError.message(L("no API key. Add one in Settings")) }
    return key
}

/// Computed, not `let`: a global constant would remember the language of the first access.
var keyRejected: [Int: String] { [401: L("key rejected. Check it in Settings")] }

/// A key lives in one vendor region, international or Chinese. Try them in turn:
/// a 401 before the last one means a key from the other region. Returns the response and the index of the URL that worked.
func getInRegions(_ urls: [String], key: String) async throws -> (Data, Int) {
    let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    for (i, url) in urls.enumerated() {
        let (data, status) = try await HTTP.request(url, headers: headers)
        if status == 401, i < urls.count - 1 { continue }
        return (try HTTP.check(data, status, keyRejected), i)
    }
    throw UsageError.message(L("no API addresses"))
}

/// Kimi Code subscription: a key from the Kimi console. The CLI is left alone, its refresh token is single-use.
public struct KimiSource: UsageSource {
    let accountID: UUID
    public init(accountID: UUID) { self.accountID = accountID }

    public func fetch() async throws -> UsageReport {
        let key = try await apiKey(accountID)
        let (data, _) = try await getInRegions(["https://api.kimi.com/coding/v1/usages",
                                                "https://api.kimi.ai/coding/v1/usages"], key: key)
        return try Parsers.kimi(data)
    }
}

public struct OpenRouterSource: UsageSource {
    let accountID: UUID
    public init(accountID: UUID) { self.accountID = accountID }

    public func fetch() async throws -> UsageReport {
        let key = try await apiKey(accountID)
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        async let keyInfo = HTTP.get("https://openrouter.ai/api/v1/key", headers: headers, errors: keyRejected)
        async let credits = HTTP.request("https://openrouter.ai/api/v1/credits", headers: headers)
        // The key may not be allowed to see the account balance (401/403): then go without it, key budget only.
        // Other failures fail the poll: otherwise a transient error would silently wipe the shown balance.
        let (creditsData, status) = try await credits
        let balance = [401, 403].contains(status) ? nil : try HTTP.check(creditsData, status, [:])
        return try Parsers.openRouter(key: try await keyInfo, credits: balance)
    }
}

/// Moonshot platform balance (pay-per-token Kimi API), not a subscription.
public struct MoonshotSource: UsageSource {
    let accountID: UUID
    public init(accountID: UUID) { self.accountID = accountID }

    public func fetch() async throws -> UsageReport {
        let key = try await apiKey(accountID)
        let (data, region) = try await getInRegions(["https://api.moonshot.ai/v1/users/me/balance",
                                                     "https://api.moonshot.cn/v1/users/me/balance"], key: key)
        return try Parsers.moonshot(data, currency: region == 0 ? "USD" : "CNY")
    }
}

// MARK: Google Cloud billing

/// The last BigQuery answer per billing settings and period: BigQuery is asked at most every
/// `CloudBillingSource.minInterval`. The raw answer is kept, not the report, so every poll parses it again in the
/// current language. A query already running for the key is shared: two accounts with the same settings, or an
/// account turned off and on during a poll, wait for it instead of starting another billed one.
actor CloudBillingCache {
    static let shared = CloudBillingCache()
    private var entries: [String: (at: Date, data: Data)] = [:]
    private var running: [String: Task<Data, Error>] = [:]

    func data(_ key: String, newerThan age: TimeInterval, now: Date,
              fetch: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let entry = entries[key], now.timeIntervalSince(entry.at) < age { return entry.data }
        if let task = running[key] { return try await task.value }
        let task = Task { try await fetch() }
        running[key] = task
        defer { running[key] = nil }
        let data = try await task.value
        entries[key] = (now, data)
        return data
    }
}

/// Spending from the billing export to BigQuery (Standard usage cost). The export changes a few times a day, so a
/// query runs at most every 15 minutes per settings (polls in between get the last answer), and each one is capped
/// by `maximumBytesBilled`: a query over the cap fails unbilled instead of scanning a large export. Worst case,
/// 100 MB × 4 an hour is about 290 GB a month, inside BigQuery's free terabyte. The token comes from
/// `gcloud auth print-access-token`: gcloud keeps and refreshes its own credentials (not single-use), the token
/// lives in memory for this poll only.
public struct CloudBillingSource: UsageSource {
    let billing: CloudBilling?
    public init(billing: CloudBilling?) { self.billing = billing }

    static let candidates = ["/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", "~/google-cloud-sdk/bin/gcloud",
                             "/opt/homebrew/share/google-cloud-sdk/bin/gcloud"]

    static let minInterval: TimeInterval = 15 * 60
    static let maxBytesBilled = 100_000_000

    public func fetch() async throws -> UsageReport {
        guard let billing, let (project, dataset) = Self.split(billing.dataset) else {
            throw UsageError.message(L("set the billing export dataset in Settings"))
        }
        let now = Date()
        let (start, end) = CloudBilling.bounds(billing.period, now: now)
        let key = billing.tag + "@" + String(Int(start.timeIntervalSince1970))
        let data = try await CloudBillingCache.shared.data(key, newerThan: Self.minInterval, now: now) {
            try await Self.query(billing, project: project, dataset: dataset, start: start, end: end)
        }
        return try Parsers.cloudBilling(data, billing: billing, start: start, end: end)
    }

    /// The jobs.query answer of a finished job; anything else throws and is not cached.
    private static func query(_ billing: CloudBilling, project: String, dataset: String, start: Date, end: Date) async throws -> Data {
        guard let gcloud = ProcessRunner.locate(Self.candidates) else {
            throw UsageError.message(L("%@ not installed", "gcloud"))
        }
        let token: String
        do {
            let output = try await ProcessRunner.run(gcloud, ["auth", "print-access-token"], timeout: 20)
            token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw UsageError.message(L("gcloud has no signed-in account. Run gcloud auth login"))
        }
        guard !token.isEmpty else { throw UsageError.message(L("gcloud has no signed-in account. Run gcloud auth login")) }

        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let base = "https://bigquery.googleapis.com/bigquery/v2/projects/\(project)"
        let body = Self.query(project: project, dataset: dataset, filter: billing.project, start: start, end: end,
                              result: Self.resultTable(billing))
        // jobs.insert, then jobs.getQueryResults: the job keeps running on the server, so its result is awaited
        // instead of starting (and paying for) another one.
        var (data, status) = try await HTTP.request(base + "/jobs", headers: headers, body: body, timeout: 30)
        for _ in 0..<4 {
            guard status == 200, let job = Self.pendingJob(data) else { break }
            (data, status) = try await HTTP.request(base + "/queries/" + job, headers: headers, timeout: 30)
        }
        guard status == 200 else { throw Self.failure(data, status, dataset: billing.dataset) }
        if Self.pendingJob(data) != nil {
            throw UsageError.message(L("BigQuery has not finished the query; the next poll will try again"))
        }
        return data
    }

    /// The path and query of `jobs.getQueryResults` for a job not known to be complete (the jobs.insert answer, or
    /// a results answer with `jobComplete: false`), nil for finished results.
    static func pendingJob(_ data: Data) -> String? {
        guard let root = try? Parsers.object(data), root["jobComplete"] as? Bool != true,
              let ref = root["jobReference"] as? [String: Any], let id = ref["jobId"] as? String,
              id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var items = [URLQueryItem(name: "timeoutMs", value: "10000")]
        if let location = ref["location"] as? String { items.append(URLQueryItem(name: "location", value: location)) }
        var components = URLComponents()
        components.queryItems = items
        return id + "?" + (components.percentEncodedQuery ?? "")
    }

    /// `project.dataset`, both checked: they go into the query text, not as parameters (BigQuery has none for tables).
    static func split(_ text: String) -> (String, String)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].range(of: #"^[a-z][a-z0-9-]{4,61}[a-z0-9]$"#, options: .regularExpression) != nil,
              parts[1].range(of: #"^[A-Za-z0-9_]{1,1024}$"#, options: .regularExpression) != nil else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The one-row result goes to a table of its own in the export's dataset, one per settings (two accounts never
    /// read each other's), overwritten by every query. Without a destination BigQuery makes an anonymous dataset
    /// owned by the user, and an organization that limits IAM members to its own domain (`iam.allowedPolicyMemberDomains`)
    /// refuses that for a personal account; the export's dataset is shared with project roles only.
    static func resultTable(_ billing: CloudBilling) -> String {
        let digest = SHA256.hash(data: Data(billing.tag.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "agents_usage_" + digest
    }

    /// The cost and credits of the period, and the currencies and newest export of the same project scope (all time,
    /// so an empty period still has a currency). Several currencies (exports of billing accounts in different
    /// currencies in one dataset) are reported, not added up. A jobs.insert body writing to `result`.
    static func query(project: String, dataset: String, filter: String?, start: Date, end: Date, result: String) -> Data {
        let table = "`\(project).\(dataset).gcp_billing_export_v1_*`"
        let sql = """
            SELECT
              (SELECT COUNT(DISTINCT currency) FROM \(table) WHERE \(projectScope)) AS currencies,
              (SELECT ANY_VALUE(currency) FROM \(table) WHERE \(projectScope)) AS currency,
              (SELECT SUM(cost) FROM \(table) WHERE \(scope)) AS cost,
              (SELECT SUM((SELECT IFNULL(SUM(c.amount), 0) FROM UNNEST(credits) AS c)) FROM \(table) WHERE \(scope)) AS credits,
              (SELECT UNIX_SECONDS(MAX(export_time)) FROM \(table) WHERE \(projectScope)) AS exported
            """
        func parameter(_ name: String, _ type: String, _ value: String) -> [String: Any] {
            ["name": name, "parameterType": ["type": type], "parameterValue": ["value": value]]
        }
        let query: [String: Any] = [
            "query": sql, "useLegacySql": false, "parameterMode": "NAMED",
            "maximumBytesBilled": String(maxBytesBilled),
            "destinationTable": ["projectId": project, "datasetId": dataset, "tableId": result],
            "writeDisposition": "WRITE_TRUNCATE",
            "queryParameters": [
                parameter("start", "INT64", String(Int(start.timeIntervalSince1970))),
                parameter("end", "INT64", String(Int(end.timeIntervalSince1970))),
                parameter("project", "STRING", filter?.trimmingCharacters(in: .whitespaces) ?? ""),
            ],
        ]
        let root: [String: Any] = ["configuration": ["query": query]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    private static let projectScope = "(@project = '' OR project.id = @project)"
    private static let scope = """
        usage_start_time >= TIMESTAMP_SECONDS(@start) AND usage_start_time < TIMESTAMP_SECONDS(@end) \
        AND \(projectScope)
        """

    /// Google's own message (`error.message`) is the most precise one; a missing export gets a hint instead.
    static func failure(_ data: Data, _ status: Int, dataset: String) -> UsageError {
        let message = ((try? Parsers.object(data))?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return .message(L("gcloud token rejected. Run gcloud auth login"))
        case 404: return .message(L("No billing export in %@ yet. Turn it on in Billing → Billing export; the table appears within hours", dataset))
        default: return .message(L("BigQuery: %@", message ?? "HTTP \(status)"))
        }
    }
}

// MARK: Antigravity (agy)

/// A read-only slash command in print mode: no model runs, agy refreshes the token itself.
public struct AgySource: UsageSource {
    public init() {}

    /// `~/.gemini/bin/agy` is where the installer puts the binary; `~/.local/bin/agy` is its optional link on PATH.
    static let candidates = ["~/.local/bin/agy", "~/.gemini/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]

    public func fetch() async throws -> UsageReport {
        guard let agy = ProcessRunner.locate(Self.candidates) else { throw UsageError.message(L("%@ not installed", "agy")) }
        let output = try await ProcessRunner.run(agy, ["-p", "/usage", "--output-format", "json"], timeout: 20)
        return try Parsers.agy(output)
    }
}
