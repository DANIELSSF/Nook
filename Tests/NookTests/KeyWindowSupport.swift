import AppKit
import XCTest

extension XCTestCase {
    /// Skips a test that needs a window to be key (a real click into a field, the keyboard that follows a drop) while the screen is locked:
    /// the window server then gives no window the key, however it is asked (`isKeyWindow` stays false after `makeKeyAndOrderFront`), so
    /// such a test would fail for a reason that has nothing to do with the code.
    func requireKeyCapableSession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        try XCTSkipIf((session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true, "The screen is locked: no window can become key.")
    }
}
