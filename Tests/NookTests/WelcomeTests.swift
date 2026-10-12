import Combine
import XCTest
@testable import Nook

/// The very first time Nook runs it greets the user; once they dismiss the greeting or start using Nook (their first tab), never
/// again.
@MainActor
final class WelcomeTests: XCTestCase {
    private let tty = "/dev/ttys5" + String(Int.random(in: 10...99)) + String(UUID().uuidString.prefix(4))
    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-welcome-" + UUID().uuidString)! }
    private func model(_ defaults: UserDefaults) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.resting = true
        model.terminalBridge.loginStampsReader = { [:] }
        return model
    }
    private func tab() -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 7, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["login", "-zsh"], busy: false, selected: true, text: "")
    }

    func testTheFirstRunIsWelcomedOnceAndForGood() {
        let defaults = suite()
        let model = model(defaults)
        XCTAssertFalse(model.hasBeenWelcomed, "a Mac that never ran Nook gets the greeting")
        var published = 0
        let watch = model.$hasBeenWelcomed.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        model.markWelcomed()
        model.markWelcomed()
        XCTAssertTrue(model.hasBeenWelcomed)
        XCTAssertEqual(published, 1)
        XCTAssertTrue(self.model(defaults).hasBeenWelcomed, "saved: the next launch doesn't greet again")
    }

    func testTheFirstTabEndsTheGreeting() {
        let model = model(suite())
        model.connectTerminalTab(tab())
        XCTAssertTrue(model.hasBeenWelcomed)
    }

    func testAModelOfItsOwnStartsUnwelcomed() {
        let defaults = suite()
        _ = model(defaults)
        XCTAssertNil(defaults.object(forKey: AppModel.welcomedKey), "nothing is written until the greeting is over")
    }
}
