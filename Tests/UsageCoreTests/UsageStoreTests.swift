import Foundation
import Testing
@testable import UsageCore

/// Источник со сценарием: по очереди отдаёт заданные результаты, считает вызовы.
private final class ScriptedSource: UsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<UsageReport, Error>]
    private var count = 0
    let delay: Duration

    var calls: Int { lock.withLock { count } }

    init(_ script: [Result<UsageReport, Error>], delay: Duration = .zero) {
        self.script = script
        self.delay = delay
    }

    func fetch() async throws -> UsageReport {
        let next: Result<UsageReport, Error> = lock.withLock {
            count += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        try await Task.sleep(for: delay)
        return try next.get()
    }
}

private let report = UsageReport(windows: [
    LimitWindow(id: "w", title: "5 часов", used: 0.3, resetsAt: nil, isShort: true),
], plan: "Pro")

/// Стор с одним скриптованным источником на аккаунт.
@MainActor
private func makeStore(_ sources: [UUID: ScriptedSource]) -> UsageStore {
    UsageStore(makeSource: { sources[$0.id]! })
}

@MainActor @Suite struct UsageStoreTests {
    @Test func failureKeepsPreviousDataAndSetsError() async {
        let a = Account(kind: .claude)
        let store = makeStore([a.id: ScriptedSource([.success(report), .failure(UsageError.message("сеть"))])])
        store.setAccounts([a])

        await store.refresh()
        #expect(store.snapshot(a.id).report == report)
        #expect(store.snapshot(a.id).error == nil)
        let firstFetch = store.snapshot(a.id).fetchedAt

        await store.refresh()
        #expect(store.snapshot(a.id).report == report)
        #expect(store.snapshot(a.id).error == "сеть")
        #expect(store.snapshot(a.id).fetchedAt == firstFetch)
    }

    @Test func successClearsError() async {
        let a = Account(kind: .codex)
        let store = makeStore([a.id: ScriptedSource([.failure(UsageError.message("x")), .success(report)])])
        store.setAccounts([a])
        await store.refresh()
        #expect(store.snapshot(a.id).report == nil)
        #expect(store.snapshot(a.id).error == "x")
        await store.refresh()
        #expect(store.snapshot(a.id).error == nil)
        #expect(store.snapshot(a.id).report == report)
    }

    @Test func concurrentRefreshOfSameAccountIsSkipped() async {
        let a = Account(kind: .agy)
        let source = ScriptedSource([.success(report)], delay: .milliseconds(200))
        let store = makeStore([a.id: source])
        store.setAccounts([a])
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        #expect(source.calls == 1)
        #expect(!store.isRefreshing)
    }

    @Test func disabledAccountsAreNotPolled() async {
        let on = Account(kind: .claude), off = Account(kind: .codex, enabled: false)
        let sOn = ScriptedSource([.success(report)]), sOff = ScriptedSource([.success(report)])
        let store = makeStore([on.id: sOn, off.id: sOff])
        store.setAccounts([on, off])
        await store.refresh()
        #expect(sOn.calls == 1)
        #expect(sOff.calls == 0)
        #expect(store.snapshots[off.id] == nil)
    }

    @Test func refreshOnlyPollsSubsetAndKeepsStaleCheck() async {
        let a = Account(kind: .claude), b = Account(kind: .codex)
        let sa = ScriptedSource([.success(report)]), sb = ScriptedSource([.success(report)])
        let store = makeStore([a.id: sa, b.id: sb])
        store.setAccounts([a, b])
        await store.refresh(only: [b.id])
        #expect(sa.calls == 0)
        #expect(sb.calls == 1)
        // Частичный опрос не считается «данные свежие»: a ещё не опрашивался.
        #expect(store.lastRefresh == nil)
        await store.refreshIfStale(olderThan: 60)
        #expect(sa.calls == 1)
    }

    @Test func setAccountsReportsNewlyEnabledAndDropsDisabled() async {
        var a = Account(kind: .claude)
        let b = Account(kind: .codex)
        let store = makeStore([a.id: ScriptedSource([.success(report)]), b.id: ScriptedSource([.success(report)])])
        #expect(store.setAccounts([a]) == [a.id])
        await store.refresh()
        #expect(store.snapshots[a.id] != nil)

        // Добавили b — опросить сразу только его.
        #expect(store.setAccounts([a, b]) == [b.id])

        // Выключили a — снимок пропал, опрашивать нечего.
        a.enabled = false
        #expect(store.setAccounts([a, b]).isEmpty)
        #expect(store.snapshots[a.id] == nil)

        // Включили обратно — снова в списке на опрос.
        a.enabled = true
        #expect(store.setAccounts([a, b]) == [a.id])
    }

