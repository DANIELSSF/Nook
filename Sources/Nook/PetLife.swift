import AppKit

/// How a cat carries itself: how wide its eyes rest, where its ears sit, how often it blinks and fidgets. It comes from who the cat
/// is (`PetPersonality`) and the hour of the day, and it is what makes a sleepy cat look sleepy even when it is doing nothing. The
/// curious cat in the daytime is the neutral one, exactly the cat Nook always had.
struct PetTemperament: Equatable {
    /// How open the eyes rest, against the plain cat's 1.
    var eyeOpen: CGFloat = 1
    /// Added to both ears' angle at rest: positive lays them back a little, negative pricks them.
    var earSet: CGFloat = 0
    /// The length of the slots in which a blink may fall, and how long a blink lasts.
    var blinkEvery = 7.0, blinkLength = 0.2
    /// How often the small movements (an ear, the tail, a look) come, against 1 for the plain cat.
    var fidget = 1.0
    /// How high the tail's tip rests.
    var tailLift: CGFloat = 0
    /// How high the cat carries its head and chest, in rig units: a sleepy one slumps, a playful one sits tall.
    var headLift: CGFloat = 0

    static func of(_ personality: PetPersonality, dayPart: PetDayPart = .day) -> PetTemperament {
        var t = PetTemperament()
        switch personality {
        case .curious: break
        case .playful: t.eyeOpen = 1.1; t.earSet = -0.08; t.blinkEvery = 6.0; t.blinkLength = 0.17; t.fidget = 1.35; t.tailLift = 2.4; t.headLift = 0.7
        case .calm: t.eyeOpen = 0.9; t.earSet = 0.04; t.blinkEvery = 8.0; t.blinkLength = 0.24; t.fidget = 0.8; t.headLift = -0.2
        case .sleepy: t.eyeOpen = 0.66; t.earSet = 0.13; t.blinkEvery = 9.0; t.blinkLength = 0.36; t.fidget = 0.55; t.tailLift = -2.0; t.headLift = -0.7
        }
        switch dayPart {
        case .night: t.eyeOpen *= 0.92; t.blinkLength *= 1.2; t.fidget *= 0.8; t.earSet += 0.03; t.headLift -= 0.2
        case .morning: t.fidget *= 1.1
        case .day, .evening: break
        }
        return t
    }
}

/// The small life laid over every pose: the blinks, a flick of an ear or of the tail's tip, a glance, a shift of weight, a sigh,
/// and while the terminal works the bursts of attention of a cat on duty. They are events at hashed moments of the clock, so they
/// never fall into a rhythm, and each is brief: between them the cat is nearly still, which is both how a cat sits and what keeps
/// the cost of drawing it low.
enum PetLife {
    /// Seconds between the small movements of the plain cat (each lands at a hashed moment of its slot): a calm cat's day has about a
    /// blink every 7 s, an ear a few times a minute, and a look, a flick of the tail, a shift of weight or a tilt of the head rarely.
    static let ear = 20.0, listen = 41.0, look = 22.0, flickEvery = 25.0, hook = 30.0, shift = 53.0, tilt = 45.0
    /// The same for a cat on duty while the terminal works.
    static let onDuty = (look: 12.0, ear: 11.0, tail: 16.0, paw: 26.0)

    struct Context {
        var time: Double
        var temperament = PetTemperament()
        /// 1 when the cat is at rest and these small movements are all it does; less while a gesture has the cat's body.
        var restful: CGFloat = 1
        /// How much of the small movements the user's work allows: the cat holds still while they type.
        var quiet: CGFloat = 1
        /// How often they come against the plain cat: more while the cat is free to be watched, fewer while the user types.
        var rate = 1.0
        /// The on-duty posture, 0...1.
        var alert: CGFloat = 0
        /// How big its breathing is against the plain cat's: it breathes less visibly while the user is busy.
        var breath: CGFloat = 1
        /// False for a cat that is asleep, dragged or hopping: nothing of this applies to it.
        var active = true
    }

    /// Where the cat carries itself: how wide its eyes rest, where its ears and the tip of its tail sit.
    private static func posture(_ p: inout PetPose, _ tm: PetTemperament, restful: CGFloat) {
        p.eyes *= 1 - (1 - tm.eyeOpen) * restful
        p.earL += tm.earSet * restful; p.earR += tm.earSet * restful
        p.tail.p3.y += tm.tailLift * restful; p.tail.c2.y += tm.tailLift * 0.5 * restful
        p.head.y += tm.headLift * restful; p.chest.ry += tm.headLift * 0.5 * restful
    }

    /// The cat at rest as a picture: how it carries itself and none of what it does (no blink, no flick), for the settings.
    static func resting(_ pose: PetPose, temperament: PetTemperament) -> PetPose {
        var p = pose
        posture(&p, temperament, restful: 1)
        return p
    }

