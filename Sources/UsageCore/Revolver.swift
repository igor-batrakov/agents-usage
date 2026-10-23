import Foundation

// Revolver (`revo`), the code review chain: its JSON contract is `docs/json.md` in the revolver repository
// (schema 2). The app never reads or writes revo's files, it only runs these commands.

/// A JSON scalar: `error.value` and the old/new values of a diff are strings, numbers or booleans.
public enum RevoValue: Decodable, Equatable, Sendable, CustomStringConvertible {
    case string(String), int(Int), double(Double), bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        // An array or an object only ends up in a message: not a reason to reject the whole answer.
        else { self = .string("…") }
    }

    public var description: String {
        switch self {
        case .string(let v): v
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .bool(let v): String(v)
        }
    }
}

/// Block roles: every enabled required block runs on each review, in parallel; a fallback reviews instead of a
/// required block above it that gave no review.
public enum RevoRole {
    public static let required = "required"
    public static let fallback = "fallback"
}

/// When a fallback steps in: `limit` if the required block (or a fallback tried for it) hit a limit, `any_fail`
/// if it gave no review for any reason. A required block always has `-`.
public enum RevoTakesOver {
    public static let none = "-"
    public static let limit = "limit"
    public static let anyFail = "any_fail"
}

/// A chain block, in the form `revo apply` accepts. Fields the app does not know are skipped and never sent back.
public struct RevoBlock: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var engine: String
    public var model: String
    public var effort: String
    public var on: Bool
    public var role: String
    public var takesOver: String

    public var isRequired: Bool { role == RevoRole.required }

    /// The defaults are those of `apply`'s `add`: on, a fallback that steps in on any failure.
    public init(id: String, engine: String, model: String, effort: String, on: Bool = true,
                role: String = RevoRole.fallback, takesOver: String = RevoTakesOver.anyFail) {
        self.id = id
        self.engine = engine
        self.model = model
        self.effort = effort
        self.on = on
        self.role = role
        self.takesOver = takesOver
    }

    enum CodingKeys: String, CodingKey { case id, engine, model, effort, on, role, takesOver = "takes_over" }
}

public struct RevoSettings: Decodable, Equatable, Sendable {
    /// Review runs per commit (1–20); revo does not repeat reviews itself, agents read the number.
    public var reviewRounds: Int
    /// `en`, `ru`, or nil: follow the environment.
    public var lang: String?
    /// A required block got no review while others did: `ask` (the commit waits for the user) or `note`.
    public var missingReview: String

    public static let rounds = 1...20

    enum CodingKeys: String, CodingKey { case reviewRounds = "review_rounds", lang, missingReview = "missing_review" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewRounds = try c.decodeIfPresent(Int.self, forKey: .reviewRounds) ?? 2
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        missingReview = try c.decodeIfPresent(String.self, forKey: .missingReview) ?? "ask"
    }
}

/// A limit revo recorded for a block's engine.
public struct RevoBlockState: Decodable, Equatable, Sendable {
    public var limitUntil: Int?
    /// Computed by revo, not by the app.
    public var active: Bool

    enum CodingKeys: String, CodingKey { case limitUntil = "limit_until", active }
}

/// `revo ls --json`: the global chain. The app runs revo from `/`, so a project's `.revolver.json` is not seen.
public struct RevoChain: Decodable, Equatable, Sendable {
    public var configPath: String
    /// sha256 of `chain.json`, or "defaults" without the file; `apply` takes it as `base`.
    public var configRev: String
    /// Every block has a role: revo derives them for a file without roles.
    public var chain: [RevoBlock]
    public var settings: RevoSettings?
    public var state: [String: RevoBlockState]

    enum CodingKeys: String, CodingKey { case configPath = "config_path", configRev = "config_rev", chain, settings, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configPath = try c.decode(String.self, forKey: .configPath)
        configRev = try c.decode(String.self, forKey: .configRev)
        chain = try c.decode([RevoBlock].self, forKey: .chain)
        settings = try c.decodeIfPresent(RevoSettings.self, forKey: .settings)
        state = try c.decodeIfPresent([String: RevoBlockState].self, forKey: .state) ?? [:]
    }

