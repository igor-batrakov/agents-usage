import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let settings = Settings()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: PopoverView(store: store, settings: settings))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        store.onChange = { [weak self] in self?.updateIcon() }
        settings.onChange = { [weak self] in self?.applySettings() }
        applySettings()
        updateIcon()

        // После сна сеть поднимается не сразу — даём ей несколько секунд.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await self?.store.refresh()
            }
        }
        Task { await store.refresh() }
    }

    private var scheduledInterval: TimeInterval?

    private func applySettings() {
        if scheduledInterval != settings.interval {
            scheduledInterval = settings.interval
            store.schedule(every: settings.interval)
        }
        if settings.panelEnabled {
            if panel == nil {
                panel = FloatingPanel(store: store) { [weak self] in self?.settings.panelEnabled = false }
            }
            panel?.apply(onDesktop: settings.panelOnDesktop)
            panel?.orderFrontRegardless()
        } else if let panel {
            panel.close()
            self.panel = nil
        }
    }

    private var resetTimer: Timer?

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(StatusIcon.bars(store))
        statusItem.button?.toolTip = StatusIcon.tooltip(store)
        scheduleResetRefresh()
    }

    /// Разовый опрос сразу после ближайшего сброса окна (+5 с — сервер успевает обнулить счётчик).
    /// Если плановый опрос наступит раньше, он сам переставит этот таймер через onChange.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let reset = store.nextReset(after: Date()) else { return }
        let t = Timer(fire: reset.addingTimeInterval(5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        resetTimer = t
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { await store.refreshIfStale(olderThan: 60) }
    }
}
