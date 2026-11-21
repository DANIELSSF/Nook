import XCTest
@testable import Nook

/// 21/11 00:11 and 00:12 (deliveries.log): a question and some sixty pasted lines (Markdown, backticks, a `<system-reminder>`, quoted
/// lines, file paths, and three screenshots' paths quoted from an earlier message) went to Claude Code 2.1.330 in a Terminal tab.
/// Claude collapsed the paste to "[Pasted text #N +66 lines]" and took it on the paste's own Return, both times (its record has the
/// message twice, as `<pasted_content>`). Nook counted the three paths as images, so it waited for the message's words in the box or
/// in the chat, saw neither, and gave the message back to the field: "8.3s no apareció en la caja en 8 s; sin Enter, no enviado".
/// The user sent it again.
final class CollapsedPasteDeliveryTests: XCTestCase {
    static let rule = String(repeating: "─", count: 120)
    static let footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
    static let suggestion = "avísame cuando termine y reinicia la app"
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1, images: 5)
    private let quiet = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.3, hold: 0.05, settle: 0.1, images: 0.3)

    /// A message shaped like that one (not its words): a short question, then a pasted summary with the same kinds of lines.
    static let message: String = {
        let folder = MessageAttachments.folder
        let pasted = """
            This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion.

            Summary:
            1. Primary Request and Intent:
               - Make the copy buttons of the mirror **discreet**, the same in the light and the dark island.
               - Keep `TranscriptStyle.swift` the only place that styles a message; nothing inline.

            2. Key Technical Concepts:
               - `MirrorCopy` builds the Markdown that goes to the clipboard (fences, quotes, tables).
               - The mirror draws blocks with `TranscriptBlocks`; a table keeps its columns.
               - Screenshots: `blocks-dark-540.png`, `blocks-light-540.png`, `copy-buttons-dark.png`.

            3. Files and Code Sections:
               - /Users/example/Projects/Nook/Sources/Nook/MirrorCopy.swift
                 - Added `copyMarkdown(for:)`, which keeps ``` fences ``` and `> quotes`.
               - /Users/example/Projects/Nook/Sources/Nook/TranscriptBlocks.swift
                 - `Block.code(language:text:)` carries its language for the copy.
               - /Users/example/Projects/Nook/Tests/NookTests/MirrorCopyTests.swift
                 - Covers a quote (`> hola`), a fence and a table.

            4. Errors and fixes:
               - "Cannot assign to property: 'copied' is a 'let' constant": made it `@State private var copied = false`.
               - The button flickered on hover: the tint now waits 150 ms (`.easeOut(duration: 0.15)`).

            5. Problem Solving:
               - A long reply scrolled under the composer; the mirror keeps 12 pt of room at its end.
               - Copying a table gave tabs; it gives Markdown pipes now: `| a | b |`.

            6. All user messages:
              <system-reminder>
              The user sent the following messages while you were working:
                 - "en el mensaje de claude quiero un botón para copiar en markdown, mira la primera imagen \(folder)imagen-pantalla-20261120-211607.png
             \(folder)imagen-pantalla-20261120-211700.png
             \(folder)imagen-pantalla-20261120-211751.png"
                 - "que también resalte el color del comando cuando lo copio \(folder)imagen-pantalla-20261120-212152.png
             \(folder)imagen-pantalla-20261120-212210.png"
              </system-reminder>

            7. Pending Tasks:
               > Check both themes at 540 and 900 points wide.
               > Run `swift test --filter MirrorCopyTests` and the render tests.
               > Ask before restarting Nook: "¿lo reinicio ahora?"

            8. Current Work:
               - The quote button: rest, live and copied, in both themes (`quote-button-{rest,live,copied}-{dark,light}.png`).
               - Its tooltip says what it copies; the icon alone stands next to «Resumen».

            9. Optional Next Step:
               - Show only the icon beside «Resumen», with its name on hover.
               - Then the same for the summary of a compaction:
                 ```swift
                 Button { copy(block) } label: { Image(systemName: "doc.on.doc") }
                     .help("Copiar en Markdown")
                 ```
               - And a last look at both widths.
               - Nothing else is pending.

            Notes for whoever goes on:
               - Never touch `LiveTerminalScrollView.swift` without asking.
               - `C:\\Users\\nobody` paths stay text; "quotes" & <tags> & 100% stay as written.
               - Emoji in a reply (✅, 🚀) keep their width in the mirror.
               - The last build is in .build/arm64-apple-macosx/debug.

            If you need specific details from before compaction (like exact code snippets, error messages, or content you generated), read the full transcript.
            Recent messages are preserved verbatim.
            """
        return "lo mismo pasa cuando una sesión se queda quieta mucho rato: sale este mensaje gigante, ¿se puede resumir?\n\n" + pasted
    }()

    /// Claude Code 2.1.330 in a Terminal tab, as its paste handler and the record of 21/11 show it: a paste of more than two lines, or
    /// one longer than 800 characters, becomes "[Pasted text #N +M lines]" in its box (image paths inside it stay text), and its echo
    /// in the chat is that placeholder, never the words. Terminal's Return after the paste sends it at once, before any reading can
    /// catch the box, unless `holdsPaste` (the Return got lost in the paste: the box keeps it for an Enter). A typed message shows in
    /// the box for a reading, then its Return sends it. `scrolls`: the chat holds a screen's worth, so an echo pushes its oldest two
    /// lines out (there, an older "[Pasted text #1 …]"). What Claude takes goes to its record, as Claude writes it, when `record` is set.
    final class Claude330 {
        static let earlier = ["❯ [Pasted text #1 +12 lines]", "", "⏺ Listo: el resumen ya no queda en medio de la conversación.", "",
                              "❯ \(CollapsedPasteDeliveryTests.suggestion)", "", "⏺ Compilé, cerré Nook y lo abrí de nuevo. Ya está corriendo."]
        let message: String
        var chat: [String]
        var box: String
        var status: String?
        var holdsPaste = false
        var deaf = false
        var scrolls = false
        /// Readings after the message went in which Claude shows nothing new yet.
        var quietReads = 0
        var record: URL?
        private(set) var actions: [String] = []
        private(set) var taken = 0
        private var pastes = 1
        private var typedReturn = false
        private var arriving: (shown: String, withReturn: Bool)?

        init(message: String, chat: [String] = Claude330.earlier, box: String = CollapsedPasteDeliveryTests.suggestion) {
            self.message = message; self.chat = chat; self.box = box
        }

        var enters: Int { actions.filter { $0 == TerminalAppBridge.returnAction }.count }
        var typed: Bool { TerminalAppBridge.typesDirectly(message, agent: .claude) }
        var collapses: Bool { !typed && (message.count > 800 || lineBreaks > 2) }
        var lineBreaks: Int { message.filter(\.isNewline).count }

        /// A Terminal tab's `do script`: the message with its Return, or one more Return.
        func run(_ action: String) {
            actions.append(action)
            if action == TerminalAppBridge.returnAction { return submit() }
            arrive(withReturn: true)
        }

        /// A Nook session's tmux: the paste has no Return of its own.
        func pane(_ step: TerminalAppBridge.DeliveryStep) {
            actions.append(step == .enter ? TerminalAppBridge.returnAction : "paste-buffer")
            if step == .enter { return submit() }
            arrive(withReturn: false)
        }

        private func arrive(withReturn: Bool) {
            guard !deaf else { return }
            let shown: String
            if collapses { pastes += 1; shown = "[Pasted text #\(pastes) +\(lineBreaks) lines]" } else { shown = message }
            if quietReads > 0 { arriving = (shown, withReturn); return }
            land(shown, withReturn: withReturn)
        }

        private func land(_ shown: String, withReturn: Bool) {
            box = shown
            guard withReturn, !holdsPaste else { return }
            // Typed keys show before their Return is read; a paste's Return goes with it.
            if typed { typedReturn = true } else { submit() }
        }

        func read() -> String {
            if let next = arriving {
                if quietReads > 0 { quietReads -= 1 } else { arriving = nil; land(next.shown, withReturn: next.withReturn) }
            } else if typedReturn {
                typedReturn = false
                defer { submit() }
                return screen
            }
            return screen
        }

        private func submit() {
            guard !box.isEmpty, box != CollapsedPasteDeliveryTests.suggestion else { return }
            chat += ["", "❯ " + box]
            if scrolls { chat.removeFirst(2) }
            box = ""
            status = "✻ Churning… (2s · esc to interrupt)"
            taken += 1
            if let record { try? CollapsedPasteDeliveryTests.append(userMessage: collapses ? CollapsedPasteDeliveryTests.pasted(message) : message, to: record) }
        }

        var screen: String {
            (chat + [""] + (status.map { [$0, ""] } ?? []) + [CollapsedPasteDeliveryTests.rule, "❯ " + box, CollapsedPasteDeliveryTests.rule,
                                                               CollapsedPasteDeliveryTests.footer]).joined(separator: "\n")
        }
    }

    // MARK: Claude's record, as Claude writes it

    /// A paste as Claude's record keeps it (21/11 00:10:53): a blank line, then the paste inside `<pasted_content>`.
    static func pasted(_ text: String) -> String { "\n\n<pasted_content id=\"f644\">\n\(text)\n</pasted_content id=\"f644\">\n" }

    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func append(userMessage content: Any, at date: Date = Date(), meta: Bool = false, to record: URL) throws {
        var entry: [String: Any] = ["parentUuid": UUID().uuidString, "isSidechain": false, "type": "user", "uuid": UUID().uuidString,
                                    "timestamp": stamp(date), "message": ["role": "user", "content": content]]
        if meta { entry["isMeta"] = true }
        try append(line(entry), to: record)
    }

    static func append(_ line: String, to record: URL) throws {
        if !FileManager.default.fileExists(atPath: record.path) { FileManager.default.createFile(atPath: record.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: record)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func recordFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-record-\(UUID().uuidString.prefix(8)).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: The message of 21/11

    func testTheMessageOf21NovIsLongPastedAndCarriesThreeImagePaths() {
        let message = Self.message
        XCTAssertFalse(TerminalAppBridge.typesDirectly(message, agent: .claude), "Pasted, between bracketed-paste marks.")
        XCTAssertEqual(message.filter(\.isNewline).count, 66, "As many line breaks as the real one, which Claude showed as \"+66 lines\".")
        XCTAssertEqual(ClaudeImagePaste.parts(message).images.map { ($0 as NSString).lastPathComponent },
                       ["imagen-pantalla-20261120-211607.png", "imagen-pantalla-20261120-211700.png", "imagen-pantalla-20261120-212152.png"],
                       "Nook reads three paths as images (a path with a quote after it is none): the strict wait of a message with images.")
        XCTAssertFalse(MessageAttachments.endsWithAttachments(message), "None of them is an attachment of this message.")
    }

    /// 00:11:01 replayed: Claude takes the paste on its own Return; its chat shows one more "[Pasted text #…]". That is the message.
    func testTheCollapsedPasteClaudeTakesOnItsOwnReturnIsSent() throws {
        let claude = Claude330(message: Self.message)
        var steps: [String] = []
        let started = Date()
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(steps.first, "caja antes: «\(Self.suggestion)»")
        XCTAssertEqual(steps[1], "pegado entre marcas con su Enter (\(Self.message.utf8.count) bytes, 3 imágenes)", "The log line of 00:11:01.")
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertEqual(claude.actions, [TerminalAppBridge.messageAction(Self.message, agent: .claude)], "No Enter of Nook's: Claude had it.")
        XCTAssertEqual(claude.taken, 1)
        XCTAssertTrue(claude.chat.contains("❯ [Pasted text #2 +66 lines]"))
        XCTAssertEqual(MessageEcho.echoes(of: Self.message, inChatOf: claude.screen), 0, "Its words never showed: only the placeholder's echo told it.")
        XCTAssertLessThan(Date().timeIntervalSince(started), fast.images, "Told by its echo, not after the images' whole wait.")
    }

    /// The same paste when its Return got lost in it: the box holds the placeholder, Nook's one Enter sends it, and the placeholder's echo
    /// says so.
    func testACollapsedPasteHeldInTheBoxGetsOneEnter() throws {
        let claude = Claude330(message: Self.message)
        claude.holdsPaste = true
        var steps: [String] = []
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(claude.enters, 1)
        XCTAssertTrue(steps.contains("en la caja «[Pasted text #2 +\(claude.lineBreaks) lines]»"), steps.joined(separator: "\n"))
        XCTAssertEqual(steps.last, "caja vacía: enviado")
        XCTAssertEqual(claude.taken, 1)
    }

    /// The more common way into the same wait: a long message of several lines with screen vision's screenshot (or an image) attached.
    func testALongMessageWithItsOwnAttachmentIsSent() throws {
        let words = "revisa esto:\n- el botón de copiar\n- el color del comando\n- el resumen arriba"
        let message = MessageAttachments.message(text: words, files: [MessageAttachments.folder + "pantalla-20261121-001100.png"])
        XCTAssertEqual(ClaudeImagePaste.parts(message).images.count, 1)
        let claude = Claude330(message: message)
        var steps: [String] = []
        try TerminalAppBridge.deliver(message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertEqual(claude.enters, 0)
    }

    /// A long paste with no image path in it never had the strict wait: it is still sent the same way.
    func testALongPasteWithoutImagePathsIsSent() throws {
        let message = Self.message.components(separatedBy: "\n").filter { !$0.contains(MessageAttachments.folder) }.joined(separator: "\n")
        XCTAssertTrue(ClaudeImagePaste.parts(message).images.isEmpty)
        let claude = Claude330(message: message)
        var steps: [String] = []
        try TerminalAppBridge.deliver(message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertEqual(claude.taken, 1)
        XCTAssertEqual(claude.enters, 0)
    }

    // MARK: Short messages and special characters

    func testAShortMessageIsTypedAndSent() throws {
        let claude = Claude330(message: "si, hazlo")
        var steps: [String] = []
        try TerminalAppBridge.deliver("si, hazlo", agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(steps[1], "escrito con su Enter")
        XCTAssertEqual(claude.actions, [TerminalAppBridge.typeAction("si, hazlo")])
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertTrue(claude.chat.contains("❯ si, hazlo"))
    }

    func testMessagesWithSpecialCharactersAreSent() throws {
        let short = "¿\"comillas\", \\barra, <tag> & 100% `code` > cita ✅ 🚀?"
        XCTAssertTrue(TerminalAppBridge.typesDirectly(short, agent: .claude))
        let typed = Claude330(message: short)
        var steps: [String] = []
        try TerminalAppBridge.deliver(short, agent: .claude, timing: fast, run: typed.run, read: typed.read, trace: { steps.append($0) })
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertEqual(typed.actions, [TerminalAppBridge.typeAction(short)])
        XCTAssertTrue(typed.actions[0].contains(#"\"comillas\""#) && typed.actions[0].contains(#"\\barra"#), "Quotes and backslashes are escaped for AppleScript.")

        // The same characters in a long paste, after a "!" (Claude's shell mode stays a key in front of it).
        let long = "!" + String(repeating: "echo \"<system-reminder>\" && printf '%s\\n' `date` > /tmp/x ✅\n", count: 4)
        let pasted = Claude330(message: long)
        steps = []
        try TerminalAppBridge.deliver(long, agent: .claude, timing: fast, run: pasted.run, read: pasted.read, trace: { steps.append($0) })
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
        XCTAssertTrue(pasted.actions[0].hasPrefix("do script (\"!\" & (character id 27) & \"[200~\""), pasted.actions[0])
        XCTAssertEqual(pasted.enters, 0)
    }

    // MARK: What the screen can't tell: Claude's record

    /// Claude took it, but its chat holds a screen's worth: the older "[Pasted text #1 …]" went off the top as the new one came in, so the
    /// screen never says. Claude's record does: the message is not given back.
    func testWhenTheScreenNeverTellsClaudesRecordDoes() throws {
        let record = recordFile()
        try Self.append(userMessage: Self.pasted("una pegada anterior\ncon\nvarias\nlíneas"), at: Date().addingTimeInterval(-600), to: record)
        let claude = Claude330(message: Self.message)
        claude.scrolls = true
        claude.record = record
        var steps: [String] = []
        let since = Date().addingTimeInterval(-1)
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: quiet, run: claude.run, read: claude.read,
                                      record: { ClaudeRecordArrival.holds($0, in: record, since: since) }, trace: { steps.append($0) })
        XCTAssertEqual(claude.taken, 1)
        XCTAssertEqual(steps.last, "no apareció en la caja, pero el registro de Claude lo tiene: enviado")
        XCTAssertEqual(claude.enters, 0)
    }

    /// A real failure: nothing reached Claude (another program had the keys). Neither the screen nor the record has it: not sent, and the
    /// message comes back.
    func testAMessageClaudeNeverGotIsNotReportedSent() {
        let record = recordFile()
        let claude = Claude330(message: Self.message)
        claude.deaf = true
        var steps: [String] = []
        let since = Date().addingTimeInterval(-1)
        XCTAssertThrowsError(try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: quiet, run: claude.run, read: claude.read,
                                                           record: { ClaudeRecordArrival.holds($0, in: record, since: since) }, trace: { steps.append($0) })) { error in
            guard case DeliveryError.unseen = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(claude.enters, 0, "No Enter on a guess.")
        XCTAssertEqual(steps.last, "no apareció en la caja en 0 s; sin Enter, no enviado (tampoco en el registro de Claude)")
    }

    /// The terminal itself failing (the tab closed): the error goes up as it is, nothing more is written.
    func testATransportFailureIsNoDelivery() {
        struct Closed: Error {}
        var actions: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: quiet, run: { actions.append($0); throw Closed() },
                                                           read: { Claude330(message: Self.message).screen })) { error in
            XCTAssertTrue(error is Closed, "\(error)")
        }
        XCTAssertEqual(actions.count, 1, "Never a second paste, never an Enter.")
    }

    // MARK: The record itself

    func testTheRecordHoldsTheMessageOnlySinceTheDeliveryBegan() throws {
        let record = recordFile()
        let now = Date()
        // The first send of 00:11, then (later) other entries Claude writes.
        try Self.append(userMessage: Self.pasted(Self.message), at: now.addingTimeInterval(-98), to: record)
        try Self.append(Self.line(["type": "assistant", "timestamp": Self.stamp(now.addingTimeInterval(-90)),
                                   "message": ["role": "assistant", "content": [["type": "text", "text": "Voy a mirarlo."]]]]), to: record)
        XCTAssertFalse(ClaudeRecordArrival.holds(Self.message, in: record, since: now.addingTimeInterval(-2)),
                       "The earlier copy of the same words is not this delivery's: a message sent twice is never taken for the second.")
        XCTAssertTrue(ClaudeRecordArrival.holds(Self.message, in: record, since: now.addingTimeInterval(-100)))
        try Self.append(userMessage: Self.pasted(Self.message), at: now, to: record)
        XCTAssertTrue(ClaudeRecordArrival.holds(Self.message, in: record, since: now.addingTimeInterval(-2)))
    }

    func testTheRecordsFormsOfAMessage() throws {
        let record = recordFile(), now = Date(), since = now.addingTimeInterval(-1)
        // Queued while Claude worked.
        try Self.append(Self.line(["type": "queue-operation", "operation": "enqueue", "timestamp": Self.stamp(now), "content": "mandale esta al C por favor"]), to: record)
        XCTAssertTrue(ClaudeRecordArrival.holds("mandale esta al C por favor", in: record, since: since))
        try Self.append(Self.line(["type": "queue-operation", "operation": "dequeue", "timestamp": Self.stamp(now), "content": "solo sacada de la cola"]), to: record)
        XCTAssertFalse(ClaudeRecordArrival.holds("solo sacada de la cola", in: record, since: since))
        // Text blocks (a message with images), and Claude's shell mode.
        try Self.append(userMessage: [["type": "text", "text": "compara estas dos"], ["type": "image", "source": ["type": "base64", "data": "AAAA"]]], at: now, to: record)
        XCTAssertTrue(ClaudeRecordArrival.holds(MessageAttachments.message(text: "compara estas dos", files: [MessageAttachments.folder + "imagen-1.png"]),
                                                in: record, since: since), "Its words, the paths of its images aside.")
        try Self.append(userMessage: "<bash-input>git status --short</bash-input>", at: now, to: record)
        XCTAssertTrue(ClaudeRecordArrival.holds("! git status --short", in: record, since: since))
        // Claude's own notes are no message it got; nor is a message too short to tell.
        try Self.append(userMessage: "una nota que Claude añade sola", at: now, meta: true, to: record)
        XCTAssertFalse(ClaudeRecordArrival.holds("una nota que Claude añade sola", in: record, since: since))
        try Self.append(userMessage: "ok", at: now, to: record)
        XCTAssertFalse(ClaudeRecordArrival.holds("ok", in: record, since: since))
        XCTAssertFalse(ClaudeRecordArrival.holds("hola", in: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-record.jsonl"), since: since))
    }

    /// Only the record's end is read: an entry further back than that is out of reach, and the line the read starts inside is dropped.
    func testOnlyTheEndOfALongRecordIsRead() throws {
        let record = recordFile(), now = Date()
        try Self.append(userMessage: "el mensaje de hace un rato que quedó muy atrás", at: now, to: record)
        try Self.append(Self.line(["type": "assistant", "timestamp": Self.stamp(now), "message": ["content": [["type": "text", "text": String(repeating: "x", count: 4000)]]]]), to: record)
        XCTAssertFalse(ClaudeRecordArrival.holds("el mensaje de hace un rato que quedó muy atrás", in: record, since: now.addingTimeInterval(-1), tailBytes: 2000))
        XCTAssertTrue(ClaudeRecordArrival.holds("el mensaje de hace un rato que quedó muy atrás", in: record, since: now.addingTimeInterval(-1), tailBytes: 1 << 20))
    }

    func testTheChatCountsCollapsedPastes() {
        let screen = Claude330(message: "x").screen
        XCTAssertEqual(MessageEcho.pastedEchoes(inChatOf: screen), 1)
        XCTAssertEqual(MessageEcho.pastedEchoes(inChatOf: Claude330(message: "x", box: "[Pasted text #2 +66 lines]").screen), 1, "The box's own is no echo.")
        XCTAssertNil(MessageEcho.pastedEchoes(inChatOf: "⏺ Hola\n\nsin caja"), "No box, no telling.")
    }
}

/// The composers' shared path (`AppModel.sendMessage`) around a delivery: a message that comes back is said, and a second one never goes
/// while the first is on its way.
@MainActor
final class SendInFlightTests: XCTestCase {
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1, images: 5)

    /// A Claude session of Nook's own, its tmux steps and screen faked (nothing runs).
    private func claudeSession(_ claude: CollapsedPasteDeliveryTests.Claude330) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-inflight-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-inflight-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: "/dev/ttys007", processes: ["claude"], text: claude.screen)
        session.paneJournal = { _ in }
        session.paneTiming = fast
        session.paneSend = { step, _ in claude.pane(step) }
        session.paneScreen = { claude.read() }
        session.deliveryRecord = { nil }
        return session
    }

    private func model() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: RemoteFixture.defaults())
        model.messageSender = nil
        return model
    }

    /// What the island's composer does with a message that comes back (`SessionPane.send`): gives it back to the field and says why.
    private func sendFromTheIsland(_ text: String, model: AppModel, to session: TerminalSession) -> AppModel.MessageOutcome? {
        var outcome: AppModel.MessageOutcome?
        let serial = model.noticeSerial
        model.sendMessage(text, to: session) { result in
            outcome = result
            if result == .notDelivered { model.tellUndelivered(on: session, since: serial) }
        }
        RemoteFixture.waitUntil { outcome != nil }
        return outcome
    }

    func testAMessageThatComesBackIsSaid() {
        let (model, session, _) = RemoteFixture.model()
        model.messageSender = { _, _, done in done(false) }
        XCTAssertEqual(sendFromTheIsland("revisa el build", model: model, to: session), .notDelivered)
        XCTAssertEqual(model.notice, AppModel.undeliveredNotice(agent: .claude))
        XCTAssertEqual(model.notice, "No pude confirmar que Claude recibiera tu mensaje, así que no lo di por enviado. Revisa la terminal antes de enviarlo otra vez.")
        XCTAssertNil(session.pendingMessage)
    }

    func testAMorePreciseWordIsNotCoveredOver() {
        let (model, session, _) = RemoteFixture.model()
        // The terminal said what went wrong itself (`onFailure`).
        model.messageSender = { _, _, done in model.notice = "La pestaña original ya se cerró. No se envió el mensaje."; done(false) }
        _ = sendFromTheIsland("hola", model: model, to: session)
        XCTAssertEqual(model.notice, "La pestaña original ya se cerró. No se envió el mensaje.")
        // It landed behind text in Claude's box: the box's own warning says it.
        model.notice = nil
        model.messageSender = { _, session, done in session.joinedBox = "t/usage hola"; done(false) }
        _ = sendFromTheIsland("hola", model: model, to: session)
        XCTAssertNil(model.notice)
    }

    /// The phone has words of its own for it (`RemoteRoutes`): the model's send says nothing on the Mac for a message that came back.
    func testTheSharedPathLeavesTheSayingToTheComposer() {
        let (model, session, _) = RemoteFixture.model()
        model.messageSender = { _, _, done in done(false) }
        var outcome: AppModel.MessageOutcome?
        model.sendMessage("desde el teléfono", to: session) { outcome = $0 }
        XCTAssertEqual(outcome, .notDelivered)
        XCTAssertNil(model.notice)
    }

    func testTheIslandsComposerSaysWhyAMessageCameBack() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/NookTests/CollapsedPasteDeliveryTests.swift", with: "Sources/Nook/PanelView.swift"), encoding: .utf8)
        let send = try XCTUnwrap(source.range(of: "    private func send() {")).upperBound
        let body = String(source[send...].prefix(5000))
        let serial = try XCTUnwrap(body.range(of: "let serial = model.noticeSerial"))
        let call = try XCTUnwrap(body.range(of: "model.sendMessage(sentText, files: sentFiles, to: session)"))
        XCTAssertLessThan(serial.lowerBound, call.lowerBound, "Read before the message goes.")
        XCTAssertTrue(body.contains("model.tellUndelivered(on: session, since: serial)"))
    }

    func testADeliveredMessageSaysNothing() {
        let (model, session, _) = RemoteFixture.model()
        var outcome: AppModel.MessageOutcome?
        model.sendMessage(CollapsedPasteDeliveryTests.message, to: session) { outcome = $0 }
        XCTAssertEqual(outcome, .delivered)
        XCTAssertNil(model.notice)
    }

    /// The user presses ↵ again while the first message is still on its way: the second never goes, comes back to its composer, and the
    /// notice says why. The first goes on and is delivered once.
    func testASecondMessageNeverGoesWhileTheFirstIsOnItsWay() {
        let first = MessageAttachments.message(text: CollapsedPasteDeliveryTests.message, files: [MessageAttachments.folder + "pantalla-20261121-001100.png"])
        let claude = CollapsedPasteDeliveryTests.Claude330(message: first)
        claude.quietReads = 15
        let session = claudeSession(claude), model = model()
        var outcomes: [AppModel.MessageOutcome] = []
        model.sendMessage(CollapsedPasteDeliveryTests.message, files: [MessageAttachments.folder + "pantalla-20261121-001100.png"], to: session) { outcomes.append($0) }
        XCTAssertTrue(session.sending, "On its way.")
        var second: AppModel.MessageOutcome?
        model.sendMessage(CollapsedPasteDeliveryTests.message, to: session) { second = $0 }
        XCTAssertEqual(second, .notDelivered, "At once: nothing of it was written.")
        XCTAssertEqual(model.notice, "Todavía se está enviando el mensaje anterior; espera un momento.")
        RemoteFixture.waitUntil(10) { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.delivered])
        XCTAssertEqual(claude.actions.filter { $0 == "paste-buffer" }.count, 1, "Pasted once.")
        XCTAssertEqual(claude.taken, 1, "Claude got it once.")
        XCTAssertEqual(session.sentHistory.filter { $0 == CollapsedPasteDeliveryTests.message }.count, 0, "The refused one is not in the history.")
        XCTAssertFalse(session.sending)
        XCTAssertEqual(model.notice, "Todavía se está enviando el mensaje anterior; espera un momento.", "Delivered: nothing more to say.")
    }

    func testNoMessageGoesWhileTheScreenIsCapturedForTheOneBefore() {
        XCTAssertEqual(AppModel.messageInFlight(sending: false, capturing: true), "Nook está capturando la pantalla para el mensaje anterior; espera un momento.")
        XCTAssertNil(AppModel.messageInFlight(sending: false, capturing: false))
    }

    /// A Nook session's delivery asks the record too: Claude took the message although its screen never said.
    func testANookSessionAsksClaudesRecordToo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-record-\(UUID().uuidString.prefix(8)).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let message = MessageAttachments.message(text: "mira esto", files: [MessageAttachments.folder + "imagen-1.png"])
        let claude = CollapsedPasteDeliveryTests.Claude330(message: message)
        claude.deaf = true
        let session = claudeSession(claude)
        session.paneTiming = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.3, hold: 0.05, settle: 0.1, images: 0.3)
        session.deliveryRecord = { url }
        // Claude has it, though nothing showed (its screen went to another program meanwhile).
        try CollapsedPasteDeliveryTests.append(userMessage: "mira esto " + MessageAttachments.folder + "imagen-1.png", at: Date().addingTimeInterval(0.2), to: url)
        var delivered: Bool?
        session.send(message) { delivered = $0 }
        RemoteFixture.waitUntil(10) { delivered != nil }
        XCTAssertEqual(delivered, true)
        // Without it in the record, the message comes back.
        let other = claudeSession(claude)
        other.paneTiming = session.paneTiming
        other.deliveryRecord = { url }
        let unseen = MessageAttachments.message(text: "esta nunca llegó", files: [MessageAttachments.folder + "imagen-2.png"])
        delivered = nil
        other.send(unseen) { delivered = $0 }
        RemoteFixture.waitUntil(10) { delivered != nil }
        XCTAssertEqual(delivered, false)
    }
}
