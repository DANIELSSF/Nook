import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The keys of the card of Claude's question with a preview: the digits that choose an option, «n» that opens the notes, and what a digit is while the notes are being typed.
/// The card is hosted alone in an offscreen window that never becomes key, and its keys are handed to the window as events (nothing is posted to the system and nothing takes
/// the keyboard): SwiftUI gives the card the keyboard there as it does on screen, and its key presses reach it through the window's own dispatch. Nothing here reaches
/// Terminal, a real session or the user's keyboard.
@MainActor
final class PreviewCardKeyTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures

    private final class Answers {
        var plain: [Int] = []
        var withNotes: [String] = []
    }

    /// A card over `rows`, its answers recorded, in a window of its own.
    @MainActor private final class Rig {
        let answers = Answers()
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(rows: [String], busy: Bool = false, width: CGFloat = 542, maxHeight: CGFloat? = nil) throws {
            let prompt = try XCTUnwrap(AgentPrompt.parse(rows.joined(separator: "\n")))
            let answers = self.answers
            let height = maxHeight.map { $0 + 10 } ?? 400
            let card = AgentPromptCard(prompt: prompt, busy: busy, maxHeight: maxHeight, width: width, onChoose: { answers.plain.append($0) },
                                       onChooseWithNotes: { answers.withNotes.append("\($0):\($1)") })
                .frame(width: width, height: height).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
            host = NSHostingView(rootView: AnyView(card))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            // Borderless: it can never become the key window, so nothing here can take the keyboard from whoever has it.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        }

        var field: ComposerTextView? { Self.find(ComposerFieldView.self, in: host)?.textView }

        /// Whether the notes' field is inside what the card's body shows now (the body is the tallest scroll view that is not a text field's).
        var fieldIsInView: Bool {
            var scrolls: [NSScrollView] = []
            Self.collect(in: host, into: &scrolls)
            guard let body = scrolls.filter({ !($0 is ComposerScrollView) && $0.frame.height > 80 }).max(by: { $0.frame.height < $1.frame.height }), let document = body.documentView,
                  let field = Self.find(ComposerFieldView.self, in: host) else { return false }
            return body.documentVisibleRect.contains(field.convert(field.bounds, to: document))
        }

        private static func collect(in view: NSView, into list: inout [NSScrollView]) {
            if let scroll = view as? NSScrollView { list.append(scroll) }
            for sub in view.subviews { collect(in: sub, into: &list) }
        }

        private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }

        /// The keyboard is with the card: SwiftUI's own key view, not a text view.
        var cardHasTheKeyboard: Bool { !(window.firstResponder is NSTextView) && window.firstResponder != nil }

        /// A key as the window would dispatch it.
        func press(_ characters: String, code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }

        func digit(_ number: Int) { press("\(number)", code: [29, 18, 19, 20, 21, 23, 22, 26, 28, 25][number]) }
        func enter() { press("\r", code: 36) }
        func n() { press("n", code: 45) }
        func esc() { press("\u{1b}", code: 53); RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
    }

    // MARK: The digits

    /// The digits choose the options the terminal numbers, and nothing else: «Chat about this» has no number where the preview is drawn.
    func testDigitsChooseTheNumberedOptions() throws {
        let rig = try Rig(rows: F.sample())
        XCTAssertTrue(rig.cardHasTheKeyboard, "The card takes the keyboard when it appears.")
        rig.digit(2)
        rig.digit(1)
        XCTAssertEqual(rig.answers.plain, [1, 0])
        rig.digit(3)
        rig.digit(9)
        rig.digit(0)
        XCTAssertEqual(rig.answers.plain, [1, 0], "No option has those numbers.")
        XCTAssertEqual(rig.answers.withNotes, [])
    }

    func testABusyCardTakesNoDigit() throws {
        let rig = try Rig(rows: F.sample(), busy: true)
        rig.digit(1)
        XCTAssertEqual(rig.answers.plain, [], "The keys of the answer on its way are not answered over.")
    }

    // MARK: The notes

    /// «n» opens the notes as in the terminal: the field takes the keyboard (the «n» is not typed), and a digit is then a character of the note, never a choice. Esc gives the
    /// keyboard back to the card and keeps the note, and the next digit chooses its option with it.
    func testNOpensTheNotesAndADigitInThemIsText() throws {
        let rig = try Rig(rows: F.sample())
        let field = try XCTUnwrap(rig.field)
        rig.n()
        XCTAssertTrue(rig.window.firstResponder === field, "The field has the keyboard.")
        XCTAssertEqual(field.string, "", "The key that opened it is not typed into it.")
        rig.digit(1)
        XCTAssertEqual(rig.answers.plain, [], "A digit typed into the notes chooses nothing.")
        XCTAssertEqual(field.string, "1", "It is a character of the note.")
        rig.n()
        XCTAssertEqual(field.string, "1n", "An «n» typed into the notes is a letter.")
        // Esc: back to the card, the note kept, and nothing chosen or sent by leaving.
        rig.esc()
        XCTAssertFalse(rig.window.firstResponder === field, "The card has the keyboard again.")
        XCTAssertTrue(rig.cardHasTheKeyboard)
        XCTAssertEqual(field.string, "1n")
        XCTAssertEqual(rig.answers.plain, [])
        XCTAssertEqual(rig.answers.withNotes, [])
        // The digit that chooses now carries the note.
        rig.digit(2)
        XCTAssertEqual(rig.answers.withNotes, ["1:1n"], "The second option, with the note the first Esc kept.")
        XCTAssertEqual(rig.answers.plain, [])
    }

    /// ↵ in the notes sends them with the option the preview belongs to (the highlighted one, here the second), through the window's own dispatch: the card's key handlers
    /// (which ignore ↵ outside Claude's model picker) leave it to the field. Nothing written, nothing sent.
    func testEnterInTheNotesSendsThemWithTheOptionOfThePreview() throws {
        let rig = try Rig(rows: F.sample(highlight: 2))
        rig.n()
        rig.enter()
        XCTAssertEqual(rig.answers.withNotes, [], "Nothing written, nothing sent.")
        XCTAssertEqual(rig.answers.plain, [])
        rig.field?.insertText("el logo a la izquierda", replacementRange: NSRange(location: 0, length: 0))
        rig.enter()
        XCTAssertEqual(rig.answers.withNotes, ["1:el logo a la izquierda"], "The option the preview shows, with the note.")
        XCTAssertEqual(rig.answers.plain, [])
    }

    /// The notes' field holds the note while it is written; a click or a digit on an option of «Chat about this» is never sent with it (no digit chooses it, and the click is
    /// the pane's, which the pane tests hold).
    func testTheNotesGoWithTheNumberedOptionsOnly() throws {
        let rig = try Rig(rows: F.sample())
        rig.n()
        rig.field?.insertText("el logo a la izquierda", replacementRange: NSRange(location: 0, length: 0))
        rig.esc()
        rig.digit(1)
        rig.digit(3)
        XCTAssertEqual(rig.answers.withNotes, ["0:el logo a la izquierda"])
        XCTAssertEqual(rig.answers.plain, [])
    }

    /// A card that scrolls (the Normal island's room is 190 pt) with the notes' field below the fold: «n» brings it into view, and what is written, which makes it taller (and puts
    /// its caption under it), keeps it in view. Beside the options, and stacked under the box in a narrower card.
    func testTheNotesComeIntoViewAndStayThereAsTheyGrow() throws {
        for width in [542.0, 410.0] {
            let rig = try Rig(rows: F.sample(), width: width, maxHeight: 190)
            XCTAssertFalse(rig.fieldIsInView, "\(Int(width)) pt: the field starts under the fold.")
            rig.n()
            XCTAssertTrue(rig.fieldIsInView, "\(Int(width)) pt: «n» brings it into view.")
            rig.field?.insertText("el logo a la izquierda y el nombre de la empresa en dos líneas, más una nota larga para llenar tres líneas del campo de notas", replacementRange: NSRange(location: 0, length: 0))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            XCTAssertTrue(rig.fieldIsInView, "\(Int(width)) pt: it stays in view as it grows.")
        }
    }

    // MARK: What the terminal holds

    /// The terminal already holds notes: «n» opens nothing (the card has no field of its own then), and the digits choose as they always did.
    func testWhenTheTerminalHoldsNotesNOpensNothing() throws {
        let rig = try Rig(rows: F.sample(notes: "el logo a la izquierda"))
        XCTAssertNil(rig.field)
        rig.n()
        XCTAssertTrue(rig.cardHasTheKeyboard, "Nothing took the keyboard.")
        rig.digit(2)
        XCTAssertEqual(rig.answers.plain, [1])
        XCTAssertEqual(rig.answers.withNotes, [])
    }

    /// The terminal's own notes field has the keyboard, empty or with text being typed in it: the keys would land in it, so the digits wait with the rows (which are dimmed),
    /// and «n» opens nothing.
    func testWhileTheTerminalsNotesFieldHasTheKeyboardTheDigitsWait() throws {
        for (name, rows) in [("open and empty", F.sample(notes: "Add notes on this design…")), ("with text being typed", F.sample(notes: "el logo a la izquierda", focused: true))] {
            let rig = try Rig(rows: rows)
            XCTAssertNil(rig.field, name)
            rig.digit(1)
            rig.digit(2)
            rig.n()
            XCTAssertEqual(rig.answers.plain, [], name)
            XCTAssertEqual(rig.answers.withNotes, [], name)
        }
    }

    // MARK: The other questions

    /// A question without a preview: «n» is not a key of the card, and the digits are the options' positions as they always were («Chat about this» is the fourth).
    func testAQuestionWithoutAPreviewKeepsItsDigitsAndIgnoresN() throws {
        let rig = try Rig(rows: F.nextTab)
        rig.n()
        XCTAssertTrue(rig.cardHasTheKeyboard)
        rig.digit(4)
        rig.digit(1)
        XCTAssertEqual(rig.answers.plain, [3, 0])
    }

    /// Nothing here may be seen by whoever is using the Mac: the window never becomes key and the test process never takes the front.
    func testTheProbesNeverTakeTheKeyboardOrTheFront() throws {
        // Other UI tests may already have activated XCTest; these probes must not change that state.
        let wasActive = NSApp.isActive
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rig = try Rig(rows: F.sample())
        rig.n()
        rig.esc()
        rig.digit(2)
        XCTAssertFalse(rig.window.isKeyWindow)
        XCTAssertEqual(NSApp.isActive, wasActive, "The probes do not change application activation.")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, before, "Whatever was in front stays there.")
    }
}
