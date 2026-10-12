import XCTest
@testable import Nook

/// The arithmetic of dragging a tab along the strip (`TabStrip.swift`): where the tabs stand, when the carried one passes a neighbour, how far the others move aside, where it settles and
/// when the strip scrolls. Plain numbers, checked without a window.
final class TabStripTests: XCTestCase {
    private let gap = TabStrip.spacing

    func testTabsStandSideBySide() {
        XCTAssertEqual(TabStrip.origins(of: [100, 80, 60]), [0, 100 + gap, 100 + gap + 80 + gap])
        XCTAssertEqual(TabStrip.contentWidth(of: [100, 80, 60]), 100 + 80 + 60 + 2 * gap)
        XCTAssertEqual(TabStrip.contentWidth(of: []), 0)
        XCTAssertEqual(TabStrip.contentWidth(of: [90]), 90)
    }

    func testMovedPutsATabInAnotherPlace() {
        XCTAssertEqual(TabStrip.moved(["a", "b", "c", "d"], from: 0, to: 2), ["b", "c", "a", "d"])
        XCTAssertEqual(TabStrip.moved(["a", "b", "c", "d"], from: 3, to: 1), ["a", "d", "b", "c"])
        XCTAssertEqual(TabStrip.moved(["a", "b"], from: 1, to: 1), ["a", "b"])
        XCTAssertEqual(TabStrip.moved(["a", "b"], from: 5, to: 0), ["a", "b"], "a place that is not there changes nothing")
    }

    // MARK: Passing a neighbour

    /// A tab passes its neighbour once its leading edge has crossed that neighbour's middle: right edge going right, left edge going left.
    func testTheCarriedTabPassesANeighbourAtItsMiddle() {
        let widths: [CGFloat] = [100, 100, 100]
        // The middle tab, carried right: the one to its right has its middle at 106 + 106 + 50 = 262; the carried tab's right edge (minX + 100) reaches it at minX 162.
        XCTAssertEqual(TabStrip.target(of: 1, minX: 106, widths: widths), 1, "where it stands, it stays")
        XCTAssertEqual(TabStrip.target(of: 1, minX: 150, widths: widths), 1)
        XCTAssertEqual(TabStrip.target(of: 1, minX: 163, widths: widths), 2)
        // Carried left: the one to its left has its middle at 50; the left edge reaches it at 50.
        XCTAssertEqual(TabStrip.target(of: 1, minX: 60, widths: widths), 1)
        XCTAssertEqual(TabStrip.target(of: 1, minX: 49, widths: widths), 0)
    }

    func testItCanPassSeveralInOneMove() {
        let widths: [CGFloat] = [100, 100, 100, 100]
        XCTAssertEqual(TabStrip.target(of: 0, minX: 400, widths: widths), 3, "dragged to the far end")
        XCTAssertEqual(TabStrip.target(of: 3, minX: -50, widths: widths), 0, "and back to the start")
        XCTAssertEqual(TabStrip.target(of: 0, minX: 0, widths: widths), 0)
    }

    /// After a swap, going back needs the carried tab to cross the middle of the tab it passed, which has moved into the carried tab's old place: the two thresholds are not the same
    /// point (the spacing between the tabs is the difference), so a tab held still between two places does not flicker between them.
    func testThereIsRoomBetweenSwappingAndSwappingBack() {
        let widths: [CGFloat] = [100, 100, 100]
        // Carried from the middle to the right: swapped at minX > 162.
        let forward = (100...260).first { TabStrip.target(of: 1, minX: CGFloat($0), widths: widths) == 2 }
        XCTAssertEqual(forward, 163)
        // Now it is third (order a, c, b); the one it passed (c) stands second, with its middle at 106 + 50 = 156: back is minX < 156.
        let order: [CGFloat] = [100, 100, 100]
        let backAt = stride(from: 260, through: 100, by: -1).first { TabStrip.target(of: 2, minX: CGFloat($0), widths: order) == 1 }
        XCTAssertEqual(backAt, 155)
        XCTAssertGreaterThan(forward! - backAt!, 6, "a gap of at least the spacing")
    }

    func testTabsOfDifferentWidthsPassAtTheirOwnMiddles() {
        let widths: [CGFloat] = [60, 180, 60]
        // The second, wide tab carried left: the first tab's middle is at 30.
        XCTAssertEqual(TabStrip.target(of: 1, minX: 31, widths: widths), 1)
        XCTAssertEqual(TabStrip.target(of: 1, minX: 29, widths: widths), 0)
        // Carried right: the third tab starts at 60 + 6 + 180 + 6 = 252 and its middle is at 282; the carried tab's right edge is minX + 180.
        XCTAssertEqual(TabStrip.target(of: 1, minX: 100, widths: widths), 1)
        XCTAssertEqual(TabStrip.target(of: 1, minX: 103, widths: widths), 2)
    }

