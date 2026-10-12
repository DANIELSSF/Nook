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

    func testCatIsDrawnAsOftenAsItsPictureMovesAndNoMore() {
        // Frames follow how far the picture moves between two: a cat that only breathes waits, a step or a blink gets frames.
        var pace = PetPace(fast: 1.0 / 30)
        var pose = PetPose()
        var interval = pace.interval(for: pose, now: 0)
        XCTAssertEqual(interval, 1.0 / 30, "The first frame says nothing about speed: it is drawn at the full rate.")
        // Breathing alone: the rate drops to the resting one after a short quiet spell.
        var now = 0.0
        for frame in 1...60 {
            now += interval
            pose.chest.ry = 8.5 + 0.25 * CGFloat(sin(Double(frame) / 4))
            interval = pace.interval(for: pose, now: now)
        }
        XCTAssertEqual(interval, pace.slow)
        // A blink closes the eyes in a twentieth of a second: the full rate at once. A step likewise.
        now += 0.05
        pose.eyes = 0
        XCTAssertEqual(pace.interval(for: pose, now: now), 1.0 / 30)
        now += 0.05
        pose.legs[3].foot.x += 3
        XCTAssertEqual(pace.interval(for: pose, now: now), 1.0 / 30)
        // The motion stops: the rate comes back down, not at the very next frame (the pauses between the beats of a movement keep it).
        now += 1.0 / 30
        let held = pace.interval(for: pose, now: now)
        XCTAssertLessThan(held, pace.slow)
        var back = held, quietFor = 0.0
        while back < pace.slow, quietFor < 2 { quietFor += back; now += back; back = pace.interval(for: pose, now: now) }
        XCTAssertEqual(back, pace.slow)
        XCTAssertLessThan(quietFor, 0.6, "after a short dwell")
        // The slower the picture moves, the longer the frame; every interval is one of a few values.
        var seen = Set<Double>()
        for speed in stride(from: 0.2, through: 120, by: 0.7) {
            var p = PetPace(fast: 1.0 / 30)
            var pose = PetPose(), t = 0.0, interval = 1.0 / 30
            for _ in 0..<40 {
                // `speed` pixels a second: at 0.6 pt a unit and 2 px a point, a unit is 1.2 px.
                pose.legs[3].foot.x += CGFloat(speed * interval / 1.2)
                t += interval
                interval = p.interval(for: pose, now: t)
            }
            seen.insert(interval)
        }
        XCTAssertTrue(seen.isSubset(of: Set(PetPace.levels)), "\(seen)")
        XCTAssertEqual(seen.max(), PetAnimation.restInterval, "the slowest is the resting one")
        XCTAssertEqual(seen.min(), 1.0 / 30)
        // A gesture's ceiling, and a small event about to start, each shorten the wait.
        var limited = PetPace(fast: 1.0 / 30)
        var t = 0.0, wait = limited.interval(for: PetPose(), now: 0)
        for _ in 0..<40 { t += wait; wait = limited.interval(for: PetPose(), now: t) }
        XCTAssertEqual(wait, limited.slow)
        XCTAssertEqual(limited.interval(for: PetPose(), now: t + wait, ceiling: 1.0 / 8), 1.0 / 8)
        XCTAssertEqual(limited.interval(for: PetPose(), now: t + 0.3, due: 0.06), 0.06, accuracy: 1e-9, "a frame when the blink starts, not up to a whole interval late")
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

    /// The real `Nook --terminal-script` once kept every reply alive (6.6 GB after a day of polling).
    func testTheRealHelperStaysFlatAcrossPolls() throws {
        // `swift test` builds the app next to the test bundle.
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Nook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Compila Nook primero.") }
        let real = ScriptHelper(executable: binary)
        // The shell `do shell script` starts is the helper's child; Terminal is never addressed. The helper
        // quits by itself once `real` goes away and closes its requests pipe.
        let pid = try XCTUnwrap(pid_t(real.run(#"do shell script "echo $PPID""#)["value"] as? String ?? ""))
        func footprint() -> Int64 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
            return status == 0 ? Int64(usage.ri_phys_footprint) : -1
        }
        // Two tabs of 81,920 characters each, like a detailed snapshot. Before the fix this grew ~1 MB per poll.
        let poll = "set s to \"0123456789\"\nrepeat 13 times\nset s to s & s\nend repeat\nreturn {{1, \"/dev/ttys001\", s, true}, {2, \"/dev/ttys002\", s, false}}"
        for _ in 0..<20 { _ = try autoreleasepool { try real.run(poll) } }
        let start = footprint()
        XCTAssertGreaterThan(start, 0)
        for _ in 0..<200 {
            let rows = try autoreleasepool { try real.run(poll)["value"] as? [[Any]] }
            XCTAssertEqual((rows?.first?[2] as? String)?.count, 81_920)
        }
        XCTAssertLessThan(footprint() - start, 25 << 20, "Each request must free its result and reply.")
    }
}
