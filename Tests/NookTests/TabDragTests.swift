import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Dragging a tab along the strip, in the island's real tab row: pressing a tab and moving the pointer carries it, the order follows live, letting go settles it, and everything the
/// tab already did still works (a click selects, the ✕ closes). The events go straight to a window of the test's own, which is never made key and sits far off screen, so nothing here
/// takes the keyboard from the user.
@MainActor
final class TabDragTests: XCTestCase {
    @MainActor private struct Rig {
        var model: AppModel
        var window: NSPanel
        var host: NSHostingView<NookPanel>
        var sessions: [TerminalSession]
    }

    private let titles = ["Alfa", "Beta", "Gamma"]

    private func rig(animations: Bool = true, titles names: [String]? = nil) -> Rig {
        let titles = names ?? self.titles
        let name = "nook-tab-drag-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = animations
        model.neckWithoutWindow = 32
        var sessions: [TerminalSession] = []
        for (index, title) in titles.enumerated() {
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: index + 1, tty: "/dev/ttys08\(index)", customTitle: title, processes: ["login", "-zsh"], busy: false,
                                          selected: index == 2, text: "")
            sessions.append(TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge))
        }
        model.sessions = sessions
        model.selectedID = sessions[2].id
        model.expanded = true; model.islandContentVisible = true
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // In front without being asked to take the keyboard.
        window.orderFrontRegardless()
        let rig = Rig(model: model, window: window, host: host, sessions: sessions)
        wait(0.5)
        addTeardownBlock { window.close() }
        return rig
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Where the control with this label is, from the window's top left.
    private func top(of label: String, in rig: Rig) throws -> NSPoint {
        try XCTUnwrap(AccessibilityLookup.center(of: label, in: rig.window), "\(label) is on screen")
    }

    private func send(_ type: NSEvent.EventType, _ point: NSPoint, in rig: Rig) {
        let location = NSPoint(x: point.x, y: rig.host.bounds.height - point.y)
        rig.window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }

    private func click(_ label: String, in rig: Rig) throws {
        let point = try top(of: label, in: rig)
        send(.leftMouseDown, point, in: rig); send(.leftMouseUp, point, in: rig)
        wait(0.2)
    }

    /// Presses on a tab's title and carries the pointer `distance` points to the right in steps, letting go at the end unless `release` is false.
    private func drag(_ label: String, by distance: CGFloat, in rig: Rig, step: CGFloat = 4, release: Bool = true) throws {
        let start = try top(of: label, in: rig)
        send(.leftMouseDown, start, in: rig)
        var x = start.x
        let direction: CGFloat = distance < 0 ? -1 : 1
        while abs(x - start.x) < abs(distance) {
            x += direction * step
            send(.leftMouseDragged, NSPoint(x: x, y: start.y), in: rig)
            wait(0.016)
        }
        if release { send(.leftMouseUp, NSPoint(x: x, y: start.y), in: rig); wait(1.0) } else { wait(0.1) }
    }

    private var ids: (Rig) -> [String] { { $0.model.sessions.map(\.displayTitle) } }

    // MARK: Carrying

    func testDraggingATabPastItsNeighbourSwapsThemLive() throws {
        let rig = rig()
        XCTAssertEqual(ids(rig), titles)
        try drag("Alfa", by: 70, in: rig, release: false)
        XCTAssertEqual(ids(rig), ["Beta", "Alfa", "Gamma"], "the model's order followed while the tab was still held")
        XCTAssertTrue(rig.model.tabDragInProgress, "the island is held open while a tab is carried")
        send(.leftMouseUp, try top(of: "Alfa", in: rig), in: rig)
        wait(1.0)
        XCTAssertFalse(rig.model.tabDragInProgress)
        XCTAssertEqual(ids(rig), ["Beta", "Alfa", "Gamma"])
    }

    func testItCanGoAllTheWayAcrossAndBack() throws {
        let rig = rig()
        try drag("Alfa", by: 420, in: rig)
        XCTAssertEqual(ids(rig), ["Beta", "Gamma", "Alfa"], "to the far end")
        try drag("Alfa", by: -420, in: rig)
        XCTAssertEqual(ids(rig), titles, "and back to the start")
    }

    func testADragDoesNotSelectAnything() throws {
        let rig = rig()
        XCTAssertEqual(rig.model.selectedID, rig.sessions[2].id)
        try drag("Alfa", by: 70, in: rig)
        XCTAssertEqual(rig.model.selectedID, rig.sessions[2].id, "the tab that was selected still is: moving a tab is not choosing it")
    }

    /// With the island's animations off (what Reduce Motion asks for too) the tab still follows the pointer and the order still changes: nothing lifts or springs.
    func testWithTheAnimationsOffItStillReorders() throws {
        let rig = rig(animations: false)
        try drag("Alfa", by: 70, in: rig)
        XCTAssertEqual(ids(rig), ["Beta", "Alfa", "Gamma"])
        XCTAssertFalse(rig.model.tabDragInProgress)
    }

    /// The row shows, once the tab is let go and has settled, the model's order: the tabs stand left to right as `sessions` says.
    func testWhenItSettlesTheStripStandsInTheModelsOrder() throws {
        let rig = rig()
        try drag("Alfa", by: 70, in: rig)
        let xs = try ids(rig).map { try top(of: $0, in: rig).x }
        XCTAssertEqual(xs, xs.sorted(), "left to right in the model's order: \(xs)")
        XCTAssertEqual(Set(xs).count, 3)
    }

    /// The order the strip ends in is the order the model has (`AppModel.moveSession` keeps it, across launches).
    func testTheNewOrderIsTheModelsOrder() throws {
        let rig = rig()
        try drag("Alfa", by: 70, in: rig)
        let moved = rig.model.sessions.map(\.id)
        XCTAssertEqual(moved, [rig.sessions[1].id, rig.sessions[0].id, rig.sessions[2].id])
    }

    // MARK: What a tab already did

    func testAClickThatDoesNotMoveStillSelects() throws {
        let rig = rig()
        try click("Beta", in: rig)
        XCTAssertEqual(rig.model.selectedID, rig.sessions[1].id)
        XCTAssertEqual(ids(rig), titles, "and moves nothing")
        XCTAssertFalse(rig.model.tabDragInProgress)
    }

    /// A press that moves less than the threshold is a click, not a drag.
    func testAWobbleBelowTheThresholdIsStillAClick() throws {
        let rig = rig()
        let start = try top(of: "Beta", in: rig)
        send(.leftMouseDown, start, in: rig)
        send(.leftMouseDragged, NSPoint(x: start.x + 2, y: start.y), in: rig)
        send(.leftMouseUp, NSPoint(x: start.x + 2, y: start.y), in: rig)
        wait(0.2)
        XCTAssertEqual(rig.model.selectedID, rig.sessions[1].id)
        XCTAssertEqual(ids(rig), titles)
    }

    func testTheCloseButtonStillCloses() throws {
        let rig = rig()
        try click("Cerrar pestaña", in: rig)
        XCTAssertEqual(rig.model.sessions.count, 2, "a click on a tab's ✕ closes that tab")
    }

    /// The model is told when the island lets go of the drag: with no button down the row ends it, wherever the pointer is.
    func testTheDragEndsWhenTheIslandLetsGoOfIt() throws {
        let rig = rig()
        try drag("Alfa", by: 70, in: rig, release: false)
        XCTAssertTrue(rig.model.tabDragInProgress)
        rig.model.tabDragInProgress = false   // `NotchController.trackPointer` does this when no button is down
        wait(1.0)
        XCTAssertEqual(ids(rig), ["Beta", "Alfa", "Gamma"], "the order it had reached is the order it keeps")
        let xs = try ids(rig).map { try top(of: $0, in: rig).x }
        XCTAssertEqual(xs, xs.sorted(), "and the strip settled")
    }

    /// More tabs than the row holds: a tab carried to the strip's edge and held there scrolls the strip, and takes the tab past the ones that were out of sight.
    func testHoldingATabAtTheEdgeScrollsTheStripAndCarriesItPastTheHiddenTabs() throws {
        let names = ["Uno", "Dos", "Tres", "Cuatro", "Cinco", "Seis", "Siete", "Ocho", "Nueve"]
        // The animations off: the strip jumps to the tab it brings into view (a window that is not on a screen runs no animation), which is what Reduce Motion asks for too.
        let rig = rig(animations: false, titles: names)
        XCTAssertEqual(ids(rig), names)
        let secondAtFirst = try top(of: "Dos", in: rig).x
        XCTAssertGreaterThan(try top(of: "Nueve", in: rig).x, rig.host.bounds.width - 130, "the last tab starts out of sight, beyond the row's end")
        // Out to the strip's right edge and on past it, then held there: the strip takes a step every quarter of a second.
        let start = try top(of: "Uno", in: rig)
        send(.leftMouseDown, start, in: rig)
        var x = start.x
        let edge = rig.host.bounds.width - 130
        while x < edge {
            x += 6
            send(.leftMouseDragged, NSPoint(x: x, y: start.y), in: rig)
            wait(0.016)
        }
        // The pointer stays still; only time passes.
        for _ in 0..<10 {
            send(.leftMouseDragged, NSPoint(x: x, y: start.y), in: rig)
            wait(0.3)
        }
        XCTAssertTrue(rig.model.tabDragInProgress, "still carried")
        XCTAssertEqual(ids(rig).last, "Uno", "holding it at the edge took it past every tab, those that had been out of sight too: \(ids(rig))")
        let secondNow = try top(of: "Dos", in: rig).x
        XCTAssertLessThan(secondNow, secondAtFirst - 100, "the strip scrolled: \(secondAtFirst) → \(secondNow)")
        send(.leftMouseUp, NSPoint(x: x, y: start.y), in: rig)
        wait(1.0)
        XCTAssertFalse(rig.model.tabDragInProgress)
        XCTAssertEqual(ids(rig), Array(names.dropFirst()) + ["Uno"], "and it stayed there")
    }

    func testClosingATabWhileOneIsCarriedEndsTheDrag() throws {
        let rig = rig()
        try drag("Alfa", by: 70, in: rig, release: false)
        rig.model.close(rig.sessions[2])
        wait(0.6)
        XCTAssertFalse(rig.model.tabDragInProgress)
        XCTAssertEqual(rig.model.sessions.count, 2)
        let xs = try ids(rig).map { try top(of: $0, in: rig).x }
        XCTAssertEqual(xs, xs.sorted())
    }
}
