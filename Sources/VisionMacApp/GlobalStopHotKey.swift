import AppKit
import Carbon.HIToolbox

// MARK: - ⌃⌥⌘. — stop all AI control, from any app
//
// ⌘. stops a chat, but only while Vision is the app in front — and when the
// AI is driving the Mac, Vision usually isn't. This shortcut is registered
// with the system (Carbon's hot keys need no Accessibility permission and see
// the keys whichever app is in front): pressing it stops every chat that is
// using or waiting for the machine, hands the mouse and keyboard back, and
// makes those chats ask again before they control anything.

@MainActor
final class GlobalStopHotKey {
    static let shared = GlobalStopHotKey()

    /// The shortcut, as menus and messages write it.
    static let display = "⌃⌥⌘."
    static let keyCode = UInt32(kVK_ANSI_Period)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    /// Whether the system took the shortcut (another app may own it).
    private(set) var registered = false

    /// Listen for the shortcut; `action` runs on the main thread.
    func register(_ action: @escaping () -> Void) {
        self.action = action
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            // Carbon delivers hot keys on the main thread's event loop.
            MainActor.assumeIsolated { GlobalStopHotKey.shared.fire() }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: OSType(0x5653_544F), id: 1)   // 'VSTO'
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        registered = status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        registered = false
    }

    private func fire() { action?() }
}
