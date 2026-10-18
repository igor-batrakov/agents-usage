import AppKit
import Observation
import SwiftUI
import UsageCore

/// Плавающая панель без рамки: не забирает фокус, видна на всех рабочих столах,
/// перетаскивается за фон.
///
/// Положение — привязка к углу экрана с отступом либо «свободно». Свободная позиция
/// хранится как верхний левый угол: высота меняется вместе с данными, и панель должна
/// расти вниз, а не уезжать вверх за край экрана (frame autosave хранит нижний левый
/// угол, поэтому он здесь не подходит). У привязанной панели при смене размера и экрана
/// держится её угол. Перетаскивание привязанной панели переводит её в «свободно».
final class FloatingPanel: NSPanel {
    struct Placement: Equatable {
        var anchor: Settings.PanelAnchor
        var margin: Double
    }

    private static let positionKey = "panelTopLeft"
    private var placement = Placement(anchor: .free, margin: 12)
    /// Свои перемещения не считаются перетаскиванием пользователя.
    private var positioning = false
    /// Явная перестановка в угол (смена привязки или экрана).
    private var snapping = false
    private var observers: [NSObjectProtocol] = []
    private let hover = PanelHover()
    /// Пользователь перетащил привязанную панель.
    var onUserMove: (() -> Void)?

    init(store: UsageStore, settings: Settings, onHide: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingController(rootView: PanelContent(store: store, settings: settings, hover: hover, onHide: onHide))
        host.sizingOptions = .preferredContentSize
        contentViewController = host

        place { setFrameTopLeftPoint(Self.savedTopLeft() ?? Self.defaultTopLeft()) }
        // queue: nil — синхронно, внутри setFrame: флаг positioning ещё стоит, и своё
        // перемещение не примется за перетаскивание пользователем.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didMove() }
        })
        // Монитор подключили, отключили или сменили разрешение — вернуть панель в её угол.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func apply(onDesktop: Bool, placement: Placement, opacity: Double, clickThrough: Bool) {
        level = onDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        alphaValue = opacity
        ignoresMouseEvents = clickThrough
        if placement != self.placement {
            self.placement = placement
            reposition()
        }
    }

    override var canBecomeKey: Bool { false }

    /// Смена размера — у привязанной панели держится угол, у свободной верхний край.
    /// Перемещение без смены размера — это перетаскивание пользователем: его не трогаем,
    /// а didMove переведёт привязанную панель в «свободно».
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        let resized = rect.size != frame.size
        guard resized || snapping else {
            super.setFrame(rect, display: flag)
            return
        }
        if placement.anchor != .free {
            rect.origin = origin(for: rect.size)
        } else {
            rect.origin.y = frame.maxY - rect.height
        }
        place { super.setFrame(rect, display: flag) }
    }

    private func place(_ body: () -> Void) {
        positioning = true
        body()
        positioning = false
    }

    private func reposition() {
        if placement.anchor != .free {
            snapping = true
            setFrame(frame, display: true)
            snapping = false
        } else if Self.savedTopLeft() == nil {
            // Свободная позиция осталась на отключённом мониторе.
            place { setFrameTopLeftPoint(Self.defaultTopLeft()) }
        }
    }

    private func didMove() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.positionKey)
        if !positioning, placement.anchor != .free { onUserMove?() }
    }

    private func origin(for size: NSSize) -> NSPoint {
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let m = placement.margin
        switch placement.anchor {
        case .topLeft: return NSPoint(x: vf.minX + m, y: vf.maxY - m - size.height)
        case .topRight, .free: return NSPoint(x: vf.maxX - m - size.width, y: vf.maxY - m - size.height)
        case .bottomLeft: return NSPoint(x: vf.minX + m, y: vf.minY + m)
        case .bottomRight: return NSPoint(x: vf.maxX - m - size.width, y: vf.minY + m)
        }
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
}

/// Наведён ли курсор на панель — для крестика. Отдельная модель вместо @State
/// (SwiftUI-макросов в Command Line Tools нет, см. Settings.selectedAccountID).
@MainActor @Observable
private final class PanelHover {
    var inside = false
}

private struct PanelContent: View {
    let store: UsageStore
    let settings: Settings
    let hover: PanelHover
    let onHide: () -> Void
    private let height = ContentHeight()

    var body: some View {
        UsageView(store: store, height: height, maxHeight: UsageView.screenLimit(reserve: 80),
                  compact: true, showPace: settings.showPace, include: \.onPanel)
            .padding(12)
            .frame(width: 250)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                if hover.inside {
                    Button(action: onHide) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Hide the panel"))
                    .padding(6)
                }
            }
            .onHover { hover.inside = $0 }
            // isMovableByWindowBackground не срабатывает: SwiftUI-контент забирает нажатие мыши.
            // Кнопки внутри (ссылка, крестик) получают клики раньше жеста.
            .gesture(WindowDragGesture())
            .contextMenu {
                Button(L("Refresh")) { Task { await store.refresh() } }
                Button(L("Hide the panel"), action: onHide)
            }
            .id(settings.language ?? "")  // новый язык — пересобрать: строки L() вычисляются при построении
    }
}
