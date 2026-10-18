import Foundation
import Testing
@testable import UsageCore

/// Длины месяцев — константами: литерал-произведение внутри `#expect` сравнивается не как TimeInterval?.
private let days31: TimeInterval? = 31 * 86400
private let days30: TimeInterval? = 30 * 86400

@Suite struct CopilotParserTests {
    @Test func monthlyQuotasSkipZeroEntitlement() throws {
        let r = try Parsers.copilot(fixture("copilot_user"))
        // Премиум на бесплатном плане — объём 0, не показываем.
        #expect(r.windows.map(\.id) == ["copilot-chat", "copilot-completions"])
        #expect(r.windows.map(\.title) == ["Chat", "Completions"])
        #expect(r.windows[0].used == 0)
        #expect(abs(r.windows[1].used - 0.006) < 1e-9)
        let reset = try #require(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(r.windows[1].resetsAt == reset)
        // Октябрь — 31 день.
        #expect(r.windows[1].duration == days31)
        #expect(r.plan == "Free")
    }

    @Test func unlimitedIsSkippedAndNoQuotasIsError() {
        let json = #"{"quota_snapshots":{"chat":{"unlimited":true,"entitlement":0,"percent_remaining":100}}}"#
        #expect(throws: UsageError.self) { try Parsers.copilot(Data(json.utf8)) }
    }
}

@Suite struct CursorParserTests {
    @Test func freePlanFromLiveFixture() throws {
        let r = try Parsers.cursor(fixture("cursor_usage_summary"))
        #expect(r.windows.map(\.id) == ["cursor-plan", "cursor-auto", "cursor-api"])
        #expect(r.windows.allSatisfy { $0.used == 0 })
        #expect(r.plan == "Free")
        // Окно — расчётный период: от начала до конца.
        let end = try #require(ISO8601DateFormatter().date(from: "2026-11-01T16:57:17Z"))
        #expect(r.windows[0].resetsAt == end)
        #expect(r.windows[0].duration == days31)
        #expect(r.balances.isEmpty)
    }

