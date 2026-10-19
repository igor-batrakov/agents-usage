import Foundation
import Testing
@testable import UsageCore

/// Translations are repository files, the tests read them directly. The shared `Localization.shared` is left alone:
/// tests run in parallel, and switching the language in one would break the expectations of others.
@Suite struct LocalizationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let resources = root.appendingPathComponent("Resources")

    /// `L("…")` keys from the sources, collected the way tools/strings.py does (comment lines are skipped).
    static func sourceKeys() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let code = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for m in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                keys.insert(String(code[Range(m.range(at: 1), in: code)!]))
            }
        }
        return keys
    }

    static func table(_ code: String) -> [String: String] {
        NSDictionary(contentsOf: resources.appendingPathComponent("\(code).lproj/Localizable.strings")) as? [String: String] ?? [:]
    }

    /// `%@`, `%d` in order: a translation must substitute the same arguments.
    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[@dfs]"#)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    @Test func everyLanguageHasEveryKeyWithSameSpecifiers() throws {
        let keys = try Self.sourceKeys()
        #expect(keys.count > 100)
        let languages = Localization().availableIn(Self.resources)
        #expect(languages.contains("en") && languages.contains("ru"))
        for code in languages {
            let table = Self.table(code)
            #expect(Set(table.keys) == keys, "\(code): keys differ from the code, run tools/strings.py")
            for (key, value) in table {
                #expect(Self.specifiers(key) == Self.specifiers(value), "\(code): «\(key)» → «\(value)»")
            }
        }
    }

    @Test func russianIsLoaded() {
        let l10n = Localization()
        l10n.resources = Self.resources
        l10n.use("ru")
        #expect(l10n.code == "ru")
        #expect(l10n.string("5 hours") == "5 часов")
        #expect(l10n.string("not in any table") == "not in any table")
        // No such language: follow the system, not an empty table.
        l10n.use("xx")
        #expect(l10n.available().contains(l10n.code))
    }

    @Test func systemLanguageMatching() {
        #expect(Localization.match(["en-TR", "ru-TR"], in: ["en", "ru"]) == "en")
        #expect(Localization.match(["ru-RU", "en-US"], in: ["en", "ru"]) == "ru")
        #expect(Localization.match(["de-DE", "ru"], in: ["en", "ru"]) == "ru")
        #expect(Localization.match(["ja-JP"], in: ["en", "ru"]) == "en")
        #expect(Localization.name("ru") == "Русский")
        #expect(Localization.name("en") == "English")
    }
}
