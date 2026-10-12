import XCTest
@testable import Nook

/// The real `--mcp-screen` process, as Claude Code starts it: only JSON-RPC lines on stdout, whatever it is sent. Never calls a tool that
/// would reach the running Nook's socket.
final class ScreenVisionHelperProcessTests: XCTestCase {
    private func executable() throws -> URL {
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nook")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else { throw XCTSkip("The Nook executable is not next to the test bundle.") }
        return sibling
    }

    func testStdoutCarriesOnlyOneJSONObjectPerReplyAndTheProcessEndsWithItsInput() throws {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = ["--mcp-screen"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
            "this is not json",
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            "   ",
            #"{"jsonrpc":"2.0","id":"x","method":"resources/list"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"capture_screen","arguments":{"display":"bogus"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"other"}}"#,
        ]
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        // initialize, parse error, tools/list, resources/list, bad display, unknown tool: no reply to the notification or the blank line.
        XCTAssertEqual(replies.count, 6, "\(replies)")
        let objects = try replies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any], $0) }
        XCTAssertTrue(objects.allSatisfy { $0["jsonrpc"] as? String == "2.0" })
        XCTAssertEqual((objects[0]["result"] as? [String: Any])?["protocolVersion"] as? String, ScreenVisionMCPServer.protocolVersions[0])
        XCTAssertEqual((objects[1]["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((objects[3]["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(objects[3]["id"] as? String, "x")
        XCTAssertEqual((objects[4]["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual((objects[5]["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
