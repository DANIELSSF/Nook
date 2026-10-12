import AppKit

/// The gestures a cat makes when it has nothing to do: a yawn, a scratch behind the ear, a start at a noise, a game with its own
/// tail, a long lie-down and the hunt of a speck in the air. Each is a pure function of the seconds `u` since it began (and the
/// wall clock `t`, for the breathing that goes on under everything), authored to start and end exactly at the sit so the director
/// can chain them; the springs and the small life laid over them by the player add the follow-through.
extension PetAnimation {
    // MARK: Yawn

    static let yawnLength = 3.6

    /// A deeper breath in, then the mouth opens wide as the head tips up and the eyes squeeze shut, a tremble at the top, the mouth
    /// closes, the head shakes once and the lids come up slowly.
    static func yawn(u: Double, time t: Double) -> PetPose {
        var p = sit(time: t)
        p.action = .yawn
        let inhale = bump(u, 0, 0.95)
        let open = ramp(u, 0.55, 1.2) * (1 - ramp(u, 2.3, 2.95))
        let lids = ramp(u, 0.62, 1.1) * (1 - ramp(u, 2.55, 3.2))
        let tremble = open * CGFloat(sin(u * 46)) * ramp(u, 1.35, 1.7) * (1 - ramp(u, 2.1, 2.4))
        p.mouth = open * (0.95 + 0.05 * CGFloat(sin(u * 5)))
        p.head.y += 1.3 * open + 0.4 * inhale + 0.12 * tremble
        p.headScale += 0.035 * open
        p.eyes *= 1 - 0.94 * lids
        p.earL += 0.28 * open; p.earR += 0.28 * open
        p.chest.ry += 0.5 * inhale + 0.7 * open; p.chest.rx += 0.3 * open
        p.tail.p3.y += 1.2 * open
        // After it, one shake of the head.
        p.tilt += 0.12 * ringing(u, from: 3.0, hz: 3.2, decay: 4.5)
        return p
    }

    // MARK: Scratch

    static let scratchLength = 2.7

    /// Sitting, the cat tips its head toward the near hind leg, which comes up beside the ear and scratches it fast, eyes shut with
    /// pleasure; the leg goes down and the head shakes itself straight.
    static func scratch(u: Double, time t: Double) -> PetPose {
        var p = sit(time: t)
        p.action = .scratch
        let d = scratchLength
        let up = ramp(u, 0, 0.55) * (1 - ramp(u, d - 0.95, d - 0.4))
        let stroke = ramp(u, 0.5, 0.75) * (1 - ramp(u, d - 1.2, d - 0.95))
        let s = CGFloat(sin(u * 58))
        let target = PetLimb(CGPoint(x: 6.8, y: 5.4), CGPoint(x: 14.6, y: 9.2), CGPoint(x: 10.6 + 1.1 * s * stroke, y: 17.2 + 1.5 * s * stroke), 3.7)
        p.legs[2] = p.legs[2].blended(to: target, up)
        p.tilt += -0.3 * up + 0.025 * s * stroke
        p.head.x += 1.5 * up; p.head.y -= 0.9 * up
        p.eyes *= 1 - 0.8 * up
        p.earR += 0.3 * up; p.earL -= 0.06 * up
        p.chest.cx += -0.6 * up + 0.35 * s * stroke
        p.haunch.cx += -0.5 * up
        // Shaking itself straight again.
        let shake = ringing(u, from: d - 0.9, hz: 3.6, decay: 4.0)
        p.tilt += 0.13 * shake; p.earL -= 0.18 * max(0, shake); p.earR += 0.1 * shake
        return p
    }

    // MARK: Startle

    static let startleLength = 2.9

