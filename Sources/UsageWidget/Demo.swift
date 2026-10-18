import Foundation
import UsageCore

/// Демо-режим для скриншотов README:
///
///     open "Agents Usage.app" --args --demo [-language ru] [--demo-settings] [--demo-panel]
///
/// Вымышленные данные всех сервисов и свои настройки в отдельном домене UserDefaults (стираются при
/// каждом запуске). Настоящие аккаунты, ключи и состояние уведомлений не трогаются; уведомлений и
/// горячей клавиши нет. `--demo-settings` сразу открывает настройки на вкладке «Сервисы»,
/// `--demo-panel` включает панель.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    static let opensSettings = CommandLine.arguments.contains("--demo-settings")
    private static let suite = "ru.batrakov.UsageWidget.demo"

    /// Аккаунты демо: порядок — как в строке меню.
    private static let kinds: [Provider] = [.claude, .codex, .agy, .copilot, .cursor, .openrouter]

    @MainActor
    static func settings() -> Settings {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let accounts = kinds.map { Account(kind: $0) }
        defaults.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
        defaults.set(false, forKey: "notify")
        defaults.set(HotKeyChoice.off.rawValue, forKey: "hotKey")
        defaults.set(CommandLine.arguments.contains("--demo-panel"), forKey: "panelEnabled")
        let settings = Settings(defaults: defaults)
        if opensSettings {
            settings.selectedTab = 1
            settings.selectedAccountID = accounts.last?.id
        }
        return settings
    }

    static func source(_ account: Account) -> any UsageSource { DemoSource(kind: account.kind) }
}

/// Отчёт строится при опросе: время сброса — от текущего момента, подписи — на выбранном языке.
private struct DemoSource: UsageSource {
    let kind: Provider

    func fetch() async throws -> UsageReport {
        let now = Date()
        func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }
        let h5: TimeInterval = 5 * 3600, week: TimeInterval = 7 * 86400, month: TimeInterval = 30 * 86400
        func w(_ id: String, _ title: String, _ group: String? = nil, _ used: Double, _ hours: Double,
               _ duration: TimeInterval, short: Bool = false) -> LimitWindow {
            LimitWindow(id: id, title: title, group: group, used: used, resetsAt: at(hours), isShort: short,
                        duration: duration)
        }
        switch kind {
        case .claude:
            return UsageReport(windows: [
                w("claude-session", L("5 hours"), nil, 0.38, 2.2, h5, short: true),
                w("claude-weekly_all", L("Week"), nil, 0.43, 83, week),
                w("claude-weekly_scoped-Opus", L("Week") + " · Opus", nil, 0.12, 83, week),
            ], plan: "Max 5x")
        case .codex:
            return UsageReport(windows: [
                w("codex-5h", L("5 hours"), nil, 0.74, 1.4, h5, short: true),
                w("codex-week", L("Week"), nil, 0.47, 98, week),
            ], plan: "Plus", freeResets: FreeResets(count: 2, nextExpiry: at(74)))
        case .agy:
            let gemini = "Gemini", other = L("Claude and GPT")
            return UsageReport(windows: [
                w("agy-g5", L("5 hours"), gemini, 0.15, 3.6, h5, short: true),
                w("agy-gw", L("Week"), gemini, 0.11, 121, week),
                w("agy-c5", L("5 hours"), other, 0.56, 4.1, h5, short: true),
                w("agy-cw", L("Week"), other, 0.31, 121, week),
            ], plan: nil)
        case .copilot:
            return UsageReport(windows: [
                w("copilot-premium_interactions", L("Premium requests"), nil, 0.64, 13 * 24, month),
            ], plan: "Pro")
        case .cursor:
            return UsageReport(windows: [
                w("cursor-plan", L("Included in plan"), nil, 0.81, 9 * 24, month),
                w("cursor-api", L("API models"), nil, 0.93, 9 * 24, month),
            ], plan: "Pro")
        case .openrouter:
            return UsageReport(windows: [
                LimitWindow(id: "openrouter-key", title: L("Key · month"), used: 0.23, resetsAt: nil, isShort: false),
            ], plan: nil, balances: [Balance(id: "openrouter-credits", title: L("Balance"), amount: 44, currency: "USD")])
        case .kimi, .moonshot:
            return UsageReport(windows: [], plan: nil,
                               balances: [Balance(id: "demo", title: L("Balance"), amount: 12.5, currency: "USD")])
        }
    }
}
