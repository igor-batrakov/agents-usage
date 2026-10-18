import Foundation
import Testing
@testable import UsageCore

/// Источник со сценарием: по очереди отдаёт заданные результаты, считает вызовы.
private final class ScriptedSource: UsageSource, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var script: [Result<UsageReport, Error>]
    private(set) var calls = 0
    let delay: Duration

    init(_ provider: Provider, _ script: [Result<UsageReport, Error>], delay: Duration = .zero) {
        self.provider = provider
        self.script = script
        self.delay = delay
    }

    func fetch() async throws -> UsageReport {
        let next: Result<UsageReport, Error> = lock.withLock {
            calls += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        try await Task.sleep(for: delay)
        return try next.get()
    }
}

private let report = UsageReport(windows: [
    LimitWindow(id: "w", title: "5 часов", used: 0.3, resetsAt: nil, isShort: true),
], plan: "Pro")

@MainActor @Suite struct UsageStoreTests {
    @Test func failureKeepsPreviousDataAndSetsError() async {
        let source = ScriptedSource(.claude, [.success(report), .failure(UsageError.message("сеть"))])
        let store = UsageStore(sources: [source])

        await store.refresh()
        #expect(store.snapshot(.claude).report == report)
        #expect(store.snapshot(.claude).error == nil)
        let firstFetch = store.snapshot(.claude).fetchedAt

        await store.refresh()
        #expect(store.snapshot(.claude).report == report)
        #expect(store.snapshot(.claude).error == "сеть")
        #expect(store.snapshot(.claude).fetchedAt == firstFetch)
    }

    @Test func successClearsError() async {
        let source = ScriptedSource(.codex, [.failure(UsageError.message("x")), .success(report)])
        let store = UsageStore(sources: [source])
        await store.refresh()
        #expect(store.snapshot(.codex).report == nil)
        #expect(store.snapshot(.codex).error == "x")
        await store.refresh()
        #expect(store.snapshot(.codex).error == nil)
        #expect(store.snapshot(.codex).report == report)
    }

    @Test func concurrentRefreshIsIgnored() async {
        let source = ScriptedSource(.agy, [.success(report)], delay: .milliseconds(200))
        let store = UsageStore(sources: [source])
        async let a: Void = store.refresh()
        async let b: Void = store.refresh()
        _ = await (a, b)
        #expect(source.calls == 1)
    }

    @Test func staleCheckSkipsFreshData() async {
        let source = ScriptedSource(.claude, [.success(report)])
        let store = UsageStore(sources: [source])
        await store.refresh()
        await store.refreshIfStale(olderThan: 60)
        #expect(source.calls == 1)
    }

    @Test func totalFailureDoesNotMarkFresh() async {
        let source = ScriptedSource(.claude, [.failure(UsageError.message("нет сети"))])
        let store = UsageStore(sources: [source])
        await store.refresh()
        #expect(store.lastRefresh == nil)
        await store.refreshIfStale(olderThan: 60)
        #expect(source.calls == 2)
    }

    @Test func nextResetIsNearestFuture() async {
        let now = Date()
        let r = UsageReport(windows: [
            LimitWindow(id: "past", title: "a", used: 1, resetsAt: now.addingTimeInterval(-10), isShort: true),
            LimitWindow(id: "far", title: "b", used: 1, resetsAt: now.addingTimeInterval(7200), isShort: false),
            LimitWindow(id: "near", title: "c", used: 1, resetsAt: now.addingTimeInterval(600), isShort: true),
        ], plan: nil)
        let store = UsageStore(sources: [ScriptedSource(.claude, [.success(r)])])
        #expect(store.nextReset(after: now) == nil)
        await store.refresh()
        #expect(store.nextReset(after: now) == now.addingTimeInterval(600))
    }

    @Test func onChangeFiresPerSourceAndAtEnd() async {
        let store = UsageStore(sources: [ScriptedSource(.claude, [.success(report)]),
                                         ScriptedSource(.codex, [.success(report)])])
        var count = 0
        store.onChange = { count += 1 }
        await store.refresh()
        #expect(count == 3)
        #expect(store.isRefreshing == false)
        #expect(store.lastRefresh != nil)
    }
}
