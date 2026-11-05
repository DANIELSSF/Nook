import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Nook

/// ⌃⌥N from any app opens the island, and the same keys put it away. The island here is quiet (invisible, deaf to the pointer) and the
/// toggle never takes the keyboard, so nothing reaches the app in front; no hot key is registered either.
@MainActor
final class IslandShortcutTests: XCTestCase {
    func testTheShortcutIsControlOptionN() {
        let combo = HotKeyCombo.toggleIsland
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(combo.modifiers, UInt32(controlKey | optionKey), "Control-Option: free in macOS and in Edge")
        XCTAssertEqual(combo.menuKey, "n")
        XCTAssertEqual(combo.menuModifiers, [.control, .option], "the menu shows the same keys the hot key takes")
    }

    func testTheSameShortcutOpensAndPutsAwayTheIsland() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-shortcut-" + UUID().uuidString)!)
        let controller = NotchController(model: model, quiet: true)
        addTeardownBlock {
            controller.collapse(force: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            controller.panel.close(); controller.petPanel.close()
            model.controller = nil
        }
        XCTAssertFalse(model.expanded)
        controller.toggleFromShortcut(focus: false)
        XCTAssertTrue(model.expanded, "collapsed, the shortcut opens the island")
        controller.toggleFromShortcut(focus: false)
        XCTAssertFalse(model.expanded, "open, the same shortcut puts it away")
        model.pinned = true
        controller.toggleFromShortcut(focus: false)
        controller.toggleFromShortcut(focus: false)
        XCTAssertFalse(model.expanded, "a pinned island goes too, as with the chevron")
    }
}
