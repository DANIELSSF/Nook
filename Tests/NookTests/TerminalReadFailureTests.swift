import XCTest
@testable import Nook

/// A Terminal read that keeps failing raises one notice per failing streak, not one per poll.
final class TerminalReadFailureTests: XCTestCase {
    private func tab() -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "w", index: 1, tty: "/dev/ttys099", customTitle: "", processes: [], busy: false, selected: true, text: "")
    }

    /// Runs one refresh on the bridge and waits until its result was handled on the main queue.
    private func refreshOnce(_ bridge: TerminalAppBridge) {
        let done = expectation(description: "refresh handled")
        bridge.refresh()
        bridge.queue.async { DispatchQueue.main.async { done.fulfill() } }
        wait(for: [done], timeout: 5)
    }

    func testTheSameFailureOnEveryPollRaisesOneNoticeAndSuccessStartsANewStreak() {
        let bridge = TerminalAppBridge()
        var mode: Result<[TerminalTabSnapshot], Error> = .failure(TerminalBridgeError.failed("Terminal no responde."))
        bridge.reader = { _ in try mode.get() }
        var notices: [String] = []
        bridge.onFailure = { notices.append($0) }
        bridge.connect(tab: tab())
        refreshOnce(bridge)
        defer { bridge.disconnect(tty: "/dev/ttys099") }
        XCTAssertEqual(notices, ["Terminal no responde."])
        refreshOnce(bridge); refreshOnce(bridge)
        XCTAssertEqual(notices.count, 1, "the same message on every poll must not bring the notice back")
        XCTAssertEqual(bridge.error, "Terminal no responde.")

        mode = .success([])
        refreshOnce(bridge)
        XCTAssertNil(bridge.error, "a good read ends the streak")

        mode = .failure(TerminalBridgeError.failed("Terminal no responde."))
        refreshOnce(bridge)
        XCTAssertEqual(notices.count, 2, "the failure after a success is a new streak")
    }

    func testADifferentMessageInTheSameStreakIsReported() {
        let bridge = TerminalAppBridge()
        var message = "uno"
        bridge.reader = { _ in throw TerminalBridgeError.failed(message) }
        var notices: [String] = []
        bridge.onFailure = { notices.append($0) }
        bridge.connect(tab: tab())
        refreshOnce(bridge)
        defer { bridge.disconnect(tty: "/dev/ttys099") }
        message = "dos"
        refreshOnce(bridge)
        XCTAssertEqual(notices, ["uno", "dos"])
    }
}
