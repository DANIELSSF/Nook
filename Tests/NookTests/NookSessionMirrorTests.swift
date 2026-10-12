import XCTest
@testable import Nook

/// A Nook session (tmux) with Claude or Codex running in it shows the agent's conversation like a Terminal tab does: the agent is
/// found among the pane's foreground processes and its screen goes through the same parts. A shell keeps the terminal on show.
final class NookSessionMirrorTests: XCTestCase {
    private func session(kind: SessionKind = .shell) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-mirror-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-mirror-" + UUID().uuidString.prefix(6), name: kind.title, kind: kind, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        return TerminalSession(record: record, backend: backend, create: false)
    }

    func testTheForegroundCommandsComeFromTheirArgumentsInOrder() {
        // Claude's native binary is named after its version; its arguments still say "claude". A background job is not foreground.
        let ps = """
         6791 Ss   /bin/zsh -l
         7194 S+   npm exec chrome-devtools-mcp@latest
         7177 S+   claude --name ui-designer
         7300 S    sleep 100
        """
        let commands = TerminalSession.foregroundCommands(ps: ps)
        XCTAssertEqual(commands, ["claude --name ui-designer", "npm exec chrome-devtools-mcp@latest"])
        XCTAssertEqual(TerminalAgent(processes: commands), .claude)
        XCTAssertNil(TerminalAgent(processes: TerminalSession.foregroundCommands(ps: " 6791 Ss+  /bin/zsh -l")), "A shell at its prompt has no agent.")
    }

    func testClaudeInANookSessionIsMirroredWithoutItsBoxAndAShellIsNot() {
        let session = session()
        XCTAssertFalse(session.mirrorsAgent, "A plain shell shows its terminal.")
        let rule = String(repeating: "─", count: 62)
        let screen = ["⏺ Listo, revisé el archivo.", "", "✶ Warping… (3m 24s · thinking with max effort)", "",
                      String(repeating: "─", count: 48) + " ui-designer ─", "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt"].joined(separator: "\n")
        session.applyPane(tty: "/dev/ttys003", processes: ["claude --name ui-designer"], text: screen)
        XCTAssertEqual(session.agent, .claude)
        XCTAssertTrue(session.mirrorsAgent)
        XCTAssertEqual(session.agentTTY, "/dev/ttys003", "Claude's record is looked up by the pane's device.")
        XCTAssertEqual(session.displayText, "⏺ Listo, revisé el archivo.", "No box, status or mode line in the mirror.")
        XCTAssertEqual(session.agentInput, "")
        XCTAssertEqual(session.agentStatus?.working, true)
        XCTAssertNil(session.panel)

        // Claude quits: the shell's terminal is on show again.
        session.applyPane(tty: "/dev/ttys003", processes: ["/bin/zsh -l"], text: nil)
        XCTAssertNil(session.agent)
        XCTAssertFalse(session.mirrorsAgent)
    }
}

/// The effort control reads Claude's level from its screen and sets it with the command, never through Claude's slider.
final class ClaudeEffortTests: XCTestCase {
    func testTheLevelComesFromWhatClaudeLastSaid() {
        XCTAssertEqual(ClaudeEffort.reported(in: "✶ Warping… (3m 24s · thinking with max effort)"), .max)
        XCTAssertEqual(ClaudeEffort.reported(in: "  ⎿  Set effort level to xhigh (saved as your default for new sessions)"), .xhigh)
        XCTAssertEqual(ClaudeEffort.reported(in: "⎿ Set effort level to low\n…\n✶ Baking… (2s · thinking with high effort)"), .high, "The newest report wins.")
        XCTAssertNil(ClaudeEffort.reported(in: "⏺ Habla de effort en general, sin nivel."))
        XCTAssertNil(ClaudeEffort.reported(in: "thinking with great effort"), "Only Claude's own levels.")
        XCTAssertEqual(ClaudeEffort.xhigh.command, "/effort xhigh")
    }

    func testASessionKeepsItsLevelUntilClaudeReportsAnother() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-effort-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-effort-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: "/dev/ttys004", processes: ["claude"], text: "⏺ Hola\n✶ Warping… (3s · thinking with max effort)")
        XCTAssertEqual(session.effort, .max)
        session.applyPane(tty: "/dev/ttys004", processes: ["claude"], text: "⏺ Hola\n✻ Baked for 3s")
        XCTAssertEqual(session.effort, .max, "A screen that says nothing about it keeps the last level.")
        session.applyPane(tty: "/dev/ttys004", processes: ["/bin/zsh -l"], text: nil)
        XCTAssertNil(session.effort, "Another Claude may start with another level.")
    }
}

/// A turn that ends in the tab the user is looking at raises no alert, but it does end.
final class FrontTabTurnTests: XCTestCase {
    func testAFinishedTurnInTheFrontTabIsNoLongerWorking() {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-front-" + UUID().uuidString)!)
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-front-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-front-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        model.sessions = [session]; model.selectedID = session.id; model.expanded = true
        session.taskState = .working
        model.raiseAlert(.finished, for: session, message: "Claude terminó su respuesta.")
        XCTAssertEqual(session.taskState, .idle)
        XCTAssertNil(session.unreadNotice, "No bell for the tab on screen.")
        XCTAssertNil(model.alert)
    }
}
