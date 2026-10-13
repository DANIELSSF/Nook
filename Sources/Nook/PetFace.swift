import AppKit

/// The face as the painter lays it out for a pose, in the head's own frame: where the eyes look, how far the face turns with them, where
/// an open mouth goes, and how the ears stand. The poses only say where the cat looks (`look`) and how its ears are turned (`earL`,
/// `earR`); many layers add to both (a gesture, a perk, the pointer, the cat's own glances, the follow-through), and a sum the eye
/// would never make on its own must still draw a cat. So it is drawn here, once, by the same rule for every cat:
///   - the eyes go where the cat looks up to `eyeKnee`, and past it creep toward `eyeReach`, however many layers add up, so they stay
///     in the face;
///   - the face turns with the eyes, by `turnShare` of the way: the mouth, the glasses and a tear go with it, the forehead's stripes
///     (higher up the head) half as far. An open mouth so stays under the eyes instead of at the middle of the head while they look away;
///   - an open mouth keeps `chin` inside the head's outline: a face looking down while it opens wide is turned down no further than
///     leaves the mouth room, the eyes with it;
///   - an ear pricked forward stands up narrower, as one turned to the front does: the outer corner of its base slides up the head's
///     outline (`earSlide`) and its tip turns in about the middle of its base; one laid back folds out over the head's edge about the
///     inner corner of its base, the outer corner sinking into the head. Neither lifts a corner of its base off the head, and both stop
///     short of where an ear can go (`earForward`, `earBack`).
///
/// It is a handful of numbers per frame and allocates nothing. The website lays out the same face with the same numbers
/// (`site/src/cat/render.ts`: `faceLayout`, `earPoints`).
struct PetFace {
    /// Where the eyes rest, each side of the middle of the face.
    static let eyeRest = CGPoint(x: 4.3, y: 0.3)
    /// A look is drawn as it is up to `eyeKnee` on each axis; past it the eyes only creep toward `eyeReach`.
    static let eyeKnee = CGPoint(x: 1.8, y: 1.0), eyeReach = CGPoint(x: 2.4, y: 1.4)
    /// The share of the eyes' look that the face itself turns by.
    static let turnShare: CGFloat = 0.6
    /// How far inside the head's outline an open mouth's lowest point stays.
    static let chin: CGFloat = 0.4
    /// The head's half width and half height.
    static let head = CGSize(width: 9.3, height: 7.4)
    /// How far an ear turns, in radians: pricked forward (negative) as it is down to the knee and no further than the reach; laid back
    /// (positive) the same.
    static let earForward = (knee: CGFloat(0.3), reach: CGFloat(0.5)), earBack = (knee: CGFloat(0.7), reach: CGFloat(1.0))
    /// How far up the head's outline (in its angle, radians) the outer corner of a pricked ear's base slides per radian the ear turns.
    static let earSlide: CGFloat = 1.2
    /// Where the outer corner of an ear's base rests, as an angle round the head's outline and how far out on it (its own outline, a
    /// hair outside the head's: the ear covers the head's edge there).
    private static let earRest = (angle: CGFloat(atan2(1.6 / 7.4, 9.1 / 9.3)), out: CGFloat(hypot(9.1 / 9.3, 1.6 / 7.4)))

    /// How far both eyes are from where they rest.
    let eyes: CGPoint
    /// How far the face has turned: the mouth, the glasses and a tear are this far from where they rest.
    let turn: CGPoint
    /// The eyes' size: a lid that closes makes them wider and flatter, down to a line.
    let eyeWidth, eyeHeight: CGFloat
    /// The open mouth's oval, or nil when it is closed.
    let mouth: CGRect?

