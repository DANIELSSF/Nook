import AppKit
import SwiftUI

// The icons a tab can wear beside its name, and the picker that chooses them.
//
// An icon is drawn in the tab's colour, ten points wide and calm: one soft movement, never a flash. It moves only while the
// AI of its tab works, so a glance at the tab row says which sessions are busy, and nothing runs in the rest. Every icon has a
// still form, which is also where its movement begins (a still icon is the movement at time zero). It is shown still for Reduce
// Motion, for the animations preference and while the island is collapsed, as `TabAgentBadge`'s spinner is.
//
// The art is plain geometry (`TabIconArt.shapes`): a list of discs, rings, bars and polygons in the icon's 10 × 10 box, so it
// can be tested without drawing it. `TabIconView` draws it: still, as a SwiftUI `Canvas`; moving, twenty times a second, as a small
// AppKit view of its own (`TabIconMotionView`) that paints the same pieces with Core Graphics. A `TimelineView` renders each of those
// frames through the island's whole hosting view (its layout, from the root): measured on the island with a Claude tab at work, that kept
// a core busy at twenty frames a second (at the low priority the tests run at), against about 1% for the AppKit view's repaint. While it
// is still, nothing runs.

extension TabIcon {
    /// What the picker's tooltips and VoiceOver call it.
    var title: String {
        switch self {
        case .dot: "Punto"
        case .half: "Medio círculo"
        case .orbit: "Órbita"
        case .bars: "Barras"
        case .spark: "Destello"
        case .gem: "Gema"
        case .heart: "Corazón"
        case .bolt: "Rayo"
        case .leaf: "Hoja"
        case .moon: "Luna"
        case .wave: "Ola"
        case .paw: "Huella"
        case .flame: "Llama"
        case .star: "Estrella"
        case .code: "Código"
        case .sun: "Sol"
        }
    }

    /// Whether it moves at all. The dot is the still choice.
    var moves: Bool { self != .dot }
}

// MARK: - Geometry

/// One piece of an icon, in the icon's own box: 10 × 10, origin at the top left, y pointing down.
enum TabIconShape: Equatable {
    case disc(center: CGPoint, radius: Double, opacity: Double)
    case ring(center: CGPoint, radius: Double, width: Double, opacity: Double)
    case bar(CGRect, opacity: Double)
    case polygon([CGPoint], opacity: Double)

