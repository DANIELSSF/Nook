import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A tab that is closed while the island shows its tab row is freed. SwiftUI keeps on to the closures of its views for a while (a hover's callback in
/// its responders until an event reaches them, a context menu's content, a popover's), so none of those may hold the tab, or the list of tabs it was in.
@MainActor
final class TabClosureTests: XCTestCase {
    private func session(_ model: AppModel, _ n: Int) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: n, tty: "/dev/ttys08\(n)", customTitle: "tab \(n)", processes: ["login", "-zsh", "claude"], busy: false,
                                      selected: n == 1, text: "⏺ hola")
        return TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
    }

    func testAClosedTabIsFreedWhetherTheIslandIsOpenOrCollapsed() {
        for open in [true, false] {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-closure-" + UUID().uuidString)!)
            let first = session(model, 1)
            var second: TerminalSession? = session(model, 2)
            weak var closed = second
            model.sessions = [first, second!]; model.selectedID = first.id
            model.expanded = open; model.islandContentVisible = open
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            model.close(second!)
            second = nil
            for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded(); host.display() }
            XCTAssertNil(closed, "The closed tab is gone (island \(open ? "open" : "collapsed")).")
            window.contentView = nil
        }
    }

    /// The same with Claude's record, subagents and a few readings behind the tabs, as a day's work leaves them.
    func testAClosedTabIsFreedWithAWorkloadBehindIt() throws {
        let workload = try MemoryWorkload(tabs: 2, recordBytes: 20_000, panel: true)
        defer { workload.tearDown() }
        workload.setOpen(true)
        for _ in 0..<5 { workload.poll(history: true) }
        workload.settle()
        weak var closed = workload.model.sessions.last
        XCTAssertNotNil(closed)
        autoreleasepool { workload.model.close(workload.model.sessions.last!) }
        for _ in 0..<4 { workload.poll(history: true) }
        for _ in 0..<4 { workload.settle() }
        XCTAssertNil(closed, "Nothing in the tab row keeps the closed tab.")
    }
}
