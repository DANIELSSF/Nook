import AppKit

/// The cat's rigs and routines: pure functions from a moment to a `PetPose`. They know nothing about views, input or state: the
/// director chooses what to do and when, the player layers the cat's small life and its follow-through on top, and the painter
/// draws the result.
enum PetAnimation {
    /// Drawn extent of the cat beyond its anchor, in rig units, over every pose the gestures can produce.
    static let reach = (left: CGFloat(22), right: CGFloat(22))
    /// Compact wing: the cat is anchored at `compactAnchor` points, drawn at `compactScale`, and must stay inside `wing` (the cutout starts at 30).
    static let compactAnchor: CGFloat = 15.5, compactScale: CGFloat = 0.6, wing: ClosedRange<CGFloat> = 2...28.5
    /// The shortest interval between frames, per layout. Sixty a second divides what every display refreshes at (60, 120), so no
    /// frame is held longer than its neighbours. It is only the ceiling: how far the picture moves between two frames decides the
    /// rate (`PetPace`), so a small cat that moves a little gets far fewer, and only a fast movement of a big cat gets all sixty.
    static let compactInterval = 1.0 / 60, headerInterval = 1.0 / 60
    /// The top rate while the cat only rests (its small life: a blink, a flick, a glance), as it has always been: thirty a second.
    static let restingTopInterval = 1.0 / 30
    /// The dragged cat follows the pointer at the same top rate.
    static let ghostInterval = 1.0 / 60
    /// Seconds between frames while the cat only breathes. (A cat nobody can see has no timer at all, not a slow one: `PetSight`.)
    static let restInterval = 1.0 / 5
    /// The notch's three working dots wave about once a second; eight frames a second show that without visible steps.
    static let dotsInterval = 1.0 / 8
    /// A foot higher than this (rig units) is a paw raised to the face, drawn over the head.
    static let raisedAbove: CGFloat = 14.5
    static var motionReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Rigs (authored facing right)

    /// Front-facing sit, the character's home pose: it breathes and its tail drifts, and nothing else. The blinks, the flicks of an ear
    /// or the tail and the glances that make it alive come from `PetLife`, laid over this and whatever gesture is on. `alert` is the
    /// on-duty posture while the terminal works: eyes a little wider, ears forward.
    static func sit(time t: Double, alert: CGFloat = 0) -> PetPose {
        var p = PetPose()
        let breath = CGFloat(sin(t * 1.7)) * 0.25
        p.chest.ry += breath; p.head.y += breath * 0.6
        let sway = CGFloat(sin(t * 1.1))
        p.tail.p3.x += sway * 0.55; p.tail.p3.y += sway * 0.4; p.tail.c2.y += CGFloat(sin(t * 1.1 + 1)) * 0.5
        if alert > 0 {
            p.eyes *= 1 + 0.12 * alert; p.earL -= 0.1 * alert; p.earR -= 0.1 * alert
        }
        return p
    }

    /// Four-legged stand/walk. `phase` is the gait angle, `amp` scales the stride (0 stands still).
    ///
    /// A cat walks in a lateral sequence: a hind foot, then the front foot on the same side a quarter of a stride later, then the other
    /// hind foot and the other front one, evenly spaced, each foot down for most of the stride (two or three feet are always on the
    /// ground). The body rides over the planted legs: the hips rise as a hind leg passes under them and the shoulders as a front leg does,
    /// a quarter stride apart, so the back rocks gently; the head stays steadier than either, as a cat's does, and the tail is carried up
    /// with a slow sway whose tip lags its middle.
    static func walk(phase: Double, amp: CGFloat, time t: Double) -> PetPose {
        var p = PetPose()
        p.action = .walk
        let hips = amp * CGFloat(cos(2 * phase)) * 0.4, shoulders = -amp * CGFloat(cos(2 * phase)) * 0.32
        p.haunch = PetOval(-6.6, 12.4 + hips, 7.6, 5.4); p.chest = PetOval(4.4, 12.9 + shoulders, 7.3, 5.8)
        p.head = CGPoint(x: 12.4, y: 19.4 + shoulders * 0.3); p.headScale = 0.82
        p.look = CGPoint(x: 1.3, y: -0.2)
        // Hip x, gait phase offset (near hind, near front a quarter later, far hind, far front), knee bend, whether it hangs from the hips.
        let setup: [(CGFloat, Double, CGFloat, Bool)] = [(-9.6, -.pi, -1.8, true), (6.0, -3 * .pi / 2, 1.2, false), (-6.8, 0, -1.8, true), (8.6, -.pi / 2, 1.2, false)]
        for (i, s) in setup.enumerated() {
            let step = gait(phase + s.1)
            let swing = amp * halfStride * step.swing, lift = amp * 3.2 * step.lift
            let hip = CGPoint(x: s.0, y: 8.4 + (s.3 ? hips : shoulders)), foot = CGPoint(x: s.0 + swing, y: lift)
            p.legs[i] = PetLimb(hip, CGPoint(x: (hip.x + foot.x) / 2 + s.2 * (1 + lift / 4), y: (hip.y + foot.y) / 2), foot, 3.1)
        }
        let sway = CGFloat(sin(t * 2.2)), tip = CGFloat(sin(t * 2.2 - 0.9))
        p.tail = PetTail(p0: CGPoint(x: -12.5, y: 14 + hips), c1: CGPoint(x: -18, y: 13 + hips * 0.6), c2: CGPoint(x: -19.5 + sway, y: 19), p3: CGPoint(x: -16 + tip * 1.5, y: 25 + tip))
        return p
    }
    /// Half the foot travel of a stride, in rig units.
    static let halfStride: CGFloat = 5
    /// The share of a stride each foot spends on the ground.
    static let duty = 0.62
    /// How far the body travels in one stride (`2 * pi` of phase), in rig units: a foot on the ground slides back by exactly that, so it
    /// stays where it was put.
    static var strideLength: CGFloat { 2 * halfStride / CGFloat(duty) }

