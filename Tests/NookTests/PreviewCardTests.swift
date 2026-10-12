import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What the card of Claude's question with a preview puts on screen, without a window of its own: how it arranges the options, the box and the notes by the card's width, the
/// mock's size and heights, the words (Spanish), and that the pane's estimate of the card's height stays close to the card as SwiftUI lays it out. Sample's dialog and its
/// variants are `PreviewQuestionFixtures`. Nothing here reaches Terminal, a real session or the keyboard.
@MainActor
final class PreviewCardTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private typealias M = PreviewMetrics

    private func prompt(_ rows: [String], file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        try XCTUnwrap(AgentPrompt.parse(rows.joined(separator: "\n")), "The fixture is not a dialog", file: file, line: line)
    }

    // MARK: How the card arranges itself

    /// The Normal island's card (542 pt) has the room for Sample's mock beside the options; the smallest island's (410 pt) does not, and the box takes its whole width.
    func testTheBoxStandsBesideTheOptionsWhileTheMockFitsAndStacksWhenItDoesNot() throws {
        let sample = try prompt(F.sample())
        let normal = M.arrange(sample.preview, hiddenLines: sample.previewHiddenLines, width: 542)
        XCTAssertTrue(normal.beside)
        XCTAssertFalse(normal.scrollsAcross)
        XCTAssertGreaterThanOrEqual(normal.fontSize, M.floorSize, "Shrunk to fit, never under the floor.")
        XCTAssertLessThanOrEqual(normal.fontSize, M.nominalSize)
        XCTAssertEqual(normal.optionsWidth + M.besideGap + normal.boxWidth, 542 - 2 * M.edge, accuracy: 0.5, "The two columns take the card's width between its margins.")
        let smallest = M.arrange(sample.preview, hiddenLines: sample.previewHiddenLines, width: 410)
        XCTAssertFalse(smallest.beside, "No room beside the options at the smallest island: the box takes the card's width.")
        XCTAssertEqual(smallest.boxWidth, 410 - 2 * M.edge)
        XCTAssertEqual(smallest.fontSize, M.nominalSize, "With the whole width the mock keeps the size it is drawn at.")
        // A wide island leaves it all its size beside the options too.
        XCTAssertEqual(M.arrange(sample.preview, width: 690).fontSize, M.nominalSize)
        XCTAssertTrue(M.arrange(sample.preview, width: 690).beside)
    }

    /// A mock wider than the room beside the options is not squeezed past what reads: the card stacks the box under the options (the whole width is the mock's), and a mock
    /// wider than even that scrolls across inside its box.
    func testAWideMockStacksAndAVeryWideOneScrollsAcross() {
        let wide = (["┌" + String(repeating: "─", count: 84) + "┐"] + [String(repeating: "x", count: 86)]).joined(separator: "\n")
        let stacked = M.arrange(wide, width: 542)
        XCTAssertFalse(stacked.beside)
        XCTAssertFalse(stacked.scrollsAcross)
        XCTAssertGreaterThanOrEqual(stacked.fontSize, M.floorSize)
        let huge = String(repeating: "x", count: 200)
        let scrolls = M.arrange(huge, width: 542)
        XCTAssertFalse(scrolls.beside)
        XCTAssertTrue(scrolls.scrollsAcross, "Past the floor the box scrolls.")
        XCTAssertEqual(scrolls.fontSize, M.floorSize)
    }

    /// The user's chat text size is the card's: the mock, its floor and the options' column all follow it.
    func testTheTextSizeTheUserChoseScalesTheMock() throws {
        let sample = try prompt(F.sample())
        let small = M.arrange(sample.preview, width: 690, chatSize: 11)
        let big = M.arrange(sample.preview, width: 690, chatSize: 16)
        XCTAssertGreaterThan(big.fontSize, small.fontSize)
        XCTAssertGreaterThan(big.optionsWidth, small.optionsWidth)
        XCTAssertGreaterThan(big.lineHeight, small.lineHeight)
    }

    /// The box is as tall as its mock, or as tall as the room it is given; a mock taller than that scrolls inside it, and the box never gives up a few lines of it.
    func testTheBoxIsCappedByTheRoomAndNeverUnderItsMinimum() throws {
        let tall = (1...40).map { "línea \($0)" }.joined(separator: "\n")
        let arrangement = M.arrange(tall, hiddenLines: 3, width: 542)
        XCTAssertEqual(arrangement.lines, 40)
        XCTAssertEqual(arrangement.height(cap: nil), arrangement.naturalHeight)
        XCTAssertEqual(arrangement.height(cap: 200), 200)
        XCTAssertTrue(arrangement.scrollsDown(cap: 200))
        XCTAssertFalse(arrangement.scrollsDown(cap: nil))
        XCTAssertFalse(arrangement.scrollsDown(cap: arrangement.naturalHeight + 50))
        XCTAssertEqual(arrangement.height(cap: arrangement.naturalHeight + 50), arrangement.naturalHeight, "Room to spare is not filled.")
        XCTAssertEqual(arrangement.height(cap: 10), arrangement.minimumHeight, "Little room: still a few lines of the mock.")
        XCTAssertEqual(arrangement.minimumHeight, M.headerHeight + 2 * M.insetY + CGFloat(M.minLines) * arrangement.lineHeight + M.foldHeight)
        // Without a fold the box has no row for it.
        XCTAssertLessThan(M.arrange(tall, width: 542).naturalHeight, arrangement.naturalHeight)
        // An option with no preview has the short box that says so.
        let none = M.arrange(nil, width: 542)
        XCTAssertFalse(none.hasPreview)
        XCTAssertEqual(none.naturalHeight, M.headerHeight + M.emptyHeight)
    }

    /// The line height the arrangement counts is the one SwiftUI sets for the mock's font: a block of lines laid out is as tall as the arrangement says.
    func testALineOfTheMockIsAsTallAsTheArrangementCounts() {
        for size in [9.0, 9.5, 10.0, 10.5, 12.0, 14.0] as [CGFloat] {
            let text = Text(verbatim: (1...10).map { "│ línea \($0) ≡ │" }.joined(separator: "\n")).font(Font(M.mockFont(size) as CTFont)).fixedSize()
            let host = NSHostingView(rootView: text)
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, 10 * M.lineHeight(size), accuracy: 0.5, "at \(size) pt")
        }
    }

    func testTheMockKeepsItsWhitespaceAndItsTabsAreSpaces() {
        XCTAssertEqual(M.displayed("  · a\n\tb"), "  · a\n    b")
        XCTAssertEqual(M.ink(of: "abc\nabcdef").lines, 2)
        XCTAssertEqual(M.ink(of: "abc\nabcdef").widest, ("abcdef" as NSString).size(withAttributes: [.font: M.mockFont(100)]).width / 100, accuracy: 0.001, "Measured by its widest line.")
    }

    // MARK: The words

    func testTheFoldSaysHowManyLinesClaudeKeepsOut() {
        XCTAssertEqual(PreviewCopy.hidden(5, agentName: "Claude"), "Claude oculta 5 líneas más")
        XCTAssertEqual(PreviewCopy.hidden(1, agentName: "Claude"), "Claude oculta 1 línea más")
        XCTAssertTrue(PreviewCopy.hiddenHelp(5, agentName: "Claude").contains("5 líneas"))
        XCTAssertTrue(PreviewCopy.hiddenHelp(1, agentName: "Claude").contains("una línea"))
        XCTAssertEqual(PreviewCopy.caption(sendsWith: 1), "Se envían con la opción que elijas, o con ↵ en la opción 1.")
        XCTAssertEqual(PreviewCopy.caption(sendsWith: nil), "Se envían con la opción que elijas.")
        XCTAssertEqual(PreviewCopy.spokenLabel(number: 2, title: "Ticket aparte"), "Vista previa de la opción 2: Ticket aparte")
    }

    /// VoiceOver reads the mock's words, not the lines it is framed with.
    func testTheSpokenMockHasNoFrames() {
        let mock = ["Hoy:", "┌────────────┐", "│ ≡  VIBE    │", "└────────────┘", "", "Propuesta:"].joined(separator: "\n")
        XCTAssertEqual(PreviewCopy.spoken(mock), "Hoy:\n≡ VIBE\nPropuesta:")
    }

    /// The digits choose the options the terminal numbers; where it draws the preview, «Chat about this» has no number and no digit chooses it. Any other question is as it was:
    /// the digit is the option's position.
    func testDigitsChooseTheOptionsTheTerminalNumbers() throws {
        let sample = try prompt(F.sample())
        XCTAssertEqual(PromptCardText.optionIndex(forDigit: 1, in: sample), 0)
        XCTAssertEqual(PromptCardText.optionIndex(forDigit: 2, in: sample), 1)
        XCTAssertNil(PromptCardText.optionIndex(forDigit: 3, in: sample), "The third row is «Chat about this»: not numbered.")
        XCTAssertNil(PromptCardText.optionIndex(forDigit: 0, in: sample))
        XCTAssertNil(PromptCardText.optionIndex(forDigit: 9, in: sample))
        let plain = try prompt(F.nextTab)
        XCTAssertFalse(plain.takesNotes)
        XCTAssertEqual((1...4).map { PromptCardText.optionIndex(forDigit: $0, in: plain) }, [0, 1, 2, 3])
        XCTAssertNil(PromptCardText.optionIndex(forDigit: 5, in: plain))
        XCTAssertNil(PromptCardText.optionIndex(forDigit: 0, in: plain))
    }

    /// The notes written for a question belong to it: another question (another signature) never finds them.
    func testNotesBelongToTheirQuestion() {
        let kept = WrittenNotes.keeping("el logo a la izquierda", for: "A")
        XCTAssertEqual(WrittenNotes.text(kept, for: "A"), "el logo a la izquierda")
        XCTAssertEqual(WrittenNotes.text(kept, for: "B"), "")
        XCTAssertNil(WrittenNotes.keeping("", for: "A"), "Empty notes are kept as nothing.")
        XCTAssertEqual(WrittenNotes.text(nil, for: "A"), "")
    }

    /// The tab keeps its notes while its pane is made again (the user goes to another tab and comes back), and gives them up when they are cleared.
    func testATabKeepsItsNotesWhileItsPaneIsRebuilt() {
        let store = WrittenNotesStore()
        XCTAssertNil(store.notes(for: "tab"))
        store.set(WrittenNotes.keeping("el logo a la izquierda", for: "A"), for: "tab")
        XCTAssertEqual(WrittenNotes.text(store.notes(for: "tab"), for: "A"), "el logo a la izquierda")
        XCTAssertEqual(WrittenNotes.text(store.notes(for: "tab"), for: "B"), "", "Another question of the tab does not find them.")
        XCTAssertNil(store.notes(for: "other tab"))
        store.set(nil, for: "tab")
        XCTAssertNil(store.notes(for: "tab"))
    }

    // MARK: What the notes are

    /// One reading of the screen's notes, for the card's rows and keys, the notes' block and the estimate: Nook's to write, held with the field closed, or in the terminal's
    /// hands (its field has the keyboard, empty or with text being typed: what tells them apart from held notes is `AgentPrompt.notesFocused`).
    func testTheNotesAreEditableHeldOrInTheTerminalsHands() throws {
        let notes = "el logo a la izquierda"
        XCTAssertEqual(PreviewNotesState(try prompt(F.sample())), .editable)
        XCTAssertEqual(PreviewNotesState(try prompt(F.single())), .editable)
        XCTAssertEqual(PreviewNotesState(try prompt(F.sample(notes: notes))), .held(notes), "Notes with the field closed: held, read only, and they go with the answer.")
        XCTAssertEqual(PreviewNotesState(try prompt(F.sample(notes: notes, focused: true))), .focused(typed: notes), "The same text with the field open: being typed.")
        XCTAssertEqual(PreviewNotesState(try prompt(F.single(notes: notes, focused: true))), .focused(typed: notes))
        XCTAssertEqual(PreviewNotesState(try prompt(F.sample(notes: "Add notes on this design…"))), .focused(typed: nil), "Open and empty: the placeholder says so.")
        XCTAssertEqual(PreviewNotesState(try prompt(F.sample(notes: "Add notes on this design…", focused: true))), .focused(typed: nil))
        XCTAssertEqual(PreviewNotesState(try prompt(F.single(notes: "Add notes on this design…", focused: true))), .focused(typed: nil))
        // A prompt that says only that its field is open is in the terminal's hands as well: the model refuses on either.
        var open = try prompt(F.sample())
        open.notesOpen = true
        XCTAssertEqual(PreviewNotesState(open), .focused(typed: nil))
        var focused = try prompt(F.sample(notes: notes))
        focused.notesFocused = true
        XCTAssertEqual(PreviewNotesState(focused), .focused(typed: notes))
    }

    /// What is typed in the terminal's field is quoted in the notice, whole in the words and at most three lines on the card; the notice's height is what the card lays out.
    func testTheFocusedNoticeQuotesWhatIsTypedAndStopsAtThreeLines() throws {
        XCTAssertEqual(PreviewCopy.focusedTyped("el logo"), "Escrito allí: «el logo»")
        XCTAssertEqual(PreviewCopy.focusedLabel, "El campo de notas está abierto en la terminal.")
        XCTAssertEqual(PreviewCopy.focusedCaption, "Ciérralo allí con Esc, o termina allí tu respuesta.", "The model's own remedy.")
        XCTAssertEqual(PreviewCopy.blockedHelp, "El campo de notas está abierto en la terminal: ciérralo allí con Esc, o termina allí tu respuesta.")
        let empty = try prompt(F.sample(notes: "Add notes on this design…"))
        let short = try prompt(F.sample(notes: "el logo", focused: true))
        let long = try prompt(F.sample(notes: String(repeating: "una nota muy larga que no cabe en tres líneas del aviso ", count: 6), focused: true))
        let longer = try prompt(F.sample(notes: String(repeating: "una nota muy larga que no cabe en tres líneas del aviso ", count: 12), focused: true))
        func height(_ prompt: AgentPrompt) -> CGFloat { M.notesHeight(prompt, width: 190, chatSize: 11, inputSize: 13) }
        XCTAssertGreaterThan(height(short), height(empty), "A line of what is typed.")
        XCTAssertGreaterThan(height(long), height(short))
        XCTAssertEqual(height(long), height(longer), "Three lines at most, however much is typed.")
        XCTAssertGreaterThan(height(empty), M.fieldHeight(inputSize: 13), "A notice is taller than the empty field.")
    }

    // MARK: The estimate

    private func fixtures() throws -> [(String, AgentPrompt)] {
        let longMock = (1...30).map { "  línea \($0) del mock" }
        let wideMock = ["┌" + String(repeating: "─", count: 84) + "┐"] + (1...4).map { _ in "│ " + String(repeating: "·", count: 82) + " │" } + ["└" + String(repeating: "─", count: 84) + "┘"]
        func question(_ mock: [String], width: Int, hidden: Int = 0) -> [String] {
            F.above + [F.rule(150), "←  ☐ Navbar  ☐ Tarjetas  ✔ Submit  →", ""] + F.question + [""]
                + F.columns(["❯ 1. Rediseñarlo aquí", "  2. Ticket aparte"], F.box(mock, width: width, hidden: hidden))
                + ["", String(repeating: " ", count: F.boxColumn) + "Notes: press n to add notes", "", F.rule(150), "  Chat about this", "", F.hint]
        }
        return [("sample", try prompt(F.sample())), ("ticket", try prompt(F.sample(highlight: 2))), ("single", try prompt(F.single())),
                ("held", try prompt(F.sample(notes: "el logo a la izquierda y el nombre de la empresa en dos líneas"))), ("open", try prompt(F.sample(notes: "Add notes on this design…"))),
                ("typing", try prompt(F.sample(notes: "el logo a la izquierda y el nombre de la empresa en dos líneas", focused: true))),
                ("typing-long", try prompt(F.sample(notes: String(repeating: "una nota muy larga que no cabe en tres líneas del aviso ", count: 6), focused: true))),
                ("long", try prompt(question(longMock, width: 40, hidden: 6))), ("wide", try prompt(question(wideMock, width: 90))),
                ("none", try prompt(question(["No preview available"], width: 44)))]
    }

    /// The estimate the pane decides by against the card as SwiftUI lays it out (the card here has no cap: it is as tall as its content): if they drifted apart, the conversation
    /// would be hidden under a card that leaves it room, or squeezed beside one that does not.
    func testTheEstimateIsCloseToTheCardAsLaidOut() throws {
        for width in [542.0, 470.0, 410.0, 690.0] {
            for (name, prompt) in try fixtures() {
                let card = AgentPromptCard(prompt: prompt, accessory: AnyView(Color.clear.frame(width: 118, height: 22)), width: width)
                    .frame(width: width).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                let host = NSHostingView(rootView: card.fixedSize(horizontal: false, vertical: true))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded() }
                let real = host.fittingSize.height
                let estimate = PromptCardText.estimatedHeight(prompt, width: width, hasAccessory: true)
                XCTAssertEqual(estimate, real, accuracy: 6, "\(name) at \(Int(width)) pt: estimated \(estimate), laid out \(real)")
            }
        }
    }

    /// The card that takes the pane (a question with a preview is always taller than the Normal island's room) is the estimate's decision, like any other card's.
    func testAQuestionWithAPreviewTakesTheNormalIslandsPane() throws {
        let sample = try prompt(F.sample())
        let height = PromptCardText.estimatedHeight(sample, width: 542, hasAccessory: true)
        XCTAssertGreaterThan(height, 189, "More than the room the card may take in the Normal island.")
        XCTAssertTrue(AgentPromptCard.coversMirror(cardHeight: min(height, 189), room: 195))
        // And what the other cards estimate is what it always was: the options as rows, nothing of the preview's layout.
        let plain = try prompt(F.nextTab)
        XCTAssertFalse(plain.takesNotes)
        XCTAssertEqual(PromptCardText.estimatedBodyHeight(plain, inline: false, width: 542), PromptCardText.estimatedBodyHeight(plain, inline: false, width: 542, inputSize: 20),
                       "The notes' text size is the preview's alone.")
    }
}
