import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The composer's keys with the "/" menu, driven through a real window, SwiftUI's own text field and AppKit key events.
/// Nothing here starts the app or touches Terminal: the session is an owned one whose process is `true`.
@MainActor
final class SlashMenuKeyTests: XCTestCase {
    /// SwiftUI delivers Esc to the closest `onExitCommand`; the island's own is what collapses it.
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

    @MainActor private final class Rig {
        let model = AppModel(receivesSignals: false)
        let session: TerminalSession
        let escapes = Escapes()
        let window: NSWindow
        let host: NSHostingView<Island>
        let field: NSTextView

        init(history: [String] = []) throws {
            let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-keys-\(getpid()).sock", configuration: "/dev/null")
            let record = SessionRecord(id: "nook-keys-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
            session = TerminalSession(record: record, backend: backend, create: false)
            session.isRunning = true
            session.sentHistory = history
            session.applyTranscript(nil, recap: nil, skills: ["codex:rescue": "Ask Codex for a second opinion"], usedCommands: [])
            model.sessions = [session]; model.selectedID = session.id
            host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes))
            // Far off every screen: the window never shows, and a window that is not key still takes key events.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 204), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            Self.settle(0.5)
            let textField = try XCTUnwrap(Rig.find(ComposerTextView.self, in: host))
            window.makeFirstResponder(textField)
            Self.settle(0.3)
            field = try XCTUnwrap(window.firstResponder as? NSTextView)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        static func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        /// What the user types: text goes in as the keyboard would insert it.
        func type(_ text: String) {
            field.insertText(text, replacementRange: field.selectedRange())
            Self.settle()
        }

        enum Key {
            case up, down, tab, escape, enter
            var code: UInt16 { switch self { case .up: 126; case .down: 125; case .tab: 48; case .escape: 53; case .enter: 36 } }
            var characters: String { switch self { case .up: "\u{F700}"; case .down: "\u{F701}"; case .tab: "\t"; case .escape: "\u{1b}"; case .enter: "\r" } }
        }