    /// Lays the cat's life over `p`.
    static func apply(_ p: inout PetPose, _ c: Context) {
        guard c.active else { return }
        let t = c.time, tm = c.temperament
        let f = tm.fidget * c.rate
        let still = c.restful * c.quiet
        let any = c.restful * 0.45 + 0.55 * c.restful * c.quiet   // the face keeps its life a little even when the user is busy

        posture(&p, tm, restful: c.restful)
        if c.breath != 1, p.action == .sit {
            let b = CGFloat(sin(t * 1.7))
            p.chest.ry += (c.breath - 1) * 0.25 * b; p.head.y += (c.breath - 1) * 0.15 * b
        }

        // Blinks: the lid drops quickly and comes up more slowly; now and then there are two, close together.
        let blink = blinkClosure(t, period: tm.blinkEvery / c.rate, length: tm.blinkLength, salt: 1)
        p.eyes *= 1 - blink

        // The slow blink of a cat at ease.
        if let u = event(t, period: 61, length: 1.5, salt: 11), tm.fidget < 1.3 {
            p.eyes *= 1 - 0.9 * ramp(u, 0, 0.38) * (1 - ramp(u, 0.62, 1))
        }

        // An ear flicks, now one and now the other.
        if let u = event(t, period: ear / f, length: 0.4, salt: 3) {
            let twitch = CGFloat(sin(.pi * u)) * 0.45 * any
            if hash(Int(floor(t / (ear / f))), 9) < 0.5 { p.earL -= twitch } else { p.earR -= twitch }
        }
        // Listening: both ears swivel to something and the head tips.
        if let u = event(t, period: listen / f, length: 1.5, salt: 14) {
            let s = bump(u, 0, 1) * still
            p.earL -= 0.2 * s; p.earR += 0.12 * s; p.tilt += 0.04 * s
        }
        // A glance: the eyes go first, the head follows a moment later and comes back.
        if let u = event(t, period: look / f, length: 2.6, salt: 4) {
            let dir: CGFloat = hash(Int(floor(t / (look / f))), 8) < 0.5 ? -1 : 1
            let eyes = hold(u, 0.12, 0.85) * any, head = hold(u, 0.3, 0.8) * any
            p.look.x += dir * 1.5 * eyes; p.look.y += 0.35 * eyes
            p.head.x += dir * 0.55 * head; p.tilt += -dir * 0.07 * head
        }
        // The tail's tip flicks, and now and then curls slowly up and over.
        if let u = event(t, period: flickEvery / f, length: 0.8, salt: 2) {
            let flick = CGFloat(sin(u * .pi * 4)) * CGFloat(1 - u) * any
            p.tail.p3.y += 3.5 * flick; p.tail.p3.x += 1.5 * flick; p.tail.c2.y += 2 * flick
        }
        if let u = event(t, period: hook / f, length: 2.4, salt: 21) {
            let s = bump(u, 0, 1) * still
            p.tail.p3.y += 2.6 * s; p.tail.p3.x += 2.0 * s; p.tail.c2.y += 1.2 * s
        }
        // It shifts its weight, and once in a while sighs.
        if let u = event(t, period: shift / f, length: 1.8, salt: 17) {
            let dir: CGFloat = hash(Int(floor(t / (shift / f))), 18) < 0.5 ? -1 : 1
            let s = bump(u, 0, 1) * still
            p.haunch.cx += 0.55 * dir * s; p.chest.cx -= 0.25 * dir * s; p.head.x -= 0.2 * dir * s
        }
        if let u = event(t, period: 71, length: 2.6, salt: 19) {
            let s = bump(u, 0, 1) * c.restful
            p.chest.ry += 0.8 * s; p.head.y += 0.45 * s; p.earL += 0.06 * s; p.earR += 0.06 * s
        }
        if let u = event(t, period: tilt / f, length: 1.9, salt: 23) {
            let dir: CGFloat = hash(Int(floor(t / (tilt / f))), 24) < 0.5 ? -1 : 1
            p.tilt += dir * 0.1 * bump(u, 0, 1) * still
        }

        // On duty: it does not sway all the while, it watches. Bursts of attention come every few seconds: it looks to the right
        // where the activity is shown, an ear swivels, the tip of its tail taps, and a paw. While the user works at the keyboard the
        // taps are left out: they would be seen at the corner of the eye.
        if c.alert > 0 {
            let a = c.alert * c.restful
            let busy = c.quiet > 0.5 ? a : 0
            if let u = event(t, period: onDuty.look, length: 4, salt: 47) {
                let g = hold(u, 0.15, 0.85) * a
                p.look.x += 1.3 * g; p.look.y += 0.2 * g; p.tilt += -0.05 * g
            }
            if let u = event(t, period: onDuty.ear, length: 0.5, salt: 49) { p.earR -= 0.3 * CGFloat(sin(.pi * u)) * a }
            if let u = event(t, period: onDuty.tail, length: 1.1, salt: 41) {
                let tap = CGFloat(sin(u * .pi * 4)) * CGFloat(sin(u * .pi)) * busy
                p.tail.p3.y += 3 * tap; p.tail.p3.x += 2 * tap; p.tail.c2.y += 1.5 * tap
            }
            if let u = event(t, period: onDuty.paw, length: 0.8, salt: 43) {
                let tap = CGFloat(max(0, sin(u * .pi * 3))) * 2.2 * busy
                p.legs[3].foot.y += tap; p.legs[3].knee.y += tap * 0.6
            }
        }
    }

