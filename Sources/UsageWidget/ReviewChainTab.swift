import SwiftUI
import UsageCore

/// Settings tab for the Revolver review chain: order, on/off, model and effort of each block, plus the chain
/// settings. Adding and removing blocks stays in the terminal (`revo add`). Shown only when revo is found.
struct ReviewChainTab: View {
    let chain: ReviewChain
    @Bindable var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            if let draft = chain.draft {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    List {
                        ForEach(draft.blocks) { block in
                            BlockRow(block: block, chain: chain, now: context.date)
                        }
                        .onMove { chain.move(from: $0, to: $1) }
                    }
                }
                .disabled(chain.preview != nil)
            } else {
                Group {
                    if chain.busy { ProgressView() } else { Text(L("The review chain is not loaded.")).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(12)
        }
        .onAppear { Task { await chain.reload() } }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let chainSettings = chain.draft?.settings {
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
                .disabled(chain.preview != nil)
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
                HStack {
                    Text(loaded.configRev == "defaults" ? L("Built-in chain. Apply creates %@", file) : L("Edits %@", file))
                    Spacer()
                    Text(L("drag to reorder")).foregroundStyle(.tertiary)
                }
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

private struct BlockRow: View {
    let block: RevoBlock
    let chain: ReviewChain
    let now: Date

    var body: some View {
        let engine = chain.engines[block.engine]
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { block.on }, set: { v in chain.update(block.id) { $0.on = v } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(chain.blockName(block.id)).lineLimit(1)
                if let note = chain.note(block, now: now) {
                    Text(note.text)
                        .font(.caption2)
                        .foregroundStyle(note.warning ? Color(nsColor: Theme.amber) : .secondary)
                        .lineLimit(1)
                }
            }
            .opacity(block.on ? 1 : 0.5)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                TextField("", text: Binding(get: { block.model }, set: { v in chain.update(block.id) { $0.model = v } }))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(engine?.customModel == false)
                Menu {
                    ForEach(engine?.models ?? [], id: \.self) { model in
                        Button(model == "default" ? L("default") : model) { chain.update(block.id) { $0.model = model } }
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
        }
    }

    private func efforts(_ engine: RevoEngine?) -> [String] {
        let known = engine?.efforts ?? []
        return known.contains(block.effort) ? known : known + [block.effort]
    }
}

/// Popover line: review limits recorded by revo, apart from the live usage of the service cards above.
struct ReviewLimitsRow: View {
    let chain: ReviewChain
    let now: Date

    var body: some View {
        let limits = chain.activeLimits(now: now)
        VStack(alignment: .leading, spacing: 2) {
            if !limits.isEmpty {
                Label {
                    Text(L("Review chain: %@", limits.map {
                        L("%@ limit, resets %@", chain.engineName($0.engine), Format.resetIn($0.until, now: now))
                    }.joined(separator: ", ")))
                } icon: { Image(systemName: "checklist") }
                .help(L("Recorded by revo: %@", limits.map {
                    "\(chain.engineName($0.engine)) \(Format.date($0.until))"
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
