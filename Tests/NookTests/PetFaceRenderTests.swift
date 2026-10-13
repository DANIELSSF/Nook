import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Frames where several layers turn the cat's face at once, as the big cats show them: the pointer far to one side (curious) over
/// the mew of a click (the perk) and a glance of the cat's own (`PetLife`). They are the frames where the eyes used to run into
/// the mouth and the ears used to flare at their bases.
enum PetFaceScenes {
    /// The moment of the cat's own glance (`PetLife`) at its fullest toward `side` (-1 left, 1 right), found on the clock the way the
    /// player meets it.
    static func glanceTime(toward side: CGFloat) -> Double {
        var best = (t: 0.0, x: CGFloat(0))
        var t = 0.0
        while t < 400 {
            var p = PetPose()
            PetLife.apply(&p, PetLife.Context(time: t))
            if p.look.x * side > best.x, abs(p.look.y) < 0.6, p.eyes > 0.95 { best = (t, p.look.x * side) }
            t += 0.05
        }
        return best.t
    }

    /// The layers in the director's and the player's order: the sit, a click's perk at the top of its mew (`mew`), the pointer's
    /// pull (`gaze`, nil for none) and the cat's own glance toward `glance` (0 for none).
    static func stacked(gaze: PetGaze?, mew: Bool = true, glance: CGFloat = 0, base: PetPose? = nil) -> PetPose {
        let t = glance == 0 ? 1000 : glanceTime(toward: glance)
        var p = base ?? PetAnimation.sit(time: t)
        // The mew is at its widest 0.45 s into the perk.
        if mew { p = PetAnimation.perked(from: p, time: t, amount: 1, age: 0.45) }
        if let gaze { p = PetAnimation.curious(p, gaze: gaze, amount: 1, age: 2.0) }
        PetLife.apply(&p, PetLife.Context(time: glance == 0 ? 1000.37 : t))
        return p
    }

    /// The frame Daniel saw on the greeting: the pointer off to the right and a little below the cat's head, a click's mew, and a
    /// glance of its own the same way.
    static var greetingToTheSide: PetPose { stacked(gaze: PetGaze(dx: 1, dy: -0.6), mew: true, glance: 1) }

    /// The states that stack layers, named.
    static var states: [(String, PetPose)] {
        [
            ("sit", PetAnimation.sit(time: 3)),
            ("left", stacked(gaze: PetGaze(dx: -1, dy: 0), mew: false)),
            ("right", stacked(gaze: PetGaze(dx: 1, dy: 0), mew: false)),
            ("above", stacked(gaze: PetGaze(dx: 0.1, dy: 1), mew: false)),
            ("below", stacked(gaze: PetGaze(dx: -0.1, dy: -1), mew: false)),
            ("perk", stacked(gaze: nil, mew: true)),
            ("right-low-mew", stacked(gaze: PetGaze(dx: 1, dy: -0.6), mew: true)),
            ("left-low-mew", stacked(gaze: PetGaze(dx: -1, dy: -0.6), mew: true)),
            ("right-mew-glance", greetingToTheSide),
            ("left-mew-glance", stacked(gaze: PetGaze(dx: -1, dy: -0.6), mew: true, glance: -1)),
            ("above-mew-glance", stacked(gaze: PetGaze(dx: 0.6, dy: 1), mew: true, glance: 1)),
            ("yawn-glance", stacked(gaze: nil, mew: false, glance: 1, base: PetAnimation.yawn(u: 1.6, time: glanceTime(toward: 1)))),
            ("wave-right", stacked(gaze: PetGaze(dx: 1, dy: 0.3), mew: false, base: PetAnimation.wave(time: 0.3, amount: 1))),
            ("sad", PetAnimation.sad(time: 2.5)),
        ]
    }
}

/// The big cats' faces in the frames that stack layers, drawn to PNG for review (set NOOK_RENDER_DIR): `face-*.png`.
@MainActor
final class PetFaceRenderTests: XCTestCase {
    private func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the cat's face.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    /// The cat on a black stage of `size` points, its home half way across and its feet on the home's ground, at `ppp` pixels per point.
    private func stage(_ pose: PetPose, look: PetLook = PetLook(), size: CGSize = CGSize(width: 120, height: 104), ppp: CGFloat = 3, caption: String? = nil) -> CGImage {
        let scale = HomeMetrics.scale(stage: size, homeFraction: 0.5)
        let width = Int(size.width * ppp), height = Int(size.height * ppp)
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.scaleBy(x: ppp, y: ppp)
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        HomePetView.paint(pose, look: look, scale: scale, homeX: size.width / 2, in: cg)
        if let caption {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 7, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
            (caption as NSString).draw(at: CGPoint(x: 4, y: size.height - 11), withAttributes: attributes)
        }
        return cg.makeImage()!
    }

