import XCTest
@testable import Nook

/// What an older build saved must still load after the 12 colours, 16 icons, tab order and sound settings arrived.
final class LegacyPersistenceTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-legacy-" + UUID().uuidString)! }

    /// Every colour and icon the first build could save, by raw value, exactly as it wrote them.
    func testEveryColourAndIconTheFirstBuildSavedStillLoadsAsItself() throws {
        let tints = ["mint", "blue", "lavender", "rose", "peach", "sand", "gray"]
        let icons = ["dot", "half", "orbit", "bars", "spark", "gem"]
        var entries: [String] = []
        for (i, tint) in tints.enumerated() { entries.append(#""t\#(i)": {"title": "T\#(i)", "tint": "\#(tint)", "icon": "\#(icons[i % icons.count])"}"#) }
        let loaded = try JSONDecoder().decode([String: TabAppearance].self, from: Data(("{" + entries.joined(separator: ",") + "}").utf8))
        XCTAssertEqual(loaded.count, tints.count)
        for (i, tint) in tints.enumerated() {
            XCTAssertEqual(loaded["t\(i)"], TabAppearance(title: "T\(i)", tint: TabTint(rawValue: tint)!, icon: TabIcon(rawValue: icons[i % icons.count])!))
        }
        for raw in tints { XCTAssertNotNil(TabTint(rawValue: raw), "the raw value \(raw) was renamed") }
        for raw in icons { XCTAssertNotNil(TabIcon(rawValue: raw), "the raw value \(raw) was renamed") }
    }

    func testTheNewColoursAndIconsRoundTripAndEveryColourIsInThePicker() throws {
        XCTAssertEqual(TabTint.allCases.count, 12)
        XCTAssertEqual(TabIcon.allCases.count, 16)
        XCTAssertEqual(Set(TabTint.pickerOrder), Set(TabTint.allCases))
        XCTAssertEqual(TabTint.pickerOrder.count, 12)
        let saved = Dictionary(uniqueKeysWithValues: TabTint.allCases.enumerated().map { i, tint in
            ("k\(i)", TabAppearance(title: "n", tint: tint, icon: TabIcon.allCases[i % TabIcon.allCases.count]))
        })
        XCTAssertEqual(try JSONDecoder().decode([String: TabAppearance].self, from: JSONEncoder().encode(saved)), saved)
    }

    /// Nothing saved, a wrong type or a list with holes never crashes and never invents a place.
    func testTheTabOrderOfAnOldBuildOrAHandEditedPlistLoads() {
        let defaults = suite()
        XCTAssertEqual(TabOrder.load(from: defaults).ids, [])
        defaults.set("not a list", forKey: TabOrder.key)
        XCTAssertEqual(TabOrder.load(from: defaults).ids, [])
        defaults.set([1, 2], forKey: TabOrder.key)
        XCTAssertEqual(TabOrder.load(from: defaults).ids, [])
        defaults.set(["", "a", "a"], forKey: TabOrder.key)
        XCTAssertEqual(TabOrder.load(from: defaults).ids, ["", "a"])
    }

    @MainActor func testAModelWithNothingSavedHasTheSoundOn() {
        let model = AppModel(receivesSignals: false, defaults: suite())
        XCTAssertTrue(model.sessions.allSatisfy { $0.alertSoundOn })
    }
}
