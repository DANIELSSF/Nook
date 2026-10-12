import XCTest
@testable import Nook

/// The shapes of the dialogs are the ones users see in Claude Code and Codex (see `AgentPrompt`); none was read from a
/// real session by the tests, so each case states what it stands for.
final class AgentPromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    private let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                              " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                              "   3. No, and tell Claude what to do differently (esc)"]

    // MARK: - Permission prompts

    func testPermissionPromptIsReadWithItsContext() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(permission)))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.context, "Bash(rm -rf build)")
        XCTAssertEqual(prompt.options.map(\.title), ["Yes", "Yes, and don't ask again for rm commands in this project", "No, and tell Claude what to do differently"])
        XCTAssertEqual(prompt.options.map(\.number), [1, 2, 3])
        XCTAssertEqual(prompt.highlighted, 0)
        XCTAssertEqual(prompt.options[2].shortcut, "esc", "The key an option names for itself leaves the title.")
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .followUp])
    }

    func testPermissionPromptWithoutBlankLinesAndWithHintsStillReads() throws {
        // The shape in the request: no blank line between the command and the question; newer builds add a hint line.
        var rows = permission
        rows.removeAll { $0.isEmpty }
        rows += ["", " Esc to cancel · Tab to amend"]
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(rows)))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.options.count, 3)
    }

    func testKeysReachTheOptionFromTheHighlight() throws {
        let first = try XCTUnwrap(AgentPrompt.parse(lines(permission)))
        XCTAssertEqual(first.keys(choosing: 0), [.enter], "Already highlighted: only Enter, which needs no Accessibility.")
        XCTAssertEqual(first.keys(choosing: 1), [.down, .enter])
        XCTAssertEqual(first.keys(choosing: 2), [.down, .down, .enter])
        XCTAssertEqual(first.keys(choosing: 9), [])
        XCTAssertEqual(first.moves(to: 2), 2)
        // The highlight can sit in the middle.
        let middle = permission.map { $0.replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   2. Yes,", with: " ❯ 2. Yes,") }
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(middle)))
        XCTAssertEqual(prompt.highlighted, 1)
        XCTAssertEqual(prompt.keys(choosing: 0), [.up, .enter])
        XCTAssertEqual(prompt.keys(choosing: 1), [.enter])
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .enter])
        XCTAssertEqual(prompt.signature, first.signature, "Moving the highlight does not make a new prompt.")
        let last = permission.map { $0.replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   3. No", with: " ❯ 3. No") }
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(lines(last))).keys(choosing: 0), [.up, .up, .enter])
    }

    func testPlanApproval() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(["⏺ Plan listo.", "", " Would you like to proceed?", "", " ❯ 1. Yes, and auto-accept edits",
                                                            "   2. Yes, and manually approve edits", "   3. No, keep planning"])))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.question, "Would you like to proceed?")
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .none], "Declining a plan is a plain option.")
    }

    func testCodexApprovalWithTheRightHighlight() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(["  Would you like to run the following command?", "", "  Reason: needs network access", "", "  $ git push origin main", "",
                                                            "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for this command (p)", "  3. No, and tell Codex what to do differently (esc)",
                                                            "", "  Press enter to confirm or esc to cancel"])))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.question, "$ git push origin main", "The line right above the options; the question stays in the mirror above it.")
        XCTAssertEqual(prompt.options.map(\.shortcut), ["y", "p", "esc"])
        XCTAssertEqual(prompt.options[2].input, .followUp)
        XCTAssertEqual(prompt.keys(choosing: 1), [.down, .enter])
    }

    func testClaudeDialogDrawnInsideARoundedBox() throws {
        // Older Claude builds draw the permission dialog in a box, with the tool call above it.
        let box = String(repeating: "─", count: 64)
        let edge = "│" + String(repeating: " ", count: 64) + "│"
        func row(_ text: String) -> String { "│ " + text + String(repeating: " ", count: 63 - text.count) + "│" }
        let screen = lines(["⏺ Bash(rm -rf build)", "╭" + box + "╮", row("Bash command"), edge, row("  rm -rf build"), row("  Delete the build folder"), edge, row("Do you want to proceed?"),
                            row("❯ 1. Yes"), row("  2. Yes, and don't ask again for rm commands in /tmp/project"), row("  3. No, and tell Claude what to do differently (esc)"), edge, "╰" + box + "╯"])
        let prompt = try XCTUnwrap(AgentPrompt.parse(ClaudeComposer.split(screen).conversation))
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.context, "Bash(rm -rf build)")
        XCTAssertEqual(prompt.options.map(\.title), ["Yes", "Yes, and don't ask again for rm commands in /tmp/project", "No, and tell Claude what to do differently"])
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .down, .enter])
        XCTAssertTrue(AgentPrompt.withoutPrompt(screen).contains("Delete the build folder"))
        XCTAssertFalse(AgentPrompt.withoutPrompt(screen).contains("Do you want to proceed?"))
    }

    func testCodexDialogDrawnInsideABox() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(["╭──────────────────────────────────────────╮", "│ Allow command?                           │", "│ $ rm -rf build                           │",
                                                            "│                                          │", "│ ❯ 1. Yes (y)                             │", "│   2. No, and tell Codex what to do (esc) │",
                                                            "╰──────────────────────────────────────────╯"])))
        XCTAssertEqual(prompt.options.map(\.title), ["Yes", "No, and tell Codex what to do"])
        XCTAssertEqual(prompt.highlighted, 0)
    }

    // MARK: - Questions

    private let question = ["⏺ Antes de empezar necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                            "❯ 1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                            "  3. Type something.", String(repeating: "─", count: 40), "  4. Chat about this", "",
                            "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    func testQuestionWithDescriptionsAndFreeTextOptions() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(question)))
        XCTAssertEqual(prompt.kind, .question)
        XCTAssertEqual(prompt.question, "Which database should we use?")
        XCTAssertEqual(prompt.options.map(\.title), ["PostgreSQL", "SQLite", "Type something.", "Chat about this"])
        XCTAssertEqual(prompt.options[0].detail, "Relational, strong consistency")
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .inline, .followUp])
        // A text field is reached, not confirmed: the user types into it and Nook's send presses Enter.
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .down])
        XCTAssertEqual(prompt.keys(choosing: 3), [.down, .down, .down, .enter], "Chatting about it leaves the dialog: Enter.")
        XCTAssertEqual(prompt.keys(choosing: 1), [.down, .enter])
        let onTheField = lines(question).replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  3. Type", with: "❯ 3. Type")
        XCTAssertEqual(try XCTUnwrap(AgentPrompt.parse(onTheField)).keys(choosing: 2), [], "Already on the text field: nothing to press.")
    }

    func testWhatWasPastedIntoADialogsTextFieldCountsAsSeen() {
        let typed = lines(question).replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  3. Type something.", with: "❯ 3. Usa MongoDB con réplica")
        XCTAssertTrue(MessageEcho.pending("Usa MongoDB con réplica", in: typed, agent: .claude), "The delivery presses Enter as soon as the field shows the text.")
        XCTAssertFalse(MessageEcho.pending("Usa MongoDB con réplica", in: lines(question), agent: .claude), "Not shown yet.")
        XCTAssertFalse(MessageEcho.pending("ok", in: lines(question) + " ok", agent: .claude), "A short message is not matched by chance.")
        XCTAssertFalse(MessageEcho.pending("Usa MongoDB con réplica", in: "⏺ Usa MongoDB con réplica", agent: .claude), "Without a dialog, only Claude's box counts, as before.")
    }

    func testQuestionWithOtherAsItsLastOption() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(["Which environments?", "❯ 1. Staging", "  2. Production", "  3. Other"])))
        XCTAssertEqual(prompt.options.map(\.input), [.none, .none, .inline])
        XCTAssertEqual(prompt.kind, .question)
    }

    func testLongQuestionThatWrapsIsJoined() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines([" Which approach do you prefer for handling authentication in the", " new endpoint?", "", " ❯ 1. Tokens", "   2. Sessions"])))
        XCTAssertEqual(prompt.question, "Which approach do you prefer for handling authentication in the new endpoint?")
    }

    // MARK: - Selectors without numbers

    func testSelectorWithoutNumbers() throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(lines(["⏺ Listo.", "", " Select model", " Switch between Claude models.", "", " ❯ Opus (recommended)  Most capable", "   Sonnet                Everyday tasks", "   Haiku", "", " Enter to confirm · Esc to exit"])))
        XCTAssertEqual(prompt.kind, .selector)
        XCTAssertEqual(prompt.question, "Select model")
        XCTAssertEqual(prompt.options.map(\.title), ["Opus (recommended)", "Sonnet", "Haiku"])
        XCTAssertEqual(prompt.options.map(\.number), [nil, nil, nil])
        XCTAssertEqual(prompt.options.map(\.shortcut), [nil, nil, nil], "\"(recommended)\" is not a key.")
        XCTAssertEqual(prompt.options.map(\.detail), ["Most capable", "Everyday tasks", nil], "A description aligned in a column leaves the title.")
        XCTAssertEqual(prompt.highlighted, 0)
        XCTAssertEqual(prompt.keys(choosing: 2), [.down, .down, .enter])
    }

    func testSelectorBetweenRulesKeepsItsOptionsAndAskedLine() throws {
        // Claude draws some selectors between rules; `ClaudeComposer` keeps them whole as a dialog.
        let screen = lines(["⏺ Hecho.", "", rule, " Choose the text style", "", "   Dark mode", " ❯ Light mode", "   Auto", "", " Enter to confirm · Esc to exit", rule])
        let prompt = try XCTUnwrap(AgentPrompt.parse(ClaudeComposer.split(screen).conversation))
        XCTAssertEqual(prompt.options.map(\.title), ["Dark mode", "Light mode", "Auto"])
        XCTAssertEqual(prompt.highlighted, 1)
        XCTAssertEqual(prompt.question, "Choose the text style")
        XCTAssertEqual(prompt.keys(choosing: 0), [.up, .enter])
    }

    // MARK: - What is not a prompt

    func testNumberedListInAReplyIsNotAPrompt() {
        XCTAssertNil(AgentPrompt.parse(lines(["⏺ Pendiente:", "  1. Reconecta la pestaña.", "  2. Dímelo si no la quitaste tú.", "  3. No he probado a mano Enter."])))
    }

    func testUserMessagesAndInputBoxesAreNotPrompts() {
        XCTAssertNil(AgentPrompt.parse("> 1. una pregunta\n> 2. otra"))
        XCTAssertNil(AgentPrompt.parse(lines(["⏺ Hecho.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"])))
        XCTAssertNil(AgentPrompt.parse(lines(["⏺ Hecho.", "", "› Ask Codex to do something", "", "  ? for shortcuts"])))
        // The user's own message that happens to look like an option, followed by the reply.
        XCTAssertNil(AgentPrompt.parse(lines(["❯ 1. arregla el bug", "  2. y luego escribe pruebas", "", "⏺ Voy a empezar por el bug."])))
    }

    func testAPromptThatScrolledAwayIsNotOpenAnyMore() {
        let old = lines(permission + ["", "⏺ Listo, borré la carpeta."] + (1...14).map { "línea \($0)" })
        XCTAssertNil(AgentPrompt.parse(old))
        XCTAssertNil(AgentPrompt.parse(lines(permission + ["", "⏺ Listo."])), "Even one line of output after it means it was answered.")
        XCTAssertNotNil(AgentPrompt.parse(lines(permission + ["", "  ⏵⏵ accept edits on (shift+tab to cycle)"])), "A mode line may follow a dialog.")
        XCTAssertNil(AgentPrompt.parse(lines(permission + ["", "⏺ Usa Enter to select la opción que prefieras."])), "A reply that happens to contain a hint's words is still a reply.")
    }

    func testShellOutputIsNotAPrompt() {
        XCTAssertNil(AgentPrompt.parse("~ % ls\n1. uno\n2. dos"))
        XCTAssertNil(AgentPrompt.parse("❯ ls\n1. uno\n2. dos"))
        XCTAssertNil(AgentPrompt.parse("❯ npm run build\n> nook@1.0.0 build\n> swift build\nBuild complete!"))
        XCTAssertNil(AgentPrompt.parse(""))
        XCTAssertNil(AgentPrompt.parse("⏺ Hecho."))
    }

    func testIncompleteOrAmbiguousListsAreNotPrompts() {
        XCTAssertNil(AgentPrompt.parse(lines([" ❯ 1. Yes"])), "One option is not a choice.")
        XCTAssertNil(AgentPrompt.parse(lines([" ? ", "   2. Yes", " ❯ 3. No"])), "The numbers must start at 1.")
        XCTAssertNil(AgentPrompt.parse(lines([" ❯ 1. Yes", "   3. No"])), "No gaps.")
        XCTAssertNil(AgentPrompt.parse(lines([" ❯ 1. Yes", " ❯ 2. No"])), "Exactly one highlighted option.")
        XCTAssertNil(AgentPrompt.parse(lines(["   1. Yes", "   2. No"])), "Nothing is highlighted: a list.")
        XCTAssertNil(AgentPrompt.parse(lines(["❯ Opus", "  Sonnet", "  Haiku"])), "Without the key hint a highlight is a shell prompt.")
        XCTAssertNotNil(AgentPrompt.parse(lines(["❯ Opus", "  Sonnet", "", "Enter to confirm"])), "A blank line before the hint is how the dialogs are drawn.")
        XCTAssertNil(AgentPrompt.parse(lines(["❯ Opus", "  Sonnet", "texto cualquiera", "Enter to confirm"])), "Anything else between the options and the hint means it is not their hint.")
        XCTAssertNil(AgentPrompt.parse(lines(["❯ Opus", "  Sonnet", "", "✶ Churning… (1m 2s · esc to interrupt)"])), "The spinner's hint is not a dialog hint.")
        let many = lines((1...13).map { ($0 == 1 ? " ❯ " : "   ") + "\($0). Opción \($0)" })
        XCTAssertNil(AgentPrompt.parse(many), "More options than a dialog shows.")
    }

    // MARK: - The mirror without the prompt

    func testMirrorKeepsTheContextAndDropsTheQuestionAndOptions() throws {
        let text = lines(["⏺ Voy a borrar.", ""] + permission)
        XCTAssertEqual(AgentPrompt.withoutPrompt(text), lines(["⏺ Voy a borrar.", "", "⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder"]))
        let withHint = text + "\n\n Esc to cancel · Tab to amend"
        XCTAssertEqual(AgentPrompt.withoutPrompt(withHint), AgentPrompt.withoutPrompt(text))
        XCTAssertEqual(AgentPrompt.withoutPrompt("⏺ Hecho.\n\nSin pregunta"), "⏺ Hecho.\n\nSin pregunta")
        XCTAssertEqual(AgentPrompt.withoutPrompt(lines([" Do you want to proceed?", " ❯ 1. Yes", "   2. No"])), "", "A prompt that fills the screen leaves nothing.")
        let selector = lines(["⏺ Listo.", "", " Select model", " Switch between Claude models.", "", " ❯ Opus", "   Sonnet", "", " Enter to confirm · Esc to exit"])
        XCTAssertEqual(AgentPrompt.withoutPrompt(selector), "⏺ Listo.")
    }

    func testADifferentQuestionHasAnotherSignature() throws {
        let first = try XCTUnwrap(AgentPrompt.parse(lines(permission)))
        let second = try XCTUnwrap(AgentPrompt.parse(lines(permission).replacingOccurrences(of: "rm -rf build", with: "rm -rf dist")))
        XCTAssertNotEqual(first.signature, second.signature, "The tool call is part of what identifies a prompt.")
    }

    // MARK: - On the session

    private func tab(_ text: String, processes: [String] = ["login", "-zsh", "claude"], history: Bool = true) -> TerminalTabSnapshot {
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys090", customTitle: "", processes: processes, busy: false, selected: true, text: text)
        tab.history = history
        return tab
    }

    func testSessionReadsThePromptFromItsScreenAndLosesItWhenAnswered() {
        let model = AppModel(receivesSignals: false)
        let session = TerminalSession(tab: tab("⏺ Hola"), backend: .bundled, bridge: model.terminalBridge)
        XCTAssertNil(session.prompt)
        session.update(tab(lines(permission)))
        XCTAssertEqual(session.prompt?.question, "Do you want to proceed?")
        session.update(tab(lines(permission + ["", "⏺ Listo."])))
        XCTAssertNil(session.prompt)
        // A collapsed island reads only the visible screen, and still notices.
        session.update(tab(lines(permission), history: false))
        XCTAssertEqual(session.prompt?.options.count, 3)
        // Claude's box and status are already out of the text the parser reads.
        let withBox = lines(permission) + "\n" + rule + "\n❯ \n" + rule
        session.update(tab("⏺ Otra cosa"))
        session.update(tab(withBox))
        XCTAssertNotNil(session.prompt)
    }

    func testAShellTabNeverHasAPrompt() {
        let model = AppModel(receivesSignals: false)
        let session = TerminalSession(tab: tab(lines(permission), processes: ["login", "-zsh"]), backend: .bundled, bridge: model.terminalBridge)
        XCTAssertNil(session.prompt)
    }

    // MARK: - Answering

    /// A model whose Terminal transport is a recorder, with one Claude tab showing the permission prompt (or `screen`).
    private func recordingModel(keysAllowed: Bool = true, screen: [String]? = nil) -> (AppModel, TerminalSession, () -> [String], () -> [TerminalKey]) {
        let model = AppModel(receivesSignals: false)
        let lock = NSLock()
        var scripts: [String] = []
        var keys: [TerminalKey] = []
        model.terminalBridge.directKeysAllowed = { keysAllowed }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { script in lock.lock(); scripts.append(script); lock.unlock() }
        model.terminalBridge.postKey = { key, _ in lock.lock(); keys.append(key); lock.unlock() }
        let session = TerminalSession(tab: tab(lines(screen ?? permission)), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        return (model, session, { lock.lock(); defer { lock.unlock() }; return scripts }, { lock.lock(); defer { lock.unlock() }; return keys })
    }

    func testAnsweringWritesTheArrowsAndEnterInOneScript() throws {
        let (model, session, scripts, keys) = recordingModel()
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "answered")
        var delivery: KeyDelivery?
        model.answer(prompt, option: 2, on: session) { delivery = $0; done.fulfill() }
        XCTAssertTrue(session.answering)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(delivery, .sent)
        XCTAssertEqual(keys(), [], "No key events: the arrows travel as their bytes, Enter as Terminal's own Return.")
        XCTAssertEqual(scripts().count, 1)
        XCTAssertTrue(scripts()[0].contains(#"do script ((character id 27) & "[B" & (character id 27) & "[B") in t"#), scripts()[0])
        XCTAssertFalse(scripts()[0].contains("frontmost") || scripts()[0].contains("activate"), "Terminal is never brought forward.")
        XCTAssertTrue(session.answering, "The card stays quiet until the screen shows the result.")
        // A second click while the first answer is on its way is refused.
        let refused = expectation(description: "refused")
        model.answer(prompt, option: 0, on: session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(scripts().count, 1)
        // The dialog closing is the result.
        session.update(tab(lines(permission + ["", "⏺ Listo."])))
        XCTAssertFalse(session.answering)
    }

    func testTheScreenChangingMidwayDoesNotReopenTheCardBeforeTheKeysAreDone() throws {
        let (model, session, _, _) = recordingModel()
        let gate = DispatchSemaphore(value: 0)
        model.terminalBridge.runScript = { _ in gate.wait() }
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "answered")
        model.answer(prompt, option: 2, on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        // The first arrow already moved the highlight on screen while the script that writes the answer has not returned yet.
        let moved = lines(permission).replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and")
        session.update(tab(moved))
        XCTAssertTrue(session.answering, "A second click now would compute its keys from a highlight that is still moving.")
        gate.signal()
        wait(for: [done], timeout: 3)
        XCTAssertFalse(session.answering, "Once the keys are done and the screen differs, the result is already on screen.")
    }

    func testAFieldChosenOnACardThatWentAwayTakesNoMessage() throws {
        // The text field chosen on the card waits for the composer's message; Claude moves on (the user answered at the
        // terminal) before it comes: the message is a message again, for Claude's box.
        let (model, session, scripts, keys) = recordingModel(screen: question)
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "chosen")
        model.answer(prompt, option: 2, on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(model.fieldAnswer(for: session)?.option, 2)
        session.update(tab(lines(question + ["", "⏺ Listo."])))
        XCTAssertNil(model.fieldAnswer(for: session))
        XCTAssertFalse(model.sendToField("Usa MongoDB", on: session) { _ in XCTFail("Not a field answer") })
        XCTAssertEqual(keys(), [])
        XCTAssertEqual(scripts().count, 0)
        XCTAssertFalse(session.answering)
    }

    func testAnsweringTheHighlightedOptionNeedsNoAccessibility() throws {
        let (model, session, scripts, keys) = recordingModel(keysAllowed: false)
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "answered")
        model.answer(prompt, option: 0, on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(keys(), [])
        XCTAssertEqual(scripts().count, 1)
        XCTAssertTrue(scripts()[0].contains("do script \"\" in t"))
    }

    /// A text field chosen on the card presses nothing: its arrows go with the answer's text (`AppModel.answer(_:option:text:on:)`).
    /// Arrows alone used to be key events that brought Terminal forward (Sample, 9/10).
    func testATextFieldOptionPressesNothingUntilItsAnswer() throws {
        let model = AppModel(receivesSignals: false)
        var keys: [TerminalKey] = []
        model.terminalBridge.directKeysAllowed = { true }
        model.terminalBridge.terminalProcess = { 4242 }
        var scripts: [String] = []
        model.terminalBridge.runScript = { scripts.append($0) }
        model.terminalBridge.postKey = { key, _ in keys.append(key) }
        let session = TerminalSession(tab: tab(lines(question)), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "answered")
        model.answer(prompt, option: 2, on: session) { XCTAssertEqual($0, .sent); done.fulfill() }
        wait(for: [done], timeout: 3)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(keys, [], "No arrow posted.")
        XCTAssertEqual(scripts, [], "No write either: no Enter on an empty field, which would cancel the question.")
        XCTAssertEqual(session.chosenField?.option, 2)
    }

    func testAFailureStopsTheSequence() throws {
        let (model, session, scripts, keys) = recordingModel()
        model.terminalBridge.runScript = { _ in throw TerminalBridgeError.failed("La pestaña original ya se cerró.") }
        let prompt = try XCTUnwrap(session.prompt)
        let done = expectation(description: "failed")
        model.answer(prompt, option: 2, on: session) { XCTAssertEqual($0, .failed); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(keys(), [])
        XCTAssertEqual(scripts().count, 0)
        XCTAssertFalse(session.answering, "A failed answer can be tried again.")
        XCTAssertEqual(model.notice, "La pestaña original ya se cerró.")
    }

    func testNothingIsSentWhenTheScreenNoLongerShowsThatPrompt() throws {
        let (model, session, scripts, keys) = recordingModel()
        let prompt = try XCTUnwrap(session.prompt)
        session.update(tab(lines(permission + ["", "⏺ Listo."])))
        let refused = expectation(description: "refused")
        model.answer(prompt, option: 2, on: session) { XCTAssertEqual($0, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(scripts().count + keys().count, 0, "A stale click never reaches the terminal.")
        // And the keys are computed from the screen as it is now, not from the card that was clicked.
        let moved = lines(permission).replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and")
        session.update(tab(moved))
        XCTAssertEqual(session.prompt?.keys(choosing: 2), [.down, .enter])
    }

    func testCancelSendsEscapeOnce() throws {
        let (model, session, scripts, keys) = recordingModel()
        model.cancelPrompt(on: session)
        model.cancelPrompt(on: session)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(keys(), [.escape], "A double click must not send Escape twice: the second one would open Claude's rewind.")
        XCTAssertEqual(scripts().count, 1)
    }

    // MARK: - The island

    func testAPromptHoldsTheIslandUntilItIsAnsweredOrPutAway() throws {
        let model = AppModel(receivesSignals: false)
        let session = TerminalSession(tab: tab("⏺ Hola"), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertFalse(model.promptHoldsIsland)
        session.update(tab(lines(permission)))
        XCTAssertTrue(model.promptHoldsIsland)
        model.dismissPrompt()
        XCTAssertFalse(model.promptHoldsIsland, "Collapsing by hand lets go of that prompt.")
        // The same prompt stays dismissed while the screen flickers; a different one holds again.
        model.updatePrompt()
        XCTAssertFalse(model.promptHoldsIsland)
        session.update(tab(lines(permission).replacingOccurrences(of: "rm -rf build", with: "rm -rf dist")))
        XCTAssertTrue(model.promptHoldsIsland)
        session.update(tab("⏺ Listo."))
        XCTAssertFalse(model.promptHoldsIsland)
    }

    func testAMenuTheUserOpenedHoldsNothing() throws {
        let model = AppModel(receivesSignals: false)
        let selector = lines(["⏺ Listo.", "", " Select model", "", " ❯ Opus", "   Sonnet", "", " Enter to confirm · Esc to exit"])
        let session = TerminalSession(tab: tab(selector), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertEqual(session.prompt?.kind, .selector, "It still gets its card when the island is open.")
        XCTAssertFalse(model.promptHoldsIsland, "A slash command's menu does not open or hold the island: the user is already at the terminal.")
    }

    func testAPromptIsForgottenOnlyAfterItStaysAway() throws {
        let model = AppModel(receivesSignals: false)
        let session = TerminalSession(tab: tab(lines(permission)), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        let start = Date()
        model.updatePrompt(now: start)
        model.dismissPrompt()
        session.update(tab("⏺ Redibujando…"))
        model.updatePrompt(now: start.addingTimeInterval(1))
        session.update(tab(lines(permission)))
        XCTAssertFalse(model.promptHoldsIsland, "A one-second flicker is the same prompt, still put away.")
        session.update(tab("⏺ Redibujando…"))
        model.updatePrompt(now: start.addingTimeInterval(2))
        model.updatePrompt(now: start.addingTimeInterval(6))
        session.update(tab(lines(permission)))
        XCTAssertTrue(model.promptHoldsIsland, "After a lasting absence the same text is a new prompt.")
    }
}
