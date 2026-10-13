import AppKit

/// The cat's body as one figure. The poses still say where the haunch and the chest are (two ovals), but the cat is not drawn as two ovals
/// stuck together: its outline is the haunch's round rear and the chest's round front, joined by a back line above and a belly line below,
/// each one smooth curve from one oval to the other. So the waist between them is a curve and not a notch, and the spine bends with the pose.
///
/// Each line starts from the two ovals' common tangent on its side (the outline a string pulled round both would make) and is let down
/// into the waist part of the way to where the ovals' outlines cross: there it leaves the haunch and reaches the chest along each oval's
/// own tangent, as a cubic curve, so nothing has a corner. How far it is let down depends on the pose:
///   - two ovals that overlap a lot (a loaf) have a shallow notch, and the lines hardly dip;
///   - two ovals end to end (a stretch) have a deep one, and the back dips long and low;
///   - a cat seen from the side keeps its back straighter than its belly, which tucks up a little more;
///   - and the ovals' turn against each other is the spine's bend: turned toward each other on one side (the arch) that side is rounded out
///     over both, and the other one (the belly) is drawn in.
/// A seated cat, its ovals stacked and turned alike, keeps its two sides as they were, with a smooth waist.
///
/// A cat that stands or walks carries its body as one piece (`PetPose.carriage` 1): the waist is not let down at all, or the cat would
/// read as two lobes with a pinched middle. Its back runs straight along the common tangent from the rump to the shoulders, and its belly
/// from the chest back to the thigh, but for a small tuck of the flank just in front of the thigh, where the belly leaves the haunch a
/// little way up toward the notch. Every share of the way between the two is a blend of them, so a cat that gets up and walks off fills
/// out as it goes.
///
/// It is cheap enough for every frame: a few Newton steps for the tangents, a short search for each notch, and a dozen curves; nothing is
/// allocated. The website draws the same figure with the same numbers (`site/src/cat/render.ts`: `torsoJoins`, `torsoPath`).
struct PetTorso {
    let haunch, chest: PetOval
    /// Where the back line leaves the haunch and reaches the chest, and where the belly line does: each oval's parametric angle (0 at the
    /// end of its long axis, counterclockwise).
    let backHaunch, backChest, bellyHaunch, bellyChest: CGFloat

    /// How far into the waist the lines are let down: the share of the way from the common tangent to where the ovals cross.
    static let waist: CGFloat = 0.4
    /// A cat seen from the side carries its back straighter than its belly: the back is let down by this share less, the belly by this more.
    static let level: CGFloat = 0.12
    /// A body carried as one piece: how far the back is let down at both ends (0, straight along the common tangent), and how far the belly
    /// is where it leaves the haunch (the flank's tuck in front of the thigh); it reaches the chest on the tangent, where the cat is deepest.
    static let carried = (back: CGFloat(0), tuck: CGFloat(0.2))
    /// How much each end of a line turns (radians) per radian the chest is turned against the haunch: the spine's bend.
    static let bend: CGFloat = 0.4
    /// The furthest a line is let out (radians) over a rounded back, and the furthest share of the way to the notch it is let down.
    static let bulge: CGFloat = 0.6, reach: CGFloat = 0.72
    /// The length of a line's handles, as a share of the distance it spans.
    static let handle: CGFloat = 0.38
    /// The furthest the outline moves (rig units) as a body goes from having a waist to being carried as one piece (0.84, a walking cat's
    /// belly): what the frame pacing counts a change of `PetPose.carriage` as (`PetPose.displacement`).
    static let carriageReach: CGFloat = 0.85

    /// The body of a pose: its two ovals, carried as `carriage` says (0 with a waist, 1 as one piece).
    init(_ pose: PetPose) { self.init(pose.haunch, pose.chest, carriage: pose.carriage) }

    init(_ haunch: PetOval, _ chest: PetOval, carriage: CGFloat = 0) {
        self.haunch = haunch; self.chest = chest
        var ux = chest.cx - haunch.cx, uy = chest.cy - haunch.cy
        let length = (ux * ux + uy * uy).squareRoot()
        if length < 0.001 { ux = 0; uy = 1 } else { ux /= length; uy /= length }
        // The spine's bend: how far the chest is turned against the haunch (negative arches the back, positive sags it).
        let bent = Self.bend * (chest.angle - haunch.angle)
        let carried = min(1, max(0, carriage))
        let h = TurnedOval(haunch), c = TurnedOval(chest)
        let back = Self.join(h, c, ux, uy, side: 1, bent: bent, carried: carried), belly = Self.join(h, c, ux, uy, side: -1, bent: -bent, carried: carried)
        backHaunch = back.haunch; backChest = back.chest; bellyHaunch = belly.haunch; bellyChest = belly.chest
    }

