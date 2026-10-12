import XCTest
@testable import Nook

/// The model button: what Claude's own /model picker offers (Claude Code's list on disk, else the picker rows Nook saw, else the
/// aliases), the current model, and switching as the default or for this session only.
final class ClaudeModelTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }
    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-models-" + UUID().uuidString)! }

    /// A home of its own, so Sample's real config folders never reach a test. `catalog` writes Claude Code's list into
    /// `.claude-work/cache/model-catalog`.
    private func home(catalog: [[String: Any]]? = nil, selected: String = "claude-opus-5-5", fetched: Double = 1_791_316_587_773, staleAt: Double = 4_102_444_800_000) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-models-" + UUID().uuidString)
        if let catalog {
            let folder = url.appendingPathComponent(".claude-work/cache/model-catalog")
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file: [String: Any] = ["version": 2, "fetchedAt": fetched, "staleAt": staleAt,
                                       "catalog": ["surface": "cc", "config": ["id": "x", "models": catalog, "settings_vocabulary": [:]],
                                                   "state": ["id": "x", "model": selected, "selection_source": "user_setting"]]]
            try! JSONSerialization.data(withJSONObject: file).write(to: folder.appendingPathComponent("account-cc.json"))
        }
        return url
    }

    /// The model fields of Claude Code's list as Sample's `~/.claude-work` cached it on 2026-10-06 (only those; the file holds
    /// nothing else Nook reads).
    private let sampleList: [[String: Any]] = [
        ["id": "claude-opus-5-5", "name": "Opus 5.5", "short_name": "Opus", "description": "For complex work and everyday tasks", "section": "main", "min_claude_code_version": "2.1.280"],
        ["id": "claude-fable-5-1", "name": "Fable 5.1", "short_name": "Fable", "description": "For your toughest challenges", "section": "main", "min_claude_code_version": "2.1.251"],
        ["id": "claude-sonnet-5-5", "name": "Sonnet 5.5", "short_name": "Sonnet", "description": "Most efficient for simpler tasks", "section": "main"],
        ["id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "short_name": "Haiku", "description": "Fastest for quick answers", "section": "main"],
        ["id": "claude-sonnet-5", "name": "Sonnet 5", "short_name": "Sonnet", "section": "overflow"],
        ["id": "claude-opus-5", "name": "Opus 5", "short_name": "Opus", "section": "overflow"],
        ["id": "claude-fable-5", "name": "Fable 5", "short_name": "Fable", "section": "overflow"],
        ["id": "claude-opus-4-8", "name": "Opus 4.8", "short_name": "Opus", "section": "overflow"],
        ["id": "claude-opus-4-7", "name": "Opus 4.7", "short_name": "Opus", "section": "overflow"],
        ["id": "claude-opus-4-6", "name": "Opus 4.6", "short_name": "Opus", "section": "overflow"],
        ["id": "claude-sonnet-4-6", "name": "Sonnet 4.6", "short_name": "Sonnet", "section": "overflow"],
    ]

    /// Sample's picker (Claude Code 2.1.290, screenshot of 2026-10-06): nine rows of twelve in view.
    private var realPicker: [String] {
        ["⏺ Listo.", "", rule, " Select model",
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

    /// An older picker shape (what `ClaudeDialogTests` reads): Nook's fallback when no list is on disk.
    private var oldPicker: [String] {
        ["⏺ Listo.", "", rule, " Select model", " Switch between Claude models. Applies to this session and future Claude",
         " Code sessions. For other/previous model names, specify with --model.", "",
         " ❯ 1. Default (recommended) ✔  Opus 5.5 · Most capable for complex work",
         "   2. Sonnet                   Sonnet 5.5 · Best for everyday tasks",
         "   3. Haiku                    Haiku 4.5 · Fastest for quick answers",
         "   4. Opus (1M context)        Opus 5.5 with 1M context · For long sessions", "",
         " ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]
    }
    private var oldPrompt: AgentPrompt { AgentPrompt.parse(lines(oldPicker))! }

    // MARK: Claude Code's list on disk

    func testClaudeCodesOwnListGivesEveryRowOfThePickerInOrder() throws {
        let store = ClaudeModelStore(defaults: suite(), home: home(catalog: sampleList))
        let file = try XCTUnwrap(store.cached(folder: ".claude-work"))
        XCTAssertEqual(file.models.count, 11)
        XCTAssertEqual(file.selected, "claude-opus-5-5")
        let choices = store.choices(folder: ".claude-work", version: "2.1.290", current: nil)
        XCTAssertEqual(choices.map(\.label), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5", "Sonnet 5", "Opus 5", "Fable 5",
                                              "Opus 4.8", "Opus 4.7", "Opus 4.6", "Sonnet 4.6"], "The twelve rows of Sample's picker, the three below its view too.")
        XCTAssertEqual(choices.map(\.row), Array(1...12))
        XCTAssertEqual(choices.first?.argument, "default")
        XCTAssertEqual(choices[2].argument, "claude-fable-5-1", "/model takes the id Claude Code itself uses.")
        XCTAssertEqual(choices.filter(\.isCurrent).map(\.label), ["Opus 5.5"], "Without a banner, Claude Code's saved choice.")
        XCTAssertEqual(store.choices(folder: ".claude-work", version: "2.1.290", current: "Sonnet 5.5").filter(\.isCurrent).map(\.label), ["Sonnet 5.5"],
                       "The banner's model (a choice for this session only) wins over the saved one.")
        XCTAssertFalse(choices.contains(where: \.isAlias), "Exactly what the picker offers: no extra aliases.")
        XCTAssertEqual(store.missingRows(folder: ".claude-work"), 0)
        XCTAssertEqual(store.cached(folder: nil)?.models.count, 11, "A tab whose folder is unknown takes the newest list.")
    }

    func testModelsTheTabsVersionCantRunAreLeftOutAsThePickerDoes() {
        let store = ClaudeModelStore(defaults: suite(), home: home(catalog: sampleList))
        let older = store.choices(folder: ".claude-work", version: "2.1.250", current: nil).map(\.label)
        XCTAssertFalse(older.contains("Opus 5.5"), "Needs 2.1.280.")
        XCTAssertFalse(older.contains("Fable 5.1"), "Needs 2.1.251.")
        XCTAssertTrue(older.contains("Sonnet 5.5"))
        XCTAssertTrue(ClaudeModelCacheFile.version("2.1.290", isAtLeast: "2.1.280"))
        XCTAssertFalse(ClaudeModelCacheFile.version("2.1.29", isAtLeast: "2.1.280"))
    }

    func testThePickersOwnWordsFillWhatTheListLacks() throws {
        let real = AgentPrompt.parse(lines(realPicker))
        try XCTSkipIf(real == nil, "Waiting on the parser for this picker shape (AgentPrompt).")
        let store = ClaudeModelStore(defaults: suite(), home: home(catalog: sampleList))
        store.learn(real!, version: "2.1.290", folder: ".claude-work")
        let choices = store.choices(folder: ".claude-work", version: "2.1.290", current: "Opus 5.5")
        XCTAssertEqual(choices[0].detail, "Sonnet 5.5 · Efficient for routine tasks", "Default's row as the picker words it.")
        XCTAssertEqual(choices[5].detail, "Efficient for routine tasks", "Sonnet 5 has no description in the list; the picker's fills in.")
        XCTAssertEqual(choices[1].detail, "For complex work and everyday tasks")
        XCTAssertNil(choices[10].detail, "Opus 4.6 was never in view.")
    }

    func testAStaleListIsFlagged() {
        let fresh = ClaudeModelStore(defaults: suite(), home: home(catalog: sampleList))
        XCTAssertFalse(fresh.isStale(folder: ".claude-work", version: "2.1.290"))
        let old = ClaudeModelStore(defaults: suite(), home: home(catalog: sampleList, staleAt: 1_790_119_135_724))
        XCTAssertTrue(old.isStale(folder: ".claude-work", version: "2.1.290"), "Past the time Claude would fetch it again.")
    }

    func testOnlyTheModelFieldsAreDecoded() {
        let data = Data(#"{"version":2,"fetchedAt":1,"catalog":{"surface":"cc","config":{"models":[{"id":"claude-x","name":"X 1","extra":{"anything":true}}]},"state":{"model":"claude-x","thinking":{"type":"effort"}}},"other":"ignored"}"#.utf8)
        XCTAssertEqual(ClaudeModelCacheFile.parse(data)?.models.map(\.name), ["X 1"])
        XCTAssertNil(ClaudeModelCacheFile.parse(Data(#"{"catalog":{"surface":"chat","config":{"models":[{"id":"a","name":"A"}]}}}"#.utf8)), "Another surface's list is not Claude Code's.")
        XCTAssertNil(ClaudeModelCacheFile.parse(Data("not json".utf8)))
    }

    // MARK: Without the list: the picker rows Nook saw, then the aliases

    func testWithNothingKnownTheAliasesStand() {
        let store = ClaudeModelStore(defaults: suite(), home: home())
        let choices = store.choices(folder: nil, current: "Sonnet 5.5")
        XCTAssertEqual(choices.map(\.argument), ["default", "opus", "sonnet", "haiku"])
        XCTAssertTrue(choices.allSatisfy(\.isAlias))
        XCTAssertEqual(choices.filter(\.isCurrent).map(\.argument), ["sonnet"], "A family name points at its alias.")
        XCTAssertFalse(store.isStale(folder: nil, version: "2.1.290"), "Aliases never go stale.")
        XCTAssertNil(store.missingRows(folder: nil))
    }

    func testPickerRowsAreKeptAcrossLaunchesAndMergedWithTheAliases() {
        let defaults = suite(), empty = home()
        ClaudeModelStore(defaults: defaults, home: empty).learn(oldPrompt, version: "2.1.290", folder: ".claude-work")
        let store = ClaudeModelStore(defaults: defaults, home: empty)
        let choices = store.choices(folder: ".claude-work", current: "Sonnet 5.5")
        XCTAssertEqual(choices.map(\.label), ["Default (recommended)", "Sonnet", "Haiku", "Opus (1M context)", "Opus"])
        XCTAssertEqual(choices.map(\.argument), ["default", "sonnet", "haiku", nil, "opus"])
        XCTAssertEqual(choices.map(\.row), [1, 2, 3, 4, nil])
        XCTAssertEqual(choices.filter(\.isCurrent).map(\.label), ["Sonnet"])
        XCTAssertTrue(store.isStale(folder: ".claude-work", version: "2.1.291"), "Another version may list other models.")
    }

    func testRowsAddUpAcrossViewsOfAScrollingPicker() throws {
        let real = AgentPrompt.parse(lines(realPicker))
        try XCTSkipIf(real == nil, "Waiting on the parser for this picker shape (AgentPrompt).")
        let store = ClaudeModelStore(defaults: suite(), home: home())
        store.learn(real!, version: "2.1.290", folder: ".claude-work")
        XCTAssertEqual(store.catalog(folder: ".claude-work")?.total, 12, "Nine in view and \"… +3 models\".")
        XCTAssertEqual(store.missingRows(folder: ".claude-work"), 3)
        // Scrolled to the end: rows 4 to 12.
        let tail = Array(realPicker[0..<7]) + [
            " ↑  4.  Sonnet 5.5             Most efficient for simpler tasks",
            "    5.  Haiku 4.5              Fastest for quick answers",
            "    6.  Sonnet 5               Efficient for routine tasks",
            "    7.  Opus 5                 Best for everyday, complex tasks",
            "    8.  Fable 5                Most capable for your hardest and longest-running tasks",
            "    9.  Opus 4.8               Best for everyday, complex tasks",
            "    10. Opus 4.7               Best for everyday, complex tasks",
            "    11. Opus 4.6               Best for everyday, complex tasks",
            " ❯  12. Sonnet 4.6             Efficient for routine tasks", "",
            " ● xHigh effort ←/→ to adjust", "",
            " Enter to set as default · s to use this session only · Esc to cancel"]
        let seen = try XCTUnwrap(AgentPrompt.parse(lines(tail)))
        store.learn(seen, version: "2.1.290", folder: ".claude-work")
        XCTAssertEqual(store.catalog(folder: ".claude-work")?.entries.map(\.label).count, 12)
        XCTAssertEqual(store.catalog(folder: ".claude-work")?.entries.last?.label, "Sonnet 4.6")
        XCTAssertEqual(store.missingRows(folder: ".claude-work"), 0)
    }

    func testOnlyTheDocumentedAliasesGoAsArgumentsWithoutTheList() {
        XCTAssertEqual(ClaudeModelStore.argument(forLabel: "Default (recommended)"), "default")
        XCTAssertEqual(ClaudeModelStore.argument(forLabel: "Sonnet"), "sonnet")
        XCTAssertNil(ClaudeModelStore.argument(forLabel: "Opus (1M context)"), "Not certain: chosen in the picker.")
        XCTAssertNil(ClaudeModelStore.argument(forLabel: "Fable 5.1"))
    }

    /// Claude's answers to /model as Sample's records hold them (`<local-command-stdout>`, Claude Code 2.1.223–2.1.291), and the
    /// one for this session only, worded like /effort's ("(this session only)"); none is in the records yet.
    func testTheAnswersNameTheModel() {
        let answers = [
            ("Set model to `Opus 5.5` and saved as your default for new sessions", "Opus 5.5", nil),
            ("Set model to `Opus 5 (1M context)` and saved as your default for new sessions with `max` effort", "Opus 5 (1M context)", "max"),
            ("Set model to \u{1b}[1mSonnet 5\u{1b}[22m and saved as your default for new sessions", "Sonnet 5", nil),
            ("Kept model as `Opus 5.5 (1M context)`", "Opus 5.5 (1M context)", nil),
            ("Set model to Sonnet 4.6", "Sonnet 4.6", nil),
            ("Set model to `Fable 5.1` (this session only)", "Fable 5.1", nil),
            ("Set model to Fable 5.1 for this session only", "Fable 5.1", nil),
        ]
        for (answer, model, effort) in answers {
            let change = ClaudeBanner.modelChange(in: "  ⎿  " + answer)
            XCTAssertEqual(change?.model, model, answer)
            XCTAssertEqual(change?.effort, effort, answer)
            XCTAssertTrue(ClaudeSettingsEcho.isConfirmation(answer), "Hidden from the chat: \(answer)")
        }
    }

    // MARK: Switching

    func testTheKeysThatReachARowAndApplyIt() throws {
        let real = AgentPrompt.parse(lines(realPicker))
        try XCTSkipIf(real == nil, "Waiting on the parser for this picker shape (AgentPrompt).")
        let picker = real!
        XCTAssertEqual(picker.options[picker.highlighted].title, "Opus 5.5")
        let sonnet46 = ClaudeModelChoice(label: "Sonnet 4.6", argument: "claude-sonnet-4-6", row: 12)
        XCTAssertEqual(AppModel.pickerKeys(for: sonnet46, in: picker, scope: .sessionOnly), Array(repeating: .down, count: 10) + [.keyS],
                       "Below the view: reached by moving on; \"s\" for this session only.")
        let defaultRow = ClaudeModelChoice(label: "Default (recommended)", argument: "default", row: 1)
        XCTAssertEqual(AppModel.pickerKeys(for: defaultRow, in: picker, scope: .default), [.up, .enter])
        XCTAssertEqual(AppModel.pickerKeys(for: ClaudeModelChoice(label: "Opus 5.5", row: 2), in: picker, scope: .sessionOnly), [.keyS])
        XCTAssertNil(AppModel.pickerKeys(for: ClaudeModelChoice(label: "Algo"), in: picker, scope: .default), "No row, no keys.")
    }

    func testTheSessionKeyIsItsOwnAndNoRowShowsIt() {
        XCTAssertEqual(TerminalKey.keyS.tmuxName, "s")
        XCTAssertEqual(TerminalKey.keyS.keyCode, 1, "kVK_ANSI_S")
        XCTAssertEqual(TerminalKey.keyS.modifiers, [])
        XCTAssertTrue(TerminalKey.keyS.needsDirectKeys, "do script would add a Return after it.")
        XCTAssertFalse(TerminalKey.menuKeys.contains(.keyS))
        XCTAssertFalse(TerminalKey.panelKeys.contains(.keyS))
    }

    /// A model with one Claude tab whose transports only record: commands and keys never reach Terminal.
    private func rig(screen: [String], version: String = "2.1.290", catalog: [[String: Any]]? = nil) -> (AppModel, TerminalSession, () -> [String], () -> [TerminalKey]) {
        let model = AppModel(receivesSignals: false, defaults: suite())
        model.models = ClaudeModelStore(defaults: suite(), home: home(catalog: catalog))
        let lock = NSLock()
        var keys: [TerminalKey] = []
        var commands: [String] = []
        model.terminalBridge.directKeysAllowed = { true }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.postKey = { key, _ in lock.lock(); keys.append(key); lock.unlock() }
        model.commandSender = { text, _ in commands.append(text) }
        let session = TerminalSession(tab: tab(screen, version: version), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        session.onModelPicker = { [weak model, weak session] picker in if let session { model?.modelPickerShown(picker, on: session) } }
        return (model, session, { commands }, { lock.lock(); defer { lock.unlock() }; return keys })
    }

    private func tab(_ screen: [String], version: String = "2.1.290") -> TerminalTabSnapshot {
        let banner = ["▗ ▗   ▖ ▖  Claude Code v" + version, "           Opus 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
        return TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys095", customTitle: "", processes: ["login", "-zsh", "claude"],
                                   busy: false, selected: true, text: lines(banner + screen))
    }

    private func waitForKeys(_ keys: @escaping () -> [TerminalKey], count: Int) {
        let done = expectation(description: "keys")
        DispatchQueue.global().async { while keys().count < count { usleep(5_000) }; done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testAsTheDefaultAModelGoesAsAPlainCommandWithItsId() {
        let (model, session, commands, keys) = rig(screen: [rule, "❯ ", rule], catalog: sampleList)
        let fable = model.availableModels(for: session)[2]
        XCTAssertEqual(fable.label, "Fable 5.1")
        model.setModel(fable, on: session)
        XCTAssertEqual(commands(), ["/model claude-fable-5-1"])
        XCTAssertTrue(keys().isEmpty, "No keys, no Accessibility.")
        session.update(tab(["> /model claude-fable-5-1", "  ⎿  Set model to Fable 5.1 and saved as your default for new sessions", rule, "❯ ", rule]))
        XCTAssertEqual(session.currentModel, "Fable 5.1")
        XCTAssertEqual(model.availableModels(for: session).filter(\.isCurrent).map(\.label), ["Fable 5.1"])
    }

    func testForThisSessionOnlyThePickerOpensAndGetsS() throws {
        try XCTSkipIf(AgentPrompt.parse(lines(realPicker)) == nil, "Waiting on the parser for this picker shape (AgentPrompt).")
        let (model, session, commands, keys) = rig(screen: [rule, "❯ ", rule], catalog: sampleList)
        let haiku = model.availableModels(for: session)[4]
        model.setModel(haiku, on: session, scope: .sessionOnly)
        XCTAssertEqual(commands(), ["/model"], "Only Claude's picker applies a model to this session only.")
        session.update(tab(realPicker))
        waitForKeys(keys, count: 4)
        XCTAssertEqual(keys(), [.down, .down, .down, .keyS], "From Opus 5.5 (row 2) to Haiku 4.5 (row 5), then \"s\".")
    }

    func testWithoutTheListARowOnlyThePickerKnowsIsChosenThere() {
        let (model, session, commands, keys) = rig(screen: [rule, "❯ ", rule])
        model.setModel(ClaudeModelChoice(label: "Opus (1M context)", row: 4), on: session)
        XCTAssertEqual(commands(), ["/model"], "Opens Claude's own picker.")
        session.update(tab(oldPicker))
        waitForKeys(keys, count: 3)
        XCTAssertEqual(keys(), [.down, .down, .down], "Three down from the ticked Default; Enter goes as Terminal's own Return.")
        XCTAssertEqual(model.models.catalog(folder: nil)?.entries.count, 4, "The picker that opened was learned on the way.")
    }

    func testOpeningThePickerTwiceSendsItOnce() {
        let (model, session, commands, _) = rig(screen: [rule, "❯ ", rule])
        model.openModelPicker(on: session)
        session.update(tab(oldPicker))
        model.openModelPicker(on: session)
        XCTAssertEqual(commands(), ["/model"])
    }

    func testTheButtonWaitsWhileClaudeWorksOrAsks() {
        let (model, session, commands, _) = rig(screen: ["✻ Churning… (3s · esc to interrupt)", rule, "❯ ", rule], catalog: sampleList)
        XCTAssertEqual(model.modelSwitchBlocked(on: session), "Claude está trabajando; podrás cambiar el modelo cuando termine.")
        model.setModel(ClaudeModelStore.aliases[2], on: session)
        XCTAssertTrue(commands().isEmpty, "A /model queued mid-turn would switch models in the middle of the work.")
        session.update(tab(["✻ Waiting for 2 background agents to finish", rule, "❯ ", rule]))
        XCTAssertNil(model.modelSwitchBlocked(on: session), "Claude's own turn is over while it waits for its agents.")
        session.update(tab([" Do you want to proceed?", " ❯ 1. Yes", "   2. No", "", " Esc to cancel"]))
        XCTAssertEqual(model.modelSwitchBlocked(on: session), "Claude espera una respuesta en la pestaña.")
        session.update(TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys095", customTitle: "", processes: ["login", "-zsh"],
                                           busy: false, selected: true, text: "developer@MacBook-Pro-Example app % "))
        XCTAssertNotNil(model.modelSwitchBlocked(on: session))
    }
}
