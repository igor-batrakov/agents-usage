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
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store, notifier: notifier)
    private let notifier = Notifier()
    private let hotKey = HotKey()
    private var appliedHotKey: HotKeyChoice?
    /// Применённый язык; внешний nil — ещё не применяли (первый вызов: язык уже выбран в main).
    private var appliedLanguage: String??

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

        // После сна сеть поднимается не сразу — даём ей несколько секунд.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp(after: .seconds(5), olderThan: 60) }
        }
        // Экран разблокировали или дисплей проснулся: пока он был тёмным, экономный режим
        // пропускал опросы — догоняем, если данные устарели.
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
        // Первый опрос — всегда, даже с выключенным автообновлением: иначе после запуска пусто.
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

        // Сменили язык: главное меню и заголовок окна — заново, SwiftUI-виды пересоберутся сами
        // (`.id(settings.language)`), а тексты из данных (заголовки окон, ошибки) придут с опросом.
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

    private var catchUpTask: Task<Void, Never>?

    /// Догоняющий опрос после сна и разблокировки: прошёл сброс окна — сразу (разовый опрос
    /// к нему при тёмном экране пропущен), иначе — если данные старше `age`. Пробуждение шлёт
    /// сразу несколько уведомлений — опрашиваем один раз, по последнему. Отменяется только
    /// ожидание: начатый опрос идёт отдельной задачей и не прерывается.
    private func catchUp(after delay: Duration, olderThan age: TimeInterval) {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Автообновление могли выключить, пока ждали. Дисплей просыпается и на экране блокировки,
            // а экран могли снова заблокировать — опрос догонит следующая разблокировка.
            // Аккаунты, опрос которых уже идёт, стор пропустит сам.
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

    /// Разовый опрос сразу после ближайшего сброса окна (+5 с — сервер успевает обнулить счётчик).
    /// Если плановый опрос наступит раньше, он сам переставит этот таймер через onChange.
    /// При выключенном автообновлении не планируется.
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard settings.autoRefresh, let reset = store.nextReset(after: Date()) else { return }
        let t = Timer(fire: reset.addingTimeInterval(5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Тёмный экран — опрос догонит разблокировка; батарея разовому опросу не помеха.
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
    }
}
