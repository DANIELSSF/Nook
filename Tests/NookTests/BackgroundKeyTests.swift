import AppKit
import XCTest
@testable import Nook

/// Keys to a Terminal tab sent with Terminal left behind, and checked on the tab's screen (`TerminalAppBridge.press`, `KeyEffect`).
/// Terminal here is a model: a front window, a screen the keys change, a clock that only moves when the bridge waits. Nothing
/// reaches the real Terminal, posts a key or moves the real keyboard.
final class BackgroundKeyTests: XCTestCase {
    private static let rule = String(repeating: "─", count: 100)
    private static let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    private static func screen(_ rows: [String]) -> String { rows.joined(separator: "\n") }
    private static func box(_ footer: String = footer) -> [String] { [rule, "❯ ", rule, footer] }

    /// Claude at work, with the ■ the island shows; then stopped by Esc; and a reading caught mid-redraw, without its box.
    private static let working = screen(["⏺ Hola", "", "> recomendado", "", "✻ Churning… (2s · esc to interrupt)"] + box())
    private static let interrupted = screen(["⏺ Hola", "", "> recomendado", "  ⎿  Interrupted · What should Claude do instead?", ""] + box())
    private static let torn = screen(["⏺ Hola", "", "> recomendado", ""])
    private static let idle = screen(["⏺ Hola", "", "> recomendado", "", "⏺ Listo."] + box())
    /// Claude's permission request with option `highlight` (from 0) highlighted.
    private static func permission(_ highlight: Int) -> String {
        let options = ["Yes", "Yes, and don't ask again for rm commands in this project", "No, and tell Claude what to do differently (esc)"]
        return screen(["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "", " Do you want to proceed?"]
                      + options.enumerated().map { index, title in (index == highlight ? " ❯ " : "   ") + "\(index + 1). \(title)" })
    }
    private static let defaultMode = screen(["⏺ Hola", ""] + box("  ? for shortcuts"))
    private static let acceptEdits = screen(["⏺ Hola", ""] + box("  ⏵⏵ accept edits on (shift+tab to cycle)"))
    /// Codex at work, and stopped.
    private static let codexWorking = screen(["• Running the tests", "", "• Working (12s • esc to interrupt)", "", "› Ask Codex to do something", "", "  ⏎ send   ⌃J newline"])
    private static let codexStopped = screen(["• Running the tests", "", "■ Conversation interrupted - tell the model what to do differently", "",
                                              "› Ask Codex to do something", "", "  ⏎ send   ⌃J newline"])

    // MARK: - What each key shows

    func testEscapeWhileClaudeWorksShowsAsItsTurnStopping() throws {
        let shows = try XCTUnwrap(KeyEffect.check(.escape, agent: .claude, before: Self.working))
        XCTAssertTrue(shows(Self.interrupted))
        XCTAssertTrue(shows(Self.idle))
        XCTAssertFalse(shows(Self.working))
        XCTAssertFalse(shows(Self.torn), "A reading without Claude's box doesn't count: the spinner may just not be drawn yet.")
    }

    func testAnArrowShowsAsTheHighlightMoving() throws {
        let down = try XCTUnwrap(KeyEffect.check(.down, agent: .claude, before: Self.permission(0)))
        XCTAssertTrue(down(Self.permission(1)))
        XCTAssertTrue(down(Self.permission(2)), "Any move counts: the key arrived.")
        XCTAssertFalse(down(Self.permission(0)))
        XCTAssertFalse(down(Self.torn), "Without the whole dialog there is no highlight to read.")
        let up = try XCTUnwrap(KeyEffect.check(.up, agent: .claude, before: Self.permission(2)))
        XCTAssertTrue(up(Self.permission(1)))
        XCTAssertNil(KeyEffect.check(.down, agent: .claude, before: Self.idle), "No dialog: nothing would show an arrow.")
    }

    func testEscapeOnADialogShowsAsTheDialogGone() throws {
        let shows = try XCTUnwrap(KeyEffect.check(.escape, agent: .claude, before: Self.permission(1)))
        XCTAssertTrue(shows(Self.interrupted), "The box is back.")
        XCTAssertFalse(shows(Self.permission(1)))
        XCTAssertFalse(shows(Self.permission(2)), "The same dialog, only another highlight.")
        XCTAssertFalse(shows(Self.torn))
    }

    func testEscapeOnClaudesPanelShowsAsThePanelClosing() throws {
        let open = ClaudePanelFixtures.screen(ClaudePanelFixtures.ruled)
        let shows = try XCTUnwrap(KeyEffect.check(.escape, agent: .claude, before: open))
        XCTAssertTrue(shows(ClaudePanelFixtures.closed))
        XCTAssertFalse(shows(open))
    }

    func testShiftTabShowsAsTheModeLineNamingAnotherMode() throws {
        let shows = try XCTUnwrap(KeyEffect.check(.backtab, agent: .claude, before: Self.defaultMode))
        XCTAssertTrue(shows(Self.acceptEdits))
        XCTAssertFalse(shows(Self.defaultMode))
        XCTAssertFalse(shows(Self.torn))
        XCTAssertNil(KeyEffect.check(.backtab, agent: .claude, before: Self.permission(0)), "⇧⇥ never goes to a dialog.")
        XCTAssertNil(KeyEffect.check(.backtab, agent: .codex, before: Self.codexWorking))
    }

    func testCodexStoppingShowsAsItsInterruptHintGone() throws {
        let shows = try XCTUnwrap(KeyEffect.check(.escape, agent: .codex, before: Self.codexWorking))
        XCTAssertTrue(shows(Self.codexStopped))
        XCTAssertFalse(shows(Self.codexWorking))
        XCTAssertFalse(shows(""))
        XCTAssertNil(KeyEffect.check(.escape, agent: .codex, before: Self.codexStopped))
    }

    func testKeysWithNothingSureToShowHaveNoCheck() {
        XCTAssertNil(KeyEffect.check(.escape, agent: .claude, before: Self.idle), "Esc on an idle box may do nothing visible.")
        for key in [TerminalKey.tab, .left, .right, .keyS, .pasteImage, .enter] {
            XCTAssertFalse(KeyEffect.checkable(key), "\(key)")
            XCTAssertNil(KeyEffect.check(key, agent: .claude, before: Self.permission(0)), "\(key)")
        }
        XCTAssertEqual(TerminalKey.allCases.filter(KeyEffect.checkable), [.up, .down, .escape, .backtab])
    }

    // MARK: - The bridge

    /// Terminal as the bridge sees it. A key posted with Terminal in front always arrives; one posted with Terminal behind arrives
    /// as `background` says: at once, only once Terminal comes forward (late, as a busy agent would show it), or never.
    private final class FakeTerminal {
        enum Arrival { case atOnce, whenInFront, never }
        let bridge = TerminalAppBridge()
        private let lock = NSLock()
        private var _screen: String
        private var held: String?
        private var _scripts: [String] = [], _posts: [String] = [], _reports: [KeyAttempt] = []
        private var _front: pid_t
        private var _now: TimeInterval = 1_000
        var windowInFront = true
        var background: Arrival
        var effect: (TerminalKey, String) -> String
        var returned: [KeyFocus] = []

        var screen: String { locked { _screen } }
        var scripts: [String] { locked { _scripts } }
        var posts: [String] { locked { _posts } }
        var reports: [KeyAttempt] { locked { _reports } }
        var outcomes: [KeyAttempt.Outcome] { reports.map(\.outcome) }
        var front: pid_t { locked { _front } }
        var activated: Bool { scripts.contains { $0.contains("activate") } }
        private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

        init(screen: String, background: Arrival = .atOnce, front: pid_t = 777, effect: @escaping (TerminalKey, String) -> String) {
            _screen = screen; self.background = background; _front = front; self.effect = effect
            bridge.backgroundKeys = true
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.focusReturnDelay = 0.2
            bridge.runScript = { [unowned self] script in
                try self.locked {
                    self._scripts.append(script)
                    if script.contains("index of targetWindow is not 1"), !self.windowInFront { throw TerminalBridgeError.failed("La ventana de la pestaña no es la de delante en Terminal.") }
                    if script.contains("activate") {
                        self._front = 4242
                        if let held = self.held { self._screen = held; self.held = nil }
                    }
                }
            }
            bridge.postKey = { [unowned self] key, pid in
                self.locked {
                    let inFront = self._front == 4242
                    self._posts.append("\(key.rawValue)\(inFront ? " (Terminal delante)" : "")")
                    switch inFront ? .atOnce : self.background {
                    case .atOnce: self._screen = self.effect(key, self._screen)
                    case .whenInFront: self.held = self.effect(key, self.held ?? self._screen)
                    case .never: break
                    }
                }
            }
            bridge.screenReader = { [unowned self] _, _ in
                self.locked { self._screen }
            }
            bridge.keyClock = { [unowned self] in self.locked { self._now } }
            bridge.keyPause = { [unowned self] seconds in self.locked { self._now += seconds } }
            bridge.keyReport = { [unowned self] attempt in self.locked { self._reports.append(attempt) } }
            bridge.currentFocus = { [unowned self] in KeyFocus(app: self.front) }
            bridge.returnFocus = { [unowned self] in self.returned.append($0) }
        }

        func press(_ keys: [TerminalKey], agent: TerminalAgent? = .claude, test: XCTestCase) -> [KeyDelivery] {
            var results: [KeyDelivery] = []
            for key in keys {
                let done = test.expectation(description: "\(key)")
                bridge.press(key, windowID: 1, tty: "/dev/ttys090", agent: agent) { results.append($0); done.fulfill() }
                test.wait(for: [done], timeout: 3)
            }
            return results
        }
    }

    private func settle(_ seconds: Double = 0.45) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    private static func stop(_ key: TerminalKey, _ screen: String) -> String { key == .escape && screen == working ? interrupted : screen }
    private static func move(_ key: TerminalKey, _ screen: String) -> String {
        guard let at = (0..<3).first(where: { permission($0) == screen }) else { return screen }
        return permission(min(2, max(0, at + (key == .down ? 1 : key == .up ? -1 : 0))))
    }

    func testTheStopButtonsEscapeGoesWithTerminalBehindWhenTheScreenShowsIt() {
        let terminal = FakeTerminal(screen: Self.working, effect: Self.stop)
        XCTAssertEqual(terminal.press([.escape], test: self), [.sent])
        XCTAssertEqual(terminal.posts, ["escape"], "One key, posted with Terminal behind.")
        XCTAssertEqual(terminal.scripts.count, 1)
        XCTAssertTrue(terminal.scripts[0].contains("index of targetWindow is not 1"))
        XCTAssertFalse(terminal.activated)
        XCTAssertFalse(terminal.scripts[0].contains("set index"), "The window is never raised in the background.")
        XCTAssertEqual(terminal.reports, [KeyAttempt(key: .escape, outcome: .verified, milliseconds: 200)], "Two readings in a row, 0.1 s apart.")
        settle()
        XCTAssertEqual(terminal.returned, [], "Terminal never came forward: the keyboard never moved.")
        XCTAssertEqual(terminal.front, 777)
    }

    func testAKeyTheScreenDoesntShowIsPressedOnceMoreWithTerminalInFront() {
        let terminal = FakeTerminal(screen: Self.working, background: .never, effect: Self.stop)
        XCTAssertEqual(terminal.press([.escape], test: self), [.sent])
        XCTAssertEqual(terminal.posts, ["escape", "escape (Terminal delante)"], "Exactly one more press, with Terminal in front.")
        XCTAssertEqual(terminal.scripts.count, 2)
        XCTAssertTrue(terminal.scripts[1].contains("activate"))
        XCTAssertEqual(terminal.outcomes, [.unverified])
        XCTAssertTrue((1000...1100).contains(terminal.reports[0].milliseconds), "The whole wait: \(terminal.reports[0].milliseconds) ms")
        XCTAssertEqual(terminal.screen, Self.interrupted)
        settle()
        XCTAssertEqual(terminal.returned, [KeyFocus(app: 777)], "The keyboard goes back, as with any key that brought Terminal forward.")
    }

    func testAWindowThatIsntTerminalsFrontOneGoesStraightToTerminalInFront() {
        let terminal = FakeTerminal(screen: Self.working, effect: Self.stop)
        terminal.windowInFront = false
        XCTAssertEqual(terminal.press([.escape], test: self), [.sent])
        XCTAssertEqual(terminal.posts, ["escape (Terminal delante)"], "No key with Terminal behind: it would go to its front window.")
        XCTAssertEqual(terminal.reports.map(\.outcome), [.behind])
        XCTAssertTrue(terminal.reports[0].detail.contains("no es la de delante"))
        XCTAssertTrue(terminal.activated)
        settle()
        XCTAssertEqual(terminal.returned, [KeyFocus(app: 777)])
    }

    func testAKeyThatShowsOnlyOnceTerminalIsInFrontIsNotPressedTwice() {
        let terminal = FakeTerminal(screen: Self.working, background: .whenInFront, effect: Self.stop)
        XCTAssertEqual(terminal.press([.escape], test: self), [.sent])
        XCTAssertEqual(terminal.posts, ["escape"], "It arrived in the background; it is not pressed again.")
        XCTAssertEqual(terminal.outcomes, [.unverified, .late])
        XCTAssertEqual(terminal.screen, Self.interrupted)
    }

    func testABurstWaitsOnlyForItsFirstKey() {
        let terminal = FakeTerminal(screen: Self.permission(0), effect: Self.move)
        XCTAssertEqual(terminal.press([.down, .down, .up], test: self), [.sent, .sent, .sent])
        XCTAssertEqual(terminal.outcomes, [.verified, .trusted, .trusted])
        XCTAssertEqual(terminal.posts, ["down", "down", "up"])
        XCTAssertFalse(terminal.activated)
        XCTAssertEqual(terminal.screen, Self.permission(1))
        settle()
        XCTAssertEqual(terminal.returned, [])
    }

    func testAMissedKeyEndsTheTrust() {
        let terminal = FakeTerminal(screen: Self.permission(0), effect: Self.move)
        _ = terminal.press([.down], test: self)
        terminal.windowInFront = false   // the user raised another Terminal window
        _ = terminal.press([.down], test: self)
        terminal.windowInFront = true
        _ = terminal.press([.up], test: self)
        XCTAssertEqual(terminal.outcomes, [.verified, .behind, .verified], "After a key that couldn't go behind, the next one is checked again.")
    }

    func testAScreenWithNothingSureToShowTheKeyGoesWithTerminalInFront() {
        let terminal = FakeTerminal(screen: Self.idle, effect: { _, screen in screen })
        XCTAssertEqual(terminal.press([.escape], test: self), [.sent])
        XCTAssertEqual(terminal.outcomes, [.unchecked])
        XCTAssertEqual(terminal.posts, ["escape (Terminal delante)"])
    }

    func testKeysWithoutACheckNeverTryTheBackground() {
        let terminal = FakeTerminal(screen: Self.permission(0), effect: Self.move)
        XCTAssertEqual(terminal.press([.tab, .left, .keyS], test: self), [.sent, .sent, .sent])
        XCTAssertEqual(terminal.reports, [])
        XCTAssertEqual(terminal.posts, ["tab (Terminal delante)", "left (Terminal delante)", "keyS (Terminal delante)"])
        XCTAssertFalse(terminal.scripts.contains { $0.contains("index of targetWindow is not 1") })
        settle()
        XCTAssertEqual(terminal.returned, [KeyFocus(app: 777)], "Once, after the burst.")
    }

    func testWithoutTheAppTurningItOnOrWithoutAnAgentEveryKeyGoesAsBefore() {
        let off = FakeTerminal(screen: Self.working, effect: Self.stop)
        off.bridge.backgroundKeys = false
        _ = off.press([.escape], test: self)
        XCTAssertEqual(off.reports, [])
        XCTAssertEqual(off.posts, ["escape (Terminal delante)"])
        let shell = FakeTerminal(screen: Self.working, effect: Self.stop)
        _ = shell.press([.escape], agent: nil, test: self)
        XCTAssertEqual(shell.reports, [])
        XCTAssertEqual(shell.posts, ["escape (Terminal delante)"])
        XCTAssertFalse(TerminalAppBridge().backgroundKeys, "Off by default: tests and previews never read a real screen.")
    }

    func testTheBackgroundScriptCompilesWithTerminalsDictionary() {
        var details: NSDictionary?
        let source = TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: TerminalAppBridge.backgroundKeyAction)
        XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
        XCTAssertFalse(TerminalAppBridge.backgroundKeyAction.contains("activate"))
        XCTAssertFalse(TerminalAppBridge.backgroundKeyAction.contains("set index"))
    }

