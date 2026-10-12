import AppKit
import XCTest
@testable import Nook

/// Choosing an option of an agent's dialog in a Terminal tab without bringing Terminal forward, and giving the keyboard back
/// after the keys that still must (← →, Esc, ⇧⇥, a text field reached by arrows). Every transport is a recorder: nothing here
/// reaches the real Terminal, posts a key or moves the real keyboard.
final class TerminalAnswerTests: XCTestCase {
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    /// Claude Code's permission request, as users see it.
    private let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                              " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                              "   3. No, and tell Claude what to do differently (esc)"]
    /// Claude's question that takes several answers (AskUserQuestion with multiSelect): Enter ticks the highlighted box.
    private let platforms = [" ☐ Platforms", "", "Which platforms should the release support?", "",
                             "  1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "❯ 3. [ ] Linux", "  4. Type something.", "  5. Submit", "",
                             "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// One question of a dialog with several, with its free-text option.
    private let cache = [String(repeating: "─", count: 72), "←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Which cache should we put in front of it?", "",
                         "❯ 1. Redis", "     In-memory, battle tested", "  2. Memcached", "     Simpler, no persistence", "  3. Type something.",
                         String(repeating: "─", count: 72), "  4. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
    /// Codex's approval, highlighted with "›".
    private let codex = ["  Would you like to run the following command?", "", "  Reason: needs network access", "", "  $ git push origin main", "",
                         "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for this command (p)", "  3. No, and tell Codex what to do differently (esc)",
                         "", "  Press enter to confirm or esc to cancel"]

    private func tab(_ text: String, agent: String = "claude") -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys090", customTitle: "", processes: ["login", "-zsh", agent], busy: false, selected: true, text: text)
    }

    /// A model whose Terminal transport records, with one tab showing `screen`. Accessibility is off: an answer must not need it.
    private func rig(_ screen: [String], agent: String = "claude", keysAllowed: Bool = false) -> (AppModel, TerminalSession, () -> [String], () -> [TerminalKey]) {
        let model = AppModel(receivesSignals: false)
        let lock = NSLock()
        var scripts: [String] = [], keys: [TerminalKey] = []
        model.terminalBridge.directKeysAllowed = { keysAllowed }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { script in lock.lock(); scripts.append(script); lock.unlock() }
        model.terminalBridge.postKey = { key, _ in lock.lock(); keys.append(key); lock.unlock() }
        let session = TerminalSession(tab: tab(lines(screen), agent: agent), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        return (model, session, { lock.lock(); defer { lock.unlock() }; return scripts }, { lock.lock(); defer { lock.unlock() }; return keys })
    }

    private func answer(_ model: AppModel, _ session: TerminalSession, option: Int) -> KeyDelivery? {
        let done = expectation(description: "answered")
        var delivery: KeyDelivery?
        model.answer(try! XCTUnwrap(session.prompt), option: option, on: session) { delivery = $0; done.fulfill() }
        wait(for: [done], timeout: 3)
        return delivery
    }

    /// What must never be in an answer's script: anything that brings Terminal or the tab forward.
    private func assertNothingComesForward(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] {
            XCTAssertFalse(script.contains(word), "«\(word)» in \(script)", file: file, line: line)
        }
    }

    // MARK: - The bytes

    func testAnAnswerIsTheArrowsAsEscapeSequencesThenTerminalsReturn() {
        XCTAssertEqual(TerminalAppBridge.answerAction([.down, .down, .enter]), #"do script ((character id 27) & "[B" & (character id 27) & "[B") in t"#)
        XCTAssertEqual(TerminalAppBridge.answerAction([.up, .enter]), #"do script ((character id 27) & "[A") in t"#)
        XCTAssertEqual(TerminalAppBridge.answerAction([.enter]), TerminalAppBridge.returnAction, "The highlighted option: the lone Return, as before.")
        XCTAssertNil(TerminalAppBridge.answerAction([.down, .down]), "A text field is reached, never confirmed: no Return may follow.")
        XCTAssertNil(TerminalAppBridge.answerAction([]))
        XCTAssertNil(TerminalAppBridge.answerAction([.tab, .enter]))
        XCTAssertNil(TerminalAppBridge.answerAction([.escape]))
        XCTAssertNil(TerminalAppBridge.answerAction([.enter, .enter]), "One Enter, the last key, and only Terminal's own.")
        XCTAssertNotNil(TerminalAppBridge.answerAction(Array(repeating: .down, count: TerminalAppBridge.answerArrowLimit) + [.enter]))
        XCTAssertNil(TerminalAppBridge.answerAction(Array(repeating: .down, count: TerminalAppBridge.answerArrowLimit + 1) + [.enter]))
    }

    /// The expression `do script` writes is exactly what a terminal sends for the arrows: ESC [ B for ↓, ESC [ A for ↑ (not
    /// the application-cursor form ESC O B). AppleScript evaluates it here without Terminal.
    func testTheAnswerTextIsTheBytesATerminalSendsForTheArrows() throws {
        let down = try XCTUnwrap(TerminalAppBridge.answerText([.down, .down, .down, .enter]))
        XCTAssertEqual(try TerminalAppBridge.execute("return " + down).stringValue, "\u{1B}[B\u{1B}[B\u{1B}[B")
        let up = try XCTUnwrap(TerminalAppBridge.answerText([.up, .enter]))
        XCTAssertEqual(try TerminalAppBridge.execute("return " + up).stringValue, "\u{1B}[A")
        XCTAssertEqual(try TerminalAppBridge.execute("return " + XCTUnwrap(TerminalAppBridge.answerText([.enter]))).stringValue ?? "", "")
    }

    func testTheAnswerScriptCompilesWithTerminalsDictionary() throws {
        let action = try XCTUnwrap(TerminalAppBridge.answerAction([.up, .up, .enter]))
        var details: NSDictionary?
        let source = TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: action)
        XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
    }

    // MARK: - Answering from the card

    func testChoosingAnOptionIsOneWriteThatBringsNothingForwardAndNeedsNoAccessibility() throws {
        let (model, session, scripts, keys) = rig(permission)
        XCTAssertEqual(answer(model, session, option: 2), .sent)
        XCTAssertEqual(keys(), [], "No key event: Accessibility is off and nothing was refused.")
        XCTAssertEqual(scripts().count, 1, "Arrows and Enter in one script.")
        let script = try XCTUnwrap(scripts().first)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B" & (character id 27) & "[B") in t"#), script)
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys090" then"#), "Addressed to the tab by its TTY.")
        assertNothingComesForward(script)
        XCTAssertNil(model.notice)
        XCTAssertTrue(session.answering, "The card stays quiet until the screen shows the result.")
    }

    func testTickingABoxOfAMultipleChoiceQuestionGoesUpInOneWrite() throws {
        let (model, session, scripts, keys) = rig(platforms)
        XCTAssertEqual(session.prompt?.multiSelect, true)
        XCTAssertEqual(answer(model, session, option: 0), .sent)
        XCTAssertEqual(keys(), [])
        XCTAssertEqual(scripts().count, 1)
        XCTAssertTrue(scripts()[0].contains(#"do script ((character id 27) & "[A" & (character id 27) & "[A") in t"#), "From Linux up to macOS, then Enter ticks it.")
        assertNothingComesForward(scripts()[0])
    }

    func testAQuestionOfSeveralAndCodexAnswerTheSameWay() throws {
        let (model, session, scripts, _) = rig(cache)
        XCTAssertEqual(answer(model, session, option: 1), .sent)
        XCTAssertTrue(scripts().last?.contains(#"do script ((character id 27) & "[B") in t"#) == true)
        let (codexModel, codexSession, codexScripts, codexKeys) = rig(codex, agent: "codex")
        XCTAssertEqual(codexSession.agent, .codex)
        XCTAssertEqual(answer(codexModel, codexSession, option: 1), .sent)
        XCTAssertEqual(codexKeys(), [])
        XCTAssertEqual(codexScripts().count, 1)
        XCTAssertTrue(codexScripts()[0].contains(#"do script ((character id 27) & "[B") in t"#))
        assertNothingComesForward(codexScripts()[0])
    }

    func testTheArrowsAreCountedFromTheScreenOfThatMoment() throws {
        let (model, session, scripts, _) = rig(permission)
        let card = try XCTUnwrap(session.prompt)
        // The user moved the highlight at the terminal after the card was drawn: the same dialog, one row further.
        let moved = lines(permission).replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and")
        session.update(tab(moved))
        XCTAssertEqual(session.prompt?.signature, card.signature)
        let done = expectation(description: "answered")
        model.answer(card, option: 2, on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(scripts().count, 1)
        XCTAssertTrue(scripts()[0].contains(#"do script ((character id 27) & "[B") in t"#), "One arrow from where the highlight is now, not two.")
    }

    func testAChangedDialogIsRefusedWithNothingWritten() throws {
        let (model, session, scripts, keys) = rig(permission)
        let card = try XCTUnwrap(session.prompt)
        session.update(tab(lines(cache)))
        let refused = expectation(description: "refused")
        model.answer(card, option: 2, on: session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(scripts().count + keys().count, 0)
        XCTAssertFalse(session.answering)
    }

    /// Sample, 9/10: choosing "Type something." brought Terminal forward (its arrows were key events) and left him typing there.
    /// No option needs a key event any more: a text field takes its arrows with the answer's text, in one write
    /// (`DialogFieldAnswerTests`), and choosing it on the card sends nothing at all.
    func testNoOptionNeedsKeyEventsAndATextFieldGetsNoKeyOnItsOwn() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(cache)))
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .down], "A field is reached, never confirmed, by these keys alone.")
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 2), "Type something: no Accessibility, no Terminal in front.")
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 0), "The highlighted option: the lone Return.")
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 1))
        XCTAssertFalse(prompt.needsDirectKeys(choosing: 3), "Chat about this: three arrows and Enter, one write.")
        let highlighted = lines(cache).replacingOccurrences(of: "❯ 1. Redis", with: "  1. Redis").replacingOccurrences(of: "  3. Type something.", with: "❯ 3. Type something.")
        XCTAssertFalse(try XCTUnwrap(AgentPrompt.parse(highlighted)).needsDirectKeys(choosing: 2))

        let (model, session, scripts, keys) = rig(cache, keysAllowed: true)
        XCTAssertEqual(answer(model, session, option: 2), .sent, "The card's part is done: the composer takes the answer.")
        settle(0.15)
        XCTAssertEqual(keys(), [], "No key event, though Accessibility is on.")
        XCTAssertEqual(scripts(), [], "Nothing written: no arrow, no Return, nothing brought forward.")
        XCTAssertEqual(model.fieldAnswer(for: session)?.option, 2, "The next message from the composer answers that field.")
    }

    func testMoreArrowsThanTheLimitAreNotOneWrite() {
        let bridge = TerminalAppBridge()
        var scripts: [String] = []
        bridge.runScript = { scripts.append($0) }
        let session = TerminalSession(tab: tab(lines(permission)), backend: .bundled, bridge: bridge)
        let tooMany = Array(repeating: TerminalKey.down, count: TerminalAppBridge.answerArrowLimit + 1) + [.enter]
        XCTAssertFalse(session.choose(tooMany) { _ in XCTFail("Nothing is sent") })
        XCTAssertFalse(bridge.answer(tooMany, windowID: 1, tty: "/dev/ttys090") { _ in XCTFail("Nothing is sent") })
        XCTAssertFalse(session.choose([.down, .down]) { _ in XCTFail("Nothing is sent") }, "A text field keeps the keys.")
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(scripts, [])
    }

    @MainActor
    func testATmuxSessionNeverTakesTheTerminalWrite() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-answer-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-answer-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        XCTAssertFalse(session.choose([.down, .enter]) { _ in XCTFail("tmux presses its keys one by one") })
    }

    // MARK: - Giving the keyboard back

    /// A bridge whose Terminal is pid 4242 and comes to the front with the script that shows the tab, as the real one does.
    private final class FocusRig {
        let bridge = TerminalAppBridge()
        private let lock = NSLock()
        private var _front: pid_t
        private var _log: [String] = []
        var island: Bool
        var returned: [KeyFocus] = []
        var front: pid_t {
            get { lock.lock(); defer { lock.unlock() }; return _front }
            set { lock.lock(); _front = newValue; lock.unlock() }
        }
        var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
        func record(_ entry: String) { lock.lock(); _log.append(entry); lock.unlock() }

        init(front: pid_t, island: Bool, delay: TimeInterval = 0.05, fails: Bool = false) {
            _front = front; self.island = island
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.focusReturnDelay = delay
            bridge.runScript = { [unowned self] script in
                if script.contains("activate") { self.front = 4242 }
                self.record("guion")
                if fails { throw TerminalBridgeError.failed("Terminal no mostró la pestaña elegida; no se envió la tecla.") }
            }
            bridge.postKey = { [unowned self] key, pid in self.record("tecla \(key.rawValue) → \(pid)") }
            bridge.currentFocus = { [unowned self] in KeyFocus(app: self.front, island: self.island) }
            bridge.returnFocus = { [unowned self] focus in self.returned.append(focus); self.record("foco → \(focus.app)") }
        }

        /// Presses `keys` one after another, each once the previous one is in, as a sequence of an answer does.
        func press(_ keys: [TerminalKey], then done: @escaping () -> Void) {
            guard let key = keys.first else { done(); return }
            bridge.press(key, windowID: 1, tty: "/dev/ttys090") { [unowned self] _ in self.press(Array(keys.dropFirst()), then: done) }
        }
    }

    private func settle(_ seconds: Double) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    func testAfterABurstOfKeysTheKeyboardGoesBackOnceToTheAppThatWasInFront() {
        let rig = FocusRig(front: 777, island: true, delay: 0.2)
        let pressed = expectation(description: "pressed")
        rig.press([.down, .down, .escape]) { pressed.fulfill() }
        wait(for: [pressed], timeout: 3)
        XCTAssertEqual(rig.returned, [], "Not between the keys of a burst, nor right after the last one: Terminal must read it first.")
        settle(0.4)
        XCTAssertEqual(rig.returned, [KeyFocus(app: 777, island: true)], "Once, to the app and the island that had the keyboard.")
        XCTAssertEqual(rig.log, ["guion", "tecla down → 4242", "guion", "tecla down → 4242", "guion", "tecla escape → 4242", "foco → 777"])
    }

    func testQuickTapsOnTheKeyStripGiveTheKeyboardBackOnce() {
        let rig = FocusRig(front: ProcessInfo.processInfo.processIdentifier, island: true, delay: 0.3)
        for (index, key) in [TerminalKey.down, .down, .up].enumerated() {
            let pressed = expectation(description: "tap \(index)")
            rig.bridge.press(key, windowID: 1, tty: "/dev/ttys090") { _ in pressed.fulfill() }
            wait(for: [pressed], timeout: 2)
            settle(0.1)
        }
        XCTAssertEqual(rig.returned, [], "Each tap came before the keyboard went back: Terminal stayed in front for all of them.")
        settle(0.45)
        XCTAssertEqual(rig.returned, [KeyFocus(app: ProcessInfo.processInfo.processIdentifier, island: true)], "Back to Nook, once.")
    }

    func testNothingGoesBackWhenTerminalWasAlreadyInFront() {
        let rig = FocusRig(front: 4242, island: false)
        let pressed = expectation(description: "pressed")
        rig.press([.tab]) { pressed.fulfill() }
        wait(for: [pressed], timeout: 3)
        settle(0.2)
        XCTAssertEqual(rig.returned, [], "Terminal stays where the user had it.")
    }

    func testTheIslandTakesTheKeyboardBackWhenTerminalWasInFront() {
        let rig = FocusRig(front: 4242, island: true)
        let pressed = expectation(description: "pressed")
        rig.press([.left]) { pressed.fulfill() }
        wait(for: [pressed], timeout: 3)
        settle(0.2)
        XCTAssertEqual(rig.returned, [KeyFocus(app: 4242, island: true)], "Only the island's keyboard: Terminal stays the app in front.")
    }

    func testNothingGoesBackWhenTheUserMovedToAnotherApp() {
        let rig = FocusRig(front: 777, island: false)
        let pressed = expectation(description: "pressed")
        rig.press([.backtab]) { pressed.fulfill() }
        wait(for: [pressed], timeout: 3)
        rig.front = 888   // the user clicked another app meanwhile
        settle(0.2)
        XCTAssertEqual(rig.returned, [], "The user's own move wins.")
    }

    func testAFailedKeyStillGivesTheKeyboardBack() {
        let rig = FocusRig(front: 777, island: false, fails: true)
        let failed = expectation(description: "failed")
        rig.bridge.press(.escape, windowID: 1, tty: "/dev/ttys090") { XCTAssertEqual($0, .failed); failed.fulfill() }
        wait(for: [failed], timeout: 3)
        settle(0.2)
        XCTAssertEqual(rig.returned, [KeyFocus(app: 777, island: false)], "Terminal came forward before the check failed.")
        XCTAssertFalse(rig.log.contains { $0.hasPrefix("tecla") })
    }

    func testAKeyWithoutThePermissionLeavesTheKeyboardAlone() {
        let rig = FocusRig(front: 777, island: true)
        rig.bridge.directKeysAllowed = { false }
        var asked = false
        rig.bridge.currentFocus = { asked = true; return nil }
        let refused = expectation(description: "refused")
        rig.bridge.press(.down, windowID: 1, tty: "/dev/ttys090") { XCTAssertEqual($0, .needsPermission); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        settle(0.15)
        XCTAssertFalse(asked)
        XCTAssertEqual(rig.returned, [])
        XCTAssertEqual(rig.log, [])
    }

    /// Enter alone is `do script ""`: Terminal never comes forward, so there is nothing to give back.
    func testEnterAloneLeavesTheKeyboardAlone() {
        let rig = FocusRig(front: 777, island: true)
        let pressed = expectation(description: "pressed")
        rig.bridge.press(.enter, windowID: 1, tty: "/dev/ttys090") { XCTAssertEqual($0, .sent); pressed.fulfill() }
        wait(for: [pressed], timeout: 2)
        settle(0.15)
        XCTAssertEqual(rig.returned, [])
        XCTAssertEqual(rig.front, 777)
    }

    /// The model's own wiring: without the island (no controller, as in every test) nothing is ever activated.
    func testTheModelGivesTheKeyboardBackOnlyThroughItsIsland() {
        let model = AppModel(receivesSignals: false)
        XCTAssertNotEqual(model.terminalBridge.currentFocus()?.island, true, "No controller: the island never counts as having the keyboard.")
        model.terminalBridge.returnFocus(KeyFocus(app: 1, island: true))   // a no-op without the controller
    }
}
