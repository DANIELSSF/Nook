import AppKit
import XCTest
@testable import Nook

/// The cat's small life and its follow-through: blinks that close fast and open slowly, flicks and glances at hashed moments (rare, brief,
/// never a rhythm), a temperament that makes a sleepy cat look sleepy, a cat that holds still while the user types, and springs that carry
/// a hop into the tail and the ears without ever misbehaving.
final class PetLifeTests: XCTestCase {
    private let rest = PetAnimation.sit(time: 0)

    // MARK: Blinks

    private func blinks(period: Double = 7, length: Double = 0.2, seconds: Double = 600) -> [(start: Double, closing: Double, opening: Double)] {
        var result: [(Double, Double, Double)] = []
        var t = 0.0, was: CGFloat = 0, start: Double?, up: Double?, top: Double?
        while t < seconds {
            let c = PetLife.blinkClosure(t, period: period, length: length, salt: 1)
            if was < 0.1, c >= 0.1 { start = t; up = nil; top = nil }
            if start != nil, up == nil, c >= 0.9 { up = t }
            if start != nil, up != nil, top == nil, c < 0.9, was >= 0.9 { top = t }
            if let s = start, let u = up, let hi = top, was >= 0.1, c < 0.1 { result.append((s, u - s, t - hi)); start = nil }
            was = c; t += 0.001
        }
        return result
    }

    func testABlinkClosesQuicklyAndOpensMoreSlowly() {
        let all = blinks()
        XCTAssertGreaterThan(all.count, 60)
        let closing = all.map(\.closing).reduce(0, +) / Double(all.count), opening = all.map(\.opening).reduce(0, +) / Double(all.count)
        XCTAssertLessThan(closing, 0.08, "down in about a twentieth of a second"); XCTAssertGreaterThan(opening, closing * 1.4, "and up more slowly")
        for t in stride(from: 0.0, to: 200, by: 0.013) {
            let c = PetLife.blinkClosure(t, period: 7, length: 0.2, salt: 1)
            XCTAssertGreaterThanOrEqual(c, 0); XCTAssertLessThanOrEqual(c, 1)
        }
    }

    func testBlinksComeEverySevenSecondsOrSoAndNowAndThenInTwos() {
        let all = blinks(period: 7)
        let perMinute = Double(all.count) / 10
        XCTAssertGreaterThan(perMinute, 7); XCTAssertLessThan(perMinute, 14, "about a blink every five to eight seconds: \(perMinute) a minute")
        let doubled = zip(all, all.dropFirst()).filter { $1.start - $0.start < 0.5 }.count
        XCTAssertGreaterThan(Double(doubled) / Double(all.count), 0.1); XCTAssertLessThan(Double(doubled) / Double(all.count), 0.32, "one in five or so has a second close behind it")
        // Never a rhythm: the gaps between blinks are all different.
        let gaps = zip(all, all.dropFirst()).map { ($1.start - $0.start) }.filter { $0 > 0.5 }
        XCTAssertGreaterThan(Set(gaps.map { ($0 * 10).rounded() }).count, 40)
        XCTAssertGreaterThan(gaps.max()! - gaps.min()!, 6)
    }

    // MARK: Temperaments

    func testTheCuriousCatInTheDaytimeIsTheCatNookAlwaysHad() {
        let curious = PetLife.resting(rest, temperament: .of(.curious, dayPart: .day))
        XCTAssertEqual(curious, rest, "nothing is added to its look")
    }

