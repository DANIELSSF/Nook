import XCTest
@testable import Nook

/// The island's composer and the phone (Nook Remote) send a message the same way (`AppModel.sendMessage`): this is what the island
/// did on its own before, step by step, and the screenshots it now remembers for the phone.
@MainActor
final class SharedSendPathTests: XCTestCase {
    private func outcome(_ model: AppModel, _ text: String, files: [String] = [], to session: TerminalSession) -> AppModel.MessageOutcome? {
        var result: AppModel.MessageOutcome?
        model.sendMessage(text, files: files, to: session) { result = $0 }
        RemoteFixture.waitUntil { result != nil }
        return result
    }

    func testAMessageJoinsTheHistoryShowsAtOnceAndGoes() {
        let (model, session, _) = RemoteFixture.model()
        var held: ((Bool) -> Void)?
        var delivered: [String] = []
        model.messageSender = { text, _, done in delivered.append(text); held = done }
        let image = MessageAttachments.folder + "imagen-20261105-090000.png"
        var result: AppModel.MessageOutcome?
        model.sendMessage("mira esto", files: [image], to: session) { result = $0 }
        XCTAssertEqual(delivered, ["mira esto " + image], "The words, then the attached image's path.")
        XCTAssertEqual(session.sentHistory.last, "mira esto " + image, "The history keeps what was written and attached.")
        XCTAssertEqual(session.pendingMessage, "mira esto " + image, "The conversation shows it while it goes.")
        XCTAssertNil(result, "Not done until the terminal says.")
        held?(true)
        XCTAssertEqual(result, .delivered)
        XCTAssertNotNil(session.pendingMessage, "Delivered: it stays until Claude's record has it.")
        XCTAssertTrue(model.sentShots(for: session).isEmpty, "No picture of the screen went.")
    }

    func testAMessageThatDidNotGoLeavesNoPlaceholder() {
        let (model, session, _) = RemoteFixture.model()
        model.messageSender = { _, _, done in done(false) }
        XCTAssertEqual(outcome(model, "hola", to: session), .notDelivered)
        XCTAssertNil(session.pendingMessage)
        XCTAssertEqual(session.sentHistory.last, "hola", "It was written: ↑ brings it back.")
        XCTAssertEqual(session.draft, "", "Where it goes back is the composer's to say: the model leaves the island's field alone.")
    }

    func testAShellInATerminalTabShowsItsMessageToo() {
        let (model, _, _) = RemoteFixture.model()
        let shell = TerminalSession(tab: RemoteFixture.tab("$ ls", tty: "/dev/ttys043", processes: ["login", "-zsh"]), backend: .bundled, bridge: model.terminalBridge)
        XCTAssertTrue(shell.mirrorsAgent, "Nook mirrors every Terminal tab's text, a shell's included.")
        XCTAssertEqual(outcome(model, "ls", to: shell), .delivered)
        XCTAssertEqual(shell.pendingMessage, "ls", "So the message shows in it while it goes, as before.")
    }

    func testThePictureOfTheScreenGoesLastAndIsRemembered() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        let image = MessageAttachments.folder + "imagen-20261105-090000.png"
        XCTAssertEqual(outcome(model, "¿qué ves?", files: [image], to: session), .delivered)
        let sent = try XCTUnwrap(recorder.all("message").first)
        let parts = MessageAttachments.parts(of: sent)
        XCTAssertEqual(parts.text, "¿qué ves?")
        XCTAssertEqual(parts.files.count, 2)
        XCTAssertEqual(parts.files.first, image, "The attached image first, the screen after it.")
        XCTAssertTrue((parts.files[1] as NSString).lastPathComponent.hasPrefix("pantalla-"))
        XCTAssertEqual(session.sentHistory.last, "¿qué ves? " + image, "Sending it again takes a new picture: the history has none.")
        let shots = model.sentShots(for: session)
        XCTAssertEqual(shots.map(\.text), ["¿qué ves?"], "The words that went with it, without any path.")
        XCTAssertEqual(shots.first?.path, parts.files[1])
        XCTAssertEqual(shots.first?.date, ScreenVisionFixture.date, "When it was taken.")
        XCTAssertEqual(model.sentShot(named: shots[0].name), shots[0])
        XCTAssertNil(model.sentShot(named: "pantalla-20990101-000000.png"))
        XCTAssertEqual(capturer.calls.count, 1)
    }

    func testTheScreenshotAloneLeavesTheHistoryAsItWas() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        XCTAssertEqual(outcome(model, "", to: session), .delivered)
        let sent = try XCTUnwrap(recorder.all("message").first)
        XCTAssertEqual(MessageAttachments.parts(of: sent).files, [sent], "The screenshot's path, and nothing else.")
        XCTAssertTrue(session.sentHistory.isEmpty, "Nothing empty for ↑ to bring back.")
        XCTAssertEqual(session.pendingMessage, sent, "It shows in the conversation while it goes, as [Image #1].")
        // The island's own messages are remembered as always.
        XCTAssertEqual(outcome(model, "¿qué ves?", to: session), .delivered)
        XCTAssertEqual(session.sentHistory, ["¿qué ves?"])
        XCTAssertEqual(capturer.calls.count, 2)
    }

    func testCommandsNeverCarryTheScreen() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        XCTAssertEqual(outcome(model, "/model", to: session), .delivered)
        XCTAssertEqual(outcome(model, "!ls", to: session), .delivered)
        XCTAssertEqual(recorder.all("message"), ["/model", "!ls"])
        XCTAssertTrue(capturer.calls.isEmpty)
    }

    func testAFailedPictureSendsNothing() throws {
        let capturer = FakeScreenCapturer(.failure(ScreenVisionError.failed("sin pantalla.")))
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        guard case .screenFailed(let notice)? = outcome(model, "mira", to: session) else { return XCTFail() }
        XCTAssertEqual(notice, ScreenVision.notSent(because: ScreenVisionError.failed("sin pantalla.")))
        XCTAssertTrue(recorder.all("message").isEmpty, "Without the picture Claude would not see the screen: nothing went.")
        XCTAssertNil(session.pendingMessage)
        XCTAssertTrue(session.sentHistory.isEmpty)
    }

    func testTheIslandsSendGoesThroughTheSharedPath() throws {
        // The island's composer calls the model's send and keeps only what is its own (its field, its pictures): no copy of the steps.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/NookTests/SharedSendPathTests.swift", with: "Sources/Nook/PanelView.swift"), encoding: .utf8)
        let send = try XCTUnwrap(source.range(of: "    private func send() {")).upperBound
        let body = String(source[send...].prefix(4000))
        XCTAssertTrue(body.contains("model.sendMessage(sentText, files: sentFiles, to: session)"))
        XCTAssertFalse(body.contains("prepareMessage"), "The screen is the shared path's.")
        XCTAssertFalse(body.contains("session.send("), "Delivery is the shared path's.")
    }
}
