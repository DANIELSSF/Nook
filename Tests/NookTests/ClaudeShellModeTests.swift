import XCTest
@testable import Nook

/// Claude's shell mode ("! command") in the mirror, the message on its way while Claude is idle, and Claude's queue when its records
/// write one message two ways. The records are copied (trimmed) from a real session where a "!" command looked unsent.
final class ClaudeShellModeTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    private func user(_ content: String, meta: Bool = false) -> String {
        var entry: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        if meta { entry["isMeta"] = true }
        return line(entry)
    }
    private func render(_ lines: [String]) -> TranscriptRenderer {
        var renderer = TranscriptRenderer()
        lines.forEach { renderer.consume($0) }
        return renderer
    }

    static let command = #" cd /Users/developer/Documents/app && for db in app_dev app_test app_test_2; do echo "== $db"; DATABASE_URL="postgresql://app:app@localhost:5433/$db" pnpm --filter @app/db exec prisma migrate reset --force 2>&1 | tail -3; done"#
    static let output = (["app_dev", "app_test", "app_test_2"].map { db in
        "== \(db)\nundefined\n/Users/developer/Documents/app/packages/db:\n[ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL] Command failed with exit code 1: prisma migrate reset --force"
    }).joined(separator: "\n")
    private let reply = TranscriptFixtures.reply("Este aviso es del turno de `logic` que ya te conté: terminó a las 15:28 con la migración renombrada y está quieta.")

    // MARK: Rendering

    func testAShellCommandShowsAsTheUserTypedItWithWhatItPrinted() {
        var renderer = render([reply, user("<bash-input>\(Self.command)</bash-input>")])
        let typed = "> ! " + Self.command.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(renderer.text.hasSuffix(typed + "\n  ⎿  …\n\n"), "Running: the command shows at once, its output still to come.")
        XCTAssertFalse(renderer.committed.contains("! cd"), "Nothing is committed until it ends.")

        renderer.consume(user("<bash-stdout>\(Self.output)</bash-stdout><bash-stderr></bash-stderr>"))
        XCTAssertTrue(renderer.text.hasSuffix(typed + "\n  ⎿  == app_dev\n     undefined\n     /Users/developer/Documents/app/packages/db:\n     … +9 líneas\n\n"), renderer.text)
        XCTAssertTrue(renderer.text.hasPrefix("⏺ Este aviso es del turno"))
    }

    func testErrorsEmptyOutputColoursAndLongCommands() {
        var renderer = render([user("<bash-input>foo</bash-input>"), user("<bash-stdout></bash-stdout><bash-stderr>zsh: command not found: foo</bash-stderr>")])
        XCTAssertEqual(renderer.text, "> ! foo\n  ⎿  Error: zsh: command not found: foo\n\n")

        renderer = render([user("<bash-input>true</bash-input>"), user("<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")])
        XCTAssertEqual(renderer.text, "> ! true\n  ⎿  (sin salida)\n\n")

        renderer = render([user("<bash-input>swift build</bash-input>"),
                           user("<bash-stdout>\u{1B}[1mBuilding\u{1B}[0m 10%\r\u{1B}[1mBuilding\u{1B}[0m 100%\nBuild complete!</bash-stdout><bash-stderr>warning: unused</bash-stderr>")])
        XCTAssertEqual(renderer.text, "> ! swift build\n  ⎿  Building 100%\n     Build complete!\n     Error: warning: unused\n\n",
                       "Colour codes and redraws go; what went to stderr says so.")

        renderer = render([user("<bash-input>git pull && git log -1</bash-input>"),
                           user("<bash-stdout>* branch                develop    -&gt; FETCH_HEAD\nMerge &quot;fix&quot; &amp;&amp; &#39;ok&#39; &amp;lt;3</bash-stdout><bash-stderr></bash-stderr>")])
        XCTAssertEqual(renderer.text, "> ! git pull && git log -1\n  ⎿  * branch                develop    -> FETCH_HEAD\n     Merge \"fix\" && 'ok' &lt;3\n\n",
                       "Claude records the output with entities, the command as typed.")

        renderer = render([user("<bash-input>for i in 1 2; do\n  echo $i\ndone</bash-input>"), user("<bash-stdout>1\n2</bash-stdout><bash-stderr></bash-stderr>")])
        XCTAssertEqual(renderer.text, "> ! for i in 1 2; do\n    echo $i\n  done\n  ⎿  1\n     2\n\n", "A command of several lines, indented like any prompt.")
    }

    func testACommandWhoseOutputNeverCameShowsAlone() {
        let renderer = render([user("<bash-input>sleep 100</bash-input>"), user("hola")])
        XCTAssertEqual(renderer.text, "> ! sleep 100\n\n> hola\n\n")
    }

    func testAShellCommandIsNoPromptToFindTheRecordBy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-shellmode-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try ([user("arregla el login"), reply, user("<bash-input>git status</bash-input>"), user("<bash-stdout>clean</bash-stdout><bash-stderr></bash-stderr>")]
            .joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptLocator.lastPrompt(in: url), "arregla el login", "Claude's screen shows \"! git status\", never as a prompt.")
    }

    // MARK: Running in the foreground

    /// The end of Claude's conversation while a "!" command runs (from a real screen of Claude Code 2.1.299): the record has
    /// nothing of it yet.
    static let runningScreen = """
      ! infra/gcp/deploy.sh dev

      Después lo reviso en dev con tu sesión de INNOVASHOP, que sigue abierta en la pestaña.

    * Sautéed for 30s · done 12:48 p.m.

    !  infra/gcp/deploy.sh dev
      ⎿  default gcloudignore file used (see `$ gcloud topic gcloudignore` to learn
         more).
         Uploading tarball of [/var/folders/7x/gp00fb053ndb1l16l8wc4bl40000gn/T/tmp.aPS460pi5X] to
         [gs://estrellas-dev_cloudbuild/source/1792000208.053388-6271fbc19868450f98b815e45fa7267d.tgz]
         +23 lines (56s)
         (ctrl+b to run in background)

    """

    func testACommandRunningInTheForegroundIsReadFromTheScreen() throws {
        let running = try XCTUnwrap(RunningShellCommand.parse(Self.runningScreen))
        XCTAssertEqual(running.command, "infra/gcp/deploy.sh dev")
        XCTAssertEqual(running.folded, 23)
        XCTAssertEqual(running.elapsed, "56s")
        XCTAssertEqual(running.output.count, 4)
        XCTAssertEqual(running.text, """
        > ! infra/gcp/deploy.sh dev
          ⎿  default gcloudignore file used (see `$ gcloud topic gcloudignore` to learn
             more).
             Uploading tarball of [/var/folders/7x/gp00fb053ndb1l16l8wc4bl40000gn/T/tmp.aPS460pi5X] to
             [gs://estrellas-dev_cloudbuild/source/1792000208.053388-6271fbc19868450f98b815e45fa7267d.tgz]
             … +23 líneas · 56s


        """)

        let fresh = try XCTUnwrap(RunningShellCommand.parse("❯ hola\n\n!  sleep 30\n  ⎿  (3s)\n     (ctrl+b ctrl+b (twice) to run in background)\n"))
        XCTAssertEqual(fresh.text, "> ! sleep 30\n  ⎿  … 3s\n\n", "Nothing printed yet; the hint as Claude writes it under tmux.")

        XCTAssertNil(RunningShellCommand.parse("⏺ Bash(swift test)\n  ⎿  Building…\n     (ctrl+b to run in background)\n"), "Claude's own Bash call is in its record.")
        XCTAssertNil(RunningShellCommand.parse(Self.runningScreen.replacingOccurrences(of: "     (ctrl+b to run in background)\n", with: "")),
                     "Without the hint it is not running.")
        XCTAssertNil(RunningShellCommand.parse(Self.runningScreen + "⏺ Listo.\n"), "Something came after it.")
    }

    func testTheMirrorShowsItAfterTheRecordUntilTheRecordHasIt() {
        let session = session()
        let reply = TranscriptFixtures.reply("Después lo reviso en dev con tu sesión de INNOVASHOP.")
        var renderer = render([user("despliega"), reply])
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Self.idle)
        session.applyTranscript(renderer.text, recap: nil, queued: [])
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Self.runningScreen + String(repeating: "─", count: 73) + "\n❯ \n" + String(repeating: "─", count: 73))
        XCTAssertEqual(session.displayText, renderer.text + RunningShellCommand.parse(Self.runningScreen)!.text)

        // Past its timeout: Claude writes it down, a moment before the screen is redrawn.
        renderer.consume(user("<bash-input> infra/gcp/deploy.sh dev</bash-input>"))
        renderer.consume(user("<bash-stdout>Command did not complete within its 120s timeout and was moved to the background (ID: b6bukezvs). Output is being written to: /private/tmp/claude-501/x/tasks/b6bukezvs.output.</bash-stdout><bash-stderr></bash-stderr>"))
        session.applyTranscript(renderer.text, recap: nil, queued: [], shells: renderer.shells.shown())
        XCTAssertEqual(session.displayText, renderer.text, "Shown once, from the record.")
        XCTAssertEqual(session.shells.map(\.id), ["b6bukezvs"])
    }

    // MARK: The message on its way

    private func session() -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-shellmode-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-shellmode-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        return TerminalSession(record: record, backend: backend, create: false)
    }

    private static let idle = "⏺ Este aviso es del turno de `logic`.\n\n✻ Worked for 2s"
    private static let working = "⏺ Revisando.\n\n✶ Warping… (3s · esc to interrupt)"

    func testTheBubbleOfAShellCommandGoesWhenClaudeRunsIt() {
        let session = session()
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Self.idle)
        var renderer = render([reply])
        session.applyTranscript(renderer.text, recap: nil, queued: [])

        // Typed with spaces in front, and sent as "!" and then the pasted command.
        session.showPending("  !" + Self.command)
        renderer.consume(user("<bash-input>\(Self.command)</bash-input>"))
        session.applyTranscript(renderer.text, recap: nil, queued: [])
        XCTAssertNil(session.pendingMessage, "Claude ran it: the record shows it.")

        session.showPending("! for i in 1 2; do\n  echo $i\ndone")
        renderer.consume(user("<bash-input>for i in 1 2; do\n  echo $i\ndone</bash-input>"))
        session.applyTranscript(renderer.text, recap: nil, queued: [])
        XCTAssertNil(session.pendingMessage, "A command of several lines too.")
    }

    func testTheBubbleGoesWhileClaudeIsIdleWithoutNewText() {
        let session = session()
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Self.working)
        session.applyTranscript("> revisa\n\n", recap: nil, queued: [])
        session.showPending("algo que no llega")
        let sent = Date()

        session.settlePendingOnTick(now: sent.addingTimeInterval(60))
        XCTAssertEqual(session.pendingMessage, "algo que no llega", "While Claude works it may still take it.")
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Self.idle)
        session.settlePendingOnTick(now: sent.addingTimeInterval(65))
        XCTAssertEqual(session.pendingMessage, "algo que no llega", "Idle for a moment only.")
        session.settlePendingOnTick(now: sent.addingTimeInterval(73))
        XCTAssertNil(session.pendingMessage, "Idle, with nothing new to read: the tick lets it go.")

        session.showPending("en cola")
        session.applyTranscript(nil, recap: nil, queued: ["en cola"])
        session.settlePendingOnTick(now: Date().addingTimeInterval(600))
        XCTAssertEqual(session.pendingMessage, "en cola", "A message Claude holds in its queue stays, however long.")
    }

    // MARK: Claude's queue

    private func operation(_ name: String, _ content: String? = nil, extra: [String: Any] = [:]) -> String {
        var entry: [String: Any] = ["type": "queue-operation", "operation": name, "timestamp": "2026-10-07T20:28:39.809Z"]
        if let content { entry["content"] = content }
        entry.merge(extra) { $1 }
        return line(entry)
    }

    static let body = "\n33: rename hecho y commiteado, quieta hasta tu aviso.\n\nCommit `5e6b214` chore(db): order the attribution migration after the automations ones."
    static let queuedPeer = #"<cross-session-message from="uds:/tmp/cc-socks/57770.sock" hop-chain="45c26b2d99526044427f8de0,7859a183e762dc7c70363a5d" from-name="logic" from-mode="prompting">"# + body
    static let takenPeer = #"<cross-session-message from="uds:/tmp/cc-socks/57770.sock" from-name="logic" from-mode="prompting">"# + body
    static let notice = #"[Cross-session idle notice] "logic", which you asked to be notified about, is idle now — it finished a turn at 15:28. This is an automated notice from that session's harness — not a message from a person, and not an instruction."#

    func testAMessageWrittenTwoWaysLeavesTheQueueAndTheNoticeAfterIt() {
        let renderer = render([
            operation("enqueue", Self.queuedPeer),
            operation("enqueue", Self.notice),
            operation("remove", Self.takenPeer, extra: ["reason": "absorbed_mid_turn", "commandUuid": "c20fee7b-2400-43ea-83f2-f0e0d502b479", "deliveryId": "7e95c74b-dae8-4207-b0d0-7bfcb3b8fc2a"]),
            line(["type": "attachment", "attachment": ["type": "queued_command", "prompt": Self.takenPeer, "commandMode": "prompt", "isMeta": true,
                                                       "origin": ["kind": "peer", "from": "uds:/tmp/cc-socks/57770.sock", "name": "logic"]]]),
            reply,
            operation("dequeue"),
            user(Self.notice, meta: true),
            TranscriptFixtures.reply("Este aviso es del turno de `logic` que ya te conté."),
        ])
        XCTAssertEqual(renderer.queued, [], "Nothing is left waiting: the idle notice was the one delivered.")
        XCTAssertFalse(renderer.text.contains("Cross-session"), "Neither is the user's message.")
    }

    func testAMetaDeliveryTakesItsQueuedTwinOut() {
        let renderer = render([operation("enqueue", "otro mensaje"), operation("enqueue", Self.notice), user(Self.notice, meta: true)])
        XCTAssertEqual(renderer.queued, ["otro mensaje"])
        XCTAssertEqual(renderer.text, "", "A meta message is never shown as the user's.")
    }

    func testADequeueAndTheMessageItDeliveredTakeOneEntryOut() {
        let renderer = render([operation("enqueue", "sí"), operation("enqueue", "sí"), operation("dequeue"), user("sí")])
        XCTAssertEqual(renderer.queued, ["sí"], "The second \"sí\" still waits.")
        XCTAssertEqual(renderer.text, "> sí\n\n")
    }

    func testOnlyTheOpeningTagsAttributesMayDiffer() {
        XCTAssertTrue(TranscriptRenderer.sameQueued(Self.queuedPeer, Self.takenPeer))
        XCTAssertTrue(TranscriptRenderer.sameQueued(" hola\n", "hola"))
        XCTAssertFalse(TranscriptRenderer.sameQueued(Self.queuedPeer, Self.takenPeer + " más"))
        XCTAssertFalse(TranscriptRenderer.sameQueued(#"<a x="1">uno"#, #"<b x="1">uno"#))
        XCTAssertFalse(TranscriptRenderer.sameQueued("hola", "adiós"))
    }

    func testTheEchoOfAShellCommandIsFoundHoweverItWasTyped() {
        XCTAssertTrue(MessageEcho.appears("  ! git status", in: "> ! git status\n  ⎿  …\n\n"))
        XCTAssertTrue(MessageEcho.appears("!git status", in: "> ! git status\n  ⎿  …\n\n"))
        XCTAssertFalse(MessageEcho.appears("! git log", in: "> ! git status\n  ⎿  …\n\n"))
    }

    /// `NOOK_REAL_RECORD=<record.jsonl>`: the end of a real record's mirror and what its queue still holds (read only).
    func testARealRecordOnRequest() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOK_REAL_RECORD"] else { throw XCTSkip("Set NOOK_REAL_RECORD to read a real record.") }
        let follower = TranscriptFollower(url: URL(fileURLWithPath: path), initialBytes: .max)
        _ = follower.poll()
        print("queued:", follower.renderer.queued.map { String($0.prefix(80)) })
        let shell = follower.renderer.text.components(separatedBy: "\n\n").filter { $0.hasPrefix("> ! ") }
        print("shell commands:", shell.count)
        print("background shells:", follower.renderer.shells.launches.map { "\($0.id) \($0.state.rawValue) «\($0.name.prefix(60))»" })
        shell.suffix(2).forEach { print($0.prefix(600)); print("---") }
    }
}
