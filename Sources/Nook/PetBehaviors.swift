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
        // It shuts its mouth with a little smack of the lips once the yawn is over.
        p.mouth = open * (0.95 + 0.05 * CGFloat(sin(u * 5))) + 0.12 * bump(u, 3.0, 3.22)
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
        let s = CGFloat(sin(u * 52))
        let target = PetLimb(CGPoint(x: 6.6, y: 6.4), CGPoint(x: 12.4, y: 9.6), CGPoint(x: 10.4 + 1.0 * s * stroke, y: 16.0 + 1.2 * s * stroke), 3.7)
        p.legs[2] = p.legs[2].blended(to: target, up)
        // The head tips and comes down to meet the foot, a little ahead of it.
        let lean = ramp(u, 0, 0.45) * (1 - ramp(u, d - 0.95, d - 0.4))
        p.tilt += -0.34 * lean + 0.025 * s * stroke
        p.head.x += 1.5 * lean; p.head.y -= 1.3 * lean
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
        let landing = easeOut((u - 0.34) / 0.08) * (1 - ramp(u, 0.42, 0.8))
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

    /// The tail comes round to the front of the feet, a wave from its base to its tip; the cat looks down at it, its tip flicking, and
    /// swats at it twice with the near paw: each swat cocks the paw up and back, strikes down fast, and on the paw's contact the tip jumps
    /// out from under it and swings; after the second the tail whips back out of reach and the cat looks innocent.
    static func tailPlay(u: Double, time t: Double) -> PetPose {
        var p = sit(time: t)
        p.action = .tailPlay
        let d = tailPlayLength
        // The tail drops to the ground behind the cat, then sweeps under it and comes up on the far side, its tip curling over: the base
        // leads, the middle follows and the tip comes last, on the way in and on the way out.
        let low = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -16, y: 1.5), c2: CGPoint(x: -17, y: 0.6), p3: CGPoint(x: -11, y: 0.8), width: 3.5)
        let front = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -15.5, y: 1.0), c2: CGPoint(x: 3.0, y: -1.8), p3: CGPoint(x: 11.6, y: 6.4), width: 3.5)
        func engage(_ lag: Double) -> CGFloat { ramp(u, lag, 1.0 + lag) * (1 - ramp(u, d - 1.1 + lag * 0.5, d - 0.25 + lag * 0.5)) }
        func path(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ k: CGFloat) -> CGPoint {
            CGPoint(x: (1 - k) * (1 - k) * a.x + 2 * k * (1 - k) * b.x + k * k * c.x, y: (1 - k) * (1 - k) * a.y + 2 * k * (1 - k) * b.y + k * k * c.y)
        }
        let rest = p.tail
        p.tail = PetTail(p0: rest.p0, c1: path(rest.c1, low.c1, front.c1, engage(0)), c2: path(rest.c2, low.c2, front.c2, engage(0.08)),
                         p3: path(rest.p3, low.p3, front.p3, engage(0.16)), width: 3.5)
        // Its tip lives a life of its own while the cat watches it, and jumps out from under the paw at each swat.
        let flick = CGFloat(sin(u * 13)) * ramp(u, 1.0, 1.3) * (1 - ramp(u, 2.5, 2.9))
        let contacts = [1.48, 2.1]
        var kick: CGFloat = 0
        for (k, c) in contacts.enumerated() where u > c { kick += CGFloat(sin(2 * .pi * 2.2 * (u - c)) * exp(-5 * (u - c))) * (k == 0 ? 1 : 1.3) }
        let tip = engage(0.16)
        p.tail.p3.x += (0.9 * flick + 2.6 * kick) * tip; p.tail.p3.y += (2.2 * flick + 1.4 * kick) * tip
        p.tail.c2.x += 1.0 * kick * tip; p.tail.c2.y += 0.5 * kick * tip
        // Head down, eyes on the tip, ears forward.
        let look = ramp(u, 0.5, 1.2) * (1 - ramp(u, d - 1.2, d - 0.5))
        p.head.y -= 1.5 * look; p.look.x += 1.3 * look; p.look.y += -1.0 * look + 0.4 * flick * look
        p.tilt += -0.08 * look; p.earL -= 0.14 * look; p.earR -= 0.14 * look; p.eyes *= 1 + 0.1 * look
        // The paw: held ready while it watches, then each swat (cocked up and back, a strike that is fastest as it lands, a moment on the
        // tip, and back).
        let ready = PetLimb(CGPoint(x: 4.4, y: 7.8), CGPoint(x: 8.6, y: 6.6), CGPoint(x: 9.4, y: 4.4), 3.4)
        let cocked = PetLimb(CGPoint(x: 4.4, y: 8.4), CGPoint(x: 8.2, y: 9.6), CGPoint(x: 9.2, y: 11.4), 3.4)
        let strike = PetLimb(CGPoint(x: 4.4, y: 7.6), CGPoint(x: 9.6, y: 6.6), CGPoint(x: 11.4, y: 5.2), 3.4)
        var paw = ready, lunge: CGFloat = 0
        for c in contacts {
            let tau = u - c
            guard tau > -0.28, tau < 0.35 else { continue }
            if tau < -0.08 { paw = ready.blended(to: cocked, ramp(tau, -0.28, -0.08)) }
            else if tau < 0 { paw = cocked.blended(to: strike, easeIn((tau + 0.08) / 0.08)) }
            else if tau < 0.08 { paw = strike }
            else { paw = strike.blended(to: ready, ramp(tau, 0.08, 0.35)) }
            lunge = spline(tau, [(-0.28, 0), (-0.08, -0.25), (0, 0.6), (0.1, 0.5), (0.35, 0)])
        }
        let watching = ramp(u, 0.9, 1.2) * (1 - ramp(u, 2.35, 2.75))
        p.legs[3] = p.legs[3].blended(to: paw, watching)
        p.chest.cx += 0.5 * lunge * watching; p.head.x += 0.5 * lunge * watching
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
            // Each paw lifts and pushes forward (a little loop: up, then out, then down), in turn; the presses start and end at rest.
            func press(_ v: Double) -> CGFloat { CGFloat(pow(max(0, v), 1.5)) }
            let far = press(sin(u * 5.8)), near = press(-sin(u * 5.8)), farOut = press(sin(u * 5.8 - 0.5)), nearOut = press(-sin(u * 5.8 - 0.5))
            target.legs[1] = PetLimb(CGPoint(x: 8, y: 3.2), CGPoint(x: 12.4, y: 3.2 + 0.4 * far), CGPoint(x: 16.2 + 0.8 * farOut, y: 1.8 + 3.2 * far), 3).blended(to: target.legs[1], 1 - knead)
            target.legs[3] = PetLimb(CGPoint(x: 11, y: 3.5), CGPoint(x: 14.6, y: 3.4 + 0.4 * near), CGPoint(x: 18.2 + 0.8 * nearOut, y: 1.8 + 3.2 * near), 3).blended(to: target.legs[3], 1 - knead)
            target.head.y -= 0.45 * knead * (far + near); target.chest.cx += 0.15 * knead * (far - near)
            target.eyes *= 1 - 0.55 * knead
        }
        if f < 0 { target = target.mirrored() }
        // It lies down front first and gets up the same way: the head comes up, the chest rises onto the front legs, and the rear follows.
        return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 1.9)) : target.staged(to: base, ramp(u, d - 1.9, d)), .loaf)
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
        // Hind legs folded under the raised rear (the hocks back and low, the paws under the hips), front legs tucked forward under the chest.
        p.legs[0] = PetLimb(CGPoint(x: -8.2, y: 10.2), CGPoint(x: -10.6 + 0.7 * w, y: 2.2), CGPoint(x: -7.6 + 0.7 * w, y: 0.5), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -5.8, y: 10.2), CGPoint(x: -8.2 - 0.7 * w, y: 2.2), CGPoint(x: -5.2 - 0.7 * w, y: 0.5), 3.1)
        p.legs[1] = PetLimb(CGPoint(x: 4.4, y: 7.0), CGPoint(x: 7.4, y: 4.0), CGPoint(x: 9.8, y: 0.6), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 6.6, y: 7.0), CGPoint(x: 9.4, y: 4.0), CGPoint(x: 12.0, y: 0.8), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -9.6, y: 11.6), c1: CGPoint(x: -13.2, y: 10.8), c2: CGPoint(x: -13.8 + 1.4 * w, y: 9.2), p3: CGPoint(x: -12.6 + 2.0 * w, y: 7.4 + 1.2 * w))
        return p
    }

    /// The middle of a pounce, in the air: the body stretched out long, the front legs reaching forward and down for the speck, the hind
    /// legs trailing back from the push, the tail streaming behind, the eyes huge and on the target.
    static func leap(time t: Double) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .hunt
        p.haunch = PetOval(-4.4, 10.8, 7.4, 4.8, 0.10)
        p.chest = PetOval(6.8, 10.2, 7.2, 4.5, -0.04)
        p.head = CGPoint(x: 13.8, y: 12.4); p.headScale = 0.84; p.tilt = 0
        p.eyes = 1.25; p.earL = -0.18; p.earR = -0.18; p.look = CGPoint(x: 1.6, y: -0.8)
        p.legs[1] = PetLimb(CGPoint(x: 8.2, y: 9.6), CGPoint(x: 12.2, y: 7.4), CGPoint(x: 16.0, y: 4.6), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 10.2, y: 9.6), CGPoint(x: 14.4, y: 7.2), CGPoint(x: 18.2, y: 4.0), 3.1)
        p.legs[0] = PetLimb(CGPoint(x: -7.2, y: 10.4), CGPoint(x: -10.0, y: 7.0), CGPoint(x: -13.0, y: 4.8), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -4.8, y: 10.4), CGPoint(x: -7.6, y: 6.6), CGPoint(x: -10.8, y: 4.0), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -9.6, y: 11.8), c1: CGPoint(x: -14.0, y: 12.2), c2: CGPoint(x: -16.6, y: 12.6), p3: CGPoint(x: -17.6, y: 14.2))
        return p
    }

    /// Landed on it: the front paws pin the speck to the ground, the chest is down between them, the rear still a little up from the
    /// leap with the hind legs folded under, and the cat peers at what it has caught.
    static func pinned(time t: Double) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .hunt
        p.haunch = PetOval(-1.4, 9.2, 7.2, 5.0, -0.18)
        p.chest = PetOval(7.0, 6.4, 6.9, 4.2, -0.3)
        p.head = CGPoint(x: 13.4, y: 7.6); p.headScale = 0.84; p.tilt = -0.12
        p.eyes = 1.15; p.earL = -0.12; p.earR = -0.12; p.look = CGPoint(x: 1.5, y: -1.0)
        p.legs[1] = PetLimb(CGPoint(x: 8.0, y: 6.2), CGPoint(x: 12.6, y: 3.6), CGPoint(x: 16.8, y: 0.9), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 10.0, y: 6.2), CGPoint(x: 14.4, y: 3.4), CGPoint(x: 18.6, y: 1.0), 3.1)
        p.legs[0] = PetLimb(CGPoint(x: -4.4, y: 9.6), CGPoint(x: -6.6, y: 2.2), CGPoint(x: -3.6, y: 0.4), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -2.0, y: 9.6), CGPoint(x: -4.0, y: 2.2), CGPoint(x: -1.0, y: 0.4), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -6.4, y: 10.2), c1: CGPoint(x: -11.4, y: 9.6), c2: CGPoint(x: -14.4, y: 7.2), p3: CGPoint(x: -12.8, y: 4.0))
        return p
    }

    /// Where the speck is, `u` seconds into the hunt: it flutters round to the right of the cat's head, lands low in front of it
    /// and waits, twitching; then it is caught (variant 0: it is gone under the paws as they land on it) or gets away (variant 1: it
    /// darts up and off just before they do).
    static func mote(u: Double, variant: Int) -> (point: CGPoint, size: CGFloat) {
        let appear = ramp(u, 0, 0.7)
        let fly = CGPoint(x: 14.8 + 3.0 * CGFloat(sin(u * 1.7 + 0.4)), y: 21.5 + 5.0 * CGFloat(sin(u * 2.3)) + 2.6 * CGFloat(sin(u * 0.9)))
        let land = ramp(u, 3.5, 4.4)
        let rest = CGPoint(x: 19.2 + 0.3 * CGFloat(sin(u * 11)) * land, y: 2.5 + 0.3 * CGFloat(sin(u * 13)) * land)
        var point = lerp(fly, rest, land)
        var size = appear
        if variant == 0 {
            size *= 1 - ramp(u, 7.22, 7.3)
        } else {
            let escape = ramp(u, 7.0, 7.7)
            point = lerp(point, CGPoint(x: 19.0, y: 19.0 + 2.0 * CGFloat(sin(u * 8))), escape)
            size *= 1 - ramp(u, 7.5, 8.2)
        }
        return (point, size)
    }

    /// The whole hunt, in the beats of a cat. It notices a speck (the ears prick first, then the eyes go to it, and the head follows them a
    /// beat behind) and follows it, the tip of its tail flicking now and then. The speck lands: the cat locks on and holds still, goes down
    /// into a crouch head first, and stalks it, two creeping steps a front paw at a time. It coils: its rear sways and its hind feet tread
    /// (the wiggle builds), it sinks lower, and freezes, longer than feels comfortable. Then the burst: the hind legs push, the body
    /// stretches out and the front paws reach for the speck in an arc through the air; it lands front paws first, on the speck, and takes
    /// the landing in a short squash. The speck is caught (it peers at it with its tail swishing, looks round pleased and blinks slowly) or
    /// gets away (its head comes up after it, and it looks, a little baffled, back at us); then it sits back up, the front first. `facing` is
    /// the side the speck is on (1 right, -1 left): everything that goes toward it is written for the right and mirrored. `shift` moves the
    /// whole crouch sideways (points, away from the speck) to leave room for the pounce, which covers the distance within the cat's own
    /// room.
    static func hunt(u: Double, length d: Double, time t: Double, variant: Int = 0, facing f: CGFloat = 1, shift: CGFloat = 0) -> PetPose {
        let base = sit(time: t)
        let m = mote(u: u, variant: variant)
        // 1. Watching from the sit.
        var watch = base
        let ears = ramp(u, 0.3, 0.45), seen = ramp(u, 0.35, 0.8), follow = ramp(u, 0.45, 0.95)
        let late = mote(u: max(0, u - 0.25), variant: variant).point
        let dx = min(1, max(-1, (m.point.x - 3) / 14)), dy = min(1, max(-1, (m.point.y - 19) / 9))
        let hx = min(1, max(-1, (late.x - 3) / 14)), hy = min(1, max(-1, (late.y - 19) / 9))
        watch.look.x += 1.9 * dx * seen * f; watch.look.y += 1.0 * dy * seen
        watch.head.x += 1.2 * hx * follow * f; watch.head.y += 0.9 * max(0, hy) * follow
        watch.tilt += -0.12 * hx * follow * f
        watch.earL -= 0.24 * ears; watch.earR -= 0.24 * ears; watch.eyes *= 1 + 0.16 * seen
        let flicks = twitch(u, 1.4, 1.75) + twitch(u, 2.5, 2.8) + twitch(u, 3.5, 3.8)
        watch.tail.p3.y += 2.2 * flicks; watch.tail.p3.x += 1.0 * flicks * f; watch.tail.c2.y += 0.8 * flicks
        // 2-4. The crouch, the stalk and the coil.
        let wiggle = ramp(u, 5.65, 6.0) * (1 - ramp(u, 6.3, 6.45))
        let w = CGFloat(sin((u - 5.65) * 2 * .pi * 3.4)) * wiggle
        var crouched = crouch(time: t, wiggle: w)
        let coil = ramp(u, 5.6, 5.95), sink = ramp(u, 6.66, 6.8)
        crouched.haunch.cy += 0.5 * coil - 0.3 * sink; crouched.chest.cy -= 0.4 * coil + 0.3 * sink; crouched.chest.ry -= 0.25 * coil
        crouched.head.y -= 0.35 * coil + 0.2 * sink; crouched.earL -= 0.06 * coil; crouched.earR -= 0.06 * coil
        // The tip of the tail twitches while it waits, quicker in the coil, and is still in the freeze.
        crouched.tail.p3.y += 0.9 * CGFloat(sin(u * 8)) * ramp(u, 4.4, 5) * (1 - ramp(u, 5.6, 5.8)) + 0.8 * CGFloat(sin(u * 22)) * wiggle
        // The stalk: the body creeps forward in two surges, each after a front paw has stepped (lifted and put down again further on), and the
        // hind feet catch up; the head moves least.
        let creep = 0.45 * ramp(u, 5.05, 5.3) + 0.45 * ramp(u, 5.3, 5.55)
        crouched.haunch.cx += creep; crouched.chest.cx += creep; crouched.head.x += 0.6 * creep
        crouched.tail = PetTail(p0: CGPoint(x: crouched.tail.p0.x + creep, y: crouched.tail.p0.y), c1: CGPoint(x: crouched.tail.c1.x + creep, y: crouched.tail.c1.y),
                                c2: CGPoint(x: crouched.tail.c2.x + creep, y: crouched.tail.c2.y), p3: CGPoint(x: crouched.tail.p3.x + creep, y: crouched.tail.p3.y), width: crouched.tail.width)
        let steps: [(leg: Int, step: CGFloat, lift: CGFloat)] = [(3, ramp(u, 5.0, 5.22), bump(u, 5.0, 5.22)), (1, ramp(u, 5.24, 5.46), bump(u, 5.24, 5.46)),
                                                                  (2, ramp(u, 5.4, 5.58), bump(u, 5.4, 5.58)), (0, ramp(u, 5.46, 5.64), bump(u, 5.46, 5.64))]
        for s in steps {
            crouched.legs[s.leg].hip.x += creep; crouched.legs[s.leg].knee.x += (creep + 0.9 * s.step) / 2
            crouched.legs[s.leg].foot.x += 0.9 * s.step; crouched.legs[s.leg].foot.y += 0.9 * s.lift
        }
        if f < 0 { crouched = crouched.mirrored() }
        // Locked on and still from 4.0, it goes down head first.
        let down = ramp(u, 4.25, 4.95)
        var p = watch.staged(to: crouched, down)
        // 5. The pounce: the burst (the hind legs push first), the arc, and down onto the speck front paws first.
        let launch = easeOut((u - 6.8) / 0.14), descend = ramp(u, 6.98, 7.3)
        if launch > 0 {
            var flying = leap(time: t), landed = pinned(time: t)
            if f < 0 { flying = flying.mirrored(); landed = landed.mirrored() }
            p = p.staged(to: flying, launch, order: .legsFirst)
            if descend > 0 { p = p.staged(to: landed, descend) }
        }
        let flight = (u - 6.84) / 0.46
        let airborne: CGFloat = flight > 0 && flight < 1 ? CGFloat(4 * flight * (1 - flight)) : 0
        p.y += 3.4 * airborne
        // The landing goes on at the speed of the drop: the legs give, and push back.
        let impact = easeOut((u - 7.3) / 0.08) * (1 - ramp(u, 7.38, 7.65))
        p.haunch.cy -= 0.6 * impact; p.chest.cy -= 0.5 * impact; p.chest.ry -= 0.3 * impact; p.head.y -= 0.8 * impact
        p.earL += 0.12 * impact; p.earR += 0.12 * impact
        // 6. Afterwards.
        if variant == 0 {
            let peer = ramp(u, 7.35, 7.6) * (1 - ramp(u, 7.9, 8.3))
            p.head.y -= 0.5 * peer; p.look.y -= 0.3 * peer
            let swish = CGFloat(sin((u - 7.3) * 9)) * ramp(u, 7.3, 7.5) * (1 - ramp(u, 8.3, 8.8))
            p.tail.p3.y += 1.4 * swish; p.tail.p3.x += 0.8 * swish * f
            let round = ramp(u, 7.9, 8.2) * (1 - ramp(u, 8.9, 9.2))
            let sweep = CGFloat(sin((u - 7.9) * 3.2))
            p.look.x += 1.8 * sweep * round; p.head.x += 0.8 * sweep * round
        } else {
            let after = ramp(u, 7.05, 7.45) * (1 - ramp(u, 8.1, 8.6))
            p.look.y += 2.0 * after; p.head.y += 2.4 * after; p.tilt += 0.06 * after * f
            let baffled = ramp(u, 8.3, 8.8) * (1 - ramp(u, 9.3, 9.7))
            p.tilt += -0.16 * baffled * f; p.look.x += -0.5 * baffled * f
        }
        // 7. It sits back up: its rear is already down, so the front comes up first (the head, the chest onto the front legs).
        let rise = ramp(u, 8.4, d)
        if rise > 0 { p = p.staged(to: base, rise) }
        // Pleased with its catch, it blinks slowly as it settles.
        if variant == 0 { p.eyes *= 1 - 0.85 * bump(u, 8.5, 9.1) }
        let low = down * (1 - rise)
        p.x += shift * low * f
        // The speck itself.
        p.mote = CGPoint(x: m.point.x * f, y: m.point.y); p.moteSize = m.size
        p.action = low > 0.5 ? .hunt : .sit
        return labelled(p, .hunt)
    }
}
