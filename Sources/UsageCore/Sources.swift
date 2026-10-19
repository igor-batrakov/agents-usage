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

    static func request(_ url: String, headers: [String: String], timeout: TimeInterval = 10) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        request.setValue("usage-widget/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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

// MARK: Antigravity (agy)

/// A read-only slash command in print mode: no model runs, agy refreshes the token itself.
public struct AgySource: UsageSource {
    public init() {}

    static let candidates = ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]

    public func fetch() async throws -> UsageReport {
        guard let agy = ProcessRunner.locate(Self.candidates) else { throw UsageError.message(L("%@ not installed", "agy")) }
        let output = try await ProcessRunner.run(agy, ["-p", "/usage", "--output-format", "json"], timeout: 20)
        return try Parsers.agy(output)
    }
}
