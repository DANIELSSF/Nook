import Darwin
import XCTest
@testable import Nook

/// Background shells read from Claude's record, in the shapes Claude Code 2.1.2xx writes (copied from real records): launches,
/// endings, stops, and what must not count as a shell.
final class BackgroundShellsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let output = "/private/tmp/claude-501/-Users-me-backend/c803ebd3-db4c-4338-b860-3557b27e9225/tasks"

    private func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }

    private func bash(_ id: String, _ input: [String: Any], at seconds: TimeInterval = 0) -> String {
        TranscriptFixtures.json(["type": "assistant", "timestamp": stamp(seconds), "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": id, "name": "Bash", "input": input]]]])
    }

    private func result(_ id: String, _ text: String, details: [String: Any]? = nil, error: Bool = false, at seconds: TimeInterval = 0) -> String {
        var entry: [String: Any] = ["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": [
            ["tool_use_id": id, "type": "tool_result", "content": text, "is_error": error]]]]
        if let details { entry["toolUseResult"] = details }
        return TranscriptFixtures.json(entry)
    }

    /// The launch's answer, word for word.
    private func launched(_ call: String, task: String, at seconds: TimeInterval = 0) -> String {
        result(call, "Command running in background with ID: \(task). Output is being written to: \(output)/\(task).output. You will be notified when it completes. To check interim output, use Read on that file path.\nSession cwd remains /Users/me/backend; directory changes made by the backgrounded command do not apply to subsequent commands.",
               details: ["stdout": "", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false, "backgroundTaskId": task,
                         "backgroundCwdHint": "Session cwd remains /Users/me/backend; directory changes made by the backgrounded command do not apply to subsequent commands."],
               at: seconds)
    }

    private func notification(_ task: String, status: String, summary: String, call: String = "toolu_x") -> String {
        "<task-notification>\n<task-id>\(task)</task-id>\n<tool-use-id>\(call)</tool-use-id>\n<output-file>\(output)/\(task).output</output-file>\n<status>\(status)</status>\n<summary>\(summary)</summary>\n</task-notification>"
    }

    /// Claude writes each notification twice: into its queue as it arrives, then as the user message it becomes.
    private func delivered(_ text: String, at seconds: TimeInterval) -> [String] {
        [TranscriptFixtures.json(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(seconds), "content": text]),
         TranscriptFixtures.json(["type": "user", "timestamp": stamp(seconds), "origin": ["kind": "task-notification"], "promptSource": "system",
                                  "message": ["role": "user", "content": text]])]
    }

    private func renderer(_ lines: [String]) -> TranscriptRenderer {
        var renderer = TranscriptRenderer()
        lines.forEach { renderer.consume($0) }
        return renderer
    }

    // MARK: Launches

    func testABackgroundCommandRunsFromItsLaunchUntilItsNotification() {
        let launch = [
            bash("toolu_01ASrsT9XcBCwEh1JL2PE1PT", ["command": "gcloud builds submit --tag \"$IMAGE\" .", "description": "Build and push the cfcefc7 image via Cloud Build",
                                                     "timeout": 600_000, "run_in_background": true]),
            launched("toolu_01ASrsT9XcBCwEh1JL2PE1PT", task: "bjoijjfvn", at: 1),
        ]
        var renderer = renderer(launch)
        var shells = renderer.shells.shown(now: start.addingTimeInterval(95))
        XCTAssertEqual(shells.count, 1)
        XCTAssertEqual(shells[0].id, "bjoijjfvn")
        XCTAssertEqual(shells[0].name, "Build and push the cfcefc7 image via Cloud Build")
        XCTAssertEqual(shells[0].command, "gcloud builds submit --tag \"$IMAGE\" .")
        XCTAssertEqual(shells[0].state, .running)
        XCTAssertEqual(shells[0].outputPath, "\(output)/bjoijjfvn.output")
        XCTAssertEqual(shells[0].started, start)
        XCTAssertFalse(shells[0].movedToBackground)
        XCTAssertEqual(shells[0].stateText, "en curso")
        XCTAssertEqual(shells[0].detail(at: start.addingTimeInterval(95)), "en curso · 1m 35s")
        XCTAssertEqual(renderer.shells.shown(now: start.addingTimeInterval(96)), shells,
                       "The list doesn't change as a running shell's time passes: its row ticks on its own, nothing is published every second.")

        let done = notification("bjoijjfvn", status: "completed", summary: "Background command \"Build and push the cfcefc7 image via Cloud Build\" completed (exit code 0)",
                                call: "toolu_01ASrsT9XcBCwEh1JL2PE1PT")
        delivered(done, at: 331).forEach { renderer.consume($0) }
        shells = renderer.shells.shown(now: start.addingTimeInterval(400))
        XCTAssertEqual(shells[0].state, .completed)
        XCTAssertEqual(shells[0].exitCode, 0)
        XCTAssertEqual(shells[0].ended, start.addingTimeInterval(331), "Its end is the notification's first arrival.")
        XCTAssertEqual(shells[0].detail(at: start.addingTimeInterval(400)), "terminó · 5m 31s", "Its time stops when it ends.")
        XCTAssertEqual(renderer.shells.shown(now: start.addingTimeInterval(500)), shells, "A finished shell's list stays the same while time passes.")
        XCTAssertTrue(renderer.shells.shown(now: start.addingTimeInterval(331 + 601)).isEmpty, "Finished shells leave after ten minutes.")
        XCTAssertFalse(renderer.text.contains("task-notification"), "The notification stays out of the chat, as before.")
    }

    func testACommandMovedToTheBackgroundAfterItsTimeoutIsAShellFromItsStart() {
        let lines = [
            bash("toolu_01BZas6Fo3jm2ACBPHAdJ3j2", ["command": "cd /Users/me/VIBE && pnpm turbo run test\npnpm lint", "timeout": 300_000], at: 0),
            result("toolu_01BZas6Fo3jm2ACBPHAdJ3j2", "Command did not complete within its 300s timeout and was moved to the background (ID: b27fe3r52). Output is being written to: \(output)/b27fe3r52.output. You will be notified when it completes. If it is still running after 30m in the background, it will be stopped and you will be notified. To check interim output, use Read on that file path.",
                   details: ["stdout": "", "stderr": "", "interrupted": false, "isImage": false, "noOutputExpected": false, "backgroundTaskId": "b27fe3r52", "timedOutAfterMs": 300_000],
                   at: 300),
        ]
        let shell = renderer(lines).shells.shown(now: start.addingTimeInterval(310)).first
        XCTAssertEqual(shell?.id, "b27fe3r52")
        XCTAssertEqual(shell?.name, "cd /Users/me/VIBE && pnpm turbo run test", "Without a description, the command's first line names it.")
        XCTAssertEqual(shell?.started, start, "It has been running since its call.")
        XCTAssertEqual(shell?.movedToBackground, true)
        XCTAssertEqual(shell?.outputPath, "\(output)/b27fe3r52.output")
    }

    func testTheIdIsReadFromTheTextWhenTheDetailsLackIt() {
        let lines = [bash("c1", ["command": "sleep 100", "run_in_background": "true"]),
                     result("c1", "Command running in background with ID: bash_1. Output is being written to: \(output)/bash_1.output.")]
        let shell = renderer(lines).shells.shown(now: start).first
        XCTAssertEqual(shell?.id, "bash_1")
        XCTAssertEqual(shell?.outputPath, "\(output)/bash_1.output")
        XCTAssertEqual(shell?.movedToBackground, false, "\"run_in_background\": \"true\" from newer builds is a background launch too.")

        let moved = [bash("c2", ["command": "swift test"]),
                     result("c2", "Command did not complete within its 120s timeout and was moved to the background (ID: bj74spjc4). Output is being written to: \(output)/bj74spjc4.output. You will be notified when it completes.")]
        XCTAssertEqual(renderer(moved).shells.shown(now: start).first?.id, "bj74spjc4")
        XCTAssertEqual(renderer(moved).shells.shown(now: start).first?.movedToBackground, true)
    }

    func testForegroundCommandsAndOtherToolsAreNoShells() {
        let lines = [bash("c1", ["command": "ls", "description": "List"]), result("c1", "a\nb", details: ["stdout": "a\nb", "stderr": "", "interrupted": false]),
                     bash("c2", ["command": "false", "run_in_background": true]), result("c2", "Error: could not start", error: true),
                     TranscriptFixtures.call("c3", "Monitor", ["command": "tail -f x.log", "description": "watch"]),
                     result("c3", "Monitor started with ID: bj8682qqd", details: ["backgroundTaskId": "bj8682qqd"])]
        XCTAssertTrue(renderer(lines).shells.launches.isEmpty)
    }

    // MARK: Endings

    func testAFailureKeepsItsExitCode() {
        var lines = [bash("toolu_01Gi4T1Zsznvg4Chrm1Nc5tG", ["command": "pnpm gate", "description": "Run lint, typecheck and test gate", "run_in_background": true]),
                     launched("toolu_01Gi4T1Zsznvg4Chrm1Nc5tG", task: "b6648p42q")]
        lines += delivered(notification("b6648p42q", status: "failed", summary: "Background command \"Run lint, typecheck and test gate\" failed with exit code 1"), at: 12)
        let shell = renderer(lines).shells.shown(now: start.addingTimeInterval(20)).first
        XCTAssertEqual(shell?.state, .failed)
        XCTAssertEqual(shell?.exitCode, 1)
        XCTAssertEqual(shell?.stateText, "falló (código 1)")
        XCTAssertEqual(shell?.detail(at: start.addingTimeInterval(20)), "falló (código 1) · 12s")
    }

    func testAStoppedCommandSaysSoAndWhy() {
        var lines = [bash("c1", ["command": "pnpm dev", "description": "Start pnpm dev", "run_in_background": true]), launched("c1", task: "bow7827tc"),
                     bash("c2", ["command": "next build", "description": "Build", "run_in_background": true]), launched("c2", task: "bmem00001")]
        lines += delivered(notification("bow7827tc", status: "killed", summary: "Background command \"Start pnpm dev\" was stopped"), at: 30)
        lines += delivered(notification("bmem00001", status: "killed", summary: "Background command \"Build\" was stopped because the system is running low on memory"), at: 40)
        let shells = renderer(lines).shells.shown(now: start.addingTimeInterval(50))
        XCTAssertEqual(shells.map(\.state), [.stopped, .stopped])
        XCTAssertEqual(shells.map(\.stateText), ["detenido", "detenido (sin memoria)"])
    }

    func testTaskStopEndsTheShellItNames() {
        let lines = [bash("c1", ["command": "caffeinate -dims", "run_in_background": true]), launched("c1", task: "b5kaobp6m", at: 1),
                     TranscriptFixtures.call("c2", "TaskStop", ["task_id": "b5kaobp6m"]),
                     result("c2", #"{"message":"Successfully stopped task: b5kaobp6m (caffeinate -dims)","task_id":"b5kaobp6m","task_type":"local_bash","command":"caffeinate -dims"}"#,
                            details: ["message": "Successfully stopped task: b5kaobp6m (caffeinate -dims)", "task_id": "b5kaobp6m", "task_type": "local_bash", "command": "caffeinate -dims"],
                            at: 60)]
        let shell = renderer(lines).shells.shown(now: start.addingTimeInterval(61)).first
        XCTAssertEqual(shell?.state, .stopped)
        XCTAssertEqual(shell?.ended, start.addingTimeInterval(60))
        XCTAssertEqual(shell?.detail(at: start.addingTimeInterval(61)), "detenido · 1m 0s")
    }

    func testKillShellOfOlderBuildsEndsItToo() {
        let lines = [bash("c1", ["command": "npm run watch", "run_in_background": true]),
                     result("c1", "Command running in background with ID: bash_2"),
                     TranscriptFixtures.call("c2", "KillShell", ["shell_id": "bash_2"]),
                     result("c2", #"{"message":"Successfully killed shell: bash_2 (npm run watch)","shell_id":"bash_2"}"#)]
        XCTAssertEqual(renderer(lines).shells.shown(now: start).first?.state, .stopped)
    }

    func testAStopThatFailedOrNamesAnotherTaskChangesNothing() {
        let lines = [bash("c1", ["command": "sleep 9", "run_in_background": true]), launched("c1", task: "bsleep001"),
                     TranscriptFixtures.call("c2", "TaskStop", ["task_id": "bsleep001"]), result("c2", "No running task with ID bsleep001", error: true),
                     TranscriptFixtures.call("c3", "TaskStop", ["task_id": "a1c81ddd1e8c47fb4"]),
                     result("c3", "{}", details: ["message": "Successfully stopped task: a1c81ddd1e8c47fb4 (security re-audit)", "task_id": "a1c81ddd1e8c47fb4", "task_type": "local_agent"]),
                     TranscriptFixtures.call("c4", "TaskStop", ["task_id": "bunknown1"]),
                     result("c4", "{}", details: ["message": "Successfully stopped task: bunknown1 (x)", "task_id": "bunknown1", "task_type": "local_bash"])]
        let renderer = renderer(lines)
        XCTAssertEqual(renderer.shells.launches.map(\.id), ["bsleep001"], "A stop of a task nobody knows adds nothing.")
        XCTAssertEqual(renderer.shells.launches.first?.state, .running)
    }

    // MARK: What is not a shell's ending

    func testAgentAndMonitorNotificationsAreNoShells() {
        var lines = [TranscriptFixtures.call("toolu_agent", "Agent", ["description": "Check Claude in Chrome Edge support", "prompt": "…", "run_in_background": true]),
                     result("toolu_agent", "Async agent launched successfully.\nagentId: a0a02367c1cae46f8 (internal ID)")]
        lines += delivered(notification("a0a02367c1cae46f8", status: "completed", summary: "Agent \"Check Claude in Chrome Edge support\" finished"), at: 5)
        lines += delivered(notification("bj8682qqd", status: "completed", summary: "Monitor \"CI checks on PR 378\" stream ended") + "\nIf this event is something the user would act on now, send a PushNotification.", at: 6)
        lines += delivered(notification("wf1", status: "completed", summary: "Workflow \"release\" completed"), at: 7)
        let renderer = renderer(lines)
        XCTAssertTrue(renderer.shells.launches.isEmpty)
        XCTAssertEqual(renderer.agents.launches.first?.state, .done, "The agent still ends as before.")
    }

    func testABackgroundCommandLaunchedBeforeWhatWasReadJoinsWhenItEnds() {
        let lines = delivered(notification("bjoijjfvn", status: "completed", summary: "Background command \" Build and push the \"cfcefc7\" image\" completed (exit code 0)"), at: 100)
        let shells = renderer(lines).shells.shown(now: start.addingTimeInterval(120))
        XCTAssertEqual(shells.count, 1, "Written twice, joined once.")
        XCTAssertEqual(shells.first?.name, "Build and push the \"cfcefc7\" image")
        XCTAssertEqual(shells.first?.command, "")
        XCTAssertEqual(shells.first?.state, .completed)
        XCTAssertNil(shells.first?.started)
        XCTAssertNil(shells.first?.duration(at: start.addingTimeInterval(120)), "No start, no time.")
        XCTAssertEqual(shells.first?.outputPath, "\(output)/bjoijjfvn.output", "Its output can still be read.")
        XCTAssertEqual(shells.first?.detail(), "terminó")
    }

    func testANotificationQuotedInAReplyOrAToolResultEndsNothing() {
        let quoted = notification("bjoijjfvn", status: "completed", summary: "Background command \"Build\" completed (exit code 0)")
        let lines = [bash("c1", ["command": "make", "description": "Build", "run_in_background": true]), launched("c1", task: "bjoijjfvn"),
                     TranscriptFixtures.call("c2", "Grep", ["pattern": "task-notification"]), result("c2", quoted),
                     TranscriptFixtures.reply("Esto llegó: " + quoted)]
        XCTAssertEqual(renderer(lines).shells.launches.first?.state, .running)
    }

    func testANotificationInAQueuedCommandEndsTheShell() {
        let lines = [bash("c1", ["command": "make", "description": "Build", "run_in_background": true]), launched("c1", task: "bq0000001"),
                     TranscriptFixtures.json(["type": "attachment", "timestamp": stamp(9), "attachment": ["type": "queued_command", "commandMode": "task-notification",
                                                                                             "origin": ["kind": "task-notification"],
                                                                                             "prompt": notification("bq0000001", status: "failed", summary: "Background command \"Build\" failed with exit code 2")]])]
        let shell = renderer(lines).shells.launches.first
        XCTAssertEqual(shell?.state, .failed)
        XCTAssertEqual(shell?.exitCode, 2)
    }

    func testSeveralNotificationsInOneMessageAndUnknownWords() {
        var lines = [bash("c1", ["command": "a", "run_in_background": true]), launched("c1", task: "baaaaaaa1"),
                     bash("c2", ["command": "b", "run_in_background": true]), launched("c2", task: "bbbbbbbb2"),
                     bash("c3", ["command": "c", "run_in_background": true]), launched("c3", task: "bcccccccc")]
        lines += delivered(notification("baaaaaaa1", status: "completed", summary: "Background command \"a\" completed (exit code 0)") + "\n"
                           + notification("bbbbbbbb2", status: "cancelled", summary: "Background command \"b\" was cancelled")
                           + notification("bcccccccc", status: "running", summary: "progress"), at: 3)
        XCTAssertEqual(renderer(lines).shells.launches.map(\.state), [.completed, .stopped, .running], "An unknown ending stops it; \"running\" is no ending.")
    }

    func testMalformedNotificationsAndIdsAreIgnored() {
        let lines = delivered("<task-notification><task-id>../../etc</task-id><status>completed</status><summary>Background command \"x\" completed</summary></task-notification>"
                              + "<task-notification><task-id>bnostatus</task-id><summary>Background command \"y\" completed</summary>"
                              + "<task-notification><status>failed</status></task-notification>", at: 1)
        XCTAssertTrue(renderer(lines).shells.launches.isEmpty)
    }

    func testFinishedShellsBeyondTheLatestThirtyAreHistory() {
        var lines: [String] = []
        for index in 0..<45 {
            lines.append(bash("c\(index)", ["command": "job \(index)", "run_in_background": true]))
            lines.append(launched("c\(index)", task: "b\(index)"))
            if index > 0 { lines += delivered(notification("b\(index)", status: "completed", summary: "Background command \"job\" completed (exit code 0)"), at: 2) }
        }
        let launches = renderer(lines).shells.launches
        XCTAssertEqual(launches.filter { $0.state != .running }.count, TranscriptShells.finishedLimit)
        XCTAssertEqual(launches.first?.id, "b0", "A running one is never dropped.")
    }

    /// `NOOK_REAL_RECORD=<record.jsonl>`: every shell of a real record, and the end of the newest one's output (read only).
    func testARealRecordOnRequest() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOK_REAL_RECORD"] else { throw XCTSkip("Set NOOK_REAL_RECORD to read a real record.") }
        let follower = TranscriptFollower(url: URL(fileURLWithPath: path), initialBytes: .max)
        _ = follower.poll()
        let all = follower.renderer.shells.launches
        print("shells:", all.count, "running:", all.filter { $0.state == .running }.map(\.id))
        for shell in all { print("·", shell.id, "|", shell.name.prefix(60), "|", shell.state, shell.exitCode.map(String.init) ?? "", shell.note ?? "", "|", shell.movedToBackground ? "moved" : "bg", "|", shell.outputPath ?? "—") }
        guard let newest = all.last else { return }
        let output = follower.shellOutput(id: newest.id, epoch: 1)
        print("output of", newest.id, "available:", output?.available ?? false, "clipped:", output?.clipped ?? false)
        print(output?.text.suffix(600) ?? "")
    }

    // MARK: Claude's mode line

    func testTheModeLineCountsShells() {
        XCTAssertEqual(ShellActivity.count(inHints: ["1 shell", "↓ to manage"]), 1)
        XCTAssertEqual(ShellActivity.count(inHints: ["shift+tab to cycle", "3 shells"]), 3)
        XCTAssertNil(ShellActivity.count(inHints: ["2 background agents", "← for agents"]))
        XCTAssertEqual(ClaudeMode.parse("⏵⏵ auto mode on · 1 shell · ↓ to manage").map { ShellActivity.count(inHints: $0.hints) }, 1)
    }

    func testStateWords() {
        var shell = ShellActivity(id: "b", name: "x", command: "x", state: .completed)
        XCTAssertEqual(shell.stateText, "terminó")
        shell.exitCode = 0
        XCTAssertEqual(shell.stateText, "terminó")
        shell.state = .failed; shell.exitCode = nil
        XCTAssertEqual(shell.stateText, "falló")
        shell.exitCode = 143
        XCTAssertEqual(shell.stateText, "falló (código 143)")
        shell.state = .stopped; shell.exitCode = nil
        XCTAssertEqual(shell.detail(), "detenido")
    }
}

