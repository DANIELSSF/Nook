import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Nook

/// The background shells' parts of the island: what the capsule and the tabs count and say, the list's rows, entering a shell's output and leaving it, what
/// the mirror shows meanwhile, and the empty states. The logic behind them (reading Claude's record and the output files) is `BackgroundShellsTests`.
@MainActor
final class ShellUITests: XCTestCase {
    // MARK: Fixtures

    private func shell(_ id: String = "bdev00001", _ name: String = "Dev server", command: String = "pnpm dev", state: ShellActivity.State = .running, exit: Int? = nil,
                       note: String? = nil, ran: TimeInterval = 65, moved: Bool = false, path: String? = "/private/tmp/claude-501/-Users-me-app/s/tasks/x.output") -> ShellActivity {
        var shown = ShellActivity(id: id, name: name, command: command, state: state, exitCode: exit, note: note, movedToBackground: moved, started: Date().addingTimeInterval(-ran), outputPath: path)
        if state != .running { shown.ended = Date() }
        return shown
    }

    private func agent(_ id: String, _ name: String = "Diseñar el gato", state: SubagentActivity.State = .running) -> SubagentActivity {
        SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 12, tokens: "30k", duration: "2m 8s")
    }

    private func model() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-shellui-" + UUID().uuidString)!)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.loginStampsReader = { [:] }
        model.animations = false
        return model
    }

    private func claudeSession(_ model: AppModel, tty: String = "/dev/ttys240", agents: [SubagentActivity] = [], shells: [ShellActivity] = [], modeHint: Int? = nil) -> TerminalSession {
        let rule = String(repeating: "─", count: 60)
        let hints = [modeHint.map { $0 == 1 ? "1 shell" : "\($0) shells" }, "↓ to manage"].compactMap { $0 }.joined(separator: " · ")
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on · \(hints)"].joined(separator: "\n"))
        tab.history = true
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        // Nothing here may go looking for Claude's record on disk.
        session.transcriptLocated = Date()
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil, agents: agents, shells: shells)
        return session
    }

    // MARK: Windows

    private func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Runs the loop until `condition` holds or `timeout` passes; whether it held.
    @discardableResult private func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func mount<V: View>(_ view: V, size: NSSize, key: Bool = false) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.contentView = host
        // A borderless window cannot become key, so a test that clicks never takes the keyboard from the app that has it.
        if key { window.makeKeyAndOrderFront(nil) }
        host.layoutSubtreeIfNeeded()
        settle(0.3)
        return (window, host)
    }

    private func descendants<V: NSView>(of root: NSView, as type: V.Type) -> [V] {
        var found: [V] = []
        func visit(_ view: NSView) { if let match = view as? V { found.append(match) }; view.subviews.forEach(visit) }
        visit(root)
        return found
    }

    /// Every label and value the window's accessibility tree holds: the words on screen, which SwiftUI gives its text nodes.
    private func words(in window: NSWindow) -> [String] {
        NSApp.accessibilitySetValue(true as NSNumber, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var found: [String] = []
        func visit(_ element: AnyObject) {
            guard let node = element as? NSObject else { return }
            for key in ["accessibilityLabel", "accessibilityValue"] {
                if let text = node.value(forKey: key) as? String, !text.isEmpty { found.append(text) }
            }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { visit(child as AnyObject) }
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { visit(child as AnyObject) }
        return found
    }

    private func has(_ text: String, in window: NSWindow) -> Bool { words(in: window).contains { $0.contains(text) } }

    /// A left click in the window, `point` measured from the content's top left like SwiftUI does.
    private func click(_ window: NSWindow, at point: NSPoint, settle seconds: TimeInterval = 0.3) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        settle(seconds)
    }

    private func pressEscape(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(event)
        }
        settle()
    }

    // MARK: What the capsule says

    func testTheCapsuleCountsShellsWithTheAgents() {
        func label(_ agents: [SubagentActivity] = [], _ shells: [ShellActivity] = [], unseen: Int = 0) -> String { BackgroundSummary(agents, shells: shells, unseen: unseen).label }
        XCTAssertEqual(label([agent("a")]), "1 agente", "Agents alone read as they always did.")
        XCTAssertEqual(label([agent("a"), agent("b")]), "2 agentes")
        XCTAssertEqual(label([agent("a", state: .done), agent("b", state: .done)]), "2 agentes listos")
        XCTAssertEqual(label([agent("a", state: .failed)]), "1 con error")

        XCTAssertEqual(label([], [shell()]), "1 shell")
        XCTAssertEqual(label([], [shell("a"), shell("b")]), "2 shells")
        XCTAssertEqual(label([agent("a"), agent("b")], [shell()]), "2 agentes · 1 shell")
        XCTAssertEqual(label([agent("a", state: .done)], [shell()]), "1 shell", "Only what runs is counted while anything does.")

        // The moment the capsule lingers.
        XCTAssertEqual(label([], [shell(state: .completed, exit: 0)]), "1 shell listo")
        XCTAssertEqual(label([], [shell("a", state: .completed), shell("b", state: .completed)]), "2 shells listos")
        XCTAssertEqual(label([agent("a", state: .done)], [shell(state: .completed)]), "1 agente · 1 shell listos")
        XCTAssertEqual(label([], [shell(state: .failed, exit: 1)]), "1 shell con error")
        XCTAssertEqual(label([agent("a", state: .failed)], [shell(state: .failed)]), "2 con error")
        XCTAssertEqual(label([agent("a", state: .failed)], [shell(state: .completed)]), "1 con error", "A failure leads, whoever it is.")
        XCTAssertEqual(label([], [shell(state: .stopped)]), "1 shell detenido", "A stopped shell did not finish: \"listo\" would say it did.")
        XCTAssertEqual(label([], [shell("a", state: .stopped), shell("b", state: .stopped)]), "2 shells detenidos")
        XCTAssertEqual(label([], [shell("a", state: .stopped), shell("b", state: .completed)]), "2 shells listos")

        // Shells Claude counts and Nook cannot name run, as far as anyone knows.
        XCTAssertEqual(label([], [], unseen: 1), "1 shell")
        XCTAssertEqual(label([agent("a")], [shell()], unseen: 2), "1 agente · 3 shells")
        XCTAssertEqual(label(), "", "Nothing to say, nothing said.")
    }

    func testTheCapsuleIsNamedForWhatItHolds() {
        XCTAssertEqual(BackgroundSummary([agent("a")]).title, "Agentes de Claude")
        XCTAssertEqual(BackgroundSummary([], shells: [shell()]).title, "Shells de Claude")
        XCTAssertEqual(BackgroundSummary([agent("a")], shells: [shell()]).title, "Agentes y shells de Claude")
        XCTAssertEqual(BackgroundSummary([], unseen: 1).title, "Shells de Claude")
    }

    func testTheSummaryCountsEachStateOnce() {
        let summary = ShellSummary([shell("a"), shell("b", state: .completed), shell("c", state: .stopped), shell("d", state: .failed)], unseen: 2)
        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.done, 2, "A stopped shell is over, and not a failure.")
        XCTAssertEqual(summary.stopped, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.active, 3)
        XCTAssertEqual(summary.total, 6)
        XCTAssertEqual(ShellSummary([], unseen: -3).unseen, 0)
        // Seconds ticking in a row are not a change of the summary: nothing is republished for them.
        XCTAssertEqual(BackgroundSummary([agent("a")], shells: [shell(ran: 10)]), BackgroundSummary([agent("a")], shells: [shell(ran: 400)]))
    }

    func testShellsClaudeCountsAndTheRecordDoesNotNameAreOnlyAHint() {
        XCTAssertEqual(ShellHint.unseen(rows: [], screen: 1), 1)
        XCTAssertEqual(ShellHint.unseen(rows: [shell()], screen: 1), 0, "The record names the one Claude counts.")
        XCTAssertEqual(ShellHint.unseen(rows: [shell()], screen: 3), 2)
        XCTAssertEqual(ShellHint.unseen(rows: [shell(state: .completed)], screen: 1), 1, "A shell that ended is not one of the running ones the line counts.")
        XCTAssertEqual(ShellHint.unseen(rows: [], screen: nil), 0, "No count on the screen: no hint, which does not mean none run.")
        XCTAssertEqual(ShellHint.unseen(rows: [shell("a"), shell("b")], screen: 1), 0)
    }

    func testTheDotsGiveEachKindItsPlaceWithinFive() {
        func marks(_ agents: Int, _ shells: Int, unseen: Int = 0) -> [SubagentDots.Mark.Kind] {
            SubagentDots.marks(agents: (0..<agents).map { agent("a\($0)") }, shells: (0..<shells).map { shell("s\($0)") }, unseen: unseen).map(\.kind)
        }
        XCTAssertEqual(marks(3, 0), [.agent, .agent, .agent], "Agents alone are as before.")
        XCTAssertEqual(marks(9, 0).count, 5)
        XCTAssertEqual(marks(2, 1), [.agent, .agent, .shell])
        XCTAssertEqual(marks(0, 2), [.shell, .shell])
        XCTAssertEqual(marks(7, 1), [.agent, .agent, .agent, .agent, .shell], "A shell keeps a place when the agents would fill all five.")
        XCTAssertEqual(marks(7, 4), [.agent, .agent, .agent, .shell, .shell], "…and two when there are more of them.")
        XCTAssertEqual(marks(1, 6), [.agent, .shell, .shell, .shell, .shell], "Places the agents leave free are the shells'.")
        XCTAssertEqual(marks(1, 0, unseen: 2), [.agent, .unnamedShell, .unnamedShell])
        XCTAssertEqual(marks(0, 1, unseen: 1), [.shell, .unnamedShell])
        XCTAssertEqual(marks(0, 0, unseen: 9).count, 5)
        // Running ones first, like the list.
        let ordered = SubagentDots.marks(agents: [], shells: [shell("done", state: .completed), shell("run")], unseen: 0)
        XCTAssertEqual(ordered.map(\.id), ["s:run", "s:done"])
        XCTAssertTrue(ordered[0].running)
        XCTAssertFalse(ordered[1].running)
    }

    // MARK: The tab's badge

    func testTheTabsBadgeCountsShellsToo() {
        let only = TabAgentState([], shells: [shell()])
        XCTAssertEqual(only.kind, .running)
        XCTAssertEqual(only.count, 1)
        XCTAssertEqual(only.label, "1 shell trabajando")
        XCTAssertEqual(only.title, "Shells de Claude")

        let both = TabAgentState([agent("a"), agent("b")], shells: [shell()])
        XCTAssertEqual(both.count, 3)
        XCTAssertEqual(both.label, "2 agentes y 1 shell trabajando")
        XCTAssertEqual(both.title, "Agentes y shells de Claude")

        let warns = TabAgentState([agent("a")], shells: [shell("a"), shell("f", state: .failed)])
        XCTAssertTrue(warns.warns, "A shell that failed while others work warns, as an agent does.")
        XCTAssertEqual(warns.label, "1 agente y 1 shell trabajando, 1 con error")

        XCTAssertNil(TabAgentState([], shells: [shell(state: .completed)]).kind, "A shell that finished long ago shows nothing.")
        let lingering = TabAgentState([], shells: [shell(state: .completed), shell("b", state: .completed)], lingering: true)
        XCTAssertEqual(lingering.kind, .done)
        XCTAssertEqual(lingering.label, "2 shells listos")
        XCTAssertEqual(TabAgentState([], shells: [shell(state: .failed)], lingering: true).label, "1 shell con error")
        XCTAssertEqual(TabAgentState([agent("a", state: .done)], shells: [shell(state: .completed)], lingering: true).label, "1 agente y 1 shell listos")

        XCTAssertEqual(TabAgentState([agent("a")], shells: [shell(ran: 5)]), TabAgentState([agent("a")], shells: [shell(ran: 500)]), "The badge does not notice the seconds.")
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    func testTheTrackerFollowsAShellFromItsStartToItsEnd() async {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([])
        let shells = CurrentValueSubject<[ShellActivity], Never>([])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), shells: shells.eraseToAnyPublisher(), linger: 0.3)
        XCTAssertNil(tracker.state.kind)
        shells.send([shell()])
        XCTAssertEqual(tracker.state.kind, .running)
        XCTAssertEqual(tracker.state.count, 1)
        // Its seconds tick in the list, not in the badge: a new reading with the same states changes nothing.
        let before = tracker.state
        shells.send([shell(ran: 400)])
        XCTAssertEqual(tracker.state, before)

        shells.send([shell(state: .completed, exit: 0)])
        XCTAssertEqual(tracker.state.kind, .done, "It lingers a moment once the last shell ends.")
        await pause(0.6)
        XCTAssertNil(tracker.state.kind)
    }

    func testTheTrackerOfASessionReadsItsShells() async {
        let model = model()
        let session = claudeSession(model)
        let tracker = TabAgentTracker(session: session, linger: 0.3)
        XCTAssertNil(tracker.state.kind)
        session.applyTranscript(nil, recap: nil, agents: nil, shells: [shell()])
        XCTAssertEqual(tracker.state.kind, .running, "A tab whose Claude runs a shell shows its badge, as for an agent.")
        session.applyTranscript(nil, recap: nil, agents: nil, shells: [])
        await pause(0.1)
        XCTAssertNil(tracker.state.kind)
    }

    // MARK: The list's rows

    func testRowsKeepAFixedHeightThatFollowsWhatTheyShow() {
        let named = shell("n", "Build and push the image", command: "gcloud builds submit .")
        let bare = shell("n", "pnpm dev", command: "pnpm dev")
        let ended = shell(state: .completed, exit: 0)
        let unknown = shell(command: "")
        XCTAssertTrue(named.showsCommandLine, "A running shell with a description shows its command under it.")
        XCTAssertFalse(bare.showsCommandLine, "…unless its name already is the command.")
        XCTAssertFalse(ended.showsCommandLine, "A finished shell is one line; the command is in its tooltip.")
        XCTAssertFalse(unknown.showsCommandLine, "A shell known only from its end has no command to show.")
        XCTAssertEqual(ShellListLayout.rowHeight(of: named), SubagentListLayout.workingRowHeight)
        XCTAssertEqual(ShellListLayout.rowHeight(of: bare), SubagentListLayout.rowHeight)
        XCTAssertEqual(ShellListLayout.rowHeight(of: ended), SubagentListLayout.rowHeight)
        // A name cut at 200 characters by the record is still the command's.
        let long = String(repeating: "x", count: 250)
        XCTAssertTrue(shell("n", String(long.prefix(199)) + "…", command: long).isNamedByItsCommand)
        XCTAssertFalse(shell("n", "Dev", command: long).isNamedByItsCommand)
    }

    func testTheListsHeightCountsEveryPartOfIt() {
        let base = SubagentListLayout.headerHeight + 2 * SubagentListLayout.verticalPadding
        let running = shell("n", "Dev", command: "pnpm dev"), ended = shell("b", state: .completed)
        XCTAssertEqual(SubagentListLayout.height(of: []), base)
        XCTAssertEqual(SubagentListLayout.height(of: [agent("a")]), base + SubagentListLayout.workingRowHeight, "Agents alone: as before.")
        XCTAssertEqual(SubagentListLayout.height(of: [], shells: [running, ended]), base + SubagentListLayout.workingRowHeight + SubagentListLayout.rowHeight,
                       "Alone, the shells have the list's own title: no section under it.")
        XCTAssertEqual(SubagentListLayout.height(of: [agent("a")], shells: [running]),
                       base + SubagentListLayout.workingRowHeight + ShellListLayout.sectionHeight + SubagentListLayout.workingRowHeight)
        XCTAssertEqual(SubagentListLayout.height(of: [], shells: [], unseen: 2), base + SubagentListLayout.rowHeight, "The shells Nook cannot name are one row, however many.")
        XCTAssertEqual(SubagentListLayout.height(of: [agent("a")], shells: [], unseen: 1), base + SubagentListLayout.workingRowHeight + ShellListLayout.sectionHeight + SubagentListLayout.rowHeight)
    }

    func testRunningShellsComeFirstThenTheOnesThatFailed() {
        let shells = [shell("done1", state: .completed), shell("run1"), shell("fail1", state: .failed), shell("run2"), shell("stop1", state: .stopped), shell("done2", state: .completed)]
        XCTAssertEqual(ShellListLayout.ordered(shells).map(\.id), ["run1", "run2", "fail1", "done1", "stop1", "done2"])
    }

    func testTheCommandIsOneCalmLine() {
        XCTAssertEqual(shell(command: "  gcloud   builds\tsubmit  .  ").commandPreview, "gcloud builds submit .")
        XCTAssertEqual(shell(command: "cd /Users/me/VIBE && pnpm turbo run test\npnpm lint").commandPreview, "cd /Users/me/VIBE && pnpm turbo run test …", "More lines are said, not shown.")
        XCTAssertEqual(shell(command: "\n\n  echo hi\n").commandPreview, "echo hi")
        XCTAssertEqual(shell(command: "").commandPreview, "")
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(shell(command: long).commandPreview.count, 160)
        XCTAssertTrue(shell(command: long).commandPreview.hasSuffix("…"))
    }

    func testTheTooltipHasTheNameTheWholeCommandAndWhereTheShellStands() {
        let building = ShellActivity(id: "b", name: "Build", command: "cd app\npnpm build", state: .running, started: Date().addingTimeInterval(-192))
        XCTAssertEqual(ShellWords.rowHelp(building, opens: true).components(separatedBy: "\n"), ["Build", "$ cd app", "pnpm build", "en curso", "Clic para ver su salida"],
                       "A running shell's seconds tick in its row; a tooltip that changed every second would be taken down each time.")
        XCTAssertEqual(ShellWords.rowHelp(building, opens: true), ShellWords.rowHelp(building, opens: true))
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let ended = ShellActivity(id: "e", name: "Build", command: "pnpm build", state: .failed, exitCode: 1, started: t0, ended: t0.addingTimeInterval(74))
        XCTAssertEqual(ShellWords.rowHelp(ended, opens: false).components(separatedBy: "\n"), ["Build", "$ pnpm build", "falló (código 1) · 1m 14s"], "How long a finished one took does not change.")
        XCTAssertEqual(ShellOutputWords.barHelp(ended), "Build\n$ pnpm build\nfalló (código 1) · 1m 14s")
        XCTAssertFalse(ShellWords.rowHelp(shell(), opens: false).contains("Clic para ver su salida"), "A plain row does not promise a click.")
        XCTAssertTrue(ShellWords.rowHelp(shell(moved: true), opens: false).contains("Claude lo pasó a segundo plano"))
        XCTAssertEqual(ShellWords.rowHelp(shell(command: ""), opens: false).components(separatedBy: "\n").count, 2, "No command, no line for it.")
        let many = (1...12).map { "paso \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ShellWords.tooltipCommand(many)?.components(separatedBy: "\n").count, 8, "Eight lines, and the ellipsis on the last.")
        XCTAssertTrue(ShellWords.tooltipCommand(many)?.hasSuffix("paso 8 …") == true)
        XCTAssertNil(ShellWords.tooltipCommand(" \n "))
        XCTAssertEqual(ShellWords.tooltipCommand(String(repeating: "x", count: 900))?.count, 599 + 2)
    }

    func testTheWordsForShellsTheRecordDoesNotName() {
        XCTAssertEqual(ShellWords.unseenRow(1, alongside: false), "1 shell, lanzado antes de lo que Nook leyó")
        XCTAssertEqual(ShellWords.unseenRow(2, alongside: false), "2 shells, lanzados antes de lo que Nook leyó")
        XCTAssertEqual(ShellWords.unseenRow(1, alongside: true), "1 más, lanzado antes de lo que Nook leyó")
        XCTAssertEqual(ShellWords.unseenRow(3, alongside: true), "3 más, lanzados antes de lo que Nook leyó")
        XCTAssertTrue(ShellWords.unseenHelp(1).contains("Nook no puede abrirlo"))
        XCTAssertTrue(ShellWords.unseenHelp(2).contains("Nook no puede abrirlos"))
        XCTAssertTrue(ShellWords.unseenHelp(2).contains("Gestionar (↓)"), "It says where they can be reached.")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let lines = ShellWords.capsuleLines([ShellActivity(id: "b", name: "Build", command: "", state: .failed, exitCode: 2, started: t0, ended: t0.addingTimeInterval(12)),
                                             ShellActivity(id: "a", name: "Dev", command: "", state: .running, started: t0)], unseen: 1)
        XCTAssertEqual(lines, ["● Dev (shell) — en curso", "! Build (shell) — falló (código 2) · 12s", "? 1 más, lanzado antes de lo que Nook leyó"],
                       "The ones that run first, as in the list; a mark for each state; and the hint last.")
        XCTAssertEqual(ShellWords.capsuleLines([], unseen: 2), ["? 2 shells, lanzados antes de lo que Nook leyó"])
    }

    func testRowsAreOnlyButtonsWhenSomeoneListens() {
        XCTAssertNil(ShellRow(shell: shell()).onOpen)
        var opened: [String] = []
        let row = ShellRow(shell: shell(), onOpen: { opened.append($0.id) })
        row.onOpen?(shell())
        XCTAssertEqual(opened, ["bdev00001"])
    }

    // MARK: The time ticks

    func testARunningRowsTimeTicksOnItsOwnAndAFinishedRowsDoesNot() {
        struct Rows: View {
            var body: some View {
                VStack(alignment: .leading) {
                    ShellRow(shell: ShellActivity(id: "run", name: "Corriendo", command: "", state: .running, started: Date().addingTimeInterval(-5)))
                    ShellRow(shell: ShellActivity(id: "end", name: "Terminado", command: "", state: .completed, started: Date().addingTimeInterval(-100), ended: Date().addingTimeInterval(-40)))
                    ShellRow(shell: ShellActivity(id: "held", name: "Quieto", command: "", state: .running, started: Date().addingTimeInterval(-5)), ticking: false)
                }.frame(width: 470).environment(\.colorScheme, .dark)
            }
        }
        let (window, _) = mount(Rows(), size: NSSize(width: 470, height: 100))
        let first = words(in: window)
        XCTAssertTrue(first.contains { $0.contains("Corriendo") && ($0.contains("en curso · 5s") || $0.contains("en curso · 6s")) }, "\(first)")
        let before = first.filter { $0.contains("en curso") }
        settle(2.2)
        let after = words(in: window).filter { $0.contains("en curso") }
        XCTAssertNotEqual(before, after, "The running row's seconds moved on without a new reading of the record.")
        XCTAssertTrue(words(in: window).contains { $0.contains("terminó · 1m") }, "A finished row's time is where it stopped.")
        // The row that is held keeps what it showed; it is the island out of sight.
        let held = words(in: window).filter { $0.contains("Quieto") }
        XCTAssertTrue(held.allSatisfy { $0.contains("en curso · 5s") || $0.contains("en curso · 6s") }, "\(held)")
    }

    // MARK: The capsule's life

    private final class Feed: ObservableObject {
        @Published var agents: [SubagentActivity] = []
        @Published var shells: [ShellActivity] = []
        @Published var screen: Int?
    }

    private struct CapsuleHost: View {
        @ObservedObject var feed: Feed
        var body: some View {
            // Long enough that a slow machine, whose every look at the screen takes a while, still sees the capsule in the state each step is about.
            HStack { Spacer(); SubagentCapsule(agents: feed.agents, shells: feed.shells, screenShellCount: feed.screen, animated: false, linger: 1.2, hintSettle: 1.2) }
                .padding(20).frame(width: 400, height: 80).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        }
    }

    func testTheCapsuleShowsWhileAShellRunsLingersAndGoes() {
        let feed = Feed()
        let (window, _) = mount(CapsuleHost(feed: feed), size: NSSize(width: 400, height: 80))
        XCTAssertFalse(has("de Claude", in: window), "Nothing runs: no capsule.")

        feed.shells = [shell()]
        XCTAssertTrue(wait { has("Shells de Claude: 1 shell", in: window) }, "A running shell is enough for the capsule: \(words(in: window)).")

        feed.shells = [shell(state: .completed, exit: 0)]
        XCTAssertTrue(wait { has("Shells de Claude: 1 shell listo", in: window) }, "It lingers a moment once the shell ends.")
        XCTAssertTrue(wait(5) { !has("de Claude", in: window) }, "…and goes.")
    }

    func testOldFinishedShellsLeaveTheCapsuleQuiet() {
        let feed = Feed()
        feed.shells = [shell(state: .completed, exit: 0), shell("b", state: .failed, exit: 1)]
        let (window, _) = mount(CapsuleHost(feed: feed), size: NSSize(width: 400, height: 80))
        settle(0.6)
        XCTAssertFalse(has("de Claude", in: window), "A tab opened with only shells that ended before shows no capsule: the list under its tab is for what works.")
    }

    func testAShellAndAnAgentShareOneCapsule() {
        let feed = Feed()
        feed.agents = [agent("a"), agent("b")]
        let (window, _) = mount(CapsuleHost(feed: feed), size: NSSize(width: 400, height: 80))
        XCTAssertTrue(wait { has("Agentes de Claude: 2 agentes", in: window) })
        feed.shells = [shell()]
        XCTAssertTrue(wait { has("Agentes y shells de Claude: 2 agentes · 1 shell", in: window) }, "\(words(in: window))")
    }

    func testAShellClaudeCountsAndNookCannotNameShowsOnceTheCountHolds() {
        let feed = Feed()
        let (window, _) = mount(CapsuleHost(feed: feed), size: NSSize(width: 400, height: 80))
        feed.screen = 1
        XCTAssertFalse(has("de Claude", in: window), "The line may be a moment ahead of the record, or behind it: a count is not believed at once.")
        XCTAssertTrue(wait(4) { has("Shells de Claude: 1 shell", in: window) }, "…but is once it has held.")
        feed.screen = nil
        XCTAssertTrue(wait(1) { !has("de Claude", in: window) }, "It stops counting the moment the line does.")

        // A count that does not hold never shows.
        feed.screen = 2
        settle(0.2)
        feed.screen = nil
        settle(1.6)
        XCTAssertFalse(has("de Claude", in: window))
        // The record naming the shell is not a second one.
        feed.screen = 1
        feed.shells = [shell()]
        settle(1.6)
        XCTAssertTrue(has("Shells de Claude: 1 shell", in: window))
        XCTAssertFalse(has("2 shells", in: window))
    }

    // MARK: Entering from a list

    func testAClickOnAShellRowOfTheComposersListEntersItAndPutsTheListAway() throws {
        var picked: [String] = []
        let running = shell("brun0001", "Servidor de desarrollo", command: "pnpm dev")
        // The list closes by itself 0.6 s after it opens when the pointer is not over it, so the click comes quickly; on a busy machine the window may
        // not be laid out in time, and the attempt is made again.
        for _ in 0..<3 where picked.isEmpty {
            let view = ZStack(alignment: .topTrailing) {
                Color.black
                HStack { Spacer(); SubagentCapsule(agents: [], shells: [running, shell("bend0001", "Construir", state: .completed, exit: 0)], alwaysVisible: true, initiallyOpen: true,
                                                   onOpenShell: { picked.append($0.id) }) }
                    .padding(.trailing, 25).padding(.top, 196)
            }.frame(width: 572, height: 266).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
            let (window, _) = mount(view, size: NSSize(width: 572, height: 266), key: true)
            // The list floats over the capsule: its bottom 6 pt over the capsule's top (196); the header, then the running shell's row (with its command).
            let rows = SubagentListLayout.height(of: [], shells: [running, shell("bend0001", state: .completed)])
            let listTop = 196 - 6 - rows
            let firstRow = listTop + SubagentListLayout.verticalPadding + SubagentListLayout.headerHeight + SubagentListLayout.workingRowHeight / 2
            click(window, at: NSPoint(x: 330, y: firstRow), settle: 0.05)
            window.orderOut(nil)
        }
        XCTAssertEqual(picked.first, "brun0001")
    }

    func testAClickOnARowOfATabsListEntersThatShellAndClosesTheList() throws {
        let model = model()
        let session = claudeSession(model, shells: [shell("bend0001", "Construir", state: .completed, exit: 0), shell("brun0001", "Servidor de desarrollo", command: "pnpm dev")])
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        let presenter = TabAgentListPresenter()
        presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let (window, _) = mount(NookPanel(model: model, agentList: presenter).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: size, key: true)
        settle(0.4)
        XCTAssertEqual(presenter.open?.id, session.id)

        // The list hangs under the tab row: its title (this tab has no agents), then the running shell first, then the one that ended.
        let top = model.neckHeight + TabAgentListLayout.originY + SubagentListLayout.verticalPadding + SubagentListLayout.headerHeight
        click(window, at: NSPoint(x: 232, y: top + SubagentListLayout.workingRowHeight / 2))
        XCTAssertEqual(session.viewedShell, "brun0001", "The click showed the running shell's output.")
        XCTAssertNil(presenter.open, "…and the list went away.")

        model.leaveAgentView()
        presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        settle()
        click(window, at: NSPoint(x: 232, y: top + SubagentListLayout.workingRowHeight + SubagentListLayout.rowHeight / 2))
        XCTAssertEqual(session.viewedShell, "bend0001")
    }

    // MARK: The output in the mirror's place

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var escapes: Escapes
        var body: some View {
            SessionPane(model: model, session: session)
                .frame(width: 572, height: 204).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                .onExitCommand { escapes.count += 1 }
        }
    }

    private final class Escapes { var count = 0 }

    private func texts(in host: NSView) -> [String] { descendants(of: host, as: LiveTerminalScrollView.self).map { $0.textView.string } }

    func testEnteringAShellShowsItsOutputAndKeepsClaudesConversationUnderIt() {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let (window, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        XCTAssertEqual(texts(in: host), ["> pregunta\n\n⏺ respuesta\n\n"])
        XCTAssertFalse(has("Volver a Claude", in: window))

        model.openShell(running, in: session)
        session.applyShellOutput(ShellOutput(text: "ready on :3000\nGET / 200\n"), id: "bdev00001")
        settle(0.4)
        XCTAssertEqual(texts(in: host), ["> pregunta\n\n⏺ respuesta\n\n", "ready on :3000\nGET / 200"],
                       "Claude's conversation stays under the shell's output (its scroll and selection with it), and the output has no blank line after its last one.")
        XCTAssertTrue(has("Volver a Claude", in: window))
        XCTAssertTrue(has("Salida del shell Dev server", in: window))
        XCTAssertTrue(has("en curso · 1m", in: window), "The state and the time are in the bar: \(words(in: window))")

        // The output is plain text, not Claude's transcript: no styling of messages and tools.
        let shellMirror = descendants(of: host, as: LiveTerminalScrollView.self)[1]
        XCTAssertNil(shellMirror.textView.textStorage?.attribute(.transcriptBubble, at: 0, effectiveRange: nil))
        XCTAssertEqual(shellMirror.contentID, "shell:bdev00001")

        model.leaveAgentView()
        settle(0.3)
        XCTAssertEqual(texts(in: host), ["> pregunta\n\n⏺ respuesta\n\n"], "Back to Claude's conversation alone.")
        XCTAssertFalse(has("Volver a Claude", in: window))
    }

    func testEscLeavesTheShellsOutputAndOnlyTheNextOneReachesTheIsland() throws {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let escapes = Escapes()
        let (window, host) = mount(Island(model: model, session: session, escapes: escapes), size: NSSize(width: 572, height: 204), key: true)
        let field = try XCTUnwrap(descendants(of: host, as: ComposerFieldView.self).first).textView
        window.makeFirstResponder(field)
        settle()

        model.openShell(running, in: session)
        session.applyShellOutput(ShellOutput(text: "ready\n"), id: "bdev00001")
        settle()
        XCTAssertEqual(session.viewedShell, "bdev00001")
        pressEscape(in: window)
        XCTAssertNil(session.viewedShell, "Esc went back to Claude.")
        XCTAssertEqual(escapes.count, 0, "…and did not put the island away.")
        XCTAssertEqual(texts(in: host), ["> pregunta\n\n⏺ respuesta\n\n"])

        pressEscape(in: window)
        XCTAssertEqual(escapes.count, 1, "With no shell shown, Esc is the island's again.")
    }

    func testTheFieldSaysItWritesToClaudeAndTheBannerStepsAsideWhileAShellIsShown() throws {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let (_, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        let field = try XCTUnwrap(descendants(of: host, as: ComposerFieldView.self).first).textView
        XCTAssertNotEqual(field.placeholder, "Mensaje para Claude…")
        model.openShell(running, in: session)
        settle()
        XCTAssertEqual(field.placeholder, "Mensaje para Claude…", "What is written still goes to Claude.")
        model.leaveAgentView()
        settle()
        XCTAssertNotEqual(field.placeholder, "Mensaje para Claude…")
    }

    func testAShellThatLeftTheListIsStillShownWithTheWayBack() {
        let model = model()
        let session = claudeSession(model, shells: [])
        model.sessions = [session]; model.selectedID = session.id
        let (window, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        // Entered while its row was on the list, and the row went (ten minutes after the shell ended): the output stays.
        model.view(shell: "bgone0001", in: session)
        session.applyShellOutput(ShellOutput(text: "Deploying…\nDone in 12.4s\n"), id: "bgone0001")
        settle(0.4)
        XCTAssertEqual(texts(in: host).last, "Deploying…\nDone in 12.4s")
        XCTAssertTrue(has("Volver a Claude", in: window))
        XCTAssertTrue(has("Salida de un shell anterior", in: window), "The bar says what it can: its row is gone, and so are its name and command.")
        XCTAssertFalse(has("Copiar el comando", in: window), "There is no command to copy.")
        model.view(shell: nil, in: session)
        settle(0.3)
        XCTAssertNil(session.viewedShell)
        XCTAssertFalse(has("Volver a Claude", in: window))
    }

    func testTheBarCopiesTheCommand() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-shell-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var copied = 0
        let bar = ShellViewBar(shell: shell(command: "gcloud builds submit ."), pasteboard: pasteboard, onBack: {}, onCopy: { copied += 1 })
            .frame(width: 560).padding(8).background(Color.black).environment(\.colorScheme, .dark)
        let (window, _) = mount(bar, size: NSSize(width: 576, height: 44), key: true)
        let center = try XCTUnwrap(AccessibilityLookup.center(of: "Copiar el comando", in: window))
        click(window, at: center)
        XCTAssertEqual(pasteboard.string(forType: .string), "gcloud builds submit .")
        XCTAssertEqual(copied, 1, "The composer's status line says it was copied.")
    }

    func testTheBarGoesBackToClaude() throws {
        var back = 0
        let bar = ShellViewBar(shell: shell(), onBack: { back += 1 }).frame(width: 560).padding(8).background(Color.black).environment(\.colorScheme, .dark)
        let (window, _) = mount(bar, size: NSSize(width: 576, height: 44), key: true)
        let center = try XCTUnwrap(AccessibilityLookup.center(of: "Volver a Claude", in: window))
        click(window, at: center)
        XCTAssertEqual(back, 1)
    }

    // MARK: The output follows its end

    func testTheOutputFollowsItsEndUntilTheReaderScrollsUp() throws {
        let lines = (1...80).map { "línea \($0) de la salida del shell" }
        let feed = ObservableFeed(ShellOutput(text: lines.joined(separator: "\n") + "\n"))
        let (_, host) = mount(ObservedPane(feed: feed), size: NSSize(width: 532, height: 130))
        let scroll = try XCTUnwrap(descendants(of: host, as: LiveTerminalScrollView.self).first)
        func atEnd() -> Bool { abs(scroll.contentView.bounds.origin.y - (scroll.textView.frame.height - scroll.contentSize.height)) < 2 }
        XCTAssertTrue(atEnd(), "A shell's output opens at its end, where it is live.")

        feed.output = ShellOutput(text: (lines + ["línea 81 nueva"]).joined(separator: "\n") + "\n")
        settle(0.3)
        XCTAssertTrue(scroll.textView.string.hasSuffix("línea 81 nueva"))
        XCTAssertTrue(atEnd(), "New output keeps the reader at the end.")

        // The reader scrolls up to read: new output does not take them away from it.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120)); scroll.reflectScrolledClipView(scroll.contentView)
        feed.output = ShellOutput(text: (lines + ["línea 81 nueva", "línea 82 más nueva"]).joined(separator: "\n") + "\n")
        settle(0.3)
        XCTAssertTrue(scroll.textView.string.hasSuffix("línea 82 más nueva"))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 120, accuracy: 1, "They go on reading where they were.")
        XCTAssertFalse(atEnd())
    }

    private final class ObservableFeed: ObservableObject {
        @Published var output: ShellOutput
        init(_ output: ShellOutput) { self.output = output }
    }

    private struct ObservedPane: View {
        @ObservedObject var feed: ObservableFeed
        var body: some View {
            ShellOutputPane(id: "bdev00001", shell: ShellActivity(id: "bdev00001", name: "Dev server", command: "pnpm dev", state: .running, started: Date()), output: feed.output, onBack: {})
                .frame(width: 520, height: 130).padding(.horizontal, 6).background(Color.black).environment(\.colorScheme, .dark)
        }
    }

    /// The whole path with a real file: Claude's record names the shell, the island lists it, a click shows its output, and what the command goes on
    /// writing arrives in the mirror, which keeps following its end.
    func testTheOutputOfARealFileArrivesAndKeepsFollowingItsEnd() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-shellui-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("claude-\(getuid())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true)
        let out = root.appendingPathComponent("tasks/bui000001.output")
        let first = (1...60).map { "\u{1B}[32mlínea \($0)\u{1B}[0m" }.joined(separator: "\n") + "\n"
        try Data(first.utf8).write(to: out)
        let record = folder.appendingPathComponent("s.jsonl")
        try ([TranscriptFixtures.call("c1", "Bash", ["command": "pnpm dev", "description": "Servidor", "run_in_background": true]),
              TranscriptFixtures.result("c1", "Command running in background with ID: bui000001. Output is being written to: \(out.path). You will be notified when it completes.",
                                        details: ["backgroundTaskId": "bui000001"])].joined(separator: "\n") + "\n").write(to: record, atomically: true, encoding: .utf8)

        let model = model()
        let session = claudeSession(model, modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let follower = TranscriptFollower(url: record)
        follower.shellRoots = [root.path]
        session.transcript = follower
        let (_, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        model.followTranscript(session)
        XCTAssertTrue(wait { session.shells.map(\.name) == ["Servidor"] }, "Claude's record names the shell.")

        model.openShell(session.shells[0], in: session)
        XCTAssertTrue(wait { texts(in: host).count == 2 && texts(in: host)[1].hasSuffix("línea 60") }, "The output is read and shown, without its colour codes: \(texts(in: host).map { String($0.suffix(30)) })")
        let scroll = descendants(of: host, as: LiveTerminalScrollView.self)[1]
        func atEnd() -> Bool { abs(scroll.contentView.bounds.origin.y - (scroll.textView.frame.height - scroll.contentSize.height)) < 2 }
        XCTAssertTrue(atEnd())

        let handle = try FileHandle(forWritingTo: out)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\u{1B}[32mlínea 61 que llega después\u{1B}[0m\n".utf8))
        try handle.close()
        model.followTranscript(session)
        XCTAssertTrue(wait { texts(in: host)[1].hasSuffix("línea 61 que llega después") }, "What the command writes next arrives.")
        settle(0.2)
        XCTAssertTrue(atEnd(), "…and the mirror follows it.")

        model.leaveAgentView()
        model.followTranscript(session)
        settle(0.2)
        XCTAssertEqual(follower.watchedShellOutputs, 0, "Back to Claude, the file is no longer read.")
    }

    // MARK: Empty states

    func testTheOutputSaysWhatItIsLike() {
        let running = shell(), ended = shell(state: .completed, exit: 0)
        XCTAssertEqual(ShellOutputState(output: nil, shell: running), .reading)
        XCTAssertEqual(ShellOutputState(output: ShellOutput(text: ""), shell: running), .silent(running: true))
        XCTAssertEqual(ShellOutputState(output: ShellOutput(text: " \n\t\n"), shell: ended), .silent(running: false), "Blank lines are no output.")
        XCTAssertEqual(ShellOutputState(output: ShellOutput(text: "hola\n"), shell: running), .showing)
        XCTAssertEqual(ShellOutputState(output: ShellOutput(available: false), shell: running), .unavailable(named: true))
        XCTAssertEqual(ShellOutputState(output: ShellOutput(available: false), shell: shell(path: nil)), .unavailable(named: false))
        XCTAssertEqual(ShellOutputState(output: ShellOutput(available: false), shell: nil), .unavailable(named: false))
        XCTAssertEqual(ShellOutputState(output: ShellOutput(text: ""), shell: nil), .silent(running: false))

        XCTAssertEqual(ShellOutputState.reading.title, "Leyendo la salida…")
        XCTAssertEqual(ShellOutputState.silent(running: true).title, "Sin salida todavía")
        XCTAssertEqual(ShellOutputState.silent(running: false).title, "Sin salida")
        XCTAssertEqual(ShellOutputState.silent(running: true).detail, "Si el comando manda su salida a otro archivo, aquí no aparecerá.")
        XCTAssertEqual(ShellOutputState.unavailable(named: true).title, "La salida de este shell no está disponible")
        XCTAssertEqual(ShellOutputState.unavailable(named: true).detail, "Su archivo ya no existe o Nook no puede abrirlo.")
        XCTAssertEqual(ShellOutputState.unavailable(named: false).detail, "Claude no indicó dónde guarda su salida.")
        XCTAssertNil(ShellOutputState.showing.title)
        XCTAssertGreaterThan(ShellOutputState.reading.delay, 0, "Right after entering the file is being read: that is no reason to say anything yet.")
        let keys = Set([ShellOutputState.reading, .silent(running: true), .silent(running: false), .unavailable(named: true), .unavailable(named: false), .showing].map(\.key))
        XCTAssertEqual(keys.count, 6, "Each state fades in on its own.")
    }

    func testThePlaceholdersAppearOnceTheirStateHasHeldForAMoment() {
        let feed = ObservableFeed(ShellOutput(text: ""))
        let (window, _) = mount(ObservedPane(feed: feed), size: NSSize(width: 532, height: 130))
        XCTAssertTrue(wait { has("Sin salida todavía", in: window) }, "\(words(in: window))")
        XCTAssertTrue(has("aquí no aparecerá", in: window))
        feed.output = ShellOutput(text: "primera línea\n")
        XCTAssertTrue(wait { !has("Sin salida todavía", in: window) }, "The first line takes the words away.")
        feed.output = ShellOutput(available: false)
        XCTAssertTrue(wait { has("La salida de este shell no está disponible", in: window) })
    }

    func testTheClippedNoticeIsSaidUnderTheBarAndNotInTheText() {
        let feed = ObservableFeed(ShellOutput(text: "una línea\n", clipped: true))
        let (window, host) = mount(ObservedPane(feed: feed), size: NSSize(width: 532, height: 130))
        XCTAssertTrue(has("Se muestran solo los últimos ~200 KB", in: window), "\(words(in: window))")
        XCTAssertEqual(texts(in: host), ["una línea"], "The notice is not in the text, which follows its end.")
        feed.output = ShellOutput(text: "una línea\n", clipped: false)
        XCTAssertTrue(wait { !has("Se muestran solo los últimos", in: window) })
        XCTAssertEqual(ShellOutputWords.mirrorText(ShellOutput(text: "a\n\n\n")), "a")
        XCTAssertEqual(ShellOutputWords.mirrorText(ShellOutput(text: "a\n  b")), "a\n  b", "An unfinished last line is shown as it is.")
        XCTAssertEqual(ShellOutputWords.mirrorText(nil), "")
        XCTAssertEqual(ShellOutputWords.mirrorText(ShellOutput(text: "x", available: false)), "")
    }

    // MARK: The notice

    func testTheNoticeHangsUnderTheShellsBarWhileOneIsShown() throws {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let (window, _) = mount(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: size)
        model.notice = "Copiado al portapapeles."
        settle(0.4)
        let plain = try XCTUnwrap(AccessibilityLookup.center(of: "Aviso", in: window))

        model.openShell(running, in: session)
        session.applyShellOutput(ShellOutput(text: "ready\n"), id: "bdev00001")
        settle(0.4)
        XCTAssertTrue(has("Volver a Claude", in: window))
        let shown = try XCTUnwrap(AccessibilityLookup.center(of: "Aviso", in: window), "The notice is still there.")
        let back = try XCTUnwrap(AccessibilityLookup.center(of: "Volver a Claude", in: window))
        XCTAssertEqual(shown.x, plain.x, accuracy: 1, "Still centred across the island.")
        XCTAssertEqual(shown.y - plain.y, NoticeMetrics.viewBar, accuracy: 1, "It hangs from the bar's lower edge instead of from the top of the conversation.")
        XCTAssertLessThan(back.y, shown.y - 19, "The way back to Claude is above the card (a line of it is 38 pt), not under it.")
    }

    // MARK: Motion

    /// Like the agent's bar, the shell's comes in by fading its own opacity: nothing below it moves, so the mirror changes size at once and only once.
    func testTheBarFadesInWithoutMovingTheOutputUnderIt() {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let (window, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        model.openShell(running, in: session)
        session.applyShellOutput(ShellOutput(text: (1...30).map { "línea \($0)" }.joined(separator: "\n") + "\n"), id: "bdev00001")
        settle(0.05)
        func frame() -> NSRect? { descendants(of: host, as: LiveTerminalScrollView.self).dropFirst().first.map { $0.convert($0.bounds, to: nil) } }
        let first = frame()
        XCTAssertNotNil(first)
        var seen = Set<String>()
        let start = Date()
        while Date().timeIntervalSince(start) < 0.5 {
            settle(0.02)
            seen.insert(frame().map { "\($0)" } ?? "gone")
        }
        XCTAssertEqual(seen, [frame().map { "\($0)" } ?? "gone"], "The output under the bar kept one place while the bar came in.")
        XCTAssertEqual(frame(), first)
        withExtendedLifetime(window) {}
    }

    // MARK: The pointer

    func testClaudesMirrorUnderTheShellsOutputGivesUpThePointer() {
        let model = model()
        let running = shell()
        let session = claudeSession(model, shells: [running], modeHint: 1)
        model.sessions = [session]; model.selectedID = session.id
        let (_, host) = mount(Island(model: model, session: session, escapes: Escapes()), size: NSSize(width: 572, height: 204))
        let claudes = descendants(of: host, as: LiveTerminalScrollView.self)[0]
        XCTAssertTrue(claudes.textView.claimsPointer, "On show, the conversation's text has the I-beam.")
        model.openShell(running, in: session)
        session.applyShellOutput(ShellOutput(text: "ready\n"), id: "bdev00001")
        settle(0.4)
        let mirrors = descendants(of: host, as: LiveTerminalScrollView.self)
        XCTAssertEqual(mirrors.count, 2)
        XCTAssertTrue(mirrors[0] === claudes, "Claude's mirror stays where it was.")
        XCTAssertFalse(claudes.textView.claimsPointer, "It is faded out under the output: a transparent text view still claims the pointer, and its I-beam would show over the shell's.")
        XCTAssertTrue(mirrors[1].textView.claimsPointer, "The output's own text has it.")
        model.leaveAgentView()
        settle(0.4)
        XCTAssertTrue(claudes.textView.claimsPointer, "Back to Claude, the text takes the pointer again.")
    }

    func testTheShellsListIsChromeOverTheMirrorAndMarksItself() {
        let view = ZStack(alignment: .bottomTrailing) {
            LiveTerminalSurface(text: String(repeating: "una línea de texto del espejo, bastante larga para llenar el ancho\n", count: 14))
            SubagentCapsule(agents: [], shells: [shell(), shell("b", state: .failed, exit: 1)], alwaysVisible: true, initiallyOpen: true).padding(8)
        }.frame(width: 560, height: 260).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        let (window, _) = mount(view, size: NSSize(width: 560, height: 260))
        XCTAssertFalse(PointerHoles.frames(in: window).isEmpty, "The list marks where it stands, so the text under it gives the pointer up there.")
    }
}