    init(_ pose: PetPose) {
        let open = max(0, pose.eyes)
        eyeWidth = 2.2 + 0.9 * (1 - min(1, open)); eyeHeight = max(0.55, 2.9 * open)
        var eyes = CGPoint(x: Self.soft(pose.look.x, knee: Self.eyeKnee.x, reach: Self.eyeReach.x), y: Self.soft(pose.look.y, knee: Self.eyeKnee.y, reach: Self.eyeReach.y))
        var turn = CGPoint(x: eyes.x * Self.turnShare, y: eyes.y * Self.turnShare)
        if pose.mouth > 0.02 {
            let m = pose.mouth
            let rx = 1.1 + 1.8 * m, ry = 0.3 + 3.2 * m
            let across = turn.x / Self.head.width
            // The lowest the mouth's middle may be: its lowest point `chin` inside the head, below where it is across the face.
            let floor = ry - (Self.head.height - Self.chin) * max(0, 1 - across * across).squareRoot()
            let lift = max(0, floor - (-3.1 - 0.5 * m + turn.y))
            turn.y += lift; eyes.y += lift
            mouth = CGRect(x: turn.x - rx, y: -3.1 - 0.5 * m + turn.y - ry, width: 2 * rx, height: 2 * ry)
        } else {
            mouth = nil
        }
        self.eyes = eyes; self.turn = turn
    }

    /// The middle of the eye on `side` (-1 left, 1 right).
    func eye(_ side: CGFloat) -> CGPoint { CGPoint(x: side * Self.eyeRest.x + eyes.x, y: Self.eyeRest.y + eyes.y) }
    /// The eye on `side` as an oval.
    func eyeRect(_ side: CGFloat) -> CGRect {
        let c = eye(side)
        return CGRect(x: c.x - eyeWidth / 2, y: c.y - eyeHeight / 2, width: eyeWidth, height: eyeHeight)
    }

    /// `v` as it is up to `knee` (either way), and past it easing toward `reach`, which it never passes: smooth at the knee, so a
    /// look or an ear moving through it does not jolt.
    static func soft(_ v: CGFloat, knee: CGFloat, reach: CGFloat) -> CGFloat {
        let a = abs(v)
        guard a > knee else { return v }
        let room = reach - knee
        let eased = knee + room * CGFloat(tanh(Double((a - knee) / room)))
        return v < 0 ? -eased : eased
    }

    /// How far an ear turned `angle` is drawn turned.
    static func earTurn(_ angle: CGFloat) -> CGFloat {
        angle < 0 ? soft(angle, knee: earForward.knee, reach: earForward.reach) : soft(angle, knee: earBack.knee, reach: earBack.reach)
    }

    /// The ear on `side` (-1 left, 1 right) turned `angle` (negative pricks it forward, positive lays it back): the outer corner of its
    /// base, its tip and the inner corner of its base.
    static func ear(side: CGFloat, angle: CGFloat) -> (outer: CGPoint, tip: CGPoint, inner: CGPoint) {
        let outer = CGPoint(x: side * 9.1, y: 1.6), tip = CGPoint(x: side * 7.5, y: 12.2), inner = CGPoint(x: side * 2.2, y: 6.6)
        let a = earTurn(angle)
        // Counterclockwise is positive: a pricked right ear's tip turns counterclockwise (in), a laid-back one clockwise (out).
        let turn = side * -a
        if a < 0 {
            // Pricked: the outer corner slides up along the head's outline, so the ear stands up narrower, and the tip turns in about
            // the middle of the base.
            let along = earRest.angle - earSlide * a
            let up = CGPoint(x: side * head.width * earRest.out * cos(along), y: head.height * earRest.out * sin(along))
            return (up, rotate(tip, about: CGPoint(x: side * 5.65, y: 4.1), by: turn), inner)
        }
        // Laid back: the ear folds out about the inner corner of its base, and the outer corner goes down into the head.
        return (rotate(outer, about: inner, by: turn), rotate(tip, about: inner, by: turn), inner)
    }

    private static func rotate(_ p: CGPoint, about c: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return p }
        let cs = cos(angle), sn = sin(angle), x = p.x - c.x, y = p.y - c.y
        return CGPoint(x: c.x + x * cs - y * sn, y: c.y + x * sn + y * cs)
    }
}
