import XCTest
@testable import Nook

/// Nook's status line for Claude Code: installed into settings files (all in temporary folders, never the user's own), the
/// real script run against a payload like Claude 2.1.294's, the folder it writes to watched and mapped to tabs, the card's
/// figures filled from it, and Claude's screens with the status line's row under the box.
final class NookStatusLineTests: XCTestCase {
    private var root: URL!
    private var script: URL { root.appendingPathComponent("support/nook-statusline.sh") }
    private var status: URL { root.appendingPathComponent("tmp/status") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-statusline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        NookStatusLine.setShownLines([])
        ClaudeSettingsFile.willWrite = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String, settings: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let settings { try settings.write(to: url.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8) }
        return url
    }

    private func json(_ folder: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("settings.json"))) as? [String: Any])
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func backups(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("settings.nook-backup-") }
    }

    // MARK: Install and uninstall

    func testInstallAddsChainsAndUninstallPutsEveryFolderBackAsItWas() throws {
        let empty = try folder(".claude")
        let other = try folder(".claude-work", settings: #"{"model": "opus", "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "afplay x"}]}]}}"#)
        let foreign = try folder(".claude-team", settings: #"{"statusLine": {"type": "command", "command": "~/bin/line.sh 'it''s'", "padding": 1, "refreshInterval": 10}, "x": 1}"#)
        let beforeOther = try json(other), beforeForeign = try json(foreign)
        XCTAssertEqual(NookStatusLine.states(folders: [empty, other, foreign], script: script).map(\.state),
                       [.off, .off, .foreign(command: "~/bin/line.sh 'it''s'")])

        try NookStatusLine.install(in: [empty, other, foreign], script: script, statusFolder: status)
        let own = NookStatusLine.command(script: script)
        XCTAssertEqual((try json(empty))["statusLine"] as? [String: String], ["type": "command", "command": own])
        XCTAssertEqual(mode(empty.appendingPathComponent("settings.json").path), 0o600)
        XCTAssertEqual((try json(other))["model"] as? String, "opus", "Everything else stays.")
        XCTAssertNotNil((try json(other))["hooks"])
        XCTAssertEqual(backups(other).count, 1, "A backup of the file Nook changed.")
        XCTAssertEqual(backups(empty).count, 0, "Nothing to back up where there was no file.")
        let chained = try XCTUnwrap((try json(foreign))["statusLine"] as? [String: Any])
        XCTAssertEqual(chained["command"] as? String, NookStatusLine.command(script: script, chaining: "~/bin/line.sh 'it''s'"))
        XCTAssertEqual(chained["padding"] as? Int, 1); XCTAssertEqual(chained["refreshInterval"] as? Int, 10, "The rest of the user's status line stays.")
        XCTAssertEqual(NookStatusLine.states(folders: [empty, other, foreign], script: script).map(\.state),
                       [.on, .on, .chained(original: "~/bin/line.sh 'it''s'")])
        XCTAssertEqual(mode(script.path), 0o700)
        XCTAssertTrue(own.hasPrefix("/bin/sh '") && own.hasSuffix("nook-statusline.sh'"))

        // A second click changes nothing.
        let settled = try [empty, other, foreign].map { try Data(contentsOf: $0.appendingPathComponent("settings.json")) }
        try NookStatusLine.install(in: [empty, other, foreign], script: script, statusFolder: status)
        XCTAssertEqual(try [empty, other, foreign].map { try Data(contentsOf: $0.appendingPathComponent("settings.json")) }, settled)

        try NookStatusLine.uninstall(from: [empty, other, foreign], script: script, statusFolder: status)
        XCTAssertNil((try json(empty))["statusLine"])
        XCTAssertEqual(NSDictionary(dictionary: try json(other)), NSDictionary(dictionary: beforeOther), "Exactly as before.")
        XCTAssertEqual(NSDictionary(dictionary: try json(foreign)), NSDictionary(dictionary: beforeForeign), "The user's own status line, all of it.")
        XCTAssertEqual(NookStatusLine.states(folders: [empty, other, foreign], script: script).map(\.state), [.off, .off, .foreign(command: "~/bin/line.sh 'it''s'")])
    }

    func testRemovingPutsBackOnlyTheCommandAndKeepsLaterEdits() throws {
        let foreign = try folder(".claude", settings: #"{"statusLine": {"type": "command", "command": "printf 'x'", "padding": 2}}"#)
        try NookStatusLine.install(in: [foreign], script: script, statusFolder: status)
        // The user changes the padding while Nook's status line is in.
        var edited = try json(foreign)
        var line = try XCTUnwrap(edited["statusLine"] as? [String: Any])
        line["padding"] = 4
        edited["statusLine"] = line
        try JSONSerialization.data(withJSONObject: edited).write(to: foreign.appendingPathComponent("settings.json"))
        try NookStatusLine.uninstall(from: [foreign], script: script, statusFolder: status)
        let restored = try XCTUnwrap((try json(foreign))["statusLine"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "printf 'x'", "The user's command back.")
        XCTAssertEqual(restored["padding"] as? Int, 4, "The edit made since stays.")
    }

    func testALinkedSettingsFileStaysALinkForTheStatusLineAndTheHooks() throws {
        // A dotfiles setup: ~/.claude/settings.json is a link to the real file elsewhere.
        let dotfiles = root.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("claude-settings.json")
        try #"{"model": "opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        let linked = try folder(".claude")
        let link = linked.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try NookStatusLine.install(in: [linked], script: script, statusFolder: status)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "Still a link.")
        XCTAssertNotNil((try json(linked))["statusLine"], "The real file has it.")
        XCTAssertEqual(backups(dotfiles).count, 1, "The backup sits beside the real file.")
        try ClaudeHooks.write(enabled: true, to: [linked], command: "/x/nook-hook --claude-hook")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertTrue(ClaudeHooks.isEnabled(in: linked, command: "/x/nook-hook --claude-hook"))
        XCTAssertEqual(mode(real.path), 0o600)
    }

    func testAFileChangedMeanwhileIsNotOverwritten() throws {
        let work = try folder(".claude-work", settings: #"{"model": "opus"}"#)
        // Claude rewrites the file (/model) between Nook's reading and its writing.
        ClaudeSettingsFile.willWrite = { url in try? #"{"model": "sonnet"}"#.write(to: url, atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try NookStatusLine.install(in: [work], script: script, statusFolder: status)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cambió mientras Nook lo editaba"), error.localizedDescription)
        }
        XCTAssertEqual((try json(work))["model"] as? String, "sonnet", "Claude's change stands.")
        XCTAssertNil((try json(work))["statusLine"])
        XCTAssertEqual(backups(work).count, 0)
    }

    func testBackupsArePrivateAndOnlyTheNewestAreKept() throws {
        let work = try folder(".claude-work", settings: #"{"env": {"TOKEN": "secret"}}"#)
        for _ in 0..<4 {
            try NookStatusLine.install(in: [work], script: script, statusFolder: status)
            try NookStatusLine.uninstall(from: [work], script: script, statusFolder: status)
        }
        let kept = backups(work)
        XCTAssertEqual(kept.count, ClaudeSettingsFile.backupsKept, "8 changes, \(ClaudeSettingsFile.backupsKept) backups.")
        XCTAssertTrue(kept.allSatisfy { mode(work.appendingPathComponent($0).path) == 0o600 })
        XCTAssertEqual(mode(work.appendingPathComponent("settings.json").path), 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: work.path).contains { $0.contains(".nook-") && !$0.hasPrefix("settings.nook-backup-") }, "No temporary file left.")
    }

    func testAMalformedSettingsFileStopsEverythingAndOtherStatusLinesAreNeverTouched() throws {
        let good = try folder(".claude")
        let broken = try folder(".claude-work", settings: "{ \"model\": ")
        XCTAssertEqual(NookStatusLine.states(folders: [good, broken], script: script).map(\.state), [.off, .unreadable])
        XCTAssertThrowsError(try NookStatusLine.install(in: [good, broken], script: script, statusFolder: status)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No se modificó nada"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.appendingPathComponent("settings.json").path), "Nothing written anywhere.")
        XCTAssertEqual(try String(contentsOf: broken.appendingPathComponent("settings.json"), encoding: .utf8), "{ \"model\": ")
        // A status line of another kind can't be chained, nor one that isn't even an object: left alone, and said so.
        let other = try folder(".claude-other", settings: #"{"statusLine": {"type": "static", "text": "hola"}}"#)
        let odd = try folder(".claude-odd", settings: #"{"statusLine": "echo hola"}"#)
        let before = try [other, odd].map { try Data(contentsOf: $0.appendingPathComponent("settings.json")) }
        XCTAssertEqual(NookStatusLine.states(folders: [odd], script: script).map(\.state), [.foreign(command: "")])
        XCTAssertEqual(try NookStatusLine.install(in: [other, odd], script: script, statusFolder: status), [other, odd])
        XCTAssertEqual(try [other, odd].map { try Data(contentsOf: $0.appendingPathComponent("settings.json")) }, before)
        try NookStatusLine.uninstall(from: [other, odd], script: script, statusFolder: status)
        XCTAssertEqual(try [other, odd].map { try Data(contentsOf: $0.appendingPathComponent("settings.json")) }, before)
        // Removing touches only Nook's own.
        let mine = try folder(".claude-mine", settings: #"{"statusLine": {"type": "command", "command": "~/line.sh"}}"#)
        let untouched = try Data(contentsOf: mine.appendingPathComponent("settings.json"))
        try NookStatusLine.uninstall(from: [mine], script: script, statusFolder: status)
        XCTAssertEqual(try Data(contentsOf: mine.appendingPathComponent("settings.json")), untouched)
        XCTAssertEqual(NookStatusLine.unquote(Shell.quote("it's 'quoted'")), "it's 'quoted'")
        XCTAssertNil(NookStatusLine.unquote("'unbalanced"))
    }

    // MARK: The script

    static let resets = (session: Date(timeIntervalSince1970: 1_791_500_000), week: Date(timeIntervalSince1970: 1_791_900_000))

    static var payload: String {
        #"{"session_id":"abc-123","transcript_path":"/Users/sample/.claude-work/projects/-Users-sample-p/abc-123.jsonl","cwd":"/Users/sample/p","#
            + #""model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"version":"2.1.294","#
            + #""cost":{"total_cost_usd":1.75,"total_duration_ms":496000,"total_api_duration_ms":254000,"total_lines_added":3,"total_lines_removed":1},"#
            + #""context_window":{"total_input_tokens":84000,"context_window_size":200000,"used_percentage":42,"remaining_percentage":58},"#
            + #""effort":{"level":"xhigh"},"rate_limits":{"five_hour":{"used_percentage":28,"resets_at":1791500000},"seven_day":{"used_percentage":74,"resets_at":1791900000}},"#
            + #""prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1791493600,"requests":22,"misses":0,"hit_ratio":0.95}}"#
    }

    private func runScript(_ arguments: [String] = [], input: String = payload) throws -> (status: Int32, output: String, seconds: Double, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let start = Date()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, Date().timeIntervalSince(start), errors)
    }

    func testTheScriptLeavesThePayloadPrivatelyAndPrintsNothing() throws {
        try NookStatusLine.installScript(at: script, statusFolder: status)
        let result = try runScript()
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.output, "", "Nothing of its own on Claude's screen.")
        XCTAssertLessThan(result.seconds, 2)
        let file = status.appendingPathComponent("abc-123.json")
        XCTAssertEqual(mode(file.path), 0o600); XCTAssertEqual(mode(status.path), 0o700)
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil(wrapper["nook_ppid"] as? NSNumber)
        let payload = try XCTUnwrap((wrapper["payload"] as? [String: Any]).flatMap(ClaudeStatusPayload.init(json:)))
        XCTAssertEqual(payload.sessionID, "abc-123")
        XCTAssertEqual(payload.rateLimits?.sevenDay?.usedPercentage, 74)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: status.path).contains { $0.hasPrefix(".") }, "No half-written file left.")
        // A session id that could leave the folder is not written at all.
        _ = try runScript(input: Self.payload.replacingOccurrences(of: "abc-123\",\"transcript", with: "../../x\",\"transcript"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: status.path).sorted(), ["abc-123.json"])
    }

    func testTheScriptTakesSpacedJSONAndSaysNothingAboutWhatItRefuses() throws {
        try NookStatusLine.installScript(at: script, statusFolder: status)
        // Whitespace after the colon, as a pretty-printed payload has it.
        let spaced = Self.payload.replacingOccurrences(of: "\"session_id\":\"abc-123\"", with: "\"session_id\":  \"abc-123\"")
        XCTAssertNotEqual(spaced, Self.payload)
        XCTAssertEqual(try runScript(input: spaced).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.appendingPathComponent("abc-123.json").path))
        // An id too long, or of other characters: nothing written, nothing said, not even on stderr.
        for id in [String(repeating: "a", count: 200), "a/b", "x y"] {
            let result = try runScript(input: Self.payload.replacingOccurrences(of: "abc-123\",\"transcript", with: "\(id)\",\"transcript"))
            XCTAssertEqual(result.status, 0, id); XCTAssertEqual(result.output, "", id); XCTAssertEqual(result.errors, "", id)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: status.path), ["abc-123.json"])
        XCTAssertEqual(try runScript(input: "not json").errors, "")
        // Removing Nook's status line takes the folder and every payload in it.
        let claude = try folder(".claude")
        try NookStatusLine.install(in: [claude], script: script, statusFolder: status)
        try NookStatusLine.uninstall(from: [claude], script: script, statusFolder: status)
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
    }

    func testTheScriptEndsAtOnceWhenItsFolderIsBrokenOrNotPrivate() throws {
        // A file where the folder should be.
        try NookStatusLine.installScript(at: script, statusFolder: status)
        try Data("x".utf8).write(to: status)
        let blocked = try runScript()
        XCTAssertEqual(blocked.status, 0); XCTAssertEqual(blocked.output, ""); XCTAssertLessThan(blocked.seconds, 2)
        XCTAssertEqual(blocked.errors, "", "Not a word on stderr either.")
        // A link to somewhere else: nothing goes through it.
        try FileManager.default.removeItem(at: status)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: status, withDestinationURL: elsewhere)
        XCTAssertEqual(try runScript().status, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testAChainedStatusLineGetsTheSameInputAndShowsAsBefore() throws {
        try NookStatusLine.installScript(at: script, statusFolder: status)
        let echoed = try runScript(["--chain", "cat"])
        XCTAssertEqual(echoed.output.trimmingCharacters(in: .newlines), Self.payload, "The user's command reads what Claude sent.")
        let shown = try runScript(["--chain", "cat >/dev/null; printf '~/proj main ✓'; exit 3"])
        XCTAssertEqual(shown.output, "~/proj main ✓\n")
        XCTAssertEqual(shown.status, 3, "It ends as the user's did.")
        XCTAssertEqual(try String(contentsOf: status.appendingPathComponent("abc-123.line"), encoding: .utf8), "~/proj main ✓\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.appendingPathComponent("abc-123.json").path))
        // A status line that prints nothing still prints nothing, and its old row is forgotten.
        let silent = try runScript(["--chain", "cat >/dev/null"])
        XCTAssertEqual(silent.output, "")
        XCTAssertEqual(silent.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.appendingPathComponent("abc-123.line").path))
    }

    // MARK: Watching and mapping

    private func reading(_ id: String, folder: String = "/Users/sample/.claude-work", limits: (Double, Double)? = (28, 74), ppid: Int = 0,
                         age: TimeInterval = 0, line: String? = nil) throws {
        let limitsJSON = limits.map { #","rate_limits":{"five_hour":{"used_percentage":\#($0.0),"resets_at":1791500000},"seven_day":{"used_percentage":\#($0.1),"resets_at":1791900000}}"# } ?? ""
        let text = #"{"nook_ppid":\#(ppid),"payload":{"session_id":"\#(id)","transcript_path":"\#(folder)/projects/p/\#(id).jsonl""# + limitsJSON + "}}"
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = status.appendingPathComponent(id + ".json")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        if let line { try line.write(to: status.appendingPathComponent(id + ".line"), atomically: true, encoding: .utf8) }
    }

    func testTheWatcherReadsEachSessionAndPrunesWhatIsStale() throws {
        try reading("old", age: 30)
        try reading("new", ppid: 4242, line: "\u{1B}[2m~/proj main ✓\u{1B}[0m\n")
        try reading("gone", age: 7 * 3600)
        try "{}".write(to: status.appendingPathComponent(".half.123"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: status.appendingPathComponent(".half.123").path)
        let watcher = ClaudeStatusWatcher(folder: status)
        watcher.terminalOf = { $0 == 4242 ? "/dev/ttys004" : "" }
        watcher.processStart = { _ in "1.0" }
        let readings = watcher.scan()
        XCTAssertEqual(readings.map(\.payload.sessionID), ["old", "new"], "Oldest first; the stale one is gone.")
        XCTAssertEqual(readings.last?.tty, "/dev/ttys004")
        XCTAssertEqual(readings.first?.payload.configFolder, "/Users/sample/.claude-work")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: status.path).sorted(), ["new.json", "new.line", "old.json"])
        XCTAssertTrue(NookStatusLine.isShownLine("  ~/proj main ✓"), "The chained line, colours off, is Claude's footer.")
        XCTAssertTrue(NookStatusLine.isShownLine("~/proj main…"), "Cut short by Claude: the same row.")
        XCTAssertFalse(NookStatusLine.isShownLine("~/pr…"), "Too short a cut to be sure.")
        // A reused pid is a new process: its terminal is asked again; a process that is gone has none.
        var asked = 0
        var started: String? = "100.1"
        watcher.terminalOf = { pid in
            guard pid == 777 else { return "" }
            asked += 1
            return "/dev/ttys00\(asked)"
        }
        watcher.processStart = { _ in started }
        try reading("pid", ppid: 777)
        XCTAssertEqual(watcher.scan().first { $0.payload.sessionID == "pid" }?.tty, "/dev/ttys001")
        XCTAssertEqual(watcher.scan().first { $0.payload.sessionID == "pid" }?.tty, "/dev/ttys001", "Same process: from the cache.")
        started = "200.2"
        XCTAssertEqual(watcher.scan().first { $0.payload.sessionID == "pid" }?.tty, "/dev/ttys002")
        started = nil
        XCTAssertNil(watcher.scan().first { $0.payload.sessionID == "pid" }?.tty)
        XCTAssertNotNil(ClaudeStatusWatcher.startTime(of: getpid()))
        XCTAssertFalse(NookStatusLine.isShownLine("⏺ ~/proj main ✓ is the folder"))
    }

    func testAChainedLineIsReadOnlyFromASafeSmallFileOfAValidSession() throws {
        let watcher = ClaudeStatusWatcher(folder: status)
        watcher.processStart = { _ in nil }
        // A payload whose session id would lead out of the folder: its line is not looked for.
        try reading("odd")
        let odd = status.appendingPathComponent("odd.json")
        try String(contentsOf: odd, encoding: .utf8).replacingOccurrences(of: "\"session_id\":\"odd\"", with: "\"session_id\":\"../outside\"")
            .write(to: odd, atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent("tmp/outside.line"), atomically: true, encoding: .utf8)
        XCTAssertNil(watcher.scan().first { $0.payload.sessionID == "../outside" }?.line)
        // A link, or something far too big for a status line, is not read either.
        try reading("linked")
        try FileManager.default.createSymbolicLink(at: status.appendingPathComponent("linked.line"), withDestinationURL: root.appendingPathComponent("tmp/outside.line"))
        try reading("big", line: String(repeating: "x", count: 70_000))
        try reading("fine", line: "ok line here\n")
        let lines = Dictionary(uniqueKeysWithValues: watcher.scan().map { ($0.payload.sessionID, $0.line) })
        XCTAssertEqual(lines["linked"], .some(nil)); XCTAssertEqual(lines["big"], .some(nil)); XCTAssertEqual(lines["fine"], "ok line here\n")
    }

    func testEachTabGetsItsOwnFiguresAndItsAccountsFreshestLimits() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-statusline-" + UUID().uuidString)!)
        func session(_ id: String) -> TerminalSession {
            let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-statusline-\(getpid()).sock", configuration: "/dev/null")
            let record = SessionRecord(id: "nook-sl-" + id + UUID().uuidString.prefix(4), name: id, kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
            return TerminalSession(record: record, backend: backend, create: false)
        }
        let work = session("work"), quiet = session("quiet"), other = session("other"), byTerminal = session("tty")
        work.transcript = TranscriptFollower(url: URL(fileURLWithPath: "/Users/sample/.claude-work/projects/p/abc-123.jsonl"))
        quiet.transcript = TranscriptFollower(url: URL(fileURLWithPath: "/Users/sample/.claude-work/projects/q/def-456.jsonl"))
        other.transcript = TranscriptFollower(url: URL(fileURLWithPath: "/Users/sample/.claude/projects/p/ghi-789.jsonl"))
        byTerminal.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: "⏺ hola")
        model.sessions = [work, quiet, other, byTerminal]
        func payload(_ id: String, folder: String = "/Users/sample/.claude-work", limits: (Double, Double)?) -> ClaudeStatusPayload {
            var json: [String: Any] = ["session_id": id, "transcript_path": "\(folder)/projects/p/\(id).jsonl", "cost": ["total_cost_usd": 1.5]]
            if let limits { json["rate_limits"] = ["five_hour": ["used_percentage": limits.0], "seven_day": ["used_percentage": limits.1]] }
            return ClaudeStatusPayload(json: json)!
        }
        let now = Date()
        let readings = [ClaudeStatusReading(payload: payload("abc-123", limits: (28, 74)), at: now.addingTimeInterval(-60)),
                        ClaudeStatusReading(payload: payload("zzz-999", limits: (30, 75)), at: now),
                        ClaudeStatusReading(payload: payload("ghi-789", folder: "/Users/sample/.claude", limits: (5, 10)), at: now),
                        ClaudeStatusReading(payload: payload("tty-1", folder: "/Users/sample/.claude-x", limits: nil), at: now, tty: "/dev/ttys005")]
        model.applyStatus(readings)
        XCTAssertEqual(work.liveUsage?.session?.sessionID, "abc-123", "Its own, by its record.")
        XCTAssertEqual(work.liveUsage?.limits?.fiveHour?.usedPercentage, 30, "The account's freshest, from another session of the folder.")
        XCTAssertNil(quiet.liveUsage?.session, "No reading of its own yet…")
        XCTAssertEqual(quiet.liveUsage?.limits?.sevenDay?.usedPercentage, 75, "…but its account's limits.")
        XCTAssertEqual(other.liveUsage?.limits?.fiveHour?.usedPercentage, 5, "Another account, its own limits.")
        XCTAssertEqual(byTerminal.liveUsage?.session?.sessionID, "tty-1", "No record yet: by its terminal.")
    }

    // MARK: The card

    private func live(fiveHour: Double = 3, sevenDay: Double = 86, at now: Date) -> ClaudeLiveUsage {
        var json: [String: Any] = ["session_id": "abc-123", "transcript_path": "/Users/sample/.claude-work/projects/p/abc-123.jsonl",
                                   "cost": ["total_cost_usd": 1.75, "total_duration_ms": 496_000, "total_api_duration_ms": 254_000, "total_lines_added": 0, "total_lines_removed": 0],
                                   "prompt_cache": ["warm": true, "ttl": "1h", "expires_at": now.addingTimeInterval(3600 - 71).timeIntervalSince1970, "requests": 22, "misses": 0, "hit_ratio": 0.95]]
        json["rate_limits"] = ["five_hour": ["used_percentage": fiveHour, "resets_at": now.addingTimeInterval(3 * 3600).timeIntervalSince1970],
                               "seven_day": ["used_percentage": sevenDay, "resets_at": now.addingTimeInterval(5 * 86400).timeIntervalSince1970]]
        let payload = ClaudeStatusPayload(json: json)!
        return ClaudeLiveUsage(session: payload, sessionAt: now, limits: payload.rateLimits, limitsAt: now)
    }

    private let bogota = TimeZone(identifier: "America/Bogota")!

    private func at(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = bogota; formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testTheLimitsTheScreenDidNotReachComeLiveAndThePanelsOwnWin() throws {
        let now = at("2026-10-08 10:00")
        // 32 rows of a Nook tab: the session's limit is on screen, the week's is not.
        let partial = try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.screen(top: 0, height: 28)))
        let filled = partial.filled(from: live(at: now), now: now, zone: bogota)
        XCTAssertEqual(filled.meters.map(\.title), ["Current session", "Current week (all models)"])
        XCTAssertEqual(filled.meters[0].source, .panel); XCTAssertEqual(filled.meters[0].fraction, 0.28, "The panel's own figure wins.")
        XCTAssertEqual(filled.meters[1].source, .live); XCTAssertEqual(filled.meters[1].fraction, 0.86, accuracy: 0.0001)
        XCTAssertEqual(filled.meters[1].label, "86% used")
        XCTAssertEqual(filled.meters[1].resets, "Resets Oct 13 at 10am (America/Bogota)")
        XCTAssertEqual(UsageWords.resets(filled.meters[1].resets!), "Se reinicia el 13 oct a las 10 a. m. (America/Bogota)", "Worded as Claude does, so it reads in Spanish.")
        XCTAssertNotNil(filled.live)
        // The whole panel: its limits stand, the Fable one included; nothing is added.
        let whole = try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.whole)).filled(from: live(at: now), now: now, zone: bogota)
        XCTAssertEqual(whole.meters.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertTrue(whole.meters.allSatisfy { $0.source == .panel && $0.resetsSource == .panel })
        XCTAssertEqual(try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.whole)).filled(from: nil), try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.whole)))
    }

    func testAResetThePanelShowsThatHasPassedGivesWayToTheNextOne() throws {
        // The panel was read at noon: "Resets 1pm". It is 3 p.m. now, and Claude's status line says the next is at 6:10 p.m.
        let now = at("2026-10-08 15:00")
        var limits = live(at: now)
        limits.limits?.fiveHour?.resetsAt = at("2026-10-08 18:10")
        let usage = try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.whole)).filled(from: limits, now: now, zone: bogota)
        XCTAssertEqual(usage.meters[0].resets, "Resets 6:10pm (America/Bogota)")
        XCTAssertEqual(usage.meters[0].resetsSource, .live)
        XCTAssertEqual(usage.meters[0].source, .panel, "Its percent is still the panel's.")
        XCTAssertEqual(usage.meters[1].resetsSource, .panel, "Oct 13 has not come yet.")
        XCTAssertEqual(ClaudeUsage.resetDate("Resets Oct 13 at 6am (America/Bogota)", now: now, zone: .current), at("2026-10-13 06:00"))
    }

    func testTheSessionsFiguresComeLiveWhereThePanelsRowsLackThem() throws {
        let now = at("2026-10-08 10:00")
        // First seen with its top row at the prompt cache: no cost, durations or code changes on screen.
        let reader = ClaudeUsageReader()
        let text = try XCTUnwrap(reader.read(ClaudeComposer.split(ClaudeUsageFixtures.screen(top: 11, height: 28)).panel))
        let usage = try XCTUnwrap(ClaudeUsageFixtures.usage(text)).filled(from: live(at: now), now: now, zone: bogota)
        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.cost, "$1.75"); XCTAssertEqual(session.apiDuration, "4m 14s"); XCTAssertEqual(session.wallDuration, "8m 16s")
        XCTAssertEqual(session.linesAdded, 0); XCTAssertEqual(session.linesRemoved, 0)
        XCTAssertEqual(session.liveFields, [.cost, .apiDuration, .wallDuration, .lines])
        XCTAssertEqual(session.promptCache, "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)", "The panel's own.")
        // No session section at all on screen: all of it live, the cache line worded as Claude's so it reads in Spanish.
        let tail = try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudeUsageFixtures.screen(top: 38, height: 28))).filled(from: live(at: now), now: now, zone: bogota)
        XCTAssertEqual(tail.session?.promptCache, "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)")
        XCTAssertEqual(tail.session?.liveFields.contains(.promptCache), true)
        XCTAssertEqual(UsageWords.promptCache(try XCTUnwrap(tail.session?.promptCache)),
                       "22 solicitudes · 95 % de la entrada desde la caché · sin fallos · activa (TTL de 1h, última actividad hace 1m 11s)")
        XCTAssertEqual(ClaudeUsage.dollars(0.0003), "$0.0003"); XCTAssertEqual(ClaudeUsage.duration(35_796), "9h 56m 36s")
    }

    // MARK: Claude's screen with a status line

    private func screen(statusRow: String?, footer: String? = "  ⏵⏵ auto mode on · ← for agents") -> String {
        (["⏺ Listo, lo dejé así.", "", String(repeating: "─", count: 80), "❯ ", String(repeating: "─", count: 80)]
            + (statusRow.map { [$0] } ?? []) + (footer.map { [$0] } ?? [])).joined(separator: "\n")
    }

    func testTheBoxModeAndConversationReadTheSameWithAStatusRowUnderTheBox() throws {
        for row in [nil, "", "  "] {
            let split = ClaudeComposer.split(screen(statusRow: row))
            XCTAssertEqual(split.input, "", "The box: \(String(describing: row))")
            XCTAssertEqual(split.mode?.kind, .auto)
            XCTAssertEqual(split.conversation, "⏺ Listo, lo dejé así.")
            XCTAssertNil(split.panel)
        }
        // The default mode: Claude hides its hints while a status line is set, leaving only the (blank) status row.
        XCTAssertEqual(ClaudeComposer.split(screen(statusRow: "  ", footer: nil)).mode, .standard)
        // A status line Nook chained prints a row of its own: once the script has seen it, it is Claude's footer.
        NookStatusLine.setShownLines(["\u{1B}[36m~/proj\u{1B}[0m main ✓"])
        let chained = ClaudeComposer.split(screen(statusRow: "  ~/proj main ✓"))
        XCTAssertEqual(chained.conversation, "⏺ Listo, lo dejé así.", "Not part of the conversation.")
        XCTAssertEqual(chained.mode?.kind, .auto)
        XCTAssertEqual(ClaudeComposer.split(screen(statusRow: "  ~/proj main ✓", footer: nil)).mode, .standard)
        // Cut short by a narrow terminal, it is still the same row.
        XCTAssertEqual(ClaudeComposer.split(screen(statusRow: "  ~/proj ma…")).conversation, "⏺ Listo, lo dejé así.")
        // The usage panel is found as before.
        XCTAssertNotNil(ClaudeComposer.split(ClaudeUsageFixtures.screen(top: 0, height: 28)).panel)
    }
}
