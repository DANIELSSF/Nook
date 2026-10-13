import AppKit

/// What a frame of the cat is doing, as a label: the poses name themselves so tests, previews and the frame pacing can tell a
/// gesture from the idle sit without looking at the numbers.
enum PetAction: CaseIterable {
    case sit, walk, stretch, play, sleep, wave, groom, glance, peek, celebrate, land, curious
    case yawn, loaf, hunt, scratch, startle, tailPlay
    /// The cat is sorry to see the user go (the question before quitting): head low, ears down, tail limp, a tear. A scene of its own, not one of the
    /// director's gestures.
    case sad
}

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

/// The four legs, in the order far hind, far front, near hind, near front. Four stored limbs instead of an array: a pose is
/// built, blended and thrown away many times a second, and a value with no heap storage costs a copy instead of an allocation.
struct PetLegs: Equatable, RandomAccessCollection, MutableCollection, ExpressibleByArrayLiteral {
    var farHind, farFront, nearHind, nearFront: PetLimb

    init(_ farHind: PetLimb, _ farFront: PetLimb, _ nearHind: PetLimb, _ nearFront: PetLimb) {
        self.farHind = farHind; self.farFront = farFront; self.nearHind = nearHind; self.nearFront = nearFront
    }
    init(arrayLiteral elements: PetLimb...) {
        precondition(elements.count == 4, "a cat has four legs")
        self.init(elements[0], elements[1], elements[2], elements[3])
    }

