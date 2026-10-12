import AppKit
import XCTest
@testable import Nook

/// The painter that draws the cat for every frame: it paints the cat the old one painted, dresses it in its coat and what it wears, draws
/// the mouth and the speck, restores what it touches, and costs less than the one it replaced (which made a path, a colour and an array
/// or two for every part of every frame).
@MainActor
final class PetPainterTests: XCTestCase {
    private let ppp = 4, canvas = CGSize(width: 56, height: 40)

    /// One frame of `pose` on black, drawn by `paint` in the frame's own units (feet at the canvas's (28, 8)), as RGBA bytes.
    private func pixels(ppp: Int? = nil, _ paint: (CGContext) -> Void) -> [UInt8] {
        let scale = ppp ?? self.ppp
        let w = Int(canvas.width) * scale, h = Int(canvas.height) * scale
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        cg.translateBy(x: 28, y: 8); cg.scaleBy(x: 0.9, y: 0.9)
        paint(cg)
        let data = cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: data, count: w * h * 4))
    }
    private func drawNew(_ pose: PetPose, look: PetLook = PetLook(), ledge: CGFloat? = nil) -> [UInt8] {
        pixels { cg in
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            PetPainter.draw(pose, look: look, ledge: ledge, in: cg)
        }
    }
    private func drawOld(_ pose: PetPose, ledge: CGFloat? = nil) -> [UInt8] {
        pixels { cg in
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            LegacyPetPainter.draw(pose, color: .white, ledge: ledge)
        }
    }
    /// The largest and the mean difference of the red channel between two renders, 0...1.
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (max: Double, mean: Double, count: Int) {
        var most = 0.0, total = 0.0, differing = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = abs(Double(a[i]) - Double(b[i])) / 255
            most = max(most, d); total += d
            if d > 0.2 { differing += 1 }
        }
        return (most, total / Double(a.count / 4), differing)
    }
    private func lit(_ p: [UInt8]) -> Int { stride(from: 0, to: p.count, by: 4).filter { Int(p[$0]) + Int(p[$0 + 1]) + Int(p[$0 + 2]) > 120 }.count }

    /// A spread of poses with everything the old painter drew: sitting, walking, both ends of a stretch, a paw raised to the face (the
    /// seam), a ball, the z's of a nap, a celebration's sparkles, a cat held by the scruff, and one sunk behind a ledge.
    private var poses: [(String, PetPose, CGFloat?)] {
        let ledge: CGFloat = -7 / PetAnimation.compactScale
        return [
            ("sit", PetAnimation.sit(time: 3), nil), ("work", PetAnimation.sit(time: 3, alert: 1), nil),
            ("walk", PetAnimation.walk(phase: 1.3, amp: 1, time: 3), nil), ("walk-left", PetAnimation.walk(phase: 2.1, amp: 1, time: 3).mirrored(), nil),
            ("bow", PetAnimation.bow(time: 3), nil), ("arch", PetAnimation.arch(time: 3), nil),
            ("loaf", PetAnimation.loaf(rest: 0, time: 3), nil), ("nap", { var p = PetAnimation.loaf(rest: 1, curl: 1, time: 3); p.zAlpha = 1; p.zRise = 0.3; return p }(), nil),
            ("groom", PetAnimation.groom(u: 1.5, time: 3), nil), ("wave", PetAnimation.wave(time: 3, amount: 1), nil), ("play", PetAnimation.play(time: 3, intensity: 1), nil),
            ("celebrate", PetAnimation.celebrate(u: 0.7, time: 3), nil), ("lifted", PetAnimation.lifted(time: 3), nil),
            ("peek", PetAnimation.peek(u: 3.2, time: 3, ledge: ledge), ledge), ("peek-ears", PetAnimation.peek(u: 1.7, time: 3, ledge: ledge), ledge),
            ("curious", PetAnimation.curious(PetAnimation.sit(time: 3), gaze: PetGaze(dx: 0.9, dy: 0.3), amount: 1, age: 0.45), nil),
        ]
    }

    // MARK: The same cat

    func testItPaintsTheCatTheOldPainterPainted() {
        for (name, pose, ledge) in poses {
            let d = difference(drawNew(pose, ledge: ledge), drawOld(pose, ledge: ledge))
            XCTAssertLessThan(d.mean, 0.0006, "\(name): the two paintings are the same picture (mean difference \(d.mean))")
            XCTAssertLessThan(d.count, 60, "\(name): at most a few edge pixels differ by more than a fifth (\(d.count) do)")
        }
    }

    func testTheOldCatsPixelsAreTheNewCatsWhiteOnes() {
        // The default look is white, with no accessory: the pixels the old painter made are the ones the new one makes.
        for (name, pose, ledge) in poses where ledge == nil {
            let new = drawNew(pose, look: PetLook(coat: .snow, accessory: .none)), old = drawOld(pose)
            XCTAssertGreaterThan(lit(new), 500, name)
            XCTAssertEqual(Double(lit(new)), Double(lit(old)), accuracy: Double(lit(old)) * 0.01, "\(name): the same area is painted")
        }
    }

    // MARK: What is new

    func testTheCoatsColourTheCatAndTheStripesAreDarkerThanTheCoat() {
        let pose = PetAnimation.sit(time: 3)
        func average(_ look: PetLook) -> (r: Double, g: Double, b: Double) {
            let p = drawNew(pose, look: look)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for i in stride(from: 0, to: p.count, by: 4) where p[i] > 140 || p[i + 1] > 140 || p[i + 2] > 140 { r += Double(p[i]); g += Double(p[i + 1]); b += Double(p[i + 2]); n += 1 }
            return (r / n / 255, g / n / 255, b / n / 255)
        }
        let white = average(PetLook(coat: .snow)), ginger = average(PetLook(coat: .ginger)), silver = average(PetLook(coat: .silver))
        XCTAssertGreaterThan(white.r, 0.95); XCTAssertGreaterThan(white.b, 0.95)
        XCTAssertGreaterThan(ginger.r, ginger.b + 0.2, "orange")
        XCTAssertGreaterThan(silver.b, silver.r, "a cool grey")
        // A tabby's stripes are darker pixels inside the body: the plain coat of the same colour has none there.
        let tabby = drawNew(pose, look: PetLook(coat: .tabby)), plain = drawNew(pose, look: PetLook(coat: .snow))
        func dark(_ p: [UInt8], _ q: [UInt8]) -> Int { stride(from: 0, to: p.count, by: 4).filter { q[$0] > 100 && p[$0] < 150 }.count }
        XCTAssertGreaterThan(dark(tabby, plain), 80, "stripes on the forehead, the flanks and the tail")
        XCTAssertEqual(lit(drawNew(pose, look: PetLook(coat: .tabby))), lit(plain), accuracy: lit(plain) / 30, "the silhouette is the same: only the colours differ")
    }

    func testTheAccessoriesAreDrawnWhereTheyBelongAndFollowTheHead() {
        let pose = PetAnimation.sit(time: 3)
        let plain = drawNew(pose)
        func extra(_ look: PetLook, _ p: PetPose = pose) -> Int {
            let image = drawNew(p, look: look)
            return stride(from: 0, to: image.count, by: 4).filter { i in
                let r = Int(image[i]), g = Int(image[i + 1]), b = Int(image[i + 2])
                return abs(r - g) > 40 || abs(g - b) > 40 || abs(r - b) > 40   // coloured pixels: a white cat has none
            }.count
        }
        XCTAssertEqual(extra(PetLook()), 0, "a plain white cat has no colour in it")
        XCTAssertGreaterThan(extra(PetLook(accessory: .collar)), 120, "the collar and its gold bell")
        XCTAssertGreaterThan(extra(PetLook(accessory: .bow)), 90, "the bow tie")
        // The glasses are black rings on the white face.
        let glasses = drawNew(pose, look: PetLook(accessory: .glasses))
        let blackened = stride(from: 0, to: glasses.count, by: 4).filter { glasses[$0] < 60 && plain[$0] > 200 }.count
        XCTAssertGreaterThan(blackened, 150, "rims round the eyes")
        // The bell hangs lower and swings: a swung bell is in a different place than a still one.
        var swung = pose; swung.swing = 1
        let a = drawNew(pose, look: PetLook(accessory: .collar)), b = drawNew(swung, look: PetLook(accessory: .collar))
        XCTAssertGreaterThan(difference(a, b).count, 10, "the bell swings")
        // With the head tilted the collar goes with it.
        var tilted = pose; tilted.tilt = 0.35
        XCTAssertNotEqual(drawNew(tilted, look: PetLook(accessory: .collar)), drawNew(tilted))
        XCTAssertGreaterThan(difference(drawNew(tilted, look: PetLook(accessory: .collar)), a).count, 50)
    }

    func testTheMouthAndTheSpeckAreDrawn() {
        let pose = PetAnimation.sit(time: 3)
        var yawning = pose; yawning.mouth = 1
        let closed = drawNew(pose), open = drawNew(yawning)
        XCTAssertLessThan(lit(open), lit(closed) - 100, "an open mouth is a dark hole in the face")
        var mew = pose; mew.mouth = 0.5
        XCTAssertLessThan(lit(drawNew(mew)), lit(closed)); XCTAssertGreaterThan(lit(drawNew(mew)), lit(open))
        var chased = pose; chased.mote = CGPoint(x: 17, y: 20); chased.moteSize = 1
        let withSpeck = drawNew(chased)
        let warm = stride(from: 0, to: withSpeck.count, by: 4).filter { withSpeck[$0] > 200 && withSpeck[$0 + 2] < 190 && closed[$0] < 40 }.count
        XCTAssertGreaterThan(warm, 20, "a small warm dot, beside the cat")
        chased.moteSize = 0
        XCTAssertEqual(drawNew(chased), closed, "a speck of no size is not drawn")
    }

    func testPaintingIsRepeatableAndLeavesTheContextAsItFoundIt() {
        let pose = PetAnimation.groom(u: 1.4, time: 3)
        XCTAssertEqual(drawNew(pose, look: PetLook(coat: .ginger, accessory: .collar)), drawNew(pose, look: PetLook(coat: .ginger, accessory: .collar)))
        let cg = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)); cg.setStrokeColor(CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)); cg.setLineWidth(7); cg.setAlpha(0.5)
        // What the context paints with before and after: a patch of fill, and a stroke.
        func probe(at x: CGFloat) -> [UInt8] {
            cg.fill(CGRect(x: x, y: 80, width: 6, height: 6))
            cg.move(to: CGPoint(x: x, y: 92)); cg.addLine(to: CGPoint(x: x + 6, y: 92)); cg.strokePath()
            let data = cg.data!.bindMemory(to: UInt8.self, capacity: 100 * 100 * 4)
            let row = { (y: Int, x: Int) -> [UInt8] in (0..<4).map { data[((99 - y) * 100 + x) * 4 + $0] } }
            return row(83, Int(x) + 3) + row(92, Int(x) + 3)
        }
        let before = probe(at: 4)
        let transform = cg.ctm, clip = cg.boundingBoxOfClipPath
        PetPainter.draw(PetAnimation.celebrate(u: 0.8, time: 1), look: PetLook(coat: .tabby, accessory: .glasses), ledge: -5, in: cg)
        XCTAssertEqual(cg.ctm, transform, "the transform is back where it was")
        XCTAssertEqual(cg.boundingBoxOfClipPath, clip, "the ledge's clip does not outlive the frame")
        XCTAssertEqual(probe(at: 40), before, "the fill, the stroke, the line width and the alpha are as they were")
    }

    func testTheWingKeepsTheCatInsideTheIsland() {
        let bounds = NSRect(x: 0, y: 0, width: 246, height: 32)
        let w = 80, h = 64
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.scaleBy(x: 2, y: 2)
        PetWing.draw(PetAnimation.peek(u: 1.4, time: 2, ledge: PetStage.compact(height: 32).ledge), bounds: bounds, in: cg)
        let data = cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // The island's bottom-left corner is rounded: outside its curve (the image's last row, first pixel) nothing is painted, cat or island.
        XCTAssertEqual(data[(h - 1) * w * 4 + 3], 0, "outside the island's corner nothing is painted (alpha)")
        XCTAssertEqual(data[3], 255, "the island's square top corner is black")
        XCTAssertEqual(PetWing.islandPath(bounds), PetWing.islandPath(bounds), "the path is the cached one")
        XCTAssertTrue(PetWing.islandPath(bounds).contains(CGPoint(x: 100, y: 16)))
        XCTAssertFalse(PetWing.islandPath(bounds).contains(CGPoint(x: 1, y: 1)), "the corner is rounded")
    }

    // MARK: Cost

    /// What a frame costs to paint, against the old painter: it builds nothing per frame, so it is quicker even in a debug build (which
    /// is the slowest the code ever runs).
    func testPaintingCostsLessThanTheOldPainter() {
        let frames = PetSim.compactPoses(step: 0.2).prefix(300)
        let list = Array(frames)
        let w = 80, h = 64
        func run(_ paint: (PetPose, CGContext) -> Void) -> Double {
            let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.scaleBy(x: 2, y: 2); cg.translateBy(x: 20, y: 7); cg.scaleBy(x: 0.6, y: 0.6)
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            for p in list.prefix(50) { paint(p, cg) }
            let start = Date()
            for _ in 0..<6 { for p in list { paint(p, cg) } }
            return Date().timeIntervalSince(start) / Double(6 * list.count) * 1e6
        }
        let new = run { PetPainter.draw($0, in: $1) }
        let old = run { p, _ in LegacyPetPainter.draw(p, color: .white) }
        print("painting a frame: \(String(format: "%.1f", new)) us now, \(String(format: "%.1f", old)) us before (debug build, 40 x 32 pt at 2x)")
        XCTAssertLessThan(new, old * 0.85, "the new painter is quicker than the old one")
    }

    // MARK: The header repaints only where the cat is

    func testRepaintingOnlyTheHeaderCatsRectGivesTheVeryPictureOfRepaintingTheWholeStage() {
        // The header's cat repaints where it was and where it is now (`HeaderPetView.paintedRect`), not its whole stage. Any part of it
        // painted outside that rect would be left behind as a trail; so for every frame of every gesture, dressed in what reaches
        // furthest, a partial repaint over the frame before must give the same pixels as painting the new frame on a clear stage.
        let ppp: CGFloat = 2, size = CGSize(width: 164, height: 32), scale: CGFloat = 0.5
        let w = Int(size.width * ppp), h = Int(size.height * ppp)
        func stage() -> CGContext {
            let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.scaleBy(x: ppp, y: ppp)
            return cg
        }
        func bytes(_ cg: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4), count: w * h * 4)) }
        var poses: [PetPose] = []
        for kind in PetDirector.Kind.allCases where kind != .home {
            poses += PetSim.gesture(kind, in: PetRender.header, extra: 0.3, fps: 10)
        }
        for style in [PetCheer.hop, .doubleHop, .content] {
            poses += stride(from: 0, through: PetAnimation.cheerLength(style), by: 0.1).map { PetAnimation.celebrate(u: $0, time: $0, style: style) }
        }
        poses += stride(from: 0.0, through: 2, by: 0.1).map { PetAnimation.perked(from: PetAnimation.sit(time: $0), time: $0, amount: 1, age: $0) }
        poses += stride(from: 0.0, through: 2, by: 0.1).map { PetAnimation.curious(PetAnimation.sit(time: $0), gaze: PetGaze(dx: 1, dy: -1), amount: 1, age: $0) }
        XCTAssertGreaterThan(poses.count, 600)
        var compared = 0, worst = (pixels: 0, at: -1)
        for look in [PetLook(coat: .tabby, accessory: .collar), PetLook(coat: .ginger, accessory: .bow), PetLook(accessory: .glasses)] {
            for (i, (old, new)) in zip(poses, poses.dropFirst()).enumerated() where old != new {
                let rect = HeaderPetView.paintedRect(old, scale: scale).union(HeaderPetView.paintedRect(new, scale: scale))
                // AppKit repaints whole device pixels: the dirty rect is widened to them.
                let dirty = CGRect(x: rect.minX * ppp, y: rect.minY * ppp, width: rect.width * ppp, height: rect.height * ppp).integral
                let partial = stage()
                HeaderPetView.paint(old, look: look, scale: scale, in: partial)
                partial.saveGState()
                partial.clip(to: CGRect(x: dirty.minX / ppp, y: dirty.minY / ppp, width: dirty.width / ppp, height: dirty.height / ppp))
                partial.clear(CGRect(origin: .zero, size: size))
                HeaderPetView.paint(new, look: look, scale: scale, in: partial)
                partial.restoreGState()
                let full = stage()
                HeaderPetView.paint(new, look: look, scale: scale, in: full)
                let a = bytes(partial), b = bytes(full)
                var differing = 0
                for k in stride(from: 0, to: a.count, by: 4) where a[k] != b[k] || a[k + 3] != b[k + 3] { differing += 1 }
                if differing > worst.pixels { worst = (differing, i) }
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 1500)
        XCTAssertEqual(worst.pixels, 0, "frame \(worst.at) left \(worst.pixels) pixels of the frame before behind")
    }
}
