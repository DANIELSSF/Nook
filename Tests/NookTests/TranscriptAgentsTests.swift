import XCTest
@testable import Nook

final class TranscriptAgentsTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    private func stamp(_ seconds: TimeInterval, from start: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }

    func testAgentsComeFromTheRecordAndTheirOwnRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-agents-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("session.jsonl")
        let agents = folder.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 90).rounded(.down))

        let lines = [
            line(["type": "assistant", "cwd": "/Users/me/app", "timestamp": stamp(0, from: start), "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "call-bg", "name": "Agent", "input": ["description": "Diseñar el gato", "subagent_type": "general-purpose", "model": "sonnet", "prompt": "…", "run_in_background": true]],
                ["type": "tool_use", "id": "call-sync", "name": "Agent", "input": ["description": "Buscar el notch", "subagent_type": "Explore", "prompt": "…"]],
            ]]]),
            line(["type": "user", "timestamp": stamp(1, from: start), "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call-bg", "content": [["type": "text", "text": "Async agent launched successfully.\nagentId: abc123 (internal ID)"]]],
            ]]]),
            line(["type": "user", "timestamp": stamp(30, from: start), "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call-sync", "content": "Encontrado en NotchController.swift"],
            ]]]),
            line(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(40, from: start),
                  "content": "<task-notification><task-id>bash77</task-id><status>completed</status></task-notification>"]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)
        let own = [
            line(["type": "user", "isSidechain": true, "cwd": "/Users/me/app", "message": ["role": "user", "content": "Diseña el gato del notch"]]),
            line(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "usage": ["input_tokens": 200, "cache_read_input_tokens": 12_000, "output_tokens": 100],
                                                   "content": [["type": "text", "text": "Empiezo por las poses."],
                                                               ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/Users/me/app/Sources/Pet.swift"]]]]]),
        ]
        try (own.joined(separator: "\n") + "\n").write(to: agents.appendingPathComponent("agent-abc123.jsonl"), atomically: true, encoding: .utf8)

        let follower = TranscriptFollower(url: record)
        XCTAssertNotNil(follower.poll())
        var shown = follower.agents(now: start.addingTimeInterval(95))
        XCTAssertEqual(shown.map(\.name), ["Diseñar el gato", "Buscar el notch"])
        XCTAssertEqual(shown[0].state, .running, "A background agent keeps working after its launch answers.")
        XCTAssertTrue(shown[0].background)
        XCTAssertEqual(shown[0].model, "sonnet")
        XCTAssertEqual(shown[0].activity, "Read(Sources/Pet.swift)", "What it does now, from its own record.")
        XCTAssertEqual(shown[0].toolUses, 1)
        XCTAssertEqual(shown[0].tokens, "12.3k")
        XCTAssertEqual(shown[0].duration, "1m 35s")
        XCTAssertEqual(shown[1].state, .done, "A plain agent ends with its result.")
        XCTAssertEqual(shown[1].kind, "Explore")
        XCTAssertEqual(shown[1].duration, "30s")

        // The background agent's end arrives as a task notification (written twice, as Claude does).
        let handle = try FileHandle(forWritingTo: record)
        try handle.seekToEnd()
        let ended = line(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(100, from: start),
                          "content": "<task-notification>\n<task-id>abc123</task-id>\n<status>completed</status>\n</task-notification>"])
        try handle.write(contentsOf: Data((ended + "\n" + ended + "\n").utf8))
        try handle.close()
        _ = follower.poll()
        shown = follower.agents(now: start.addingTimeInterval(120))
        XCTAssertEqual(shown[0].state, .done)
        XCTAssertNil(shown[0].activity, "A finished agent is doing nothing.")
        XCTAssertEqual(shown[0].duration, "1m 40s", "Its time stops when it ends.")

        XCTAssertTrue(follower.agents(now: start.addingTimeInterval(800)).isEmpty, "Finished agents leave after ten minutes.")

        // Entering the agent's own conversation, like Claude's agent view.
        XCTAssertNil(follower.agentText(call: "call-sync"), "An agent without a record yet shows nothing.")
        let conversation = try XCTUnwrap(follower.agentText(call: "call-bg"))
        XCTAssertTrue(conversation.hasPrefix("> Diseña el gato del notch"), "Its task, as the main Claude wrote it.")
        XCTAssertTrue(conversation.contains("⏺ Empiezo por las poses."))
        XCTAssertTrue(conversation.contains("⏺ Read(Sources/Pet.swift)"))
        XCTAssertFalse(follower.renderer.text.contains("Empiezo por las poses"), "The main conversation never takes the agent's lines.")
        XCTAssertNil(follower.agentText(call: nil), "Back to the main conversation.")
    }

    func testTheMirrorSwitchesToAnAgentAndBack() {
        let rule = String(repeating: "─", count: 72)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys091", customTitle: "", processes: ["claude"], busy: true, selected: true,
                                      text: "⏺ en pantalla\n" + rule + "\n❯ \n" + rule)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil)
        session.view(agent: "call-bg")
        XCTAssertEqual(session.displayText, "", "Empty until the agent's record is read.")
        session.applyAgentText("> tarea del agente\n\n", call: "call-bg")
        XCTAssertEqual(session.displayText, "> tarea del agente\n\n")
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n> otra\n\n", recap: nil)
        session.update(tab)
        XCTAssertEqual(session.displayText, "> tarea del agente\n\n", "Claude's own updates wait while an agent is shown.")
        session.applyAgentText("> de otro agente\n\n", call: "otro")
        XCTAssertEqual(session.displayText, "> tarea del agente\n\n", "A late reading of another agent never shows.")
        session.view(agent: nil)
        XCTAssertEqual(session.displayText, "> pregunta\n\n⏺ respuesta\n\n> otra\n\n", "Back to Claude, up to date.")
    }

    func testAnAgentWithoutItsIdInTheResultIsFoundByItsMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-agents-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("s.jsonl")
        let agents = folder.appendingPathComponent("s/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (line(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "call-1", "name": "Agent", "input": ["description": "Revisar", "prompt": "…"]]]]]) + "\n")
            .write(to: record, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["toolUseId": "call-1", "agentType": "Explore"]).write(to: agents.appendingPathComponent("agent-zz9.meta.json"))
        try (line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "g", "name": "Grep", "input": ["pattern": "notch"]]]]]) + "\n")
            .write(to: agents.appendingPathComponent("agent-zz9.jsonl"), atomically: true, encoding: .utf8)
        let follower = TranscriptFollower(url: record)
        _ = follower.poll()
        XCTAssertEqual(follower.agents().first?.activity, "Grep(notch)")
    }

    func testCountsReadLikeClaudes() {
        XCTAssertEqual(SubagentWatch.tokens(950), "950")
        XCTAssertEqual(SubagentWatch.tokens(41_230), "41.2k")
        XCTAssertEqual(SubagentWatch.tokens(12_000), "12k")
        XCTAssertEqual(SubagentWatch.duration(45.9), "45s")
        XCTAssertEqual(SubagentWatch.duration(192), "3m 12s")
        XCTAssertEqual(SubagentWatch.duration(3840), "1h 4m")
    }

    /// Reads a real record when NOOK_REAL_RECORD points at one; prints its agents.
    func testARealRecordOnRequest() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOK_REAL_RECORD"] else { throw XCTSkip("Set NOOK_REAL_RECORD to read a real record.") }
        let follower = TranscriptFollower(url: URL(fileURLWithPath: path))
        _ = follower.poll()
        let all = follower.renderer.agents.launches
        print("launches:", all.count, "running:", all.filter { $0.state == .running }.map(\.name), "ids:", all.filter { $0.agentID != nil }.count)
        for agent in follower.agents() { print("·", agent.name, "|", agent.state, "|", agent.detail, "|", agent.activity ?? "—", "|", agent.model ?? "—") }
        if let change = follower.renderer.text.components(separatedBy: "\n\n").last(where: { $0.contains("  ⎿  Actualizado ") }) {
            print(change.components(separatedBy: "\n").prefix(14).joined(separator: "\n"))
        }
    }
}
