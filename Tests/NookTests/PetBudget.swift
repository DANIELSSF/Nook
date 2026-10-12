import AppKit
import Foundation
#if !PETLAB
@testable import Nook
#endif

/// What the cat costs, measured on simulated days. A view's whole job per frame is the driver's tick (the pose and the choice of when
/// to come back) and, when the picture changed enough, a draw; so a simulated view that does exactly that on a realistic mix of
/// the Mac's states (typing, reading, away, Claude working, the pointer visiting) counts the frames the real one would draw, and how
/// long each step and each draw takes. The same days were run through the cat as it was before this was reworked (see
/// `PetBudgetTests.legacy`), which is where its numbers come from.
enum PetBudget {
    struct Tally {
        /// Ticks, repaints of the cat, frames the notch's dots asked for, and the repaints of the wing (the cat changed or the dots wave).
        var seconds = 0.0, ticks = 0, draws = 0, dotDraws = 0, paints = 0, cpuNanos = 0.0
        mutating func add(_ o: Tally) { seconds += o.seconds; ticks += o.ticks; draws += o.draws; dotDraws += o.dotDraws; paints += o.paints; cpuNanos += o.cpuNanos }
        var minutes: Double { max(seconds / 60, 1e-9) }
        var ticksPerMinute: Double { Double(ticks) / minutes }
        var drawsPerMinute: Double { Double(draws) / minutes }
        var dotDrawsPerMinute: Double { Double(dotDraws) / minutes }
        /// The frames a minute that reach the screen: the figure that costs (each is a commit and a composite).
        var paintsPerMinute: Double { Double(paints) / minutes }
    }
    typealias Report = [String: Tally]

    static func total(_ report: Report) -> Tally {
        var all = Tally()
        for tally in report.values { all.add(tally) }
        return all
    }

    /// The seconds between the dots' frames while Claude works with no spinner glyph to show (`PetView`).
    static let dotsInterval = PetAnimation.dotsInterval

    // MARK: The views, as simulations

    /// The collapsed island's cat: what `PetView.step()` does on each tick, the dots' own clock included.
    final class CompactView {
        var driver: PetDriver
        var dots = PetDotsClock()
        let prefs: PetPreferences, power: PetPower, dayPart: PetDayPart
        var drawn: [PetPose] = []
        init(seed: Int, prefs: PetPreferences = PetPreferences(), power: PetPower = .normal, dayPart: PetDayPart = .day) {
            driver = PetDriver(layout: .compact, seed: seed)
            self.prefs = prefs; self.power = power; self.dayPart = dayPart
        }
        func step(now: Double, world: PetWorldSample, dots waving: Bool) -> (interval: Double, drew: Bool, dotDrew: Bool) {
            let tick = driver.tick(now: now, layout: .compact(height: 32), input: PetBudget.input(world, prefs: prefs, power: power, dayPart: dayPart))
            if tick.draw { drawn.append(tick.pose) }
            let dotFrame = dots.frame(now: now, waving: waving)
            return (min(tick.interval, dotFrame.within ?? .infinity), tick.draw, dotFrame.draw)
        }
    }

    /// The open island's header cat: what `HeaderPetView.step()` does.
    final class HeaderView {
        var driver: PetDriver
        let prefs: PetPreferences, power: PetPower, dayPart: PetDayPart
        var drawn: [PetPose] = []
        let travel: CGFloat = 164 - 22 - 11 - 4
        init(seed: Int, prefs: PetPreferences = PetPreferences(), power: PetPower = .normal, dayPart: PetDayPart = .day) {
            driver = PetDriver(layout: .header, seed: seed)
            self.prefs = prefs; self.power = power; self.dayPart = dayPart
        }
        func step(now: Double, world: PetWorldSample) -> (interval: Double, drew: Bool, dotDrew: Bool) {
            let tick = driver.tick(now: now, layout: .header(travel: travel, scale: 0.5, height: 32), input: PetBudget.input(world, prefs: prefs, power: power, dayPart: dayPart))
            if tick.draw { drawn.append(tick.pose) }
            return (tick.interval, tick.draw, false)
        }
    }

    /// What a world sample says to the cat.
    static func input(_ w: PetWorldSample, prefs: PetPreferences, power: PetPower, dayPart: PetDayPart) -> PetInput {
        var input = PetInput(working: w.working, gaze: w.near ? PetGaze(dx: 0.8, dy: 0.2) : nil, dragging: false, completions: w.completions,
                             focus: PetFocus(rawValue: w.focus) ?? .free, idle: w.idle, needsAttention: false)
        if w.perk > 0.001 { input.perk = CGFloat(w.perk); input.perkAge = w.perkAge }
        input.prefs = prefs; input.power = power; input.dayPart = dayPart
        return input
    }

    // MARK: Simulation

    static func nanos() -> Double { Double(DispatchTime.now().uptimeNanoseconds) }

