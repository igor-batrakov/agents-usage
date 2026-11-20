import AppKit
import Observation
import SwiftUI  // Array.move(fromOffsets:toOffset:) is a SwiftUI extension
import UsageCore

/// The code review chain of Revolver (`revo`): the settings tab edits it, the popover shows required reviewers on
/// a limit. The config changes only through `revo apply` after an explicit Apply; revo's files are never read or
/// written here. revo runs on demand only (tab opening, Apply, popover opening, the model list button) and once at
/// launch for model lists older than a day, with no timer and no file watching.
@MainActor @Observable
final class ReviewChain {
    /// The revo in use; nil hides the tab and the popover line. In demo mode a placeholder: revo is never run.
    private(set) var path: String?
    /// The chain as revo last reported it.
    private(set) var loaded: RevoChain?
    private(set) var engines: [String: RevoEngine] = [:]
    /// The same engines in revo's order, for the provider picker of a new block.
    private(set) var engineList: [RevoEngine] = []
    /// The edited chain; Apply sends its difference from `loaded`.
    private(set) var draft: RevoDraft?
    /// What Apply will change (`apply --check`), shown for confirmation. Editing waits until it is gone.
    private(set) var preview: RevoApplyResult?
    private(set) var failure: RevoFailure?
    private(set) var busy = false
    /// `apply --check` is running.
    private(set) var checking = false
    /// The chain with its limits as of the last popover opening. A failed call keeps it and only sets `limitsFailure`.
    private(set) var latest: RevoChain?
    private(set) var limitsFailure: RevoFailure?
    /// The revo path typed, pasted or dropped in settings, before it is checked.
    var pathInput = ""
    /// Why the path given by hand was not taken.
    private(set) var pathError: String?
    /// The login shell or a path given by hand is being checked.
    private(set) var searching = false
    /// The last `revo models` answer by engine name: why a list could not be fetched.
    private(set) var modelLists: [String: RevoModelList] = [:]
    /// `revo models` is running; editing does not wait for it.
    private(set) var fetchingModels = false
    private(set) var modelsFailure: RevoFailure?
    /// The revo that has no `models` command: the update button is hidden for it.
    private(set) var noModelsCommand: String?

    @ObservationIgnored private let settings: Settings
    /// The path whose schema was checked (`revo version`): once per path, not on every reload.
    @ObservationIgnored private var verified: String?
    @ObservationIgnored private var limitsAt: Date?
    /// The edits `preview` describes; Confirm writes exactly these.
    @ObservationIgnored private var checked = RevoOps()
    /// The login shell is asked at most once per launch: that runs the user's shell profile.
    @ObservationIgnored private var askedShell = false
    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var enginesAsked = 0
    @ObservationIgnored private var enginesShown = 0

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

    /// The block's model has no effort revo passes (`unusable`): revo would refuse the write (`invalid_effort`).
    func isUnusable(_ block: RevoBlock) -> Bool {
        engines[block.engine]?.unusable.contains(block.model) == true
    }

    /// A new block or a changed model that revo would refuse holds Apply back (after the engines are read again). An applied block keeping its model is
    /// only marked: the write does not send its model, and the user may be fixing something else first.
    var blocksApply: Bool {
        guard let draft else { return false }
        return draft.blocks.contains { block in
            isUnusable(block) && loaded?.chain.first(where: { $0.id == block.id })?.model != block.model
        }
    }

    /// Editing waits for the check and its confirmation: the draft then is exactly what gets written, and after
    /// the write the chain is taken as revo reports it.
    var editable: Bool { preview == nil && !checking }

    /// Cheap (a few file checks): repeated on settings and popover opening, revo may have been installed meanwhile.
    func locate() {
        path = Demo.isOn ? "demo" : Revo.locate(custom: settings.revoPath)
    }

    /// revo outside the fixed places: the login shell's `command -v revo`, kept as the chosen path if it checks out.
    /// Only while revo is not found, once per launch, on settings opening; never in demo mode.
    func discover() async {
        guard path == nil, !askedShell, !searching, !Demo.isOn else { return }
        askedShell = true
        searching = true
        defer { searching = false }
        guard let found = await Revo.fromShell(), await Self.verify(found) == nil else { return }
        keep(found)
    }

