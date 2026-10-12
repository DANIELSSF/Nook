import AppKit

// The cat that sleeps when Nook opens at night, and the way any sleeping cat wakes.
//
//   PetBedtime         whether the cat went to bed because Nook started at night, and until what wakes it: a click, or the lights coming on. Plain state on a clock it is
//                      handed (nothing here knows about a window); the running app starts it (`AppDelegate`), so no test or preview ever starts asleep
//   PetAnimation       `waking`, the pose of a cat waking up gently, and the still pose of a cat asleep
//   PetBedtimeFollower what each cat's view does with the bedtime on each tick: goes to bed when it is bedtime, and wakes (gently if it happened just now, at once if it
//                      happened out of its sight) when something woke the cat
//
// Every cat is the same cat: the one in the notch, the one in the header and the one on the home all follow the same bedtime, so a cat woken in one place is awake in the others.
// A cat that sleeps for any other reason (its own naps, `PetDirector.Kind.nap`) wakes the same way when it is clicked.

// MARK: - Bedtime

final class PetBedtime {
    /// What woke the cat.
    enum Reason: Equatable {
        /// A click on the cat.
        case click
        /// The island turned light: the cat squints at it.
        case light
        /// The greeting needs the cat awake to wave.
        case greeting
    }

    /// The hours the cat is put to bed at: the pet system's own night (`PetDayPart.night`).
    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        PetDayPart.of(hour: calendar.component(.hour, from: date)) == .night
    }

    /// How long after Nook starts the light of the island may still be settling into the user's theme (the window takes its appearance as the island first shows):
    /// a change of light within it is not the user's hand on a switch.
    static let settling = 3.0

    /// The cat is asleep because Nook started at night, and nothing has woken it.
    private(set) var isAsleep = false
    /// How many times it has been woken, and when (the clock's seconds) and why the last time: a cat's view that sees the number change knows what happened.
    private(set) var wakes = 0
    private(set) var wokeAt = 0.0
    private(set) var reason: Reason?
    private let clock: () -> Double
    private var launchedAt: Double
    /// Whether the island's light was dark when it was last looked at.
    private var dark: Bool?

    /// `clock` gives seconds (the system's uptime in the app). A bedtime starts awake: `launch(at:)` puts the cat to bed.
    init(asleep: Bool = false, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        isAsleep = asleep
        launchedAt = clock()
    }

    /// Nook has just started: the cat goes to bed if it is night, and stays up otherwise.
    func launch(at date: Date = Date(), calendar: Calendar = .current) {
        launchedAt = clock()
        isAsleep = Self.isNight(date, calendar: calendar)
        wakes = 0; reason = nil
    }

    /// The cat is woken. Returns whether it was asleep: a cat that is up has nothing to wake.
    @discardableResult
    func wake(_ reason: Reason = .click) -> Bool {
        guard isAsleep else { return false }
        isAsleep = false
        wakes += 1
        wokeAt = clock()
        self.reason = reason
        return true
    }

    /// A click on the cat: wakes it if it is asleep.
    @discardableResult
    func click() -> Bool { wake(.click) }

    /// The light of the island is `dark` (a cat's view says so whenever its window's appearance changes). The lights coming on wake a sleeping cat; the lights going out never put
    /// one to sleep. The first look, and any in the first seconds after launch, only note how things are.
    func lights(dark now: Bool) {
        defer { dark = now }
        guard let before = dark, before, !now, clock() - launchedAt >= Self.settling else { return }
        wake(.light)
    }
}

// MARK: - Following it

/// What a cat's view does with the bedtime on each tick. The cat goes to bed when it is bedtime (and stays there across the island opening and closing: `PetDirector.settle` does
/// not wake it), and when it is woken it wakes: gently, from the beat it should be at, if that happened a moment ago; at once, if it happened while this cat was out of sight.
struct PetBedtimeFollower {
    private var wakes = 0

    /// Brings `player` in line with `bedtime` at `now` (the clock the bedtime was handed). Returns whether anything changed.
    @discardableResult
    mutating func follow(_ bedtime: PetBedtime?, player: inout PetPlayer, now: Double) -> Bool {
        guard let bedtime else { return false }
        defer { wakes = bedtime.wakes }
        if bedtime.isAsleep {
            guard !player.isPinnedAsleep else { return false }
            player.fallAsleep()
            return true
        }
        guard bedtime.wakes != wakes, player.isPinnedAsleep else { return false }
        player.wake(age: max(0, now - bedtime.wokeAt), squint: bedtime.reason == .light ? 1 : 0)
        return true
    }
}

// MARK: - The pose

