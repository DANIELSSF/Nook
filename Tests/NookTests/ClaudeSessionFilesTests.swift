import XCTest
@testable import Nook

/// A tab's record from the file Claude Code keeps for its process (`<config>/sessions/<pid>.json`), checked against the process
/// itself, before any guessing. The sample is a real file of Claude Code 2.1.292, trimmed.
final class ClaudeSessionFilesTests: XCTestCase {
    private var home: URL!
    private var config: URL!
    private static let first = "09ce6639-cd2e-43fc-83a6-50e34c44d2f8"
    private static let second = "b35f909a-28fd-4e00-93aa-857d3086e090"
    /// The moment `ps` says the process started, a fraction of a second before the whole second it prints.
    private static let started = ClaudeSessionFile.date(procStart: "Tue Oct  6 22:38:49 2026")!.addingTimeInterval(0.42)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-sessionfiles-\(UUID().uuidString.prefix(8))")
        config = home.appendingPathComponent(".claude-work")
        for folder in ["sessions", "projects/-Users-me-app"] {
            try FileManager.default.createDirectory(at: config.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for id in [Self.first, Self.second] { try record(id) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    @discardableResult private func record(_ id: String) throws -> URL {
        let url = config.appendingPathComponent("projects/-Users-me-app/\(id).jsonl")
        try (TranscriptFixtures.prompt("hola") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func json(pid: Int = 7078, session: String = first, procStart: String? = "Tue Oct  6 22:38:49 2026", updatedAt: Double = 1_791_407_427_688,
                      status: String = "busy") -> String {
        var object: [String: Any] = ["pid": pid, "sessionId": session, "cwd": "/Users/me/app", "startedAt": 1_791_326_330_396, "version": "2.1.292",
                                     "peerProtocol": 1, "kind": "interactive", "entrypoint": "cli", "messagingSocketPath": "/tmp/cc-socks/7078.sock",
                                     "name": "new-project-44", "status": status, "updatedAt": updatedAt, "statusUpdatedAt": updatedAt]
        if let procStart { object["procStart"] = procStart }
        return TranscriptFixtures.json(object)
    }

    /// Writes the process's file, dated `modified` (a rewrite within the same instant must still read as a change).
    private func write(_ text: String, pid: Int = 7078, modified: Date = Date()) throws {
        let url = config.appendingPathComponent("sessions/\(pid).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func locator(pid: Int32? = 7078, started: Date = started) -> ClaudeRecordLocator {
        ClaudeRecordLocator(tty: "/dev/ttys009", lookup: ClaudeProcessLookup(pid: { $0 == "/dev/ttys009" ? pid : nil }, started: { $0 == pid ? started : nil }),
                            configs: [home.appendingPathComponent(".claude"), config])
    }

    // MARK: The file

    func testClaudesFileIsReadAsItIsWritten() throws {
        let file = try XCTUnwrap(ClaudeSessionFile.parse(Data(json().utf8)))
        XCTAssertEqual(file.pid, 7078)
        XCTAssertEqual(file.sessionID, Self.first)
        XCTAssertEqual(file.status, "busy")
        XCTAssertEqual(file.cwd, "/Users/me/app")
        XCTAssertEqual(file.updatedAt, Date(timeIntervalSince1970: 1_791_407_427.688))
    }

    func testOnlyTheProcessThatStartedThenMatches() throws {
        let file = try XCTUnwrap(ClaudeSessionFile.parse(Data(json().utf8)))
        XCTAssertTrue(file.matches(pid: 7078, startedAt: Self.started))
        XCTAssertEqual(ClaudeSessionFile.date(procStart: "Tue Oct 6 22:38:49 2026"), ClaudeSessionFile.date(procStart: " Tue  Oct  6  22:38:49 2026 "), "However it is spaced.")
        XCTAssertFalse(file.matches(pid: 7078, startedAt: Self.started.addingTimeInterval(3_600)), "The pid now belongs to a later process.")
        XCTAssertFalse(file.matches(pid: 7079, startedAt: Self.started))
        XCTAssertFalse(try XCTUnwrap(ClaudeSessionFile.parse(Data(json(procStart: nil).utf8))).matches(pid: 7078, startedAt: Self.started),
                       "Without its start nothing proves it is this process's.")
        XCTAssertFalse(try XCTUnwrap(ClaudeSessionFile.parse(Data(json(procStart: "mar.  6 oct 17:38:49 2026").utf8))).matches(pid: 7078, startedAt: Self.started))
    }

    func testAnythingElseIsIgnored() {
        XCTAssertNil(ClaudeSessionFile.parse(Data("{\"pid\":7078,\"sessionId\":".utf8)), "Cut off while written.")
        XCTAssertNil(ClaudeSessionFile.parse(Data(json(session: "../../etc/passwd").utf8)))
        XCTAssertNil(ClaudeSessionFile.parse(Data(json(session: "a/b").utf8)))
        XCTAssertNil(ClaudeSessionFile.parse(Data(json(pid: -1).utf8)))
        XCTAssertNil(ClaudeSessionFile.parse(Data("[1, 2]".utf8)))
        let padded = String(json().dropLast()) + ",\"extra\":\"" + String(repeating: "x", count: ClaudeSessionFile.maxBytes) + "\"}"
        XCTAssertNil(ClaudeSessionFile.parse(Data(padded.utf8)), "Far too large to be Claude's.")
    }

    // MARK: Finding the record

    func testTheVerifiedFileNamesTheRecord() throws {
        try write(json())
        let locator = locator()
        XCTAssertEqual(locator.sessionFile()?.status, "busy")
        XCTAssertEqual(locator.record(hook: nil)?.lastPathComponent, Self.first + ".jsonl")
    }

    func testAFileOfAnEarlierProcessWithTheSamePidIsNotTrusted() throws {
        try write(json())
        XCTAssertNil(locator(started: Self.started.addingTimeInterval(-86_400)).record(hook: nil))
    }

    func testAMalformedOrOversizedFileIsIgnored() throws {
        try write("{\"pid\":7078,")
        XCTAssertNil(locator().record(hook: nil))
        try write(String(repeating: " ", count: ClaudeSessionFile.maxBytes + 1) + json())
        XCTAssertNil(locator().record(hook: nil))
    }

    func testWithoutAFileTheGuessIsLeftToTheCaller() throws {
        XCTAssertNil(locator().record(hook: nil), "An older Claude writes no file: nothing to say, so the folder and screen guess goes on.")
        XCTAssertNil(locator(pid: nil).record(hook: nil), "No Claude process found on the terminal.")
        XCTAssertEqual(locator().record(hook: .init(id: Self.second, at: Date()))?.lastPathComponent, Self.second + ".jsonl", "Its hooks still say.")
    }

    func testAClearOrResumeInTheSameProcessMovesTheRecord() throws {
        try write(json(), modified: Date(timeIntervalSinceNow: -10))
        let locator = locator()
        XCTAssertEqual(locator.record(hook: nil)?.lastPathComponent, Self.first + ".jsonl")
        try write(json(session: Self.second))
        XCTAssertEqual(locator.record(hook: nil)?.lastPathComponent, Self.second + ".jsonl")

        // A session whose record isn't written yet (a fresh /clear): nothing until it is.
        let third = "3912fd9f-747c-4a66-9590-b3ae71f5ea59"
        try write(json(session: third), modified: Date(timeIntervalSinceNow: 5))
        let now = Date()
        XCTAssertNil(locator.record(hook: nil, now: now))
        try record(third)
        XCTAssertNil(locator.record(hook: nil, now: now.addingTimeInterval(1)), "Searched for again after a while, not on every reading.")
        XCTAssertEqual(locator.record(hook: nil, now: now.addingTimeInterval(ClaudeRecordLocator.searchInterval + 1))?.lastPathComponent, third + ".jsonl")
    }

    func testTheFileIsReadAgainOnlyWhenItChanges() throws {
        let stamp = Date(timeIntervalSinceNow: -60)
        try write(json(), modified: stamp)
        let locator = locator()
        XCTAssertEqual(locator.sessionFile()?.sessionID, Self.first)
        // Same size and date, other content: not read again (a reading only stats it).
        try write(json(session: Self.second), modified: stamp)
        XCTAssertEqual(locator.sessionFile()?.sessionID, Self.first)
        try write(json(session: Self.second), modified: stamp.addingTimeInterval(1))
        XCTAssertEqual(locator.sessionFile()?.sessionID, Self.second)
    }

    func testTheNewerOfTheFileAndTheHooksWins() throws {
        let updated = Date(timeIntervalSince1970: 1_791_407_427.688)
        try write(json(updatedAt: updated.timeIntervalSince1970 * 1000))
        let locator = locator()
        XCTAssertEqual(locator.sessionID(hook: .init(id: Self.second, at: updated.addingTimeInterval(5))), Self.second, "A hook after the file's last word.")
        XCTAssertEqual(locator.sessionID(hook: .init(id: Self.second, at: updated.addingTimeInterval(-5))), Self.first, "The file rewritten after the hook.")
        XCTAssertEqual(locator.sessionID(hook: .init(id: Self.first, at: .distantPast)), Self.first)
    }

    // MARK: The process

    func testThePidOfClaudeOnATerminal() {
        XCTAssertEqual(TranscriptLocator.claudePID(ps: "  7177 claude\n  812 -zsh\n"), 7177, "A short pid comes padded.")
        XCTAssertEqual(TranscriptLocator.claudePID(ps: " 3001 /bin/zsh\n57770 /Users/me/.local/bin/claude\n"), 57770)
        XCTAssertNil(TranscriptLocator.claudePID(ps: "  812 -zsh\n 9000 node\n"))
        XCTAssertNotNil(TranscriptLocator.startTime(pid: getpid()))
        XCTAssertLessThan(TranscriptLocator.startTime(pid: getpid())!, Date())
        XCTAssertNil(TranscriptLocator.startTime(pid: 999_999))
    }

    /// `NOOK_REAL_TTY=/dev/ttys001`: the live Claude on that terminal, its file and its record (read only).
    func testARealTerminalOnRequest() throws {
        guard let tty = ProcessInfo.processInfo.environment["NOOK_REAL_TTY"] else { throw XCTSkip("Set NOOK_REAL_TTY to look up a real Claude.") }
        let locator = ClaudeRecordLocator(tty: tty)
        let file = locator.sessionFile()
        print("pid:", TranscriptLocator.claudePID(tty: tty) as Any, "started:", TranscriptLocator.claudePID(tty: tty).flatMap(TranscriptLocator.startTime(pid:)) as Any)
        print("file:", file as Any)
        print("record:", locator.record(hook: nil)?.path ?? "—")
    }
}

/// The whole path: a tab followed on a guess moves to the record its Claude's file names, and follows a /clear.
@MainActor
final class ClaudeSessionFileFollowTests: XCTestCase {
    func testATabMovesToTheRecordItsClaudeNamesAndFollowsAClear() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-sessionflow-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".claude-work")
        let project = config.appendingPathComponent("projects/-Users-me-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let ids = ["11111111-aaaa-4bbb-8ccc-000000000001", "789f05bb-7a12-484f-94e0-22ba8d29fb9e", "22222222-aaaa-4bbb-8ccc-000000000002"]
        for id in ids { try (TranscriptFixtures.prompt("prompt de \(id.prefix(8))") + "\n").write(to: project.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8) }
        let started = ClaudeSessionFile.date(procStart: "Mon Oct  5 16:07:15 2026")!.addingTimeInterval(0.3)
        func file(_ id: String, modified: Date) throws {
            let url = config.appendingPathComponent("sessions/59541.json")
            try TranscriptFixtures.json(["pid": 59541, "sessionId": id, "procStart": "Mon Oct  5 16:07:15 2026", "kind": "interactive", "status": "idle",
                                         "updatedAt": Date().timeIntervalSince1970 * 1000]).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try file(ids[1], modified: Date(timeIntervalSinceNow: -30))

        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-sessionflow-" + UUID().uuidString)!)
        model.claudeProcesses = ClaudeProcessLookup(pid: { $0 == "/dev/ttys941" ? 59541 : nil }, started: { $0 == 59541 ? started : nil })
        model.claudeConfigs = { [config] }
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys941", customTitle: "", processes: ["claude"], busy: false, selected: true,
                                      text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]
        // Followed on a guess: another session of the same folder.
        session.transcript = TranscriptFollower(url: project.appendingPathComponent(ids[0] + ".jsonl"))
        session.transcriptByGuess = true; session.transcriptLocated = Date()

        model.followTranscript(session)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(session.transcript?.url.lastPathComponent, ids[1] + ".jsonl", "The record its Claude names.")
        XCTAssertEqual(session.transcriptByGuess, false)
        XCTAssertEqual(session.displayText, "> prompt de 789f05bb\n\n")

        try file(ids[2], modified: Date())
        model.followTranscript(session)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(session.transcript?.url.lastPathComponent, ids[2] + ".jsonl", "/clear in the same process: the new record, at the next reading.")
    }
}
