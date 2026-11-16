import Foundation
import Testing
@testable import UsageCore

/// Google Cloud spending from the billing export: the jobs.query answer, the period, the query itself.
/// The answers are made up in the documented jobs.query format (no real project or billing account ids).
@Suite struct CloudBillingTests {
    /// A jobs.query answer with one row: number of currencies, currency, cost, credits, newest export.
    func answer(_ cost: String?, _ credits: String?, _ currency: String?, _ exported: String?, complete: Bool = true,
                currencies: String = "1") -> Data {
        func cell(_ v: String?) -> String { v.map { #"{"v": "\#($0)"}"# } ?? #"{"v": null}"# }
        let row = [currencies, currency, cost, credits, exported].map(cell).joined(separator: ", ")
        return Data(#"{"kind": "bigquery#queryResponse", "jobComplete": \#(complete), "totalRows": "1", "rows": [{"f": [\#(row)]}]}"#.utf8)
    }

    let start = Date(timeIntervalSince1970: 1_793_491_200)   // made-up period
    var end: Date { start.addingTimeInterval(30 * 86400) }

    @Test func grossCostWithLimitAndCredits() throws {
        let billing = CloudBilling(dataset: "my-project.billing_export", limit: 80)
        let r = try Parsers.cloudBilling(answer("12.5", "-10.25", "EUR", "1793600000"), billing: billing, start: start, end: end)
        #expect(r.balances.map(\.id) == ["gcloud-spent", "gcloud-credits"])
        #expect(r.balances[0].amount == 12.5 && r.balances[0].currency == "EUR")
        #expect(r.balances[1].amount == 10.25)
        let w = try #require(r.windows.first)
        #expect(w.id == "gcloud-month" && w.title == "Month")
        let used = 12.5 / 80
        #expect(w.used == used)
        #expect(w.resetsAt == end && w.duration == 30 * 86400 && !w.isShort)
        #expect(r.plan?.isEmpty == false)
    }

    @Test func netSubtractsCreditsAndNeverGoesBelowZero() throws {
        var billing = CloudBilling(dataset: "my-project.billing_export", period: .week, net: true)
        var r = try Parsers.cloudBilling(answer("0.48", "-0.48", "EUR", nil), billing: billing, start: start, end: end)
        #expect(r.balances.map(\.amount) == [0])
        #expect(r.balances[0].title == "Spent this week")
        #expect(r.windows.isEmpty && r.plan == nil)
        billing.limit = 10
        r = try Parsers.cloudBilling(answer("5", "-1", "EUR", nil), billing: billing, start: start, end: end)
        #expect(r.balances.map(\.amount) == [4])
        #expect(r.windows.map(\.id) == ["gcloud-week"])
        #expect(r.windows[0].used == 0.4)
        // Credits above the cost (a refund) do not make a negative spending.
        r = try Parsers.cloudBilling(answer("1", "-3", "EUR", nil), billing: billing, start: start, end: end)
        #expect(r.balances[0].amount == 0)
    }

    @Test func emptyPeriodIsZeroButAnEmptyExportIsAnError() throws {
        let billing = CloudBilling(dataset: "my-project.billing_export")
        let r = try Parsers.cloudBilling(answer(nil, nil, "EUR", "1793600000"), billing: billing, start: start, end: end)
        #expect(r.balances.map(\.amount) == [0])
        #expect(throws: UsageError.self) {
            try Parsers.cloudBilling(answer(nil, nil, nil, nil), billing: billing, start: start, end: end)
        }
        #expect(throws: UsageError.self) {
            try Parsers.cloudBilling(answer("1", "0", "EUR", nil, complete: false), billing: billing, start: start, end: end)
        }
        // EUR and USD exports in one dataset are never added up.
        #expect(throws: UsageError.self) {
            try Parsers.cloudBilling(answer("200", "0", "EUR", nil, currencies: "2"), billing: billing, start: start, end: end)
        }
    }

