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
            w.title = "Настройки — Agents Usage"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(settings: settings, store: store,
                                                                                         notifier: notifier))
            w.center()
            window = w
        }
        if settings.selectedAccountID == nil { settings.selectedAccountID = settings.accounts.first?.id }
        // Приложение без Dock-иконки: без активации окно откроется за другими.
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @Bindable var settings: Settings
    let store: UsageStore
    let notifier: Notifier

    var body: some View {
        TabView {
            GeneralTab(settings: settings, notifier: notifier)
                .tabItem { Label("Общие", systemImage: "gearshape") }
            ServicesTab(settings: settings, store: store)
                .tabItem { Label("Сервисы", systemImage: "square.stack.3d.up") }
            PanelTab(settings: settings)
                .tabItem { Label("Панель", systemImage: "macwindow") }
        }
        .frame(width: 660, height: 480)
    }
}

// MARK: Общие

private struct GeneralTab: View {
    @Bindable var settings: Settings
    let notifier: Notifier

    var body: some View {
        Form {
            Section("Обновление") {
                Toggle("Автообновление", isOn: $settings.autoRefresh)
                Picker("Интервал", selection: $settings.interval) {
                    ForEach(Settings.intervals, id: \.self) { Text("\(Int($0 / 60)) мин").tag($0) }
                }
                .disabled(!settings.autoRefresh)
                Text("Выключенное автообновление — только кнопка ↻ в поповере (⌘R).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Экономный опрос", isOn: $settings.economy)
                    .disabled(!settings.autoRefresh)
                Text("Не опрашивать, пока экран заблокирован или дисплей спит; от батареи — в 3 раза реже.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Уведомления") {
                Toggle("Предупреждать о лимите", isOn: $settings.notify)
                Picker("Порог", selection: $settings.notifyThreshold) {
                    ForEach(Settings.thresholds, id: \.self) { Text(Format.percent($0)).tag($0) }
                }
                .disabled(!settings.notify)
                Toggle("Сообщать, когда лимит сбросился", isOn: $settings.notifyReset)
                    .disabled(!settings.notify)
                Text(notifier.denied
                     ? "Уведомления запрещены в Системных настройках → Уведомления → Agents Usage."
                     : "Не чаще раза за окно. О сбросе — только по окнам, дошедшим до порога.")
                    .font(.caption)
                    .foregroundStyle(notifier.denied ? Color(nsColor: Theme.amber) : .secondary)
            }
            Section("Вид") {
                Picker("Строка меню", selection: $settings.iconStyle) {
                    Text("Полоски").tag(Settings.IconStyle.bars)
                    Text("Проценты").tag(Settings.IconStyle.percents)
                    Text("Только худший").tag(Settings.IconStyle.worst)
                }
                .pickerStyle(.segmented)
                Toggle("Метка темпа на полосках", isOn: $settings.showPace)
                Text("Чёрточка — сколько времени окна уже прошло. Заливка правее неё — расход быстрее, "
                     + "чем нужно, чтобы лимита хватило до сброса.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Система") {
                Toggle("Запускать при входе", isOn: $settings.launchAtLogin)
                Picker("Открыть поповер", selection: $settings.hotKey) {
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
                            Button(kind.title + (kind.usesAPIKey ? " — по API-ключу"
                                                 : Catalog.isInstalled(kind) ? "" : " — не найден")) { settings.add(kind) }
                                .disabled(!Catalog.canAdd(kind, to: settings.accounts))
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Добавить сервис")
                    Button {
                        if let id = settings.selectedAccountID { settings.remove(id) }
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(settings.selectedAccountID == nil)
                    .help("Удалить выбранный")
                    Spacer()
                    Text("порядок — перетаскиванием").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(6)
            }
            .frame(width: 220)
            Divider()
            if let id = settings.selectedAccountID, let account = settings.account(id) {
                AccountDetail(account: account, settings: settings, store: store)
            } else {
                Text("Выберите сервис слева").foregroundStyle(.secondary)
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
                TextField("Имя", text: field(\.name))
                Toggle("Показывать", isOn: field(\.enabled))
                Toggle("На панели", isOn: field(\.onPanel))
                if let variable = account.kind.configDirVariable {
                    TextField(variable, text: optionalText(\.configDir), prompt: Text("по умолчанию"))
                    Text("Каталог конфигурации второго аккаунта, например ~/.claude-work. Пусто — основной.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if account.kind.usesAPIKey { keySection }
            Section("Окна") {
                if account.balanceOnly(snapshot) {
                    Text("Окон лимита нет — только баланс.").foregroundStyle(.secondary)
                } else if let windows = snapshot.report?.windows, !windows.isEmpty {
                    ForEach(windows) { w in
                        Toggle(w.group.map { "\($0) · \(w.title)" } ?? w.title, isOn: Binding(
                            get: { !(settings.account(account.id)?.hiddenWindows.contains(w.id) ?? false) },
                            set: { visible in settings.update(account.id) {
                                if visible { $0.hiddenWindows.remove(w.id) } else { $0.hiddenWindows.insert(w.id) }
                            } }))
                    }
                    Picker("В строке меню", selection: field(\.barWindowID)) {
                        Text("Авто — короткое окно").tag(String?.none)
                        ForEach(account.visibleWindows(snapshot)) { w in
                            Text(w.group.map { "\($0) · \(w.title)" } ?? w.title).tag(Optional(w.id))
                        }
                    }
                } else {
                    Text(account.enabled ? "Данных пока нет — нажмите «Проверить»." : "Сервис выключен.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Страница лимитов") {
                HStack {
                    TextField("Адрес", text: optionalText(\.usageURL),
                              prompt: Text(account.kind.defaultUsageURL?.absoluteString ?? "у сервиса нет веб-страницы"))
                    Button("Открыть") { if let url = account.resolvedUsageURL { NSWorkspace.shared.open(url) } }
                        .disabled(account.resolvedUsageURL == nil)
                }
            }
            Section {
                HStack {
                    Button("Проверить") { Task { await store.refresh(only: [account.id]) } }
                        .disabled(!account.enabled || (store.inFlight[account.id] != nil))
                    if (store.inFlight[account.id] != nil) {
                        ProgressView().controlSize(.small)
                    } else if let error = snapshot.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: Theme.amber)).lineLimit(2)
                    } else if let at = snapshot.fetchedAt, let n = snapshot.report?.windows.count {
                        Label("работает: окон \(n), \(at.formatted(date: .omitted, time: .shortened))",
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
        return Section("API-ключ") {
            HStack {
                SecureField("Ключ", text: Binding(get: { settings.keyDraft }, set: { settings.keyDraft = $0 }),
                            prompt: Text("вставь ключ — заменит сохранённый"))
                Button("Сохранить") {
                    let draft = settings.keyDraft
                    keyChange(id, submitted: draft, done: "ключ сохранён в Связке ключей", same: "этот ключ уже сохранён") {
                        try await KeyStore.save(draft, for: id)
                    }
                }
                .disabled(settings.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Удалить") {
                    keyChange(id, submitted: nil, done: "ключ удалён", same: "ключа нет") { try await KeyStore.delete(id) }
                }
            }
            HStack(spacing: 4) {
                Text(settings.keyMessage ?? "Хранится в Связке ключей macOS — не в настройках и не в логах.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = account.kind.apiKeysURL {
                    Button("Где взять ключ") { NSWorkspace.shared.open(url) }
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
            Section("Панель на рабочем столе") {
                Picker("Режим", selection: $settings.panelMode) {
                    Text("Выключена").tag(Settings.PanelMode.off)
                    Text("Поверх окон").tag(Settings.PanelMode.floating)
                    Text("На столе").tag(Settings.PanelMode.desktop)
                }
                .pickerStyle(.segmented)
                Text("«На столе» — панель видна поверх обоев, окна её закрывают.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Положение") {
                Picker("Привязка", selection: $settings.panelAnchor) {
                    Text("Свободно (перетаскиванием)").tag(Settings.PanelAnchor.free)
                    Text("Левый верхний угол").tag(Settings.PanelAnchor.topLeft)
                    Text("Правый верхний угол").tag(Settings.PanelAnchor.topRight)
                    Text("Левый нижний угол").tag(Settings.PanelAnchor.bottomLeft)
                    Text("Правый нижний угол").tag(Settings.PanelAnchor.bottomRight)
                }
                LabeledContent("Отступ от края") {
                    HStack {
                        Slider(value: $settings.panelMargin, in: 0...60, step: 2)
                        Text("\(Int(settings.panelMargin)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(settings.panelAnchor == .free)
                Text("Перетаскивание панели переключает привязку на «Свободно».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Вид") {
                LabeledContent("Непрозрачность") {
                    HStack {
                        Slider(value: $settings.panelOpacity, in: 0.3...1)
                        Text(Format.percent(settings.panelOpacity)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Сквозь клики", isOn: $settings.panelClickThrough)
                Text("Панель не перехватывает мышь: клики уходят окнам и столу под ней. Перетащить, закрыть "
                     + "крестиком и открыть ссылку на панели тогда нельзя — управление отсюда и из поповера.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Сервисы на панели") {
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
