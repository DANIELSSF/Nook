import AppKit
import SwiftUI

enum PetAction: CaseIterable { case sit, walk, stretch, play, sleep, wave, groom, glance, peek, celebrate, land, curious }

struct PetOval: Equatable {
    var cx, cy, rx, ry, angle: CGFloat
    init(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ angle: CGFloat = 0) { self.cx = cx; self.cy = cy; self.rx = rx; self.ry = ry; self.angle = angle }
    var halfWidth: CGFloat { sqrt(rx * rx * cos(angle) * cos(angle) + ry * ry * sin(angle) * sin(angle)) }
    var halfHeight: CGFloat { sqrt(rx * rx * sin(angle) * sin(angle) + ry * ry * cos(angle) * cos(angle)) }
}

struct PetLimb: Equatable {
    var hip, knee, foot: CGPoint
    var width: CGFloat
    init(_ hip: CGPoint, _ knee: CGPoint, _ foot: CGPoint, _ width: CGFloat = 3.2) { self.hip = hip; self.knee = knee; self.foot = foot; self.width = width }
    /// A straight limb hanging from `hip` down to `foot`.
    init(x: CGFloat, hip: CGFloat, foot: CGFloat, width: CGFloat = 3.2) { self.init(CGPoint(x: x, y: hip), CGPoint(x: x, y: (hip + foot) / 2), CGPoint(x: x, y: foot), width) }
    func blended(to o: PetLimb, _ t: CGFloat) -> PetLimb {
        func p(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        return PetLimb(p(hip, o.hip), p(knee, o.knee), p(foot, o.foot), width + (o.width - width) * t)
    }
}

struct PetTail: Equatable {
    var p0, c1, c2, p3: CGPoint
    var width: CGFloat = 3.5
}

/// One frame of the cat. Rig coordinates are "cat units" (feet at y 0, centre at x 0, about 31 units tall); `x` moves the whole cat sideways in view points.
struct PetPose: Equatable {
    var action: PetAction = .sit
    var facing: CGFloat = 1
    var x: CGFloat = 0
    var haunch = PetOval(0, 7.2, 9.6, 7.4)
    var chest = PetOval(0, 13.5, 6.6, 8.5)
    var head = CGPoint(x: 0, y: 19.2)
    var headScale: CGFloat = 1
    var tilt: CGFloat = 0
    var earL: CGFloat = 0
    var earR: CGFloat = 0
    var eyes: CGFloat = 1
    var look = CGPoint.zero
    // Far hind, far front, near hind, near front.
    var legs = [
        PetLimb(x: -6.2, hip: 6, foot: 3.5, width: 3), PetLimb(x: -3.6, hip: 8, foot: 1.3, width: 3.8),
        PetLimb(x: 6.2, hip: 6, foot: 3.5, width: 3), PetLimb(x: 3.6, hip: 8, foot: 1.3, width: 3.8),
    ]
    var tail = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -19, y: -2), c2: CGPoint(x: -19.5, y: 9), p3: CGPoint(x: -13, y: 12))
    var ball = CGPoint(x: 19, y: 3)
    var ballSize: CGFloat = 0
    var zAlpha: CGFloat = 0
    var zRise: CGFloat = 0
    /// Lifts (+) or lowers (-) the whole cat, in rig units: a hop, a landing, or a peek that sinks it behind a ledge.
    var y: CGFloat = 0
    /// Progress 0...1 of the little sparkle beside the head; 0 draws none.
    var sparkle: CGFloat = 0

    /// Applies `f` to every animatable number of two poses (used for blending and comparing).
    func combined(_ o: PetPose, _ f: (CGFloat, CGFloat) -> CGFloat) -> PetPose {
        func p(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: f(a.x, b.x), y: f(a.y, b.y)) }
        func v(_ a: PetOval, _ b: PetOval) -> PetOval { PetOval(f(a.cx, b.cx), f(a.cy, b.cy), f(a.rx, b.rx), f(a.ry, b.ry), f(a.angle, b.angle)) }
        func l(_ a: PetLimb, _ b: PetLimb) -> PetLimb { PetLimb(p(a.hip, b.hip), p(a.knee, b.knee), p(a.foot, b.foot), f(a.width, b.width)) }
        var r = self
        r.x = f(x, o.x)
        r.haunch = v(haunch, o.haunch); r.chest = v(chest, o.chest)
        r.head = p(head, o.head); r.headScale = f(headScale, o.headScale); r.tilt = f(tilt, o.tilt)
        r.earL = f(earL, o.earL); r.earR = f(earR, o.earR); r.eyes = f(eyes, o.eyes); r.look = p(look, o.look)
        r.legs = zip(legs, o.legs).map(l)
        r.tail = PetTail(p0: p(tail.p0, o.tail.p0), c1: p(tail.c1, o.tail.c1), c2: p(tail.c2, o.tail.c2), p3: p(tail.p3, o.tail.p3), width: f(tail.width, o.tail.width))
        r.ball = p(ball, o.ball); r.ballSize = f(ballSize, o.ballSize)
        r.zAlpha = f(zAlpha, o.zAlpha); r.zRise = f(zRise, o.zRise)
        r.y = f(y, o.y); r.sparkle = f(sparkle, o.sparkle)
        return r
    }

    func blended(to o: PetPose, _ t: CGFloat) -> PetPose {
        let t = min(1, max(0, t))
        var r = combined(o) { $0 + ($1 - $0) * t }
        if t >= 0.5 { r.action = o.action; r.facing = o.facing }
        return r
    }

    /// Largest difference between any two numbers of the poses.
    func distance(to o: PetPose) -> CGFloat {
        var d: CGFloat = 0
        _ = combined(o) { d = max(d, abs($0 - $1)); return $0 }
        return d
    }

    /// Poses are authored facing right; this mirrors them to face left.
    func mirrored() -> PetPose {
        func p(_ a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: a.y) }
        var r = self
        r.facing = -facing
        r.haunch.cx = -haunch.cx; r.haunch.angle = -haunch.angle; r.chest.cx = -chest.cx; r.chest.angle = -chest.angle
        r.head = p(head); r.tilt = -tilt; r.earL = earR; r.earR = earL; r.look = p(look)
        r.legs = legs.map { PetLimb(p($0.hip), p($0.knee), p($0.foot), $0.width) }
        r.tail = PetTail(p0: p(tail.p0), c1: p(tail.c1), c2: p(tail.c2), p3: p(tail.p3), width: tail.width)
        // The ball sits where the cat looks; without one there is nothing to mirror (and nothing to blend later).
        if ballSize > 0 { r.ball = p(ball) }
        return r
    }

    /// How far the sparkles of a celebration reach from the head's centre, in rig units.
    static let sparkleReach = (left: CGFloat(11.5), right: CGFloat(15.5), up: CGFloat(12.8))
    /// The z's of a nap are too faint to draw (and to count in the bounds) below this.
    static let zVisible: CGFloat = 0.04

    /// Conservative bounds of everything drawn, in rig units (relative to `x`).
    var bounds: CGRect {
        var rect = CGRect.null
        func add(_ r: CGRect) { rect = rect.union(r) }
        func dot(_ p: CGPoint, _ r: CGFloat) { add(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        for o in [haunch, chest] { add(CGRect(x: o.cx - o.halfWidth, y: o.cy - o.halfHeight, width: 2 * o.halfWidth, height: 2 * o.halfHeight)) }
        // Head outline: ellipse extremes plus ear tips, rotated with the head.
        for c in [CGPoint(x: -9.3, y: 0), CGPoint(x: 9.3, y: 0), CGPoint(x: 0, y: -7.4), CGPoint(x: 0, y: 7.4), CGPoint(x: -7.5, y: 12.2), CGPoint(x: 7.5, y: 12.2)] {
            let x = c.x * headScale, y = c.y * headScale
            dot(CGPoint(x: head.x + x * cos(tilt) - y * sin(tilt), y: head.y + x * sin(tilt) + y * cos(tilt)), 0)
        }
        for leg in legs { for p in [leg.hip, leg.knee, leg.foot] { dot(p, leg.width / 2) } }
        for i in 0...12 {
            let u = CGFloat(i) / 12, v = 1 - u
            dot(CGPoint(x: v * v * v * tail.p0.x + 3 * v * v * u * tail.c1.x + 3 * v * u * u * tail.c2.x + u * u * u * tail.p3.x,
                        y: v * v * v * tail.p0.y + 3 * v * v * u * tail.c1.y + 3 * v * u * u * tail.c2.y + u * u * u * tail.p3.y), tail.width / 2)
        }
        if ballSize > 0 { dot(ball, 2.4 * ballSize) }
        if zAlpha > Self.zVisible { add(CGRect(x: head.x - 3, y: head.y + 4, width: 13, height: 22)) }
        if sparkle > 0 { add(CGRect(x: head.x - Self.sparkleReach.left, y: head.y - 2, width: Self.sparkleReach.left + Self.sparkleReach.right, height: Self.sparkleReach.up + 2)) }
        return rect.offsetBy(dx: 0, dy: y)
    }
}

enum PetAnimation {
    /// Drawn extent of the cat beyond its anchor, in rig units, over every pose the gestures can produce.
    static let reach = (left: CGFloat(22), right: CGFloat(22))
    /// Compact wing: the cat is anchored at `compactAnchor` points, drawn at `compactScale`, and must stay inside `wing` (the cutout starts at 30).
    static let compactAnchor: CGFloat = 15.5, compactScale: CGFloat = 0.6, wing: ClosedRange<CGFloat> = 2...28.5
    /// Frame intervals while animating, and the slow check that wakes a hidden pet when its panel returns.
    /// Motion frame intervals (display-synced); idle breathing drops to `PetPace.slow`. Each frame's
    /// cost is mostly Core Animation committing it, so the always-on notch cat uses fewer frames
    /// than the header, which is only drawn while the island is open.
    static let compactInterval = 1.0 / 24, headerInterval = 1.0 / 60, watchdogInterval = 2.0
    /// A foot higher than this (rig units) is a paw raised to the face, drawn over the head.
    static let raisedAbove: CGFloat = 14.5
    static var motionReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Rigs (authored facing right)

    /// Front-facing sit, the character's home pose. `alert` perks it up while the terminal is working.
    static func sit(time t: Double, alert: CGFloat = 0) -> PetPose {
        var p = PetPose()
        let breath = CGFloat(sin(t * 1.7)) * 0.25
        p.chest.ry += breath; p.head.y += breath * 0.6
        // Blink, ear twitch, glance and tail flick fire at hashed moments so the cycle never looks mechanical.
        if let u = event(t, period: 3.6, length: 0.22, salt: 1) { p.eyes = CGFloat(1 - sin(.pi * u)) }
        if let u = event(t, period: 8.5, length: 0.4, salt: 3) {
            let twitch = CGFloat(sin(.pi * u)) * 0.5
            if hash(Int(floor(t / 8.5)), 9) < 0.5 { p.earL = -twitch } else { p.earR = -twitch }
        }
        if let u = event(t, period: 10, length: 2.6, salt: 4) {
            let dir: CGFloat = hash(Int(floor(t / 10)), 8) < 0.5 ? -1 : 1
            let g = hold(u, 0.2, 0.8)
            p.look.x = dir * 1.5 * g; p.look.y = 0.4 * g; p.tilt = -dir * 0.07 * g
        }
        let sway = CGFloat(sin(t * 1.4))
        p.tail.p3.x += sway * 1.2; p.tail.p3.y += sway * 0.8; p.tail.c2.y += CGFloat(sin(t * 1.4 + 1)) * 1.2
        if let u = event(t, period: 6.5, length: 0.9, salt: 2) {
            let flick = CGFloat(sin(u * .pi * 4)) * CGFloat(1 - u)
            p.tail.p3.y += 3.5 * flick; p.tail.p3.x += 1.5 * flick; p.tail.c2.y += 2 * flick
        }
        if alert > 0 {
            // Working: eyes wide, ears forward, scanning, tail flicking and the odd paw tap.
            p.eyes *= 1 + 0.12 * alert; p.earL -= 0.1 * alert; p.earR -= 0.1 * alert
            p.look.x += CGFloat(sin(t * 0.9)) * 1.3 * alert; p.look.y += 0.3 * alert
            p.tilt += CGFloat(sin(t * 0.9 - 0.4)) * 0.05 * alert
            let flick = CGFloat(sin(t * 5.2)) * CGFloat(max(0, sin(t * 1.1)))
            p.tail.p3.y += 3 * flick * alert; p.tail.p3.x += 2 * flick * alert; p.tail.c2.y += 1.5 * flick * alert
            let tap = CGFloat(max(0, sin(t * 7))) * CGFloat(max(0, sin(t * 0.8 + 0.3))) * 2.2 * alert
            p.legs[3].foot.y += tap; p.legs[3].knee.y += tap * 0.6
        }
        return p
    }

    /// Four-legged stand/walk. `phase` is the gait angle, `amp` scales the stride (0 stands still).
    static func walk(phase: Double, amp: CGFloat, time t: Double) -> PetPose {
        var p = PetPose()
        p.action = .walk
        let bob = amp * CGFloat(cos(2 * phase)) * 0.45
        p.haunch = PetOval(-6.6, 12.4 + bob, 7.6, 5.4); p.chest = PetOval(4.4, 12.9 + bob, 7.3, 5.8)
        p.head = CGPoint(x: 12.4, y: 19.4 + bob * 1.4); p.headScale = 0.82
        p.look = CGPoint(x: 1.3, y: -0.2)
        // Hip x, gait phase offset (diagonal pairs move together), knee bend.
        let setup: [(CGFloat, Double, CGFloat)] = [(-9.6, 0, -1.8), (6.0, .pi, 1.2), (-6.8, .pi, -1.8), (8.6, 0, 1.2)]
        for (i, s) in setup.enumerated() {
            let step = gait(phase + s.1)
            let swing = amp * halfStride * step.swing, lift = amp * 3.2 * step.lift
            let hip = CGPoint(x: s.0, y: 8.4 + bob), foot = CGPoint(x: s.0 + swing, y: lift)
            p.legs[i] = PetLimb(hip, CGPoint(x: (hip.x + foot.x) / 2 + s.2 * (1 + lift / 4), y: (hip.y + foot.y) / 2), foot, 3.1)
        }
        let sway = CGFloat(sin(t * 2.2))
        p.tail = PetTail(p0: CGPoint(x: -12.5, y: 14), c1: CGPoint(x: -18, y: 13), c2: CGPoint(x: -19.5 + sway, y: 19), p3: CGPoint(x: -16 + sway * 1.5, y: 25 + sway))
        return p
    }
    /// Half the foot travel of a stride, in rig units.
    static let halfStride: CGFloat = 5

    /// One foot at gait angle `ph`: how far it is along its stride (-1 back ... 1 forward) and how high it is lifted
    /// (0...1). A foot is down for half the cycle and slides back along a straight line, so seen from the ground it
    /// stays still: with the body moving `4 * halfStride` units per cycle, the foot's backward travel in stance is
    /// exactly the body's forward travel. The other half it swings forward in an arc.
    static func gait(_ ph: Double) -> (swing: CGFloat, lift: CGFloat) {
        var p = (ph - .pi / 2) / (2 * .pi)
        p -= floor(p)
        if p < 0.5 { return (CGFloat(1 - 4 * p), 0) }
        let s = (p - 0.5) * 2
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

    /// Curled loaf. `rest` 1 closes the eyes and tucks the head.
    static func loaf(rest r: CGFloat, time t: Double) -> PetPose {
        var p = PetPose()
        p.action = .sleep
        let breath = CGFloat(sin(t * 2.1)) * 0.45
        p.haunch = PetOval(-3.2, 5.0, 10.4, 5.2 + breath * 0.6); p.chest = PetOval(4.8, 4.7, 8.2, 4.8 + breath * 0.5)
        p.head = CGPoint(x: 9.6, y: 7.4 - 1.4 * r + breath * 0.3); p.headScale = 0.86
        p.tilt = -0.18 * r; p.eyes = 1 - r; p.earL = 0.35 * r; p.earR = 0.25 * r; p.look = CGPoint(x: 0.6, y: -0.2)
        p.legs = [PetLimb(x: -6, hip: 3, foot: 2, width: 3), PetLimb(x: 8, hip: 3, foot: 1.8, width: 3), PetLimb(x: -2, hip: 3, foot: 2, width: 3), PetLimb(x: 11, hip: 3.5, foot: 1.8, width: 3)]
        p.tail = PetTail(p0: CGPoint(x: -11.5, y: 4.2), c1: CGPoint(x: -17.5, y: 1), c2: CGPoint(x: -4, y: -0.2), p3: CGPoint(x: 6, y: 1.2), width: 3.2)
        return p
    }

    /// Sitting and batting a bouncing ball with the near front paw.
    static func play(time t: Double, intensity i: CGFloat, alert: CGFloat = 0) -> PetPose {
        var p = sit(time: t, alert: alert)
        p.action = .play
        let hop = CGFloat(abs(sin(t * 3.6)))
        let swat = CGFloat(max(0, sin(t * 3.6 - 0.9)))
        p.ball = CGPoint(x: 18.5 + 0.8 * CGFloat(sin(t * 1.8)), y: 2.2 + 8.5 * hop * i); p.ballSize = i
        p.look.x += 1.6 * i; p.look.y += (0.9 - 1.5 * hop) * i; p.tilt += -0.08 * i + 0.06 * swat * i
        p.legs[3] = p.legs[3].blended(to: PetLimb(CGPoint(x: 4.2, y: 9.5), CGPoint(x: 10 + 2 * swat, y: 8), CGPoint(x: 9.5 + 4 * swat, y: 8.3 + 5 * swat), 3.4), i)
        p.chest.cx += 0.8 * i; p.head.x += 0.8 * i
        let wag = CGFloat(sin(t * 7.5)) * i
        p.tail.p3.y += 2 * wag; p.tail.p3.x += 1.5 * wag; p.tail.c2.y += 2.5 * wag
        return p
    }

    /// Sitting with one paw raised, waving.
    static func wave(time t: Double, amount a: CGFloat, alert: CGFloat = 0) -> PetPose {
        var p = sit(time: t, alert: alert)
        p.action = .wave
        let w = CGFloat(sin(t * 8))
        p.legs[3] = p.legs[3].blended(to: PetLimb(CGPoint(x: 4.2, y: 11), CGPoint(x: 9 + 0.5 * w, y: 16), CGPoint(x: 10.5 + 1.8 * w, y: 21), 3.4), a)
        p.tilt += -0.1 * a; p.eyes = min(p.eyes, 1 - 0.25 * a)
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
        // One stride (2·pi) covers `4 * halfStride` rig units; a view point is `1 / scale` units.
        let phase = Double(abs(fx - x0) * travel / scale) * 2 * .pi / (4 * Double(halfStride))
        var walker = walk(phase: phase, amp: amp, time: t)
        if dir < 0 { walker = walker.mirrored() }
        walker.x = fx * travel
        var rest = sit(time: t, alert: alert)
        if u < d / 2 { rest.x = x0 * travel; return rest.staged(to: walker, ramp(u, 0, lead)) }
        rest.x = step.to * travel
        return walker.staged(to: rest, ramp(u, d - lead, d), order: .legsFirst)
    }
    /// One in-place action, `u` seconds in; poses ease out of and back into the idle sit.
    static func perform(_ action: PetAction, u: Double, length d: Double, time t: Double, facing f: CGFloat = 1, alert: CGFloat, shift: CGFloat = 0) -> PetPose {
        let base = sit(time: t, alert: alert)
        func face(_ p: PetPose) -> PetPose { f < 0 ? p.mirrored() : p }
        switch action {
        case .stretch:
            // Turns toward its stretch head first, then bows; the way out runs the other way round.
            let amount = ramp(u, 0.8, 1.6) * (1 - ramp(u, d - 1.8, d - 0.9))
            var target = walk(phase: 0, amp: 0, time: t).blended(to: bow(time: t), amount)
            target.x = shift * amount
            target = face(target)
            return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 0.8)) : target.staged(to: base, ramp(u, d - 0.8, d), order: .legsFirst), .stretch)
        case .sleep:
            let rest = ramp(u, 1.6, 2.9) * (1 - ramp(u, d - 2.7, d - 1.5))
            var target = loaf(rest: rest, time: t)
            target.zAlpha = ramp(u, 3.1, 4.1) * (1 - ramp(u, d - 3.0, d - 2.0)); target.zRise = CGFloat((u * 0.3).truncatingRemainder(dividingBy: 1))
            target = face(target)
            return labelled(u < d / 2 ? base.staged(to: target, ramp(u, 0, 1.6)) : target.staged(to: base, ramp(u, d - 1.4, d), order: .legsFirst), .sleep)
        case .play:
            let i = ramp(u, 0.3, 1) * (1 - ramp(u, d - 1, d - 0.3))
            var p = play(time: t, intensity: i, alert: alert); p.x = shift * i
            return p
        case .wave: return wave(time: t, amount: ramp(u, 0.2, 0.7) * (1 - ramp(u, d - 0.7, d - 0.2)), alert: alert)
        case .sit, .walk, .groom, .glance, .peek, .celebrate, .land, .curious: return base
        }
    }

    /// Blends keep the label of whichever pose dominates; scheduled actions name themselves instead.
    private static func labelled(_ p: PetPose, _ action: PetAction) -> PetPose {
        var r = p; r.action = p.action == .sit ? .sit : action
        return r
    }

    /// The cat's reaction to an alert: sitting tall with the ears forward, eyes wide and the head turned
    /// toward the bell, tail flicking for a moment (`age` is the seconds since it began). `base`, whatever the cat
    /// was doing, eases into it by `amount`, so even a sleeping cat looks up.
    static func perked(from base: PetPose, time t: Double, amount: CGFloat, age: Double) -> PetPose {
        guard amount > 0 else { return base }
        var p = sit(time: t)
        p.eyes *= 1.18
        p.earL -= 0.26; p.earR -= 0.26
        p.head.y += 1.2; p.headScale = 1.05; p.chest.ry += 0.7
        p.look = CGPoint(x: 1.8, y: -0.7); p.tilt = -0.11
        let flick = CGFloat(sin(age * 17) * exp(-age * 2.2))
        p.tail.p3.y += 4 * flick; p.tail.p3.x += 1.6 * flick; p.tail.c2.y += 2.4 * flick
        // A napping cat's z's are gone before the head has risen into them.
        var start = base
        start.zAlpha *= 1 - min(1, amount * 3)
        return start.blended(to: p, amount)
    }

    // MARK: Helpers

    static func smooth(_ t: Double) -> CGFloat { let t = min(1, max(0, t)); return CGFloat(t * t * (3 - 2 * t)) }
    /// 0 before `a`, 1 after `b`, smooth in between.
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat { smooth((t - a) / (b - a)) }
    /// Rises over `[0, a]`, holds, and falls over `[b, 1]`.
    static func hold(_ u: Double, _ a: Double, _ b: Double) -> CGFloat { ramp(u, 0, a) * (1 - ramp(u, b, 1)) }
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
    // MARK: Drawing

    /// Paints the cat in rig units (feet at y 0). A `ledge` is the lowest y that may be painted: a cat peeking over
    /// the island's edge sinks below it and is cut there, so nothing ever lands outside the drawable area.
    static func draw(_ pose: PetPose, color: NSColor, ledge: CGFloat? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        if let ledge { cg.clip(to: CGRect(x: -400, y: ledge, width: 800, height: 800)) }
        cg.translateBy(x: 0, y: pose.y)
        color.setFill(); color.setStroke()
        func limb(_ l: PetLimb, halo: Bool = false) {
            if halo {
                // A paw raised in front of the face is white on white: a thin black seam around the forearm keeps it readable.
                let seam = NSBezierPath(); seam.move(to: l.knee); seam.line(to: l.foot)
                NSColor.black.setStroke()
                seam.lineWidth = l.width + 1.9; seam.lineCapStyle = .round; seam.stroke()
                color.setStroke()
            }
            let path = NSBezierPath(); path.move(to: l.hip); path.line(to: l.knee); path.line(to: l.foot)
            path.lineWidth = l.width; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        /// Legs lifted to the face are drawn over the head instead of behind it.
        func raised(_ l: PetLimb) -> Bool { l.foot.y > PetAnimation.raisedAbove }
        func oval(_ o: PetOval) {
            cg.saveGState(); cg.translateBy(x: o.cx, y: o.cy); cg.rotate(by: o.angle)
            NSBezierPath(ovalIn: NSRect(x: -o.rx, y: -o.ry, width: 2 * o.rx, height: 2 * o.ry)).fill()
            cg.restoreGState()
        }
        let t = pose.tail
        let tail = NSBezierPath(); tail.move(to: t.p0); tail.curve(to: t.p3, controlPoint1: t.c1, controlPoint2: t.c2)
        tail.lineWidth = t.width; tail.lineCapStyle = .round; tail.stroke()
        pose.legs.prefix(2).filter { !raised($0) }.forEach { limb($0) }
        oval(pose.haunch); oval(pose.chest)
        pose.legs.dropFirst(2).filter { !raised($0) }.forEach { limb($0) }
        // The head has its own frame so tilt and scale carry the ears and eyes along.
        cg.saveGState(); cg.translateBy(x: pose.head.x, y: pose.head.y); cg.scaleBy(x: pose.headScale, y: pose.headScale); cg.rotate(by: pose.tilt)
        NSBezierPath(ovalIn: NSRect(x: -9.3, y: -7.4, width: 18.6, height: 14.8)).fill()
        for (side, angle) in [(CGFloat(-1), pose.earL), (CGFloat(1), pose.earR)] {
            cg.saveGState(); cg.translateBy(x: side * 5.8, y: 4.4); cg.rotate(by: side * -angle); cg.translateBy(x: -side * 5.8, y: -4.4)
            let ear = NSBezierPath()
            ear.move(to: CGPoint(x: side * 9.1, y: 1.6)); ear.line(to: CGPoint(x: side * 7.5, y: 12.2)); ear.line(to: CGPoint(x: side * 2.2, y: 6.6)); ear.close(); ear.fill()
            cg.restoreGState()
        }
        NSColor.black.setFill()
        let open = max(0, pose.eyes)
        for side: CGFloat in [-1, 1] {
            let w = 2.2 + 0.9 * (1 - min(1, open)), h = max(0.55, 2.9 * open)
            NSBezierPath(ovalIn: NSRect(x: side * 4.3 + pose.look.x - w / 2, y: 0.3 + pose.look.y - h / 2, width: w, height: h)).fill()
        }
        cg.restoreGState()
        pose.legs.filter(raised).forEach { limb($0, halo: true) }
        if pose.ballSize > 0 {
            NSColor.systemMint.withAlphaComponent(0.9).setFill()
            let r = 2.3 * pose.ballSize
            NSBezierPath(ovalIn: NSRect(x: pose.ball.x - r, y: pose.ball.y - r, width: 2 * r, height: 2 * r)).fill()
        }
        if pose.zAlpha > PetPose.zVisible {
            for i in 0..<2 {
                let rise = (pose.zRise + CGFloat(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let size = 1.7 + 0.5 * CGFloat(i) + rise * 1.1
                let at = CGPoint(x: pose.head.x + 0.5 + rise * 6, y: pose.head.y + 7 + rise * 15)
                color.withAlphaComponent(0.6 * pose.zAlpha * sin(rise * .pi)).setStroke()
                let z = NSBezierPath()
                z.move(to: CGPoint(x: at.x - size, y: at.y + size)); z.line(to: CGPoint(x: at.x + size, y: at.y + size))
                z.line(to: CGPoint(x: at.x - size, y: at.y - size)); z.line(to: CGPoint(x: at.x + size, y: at.y - size))
                z.lineWidth = 1.1; z.lineCapStyle = .round; z.lineJoinStyle = .round; z.stroke()
            }
        }
        if pose.sparkle > 0 { drawSparkles(pose, color: color) }
    }

    /// The celebration's glints: three four-point stars around the head, each swelling and fading in turn.
    private static func drawSparkles(_ pose: PetPose, color: NSColor) {
        // Offset from the head, size, and the part of the sequence (0...1) where each one shines.
        let stars: [(dx: CGFloat, dy: CGFloat, size: CGFloat, from: CGFloat, to: CGFloat)] = [
            (10.6, 9.4, 2.9, 0.0, 0.7), (-10.2, 8.2, 2.1, 0.18, 0.85), (13.2, 2.4, 1.8, 0.3, 1.0),
        ]
        for star in stars {
            let local = (pose.sparkle - star.from) / (star.to - star.from)
            guard local > 0, local < 1 else { continue }
            let glow = CGFloat(sin(Double(local) * .pi)), s = star.size * (0.45 + 0.55 * glow), k = s * 0.3
            color.withAlphaComponent(0.95 * glow).setFill()
            let c = CGPoint(x: pose.head.x + star.dx, y: pose.head.y + star.dy)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x, y: c.y + s)); path.line(to: CGPoint(x: c.x + k, y: c.y + k))
            path.line(to: CGPoint(x: c.x + s, y: c.y)); path.line(to: CGPoint(x: c.x + k, y: c.y - k))
            path.line(to: CGPoint(x: c.x, y: c.y - s)); path.line(to: CGPoint(x: c.x - k, y: c.y - k))
            path.line(to: CGPoint(x: c.x - s, y: c.y)); path.line(to: CGPoint(x: c.x - k, y: c.y + k))
            path.close(); path.fill()
        }
    }
}

