import XCTest
@testable import Nook

final class SlashCommandTests: XCTestCase {
    private func command(_ name: String, uses: Int = 0) -> SlashCommand { SlashCommand(name: name, uses: uses) }

    func testOnlyACommandBeingTypedIsCompleted() {
        XCTAssertEqual(SlashCatalog.query(in: "/"), "")
        XCTAssertEqual(SlashCatalog.query(in: "/us"), "us")
        XCTAssertEqual(SlashCatalog.query(in: "/codex:res"), "codex:res")
        XCTAssertNil(SlashCatalog.query(in: "/compact keep the plan"), "Arguments started: the menu steps aside.")
        XCTAssertNil(SlashCatalog.query(in: "/Users/me/file.png"), "A path is not a command.")
        XCTAssertNil(SlashCatalog.query(in: "hola /usage"))
        XCTAssertNil(SlashCatalog.query(in: "/usage\n"))
    }

    func testMatchesPutWhatStartsWithTheTextFirstThenTheMostUsed() {
        let all = [command("usage", uses: 3), command("user-skill"), command("status", uses: 9), command("codex:rescue"),
                   command("resume", uses: 1), command("busy-tool")]
        XCTAssertEqual(SlashCatalog.matches(all, draft: "/us").map(\.name), ["usage", "user-skill"], "Like Claude: only from the start of the name or of a word in it.")
        XCTAssertEqual(SlashCatalog.matches(all, draft: "/res").map(\.name), ["resume", "codex:rescue"], "A part after ':' counts after full prefixes.")
        XCTAssertEqual(SlashCatalog.matches(all, draft: "/").map(\.name).prefix(3), ["status", "usage", "resume"])
        XCTAssertEqual(SlashCatalog.matches(all, draft: "/US").map(\.name).first, "usage")
        XCTAssertTrue(SlashCatalog.matches(all, draft: "/usage now").isEmpty)
        let documented = [SlashCommand(name: "add-dir"), SlashCommand(name: "clear", aliases: ["reset", "new"])]
        XCTAssertEqual(SlashCatalog.matches(documented, draft: "/adddir").map(\.name), ["add-dir"], "Separators are ignored.")
        XCTAssertEqual(SlashCatalog.matches(documented, draft: "/new").map(\.name), ["clear"], "An alias finds its command.")
        XCTAssertEqual(SlashCatalog.matches(documented, draft: "/dir").map(\.name), ["add-dir"])
        let resume = SlashCommand(name: "resume", uses: 26, aliases: ["continue"]), compact = SlashCommand(name: "compact", uses: 1)
        XCTAssertEqual(SlashCatalog.matches([resume, compact], draft: "/co").map(\.name), ["compact", "resume"], "The name counts before an alias.")
        let plan = SlashCommand(name: "plan", uses: 1), planner = SlashCommand(name: "plan-review", uses: 40)
        XCTAssertEqual(SlashCatalog.matches([planner, plan], draft: "/plan").first?.name, "plan", "A name typed in full comes first, whatever is used more.")
    }

    func testClaudesOfficialReferenceIsBundled() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/claude-commands.json")
        let reference = CommandReference.load(file)
        XCTAssertGreaterThan(reference.count, 100)
        let byName = Dictionary(uniqueKeysWithValues: reference.map { ($0.name, $0) })
        XCTAssertEqual(byName["usage"]?.detail, "Show session cost, plan usage limits, and activity stats")
        XCTAssertEqual(byName["clear"]?.aliases, ["reset", "new"])
        XCTAssertEqual(byName["model"]?.hint, "[model]")
        XCTAssertNil(byName["vim"], "Commands the reference lists as removed are left out.")
        XCTAssertTrue(reference.allSatisfy { ($0.detail ?? "").count <= 160 })

