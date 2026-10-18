import Foundation

/// Тип источника — запись каталога. Код опроса у каждого свой (`Catalog.source`).
public enum Provider: String, CaseIterable, Codable, Sendable {
    case claude, codex, agy

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .agy: "Antigravity"
        }
    }

    /// Страница лимитов у вендора; nil — веб-страницы нет.
    public var defaultUsageURL: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")
        case .agy: nil
        }
    }

    /// Переменная окружения с каталогом конфигурации — она различает аккаунты одного сервиса.
    /// nil — аккаунт у сервиса один.
    public var configDirVariable: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .agy: nil
        }
    }

    public var allowsMultipleAccounts: Bool { configDirVariable != nil }
}

/// Аккаунт — экземпляр сервиса из каталога со своими настройками. Порядок — порядок в списке.
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: Provider
    public var name: String
    public var enabled: Bool
    /// Каталог конфигурации (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`); nil — по умолчанию.
    public var configDir: String?
    /// Скрытые окна (по `LimitWindow.id`): не показываются и не влияют на цвет иконки.
    public var hiddenWindows: Set<String>
    /// Окно для полоски в строке меню; nil — авто (максимум по коротким окнам).
    public var barWindowID: String?
    /// Своя ссылка на страницу лимитов; nil — `kind.defaultUsageURL`.
    public var usageURL: String?
    public var onPanel: Bool

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

    public var resolvedUsageURL: URL? {
        if let usageURL, !usageURL.isEmpty, let url = URL(string: usageURL) { return url }
        return kind.defaultUsageURL
    }

    public func visibleWindows(_ snapshot: Snapshot) -> [LimitWindow] {
        (snapshot.report?.windows ?? []).filter { !hiddenWindows.contains($0.id) }
    }

    /// Доля для полоски в строке меню: выбранное окно, иначе максимум по коротким, иначе по всем.
    public func barUsed(_ snapshot: Snapshot, at now: Date) -> Double? {
        let windows = visibleWindows(snapshot)
        if let barWindowID, let w = windows.first(where: { $0.id == barWindowID }) { return w.used(at: now) }
        let short = windows.filter(\.isShort)
        return (short.isEmpty ? windows : short).map { $0.used(at: now) }.max()
    }

    /// Самое напряжённое видимое окно — по нему выбирается цвет.
    public func maxUsed(_ snapshot: Snapshot, at now: Date) -> Double? {
        visibleWindows(snapshot).map { $0.used(at: now) }.max()
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
}

public enum UsageError: LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
