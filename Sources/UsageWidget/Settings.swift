import Foundation
import Observation
import ServiceManagement
import SwiftUI  // Array.move(fromOffsets:toOffset:) — расширение из SwiftUI
import UsageCore
import os

/// Все настройки приложения; каждое изменение сохраняется в UserDefaults и вызывает `onChange`.
@MainActor @Observable
final class Settings {
    static let intervals: [TimeInterval] = [60, 300, 900, 1800]

    enum IconStyle: String, CaseIterable { case bars, percents, worst }
    enum PanelAnchor: String, CaseIterable { case free, topLeft, topRight, bottomLeft, bottomRight }
    enum PanelMode: Hashable { case off, floating, desktop }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var revertingLaunchAtLogin = false

    /// Выбранный аккаунт во вкладке «Сервисы». Не сохраняется. Живёт здесь, а не в @State:
    /// в SDK macOS 27 @State — макрос, а его плагина (SwiftUIMacros) нет в Command Line Tools.
    var selectedAccountID: UUID?

    var accounts: [Account] {
        didSet {
            if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "accounts") }
            onChange?()
        }
    }
    var autoRefresh: Bool { didSet { save(autoRefresh, "autoRefresh") } }
    var interval: TimeInterval { didSet { save(interval, "interval") } }
    var iconStyle: IconStyle { didSet { save(iconStyle.rawValue, "iconStyle") } }

    var panelEnabled: Bool { didSet { save(panelEnabled, "panelEnabled") } }
    /// true — панель на уровне рабочего стола (видна поверх обоев), false — поверх окон.
    var panelOnDesktop: Bool { didSet { save(panelOnDesktop, "panelOnDesktop") } }
    var panelAnchor: PanelAnchor { didSet { save(panelAnchor.rawValue, "panelAnchor") } }
    /// Отступ от краёв экрана при привязке к углу, pt.
    var panelMargin: Double { didSet { save(panelMargin, "panelMargin") } }
    var panelOpacity: Double { didSet { save(panelOpacity, "panelOpacity") } }
    /// Панель не перехватывает мышь: клики уходят окнам и столу под ней.
    var panelClickThrough: Bool { didSet { save(panelClickThrough, "panelClickThrough") } }

    /// Оба флага панели одним значением — для сегмента в настройках.
    var panelMode: PanelMode {
        get { !panelEnabled ? .off : panelOnDesktop ? .desktop : .floating }
        set {
            if newValue != .off { panelOnDesktop = newValue == .desktop }
            panelEnabled = newValue != .off
        }
    }

    /// Состояние хранит сама система (SMAppService); здесь — зеркало для UI.
    var launchAtLogin: Bool {
        didSet {
            guard !revertingLaunchAtLogin else { return }
            // Выключение снимает и регистрацию в статусе .requiresApproval (её отключили
            // в Системных настройках), а не только .enabled.
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
                // Откат тумблера к фактическому состоянию — без побочных эффектов didSet:
                // иначе неудачное включение (статус .requiresApproval) вызвало бы unregister.
                revertingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                revertingLaunchAtLogin = false
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "accounts"), let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        } else {
            // Первый запуск или переход с v1, где списка аккаунтов не было. Сохраняем сразу:
            // id аккаунтов должны быть постоянными (didSet в init не срабатывает).
            let defaults = Catalog.defaultAccounts()
            accounts = defaults
            if let data = try? JSONEncoder().encode(defaults) { d.set(data, forKey: "accounts") }
        }
        autoRefresh = d.object(forKey: "autoRefresh") as? Bool ?? true
        let stored = d.double(forKey: "interval")
        interval = Self.intervals.contains(stored) ? stored : 300
        iconStyle = d.string(forKey: "iconStyle").flatMap(IconStyle.init) ?? .bars
        panelEnabled = d.bool(forKey: "panelEnabled")
        panelOnDesktop = d.bool(forKey: "panelOnDesktop")
        // v1 запоминал свободную позицию панели — сохраняем её; иначе по умолчанию правый верхний угол.
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

    // MARK: Аккаунты

    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
    }

    func add(_ kind: Provider) {
        guard Catalog.canAdd(kind, to: accounts) else { return }
        // Второй аккаунт того же сервиса получает номер в имени, чтобы их различать.
        let same = accounts.filter { $0.kind == kind }.count
        let account = Account(kind: kind, name: same == 0 ? kind.title : "\(kind.title) \(same + 1)")
        accounts.append(account)
        selectedAccountID = account.id
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
    }

    func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
    }
}
