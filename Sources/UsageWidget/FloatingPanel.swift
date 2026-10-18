import AppKit
import SwiftUI
import UsageCore

/// Плавающая панель без рамки: не забирает фокус, видна на всех рабочих столах,
/// перетаскивается за фон. Запоминается верхний левый угол: высота меняется вместе
/// с данными, и панель должна расти вниз, а не уезжать вверх за край экрана
/// (frame autosave хранит нижний левый угол, поэтому он здесь не подходит).
final class FloatingPanel: NSPanel {
    private static let positionKey = "panelTopLeft"
    private var moveObserver: NSObjectProtocol?

    init(store: UsageStore, onHide: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingController(rootView: PanelContent(store: store, onHide: onHide))
        host.sizingOptions = .preferredContentSize
        contentViewController = host

        setFrameTopLeftPoint(Self.savedTopLeft() ?? Self.defaultTopLeft())
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.positionKey)
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Смена размера (контент вырос или сжался) — верхний край остаётся на месте.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if rect.size != frame.size { rect.origin.y = frame.maxY - rect.height }
        super.setFrame(rect, display: flag)
    }

    /// Сохранённая точка, если она всё ещё на одном из экранов (монитор могли отключить).
    private static func savedTopLeft() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let p = NSPointFromString(s)
        let probe = NSPoint(x: p.x + 20, y: p.y - 20)
        return NSScreen.screens.contains { $0.visibleFrame.contains(probe) } ? p : nil
    }

    /// Первый запуск — правый верхний угол основного экрана.
    private static func defaultTopLeft() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - 270, y: screen.maxY - 12)
    }

    func apply(onDesktop: Bool) {
        level = onDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    override var canBecomeKey: Bool { false }
}

private struct PanelContent: View {
    let store: UsageStore
    let onHide: () -> Void

    var body: some View {
        UsageView(store: store, compact: true)
            .padding(12)
            .frame(width: 250)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .contextMenu {
                Button("Обновить") { Task { await store.refresh() } }
                Button("Скрыть панель", action: onHide)
            }
    }
}