    /// The reset time of a block on a limit still in force at `now`. `active` is as of the call, the answer may be older.
    public func limit(_ id: String, now: Date) -> Date? {
        guard let state = state[id], state.active, let until = state.limitUntil else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(until))
        return date > now ? date : nil
    }
}

/// `revo engines --json`: what the pickers offer, nothing is hardcoded in the app.
public struct RevoEngine: Decodable, Equatable, Sendable {
    public var name: String
    public var display: String
    public var efforts: [String]
    /// The first one is `default`: the CLI picks its own model.
    public var models: [String]
    public var customModel: Bool
    /// What a typed model name must match (a regular expression).
    public var modelPattern: String?
    /// The CLI file was found (it is not run).
    public var installed: Bool

    enum CodingKeys: String, CodingKey {
        case name, display, efforts, models, customModel = "custom_model", modelPattern = "model_pattern", installed
    }

    /// Whether revo will take this model name (`invalid_model` otherwise).
    public func accepts(_ model: String) -> Bool {
        if models.contains(model) { return true }
        guard customModel, !model.isEmpty else { return false }
        guard let modelPattern else { return true }
        return model.range(of: modelPattern, options: .regularExpression) != nil
    }

    /// The effort a new block starts with.
    public var defaultEffort: String {
        efforts.contains("high") ? "high" : efforts.last ?? "high"
    }
}

public struct RevoChange: Decodable, Equatable, Sendable {
    /// Block id; nil for a setting.
    public var id: String?
    public var field: String
    public var old: RevoValue?
    public var new: RevoValue?
}

public struct RevoDiff: Decodable, Equatable, Sendable {
    public struct Order: Decodable, Equatable, Sendable {
        public var old: [String]
        public var new: [String]
    }
    public var order: Order?
    public var changes: [RevoChange]
    public var added: [RevoBlock]
    public var removed: [String]
    public var settings: [RevoChange]

    enum CodingKeys: String, CodingKey { case order, changes, added, removed, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent(Order.self, forKey: .order)
        changes = try c.decodeIfPresent([RevoChange].self, forKey: .changes) ?? []
        added = try c.decodeIfPresent([RevoBlock].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        settings = try c.decodeIfPresent([RevoChange].self, forKey: .settings) ?? []
    }
}

/// The answer of `revo apply [--check]`. With `--check` `configRev` is the current one: it goes as `base` to the write.
public struct RevoApplyResult: Decodable, Equatable, Sendable {
    public var check: Bool
    public var configRev: String
    public var diff: RevoDiff

    enum CodingKeys: String, CodingKey { case check, configRev = "config_rev", diff }
}

/// `{"ok": false, "error": …}`. The app translates by `code`; `message` is the fallback, in the language of `REVO_LANG`.
public struct RevoError: Decodable, Equatable, Sendable {
    public var code: String
    public var block: String?
    public var field: String?
    public var value: RevoValue?
    public var message: String
}

public enum RevoFailure: Error, Equatable, Sendable {
    /// revo does not speak schema 2 (too old, or a future incompatible one).
    case outdated
    /// revo answered with an error object; `status` is the exit code (4 is config_changed, 5 is busy).
    case failed(RevoError, status: Int32)
    /// Not the JSON of the contract (a crash before the output, a different program).
    case unreadable(status: Int32)
    /// Could not run it: not found, timed out. The text is already translated.
    case run(String)

    public var isConfigChanged: Bool {
        if case .failed(let e, _) = self { return e.code == "config_changed" }
        return false
    }

