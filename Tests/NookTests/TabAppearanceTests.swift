import XCTest
@testable import Nook

/// A tab's name, colour and icon are saved together; what was saved by another build must still load.
final class TabAppearanceTests: XCTestCase {
    private func decode(_ json: String) throws -> [String: TabAppearance] {
        try JSONDecoder().decode([String: TabAppearance].self, from: Data(json.utf8))
    }

    func testRoundTripKeepsNameColourAndIcon() throws {
        let saved = ["a": TabAppearance(title: "API", tint: .blue, icon: .dot)]
        let loaded = try JSONDecoder().decode([String: TabAppearance].self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(loaded, saved)
    }

    func testAppearanceSavedBeforeIconsGetsTheDot() throws {
        let loaded = try decode(#"{"a": {"title": "API", "tint": "rose"}}"#)
        XCTAssertEqual(loaded["a"], TabAppearance(title: "API", tint: .rose, icon: .dot))
    }

    func testAnIconOrColourThisBuildLacksDoesNotLoseTheOtherTabs() throws {
        // The unknown colour is a name no case can have (it is not even an identifier): new colours are appended to `TabTint` as the app grows, and a fixture that is
        // a real name today turns into a case one day.
        let loaded = try decode(#"{"a": {"title": "API", "tint": "blue", "icon": "comet"}, "b": {"title": "Web", "tint": "not a colour"}}"#)
        XCTAssertEqual(loaded["a"], TabAppearance(title: "API", tint: .blue, icon: .dot))
        XCTAssertEqual(loaded["b"], TabAppearance(title: "Web", tint: .mint, icon: .dot))
    }
}