    @Test func percentsArePercentUnitsAndOnDemandWithLimit() throws {
        let json = #"""
        {"billingCycleStart":"2025-01-01T00:00:00.000Z","billingCycleEnd":"2025-02-01T00:00:00.000Z","membershipType":"pro",
         "individualUsage":{"plan":{"enabled":true,"used":1500,"limit":5000,"remaining":3500,"totalPercentUsed":30.0},
         "onDemand":{"enabled":true,"used":500,"limit":10000,"remaining":9500}}}
        """#
        let r = try Parsers.cursor(Data(json.utf8))
        #expect(r.windows.map(\.id) == ["cursor-plan", "cursor-on-demand"])
        #expect(r.windows[0].used == 0.3)
        #expect(r.windows[1].used == 0.05)
        #expect(r.plan == "Pro")
    }

    @Test func onDemandWithoutLimitIsSpentMoney() throws {
        let json = #"{"individualUsage":{"plan":{"totalPercentUsed":0.36},"onDemand":{"enabled":true,"used":1234,"limit":null}}}"#
        let r = try Parsers.cursor(Data(json.utf8))
        #expect(abs(r.windows[0].used - 0.0036) < 1e-9)
        #expect(r.balances == [Balance(id: "cursor-on-demand", title: "On-demand", amount: 12.34, currency: "USD")])
    }

    @Test func jwtSubjectGivesUserID() {
        // {"sub":"auth0|user_abc"} в base64url без выравнивания.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.sig"
        #expect(CursorSource.userID(jwt: jwt) == "user_abc")
        #expect(CursorSource.userID(jwt: "not-a-jwt") == nil)
    }
}

@Suite struct KimiParserTests {
    @Test func countsFormatWeeklyAndShortWindow() throws {
        let json = #"""
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-01-09T15:23:13.716839300Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
         "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-01-06T13:33:02.717479433Z"}}]}
        """#
        let r = try Parsers.kimi(Data(json.utf8))
        #expect(r.windows.map(\.id) == ["kimi-5h", "kimi-week"])
        #expect(r.windows.map(\.title) == ["5 hours", "Week"])
        #expect(r.windows[0].used == 139.0 / 200)
        #expect(r.windows[0].isShort)
        #expect(r.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-01-06T13:33:02Z"))
        #expect(r.windows[1].used == 214.0 / 2048)
    }

    @Test func ratioFormatAndPlan() throws {
        let json = #"""
        {"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-16T20:15:44Z"},
         "limit_month_total":{"used_ratio":0.0056,"reset_time":"2026-10-17T00:00:00Z"}},
         "user":{"membership":{"level":"LEVEL_BASIC"}}}
        """#
        let r = try Parsers.kimi(Data(json.utf8))
        #expect(r.windows.map(\.id) == ["kimi-5h", "kimi-month"])
        #expect(r.windows[1].used == 0.0056)
        // Сентябрь — 30 дней.
        #expect(r.windows[1].duration == days30)
        #expect(r.plan == "Moderato")
    }

    @Test func zeroLimitIsNoWindow() {
        let json = #"{"usage":{"limit":"0","used":"0"}}"#
        #expect(throws: UsageError.self) { try Parsers.kimi(Data(json.utf8)) }
    }
}

@Suite struct OpenRouterParserTests {
    let key = #"{"data":{"limit":20,"limit_remaining":15,"limit_reset":"monthly","usage":5,"usage_monthly":4}}"#
    let credits = #"{"data":{"total_credits":5,"total_usage":3.10}}"#

    @Test func keyBudgetAndBalance() throws {
        let r = try Parsers.openRouter(key: Data(key.utf8), credits: Data(credits.utf8))
        #expect(r.windows.map(\.title) == ["Key · month"])
        #expect(r.windows[0].used == 0.25)
        #expect(r.windows[0].resetsAt == nil)
        #expect(r.balances.count == 1)
        #expect(abs(r.balances[0].amount - 1.9) < 1e-9)
    }

    @Test func malformedCreditsIsError() {
        #expect(throws: UsageError.self) {
            try Parsers.openRouter(key: Data(key.utf8), credits: Data(#"{"error":"x"}"#.utf8))
        }
    }

    @Test func noLimitAndNoCreditsShowsKeySpend() throws {
        let r = try Parsers.openRouter(key: Data(#"{"data":{"limit":null,"usage":7.5}}"#.utf8), credits: nil)
        #expect(r.windows.isEmpty)
        #expect(r.balances == [Balance(id: "openrouter-key-usage", title: "Spent by key", amount: 7.5, currency: "USD")])
        #expect(Account(kind: .openrouter).balanceOnly(Snapshot(report: r)))
        #expect(Account(kind: .moonshot).balanceOnly(Snapshot()))
        #expect(!Account(kind: .openrouter).balanceOnly(Snapshot()))
    }
}

@Suite struct MoonshotParserTests {
    @Test func availableBalanceInRegionCurrency() throws {
        let json = #"{"code":0,"data":{"available_balance":49.58,"voucher_balance":50,"cash_balance":12.34},"scode":"0x0","status":true}"#
        let r = try Parsers.moonshot(Data(json.utf8), currency: "CNY")
        #expect(r.windows.isEmpty)
        #expect(r.balances == [Balance(id: "moonshot-balance", title: "Balance", amount: 49.58, currency: "CNY")])
    }

    @Test func apiErrorCode() {
        let json = #"{"code":5,"scode":"0x5","status":false}"#
        #expect(throws: UsageError.self) { try Parsers.moonshot(Data(json.utf8), currency: "USD") }
    }
}

@Suite struct FormatMoneyTests {
    @Test func currencies() {
        #expect(Format.money(12.345, "USD") == "$12.35")
        #expect(Format.money(5, "CNY") == "¥5.00")
        #expect(Format.money(-1.5, "USD") == "−$1.50")
        #expect(Format.money(3, "EUR") == "3.00 EUR")
        #expect(Format.money(-0.001, "USD") == "$0.00")
    }
}

@Suite struct KeyStoreTests {
    @Test func keyCharactersAreRestricted() {
        #expect(KeyStore.isValid("sk-or-v1-abc_DEF.123"))
        #expect(!KeyStore.isValid(""))
        #expect(!KeyStore.isValid("with space"))
        #expect(!KeyStore.isValid("quote\"inside"))
        #expect(!KeyStore.isValid("back\\slash"))
        #expect(!KeyStore.isValid("ключ"))
    }

    /// Живая Связка ключей — только по `LIVE_KEYCHAIN=1 ./test.sh`: пишет и удаляет свой элемент.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_KEYCHAIN"] != nil))
    func liveSaveReadReplaceDelete() async throws {
        let id = UUID()
        #expect(try await KeyStore.save("test-key_1", for: id))
        #expect(try await KeyStore.lookup(id) == "test-key_1")
        // Тот же ключ — «не изменился».
        #expect(try await !KeyStore.save("test-key_1", for: id))
        #expect(try await KeyStore.save("test-key_2", for: id))
        #expect(try await KeyStore.lookup(id) == "test-key_2")
        #expect(try await KeyStore.delete(id))
        #expect(try await KeyStore.lookup(id) == nil)
        // Удалить отсутствующий — не ошибка, но и не изменение.
        #expect(try await !KeyStore.delete(id))
    }
}
