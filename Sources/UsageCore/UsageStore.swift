import Foundation
import Observation
import os

/// Account snapshots and the polling schedule. Polling happens only on the timer,
/// on request or after sleep; nothing runs between polls.
/// Only enabled accounts are polled.
@MainActor @Observable
public final class UsageStore {
    public private(set) var accounts: [Account] = []
    public private(set) var snapshots: [UUID: Snapshot] = [:]
    /// Accounts being polled right now → the generation the poll started with.
    public private(set) var inFlight: [UUID: Int] = [:]
    /// Time of the last full poll in which at least one source answered. A completely
    /// failed poll (no network after sleep) does not move it, so the popover retries right away.
    /// A partial poll (`only:`, "Check" or a just-enabled account) does not move it either:
    /// the other accounts were not polled.
    public private(set) var lastRefresh: Date?

    public var isRefreshing: Bool { !inFlight.isEmpty }
    public var enabledAccounts: [Account] { accounts.filter(\.enabled) }

    /// Called after every update (to redraw the menu bar icon).
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Whether a scheduled timer poll is allowed right now; nil means always.
    @ObservationIgnored public var timerGate: (() -> Bool)?

    @ObservationIgnored private let makeSource: (Account) -> any UsageSource
    @ObservationIgnored private var timer: Timer?
    /// The account generation grows on disable, removal and directory change: the result of a poll
    /// started in an earlier generation is not stored (even if everything was later set back).
    @ObservationIgnored private var generation: [UUID: Int] = [:]

    private func gen(_ id: UUID) -> Int { generation[id, default: 0] }
    @ObservationIgnored private let log = Logger(subsystem: "ru.batrakov.UsageWidget", category: "refresh")

    public init(makeSource: @escaping (Account) -> any UsageSource = Catalog.source(for:)) {
        self.makeSource = makeSource
    }

    public func snapshot(_ id: UUID) -> Snapshot { snapshots[id] ?? Snapshot() }

    /// New account list. Snapshots of removed and disabled accounts are dropped: a disabled
    /// account's data goes stale, and after enabling it is polled again.
    /// Returns ids of accounts worth polling right away (new and just enabled).
    @discardableResult
    public func setAccounts(_ new: [Account]) -> Set<UUID> {
        let wasEnabled = Set(enabledAccounts.map(\.id))
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        // The config directory or API key changed: effectively another account, the old data is not its own.
        var changedSource: Set<UUID> = []
        for old in accounts {
            let now = newByID[old.id]
            let dirChanged = now.map { !$0.sameSource(as: old) } ?? false
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

    /// The nearest future reset among windows of enabled accounts. The app schedules a one-off
    /// poll for it so the icon does not show an exhausted limit until the next scheduled poll.
    public func nextReset(after now: Date) -> Date? {
        enabledAccounts.flatMap { $0.visibleWindows(snapshot($0.id)) }
            .compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// There is a visible window whose reset has passed, with no fresh data since.
    public func hasPassedReset(at now: Date) -> Bool {
        enabledAccounts.contains { account in
            let snap = snapshot(account.id)
            return account.visibleWindows(snap).contains { window in
                guard let reset = window.resetsAt, reset <= now else { return false }
                return snap.fetchedAt.map { $0 < reset } ?? true
            }
        }
    }

    /// Restarts the timer; nil means auto-refresh is off.
    /// 10% tolerance lets the system coalesce wakeups.
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

    /// Scheduled poll; `timerGate` may skip it (low-power mode).
    public func timerTick() async {
        if let timerGate, !timerGate() {
            log.info("timer tick skipped")
            return
        }
        await refresh()
    }

    /// Refresh if the data is older than `age` seconds (popover opening).
    public func refreshIfStale(olderThan age: TimeInterval) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        await refresh()
    }

    /// Polls enabled accounts in parallel (`only` is a subset).
    /// An account already being polled in the current generation is skipped; a poll from an earlier
    /// generation (directory changed, disabled and re-enabled) does not block the new one.
    /// A failed source keeps its previous data and gets an error text.
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
                // Only its own poll clears the "in progress" mark: a newer one may have started already.
                if inFlight[account.id] == startedGen { inFlight[account.id] = nil }
                // While the poll ran, the account may have been disabled, removed or given another directory:
                // then the result belongs to the earlier generation and is not needed.
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
