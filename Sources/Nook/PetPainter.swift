import AppKit

/// Paints the cat in rig units (feet at y 0) with Core Graphics straight into the current context. It is called for every frame the
/// cat draws, so it builds no objects: no paths, colours or arrays are made per call (the colours are tables made once, the
/// shapes are drawn with the context's own path), and everything that is the same for every frame is hoisted out of it.
enum PetPainter {
    // MARK: Colours (made once)

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    private static let black = srgb(0, 0, 0)
    /// The coats' fills and stripes, in the order of `PetCoat.allCases`.
    private static let coats: [(fill: CGColor, stripe: CGColor?)] = PetCoat.allCases.map { coat in
        (srgb(coat.fill.red, coat.fill.green, coat.fill.blue), coat.stripe.map { srgb($0.red, $0.green, $0.blue) })
    }
    /// The same mint as the notch's activity dots, for the ball.
    private static let ballColor = NSColor.systemMint.withAlphaComponent(0.9).cgColor
    private static let moteColor = srgb(1, 0.94, 0.66, 0.95)
    private static let collarColor = srgb(0.32, 0.73, 0.61)
    private static let bellColor = srgb(0.97, 0.80, 0.38)
    private static let bowColor = srgb(0.85, 0.47, 0.34)
    /// A tear and the glint in a wet eye: the same cool white-blue in both, a little translucent, so it reads on the white face and on the black of the eyes.
    private static let tearColor = srgb(0.60, 0.82, 1.0, 0.92)
    private static let glintColor = srgb(1, 1, 1, 0.95)

    /// A foot higher than this (rig units) is a paw raised to the face, drawn over the head.
    static let raisedAbove: CGFloat = 14.5

    // MARK: Drawing

