import AppKit
import Observation
import UsageCore
import UserNotifications

/// Доставка уведомлений о лимитах. Когда уведомлять — решает `Alerts`; его состояние
/// (о каких окнах уже предупредили) хранится между запусками, чтобы перезапуск не повторял их.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Уведомления запрещены в Системных настройках — для подсказки в окне настроек.
    private(set) var denied = false
    /// Клик по уведомлению.
    @ObservationIgnored var onOpen: (() -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var state: Alerts.State
    @ObservationIgnored private var authorized = false
    private static let stateKey = "alertState"

    override init() {
        state = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(Alerts.State.self, from: $0) } ?? [:]
        super.init()
        center.delegate = self
    }

    /// Разрешение выдано — проверить заново (то, что пришло до него, не показывалось).
    @ObservationIgnored var onAuthorized: (() -> Void)?

    /// Запрос разрешения — один раз за запуск; система спрашивает пользователя только впервые.
    func authorize() {
        guard !authorized else { return }
        authorized = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.denied = !granted
                if granted { self.onAuthorized?() }
            }
        }
    }

    /// Проверить данные после опроса или смены настроек.
    func check(_ store: UsageStore, _ settings: Settings) {
        // Выключенные уведомления не копят состояние: после включения сразу придёт
        // предупреждение об окнах, которые уже за порогом.
        guard settings.notify else {
            save([:])
            return
        }
        // Без разрешения система принимает уведомление, но не показывает его — а окно уже
        // считалось бы предупреждённым. Поэтому оцениваем только при выданном разрешении
        // (его могли и отозвать в Системных настройках — спрашиваем каждый раз).
        center.getNotificationSettings { current in
            let status = current.authorizationStatus
            Task { @MainActor in
                self.denied = status == .denied
                guard status == .authorized || status == .provisional else { return }
                self.evaluate(store, settings)
            }
        }
    }

    private func evaluate(_ store: UsageStore, _ settings: Settings) {
        guard settings.notify else { return }
        var next = state
        let events = Alerts.evaluate(accounts: store.accounts, snapshots: store.snapshots,
                                     threshold: settings.notifyThreshold, state: &next, now: Date())
        save(next)
        for event in events where event.kind == .threshold || settings.notifyReset { post(event) }
    }

    private func save(_ next: Alerts.State) {
        guard next != state else { return }
        state = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }

    private func post(_ event: Alerts.Event) {
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .threshold:
            content.title = "\(event.accountName): \(event.windowTitle) — \(Format.percent(event.used))"
            content.body = event.resetsAt.map { L("Resets %@", Format.resetIn($0, now: Date())) } ?? L("The limit is almost used up")
        case .reset:
            content.title = L("%@: %@ limit reset", event.accountName, event.windowTitle)
            content.body = L("You can keep going")
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Приложение из строки меню часто «активно» (открыт поповер) — без этого баннер не показался бы.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?() }
        completionHandler()
    }
}
