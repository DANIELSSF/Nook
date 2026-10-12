import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The usage card is laid out for exactly the width of the island it is in, and nothing of it is drawn past the island's edge, on the island as the app runs it: the real
/// controller with its window, its shape and the real panel in them, on this machine's own screen (the window is all but transparent and takes no pointer, so nobody sees
/// or touches it). What is compared is what the app plans (the island's frame, the width the content is laid out for, the width the card measured itself at) with what it
/// really gets (the window's frame, the island view, the hosting view, the shape's box and what is drawn), at rest, while the island moves and after it was opened with the
/// card already up, its panel grew or its size changed.
@MainActor
final class IslandWidthTests: XCTestCase {
    // MARK: The island as the app runs it

    @MainActor private struct Island {
        let model: AppModel
        let controller: NotchController
        let session: TerminalSession

        var panel: NotchPanel { controller.panel }
        var view: NSView { controller.panel.contentView! }
        var hosting: NSView { view.subviews.first { String(describing: type(of: $0)).hasPrefix("NSHostingView") }! }
        var shape: CGRect { (view as? IslandView)?.shape.path?.boundingBox ?? .null }
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Sample's /usage as Claude draws it, and then some: the sections, a long table of subagents and the footer.
    private func usageText(extraAgents: Int = 0) -> String {
        var lines = ClaudeUsageFixtures.whole.components(separatedBy: "\n")
        let extra = (0..<extraAgents).map { "  subagent-number-\($0)                    \(($0 % 9) + 1)%" }
        if let index = lines.firstIndex(where: { $0.contains("Esc to cancel") }) { lines.insert(contentsOf: extra, at: index) }
        return lines.joined(separator: "\n")
    }

    private func tab(_ text: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
    }

    /// The controller on this machine's screen with a Terminal tab whose Claude has its usage panel open, the island pinned open at this width and text size.
    private func open(width: CGFloat, chat: Double = 11, text: String? = nil) throws -> Island {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-width-" + UUID().uuidString)!)
        var display = DisplaySettings()
        display.widthExtra = width - NotchGeometry.expandedWidth
        display.chatSize = chat
        model.display = display
        model.pinned = true
        let session = TerminalSession(tab: tab(text ?? usageText(extraAgents: 12)), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        XCTAssertNotNil(session.panel, "The fixture is a Claude with its usage panel open.")
        let controller = NotchController(model: model, quiet: true)
        model.updateActivity()
        controller.expand(focus: false)
        return Island(model: model, controller: controller, session: session)
    }

    private func close(_ island: Island) {
        island.controller.collapse(force: true)
        settle(0.5)
        island.controller.panel.close()
        island.controller.petPanel.close()
        island.model.controller = nil
    }

    /// Waits until the island has stopped: no move on, and the same frame for most of a second.
    private func waitUntilAtRest(_ island: Island, within seconds: TimeInterval = 10) {
        var last = island.panel.frame, still = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            settle(0.1)
            let now = island.panel.frame
            still = now == last && !island.controller.roomKeeper.isMoving ? still + 1 : 0
            last = now
            if still >= 9 { return }
        }
    }

    // MARK: What is compared

    /// What the content may never be, at any instant: laid out for a width the window does not have.
    private func assertNeverWiderThanTheWindow(_ island: Island, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = island.panel.frame, hosting = island.hosting.frame
        XCTAssertLessThanOrEqual(island.model.islandSize.width, window.width + 0.5, "\(label): the content is laid out for \(island.model.islandSize.width) pt in a window of \(window.width)", file: file, line: line)
        XCTAssertEqual(hosting.width, island.view.bounds.width, accuracy: 0.5, "\(label): the hosting view is the island view's width", file: file, line: line)
        XCTAssertEqual(island.view.bounds.width, window.width, accuracy: 0.5, "\(label): the island view is the window's width", file: file, line: line)
        if let presented = (island.view as? IslandView)?.shape.presentation()?.path?.boundingBox {
            XCTAssertLessThanOrEqual(presented.maxX, window.width + 1, "\(label): the shape shown is inside the window", file: file, line: line)
            XCTAssertGreaterThanOrEqual(presented.minX, -1, "\(label): the shape shown is inside the window", file: file, line: line)
        }
    }

