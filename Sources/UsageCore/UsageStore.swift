import Foundation
import Observation
import os

/// Снимки всех источников и расписание опроса. Опрос — только по таймеру,
/// по запросу или после сна; между опросами ничего не работает.
@MainActor @Observable
public final class UsageStore {
    public private(set) var snapshots: [Provider: Snapshot] = [:]
    public private(set) var isRefreshing = false
    /// Время последнего опроса, в котором ответил хотя бы один источник. Полностью
    /// неудачный опрос (нет сети после сна) его не сдвигает — поповер повторит опрос сразу.
    public private(set) var lastRefresh: Date?

    /// Вызывается после каждого обновления (перерисовать иконку в строке меню).
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let sources: [any UsageSource]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "ru.batrakov.UsageWidget", category: "refresh")

    public init(sources: [any UsageSource] = [ClaudeSource(), CodexSource(), AgySource()]) {
        self.sources = sources
    }

    public func snapshot(_ provider: Provider) -> Snapshot { snapshots[provider] ?? Snapshot() }

    /// Ближайший будущий сброс среди всех окон — к нему приложение планирует разовый опрос,
    /// чтобы иконка не держала исчерпанный лимит до следующего планового.
    public func nextReset(after now: Date) -> Date? {
        snapshots.values.flatMap { $0.report?.windows ?? [] }
            .compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// Перезапускает таймер с новым интервалом. Допуск 10% даёт системе объединять пробуждения.
    public func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Обновить, если данные старше `age` секунд (открытие поповера).
    public func refreshIfStale(olderThan age: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        await refresh()
    }

    /// Опрос всех источников параллельно. Повторный вызов во время опроса игнорируется.
    /// Упавший источник сохраняет прошлые данные и получает текст ошибки.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        log.info("refresh start")
        var anySuccess = false
        defer {
            isRefreshing = false
            if anySuccess { lastRefresh = Date() }
            onChange?()
        }
        await withTaskGroup(of: (Provider, Result<UsageReport, Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source.provider, .success(try await source.fetch())) }
                    catch { return (source.provider, .failure(error)) }
                }
            }
            for await (provider, result) in group {
                var snap = snapshots[provider] ?? Snapshot()
                switch result {
                case .success(let report):
                    snap = Snapshot(report: report, fetchedAt: Date(), error: nil)
                    anySuccess = true
                    log.info("\(provider.rawValue, privacy: .public) ok: \(report.windows.count) windows")
                case .failure(let error):
                    snap.error = error.localizedDescription
                    log.error("\(provider.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                snapshots[provider] = snap
                onChange?()
            }
        }
    }
}