    /// Translated when shown, so a language change applies to an error already on screen.
    public var text: String {
        switch self {
        case .outdated: L("This revo is too old for the app. Update it: %@", Revo.upgradeCommand)
        case .unreadable(let status): L("revo returned an unexpected response (exit code %d)", Int(status))
        case .run(let text): text
        case .failed(let e, _):
            switch e.code {
            case "busy": L("The review chain is being changed by another process. Try again.")
            case "config_changed":
                L("The review chain was changed outside the app and has been reloaded. Check your edits and apply again.")
            case "invalid_effort": L("%@: effort %@ is not supported", e.block ?? "?", e.value?.description ?? "")
            case "invalid_model": L("%@: invalid model name %@", e.block ?? "?", e.value?.description ?? "")
            case "internal": L("revo failed with an internal error. Run it in Terminal to see the details.")
            default: e.message
            }
        }
    }
}

/// What the tab warns about; nothing is forbidden, revo accepts such a chain.
public enum RevoWarning: Equatable, Sendable {
    /// An enabled fallback with no enabled required block above it: it never runs.
    case neverRuns
    /// An enabled required block with no enabled fallback below it: nobody reviews instead of it.
    case noFallback
}

/// The rules of `docs/SPEC-stage3-chain.md` §1, as far as the tab shows them.
extension Array where Element == RevoBlock {
    /// Without an enabled required block reviews do not start (`no_required_blocks`).
    public var hasEnabledRequired: Bool { contains { $0.on && $0.isRequired } }

    /// For a fallback: the required block it goes for first, the topmost enabled one above it.
    public func coveredFirst(at index: Int) -> RevoBlock? {
        guard indices.contains(index), !self[index].isRequired else { return nil }
        return self[..<index].first { $0.on && $0.isRequired }
    }

    public func warning(at index: Int) -> RevoWarning? {
        guard indices.contains(index), self[index].on else { return nil }
        if self[index].isRequired {
            return self[(index + 1)...].contains { $0.on && !$0.isRequired } ? nil : .noFallback
        }
        return coveredFirst(at: index) == nil ? .neverRuns : nil
    }

    /// Who reviews instead of each enabled required block on a limit (`limited` are block ids). Top-down, a fallback
    /// covers one required block: the first enabled one below it that is not used yet and not on a limit itself.
    /// Both conditions fit a limit.
    public func cover(limited: Set<String>) -> [(required: RevoBlock, by: RevoBlock?)] {
        var used = Set<String>()
        var result: [(required: RevoBlock, by: RevoBlock?)] = []
        for (i, block) in enumerated() where block.on && block.isRequired && limited.contains(block.id) {
            let by = self[(i + 1)...].first {
                $0.on && !$0.isRequired && !limited.contains($0.id) && !used.contains($0.id)
            }
            if let by { used.insert(by.id) }
            result.append((block, by))
        }
        return result
    }
}

/// Edits of the chain as `revo apply` operations: by id, so fields and blocks the app does not know stay as they were.
/// revo applies them in this order: `remove`, `add` (at the end), `order`, `set`, `settings`.
public struct RevoOps: Equatable, Sendable {
    public struct BlockEdit: Equatable, Sendable {
        public var on: Bool?
        public var model: String?
        public var effort: String?
        public var role: String?
        public var takesOver: String?

        public init(on: Bool? = nil, model: String? = nil, effort: String? = nil, role: String? = nil,
                    takesOver: String? = nil) {
            self.on = on
            self.model = model
            self.effort = effort
            self.role = role
            self.takesOver = takesOver
        }
    }

    public var remove: [String] = []
    /// New blocks with their final ids.
    public var add: [RevoBlock] = []
    /// The resulting order of ids, after `remove` and `add`; nil if it is the natural one.
    public var order: [String]?
    public var set: [String: BlockEdit] = [:]
    public var reviewRounds: Int?
    /// nil: unchanged; `.some(nil)`: remove `lang`, the language follows the environment again.
    public var lang: String??
    public var missingReview: String?
    /// The role of every kept block, sent with any edit so revo writes derived roles into the file. Not an edit:
    /// it is not replayed onto another version of the chain.
    public var roles: [String: String] = [:]

