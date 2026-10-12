import Combine
import XCTest
@testable import Nook

/// Nook's own order of its tabs: the user drags a tab to another place along the strip, and that order holds through Terminal's
/// readings and across launches, with Terminal's own tabs never moved. A tab that comes back takes its place again; a new tab, also
/// one that reuses a closed tab's TTY, goes at the end.
@MainActor
final class TabOrderTests: XCTestCase {
    /// TTYs of this test's own, and their logins: names and colours are saved in the test process's shared preferences.
    private let stem = "/dev/ttys7" + String(Int.random(in: 10...99)) + String(UUID().uuidString.prefix(4))
    private var a: String { stem + "a" }
    private var b: String { stem + "b" }
    private var c: String { stem + "c" }
    private var d: String { stem + "d" }
    private lazy var logins = [a: "1759600000.000001", b: "1759600000.000002", c: "1759600000.000003", d: "1759600000.000004"]
    private let scripts = ScriptLog()

    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-tab-order-" + UUID().uuidString)! }
    private func model(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: defaults)
        let scripts = scripts
        model.terminalBridge.runScript = { scripts.add($0) }          // nothing reaches the real Terminal
        model.terminalBridge.resting = true                           // connecting must not start reading it either
        model.terminalBridge.loginStampsReader = { [unowned self] in self.logins }
        model.frontTerminalWindow = { nil }
        return model
    }
    private func tab(_ tty: String, window: Int = 7, index: Int = 1) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: window, windowTitle: "IA", index: index, tty: tty, customTitle: "", processes: ["login", "-zsh"], busy: false,
                            selected: false, text: tty)
    }
    /// Terminal's reading of `ttys`, in Terminal's own order.
    private func read(_ ttys: [String], into model: AppModel) {
        model.updateExternalTabs(ttys.enumerated().map { tab($1, index: $0 + 1) }, ttys: Set(ttys))
    }
    private func order(_ model: AppModel) -> [String] { model.sessions.map { $0.externalTTY ?? $0.id } }
    private func tracked(_ ttys: [String]) -> [TrackedTerminalTab] { ttys.map { TrackedTerminalTab(windowID: 7, tty: $0, login: logins[$0]) } }

    // MARK: Dragging

    func testDraggingATabMovesItOnceAndKeepsTheSelection() throws {
        let model = model(suite())
        read([a, b, c], into: model)
        XCTAssertEqual(order(model), [a, b, c])
        let second = try XCTUnwrap(model.sessions.first { $0.externalTTY == b })
        model.select(second)

        var published = 0
        let watch = model.$sessions.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        model.moveSession(model.sessions[0].id, to: 2)
        XCTAssertEqual(order(model), [b, c, a])
        XCTAssertEqual(published, 1, "a move is one change of the strip")
        XCTAssertEqual(model.selectedID, second.id, "the selection stays on the same tab")

        model.moveSession(model.sessions[2].id, to: 2)
        model.moveSession("no-such-tab", to: 0)
        XCTAssertEqual(published, 1, "a tab already there, or one not in the strip, changes nothing")

        model.moveSession(model.sessions[0].id, to: 99)
        XCTAssertEqual(order(model), [c, a, b], "past the end is the end")
        model.moveSession(model.sessions[2].id, to: -3)
        XCTAssertEqual(order(model), [b, c, a], "before the start is the start")
    }

    func testADragSwapsLiveAsItPassesEachTab() {
        let model = model(suite())
        read([a, b, c, d], into: model)
        let dragged = model.sessions[0].id
        // The view asks for the next place each time the dragged tab passes a neighbour.
        for index in 1...3 { model.moveSession(dragged, to: index) }
        XCTAssertEqual(order(model), [b, c, d, a])
        for index in stride(from: 2, through: 0, by: -1) { model.moveSession(dragged, to: index) }
        XCTAssertEqual(order(model), [a, b, c, d])
    }

    func testTerminalsReadingsKeepNooksOrderWithoutRedrawing() {
        let model = model(suite())
        read([a, b, c], into: model)
        model.moveSession(model.sessions[2].id, to: 0)
        XCTAssertEqual(order(model), [c, a, b])

        var published = 0
        let watch = model.$sessions.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        for _ in 0..<4 { read([a, b, c], into: model) }
        XCTAssertEqual(order(model), [c, a, b], "Terminal's order is Terminal's; Nook keeps its own")
        XCTAssertEqual(published, 0, "readings twice a second publish nothing about the strip")
    }

    func testNooksOrderNeverMovesTerminalsTabs() {
        let model = model(suite())
        for tty in [a, b, c] { model.connectTerminalTab(tab(tty)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let before = scripts.count, followed = model.terminalBridge.trackedTabs
        model.moveSession(model.sessions[0].id, to: 2)
        model.moveSession(model.sessions[1].id, to: 0)
        XCTAssertEqual(order(model), [c, b, a])
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(scripts.count, before, "no script goes to Terminal for a move in Nook's strip")
        XCTAssertEqual(model.terminalBridge.trackedTabs, followed, "what Nook follows in Terminal is untouched")
    }

    // MARK: Relaunch

    func testTheOrderSurvivesARelaunchWhateverOrderTheTabsComeBackIn() {
        let defaults = suite()
        let first = model(defaults)
        read([a, b, c], into: first)
        first.moveSession(first.sessions[2].id, to: 0)
        XCTAssertEqual(order(first), [c, a, b])

        // All at once, in Terminal's order.
        let relaunched = model(defaults)
        relaunched.restoreTabState(keeping: tracked([a, b, c]), logins: logins)
        read([a, b, c], into: relaunched)
        XCTAssertEqual(order(relaunched), [c, a, b])

        // One by one (one window's reading after another's): each takes its saved place among those already back.
        let again = model(defaults)
        again.restoreTabState(keeping: tracked([a, b, c]), logins: logins)
        again.updateExternalTabs([tab(b)], ttys: [b])
        again.updateExternalTabs([tab(a)], ttys: [a])
        XCTAssertEqual(order(again), [a, b])
        again.updateExternalTabs([tab(c)], ttys: [c])
        XCTAssertEqual(order(again), [c, a, b])
    }

    func testANewTabGoesAtTheEndEvenBeforeTheRestoredOnesAreBack() {
        let defaults = suite()
        let first = model(defaults)
        read([a, b, c], into: first)
        first.moveSession(first.sessions[2].id, to: 0)

        let relaunched = model(defaults)
        relaunched.restoreTabState(keeping: tracked([a, b, c]), logins: logins)
        read([a, b], into: relaunched)
        relaunched.connectTerminalTab(tab(d))
        XCTAssertEqual(order(relaunched), [a, b, d], "a tab never seen goes at the end")
        relaunched.updateExternalTabs([tab(c)], ttys: [c])
        XCTAssertEqual(order(relaunched), [c, a, b, d], "a restored tab still takes its saved place")
    }

    // MARK: Identity

    func testATabOnAReusedTTYDoesNotTakeTheClosedTabsPlaceAcrossALaunch() {
        let defaults = suite()
        let first = model(defaults)
        read([a, b, c], into: first)
        first.moveSession(first.sessions[2].id, to: 0)
        XCTAssertEqual(order(first), [c, a, b])

        // While Nook was away, c's tab closed and Terminal gave its TTY to a new tab.
        logins[c] = "1759700000.000009"
        let relaunched = model(defaults)
        relaunched.restoreTabState(keeping: tracked([a, b]), logins: logins)
        read([a, b], into: relaunched)
        relaunched.connectTerminalTab(tab(c))
        XCTAssertEqual(order(relaunched), [a, b, c], "the new tab on c's TTY is a new tab: at the end")
        XCTAssertFalse(TabOrder.load(from: defaults).ids.contains { $0.hasSuffix("1759600000.000003") }, "the closed tab's place is forgotten")
    }

    func testATabOnAReusedTTYDoesNotTakeTheClosedTabsPlaceWhileNookRuns() {
        let model = model(suite())
        read([a, b, c], into: model)
        model.moveSession(model.sessions[2].id, to: 0)
        logins[c] = "1759700000.000009"
        read([a, b, c], into: model)
        XCTAssertEqual(order(model), [a, b], "the tab Nook followed on c's TTY is gone")
        model.connectTerminalTab(tab(c))
        XCTAssertEqual(order(model), [a, b, c])
    }

    func testAReopenedTabGetsItsPlaceBack() throws {
        let model = model(suite())
        read([a, b, c], into: model)
        model.close(try XCTUnwrap(model.sessions.first { $0.externalTTY == b }))   // the ×: the tab lives on in Terminal
        XCTAssertEqual(order(model), [a, c])
        model.connectTerminalTab(tab(b))   // what reopening does once Terminal shows the tab
        XCTAssertEqual(order(model), [a, b, c])

        model.close(try XCTUnwrap(model.sessions.first { $0.externalTTY == b }))
        model.moveSession(model.sessions[1].id, to: 0)
        XCTAssertEqual(order(model), [c, a])
        model.connectTerminalTab(tab(b))
        XCTAssertEqual(order(model), [c, a, b], "it comes back after the tab it followed")
    }

    // MARK: The drag holds the island

    func testATabDragEndsWithTheIsland() {
        let model = model(suite())
        model.expanded = true
        model.tabDragInProgress = true
        model.expanded = false
        XCTAssertFalse(model.tabDragInProgress, "a collapsed island has no drag going on")
    }

    // MARK: The order itself

    func testAnArrivingTabGoesBeforeTheFirstTabAfterIt() {
        var order = TabOrder(["c", "a", "x", "b"])
        XCTAssertEqual(order.place("a", among: ["b"]), 0)
        XCTAssertEqual(order.place("c", among: ["a", "b"]), 0)
        XCTAssertEqual(order.place("x", among: ["c", "a", "b"]), 2)
        XCTAssertEqual(order.place("new", among: ["c", "a", "x", "b"]), 4)
        XCTAssertEqual(order.ids, ["c", "a", "x", "b", "new"])
        var adopting = TabOrder(["a"])
        XCTAssertEqual(adopting.place("a", among: ["byHand"]), 0, "a tab put in the strip by hand counts as after every known one")
        XCTAssertEqual(adopting.ids, ["a", "byHand"])
    }

    func testOnlyTheDraggedTabMovesTheTabsNotInTheStripStay() {
        // b is closed; it was after a.
        var order = TabOrder(["a", "b", "c"])
        order.follow(["c", "a"], moved: "a")
        XCTAssertEqual(order.ids, ["b", "c", "a"], "b stays where it was, before c, when a goes")
        order = TabOrder(["a", "b", "c"])
        order.follow(["c", "a"], moved: "c")
        XCTAssertEqual(order.ids, ["c", "a", "b"], "b stays after a when c goes")
        order = TabOrder(["x", "a", "c"])
        order.follow(["c", "a"], moved: "c")
        XCTAssertEqual(order.ids, ["x", "c", "a"], "tabs before every tab stay first")
    }

    func testArrangingKeepsWhatTheOrderLacksAtTheEnd() {
        let order = TabOrder(["c", "a"])
        XCTAssertEqual(order.arranged(["a", "z", "c", "y"], id: { $0 }), ["c", "a", "z", "y"])
    }

    func testPlacesFollowTheTabsIdentityAtLaunch() {
        let prefix = TerminalTabIdentity.terminalPrefix
        var order = TabOrder([prefix + "/dev/ttys001@1", "nook::kept", prefix + "/dev/ttys002@2", prefix + "/dev/ttys003", "nook::gone", prefix + "/dev/ttys004"])
        order.migrate(keep: [prefix + "/dev/ttys003": prefix + "/dev/ttys003@3"],
                      logins: ["/dev/ttys001": "1", "/dev/ttys002": "9", "/dev/ttys003": "3", "/dev/ttys004": "4"], nookTabs: ["nook::kept"])
        XCTAssertEqual(order.ids, [prefix + "/dev/ttys001@1", "nook::kept", prefix + "/dev/ttys003@3"],
                       "same tab kept; reused TTY gone; bare TTY moved to its tab; bare TTY not provably the same gone; a tmux session not restored gone")
    }

    func testTheOrderIsSavedInTheModelsOwnPreferences() {
        let defaults = suite()
        TabOrder(["a", "b", "a", "c"]).save(to: defaults)
        XCTAssertEqual(TabOrder.load(from: defaults).ids, ["a", "b", "c"])
        XCTAssertEqual(TabOrder.load(from: suite()).ids, [])
    }
}

/// The scripts a test's bridge would have sent to Terminal; they run on the bridge's own queue.
final class ScriptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    func add(_ script: String) { lock.lock(); scripts.append(script); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return scripts.count }
}