    /// One line's ends: `side` 1 is the back (left of the way from the haunch to the chest), -1 the belly. `bent` turns both ends: toward
    /// the waist when positive, away from it (rounding the line out) when negative. `carried` is how far the body is carried as one piece.
    private static func join(_ h: TurnedOval, _ c: TurnedOval, _ ux: CGFloat, _ uy: CGFloat, side: CGFloat, bent: CGFloat, carried: CGFloat) -> (haunch: CGFloat, chest: CGFloat) {
        // The common tangent on this side: Newton on the angle of its normal, from the perpendicular to the spine.
        var normal = atan2(side * ux, -side * uy)
        for _ in 0..<6 {
            let dx = cos(normal), dy = sin(normal)
            let a = h.support(dx, dy), b = c.support(dx, dy)
            let pa = h.point(at: a.angle), pb = c.point(at: b.angle)
            let slope = (pa.x - pb.x) * -dy + (pa.y - pb.y) * dx
            if abs(slope) < 0.001 { break }
            let step = max(-0.5, min(0.5, (a.reach - b.reach) / slope))
            normal -= step
            if abs(step) < 0.00001 { break }
        }
        let dx = cos(normal), dy = sin(normal)
        let tangentH = h.support(dx, dy).angle, tangentC = c.support(dx, dy).angle
        // The notch: along the haunch from its tangent point toward the waist, the first point inside the chest.
        let toward = -side
        var low: CGFloat = 0, high: CGFloat = 0, found = false
        for k in 1...12 {
            let a = CGFloat(k) * 0.26
            if c.level(of: h.point(at: tangentH + toward * a)) <= 0 { low = a - 0.26; high = a; found = true; break }
        }
        var spanH: CGFloat = 0.6, spanC: CGFloat = 0.6
        if found {
            for _ in 0..<6 {
                let middle = (low + high) / 2
                if c.level(of: h.point(at: tangentH + toward * middle)) <= 0 { high = middle } else { low = middle }
            }
            spanH = (low + high) / 2
            spanC = wrap((c.parameter(toward: h.point(at: tangentH + toward * spanH)) - tangentC) * side)
            if spanC > .pi { spanC = 0 }
        }
        let share = waist - level * side * ux
        // Carried as one piece, the back (the upper side of a cat seen from the side) is let down by `carried.back` and the belly only
        // where it leaves the haunch; a seated cat's two sides, neither above the other, take half of each.
        let upper = (1 + side * ux) / 2
        let shareH = share + (Self.carried.back * upper + Self.carried.tuck * (1 - upper) - share) * carried
        let shareC = share + (Self.carried.back * upper - share) * carried
        let slideH = max(-bulge, min(reach * spanH, shareH * spanH + bent))
        let slideC = max(-bulge, min(reach * spanC, shareC * spanC + bent))
        return (tangentH + toward * slideH, tangentC + side * slideC)
    }

    private static func wrap(_ a: CGFloat) -> CGFloat {
        let r = a.truncatingRemainder(dividingBy: 2 * .pi)
        return r < 0 ? r + 2 * .pi : r
    }

    // MARK: The outline

    /// Walks the outline counterclockwise: from the back round the haunch's rear to the belly, the belly line, round the chest's front, and
    /// the back line home. `move` is called once, then `curve(control1, control2, end)` for each cubic.
    func trace(move: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let haunch = TurnedOval(haunch), chest = TurnedOval(chest)
        move(haunch.point(at: backHaunch))
        Self.arc(haunch, from: backHaunch, span: Self.wrap(bellyHaunch - backHaunch), curve)
        Self.line(from: haunch, bellyHaunch, to: chest, bellyChest, curve)
        Self.arc(chest, from: bellyChest, span: Self.wrap(backChest - bellyChest), curve)
        Self.line(from: chest, backChest, to: haunch, backHaunch, curve)
    }

