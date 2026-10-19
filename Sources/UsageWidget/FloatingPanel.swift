import AppKit
import Observation
import SwiftUI
import UsageCore

/// Borderless floating panel: does not take focus, shows on all desktops,
/// is dragged by its background.
///
/// Position is either pinned to a screen corner with a margin or "free". The free position
/// is stored as the top-left corner: the height changes with the data, and the panel should
/// grow downward instead of sliding up past the screen edge (frame autosave stores the bottom-left
/// corner, so it does not fit here). A pinned panel keeps its corner when its size or the screen
/// changes. Dragging a pinned panel switches it to "free".
final class FloatingPanel: NSPanel {
    struct Placement: Equatable {
        var anchor: Settings.PanelAnchor
        var margin: Double
    }

    private static let positionKey = "panelTopLeft"
    private var placement = Placement(anchor: .free, margin: 12)
    /// Our own moves do not count as user drags.
    private var positioning = false
    /// Explicit move to the corner (pin or screen change).
    private var snapping = false
    private var observers: [NSObjectProtocol] = []
    private let hover = PanelHover()
    /// The user dragged a pinned panel.
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
        // queue: nil means synchronous, inside setFrame: the positioning flag is still set, and our own
        // move is not mistaken for a user drag.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didMove() }
        })
        // A monitor was connected, disconnected or changed resolution: put the panel back in its corner.
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

    /// On resize a pinned panel keeps its corner, a free one keeps its top edge.
    /// A move without resize is a user drag: leave it alone,
    /// and didMove switches a pinned panel to "free".
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
            // The free position was left on a disconnected monitor.
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

    /// The saved point, if it is still on one of the screens (a monitor may have been disconnected).
    private static func savedTopLeft() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let p = NSPointFromString(s)
        let probe = NSPoint(x: p.x + 20, y: p.y - 20)
        return NSScreen.screens.contains { $0.visibleFrame.contains(probe) } ? p : nil
    }

    /// First launch: top-right corner of the main screen.
    private static func defaultTopLeft() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - 270, y: screen.maxY - 12)
    }
}

/// Whether the pointer is over the panel, for the close button. A separate model instead of @State
/// (Command Line Tools have no SwiftUI macros, see Settings.selectedAccountID).
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
            // isMovableByWindowBackground does not work: the SwiftUI content takes the mouse down.
            // Buttons inside (the link, the close button) get clicks before the gesture.
            .gesture(WindowDragGesture())
            .contextMenu {
                Button(L("Refresh")) { Task { await store.refresh() } }
                Button(L("Hide the panel"), action: onHide)
            }
            .id(settings.language ?? "")  // new language: rebuild, L() strings are evaluated at build time
    }
}
