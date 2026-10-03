import Combine
import XCTest
@testable import Nook

/// What a session tab shows of its agent's subagents, and the words and measures of the list it opens.
@MainActor
final class TabAgentIndicatorTests: XCTestCase {
    private func agent(_ id: String, state: SubagentActivity.State = .running, role: SubagentActivity.Role = .agent, duration: String? = nil, activity: String? = nil) -> SubagentActivity {
        var shown = SubagentActivity(id: id, role: role, name: "Agent \(id)", state: state, duration: duration)
        shown.activity = activity
        return shown
    }

    private func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: - What the badge says

    func testATabWithoutAgentsShowsNothing() {
        let state = TabAgentState([])
        XCTAssertNil(state.kind)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.label, "")
    }

    func testWorkingAgentsShowTheirNumber() {
        let one = TabAgentState([agent("a")])
        XCTAssertEqual(one.kind, .running)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.label, "1 agente trabajando")
        let two = TabAgentState([agent("a"), agent("b")])
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.label, "2 agentes trabajando")
    }

    func testWorkingBeatsFinishedAndTheCountIgnoresFinishedOnes() {
        let state = TabAgentState([agent("a"), agent("b", state: .done), agent("c", state: .done)], lingering: true)
        XCTAssertEqual(state.kind, .running)
        XCTAssertEqual(state.count, 1)
        XCTAssertFalse(state.warns)
    }

    func testAFailureBesideWorkingAgentsWarnsWithoutChangingTheBadge() {
        let state = TabAgentState([agent("a"), agent("b"), agent("c", state: .failed)])
        XCTAssertEqual(state.kind, .running)
        XCTAssertEqual(state.count, 2)
        XCTAssertTrue(state.warns)
        XCTAssertEqual(state.label, "2 agentes trabajando, 1 con error")
    }

    func testFinishedAgentsShowOnlyWhileTheyLinger() {
        let agents = [agent("a", state: .done), agent("b", state: .done), agent("c", state: .done)]
        XCTAssertNil(TabAgentState(agents).kind)
        let lingering = TabAgentState(agents, lingering: true)
        XCTAssertEqual(lingering.kind, .done)
        XCTAssertEqual(lingering.count, 3)
        XCTAssertEqual(lingering.label, "3 agentes listos")
        XCTAssertEqual(TabAgentState([agent("a", state: .done)], lingering: true).label, "1 agente listo")
    }

    func testFailedBeatsFinishedWhenNothingWorks() {
        let state = TabAgentState([agent("a", state: .done), agent("b", state: .failed), agent("c", state: .failed)], lingering: true)
        XCTAssertEqual(state.kind, .failed)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.label, "2 agentes con error")
        XCTAssertNil(TabAgentState([agent("b", state: .failed)]).kind)
    }

    func testMessagesToOtherAgentsDoNotCount() {
        XCTAssertNil(TabAgentState([agent("m", role: .message)]).kind)
        XCTAssertEqual(TabAgentState([agent("a"), agent("m", role: .message)]).count, 1)
    }

    func testTheNumberStopsAtNine() {
        XCTAssertEqual(TabAgentState((0..<12).map { agent("\($0)") }).countText, "9+")
        XCTAssertEqual(TabAgentState((0..<9).map { agent("\($0)") }).countText, "9")
    }

    /// Counters tick every second; the badge must not notice them.
    func testTickingCountersAndActivityLinesDoNotChangeTheBadge() {
        let first = TabAgentState([agent("a", duration: "1m 2s", activity: "Read(a.swift)"), agent("b", state: .done, duration: "5s")])
        let later = TabAgentState([agent("a", duration: "1m 3s", activity: "Bash(swift test)"), agent("b", state: .done, duration: "5s")])
        XCTAssertEqual(first, later)
    }

    // MARK: - The tracker

    func testATabOpenedWithOnlyOldFinishedAgentsStaysQuiet() {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([agent("a", state: .done), agent("b", state: .failed)])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), linger: 0.2)
        XCTAssertNil(tracker.state.kind)
    }

    func testTheBadgeFollowsAgentsStartingAndEnding() async {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), linger: 0.2)
        XCTAssertNil(tracker.state.kind)
        agents.send([agent("a"), agent("b")])
        XCTAssertEqual(tracker.state.kind, .running)
        XCTAssertEqual(tracker.state.count, 2)
        agents.send([agent("a", state: .done), agent("b")])
        XCTAssertEqual(tracker.state.count, 1)
        // The last one ends: the finished ones show for a while, then the tab goes quiet.
        agents.send([agent("a", state: .done), agent("b", state: .done)])
        XCTAssertEqual(tracker.state.kind, .done)
        XCTAssertEqual(tracker.state.count, 2)
        await wait(0.45)
        XCTAssertNil(tracker.state.kind)
    }

    /// The tab follows the session's own published list, the way `SessionTab` wires it.
    func testTheTrackerFollowsARealSessionsAgents() {
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys090", customTitle: "nook", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.subagents = [agent("a", duration: "1s")]
        let tracker = TabAgentTracker(session: session, linger: 0.2)
        XCTAssertEqual(tracker.state.kind, .running, "an agent that already works when the tab appears shows at once")
        session.subagents = [agent("a", duration: "2s"), agent("b")]
        XCTAssertEqual(tracker.state.count, 2)
        session.subagents = []
        XCTAssertNil(tracker.state.kind)
    }

    func testNothingIsPublishedWhileOnlyCountersTick() {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([agent("a", duration: "1s")])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), linger: 0.2)
        var published = 0
        let observation = tracker.$state.dropFirst().sink { _ in published += 1 }
        for second in 2...40 { agents.send([agent("a", duration: "\(second)s", activity: second.isMultiple(of: 2) ? "Read(a.swift)" : nil)]) }
        XCTAssertEqual(published, 0)
        agents.send([agent("a", state: .done, duration: "41s")])
        XCTAssertEqual(published, 1)
        observation.cancel()
    }

    func testNewWorkDuringTheLingerRestartsIt() async {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([agent("a")])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), linger: 0.5)
        agents.send([agent("a", state: .done)])
        XCTAssertEqual(tracker.state.kind, .done)
        await wait(0.25)
        agents.send([agent("a", state: .done), agent("b")])
        XCTAssertEqual(tracker.state.kind, .running)
        await wait(0.35)
        // The first linger would have ended by now; the second one starts when "b" ends.
        agents.send([agent("a", state: .done), agent("b", state: .done)])
        await wait(0.3)
        XCTAssertEqual(tracker.state.kind, .done)
        await wait(0.5)
        XCTAssertNil(tracker.state.kind)
    }

    func testAgentsLeavingTheListWhileLingeringLeaveNothingToShow() {
        let agents = CurrentValueSubject<[SubagentActivity], Never>([agent("a")])
        let tracker = TabAgentTracker(agents: agents.eraseToAnyPublisher(), linger: 0.3)
        agents.send([])
        XCTAssertNil(tracker.state.kind)
    }

    // MARK: - Opening the list

    private let frame = CGRect(x: 100, y: 4, width: 28, height: 22)

    private func presenter() -> TabAgentListPresenter { TabAgentListPresenter(openDelay: 0.05, closeDelay: 0.05) }

    func testPointingAtABadgeOpensItsListAfterAMoment() async {
        let presenter = presenter()
        presenter.badgeHover("a", frame: frame, over: true)
        XCTAssertNil(presenter.open)
        await wait(0.3)
        XCTAssertEqual(presenter.open, TabAgentListPresenter.Open(id: "a", frame: frame))
    }

    func testSweepingAcrossABadgeOpensNothing() async {
        let presenter = presenter()
        presenter.badgeHover("a", frame: frame, over: true)
        presenter.badgeHover("a", frame: frame, over: false)
        await wait(0.3)
        XCTAssertNil(presenter.open)
    }

    func testMovingToAnotherBadgeFollowsAtOnce() async {
        let presenter = presenter()
        presenter.toggle("a", frame: frame)
        presenter.badgeHover("a", frame: frame, over: false)
        let other = CGRect(x: 220, y: 4, width: 28, height: 22)
        presenter.badgeHover("b", frame: other, over: true)
        XCTAssertEqual(presenter.open?.id, "b")
        await wait(0.3)
        XCTAssertEqual(presenter.open, TabAgentListPresenter.Open(id: "b", frame: other))
    }

    func testLeavingForGoodClosesTheListAfterAGrace() async {
        let presenter = presenter()
        presenter.toggle("a", frame: frame)
        presenter.badgeHover("a", frame: frame, over: true)
        presenter.badgeHover("a", frame: frame, over: false)
        XCTAssertNotNil(presenter.open)
        await wait(0.3)
        XCTAssertNil(presenter.open)
    }

    func testCrossingToTheCardKeepsTheListOpenUntilThePointerLeavesIt() async {
        let presenter = presenter()
        presenter.toggle("a", frame: frame)
        presenter.badgeHover("a", frame: frame, over: false)
        presenter.cardHover(true)
        await wait(0.3)
        XCTAssertNotNil(presenter.open)
        presenter.cardHover(false)
        await wait(0.3)
        XCTAssertNil(presenter.open)
    }

    func testAClickOpensAtOnceAndAnotherClosesIt() {
        let presenter = presenter()
        presenter.toggle("a", frame: frame)
        XCTAssertEqual(presenter.open?.id, "a")
        presenter.toggle("a", frame: frame)
        XCTAssertNil(presenter.open)
        presenter.toggle("a", frame: frame)
        presenter.toggle("b", frame: frame)
        XCTAssertEqual(presenter.open?.id, "b")
    }

    func testTheListFollowsItsBadgeWhenTheRowScrolls() {
        let presenter = presenter()
        presenter.move("a", to: frame)
        XCTAssertNil(presenter.open, "a badge that is not showing a list has nothing to move")
        presenter.toggle("a", frame: frame)
        presenter.move("b", to: CGRect(x: 1, y: 1, width: 1, height: 1))
        XCTAssertEqual(presenter.open?.frame, frame)
        let scrolled = CGRect(x: 60, y: 4, width: 28, height: 22)
        presenter.move("a", to: scrolled)
        XCTAssertEqual(presenter.open?.frame, scrolled)
    }

    func testALeavingTabTakesOnlyItsOwnListWithIt() {
        let presenter = presenter()
        presenter.toggle("a", frame: frame)
        presenter.close(ifShowing: "b")
        XCTAssertEqual(presenter.open?.id, "a")
        presenter.close(ifShowing: "a")
        XCTAssertNil(presenter.open)
    }

    // MARK: - Where the list goes

    func testTheListCentresUnderItsBadgeAndStaysInsideTheIsland() {
        let container: CGFloat = 572
        let width = TabAgentListLayout.width
        XCTAssertEqual(TabAgentListLayout.originX(badge: CGRect(x: 286 - 14, y: 4, width: 28, height: 22), container: container), 286 - width / 2)
        XCTAssertEqual(TabAgentListLayout.originX(badge: CGRect(x: 20, y: 4, width: 28, height: 22), container: container), TabAgentListLayout.margin)
        XCTAssertEqual(TabAgentListLayout.originX(badge: CGRect(x: 540, y: 4, width: 28, height: 22), container: container), container - TabAgentListLayout.margin - width)
        // An island narrower than the card still starts at the margin.
        XCTAssertEqual(TabAgentListLayout.originX(badge: frame, container: 300), TabAgentListLayout.margin)
    }

    // MARK: - The list's words and measures

    func testModelNamesAreShortAndReadable() {
        XCTAssertEqual(AgentModelName.short("sonnet"), "Sonnet")
        XCTAssertEqual(AgentModelName.short("OPUS"), "Opus")
        XCTAssertEqual(AgentModelName.short("haiku"), "Haiku")
        XCTAssertEqual(AgentModelName.short("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(AgentModelName.short("claude-opus-4-1"), "Opus 4.1")
        XCTAssertEqual(AgentModelName.short("claude-opus-4-20250514"), "Opus 4")
        XCTAssertEqual(AgentModelName.short("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(AgentModelName.short("claude-3-opus-20240229"), "Opus 3")
        XCTAssertEqual(AgentModelName.short("sonnet[1m]"), "Sonnet")
    }

    func testTheSpinnerHoldsItsRestingFrameWhenStill() {
        let now = Date()
        XCTAssertEqual(SubagentStateGlyph.symbol(at: now, still: true), "✻")
        XCTAssertEqual(SubagentStateGlyph.symbol(at: now.addingTimeInterval(7.3), still: true), "✻")
        // Moving, it walks through Claude's symbols and comes back to where it started.
        let frames = Set((0..<10).map { SubagentStateGlyph.symbol(at: Date(timeIntervalSinceReferenceDate: Double($0) * 0.16 + 0.01), still: false) })
        XCTAssertEqual(frames, ["·", "✢", "✳", "✶", "✻", "✽"])
    }

    func testNoModelOrTheParentsModelShowsNoChip() {
        XCTAssertNil(AgentModelName.short(nil))
        XCTAssertNil(AgentModelName.short(""))
        XCTAssertNil(AgentModelName.short("  "))
        XCTAssertNil(AgentModelName.short("inherit"))
    }

    func testAnUnknownModelKeepsItsOwnNameWithinTheChip() {
        XCTAssertEqual(AgentModelName.short("gemini"), "Gemini")
        XCTAssertEqual(AgentModelName.short("a-very-long-custom-model-name"), "A-very-long-cus…")
    }

    func testActivityLinesSplitIntoToolAndArgument() {
        let read = AgentActivityLine.parse("Read(Sources/Nook/Pet.swift)")
        XCTAssertEqual(read, AgentActivityLine.Parts(tool: "Read", argument: "Sources/Nook/Pet.swift"))
        XCTAssertTrue(read.isPath)
        let bash = AgentActivityLine.parse("Bash(swift test --filter PanelRenderTests)")
        XCTAssertEqual(bash.tool, "Bash")
        XCTAssertEqual(bash.argument, "swift test --filter PanelRenderTests")
        XCTAssertFalse(bash.isPath, "a command is cut at its end, not in the middle")
        XCTAssertEqual(AgentActivityLine.parse("Bash(echo (hi))").argument, "echo (hi)")
        XCTAssertEqual(AgentActivityLine.parse("Glob(**/*.swift)").isPath, true)
    }

    func testActivityLinesWithoutAnArgumentStayWhole() {
        XCTAssertEqual(AgentActivityLine.parse("TodoWrite"), AgentActivityLine.Parts(tool: "TodoWrite", argument: nil))
        XCTAssertEqual(AgentActivityLine.parse("Read()"), AgentActivityLine.Parts(tool: "Read", argument: nil))
        XCTAssertEqual(AgentActivityLine.parse("(odd)"), AgentActivityLine.Parts(tool: "(odd)", argument: nil))
    }

    func testRunningAgentsHaveASecondLineAndOthersDoNot() {
        XCTAssertTrue(agent("a").showsActivityLine)
        XCTAssertFalse(agent("a", state: .done).showsActivityLine)
        XCTAssertFalse(agent("a", state: .failed).showsActivityLine)
        XCTAssertFalse(agent("m", role: .message).showsActivityLine)
        // Whether it has an activity right now makes no difference: the row keeps its height between tool calls.
        XCTAssertEqual(SubagentListLayout.rowHeight(of: agent("a", activity: "Read(a.swift)")), SubagentListLayout.rowHeight(of: agent("a")))
        XCTAssertGreaterThan(SubagentListLayout.rowHeight(of: agent("a")), SubagentListLayout.rowHeight(of: agent("a", state: .done)))
    }

    func testTheListPutsWorkingAgentsFirstAndKeepsClaudesOrderWithinAGroup() {
        let agents = [agent("done1", state: .done), agent("run1"), agent("msg", role: .message), agent("fail1", state: .failed), agent("run2"), agent("done2", state: .done)]
        XCTAssertEqual(SubagentListLayout.ordered(agents).map(\.id), ["run1", "run2", "fail1", "done1", "done2", "msg"])
    }

    func testTheCardsHeightAddsUpItsRows() {
        let agents = [agent("a"), agent("b", state: .done)]
        let expected = SubagentListLayout.headerHeight + 2 * SubagentListLayout.verticalPadding + SubagentListLayout.workingRowHeight + SubagentListLayout.rowHeight
        XCTAssertEqual(SubagentListLayout.height(of: agents), expected)
        XCTAssertEqual(SubagentListLayout.height(of: []), SubagentListLayout.headerHeight + 2 * SubagentListLayout.verticalPadding)
    }

    /// Both lists have a ceiling that keeps them inside the island; the composer's must stay below the tab row.
    func testTheListsCeilingsFitTheIsland() {
        // The tab row starts under the neck (the notch's height); the list hangs below the row and keeps 10 pt above the island's bottom.
        for neck in [28.0, 32.0] {
            let island = NotchGeometry.expandedHeight(topInset: neck)
            XCTAssertLessThanOrEqual(neck + TabAgentListLayout.originY + TabAgentListLayout.maxHeight, island - 10, "neck \(neck)")
        }
        // Six working agents do not fit under the tab row, so that list scrolls.
        XCTAssertGreaterThan(SubagentListLayout.height(of: (0..<6).map { agent("\($0)") }), TabAgentListLayout.maxHeight)
        // Three working agents do fit, and need no scrolling.
        XCTAssertLessThan(SubagentListLayout.height(of: (0..<3).map { agent("\($0)") }), TabAgentListLayout.maxHeight)
    }
}
