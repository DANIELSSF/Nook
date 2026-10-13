import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Draws the cat to images: contact sheets of frames (real size and zoomed) and animated GIFs of every gesture, for reviewing them by
/// eye; and the settings card's tab for the cat. Nothing here runs unless NOOK_RENDER_DIR is set. The drawing itself is `PetRender`
/// (`PetRenderKit.swift`), which has no assertions so a scratch tool can use it too.
@MainActor
final class PetRenderTests: XCTestCase {
    func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the cat.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    static let notched = PetRender.notched, flat = PetRender.flat, header = PetRender.header
    static func crop(_ stage: PetRender.Stage, width: CGFloat) -> CGRect { PetRender.crop(stage, width: width) }

    /// Writes the review images of one gesture (see `PetRender.film`).
    func film(_ name: String, header: Bool = true, headerWidth: CGFloat = 70, every: Double = 0.1, compactOnly: Bool = false, look: PetLook = PetLook(), gif: Bool = true, _ poses: (PetRender.Stage) -> [PetPose]) throws {
        try PetRender.film(name, to: renderDirectory(), header: header, headerWidth: headerWidth, every: every, compactOnly: compactOnly, look: look, gif: gif, poses)
    }

    /// One gesture, started at once, as the director runs it, over the cat's own life and follow-through.
    func film(_ name: String, _ kind: PetDirector.Kind, variant: Int? = nil, facing: CGFloat? = nil, every: Double = 0.2, header: Bool = false, look: PetLook = PetLook(), idle: Double = 10) throws {
        try film(name, header: header, headerWidth: 70, every: every, compactOnly: !header, look: look) { stage in
            PetSim.gesture(kind, in: stage, variant: variant, facing: facing, input: { _ in PetInput(idle: idle) })
        }
    }

    /// Every frame of `seconds` at the film rate from a gesture sampled directly.
    func sample(_ seconds: Double, _ pose: (Double) -> PetPose) -> [PetPose] { PetRender.sample(seconds, pose) }

    // MARK: The gestures

    func testRenderTheGesturesThatWereThere() throws {
        try film("groom", .groom, variant: 0, every: 0.1, header: true)
        try film("groom-chest", .groom, variant: 1, every: 0.1)
        try film("glance", .glance, variant: 0, every: 0.2); try film("listen", .glance, variant: 1, every: 0.2); try film("look-up", .glance, variant: 3, every: 0.2)
        try film("peek", .peek, every: 0.25, header: true)
        try film("play", .play, every: 0.3, header: true)
        try film("wave", .wave, every: 0.25)
        try film("land", header: true, compactOnly: true) { _ in self.sample(PetAnimation.landLength) { PetAnimation.land(u: $0, time: 3) } }
        for style in [PetCheer.hop, .doubleHop, .content] {
            try film("celebrate-\(style)", header: true, every: 0.12) { _ in self.sample(PetAnimation.cheerLength(style)) { PetAnimation.celebrate(u: $0, time: 3, style: style) } }
        }
    }

    func testRenderTheNewGestures() throws {
        try film("yawn", .yawn, every: 0.12, header: true)
        try film("scratch", .scratch, every: 0.1)
        try film("startle", .startle, variant: 0, every: 0.12)
        try film("tail-play", .tailPlay, every: 0.15)
        try film("loaf", .loaf, variant: 0, facing: 1, every: 0.5)
        try film("knead", .loaf, variant: 1, facing: 1, every: 0.5)
        try film("hunt-catch", .hunt, variant: 0, facing: 1, every: 0.3, header: true)
        try film("hunt-miss", .hunt, variant: 1, facing: -1, every: 0.3)
        try film("stretch", .stretch, facing: 1, every: 0.3, header: true)
        try film("nap", .nap, facing: 1, every: 0.8, idle: 400)
    }

    /// The idle cat for half a minute: its breathing, blinks, flicks and glances, a frame every half second, in each temperament.
    func testRenderTheRestingCat() throws {
        for personality in PetPersonality.allCases {
            try film("rest-\(personality.rawValue)", header: false, every: 0.5, compactOnly: true, gif: false) { stage in
                var prefs = PetPreferences(); prefs.personality = personality; prefs.activity = .none
                return PetSim.run(stage.layout, seconds: 24, fps: PetRender.fps, seed: 2, input: { _ in var i = PetInput(idle: 10); i.prefs = prefs; return i }).map(\.pose)
            }
        }
    }

    // MARK: The coats and what the cat wears

