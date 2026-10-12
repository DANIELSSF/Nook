import XCTest
@testable import Nook

/// Claude's usage panel read whole: pages laid over one another (`UsagePanelStitcher`), a tab's panel over time
/// (`ClaudeUsageReader`), and the walk that scrolls it through tmux in a Nook session (`ClaudeUsageWalk`), against a fake Claude
/// that scrolls its panel one row per ↓ or ↑ as Claude Code 2.1.293 does (`scrollBy(±1)`, nothing past the ends).
final class ClaudeUsageWalkTests: XCTestCase {
    private typealias Fixtures = ClaudeUsageFixtures

    private func page(top: Int, height: Int = 28, body: [String] = Fixtures.body) -> ClaudePanelPage {
        ClaudeUsageWalk.page(in: Fixtures.screen(top: top, height: height, body: body))!
    }

    private var whole: ClaudeUsage { Fixtures.usage(Fixtures.whole)! }

    // MARK: Pages

    func testAPageIsItsFixedHeadAndItsScrollingRowsWithoutTheMarks() throws {
        let first = page(top: 0)
        XCTAssertEqual(first.head, [String(repeating: "▔", count: 73), Fixtures.tabs, ""], "The edge, the tab row and the blank line under it stay put.")
        XCTAssertEqual(first.body.count, 28)
        XCTAssertEqual(first.body.first, "  Session")
        XCTAssertEqual(first.body.last, "  Resets 1pm (America/Bogota)", "Claude's ↓ is off the last row.")
        XCTAssertTrue(first.moreBelow); XCTAssertFalse(first.moreAbove)
        let middle = page(top: 20)
        XCTAssertTrue(middle.moreAbove); XCTAssertTrue(middle.moreBelow)
        XCTAssertFalse(middle.body.contains { $0.hasSuffix("↑") || $0.hasSuffix("↓") })
        XCTAssertNil(ClaudePanelPage("   Some panel\n   without tabs\n   Esc to close"), "Only Settings scroll this way.")
        XCTAssertTrue(ClaudePanelPage([Fixtures.tabs, "", "  Scanning local sessions…"].joined(separator: "\n"))!.isLoading)
        XCTAssertFalse(first.isLoading)
    }

    // MARK: Stitching

    func testPagesThatOverlapBecomeTheWholePanel() throws {
        var stitcher = UsagePanelStitcher(page(top: 0))
        XCTAssertFalse(stitcher.complete)
        let last = Fixtures.body.count - 28
        for top in [18, 36, last] {
            XCTAssertEqual(stitcher.merge(page(top: top)), top, "Laid where its rows agree: \(top) rows down.")
            XCTAssertEqual(stitcher.offset, top)
        }
        XCTAssertTrue(stitcher.complete)
        XCTAssertEqual(stitcher.rows, Fixtures.body)
        XCTAssertEqual(Fixtures.usage(stitcher.text), whole, "Read whole, the stitched panel is the panel.")
        XCTAssertFalse(stitcher.text.contains("↓"))
        // Back up the panel: nothing new, nothing lost.
        XCTAssertEqual(stitcher.merge(page(top: 5)), 5)
        XCTAssertEqual(stitcher.rows, Fixtures.body)
        XCTAssertTrue(stitcher.complete)
    }

    func testAPageFitsWhereItIsEvenWhenClaudeUpdatedAFigureMeanwhile() throws {
        var stitcher = UsagePanelStitcher(page(top: 0))
        // Between the two readings the session went on: a new cost, a newer last activity.
        let later = Fixtures.body.map {
            $0.replacingOccurrences(of: "$1.75", with: "$1.82").replacingOccurrences(of: "1m 11s ago", with: "1m 19s ago")
                .replacingOccurrences(of: "warm (1h TTL", with: "cold (1h TTL")
        }
        XCTAssertEqual(stitcher.merge(page(top: 1, body: later)), 1)
        XCTAssertTrue(stitcher.rows.contains("  Total cost:            $1.82"), "The newer page's rows win.")
        XCTAssertFalse(stitcher.rows.contains("  Total cost:            $1.75"))
    }

    func testAPageOfAnotherPanelFitsNowhere() throws {
        var stitcher = UsagePanelStitcher(page(top: 0))
        let before = stitcher
        let status = ClaudePanelPage([String(repeating: "▔", count: 73), Fixtures.tabs, "", "  Version: 2.1.293", "  Session ID: 9f1c2a7e",
                                      "  cwd: /Users/developer", "  Login method: Claude Max Account", "  Model: Opus 5.5"].joined(separator: "\n"))!
        XCTAssertNil(stitcher.merge(status))
        XCTAssertEqual(stitcher, before, "Nothing changed.")
        // A jump past everything read fits nowhere either.
        XCTAssertNil(stitcher.merge(page(top: 40)))
    }

