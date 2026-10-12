import XCTest
@testable import Nook

/// Why a Terminal tab with Claude showed the raw screen (and no agent pill) instead of Claude's record: the record was never
/// located. Claude runs its hooks without a terminal, so their signals named no tab, and the fallback (the last prompt on
/// screen) missed prompts Terminal wrapped at the edge. The record's own agents, forks launched in the background, were read
/// fine all along; the last test proves it with the shape of Sample's session (2026-10-06, Claude Code 2.1.291).
final class TranscriptLocationTests: XCTestCase {
    // MARK: - Hooks name their tab

    func testAHookWithoutATerminalTakesItsClaudesTerminal() {
        // hook (no terminal) → /bin/sh (no terminal) → claude on ttys009 → zsh → login → Terminal.
        let table: [pid_t: (String, pid_t)] = [900: ("??", 800), 800: ("??", 56801), 56801: ("ttys009", 56401), 56401: ("ttys009", 56399), 56399: ("ttys009", 1780)]
        XCTAssertEqual(ClaudeHooks.terminal(from: 900) { table[$0].map { (tty: $0.0, parent: $0.1) } }, "/dev/ttys009")
        XCTAssertEqual(ClaudeHooks.terminal(from: 56801) { table[$0].map { (tty: $0.0, parent: $0.1) } }, "/dev/ttys009", "A hook with a terminal of its own keeps it.")
    }

    func testAHookWithNoTerminalAnywhereNamesNone() {
        let table: [pid_t: (String, pid_t)] = [900: ("??", 800), 800: ("??", 700), 700: ("??", 1)]
        XCTAssertEqual(ClaudeHooks.terminal(from: 900) { table[$0].map { (tty: $0.0, parent: $0.1) } }, "")
        XCTAssertEqual(ClaudeHooks.terminal(from: 900) { _ in nil }, "", "ps failing names nothing.")
        // A long chain stops: the terminal of something far above is not Claude's.
        var chain: [pid_t: (String, pid_t)] = [:]
        for pid in pid_t(2)...pid_t(20) { chain[pid] = ("??", pid + 1) }
        chain[21] = ("ttys001", 1)
        XCTAssertEqual(ClaudeHooks.terminal(from: 2) { chain[$0].map { (tty: $0.0, parent: $0.1) } }, "")
    }

    func testThisProcessFindsItsTerminalTheSameWay() {
        // Whatever runs the tests: the walk never returns "??" or a bare name.
        let found = ClaudeHooks.terminal(from: getpid())
        XCTAssertTrue(found.isEmpty || found.hasPrefix("/dev/tty"), found)
    }

    // MARK: - The prompt on screen, wrapped at the edge

    func testAPromptWrappedAtTheEdgeStillCounts() {
        let prompt = "la logica para opus el arquitectto tu que seras el que le diga que se debe lograr y la ui para sonnet, qa con sonent y sevurirty con haiku"
        let screen = ["⏺ Hecho.", "", "❯ la logica para opus el arquitectto tu que seras el que le diga que se debe", "lograr y la ui para sonnet, qa con sonent y sevurirty con haiku",
                      "", "⏺ Voy."].joined(separator: "\n")
        XCTAssertTrue(TranscriptLocator.shows(prompt: prompt, on: screen))
        // What follows a prompt at the edge and opens something else is not part of it.
        let cut = ["❯ la logica para opus el arquitectto tu que seras el que le diga que se debe", "⏺ lograr y la ui para sonnet, qa con sonent y sevurirty con haiku"].joined(separator: "\n")
        XCTAssertFalse(TranscriptLocator.shows(prompt: prompt, on: cut))
        let boxed = ["❯ la logica para opus el arquitectto tu que seras el que le diga que se debe", String(repeating: "─", count: 60), "lograr y la ui"].joined(separator: "\n")
        XCTAssertFalse(TranscriptLocator.shows(prompt: prompt, on: boxed))
    }

