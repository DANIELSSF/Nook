import XCTest
@testable import Nook

/// The checks an answer's write makes in its own script, right before writing (`TerminalAppBridge.answerScript`): the tab still runs a
/// program in its foreground (Terminal's `busy`: once the agent quits, the answer's ↑ and Terminal's Return would recall and run the
/// shell's last command), and, for Claude's question with a preview, the screen still holds the lines the keys were counted from
/// (`AgentPrompt.screenAnchors`). Also the cap on an answer's length and what the delivery log keeps of it. Transports are recorders
/// that play Terminal's part (a check that fails raises its error, as the script would); the checks' own AppleScript runs locally,
/// on records and strings, never against Terminal. Nothing reaches Terminal, a real session or the keyboard.
final class AnswerWriteGuardTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.6, hold: 0.06, settle: 0.3)
    private let notes = "el logo a la izquierda"

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    // MARK: - The script

    func testEveryAnswerScriptChecksTheTabBeforeItsWrite() throws {
        let anchors = try XCTUnwrap(AgentPrompt.parse(lines(F.sample()))).screenAnchors
        let action = try XCTUnwrap(TerminalAppBridge.answerAction([.down, .enter]))
        let script = TerminalAppBridge.answerScript(windowID: 42, tty: "/dev/ttys003", anchors: anchors, action: action)
        let tab = try XCTUnwrap(script.range(of: #"if tty of t is "/dev/ttys003" then"#))
        let busy = try XCTUnwrap(script.range(of: TerminalAppBridge.busyGuard))
        let screen = try XCTUnwrap(script.range(of: "set screenNow to contents of tab tabIndex of targetWindow"))
        let write = try XCTUnwrap(script.range(of: action))
        XCTAssertTrue(tab.upperBound <= busy.lowerBound && busy.upperBound <= screen.lowerBound && screen.upperBound <= write.lowerBound,
                      "In the tab's block: the tab, then the screen, then the write.")
        for anchor in anchors { XCTAssertTrue(script.contains("if screenNow does not contain \(AppleScriptText.literal(anchor)) then error"), anchor) }
        for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] { XCTAssertFalse(script.contains(word), word) }
        var details: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: script)!.compileAndReturnError(&details), details?.description ?? "")
        // Without anchors only the tab is checked.
        let plain = TerminalAppBridge.answerScript(windowID: 42, tty: "/dev/ttys003", action: action)
        XCTAssertTrue(plain.contains(TerminalAppBridge.busyGuard))
        XCTAssertFalse(plain.contains("screenNow"))
        XCTAssertTrue(NSAppleScript(source: plain)!.compileAndReturnError(&details), details?.description ?? "")
    }

    /// The checks' AppleScript, run here on a record and a string in place of Terminal's tab and screen: a check that fails raises the
    /// error Nook reads back, before the line after it (the write) runs.
    func testTheChecksStopTheScriptBeforeTheWrite() throws {
        func run(_ source: String) throws -> String? { try TerminalAppBridge.execute(source + "\nreturn \"written\"").stringValue }
        XCTAssertEqual(try run("set t to {busy:true}\n" + TerminalAppBridge.busyGuard), "written")
        XCTAssertThrowsError(try run("set t to {busy:false}\n" + TerminalAppBridge.busyGuard)) {
            XCTAssertEqual(TerminalAppBridge.answerOutcome($0) as? TerminalAppBridge.FieldAnswerError, .agentGone, "\($0)")
        }
        let screen = lines(F.sample())
        let anchors = try XCTUnwrap(AgentPrompt.parse(screen)).screenAnchors
        let set = { (text: String) in "set screenNow to " + AppleScriptText.literal(text) + "\n" }
        XCTAssertEqual(try run(set(screen) + TerminalAppBridge.screenGuard(anchors)), "written")
        for changed in [F.sample(highlight: 2), F.sample(notes: notes, focused: true), F.sample(notes: "Add notes on this design…"), F.nextTab,
                        F.sample().map { $0.uppercased() }] {
            XCTAssertThrowsError(try run(set(lines(changed)) + TerminalAppBridge.screenGuard(anchors)), changed.suffix(2).joined()) {
                XCTAssertEqual(TerminalAppBridge.answerOutcome($0) as? TerminalAppBridge.FieldAnswerError, .changed, "\($0)")
            }
        }
    }

    /// What the anchors are, and that they tell the changes that matter from a screen that stayed as read.
    func testTheAnchorsAreTheRowsThatChangeWithTheQuestion() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(F.sample())))
        let marked = try XCTUnwrap(F.sample().first { $0.hasPrefix("❯ 1.") })
        XCTAssertEqual(prompt.screenAnchors, [marked, "  Chat about this", String(repeating: " ", count: 34) + "Notes: press n to add notes", F.hint])
        let chat = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(highlight: 3)))).screenAnchors
        XCTAssertEqual(chat.filter { $0.hasPrefix("❯") }.count, 2, "The option keeping its mark and «Chat about this».")
        let focused = try XCTUnwrap(AgentPrompt.parse(lines(F.sample(notes: notes, focused: true)))).screenAnchors
        XCTAssertEqual(Array(focused.suffix(2)), Array(F.sample(notes: notes, focused: true).suffix(2)), "Both rows of a wrapped hint.")
        func holds(_ anchors: [String], _ rows: [String]) -> Bool { anchors.allSatisfy(lines(rows).contains) }
        XCTAssertTrue(holds(prompt.screenAnchors, F.sample()))
        XCTAssertTrue(holds(prompt.screenAnchors, F.sample() + ["⏵⏵ auto mode on (shift+tab to cycle)"]), "What's under the dialog doesn't count.")
        for changed in [F.sample(highlight: 2), F.sample(highlight: 3), F.sample(notes: "Add notes on this design…"), F.sample(notes: notes),
                        F.sample(focused: true), F.nextTab, F.answered("Ticket aparte")] {
            XCTAssertFalse(holds(prompt.screenAnchors, changed), changed.suffix(3).joined(separator: " | "))
        }
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(F.nextTab))).screenAnchors, [], "Only the layout with a preview has them.")
    }

    // MARK: - From the card (AppModel), Terminal playing its part

    /// A model whose Terminal tab shows `screen`. Its scripts are recorded as written unless a check of theirs fails the way Terminal
    /// would fail it: the tab not `busy`, or the screen no longer holding an anchor (`screenChanged`).
    private final class Rig {
        let model = AppModel(receivesSignals: false)
        let session: TerminalSession
        private let lock = NSLock()
        private var _written: [String] = [], _reads = 0
        var written: [String] { lock.lock(); defer { lock.unlock() }; return _written }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        var journal: [String] = []

        init(_ test: AnswerWriteGuardTests, screen: [String], after: [String]? = nil, busy: Bool = true, screenChanged: Bool = false) {
            let before = test.lines(screen), later = after.map(test.lines)
            var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys089", customTitle: "", processes: ["login", "-zsh", "claude"],
                                          busy: true, selected: true, text: before)
            tab.history = true
            session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = test.timing
            bridge.reader = { _ in [] }
            bridge.postKey = { _, _ in XCTFail("No key event") }
            bridge.fieldJournal = { [unowned self] entry in self.lock.lock(); self.journal.append(entry); self.lock.unlock() }
            bridge.runScript = { [unowned self] script in
                if !busy, script.contains(TerminalAppBridge.busyGuard) { throw TerminalBridgeError.failed(TerminalAppBridge.agentGoneError) }
                if screenChanged, script.contains("screenNow") { throw TerminalBridgeError.failed(TerminalAppBridge.screenChangedError) }
                self.lock.lock(); self._written.append(script); self.lock.unlock()
            }
            bridge.screenReader = { [unowned self] _, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                self._reads += 1
                return self._written.isEmpty ? before : (later ?? before)
            }
            model.sessions = [session]; model.selectedID = session.id
        }

        func answer(_ option: Int, text: String? = nil, notes: String? = nil, test: XCTestCase) throws -> KeyDelivery? {
            let prompt = try XCTUnwrap(session.prompt)
            let done = test.expectation(description: "answer")
            var delivery: KeyDelivery?
            let completion: (KeyDelivery) -> Void = { delivery = $0; done.fulfill() }
            if let notes { model.answer(prompt, option: option, notes: notes, on: session, completion: completion) }
            else if let text { model.answer(prompt, option: option, text: text, on: session, completion: completion) }
            else { model.answer(prompt, option: option, on: session, completion: completion) }
            test.wait(for: [done], timeout: 5)
            return delivery
        }
    }

    private let gone = "Claude ya no está en marcha en esa pestaña, así que no envié lo que faltaba de tu respuesta. Revisa la terminal."

    /// Claude quit between the reading and the write: no answer's write goes (a plain choice, a preview's choice, notes, a field's
    /// answer), the model says why, and no session is marked stopped (that is for a failure to reach Terminal at all).
    func testWithTheTabNoLongerBusyNothingIsWritten() throws {
        let cases: [(screen: [String], option: Int, text: String?, notes: String?)] = [
            (F.nextTab, 1, nil, nil), (F.sample(), 1, nil, nil), (F.single(), 1, nil, notes), (F.nextTab, 2, "Usa MongoDB", nil)]
        for (screen, option, text, notes) in cases {
            let rig = Rig(self, screen: screen, busy: false)
            XCTAssertEqual(try rig.answer(option, text: text, notes: notes, test: self), .failed, "\(screen.last ?? "")")
            XCTAssertEqual(rig.written, [], "Nothing written.")
            XCTAssertEqual(rig.model.notice, gone)
            XCTAssertTrue(rig.session.isRunning, "The tab's session isn't marked stopped.")
            XCTAssertFalse(rig.session.answering)
        }
        XCTAssertEqual(AppModel.agentGoneNotice(agent: .claude), gone)
    }

    /// Control: the tab busy (Claude in its foreground), each of those answers is one write carrying the check.
    func testWithTheTabBusyEachAnswerIsOneWrite() throws {
        let plain = Rig(self, screen: F.nextTab)
        XCTAssertEqual(try plain.answer(1, test: self), .sent)
        XCTAssertEqual(plain.written.count, 1)
        let preview = Rig(self, screen: F.sample())
        XCTAssertEqual(try preview.answer(1, test: self), .sent)
        XCTAssertEqual(preview.written.count, 1)
        let withNotes = Rig(self, screen: F.single(), after: F.answered("Ticket aparte"))
        XCTAssertEqual(try withNotes.answer(1, notes: notes, test: self), .sent)
        XCTAssertEqual(withNotes.written.count, 1)
        for script in plain.written + preview.written + withNotes.written {
            XCTAssertTrue(script.contains(TerminalAppBridge.busyGuard), script)
            for word in ["activate", "set index", "frontmost"] { XCTAssertFalse(script.contains(word), word) }
        }
        // The preview's choice and the notes carry the reading's anchors too.
        XCTAssertTrue(try XCTUnwrap(preview.written.first).contains("if screenNow does not contain " + AppleScriptText.literal(F.hint)))
        XCTAssertTrue(try XCTUnwrap(withNotes.written.first).contains("Notes: press n to add notes"))
    }

    /// The screen changed between the reading and the write (Terminal finds an anchor missing): nothing is written.
    func testAScreenThatChangedSinceTheReadingGetsNothing() throws {
        let preview = Rig(self, screen: F.sample(), screenChanged: true)
        XCTAssertEqual(try preview.answer(1, test: self), .failed)
        XCTAssertEqual(preview.written, [])
        XCTAssertEqual(preview.model.notice, "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal.")
        XCTAssertTrue(preview.journal.last?.contains("la pantalla ya no muestra la pregunta como se leyó; no se escribió") == true, preview.journal.last ?? "")
        let withNotes = Rig(self, screen: F.single(), screenChanged: true)
        XCTAssertEqual(try withNotes.answer(1, notes: notes, test: self), .failed)
        XCTAssertEqual(withNotes.written, [])
        XCTAssertEqual(withNotes.model.notice, "La pregunta cambió antes de que enviara tu respuesta; no envié nada. Revisa la terminal.")
        XCTAssertFalse(withNotes.journal.joined().contains("logo"), "The notes' words stay out of the log.")
    }

    // MARK: - Length

    /// Longer than 4,000 characters, notes and a field's answer are refused before anything is read or written; the card keeps them.
    func testAnAnswerLongerThanTheLimitIsRefusedBeforeAnything() throws {
        let long = String(repeating: "a", count: AppModel.answerLimit + 1)
        let withNotes = Rig(self, screen: F.single())
        XCTAssertEqual(try withNotes.answer(1, notes: long, test: self), .failed)
        XCTAssertEqual(withNotes.written, [])
        XCTAssertEqual(withNotes.reads, 0)
        XCTAssertEqual(withNotes.model.notice, "Tus notas son demasiado largas (más de 4000 caracteres); acórtalas y vuelve a intentarlo. No envié nada.")
        let field = Rig(self, screen: F.nextTab)
        XCTAssertEqual(try field.answer(2, text: long, test: self), .failed)
        XCTAssertEqual(field.written, [])
        XCTAssertEqual(field.reads, 0)
        XCTAssertEqual(field.model.notice, "Tu respuesta es demasiado larga (más de 4000 caracteres); acórtala y vuelve a enviarla. No envié nada.")
        // At the limit they go (counted once cleaned: blanks at either end don't count).
        let atLimit = Rig(self, screen: F.single(), after: F.answered("Ticket aparte"))
        XCTAssertEqual(try atLimit.answer(1, notes: String(repeating: "a", count: AppModel.answerLimit) + "\n ", test: self), .sent)
        XCTAssertEqual(atLimit.written.count, 1)
        XCTAssertFalse(atLimit.journal.joined().contains("aaaa"), "Only the length is logged.")
        XCTAssertTrue(atLimit.journal.joined().contains("(4000 caracteres)"), atLimit.journal.joined())
    }
}
