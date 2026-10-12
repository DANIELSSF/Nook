import AppKit
import XCTest
@testable import Nook

/// The `capture_screen` MCP server as Claude Code talks to it: JSON-RPC lines in, lines out, with Nook's side replaced by a fake.
final class ScreenVisionMCPTests: XCTestCase {
    private var folder: URL!
    private var asked: [ScreenDisplayChoice] = []

    override func setUpWithError() throws {
        folder = try ScreenVisionFixture.folder()
        try ScreenShotFile.prepare(folder)
        asked = []
    }

    /// A screenshot file in the folder, as Nook would have saved it.
    private func shot(_ name: String = "pantalla-20261007-140322.png", display: String = "Pantalla integrada") throws -> ScreenShot {
        let encoded = try XCTUnwrap(ScreenShotFile.encode(ScreenVisionFixture.image(width: 320, height: 200)))
        let url = folder.appendingPathComponent(name)
        try encoded.data.write(to: url)
        return ScreenShot(path: url.path, mimeType: encoded.mimeType, display: display, width: 320, height: 200, date: ScreenVisionFixture.date)
    }

    private func server(_ capture: @escaping (ScreenDisplayChoice) throws -> [ScreenShot]) -> ScreenVisionMCPServer {
        ScreenVisionMCPServer(capture: { [unowned self] choice in self.asked.append(choice); return try capture(choice) }, folder: folder.path)
    }

