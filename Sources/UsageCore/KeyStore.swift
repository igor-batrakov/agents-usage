import Foundation

/// Account API keys live in the Keychain, one item per account (`account` is its UUID).
/// Only through `/usr/bin/security`, as for Claude: an item it created it can read without
/// an access prompt. With SecItem the access would belong to the app itself, and its ad-hoc
/// signature changes with every build, so macOS would ask for permission after every update.
/// The key is written through stdin (`security -i`), not as an argument: arguments show up in `ps`.
public enum KeyStore {
    static let service = "Agents Usage API key"
    /// `security` exit code when the item does not exist.
    static let notFound: Int32 = 44

    /// nil means no key; an error means the Keychain did not answer (then nothing is known about the key).
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

    /// An empty key deletes. The written value is read back: `security -i` reports a failed command
    /// only on stderr. Returns whether the key changed (same key: nothing is done).
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

    /// A missing key is not an error; any other failure is, and the result is verified by reading.
    /// Returns whether there was a key.
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

    /// Printable ASCII without quotes, backslash or spaces: the key goes into a `security -i` command
    /// in double quotes, and no character may break out of it. Vendor keys fit this set.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" && $0 != "\\" }
    }
}