    /// How closed the lids are at `t`, 0...1, with the blinks of the slots of `period` seconds: asymmetric (down in a third of the
    /// time it takes to come up) and sometimes doubled.
    static func blinkClosure(_ t: Double, period: Double, length: Double, salt: Int) -> CGFloat {
        func shape(_ u: Double) -> CGFloat { u < 0.34 ? ramp(u, 0, 0.34) : 1 - ramp(u, 0.34, 1) }
        var closed: CGFloat = 0
        if let u = event(t, period: period, length: length, salt: salt) { closed = shape(u) }
        // The second of a double blink follows the first by a heartbeat, in one slot in five.
        let echo = t - (length + 0.13)
        if hash(Int(floor(echo / period)), salt + 5) < 0.2, let u = event(echo, period: period, length: length, salt: salt) { closed = max(closed, shape(u)) }
        return closed
    }

    /// What the small movements ask of the frame rate: the seconds until the next one begins (so a frame can be drawn just as it
    /// starts instead of up to a whole resting interval late), and how much longer a quick one that is already under way lasts (a
    /// blink, a flick: they have to be drawn in several frames or they are not seen at all). The slow ones (a look, a sigh) need
    /// neither: how far they move between frames is all that paces them. They ease in from stillness, so a tick at the instant one
    /// starts finds nothing to draw: announcing them would only wake the Mac once more for each (a dozen times a minute).
    static func timing(_ c: Context) -> (due: Double, busyFor: Double) {
        let t = c.time, tm = c.temperament, f = tm.fidget * c.rate, blinkEvery = tm.blinkEvery / c.rate
        var soonest = Double.infinity, busy = 0.0
        func consider(_ period: Double, _ length: Double, _ salt: Int, quick: Bool = false, announced: Bool? = nil) {
            if quick, let u = event(t, period: period, length: length, salt: salt) { busy = max(busy, (1 - u) * length) }
            guard announced ?? quick else { return }
            let n = Int(floor(t / period))
            for k in 0...1 {
                let slot = n + k
                let start = Double(slot) * period + hash(slot, salt) * (period - length)
                if start > t { soonest = min(soonest, start - t); return }
            }
        }
        consider(blinkEvery, tm.blinkLength, 1, announced: true)
        // A blink, and the second of a double one that follows it by a heartbeat: the lid is drawn in a few frames all through, and
        // the second one gets a frame as it begins.
        let length = tm.blinkLength, n = Int(floor(t / blinkEvery))
        for slot in [n - 1, n] {
            let first = Double(slot) * blinkEvery + hash(slot, 1) * (blinkEvery - length)
            let double = hash(slot, 6) < 0.2
            let second = first + length + 0.13
            let end = double ? second + length : first + length
            if t >= first, t < end { busy = max(busy, end - t) }
            if double, second > t { soonest = min(soonest, second - t) }
        }
        consider(ear / f, 0.4, 3, quick: true); consider(flickEvery / f, 0.8, 2, quick: true)
        consider(look / f, 2.6, 4); consider(listen / f, 1.5, 14); consider(shift / f, 1.8, 17); consider(tilt / f, 1.9, 23); consider(hook / f, 2.4, 21)
        if c.alert > 0 {
            consider(onDuty.look, 4, 47); consider(onDuty.ear, 0.5, 49, quick: true)
            if c.quiet > 0.5 { consider(onDuty.tail, 1.1, 41, quick: true); consider(onDuty.paw, 0.8, 43, quick: true) }
        }
        return (soonest, busy)
    }

    private static func event(_ t: Double, period: Double, length: Double, salt: Int) -> Double? { PetAnimation.event(t, period: period, length: length, salt: salt) }
    private static func hash(_ n: Int, _ salt: Int) -> Double { PetAnimation.hash(n, salt) }
    private static func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { PetAnimation.ramp(t, a, b) }
    private static func hold(_ u: Double, _ a: Double, _ b: Double) -> CGFloat { PetAnimation.hold(u, a, b) }
    private static func bump(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { PetAnimation.bump(t, a, b) }
}
