import XCTest
@testable import Nook

final class AgentActivityTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)
    private let mode = "  ⏵⏵ auto mode on (shift+tab to cycle)"
    /// The mode line while two background tasks run: Claude adds a pill with their count.
    private let busyMode = "  ⏵⏵ auto mode on (shift+tab to cycle) · 2 background · ↓ to manage"

    /// Claude's own input box and mode line under the conversation, as they appear in the raw mirror.
    private func screen(_ conversation: [String], modeLine: String? = nil, spinner: String? = nil) -> String {
        (conversation + [""] + (spinner.map { [$0, ""] } ?? []) + [rule, "❯ ", rule, modeLine ?? mode]).joined(separator: "\n")
    }

    private func parse(_ lines: [String], modeLine: String? = nil) -> [SubagentActivity] {
        AgentActivity.parse(screen(lines, modeLine: modeLine))
    }

    // MARK: - Single agents

    func testEmptyAndPlainInputFindNothing() {
        XCTAssertEqual(AgentActivity.parse(""), [])
        XCTAssertEqual(AgentActivity.parse("  \n\n \t\n"), [])
        XCTAssertEqual(AgentActivity.parse("~ % ls\nREADME.md  Sources"), [])
        XCTAssertEqual(parse(["⏺ Hola, ¿en qué te ayudo?"]), [])
    }

    func testRunningAgentWithNestedToolLines() {
        let agents = AgentActivity.parse(screen([
            "⏺ Voy a pedirle el diseño a un agente.",
            "",
            "⏺ Agent(Design cat pet animations)",
            "  ⎿  Read(Sources/Nook/PetAnimation.swift)",
            "     Search(pattern: \"walk\")",
            "     … +12 tool uses (ctrl+o to expand)",
        ], spinner: "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)"))
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].name, "Design cat pet animations")
        XCTAssertNil(agents[0].kind)
        XCTAssertEqual(agents[0].state, .running)
        XCTAssertFalse(agents[0].background)
        XCTAssertEqual(agents[0].detail, "Iniciando…")
    }

    func testOlderWordingForHiddenToolUsesStillCountsAsEvidence() {
        let agents = parse(["⏺ my-reviewer(Check the diff)", "  ⎿  Read(a.swift)", "     +4 more tool uses (ctrl+o to expand)"])
        XCTAssertEqual(agents.first?.kind, "my-reviewer")
    }

    func testTaskFromOlderVersionsAndInitializing() {
        let agents = parse(["⏺ Task(Explore the repo)", "  ⎿  Initializing…"])
        XCTAssertEqual(agents.map(\.name), ["Explore the repo"])
        XCTAssertEqual(agents.first?.state, .running)
    }

    func testBackgroundedAgentStaysRunningAfterClaudeKeepsTalking() {
        let agents = parse([
            "⏺ Agent(Design cat pet animations)",
            "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)",
            "",
            "⏺ Lo dejé trabajando; mientras tanto reviso el parser.",
        ], modeLine: "  ⏵⏵ auto mode on (shift+tab to cycle) · 1 background · ↓ to manage")
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].state, .running)
        XCTAssertTrue(agents[0].background)
        XCTAssertEqual(agents[0].detail, "En segundo plano")
    }

    func testDoneAgentKeepsItsCounters() {
        let agents = parse(["⏺ Task(Explore the repo)", "  ⎿  Done (23 tool uses · 41.2k tokens · 3m 12s)"])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].state, .done)
        XCTAssertEqual(agents[0].toolUses, 23)
        XCTAssertEqual(agents[0].tokens, "41.2k")
        XCTAssertEqual(agents[0].duration, "3m 12s")
        XCTAssertEqual(agents[0].detail, "23 herramientas · 41.2k tokens · 3m 12s")
        let single = parse(["⏺ Agent(Una sola cosa)", "  ⎿  Done (1 tool use · 900 tokens · 8s)"])
        XCTAssertEqual(single.first?.detail, "1 herramienta · 900 tokens · 8s")
        XCTAssertEqual(parse(["⏺ Agent(Sin cifras)", "  ⎿  Done"]).first?.detail, "Listo")
    }

    func testFailedAndInterruptedAgents() {
        let failed = parse(["⏺ Agent(Run the migration)", "  ⎿  Error: Agent exceeded its context window"])
        XCTAssertEqual(failed.first?.state, .failed)
        XCTAssertEqual(failed.first?.note, "Con error")
        let stopped = parse(["⏺ Agent(Run the migration)", "  ⎿  Interrupted · What should Claude do instead?"])
        XCTAssertEqual(stopped.first?.state, .failed)
        XCTAssertEqual(stopped.first?.detail, "Interrumpido")
    }

    func testTypedAgentsNeedEvidenceUnlessTheTypeShipsWithClaude() {
        let explore = parse(["⏺ Explore(Find the auth code)"])
        XCTAssertEqual(explore.first?.kind, "Explore")
        XCTAssertEqual(explore.first?.name, "Find the auth code")
        XCTAssertEqual(explore.first?.state, .running)
        XCTAssertEqual(parse(["⏺ code-reviewer(Check the diff)"]), [], "A custom name alone could be any tool.")
        let custom = parse(["⏺ code-reviewer(Check the diff)", "  ⎿  Done (3 tool uses · 5.1k tokens · 20s)"])
        XCTAssertEqual(custom.first?.kind, "code-reviewer")
        XCTAssertEqual(custom.first?.state, .done)
        let plugin = parse(["⏺ codex:codex-rescue(Fix the flaky test)", "  ⎿  Initializing…"])
        XCTAssertEqual(plugin.first?.kind, "codex:codex-rescue")
    }

    // MARK: - No false positives

    func testOrdinaryToolsAndRepliesAreNeverAgents() {
        let conversation = [
            "⏺ Read(Sources/Nook/PanelView.swift)",
            "  ⎿  Read 486 lines",
            "",
            "⏺ Bash(swift build)",
            "  ⎿  Done",
            "",
            "⏺ Bash(touch /tmp/x)",
            "  ⎿  (No output)",
            "",
            "⏺ Bash(npm run dev)",
            "  ⎿  Running in the background (↓ to manage)",
            "",
            "⏺ Update(Sources/Nook/Session.swift)",
            "  ⎿  Updated Sources/Nook/Session.swift with 3 additions",
            "",
            "⏺ Search(pattern: \"Agent\")",
            "  ⎿  Found 3 files",
            "",
            "⏺ Fetch(https://example.com)",
            "  ⎿  Error: 404",
            "",
            "⏺ TaskCreate(Revisar el parser)",
            "  ⎿  Task #1 created",
            "",
            "⏺ El Agent(foo) del que hablas ya terminó y tomó 3 tool uses.",
            "⏺ 3 agents are great for this",
            "⏺ Running tests…",
        ]
        XCTAssertEqual(parse(conversation), [])
    }

    func testIndentedTextCodeAndQuotesAreIgnored() {
        let conversation = [
            "⏺ Así se ve una llamada a un agente:",
            "  ⏺ Agent(Design cat pet animations)",
            "    ⎿  Done (23 tool uses · 41.2k tokens · 3m 12s)",
            "  ```",
            "  ⏺ Task(Explore the repo)",
            "  Running 3 agents…",
            "  ├─ one · 3 tool uses",
            "  ```",
            "  > Agent \"Design cat pet animations\" completed",
        ]
        XCTAssertEqual(parse(conversation), [])
    }

    func testGroupWordingInsideProseNeedsRows() {
        XCTAssertEqual(parse(["⏺ Running 3 agents…"]), [])
        XCTAssertEqual(parse(["⏺ 3 agents finished"]), [])
    }

    func testTextWithoutClaudeStructureIsIgnored() {
        let shell = ["~ % grep -rn \"Agent(\" Sources", "Sources/Nook/Foo.swift:3: Agent(x)", "Done (3 tool uses · 5k tokens · 20s)", "Task(Explore the repo)", "agents finished"]
        XCTAssertEqual(AgentActivity.parse(shell.joined(separator: "\n")), [])
    }

    // MARK: - Parallel agents

    func testRunningGroupListsEveryRowWithItsOwnState() {
        let agents = parse([
            "⏺ Running 3 Explore agents…  (ctrl+o to expand)",
            "   ├─ Find auth code · 3 tool uses · 12.3k tokens",
            "   │  ⎿  Read(src/auth.ts)",
            "   ├─ Map the database layer · 0 tool uses",
            "   │  ⎿  Initializing…",
            "   └─ Review the API · 5 tool uses · 8k tokens",
            "      ⎿  Done",
        ])
        XCTAssertEqual(agents.map(\.name), ["Find auth code", "Map the database layer", "Review the API"])
        XCTAssertEqual(agents.map(\.state), [.running, .running, .done])
        XCTAssertEqual(agents.map(\.kind), ["Explore", "Explore", "Explore"])
        XCTAssertEqual(agents[0].toolUses, 3)
        XCTAssertEqual(agents[0].tokens, "12.3k")
        XCTAssertEqual(agents[1].toolUses, 0)
        XCTAssertNil(agents[1].tokens)
        XCTAssertEqual(agents[2].detail, "5 herramientas · 8k tokens")
    }

    func testFinishedGroupAndMixedTypes() {
        let agents = parse([
            "⏺ 2 agents finished (ctrl+o to expand)",
            "   ├─ Explore (Find auth code) · 11 tool uses · 28.2k tokens",
            "   │  ⎿  Done",
            "   └─ Agent (Fix the failing test) · 7 tool uses · 19.6k tokens",
            "      ⎿  Done",
        ])
        XCTAssertEqual(agents.map(\.name), ["Find auth code", "Fix the failing test"])
        XCTAssertEqual(agents.map(\.kind), ["Explore", nil])
        XCTAssertEqual(agents.map(\.state), [.done, .done])
    }

    func testBackgroundLaunchGroupIsRunningInTheBackground() {
        let agents = parse([
            "⏺ 2 background agents launched (↓ to manage)",
            "   ├─ Design cat pet animations",
            "   └─ Review the notch layout",
        ], modeLine: "  ⏵⏵ auto mode on (shift+tab to cycle) · 2 background · ↓ to manage")
        XCTAssertEqual(agents.map(\.state), [.running, .running])
        XCTAssertEqual(agents.map(\.background), [true, true])
    }

    // MARK: - Completion of background agents

    func testCompletionNoticeClosesTheMatchingBackgroundAgent() {
        let lines = [
            "⏺ Agent(Design cat pet animations)",
            "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)",
            "⏺ Agent(Review the notch layout)",
            "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)",
            "",
            "⏺ Agent \"Design cat pet animations\" completed",
        ]
        let agents = parse(lines, modeLine: busyMode)
        XCTAssertEqual(agents.map(\.state), [.done, .running])
        let stopped = parse(lines.dropLast() + ["⏺ Background agent \"Review the notch layout\" was stopped by the user."], modeLine: busyMode)
        XCTAssertEqual(stopped.map(\.state), [.running, .failed])
        XCTAssertEqual(stopped.last?.note, "Detenido")
        XCTAssertEqual(parse(lines.dropLast() + ["⏺ Agent \"Algo que nunca vimos\" completed"], modeLine: busyMode).map(\.state), [.running, .running])
    }

    func testBottomOfTheScreenRetiresBackgroundAgentsThatNoLongerRun() {
        let launches = [
            "⏺ Agent(First job)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)",
            "⏺ Agent(Second job)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)",
            "", "⏺ Esperando resultados.",
        ]
        XCTAssertEqual(parse(launches, modeLine: "  ⏵⏵ auto mode on (shift+tab to cycle) · 1 background · ↓ to manage").map(\.state), [.done, .running])
        XCTAssertEqual(parse(launches, modeLine: "  ⏵⏵ auto mode on (shift+tab to cycle) · 2 bg").map(\.state), [.running, .running])
        XCTAssertEqual(parse(launches).map(\.state), [.done, .done], "The mode line is visible and shows no background pill.")
        // Without the mode line (the conversation alone) nothing is retired.
        XCTAssertEqual(AgentActivity.parse(launches.joined(separator: "\n")).map(\.state), [.running, .running])
        let waiting = launches + ["✻ Waiting for 1 background agent to finish"]
        XCTAssertEqual(AgentActivity.parse(waiting.joined(separator: "\n")).map(\.state), [.done, .running])
    }

    // MARK: - Dedupe and liveness

    func testTheNewestSightingOfAnAgentWins() {
        let frames = [
            "⏺ Agent(Design cat pet animations)", "  ⎿  Initializing…", "",
            "⏺ Agent(Design cat pet animations)", "  ⎿  Read(Sources/Nook/Pet.swift)", "     … +3 tool uses (ctrl+o to expand)", "",
            "⏺ Agent(Design cat pet animations)", "  ⎿  Done (9 tool uses · 20.1k tokens · 1m 5s)",
        ]
        let agents = parse(frames)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].state, .done)
        XCTAssertEqual(agents[0].toolUses, 9)
        XCTAssertEqual(parse(Array(frames.prefix(3))).first?.state, .running)
    }

    func testCutOffDescriptionsMergeWithTheCompleteOne() {
        let agents = parse([
            "⏺ Agent(Analyze the authentication flow and find…)", "  ⎿  Initializing…", "",
            "⏺ 1 agents finished",
            "   └─ Analyze the authentication flow and find every unused session helper · 4 tool uses · 6k tokens",
            "      ⎿  Done",
        ])
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].name, "Analyze the authentication flow and find every unused session helper")
        XCTAssertEqual(agents[0].state, .done)
        let id = agents[0].id
        XCTAssertEqual(parse(["⏺ Agent(Analyze the authentication flow and find every unused session helper)", "  ⎿  Initializing…"]).first?.id, id, "The id does not depend on how much of the text Claude showed.")
    }

    func testDifferentAgentsWithSimilarNamesStaySeparate() {
        let agents = parse([
            "⏺ Agent(Fix the login)", "  ⎿  Done (2 tool uses · 1k tokens · 4s)",
            "⏺ Agent(Fix the logout)", "  ⎿  Done (2 tool uses · 1k tokens · 4s)",
            "⏺ Agent(Fix)", "  ⎿  Done (2 tool uses · 1k tokens · 4s)",
        ])
        XCTAssertEqual(agents.count, 3)
    }

    func testForegroundAgentWithoutResultIsOverOnceClaudeMovedOn() {
        let running = parse(["⏺ Agent(Review the notch layout)", "  ⎿  Initializing…"])
        XCTAssertEqual(running.first?.state, .running)
        let inParallelWithOtherTools = parse(["⏺ Agent(Review the notch layout)", "  ⎿  Initializing…", "⏺ Read(Package.swift)", "  ⎿  Read 14 lines"])
        XCTAssertEqual(inParallelWithOtherTools.first?.state, .running)
        let moved = parse(["⏺ Agent(Review the notch layout)", "  ⎿  Initializing…", "", "⏺ Terminé la revisión, todo en orden."])
        XCTAssertEqual(moved.first?.state, .done)
        let userSpoke = parse(["⏺ Agent(Review the notch layout)", "  ⎿  Initializing…", "", "❯ sigue con lo siguiente", "", "⏺ Claro."])
        XCTAssertEqual(userSpoke.first?.state, .done)
        let typing = AgentActivity.parse(["⏺ Agent(Review the notch layout)", "  ⎿  Initializing…", "", rule, "❯ texto a medio escribir", rule, mode].joined(separator: "\n"))
        XCTAssertEqual(typing.first?.state, .running, "Text in the input box is not a message from the user.")
    }

    // MARK: - Messages, limits and encodings

    func testMessagesToOtherAgentsAreKeptAsContext() {
        let agents = parse([
            "⏺ Agent(Design cat pet animations)", "  ⎿  Initializing…",
            "⏺ SendMessage(to: researcher, summary: revisa el parser)",
            "  ⎿  Message sent",
        ])
        XCTAssertEqual(agents.map(\.role), [.agent, .message])
        XCTAssertEqual(agents[1].name, "@researcher")
        XCTAssertEqual(agents[1].state, .done)
        XCTAssertEqual(SubagentSummary(agents).total, 1, "Messages are not agents.")
        let many = (1...5).flatMap { ["⏺ SendMessage(to: agent\($0))", "  ⎿  Message sent"] }
        XCTAssertEqual(parse(many).count, AgentActivity.messageLimit)
    }

    func testTheCapKeepsRunningAgentsAndTheNewestFinishedOnes() {
        var lines: [String] = []
        for index in 1...10 {
            lines += ["⏺ Agent(Job \(index))", index % 4 == 0 ? "  ⎿  Initializing…" : "  ⎿  Done (1 tool use · 1k tokens · 2s)"]
        }
        // Jobs 4 and 8 have no result yet, nothing came after them, so they are still running and always make the cut.
        let agents = AgentActivity.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(agents.map(\.name), ["Job 4", "Job 6", "Job 7", "Job 8", "Job 9", "Job 10"])
        XCTAssertEqual(agents.filter(\.isRunning).map(\.name), ["Job 4", "Job 8"])
        let live = AgentActivity.parse((lines + ["⏺ Agent(Job 11)", "  ⎿  Initializing…"]).joined(separator: "\n"))
        XCTAssertEqual(live.map(\.name), ["Job 4", "Job 7", "Job 8", "Job 9", "Job 10", "Job 11"])
    }

    func testRunningAgentsOutrankFinishedOnesWhenTheCapApplies() {
        var lines: [String] = ["⏺ Agent(Long job)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)"]
        for index in 1...8 { lines += ["⏺ Agent(Quick \(index))", "  ⎿  Done (1 tool use · 1k tokens · 2s)"] }
        let agents = AgentActivity.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(agents.count, AgentActivity.limit)
        XCTAssertEqual(agents.first?.name, "Long job")
        XCTAssertEqual(agents.first?.state, .running)
        XCTAssertEqual(SubagentSummary(agents).running, 1)
    }

    func testNonBreakingSpacesCarriageReturnsAndTheCircleBullet() {
        let text = "● Task(Explore the repo)\r\n  ⎿\u{00A0}\u{00A0}Done (2 tool uses · 3.1k tokens · 45s)\r\n"
        let agents = AgentActivity.parse(text)
        XCTAssertEqual(agents.first?.name, "Explore the repo")
        XCTAssertEqual(agents.first?.duration, "45s")
        XCTAssertEqual(agents.first?.state, .done)
        let emoji = AgentActivity.parse("⏺\u{FE0F} Agent(Con selector de variación)\n  ⎿  Initializing…")
        XCTAssertEqual(emoji.first?.name, "Con selector de variación")
    }

    func testOnlyTheNewestLinesAreRead() {
        let old = ["⏺ Agent(Ancient job)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)"]
        let filler = (0..<(AgentActivity.maxLines + 20)).map { "  línea \($0) de una respuesta larga" }
        XCTAssertEqual(AgentActivity.parse((old + filler).joined(separator: "\n")), [])
        XCTAssertEqual(AgentActivity.parse((filler + old).joined(separator: "\n")).count, 1)
    }

    func testSummaryCountsStates() {
        let agents = parse([
            "⏺ Running 3 agents…",
            "   ├─ One · 1 tool use", "   │  ⎿  Initializing…",
            "   ├─ Two · 2 tool uses · 1k tokens", "   │  ⎿  Done",
            "   └─ Three · 1 tool use", "      ⎿  Error: boom",
        ])
        let summary = SubagentSummary(agents)
        XCTAssertEqual([summary.running, summary.done, summary.failed, summary.total], [1, 1, 1, 3])
    }

    func testParsingTheWholeHistoryIsFast() {
        var lines: [String] = []
        for index in 0..<1500 { lines += ["⏺ Read(File\(index).swift)", "  ⎿  Read 40 lines", "", "⏺ Listo \(index).", "  Texto de la respuesta número \(index)."] }
        let text = lines.joined(separator: "\n")
        let start = Date()
        for _ in 0..<5 { _ = AgentActivity.parse(text) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