    /// Something it cannot see makes a noise: a small jump, the eyes wide, the ears flat and the tail puffed; then it freezes
    /// looking toward it (`variant` 0 to the right, 1 to the left), relaxes, blinks, and shakes it off.
    static func startle(u: Double, time t: Double, variant: Int = 0) -> PetPose {
        var p = sit(time: t)
        p.action = .startle
        let side: CGFloat = variant == 0 ? 1 : -1
        let d = startleLength
        let flight = u / 0.34
        let air: CGFloat = flight > 0 && flight < 1 ? CGFloat(4 * flight * (1 - flight)) : 0
        let landing = ramp(u, 0.3, 0.42) * (1 - ramp(u, 0.42, 0.8))
        let alarm = ramp(u, 0, 0.1) * (1 - ramp(u, 1.2, 2.0))
        let freeze = ramp(u, 0.35, 0.7) * (1 - ramp(u, 1.7, 2.3))
        let puff = ramp(u, 0, 0.12) * (1 - ramp(u, 1.1, 2.5))
        p = squash(p, 0.9 * landing, ears: 0.1)
        p.y = 2.7 * air
        p.chest.ry += 0.9 * air; p.head.y += 0.8 * air
        p.eyes *= 1 + 0.26 * alarm
        // The ears go flat in the first instant, then swivel toward the sound.
        let flat = ramp(u, 0, 0.1) * (1 - ramp(u, 0.3, 0.55))
        p.earL += 0.34 * flat; p.earR += 0.34 * flat
        if side > 0 { p.earR -= 0.38 * freeze; p.earL += 0.1 * freeze } else { p.earL -= 0.38 * freeze; p.earR += 0.1 * freeze }
        p.look.x += 1.9 * side * freeze; p.head.x += 1.0 * side * freeze; p.tilt += -0.1 * side * freeze
        p.head.y += 0.9 * freeze
        p.tail.width += 1.8 * puff
        p.tail.p3.y += 4.2 * puff; p.tail.c2.y += 2.4 * puff; p.tail.p3.x += 1.6 * puff
        // It relaxes with a slow blink, and shakes its head.
        p.eyes *= 1 - 0.9 * bump(u, 2.0, 2.6)
        p.tilt += 0.12 * ringing(u, from: d - 0.55, hz: 3.4, decay: 4.2)
        return p
    }

    // MARK: Tail play

    static let tailPlayLength = 3.6

