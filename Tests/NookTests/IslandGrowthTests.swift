import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The island that takes the height the usage card asks for (`IslandGrowth.swift`): how much it gives and where the screen says stop, how its window and its shape
/// go from one size to another and back, what the keeper does with the asks, and that the card's ask gets there through the panel. The island here is a stand-in, far
/// off every display, so no test touches the real one or puts anything on screen that anybody could see.
@MainActor
final class IslandGrowthTests: XCTestCase {
    // MARK: Screens

    /// A screen of this size with a notch of `notch` pt (0: none; the header is never under 28), the menu bar over it, and a Dock of `dock` pt under it. `origin` puts it
    /// somewhere no real display is.
    private func screen(width: CGFloat = 1512, height: CGFloat = 982, dock: CGFloat = 0, menuBar: CGFloat = 38, notch: CGFloat = 32, origin: CGPoint = .zero) -> IslandScreen {
        IslandScreen(frame: CGRect(x: origin.x, y: origin.y, width: width, height: height),
                     visible: CGRect(x: origin.x, y: origin.y + dock, width: width, height: height - dock - menuBar),
                     topInset: notch, neck: max(notch, 28), centerX: origin.x + width / 2)
    }

    private func userSize(_ settings: DisplaySettings = DisplaySettings(), on screen: IslandScreen) -> CGSize {
        NotchGeometry.expandedSize(screen: screen.frame.size, topInset: screen.topInset, settings: settings)
    }

    /// What a card of this height at this island width asks.
    private func asks(_ height: CGFloat, island width: CGFloat) -> IslandRoom { IslandRoom(height: height, width: ClaudePanelCard.width(inIsland: width)) }

    // MARK: How much it gives

    func testNothingAskingLeavesTheUsersSize() {
        let screen = screen(), user = userSize(on: screen)
        XCTAssertEqual(IslandGrowth.size(for: nil, now: user, user: user, screen: screen), user)
        XCTAssertEqual(IslandGrowth.size(for: IslandRoom(height: 0, width: 542), now: user, user: user, screen: screen), user, "A card that has not measured itself yet asks nothing.")
        // A card gone gives the size back, whatever the island had taken.
        let grown = CGSize(width: user.width, height: 640)
        XCTAssertEqual(IslandGrowth.size(for: nil, now: grown, user: user, screen: screen), user)
    }

    func testATallerCardGivesTheIslandItsHeightAndNothingMore() {
        let screen = screen(), user = userSize(on: screen)
        // Sample's Terminal tab at the usual width: the card wants 567 pt, and the island is that and the header and the tab row and the pane's margins.
        let size = IslandGrowth.size(for: asks(567, island: user.width), now: user, user: user, screen: screen)
        XCTAssertEqual(size.width, user.width, "Its width is the user's.")
        XCTAssertEqual(size.height, 567 + screen.neck + PaneLayout.tabRowHeight + ClaudePanelCard.topMargin + ComposerMetrics.bottomInset)
        XCTAssertEqual(size.height, 640)
        XCTAssertEqual(ClaudePanelCard.height(inIsland: size.height, neck: screen.neck), 567, "…which leaves the card exactly the height it asked for.")
        // The same card on a screen with no notch: the header is 28, not 32.
        let flat = self.screen(notch: 0)
        XCTAssertEqual(IslandGrowth.size(for: asks(567, island: user.width), now: userSize(on: flat), user: userSize(on: flat), screen: flat).height, 636)
        // A half point is a whole one.
        XCTAssertEqual(IslandGrowth.size(for: IslandRoom(height: 567.4, width: 542), now: user, user: user, screen: screen).height, 641)
    }

    func testTheUsersFrameAndTheFrameOfAGrownIslandAreTheSameFunctionOfTheirSize() {
        // The controller answers `userFrame` from the settings and a grown island's frame from its size: for the same size they are the same frame.
        for screen in [self.screen(), self.screen(notch: 0), self.screen(width: 1728, height: 1117, notch: 38), self.screen(origin: CGPoint(x: -1800, y: 200))] {
            for preset in IslandPreset.allCases {
                let settings = DisplaySettings().applying(preset)
                let size = userSize(settings, on: screen)
                XCTAssertEqual(NotchGeometry.expandedFrame(screen: screen.frame, centerX: screen.centerX, topInset: screen.topInset, settings: settings), screen.frame(of: size), "\(preset)")
            }
        }
    }

    func testAnIslandThatAlreadyHasTheRoomStaysAndNeverGoesUnderTheUsersSize() {
        let screen = screen()
        let tall = userSize(DisplaySettings().applying(.tall), on: screen)
        XCTAssertGreaterThan(tall.height, 480)
        // A small card in a tall island: nothing to give, and nothing taken back.
        XCTAssertEqual(IslandGrowth.size(for: asks(150, island: tall.width), now: tall, user: tall, screen: screen), tall)
        // A card of 400 in the tall island (482 pt) fits as it is.
        XCTAssertEqual(IslandGrowth.size(for: asks(400, island: tall.width), now: tall, user: tall, screen: screen), tall)
        // Having grown for a big card, a smaller one brings the island down, but never under the user's.
        let grown = CGSize(width: tall.width, height: 700)
        XCTAssertEqual(IslandGrowth.size(for: asks(300, island: tall.width), now: grown, user: tall, screen: screen).height, tall.height)
        XCTAssertEqual(IslandGrowth.size(for: asks(500, island: tall.width), now: grown, user: tall, screen: screen).height, 500 + 32 + 41)
    }

    func testTheScreenIsTheLimitAndTheDockIsRespected() {
        // A short screen with a Dock: 40 pt short of its height is what any island may be (660), and the Dock and a margin leave less (618).
        let short = screen(width: 1440, height: 700, dock: 70)
        XCTAssertEqual(IslandGrowth.maxHeight(on: short), 618)
        XCTAssertEqual(IslandGrowth.maxHeight(on: screen(width: 1440, height: 700)), 660, "With no Dock the display's own limit.")
        XCTAssertEqual(IslandGrowth.maxHeight(on: screen(width: 1440, height: 700, dock: 3)), 660, "A Dock that hides leaves the 40 pt as they are.")
        XCTAssertEqual(IslandGrowth.maxWidth(on: short), 1408)
        let user = userSize(on: short)
        // At 720 wide, a card of 500 fits (500 + 73 = 573); at the user's 572 a card of 700 does not.
        let wide = CGSize(width: IslandGrowth.wideWidth, height: user.height)
        XCTAssertEqual(IslandGrowth.size(for: asks(500, island: wide.width), now: wide, user: user, screen: short).height, 573)
        let capped = IslandGrowth.size(for: asks(700, island: wide.width), now: wide, user: user, screen: short)
        XCTAssertEqual(capped.height, 618, "Past what the screen leaves, the card scrolls inside it.")
        XCTAssertEqual(capped.width, wide.width, "…and the width stays.")
        // The island's bottom edge is above the Dock's top edge.
        XCTAssertLessThanOrEqual(short.frame.maxY - 618, short.frame.maxY - 618)
        XCTAssertGreaterThanOrEqual(short.frame(of: capped).minY, short.visible.minY + IslandGrowth.bottomMargin - 1)
        // A user who made the island taller than the screen leaves room for is not made smaller.
        let huge = CGSize(width: 572, height: 640)
        XCTAssertEqual(IslandGrowth.size(for: asks(900, island: 572), now: huge, user: huge, screen: short).height, 640)
    }