    /// One foot at gait angle `ph`: how far it is along its stride (-1 back ... 1 forward) and how high it is lifted
    /// (0...1). A foot is down for `duty` of the cycle and slides back along a straight line, so seen from the ground it
    /// stays still: with the body moving `strideLength` units per cycle, the foot's backward travel in stance is
    /// exactly the body's forward travel. The rest of the cycle it swings forward in an arc; phase 0 is the middle of the swing.
    static func gait(_ ph: Double) -> (swing: CGFloat, lift: CGFloat) {
        var p = ph / (2 * .pi) + (1 + duty) / 2
        p -= floor(p)
        if p < duty { return (CGFloat(1 - 2 * p / duty), 0) }
        let s = (p - duty) / (1 - duty)
        return (CGFloat(-1 + 2 * smooth(s)), CGFloat(sin(s * .pi)))
    }

    /// Play-bow: chest down, rear up, front paws reaching out.
    static func bow(time t: Double) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .stretch
        let wiggle = CGFloat(sin(t * 3))
        p.haunch = PetOval(-6.6, 14.6, 7.8, 6.4, -0.42)
        p.chest = PetOval(4.0, 9.3, 7.6, 5.0, -0.38)
        p.head = CGPoint(x: 13.6, y: 7.6); p.headScale = 0.86
        p.tilt = -0.12; p.eyes = 0.15; p.earL = 0.2; p.earR = 0.2; p.look = CGPoint(x: 1.8, y: -0.2)
        let reach = 15.5 + 2 * CGFloat(sin(t * 2))
        p.legs[1] = PetLimb(CGPoint(x: 6, y: 5.4), CGPoint(x: 11, y: 1.6), CGPoint(x: reach, y: 1.3), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 8.6, y: 5.4), CGPoint(x: 13, y: 1.6), CGPoint(x: reach + 2, y: 1.3), 3.1)
        p.legs[0] = PetLimb(CGPoint(x: -9.6, y: 13.4), CGPoint(x: -11, y: 7), CGPoint(x: -9.1, y: 0.2), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -6.8, y: 13.4), CGPoint(x: -8.2, y: 7), CGPoint(x: -6.3, y: 0.2), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -12.8, y: 17), c1: CGPoint(x: -17, y: 18), c2: CGPoint(x: -16.5 + wiggle, y: 24), p3: CGPoint(x: -17.5 + 1.2 * wiggle, y: 27.5))
        return p
    }

    /// The second half of a cat's stretch: standing, the back arched high, the head low, the tail hanging in a hook. `tremble` is
    /// the shiver of holding it.
    static func arch(time t: Double, tremble: CGFloat = 0) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .stretch
        p.haunch = PetOval(-5.4, 15.4, 7.6, 5.6, 0.52)
        p.chest = PetOval(4.8, 15.0, 7.4, 5.6, -0.5)
        p.head = CGPoint(x: 11.2, y: 13.0 + tremble * 0.25); p.headScale = 0.84
        p.tilt = -0.34; p.eyes = 0.12; p.earL = 0.34; p.earR = 0.3; p.look = CGPoint(x: 1.2, y: -0.8)
        p.legs[0] = PetLimb(CGPoint(x: -8.6, y: 11.6), CGPoint(x: -9.4, y: 5.8), CGPoint(x: -9.2, y: 0.2), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -5.8, y: 11.6), CGPoint(x: -6.4, y: 5.8), CGPoint(x: -6.0, y: 0.2), 3.1)
        p.legs[1] = PetLimb(CGPoint(x: 5.6, y: 11.4), CGPoint(x: 6.6, y: 5.8), CGPoint(x: 7.2, y: 0.2), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 8.0, y: 11.4), CGPoint(x: 9.0, y: 5.8), CGPoint(x: 9.4, y: 0.2), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -10.8, y: 16.4), c1: CGPoint(x: -15.8, y: 15.2), c2: CGPoint(x: -17.6 + tremble * 0.6, y: 9.0), p3: CGPoint(x: -16.2, y: 3.8 + tremble * 0.5))
        return p
    }

    /// The middle of a cat's stretch, between the bow and the arch: it has come forward out of the bow onto its front legs, the middle of
    /// its back let down and its chin up, and one hind leg (the near one) stretched out straight behind it, the toes pointed. `tremble` is
    /// the shiver of holding it.
    static func rearStretch(time t: Double, tremble: CGFloat = 0) -> PetPose {
        var p = walk(phase: 0, amp: 0, time: t)
        p.action = .stretch
        p.haunch = PetOval(-4.0, 12.2, 7.6, 5.3, 0.08)
        p.chest = PetOval(6.8, 12.6, 7.3, 5.8, 0.02)
        p.head = CGPoint(x: 13.6, y: 19.8); p.headScale = 0.83
        p.tilt = 0.12; p.eyes = 0.3; p.earL = 0.12; p.earR = 0.12; p.look = CGPoint(x: 1.2, y: 0.5)
        p.legs[1] = PetLimb(CGPoint(x: 8.4, y: 9.4), CGPoint(x: 10.2, y: 4.8), CGPoint(x: 11.6, y: 0.2), 3.1)
        p.legs[3] = PetLimb(CGPoint(x: 10.6, y: 9.4), CGPoint(x: 12.2, y: 4.8), CGPoint(x: 13.6, y: 0.2), 3.1)
        p.legs[0] = PetLimb(CGPoint(x: -6.8, y: 9.6), CGPoint(x: -8.0, y: 5.0), CGPoint(x: -6.4, y: 0.2), 3.1)
        p.legs[2] = PetLimb(CGPoint(x: -4.4, y: 9.6), CGPoint(x: -9.2, y: 7.4 + tremble * 0.2), CGPoint(x: -14.2, y: 4.2 + tremble * 0.35), 3.1)
        p.tail = PetTail(p0: CGPoint(x: -10.2, y: 14.4), c1: CGPoint(x: -14.6, y: 17.6), c2: CGPoint(x: -16.0, y: 22.8), p3: CGPoint(x: -12.6, y: 27.0))
        return p
    }

    /// The whole stretch of a cat that has got up, beat by beat: from the stand it `bows` (the forelegs reach out along the ground, the
    /// rear up), comes forward out of it with a hind leg stretched out behind (`reaches`), `arches` its back high (`shiver` is the tremble
    /// at the top of it) and `stands` again. Each beat goes from where the one before ended, so no two are ever mixed with a third: a
    /// front paw that has to move steps (it lifts as it goes), and the tail swings from one beat to the next instead of sliding through a
    /// stub (curling up by half as it swings, so it stays in the room the cat has).
    static func stretching(time t: Double, bows: CGFloat, reaches: CGFloat, arches: CGFloat, stands: CGFloat, shiver: CGFloat = 0, tremble: CGFloat = 0) -> PetPose {
        let stand = walk(phase: 0, amp: 0, time: t), bowing = bow(time: t), reaching = rearStretch(time: t, tremble: tremble), hooked = arch(time: t, tremble: shiver)
        var p = stand.blended(to: bowing, bows).blended(to: reaching, reaches).blended(to: hooked, arches).blended(to: stand, stands)
        p.tail = stand.tail.swung(to: bowing.tail, bows, curl: 0.5).swung(to: reaching.tail, reaches, curl: 0.5).swung(to: hooked.tail, arches, curl: 0.5).swung(to: stand.tail, stands, curl: 0.5)
        // The front paws step back under the shoulders, the far one and then the near one.
        for k in [bows, reaches, arches] where k > 0 && k < 1 {
            p.legs[1].foot.y += 1.2 * bump(Double(k), 0, 0.6); p.legs[3].foot.y += 1.2 * bump(Double(k), 0.35, 0.95)
        }
        return p
    }

    /// Lying down, seen from the side and facing right. `rest` 1 closes the eyes and tucks the head; `curl` 1 draws the whole cat in
    /// on itself, the tail round the front of the face. `asleep` 1 slows the breathing right down (two breaths at different
    /// speeds are mixed, rather than one whose speed changes: a changing speed against the clock's large value would shake).
    static func loaf(rest r: CGFloat, curl c: CGFloat = 0, time t: Double, asleep: CGFloat = 0) -> PetPose {
        var p = PetPose()
        p.action = .sleep
        let breath = (CGFloat(sin(t * 2.1)) * (1 - asleep) + CGFloat(sin(t * 0.95)) * asleep) * (0.45 + 0.2 * c)
        p.haunch = PetOval(-3.2 + 1.7 * c, 5.0 + 0.4 * c, 10.4 + 0.2 * c, 5.2 + 0.4 * c + breath * 0.6)
        p.chest = PetOval(4.8 + 0.8 * c, 4.7 + 0.2 * c, 8.2 - 0.2 * c, 4.8 - 0.2 * c + breath * 0.5)
        p.head = CGPoint(x: 9.6 + 1.4 * c, y: 7.4 - 1.4 * r - 2.0 * c + breath * 0.3); p.headScale = 0.86 - 0.02 * c
        p.tilt = -0.18 * r - 0.32 * c; p.eyes = 1 - r; p.earL = 0.35 * r + 0.1 * c; p.earR = 0.25 * r + 0.1 * c; p.look = CGPoint(x: 0.6, y: -0.2)
        p.legs = [PetLimb(x: -6, hip: 3, foot: 2, width: 3), PetLimb(x: 8, hip: 3, foot: 1.8, width: 3), PetLimb(x: -2, hip: 3, foot: 2, width: 3), PetLimb(x: 11, hip: 3.5, foot: 1.8, width: 3)]
        let open = PetTail(p0: CGPoint(x: -11.5, y: 4.2), c1: CGPoint(x: -17.5, y: 1), c2: CGPoint(x: -19, y: 0.8), p3: CGPoint(x: -13.5, y: 0.5), width: 3.2)
        let wrapped = PetTail(p0: CGPoint(x: -11.5, y: 4.4), c1: CGPoint(x: -18.5, y: 0.6), c2: CGPoint(x: 3.5, y: -0.9), p3: CGPoint(x: 15.5, y: 2.0), width: 3.2)
        p.tail = PetTail(p0: lerp(open.p0, wrapped.p0, c), c1: lerp(open.c1, wrapped.c1, c), c2: lerp(open.c2, wrapped.c2, c), p3: lerp(open.p3, wrapped.p3, c), width: 3.2)
        return p
    }

    /// The ball game's beat: the first swat lands `playFirst` seconds into it, and one more every `playEvery`.
    static let playFirst = 1.1, playEvery = 1.3
    /// Where the ball rests, in reach of the near paw.
    static let ballRest = CGPoint(x: 17.6, y: 2.3)

    /// The swat that `u` is nearest to: how long since it landed (negative before it), from the first one on.
    static func swat(at u: Double) -> Double {
        let k = max(0, ((u - playFirst) / playEvery).rounded())
        return u - (playFirst + k * playEvery)
    }

    /// Where the ball is `u` seconds into the game. It rolls in and settles in reach; from each swat it flies up and out in an arc, comes
    /// down, and bounces lower and lower back to where the paw can reach it, as a ball does (each bounce keeps a little under half of the
    /// speed it landed with). It starts to move at the paw's contact, never before.
    static func ball(u: Double) -> CGPoint {
        guard u >= playFirst else {
            let k = ramp(u, 0.25, 1.0)
            return CGPoint(x: ballRest.x + 3.2 * (1 - k), y: ballRest.y)
        }
        let since = (u - playFirst).truncatingRemainder(dividingBy: playEvery)
        // Three arcs, each a parabola under the same pull: up 10 units over 0.62 s, then 1.85 over 0.266 s, then 0.34 over 0.115 s.
        var y: CGFloat = 0, start = 0.0
        for (length, height) in [(0.62, CGFloat(10)), (0.266, 1.85), (0.115, 0.34)] {
            if since < start + length { let s = (since - start) / length; y = height * CGFloat(4 * s * (1 - s)); break }
            start += length
        }
        let out = CGFloat(sin(.pi * min(1, since / 1.0)))
        return CGPoint(x: ballRest.x + 1.8 * out, y: ballRest.y + y)
    }

    /// Sitting and playing with a ball with the near front paw, `u` seconds into the game (`intensity` eases it in and out). Each swat has
    /// its beats: the paw is held ready, cocks up and back (the anticipation), strikes down fast onto the ball (fastest as it lands), sweeps
    /// on with it and comes back; the cat leans into the strike, its eyes and then its head follow the ball, and its tail lashes. The ball
    /// moves on the paw's contact.
    static func play(u: Double? = nil, time t: Double, intensity i: CGFloat, alert: CGFloat = 0) -> PetPose {
        let u = u ?? t
        var p = sit(time: t, alert: alert)
        p.action = .play
        let ball = self.ball(u: u), seen = self.ball(u: u - 0.12)
        p.ball = ball; p.ballSize = i
        let ready = PetLimb(CGPoint(x: 4.2, y: 9.4), CGPoint(x: 9.0, y: 7.6), CGPoint(x: 11.2, y: 5.2), 3.4)
        let cocked = PetLimb(CGPoint(x: 4.2, y: 9.8), CGPoint(x: 8.6, y: 11.2), CGPoint(x: 10.2, y: 13.4), 3.4)
        let contact = PetLimb(CGPoint(x: 4.6, y: 9.2), CGPoint(x: 10.8, y: 6.6), CGPoint(x: 15.0, y: 3.2), 3.4)
        let swept = PetLimb(CGPoint(x: 4.6, y: 9.6), CGPoint(x: 11.2, y: 9.0), CGPoint(x: 15.2, y: 8.2), 3.4)
        let tau = swat(at: u)
        var paw = ready
        if tau >= -0.3, tau < 0.32 {
            if tau < -0.09 { paw = ready.blended(to: cocked, ramp(tau, -0.3, -0.09)) }
            else if tau < 0 { paw = cocked.blended(to: contact, easeIn((tau + 0.09) / 0.09)) }
            else if tau < 0.09 { paw = contact.blended(to: swept, easeOut(tau / 0.09)) }
            else { paw = swept.blended(to: ready, ramp(tau, 0.09, 0.32)) }
        }
        p.legs[3] = p.legs[3].blended(to: paw, i)
        // It draws back a little as it cocks, leans into the strike, and comes back.
        let lean = spline(tau, [(-0.3, 0), (-0.09, -0.3), (0, 0.7), (0.12, 0.6), (0.5, 0)])
        p.chest.cx += (0.6 + lean) * i; p.head.x += (0.7 + 0.8 * lean) * i; p.chest.cy -= 0.3 * max(0, lean) * i
        p.legs[3].hip.x += 0.4 * lean * i
        // The eyes are on the ball, the head a beat behind them; the ears are forward.
        let high = (ball.y - ballRest.y) / 10, late = (seen.y - ballRest.y) / 10
        p.look.x += 1.5 * i; p.look.y += (-0.6 + 1.6 * high) * i
        p.head.y += 1.1 * late * i; p.tilt += (-0.07 - 0.05 * late) * i
        p.earL -= 0.14 * i; p.earR -= 0.18 * i; p.eyes *= 1 + 0.1 * i
        // The tail lashes, a wave from its middle to its tip.
        let lash = CGFloat(sin(u * 6)), tip = CGFloat(sin(u * 6 - 0.9))
        p.tail.c2.y += 1.6 * lash * i; p.tail.p3.y += 2.2 * tip * i; p.tail.p3.x += 1.2 * tip * i
        return p
    }

    /// Sitting with one paw raised, waving, `u` seconds into the wave (the wall clock when there is no wave to time it by). The paw waves
    /// from the elbow: the forearm leads and the paw follows it a beat later, and the head tips a little with it.
    static func wave(u: Double? = nil, time t: Double, amount a: CGFloat, alert: CGFloat = 0) -> PetPose {
        var p = sit(time: t, alert: alert)
        p.action = .wave
        let local = u ?? t
        let w = CGFloat(sin(local * 8)), tip = CGFloat(sin(local * 8 - 0.7))
        p.legs[3] = p.legs[3].blended(to: PetLimb(CGPoint(x: 4.2, y: 11), CGPoint(x: 9 + 0.6 * w, y: 16), CGPoint(x: 10.5 + 1.9 * tip, y: 21 - 0.4 * abs(tip)), 3.4), a)
        p.tilt += (-0.1 - 0.03 * w) * a; p.eyes = min(p.eyes, 1 - 0.25 * a)
        p.chest.cx += 0.3 * a; p.head.x += 0.25 * a
        return p
    }

    /// Held by the scruff for the drag ghost: legs dangling, eyes wide.
    static func lifted(time t: Double) -> PetPose {
        var p = sit(time: t)
        let sway = CGFloat(sin(t * 3))
        p.haunch = PetOval(0, 9.5, 8.6, 7.8); p.chest = PetOval(0, 15.5, 6.2, 8.2)
        p.head = CGPoint(x: 0, y: 21.4); p.eyes = 1.18; p.earL = 0.12; p.earR = 0.12; p.look = CGPoint(x: 0, y: -0.5)
        p.legs = [
            PetLimb(CGPoint(x: -5, y: 6), CGPoint(x: -5.5 + sway * 0.5, y: 2), CGPoint(x: -5.4 + sway, y: -1.6), 3), PetLimb(CGPoint(x: -3.4, y: 9), CGPoint(x: -3.8, y: 4), CGPoint(x: -3.4 - sway, y: -1.2), 3.4),
            PetLimb(CGPoint(x: 5, y: 6), CGPoint(x: 5.5 + sway * 0.5, y: 2), CGPoint(x: 5.4 + sway, y: -1.6), 3), PetLimb(CGPoint(x: 3.4, y: 9), CGPoint(x: 3.8, y: 4), CGPoint(x: 3.4 - sway, y: -1.2), 3.4),
        ]
        p.tail = PetTail(p0: CGPoint(x: -4, y: 4), c1: CGPoint(x: -9, y: -2), c2: CGPoint(x: -12 + sway * 2, y: -4), p3: CGPoint(x: -10 + sway * 3, y: -9))
        return p
    }

    // MARK: Routines

    struct Step: Equatable {
        var action: PetAction, length: Double, to: CGFloat
        init(_ action: PetAction, _ length: Double, to: CGFloat = 0) { self.action = action; self.length = length; self.to = to }
    }
    /// Strolls along the header's stage. Each leaves home and comes back (x 0); `to` is a fraction of the stage travel.
    static let routes: [[Step]] = [
        [Step(.walk, 8, to: 0.55), Step(.sit, 3), Step(.walk, 8, to: 0)],
        [Step(.walk, 10, to: 0.92), Step(.play, 6.5), Step(.walk, 10, to: 0)],
        [Step(.walk, 6, to: 0.3), Step(.wave, 3.4), Step(.walk, 6, to: 0)],
        [Step(.walk, 6, to: 0.35), Step(.sit, 2), Step(.walk, 6.5, to: 0.78), Step(.sit, 2), Step(.walk, 6, to: 0.4), Step(.sit, 1.5), Step(.walk, 6.5, to: 0)],
        [Step(.walk, 6, to: 0.5), Step(.sit, 1), Step(.walk, 6, to: 0), Step(.sit, 1), Step(.walk, 8, to: 0.85), Step(.sit, 1), Step(.walk, 8, to: 0)],
        // A stop to wash, one to look around, and a yawn at the far end before the walk back.
        [Step(.walk, 7, to: 0.5), Step(.groom, groomLength), Step(.glance, glanceLength), Step(.walk, 7, to: 0)],
        [Step(.walk, 8, to: 0.7), Step(.yawn, yawnLength), Step(.sit, 1.5), Step(.walk, 8, to: 0)],
    ]
    /// The short routes, for when the user is reading: they never go far.
    static let shortRoutes = [0, 2]

    static func length(of steps: [Step]) -> Double { steps.reduce(0) { $0 + $1.length } }

    /// The way back to the home spot from `x` (a fraction of the stage), as a route of its own.
    static func homeward(from x: CGFloat) -> [Step] { [Step(.walk, 2 + 9 * Double(abs(x)), to: 0)] }

    /// `steps`, `u` seconds in, setting off from `startX` (a fraction of the `travel` points of stage).
    static func route(_ steps: [Step], u: Double, startX: CGFloat, travel: CGFloat, scale: CGFloat, time t: Double, alert: CGFloat) -> PetPose {
        var cursor = 0.0, x = startX, facing: CGFloat = 1
        for step in steps {
            if u < cursor + step.length {
                let local = u - cursor
                if step.action == .walk { return stroll(step, u: local, from: x, travel: travel, scale: scale, time: t, alert: alert) }
                var pose = step.action == .sit ? sit(time: t, alert: alert) : perform(step.action, u: local, length: step.length, time: t, facing: facing, alert: alert)
                pose.x += x * travel
                return pose
            }
            cursor += step.length
            if step.action == .walk { facing = step.to >= x ? 1 : -1; x = step.to }
        }
        var pose = sit(time: t, alert: alert); pose.x = x * travel
        return pose
    }

    /// Walking from `x0` to `step.to`: it turns toward the way it will go (head first, then body, then legs), accelerates,
    /// glides and settles into a sit. Legs follow the distance covered and a foot that is down moves back exactly as
    /// fast as the body moves forward, so feet stay planted.
    private static func stroll(_ step: Step, u: Double, from x0: CGFloat, travel: CGFloat, scale: CGFloat, time t: Double, alert: CGFloat) -> PetPose {
        let dir: CGFloat = step.to >= x0 ? 1 : -1
        // Turning round to walk back takes longer: the tail has to come over to the other side.
        let lead = dir < 0 ? 1.3 : 0.9, d = step.length, raw = min(1, max(0, (u - lead) / (d - 2 * lead)))
        let fx = x0 + (step.to - x0) * smooth(raw)
        let amp = min(1, CGFloat(6 * raw * (1 - raw)) * 1.6)
        // One stride (2·pi) covers `strideLength` rig units; a view point is `1 / scale` units.
        let phase = Double(abs(fx - x0) * travel / scale) * 2 * .pi / Double(strideLength)
        var walker = walk(phase: phase, amp: amp, time: t)
        if dir < 0 { walker = walker.mirrored() }
        walker.x = fx * travel
        var rest = sit(time: t, alert: alert)
        if u < d / 2 { rest.x = x0 * travel; return rest.staged(to: walker, ramp(u, 0, lead)) }
        rest.x = step.to * travel
        return walker.staged(to: rest, ramp(u, d - lead, d), order: .legsFirst)
    }

    /// One in-place action, `u` seconds in; poses ease out of and back into the idle sit.
    static func perform(_ action: PetAction, u: Double, length d: Double, time t: Double, facing f: CGFloat = 1, alert: CGFloat, shift: CGFloat = 0, variant: Int = 0) -> PetPose {
        let base = sit(time: t, alert: alert)
        func face(_ p: PetPose) -> PetPose { f < 0 ? p.mirrored() : p }
        switch action {
        case .stretch:
            // A cat's stretch, in its order: it gets up and turns (head first), bows (the forelegs first), comes forward out of the bow
            // with a hind leg stretched out behind, arches its back, stands, and sits down again, the hips first. It eases in and out of
            // each beat, and holds the stretched ones with a tremble.
            let bows = ramp(u, 0.8, 1.8), reaches = ramp(u, 2.5, 3.2), arches = ramp(u, d - 3.1, d - 2.5), stands = ramp(u, d - 1.8, d - 1.1)
            let shiver = arches * (1 - stands) * CGFloat(sin(t * 38)) * ramp(u, d - 2.6, d - 2.3)
            let tremble = reaches * (1 - arches) * CGFloat(sin(t * 31)) * ramp(u, 3.15, 3.4)
            var target = stretching(time: t, bows: bows, reaches: reaches, arches: arches, stands: stands, shiver: shiver, tremble: tremble)
            // The shift is written for a cat facing right; one facing left (which `face` mirrors) goes the other way.
            target.x = shift * bows * (1 - stands) * (f < 0 ? -1 : 1)
            target = face(target)
            return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 0.8)) : target.staged(to: base, ramp(u, d - 0.8, d), order: .legsFirst), .stretch)
        case .sleep:
            let rest = ramp(u, 1.6, 2.9) * (1 - ramp(u, d - 3.4, d - 2.2))
            let curl = ramp(u, 3.0, 4.7) * (1 - ramp(u, d - 4.3, d - 3.0))
            // Asleep it breathes slowly, an ear or a paw twitches as it dreams, and it hardly stirs otherwise.
            let asleep = rest * curl
            var target = loaf(rest: rest, curl: curl, time: t, asleep: asleep)
            if let dream = event(u, period: 9.5, length: 0.7, salt: 77), asleep > 0.6 {
                let twitch = CGFloat(sin(.pi * dream)) * asleep
                target.earR -= 0.32 * twitch; target.legs[3].foot.x += 0.9 * twitch; target.legs[3].foot.y += 0.5 * twitch; target.tail.p3.y += 1.3 * twitch
            }
            target.zAlpha = ramp(u, 3.1, 4.1) * (1 - ramp(u, d - 3.0, d - 2.0)); target.zRise = CGFloat((u * 0.3).truncatingRemainder(dividingBy: 1))
            target = face(target)
            // It lies down front first and gets up the same way: the head comes up, the chest rises onto the front legs, the rear last.
            return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 1.6)) : target.staged(to: base, ramp(u, d - 1.4, d)), .sleep)
        case .play:
            let i = ramp(u, 0.3, 1) * (1 - ramp(u, d - 1, d - 0.3))
            var p = play(u: u, time: t, intensity: i, alert: alert); p.x = shift * i
            return p
        case .wave: return wave(u: u - 0.45, time: t, amount: ramp(u, 0.2, 0.7) * (1 - ramp(u, d - 0.7, d - 0.2)), alert: alert)
        case .groom: return groom(u: u, time: t, alert: alert, variant: variant)
        case .glance: return glance(u: u, time: t, alert: alert, variant: variant)
        case .yawn: return yawn(u: u, time: t)
        case .scratch: return scratch(u: u, time: t)
        case .startle: return startle(u: u, time: t, variant: variant)
        case .tailPlay: return tailPlay(u: u, time: t)
        case .loaf: return loafing(u: u, length: d, time: t, variant: variant, facing: f)
        case .hunt: return hunt(u: u, length: d, time: t, variant: variant, facing: f, shift: shift)
        case .sit, .walk, .peek, .celebrate, .land, .curious, .sad: return base
        }
    }

    /// Blends keep the label of whichever pose dominates; scheduled actions name themselves instead.
    static func labelled(_ p: PetPose, _ action: PetAction) -> PetPose {
        var r = p; r.action = p.action == .sit ? .sit : action
        return r
    }

    /// The cat's reaction to an alert: sitting tall with the ears forward, eyes wide and the head turned
    /// toward the bell, tail flicking for a moment (`age` is the seconds since it began). `base`, whatever the cat
    /// was doing, eases into it by `amount`, so even a sleeping cat looks up. It also mews once, a small mouth, as it looks.
    static func perked(from base: PetPose, time t: Double, amount: CGFloat, age: Double) -> PetPose {
        guard amount > 0 else { return base }
        var p = sit(time: t)
        p.eyes *= 1.18
        p.earL -= 0.26; p.earR -= 0.26
        p.head.y += 1.2; p.headScale = 1.05; p.chest.ry += 0.7
        p.look = CGPoint(x: 1.8, y: -0.7); p.tilt = -0.11
        let flick = CGFloat(sin(age * 17) * exp(-age * 2.2))
        p.tail.p3.y += 4 * flick; p.tail.p3.x += 1.6 * flick; p.tail.c2.y += 2.4 * flick
        // The mew: a small mouth that opens and closes once, as the cat turns to the bell.
        let mew = (age - 0.22) / 0.46
        if mew > 0, mew < 1 { p.mouth = 0.5 * CGFloat(sin(mew * .pi)); p.head.y += 0.5 * p.mouth }
        // A napping cat's z's are gone before the head has risen into them. It looks up where it is: a cat strolling stays where it was.
        var start = base
        start.zAlpha *= 1 - min(1, amount * 3)
        p.x = base.x
        return start.blended(to: p, amount)
    }

    // MARK: Helpers

    static func smooth(_ t: Double) -> CGFloat { let t = min(1, max(0, t)); return CGFloat(t * t * (3 - 2 * t)) }
    /// Leaves at full speed and slows to a stop over 0...1: a burst (a launch, the sweep after a strike).
    static func easeOut(_ t: Double) -> CGFloat { let t = min(1, max(0, t)); return CGFloat(1 - (1 - t) * (1 - t)) }
    /// Starts from rest and arrives at full speed over 0...1: a strike, fastest as it lands.
    static func easeIn(_ t: Double) -> CGFloat { let t = min(1, max(0, t)); return CGFloat(t * t) }
    /// A twitch over `a...b`: out, back past where it was and home again, starting and ending at rest (an ear, the tip of a tail).
    static func twitch(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        guard t > a, t < b else { return 0 }
        let s = (t - a) / (b - a)
        return CGFloat(sin(2 * .pi * s) * sin(.pi * s))
    }
    /// A smooth path through `(time, value)` keys: it eases out of the first and into the last, passes the ones in between without
    /// stopping, stops only where it turns back (a key higher or lower than both its neighbours), and never overshoots a key (a monotone
    /// cubic, Fritsch and Carlson's). Where `keyframe` comes to rest at every key, this flows through them, as a limb on an arc does.
    static func spline(_ u: Double, _ keys: [(Double, CGFloat)]) -> CGFloat {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if u <= first.0 { return first.1 }
        if u >= last.0 { return last.1 }
        var i = 1
        while i < keys.count - 1, u > keys[i].0 { i += 1 }
        func slope(_ k: Int) -> Double { Double(keys[k + 1].1 - keys[k].1) / (keys[k + 1].0 - keys[k].0) }
        func tangent(_ k: Int) -> Double {
            guard k > 0, k < keys.count - 1 else { return 0 }
            let a = slope(k - 1), b = slope(k)
            guard a * b > 0 else { return 0 }
            let ha = keys[k].0 - keys[k - 1].0, hb = keys[k + 1].0 - keys[k].0
            return 3 * (ha + hb) / ((2 * hb + ha) / a + (hb + 2 * ha) / b)
        }
        let a = keys[i - 1], b = keys[i], h = b.0 - a.0, s = (u - a.0) / h
        let m0 = tangent(i - 1) * h, m1 = tangent(i) * h, s2 = s * s, s3 = s2 * s
        return CGFloat((2 * s3 - 3 * s2 + 1) * Double(a.1) + (s3 - 2 * s2 + s) * m0 + (3 * s2 - 2 * s3) * Double(b.1) + (s3 - s2) * m1)
    }
    /// 0 before `a`, 1 after `b`, smooth in between.
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { smooth((t - a) / (b - a)) }
    /// Rises over `[0, a]`, holds, and falls over `[b, 1]`.
    static func hold(_ u: Double, _ a: Double, _ b: Double) -> CGFloat { ramp(u, 0, a) * (1 - ramp(u, b, 1)) }
    /// A smooth bump: 0 until `a`, up to 1 at the middle of `a...b`, back to 0 at `b`.
    static func bump(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        guard t > a, t < b else { return 0 }
        let s = CGFloat(sin((t - a) / (b - a) * .pi))
        return s * s
    }
    /// A ring-down: `sin` at `hz` that dies away at `decay` a second, starting at `t0`.
    static func ringing(_ t: Double, from t0: Double, hz: Double, decay: Double) -> CGFloat {
        guard t > t0 else { return 0 }
        let u = t - t0
        return CGFloat(sin(2 * .pi * hz * u) * exp(-decay * u))
    }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    /// Deterministic noise in 0..<1.
    static func hash(_ n: Int, _ salt: Int = 0) -> Double {
        var z = UInt64(bitPattern: Int64(n) &* 0x9E37_79B1 &+ Int64(salt) &* 0x85EB_CA6B) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    /// Progress 0...1 of a once-per-period event of the given length at a hashed offset, nil otherwise.
    static func event(_ t: Double, period: Double, length: Double, salt: Int) -> Double? {
        let n = Int(floor(t / period)), local = t - Double(n) * period
        let start = hash(n, salt) * (period - length)
        guard local >= start, local < start + length else { return nil }
        return (local - start) / length
    }
}