    /// The tail comes round to the front of the feet; the cat looks down at it, its tip flicking, and swats at it twice with the
    /// near paw; the tail whips back out of reach and the cat looks innocent.
    static func tailPlay(u: Double, time t: Double) -> PetPose {
        var p = sit(time: t)
        p.action = .tailPlay
        let d = tailPlayLength
        let engage = ramp(u, 0, 1.0) * (1 - ramp(u, d - 1.1, d - 0.2))
        let flick = CGFloat(sin(u * 13)) * ramp(u, 1.0, 1.3) * (1 - ramp(u, 2.5, 2.9))
        // The tail drops to the ground behind the cat, then sweeps under it and comes up on the far side, its tip curling over.
        let low = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -16, y: 1.5), c2: CGPoint(x: -17, y: 0.6), p3: CGPoint(x: -11, y: 0.8), width: 3.5)
        let front = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -15.5, y: 1.0), c2: CGPoint(x: 3.0, y: -1.8), p3: CGPoint(x: 11.6 + 0.9 * flick, y: 6.4 + 2.2 * flick), width: 3.5)
        func at(_ a: PetTail, _ b: PetTail, _ k: CGFloat) -> PetTail { PetTail(p0: lerp(a.p0, b.p0, k), c1: lerp(a.c1, b.c1, k), c2: lerp(a.c2, b.c2, k), p3: lerp(a.p3, b.p3, k), width: 3.5) }
        let rest = p.tail
        p.tail = engage < 0.5 ? at(rest, low, engage * 2) : at(low, front, (engage - 0.5) * 2)
        // Head down, eyes on the tip, ears forward.
        let look = ramp(u, 0.5, 1.2) * (1 - ramp(u, d - 1.2, d - 0.5))
        p.head.y -= 1.5 * look; p.look.x += 1.3 * look; p.look.y += -1.0 * look + 0.4 * flick * look
        p.tilt += -0.08 * look; p.earL -= 0.14 * look; p.earR -= 0.14 * look; p.eyes *= 1 + 0.1 * look
        // Two swats of the near paw at the tip.
        for start in [1.45, 2.05] {
            let local = (u - start) / 0.42
            guard local > 0, local < 1 else { continue }
            let swat = CGFloat(sin(local * .pi))
            let paw = PetLimb(CGPoint(x: 4.4, y: 7.6), CGPoint(x: 9.2, y: 6.2), CGPoint(x: 10.0 + 2.0 * swat, y: 3.0 + 3.0 * swat), 3.4)
            p.legs[3] = p.legs[3].blended(to: paw, swat)
            p.chest.cx += 0.5 * swat; p.head.x += 0.5 * swat
        }
        // Looking innocent at the end: a slow blink.
        p.eyes *= 1 - 0.85 * bump(u, d - 0.9, d - 0.15)
        return p
    }

    // MARK: Loaf

    /// Lying down in a loaf, awake: it settles onto its belly, its eyes soften and slow-blink, an ear turns now and then, and in
    /// variant 1 it kneads the floor with its front paws in the middle of it; then it gets up again. `length` is how long all of it
    /// lasts, from the start of the lowering to the end of the rising.
    static func loafing(u: Double, length d: Double, time t: Double, variant: Int = 0, facing f: CGFloat = 1) -> PetPose {
        let base = sit(time: t)
        var target = loaf(rest: 0, time: t)
        target.action = .loaf
        // Settled: lids half down, the odd slow blink, an ear turning to a sound, the tail tip drifting.
        let settled = ramp(u, 1.5, 2.6) * (1 - ramp(u, d - 2.6, d - 1.6))
        target.eyes = 1 - 0.3 * settled
        if let blink = event(u, period: 6.5, length: 1.3, salt: 31) { target.eyes *= 1 - 0.92 * bump(blink, 0, 1) * settled }
        if let flick = event(u, period: 8.0, length: 0.5, salt: 33) { target.earL -= 0.3 * CGFloat(sin(.pi * flick)) * settled }
        target.earL += 0.1 * settled; target.earR += 0.06 * settled
        target.tail.p3.y += 0.9 * CGFloat(sin(t * 1.3)) * settled
        // Kneading: the front paws press the floor in turn, the head dipping with each, the eyes nearly shut.
        let knead = variant == 1 ? ramp(u, 3.0, 3.9) * (1 - ramp(u, d - 4.6, d - 3.7)) : 0
        if knead > 0 {
            let beat = CGFloat(sin(u * 5.8))
            let far = max(0, beat), near = max(0, -beat)
            target.legs[1] = PetLimb(CGPoint(x: 8, y: 3.2), CGPoint(x: 12.4, y: 3.2 + 0.4 * far), CGPoint(x: 16.2 + 0.8 * far, y: 1.8 + 3.2 * far), 3).blended(to: target.legs[1], 1 - knead)
            target.legs[3] = PetLimb(CGPoint(x: 11, y: 3.5), CGPoint(x: 14.6, y: 3.4 + 0.4 * near), CGPoint(x: 18.2 + 0.8 * near, y: 1.8 + 3.2 * near), 3).blended(to: target.legs[3], 1 - knead)
            target.head.y -= 0.45 * knead * (far + near); target.chest.cx += 0.0
            target.eyes *= 1 - 0.55 * knead
        }
        if f < 0 { target = target.mirrored() }
        return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 1.9)) : target.staged(to: base, ramp(u, d - 1.9, d), order: .legsFirst), .loaf)
    }

    // MARK: Hunt

    /// How long a hunt lasts when the speck is caught (variant 0) and when it escapes (variant 1).
    static func huntLength(variant: Int) -> Double { variant == 0 ? 9.4 : 9.8 }

    /// A cat flat on the ground with its rear in the air, all of it ready to spring: the chest low, the head level and the eyes
    /// huge, the hind legs folded, the tail low and twitching. `wiggle` rocks the rear from side to side before the pounce.
    static func crouch(time t: Double, wiggle w: CGFloat = 0) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .hunt
        p.haunch = PetOval(-4.8 + 1.0 * w, 10.2, 7.2, 5.3, -0.14)
        p.chest = PetOval(3.2, 7.2, 6.8, 4.4, -0.28)
        p.head = CGPoint(x: 10.2, y: 8.8); p.headScale = 0.84; p.tilt = -0.06
        p.eyes = 1.22; p.earL = -0.2; p.earR = -0.2; p.look = CGPoint(x: 1.9, y: -0.3)
        // Hind legs folded (the thigh forward, the foot back under the hip), front legs tucked forward under the chest.
        p.legs[0] = PetLimb(CGPoint(x: -7.4, y: 9.4), CGPoint(x: -4.6, y: 4.6), CGPoint(x: -7.6 + 0.7 * w, y: 0.5), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -4.8, y: 9.4), CGPoint(x: -2.2, y: 4.8), CGPoint(x: -5.2 - 0.7 * w, y: 0.5), 3.1)
        p.legs[1] = PetLimb(CGPoint(x: 4.4, y: 7.0), CGPoint(x: 7.4, y: 4.0), CGPoint(x: 9.8, y: 0.6), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 6.6, y: 7.0), CGPoint(x: 9.4, y: 4.0), CGPoint(x: 12.0, y: 0.8), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -9.6, y: 11.6), c1: CGPoint(x: -13.2, y: 10.8), c2: CGPoint(x: -13.8 + 1.4 * w, y: 9.2), p3: CGPoint(x: -12.6 + 2.0 * w, y: 7.4 + 1.2 * w))
        return p
    }

    /// Where the speck is, `u` seconds into the hunt: it flutters round to the right of the cat's head, lands low in front of it
    /// and waits, twitching; then it is caught (variant 0: it is gone under the paws) or gets away (variant 1: it darts up and off).
    static func mote(u: Double, variant: Int) -> (point: CGPoint, size: CGFloat) {
        let appear = ramp(u, 0, 0.7)
        let fly = CGPoint(x: 14.8 + 3.0 * CGFloat(sin(u * 1.7 + 0.4)), y: 21.5 + 5.0 * CGFloat(sin(u * 2.3)) + 2.6 * CGFloat(sin(u * 0.9)))
        let land = ramp(u, 3.5, 4.4)
        let rest = CGPoint(x: 19.2 + 0.3 * CGFloat(sin(u * 11)) * land, y: 2.5 + 0.3 * CGFloat(sin(u * 13)) * land)
        var point = lerp(fly, rest, land)
        var size = appear
        if variant == 0 {
            size *= 1 - ramp(u, 7.0, 7.18)
        } else {
            let escape = ramp(u, 7.0, 7.7)
            point = lerp(point, CGPoint(x: 19.0, y: 19.0 + 2.0 * CGFloat(sin(u * 8))), escape)
            size *= 1 - ramp(u, 7.5, 8.2)
        }
        return (point, size)
    }

    /// The whole hunt, in the beats of a cat: it spots a speck and follows it with its eyes and head; the speck settles, the cat
    /// turns to it and drops into a crouch; its rear wiggles; it springs. The speck is caught (the cat looks around pleased) or
    /// gets away (the cat watches it go and looks, a little baffled, back at us); then it sits up again. `facing` is the side the
    /// speck is on (1 right, -1 left): everything that goes toward it is written for the right and multiplied by it. `shift` moves
    /// the whole crouch sideways (points, away from the speck) to leave room, and `lunge` is how far the pounce carries it toward it.
    static func hunt(u: Double, length d: Double, time t: Double, variant: Int = 0, facing f: CGFloat = 1, shift: CGFloat = 0, lunge: CGFloat = 0) -> PetPose {
        let base = sit(time: t)
        let m = mote(u: u, variant: variant)
        // 1. Watching from the sit: the eyes lead, the head follows, the ears point at the speck.
        var watch = base
        let seen = ramp(u, 0.3, 0.9)
        let dx = min(1, max(-1, (m.point.x - 3) / 14)), dy = min(1, max(-1, (m.point.y - 19) / 9))
        watch.look.x += 1.9 * dx * seen * f; watch.look.y += 1.0 * dy * seen
        watch.head.x += 1.2 * dx * seen * f; watch.head.y += 0.9 * max(0, dy) * seen
        watch.tilt += -0.12 * dx * seen * f
        watch.earL -= 0.2 * seen; watch.earR -= 0.2 * seen; watch.eyes *= 1 + 0.16 * seen
        watch.tail.p3.y += 2.0 * CGFloat(sin(u * 9)) * seen * ramp(u, 1.5, 2.5)
        watch.tail.p3.x += 1.0 * CGFloat(sin(u * 7)) * seen * ramp(u, 1.5, 2.5)
        // 2. The crouch and its wiggle.
        let wiggleAmount = ramp(u, 5.35, 5.75) * (1 - ramp(u, 6.45, 6.75))
        let w = CGFloat(sin(u * 33)) * wiggleAmount
        var crouched = crouch(time: t, wiggle: w)
        // The tail tip twitches while it waits.
        crouched.tail.p3.y += 0.9 * CGFloat(sin(u * 8)) * ramp(u, 4.4, 5)
        if f < 0 { crouched = crouched.mirrored() }
        // Down into the crouch (head first, then the body, then the legs), and back up at the end the other way round.
        var p = u < 8.2 ? watch.staged(to: crouched, ramp(u, 3.7, 4.9)) : crouched.staged(to: base, ramp(u, 8.2, d), order: .legsFirst)
        let low = ramp(u, 3.7, 4.9) * (1 - ramp(u, 8.2, d))
        p.x += shift * low * f
        // 3. The pounce: it sinks back, springs out in an arc with the front paws and head thrown forward, and lands.
        let sink = ramp(u, 6.62, 6.86) * (1 - ramp(u, 6.86, 6.9))
        let flight = (u - 6.88) / 0.52
        let airborne: CGFloat = flight > 0 && flight < 1 ? CGFloat(4 * flight * (1 - flight)) : 0
        let reach = ramp(u, 6.88, 7.15) * (1 - ramp(u, 7.7, 8.4))
        let impact = ramp(u, 7.28, 7.38) * (1 - ramp(u, 7.38, 7.75))
        if u > 6.5, u < d {
            p.haunch.cx -= 0.9 * sink * f; p.chest.cx -= 0.4 * sink * f; p.head.y -= 0.5 * sink
            p.y += 3.4 * airborne - 0.6 * impact
            p.x += lunge * f * ramp(u, 6.88, 7.3) * (1 - ramp(u, 8.0, 8.9))
            p.head.x += 1.4 * reach * f; p.head.y += 0.8 * airborne
            p.legs[1].foot = lerp(p.legs[1].foot, CGPoint(x: 15.6 * f, y: 1.2 + 2.2 * airborne), reach)
            p.legs[1].knee = lerp(p.legs[1].knee, CGPoint(x: 11.0 * f, y: 3.8 + 1.5 * airborne), reach)
            p.legs[3].foot = lerp(p.legs[3].foot, CGPoint(x: 17.4 * f, y: 1.0 + 2.6 * airborne), reach)
            p.legs[3].knee = lerp(p.legs[3].knee, CGPoint(x: 12.6 * f, y: 3.8 + 1.5 * airborne), reach)
            p.legs[0].foot.x -= 2.2 * airborne * f; p.legs[2].foot.x -= 2.2 * airborne * f
        }
        // 4. Afterwards: pleased (looks round, a slow blink) or baffled (follows the speck away, then looks at us).
        if variant == 0 {
            let round = ramp(u, 7.7, 8.0) * (1 - ramp(u, 8.9, 9.2))
            p.look.x += 1.8 * CGFloat(sin((u - 7.8) * 3.2)) * round; p.head.x += 0.8 * CGFloat(sin((u - 7.8) * 3.2)) * round
            p.eyes *= 1 - 0.85 * bump(u, 8.5, 9.1)
        } else {
            let follow = ramp(u, 7.0, 7.5) * (1 - ramp(u, 8.0, 8.5))
            p.look.y += 1.2 * follow; p.head.y += 1.3 * follow
            let baffled = ramp(u, 8.3, 8.8) * (1 - ramp(u, 9.3, 9.7))
            p.tilt += -0.16 * baffled * f; p.look.x += -0.5 * baffled * f
        }
        // The speck itself.
        p.mote = CGPoint(x: m.point.x * f, y: m.point.y); p.moteSize = m.size
        p.action = low > 0.5 ? .hunt : .sit
        return labelled(p, .hunt)
    }
}
