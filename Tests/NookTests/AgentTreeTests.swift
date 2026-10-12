import XCTest
@testable import Nook

/// The list of agents Claude Code (2.1.29x) draws under its mode line while agents run ("← for agents · ↓ to manage"). The
/// fixtures are what Sample saw in Nook's chat: one with a wide screen, one from a narrow pane where the counters wrap.
final class AgentTreeTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)
    private let mode = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage"

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    /// A wide screen: one agent, its counters on its own row.
    private var wide: String {
        lines(["⏺ Le pedí la lista de contactos a un agente.", "", "✻ Waiting for 1 background agent to finish", "", rule, "❯ ", rule, mode, "", "  ⏺ main",
               "  coder  Reading ContactList in contact-list.tsx                                            1m 51s · ↓ 187.7k tokens"])
    }

    /// A narrow pane: a status mark per agent and the counters wrapped to the edge, under "⏺️" with its emoji selector.
    private var narrow: String {
        lines(["  Te aviso cuando termine cada agente.", "", "✻ Waiting for 3 background agents to finish", "", rule, "❯ ", rule, mode, "", "  ⏺️ main",
               "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens",
               "  ○ fork  Charting echo failures in deliveries.log", "4m 56s · ↓ 189.9k tokens",
               "  ○ fork  Finding AgentPrompt construction call sites", "4m 56s · ↓ 208.6k tokens"])
    }

    func testTheListOnOneLinePerAgent() throws {
        let rows = try XCTUnwrap(AgentActivity.tree(wide))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "coder")
        XCTAssertEqual(rows[0].activity, "Reading ContactList in contact-list.tsx")
        XCTAssertEqual(rows[0].duration, "1m 51s")
        XCTAssertEqual(rows[0].tokens, "187.7k")
        XCTAssertEqual(rows[0].state, .running)
    }

    func testTheListWithItsCountersWrappedToTheEdge() throws {
        let rows = try XCTUnwrap(AgentActivity.tree(narrow))
        XCTAssertEqual(rows.map(\.name), ["fork", "fork", "fork"])
        XCTAssertEqual(rows.map(\.activity), ["Reading NotchController expand and keepIslandWithTerminal", "Charting echo failures in deliveries.log",
                                               "Finding AgentPrompt construction call sites"])
        XCTAssertEqual(rows.map(\.tokens), ["187.3k", "189.9k", "208.6k"])
        XCTAssertEqual(rows.map(\.duration), ["4m 56s", "4m 56s", "4m 56s"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "Agents with the same name stay apart.")
        XCTAssertTrue(rows.allSatisfy(\.isRunning))
    }

    func testTheScreenAloneFeedsTheAgentPill() {
        // Without Claude's record, the screen's own reading finds the agents from the list.
        let agents = AgentActivity.parse(narrow)
        XCTAssertEqual(agents.count, 3)
        XCTAssertEqual(SubagentSummary(agents).running, 3)
        XCTAssertEqual(agents.first?.activity, "Reading NotchController expand and keepIslandWithTerminal")
        let one = AgentActivity.parse(wide)
        XCTAssertEqual(one.map(\.name), ["coder"])
        XCTAssertEqual(one.first?.tokens, "187.7k")
    }

    func testAnAgentSeenInTheConversationTakesTheListsWords() {
        let screen = lines(["⏺ Explore(Find the contact list)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "", "⏺ Sigo con lo demás.", "",
                            rule, "❯ ", rule, mode, "", "  ⏺ main", "  ○ Explore  Reading ContactList in contact-list.tsx  1m 51s · ↓ 12.4k tokens"])
        let agents = AgentActivity.parse(screen)
        XCTAssertEqual(agents.count, 1, "The list's row is the agent already seen, not another one.")
        XCTAssertEqual(agents.first?.name, "Find the contact list")
        XCTAssertEqual(agents.first?.activity, "Reading ContactList in contact-list.tsx")
        XCTAssertEqual(agents.first?.tokens, "12.4k")
        XCTAssertEqual(agents.first?.state, .running, "The mode line has no count any more; the list says it still runs.")
    }

    func testABackgroundAgentTheListLeavesOutIsOver() {
        let screen = lines(["⏺ Explore(Find the contact list)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "",
                            "⏺ Agent(Review the diff)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "", "⏺ Sigo.", "",
                            rule, "❯ ", rule, mode, "", "  ⏺ main", "  ○ Explore  Reading ContactList  1m 51s · ↓ 12.4k tokens"])
        let agents = AgentActivity.parse(screen)
        XCTAssertEqual(agents.map(\.name), ["Find the contact list", "Review the diff"])
        XCTAssertEqual(agents.map(\.state), [.running, .done])
    }

    func testTheModeLineWithoutACountNoLongerEndsBackgroundAgents() {
        // "← for agents" replaced the "2 background" pill: without the list on screen, the waiting line is the count.
        let screen = lines(["⏺ Agent(Review the diff)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "", "⏺ Sigo.", "",
                            "✻ Waiting for 1 background agent to finish", "", rule, "❯ ", rule, mode])
        XCTAssertEqual(AgentActivity.parse(screen).map(\.state), [.running])
    }

    func testTheRecordsAgentsTakeTheListsWordsInOrder() {
        func launched(_ call: String, _ name: String) -> SubagentActivity {
            SubagentActivity(id: call, name: name, kind: "fork", state: .running, background: true, tokens: "250k", activity: "Bash(swift build)")
        }
        let record = [launched("a", "L1 logic: Terminal-backed tabs"), launched("b", "L2 logic: delivery"), launched("c", "L3 logic: prompts")]
        let merged = AgentActivity.merged(record, tree: AgentActivity.tree(narrow))
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"], "No duplicates: each row updates one agent from the record.")
        XCTAssertEqual(merged.map(\.name), record.map(\.name), "The record's names stay; they say what each was asked.")
        XCTAssertEqual(merged.map(\.activity), ["Reading NotchController expand and keepIslandWithTerminal", "Charting echo failures in deliveries.log",
                                                 "Finding AgentPrompt construction call sites"])
        XCTAssertEqual(merged.map(\.tokens), ["187.3k", "189.9k", "208.6k"])
        XCTAssertEqual(AgentActivity.merged(record, tree: nil), record)
        // A row nobody in the record matches joins them.
        XCTAssertEqual(AgentActivity.merged(Array(record.prefix(1)), tree: AgentActivity.tree(wide)).map(\.name), ["L1 logic: Terminal-backed tabs", "coder"])
    }

    func testTheChatLosesTheList() {
        let without = AgentActivity.withoutTree(narrow)
        XCTAssertTrue(without.hasSuffix(mode), "Everything from the blank line after the mode line goes.")
        XCTAssertFalse(without.contains("fork"))
        XCTAssertEqual(AgentActivity.withoutTree("⏺ Hola"), "⏺ Hola")
    }

    func testOrdinaryTextIsNeverTheList() {
        XCTAssertNil(AgentActivity.tree(""))
        XCTAssertNil(AgentActivity.tree(lines(["⏺ Hecho.", "", rule, "❯ ", rule, mode])), "The mode line alone has no list under it.")
        XCTAssertNil(AgentActivity.tree(lines(["⏺ Resumen:", "  main  la rama principal", "  coder  el agente que escribe  1m 51s · ↓ 3k tokens"])),
                     "Without \"⏺ main\" or the mode line above, rows that look alike are a reply.")
        XCTAssertNil(AgentActivity.tree(lines(["⏺ Tardó esto:", "4m 56s · ↓ 187.3k tokens"])))
        XCTAssertNil(AgentActivity.tree(lines([mode, "", "Some notice from Claude"])))
    }

    // MARK: - One recogniser

    func testTheChatAndTheAgentsAgreeOnWhatIsTheList() throws {
        for screen in [wide, narrow] {
            let lines = screen.components(separatedBy: "\n")
            let range = try XCTUnwrap(ClaudeAgentTree.range(in: lines))
            var kept = Array(lines[..<range.lowerBound])
            while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
            XCTAssertEqual(AgentActivity.withoutTree(screen), kept.joined(separator: "\n"))
            XCTAssertNotNil(AgentActivity.tree(screen))
        }
        // "⏺ main" as the last reply, with nothing of Claude's box above it, is a reply for both.
        let reply = lines(["⏺ La rama es:", "", "⏺ main"])
        XCTAssertNil(ClaudeAgentTree.range(in: reply.components(separatedBy: "\n")))
        XCTAssertNil(AgentActivity.tree(reply))
        XCTAssertEqual(AgentActivity.withoutTree(reply), reply)
    }

    func testAFocusedListStillNamesItsAgents() throws {
        // With the list focused (↓ to manage) "↑/↓ to select" replaces the mode line and the rows gain "❯".
        let screen = lines(["⏺ Listo.", rule, "❯ avísame cuando esté publicado", rule, "  ↑/↓ to select", "❯ ⏺ main",
                            "❯ ◯ general-purpose  Adding suggestion renders to DisplayRenderTests                         41m 40s",
                            "  ◯ Explore  Searching for the hook helper  2m 3s · ↓ 9.1k tokens"])
        let rows = try XCTUnwrap(AgentActivity.tree(screen))
        XCTAssertEqual(rows.map(\.name), ["general-purpose", "Explore"])
        XCTAssertEqual(rows.map(\.activity), ["Adding suggestion renders to DisplayRenderTests", "Searching for the hook helper"])
        XCTAssertEqual(rows.map(\.duration), ["41m 40s", "2m 3s"])
        XCTAssertEqual(AgentActivity.withoutTree(screen), lines(["⏺ Listo.", rule, "❯ avísame cuando esté publicado", rule]))
    }

    // MARK: - On the tab

    private func tab(_ text: String) -> TerminalTabSnapshot {
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys092", customTitle: "", processes: ["login", "-zsh", "claude"], busy: true, selected: true, text: text)
        tab.history = true
        return tab
    }

    func testWithItsRecordATabShowsTheRecordsAgentsWithTheListsWords() throws {
        let model = AppModel(receivesSignals: false)
        let session = TerminalSession(tab: tab("⏺ Hola"), backend: .bundled, bridge: model.terminalBridge)
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("nook-tree-\(UUID().uuidString.prefix(8)).jsonl")
        try "".write(to: record, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: record) }
        session.transcript = TranscriptFollower(url: record)
        let launched = ["L1 logic: Terminal-backed tabs", "L2 logic: delivery", "L3 logic: prompts"].enumerated().map { index, name in
            SubagentActivity(id: "call-\(index)", name: name, kind: "fork", state: .running, background: true, tokens: "250k")
        }
        session.applyTranscript(nil, recap: nil, agents: launched)
        XCTAssertEqual(session.subagents, launched, "No list on screen yet: the record's agents as they are.")
        session.update(tab(narrow))
        XCTAssertEqual(session.subagents.map(\.id), ["call-0", "call-1", "call-2"], "The same agents, not a second copy from the list.")
        XCTAssertEqual(session.subagents.map(\.activity), ["Reading NotchController expand and keepIslandWithTerminal", "Charting echo failures in deliveries.log",
                                                         "Finding AgentPrompt construction call sites"])
        XCTAssertEqual(session.subagents.map(\.tokens), ["187.3k", "189.9k", "208.6k"])
        // A new reading of the record keeps the list's words on top.
        session.applyTranscript(nil, recap: nil, agents: launched)
        XCTAssertEqual(session.subagents.first?.activity, "Reading NotchController expand and keepIslandWithTerminal")
        // An agent only the list shows (the record has not named it yet) still shows.
        session.applyTranscript(nil, recap: nil, agents: [])
        XCTAssertEqual(session.subagents.map(\.name), ["fork", "fork", "fork"])
        // The list gone from the screen: the record alone again.
        session.applyTranscript(nil, recap: nil, agents: launched)
        session.update(tab(lines(["⏺ Hola otra vez", "", rule, "❯ ", rule, mode])))
        XCTAssertEqual(session.subagents, launched)
    }
}
