import CryptoKit
import Foundation

public protocol UsageSource: Sendable {
    func fetch() async throws -> UsageReport
}

/// `~/x` → абсолютный путь; пустая строка — nil (каталог по умолчанию).
func expandedDir(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
    return (path as NSString).expandingTildeInPath
}

// MARK: Claude Code

/// Токен — из Keychain через `/usr/bin/security`: он уже в ACL элемента,
/// который создаёт Claude Code, поэтому запроса доступа не возникает.
/// Токен сам не обновляем: refresh-токен одноразовый, обновление за спиной
/// у CLI разлогинило бы его. Истёк — просим запустить claude.
public struct ClaudeSource: UsageSource {
    let configDir: String?
    public init(configDir: String? = nil) { self.configDir = expandedDir(configDir) }

    /// Имя элемента Keychain — как его строит Claude Code (2.1.x): при заданном
    /// CLAUDE_CONFIG_DIR к имени добавляются первые 8 hex-символов sha256 от пути в NFC.
    static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    /// Варианты имени: путь как введён и без завершающего «/». Нормализует ли путь сам
    /// Claude Code, по минифицированному бинарю не установить — пробуем оба.
    static func keychainServices(configDir: String?) -> [String] {
        guard let configDir else { return [keychainService(configDir: nil)] }
        let names = [configDir, (configDir as NSString).standardizingPath].map { keychainService(configDir: $0) }
        return names.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public func fetch() async throws -> UsageReport {
        var found: Data?
        for service in Self.keychainServices(configDir: configDir) {
            // Нет элемента — security выходит с кодом 44; это не ошибка, пробуем следующий вариант.
            if let data = try? await ProcessRunner.run(
                "/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 5) {
                found = data
                break
            }
        }
        guard let raw = found else {
            throw UsageError.message(configDir == nil ? "нет входа в Claude Code"
                                                      : "нет входа в Claude Code для этого каталога")
        }
        guard let creds = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let token = creds["accessToken"] as? String
        else { throw UsageError.message("нет входа в Claude Code") }

        if let expiresMs = Parsers.number(creds["expiresAt"]), Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
            throw UsageError.message("токен истёк — запусти claude")
        }

        let data = try await HTTP.get("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ], errors: [401: "токен истёк — запусти claude"], timeout: 5)
        let plan = Parsers.claudePlan(subscription: creds["subscriptionType"] as? String,
                                      tier: creds["rateLimitTier"] as? String)
        return try Parsers.claude(data, plan: plan)
    }
}

/// GET с общими ошибками. `errors` — свои тексты для кодов (401 — что сделать пользователю).
enum HTTP {
    /// Ephemeral: без дискового кэша и cookie — меньше памяти, ничего не остаётся на диске.
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
        throw UsageError.message(status == 429 ? "API: слишком часто (429)" : "API: HTTP \(status)")
    }
}

// MARK: GitHub Copilot

/// Токен — у GitHub CLI (`gh auth token`, сам gh держит его в Связке ключей и обновляет).
/// Эндпоинт внутренний, тот же, что у расширения Copilot в редакторе: без editor-заголовков не отвечает.
public struct CopilotSource: UsageSource {
    public init() {}

    static let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "~/.local/bin/gh"]

    public func fetch() async throws -> UsageReport {
        guard let gh = ProcessRunner.locate(Self.candidates) else {
            throw UsageError.message("нет GitHub CLI (gh) — через него берётся вход")
        }
        guard let raw = try? await ProcessRunner.run(gh, ["auth", "token"], timeout: 5),
              case let token = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw UsageError.message("нет входа в gh — запусти gh auth login") }
        let data = try await HTTP.get("https://api.github.com/copilot_internal/user", headers: [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ], errors: [401: "gh отклонил вход — запусти gh auth login", 404: "у аккаунта нет Copilot"])
        return try Parsers.copilot(data)
    }
}

// MARK: Codex

