import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Nook

/// Draws the cat to images: contact sheets of frames (real size and zoomed) and animated GIFs, for reviewing the
/// gestures by eye. Nothing here runs unless NOOK_RENDER_DIR is set.
enum PetRender {
    /// Where the cat is drawn: the collapsed island's left wing, or the expanded header's stage.
    enum Stage {
        case compact(height: CGFloat)
        case header(width: CGFloat, height: CGFloat)
    }

    /// The part of the desktop around the stage, so the island's own edge is visible.
    static let compactCanvas = (width: CGFloat(56), margin: CGFloat(8))
    static let headerCanvas = (tabs: CGFloat(22), margin: CGFloat(0))

    static func size(_ stage: Stage) -> CGSize {
        switch stage {
        case .compact(let height): CGSize(width: compactCanvas.width, height: height + compactCanvas.margin)
        case .header(let width, let height): CGSize(width: width, height: height + headerCanvas.tabs)
        }
    }

    /// The rig-to-points transform of the cat inside the canvas (bottom-left origin).
    static func placement(_ stage: Stage, pose: PetPose) -> (origin: CGPoint, scale: CGFloat, ledge: CGFloat) {
        switch stage {
        case .compact(let height):
            let ground = height / 2 - 9
            return (CGPoint(x: PetAnimation.compactAnchor + pose.x, y: compactCanvas.margin + ground), PetAnimation.compactScale, -ground / PetAnimation.compactScale)
        case .header(let width, let height):
            let scale = min(0.5, max(0.3, (height - 15.5) / 31.5))
            _ = width
            return (CGPoint(x: HeaderPetView.homeX + pose.x, y: headerCanvas.tabs + HeaderPetView.ground), scale, -HeaderPetView.ground / scale)
        }
    }

    /// One frame at `ppp` pixels per point.
    static func image(_ pose: PetPose, stage: Stage, ppp: CGFloat, caption: String? = nil, crop: CGRect? = nil, extra: ((CGContext) -> Void)? = nil) -> CGImage {
        let points = size(stage)
        let width = Int(points.width * ppp), height = Int(points.height * ppp)
        let space = CGColorSpaceCreateDeviceRGB()
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.interpolationQuality = .high
        cg.scaleBy(x: ppp, y: ppp)
        let ns = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = ns
        switch stage {
        case .compact(let height):
            // Desktop, then the island: square top, rounded bottom-left corner, running off to the right.
            NSColor(red: 0.2, green: 0.26, blue: 0.36, alpha: 1).setFill(); NSRect(origin: .zero, size: points).fill()
            let island = NSBezierPath()
            let top = points.height, bottom = compactCanvas.margin
            island.move(to: CGPoint(x: 0, y: top)); island.line(to: CGPoint(x: points.width, y: top)); island.line(to: CGPoint(x: points.width, y: bottom))
            island.line(to: CGPoint(x: 10, y: bottom)); island.curve(to: CGPoint(x: 0, y: bottom + 10), controlPoint1: CGPoint(x: 4, y: bottom), controlPoint2: CGPoint(x: 0, y: bottom + 4))
            island.close()
            NSColor.black.setFill(); island.fill()
            _ = height
            let place = placement(stage, pose: pose)
            cg.saveGState()
            island.addClip()
            cg.translateBy(x: place.origin.x, y: place.origin.y); cg.scaleBy(x: place.scale, y: place.scale)
            PetAnimation.draw(pose, color: .white, ledge: place.ledge)
            cg.restoreGState()
        case .header(let width, let height):
            NSColor.black.setFill(); NSRect(origin: .zero, size: points).fill()
            // Two tab chips under the stage, where the tab row sits in the panel.
            NSColor.white.withAlphaComponent(0.1).setFill()
            for x in [CGFloat(12), 78] { NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 58, height: 15), xRadius: 7, yRadius: 7).fill() }
            let stage = NSRect(x: 0, y: headerCanvas.tabs, width: width, height: height)
            let place = placement(.header(width: width, height: height), pose: pose)
            cg.saveGState()
            cg.clip(to: stage)
            cg.translateBy(x: place.origin.x, y: place.origin.y); cg.scaleBy(x: place.scale, y: place.scale)
            PetAnimation.draw(pose, color: .white, ledge: place.ledge)
            cg.restoreGState()
        }
        extra?(cg)
        if let caption {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 2.6, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
            (caption as NSString).draw(at: CGPoint(x: 1.5, y: 0.8), withAttributes: attributes)
        }
        let full = cg.makeImage()!
        guard let crop else { return full }
        // `crop` is in points with a bottom-left origin; CGImage cropping is top-left.
        let rect = CGRect(x: crop.minX * ppp, y: CGFloat(height) - crop.maxY * ppp, width: crop.width * ppp, height: crop.height * ppp)
        return full.cropping(to: rect) ?? full
    }

    /// Frames side by side, wrapping after `columns`, on a neutral gap colour.
    static func sheet(_ frames: [CGImage], columns: Int, gap: Int = 6) -> CGImage {
        let w = frames.map(\.width).max() ?? 1, h = frames.map(\.height).max() ?? 1
        let rows = (frames.count + columns - 1) / columns
        let width = columns * w + (columns + 1) * gap, height = rows * h + (rows + 1) * gap
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (i, frame) in frames.enumerated() {
            let row = i / columns, column = i % columns
            cg.draw(frame, in: CGRect(x: gap + column * (w + gap), y: height - (row + 1) * (h + gap), width: frame.width, height: frame.height))
        }
        return cg.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write \(url.lastPathComponent)")
    }

    /// An endlessly looping GIF; `holdLast` seconds of stillness at the end so the loop point reads.
    static func writeGIF(_ frames: [CGImage], fps: Double, holdLast: Double = 0.6, to url: URL) {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for (i, frame) in frames.enumerated() {
            let delay = i == frames.count - 1 ? max(1 / fps, holdLast) : 1 / fps
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write \(url.lastPathComponent)")
    }
}

