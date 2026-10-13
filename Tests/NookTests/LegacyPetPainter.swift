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
        let t = pose.tail
        let tail = NSBezierPath(); tail.move(to: t.p0); tail.curve(to: t.p3, controlPoint1: t.c1, controlPoint2: t.c2)
        tail.lineWidth = t.width; tail.lineCapStyle = .round; tail.stroke()
        pose.legs.prefix(2).filter { !raised($0) }.forEach { limb($0) }
        // The body has been one figure since the torso was redrawn (`PetTorso`): the old painter draws that figure too, its own way (a
        // new NSBezierPath every frame), so the two are still held to painting the same cat.
        let body = NSBezierPath()
        PetTorso(pose.haunch, pose.chest).trace(move: { body.move(to: $0) }, curve: { body.curve(to: $2, controlPoint1: $0, controlPoint2: $1) })
        body.close(); body.fill()
        pose.legs.dropFirst(2).filter { !raised($0) }.forEach { limb($0) }
        // The head has its own frame so tilt and scale carry the ears and eyes along.
        cg.saveGState(); cg.translateBy(x: pose.head.x, y: pose.head.y); cg.scaleBy(x: pose.headScale, y: pose.headScale); cg.rotate(by: pose.tilt)
        NSBezierPath(ovalIn: NSRect(x: -9.3, y: -7.4, width: 18.6, height: 14.8)).fill()
        // The ears and the eyes have been laid out by `PetFace` since the face was made to hold together (an ear's base stays on the
        // head, the eyes stay in the face): the old painter draws them where it says too, its own way.
        for (side, angle) in [(CGFloat(-1), pose.earL), (CGFloat(1), pose.earR)] {
            let corners = PetFace.ear(side: side, angle: angle)
            let ear = NSBezierPath()
            ear.move(to: corners.outer); ear.line(to: corners.tip); ear.line(to: corners.inner); ear.close(); ear.fill()
        }
        NSColor.black.setFill()
        let face = PetFace(pose)
        for side: CGFloat in [-1, 1] { NSBezierPath(ovalIn: face.eyeRect(side)).fill() }
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
