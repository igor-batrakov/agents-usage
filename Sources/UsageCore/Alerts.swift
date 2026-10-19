import Foundation

/// When to notify: a window reached the threshold, and a window that reached it has reset.
/// Pure logic, covered by tests; the app does the delivery.
public enum Alerts {
    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case threshold, reset }
        public let kind: Kind
        public let accountName: String
        public let windowTitle: String
        public let used: Double
        public let resetsAt: Date?
    }

    /// Windows already warned about (`<account id>/<source>/<window id>`, source is `sourceTag`:
    /// config directory and key revision) → their reset time; `distantFuture` if the API gives no reset time.
    /// Persisted across launches. A changed source is effectively another account, old entries are not its own.
    public typealias State = [String: Date]

    /// A reset we learn about later than this (the app was closed) is no longer news.
    static let resetNewsAge: TimeInterval = 3600

    /// At most once per window: a warned window waits for its reset. Hidden windows and
    /// disabled accounts never notify, their entries are dropped. An account with no data
    /// (first load in progress) keeps its entries.
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
                    // The period changed early (a free Codex reset): that is a reset too. One minute of slack:
                    // the reset time can drift by seconds between polls.
                    let periodChanged = window.resetsAt.map { abs($0.timeIntervalSince(resetAt)) > 60 } ?? false
                    // Same period: keep the latest reset time. Otherwise a few seconds of forward drift
                    // would produce a false reset between the old and new time, and a repeated threshold.
                    if !periodChanged, let latest = window.resetsAt { resetAt = latest }
                    warned = resetAt
                    if resetAt <= now || periodChanged {
                        if now.timeIntervalSince(resetAt) < resetNewsAge { events.append(event(.reset)) }
                        warned = nil
                    }
                }
                // Threshold uses the rounded percentage, same as the label and the bar color.
                let over = (used * 100).rounded() >= limit
                if over, warned == nil {
                    events.append(event(.threshold))
                    warned = window.resetsAt ?? .distantFuture
                } else if warned == .distantFuture {
                    if let resetsAt = window.resetsAt {
                        warned = resetsAt  // a reset time appeared: wait for it from now on, as usual
                    } else if !over {
                        warned = nil  // no reset time: the window re-arms once usage drops below the threshold
                    }
                }
                next[key] = warned
            }
        }
        state = next
        return events
    }
}

/// Low-power polling on the timer.
public enum PollPolicy {
    /// A scheduled poll is skipped while the screen is locked or the display is asleep (after
    /// unlock the app polls if the data is stale). On battery, roughly once every three
    /// intervals: the timer fires every interval and `lastRefresh` is set at the end of the
    /// poll, seconds after the tick, so the cutoff is 2.5 intervals rather than 3.
    public static func timerShouldPoll(lastRefresh: Date?, now: Date, interval: TimeInterval,
                                       screenIdle: Bool, onBattery: Bool) -> Bool {
        if screenIdle { return false }
        guard onBattery, let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= interval * 2.5
    }
}
