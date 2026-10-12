import AppKit
import XCTest
@testable import Nook

/// The private socket between the tool's helper and the running Nook, on sockets of the tests' own (never the app's).
@MainActor
final class ScreenRelayTests: XCTestCase {
    private let sample = ScreenShot(path: "/tmp/nook-test/images/pantalla-20261007-140322.png", mimeType: "image/png", display: "Pantalla integrada",
                                    width: 1512, height: 982, date: ScreenVisionFixture.date)

    /// Runs `work` off the main thread (the helper's request blocks) while the main thread goes on serving, and returns its outcome.
    private func offMain<T>(_ timeout: TimeInterval = 5, _ work: @escaping () throws -> T) -> Result<T, Error>? {
        var outcome: Result<T, Error>?
        let lock = NSLock()
        DispatchQueue.global().async {
            let result = Result { try work() }
            lock.lock(); outcome = result; lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let done = outcome; lock.unlock()
            if let done { return done }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return nil
    }

    func testARequestAndItsAnswerCrossTheSocket() throws {
        let path = ScreenVisionFixture.socketPath()
        var received: ScreenRelay.Request?
        let server = try XCTUnwrap(ScreenRelayServer(path: path) { request, reply in received = request; reply(ScreenRelay.Response(shots: [self.sample])) })
        defer { server.stop() }
        XCTAssertEqual(ScreenVisionFixture.posixPermissions(path), 0o600, "Only the user can connect.")
        let shots = try XCTUnwrap(offMain { try ScreenRelay.request(ScreenRelay.Request(display: .main), path: path) }).get()
        XCTAssertEqual(shots, [sample], "Every field, the date included, arrives as it was sent.")
        XCTAssertEqual(received, ScreenRelay.Request(action: "capture", display: .main))
    }

    func testNooksRefusalArrivesInItsWords() throws {
        let path = ScreenVisionFixture.socketPath()
        let server = try XCTUnwrap(ScreenRelayServer(path: path) { _, reply in reply(ScreenRelay.Response(error: "La visión de pantalla está desactivada en Nook.")) })
        defer { server.stop() }
        let outcome = try XCTUnwrap(offMain { try ScreenRelay.request(ScreenRelay.Request(), path: path) })
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(error as? ScreenRelay.Failure, .refused("La visión de pantalla está desactivada en Nook."))
            XCTAssertEqual(error.localizedDescription, "La visión de pantalla está desactivada en Nook.")
        }
    }

    func testWithoutNookTheHelperSaysSo() {
        let path = ScreenVisionFixture.socketPath()
        XCTAssertThrowsError(try ScreenRelay.request(ScreenRelay.Request(), path: path, timeout: 1)) { error in
            XCTAssertEqual(error as? ScreenRelay.Failure, .notRunning)
            XCTAssertEqual(error.localizedDescription, "Nook no está abierto. Ábrelo y activa la visión de pantalla en sus ajustes para que Claude pueda ver tu pantalla.")
        }
    }

    func testAnAnswerThatNeverComesEndsInATimeout() throws {
        let path = ScreenVisionFixture.socketPath()
        // Nook's side gives up first and says so.
        let server = try XCTUnwrap(ScreenRelayServer(path: path, replyTimeout: 0.3) { _, _ in })
        defer { server.stop() }
        let outcome = try XCTUnwrap(offMain { try ScreenRelay.request(ScreenRelay.Request(), path: path, timeout: 3) })
        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ScreenRelay.Failure, .refused("Nook no respondió a tiempo con la captura de pantalla.")) }
        // And when even that does not come, the helper stops waiting on its own.
        let silent = ScreenVisionFixture.socketPath()
        let mute = try XCTUnwrap(ScreenRelayServer(path: silent, replyTimeout: 30) { _, _ in })
        defer { mute.stop() }
        let started = Date()
        let late = try XCTUnwrap(offMain { try ScreenRelay.request(ScreenRelay.Request(), path: silent, timeout: 0.4) })
        XCTAssertThrowsError(try late.get()) { XCTAssertEqual($0 as? ScreenRelay.Failure, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testAStoppedServerTakesItsSocketAway() throws {
        let path = ScreenVisionFixture.socketPath()
        let server = try XCTUnwrap(ScreenRelayServer(path: path) { _, reply in reply(ScreenRelay.Response(shots: [])) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try ScreenRelay.request(ScreenRelay.Request(), path: path, timeout: 1)) { XCTAssertEqual($0 as? ScreenRelay.Failure, .notRunning) }
    }

    // MARK: End to end: Claude's tool, the socket, Nook's capture

    func testClaudesToolGetsAScreenshotFromNookThroughTheSocket() throws {
        let folder = try ScreenVisionFixture.folder()
        let path = ScreenVisionFixture.socketPath()
        let capturer = FakeScreenCapturer()
        let vision = ScreenVision(defaults: ScreenVisionFixture.defaults(), capturer: capturer, registrar: FakeRegistrar(), folder: folder, relayPath: path,
                                  ownPID: 4242, timeout: 2, now: { ScreenVisionFixture.date })
        vision.enabled = true
        vision.start(serving: true)
        let tool = ScreenVisionMCPServer(capture: { try ScreenRelay.request(ScreenRelay.Request(display: $0), path: path, timeout: 5) }, folder: folder.path)
        let line = try XCTUnwrap(offMain { tool.reply(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_screen","arguments":{"display":"main"}}}"#) }?.get())
        let line2 = try XCTUnwrap(line)
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line2.utf8)) as? [String: Any])
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let saved = folder.appendingPathComponent("pantalla-20261007-140322.png")
        XCTAssertEqual(Data(base64Encoded: content[1]["data"] as? String ?? ""), try Data(contentsOf: saved))
        XCTAssertEqual(capturer.calls.map(\.choice), [.main])
        XCTAssertEqual(capturer.calls.first?.pid, 4242)
        XCTAssertEqual(vision.lastCapture?.origin, .claude, "The island can say Claude looked.")

        // Off in Nook: Claude is told, and nothing is captured.
        vision.enabled = false
        let refused = try XCTUnwrap(offMain { tool.reply(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screen","arguments":{}}}"#) }?.get())
        let refusal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(refused).utf8)) as? [String: Any])
        let text = ((refusal["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(text, ScreenVisionError.disabled.localizedDescription)
        XCTAssertEqual(capturer.calls.count, 1)
    }
}
