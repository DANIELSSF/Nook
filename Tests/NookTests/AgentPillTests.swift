import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The collapsed island's mint pill: the words it speaks, where it can be pointed at and clicked, and the open island's answer
/// to a click on it.
@MainActor
final class AgentPillTests: XCTestCase {
    private func agent(_ id: String, _ name: String, state: SubagentActivity.State = .running, role: SubagentActivity.Role = .agent) -> SubagentActivity {
        var shown = SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 3, tokens: "2k", duration: "20s")
        shown.role = role
        shown.model = "sonnet"
        return shown
    }

    private func summary(_ names: [String], tab: String = "nook") -> AgentPillSummary { AgentPillSummary(tab: tab, names: names) }

    // MARK: Words

    func testTheTooltipCountsAndNamesTheWorkingAgents() {
        XCTAssertEqual(AgentPillTooltip.text(summary(["Diseñar el gato"])),
                       "1 subagente trabajando en «nook»\n· Diseñar el gato\nClic para ver la lista")
        XCTAssertEqual(AgentPillTooltip.text(summary(["Uno", "Dos"], tab: "Claude Code")),
                       "2 subagentes trabajando en «Claude Code»\n· Uno\n· Dos\nClic para ver la lista")
        XCTAssertEqual(AgentPillTooltip.text(summary(["a", "b", "c"])).components(separatedBy: "\n").count, 5, "Three names fit.")
    }

    func testMoreThanThreeAgentsSayHowManyAreNotNamed() {
        let lines = AgentPillTooltip.text(summary(["a", "b", "c", "d", "e"])).components(separatedBy: "\n")
        XCTAssertEqual(lines, ["5 subagentes trabajando en «nook»", "· a", "· b", "· c", "· y 2 más", "Clic para ver la lista"])
        XCTAssertEqual(AgentPillTooltip.text(summary(["a", "b", "c", "d"])).components(separatedBy: "\n")[4], "· y 1 más")
    }

    func testNamesAndTabsAreKeptOnOneCalmLine() {
        let long = String(repeating: "revisar el panel ", count: 12)
        let line = AgentPillTooltip.text(summary(["  Revisa \n el   panel  ", long], tab: "mi\n  tab")).components(separatedBy: "\n")
        XCTAssertEqual(line[0], "2 subagentes trabajando en «mi tab»")
        XCTAssertEqual(line[1], "· Revisa el panel")
        XCTAssertEqual(line[2].count, "· ".count + AgentPillTooltip.nameLength)
        XCTAssertTrue(line[2].hasSuffix("…"))
        XCTAssertEqual(AgentPillTooltip.text(summary(["x"], tab: "  ")).components(separatedBy: "\n")[0], "1 subagente trabajando", "A tab with no name leaves the «» out.")
    }

    // MARK: What the pill speaks for

    func testThePillSpeaksForTheSelectedTabsWorkingAgentsOnly() {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-pill-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys070", customTitle: "", processes: ["claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        let other = TerminalSession(tab: TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 2, tty: "/dev/ttys071", customTitle: "", processes: ["claude"], busy: false, selected: false, text: "⏺ hola"),
                                    backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session, other]; model.selectedID = session.id
        XCTAssertNil(model.agentPill, "No agents, no pill.")

        session.customTitle = "nook"
        session.subagents = [agent("a", "Diseñar el gato"), agent("b", "Revisar el notch"), agent("c", "Listo ya", state: .done),
                             agent("d", "a otro agente", role: .message), agent("e", "Falló", state: .failed)]
        other.subagents = [agent("z", "De otra pestaña")]
        model.updateActivity()
        XCTAssertEqual(model.agentPill, AgentPillSummary(tab: "nook", names: ["Diseñar el gato", "Revisar el notch"]))
        XCTAssertEqual(model.agentPill?.running, model.runningSubagents, "The tooltip and the number on the pill agree.")

        model.select(other)
        model.updateActivity()
        XCTAssertEqual(model.agentPill?.names, ["De otra pestaña"])
        XCTAssertEqual(model.agentPill?.tab, other.displayTitle)

        other.subagents = other.subagents.map { var ended = $0; ended.state = .done; return ended }
        model.updateActivity()
        XCTAssertNil(model.agentPill)
        XCTAssertEqual(model.runningSubagents, 0)
    }

    // MARK: Where it can be pointed at

    func testTheHitAreaIsLargerThanThePillAndInsideTheWing() throws {
        let bounds = NSRect(x: 0, y: 0, width: 245, height: 32)
        XCTAssertNil(AgentNotchBadge.hitRect(running: 0, in: bounds))
        for running in [1, 5, 12] {
            let pill = try XCTUnwrap(AgentNotchBadge.rect(running: running, in: bounds))
            let hit = try XCTUnwrap(AgentNotchBadge.hitRect(running: running, in: bounds))
            XCTAssertTrue(hit.contains(pill))
            XCTAssertGreaterThan(hit.width, pill.width + 4)
            XCTAssertTrue(bounds.contains(hit), "\(hit) leaves \(bounds)")
            XCTAssertGreaterThanOrEqual(hit.minX, bounds.width - 36, "It stays in the right wing, clear of the cat.")
        }
        // The pill sits at the corner of the activity symbol, not over the whole wing: most of the wing keeps its own click.
        let hit = try XCTUnwrap(AgentNotchBadge.hitRect(running: 1, in: bounds))
        XCTAssertLessThan(hit.width * hit.height, 36 * bounds.height / 3)
    }

    // MARK: The tooltip's surface

    func testTheTooltipGoesUnderTheIslandCentredOnThePillAndInsideTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let island = NSRect(x: 633, y: 950, width: 245, height: 32)
        let size = NSSize(width: 200, height: 70)
        let pill = NSRect(x: 850, y: 962, width: 9, height: 9)
        let frame = AgentPillTip.frame(size: size, pill: pill, island: island, screen: screen)
        XCTAssertEqual(frame.midX, pill.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, island.minY - 5, accuracy: 0.01, "Hangs under the island, as the alert's peek does.")
        XCTAssertLessThan(frame.maxY, island.minY)
        let edge = AgentPillTip.frame(size: size, pill: NSRect(x: 1500, y: 962, width: 9, height: 9), island: island, screen: screen)
        XCTAssertEqual(edge.maxX, screen.maxX - 8, accuracy: 0.01, "Kept inside the screen.")
    }

    func testTheTooltipSurfaceFitsItsTextAndDrawsIt() throws {
        let short = AgentPillTooltip.text(summary(["Uno"]))
        let tall = AgentPillTooltip.text(summary(["a", "b", "c", "d", "e"]))
        let small = AgentPillTipView.size(for: short), big = AgentPillTipView.size(for: tall)
        XCTAssertGreaterThan(big.height, small.height)
        XCTAssertLessThanOrEqual(big.width, AgentPillTipView.maxWidth)
        let view = AgentPillTipView(frame: NSRect(origin: .zero, size: big))
        view.setText(tall)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Black surface, with light text somewhere on it.
        let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(middle.redComponent, 0.05)
        var light = false
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.6 { light = true } }
        XCTAssertTrue(light, "The text is drawn.")
        XCTAssertEqual(view.accessibilityValue() as? String, tall.replacingOccurrences(of: "\n", with: ". "))
    }

    // MARK: A click opens the list

    private func settle(_ seconds: TimeInterval = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testTheOpenIslandShowsTheTabsListOnceItsContentIsOnScreen() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-pill-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys072", customTitle: "nook", processes: ["claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.transcriptLocated = Date()
        session.subagents = [agent("a", "Diseñar el gato"), agent("b", "Revisar el notch")]
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = false
        model.updateActivity()

        let presenter = TabAgentListPresenter()
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: presenter).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        settle()

        // The pill was clicked while the island was still opening: the request waits for the content.
        model.requestAgentList(for: session)
        settle()
        XCTAssertNil(presenter.open, "Nothing opens under an island whose content is not on screen yet.")
        XCTAssertNotNil(model.agentListRequest)

        model.islandContentVisible = true
        settle()
        XCTAssertEqual(presenter.open?.id, session.id, "The tab's list opens with the content.")
        XCTAssertNil(model.agentListRequest, "…and the request is spent.")
        XCTAssertGreaterThan(presenter.open?.frame.width ?? 0, 0, "It opens under the tab's badge, where the badge is.")

        // With the content on screen, a request is answered at once.
        presenter.close()
        model.requestAgentList(for: session)
        settle(0.1)
        XCTAssertNil(model.agentListRequest)
        XCTAssertEqual(presenter.open?.id, session.id)

        // Putting the island away takes the list with it, and a request the island never got to answer.
        model.islandContentVisible = false
        settle(0.1)
        XCTAssertNil(presenter.open)
        model.requestAgentList(for: session)
        XCTAssertNotNil(model.agentListRequest)
        model.expanded = false
        XCTAssertNil(model.agentListRequest, "A request is not kept for a later visit.")
    }

    func testARequestForATabThatIsGoneOpensNothing() {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-pill-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys073", customTitle: "nook", processes: ["claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.subagents = [agent("a", "Diseñar")]
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        let presenter = TabAgentListPresenter()
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: presenter))
        host.frame = NSRect(x: 0, y: 0, width: 572, height: 266)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        settle()
        model.agentListRequest = AgentListRequest(sessionID: "ya-no-existe", serial: 1)
        settle()
        XCTAssertNil(presenter.open)
        XCTAssertNil(model.agentListRequest)
    }
}
