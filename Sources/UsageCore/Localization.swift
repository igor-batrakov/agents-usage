import Foundation

/// Строки интерфейса на выбранном языке.
///
/// Языки — каталоги `<код>.lproj/Localizable.strings` в ресурсах приложения: новый язык — новый каталог,
/// код не меняется (список языков собирается по найденным каталогам). Ключ — английский текст:
/// непереведённая строка показывается по-английски, а код читается без справочника ключей.
///
/// Свой выбор языка, а не системная локализация `Bundle`: язык переключается в настройках без
/// перезапуска. Поэтому в SwiftUI — `Text(L("…"))`, а не `Text("…")`: литерал SwiftUI переводит сам,
/// по языку системы.
///
/// Читается из любых потоков (парсеры работают вне главного), таблица под замком.
public final class Localization: @unchecked Sendable {
    public static let shared = Localization()

    /// Где искать `*.lproj`: ресурсы приложения; тесты подставляют каталог репозитория.
    public var resources: URL? = Bundle.main.resourceURL

    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var current = "en"

    /// Код действующего языка («en», «ru»).
    public var code: String { lock.withLock { current } }

    /// Коды языков, для которых есть перевод; английский — всегда (он в ключах).
    public func available() -> [String] { availableIn(resources) }

    func availableIn(_ directory: URL?) -> [String] {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: directory?.path ?? ""))?
            .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(".lproj".count)) } ?? []
        return (Set(found).union(["en"])).filter { $0 != "Base" }.sorted()
    }

    /// nil — как в системе: первый из предпочитаемых языков macOS, для которого есть перевод.
    public func use(_ choice: String?) {
        let code = choice.flatMap { available().contains($0) ? $0 : nil } ?? Self.match(Locale.preferredLanguages, in: available())
        let url = resources?.appendingPathComponent("\(code).lproj/Localizable.strings")
        let strings = url.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        lock.withLock {
            current = code
            table = strings
        }
    }

    /// «en-TR» → «en»; ни один не подошёл — английский.
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

    /// Имя языка на нём самом: «English», «Русский».
    public static func name(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Строка на выбранном языке; с аргументами — формат (`%@`, `%d`), как в `String(format:)`.
/// Без локали формата: числа и суммы форматируются до подстановки, единообразно для всех языков.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localization.shared.string(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
