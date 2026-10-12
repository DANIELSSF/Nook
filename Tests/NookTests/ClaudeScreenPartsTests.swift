import XCTest
@testable import Nook

/// What Claude draws around the chat (its banner and start-up warnings, the waiting line, the mode line and the agent list)
/// stays out of Nook's chat and becomes state, as on Sample's screens of 2026-10-05/06.
final class ClaudeScreenPartsTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private let modeLine = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage"
    private let format = "Permission allow rule (.claude/settings.json): Bash(pnpm --filter * exec prisma format*) has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean, or only use * after the subcommand."
    private let migrate = "Permission allow rule (.claude/settings.json): Bash(pnpm --filter * exec prisma migrate dev*) has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean, or only use * after the subcommand."

    /// A new session in Sample's app tab: the shell line that started Claude, its warnings (the first one wrapped by the
    /// terminal), a stretch of blank screen, the banner and the empty box.
    private var startup: String {
        let wrapped = format.components(separatedBy: " has a ")
        return (["developer@MacBook-Pro-Example app % claude", wrapped[0] + " has a", "wildcard " + wrapped[1].dropFirst("wildcard ".count), migrate, migrate]
                + Array(repeating: "", count: 17)
                + ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app", "",
                   rule, "❯ Try \"refactor <filepath>\"", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]).joined(separator: "\n")
    }

    func testTheBannerAndItsWarningsLeaveTheChat() throws {
        let screen = ClaudeComposer.split(startup)
        XCTAssertEqual(screen.conversation, "", "The shell's line that started Claude belongs to the shell, not to this conversation.")
        let banner = try XCTUnwrap(screen.banner)
        XCTAssertEqual(banner, ClaudeBanner(version: "2.1.290", model: "Sonnet 5.5", effort: "xhigh", plan: "Claude Team", directory: "~/Documents/app"))
        XCTAssertEqual(screen.warnings.map(\.text), [format, migrate], "Once each, the wrapped one whole again.")
        XCTAssertEqual(screen.warnings.first?.source, ".claude/settings.json")
        XCTAssertEqual(screen.input, "Try \"refactor <filepath>\"")
        XCTAssertEqual(screen.mode?.kind, .auto)
    }

    func testTheBannerAsNooksOwnTmuxPaneShowsIt() throws {
        // Captured from a Nook session (Claude Code 2.1.289): the logo differs, the shape doesn't.
        let pane = ["", " ▐▛███▛█   Claude Code v2.1.289", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Chamba"]
            + Array(repeating: "", count: 16) + ["                                 ✔ Update installed · Restart to update", rule, "❯ Try \"refactor <filepath>\"", rule,
                                                  "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]
        let screen = ClaudeComposer.split(pane.joined(separator: "\n"))
        XCTAssertEqual(screen.banner, ClaudeBanner(version: "2.1.289", model: "Opus 5.5", effort: "xhigh", plan: "Claude Team", directory: "~/Documents/Chamba"))
        XCTAssertEqual(screen.conversation, "")
        XCTAssertEqual(ClaudeEffort.reported(in: pane.joined(separator: "\n")), .xhigh, "The banner names the starting effort.")
        XCTAssertNil(ClaudeStartup.banner(at: 0, in: ["⏺ Claude Code v2 añadió el modo fullscreen"]), "A reply mentioning Claude Code is no banner.")
    }

    func testAWarningLikeLineNotFollowedByABannerStays() {
        let text = ["⏺ El aviso decía:", format, "", "⏺ ¿Lo arreglo?", rule, "❯ ", rule].joined(separator: "\n")
        let screen = ClaudeComposer.split(text)
        XCTAssertTrue(screen.conversation.contains(format), "Without the banner after it, it is just text.")
        XCTAssertTrue(screen.warnings.isEmpty)
        XCTAssertNil(screen.banner)
    }

    func testOnlyTheNewestSessionsBannerAndWarningsCount() {
        let first = [migrate, "", "▗ ▗   ▖ ▖  Claude Code v2.1.289", "           Opus 5.5 · Claude Team", " ▘▘   ▝▝   ~/Documents/app", "⏺ Hecho.",
                     "developer@MacBook-Pro-Example app % claude"]
        let second = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app", rule, "❯ ", rule]
        let screen = ClaudeComposer.split((first + second).joined(separator: "\n"))
        XCTAssertEqual(screen.banner?.version, "2.1.290")
        XCTAssertEqual(screen.banner?.effort, "xhigh")
        XCTAssertTrue(screen.warnings.isEmpty, "The newest session started without warnings.")
        XCTAssertEqual(screen.conversation, "", "The earlier session and the shell that started this one are not this conversation.")
    }

    /// Sample's report: this showed in Nook's chat.
    func testTheWaitingLineModeLineAndAgentListLeaveTheChat() throws {
        let text = ["⏺ Lancé al agente para revisar la lista.", "", "✻ Waiting for 1 background agent to finish", rule, "❯ ", rule, modeLine, "", "  ⏺ main",
                    "  coder  Reading ContactList in contact-list.tsx                                            1m 51s · ↓ 187.7k tokens"].joined(separator: "\n")
        let screen = ClaudeComposer.split(text)
        XCTAssertEqual(screen.conversation, "⏺ Lancé al agente para revisar la lista.")
        XCTAssertEqual(screen.input, "")
        let status = try XCTUnwrap(screen.status)
        XCTAssertEqual(status.background, 1)
        XCTAssertTrue(status.working, "Claude's turn goes on once its agents report back.")
        XCTAssertEqual(status.glyph, "✻")
        XCTAssertEqual(status.text, "Waiting for 1 background agent to finish")
        XCTAssertEqual(screen.mode, ClaudeMode(kind: .auto, label: "auto mode on", hints: ["shift+tab to cycle", "← for agents", "↓ to manage"]))
    }

    /// The coordinator's screenshot: several agents, plural, and times wrapped to the left edge in a narrow pane.
    func testAWrappedAgentListLeavesTheChatWhole() {
        let text = ["⏺ Tres agentes en marcha.", "✻ Waiting for 3 background agents to finish", "", rule, "❯ ", rule, modeLine, "", "  ⏺ main",
                    "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens",
                    "  ○ fork  Charting echo failures in deliveries.log", "4m 56s · ↓ 189.9k tokens"].joined(separator: "\n")
        let screen = ClaudeComposer.split(text)
        XCTAssertEqual(screen.conversation, "⏺ Tres agentes en marcha.")
        XCTAssertEqual(screen.status?.background, 3)
        XCTAssertEqual(screen.input, "")
        XCTAssertTrue(TerminalSession.screen(text, agent: .claude).conversation == screen.conversation)
    }

    /// deliveries.log 4/10: with the list focused (↓ to manage) the box was taken for a dialog and the message never matched.
    func testAFocusedAgentListNoLongerHidesTheBox() {
        let text = ["⏺ Listo.", rule, "❯ avísame cuando esté publicado", rule, "  ↑/↓ to select", "❯ ⏺ main",
                    "❯ ◯ general-purpose  Adding suggestion renders to DisplayRenderTests                         41m 40s"].joined(separator: "\n")
        let screen = ClaudeComposer.split(text)
        XCTAssertEqual(screen.input, "avísame cuando esté publicado")
        XCTAssertEqual(screen.conversation, "⏺ Listo.")
        XCTAssertTrue(MessageEcho.pending("avísame cuando esté publicado", in: text, agent: .claude))
    }

    func testRepliesThatLookLikeTheListStay() {
        // "⏺ main" as a reply line, with more conversation and the box after it.
        let text = ["⏺ La rama es:", "", "⏺ main", "", "⏺ ¿Hago el merge?", rule, "❯ ", rule, modeLine].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(text).conversation, "⏺ La rama es:\n\n⏺ main\n\n⏺ ¿Hago el merge?")
        XCTAssertNil(ClaudeStatus(line: "⏺ Waiting for 1 background agent to finish"), "A reply is no status line.")
        XCTAssertNil(ClaudeStatus(line: "   Waiting for 2 background agents to finish"), "Indented text is a reply.")
        XCTAssertEqual(ClaudeStatus(line: "✻ Waiting for 2 background agents to finish")?.background, 2)
        XCTAssertNil(ClaudeStatus(line: "✻ Churning… (2s)")?.background)
    }

    func testModeLines() {
        XCTAssertEqual(ClaudeMode.parse("  ⏸ plan mode on (shift+tab to cycle)")?.kind, .plan)
        XCTAssertEqual(ClaudeMode.parse("  ⏵⏵ accept edits on (shift+tab to cycle) · 1 background")?.hints, ["shift+tab to cycle", "1 background"])
        XCTAssertEqual(ClaudeMode.parse("  ⏵⏵ bypass permissions on (shift+tab to cycle)")?.kind, .bypassPermissions)
        XCTAssertNil(ClaudeMode.parse("  ? for shortcuts"), "The default mode names no mode.")
        XCTAssertNil(ClaudeMode.parse("⏺ El modo auto mode on se activa con shift+tab"), "A reply is no mode line.")
        XCTAssertEqual(ClaudeComposer.split(["⏺ Hola", rule, "❯ ", rule, "  ? for shortcuts"].joined(separator: "\n")).mode, .standard,
                       "The default mode draws no mode line: the box with Claude's quiet footer says it.")
        XCTAssertEqual(ClaudeComposer.split(["⏺ Hola", rule, "❯ ", rule].joined(separator: "\n")).mode, .standard)
        XCTAssertTrue(ClaudeMode.standard.isDefault)
        XCTAssertFalse(ClaudeMode.parse(modeLine)!.isDefault)
        XCTAssertNil(ClaudeComposer.split(["⏺ Hola", rule, "❯ /mo", rule, "  /model     Set the AI model for Claude Code", "  /mobile    Download the app"].joined(separator: "\n")).mode,
                     "The \"/\" menu stands where the mode line was: no telling.")
        XCTAssertNil(ClaudeComposer.split(["⏺ Hola", rule, "❯ ", rule, "  plan mode on"].joined(separator: "\n")).mode, "A mode Nook can't read is not the default.")
        XCTAssertNil(ClaudeComposer.split("⏺ Hola\n Select model\n ❯ 1. Opus\n Enter to confirm · Esc to exit").mode, "No box, no telling.")
    }

    func testTheModeChipKeepsItsModeWhileAReadingCantTell() {
        let tab = { (lines: [String]) in TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys009", customTitle: "",
                                                             processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: lines.joined(separator: "\n")) }
        let session = TerminalSession(tab: tab(["⏺ Hola", rule, "❯ ", rule, "  ⏸ plan mode on (shift+tab to cycle)"]), backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.agentMode?.kind, .plan)
        session.update(tab(["⏺ Hola", rule, "❯ /mo", rule, "  /model     Set the AI model for Claude Code"]))
        XCTAssertEqual(session.agentMode?.kind, .plan, "The \"/\" menu hid the line; the mode didn't change.")
        session.update(tab(["⏺ Hola", rule, "❯ ", rule, "  ? for shortcuts"]))
        XCTAssertEqual(session.agentMode, .standard, "⇧⇥ went round to the default mode.")
        session.update(TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh"],
                                           busy: false, selected: true, text: "developer@MacBook-Pro-Example app % "))
        XCTAssertNil(session.agentMode, "Claude quit.")
    }

    func testTheBannerFollowsModelChanges() {
        let banner = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
        let changed = banner + ["", "> /model", "  ⎿  Set model to Opus 5.5 and saved as your default for new sessions", "", rule, "❯ ", rule]
        XCTAssertEqual(ClaudeComposer.split(changed.joined(separator: "\n")).banner?.model, "Opus 5.5")
        XCTAssertEqual(ClaudeComposer.split(changed.joined(separator: "\n")).banner?.effort, "xhigh", "The effort is not the model's answer to change.")
        let kept = changed + ["> /model", "  ⎿  Kept model as `Fable 5.1`"]
        XCTAssertEqual(ClaudeComposer.split(kept.joined(separator: "\n")).banner?.model, "Fable 5.1", "The newest answer wins; backticks go.")
        XCTAssertEqual(ClaudeBanner.modelChange(in: "  ⎿  Set model to Sonnet 4.6")?.model, "Sonnet 4.6")
        XCTAssertEqual(ClaudeBanner.modelChange(in: "  ⎿  Set model to `Opus 5 (1M context)` and saved as your default for new sessions")?.model, "Opus 5 (1M context)")
        XCTAssertEqual(ClaudeBanner.modelChange(in: "  ⎿  Set model to Opus 5.5 with max effort")?.effort, "max")
        XCTAssertNil(ClaudeBanner.modelChange(in: "⏺ Usa /model y verás «Set model to Opus 5.5»."), "A reply that quotes it changes nothing.")
        XCTAssertNil(ClaudeBanner.modelChange(in: "  ⎿  Set model to …"))
        // An answer from the session before the newest banner belongs to that session.
        let older = ["> /model", "  ⎿  Set model to Haiku 4.5"] + banner + [rule, "❯ ", rule]
        XCTAssertEqual(ClaudeComposer.split(older.joined(separator: "\n")).banner?.model, "Sonnet 5.5")
    }

    func testATabShowsTheBannerAndModeOutsideTheChat() {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: startup)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.displayText, "", "Nothing of the shell before Claude's banner.")
        XCTAssertTrue(session.awaitsFirstMessage, "Claude just started: its grey suggestion is no message.")
        XCTAssertEqual(session.banner?.model, "Sonnet 5.5")
        XCTAssertEqual(session.startupWarnings.count, 2)
        XCTAssertEqual(session.agentMode?.kind, .auto)
        XCTAssertEqual(session.effort, .xhigh, "Until Claude reports another, the banner's effort.")
        let shell = TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh"],
                                        busy: false, selected: true, text: startup + "\ndeveloper@MacBook-Pro-Example app % ")
        session.update(shell)
        XCTAssertNil(session.banner, "Claude quit: its banner goes with it.")
        XCTAssertNil(session.agentMode)
    }
}
