import Foundation

/// Каталог: как опрашивать аккаунт и какие сервисы установлены.
public enum Catalog {
    public static func source(for account: Account) -> any UsageSource {
        switch account.kind {
        case .claude: ClaudeSource(configDir: account.configDir)
        case .codex: CodexSource(codexHome: account.configDir)
        case .agy: AgySource()
        }
    }

    /// Признак, что сервис стоит на машине: его CLI или каталог конфигурации.
    public static func isInstalled(_ kind: Provider) -> Bool {
        switch kind {
        case .claude:
            ProcessRunner.locate(["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) != nil
                || FileManager.default.fileExists(atPath: ("~/.claude" as NSString).expandingTildeInPath)
        case .codex: ProcessRunner.locate(CodexSource.candidates) != nil
        case .agy: ProcessRunner.locate(AgySource.candidates) != nil
        }
    }

    /// Первый запуск (и переход с v1, где списка не было): по аккаунту на каждый найденный сервис.
    public static func defaultAccounts(installed: (Provider) -> Bool = isInstalled) -> [Account] {
        Provider.allCases.filter(installed).map { Account(kind: $0) }
    }

    /// Можно ли добавить ещё один аккаунт этого сервиса.
    public static func canAdd(_ kind: Provider, to accounts: [Account]) -> Bool {
        kind.allowsMultipleAccounts || !accounts.contains { $0.kind == kind }
    }
}