    /// revo outside the fixed places, e.g. a symlink in a directory of your own. True when one was taken.
    @discardableResult
    func choosePath() async -> Bool {
        guard !searching else { return false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = L("Choose the revo executable")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return await use(url.path)
    }

    /// A path typed, pasted or dropped (`~` is expanded); taken only if it is revo speaking schema 2.
    @discardableResult
    func use(_ raw: String) async -> Bool {
        let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !path.isEmpty, !searching else { return false }
        searching = true
        defer { searching = false }
        if let error = await Self.verify(path) {
            pathError = error
            return false
        }
        keep(path)
        return true
    }

    private func keep(_ path: String) {
        pathError = nil
        pathInput = ""
        settings.revoPath = path
        verified = path
        locate()
        Task { await reload() }
    }

    /// Why `path` is not a usable revo, or nil.
    private static func verify(_ path: String) async -> String? {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            return L("No executable file at %@", (path as NSString).abbreviatingWithTildeInPath)
        }
        do {
            try await Revo.checkVersion(path)
            return nil
        } catch RevoFailure.outdated {
            // Any other program fails the version check the same way.
            return L("This is not revo, or a revo too old for the app. Update it: %@", Revo.upgradeCommand)
        } catch {
            return failure(error).text
        }
    }

    /// A reload already running is awaited, not repeated: its callers then fetch the model lists after it.
    func reload() async {
        if let reloading { return await reloading.value }
        locate()
        guard path != nil, !busy else { return }
        busy = true
        let task = Task {
            do {
                try await fetch()
                failure = nil
            } catch {
                failure = Self.failure(error)
            }
        }
        reloading = task
        await task.value
        reloading = nil
        busy = false
    }

    /// `carry`: replay the unapplied edits onto the new version; false right after our own write, which left none.
    private func fetch(carry: Bool = true) async throws {
        guard let path else { return }
        if Demo.isOn {
            let demo = Demo.reviewChain()
            adopt(loaded ?? demo.chain, demo.engines, enginesTicket(), carry: carry)
            return
        }
        if verified != path {
            try await Revo.checkVersion(path)
            verified = path
        }
        let ticket = enginesTicket()
        async let chain = Revo.list(path)
        async let engines = Revo.engines(path)
        adopt(try await chain, try await engines, ticket, carry: carry)
    }

    private func adopt(_ chain: RevoChain, _ list: [RevoEngine], _ ticket: Int, carry: Bool) {
        let edits = self.edits
        loaded = chain
        setEngines(list, ticket)
        // Blocks added and not applied yet come back with their final ids: `edits` holds them in `add`.
        draft = carry ? edits.applied(to: RevoDraft(chain)) : RevoDraft(chain)
        preview = nil
    }

    /// Numbers `revo engines` calls in the order they start. A reload and a model list update run side by side, and
    /// an answer asked for before `revo models` saved the lists must not replace one asked for after it.
    private func enginesTicket() -> Int {
        enginesAsked += 1
        return enginesAsked
    }

    private func setEngines(_ list: [RevoEngine], _ ticket: Int) {
        guard ticket > enginesShown else { return }
        enginesShown = ticket
        engines = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        engineList = list
    }

    /// The update button makes sense: revo is found, knows `models`, and this is not the demo.
    var canFetchModels: Bool {
        guard let path, !Demo.isOn else { return false }
        return noModelsCommand != path
    }

    /// `revo models` (on tab opening without `refresh`: only lists older than a day; the button refreshes all), then
    /// the engines again, which merge the saved lists. The draft and the edits are left alone.
    func updateModels(refresh: Bool) async {
        guard canFetchModels, let path, !fetchingModels else { return }
        fetchingModels = true
        defer { fetchingModels = false }
        do {
            let lists = try await Revo.models(path, refresh: refresh)
            let ticket = enginesTicket()
            let list = try await Revo.engines(path)
            // Another revo chosen meanwhile: its own reload has the right engines, these are of the old one.
            guard self.path == path else { return }
            modelLists = lists
            modelsFailure = nil
            setEngines(list, ticket)
        } catch RevoFailure.outdated {
            noModelsCommand = path
            modelsFailure = nil
        } catch {
            if self.path == path { modelsFailure = Self.failure(error) }
        }
    }

