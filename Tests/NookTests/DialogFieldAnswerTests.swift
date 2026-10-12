import AppKit
import XCTest
@testable import Nook

/// Answering the free-text option of Claude's questions ("Type something.") from Nook: the arrows, the text and the Enter that
/// sends it, with Terminal left where it is and no key event (Sample, 9/10: "abre la terminal original y no me deja escribir
/// desde Nook"). The dialogs are drawn as Claude Code 2.1.295 draws AskUserQuestion (its source: the field's placeholder is
/// "Type something." in a question with one answer, "Type something" behind a box in one with several, and "Chat about this"
/// sits under a rule). Every transport is a recorder and every screen a fixture: nothing reaches Terminal, a real session, the
/// keyboard or Sample's delivery log.
final class DialogFieldAnswerTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)
    private let quiet = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.25, hold: 0.06, settle: 0.25)

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    /// One question with one answer, its highlight on the first option.
    private let question = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                            "❯ 1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                            "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "",
                            "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same question with `answer` written into its field (the highlight on it): the row shows the text, not the placeholder.
    private func written(_ answer: String) -> [String] {
        question.map { $0 == "❯ 1. PostgreSQL" ? "  1. PostgreSQL" : $0 == "  3. Type something." ? "❯ 3. " + answer : $0 }
    }
    /// The highlight already on the field, still empty.
    private var onTheField: [String] {
        question.map { $0 == "❯ 1. PostgreSQL" ? "  1. PostgreSQL" : $0 == "  3. Type something." ? "❯ 3. Type something." : $0 }
    }
    /// Claude took the answer: the dialog closed, its record of the answer in the chat and its box back.
    private func answered(_ answer: String) -> String {
        lines(["⏺ Antes de seguir necesito una decisión.", "", "⏺ User answered Claude's questions:", "  ⎿  · Which database should we use? → \(answer)", "",
               "✻ Pondering… (2s · esc to interrupt)", "", rule, "❯ ", rule, footer])
    }

    /// A question that takes several answers: the field sits behind its own box.
    private let platforms = [" ☐ Platforms", "", "Which platforms should the release support?", "",
                             "❯ 1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "  3. [ ] Linux", "  4. [ ] Type something", "",
                             "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    private func platforms(answer: String, ticked: Bool) -> [String] {
        platforms.map { $0 == "❯ 1. [ ] macOS" ? "  1. [ ] macOS" : $0 == "  4. [ ] Type something" ? "❯ 4. [\(ticked ? "✔" : " ")] " + answer : $0 }
    }

    // MARK: - The bytes

    func testTheAnswerIsTheArrowsThenTheTextBetweenPasteMarksInOneScript() throws {
        XCTAssertEqual(TerminalAppBridge.fieldAnswerAction(arrows: [.down, .down], text: "Usa MongoDB"),
                       #"do script ((character id 27) & "[B" & (character id 27) & "[B" & (character id 27) & "[200~" & "Usa MongoDB" & (character id 27) & "[201~") in t"#)
        XCTAssertEqual(TerminalAppBridge.fieldAnswerAction(arrows: [.up], text: "otra"),
                       #"do script ((character id 27) & "[A" & (character id 27) & "[200~" & "otra" & (character id 27) & "[201~") in t"#)
        XCTAssertEqual(TerminalAppBridge.fieldAnswerAction(arrows: [], text: "ya en el campo"),
                       #"do script ((character id 27) & "[200~" & "ya en el campo" & (character id 27) & "[201~") in t"#,
                       "The field already highlighted: the paste alone, and Terminal's Return.")
        XCTAssertNil(TerminalAppBridge.fieldAnswerAction(arrows: [.down], text: "  \n\u{1B}\u{03} "), "Nothing to write: nothing goes, and no Return.")
        XCTAssertNil(TerminalAppBridge.fieldAnswerAction(arrows: [.down, .enter], text: "x"), "Arrows only: Terminal adds the one Return.")
        XCTAssertNil(TerminalAppBridge.fieldAnswerAction(arrows: [.tab], text: "x"))
        XCTAssertNil(TerminalAppBridge.fieldAnswerAction(arrows: Array(repeating: .down, count: TerminalAppBridge.answerArrowLimit + 1), text: "x"))
        XCTAssertNotNil(TerminalAppBridge.fieldAnswerAction(arrows: Array(repeating: .down, count: TerminalAppBridge.answerArrowLimit), text: "x"))
    }

    /// AppleScript evaluates the expression here, without Terminal: the bytes are the arrows' CSI form, the marks and the text,
    /// its quotes and backslashes intact.
    func testTheScriptWritesExactlyTheseBytes() throws {
        let text = try XCTUnwrap(TerminalAppBridge.fieldAnswerText(arrows: [.down, .down], text: #"Usa "MongoDB" en C:\datos"#))
        XCTAssertEqual(try TerminalAppBridge.execute("return " + text).stringValue, "\u{1B}[B\u{1B}[B\u{1B}[200~Usa \"MongoDB\" en C:\\datos\u{1B}[201~")
        let action = try XCTUnwrap(TerminalAppBridge.fieldAnswerAction(arrows: [.up], text: "sí"))
        var details: NSDictionary?
        let source = TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: action)
        XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
    }

    /// The field is one answer: its line breaks and tabs go as spaces (a row of their own would read as more of the dialog), and
    /// no control character travels (an Escape would end the paste early; "[201~" left alone is plain text).
    func testTheAnswerIsOneLineWithoutControlCharacters() {
        XCTAssertEqual(TerminalAppBridge.fieldText("  línea 1\n\tlínea 2\u{1B}[201~\u{03}  "), "línea 1 línea 2[201~")
        XCTAssertEqual(TerminalAppBridge.fieldText("uno\r\n\r\ndos\tytres"), "uno dos ytres")
        XCTAssertEqual(TerminalAppBridge.fieldText("\n\n  \u{7F}"), "")
    }

    // MARK: - Reading the field

    func testTheFreeTextOptionIsAFieldInBothShapesClaudeDraws() throws {
        let one = try XCTUnwrap(AgentPrompt.parse(lines(question)))
        XCTAssertEqual(one.options.map(\.input), [.none, .none, .inline, .followUp], "\"Chat about this\" is not the field: it leaves the dialog.")
        XCTAssertFalse(one.multiSelect)
        let several = try XCTUnwrap(AgentPrompt.parse(lines(platforms)))
        XCTAssertTrue(several.multiSelect)
        XCTAssertEqual(several.options[3].title, "Type something", "Without the period, behind its box.")
        XCTAssertEqual(several.options[3].input, .inline)
        XCTAssertEqual(several.options[3].checked, false)
        XCTAssertEqual(several.arrows(to: 3), [.down, .down, .down])
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(onTheField))).arrows(to: 2), [])
    }

    func testTheFieldShowsTheAnswerWholeOrWrappedButNeverAsItsPlaceholder() throws {
        let typed = try XCTUnwrap(AgentPrompt.parse(lines(written("Usa MongoDB con réplica"))))
        XCTAssertTrue(typed.field(2, shows: "Usa MongoDB con réplica"))
        XCTAssertTrue(typed.field(2, shows: "Usa  MongoDB\ncon réplica"), "Compared without whitespace.")
        XCTAssertFalse(typed.field(2, shows: "Usa MongoDB"), "A short answer must be all the field holds.")
        XCTAssertFalse(typed.field(1, shows: "Usa MongoDB con réplica"))
        let long = "Prefiero PostgreSQL gestionado con una réplica de lectura en otra zona, siempre que el costo no pase de 50 dólares"
        let wrapped = question.map { $0 == "❯ 1. PostgreSQL" ? "  1. PostgreSQL" : $0 }.flatMap {
            $0 == "  3. Type something." ? ["❯ 3. Prefiero PostgreSQL gestionado con una réplica de lectura en otra zona,", "     siempre que el costo no pase de 50 dólares"] : [$0]
        }
        XCTAssertTrue(try XCTUnwrap(AgentPrompt.parse(lines(wrapped))).field(2, shows: long), "Its wrapped rows read as the option's own.")
        let placeholder = try XCTUnwrap(AgentPrompt.parse(lines(question)))
        XCTAssertFalse(placeholder.field(2, shows: "Type"), "The placeholder starts like the answer: not the answer.")
        // And the screen check never takes a dialog that reads as before for an answer, even one equal to the placeholder.
        XCTAssertEqual(TerminalAppBridge.fieldState(lines(question), agent: .claude, option: 2, text: "Type something.", expected: placeholder), .untouched)
        XCTAssertEqual(TerminalAppBridge.fieldState(lines(written("Usa MongoDB")), agent: .claude, option: 2, text: "Usa MongoDB", expected: placeholder),
                       .holding(checked: nil))
        XCTAssertEqual(TerminalAppBridge.fieldState(answered("Usa MongoDB"), agent: .claude, option: 2, text: "Usa MongoDB", expected: placeholder), .gone)
    }

    // MARK: - The delivery, any transport

    /// A clock for `answerField` that moves only when it pauses between readings.
    private final class VirtualClock {
        private let start = Date(timeIntervalSinceReferenceDate: 0)
        private(set) var elapsed: TimeInterval = 0
        func now() -> Date { start.addingTimeInterval(elapsed) }
        func pause(_ seconds: TimeInterval) { elapsed += seconds }
    }

    /// A screen that follows the steps written so far, and the steps, from any thread.
    private final class Stage {
        private let lock = NSLock()
        private var _steps: [TerminalAppBridge.FieldStep] = []
        private var _reads = 0
        private let screen: ([TerminalAppBridge.FieldStep]) -> String?
        init(_ screen: @escaping ([TerminalAppBridge.FieldStep]) -> String?) { self.screen = screen }
        var steps: [TerminalAppBridge.FieldStep] { lock.lock(); defer { lock.unlock() }; return _steps }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        func send(_ step: TerminalAppBridge.FieldStep) { lock.lock(); _steps.append(step); lock.unlock() }
        func read() -> String? {
            lock.lock(); let steps = _steps; _reads += 1; lock.unlock()
            return screen(steps)
        }
    }

    private func signature(_ rows: [String]) throws -> String { try XCTUnwrap(AgentPrompt.parse(lines(rows))).signature }

    func testATerminalTabsAnswerGoesInOneWriteAndTheDialogTakingItEndsIt() throws {
        let answer = "Usa MongoDB con réplica"
        let stage = Stage { $0.isEmpty ? self.lines(self.question) : self.answered(answer) }
        var trace: [String] = []
        try TerminalAppBridge.answerField(answer, option: 2, expecting: signature(question), agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: answer)], "Terminal's own Return confirms it: no Enter of Nook's.")
        XCTAssertEqual(trace.first, "campo «Type something.» (opción 3), resaltada la 1")
        XCTAssertEqual(trace.dropFirst().first, "↓↓ y texto pegado con su Enter (24 bytes)")
        XCTAssertEqual(trace.last, "Claude registró la respuesta: enviado")
    }

    func testTheArrowsAreCountedFromTheReadingRightBefore() throws {
        // The card was drawn with the highlight on the first option; the screen now has it on the field already.
        let stage = Stage { $0.isEmpty ? self.lines(self.onTheField) : self.answered("sí") }
        try TerminalAppBridge.answerField("sí", option: 2, expecting: signature(question), agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read)
        XCTAssertEqual(stage.steps, [.answer(arrows: [], text: "sí")])
    }

    func testAChangedDialogOrAnotherOptionGetsNothing() throws {
        let expected = try signature(question)
        let other = Stage { _ in self.lines(self.platforms) }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("x", option: 2, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: other.send, read: other.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .changed) }
        let gone = Stage { _ in self.answered("PostgreSQL") }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("x", option: 2, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: gone.send, read: gone.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .changed) }
        let notAField = Stage { _ in self.lines(self.question) }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("x", option: 1, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: notAField.send, read: notAField.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .changed) }
        let unread = Stage { _ in nil }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("x", option: 2, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: unread.send, read: unread.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unread) }
        let empty = Stage { _ in self.lines(self.question) }
        XCTAssertThrowsError(try TerminalAppBridge.answerField(" \n\u{1B} ", option: 2, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: empty.send, read: empty.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .empty) }
        for stage in [other, gone, notAField, unread, empty] { XCTAssertEqual(stage.steps, [], "Nothing written.") }
    }

    /// The text never showed and the dialog stayed as it was: no Enter, which on the empty field would cancel Claude's question.
    func testAnAnswerThatNeverShowsGetsNoEnter() throws {
        let stage = Stage { _ in self.lines(self.question) }
        var trace: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: signature(question), agent: .claude, withReturn: true,
                                                               timing: quiet, send: stage.send, read: stage.read, trace: { trace.append($0) })) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unseen)
        }
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB")])
        XCTAssertTrue(trace.last?.contains("el Return de Terminal fue con el texto, Nook no añade otro") == true, "Terminal's Return went with the write: \(trace.last ?? "")")
    }

    /// The answer an exact copy of the placeholder: the dialog reads as before, so it never counts as written, and gets no Enter.
    func testAnAnswerThatReadsLikeThePlaceholderIsNeverConfirmedBlind() throws {
        let stage = Stage { _ in self.lines(self.question) }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("Type something.", option: 2, expecting: signature(question), agent: .claude, withReturn: true,
                                                               timing: quiet, send: stage.send, read: stage.read)) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unseen)
        }
        XCTAssertFalse(stage.steps.contains(.enter))
    }

    /// Claude drops the Return of a paste it reads images from (`ClaudeImagePaste`): the field keeps the answer, and one Enter of
    /// Nook's sends it, once the field has held it for `hold`.
    func testAFieldThatKeepsTheAnswerGetsOneEnter() throws {
        let answer = "Usa MongoDB con réplica"
        let stage = Stage { steps in
            steps.isEmpty ? self.lines(self.question) : steps.contains(.enter) ? self.answered(answer) : self.lines(self.written(answer))
        }
        var trace: [String] = []
        try TerminalAppBridge.answerField(answer, option: 2, expecting: signature(question), agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: answer), .enter])
        XCTAssertTrue(trace.contains("la respuesta en el campo"), trace.joined(separator: " | "))
        XCTAssertFalse(trace.joined().contains(answer), "The answer's words stay out of the log.")
        XCTAssertTrue(trace.contains("Enter (el del pegado no llegó)"))
        XCTAssertEqual(trace.last, "Claude registró la respuesta: enviado")
    }

    func testAnAnswerStillInTheFieldAfterTheEnterIsNotSent() throws {
        let stage = Stage { $0.isEmpty ? self.lines(self.question) : self.lines(self.written("Usa MongoDB")) }
        XCTAssertThrowsError(try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: signature(question), agent: .claude, withReturn: true,
                                                               timing: timing, send: stage.send, read: stage.read)) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .stuck)
        }
        XCTAssertEqual(stage.steps.filter { $0 == .enter }.count, 1, "One Enter, never a second.")
    }

    /// A Nook session's tmux writes no Return with the paste: Nook's Enter goes as soon as the field shows the answer.
    func testWithoutItsOwnReturnTheEnterFollowsTheText() throws {
        let stage = Stage { steps in
            steps.isEmpty ? self.lines(self.question) : steps.contains(.enter) ? self.answered("Usa MongoDB") : self.lines(self.written("Usa MongoDB"))
        }
        // A virtual clock: when the Enter went is measured in pauses between readings, not in wall time under load.
        let clock = VirtualClock()
        var enteredAt: TimeInterval?
        try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: signature(question), agent: .claude, withReturn: false,
                                          timing: .init(poll: 0.01, echo: 2, hold: 1.5, settle: 0.5),
                                          send: { step in if step == .enter { enteredAt = clock.elapsed }; stage.send(step) }, read: stage.read,
                                          now: clock.now, pause: clock.pause)
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB"), .enter])
        XCTAssertLessThan(try XCTUnwrap(enteredAt), 0.05, "No hold to wait out: no Return was on its way, the Enter follows the first reading.")
    }

    /// Several answers: Terminal's Return in the same write toggles the box the text just ticked (Claude 2.1.295: typing into the
    /// field ticks it, Enter toggles it), so the box shows empty with the answer, and one Enter ticks it again.
    func testInAQuestionWithSeveralAnswersTheBoxEndsTicked() throws {
        let answer = "Linux ARM también"
        let stage = Stage { steps in
            steps.isEmpty ? self.lines(self.platforms) : self.lines(self.platforms(answer: answer, ticked: steps.contains(.enter)))
        }
        var trace: [String] = []
        try TerminalAppBridge.answerField(answer, option: 3, expecting: signature(platforms), agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down, .down], text: answer), .enter])
        XCTAssertEqual(trace.last, "casilla marcada con la respuesta: enviado")
        // Ticked by the text itself (a tmux paste, no Return): nothing more.
        let ticked = Stage { $0.isEmpty ? self.lines(self.platforms) : self.lines(self.platforms(answer: answer, ticked: true)) }
        try TerminalAppBridge.answerField(answer, option: 3, expecting: signature(platforms), agent: .claude, withReturn: false, timing: timing,
                                          send: ticked.send, read: ticked.read)
        XCTAssertEqual(ticked.steps, [.answer(arrows: [.down, .down, .down], text: answer)], "No Enter: it would untick it.")
    }

    // MARK: - From the card and the composer (AppModel)

    private func tab(_ text: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
    }

    /// A model whose Terminal tab shows `screen` and answers through recorders: the scripts it runs, the keys it would post, its
    /// journal, and a screen that changes to `after` once a script wrote the answer. Accessibility is on, so nothing but the
    /// design keeps key events out.
    private final class Rig {
        let model = AppModel(receivesSignals: false)
        let session: TerminalSession
        private let lock = NSLock()
        private var _scripts: [String] = [], _keys: [TerminalKey] = [], _journal: [String] = []
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
        var keys: [TerminalKey] { lock.lock(); defer { lock.unlock() }; return _keys }
        var journal: [String] { lock.lock(); defer { lock.unlock() }; return _journal }

        init(_ test: DialogFieldAnswerTests, screen: [String], after: @escaping (String) -> String) {
            session = TerminalSession(tab: test.tab(test.lines(screen)), backend: .bundled, bridge: model.terminalBridge)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = test.timing
            bridge.runScript = { [unowned self] script in self.lock.lock(); self._scripts.append(script); self.lock.unlock() }
            bridge.postKey = { [unowned self] key, _ in self.lock.lock(); self._keys.append(key); self.lock.unlock() }
            bridge.fieldJournal = { [unowned self] entry in self.lock.lock(); self._journal.append(entry); self.lock.unlock() }
            let before = test.lines(screen)
            bridge.screenReader = { [unowned self] _, _ in
                let written = self.scripts.first { $0.contains("[200~") }
                return written.map(after) ?? before
            }
            model.sessions = [session]; model.selectedID = session.id
        }
    }

    private func answer(_ rig: Rig, option: Int, text: String) throws -> KeyDelivery? {
        let done = expectation(description: "answered")
        var delivery: KeyDelivery?
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: option, text: text, on: rig.session) { delivery = $0; done.fulfill() }
        XCTAssertTrue(rig.session.answering, "The card stays quiet while the answer goes.")
        XCTAssertTrue(rig.session.sending, "And the composer waits for it, as for a message.")
        // A second send meanwhile is refused with nothing written.
        let second = expectation(description: "second")
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: option, text: text, on: rig.session) { XCTAssertEqual($0, .failed); second.fulfill() }
        XCTAssertEqual(rig.model.notice, "Todavía se está enviando un mensaje a la terminal; espera a que llegue y vuelve a enviar tu respuesta.")
        rig.model.notice = nil
        wait(for: [done, second], timeout: 5)
        XCTAssertFalse(rig.session.sending)
        return delivery
    }

    private func assertNothingComesForward(_ scripts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for script in scripts {
            for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] {
                XCTAssertFalse(script.contains(word), "«\(word)» in \(script)", file: file, line: line)
            }
        }
    }

    func testAnsweringTheFieldFromATerminalTabIsOneWriteWithNoKeyEventAndNothingForward() throws {
        let rig = Rig(self, screen: question) { _ in self.answered("Usa MongoDB con réplica") }
        XCTAssertEqual(try answer(rig, option: 2, text: "Usa MongoDB con réplica"), .sent)
        XCTAssertEqual(rig.keys, [], "No key event, though Accessibility is on.")
        XCTAssertEqual(rig.scripts.count, 1, "Arrows, text and Terminal's Return in one script.")
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B" & (character id 27) & "[B" & (character id 27) & "[200~" & "Usa MongoDB con réplica" & (character id 27) & "[201~") in t"#), script)
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys091" then"#), "Addressed to the tab by its TTY.")
        assertNothingComesForward(rig.scripts)
        XCTAssertNil(rig.model.notice)
        XCTAssertEqual(rig.journal.count, 1, "The steps are in the delivery log.")
        XCTAssertTrue(rig.journal[0].hasPrefix("Claude · respuesta en el campo de la pregunta (23 caracteres)"), rig.journal[0])
        XCTAssertFalse(rig.journal[0].contains("MongoDB"), "The answer's words stay out of the log: \(rig.journal[0])")
        XCTAssertTrue(rig.journal[0].contains("↓↓ y texto pegado con su Enter"), rig.journal[0])
        XCTAssertTrue(rig.journal[0].contains("Claude registró la respuesta: enviado"), rig.journal[0])
    }

    func testAChangedQuestionGetsNothingFromTheModel() throws {
        let rig = Rig(self, screen: question) { _ in self.answered("x") }
        let card = try XCTUnwrap(rig.session.prompt)
        rig.session.update(tab(lines(platforms)))
        let refused = expectation(description: "refused")
        rig.model.answer(card, option: 2, text: "Usa MongoDB", on: rig.session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(rig.scripts.count + rig.keys.count, 0)
        XCTAssertFalse(rig.session.answering)
        XCTAssertTrue(rig.model.notice?.contains("La pregunta cambió") == true)
    }

    /// The screen read right before writing no longer shows the dialog (Claude moved on between two readings): nothing is written.
    func testTheReadingRightBeforeWritingHasTheLastWord() throws {
        let rig = Rig(self, screen: question) { _ in self.answered("x") }
        rig.model.terminalBridge.screenReader = { _, _ in self.answered("PostgreSQL") }
        XCTAssertEqual(try answer(rig, option: 2, text: "Usa MongoDB"), .failed)
        XCTAssertEqual(rig.scripts.count + rig.keys.count, 0)
        XCTAssertTrue(rig.model.notice?.contains("La pregunta cambió") == true)
        XCTAssertFalse(rig.session.answering, "It can be tried again at once.")
    }

    func testAnUnseenAnswerSaysSoAndCanBeTriedAgain() throws {
        let rig = Rig(self, screen: question) { _ in self.lines(self.question) }
        rig.model.terminalBridge.fieldTiming = quiet
        XCTAssertEqual(try answer(rig, option: 2, text: "Usa MongoDB"), .failed)
        XCTAssertEqual(rig.scripts.count, 1, "The answer's write, and no Enter after it.")
        XCTAssertEqual(rig.model.notice, "Tu respuesta no apareció en el campo de Claude y la pregunta sigue abierta. Revisa la terminal antes de enviarla de nuevo.",
                       "Terminal's own Return went with the write: the notice doesn't claim no Enter was pressed.")
        XCTAssertFalse(rig.session.answering)
    }

    /// Choosing the field on the card presses nothing, not even with Accessibility on: it waits for the text. The next message
    /// from the composer is its answer.
    func testChoosingTheFieldOnTheCardPressesNothingAndTheComposersMessageAnswersIt() throws {
        let rig = Rig(self, screen: question) { _ in self.answered("Usa MongoDB") }
        let prompt = try XCTUnwrap(rig.session.prompt)
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 2), "No permission needed: the card says nothing about Accessibility.")
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session), "The highlight is on PostgreSQL: a message is not an answer yet.")
        let chosen = expectation(description: "chosen")
        rig.model.answer(prompt, option: 2, on: rig.session) { XCTAssertEqual($0, .sent); chosen.fulfill() }
        wait(for: [chosen], timeout: 1)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(rig.keys, [], "No arrow posted: Terminal never comes forward.")
        XCTAssertEqual(rig.scripts, [], "Nothing written until the answer exists.")
        XCTAssertFalse(rig.session.answering)
        let target = try XCTUnwrap(rig.model.fieldAnswer(for: rig.session))
        XCTAssertEqual(target.option, 2)
        XCTAssertEqual(target.prompt.signature, prompt.signature)
        // The composer's send.
        let sent = expectation(description: "sent")
        XCTAssertTrue(rig.model.sendToField("Usa MongoDB", on: rig.session) { XCTAssertTrue($0); sent.fulfill() })
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(rig.scripts.count, 1)
        XCTAssertTrue(rig.scripts[0].contains(#"(character id 27) & "[B" & (character id 27) & "[B" & (character id 27) & "[200~" & "Usa MongoDB""#), rig.scripts[0])
        XCTAssertEqual(rig.keys, [])
        XCTAssertNil(rig.session.chosenField, "Answered: the field is no target any more.")
    }

    /// The user moved to the field at the terminal: what Nook's composer sends is its answer, with no arrows.
    func testAHighlightedFieldTakesTheComposersMessage() throws {
        let rig = Rig(self, screen: onTheField) { _ in self.answered("sí, la réplica") }
        let target = try XCTUnwrap(rig.model.fieldAnswer(for: rig.session))
        XCTAssertEqual(target.option, 2)
        let sent = expectation(description: "sent")
        XCTAssertTrue(rig.model.sendToField("sí, la réplica", on: rig.session) { XCTAssertTrue($0); sent.fulfill() })
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(rig.scripts.count, 1)
        XCTAssertTrue(rig.scripts[0].contains(#"do script ((character id 27) & "[200~" & "sí, la réplica" & (character id 27) & "[201~") in t"#), rig.scripts[0])
    }

    func testWithoutAFieldTheComposersMessageGoesTheUsualWay() throws {
        let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                          " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                          "   3. No, and tell Claude what to do differently (esc)"]
        let rig = Rig(self, screen: permission) { _ in "" }
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
        XCTAssertFalse(rig.model.sendToField("hola", on: rig.session) { _ in XCTFail("Never called when it doesn't apply") })
        // The field chosen on another dialog's card doesn't follow it here.
        let other = Rig(self, screen: question) { _ in "" }
        let chosen = expectation(description: "chosen")
        other.model.answer(try XCTUnwrap(other.session.prompt), option: 2, on: other.session) { _ in chosen.fulfill() }
        wait(for: [chosen], timeout: 1)
        XCTAssertNotNil(other.model.fieldAnswer(for: other.session))
        other.session.update(tab(lines(permission)))
        XCTAssertNil(other.model.fieldAnswer(for: other.session))
        XCTAssertNil(other.session.chosenField)
        XCTAssertEqual(rig.scripts + other.scripts, [])
    }

    /// The chosen field is published: the pane follows every change (chosen, forgotten), and nothing more.
    func testTheChosenFieldIsPublished() throws {
        let rig = Rig(self, screen: question) { _ in "" }
        var seen: [Int?] = []
        let watch = rig.session.$chosenField.sink { seen.append($0?.option) }
        defer { watch.cancel() }
        rig.session.chooseField(2, of: try XCTUnwrap(rig.session.prompt))
        rig.session.forgetChosenField()
        rig.session.forgetChosenField()
        XCTAssertEqual(seen, [nil, 2, nil], "Forgetting a field that isn't there publishes nothing.")
    }

    /// The model forgets the chosen field once the screen has shown no dialog for `chosenFieldGrace`, so an identical question
    /// asked later doesn't find it chosen; a single reading without the dialog (a redraw caught midway) keeps it.
    func testAChosenFieldOutlivesAFlakyReadingButNotTheDialog() throws {
        let rig = Rig(self, screen: question) { _ in "" }
        let session = rig.session
        session.chosenFieldGrace = 0.6
        let chosen = expectation(description: "chosen")
        rig.model.answer(try XCTUnwrap(session.prompt), option: 2, on: session) { _ in chosen.fulfill() }
        wait(for: [chosen], timeout: 1)
        func pause(_ seconds: Double) {
            let paused = expectation(description: "paused")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { paused.fulfill() }
            wait(for: [paused], timeout: seconds + 1)
        }
        session.update(tab(answered("x")))
        pause(0.2)
        XCTAssertNotNil(session.chosenField, "No dialog for a moment: still chosen.")
        session.update(tab(lines(question)))
        XCTAssertNotNil(session.chosenField, "The dialog came back within the grace: a redraw, and the wait starts over.")
        pause(0.2)
        session.update(tab(answered("y")))
        XCTAssertNotNil(session.chosenField)
        pause(0.2)
        session.update(tab(answered("z")))
        XCTAssertNotNil(session.chosenField, "0.2 s without it: not yet.")
        pause(0.5)
        session.update(tab(answered("w")))
        XCTAssertNil(session.chosenField, "Gone for longer than the grace: forgotten.")
        // The same question asked again finds no field chosen: a message is a message until the field is chosen anew.
        session.update(tab(lines(question)))
        XCTAssertNil(rig.model.fieldAnswer(for: session))
    }

    /// A screen that stays still once the dialog went is read once (an unchanged screen isn't parsed again): the same question
    /// asked after the grace still finds its field forgotten.
    func testTheSameQuestionAskedAgainAfterAStillScreenIsNotChosen() throws {
        let rig = Rig(self, screen: question) { _ in "" }
        let session = rig.session
        session.chosenFieldGrace = 0.2
        session.chooseField(2, of: try XCTUnwrap(session.prompt))
        session.update(tab(answered("x")))
        let paused = expectation(description: "paused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { paused.fulfill() }
        wait(for: [paused], timeout: 2)
        XCTAssertNotNil(session.chosenField, "No reading came meanwhile.")
        session.update(tab(lines(question)))
        XCTAssertNil(session.chosenField)
        XCTAssertNil(rig.model.fieldAnswer(for: session))
    }

    func testAnEmptyAnswerIsRefusedWithNothingWritten() throws {
        let rig = Rig(self, screen: onTheField) { _ in self.answered("x") }
        let refused = expectation(description: "refused")
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: 2, text: " \n ", on: rig.session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(rig.scripts, [], "Enter on the empty field would cancel Claude's question.")
        XCTAssertFalse(rig.session.answering)
    }

    // MARK: - A Nook session (tmux)

    @MainActor
    func testANookSessionAnswersThroughTmuxWithItsEnterOnceTheFieldShowsTheText() throws {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-field-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-field-" + UUID().uuidString.prefix(6), name: "Claude", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        defer { session.disconnectClients() }
        session.applyPane(tty: "/dev/ttys092", processes: ["claude"], text: lines(question))
        session.isRunning = true
        XCTAssertNotNil(session.prompt)
        let model = AppModel(receivesSignals: false)
        model.sessions = [session]; model.selectedID = session.id
        let lock = NSLock()
        var steps: [TerminalAppBridge.FieldStep] = [], journal: [String] = []
        session.paneField = { step in lock.lock(); steps.append(step); lock.unlock() }
        session.paneScreen = { [self] in
            lock.lock(); defer { lock.unlock() }
            return steps.isEmpty ? lines(question) : steps.contains(.enter) ? answered("Usa MongoDB") : lines(written("Usa MongoDB"))
        }
        session.paneTiming = timing
        session.paneJournal = { entry in lock.lock(); journal.append(entry); lock.unlock() }
        let done = expectation(description: "answered")
        model.answer(try XCTUnwrap(session.prompt), option: 2, text: "Usa MongoDB", on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        wait(for: [done], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB"), .enter], "tmux presses the arrows and pastes; Enter once the field shows it.")
        XCTAssertEqual(journal.count, 1)
        XCTAssertTrue(journal[0].contains("(sesión de Nook) · respuesta en el campo de la pregunta"), journal[0])
        XCTAssertNil(model.notice)
    }
}

// MARK: - Sent only with Claude's record of this answer (security review and QA, 9/10)

extension DialogFieldAnswerTests {
    /// Claude's record of a cancelled question (Claude Code 2.1.295): what Enter on the empty field leaves.
    private var declined: String {
        lines(["⏺ Antes de seguir necesito una decisión.", "", "⏺ User declined to answer questions", "  ⎿  · Which database should we use? (PostgreSQL / SQLite)", "",
               rule, "❯ ", rule, footer])
    }
    /// The question gone and no record of any answer on screen.
    private var unrecorded: String {
        lines(["⏺ Antes de seguir necesito una decisión.", "", "✻ Pondering… (2s · esc to interrupt)", "", rule, "❯ ", rule, footer])
    }

    func testClaudesRecordsAreCountedFromTheScreen() {
        let records = TerminalAppBridge.FieldRecords(answered("Usa MongoDB con réplica"), agent: .claude, text: "Usa MongoDB con réplica")
        XCTAssertEqual(records.answer, 1); XCTAssertEqual(records.answered, 1); XCTAssertEqual(records.declined, 0)
        let wrapped = answered("Usa MongoDB con réplica").replacingOccurrences(of: "→ Usa MongoDB", with: "→ Usa\n     MongoDB")
        XCTAssertEqual(TerminalAppBridge.FieldRecords(wrapped, agent: .claude, text: "Usa MongoDB con réplica").answer, 1, "Wrapped rows join.")
        XCTAssertEqual(TerminalAppBridge.FieldRecords(declined, agent: .claude, text: "x").declined, 1)
        XCTAssertEqual(TerminalAppBridge.FieldRecords(answered("PostgreSQL"), agent: .claude, text: "Usa MongoDB").answer, 0)
    }

    private func outcome(after screen: @escaping ([TerminalAppBridge.FieldStep]) -> String, text: String = "Usa MongoDB", rows: [String]? = nil,
                         option: Int = 2) throws -> (TerminalAppBridge.FieldAnswerError?, Stage, [String]) {
        let rows = rows ?? question
        let stage = Stage { $0.isEmpty ? self.lines(rows) : screen($0) }
        var trace: [String] = []
        do {
            try TerminalAppBridge.answerField(text, option: option, expecting: signature(rows), agent: .claude, withReturn: true, timing: quiet,
                                              send: stage.send, read: stage.read, trace: { trace.append($0) })
            return (nil, stage, trace)
        } catch let error as TerminalAppBridge.FieldAnswerError {
            return (error, stage, trace)
        }
    }

    /// The paste didn't land, and Terminal's Return reached the empty field: Claude cancelled the question. Not sent.
    func testAQuestionClosedWithoutTheAnswerIsNotSent() throws {
        let (error, stage, trace) = try outcome(after: { _ in self.declined })
        XCTAssertEqual(error, .declined)
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB")], "No Enter of Nook's.")
        XCTAssertTrue(trace.last?.contains("sin respuesta") == true, trace.last ?? "")
    }

    /// Without its own Return (tmux), an answer that never showed got no Enter at all, and the log says so.
    func testAnUnseenAnswerWithoutItsReturnSaysNoEnterWent() throws {
        let stage = Stage { _ in self.lines(self.question) }
        var trace: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: signature(question), agent: .claude, withReturn: false,
                                                               timing: quiet, send: stage.send, read: stage.read, trace: { trace.append($0) })) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unseen)
        }
        XCTAssertTrue(trace.last?.contains("sin Enter") == true, trace.last ?? "")
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB")])
    }

    /// The highlight moved between the reading and the write: the Return chose another option.
    func testAQuestionAnsweredWithAnotherOptionIsNotSent() throws {
        let (error, stage, _) = try outcome(after: { _ in self.answered("PostgreSQL") })
        XCTAssertEqual(error, .otherAnswer)
        XCTAssertFalse(stage.steps.contains(.enter))
    }

    /// The dialog went and nothing says what Claude did with it: not reported as sent.
    func testAQuestionGoneWithoutAnyRecordIsUnconfirmed() throws {
        let (error, stage, trace) = try outcome(after: { _ in self.unrecorded })
        XCTAssertEqual(error, .unconfirmed)
        XCTAssertFalse(stage.steps.contains(.enter))
        XCTAssertTrue(trace.last?.contains("sin que Claude registrara la respuesta") == true, trace.last ?? "")
    }

    /// A slow Claude: a reading or two without the dialog and without its record yet, then the record. Sent.
    /// Run on a virtual clock that moves only by the pauses between readings: what it proves doesn't depend on how loaded the
    /// machine is (it once failed under load on the wall clock, with six readings due in a quarter of a second).
    func testASlowRecordStillCounts() throws {
        // The record shows on the sixth reading after the question went: within the wait, sent.
        let late = try slowRecord(showsAfter: 5, timing: quiet)
        XCTAssertNil(late.error)
        XCTAssertEqual(late.trace.last, "Claude registró la respuesta: enviado")
        // One that would only show after the whole wait is not waited for: not sent.
        let tooLate = try slowRecord(showsAfter: Int(quiet.echo / quiet.poll) + 10, timing: quiet)
        XCTAssertEqual(tooLate.error, .unconfirmed)
    }

    /// The answer written, then `showsAfter` readings without the question and without its record, then the record; on a clock
    /// that advances only by `timing.poll` per reading.
    private func slowRecord(showsAfter count: Int, timing: TerminalAppBridge.DeliveryTiming) throws -> (error: TerminalAppBridge.FieldAnswerError?, trace: [String]) {
        var readings = 0, trace: [String] = []
        let clock = VirtualClock()
        let stage = Stage { steps in
            guard !steps.isEmpty else { return self.lines(self.question) }
            readings += 1
            return readings <= count ? self.unrecorded : self.answered("Usa MongoDB")
        }
        do {
            try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: signature(question), agent: .claude, withReturn: true, timing: timing,
                                              send: stage.send, read: stage.read, trace: { trace.append($0) }, now: clock.now, pause: clock.pause)
            return (nil, trace)
        } catch let error as TerminalAppBridge.FieldAnswerError {
            return (error, trace)
        }
    }

    /// A new question whose option 3 happens to read like the answer is no field holding it: no Enter of Nook's goes to it.
    func testAnotherQuestionWhoseOptionReadsLikeTheAnswerGetsNoEnter() throws {
        let other = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Cache", "", "Which cache should we use?", "",
                     "  1. Redis", "  2. Memcached", "❯ 3. Usa MongoDB", String(repeating: "─", count: 60), "  4. Chat about this", "",
                     "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        XCTAssertEqual(TerminalAppBridge.fieldState(lines(other), agent: .claude, option: 2, text: "Usa MongoDB", expected: try XCTUnwrap(AgentPrompt.parse(lines(question)))),
                       .gone)
        let (error, stage, _) = try outcome(after: { _ in self.lines(other) })
        XCTAssertEqual(error, .unconfirmed)
        XCTAssertEqual(stage.steps.filter { $0 == .enter }.count, 0)
    }

    // MARK: Dialogs with tabs

    /// Re-answering a question already answered: its tab was ticked before, so only the review step's "→ answer" says it took it.
    private var answeredFirstTab: [String] {
        [" ←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Which database should we use?", "",
         "❯ 1. PostgreSQL", "  2. SQLite", "  3. Type something.", "  ", "  4. Chat about this", "",
         "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
    }

    func testTheReviewStepShowingTheAnswerIsSent() throws {
        let review = [String(repeating: "─", count: 60), "←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Review your answers", "",
                      "⚠ You have not answered all questions", "", "│ ● Which database should we use?", "  → Usa MongoDB", "",
                      "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        XCTAssertEqual(try XCTUnwrap(TerminalAppBridge.prompt(onScreen: lines(review), agent: .claude)).review.first?.answer, "Usa MongoDB", "Fixture: a review step Nook reads.")
        let (error, _, _) = try outcome(after: { _ in self.lines(review) }, rows: answeredFirstTab)
        XCTAssertNil(error)
    }

    func testTheNextTabWithNoMoreTabsAnsweredIsUnconfirmed() throws {
        let next = [" ←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Which cache should we put in front of it?", "",
                    "❯ 1. Redis", "  2. Memcached", "  3. Type something.", "  ", "  4. Chat about this", "",
                    "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
        let (error, _, _) = try outcome(after: { _ in self.lines(next) }, rows: answeredFirstTab)
        XCTAssertEqual(error, .unconfirmed, "Moving on proves nothing when that tab was already answered.")
    }

    func testTabsCutDifferentlyAreTheSameTabs() {
        let a = [AgentPrompt.Tab(title: "Infraestructura", answered: false, isSubmit: false), AgentPrompt.Tab(title: "Submit", answered: false, isSubmit: true)]
        let b = [AgentPrompt.Tab(title: "Infraestruc…", answered: true, isSubmit: false), AgentPrompt.Tab(title: "Submit", answered: false, isSubmit: true)]
        XCTAssertTrue(TerminalAppBridge.sameTabs(a, b))
        XCTAssertFalse(TerminalAppBridge.sameTabs(a, [b[1], b[0]]))
        XCTAssertFalse(TerminalAppBridge.sameTabs(a, Array(b.prefix(1))))
    }

    // MARK: The model's notices

    func testTheModelSaysWhatClaudeDidWhenTheAnswerDidntGo() throws {
        let rig = Rig(self, screen: question) { _ in self.declined }
        rig.model.terminalBridge.fieldTiming = quiet
        XCTAssertEqual(try answer(rig, option: 2, text: "Usa MongoDB"), .failed)
        XCTAssertEqual(rig.scripts.count, 1)
        XCTAssertEqual(rig.model.notice, "Claude cerró la pregunta sin tu respuesta (la dio por no respondida). Tu texto vuelve a la caja; revisa la terminal.")
        let other = Rig(self, screen: question) { _ in self.answered("PostgreSQL") }
        other.model.terminalBridge.fieldTiming = quiet
        XCTAssertEqual(try answer(other, option: 2, text: "Usa MongoDB"), .failed)
        XCTAssertEqual(other.model.notice, "Claude respondió la pregunta con otra opción, no con tu texto. Tu texto vuelve a la caja; revisa la terminal.")
        let silent = Rig(self, screen: question) { _ in self.unrecorded }
        silent.model.terminalBridge.fieldTiming = quiet
        XCTAssertEqual(try answer(silent, option: 2, text: "Usa MongoDB"), .failed)
        XCTAssertTrue(silent.model.notice?.hasPrefix("La pregunta se cerró, pero Claude no muestra tu respuesta") == true, silent.model.notice ?? "")
        XCTAssertTrue(silent.journal[0].contains("no enviado"), silent.journal[0])
    }

    func testAnAnswerWhileAMessageIsOnItsWaySaysSo() throws {
        let rig = Rig(self, screen: onTheField) { _ in self.answered("x") }
        rig.session.sending = true
        let refused = expectation(description: "refused")
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: 2, text: "Usa MongoDB", on: rig.session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(rig.scripts, [])
        XCTAssertEqual(rig.model.notice, "Todavía se está enviando un mensaje a la terminal; espera a que llegue y vuelve a enviar tu respuesta.")
        XCTAssertFalse(rig.session.answering)
    }

    // MARK: A field already filled (several answers)

    /// After a question with several answers took the text, the field keeps it, ticked, with the highlight on it. Pasting again
    /// would add to it, so it is no field to answer any more: the composer isn't its answer box, an answer to it is refused, and
    /// a click on it on the card toggles its box (arrows and Enter in one write), as Enter does there.
    func testAFilledFieldIsNoTargetAndAClickTogglesItsBox() throws {
        let text = "Otro proveedor"   // Reads like a free-text option: the row stays a "field" to the parser.
        let rig = Rig(self, screen: platforms) { _ in self.lines(self.platforms(answer: text, ticked: true)) }
        XCTAssertEqual(try answer(rig, option: 3, text: text), .sent)
        rig.session.update(tab(lines(platforms(answer: text, ticked: true))))
        let filled = try XCTUnwrap(rig.session.prompt)
        XCTAssertEqual(filled.options[3].input, .inline, "Fixture: the answer's row still reads as a field.")
        XCTAssertEqual(filled.highlighted, 3)
        XCTAssertTrue(rig.session.isFilledField(3, of: filled))
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session), "The composer is not that field's answer box any more.")
        XCTAssertFalse(rig.model.sendToField("otra cosa", on: rig.session) { _ in XCTFail("Not a field answer") })
        let refused = expectation(description: "refused")
        rig.model.answer(filled, option: 3, text: "otra cosa", on: rig.session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(rig.model.notice, "Ese campo ya tiene tu respuesta y su casilla marcada; para cambiarla, edítala en la terminal.")
        XCTAssertEqual(rig.scripts.count, 1, "Nothing written after the answer.")
        // The card's click: Enter toggles its box, and no field is chosen.
        let toggled = expectation(description: "toggled")
        rig.model.answer(filled, option: 3, on: rig.session) { XCTAssertEqual($0, .sent); toggled.fulfill() }
        wait(for: [toggled], timeout: 3)
        XCTAssertEqual(rig.scripts.count, 2)
        XCTAssertTrue(rig.scripts[1].contains(TerminalAppBridge.returnAction), rig.scripts[1])
        XCTAssertNil(rig.session.chosenField)
        XCTAssertEqual(rig.keys, [])
        // Another dialog: the field is forgotten.
        rig.session.update(tab(lines(question)))
        XCTAssertNil(rig.session.filledField)
    }

    // MARK: The delivery log

    private func journalFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-journal-\(UUID().uuidString)/Logs")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return folder
    }
    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// The log holds the user's own messages and answers: only the user may read it.
    func testTheDeliveryLogIsReadableByTheUserAlone() throws {
        let folder = try journalFolder()
        let log = folder.appendingPathComponent("deliveries.log")
        DeliveryJournal.append("Claude · «hola»", to: log)
        XCTAssertEqual(try mode(log), 0o600)
        XCTAssertEqual(try mode(folder), 0o700, "A folder it creates is the user's alone too.")
        // A log an earlier build left readable by others is brought back to 0600 on the next entry, its text kept.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        DeliveryJournal.append("Claude · «adiós»", to: log)
        XCTAssertEqual(try mode(log), 0o600)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("«hola»") && text.contains("«adiós»"), text)
    }

    func testTheDeliveryLogIsNeverWrittenThroughALink() throws {
        let folder = try journalFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("elsewhere.txt"), log = folder.appendingPathComponent("deliveries.log")
        try "intact".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: target)
        DeliveryJournal.append("Claude · «hola»", to: log)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "intact")
    }

    func testAnAnswerNeverEndsInABackslash() {
        XCTAssertEqual(TerminalAppBridge.fieldText(#"C:\datos\"#), #"C:\datos"#, "Claude would turn it and the Return into a line break.")
        XCTAssertEqual(TerminalAppBridge.fieldText("sí \\\\ "), "sí")
        XCTAssertEqual(TerminalAppBridge.fieldText("\\"), "")
    }
}
