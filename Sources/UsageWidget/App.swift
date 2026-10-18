import AppKit

@main @MainActor
enum UsageWidgetApp {
    static let delegate = AppDelegate()

    static func main() {
        // Запись в pipe уже вышедшего подпроцесса не должна убивать приложение сигналом:
        // пусть write вернёт ошибку EPIPE, её обработает ProcessRunner.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