extension PetRender.Stage {
    /// The player's layout for this stage, as the views would compute it.
    var layout: PetPlayer.Layout {
        switch self {
        case .compact(let height): return .compact(height: height)
        case .header(let width, let height):
            let scale = min(0.5, max(0.3, (height - 15.5) / 31.5))
            return .header(travel: max(0, width - HeaderPetView.homeX - PetAnimation.reach.right * scale - 4), scale: scale, height: height)
        }
    }
    var isHeader: Bool { if case .header = self { return true } else { return false } }
}

@MainActor
final class PetRenderTests: XCTestCase {
    func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the cat.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    static let notched = PetRender.Stage.compact(height: 32), flat = PetRender.Stage.compact(height: 28)
    static let header = PetRender.Stage.header(width: 164, height: 32)
    static func crop(_ stage: PetRender.Stage, width: CGFloat) -> CGRect {
        let size = PetRender.size(stage)
        return CGRect(x: 0, y: 0, width: min(width, size.width), height: size.height)
    }

    /// Writes the review images of one gesture: real-size and zoomed contact sheets for the collapsed island (notch and
    /// flat screens) and the expanded header, and a GIF of each at about three times the Retina size.
    /// `poses` returns the frames (24 a second) for a stage.
    func film(_ name: String, header: Bool = true, headerWidth: CGFloat = 70, every: Double = 0.1, compactOnly: Bool = false, _ poses: (PetRender.Stage) -> [PetPose]) throws {
        let directory = try renderDirectory()
        var cases: [(String, PetRender.Stage, CGFloat)] = [("compact", Self.notched, 46)]
        if !compactOnly { cases.append(("compact-flat", Self.flat, 46)) }
        if header { cases.append(("header", Self.header, headerWidth)) }
        for (label, stage, width) in cases {
            let crop = Self.crop(stage, width: width)
            let frames = poses(stage)
            let step = max(1, Int((every * 24).rounded()))
            func images(_ indices: [Int], ppp: CGFloat, captions: Bool) -> [CGImage] {
                indices.map { PetRender.image(frames[$0], stage: stage, ppp: ppp, caption: captions ? String(format: "%.2f", Double($0) / 24) : nil, crop: crop) }
            }
            let picked = Array(stride(from: 0, to: frames.count, by: step))
            let columns = label == "header" ? (width > 100 ? 2 : 4) : 6
            try PetRender.writePNG(PetRender.sheet(images(picked, ppp: 2, captions: false), columns: min(picked.count, 16), gap: 2), to: directory.appendingPathComponent("\(name)-\(label)-real.png"))
            try PetRender.writePNG(PetRender.sheet(images(picked, ppp: width > 100 ? 4 : 7, captions: true), columns: columns), to: directory.appendingPathComponent("\(name)-\(label)-zoom.png"))
            if label != "compact-flat" {
                PetRender.writeGIF(images(Array(frames.indices), ppp: label == "header" ? (width > 100 ? 4 : 5) : 6, captions: false), fps: 24, to: directory.appendingPathComponent("\(name)-\(label).gif"))
            }
        }
    }