    func testAPageReachingAboveWhatWasReadAddsItsRows() throws {
        var stitcher = UsagePanelStitcher(page(top: 20))
        XCTAssertFalse(stitcher.complete)
        XCTAssertEqual(stitcher.merge(page(top: 2)), -18, "Counted in the rows as they were.")
        XCTAssertEqual(stitcher.offset, 0)
        XCTAssertFalse(stitcher.sawTop, "Claude's ↑ still says there is more.")
        XCTAssertEqual(stitcher.merge(page(top: 0)), -2)
        XCTAssertTrue(stitcher.sawTop)
        XCTAssertEqual(stitcher.rows, Array(Fixtures.body[0..<48]))
    }

    // MARK: The reader

    func testTheReaderKeepsWhatWasReadWhileThePanelIsOpen() throws {
        let reader = ClaudeUsageReader()
        let start = Date(timeIntervalSince1970: 1_000)
        let first = Fixtures.screen(top: 0, height: 28)
        let shown = try XCTUnwrap(reader.read(ClaudeComposer.split(first).panel, now: start))
        XCTAssertEqual(reader.generation, 1)
        XCTAssertEqual(Fixtures.usage(shown)?.complete, false)
        // The user's ↓ ("más"): one row more each time, kept.
        for top in 1...6 { _ = reader.read(ClaudeComposer.split(Fixtures.screen(top: top, height: 28)).panel, now: start + Double(top)) }
        XCTAssertEqual(reader.stitcher?.rows, Array(Fixtures.body[0..<34]))
        XCTAssertEqual(reader.generation, 1)
        // A reading caught while Claude redraws misses the panel: kept for a moment…
        XCTAssertNil(reader.read(nil, now: start + 7))
        XCTAssertNotNil(reader.read(ClaudeComposer.split(Fixtures.screen(top: 6, height: 28)).panel, now: start + 7.5))
        XCTAssertEqual(reader.generation, 1, "Still the same panel.")
        // …and dropped once it stays away.
        XCTAssertNil(reader.read(nil, now: start + 8))
        XCTAssertNil(reader.read(nil, now: start + 10))
        XCTAssertNil(reader.stitcher)
        _ = reader.read(ClaudeComposer.split(first).panel, now: start + 11)
        XCTAssertEqual(reader.generation, 2, "Opened again: read afresh.")
    }

    func testAnotherTabIsShownAsTheScreenHasItAndEscDropsThePanelAtOnce() throws {
        let reader = ClaudeUsageReader()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = reader.read(ClaudeComposer.split(Fixtures.screen(top: 0, height: 28)).panel, now: start)
        let status = [String(repeating: "▔", count: 73), Fixtures.tabs, "", "  Version: 2.1.293", "  Session ID: 9f1c2a7e", "  Login method: Claude Max Account"]
            .joined(separator: "\n")
        XCTAssertEqual(reader.read(status, now: start + 1), status, "Another tab is the screen's own.")
        XCTAssertNil(reader.stitcher)
        _ = reader.read(ClaudeComposer.split(Fixtures.screen(top: 0, height: 28)).panel, now: start + 2)
        XCTAssertEqual(reader.generation, 2)
        reader.userPressed(.escape, now: start + 3)
        XCTAssertNil(reader.read(nil, now: start + 3.2))
        XCTAssertNil(reader.stitcher, "Closed with Esc: gone without waiting.")
        XCTAssertEqual(reader.read("   Some other panel\n   Esc to close", now: start + 4), "   Some other panel\n   Esc to close")
    }

