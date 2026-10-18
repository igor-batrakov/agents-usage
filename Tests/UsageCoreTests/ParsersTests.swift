import Foundation
import Testing
@testable import UsageCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Длины окон: 5 часов и неделя.
private let h5: TimeInterval? = 5 * 3600
private let wk: TimeInterval? = 7 * 86400

@Suite struct ClaudeParserTests {
    @Test func parsesLimitsArrayIncludingScopedModel() throws {
        let r = try Parsers.claude(fixture("claude_usage"), plan: "Max 5x")
        #expect(r.windows.map(\.title) == ["5 hours", "Week", "Week · Fable"])
        #expect(r.windows.map(\.id) == ["claude-session", "claude-weekly_all", "claude-weekly_scoped-Fable"])
        #expect(r.windows[0].used == 0.19)
        #expect(r.windows[0].isShort)
        #expect(r.windows[1].used == 0.35)
        #expect(!r.windows[1].isShort)
        #expect(r.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-18T14:19:59Z"))
        #expect(r.windows.map(\.duration) == [h5, wk, wk])
        #expect(r.plan == "Max 5x")
    }

    @Test func fallsBackToNamedWindows() throws {
        let json = #"{"five_hour":{"utilization":12.5,"resets_at":"2026-10-18T14:20:00.394710+00:00"},"seven_day":null}"#
        let r = try Parsers.claude(Data(json.utf8), plan: nil)
        #expect(r.windows.count == 1)
        #expect(r.windows[0].used == 0.125)
        #expect(r.windows[0].isShort)
    }

    @Test func emptyResponseIsError() {
        #expect(throws: UsageError.self) { try Parsers.claude(Data("{}".utf8), plan: nil) }
    }

    @Test func planName() {
        #expect(Parsers.claudePlan(subscription: "max", tier: "default_claude_max_5x") == "Max 5x")
        #expect(Parsers.claudePlan(subscription: "pro", tier: nil) == "Pro")
        #expect(Parsers.claudePlan(subscription: nil, tier: "x") == nil)
    }
}

@Suite struct CodexParserTests {
    @Test func parsesPrimaryAndSecondary() throws {
        let r = try Parsers.codex(fixture("codex_ratelimits"))
        #expect(r.windows.map(\.title) == ["5 hours", "Week"])
        #expect(r.windows[0].used == 0.44)
        #expect(r.windows[0].isShort)
        #expect(r.windows[1].used == 0.22)
        #expect(r.windows[1].resetsAt == Date(timeIntervalSince1970: 1792875605))
        #expect(r.windows.map(\.duration) == [h5, wk])
        #expect(r.plan == "Plus")
    }

    @Test func freeResetsCountAndNearestExpiry() throws {
        let r = try Parsers.codex(fixture("codex_ratelimits"))
        #expect(r.freeResets == FreeResets(count: 3, nextExpiry: Date(timeIntervalSince1970: 1792703236)))
    }

    @Test func noAvailableFreeResetsIsNil() throws {
        let json = #"""
        {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1}},
         "rateLimitResetCredits":{"credits":[{"status":"used","expiresAt":5}]}}}
        """#
        #expect(try Parsers.codex(Data(json.utf8)).freeResets == nil)
    }

    @Test func extraLimitGetsPrefix() throws {
        let json = #"""
        {"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex"},
           "spark":{"limitId":"spark","limitName":"Spark","secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":2}}}}}
        """#
        let r = try Parsers.codex(Data(json.utf8))
        #expect(r.windows.map(\.title) == ["5 hours", "Week · Spark"])
    }

    @Test func rpcErrorIsSurfaced() {
        let json = #"{"id":2,"error":{"code":-32000,"message":"not logged in"}}"#
        #expect(throws: UsageError.message("not logged in")) { try Parsers.codex(Data(json.utf8)) }
    }
}

@Suite struct AgyParserTests {
    @Test func parsesGroupsAndConvertsRemainingToUsed() throws {
        let r = try Parsers.agy(fixture("agy_usage"))
        #expect(r.windows.count == 5)
        #expect(r.windows.map(\.group) == ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT", "Argon"])
        #expect(r.windows.map(\.title) == ["5 hours", "Week", "5 hours", "Week", "Week"])
        let argon = r.windows[4]
        #expect(abs(argon.used - 0.8994) < 0.001)
        #expect(argon.resetsAt == ISO8601DateFormatter().date(from: "2026-10-24T00:16:04Z"))
        #expect(r.windows[0].isShort && !r.windows[1].isShort)
        #expect(abs(r.windows[0].used - 0.0159) < 0.001)
        #expect(r.windows.map(\.duration) == [h5, wk, h5, wk, wk])
    }

    @Test func missingCommandDataIsError() {
        #expect(throws: UsageError.self) { try Parsers.agy(Data(#"{"status":"ERROR"}"#.utf8)) }
    }
}

@Suite struct WindowLogicTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func passedResetMeansEmpty() {
        let w = LimitWindow(id: "a", title: "t", used: 0.8, resetsAt: now.addingTimeInterval(-1), isShort: true)
        #expect(w.used(at: now) == 0)
        let future = LimitWindow(id: "b", title: "t", used: 0.8, resetsAt: now.addingTimeInterval(60), isShort: true)
        #expect(future.used(at: now) == 0.8)
    }

    @Test func paceIsElapsedShareOfWindow() {
        let w = LimitWindow(id: "a", title: "t", used: 0.5, resetsAt: now.addingTimeInterval(3600), isShort: true,
                            duration: 4 * 3600)
        #expect(w.pace(at: now) == 0.75)
        // Сброс прошёл, длина неизвестна — метки нет.
        #expect(w.pace(at: now.addingTimeInterval(3601)) == nil)
        #expect(LimitWindow(id: "b", title: "t", used: 0.5, resetsAt: now.addingTimeInterval(60), isShort: true)
            .pace(at: now) == nil)
    }

    @Test func usedIsClamped() {
        #expect(LimitWindow(id: "a", title: "t", used: 1.4, resetsAt: nil, isShort: true).used == 1)
        #expect(LimitWindow(id: "a", title: "t", used: -0.1, resetsAt: nil, isShort: true).used == 0)
    }

    @Test func formats() {
        #expect(Format.resetIn(now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now) == "in 3d 4h")
        #expect(Format.resetIn(now.addingTimeInterval(72 * 60), now: now) == "in 1h 12m")
        #expect(Format.resetIn(now.addingTimeInterval(4 * 60 + 1), now: now) == "in 5m")
        #expect(Format.resetIn(now.addingTimeInterval(10), now: now) == "in 1m")
        #expect(Format.resetIn(now.addingTimeInterval(-5), now: now) == "reset")
        #expect(Format.percent(0.0074) == "1%")
        #expect(Format.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
    }
}
