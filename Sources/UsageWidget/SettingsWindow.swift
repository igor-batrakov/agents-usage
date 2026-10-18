import AppKit
import SwiftUI
import UsageCore

/// Окно детальных настроек. Создаётся при первом открытии и потом только прячется.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: Settings
    private let store: UsageStore
    private let notifier: Notifier

    init(settings: Settings, store: UsageStore, notifier: Notifier) {
        self.settings = settings
        self.store = store
        self.notifier = notifier
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(settings: settings, store: store,
                                                                                         notifier: notifier))
            w.center()
            window = w
        }
        relocalize()
        if settings.selectedAccountID == nil { settings.selectedAccountID = settings.accounts.first?.id }
        // Приложение без Dock-иконки: без активации окно откроется за другими.
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Заголовок окна — AppKit, сам при смене языка не обновится.
    func relocalize() {
        window?.title = L("Agents Usage Settings")
    }
}

struct SettingsView: View {
    @Bindable var settings: Settings
    let store: UsageStore
    let notifier: Notifier

    var body: some View {
        TabView {
            GeneralTab(settings: settings, notifier: notifier)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            ServicesTab(settings: settings, store: store)
                .tabItem { Label(L("Services"), systemImage: "square.stack.3d.up") }
            PanelTab(settings: settings)
                .tabItem { Label(L("Panel"), systemImage: "macwindow") }
        }
        .frame(width: 660, height: 480)
        // Новый язык — пересобрать дерево: строки L() вычисляются при построении вида.
        .id(settings.language ?? "")
    }
}

// MARK: Общие

private struct GeneralTab: View {
    @Bindable var settings: Settings
    let notifier: Notifier