/// The beats of a gentle waking, in seconds from the moment the cat is woken: the same sequence the website's cat wakes with, about four seconds in all. A cat woken by the light
/// squints for a second first (`squintLead`), and then wakes the same way. Everything the cat does is one of the cat's own poses (`PetAnimation.loaf`, `bow`, `arch`, the stand,
/// `sit`) and the face of its own yawn, blended the way its own stretch blends them (`perform(.stretch)`): the cat is the same cat in every frame.
enum PetWakeBeats {
    /// With the light in its eyes the cat squints first, for this long: ears back, head tucked.
    static let squintLead = 1.0
    /// An ear flicks, and again.
    static let earFlick = 0.04...0.36
    static let earFlickAgain = 0.38...0.70
    /// The z's of the dream are gone by this time.
    static let zFade = 0.8
    /// How open the eyes are, by time: open a little (0.55) from 0.3 to 0.95, sink again (0.1) by 1.6, open (0.9) by 2.0, and wide by 2.6.
    static let eyes: [(Double, CGFloat)] = [(0, 0), (0.3, 0), (0.95, 0.55), (1.2, 0.55), (1.6, 0.1), (2.0, 0.9), (2.6, 1)]
    /// Lying, the head comes up a little.
    static let lyingUp = 0.5...1.4
    /// The stretch: it rises into the bow (the front legs forward, the rear up), arches its back out of it, and comes back to a stand.
    static let bow = 1.4...2.2
    static let arch = 2.4...2.95
    static let standUp = 2.95...3.25
    /// The yawn: the mouth opens as it rises into the bow and holds through the arch, and closes as it comes back to a stand.
    static let yawnOpens = 2.0...2.45
    static let yawnCloses = 2.95...3.3
    /// Sitting back down (legs first, as the cat's own stretch ends), and the slow blink of a cat that has settled.
    static let sitting = 3.05...3.75
    static let slowBlink = 3.45...3.97
    static let length = 4.0
}

extension PetAnimation {
    /// How long the waking lasts: four seconds, and the second of squinting before it for a cat woken by the light (`squint` > 0).
    static func wakeLength(squint: CGFloat = 0) -> Double { PetWakeBeats.length + (squint > 0 ? PetWakeBeats.squintLead : 0) }