    /// Every frame of `seconds` at 24 a second from a gesture sampled directly.
    func sample(_ seconds: Double, _ pose: (Double) -> PetPose) -> [PetPose] {
        stride(from: 0, through: seconds + 1e-9, by: 1.0 / 24).map(pose)
    }

    func testRenderGestures() throws {
        try film("groom") { _ in self.sample(PetAnimation.groomLength) { PetAnimation.groom(u: $0, time: 3) } }
        try film("celebrate") { _ in self.sample(PetAnimation.celebrateLength) { PetAnimation.celebrate(u: $0, time: 3) } }
        try film("land", header: true, compactOnly: true) { _ in self.sample(PetAnimation.landLength) { PetAnimation.land(u: $0, time: 3) } }
        try film("peek", every: 0.2) { stage in
            let ledge = PetRender.placement(stage, pose: PetPose()).ledge
            return self.sample(PetAnimation.peekLength) { PetAnimation.peek(u: $0, time: 3, ledge: ledge, shift: stage.isHeader ? 2 : 3.5) }
        }
    }

    /// The cat noticing a pointer: it appears at 0.3 s up and to the right, stays, and leaves at 2.8 s.
    func testRenderCurious() throws {
        for (name, gaze) in [("curious-right", PetGaze(dx: 0.9, dy: 0.3)), ("curious-left", PetGaze(dx: -0.9, dy: -0.2)), ("curious-above", PetGaze(dx: 0.05, dy: 1))] {
            try film(name, headerWidth: 70, every: 0.12) { stage in
                PetSim.run(stage.layout, seconds: 4, fps: 24, seed: 2) { t in PetInput(gaze: t > 0.3 && t < 2.8 ? gaze : nil) }.map(\.pose)
            }
        }
    }

