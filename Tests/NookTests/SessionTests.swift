import XCTest
import AppKit
@testable import Nook

final class SessionTests: XCTestCase {
    func testShellQuotePreservesApostrophesAndCommandCharacters() {
        XCTAssertEqual(Shell.quote("a'b; $(touch /tmp/nope)"), "'a'\\''b; $(touch /tmp/nope)'")
    }

    func testShellQuoteRoundTripsLiteralContent() throws {
        let input = "gato's folder; $(printf WRONG) `printf WRONG`\n¡Hola!"
        let result = try Shell.run("/bin/zsh", ["-f", "-c", "printf '%s' " + Shell.quote(input)])
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1, input)
    }

    func testNotchGeometryUsesActualScreenCoordinates() {
        let screen = CGRect(x: 1600, y: -200, width: 1512, height: 982)
        let left = CGRect(x: 1600, y: 750, width: 660, height: 32)
        let right = CGRect(x: 2452, y: 750, width: 660, height: 32)
        let frame = NotchGeometry.idleFrame(screen: screen, left: left, right: right, topInset: 32)
        XCTAssertEqual(frame.minX, 2230)
        XCTAssertEqual(frame.midX, 2356)
        XCTAssertEqual(frame.maxY, screen.maxY)
    }

    func testScreenWithoutNotchHasCenteredFallback() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NotchGeometry.idleFrame(screen: screen, left: nil, right: nil, topInset: 0)
        XCTAssertEqual(frame.midX, 960)
        XCTAssertEqual(frame.height, 28)
        XCTAssertEqual(frame.maxY, 1080)
    }

    func testExpandedIslandRemainsCompactAndAttachedToTheScreenEdge() {
        let screen = CGRect(x: 1600, y: -200, width: 1512, height: 982)
        let frame = NotchGeometry.expandedFrame(screen: screen, centerX: screen.midX, topInset: 32)
        XCTAssertEqual(frame.width, 572)
        XCTAssertEqual(frame.height, 266)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.maxY, screen.maxY)
    }

    func testBundledConfigurationCopiesMouseSelectionsToTheClipboard() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("Vendor/bin/tmux").path
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Compila el tmux incluido primero.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nook-copy-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let args = ["-S", temporary.appendingPathComponent("s").path, "-f", root.appendingPathComponent("Resources/tmux.conf").path]
        defer { _ = try? Shell.run(binary, args + ["kill-server"]) }
        XCTAssertEqual(try Shell.run(binary, args + ["new-session", "-d", "-s", "copy", "/bin/zsh -f"]).0, 0)
        XCTAssertEqual(try Shell.run(binary, args + ["show-options", "-gv", "copy-command"]).1.trimmingCharacters(in: .whitespacesAndNewlines), "pbcopy")
        XCTAssertEqual(try Shell.run(binary, args + ["show-options", "-gv", "mouse"]).1.trimmingCharacters(in: .whitespacesAndNewlines), "on")
    }

    func testSharedSessionAcceptsInputFromTwoClientsAndPersists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("Vendor/bin/tmux").path
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Compila el tmux incluido primero.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nook-test-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let args = ["-S", temporary.appendingPathComponent("s").path, "-f", root.appendingPathComponent("Resources/tmux.conf").path]
        defer { _ = try? Shell.run(binary, args + ["kill-server"]) }
        let created = try Shell.run(binary, args + ["new-session", "-d", "-s", "shared", "/bin/zsh -f"])
        guard created.0 == 0 else { XCTFail("No se pudo iniciar la sesión de prueba: \(created.1)"); return }

        func client() throws -> (Process, Pipe) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args + ["-C", "attach-session", "-t", "=shared"]
            let input = Pipe(); let output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            // Control clients have bounded output here, so pipes cannot fill.
            return (process, input)
        }
        let (first, firstInput) = try client()
        let (second, secondInput) = try client()
        defer { if first.isRunning { first.terminate() }; if second.isRunning { second.terminate() } }
        firstInput.fileHandleForWriting.write(Data("send-keys -t shared:0.0 -l 'export NOOK_TEST_TOKEN=shared_state; print READY_FIRST'\nsend-keys -t shared:0.0 Enter\n".utf8))
        let readyDeadline = Date().addingTimeInterval(3)
        while Date() < readyDeadline {
            let content = try Shell.run(binary, args + ["capture-pane", "-p", "-t", "shared:0.0"]).1
            if content.contains("\nREADY_FIRST\n") { break }
            Thread.sleep(forTimeInterval: 0.04)
        }
        let token = UUID().uuidString
        secondInput.fileHandleForWriting.write(Data("send-keys -t shared:0.0 -l 'print -r -- VALUE:${NOOK_TEST_TOKEN}:\(token)'\nsend-keys -t shared:0.0 Enter\n".utf8))
        var capture = ""
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            capture = try Shell.run(binary, args + ["capture-pane", "-p", "-t", "shared:0.0"]).1
            if capture.contains("VALUE:shared_state:") { break }
            Thread.sleep(forTimeInterval: 0.04)
        }
        XCTAssertTrue(capture.contains("VALUE:shared_state:"), capture)
        firstInput.fileHandleForWriting.write(Data("detach-client\n".utf8))
        secondInput.fileHandleForWriting.write(Data("detach-client\n".utf8))
        let persisted = try Shell.run(binary, args + ["has-session", "-t", "=shared"])
        XCTAssertEqual(persisted.0, 0)
    }
}
