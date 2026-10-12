import AppKit

/// Which way the pointer pulls the cat's attention, as the rig wants it: each axis -1...1, clamped, so a pointer
/// at any distance or direction (or none at all) can only ever produce a mild, bounded turn of the head.
struct PetGaze: Equatable {
    var dx: CGFloat = 0, dy: CGFloat = 0
    init(dx: CGFloat = 0, dy: CGFloat = 0) {
        func tame(_ v: CGFloat) -> CGFloat { v.isFinite ? min(1, max(-1, v)) : 0 }
        self.dx = tame(dx); self.dy = tame(dy)
    }
}

extension PetPose {
    /// Which end of the body leads a change of pose.
    enum Order { case headFirst, legsFirst }

    /// Blends toward `o` in stages so a turn reads as anticipation instead of a slide: the head and eyes
    /// lead, then the torso, then legs and tail (`legsFirst` runs it backwards, as a walker settling into a sit).
    func staged(to o: PetPose, _ t: CGFloat, order: Order = .headFirst) -> PetPose {
        let t = min(1, max(0, t))
        func part(_ a: CGFloat, _ b: CGFloat) -> CGFloat { PetAnimation.smooth(Double((t - a) / (b - a))) }
        let (head, body, legs, tail) = order == .headFirst ? (part(0, 0.5), part(0.1, 0.75), part(0.2, 0.9), part(0.1, 1)) : (part(0.5, 1), part(0.25, 0.9), part(0, 0.7), part(0, 1))
        var r = blended(to: o, body)
        let h = blended(to: o, head), l = blended(to: o, legs), tl = blended(to: o, tail)
        r.head = h.head; r.headScale = h.headScale; r.tilt = h.tilt; r.earL = h.earL; r.earR = h.earR; r.eyes = h.eyes; r.look = h.look; r.mouth = h.mouth
        r.legs = l.legs; r.tail = tl.tail
        if t >= 0.5 { r.action = o.action; r.facing = o.facing } else { r.action = action; r.facing = facing }
        return r
    }
}

/// The ways the cat can cheer when a task finishes. The cat's temperament picks one.
enum PetCheer: Equatable { case hop, doubleHop, content }

extension PetAnimation {
    // MARK: Squash

    /// Crouch and landing compression: the body sinks onto its feet and widens a little, the head dips and the
    /// ears fold back. `c` 0...1 (a landing goes a little past 1).
    static func squash(_ p: PetPose, _ c: CGFloat, ears: CGFloat = 0.18) -> PetPose {
        var r = p
        r.haunch.ry -= 1.4 * c; r.haunch.cy -= 1.4 * c; r.haunch.rx += 0.6 * c
        r.chest.ry -= 1.0 * c; r.chest.cy -= 2.0 * c
        r.head.y -= 2.7 * c
        r.earL += ears * c; r.earR += ears * c
        r.tail.p3.y -= 1.6 * c; r.tail.c2.y -= 1.0 * c
        r.legs[1].foot.x -= 0.4 * c; r.legs[3].foot.x += 0.4 * c
        return r
    }

    // MARK: Curious