    func testAWalkIsDueOncePerPanelAndNeverAfterTheUsersOwnKeys() throws {
        let reader = ClaudeUsageReader()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = reader.read(ClaudeComposer.split(Fixtures.screen(top: 0, height: 28)).panel, now: start)
        XCTAssertEqual(reader.walkDue(), start + ClaudeUsageReader.walkDelay, "A moment after it opened: Claude fills its sections in.")
        let walk = ClaudeUsageWalk(generation: reader.generation)
        reader.begin(walk)
        XCTAssertNil(reader.walkDue(), "One at a time.")
        reader.finish(walk)
        XCTAssertNil(reader.walkDue(), "Not twice for the same panel.")
        // The whole panel on screen needs no walk.
        let tall = ClaudeUsageReader()
        _ = tall.read(ClaudeComposer.split(Fixtures.whole).panel, now: start)
        XCTAssertNil(tall.walkDue())
        // The user pressing keys on it: theirs to scroll.
        let touched = ClaudeUsageReader()
        _ = touched.read(ClaudeComposer.split(Fixtures.screen(top: 0, height: 28)).panel, now: start)
        touched.userPressed(.down, now: start)
        XCTAssertNil(touched.walkDue())
        // A walk the user's key interrupts stops before it.
        let running = ClaudeUsageReader()
        _ = running.read(ClaudeComposer.split(Fixtures.screen(top: 0, height: 28)).panel, now: start)
        let interrupted = ClaudeUsageWalk(generation: running.generation)
        running.begin(interrupted)
        running.userPressed(.right, now: start)
        XCTAssertTrue(interrupted.isCancelled)
    }

    // MARK: In a session

