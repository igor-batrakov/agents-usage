import Foundation
import Observation
import ServiceManagement
import SwiftUI  // Array.move(fromOffsets:toOffset:) is a SwiftUI extension
import UsageCore
import os

/// All app settings; every change is saved to UserDefaults and calls `onChange`.
@MainActor @Observable
final class Settings {
    static let intervals: [TimeInterval] = [60, 300, 900, 1800]
    static let thresholds: [Double] = [0.7, 0.8, 0.9, 0.95, 1]

    enum IconStyle: String, CaseIterable { case bars, percents, worst }
    enum PanelAnchor: String, CaseIterable { case free, topLeft, topRight, bottomLeft, bottomRight }
    enum PanelMode: Hashable { case off, floating, desktop }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var revertingLaunchAtLogin = false

    /// The account selected on the Services tab. Not saved. Lives here, not in @State:
    /// in the macOS 27 SDK @State is a macro, and its plugin (SwiftUIMacros) is missing from Command Line Tools.
    var selectedAccountID: UUID? {
        // The key draft belongs to the selected account: when the selection changes it must not carry over.
        didSet { if selectedAccountID != oldValue { keyDraft = ""; keyMessage = nil } }
    }
    /// The open settings tab (0 is General). Not saved, lives here for the same reason.
    var selectedTab = 0
    /// The API key being entered and the result of saving it. Not saved: the key itself lives only in the Keychain.
    var keyDraft = ""
    var keyMessage: String?