    /// The cat noticing the pointer: it looks at it, tips its head a little and sniffs. Only the head, eyes and
    /// ears move, within small fixed limits, so the body and the place that is clicked stay exactly where they were.
    /// Left alone with the pointer for a while it settles, and now and then gives the slow blink cats keep for those they trust.
    /// - Parameters:
    ///   - base: the cat as it was (a calm sit).
    ///   - amount: 0...1, how far it has turned toward the pointer.
    ///   - age: seconds since it noticed, which times the sniffs.
    ///   - sniff: false when something else (a drag) is what it watches, so it stares without sniffing.
    static func curious(_ base: PetPose, gaze: PetGaze, amount: CGFloat, age: Double, sniff: Bool = true) -> PetPose {
        guard amount > 0 else { return base }
        var p = base
        p.action = .curious
        // Always tipped a little to one side, toward the pointer when it is clearly to one side.
        var lean = gaze.dx
        if abs(lean) < 0.35 { lean = lean < 0 ? -0.35 : 0.35 }
        p.look.x = base.look.x + 2.0 * gaze.dx; p.look.y = base.look.y + 1.1 * gaze.dy
        p.head.x += 1.3 * gaze.dx; p.head.y += 0.7 * max(0, gaze.dy)
        p.tilt = base.tilt - 0.14 * lean
        // Both ears come forward; the one on the pointer's side turns more.
        p.earL -= 0.16 + (gaze.dx < 0 ? 0.2 * -gaze.dx : 0); p.earR -= 0.16 + (gaze.dx > 0 ? 0.2 * gaze.dx : 0)
        p.eyes *= 1.12; p.headScale *= 1.02
        if sniff {
            // Three quick pulses of the nose: the head lifts and nudges forward, the eyes narrow a touch.
            let q = (age - 0.3) / 0.2
            if q >= 0, q < 3 {
                let pulse = CGFloat(sin((q - floor(q)) * .pi))
                p.head.y += 1.0 * pulse; p.head.x += 0.5 * pulse * (lean >= 0 ? 1 : -1)
                p.headScale += 0.02 * pulse; p.eyes *= 1 - 0.25 * pulse
                p.earL -= 0.04 * pulse; p.earR -= 0.04 * pulse
            }
            // The slow blink: the lids come down over half a second, rest, and rise again, every eight seconds or so.
            let slow = age - slowBlinkAfter
            if slow > 0 {
                let local = slow.truncatingRemainder(dividingBy: slowBlinkEvery)
                p.eyes *= 1 - 0.92 * ramp(local, 0, 0.55) * (1 - ramp(local, 0.8, 1.45))
            }
        }
        return base.blended(to: p, amount)
    }
    /// How long the pointer has to linger before the first slow blink, and how often it comes after that.
    static let slowBlinkAfter = 2.6, slowBlinkEvery = 8.0

    // MARK: Grooming

    static let groomLength = 2.7

    /// Sitting, the cat lifts the near front paw to its mouth, licks it and wipes its face twice, eyes half
    /// closed and head tipped toward the paw; `u` seconds in. Rises and lowers within `groomLength`. Variant 1 washes its chest
    /// instead: the head dips down to it and bobs with each lick.
    static func groom(u: Double, time t: Double, alert: CGFloat = 0, variant: Int = 0) -> PetPose {
        let d = groomLength
        var p = sit(time: t, alert: alert)
        p.action = .groom
        let raise = ramp(u, 0, 0.5) * (1 - ramp(u, d - 0.55, d))
        if variant == 1 {
            // Three long licks down the chest, the head going down and a little forward with each.
            let dip = ramp(u, 0, 0.55) * (1 - ramp(u, d - 0.6, d))
            let lick = u >= 0.7 && u < d - 0.6 ? CGFloat(sin((u - 0.7) / 0.43 * 2 * .pi)) : 0
            p.head.y -= 3.4 * dip + 0.55 * max(0, lick) * dip; p.head.x += 0.5 * dip
            p.tilt += 0.07 * dip + 0.05 * lick * dip
            p.eyes = min(p.eyes, 1 - 0.88 * dip)
            p.earL += 0.12 * dip; p.earR += 0.12 * dip
            p.chest.ry -= 0.5 * dip; p.chest.cy -= 0.5 * dip
            p.headScale -= 0.02 * dip
            return p
        }
        // Two short licks at the mouth, then two slow wipes up the cheek and back.
        let lick = u >= 0.5 && u < 1.05 ? CGFloat(sin((u - 0.5) / 0.55 * 2 * .pi * 2)) : 0
        let w = (u - 1.05) / 0.55
        let wipe: CGFloat = w >= 0 && w < 2 ? CGFloat((1 - cos(w * 2 * .pi)) / 2) : 0
        let mouth = PetLimb(CGPoint(x: 4.6, y: 11.4), CGPoint(x: 9.4, y: 12.6), CGPoint(x: 3.6, y: 15.8), 3.4)
        var arm = p.legs[3].blended(to: mouth, raise)
        // The wipe carries the paw up along the outside of the cheek; the elbow follows.
        arm.foot.x += 6.0 * wipe * raise; arm.foot.y += 6.2 * wipe * raise
        arm.knee.x += 1.4 * wipe * raise; arm.knee.y += 2.2 * wipe * raise
        arm.foot.y += 0.35 * lick * raise
        p.legs[3] = arm
        p.tilt += -0.13 * raise - 0.04 * wipe * raise
        p.head.x += 0.7 * raise; p.head.y += (-0.55 * raise) - 0.35 * max(0, lick) * raise
        p.eyes = min(p.eyes, 1 - 0.8 * raise)
        p.earL += 0.1 * raise; p.earR += 0.2 * raise
        p.chest.cx += 0.3 * raise
        return p
    }