/// Runs a cat: owns the director and the clocks, eases the working state, and hands out the pose to draw.
struct PetPlayer {
    enum Layout: Equatable {
        case compact(height: CGFloat = 32)
        case header(travel: CGFloat, scale: CGFloat = 0.5, height: CGFloat = 32)
        var stage: PetStage {
            switch self {
            case .compact(let height): .compact(height: height)
            case .header(let travel, let scale, let height): .header(travel: travel, scale: scale, height: height)
            }
        }
    }
    private(set) var director: PetDirector
    /// Free-running clock (system uptime), so every sitting cat on screen is in the same phase.
    private(set) var wall: Double = 0
    private(set) var alert: Double = 0
    private var last: Double?

    init(layout: PetLayout, seed: Int = 0) { director = PetDirector(layout: layout, seed: seed) }
    /// A random seed, so each launch has its own routine.
    static func randomSeed() -> Int { Int.random(in: 0..<100_000) }

    /// Back at home, calm, when the view reappears; the rhythm picks up where it was.
    mutating func settle() { last = nil; director.settle() }
    /// The cat was put down after a drag.
    mutating func land() { director.land() }
    /// Whether the frames are worth drawing at the full rate.
    var isBusy: Bool { director.isBusy }
    /// Starts a gesture now instead of waiting for its turn (previews and tests).
    mutating func begin(_ kind: PetDirector.Kind, layout: Layout, focus: PetFocus = .free) { director.start(kind, stage: layout.stage, focus: focus) }