    /// Adds the outline to the context's path, closed.
    func addPath(to cg: CGContext) {
        trace(move: { cg.move(to: $0) }, curve: { cg.addCurve(to: $2, control1: $0, control2: $1) })
        cg.closePath()
    }

    /// The box round the back and belly lines' control points, which holds both lines. (The arcs lie on the ovals; a back rounded out over
    /// them can rise a little above both.)
    var linesBounds: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func add(_ p: CGPoint) { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        let haunch = TurnedOval(haunch), chest = TurnedOval(chest)
        add(haunch.point(at: bellyHaunch)); add(chest.point(at: backChest))
        Self.line(from: haunch, bellyHaunch, to: chest, bellyChest) { add($0); add($1); add($2) }
        Self.line(from: chest, backChest, to: haunch, backHaunch) { add($0); add($1); add($2) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// An oval's arc counterclockwise from `t0`, as up to four cubics (each a quarter turn or less, the circle's own approximation).
    private static func arc(_ o: TurnedOval, from t0: CGFloat, span: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let n = max(1, Int((span / (.pi / 2) - 0.000001).rounded(.up)))
        let d = span / CGFloat(n), k = 4 / 3 * tan(d / 4)
        for i in 0..<n {
            let a = t0 + CGFloat(i) * d, b = a + d
            let p0 = o.point(at: a), p3 = o.point(at: b), v0 = o.direction(at: a), v3 = o.direction(at: b)
            curve(CGPoint(x: p0.x + k * v0.x, y: p0.y + k * v0.y), CGPoint(x: p3.x - k * v3.x, y: p3.y - k * v3.y), p3)
        }
    }

    /// A back or belly line: from oval `a` at `ta` to oval `b` at `tb`, leaving and arriving along each oval's own tangent.
    private static func line(from a: TurnedOval, _ ta: CGFloat, to b: TurnedOval, _ tb: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let p0 = a.point(at: ta), p3 = b.point(at: tb)
        let v0 = a.direction(at: ta), v3 = b.direction(at: tb)
        let n0 = max(0.000001, (v0.x * v0.x + v0.y * v0.y).squareRoot()), n3 = max(0.000001, (v3.x * v3.x + v3.y * v3.y).squareRoot())
        let l = ((p3.x - p0.x) * (p3.x - p0.x) + (p3.y - p0.y) * (p3.y - p0.y)).squareRoot() * handle
        curve(CGPoint(x: p0.x + v0.x / n0 * l, y: p0.y + v0.y / n0 * l), CGPoint(x: p3.x - v3.x / n3 * l, y: p3.y - v3.y / n3 * l), p3)
    }
}

// MARK: The legs

/// A leg as the cat's figure draws it. The poses still give a leg as three points and a width (`PetLimb`: the hip, the knee and the
/// foot), but it is not drawn as a stick of one width hung from a point under the body, which made the cat a spider on sticks. It is
/// broad where it comes out of the body (a hind leg's thigh, a front leg's shoulder), narrows down to the hock or the wrist, and ends in
/// a paw. Its shape is three circles and an oval:
///   - a circle at the hip, inside the body (so the leg comes out of it as one figure), a smaller one at the knee (a hind leg's hock, a
///     front leg's wrist) and a smaller one still at the foot, each joined to the next by their two common tangents;
///   - the paw, an oval a little wider than the ankle. Under a leg that stands it lies flat on the ground, its sole where the stick's
///     round end was (so the cat stands where it stood) and a little forward, toward where the cat faces; on a leg that reaches out or
///     is raised it points along the leg, the toes where the stick ended.
/// It is traced as one outline: down one side, round the paw from where that side runs into it to where the other side does, up the
/// other side and round the hip; round on the outside of the knee and a corner where the tangents cross on the inside of it (a knee
/// inside the hip's circle is passed by). Where a side misses the paw the outline goes round the foot and the paw is traced on its own;
/// a leg folded so tight that the corner would be far from the knee is traced as its three overlapping pieces. Every piece goes
/// counterclockwise, so pieces fill as their union. It is cheap enough for every frame: a few square roots and arc tangents and a dozen
/// curves, in one shape (Core Graphics fills a shape for each piece, so fewer pieces cost less); nothing is allocated. The website
/// draws the same leg with the same numbers (`site/src/cat/render.ts`: `limbShape`, `limbPath`).
struct PetLimbShape {
    let hip, knee, foot: CGPoint
    let hipRadius, kneeRadius, footRadius: CGFloat
    /// The paw: its centre, the unit direction of its length, and its half-length and half-height.
    let paw: CGPoint, pawAxis: CGPoint, pawLength: CGFloat, pawHeight: CGFloat

    /// The radii at the hip, the knee and the foot, as shares of the limb's width: a hind leg's thigh is broad and its hock bony, a
    /// front leg comes down from the shoulder in a column that narrows less.
    static let hind = (hip: CGFloat(0.95), knee: CGFloat(0.45), foot: CGFloat(0.38))
    static let front = (hip: CGFloat(0.78), knee: CGFloat(0.46), foot: CGFloat(0.39))
    /// The paw's half-length and half-height (a little more than the ankle's, so the leg's sides run into it), and how far forward of
    /// the foot a standing paw's centre is (its heel under the back of the ankle, its toes ahead of it), as shares of the width.
    static let pawShares = (length: CGFloat(0.6), height: CGFloat(0.4), toe: CGFloat(0.18))

    /// The leg `l` of a `hind` or front leg, for a cat facing `toe` (1 seen from its right side, -1 from its left, 0 from the front).
    init(_ l: PetLimb, hind: Bool, toe: CGFloat) {
        let k = hind ? Self.hind : Self.front, w = l.width
        hip = l.hip; knee = l.knee; foot = l.foot
        hipRadius = k.hip * w; kneeRadius = k.knee * w; footRadius = k.foot * w
        pawLength = Self.pawShares.length * w; pawHeight = Self.pawShares.height * w
        // Which way the lower leg goes from the knee to the foot.
        var ux = foot.x - knee.x, uy = foot.y - knee.y
        let n = (ux * ux + uy * uy).squareRoot()
        if n < 0.001 { ux = 0; uy = -1 } else { ux /= n; uy /= n }
        // How much it stands: 1 for a lower leg within about thirty degrees of straight down, 0 for one more than seventy from it.
        let s = min(1, max(0, (-uy - 0.35) / 0.5)), flat = s * s * (3 - 2 * s)
        // Standing, the paw lies flat (its length along the ground, either way, as an oval has no front); otherwise it points along the leg.
        var ax = ux * (1 - flat) + (ux < 0 ? -flat : flat), ay = uy * (1 - flat)
        let an = (ax * ax + ay * ay).squareRoot()
        if an < 0.001 { ax = 1; ay = 0 } else { ax /= an; ay /= an }
        pawAxis = CGPoint(x: ax, y: ay)
        // Flat, its sole is where the stick's round end was and its toes a little forward; pointing, its tip is where the stick ended.
        let along = 0.5 * w - pawLength, sole = 0.5 * w - pawHeight
        paw = CGPoint(x: foot.x + ux * along * (1 - flat) + toe * Self.pawShares.toe * w * flat,
                      y: foot.y + uy * along * (1 - flat) - sole * flat)
    }

    /// The shape of the four legs of `pose`, in the order of `PetLegs` (far hind, far front, near hind, near front).
    static func legs(of pose: PetPose) -> (PetLimbShape, PetLimbShape, PetLimbShape, PetLimbShape) {
        let toe = facing(pose), l = pose.legs
        return (PetLimbShape(l.farHind, hind: true, toe: toe), PetLimbShape(l.farFront, hind: false, toe: toe),
                PetLimbShape(l.nearHind, hind: true, toe: toe), PetLimbShape(l.nearFront, hind: false, toe: toe))
    }

    /// Which way the cat faces, seen from where it is drawn: 1 its right side, -1 its left, 0 from the front, and in between as it turns
    /// (how far its chest is ahead of its haunch), so a paw's toes never jump from one side to the other.
    static func facing(_ pose: PetPose) -> CGFloat { min(1, max(-1, (pose.chest.cx - pose.haunch.cx) / 8)) }

    // MARK: The outline

    /// The whole leg, as one outline with the paw in it where the leg's sides run into the paw, and as the outline and the paw apart where
    /// they do not. `move` starts each piece, then `line(to)` and `curve(control1, control2, end)`; `close` ends each.
    func trace(move: (CGPoint) -> Void, line: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void, close: () -> Void) {
        if traceOutline(paw: true, move: move, line: line, curve: curve, close: close) { return }
        if traceOutline(paw: false, move: move, line: line, curve: curve, close: close) {
            tracePaw(move: move, curve: curve, close: close)
            return
        }
        // Too short or folded too tight for one outline: the upper leg, the lower leg (its end at the knee cut straight across, as the
        // upper leg holds the whole circle there) and the paw.
        Self.hull(hip, hipRadius, knee, kneeRadius, round: true, move, line, curve, close)
        traceForearm(round: false, move: move, line: line, curve: curve, close: close)
    }

    /// The lower leg and the paw only: what is outlined in black when a paw is raised over the white face (with its round end at the
    /// knee, as the seam goes round it).
    func traceForearm(move: (CGPoint) -> Void, line: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void, close: () -> Void) {
        traceForearm(round: true, move: move, line: line, curve: curve, close: close)
    }

    private func traceForearm(round: Bool, move: (CGPoint) -> Void, line: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void, close: () -> Void) {
        Self.hull(knee, kneeRadius, foot, footRadius, round: round, move, line, curve, close)
        tracePaw(move: move, curve: curve, close: close)
    }

    /// The leg's outline, counterclockwise: down the right side (of the way from the hip to the foot), round the foot (or, with `paw`,
    /// round the paw from where the right side runs into it to where the left side does), up the left side and round the hip. At the knee
    /// each side either goes round the circle there (the outside of a bend) or turns where its two tangents cross (the inside); a knee
    /// inside the hip's circle (a short leg tucked under the body) is passed by, the hip's circle joined straight to the foot's. False,
    /// and nothing traced, when the foot's circle and the knee's hold one another, the crossing is far from the knee, or (with `paw`) a
    /// side misses the paw or meets it far from the ankle.
    private func traceOutline(paw withPaw: Bool, move: (CGPoint) -> Void, line: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void, close: () -> Void) -> Bool {
        func on(_ c: CGPoint, _ r: CGFloat, _ n: CGPoint) -> CGPoint { CGPoint(x: c.x + r * n.x, y: c.y + r * n.y) }
        /// The turn from normal `a` to normal `b`, either way, in (-pi, pi].
        func turn(_ a: CGPoint, _ b: CGPoint) -> CGFloat { atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y) }
        // The tangents of the upper and the lower leg (both the hip's to the foot's when the knee is passed by).
        let upper: (right: CGPoint, left: CGPoint, phi: CGFloat), lower: (right: CGPoint, left: CGPoint, phi: CGFloat)
        var bent = true
        if let u = Self.tangents(hip, hipRadius, knee, kneeRadius), let l = Self.tangents(knee, kneeRadius, foot, footRadius) {
            upper = u; lower = l
        } else {
            let dx = knee.x - hip.x, dy = knee.y - hip.y
            guard (dx * dx + dy * dy).squareRoot() + kneeRadius <= hipRadius + 0.01, let d = Self.tangents(hip, hipRadius, foot, footRadius) else { return false }
            upper = d; lower = d; bent = false
        }
        let hipRight = on(hip, hipRadius, upper.right), hipLeft = on(hip, hipRadius, upper.left)
        let footRight = on(foot, footRadius, lower.right), footLeft = on(foot, footRadius, lower.left)
        // Past the knee: where the right side's lower straight starts and the left side's ends (round the knee or through the corner).
        var rightTurn: CGFloat = 0, leftTurn: CGFloat = 0, rightFrom = hipRight, leftTo = hipLeft
        if bent {
            rightTurn = turn(upper.right, lower.right); leftTurn = turn(lower.left, upper.left)
            if rightTurn < 0 {
                guard let c = Self.crossing(hipRight, on(knee, kneeRadius, upper.right), on(knee, kneeRadius, lower.right), footRight, near: knee, within: 3 * kneeRadius) else { return false }
                rightFrom = c
            } else { rightFrom = on(knee, kneeRadius, lower.right) }
            if leftTurn < 0 {
                guard let c = Self.crossing(footLeft, on(knee, kneeRadius, lower.left), on(knee, kneeRadius, upper.left), hipLeft, near: knee, within: 3 * kneeRadius) else { return false }
                leftTo = c
            } else { leftTo = on(knee, kneeRadius, lower.left) }
        }
        // Where each side runs into the paw, coming down from the knee.
        var rightHit = (point: CGPoint.zero, angle: CGFloat(0)), leftHit = rightHit
        if withPaw {
            guard let r = pawHit(rightFrom, footRight), let l = pawHit(leftTo, footLeft) else { return false }
            rightHit = r; leftHit = l
        }
        move(hipRight)
        if bent, rightTurn >= 0 { line(on(knee, kneeRadius, upper.right)); Self.arc(knee, kneeRadius, from: upper.right, span: rightTurn, curve) }
        else if bent { line(rightFrom) }
        if withPaw {
            line(rightHit.point)
            var span = leftHit.angle - rightHit.angle
            if span <= 0 { span += 2 * .pi }
            pawArc(from: rightHit.angle, span: span, curve)
        } else {
            line(footRight)
            Self.arc(foot, footRadius, from: lower.right, span: 2 * lower.phi, curve)
        }
        if bent { line(leftTo) }
        if bent, leftTurn >= 0 { Self.arc(knee, kneeRadius, from: lower.left, span: leftTurn, curve) }
        line(hipLeft)
        Self.arc(hip, hipRadius, from: upper.left, span: 2 * .pi - 2 * upper.phi, curve)
        close()
        return true
    }

    /// Where the side from `a` (by the knee) to `b` (on the ankle) first meets the paw, and the paw's parametric angle there; nil when it
    /// misses the paw, starts in it, meets it more than the ankle's radius past `b` (the side would run on past the ankle), or meets it
    /// more than that before `b` with `b` itself outside the paw (the ankle would show beside it).
    private func pawHit(_ a: CGPoint, _ b: CGPoint) -> (point: CGPoint, angle: CGFloat)? {
        // In the paw's own frame, scaled to a unit circle.
        let ax = a.x - paw.x, ay = a.y - paw.y, dx = b.x - a.x, dy = b.y - a.y
        let px = (ax * pawAxis.x + ay * pawAxis.y) / pawLength, py = (ay * pawAxis.x - ax * pawAxis.y) / pawHeight
        let vx = (dx * pawAxis.x + dy * pawAxis.y) / pawLength, vy = (dy * pawAxis.x - dx * pawAxis.y) / pawHeight
        let qa = vx * vx + vy * vy, qb = px * vx + py * vy, qc = px * px + py * py - 1
        guard qc > 0, qa > 0.000001 else { return nil }
        let disc = qb * qb - qa * qc
        guard disc > 0 else { return nil }
        let root = disc.squareRoot(), t = (-qb - root) / qa, out = (-qb + root) / qa
        let length = (dx * dx + dy * dy).squareRoot(), slack = footRadius / max(length, 0.001)
        guard t > 0, t < 1 + slack, t > 1 - slack || out > 1 else { return nil }
        return (CGPoint(x: a.x + t * dx, y: a.y + t * dy), atan2(py + t * vy, px + t * vx))
    }

    /// The paw's outline counterclockwise from parametric angle `t0`, as cubics of a third of a turn or less.
    private func pawArc(from t0: CGFloat, span: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let count = max(1, Int((span / (2 * .pi / 3) - 0.000001).rounded(.up)))
        let d = span / CGFloat(count), k = 4 / 3 * tan(d / 4), cd = cos(d), sd = sin(d)
        let ax = pawAxis.x * pawLength, ay = pawAxis.y * pawLength, bx = -pawAxis.y * pawHeight, by = pawAxis.x * pawHeight
        var c0 = cos(t0), s0 = sin(t0)
        for _ in 0..<count {
            let c1 = c0 * cd - s0 * sd, s1 = c0 * sd + s0 * cd
            // The point at an angle and the outline's direction there (its derivative).
            let p0 = CGPoint(x: paw.x + c0 * ax + s0 * bx, y: paw.y + c0 * ay + s0 * by), v0 = CGPoint(x: -s0 * ax + c0 * bx, y: -s0 * ay + c0 * by)
            let p1 = CGPoint(x: paw.x + c1 * ax + s1 * bx, y: paw.y + c1 * ay + s1 * by), v1 = CGPoint(x: -s1 * ax + c1 * bx, y: -s1 * ay + c1 * by)
            curve(CGPoint(x: p0.x + k * v0.x, y: p0.y + k * v0.y), CGPoint(x: p1.x - k * v1.x, y: p1.y - k * v1.y), p1)
            c0 = c1; s0 = s1
        }
    }

    /// The paw, counterclockwise from the toes.
    private func tracePaw(move: (CGPoint) -> Void, curve: (CGPoint, CGPoint, CGPoint) -> Void, close: () -> Void) {
        let px = CGPoint(x: pawAxis.x * pawLength, y: pawAxis.y * pawLength), py = CGPoint(x: -pawAxis.y * pawHeight, y: pawAxis.x * pawHeight)
        let k: CGFloat = 0.5522847498
        func at(_ c: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: paw.x + c * px.x + s * py.x, y: paw.y + c * px.y + s * py.y) }
        move(at(1, 0))
        curve(at(1, k), at(k, 1), at(0, 1))
        curve(at(-k, 1), at(-1, k), at(-1, 0))
        curve(at(-1, -k), at(-k, -1), at(0, -1))
        curve(at(k, -1), at(1, -k), at(1, 0))
        close()
    }

