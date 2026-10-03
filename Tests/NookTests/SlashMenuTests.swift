import XCTest
@testable import Nook

final class SlashMenuTests: XCTestCase {
    private func commands(_ count: Int) -> [SlashCommand] { (0..<count).map { SlashCommand(name: "cmd\($0)") } }

    private func menu(_ count: Int) -> SlashMenuState {
        var state = SlashMenuState()
        state.update(commands(count))
        return state
    }

    func testTheMenuShowsOnlyWhileThereAreMatchesAndItWasNotClosed() {
        var state = SlashMenuState()
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.current)
        state.update(commands(3))
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.current?.name, "cmd0")
        XCTAssertEqual(state.press(.escape), .handled)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.current)
        state.update(commands(3))
        XCTAssertTrue(state.isVisible, "A new draft brings the menu back.")
        state.update([])
        XCTAssertFalse(state.isVisible)
    }

    func testKeysAreLeftToTheFieldWhileTheMenuIsHidden() {
        var state = SlashMenuState()
        for key in [SlashMenuState.Key.up, .down, .tab, .enter, .escape] { XCTAssertEqual(state.press(key), .ignored) }
        state.update(commands(2))
        _ = state.press(.escape)
        for key in [SlashMenuState.Key.up, .down, .tab, .enter, .escape] { XCTAssertEqual(state.press(key), .ignored, "Closed with Esc: the keys are the field's again.") }
    }

    func testArrowsMoveTheHighlightAndWrapAround() {
        var state = menu(3)
        XCTAssertEqual(state.highlighted, 0)
        XCTAssertEqual(state.press(.down), .handled)
        XCTAssertEqual(state.highlighted, 1)
        _ = state.press(.down); _ = state.press(.down)
        XCTAssertEqual(state.highlighted, 0, "Past the last row it wraps to the first.")
        _ = state.press(.up)
        XCTAssertEqual(state.highlighted, 2, "Before the first it wraps to the last.")
        var single = menu(1)
        XCTAssertEqual(single.press(.down), .handled, "With one row the arrows still belong to the menu.")
        XCTAssertEqual(single.highlighted, 0)
    }

    func testTabFillsWithATrailingSpaceAndEnterSendsTheBareCommand() {
        var state = menu(3)
        _ = state.press(.down)
        XCTAssertEqual(state.press(.tab), .fill("/cmd1 "))
        XCTAssertEqual(state.press(.enter), .send("/cmd1"))
        XCTAssertEqual(SlashMenuState.completion(of: SlashCommand(name: "codex:rescue")), "/codex:rescue ")
    }

    func testANewDraftStartsAtTheFirstRowAndTheTop() {
        var state = menu(20)
        for _ in 0..<12 { _ = state.press(.down) }
        XCTAssertEqual(state.highlighted, 12)
        XCTAssertGreaterThan(state.top, 0)
        state.update(commands(20))
        XCTAssertEqual(state.highlighted, 0)
        XCTAssertEqual(state.top, 0)
    }

    func testTheWindowKeepsTheHighlightInViewWithARowOfContext() {
        // Five rows are shown; the highlight keeps one row on each side, except at the ends of the list.
        XCTAssertEqual(SlashMenuState.visibleRows, 5)
        func top(_ index: Int, from top: Int = 0, count: Int = 30) -> Int { SlashMenuState.scrollTop(keeping: index, from: top, count: count) }
        XCTAssertEqual(top(0), 0)
        XCTAssertEqual(top(3), 0, "The fourth row still has the fifth below it.")
        XCTAssertEqual(top(4), 1, "Going down, the window follows one row ahead.")
        XCTAssertEqual(top(10, from: 7), 7, "Already inside the window: no movement.")
        XCTAssertEqual(top(11, from: 7), 8, "The row would sit at the window's bottom edge, so the window moves down one.")
        XCTAssertEqual(top(6, from: 7), 5, "Going up, the row above stays visible too.")
        XCTAssertEqual(top(1, from: 5), 0, "At the top the window stops.")
        XCTAssertEqual(top(29, from: 0), 25, "The last row shows at the bottom of the last window.")
        XCTAssertEqual(top(28, from: 25), 25, "…and the one before it needs no more scrolling.")
        XCTAssertEqual(top(0, from: 25), 0, "Wrapping to the first row goes back to the top.")
        XCTAssertEqual(top(2, count: 5), 0, "A list that fits never scrolls.")
        XCTAssertEqual(top(100, from: 3, count: 30), 25, "Never past the last window.")
    }

    func testTheArrowsDriveTheWindowThroughALongList() {
        var state = menu(117)
        var seen: [Int] = []
        for _ in 0..<116 {
            _ = state.press(.down)
            seen.append(state.top)
            XCTAssertTrue((state.top...(state.top + 4)).contains(state.highlighted), "The highlighted row is always inside the window.")
        }
        XCTAssertEqual(state.highlighted, 116)
        XCTAssertEqual(state.top, 112, "The window ends on the last row.")
        XCTAssertEqual(seen, seen.sorted(), "Going down the window only moves down.")
        _ = state.press(.down)
        XCTAssertEqual(state.highlighted, 0)
        XCTAssertEqual(state.top, 0)
        _ = state.press(.up)
        XCTAssertEqual(state.highlighted, 116)
        XCTAssertEqual(state.top, 112)
    }

    func testTheMatchedPartOfANameIsFoundTheWayTheMatchingFindsIt() {
        func part(_ name: String, _ query: String) -> String? {
            SlashMenuState.matchedRange(in: name, query: query).map { String(name[$0]) }
        }
        XCTAssertEqual(part("usage", "us"), "us")
        XCTAssertEqual(part("Usage", "US"), "Us", "Case does not matter.")
        XCTAssertEqual(part("add-dir", "adddir"), "add-dir", "Separators are ignored on both sides.")
        XCTAssertEqual(part("add-dir", "add-d"), "add-d")
        XCTAssertEqual(part("codex:rescue", "res"), "res", "A word inside the name counts.")
        XCTAssertEqual(part("deep-research", "res"), "res")
        XCTAssertEqual(part("codex:rescue", "cod"), "cod", "From the start of the name first.")
        XCTAssertNil(part("clear", "new"), "An alias matched: the name has nothing to emphasise.")
        XCTAssertNil(part("usage", ""))
        XCTAssertNil(part("usage", "usagex"))
        XCTAssertNil(part("status", "tat"), "A letter in the middle of a word is not a match.")
    }

    func testTheListsHeightIsWholeRowsUpToTheVisibleOnes() {
        XCTAssertEqual(SlashMenuView.listHeight(rows: 0), 0)
        XCTAssertEqual(SlashMenuView.listHeight(rows: 1), SlashMenuView.rowHeight)
        XCTAssertEqual(SlashMenuView.listHeight(rows: 2), 2 * SlashMenuView.rowHeight + SlashMenuView.rowGap)
        XCTAssertEqual(SlashMenuView.listHeight(rows: 5), SlashMenuView.listHeight(rows: 117), "More rows scroll instead of growing.")
        // The island's pane is 204 pt tall: 9 pt below the composer, the composer, the gap to the menu, and the row of tabs above it.
        XCTAssertLessThanOrEqual(SlashMenuView.height(rows: 117) + 66 + 9 + 5, 204 - 4, "The tallest menu leaves a little air under the tab row.")
    }
}