    public var isEmpty: Bool {
        remove.isEmpty && add.isEmpty && order == nil && set.isEmpty && reviewRounds == nil && lang == nil
            && missingReview == nil
    }

    public init(remove: [String] = [], add: [RevoBlock] = [], order: [String]? = nil, set: [String: BlockEdit] = [:],
                reviewRounds: Int? = nil, lang: String?? = nil, missingReview: String? = nil) {
        self.remove = remove
        self.add = add
        self.order = order
        self.set = set
        self.reviewRounds = reviewRounds
        self.lang = lang
        self.missingReview = missingReview
    }

    /// The edits that turn `old` into `new`: only changed fields, the order only if it differs from the natural one.
    /// New blocks (`RevoDraft.isNew`) get their final ids here. With any edit, every block's role is sent: revo then
    /// writes the roles into the file, and a later reordering cannot change a derived role.
    public static func between(_ old: RevoDraft, _ new: RevoDraft) -> RevoOps {
        var ops = RevoOps()
        let oldIDs = old.blocks.map(\.id)
        let kept = Set(new.blocks.map(\.id))
        ops.remove = oldIDs.filter { !kept.contains($0) }

        let before = Dictionary(old.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var taken = Set(oldIDs).union(new.blocks.map(\.id).filter { !RevoDraft.isNew($0) })
        var final: [String: String] = [:]
        for block in new.blocks where before[block.id] == nil {
            var added = block
            if RevoDraft.isNew(block.id) { added.id = RevoDraft.freeID(for: block, taken: taken) }
            taken.insert(added.id)
            final[block.id] = added.id
            ops.add.append(added)
        }
        let resulting = new.blocks.map { final[$0.id] ?? $0.id }
        if resulting != oldIDs.filter(kept.contains) + ops.add.map(\.id) { ops.order = resulting }

        for block in new.blocks {
            guard let was = before[block.id] else { continue }
            var edit = BlockEdit()
            if block.on != was.on { edit.on = block.on }
            if block.model != was.model { edit.model = block.model }
            if block.effort != was.effort { edit.effort = block.effort }
            if block.role != was.role { edit.role = block.role }
            if block.takesOver != was.takesOver { edit.takesOver = block.takesOver }
            if edit != BlockEdit() { ops.set[block.id] = edit }
        }
        if let a = old.settings, let b = new.settings {
            if a.reviewRounds != b.reviewRounds { ops.reviewRounds = b.reviewRounds }
            if a.lang != b.lang { ops.lang = .some(b.lang) }
            if a.missingReview != b.missingReview { ops.missingReview = b.missingReview }
        }
        if !ops.isEmpty {
            ops.roles = Dictionary(new.blocks.filter { before[$0.id] != nil }.map { ($0.id, $0.role) },
                                   uniquingKeysWith: { a, _ in a })
        }
        return ops
    }

    /// The same edits on another version of the chain (reloaded after a change elsewhere, or the demo): removed
    /// and edited blocks that are gone are skipped, the order only if it is a permutation of the resulting ids.
    /// A new block whose id someone else took meanwhile stays new, with a temporary id again.
    public func applied(to draft: RevoDraft) -> RevoDraft {
        var result = draft
        result.blocks.removeAll { remove.contains($0.id) }
        var renamed: [String: String] = [:]
        for block in add {
            guard let other = result.blocks.first(where: { $0.id == block.id }) else {
                result.blocks.append(block)
                continue
            }
            var same = other
            same.id = block.id
            if same == block { continue }   // the same reviewer is already there
            var fresh = block
            fresh.id = RevoDraft.newID()
            renamed[block.id] = fresh.id
            result.blocks.append(fresh)
        }
        let order = order.map { $0.map { renamed[$0] ?? $0 } }
        if let order, order.sorted() == result.blocks.map(\.id).sorted() {
            let byID = Dictionary(result.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            result.blocks = order.compactMap { byID[$0] }
        }
        for i in result.blocks.indices {
            guard let edit = set[result.blocks[i].id] else { continue }
            if let on = edit.on { result.blocks[i].on = on }
            if let model = edit.model { result.blocks[i].model = model }
            if let effort = edit.effort { result.blocks[i].effort = effort }
            if let role = edit.role { result.blocks[i].role = role }
            if let takesOver = edit.takesOver { result.blocks[i].takesOver = takesOver }
        }
        if result.settings != nil {
            if let reviewRounds { result.settings?.reviewRounds = reviewRounds }
            if let lang { result.settings?.lang = lang }
            if let missingReview { result.settings?.missingReview = missingReview }
        }
        return result
    }

    /// stdin of `revo apply`.
    public func json(base: String) -> Data {
        var root: [String: Any] = ["schema": Revo.schema, "base": base]
        if !remove.isEmpty { root["remove"] = remove }
        if !add.isEmpty {
            root["add"] = add.map { b -> [String: Any] in
                ["id": b.id, "engine": b.engine, "model": b.model, "effort": b.effort, "on": b.on, "role": b.role,
                 "takes_over": b.takesOver]
            }
        }
        if let order { root["order"] = order }
        var set = self.set
        for (id, role) in roles where set[id]?.role == nil { set[id, default: BlockEdit()].role = role }
        if !set.isEmpty {
            root["set"] = set.mapValues { edit -> [String: Any] in
                var fields: [String: Any] = [:]
                if let on = edit.on { fields["on"] = on }
                if let model = edit.model { fields["model"] = model }
                if let effort = edit.effort { fields["effort"] = effort }
                if let role = edit.role { fields["role"] = role }
                if let takesOver = edit.takesOver { fields["takes_over"] = takesOver }
                return fields
            }
        }
        var settings: [String: Any] = [:]
        if let reviewRounds { settings["review_rounds"] = reviewRounds }
        if let lang { settings["lang"] = lang ?? NSNull() }
        if let missingReview { settings["missing_review"] = missingReview }
        if !settings.isEmpty { root["settings"] = settings }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }
}

/// What the settings tab edits: the blocks in order and the settings.
public struct RevoDraft: Equatable, Sendable {
    public var blocks: [RevoBlock]
    public var settings: RevoSettings?

    public init(_ chain: RevoChain) {
        blocks = chain.chain
        settings = chain.settings
    }

    /// A block added in the tab and not applied yet has a temporary id: `+` is not allowed in revo ids, so it
    /// never meets a real one. The final id is picked when the edits are built, from the model chosen by then.
    public static func isNew(_ id: String) -> Bool { id.hasPrefix("+") }

    public static func newID() -> String { "+" + UUID().uuidString }

    /// A short free id from the model: `claude-opus-5-5` → `opus`, `gpt-6.1-sol` → `sol`; the engine name for
    /// the default model. Only letters, digits and `._-`, as revo requires.
    static func freeID(for block: RevoBlock, taken: Set<String>) -> String {
        let vendors: Set<String> = ["claude", "gemini", "gpt", "codex", "openai", "anthropic", "google", "agy", "default"]
        let word = block.model.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "/" })
            .map { String($0.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) }
            .first { !$0.isEmpty && !vendors.contains($0) && !($0.first?.isNumber ?? true) }
        let base = word ?? block.engine
        var id = base, n = 2
        while taken.contains(id) {
            id = "\(base)\(n)"
            n += 1
        }
        return id
    }
}

/// Runs revo: from `/` (a project's `.revolver.json` must not apply), with `REVO_LANG` in the app's language,
/// at most `timeout` (revo gives up waiting for its lock after 3 s and answers "busy").
public enum Revo {
    public static let schema = 2
    /// Fixed places only (pipx/uv, Homebrew), no PATH and no repository directories; plus the user's choice.
    public static let candidates = ["~/.local/bin/revo", "/opt/homebrew/bin/revo", "/usr/local/bin/revo"]
    public static let upgradeCommand = "pipx upgrade revolver-review"
    static let timeout: TimeInterval = 8

