import XCTest
@testable import Nook

/// /effort and /model that worked stay out of Nook's chat (the chips and the banner show them), on the screen and in the
/// record. Errors, other answers and other commands stay. Shapes from Sample's records (Claude Code 2.1.223–2.1.291).
final class ClaudeSettingsEchoTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private func box(_ input: String = "") -> [String] { [rule, "❯ " + input, rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"] }

    // MARK: Screen

    func testARoundTripThatWorkedLeavesTheScreensChat() {
        let screen = ["⏺ Antes.", "", "> /effort max",
                      "  ⎿  Set effort level to max (this session only): Maximum capability with deepest reasoning. May use",
                      "     excessive tokens resulting in long responses.", "", "> hola", "", "⏺ Hola."] + box()
        XCTAssertEqual(ClaudeComposer.split(screen.joined(separator: "\n")).conversation, "⏺ Antes.\n\n> hola\n\n⏺ Hola.")
        XCTAssertEqual(ClaudeEffort.reported(in: screen.joined(separator: "\n")), .max, "The effort is still read from the raw screen.")
    }

    func testTheModelAnswerStillMovesTheBannerButLeavesTheChat() {
        let screen = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app", "",
                      "> /model opus", "  ⎿  Set model to Opus 5.5 and saved as your default for new sessions", "",
                      "❯ /model", "  ⎿  Kept model as Opus 5.5", "", "> /effort", "  ⎿  Cancelled", "", "⏺ Listo."] + box()
        let split = ClaudeComposer.split(screen.joined(separator: "\n"))
        XCTAssertEqual(split.banner?.model, "Opus 5.5")
        XCTAssertEqual(split.conversation.trimmingCharacters(in: .newlines), "⏺ Listo.")
    }

    func testErrorsOtherAnswersAndOtherCommandsStay() {
        let screen = ["> /model foo", "  ⎿  Model 'foo' not found. Run /model to pick one.", "",
                      "> /effort turbo", "  ⎿  Invalid effort level: turbo. Use low, medium, high, xhigh or max.", "",
                      "> /usage", "  ⎿  Set model to nothing here", "",
                      "> /models", "  ⎿  Set model to Opus 5.5", "",
                      "⏺ /model sonnet", "  ⎿  Set model to Sonnet 5.5"] + box()
        let conversation = ClaudeComposer.split(screen.joined(separator: "\n")).conversation
        for kept in ["Model 'foo' not found", "Invalid effort level: turbo", "> /usage", "> /models", "⏺ /model sonnet"] {
            XCTAssertTrue(conversation.contains(kept), kept)
        }
    }

    func testACommandStillInTheBoxOrWithoutAnAnswerStays() {
        // Typed, not sent: the box shows it and Nook's field offers it.
        XCTAssertEqual(ClaudeComposer.split((["⏺ Hola."] + box("/model sonnet")).joined(separator: "\n")).input, "/model sonnet")
        // Sent, the picker still open: the echo stays until Claude answers.
        XCTAssertTrue(ClaudeComposer.split(["⏺ Hola.", "", "> /model", "", " Select model"].joined(separator: "\n")).conversation.contains("> /model"))
        XCTAssertTrue(ClaudeSettingsEcho.isCommand("/effort high"))
        XCTAssertTrue(ClaudeSettingsEcho.isCommand("/model"))
        XCTAssertFalse(ClaudeSettingsEcho.isCommand("/models"))
        XCTAssertFalse(ClaudeSettingsEcho.isCommand("cambia el /model a sonnet"))
    }

    // MARK: Record

    private func record(_ content: String, type: String = "user") -> String {
        let entry: [String: Any] = type == "user" ? ["type": "user", "message": ["role": "user", "content": content]] : ["type": "system", "subtype": "local_command", "content": content]
        return String(data: try! JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
    }
    private func command(_ name: String, _ args: String = "") -> String {
        "<command-name>/\(name)</command-name>\n            <command-message>\(name)</command-message>\n            <command-args>\(args)</command-args>"
    }

    func testTheRecordsRoundTripsThatWorkedLeaveTheChat() {
        var renderer = TranscriptRenderer()
        renderer.consume(record("hola"))
        renderer.consume(record(command("model")))
        renderer.consume(record("<local-command-stdout>Set model to `Fable 5.1` and saved as your default for new sessions</local-command-stdout>"))
        renderer.consume(record(command("effort", "max")))
        renderer.consume(record("<local-command-stdout>Set effort level to max (this session only): Maximum capability with deepest reasoning. May use excessive tokens resulting in long responses.</local-command-stdout>"))
        renderer.consume(record(command("model")))
        renderer.consume(record("<local-command-stdout>Set model to \u{1b}[1mSonnet 5\u{1b}[22m and saved as your default for new sessions</local-command-stdout>"))
        renderer.consume(record(command("effort")))
        renderer.consume(record("<local-command-stdout>Cancelled</local-command-stdout>"))
        renderer.consume(record("sigue"))
        XCTAssertEqual(renderer.text, "> hola\n\n> sigue\n\n")
    }

    func testTheRecordKeepsErrorsAndOtherCommands() {
        var renderer = TranscriptRenderer()
        renderer.consume(record(command("model", "foo")))
        renderer.consume(record("<local-command-stderr>Model 'foo' not found.</local-command-stderr>"))
        renderer.consume(record(command("usage")))
        renderer.consume(record("<local-command-stdout>Current session: 25% used</local-command-stdout>"))
        // An answer that never came: the command shows as it was typed once anything else follows.
        renderer.consume(record(command("effort", "high")))
        renderer.consume(record("y ahora?"))
        XCTAssertEqual(renderer.text, "> /model foo\n  ⎿  Model 'foo' not found.\n\n> /usage\n\n> /effort high\n\n> y ahora?\n\n")
    }

    // MARK: Sending

    func testNoPendingBubbleForASettingsCommand() {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys093", customTitle: "", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: (["⏺ Hola."] + box()).joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        session.showPending("/effort high")
        XCTAssertNil(session.pendingMessage, "It never shows in the chat, so its bubble would wait for nothing.")
        session.showPending("/model sonnet")
        XCTAssertNil(session.pendingMessage)
        session.showPending("hola")
        XCTAssertEqual(session.pendingMessage, "hola")
    }

    func testAChipsCommandIsSeenTakenThoughItsEchoIsHidden() throws {
        var actions: [String] = []
        let before = (["⏺ Hola."] + box()).joined(separator: "\n")
        let after = (["⏺ Hola.", "", "> /model sonnet", "  ⎿  Set model to Sonnet 5.5"] + box()).joined(separator: "\n")
        try TerminalAppBridge.deliver("/model sonnet", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1),
                                      run: { actions.append($0) }, read: { actions.isEmpty ? before : after })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("/model sonnet")], "Taken: no Enter on whatever comes next.")
    }
}
