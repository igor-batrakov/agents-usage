import Foundation
import Testing
@testable import UsageCore

@Suite struct UpdatesTests {
    @Test func parsesLatestRelease() throws {
        let r = try Updates.parse(fixture("github_release_latest"))
        #expect(r.tag == "v0.1.0")
        #expect(r.version == "0.1.0")
        #expect(r.url.absoluteString == "https://github.com/igor-batrakov/agents-usage/releases/tag/v0.1.0")
    }

    @Test func rejectsResponseWithoutTag() {
        // GitHub answers 404 with a message when there are no releases; any shape without a tag is an error.
        #expect(throws: UsageError.self) { try Updates.parse(Data(#"{"message":"Not Found"}"#.utf8)) }
        #expect(throws: UsageError.self) { try Updates.parse(Data("not json".utf8)) }
    }

    @Test func comparesVersionsNumerically() {
        #expect(Updates.isNewer("v0.2.0", than: "0.1.0"))
        #expect(Updates.isNewer("0.10.0", than: "0.9.1"))
        #expect(Updates.isNewer("1.0", than: "0.9.9"))
        #expect(Updates.isNewer("0.1.1", than: "0.1"))
        #expect(!Updates.isNewer("0.1.0", than: "0.1.0"))
        #expect(!Updates.isNewer("v0.1.0", than: "0.1"))
        #expect(!Updates.isNewer("0.1.0", than: "0.2.0"))
        #expect(!Updates.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    @Test func checkIsDueOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Updates.isDue(lastCheck: nil, now: now))
        #expect(!Updates.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(-Updates.interval), now: now))
        // The clock went back: a check stamped in the future must not block checks for good.
        #expect(Updates.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