    /// Runs `step` on the scenario the way a timer would: each call says how long to wait for the next one, and the scenario's
    /// discrete events cause an extra call at once (the view is told and steps). Returns the tallies by the world's state.
    static func simulate(_ scenario: PetScenario, startingAt start: Double = 5000, measure: Bool = true,
                         step: (Double, PetWorldSample) -> (interval: Double, drew: Bool, dotDrew: Bool)) -> Report {
        var tallies: Report = [:]
        let events = scenario.events
        var ei = 0
        var t = 0.0, nextTick = 0.0, interval = 0.0, lastT = 0.0
        func key(_ w: PetWorldSample) -> String { w.working ? "working" : w.label.rawValue }
        func advance(to now: Double) {
            let w = scenario.sample(at: lastT)
            tallies[key(w), default: Tally()].seconds += now - lastT
            lastT = now
        }
        while t < scenario.duration {
            let nextEvent = ei < events.count ? events[ei] : .infinity
            let isEvent = nextEvent < nextTick
            t = isEvent ? nextEvent : nextTick
            if isEvent { ei += 1 }
            if t >= scenario.duration { break }
            advance(to: t)
            let world = scenario.sample(at: t)
            let before = measure ? nanos() : 0
            let result = step(start + t, world)
            var tally = tallies[key(world), default: Tally()]
            tally.ticks += 1; if result.drew { tally.draws += 1 }; if result.dotDrew { tally.dotDraws += 1 }; if result.drew || result.dotDrew { tally.paints += 1 }
            if measure { tally.cpuNanos += nanos() - before }
            tallies[key(world)] = tally
            if result.interval != interval { interval = result.interval; nextTick = t + interval }
            else if !isEvent || nextTick <= t { nextTick = t + interval }
        }
        advance(to: scenario.duration)
        return tallies
    }

    /// A day of the collapsed island's cat. `drawn` is every pose it painted, for measuring what painting costs.
    static func compactDay(hours: Double, seed: UInt64, prefs: PetPreferences = PetPreferences(), power: PetPower = .normal, dayPart: PetDayPart = .day) -> (report: Report, drawn: [PetPose]) {
        let day = PetScenario.day(hours: hours, seed: seed)
        let view = CompactView(seed: Int(seed), prefs: prefs, power: power, dayPart: dayPart)
        let report = simulate(day) { now, world in view.step(now: now, world: world, dots: world.working && day.dots(at: now - 5000)) }
        return (report, view.drawn)
    }

    /// Visits of the open island, each `minutes` long: the header cat's life (it only exists while the island is open).
    static func openIsland(sessions: Int, minutes: Double, seed: UInt64, prefs: PetPreferences = PetPreferences(), power: PetPower = .normal, dayPart: PetDayPart = .day) -> (report: Report, drawn: [PetPose]) {
        let open = PetScenario.openIsland(sessions: sessions, minutes: minutes, seed: seed)
        let view = HeaderView(seed: Int(seed), prefs: prefs, power: power, dayPart: dayPart)
        var last = -1
        let report = simulate(open) { now, world in
            // A new visit: the view comes back and settles, as `HeaderPetView` does when its panel reappears.
            let session = Int((now - 5000) / (minutes * 60))
            if session != last { last = session; view.driver.settle() }
            return view.step(now: now, world: world)
        }
        return (report, view.drawn)
    }

    // MARK: Costs

    /// Microseconds to paint one frame of the wing (the island's black and the cat, 40 x 32 points at 2x, the dirty rect the view
    /// repaints), averaged over `poses`.
    static func costOfDrawing(_ poses: [PetPose], look: PetLook = PetLook(), rounds: Int) -> Double {
        let ppp = 2, w = 40 * ppp, h = 32 * ppp
        guard !poses.isEmpty, let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        cg.scaleBy(x: CGFloat(ppp), y: CGFloat(ppp))
        let bounds = NSRect(x: 0, y: 0, width: 246, height: 32)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        for p in poses.prefix(500) { PetWing.draw(p, look: look, bounds: bounds, in: cg) }
        let start = nanos()
        var n = 0
        for _ in 0..<rounds { for p in poses { PetWing.draw(p, look: look, bounds: bounds, in: cg); n += 1 } }
        return (nanos() - start) / Double(max(n, 1)) / 1000
    }

    /// Microseconds the player takes to make one pose, over a mix of states.
    static func costOfPose(frames: Int) -> Double {
        var player = PetPlayer(layout: .compact, seed: 9)
        var keep = PetPose()
        let start = nanos()
        for i in 0..<frames {
            let pose = player.pose(now: 1000 + Double(i) / 30, layout: .compact(), motion: true, input: PetInput(working: i % 900 < 300, idle: Double(i % 400)))
            if i % 97 == 0 { keep = pose }
        }
        _ = keep
        return (nanos() - start) / Double(max(frames, 1)) / 1000
    }

    // MARK: Reporting

    static func format(_ title: String, _ report: Report) -> String {
        var lines = ["== \(title)"]
        let all = total(report)
        func line(_ name: String, _ t: Tally) -> String {
            String(format: "  %-9@ %5.1f%% of time  ticks/min %7.1f  cat draws/min %7.1f  dots/min %6.1f  PAINTS/min %7.1f  step cpu %6.1f us", name as NSString,
                   100 * t.seconds / max(all.seconds, 1e-9), t.ticksPerMinute, t.drawsPerMinute, t.dotDrawsPerMinute, t.paintsPerMinute, t.cpuNanos / Double(max(t.ticks, 1)) / 1000)
        }
        for key in ["free", "typing", "reading", "hover", "away", "working"] { if let t = report[key] { lines.append(line(key, t)) } }
        lines.append(line("TOTAL", all))
        return lines.joined(separator: "\n")
    }
}
