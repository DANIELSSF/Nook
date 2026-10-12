import XCTest
@testable import Nook

/// ⇧⇥ from Nook's mode chip: Claude's own key for its permission modes, sent the way the other keys go.
final class ClaudeModeCycleTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)

    private func tab(_ lines: [String], processes: [String] = ["login", "-zsh", "claude"]) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 7, windowTitle: "app", index: 1, tty: "/dev/ttys009", customTitle: "", processes: processes, busy: false, selected: true,
                            text: lines.joined(separator: "\n"))
    }

    func testShiftTabIsItsOwnKeyAndNoRowShowsIt() {
        XCTAssertEqual(TerminalKey.backtab.tmuxName, "BTab")
        XCTAssertEqual(TerminalKey.backtab.keyCode, TerminalKey.tab.keyCode)
        XCTAssertEqual(TerminalKey.backtab.modifiers, .maskShift, "Tab with Shift, and only Shift.")
        XCTAssertEqual(TerminalKey.tab.modifiers, [], "Plain Tab never carries Shift.")
        XCTAssertTrue(TerminalKey.backtab.needsDirectKeys, "do script always adds a Return: the key goes as a key event.")
        XCTAssertFalse(TerminalKey.menuKeys.contains(.backtab))
        XCTAssertFalse(TerminalKey.panelKeys.contains(.backtab))
    }

    /// A model whose Terminal transport records what it would do, with one Claude tab.
    private func recordingModel(keysAllowed: Bool = true, processes: [String] = ["login", "-zsh", "claude"]) -> (AppModel, TerminalSession, () -> [String], () -> [TerminalKey]) {
        let model = AppModel(receivesSignals: false)
        let lock = NSLock()
        var scripts: [String] = [], keys: [TerminalKey] = []
        model.terminalBridge.directKeysAllowed = { keysAllowed }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { script in lock.lock(); scripts.append(script); lock.unlock() }
        model.terminalBridge.postKey = { key, _ in lock.lock(); keys.append(key); lock.unlock() }
        let session = TerminalSession(tab: tab(["⏺ Hola", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"], processes: processes),
                                      backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        return (model, session, { lock.lock(); defer { lock.unlock() }; return scripts }, { lock.lock(); defer { lock.unlock() }; return keys })
    }

    func testCyclingTheModePressesShiftTabInClaudesTab() {
        let (model, session, scripts, keys) = recordingModel()
        XCTAssertEqual(session.agentMode?.kind, .auto)
        model.cycleMode(on: session)
        let sent = expectation(description: "key posted")
        DispatchQueue.global().async { while keys().isEmpty { usleep(5_000) }; sent.fulfill() }
        wait(for: [sent], timeout: 3)
        XCTAssertEqual(keys(), [.backtab])
        XCTAssertTrue(scripts().first?.contains("frontmost") == true, "Only once Terminal shows that very tab, like every other key.")
        XCTAssertFalse(scripts().contains { $0.contains("do script") }, "Never through do script: its Return would send Claude's box.")
    }

    func testCyclingNeedsClaudeRunningInTheTab() {
        var pressed: [TerminalKey] = []
        let (model, session, _, _) = recordingModel(processes: ["login", "-zsh"])
        model.keySender = { key, _ in pressed.append(key) }
        model.cycleMode(on: session)
        XCTAssertTrue(pressed.isEmpty, "A shell has no modes: ⇧⇥ would reach whatever runs there.")
        let (claudeModel, claude, _, _) = recordingModel()
        claudeModel.keySender = { key, _ in pressed.append(key) }
        claude.isRunning = false
        claudeModel.cycleMode(on: claude)
        XCTAssertTrue(pressed.isEmpty, "A tab that is gone gets nothing.")
        claude.isRunning = true
        claudeModel.cycleMode(on: claude)
        XCTAssertEqual(pressed, [.backtab])
    }

    func testWithoutAccessibilityTheKeyAsksForItInsteadOfPressing() {
        // `AppModel.handle` answers `.needsPermission` with Nook's explanation and the way to Settings (an alert, not run here).
        let (model, session, scripts, keys) = recordingModel(keysAllowed: false)
        var result: KeyDelivery?
        // The session holds its bridge weakly: the model that owns it must outlive the press.
        withExtendedLifetime(model) { session.press(.backtab) { result = $0 } }
        XCTAssertEqual(result, .needsPermission)
        XCTAssertTrue(keys().isEmpty)
        XCTAssertTrue(scripts().isEmpty, "Terminal isn't even brought forward.")
    }

    func testAModeChangeShowsOnTheNextReading() {
        let (_, session, _, _) = recordingModel()
        session.update(tab(["⏺ Hola", rule, "❯ ", rule, "  ⏸ plan mode on (shift+tab to cycle)"]))
        XCTAssertEqual(session.agentMode?.kind, .plan)
        session.update(tab(["⏺ Hola", rule, "❯ ", rule, "  ? for shortcuts"]))
        XCTAssertEqual(session.agentMode?.isDefault, true)
    }
}
