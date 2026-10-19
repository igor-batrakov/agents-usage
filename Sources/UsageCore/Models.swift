import Foundation

/// Source type, a catalog entry. Each has its own polling code (`Catalog.source`).
public enum Provider: String, CaseIterable, Codable, Sendable {
    case claude, codex, agy, copilot, cursor, kimi, openrouter, moonshot

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .agy: "Antigravity"
        case .copilot: "GitHub Copilot"
        case .cursor: "Cursor"
        case .kimi: "Kimi Code"
        case .openrouter: "OpenRouter"
        case .moonshot: "Moonshot"
        }
    }

    /// The vendor's usage page; nil if there is no web page.
    public var defaultUsageURL: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")
        case .agy: nil
        case .copilot: URL(string: "https://github.com/settings/copilot/features")
        case .cursor: URL(string: "https://cursor.com/dashboard/spending")
        case .kimi: URL(string: "https://www.kimi.com/code/console")
        case .openrouter: URL(string: "https://openrouter.ai/activity")
        case .moonshot: URL(string: "https://platform.moonshot.ai/console/account")
        }
    }

    /// Environment variable holding the config directory; it tells accounts of one service apart.
    /// nil means the service has a single account.
    public var configDirVariable: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        default: nil
        }
    }

    /// Signs in with an API key from the vendor console (stored in the Keychain, `KeyStore`), not through a CLI.
    public var usesAPIKey: Bool {
        switch self {
        case .kimi, .openrouter, .moonshot: true
        default: false
        }
    }

    /// Where to create the key.
    public var apiKeysURL: URL? {
        switch self {
        case .kimi: URL(string: "https://www.kimi.com/code/console")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .moonshot: URL(string: "https://platform.moonshot.ai/console/api-keys")
        default: nil
        }
    }

    /// Multiple accounts: for services with a config directory or a key (one key per account).
    public var allowsMultipleAccounts: Bool { configDirVariable != nil || usesAPIKey }
}

/// Account: an instance of a catalog service with its own settings. Order is the list order.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: Provider
    public var name: String
    public var enabled: Bool
    /// Config directory (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`); nil means the default.
    public var configDir: String?
    /// Hidden windows (by `LimitWindow.id`): not shown and do not affect the icon color.
    public var hiddenWindows: Set<String>
    /// Window for the menu bar; nil means auto (maximum over the short windows).
    public var barWindowID: String?
    /// Custom link to the usage page; nil means `kind.defaultUsageURL`.
    public var usageURL: String?
    public var onPanel: Bool
    /// Grows on every API key change (the key itself is in `KeyStore`). For the store and notifications this is
    /// a source change, like a directory change: a poll with the old key is discarded. Optional so that old
    /// saved accounts without this field decode as they are.
    public var keyRevision: Int?

    public init(id: UUID = UUID(), kind: Provider, name: String? = nil, enabled: Bool = true,
                configDir: String? = nil, hiddenWindows: Set<String> = [], barWindowID: String? = nil,
                usageURL: String? = nil, onPanel: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.enabled = enabled
        self.configDir = configDir
        self.hiddenWindows = hiddenWindows
        self.barWindowID = barWindowID
        self.usageURL = usageURL
        self.onPanel = onPanel
    }

    /// Where the account data comes from besides its type: if it changes, it is effectively another account.
    public func sameSource(as other: Account) -> Bool {
        configDir == other.configDir && keyRevision == other.keyRevision
    }

    /// Same for notification state keys: without an API key, the old form (directory only).
    public var sourceTag: String {
        (configDir ?? "") + (keyRevision.map { "#\($0)" } ?? "")
    }

    public var resolvedUsageURL: URL? {
        if let usageURL, !usageURL.isEmpty, let url = URL(string: usageURL) { return url }
        return kind.defaultUsageURL
    }

    public func visibleWindows(_ snapshot: Snapshot) -> [LimitWindow] {
        (snapshot.report?.windows ?? []).filter { !hiddenWindows.contains($0.id) }
    }

    /// The service has only a balance and no limit windows: its menu bar bar would always be empty.
    /// Moonshot by type (it never has windows, neither before the first response nor on error), the rest
    /// by response (OpenRouter without a key budget).
    public func balanceOnly(_ snapshot: Snapshot) -> Bool {
        if kind == .moonshot { return true }
        guard let report = snapshot.report else { return false }
        return report.windows.isEmpty && !report.balances.isEmpty
    }

    /// Fraction for the menu bar: the selected window, else the maximum over short ones, else over all.
    public func barUsed(_ snapshot: Snapshot, at now: Date) -> Double? {
        let windows = visibleWindows(snapshot)
        if let barWindowID, let w = windows.first(where: { $0.id == barWindowID }) { return w.used(at: now) }
        let short = windows.filter(\.isShort)
        return (short.isEmpty ? windows : short).map { $0.used(at: now) }.max()
    }

    /// The most loaded visible window; it picks the color.
    public func maxUsed(_ snapshot: Snapshot, at now: Date) -> Double? {
        visibleWindows(snapshot).map { $0.used(at: now) }.max()
    }
}