    @Test func anUnfinishedJobIsAwaitedNotRestarted() throws {
        let pending = #"{"jobComplete": false, "jobReference": {"projectId": "my-project", "jobId": "job_Ab-1", "location": "EU"}}"#
        #expect(CloudBillingSource.pendingJob(Data(pending.utf8)) == "job_Ab-1?timeoutMs=10000&location=EU")
        let odd = #"{"jobComplete": false, "jobReference": {"jobId": "../x?y"}}"#
        #expect(CloudBillingSource.pendingJob(Data(odd.utf8)) == nil)
        #expect(CloudBillingSource.pendingJob(answer("1", "0", "EUR", nil)) == nil)
        // The jobs.insert answer has no jobComplete: its results are fetched.
        let inserted = #"{"kind": "bigquery#job", "jobReference": {"projectId": "p", "jobId": "job_9", "location": "EU"}, "status": {"state": "RUNNING"}}"#
        #expect(CloudBillingSource.pendingJob(Data(inserted.utf8)) == "job_9?timeoutMs=10000&location=EU")
        // One result table per settings, a valid table id.
        let a = CloudBilling(dataset: "p-12345.d"), b = CloudBilling(dataset: "p-12345.d", project: "x-12345")
        #expect(CloudBillingSource.resultTable(a) != CloudBillingSource.resultTable(b))
        #expect(CloudBillingSource.resultTable(a) == CloudBillingSource.resultTable(a))
        #expect(CloudBillingSource.resultTable(a).range(of: #"^agents_usage_[0-9a-f]{12}$"#, options: .regularExpression) != nil)
    }

    actor Counter {
        var n = 0
        func next() -> Int { n += 1; return n }
    }

