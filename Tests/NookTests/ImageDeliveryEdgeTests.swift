import XCTest
@testable import Nook

/// Edges around a message with images that the main suites leave out: byte limits with multi-byte text, other agents, shell mode,
/// and the guards of a burst of arrows.
@MainActor
final class ImageDeliveryEdgeTests: XCTestCase {
    private let shot = MessageAttachments.folder + "pantalla-20261008-092246.png"

    func testOnlyImagesNookAttachedForceThePaste() {
        XCTAssertTrue(TerminalAppBridge.typesDirectly("mira /tmp/a.png"), "A path the user typed stays typed.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(MessageAttachments.message(text: "mira", files: [shot]), agent: .claude))
        XCTAssertTrue(TerminalAppBridge.typesDirectly(MessageAttachments.message(text: "mira", files: [shot]), agent: .codex), "Codex keeps its way.")
        XCTAssertTrue(TerminalAppBridge.typesDirectly(MessageAttachments.message(text: "mira", files: [shot])), "Without an agent nothing changes.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(MessageAttachments.message(text: "ñandú 😀 útil", files: [shot]), agent: .claude), "Unicode words.")
    }

    func testTheTypedLimitCountsBytesNotCharacters() {
        XCTAssertTrue(TerminalAppBridge.typesDirectly(String(repeating: "x", count: 200)))
        XCTAssertFalse(TerminalAppBridge.typesDirectly(String(repeating: "x", count: 201)))
        XCTAssertTrue(TerminalAppBridge.typesDirectly(String(repeating: "ñ", count: 100)), "200 bytes")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(String(repeating: "ñ", count: 101)), "202 bytes: pasted")
    }

    func testAShellModeMessageWithAnImageKeepsItsBangAsAKeyBeforeThePaste() {
        let action = TerminalAppBridge.messageAction("!ls " + shot, agent: .claude)
        XCTAssertTrue(action.hasPrefix("do script (\"!\" & (character id 27) & \"[200~\""), action)
        XCTAssertTrue(action.contains("ls " + shot) && action.hasSuffix("\"[201~\") in t"), action)
        XCTAssertFalse(action.contains("!ls"), "The bang is not inside the paste.")
    }

    func testAnImageMessageWithLineBreaksAndUnicodeIsPastedWholeAndComesApart() {
        let text = "primera línea\nsegunda ñ 😀"
        let message = MessageAttachments.message(text: text, files: [shot])
        XCTAssertTrue(MessageAttachments.endsWithAttachments(message))
        XCTAssertEqual(MessageAttachments.parts(of: message).text, text)
        XCTAssertEqual(MessageAttachments.parts(of: message).files, [shot])
        let action = TerminalAppBridge.messageAction(message, agent: .claude)
        XCTAssertTrue(action.contains("[200~") && action.contains("\\n") && action.contains(shot), action)
    }

    func testAnImageOutsideNooksFolderIsNotAnAttachment() {
        XCTAssertFalse(MessageAttachments.endsWithAttachments("mira /Users/sample/Desktop/a.png"))
        XCTAssertFalse(MessageAttachments.endsWithAttachments("mira " + MessageAttachments.folder + "../../etc/a.txt"))
        XCTAssertFalse(MessageAttachments.endsWithAttachments(""))
    }

    func testTheLogExcerptNeverSplitsACharacterAndStaysShort() {
        let long = String(repeating: "😀ñ", count: 500)
        let cut = TerminalAppBridge.excerpt(long)
        XCTAssertLessThanOrEqual(cut.count, TerminalAppBridge.excerptLimit + 4)
        XCTAssertTrue(cut.contains(" … "))
        XCTAssertEqual(TerminalAppBridge.excerpt(""), "")
    }

    /// A page of arrows is only ↑ or ↓, between 1 and `burstLimit`: anything else sends nothing and says so.
    func testABurstOfArrowsRefusesOtherKeysAndOutOfRangeCounts() {
        let bridge = TerminalAppBridge()
        var scripts = 0
        bridge.runScript = { _ in scripts += 1 }
        bridge.postKey = { _, _ in scripts += 1 }
        bridge.directKeysAllowed = { true }
        bridge.terminalProcess = { 1 }
        var results: [KeyDelivery] = []
        bridge.press(.enter, count: 3, windowID: 1, tty: "/dev/ttys001") { results.append($0) }
        bridge.press(.down, count: TerminalAppBridge.burstLimit + 1, windowID: 1, tty: "/dev/ttys001") { results.append($0) }
        XCTAssertEqual(results, [.failed, .failed])
        XCTAssertEqual(scripts, 0)
    }

    func testASessionRefusesABurstOfAnythingButArrows() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-edge-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-edge-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        var results: [KeyDelivery] = []
        session.press(.enter, count: 5) { results.append($0) }
        session.press(.up, count: 0) { results.append($0) }
        session.press(.up, count: TerminalSession.burstLimit + 1) { results.append($0) }
        XCTAssertEqual(results, [.failed, .failed, .failed])
    }
}
