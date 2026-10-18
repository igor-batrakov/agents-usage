import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case claude, codex, agy

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .agy: "Antigravity"
        }
    }
}

/// Одно окно лимита. `used` — доля израсходованного, 0…1.
public struct LimitWindow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Подзаголовок-группа (у agy: «Gemini», «Claude и GPT»); nil — без группы.
    public let group: String?
    public let used: Double
    public let resetsAt: Date?
    /// Короткое (5-часовое) окно: по нему рисуется полоска в строке меню.
    public let isShort: Bool

    public init(id: String, title: String, group: String? = nil, used: Double, resetsAt: Date?, isShort: Bool) {
        self.id = id
        self.title = title
        self.group = group
        self.used = min(max(used, 0), 1)
        self.resetsAt = resetsAt
        self.isShort = isShort
    }

    /// Если время сброса уже прошло, окно считается пустым до следующего опроса.
    public func used(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return used
    }
}

public struct UsageReport: Sendable, Equatable {
    public let windows: [LimitWindow]
    public let plan: String?

    public init(windows: [LimitWindow], plan: String?) {
        self.windows = windows
        self.plan = plan
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

    /// Доля для полоски в строке меню: максимум по коротким окнам, иначе по всем.
    public func shortUsed(at now: Date) -> Double? {
        guard let windows = report?.windows, !windows.isEmpty else { return nil }
        let short = windows.filter(\.isShort)
        return (short.isEmpty ? windows : short).map { $0.used(at: now) }.max()
    }

    /// Самое напряжённое окно — по нему выбирается цвет.
    public func maxUsed(at now: Date) -> Double? {
        report?.windows.map { $0.used(at: now) }.max()
    }
}

public enum UsageError: LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
