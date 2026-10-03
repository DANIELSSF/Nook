import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Entering a subagent's conversation and coming back: the state the model keeps, the keys, and what the pane shows.
@MainActor
final class AgentViewTests: XCTestCase {
    private func agent(_ id: String, _ name: String = "Diseñar el gato", state: SubagentActivity.State = .running) -> SubagentActivity {
        var shown = SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 12, tokens: "30k", duration: "2m 8s")
        shown.model = "sonnet"
        return shown
    }

    private func claudeSession(_ model: AppModel, tty: String = "/dev/ttys080", agents: [SubagentActivity] = []) -> TerminalSession {
        let rule = String(repeating: "─", count: 60)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        // Nothing here may go looking for Claude's record on disk.
        session.transcriptLocated = Date()
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil, agents: agents)
        return session
    }

    private func model() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-agentview-" + UUID().uuidString)!) }

    // MARK: Entering and leaving

    func testClickingARowShowsTheAgentsConversationAndLeavingGoesBack() {
        let model = model()
        let a = agent("call-a")
        let session = claudeSession(model, agents: [a])
        model.sessions = [session]; model.selectedID = session.id

        XCTAssertFalse(model.leaveAgentView(), "Nothing to leave: Esc keeps its other meaning.")
        model.openAgent(a, in: session)
        XCTAssertEqual(session.viewedAgent, "call-a")
        XCTAssertEqual(session.displayText, "", "Empty until the agent's record is read.")
        session.applyAgentText("> tarea del agente\n\n⏺ empiezo\n\n", call: "call-a")
        XCTAssertEqual(session.displayText, "> tarea del agente\n\n⏺ empiezo\n\n")

        XCTAssertTrue(model.leaveAgentView())
        XCTAssertNil(session.viewedAgent)
        XCTAssertEqual(session.displayText, "> pregunta\n\n⏺ respuesta\n\n", "Back to Claude's conversation.")
        XCTAssertFalse(model.leaveAgentView(), "A second Esc is the island's.")
    }

    func testOnlyAgentsAreEntered() {
        let model = model()
        var message = agent("msg", "a otro agente", state: .done)
        message.role = .message
        let session = claudeSession(model, agents: [message])
        model.sessions = [session]; model.selectedID = session.id
        model.openAgent(message, in: session)
        XCTAssertNil(session.viewedAgent, "A message to another agent has no conversation of its own.")
    }

    func testEnteringTheAgentOfAnotherTabBringsThatTabForward() {
        let model = model()
        let first = claudeSession(model, tty: "/dev/ttys081")
        let other = agent("call-b")
        let second = claudeSession(model, tty: "/dev/ttys082", agents: [other])
        model.sessions = [first, second]; model.selectedID = first.id
        // The list under a tab's badge belongs to that tab, whichever one is open.
        model.openAgent(other, in: second)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(second.viewedAgent, "call-b")
        XCTAssertNil(first.viewedAgent)
    }

    func testSwitchingTabsReturnsTheTabLeftToClaude() {
        let model = model()
        let a = agent("call-a")
        let first = claudeSession(model, tty: "/dev/ttys083", agents: [a])
        let second = claudeSession(model, tty: "/dev/ttys084")
        model.sessions = [first, second]; model.selectedID = first.id
        model.openAgent(a, in: first)
        XCTAssertEqual(first.viewedAgent, "call-a")
        model.select(second)
        XCTAssertNil(first.viewedAgent, "Picking another tab leaves the agent's view.")
        XCTAssertEqual(first.displayText, "> pregunta\n\n⏺ respuesta\n\n")

        // Terminal's own tab switches, which Nook follows, change the selection without `select`.
        model.select(first)
        model.openAgent(a, in: first)
        model.selectedID = second.id
        XCTAssertNil(first.viewedAgent)
        model.selectedID = first.id
        XCTAssertNil(first.viewedAgent, "Coming back to the tab finds Claude's conversation.")
    }

    func testSendingAMessageReturnsToClaude() {
        // A session of Nook's own (tmux) takes the send path that never reaches Terminal.
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-agentview-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-av-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyTranscript("> pregunta\n\n", recap: nil)
        session.view(agent: "call-a")
        session.applyAgentText("> tarea\n\n", call: "call-a")
        XCTAssertEqual(session.displayText, "> tarea\n\n")
        session.send("hola Claude")
        XCTAssertNil(session.viewedAgent, "The message goes to Claude: its conversation comes back to show it arriving.")
        XCTAssertEqual(session.displayText, "> pregunta\n\n")
    }

    func testTheAgentViewEndsWhenTheTabStopsShowingClaude() {
        let model = model()
        let session = claudeSession(model)
        // An agent's view needs Claude's record; this one is an empty file.
        session.transcript = TranscriptFollower(url: URL(fileURLWithPath: "/dev/null"))
        session.view(agent: "call-a")
        var plain = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys080", customTitle: "", processes: ["zsh"], busy: false, selected: true, text: "$ ls")
        plain.history = true
        session.update(plain)
        XCTAssertNil(session.viewedAgent)
    }

    // MARK: The bar's words

    func testTheBarSaysHowAnAgentEnded() {
        XCTAssertEqual(AgentViewBar.endingText(agent("a", state: .done)), "Listo · 2m 8s")
        var bare = SubagentActivity(id: "b", name: "x", state: .done)
        bare.toolUses = nil; bare.tokens = nil; bare.duration = nil
        XCTAssertEqual(AgentViewBar.endingText(bare), "Listo")
        var failed = agent("c", state: .failed)
        failed.note = "Interrumpido"
        XCTAssertTrue(AgentViewBar.endingText(failed).hasPrefix("Interrumpido"))
    }

    // MARK: Esc and the pane

    private final class Escapes { var count = 0 }

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

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func pressEscape(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            window.sendEvent(event)
        }
        settle()
    }

    func testEscInTheFieldLeavesTheAgentViewAndOnlyTheNextOneReachesTheIsland() throws {
        let model = model()
        let a = agent("call-a")
        let session = claudeSession(model, agents: [a])
        model.sessions = [session]; model.selectedID = session.id
        let escapes = Escapes()
        let host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 204), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
        let field = try XCTUnwrap(find(ComposerFieldView.self, in: host)).textView
        window.makeFirstResponder(field)
        settle()

        model.openAgent(a, in: session)
        session.applyAgentText("> tarea del agente\n\n", call: "call-a")
        settle()
        XCTAssertNotNil(find(LiveTerminalScrollView.self, in: host))
        XCTAssertEqual(find(LiveTerminalScrollView.self, in: host)?.textView.string, "> tarea del agente\n\n", "The mirror shows the agent's conversation.")
        pressEscape(in: window)
        XCTAssertNil(session.viewedAgent, "Esc went back to Claude.")
        XCTAssertEqual(escapes.count, 0, "…and did not put the island away.")
        XCTAssertEqual(find(LiveTerminalScrollView.self, in: host)?.textView.string, "> pregunta\n\n⏺ respuesta\n\n")

        pressEscape(in: window)
        XCTAssertEqual(escapes.count, 1, "With no agent shown, Esc is the island's again.")
    }

    func testTheFieldSaysItWritesToClaudeWhileAnAgentIsShown() throws {
        let model = model()
        let a = agent("call-a")
        let session = claudeSession(model, agents: [a])
        model.sessions = [session]; model.selectedID = session.id
        let host = NSHostingView(rootView: Island(model: model, session: session, escapes: Escapes()))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 204), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
        let field = try XCTUnwrap(find(ComposerFieldView.self, in: host)).textView
        XCTAssertNotEqual(field.placeholder, "Mensaje para Claude…")
        model.openAgent(a, in: session)
        settle()
        XCTAssertEqual(field.placeholder, "Mensaje para Claude…")
        model.leaveAgentView()
        settle()
        XCTAssertNotEqual(field.placeholder, "Mensaje para Claude…")
    }

    // MARK: The scroll view keeps each conversation's place

    func testTheMirrorKeepsWhereTheReaderWasInEachConversation() throws {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.setTheme(dark: true, transcript: true)
        let claude = (1...60).map { "⏺ línea \($0) de Claude" }.joined(separator: "\n\n")
        let agent = (1...40).map { "⏺ línea \($0) del agente" }.joined(separator: "\n\n")
        scroll.setText(claude)
        scroll.layoutSubtreeIfNeeded()
        let bottom = scroll.textView.frame.height - scroll.contentSize.height
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottom, accuracy: 1, "A new conversation opens at its end.")

        // The reader scrolls up in Claude's conversation, then enters the agent's.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
        scroll.setContent("call-a")
        scroll.setText(agent)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scroll.textView.frame.height - scroll.contentSize.height, accuracy: 1, "An agent's conversation opens at its end, where it is live.")

        // Back: Claude's conversation is where the reader left it, not at the end.
        scroll.setContent("")
        scroll.setText(claude)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 200, accuracy: 1)
        XCTAssertEqual(scroll.textView.string, claude)

        // A reader at the end of Claude's conversation finds it at the end (with what arrived meanwhile) too.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.textView.frame.height - scroll.contentSize.height)); scroll.reflectScrolledClipView(scroll.contentView)
        scroll.setContent("call-a")
        scroll.setText(agent)
        scroll.setContent("")
        scroll.setText(claude + "\n\n⏺ nueva línea")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, scroll.textView.frame.height - scroll.contentSize.height, accuracy: 1)
    }

    func testSettingTheSameContentChangesNothing() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setText((1...60).map { "⏺ línea \($0)" }.joined(separator: "\n\n"))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 150)); scroll.reflectScrolledClipView(scroll.contentView)
        scroll.setContent("")
        scroll.setText((1...60).map { "⏺ línea \($0)" }.joined(separator: "\n\n") + "\n\n⏺ más")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 150, accuracy: 1, "The reader reading earlier text is not moved by new text at the end.")
    }

    // MARK: Clicking a row

    /// A left click in the window, `point` measured from the content's top left like SwiftUI does.
    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        settle(0.3)
    }

    func testAClickOnARowOfATabsListEntersThatAgentAndClosesTheList() throws {
        let model = model()
        let working = agent("call-run", "Diseñar el gato")
        let finished = agent("call-done", "Revisar el notch", state: .done)
        let session = claudeSession(model, agents: [finished, working])
        session.subagents = [finished, working]
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        let presenter = TabAgentListPresenter()
        presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: presenter).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(0.6)
        XCTAssertEqual(presenter.open?.id, session.id)

        // The list hangs under the tab row: header, then the working agent (taller), then the finished one.
        let top = model.neckHeight + TabAgentListLayout.originY + SubagentListLayout.verticalPadding + SubagentListLayout.headerHeight
        click(window, at: NSPoint(x: 232, y: top + SubagentListLayout.workingRowHeight / 2))
        XCTAssertEqual(session.viewedAgent, "call-run", "The click entered the working agent's conversation.")
        XCTAssertNil(presenter.open, "…and the list went away.")

        model.leaveAgentView()
        presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        settle()
        click(window, at: NSPoint(x: 232, y: top + SubagentListLayout.workingRowHeight + SubagentListLayout.rowHeight / 2))
        XCTAssertEqual(session.viewedAgent, "call-done")
    }

    func testAClickOnARowOfTheComposersListEntersThatAgent() throws {
        var picked: [String] = []
        let working = agent("call-run", "Diseñar el gato")
        let view = ZStack(alignment: .topTrailing) {
            Color.black
            HStack { Spacer(); SubagentCapsule(agents: [working, agent("call-done", "Revisar el notch", state: .done)], alwaysVisible: true, initiallyOpen: true, onOpen: { picked.append($0.id) }) }
                .padding(.trailing, 25).padding(.top, 196)
        }.frame(width: 572, height: 266).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 572, height: 266)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
        // The list floats over the capsule: its first row is the working agent, a click on it opens that agent.
        var y: CGFloat = 4
        while picked.isEmpty, y < 200 { click(window, at: NSPoint(x: 330, y: y)); y += 5 }
        XCTAssertEqual(picked.first, "call-run")
    }

    func testRowsAreOnlyButtonsWhenSomeoneListens() throws {
        // Without a way to open an agent a row stays plain: nothing to click, no hint of one.
        let plain = SubagentRow(agent: agent("a", "Diseñar"))
        XCTAssertNil(plain.onOpen)
        XCTAssertFalse(plain.helpText.contains("Clic para ver su conversación"))
        let clickable = SubagentRow(agent: agent("a", "Diseñar"), onOpen: { _ in })
        XCTAssertTrue(clickable.helpText.contains("Clic para ver su conversación"))
    }
}
