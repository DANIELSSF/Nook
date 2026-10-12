import AppKit
import ImageIO
import UniformTypeIdentifiers
#if !PETLAB
@testable import Nook
#endif

/// Draws the cat to images: contact sheets of frames (real size and zoomed) and animated GIFs, for reviewing the gestures by eye. It
/// holds no assertions, so a scratch tool can use it too; the tests that call it live in `PetRenderTests`.
enum PetRender {
    /// Where the cat is drawn: the collapsed island's left wing, or the expanded header's stage.
    enum Stage {
        case compact(height: CGFloat)
        case header(width: CGFloat, height: CGFloat)
    }

    /// The part of the desktop around the stage, so the island's own edge is visible.
    static let compactCanvas = (width: CGFloat(56), margin: CGFloat(8))
    static let headerCanvas = (tabs: CGFloat(22), margin: CGFloat(0))
    /// Frames a second of the films: the cat's own top rate.
    static let fps = 30.0

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
    static func image(_ pose: PetPose, stage: Stage, ppp: CGFloat, look: PetLook = PetLook(), caption: String? = nil, crop: CGRect? = nil, extra: ((CGContext) -> Void)? = nil) -> CGImage {
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
            PetPainter.draw(pose, look: look, ledge: place.ledge)
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
            PetPainter.draw(pose, look: look, ledge: place.ledge)
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

    struct WriteError: Error, CustomStringConvertible { var description: String }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw WriteError(description: "could not open \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError(description: "could not write \(url.lastPathComponent)") }
    }

    /// An endlessly looping GIF; `holdLast` seconds of stillness at the end so the loop point reads.
    static func writeGIF(_ frames: [CGImage], fps: Double, holdLast: Double = 0.6, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { throw WriteError(description: "could not open \(url.lastPathComponent)") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        for (i, frame) in frames.enumerated() {
            let delay = i == frames.count - 1 ? max(1 / fps, holdLast) : 1 / fps
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw WriteError(description: "could not write \(url.lastPathComponent)") }
    }

    // MARK: Films

    static let notched = Stage.compact(height: 32), flat = Stage.compact(height: 28)
    static let header = Stage.header(width: 164, height: 32)
    static func crop(_ stage: Stage, width: CGFloat) -> CGRect {
        let size = size(stage)
        return CGRect(x: 0, y: 0, width: min(width, size.width), height: size.height)
    }

    /// Writes the review images of one gesture: real-size and zoomed contact sheets for the collapsed island (notch and flat
    /// screens) and the expanded header, and a GIF of each at about three times the Retina size. `poses` returns the frames
    /// (`fps` a second) for a stage; `every` is the seconds between the frames the sheets pick.
    static func film(_ name: String, to directory: URL, header showHeader: Bool = true, headerWidth: CGFloat = 70, every: Double = 0.1, compactOnly: Bool = false,
                     look: PetLook = PetLook(), gif: Bool = true, _ poses: (Stage) -> [PetPose]) throws {
        var cases: [(String, Stage, CGFloat)] = [("compact", notched, 46)]
        if !compactOnly { cases.append(("compact-flat", flat, 46)) }
        if showHeader { cases.append(("header", header, headerWidth)) }
        for (label, stage, width) in cases {
            let crop = crop(stage, width: width)
            let frames = poses(stage)
            let step = max(1, Int((every * fps).rounded()))
            func images(_ indices: [Int], ppp: CGFloat, captions: Bool) -> [CGImage] {
                indices.map { image(frames[$0], stage: stage, ppp: ppp, look: look, caption: captions ? String(format: "%.2f", Double($0) / fps) : nil, crop: crop) }
            }
            let picked = Array(stride(from: 0, to: frames.count, by: step))
            let columns = label == "header" ? (width > 100 ? 2 : 4) : 6
            try writePNG(sheet(images(picked, ppp: 2, captions: false), columns: min(picked.count, 16), gap: 2), to: directory.appendingPathComponent("\(name)-\(label)-real.png"))
            try writePNG(sheet(images(picked, ppp: width > 100 ? 4 : 7, captions: true), columns: columns), to: directory.appendingPathComponent("\(name)-\(label)-zoom.png"))
            if gif, label != "compact-flat" {
                try writeGIF(images(Array(frames.indices), ppp: label == "header" ? (width > 100 ? 4 : 5) : 6, captions: false), fps: fps, to: directory.appendingPathComponent("\(name)-\(label).gif"))
            }
        }
    }

    /// Every frame of `seconds` at the film rate from a gesture sampled directly.
    static func sample(_ seconds: Double, _ pose: (Double) -> PetPose) -> [PetPose] {
        stride(from: 0, through: seconds + 1e-9, by: 1.0 / fps).map(pose)
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
