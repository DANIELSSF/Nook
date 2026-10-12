import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Claude's panel in the island, driven through a real window and AppKit key and mouse events: the card takes the keyboard when
/// the panel opens, the arrows, Tab, Enter and Esc travel to Claude, and everything else (the draft, sending, the agent's view,
/// a question's card) is where it was when the panel goes. Nothing here starts the app or touches Terminal: the keys are caught
/// by `AppModel.keySender`, and the session has no bridge, so a message could only reach its own idle terminal view.
@MainActor
final class ClaudePanelKeyTests: XCTestCase {
    private final class Escapes: ObservableObject { var count = 0 }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var escapes: Escapes
        var body: some View {
            SessionPane(model: model, session: session)
                .frame(width: 572, height: 204).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                .onExitCommand { escapes.count += 1 }
        }
    }

    private var holdBefore = 0.0
    override func setUp() { holdBefore = ClaudePanelHold.delay }
    override func tearDown() { ClaudePanelHold.delay = holdBefore }

    @MainActor private final class Rig {
        let model: AppModel
        let session: TerminalSession
        let escapes = Escapes()
        let window: NSWindow
        let host: NSHostingView<Island>
        var sent: [TerminalKey] = []

        /// `screen` is what the tab shows when the island opens; `hold` how long the island keeps a panel the screen stopped showing.
        init(screen: String = ClaudePanelFixtures.closed, draft: String = "", hold: Double = 0.05) {
            ClaudePanelHold.delay = hold
            model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-panelkeys-" + UUID().uuidString)!)
            session = TerminalSession(tab: Self.tab(screen), backend: .bundled, bridge: model.terminalBridge)
            // Without a bridge nothing can reach Terminal: a message goes to the session's own (idle) terminal view.
            session.terminalBridge = nil
            session.transcriptLocated = Date()
            session.draft = draft
            model.sessions = [session]; model.selectedID = session.id
            host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes))
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 204), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            model.keySender = { [weak self] key, _ in self?.sent.append(key) }
            window.makeKeyAndOrderFront(nil)
            Self.settle(0.5)
        }

        static func tab(_ screen: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: screen)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        static func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        /// Runs the island until `done` holds (or `timeout` passes). A panel leaves after its hold, a task's sleep and an animation:
        /// how long that takes in wall-clock time depends on the machine's load (the full suite, other builds), so a test that
        /// expects it gone waits for it instead of guessing a time.
        static func settle(until done: () -> Bool, timeout: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        var catcher: PanelKeyView? { Self.find(PanelKeyView.self, in: host) }
        var field: ComposerTextView? { Self.find(ComposerFieldView.self, in: host)?.textView }

        /// The screen as Claude draws it next (a reading of the tab).
        func show(_ screen: String, wait: TimeInterval = 0.3) {
            session.update(Self.tab(screen))
            Self.settle(wait)
        }
        /// Claude closed its panel: the next reading, then the panel leaving the island, then the keyboard going back.
        func showClosedAndWaitForThePanelToLeave() {
            show(ClaudePanelFixtures.closed, wait: 0.05)
            Self.settle(until: { self.catcher == nil })
            Self.settle(0.15)
        }

        enum Key {
            case left, right, up, down, tab, escape, enter, letter(String)
            var code: UInt16 {
                switch self { case .left: 123; case .right: 124; case .up: 126; case .down: 125; case .tab: 48; case .escape: 53; case .enter: 36; case .letter: 0 }
            }
            var characters: String {
                switch self {
                case .left: "\u{F702}"; case .right: "\u{F703}"; case .up: "\u{F700}"; case .down: "\u{F701}"; case .tab: "\t"; case .escape: "\u{1b}"; case .enter: "\r"
                case .letter(let text): text
                }
            }
            var isArrow: Bool { switch self { case .left, .right, .up, .down: true; default: false } }
        }

        func press(_ key: Key, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) {
            var flags = flags
            if key.isArrow { flags.formUnion([.function, .numericPad]) }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: repeating, keyCode: key.code)!
                window.sendEvent(event)
            }
            Self.settle(0.1)
        }

        /// A click at a point of the window, given from its top left.
        func click(x: CGFloat, fromTop y: CGFloat) {
            let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            Self.settle(0.15)
        }

        func snapshot(to path: String) throws {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    private var usageScreen: String { ClaudePanelFixtures.screen(ClaudePanelFixtures.usage) }

    // MARK: The keys

    func testTheCardTakesTheKeyboardAndTheKeysTravelToClaude() throws {
        let rig = Rig(screen: usageScreen)
        let catcher = try XCTUnwrap(rig.catcher, "The panel is on screen.")
        XCTAssertTrue(rig.window.firstResponder === catcher, "It took the keyboard when it opened, from the field behind it.")
        for key in [Rig.Key.left, .right, .up, .down, .tab, .enter] { rig.press(key) }
        XCTAssertEqual(rig.sent, [.left, .right, .up, .down, .tab, .enter], "Each key went to Claude, in order.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "Enter was Claude's, not a message to send.")

        rig.press(.escape)
        XCTAssertEqual(rig.sent.last, .escape, "Esc closes Claude's panel…")
        XCTAssertEqual(rig.escapes.count, 0, "…and does not put the island away.")
        XCTAssertEqual(rig.sent.count, 7)
    }

    func testOnlyThePanelsKeysGetThroughAndAHeldKeyIsOneTrip() throws {
        let rig = Rig(screen: usageScreen)
        rig.press(.letter("a"))
        rig.press(.letter("/"))
        rig.press(.tab, .shift)
        rig.press(.left, .option)
        rig.press(.enter, .shift)
        XCTAssertTrue(rig.sent.isEmpty, "Letters, ⇧⇥, ⌥← and ⇧↵ are not the panel's.")
        XCTAssertEqual(rig.session.draft, "", "Nothing typed went into the hidden field either.")
        rig.press(.down, repeating: true)
        rig.press(.down, repeating: true)
        XCTAssertTrue(rig.sent.isEmpty, "A held key does not flood Terminal with trips.")
        rig.press(.down)
        XCTAssertEqual(rig.sent, [.down])
        XCTAssertEqual(rig.escapes.count, 0)
    }

    func testTheButtonsSendTheSameKeys() throws {
        let rig = Rig(screen: usageScreen)
        // "Cerrar · esc" sits at the toolbar's right end: the card is 15 pt from the island's edge, the toolbar 34 pt tall under 2 pt.
        rig.click(x: 572 - 15 - 10 - 20, fromTop: 2 + 17)
        XCTAssertEqual(rig.sent, [.escape], "The close button is Esc.")
        rig.sent.removeAll()
        // The key strip lies left of it: the last two keys are Tab and Enter, each 24 pt wide.
        rig.click(x: 572 - 15 - 10 - 86 - 8 - 12, fromTop: 2 + 17)
        XCTAssertEqual(rig.sent, [.enter], "A click on the strip's last key.")
        XCTAssertTrue(rig.window.firstResponder === rig.catcher, "Clicking a button keeps the keyboard in the card.")
        XCTAssertEqual(rig.escapes.count, 0)
    }

    func testKeysGoNowhereWhenTheTerminalIsGone() {
        let rig = Rig(screen: usageScreen)
        rig.session.isRunning = false
        Rig.settle(0.2)
        rig.press(.left)
        rig.press(.escape)
        XCTAssertTrue(rig.sent.isEmpty, "The terminal behind the tab is not running: there is nowhere to press.")
    }

    // MARK: Coming and going

    func testThePanelComesAndGoesWithTheScreenAndTheFieldGetsTheKeyboardBack() throws {
        let rig = Rig(draft: "borrador", hold: 0.3)
        XCTAssertNil(rig.catcher, "No panel: the island is as it was.")
        let field = try XCTUnwrap(rig.field)
        XCTAssertEqual(field.string, "borrador")

        rig.show(usageScreen)
        let catcher = try XCTUnwrap(rig.catcher)
        XCTAssertTrue(rig.window.firstResponder === catcher)

        // A reading caught while Claude redraws misses the panel for a moment: it does not blink away.
        rig.show(ClaudePanelFixtures.closed, wait: 0.1)
        XCTAssertTrue(rig.catcher === catcher, "Held for a moment…")
        rig.show(usageScreen, wait: 0.1)
        Rig.settle(0.5)
        XCTAssertTrue(rig.catcher === catcher, "…and the next reading brought it back: it never left.")

        // Claude really closed it.
        rig.showClosedAndWaitForThePanelToLeave()
        XCTAssertNil(rig.catcher, "A panel the screen no longer shows leaves once the hold has passed.")
        let back = try XCTUnwrap(rig.field)
        XCTAssertTrue(rig.window.firstResponder === back, "The message field has the keyboard again.")
        XCTAssertEqual(back.string, "borrador", "The draft waited for it.")
        XCTAssertEqual(rig.session.draft, "borrador")
    }

    func testSendingStillWorksAndEnterWentToThePanelWhileItWasOpen() throws {
        let rig = Rig(draft: "borrador", hold: 0.05)
        rig.show(usageScreen)
        rig.press(.enter)
        XCTAssertEqual(rig.sent, [.enter])
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "Enter in the panel did not send the draft behind it.")
        XCTAssertEqual(rig.session.draft, "borrador")

        rig.showClosedAndWaitForThePanelToLeave()
        XCTAssertNil(rig.catcher)
        let field = try XCTUnwrap(rig.field)
        field.insertText(" más", replacementRange: field.selectedRange())
        Rig.settle()
        XCTAssertEqual(rig.session.draft, "borrador más")
        rig.session.isRunning = true
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["borrador más"], "Enter sends again, as it always did.")
        XCTAssertEqual(rig.session.draft, "")
        XCTAssertEqual(rig.sent, [.enter], "…and the panel's keys were not touched.")
    }

    func testAfterEscThePanelLeavesAsSoonAsTheScreenStopsShowingIt() {
        // With a long hold, a panel closed by someone else (in Terminal itself) stays for it; one closed with Esc here does not wait.
        let other = Rig(screen: usageScreen, hold: 5)
        other.show(ClaudePanelFixtures.closed, wait: 0.5)
        XCTAssertNotNil(other.catcher, "Closed in Terminal: held, in case the reading was caught mid-redraw.")

        let rig = Rig(screen: usageScreen, hold: 5)
        rig.press(.escape)
        XCTAssertNotNil(rig.catcher, "Esc was pressed, but the screen still shows the panel.")
        // With a hold of 5 s, gone well before it means the Esc cut the wait short.
        let closed = Date()
        rig.showClosedAndWaitForThePanelToLeave()
        XCTAssertNil(rig.catcher, "Esc asked for the closing: the panel goes as soon as the screen says it is gone.")
        XCTAssertLessThan(Date().timeIntervalSince(closed), 4)
        XCTAssertNotNil(rig.field)
    }

    func testAQuestionsCardWinsOverThePanel() throws {
        // A long hold: if the card did not win by itself, the panel would still be on screen for seconds.
        let rig = Rig(screen: usageScreen, hold: 5)
        XCTAssertNotNil(rig.catcher)
        let permission = ["⏺ Voy a limpiar la carpeta.", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        rig.show(permission)
        XCTAssertNotNil(rig.session.prompt)
        XCTAssertNil(rig.session.panel, "The data already has no panel while a question is open.")
        XCTAssertNil(rig.catcher, "The question's card is on screen at once, not the panel held over from before.")
        XCTAssertNil(rig.field, "The card has the composer's place.")
        rig.show(usageScreen)
        XCTAssertNotNil(rig.catcher, "With the question gone, the panel is again what the screen shows.")
    }

    // MARK: With the agent's view, and Esc at the island

    func testEscClosesThePanelFirstAndTheAgentsViewStaysForAfterwards() throws {
        let rig = Rig(hold: 0.05)
        rig.session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil)
        rig.session.view(agent: "call-a")
        rig.session.applyAgentText("> tarea del agente\n\n", call: "call-a")
        Rig.settle()
        XCTAssertEqual(Rig.find(LiveTerminalScrollView.self, in: rig.host)?.textView.string, "> tarea del agente\n\n")

        rig.show(usageScreen)
        XCTAssertNotNil(rig.catcher, "The panel belongs to Claude: it shows over the agent's view too.")
        rig.press(.escape)
        XCTAssertEqual(rig.sent, [.escape], "Esc went to Claude's panel…")
        XCTAssertEqual(rig.session.viewedAgent, "call-a", "…not to the agent's view, which is still where the user left it.")
        XCTAssertEqual(rig.escapes.count, 0)

        rig.showClosedAndWaitForThePanelToLeave()
        XCTAssertNil(rig.catcher)
        XCTAssertEqual(Rig.find(LiveTerminalScrollView.self, in: rig.host)?.textView.string, "> tarea del agente\n\n", "The agent's conversation is back as it was.")
        rig.press(.escape)
        XCTAssertNil(rig.session.viewedAgent, "With no panel, the next Esc goes back to Claude's conversation, as before.")
        XCTAssertEqual(rig.escapes.count, 0)
        rig.press(.escape)
        XCTAssertEqual(rig.escapes.count, 1, "…and the one after that is the island's.")
    }

    func testTheIslandsEscClosesAPanelBeforeItCollapsesAndLeavesItAloneOtherwise() throws {
        let rig = Rig()
        XCTAssertFalse(rig.model.dismissPanel(), "No panel: the key keeps its other meanings.")
        XCTAssertTrue(rig.sent.isEmpty)
        rig.show(usageScreen)
        XCTAssertNil(rig.session.panelEscapedAt)
        XCTAssertTrue(rig.model.dismissPanel(), "With a panel open the island's Esc is Claude's.")
        XCTAssertEqual(rig.sent, [.escape])
        XCTAssertNotNil(rig.session.panelEscapedAt, "…and it is remembered, so the closing that follows is not held back.")

        rig.session.isRunning = false
        XCTAssertFalse(rig.model.dismissPanel(), "Nowhere to press: the island decides what Esc means.")
        rig.session.isRunning = true

        // The same through the whole island: with the keyboard somewhere else (the hidden field), Esc still closes the panel.
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-panelkeys-" + UUID().uuidString)!)
        let session = TerminalSession(tab: Rig.tab(usageScreen), backend: .bundled, bridge: model.terminalBridge)
        session.terminalBridge = nil
        session.transcriptLocated = Date()
        var sent: [TerminalKey] = []
        model.keySender = { key, _ in sent.append(key) }
        model.sessions = [session]; model.selectedID = session.id
        model.islandContentVisible = true
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 266), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        Rig.settle(0.6)
        let field = try XCTUnwrap(Rig.find(ComposerFieldView.self, in: host)).textView
        window.makeFirstResponder(field)
        Rig.settle(0.1)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        }
        Rig.settle(0.2)
        XCTAssertEqual(sent, [.escape], "Esc reached Claude's panel through the island's own handler.")
    }

    func testTheCardDoesNotTakeTheKeyboardFromATextFieldBeingEdited() throws {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let field = NSTextField(frame: NSRect(x: 10, y: 50, width: 200, height: 22))
        let catcher = PanelKeyView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content.addSubview(field)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        Rig.settle(0.1)
        XCTAssertTrue((window.firstResponder as? NSText)?.isFieldEditor == true, "The field is being edited.")
        content.addSubview(catcher)
        Rig.settle(0.2)
        XCTAssertFalse(window.firstResponder === catcher, "Someone typing in a field keeps the keyboard.")
        window.makeFirstResponder(nil)
        catcher.takeKeyboard()
        Rig.settle(0.1)
        XCTAssertTrue(window.firstResponder === catcher, "With nothing being edited it takes it.")
    }

    // MARK: Looks

    /// Opt-in, like the other render tests: the pane after a run of keys, to see the key flash and the card in a real window.
    func testRenderTheCardInARealWindow() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the panel.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let rig = Rig(screen: ClaudePanelFixtures.screen(ClaudePanelFixtures.list))
        rig.press(.down)
        try rig.snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-keys-window.png").path)
    }
}