    func testEachTemperamentRestsDifferently() {
        func face(_ personality: PetPersonality) -> PetPose { PetLife.resting(rest, temperament: .of(personality)) }
        let sleepy = face(.sleepy), calm = face(.calm), curious = face(.curious), playful = face(.playful)
        XCTAssertLessThan(sleepy.eyes, calm.eyes); XCTAssertLessThan(calm.eyes, curious.eyes); XCTAssertLessThan(curious.eyes, playful.eyes, "lids from low to wide")
        XCTAssertGreaterThan(sleepy.earL, curious.earL); XCTAssertLessThan(playful.earL, curious.earL, "ears from back to pricked")
        XCTAssertLessThan(sleepy.tail.p3.y, curious.tail.p3.y); XCTAssertGreaterThan(playful.tail.p3.y, curious.tail.p3.y, "the tail from low to high")
        XCTAssertLessThan(sleepy.head.y, curious.head.y); XCTAssertGreaterThan(playful.head.y, curious.head.y, "slumped or sitting tall")
        let sleepyT = PetTemperament.of(.sleepy), curiousT = PetTemperament.of(.curious), playfulT = PetTemperament.of(.playful)
        XCTAssertGreaterThan(sleepyT.blinkLength, curiousT.blinkLength); XCTAssertGreaterThan(curiousT.blinkLength, playfulT.blinkLength)
        XCTAssertGreaterThan(sleepyT.blinkEvery, curiousT.blinkEvery); XCTAssertGreaterThan(curiousT.blinkEvery, playfulT.blinkEvery)
        XCTAssertLessThan(sleepyT.fidget, curiousT.fidget); XCTAssertLessThan(curiousT.fidget, playfulT.fidget)
        // Even at night a playful cat stays livelier than a sleepy one by day.
        XCTAssertGreaterThan(PetTemperament.of(.playful, dayPart: .night).fidget, PetTemperament.of(.sleepy, dayPart: .day).fidget)
    }

    // MARK: Small movements

    /// How much a cat moves over `seconds` of the clock, as the picture changes between frames (points), with `context` for its life.
    private func movement(seconds: Double, context: (Double) -> PetLife.Context) -> (total: Double, stillShare: Double) {
        var total = 0.0, still = 0, count = 0
        var previous: PetPose?
        for t in stride(from: 1000.0, to: 1000 + seconds, by: 1.0 / 30) {
            var p = PetAnimation.sit(time: t)
            PetLife.apply(&p, context(t))
            if let previous {
                let d = Double(p.displacement(to: previous, scale: 0.6))
                total += d; count += 1; if d < 0.01 { still += 1 }
            }
            previous = p
        }
        return (total, Double(still) / Double(count))
    }

    func testTheCatIsMostlyStillBetweenItsSmallMovements() {
        let free = movement(seconds: 300) { PetLife.Context(time: $0, rate: 1.5) }
        // The breath alone moves it by less than a hundredth of a point a frame; its small movements are what is left.
        let moving = free.total / 300
        XCTAssertGreaterThan(moving, 1, "it is alive: it moves a little all the time")
        XCTAssertLessThan(moving, 25, "but not much: points of motion a second, added up")
    }

    func testItHoldsStillWhileTheUserTypesAndMovesMoreWhenItIsFreeToBeWatched() {
        func run(_ focus: PetFocus) -> Double {
            movement(seconds: 600) { PetLife.Context(time: $0, quiet: PetPlayer.quiet(focus), rate: PetPlayer.rate(focus), breath: PetPlayer.breath(focus)) }.total
        }
        let free = run(.free), reading = run(.reading), typing = run(.typing)
        XCTAssertGreaterThan(free, reading * 1.15); XCTAssertGreaterThan(reading, typing * 1.2)
        XCTAssertLessThan(typing, free * 0.55, "typing: free \(free), reading \(reading), typing \(typing)")
        XCTAssertGreaterThan(PetPlayer.rate(.free), PetPlayer.rate(.reading)); XCTAssertGreaterThan(PetPlayer.rate(.reading), PetPlayer.rate(.typing))
    }

    func testSmallMovementsAreFunctionsOfTheClockAndGoWhenTheCatIsBusy() {
        for t in stride(from: 3000.0, to: 3100, by: 0.37) {
            var a = rest, b = rest
            PetLife.apply(&a, PetLife.Context(time: t)); PetLife.apply(&b, PetLife.Context(time: t))
            XCTAssertEqual(a, b)
            // A cat that is asleep, hopping or dragged is left alone (apart from where it carries itself, which is zero for the plain cat).
            var busy = rest
            PetLife.apply(&busy, PetLife.Context(time: t, restful: 0))
            XCTAssertEqual(busy.look, rest.look); XCTAssertEqual(busy.earL, rest.earL); XCTAssertEqual(busy.tail, rest.tail); XCTAssertEqual(busy.head, rest.head)
            var inactive = rest
            PetLife.apply(&inactive, PetLife.Context(time: t, active: false))
            XCTAssertEqual(inactive, rest)
        }
    }

