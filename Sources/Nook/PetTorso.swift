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
    /// How much each end of a line turns (radians) per radian the chest is turned against the haunch: the spine's bend.
    static let bend: CGFloat = 0.4
    /// The furthest a line is let out (radians) over a rounded back, and the furthest share of the way to the notch it is let down.
    static let bulge: CGFloat = 0.6, reach: CGFloat = 0.72
    /// The length of a line's handles, as a share of the distance it spans.
    static let handle: CGFloat = 0.38

    init(_ haunch: PetOval, _ chest: PetOval) {
        self.haunch = haunch; self.chest = chest
        var ux = chest.cx - haunch.cx, uy = chest.cy - haunch.cy
        let length = (ux * ux + uy * uy).squareRoot()
        if length < 0.001 { ux = 0; uy = 1 } else { ux /= length; uy /= length }
        // The spine's bend: how far the chest is turned against the haunch (negative arches the back, positive sags it).
        let bent = Self.bend * (chest.angle - haunch.angle)
        let back = Self.join(haunch, chest, ux, uy, side: 1, bent: bent), belly = Self.join(haunch, chest, ux, uy, side: -1, bent: -bent)
        backHaunch = back.haunch; backChest = back.chest; bellyHaunch = belly.haunch; bellyChest = belly.chest
    }

    /// One line's ends: `side` 1 is the back (left of the way from the haunch to the chest), -1 the belly. `bent` turns both ends: toward
    /// the waist when positive, away from it (rounding the line out) when negative.
    private static func join(_ h: PetOval, _ c: PetOval, _ ux: CGFloat, _ uy: CGFloat, side: CGFloat, bent: CGFloat) -> (haunch: CGFloat, chest: CGFloat) {
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
        let slideH = max(-bulge, min(reach * spanH, share * spanH + bent))
        let slideC = max(-bulge, min(reach * spanC, share * spanC + bent))
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
        add(haunch.point(at: bellyHaunch)); add(chest.point(at: backChest))
        Self.line(from: haunch, bellyHaunch, to: chest, bellyChest) { add($0); add($1); add($2) }
        Self.line(from: chest, backChest, to: haunch, backHaunch) { add($0); add($1); add($2) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// An oval's arc counterclockwise from `t0`, as up to four cubics (each a quarter turn or less, the circle's own approximation).
    private static func arc(_ o: PetOval, from t0: CGFloat, span: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let n = max(1, Int((span / (.pi / 2) - 0.000001).rounded(.up)))
        let d = span / CGFloat(n), k = 4 / 3 * tan(d / 4)
        for i in 0..<n {
            let a = t0 + CGFloat(i) * d, b = a + d
            let p0 = o.point(at: a), p3 = o.point(at: b), v0 = o.direction(at: a), v3 = o.direction(at: b)
            curve(CGPoint(x: p0.x + k * v0.x, y: p0.y + k * v0.y), CGPoint(x: p3.x - k * v3.x, y: p3.y - k * v3.y), p3)
        }
    }

    /// A back or belly line: from oval `a` at `ta` to oval `b` at `tb`, leaving and arriving along each oval's own tangent.
    private static func line(from a: PetOval, _ ta: CGFloat, to b: PetOval, _ tb: CGFloat, _ curve: (CGPoint, CGPoint, CGPoint) -> Void) {
        let p0 = a.point(at: ta), p3 = b.point(at: tb)
        let v0 = a.direction(at: ta), v3 = b.direction(at: tb)
        let n0 = max(0.000001, (v0.x * v0.x + v0.y * v0.y).squareRoot()), n3 = max(0.000001, (v3.x * v3.x + v3.y * v3.y).squareRoot())
        let l = ((p3.x - p0.x) * (p3.x - p0.x) + (p3.y - p0.y) * (p3.y - p0.y)).squareRoot() * handle
        curve(CGPoint(x: p0.x + v0.x / n0 * l, y: p0.y + v0.y / n0 * l), CGPoint(x: p3.x - v3.x / n3 * l, y: p3.y - v3.y / n3 * l), p3)
    }
}

extension PetOval {
    /// The point at parametric angle `t`.
    func point(at t: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle), lx = rx * cos(t), ly = ry * sin(t)
        return CGPoint(x: cx + lx * c - ly * s, y: cy + lx * s + ly * c)
    }

    /// The outline's direction at `t`, counterclockwise (its derivative: not of unit length).
    func direction(at t: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle), lx = -rx * sin(t), ly = ry * cos(t)
        return CGPoint(x: lx * c - ly * s, y: lx * s + ly * c)
    }

    /// How far the oval reaches along the unit direction (`dx`, `dy`), and the parametric angle of the point that reaches it.
    func support(_ dx: CGFloat, _ dy: CGFloat) -> (reach: CGFloat, angle: CGFloat) {
        let c = cos(angle), s = sin(angle)
        let ax = rx * (dx * c + dy * s), by = ry * (-dx * s + dy * c)
        let k = max(0.000001, (ax * ax + by * by).squareRoot())
        return (dx * cx + dy * cy + k, atan2(by, ax))
    }

    /// Negative inside the oval, 0 on its outline, positive outside.
    func level(of p: CGPoint) -> CGFloat {
        let c = cos(angle), s = sin(angle), dx = p.x - cx, dy = p.y - cy
        let lx = (dx * c + dy * s) / rx, ly = (-dx * s + dy * c) / ry
        return lx * lx + ly * ly - 1
    }

    /// The parametric angle of the point of the outline in the direction of `p` from the centre (the oval squashed to a circle).
    func parameter(toward p: CGPoint) -> CGFloat {
        let c = cos(angle), s = sin(angle), dx = p.x - cx, dy = p.y - cy
        return atan2((-dx * s + dy * c) / ry, (dx * c + dy * s) / rx)
    }
}