    // MARK: - The record's agents

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Sample's session trimmed to what the agents need: one launch refused for an unknown type, three forks launched in the
    /// background ("run_in_background" written as the string "true"), their "Async agent launched" results with the agentId,
    /// the metadata files Claude writes for them, and a fork's own record (which opens with a reference to its parent).
    func testForksLaunchedInTheBackgroundAreReadFromTheRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-forks-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("11453b18.jsonl")
        let agents = folder.appendingPathComponent("11453b18/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-300)
        let forks = [("toolu_L1", "ae22dc483f4cdbfd1", "L1 logic: Terminal-backed tabs + tab identity"),
                     ("toolu_L2", "ac0279f3e911a78f4", "L2 logic: delivery + Claude box/screen parsing"),
                     ("toolu_L3", "a5d47386391203888", "L3 logic: prompts, model picker, agent tree parsing")]
        var lines = [
            line(["type": "user", "cwd": "/Users/me/New project", "timestamp": stamp(start), "message": ["role": "user", "content": "organiza los sub agentes"]]),
            line(["type": "assistant", "timestamp": stamp(start.addingTimeInterval(5)), "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_refused", "name": "Agent", "input": ["description": "Logic L1: Terminal-backed tabs", "subagent_type": "logic-engineer", "prompt": "…", "run_in_background": "true"]]]]]),
            line(["type": "user", "timestamp": stamp(start.addingTimeInterval(6)), "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_refused", "is_error": true,
                 "content": "Agent type 'logic-engineer' not found. Available agents: claude, Explore, general-purpose, Plan, ui-designer"]]]]),
        ]
        for (offset, fork) in forks.enumerated() {
            let at = start.addingTimeInterval(10 + Double(offset))
            lines.append(line(["type": "assistant", "timestamp": stamp(at), "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": fork.0, "name": "Agent", "input": ["description": fork.2, "subagent_type": "fork", "prompt": "…", "run_in_background": "true"]]]]]))
        }
        for (offset, fork) in forks.enumerated() {
            let text = "Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it, including the agentId below, into a user-facing reply.)\n"
                + "agentId: \(fork.1) (internal ID - do not mention to user. Use SendMessage with to: '\(fork.1)', summary: '<5-10 word recap>' to continue this agent.)\n"
                + "The agent is working in the background. You will be notified automatically when it completes."
            lines.append(line(["type": "user", "timestamp": stamp(start.addingTimeInterval(14 + Double(offset))),
                               "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": fork.1, "description": fork.2],
                               "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": fork.0, "content": [["type": "text", "text": text]]]]]]))
            let meta: [String: Any] = ["agentType": "fork", "isFork": true, "description": fork.2, "toolUseId": fork.0, "requestShape": "background"]
            try JSONSerialization.data(withJSONObject: meta).write(to: agents.appendingPathComponent("agent-\(fork.1).meta.json"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)
        // L1's own record: the reference to its parent, the launch it was born from with its result, then its own work.
        let own = [
            line(["type": "fork-context-ref", "agentId": forks[0].1, "parentSessionId": "11453b18", "contextLength": 132]),
            line(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": forks[0].0, "name": "Agent", "input": ["description": forks[0].2, "subagent_type": "fork", "prompt": "…"]]]]]),
            line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": forks[0].0, "content": "Fork started — processing in background"], ["type": "text", "text": "<fork-boilerplate>…"]]]]),
            line(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "usage": ["input_tokens": 10, "cache_read_input_tokens": 186_000, "output_tokens": 1_300],
                                                   "content": [["type": "tool_use", "id": "toolu_read", "name": "Bash", "input": ["command": "sed -n 480,530p Sources/Nook/NotchController.swift"]]]]]),
        ]
        try (own.joined(separator: "\n") + "\n").write(to: agents.appendingPathComponent("agent-\(forks[0].1).jsonl"), atomically: true, encoding: .utf8)

        let follower = TranscriptFollower(url: record)
        _ = follower.poll()
        let shown = follower.agents(now: start.addingTimeInterval(300))
        XCTAssertEqual(shown.map(\.name), ["Logic L1: Terminal-backed tabs"] + forks.map(\.2))
        XCTAssertEqual(shown.map(\.state), [.failed, .running, .running, .running])
        XCTAssertEqual(shown.dropFirst().map(\.kind), ["fork", "fork", "fork"])
        XCTAssertTrue(shown.dropFirst().allSatisfy(\.background), "The launch's own words say it went to the background.")
        XCTAssertEqual(shown[1].activity, "Bash(sed -n 480,530p Sources/Nook/NotchController.swift)")
        XCTAssertEqual(shown[1].tokens, "187.3k")
        // The list under Claude's mode line adds its words to these agents, never a second copy of them.
        let tree = AgentActivity.tree(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage", "", "  ⏺️ main",
                                       "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens",
                                       "  ○ fork  Charting echo failures in deliveries.log", "4m 56s · ↓ 189.9k tokens",
                                       "  ○ fork  Finding AgentPrompt construction call sites", "4m 56s · ↓ 208.6k tokens"].joined(separator: "\n"))
        let merged = AgentActivity.merged(shown, tree: tree)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[1].activity, "Reading NotchController expand and keepIslandWithTerminal")
        XCTAssertEqual(merged[3].activity, "Finding AgentPrompt construction call sites")
    }

    // MARK: - The hook's copy of Nook stays current

    func testTheHooksCopyIsRefreshedOnlyWhenHooksUseItAndItIsStale() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-helper-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("Nook"), helper = folder.appendingPathComponent("Support/nook-hook")
        try Data("build 2".utf8).write(to: app)
        XCTAssertFalse(try ClaudeHooks.refreshHelper(inUse: false, from: app, to: helper), "Hooks the user never turned on get nothing.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
        XCTAssertTrue(try ClaudeHooks.refreshHelper(inUse: true, from: app, to: helper), "Turned on but missing: put back.")
        XCTAssertEqual(try Data(contentsOf: helper), Data("build 2".utf8))
        XCTAssertFalse(try ClaudeHooks.refreshHelper(inUse: true, from: app, to: helper), "The same build: nothing to do.")
        try Data("build 3".utf8).write(to: app)
        XCTAssertTrue(try ClaudeHooks.refreshHelper(inUse: true, from: app, to: helper), "Same size, other bytes: a newer Nook.")
        XCTAssertEqual(try Data(contentsOf: helper), Data("build 3".utf8))
        try Data("build 30".utf8).write(to: app)
        XCTAssertTrue(try ClaudeHooks.refreshHelper(inUse: true, from: app, to: helper))
        let mode = try FileManager.default.attributesOfItem(atPath: helper.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: helper.deletingLastPathComponent().path), ["nook-hook"], "No staging copies left behind.")
    }
}
