import AppKit
#if !PETLAB
@testable import Nook
#endif

/// The painter the cat had before it was rebuilt, kept as it was (NSBezierPath and NSColor made for every frame), so the new one can be held to
/// two things: it paints the same cat, and it costs less to do it. Nothing in the app uses it.
enum LegacyPetPainter {
    /// Paints the cat in rig units (feet at y 0). A `ledge` is the lowest y that may be painted: a cat peeking over
    /// the island's edge sinks below it and is cut there, so nothing ever lands outside the drawable area.
    static func draw(_ pose: PetPose, color: NSColor = .white, ledge: CGFloat? = nil) {
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
