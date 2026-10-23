import Foundation
import Observation
import SwiftUI  // Array.move(fromOffsets:toOffset:) is a SwiftUI extension
import UsageCore

/// The code review chain of Revolver (`revo`): the settings tab edits it, the popover shows its limits.
/// The config changes only through `revo apply` after an explicit Apply; revo's files are never read or written here.
/// revo runs on demand only (tab opening, Apply, popover opening), with no timer and no file watching.
@MainActor @Observable
final class ReviewChain {
    /// The revo in use; nil hides the tab and the popover line. In demo mode a placeholder: revo is never run.
    private(set) var path: String?
    /// The chain as revo last reported it.
    private(set) var loaded: RevoChain?
    private(set) var engines: [String: RevoEngine] = [:]
    /// The edited chain; Apply sends its difference from `loaded`.
    private(set) var draft: RevoDraft?
    /// What Apply will change (`apply --check`), shown for confirmation. Editing waits until it is gone.
    private(set) var preview: RevoApplyResult?
    private(set) var failure: RevoFailure?
    private(set) var busy = false
    /// Active limits by engine, for the popover. A failed call keeps them and only sets `limitsFailure`.
    private(set) var limits: [String: RevoLimit] = [:]
    private(set) var limitsFailure: RevoFailure?

    @ObservationIgnored private let settings: Settings
    /// The path whose schema was checked (`revo version`): once per path, not on every reload.
    @ObservationIgnored private var verified: String?
    @ObservationIgnored private var limitsAt: Date?

    init(settings: Settings) {
        self.settings = settings
        locate()
    }

    var isAvailable: Bool { path != nil }

    var edits: RevoOps {
        guard let loaded, let draft else { return RevoOps() }
        return RevoOps.between(RevoDraft(loaded), draft)
    }

    var hasEdits: Bool { !edits.isEmpty }

    /// Cheap (a few file checks): repeated on settings and popover opening, revo may have been installed meanwhile.
    func locate() {
        path = Demo.isOn ? "demo" : Revo.locate(custom: settings.revoPath)
    }