    var accounts: [Account] {
        didSet {
            if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "accounts") }
            onChange?()
        }
    }
    var autoRefresh: Bool { didSet { save(autoRefresh, "autoRefresh") } }
    var interval: TimeInterval { didSet { save(interval, "interval") } }
    var iconStyle: IconStyle { didSet { save(iconStyle.rawValue, "iconStyle") } }
    /// Low-power polling: no timer polls while the screen is locked or the display sleeps, less often on battery.
    var economy: Bool { didSet { save(economy, "economy") } }
    /// Pace marker on the bars.
    var showPace: Bool { didSet { save(showPace, "showPace") } }
    var hotKey: HotKeyChoice { didSet { save(hotKey.rawValue, "hotKey") } }
    /// UI language code; nil follows the system. Stored as an empty string.
    var language: String? { didSet { save(language ?? "", "language") } }
    /// Check GitHub for a new version once a day.
    var checkUpdates: Bool { didSet { save(checkUpdates, "checkUpdates") } }

    /// The language is needed before settings are created: the main menu is built earlier.
    static var storedLanguage: String? {
        UserDefaults.standard.string(forKey: "language").flatMap { $0.isEmpty ? nil : $0 }
    }

    var notify: Bool { didSet { save(notify, "notify") } }
    var notifyThreshold: Double { didSet { save(notifyThreshold, "notifyThreshold") } }
    /// Notify when a window that reached the threshold resets.
    var notifyReset: Bool { didSet { save(notifyReset, "notifyReset") } }

    var panelEnabled: Bool { didSet { save(panelEnabled, "panelEnabled") } }
    /// true: the panel sits at desktop level (visible over the wallpaper); false: above windows.
    var panelOnDesktop: Bool { didSet { save(panelOnDesktop, "panelOnDesktop") } }
    var panelAnchor: PanelAnchor { didSet { save(panelAnchor.rawValue, "panelAnchor") } }
    /// Margin from the screen edges when pinned to a corner, pt.
    var panelMargin: Double { didSet { save(panelMargin, "panelMargin") } }
    var panelOpacity: Double { didSet { save(panelOpacity, "panelOpacity") } }
    /// The panel ignores the mouse: clicks go to the windows and desktop below it.
    var panelClickThrough: Bool { didSet { save(panelClickThrough, "panelClickThrough") } }

    /// Both panel flags as one value, for the segmented control in settings.
    var panelMode: PanelMode {
        get { !panelEnabled ? .off : panelOnDesktop ? .desktop : .floating }
        set {
            if newValue != .off { panelOnDesktop = newValue == .desktop }
            panelEnabled = newValue != .off
        }
    }

    /// The system keeps the state itself (SMAppService); this is a mirror for the UI.
    var launchAtLogin: Bool {
        didSet {
            guard !revertingLaunchAtLogin else { return }
            // Turning off also removes a registration in the .requiresApproval state (disabled
            // in System Settings), not just an .enabled one.
            let status = SMAppService.mainApp.status
            do {
                if launchAtLogin, status != .enabled {
                    try SMAppService.mainApp.register()
                } else if !launchAtLogin, status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger(subsystem: "ru.batrakov.UsageWidget", category: "settings")
                    .error("launch at login: \(error.localizedDescription, privacy: .public)")
                // Roll the toggle back to the actual state without didSet side effects:
                // otherwise a failed enable (status .requiresApproval) would call unregister.
                revertingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                revertingLaunchAtLogin = false
            }
        }
    }

    /// `defaults`: demo mode (Demo) has its own domain, otherwise the standard one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        if let data = d.data(forKey: "accounts"), let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        } else {
            // First launch or migration from v1, which had no account list. Save right away:
            // account ids must stay the same (didSet does not fire in init).
            let defaults = Catalog.defaultAccounts()
            accounts = defaults
            if let data = try? JSONEncoder().encode(defaults) { d.set(data, forKey: "accounts") }
        }
        autoRefresh = d.object(forKey: "autoRefresh") as? Bool ?? true
        let stored = d.double(forKey: "interval")
        interval = Self.intervals.contains(stored) ? stored : 300
        iconStyle = d.string(forKey: "iconStyle").flatMap(IconStyle.init) ?? .bars
        economy = d.object(forKey: "economy") as? Bool ?? true
        showPace = d.object(forKey: "showPace") as? Bool ?? true
        hotKey = d.string(forKey: "hotKey").flatMap(HotKeyChoice.init) ?? .ctrlOptL
        language = Self.storedLanguage
        checkUpdates = d.object(forKey: "checkUpdates") as? Bool ?? true
        notify = d.object(forKey: "notify") as? Bool ?? true
        let threshold = d.double(forKey: "notifyThreshold")
        notifyThreshold = Self.thresholds.contains(threshold) ? threshold : 0.9
        notifyReset = d.object(forKey: "notifyReset") as? Bool ?? true
        panelEnabled = d.bool(forKey: "panelEnabled")
        panelOnDesktop = d.bool(forKey: "panelOnDesktop")
        // v1 remembered the free panel position: keep it; otherwise default to the top-right corner.
        panelAnchor = d.string(forKey: "panelAnchor").flatMap(PanelAnchor.init)
            ?? (d.string(forKey: "panelTopLeft") != nil ? .free : .topRight)
        panelMargin = d.object(forKey: "panelMargin") as? Double ?? 12
        panelOpacity = d.object(forKey: "panelOpacity") as? Double ?? 1
        panelClickThrough = d.bool(forKey: "panelClickThrough")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    // MARK: Accounts

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
    }

    func add(_ kind: Provider) {
        guard Catalog.canAdd(kind, to: accounts) else { return }
        // A second account of the same service gets a number in its name to tell them apart.
        let same = accounts.filter { $0.kind == kind }.count
        let account = Account(kind: kind, name: same == 0 ? kind.title : "\(kind.title) \(same + 1)")
        accounts.append(account)
        selectedAccountID = account.id
    }

    /// The latest key operation per account. Operations of one account run in order: removing
    /// an account cannot overtake a save in progress, otherwise the save would recreate a key that
    /// the app could no longer delete. The entry stays after completion; there are only a few.
    @ObservationIgnored private var keyTasks: [UUID: Task<Void, Never>] = [:]

    func withKey(_ id: UUID, _ operation: @escaping @MainActor () async -> Void) {
        let previous = keyTasks[id]
        keyTasks[id] = Task {
            await previous?.value
            await operation()
        }
    }

    func remove(_ id: UUID) {
        if account(id)?.kind.usesAPIKey == true { withKey(id) { try? await KeyStore.delete(id) } }
        accounts.removeAll { $0.id == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
    }
}
