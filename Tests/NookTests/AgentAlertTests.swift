import XCTest
@testable import Nook

final class AgentAlertTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)
    private let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "", " Do you want to proceed?", " ❯ 1. Yes",
                              "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"]

    func testATurnEndsWhenTheSpinnerStaysAway() {
        var watch = TurnWatch()
        let start = Date()
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start), "Never seen working: nothing ended.")
        XCTAssertFalse(watch.observe(working: true, asking: false, now: start))
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start.addingTimeInterval(1)), "One reading without it is a redraw.")
        XCTAssertFalse(watch.observe(working: true, asking: false, now: start.addingTimeInterval(2)), "It came back.")
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start.addingTimeInterval(3)))
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start.addingTimeInterval(4)), "Two readings, but not long enough.")
        XCTAssertTrue(watch.observe(working: false, asking: false, now: start.addingTimeInterval(5.5)))
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start.addingTimeInterval(8)), "Told once.")

        XCTAssertFalse(watch.observe(working: true, asking: false, now: start.addingTimeInterval(10)))
        XCTAssertFalse(watch.observe(working: false, asking: true, now: start.addingTimeInterval(12)))
        XCTAssertFalse(watch.observe(working: false, asking: false, now: start.addingTimeInterval(20)), "A question took the spinner's place: not an end.")
    }

    private func tab(_ text: String, tty: String = "/dev/ttys080", window: Int = 3, selected: Bool = true) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: window, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["claude"], busy: true, selected: selected, text: text, history: false)
    }
    private func screen(_ body: String) -> String { body + "\n" + rule + "\n❯ \n" + rule }

    func testTheScreenAlertsWhenClaudeFinishesOrAsks() {
        let session = TerminalSession(tab: tab(screen("⏺ hola")), backend: .bundled, bridge: TerminalAppBridge())
        var alerts: [(NookAlert.Kind, String)] = []
        session.onAlert = { alerts.append(($0, $1)) }
        var completed = 0
        session.onCompletion = { completed += 1 }
        let start = Date()
        session.update(tab(screen("⏺ revisando\n✶ Churning… (3s)")))
        session.watchTurn(status: ClaudeStatus(glyph: "✶", text: "Churning…", working: true), conversation: "", now: start)
        session.watchTurn(status: nil, conversation: "⏺ listo", now: start.addingTimeInterval(2))
        session.watchTurn(status: ClaudeStatus(glyph: "✻", text: "Churned for 4s", working: false), conversation: "⏺ listo", now: start.addingTimeInterval(4))
        XCTAssertEqual(alerts.map(\.0), [.finished])
        XCTAssertEqual(alerts.first?.1, "Claude terminó.")
        XCTAssertEqual(completed, 1, "Claude's closing line was on screen: a completion to celebrate.")

        session.update(tab(permission.joined(separator: "\n")))
        session.update(tab(permission.joined(separator: "\n")))
        XCTAssertEqual(alerts.map(\.0), [.finished, .question], "The same dialog is announced once.")
        XCTAssertEqual(alerts.last?.1, "Do you want to proceed?")

        alerts = []
        session.update(tab(screen("⏺ sigo\n✶ Churning… (1s)")))
        session.watchTurn(status: ClaudeStatus(glyph: "✶", text: "Churning…", working: true), conversation: "", now: start.addingTimeInterval(30))
        session.watchTurn(status: nil, conversation: "⎿  Interrupted · What should Claude do instead?", now: start.addingTimeInterval(32))
        session.watchTurn(status: nil, conversation: "⎿  Interrupted · What should Claude do instead?", now: start.addingTimeInterval(34))
        XCTAssertTrue(alerts.isEmpty, "A turn the user stopped rings nothing.")
        session.watchTurn(status: ClaudeStatus(glyph: "✶", text: "Churning…", working: true), conversation: "", now: start.addingTimeInterval(50))
        session.watchTurn(status: nil, conversation: "⏺ listo", now: start.addingTimeInterval(52))
        session.watchTurn(status: nil, conversation: "⏺ listo", now: start.addingTimeInterval(54))
        XCTAssertEqual(alerts.map(\.0), [.finished])
        XCTAssertEqual(completed, 1, "A spinner that just went away is not a trusted completion.")
    }

    func testTheModelAlertsOnceAndNotForTheTabInFront() {
        let model = AppModel(receivesSignals: false)
        model.terminalBridge.runScript = { _ in }
        model.frontTerminalWindow = { nil }   // Terminal is not the active app
        model.updateExternalTabs([tab(screen("⏺ hola")), tab(screen("⏺ otra"), tty: "/dev/ttys081")], ttys: ["/dev/ttys080", "/dev/ttys081"])
        let first = model.sessions.first { $0.externalTTY == "/dev/ttys080" }!
        let second = model.sessions.first { $0.externalTTY == "/dev/ttys081" }!
        model.select(first)

        let now = Date()
        model.raiseAlert(.finished, for: first, message: "Claude terminó.", now: now)
        XCTAssertEqual(model.alert?.kind, .finished)
        XCTAssertEqual(model.alert?.sessionID, first.id)
        XCTAssertEqual(first.unreadNotice, "Claude terminó.")
        XCTAssertEqual(model.unreadCount, 1)
        let id = model.alert?.id

        model.raiseAlert(.finished, for: first, message: "Claude terminó su respuesta.", now: now.addingTimeInterval(2))
        XCTAssertEqual(model.alert?.id, id, "A hook and the screen telling the same thing ring once.")
        model.raiseAlert(.question, for: first, message: "Do you want to proceed?", now: now.addingTimeInterval(3))
        XCTAssertEqual(model.alert?.kind, .question)
        XCTAssertEqual(first.unreadNotice, "Do you want to proceed?")
        model.raiseAlert(.finished, for: first, message: "Claude terminó.", now: now.addingTimeInterval(20))
        XCTAssertEqual(first.unreadNotice, "Do you want to proceed?", "A plain finish never hides a question.")

        model.noteCompletion(for: first, now: now)
        model.noteCompletion(for: first, now: now.addingTimeInterval(4))
        XCTAssertEqual(model.completions, 1, "A hook and the screen telling the same finish celebrate once.")
        model.noteCompletion(for: second, now: now.addingTimeInterval(5))
        XCTAssertEqual(model.completions, 2)

        model.expanded = true
        XCTAssertNil(model.alert, "Opening the island takes the alert; the notice stays until the tab is looked at.")
        model.raiseAlert(.question, for: first, message: "otra pregunta", now: now.addingTimeInterval(40))
        XCTAssertNil(model.alert, "The tab open in front of the user needs no alert.")
        model.raiseAlert(.failed, for: second, message: "Claude terminó con un error.", now: now.addingTimeInterval(41))
        XCTAssertEqual(model.alert?.sessionID, second.id, "Another tab still alerts.")
        model.expanded = false
    }

    func testHooksGoIntoEveryClaudeFolderAndKeepTheRest() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-hooks-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        for folder in [".claude", ".claude-work/projects", ".claude-empty", ".codex"] {
            try manager.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let mine = ["model": "opus", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "say listo"]]]]]] as [String: Any]
        try JSONSerialization.data(withJSONObject: mine).write(to: home.appendingPathComponent(".claude/settings.json"))
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude.json"))

        let folders = ClaudeHooks.folders(home: home)
        XCTAssertEqual(folders.map(\.lastPathComponent), [".claude", ".claude-work"], "Only folders with settings or records; files and other tools are left alone.")
        XCTAssertEqual(ClaudeHooks.describe(folders), "~/.claude/settings.json y ~/.claude-work/settings.json")

        let command = "'/tmp/nook-hook' --claude-hook"
        try ClaudeHooks.write(enabled: true, to: folders, command: command)
        XCTAssertTrue(folders.allSatisfy { ClaudeHooks.isEnabled(in: $0, command: command) })
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))) as! [String: Any]
        XCTAssertEqual(first["model"] as? String, "opus")
        let stop = (first["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "The user's own Stop hook stays.")
        let backups = try manager.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path).filter { $0.hasPrefix("settings.nook-backup-") }
        XCTAssertEqual(backups.count, 1, "The changed file was backed up first.")
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: home.appendingPathComponent(".claude-work").path).allSatisfy { !$0.hasPrefix("settings.nook-backup-") },
                      "A folder without settings had nothing to back up.")

        try ClaudeHooks.write(enabled: false, to: folders, command: command)
        XCTAssertFalse(folders.contains { ClaudeHooks.isEnabled(in: $0, command: command) })
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))) as! [String: Any]
        XCTAssertEqual(((restored["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 1)

        try Data("no es json".utf8).write(to: home.appendingPathComponent(".claude-work/settings.json"))
        XCTAssertThrowsError(try ClaudeHooks.write(enabled: true, to: folders, command: command))
        XCTAssertFalse(ClaudeHooks.isEnabled(in: folders[0], command: command), "One unreadable file means no folder is touched.")
    }

    func testNothingIsReadWhileNobodyCanSeeTheScreen() {
        XCTAssertEqual(TerminalAppBridge.interval(detailed: true), 0.5)
        XCTAssertEqual(TerminalAppBridge.interval(detailed: false), 2)
        let model = AppModel(receivesSignals: false)
        let bridge = model.terminalBridge   // no tabs followed: a reading would do nothing
        bridge.startMonitoring()
        XCTAssertTrue(bridge.isMonitoring)
        model.rest("pantallas", true)
        model.rest("bloqueo", true)
        XCTAssertFalse(bridge.isMonitoring, "Asleep screens: no reading at all.")
        model.rest("pantallas", false)
        XCTAssertFalse(bridge.isMonitoring, "Still locked.")
        model.rest("bloqueo", false)
        XCTAssertTrue(bridge.isMonitoring, "Back: reading again, starting at once.")
        bridge.resting = true
        bridge.startMonitoring()
        XCTAssertFalse(bridge.isMonitoring, "A tab connected during the rest waits for its end.")
        bridge.resting = false
        XCTAssertTrue(bridge.isMonitoring)
        bridge.disconnect(tty: "/dev/none")
        XCTAssertFalse(bridge.isMonitoring)
    }

    func testANoticeGoesOnceItsTabIsInFrontAndOnlyThen() {
        let model = AppModel(receivesSignals: false)
        model.terminalBridge.runScript = { _ in }
        var front: Int? = nil
        model.frontTerminalWindow = { front }
        let tabs = { [self] in [tab(screen("⏺ a")), tab(screen("⏺ b"), tty: "/dev/ttys081", window: 4, selected: true), tab(screen("⏺ c"), tty: "/dev/ttys082", window: 4, selected: false)] }
        model.updateExternalTabs(tabs(), ttys: ["/dev/ttys080", "/dev/ttys081", "/dev/ttys082"])
        let first = model.sessions.first { $0.externalTTY == "/dev/ttys080" }!
        let second = model.sessions.first { $0.externalTTY == "/dev/ttys081" }!
        let third = model.sessions.first { $0.externalTTY == "/dev/ttys082" }!
        model.select(first)
        model.raiseAlert(.finished, for: first, message: "Claude terminó.")
        model.raiseAlert(.question, for: second, message: "¿Sigo?")
        model.raiseAlert(.finished, for: third, message: "Claude terminó.")
        XCTAssertEqual(model.unreadCount, 3)

        model.expanded = true
        XCTAssertNil(first.unreadNotice, "Opening the island shows the selected tab: its bell goes.")
        XCTAssertEqual(model.unreadCount, 2, "The other tabs keep theirs.")
        model.expanded = false

        front = 4   // the user brings Terminal forward on the window showing the second tab
        model.updateExternalTabs(tabs(), ttys: ["/dev/ttys080", "/dev/ttys081", "/dev/ttys082"])
        XCTAssertNil(second.unreadNotice, "Seen in Terminal itself.")
        XCTAssertNotNil(third.unreadNotice, "Same window, but not the tab it shows.")
        XCTAssertEqual(model.unreadCount, 1)

        let before = model.alert?.id
        model.raiseAlert(.finished, for: second, message: "Claude terminó.")
        XCTAssertNil(second.unreadNotice, "No alert for the tab the user is looking at in Terminal.")
        XCTAssertEqual(model.alert?.id, before)
    }
}