    /// The cat `u` seconds after it was woken, from the nap it was in (`sleptAge` seconds into one `sleptLength` long: the pose it is waking from) to the idle sit. It does not sit up at
    /// once: an ear flicks twice, its eyes open slowly (a crack, a heavy lid sinking again, then open), its head comes up and it stretches (front legs out and the rear up, then the
    /// back arched, as its own stretch does), yawns as it does, comes back to a stand, sits down and, settled, blinks slowly. `squint` (0...1) is a cat woken by the light: it squints
    /// first for a second (ears back, head tucked) and wakes the same way. Facing right; a cat that lay facing left is mirrored by the caller. Every beat begins where the one before
    /// ended: it begins at the nap's own pose and ends at the sit.
    static func waking(u raw: Double, time t: Double, sleptAge: Double, sleptLength: Double, squint: CGFloat = 0) -> PetPose {
        let beats = PetWakeBeats.self
        let lead = squint > 0 ? beats.squintLead : 0
        let u = raw - lead
        let asleep = perform(.sleep, u: sleptAge, length: sleptLength, time: t, facing: 1, alert: 0)
        func span(_ r: ClosedRange<Double>) -> CGFloat { ramp(u, r.lowerBound, r.upperBound) }

        // The glare: the cat flinches (the head lifts for a moment, an eye cracks open and shuts again), and tucks against it: ears back, head down, eyes slits, the dream's z's gone.
        // It holds that through the squint and lets go of it over the first second of the waking. Every number is within what the cat's own poses use (a nap's ears are 0.45).
        let glare = squint * (raw < lead ? ramp(raw, 0.08, 0.45) : 1 - ramp(u, 0, 0.9))
        let flinch = squint * bump(raw, 0, 0.36)
        func squinting(_ p: PetPose) -> PetPose {
            guard glare > 0 || flinch > 0 else { return p }
            var q = p
            q.earL += 0.2 * glare; q.earR += 0.2 * glare
            q.head.y += 0.8 * flinch - 0.5 * glare
            q.tilt -= 0.05 * glare
            q.eyes = max(q.eyes * (1 - 0.5 * glare), 0.2 * glare) + 0.25 * flinch
            q.zAlpha *= 1 - squint * ramp(raw, 0, 0.3)
            return q
        }
        // The squint before the waking: the sleeper, scrunched against the light.
        if u < 0 { return squinting(asleep) }

        let lying = loaf(rest: 0, curl: 0, time: t)
        let seated = sit(time: t)
        // Lying: the head comes up a little. An ear flicks, and flicks again.
        var p = asleep.staged(to: lying, 0.55 * span(beats.lyingUp))
        p.earR -= 0.55 * bump(u, beats.earFlick.lowerBound, beats.earFlick.upperBound) + 0.4 * bump(u, beats.earFlickAgain.lowerBound, beats.earFlickAgain.upperBound)
        // The stretch, as the cat's own does it: the bow, the arch out of it, the stand it comes back to. It rises into the bow from lying, and sits down from the stand (legs first).
        let archAmount = span(beats.arch), standAmount = span(beats.standUp)
        let shiver = archAmount * (1 - standAmount) * CGFloat(sin(t * 38)) * ramp(u, beats.arch.lowerBound + 0.15, beats.arch.lowerBound + 0.35)
        let up = bow(time: t), hooked = arch(time: t, tremble: shiver), standing = walk(phase: 0, amp: 0, time: t)
        var stretch = up.blended(to: hooked, archAmount).blended(to: standing, standAmount)
        // The tail swings from up to hooked down and back up (a blend would slide its points across and fold it into a stub on the way).
        stretch.tail = up.tail.swung(to: hooked.tail, archAmount).swung(to: standing.tail, standAmount)
        let rise = span(beats.bow)
        if rise > 0 {
            // Its parts rise together (the rear lifts as the front reaches out), and the tail lifts off the floor by swinging.
            let lying = p.tail
            p = p.blended(to: stretch, rise)
            p.tail = lying.swung(to: stretch.tail, rise)
        }
        p = p.staged(to: seated, span(beats.sitting), order: .legsFirst)
        // The yawn, through the stretch, with the amplitudes of the cat's own yawn (`yawn(u:)`): the mouth opens, the head tips up, the ears go back and the eyes squeeze shut.
        let yawn = span(beats.yawnOpens) * (1 - span(beats.yawnCloses))
        p.mouth = 0.97 * yawn
        p.head.y += 1.3 * yawn; p.headScale += 0.035 * yawn
        p.earL += 0.28 * yawn; p.earR += 0.28 * yawn
        // The eyes, in fits: they open and sink and open; squeezed shut by the yawn; and the slow blink at the end.
        var eyes = keyframe(u, beats.eyes)
        eyes *= 1 - 0.94 * yawn
        eyes *= 1 - 0.96 * bump(u, beats.slowBlink.lowerBound, beats.slowBlink.upperBound)
        p.eyes = asleep.eyes + (1 - asleep.eyes) * eyes
        // The z's thin out at once.
        p.zAlpha = asleep.zAlpha * (1 - ramp(u, 0, beats.zFade))
        p.action = u < beats.bow.lowerBound ? .sleep : .stretch
        if u >= beats.length { return seated }
        return squinting(p)
    }

    /// The pose of a sleeping cat that is not allowed to move (Reduce Motion, the animations off): curled up, its eyes shut, a few z's.
    static func asleepPose() -> PetPose {
        var p = loaf(rest: 1, curl: 1, time: 0, asleep: 1)
        p.zAlpha = 0.6; p.zRise = 0.35
        return p
    }
}

extension PetTail {
    /// Swings toward `o` about its root, each control point keeping its distance from it (blended) and turning the shorter way round, rather than sliding across to where it is in
    /// `o`: a slide takes a tail that goes from up to down through a stub, a swing takes it through the way a tail goes. Halfway it is `curl` shorter (it curls a little as it swings),
    /// which keeps a tail that goes straight out behind the cat inside the room the cat has.
    func swung(to o: PetTail, _ t: CGFloat, curl: CGFloat = 0.3) -> PetTail {
        let root = CGPoint(x: p0.x + (o.p0.x - p0.x) * t, y: p0.y + (o.p0.y - p0.y) * t)
        let shorter = 1 - curl * CGFloat(sin(Double(t) * .pi))
        func swing(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let va = CGPoint(x: a.x - p0.x, y: a.y - p0.y), vb = CGPoint(x: b.x - o.p0.x, y: b.y - o.p0.y)
            let from = atan2(va.y, va.x)
            var turn = atan2(vb.y, vb.x) - from
            if turn > .pi { turn -= 2 * .pi } else if turn < -.pi { turn += 2 * .pi }
            let radius = (hypot(va.x, va.y) + (hypot(vb.x, vb.y) - hypot(va.x, va.y)) * t) * shorter, angle = from + turn * t
            return CGPoint(x: root.x + radius * cos(angle), y: root.y + radius * sin(angle))
        }
        return PetTail(p0: root, c1: swing(c1, o.c1), c2: swing(c2, o.c2), p3: swing(p3, o.p3), width: width + (o.width - width) * t)
    }
}
