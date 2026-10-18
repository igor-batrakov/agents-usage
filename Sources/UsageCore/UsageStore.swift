import Foundation
import Observation
import os

/// Снимки аккаунтов и расписание опроса. Опрос — только по таймеру,
/// по запросу или после сна; между опросами ничего не работает.
/// Опрашиваются только включённые аккаунты.
@MainActor @Observable
public final class UsageStore {
    public private(set) var accounts: [Account] = []
    public private(set) var snapshots: [UUID: Snapshot] = [:]
    /// Аккаунты, опрос которых идёт прямо сейчас, → поколение, с которым опрос начат.
    public private(set) var inFlight: [UUID: Int] = [:]
    /// Время последнего полного опроса, в котором ответил хотя бы один источник. Полностью
    /// неудачный опрос (нет сети после сна) его не сдвигает — поповер повторит опрос сразу.
    /// Частичный опрос (`only:` — «Проверить», только что включённый аккаунт) тоже не сдвигает:
    /// остальные аккаунты при нём не опрашивались.
    public private(set) var lastRefresh: Date?

    public var isRefreshing: Bool { !inFlight.isEmpty }
    public var enabledAccounts: [Account] { accounts.filter(\.enabled) }

    /// Вызывается после каждого обновления (перерисовать иконку в строке меню).
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Разрешён ли плановый опрос по таймеру сейчас; nil — всегда.
    @ObservationIgnored public var timerGate: (() -> Bool)?

    @ObservationIgnored private let makeSource: (Account) -> any UsageSource
    @ObservationIgnored private var timer: Timer?
    /// Поколение аккаунта растёт при выключении, удалении и смене каталога: результат опроса,
    /// начатого в прежнем поколении, не записывается (даже если потом всё вернули как было).
    @ObservationIgnored private var generation: [UUID: Int] = [:]

    private func gen(_ id: UUID) -> Int { generation[id, default: 0] }
    @ObservationIgnored private let log = Logger(subsystem: "ru.batrakov.UsageWidget", category: "refresh")

    public init(makeSource: @escaping (Account) -> any UsageSource = Catalog.source(for:)) {
        self.makeSource = makeSource
    }

    public func snapshot(_ id: UUID) -> Snapshot { snapshots[id] ?? Snapshot() }

    /// Новый список аккаунтов. Снимки удалённых и выключенных отбрасываются: данные
    /// выключенного устаревают, а после включения он опрашивается заново.
    /// Возвращает id аккаунтов, которые стоит опросить сразу (новые и только что включённые).
    @discardableResult
    public func setAccounts(_ new: [Account]) -> Set<UUID> {
        let wasEnabled = Set(enabledAccounts.map(\.id))
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        // Сменился каталог конфигурации — это другой аккаунт по сути, старые данные не его.
        var changedSource: Set<UUID> = []
        for old in accounts {
            let now = newByID[old.id]
            let dirChanged = now.map { $0.configDir != old.configDir } ?? false
            if dirChanged { changedSource.insert(old.id) }
            if now == nil || (old.enabled && now?.enabled == false) || dirChanged {
                generation[old.id, default: 0] += 1
            }
        }
        accounts = new
        let enabled = Set(enabledAccounts.map(\.id))
        snapshots = snapshots.filter { enabled.contains($0.key) && !changedSource.contains($0.key) }
        onChange?()
        return enabled.subtracting(wasEnabled).union(changedSource.intersection(enabled))
    }

    /// Ближайший будущий сброс среди окон включённых аккаунтов — к нему приложение планирует
    /// разовый опрос, чтобы иконка не держала исчерпанный лимит до следующего планового.
    public func nextReset(after now: Date) -> Date? {
        enabledAccounts.flatMap { $0.visibleWindows(snapshot($0.id)) }
            .compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// Есть видимое окно, чей сброс уже прошёл, а свежих данных после него нет.
    public func hasPassedReset(at now: Date) -> Bool {
        enabledAccounts.contains { account in
            let snap = snapshot(account.id)
            return account.visibleWindows(snap).contains { window in
                guard let reset = window.resetsAt, reset <= now else { return false }
                return snap.fetchedAt.map { $0 < reset } ?? true
            }
        }
    }

    /// Перезапускает таймер; nil — автообновление выключено.
    /// Допуск 10% даёт системе объединять пробуждения.
    public func schedule(every interval: TimeInterval?) {
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.timerTick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Плановый опрос; `timerGate` может его пропустить (экономный режим).
    public func timerTick() async {
        if let timerGate, !timerGate() {
            log.info("timer tick skipped")
            return
        }
        await refresh()
    }

    /// Обновить, если данные старше `age` секунд (открытие поповера).
    public func refreshIfStale(olderThan age: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        await refresh()
    }

    /// Опрос включённых аккаунтов параллельно (`only` — подмножество).
    /// Аккаунт, опрос которого уже идёт в текущем поколении, пропускается; опрос прежнего
    /// поколения (сменили каталог, выключили и включили) новому не мешает.
    /// Упавший источник сохраняет прошлые данные и получает текст ошибки.
    public func refresh(only ids: Set<UUID>? = nil) async {
        let targets = enabledAccounts.filter { (ids?.contains($0.id) ?? true) && inFlight[$0.id] != gen($0.id) }
        guard !targets.isEmpty else { return }
        let started = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, gen($0.id)) })
        inFlight.merge(started) { _, new in new }
        log.info("refresh start: \(targets.count) accounts")
        var anySuccess = false
        defer {
            if anySuccess, ids == nil { lastRefresh = Date() }
            onChange?()
        }
        await withTaskGroup(of: (Account, Result<UsageReport, Error>).self) { group in
            for account in targets {
                let source = makeSource(account)
                group.addTask {
                    do { return (account, .success(try await source.fetch())) }
                    catch { return (account, .failure(error)) }
                }
            }
            for await (account, result) in group {
                let startedGen = started[account.id]!
                // Метку «в работе» снимает только свой опрос: более новый мог уже начаться.
                if inFlight[account.id] == startedGen { inFlight[account.id] = nil }
                // Пока шёл опрос, аккаунт могли выключить, удалить или сменить ему каталог —
                // тогда результат относится к прежнему поколению и не нужен.
                guard gen(account.id) == startedGen, enabledAccounts.contains(where: { $0.id == account.id })
                else { continue }
                var snap = snapshots[account.id] ?? Snapshot()
                switch result {
                case .success(let report):
                    snap = Snapshot(report: report, fetchedAt: Date(), error: nil)
                    anySuccess = true
                    log.info("\(account.kind.rawValue, privacy: .public) ok: \(report.windows.count) windows")
                case .failure(let error):
                    snap.error = error.localizedDescription
                    log.error("\(account.kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                snapshots[account.id] = snap
                onChange?()
            }
        }
    }
}