    var body: some View {
        Form {
            Section(L("Data refresh")) {
                Toggle(L("Auto-refresh"), isOn: $settings.autoRefresh)
                Picker(L("Interval"), selection: $settings.interval) {
                    ForEach(Settings.intervals, id: \.self) { Text(L("%d min", Int($0 / 60))).tag($0) }
                }
                .disabled(!settings.autoRefresh)
                Text(L("With auto-refresh off, data updates only with ↻ in the popover (⌘R)."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Energy saver"), isOn: $settings.economy)
                    .disabled(!settings.autoRefresh)
                Text(L("Skip polling while the screen is locked or the display sleeps; poll 3× less often on battery."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Notifications")) {
                Toggle(L("Warn about limits"), isOn: $settings.notify)
                Picker(L("Threshold"), selection: $settings.notifyThreshold) {
                    ForEach(Settings.thresholds, id: \.self) { Text(Format.percent($0)).tag($0) }
                }
                .disabled(!settings.notify)
                Toggle(L("Notify when a limit resets"), isOn: $settings.notifyReset)
                    .disabled(!settings.notify)
                Text(notifier.denied
                     ? L("Notifications are turned off in System Settings → Notifications → Agents Usage.")
                     : L("At most once per window. Resets are reported only for windows that reached the threshold."))
                    .font(.caption)
                    .foregroundStyle(notifier.denied ? Color(nsColor: Theme.amber) : .secondary)
            }
            Section(L("Appearance")) {
                Picker(L("Menu bar"), selection: $settings.iconStyle) {
                    Text(L("Bars")).tag(Settings.IconStyle.bars)
                    Text(L("Percentages")).tag(Settings.IconStyle.percents)
                    Text(L("Worst only")).tag(Settings.IconStyle.worst)
                }
                .pickerStyle(.segmented)
                Toggle(L("Pace marker on bars"), isOn: $settings.showPace)
                // Ключ перевода — одним литералом: его находит проверка строк (LocalizationTests).
                Text(L("The tick shows how much of the window has passed. Fill past it means the limit is being used faster than it would last until the reset."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("System")) {
                // Названия языков — на них самих: найти свой язык должен тот, кто не читает текущий.
                Picker(L("Language"), selection: $settings.language) {
                    Text(L("System default")).tag(String?.none)
                    ForEach(Localization.shared.available(), id: \.self) { code in
                        Text(Localization.name(code)).tag(Optional(code))
                    }
                }
                Toggle(L("Launch at login"), isOn: $settings.launchAtLogin)
                Picker(L("Open popover"), selection: $settings.hotKey) {
                    ForEach(HotKeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Сервисы

private struct ServicesTab: View {
    @Bindable var settings: Settings
    let store: UsageStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $settings.selectedAccountID) {
                    ForEach(settings.accounts) { account in
                        AccountRow(account: account, settings: settings).tag(account.id)
                    }
                    .onMove { settings.move(from: $0, to: $1) }
                }
                Divider()
                HStack(spacing: 4) {
                    Menu {
                        ForEach(Provider.allCases, id: \.self) { kind in
                            Button(kind.title + (kind.usesAPIKey ? " — " + L("API key")
                                                 : Catalog.isInstalled(kind) ? "" : " — " + L("not found"))) { settings.add(kind) }
                                .disabled(!Catalog.canAdd(kind, to: settings.accounts))
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Add a service"))
                    Button {
                        if let id = settings.selectedAccountID { settings.remove(id) }
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(settings.selectedAccountID == nil)
                    .help(L("Remove the selected one"))
                    Spacer()
                    Text(L("drag to reorder")).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(6)
            }
            .frame(width: 220)
            Divider()
            if let id = settings.selectedAccountID, let account = settings.account(id) {
                AccountDetail(account: account, settings: settings, store: store)
            } else {
                Text(L("Select a service on the left")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let settings: Settings

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { account.enabled },
                                     set: { v in settings.update(account.id) { $0.enabled = v } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Circle().fill(Theme.accent(account.kind)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.name).lineLimit(1)
                if account.name != account.kind.title {
                    Text(account.kind.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(account.enabled ? 1 : 0.5)
        }
    }
}

private struct AccountDetail: View {
    let account: Account
    let settings: Settings
    let store: UsageStore

    /// Привязка к полю аккаунта в настройках (без @State — см. Settings.selectedAccountID).
    private func field<T>(_ keyPath: WritableKeyPath<Account, T>) -> Binding<T> {
        let id = account.id, fallback = account[keyPath: keyPath]
        return Binding(get: { settings.account(id)?[keyPath: keyPath] ?? fallback },
                       set: { v in settings.update(id) { $0[keyPath: keyPath] = v } })
    }

    private func optionalText(_ keyPath: WritableKeyPath<Account, String?>) -> Binding<String> {
        let b = field(keyPath)
        return Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        let snapshot = store.snapshot(account.id)
        Form {
            Section(account.kind.title) {
                TextField(L("Name"), text: field(\.name))
                Toggle(L("Show"), isOn: field(\.enabled))
                Toggle(L("On panel"), isOn: field(\.onPanel))
                if let variable = account.kind.configDirVariable {
                    TextField(variable, text: optionalText(\.configDir), prompt: Text(L("default")))
                    Text(L("Configuration directory of a second account, e.g. ~/.claude-work. Empty means the main one."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if account.kind.usesAPIKey { keySection }
            Section(L("Windows")) {
                if account.balanceOnly(snapshot) {
                    Text(L("No limit windows, only a balance.")).foregroundStyle(.secondary)
                } else if let windows = snapshot.report?.windows, !windows.isEmpty {
                    ForEach(windows) { w in
                        Toggle(w.group.map { "\($0) · \(w.title)" } ?? w.title, isOn: Binding(
                            get: { !(settings.account(account.id)?.hiddenWindows.contains(w.id) ?? false) },
                            set: { visible in settings.update(account.id) {
                                if visible { $0.hiddenWindows.remove(w.id) } else { $0.hiddenWindows.insert(w.id) }
                            } }))
                    }
                    Picker(L("In menu bar"), selection: field(\.barWindowID)) {
                        Text(L("Auto (short window)")).tag(String?.none)
                        ForEach(account.visibleWindows(snapshot)) { w in
                            Text(w.group.map { "\($0) · \(w.title)" } ?? w.title).tag(Optional(w.id))
                        }
                    }
                } else {
                    Text(account.enabled ? L("No data yet. Click Check.") : L("The service is off."))
                        .foregroundStyle(.secondary)
                }
            }
            Section(L("Usage page")) {
                HStack {
                    TextField(L("URL"), text: optionalText(\.usageURL),
                              prompt: Text(account.kind.defaultUsageURL?.absoluteString ?? L("this service has no web page")))
                    Button(L("Open")) { if let url = account.resolvedUsageURL { NSWorkspace.shared.open(url) } }
                        .disabled(account.resolvedUsageURL == nil)
                }
            }
            Section {
                HStack {
                    Button(L("Check")) { Task { await store.refresh(only: [account.id]) } }
                        .disabled(!account.enabled || (store.inFlight[account.id] != nil))
                    if (store.inFlight[account.id] != nil) {
                        ProgressView().controlSize(.small)
                    } else if let error = snapshot.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: Theme.amber)).lineLimit(2)
                    } else if let at = snapshot.fetchedAt, let n = snapshot.report?.windows.count {
                        Label(L("working: %d windows, %@", n, Format.date(at, date: .omitted)),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: Theme.nsAccent(.codex)))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Смена ключа в Связке ключей. Удалась — у аккаунта растёт `keyRevision`: стор отбросит опрос
    /// со старым ключом и его снимок и опросит заново (как при смене каталога). Делается для того
    /// аккаунта, чей ключ меняли, даже если за время записи выбрали другой; итог — только своему.
    /// Тот же ключ ещё раз (или удаление отсутствующего) ревизию не меняет: иначе стор и уведомления
    /// сочли бы аккаунт новым, и предупреждение о пороге пришло бы повторно.
    /// Черновик очищается, только если в поле всё ещё отправленный ключ: правку, сделанную во время
    /// записи, не стираем (`submitted` nil — удаление, черновик не трогаем).
    private func keyChange(_ id: UUID, submitted: String?, done: String, same: String,
                           _ change: @escaping () async throws -> Bool) {
        settings.withKey(id) {
            do {
                let changed = try await change()
                if changed { settings.update(id) { $0.keyRevision = ($0.keyRevision ?? 0) + 1 } }
                guard settings.selectedAccountID == id else { return }
                if let submitted, settings.keyDraft == submitted { settings.keyDraft = "" }
                settings.keyMessage = changed ? done : same
            } catch {
                if settings.selectedAccountID == id { settings.keyMessage = error.localizedDescription }
            }
        }
    }

    /// Ключ вводится и сразу уходит в Связку ключей; в поле его потом не видно — только итог.
    private var keySection: some View {
        let id = account.id
        return Section(L("API key")) {
            HStack {
                SecureField(L("Key"), text: Binding(get: { settings.keyDraft }, set: { settings.keyDraft = $0 }),
                            prompt: Text(L("Paste a key to replace the saved one")))
                Button(L("Save")) {
                    let draft = settings.keyDraft
                    keyChange(id, submitted: draft, done: L("key saved to Keychain"), same: L("this key is already saved")) {
                        try await KeyStore.save(draft, for: id)
                    }
                }
                .disabled(settings.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("Delete")) {
                    keyChange(id, submitted: nil, done: L("key deleted"), same: L("no key was saved")) { try await KeyStore.delete(id) }
                }
            }
            HStack(spacing: 4) {
                Text(settings.keyMessage ?? L("Stored in the macOS Keychain, never in settings or logs."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = account.kind.apiKeysURL {
                    Button(L("Get a key")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

// MARK: Панель

private struct PanelTab: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section(L("Desktop panel")) {
                Picker(L("Mode"), selection: $settings.panelMode) {
                    Text(L("Off")).tag(Settings.PanelMode.off)
                    Text(L("Above windows")).tag(Settings.PanelMode.floating)
                    Text(L("On desktop")).tag(Settings.PanelMode.desktop)
                }
                .pickerStyle(.segmented)
                Text(L("On desktop keeps the panel above the wallpaper, under your windows."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Position")) {
                Picker(L("Anchor"), selection: $settings.panelAnchor) {
                    Text(L("Free (drag to move)")).tag(Settings.PanelAnchor.free)
                    Text(L("Top left corner")).tag(Settings.PanelAnchor.topLeft)
                    Text(L("Top right corner")).tag(Settings.PanelAnchor.topRight)
                    Text(L("Bottom left corner")).tag(Settings.PanelAnchor.bottomLeft)
                    Text(L("Bottom right corner")).tag(Settings.PanelAnchor.bottomRight)
                }
                LabeledContent(L("Margin from edge")) {
                    HStack {
                        Slider(value: $settings.panelMargin, in: 0...60, step: 2)
                        Text(L("%d pt", Int(settings.panelMargin))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(settings.panelAnchor == .free)
                Text(L("Dragging the panel switches the anchor to Free."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Appearance")) {
                LabeledContent(L("Opacity")) {
                    HStack {
                        Slider(value: $settings.panelOpacity, in: 0.3...1)
                        Text(Format.percent(settings.panelOpacity)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(L("Click-through"), isOn: $settings.panelClickThrough)
                Text(L("The panel ignores the mouse, so clicks reach the windows and desktop below. You can't drag it, close it, or open its links then. Use these settings and the popover instead."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Services on panel")) {
                ForEach(settings.accounts) { account in
                    Toggle(account.name, isOn: Binding(
                        get: { account.onPanel }, set: { v in settings.update(account.id) { $0.onPanel = v } }))
                        .disabled(!account.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
