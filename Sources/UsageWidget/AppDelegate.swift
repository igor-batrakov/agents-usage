import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Demo.isOn ? UsageStore(makeSource: Demo.source) : UsageStore()
    private let settings = Demo.isOn ? Demo.settings() : Settings()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: FloatingPanel?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store, notifier: notifier,
                                                               updater: updater)
    private let notifier = Notifier()
    private let updater = Updater()
    private let hotKey = HotKey()
    private var appliedHotKey: HotKeyChoice?
    /// The applied language; outer nil means not applied yet (first call: the language is already set in main).
    private var appliedLanguage: String??

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: PopoverView(store: store, settings: settings, updater: updater) { [weak self] in
            self?.popover.performClose(nil)
            self?.settingsWindow.show()
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        store.onChange = { [weak self] in
            guard let self else { return }
            updateIcon()
            notifier.check(store, settings)
        }
        store.timerGate = { [weak self] in
            guard let self, settings.economy else { return true }
            return PollPolicy.timerShouldPoll(lastRefresh: store.lastRefresh, now: Date(), interval: settings.interval,
                                              screenIdle: SystemState.screenIdle, onBattery: SystemState.onBattery)
        }
        notifier.onOpen = { [weak self] in self?.showPopover() }
        notifier.onAuthorized = { [weak self] in
            guard let self else { return }
            notifier.check(store, settings)
        }
        settings.onChange = { [weak self] in self?.applySettings() }
        store.setAccounts(settings.accounts)
        applySettings()
        updateIcon()

        // After sleep the network does not come up right away, so give it a few seconds.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(after: .seconds(5), olderThan: 60) }
        }
        // The screen was unlocked or the display woke: while it was dark, low-power mode
        // skipped polls, so catch up if the data is stale.
        let screenBack: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.catchUp(after: .seconds(2), olderThan: self.settings.interval)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: screenBack)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: screenBack)
        // The first poll always runs, even with auto-refresh off: otherwise the app is empty after launch.
        Task { await store.refresh() }
        if Demo.opensSettings { settingsWindow.show() }
    }

    private var scheduledInterval: TimeInterval??
    private var pendingPoll: Set<UUID> = []
    private var pollTask: Task<Void, Never>?

    private func applySettings() {
        let toPoll = store.setAccounts(settings.accounts)
        if !toPoll.isEmpty { pollSoon(toPoll) }

        let interval: TimeInterval? = settings.autoRefresh ? settings.interval : nil
        if scheduledInterval != .some(interval) {
            scheduledInterval = .some(interval)
            store.schedule(every: interval)
        }

        if settings.panelEnabled {
            if panel == nil {
                let p = FloatingPanel(store: store, settings: settings) { [weak self] in self?.settings.panelEnabled = false }
                p.onUserMove = { [weak self] in self?.settings.panelAnchor = .free }
                panel = p
            }
            panel?.apply(onDesktop: settings.panelOnDesktop,
                         placement: .init(anchor: settings.panelAnchor, margin: settings.panelMargin),
                         opacity: settings.panelOpacity,
                         clickThrough: settings.panelClickThrough)
            panel?.orderFrontRegardless()
        } else if let panel {
            panel.close()
            self.panel = nil
        }

        // Language changed: rebuild the main menu and window title; SwiftUI views rebuild themselves
        // (`.id(settings.language)`), and texts from data (window titles, errors) arrive with the poll.
        if appliedLanguage != .some(settings.language) {
            let first = appliedLanguage == nil
            appliedLanguage = .some(settings.language)
            if !first {
                Localization.shared.use(settings.language)
                NSApp.mainMenu = UsageWidgetApp.editMenu()
                settingsWindow.relocalize()
                Task { await store.refresh() }
            }
        }

        if appliedHotKey != settings.hotKey {
            appliedHotKey = settings.hotKey
            hotKey.set(settings.hotKey) { [weak self] in self?.togglePopover() }
        }
        if settings.notify { notifier.authorize() }
        notifier.check(store, settings)
        updater.checkIfDue(enabled: settings.checkUpdates)
        updateIcon()
    }

    /// Polls new and just-enabled accounts after a one-second delay, so typing a config
    /// directory letter by letter does not start a poll on every keystroke.
    /// Only the wait is cancelled: a started poll runs as a separate task and is not interrupted.
    private func pollSoon(_ ids: Set<UUID>) {
        pendingPoll.formUnion(ids)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let ids = pendingPoll
            pendingPoll = []
            Task { await self.store.refresh(only: ids) }
        }
    }

    private var catchUpTask: Task<Void, Never>?

    /// Catch-up poll after sleep and unlock: right away if a window reset has passed (the one-off
    /// poll for it was skipped while the screen was dark), else if the data is older than `age`. Waking
    /// sends several notifications at once, so we poll once, on the last one. Only the wait
    /// is cancelled: a started poll runs as a separate task and is not interrupted.
    private func catchUp(after delay: Duration, olderThan age: TimeInterval) {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Auto-refresh may have been turned off while waiting. The display also wakes on the lock screen,
            // and the screen may have been locked again: the next unlock will catch up.
            // The store skips accounts that are already being polled.
            guard !Task.isCancelled, let self, settings.autoRefresh,
                  !(settings.economy && SystemState.screenIdle) else { return }
            Task {
                if self.store.hasPassedReset(at: Date()) {
                    await self.store.refresh()
                } else {
                    await self.store.refreshIfStale(olderThan: age)
                }
            }
        }
    }

    private var resetTimer: Timer?

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        StatusIcon.apply(settings.iconStyle, bars: StatusIcon.bars(store), to: button)
        button.toolTip = StatusIcon.tooltip(store)
        scheduleResetRefresh()
    }

    /// One-off poll right after the nearest window reset (+5 s, so the server has time to zero the counter).
    /// If a scheduled poll comes first, it reschedules this timer itself through onChange.
    /// Not scheduled when auto-refresh is off.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard settings.autoRefresh, let reset = store.nextReset(after: Date()) else { return }
        let t = Timer(fire: reset.addingTimeInterval(5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Dark screen: the unlock will catch up; battery does not stop a one-off poll.
                guard let self, !(self.settings.economy && SystemState.screenIdle) else { return }
                await self.store.refresh()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        resetTimer = t
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if settings.autoRefresh { Task { await store.refreshIfStale(olderThan: 60) } }
        updater.checkIfDue(enabled: settings.checkUpdates)
    }
}