    /// Adds the whole leg to the context's path.
    func addPath(to cg: CGContext) {
        trace(move: { cg.move(to: $0) }, line: { cg.addLine(to: $0) }, curve: { cg.addCurve(to: $2, control1: $0, control2: $1) }, close: { cg.closePath() })
    }

    /// Adds the lower leg and the paw to the context's path.
    func addForearm(to cg: CGContext) {
        traceForearm(move: { cg.move(to: $0) }, line: { cg.addLine(to: $0) }, curve: { cg.addCurve(to: $2, control1: $0, control2: $1) }, close: { cg.closePath() })
    }

    /// A box that holds the whole leg (the paw's is the oval's own: a flat paw's reaches no lower than its sole).
    var bounds: CGRect {
        let ax = pawAxis.x, ay = pawAxis.y
        let rx = (pawLength * pawLength * ax * ax + pawHeight * pawHeight * ay * ay).squareRoot()
        let ry = (pawLength * pawLength * ay * ay + pawHeight * pawHeight * ax * ax).squareRoot()
        var minX = paw.x - rx, minY = paw.y - ry, maxX = paw.x + rx, maxY = paw.y + ry
        func add(_ c: CGPoint, _ radius: CGFloat) {
            minX = min(minX, c.x - radius); minY = min(minY, c.y - radius); maxX = max(maxX, c.x + radius); maxY = max(maxY, c.y + radius)
        }
        add(hip, hipRadius); add(knee, kneeRadius); add(foot, footRadius)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The common tangents of two circles: the unit normals of the one on the right of the way from `a` to `b` and of the one on its
    /// left, which are `phi` either side of that way; nil when a circle holds the other.
    private static func tangents(_ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat) -> (right: CGPoint, left: CGPoint, phi: CGFloat)? {
        let dx = b.x - a.x, dy = b.y - a.y, d = (dx * dx + dy * dy).squareRoot()
        guard d > abs(ra - rb) + 0.01 else { return nil }
        let ux = dx / d, uy = dy / d, c = (ra - rb) / d, s = (1 - c * c).squareRoot()
        return (CGPoint(x: c * ux + s * uy, y: c * uy - s * ux), CGPoint(x: c * ux - s * uy, y: c * uy + s * ux), acos(c))
    }

    /// Where the line through `a` and `b` crosses the one through `c` and `d` (the two ends' midpoint if they are all but parallel), or
    /// nil when that is more than `within` from `near`.
    private static func crossing(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, near: CGPoint, within: CGFloat) -> CGPoint? {
        let rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y
        let denominator = rx * sy - ry * sx
        var p = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
        if abs(denominator) > 0.000001 {
            let t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denominator
            p = CGPoint(x: a.x + t * rx, y: a.y + t * ry)
        }
        let dx = p.x - near.x, dy = p.y - near.y
        return dx * dx + dy * dy <= within * within ? p : nil
    }

    /// Two circles and their two common tangents, counterclockwise: the tangent on the right of the way from `a` to `b`, round the far
    /// side of `b`, the tangent on the left, and round the far side of `a` (or, not `round`, straight across it). A circle that holds the
    /// other is drawn alone.
    private static func hull(_ a: CGPoint, _ ra: CGFloat, _ b: CGPoint, _ rb: CGFloat, round: Bool, _ move: (CGPoint) -> Void, _ line: (CGPoint) -> Void,
                             _ curve: (CGPoint, CGPoint, CGPoint) -> Void, _ close: () -> Void) {
        guard let t = tangents(a, ra, b, rb) else {
            let (c, r) = ra >= rb ? (a, ra) : (b, rb)
            move(CGPoint(x: c.x + r, y: c.y)); arc(c, r, from: CGPoint(x: 1, y: 0), span: 2 * .pi, curve); close()
            return
        }
        move(CGPoint(x: a.x + ra * t.right.x, y: a.y + ra * t.right.y))
        line(CGPoint(x: b.x + rb * t.right.x, y: b.y + rb * t.right.y))
        arc(b, rb, from: t.right, span: 2 * t.phi, curve)
        line(CGPoint(x: a.x + ra * t.left.x, y: a.y + ra * t.left.y))
        if round { arc(a, ra, from: t.left, span: 2 * .pi - 2 * t.phi, curve) }
        close()
    }

    /// A circle's arc counterclockwise from the unit direction `n`, as cubics of a third of a turn or less (each within a six-hundredth
    /// of the radius: well under a pixel at the largest size the cat is drawn), each a turn of the one before.
    private static func arc(_ c: CGPoint, _ r: CGFloat, from n: CGPoint, span: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let count = max(1, Int((span / (2 * .pi / 3) - 0.000001).rounded(.up)))
        let d = span / CGFloat(count), k = 4 / 3 * tan(d / 4) * r, cd = cos(d), sd = sin(d)
        var x0 = n.x, y0 = n.y
        for _ in 0..<count {
            let x1 = x0 * cd - y0 * sd, y1 = x0 * sd + y0 * cd
            curve(CGPoint(x: c.x + r * x0 - k * y0, y: c.y + r * y0 + k * x0), CGPoint(x: c.x + r * x1 + k * y1, y: c.y + r * y1 - k * x1), CGPoint(x: c.x + r * x1, y: c.y + r * y1))
            x0 = x1; y0 = y1
        }
    }
}

extension PetOval {
    /// The point at parametric angle `t`.
    func point(at t: CGFloat) -> CGPoint { TurnedOval(self).point(at: t) }

