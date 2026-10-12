import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The composer as the pane drives it: a real `SessionPane` in an offscreen window, with real AppKit key events. Everything the
/// single-line field did (see `SlashMenuKeyTests`) has to keep working beside the new lines, and the pane has to give the
/// field's growth to the conversation without moving the island.
@MainActor
final class ComposerPaneTests: XCTestCase {
    private final class Escapes: ObservableObject { var count = 0 }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var escapes: Escapes
        var width: CGFloat
        var height: CGFloat
        var body: some View {
            SessionPane(model: model, session: session)
                .frame(width: width, height: height).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                .onExitCommand { escapes.count += 1 }
        }
    }

    @MainActor private final class Rig {
        let model: AppModel
        let session: TerminalSession
        let escapes = Escapes()
        let window: NSWindow
        let host: NSHostingView<Island>
        let field: ComposerTextView
        let fieldView: ComposerFieldView

        /// `suggestion` makes the tab a Terminal one showing Claude with that grey suggestion in its box (the only kind that has one).
        init(width: CGFloat = 572, height: CGFloat = 204, display: DisplaySettings = DisplaySettings(), history: [String] = [], draft: String = "", suggestion: String? = nil) throws {
            let defaults = UserDefaults(suiteName: "nook-pane-test-" + UUID().uuidString)!
            model = AppModel(receivesSignals: false, defaults: defaults)
            model.display = display
            if let suggestion {
                // Sending would reach the real Terminal: nothing in this rig goes that far.
                model.terminalBridge.runScript = { _ in }
                let rule = String(repeating: "─", count: 60)
                let screen = ["⏺ Listo.", "", rule, "❯ " + suggestion, rule].joined(separator: "\n")
                let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "", processes: ["claude"], busy: false, selected: true, text: screen)
                session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            } else {
                let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-pane-\(getpid()).sock", configuration: "/dev/null")
                let record = SessionRecord(id: "nook-pane-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
                session = TerminalSession(record: record, backend: backend, create: false)
                session.isRunning = true
                session.applyTranscript(nil, recap: nil, skills: [:], usedCommands: [])
            }
            session.sentHistory = history
            session.draft = draft
            model.sessions = [session]; model.selectedID = session.id
            host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes, width: width, height: height))
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            Self.settle(0.5)
            fieldView = try XCTUnwrap(Self.find(ComposerFieldView.self, in: host))
            field = fieldView.textView
            window.makeFirstResponder(field)
            Self.settle(0.3)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        static func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        func type(_ text: String) {
            field.insertText(text, replacementRange: field.selectedRange())
            Self.settle()
        }

        enum Key {
            case up, down, right, tab, escape, enter
            var code: UInt16 { switch self { case .up: 126; case .down: 125; case .right: 124; case .tab: 48; case .escape: 53; case .enter: 36 } }
            var characters: String { switch self { case .up: "\u{F700}"; case .down: "\u{F701}"; case .right: "\u{F703}"; case .tab: "\t"; case .escape: "\u{1b}"; case .enter: "\r" } }
        }

        func press(_ key: Key, _ flags: NSEvent.ModifierFlags = []) {
            if key == .enter { session.isRunning = true }
            var flags = flags
            if key == .up || key == .down || key == .right { flags.formUnion([.function, .numericPad]) }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)!
                window.sendEvent(event)
            }
            Self.settle()
        }

        /// A new line in the draft, as ⇧↵ makes it.
        func newline() { press(.enter, .shift) }

        var draft: String { session.draft }
        var caretLine: Int { (field.string as NSString).substring(to: field.selectedRange().location).filter { $0 == "\n" }.count }
    }

    // MARK: Sending

    func testEnterSendsTheWholeMessageWithItsLinesAndClearsTheFieldAtOnce() throws {
        let rig = try Rig()
        rig.type("uno"); rig.newline(); rig.type("dos"); rig.newline(); rig.type("tres")
        XCTAssertEqual(rig.draft, "uno\ndos\ntres", "⇧↵ added the lines to the draft.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "…and sent nothing.")
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["uno\ndos\ntres"], "Enter sends the message with its line breaks.")
        XCTAssertEqual(rig.draft, "")
        XCTAssertEqual(rig.field.string, "", "The field cleared at once, as it always did.")
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 1, size: 13), accuracy: 0.5, "…and went back to one line.")
    }

    func testTheBreaksLeftAtTheEndsOfAMessageAreNotSent() throws {
        let rig = try Rig()
        rig.type("hola"); rig.newline(); rig.newline()
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["hola"], "A trailing line break is not part of the message.")
        let second = try Rig()
        second.newline(); second.newline(); second.press(.enter)
        XCTAssertTrue(second.session.sentHistory.isEmpty, "A draft of only line breaks is empty: nothing is sent.")
        XCTAssertEqual(second.draft, "\n\n")
    }

    func testOptionEnterAndShiftEnterBothAddALineAndEnterAloneStillSends() throws {
        let rig = try Rig()
        rig.type("a"); rig.press(.enter, .option); rig.type("b")
        XCTAssertEqual(rig.draft, "a\nb")
        rig.press(.enter)
        XCTAssertEqual(rig.session.sentHistory, ["a\nb"])
        let plain = try Rig()
        plain.type("hola"); plain.press(.enter)
        XCTAssertEqual(plain.session.sentHistory, ["hola"])
        XCTAssertEqual(plain.field.string, "")
    }

    func testEnterOnAnEmptyFieldTakesClaudesSuggestionAndTheNextEnterSendsIt() throws {
        let rig = try Rig(suggestion: "ok avísame cuando esté listo")
        XCTAssertEqual(rig.field.placeholder, "ok avísame cuando esté listo", "Claude's grey suggestion is the field's placeholder.")
        rig.press(.enter)
        XCTAssertEqual(rig.draft, "ok avísame cuando esté listo", "Enter on the empty field copies it in.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "…and sends nothing yet.")
        XCTAssertEqual(rig.field.string, "ok avísame cuando esté listo")
        XCTAssertEqual(rig.field.selectedRange().location, ("ok avísame cuando esté listo" as NSString).length)
    }

    func testEnterTakesTheExampleOfClaudesTrySuggestionAsTabDoesAndNotItsWrapper() throws {
        let rig = try Rig(suggestion: "Try \"write a test for <filepath>\"")
        rig.press(.enter)
        XCTAssertEqual(rig.draft, "write a test for <filepath>", "The example, as ⇥ takes it: not Claude's «Try» with its quotes.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "…and nothing is sent.")
    }

    func testTabAcceptsClaudesSuggestionOnAnEmptyFieldWithoutSendingIt() throws {
        let suggestion = "ok avísame cuando esté listo"
        let rig = try Rig(suggestion: suggestion)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, suggestion, "⇥ takes the grey suggestion, as in Claude's own box.")
        XCTAssertEqual(rig.field.string, suggestion)
        XCTAssertEqual(rig.field.selectedRange(), NSRange(location: (suggestion as NSString).length, length: 0), "The caret ends up after it.")
        XCTAssertTrue(rig.session.sentHistory.isEmpty, "…and nothing is sent.")
        // With text in the field ⇥ does nothing more: no suggestion is added, no tab typed.
        rig.press(.tab)
        XCTAssertEqual(rig.draft, suggestion)
        // The user can edit what was taken.
        rig.type(" ya")
        XCTAssertEqual(rig.draft, suggestion + " ya")
    }

    func testTheRightArrowTakesTheSuggestionOnlyFromAnEmptyField() throws {
        let suggestion = "ok avísame cuando esté listo"
        let rig = try Rig(suggestion: suggestion)
        rig.press(.right)
        XCTAssertEqual(rig.draft, suggestion, "→ on the empty field takes it too.")
        XCTAssertEqual(rig.field.selectedRange().location, (suggestion as NSString).length)
        rig.field.setSelectedRange(NSRange(location: 2, length: 0))
        rig.press(.right)
        XCTAssertEqual(rig.draft, suggestion, "With text, → is the caret's.")
        XCTAssertEqual(rig.field.selectedRange().location, 3)
        // A field holding only spaces is not empty for →: the caret moves.
        let spaces = try Rig(draft: "  ", suggestion: suggestion)
        spaces.press(.right)
        XCTAssertEqual(spaces.draft, "  ")
    }

    func testTabWithNoSuggestionDoesNothingAndTheMenuKeepsItsTab() throws {
        let plain = try Rig()
        plain.press(.tab)
        XCTAssertEqual(plain.draft, "", "No suggestion: nothing to take, and no tab typed.")
        plain.press(.right)
        XCTAssertEqual(plain.draft, "")
        // With a suggestion pending and the "/" menu open, ⇥ still completes the command.
        let rig = try Rig(suggestion: "ok avísame cuando esté listo")
        rig.type("/us")
        let found = rig.model.completions(for: rig.session, draft: "/us").map(\.name)
        XCTAssertFalse(found.isEmpty)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(found[0]) ", "The menu's ⇥ is a completion, not the suggestion.")
    }

    // MARK: The arrows

    func testUpOnTheFirstLineRecallsTheHistoryAndOnOtherLinesMovesTheCaret() throws {
        let rig = try Rig(history: ["primero", "segundo"])
        rig.type("uno"); rig.newline(); rig.type("dos"); rig.newline(); rig.type("tres")
        XCTAssertEqual(rig.caretLine, 2)
        rig.press(.up)
        XCTAssertEqual(rig.draft, "uno\ndos\ntres", "On the last line ↑ walks the caret up, not the history.")
        XCTAssertEqual(rig.caretLine, 1)
        rig.press(.up)
        XCTAssertEqual(rig.draft, "uno\ndos\ntres")
        XCTAssertEqual(rig.caretLine, 0)
        rig.press(.up)
        XCTAssertEqual(rig.draft, "segundo", "On the first line ↑ recalls the newest sent message.")
        rig.press(.up)
        XCTAssertEqual(rig.draft, "primero")
        rig.press(.down)
        XCTAssertEqual(rig.draft, "segundo")
        rig.press(.down)
        XCTAssertEqual(rig.draft, "uno\ndos\ntres", "Past the newest the draft that was being written comes back, line breaks and all.")
    }

    func testDownOnTheLastLineOfARecalledMultiLineMessageGoesToAnewerOneAndElsewhereMovesTheCaret() throws {
        let rig = try Rig(history: ["a\nb", "solo"])
        rig.press(.up)
        XCTAssertEqual(rig.draft, "solo")
        rig.press(.up)
        XCTAssertEqual(rig.draft, "a\nb", "Recalled with the caret at its end, on its last line.")
        XCTAssertEqual(rig.caretLine, 1)
        rig.press(.up)
        XCTAssertEqual(rig.draft, "a\nb", "↑ inside the recalled message moves the caret first.")
        XCTAssertEqual(rig.caretLine, 0)
        rig.press(.down)
        XCTAssertEqual(rig.draft, "a\nb", "↓ on its first line moves the caret down.")
        XCTAssertEqual(rig.caretLine, 1)
        rig.press(.down)
        XCTAssertEqual(rig.draft, "solo", "On the last line ↓ goes on to the newer message.")
    }

    func testAWrappedLineIsSeveralLinesForTheArrows() throws {
        let long = Array(repeating: "palabra", count: 90).joined(separator: " ")
        let rig = try Rig(history: ["antes"], draft: long)
        rig.press(.up)
        XCTAssertEqual(rig.draft, long, "The caret at the end of a wrapped paragraph walks up its visual lines first.")
        rig.field.setSelectedRange(NSRange(location: 2, length: 0))
        rig.press(.up)
        XCTAssertEqual(rig.draft, "antes", "On the first visual line ↑ recalls.")
    }

    func testTheArrowsStillWalkTheMenuWhenItShowsEvenWithSeveralLinesElsewhere() throws {
        let rig = try Rig()
        rig.type("/us")
        let found = rig.model.completions(for: rig.session, draft: "/us").map(\.name)
        XCTAssertGreaterThanOrEqual(found.count, 2)
        rig.press(.down)
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "/\(found[1]) ", "↓ moved the menu's highlight and Tab completed it.")
        let history = try Rig(history: ["antes"])
        history.type("/us"); history.press(.escape)
        history.press(.up)
        XCTAssertEqual(history.draft, "antes", "With the menu closed, ↑ on the single line recalls the history.")
    }

    // MARK: Esc, Tab

    func testEscAndTabKeepTheirMeaning() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.escape)
        XCTAssertEqual(rig.escapes.count, 1, "With no menu Esc goes to the island.")
        rig.press(.tab)
        XCTAssertEqual(rig.draft, "hola", "Tab types no tab character.")
        let menu = try Rig()
        menu.type("/us")
        menu.press(.escape)
        XCTAssertEqual(menu.escapes.count, 0, "With the menu open Esc closes it and stops there.")
    }

    // MARK: Growth

    func testTheComposerGrowsUpwardAndTheConversationGivesUpTheRoom() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.fieldView.frame.height, 22, accuracy: 0.5)
        let before = rig.fieldView.convert(rig.fieldView.bounds, to: nil)   // window coordinates: y grows up
        rig.type("uno"); rig.newline(); rig.type("dos"); rig.newline(); rig.type("tres")
        XCTAssertEqual(rig.fieldView.frame.height, 54, accuracy: 0.5, "Three lines of 16 pt and 6 pt of padding.")
        XCTAssertEqual(rig.window.frame.size, CGSize(width: 572, height: 204), "The island's window does not change.")
        let after = rig.fieldView.convert(rig.fieldView.bounds, to: nil)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1.5, "The field's bottom edge stays where it was...")
        XCTAssertEqual(after.maxY, before.maxY + 32, accuracy: 1.5, "...and its top moved up by the two lines it gained.")
    }

    func testTheLinesTheUserChoseAreTheLinesTheFieldGrowsTo() throws {
        var two = DisplaySettings(); two.inputLines = 2
        let rig = try Rig(display: two)
        rig.type("1"); rig.newline(); rig.type("2"); rig.newline(); rig.type("3"); rig.newline(); rig.type("4")
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 2, size: 13), accuracy: 0.5)
        var six = DisplaySettings(); six.inputLines = 6
        let tall = try Rig(height: 204 + 220, display: six)
        for n in 1...8 { tall.type("\(n)"); tall.newline() }
        XCTAssertEqual(tall.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 6, size: 13), accuracy: 0.5, "Six lines in a tall island.")
        // The Normal island cannot spare six lines: the conversation keeps its room.
        let normal = try Rig(display: six)
        for n in 1...8 { normal.type("\(n)"); normal.newline() }
        let expected = ComposerMetrics.fieldHeight(lines: PaneLayout(width: 572, height: 204, settings: six).fieldLines, size: 13)
        XCTAssertEqual(normal.fieldView.frame.height, expected, accuracy: 0.5)
        XCTAssertLessThan(expected, ComposerMetrics.fieldHeight(lines: 6, size: 13))
    }

    func testTheFieldFollowsTheInputTextSize() throws {
        var big = DisplaySettings(); big.inputSize = 20
        let rig = try Rig(display: big)
        XCTAssertEqual(rig.field.font?.pointSize, 20)
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 1, size: 20), accuracy: 0.5)
        rig.type("hola")
        // The text typed is in the new size too.
        let storage = try XCTUnwrap(rig.field.textStorage)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 20)
        // And the size changes live.
        rig.model.display.inputSize = 11
        Rig.settle(0.4)
        XCTAssertEqual(rig.field.font?.pointSize, 11)
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 11, "What was typed is restyled.")
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 1, size: 11), accuracy: 0.5)
    }

    func testChangingTheLinesWhileTheFieldIsOpenAppliesAtOnce() throws {
        let rig = try Rig()
        for n in 1...5 { rig.type("\(n)"); rig.newline() }
        XCTAssertEqual(rig.fieldView.frame.height, 54, accuracy: 0.5)
        rig.model.display.inputLines = 1
        Rig.settle(0.4)
        XCTAssertEqual(rig.fieldView.frame.height, 22, accuracy: 0.5, "A limit of one line: the field shrinks and scrolls.")
        rig.model.display.inputLines = 5
        Rig.settle(0.4)
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: min(5, PaneLayout(width: 572, height: 204, settings: rig.model.display).fieldLines), size: 13), accuracy: 0.5)
    }

    func testADraftThatComesBackWithItsTabIsShownFromWhereTheCaretIs() throws {
        let draft = (1...8).map { "línea \($0)" }.joined(separator: "\n")
        let rig = try Rig(draft: draft)
        Rig.settle(0.3)
        XCTAssertEqual(rig.field.string, draft)
        XCTAssertGreaterThan(rig.fieldView.scroll.contentView.bounds.origin.y, 0, "Scrolled to the end, where the caret is.")
        XCTAssertEqual(rig.field.selectedRange().location, (draft as NSString).length)
    }

    // MARK: The "/" menu in other sizes

    func testTheMenuKeepsFiveRowsInTheNormalIslandAndShowsMoreInATallOne() throws {
        let normal = try Rig()
        normal.type("/")
        let found = normal.model.completions(for: normal.session, draft: "/").count
        XCTAssertGreaterThan(found, 100)
        let normalHeight = SlashMenuView.height(rows: found, visible: 5)
        XCTAssertEqual(normalHeight, 5 * 22 - 1 + 8)
        // The menu's rows are the ones the pane's layout asks for; scrolling by arrows keeps the highlight in the window.
        for _ in 0..<12 { normal.press(.down) }
        normal.press(.tab)
        XCTAssertTrue(normal.draft.hasPrefix("/"))

        let tall = try Rig(height: 204 + 220)
        tall.type("/")
        let layout = PaneLayout(width: 572, height: 424, settings: DisplaySettings())
        XCTAssertGreaterThan(layout.slashRows(composerHeight: 66), 5)
        for _ in 0..<20 { tall.press(.down) }
        tall.press(.tab)
        let all = tall.model.completions(for: tall.session, draft: "/").map(\.name)
        XCTAssertEqual(tall.draft, "/\(all[20]) ", "Twenty ↓ in a menu of any height highlight the twenty-first row.")
    }
}
