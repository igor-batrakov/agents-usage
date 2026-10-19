import AppKit
import Observation
import UsageCore
import UserNotifications

/// Delivers limit notifications. `Alerts` decides when to notify; its state
/// (which windows were already warned about) is kept across launches so a restart does not repeat them.
@MainActor @Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Notifications are denied in System Settings, for the hint in the settings window.
    private(set) var denied = false
    /// Click on a notification.
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

    /// Permission granted: check again (whatever came before it was not shown).
    @ObservationIgnored var onAuthorized: (() -> Void)?

    /// Permission is requested once per launch; the system asks the user only the first time.
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

    /// Check the data after a poll or a settings change.
    func check(_ store: UsageStore, _ settings: Settings) {
        // Demo data does not notify and does not touch the saved state of real accounts.
        guard !Demo.isOn else { return }
        // Disabled notifications do not accumulate state: once enabled, a warning arrives right away
        // for windows already over the threshold.
        guard settings.notify else {
            save([:])
            return
        }
        // Without permission the system accepts a notification but does not show it, while the window
        // would already count as warned. So evaluate only with permission granted
        // (it may be revoked in System Settings, so ask every time).
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

    // A menu bar app is often "active" (popover open); without this the banner would not show.
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