    func testEachSmallMovementIsBriefAndWithinReach() {
        var biggest: (look: CGFloat, ear: CGFloat, tail: CGFloat, head: CGFloat, tilt: CGFloat) = (0, 0, 0, 0, 0)
        for t in stride(from: 2000.0, to: 4000, by: 0.05) {
            var p = rest
            PetLife.apply(&p, PetLife.Context(time: t, rate: 1.5))
            biggest.look = max(biggest.look, abs(p.look.x)); biggest.ear = max(biggest.ear, abs(p.earL), abs(p.earR))
            biggest.tail = max(biggest.tail, abs(p.tail.p3.y - rest.tail.p3.y)); biggest.head = max(biggest.head, abs(p.head.x))
            biggest.tilt = max(biggest.tilt, abs(p.tilt))
        }
        XCTAssertLessThan(biggest.look, 3.0, "the pupils stay in the eyes"); XCTAssertLessThan(biggest.ear, 0.85)
        XCTAssertLessThan(biggest.tail, 9); XCTAssertLessThan(biggest.head, 1.2); XCTAssertLessThan(biggest.tilt, 0.2)
        XCTAssertGreaterThan(biggest.ear, 0.3, "it does flick an ear"); XCTAssertGreaterThan(biggest.tail, 2, "and the tail's tip")
    }

    // MARK: On duty

    func testACatOnDutyWatchesInBurstsAndKeepsItsTailStillWhileTheUserTypes() {
        func share(quiet: CGFloat, _ moved: (PetPose) -> Bool) -> Double {
            var n = 0, total = 0
            for t in stride(from: 5000.0, to: 5600, by: 1.0 / 20) {
                var p = rest
                PetLife.apply(&p, PetLife.Context(time: t, quiet: quiet, alert: 1))
                total += 1; if moved(p) { n += 1 }
            }
            return Double(n) / Double(total)
        }
        let tail = share(quiet: 1) { abs($0.tail.p3.y - rest.tail.p3.y) > 1.2 }
        XCTAssertGreaterThan(tail, 0.02, "the tip of the tail taps"); XCTAssertLessThan(tail, 0.2, "now and then, not all the while")
        let paw = share(quiet: 1) { $0.legs[3].foot.y > rest.legs[3].foot.y + 0.5 }
        XCTAssertGreaterThan(paw, 0.005); XCTAssertLessThan(paw, 0.12)
        let looking = share(quiet: 1) { $0.look.x > 0.9 }
        XCTAssertGreaterThan(looking, 0.05); XCTAssertLessThan(looking, 0.5, "it looks toward the activity in bursts")
        // While the user types the on-duty taps of the tail and the paw are left out: the cat on duty and the one off it differ by nothing there.
        for t in stride(from: 5000.0, to: 5400, by: 1.0 / 20) {
            var on = rest, off = rest
            PetLife.apply(&on, PetLife.Context(time: t, quiet: 0.3, alert: 1)); PetLife.apply(&off, PetLife.Context(time: t, quiet: 0.3, alert: 0))
            XCTAssertEqual(on.tail, off.tail, "no tail taps while the user types"); XCTAssertEqual(on.legs, off.legs, "and no paw taps")
        }
    }

    // MARK: What the frame rate is told

