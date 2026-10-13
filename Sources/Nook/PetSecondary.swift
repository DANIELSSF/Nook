import AppKit

/// A damped spring that is advanced exactly: the position and velocity after `dt` seconds are the solution of the spring's equation,
/// not a step of an integrator, so it is stable at any frame interval (a resting cat is drawn four times a second, a hopping one
/// thirty) and costs the same either way.
struct PetSpring {
    var x: CGFloat = 0, v: CGFloat = 0

    /// The coefficients of one spring for one `dt`: `e^(-zeta w dt)` and the cosine and sine of the damped frequency. Springs of one
    /// kind share them, so a frame computes three of these, not one per number.
    struct Step {
        let e, c, s, wd, zw: CGFloat
        init(w: CGFloat, zeta: CGFloat, dt: CGFloat) {
            let z = min(zeta, 0.98)
            wd = w * (1 - z * z).squareRoot(); zw = z * w
            let a = Double(wd * dt)
            e = CGFloat(exp(-Double(zw * dt))); c = CGFloat(cos(a)); s = CGFloat(sin(a))
        }
    }

    /// Moves toward `target` and returns where it is now.
    @inline(__always) mutating func advance(to target: CGFloat, _ k: Step) -> CGFloat {
        let d = x - target
        let b = (v + k.zw * d) / k.wd
        let ac = d * k.c + b * k.s
        x = target + k.e * ac
        v = k.e * (-k.zw * ac + k.wd * (b * k.c - d * k.s))
        return x
    }

    mutating func snap(to value: CGFloat) { x = value; v = 0 }
}

/// Secondary motion: the parts of a cat that are not driven but follow. The tail's tip lags the body and swings past where it is
/// going, an ear flicks and rings, the head settles after it turns, and what hangs from the neck swings with it. Each is a spring
/// pulled toward where the pose wants it, and the tail, the ears and the head also feel the whole body's acceleration (a hop leaves
/// the tail behind in the air and drops it on the landing). The tail is a chain: its middle follows where its base lags and its tip
/// where its middle lags, so a movement runs down it from the base to the tip, the way a wave runs down a whip. The ears lag the
/// head: a head that turns or moves sideways leaves them behind a moment, and they catch up with a little swing. It is laid over the
/// finished pose by the player, so every gesture gets it for free, and it is why nothing the cat does stops dead.
struct PetSecondary {
    private var c1x = PetSpring(), c1y = PetSpring(), c2x = PetSpring(), c2y = PetSpring(), p3x = PetSpring(), p3y = PetSpring()
    private var earL = PetSpring(), earR = PetSpring()
    private var headX = PetSpring(), headY = PetSpring(), tilt = PetSpring()
    private var swing = PetSpring()
    private var primed = false
    private var body = (x: CGFloat(0), y: CGFloat(0), vx: CGFloat(0), vy: CGFloat(0))
    private var headVelocity: CGFloat = 0, lastHeadX: CGFloat = 0
    /// How the drawn head moved: its sideways speed and its turning speed on the last frame, for the ears to lag.
    private var drawnHead = (x: CGFloat(0), tilt: CGFloat(0), vx: CGFloat(0), spin: CGFloat(0))
    /// How much of the lag of each link of the tail the next one takes on.
    static let chain: CGFloat = 0.5

    /// Forget where everything was (the cat reappeared, or the pose jumped): the next frame starts at rest on its pose.
    mutating func reset() { primed = false }

    /// How wound up the springs are, in rig units: zero when everything has settled on its target.
    var energy: CGFloat {
        abs(p3x.v) + abs(p3y.v) + abs(c2x.v) + abs(c2y.v) + (abs(earL.v) + abs(earR.v)) * 8 + abs(headX.v) + abs(headY.v) + abs(tilt.v) * 9 + abs(swing.v) * 3
    }

