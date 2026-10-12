import AppKit
import XCTest
@testable import Nook

/// QA additions for answering a dialog's text field and for the panels' Spaces: a dialog with tabs, an answer that carries the bracketed-paste
/// marks, a transport that fails after the screen was read, and a controller that is let go of while its checks are pending. Every transport is
/// a recorder and every screen a fixture; nothing reaches Terminal, the keyboard or the user's logs.
final class FieldAnswerEdgeTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)

    /// The first question of a dialog with two, its tabs on top (Claude Code draws the open tab in colour: plain text shows only which are answered).
    private let firstTab = [" ←  ☐ Database  ☐ Cache  ✔ Submit  →", "", "Which database should we use?", "",
                            "❯ 1. PostgreSQL", "  2. SQLite", "  3. Type something.", "  ", "  4. Chat about this", "",
                            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
    /// Claude moved on to the second question once the first had its answer.
    private let secondTab = [" ←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Which cache should we put in front of it?", "",
                             "❯ 1. Redis", "  2. Memcached", "  3. Type something.", "  ", "  4. Chat about this", "",
                             "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]

    func testAnAnswerInADialogWithTabsEndsWhenClaudeMovesToTheNextQuestion() throws {
        let first = try XCTUnwrap(AgentPrompt.parse(lines(firstTab)))
        XCTAssertEqual(first.tabs.count, 3)
        XCTAssertEqual(first.options[2].input, .inline)
        let lock = NSLock()
        var steps: [TerminalAppBridge.FieldStep] = []
        try TerminalAppBridge.answerField("Usa MongoDB", option: 2, expecting: first.signature, agent: .claude, withReturn: true, timing: timing,
                                          send: { lock.lock(); steps.append($0); lock.unlock() },
                                          read: { lock.lock(); defer { lock.unlock() }; return self.lines(steps.isEmpty ? self.firstTab : self.secondTab) })
        XCTAssertEqual(steps, [.answer(arrows: [.down, .down], text: "Usa MongoDB")], "The next tab's own field is never written into.")
    }

    /// The second question looks like the first (same options): only its question and tabs differ. It must not count as the same dialog.
    func testTheNextTabIsAnotherDialogEvenWithTheSameOptions() throws {
        let first = try XCTUnwrap(AgentPrompt.parse(lines(firstTab)))
        let next = try XCTUnwrap(AgentPrompt.parse(lines(secondTab)))
        XCTAssertNotEqual(first.signature, next.signature)
        XCTAssertThrowsError(try TerminalAppBridge.answerField("x", option: 2, expecting: first.signature, agent: .claude, withReturn: true, timing: timing,
                                                               send: { _ in XCTFail("Nothing may be written into another question's field.") },
                                                               read: { self.lines(self.secondTab) })) {
            XCTAssertEqual($0 as? TerminalAppBridge.FieldAnswerError, .changed)
        }
    }

    // MARK: - What travels

    /// An answer that carries Claude's end-of-paste mark (typed or pasted by the user) must not close the paste early: the Esc goes, and what is left
    /// is text. The script has exactly one closing mark, and no raw control character at all.
    func testAnAnswerCarryingThePasteEndMarkCannotClosePasteEarly() throws {
        let hostile = "ok\u{1B}[201~\r\u{1B}[200~ rm -rf ~\u{03}\u{7F}\u{9B}31m fin"
        let script = try XCTUnwrap(TerminalAppBridge.fieldAnswerText(arrows: [.down], text: hostile))
        for scalar in script.unicodeScalars where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
            XCTFail("Raw control character U+\(String(scalar.value, radix: 16)) in the script")
        }
        XCTAssertEqual(script.components(separatedBy: #"(character id 27) & "[201~""#).count - 1, 1, script)
        XCTAssertEqual(script.components(separatedBy: #"(character id 27) & "[200~""#).count - 1, 1, script)
        XCTAssertTrue(script.hasSuffix(#"(character id 27) & "[201~")"#), "The closing mark is the last thing written.")
    }

    func testALongOrMultiLineAnswerIsOneLineInsideOnePaste() throws {
        let long = (1...40).map { "línea \($0) con acentos áéíóú y emoji 🙂" }.joined(separator: "\n\n")
        let clean = TerminalAppBridge.fieldText(long)
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertTrue(clean.hasPrefix("línea 1 con acentos áéíóú y emoji 🙂 línea 2"))
        let script = try XCTUnwrap(TerminalAppBridge.fieldAnswerText(arrows: [.down, .down], text: long))
        XCTAssertFalse(script.contains("\\n"), "No line break inside the paste: each would be a Return.")
        XCTAssertTrue(script.contains(clean))
    }

    // MARK: - A transport that fails after the screen was read

    func testAWriteThatFailsGivesNothingBackAsSentAndKeepsTheFieldChosen() throws {
        let screen = lines(["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                            "❯ 1. PostgreSQL", "  2. SQLite", "  3. Type something.", rule, "  4. Chat about this", "",
                            "Enter to select · ↑/↓ to navigate · Esc to cancel"])
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: screen)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        model.terminalBridge.directKeysAllowed = { true }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.fieldTiming = timing
        model.terminalBridge.fieldJournal = { _ in }
        model.terminalBridge.screenReader = { _, _ in screen }
        model.terminalBridge.runScript = { _ in throw Boom() }
        model.terminalBridge.postKey = { _, _ in XCTFail("No key event may be posted.") }
        model.sessions = [session]; model.selectedID = session.id
        let card = try XCTUnwrap(session.prompt)
        let chosen = expectation(description: "chosen")
        model.answer(card, option: 2, on: session) { XCTAssertEqual($0, .sent); chosen.fulfill() }
        wait(for: [chosen], timeout: 1)
        let done = expectation(description: "sent")
        XCTAssertTrue(model.sendToField("Usa MongoDB", on: session) { XCTAssertFalse($0, "A failed write is no delivery: the composer gets its text back."); done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(model.notice, "The model says why.")
        XCTAssertFalse(session.answering); XCTAssertFalse(session.sending)
        XCTAssertNotNil(session.chosenField, "The user can fix the text and send again.")
    }
}

/// The panels' Spaces when the controller that watches them is let go of.
@MainActor
final class SpaceControllerLifetimeTests: XCTestCase {
    private final class CountingBackend: SpaceBackend {
        var isAvailable = true
        private(set) var calls = 0
        func spaces(of windowNumber: Int) -> [UInt64] { calls += 1; return [] }
        func displaySpaces() -> [[UInt64]] { calls += 1; return [] }
        func add(_ windowNumber: Int, to spaces: [UInt64]) { calls += 1 }
    }

    /// A pending series of checks, a wake and a swipe after the controller is gone must neither crash nor reach WindowServer on its behalf.
    func testNotificationsAndPendingChecksAfterTheControllerIsReleasedDoNothing() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let original = SpaceMembership.shared
        let backend = CountingBackend()
        SpaceMembership.shared = SpaceMembership(backend: backend)
        defer { SpaceMembership.shared = original }
        let center = NotificationCenter()
        weak var released: NotchController?
        autoreleasepool {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-spaces-life-" + UUID().uuidString)!)
            let controller = NotchController(model: model, quiet: true, workspace: center)
            released = controller
            controller.checkSpacesSoon(reason: "prueba", delays: [0.05, 0.15])
            controller.panel.orderOut(nil); controller.petPanel.orderOut(nil)
            model.controller = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard released == nil else { throw XCTSkip("The controller is still alive (held by its own windows); nothing to check after its release.") }
        let before = backend.calls
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(backend.calls, before)
    }
}