    func testRenderEveryCoatAndAccessory() throws {
        let directory = try renderDirectory()
        let sit = PetAnimation.sit(time: 3)
        var rows: [CGImage] = []
        for coat in PetCoat.allCases {
            for accessory in PetAccessory.allCases {
                rows.append(PetRender.image(sit, stage: Self.notched, ppp: 7, look: PetLook(coat: coat, accessory: accessory), crop: Self.crop(Self.notched, width: 46)))
            }
        }
        try PetRender.writePNG(PetRender.sheet(rows, columns: PetAccessory.allCases.count), to: directory.appendingPathComponent("coats-accessories-zoom.png"))
        // The same at the real size, with the head turned and the tail up, so the bell and the stripes are seen move.
        var moving = sit; moving.tilt = -0.2; moving.swing = 0.7; moving.tail.p3 = CGPoint(x: -10, y: 22)
        var real: [CGImage] = []
        for coat in PetCoat.allCases {
            for accessory in PetAccessory.allCases { real.append(PetRender.image(moving, stage: Self.notched, ppp: 2, look: PetLook(coat: coat, accessory: accessory), crop: Self.crop(Self.notched, width: 46))) }
        }
        try PetRender.writePNG(PetRender.sheet(real, columns: PetAccessory.allCases.count, gap: 2), to: directory.appendingPathComponent("coats-accessories-real.png"))
        // The tabby's stripes follow a walk and a lie-down.
        let tabby = PetLook(coat: .tabby, accessory: .collar), ginger = PetLook(coat: .ginger, accessory: .bow)
        let poses = [PetAnimation.walk(phase: 1, amp: 1, time: 1), PetAnimation.loaf(rest: 0, time: 1), PetAnimation.bow(time: 1), PetAnimation.arch(time: 1)]
        try PetRender.writePNG(PetRender.sheet(poses.flatMap { p in [tabby, ginger].map { PetRender.image(p, stage: Self.notched, ppp: 7, look: $0, crop: Self.crop(Self.notched, width: 46)) } }, columns: 4), to: directory.appendingPathComponent("coats-poses-zoom.png"))
    }

    // MARK: Moments

    /// The cat noticing a pointer: it appears at 0.3 s up and to the right, stays (and gives a slow blink), and leaves at 6 s.
    func testRenderCurious() throws {
        for (name, gaze) in [("curious-right", PetGaze(dx: 0.9, dy: 0.3)), ("curious-left", PetGaze(dx: -0.9, dy: -0.2)), ("curious-above", PetGaze(dx: 0.05, dy: 1))] {
            try film(name, headerWidth: 70, every: 0.25) { stage in
                PetSim.run(stage.layout, seconds: 8, fps: PetRender.fps, seed: 2, input: { t in PetInput(gaze: t > 0.3 && t < 6 ? gaze : nil) }).map(\.pose)
            }
        }
    }

    /// Transitions: sitting down into a nap and waking, stretching, playing, a stroll out and back, all between sits.
    func testRenderTransitions() throws {
        for (name, kind, seconds, compact) in [("nap", PetDirector.Kind.nap, 14.0, true), ("stretch", .stretch, 7.0, true), ("play", .play, 6.4, true), ("wave", .wave, 3.4, true)] {
            try film("transition-" + name, header: true, every: seconds > 8 ? 0.5 : 0.25, compactOnly: compact) { stage in
                PetSim.run(stage.layout, seconds: seconds, fps: PetRender.fps, before: { $0.begin(kind, layout: stage.layout) }, input: { _ in PetInput(idle: 300) }).map(\.pose)
            }
        }
        // A stroll in the header, followed by a window that tracks the cat: setting off, the middle of the walk, arriving.
        let header = Self.header
        let stroll = PetSim.run(header.layout, seconds: 24, fps: PetRender.fps, before: { $0.begin(.stroll, layout: header.layout) })
        let directory = try renderDirectory()
        let frames = stroll.map(\.pose)
        func following(_ pose: PetPose) -> CGRect { CGRect(x: max(0, HeaderPetView.homeX + pose.x - 26), y: 0, width: 58, height: PetRender.size(header).height) }
        func sheet(_ name: String, _ range: ClosedRange<Double>, step: Double) throws {
            let indices = stride(from: Int(range.lowerBound * PetRender.fps), through: Int(range.upperBound * PetRender.fps), by: max(1, Int(step * PetRender.fps))).filter { $0 < frames.count }
            let images = indices.map { PetRender.image(frames[$0], stage: header, ppp: 6, caption: String(format: "%.2f", Double($0) / PetRender.fps), crop: following(frames[$0])) }
            try PetRender.writePNG(PetRender.sheet(images, columns: 6), to: directory.appendingPathComponent("transition-stroll-\(name).png"))
        }
        try sheet("start", 0...2.2, step: 0.1)
        try sheet("middle", 6...7.2, step: 0.1)
        try sheet("arrive", 7.6...10.2, step: 0.1)
        try PetRender.writeGIF(frames.indices.map { PetRender.image(frames[$0], stage: header, ppp: 4, crop: CGRect(x: 0, y: 0, width: 164, height: PetRender.size(header).height)) }, fps: PetRender.fps, to: directory.appendingPathComponent("transition-stroll-header.gif"))
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

    /// A task finishes while the island is collapsed: the alert's peek makes the cat look up and toward the bell (and mew); once that
    /// settles, a single cheer. The alert's own timeline drives the cat's reaction, as in the app.
    func testRenderAFinishedTaskAsTheAppSeesIt() throws {
        let alert = NookAlert(id: 1, sessionID: "a", kind: .finished, title: "api", message: "Claude terminó.")
        var timeline = AlertPeekTimeline()
        timeline.begin(alert, now: 0, motion: true)
        try film("finish-with-alert", header: false, every: 0.25, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 7, fps: PetRender.fps, input: { t in
                PetInput(perk: timeline.perk(at: t), perkAge: t, completions: t > 0.05 ? 1 : 0)
            }).map(\.pose)
        }
        // The same finish while the island is open: no alert, the header cat cheers at once.
        try film("finish-in-header", compactOnly: false) { stage in
            PetSim.run(stage.layout, seconds: 3, fps: PetRender.fps, input: { t in PetInput(completions: t > 0.1 ? 1 : 0) }).map(\.pose)
        }
        // How each temperament cheers.
        for personality in PetPersonality.allCases {
            try film("finish-\(personality.rawValue)", header: false, every: 0.2, compactOnly: true) { stage in
                var prefs = PetPreferences(); prefs.personality = personality
                return PetSim.run(stage.layout, seconds: 3, fps: PetRender.fps, input: { t in var i = PetInput(completions: t > 0.1 ? 1 : 0); i.prefs = prefs; return i }).map(\.pose)
            }
        }
    }