    /// The reply to one message, as a dictionary (and checked to be a single line, as stdio requires).
    private func reply(_ server: ScreenVisionMCPServer, _ message: String) throws -> [String: Any]? {
        guard let line = server.reply(to: message) else { return nil }
        XCTAssertFalse(line.contains("\n"), "One message per line.")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func call(_ arguments: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"capture_screen","arguments":\#(arguments)}}"#
    }

    // MARK: The handshake

    func testInitializeAnswersInTheClientsVersionWhenItKnowsIt() throws {
        let server = server { _ in [] }
        let answer = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.292"}}}"#))
        XCTAssertEqual(answer["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(answer["id"] as? Int, 0)
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "nook-screen")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any], "It offers tools, and nothing else.")
        XCTAssertNil((result["capabilities"] as? [String: Any])?["resources"])

        let older = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#))
        XCTAssertEqual((older["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
        let unknown = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, ScreenVisionMCPServer.protocolVersions[0], "Otherwise its newest.")
    }

    func testNotificationsGetNoReplyAndPingGetsAnEmptyOne() throws {
        let server = server { _ in [] }
        XCTAssertNil(server.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.reply(to: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        XCTAssertNil(server.reply(to: #"{"jsonrpc":"2.0","method":"something/unknown"}"#), "A notification never gets an answer, not even an error.")
        XCTAssertNil(server.reply(to: ""), "A blank line is nothing.")
        XCTAssertNil(server.reply(to: #"{"jsonrpc":"2.0","id":5,"result":{}}"#), "A response to nothing asked is dropped.")
        let ping = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#))
        XCTAssertEqual(ping["id"] as? String, "p-1", "The id comes back as it was sent, string or number.")
        XCTAssertEqual((ping["result"] as? [String: Any])?.count, 0)
    }

    func testTheOneToolIsDescribedForClaude() throws {
        let server = server { _ in [] }
        let answer = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((answer["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool["name"] as? String, "capture_screen")
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertTrue(description.contains("Nook's own windows") && description.contains("left out"), "Claude knows Nook is not in the picture.")
        XCTAssertTrue(description.contains("image"))
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        let display = try XCTUnwrap((schema["properties"] as? [String: Any])?["display"] as? [String: Any])
        XCTAssertEqual(display["enum"] as? [String], ["pointer", "main", "all"])
        XCTAssertNil(schema["required"], "Every argument is optional.")
        XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
    }

    // MARK: The call

    func testACallReturnsTheScreenshotAsAnImageWithAShortCaption() throws {
        let shot = try shot()
        let server = server { _ in [shot] }
        let answer = try XCTUnwrap(reply(server, call()))
        XCTAssertEqual(answer["id"] as? Int, 7)
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
        let caption = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertEqual(caption, "Pantalla «Pantalla integrada», 14:03:22, 320×200 px, sin las ventanas de Nook. Archivo: \(shot.path)")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/png")
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(content[1]["data"] as? String)))
        XCTAssertEqual(data, try Data(contentsOf: URL(fileURLWithPath: shot.path)), "The file's own bytes.")
        XCTAssertEqual(asked, [.pointer], "The display under the pointer when Claude names none.")
    }

    func testEveryDisplayComesAsItsOwnImage() throws {
        let first = try shot("pantalla-20261007-140322-1.png", display: "Integrada"), second = try shot("pantalla-20261007-140322-2.png", display: "Externa")
        let server = server { _ in [first, second] }
        let answer = try XCTUnwrap(reply(server, call(#"{"display":"all"}"#)))
        let content = try XCTUnwrap((answer["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image", "text", "image"])
        XCTAssertTrue((content[2]["text"] as? String)?.contains("«Externa»") == true)
        XCTAssertEqual(asked, [.all])
        _ = try reply(server, call(#"{"display":"main"}"#))
        XCTAssertEqual(asked, [.all, .main])
    }

    func testNooksReasonReachesClaudeAsAToolError() throws {
        let server = server { _ in throw ScreenRelay.Failure.refused(ScreenVisionError.disabled.localizedDescription) }
        let answer = try XCTUnwrap(reply(server, call()))
        XCTAssertNil(answer["error"], "A failed capture is the tool's result, so Claude reads why.")
        let result = try XCTUnwrap(answer["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String,
                       "La visión de pantalla está desactivada en Nook. Actívala en los ajustes de Nook para que Claude pueda ver tu pantalla.")
        let closed = self.server { _ in throw ScreenRelay.Failure.notRunning }
        let text = try XCTUnwrap(((try reply(closed, call()))?["result"] as? [String: Any])?["content"] as? [[String: Any]]).first?["text"] as? String
        XCTAssertEqual(text, "Nook no está abierto. Ábrelo y activa la visión de pantalla en sus ajustes para que Claude pueda ver tu pantalla.")
    }

    func testABadDisplayIsExplainedWithoutCapturing() throws {
        let server = server { _ in XCTFail("Captured anyway"); return [] }
        for arguments in [#"{"display":"left"}"#, #"{"display":3}"#] {
            let result = try XCTUnwrap((try reply(server, call(arguments)))?["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertEqual((result["content"] as? [[String: Any]])?.first?["text"] as? String, "El parámetro display debe ser \"pointer\", \"main\" o \"all\".")
        }
        XCTAssertEqual(asked, [])
    }

    func testOnlyNooksOwnScreenshotsAreEverRead() throws {
        // A file outside the folder, or with another name, is not sent to Claude even if the answer names it.
        let secret = folder.deletingLastPathComponent().appendingPathComponent("secreto.png")
        try Data([1, 2, 3]).write(to: secret)
        let pasted = folder.appendingPathComponent("imagen-07102026140322.png")
        try Data([1, 2, 3]).write(to: pasted)
        let sneaky = folder.path + "/../secreto.png"
        for path in [secret.path, pasted.path, sneaky] {
            let server = server { _ in [ScreenShot(path: path, mimeType: "image/png", display: "x", width: 1, height: 1, date: Date())] }
            let result = try XCTUnwrap((try reply(server, call()))?["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true, path)
            XCTAssertFalse(String(describing: result).contains("AQID"), "The file's bytes never go out.")
        }
        // Nor through a link inside the folder.
        let link = folder.appendingPathComponent("pantalla-20261007-140323.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let linked = server { _ in [ScreenShot(path: link.path, mimeType: "image/png", display: "x", width: 1, height: 1, date: Date())] }
        XCTAssertEqual(((try reply(linked, call()))?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    // MARK: What is not this server's

    func testUnknownMethodsToolsAndGarbageGetTheirJSONRPCErrors() throws {
        let server = server { _ in [] }
        let unknown = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":"r","method":"resources/list"}"#))
        XCTAssertEqual(unknown["id"] as? String, "r")
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        let tool = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"delete_everything","arguments":{}}}"#))
        XCTAssertEqual((tool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let garbage = try XCTUnwrap(reply(server, "not json"))
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(garbage["id"] is NSNull)
        let noMethod = try XCTUnwrap(reply(server, #"{"jsonrpc":"2.0","id":4}"#))
        XCTAssertEqual((noMethod["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(asked, [])
    }

    func testABatchGetsABatchOfReplies() throws {
        let server = server { _ in [] }
        let line = try XCTUnwrap(server.reply(to: #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#))
        let replies = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]])
        XCTAssertEqual(replies.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertNil(server.reply(to: #"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#), "Only notifications: nothing to say.")
    }
}