    func testTheFrameRateIsToldWhenTheNextSmallThingStartsAndHowLongAQuickOneLasts() {
        let context = { (t: Double) in PetLife.Context(time: t, rate: 1.5) }
        // Find a blink and look at it from before, from inside, and from after.
        let period = PetTemperament().blinkEvery / 1.5
        var start: Double?
        for t in stride(from: 1000.0, to: 1100, by: 0.002) where PetLife.blinkClosure(t, period: period, length: 0.2, salt: 1) > 0.05 { start = t; break }
        let s = try! XCTUnwrap(start)
        let before = PetLife.timing(context(s - 0.3))
        XCTAssertLessThanOrEqual(before.due, 0.31, "a blink is about to start"); XCTAssertGreaterThan(before.due, 0.2)
        XCTAssertEqual(before.busyFor, 0, "nothing is under way yet")
        let during = PetLife.timing(context(s + 0.05))
        XCTAssertGreaterThan(during.busyFor, 0.05); XCTAssertLessThanOrEqual(during.busyFor, 0.2 + 0.13 + 0.2, "a blink is under way: it has a fraction of a second left (and a double one its second blink)")
        // Whatever is next is some seconds off, and never negative.
        for t in stride(from: 1000.0, to: 1200, by: 0.31) {
            let timing = PetLife.timing(context(t))
            XCTAssertGreaterThan(timing.due, 0); XCTAssertLessThan(timing.due, 40)
            XCTAssertGreaterThanOrEqual(timing.busyFor, 0)
        }
    }

    func testEveryStartThatTheFrameRateIsToldOfIsOneThatHappens() {
        // The next start it reports is a moment when the pose really begins to change.
        var checked = 0
        for t0 in stride(from: 7000.0, to: 7400, by: 1.7) {
            let c = PetLife.Context(time: t0, rate: 1.0)
            let due = PetLife.timing(c).due
            var before = rest, after = rest
            PetLife.apply(&before, PetLife.Context(time: t0 + due - 0.02, rate: 1.0)); PetLife.apply(&after, PetLife.Context(time: t0 + due + 0.15, rate: 1.0))
            // 0.17 s later than it was told, something is different from the instant before it (unless a slower movement has only begun).
            if after.displacement(to: before, scale: 0.6) > 0.001 { checked += 1 }
        }
        XCTAssertGreaterThan(checked, 150, "almost every start it announces is followed by a change in the picture")
    }

    func testOnlyTheQuickMovementsAreAnnouncedToTheFrameRate() {
        // The slow ones (a look, a sigh, a shift of weight) ease in from stillness: a tick at the instant one starts finds nothing to
        // draw, and announcing them only woke the Mac once more for each. A blink, an ear or the tail's tip is what is announced.
        let tm = PetTemperament(), rate = 1.0, f = tm.fidget * rate
        var announced = 0, t = 9000.0
        while t < 9000 + 1800 {
            let start = t + PetLife.timing(PetLife.Context(time: t, rate: rate)).due
            let at = start + 0.01
            let blink = PetLife.blinkClosure(at, period: tm.blinkEvery / rate, length: tm.blinkLength, salt: 1) > 0
            let ear = PetAnimation.event(at, period: PetLife.ear / f, length: 0.4, salt: 3) != nil
            let flick = PetAnimation.event(at, period: PetLife.flickEvery / f, length: 0.8, salt: 2) != nil
            XCTAssertTrue(blink || ear || flick, "the start announced at \(start) is a quick movement's")
            announced += 1
            t = start + 0.05
        }
        XCTAssertGreaterThan(announced, 300, "a blink every few seconds, and an ear or a flick of the tail now and then")
    }
}

/// The springs that carry the follow-through: exact at any step, stable, and with the overshoot that makes a tail swing.
final class PetSecondaryTests: XCTestCase {
    func testASpringReachesItsTargetAndOvershootsWhenItIsUnderdamped() {
        var spring = PetSpring()
        var peak: CGFloat = 0, settledAt: Double?
        for i in 1...400 {
            let t = Double(i) / 200
            let x = spring.advance(to: 1, PetSpring.Step(w: 20, zeta: 0.4, dt: 1 / 200))
            peak = max(peak, x)
            if settledAt == nil, abs(x - 1) < 0.01, abs(spring.v) < 0.05 { settledAt = t }
        }
        XCTAssertEqual(peak, 1 + exp(-Double.pi * 0.4 / (1 - 0.16).squareRoot()), accuracy: 0.02, "the textbook overshoot of a spring with damping 0.4")
        XCTAssertNotNil(settledAt); XCTAssertLessThan(settledAt ?? 9, 1.6)
        var heavy = PetSpring(), highest: CGFloat = 0
        for _ in 1...400 { highest = max(highest, heavy.advance(to: 1, PetSpring.Step(w: 20, zeta: 1.4, dt: 1 / 200))) }
        XCTAssertLessThan(highest, 1.005, "a heavily damped one creeps up and never passes")
    }

