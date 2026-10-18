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
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let host = NSHostingController(rootView: PopoverView(store: store, settings: settings) { [weak self] in
            self?.popover.performClose(nil)
            self?.settingsWindow.show()
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        store.onChange = { [weak self] in self?.updateIcon() }
        settings.onChange = { [weak self] in self?.applySettings() }
        store.setAccounts(settings.accounts)
        applySettings()
        updateIcon()

        // После сна сеть поднимается не сразу — даём ей несколько секунд.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                // Проверка после паузы: автообновление могли выключить, пока ждали сеть.
                guard self?.settings.autoRefresh == true else { return }
                await self?.store.refresh()
            }
        }
        // Первый опрос — всегда, даже с выключенным автообновлением: иначе после запуска пусто.
        Task { await store.refresh() }
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
                let p = FloatingPanel(store: store) { [weak self] in self?.settings.panelEnabled = false }
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
        updateIcon()
    }

    /// Опрос новых и только что включённых аккаунтов — с задержкой в секунду, чтобы ввод
    /// каталога конфигурации по буквам не запускал опрос на каждое нажатие.
    /// Отменяется только ожидание: начатый опрос идёт отдельной задачей и не прерывается.
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

    private var resetTimer: Timer?

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        StatusIcon.apply(settings.iconStyle, bars: StatusIcon.bars(store), to: button)
        button.toolTip = StatusIcon.tooltip(store)
        scheduleResetRefresh()
    }

    /// Разовый опрос сразу после ближайшего сброса окна (+5 с — сервер успевает обнулить счётчик).
    /// Если плановый опрос наступит раньше, он сам переставит этот таймер через onChange.
    /// При выключенном автообновлении не планируется.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard settings.autoRefresh, let reset = store.nextReset(after: Date()) else { return }
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
        if settings.autoRefresh { Task { await store.refreshIfStale(olderThan: 60) } }
    }
}
