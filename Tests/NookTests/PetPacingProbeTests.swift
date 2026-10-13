import AppKit
import XCTest
@testable import Nook

/// The frame pacing of a big cat (the home's, 2.4 points a unit on a Retina screen), probed headlessly: the driver is ticked the way the
/// view's timer and display link would tick it, through a slow movement (the bow of a stretch), a fast one (a hop) and a long rest. It
/// records the interval the driver picks at each tick, how far the picture moved on each frame it drew, and what that costs (the tick's
/// own work and painting the part of the stage that changed), prints them per phase, and checks what they promise: steps under the eye's
/// notice while it moves slowly, the top rate while it moves fast, and the resting cadence (and cost) unchanged while it rests.
@MainActor
final class PetPacingProbeTests: XCTestCase {
    struct Phase {
        var name: String
        var range: Range<Double>
        var ticks = 0, draws = 0
        var intervals: [Double: Int] = [:]
        /// Pixels the picture moved on each drawn frame.
        var steps: [Double] = []
        var tickNanos = 0.0, paintNanos = 0.0
        var seconds: Double { range.upperBound - range.lowerBound }
        var summary: String {
            let sorted = steps.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let histogram = intervals.keys.sorted().map { String(format: "1/%.0f×%d", 1 / $0, intervals[$0] ?? 0) }.joined(separator: " ")
            return String(format: "%-10@ ticks/s %5.1f  draws/s %5.1f  step px median %4.2f max %5.2f  cpu %6.1f us/s (tick %5.1f + paint %6.1f)  intervals: %@",
                          name as NSString, Double(ticks) / seconds, Double(draws) / seconds, median, sorted.last ?? 0, (tickNanos + paintNanos) / 1000 / seconds,
                          tickNanos / 1000 / seconds, paintNanos / 1000 / seconds, histogram as NSString)
        }
    }