    /// The rectangle the piece covers.
    var bounds: CGRect {
        switch self {
        case .disc(let center, let radius, _):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .ring(let center, let radius, let width, _):
            let outer = radius + width / 2
            return CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
        case .bar(let rect, _):
            return rect
        case .polygon(let points, _):
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else { return .zero }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}

enum TabIconArt {
    /// The side of the box every icon is drawn in.
    static let box: Double = 10

    // How long one turn, one pulse or one flip takes, in seconds. Slow on purpose: these sit in the corner of the eye.
    static let halfTurn = 2.8
    static let orbitTurn = 2.4
    static let barsCycle = 1.8
    static let sparkCycle = 2.2
    static let gemTurn = 3.0
    static let heartBeat = 1.7
    static let boltCycle = 1.8
    static let leafSway = 2.8
    static let moonCycle = 3.4
    static let waveCycle = 2.4
    static let pawCycle = 2.0
    static let flameCycle = 1.9
    /// One full turn of the star, which looks the same every fifth of it; and of the sun's rays, every eighth.
    static let starTurn = 9.0
    static let codeCycle = 2.2
    static let sunTurn = 12.0

    private static let center = CGPoint(x: 5, y: 5)

    /// The pieces of `icon` `time` seconds into its movement. Nil is the icon at rest, which is also its movement at time zero
    /// (only the orbit's trail, which has nothing to trail behind at rest, appears with the movement).
    static func shapes(of icon: TabIcon, at time: Double?) -> [TabIconShape] {
        let t = time ?? 0
        switch icon {
        case .dot:
            return [.disc(center: center, radius: 2.5, opacity: 1)]

        case .half:
            // A ring and a half of the disc, solid: the half goes round clockwise, starting on the left like "◐".
            let start = 90 + 360 * fraction(t / halfTurn)
            return [.ring(center: center, radius: 4.0, width: 1.15, opacity: 0.95),
                    .polygon(halfDisc(radius: 4.55, from: start), opacity: 1)]

        case .orbit:
            // A core, a faint track and a small moon on it, with a short trail while it goes round.
            let radius = 3.55
            let angle = -50 + 360 * fraction(t / orbitTurn)
            var pieces: [TabIconShape] = [.ring(center: center, radius: radius, width: 1.0, opacity: 0.40),
                                          .disc(center: center, radius: 1.45, opacity: 0.95)]
            if time != nil {
                for step in (1...6).reversed() {
                    let behind = Double(step)
                    pieces.append(.disc(center: onCircle(radius, degrees: angle - 9 * behind), radius: 1.2 * (1 - behind / 8), opacity: 0.55 * (1 - behind / 7)))
                }
            }
            pieces.append(.disc(center: onCircle(radius, degrees: angle), radius: 1.4, opacity: 1))
            return pieces

        case .bars:
            let width = 1.55, gap = 0.95
            let heights = barHeights(at: t)
            let left = center.x - (Double(heights.count) * width + Double(heights.count - 1) * gap) / 2
            return heights.enumerated().map { index, height in
                .bar(CGRect(x: left + Double(index) * (width + gap), y: center.y - height / 2, width: width, height: height), opacity: 1)
            }

        case .spark:
            // The star breathes: a little smaller and fainter, then full again.
            let light = 0.5 + 0.5 * cos(2 * .pi * t / sparkCycle)
            return [.polygon(star(radius: 4.8 * (0.78 + 0.22 * light), pinch: 0.16), opacity: 0.72 + 0.28 * light)]

        case .gem:
            // A diamond turning on its vertical axis: it narrows to a sliver and comes back with the other facet in the light.
            let turn = cos(2 * .pi * t / gemTurn)
            let half = max(3.9 * abs(turn), 0.35)
            let top = CGPoint(x: center.x, y: 0.5), bottom = CGPoint(x: center.x, y: 9.5)
            let lit = 1.0, shade = 0.62
            return [.polygon([top, CGPoint(x: center.x - half, y: center.y), bottom], opacity: turn >= 0 ? lit : shade),
                    .polygon([top, CGPoint(x: center.x + half, y: center.y), bottom], opacity: turn >= 0 ? shade : lit)]

        case .heart: return heart(at: t)
        case .bolt: return bolt(at: t)
        case .leaf: return leaf(at: t)
        case .moon: return moon(at: t)
        case .wave: return wave(at: t)
        case .paw: return paw(at: t)
        case .flame: return flame(at: t)
        case .star: return star(at: t)
        case .code: return code(at: t)
        case .sun: return sun(at: t)
        }
    }

    // MARK: The newer icons
    //
    // Each is drawn the same way as the first six: a few pieces of plain geometry in the 10 × 10 box, calm, and at rest (time zero) exactly its still form.

    /// A smooth bump that is zero outside `from..<to`: 0 at both ends, 1 in the middle. What a beat, a dip or a tap is made of.
    private static func bump(_ u: Double, _ from: Double, _ to: Double) -> Double {
        guard u >= from, u < to else { return 0 }
        let s = sin(.pi * (u - from) / (to - from))
        return s * s
    }

    /// A line from `p` to `q` as a polygon, `width` thick.
    private static func stroke(_ p: CGPoint, _ q: CGPoint, width: Double) -> [CGPoint] {
        let dx = q.x - p.x, dy = q.y - p.y
        let length = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / length * width / 2, ny = dx / length * width / 2
        return [CGPoint(x: p.x + nx, y: p.y + ny), CGPoint(x: q.x + nx, y: q.y + ny), CGPoint(x: q.x - nx, y: q.y - ny), CGPoint(x: p.x - nx, y: p.y - ny)]
    }

    private static func rotated(_ points: [CGPoint], about pivot: CGPoint, degrees: Double) -> [CGPoint] {
        let angle = degrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        return points.map { CGPoint(x: pivot.x + ($0.x - pivot.x) * c - ($0.y - pivot.y) * s, y: pivot.y + ($0.x - pivot.x) * s + ($0.y - pivot.y) * c) }
    }

    /// `points` clipped to the half-plane above or below the horizontal line `y` (the bolt is cut in two there).
    private static func clipped(_ points: [CGPoint], y: Double, keepAbove: Bool) -> [CGPoint] {
        func inside(_ p: CGPoint) -> Bool { keepAbove ? p.y <= y : p.y >= y }
        func cut(_ a: CGPoint, _ b: CGPoint) -> CGPoint { let k = (y - a.y) / (b.y - a.y); return CGPoint(x: a.x + (b.x - a.x) * k, y: y) }
        var out: [CGPoint] = []
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            if inside(a) { out.append(a) }
            if inside(a) != inside(b) { out.append(cut(a, b)) }
        }
        return out
    }

    /// A quadratic curve's points from `p0` to `p2`, bent toward `p1`.
    private static func curve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, steps: Int) -> [CGPoint] {
        (0...steps).map { index in
            let u = Double(index) / Double(steps), v = 1 - u
            return CGPoint(x: v * v * p0.x + 2 * v * u * p1.x + u * u * p2.x, y: v * v * p0.y + 2 * v * u * p1.y + u * u * p2.y)
        }
    }