/// `codex app-server` по stdio: сам Codex держит авторизацию и обновляет токен.
/// Три сообщения можно отправить разом — сервер обрабатывает их по порядку.
public struct CodexSource: UsageSource {
    let codexHome: String?
    public init(codexHome: String? = nil) { self.codexHome = expandedDir(codexHome) }

    static let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]

    public func fetch() async throws -> UsageReport {
        guard let codex = ProcessRunner.locate(Self.candidates) else { throw UsageError.message("codex не установлен") }
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
        guard let line = Self.response(id: 2, in: output) else { throw UsageError.message("app-server не ответил") }
        return try Parsers.codex(line)
    }

    /// Строка JSON-RPC ответа с нужным id из потока строк (неполная последняя строка пропускается).
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

/// Токен — из базы состояния Cursor (`state.vscdb`, только чтение): обновляет его сам Cursor.
/// Веб-API принимает его в cookie сессии сайта: `<userId>%3A%3A<jwt>`, userId — хвост `sub` из JWT.
public struct CursorSource: UsageSource {
    public init() {}

    static let database = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

    public func fetch() async throws -> UsageReport {
        let path = (Self.database as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw UsageError.message("Cursor не установлен") }
        let raw = try await ProcessRunner.run("/usr/bin/sqlite3", [
            "-readonly", path, "select value from ItemTable where key = 'cursorAuth/accessToken'",
        ], timeout: 5)
        let jwt = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = Self.userID(jwt: jwt) else { throw UsageError.message("нет входа в Cursor — войди в приложении") }
        let data = try await HTTP.get("https://cursor.com/api/usage-summary", headers: [
            "Cookie": "WorkosCursorSessionToken=\(user)%3A%3A\(jwt)",
            "Accept": "application/json",
        ], errors: [401: "вход в Cursor истёк — открой Cursor"])
        return try Parsers.cursor(data)
    }

    /// `sub` вида `auth0|user_…` → `user_…`.
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

// MARK: По API-ключу: Kimi Code, OpenRouter, Moonshot

/// Ключ аккаунта из Связки ключей; нет — подсказка, где его задать.
func apiKey(_ id: UUID) async throws -> String {
    guard let key = try await KeyStore.lookup(id) else { throw UsageError.message("нет API-ключа — задай его в настройках") }
    return key
}

let keyRejected = [401: "ключ отклонён — проверь его в настройках"]

/// Ключ живёт в одном регионе вендора — международном или китайском. Пробуем по очереди:
/// 401 не на последнем — значит, ключ другого региона. Возвращает ответ и индекс сработавшего адреса.
func getInRegions(_ urls: [String], key: String) async throws -> (Data, Int) {
    let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    for (i, url) in urls.enumerated() {
        let (data, status) = try await HTTP.request(url, headers: headers)
        if status == 401, i < urls.count - 1 { continue }
        return (try HTTP.check(data, status, keyRejected), i)
    }
    throw UsageError.message("нет адресов API")
}

/// Подписка Kimi Code: ключ из консоли Kimi. CLI не трогаем — его refresh-токен одноразовый.
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
        // Баланс счёта ключу может быть не положен (401/403) — тогда без него, только бюджет ключа.
        // Остальные сбои — сбой опроса: иначе временная ошибка молча стёрла бы показанный баланс.
        let (creditsData, status) = try await credits
        let balance = [401, 403].contains(status) ? nil : try HTTP.check(creditsData, status, [:])
        return try Parsers.openRouter(key: try await keyInfo, credits: balance)
    }
}

/// Баланс платформы Moonshot (API Kimi по токенам), не подписка.
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

/// Read-only слэш-команда в print-режиме: модель не запускается, токен agy обновляет сам.
public struct AgySource: UsageSource {
    public init() {}

    static let candidates = ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]

    public func fetch() async throws -> UsageReport {
        guard let agy = ProcessRunner.locate(Self.candidates) else { throw UsageError.message("agy не установлен") }
        let output = try await ProcessRunner.run(agy, ["-p", "/usage", "--output-format", "json"], timeout: 20)
        return try Parsers.agy(output)
    }
}