    /// Interruptions: a grooming cat that the pointer approaches, a peek cut short by an alert, a nap that ends when the user
    /// comes back, a drag taking over, and a stroll stopped halfway that walks home afterwards.
    func testRenderInterruptions() throws {
        try film("interrupt-groom-by-pointer", header: false, every: 0.15, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 5, fps: PetRender.fps, before: { $0.begin(.groom, layout: stage.layout) }, input: { t in PetInput(gaze: t > 1.2 && t < 3.6 ? PetSim.pointer : nil) }).map(\.pose)
        }
        try film("interrupt-peek-by-alert", header: false, every: 0.2, compactOnly: true) { stage in
            var timeline = AlertPeekTimeline()
            timeline.begin(NookAlert(id: 2, sessionID: "a", kind: .question, title: "api", message: "?"), now: 3, motion: true)
            return PetSim.run(stage.layout, seconds: 7, fps: PetRender.fps, before: { $0.begin(.peek, layout: stage.layout) }, input: { t in PetInput(perk: timeline.perk(at: t), perkAge: max(0, t - 3)) }).map(\.pose)
        }
        try film("interrupt-nap-by-user", header: false, every: 0.4, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 16, fps: PetRender.fps, before: { $0.begin(.nap, layout: stage.layout) }, input: { t in PetInput(idle: t < 9 ? 400 : 0) }).map(\.pose)
        }
        try film("interrupt-by-drag", header: false, every: 0.1, compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 3, fps: PetRender.fps, before: { $0.begin(.stretch, layout: stage.layout) }, input: { t in PetInput(gaze: t > 1.5 ? PetSim.pointer : nil, dragging: t > 1.5) }).map(\.pose)
        }
        // Header: a stroll stopped by the pointer, then the walk home.
        let header = Self.header
        let frames = PetSim.run(header.layout, seconds: 30, fps: PetRender.fps, before: { $0.begin(.stroll, layout: header.layout) }, input: { t in PetInput(gaze: t > 5 && t < 8 ? PetSim.pointer : nil) }).map(\.pose)
        let directory = try renderDirectory()
        try PetRender.writeGIF(frames.indices.map { PetRender.image(frames[$0], stage: header, ppp: 4, crop: CGRect(x: 0, y: 0, width: 164, height: PetRender.size(header).height)) }, fps: PetRender.fps, to: directory.appendingPathComponent("interrupt-stroll-header.gif"))
    }

    /// Put down after a drag: drops in from above, squashes, settles.
    func testRenderLandingAfterADrag() throws {
        try film("landing-after-drag", compactOnly: true) { stage in
            PetSim.run(stage.layout, seconds: 1.8, fps: PetRender.fps, before: { $0.land() }).map(\.pose)
        }
    }

    /// One image with a row per gesture (collapsed island, zoomed), as the quick look at everything the cat can do.
    func testRenderGallery() throws {
        let directory = try renderDirectory()
        let stage = Self.notched
        func row(_ title: String, count: Int = 10, _ poses: [PetPose]) -> [CGImage] {
            let picks = (0..<count).map { poses[min(poses.count - 1, $0 * (poses.count - 1) / max(1, count - 1))] }
            return picks.enumerated().map { PetRender.image($1, stage: stage, ppp: 4, caption: $0 == 0 ? title : nil, crop: Self.crop(stage, width: 46)) }
        }
        let sit = PetAnimation.sit(time: 3)
        let ledge = PetRender.placement(stage, pose: PetPose()).ledge
        var rows = [
            row("curiosidad", (0..<60).map { PetAnimation.curious(sit, gaze: PetGaze(dx: 0.9, dy: 0.3), amount: 1, age: Double($0) / 30 * 3.5) }),
            row("aseo", sample(PetAnimation.groomLength) { PetAnimation.groom(u: $0, time: 3) }),
            row("mirada", sample(PetAnimation.glanceLength) { PetAnimation.glance(u: $0, time: 3) }),
            row("asomarse", sample(PetAnimation.peekLength) { PetAnimation.peek(u: $0, time: 3, ledge: ledge) }),
            row("celebracion", sample(PetAnimation.celebrateLength) { PetAnimation.celebrate(u: $0, time: 3) }),
            row("aterrizaje", sample(PetAnimation.landLength) { PetAnimation.land(u: $0, time: 3) }),
            row("bostezo", sample(PetAnimation.yawnLength) { PetAnimation.yawn(u: $0, time: 3) }),
            row("rascarse", sample(PetAnimation.scratchLength) { PetAnimation.scratch(u: $0, time: 3) }),
            row("susto", sample(PetAnimation.startleLength) { PetAnimation.startle(u: $0, time: 3) }),
            row("cola", sample(PetAnimation.tailPlayLength) { PetAnimation.tailPlay(u: $0, time: 3) }),
            row("hogaza", sample(14) { PetAnimation.loafing(u: $0, length: 14, time: 3, variant: 1) }),
            row("caza", sample(PetAnimation.huntLength(variant: 0)) { PetAnimation.hunt(u: $0, length: PetAnimation.huntLength(variant: 0), time: 3, variant: 0, shift: -1.2) }),
            row("estirarse", sample(7) { PetAnimation.perform(.stretch, u: $0, length: 7, time: 3, alert: 0, shift: -0.5) }),
        ]
        rows = rows.filter { !$0.isEmpty }
        try PetRender.writePNG(PetRender.sheet(rows.flatMap { $0 }, columns: 10, gap: 3), to: directory.appendingPathComponent("gallery-gestures.png"))
    }

    // MARK: The settings card's tab

    private func write(_ host: NSView, size: NSSize, appearance: NSAppearance.Name, to url: URL) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// The Gato tab with the plain cat and with a dressed one, in a light window and a dark one (the card itself is always dark: it is
    /// the island's own surface). Nothing is read or asked.
    func testRenderTheSettingsCardsGatoTab() throws {
        let directory = try renderDirectory()
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        var dressed = PetPreferences()
        dressed.personality = .sleepy; dressed.activity = .low; dressed.coat = .ginger; dressed.accessory = .collar; dressed.celebrates = false
        var playful = PetPreferences(); playful.personality = .playful; playful.activity = .high; playful.coat = .tabby; playful.accessory = .glasses
        for (name, prefs) in [("default", PetPreferences()), ("sleepy-ginger", dressed), ("playful-tabby", playful)] {
            let model = AppModel(receivesSignals: false, defaults: suite)
            model.pet = prefs
            model.settingsTab = .pet
            for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let view = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:])).padding(30).background(Color(white: look == "dark" ? 0.3 : 0.86))
                let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
                try write(host, size: host.fittingSize, appearance: appearance, to: directory.appendingPathComponent("settings-gato-\(name)-\(look).png"))
            }
        }
        // The tab bar with a permission missing: the dot sits on the symbol's corner.
        let needy = AppModel(receivesSignals: false, defaults: suite)
        needy.settingsTab = .pet
        let missing = PermissionsModel(states: [.accessibility: .notAsked, .automation: .notAsked, .screenRecording: .notAsked])
        let dotted = NSHostingView(rootView: SettingsCard(model: needy, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: missing).padding(30).background(Color(white: 0.3)).environment(\.nookTintedGlass, false))
        try write(dotted, size: dotted.fittingSize, appearance: .darkAqua, to: directory.appendingPathComponent("settings-gato-with-a-dot.png"))
        // The tab bar with five tabs, the Isla tab for comparison.
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.settingsTab = .island
        let host = NSHostingView(rootView: SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:])).padding(30).background(Color(white: 0.3)).environment(\.nookTintedGlass, false))
        try write(host, size: host.fittingSize, appearance: .darkAqua, to: directory.appendingPathComponent("settings-isla-with-gato-tab.png"))
    }
}