    /// A heart, 8 wide and centred on the origin, from the classic curve.
    private static let heartOutline: [CGPoint] = {
        let raw = (0..<48).map { index -> CGPoint in
            let a = 2 * Double.pi * Double(index) / 48
            return CGPoint(x: 16 * pow(sin(a), 3), y: -(13 * cos(a) - 5 * cos(2 * a) - 2 * cos(3 * a) - cos(4 * a)))
        }
        let xs = raw.map(\.x), ys = raw.map(\.y)
        let scale = 8.0 / (xs.max()! - xs.min()!)
        let mx = (xs.max()! + xs.min()!) / 2, my = (ys.max()! + ys.min()!) / 2
        return raw.map { CGPoint(x: ($0.x - mx) * scale, y: ($0.y - my) * scale) }
    }()

    /// It beats twice and rests, as a heart does: a firm beat, a softer one, and a pause.
    private static func heart(at t: Double) -> [TabIconShape] {
        let u = fraction(t / heartBeat)
        let size = 1 + 0.14 * bump(u, 0, 0.17) + 0.09 * bump(u, 0.24, 0.40)
        return [.polygon(heartOutline.map { CGPoint(x: 5 + $0.x * size, y: 5.15 + $0.y * size) }, opacity: 1)]
    }

    private static let boltOutline = [CGPoint(x: 6.4, y: 0.4), CGPoint(x: 2.2, y: 5.6), CGPoint(x: 4.6, y: 5.6), CGPoint(x: 3.4, y: 9.6), CGPoint(x: 7.8, y: 4.2), CGPoint(x: 5.5, y: 4.2)]

    /// The bolt in two halves, a little under half its brightness taken from each in turn: the charge runs down it.
    private static func bolt(at t: Double) -> [TabIconShape] {
        let u = fraction(t / boltCycle)
        return [.polygon(clipped(boltOutline, y: 5, keepAbove: true), opacity: 1 - 0.45 * bump(u, 0, 0.5)),
                .polygon(clipped(boltOutline, y: 5, keepAbove: false), opacity: 1 - 0.45 * bump(u, 0.5, 1))]
    }

    /// The leaf's two halves (the shaded one is the lower side of its midrib), and its stem.
    private static let leafPieces: (light: [CGPoint], shade: [CGPoint], stem: [CGPoint]) = {
        let base = CGPoint(x: 2.5, y: 8.6), tip = CGPoint(x: 7.9, y: 2.2)
        let dx = tip.x - base.x, dy = tip.y - base.y
        let length = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / length, ny = dx / length
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in 0...14 {
            let v = Double(index) / 14
            let w = 2.15 * sin(.pi * pow(v, 0.85)) * (1 - 0.18 * v)
            let cx = base.x + dx * v, cy = base.y + dy * v
            left.append(CGPoint(x: cx + nx * w, y: cy + ny * w)); right.append(CGPoint(x: cx - nx * w, y: cy - ny * w))
        }
        return (left + [tip, base], right.reversed() + [base], stroke(CGPoint(x: 1.4, y: 9.4), CGPoint(x: 2.9, y: 7.9), width: 0.9))
    }()

    /// It sways on its stem, a few degrees either way.
    private static func leaf(at t: Double) -> [TabIconShape] {
        let degrees = 13 * sin(2 * .pi * t / leafSway)
        let pivot = CGPoint(x: 2.5, y: 8.6)
        return [.polygon(rotated(leafPieces.light, about: pivot, degrees: degrees), opacity: 1),
                .polygon(rotated(leafPieces.shade, about: pivot, degrees: degrees), opacity: 0.62),
                .polygon(rotated(leafPieces.stem, about: pivot, degrees: degrees), opacity: 1)]
    }