/// One limit window. `used` is the fraction consumed, 0…1.
public struct LimitWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Group subheading (for agy: "Gemini", "Claude and GPT"); nil means no group.
    public let group: String?
    public let used: Double
    public let resetsAt: Date?
    /// Short (5-hour) window: the menu bar bar is drawn from it.
    public let isShort: Bool
    /// Window length in seconds; nil if unknown (then there is no pace marker).
    public let duration: TimeInterval?

    public init(id: String, title: String, group: String? = nil, used: Double, resetsAt: Date?, isShort: Bool,
                duration: TimeInterval? = nil) {
        self.id = id
        self.title = title
        self.group = group
        self.used = min(max(used, 0), 1)
        self.resetsAt = resetsAt
        self.isShort = isShort
        self.duration = duration
    }

    public var fullTitle: String { group.map { "\($0) · \(title)" } ?? title }

    /// If the reset time has passed, the window counts as empty until the next poll.
    public func used(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return used
    }

    /// Pace: how much of the window has elapsed in time, 0…1. Usage above pace runs out before the reset.
    /// nil if the length or reset time is unknown, or the reset has already passed.
    public func pace(at now: Date) -> Double? {
        guard let duration, duration > 0, let resetsAt, resetsAt > now else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
    }
}

/// Free limit resets (Codex "Full reset"): how many are available and when the nearest one expires.
public struct FreeResets: Sendable, Equatable {
    public let count: Int
    public let nextExpiry: Date?

    public init(count: Int, nextExpiry: Date?) {
        self.count = count
        self.nextExpiry = nextExpiry
    }
}

/// Money metric without a fraction (account balance): shown as a line next to the limit windows.
public struct Balance: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// In currency units (dollars, yuan), not cents.
    public let amount: Double
    /// ISO 4217 code: USD, CNY.
    public let currency: String

    public init(id: String, title: String, amount: Double, currency: String) {
        self.id = id
        self.title = title
        self.amount = amount
        self.currency = currency
    }
}

public struct UsageReport: Sendable, Equatable {
    public let windows: [LimitWindow]
    public let plan: String?
    public let freeResets: FreeResets?
    public let balances: [Balance]

    public init(windows: [LimitWindow], plan: String?, freeResets: FreeResets? = nil, balances: [Balance] = []) {
        self.windows = windows
        self.plan = plan
        self.freeResets = freeResets
        self.balances = balances
    }
}

public struct Snapshot: Sendable, Equatable {
    public var report: UsageReport?
    public var fetchedAt: Date?
    public var error: String?

    public init(report: UsageReport? = nil, fetchedAt: Date? = nil, error: String? = nil) {
        self.report = report
        self.fetchedAt = fetchedAt
        self.error = error
    }
}

public enum UsageError: LocalizedError, Equatable {
    case message(String)
    /// The process exited with a nonzero code: the caller tells outcomes apart by it (`security` 44 is "no item").
    case exit(tool: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .exit(let tool, let status): L("%@: exit code %d", tool, status)
        }
    }
}
