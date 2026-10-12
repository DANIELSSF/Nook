import AppKit
import SwiftUI
import XCTest
@testable import Nook

enum Footprint {
    static func of(_ pid: pid_t = getpid()) -> Int64 { MemoryFootprint.of(pid) ?? -1 }
    static func mb(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}

/// The bytes malloc holds for live allocations in this process: what a leak makes grow, without the footprint's noise from pages
/// the allocator has not handed back yet.
enum LiveHeap {
    static func bytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }
}

/// Terminal and Claude in miniature, for measuring what Nook keeps: Claude tabs whose history grows a few lines per reading (Terminal
/// hands back its last 80,000 characters), each with Claude's record on disk growing as it works, and a subagent with its own record.
/// Nothing reaches Terminal or tmux: the readings go straight to `AppModel.updateExternalTabs`.
@MainActor
final class MemoryWorkload {
    let model: AppModel
    let tabs: Int
    private(set) var lines: Int
    let folder: URL
    private(set) var records: [URL] = []
    private var host: NSHostingView<AnyView>?
    private var window: NSWindow?
    private var entry = 0
    private static let rule = String(repeating: "─", count: 96)

    /// Lines each tab's history grows by per reading.
    let step: Int

    /// `archiveLimit` and `recordLimit` lower the caps on what slid out of Terminal's window and on Claude's record as the mirror
    /// keeps it, so a short test reaches the steady state a day of use reaches.
    init(tabs: Int, recordBytes: Int, startLines: Int = 1_500, step: Int = 3, panel: Bool = false,
         archiveLimit: Int = TerminalSession.archiveLimit, recordLimit: Int = 240_000) throws {
        self.tabs = tabs
        self.step = step
        lines = startLines
        model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-memory-" + UUID().uuidString)!)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.loginStampsReader = { [:] }
        model.animations = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-memory-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for tab in 0..<tabs {
            let url = folder.appendingPathComponent("record-\(tab).jsonl")
            // Built in its own pool: the harness's JSON must not count as Nook's memory.
            try autoreleasepool {
                var text = ""
                while text.utf8.count < recordBytes { text += entries() }
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            records.append(url)
        }
        // The first tab's Claude runs a subagent with a record of its own.
        let agents = folder.appendingPathComponent("record-0/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["toolUseId": "agent-call", "agentType": "Explore"]).write(to: agents.appendingPathComponent("agent-a1.meta.json"))
        try "".write(to: agents.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try append(TranscriptFixtures.call("agent-call", "Agent", ["description": "Revisar memoria", "prompt": "Mide", "run_in_background": true]) + "\n", to: records[0])
        poll(history: true)
        for (index, session) in model.sessions.enumerated() {
            session.archiveLimit = archiveLimit
            session.transcript = TranscriptFollower(url: records[index], limit: recordLimit)
        }
        if panel { showPanel() }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func setOpen(_ open: Bool) {
        model.expanded = open
        model.islandContentVisible = open
    }

    /// The island as the app shows it, in a window off screen.
    private func showPanel() {
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let host = NSHostingView(rootView: AnyView(NookPanel(model: model).environment(\.colorScheme, .dark)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host; self.window = window
    }

    func tearDown() {
        window?.contentView = nil
        window?.close()
        host = nil; window = nil
    }

    /// A few of Claude's record lines: a prompt, a reply, a file read with its whole content, now and then an edit.
    private func entries() -> String {
        entry += 1
        let id = "call-\(entry)"
        var out = [TranscriptFixtures.prompt("Pregunta \(entry): revisa por qué la memoria crece cuando la isla está abierta y cerrada"),
                   TranscriptFixtures.reply("Respuesta \(entry). Revisé `Session.swift` y **TranscriptStyle.swift**; el archivo tiene \(entry) líneas y el problema está en la copia del texto completo en cada lectura."),
                   TranscriptFixtures.call(id, "Read", ["file_path": TranscriptFixtures.cwd + "/Sources/Nook/Session\(entry % 9).swift"]),
                   TranscriptFixtures.result(id, String(repeating: "    let value = compute(input) // línea de código con acentos ñ\n", count: 60))]
        if entry % 5 == 0 { out += TranscriptFixtures.swiftEdit(id: "edit-\(entry)") }
        return out.joined(separator: "\n") + "\n"
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func line(_ index: Int, tab: Int) -> String {
        switch index % 7 {
        case 0: return "> Pregunta \(index) de la pestaña \(tab): revisa el archivo y dime qué pasa con la memoria del proceso"
        case 2: return "⏺ Respuesta \(index): la isla guarda el texto del espejo, el archivo y la vista; aquí va una línea larga con acentos y ñ para que el texto no sea solo ASCII."
        case 3: return "  ⎿  Read 42 lines (ctrl+o to expand)"
        case 4: return "⏺ Bash(swift build --scratch-path /tmp/nook-\(index))"
        case 5: return "  ⎿  Build complete! (18,64 s) · línea \(index)"
        default: return ""
        }
    }

    /// The last 80,000 characters of a tab's history, as Terminal returns them, Claude's box at the end.
    func screen(tab: Int, working: Bool) -> String {
        var parts: [String] = [], length = 0, index = lines - 1
        while index >= 0, length < 80_000 { let text = line(index, tab: tab); parts.append(text); length += text.count + 1; index -= 1 }
        var text = parts.reversed().joined(separator: "\n")
        if text.count > 80_000 - 400 { text = String(text.suffix(80_000 - 400)) }
        if working { text += "\n✻ Churning… (\(lines % 60)s · ↓ 1.2k tokens)" }
        return text + "\n" + Self.rule + "\n❯ \n" + Self.rule + "\n  ⏵⏵ auto mode on (shift+tab to cycle)"
    }

    /// One reading: every tab grew by three lines, and every other reading each Claude wrote a little more of its record.
    func poll(history: Bool, spin: TimeInterval? = nil) {
        lines += step
        autoreleasepool {
            let snapshots = (0..<tabs).map { tab in
                // A screen-only read (collapsed island) gets what Terminal shows, about fifty lines; a history read its last 80,000 characters.
                let text = screen(tab: tab, working: lines % 4 != 0)
                var snapshot = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: tab + 1, tty: "/dev/ttys9\(String(format: "%02d", tab))", customTitle: "",
                                                   processes: ["login", "-zsh", "claude"], busy: true, selected: tab == 0, text: history ? text : String(text.suffix(4_000)))
                snapshot.history = history
                return snapshot
            }
            if (lines / step) % 2 == 0 {
                for url in records { try? append(entries(), to: url) }
                // The subagent calls a tool and gets its result.
                let agent = folder.appendingPathComponent("record-0/subagents/agent-a1.jsonl")
                try? append(TranscriptFixtures.call("g\(lines)", "Grep", ["pattern": "memoria \(lines)"]) + "\n" + TranscriptFixtures.result("g\(lines)", "3 coincidencias") + "\n", to: agent)
            }
            model.updateExternalTabs(snapshots, ttys: Set(snapshots.map(\.tty)))
        }
        // The records are read off the main thread and handed back to it; the panel renders.
        RunLoop.main.run(until: Date().addingTimeInterval(spin ?? (history ? 0.03 : 0.01)))
    }

    /// Lets the readings in flight land, and the island draw what they changed.
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host?.layoutSubtreeIfNeeded(); host?.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// What each tab keeps, in UTF-8 bytes.
    func report() -> String {
        model.sessions.map { session in
            "\(session.externalTTY ?? "") mirrored \(session.mirroredText.utf8.count) archive \(session.archive.utf8.count) display \(session.displayText.utf8.count) record \(session.transcript?.renderer.text.utf8.count ?? 0)"
        }.joined(separator: "\n")
    }
}

/// Memory that must stay flat however long Nook runs: what each reading of Terminal, each look at Claude's record and each redraw of
/// the island leaves behind. Each test warms up first (caches, the record's first read, SwiftUI's own state), then counts the live
/// heap across many more readings; a leak of a few kilobytes per reading (a day is ~170,000 readings with the island open) fails it.
@MainActor
final class MemoryBudgetTests: XCTestCase {
    /// Live bytes gained across `count` repetitions of `body`, after `warmup` of them.
    private func growth(warmup: Int, count: Int, settle: () -> Void = {}, _ body: (Int) -> Void) -> Int {
        for index in 0..<warmup { autoreleasepool { body(index) } }
        settle()
        let start = LiveHeap.bytes()
        for index in warmup..<(warmup + count) { autoreleasepool { body(index) } }
        settle()
        return LiveHeap.bytes() - start
    }

    /// Three Claude tabs read twice a second with the island open (the whole island drawn off screen), then collapsed: what the
    /// readings, Claude's records, the mirror's styling and the panel's redraws leave behind stays put. The island's panel once made a
    /// dictation recognizer on every redraw and kept it forever, a kilobyte or more per reading.
    func testReadingTerminalAndClaudesRecordStaysFlat() throws {
        // Low caps, and histories that grow fast, so a few dozen readings reach the steady state of a day of use; what still grows
        // after that is kept per reading. Its records start past the cap.
        let workload = try MemoryWorkload(tabs: 3, recordBytes: 300_000, step: 40, panel: true, archiveLimit: 20_000, recordLimit: 20_000)
        defer { workload.tearDown() }
        workload.setOpen(true)
        let open = growth(warmup: 30, count: 100, settle: workload.settle) { _ in workload.poll(history: true, spin: 0.01) }
        print("Open island: \(open) bytes kept over 100 readings")
        XCTAssertLessThan(open, 200_000, "Open island: \(open / 100) bytes kept per reading.")
        workload.setOpen(false)
        let collapsed = growth(warmup: 20, count: 150, settle: workload.settle) { index in workload.poll(history: index % 5 == 0, spin: 0.003) }
        print("Collapsed island: \(collapsed) bytes kept over 150 readings")
        XCTAssertLessThan(collapsed, 150_000, "Collapsed island: \(collapsed / 150) bytes kept per reading.")
        // Everything a tab keeps has its cap: the mirror's window, what slid out of it, and Claude's record.
        for session in workload.model.sessions {
            XCTAssertLessThanOrEqual((session.mirroredText as NSString).length, 81_000)
            XCTAssertLessThanOrEqual((session.archive as NSString).length, 20_000)
            XCTAssertLessThanOrEqual(((session.transcript?.renderer.text ?? "") as NSString).length, 21_000)
        }
    }

    /// The mirror restyles only what changed, and keeps nothing of the texts it showed before: a transcript that keeps growing past its
    /// 240,000-character window costs the same after hundreds of updates.
    func testTheMirrorKeepsNothingOfOldTexts() {
        let mirror = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        mirror.setTheme(dark: true, transcript: true)
        var renderer = TranscriptRenderer()
        renderer.limit = 20_000
        var entry = 0
        func grow() {
            for _ in 0..<4 {
                entry += 1
                renderer.consume(TranscriptFixtures.prompt("Pregunta \(entry) con **negrita** y `código`"))
                renderer.consume(TranscriptFixtures.reply("Respuesta \(entry):\n- uno\n- dos\n```swift\nlet x = \(entry)\n```"))
            }
            mirror.update(text: renderer.text, messages: entry % 3 == 0 ? [MirrorMessage(text: "en cola \(entry)", state: .queued)] : [])
        }
        let kept = growth(warmup: 100, count: 300) { _ in grow() }
        print("Mirror: \(kept) bytes kept over 300 updates")
        XCTAssertLessThan(kept, 150_000, "\(kept / 300) bytes kept per update.")
        XCTAssertLessThanOrEqual(mirror.textView.string.utf16.count, 20_000 + 200)
    }

    /// A panel is made on every redraw of the island; its dictation controller must cost nothing until dictation is used.
    func testADictationControllerCostsNothingUntilUsed() {
        let kept = growth(warmup: 20, count: 400) { _ in _ = SpeechController() }
        XCTAssertLessThan(kept, 40_000, "\(kept / 400) bytes kept per controller.")
    }

    /// Following a record that keeps growing: only the appended part is read, lines are handed over whole, and nothing piles up.
    func testFollowingARecordReadsOnlyWhatWasAppendedAndStaysFlat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-follow-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "".write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let follower = TranscriptFollower(url: url)
        var entry = 0
        let kept = growth(warmup: 100, count: 300) { _ in
            entry += 1
            let reply = "Respuesta \(entry) " + String(repeating: "texto ", count: 40)
            // Written in two pieces: a line still being written waits for its end.
            let bytes = Data((TranscriptFixtures.reply(reply) + "\n").utf8)
            try? handle.write(contentsOf: bytes.prefix(bytes.count / 2))
            XCTAssertNil(follower.poll(), "Half a line is not an entry yet.")
            try? handle.write(contentsOf: bytes.suffix(from: bytes.count / 2))
            XCTAssertEqual(follower.poll()?.hasSuffix("⏺ " + reply + "\n\n"), true)
        }
        XCTAssertLessThan(kept, 300_000, "\(kept / 300) bytes kept per entry.")
        XCTAssertLessThanOrEqual((follower.renderer.text as NSString).length, follower.renderer.limit)
    }

    /// A record read from the middle starts at the next whole line, and lines are walked in place, however many arrive at once.
    func testReadingLinesInPlace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-lines-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = (0..<500).map { "línea \($0)" }
        try ("cola de una línea anterior\n" + lines.joined(separator: "\n") + "\nsin terminar").write(to: url, atomically: true, encoding: .utf8)
        var offset: UInt64 = 3, partial = Data(), skip = true, read: [String] = []
        XCTAssertTrue(TranscriptFollower.readLines(of: url, offset: &offset, partial: &partial, skipToLineStart: &skip) { read.append(String(decoding: $0, as: UTF8.self)) })
        XCTAssertEqual(read, lines, "The cut first line is skipped; the unfinished last one waits.")
        XCTAssertEqual(String(decoding: partial, as: UTF8.self), "sin terminar")
        XCTAssertFalse(skip)
        XCTAssertFalse(TranscriptFollower.readLines(of: url, offset: &offset, partial: &partial, skipToLineStart: &skip) { read.append(String(decoding: $0, as: UTF8.self)) },
                       "Nothing new: nothing read.")
        // Read in small chunks, lines that straddle them come out whole all the same.
        var small: [String] = []
        offset = 3; partial = Data(); skip = true
        TranscriptFollower.readLines(of: url, offset: &offset, partial: &partial, skipToLineStart: &skip, chunk: 7) { small.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(small, lines)
        XCTAssertEqual(String(decoding: partial, as: UTF8.self), "sin terminar")
    }

    /// The renderer's version moves exactly when its text may have changed, so a reading with nothing new builds no text.
    func testTheRendererSaysWhenItsTextChanged() {
        var renderer = TranscriptRenderer()
        let start = renderer.version
        renderer.consume(TranscriptFixtures.json(["type": "system", "subtype": "other"]))
        XCTAssertEqual(renderer.version, start, "An entry that shows nothing changes nothing.")
        renderer.consume(TranscriptFixtures.prompt("hola"))
        XCTAssertNotEqual(renderer.version, start)
        let afterPrompt = renderer.version
        renderer.consume(TranscriptFixtures.call("c1", "Read", ["file_path": "/a.swift"]))
        XCTAssertNotEqual(renderer.version, afterPrompt, "A pending call shows too.")
    }

    /// The length the renderer keeps track of is the text's own, also after trimming and with characters beyond one UTF-16 unit.
    func testTheRendererTrimsAtItsLimitWithoutCountingAgain() {
        var renderer = TranscriptRenderer()
        renderer.limit = 2_000
        for index in 0..<400 { renderer.consume(TranscriptFixtures.reply("😀 respuesta \(index) ⏺ ñ")) }
        let length = (renderer.committed as NSString).length
        XCTAssertLessThanOrEqual(length, 2_000)
        XCTAssertGreaterThan(length, 400, "Trimmed by three quarters at most.")
        XCTAssertTrue(renderer.committed.hasPrefix("⏺ "), "Trimmed at an entry's start.")
        XCTAssertTrue(renderer.committed.hasSuffix("⏺ 😀 respuesta 399 ⏺ ñ\n\n"))
    }

    /// The tail of a screen, split like the whole screen would be.
    func testTheLastLinesAreTheWholeSplitsLast() {
        for text in ["", "a", "a\n", "\n\n", "a\nb\nc", "a\r\nb\nc\n", String(repeating: "línea\n", count: 200) + "fin", "x\u{2028}y\nz"] {
            for count in [1, 2, 3, 80] {
                XCTAssertEqual(Array(AgentActivity.lastLines(text, count)), Array(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(count)),
                               "\(text.debugDescription) last \(count)")
            }
        }
    }

    /// With Claude's record only the window is split; the banner that scrolled out of it is found where the whole text would show it,
    /// with its warnings, also when Terminal's cut runs through the banner itself.
    func testTheBannerOutOfTheWindowIsFoundAsTheWholeTextWouldShowIt() {
        let rule = String(repeating: "─", count: 72)
        let warning = "Permission allow rule (.claude/settings.json): Bash(pnpm --filter * exec prisma migrate dev*) has a wildcard before the rest."
        let reply = (0..<300).map { "⏺ Respuesta \($0) que menciona Claude Code v2 de pasada" }.joined(separator: "\n")
        let history = (["claude", warning, warning, "", "", "▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team",
                        " ▘▘   ▝▝   ~/Documents/app", "", "> hola"] + [reply, "✻ Churned for 3m 58s", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"]).joined(separator: "\n")
        let banner = (history as NSString).range(of: "Claude Code v2.1.290").location
        // Cut far below the banner, right through its model line, and just above it.
        for cut in [history.utf16.count - 3_000, banner + 40, banner - 30] {
            let earlier = (history as NSString).substring(to: cut), window = (history as NSString).substring(from: cut)
            let whole = TerminalSession.screen(earlier + window, agent: .claude)
            let parts = TerminalSession.screen(window, agent: .claude, earlier: earlier)
            XCTAssertEqual(parts.banner, whole.banner, "cut at \(cut)")
            XCTAssertEqual(parts.warnings, whole.warnings, "cut at \(cut)")
            XCTAssertEqual(parts.input, whole.input)
            XCTAssertEqual(parts.mode, whole.mode)
            XCTAssertEqual(parts.status, whole.status)
        }
        XCTAssertEqual(TerminalSession.screen(history, agent: .claude).banner?.model, "Sonnet 5.5")
        XCTAssertNil(TerminalSession.screen("⏺ hola", agent: .claude, earlier: reply).banner, "Mentions are no banner.")
    }

    /// A Terminal tab never shows Nook's own terminal, so it never makes SwiftTerm's view; a Nook session has one from the start.
    func testATerminalTabMakesNoTerminalView() {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys977", customTitle: "", processes: ["claude"], busy: false, selected: true, text: "hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertFalse(session.hasTerminalView)
        session.applyTheme()
        XCTAssertFalse(session.hasTerminalView, "Theming touches only views that exist.")
        _ = session.terminal
        XCTAssertTrue(session.hasTerminalView, "Made when asked for.")
    }

    /// Off the main thread, tabs are read straight from the helper's answer instead of through Apple event descriptors; both readings agree,
    /// malformed rows included.
    func testTabsReadFromTheHelpersAnswerMatchTheDescriptorReading() throws {
        let screen = String(repeating: "⏺ línea con ñ\n", count: 2_000)
        let value: [Any] = [
            [NSNumber(value: 41), "IA — claude", NSNumber(value: 1), "/dev/ttys001", "", ["login", "-zsh", "claude"], NSNumber(value: true), NSNumber(value: true), screen],
            [NSNumber(value: 41), "IA", NSNumber(value: 2), "/dev/ttys002", "Mi pestaña", [String](), NSNumber(value: false), NSNumber(value: false), ""],
        ]
        // The helper's own encoding of a descriptor, and back: what the main thread reads.
        func descriptor(_ value: Any) -> NSAppleEventDescriptor {
            if let list = value as? [Any] {
                let result = NSAppleEventDescriptor.list()
                for (index, item) in list.enumerated() { result.insert(descriptor(item), at: index + 1) }
                return result
            }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
                return NSAppleEventDescriptor(int32: number.int32Value)
            }
            return NSAppleEventDescriptor(string: value as? String ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(try TerminalAppBridge.decode(rows: json), try TerminalAppBridge.decode(descriptor(value)))
        XCTAssertEqual(try TerminalAppBridge.decode(rows: [Any]()), [])
        XCTAssertThrowsError(try TerminalAppBridge.decode(rows: "no es una lista"))
        XCTAssertThrowsError(try TerminalAppBridge.decode(rows: [[NSNumber(value: 1), "IA", NSNumber(value: 1), "", "", [String](), NSNumber(value: false), NSNumber(value: false), ""]]),
                             "A row without its TTY is malformed.")
        XCTAssertThrowsError(try TerminalAppBridge.decode(rows: [[NSNumber(value: 1)]]))
    }

    /// A tab that closes takes everything it held with it: nothing in Nook's model keeps it alive, and if a view on its way out still
    /// holds it, it holds no text.
    func testAClosedTabIsFreed() throws {
        for panel in [false, true] {
            let workload = try MemoryWorkload(tabs: 2, recordBytes: 100_000, panel: panel)
            defer { workload.tearDown() }
            workload.setOpen(true)
            for _ in 0..<5 { workload.poll(history: true) }
            workload.settle()
            weak var closed = workload.model.sessions.last
            weak var follower = workload.model.sessions.last?.transcript
            XCTAssertNotNil(closed)
            XCTAssertNotNil(follower)
            autoreleasepool { workload.model.close(workload.model.sessions.last!) }
            for _ in 0..<3 { workload.poll(history: true) }
            workload.settle()
            XCTAssertNil(follower, "Its reader of Claude's record is gone.")
            XCTAssertNil(closed, "The closed tab is gone (panel mounted: \(panel)).")
            if let closed {
                XCTAssertTrue(closed.mirroredText.isEmpty && closed.displayText.isEmpty && closed.archive.isEmpty && closed.transcriptText == nil,
                              "Whatever still holds the tab holds none of its text.")
            }
        }
    }

    /// The agents' readers go with the agents no longer shown; a long session launches hundreds.
    func testFinishedAgentsTakeTheirReadersWithThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-agents-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("s.jsonl")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("s/subagents"), withIntermediateDirectories: true)
        var lines: [String] = []
        let now = Date()
        let old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        for index in 0..<40 {
            lines.append(TranscriptFixtures.json(["type": "assistant", "timestamp": old, "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "call-\(index)", "name": "Agent", "input": ["description": "Agente \(index)", "prompt": "…"]]]]]))
            lines.append(TranscriptFixtures.json(["type": "user", "timestamp": old, "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call-\(index)", "content": "agentId: a\(index)\nlisto"]]]]))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)
        let follower = TranscriptFollower(url: record)
        _ = follower.poll()
        let shown = follower.agents(now: now.addingTimeInterval(-3_500))
        XCTAssertGreaterThanOrEqual(shown.count, 30, "Just finished: the latest are shown…")
        XCTAssertEqual(follower.watchedAgents, shown.count, "…each with its reader.")
        XCTAssertTrue(follower.agents(now: now).isEmpty, "Finished an hour ago: none shown.")
        XCTAssertEqual(follower.watchedAgents, 0, "Nor read.")
    }
}

/// The prompt histories are read once and then only what was appended, each time the island opens.
final class CommandHistoryReadingTests: XCTestCase {
    func testOnlyWhatWasAppendedIsReadAndARewrittenHistoryIsCountedAgain() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-history-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let url = home.appendingPathComponent(".claude/history.jsonl")
        // Claude writes `"display":"/usage"`; Foundation escapes the slash (`"\/usage"`): both count.
        func entry(_ text: String) -> String { #"{"display":"\#(text)","timestamp":1}"# + "\n" }
        try (entry("/usage") + entry("hola") + String(data: try JSONSerialization.data(withJSONObject: ["display": "/usage"]), encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        let suite = "nook-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SlashCommandStore(home: home, defaults: defaults, reference: [:])
        func refresh() {
            let done = expectation(description: "read")
            store.refresh { done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        refresh()
        XCTAssertEqual(store.typed[.claude]?["usage"], 2)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((entry("/usage") + entry("/model opus") + #"{"display":"/mo"#).utf8))
        refresh()
        XCTAssertEqual(store.typed[.claude]?["usage"], 3, "Only the appended lines count, once.")
        XCTAssertNil(store.typed[.claude]?["mo"], "A line still being written waits.")
        try handle.write(contentsOf: Data(#"del sonnet","timestamp":2}"#.utf8) + Data("\n".utf8))
        try handle.close()
        refresh()
        XCTAssertEqual(store.typed[.claude]?["model"], 2)
        refresh()
        XCTAssertEqual(store.typed[.claude]?["usage"], 3, "Nothing new: nothing changes.")
        try entry("/clear").write(to: url, atomically: true, encoding: .utf8)
        refresh()
        XCTAssertEqual(store.typed[.claude], ["clear": 1], "Written anew and shorter: counted again from its start.")
    }
}

/// The safety net: past its limits, Nook trims what can be rebuilt and says so once; a helper that grows is replaced between requests.
@MainActor
final class MemoryWatchTests: XCTestCase {
    func testTrimsPastTheLimitOncePerGrowthAndRaisesTheAlarmOnce() {
        let watch = MemoryWatch(limits: .init(trim: 100, alarm: 1_000), interval: 3_600)
        var footprint: Int64 = 50
        var trims: [MemoryWatch.Reason] = [], alarms: [Int64] = []
        watch.footprint = { footprint }
        watch.onTrim = { reason in trims.append(reason); footprint = footprint * 9 / 10 }
        watch.onAlarm = { alarms.append($0) }
        XCTAssertNil(watch.check(), "Under the limit: nothing to do.")
        footprint = 200
        XCTAssertEqual(watch.check(), .footprint(200))
        XCTAssertEqual(trims, [.footprint(200)])
        XCTAssertNil(watch.check(), "Still high but not growing: trimming again would only repeat itself.")
        footprint = 300
        XCTAssertEqual(watch.check(), .footprint(300), "Grown by a good margin since: trimmed again.")
        footprint = 2_000
        watch.check(); watch.check()
        XCTAssertEqual(alarms, [2_000], "The alarm is raised once.")
        footprint = 60
        XCTAssertNil(watch.check())
        footprint = 150
        XCTAssertEqual(watch.check(), .footprint(150), "Back under the limit in between: the next pass trims at once.")
    }

    func testTrimmingLetsGoOfHiddenTabsOnly() throws {
        let workload = try MemoryWorkload(tabs: 3, recordBytes: 50_000, startLines: 4_000)
        workload.setOpen(true)
        // The window slides: what left it is kept in front of it.
        for _ in 0..<40 { workload.poll(history: true, spin: 0.005) }
        workload.settle()
        let model = workload.model
        XCTAssertTrue(model.sessions.allSatisfy { !$0.archive.isEmpty })
        let followers = model.sessions.map { $0.transcript.map(ObjectIdentifier.init) }
        let selected = try XCTUnwrap(model.selected)
        model.trimMemory(.pressure)
        for (session, follower) in zip(model.sessions, followers) {
            if session === selected {
                XCTAssertFalse(session.archive.isEmpty, "The tab on screen keeps everything.")
                XCTAssertEqual(session.transcript.map(ObjectIdentifier.init), follower)
            } else {
                XCTAssertTrue(session.archive.isEmpty)
                XCTAssertNotEqual(session.transcript.map(ObjectIdentifier.init), follower, "A new reader…")
                XCTAssertEqual(session.transcript?.url, workload.records[model.sessions.firstIndex { $0 === session }!], "…of the same record.")
            }
        }
        // Read again, the record gives the same text.
        let before = model.sessions.map(\.displayText)
        for _ in 0..<3 { workload.poll(history: true, spin: 0.05) }
        workload.settle()
        for (session, text) in zip(model.sessions, before) where session !== selected {
            XCTAssertTrue(session.displayText.hasPrefix(text), "The record's text is back, and goes on.")
        }
        workload.setOpen(false)
        model.trimMemory(.pressure)
        XCTAssertTrue(model.sessions.allSatisfy(\.archive.isEmpty), "Collapsed, no tab is on screen.")
    }

    func testAHelperThatGrowsIsReplacedBetweenRequests() throws {
        // A stand-in helper whose footprint is always over a 1-byte limit: it is replaced every `checkEvery` requests, and every request is
        // answered all the same.
        let helper = ScriptHelper(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"while read line; do printf '{"value":"%s"}\n' "$$"; done"#], footprintLimit: 1)
        var pids = Set<String>()
        for _ in 0..<(ScriptHelper.checkEvery * 2 + 1) { pids.insert(try XCTUnwrap(helper.run("return 1")["value"] as? String)) }
        XCTAssertEqual(helper.recycled, 2)
        XCTAssertEqual(pids.count, 3, "Each replacement is a new process.")
        helper.recycle()
        _ = try helper.run("return 1")
        XCTAssertEqual(helper.recycled, 3, "Asked for, it is replaced before the next request.")
    }

    /// The real helper, serving six tabs of 80,000 characters, stays far below the limit that replaces it: in normal use it is never
    /// replaced, and the limit is there only for a leak.
    func testTheRealHelperStaysFarBelowItsLimit() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Compila Nook primero.") }
        let real = ScriptHelper(executable: binary)
        let pid = try XCTUnwrap(pid_t(real.run(#"do shell script "echo $PPID""#)["value"] as? String ?? ""))
        let rows = (1...6).map { #"{\#($0), "/dev/ttys00\#($0)", s, true}"# }.joined(separator: ", ")
        let poll = "set s to \"0123456789\"\nrepeat 13 times\nset s to s & s\nend repeat\nreturn {\(rows)}"
        for _ in 0..<60 { _ = try autoreleasepool { try real.run(poll) } }
        let footprint = try XCTUnwrap(MemoryFootprint.of(pid))
        XCTAssertLessThan(footprint, ScriptHelper.defaultFootprintLimit / 3, "The helper uses \(footprint >> 20) MB.")
        XCTAssertEqual(real.recycled, 0)
    }

    func testAHelperUnderItsLimitIsKept() throws {
        let helper = ScriptHelper(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"while read line; do printf '{"value":"%s"}\n' "$$"; done"#])
        var pids = Set<String>()
        for _ in 0..<(ScriptHelper.checkEvery * 3) { pids.insert(try XCTUnwrap(helper.run("return 1")["value"] as? String)) }
        XCTAssertEqual(pids.count, 1)
        XCTAssertEqual(helper.recycled, 0)
    }
}

/// Measures where memory goes, on request (NOOK_MEMORY_PROBE=1): six Claude tabs, open and collapsed, with the island on screen.
/// NOOK_MEMORY_PAUSE=<seconds> holds the process at the end for `heap`/`vmmap`; NOOK_MEMORY_HEAPS=<folder> writes `heap` snapshots.
@MainActor
final class MemoryProbeTests: XCTestCase {
    func testWhereMemoryGoes() throws {
        guard ProcessInfo.processInfo.environment["NOOK_MEMORY_PROBE"] != nil else { throw XCTSkip("Set NOOK_MEMORY_PROBE=1 to measure.") }
        let environment = ProcessInfo.processInfo.environment
        let tabs = Int(environment["NOOK_MEMORY_TABS"] ?? "") ?? 6
        let polls = Int(environment["NOOK_MEMORY_POLLS"] ?? "") ?? 300
        setvbuf(stdout, nil, _IOLBF, 0)
        let start = Footprint.of()
        print("MEM start \(Footprint.mb(start))")
        // NOOK_MEMORY_SMALL=1: low caps and fast-growing histories, so what grows in a heap diff is what leaks.
        let small = environment["NOOK_MEMORY_SMALL"] != nil
        let workload = try MemoryWorkload(tabs: tabs, recordBytes: small ? 300_000 : 4_000_000, step: small ? 40 : 3, panel: environment["NOOK_MEMORY_PANEL"] != "0",
                                          archiveLimit: small ? 20_000 : TerminalSession.archiveLimit, recordLimit: small ? 20_000 : 240_000)
        print("MEM setup \(Footprint.mb(Footprint.of())) live \(LiveHeap.bytes() >> 10) KB")
        workload.setOpen(true)
        let heaps = environment["NOOK_MEMORY_HEAPS"]
        for poll in 1...polls {
            workload.poll(history: true)
            if poll % 50 == 0 { print("MEM open poll \(poll) \(Footprint.mb(Footprint.of())) live \(LiveHeap.bytes() >> 10) KB") }
            if let heaps, poll == polls / 3 || poll == polls {
                Self.heap(to: heaps + "/heap-open-\(poll).txt")
                if environment["NOOK_MEMORY_ADDRESSES"] != nil { Self.heap(to: heaps + "/addresses-open-\(poll).txt", arguments: ["-addresses=non-object"]) }
            }
        }
        print(workload.report())
        workload.setOpen(false)
        for poll in 1...polls {
            workload.poll(history: poll % 5 == 0)
            if poll % 50 == 0 { print("MEM collapsed poll \(poll) \(Footprint.mb(Footprint.of())) live \(LiveHeap.bytes() >> 10) KB") }
        }
        print(workload.report())
        let before = Footprint.of(), started = Date()
        MemoryFootprint.relieve()
        print(String(format: "MEM relief %@ → %@ in %.1f ms", Footprint.mb(before), Footprint.mb(Footprint.of()), Date().timeIntervalSince(started) * 1000))
        print("MEM end \(Footprint.mb(Footprint.of())) live \(LiveHeap.bytes() >> 10) KB")
        if let pause = Double(environment["NOOK_MEMORY_PAUSE"] ?? "") {
            print("MEM pausing pid \(getpid()) for \(pause) s")
            Thread.sleep(forTimeInterval: pause)
        }
        workload.tearDown()
    }

    /// The real helper's footprint while it serves six tabs of 80,000 characters, twice a second's worth of readings.
    func testWhereTheHelpersMemoryGoes() throws {
        guard ProcessInfo.processInfo.environment["NOOK_MEMORY_PROBE"] != nil else { throw XCTSkip("Set NOOK_MEMORY_PROBE=1 to measure.") }
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Compila Nook primero.") }
        setvbuf(stdout, nil, _IOLBF, 0)
        let real = ScriptHelper(executable: binary)
        let pid = try XCTUnwrap(pid_t(real.run(#"do shell script "echo $PPID""#)["value"] as? String ?? ""))
        print("HELPER idle \(Footprint.mb(Footprint.of(pid)))")
        let rows = (1...6).map { #"{\#($0), "/dev/ttys00\#($0)", s, true}"# }.joined(separator: ", ")
        let poll = "set s to \"0123456789\"\nrepeat 13 times\nset s to s & s\nend repeat\nreturn {\(rows)}"
        let polls = Int(ProcessInfo.processInfo.environment["NOOK_MEMORY_POLLS"] ?? "") ?? 400
        for index in 1...polls {
            _ = try autoreleasepool { try real.run(poll) }
            if index % 100 == 0 { print("HELPER poll \(index) \(Footprint.mb(Footprint.of(pid)))") }
        }
    }

    /// What one reading of a Claude tab with its record costs to split: the whole 320,000 characters as before, or the window.
    func testWhatSplittingAReadingCosts() throws {
        guard ProcessInfo.processInfo.environment["NOOK_MEMORY_PROBE"] != nil else { throw XCTSkip("Set NOOK_MEMORY_PROBE=1 to measure.") }
        let rule = String(repeating: "─", count: 96)
        let lines = (0..<6_000).map { index -> String in
            index % 3 == 0 ? "⏺ Respuesta \(index): una línea larga con acentos, ñ y algo de código `let x = \(index)` para medir." : "  ⎿  Read \(index) lines"
        }
        let all = lines.joined(separator: "\n")
        let archive = String(all.prefix(240_000)), window = String(all.dropFirst(240_000).prefix(80_000)) + "\n" + rule + "\n❯ \n" + rule
        func time(_ body: () -> Void) -> Double {
            let start = Date()
            for _ in 0..<20 { autoreleasepool(invoking: body) }
            return Date().timeIntervalSince(start) / 20 * 1000
        }
        let whole = time { _ = TerminalSession.screen(archive + window, agent: .claude) }
        let parts = time { _ = TerminalSession.screen(window, agent: .claude, earlier: archive) }
        print(String(format: "SPLIT whole %.1f ms, window %.1f ms per reading", whole, parts))
    }

    /// `heap` run on this very process: it suspends it, reads it, writes to a file and lets it go on.
    static func heap(to path: String, arguments: [String] = ["-s"]) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
        process.arguments = arguments + [String(getpid())]
        process.standardOutput = out; process.standardError = out
        try? process.run()
        process.waitUntilExit()
        try? out.close()
    }
}