    /// Everything the island is at rest: the planned frame is the real one, all of the window is the island, the shape is all of it, the content is laid out for it, and
    /// the card measured itself at the width it has there.
    private func assertAtRest(_ island: Island, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let controller = island.controller
        let planned = controller.roomScreen.frame(of: controller.roomKeeper.size)
        let window = island.panel.frame
        XCTAssertEqual(window.minX, planned.minX, accuracy: 0.5, "\(label): the window's left edge is the planned one", file: file, line: line)
        XCTAssertEqual(window.width, planned.width, accuracy: 0.5, "\(label): the window's width is the planned one", file: file, line: line)
        XCTAssertEqual(window.height, planned.height, accuracy: 0.5, "\(label): the window's height is the planned one", file: file, line: line)
        XCTAssertEqual(window.maxY, planned.maxY, accuracy: 0.5, "\(label): it hangs from the screen's top edge", file: file, line: line)
        XCTAssertEqual(window.midX, controller.compactFrame.midX, accuracy: 0.5, "\(label): on the notch's axis", file: file, line: line)
        XCTAssertEqual(island.view.bounds.size.width, window.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(island.view.bounds.size.height, window.height, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(island.hosting.frame.size.width, window.width, accuracy: 0.5, "\(label): the hosting view is the whole window", file: file, line: line)
        XCTAssertEqual(island.hosting.frame.size.height, window.height, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(island.shape.width, window.width, accuracy: 1, "\(label): the shape is all of the window's width", file: file, line: line)
        XCTAssertEqual(island.shape.height, window.height, accuracy: 1, "\(label): …and its height", file: file, line: line)
        XCTAssertEqual(island.shape.minX, 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(island.model.islandSize.width, window.width, accuracy: 0.5, "\(label): the content is laid out for the window's width", file: file, line: line)
        XCTAssertEqual(island.model.islandSize.height, window.height, accuracy: 0.5, file: file, line: line)
        // The card measured itself at the width the island gives it, and that is inside the island with its margins on both sides.
        let room = try XCTUnwrap(controller.roomKeeper.room, "\(label): the card is asking for room", file: file, line: line)
        XCTAssertEqual(room.width, ClaudePanelCard.width(inIsland: window.width), accuracy: 1, "\(label): the card's width is the island's less its margins", file: file, line: line)
        XCTAssertLessThanOrEqual(room.width + 2 * ClaudePanelCard.paneEdge, window.width + 1, "\(label): the card is inside the island", file: file, line: line)
        // It has what it asked for, or all the screen leaves.
        XCTAssertGreaterThanOrEqual(window.height, min(ceil(ClaudePanelCard.island(forCard: room.height, neck: controller.neckHeight)), IslandGrowth.maxHeight(on: controller.roomScreen)) - 2, "\(label): the island is as tall as the card asked, up to the screen's limit", file: file, line: line)
        // Nothing is drawn between the card and the island's edge, which is where a card laid out wider than its island would show.
        let beside = try ink(island)
        XCTAssertGreaterThan(beside.card, 200, "\(label): the card is drawn (the render is not blank)", file: file, line: line)
        XCTAssertEqual(beside.margin, 0, "\(label): something is drawn in the margin between the card and the island's edge", file: file, line: line)
    }

    /// How much is drawn in the strip between where the card ends and the island's edge (none, when the card is inside its room), and in the card itself (the control: the render
    /// is not empty). A strip as tall as the card, 13 pt wide, a few points in from the edge, where the island's rim and its corners are not.
    private func ink(_ island: Island) throws -> (margin: Int, card: Int) {
        let view = island.hosting
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return try ink(in: rep, island: view.bounds.size, scale: scale)
    }

    private func ink(in rep: NSBitmapImageRep, island: CGSize, scale: CGFloat) throws -> (margin: Int, card: Int) {
        let data = try XCTUnwrap(rep.bitmapData)
        let perPixel = rep.bitsPerPixel / 8, rowBytes = rep.bytesPerRow
        func count(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Int {
            var found = 0
            for row in Int(y.lowerBound * scale)...Int(y.upperBound * scale) where row < rep.pixelsHigh {
                for column in Int(x.lowerBound * scale)...Int(x.upperBound * scale) where column < rep.pixelsWide {
                    let at = row * rowBytes + column * perPixel
                    if Int(data[at]) + Int(data[at + 1]) + Int(data[at + 2]) > 18 { found += 1 }
                }
            }
            return found
        }
        let top: CGFloat = 80, bottom = island.height - 30
        return (count(x: (island.width - 13)...(island.width - 3), y: top...bottom), count(x: 20...(island.width - 20), y: 100...200))
    }

    /// The control for what `ink` measures: a card as wide as the island, in a strip it should not be in, is seen.
    func testTheMarginIsSeenWhenSomethingIsDrawnInIt() throws {
        let size = CGSize(width: 400, height: 300)
        func rep(cardWidth: CGFloat) throws -> NSBitmapImageRep {
            let view = ZStack(alignment: .topLeading) { Color.black; Color(white: 0.2).frame(width: cardWidth, height: 200).padding(.top, 90) }.frame(width: size.width, height: size.height, alignment: .topLeading)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let scale = { (rep: NSBitmapImageRep) in CGFloat(rep.pixelsWide) / size.width }
        let inside = try rep(cardWidth: 370)
        XCTAssertEqual(try ink(in: inside, island: size, scale: scale(inside)).margin, 0, "A card that ends 30 pt before the edge leaves its margin black.")
        XCTAssertGreaterThan(try ink(in: inside, island: size, scale: scale(inside)).card, 100)
        let past = try rep(cardWidth: 400)
        XCTAssertGreaterThan(try ink(in: past, island: size, scale: scale(past)).margin, 100, "A card drawn all the way to the edge is seen in the margin.")
    }

    // MARK: At every width and text size

    /// The island opens with the usage card already up and grows for it: whatever width the user made it and whatever the size of the chat's text, the width the card is laid
    /// out for is the island's real width, at every instant and at rest, and nothing is drawn past the card's room.
    func testTheCardIsLaidOutForTheRealWidthOfTheIslandWhateverItsWidthAndTheTextSize() throws {
        for width in [CGFloat(440), 572, 672, 800] {
            for chat in [11.0, 18.0] {
                let label = "island \(Int(width)) wide, text \(Int(chat))"
                let island = try open(width: width, chat: chat)
                defer { close(island) }
                let user = island.controller.userFrame.size
                // Watched while it opens and grows: the content is never laid out for more than the window has.
                let end = Date().addingTimeInterval(1.6)
                while Date() < end { settle(0.02); assertNeverWiderThanTheWindow(island, label) }
                waitUntilAtRest(island)
                try assertAtRest(island, label)
                XCTAssertGreaterThanOrEqual(island.panel.frame.height, user.height, "\(label): never under the user's")
                if user.width >= IslandGrowth.widenBelow {
                    XCTAssertEqual(island.panel.frame.width, user.width, accuracy: 0.5, "\(label): an island with columns of its own keeps its width")
                }
                if let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] { try render(island, to: directory, name: "real-\(Int(user.width))-chat\(Int(chat))") }
            }
        }
    }

    /// The same island through what happens to it in a day: its panel gets longer (Nook reads more of Claude's), it is closed and opened again with the card still up, and the
    /// user changes its width. Each time the island settles to a width the card is laid out for.
    func testTheCardStaysTheWidthOfTheIslandWhenItsPanelGrowsItIsReopenedAndItsSizeChanges() throws {
        let island = try open(width: 672, text: usageText(extraAgents: 0))
        defer { close(island) }
        waitUntilAtRest(island)
        try assertAtRest(island, "opened")
        let first = island.panel.frame

        // More rows arrive, one screen at a time.
        for agents in [4, 12, 30, 60] {
            island.session.update(tab(usageText(extraAgents: agents)))
            let end = Date().addingTimeInterval(0.5)
            while Date() < end { settle(0.02); assertNeverWiderThanTheWindow(island, "\(agents) subagents") }
        }
        waitUntilAtRest(island)
        try assertAtRest(island, "the panel grown")
        XCTAssertEqual(island.panel.frame.width, first.width, accuracy: 0.5, "More rows do not change the island's width.")

        // Closed and opened again: the card is still up, and the island takes the room again.
        island.controller.collapse(force: true)
        settle(0.6)
        XCTAssertFalse(island.model.expanded)
        island.controller.expand(focus: false)
        let reopened = Date().addingTimeInterval(1.6)
        while Date() < reopened { settle(0.02); assertNeverWiderThanTheWindow(island, "reopened") }
        waitUntilAtRest(island)
        try assertAtRest(island, "reopened")

        // The user makes the island wider and narrower with the card up.
        for width in [CGFloat(740), 560, 440] {
            var display = island.model.display
            display.widthExtra = width - NotchGeometry.expandedWidth
            island.model.display = display
            let end = Date().addingTimeInterval(1.2)
            while Date() < end { settle(0.02); assertNeverWiderThanTheWindow(island, "set to \(Int(width))") }
            waitUntilAtRest(island)
            try assertAtRest(island, "set to \(Int(width))")
        }
    }

    // MARK: Renders

    /// The island as the hosting view draws it, with the margin between the card and the island's edge marked (for review).
    private func render(_ island: Island, to directory: String, name: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let view = island.hosting
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        print("REAL ISLAND \(name): window \(island.panel.frame) hosting \(view.frame.size) shape \(island.shape.size) model \(island.model.islandSize) asked \(String(describing: island.controller.roomKeeper.room))")
    }
}
