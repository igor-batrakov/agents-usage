import AppKit
import UsageCore

@main @MainActor
enum UsageWidgetApp {
    static let delegate = AppDelegate()

    static func main() {
        // Writing to the pipe of an already exited subprocess must not kill the app with a signal:
        // let write return EPIPE, ProcessRunner handles it.
        signal(SIGPIPE, SIG_IGN)
        // With no visible windows AppKit marks the app as a candidate for automatic termination
        // (in the log: _kLSApplicationWouldBeTerminatedByTALKey=1), so the system could quietly close
        // the menu bar item. The NSSupports*Termination keys in Info.plist are about the same thing.
        ProcessInfo.processInfo.disableAutomaticTermination("menu bar app must keep running")
        Localization.shared.use(Settings.storedLanguage)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = editMenu()
        app.delegate = delegate
        app.run()
    }

    /// Main menu with a single Edit menu. An app without a Dock icon shows no menu, but without it
    /// ⌘C/⌘V/⌘X/⌘A/⌘Z do not work in settings fields: shortcuts are looked up in the main menu.
    static func editMenu() -> NSMenu {
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())  // the first item is the app menu, empty here
        main.addItem(item)
        return main
    }
}
