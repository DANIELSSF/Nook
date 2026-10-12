import XCTest
@testable import Nook

/// How a message reaches Claude or Codex in a Terminal tab, with the cases Sample hit (2026-10-05/06, deliveries.log).
final class ClaudeDeliveryTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    /// A long echo window costs nothing (a delivery returns as soon as it sees what happened) and keeps a slow, throttled run
    /// from running out of time; only the tests about nothing happening use the short one.
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1)
    private let quiet = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.3, hold: 0.05, settle: 0.1)

    private func screen(_ conversation: [String], box: String) -> String { (conversation + [rule, "❯ " + box, rule, footer]).joined(separator: "\n") }

    /// Sample's paste of 5/10 10:02:56, which reached Claude cut.
    static let shellTranscript = """
        developer@MacBook-Pro-Example app % dig +short demo-development-service-tunnel.example.invalid
        developer@MacBook-Pro-Example app % curl -fsS -H "Authorization: Bearer $TABLERO_TOKEN" "$TABLERO/cliente.mjs" -o ~/.claude/tablero.mjs
        curl: (3) URL rejected: No host part in the URL
        developer@MacBook-Pro-Example app %      node ~/.claude/tablero.mjs siguiente
        node:internal/modules/cjs/loader:1568
          throw err;
          ^

        Error: Cannot find module '/Users/developer/.claude/tablero.mjs'
            at Module._resolveFilename (node:internal/modules/cjs/loader:1564:15)
            at wrapResolveFilename (node:internal/modules/cjs/loader:1118:27)
            at defaultResolveImplForCJSLoading (node:internal/modules/cjs/loader:1142:10)
            at resolveForCJSWithHooks (node:internal/modules/cjs/loader:1169:12)
            at Module._load (node:internal/modules/cjs/loader:1341:5)
            at wrapModuleLoad (node:internal/modules/cjs/loader:261:19)
            at Module.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:154:5)
            at node:internal/main/run_main_module:33:47 {
          code: 'MODULE_NOT_FOUND',
          requireStack: []
        }

        Node.js v24.20.0
        developer@MacBook-Pro-Example app %
        """

    func testALongPasteTravelsBetweenBracketedPasteMarksInOneScript() {
        let message = "” " + Self.shellTranscript + " “"
        XCTAssertGreaterThan(message.utf8.count, 1022, "Longer than one of Terminal's pieces: it used to arrive split.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(message))
        let action = TerminalAppBridge.messageAction(message)
        XCTAssertTrue(action.hasPrefix("do script ((character id 27) & \"[200~\" & \""), action)
        XCTAssertTrue(action.hasSuffix("& (character id 27) & \"[201~\") in t"), action)
        XCTAssertEqual(action.components(separatedBy: "[200~").count, 2, "One paste, opened once…")
        XCTAssertEqual(action.components(separatedBy: "[201~").count, 2, "…and closed once.")
        XCTAssertTrue(action.contains(#"$TABLERO_TOKEN"#) && action.contains(#"\"Authorization: Bearer"#), "Quotes are escaped, $ travels as is.")
        var details: NSDictionary?
        let source = TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: action)
        XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
    }

    func testShortOneLineMessagesStillTravelAsTypedText() {
        for message in ["recomendado", "/model", "/usage", "aplica lo recomendado", "! gh pr merge 26 -R example-team/app --merge"] {
            XCTAssertTrue(TerminalAppBridge.typesDirectly(message), message)
            XCTAssertEqual(TerminalAppBridge.messageAction(message), TerminalAppBridge.typeAction(message))
        }
        XCTAssertFalse(TerminalAppBridge.typesDirectly("dos\nlíneas"), "Any line break goes as a paste.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(String(repeating: "ñ", count: 101)), "The limit counts bytes, not characters.")
    }

    func testShellModeKeepsItsBangAsAKeyAndEscapesNeverTravel() {
        let long = "!" + String(repeating: "echo uno && echo dos\n", count: 20)
        let action = TerminalAppBridge.messageAction(long)
        XCTAssertTrue(action.hasPrefix("do script (\"!\" & (character id 27) & \"[200~\" & \"echo uno"), "The ! is Claude's shell mode, typed before the paste.")
        XCTAssertFalse(TerminalAppBridge.messageAction("hola\u{1b}[201~ mundo").contains("\u{1b}"), "An Escape would end the paste early.")
        XCTAssertFalse(TerminalAppBridge.messageAction(String(repeating: "x\u{1b}", count: 200)).contains("\u{1b}"))
        XCTAssertTrue(MessageEcho.boxHolds("gh pr merge 26", "! gh pr merge 26"), "In shell mode Claude's box shows the command without its !.")
        XCTAssertFalse(MessageEcho.boxHolds("", "!"))
    }

    /// 5/10 9:42:42: "/model" went typed, Terminal's Return opened the picker, and Nook's blind Enter 3 s later chose the
    /// highlighted model, closing it ("en el terminal se abre pero después se cierra").
    func testTheModelPickerAMessageOpensGetsNoEnter() throws {
        let picker = ["⏺ Hola", "", "> /model", "", " Select model", " Switch between Claude models. Applies to this session and future Claude Code sessions.", "",
                      " ❯ 1. Default (recommended) ✔  Opus 5.5 · Most capable for complex work",
                      "   2. Sonnet                   Sonnet 5.5 · Best for everyday tasks",
                      "   3. Haiku                    Haiku 4.5 · Fastest for quick answers", "",
                      " Enter to confirm · Esc to exit"].joined(separator: "\n")
        var actions: [String] = [], steps: [String] = []
        try TerminalAppBridge.deliver("/model", agent: .claude, timing: fast, run: { actions.append($0) },
                                      read: { actions.isEmpty ? self.screen(["⏺ Hola"], box: "Try \"fix lint errors\"") : picker }, trace: { steps.append($0) })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("/model")], "Nothing after the picker opened.")
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
    }

    /// 6/10 9:04:45 "recomendado": Claude took the typed message with Terminal's Return; the box emptied while it worked.
    func testATypedMessageClaudeSentAtOnceGetsNoEnter() throws {
        var actions: [String] = []
        let working = (["⏺ Hola", "", "> recomendado", "", "✻ Churning… (2s · esc to interrupt)"] + [rule, "❯ ", rule, footer]).joined(separator: "\n")
        try TerminalAppBridge.deliver("recomendado", agent: .claude, timing: fast, run: { actions.append($0) },
                                      read: { actions.isEmpty ? self.screen(["⏺ Hola"], box: "") : working })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("recomendado")])
    }

    func testAnUnchangedScreenIsNotTakenForAnArrival() throws {
        var actions: [String] = [], steps: [String] = []
        let same = screen(["⏺ Hola"], box: "")
        try TerminalAppBridge.deliver("hola", agent: .claude, timing: quiet, run: { actions.append($0) }, read: { same }, trace: { steps.append($0) })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("hola")], "No Enter on a guess.")
        XCTAssertEqual(steps.last, "sin cambios en 0 s; sin Enter")
    }

    func testClaudeStillReadingTheKeysIsNeitherTakenNorHeld() {
        var reads = 0
        // "hol", then "hola" held: the partial box never counts as taken.
        let arrival = TerminalAppBridge.arrival(of: "hola", before: screen([], box: ""), timing: .init(poll: 0.01, echo: 5, hold: 0.05), read: {
            reads += 1
            return self.screen([], box: reads < 4 ? "hol" : "hola")
        })
        XCTAssertEqual(arrival, .waiting)
        XCTAssertTrue(MessageEcho.partial("hol", of: "hola"))
        XCTAssertFalse(MessageEcho.partial("hola", of: "hola"))
        XCTAssertFalse(MessageEcho.partial("ok, espero el bloque 2", of: "ok"), "A grey suggestion is not the message being typed.")
    }

    func testOneScreenCaughtMidRedrawIsNotAnArrival() {
        var reads = 0
        // A single reading without the box, then the message sits in the box: held, not taken.
        let arrival = TerminalAppBridge.arrival(of: "hola gato", before: screen([], box: ""), timing: .init(poll: 0.01, echo: 5, hold: 0.05), read: {
            reads += 1
            return reads == 1 ? "⏺ Hola\n" + self.rule : self.screen([], box: "hola gato")
        })
        XCTAssertEqual(arrival, .waiting)
    }

    func testAnAnswerTypedIntoADialogsFieldIsHeldThere() {
        let question = ["⏺ Antes de empezar necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                        "  1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                        "❯ 3. Type something.", String(repeating: "─", count: 40), "  4. Chat about this", "",
                        "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let typed = question.map { $0 == "❯ 3. Type something." ? "❯ 3. Usa MongoDB con réplica" : $0 }
        let before = question.joined(separator: "\n")
        XCTAssertNotNil(AgentPrompt.parse(before), "Fixture: a dialog Nook recognises.")
        var reads = 0
        let arrival = TerminalAppBridge.arrival(of: "Usa MongoDB con réplica", before: before, timing: .init(poll: 0.01, echo: 5, hold: 0.05), read: {
            reads += 1
            return (reads < 2 ? question : typed).joined(separator: "\n")
        })
        XCTAssertEqual(arrival, .waiting, "The field shows the answer: Enter is still needed there.")
    }

    // MARK: - A message equal to what the box shows (deliveries.log 6/10 13:19, 13:29, 13:30)

    private let deploy = "! infra/gcp/deploy.sh dev"

    /// After running it once, Claude suggests the same command in grey. Enter doesn't take a suggestion: it used to be pressed
    /// three times and the command never ran. Now the message is typed after the first Enter changes nothing.
    func testAGreySuggestionEqualToTheMessageIsTypedOver() throws {
        var actions: [String] = [], steps: [String] = []
        let ghost = screen(["⏺ Listo, desplegado."], box: deploy)
        // Typed: Claude runs it in shell mode, its echo shows above the box, and then it suggests the same command again.
        let ran = screen(["⏺ Listo, desplegado.", "", deploy, "  ⎿  Deploying to dev…"], box: deploy)
        try TerminalAppBridge.deliver(deploy, agent: .claude, timing: fast, run: { actions.append($0) },
                                      read: { actions.contains(TerminalAppBridge.typeAction(self.deploy)) ? ran : ghost }, trace: { steps.append($0) })
        XCTAssertEqual(actions, [TerminalAppBridge.returnAction, TerminalAppBridge.typeAction(deploy)], "One Enter that did nothing, then typed once; no Enter after.")
        XCTAssertEqual(steps, ["caja antes: «\(deploy)»", "ya estaba en la caja: Enter", "era la sugerencia gris de Claude: se escribe", "escrito con su Enter", "Claude lo tomó: enviado"])
    }

    func testTheSameTextReallyTypedInTheBoxGoesWithItsEnterAndIsNotTypedAgain() throws {
        var actions: [String] = []
        // Typed in the terminal by hand: Enter runs it, its echo shows and the box empties.
        try TerminalAppBridge.deliver(deploy, agent: .claude, timing: fast, run: { actions.append($0) }, read: {
            actions.isEmpty ? self.screen(["⏺ Listo."], box: self.deploy) : self.screen(["⏺ Listo.", "", self.deploy, "  ⎿  Deploying to dev…"], box: "")
        })
        XCTAssertEqual(actions, [TerminalAppBridge.returnAction])
        // Claude ran it and at once suggests it again: the echo above the box says it went.
        var again: [String] = []
        try TerminalAppBridge.deliver(deploy, agent: .claude, timing: fast, run: { again.append($0) }, read: {
            self.screen(again.isEmpty ? ["⏺ Listo."] : ["⏺ Listo.", "", self.deploy, "  ⎿  Deploying to dev…"], box: self.deploy)
        })
        XCTAssertEqual(again, [TerminalAppBridge.returnAction], "No second copy, no extra Enter.")
    }

    func testShellModeBoxIsReadWithItsOwnMark() throws {
        // Claude switches its box to shell mode on "!": the mark becomes "!" (pink in the terminal) instead of "❯".
        let bash = [rule, deploy, rule, "  ! for bash mode"].joined(separator: "\n")
        XCTAssertEqual(ClaudeComposer.split(bash).input, "infra/gcp/deploy.sh dev")
        XCTAssertTrue(MessageEcho.pending(deploy, in: bash, agent: .claude))
        XCTAssertTrue(MessageEcho.partial("infra/gcp/dep", of: deploy), "Still being typed in shell mode.")
        // Held there (Terminal's Return became a new line): one Enter, then it ran.
        var actions: [String] = []
        try TerminalAppBridge.deliver(deploy, agent: .claude, timing: fast, run: { actions.append($0) }, read: {
            actions.isEmpty ? self.screen(["⏺ Listo."], box: "") : actions.count == 1 ? "⏺ Listo.\n" + bash : self.screen(["⏺ Listo.", "", self.deploy], box: "")
        })
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction(deploy), TerminalAppBridge.returnAction])
        // A long shell command keeps "!" as a key in front of the paste.
        XCTAssertTrue(TerminalAppBridge.messageAction("!" + String(repeating: " echo uno &&", count: 30) + " echo fin").hasPrefix("do script (\"!\" & (character id 27)"))
    }

    func testAMessageStuckInTheBoxIsNeverASilentSuccess() {
        var actions: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver("hola gato", agent: .claude, timing: fast, run: { actions.append($0) },
                                                         read: { self.screen(["⏺ Hola"], box: actions.isEmpty ? "" : "hola gato") })) { error in
            guard case DeliveryError.stuck = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(actions.filter { $0 == TerminalAppBridge.returnAction }.count, 3)
    }

    func testCodexGetsNoSecondEnterAfterABracketedPaste() throws {
        var actions: [String] = []
        try TerminalAppBridge.deliver(Self.shellTranscript, agent: .codex, timing: fast, run: { actions.append($0) }, read: { "› [Pasted Content 1520 chars]" })
        XCTAssertEqual(actions, [TerminalAppBridge.messageAction(Self.shellTranscript)])
        var typed: [String] = []
        try TerminalAppBridge.deliver("hola", agent: .codex, timing: fast, run: { typed.append($0) }, read: { "› hola" })
        XCTAssertEqual(typed, [TerminalAppBridge.typeAction("hola"), TerminalAppBridge.returnAction], "Typed text keeps Codex's old way.")
    }

    func testClaudeGetsSamplesPasteWholeAndOneEnterAtMost() throws {
        var actions: [String] = []
        let placeholder = screen(["⏺ Hola"], box: "[Pasted text #1 +22 lines]")
        // Claude collapsed the paste and kept it (its Return arrived first): one Enter, then it is gone.
        try TerminalAppBridge.deliver(Self.shellTranscript, agent: .claude, timing: fast, run: { actions.append($0) },
                                      read: { actions.count == 1 ? placeholder : self.screen(["⏺ Hola"], box: "") })
        XCTAssertEqual(actions, [TerminalAppBridge.messageAction(Self.shellTranscript), TerminalAppBridge.returnAction])
    }

    // MARK: Edge cases added by QA

    func testTheTypedLimitIsExactly200BytesAndLineBreaksOfAnyKindPaste() {
        let at200 = String(repeating: "a", count: 200), at201 = String(repeating: "a", count: 201)
        XCTAssertTrue(TerminalAppBridge.typesDirectly(at200))
        XCTAssertEqual(TerminalAppBridge.messageAction(at200), TerminalAppBridge.typeAction(at200))
        XCTAssertFalse(TerminalAppBridge.typesDirectly(at201))
        XCTAssertTrue(TerminalAppBridge.messageAction(at201).contains("[200~"))
        XCTAssertFalse(TerminalAppBridge.typesDirectly("uno\r\ndos"), "CRLF is a line break.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly("uno\rdos"))
        XCTAssertFalse(TerminalAppBridge.typesDirectly("uno\u{2028}dos"))
        // 4-byte emoji: 50 of them are 200 bytes, 51 are not.
        XCTAssertTrue(TerminalAppBridge.typesDirectly(String(repeating: "😀", count: 50)))
        XCTAssertFalse(TerminalAppBridge.typesDirectly(String(repeating: "😀", count: 51)))
        XCTAssertTrue(TerminalAppBridge.typesDirectly(""), "An empty message is not a paste.")
    }

    func testALoneBangIsNotShellModeAndAnEscapedPasteMarkIsOnlyText() {
        XCTAssertTrue(TerminalAppBridge.typesDirectly("!"))
        let long = "!" + String(repeating: "x", count: 250)
        XCTAssertTrue(TerminalAppBridge.messageAction(long).hasPrefix("do script (\"!\" & (character id 27)"))
        // Text that spells the end mark loses its ESC: only the one real closing mark remains.
        let sneaky = String(repeating: "y", count: 250) + "\u{1b}[201~ rm -rf ~\n"
        let action = TerminalAppBridge.messageAction(sneaky)
        XCTAssertEqual(action.components(separatedBy: "(character id 27)").count - 1, 2, "Only Nook's own two Escapes.")
        var details: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: TerminalAppBridge.targetScript(windowID: 1, tty: "/dev/ttys001", action: action))!.compileAndReturnError(&details), details?.description ?? "")
    }

    func testAMessageWithEveryAwkwardCharacterCompilesAsOneStatement() {
        let nasty = String(repeating: "it's \"q\" $HOME `x` $(y) \\n \t ñ 😀 日本\n", count: 15)
        var details: NSDictionary?
        for text in [nasty, "\"", "\\", String(repeating: "\\\"", count: 120)] {
            let source = TerminalAppBridge.targetScript(windowID: 1, tty: "/dev/ttys001", action: TerminalAppBridge.messageAction(text))
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
        }
    }
}
