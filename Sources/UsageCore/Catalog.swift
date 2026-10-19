import Foundation

/// Catalog: how to poll an account and which services are installed.
public enum Catalog {
    public static func source(for account: Account) -> any UsageSource {
        switch account.kind {
        case .claude: ClaudeSource(configDir: account.configDir)
        case .codex: CodexSource(codexHome: account.configDir)
        case .agy: AgySource()
        case .copilot: CopilotSource()
        case .cursor: CursorSource()
        case .kimi: KimiSource(accountID: account.id)
        case .openrouter: OpenRouterSource(accountID: account.id)
        case .moonshot: MoonshotSource(accountID: account.id)
        }
    }

    /// Whether the service is installed on this machine: its CLI or its config directory.
    /// API-key services have nothing to install, so false: they are not added on first launch.
    public static func isInstalled(_ kind: Provider) -> Bool {
        switch kind {
        case .claude:
            ProcessRunner.locate(["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) != nil
                || FileManager.default.fileExists(atPath: ("~/.claude" as NSString).expandingTildeInPath)
        case .codex: ProcessRunner.locate(CodexSource.candidates) != nil
        case .agy: ProcessRunner.locate(AgySource.candidates) != nil
        case .copilot: ProcessRunner.locate(CopilotSource.candidates) != nil
        case .cursor: FileManager.default.fileExists(atPath: (CursorSource.database as NSString).expandingTildeInPath)
        case .kimi, .openrouter, .moonshot: false
        }
    }

    /// First launch (and migration from v1, which had no list): one account per detected service.
    public static func defaultAccounts(installed: (Provider) -> Bool = isInstalled) -> [Account] {
        Provider.allCases.filter(installed).map { Account(kind: $0) }
    }

    /// Whether another account of this service can be added.
    public static func canAdd(_ kind: Provider, to accounts: [Account]) -> Bool {
        kind.allowsMultipleAccounts || !accounts.contains { $0.kind == kind }
    }
}