    /// The path chosen in settings first, then the fixed places.
    public static func locate(custom: String?) -> String? {
        ProcessRunner.locate((custom.map { [$0] } ?? []) + candidates)
    }

    /// The revo the user's login shell finds (`command -v revo`), for an install outside the fixed places.
    /// An exception to looking binaries up at explicit paths: it runs the shell profile, so the caller asks only
    /// when revo is not found otherwise, at most once per launch. stdin is closed: a profile that waits for
    /// input gets EOF, a hung one is killed by the timeout.
    public static func fromShell(_ shell: String? = nil) async -> String? {
        let env = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let account = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? ""
        let shell = shell ?? [env, account].first { !$0.isEmpty } ?? "/bin/zsh"
        let user = NSUserName()
        guard let result = try? await ProcessRunner.runStatus(
            shell, ["-l", "-i", "-c", "command -v revo"], closeInput: true,
            environment: ["USER": user, "LOGNAME": user, "SHELL": shell, "TERM": "dumb"],
            directory: NSHomeDirectory(), timeout: 5),
            result.status == 0 else { return nil }
        return shellPath(String(decoding: result.output, as: UTF8.self))
    }

    /// The last line that is an absolute path: a shell profile may print anything before it.
    static func shellPath(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    /// revo speaks English and Russian; any other app language gets English messages.
    static var language: String { Localization.shared.code == "ru" ? "ru" : "en" }

    /// Checks that revo speaks schema 2. An old revo treats an unknown command as a review: run from `/`,
    /// that is a "not a git repository" error, never a review.
    public static func checkVersion(_ path: String) async throws {
        let result = try await run(path, ["version", "--json"])
        struct Version: Decodable { let schemas: [Int]? }
        guard result.status == 0, let v = try? JSONDecoder().decode(Version.self, from: result.output),
              v.schemas?.contains(schema) == true else { throw RevoFailure.outdated }
    }

    public static func list(_ path: String) async throws -> RevoChain {
        try decode(try await run(path, ["ls", "--json"]))
    }

    public static func engines(_ path: String) async throws -> [RevoEngine] {
        struct Answer: Decodable { let engines: [RevoEngine] }
        let answer: Answer = try decode(try await run(path, ["engines", "--json"]))
        return answer.engines
    }

    /// `check`: the same validation and diff without writing.
    public static func apply(_ path: String, _ ops: RevoOps, base: String, check: Bool) async throws -> RevoApplyResult {
        try decode(try await run(path, check ? ["apply", "--check"] : ["apply"], input: ops.json(base: base)))
    }

    private static func run(_ path: String, _ arguments: [String], input: Data? = nil) async throws -> (status: Int32, output: Data) {
        do {
            return try await ProcessRunner.runStatus(path, arguments, input: input, closeInput: input != nil,
                                                     environment: ["REVO_LANG": language], directory: "/",
                                                     timeout: timeout)
        } catch {
            throw RevoFailure.run(error.localizedDescription)
        }
    }

    private struct Envelope: Decodable { let schema: Int?; let ok: Bool?; let error: RevoError? }

    /// The common envelope: `schema`, `ok`, `error`. JSON comes on stdout whatever the exit code.
    static func decode<T: Decodable>(_ result: (status: Int32, output: Data)) throws -> T {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: result.output) else {
            throw RevoFailure.unreadable(status: result.status)
        }
        guard envelope.schema == schema else { throw RevoFailure.outdated }
        if envelope.ok != true {
            guard let error = envelope.error else { throw RevoFailure.unreadable(status: result.status) }
            // Our arguments are fixed: "usage" means a revo that does not know them.
            if error.code == "usage" { throw RevoFailure.outdated }
            throw RevoFailure.failed(error, status: result.status)
        }
        guard result.status == 0, let value = try? JSONDecoder().decode(T.self, from: result.output) else {
            throw RevoFailure.unreadable(status: result.status)
        }
        return value
    }
}