    /// - Parameters:
    ///   - motion: false when Reduce Motion or the pet preference is on; the pose is then a fixed one for the state.
    ///   - input: the world as it is now: the pointer, a drag, an alert, completions, what the user is doing.
    mutating func pose(now: Double, layout: Layout, motion: Bool, input: PetInput) -> PetPose {
        guard motion else { last = nil; return PetAnimation.staticPose(working: input.working, attention: input.needsAttention) }
        let dt = last.map { min(0.2, max(0, now - $0)) } ?? 0
        last = now; wall = now
        alert = Self.follow(alert, input.working ? 1 : 0, dt / 0.6)
        let stage = layout.stage
        director.update(dt: dt, input, stage: stage)
        return director.pose(wall: wall, alert: PetAnimation.smooth(alert), input: input, stage: stage)
    }
    private static func follow(_ value: Double, _ target: Double, _ step: Double) -> Double {
        value < target ? min(target, value + step) : max(target, value - step)
    }
}

/// Seconds since the user last touched the keyboard, scrolled, or did anything at all, read from the system's input
/// counters (no permission needed). Asked at most once a second, however often the cat's frames call it.
struct PetUserProbe {
    private var at = -1000.0
    private(set) var keyAge = 1e9, scrollAge = 1e9, idle = 0.0
    mutating func read(now: Double) {
        guard now - at >= 1 else { return }
        at = now
        func age(_ type: CGEventType) -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) }
        keyAge = age(.keyDown); scrollAge = age(.scrollWheel)
        idle = CGEventType(rawValue: ~0).map(age) ?? min(keyAge, scrollAge, age(.mouseMoved), age(.leftMouseDown))
    }
}

