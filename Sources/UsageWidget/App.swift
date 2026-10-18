import AppKit

@main @MainActor
enum UsageWidgetApp {
    static let delegate = AppDelegate()

    static func main() {
        // Запись в pipe уже вышедшего подпроцесса не должна убивать приложение сигналом:
        // пусть write вернёт ошибку EPIPE, её обработает ProcessRunner.
        signal(SIGPIPE, SIG_IGN)
        // Без видимых окон AppKit помечает приложение как кандидата на автоматическое завершение
        // (в логе: _kLSApplicationWouldBeTerminatedByTALKey=1) — строку меню система могла бы
        // закрыть молча. Ключи NSSupports*Termination в Info.plist — о том же.
        ProcessInfo.processInfo.disableAutomaticTermination("строка меню должна работать постоянно")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        app.delegate = delegate
        app.run()
    }

    /// Главное меню с одним «Правка». У приложения без Dock меню не видно, но без него
    /// в полях окна настроек не работают ⌘C/⌘V/⌘X/⌘A/⌘Z — сочетания ищутся в главном меню.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())  // первый пункт — меню приложения, у нас пустое
        main.addItem(item)
        return main
    }
}