    func testANookSessionShowsTheUsagePanelAsReadSoFarAndTheUsersKeysStopItsWalk() throws {
        // A Nook session whose tmux is /usr/bin/true: nothing real is read or pressed.
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-usage-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-usage-" + UUID().uuidString.prefix(6), name: "Claude", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 0, height: 28))
        XCTAssertEqual(Fixtures.usage(try XCTUnwrap(session.panel))?.complete, false)
        XCTAssertFalse(session.readingPanel, "The walk waits a moment for Claude to fill the panel in.")
        // The user scrolls three rows: the island keeps the top too.
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 3, height: 28))
        XCTAssertEqual(session.usageReader.stitcher?.rows, Array(Fixtures.body[0..<31]))
        XCTAssertEqual(session.panel, session.usageReader.text)
        XCTAssertTrue(try XCTUnwrap(session.panel).contains("  Session"))
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-usage-" + UUID().uuidString)!)
        var sent: [TerminalKey] = []
        model.keySender = { key, _ in sent.append(key) }
        model.press(.down, on: session)
        XCTAssertEqual(sent, [.down])
        XCTAssertTrue(session.usageReader.touched)
        XCTAssertNil(session.usageReader.walkDue(), "Pressed by the user: no walk for this panel.")
        // Claude closes it: gone from the island at once (the island's own hold keeps the card a moment).
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: ClaudePanelFixtures.closed)
        XCTAssertNil(session.panel)
    }

    // MARK: Nothing read is lost

    private func panel(top: Int, height: Int = 28) -> String? { ClaudeComposer.split(Fixtures.screen(top: top, height: height)).panel }

    func testAScrollOfSeveralScreensKeepsWhatWasReadAndMasFillsTheGap() throws {
        // The user scrolls the console from the top to the end in one go: the two pages share no row.
        let reader = ClaudeUsageReader()
        _ = reader.read(panel(top: 0))
        let both = try XCTUnwrap(reader.read(panel(top: 38)))
        XCTAssertEqual(reader.stitcher?.pieceRows, [Array(Fixtures.body[0..<28]), Array(Fixtures.body[38...])], "The top stays, the end goes after it.")
        XCTAssertEqual(reader.generation, 1, "Still the same panel.")
        let usage = try XCTUnwrap(Fixtures.usage(both))
        XCTAssertEqual(usage.session?.cost, "$1.75")
        XCTAssertEqual(usage.insights?.tables.count, 2)
        XCTAssertFalse(usage.complete, "A gap is left between them.")
        XCTAssertTrue(ClaudePanel(both).moreAbove, "Claude's view is below the gap: \"↑ más\".")
        XCTAssertFalse(ClaudePanel(both).moreBelow)
        // "↑ más" (`AppModel.scrollPanel(down: false)`): a screen up, 21 rows; the page overlaps both pieces and joins them.
        XCTAssertEqual(reader.scrollStep, 21)
        let whole = try XCTUnwrap(reader.read(panel(top: 38 - 21)))
        XCTAssertEqual(reader.stitcher?.pieceRows.count, 1)
        XCTAssertEqual(reader.stitcher?.rows, Fixtures.body)
        XCTAssertEqual(Fixtures.usage(whole), self.whole)
    }

    func testAPanelFirstSeenHalfwayDownGetsItsTopWhereItGoes() throws {
        // First seen at its end (the island collapsed while the user scrolled), then at its top.
        let reader = ClaudeUsageReader()
        _ = reader.read(panel(top: 38))
        XCTAssertEqual(reader.stitcher?.sawTop, false)
        let text = try XCTUnwrap(reader.read(panel(top: 0)))
        XCTAssertEqual(reader.stitcher?.pieceRows.first, Array(Fixtures.body[0..<28]), "The top goes first, before what was read.")
        XCTAssertEqual(Fixtures.usage(text)?.session?.cost, "$1.75")
        XCTAssertTrue(ClaudePanel(text).moreBelow, "Claude's view is above the gap now: \"↓ más\".")
        _ = reader.read(panel(top: 19))
        XCTAssertEqual(reader.stitcher?.complete, true)
        // In a short terminal, three pages that share no row, read out of order: each is placed by its sections.
        let middle = ClaudeUsageReader()
        for top in [30, 50, 8] { _ = middle.read(panel(top: top, height: 8)) }
        XCTAssertEqual(middle.stitcher?.pieceRows, [Array(Fixtures.body[8..<16]), Array(Fixtures.body[30..<38]), Array(Fixtures.body[50..<58])],
                       "In panel order (the models, the week's limits, the tables), whatever order they were read in.")
        XCTAssertEqual(middle.stitcher?.complete, false)
    }

    func testASessionSectionWithOnlyThePromptCacheLine() throws {
        // First seen with its top row at the prompt cache: the session's other figures are above, unread.
        let reader = ClaudeUsageReader()
        let text = try XCTUnwrap(reader.read(panel(top: 11)))
        let usage = try XCTUnwrap(Fixtures.usage(text))
        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.promptCache, "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)")
        XCTAssertNil(session.cost); XCTAssertEqual(session.models, [])
        XCTAssertFalse(usage.complete)
        XCTAssertTrue(ClaudePanel(text).moreAbove, "The card offers \"↑ más\" for the rest of it.")
    }

    func testTerminalTabsAreReadInDetailWhileOneShowsAPanel() {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-usage-" + UUID().uuidString)!)
        func tab(_ text: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "", processes: ["claude"], busy: false,
                                selected: true, text: text, history: false)
        }
        model.updateExternalTabs([tab(ClaudePanelFixtures.closed)], ttys: ["/dev/ttys099"])
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(model.terminalBridge.detailed)
        model.updateExternalTabs([tab(Fixtures.screen(top: 0, height: 28))], ttys: ["/dev/ttys099"])
        XCTAssertTrue(model.terminalBridge.detailed, "A panel open: read whole and often, collapsed island or not.")
        model.updateExternalTabs([tab(ClaudePanelFixtures.closed)], ttys: ["/dev/ttys099"])
        XCTAssertFalse(model.terminalBridge.detailed, "Closed: back to the light reading.")
    }

    // MARK: "más"

    func testMasScrollsAScreenOfTheUsagePanelInOneGoAndWaitsForItsPage() throws {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-usage-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-usage-" + UUID().uuidString.prefix(6), name: "Claude", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-usage-" + UUID().uuidString)!)
        var sent: [TerminalKey] = []
        model.keySender = { key, _ in sent.append(key) }
        model.scrollPanel(down: true, on: session)
        XCTAssertEqual(sent, [], "No panel, nothing to scroll.")
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 0, height: 28))
        // 28 rows on show: 21 down, 7 kept in common for the next page to be laid after this one.
        XCTAssertEqual(session.usageReader.scrollStep, 21)
        model.scrollPanel(down: true, on: session)
        XCTAssertEqual(sent, Array(repeating: .down, count: 21))
        XCTAssertTrue(session.usageReader.touched, "The user is scrolling: no walk.")
        model.scrollPanel(down: true, on: session)
        XCTAssertEqual(sent.count, 21, "A second press before the page of the first was read would jump past it: it waits.")
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 21, height: 28))
        XCTAssertEqual(session.usageReader.stitcher?.rows, Array(Fixtures.body[0..<49]), "The card grows by the page.")
        model.scrollPanel(down: true, on: session)
        XCTAssertEqual(sent.count, 42)
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 38, height: 28))
        XCTAssertEqual(session.usageReader.stitcher?.rows, Fixtures.body)
        XCTAssertEqual(Fixtures.usage(try XCTUnwrap(session.panel))?.complete, true)
        model.scrollPanel(down: false, on: session)
        XCTAssertEqual(sent.suffix(21), ArraySlice(Array(repeating: TerminalKey.up, count: 21)), "Up the same way.")
        // Any other panel: one key, where ↓ may move a cursor.
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: ClaudePanelFixtures.screen(ClaudePanelFixtures.list))
        XCTAssertEqual(session.usageReader.scrollStep, 1)
        sent = []
        model.scrollPanel(down: true, on: session)
        XCTAssertEqual(sent, [.down])
    }

    func testABurstBringsTerminalForwardOnceAndGivesTheKeyboardBackOnce() {
        let bridge = TerminalAppBridge()
        let lock = NSLock()
        var scripts: [String] = [], keys: [TerminalKey] = [], returned: [KeyFocus] = []
        var front: pid_t = 77
        bridge.directKeysAllowed = { true }
        bridge.terminalProcess = { 4242 }
        bridge.runScript = { script in lock.lock(); scripts.append(script); front = 4242; lock.unlock() }
        bridge.postKey = { key, _ in lock.lock(); keys.append(key); lock.unlock() }
        bridge.keyPause = { _ in }
        bridge.currentFocus = { lock.lock(); defer { lock.unlock() }; return KeyFocus(app: front) }
        bridge.returnFocus = { returned.append($0) }
        bridge.focusReturnDelay = 0.05
        let sent = expectation(description: "burst sent")
        bridge.press(.down, count: 36, windowID: 1, tty: "/dev/ttysA") { result in
            XCTAssertEqual(result, .sent); sent.fulfill()
        }
        wait(for: [sent], timeout: 2)
        let settled = expectation(description: "keyboard back")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(scripts.count, 1, "Terminal comes forward once for the whole burst.")
        XCTAssertTrue(scripts.first?.contains("frontmost") == true)
        XCTAssertEqual(keys, Array(repeating: .down, count: 36))
        XCTAssertEqual(returned, [KeyFocus(app: 77)], "…and the keyboard goes back once, where it was.")
        // Without Accessibility nothing goes.
        let denied = TerminalAppBridge()
        denied.directKeysAllowed = { false }
        var outcome: KeyDelivery?
        denied.press(.down, count: 5, windowID: 1, tty: "/dev/ttysA") { outcome = $0 }
        XCTAssertEqual(outcome, .needsPermission)
    }

    // MARK: Everything the user sends stops a walk

    private func nookSession(_ executable: String = "/usr/bin/true") -> TerminalSession {
        let backend = TmuxBackend(executable: executable, socket: "/tmp/nook-usage-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-usage-" + UUID().uuidString.prefix(6), name: "Claude", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        return TerminalSession(record: record, backend: backend, create: false)
    }

    func testAnInterruptAMessageAndAnyKeyStopAWalk() {
        for send in ["interrupt", "message", "key", "burst"] {
            let session = nookSession()
            session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: Fixtures.screen(top: 0, height: 28))
            let walk = ClaudeUsageWalk(generation: session.usageReader.generation)
            session.usageReader.begin(walk)
            switch send {
            case "interrupt": session.interrupt()
            case "message": session.send("hola")
            case "key": session.press(.down)
            default: session.press(.down, count: 10)
            }
            XCTAssertTrue(walk.isCancelled, send)
            XCTAssertTrue(session.usageReader.touched, send)
        }
        // Without a panel, what opens it (/usage and its Enter) does not count as the user's scrolling.
        let session = nookSession()
        session.send("/usage")
        XCTAssertFalse(session.usageReader.touched)
    }

    func testABurstIsOnlyArrowsAndOnlySoMany() {
        let session = nookSession()
        var results: [KeyDelivery] = []
        session.press(.escape, count: 5) { results.append($0) }
        session.press(.down, count: TerminalSession.burstLimit + 1) { results.append($0) }
        session.press(.down, count: 0) { results.append($0) }
        XCTAssertEqual(results, [.failed, .failed, .failed])
        let bridge = TerminalAppBridge()
        bridge.directKeysAllowed = { true }
        bridge.terminalProcess = { 4242 }
        bridge.runScript = { _ in XCTFail("Nothing goes") }
        var outcome: KeyDelivery?
        bridge.press(.down, count: TerminalAppBridge.burstLimit + 1, windowID: 1, tty: "/dev/ttysA") { outcome = $0 }
        XCTAssertEqual(outcome, .failed)
        bridge.press(.tab, count: 3, windowID: 1, tty: "/dev/ttysA") { outcome = $0 }
        XCTAssertEqual(outcome, .failed)
    }

    func testAnAnswerInANookSessionGoesFromTheHighlightOnScreenNow() throws {
        // A fake tmux: its pane shows `screen`, and the keys it is sent go to `log`.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-answer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = folder.appendingPathComponent("screen"), log = folder.appendingPathComponent("log"), tmux = folder.appendingPathComponent("tmux")
        try "#!/bin/sh\ncase \"$*\" in *capture-pane*) cat '\(screen.path)';; *send-keys*) echo \"$*\" >> '\(log.path)';; esac\n"
            .write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        func question(highlight: Int) -> String {
            (["⏺ Voy a limpiar la carpeta.", "", " Do you want to proceed?"]
                + ["1. Yes", "2. Yes, and don't ask again", "3. No, and tell Claude what to do differently (esc)"].enumerated().map { ($0.offset == highlight ? " ❯ " : "   ") + $0.element })
                .joined(separator: "\n")
        }
        let session = nookSession(tmux.path)
        session.applyPane(tty: "/dev/ttys005", processes: ["claude"], text: question(highlight: 0))
        let seen = try XCTUnwrap(session.prompt)
        XCTAssertEqual(seen.highlighted, 0)
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-answer-" + UUID().uuidString)!)

        // The fake tmux's own attach exits at once: the session is still Claude's for these answers.
        session.isRunning = true
        // Something moved the highlight to the second option since that reading: answering the third takes one ↓, not two.
        try question(highlight: 1).write(to: screen, atomically: true, encoding: .utf8)
        let answered = expectation(description: "answered")
        model.answer(seen, option: 2, on: session) { result in XCTAssertEqual(result, .sent); answered.fulfill() }
        wait(for: [answered], timeout: 5)
        let sent = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ").last.map(String.init) ?? "" }
        XCTAssertEqual(sent, ["Down", "Enter"])

        // Another question on screen by then: nothing goes, and the user is told.
        try FileManager.default.removeItem(at: log)
        session.finishAnswer(delivered: false)
        session.isRunning = true
        try "⏺ Otra cosa.\n\n Do you want to edit main.swift?\n ❯ 1. Yes\n   2. No".write(to: screen, atomically: true, encoding: .utf8)
        let refused = expectation(description: "refused")
        model.answer(seen, option: 2, on: session) { result in XCTAssertEqual(result, .failed); refused.fulfill() }
        wait(for: [refused], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "No key.")
        XCTAssertEqual(model.notice, "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal.")
    }

    // MARK: The walk

    /// Claude's Settings in a 73×32 tmux pane, Usage open: ↓ and ↑ scroll its rows one each and stop at its ends.
    private final class FakeClaude {
        var body: [String]
        let height: Int
        var top = 0
        var open = true
        var scrolls = true
        /// Takes a burst of keys as one.
        var coalesces = false
        /// What the screen shows instead of the panel from the given reading on, counted from the walk's first key.
        var replaced: (reading: Int, screen: String)?
        /// How many keys had been pressed when the replacement first showed.
        var keysWhenReplaced: Int?
        private var readings: Int?
        var keyTotal: Int { keys.reduce(0) { $0 + $1.1 } }
        func total(_ key: TerminalKey) -> Int { keys.filter { $0.0 == key }.reduce(0) { $0 + $1.1 } }
        var clock = Date(timeIntervalSince1970: 0)
        var keys: [(TerminalKey, Int)] = []
        var onPress: ((Int) -> Void)?

        init(body: [String] = ClaudeUsageFixtures.body, height: Int = 28) { self.body = body; self.height = height }

        var terminal: ClaudeUsageWalk.Terminal {
            .init(screen: { [unowned self] in
                      if let reading = self.readings { self.readings = reading + 1 }
                      if let replaced = self.replaced, let reading = self.readings, reading >= replaced.reading {
                          if self.keysWhenReplaced == nil { self.keysWhenReplaced = self.keyTotal }
                          return replaced.screen
                      }
                      return self.open ? ClaudeUsageFixtures.screen(top: self.top, height: self.height, body: self.body)
                                : "> /usage\n\n⏺ Listo.\n\n" + String(repeating: "─", count: 73) + "\n❯ \n" + String(repeating: "─", count: 73) },
                  press: { [unowned self] key, count in
                      self.keys.append((key, count))
                      if self.readings == nil { self.readings = 0 }
                      let rows = self.coalesces ? 1 : count
                      if self.scrolls { self.top = min(max(0, self.top + (key == .down ? rows : -rows)), max(0, self.body.count - self.height)) }
                      self.onPress?(self.keys.count)
                      return true
                  },
                  pause: { [unowned self] in self.clock += $0 },
                  now: { [unowned self] in self.clock })
        }
    }

    func testTheWalkReadsTheWholePanelAndTakesItBackToItsTop() throws {
        let claude = FakeClaude()
        var progress: [UsagePanelStitcher] = []
        let outcome = ClaudeUsageWalk(generation: 1).run(claude.terminal) { progress.append($0) }
        XCTAssertEqual(outcome, .complete)
        let read = try XCTUnwrap(progress.last)
        XCTAssertTrue(read.complete)
        XCTAssertEqual(read.rows, Fixtures.body, "Every row once, in order: the overlaps are laid over one another.")
        XCTAssertEqual(Fixtures.usage(read.text), whole)
        XCTAssertEqual(claude.top, 0, "Back where the user's view was.")
        XCTAssertEqual(claude.keys.first?.0, .down); XCTAssertEqual(claude.keys.first?.1, 1, "One row first, to see that ↓ scrolls.")
        let firstUp = try XCTUnwrap(claude.keys.firstIndex { $0.0 == .up })
        XCTAssertTrue(claude.keys[..<firstUp].allSatisfy { $0.0 == .down } && claude.keys[firstUp...].allSatisfy { $0.0 == .up }, "Only ↓ on the way and ↑ back.")
        XCTAssertEqual(claude.total(.down), 1 + 19 + 19, "Two thirds of a screen at a time (28 rows, 9 kept in common).")
        XCTAssertTrue(claude.keys.allSatisfy { $0.1 <= 4 }, "A few keys a write, the screen read before each.")
        XCTAssertEqual(claude.total(.up), Fixtures.body.count - 28, "Up by exactly what it went down.")
        XCTAssertGreaterThanOrEqual(progress.count, 4, "The card grows as the walk reads.")
    }

    func testTheWalkOfSamplesTerminalSizedPanelTakesOneStep() throws {
        // 47 rows on show, as in Sample's 51-row tab: the probe and one more step reach the end.
        let claude = FakeClaude(height: 47)
        var last: UsagePanelStitcher?
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { last = $0 }, .complete)
        XCTAssertEqual(last?.rows, Fixtures.body)
        XCTAssertEqual(claude.total(.down), 1 + 32)
        XCTAssertEqual(claude.total(.up), Fixtures.body.count - 47)
        XCTAssertEqual(claude.top, 0)
    }

    func testAPanelThatAlreadyFitsIsNotWalked() {
        // A shorter panel (no insights yet) on a screen with room for all of it.
        let claude = FakeClaude(body: Array(Fixtures.body.prefix(40)), height: 50)
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { _ in }, .complete)
        XCTAssertTrue(claude.keys.isEmpty, "Nothing to scroll, no key.")
    }

    func testTheUsersKeyStopsTheWalkWhereItIs() throws {
        let claude = FakeClaude()
        let walk = ClaudeUsageWalk(generation: 1)
        // The user presses a key on the panel right after the walk's second press (from the main thread: `cancel()` waits for a
        // press under way, so here it comes in the walk's next pause).
        var userPressed = false
        claude.onPress = { count in if count == 2 { userPressed = true } }
        let terminal = claude.terminal
        let interrupted = ClaudeUsageWalk.Terminal(screen: terminal.screen, press: terminal.press,
                                                   pause: { if userPressed { walk.cancel() }; terminal.pause($0) }, now: terminal.now)
        var last: UsagePanelStitcher?
        XCTAssertEqual(walk.run(interrupted) { last = $0 }, .cancelled)
        XCTAssertEqual(claude.keys.count, 2, "Not one key after theirs, and no way back: the panel is theirs now.")
        XCTAssertFalse(last?.complete ?? true)
    }

    func testAPanelThatDoesNotScrollGetsOneKeyAndNoMore() {
        let claude = FakeClaude()
        claude.scrolls = false
        let outcome = ClaudeUsageWalk(generation: 1).run(claude.terminal) { _ in }
        XCTAssertEqual(outcome, .partial("no scroll"))
        XCTAssertEqual(claude.keys.count, 1, "The probe only; nothing to take back.")
    }

    func testThePanelClosingStopsTheWalk() {
        let claude = FakeClaude()
        claude.onPress = { [unowned claude] count in if count == 2 { claude.open = false } }
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { _ in }, .gone)
        XCTAssertEqual(claude.keys.count, 2, "No ↑ into Claude's box once the panel is gone.")
    }

    func testKeysClaudeTakesAsOneAreSentOneByOne() throws {
        let claude = FakeClaude()
        claude.coalesces = true
        var last: UsagePanelStitcher?
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { last = $0 }, .complete)
        XCTAssertEqual(last?.rows, Fixtures.body)
        XCTAssertEqual(claude.top, 0, "Back at the top, one key at a time.")
        // The probe, a batch of 19 in writes of 4 that scrolled five rows, and single keys from then on.
        XCTAssertEqual(claude.keys.prefix(6).map(\.1), [1, 4, 4, 4, 4, 3])
        XCTAssertTrue(claude.keys.dropFirst(6).allSatisfy { $0.1 == 1 })
    }

    func testAKeyNeverGoesToAQuestionThatTookThePanelsPlace() {
        // Claude asks for a permission right after the walk read its first scrolled page: the next ↓ would move the question's
        // highlight. The screen is read again before each press, and the press does not go.
        let claude = FakeClaude()
        let question = ["⏺ Voy a limpiar la carpeta.", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]
            .joined(separator: "\n")
        claude.replaced = (3, question)
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { _ in }, .gone)
        XCTAssertEqual(claude.keys.count, 1, "Only the probe, before the question.")
        // The panel moved under the walk (scrolled from elsewhere): it stops too, and leaves the panel alone.
        let moved = FakeClaude()
        moved.replaced = (3, Fixtures.screen(top: 10, height: 28))
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(moved.terminal) { _ in }, .partial("screen changed"))
        XCTAssertEqual(moved.keys.count, 1)
    }

    func testADialogThatShowsUpBetweenSingleKeysGetsNoneOfThem() {
        // Keys one by one (Claude took a burst as one), and a permission question takes the panel's place in the middle of them.
        let claude = FakeClaude()
        claude.coalesces = true
        let question = ["⏺ Voy a limpiar la carpeta.", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again",
                        "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        claude.replaced = (15, question)
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { _ in }, .gone)
        let shown = try? XCTUnwrap(claude.keysWhenReplaced)
        XCTAssertNotNil(shown)
        XCTAssertGreaterThan(claude.keys.count, 6, "It was in the middle of single keys.")
        XCTAssertEqual(claude.keyTotal, shown, "Not one key once the question was on screen.")
    }

    func testTheWalkKeepsToItsKeysAndItsTimeTheWayBackIncluded() {
        // 20 keys in all: the walk takes 10 at most, so the way back fits.
        let claude = FakeClaude()
        XCTAssertEqual(ClaudeUsageWalk(generation: 1, limits: .init(keys: 20)).run(claude.terminal) { _ in }, .partial("limits"))
        XCTAssertLessThanOrEqual(claude.keyTotal, 20)
        XCTAssertEqual(claude.top, 0, "And back where it was.")
        // A panel that keeps loading: every wait ends in time for the way back, within the 5 s allowed.
        let slow = FakeClaude(body: ["  Loading usage data…"] + Fixtures.body)
        _ = ClaudeUsageWalk(generation: 1, limits: .init(duration: 5)).run(slow.terminal) { _ in }
        XCTAssertLessThanOrEqual(slow.clock.timeIntervalSince1970, 5.3)
    }

    func testTheWalkWaitsForASectionStillLoading() throws {
        // Claude is still scanning the local sessions when the walk reaches the insights; they come in a moment later.
        let loaded = Fixtures.body
        guard let start = loaded.firstIndex(of: "  Last 24h · these are independent characteristics of your usage, not a") else { return XCTFail() }
        let scanning = Array(loaded[..<start]) + ["  Scanning local sessions…"]
        let claude = FakeClaude(body: scanning)
        let ready = claude.clock.addingTimeInterval(2)
        // The fake's clock moves with the walk's pauses: past `ready`, every reading shows the panel loaded.
        let terminal = claude.terminal
        var sawScanning = false
        let watching = ClaudeUsageWalk.Terminal(screen: { [unowned claude] in
            if claude.clock >= ready { claude.body = loaded }
            let screen = terminal.screen()
            if screen?.contains("Scanning local sessions…") == true { sawScanning = true }
            return screen
        }, press: terminal.press, pause: terminal.pause, now: terminal.now)
        var last: UsagePanelStitcher?
        let outcome = ClaudeUsageWalk(generation: 1).run(watching) { last = $0 }
        XCTAssertTrue(sawScanning, "The walk reached the insights while Claude was still scanning.")
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(last?.rows, loaded, "What loaded replaced the scanning line, rows below it included.")
        XCTAssertEqual(Fixtures.usage(try XCTUnwrap(last).text)?.insights?.items.count, 2)
    }

    func testTheWalkStartsWhereTheUsersViewIsAndComesBackThere() throws {
        // Opened scrolled down (the user had scrolled before): down to the end, up to the top, back to where it was.
        let claude = FakeClaude()
        claude.top = 20
        var last: UsagePanelStitcher?
        XCTAssertEqual(ClaudeUsageWalk(generation: 1).run(claude.terminal) { last = $0 }, .complete)
        XCTAssertEqual(last?.rows, Fixtures.body)
        XCTAssertEqual(claude.top, 20)
        XCTAssertEqual(claude.keys.last?.0, .down, "From the top back down to it.")
    }
}