/// Repeating main-run-loop timer whose interval can change; `stop()` leaves no timer behind.
final class PetTicker {
    private var timer: Timer?
    private var link: CADisplayLink?
    private(set) var interval: TimeInterval = 0
    private let fire: () -> Void
    /// The view whose screen paces motion frames; its display link also pauses when it isn't visible.
    weak var host: NSView?
    init(_ fire: @escaping () -> Void) { self.fire = fire }
    deinit { stop() }
    func run(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        stop()
        interval = seconds
        // Motion frames follow the display's refresh for smooth movement; slow ticks stay on a
        // cheap timer the system may coalesce.
        if seconds < 1.0 / 20, let link = host?.displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick)) {
            let rate = Float((1 / seconds).rounded())
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            self.link = link
            return
        }
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in self?.fire() }
        timer.tolerance = seconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil; link?.invalidate(); link = nil; interval = 0 }

    /// The display link retains its target; a weak hop keeps it from keeping the ticker alive.
    private final class LinkTarget: NSObject {
        weak var ticker: PetTicker?
        init(_ ticker: PetTicker) { self.ticker = ticker }
        @objc func tick() { ticker?.fire() }
    }
}

/// Frame pacing by how fast the pose changes: the full rate for clear movement (a step, a blink,
/// a tail flick), half for gentle sway, a few frames a second while it only breathes. Measured
/// on the player, the working cat sways most of the time, so a single threshold kept it at full
/// rate almost always; any clear movement brings the full rate back on the next tick.
struct PetPace {
    var fast: Double
    var slow = 1.0 / 8
    var medium: Double { min(slow, fast * 2) }
    private var last: (pose: PetPose, time: Double)?
    private var quietSince: Double?

