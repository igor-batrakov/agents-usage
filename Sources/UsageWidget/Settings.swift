import Foundation
import Observation
import ServiceManagement
import os

@MainActor @Observable
final class Settings {
    static let intervals: [TimeInterval] = [60, 300, 900, 1800]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var revertingLaunchAtLogin = false

    /// Раскрыта ли форма настроек в поповере. Не сохраняется. Живёт здесь, а не в @State:
    /// в SDK macOS 27 @State — макрос, а его плагина (SwiftUIMacros) нет в Command Line Tools.
    var formShown = false

    var interval: TimeInterval {
        didSet { defaults.set(interval, forKey: "interval"); onChange?() }
    }
    var panelEnabled: Bool {
        didSet { defaults.set(panelEnabled, forKey: "panelEnabled"); onChange?() }
    }
    /// true — панель на уровне рабочего стола (видна поверх обоев), false — поверх окон.
    var panelOnDesktop: Bool {
        didSet { defaults.set(panelOnDesktop, forKey: "panelOnDesktop"); onChange?() }
    }
    enum PanelMode: Hashable { case off, floating, desktop }

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
        let stored = defaults.double(forKey: "interval")
        interval = Self.intervals.contains(stored) ? stored : 300
        panelEnabled = defaults.bool(forKey: "panelEnabled")
        panelOnDesktop = defaults.bool(forKey: "panelOnDesktop")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
