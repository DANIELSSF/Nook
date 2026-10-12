import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A tab's close button does not move while the pointer is on the tab row. Without that, the agent badge going away (a minute after the
/// last agent ends) slides the button into the badge's place, under a pointer that was about to click the badge.
///
/// The tab is clicked, as the island's own window gets mouse events: a panel that can be key, away from the screen. The tab's width is
/// what its host asks for, as it is in the row's scroll view, which proposes none.
@MainActor
final class SessionTabLayoutTests: XCTestCase {
    /// What flips `\.nookTabRowHeld` while a tab is on show, the way the row's hover does.
    private final class Pointer: ObservableObject {
        @Published var onRow: Bool
        init(_ onRow: Bool) { self.onRow = onRow }
    }

    private struct Harness: View {
        let model: AppModel
        let session: TerminalSession
        @ObservedObject var pointer: Pointer
        var body: some View {
            SessionTab(model: model, session: session, agentList: TabAgentListPresenter())
                .environment(\.nookTabRowHeld, pointer.onRow)
                .fixedSize()
        }
    }

    @MainActor private struct Rig {
        var model: AppModel
        var window: NotchPanel
        var host: NSHostingView<Harness>
        var session: TerminalSession
        var pointer: Pointer
        /// The tab's width as it is laid out now.
        var width: CGFloat { host.fittingSize.width }
        var open: Bool { !model.sessions.isEmpty }
    }

    private func rig(pointerOnRow: Bool, title: String = "ui") -> Rig {
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys089", customTitle: title, processes: ["login", "-zsh", "claude"], busy: false,
                                      selected: true, text: "⏺ Revisando.")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]
        model.selectedID = session.id
        let pointer = Pointer(pointerOnRow)
        let host = NSHostingView(rootView: Harness(model: model, session: session, pointer: pointer))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NotchPanel(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: host.frame.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let rig = Rig(model: model, window: window, host: host, session: session, pointer: pointer)
        settle(rig)
        return rig
    }

    /// Lets what changed play out, then sizes the window to what the tab asks for, as the row would.
    private func settle(_ rig: Rig, _ seconds: Double = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        rig.host.layoutSubtreeIfNeeded()
        let size = NSSize(width: rig.host.fittingSize.width, height: max(rig.host.fittingSize.height, 30))
        rig.window.setContentSize(size)
        rig.host.frame = NSRect(origin: .zero, size: size)
        rig.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func working() -> SubagentActivity {
        SubagentActivity(id: "a", name: "Review the notch", kind: "general-purpose", state: .running, background: true, toolUses: nil, tokens: nil, duration: nil, note: nil)
    }

    /// A click `x` points from the tab's left edge, half-way down it. True when the tab was closed by it.
    private func click(_ rig: Rig, atX x: CGFloat) -> Bool {
        let point = rig.host.convert(NSPoint(x: x, y: rig.host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            rig.window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return !rig.open
    }

    /// The middle of the close button: it is the tab's last 16 points, and 3 points of padding come after them.
    private func buttonX(_ width: CGFloat) -> CGFloat { width - 3 - 8 }

    func testTheCloseButtonIsAtTheTabsTrailingEdge() {
        let rig = rig(pointerOnRow: false)
        XCTAssertTrue(click(rig, atX: buttonX(rig.width)), "a click there closes the tab")
    }

    /// The hazard itself: with nothing holding the tab, the button moves into the place the badge had, where a pointer resting on the
    /// badge now finds it.
    func testWithoutTheHoldTheCloseButtonSlidesIntoTheBadgesPlace() {
        let bare = rig(pointerOnRow: false)
        let narrow = bare.width

        let rig = rig(pointerOnRow: false)
        rig.session.subagents = [working()]
        settle(rig)
        let wide = rig.width
        XCTAssertGreaterThan(wide, narrow + 28, "the badge makes room for itself")
        // Where the pointer rests on the badge: its left part, which was this far from the tab's edge when the tab was narrow.
        let onTheBadge = narrow - 3 - 16 + 8
        XCTAssertLessThan(onTheBadge, wide - 3 - 16 - 4 - 4, "that is within the badge")
        rig.session.subagents = []
        settle(rig)
        XCTAssertEqual(rig.width, narrow, accuracy: 0.5)
        XCTAssertTrue(click(rig, atX: onTheBadge), "and the button is under it")
    }

    func testWhileThePointerIsOnTheRowTheButtonStaysWhereItWas() {
        let narrow = rig(pointerOnRow: false).width

        let rig = rig(pointerOnRow: true)
        rig.session.subagents = [working()]
        settle(rig)
        let wide = rig.width
        rig.session.subagents = []
        settle(rig)
        XCTAssertEqual(rig.width, wide, accuracy: 0.5, "the tab keeps its width")
        let onTheBadge = narrow - 3 - 16 + 8
        XCTAssertFalse(click(rig, atX: onTheBadge), "nothing is where the badge was")
        XCTAssertTrue(click(rig, atX: buttonX(wide)), "and the button is where it was")
    }

    func testThePointerComingOntoTheRowHoldsTheTabAsItIsThen() {
        let narrow = rig(pointerOnRow: false).width

        let rig = rig(pointerOnRow: false)
        rig.session.subagents = [working()]
        settle(rig)
        let wide = rig.width
        rig.pointer.onRow = true
        settle(rig)
        rig.session.subagents = []
        settle(rig)
        XCTAssertEqual(rig.width, wide, accuracy: 0.5)
        XCTAssertFalse(click(rig, atX: narrow - 3 - 16 + 8))
        XCTAssertTrue(click(rig, atX: buttonX(wide)))
    }

    /// The room is kept only for as long as the pointer is there.
    func testThePointerLeavingLetsTheTabNarrow() {
        let narrow = rig(pointerOnRow: false).width

        let rig = rig(pointerOnRow: true)
        rig.session.subagents = [working()]
        settle(rig)
        let wide = rig.width
        rig.session.subagents = []
        settle(rig)
        XCTAssertEqual(rig.width, wide, accuracy: 0.5, "held while the pointer is there")
        rig.pointer.onRow = false
        settle(rig, 0.7)
        XCTAssertEqual(rig.width, narrow, accuracy: 0.5, "and gone with it")
        XCTAssertTrue(click(rig, atX: buttonX(narrow)))
    }

    /// Holding only stops a tab from shrinking: one that has something to add (a badge that comes) still grows.
    func testAHeldTabStillGrowsForABadgeThatComes() {
        let rig = rig(pointerOnRow: true)
        let bare = rig.width
        rig.session.subagents = [working()]
        settle(rig)
        XCTAssertGreaterThan(rig.width, bare + 28)
    }

    /// A shorter title narrows a tab as the badge does, and is held the same way.
    func testAShorterTitleIsHeldToo() {
        let rig = rig(pointerOnRow: true)
        rig.session.customTitle = "Una pestaña con un título bastante largo"
        settle(rig)
        let wide = rig.width
        rig.session.customTitle = "ui"
        settle(rig)
        XCTAssertEqual(rig.width, wide, accuracy: 0.5)
        XCTAssertTrue(click(rig, atX: buttonX(wide)), "the button has not moved")
    }

    /// Nothing is added to a tab that does not change: holding is not padding.
    func testHoldingAddsNothingToATabThatDidNotChange() {
        XCTAssertEqual(rig(pointerOnRow: true).width, rig(pointerOnRow: false).width, accuracy: 0.5)
    }
}
