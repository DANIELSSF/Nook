import XCTest
@testable import Nook

/// Notes on an option of Claude's question with a preview ("n to add notes"), written from Nook. What Claude Code 2.1.295 does
/// (its source): "n" opens a text field in the notes row, Enter there closes it and answers the highlighted option once the
/// highlight moved in that question, and the notes go to Claude with the option and its preview. Every transport is a recorder
/// and every screen a fixture (`PreviewQuestionFixtures`): nothing reaches Terminal, a real session or the keyboard.
final class PreviewNotesTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)
    private let quiet = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.25, hold: 0.06, settle: 0.25)
    private let notes = "el logo a la izquierda"

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }
    private func parsed(_ rows: [String]) throws -> AgentPrompt { try XCTUnwrap(AgentPrompt.parse(lines(rows))) }

    // MARK: - The keys and the bytes

    /// Claude answers from the notes field only once the highlight moved in the question: the arrows always move it, and an option
    /// already highlighted is left and come back to.
    func testTheArrowsToAnOptionWithNotesAlwaysMoveTheHighlight() throws {
        let first = try parsed(F.sample())
        XCTAssertEqual(first.notesArrows(to: 0), [.down, .up])
        XCTAssertEqual(first.notesArrows(to: 1), [.down])
        XCTAssertNil(first.notesArrows(to: 2), "\"Chat about this\" takes no notes.")
        XCTAssertNil(first.notesArrows(to: 3))
        let second = try parsed(F.sample(highlight: 2))
        XCTAssertEqual(second.notesArrows(to: 1), [.up, .down])
        XCTAssertEqual(second.notesArrows(to: 0), [.up])
        // From "Chat about this" the first ↑ only returns to the options.
        let chat = try parsed(F.sample(highlight: 3))
        XCTAssertEqual(chat.notesArrows(to: 1), [.up, .up, .down])
        XCTAssertEqual(chat.notesArrows(to: 0), [.up, .up])
        // A question without a preview takes no notes.
        let plain = try parsed(F.nextTab)
        XCTAssertFalse(plain.takesNotes)
        XCTAssertNil(plain.notesArrows(to: 0))
    }

    func testTheAnswerWithNotesIsTheArrowsNThenThePasteInOneScript() throws {
        XCTAssertEqual(TerminalAppBridge.notesAnswerAction(arrows: [.down], notes: notes),
                       #"do script ((character id 27) & "[B" & "n" & (character id 27) & "[200~" & "el logo a la izquierda" & (character id 27) & "[201~") in t"#)
        XCTAssertEqual(TerminalAppBridge.notesAnswerAction(arrows: [.down, .up], notes: "uno\ndos"),
                       #"do script ((character id 27) & "[B" & (character id 27) & "[A" & "n" & (character id 27) & "[200~" & "uno dos" & (character id 27) & "[201~") in t"#,
                       "One line: the field's Enter answers.")
        XCTAssertNil(TerminalAppBridge.notesAnswerAction(arrows: [.down], notes: " \n\u{1B} "), "No notes: nothing goes.")
        XCTAssertNil(TerminalAppBridge.notesAnswerAction(arrows: [.down, .enter], notes: "x"))
        XCTAssertNil(TerminalAppBridge.notesAnswerAction(arrows: Array(repeating: .down, count: TerminalAppBridge.answerArrowLimit + 1), notes: "x"))
    }

    /// AppleScript evaluates the expression here, without Terminal: the arrow, the "n", the marks and the notes, quotes intact.
    func testTheScriptWritesExactlyTheseBytes() throws {
        let text = try XCTUnwrap(TerminalAppBridge.notesAnswerText(arrows: [.down], notes: #"el "logo" a la izquierda"#))
        XCTAssertEqual(try TerminalAppBridge.execute("return " + text).stringValue, "\u{1B}[Bn\u{1B}[200~el \"logo\" a la izquierda\u{1B}[201~")
        let action = try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.up], notes: "sí"))
        var details: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: action))!.compileAndReturnError(&details),
                      details?.description ?? "")
    }

    // MARK: - The delivery, any transport

    /// A screen that follows the steps written so far, and the steps, from any thread.
    private final class Stage {
        private let lock = NSLock()
        private var _steps: [TerminalAppBridge.NotesStep] = []
        private let screen: ([TerminalAppBridge.NotesStep]) -> String?
        init(_ screen: @escaping ([TerminalAppBridge.NotesStep]) -> String?) { self.screen = screen }
        var steps: [TerminalAppBridge.NotesStep] { lock.lock(); defer { lock.unlock() }; return _steps }
        func send(_ step: TerminalAppBridge.NotesStep) { lock.lock(); _steps.append(step); lock.unlock() }
        func read() -> String? {
            lock.lock(); let steps = _steps; lock.unlock()
            return screen(steps)
        }
    }

    func testASingleQuestionTakesTheOptionAndItsNotesInOneWrite() throws {
        let stage = Stage { $0.isEmpty ? self.lines(F.single()) : self.lines(F.answered("Ticket aparte")) }
        var trace: [String] = []
        try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down], notes: notes)], "Terminal's own Return answers: no Enter of Nook's.")
        XCTAssertEqual(trace.first, "opción «Ticket aparte» (2) con notas, resaltada la 1")
        XCTAssertEqual(trace.dropFirst().first, "↓, n y notas pegadas con su Enter (22 bytes)")
        XCTAssertEqual(trace.last, "Claude registró la opción: enviado con sus notas")
    }

    func testWithTabsTheNextTabAnsweredIsTheProof() throws {
        let stage = Stage { $0.isEmpty ? self.lines(F.sample()) : self.lines(F.nextTab) }
        var trace: [String] = []
        try TerminalAppBridge.answerNotes(notes, option: 0, expecting: parsed(F.sample()).signature, agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down, .up], notes: notes)], "Already highlighted: away and back, so Claude answers it.")
        XCTAssertEqual(trace.last, "Claude tomó la opción y siguió: enviado con sus notas")
    }

    /// The notes landed but the dialog stayed (the Return got lost, or the field closed without answering): one Enter answers the
    /// highlighted option, which holds the notes.
    func testNotesThatStayGetOneEnter() throws {
        let stage = Stage { steps in
            steps.isEmpty ? self.lines(F.single()) : steps.contains(.enter) ? self.lines(F.answered("Ticket aparte")) : self.lines(F.single(highlight: 2, notes: self.notes))
        }
        var trace: [String] = []
        try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true, timing: timing,
                                          send: stage.send, read: stage.read, trace: { trace.append($0) })
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down], notes: notes), .enter])
        XCTAssertTrue(trace.contains("Enter (el del pegado no respondió)"), trace.joined(separator: " | "))
        XCTAssertEqual(trace.last, "Claude registró la opción: enviado con sus notas")
    }

    func testNotesThatStayOnAnotherOptionGetNoEnter() throws {
        let stage = Stage { $0.isEmpty ? self.lines(F.single()) : self.lines(F.single(highlight: 1, notes: self.notes)) }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true,
                                                               timing: timing, send: stage.send, read: stage.read)) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .stuck)
        }
        XCTAssertFalse(stage.steps.contains(.enter), "Enter would answer the wrong option.")
    }

    func testNotesThatNeverShowGetNoEnter() throws {
        let stage = Stage { _ in self.lines(F.single()) }
        var trace: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true,
                                                               timing: quiet, send: stage.send, read: stage.read, trace: { trace.append($0) })) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unseen)
        }
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down], notes: notes)])
        XCTAssertTrue(trace.last?.contains("Nook no añade otro") == true, trace.last ?? "")
        // Nor with the field left open and empty.
        let open = Stage { $0.isEmpty ? self.lines(F.single()) : self.lines(F.single(highlight: 2, notes: "Add notes on this design…")) }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true,
                                                               timing: quiet, send: open.send, read: open.read))
        XCTAssertFalse(open.steps.contains(.enter), "Enter on an empty field answers with what the question had, or nothing.")
    }

    func testOtherNotesInTheRowAreStuckWithoutEnter() throws {
        let stage = Stage { $0.isEmpty ? self.lines(F.single()) : self.lines(F.single(highlight: 2, notes: "otra cosa")) }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true,
                                                               timing: quiet, send: stage.send, read: stage.read)) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .stuck)
        }
        XCTAssertFalse(stage.steps.contains(.enter))
    }

    /// Nothing goes unless the reading right before shows the same question with its notes field closed and empty. The field open
    /// (empty, or with text and the hint naming the editor) says so apart: the user has to close it in the terminal.
    func testAChangedQuestionOrNotesAlreadyThereGetNothing() throws {
        let expected = try parsed(F.single()).signature
        let cases: [([String], Int, TerminalAppBridge.FieldAnswerError)] = [
            (F.single(notes: "a medias"), 1, .changed), (F.single(notes: "Add notes on this design…"), 1, .notesFieldOpen),
            (F.single(notes: "Add notes on this design…", focused: true), 1, .notesFieldOpen), (F.single(notes: "a medias", focused: true), 1, .notesFieldOpen),
            (F.single(notes: "a medias", focused: true), 0, .notesFieldOpen), (F.nextTab, 0, .changed), (F.answered("x"), 1, .changed), (F.single(), 2, .changed)]
        for (before, option, error) in cases {
            let stage = Stage { _ in self.lines(before) }
            XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: option, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                                   send: stage.send, read: stage.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, error) }
            XCTAssertEqual(stage.steps, [], "Nothing written.")
        }
        let empty = Stage { _ in self.lines(F.single()) }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(" \n ", option: 1, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: empty.send, read: empty.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .empty) }
        let unread = Stage { _ in nil }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: expected, agent: .claude, withReturn: true, timing: timing,
                                                               send: unread.send, read: unread.read)) { XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .unread) }
    }

    /// Claude recorded another answer ("(notes only)": the Return reached a field whose question never moved): not sent.
    func testAnotherAnswerRecordedIsNotSent() throws {
        let stage = Stage { $0.isEmpty ? self.lines(F.single()) : self.lines(F.answered("(notes only)")) }
        XCTAssertThrowsError(try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: true,
                                                               timing: timing, send: stage.send, read: stage.read)) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .otherAnswer)
        }
    }

    /// A Nook session's tmux writes no Return: Nook's Enter goes as soon as the notes show.
    func testWithoutItsOwnReturnTheEnterFollowsTheNotes() throws {
        let stage = Stage { steps in
            steps.isEmpty ? self.lines(F.single()) : steps.contains(.enter) ? self.lines(F.answered("Ticket aparte")) : self.lines(F.single(highlight: 2, notes: self.notes))
        }
        try TerminalAppBridge.answerNotes(notes, option: 1, expecting: parsed(F.single()).signature, agent: .claude, withReturn: false,
                                          timing: .init(poll: 0.01, echo: 2, hold: 1.5, settle: 0.5), send: stage.send, read: stage.read)
        XCTAssertEqual(stage.steps, [.answer(arrows: [.down], notes: notes), .enter])
    }

    // MARK: - From the card (AppModel)

    /// A model whose Terminal tab shows `screen` and answers through recorders: the scripts it runs, the keys it would post, its
    /// journal, and a screen that turns into `after` once a script wrote the notes.
    private final class Rig {
        let model = AppModel(receivesSignals: false)
        let session: TerminalSession
        private let lock = NSLock()
        private var _scripts: [String] = [], _keys: [TerminalKey] = [], _journal: [String] = []
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
        var keys: [TerminalKey] { lock.lock(); defer { lock.unlock() }; return _keys }
        var journal: [String] { lock.lock(); defer { lock.unlock() }; return _journal }

        init(_ test: PreviewNotesTests, screen: [String], after: [String]) {
            let before = test.lines(screen), later = test.lines(after)
            var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys096", customTitle: "", processes: ["login", "-zsh", "claude"],
                                          busy: false, selected: true, text: before)
            tab.history = true
            session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = test.timing
            bridge.runScript = { [unowned self] script in self.lock.lock(); self._scripts.append(script); self.lock.unlock() }
            bridge.postKey = { [unowned self] key, _ in self.lock.lock(); self._keys.append(key); self.lock.unlock() }
            bridge.fieldJournal = { [unowned self] entry in self.lock.lock(); self._journal.append(entry); self.lock.unlock() }
            bridge.screenReader = { [unowned self] _, _ in self.scripts.contains { $0.contains("[200~") } ? later : before }
            model.sessions = [session]; model.selectedID = session.id
        }
    }

    func testTheCardsNotesGoInOneWriteWithNothingForward() throws {
        let rig = Rig(self, screen: F.single(), after: F.answered("Ticket aparte"))
        let done = expectation(description: "answered")
        var delivery: KeyDelivery?
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: 1, notes: notes, on: rig.session) { delivery = $0; done.fulfill() }
        XCTAssertTrue(rig.session.answering, "The card stays quiet while it goes.")
        XCTAssertTrue(rig.session.sending)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(delivery, .sent)
        XCTAssertEqual(rig.keys, [], "No key event, though Accessibility is on.")
        XCTAssertEqual(rig.scripts.count, 1, "Arrows, n, notes and Terminal's Return in one script.")
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.down], notes: notes))), script)
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys096" then"#), "Addressed to the tab by its TTY.")
        for script in rig.scripts {
            for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] { XCTAssertFalse(script.contains(word), "«\(word)» in \(script)") }
        }
        XCTAssertEqual(rig.journal.count, 1, "The steps are in the delivery log.")
        XCTAssertTrue(rig.journal[0].hasPrefix("Claude · opción 2 con notas (22 caracteres)"), rig.journal[0])
        XCTAssertFalse(rig.journal[0].contains("logo"), "The notes' words stay out of the log: \(rig.journal[0])")
        XCTAssertTrue(rig.journal[0].contains("Claude registró la opción: enviado con sus notas"), rig.journal[0])
        XCTAssertNil(rig.model.notice)
    }

    func testTheCardRefusesNotesWhenTheTerminalAlreadyHasSome() throws {
        let rig = Rig(self, screen: F.single(notes: "a medias"), after: F.answered("Ticket aparte"))
        let done = expectation(description: "refused")
        rig.model.answer(try XCTUnwrap(rig.session.prompt), option: 1, notes: notes, on: rig.session) { XCTAssertEqual($0, .failed); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(rig.scripts.filter { $0.contains("[200~") }, [])
        XCTAssertEqual(rig.model.notice, "Esa pregunta ya tiene notas a medio escribir en la terminal; termínalas allí o bórralas y vuelve a intentarlo.")
        // "Chat about this" takes no notes, and a question that changed gets nothing.
        let other = Rig(self, screen: F.single(), after: F.answered("x"))
        let chat = expectation(description: "chat")
        other.model.answer(try XCTUnwrap(other.session.prompt), option: 2, notes: notes, on: other.session) { XCTAssertEqual($0, .failed); chat.fulfill() }
        wait(for: [chat], timeout: 2)
        XCTAssertEqual(other.scripts.filter { $0.contains("[200~") }, [])
    }
}