    init(fast: Double) { self.fast = fast }

    mutating func interval(for pose: PetPose, now: Double) -> Double {
        defer { last = (pose, now) }
        guard let last, now > last.time else { return fast }
        let speed = pose.distance(to: last.pose) / CGFloat(now - last.time)
        if speed > 6 || pose.action != last.pose.action { quietSince = nil; return fast }
        if speed > 2.5 { quietSince = nil; return medium }
        let since = quietSince ?? now
        quietSince = since
        return now - since > 0.6 ? slow : medium
    }
}

extension NSView {
    /// Whether the pointer is within `margin` points of `rect` (view coordinates), even while another app is active.
    func pointerIsNear(_ rect: NSRect, margin: CGFloat) -> Bool {
        guard let window else { return false }
        return rect.insetBy(dx: -margin, dy: -margin).contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// What the pointer pulls on a cat whose head is at `head` (view coordinates): nil unless it is within `enter`
    /// points (`leave` once it has been noticed, so the edge doesn't flicker) or `over` the cat itself. Works while
    /// another app is active.
    func petGaze(head: CGPoint, enter: CGFloat, leave: CGFloat, noticed: inout Bool, over: Bool) -> PetGaze? {
        guard let window else { noticed = false; return nil }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let dx = point.x - head.x, dy = point.y - head.y
        let near = over || PetDirector.pointerNear(distance: hypot(dx, dy), wasNear: noticed, enter: enter, leave: leave)
        noticed = near
        return near ? PetGaze(dx: dx / 40, dy: dy / 24) : nil
    }
}

struct HeaderPetStage: NSViewRepresentable {
    var animated: Bool
    var working: Bool
    var needsAttention = false
    var controller: NotchController?
    func makeNSView(context: Context) -> HeaderPetView { HeaderPetView() }
    func updateNSView(_ view: HeaderPetView, context: Context) {
        view.controller = controller; view.animated = animated; view.working = working; view.needsAttention = needsAttention
    }
}

/// Header stage: the cat sits on the "Nook" title and strolls and plays to its right, never beyond the view.
final class HeaderPetView: NSView {
    var animated = true { didSet { if animated != oldValue { refresh() } } }
    var working = false { didSet { if working != oldValue { refresh() } } }
    var needsAttention = false { didSet { if needsAttention != oldValue { refresh() } } }
    weak var controller: NotchController?
    /// The cat walks the header's middle band; without a title under it, it sits centred in the row.
    static let homeX: CGFloat = 22, ground: CGFloat = 8
    private var player = PetPlayer(layout: .header, seed: PetPlayer.randomSeed())
    var pose = PetPose()
    private lazy var ticker = PetTicker { [weak self] in self?.step() }
    /// Seconds between the cat's frames right now: 0 when it has no timer at all (a still cat), the watchdog's while hidden.
    var frameInterval: TimeInterval { ticker.interval }
    private var pace = PetPace(fast: PetAnimation.headerInterval)
    private var user = PetUserProbe()
    private var noticed = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowObserver: NSObjectProtocol?
    private var wasVisible = false
    private var dragStart: CGPoint?
    private var dragging = false