    /// Transitions: sitting down into a nap and waking, stretching, playing, a stroll out and back, all between sits.
    func testRenderTransitions() throws {
        for (name, kind, seconds, compact) in [("nap", PetDirector.Kind.nap, 14.0, true), ("stretch", .stretch, 5.6, true), ("play", .play, 6.4, true), ("wave", .wave, 3.4, true)] {
            try film("transition-" + name, header: true, every: seconds > 8 ? 0.5 : 0.25, compactOnly: compact) { stage in
                PetSim.run(stage.layout, seconds: seconds, fps: 24, before: { $0.begin(kind, layout: stage.layout) }, input: { _ in PetInput(idle: 300) }).map(\.pose)
            }
        }
        // A stroll in the header, followed by a window that tracks the cat: setting off, the middle of the walk, arriving.
        let header = Self.header
        let stroll = PetSim.run(header.layout, seconds: 24, fps: 24, before: { $0.begin(.stroll, layout: header.layout) })
        let directory = try renderDirectory()
        let frames = stroll.map(\.pose)
        func following(_ pose: PetPose) -> CGRect { CGRect(x: max(0, HeaderPetView.homeX + pose.x - 26), y: 0, width: 58, height: PetRender.size(header).height) }
        func sheet(_ name: String, _ range: ClosedRange<Double>, step: Double) throws {
            let indices = stride(from: Int(range.lowerBound * 24), through: Int(range.upperBound * 24), by: max(1, Int(step * 24))).filter { $0 < frames.count }
            let images = indices.map { PetRender.image(frames[$0], stage: header, ppp: 6, caption: String(format: "%.2f", Double($0) / 24), crop: following(frames[$0])) }
            try PetRender.writePNG(PetRender.sheet(images, columns: 6), to: directory.appendingPathComponent("transition-stroll-\(name).png"))
        }
        try sheet("start", 0...2.2, step: 0.1)
        try sheet("middle", 6...7.2, step: 0.1)
        try sheet("arrive", 7.6...10.2, step: 0.1)
        PetRender.writeGIF(frames.indices.map { PetRender.image(frames[$0], stage: header, ppp: 4, crop: CGRect(x: 0, y: 0, width: 164, height: PetRender.size(header).height)) }, fps: 24, to: directory.appendingPathComponent("transition-stroll-header.gif"))
    }

    /// The still poses the cat shows when it must not move (Reduce Motion, animations off): calm, working, a notice waiting.
    func testRenderStaticPoses() throws {
        let directory = try renderDirectory()
        let poses = [PetAnimation.staticPose(working: false, attention: false), PetAnimation.staticPose(working: true, attention: false), PetAnimation.staticPose(working: false, attention: true)]
        var images: [CGImage] = []
        for stage in [Self.notched, Self.header] {
            let crop = Self.crop(stage, width: 46)
            images += poses.map { PetRender.image($0, stage: stage, ppp: 6, crop: crop) }
        }
        try PetRender.writePNG(PetRender.sheet(images, columns: 3), to: directory.appendingPathComponent("static-poses.png"))
        try PetRender.writePNG(PetRender.sheet(poses.map { PetRender.image($0, stage: Self.notched, ppp: 2, crop: Self.crop(Self.notched, width: 46)) }, columns: 3, gap: 2), to: directory.appendingPathComponent("static-poses-real.png"))
    }