    /// Paints `pose` into the current graphics context. A `ledge` is the lowest y that may be painted: a cat peeking over the
    /// island's edge sinks below it and is cut there, so nothing ever lands outside the drawable area.
    static func draw(_ pose: PetPose, look: PetLook = PetLook(), ledge: CGFloat? = nil) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        draw(pose, look: look, ledge: ledge, in: cg)
    }

    static func draw(_ pose: PetPose, look: PetLook = PetLook(), ledge: CGFloat? = nil, in cg: CGContext) {
        let coat = coats[look.coat.index]
        let fill = coat.fill
        cg.saveGState()
        defer { cg.restoreGState() }
        if let ledge { cg.clip(to: CGRect(x: -400, y: ledge, width: 800, height: 800)) }
        cg.translateBy(x: 0, y: pose.y)
        cg.setFillColor(fill); cg.setStrokeColor(fill)
        cg.setLineCap(.round); cg.setLineJoin(.round)

        // The tail goes behind everything.
        let t = pose.tail
        cg.move(to: t.p0); cg.addCurve(to: t.p3, control1: t.c1, control2: t.c2)
        cg.setLineWidth(t.width); cg.strokePath()
        if let stripe = coat.stripe { tailRings(t, stripe, in: cg) }

        // Far legs, the body, near legs: a leg raised to the face waits to be drawn over the head.
        let legs = pose.legs
        if legs.farHind.foot.y <= raisedAbove { limb(legs.farHind, in: cg) }
        if legs.farFront.foot.y <= raisedAbove { limb(legs.farFront, in: cg) }
        oval(pose.haunch, in: cg)
        oval(pose.chest, in: cg)
        if let stripe = coat.stripe { flankStripes(pose.haunch, stripe, in: cg) }
        if legs.nearHind.foot.y <= raisedAbove { limb(legs.nearHind, in: cg) }
        if legs.nearFront.foot.y <= raisedAbove { limb(legs.nearFront, in: cg) }

        // The head has its own frame, so tilt and scale carry the ears, the face and what is worn on it along.
        cg.saveGState()
        cg.translateBy(x: pose.head.x, y: pose.head.y); cg.scaleBy(x: pose.headScale, y: pose.headScale); cg.rotate(by: pose.tilt)
        cg.fillEllipse(in: CGRect(x: -9.3, y: -7.4, width: 18.6, height: 14.8))
        ear(side: -1, angle: pose.earL, in: cg)
        ear(side: 1, angle: pose.earR, in: cg)
        if let stripe = coat.stripe { foreheadStripes(stripe, in: cg) }
        if look.accessory == .collar || look.accessory == .bow { neckwear(look.accessory, swing: pose.swing, in: cg) }
        cg.setFillColor(black)
        let open = max(0, pose.eyes)
        let w = 2.2 + 0.9 * (1 - min(1, open)), h = max(0.55, 2.9 * open)
        cg.fillEllipse(in: CGRect(x: -4.3 + pose.look.x - w / 2, y: 0.3 + pose.look.y - h / 2, width: w, height: h))
        cg.fillEllipse(in: CGRect(x: 4.3 + pose.look.x - w / 2, y: 0.3 + pose.look.y - h / 2, width: w, height: h))
        if pose.glisten > 0.02 { glints(pose, w: w, h: h, in: cg) }
        if pose.tear > 0.01 { tear(pose.tear, in: cg) }
        if pose.mouth > 0.02 {
            let m = pose.mouth
            let rx = 1.1 + 1.8 * m, ry = 0.3 + 3.2 * m
            cg.fillEllipse(in: CGRect(x: -rx, y: -3.1 - 0.5 * m - ry, width: 2 * rx, height: 2 * ry))
        }
        if look.accessory == .glasses { glasses(in: cg) }
        cg.restoreGState()

        // Raised paws, over the face; a thin black seam keeps a white forearm readable on the white head.
        cg.setFillColor(fill); cg.setStrokeColor(fill)
        if legs.farHind.foot.y > raisedAbove { limb(legs.farHind, halo: true, in: cg, color: fill) }
        if legs.farFront.foot.y > raisedAbove { limb(legs.farFront, halo: true, in: cg, color: fill) }
        if legs.nearHind.foot.y > raisedAbove { limb(legs.nearHind, halo: true, in: cg, color: fill) }
        if legs.nearFront.foot.y > raisedAbove { limb(legs.nearFront, halo: true, in: cg, color: fill) }

        if pose.ballSize > 0 {
            let r = 2.3 * pose.ballSize
            cg.setFillColor(ballColor)
            cg.fillEllipse(in: CGRect(x: pose.ball.x - r, y: pose.ball.y - r, width: 2 * r, height: 2 * r))
        }
        if pose.moteSize > 0 {
            let r = 1.45 * pose.moteSize
            cg.setFillColor(moteColor)
            cg.fillEllipse(in: CGRect(x: pose.mote.x - r, y: pose.mote.y - r * 0.8, width: 2 * r, height: 1.6 * r))
        }
        if pose.zAlpha > PetPose.zVisible { sleepZs(pose, color: fill, in: cg) }
        if pose.sparkle > 0 { sparkles(pose, color: fill, in: cg) }
    }

    // MARK: Parts

    private static func limb(_ l: PetLimb, halo: Bool = false, in cg: CGContext, color: CGColor? = nil) {
        if halo {
            // A paw raised in front of the face is white on white: a thin black seam around the forearm keeps it readable.
            cg.setStrokeColor(black)
            cg.move(to: l.knee); cg.addLine(to: l.foot)
            cg.setLineWidth(l.width + 1.9); cg.strokePath()
            if let color { cg.setStrokeColor(color) }
        }
        cg.move(to: l.hip); cg.addLine(to: l.knee); cg.addLine(to: l.foot)
        cg.setLineWidth(l.width); cg.strokePath()
    }

    private static func oval(_ o: PetOval, in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: o.cx, y: o.cy); cg.rotate(by: o.angle)
        cg.fillEllipse(in: CGRect(x: -o.rx, y: -o.ry, width: 2 * o.rx, height: 2 * o.ry))
        cg.restoreGState()
    }

    private static func ear(side: CGFloat, angle: CGFloat, in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: side * 5.8, y: 4.4); cg.rotate(by: side * -angle); cg.translateBy(x: -side * 5.8, y: -4.4)
        cg.move(to: CGPoint(x: side * 9.1, y: 1.6)); cg.addLine(to: CGPoint(x: side * 7.5, y: 12.2)); cg.addLine(to: CGPoint(x: side * 2.2, y: 6.6))
        cg.closePath(); cg.fillPath()
        cg.restoreGState()
    }

    // MARK: Stripes (the tabby coats)

    /// Four dark bands across the tail, at fixed places along it, so they travel with it.
    private static func tailRings(_ t: PetTail, _ stripe: CGColor, in cg: CGContext) {
        cg.saveGState()
        cg.setStrokeColor(stripe); cg.setLineWidth(0.95); cg.setLineCap(.butt)
        for u in [CGFloat(0.4), 0.58, 0.75, 0.9] {
            let v = 1 - u
            let px = v * v * v * t.p0.x + 3 * v * v * u * t.c1.x + 3 * v * u * u * t.c2.x + u * u * u * t.p3.x
            let py = v * v * v * t.p0.y + 3 * v * v * u * t.c1.y + 3 * v * u * u * t.c2.y + u * u * u * t.p3.y
            let dx = 3 * v * v * (t.c1.x - t.p0.x) + 6 * v * u * (t.c2.x - t.c1.x) + 3 * u * u * (t.p3.x - t.c2.x)
            let dy = 3 * v * v * (t.c1.y - t.p0.y) + 6 * v * u * (t.c2.y - t.c1.y) + 3 * u * u * (t.p3.y - t.c2.y)
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len * t.width * 0.5, ny = dx / len * t.width * 0.5
            cg.move(to: CGPoint(x: px - nx, y: py - ny)); cg.addLine(to: CGPoint(x: px + nx, y: py + ny))
        }
        cg.strokePath()
        cg.restoreGState()
    }

    /// Two short bars on each side of the body, where the haunch shows beside the chest.
    private static func flankStripes(_ h: PetOval, _ stripe: CGColor, in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: h.cx, y: h.cy); cg.rotate(by: h.angle)
        cg.setStrokeColor(stripe); cg.setLineWidth(0.9)
        for side in [CGFloat(-1), 1] {
            cg.move(to: CGPoint(x: side * 7.0, y: 3.0)); cg.addLine(to: CGPoint(x: side * 5.7, y: 0.5))
            cg.move(to: CGPoint(x: side * 7.7, y: -0.9)); cg.addLine(to: CGPoint(x: side * 6.5, y: -3.0))
        }
        cg.strokePath()
        cg.restoreGState()
    }

    /// The tabby's "M": three short strokes on the forehead.
    private static func foreheadStripes(_ stripe: CGColor, in cg: CGContext) {
        cg.setStrokeColor(stripe); cg.setLineWidth(0.9)
        cg.move(to: CGPoint(x: -2.5, y: 6.1)); cg.addLine(to: CGPoint(x: -1.9, y: 3.7))
        cg.move(to: CGPoint(x: 0, y: 6.4)); cg.addLine(to: CGPoint(x: 0, y: 3.9))
        cg.move(to: CGPoint(x: 2.5, y: 6.1)); cg.addLine(to: CGPoint(x: 1.9, y: 3.7))
        cg.strokePath()
    }

    // MARK: Accessories (in the head's frame)

    /// What hangs under the chin: a collar with a bell that swings with the head, or a bow tie.
    private static func neckwear(_ kind: PetAccessory, swing: CGFloat, in cg: CGContext) {
        if kind == .collar {
            cg.setStrokeColor(collarColor); cg.setLineWidth(1.7)
            cg.move(to: CGPoint(x: -6.6, y: -5.5)); cg.addCurve(to: CGPoint(x: 6.6, y: -5.5), control1: CGPoint(x: -3.2, y: -9.5), control2: CGPoint(x: 3.2, y: -9.5))
            cg.strokePath()
            // The bell hangs from the middle of the band and swings about it.
            cg.saveGState()
            cg.translateBy(x: 0, y: -7.4); cg.rotate(by: swing * 0.7)
            cg.setFillColor(bellColor)
            cg.fillEllipse(in: CGRect(x: -1.25, y: -3.1, width: 2.5, height: 2.5))
            cg.restoreGState()
        } else {
            cg.setFillColor(bowColor)
            cg.move(to: CGPoint(x: 0, y: -8.2)); cg.addLine(to: CGPoint(x: -3.9, y: -5.9)); cg.addLine(to: CGPoint(x: -3.9, y: -10.5)); cg.closePath()
            cg.move(to: CGPoint(x: 0, y: -8.2)); cg.addLine(to: CGPoint(x: 3.9, y: -5.9)); cg.addLine(to: CGPoint(x: 3.9, y: -10.5)); cg.closePath()
            cg.fillPath()
            cg.fillEllipse(in: CGRect(x: -1, y: -9.2, width: 2, height: 2))
        }
    }

    /// A small white glint at the upper left of each eye: the eyes look wet. It sits on the pupil, so it moves with it and shrinks as a lid closes.
    private static func glints(_ pose: PetPose, w: CGFloat, h: CGFloat, in cg: CGContext) {
        let r = 0.62 * pose.glisten * min(1, max(0.25, h / 2.9))
        cg.saveGState()
        cg.setFillColor(glintColor)
        for side in [CGFloat(-1), 1] {
            let cx = side * 4.3 + pose.look.x - w * 0.2, cy = 0.3 + pose.look.y + h * 0.18
            cg.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        cg.restoreGState()
    }

    /// A tear: a drop that wells at the lower lid of the left eye, runs down the cheek, swells a little as it goes and is gone before the chin. `u` is how far it has run.
    private static func tear(_ u: CGFloat, in cg: CGContext) {
        let run = u * u * (3 - 2 * u)
        let swell = CGFloat(sin(Double(min(1, u * 1.15)) * .pi * 0.5))
        let fade = u < 0.82 ? 1 : max(0, 1 - (u - 0.82) / 0.18)
        let r = 0.5 + 0.35 * swell
        let x = -4.5 - 0.45 * run, y = -1.2 - 5.4 * run
        cg.saveGState()
        cg.setAlpha(min(1, u * 8) * fade)
        cg.setFillColor(tearColor)
        // The drop is a disc with a point on top (it runs head down).
        cg.fillEllipse(in: CGRect(x: x - r, y: y - r * 1.1, width: 2 * r, height: 2.2 * r))
        cg.move(to: CGPoint(x: x - r * 0.86, y: y + r * 0.3)); cg.addLine(to: CGPoint(x: x, y: y + r * 2.2)); cg.addLine(to: CGPoint(x: x + r * 0.86, y: y + r * 0.3))
        cg.closePath(); cg.fillPath()
        cg.restoreGState()
    }

    /// Round glasses: a thin black rim around each eye. The rim stays on the face while the pupils move inside it.
    private static func glasses(in cg: CGContext) {
        cg.setStrokeColor(black); cg.setLineWidth(0.75)
        cg.strokeEllipse(in: CGRect(x: -4.3 - 3.2, y: 0.3 - 3.2, width: 6.4, height: 6.4))
        cg.strokeEllipse(in: CGRect(x: 4.3 - 3.2, y: 0.3 - 3.2, width: 6.4, height: 6.4))
        cg.move(to: CGPoint(x: -1.1, y: 0.9)); cg.addLine(to: CGPoint(x: 1.1, y: 0.9))
        cg.strokePath()
    }

    // MARK: Extras

    /// The z's of a nap: two that rise, fade and swell in turn.
    private static func sleepZs(_ pose: PetPose, color: CGColor, in cg: CGContext) {
        cg.setStrokeColor(color); cg.setLineWidth(1.1)
        for i in 0..<2 {
            let rise = (pose.zRise + CGFloat(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let size = 1.7 + 0.5 * CGFloat(i) + rise * 1.1
            let at = CGPoint(x: pose.head.x + 0.5 + rise * 6, y: pose.head.y + 7 + rise * 15)
            cg.setAlpha(min(1, 0.6 * pose.zAlpha * CGFloat(sin(Double(rise) * .pi))))
            cg.move(to: CGPoint(x: at.x - size, y: at.y + size)); cg.addLine(to: CGPoint(x: at.x + size, y: at.y + size))
            cg.addLine(to: CGPoint(x: at.x - size, y: at.y - size)); cg.addLine(to: CGPoint(x: at.x + size, y: at.y - size))
            cg.strokePath()
        }
        cg.setAlpha(1)
    }

    /// The celebration's glints: three four-point stars around the head, each swelling and fading in turn.
    private static func sparkles(_ pose: PetPose, color: CGColor, in cg: CGContext) {
        cg.setFillColor(color)
        sparkle(pose, dx: 10.6, dy: 9.4, size: 2.9, from: 0.0, to: 0.7, in: cg)
        sparkle(pose, dx: -10.2, dy: 8.2, size: 2.1, from: 0.18, to: 0.85, in: cg)
        sparkle(pose, dx: 13.2, dy: 2.4, size: 1.8, from: 0.3, to: 1.0, in: cg)
        cg.setAlpha(1)
    }

    private static func sparkle(_ pose: PetPose, dx: CGFloat, dy: CGFloat, size: CGFloat, from: CGFloat, to: CGFloat, in cg: CGContext) {
        let local = (pose.sparkle - from) / (to - from)
        guard local > 0, local < 1 else { return }
        let glow = CGFloat(sin(Double(local) * .pi)), s = size * (0.45 + 0.55 * glow), k = s * 0.3
        cg.setAlpha(0.95 * glow)
        let c = CGPoint(x: pose.head.x + dx, y: pose.head.y + dy)
        cg.move(to: CGPoint(x: c.x, y: c.y + s)); cg.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
        cg.addLine(to: CGPoint(x: c.x + s, y: c.y)); cg.addLine(to: CGPoint(x: c.x + k, y: c.y - k))
        cg.addLine(to: CGPoint(x: c.x, y: c.y - s)); cg.addLine(to: CGPoint(x: c.x - k, y: c.y - k))
        cg.addLine(to: CGPoint(x: c.x - s, y: c.y)); cg.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
        cg.closePath(); cg.fillPath()
    }
}

/// The collapsed island's wing as `PetView` paints it: the island's black shape and the cat over it. The shape is the mask too: a cat
/// peeking over the island's bottom edge is cut by it, and nothing can land outside what the island draws. The path is made once per
/// size, not once per frame.
enum PetWing {
    private static var cache: (size: CGSize, path: CGPath)?

    /// The island's black shape: square top against the screen edge, rounded bottom corners.
    static func islandPath(_ bounds: NSRect) -> CGPath {
        if let cache, cache.size == bounds.size { return cache.path }
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 0, y: bounds.height))
        wing.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        wing.addLine(to: CGPoint(x: bounds.width, y: 10))
        wing.addCurve(to: CGPoint(x: bounds.width - 10, y: 0), control1: CGPoint(x: bounds.width, y: 4), control2: CGPoint(x: bounds.width - 4, y: 0))
        wing.addLine(to: CGPoint(x: 10, y: 0))
        wing.addCurve(to: CGPoint(x: 0, y: 10), control1: CGPoint(x: 4, y: 0), control2: CGPoint(x: 0, y: 4))
        wing.closeSubpath()
        cache = (bounds.size, wing)
        return wing
    }

    /// Paints the cat in the wing of an island of `bounds` (origin at its bottom left), clipped to the island's shape.
    static func drawCat(_ pose: PetPose, look: PetLook = PetLook(), bounds: NSRect, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(islandPath(bounds)); cg.clip()
        let ground = bounds.height / 2 - 9
        cg.translateBy(x: PetAnimation.compactAnchor + pose.x, y: ground)
        cg.scaleBy(x: PetAnimation.compactScale, y: PetAnimation.compactScale)
        PetPainter.draw(pose, look: look, ledge: -ground / PetAnimation.compactScale, in: cg)
    }

    /// What `PetView.draw(_:)` does for a dirty rect over the cat's wing: the island's black, then the cat.
    static func draw(_ pose: PetPose, look: PetLook = PetLook(), bounds: NSRect, in cg: CGContext) {
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.addPath(islandPath(bounds)); cg.fillPath()
        drawCat(pose, look: look, bounds: bounds, in: cg)
    }
}
