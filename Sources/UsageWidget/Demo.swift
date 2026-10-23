import Foundation
import UsageCore

/// Demo mode for README screenshots:
///
///     open "Agents Usage.app" --args --demo [-language ru] [--demo-settings] [--demo-review] [--demo-panel]
///
/// Made-up data for every service and its own settings in a separate UserDefaults domain (wiped on
/// every launch). Real accounts, keys and notification state are not touched; there are no notifications,
/// no hotkey and no revo runs (a made-up review chain). `--demo-settings` opens settings on the Services tab
/// right away, `--demo-review` on the Review chain tab, `--demo-panel` turns on the panel.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    static let opensReview = CommandLine.arguments.contains("--demo-review")
    static let opensSettings = CommandLine.arguments.contains("--demo-settings") || opensReview
    private static let suite = "ru.batrakov.UsageWidget.demo"

    /// Demo accounts, in menu bar order.
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
            settings.selectedTab = opensReview ? SettingsView.reviewTab : 1
            settings.selectedAccountID = accounts.last?.id
        }
        return settings
    }

    static func source(_ account: Account) -> any UsageSource { DemoSource(kind: account.kind) }

    /// A made-up review chain: the demo never runs revo. Codex is on a limit for two hours.
    static func reviewChain() -> (chain: RevoChain, engines: [RevoEngine]) {
        let until = Int(Date().timeIntervalSince1970) + 2 * 3600
        let limited = #"{"limit_until": \#(until), "active": true}"#, free = #"{"limit_until": null, "active": false}"#
        let chain = """
            {"config_path": "~/.config/revolver/chain.json", "config_rev": "demo",
             "chain": [
               {"id": "sol", "engine": "codex", "model": "gpt-6.1-sol", "effort": "max", "on": true, "takes_over": "-"},
               {"id": "astra", "engine": "codex", "model": "gpt-6-astra", "effort": "high", "on": false, "takes_over": "any_fail"},
               {"id": "gemini", "engine": "agy", "model": "gemini-3.8-flash", "effort": "high", "on": true, "takes_over": "limit"},
               {"id": "fable", "engine": "claude", "model": "claude-fable-5-1", "effort": "high", "on": true, "takes_over": "limit"}],
             "settings": {"review_rounds": 2, "lang": null},
             "state": {"sol": \(limited), "astra": \(limited), "gemini": \(free), "fable": \(free)}}
            """
        let engines = """
            [{"name": "codex", "display": "Codex", "efforts": ["low", "medium", "high", "xhigh", "max"],
              "models": ["default", "gpt-6.1-sol", "gpt-6-astra"], "custom_model": true, "installed": true},
             {"name": "agy", "display": "Gemini", "efforts": ["low", "medium", "high"],
              "models": ["default", "gemini-3.8-flash", "gemini-4-argon"], "custom_model": true, "installed": true},
             {"name": "claude", "display": "Claude", "efforts": ["low", "medium", "high", "xhigh", "max"],
              "models": ["default", "claude-fable-5-1", "claude-opus-5-5"], "custom_model": true, "installed": true}]
            """
        let decoder = JSONDecoder()
        return (try! decoder.decode(RevoChain.self, from: Data(chain.utf8)),
                try! decoder.decode([RevoEngine].self, from: Data(engines.utf8)))
    }

    static func reviewLimits() -> [String: RevoLimit] {
        let until = Int(Date().timeIntervalSince1970) + 2 * 3600
        return try! JSONDecoder().decode([String: RevoLimit].self, from: Data(#"{"codex": {"until": \#(until)}}"#.utf8))
    }
}

/// The report is built at poll time: reset times count from now, labels are in the selected language.
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