    /// A task finishes while the island is collapsed: the alert's peek makes the cat look up and toward the bell; once that
    /// settles, a single hop. The alert's own timeline drives the cat's reaction, as in the app.
    func testRenderAFinishedTaskAsTheAppSeesIt() throws {
        let alert = NookAlert(id: 1, sessionID: "a", kind: .finished, title: "api", message: "Claude terminó.")
        var timeline = AlertPeekTimeline()
        timeline.begin(alert, now: 0, motion: true)
        try film("finish-with-alert", header: false, every: 0.25, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 7, fps: 24, input: { t in
                PetInput(perk: timeline.perk(at: t), perkAge: t, completions: t > 0.05 ? 1 : 0)
            }).map(\.pose)
        }
        // The same finish while the island is open: no alert, the header cat hops at once.
        try film("finish-in-header", compactOnly: false) { stage in
            PetSim.run(stage.layout, seconds: 3, fps: 24, input: { t in PetInput(completions: t > 0.1 ? 1 : 0) }).map(\.pose)
        }
    }

    /// Interruptions: a grooming cat that the pointer approaches, a peek cut short by an alert, a nap that ends when the user
    /// comes back, a drag taking over, and a stroll stopped halfway that walks home afterwards.
    func testRenderInterruptions() throws {
        try film("interrupt-groom-by-pointer", header: false, every: 0.15, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 5, fps: 24, before: { $0.begin(.groom, layout: stage.layout) }, input: { t in PetInput(gaze: t > 1.2 && t < 3.6 ? PetSim.pointer : nil) }).map(\.pose)
        }
        try film("interrupt-peek-by-alert", header: false, every: 0.2, compactOnly: true) { stage in
            var timeline = AlertPeekTimeline()
            timeline.begin(NookAlert(id: 2, sessionID: "a", kind: .question, title: "api", message: "?"), now: 3, motion: true)
            return PetSim.run(stage.layout, seconds: 7, fps: 24, before: { $0.begin(.peek, layout: stage.layout) }, input: { t in PetInput(perk: timeline.perk(at: t), perkAge: max(0, t - 3)) }).map(\.pose)
        }
        try film("interrupt-nap-by-user", header: false, every: 0.4, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 14, fps: 24, before: { $0.begin(.nap, layout: stage.layout) }, input: { t in PetInput(idle: t < 9 ? 400 : 0) }).map(\.pose)
        }
        try film("interrupt-by-drag", header: false, every: 0.1, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 3, fps: 24, before: { $0.begin(.stretch, layout: stage.layout) }, input: { t in PetInput(gaze: t > 1.5 ? PetSim.pointer : nil, dragging: t > 1.5) }).map(\.pose)
        }
        // Header: a stroll stopped by the pointer, then the walk home.
        let header = Self.header
        let frames = PetSim.run(header.layout, seconds: 30, fps: 24, before: { $0.begin(.stroll, layout: header.layout) }, input: { t in PetInput(gaze: t > 5 && t < 8 ? PetSim.pointer : nil) }).map(\.pose)
        let directory = try renderDirectory()
        PetRender.writeGIF(frames.indices.map { PetRender.image(frames[$0], stage: header, ppp: 4, crop: CGRect(x: 0, y: 0, width: 164, height: PetRender.size(header).height)) }, fps: 24, to: directory.appendingPathComponent("interrupt-stroll-header.gif"))
    }

    /// Put down after a drag: drops in from above, squashes, settles.
    func testRenderLandingAfterADrag() throws {
        try film("landing-after-drag", compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 1.8, fps: 24, before: { $0.land() }).map(\.pose)
        }
    }

    /// One image with a row per gesture (collapsed island, zoomed), as the quick look at everything the cat can do.
    func testRenderGallery() throws {
        let directory = try renderDirectory()
        let stage = Self.notched, layout = stage.layout
        func row(_ title: String, count: Int = 10, _ poses: [PetPose]) -> [CGImage] {
            let picks = (0..<count).map { poses[min(poses.count - 1, $0 * (poses.count - 1) / max(1, count - 1))] }
            return picks.enumerated().map { PetRender.image($1, stage: stage, ppp: 4, caption: $0 == 0 ? title : nil, crop: Self.crop(stage, width: 46)) }
        }
        let sit = PetAnimation.sit(time: 3)
        let curious = (0..<48).map { PetAnimation.curious(sit, gaze: PetGaze(dx: 0.9, dy: 0.3), amount: 1, age: Double($0) / 24 * 1.4) }
        let groom = sample(PetAnimation.groomLength) { PetAnimation.groom(u: $0, time: 3) }
        let glance = sample(PetAnimation.glanceLength) { PetAnimation.glance(u: $0, time: 3) }
        let peek = sample(PetAnimation.peekLength) { PetAnimation.peek(u: $0, time: 3, ledge: PetRender.placement(stage, pose: PetPose()).ledge) }
        let celebrate = sample(PetAnimation.celebrateLength) { PetAnimation.celebrate(u: $0, time: 3) }
        let land = sample(PetAnimation.landLength) { PetAnimation.land(u: $0, time: 3) }
        let rows = [row("curiosidad", curious), row("aseo", groom), row("mirada", glance), row("asomarse", peek), row("celebracion", celebrate), row("aterrizaje", land)]
        try PetRender.writePNG(PetRender.sheet(rows.flatMap { $0 }, columns: 10, gap: 3), to: directory.appendingPathComponent("gallery-gestures.png"))
    }
}