    /// The run of points of the circle (`center`, `radius`) that `keep` accepts (the part of one moon circle that is outside, or inside, the other).
    private static func arc(center: CGPoint, radius: Double, steps: Int, keep: (CGPoint) -> Bool) -> [CGPoint] {
        let all = (0..<steps).map { index -> CGPoint in
            let a = 2 * Double.pi * Double(index) / Double(steps)
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }
        let kept = Set(all.indices.filter { keep(all[$0]) })
        guard let first = kept.first(where: { !kept.contains(($0 + steps - 1) % steps) }) else { return all.filter(keep) }
        var run: [CGPoint] = []
        var index = first
        while kept.contains(index) { run.append(all[index]); index = (index + 1) % steps }
        return run
    }

    /// A crescent moon whose shadow drifts a little (it waxes and wanes), with a small star beside it that twinkles with it.
    private static func moon(at t: Double) -> [TabIconShape] {
        let s = 0.5 - 0.5 * cos(2 * .pi * t / moonCycle)
        let outerCenter = CGPoint(x: 4.7, y: 5.35), outerRadius = 4.25
        let innerCenter = CGPoint(x: outerCenter.x + 2.0 + 0.6 * s, y: outerCenter.y - 1.55 - 0.25 * s), innerRadius = 3.6
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
        let outer = arc(center: outerCenter, radius: outerRadius, steps: 72) { distance($0, innerCenter) >= innerRadius }
        var inner = arc(center: innerCenter, radius: innerRadius, steps: 90) { distance($0, outerCenter) <= outerRadius }
        if let last = outer.last, let first = inner.first, let end = inner.last, distance(first, last) > distance(end, last) { inner.reverse() }
        return [.polygon(outer + inner, opacity: 1), .disc(center: CGPoint(x: 7.95, y: 2.05), radius: 0.8, opacity: 1 - 0.55 * s)]
    }

    /// Two waves rolling to the left, the farther one fainter.
    private static func wave(at t: Double) -> [TabIconShape] {
        let phase = 2 * Double.pi * t / waveCycle
        func ribbon(y: Double, shift: Double, opacity: Double) -> TabIconShape {
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            for index in 0...22 {
                let x = 0.5 + 9.0 * Double(index) / 22
                let height = y + 1.1 * sin(2 * .pi * (x - 0.5) / 4.5 - phase + shift)
                top.append(CGPoint(x: x, y: height - 0.75)); bottom.append(CGPoint(x: x, y: height + 0.75))
            }
            return .polygon(top + bottom.reversed(), opacity: opacity)
        }
        return [ribbon(y: 3.5, shift: 0, opacity: 1), ribbon(y: 6.7, shift: 1.4, opacity: 0.6)]
    }

    private static let pawPad: [CGPoint] = (0..<36).map { index in
        let a = 2 * Double.pi * Double(index) / 36
        let r = 2.55 + 0.315 * cos(3 * (a - .pi / 2))
        return CGPoint(x: 5 + r * cos(a) * 1.12, y: 7.05 + r * sin(a) * 0.82)
    }

    /// A cat's paw. The toes dip one after another, as a paw taps; the pad stays.
    private static func paw(at t: Double) -> [TabIconShape] {
        let toes = [CGPoint(x: 1.9, y: 4.6), CGPoint(x: 3.95, y: 2.45), CGPoint(x: 6.05, y: 2.45), CGPoint(x: 8.1, y: 4.6)]
        var pieces: [TabIconShape] = toes.enumerated().map { index, center in
            let u = fraction(t / pawCycle - 0.25 * Double(index))
            return .disc(center: center, radius: 1.15, opacity: 1 - 0.55 * bump(u, 0, 0.25))
        }
        pieces.append(.polygon(pawPad, opacity: 1))
        return pieces
    }

