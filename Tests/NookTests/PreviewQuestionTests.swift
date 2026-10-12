import XCTest
@testable import Nook

/// Claude's question whose options carry a preview, as Claude Code 2.1.295 draws it (its renderer, read for this: the options in a
/// column 30 wide, the highlighted option's preview in a box 4 columns to their right, at most the terminal's width less 34 columns
/// wide and its height less 26 rows tall, then the notes row, "Chat about this" under a rule and the key hint). The screens are
/// built column by column from that layout; the one Sample sent is rebuilt from his screenshot. Shared with the card's renders.
enum PreviewQuestionFixtures {
    /// The options' column and the gap after it: the box's column.
    static let boxColumn = 34

    static func rule(_ width: Int) -> String { String(repeating: "─", count: width) }

    /// The preview box as Claude draws it: `width` columns, a row per line ("│ " + the line + its padding + " │"), the fold when
    /// lines are hidden.
    static func box(_ lines: [String], width: Int, hidden: Int = 0) -> [String] {
        let inner = width - 4
        var rows = ["┌" + rule(width - 2) + "┐"]
        rows += lines.map { "│ " + $0 + String(repeating: " ", count: max(0, inner - $0.count)) + " │" }
        if hidden > 0 {
            let fold = "─── ✂ ─── \(hidden) lines hidden "
            rows.append("├" + fold + rule(max(0, width - 2 - fold.count)) + "┤")
        }
        rows.append("└" + rule(width - 2) + "┘")
        return rows
    }

    /// The options' column beside the box's: each row of `left` padded to the box's column, then the box's row (or nothing).
    static func columns(_ left: [String], _ right: [String]) -> [String] {
        (0..<max(left.count, right.count)).map { index in
            let l = index < left.count ? left[index] : "", r = index < right.count ? right[index] : ""
            guard !r.isEmpty else { return l }
            return l + String(repeating: " ", count: max(0, boxColumn - l.count)) + r
        }
    }

    /// Option 1's preview in Sample's dialog (11 lines, the widest 50 columns): today's header and the proposal, as ASCII mocks.
    static let redesign = ["Hoy:",
                           "┌──────────────────────────────────────┐",
                           "│ ≡  V I B E   INNOVASHOP GROUP S.A.S. … 🔔  ⇥ │",
                           "└──────────────────────────────────────┘",
                           "",
                           "Propuesta:",
                           "┌────────────────────────────────────────────────┐",
                           "│ ≡  VIBE                          🔔  ⇥         │",
                           "│    INNOVASHOP GROUP S.A.S.                     │",
                           "└────────────────────────────────────────────────┘",
                           "El nombre baja a una segunda línea."]
    /// Option 2's preview: four lines, no fold.
    static let ticket = ["Se deja el header como está.", "Abro un ticket para /admin y la consola:", "  · afecta a todas las pantallas", "  · lo revisa diseño antes"]

