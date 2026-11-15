import SwiftUI
import UsageCore

/// Settings tab for the Revolver review chain: reviewers in priority order (drag), each one on/off, provider,
/// model, effort, role and, for a fallback, when it steps in; adding and removing; the chain settings.
/// Shown only when revo is found.
struct ReviewChainTab: View {
    let chain: ReviewChain
    @Bindable var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            if let draft = chain.draft {
                if !draft.blocks.hasEnabledRequired {
                    Label(L("No required reviewer is on: reviews will not start."), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: Theme.amber))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    List {
                        ForEach(Array(draft.blocks.enumerated()), id: \.element.id) { index, _ in
                            BlockRow(index: index, blocks: draft.blocks, chain: chain, now: context.date)
                        }
                        .onMove { chain.move(from: $0, to: $1) }
                    }
                }
                .disabled(!chain.editable)
                HStack {
                    Button { chain.addBlock() } label: { Label(L("Add reviewer"), systemImage: "plus") }
                        .buttonStyle(.borderless)
                        .disabled(!chain.editable || chain.engineList.isEmpty)
                    Spacer()
                    Text(L("drag to reorder: higher goes first")).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                modelLists
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            } else {
                Group {
                    if chain.busy { ProgressView() } else { Text(L("The review chain is not loaded.")).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(12)
        }
        .onAppear {
            Task {
                await chain.reload()
                // Only lists older than a day are fetched: usually an instant answer from revo's saved lists.
                await chain.updateModels(refresh: false)
            }
        }
    }

    /// When the model lists were fetched, the button that fetches them all again, and why some could not be.
    @ViewBuilder private var modelLists: some View {
        if chain.canFetchModels || chain.modelsFetchedAt != nil {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let at = chain.modelsFetchedAt {
                        Text(L("Model lists updated %@", Format.date(at)))
                    } else {
                        Text(L("Model lists not fetched yet"))
                    }
                    if chain.canFetchModels {
                        Button(L("Update model lists")) { Task { await chain.updateModels(refresh: true) } }
                            .buttonStyle(.link)
                            .disabled(chain.fetchingModels)
                            .help(L("Asks the providers which models they offer. No model is run and nothing is spent; it can take half a minute."))
                        if chain.fetchingModels { ProgressView().controlSize(.mini) }
                    }
                }
                ForEach(chain.modelProblems, id: \.self) { Text($0).foregroundStyle(Color(nsColor: Theme.amber)) }
                if let failure = chain.modelsFailure {
                    Text(L("Model lists: %@", failure.text)).foregroundStyle(Color(nsColor: Theme.amber))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chainSettings = chain.draft?.settings {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 20) {
                        Stepper(value: Binding(get: { chainSettings.reviewRounds }, set: { chain.setRounds($0) }),
                                in: RevoSettings.rounds) {
                            Text(L("Review rounds per commit: %d", chainSettings.reviewRounds))
                        }
                        Picker(L("Review language"), selection: Binding(get: { chainSettings.lang }, set: { chain.setLanguage($0) })) {
                            Text(L("System default")).tag(String?.none)
                            ForEach(["en", "ru"], id: \.self) { Text(Localization.name($0)).tag(Optional($0)) }
                        }
                        .fixedSize()
                    }
                    Text(L("A round is one run of the whole chain; the remarks of the last one are fixed without another review. The number is shared by all reviewers; a project can set its own in .revolver.json."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(L("No review from a required reviewer:"),
                           selection: Binding(get: { chainSettings.missingReview }, set: { chain.setMissingReview($0) })) {
                        Text(chain.missingReview("ask")).tag("ask")
                        Text(chain.missingReview("note")).tag("note")
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                .disabled(!chain.editable)
            }
            if let preview = chain.preview {
                let lines = chain.describe(preview.diff)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Apply these changes?")).fontWeight(.semibold)
                    // The window does not resize: a long diff scrolls, a short one takes only its own height.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(lines, id: \.self) { Text("• " + $0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(CGFloat(lines.count) * 19, 133))
                }
                .font(.callout)
            }
            if let failure = chain.failure {
                Label(failure.text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: Theme.amber))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Toggle(L("Show review limits in the popover"), isOn: $settings.showReviewLimits)
                    .toggleStyle(.checkbox)
                Spacer()
                if chain.busy { ProgressView().controlSize(.small) }
                Button { Task { await chain.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(chain.busy)
                    .help(L("Reload the chain from revo"))
                if chain.preview != nil {
                    Button(L("Cancel")) { chain.cancelPreview() }
                        .keyboardShortcut(.cancelAction)
                    Button(L("Apply")) { Task { await chain.confirm() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(chain.busy)
                } else {
                    Button(L("Revert")) { chain.revert() }
                        .disabled(!chain.hasEdits || chain.busy)
                    Button(L("Apply…")) { Task { await chain.check() } }
                        .disabled(!chain.hasEdits || chain.busy)
                }
            }
            paths
        }
    }

    /// Which file the tab edits and which revo it runs.
    private var paths: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let loaded = chain.loaded {
                let file = (loaded.configPath as NSString).abbreviatingWithTildeInPath
                Text(loaded.configRev == "defaults" ? L("Built-in chain. Apply creates %@", file) : L("Edits %@", file))
            }
            if !Demo.isOn, let path = chain.path {
                HStack(spacing: 6) {
                    Text(verbatim: "revo: " + (path as NSString).abbreviatingWithTildeInPath)
                    Button(L("Choose…")) { Task { await chain.choosePath() } }.buttonStyle(.link)
                    if settings.revoPath != nil {
                        Button(L("Default")) {
                            settings.revoPath = nil
                            Task { await chain.reload() }
                        }
                        .buttonStyle(.link)
                    }
                }
                // A pending check would overwrite a newer choice.
                .disabled(chain.searching)
                if let error = chain.pathError {
                    Text(error).foregroundStyle(Color(nsColor: Theme.amber))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

/// Two lines: on/off, provider, model, effort, remove; then role, condition and the note. A fallback is indented
/// under the required reviewers above it.
private struct BlockRow: View {
    let index: Int
    let blocks: [RevoBlock]
    let chain: ReviewChain
    let now: Date

    private var block: RevoBlock { blocks[index] }

    var body: some View {
        let engine = chain.engines[block.engine]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { block.on }, set: { v in chain.update(block.id) { $0.on = v } }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                provider(engine)
                    .frame(width: 140, alignment: .leading)
                    .opacity(block.on ? 1 : 0.5)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    TextField("", text: Binding(get: { block.model }, set: { v in chain.update(block.id) { $0.model = v } }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .disabled(engine?.customModel == false)
                    Menu {
                        ForEach(engine?.models ?? [], id: \.self) { model in
                            let name = chain.modelName(model)
                            let isNew = engine?.discovered.contains(model) == true
                            Button(isNew ? L("%@ (new, no reviews yet)", name) : name) { chain.setModel(block.id, model) }
                        }
                    } label: { EmptyView() }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L("Known models"))
                }
                Picker("", selection: Binding(get: { block.effort }, set: { v in chain.update(block.id) { $0.effort = v } })) {
                    // The current value stays selectable even if revo no longer lists it.
                    ForEach(efforts(engine), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                .help(L("Effort"))
                Button { chain.removeBlock(block.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help(L("Remove reviewer"))
            }
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { block.role }, set: { chain.setRole(block.id, $0) })) {
                    Text(L("required")).tag(RevoRole.required)
                    Text(L("fallback")).tag(RevoRole.fallback)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(L("A required reviewer runs on every review, in parallel with the others. A fallback reviews instead of a required one above it that gave no review."))
                if !block.isRequired {
                    Picker("", selection: Binding(
                        get: { block.takesOver == RevoTakesOver.limit ? RevoTakesOver.limit : RevoTakesOver.anyFail },
                        set: { v in chain.update(block.id) { $0.takesOver = v } })) {
                        Text(chain.condition(RevoTakesOver.limit)).tag(RevoTakesOver.limit)
                        Text(chain.condition(RevoTakesOver.anyFail)).tag(RevoTakesOver.anyFail)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let note = chain.note(index, in: blocks, now: now) {
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.warning ? Color(nsColor: Theme.amber) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note.text)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.leading, 24)
            if let engine, engine.takesProject { project(engine) }
        }
        .padding(.leading, block.isRequired ? 0 : 20)
        .padding(.vertical, 3)
    }

    /// An applied block keeps its engine (`apply` cannot change it); a new one picks from revo's list.
    @ViewBuilder private func provider(_ engine: RevoEngine?) -> some View {
        if chain.isPending(block.id) {
            Picker("", selection: Binding(get: { block.engine }, set: { chain.setEngine(block.id, $0) })) {
                ForEach(chain.engineList, id: \.name) { e in
                    // `display`, not the vendor: the picker has to tell agy, the Gemini API and Vertex apart.
                    Text(e.installed ? e.display : L("%@ (not installed)", e.display)).tag(e.name)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(engine?.installed == false ? L("The CLI of this provider was not found") : L("Provider"))
        } else {
            Text(chain.name(block))
                .lineLimit(1)
                .foregroundStyle(engine?.installed == false ? .secondary : .primary)
                // revo's own name in the tooltip tells engines of one vendor apart ("Gemini Vertex").
                .help(engine?.installed == false ? L("The CLI of this provider was not found") : engine?.display ?? chain.name(block))
        }
    }

    /// The Google Cloud project a Vertex review is billed to: typed, or picked from the gcloud account's projects
    /// (`revo models` saves them). Empty is the default: `REVO_VERTEX_PROJECT`, then gcloud's active project.
    private func project(_ engine: RevoEngine) -> some View {
        HStack(spacing: 4) {
            Text(L("Google Cloud project:"))
            TextField(L("default (gcloud)"), text: Binding(get: { block.project ?? "" }, set: { chain.setProject(block.id, $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
            Menu {
                Button(L("default (gcloud)")) { chain.setProject(block.id, nil) }
                Divider()
                ForEach(engine.projects, id: \.id) { p in
                    Button(chain.projectName(p.id, engine: engine.name)) { chain.setProject(block.id, p.id) }
                }
            } label: { EmptyView() }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Projects of your gcloud account"))
            // The field holds the id; the account's name for it, when the list has one, goes next to it.
            if let name = engine.projects.first(where: { $0.id == block.project })?.name, name != block.project {
                Text(name).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.leading, 24)
        .help(L("Vertex reviews are billed to this project. By default it follows the project gcloud is switched to."))
    }

    /// What the provider gives this model (the engine's list for a model it did not report).
    private func efforts(_ engine: RevoEngine?) -> [String] {
        let known = engine?.efforts(for: block.model) ?? []
        return known.contains(block.effort) ? known : known + [block.effort]
    }
}

/// Popover lines: required reviewers on a limit recorded by revo and who reviews instead, apart from the live usage
/// of the service cards above.
struct ReviewLimitsRow: View {
    let chain: ReviewChain
    let now: Date

    var body: some View {
        let items = chain.limitedReviewers(now: now)
        let blocks: [RevoBlock] = chain.latest?.chain ?? []
        VStack(alignment: .leading, spacing: 2) {
            if !items.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            let reset: String = Format.resetIn(item.until, now: now)
                            let who: String = chain.name(item.required, among: blocks)
                            if let by = item.by {
                                Text(L("%@: limit, resets %@ → %@", who, reset, chain.name(by, among: blocks)))
                            } else {
                                Text(L("%@: limit, resets %@, no review", who, reset))
                            }
                        }
                    }
                } icon: { Image(systemName: "checklist") }
                .help(L("Recorded by revo: %@", items.map {
                    "\(chain.name($0.required, among: blocks)) \(Format.date($0.until))"
                }.joined(separator: ", ")))
            }
            if let failure = chain.limitsFailure {
                Text(L("Review chain: %@", failure.text))
                    .foregroundStyle(Color(nsColor: Theme.amber))
                    .lineLimit(2)
            }
        }
        .font(.system(size: 12))
    }
}
