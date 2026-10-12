import XCTest
@testable import Nook

/// Claude's dialogs read in full: long questions, long descriptions, several questions, boxes to tick, and the menus a slash
/// command opens (the model picker). Shapes follow Claude Code 2.1.29x as users see it; none was captured from a live
/// session by the tests (Nook can't drive Claude here), so each fixture says what it stands for.
final class ClaudeDialogTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    /// AskUserQuestion with one question: its label, a question that wraps over three lines, four options whose
    /// descriptions wrap (one over four lines), the free-text field and "Chat about this" under its own rule.
    private var longQuestion: [String] {
        ["⏺ Necesito decidir cómo autenticar.", "", rule, " ☐ Auth method", "",
         "Which authentication method should the new endpoint use? It has to work for",
         "both the mobile app and the web dashboard, and the tokens must survive a",
         "server restart.", "",
         "❯ 1. JWT tokens",
         "     Stateless tokens signed with a shared secret; easy to scale",
         "     horizontally, but revoking one before it expires needs a deny list.",
         "  2. Session cookies",
         "     Server-side sessions stored in Redis; simple to revoke.",
         "  3. OAuth with the company SSO",
         "     Reuses the existing provider; needs a new client registration,",
         "     a redirect URL per environment and a consent screen that legal",
         "     has to approve before launch, which can take two weeks. Press Enter",
         "     to confirm only if legal already agreed.",
         "  4. API keys",
         "     One key per client.",
         "  5. Type something.",
         rule,
         "  6. Chat about this", "",
         "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    }

    func testALongQuestionKeepsEveryLineOfTheQuestionAndOfEachDescription() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(longQuestion)))
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.header, "Auth method")
        XCTAssertEqual(prompt.tabs, [])
        XCTAssertEqual(prompt.question, "Which authentication method should the new endpoint use? It has to work for both the mobile app and the web dashboard, and the tokens must survive a server restart.",
                       "Every wrapped line of the question, not only the last one.")
        XCTAssertEqual(prompt.options.map(\.title), ["JWT tokens", "Session cookies", "OAuth with the company SSO", "API keys", "Type something.", "Chat about this"])
        XCTAssertEqual(prompt.options[0].detail, "Stateless tokens signed with a shared secret; easy to scale horizontally, but revoking one before it expires needs a deny list.")
        XCTAssertEqual(prompt.options[2].detail, "Reuses the existing provider; needs a new client registration, a redirect URL per environment and a consent screen that legal has to approve before launch, which can take two weeks. Press Enter to confirm only if legal already agreed.",
                       "A description over four lines stays whole, even with a hint's words in it.")
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .none, .none, .inline, .followUp])
        XCTAssertEqual(prompt.highlighted, 0)
        XCTAssertFalse(prompt.multiSelect)
        XCTAssertEqual(prompt.keys(choosing: 3), [.down, .down, .down, .enter])
        // The card shows the label, question and options; the mirror keeps only what came before.
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(longQuestion)), lines(["⏺ Necesito decidir cómo autenticar.", "", rule]))
    }

    func testAQuestionThatContainsAHintsWordsIsStillTheQuestion() throws {
        let rows = [" ☐ Branch", "", "Which branch should I use to confirm the fix before the release?", "", "❯ 1. main", "  2. develop", "", "Enter to select · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.question, "Which branch should I use to confirm the fix before the release?")
        XCTAssertEqual(prompt.header, "Branch")
    }

    func testAQuestionInParagraphsKeepsThemAll() throws {
        let rows = [" ☐ Scope", "", "The migration touches 14 tables.", "", "Should I run it now or wait for the backup?", "", "❯ 1. Now", "  2. Wait", "", "Enter to select · Esc to cancel"]
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(rows))).question, "The migration touches 14 tables.\nShould I run it now or wait for the backup?")
    }

    func testSeveralQuestionsShowTheirTabs() throws {
        let rows = [rule, "←  ☒ Database  ☐ Cache  ✔ Submit  →", "", "Which cache should we put in front of it?", "",
                    "❯ 1. Redis", "     In-memory, battle tested", "  2. Memcached", "     Simpler, no persistence", "  3. Type something.", rule,
                    "  4. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertNil(prompt.header)
        XCTAssertEqual(prompt.tabs, [AgentPrompt.Tab(title: "Database", answered: true, isSubmit: false), AgentPrompt.Tab(title: "Cache", answered: false, isSubmit: false),
                                     AgentPrompt.Tab(title: "Submit", answered: false, isSubmit: true)])
        XCTAssertEqual(prompt.question, "Which cache should we put in front of it?")
        XCTAssertEqual(prompt.options.map(\.detail), ["In-memory, battle tested", "Simpler, no persistence", nil, nil])
        XCTAssertEqual(prompt.kind, .question)
    }

    func testBoxesToTickMakeAMultipleChoiceQuestion() throws {
        let rows = [" ☐ Platforms", "", "Which platforms should the release support?", "",
                    "❯ 1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "  3. [ ] Linux", "  4. Type something.", "  5. Submit", "",
                    "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertTrue(prompt.multiSelect)
        XCTAssertEqual(prompt.options.map(\.title), ["macOS", "iOS", "Linux", "Type something.", "Submit"])
        XCTAssertEqual(prompt.options.map(\.checked), [false, true, false, nil, nil])
        XCTAssertEqual(prompt.options[0].detail, "Apple Silicon and Intel")
        XCTAssertEqual(prompt.signature, try XCTUnwrap(AgentPrompt.parse(lines(rows).replacingOccurrences(of: "[ ] macOS", with: "[✔] macOS"))).signature,
                       "Ticking a box is the same question.")
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(rows).replacingOccurrences(of: "[ ]", with: "☐").replacingOccurrences(of: "[✔]", with: "☒"))).options.map(\.checked),
                       [false, true, false, nil, nil], "Drawn boxes count as well.")
    }

    // MARK: - Permissions and plans

    func testAPermissionPromptOfTodayStillReadsWithItsCommandOutOfTheQuestion() throws {
        let rows = ["⏺ Bash(git push origin main)", rule, " Bash command", "", "   git push origin main", "   Push the release branch", "",
                    " Permission rule Bash(git push:*) requires confirmation for this command.", "", " Do you want to proceed?",
                    " ❯ 1. Yes", "   2. Yes, and don't ask again for git push commands in /Users/me/project", "   3. No, and tell Claude what to do differently (esc)", "",
                    " Esc to cancel · Tab to amend · ctrl+e to explain"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.context, "Bash(git push origin main)")
        XCTAssertEqual(prompt.options[1].title, "Yes, and don't ask again for git push commands in /Users/me/project")
    }

    func testAPlanApprovalWithItsEditorHint() throws {
        let rows = ["⏺ Plan listo.", "", " Would you like to proceed?", "", " ❯ 1. Yes, and auto-accept edits", "   2. Yes, and manually approve edits",
                    "   3. No, keep planning", "", " ctrl-g to edit in VS Code"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.question, "Would you like to proceed?")
        XCTAssertEqual(prompt.options.count, 3)
    }

    // MARK: - The model picker and other menus

    /// `/model` in Claude Code 2.1.29x: a title over a description that wraps, numbered models with their own column, the
    /// current one ticked, the effort under them (changed with ← →) and "Esc to exit".
    private var modelPicker: [String] {
        ["⏺ Listo.", "", rule, " Select model", " Switch between Claude models. Applies to this session and future Claude",
         " Code sessions. For other/previous model names, specify with --model.", "",
         " ❯ 1. Default (recommended) ✔  Opus 5.5 · Most capable for complex work",
         "   2. Sonnet                   Sonnet 5.5 · Best for everyday tasks",
         "   3. Haiku                    Haiku 4.5 · Fastest for quick answers", "",
         " ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]
    }

    func testTheModelPickerIsAMenuWithTheCurrentModelAndTheEffort() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(modelPicker)))
        XCTAssertEqual(prompt.kind, .selector, "A menu the user opened: no alert, and it does not hold the island.")
        XCTAssertEqual(prompt.question, "Select model")
        XCTAssertEqual(prompt.note, "Switch between Claude models. Applies to this session and future Claude Code sessions. For other/previous model names, specify with --model.")
        XCTAssertEqual(prompt.options.map(\.title), ["Default (recommended)", "Sonnet", "Haiku"])
        XCTAssertEqual(prompt.options.map(\.detail), ["Opus 5.5 · Most capable for complex work", "Sonnet 5.5 · Best for everyday tasks", "Haiku 4.5 · Fastest for quick answers"])
        XCTAssertEqual(prompt.options.map(\.current), [true, false, false])
        XCTAssertEqual(prompt.adjustment, "Medium effort (default)")
        XCTAssertEqual(prompt.keys(choosing: 1), [.down, .enter])
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(modelPicker)), lines(["⏺ Listo.", "", rule]))
    }

    func testTheTickCanFollowTheDescriptionAndTheModelsCanComeWithoutNumbers() throws {
        let older = ["Select model", "", "   1. Default (recommended)   Use the default model", " ❯ 2. Opus                    Opus for complex tasks ✔", "   3. Haiku                   Haiku for simple tasks", "",
                     "Enter to confirm · Esc to exit"]
        let numbered = try XCTUnwrap(AgentPrompt.parse(lines(older)))
        XCTAssertEqual(numbered.options.map(\.current), [false, true, false])
        XCTAssertEqual(numbered.options[1].detail, "Opus for complex tasks")
        XCTAssertEqual(numbered.highlighted, 1)
        let plain = try XCTUnwrap(AgentPrompt.parse(lines(["Select model", "", " ❯ Opus ✔", "   Sonnet", "   Haiku", "", " ←/→ to adjust effort · Enter to confirm · Esc to exit"])))
        XCTAssertEqual(plain.kind, .selector)
        XCTAssertEqual(plain.options.map(\.title), ["Opus", "Sonnet", "Haiku"])
        XCTAssertEqual(plain.options.map(\.current), [true, false, false])
    }

    func testTheModelPickerReachesTheSessionAsACardNotAPanel() {
        let model = AppModel(receivesSignals: false)
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: lines(modelPicker))
        tab.history = true
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertEqual(session.prompt?.kind, .selector)
        XCTAssertEqual(session.prompt?.options.count, 3)
        XCTAssertNil(session.panel, "The card answers it; the raw panel stays away.")
        XCTAssertFalse(model.promptHoldsIsland)
    }

    func testAnOpenQuestionIsNotAMenuEvenWithEscToExit() throws {
        // Claude's own question keeps its alert even if a build words its hint like a menu's.
        let rows = [" ☐ Database", "", "Which database?", "", "❯ 1. PostgreSQL", "  2. SQLite", "  3. Type something.", "", "Enter to confirm · Esc to exit"]
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(rows))).kind, .question)
    }

    // MARK: - Claude's agent list under a dialog

    func testClaudesAgentListAfterTheDialogDoesNotHideIt() throws {
        let rows = longQuestion + ["", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage", "", "  ⏺️ main",
                                   "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.options.count, 6)
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(rows)), lines(["⏺ Necesito decidir cómo autenticar.", "", rule]))
    }

    // MARK: - Still not prompts

    func testRepliesWithTicksOrBoxesAreNotQuestions() {
        XCTAssertNil(AgentPrompt.parse(lines(["⏺ Hecho:", "  ✔ Tests", "  1. [x] macOS", "  2. [ ] Linux"])))
        XCTAssertNil(AgentPrompt.parse(lines(["✔ Done", "", "❯ 1. uno", "  2. dos", "", "⏺ Listo."])))
    }

    // MARK: Edge cases added by QA

    /// 12 options (two-digit numbers, accents, emoji) must all survive, in order, with their descriptions.
    func testAQuestionWithTwelveOptionsKeepsEveryOneInOrder() throws {
        var rows = [" ☐ País", "", "¿En qué país está el cliente? 🌎", ""]
        for n in 1...10 { rows += [(n == 1 ? "❯ " : "  ") + "\(n). Opción \(n) ñandú", "     Detalle de la opción \(n) 😀"] }
        rows += ["  11. Type something.", rule, "  12. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.options.count, 12)
        XCTAssertEqual(prompt.options.map(\.title).prefix(10).last, "Opción 10 ñandú")
        XCTAssertEqual(prompt.options[9].detail, "Detalle de la opción 10 😀")
        XCTAssertEqual(prompt.options[10].input, .inline)
        XCTAssertEqual(prompt.options[11].input, .followUp)
        XCTAssertEqual(prompt.question, "¿En qué país está el cliente? 🌎")
        XCTAssertEqual(prompt.keys(choosing: 11), Array(repeating: .down, count: 11) + [.enter])
    }

    /// Windows-style line ends in the screen text must not lose or merge options.
    func testACRLFScreenParsesLikeAnLFOne() throws {
        let lf = lines(longQuestion)
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let a = AgentPrompt.parse(lf), b = AgentPrompt.parse(crlf)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.options.map(\.title), b?.options.map(\.title))
        XCTAssertEqual(a?.question, b?.question)
    }

    // MARK: - The review step of several questions

    /// Sample's session (app, Claude Code 2.1.289, 2026-10-06): two questions with tabs "Id número" and "Modo Meta", both
    /// answered, on the step that sends them. Rebuilt from the AskUserQuestion in his record and the screenshot of Nook's card
    /// (imagen-06102026010504): a bar on the left of each question's lines, wrapped at about 115 columns, "→" with the answer
    /// on a line of its own, and "Ready to submit your answers?" over Submit and Cancel.
    private var reviewStep: [String] {
        [rule, "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
         "│ ● Según la doc de Meta (Embedded Signup v4), en el modo coexistencia el navegador recibe el id de la cuenta de",
         "│   WhatsApp Business (waba_id), pero NO el id del número (phone_number_id). La spec 18a exige ese id del número para",
         "│   conectar en todos los modos. ¿Qué hacemos?",
         "  → Opcional + lo busca el servidor (Recomendado)",
         "│ ● La doc de Meta v4 también dice que el modo (número nuevo o coexistencia) lo fija la configuración de Login for",
         "│   Business (config_id), no un parámetro del navegador como asume la spec. Para ofrecer los dos modos haría falta un",
         "│   segundo config_id: una sexta variable de entorno y otra configuración en la app de Meta. Es la pregunta abierta de",
         "│   la §10. ¿Qué hacemos?",
         "  → Dejarlo para EP2026-363 (Recomendado)", "",
         "Ready to submit your answers?", "",
         "❯ 1. Submit answers", "  2. Cancel", "",
         "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    }

    func testTheReviewStepIsEachQuestionWithItsAnswer() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(reviewStep)))
        XCTAssertEqual(prompt.reviewTitle, "Review your answers")
        XCTAssertEqual(prompt.question, "Ready to submit your answers?")
        XCTAssertEqual(prompt.review, [
            AgentPrompt.ReviewItem(question: "Según la doc de Meta (Embedded Signup v4), en el modo coexistencia el navegador recibe el id de la cuenta de WhatsApp Business (waba_id), pero NO el id del número (phone_number_id). La spec 18a exige ese id del número para conectar en todos los modos. ¿Qué hacemos?",
                                   answer: "Opcional + lo busca el servidor (Recomendado)", tab: "Id número"),
            AgentPrompt.ReviewItem(question: "La doc de Meta v4 también dice que el modo (número nuevo o coexistencia) lo fija la configuración de Login for Business (config_id), no un parámetro del navegador como asume la spec. Para ofrecer los dos modos haría falta un segundo config_id: una sexta variable de entorno y otra configuración en la app de Meta. Es la pregunta abierta de la §10. ¿Qué hacemos?",
                                   answer: "Dejarlo para EP2026-363 (Recomendado)", tab: "Modo Meta"),
        ], "The questions read as in Sample's record: no bar, no gaps, one space where the lines wrapped.")
        XCTAssertNil(prompt.warning)
        XCTAssertEqual(prompt.tabs.map(\.title), ["Id número", "Modo Meta", "Submit"])
        XCTAssertEqual(prompt.options.map(\.title), ["Submit answers", "Cancel"])
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertNil(prompt.header)
        XCTAssertFalse(prompt.question.contains("│") || prompt.review.contains { $0.question.contains("│") || $0.question.contains("|") })
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(reviewStep)), rule, "The whole step goes to the card.")
    }

    func testTheReviewStepWithSeveralAnswersAndAnUnansweredQuestion() throws {
        let rows = [rule, "←  ☒ Platforms  ☐ Database  ☒ Notes  ✔ Submit  →", "", "Review your answers", "",
                    "⚠ You have not answered all questions", "",
                    "│ ● Which platforms should the release support?", "  → macOS, iOS",
                    "│ ● Which database should we use for the cache layer that sits in front of the billing service when",
                    "│   it is under load?",
                    "│ ● Anything else?", "  → Keep the old endpoint alive until the mobile app ships the new client, then remove it",
                    "    in the next release.", "",
                    "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.warning, "You have not answered all questions")
        XCTAssertEqual(prompt.review.map(\.question), ["Which platforms should the release support?",
                                                      "Which database should we use for the cache layer that sits in front of the billing service when it is under load?",
                                                      "Anything else?"])
        XCTAssertEqual(prompt.review.map(\.answer), ["macOS, iOS", nil, "Keep the old endpoint alive until the mobile app ships the new client, then remove it in the next release."])
        XCTAssertEqual(prompt.review.map(\.tab), ["Platforms", "Database", "Notes"])
        // Several answers on lines of their own are joined the way Claude joins them on one.
        let split = rows.map { $0 == "  → macOS, iOS" ? "  → macOS\n  → iOS" : $0 }.joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(split)).review.first?.answer, "macOS, iOS")
        // Claude's own words for a question without an answer.
        let none = rows.map { $0 == "│   it is under load?" ? "│   it is under load?\n  → (no answer)" : $0 }.joined(separator: "\n")
        XCTAssertNil(try XCTUnwrap(AgentPrompt.parse(none)).review[1].answer)
    }

    func testAQuestionWithBulletsIsNotAReview() throws {
        let rows = [" ☐ Plan", "", "Which plan?", "", "• Plan A keeps the cache", "• Plan B drops it", "", "❯ 1. A", "  2. B", "", "Enter to select · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.review, [])
        XCTAssertEqual(prompt.question, "Which plan?\n• Plan A keeps the cache • Plan B drops it")
    }

    func testSideBarsNeverReachTheText() throws {
        // A dialog Claude draws with a bar on the left only, and one in a full box: neither bar is text.
        let left = ["│ ☐ Deploy", "│", "│ Which environment should the deploy go to? The staging one is shared", "│ with the mobile team this week.", "│",
                    "│ ❯ 1. Staging", "│      Shared with the mobile team", "│   2. Production", "│      Needs a second approval", "│",
                    "│ Enter to select · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(left)))
        XCTAssertEqual(prompt.header, "Deploy")
        XCTAssertEqual(prompt.question, "Which environment should the deploy go to? The staging one is shared with the mobile team this week.")
        XCTAssertEqual(prompt.options.map(\.title), ["Staging", "Production"])
        XCTAssertEqual(prompt.options.map(\.detail), ["Shared with the mobile team", "Needs a second approval"])
        let texts = [prompt.question] + prompt.options.flatMap { [$0.title, $0.detail ?? ""] }
        XCTAssertFalse(texts.contains { $0.contains("│") })
        // A table in a question keeps its own bars: only a lone bar at the edge is a border.
        let table = ["Which row is right?", "| a | b |", "", "❯ 1. a", "  2. b", "", "Enter to select · Esc to cancel"]
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(table))).options.count, 2)
    }

    // MARK: - The model picker as Claude Code 2.1.29x draws it

    /// Sample's screen (imagen-06102026042015, 2026-10-06), transcribed: a numbered list with the model in one column and its
    /// description in the next, the current one ticked, "↓" on the last row shown and "… +3 models" under it, the effort with
    /// ←/→, and three keys in the hint.
    private var realPicker: [String] {
        ["⏺ Listo.", "", rule,
         " Select model",
         " Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with",
         " --model.", "",
         "    1.  Default (recommended)  Sonnet 5.5 · Efficient for routine tasks",
         " ❯  2.  Opus 5.5 ✔             For complex work and everyday tasks",
         "    3.  Fable 5.1              For your toughest challenges",
         "    4.  Sonnet 5.5             Most efficient for simpler tasks",
         "    5.  Haiku 4.5              Fastest for quick answers",
         "    6.  Sonnet 5               Efficient for routine tasks",
         "    7.  Opus 5                 Best for everyday, complex tasks",
         "    8.  Fable 5                Most capable for your hardest and longest-running tasks",
         " ↓  9.  Opus 4.8               Best for everyday, complex tasks",
         "    … +3 models", "",
         " ● xHigh effort ←/→ to adjust", "",
         " Enter to set as default · s to use this session only · Esc to cancel"]
    }

    func testTheRealModelPickerIsACardWithEveryVisibleRow() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(realPicker)))
        XCTAssertEqual(prompt.kind, .selector)
        XCTAssertEqual(prompt.question, "Select model")
        XCTAssertEqual(prompt.note, "Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with --model.")
        XCTAssertEqual(prompt.options.map(\.number), Array(1...9))
        XCTAssertEqual(prompt.options.map(\.title), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Opus 5", "Fable 5", "Opus 4.8"],
                       "The scroll mark is not part of the name.")
        XCTAssertEqual(prompt.options[0].detail, "Sonnet 5.5 · Efficient for routine tasks")
        XCTAssertEqual(prompt.options[8].detail, "Best for everyday, complex tasks")
        XCTAssertEqual(prompt.options.map(\.current), [false, true, false, false, false, false, false, false, false])
        XCTAssertEqual(prompt.highlighted, 1)
        XCTAssertEqual(prompt.moreAbove, 0)
        XCTAssertEqual(prompt.moreBelow, 3)
        XCTAssertEqual(prompt.adjustment, "xHigh effort")
        XCTAssertEqual(prompt.actions, [AgentPrompt.KeyAction(key: "enter", label: "set as default"), AgentPrompt.KeyAction(key: "s", label: "use this session only"),
                                        AgentPrompt.KeyAction(key: "esc", label: "cancel")])
        XCTAssertEqual(prompt.secondaryAction, AgentPrompt.KeyAction(key: "s", label: "use this session only"))
        XCTAssertEqual(prompt.confirmLabel, "set as default")
        XCTAssertEqual(prompt.keys(choosing: 8), Array(repeating: .down, count: 7) + [.enter])
        XCTAssertTrue(ClaudeModelStore.isModelPicker(prompt), "What the catalog learns from.")
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines(realPicker)), lines(["⏺ Listo.", "", rule]))
    }

    func testTheRealModelPickerReachesTheTabAsACardAndFeedsTheCatalog() {
        let model = AppModel(receivesSignals: false)
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys093", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: lines(realPicker))
        tab.history = true
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        var seen: [AgentPrompt] = []
        session.onModelPicker = { seen.append($0) }
        var moved = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys093", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                        text: lines(realPicker).replacingOccurrences(of: " ❯  2.", with: "    2.").replacingOccurrences(of: "    3.  Fable 5.1", with: " ❯  3.  Fable 5.1"))
        moved.history = true
        session.update(moved)
        XCTAssertNil(session.panel, "Not the raw panel any more.")
        XCTAssertEqual(session.prompt?.kind, .selector)
        XCTAssertEqual(session.prompt?.highlighted, 2)
        XCTAssertEqual(seen.last?.options.compactMap(\.number), Array(1...9), "Every visible row, with its number.")
    }

    func testTheModelPickerScrolledPastItsStartKeepsItsNumbers() throws {
        let scrolled = ["⏺ Listo.", "", rule, " Select model", " Switch between Claude models. Your pick becomes the default for new sessions.", "",
                        " ↑  … +3 models",
                        "    4.  Sonnet 5.5             Most efficient for simpler tasks",
                        "    5.  Haiku 4.5              Fastest for quick answers",
                        "    6.  Sonnet 5               Efficient for routine tasks",
                        "    7.  Opus 5                 Best for everyday, complex tasks",
                        "    8.  Fable 5                Most capable for your hardest and longest-runn",
                        "    9.  Opus 4.8               Best for everyday, complex tasks",
                        "    10. Sonnet 4.6             Balanced for everyday tasks",
                        "    11. Haiku 4.5 (legacy)     Older fast model",
                        " ❯  12. Opus 4.7               Previous Opus", "",
                        " ● xHigh effort ←/→ to adjust", "", " Enter to set as default · s to use this session only · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(scrolled)))
        XCTAssertEqual(prompt.kind, .selector, "Scrolled away from its ticked row, still the menu: no alert, no hold.")
        XCTAssertTrue(ClaudeModelStore.isModelPicker(prompt))
        XCTAssertEqual(prompt.options.map(\.number), Array(4...12))
        XCTAssertEqual(prompt.options.last?.title, "Opus 4.7")
        XCTAssertEqual(prompt.options[4].detail, "Most capable for your hardest and longest-runn", "A description cut by a narrow pane stays as cut.")
        XCTAssertEqual(prompt.highlighted, 8)
        XCTAssertEqual(prompt.moreAbove, 3)
        XCTAssertEqual(prompt.moreBelow, 0)
        XCTAssertEqual(prompt.keys(choosing: 0), Array(repeating: .up, count: 8) + [.enter])
        // An "↑" on the first row shown, without a count, still says the list goes on above.
        let marked = scrolled.filter { $0 != " ↑  … +3 models" }.map { $0 == "    4.  Sonnet 5.5             Most efficient for simpler tasks" ? " ↑  4.  Sonnet 5.5             Most efficient for simpler tasks" : $0 }
        let up = try XCTUnwrap(AgentPrompt.parse(lines(marked)))
        XCTAssertEqual(up.kind, .selector)
        XCTAssertEqual(up.options.first?.title, "Sonnet 5.5")
        // With only "Esc to cancel" and no other sign, the scrolled list is still a menu, not a question.
        let plain = scrolled.map { $0.hasPrefix(" Enter to set") ? " Enter to confirm · Esc to cancel" : $0 }
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(plain))).kind, .selector)
        XCTAssertEqual(up.moreAbove, 1)
        // Without any sign of scrolling, a list that starts at 4 is still no list.
        XCTAssertNil(AgentPrompt.parse(lines(scrolled.filter { $0 != " ↑  … +3 models" })))
    }

    func testTheModelPickerInANarrowPaneAndWithEveryModelShown() throws {
        let narrow = [" Select model", " Switch between Claude models.", "",
                      "    1.  Default (recommended)  Sonnet 5.5 · Effi",
                      " ❯  2.  Opus 5.5 ✔             For complex work",
                      "    3.  Fable 5.1", "    4.  Haiku 4.5", "",
                      " ◑ Medium effort ←/→ to adjust", "", " Enter to set as default · s to use this session only · Esc to cancel"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(narrow)))
        XCTAssertEqual(prompt.options.map(\.title), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Haiku 4.5"])
        XCTAssertEqual(prompt.options.map(\.detail), ["Sonnet 5.5 · Effi", "For complex work", nil, nil])
        XCTAssertEqual(prompt.moreBelow, 0, "No \"+N\" line: every model is on screen.")
        XCTAssertEqual(prompt.adjustment, "Medium effort")
        XCTAssertEqual(prompt.options[1].current, true)
    }

    func testRealPanelsStayPanels() {
        // /config's list: unnumbered settings, no tick, "Esc to exit"; nothing here should turn into a numbered card.
        let config = ["  Settings  Status   Config   Usage   Stats", "", "  ❯ Auto-compact                       true", "    Show tips                          true",
                      "    Theme                              Dark mode", "", "  ↑/↓ to select · Enter to change · Esc to exit"]
        XCTAssertNotEqual(AgentPrompt.parse(lines(config))?.options.compactMap(\.number).isEmpty, false)
        let usage = ["  Settings  Status   Config   Usage   Stats", "", "  Current session", "  ███████▌                                           15% used", "  Resets 8:59pm",
                     "", "  Esc to cancel"]
        XCTAssertNil(AgentPrompt.parse(lines(usage)))
    }
}