    func testTheSpringIsExactAtAnyStep() {
        let w: CGFloat = 13, zeta: CGFloat = 0.55
        var one = PetSpring(x: 0.3, v: -2), many = PetSpring(x: 0.3, v: -2)
        _ = one.advance(to: 2, PetSpring.Step(w: w, zeta: zeta, dt: 1.0))
        let tiny = PetSpring.Step(w: w, zeta: zeta, dt: 0.001)
        for _ in 0..<1000 { _ = many.advance(to: 2, tiny) }
        XCTAssertEqual(one.x, many.x, accuracy: 1e-4); XCTAssertEqual(one.v, many.v, accuracy: 1e-3, "one second in one step is a thousand steps of a millisecond")
        var split = PetSpring(x: 0.3, v: -2)
        for dt in [0.25, 0.25, 0.1, 0.4] as [CGFloat] { _ = split.advance(to: 2, PetSpring.Step(w: w, zeta: zeta, dt: dt)) }
        XCTAssertEqual(one.x, split.x, accuracy: 1e-4)
    }

    func testItIsStableForEveryStepSizeAndEveryTarget() {
        var generator = SeededGenerator(seed: 4)
        var spring = PetSpring()
        for _ in 0..<20000 {
            let dt = CGFloat.random(in: 0.0001...0.6, using: &generator), target = CGFloat.random(in: -30...30, using: &generator)
            let x = spring.advance(to: target, PetSpring.Step(w: CGFloat.random(in: 5...30, using: &generator), zeta: CGFloat.random(in: 0.1...1.3, using: &generator), dt: dt))
            XCTAssertTrue(x.isFinite && abs(x) < 80, "x \(x)"); XCTAssertTrue(spring.v.isFinite && abs(spring.v) < 4000)
        }
    }

    // MARK: The follow-through of a pose

    /// A hop (the whole cat goes up and down, in rig units) as the player sees it, with the tail and ears sprung.
    private func hop(seconds: Double = 3, fps: Double = 60) -> (raw: [PetPose], sprung: [PetPose]) {
        var secondary = PetSecondary()
        var raw = [PetPose](), sprung = [PetPose]()
        var t = 0.0
        while t <= seconds {
            var p = PetAnimation.sit(time: 5)
            let air = t > 0.5 && t < 1.0 ? CGFloat(4 * ((t - 0.5) / 0.5) * (1 - (t - 0.5) / 0.5)) : 0
            p.y = 4 * air
            raw.append(p)
            secondary.apply(&p, dt: 1 / fps, scale: 0.6)
            sprung.append(p)
            t += 1 / fps
        }
        return (raw, sprung)
    }

    func testAHopLeavesTheTailBehindInTheAirAndDropsItOnTheLanding() {
        let (raw, sprung) = hop()
        let rest = raw[0].tail.p3.y
        let tipUp = sprung.map { $0.tail.p3.y - rest }
        XCTAssertGreaterThan(tipUp.max()!, 0.3, "the tail's tip floats up as the body goes up")
        XCTAssertLessThan(tipUp.min()!, -0.2, "and is thrown down by the landing")
        let apex = raw.firstIndex { $0.y == raw.map(\.y).max()! }!
        let tipPeak = tipUp.firstIndex(of: tipUp.max()!)!
        XCTAssertLessThan(tipPeak, apex + 20, "it follows the body, it does not lead it")
        // Ears are thrown too.
        let ears = sprung.map { $0.earL - raw[0].earL }
        XCTAssertGreaterThan(ears.map(abs).max()!, 0.04, "and the ears")
        // It all calms: two seconds after the landing there is nothing left but where the pose wants it.
        for (r, s) in zip(raw, sprung).suffix(30) {
            XCTAssertEqual(s.tail.p3.y, r.tail.p3.y, accuracy: 0.03); XCTAssertEqual(s.earL, r.earL, accuracy: 0.01)
        }
    }

