import Foundation

/// UI strings in the selected language.
///
/// Languages are `<code>.lproj/Localizable.strings` directories in the app resources: a new language is a new
/// directory, no code changes (the language list comes from the directories found). The key is the English text:
/// an untranslated string shows in English, and the code reads without a key reference.
///
/// Our own language choice instead of `Bundle` localization: the language switches in settings without
/// a restart. That is why SwiftUI uses `Text(L("…"))`, not `Text("…")`: SwiftUI translates a literal itself,
/// by the system language.
///
/// Read from any thread (parsers run off the main one), the table is behind a lock.
public final class Localization: @unchecked Sendable {
    public static let shared = Localization()

    /// Where to look for `*.lproj`: the app resources; tests point it at the repository directory.
    public var resources: URL? = Bundle.main.resourceURL

    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var current = "en"

    /// Code of the active language ("en", "ru").
    public var code: String { lock.withLock { current } }

    /// Codes of languages that have a translation; English is always there (it is the keys).
    public func available() -> [String] { availableIn(resources) }

    func availableIn(_ directory: URL?) -> [String] {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: directory?.path ?? ""))?
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) } ?? []
        return (Set(found).union(["en"])).filter { $0 != "Base" }.sorted()
    }

    /// nil follows the system: the first of the preferred macOS languages that has a translation.
    public func use(_ choice: String?) {
        let code = choice.flatMap { available().contains($0) ? $0 : nil } ?? Self.match(Locale.preferredLanguages, in: available())
        let url = resources?.appendingPathComponent("\(code).lproj/Localizable.strings")
        let strings = url.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        lock.withLock {
            current = code
            table = strings
        }
    }

    /// "en-TR" → "en"; if none matches, English.
    static func match(_ preferred: [String], in available: [String]) -> String {
        for identifier in preferred {
            let language = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
            if available.contains(language) { return language }
        }
        return "en"
    }

    public func string(_ key: String) -> String {
        lock.withLock { table[key] } ?? key
    }

    /// Language name in the language itself: "English", "Русский".
    public static func name(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// String in the selected language; with arguments it is a format (`%@`, `%d`), as in `String(format:)`.
/// No format locale: numbers and amounts are formatted before substitution, the same way for every language.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localization.shared.string(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
