import Foundation

/// A published release on GitHub.
public struct Release: Equatable, Sendable {
    /// Git tag, `v0.2.0`: `install.sh` downloads by it.
    public let tag: String
    /// Version without the `v`, as in `CFBundleShortVersionString`.
    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    public let url: URL

    public init(tag: String, url: URL) {
        self.tag = tag
        self.url = url
    }
}

/// Update check: the latest GitHub release against the running version. Pure functions apart from `latest()`.
public enum Updates {
    public static let repo = "igor-batrakov/agents-usage"
    public static let repoURL = URL(string: "https://github.com/\(repo)")!
    public static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    public static let issuesURL = URL(string: "https://github.com/\(repo)/issues")!
    /// Automatic checks at most this often.
    public static let interval: TimeInterval = 86400

    /// `GET api.github.com/repos/<repo>/releases/latest`: drafts and prereleases never show up there.
    public static func latest() async throws -> Release {
        let data = try await HTTP.get("https://api.github.com/repos/\(repo)/releases/latest",
                                      headers: ["Accept": "application/vnd.github+json"], timeout: 10)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Release {
        // The tag goes into the download URL: only the plain form v1.2.3 is accepted.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              tag.range(of: #"^v?[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil,
              let page = root["html_url"] as? String, let url = URL(string: page)
        else { throw UsageError.message(L("unexpected response from GitHub")) }
        return Release(tag: tag, url: url)
    }

    /// Dotted numbers compared one by one, missing parts count as 0: "0.10.0" is newer than "0.9.1".
    /// A leading "v" and a suffix after "-" ("1.0.0-beta") are ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// An automatic check is due when there was none yet, the last one is a day old, or the clock went back.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let age = now.timeIntervalSince(lastCheck)
        return age >= interval || age < 0
    }

    private static func numbers(_ version: String) -> [Int] {
        let core = version.drop { $0 == "v" }.split(separator: "-").first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}