    @Test func cacheAnswersWithinTheIntervalAndSharesARunningQuery() async throws {
        let cache = CloudBillingCache()
        let calls = Counter()
        let fetch: @Sendable () async throws -> Data = {
            let n = await calls.next()
            try await Task.sleep(for: .milliseconds(100))
            return Data("\(n)".utf8)
        }
        let t = Date(timeIntervalSince1970: 1000)
        // Two polls at once: one query, both get its answer.
        async let a = cache.data("k", newerThan: 900, now: t, fetch: fetch)
        async let b = cache.data("k", newerThan: 900, now: t, fetch: fetch)
        let (x, y) = try await (a, b)
        #expect(x == Data("1".utf8) && y == x)
        #expect(await calls.n == 1)
        // Within the interval the saved answer; after it, another query; another key never shares.
        #expect(try await cache.data("k", newerThan: 900, now: t.addingTimeInterval(899), fetch: fetch) == Data("1".utf8))
        #expect(try await cache.data("k", newerThan: 900, now: t.addingTimeInterval(900), fetch: fetch) == Data("2".utf8))
        #expect(try await cache.data("other", newerThan: 900, now: t, fetch: fetch) == Data("3".utf8))
        // A failed query is not saved.
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await cache.data("bad", newerThan: 900, now: t) { throw Boom() }
        }
        #expect(try await cache.data("bad", newerThan: 900, now: t, fetch: fetch) == Data("4".utf8))
    }

    @Test func periodBoundsFollowTheLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // Sunday 15 Nov 2026, 12:00 in Berlin.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12)))
        let month = CloudBilling.bounds(.month, now: now, calendar: calendar)
        #expect(month.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        #expect(month.end == calendar.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        // The ISO week starts on Monday whatever the locale.
        let week = CloudBilling.bounds(.week, now: now, calendar: calendar)
        #expect(week.start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
        #expect(week.end == calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    }

    @Test func datasetIsCheckedBeforeItGoesIntoTheQuery() {
        #expect(CloudBillingSource.split("my-project-123.billing_export")! == ("my-project-123", "billing_export"))
        #expect(CloudBillingSource.split(" my-project-123.billing_export ") != nil)
        #expect(CloudBillingSource.split("billing_export") == nil)
        #expect(CloudBillingSource.split("my-project-123.billing.export") == nil)
        #expect(CloudBillingSource.split("my-project-123.x` OR 1=1 --") == nil)
        #expect(CloudBillingSource.split("My_Project.billing") == nil)
        #expect(CloudBillingSource.split("") == nil)
    }

    @Test func queryReadsTheExportByPrefixWithParameters() throws {
        let body = CloudBillingSource.query(project: "my-project-123", dataset: "billing_export", filter: " app-prod-1 ",
                                            service: "Vertex AI", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200),
                                            result: "agents_usage_abc")
        let job = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let root = try #require((job["configuration"] as? [String: Any])?["query"] as? [String: Any])
        // An explicit result table: no anonymous dataset, which a domain-restricted organization refuses.
        let destination = try #require(root["destinationTable"] as? [String: String])
        #expect(destination == ["projectId": "my-project-123", "datasetId": "billing_export", "tableId": "agents_usage_abc"])
        #expect(root["writeDisposition"] as? String == "WRITE_TRUNCATE")
        let sql = try #require(root["query"] as? String)
        #expect(sql.contains("`my-project-123.billing_export.gcp_billing_export_v1_*`"))
        #expect(!sql.contains("app-prod-1"))
        #expect(root["useLegacySql"] as? Bool == false)
        #expect(root["maximumBytesBilled"] as? String == "100000000")
        let params = try #require(root["queryParameters"] as? [[String: Any]])
        let values = Dictionary(uniqueKeysWithValues: params.map {
            ($0["name"] as! String, ($0["parameterValue"] as! [String: Any])["value"] as! String)
        })
        #expect(values == ["start": "100", "end": "200", "project": "app-prod-1", "service": "Vertex AI"])
        #expect(sql.contains("service.description = @service") && !sql.contains("Vertex AI"))
    }

    /// Against the real export, only on request: `CLOUD_BILLING_LIVE=project.dataset ./test.sh --filter liveCloudBilling`.
    /// Read-only: one query (or an error before it, which is not billed). Prints the report or the error text.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLOUD_BILLING_LIVE"] != nil))
    func liveCloudBilling() async {
        let dataset = ProcessInfo.processInfo.environment["CLOUD_BILLING_LIVE"] ?? ""
        do {
            let r = try await CloudBillingSource(billing: CloudBilling(dataset: dataset, limit: 80)).fetch()
            print("live:", r.balances.map { "\($0.title) \(Format.money($0.amount, $0.currency))" }, r.windows.map(\.used), r.plan ?? "")
        } catch {
            print("live error:", error.localizedDescription)
        }
    }

    @Test func notAddedOnFirstLaunchAndSettingsAreTheSource() {
        #expect(!Catalog.defaultAccounts(installed: { _ in true }).contains { $0.kind == .gcloud })
        #expect(Provider.gcloud.allowsMultipleAccounts)
        var a = Account(kind: .gcloud)
        let before = a
        a.billing = CloudBilling(dataset: "my-project.billing_export", limit: 80)
        #expect(!a.sameSource(as: before))
        #expect(a.sourceTag != before.sourceTag)
        var b = a
        b.billing?.limit = 100
        #expect(!b.sameSource(as: a) && b.sourceTag != a.sourceTag)
        var c = a
        c.billing?.service = "Vertex AI"
        #expect(!c.sameSource(as: a))
        #expect(CloudBillingSource.resultTable(c.billing!) != CloudBillingSource.resultTable(a.billing!))
        // Settings saved before the service filter existed still decode.
        let old = #"{"dataset": "p-12345.d", "period": "month", "net": false}"#
        let decoded = try? JSONDecoder().decode(CloudBilling.self, from: Data(old.utf8))
        #expect(decoded != nil && decoded?.service == nil)
        #expect(Format.money(12.5, "EUR") == "€12.50")
    }
}
