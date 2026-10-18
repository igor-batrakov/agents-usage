import Foundation

/// Тип источника — запись каталога. Код опроса у каждого свой (`Catalog.source`).
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

    /// Страница лимитов у вендора; nil — веб-страницы нет.
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

    /// Переменная окружения с каталогом конфигурации — она различает аккаунты одного сервиса.
    /// nil — аккаунт у сервиса один.
    public var configDirVariable: String? {
        switch self {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        default: nil
        }
    }

    /// Вход по API-ключу из консоли вендора (хранится в Связке ключей, `KeyStore`), а не через CLI.
    public var usesAPIKey: Bool {
        switch self {
        case .kimi, .openrouter, .moonshot: true
        default: false
        }
    }

    /// Где выпустить ключ.
    public var apiKeysURL: URL? {
        switch self {
        case .kimi: URL(string: "https://www.kimi.com/code/console")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .moonshot: URL(string: "https://platform.moonshot.ai/console/api-keys")
        default: nil
        }
    }

    /// Несколько аккаунтов — у сервисов с каталогом конфигурации или ключом (ключ на аккаунт).
    public var allowsMultipleAccounts: Bool { configDirVariable != nil || usesAPIKey }
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
    /// Растёт при каждой смене API-ключа (сам ключ — в `KeyStore`). Для стора и уведомлений это смена
    /// источника, как смена каталога: опрос со старым ключом отбрасывается. Optional — старые
    /// сохранённые аккаунты без этого поля читаются как есть.
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

    /// Откуда берутся данные аккаунта, кроме его типа: сменилось — это по сути другой аккаунт.
    public func sameSource(as other: Account) -> Bool {
        configDir == other.configDir && keyRevision == other.keyRevision
    }

    /// То же для ключей состояния уведомлений: без ключа API — прежний вид (каталог).
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

    /// У сервиса только баланс, окон лимита нет: полоска в строке меню у него была бы всегда пустой.
    /// Moonshot — по типу (окон у него не бывает: до первого ответа и при ошибке тоже), остальные —
    /// по ответу (OpenRouter без бюджета ключа).
    public func balanceOnly(_ snapshot: Snapshot) -> Bool {
        if kind == .moonshot { return true }
        guard let report = snapshot.report else { return false }
        return report.windows.isEmpty && !report.balances.isEmpty
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
    /// Длина окна, с; nil — неизвестна (тогда нет метки темпа).
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

    /// Если время сброса уже прошло, окно считается пустым до следующего опроса.
    public func used(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return used
    }

    /// Темп: какая доля окна по времени уже прошла, 0…1. Расход выше темпа — лимит кончится до сброса.
    /// nil — длина или время сброса неизвестны, либо сброс уже прошёл.
    public func pace(at now: Date) -> Double? {
        guard let duration, duration > 0, let resetsAt, resetsAt > now else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
    }
}

/// Бесплатные сбросы лимита (у Codex — «Full reset»): сколько доступно и когда сгорит ближайший.
public struct FreeResets: Sendable, Equatable {
    public let count: Int
    public let nextExpiry: Date?

    public init(count: Int, nextExpiry: Date?) {
        self.count = count
        self.nextExpiry = nextExpiry
    }
}

/// Денежная метрика без доли (баланс счёта): показывается строкой рядом с окнами лимита.
public struct Balance: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// В единицах валюты (доллары, юани), не в центах.
    public let amount: Double
    /// Код ISO 4217: USD, CNY.
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
    /// Процесс вышел с ненулевым кодом: по коду вызывающий различает исходы (у `security` 44 — «элемента нет»).
    case exit(tool: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .exit(let tool, let status): L("%@: exit code %d", tool, status)
        }
    }
}
