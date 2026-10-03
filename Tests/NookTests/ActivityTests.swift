import AppKit
import XCTest
@testable import Nook

final class ActivityTests: XCTestCase {
    func testOnlyActualAlertsTriggerBadgesIncludingSplitOSCSequences() {
        var parser = TerminalSignalParser()
        XCTAssertEqual(parser.feed(Array("\u{1b}]0;Claude Code\u{07}".utf8)[...]), [])
        XCTAssertEqual(parser.feed(Array("\u{1b}]9;Respuesta".utf8)[...]), [])
        XCTAssertEqual(parser.feed(Array(" lista\u{1b}".utf8)[...]), [])
        XCTAssertEqual(parser.feed(Array("\\".utf8)[...]), ["Respuesta lista"])
        XCTAssertEqual(parser.feed(Array("\u{1b}]9;4;1;50\u{07}".utf8)[...]), [])
        XCTAssertEqual(parser.feed([7][...]), ["La terminal solicita tu atención."])
    }

    func testHookMergePreservesOtherHooksAndIsIdempotentAndReversible() throws {
        let existing: [String: Any] = ["model": "existing", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "my-existing-hook"]]]], "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "other-hook"]]]]]]
        let command = "'/tmp/Nook helper' --claude-hook"
        let installed = ClaudeHooks.merging(existing, command: command, enabled: true)
        let twice = ClaudeHooks.merging(installed, command: command, enabled: true)
        func canonical(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
        XCTAssertEqual(try canonical(installed), try canonical(twice))
        XCTAssertEqual(try canonical(existing), try canonical(ClaudeHooks.merging(twice, command: command, enabled: false)))
    }

    func testSignalsDiscardPromptAndTranscriptAndKeepSourceIdentity() throws {
        let input = Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"session-1\",\"prompt\":\"PRIVATE PROMPT\",\"transcript_path\":\"PRIVATE PATH\"}".utf8)
        let signal = try XCTUnwrap(ClaudeSignal.fromHook(input, tty: "/dev/ttys003", environment: ["TMUX": "/tmp/test.sock,123,0", "TMUX_PANE": "%2"]))
        let encoded = String(decoding: try JSONEncoder().encode(signal), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"))
        XCTAssertEqual(signal.tty, "/dev/ttys003")
        XCTAssertEqual(signal.tmuxSocket, "/tmp/test.sock")
        XCTAssertEqual(signal.tmuxPane, "%2")
    }

    func testLocalSignalDeliveryIncludesTheCorrectTabAndWorksWithoutNetwork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-events-" + UUID().uuidString.prefix(8))
        let path = directory.appendingPathComponent("events.sock").path
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiver = ClaudeSignalReceiver(path: path)
        let received = expectation(description: "Local Claude event delivered")
        receiver.onEvent = { event in
            XCTAssertEqual(event.event, "Stop")
            XCTAssertEqual(event.tty, "/dev/ttys003")
            XCTAssertEqual(event.sessionID, "fixture-session")
            received.fulfill()
        }
        let signal = ClaudeSignal(event: "Stop", tty: "/dev/ttys003", sessionID: "fixture-session", message: "", notificationType: "", tmuxSocket: nil, tmuxPane: nil)
        LocalSignalSocket.send(signal, path: path)
        wait(for: [received], timeout: 2)
        withExtendedLifetime(receiver) {}
    }
}
