import XCTest
@testable import Nook

/// The page's own errors, written on the Mac (`POST /api/log`): one escaped line per entry, the user's file alone, capped, and a
/// limit per device and minute.
@MainActor
final class RemoteLogTests: XCTestCase {
    private var remotes: [RemoteAccess] = []

    override func tearDown() {
        remotes.forEach { $0.stop() }
        remotes = []
        super.tearDown()
    }

    private func paired() throws -> (RemoteAccess, String, AppModel) {
        let (model, _, _) = RemoteFixture.model()
        let remote = try RemoteFixture.started(model)
        remotes.append(remote)
        return (remote, try XCTUnwrap(RemoteFixture.pair(remote)), model)
    }

    private func post(_ remote: RemoteAccess, _ cookie: String?, _ body: Any, headers: [String: String] = [:]) -> RemoteResponse? {
        RemoteFixture.call(remote, RemoteFixture.request("POST", "/api/log", remote: remote, cookie: cookie, json: body, headers: headers))
    }

    private func logLines(_ remote: RemoteAccess, count: Int) -> [String] {
        var lines: [String] = []
        RemoteFixture.waitUntil {
            lines = ((try? String(contentsOf: remote.logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            return lines.count >= count
        }
        return lines
    }

    /// What Safari's `window.onerror` hands the page, as it would send it.
    private let entry: [String: Any] = [
        "level": "error", "message": "TypeError: undefined is not an object (evaluating 'd.prompt.options')",
        "detail": "renderPrompt@http://192.168.1.20:8765/:2451:31\nonState@http://192.168.1.20:8765/:1610:5", "url": "http://192.168.1.20:8765/", "line": 2451,
        "ua": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1",
    ]

    func testAnEntryIsOneEscapedLineFromItsDevice() throws {
        let (remote, cookie, _) = try paired()
        XCTAssertEqual(post(remote, cookie, entry)?.status, 200)
        let line = try XCTUnwrap(logLines(remote, count: 1).first)
        XCTAssertTrue(line.contains("[iPhone · Safari] error: TypeError: undefined is not an object (evaluating 'd.prompt.options')"), line)
        XCTAssertTrue(line.contains("detail: renderPrompt@http://192.168.1.20:8765/:2451:31\\nonState@"), "The stack's line break is escaped: \(line)")
        XCTAssertTrue(line.contains("url: http://192.168.1.20:8765/:2451"))
        XCTAssertTrue(line.contains("ua: Mozilla/5.0 (iPhone;"))
        let mode = (try FileManager.default.attributesOfItem(atPath: remote.logURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "The user's alone.")
        XCTAssertEqual(post(remote, cookie, ["level": "info", "message": "conectado", "detail": NSNull(), "url": NSNull(), "line": NSNull(), "ua": "x"])?.status, 200,
                       "Nulls where the contract allows them.")
        XCTAssertTrue(logLines(remote, count: 2)[1].hasSuffix("[iPhone · Safari] info: conectado · ua: x"))
    }

    func testAnEntryCannotPassForAnother() {
        XCTAssertEqual(RemoteLog.escaped("uno\ndos\r\ttres \\ \u{1B}[31m \u{2028}"), "uno\\ndos\\r\\ttres \\\\ \\u{1b}[31m \\u{2028}")
        let line = RemoteLog.line(RemoteLog.Entry(level: "warn", message: "a\n10/11/2026 [Mac] error: falso", detail: nil, url: nil, line: 3, userAgent: nil), device: "iPhone")
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.hasSuffix("[iPhone] warn: a\\n10/11/2026 [Mac] error: falso · line: 3"), line)
    }

    func testItTakesThePairedPagesPostsOnly() throws {
        let (remote, cookie, _) = try paired()
        XCTAssertEqual(post(remote, nil, entry)?.status, 401)
        XCTAssertEqual(post(remote, cookie, entry, headers: ["x-nook-remote": ""])?.status, 403)
        XCTAssertEqual(post(remote, cookie, entry, headers: ["origin": "http://evil.example"])?.status, 403)
        XCTAssertEqual(post(remote, cookie, ["level": "fatal", "message": "x"])?.status, 400, "Only error, warn and info.")
        XCTAssertEqual(post(remote, cookie, ["level": "error"])?.status, 400, "A message is needed.")
        var big = entry
        big["detail"] = String(repeating: "x", count: RemoteLog.maxBody)
        XCTAssertEqual(post(remote, cookie, big)?.status, 413, "At most 8 KB.")
        RemoteFixture.waitUntil(0.3) { false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.logURL.path), "Nothing of them was written.")
    }

    func testEachDeviceWritesTwentyAMinuteAndTheRestIsDropped() throws {
        let (remote, cookie, _) = try paired()
        let other = try XCTUnwrap(RemoteFixture.pair(remote))
        var dropped = 0
        for index in 0..<25 {
            var body = entry
            body["message"] = "error \(index)"
            let response = post(remote, cookie, body)
            XCTAssertEqual(response?.status, 200, "Dropped quietly: the page has nothing to do about it.")
            if RemoteFixture.json(response)["dropped"] as? Bool == true { dropped += 1 }
        }
        XCTAssertEqual(dropped, 5)
        XCTAssertEqual(post(remote, other, entry)?.status, 200)
        let lines = logLines(remote, count: 21)
        RemoteFixture.waitUntil(0.3) { false }
        XCTAssertEqual(lines.count, 21, "Twenty of the first device's, and the other device's own.")
        XCTAssertNil(lines.first { $0.contains("error: error 20") }, "The 21st of the minute was dropped.")
        let limiter = RemoteLogLimiter(), start = Date()
        for _ in 0..<RemoteLog.perMinute { XCTAssertTrue(limiter.allows("a", now: start)) }
        XCTAssertFalse(limiter.allows("a", now: start.addingTimeInterval(59)))
        XCTAssertTrue(limiter.allows("a", now: start.addingTimeInterval(61)), "A minute later it may write again.")
    }

    func testTheLogKeepsItsNewestHalfPastItsLimit() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nook-remote-log-\(UUID().uuidString.prefix(8))")
        let url = folder.appendingPathComponent("remote.log")
        let old = (0..<2000).map { "línea vieja \($0) " + String(repeating: "·", count: 20) }.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try old.write(to: url, atomically: false, encoding: .utf8)
        XCTAssertGreaterThan(old.utf8.count, RemoteLog.limit)
        RemoteLog.write("la nueva", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, RemoteLog.limit / 2 + 20)
        XCTAssertTrue(text.hasPrefix("línea vieja "), "Cut at a line's start.")
        XCTAssertTrue(text.contains("línea vieja 1999 "))
        XCTAssertTrue(text.hasSuffix("la nueva\n"))
        XCTAssertFalse(text.contains("línea vieja 0 "))
    }
}