    func testAnAttemptIsLoggedWithoutAnythingOfTheScreen() {
        // The log line carries the key, the outcome and the time; `log show` reads it (category "keys").
        KeyAttempt(key: .escape, outcome: .verified, milliseconds: 180).log()
        XCTAssertEqual(KeyAttempt.Outcome.unverified.rawValue, "not verified")
        XCTAssertEqual(KeyAttempt.Outcome.late.rawValue, "arrived late")
    }

    // MARK: - From the island

    /// The ■ button: a Claude tab's interrupt is Esc with the agent, so it goes in the background like the key strip's.
    func testTheStopButtonStopsClaudeWithoutBringingTerminalForward() {
        let model = AppModel(receivesSignals: false)
        let terminal = FakeTerminal(screen: Self.working, effect: Self.stop)
        let bridge = model.terminalBridge
        bridge.backgroundKeys = true
        bridge.directKeysAllowed = terminal.bridge.directKeysAllowed
        bridge.terminalProcess = terminal.bridge.terminalProcess
        bridge.runScript = terminal.bridge.runScript
        bridge.postKey = terminal.bridge.postKey
        bridge.screenReader = terminal.bridge.screenReader
        bridge.keyClock = terminal.bridge.keyClock
        bridge.keyPause = terminal.bridge.keyPause
        bridge.keyReport = terminal.bridge.keyReport
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys090", customTitle: "", processes: ["login", "-zsh", "claude"],
                                      busy: true, selected: true, text: Self.working)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: bridge)
        model.sessions = [session]; model.selectedID = session.id
        model.interrupt(session)
        let done = expectation(description: "stopped")
        DispatchQueue.global().async { while terminal.reports.isEmpty { usleep(5_000) }; done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(terminal.outcomes, [.verified])
        XCTAssertEqual(terminal.posts, ["escape"])
        XCTAssertFalse(terminal.activated)
    }

    /// A shell's interrupt is ⌃C written with `do script`: Terminal never comes forward for it, as before.
    func testAShellsInterruptNeverBringsTerminalForward() {
        let model = AppModel(receivesSignals: false)
        var scripts: [String] = []
        var keys: [TerminalKey] = []
        model.terminalBridge.backgroundKeys = true
        model.terminalBridge.runScript = { scripts.append($0) }
        model.terminalBridge.postKey = { key, _ in keys.append(key) }
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["login", "-zsh", "sleep"],
                                      busy: true, selected: true, text: "$ sleep 100")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.interrupt(session)
        settle(0.3)
        XCTAssertEqual(keys, [])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("do script \"\u{03}\" in t"))
        XCTAssertFalse(scripts[0].contains("activate"))
    }
}