    func reload() async {
        locate()
        guard path != nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await fetch()
            failure = nil
        } catch {
            failure = Self.failure(error)
        }
    }

    private func fetch() async throws {
        guard let path else { return }
        if Demo.isOn {
            let demo = Demo.reviewChain()
            adopt(loaded ?? demo.chain, demo.engines)
            return
        }
        if verified != path {
            try await Revo.checkVersion(path)
            verified = path
        }
        async let chain = Revo.list(path)
        async let engines = Revo.engines(path)
        adopt(try await chain, try await engines)
    }

    /// A new version of the chain: unapplied edits are carried over onto it.
    private func adopt(_ chain: RevoChain, _ list: [RevoEngine]) {
        let edits = self.edits
        loaded = chain
        engines = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        draft = edits.applied(to: RevoDraft(chain))
        preview = nil
    }

    // MARK: Editing

    func update(_ id: String, _ change: (inout RevoBlock) -> Void) {
        guard preview == nil, let i = draft?.blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&draft!.blocks[i])
    }

    func move(from source: IndexSet, to destination: Int) {
        guard preview == nil else { return }
        draft?.blocks.move(fromOffsets: source, toOffset: destination)
    }

    func setRounds(_ rounds: Int) {
        guard preview == nil else { return }
        draft?.settings?.reviewRounds = rounds
    }

    func setLanguage(_ lang: String?) {
        guard preview == nil else { return }
        draft?.settings?.lang = lang
    }

    func revert() {
        draft = loaded.map(RevoDraft.init)
        preview = nil
        failure = nil
    }

    // MARK: Apply

    /// Apply, step one: revo validates the edits and reports what will change; nothing is written.
    func check() async {
        guard let path, let loaded, hasEdits, !busy else { return }
        if Demo.isOn {
            applyInDemo()
            return
        }
        busy = true
        defer { busy = false }
        do {
            preview = try await Revo.apply(path, edits, base: loaded.configRev, check: true)
            failure = nil
        } catch {
            await fail(error)
        }
    }

    /// Step two: write what was checked, against the revision it was checked on.
    func confirm() async {
        guard let path, let preview, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await Revo.apply(path, edits, base: preview.configRev, check: false)
            self.preview = nil
            try await fetch()
            failure = nil
        } catch {
            await fail(error)
        }
    }

    func cancelPreview() {
        preview = nil
    }

    /// Changed elsewhere (code 4): reload, the edits stay on top of the new version for another look.
    private func fail(_ error: Error) async {
        let failure = Self.failure(error)
        preview = nil
        if failure.isConfigChanged { try? await fetch() }
        self.failure = failure
    }

    private func applyInDemo() {
        guard var chain = loaded, let draft else { return }
        chain.chain = draft.blocks
        chain.settings = draft.settings
        loaded = chain
    }

    private static func failure(_ error: Error) -> RevoFailure {
        error as? RevoFailure ?? .run(error.localizedDescription)
    }

    // MARK: Popover

    /// On popover opening, at most every 15 s.
    func refreshLimits() {
        guard settings.showReviewLimits else { return }
        locate()
        guard let path else { return }
        if Demo.isOn {
            limits = Demo.reviewLimits()
            return
        }
        if let limitsAt, Date().timeIntervalSince(limitsAt) < 15 { return }
        limitsAt = Date()
        Task {
            do {
                limits = try await Revo.status(path)
                limitsFailure = nil
            } catch {
                limitsFailure = Self.failure(error)
            }
        }
    }

    /// Limits still in force, by engine name.
    func activeLimits(now: Date) -> [(engine: String, until: Date)] {
        limits.compactMap { name, limit in limit.until.map { (name, Date(timeIntervalSince1970: TimeInterval($0))) } }
            .filter { $0.until > now }
            .sorted { $0.engine < $1.engine }
    }

    // MARK: Texts

    /// Before the tab has loaded the engines, the popover still needs names.
    private static let knownEngines = ["codex": "Codex", "agy": "Gemini", "claude": "Claude"]

    func engineName(_ name: String) -> String {
        engines[name]?.display ?? Self.knownEngines[name] ?? name
    }

    /// "Codex · sol"; just "Codex" when the id is the engine's name (the built-in chain).
    func blockName(_ id: String) -> String {
        guard let block = draft?.blocks.first(where: { $0.id == id }) ?? loaded?.chain.first(where: { $0.id == id })
        else { return id }
        let engine = engineName(block.engine)
        return id == block.engine || id.lowercased() == engine.lowercased() ? engine : "\(engine) · \(id)"
    }

    /// The line under a block's name and whether it is a warning.
    func note(_ block: RevoBlock, now: Date) -> (text: String, warning: Bool)? {
        if let state = loaded?.state[block.id], state.active, let until = state.limitUntil {
            return (L("limit, resets %@", Format.resetIn(Date(timeIntervalSince1970: TimeInterval(until)), now: now)), true)
        }
        if engines[block.engine]?.installed == false { return (L("CLI not found"), true) }
        switch block.takesOver {
        case "limit": return (L("runs if the one above hits a limit"), false)
        case "any_fail": return (L("runs if the one above fails"), false)
        default: return nil
        }
    }

    /// The confirmation lines for `apply --check`.
    func describe(_ diff: RevoDiff) -> [String] {
        func value(_ v: RevoValue?) -> String {
            guard let v else { return "—" }
            return v == .string("default") ? L("default") : v.description
        }
        func language(_ v: RevoValue?) -> String {
            guard case .string(let code)? = v else { return L("System default") }
            return Localization.name(code)
        }
        var lines: [String] = []
        if let order = diff.order {
            lines.append(L("Order: %@", order.new.map(blockName).joined(separator: " → ")))
        }
        for c in diff.changes {
            let name = blockName(c.id ?? "?")
            switch c.field {
            case "on": lines.append(c.new == .bool(true) ? L("%@: turn on", name) : L("%@: turn off", name))
            case "model": lines.append(L("%@: model %@ → %@", name, value(c.old), value(c.new)))
            case "effort": lines.append(L("%@: effort %@ → %@", name, value(c.old), value(c.new)))
            default: lines.append("\(name): \(c.field) \(value(c.old)) → \(value(c.new))")
            }
        }
        for c in diff.settings {
            switch c.field {
            case "review_rounds": lines.append(L("Review rounds: %@ → %@", value(c.old), value(c.new)))
            case "lang": lines.append(L("Review language: %@ → %@", language(c.old), language(c.new)))
            default: lines.append("\(c.field): \(value(c.old)) → \(value(c.new))")
            }
        }
        return lines
    }
}