    /// An island's width given by a settings' offset from the usual 572.
    private func userSize(width: CGFloat, on screen: IslandScreen) -> CGSize {
        var settings = DisplaySettings()
        settings.widthExtra = width - NotchGeometry.expandedWidth
        return userSize(settings, on: screen)
    }

    func testOnlyAnIslandTooNarrowForColumnsAsksForAWiderOneBeforeItScrolls() {
        let short = screen(width: 1440, height: 760, dock: 70)
        XCTAssertEqual(IslandGrowth.maxHeight(on: short), 678)
        // An island of 452: the card is one column, and 700 pt of it want 773, more than the screen leaves. The island goes wider first (a wide card is a short one), and
        // keeps its height until the card has measured itself again.
        let user = userSize(width: 452, on: short)
        XCTAssertEqual(user.width, 452)
        let first = IslandGrowth.size(for: asks(700, island: user.width), now: user, user: user, screen: short)
        XCTAssertEqual(first, CGSize(width: IslandGrowth.wideWidth, height: user.height))
        // The card's new reading, at 720 wide, is shorter and fits.
        let second = IslandGrowth.size(for: asks(560, island: first.width), now: first, user: user, screen: short)
        XCTAssertEqual(second, CGSize(width: IslandGrowth.wideWidth, height: 560 + 73))
        // Asked once more it says the same: it has settled.
        XCTAssertEqual(IslandGrowth.size(for: asks(560, island: second.width), now: second, user: user, screen: short), second)
        // The width does not go back while the card stays, whatever the card then asks.
        XCTAssertEqual(IslandGrowth.size(for: asks(200, island: second.width), now: second, user: user, screen: short).width, IslandGrowth.wideWidth)
        // The line is at 480: an island of 479 is widened, one of 480 is not.
        for (edge, widened) in [(CGFloat(479), true), (480, false)] {
            let island = userSize(width: edge, on: short)
            XCTAssertEqual(island.width, edge)
            let size = IslandGrowth.size(for: asks(900, island: island.width), now: island, user: island, screen: short)
            XCTAssertEqual(size.width, widened ? IslandGrowth.wideWidth : island.width, "An island \(Int(edge)) wide.")
        }
        // The usual island (572), Sample's (672) and wider ones keep their width: they take what the screen leaves, and the card scrolls inside it.
        for edge in [CGFloat(572), 672, 720, 900] {
            let island = userSize(width: edge, on: short)
            let size = IslandGrowth.size(for: asks(900, island: island.width), now: island, user: island, screen: short)
            XCTAssertEqual(size, CGSize(width: island.width, height: max(678, island.height)), "An island \(Int(edge)) wide is not widened.")
        }
        // A screen too narrow for 720 widens as far as it goes.
        let narrow = screen(width: 700, height: 500)
        XCTAssertEqual(IslandGrowth.size(for: asks(900, island: 452), now: CGSize(width: 452, height: 266), user: CGSize(width: 452, height: 266), screen: narrow).width, 668)
    }

    func testAReadingMadeForAnotherWidthWaitsForTheCardsNewOne() {
        let screen = screen(), user = userSize(on: screen)
        // The island is 572 wide, the card 542; a reading of a card 400 wide is not about this island.
        XCTAssertEqual(IslandGrowth.size(for: IslandRoom(height: 900, width: 400), now: user, user: user, screen: screen), user)
        let grown = CGSize(width: user.width, height: 640)
        XCTAssertEqual(IslandGrowth.size(for: IslandRoom(height: 900, width: 400), now: grown, user: user, screen: screen), grown, "…and it does not move the island either way.")
        // A point of difference is the card's own rounding.
        XCTAssertEqual(IslandGrowth.size(for: IslandRoom(height: 567, width: 541.4), now: user, user: user, screen: screen).height, 640)
    }

    func testAChangeOfAPointOrSoIsNotAMove() {
        let screen = screen(), user = userSize(on: screen)
        let grown = CGSize(width: user.width, height: 640)
        XCTAssertEqual(IslandGrowth.size(for: asks(568, island: user.width), now: grown, user: user, screen: screen), grown, "One point more.")
        XCTAssertEqual(IslandGrowth.size(for: asks(566, island: user.width), now: grown, user: user, screen: screen), grown, "One point less.")
        XCTAssertEqual(IslandGrowth.size(for: asks(570, island: user.width), now: grown, user: user, screen: screen).height, 643, "Three is a move.")
    }

    /// The card's height at an island width, as a stand-in for the real one: narrower is taller.
    private func card(at island: CGFloat, base: CGFloat) -> IslandRoom {
        let width = ClaudePanelCard.width(inIsland: island)
        return IslandRoom(height: (base * pow(542 / width, 0.9)).rounded(), width: width)
    }

    func testItSettlesInAtMostTwoStepsAndStaysWhateverTheScreenTheCardOrTheUser() {
        var settings: [DisplaySettings] = [DisplaySettings()]
        for preset in IslandPreset.allCases { settings.append(DisplaySettings().applying(preset)) }
        // Sample's island (672 wide), and one too narrow for columns.
        for extra in [CGFloat(100), -120] { var custom = DisplaySettings(); custom.widthExtra = extra; settings.append(custom) }
        for height in [600.0, 720, 800, 982, 1117, 1440] {
            for dock in [0.0, 70, 96] {
                for notch in [0.0, 32, 38] {
                    let screen = screen(width: 1512, height: height, dock: dock, notch: notch)
                    for setting in settings {
                        let user = userSize(setting, on: screen)
                        for base in [100.0, 300, 567, 900, 2000] {
                            let label = "screen \(Int(height)) dock \(Int(dock)) notch \(Int(notch)) \(setting.preset?.rawValue ?? "custom") card \(Int(base))"
                            var now = user
                            var steps = 0
                            while steps < 4 {
                                let next = IslandGrowth.size(for: card(at: now.width, base: CGFloat(base)), now: now, user: user, screen: screen)
                                if next == now { break }
                                now = next; steps += 1
                            }
                            XCTAssertLessThanOrEqual(steps, 2, "\(label): the width, then the height.")
                            XCTAssertEqual(IslandGrowth.size(for: card(at: now.width, base: CGFloat(base)), now: now, user: user, screen: screen), now, "\(label): settled.")
                            XCTAssertGreaterThanOrEqual(now.height, user.height, "\(label): never under the user's height.")
                            XCTAssertGreaterThanOrEqual(now.width, user.width, "\(label): never narrower than the user's.")
                            if user.width >= IslandGrowth.widenBelow { XCTAssertEqual(now.width, user.width, "\(label): an island with columns of its own is never widened.") }
                            XCTAssertLessThanOrEqual(now.height, max(IslandGrowth.maxHeight(on: screen), user.height), "\(label): within the screen.")
                            XCTAssertLessThanOrEqual(now.width, max(IslandGrowth.maxWidth(on: screen), user.width), "\(label): within the screen.")
                            let frame = screen.frame(of: now)
                            XCTAssertEqual(frame.maxY, screen.frame.maxY, "\(label): it hangs from the top edge, so it never leaves the notch.")
                            XCTAssertEqual(frame.midX, screen.centerX, accuracy: 0.5, "\(label): on the notch's axis.")
                            XCTAssertGreaterThanOrEqual(frame.minY, screen.frame.minY, "\(label): inside the display.")
                            XCTAssertGreaterThanOrEqual(frame.minX, screen.frame.minX); XCTAssertLessThanOrEqual(frame.maxX, screen.frame.maxX)
                        }
                    }
                }
            }
        }
    }

