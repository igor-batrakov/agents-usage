import Foundation

/// Когда уведомлять: окно дошло до порога и окно, дошедшее до порога, сбросилось.
/// Чистая логика — под тесты; доставку делает приложение.
public enum Alerts {
    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case threshold, reset }
        public let kind: Kind
        public let accountName: String
        public let windowTitle: String
        public let used: Double
        public let resetsAt: Date?
    }

    /// Окна, о которых уже предупредили (`<id аккаунта>/<источник>/<id окна>`, источник — `sourceTag`:
    /// каталог и ревизия ключа) → время их сброса; `distantFuture` — API время сброса не отдаёт.
    /// Хранится между запусками. Сменили источник — это другой аккаунт по сути, прежние записи не его.
    public typealias State = [String: Date]

    /// Сброс, о котором узнали позже этого (приложение было закрыто), уже не новость.
    static let resetNewsAge: TimeInterval = 3600

    /// Не чаще раза за окно: предупреждённое окно ждёт своего сброса. Скрытые окна и
    /// выключенные аккаунты не уведомляют, их записи выбрасываются. Аккаунт без данных
    /// (идёт первая загрузка) свои записи сохраняет.
    public static func evaluate(accounts: [Account], snapshots: [UUID: Snapshot], threshold: Double,
                                state: inout State, now: Date) -> [Event] {
        var events: [Event] = []
        var next = State()
        let limit = (threshold * 100).rounded()
        for account in accounts where account.enabled {
            let prefix = "\(account.id)/\(account.sourceTag)/"
            guard let snapshot = snapshots[account.id], snapshot.report != nil else {
                for (key, value) in state where key.hasPrefix(prefix) { next[key] = value }
                continue
            }
            for window in account.visibleWindows(snapshot) {
                let key = prefix + window.id
                var warned = state[key]
                let used = window.used(at: now)
                func event(_ kind: Event.Kind) -> Event {
                    Event(kind: kind, accountName: account.name, windowTitle: window.fullTitle,
                          used: used, resetsAt: window.resetsAt)
                }
                if var resetAt = warned, resetAt != .distantFuture {
                    // Период сменился раньше срока (бесплатный сброс Codex) — тоже сброс. Допуск в минуту:
                    // время сброса от опроса к опросу может гулять на секунды.
                    let periodChanged = window.resetsAt.map { abs($0.timeIntervalSince(resetAt)) > 60 } ?? false
                    // Тот же период — держим последнее время сброса: иначе сдвиг вперёд на секунды
                    // дал бы между старым и новым временем ложный сброс и повторный порог.
                    if !periodChanged, let latest = window.resetsAt { resetAt = latest }
                    warned = resetAt
                    if resetAt <= now || periodChanged {
                        if now.timeIntervalSince(resetAt) < resetNewsAge { events.append(event(.reset)) }
                        warned = nil
                    }
                }
                // Порог — по округлённому проценту, как в подписи и цвете полоски.
                let over = (used * 100).rounded() >= limit
                if over, warned == nil {
                    events.append(event(.threshold))
                    warned = window.resetsAt ?? .distantFuture
                } else if warned == .distantFuture {
                    if let resetsAt = window.resetsAt {
                        warned = resetsAt  // время сброса появилось — дальше ждём его, как обычно
                    } else if !over {
                        warned = nil  // без времени сброса окно снова «взводится», когда расход упал ниже порога
                    }
                }
                next[key] = warned
            }
        }
        state = next
        return events
    }
}

/// Экономный опрос по таймеру.
public enum PollPolicy {
    /// Плановый опрос пропускается, пока экран заблокирован или дисплей спит (после
    /// разблокировки приложение опрашивает, если данные устарели). От батареи — примерно
    /// раз в три интервала: таймер тикает каждый интервал, а `lastRefresh` ставится в конце
    /// опроса, на секунды позже тика, поэтому граница — 2,5 интервала, а не 3.
    public static func timerShouldPoll(lastRefresh: Date?, now: Date, interval: TimeInterval,
                                       screenIdle: Bool, onBattery: Bool) -> Bool {
        if screenIdle { return false }
        guard onBattery, let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval * 2.5
    }
}