    var startIndex: Int { 0 }
    var endIndex: Int { 4 }
    subscript(i: Int) -> PetLimb {
        get {
            switch i { case 0: return farHind; case 1: return farFront; case 2: return nearHind; default: return nearFront }
        }
        set {
            switch i { case 0: farHind = newValue; case 1: farFront = newValue; case 2: nearHind = newValue; default: nearFront = newValue }
        }
    }
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
    var legs = PetLegs(
        PetLimb(x: -6.2, hip: 6, foot: 3.5, width: 3), PetLimb(x: -3.6, hip: 8, foot: 1.3, width: 3.8),
        PetLimb(x: 6.2, hip: 6, foot: 3.5, width: 3), PetLimb(x: 3.6, hip: 8, foot: 1.3, width: 3.8)
    )
    var tail = PetTail(p0: CGPoint(x: -5.5, y: 3.5), c1: CGPoint(x: -19, y: -2), c2: CGPoint(x: -19.5, y: 9), p3: CGPoint(x: -13, y: 12))
    var ball = CGPoint(x: 19, y: 3)
    var ballSize: CGFloat = 0
    var zAlpha: CGFloat = 0
    var zRise: CGFloat = 0
    /// Lifts (+) or lowers (-) the whole cat, in rig units: a hop, a landing, or a peek that sinks it behind a ledge.
    var y: CGFloat = 0
    /// Progress 0...1 of the little sparkle beside the head; 0 draws none.
    var sparkle: CGFloat = 0
    /// How open the mouth is, 0...1: a yawn, a mew. Drawn as a dark opening low on the face.
    var mouth: CGFloat = 0
    /// A speck the cat is watching or pouncing on, and how big it is (0 draws none).
    var mote = CGPoint(x: 18, y: 18)
    var moteSize: CGFloat = 0
    /// How far what hangs from the cat's neck (a bell, a bow) has swung, -1...1. It is driven by the head's own motion.
    var swing: CGFloat = 0
    /// Progress 0...1 of a tear running down the cheek from the left eye; 0 draws none.
    var tear: CGFloat = 0
    /// How wet the eyes look, 0...1: a small glint in each. The sad cat's.
    var glisten: CGFloat = 0

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
        r.legs = PetLegs(l(legs.farHind, o.legs.farHind), l(legs.farFront, o.legs.farFront), l(legs.nearHind, o.legs.nearHind), l(legs.nearFront, o.legs.nearFront))
        r.tail = PetTail(p0: p(tail.p0, o.tail.p0), c1: p(tail.c1, o.tail.c1), c2: p(tail.c2, o.tail.c2), p3: p(tail.p3, o.tail.p3), width: f(tail.width, o.tail.width))
        r.ball = p(ball, o.ball); r.ballSize = f(ballSize, o.ballSize)
        r.zAlpha = f(zAlpha, o.zAlpha); r.zRise = f(zRise, o.zRise)
        r.y = f(y, o.y); r.sparkle = f(sparkle, o.sparkle)
        r.mouth = f(mouth, o.mouth); r.mote = p(mote, o.mote); r.moteSize = f(moteSize, o.moteSize); r.swing = f(swing, o.swing)
        r.tear = f(tear, o.tear); r.glisten = f(glisten, o.glisten)
        return r
    }

    func blended(to o: PetPose, _ t: CGFloat) -> PetPose {
        let t = min(1, max(0, t))
        var r = combined(o) { $0 + ($1 - $0) * t }
        // A speck or a ball that is not there has no place: one that fades in or out does it where it is, instead of sliding in.
        if moteSize == 0 { r.mote = o.mote } else if o.moteSize == 0 { r.mote = mote }
        if ballSize == 0 { r.ball = o.ball } else if o.ballSize == 0 { r.ball = ball }
        if t > 0, t < 1, isFrontal != o.isFrontal {
            let (a, b) = turning(to: o)
            r.legs = PetLegs(a.farHind.blended(to: b.farHind, t), a.farFront.blended(to: b.farFront, t), a.nearHind.blended(to: b.nearHind, t), a.nearFront.blended(to: b.nearFront, t))
        }
        if t >= 0.5 { r.action = o.action; r.facing = o.facing }
        return r
    }

    // MARK: Turning round

    /// Whether the cat is seen from the front: its legs stand, left to right, far hind, far front, near front, near hind (the hind feet
    /// outside the front legs on both sides: a sit, a cat held up). Seen from the side they stand hind, hind, front, front.
    var isFrontal: Bool {
        legs.farHind.hip.x < legs.farFront.hip.x && legs.farFront.hip.x < legs.nearFront.hip.x && legs.nearFront.hip.x < legs.nearHind.hip.x
    }

    /// The legs of this pose and of `o` for a turn between them, from the front to the side or back: the front-on pose's legs are put in
    /// the places of the side-on pose's that stand where they do (left to right), so each goes to the nearest and none crosses under the
    /// body on the way. Which leg is which does not show (they are drawn alike), so the picture at either end is the pose's own.
    func turning(to o: PetPose) -> (PetLegs, PetLegs) {
        isFrontal ? (Self.paired(legs, like: o.legs), o.legs) : (legs, Self.paired(o.legs, like: legs))
    }

    /// `a`'s legs put in the slots of `b`'s legs that stand where they do, by where their hips are from left to right.
    static func paired(_ a: PetLegs, like b: PetLegs) -> PetLegs {
        func rank(_ l: PetLegs, _ i: Int) -> Int {
            var k = 0
            for j in 0..<4 where l[j].hip.x < l[i].hip.x || (l[j].hip.x == l[i].hip.x && j < i) { k += 1 }
            return k
        }
        var r = b
        for i in 0..<4 {
            let k = rank(a, i)
            for j in 0..<4 where rank(b, j) == k { r[j] = a[i] }
        }
        return r
    }

    /// Largest difference between any two numbers of the poses (where a speck or ball is does not count while it is not there; nor which
    /// leg is which, while the cat is turning: legs that stand where the other pose's do are compared with them).
    func distance(to o: PetPose) -> CGFloat {
        var a = self
        if moteSize == 0 || o.moteSize == 0 { a.mote = o.mote }
        if ballSize == 0 || o.ballSize == 0 { a.ball = o.ball }
        var d: CGFloat = 0
        _ = a.combined(o) { d = max(d, abs($0 - $1)); return $0 }
        if isFrontal != o.isFrontal {
            a.legs = Self.paired(legs, like: o.legs)
            var e: CGFloat = 0
            _ = a.combined(o) { e = max(e, abs($0 - $1)); return $0 }
            d = min(d, e)
        }
        return d
    }

    /// The largest way the cat's *picture* differs between two poses, in view points for a cat drawn at `scale` points per rig
    /// unit. `distance` compares raw numbers (an angle in radians against a position in units); this turns each into how far
    /// its edge moves on the screen, so a small change to a pose can be told from one the eye would notice.
    func displacement(to o: PetPose, scale: CGFloat) -> CGFloat {
        @inline(__always) func gap(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(abs(a.x - b.x), abs(a.y - b.y)) }
        @inline(__always) func oval(_ a: PetOval, _ b: PetOval) -> CGFloat {
            max(abs(a.cx - b.cx), abs(a.cy - b.cy), abs(a.rx - b.rx), abs(a.ry - b.ry), abs(a.angle - b.angle) * 8)
        }
        @inline(__always) func limb(_ a: PetLimb, _ b: PetLimb) -> CGFloat { max(gap(a.hip, b.hip), gap(a.knee, b.knee), gap(a.foot, b.foot), abs(a.width - b.width) * 0.5) }
        @inline(__always) func limbs(_ a: PetLegs, _ b: PetLegs) -> CGFloat { max(limb(a.farHind, b.farHind), limb(a.farFront, b.farFront), limb(a.nearHind, b.nearHind), limb(a.nearFront, b.nearFront)) }
        var d = abs(x - o.x) / max(scale, 0.01)
        d = max(d, abs(y - o.y), oval(haunch, o.haunch), oval(chest, o.chest), gap(head, o.head), gap(look, o.look))
        d = max(d, abs(headScale - o.headScale) * 9.3, abs(tilt - o.tilt) * 9.3, abs(earL - o.earL) * 8, abs(earR - o.earR) * 8, abs(eyes - o.eyes) * 1.6)
        // Which leg is which does not show while the cat turns round: legs that stand where the other pose's do are compared with them.
        d = max(d, isFrontal != o.isFrontal ? min(limbs(legs, o.legs), limbs(Self.paired(legs, like: o.legs), o.legs)) : limbs(legs, o.legs))
        d = max(d, gap(tail.p0, o.tail.p0), gap(tail.c1, o.tail.c1) * 0.5, gap(tail.c2, o.tail.c2) * 0.5, gap(tail.p3, o.tail.p3), abs(tail.width - o.tail.width) * 0.5)
        if ballSize > 0 || o.ballSize > 0 { d = max(d, ballSize > 0 && o.ballSize > 0 ? gap(ball, o.ball) : 0, abs(ballSize - o.ballSize) * 2.3) }
        if moteSize > 0 || o.moteSize > 0 { d = max(d, moteSize > 0 && o.moteSize > 0 ? gap(mote, o.mote) : 0, abs(moteSize - o.moteSize) * 1.4) }
        d = max(d, abs(zAlpha - o.zAlpha) * 3, abs(zRise - o.zRise) * 6, abs(sparkle - o.sparkle) * 10, abs(mouth - o.mouth) * 3.5, abs(swing - o.swing) * 3)
        d = max(d, abs(tear - o.tear) * 5, abs(glisten - o.glisten) * 1.5)
        return d * scale
    }

    /// Poses are authored facing right; this mirrors them to face left.
    func mirrored() -> PetPose {
        func p(_ a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: a.y) }
        var r = self
        r.facing = -facing
        r.haunch.cx = -haunch.cx; r.haunch.angle = -haunch.angle; r.chest.cx = -chest.cx; r.chest.angle = -chest.angle
        r.head = p(head); r.tilt = -tilt; r.earL = earR; r.earR = earL; r.look = p(look)
        r.legs = PetLegs(PetLimb(p(legs.farHind.hip), p(legs.farHind.knee), p(legs.farHind.foot), legs.farHind.width),
                         PetLimb(p(legs.farFront.hip), p(legs.farFront.knee), p(legs.farFront.foot), legs.farFront.width),
                         PetLimb(p(legs.nearHind.hip), p(legs.nearHind.knee), p(legs.nearHind.foot), legs.nearHind.width),
                         PetLimb(p(legs.nearFront.hip), p(legs.nearFront.knee), p(legs.nearFront.foot), legs.nearFront.width))
        r.tail = PetTail(p0: p(tail.p0), c1: p(tail.c1), c2: p(tail.c2), p3: p(tail.p3), width: tail.width)
        // The ball and the speck sit where the cat looks; without one there is nothing to mirror (and nothing to blend later).
        if ballSize > 0 { r.ball = p(ball) }
        if moteSize > 0 { r.mote = p(mote) }
        r.swing = -swing
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
        // The body's back and belly lines run between the two ovals; a back rounded out over them can rise a little above both.
        add(PetTorso(haunch, chest).linesBounds)
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
        if moteSize > 0 { dot(mote, 1.9 * moteSize) }
        if zAlpha > Self.zVisible { add(CGRect(x: head.x - 3, y: head.y + 4, width: 13, height: 22)) }
        if sparkle > 0 { add(CGRect(x: head.x - Self.sparkleReach.left, y: head.y - 2, width: Self.sparkleReach.left + Self.sparkleReach.right, height: Self.sparkleReach.up + 2)) }
        return rect.offsetBy(dx: 0, dy: y)
    }
}
