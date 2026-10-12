import AppKit
import XCTest
@testable import Nook

/// QA gap-fill for the `busy` guard (`TerminalAppBridge.busyGuard`) on every kind of dialog answer written to a Terminal tab, and its
/// absence from the writes that are not answers (a composer message, Terminal's own Return). Transports are recorders; nothing reaches
/// Terminal, a real session or the keyboard.
final class AnswerGuardCoverageTests: XCTestCase {
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    private let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                              " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                              "   3. No, and tell Claude what to do differently (esc)"]
    private let platforms = [" ☐ Platforms", "", "Which platforms should the release support?", "",
                             "  1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "❯ 3. [ ] Linux", "  4. Type something.", "  5. Submit", "",
                             "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    private let codex = ["  Would you like to run the following command?", "", "  Reason: needs network access", "", "  $ git push origin main", "",
                         "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for this command (p)", "  3. No, and tell Codex what to do differently (esc)",
                         "", "  Press enter to confirm or esc to cancel"]

    private func tab(_ text: String, agent: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["login", "-zsh", agent], busy: true, selected: true, text: text)
    }

    private func written(_ screen: [String], agent: String, option: Int) throws -> [String] {
        let model = AppModel(receivesSignals: false)
        let lock = NSLock()
        var scripts: [String] = []
        model.terminalBridge.directKeysAllowed = { false }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { lock.lock(); scripts.append($0); lock.unlock() }
        let session = TerminalSession(tab: tab(lines(screen), agent: agent), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        let done = expectation(description: "answered")
        model.answer(try XCTUnwrap(session.prompt), option: option, on: session) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        lock.lock(); defer { lock.unlock() }
        return scripts
    }

    func testPermissionCodexAndMultiSelectAnswersAreOneGuardedWrite() throws {
        for (screen, agent, option) in [(permission, "claude", 1), (platforms, "claude", 1), (codex, "codex", 2)] {
            let scripts = try written(screen, agent: agent, option: option)
            XCTAssertEqual(scripts.count, 1, "\(agent) option \(option): one write")
            let script = try XCTUnwrap(scripts.first)
            XCTAssertEqual(script.components(separatedBy: TerminalAppBridge.busyGuard).count - 1, 1, "exactly one guard")
            XCTAssertEqual(script.components(separatedBy: "do script").count - 1, 1, "exactly one do script")
            XCTAssertFalse(script.contains("screenNow"), "A plain dialog has no anchors.")
            let guardAt = try XCTUnwrap(script.range(of: TerminalAppBridge.busyGuard)).upperBound
            XCTAssertLessThan(guardAt, try XCTUnwrap(script.range(of: "do script")).lowerBound, "guard before write")
        }
    }

    func testWritesThatAreNotAnswersCarryNoGuard() {
        let message = TerminalAppBridge.targetScript(windowID: 1, tty: "/dev/ttys091", action: TerminalAppBridge.messageAction("hola\nmundo « ñ \"q\" \\", agent: .claude))
        let enter = TerminalAppBridge.targetScript(windowID: 1, tty: "/dev/ttys091", action: TerminalAppBridge.returnAction)
        for script in [message, enter] { XCTAssertFalse(script.contains("busy of t"), script) }
    }

    func testAnswerScriptCompilesWithHostileAnchorsAndTty() {
        let anchors = ["❯ 1. \"Quoted\" \\ back", "línea con ñ y emoji 🐱", String(repeating: "x", count: 2_000)]
        let script = TerminalAppBridge.answerScript(windowID: 7, tty: "/dev/ttys\"1", anchors: anchors, action: "do script \"\" in t")
        var details: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: script)!.compileAndReturnError(&details), details?.description ?? "")
    }

    func testAnswerOutcomeLeavesOtherErrorsAlone() {
        let other = TerminalBridgeError.failed("Terminal ya se cerró. No se envió el mensaje.")
        guard case TerminalBridgeError.failed(let message)? = TerminalAppBridge.answerOutcome(other) as? TerminalBridgeError else { return XCTFail("changed kind") }
        XCTAssertEqual(message, "Terminal ya se cerró. No se envió el mensaje.")
    }
}