    // MARK: Glancing

    static let glanceLength = 3.4

    /// A quiet look from the sit; only the face moves, so it can go on while the user types or reads. `u` seconds in.
    /// Variant 0 looks round, to one side and then the other, an ear following each; 1 and 2 listen to something off to the
    /// right or the left (the ears swivel to it, the head turns, a twitch); 3 follows something small across the sky.
    static func glance(u: Double, time t: Double, alert: CGFloat = 0, variant: Int = 0) -> PetPose {
        var p = sit(time: t, alert: alert)
        p.action = .glance
        switch variant {
        case 1, 2:
            let dir: CGFloat = variant == 1 ? 1 : -1
            let h = hold(u / glanceLength, 0.14, 0.7)
            // The ears get there first and the eyes a moment before the head.
            let ears = ramp(u, 0, 0.3) * (1 - ramp(u, 2.4, 3.0))
            p.look.x += 1.7 * dir * ramp(u, 0.05, 0.4) * (1 - ramp(u, 2.5, 3.1))
            p.head.x += 0.9 * dir * h; p.tilt += -0.1 * dir * h
            if dir > 0 { p.earR -= 0.4 * ears; p.earL += 0.12 * ears } else { p.earL -= 0.4 * ears; p.earR += 0.12 * ears }
            p.eyes *= 1 + 0.08 * ears
            // The ear nearest the sound twitches once while it listens.
            let flick = CGFloat(sin(max(0, min(1, (u - 1.3) / 0.45)) * .pi * 2)) * ears
            if dir > 0 { p.earR -= 0.12 * flick } else { p.earL -= 0.12 * flick }
        case 3:
            // Up and across: the chin lifts, the eyes track something drifting from one side to the other, the ears follow it.
            let h = ramp(u, 0, 0.5) * (1 - ramp(u, 2.7, glanceLength))
            let across = ramp(u, 0.5, 2.3) * 2 - 1
            p.head.y += 1.2 * h; p.look.y += 1.0 * h; p.look.x += 1.7 * across * h
            p.head.x += 0.8 * across * h; p.tilt += -0.1 * across * h
            p.earL -= 0.2 * h; p.earR -= 0.2 * h; p.eyes *= 1 + 0.08 * h
        default:
            let side = keyframe(u, [(0, 0), (0.45, 1), (1.4, 1), (1.95, -1), (2.9, -1), (glanceLength, 0)])
            p.look.x += 1.9 * side; p.look.y += 0.2 * abs(side)
            p.head.x += 0.9 * side
            p.tilt += -0.08 * side
            p.earR -= 0.14 * max(0, side); p.earL -= 0.14 * max(0, -side)
            p.eyes *= 1 + 0.06 * abs(side)
        }
        return p
    }

    // MARK: Peeking

    static let peekLength = 5.0

    /// Where the whole cat sits, in rig units, at each beat of a peek, for a ledge at `ledge` (the lowest visible y).
    /// Hidden, then the ears, then the face; the body is always behind the ledge.
    static func peekHeights(ledge: CGFloat) -> (hidden: CGFloat, ears: CGFloat, face: CGFloat) {
        let head = PetPose().head.y
        return (ledge - head - 15, ledge + 5 - head - 12.2, ledge + 4.6 - head)
    }