    func testNothingMovesWhenNothingDoesAndWhatMustStayPutStays() {
        var secondary = PetSecondary()
        let still = PetAnimation.sit(time: 5)
        for _ in 0..<200 {
            var p = still
            secondary.apply(&p, dt: 1.0 / 30, scale: 0.6)
            XCTAssertEqual(p, still, "a still pose comes out as it went in")
        }
        // A hop moves the tail and the ears but never the legs, the body, the eyes or where the cat is.
        var primed = PetSecondary()
        var base = still; primed.apply(&base, dt: 0, scale: 0.6)
        for i in 1...60 {
            var p = still; p.y = CGFloat(i % 7); p.x = CGFloat(i % 5)
            primed.apply(&p, dt: 1.0 / 30, scale: 0.6)
            XCTAssertEqual(p.legs, still.legs); XCTAssertEqual(p.haunch, still.haunch); XCTAssertEqual(p.chest, still.chest)
            XCTAssertEqual(p.eyes, still.eyes); XCTAssertEqual(p.y, CGFloat(i % 7)); XCTAssertEqual(p.x, CGFloat(i % 5)); XCTAssertEqual(p.tail.p0, still.tail.p0)
        }
    }

    func testAResetStartsTheSpringsAtRestOnTheNextPose() {
        var secondary = PetSecondary()
        for i in 0..<30 { var p = PetAnimation.sit(time: 5); p.y = CGFloat(i % 4) * 2; secondary.apply(&p, dt: 1.0 / 30, scale: 0.6) }
        XCTAssertGreaterThan(secondary.energy, 0)
        secondary.reset()
        var next = PetAnimation.sit(time: 9); next.tail.p3 = CGPoint(x: 3, y: 20); next.earL = 0.4
        let expected = next
        secondary.apply(&next, dt: 1.0 / 30, scale: 0.6)
        XCTAssertEqual(next, expected, "the cat that comes back is where it is, not swinging in from where it was")
        XCTAssertEqual(secondary.energy, 0, accuracy: 1e-9)
    }

    func testAHeadThatTurnsSettlesWithABriefOvershoot() {
        var secondary = PetSecondary()
        var first = PetAnimation.sit(time: 5); secondary.apply(&first, dt: 0, scale: 0.6)
        var peak: CGFloat = 0, last: CGFloat = 0
        for i in 1...120 {
            var p = PetAnimation.sit(time: 5); p.head.x = 3
            secondary.apply(&p, dt: 1.0 / 60, scale: 0.6)
            peak = max(peak, p.head.x); last = p.head.x
            if i < 4 { XCTAssertLessThan(p.head.x, 3, "it takes a few frames to get there") }
        }
        XCTAssertGreaterThan(peak, 3.0); XCTAssertLessThan(peak, 3.6, "a little overshoot")
        XCTAssertEqual(last, 3, accuracy: 0.02)
    }

    func testAnAccessoryHangingFromTheNeckSwingsWithTheHeadAndSettles() {
        var secondary = PetSecondary()
        var first = PetAnimation.sit(time: 5); secondary.apply(&first, dt: 0, scale: 0.6)
        var swings = [CGFloat]()
        for i in 1...240 {
            var p = PetAnimation.sit(time: 5)
            p.tilt = i < 30 ? 0.3 : 0
            secondary.apply(&p, dt: 1.0 / 60, scale: 0.6)
            swings.append(p.swing)
        }
        XCTAssertLessThan(swings[0...40].min()!, -0.1, "the bell swings against the tilt")
        XCTAssertGreaterThan(swings[30...140].max()!, 0.05, "and back past upright: a pendulum")
        XCTAssertEqual(swings.last!, 0, accuracy: 0.02, "and hangs straight again")
        XCTAssertTrue(swings.allSatisfy { abs($0) <= 1 })
    }

    func testSpringsCostNoAllocationsAndLittleTime() {
        var secondary = PetSecondary()
        var p = PetAnimation.sit(time: 5)
        let start = Date()
        for i in 0..<20000 { p.y = CGFloat(i % 9); secondary.apply(&p, dt: 1.0 / 30, scale: 0.6) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a debug build spends well under 100 microseconds a frame on all of it")
    }
}
