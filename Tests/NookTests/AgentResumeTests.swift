import XCTest
@testable import Nook

/// An agent that finished and was sent another message works again. Sample's session (2026-10-06, Claude Code 2.1.29x)
/// launched "UI phase A" as a ui-designer agent at 14:45, got its notification at 15:36, and woke it up with SendMessage many
/// times since ("Resuming agent a69c09b", "resumedAgentId"); each run writes on to the same subagents/agent-<id>.jsonl and ends
/// with another notification for the same task id. The launch was also more than 3 MB back, outside what Nook reads of the
/// record. The fixtures below are that flow, trimmed to its shape.
final class AgentResumeTests: XCTestCase {
    private let agentID = "a69c09b0ffdeb33c7"
    private let launchCall = "toolu_01SXaPqvhw3zadK3kHdCe9gt"
    private let task = "UI phase A: banner, warnings, mode, waiting"

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func launch(at date: Date) -> [String] {
        [line(["type": "assistant", "timestamp": stamp(date), "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": launchCall, "name": "Agent", "input": ["description": task, "subagent_type": "ui-designer", "prompt": "…", "run_in_background": "true"]]]]]),
         line(["type": "user", "timestamp": stamp(date.addingTimeInterval(1)), "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": launchCall, "content": [
            ["type": "text", "text": "Async agent launched successfully.\nagentId: \(agentID) (internal ID - do not mention to user.)\nThe agent is working in the background."]]]]]])]
    }

    /// The three lines Claude writes for one notification: the queue's enqueue and remove, and the attachment.
    private func finished(at date: Date) -> [String] {
        let content = "<task-notification>\n<task-id>\(agentID)</task-id>\n<tool-use-id>\(launchCall)</tool-use-id>\n<status>completed</status>\n<summary>Agent \"\(task)\" finished</summary>\n</task-notification>"
        return [line(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(date), "content": content]),
                line(["type": "queue-operation", "operation": "remove", "timestamp": stamp(date.addingTimeInterval(8)), "content": content]),
                line(["type": "attachment", "timestamp": stamp(date), "attachment": ["type": "queued_command", "prompt": content, "commandMode": "task-notification"]])]
    }

    private func resumed(at date: Date, call: String) -> [String] {
        let reply = "{\"success\":true,\"message\":\"Resuming agent a69c09b\",\"resumedAgentId\":\"\(agentID)\",\"pin\":{\"id\":\"\(agentID)\",\"name\":\"\(agentID)\",\"ref\":\"04cc94\"}}"
        return [line(["type": "assistant", "timestamp": stamp(date), "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": call, "name": "SendMessage", "input": ["to": agentID, "summary": "UI: model chip", "message": "…"]]]]]),
                line(["type": "user", "timestamp": stamp(date.addingTimeInterval(1)), "toolUseResult": ["success": true, "message": "Resuming agent a69c09b", "resumedAgentId": agentID],
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": call, "content": [["type": "text", "text": reply]]]]]])]
    }

    /// A message queued to an agent that is still running: not a resume.
    private func queued(at date: Date, call: String) -> [String] {
        let reply = "{\"success\":true,\"message\":\"Message queued for delivery to \(agentID) at its next tool round.\",\"pin\":{\"id\":\"\(agentID)\"}}"
        return [line(["type": "assistant", "timestamp": stamp(date), "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": call, "name": "SendMessage", "input": ["to": agentID, "message": "…"]]]]]),
                line(["type": "user", "timestamp": stamp(date.addingTimeInterval(1)), "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": call, "content": [["type": "text", "text": reply]]]]]])]
    }

    private func session(_ lines: [String]) throws -> (TranscriptFollower, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-resume-\(UUID().uuidString.prefix(8))")
        let agents = folder.appendingPathComponent("11453b18/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let record = folder.appendingPathComponent("11453b18.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["agentType": "ui-designer", "description": task, "toolUseId": launchCall, "requestShape": "background"]
        try JSONSerialization.data(withJSONObject: meta).write(to: agents.appendingPathComponent("agent-\(agentID).meta.json"))
        let own = [line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": "Project: Nook…"]]),
                   line(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "usage": ["input_tokens": 10, "cache_read_input_tokens": 305_000, "output_tokens": 700],
                        "content": [["type": "text", "text": "Leo las pruebas de la tarjeta."], ["type": "tool_use", "id": "toolu_read", "name": "Read", "input": ["file_path": "/tmp/PromptCardTests.swift"]]]]])]
        try (own.joined(separator: "\n") + "\n").write(to: agents.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return (TranscriptFollower(url: record), folder)
    }

    // MARK: - The record

    func testAResumedAgentRunsAgainUntilItsNextNotification() throws {
        let start = Date().addingTimeInterval(-3 * 3600)
        let resumeAt = Date().addingTimeInterval(-346)
        var lines = launch(at: start) + finished(at: start.addingTimeInterval(3000))
        lines += queued(at: start.addingTimeInterval(100), call: "toolu_queued")
        lines += resumed(at: resumeAt, call: "toolu_01JEfnFy")
        let (follower, _) = try session(lines)
        _ = follower.poll()
        let shown = try XCTUnwrap(follower.agents().first)
        XCTAssertEqual(shown.id, launchCall, "The launch's own id: the row opens its record.")
        XCTAssertEqual(shown.state, .running)
        XCTAssertEqual(shown.kind, "ui-designer")
        XCTAssertTrue(["5m 45s", "5m 46s"].contains(shown.duration ?? ""), "The time of this run, not since the first launch: \(shown.duration ?? "nil")")
        XCTAssertEqual(shown.tokens, "305.7k")
        XCTAssertEqual(shown.activity, "Read(/tmp/PromptCardTests.swift)")
        XCTAssertNotNil(follower.agentRecord(call: shown.id))
        XCTAssertEqual(follower.agentText(call: shown.id)?.contains("Leo las pruebas de la tarjeta."), true, "Clicking it shows its conversation.")
        // Its next notification ends it again.
        let more = finished(at: Date().addingTimeInterval(-10)).joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: follower.url); try handle.seekToEnd(); try handle.write(contentsOf: Data(more.utf8)); try handle.close()
        _ = follower.poll()
        XCTAssertEqual(follower.agents().first?.state, .done)
    }

    func testAResumeOfAnAgentLaunchedBeforeWhatWasReadNamesItFromItsMetadata() throws {
        // Only the resume is in the record Nook read; the launch and the first notification are older.
        let (follower, _) = try session(resumed(at: Date().addingTimeInterval(-30), call: "toolu_01JEfnFy"))
        _ = follower.poll()
        let shown = try XCTUnwrap(follower.agents().first)
        XCTAssertEqual(shown.id, "agent:" + agentID)
        XCTAssertEqual(shown.name, task)
        XCTAssertEqual(shown.kind, "ui-designer")
        XCTAssertEqual(shown.state, .running)
        XCTAssertEqual(shown.activity, "Read(/tmp/PromptCardTests.swift)")
        XCTAssertEqual(follower.agentText(call: shown.id)?.contains("Leo las pruebas de la tarjeta."), true)
        XCTAssertNil(follower.agentRecord(call: "agent:../x"), "An id never walks out of the agents' folder.")
    }

    func testAnAgentWhoseRecordGrowsIsShownEvenWithoutItsResume() throws {
        // Launch, notification and resume all older than what was read; its record keeps being written.
        let (follower, folder) = try session([line(["type": "user", "timestamp": stamp(Date()), "message": ["role": "user", "content": "sigue"]])])
        _ = follower.poll()
        XCTAssertEqual(follower.agents().map(\.id), ["agent:" + agentID])
        XCTAssertEqual(follower.agents().first?.kind, "ui-designer")
        // Quiet for longer than the window: not running any more.
        let own = folder.appendingPathComponent("11453b18/subagents/agent-\(agentID).jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: own.path)
        XCTAssertEqual(follower.agents(), [])
    }

    func testANotificationAfterTheLastWriteEndsAnAgentTheRecordNeverLaunched() throws {
        let (follower, _) = try session(finished(at: Date().addingTimeInterval(5)))
        _ = follower.poll()
        XCTAssertEqual(follower.agents(), [], "It finished after its record last grew.")
    }

    func testTheResumeSignalItself() {
        var agents = TranscriptAgents()
        agents.result(call: "x", text: "{\"success\":true,\"message\":\"Message queued for delivery to \(agentID) at its next tool round.\"}", error: false, at: Date())
        XCTAssertEqual(agents.launches.count, 0, "A message queued to a running agent wakes nothing.")
        agents.result(call: "x", text: "{\"resumedAgentId\":\"\(agentID)\"}", error: true, at: Date())
        XCTAssertEqual(agents.launches.count, 0, "A failed SendMessage resumes nothing.")
        agents.launch(call: "fork-call", input: ["description": "L3 logic", "subagent_type": "fork", "run_in_background": "true", "name": "l3"], at: Date())
        XCTAssertEqual(agents.launches.first?.background, true, "\"true\" as a string is background too.")
        XCTAssertEqual(agents.launches.first?.alias, "l3")
    }

    // MARK: - The list under the mode line opens the record's agent

    func testARowOfTheListTakesTheAgentTheRecordThinksFinished() throws {
        let record = [SubagentActivity(id: launchCall, name: task, kind: "ui-designer", state: .done, background: true),
                      SubagentActivity(id: "older", name: "Explore the notch", kind: "Explore", state: .done)]
        let tree = try XCTUnwrap(AgentActivity.tree(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage", "", "  ⏺ main",
                                                     "  ✻ ui-designer  Reading PromptCardTests.swift for idioms  305.7k tokens · 5m 46s"].joined(separator: "\n")))
        let merged = AgentActivity.merged(record, tree: tree)
        XCTAssertEqual(merged.count, 2, "The row is the record's agent, not a third one.")
        XCTAssertEqual(merged[0].id, launchCall, "Its id is the record's, so a click opens its conversation.")
        XCTAssertEqual(merged[0].state, .running, "The list is live.")
        XCTAssertEqual(merged[0].activity, "Reading PromptCardTests.swift for idioms")
        XCTAssertEqual(merged[1].state, .done)
    }

    func testTheNewestOfSeveralFinishedAgentsOfThatTypeIsTheOne() throws {
        let record = ["first", "second"].map { SubagentActivity(id: $0, name: "UI \($0)", kind: "ui-designer", state: .done) }
        let tree = AgentActivity.tree(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", "", "  ⏺ main", "  ◯ ui-designer  Editing PanelView.swift  2m 1s"].joined(separator: "\n"))
        XCTAssertEqual(AgentActivity.merged(record, tree: tree).map(\.state), [.done, .running])
    }

    func testANamedAgentAndAForkBothMatchTheirRows() throws {
        var named = SubagentActivity(id: "call-named", name: "Design the review card", kind: "general-purpose", state: .running)
        named.alias = "designer"
        let fork = SubagentActivity(id: "call-fork", name: "L3 logic: prompts", kind: "fork", state: .running)
        let tree = AgentActivity.tree(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", "", "  ⏺ main",
                                       "  ○ fork  Reading AgentPrompt.swift  1m 2s · ↓ 90k tokens", "  ○ designer  Drawing the card  40s · ↓ 12k tokens"].joined(separator: "\n"))
        let merged = AgentActivity.merged([named, fork], tree: tree)
        XCTAssertEqual(merged.map(\.id), ["call-named", "call-fork"])
        XCTAssertEqual(merged.map(\.activity), ["Drawing the card", "Reading AgentPrompt.swift"])
    }

    func testARowWithNoRecordBehindItStaysAsItWas() throws {
        let tree = try XCTUnwrap(AgentActivity.tree(["  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", "", "  ⏺ main", "  ○ coder  Reading ContactList  1m 51s"].joined(separator: "\n")))
        let merged = AgentActivity.merged([SubagentActivity(id: "x", name: "Explore the notch", kind: "Explore", state: .done)], tree: tree)
        XCTAssertEqual(merged.map(\.id), ["x", "tree:0"])
        XCTAssertEqual(merged[0].state, .done)
    }
}
