import Carbon.HIToolbox
import UsageCore
import os

/// Popover shortcut: a choice from a few presets (recording an arbitrary shortcut is not needed).
enum HotKeyChoice: String, CaseIterable {
    case off, ctrlOptL, ctrlOptU

    var title: String {
        switch self {
        case .off: L("None")
        case .ctrlOptL: "⌃⌥L"
        case .ctrlOptU: "⌃⌥U"
        }
    }

    fileprivate var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .ctrlOptL: UInt32(kVK_ANSI_L)
        case .ctrlOptU: UInt32(kVK_ANSI_U)
        }
    }
}

/// Global shortcut through Carbon `RegisterEventHotKey`: unlike keyboard monitoring,
/// it does not need the Accessibility permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The Carbon handler is a C function without context, so the action is stored statically.
    fileprivate static var action: (() -> Void)?

    func set(_ choice: HotKeyChoice, action: @escaping () -> Void) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let keyCode = choice.keyCode else { return }
        Self.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                // Carbon calls the handler on the main thread.
                MainActor.assumeIsolated { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C_49_4D_54), id: 1)  // 'LIMT'
        let status = RegisterEventHotKey(keyCode, UInt32(controlKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Logger(subsystem: "ru.batrakov.UsageWidget", category: "hotkey")
                .error("register \(choice.rawValue, privacy: .public): \(status)")
        }
    }
}
