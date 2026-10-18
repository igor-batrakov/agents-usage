import Foundation

public protocol UsageSource: Sendable {
    var provider: Provider { get }
    func fetch() async throws -> UsageReport
}

// MARK: Claude Code

/// Токен — из Keychain через `/usr/bin/security`: он уже в ACL элемента,
/// который создаёт Claude Code, поэтому запроса доступа не возникает.
/// Токен сам не обновляем: refresh-токен одноразовый, обновление за спиной
/// у CLI разлогинило бы его. Истёк — просим запустить claude.
public struct ClaudeSource: UsageSource {
    public let provider = Provider.claude
    public init() {}

    public func fetch() async throws -> UsageReport {
        let raw = try await ProcessRunner.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 5)
        guard let creds = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let token = creds["accessToken"] as? String
        else { throw UsageError.message("нет входа в Claude Code") }

        if let expiresMs = Parsers.number(creds["expiresAt"]), Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
            throw UsageError.message("токен истёк — запусти claude")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("usage-widget/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw UsageError.message("токен истёк — запусти claude")
        case 429: throw UsageError.message("API: слишком часто (429)")
        default: throw UsageError.message("API: HTTP \(status)")
        }
        let plan = Parsers.claudePlan(subscription: creds["subscriptionType"] as? String,
                                      tier: creds["rateLimitTier"] as? String)
        return try Parsers.claude(data, plan: plan)
    }

    /// Ephemeral: без дискового кэша и cookie — меньше памяти, ничего не остаётся на диске.
    static let session = URLSession(configuration: .ephemeral)
}

// MARK: Codex

/// `codex app-server` по stdio: сам Codex держит авторизацию и обновляет токен.
/// Три сообщения можно отправить разом — сервер обрабатывает их по порядку.
public struct CodexSource: UsageSource {
    public let provider = Provider.codex
    public init() {}

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
        let output = try await ProcessRunner.run(codex, ["app-server"], input: input, timeout: 10,
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

// MARK: Antigravity (agy)

/// Read-only слэш-команда в print-режиме: модель не запускается, токен agy обновляет сам.
public struct AgySource: UsageSource {
    public let provider = Provider.agy
    public init() {}

    static let candidates = ["~/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]

    public func fetch() async throws -> UsageReport {
        guard let agy = ProcessRunner.locate(Self.candidates) else { throw UsageError.message("agy не установлен") }
        let output = try await ProcessRunner.run(agy, ["-p", "/usage", "--output-format", "json"], timeout: 20)
        return try Parsers.agy(output)
    }
}