    /// Lays the follow-through over `p`. `dt` is the seconds since the last frame; `scale` the points per rig unit (the cat's
    /// horizontal position is in points).
    mutating func apply(_ p: inout PetPose, dt rawDt: Double, scale: CGFloat) {
        let bodyX = p.x / max(scale, 0.01), bodyY = p.y
        guard primed else {
            primed = true
            c1x.snap(to: p.tail.c1.x); c1y.snap(to: p.tail.c1.y); c2x.snap(to: p.tail.c2.x); c2y.snap(to: p.tail.c2.y); p3x.snap(to: p.tail.p3.x); p3y.snap(to: p.tail.p3.y)
            earL.snap(to: p.earL); earR.snap(to: p.earR); headX.snap(to: p.head.x); headY.snap(to: p.head.y); tilt.snap(to: p.tilt); swing.snap(to: 0)
            body = (bodyX, bodyY, 0, 0); lastHeadX = p.head.x; headVelocity = 0
            drawnHead = (p.head.x, p.tilt, 0, 0)
            return
        }
        let dt = CGFloat(min(0.25, max(0.001, rawDt)))
        // The body's acceleration, from how its place changed (smoothed, so one odd frame cannot throw the tail).
        let vx = (bodyX - body.x) / dt, vy = (bodyY - body.y) / dt
        let ax = (vx - body.vx) / dt, ay = (vy - body.vy) / dt
        body = (bodyX, bodyY, vx, vy)
        func inertia(_ a: CGFloat, _ w: CGFloat, _ limit: CGFloat) -> CGFloat { max(-limit, min(limit, -a / (w * w))) }

        let tailMid = PetSpring.Step(w: 13, zeta: 0.55, dt: dt), tailTip = PetSpring.Step(w: 10, zeta: 0.5, dt: dt), tailBase = PetSpring.Step(w: 17, zeta: 0.65, dt: dt)
        let ears = PetSpring.Step(w: 26, zeta: 0.42, dt: dt), head = PetSpring.Step(w: 20, zeta: 0.62, dt: dt), bell = PetSpring.Step(w: 9, zeta: 0.22, dt: dt)

        // The tail: the base moves first, the middle a beat later, the tip last and furthest, the way a whip does. Each link is pulled
        // toward where the pose wants it plus a share of how far the link before it is lagging, so the lag runs down to the tip.
        let lagX = inertia(ax, 10, 2.2), lagY = inertia(ay, 10, 2.2), k = Self.chain
        let c1 = (x: c1x.advance(to: p.tail.c1.x, tailBase), y: c1y.advance(to: p.tail.c1.y, tailBase))
        let c2 = (x: c2x.advance(to: p.tail.c2.x + lagX * 0.5 + k * (c1.x - p.tail.c1.x), tailMid), y: c2y.advance(to: p.tail.c2.y + lagY * 0.5 + k * (c1.y - p.tail.c1.y), tailMid))
        let tip = (x: p3x.advance(to: p.tail.p3.x + lagX + k * (c2.x - p.tail.c2.x), tailTip), y: p3y.advance(to: p.tail.p3.y + lagY + k * (c2.y - p.tail.c2.y), tailTip))
        p.tail.c1 = CGPoint(x: c1.x, y: c1.y); p.tail.c2 = CGPoint(x: c2.x, y: c2.y); p.tail.p3 = CGPoint(x: tip.x, y: tip.y)

        // The head settles after it moves, and trails a little behind the body.
        let hx = headX.advance(to: p.head.x + inertia(ax, 20, 0.7) * 0.5, head)
        let hy = headY.advance(to: p.head.y + inertia(ay, 20, 0.7) * 0.5, head)
        p.tilt = tilt.advance(to: p.tilt, head)

        // The ears ring a little after a flick, are thrown back by a hop, and lag the head: a head that speeds up to the right leaves
        // their tips to the left (a turn counterclockwise of the ears), one that starts to turn counterclockwise leaves them clockwise,
        // and they swing back after it. An ear's angle opens it outward, so the same turn opens the left ear and closes the right one.
        let flop = inertia(ay, 26, 0.12) * 0.45
        let headVX = (hx - drawnHead.x) / dt, spin = (p.tilt - drawnHead.tilt) / dt
        let lag = max(-0.08, min(0.08, (headVX - drawnHead.vx) / dt * 0.001 - (spin - drawnHead.spin) / dt * 0.006))
        drawnHead = (hx, p.tilt, headVX, spin)
        p.earL = earL.advance(to: p.earL - flop + lag, ears); p.earR = earR.advance(to: p.earR - flop - lag, ears)
        // A bell or a bow hangs from the neck: the head's sideways motion and its tilt swing it.
        headVelocity = (p.head.x - lastHeadX) / dt; lastHeadX = p.head.x
        let pendulum = max(-1, min(1, -p.tilt / 0.7 - headVelocity * 0.05 + inertia(ax, 9, 0.6) * 0.4))
        p.swing = swing.advance(to: pendulum, bell)
        p.head = CGPoint(x: hx, y: hy)
    }
}
