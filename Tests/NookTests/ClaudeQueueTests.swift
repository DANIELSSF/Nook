import XCTest
@testable import Nook

/// A message sent while Claude works waits in Claude's queue (grey in its terminal) until Claude takes it, as a turn of its own
/// or in the middle of the current one. Claude's record says both, so Nook shows the message as queued and then as sent.
final class ClaudeQueueTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    private func operation(_ name: String, _ content: String? = nil, reason: String? = nil) -> String {
        var entry: [String: Any] = ["type": "queue-operation", "operation": name]
        if let content { entry["content"] = content }
        if let reason { entry["reason"] = reason }
        return line(entry)
    }
    private func taken(_ prompt: Any, mode: String = "prompt", origin: String? = "human") -> String {
        var attachment: [String: Any] = ["type": "queued_command", "prompt": prompt, "commandMode": mode]
        if let origin { attachment["origin"] = ["kind": origin] }
        return line(["type": "attachment", "attachment": attachment])
    }

    func testTheRecordKeepsClaudesQueueAndShowsWhatItTookMidTurn() {
        var renderer = TranscriptRenderer()
        [operation("enqueue", "primero"), operation("enqueue", "segundo")].forEach { renderer.consume($0) }
        XCTAssertEqual(renderer.queued, ["primero", "segundo"])
        // Taken in the middle of Claude's turn: out of the queue and into the conversation as the user's.
        [operation("remove", "primero", reason: "absorbed_mid_turn"), taken("primero")].forEach { renderer.consume($0) }
        XCTAssertEqual(renderer.queued, ["segundo"])
        XCTAssertEqual(renderer.text, "> primero\n\n")
        // A turn of its own: dequeued, then recorded as an ordinary prompt.
        renderer.consume(operation("dequeue"))
        XCTAssertEqual(renderer.queued, [])
        // Pulled back into the box with ↑: gone from the queue, never sent.
        [operation("enqueue", "tercero"), operation("popAll")].forEach { renderer.consume($0) }
        XCTAssertEqual(renderer.queued, [])
    }

    func testOnlyTheUsersQueuedMessagesJoinTheConversation() {
        var renderer = TranscriptRenderer()
        [taken("<task-notification>listo</task-notification>", mode: "task-notification", origin: nil),
         taken("<cross-session-message from=\"x\">hola</cross-session-message>", origin: "peer"),
         taken([["type": "text", "text": "mira esto"], ["type": "image", "source": [:]]]),
         taken("de una versión sin origen", origin: nil)].forEach { renderer.consume($0) }
        XCTAssertEqual(renderer.text, "> mira esto\n\n> [Imagen]\n\n> de una versión sin origen\n\n")
    }

    func testThePendingMessageStaysQueuedUntilClaudeTakesIt() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-queue-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-queue-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        let working = "⏺ Revisando.\n\n✶ Warping… (3s · esc to interrupt)"
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: working)
        session.applyTranscript("> revisa\n\n⏺ Revisando.\n\n", recap: nil, queued: [])

        session.showPending("y el notch")
        session.applyTranscript(nil, recap: nil, queued: ["<task-notification>x</task-notification>", "y el notch"])
        XCTAssertEqual(session.claudeQueue, ["y el notch"], "Only the user's messages are shown as queued.")
        XCTAssertTrue(session.pendingQueued)
        // Its grey echo on screen is not an arrival.
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: working + "\n\n❯ y el notch")
        XCTAssertEqual(session.pendingMessage, "y el notch")

        // Claude takes it: the record has it, the placeholder goes.
        session.applyTranscript("> revisa\n\n⏺ Revisando.\n\n> y el notch\n\n", recap: nil, queued: [])
        XCTAssertNil(session.pendingMessage)
        XCTAssertFalse(session.pendingQueued)
    }

    func testEffortReadsClaudesLongerSpinnerWording() {
        XCTAssertEqual(ClaudeEffort.reported(in: "✢ Choreographing… (23s · thinking more with xhigh effort)"), .xhigh)
    }
}