    /// The cat ducks behind the edge of the island (`ledge`), then comes up: first the ears, then the face, with
    /// a paw hooked over the edge, looks around and slips back out. `u` seconds in; whatever is below
    /// `ledge` is cut by the mask the view draws with.
    static func peek(u: Double, time t: Double, ledge: CGFloat, shift: CGFloat = 3.5) -> PetPose {
        let heights = peekHeights(ledge: ledge)
        let keys: [(Double, CGFloat)] = [(0, 0), (0.6, heights.hidden), (0.9, heights.hidden), (1.4, heights.ears), (2.1, heights.ears), (2.65, heights.face), (3.95, heights.face), (peekLength, 0)]
        var p = sit(time: t)
        p.action = .peek
        p.y = keyframe(u, keys)
        // While sunk it slides a little sideways, out of the island's rounded corner, unseen behind the edge.
        p.x = keyframe(u, [(0, 0), (0.6, shift), (4.3, shift), (peekLength, 0)])
        let ducking = ramp(u, 0, 0.4) * (1 - ramp(u, 0.7, 1.1))
        let earsUp = ramp(u, 1.0, 1.4) * (1 - ramp(u, 4.0, 4.6))
        let face = ramp(u, 2.2, 2.7) * (1 - ramp(u, 3.7, 4.2))
        // Eyes down while ducking, wide when the ears first come up, curious at the edge.
        p.look.y += -1.0 * ducking
        p.eyes *= 1 + 0.1 * earsUp
        p.earL -= 0.1 * earsUp; p.earR -= 0.1 * earsUp
        // The ears twitch while only they show.
        if u > 1.5, u < 2.0 { let k = CGFloat(sin((u - 1.5) / 0.5 * .pi * 3)); p.earL -= 0.3 * k; p.earR += 0.15 * k }
        // Looks left, then right, then back.
        let around = ramp(u, 2.7, 3.0) * (1 - ramp(u, 3.5, 3.9))
        let sweep = CGFloat(sin((u - 2.7) / 1.0 * .pi * 2))
        p.look.x += 1.8 * sweep * around; p.head.x += 1.0 * sweep * around; p.tilt += -0.1 * sweep * around
        // The paw hooks over the edge and taps it twice.
        let paw = ramp(u, 2.8, 3.1) * (1 - ramp(u, 3.65, 3.95))
        let tap = u >= 3.1 && u < 3.7 ? CGFloat(sin((u - 3.1) / 0.3 * .pi)) : 0
        let edge = ledge - heights.face
        let hook = PetLimb(CGPoint(x: 4.4, y: 11), CGPoint(x: 8.8, y: edge + 1.5), CGPoint(x: 10.6, y: edge + 3.4 + 1.5 * tap), 3.6)
        p.legs[3] = p.legs[3].blended(to: hook, paw * face)
        return p
    }

    // MARK: Celebration

    static let celebrateLength = 1.25

    /// How long each way of cheering lasts.
    static func cheerLength(_ style: PetCheer) -> Double {
        switch style { case .hop: celebrateLength; case .doubleHop: 2.0; case .content: 2.3 }
    }

    /// A finished task. The hop is one small jump: a little crouch, the jump with a cheer, a soft landing and a glint. `hop` is the
    /// height in rig units (about 0.6 point at the notch's scale per unit). The double hop is two, the second higher. The content
    /// cheer stays put: it sits up tall, squints with pleasure, and its tail rises in a slow curl.
    static func celebrate(u: Double, time t: Double, hop: CGFloat = 4, style: PetCheer = .hop) -> PetPose {
        switch style {
        case .hop: return hopping(u: u, time: t, hops: [(0, hop)], end: celebrateLength)
        case .doubleHop: return hopping(u: u, time: t, hops: [(0, hop * 0.7), (0.85, hop * 1.15)], end: cheerLength(.doubleHop))
        case .content:
            var p = sit(time: t)
            p.action = .celebrate
            let pleased = ramp(u, 0, 0.5) * (1 - ramp(u, 1.6, 2.3))
            p.head.y += 1.1 * pleased + 0.25 * CGFloat(sin(u * 3.2)) * pleased; p.chest.ry += 0.7 * pleased; p.headScale += 0.02 * pleased
            p.eyes *= 1 - 0.74 * pleased
            p.earL -= 0.16 * pleased; p.earR -= 0.16 * pleased
            p.tilt += -0.07 * pleased
            // The tail rises in a curl, its tip swaying slowly.
            let curl = ramp(u, 0.1, 0.8) * (1 - ramp(u, 1.7, 2.3))
            p.tail.p3 = lerp(p.tail.p3, CGPoint(x: -9.0 + 1.6 * CGFloat(sin(u * 3.4)), y: 25.5), curl)
            p.tail.c2 = lerp(p.tail.c2, CGPoint(x: -17.5, y: 17.5), curl)
            p.sparkle = u > 0.5 && u < 1.7 ? CGFloat((u - 0.5) / 1.2) : 0
            return p
        }
    }