    /// Daniel's frame: the greeting, its cat turned to the pointer off to the right with a mew and a glance of its own. The whole
    /// greeting as the island shows it (`face-greeting-side.png`), and its stage zoomed (`face-greeting-side-zoom.png`).
    func testRenderTheGreetingWithThePointerToOneSide() throws {
        let directory = try renderDirectory()
        let name = "nook-face-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        model.neckWithoutWindow = 32
        model.display.theme = .dark
        model.pet.coat = .ginger; model.pet.accessory = .collar
        model.expanded = true; model.islandContentVisible = true
        let pose = PetFaceScenes.greetingToTheSide
        let host = NSHostingView(rootView: GreetingView(model: model, staticCat: pose).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.nookFlatGlass, true))
        host.frame = NSRect(origin: .zero, size: model.islandSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("face-greeting-side.png"))
        // The greeting's stage at the size it has in the default island, four pixels a point.
        let zoomed = stage(pose, look: model.pet.look, size: CGSize(width: 179, height: 160), ppp: 4)
        try PetRender.writePNG(zoomed, to: directory.appendingPathComponent("face-greeting-side-zoom.png"))
    }

    /// Every state that stacks layers, in the snow coat, and the stacked ones in every coat and accessory (the glasses on the eyes,
    /// the collar and the bow under the chin).
    func testRenderTheFaceInEveryStackedState() throws {
        let directory = try renderDirectory()
        let states = PetFaceScenes.states
        try PetRender.writePNG(PetRender.sheet(states.map { stage($0.1, caption: $0.0) }, columns: 7), to: directory.appendingPathComponent("face-states.png"))
        let stacked = states.filter { ["right-low-mew", "right-mew-glance", "left-mew-glance", "above-mew-glance", "below"].contains($0.0) }
        for coat in PetCoat.allCases {
            var tiles: [CGImage] = []
            for (name, pose) in stacked {
                for accessory in PetAccessory.allCases { tiles.append(stage(pose, look: PetLook(coat: coat, accessory: accessory), size: CGSize(width: 96, height: 92), caption: "\(name) \(accessory)")) }
            }
            try PetRender.writePNG(PetRender.sheet(tiles, columns: PetAccessory.allCases.count), to: directory.appendingPathComponent("face-coat-\(coat).png"))
        }
    }

    /// The home's cat as the player draws it, with the pointer held far to each side and a click at 0.5 s: its follow-through and
    /// its own small life over the director's layers, a frame every tenth of a second.
    func testRenderThePlayerWithThePointerAndAClick() throws {
        let directory = try renderDirectory()
        for (name, gaze) in [("right", PetGaze(dx: 1, dy: -0.5)), ("left", PetGaze(dx: -1, dy: -0.5)), ("above", PetGaze(dx: 0.3, dy: 1)), ("below", PetGaze(dx: -0.3, dy: -1))] {
            let frames = PetSim.run(.header(travel: 40, scale: 3, height: 104), seconds: 2.4, fps: 30, seed: 2, input: { t in
                var input = PetInput(gaze: gaze, idle: 2)
                if t >= 0.5 { let age = t - 0.5; input.perk = PetAnimation.ramp(age, 0, 0.12) * (1 - PetAnimation.ramp(age, 0.9, 1.5)); input.perkAge = age }
                return input
            })
            let picked = stride(from: 0, to: frames.count, by: 3).map { frames[$0] }
            try PetRender.writePNG(PetRender.sheet(picked.map { stage($0.pose, look: PetLook(coat: .ginger, accessory: .collar), size: CGSize(width: 96, height: 92), ppp: 2, caption: String(format: "%.1f", $0.t)) }, columns: 9),
                                   to: directory.appendingPathComponent("face-player-\(name).png"))
        }
    }
}