    /// The outline's direction at `t`, counterclockwise (its derivative: not of unit length).
    func direction(at t: CGFloat) -> CGPoint { TurnedOval(self).direction(at: t) }

    /// How far the oval reaches along the unit direction (`dx`, `dy`), and the parametric angle of the point that reaches it.
    func support(_ dx: CGFloat, _ dy: CGFloat) -> (reach: CGFloat, angle: CGFloat) { TurnedOval(self).support(dx, dy) }

    /// Negative inside the oval, 0 on its outline, positive outside.
    func level(of p: CGPoint) -> CGFloat { TurnedOval(self).level(of: p) }

    /// The parametric angle of the point of the outline in the direction of `p` from the centre (the oval squashed to a circle).
    func parameter(toward p: CGPoint) -> CGFloat { TurnedOval(self).parameter(toward: p) }
}

/// An oval with the cosine and sine of its turn worked out once, for the many points a torso asks of it in a frame (the same numbers
/// as working them out for each point).
struct TurnedOval {
    let cx, cy, rx, ry, c, s: CGFloat
    init(_ o: PetOval) { cx = o.cx; cy = o.cy; rx = o.rx; ry = o.ry; c = cos(o.angle); s = sin(o.angle) }

    func point(at t: CGFloat) -> CGPoint {
        let lx = rx * cos(t), ly = ry * sin(t)
        return CGPoint(x: cx + lx * c - ly * s, y: cy + lx * s + ly * c)
    }

    func direction(at t: CGFloat) -> CGPoint {
        let lx = -rx * sin(t), ly = ry * cos(t)
        return CGPoint(x: lx * c - ly * s, y: lx * s + ly * c)
    }

    func support(_ dx: CGFloat, _ dy: CGFloat) -> (reach: CGFloat, angle: CGFloat) {
        let ax = rx * (dx * c + dy * s), by = ry * (-dx * s + dy * c)
        let k = max(0.000001, (ax * ax + by * by).squareRoot())
        return (dx * cx + dy * cy + k, atan2(by, ax))
    }

    func level(of p: CGPoint) -> CGFloat {
        let dx = p.x - cx, dy = p.y - cy
        let lx = (dx * c + dy * s) / rx, ly = (-dx * s + dy * c) / ry
        return lx * lx + ly * ly - 1
    }

    func parameter(toward p: CGPoint) -> CGFloat {
        let dx = p.x - cx, dy = p.y - cy
        return atan2((-dx * s + dy * c) / ry, (dx * c + dy * s) / rx)
    }
}
