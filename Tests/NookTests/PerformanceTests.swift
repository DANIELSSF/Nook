import AppKit
import XCTest
@testable import Nook

final class PerformanceTests: XCTestCase {
    func testIslandOutlinesCanMorphIntoEachOther() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        let compact = IslandView.outline(CGRect(x: 163, y: 234, width: 245, height: 32), radius: 10)
        let full = IslandView.outline(CGRect(x: 0, y: 0, width: 572, height: 266), radius: 22)
        XCTAssertEqual(elements(compact), elements(full), "Core Animation morphs paths only when their elements match.")
        XCTAssertEqual(full.boundingBox.minX, 0, accuracy: 0.001)
        XCTAssertEqual(full.boundingBox.width, 572, accuracy: 0.001)
        XCTAssertEqual(full.boundingBox.height, 266, accuracy: 0.001)
    }

    func testCatRunsAtDisplayRateOnlyWhileItMoves() {
        var pace = PetPace(fast: 1.0 / 60)
        var pose = PetPose()
        var interval = pace.interval(for: pose, now: 0)
        // Breathing alone: the rate drops after a short quiet spell.
        for frame in 1...60 {
            pose.x = sin(Double(frame) / 60 * .pi) * 0.3
            interval = pace.interval(for: pose, now: Double(frame) / 60)
        }
        XCTAssertEqual(interval, pace.slow)
        // Gentle sway runs at half rate; a step or a blink brings the display rate back at once.
        pose.x += 0.4
        XCTAssertEqual(pace.interval(for: pose, now: 1.1), pace.medium)
        pose.x += 3
        XCTAssertEqual(pace.interval(for: pose, now: 1.2), 1.0 / 60)
        pose.action = .walk
        XCTAssertEqual(pace.interval(for: pose, now: 1.3), 1.0 / 60)
    }

    func testCollapsedReadsOnlyTheVisibleScreen() {
        let light = TerminalAppBridge.snapshotScript(windowIDs: [42], ttys: ["/dev/ttys003"], includeText: true, screenOnly: true)
        // `contents of t` on the loop's reference returns the tab object, not its text (checked against Terminal).
        XCTAssertTrue(light.contains("contents of tab tabIndex of w"))
        XCTAssertFalse(light.contains("contents of t\n"))
        XCTAssertFalse(light.contains("history of t"))
        var details: NSDictionary?
        XCTAssertTrue(NSAppleScript(source: light)!.compileAndReturnError(&details), details?.description ?? "")
        XCTAssertTrue(TerminalAppBridge.snapshotScript(windowIDs: [42], ttys: ["/dev/ttys003"], includeText: true).contains("history of t"))
    }

    func testScreenOnlyReadsKeepTheMirrorAndUpdateClaudesStatus() {
        let rule = String(repeating: "─", count: 80)
        let history = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys050", customTitle: "", processes: ["claude"], busy: true, selected: true, text: "⏺ Historial completo\n" + rule + "\n❯ \n" + rule)
        let session = TerminalSession(tab: history, backend: .bundled, bridge: TerminalAppBridge())
        var screen = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys050", customTitle: "", processes: ["claude"], busy: true, selected: true, text: "✶ Churning… (3s)\n" + rule + "\n❯ ok sigue\n" + rule)
        screen.history = false
        session.update(screen)
        XCTAssertEqual(session.displayText, "⏺ Historial completo", "A screen-only read never replaces the mirror.")
        XCTAssertEqual(session.liveStatus?.glyph, "✶", "The notch follows Claude's spinner while collapsed.")
        XCTAssertNil(session.agentStatus, "What only the hidden panel shows waits for the next history read.")
        XCTAssertNil(session.suggestion)
    }
}

final class ScriptHelperTests: XCTestCase {
    /// A stand-in helper that answers one JSON line per request, like `Nook --terminal-script`.
    private func helper(_ script: String) -> ScriptHelper {
        ScriptHelper(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
    }

    func testShortRepliesReturnImmediatelyAndTheHelperIsReused() throws {
        let echo = helper(#"n=0; while read line; do n=$((n+1)); printf '{"value":"reply %s"}\n' "$n"; done"#)
        let started = Date()
        for expected in 1...5 { XCTAssertEqual(try echo.run("return 1")["value"] as? String, "reply \(expected)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Small replies must not wait for a full buffer.")
    }

    func testLargeRepliesArriveWhole() throws {
        let big = helper(#"while read line; do printf '{"value":"'; head -c 200000 /dev/zero | tr '\0' 'a'; printf '"}\n'; done"#)
        XCTAssertEqual((try big.run("history")["value"] as? String)?.count, 200000)
    }

    func testAHelperThatDiesIsReplacedForTheNextRequest() throws {
        let once = helper(#"read line; printf '{"value":"ok"}\n'"#)
        XCTAssertEqual(try once.run("first")["value"] as? String, "ok")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try once.run("second")["value"] as? String, "ok")
    }
}
