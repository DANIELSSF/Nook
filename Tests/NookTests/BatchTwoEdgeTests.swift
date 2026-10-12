import XCTest
@testable import Nook

/// Edge cases added by QA for the second batch of 2026-10-06: resumed agents' ids, a ghost suggestion while Claude is busy, long `!` commands.
final class BatchTwoEdgeTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.3, hold: 0.05, settle: 0.1)

    private func screen(_ conversation: [String], box: String) -> String { (conversation + [rule, "❯ " + box, rule, footer]).joined(separator: "\n") }

    private func follower(agentFiles: [String]) throws -> TranscriptFollower {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-edge-\(UUID().uuidString.prefix(8))")
        let agents = folder.appendingPathComponent("sess/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let record = folder.appendingPathComponent("sess.jsonl")
        // A resume reply for an agent that has no meta file and no record of its own.
        let reply = "{\"success\":true,\"message\":\"Resuming agent zz\",\"resumedAgentId\":\"zzzzzzzzzzzzzzzzz\"}"
        let line = try JSONSerialization.data(withJSONObject: ["type": "user", "timestamp": "2026-10-06T10:00:00.000Z",
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_x", "content": [["type": "text", "text": reply]]]]]])
        try (String(data: line, encoding: .utf8)! + "\n").write(to: record, atomically: true, encoding: .utf8)
        for name in agentFiles { try "{}\n".write(to: agents.appendingPathComponent("agent-\(name).jsonl"), atomically: true, encoding: .utf8) }
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return TranscriptFollower(url: record)
    }

    func testAgentRecordAcceptsOnlyPlainIds() throws {
        let f = try follower(agentFiles: ["abc123", "a.b"])
        XCTAssertNotNil(f.agentRecord(call: "agent:abc123"))
        for bad in ["agent:", "agent:..", "agent:a/b", "agent:a.b", "agent:../abc123", "agent:/abc123", "agent:abc123.jsonl", "agent:missing"] {
            XCTAssertNil(f.agentRecord(call: bad), bad)
        }
    }

    func testAResumeReplyForAnAgentNobodyKnowsDoesNotCrashOrInventARow() throws {
        let f = try follower(agentFiles: [])
        _ = f.poll()
        for agent in f.agents() { XCTAssertNil(f.agentRecord(call: agent.id), "A row that cannot be opened must not be offered: \(agent.id)") }
    }

    /// Claude is working (its box holds the message as a queued input); nothing changes in the box for 1.5 s. The message is already there:
    /// it must never be typed a second time.
    func testAMessageAlreadyInTheBoxWhileClaudeWorksIsNotTypedTwice() throws {
        var actions: [String] = []
        let busy = screen(["⏺ Trabajando…", "", "✻ Pensando… (esc to interrupt)"], box: "sigue con lo siguiente")
        try? TerminalAppBridge.deliver("sigue con lo siguiente", agent: .claude, timing: fast, run: { actions.append($0) }, read: { busy })
        XCTAssertFalse(actions.contains(TerminalAppBridge.typeAction("sigue con lo siguiente")), "Typed over what is already there: \(actions)")
    }

    func testAShellCommandOver200BytesWithUnicodeTravelsAsOnePasteWithItsBang() {
        let command = "!echo " + String(repeating: "añadir línea ✓ ", count: 30)
        XCTAssertGreaterThan(command.utf8.count, 200)
        let action = TerminalAppBridge.messageAction(command)
        XCTAssertTrue(action.hasPrefix("do script (\"!\""))
        XCTAssertTrue(action.contains("[200~"))
        XCTAssertTrue(action.contains("añadir línea ✓"))
        XCTAssertFalse(action.contains("\n"), "One AppleScript statement line.")
    }
}
