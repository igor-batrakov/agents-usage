import Foundation

/// API-ключи аккаунтов — в Связке ключей, элемент на аккаунт (`account` — его UUID).
/// Только через `/usr/bin/security`, как и для Claude: элемент, созданный им, он же читает без
/// запроса доступа. Через SecItem доступ был бы у самого приложения, а его ad-hoc подпись
/// меняется с каждой сборкой — после каждого обновления macOS спрашивала бы разрешение.
/// Ключ при записи идёт через stdin (`security -i`), а не аргументом: аргументы видны в `ps`.
public enum KeyStore {
    static let service = "Agents Usage API key"
    /// Код выхода `security`, когда элемента нет.
    static let notFound: Int32 = 44

    /// nil — ключа нет; ошибка — Связка ключей не ответила (тогда о наличии ключа ничего не известно).
    public static func lookup(_ id: UUID) async throws -> String? {
        let data: Data
        do {
            data = try await ProcessRunner.run(
                "/usr/bin/security", ["find-generic-password", "-s", service, "-a", id.uuidString, "-w"], timeout: 5)
        } catch UsageError.exit(_, let status) where status == notFound {
            return nil
        }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Пустой ключ — удалить. Записанное читается обратно: `security -i` о неудаче команды
    /// сообщает только в stderr. Возвращает, изменился ли ключ (тот же — ничего не делаем).
    @discardableResult
    public static func save(_ key: String, for id: UUID) async throws -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return try await delete(id) }
        guard isValid(key) else { throw UsageError.message(L("the key contains invalid characters")) }
        if try await lookup(id) == key { return false }
        let command = "add-generic-password -U -s \"\(service)\" -a \"\(id.uuidString)\" -l \"\(service)\" -w \"\(key)\"\n"
        _ = try? await ProcessRunner.run("/usr/bin/security", ["-i"], input: Data(command.utf8), closeInput: true,
                                         timeout: 5)
        guard try await lookup(id) == key else { throw UsageError.message(L("couldn't save the key to Keychain")) }
        return true
    }

    /// Отсутствующий ключ — не ошибка; любой другой сбой — ошибка, и итог проверяется чтением.
    /// Возвращает, был ли ключ.
    @discardableResult
    public static func delete(_ id: UUID) async throws -> Bool {
        guard try await lookup(id) != nil else { return false }
        do {
            _ = try await ProcessRunner.run(
                "/usr/bin/security", ["delete-generic-password", "-s", service, "-a", id.uuidString], timeout: 5)
        } catch UsageError.exit(_, let status) where status == notFound {}
        guard try await lookup(id) == nil else { throw UsageError.message(L("couldn't delete the key from Keychain")) }
        return true
    }

    /// Печатные ASCII без кавычек, обратной косой и пробелов — ключ встаёт в команду `security -i`
    /// в двойных кавычках, и ни один символ не должен её разорвать. Ключи вендоров в этот набор укладываются.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
    }
}