    /// A string of hops (`start` seconds in, and how high), the crouch before each, the soft landing after, the joy that squeezes the
    /// eyes shut over all of them, and the glint at the end. One hop of `celebrateLength` is the cat's usual cheer.
    private static func hopping(u: Double, time t: Double, hops: [(start: Double, height: CGFloat)], end: Double) -> PetPose {
        var p = sit(time: t)
        p.action = .celebrate
        var squashing: CGFloat = 0, landed: CGFloat = 0, lift: CGFloat = 0, air: CGFloat = 0
        for hop in hops {
            let local = u - hop.start
            let crouch = ramp(local, 0, 0.22) * (1 - ramp(local, 0.22, 0.31))
            let flight = (local - 0.30) / 0.46
            let flying: CGFloat = flight > 0 && flight < 1 ? CGFloat(4 * flight * (1 - flight)) : 0
            let landing = ramp(local, 0.74, 0.86) * (1 - ramp(local, 0.86, 1.12))
            squashing += crouch + 1.25 * landing; landed += landing; lift += hop.height * flying; air = max(air, flying)
        }
        // Eyes squeezed shut with joy and ears up from the push-off until the cat has settled.
        let joy = ramp(u, 0.26, 0.4) * (1 - ramp(u, end - 0.3, end - 0.05))
        p = squash(p, min(1.4, squashing), ears: 0.18 + 0.1 * min(1, landed))
        p.y = lift
        p.chest.ry += 0.7 * air; p.head.y += 1.1 * air
        p.eyes *= 1 - 0.78 * joy
        p.earL -= 0.2 * joy; p.earR -= 0.2 * joy
        p.tilt += -0.08 * joy
        p.tail.p3.y += 5 * joy; p.tail.c2.y += 3 * joy; p.tail.p3.x += 1.2 * joy
        // A cheer: the front paws reach up and out beside the head while airborne.
        p.legs[3] = p.legs[3].blended(to: PetLimb(CGPoint(x: 4.2, y: 11), CGPoint(x: 8.4, y: 12.4), CGPoint(x: 11.6, y: 17.2), 3.3), air)
        p.legs[1] = p.legs[1].blended(to: PetLimb(CGPoint(x: -4.2, y: 11), CGPoint(x: -8.4, y: 12.4), CGPoint(x: -11.6, y: 17.2), 3.3), air)
        // Hind legs trail below the body in the air.
        for i in [0, 2] { p.legs[i].foot.y -= 1.2 * air }
        let glint = (hops.last?.start ?? 0) + 0.4
        p.sparkle = u > glint && u < end - 0.13 ? CGFloat((u - glint) / (end - 0.13 - glint)) : 0
        return p
    }

    // MARK: Landing

    static let landLength = 1.0

    /// Put down again after being carried: it drops from `drop` rig units up with its legs still dangling,
    /// lands in a soft squash, blinks and settles. The hop of the celebration is the same machinery.
    static func land(u: Double, time t: Double, drop: CGFloat = 9) -> PetPose {
        let fall = 0.3
        let s = min(1, max(0, u / fall))
        var air = lifted(time: t)
        // The tail only trails a little: it must not swing into place from the carried pose in a few frames.
        air.tail = sit(time: t).tail
        var p = air.blended(to: sit(time: t), ramp(u, 0.1, fall))
        p.action = .land
        p.y = drop * CGFloat(1 - s * s)
        let impact = ramp(u, fall, fall + 0.1) * (1 - ramp(u, fall + 0.1, fall + 0.36))
        p = squash(p, 1.2 * impact, ears: 0.26)
        // A blink on impact, then a gentle rebound.
        if u > fall, u < fall + 0.2 { p.eyes *= CGFloat(1 - 0.85 * sin((u - fall) / 0.2 * .pi)) }
        if u > fall + 0.14, u < fall + 0.42 { p.y += 0.8 * CGFloat(sin((u - fall - 0.14) / 0.28 * .pi)) }
        return p
    }

    // MARK: Static poses

    /// What the cat shows when it must not move (Reduce Motion or the pets' animations off): a fixed pose for the
    /// state, instead of a movement. Never animates; the state itself is what changes it.
    static func staticPose(working: Bool, attention: Bool, asleep: Bool = false) -> PetPose {
        if asleep { return asleepPose() }
        if attention { return perked(from: PetPose(), time: 0, amount: 1, age: 10) }
        if working { return sit(time: 0, alert: 1) }
        return PetPose()
    }

    // MARK: Helpers

    /// Piecewise smooth interpolation through `(time, value)` keys, easing in and out of each one.
    static func keyframe(_ u: Double, _ keys: [(Double, CGFloat)]) -> CGFloat {
        guard let first = keys.first, u > first.0 else { return keys.first?.1 ?? 0 }
        for i in 1..<keys.count where u <= keys[i].0 {
            let a = keys[i - 1], b = keys[i]
            return a.1 + (b.1 - a.1) * smooth((u - a.0) / (b.0 - a.0))
        }
        return keys.last?.1 ?? 0
    }
}
