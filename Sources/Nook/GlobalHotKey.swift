import AppKit
import Carbon.HIToolbox

// A shortcut that works from any app. Carbon's hot keys need no Accessibility permission and take the key for themselves, so the app in
// front never also sees it. The combination is one macOS and Microsoft Edge leave free: macOS's only Control-Option default is
// Control-Option-Space (the next input source), and Edge's shortcuts with N are Command-N and Command-Shift-N.

/// A key with its modifiers, as Carbon's hot keys take them, and as the menus show it.
struct HotKeyCombo: Equatable {
    let keyCode: UInt32
    /// Carbon's modifier flags (`controlKey`, `optionKey`, …), not AppKit's.
    let modifiers: UInt32
    /// The key in a menu item (`NSMenuItem.keyEquivalent`) with `menuModifiers`, so the menu shows the shortcut.
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags
    /// How the docs and the help write it.
    let label: String

    /// Opens the island, or puts it away when it is open (`NotchController.toggleFromShortcut`).
    static let toggleIsland = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey),
                                          menuKey: "n", menuModifiers: [.control, .option], label: "⌃⌥N")
}

/// One system-wide shortcut, registered for as long as the object lives. `registered` is false when macOS refused it (another app already
/// holds the same combination): the shortcut then does nothing, and nothing else changes.
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var registered = false

    /// `action` runs on the main thread, where Carbon delivers the application's events.
    init(_ combo: HotKeyCombo, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return }
        // "Nook" as the signature, so the key is Nook's in any list of hot keys.
        let id = EventHotKeyID(signature: OSType(0x4E6F_6F6B), id: 1)
        registered = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