        let codex = Dictionary(uniqueKeysWithValues: CommandReference.load(file.deletingLastPathComponent().appendingPathComponent("codex-commands.json")).map { ($0.name, $0) })
        XCTAssertGreaterThan(codex.count, 30)
        XCTAssertEqual(codex["side"]?.aliases, ["btw"])
        XCTAssertEqual(codex["init"]?.detail, "Generate an AGENTS.md scaffold in the current directory")
        XCTAssertNil(codex["setup-default-sandbox"], "Windows-only commands are left out: Nook runs on macOS.")
    }

    func testClaudesSkillListingGivesNamesAndDescriptions() {
        let listing = """
        - codex:rescue: Delegate investigation to Codex.
        TRIGGER — continuation of the description above
        - code-review: Review a pull request.
        - not listed: ignored
        """
        let skills = SlashCatalog.skills(listing: listing, names: ["codex:rescue", "code-review", "init"])
        XCTAssertEqual(skills, ["codex:rescue": "Delegate investigation to Codex.", "code-review": "Review a pull request.", "init": ""])
    }

    func testTheAgentsOwnMenuIsReadOnlyAsARunOfRows() {
        let rows = SlashCatalog.menu([
            "  /usage                      Show plan usage limits",
            "  /clear (reset, new)         Clear conversation history and free up context",
            "  /user-tool (user)           Runs the tool…",
            "",
        ])
        XCTAssertEqual(rows.map(\.name), ["usage", "clear", "user-tool"])
        XCTAssertEqual(rows[1].detail, "Clear conversation history and free up context")
        XCTAssertTrue(SlashCatalog.menu(["  /usage                      Show plan usage limits"]).isEmpty, "A lone line is output, not a menu.")
        XCTAssertTrue(SlashCatalog.menu(["  /Users/me/a.swift     changed", "  /Users/me/b.swift     changed"]).isEmpty)
    }

    func testClaudesMenuUnderTheBoxIsKeptApartFromTheConversation() {
        let rule = String(repeating: "─", count: 80)
        let screen = ClaudeComposer.split("⏺ Listo.\n\n" + rule + "\n❯ /us\n" + rule + "\n  /usage          Show plan usage limits\n  /user-tool      Runs the tool")
        XCTAssertEqual(screen.input, "/us")
        XCTAssertEqual(screen.menu.map(\.name), ["usage", "user-tool"])
        let codex = TerminalSession.screen("› /mo\n\n  /model     choose what model and reasoning effort to use\n  /mention   mention a file", agent: .codex)
        XCTAssertEqual(codex.menu.map(\.name), ["model", "mention"])
        XCTAssertTrue(TerminalSession.screen("  /model     a\n  /mention   b", agent: nil).menu.isEmpty, "A plain shell has no agent menu.")
    }

    func testTheStoreKeepsRealCommandsAndDropsOneOffTypos() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-commands-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-work"), withIntermediateDirectories: true)
        let typed = ["/usage", "/usage", "/model opus", "/model", "/exxit", "/Users/me/video.mp4", "hola", "/tarea", "/tarea revisar"]
        let lines = typed.map { text -> String in
            String(data: try! JSONSerialization.data(withJSONObject: ["display": text, "timestamp": 1]), encoding: .utf8)!
        }
        try lines.joined(separator: "\n").write(to: home.appendingPathComponent(".claude-work/history.jsonl"), atomically: true, encoding: .utf8)
        let suite = "nook-commands-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SlashCommandStore(home: home, defaults: defaults, reference: [:])
        let read = expectation(description: "history read")
        store.refresh { read.fulfill() }
        wait(for: [read], timeout: 5)
        store.learn([SlashCommand(name: "compact", detail: "Clear history but keep a summary…")], agent: .claude)
        store.learn([SlashCommand(name: "compact", detail: "Clear")], agent: .claude)

        let commands = store.commands(agent: .claude, skills: ["code-review": "Review a pull request."], accepted: ["btw"], sent: ["/effort", "/effort high"])
        let byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["usage", "model", "tarea", "compact", "code-review", "btw", "effort"])
        XCTAssertEqual(byName["usage"]?.uses, 2)
        XCTAssertEqual(byName["compact"]?.detail, "Clear history but keep a summary…", "A cut description never replaces a longer one.")
        XCTAssertNil(byName["usage"]?.detail)
        XCTAssertTrue(store.commands(agent: .codex).isEmpty)

        let again = SlashCommandStore(home: home, defaults: defaults, reference: [:])
        XCTAssertEqual(again.commands(agent: .claude).map(\.name), ["compact"], "What the menu showed is kept across launches.")

        // The official reference adds every built-in command; its descriptions win over cut rows.
        let documented = SlashCommandStore(home: home, defaults: defaults, reference: [.claude: [
            SlashCommand(name: "compact", detail: "Free up context by summarizing the conversation so far", hint: "[instructions]"),
            SlashCommand(name: "help", detail: "Show help and available commands")]])
        let listed = Dictionary(uniqueKeysWithValues: documented.commands(agent: .claude).map { ($0.name, $0) })
        XCTAssertEqual(Set(listed.keys), ["compact", "help"])
        XCTAssertEqual(listed["compact"]?.detail, "Free up context by summarizing the conversation so far")
        XCTAssertEqual(listed["compact"]?.hint, "[instructions]")
        XCTAssertTrue(documented.commands(agent: .codex).isEmpty, "Claude's reference is not Codex's.")
    }

    func testClaudesRecordListsSkillsEvenWhenItsStartIsSkipped() throws {
        func line(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-skills-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let listing = line(["type": "attachment", "attachment": ["type": "skill_listing", "isInitial": true, "names": ["init", "codex:rescue"],
                                                                 "content": "- init: Set up CLAUDE.md\n- codex:rescue: Ask Codex"]])
        let filler = (0..<200).map { line(["type": "user", "message": ["role": "user", "content": "mensaje \($0) " + String(repeating: "x", count: 60)]]) }
        let command = line(["type": "user", "message": ["role": "user", "content": "<command-name>/usage</command-name><command-args></command-args>"]])
        try ([listing] + filler + [command]).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let follower = TranscriptFollower(url: url, initialBytes: 2_000)
        XCTAssertNotNil(follower.poll())
        XCTAssertFalse(follower.renderer.text.contains("mensaje 0 "), "The start was skipped.")
        XCTAssertEqual(follower.renderer.skills, ["init": "Set up CLAUDE.md", "codex:rescue": "Ask Codex"])
        XCTAssertEqual(follower.renderer.usedCommands, ["usage"])
    }
}
