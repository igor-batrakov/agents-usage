import Foundation
import Testing
@testable import UsageCore

@Suite struct AccountTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(_ windows: [LimitWindow]) -> Snapshot {
        Snapshot(report: UsageReport(windows: windows, plan: nil))
    }

    private let windows = [
        LimitWindow(id: "5h-a", title: "5h", used: 0.2, resetsAt: nil, isShort: true),
        LimitWindow(id: "5h-b", title: "5h b", used: 0.4, resetsAt: nil, isShort: true),
        LimitWindow(id: "week", title: "week", used: 0.9, resetsAt: nil, isShort: false),
    ]

    @Test func barIsMaxOfShortWindowsByDefault() {
        let a = Account(kind: .agy)
        #expect(a.barUsed(snapshot(windows), at: now) == 0.4)
        #expect(a.maxUsed(snapshot(windows), at: now) == 0.9)
        #expect(a.barUsed(Snapshot(), at: now) == nil)
    }

    @Test func chosenBarWindowWins() {
        let a = Account(kind: .agy, barWindowID: "week")
        #expect(a.barUsed(snapshot(windows), at: now) == 0.9)
        // Выбранное окно пропало из ответа — откат к авто.
        let gone = Account(kind: .agy, barWindowID: "nope")
        #expect(gone.barUsed(snapshot(windows), at: now) == 0.4)
    }

    @Test func hiddenWindowsDoNotCount() {
        let a = Account(kind: .agy, hiddenWindows: ["week", "5h-b"])
        #expect(a.visibleWindows(snapshot(windows)).map(\.id) == ["5h-a"])
        #expect(a.maxUsed(snapshot(windows), at: now) == 0.2)
        #expect(a.barUsed(snapshot(windows), at: now) == 0.2)
    }

    @Test func withoutShortWindowsBarUsesAll() {
        let a = Account(kind: .agy)
        let only = [LimitWindow(id: "w", title: "w", used: 0.7, resetsAt: nil, isShort: false)]
        #expect(a.barUsed(snapshot(only), at: now) == 0.7)
    }

    @Test func usageURLOverrideAndDefault() {
        #expect(Account(kind: .claude).resolvedUsageURL?.absoluteString == "https://claude.ai/settings/usage")
        #expect(Account(kind: .claude, usageURL: "https://example.com/u").resolvedUsageURL?.absoluteString
                == "https://example.com/u")
        #expect(Account(kind: .claude, usageURL: "").resolvedUsageURL?.absoluteString == "https://claude.ai/settings/usage")
        #expect(Account(kind: .agy).resolvedUsageURL == nil)
    }

    @Test func codableRoundTrip() throws {
        let list = [
            Account(kind: .claude, name: "Работа", configDir: "~/.claude-work", hiddenWindows: ["x"], barWindowID: "y",
                    usageURL: "https://e.x", onPanel: false),
            Account(kind: .agy, enabled: false),
        ]
        let decoded = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(list))
        #expect(decoded == list)
    }
}

@Suite struct CatalogTests {
    @Test func defaultAccountsForInstalledOnly() {
        let accounts = Catalog.defaultAccounts(installed: { $0 != .codex })
        #expect(accounts.map(\.kind) == [.claude, .agy])
        #expect(accounts.filter { !$0.enabled }.isEmpty)
        #expect(accounts.map(\.name) == ["Claude Code", "Antigravity"])
    }

    @Test func multipleAccountsOnlyWhereSupported() {
        let existing = [Account(kind: .claude), Account(kind: .agy)]
        #expect(Catalog.canAdd(.claude, to: existing))
        #expect(Catalog.canAdd(.codex, to: existing))
        #expect(!Catalog.canAdd(.agy, to: existing))
    }

    @Test func claudeKeychainServiceName() {
        #expect(ClaudeSource.keychainService(configDir: nil) == "Claude Code-credentials")
        // printf '%s' /Users/test/.claude-work | shasum -a 256 → 03abf0ee…
        #expect(ClaudeSource.keychainService(configDir: "/Users/test/.claude-work") == "Claude Code-credentials-03abf0ee")
    }

    @Test func trailingSlashVariantIsTried() {
        #expect(ClaudeSource.keychainServices(configDir: nil) == ["Claude Code-credentials"])
        #expect(ClaudeSource.keychainServices(configDir: "/Users/test/.claude-work")
                == ["Claude Code-credentials-03abf0ee"])
        let withSlash = ClaudeSource.keychainServices(configDir: "/Users/test/.claude-work/")
        #expect(withSlash.count == 2)
        #expect(withSlash.last == "Claude Code-credentials-03abf0ee")
    }

    @Test func tildeAndEmptyConfigDir() {
        #expect(expandedDir(nil) == nil)
        #expect(expandedDir("  ") == nil)
        #expect(expandedDir("~/.claude-work") == NSHomeDirectory() + "/.claude-work")
    }
}
