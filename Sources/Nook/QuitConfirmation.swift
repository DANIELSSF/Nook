import AppKit

// Quitting Nook asks first: "¿Seguro que quieres salir?", with a sad cat, inside the island (`AppModel.quitPrompt`). Every way the
// user quits from Nook ends in `NSApp.terminate` (⌘Q and "Salir de Nook" in the main menu, the menu bar's menu, the cat's right-click
// menu, the "…" menu), so the question is asked in one place: `AppDelegate.applicationShouldTerminate` → `AppModel.shouldTerminate`.
//
// The island asks without a modal loop: AppKit's `.terminateLater` would park the run loop in its modal mode until the answer, and
// the timers and display links that animate the cat run in the default one. So the quit is cancelled, the question goes up in the
// island, and "Salir" quits again with a one-shot pass (`AppModel.answerQuit`).

/// Who asked Nook to quit, read from the Apple event being handled when AppKit asks (`NSAppleEventManager.currentAppleEvent`).
enum QuitRequest: Equatable {
    /// ⌘Q or "Salir de Nook" in one of Nook's menus: no Apple event, the user inside Nook. The island asks first.
    case user
    /// The Mac is logging out, restarting or shutting down (the quit event's `kAEQuitReason`): Nook goes at once and never holds
    /// that up.
    case system
    /// The quit event from another app or a script (`osascript -e 'quit app "Nook"'`, Activity Monitor's Quit): the island asks, as
    /// for the user's own quit (the user wants every quit confirmed). The sender sees a cancelled quit; Force Quit and SIGTERM still go at once.
    case external

    init(event: NSAppleEventDescriptor?) {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else {
            self = .user
            return
        }
        let keyword = AEKeyword(kAEQuitReason)
        let reason = event.attributeDescriptor(forKeyword: keyword)?.enumCodeValue ?? event.paramDescriptor(forKeyword: keyword)?.enumCodeValue
        self = reason.map(Self.systemReasons.contains) == true ? .system : .external
    }

    /// The reasons the system gives with a quit at logout, restart and shutdown, asked for or already confirmed.
    static let systemReasons: Set<OSType> = [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
                                             OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)]

    /// Whether Nook asks before quitting: always, except when the Mac logs out, restarts or shuts down.
    var asks: Bool { self != .system }
}

/// The island's question before Nook quits, while it is up. A new id each time it is asked, so a view can tell one from the next.
struct QuitPrompt: Equatable, Identifiable {
    let id: Int
}

/// What puts the question on screen: the island (`NotchController`). Tests put their own.
protocol QuitPromptHost: AnyObject {
    /// Whether it can ask now; when it can't, `AppModel.quitFallback` asks instead.
    var canShowQuitPrompt: Bool { get }
    /// The question just went up (`AppModel.quitPrompt`): show it, with the keyboard, and hold it until it is answered.
    func showQuitPrompt()
    /// The question was answered "stay".
    func quitPromptDismissed()
}

/// The question as a plain alert, for when there is no island to ask it in (`AppModel.quitFallback`). True: quit.
enum QuitAlert {
    static let question = "¿Seguro que quieres salir?"
    static let detail = "Nook se cerrará. Tus terminales, las sesiones de tmux y sus procesos siguen abiertos."

    /// The picture the plain alert wears: the sad cat of the island's question (`SadCatImage`), on the island's black.
    static func icon() -> NSImage {
        let image = SadCatImage.make(size: 128)
        image.accessibilityDescription = "Un gatito triste"
        return image
    }

    static func ask(capturePrivacy: CapturePrivacy) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.icon = icon()
        alert.addButton(withTitle: "Salir")
        // Esc stays, as it does on the island's question (AppKit gives Esc only to a button named «Cancel»).
        alert.addButton(withTitle: "Quedarme").keyEquivalent = "\u{1b}"
        capturePrivacy.prepare(alert.window)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