    @Test func changingConfigDirDropsSnapshotAndRequestsPoll() async {
        var a = Account(kind: .claude)
        let store = makeStore([a.id: ScriptedSource([.success(report)])])
        store.setAccounts([a])
        await store.refresh()
        a.configDir = "~/.claude-work"
        #expect(store.setAccounts([a]) == [a.id])
        #expect(store.snapshots[a.id] == nil)
    }

    @Test func resultOfRemovedAccountIsDiscarded() async {
        let a = Account(kind: .claude)
        let store = makeStore([a.id: ScriptedSource([.success(report)], delay: .milliseconds(200))])
        store.setAccounts([a])
        async let polling: Void = store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        store.setAccounts([])
        await polling
        #expect(store.snapshots[a.id] == nil)
    }

    @Test func disableAndReenableDuringFetchDiscardsOldResult() async {
        var a = Account(kind: .claude)
        let old = UsageReport(windows: [LimitWindow(id: "old", title: "o", used: 0.9, resetsAt: nil, isShort: true)], plan: nil)
        let source = ScriptedSource([.success(old), .success(report)], delay: .milliseconds(200))
        let store = makeStore([a.id: source])
        store.setAccounts([a])
        async let first: Void = store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        a.enabled = false
        store.setAccounts([a])
        a.enabled = true
        store.setAccounts([a])
        await first
        #expect(store.snapshots[a.id] == nil)
    }

    @Test func configDirChangeDuringFetchStartsReplacementPoll() async {
        var a = Account(kind: .claude)
        let old = UsageReport(windows: [LimitWindow(id: "old", title: "o", used: 0.9, resetsAt: nil, isShort: true)], plan: nil)
        let source = ScriptedSource([.success(old), .success(report)], delay: .milliseconds(200))
        let store = makeStore([a.id: source])
        store.setAccounts([a])
        async let first: Void = store.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        a.configDir = "~/.claude-work"
        #expect(store.setAccounts([a]) == [a.id])
        // Старый опрос ещё идёт — новый всё равно запускается, а не пропускается.
        async let second: Void = store.refresh(only: [a.id])
        _ = await (first, second)
        #expect(source.calls == 2)
        #expect(store.snapshot(a.id).report == report)
        #expect(!store.isRefreshing)
    }

    @Test func totalFailureDoesNotMarkFresh() async {
        let a = Account(kind: .claude)
        let source = ScriptedSource([.failure(UsageError.message("нет сети"))])
        let store = makeStore([a.id: source])
        store.setAccounts([a])
        await store.refresh()
        #expect(store.lastRefresh == nil)
        await store.refreshIfStale(olderThan: 60)
        #expect(source.calls == 2)
    }

    @Test func staleCheckSkipsFreshData() async {
        let a = Account(kind: .claude)
        let source = ScriptedSource([.success(report)])
        let store = makeStore([a.id: source])
        store.setAccounts([a])
        await store.refresh()
        await store.refreshIfStale(olderThan: 60)
        #expect(source.calls == 1)
    }

    @Test func nextResetIsNearestFutureOfVisibleWindows() async {
        let now = Date()
        let r = UsageReport(windows: [
            LimitWindow(id: "past", title: "a", used: 1, resetsAt: now.addingTimeInterval(-10), isShort: true),
            LimitWindow(id: "far", title: "b", used: 1, resetsAt: now.addingTimeInterval(7200), isShort: false),
            LimitWindow(id: "near", title: "c", used: 1, resetsAt: now.addingTimeInterval(600), isShort: true),
        ], plan: nil)
        var a = Account(kind: .claude)
        let store = makeStore([a.id: ScriptedSource([.success(r)])])
        store.setAccounts([a])
        #expect(store.nextReset(after: now) == nil)
        await store.refresh()
        #expect(store.nextReset(after: now) == now.addingTimeInterval(600))
        a.hiddenWindows = ["near"]
        store.setAccounts([a])
        #expect(store.nextReset(after: now) == now.addingTimeInterval(7200))
    }

    @Test func onChangeFiresPerSourceAndAtEnd() async {
        let a = Account(kind: .claude), b = Account(kind: .codex)
        let store = makeStore([a.id: ScriptedSource([.success(report)]), b.id: ScriptedSource([.success(report)])])
        store.setAccounts([a, b])
        var count = 0
        store.onChange = { count += 1 }
        await store.refresh()
        #expect(count == 3)
        #expect(store.lastRefresh != nil)
    }
}