    var scale: CGFloat { min(0.5, max(0.3, (bounds.height - 15.5) / 31.5)) }
    var travel: CGFloat { max(0, bounds.width - Self.homeX - PetAnimation.reach.right * scale - 4) }
    var layout: PetPlayer.Layout { .header(travel: travel, scale: scale, height: bounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Arrastra el gatito a la terminal que quieres seguir."
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Gatito de Nook; arrastrar para conectar una terminal")
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObserver.map(NotificationCenter.default.removeObserver)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { controller?.expand(focus: true); return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObserver.map(NotificationCenter.default.removeObserver); windowObserver = nil
        guard let window else { ticker.stop(); wasVisible = false; return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.step() }
        refresh()
    }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; dragging = false; controller?.cancelScheduledExpand(); step() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, controller != nil else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 5 { dragging = true }
        if dragging { NSCursor.closedHand.set(); controller?.dragPet(to: point) }
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        if dragging { controller?.finishPetDrag(at: NSEvent.mouseLocation) }
        else { controller?.expand(focus: true) }
        dragging = false; dragStart = nil
    }

    /// Re-evaluates whether the cat should move at all; a still cat has no timer.
    private func refresh() {
        guard animated, !PetAnimation.motionReduced else {
            ticker.stop(); player.settle(); wasVisible = false
            let still = PetAnimation.staticPose(working: working, attention: needsAttention)
            if pose != still { pose = still; needsDisplay = true }
            return
        }
        if ticker.interval == 0 { ticker.run(every: PetAnimation.watchdogInterval) }
        step()
    }

    private func step() {
        guard animated, !PetAnimation.motionReduced else { return refresh() }
        // Hidden panels only keep a slow watchdog alive so the cat wakes up when the island opens again.
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true else { wasVisible = false; ticker.run(every: PetAnimation.watchdogInterval); return }
        if !wasVisible { wasVisible = true; player.settle(); ticker.host = self; ticker.run(every: PetAnimation.headerInterval) }
        let now = ProcessInfo.processInfo.systemUptime
        let model = controller?.model
        let head = CGPoint(x: Self.homeX + pose.x + pose.head.x * scale, y: Self.ground + (pose.head.y + pose.y) * scale)
        let gaze = petGaze(head: head, enter: 34, leave: 46, noticed: &noticed, over: dragStart != nil)
        user.read(now: now)
        // Typing in Nook's own field, or the panel having the keyboard, is the user reading and writing here.
        let focus = PetFocus.from(keyAge: user.keyAge, scrollAge: user.scrollAge, composing: model?.selected?.draft.isEmpty == false, panelKey: window?.isKeyWindow == true)
        // Put down after a drag: it lands once the panel is showing again (after the connection sheet, if any).
        if controller?.takePetLanding() == true { player.land() }
        let input = PetInput(working: working, gaze: gaze, dragging: dragging, completions: model?.completions ?? 0, focus: focus, idle: user.idle, needsAttention: needsAttention)
        let next = player.pose(now: now, layout: layout, motion: true, input: input)
        var wanted = pace.interval(for: next, now: now)
        if player.isBusy { wanted = PetAnimation.headerInterval }
        ticker.run(every: wanted)
        if next.distance(to: pose) > 0.01 || next.action != pose.action { pose = next; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        cg.clip(to: bounds)
        cg.translateBy(x: Self.homeX + pose.x, y: Self.ground); cg.scaleBy(x: scale, y: scale)
        PetAnimation.draw(pose, color: .white, ledge: -Self.ground / scale)
    }
}
