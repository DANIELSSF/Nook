import AppKit
import XCTest
@testable import Nook

final class TerminalPresentationTests: XCTestCase {
    private let rule = String(repeating: "─", count: 80)
    private let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ctrl+t to hide tasks · ← for agents"

    func testHidesClaudeInputBoxAndStatusLineButKeepsTheConversation() {
        let reply = "⏺ Listo. Cambié el archivo.\n  Segunda línea de la respuesta."
        let screen = [reply, "", rule, "❯ ", rule, footer].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(screen), reply)
    }

    func testHidesUpdateNoticeAndReportsWhatTheBoxShows() {
        let screen = ["⏺ Respuesta", "", "                         ✔ Update installed · Restart to update", "", rule, "❯ primera línea", "  segunda línea", rule, footer].joined(separator: "\n")
        let split = ClaudeComposer.split(screen)
        XCTAssertEqual(split.conversation, "⏺ Respuesta")
        XCTAssertEqual(split.input, "primera línea\nsegunda línea")
    }

    func testBoxTextLeavesTheMirrorAndIsReported() {
        let split = ClaudeComposer.split(["⏺ Hola", rule, "❯ ok avísame cuando esté listo", rule, footer].joined(separator: "\n"))
        XCTAssertEqual(split.conversation, "⏺ Hola", "Claude's suggestion shows in Nook's field, not in the chat.")
        XCTAssertEqual(split.input, "ok avísame cuando esté listo")
        XCTAssertEqual(ClaudeComposer.split(["⏺ Hola", rule, "❯ ", rule].joined(separator: "\n")).input, "")
        let suggestion = ClaudeComposer.split(["⏺ Hola", rule, "❯ Try \"refactor <filepath>\"", rule, footer].joined(separator: "\n"))
        XCTAssertEqual(suggestion.input, "Try \"refactor <filepath>\"", "Plain text can't prove it is a hint, so it is kept and shown in Nook's field.")
        XCTAssertEqual(suggestion.conversation, "⏺ Hola")
        XCTAssertNil(ClaudeComposer.split("~ % ls").input)
    }

    func testBoxWithTheSessionNameInItsTopRuleIsStillTheBox() {
        // A fresh Claude in a narrow terminal, its session named: the label outweighs the dashes.
        for (width, name) in [(40, "ui-designer"), (62, "ui-designer"), (80, "diseño de la isla y sus pestañas de colores")] {
            let label = " \(name) "
            let top = String(repeating: "─", count: width - label.count - 1) + label + "─"
            let screen = ["⏺ Hola", "", top, "❯ Try \"refactor <filepath>\"", String(repeating: "─", count: width), footer].joined(separator: "\n")
            let split = ClaudeComposer.split(screen)
            XCTAssertEqual(split.conversation, "⏺ Hola", "width \(width)")
            XCTAssertEqual(split.input, "Try \"refactor <filepath>\"", "width \(width)")
            XCTAssertNil(split.panel, "width \(width): the box is not a panel")
        }
        // Text with dashes around it is not a labelled rule: two labels, a label without its padding, too short a lead.
        for line in ["──── two  labels ─── here ─", "─── not a padded label here─", "── Mira esto, no es un borde ──"] {
            XCTAssertFalse(ClaudeComposer.isRule(line), line)
        }
    }

    func testClaudesModeLineAloneNeverMakesAPanel() {
        // A box caught mid-redraw (no bottom rule yet) leaves only the mode line's "shift+tab to cycle".
        let screen = ["⏺ Hola", rule, "❯ ", footer].joined(separator: "\n")
        XCTAssertNil(ClaudeComposer.split(screen).panel)
        XCTAssertNotNil(ClaudeComposer.panel(["⏺ Hola", "╭──────────╮", "│ Model │", "╰──────────╯", "  Enter to confirm · Esc to cancel"]), "A real panel's hint still counts.")
    }

    func testKeepsSlashCommandSuggestionsVisible() {
        let suggestions = ["  /help                       Show help and available commands", "  /hooks                      Manage hook configurations"]
        let screen = (["⏺ Respuesta", rule, "❯ /h", rule] + suggestions).joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(screen), (["⏺ Respuesta"] + suggestions).joined(separator: "\n"))
    }

    func testDialogsAndMenusAreNeverHidden() {
        let permission = ["⏺ Voy a ejecutar un comando.", rule, " Bash command", "   rm -rf build", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(permission), permission)
        let picker = [rule, "❯ 1. Default (recommended)", "  2. Opus", rule, "  Enter to confirm · Esc to exit"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(picker), picker)
    }

    func testRulesAndQuotesInsideRepliesStay() {
        let indented = "  " + rule
        let reply = ["⏺ Tabla y cita:", indented, "  > una cita", indented, "  fin"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(reply), reply)
        let code = ["⏺ Código:", "  ```", "  // ----------------------", "  ```"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(code + "\n" + [rule, "❯ ", rule].joined(separator: "\n")), code)
    }

    func testRoundedBoxComposerIsHiddenToo() {
        let box = ["╭" + String(repeating: "─", count: 60) + "╮", "│ > " + String(repeating: " ", count: 57) + "│", "╰" + String(repeating: "─", count: 60) + "╯", "  ? for shortcuts"]
        XCTAssertEqual(ClaudeComposer.conversation((["⏺ Hola"] + box).joined(separator: "\n")), "⏺ Hola")
        var typed = box; typed[1] = "│ > hola" + String(repeating: " ", count: 53) + "│"
        XCTAssertEqual(ClaudeComposer.split((["⏺ Hola"] + typed).joined(separator: "\n")).input, "hola")
    }

    func testPlainShellOutputIsUntouched() {
        let shell = "Last login: Thu Oct  2 on ttys003\n~ % ls\nREADME.md  Sources\n~ % "
        XCTAssertEqual(ClaudeComposer.conversation(shell), shell)
        XCTAssertEqual(ClaudeComposer.conversation(""), "")
    }

    func testClaudeStatusLinesLeaveTheChatAndKeepTheTerminalSymbol() {
        let working = ["⏺ Revisando el código.", "", "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, footer].joined(separator: "\n")
        let split = ClaudeComposer.split(working)
        XCTAssertEqual(split.conversation, "⏺ Revisando el código.")
        XCTAssertEqual(split.status, ClaudeStatus(glyph: "✶", text: "Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", working: true))
        XCTAssertEqual(SessionPane.statusText(split.status!.text), "Churning… (1m 2s · ↓ 3.4k tokens)")
        XCTAssertEqual(SessionPane.statusText("Thinking… (esc to interrupt)"), "Thinking…")

        let done = ["⏺ Listo.", "", "✻ Churned for 3m 58s · done 4:01 p.m.", "", rule, "❯ ", rule].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(done).conversation, "⏺ Listo.")
        XCTAssertEqual(ClaudeComposer.split(done).status, ClaudeStatus(glyph: "✻", text: "Churned for 3m 58s · done 4:01 p.m.", working: false))
        XCTAssertEqual(ClaudeStatus(line: "Churned for 3m 58s · done 4:01 p.m."), ClaudeStatus(glyph: nil, text: "Churned for 3m 58s · done 4:01 p.m.", working: false))
        // Older turns' summaries also leave the chat; the latest one is the status.
        let history = ["✻ Worked for 12s", "⏺ Uno", "✻ Baked for 2m 1s", "⏺ Dos"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(history).conversation, "⏺ Uno\n⏺ Dos")
        XCTAssertEqual(ClaudeComposer.split(history).status?.text, "Baked for 2m 1s")
    }

    func testRecapLeavesTheChatAndKeepsItsWrappedText() {
        let screen = ["⏺ Publicado.", "", "※ recap: Mejorando Nook para tus sesiones de Claude: ya publiqué el Enter que se",
                      "  ejecuta solo y la cápsula de subagentes. Lo siguiente es que lo pruebes.", "", rule, "❯ ", rule, footer].joined(separator: "\n")
        let parsed = ClaudeComposer.split(screen)
        XCTAssertEqual(parsed.recap, "Mejorando Nook para tus sesiones de Claude: ya publiqué el Enter que se ejecuta solo y la cápsula de subagentes. Lo siguiente es que lo pruebes.")
        XCTAssertEqual(parsed.conversation, "⏺ Publicado.")
        XCTAssertEqual(ClaudeComposer.split("recap: Revisando el notch.\n⏺ Hola").recap, "Revisando el notch.")
        XCTAssertEqual(ClaudeComposer.split("recap: Revisando el notch.\n⏺ Hola").conversation, "⏺ Hola")
        // The latest recap wins; replies that merely mention a recap stay in the chat.
        XCTAssertEqual(ClaudeComposer.split("※ recap: Uno\n\n⏺ Medio\n※ recap: Dos").recap, "Dos")
        let reply = "⏺ Aquí va el resumen:\n  recap: esto es parte de la respuesta"
        XCTAssertNil(ClaudeComposer.split(reply).recap)
        XCTAssertEqual(ClaudeComposer.split(reply).conversation, reply)
    }

    func testCodexReviewCasesKeepContentVisible() {
        // An error under the box is not Claude's mode line.
        let error = ["⏺ Hola", rule, "❯ ", rule, "  Failed to save the conversation. Retry before closing."].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.conversation(error), "⏺ Hola\n  Failed to save the conversation. Retry before closing.")
        // A selector without numbers between rules is a dialog, not the input box.
        let picker = ["⏺ Elige modelo", rule, "❯ Opus (recommended)", "  Sonnet", "  Haiku", rule, "  Enter to confirm · Esc to exit"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(picker).conversation, picker)
        XCTAssertNil(ClaudeComposer.split(picker).input)
        // A real message that starts like Claude's hint is not discarded.
        XCTAssertEqual(ClaudeComposer.split([rule, "❯ Try \"foo\" and explain the result", rule].joined(separator: "\n")).input, "Try \"foo\" and explain the result")
        // Lines that merely resemble status lines stay in the chat.
        for line in ["* Testing… this is a bullet from an example", "✻ Testing… this is a bullet", "Worked for 3s before failing to save the file."] {
            XCTAssertNil(ClaudeStatus(line: line), line)
        }
        XCTAssertEqual(ClaudeStatus(line: "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)")?.working, true)
        XCTAssertEqual(ClaudeStatus(line: "✻ Churned for 3m 58s · done 4:01 p.m.")?.working, false)
        XCTAssertEqual(ClaudeStatus(line: "✻ Worked for 1h 2m 3s")?.working, false)
    }

    func testRepliesThatLookLikeStatusLinesStay() {
        for line in ["  ✻ Churning… inside an indented reply", "⏺ Churned for 3m 58s in the last run", "> Worked for 3s yesterday", "Thinking… about it", "✻ lowercase… text", "* item without ellipsis"] {
            XCTAssertNil(ClaudeStatus(line: line), line)
        }
        XCTAssertNil(ClaudeComposer.split("⏺ Hola").status)
    }

    func testForegroundAgentComesFromTheTabProcesses() {
        XCTAssertEqual(TerminalAgent(processes: ["login", "-zsh", "claude", "npm exec chrome-devtools-mcp@latest", "chrome-devtools-mcp", "caffeinate"]), .claude)
        XCTAssertEqual(TerminalAgent(processes: ["login", "-zsh", "node", "codex"]), .codex)
        XCTAssertEqual(TerminalAgent(processes: ["login", "-zsh", "claude", "codex"]), .claude, "Codex launched by Claude still shows Claude.")
        XCTAssertEqual(TerminalAgent(processes: ["/Users/me/.local/bin/claude"]), .claude)
        XCTAssertNil(TerminalAgent(processes: ["login", "-zsh", "vim", "claude-helper"]))
    }

    func testMirrorShowsTheConversationAndKeepsTheRawText() {
        let raw = ["⏺ Hola", rule, "❯ ", rule, footer].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh", "claude"], busy: true, selected: true, text: raw)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.agent, .claude)
        XCTAssertEqual(session.mirroredText, raw)
        XCTAssertEqual(session.displayText, "⏺ Hola")
        XCTAssertNil(session.suggestion)
        XCTAssertEqual(tab.title, "1 · claude")
        let suggested = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: ["⏺ Hola", rule, "❯ ok avísame cuando esté listo", rule, footer].joined(separator: "\n"))
        session.update(suggested)
        XCTAssertEqual(session.suggestion, "ok avísame cuando esté listo")
        XCTAssertEqual(session.displayText, "⏺ Hola")
        let shell = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh"], busy: false, selected: true, text: raw)
        session.update(shell)
        XCTAssertNil(session.agent)
        XCTAssertNil(session.suggestion)
        XCTAssertEqual(session.displayText, raw, "Without Claude in front nothing is filtered.")
    }

    private func claudeScreen(_ input: String) -> String { ["⏺ Hola", rule, "❯ " + input, rule, footer].joined(separator: "\n") }

    func testEnterWaitsUntilClaudeHoldsTheMessage() throws {
        var log: [String] = []
        var reads = 0
        var shownAt: Date?, enterAt: Date?
        let hold = 0.2
        // Claude read the text as a paste: Terminal's Return became a new line and the message waits in the box. Measured in time,
        // not in readings: a slow (throttled) run reads less often, and Enter must still wait the whole hold.
        try TerminalAppBridge.deliver("/usage", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: hold, settle: 0.2), run: { action in
            log.append(action == TerminalAppBridge.returnAction ? "return" : "type")
            if action == TerminalAppBridge.returnAction, enterAt == nil { enterAt = Date() }
        }, read: {
            reads += 1
            // Busy for two reads, then the message shows in the box; after Enter the box is empty.
            if log.contains("return") { return self.claudeScreen("") }
            guard log.contains("type"), reads >= 3 else { return self.claudeScreen("") }
            if shownAt == nil { shownAt = Date() }
            return self.claudeScreen("/usage")
        })
        XCTAssertEqual(log.first, "type", "Nook first checks the box, then types.")
        let shown = try XCTUnwrap(shownAt), enter = try XCTUnwrap(enterAt)
        XCTAssertGreaterThanOrEqual(enter.timeIntervalSince(shown), hold, "Enter goes only once the box has held the message for the hold.")
        XCTAssertEqual(log.filter { $0 == "return" }.count, 1, "An emptied box means Claude took it: no second Enter.")
    }

    func testClaudeGetsOneMoreEnterOnlyWhenItKeptTheMessage() throws {
        var returns = 0
        try TerminalAppBridge.deliver("hola gato", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.1), run: { action in
            if action == TerminalAppBridge.returnAction { returns += 1 }
        }, read: { self.claudeScreen(returns < 2 ? "hola gato" : "") })
        XCTAssertEqual(returns, 2)

        var codexReturns = 0
        try TerminalAppBridge.deliver("hola", agent: .codex, timing: .init(poll: 0.01, echo: 5, settle: 0.1), run: { action in
            if action == TerminalAppBridge.returnAction { codexReturns += 1 }
        }, read: { "› hola" })
        XCTAssertEqual(codexReturns, 1, "Without a known box, Codex never gets a second Enter.")
    }

    func testTextAlreadyTypedInFrontOfTheMessageStopsTheEnter() {
        var actions: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver("/usage", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.1), run: { actions.append($0) }, read: { self.claudeScreen("t/usage") })) { error in
            guard case DeliveryError.joined(let box) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(box, "t/usage")
        }
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("/usage")], "No Enter: «t/usage» would not run the command.")
        XCTAssertNil(MessageEcho.joined("/usage", in: claudeScreen("/usage")), "A suggestion vanishes when the message is pasted.")
        XCTAssertNil(MessageEcho.joined("hola", in: claudeScreen("[Pasted text #1 +3 lines]")))
        XCTAssertNil(MessageEcho.joined("sí", in: claudeScreen("sí, hazlo")), "Only text in front of the whole message counts.")
    }

    func testMessageAlreadyInTheBoxOnlyNeedsEnter() throws {
        var actions: [String] = []
        // Typed in the terminal's box already: Enter sends it and the box empties.
        try TerminalAppBridge.deliver("ok avísame cuando esté listo", agent: .claude, timing: .init(poll: 0.01, echo: 0.2, settle: 0.1), run: { actions.append($0) }, read: {
            self.claudeScreen(actions.isEmpty ? "ok avísame cuando esté listo" : "")
        })
        XCTAssertEqual(actions, [TerminalAppBridge.returnAction], "Nothing is typed, so the box never holds two copies.")
        XCTAssertTrue(MessageEcho.same("ok avísame cuando\nesté listo", "ok avísame cuando esté listo"))
        XCTAssertFalse(MessageEcho.same("ok avísame", "ok"))
    }

    func testJoinedBoxBlocksResendingUntilTheBoxChanges() {
        let tab = { (box: String) in TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys009", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: self.claudeScreen(box)) }
        let session = TerminalSession(tab: tab("ahora moemnto de optimizarahora es momento de optimizar"), backend: .bundled, bridge: TerminalAppBridge())
        session.joinedBox = "ahora moemnto de optimizarahora es momento de optimizar"
        session.update(tab("ahora moemnto de optimizarahora es momento de optimizar"))
        XCTAssertNotNil(session.joinedBox, "Same box: still blocked.")
        session.update(tab("ahora es momento de optimizar"))
        XCTAssertNil(session.joinedBox, "Fixed in the terminal: Nook can send again.")
    }

    func testAShortMessageIsNotConfusedWithClaudesNextSuggestion() throws {
        var actions: [String] = []
        var steps: [String] = []
        // After Enter, Claude suggests "sí, hazlo también en Codex": that is not the message still waiting.
        try TerminalAppBridge.deliver("sí", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.1), run: { actions.append($0) }, read: {
            actions.contains(TerminalAppBridge.returnAction) ? self.claudeScreen("sí, hazlo también en Codex") : self.claudeScreen(actions.isEmpty ? "" : "sí")
        }, trace: { steps.append($0) })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("sí"), TerminalAppBridge.returnAction], "No extra Enter on the suggestion.")
        XCTAssertEqual(steps.last, "caja vacía: enviado")
        XCTAssertTrue(steps.contains("escrito con su Enter"))
    }

    func testRetriesAreCappedAndAFailureAfterPastingNeverPastesAgain() throws {
        var returns = 0, typed = 0
        // Claude keeps the whole message no matter what: one Enter plus two retries, then it stops and says so.
        XCTAssertThrowsError(try TerminalAppBridge.deliver("hola gato", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.05), run: { action in
            if action == TerminalAppBridge.returnAction { returns += 1 } else { typed += 1 }
        }, read: { self.claudeScreen(typed == 0 ? "" : "hola gato") })) { error in
            guard case DeliveryError.stuck = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(returns, 3)
        XCTAssertEqual(typed, 1)

        struct Busy: Error {}
        var actions: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver("revisa esto", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.05), run: { action in
            actions.append(action)
            if action == TerminalAppBridge.returnAction { throw Busy() }
        }, read: { self.claudeScreen(actions.isEmpty ? "" : "revisa esto") })) { error in
            guard case DeliveryError.joined(let box) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(box, "revisa esto", "Marked as sitting in the box, so Nook offers «Enviar así» instead of pasting again.")
        }
        XCTAssertEqual(actions.filter { $0 != TerminalAppBridge.returnAction }.count, 1, "Pasted once.")
    }

    func testNoExtraEnterWhenADialogFollowsTheMessage() throws {
        var returns = 0
        // After the answer, Claude opens another question whose screen still shows the text just sent.
        let dialog = ["⏺ Usaré PostgreSQL para el servicio nuevo", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")
        try TerminalAppBridge.deliver("Usaré PostgreSQL para el servicio nuevo", agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.05), run: { action in
            if action == TerminalAppBridge.returnAction { returns += 1 }
        }, read: { returns == 0 ? self.claudeScreen("Usaré PostgreSQL para el servicio nuevo") : dialog })
        XCTAssertEqual(returns, 1, "The new dialog's «Yes» must not be accepted by a retry.")
    }

    func testAMessageOfSeveralLinesIsPastedWholeAndSentOnce() throws {
        let message = "revisa esto:\n1. el notch\n2. el gato"
        // Claude still holds it (the Return reached it before the paste was in): one more Enter.
        for box in ["revisa esto:\n  1. el notch\n  2. el gato", "[Pasted text #1 +2 lines]"] {
            var actions: [String] = []
            try TerminalAppBridge.deliver(message, agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.05), run: { actions.append($0) },
                                          read: { actions.contains(TerminalAppBridge.returnAction) ? self.claudeScreen("") : self.claudeScreen(actions.isEmpty ? "" : box) })
            XCTAssertEqual(actions, [TerminalAppBridge.messageAction(message), TerminalAppBridge.returnAction], "One paste with its line breaks, then one Enter (\(box)).")
        }
        // The usual case: the Return after the paste marks sends it, and nothing follows.
        var actions: [String] = []
        try TerminalAppBridge.deliver(message, agent: .claude, timing: .init(poll: 0.01, echo: 5, hold: 0.03, settle: 0.05), run: { actions.append($0) },
                                      read: { actions.isEmpty ? self.claudeScreen("") : "> revisa esto:\n  1. el notch\n  2. el gato\n" + self.claudeScreen("") })
        XCTAssertEqual(actions, [TerminalAppBridge.messageAction(message)])
        XCTAssertTrue(TerminalAppBridge.messageAction(message).contains("\\n"), "Line breaks travel inside the one AppleScript string.")
        XCTAssertTrue(TerminalAppBridge.messageAction(message).contains("(character id 27) & \"[200~\""), "Between bracketed-paste marks.")
        XCTAssertTrue(MessageEcho.pending(String(repeating: "texto largo ", count: 200), in: "salida\n› [Pasted Content 2400 chars]", agent: .codex),
                      "Codex's placeholder for a long paste is the message too.")
    }

    func testClaudesPanelsShowInsteadOfTheBox() {
        let boxed = ["⏺ Listo, ya está.", "", "╭────────────────────────────────────────╮", "│ Settings:  Status   Config   Usage      │", "│                                        │",
                     "│ Current session                        │", "│ ████████░░░░  42% used                 │", "╰────────────────────────────────────────╯",
                     "  ←/→ tab to switch · Esc to exit"].joined(separator: "\n")
        let screen = ClaudeComposer.split(boxed)
        XCTAssertNil(screen.input)
        XCTAssertEqual(screen.panel?.components(separatedBy: "\n").first, "╭────────────────────────────────────────╮")
        XCTAssertTrue(screen.panel?.hasSuffix("Esc to exit") == true)
        XCTAssertFalse(screen.panel?.contains("Listo") == true, "The conversation stays out of it.")

        let ruled = ["> /usage", "", rule, " Usage", "", " Current week (all models)", " ██████░░░░ 61% used · resets Oct 7", "", " Esc to cancel"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(ruled).panel, [rule, " Usage", "", " Current week (all models)", " ██████░░░░ 61% used · resets Oct 7", "", " Esc to cancel"].joined(separator: "\n"))

        // Sample's screen with /usage open (Claude Code 2.1.288, fullscreen): no hint in view, only a "↓".
        let usage = ["✻ Waiting for 1 background agent to finish", String(repeating: "─", count: 110), "",
                     "   Settings   Status   Config   Usage   Stats", "", "   Session", "",
                     "   Total cost:            $253.64", "   Total duration (API):  9h 56m 36s",
                     "   Usage by model:", "        claude-opus-5-5:  17.9k input, 888.7k output ($87.40)", "",
                     "   Current session", "   █████████░░░░░░░░░░░░░░░░░░░░   25% used", "   Resets 8:59pm (America/Bogota)",
                     String(repeating: " ", count: 100) + "↓"].joined(separator: "\n")
        let settings = ClaudeComposer.split(usage)
        XCTAssertNil(settings.input)
        XCTAssertTrue(settings.panel?.hasPrefix(String(repeating: "─", count: 110)) == true, "From its top rule…")
        XCTAssertTrue(settings.panel?.contains("Total cost:            $253.64") == true)
        XCTAssertTrue(settings.panel?.hasSuffix("↓") == true, "…to the end of the screen.")
        XCTAssertFalse(settings.panel?.contains("Waiting for") == true)
        // The same panel with its edge drawn in block characters, and with no edge at all.
        let blocky = usage.replacingOccurrences(of: String(repeating: "─", count: 110), with: String(repeating: "▔", count: 110))
        XCTAssertTrue(ClaudeComposer.split(blocky).panel?.hasPrefix(String(repeating: "▔", count: 110)) == true)
        let bare = usage.replacingOccurrences(of: String(repeating: "─", count: 110) + "\n", with: "")
        XCTAssertTrue(ClaudeComposer.split(bare).panel?.hasPrefix("   Settings   Status") == true, "A tab row opening the screen is enough.")
        XCTAssertTrue(ClaudeComposer.isTabRow("   Settings   Status   Config   Usage   Stats"))
        XCTAssertFalse(ClaudeComposer.isTabRow("  Name    Type"), "Two words are not a tab row.")
        let table = ["⏺ Aquí tienes la tabla:", "  ──────────────────────────────", "  Name    Type    Size", "  a.swift   file   2k"].joined(separator: "\n")
        XCTAssertNil(ClaudeComposer.split(table).panel, "A table in a reply has its rule indented: not a panel.")
        XCTAssertFalse(ClaudeComposer.isTabRow("   Total cost:            $253.64"))

        XCTAssertNil(ClaudeComposer.split(claudeScreen("hola")).panel, "With the box there is no panel.")
        XCTAssertNil(ClaudeComposer.split("⏺ salida a medio dibujar\n  sin pistas de teclas").panel, "No key hint, no panel.")
        XCTAssertEqual(TerminalKey.left.tmuxName, "Left")
        XCTAssertEqual(TerminalKey.right.keyCode, 124)
        XCTAssertFalse(TerminalKey.menuKeys.contains(.left), "The composer's key strip stays as it was.")
    }

    func testNoBlindEnterWhenTheScreenCannotBeRead() throws {
        var actions: [String] = []
        // Terminal's own Return already went with the text; another one on a guess could answer a dialog.
        try TerminalAppBridge.deliver("hola", agent: .claude, timing: .init(poll: 0.01, echo: 0.05, settle: 0.05), run: { actions.append($0) }, read: { nil })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("hola")])
    }

    func testMessageEchoToleratesWrappingAndPastePlaceholders() {
        let message = "revisa el archivo PanelView.swift y dime qué ves"
        XCTAssertTrue(MessageEcho.pending(message, in: [rule, "❯ revisa el archivo PanelView.swift y", "  dime qué ves", rule].joined(separator: "\n"), agent: .claude))
        XCTAssertTrue(MessageEcho.pending("largo", in: claudeScreen("[Pasted text #1 +12 lines]"), agent: .claude))
        XCTAssertFalse(MessageEcho.pending(message, in: claudeScreen(""), agent: .claude))
        XCTAssertFalse(MessageEcho.pending(message, in: "⏺ revisa el archivo PanelView.swift y dime qué ves", agent: .claude), "Claude's transcript echo is not its box.")
        XCTAssertFalse(MessageEcho.pending("sí", in: claudeScreen("sí, hazlo también en Codex"), agent: .claude), "A short message inside Claude's next suggestion is not the message.")
        XCTAssertTrue(MessageEcho.pending("hola", in: "salida\n› hola", agent: .codex))
        XCTAssertEqual(TerminalAppBridge.typeAction("ls"), "do script \"ls\" in t")
        XCTAssertFalse(TerminalKey.enter.needsDirectKeys, "Enter travels as Terminal's own Return.")
        XCTAssertTrue(TerminalKey.allCases.filter { $0 != .enter }.allSatisfy(\.needsDirectKeys))
    }

    func testKeyAndMessageScriptsCompileWithInstalledTerminalDictionary() {
        let long = String(repeating: "línea con \"comillas\", $VAR y \\barra\n", count: 40)
        for action in [TerminalAppBridge.typeAction("Hola \"gato\"\nlínea"), TerminalAppBridge.returnAction, TerminalAppBridge.presentForKeysAction,
                       TerminalAppBridge.messageAction(long), TerminalAppBridge.messageAction("!" + long)] {
            var details: NSDictionary?
            let source = TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: action)
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
        }
    }

    func testShowingTheTerminalKeepsTheIslandUntilTheUserMovesOn() {
        var retention = TerminalRetention()
        let start = Date()
        retention.keep(appPID: 7, mirror: false, now: start)
        XCTAssertTrue(retention.holds(now: start.addingTimeInterval(1), mirrorIsKey: false) { _ in false }, "Terminal is still coming forward.")
        XCTAssertTrue(retention.holds(now: start.addingTimeInterval(30), mirrorIsKey: false) { $0 == 7 })
        XCTAssertFalse(retention.holds(now: start.addingTimeInterval(31), mirrorIsKey: false) { _ in false })
        XCTAssertFalse(retention.holds(now: start.addingTimeInterval(32), mirrorIsKey: false) { _ in true }, "Once released, returning to Terminal later does not pin the island.")
        XCTAssertNil(retention.appPID)

        retention.keep(appPID: nil, mirror: true, now: start)
        XCTAssertTrue(retention.holds(now: start.addingTimeInterval(10), mirrorIsKey: true) { _ in false })
        XCTAssertFalse(retention.holds(now: start.addingTimeInterval(11), mirrorIsKey: false) { _ in false })
        retention.keep(appPID: 7, mirror: false, now: start)
        retention.end()
        XCTAssertFalse(retention.holds(now: start, mirrorIsKey: false) { _ in true })
    }
}