    /// The newest fetch among the engines, nil if no list was ever fetched.
    var modelsFetchedAt: Date? {
        engineList.compactMap(\.modelsFetchedAt).max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// Why lists were not fetched: every failure, and a skipped engine only if the chain uses it (an engine that is
    /// not set up is no news otherwise).
    var modelProblems: [String] {
        let used = Set((draft?.blocks ?? []).map(\.engine))
        return engineList.compactMap { engine in
            guard let list = modelLists[engine.name], let error = list.error else { return nil }
            let show = list.status == RevoModelList.failed || (list.status == RevoModelList.skipped && used.contains(engine.name))
            return show ? "\(engine.display): \(error.message)" : nil
        }
    }

    /// Added in the tab and not applied yet: its engine can still change.
    func isPending(_ id: String) -> Bool {
        loaded?.chain.contains { $0.id == id } == false
    }

    // MARK: Editing

    func update(_ id: String, _ change: (inout RevoBlock) -> Void) {
        guard editable, let i = draft?.blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&draft!.blocks[i])
    }

    /// A required block always runs (`-`); a fallback keeps its condition or steps in on any failure.
    func setRole(_ id: String, _ role: String) {
        update(id) { block in
            block.role = role
            if role == RevoRole.required {
                block.takesOver = RevoTakesOver.none
            } else if block.takesOver == RevoTakesOver.none {
                block.takesOver = RevoTakesOver.anyFail
            }
        }
    }

    /// A model from the list; the effort moves to the nearest one the model takes, if it is outside: revo refuses
    /// the write otherwise (`invalid_effort`). A typed model is fitted at Apply (`fitEfforts`).
    func setModel(_ id: String, _ model: String) {
        update(id) { block in
            block.model = model
            if let engine = engines[block.engine] { block.effort = engine.effort(block.effort, for: model) }
        }
    }

    /// Only for a block that is not applied yet: `apply` cannot change the engine of an existing one.
    func setEngine(_ id: String, _ name: String) {
        guard isPending(id), let engine = engines[name] else { return }
        update(id) { block in
            block.engine = name
            block.model = engine.models.first ?? "default"
            block.effort = engine.defaultEffort
            block.project = nil   // only `vertex` takes one, and a new block starts with the default
        }
    }

    /// The Google Cloud project of a `vertex` block; empty: the default (`REVO_VERTEX_PROJECT`, then gcloud).
    func setProject(_ id: String, _ project: String?) {
        let trimmed = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        update(id) { $0.project = trimmed.isEmpty ? nil : trimmed }
    }

    /// "My project — my-project-123" when the id is in the account's list, else the id as it is.
    func projectName(_ id: String?, engine: String) -> String {
        guard let id else { return L("default (gcloud)") }
        guard let project = engines[engine]?.projects.first(where: { $0.id == id }), project.name != id else { return id }
        return "\(project.name) — \(id)"
    }

    /// A new reviewer at the end: an installed engine, its default model, a fallback stepping in on any failure.
    func addBlock() {
        guard editable, draft != nil,
              let engine = engineList.first(where: \.installed) ?? engineList.first else { return }
        draft?.blocks.append(RevoBlock(id: RevoDraft.newID(), engine: engine.name, model: engine.models.first ?? "default",
                                       effort: engine.defaultEffort))
    }

    func removeBlock(_ id: String) {
        guard editable else { return }
        draft?.blocks.removeAll { $0.id == id }
    }

    func setMissingReview(_ value: String) {
        guard editable else { return }
        draft?.settings?.missingReview = value
    }

    func move(from source: IndexSet, to destination: Int) {
        guard editable else { return }
        draft?.blocks.move(fromOffsets: source, toOffset: destination)
    }

    func setRounds(_ rounds: Int) {
        guard editable else { return }
        draft?.settings?.reviewRounds = rounds
    }

    func setLanguage(_ lang: String?) {
        guard editable else { return }
        draft?.settings?.lang = lang
    }

    func revert() {
        draft = loaded.map(RevoDraft.init)
        preview = nil
        failure = nil
    }

    // MARK: Apply

    /// A typed model changes only the name while typing (a prefix may be another model); its effort is fitted to
    /// the final model here, before the check, so the diff shows it and revo does not refuse it (`invalid_effort`).
    private func fitEfforts(_ loaded: RevoChain) {
        guard var blocks = draft?.blocks else { return }
        for i in blocks.indices {
            let block = blocks[i]
            guard loaded.chain.first(where: { $0.id == block.id })?.model != block.model,
                  let engine = engines[block.engine] else { continue }
            blocks[i].effort = engine.effort(block.effort, for: block.model)
        }
        draft?.blocks = blocks
    }