    func testAnIndexThatIsNotThereMovesNothing() {
        XCTAssertEqual(TabStrip.target(of: 7, minX: 0, widths: [100, 100]), 7)
        XCTAssertEqual(TabStrip.target(of: 0, minX: 300, widths: [100]), 0, "a lone tab has nowhere to go")
    }

    // MARK: Moving the others aside

    func testTheTabsItPassedMoveAsideByItsWidth() {
        let widths: [CGFloat] = [100, 80, 60, 120]
        // The first tab carried to the third place: the second and third move left by its width and the gap.
        XCTAssertEqual(TabStrip.shifts(widths: widths, from: 0, to: 2), [0, -(100 + gap), -(100 + gap), 0])
        // The last tab carried to the second place: the second and third move right by its width and the gap.
        XCTAssertEqual(TabStrip.shifts(widths: widths, from: 3, to: 1), [0, 120 + gap, 120 + gap, 0])
        XCTAssertEqual(TabStrip.shifts(widths: widths, from: 2, to: 2), [0, 0, 0, 0])
        XCTAssertEqual(TabStrip.shifts(widths: widths, from: 9, to: 2), [0, 0, 0, 0])
    }

    /// The shifts say where every tab stands in the new order: laid out where they are, plus their shift, they are where `moved` puts them.
    func testShiftsPlaceEveryTabWhereTheNewOrderPutsIt() {
        let widths: [CGFloat] = [100, 80, 60, 120, 90]
        for from in widths.indices {
            for to in widths.indices {
                let shifts = TabStrip.shifts(widths: widths, from: from, to: to)
                let origins = TabStrip.origins(of: widths)
                let newOrder = TabStrip.moved(Array(widths.indices), from: from, to: to)
                let newOrigins = TabStrip.origins(of: newOrder.map { widths[$0] })
                for (place, tab) in newOrder.enumerated() where tab != from {
                    XCTAssertEqual(origins[tab] + shifts[tab], newOrigins[place], accuracy: 1e-9, "tab \(tab) of a move \(from) → \(to)")
                }
                XCTAssertEqual(origins[from] + TabStrip.slot(widths: widths, from: from, to: to), newOrigins[to], accuracy: 1e-9, "the carried tab's slot, \(from) → \(to)")
            }
        }
    }

    func testTheSlotIsWhereTheCarriedTabSettles() {
        XCTAssertEqual(TabStrip.slot(widths: [100, 80, 60], from: 0, to: 2), 80 + gap + 60 + gap)
        XCTAssertEqual(TabStrip.slot(widths: [100, 80, 60], from: 2, to: 0), -(100 + gap + 80 + gap))
        XCTAssertEqual(TabStrip.slot(widths: [100, 80, 60], from: 1, to: 1), 0)
    }

    // MARK: Keeping it in

    func testTheCarriedTabStaysInsideTheStrip() {
        XCTAssertEqual(TabStrip.clamped(minX: -40, width: 90, content: 400), 0)
        XCTAssertEqual(TabStrip.clamped(minX: 380, width: 90, content: 400), 310)
        XCTAssertEqual(TabStrip.clamped(minX: 120, width: 90, content: 400), 120)
        XCTAssertEqual(TabStrip.clamped(minX: 50, width: 90, content: 60), 0, "a strip narrower than the tab")
    }

    func testTheStripScrollsTowardTabsBeyondTheEdgeOnlyWhereThereAreSome() {
        func direction(_ leading: CGFloat, _ trailing: CGFloat, back: Bool = true, forward: Bool = true) -> Int {
            TabStrip.scrollDirection(leading: leading, trailing: trailing, viewport: 400, canScrollBack: back, canScrollForward: forward)
        }
        XCTAssertEqual(direction(150, 250), 0, "in the middle it does not scroll")
        XCTAssertEqual(direction(10, 110), -1, "at the start edge, toward the start")
        XCTAssertEqual(direction(300, 395), 1, "at the end edge, toward the end")
        XCTAssertEqual(direction(10, 110, back: false), 0, "nothing hidden at the start")
        XCTAssertEqual(direction(300, 395, forward: false), 0, "nothing hidden at the end")
        XCTAssertEqual(direction(40, 140), 0, "just outside the zone")
    }

    func testTheCarryRemembersWhereItWasPickedUp() {
        var carry = TabCarry(id: "a", from: 1, to: 1, grab: 12, minX: 100, pointer: 140)
        XCTAssertFalse(carry.released)
        carry.to = 3
        carry.released = true
        XCTAssertEqual(carry.from, 1)
        XCTAssertEqual(carry, TabCarry(id: "a", from: 1, to: 3, grab: 12, minX: 100, pointer: 140, released: true))
    }
}