    static let question = ["│ ¿Qué hacemos con el header de la consola en el celular (imagen 2)? Es compartido por toda la consola de",
                           "│ proveedores y por /admin."]
    static let wholeQuestion = "¿Qué hacemos con el header de la consola en el celular (imagen 2)? Es compartido por toda la consola de proveedores y por /admin."
    static let hint = "Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · Esc to cancel"
    /// The key hint while the notes field has the keyboard: Claude names its external editor for it before "Esc to cancel" (2.1.295:
    /// `At&&mo&&chord("ctrl+g","edit in ${mo}")`; "Vim" when neither $VISUAL nor $EDITOR is set and VS Code's `code` isn't on the PATH).
    static func focusedHint(tabs: Bool = true, editor: String = "Vim") -> String {
        (["Enter to select", "↑/↓ to navigate", "n to add notes"] + (tabs ? ["Tab to switch questions"] : []) + ["ctrl+g to edit in \(editor)", "Esc to cancel"])
            .joined(separator: " · ")
    }
    /// `text` as Ink wraps it at `width` columns: broken at spaces, each row as long as it can be.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var rows: [String] = [], row = ""
        for word in text.components(separatedBy: " ") {
            if row.isEmpty { row = word } else if row.count + 1 + word.count <= width { row += " " + word } else { rows.append(row); row = word }
        }
        return rows + [row]
    }
    static let above = ["  define las tarjetas como blancas, con borde fino y sin radio. Por eso dos decisiones del diseño quedan a",
                        "  tu criterio.", ""]

    /// Sample's screen (imagen-pantalla-20261009-133521, 2026-10-09): 106 columns and 32 rows, so the box is 54 wide (the widest
    /// preview line, 50, plus its frame) and shows 32 − 26 = 6 lines before "✂ 5 lines hidden". `highlight` is 1 or 2 (or 3 for
    /// "Chat about this": the option above it keeps its mark and the box keeps its preview, since ↓ from the last option moves to
    /// "Chat about this" without moving the options' highlight); `notes` is what the notes row shows. `focused`: the notes field has the
    /// keyboard, and the hint names `editor` for it, wrapped at `width` (two rows at Sample's 106 columns: "… · Esc" over "to cancel").
    static func sample(highlight: Int = 1, notes: String = "press n to add notes", ticked: Int? = nil, focused: Bool = false, width: Int = 106,
                       editor: String = "Vim") -> [String] {
        let preview = highlight == 1 ? box(Array(redesign.prefix(6)), width: 54, hidden: 5) : box(ticket, width: 54)
        let mark = { (n: Int) in n == highlight || (highlight == 3 && n == 2) ? "❯" : " " }
        let tick = { (n: Int) in ticked == n ? " ✔" : "" }
        let options = ["\(mark(1)) 1. Rediseñarlo aquí\(tick(1))", "    (Recomendada)", "\(mark(2)) 2. Ticket aparte\(tick(2))"]
        return above + [rule(width), "←  ☐ Navbar  ☐ Tarjetas  ✔ Submit  →", ""] + question + [""]
            + columns(options, preview)
            + ["", String(repeating: " ", count: boxColumn) + "Notes: " + notes, "", rule(width),
               (highlight == 3 ? "❯" : " ") + " Chat about this", ""] + (focused ? wrapped(focusedHint(editor: editor), width: width) : [hint])
    }

    /// What the mirror keeps once the card takes the dialog.
    static let kept = above.dropLast() + ["", rule(106)]

    /// The same question asked alone: its label, no tabs, and Enter sends it at once.
    static let singleQuestion = "¿Qué hacemos con el header en el celular?"
    /// `focused`: the notes field has the keyboard (its hint, without "Tab to switch questions", fits the 106 columns on one row).
    static func single(highlight: Int = 1, notes: String = "press n to add notes", focused: Bool = false) -> [String] {
        let preview = highlight == 2 ? box(ticket, width: 54) : box(Array(redesign.prefix(6)), width: 54, hidden: 5)
        let mark = { (n: Int) in n == highlight ? "❯" : " " }
        return ["⏺ Una sola duda.", "", rule(106), " ☐ Navbar ", "", "│ " + singleQuestion, ""]
            + columns(["\(mark(1)) 1. Rediseñarlo aquí", "    (Recomendada)", "\(mark(2)) 2. Ticket aparte"], preview)
            + ["", String(repeating: " ", count: boxColumn) + "Notes: " + notes, "", rule(106), "  Chat about this", "",
               focused ? focusedHint(tabs: false) : "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"]
    }

    /// Claude's record once the single question is answered, and its box back.
    static func answered(_ answer: String) -> [String] {
        ["⏺ Una sola duda.", "", "⏺ User answered Claude's questions:", "  ⎿  · \(singleQuestion) → \(answer)", "",
         "✻ Pondering… (2s · esc to interrupt)", "", rule(106), "❯ ", rule(106), "  ⏵⏵ auto mode on (shift+tab to cycle)"]
    }

    /// Sample's dialog on its next tab once the first question is answered: "Navbar" ticked, the cards' question (no previews).
    static var nextTab: [String] {
        above + [rule(106), "←  ☒ Navbar  ☐ Tarjetas  ✔ Submit  →", "", "│ ¿Cómo dejamos las tarjetas?", "",
                 "❯ 1. Blancas con borde fino", "  2. Con sombra", "  3. Type something.", rule(106), "  4. Chat about this", "",
                 "Enter to select · ↑/↓ to navigate · Tab to switch questions · Esc to cancel"]
    }
}