    /// A flame that is round at the bottom and leans to a point: `bend` pushes its curve toward the tip's side.
    private static func teardrop(center: CGPoint, radius: Double, tip: CGPoint, bend: Double, opacity: Double) -> TabIconShape {
        let height = center.y - tip.y
        let left = curve(CGPoint(x: center.x - radius, y: center.y), CGPoint(x: center.x - radius * 0.98 + bend * 0.15, y: center.y - height * 0.62), tip, steps: 14)
        let right = curve(tip, CGPoint(x: center.x + radius * 0.9 + bend * 0.9, y: center.y - height * 0.42), CGPoint(x: center.x + radius, y: center.y), steps: 14)
        let belly = (1..<14).map { index -> CGPoint in
            let a = Double.pi * Double(index) / 14
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * 0.95 * sin(a))
        }
        return .polygon(right + belly + left, opacity: opacity)
    }

    /// Three tongues, a big one, a lick beside it and a bright core in it. They sway and flicker out of step.
    private static func flame(at t: Double) -> [TabIconShape] {
        let sway = sin(2 * .pi * t / flameCycle)
        let flicker = 0.45 * (0.5 - 0.5 * cos(2 * .pi * 2 * t / flameCycle))
        return [teardrop(center: CGPoint(x: 5.3, y: 6.5), radius: 2.95, tip: CGPoint(x: 6.0 + 0.75 * sway, y: 0.7 + flicker), bend: 0.9 + 0.5 * sway, opacity: 0.62),
                teardrop(center: CGPoint(x: 2.9, y: 7.4), radius: 1.55, tip: CGPoint(x: 2.2 - 0.35 * sway, y: 4.1 + flicker * 0.8), bend: -0.3, opacity: 0.62),
                teardrop(center: CGPoint(x: 5.3, y: 7.55), radius: 1.6, tip: CGPoint(x: 5.55 + 0.45 * sway, y: 4.4 + flicker * 0.7), bend: 0.4, opacity: 1)]
    }

    /// A five-pointed star that turns slowly: after a fifth of a turn it looks as it did, so the turn has no seam.
    private static func star(at t: Double) -> [TabIconShape] {
        let turn = 360 * t / starTurn
        let points = (0..<10).map { index in onCircle(index % 2 == 0 ? 4.85 : 2.0, degrees: -90 + 36 * Double(index) + turn) }
        return [.polygon(points, opacity: 1)]
    }

    /// `</>`: the two brackets breathe apart and together, and the slash a little fainter with them.
    private static func code(at t: Double) -> [TabIconShape] {
        let s = 0.5 - 0.5 * cos(2 * .pi * t / codeCycle)
        let apart = 0.55 * s, width = 1.25
        var pieces: [TabIconShape] = []
        for sign in [-1.0, 1.0] {
            let tipX = 5 + sign * (3.55 + apart)
            let arm = 5 + sign * (1.5 + apart)
            let top = CGPoint(x: arm, y: 2.7), middle = CGPoint(x: tipX, y: 5), bottom = CGPoint(x: arm, y: 7.3)
            pieces.append(.polygon(stroke(top, middle, width: width), opacity: 1))
            pieces.append(.polygon(stroke(middle, bottom, width: width), opacity: 1))
            pieces.append(.disc(center: middle, radius: width / 2, opacity: 1))
        }
        pieces.append(.polygon(stroke(CGPoint(x: 5.75, y: 1.9), CGPoint(x: 4.25, y: 8.1), width: 1.15), opacity: 1 - 0.3 * s))
        return pieces
    }

    /// A sun whose eight rays turn slowly round it; after an eighth of a turn it looks as it did.
    private static func sun(at t: Double) -> [TabIconShape] {
        let turn = 360 * t / sunTurn
        var pieces: [TabIconShape] = [.disc(center: center, radius: 2.35, opacity: 1)]
        for ray in 0..<8 {
            let degrees = 45 * Double(ray) + turn
            pieces.append(.polygon(stroke(onCircle(3.55, degrees: degrees), onCircle(4.7, degrees: degrees), width: 1.15), opacity: 1))
        }
        return pieces
    }

    /// The bars' heights `time` seconds in: each rises and falls on its own beat.
    static func barHeights(at time: Double) -> [Double] {
        [0.0, 1.6, 3.3, 4.9].map { 3.2 + 5.2 * (0.5 + 0.5 * sin(2 * .pi * time / barsCycle + $0)) }
    }

    private static func fraction(_ value: Double) -> Double { value - value.rounded(.down) }

    private static func onCircle(_ radius: Double, degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// Half of a disc, from `start` degrees (measured clockwise from the right) for 180°.
    private static func halfDisc(radius: Double, from start: Double) -> [CGPoint] {
        (0...36).map { onCircle(radius, degrees: start + 180 * Double($0) / 36) }
    }

    /// A four-pointed star with its points up, down, left and right, its sides curving in toward the middle.
    private static func star(radius: Double, pinch: Double) -> [CGPoint] {
        var points: [CGPoint] = []
        let steps = 20
        for tip in 0..<4 {
            let from = Double(tip) * 90 - 90, to = from + 90
            let start = onCircle(radius, degrees: from), end = onCircle(radius, degrees: to)
            let control = onCircle(radius * pinch, degrees: from + 45)
            for step in 0..<steps {
                let u = Double(step) / Double(steps)
                let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, c = u * u
                points.append(CGPoint(x: a * start.x + b * control.x + c * end.x, y: a * start.y + b * control.y + c * end.y))
            }
        }
        return points
    }

    /// Draws `shapes` into `context`, `size` points wide, in `color`.
    static func draw(_ shapes: [TabIconShape], in context: inout GraphicsContext, size: CGFloat, color: Color) {
        context.scaleBy(x: size / box, y: size / box)
        for shape in shapes {
            switch shape {
            case .disc, .bar, .polygon: context.fill(path(of: shape), with: .color(color.opacity(shape.opacity)))
            case .ring(_, _, let width, _): context.stroke(path(of: shape), with: .color(color.opacity(shape.opacity)), lineWidth: width)
            }
        }
    }

    /// The same pieces with Core Graphics, into a context whose y points down, for the icon that moves (`TabIconMotionView`). They are
    /// SwiftUI's own paths, so the picture is the one the `Canvas` above makes.
    static func draw(_ shapes: [TabIconShape], in cg: CGContext, size: CGFloat, color: NSColor) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.scaleBy(x: size / box, y: size / box)
        for shape in shapes {
            let tone = color.withAlphaComponent(color.alphaComponent * shape.opacity).cgColor
            cg.addPath(path(of: shape).cgPath)
            switch shape {
            case .disc, .bar, .polygon: cg.setFillColor(tone); cg.fillPath()
            case .ring(_, _, let width, _): cg.setStrokeColor(tone); cg.setLineWidth(width); cg.strokePath()
            }
        }
    }

    /// The outline of one piece, in the icon's box.
    private static func path(of shape: TabIconShape) -> Path {
        switch shape {
        case .disc(let center, let radius, _), .ring(let center, let radius, _, _):
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        case .bar(let rect, _):
            return Path(roundedRect: rect, cornerRadius: rect.width / 2)
        case .polygon(let points, _):
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            return path
        }
    }
}