    // MARK: A stand-in for the island

    /// The island's window and the view that holds its shape, on a screen no real display is near. What it answers the keeper is what the test set.
    private final class StandIn: IslandRoomHost {
        let panel: NSWindow
        let island: IslandView
        var screen: IslandScreen
        var user: CGSize
        var mayMove = true
        var motion = true
        var changes = 0
        var durations: [Double] = []
        /// What the test does when the content has to be laid out for a new size (what the controller's `objectWillChange` is for).
        var onChange: () -> Void = {}

        init(panel: NSWindow, island: IslandView, screen: IslandScreen, user: CGSize) {
            self.panel = panel
            self.island = island
            self.screen = screen
            self.user = user
        }

        var roomPanel: NSWindow { panel }
        var roomIsland: IslandView { island }
        var roomScreen: IslandScreen { screen }
        var roomUserSize: CGSize { user }
        var roomMayMove: Bool { mayMove }
        func roomDuration(_ base: Double) -> Double { durations.append(base); return motion ? base : 0 }
        func roomChanged() { changes += 1; onChange() }
    }

    /// A window that is not given all the size it is asked (a system that holds it to a limit): it keeps the top edge it was given and the axis, and is as big as the limit lets it be.
    private final class LimitedPanel: NSPanel {
        var limit = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            var frame = frameRect
            let size = CGSize(width: min(frame.width, limit.width), height: min(frame.height, limit.height))
            frame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
            super.setFrame(frame, display: flag)
        }
    }

    private func standIn(_ screen: IslandScreen? = nil, settings: DisplaySettings = DisplaySettings(), limit: CGSize? = nil) -> StandIn {
        let screen = screen ?? self.screen(origin: CGPoint(x: -31512, y: -31000))
        let user = userSize(settings, on: screen)
        let island = IslandView()
        let panel: NSPanel
        if let limit {
            let limited = LimitedPanel(contentRect: screen.frame(of: user), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            limited.limit = limit
            panel = limited
        } else {
            panel = NotchPanel(contentRect: screen.frame(of: user), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        }
        panel.isReleasedWhenClosed = false
        panel.contentView = island
        island.layoutSubtreeIfNeeded()
        island.reveal(island.bounds, radius: 22, duration: 0) {}
        // On the screen list, far off it: a window that is not shown does not run its animations.
        panel.orderFrontRegardless()
        return StandIn(panel: panel, island: island, screen: screen, user: user)
    }

    /// What the window shows: the shape's box, in the window's own coordinates.
    private func shape(_ host: StandIn) -> CGRect { host.island.shape.path?.boundingBox ?? .null }

    /// The same box, to a hair: a shape's outline is a path of arcs, and its box is not exact to the last digit.
    private func assertBox(_ box: CGRect, _ expected: CGRect, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.minX, expected.minX, accuracy: 0.5, message(), file: file, line: line)
        XCTAssertEqual(box.minY, expected.minY, accuracy: 0.5, message(), file: file, line: line)
        XCTAssertEqual(box.width, expected.width, accuracy: 0.5, message(), file: file, line: line)
        XCTAssertEqual(box.height, expected.height, accuracy: 0.5, message(), file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: The window and the shape

    func testTheStageTakesTheWindowAndTheShapeToTheNewSizeAndBackExactly() {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        XCTAssertEqual(host.panel.frame, user, "Before: the user's own.")
        assertBox(shape(host), host.island.bounds)

        var arrived = 0
        stage.move(to: grown, duration: 0) { arrived += 1 }
        XCTAssertEqual(arrived, 1)
        XCTAssertEqual(host.panel.frame, grown, "Open: as tall as the card asked.")
        assertBox(shape(host), host.island.bounds, "…with the shape all over the window.")
        XCTAssertEqual(host.panel.frame.maxY, user.maxY, "It hangs from the same top edge: it never leaves the notch.")
        XCTAssertEqual(host.panel.frame.midX, user.midX, "…on the same axis.")

        stage.move(to: user, duration: 0) { arrived += 1 }
        XCTAssertEqual(arrived, 2)
        XCTAssertEqual(host.island.shape.frame, host.island.bounds, "The shape's layer follows the window it is in.")
        XCTAssertEqual(host.panel.frame, user, "After: the user's own, exactly.")
        assertBox(shape(host), host.island.bounds)
        XCTAssertTrue(host.panel.hasShadow, "The shadow is back with the island at rest.")
    }

    func testAGrowthTakesTheWindowAtOnceAndCarriesTheShapeDownFromWhereItWas() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0.4, timing: IslandRoomKeeper.curve)
        XCTAssertEqual(host.panel.frame, grown, "The window has its new size at once: the shape is what takes its time.")
        XCTAssertFalse(host.panel.hasShadow, "A shadow cannot follow a shape that is moving.")
        let animation = try XCTUnwrap(host.island.shape.animation(forKey: "reveal") as? CABasicAnimation)
        let from = (try XCTUnwrap(animation.fromValue) as! CGPath).boundingBox
        // It starts as the old island was, at the top of the new window.
        XCTAssertEqual(from.width, user.width, accuracy: 0.5); XCTAssertEqual(from.height, user.height, accuracy: 0.5)
        XCTAssertEqual(from.maxY, grown.height, accuracy: 0.5, "…against the window's top edge.")
        XCTAssertEqual(from.minX, 0, accuracy: 0.5)
        let to = (try XCTUnwrap(animation.toValue) as! CGPath).boundingBox
        assertBox(to, host.island.bounds, "It ends over the whole window.")
        settle(0.7)
        XCTAssertTrue(host.panel.hasShadow, "At rest the shadow returns.")
        assertBox(shape(host), host.island.bounds)
    }

    func testAShrinkKeepsTheWindowUntilTheShapeHasGotThereAndThenTakesTheSmallerSize() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0)
        var arrived = false
        stage.move(to: user, duration: 0.3, timing: IslandRoomKeeper.curve) { arrived = true }
        XCTAssertEqual(host.panel.frame, grown, "The window stays as big as the island was while the shape comes up.")
        XCTAssertFalse(arrived)
        let animation = try XCTUnwrap(host.island.shape.animation(forKey: "reveal") as? CABasicAnimation)
        let to = (try XCTUnwrap(animation.toValue) as! CGPath).boundingBox
        XCTAssertEqual(to.height, user.height, accuracy: 0.5); XCTAssertEqual(to.maxY, grown.height, accuracy: 0.5, "The shape's top stays on the window's.")
        settle(0.7)
        XCTAssertTrue(arrived)
        XCTAssertEqual(host.panel.frame, user, "Then exactly the user's size.")
        assertBox(shape(host), host.island.bounds)
    }

    func testAMoveThatIsGivenUpNeverFinishesAndTheShadowIsAsItWas() {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0)
        var arrived = false
        stage.move(to: user, duration: 0.3) { arrived = true }
        XCTAssertTrue(stage.isMoving)
        stage.cancel()
        XCTAssertFalse(stage.isMoving)
        XCTAssertTrue(host.panel.hasShadow)
        settle(0.6)
        XCTAssertFalse(arrived, "A move given up does not finish.")
        XCTAssertEqual(host.panel.frame, grown, "The window keeps what it had.")
    }

    func testAMoveInterruptedByAnotherContinuesFromWhereTheShapeIsOnScreen() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let big = host.screen.frame(of: CGSize(width: host.user.width, height: 700))
        let bigger = host.screen.frame(of: CGSize(width: host.user.width, height: 800))
        stage.move(to: big, duration: 0)
        var finished: [String] = []
        stage.move(to: user, duration: 0.5) { finished.append("shrink") }
        stage.move(to: bigger, duration: 0.2) { finished.append("grow") }
        settle(0.8)
        XCTAssertEqual(finished, ["grow"], "The first, interrupted, does not finish.")
        XCTAssertEqual(host.panel.frame, bigger)
        assertBox(shape(host), host.island.bounds)
    }

    func testAWindowLeftAtAnotherSizeTakesTheNewOneWithTheShapeWhereItIs() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0)
        // The island closed from the grown size and opens again on the user's: the shape, still as big as the window was, stays where it is on screen.
        let resumed = stage.align(to: user)
        XCTAssertEqual(host.panel.frame, user)
        let box = shape(host)
        assertBox(try XCTUnwrap(resumed).boundingBox, box, "The next move starts from where the shape is.")
        XCTAssertEqual(box.width, grown.width, accuracy: 0.5)
        XCTAssertEqual(box.height, grown.height, accuracy: 0.5, "Its size is what it was on screen,")
        XCTAssertEqual(box.maxY, user.height, accuracy: 0.5, "…hanging from the window's top edge.")
        // Aligning with the frame it already has changes nothing.
        XCTAssertNil(stage.align(to: user))
        assertBox(shape(host), box)
    }

    func testAMoveAnswersTheFrameTheWindowReallyGot() {
        let host = standIn(limit: CGSize(width: 10_000, height: 500))
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        // A window that is not allowed all of what it is asked: the move says what it got, for the content to be laid out for that and not for what was meant.
        let small = host.screen.frame(of: CGSize(width: host.user.width, height: 400))
        XCTAssertEqual(stage.move(to: small, duration: 0), small, "Asked a size the window can take, it answers that.")
        let bigger = host.screen.frame(of: CGSize(width: host.user.width, height: 700))
        let got = stage.move(to: bigger, duration: 0)
        XCTAssertEqual(got.height, 500, accuracy: 0.5)
        XCTAssertEqual(got.maxY, bigger.maxY, "It hangs from the top edge it was given.")
        XCTAssertEqual(got, host.panel.frame)
    }

    func testAMoveThatIsOverdueIsFinishedByHandOnceAndOnlyOnce() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0)
        var arrived = 0
        stage.move(to: user, duration: 0.3, timing: IslandRoomKeeper.curve) { arrived += 1 }
        XCTAssertTrue(stage.isMoving)
        // Not yet its time: it is let be.
        XCTAssertEqual(stage.reconcile(to: user), [])
        XCTAssertTrue(stage.isMoving)
        XCTAssertEqual(arrived, 0)
        // Its time went by and the shape's word never came: the island is put where it was going.
        let repairs = stage.reconcile(to: user, now: Date().addingTimeInterval(5))
        XCTAssertEqual(repairs.count, 1, "\(repairs)")
        XCTAssertEqual(arrived, 1)
        XCTAssertFalse(stage.isMoving)
        XCTAssertTrue(host.panel.hasShadow)
        XCTAssertEqual(host.panel.frame, user)
        assertBox(shape(host), host.island.bounds)
        // The shape's own word, late, finds the move ended.
        settle(0.6)
        XCTAssertEqual(arrived, 1, "It ends once.")
        XCTAssertEqual(host.panel.frame, user)
        assertBox(shape(host), host.island.bounds)
    }

    func testAnIslandAtRestIsPutRightWhenItsWindowOrItsShapeIsNotWhatItShouldBe() {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        XCTAssertEqual(stage.reconcile(to: user), [], "All as it should be: nothing is touched.")
        // A window that is narrower than the island it should be (the content, laid out for the island, would be cut at its edge).
        host.panel.setFrame(user.insetBy(dx: 24, dy: 0), display: false)
        host.island.layoutSubtreeIfNeeded()
        var repairs = stage.reconcile(to: user)
        XCTAssertEqual(repairs.count, 1, "\(repairs)")
        XCTAssertEqual(host.panel.frame, user)
        assertBox(shape(host), host.island.bounds)
        // A shape that is not all of the island.
        host.island.reveal(CGRect(x: 0, y: 0, width: user.width - 48, height: user.height), radius: 22, duration: 0) {}
        repairs = stage.reconcile(to: user)
        XCTAssertEqual(repairs.count, 1, "\(repairs)")
        assertBox(shape(host), host.island.bounds)
        // A window that is taller, and another that is somewhere else.
        host.panel.setFrame(user.offsetBy(dx: 30, dy: -40), display: false)
        XCTAssertEqual(stage.reconcile(to: user).count, 1)
        XCTAssertEqual(host.panel.frame, user)
        XCTAssertEqual(stage.reconcile(to: user), [], "…and then it stays.")
    }

    func testAShapeSetWithNoDurationIsThereAtOnceEvenIfAMoveWasOn() throws {
        let host = standIn()
        defer { host.panel.close() }
        let stage = IslandStage(panel: host.panel, island: host.island)
        let user = host.screen.frame(of: host.user)
        let grown = host.screen.frame(of: CGSize(width: host.user.width, height: 640))
        stage.move(to: grown, duration: 0)
        stage.move(to: user, duration: 1.0, timing: IslandRoomKeeper.curve)
        XCTAssertNotNil(host.island.shape.animation(forKey: "reveal"), "The shape is on its way to the smaller island.")
        // The island is put at its own size at once (a change of screen or settings while it moves): the old journey does not go on.
        stage.cancel()
        host.panel.setFrame(user, display: false)
        host.island.layoutSubtreeIfNeeded()
        host.island.reveal(host.island.bounds, radius: 22, duration: 0) {}
        XCTAssertNil(host.island.shape.animation(forKey: "reveal"))
        // A tenth of a second on, when the old journey (a second long) would be well on its way, what is on screen is still the island.
        settle(0.1)
        assertBox(host.island.shape.presentation()?.path?.boundingBox ?? .null, host.island.bounds, "What is on screen is the island, not where the old move was going.")
        settle(1.1)
        assertBox(shape(host), host.island.bounds)
    }

    func testAnIslandViewShowsAllOfItselfOnceLaidOutAndPinsWhatFillsIt() {
        let host = standIn()
        defer { host.panel.close() }
        XCTAssertTrue(host.island.showsAll, "Open and at rest, the shape is all of the view.")
        let filler = NSView(frame: host.island.bounds)
        filler.autoresizingMask = [.width, .height]
        host.island.addSubview(filler)
        let corner = NSView(frame: NSRect(x: 3, y: 4, width: 20, height: 20))
        corner.autoresizingMask = [.maxXMargin, .maxYMargin]
        host.island.addSubview(corner)
        // The window takes another size with nobody telling the shape or the view that fills it (what a late resize of the system would do), and the filler is out of step.
        host.panel.setFrame(host.screen.frame(of: CGSize(width: host.user.width + 48, height: host.user.height + 30)), display: false)
        filler.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        host.island.needsLayout = true
        host.island.layoutSubtreeIfNeeded()
        assertBox(shape(host), host.island.bounds, "The shape is all of the island again.")
        XCTAssertEqual(filler.frame, host.island.bounds, "What fills the island is exactly the island.")
        XCTAssertEqual(corner.frame, NSRect(x: 3, y: 4, width: 20, height: 20), "What is not meant to fill it is left alone.")
        // A shape that is not meant to be all of the view (the notch's size, a size it is on its way to) is left as it is.
        host.island.reveal(CGRect(x: 100, y: 100, width: 200, height: 40), radius: 10, duration: 0) {}
        XCTAssertFalse(host.island.showsAll)
        host.island.needsLayout = true
        host.island.layoutSubtreeIfNeeded()
        assertBox(shape(host), CGRect(x: 100, y: 100, width: 200, height: 40))
    }

    // MARK: The keeper

    private func keeper(_ host: StandIn) -> IslandRoomKeeper { IslandRoomKeeper(host: host) }

    func testAskedForRoomTheIslandGrowsOnceAndGoesBackExactlyWhenTheCardIsGone() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        let before = host.panel.frame
        XCTAssertEqual(before, host.screen.frame(of: host.user))
        XCTAssertNil(keeper.grown); XCTAssertEqual(keeper.size, host.user)

        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.15)
        let open = host.panel.frame
        XCTAssertEqual(keeper.grown, CGSize(width: host.user.width, height: 640))
        XCTAssertEqual(open, host.screen.frame(of: CGSize(width: host.user.width, height: 640)), "The window has the island's new size.")
        XCTAssertEqual(keeper.frame, open)
        XCTAssertEqual(open.maxY, before.maxY, "Hanging from the same top edge.")
        XCTAssertEqual(open.midX, before.midX, accuracy: 0.5, "On the same axis.")
        XCTAssertGreaterThan(host.changes, 0, "The content is told its size changed.")
        settle(0.5)
        assertBox(shape(host), host.island.bounds, "The shape has got to the whole of it.")

        // The card goes (Esc, «Cerrar», its tab, the panel): the island is the user's again, to the point.
        keeper.ask(nil, after: 0)
        settle(0.15)
        XCTAssertNil(keeper.grown, "Nothing is taken for the card any more.")
        settle(0.6)
        XCTAssertEqual(host.panel.frame, before, "After: exactly the frame it had before.")
        assertBox(shape(host), host.island.bounds)
        XCTAssertEqual(host.user, userSize(on: host.screen), "The user's own size is not touched.")
    }

    func testABurstOfAsksIsOneMoveToWhereTheyEndUp() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        // The card lays itself out in a few passes, and Nook reads the rest of Claude's panel by itself: asks come one after the other.
        for height in [300.0, 420, 510, 567] { keeper.ask(asks(CGFloat(height), island: host.user.width), after: 0.6) }
        settle(0.15)
        XCTAssertEqual(host.durations.count, 0, "Not before they have stopped.")
        settle(1.2)
        XCTAssertEqual(host.durations.count, 1, "One move.")
        XCTAssertEqual(keeper.grown?.height, 640, "…to the last of them.")
    }

    func testNothingMovesWhileTheIslandIsNotOnShowAndItMovesOnceItIs() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        let before = host.panel.frame
        host.mayMove = false
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.2)
        XCTAssertEqual(host.panel.frame, before, "The island opening, or a corner being dragged: it waits.")
        XCTAssertNil(keeper.grown)
        host.mayMove = true
        keeper.reconsider()
        settle(0.2)
        XCTAssertEqual(keeper.grown?.height, 640, "Asked about again, it takes the room.")
    }

    func testTheSameAskAgainMovesNothing() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.2)
        let moves = host.durations.count, frame = host.panel.frame
        keeper.ask(asks(567, island: host.user.width), after: 0)
        keeper.reconsider()
        settle(0.2)
        XCTAssertEqual(host.durations.count, moves, "It has settled: asked again, it stays.")
        XCTAssertEqual(host.panel.frame, frame)
    }

    func testReleaseGivesTheUsersSizeAtOnceWithNoMoveAndAsksAreTakenAgainOnlyWhenReconsidered() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.2)
        XCTAssertNotNil(keeper.grown)
        // The island is closing (or its screen or settings changed): the size is the user's from this instant, and the room asked for is not taken again by itself.
        let moves = host.durations.count
        keeper.release()
        XCTAssertNil(keeper.grown)
        XCTAssertEqual(keeper.size, host.user)
        settle(0.2)
        XCTAssertEqual(host.durations.count, moves, "No move.")
        XCTAssertNil(keeper.grown)
        keeper.reconsider()
        settle(0.2)
        XCTAssertEqual(keeper.grown?.height, 640, "The card is still asking: reconsidered, the island takes the room again.")
    }

    func testWithReduceMotionOrTheAnimationsOffTheIslandIsAtItsNewSizeAtOnce() {
        let host = standIn()
        defer { host.panel.close() }
        host.motion = false
        let keeper = keeper(host)
        let user = host.screen.frame(of: host.user)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.1)
        XCTAssertEqual(host.panel.frame.height, 640)
        assertBox(shape(host), host.island.bounds, "No animation: the shape is there already.")
        XCTAssertNil(host.island.shape.animation(forKey: "reveal"))
        keeper.ask(nil, after: 0)
        settle(0.1)
        XCTAssertEqual(host.panel.frame, user, "…and back to the user's own at once.")
        assertBox(shape(host), host.island.bounds)
    }

    func testAShortScreenCapsTheGrowthAndTheCardScrollsInsideIt() {
        let short = screen(width: 1440, height: 700, dock: 70, origin: CGPoint(x: -31512, y: -31000))
        let host = standIn(short)
        defer { host.panel.close() }
        let keeper = keeper(host)
        keeper.ask(asks(900, island: host.user.width), after: 0)
        settle(0.2)
        // It does not fit however it is laid out, and the island has columns of its own: it keeps its width and takes what the screen leaves, in one move.
        XCTAssertEqual(keeper.grown, CGSize(width: host.user.width, height: 618), "As tall as the screen leaves, and no wider than the user made it.")
        XCTAssertEqual(host.durations.count, 1)
        settle(0.5)
        let frame = host.panel.frame
        XCTAssertEqual(frame.maxY, short.frame.maxY, "From the top edge,")
        XCTAssertGreaterThanOrEqual(frame.minY, short.visible.minY + IslandGrowth.bottomMargin - 1, "…never lower than the Dock.")
        assertBox(shape(host), host.island.bounds)
        // The card goes: the user's own size, the exact frame.
        keeper.ask(nil, after: 0)
        settle(0.8)
        XCTAssertEqual(host.panel.frame, short.frame(of: host.user))
    }

    func testAnIslandTooNarrowForColumnsGoesWiderFirstAndThenTakesTheHeightWhileTheFirstMoveIsStillOn() {
        let short = screen(width: 1440, height: 760, dock: 70, origin: CGPoint(x: -31512, y: -31000))
        var narrow = DisplaySettings()
        narrow.widthExtra = -120
        let host = standIn(short, settings: narrow)
        defer { host.panel.close() }
        let keeper = keeper(host)
        let before = host.panel.frame
        keeper.ask(asks(700, island: host.user.width), after: 0)
        settle(0.15)
        // The window is wider at once, on the same axis and from the same top edge; the shape takes its time.
        XCTAssertEqual(keeper.grown, CGSize(width: IslandGrowth.wideWidth, height: host.user.height))
        XCTAssertEqual(host.panel.frame, short.frame(of: keeper.size))
        XCTAssertEqual(host.panel.frame.midX, before.midX, accuracy: 0.5)
        XCTAssertEqual(host.panel.frame.maxY, before.maxY)
        // The card, laid out at the new width, measures itself again before the shape has got there.
        keeper.ask(asks(560, island: IslandGrowth.wideWidth), after: 0)
        settle(0.15)
        XCTAssertEqual(keeper.grown, CGSize(width: IslandGrowth.wideWidth, height: 560 + 73))
        XCTAssertEqual(host.durations.count, 2)
        settle(0.9)
        XCTAssertEqual(host.panel.frame, short.frame(of: keeper.size), "Whichever move was on, the window ends as the island is.")
        assertBox(shape(host), host.island.bounds)
        // The card goes: the user's own, to the point.
        keeper.ask(nil, after: 0)
        settle(0.9)
        XCTAssertEqual(host.panel.frame, before)
        assertBox(shape(host), host.island.bounds)
    }

    func testTheKeeperLaysTheContentOutForWhatTheWindowReallyGot() {
        let host = standIn(limit: CGSize(width: 10_000, height: 500))
        defer { host.panel.close() }
        let keeper = keeper(host)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.2)
        // The card asked for 640 and the window took 500: the island is 500, and the content is laid out for that.
        XCTAssertEqual(keeper.grown?.height ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(keeper.size.height, host.panel.frame.height, accuracy: 0.5)
        XCTAssertEqual(keeper.frame?.height ?? 0, host.panel.frame.height, accuracy: 0.5)
        settle(0.9)
        assertBox(shape(host), host.island.bounds)
        XCTAssertEqual(keeper.verify(), [], "What it is and what it took are the same: nothing to mend.")
    }

    func testTheKeeperPutsTheIslandRightWhenItLooksAtItAfterAMove() {
        let host = standIn()
        defer { host.panel.close() }
        let keeper = keeper(host)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        settle(0.2)
        XCTAssertEqual(keeper.verify(), [], "While the move is on it is let be.")
        settle(0.9)
        XCTAssertEqual(host.panel.frame, host.screen.frame(of: keeper.size))
        let changes = host.changes
        // Something left the window narrower than the island is: looked at, it is put right and the content is told.
        let frame = host.panel.frame
        host.panel.setFrame(frame.insetBy(dx: 30, dy: 0), display: false)
        let repairs = keeper.verify()
        XCTAssertEqual(repairs.count, 1, "\(repairs)")
        XCTAssertEqual(host.panel.frame, frame)
        assertBox(shape(host), host.island.bounds)
        XCTAssertGreaterThan(host.changes, changes)
        XCTAssertEqual(keeper.verify(), [], "…and it stays.")
    }

    func testTheIslandIsLookedAtByItselfOnceAMoveIsOver() {
        let host = standIn()
        defer { host.panel.close() }
        host.motion = false
        let keeper = keeper(host)
        keeper.ask(asks(567, island: host.user.width), after: 0)
        // No animation: the move is over as it is made, and the look comes a little after. Break the window in between and it is mended with nobody asking.
        settle(0.1)
        let frame = host.panel.frame
        XCTAssertEqual(frame, host.screen.frame(of: keeper.size))
        host.panel.setFrame(frame.insetBy(dx: 20, dy: 0), display: false)
        let changes = host.changes
        settle(0.9)
        XCTAssertEqual(host.panel.frame, frame)
        assertBox(shape(host), host.island.bounds)
        XCTAssertGreaterThan(host.changes, changes, "The content is told what the island turned out to be.")
    }

    /// A day of asks that come at any moment, from any card height, in the middle of one another's moves and of the looks the keeper takes: at every stop the content is
    /// laid out for no more than the window has, and once things are quiet the window is the island's frame and the shape all of it.
    func testARandomDayOfAsksLeavesTheIslandWhereItShouldBeAtEveryStop() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ count: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(count))
        }
        let short = screen(width: 1512, height: 982, dock: 94, origin: CGPoint(x: -31512, y: -31000))
        for width in [CGFloat(452), 672] {
            let host = standIn(short, settings: { var settings = DisplaySettings(); settings.widthExtra = width - NotchGeometry.expandedWidth; return settings }())
            defer { host.panel.close() }
            let keeper = keeper(host)
            for step in 0..<40 {
                switch next(7) {
                case 0, 1, 2, 3:
                    // The card asks for room, at the width the island has now (a card laid out for another width has not measured itself yet and is not acted on).
                    keeper.ask(asks(CGFloat(120 + next(1000)), island: keeper.size.width), after: [0, 0.03, 0.08][next(3)])
                case 4: keeper.ask(nil, after: 0)
                case 5: keeper.reconsider()
                default: _ = keeper.verify()
                }
                settle([0.01, 0.04, 0.1, 0.25][next(4)])
                let window = host.panel.frame
                XCTAssertLessThanOrEqual(keeper.size.width, window.width + 0.5, "island \(Int(width)), step \(step): content wider than the window")
                XCTAssertLessThanOrEqual(keeper.size.height, window.height + 0.5, "island \(Int(width)), step \(step): content taller than the window")
                XCTAssertEqual(window.maxY, short.frame.maxY, "island \(Int(width)), step \(step): from the top edge")
                XCTAssertEqual(window.midX, short.centerX, accuracy: 0.5, "island \(Int(width)), step \(step): on the axis")
            }
            // Quiet: whatever the last ask was, the island is its frame and the shape is all of it.
            settle(1.6)
            XCTAssertEqual(host.panel.frame, host.screen.frame(of: keeper.size), "island \(Int(width)): the window is the island's frame")
            assertBox(shape(host), host.island.bounds, "island \(Int(width)): the shape is all of it")
            XCTAssertGreaterThanOrEqual(keeper.size.width, host.user.width); XCTAssertGreaterThanOrEqual(keeper.size.height, host.user.height)
            XCTAssertLessThanOrEqual(keeper.size.height, max(IslandGrowth.maxHeight(on: short), host.user.height))
            if width >= IslandGrowth.widenBelow { XCTAssertEqual(keeper.size.width, width, "island \(Int(width)): not widened") }
        }
    }

    // MARK: From the card to the island

    private func usageSession(_ model: AppModel, text: String, tty: String = "/dev/ttys097") -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        return TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
    }

    func testTheCardsAskGetsToTheIslandThroughThePanelAndIsTakenBackWithItsTab() throws {
        final class Asks { var rooms: [IslandRoom?] = [] }
        let asked = Asks()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-room-" + UUID().uuidString)!)
        model.neckWithoutWindow = 32
        let usage = usageSession(model, text: ClaudeUsageFixtures.terminal)
        let shell = TerminalSession(tab: TerminalTabSnapshot(windowID: 2, windowTitle: "t", index: 1, tty: "/dev/ttys098", customTitle: "", processes: ["login", "-zsh"], busy: false, selected: false, text: "developer % ls"),
                                    backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [usage, shell]; model.selectedID = usage.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNotNil(usage.panel, "The fixture is a Claude with its usage panel open.")
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: TabAgentListPresenter(), onRoom: { asked.rooms.append($0) }).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<5 { settle(0.3); if asked.rooms.contains(where: { $0 != nil }) { break } }
        let room = try XCTUnwrap(asked.rooms.compactMap { $0 }.last, "The card asked for room, through everything the panel puts around it.")
        XCTAssertEqual(room.width, ClaudePanelCard.width(inIsland: size.width), accuracy: 1, "…as measured at the width this island gives it.")
        XCTAssertGreaterThan(room.height, 400)
        // What it asks is what the island is given: the island of that height leaves the card that height.
        let wanted = IslandGrowth.size(for: room, now: size, user: size, screen: screen(notch: 32))
        XCTAssertEqual(ClaudePanelCard.height(inIsland: wanted.height, neck: 32), ceil(room.height), accuracy: 1)

        // Another tab, with no panel: the card is gone, and with it what it asked.
        model.select(shell)
        for _ in 0..<5 { settle(0.3); if asked.rooms.last! == nil { break } }
        XCTAssertNil(asked.rooms.last!, "Switching tabs takes the ask back: the island does not keep a size for a card that is not there.")
    }

    /// The whole loop, as the app runs it: the real panel in the island's window, its card's ask going to the keeper, the keeper moving the window and the shape, and the
    /// content laid out again for the island's new size. It has to settle in one step and stay, and go back exactly when the card goes.
    func testTheIslandSettlesInOneStepThroughTheRealPanelAndGoesBackWhenTheCardGoes() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-loop-" + UUID().uuidString)!)
        model.neckWithoutWindow = 32
        let usage = usageSession(model, text: ClaudeUsageFixtures.terminal)
        let shell = TerminalSession(tab: TerminalTabSnapshot(windowID: 2, windowTitle: "t", index: 1, tty: "/dev/ttys098", customTitle: "", processes: ["login", "-zsh"], busy: false, selected: false, text: "developer % ls"),
                                    backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [usage, shell]; model.selectedID = usage.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNotNil(usage.panel)
        let screen = screen(notch: 32, origin: CGPoint(x: -31512, y: -31000))
        let host = standIn(screen)
        defer { host.panel.close() }
        let user = host.user
        let userFrame = host.panel.frame
        XCTAssertEqual(model.islandSize, user, "The panel lays itself out for the user's size to begin with.")
        let keeper = keeper(host)
        // What `AppModel.islandSize` answers in the app (the controller's frame) is, here, the settings that give exactly the keeper's size.
        host.onChange = {
            var display = model.display
            display.widthExtra = keeper.size.width - NotchGeometry.expandedWidth
            display.heightExtra = keeper.size.height - NotchGeometry.expandedHeight(topInset: 32)
            model.display = display
        }
        let content = NSHostingView(rootView: NookPanel(model: model, agentList: TabAgentListPresenter(), onRoom: { keeper.ask($0) }).environment(\.nookTintedGlass, false))
        content.sizingOptions = []
        content.autoresizingMask = [.width, .height]
        content.frame = host.island.bounds
        host.island.addSubview(content)

        // The card is drawn, says how tall it wants to be, and the island takes that: one move.
        settle(1.6)
        XCTAssertEqual(host.durations.count, 1, "One move, not a step and then another: what the card asks does not depend on the room it has.")
        let grown = try XCTUnwrap(keeper.grown, "The island took the room the card asked for.")
        XCTAssertEqual(grown.width, user.width)
        XCTAssertGreaterThan(grown.height, user.height + 200)
        XCTAssertEqual(host.panel.frame, screen.frame(of: grown), "The window is the island's new size, hanging from the same top edge.")
        XCTAssertEqual(host.panel.frame.maxY, userFrame.maxY)
        XCTAssertEqual(model.islandSize, grown, "…and the panel is laid out for it.")
        // The card, in the island that has its room, asks for the same: nothing moves again.
        settle(1.2)
        XCTAssertEqual(host.durations.count, 1, "It stays: no oscillation.")
        XCTAssertEqual(keeper.grown, grown)
        let fitted = ClaudePanelCard.height(inIsland: grown.height, neck: 32)
        XCTAssertGreaterThanOrEqual(fitted, 400)

        // Its tab goes (a tab with no panel): the island is the user's again, to the point.
        model.select(shell)
        settle(1.6)
        XCTAssertNil(keeper.grown)
        XCTAssertEqual(host.durations.count, 2, "One move back.")
        XCTAssertEqual(host.panel.frame, userFrame, "Exactly the frame it had before the card.")
        XCTAssertEqual(model.islandSize, user)
        // …and coming back to the tab with the card takes the room again, in one move.
        model.select(usage)
        settle(1.6)
        XCTAssertEqual(host.durations.count, 3)
        XCTAssertEqual(keeper.grown, grown, "The same size as the first time.")
    }

    func testAPanelThatIsNotTheUsageCardAsksForNothing() throws {
        final class Asks { var rooms: [IslandRoom?] = [] }
        let asked = Asks()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-room-" + UUID().uuidString)!)
        let list = usageSession(model, text: ClaudePanelFixtures.screen(ClaudePanelFixtures.list))
        model.sessions = [list]; model.selectedID = list.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNotNil(list.panel)
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: TabAgentListPresenter(), onRoom: { asked.rooms.append($0) }).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        settle(1.0)
        XCTAssertTrue(asked.rooms.compactMap { $0 }.isEmpty, "A list or a status panel scrolls in the island it has.")
    }

    /// The panel is laid out for the window it is in: a window narrower than the island the model has (a window not yet given its new width) cuts nothing, because the
    /// card is made for the width there is.
    func testThePanelNeverLaysItsContentOutWiderThanTheWindowItIsIn() throws {
        final class Asks { var rooms: [IslandRoom?] = [] }
        let asked = Asks()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-narrow-" + UUID().uuidString)!)
        model.neckWithoutWindow = 32
        var display = DisplaySettings()
        display.widthExtra = 148
        model.display = display
        let usage = usageSession(model, text: ClaudeUsageFixtures.terminal)
        model.sessions = [usage]; model.selectedID = usage.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertEqual(model.islandSize.width, 720, "The model's island is the wide one.")
        let host = NSHostingView(rootView: NookPanel(model: model, agentList: TabAgentListPresenter(), onRoom: { asked.rooms.append($0) }).environment(\.nookTintedGlass, false))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: model.islandSize.height)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: model.islandSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<6 { settle(0.3); if asked.rooms.contains(where: { $0 != nil }) { break } }
        let room = try XCTUnwrap(asked.rooms.compactMap { $0 }.last)
        XCTAssertEqual(room.width, ClaudePanelCard.width(inIsland: 600), accuracy: 1, "Laid out for the 600 pt there are, not the 720 the island was meant to have.")
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// What the usage card asks, drawn as the island hosts it, at this width.
    private func ask(of text: String, island width: CGFloat, chat: Double = 11) throws -> IslandRoom {
        final class Box { var room: IslandRoom? }
        struct Probe: View {
            var text: String
            var width: CGFloat
            var chat: Double
            var box: Box
            var body: some View {
                ClaudePanelCard(text: text, fontSize: chat, growsIsland: true).frame(width: width, height: 300).padding(15)
                    .background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                    .onPreferenceChange(IslandRoomKey.self) { box.room = $0 }
            }
        }
        let box = Box()
        let host = NSHostingView(rootView: Probe(text: text, width: ClaudePanelCard.width(inIsland: width), chat: chat, box: box))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 330)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: 330), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<4 {
            settle(0.25)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            if box.room != nil { break }
        }
        return try XCTUnwrap(box.room)
    }

    private func save<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            settle(0.4)
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The whole island as the app draws it with Sample's /usage open, at the size the island takes for it: what the card asks of it at the user's width, turned into
    /// the island's size the way the keeper does, and the island drawn at that size. Both of Sample's screens, at the usual island and at the wide one, and at a bigger text.
    func testRenderTheIslandGrownForTheUsageCard() throws {
        let directory = try renderDirectory()
        let screen = screen(notch: 32)
        for (name, text) in [("terminal", ClaudeUsageFixtures.terminal), ("whole", ClaudeUsageFixtures.whole)] {
            for (preset, chat) in [(IslandPreset.normal, 11.0), (.normal, 14.0), (.wide, 11.0), (.compact, 11.0)] {
                var display = DisplaySettings().applying(preset)
                display.chatSize = chat
                let user = userSize(display, on: screen)
                // Two steps at most, as in the app: what the card asks at this width, then at the width the island took.
                var now = user
                for _ in 0..<2 {
                    let room = try ask(of: try XCTUnwrap(ClaudeComposer.split(text).panel), island: now.width, chat: chat)
                    let next = IslandGrowth.size(for: room, now: now, user: user, screen: screen)
                    if next == now { break }
                    now = next
                }
                let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-grown-" + UUID().uuidString)!)
                model.neckWithoutWindow = 32
                // The island at the size it took: the settings' offsets that give exactly that size (the app gives the content that size through `islandSize`).
                display.widthExtra = now.width - NotchGeometry.expandedWidth
                display.heightExtra = now.height - NotchGeometry.expandedHeight(topInset: 32)
                model.display = display
                let session = usageSession(model, text: text)
                model.sessions = [session]; model.selectedID = session.id
                model.expanded = true; model.islandContentVisible = true
                model.updateActivity()
                XCTAssertEqual(model.islandSize.height, now.height, accuracy: 0.5)
                let label = "\(name)-\(preset.rawValue)-chat\(Int(chat))"
                try save(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: model.islandSize,
                         to: URL(fileURLWithPath: directory).appendingPathComponent("grown-\(label).png").path)
                print("GROWN \(label): user \(Int(user.width))x\(Int(user.height)) → island \(Int(now.width))x\(Int(now.height))")
            }
        }
    }

    /// The island on a short screen with the Dock out: it takes what the screen leaves, and the card scrolls inside it with its last row fading.
    func testRenderTheIslandGrownAsFarAsAShortScreenAllows() throws {
        let directory = try renderDirectory()
        let short = screen(width: 1440, height: 700, dock: 70, notch: 32)
        var display = DisplaySettings()
        let user = userSize(display, on: short)
        let text = ClaudeUsageFixtures.whole
        var now = user
        for _ in 0..<2 {
            let room = try ask(of: try XCTUnwrap(ClaudeComposer.split(text).panel), island: now.width)
            let next = IslandGrowth.size(for: room, now: now, user: user, screen: short)
            if next == now { break }
            now = next
        }
        display.widthExtra = now.width - NotchGeometry.expandedWidth
        display.heightExtra = now.height - NotchGeometry.expandedHeight(topInset: 32)
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-island-short-" + UUID().uuidString)!)
        model.neckWithoutWindow = 32
        model.display = display
        let session = usageSession(model, text: text)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        try save(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: model.islandSize,
                 to: URL(fileURLWithPath: directory).appendingPathComponent("grown-short-screen.png").path)
        print("GROWN short screen: island \(Int(now.width))x\(Int(now.height)) on a 1440x700 screen with a 70 pt Dock")
    }
}