final class PreviewQuestionTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    // MARK: - Sample's dialog

    func testSamplesPreviewQuestionIsACardWithItsTabsQuestionOptionsAndPreview() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(F.sample())), "The dialog Nook showed as a Claude panel.")
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.tabs, [AgentPrompt.Tab(title: "Navbar", answered: false, isSubmit: false), AgentPrompt.Tab(title: "Tarjetas", answered: false, isSubmit: false),
                                     AgentPrompt.Tab(title: "Submit", answered: false, isSubmit: true)])
        XCTAssertNil(prompt.header)
        XCTAssertEqual(prompt.question, F.wholeQuestion, "Both lines, without Claude's bar.")
        XCTAssertEqual(prompt.options.map(\.title), ["Rediseñarlo aquí (Recomendada)", "Ticket aparte", "Chat about this"],
                       "A title that wraps in its column is one title; the box is no part of any.")
        XCTAssertEqual(prompt.options.map(\.number), [1, 2, nil])
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .followUp])
        XCTAssertEqual(prompt.options.map(\.detail), [nil, nil, nil])
        XCTAssertEqual(prompt.highlighted, 0)
        XCTAssertFalse(prompt.multiSelect)
        XCTAssertEqual(prompt.preview, F.redesign.prefix(6).joined(separator: "\n"), "The box's lines, frame gone, the mock's own frame kept.")
        XCTAssertEqual(prompt.previewHiddenLines, 5)
        XCTAssertTrue(prompt.takesNotes)
        XCTAssertNil(prompt.notes)
        XCTAssertFalse(prompt.notesOpen)
        XCTAssertEqual(prompt.actions, [AgentPrompt.KeyAction(key: "enter", label: "select"), AgentPrompt.KeyAction(key: "↑/↓", label: "navigate"),
                                        AgentPrompt.KeyAction(key: "n", label: "add notes"), AgentPrompt.KeyAction(key: "tab", label: "switch questions"),
                                        AgentPrompt.KeyAction(key: "esc", label: "cancel")])
        XCTAssertEqual(prompt.confirmLabel, "select")
        // Choosing goes as for any numbered question: arrows from the highlight, then Enter, in one write.
        XCTAssertEqual(prompt.keys(choosing: 0), [.enter])
        XCTAssertEqual(prompt.keys(choosing: 1), [.down, .enter])
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .down, .enter], "↓ past the last option reaches \"Chat about this\".")
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 1))
        XCTAssertNotNil(TerminalAppBridge.answerAction(prompt.keys(choosing: 1)))
        // The cause: read by the numbered rules alone (here without its notes row, which the preview reading starts from), the box's
        // rows after the last option are neither its description nor quiet, so there was no dialog at all.
        XCTAssertNil(AgentPrompt.parse(lines(F.sample()).replacingOccurrences(of: "Notes:", with: "Notas")))
    }

    func testTheMirrorLosesTheWholeDialogAndKeepsWhatCameBefore() {
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(F.sample())), lines(Array(F.kept)),
                       "Tabs, question, options, box, notes, \"Chat about this\" and the hint go to the card; the rule above stays, as for other questions.")
    }

    func testTheHighlightOnTheSecondOptionShowsItsPreviewUnderTheSameSignature() throws {
        let first = try XCTUnwrap(AgentPrompt.parse(lines(F.sample())))
        let second = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(highlight: 2))))
        XCTAssertEqual(second.highlighted, 1)
        XCTAssertEqual(second.previewOption, 1)
        XCTAssertEqual(first.previewOption, 0)
        XCTAssertEqual(second.preview, F.ticket.joined(separator: "\n"), "Its own indentation kept.")
        XCTAssertEqual(second.previewHiddenLines, 0)
        XCTAssertEqual(second.signature, first.signature, "Moving the highlight changes the preview, not the question.")
        XCTAssertEqual(second.identity(ignoringOption: 0), first.identity(ignoringOption: 0))
        XCTAssertEqual(second.keys(choosing: 0), [.up, .enter])
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(F.sample(highlight: 2))), lines(Array(F.kept)))
    }

    func testChatAboutThisWithTheHighlightIsTheHighlightedOption() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(highlight: 3))))
        XCTAssertEqual(prompt.highlighted, 2, "The option above keeps its mark; the highlight is on \"Chat about this\".")
        XCTAssertEqual(prompt.previewOption, 1, "The box keeps the preview of the option the highlight left.")
        XCTAssertEqual(prompt.preview, F.ticket.joined(separator: "\n"), "What Claude draws: the second option's preview, the one `previewOption` names.")
        XCTAssertEqual(prompt.previewHiddenLines, 0)
        XCTAssertEqual(prompt.keys(choosing: 0), [.up, .up, .enter])
        XCTAssertEqual(prompt.signature, try XCTUnwrap(AgentPrompt.parse(lines(F.sample()))).signature)
    }

    func testNotesHeldOrOpenAreReadAndLeaveTheQuestionAsItWas() throws {
        let plain = try XCTUnwrap(AgentPrompt.parse(lines(F.sample())))
        let held = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(notes: "el logo a la izquierda"))))
        XCTAssertEqual(held.notes, "el logo a la izquierda")
        XCTAssertFalse(held.notesOpen)
        XCTAssertFalse(held.notesFocused, "Held: the field is closed, the hint names no editor.")
        XCTAssertFalse(plain.notesFocused)
        XCTAssertEqual(held.signature, plain.signature)
        let open = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(notes: "Add notes on this design…"))))
        XCTAssertNil(open.notes)
        XCTAssertTrue(open.notesOpen)
        XCTAssertTrue(open.notesFocused, "Only the open field draws the placeholder.")
        XCTAssertEqual(open.signature, plain.signature)
        // Long notes wrap under themselves, in the box's column.
        let wrapped = F.sample(notes: "el logo a la izquierda y el nombre de la empresa").flatMap { row -> [String] in
            row.hasSuffix("Notes: el logo a la izquierda y el nombre de la empresa")
                ? [String(repeating: " ", count: 34) + "Notes: el logo a la izquierda y el", String(repeating: " ", count: 41) + "nombre de la empresa"] : [row]
        }
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(wrapped))).notes, "el logo a la izquierda y el nombre de la empresa")
    }

    func testAnAnswerAlreadyGivenIsTickedAndTheQuestionStaysAQuestion() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(highlight: 1, ticked: 2))))
        XCTAssertEqual(prompt.options.map(\.title), ["Rediseñarlo aquí (Recomendada)", "Ticket aparte", "Chat about this"])
        XCTAssertEqual(prompt.options.map(\.current), [false, true, false])
        XCTAssertEqual(prompt.kind, .question, "A tick from an earlier answer doesn't make it a menu.")
        XCTAssertEqual(prompt.signature, try XCTUnwrap(AgentPrompt.parse(lines(F.sample()))).signature)
    }

    // MARK: - Other sizes and shapes

    /// A 64-column terminal of 30 rows: the box keeps its place beside the options (Claude has no stacked layout), 30 columns wide
    /// (64 − 34), its lines wrapped at 26, and 4 of them shown (30 − 26). The question wraps more.
    func testANarrowTerminalKeepsTheBoxBesideTheOptionsAndWrapsInsideIt() throws {
        let preview = ["Hoy: el header muestra el", "nombre completo de la", "empresa y se corta en el", "celular."]
        let rows = ["⏺ Dos decisiones quedan a tu criterio.", "", F.rule(64), "←  ☐ Navbar  ☐ Tarjetas  ✔ Submit  →", "",
                    "│ ¿Qué hacemos con el header de la consola en el celular (imagen",
                    "│ 2)? Es compartido por toda la consola de proveedores y por",
                    "│ /admin.", ""]
            + F.columns(["❯ 1. Rediseñarlo aquí", "    (Recomendada)", "  2. Ticket aparte"], F.box(preview, width: 30, hidden: 3))
            + ["", String(repeating: " ", count: 34) + "Notes: press n to add notes", "", F.rule(64), "  Chat about this", "",
               "Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.question, F.wholeQuestion)
        XCTAssertEqual(prompt.options.map(\.title), ["Rediseñarlo aquí (Recomendada)", "Ticket aparte", "Chat about this"])
        XCTAssertEqual(prompt.preview, preview.joined(separator: "\n"), "Claude's own wrapping, line by line.")
        XCTAssertEqual(prompt.previewHiddenLines, 3)
        XCTAssertEqual(prompt.tabs.map(\.title), ["Navbar", "Tarjetas", "Submit"])
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), lines(["⏺ Dos decisiones quedan a tu criterio.", "", F.rule(64)]))
    }

    /// One question alone: no arrows, no Submit tab, its label over the question, and no "Tab to switch questions" in the hint.
    /// Enter answers it and sends it at once.
    func testASingleQuestionHasItsLabelAndNoTabs() throws {
        let rows = ["⏺ Una sola duda.", "", F.rule(106), " ☐ Navbar ", "", "│ ¿Qué hacemos con el header en el celular?", ""]
            + F.columns(["❯ 1. Rediseñarlo aquí", "    (Recomendada)", "  2. Ticket aparte"], F.box(F.ticket, width: 44))
            + ["", String(repeating: " ", count: 34) + "Notes: press n to add notes", "", F.rule(106), "  Chat about this", "",
               "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.header, "Navbar")
        XCTAssertEqual(prompt.tabs, [])
        XCTAssertEqual(prompt.question, "¿Qué hacemos con el header en el celular?")
        XCTAssertEqual(prompt.preview, F.ticket.joined(separator: "\n"))
        XCTAssertEqual(prompt.actions.map(\.key), ["enter", "↑/↓", "n", "esc"])
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), lines(["⏺ Una sola duda.", "", F.rule(106)]))
    }

    /// More options than the box is tall (an option with no preview gets Claude's "No preview available"): the options run on
    /// beside the notes row.
    func testOptionsTallerThanTheBoxRunBesideTheNotesRow() throws {
        // Titles wrap at 26 columns, four columns in (the column is 30 wide and its first 4 hold the mark and the number).
        let left = ["  1. Opción uno", "❯ 2. Opción dos con un título", "    que no cabe en su columna", "  3. Opción tres", "  4. Opción cuatro"]
        let right = F.box(["No preview available"], width: 44) + ["", "Notes: press n to add notes"]
        let rows = [F.rule(100), " ☐ Orden ", "", "│ ¿En qué orden?", ""] + F.columns(left, right) + ["", F.rule(100), "  Chat about this", "",
                                                                                                "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.options.map(\.title), ["Opción uno", "Opción dos con un título que no cabe en su columna", "Opción tres", "Opción cuatro", "Chat about this"])
        XCTAssertEqual(prompt.highlighted, 1)
        XCTAssertNil(prompt.preview, "Claude's words for an option without one.")
        XCTAssertTrue(prompt.takesNotes)
        XCTAssertNil(prompt.notes)
    }

    func testANumberedListInsideThePreviewIsNoOption() throws {
        let preview = ["Pasos:", "1. Mover el logo", "2. Bajar el nombre", "3. Quitar la campana"]
        let rows = [F.rule(100), " ☐ Plan ", "", "│ ¿Qué plan?", ""]
            + F.columns(["❯ 1. Plan A", "  2. Plan B"], F.box(preview, width: 44))
            + ["", String(repeating: " ", count: 34) + "Notes: press n to add notes", "", F.rule(100), "  Chat about this", "",
               "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.options.map(\.title), ["Plan A", "Plan B", "Chat about this"])
        XCTAssertEqual(prompt.preview, preview.joined(separator: "\n"))
    }

    /// A tall terminal: a box of 70 rows still reads, tabs and question included.
    func testATallBoxStillReadsWhole() throws {
        let preview = (1...70).map { "línea \($0)" }
        let rows = [F.rule(120), "←  ☐ Navbar  ☐ Tarjetas  ✔ Submit  →", ""] + F.question + [""]
            + F.columns(["❯ 1. Rediseñarlo aquí", "  2. Ticket aparte"], F.box(preview, width: 44, hidden: 4))
            + ["", String(repeating: " ", count: 34) + "Notes: press n to add notes", "", F.rule(120), "  Chat about this", "", F.hint]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.question, F.wholeQuestion)
        XCTAssertEqual(prompt.preview?.components(separatedBy: "\n").count, 70)
        XCTAssertEqual(prompt.previewHiddenLines, 4)
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), F.rule(120))
    }

    /// The step after the last question: Claude's ordinary review (no preview, no notes), read as before.
    func testTheReviewStepAfterThePreviewQuestions() throws {
        let rows = F.above + [F.rule(106), "←  ☒ Navbar  ☒ Tarjetas  ✔ Submit  →", "", "Review your answers", "",
                              "│ ● ¿Qué hacemos con el header de la consola en el celular (imagen 2)? Es compartido por toda la consola de",
                              "│   proveedores y por /admin.",
                              "  → Rediseñarlo aquí (Recomendada)",
                              "│ ● ¿Cómo dejamos las tarjetas?",
                              "  → Blancas con borde fino", "",
                              "Ready to submit your answers?", "",
                              "❯ 1. Submit answers", "  2. Cancel", "",
                              "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.reviewTitle, "Review your answers")
        XCTAssertEqual(prompt.review.map(\.answer), ["Rediseñarlo aquí (Recomendada)", "Blancas con borde fino"])
        XCTAssertEqual(prompt.review.map(\.tab), ["Navbar", "Tarjetas"])
        XCTAssertEqual(prompt.options.map(\.title), ["Submit answers", "Cancel"])
        XCTAssertFalse(prompt.takesNotes)
        XCTAssertNil(prompt.preview)
    }

    // MARK: - Not a Claude panel

    func testThePreviewQuestionIsNoClaudePanel() throws {
        let screen = lines(F.sample())
        XCTAssertNil(ClaudeComposer.panel(F.sample()), "The highlighted option is the dialog's, not the conversation's last prompt.")
        XCTAssertNil(ClaudeComposer.split(screen).panel)
        XCTAssertNotNil(AgentPrompt.parse(ClaudeComposer.split(screen).conversation), "The split leaves the dialog whole for the card.")
        XCTAssertNil(ClaudeComposer.panel(F.sample(highlight: 3)))
    }

    func testTheSessionShowsTheCardAndNoPanel() {
        let model = AppModel(receivesSignals: false)
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys095", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false,
                                      selected: true, text: lines(F.sample()))
        tab.history = true
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertEqual(session.prompt?.options.count, 3)
        XCTAssertEqual(session.prompt?.preview, F.redesign.prefix(6).joined(separator: "\n"))
        XCTAssertNil(session.panel, "Before, Nook showed «Panel de Claude» with only \"Chat about this\" and the hint.")
    }

    func testRealPanelsStillAre() {
        // A panel's own hint, no numbered dialog: still a panel.
        XCTAssertNotNil(ClaudeComposer.panel(["⏺ Hola", "╭──────────╮", "│ Model │", "╰──────────╯", "  Enter to confirm · Esc to cancel"]))
        XCTAssertTrue(ClaudeComposer.isHighlightedOption("❯ 1. Yes"))
        XCTAssertTrue(ClaudeComposer.isHighlightedOption("❯ 12) Otro"))
        XCTAssertFalse(ClaudeComposer.isHighlightedOption("❯ Verbose output"))
        XCTAssertFalse(ClaudeComposer.isHighlightedOption("❯ "))
        XCTAssertFalse(ClaudeComposer.isHighlightedOption("    ❯ 1. Yes"), "Indented: a reply's quote, not at the edge.")
    }
}