        func press(_ key: Key, _ flags: NSEvent.ModifierFlags = []) {
            // The owned session's process (`true`) has long exited, which marks it as not running; sending needs it running.
            if key == .enter { session.isRunning = true }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)!
                window.sendEvent(event)
            }
            Self.settle()
        }

        /// A click at a point of the window, given from its top left.
        func click(x: CGFloat, fromTop y: CGFloat) {
            let point = NSPoint(x: x, y: window.contentView!.bounds.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            Self.settle()
        }

        /// The window's content as a PNG, for looking at what a key sequence left on screen.
        func snapshot(to path: String) throws {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }

        var draft: String { session.draft }
        func matches(_ draft: String) -> [String] { model.completions(for: session, draft: draft).map(\.name) }
    }

    func testArrowsWalkTheMenuAndTabCompletesTheHighlightedRow() throws {
        let rig = try Rig()
        rig.type("/")
        let all = rig.matches("/")
        XCTAssertGreaterThan(all.count, 100, "The whole reference plus the session's skills.")
        rig.press(.down); rig.press(.down)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(all[2]) ", "Tab completes the third row, with a space so arguments can follow.")
        XCTAssertEqual(rig.field.string, rig.draft)
        XCTAssertEqual(rig.field.selectedRange(), NSRange(location: (rig.draft as NSString).length, length: 0), "The cursor ends up after the completion.")
        XCTAssertTrue(rig.matches(rig.draft).isEmpty, "With the space the menu is closed.")
    }

    func testUpFromTheFirstRowWrapsToTheLastAndTheHighlightStartsOverWithEveryDraft() throws {
        let rig = try Rig()
        rig.type("/us")
        let found = rig.matches("/us")
        XCTAssertGreaterThanOrEqual(found.count, 2)
        rig.press(.up)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(found.last!) ")

        // The highlight was on the last row; a new draft starts from the top again.
        let again = try Rig()
        again.type("/u"); again.press(.down); again.press(.down)
        again.type("s")
        again.press(.tab)
        XCTAssertEqual(again.draft, "/\(again.matches("/us")[0]) ")
    }

    func testEnterSendsTheHighlightedCommandAtOnceAndClearsTheField() throws {
        let rig = try Rig()
        rig.type("/us")
        let found = rig.matches("/us")
        rig.press(.down)
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["/\(found[1])"], "The highlighted command is what goes through send().")
        XCTAssertEqual(rig.draft, "", "The field clears as it does for any message.")
        XCTAssertEqual(rig.field.string, "")
    }

    func testEnterStillSendsPlainMessagesAndAPartialCommandAfterEsc() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["hola"])
        XCTAssertEqual(rig.draft, "")

        let second = try Rig()
        second.type("/zzz-nada")
        XCTAssertTrue(second.matches("/zzz-nada").isEmpty)
        second.press(.enter)
        XCTAssertEqual(second.session.sentHistory, ["/zzz-nada"], "No match, no menu: Enter sends what was typed.")

        let third = try Rig()
        third.type("/us")
        third.press(.escape)
        third.press(.enter)
        XCTAssertEqual(third.session.sentHistory, ["/us"], "After Esc the menu is closed and Enter sends the draft as written.")
    }

    func testEscClosesTheMenuAndDoesNotReachTheIsland() throws {
        let rig = try Rig(history: ["antes"])
        rig.type("/us")
        rig.press(.escape)
        XCTAssertEqual(rig.escapes.count, 0, "Esc was the menu's: the island stays open.")
        XCTAssertEqual(rig.draft, "/us", "Closing the menu leaves the draft alone.")
        // Closed means the arrows are the history's again.
        rig.press(.up)
        XCTAssertEqual(rig.draft, "antes")

        let bare = try Rig()
        bare.type("hola")
        bare.press(.escape)
        XCTAssertEqual(bare.escapes.count, 1, "With no menu Esc goes on to collapse the island, as before.")
        bare.type(" /")
        bare.press(.escape)
        XCTAssertEqual(bare.escapes.count, 2, "A slash after other text is not a command: no menu, so Esc is the island's.")
    }

    func testTypingAfterEscOpensTheMenuAgain() throws {
        let rig = try Rig()
        rig.type("/u")
        rig.press(.escape)
        rig.press(.down)   // closed: the arrow is the history's, which is empty, so nothing moves
        rig.type("s")
        rig.press(.down)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(rig.matches("/us")[1]) ", "The menu came back on the next character, highlight on the first row before ↓.")
    }

    func testArrowsKeepWalkingTheSentMessagesWhenNoMenuShows() throws {
        let rig = try Rig(history: ["hola", "/usage", "continúa"])
        rig.press(.up)
        XCTAssertEqual(rig.draft, "continúa")
        rig.press(.up)
        XCTAssertEqual(rig.draft, "/usage", "A recalled command does not open the menu...")
        rig.press(.up)
        XCTAssertEqual(rig.draft, "hola", "...so the walk through the history goes on.")
        rig.press(.down); rig.press(.down)
        XCTAssertEqual(rig.draft, "continúa")
        rig.press(.down)
        XCTAssertEqual(rig.draft, "")
    }

    func testEditingARecalledCommandOpensTheMenuAndTheArrowsMoveIt() throws {
        let rig = try Rig(history: ["/usage"])
        rig.press(.up)
        XCTAssertEqual(rig.draft, "/usage")
        // The field editor is the one holding the text; deleting a letter is an edit by the user.
        rig.field.deleteBackward(nil)
        Rig.settle()
        XCTAssertEqual(rig.draft, "/usag")
        rig.press(.down)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(rig.matches("/usag")[1]) ")
    }

    func testTabWithoutAMenuLeavesTheDraftAlone() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "hola", "No menu: Tab is the field's usual Tab.")

        let shifted = try Rig()
        shifted.type("/us")
        shifted.press(.tab, .shift)
        XCTAssertEqual(shifted.draft, "/us", "Shift-Tab is not completion.")
    }

    func testClickingARowFillsTheFieldAndKeepsTheKeyboardThere() throws {
        let rig = try Rig()
        rig.type("/us")
        let found = rig.matches("/us")
        XCTAssertGreaterThanOrEqual(found.count, 2)
        // The composer is 66 pt tall with 9 pt below it; the menu floats 5 pt above its top, and its rows are 21 pt with 1 pt between.
        let menuHeight = SlashMenuView.height(rows: found.count)
        let menuTop = 204 - 9 - 66 - 5 - menuHeight
        let secondRow = menuTop + 4 + 22 + 10.5
        rig.click(x: 200, fromTop: secondRow)
        XCTAssertEqual(rig.draft, "/\(found[1]) ")
        XCTAssertTrue(rig.window.firstResponder === rig.field, "The click never took the keyboard from the field.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "A click fills the field; it does not send.")
    }

    func testClickingARowOfALongScrolledListPicksThatRow() throws {
        let rig = try Rig()
        rig.type("/")
        let all = rig.matches("/")
        // Eight ↓ scroll the list; the window the menu keeps is the one the state's rule gives.
        var top = 0
        for index in 1...8 { rig.press(.down); top = SlashMenuState.scrollTop(keeping: index, from: top, count: all.count) }
        XCTAssertGreaterThan(top, 0)
        let menuTop = 204 - 9 - 66 - 5 - SlashMenuView.height(rows: all.count)
        let thirdSlot = menuTop + 4 + 2 * 22 + 10.5
        rig.click(x: 200, fromTop: thirdSlot)
        XCTAssertEqual(rig.draft, "/\(all[top + 2]) ", "The row under the pointer, whatever the scroll.")
        XCTAssertTrue(rig.window.firstResponder === rig.field)
    }

    /// Opt-in, like `PanelRenderTests`: the menu after a run of arrow keys, to see the highlighted row kept in view.
    func testRenderTheMenuScrolledByTheArrows() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the menu.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, downs, ups) in [("scroll-top", 0, 0), ("scroll-3", 3, 0), ("scroll-4", 4, 0), ("scroll-8", 8, 0), ("scroll-40", 40, 0), ("scroll-wrap", 0, 1), ("scroll-wrap-up2", 0, 3), ("scroll-back", 12, 9)] {
            let rig = try Rig()
            rig.type("/")
            for _ in 0..<downs { rig.press(.down) }
            for _ in 0..<ups { rig.press(.up) }
            try rig.snapshot(to: URL(fileURLWithPath: directory).appendingPathComponent("slash-\(name).png").path)
        }
    }
}
