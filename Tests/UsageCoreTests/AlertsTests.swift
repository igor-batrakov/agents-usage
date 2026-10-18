import Foundation
import Testing
@testable import UsageCore

@Suite struct AlertsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let account = Account(kind: .claude)
    var key: String { "\(account.id)//w" }

    private func snapshot(_ used: Double, resetsAt: Date?, id: String = "w") -> [UUID: Snapshot] {
        [account.id: Snapshot(report: UsageReport(windows: [
            LimitWindow(id: id, title: "5 часов", used: used, resetsAt: resetsAt, isShort: true),
        ], plan: nil), fetchedAt: now)]
    }

    private func run(_ snapshots: [UUID: Snapshot], _ state: inout Alerts.State, at time: Date? = nil,
                     accounts: [Account]? = nil) -> [Alerts.Event.Kind] {
        Alerts.evaluate(accounts: accounts ?? [account], snapshots: snapshots, threshold: 0.9,
                        state: &state, now: time ?? now).map(\.kind)
    }

    @Test func thresholdOncePerWindowThenResetNews() {
        let reset = now.addingTimeInterval(3600)
        var state = Alerts.State()
        #expect(run(snapshot(0.89, resetsAt: reset), &state).isEmpty)
        #expect(run(snapshot(0.92, resetsAt: reset), &state) == [.threshold])
        #expect(run(snapshot(0.97, resetsAt: reset), &state).isEmpty)
        // Сброс прошёл: старые данные уже считаются нулём — одно уведомление о сбросе.
        let after = reset.addingTimeInterval(10)
        #expect(run(snapshot(0.97, resetsAt: reset), &state, at: after) == [.reset])
        #expect(run(snapshot(0.05, resetsAt: reset.addingTimeInterval(18000)), &state, at: after).isEmpty)
    }

    @Test func earlyPeriodChangeIsResetAndRearms() {
        let reset = now.addingTimeInterval(3600)
        var state = Alerts.State()
        #expect(run(snapshot(1, resetsAt: reset), &state) == [.threshold])
        // Сдвиг времени сброса на секунды — тот же период.
        #expect(run(snapshot(1, resetsAt: reset.addingTimeInterval(1)), &state).isEmpty)
        // Бесплатный сброс: новое окно на 5 часов — уведомление о сбросе, порог снова взведён.
        let fresh = now.addingTimeInterval(5 * 3600)
        #expect(run(snapshot(0, resetsAt: fresh), &state) == [.reset])
        #expect(run(snapshot(0.95, resetsAt: fresh), &state) == [.threshold])
    }

    @Test func resetTimeDriftingForwardIsNotReset() {
        let reset = now.addingTimeInterval(3600)
        var state = Alerts.State()
        #expect(run(snapshot(1, resetsAt: reset), &state) == [.threshold])
        #expect(run(snapshot(1, resetsAt: reset.addingTimeInterval(30)), &state).isEmpty)
        // Между старым и новым временем сброса — ни сброса, ни повторного порога.
        #expect(run(snapshot(1, resetsAt: reset.addingTimeInterval(30)), &state, at: reset.addingTimeInterval(10)).isEmpty)
        #expect(run(snapshot(1, resetsAt: reset.addingTimeInterval(30)), &state, at: reset.addingTimeInterval(40)) == [.reset])
    }

    @Test func resetTimeAppearingAfterWarningIsAdopted() {
        let reset = now.addingTimeInterval(3600)
        var state = Alerts.State()
        #expect(run(snapshot(0.95, resetsAt: nil), &state) == [.threshold])
        #expect(run(snapshot(0.95, resetsAt: reset), &state).isEmpty)
        #expect(run(snapshot(0.95, resetsAt: reset), &state, at: reset.addingTimeInterval(10)) == [.reset])
    }

    @Test func configDirChangeDropsState() {
        var state: Alerts.State = [key: now.addingTimeInterval(3600)]
        var moved = account
        moved.configDir = "~/.claude-work"
        // Пока новый каталог грузится, старые записи не держим; его данные — с чистого листа.
        #expect(run([:], &state, accounts: [moved]).isEmpty)
        #expect(state.isEmpty)
        #expect(run(snapshot(0.95, resetsAt: now.addingTimeInterval(7200)), &state, accounts: [moved]) == [.threshold])
    }

    @Test func keyRevisionChangeDropsState() {
        var state: Alerts.State = [key: now.addingTimeInterval(3600)]
        var rekeyed = account
        rekeyed.keyRevision = 1
        #expect(run(snapshot(0.95, resetsAt: now.addingTimeInterval(3600)), &state, accounts: [rekeyed]) == [.threshold])
        #expect(state.keys.sorted() == ["\(account.id)/#1/w"])
    }

    @Test func roundedPercentReachesThreshold() {
        var state = Alerts.State()
        // В подписи «90%» — значит порог достигнут.
        #expect(run(snapshot(0.896, resetsAt: nil), &state) == [.threshold])
    }

    @Test func staleResetIsNotNews() {
        let reset = now.addingTimeInterval(-2 * 3600)
        var state: Alerts.State = [key: reset]
        #expect(run(snapshot(0.1, resetsAt: now.addingTimeInterval(3600)), &state).isEmpty)
        #expect(state.isEmpty)
    }

    @Test func noResetTimeRearmsWhenUsageDrops() {
        var state = Alerts.State()
        #expect(run(snapshot(0.95, resetsAt: nil), &state) == [.threshold])
        #expect(run(snapshot(0.5, resetsAt: nil), &state).isEmpty)
        #expect(run(snapshot(0.95, resetsAt: nil), &state) == [.threshold])
    }

    @Test func hiddenWindowAndDisabledAccountAreSilent() {
        var hidden = account
        hidden.hiddenWindows = ["w"]
        var state = Alerts.State()
        #expect(run(snapshot(0.99, resetsAt: nil), &state, accounts: [hidden]).isEmpty)
        var off = account
        off.enabled = false
        state = [key: .distantFuture]
        #expect(run(snapshot(0.99, resetsAt: nil), &state, accounts: [off]).isEmpty)
        #expect(state.isEmpty)
    }

    @Test func accountWithoutDataKeepsState() {
        var state: Alerts.State = [key: now.addingTimeInterval(60)]
        #expect(run([:], &state).isEmpty)
        #expect(state.count == 1)
    }
}

@Suite struct PollPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func idleScreenSkipsBatteryThrottles() {
        let recent = now.addingTimeInterval(-300)
        #expect(!PollPolicy.timerShouldPoll(lastRefresh: recent, now: now, interval: 300, screenIdle: true, onBattery: false))
        #expect(PollPolicy.timerShouldPoll(lastRefresh: recent, now: now, interval: 300, screenIdle: false, onBattery: false))
        #expect(!PollPolicy.timerShouldPoll(lastRefresh: recent, now: now, interval: 300, screenIdle: false, onBattery: true))
        // Третий тик от батареи — опрос (lastRefresh стоит на секунды позже тика).
        let threeTicks = now.addingTimeInterval(-3 * 300 + 5)
        #expect(PollPolicy.timerShouldPoll(lastRefresh: threeTicks, now: now, interval: 300, screenIdle: false, onBattery: true))
        #expect(PollPolicy.timerShouldPoll(lastRefresh: nil, now: now, interval: 300, screenIdle: false, onBattery: true))
    }
}
