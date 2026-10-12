import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The effort control: Claude's levels, the chip that shows the one it reported, the keys that walk the picker, and the draft that
/// opens it.
@MainActor
final class EffortControlTests: XCTestCase {
    func testTheLevelsKeepClaudesOrderAndEachHasItsOwnName() {
        XCTAssertEqual(ClaudeEffort.allCases, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(ClaudeEffort.allCases.map(\.title), ["Bajo", "Medio", "Alto", "Muy alto", "Máximo"])
        XCTAssertEqual(Set(ClaudeEffort.allCases.map(\.title)).count, 5)
        XCTAssertTrue(ClaudeEffort.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    func testTheLevelsAreFiveStepsOfTheRing() {
        XCTAssertEqual(ClaudeEffort.allCases.map(\.steps), [1, 2, 3, 4, 5])
    }

    func testTheKeysWalkTheLevelsAndStopAtTheEnds() {
        XCTAssertEqual(EffortPickerKey.moved(from: .high, by: .down), .xhigh)
        XCTAssertEqual(EffortPickerKey.moved(from: .high, by: .right), .xhigh)
        XCTAssertEqual(EffortPickerKey.moved(from: .high, by: .tab), .xhigh)
        XCTAssertEqual(EffortPickerKey.moved(from: .high, by: .up), .medium)
        XCTAssertEqual(EffortPickerKey.moved(from: .max, by: .down), .max, "No wrapping round.")
        XCTAssertEqual(EffortPickerKey.moved(from: .low, by: .up), .low)
        for key in [ComposerKey.submit, .escape, .newline, .pasteImage] { XCTAssertNil(EffortPickerKey.moved(from: .high, by: key), "\(key) does not walk.") }
    }

    func testOnlyAPlainEffortOpensTheLevels() {
        for draft in ["/effort", " /effort ", "/effort\n", "\n/effort"] { XCTAssertTrue(EffortPickerKey.asksForTheLevels(draft), draft.debugDescription) }
        // A level given is Claude's own command and goes as it is; anything else is a message.
        for draft in ["/effort high", "/effort max", "/effortful", "/Effort", "effort", "dime /effort", "/effort?", ""] {
            XCTAssertFalse(EffortPickerKey.asksForTheLevels(draft), draft.debugDescription)
        }
    }

    func testTheSymbolsAreImagesTheSystemHas() {
        for name in [UsageButton.symbol, "xmark"] { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
    }

    func testTheChipIsASymbolInARoundChipWhateverTheLevelAndWhetherItIsKnown() {
        for effort in ClaudeEffort.allCases + [nil] {
            let size = NSHostingView(rootView: EffortChip(effort: effort) {}).fittingSize
            XCTAssertEqual(size.width, 24, accuracy: 0.5, "\(String(describing: effort)): \(size)")
            XCTAssertEqual(size.height, 24, accuracy: 0.5)
        }
    }

    func testThePickerFitsTheComposersRowAlongsideItsButtons() {
        // The row is 523 pt of text in the Normal island and 451 in the Compact one; the three buttons and their gaps take about 110.
        func row(named: Bool) -> EffortRow { EffortRow(named: named, current: .high, highlighted: .high, onPick: { _ in }, onClose: {}) }
        let named = NSHostingView(rootView: row(named: true)).fittingSize
        let bare = NSHostingView(rootView: row(named: false)).fittingSize
        XCTAssertEqual(named.height, 24); XCTAssertEqual(bare.height, 24)
        XCTAssertLessThan(named.width, 523 - 110, "With its word, in the Normal island. \(named)")
        XCTAssertLessThan(bare.width, 451 - 110, "Without it, all five levels still fit the Compact island. \(bare)")
        XCTAssertLessThan(bare.width, named.width)
    }

    // MARK: Motion

    func testTheLevelsUnfoldWithMotionAndJustSwapWithoutIt() {
        for opening in [true, false] {
            XCTAssertNotNil(EffortMotion.animation(opening: opening, reduceMotion: false, animationsOn: true), "Opening: \(opening).")
            XCTAssertNil(EffortMotion.animation(opening: opening, reduceMotion: true, animationsOn: true), "Reduce Motion asks for none.")
            XCTAssertNil(EffortMotion.animation(opening: opening, reduceMotion: false, animationsOn: false), "The app's animations switched off ask for none.")
            XCTAssertNil(EffortMotion.animation(opening: opening, reduceMotion: true, animationsOn: false))
        }
    }

    func testTheMotionIsShortAndClosingIsQuickerThanOpening() {
        XCTAssertLessThanOrEqual(EffortMotion.openingDuration, 0.3)
        XCTAssertLessThan(EffortMotion.closingDuration, EffortMotion.openingDuration)
        XCTAssertGreaterThanOrEqual(EffortMotion.closingDuration, 0.12, "Long enough to be seen as folding away.")
    }

    func testTheItemsRiseInTurnFromTheChipsSide() {
        // Six items without the word that says what the levels are (the ✕ and the five levels), seven with it.
        for count in [6, 7] {
            for item in 0..<count {
                XCTAssertEqual(EffortMotion.arrival(of: item, of: count, at: 0), 0, "None has begun at the start.")
                XCTAssertEqual(EffortMotion.arrival(of: item, of: count, at: 1), 1, "All are in place at the end, the last one just then.")
            }
            let steps = Array(stride(from: 0.0, through: 1.0, by: 0.05))
            for progress in steps {
                let arrivals = (0..<count).map { EffortMotion.arrival(of: $0, of: count, at: progress) }
                XCTAssertEqual(arrivals, arrivals.sorted(by: >), "The item beside the chip leads and the rest follow in order (at \(progress)).")
            }
            for item in 0..<count {
                let along = steps.map { EffortMotion.arrival(of: item, of: count, at: $0) }
                XCTAssertEqual(along, along.sorted(), "Item \(item) only moves forward as the whole does.")
            }
            // Folding back is the same run backwards: the item that came last goes first.
            let late = EffortMotion.arrival(of: count - 1, of: count, at: 0.4), early = EffortMotion.arrival(of: 0, of: count, at: 0.4)
            XCTAssertLessThan(late, early)
        }
    }

    func testAnItemSettlesIntoItsPlaceWithoutOvershooting() {
        for item in 0..<7 {
            for progress in stride(from: 0.0, through: 1.0, by: 0.01) {
                let arrived = EffortMotion.arrival(of: item, of: 7, at: progress)
                XCTAssertTrue((0...1).contains(arrived), "Item \(item) at \(progress): \(arrived)")
            }
        }
        XCTAssertLessThanOrEqual(EffortMotion.travel, 12, "A few points, not a slide across the row.")
    }

    func testTheStatusLineAndChipsMakeWayBeforeTheLowestLevelsRiseOverThem() {
        XCTAssertEqual(EffortMotion.closedOpacity(at: 0), 1, "Shut, all of it shows.")
        XCTAssertEqual(EffortMotion.closedOpacity(at: 1), 0, "Open, none of it.")
        let steps = Array(stride(from: 0.0, through: 1.0, by: 0.02))
        let along = steps.map { EffortMotion.closedOpacity(at: $0) }
        XCTAssertEqual(along, along.sorted(by: >), "It only goes out as the levels come in, and only comes back as they go.")
        XCTAssertTrue(along.allSatisfy { (0...1).contains($0) })
        // With seven items (the word, the five levels and the ✕) the status line is on the left, under the word and the lowest levels, which are
        // the last to rise; it has to be gone by the time the third from last begins.
        let thirdFromLast = 7 - 3
        XCTAssertLessThan(EffortMotion.closedOpacity(at: EffortMotion.stagger * Double(thirdFromLast)), 0.02)
        XCTAssertEqual(EffortMotion.arrival(of: thirdFromLast, of: 7, at: EffortMotion.stagger * Double(thirdFromLast)), 0, "It has not begun yet.")
    }

    /// Where things stand in a row like the composer's: the swap, then the three buttons beside it (circles standing in for them).
    private final class RowFrames {
        var swap: CGRect?, beside: CGRect?, closed: CGRect?, levels: CGRect?
    }

    private struct SwapRow: View {
        var showsLevels: Bool
        var animated: Bool
        var frames: RowFrames
        var body: some View {
            HStack(spacing: 10) {
                EffortSwap(showsLevels: showsLevels, reduceMotion: !animated, animationsOn: true) {
                    HStack(spacing: 10) {
                        Text("Claude · en vivo · ↵ enviar").font(.system(size: 10.5)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 6) {
                            EffortChip(effort: .high) {}
                            UsageButton {}
                        }.layoutPriority(1)
                    }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.closed = $0 }
                } levels: {
                    EffortPicker(current: .high, highlighted: .high, onPick: { _ in }, onClose: {})
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.levels = $0 }
                }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.swap = $0 }
                HStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 28, height: 28) } }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.beside = $0 }
            }.padding(.leading, 13).padding(.trailing, 6).frame(width: 560, height: 36)
        }
    }

    private func lay(showsLevels: Bool, animated: Bool) -> RowFrames {
        let frames = RowFrames()
        let host = NSHostingView(rootView: SwapRow(showsLevels: showsLevels, animated: animated, frames: frames))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 36)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        withExtendedLifetime(window) {}
        return frames
    }

    func testTheKeysAndSendStayWhereTheyAreWhileTheLevelsTakeTheStatusLinesPlace() throws {
        // The row leaves the swap everything but the three buttons (28 each, 6 apart), the gap before them and its own padding.
        let buttons: CGFloat = 3 * 28 + 2 * 6
        let expectedWidth: CGFloat = 560 - 13 - 6 - 10 - buttons
        for animated in [true, false] {
            let shut = lay(showsLevels: false, animated: animated), open = lay(showsLevels: true, animated: animated)
            let shutSwap = try XCTUnwrap(shut.swap), openSwap = try XCTUnwrap(open.swap)
            let shutBeside = try XCTUnwrap(shut.beside), openBeside = try XCTUnwrap(open.beside)
            let closed = try XCTUnwrap(shut.closed), levels = try XCTUnwrap(open.levels)
            // Whichever shows, the frame they stand in and what stands beside it are the same, so nothing hops as they swap.
            XCTAssertEqual(shutSwap, openSwap, "animated: \(animated)")
            XCTAssertEqual(shutBeside, openBeside, "animated: \(animated)")
            XCTAssertEqual(openSwap.width, expectedWidth, accuracy: 0.5)
            // Each side is where it should be: the status line and the chips when shut, the levels (from the left edge) when open.
            XCTAssertNil(shut.levels)
            XCTAssertNil(open.closed)
            XCTAssertEqual(levels.minX, openSwap.minX, accuracy: 0.5)
            XCTAssertLessThanOrEqual(levels.maxX, openSwap.maxX + 0.5)
            XCTAssertEqual(closed.maxX, shutSwap.maxX, accuracy: 0.5, "The chips stand at the swap's right edge, as they did.")
        }
    }

    // MARK: The move itself

    private final class Switch: ObservableObject { @Published var open = false }

    private final class Seen {
        var unfold: [Double] = []
        var levelsMounted = false, closedMounted = false
    }

    /// Reads the progress the items are given, and says whether it is mounted.
    private struct LevelsProbe: View {
        var seen: Seen
        @Environment(\.effortUnfold) private var unfold
        var body: some View {
            seen.unfold.append(unfold)
            return Color.clear.frame(width: 40, height: 24).onAppear { seen.levelsMounted = true }.onDisappear { seen.levelsMounted = false }
        }
    }

    private struct MotionRow: View {
        @ObservedObject var model: Switch
        var reduceMotion: Bool
        var animationsOn: Bool
        var seen: Seen
        var body: some View {
            EffortSwap(showsLevels: model.open, reduceMotion: reduceMotion, animationsOn: animationsOn) {
                Color.clear.frame(width: 40, height: 24).onAppear { seen.closedMounted = true }.onDisappear { seen.closedMounted = false }
            } levels: {
                LevelsProbe(seen: seen)
            }.frame(width: 300, height: 24)
        }
    }

    /// Flips the row (starting open or shut) and watches it: the progress the items were given afterwards, and what was mounted a little
    /// into the move and when it was over.
    private func watch(startingOpen: Bool, reduceMotion: Bool = false, animationsOn: Bool = true) -> (seen: [Double], midway: (levels: Bool, closed: Bool), end: (levels: Bool, closed: Bool)) {
        let model = Switch()
        model.open = startingOpen
        let seen = Seen()
        let host = NSHostingView(rootView: MotionRow(model: model, reduceMotion: reduceMotion, animationsOn: animationsOn, seen: seen))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        seen.unfold.removeAll()
        model.open = !startingOpen
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let midway = (levels: seen.levelsMounted, closed: seen.closedMounted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let end = (levels: seen.levelsMounted, closed: seen.closedMounted)
        withExtendedLifetime(window) {}
        return (seen.unfold, midway, end)
    }

    func testTheLevelsUnfoldStepByStepAndTheStatusLineStaysUntilTheyAreOut() {
        let opening = watch(startingOpen: false)
        // Every step of the move reached the items, in order, from 0 to 1.
        XCTAssertTrue(opening.seen.contains { $0 > 0.15 && $0 < 0.85 }, "Steps in between: \(opening.seen.count) values.")
        XCTAssertEqual(opening.seen, opening.seen.sorted(), "It only goes forward.")
        XCTAssertEqual(opening.seen.last, 1)
        // Both sides are in the row while it moves; once it is over only the levels are.
        XCTAssertTrue(opening.midway.levels && opening.midway.closed, "Both stand in the row while the levels come in.")
        XCTAssertTrue(opening.end.levels)
        XCTAssertFalse(opening.end.closed, "Open, the row has no chip.")
    }

    func testTheLevelsFoldBackTheSameWay() {
        let closing = watch(startingOpen: true)
        XCTAssertTrue(closing.seen.contains { $0 > 0.15 && $0 < 0.85 }, "Steps in between: \(closing.seen.count) values.")
        XCTAssertEqual(closing.seen, closing.seen.sorted(by: >), "It only goes back.")
        XCTAssertEqual(closing.seen.last, 0)
        XCTAssertTrue(closing.midway.levels && closing.midway.closed)
        XCTAssertFalse(closing.end.levels, "Shut, the row has no levels in it.")
        XCTAssertTrue(closing.end.closed)
    }

    func testWithReduceMotionOrTheAnimationsOffTheRowJustSwaps() {
        for (reduceMotion, animationsOn) in [(true, true), (false, false), (true, false)] {
            for startingOpen in [false, true] {
                let swap = watch(startingOpen: startingOpen, reduceMotion: reduceMotion, animationsOn: animationsOn)
                let rested = startingOpen ? 0.0 : 1.0
                XCTAssertTrue(swap.seen.allSatisfy { $0 == rested }, "Nothing between the two ends (reduce motion \(reduceMotion), animations \(animationsOn), starting open \(startingOpen)): \(swap.seen)")
                XCTAssertEqual(swap.midway.levels, !startingOpen)
                XCTAssertEqual(swap.midway.closed, startingOpen, "Even 0.1 s in, only one side stands in the row.")
                XCTAssertEqual(swap.end.levels, !startingOpen)
                XCTAssertEqual(swap.end.closed, startingOpen)
            }
        }
    }
}
