import XCTest
@testable import Nook

/// Claude's notes field with the terminal's keyboard, in its question whose options carry a preview. Plain text doesn't show the
/// cursor, so notes typed into the open field read like notes held with it closed; what tells them apart is the key hint, which names
/// the external editor only while the field is open (Claude Code 2.1.295: `At&&mo&&chord("ctrl+g","edit in ${mo}")`), and wraps
/// at the terminal's width like any text. While the field has the keyboard, the arrows and Enter of a click land in it (Enter answers
/// the option Claude has highlighted, not the clicked one), so the model refuses with nothing sent. Every transport is a recorder and
/// every screen a fixture (`PreviewQuestionFixtures`): nothing reaches Terminal, a real session or the keyboard.
final class PreviewNotesFocusTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)
    private let notes = "el logo a la izquierda"
    private let placeholder = "Add notes on this design…"
    private let refusal = "El campo de notas de Claude está abierto en la terminal: ciérralo allí con Esc, o termina allí tu respuesta. No envié nada."

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }
    private func parsed(_ rows: [String], file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        try XCTUnwrap(AgentPrompt.parse(lines(rows)), file: file, line: line)
    }
    private func kept(width: Int) -> String { lines(F.above.dropLast() + ["", F.rule(width)]) }

    // MARK: - Reading the screen

    /// Sample's 106 columns: with the field open the hint is 116 long and wraps, "… · Esc" over "to cancel".
    func testNotesTypedIntoTheOpenFieldAreToldFromNotesHeld() throws {
        let rows = F.sample(notes: notes, focused: true)
        XCTAssertEqual(Array(rows.suffix(2)), ["Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · ctrl+g to edit in Vim · Esc", "to cancel"],
                       "The fixture wraps the hint as Ink does at 106 columns.")
        let typing = try parsed(rows), held = try parsed(F.sample(notes: notes))
        XCTAssertEqual(typing.notes, notes, "The row shows the field's text as it shows held notes.")
        XCTAssertFalse(typing.notesOpen, "Not empty: no placeholder.")
        XCTAssertTrue(typing.notesFocused)
        XCTAssertEqual(held.notes, notes)
        XCTAssertFalse(held.notesFocused)
        XCTAssertEqual(typing.signature, held.signature, "Opening the field changes no question.")
        XCTAssertEqual(typing.actions, [AgentPrompt.KeyAction(key: "enter", label: "select"), AgentPrompt.KeyAction(key: "↑/↓", label: "navigate"),
                                        AgentPrompt.KeyAction(key: "n", label: "add notes"), AgentPrompt.KeyAction(key: "tab", label: "switch questions"),
                                        AgentPrompt.KeyAction(key: "ctrl+g", label: "edit in Vim"), AgentPrompt.KeyAction(key: "esc", label: "cancel")],
                       "Both rows of the hint are one hint.")
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), kept(width: 106), "The hint's second row goes to the card with the rest of the dialog.")
        XCTAssertEqual(typing.tailLines, held.tailLines + 1)
    }

    func testTheOpenEmptyFieldIsOpenAndFocused() throws {
        for rows in [F.sample(notes: placeholder, focused: true), F.sample(notes: placeholder), F.single(notes: placeholder, focused: true)] {
            let prompt = try parsed(rows)
            XCTAssertNil(prompt.notes)
            XCTAssertTrue(prompt.notesOpen)
            XCTAssertTrue(prompt.notesFocused, "The placeholder alone says the field is open, hint or not.")
        }
        // A single question's hint has no "Tab to switch questions" and fits on one row.
        let single = try parsed(F.single(notes: notes, focused: true))
        XCTAssertTrue(single.notesFocused)
        XCTAssertEqual(single.notes, notes)
        XCTAssertEqual(single.actions.map(\.key), ["enter", "↑/↓", "n", "ctrl+g", "esc"])
    }

    /// Every width Claude's box still fits beside the options, with each editor Claude may name: wherever Ink breaks the hint ("Esc" over
    /// "to cancel", "Esc to" over "cancel", "ctrl+g to edit" over "in Vim · Esc to cancel", …), the dialog reads, the field reads as
    /// focused, and the hint's rows go to the card. The same notes held with the field closed (the hint without the editor, wrapped
    /// too) never read as focused.
    func testEveryWrapOfTheHintReadsAndTellsTheFocus() throws {
        var shapes = Set<String>()
        for editor in ["Vim", "VS Code", "nano", "Sublime Text"] {
            for width in 64...130 {
                let rows = F.sample(notes: notes, focused: true, width: width, editor: editor)
                let context = "\(editor), \(width) columns: \(rows.suffix(3))"
                let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)), context)
                XCTAssertTrue(prompt.notesFocused, context)
                XCTAssertEqual(prompt.notes, notes, context)
                XCTAssertEqual(prompt.actions.last, AgentPrompt.KeyAction(key: "esc", label: "cancel"), context)
                XCTAssertTrue(prompt.actions.contains(AgentPrompt.KeyAction(key: "ctrl+g", label: "edit in \(editor)")), context)
                XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), kept(width: width), context)
                let hint = F.wrapped(F.focusedHint(editor: editor), width: width)
                shapes.insert(hint.dropFirst().map { String($0.prefix(while: { $0 != " " })) }.joined(separator: "|"))

                let closed = Array(F.sample(notes: notes, width: width).dropLast()) + F.wrapped(F.hint, width: width)
                let held = try XCTUnwrap(AgentPrompt.parse(lines(closed)), "closed, " + context)
                XCTAssertFalse(held.notesFocused, "closed, " + context)
                XCTAssertEqual(held.notes, notes, "closed, " + context)
                XCTAssertEqual(held.actions.map(\.key), ["enter", "↑/↓", "n", "tab", "esc"], "closed, " + context)
            }
        }
        // The sweep covers the breaks that matter: inside "Esc to cancel", inside "ctrl+g to edit in …", and before or after a "·".
        for first in ["to", "cancel", "Esc", "·", "Vim", "Code", "in", "edit", "ctrl+g", "questions"] {
            XCTAssertTrue(shapes.contains { $0.components(separatedBy: "|").contains(first) }, "A row opening with «\(first)» in \(shapes.sorted())")
        }
    }

    /// Only the dialog's own hint counts: notes that happen to read like it, a line right under a whole hint, or another dialog's
    /// hint naming the editor (the "Type something." field's) say nothing about the notes field.
    func testOnlyTheDialogsOwnHintTellsTheFocus() throws {
        let lookalike = try parsed(F.sample(notes: "ctrl+g to edit in Vim"))
        XCTAssertEqual(lookalike.notes, "ctrl+g to edit in Vim")
        XCTAssertFalse(lookalike.notesFocused)
        // Claude's mode line right under the hint is no row of it.
        let mode = "⏵⏵ auto mode on (shift+tab to cycle)"
        let underWhole = try parsed(F.sample(notes: notes) + [mode])
        XCTAssertFalse(underWhole.notesFocused)
        XCTAssertEqual(underWhole.actions.last, AgentPrompt.KeyAction(key: "esc", label: "cancel"))
        let underWrapped = try parsed(F.sample(notes: notes, focused: true) + [mode])
        XCTAssertTrue(underWrapped.notesFocused)
        XCTAssertEqual(underWrapped.actions.last, AgentPrompt.KeyAction(key: "esc", label: "cancel"))
        // Output right under a whole hint: the dialog scrolled away, or isn't one.
        XCTAssertNil(AgentPrompt.parse(lines(F.sample(notes: notes) + ["hola mundo"])))
        XCTAssertNil(AgentPrompt.parse(lines(F.sample(notes: notes, focused: true) + ["hola mundo"])))
        // A question without a preview takes no notes, whatever its hint names.
        let other = try parsed(Array(F.nextTab.dropLast()) + ["Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc to cancel"])
        XCTAssertFalse(other.takesNotes)
        XCTAssertFalse(other.notesFocused)
    }

    // MARK: - From the card (AppModel)

    /// A model whose Terminal tab shows `screen`, and answers through recorders: the scripts it would run and the keys it would post.
    /// The bridge's own reading right before an answer (with notes, or a choice in a question with a preview) is `fresh`, the tab's
    /// screen unless a test says otherwise, or nothing when `unreadable`; `reads` counts them.
    private final class Rig {
        let model = AppModel(receivesSignals: false)
        let session: TerminalSession
        private let lock = NSLock()
        private var _scripts: [String] = [], _keys: [TerminalKey] = [], _reads = 0
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
        var keys: [TerminalKey] { lock.lock(); defer { lock.unlock() }; return _keys }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }

        init(_ test: PreviewNotesFocusTests, screen: [String], fresh: [String]? = nil, unreadable: Bool = false) {
            let before = test.lines(screen), reading: String? = unreadable ? nil : test.lines(fresh ?? screen)
            var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys093", customTitle: "", processes: ["login", "-zsh", "claude"],
                                          busy: false, selected: true, text: before)
            tab.history = true
            session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = test.timing
            bridge.reader = { _ in [] }
            bridge.runScript = { [unowned self] script in self.lock.lock(); self._scripts.append(script); self.lock.unlock() }
            bridge.postKey = { [unowned self] key, _ in self.lock.lock(); self._keys.append(key); self.lock.unlock() }
            bridge.fieldJournal = { _ in }
            bridge.screenReader = { [unowned self] _, _ in self.lock.lock(); self._reads += 1; self.lock.unlock(); return reading }
            model.sessions = [session]; model.selectedID = session.id
        }

        func choose(_ option: Int, notes: String? = nil, test: XCTestCase) throws -> KeyDelivery? {
            let prompt = try XCTUnwrap(session.prompt)
            let done = test.expectation(description: "answer")
            var delivery: KeyDelivery?
            if let notes {
                model.answer(prompt, option: option, notes: notes, on: session) { delivery = $0; done.fulfill() }
            } else {
                model.answer(prompt, option: option, on: session) { delivery = $0; done.fulfill() }
            }
            test.wait(for: [done], timeout: 5)
            return delivery
        }
    }

    /// The field has the keyboard, with notes typed into it or empty: no click on any option sends anything, and the model says why.
    func testAClickWhileTheFieldHasTheKeyboardSendsNothing() throws {
        for screen in [F.sample(notes: notes, focused: true), F.sample(notes: placeholder, focused: true), F.sample(notes: placeholder),
                       F.sample(highlight: 2, notes: notes, focused: true), F.single(notes: notes, focused: true)] {
            for option in 0..<3 {
                let rig = Rig(self, screen: screen)
                XCTAssertTrue(try XCTUnwrap(rig.session.prompt).notesFocused)
                XCTAssertEqual(try rig.choose(option, test: self), .failed, "option \(option + 1), \(screen.suffix(2))")
                XCTAssertEqual(rig.scripts, [], "No arrow and no Return reach the field.")
                XCTAssertEqual(rig.keys, [])
                XCTAssertEqual(rig.model.notice, refusal)
                XCTAssertFalse(rig.session.answering, "The card can be used again once the field is closed.")
            }
        }
        XCTAssertEqual(AppModel.notesFieldNotice(agent: .claude), refusal)
    }

    /// Notes the terminal holds with its field closed go with whichever option is chosen: a plain click answers, as before.
    func testNotesHeldWithTheFieldClosedStillAnswerPlainly() throws {
        let rig = Rig(self, screen: F.sample(notes: notes))
        XCTAssertEqual(try rig.choose(1, test: self), .sent)
        XCTAssertEqual(rig.scripts.count, 1)
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.answerAction([.down, .enter]))), script)
        XCTAssertFalse(script.contains("[200~"))
        XCTAssertEqual(rig.keys, [])
        XCTAssertNil(rig.model.notice)
    }

    // MARK: - A click in a Terminal tab: read again right before

    /// The field was opened at the terminal after the mirror's last reading (which the card shows): the reading right before the click's
    /// write finds it, and nothing is written.
    func testAFieldOpenedSinceTheMirrorsReadingGetsNoKeys() throws {
        for fresh in [F.sample(notes: notes, focused: true), F.sample(notes: placeholder, focused: true), F.sample(highlight: 2, notes: notes, focused: true)] {
            let rig = Rig(self, screen: F.sample(notes: notes), fresh: fresh)
            XCTAssertFalse(try XCTUnwrap(rig.session.prompt).notesFocused, "The card's reading has the field closed.")
            XCTAssertEqual(try rig.choose(1, test: self), .failed)
            XCTAssertEqual(rig.reads, 1, "One reading, right before.")
            XCTAssertEqual(rig.scripts, [], "No arrow and no Return reach the field.")
            XCTAssertEqual(rig.keys, [])
            XCTAssertEqual(rig.model.notice, refusal)
            XCTAssertFalse(rig.session.answering, "The card can be used again.")
        }
    }

    /// Control: the field still closed, the click goes in one write, its keys counted from the reading right before (here the user moved
    /// the highlight to the second option at the terminal since the mirror's reading: ↑ ⏎ reaches the first).
    func testWithTheFieldClosedTheClickGoesInOneWriteFromTheFreshHighlight() throws {
        let rig = Rig(self, screen: F.sample(notes: notes))
        XCTAssertEqual(try rig.choose(1, test: self), .sent)
        XCTAssertEqual(rig.reads, 1)
        XCTAssertEqual(rig.scripts.count, 1, "One write.")
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.answerAction([.down, .enter]))), script)
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys093" then"#), "Addressed to the tab by its TTY.")
        for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] { XCTAssertFalse(script.contains(word), "«\(word)» in \(script)") }
        XCTAssertEqual(rig.keys, [], "No key event.")
        XCTAssertNil(rig.model.notice)

        let moved = Rig(self, screen: F.sample(), fresh: F.sample(highlight: 2))
        XCTAssertEqual(try moved.choose(0, test: self), .sent)
        XCTAssertEqual(moved.scripts.count, 1)
        XCTAssertTrue(try XCTUnwrap(moved.scripts.first).contains(try XCTUnwrap(TerminalAppBridge.answerAction([.up, .enter]))), moved.scripts.first ?? "")
    }

    /// The reading right before shows another question (the dialog moved on to its next tab), or can't be read: nothing is written.
    func testAnotherQuestionOrNoReadingGetsNoKeys() throws {
        let other = Rig(self, screen: F.sample(), fresh: F.nextTab)
        XCTAssertEqual(try other.choose(1, test: self), .failed)
        XCTAssertEqual(other.scripts, [])
        XCTAssertEqual(other.model.notice, "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal.")
        XCTAssertFalse(other.session.answering)
        let unread = Rig(self, screen: F.sample(), unreadable: true)
        XCTAssertEqual(try unread.choose(1, test: self), .failed)
        XCTAssertEqual(unread.scripts, [])
        XCTAssertEqual(unread.model.notice, "No pude leer la pestaña para comprobar la pregunta; no envié ninguna tecla.")
        XCTAssertFalse(unread.session.answering)
        // The verdicts themselves, for any transport.
        let expected = try parsed(F.sample()).signature
        for (screen, error) in [(F.nextTab, TerminalAppBridge.FieldAnswerError.changed), (F.sample(notes: notes, focused: true), .notesFieldOpen),
                                (F.sample(notes: placeholder), .notesFieldOpen)] {
            var sent: [[TerminalKey]] = []
            XCTAssertThrowsError(try TerminalAppBridge.answerPreview(option: 1, expecting: expected, agent: .claude, send: { keys, _ in sent.append(keys) }, read: { self.lines(screen) })) {
                XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, error)
            }
            XCTAssertEqual(sent, [])
        }
    }

    /// Any other question in a Terminal tab is chosen as before: from the mirror's reading, with no reading of its own.
    func testOtherQuestionsKeepTheirPathWithNoReading() throws {
        let rig = Rig(self, screen: F.nextTab, unreadable: true)
        XCTAssertEqual(try rig.choose(1, test: self), .sent)
        XCTAssertEqual(rig.reads, 0)
        XCTAssertEqual(rig.scripts.count, 1)
        XCTAssertTrue(try XCTUnwrap(rig.scripts.first).contains(try XCTUnwrap(TerminalAppBridge.answerAction([.down, .enter]))))
    }

    /// Notes from the card while the terminal's field has the keyboard: refused before any write (the "n" would be typed into the field).
    func testNotesFromTheCardWhileTheFieldHasTheKeyboardSendNothing() throws {
        for screen in [F.sample(notes: notes, focused: true), F.sample(notes: placeholder, focused: true), F.single(notes: placeholder)] {
            let rig = Rig(self, screen: screen)
            XCTAssertEqual(try rig.choose(1, notes: "otra cosa", test: self), .failed)
            XCTAssertEqual(rig.scripts, [])
            XCTAssertEqual(rig.keys, [])
            XCTAssertEqual(rig.model.notice, refusal)
            XCTAssertFalse(rig.session.answering)
        }
        // Held with the field closed: refused too (the paste would land inside them), with what says so.
        let held = Rig(self, screen: F.sample(notes: notes))
        XCTAssertEqual(try held.choose(1, notes: "otra cosa", test: self), .failed)
        XCTAssertEqual(held.scripts, [])
        XCTAssertEqual(held.model.notice, "Esa pregunta ya tiene notas a medio escribir en la terminal; termínalas allí o bórralas y vuelve a intentarlo.")
    }

    /// The user opened the field in the terminal after the card's last reading: the bridge's reading right before the write finds it,
    /// and nothing goes.
    func testTheReadingRightBeforeTheNotesCatchesAFieldOpenedSince() throws {
        let rig = Rig(self, screen: F.single(), fresh: F.single(notes: notes, focused: true))
        XCTAssertFalse(try XCTUnwrap(rig.session.prompt).notesFocused)
        XCTAssertEqual(try rig.choose(1, notes: "otra cosa", test: self), .failed)
        XCTAssertEqual(rig.scripts.filter { $0.contains("[200~") || $0.contains(#""n""#) }, [], "No write: no arrow, no n, no paste.")
        XCTAssertEqual(rig.keys, [])
        XCTAssertEqual(rig.model.notice, refusal)
    }

    // MARK: - A Nook session (tmux)

    /// A Nook session's pane is read again right before the arrows go: a field opened since the last reading is caught there, and no
    /// key is pressed. tmux is a script that answers `capture-pane` with that screen and writes down every command it gets.
    @MainActor
    func testANookSessionsFreshReadingCatchesTheOpenField() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-notes-focus-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = folder.appendingPathComponent("screen.txt"), log = folder.appendingPathComponent("tmux.log"), tmux = folder.appendingPathComponent("tmux")
        try lines(F.sample(notes: notes, focused: true)).write(to: screen, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\ncase \"$*\" in *capture-pane*) cat '\(screen.path)';; esac\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)

        let backend = TmuxBackend(executable: tmux.path, socket: folder.appendingPathComponent("socket").path, configuration: "/dev/null")
        let record = SessionRecord(id: "nook-notes-" + UUID().uuidString.prefix(6), name: "Claude", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        defer { session.disconnectClients() }
        session.applyPane(tty: "/dev/ttys091", processes: ["claude"], text: lines(F.sample(notes: notes)))
        session.isRunning = true
        XCTAssertEqual(session.prompt?.notesFocused, false, "The last reading had the field closed.")
        let model = AppModel(receivesSignals: false)
        model.sessions = [session]; model.selectedID = session.id
        let done = expectation(description: "refused")
        var delivery: KeyDelivery?
        model.answer(try XCTUnwrap(session.prompt), option: 1, on: session) { delivery = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(delivery, .failed)
        let commands = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(commands.contains("capture-pane"), "The pane was read again: \(commands)")
        XCTAssertFalse(commands.contains("send-keys"), "No key pressed: \(commands)")
        XCTAssertEqual(model.notice, refusal)
        XCTAssertFalse(session.answering)

        // Control: the same pane with the field closed gets its keys, so the log would have shown them.
        try lines(F.sample(notes: notes)).write(to: screen, atomically: true, encoding: .utf8)
        model.notice = nil
        // The fake tmux's `attach-session` (the session's own terminal) exits at once, which marks the session stopped meanwhile.
        session.isRunning = true
        let sent = expectation(description: "sent")
        model.answer(try XCTUnwrap(session.prompt), option: 1, on: session) { delivery = $0; sent.fulfill() }
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(delivery, .sent)
        let pressed = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.contains("send-keys") }
        XCTAssertEqual(pressed.map { $0.components(separatedBy: " ").last ?? "" }, ["Down", "Enter"], "\(pressed)")
        XCTAssertNil(model.notice)
    }
}