extension TabIconShape {
    /// How opaque the piece is drawn, 0...1.
    var opacity: Double {
        switch self {
        case .disc(_, _, let opacity), .ring(_, _, _, let opacity), .bar(_, let opacity), .polygon(_, let opacity): opacity
        }
    }
}

// MARK: - The icon

/// A tab's icon in `color`. It moves while `working` (the tab's AI is busy) unless `animated` is false or Reduce Motion is on.
struct TabIconView: View {
    var icon: TabIcon
    var color: Color
    /// The side of the icon's box; 10 in a tab. The dot is half of it, which at 10 is the 5 pt dot tabs always had.
    var size: CGFloat = 10
    var working = false
    /// False holds the icon still (the animations preference, a collapsed island). Reduce Motion does the same.
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nobody can see the island (`\.islandSeen`): the icon holds its picture until someone can, and its first frame back is the moment's.
    @Environment(\.islandSeen) private var seen

    /// A new picture twenty times a second: enough for a slow turn this small.
    static let interval = 1.0 / 20

    /// Whether the icon moves now: an icon that moves at all, while its tab's AI works, unless the preference, a collapsed island
    /// or Reduce Motion holds it still.
    static func moves(_ icon: TabIcon, working: Bool, animated: Bool, reduceMotion: Bool) -> Bool {
        icon.moves && working && animated && !reduceMotion
    }