    /// Apply, step one: revo validates the edits and reports what will change; nothing is written.
    func check() async {
        guard let path, let loaded, hasEdits, !busy else { return }
        if Demo.isOn {
            guard !blocksApply else { return }
            fitEfforts(loaded)
            applyInDemo()
            return
        }
        busy = true
        checking = true
        defer { busy = false; checking = false }
        do {
            // The list may be stale (a failed reload after `revo models`): ask revo again before holding Apply back.
            if blocksApply {
                let ticket = enginesTicket()
                let list = try await Revo.engines(path)
                guard self.path == path else { return }
                setEngines(list, ticket)
                // Still unusable: revo is not asked to check what it would refuse.
                if blocksApply {
                    failure = .run(L("A reviewer has a model revo cannot use: choose another one."))
                    return
                }
            }
            fitEfforts(loaded)
            let ops = edits
            preview = try await Revo.apply(path, ops, base: loaded.configRev, check: true)
            checked = ops
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
            _ = try await Revo.apply(path, checked, base: preview.configRev, check: false)
            self.preview = nil
            try await fetch(carry: false)
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

    /// As revo would: new blocks get their final ids.
    private func applyInDemo() {
        guard var chain = loaded else { return }
        let result = edits.applied(to: RevoDraft(chain))
        chain.chain = result.blocks
        chain.settings = result.settings
        loaded = chain
        latest = chain
        draft = result
    }

    private static func failure(_ error: Error) -> RevoFailure {
        error as? RevoFailure ?? .run(error.localizedDescription)
    }

    // MARK: Popover

    /// On popover opening, at most every 15 s: `ls`, which has both the roles and the limits.
    func refreshLimits() {
        guard settings.showReviewLimits else { return }
        locate()
        guard let path else { return }
        if Demo.isOn {
            latest = loaded ?? Demo.reviewChain().chain
            return
        }
        if let limitsAt, Date().timeIntervalSince(limitsAt) < 15 { return }
        limitsAt = Date()
        Task {
            do {
                // `ls` is old enough to exist in every revo; another schema fails as outdated.
                latest = try await Revo.list(path)
                limitsFailure = nil
            } catch {
                limitsFailure = Self.failure(error)
            }
        }
    }

    /// Enabled required reviewers on a limit at `now`, with the fallback that reviews instead (nil: nobody).
    func limitedReviewers(now: Date) -> [(required: RevoBlock, until: Date, by: RevoBlock?)] {
        guard let latest else { return [] }
        let limited = Set(latest.chain.compactMap { latest.limit($0.id, now: now) == nil ? nil : $0.id })
        return latest.chain.cover(limited: limited).compactMap { item in
            latest.limit(item.required.id, now: now).map { (item.required, $0, item.by) }
        }
    }

    // MARK: Texts

    /// Before the tab has loaded the engines, the popover still needs names (as revo's `vendor`).
    private static let knownEngines = ["codex": "Codex", "claude": "Claude Code", "agy": "Gemini", "gemini": "Gemini",
                                       "vertex": "Gemini"]

    /// The vendor: "Claude Code", "Codex", "Gemini".
    func engineName(_ name: String) -> String {
        engines[name]?.title ?? Self.knownEngines[name] ?? name
    }

    /// The vendor, told apart by the model when the chain it is in has another block of the same vendor.
    func blockName(_ id: String) -> String {
        // Separate lists: one long `+` of optionals is too slow to type-check for older compilers (CI).
        let lists: [[RevoBlock]?] = [draft?.blocks, loaded?.chain, latest?.chain, preview?.diff.added]
        for list in lists {
            if let list, let block = list.first(where: { $0.id == id }) { return name(block, among: list) }
        }
        return id
    }

    /// Just the vendor ("Codex"), with no id: next to the model field it needs nothing more. In a line of text,
    /// `among` the blocks of its chain, a second block of the same vendor adds the model ("Codex · gpt-6.1-sol"),
    /// and one with the same model too adds the id, so the confirmation never shows two blocks alike.
    func name(_ block: RevoBlock, among blocks: [RevoBlock] = []) -> String {
        let vendor = engineName(block.engine)
        let twins = blocks.filter { $0.id != block.id && engineName($0.engine) == vendor }
        if twins.isEmpty { return vendor }
        let model = modelName(block.model)
        // A block not applied yet has only a temporary id: the model is all there is to show.
        if RevoDraft.isNew(block.id) || !twins.contains(where: { $0.model == block.model }) { return "\(vendor) · \(model)" }
        return "\(vendor) · \(model) (\(block.id))"
    }

    func modelName(_ model: String) -> String { model == "default" ? L("default") : model }

    /// The line under a block's controls and whether it is a warning: limit, missing CLI, chain warnings, and for
    /// a fallback the required reviewer it goes for first.
    func note(_ index: Int, in blocks: [RevoBlock], now: Date) -> (text: String, warning: Bool)? {
        let block = blocks[index]
        var warnings: [String] = []
        // `active` is as of the last reload; the tab may stay open past the reset.
        if let until = loaded?.limit(block.id, now: now) { warnings.append(L("limit, resets %@", Format.resetIn(until, now: now))) }
        if engines[block.engine]?.installed == false { warnings.append(L("CLI not found")) }
        if isUnusable(block) {
            warnings.append(L("model has no effort levels revo passes"))
        } else if let engine = engines[block.engine], !engine.accepts(block.model) {
            warnings.append(L("invalid model name"))
        }
        if let project = block.project, let engine = engines[block.engine], !engine.acceptsProject(project) {
            warnings.append(L("invalid project ID"))
        }
        switch blocks.warning(at: index) {
        case .neverRuns?: warnings.append(L("never runs: no required reviewer above it"))
        case .noFallback?: warnings.append(L("no fallback below it"))
        case nil: break
        }
        if !warnings.isEmpty { return (warnings.joined(separator: " · "), true) }
        if block.on, let covered = blocks.coveredFirst(at: index) {
            return (L("↳ for %@", name(covered, among: blocks)), false)
        }
        return nil
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
        func role(_ v: RevoValue?) -> String { v == .string(RevoRole.required) ? L("required") : L("fallback") }
        var lines: [String] = []
        for id in diff.removed { lines.append(L("Remove %@", blockName(id))) }
        for block in diff.added {
            lines.append(L("Add %@: %@, %@, %@", name(block), modelName(block.model), block.effort, roleText(block)))
            if block.project != nil {
                lines.append(L("%@: Google Cloud project %@", name(block), projectName(block.project, engine: block.engine)))
            }
        }
        if let order = diff.order {
            lines.append(L("Order: %@", order.new.map(blockName).joined(separator: " → ")))
        }
        for c in diff.changes {
            let name = blockName(c.id ?? "?")
            switch c.field {
            case "on": lines.append(c.new == .bool(true) ? L("%@: turn on", name) : L("%@: turn off", name))
            case "model": lines.append(L("%@: model %@ → %@", name, value(c.old), value(c.new)))
            case "effort": lines.append(L("%@: effort %@ → %@", name, value(c.old), value(c.new)))
            case "role": lines.append(L("%@: %@ → %@", name, role(c.old), role(c.new)))
            // Becoming required sets `-`: the role line already says it.
            case "takes_over" where c.new != .string(RevoTakesOver.none):
                lines.append(L("%@: steps in %@", name, condition(c.new?.description ?? "")))
            case "takes_over": break
            case "project":
                // A removed project comes as null: the default again.
                let blocks: [RevoBlock] = loaded?.chain ?? []
                let engine: String = blocks.first(where: { $0.id == c.id })?.engine ?? "vertex"
                func project(_ v: RevoValue?) -> String {
                    guard case .string(let id)? = v else { return L("default (gcloud)") }
                    return projectName(id, engine: engine)
                }
                lines.append(L("%@: Google Cloud project %@ → %@", name, project(c.old), project(c.new)))
            default: lines.append("\(name): \(c.field) \(value(c.old)) → \(value(c.new))")
            }
        }
        for c in diff.settings {
            switch c.field {
            case "review_rounds": lines.append(L("Review rounds: %@ → %@", value(c.old), value(c.new)))
            case "lang": lines.append(L("Review language: %@ → %@", language(c.old), language(c.new)))
            case "missing_review":
                lines.append(L("No review from a required reviewer: %@", missingReview(c.new?.description ?? "")))
            default: lines.append("\(c.field): \(value(c.old)) → \(value(c.new))")
            }
        }
        return lines
    }

    /// "required" or "fallback, if it hits a limit".
    func roleText(_ block: RevoBlock) -> String {
        block.isRequired ? L("required") : L("fallback") + ", " + condition(block.takesOver)
    }

    /// `-` on a fallback reads as `any_fail` in revo.
    func condition(_ takesOver: String) -> String {
        takesOver == RevoTakesOver.limit ? L("if it hits a limit") : L("if it gives no review")
    }

    func missingReview(_ value: String) -> String {
        value == "note" ? L("commit with a note") : L("wait for my decision")
    }
}
