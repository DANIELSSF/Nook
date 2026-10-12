import AppKit

// The sad cat: the one that looks up from the question before quitting ("¿Seguro que quieres salir?"). It is the same cat, with the same rig, coat and
// painter as every other (`PetPose`): only its pose is new. Its head hangs and leans, its ears fold out and down, its eyes are heavy and wet, its tail lies
// limp along the ground, a tear runs down its cheek now and then, and it sighs. Nothing here is a gesture of the director's: it is a scene, a pure function of
// the seconds `t` since it began, so the views that show it (`SadCatView`, the fallback alert's picture) need no director, no clock of their own and no state.

extension PetAnimation {
    /// The tear's schedule: the first wells up at `tearFirst` seconds, runs for `tearLength`, and a new one follows every `tearEvery` seconds.
    static let tearFirst = 0.9, tearLength = 2.1, tearEvery = 6.4
    /// A slow blink every this many seconds (its lids come down over `sadBlinkLength`).
    static let sadBlinkEvery = 4.6, sadBlinkLength = 0.5
    /// How long the cat takes to droop when the scene begins.
    static let sadEntrance = 0.85
    /// How far the drooped cat reaches on its stage, in rig units: its limp tail runs well to the left of where the sitting cat's tail curls, so the scene draws it shifted right by
    /// `sadShift` and fits its width (`sadReach`) to the stage, which leaves the same room on either side.
    static let sadReach: CGFloat = 33.6, sadShift: CGFloat = 3.6

    /// How far the tear has run at `t` (0 before it wells and between tears).
    static func tearProgress(at t: Double) -> CGFloat {
        guard t >= tearFirst else { return 0 }
        let local = (t - tearFirst).truncatingRemainder(dividingBy: tearEvery)
        return local < tearLength ? CGFloat(local / tearLength) : 0
    }

    /// The sad cat `t` seconds into its scene, drooped by `amount` (0 is the idle sit, 1 is all the way down: the entrance eases it in, head and ears first).
    static func sad(time t: Double, amount a: CGFloat = 1) -> PetPose {
        let base = sit(time: t)
        guard a > 0 else { return base }
        // It breathes slowly.
        var p = sit(time: t * 0.6)
        p.action = .sad
        // Slumped: the head hangs low and leans, the chest sinks a little and the haunch spreads under it.
        p.head.y -= 2.8; p.head.x += 0.3; p.headScale = 0.97; p.tilt = -0.12
        p.chest.ry -= 0.7; p.chest.cy -= 1.0; p.haunch.rx += 0.5
        // The ears fold out and down.
        p.earL = 0.6; p.earR = 0.6
        // Heavy, wet eyes, looking down.
        p.eyes = 0.74; p.look = CGPoint(x: -0.25, y: -0.95); p.glisten = 1
        // The tail lies limp along the ground, its tip just curling up.
        let sway = CGFloat(sin(t * 0.8))
        p.tail = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -12.5, y: 2.4), c2: CGPoint(x: -17.4, y: 1.0 + 0.25 * sway), p3: CGPoint(x: -18.6 + 0.4 * sway, y: 1.9 + 0.5 * sway), width: 3.5)

        // Its small life, which is slow: a long blink, a sigh now and then, an ear that lifts for a moment (hope) and falls again.
        p.eyes *= 1 - PetLife.blinkClosure(t, period: sadBlinkEvery, length: sadBlinkLength, salt: 311) * 0.92
        if let u = event(t, period: 7.5, length: 2.4, salt: 301) {
            let inhale = bump(u, 0, 0.55), out = ramp(u, 0.5, 0.72) * (1 - ramp(u, 0.86, 1))
            p.chest.ry += 0.9 * inhale; p.head.y += 0.45 * inhale - 0.7 * out
            p.mouth = 0.15 * out
        }
        if let u = event(t, period: 9.0, length: 0.9, salt: 331) { p.earR -= 0.3 * CGFloat(sin(.pi * u)) }
        p.tear = tearProgress(at: t)

        return base.staged(to: p, a)
    }

    /// The sad cat's entrance: how far it has drooped `t` seconds after its scene began.
    static func sadAmount(at t: Double, delay: Double = 0.1) -> CGFloat { ramp(t, delay, delay + sadEntrance) }
}