    /// Ticks a driver for `seconds` from `start` the way a view would, `change` setting the world at each tick; `phases` sorts the ticks.
    static func probe(layout: PetLayout, stage: PetPlayer.Layout, scale: CGFloat, seconds: Double, phases: [(String, Range<Double>)],
                      before: (inout PetDriver) -> Void, input: (Double) -> PetInput) -> [Phase] {
        var driver = PetDriver(layout: layout, seed: 2, backing: 2, rhythm: PetDirector.Rhythm(first: 1e6...1e6, between: 1e6...1e6))
        before(&driver)
        var result = phases.map { Phase(name: $0.0, range: $0.1) }
        let ppp = 2
        let canvas = CGContext(data: nil, width: 260 * ppp, height: 100 * ppp, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.scaleBy(x: CGFloat(ppp), y: CGFloat(ppp))
        var drawn = PetPose()
        var t = 0.0
        while t < seconds {
            let start = PetBudget.nanos()
            let tick = driver.tick(now: 1000 + t, layout: stage, input: input(t))
            let tickCost = PetBudget.nanos() - start
            var paintCost = 0.0
            var step = 0.0
            if tick.draw {
                step = Double(tick.pose.displacement(to: drawn, scale: scale) * 2)
                // The view repaints where the cat was and where it is now.
                let rect = HomePetView.paintedRect(drawn, scale: scale, homeX: 100).union(HomePetView.paintedRect(tick.pose, scale: scale, homeX: 100))
                let paint = PetBudget.nanos()
                canvas.saveGState()
                canvas.clip(to: rect)
                canvas.setFillColor(CGColor(gray: 0, alpha: 1)); canvas.fill(rect)
                HomePetView.paint(tick.pose, look: PetLook(), scale: scale, homeX: 100, in: canvas)
                canvas.restoreGState()
                paintCost = PetBudget.nanos() - paint
                drawn = tick.pose
            }
            if let k = result.firstIndex(where: { $0.range.contains(t) }) {
                result[k].ticks += 1
                result[k].intervals[tick.interval, default: 0] += 1
                result[k].tickNanos += tickCost; result[k].paintNanos += paintCost
                if tick.draw { result[k].draws += 1; result[k].steps.append(step) }
            }
            t += tick.interval
        }
        return result
    }

    /// The home's cat: a stretch (slow), a hop (fast), then half a minute of rest with its blinks and glances.
    static func homeProbe() -> [Phase] {
        let layout = PetMotion.layout
        var prefs = PetPreferences(); prefs.activity = .none
        return probe(layout: .header, stage: layout, scale: PetMotion.scale, seconds: 42,
                     phases: [("slow", 0.8..<6.2), ("fast", 8.0..<9.3), ("rest", 11..<42)],
                     before: { $0.player.begin(.stretch, layout: layout) },
                     input: { t in var i = PetInput(completions: t >= 8 ? 1 : 0, idle: 10); i.prefs = prefs; return i })
    }

    /// The notch's cat through the same.
    static func compactProbe() -> [Phase] {
        var prefs = PetPreferences(); prefs.activity = .none
        return probe(layout: .compact, stage: .compact(height: 32), scale: PetAnimation.compactScale, seconds: 42,
                     phases: [("slow", 0.8..<6.2), ("fast", 8.0..<9.3), ("rest", 11..<42)],
                     before: { $0.player.begin(.stretch, layout: .compact(height: 32)) },
                     input: { t in var i = PetInput(completions: t >= 8 ? 1 : 0, idle: 10); i.prefs = prefs; return i })
    }

    func testTheIntervalsABigCatGetsMovingSlowlyThenFastThenAtRest() {
        let home = Self.homeProbe(), compact = Self.compactProbe()
        print("== the home's cat (2.4 pt a unit, 2 px a point)\n" + home.map(\.summary).joined(separator: "\n"))
        print("== the notch's cat (0.6 pt a unit)\n" + compact.map(\.summary).joined(separator: "\n"))
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let slow = home[0], fast = home[1], rest = home[2]
        // Moving slowly, a big cat is drawn in steps the eye does not see as steps (half a pixel or so), as often as that takes.
        XCTAssertLessThan(median(slow.steps), 1.5, "a slow movement of the big cat moves its picture \(median(slow.steps)) px a frame")
        XCTAssertGreaterThan(Double(slow.draws) / slow.seconds, 30, "and it is drawn often enough for that")
        // Moving fast, it gets the top rate: sixty frames a second.
        let topRate = fast.intervals.filter { abs($0.key - 1.0 / 60) < 1e-9 }.map(\.value).reduce(0, +)
        XCTAssertGreaterThan(Double(topRate) / Double(fast.ticks), 0.8, "a hop is drawn at sixty frames a second")
        // At rest it only breathes between the small movements of its life: the resting cadence is still there, and nothing at rest goes
        // faster than the resting top rate (thirty a second).
        XCTAssertNotNil(rest.intervals.keys.first { $0 >= PetCadence.rest(focus: .free, power: .normal) - 1e-9 }, "breathing keeps the resting cadence")
        XCTAssertGreaterThanOrEqual(rest.intervals.keys.min() ?? 0, PetAnimation.restingTopInterval - 1e-9)
        // The notch's cat at rest costs what it did: the same ticks and frames as before the big cats got their finer pacing.
        XCTAssertLessThan(Double(compact[2].ticks) / compact[2].seconds, 7.5)
        XCTAssertLessThan(Double(compact[2].draws) / compact[2].seconds, 4.6)
        XCTAssertGreaterThanOrEqual(compact[2].intervals.keys.min() ?? 0, PetAnimation.restingTopInterval - 1e-9)
    }

    /// A slow glide of a big cat's picture (10 pixels a second at the home's size, as slow as anything it does): the intervals the pace picks
    /// for it while the cat moves (half-pixel steps) and at its resting step (the step every movement had before: a pixel and a half).
    func testASlowMoveOfABigCatIsDrawnInStepsTheEyeDoesNotSee() {
        func glide(moving: Bool) -> (intervals: [Double], step: Double) {
            var pace = PetPace(fast: PetAnimation.headerInterval), pose = PetPose(), t = 0.0, interval = 1.0 / 60
            var intervals: [Double] = []
            for _ in 0..<80 {
                pose.head.x += CGFloat(10 / Double(PetMotion.pixels) * interval)
                t += interval
                pace.fineStepPixels = PetPace.fineStep(scale: PetMotion.scale)
                interval = pace.interval(for: pose, now: t, scale: PetMotion.scale, ceiling: 1.0 / 8, moving: moving)
                intervals.append(interval)
            }
            return (intervals, (intervals.last ?? 0) * 10)
        }
        let fine = glide(moving: true), coarse = glide(moving: false)
        print(String(format: "a slow glide, 10 px/s on the home's cat: every %.3f s in %.2f px steps while it moves (at the resting step: every %.3f s in %.2f px steps)",
                     fine.intervals.last ?? 0, fine.step, coarse.intervals.last ?? 0, coarse.step))
        XCTAssertEqual(fine.intervals.last ?? 0, 1.0 / 20, accuracy: 1e-9, "twenty frames a second, half a pixel each")
        XCTAssertEqual(coarse.intervals.last ?? 0, 1.0 / 8, accuracy: 1e-9, "where the old step drew it eight times a second")
    }
}