/// A shell's output as the island shows it: cleaned the way a terminal leaves it, read from its end and then only what was appended,
/// and only from files Claude Code itself writes.
final class ShellOutputTests: XCTestCase {
    private var folder: URL!
    /// Stands for `/private/tmp/claude-<uid>`.
    private var root: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-shells-\(UUID().uuidString.prefix(8))")
        root = folder.appendingPathComponent("claude-\(getuid())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-me-app/session/tasks"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent("-Users-me-app/session/tasks/\(name)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func append(_ text: String, to url: URL) throws { try append(Data(text.utf8), to: url) }

    // MARK: Cleaning

    func testColourCodesGo() {
        // From a real deploy script's output.
        XCTAssertEqual(ShellOutputText.clean("\u{1B}[1m▶ 1/10 origin/develop\u{1B}[0m"), "▶ 1/10 origin/develop")
        XCTAssertEqual(ShellOutputText.clean("\u{1B}[0;36m156 |\u{1B}[0;0m /* Uses NSIntegralRectWithOptions() */"), "156 | /* Uses NSIntegralRectWithOptions() */")
        XCTAssertEqual(ShellOutputText.clean("plain\ttext ñ ✓"), "plain\ttext ñ ✓", "Plain text and tabs stay as they are.")
    }

    func testACarriageReturnDrawsOverTheLine() {
        XCTAssertEqual(ShellOutputText.clean("Downloading  10%\rDownloading  55%\rDownloading 100%"), "Downloading 100%")
        XCTAssertEqual(ShellOutputText.clean("compiling 3/9…\r\u{1B}[Kdone"), "done", "Erased to the end, then written.")
        XCTAssertEqual(ShellOutputText.clean("\u{1B}[2K\r[####----] 50%\r\u{1B}[2K[########] 100%"), "[########] 100%")
        XCTAssertEqual(ShellOutputText.clean("windows line\r"), "windows line", "A line ending \\r\\n keeps its text.")
        XCTAssertEqual(ShellOutputText.clean("ab\u{8}c"), "ac", "A backspace steps back.")
        XCTAssertEqual(ShellOutputText.clean("abc\u{1B}[2Dz"), "azc")
    }

    func testOtherCodesAndUnfinishedOnesGo() {
        XCTAssertEqual(ShellOutputText.clean("\u{1B}]0;build — zsh\u{07}ready"), "ready", "A window title.")
        XCTAssertEqual(ShellOutputText.clean("\u{1B}]8;;https://x.dev\u{1B}\\link\u{1B}]8;;\u{1B}\\ text"), "link text", "A hyperlink keeps its words.")
        XCTAssertEqual(ShellOutputText.clean("\u{1B}(Bbell\u{07} \u{1B}=ok\u{0}"), "bell ok")
        XCTAssertEqual(ShellOutputText.clean("half\u{1B}[3"), "half", "A code still being written.")
        XCTAssertEqual(ShellOutputText.clean("x\u{9B}31my"), "xy", "The one-byte form of a code.")
    }

    // MARK: Following the file

    func testReadsWhatWasAppendedAndKeepsTheUnfinishedLineLive() throws {
        let url = try file("b1.output", "\u{1B}[32m✓\u{1B}[0m step 1\nstep 2\n")
        let tail = try XCTUnwrap(ShellOutputTail(path: url.path, roots: [root.path]))
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.text, "✓ step 1\nstep 2\n")
        XCTAssertFalse(tail.clipped)
        XCTAssertFalse(tail.poll(), "Nothing new: nothing read.")
        let version = tail.version

        try append("progress 10%", to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "✓ step 1\nstep 2\nprogress 10%")
        try append("\rprogress 60%", to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "✓ step 1\nstep 2\nprogress 60%", "The bar's newest frame, over the last one.")
        try append("\rprogress 100%\nstep 3\n", to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "✓ step 1\nstep 2\nprogress 100%\nstep 3\n")
        XCTAssertGreaterThan(tail.version, version)
    }

    func testACharacterSplitBetweenReadingsArrivesWhole() throws {
        let url = try file("b2.output", "a")
        let tail = try XCTUnwrap(ShellOutputTail(path: url.path, roots: [root.path]))
        try append(Data([0xC3]), to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "a", "Half a character is not shown.")
        try append(Data([0xB1]) + Data("o\n".utf8), to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "año\n")
    }

    func testALongOutputIsReadFromItsEndAndKeptUnderItsLimit() throws {
        let lines = (0..<2_000).map { "line \($0) " + String(repeating: "x", count: 40) }
        let url = try file("b3.output", lines.joined(separator: "\n") + "\n")
        let tail = try XCTUnwrap(ShellOutputTail(path: url.path, limit: 10_000, roots: [root.path]))
        tail.poll()
        XCTAssertTrue(tail.clipped, "Earlier output was left out.")
        XCTAssertLessThanOrEqual(tail.text.utf16.count, 10_000)
        XCTAssertTrue(tail.text.hasPrefix("line "), "It starts at a line's start, not in the middle of one.")
        XCTAssertTrue(tail.text.hasSuffix(lines.last! + "\n"))

        // Appended little by little, it never grows past its limit.
        for index in 0..<400 { try append("more \(index) " + String(repeating: "y", count: 50) + "\n", to: url); tail.poll() }
        XCTAssertLessThan(tail.text.utf16.count, 10_000 + 100)
        XCTAssertTrue(tail.text.hasSuffix("more 399 " + String(repeating: "y", count: 50) + "\n"))
        XCTAssertFalse(tail.text.contains("more 0 "), "The oldest went.")

        // More than a reading keeps at once: only its end is read.
        try append((0..<3_000).map { "burst \($0)" }.joined(separator: "\n") + "\n", to: url)
        tail.poll()
        XCTAssertTrue(tail.text.hasSuffix("burst 2999\n"))
        XCTAssertFalse(tail.text.contains("more 399"), "What came before the burst's end is skipped.")
        XCTAssertLessThanOrEqual(tail.text.utf16.count, 10_000)
    }

    func testAnEndlessLineIsCutAtItsLastRedraw() throws {
        let url = try file("b4.output")
        let tail = try XCTUnwrap(ShellOutputTail(path: url.path, roots: [root.path]))
        let frames = (0..<20_000).map { "\r[\($0)]" }.joined()
        try append(frames, to: url)
        tail.poll()
        XCTAssertEqual(tail.text, "[19999]")
        try append(String(repeating: "z", count: ShellOutputTail.partialLimit + 10), to: url)
        tail.poll()
        XCTAssertLessThanOrEqual(tail.text.utf8.count, ShellOutputTail.partialLimit + 1, "A line with no end and no redraw is ended.")
    }

    // MARK: Which files may be read

    func testOnlyPlainFilesOfTheUserInsideClaudesFolderAreRead() throws {
        let good = try file("bgood0001.output", "ok\n")
        let roots = [root.path]
        XCTAssertEqual(ShellOutputFile.validated(good.path, roots: roots), realpath(good.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) },
                       "Its path with every link resolved.")

        // A link, wherever it points: Claude's subagent outputs are links to their records.
        let target = try file("btarget01.output", "secret\n")
        let link = root.appendingPathComponent("-Users-me-app/session/tasks/blink0001.output")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(ShellOutputFile.validated(link.path, roots: roots))
        let outsideTarget = folder.appendingPathComponent("private.txt")
        try Data("secret".utf8).write(to: outsideTarget)
        let away = root.appendingPathComponent("-Users-me-app/session/tasks/baway0001.output")
        try FileManager.default.createSymbolicLink(at: away, withDestinationURL: outsideTarget)
        XCTAssertNil(ShellOutputFile.validated(away.path, roots: roots))

        // A folder inside the root that links outside of it.
        let outside = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("b.output"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertNil(ShellOutputFile.validated(root.appendingPathComponent("escape/b.output").path, roots: roots))
        XCTAssertNil(ShellOutputFile.validated(outside.appendingPathComponent("b.output").path, roots: roots), "Outside the root.")

        XCTAssertNil(ShellOutputFile.validated(root.path + "/-Users-me-app/session/tasks/../../../elsewhere-b.output", roots: roots), "No climbing.")
        XCTAssertNil(ShellOutputFile.validated("-Users-me-app/session/tasks/bgood0001.output", roots: roots), "Only a full path.")
        let wrong = try file("notes.txt", "x")
        XCTAssertNil(ShellOutputFile.validated(wrong.path, roots: roots), "Only \".output\".")
        let folderNamed = root.appendingPathComponent("-Users-me-app/session/tasks/bdir00001.output")
        try FileManager.default.createDirectory(at: folderNamed, withIntermediateDirectories: true)
        XCTAssertNil(ShellOutputFile.validated(folderNamed.path, roots: roots), "Not a folder.")
        let fifo = root.appendingPathComponent("-Users-me-app/session/tasks/bfifo0001.output")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(ShellOutputFile.validated(fifo.path, roots: roots), "Not a pipe, which would block the reading.")
        XCTAssertNil(ShellOutputTail(path: fifo.path, roots: roots))
        let hard = root.appendingPathComponent("-Users-me-app/session/tasks/bhard0001.output")
        try FileManager.default.linkItem(at: outsideTarget, to: hard)
        XCTAssertNil(ShellOutputFile.validated(hard.path, roots: roots), "Not a second name of another file.")
        XCTAssertNil(ShellOutputFile.validated(good.path, roots: roots, owner: getuid() + 1), "Only the user's own files.")
        XCTAssertNil(ShellOutputFile.validated(good.path, roots: [folder.appendingPathComponent("missing").path]))
    }

    func testARootThatIsALinkIsNotTrusted() throws {
        let linked = folder.appendingPathComponent("claude-link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        let good = try file("bgood0002.output", "ok\n")
        XCTAssertNil(ShellOutputFile.validated(linked.path + "/-Users-me-app/session/tasks/bgood0002.output", roots: [linked.path]),
                     "Someone else may leave a link named like the user's folder in the shared temporary directory.")
        XCTAssertNotNil(ShellOutputFile.validated(good.path, roots: [root.path]))
    }

    func testTheRealRootsAreTheUsersClaudeFolders() {
        XCTAssertEqual(ShellOutputFile.roots, ["/private/tmp/claude-\(getuid())", "/tmp/claude-\(getuid())"])
        XCTAssertNil(ShellOutputFile.validated("/etc/passwd"))
        XCTAssertNil(ShellOutputFile.validated("/private/tmp/claude-\(getuid())/../../etc/x.output"))
    }

    // MARK: Through Claude's record

    private func record(_ lines: [String]) throws -> URL {
        let url = folder.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func launch(_ task: String, path: String) -> [String] {
        [TranscriptFixtures.call("c-\(task)", "Bash", ["command": "pnpm dev", "description": "Dev server", "run_in_background": true]),
         TranscriptFixtures.result("c-\(task)", "Command running in background with ID: \(task). Output is being written to: \(path). You will be notified when it completes.",
                                   details: ["backgroundTaskId": task])]
    }

    func testTheFollowerReadsTheViewedShellOnlyAndOnlyWhatChanged() throws {
        let out = try file("bdev00001.output", "ready on :3000\n")
        let follower = TranscriptFollower(url: try record(launch("bdev00001", path: out.path)))
        follower.shellRoots = [root.path]
        _ = follower.poll()
        XCTAssertEqual(follower.shells().map(\.id), ["bdev00001"])
        XCTAssertEqual(follower.watchedShellOutputs, 0, "No output is read until a shell is viewed.")

        XCTAssertEqual(follower.shellOutput(id: "bdev00001", epoch: 1), ShellOutput(text: "ready on :3000\n"))
        XCTAssertEqual(follower.watchedShellOutputs, 1)
        XCTAssertNil(follower.shellOutput(id: "bdev00001", epoch: 1), "Nothing new: nothing handed over.")
        try append("GET / 200\n", to: out)
        XCTAssertEqual(follower.shellOutput(id: "bdev00001", epoch: 1)?.text, "ready on :3000\nGET / 200\n")
        XCTAssertEqual(follower.shellOutput(id: "bdev00001", epoch: 2)?.text, "ready on :3000\nGET / 200\n", "Entered again: handed over again.")
        XCTAssertNil(follower.shellOutput(id: nil))
        XCTAssertEqual(follower.watchedShellOutputs, 0, "Left: its reader goes.")
    }

    func testAShellWhoseOutputMayNotBeReadSaysSoOnce() throws {
        let outside = folder.appendingPathComponent("bout00001.output")
        try Data("x\n".utf8).write(to: outside)
        let follower = TranscriptFollower(url: try record(launch("bout00001", path: outside.path)))
        follower.shellRoots = [root.path]
        _ = follower.poll()
        XCTAssertEqual(follower.shellOutput(id: "bout00001", epoch: 1), ShellOutput(available: false))
        XCTAssertNil(follower.shellOutput(id: "bout00001", epoch: 1))
        XCTAssertEqual(follower.shellOutput(id: "bnobody01", epoch: 2), ShellOutput(available: false), "A shell the record doesn't know.")
        XCTAssertEqual(follower.watchedShellOutputs, 0)
    }
}

/// Entering a shell's output and coming back, beside the agents' view.
@MainActor
final class ShellViewTests: XCTestCase {
    private func model() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-shellview-" + UUID().uuidString)!)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.loginStampsReader = { [:] }
        return model
    }

    private func tab(_ tty: String, processes: [String] = ["claude"], text: String? = nil) -> TerminalTabSnapshot {
        let rule = String(repeating: "─", count: 60)
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: processes, busy: false, selected: true,
                                      text: text ?? ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on · 1 shell · ↓ to manage"].joined(separator: "\n"))
        tab.history = true
        return tab
    }

    private func shell(_ id: String = "bdev00001", state: ShellActivity.State = .running) -> ShellActivity {
        ShellActivity(id: id, name: "Dev server", command: "pnpm dev", state: state, started: Date())
    }

    private func claudeSession(_ model: AppModel, tty: String = "/dev/ttys180") -> TerminalSession {
        let session = TerminalSession(tab: tab(tty), backend: .bundled, bridge: model.terminalBridge)
        session.transcriptLocated = Date()
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil, agents: [SubagentActivity(id: "call-a", name: "Diseñar", state: .running)], shells: [shell()])
        return session
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testEnteringAShellAndLeavingIt() {
        let model = model()
        let session = claudeSession(model)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertEqual(session.shells.map(\.id), ["bdev00001"])
        XCTAssertEqual(session.screenShellCount, 1, "Claude's mode line counts it too.")

        model.openShell(session.shells[0], in: session)
        XCTAssertEqual(session.viewedShell, "bdev00001")
        XCTAssertNil(session.shellOutput, "Nothing until its first reading.")
        XCTAssertEqual(session.displayText, "> pregunta\n\n⏺ respuesta\n\n", "The conversation stays ready for coming back.")
        session.applyShellOutput(ShellOutput(text: "otra\n"), id: "bnobody01")
        XCTAssertNil(session.shellOutput, "A late reading of another shell never shows.")
        session.applyShellOutput(ShellOutput(text: "ready\n"), id: "bdev00001")
        XCTAssertEqual(session.shellOutput?.text, "ready\n")

        XCTAssertTrue(model.leaveAgentView(), "Esc leaves the shell's output.")
        XCTAssertNil(session.viewedShell)
        XCTAssertNil(session.shellOutput)
        XCTAssertFalse(model.leaveAgentView(), "A second Esc is the island's.")
    }

    func testAShellAndAnAgentAreNeverShownTogether() {
        let model = model()
        let session = claudeSession(model)
        model.sessions = [session]; model.selectedID = session.id
        model.openAgent(session.subagents[0], in: session)
        session.applyAgentText("> tarea\n\n", call: "call-a")
        model.openShell(session.shells[0], in: session)
        XCTAssertNil(session.viewedAgent)
        XCTAssertEqual(session.viewedShell, "bdev00001")
        XCTAssertEqual(session.displayText, "> pregunta\n\n⏺ respuesta\n\n", "The agent's conversation gave way to Claude's.")
        model.openAgent(session.subagents[0], in: session)
        XCTAssertEqual(session.viewedAgent, "call-a")
        XCTAssertNil(session.viewedShell)
        XCTAssertNil(session.shellOutput)
    }

    func testSwitchingTabsAndClaudeLeavingEndTheShellView() {
        let model = model()
        let first = claudeSession(model, tty: "/dev/ttys181")
        let second = claudeSession(model, tty: "/dev/ttys182")
        model.sessions = [first, second]; model.selectedID = first.id
        model.openShell(first.shells[0], in: first)
        model.select(second)
        XCTAssertNil(first.viewedShell, "Picking another tab goes back to Claude's conversation.")

        model.openShell(second.shells[0], in: second)
        XCTAssertEqual(model.selectedID, second.id)
        second.transcript = TranscriptFollower(url: URL(fileURLWithPath: "/dev/null"))
        second.update(tab("/dev/ttys182", processes: ["zsh"], text: "$ ls"))
        XCTAssertNil(second.viewedShell)
        XCTAssertTrue(second.shells.isEmpty, "Without Claude's record there are no shells.")
    }

    func testHiddenTabsDropTheOutputAndReadItAgain() {
        let model = model()
        let session = claudeSession(model)
        model.sessions = [session]; model.selectedID = session.id
        model.openShell(session.shells[0], in: session)
        session.applyShellOutput(ShellOutput(text: String(repeating: "x", count: 100_000)), id: "bdev00001")
        model.expanded = false
        model.trimMemory(.pressure)
        XCTAssertNil(session.shellOutput, "Its output goes while nobody looks…")
        XCTAssertEqual(session.viewedShell, "bdev00001", "…and the shell stays entered, read again when the island opens.")
    }

    /// The whole path: Claude's record names the shell, the viewed shell's file is read off the main thread, and both arrive.
    func testTheRecordAndTheOutputArriveThroughTheReading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-shellflow-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("claude-\(getuid())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        let out = root.appendingPathComponent("tasks/bflow0001.output")
        try Data("\u{1B}[32mready\u{1B}[0m\n".utf8).write(to: out)
        let record = folder.appendingPathComponent("s.jsonl")
        try ([TranscriptFixtures.call("c1", "Bash", ["command": "pnpm dev", "description": "Dev server", "run_in_background": true]),
              TranscriptFixtures.result("c1", "Command running in background with ID: bflow0001. Output is being written to: \(out.path). You will be notified when it completes.",
                                        details: ["backgroundTaskId": "bflow0001"])].joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)

        let model = model()
        let session = TerminalSession(tab: tab("/dev/ttys183"), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        let follower = TranscriptFollower(url: record)
        follower.shellRoots = [root.path]
        session.transcript = follower
        model.followTranscript(session)
        settle()
        XCTAssertEqual(session.shells.map(\.name), ["Dev server"])
        XCTAssertEqual(session.shells.first?.state, .running)

        model.view(shell: "bflow0001", in: session)
        settle()
        XCTAssertEqual(session.shellOutput, ShellOutput(text: "ready\n"))
        XCTAssertEqual(follower.watchedShellOutputs, 1)

        // Left and entered again before the next reading: the output still comes back, though nothing new was written.
        session.view(shell: nil)
        session.view(shell: "bflow0001")
        XCTAssertNil(session.shellOutput)
        model.followTranscript(session)
        settle()
        XCTAssertEqual(session.shellOutput?.text, "ready\n")

        // Collapsed, nothing is read for it.
        model.followTranscript(session, showingText: false)
        settle()
        XCTAssertEqual(follower.watchedShellOutputs, 0)
    }
}