    var body: some View {
        Group {
            if icon == .dot {
                Circle().fill(color).frame(width: size / 2, height: size / 2)
            } else if Self.moves(icon, working: working, animated: animated, reduceMotion: reduceMotion) {
                TabIconMotion(icon: icon, color: color, side: size, seen: seen).frame(width: size, height: size)
            } else {
                picture(at: nil)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(.isImage)
    }

    private func picture(at time: Double?) -> some View {
        Canvas { context, _ in
            TabIconArt.draw(TabIconArt.shapes(of: icon, at: time), in: &context, size: size, color: color)
        }.frame(width: size, height: size)
    }
}

/// The moving icon in SwiftUI: the AppKit view that draws it, told what to draw and whether anyone can see it.
private struct TabIconMotion: NSViewRepresentable {
    var icon: TabIcon
    var color: Color
    var side: CGFloat
    var seen: Bool
    func makeNSView(context: Context) -> TabIconMotionView { TabIconMotionView(frame: NSRect(x: 0, y: 0, width: side, height: side)) }
    func updateNSView(_ view: TabIconMotionView, context: Context) {
        // The colour is resolved here, in the environment it is drawn in: a tab's colour has a shade for each theme, and the AppKit view knows no theme.
        let resolved = NSColor(cgColor: color.resolve(in: context.environment).cgColor) ?? .white
        view.show(icon, color: resolved, side: side, seen: seen)
    }
}

/// A tab's icon while it moves: it repaints only itself, twenty times a second, from the clock (the picture at a moment is the one the
/// `Canvas` would draw then), while it is in a window and the island can be seen; otherwise its timer is paused and nothing runs. It takes
/// no clicks (the tab's button under it does) and is no element of its own for VoiceOver (`TabIconView` speaks for it).
final class TabIconMotionView: NSView {
    private(set) var icon = TabIcon.orbit
    private(set) var color = NSColor.white
    private(set) var side: CGFloat = 10
    private(set) var seen = true
    private lazy var ticker = PetTicker { [weak self] in self?.needsDisplay = true }
    /// Seconds between frames right now: 0 while it holds still.
    var frameInterval: TimeInterval { ticker.interval }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }

    func show(_ icon: TabIcon, color: NSColor, side: CGFloat, seen: Bool) {
        if icon != self.icon || color != self.color || side != self.side { needsDisplay = true }
        self.icon = icon; self.color = color; self.side = side
        // Back in sight: the picture of this moment at once, not the one it held.
        if seen, !self.seen { needsDisplay = true }
        self.seen = seen
        schedule()
    }

    private func schedule() {
        guard window != nil, seen else { ticker.pause(); return }
        ticker.host = self
        ticker.run(every: TabIconView.interval)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        TabIconArt.draw(TabIconArt.shapes(of: icon, at: Date().timeIntervalSinceReferenceDate), in: cg, size: side, color: color)
    }
}

// MARK: - The picker

/// The icons in a grid, for the tab's editor. The chosen one moves, and so does the one under the pointer, so each can be seen doing what it will do in
/// the tab. Each is drawn in the colour just chosen, on a chip that is a wash of the theme's ink: so the icon is judged on the island's own colours.
struct TabIconPicker: View {
    @Binding var selection: TabIcon
    var tint: TabTint
    var animated: Bool

    /// Eight to a row: sixteen icons make two rows.
    static let columns = 8
    static let chipWidth: CGFloat = 28, chipHeight: CGFloat = 28, spacing: CGFloat = 5
    /// How wide the grid is.
    static var width: CGFloat { CGFloat(columns) * chipWidth + CGFloat(columns - 1) * spacing }

    var body: some View {
        let icons = TabIcon.allCases
        let rows = stride(from: 0, to: icons.count, by: Self.columns).map { Array(icons[$0..<min($0 + Self.columns, icons.count)]) }
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { icon in
                        TabIconChoice(icon: icon, tint: tint, selected: selection == icon, animated: animated) { selection = icon }
                    }
                }
            }
        }
    }
}

private struct TabIconChoice: View {
    var icon: TabIcon
    var tint: TabTint
    var selected: Bool
    var animated: Bool
    var choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: choose) {
            TabIconView(icon: icon, color: tint.color, size: 16, working: selected || hovering, animated: animated)
                .frame(width: TabIconPicker.chipWidth, height: TabIconPicker.chipHeight)
                .background(selected ? tint.color.opacity(0.18) : Color.nookWash(hovering ? 0.12 : 0.06), in: shape)
                .overlay(shape.strokeBorder(selected ? tint.color.opacity(0.9) : Color.clear, lineWidth: 1.5))
                .contentShape(shape)
        }.nookPress(.none, depth: PressDepth.card)
            .onHover { hovering = $0 }
            .help(icon.title)
            .accessibilityLabel(icon.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
