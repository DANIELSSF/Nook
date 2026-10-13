import AppKit
import XCTest
@testable import Nook

/// The cat's motion as the big cats draw it: every gesture, run by the director and the player at 60 frames a second and drawn at the
/// home's size (2.4 points a unit, 2 pixels a point: a cat about 150 pixels tall). It writes, for review by eye (set NOOK_RENDER_DIR):
///   - `motion-<name>.png`, the whole gesture a frame every tenth of a second;
///   - `motion-<name>-60-<k>.png`, its key moments at every frame (60 a second);
///   - `motion-numbers.txt`, how smooth each one is: the largest step of any part of the picture from one frame to the next (a pop) and
///     the largest change of a part's speed between two frames (a kink: a velocity that jumps), in pixels at that size, and when.
/// Nothing is asserted: the numbers are compared before and after a change by whoever made it.
@MainActor
final class PetMotionRenderTests: XCTestCase {
    private func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the cat's motion.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    func testRenderEveryGestureAt60FramesASecondAtTheHomesSize() throws {
        let directory = try renderDirectory()
        var report: [String] = ["film                     frames   pop px (at)            kink px (at, part)                  same-cat misses"]
        for film in PetMotion.films() {
            let frames = film.frames
            try PetMotion.writeSheet(frames, every: 6, columns: 8, ppp: 1.5, follow: film.follows, to: directory.appendingPathComponent("motion-\(film.name).png"))
            for (k, window) in film.windows.enumerated() {
                let picked = frames.filter { $0.t >= window.lowerBound - 1e-9 && $0.t <= window.upperBound + 1e-9 }
                try PetMotion.writeSheet(picked, every: 1, columns: 10, ppp: 1.5, follow: film.follows, to: directory.appendingPathComponent("motion-\(film.name)-60-\(k).png"))
            }
            let s = PetMotion.smoothness(frames)
            report.append(String(format: "%-24@ %5d   %6.2f (%5.2f s)   %6.2f (%5.2f s, %@)   %d", film.name as NSString, frames.count, s.pop, s.popAt, s.kink, s.kinkAt, s.kinkPart as NSString, s.misses))
        }
        try report.joined(separator: "\n").write(to: directory.appendingPathComponent("motion-numbers.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }
}

extension PetMotionRenderTests {
    /// Every gesture's pose, sampled straight from its function, as numbers (`motion-poses.json`): the website's port is checked against
    /// them number by number (its own `anim.ts` computes the same samples).
    func testWriteThePosesForThePortCheck() throws {
        let directory = try renderDirectory()
        func numbers(_ p: PetPose) -> [Double] {
            var r: [Double] = []
            _ = p.combined(p) { a, _ in r.append(Double(a)); return a }
            return r
        }
        var out: [String: [[Double]]] = [:]
        func sample(_ name: String, _ length: Double, step: Double = 0.05, _ pose: (Double) -> PetPose) {
            out[name] = stride(from: 0.0, through: length + 1e-9, by: step).map { numbers(pose($0)) }
        }
        sample("groom0", PetAnimation.groomLength) { PetAnimation.groom(u: $0, time: 5 + $0, variant: 0) }
        sample("groom1", PetAnimation.groomLength) { PetAnimation.groom(u: $0, time: 5 + $0, variant: 1) }
        for v in 0..<4 { sample("glance\(v)", PetAnimation.glanceLength) { PetAnimation.glance(u: $0, time: 5 + $0, variant: v) } }
        sample("peek", PetAnimation.peekLength) { PetAnimation.peek(u: $0, time: 5 + $0, ledge: -11.67) }
        for style in [PetCheer.hop, .doubleHop, .content] { sample("celebrate-\(style)", PetAnimation.cheerLength(style)) { PetAnimation.celebrate(u: $0, time: 5 + $0, style: style) } }
        sample("land", PetAnimation.landLength) { PetAnimation.land(u: $0, time: 5 + $0) }
        sample("yawn", PetAnimation.yawnLength) { PetAnimation.yawn(u: $0, time: 5 + $0) }
        sample("scratch", PetAnimation.scratchLength) { PetAnimation.scratch(u: $0, time: 5 + $0) }
        for v in 0..<2 { sample("startle\(v)", PetAnimation.startleLength) { PetAnimation.startle(u: $0, time: 5 + $0, variant: v) } }
        sample("tailPlay", PetAnimation.tailPlayLength) { PetAnimation.tailPlay(u: $0, time: 5 + $0) }
        for v in 0..<2 { for f: CGFloat in [1, -1] { sample("loaf\(v)\(f)", 14) { PetAnimation.loafing(u: $0, length: 14, time: 5 + $0, variant: v, facing: f) } } }
        for v in 0..<2 { for (f, shift): (CGFloat, CGFloat) in [(1, 0), (-1, -1.2)] {
            sample("hunt\(v)\(f)", PetAnimation.huntLength(variant: v)) { PetAnimation.hunt(u: $0, length: PetAnimation.huntLength(variant: v), time: 5 + $0, variant: v, facing: f, shift: shift) }
        } }
        for f: CGFloat in [1, -1] { sample("stretch\(f)", 7) { PetAnimation.perform(.stretch, u: $0, length: 7, time: 5 + $0, facing: f, alert: 0, shift: -0.5) } }
        sample("sleep", 40, step: 0.2) { PetAnimation.perform(.sleep, u: $0, length: 40, time: 5 + $0, alert: 0) }
        sample("play", 6.4) { PetAnimation.perform(.play, u: $0, length: 6.4, time: 5 + $0, alert: 0, shift: -0.8) }
        sample("wave", 3.4) { PetAnimation.perform(.wave, u: $0, length: 3.4, time: 5 + $0, alert: 0) }
        sample("walk", 2 * .pi, step: 0.1) { PetAnimation.walk(phase: $0, amp: 1, time: 5 + $0) }
        sample("waking", PetAnimation.wakeLength()) { PetAnimation.waking(u: $0, time: 3 + $0, sleptAge: 9, sleptLength: 1e9) }
        sample("sad", 9) { PetAnimation.sad(time: $0, amount: PetAnimation.sadAmount(at: $0)) }
        let sit = PetAnimation.sit(time: 2), stand = PetAnimation.walk(phase: 0, amp: 0, time: 2), lying = PetAnimation.loaf(rest: 0, time: 2)
        sample("turn-head", 1, step: 0.02) { sit.staged(to: stand, CGFloat($0)) }
        sample("turn-legs", 1, step: 0.02) { stand.staged(to: sit, CGFloat($0), order: .legsFirst) }
        sample("lie-blend", 1, step: 0.02) { sit.blended(to: lying, CGFloat($0)) }
        // The follow-through over a landing and a hop at 60 frames a second.
        var secondary = PetSecondary()
        out["secondary"] = stride(from: 0.0, through: 2.4, by: 1.0 / 60).map { u in
            var p = u < 1.25 ? PetAnimation.celebrate(u: u, time: 5 + u) : PetAnimation.land(u: u - 1.25, time: 5 + u)
            p.head.x += u > 1.5 ? 2 : 0; p.tilt += u > 1.8 ? 0.2 : 0
            secondary.apply(&p, dt: u == 0 ? 0 : 1.0 / 60, scale: 2.4)
            return numbers(p)
        }
        let data = try JSONSerialization.data(withJSONObject: out)
        try data.write(to: directory.appendingPathComponent("motion-poses.json"))
    }
}

/// The films and the measures of `PetMotionRenderTests`, with no assertions.
enum PetMotion {
    /// The home's stage: 200 by 92 points, the cat's home 0.4 of the way across, 2.4 points a unit.
    static let scale: CGFloat = 2.4, width: CGFloat = 200, height: CGFloat = 92, fps = 60.0
    static var homeX: CGFloat { width * 0.4 }
    static var layout: PetPlayer.Layout { .header(travel: max(0, width - homeX - PetAnimation.reach.right * scale - 4), scale: scale, height: height) }
    /// Pixels a rig unit at the size the sheets are measured at (two pixels a point).
    static var pixels: CGFloat { scale * 2 }

    struct Frame { var t: Double; var pose: PetPose }
    struct Film {
        var name: String
        var frames: [Frame]
        /// The key moments, drawn at every frame.
        var windows: [ClosedRange<Double>]
        /// The tile follows the cat across the stage (a stroll) instead of staying on its home.
        var follows = false
    }

    /// The player's frames at 60 a second from a fresh cat with nothing of its own to do (`activity` none), `before` starting what is filmed.
    static func run(seconds: Double, seed: Int = 2, before: ((inout PetPlayer) -> Void)? = nil, input: @escaping (Double) -> PetInput = { _ in PetInput(idle: 10) }) -> [Frame] {
        var player = PetPlayer(layout: .header, seed: seed, rhythm: PetDirector.Rhythm(first: 1e6...1e6, between: 1e6...1e6))
        before?(&player)
        var frames: [Frame] = []
        var t = 0.0
        while t <= seconds + 1e-9 {
            frames.append(Frame(t: t, pose: player.pose(now: 1000 + t, layout: layout, motion: true, input: input(t))))
            t += 1 / fps
        }
        return frames
    }

    /// One of the director's gestures, started at once, the way it goes for `variant` and `facing`.
    static func gesture(_ kind: PetDirector.Kind, variant: Int? = nil, facing: CGFloat? = nil, extra: Double = 1.2, idle: Double = 10) -> [Frame] {
        let seed = PetSim.seed(for: kind, layout: .header, variant: variant, facing: facing)
        var probe = PetDirector(layout: .header, seed: seed)
        probe.start(kind, stage: layout.stage)
        let seconds = (probe.running?.length ?? 5) + extra
        return run(seconds: seconds, seed: seed, before: { $0.begin(kind, layout: layout) }, input: { _ in PetInput(idle: idle) })
    }

    /// Every film, with its key moments.
    static func films() -> [Film] {
        var films: [Film] = [
            Film(name: "groom", frames: gesture(.groom, variant: 0), windows: [0...1.3, 1.0...2.2]),
            Film(name: "groom-chest", frames: gesture(.groom, variant: 1), windows: [0...1.4]),
            Film(name: "glance", frames: gesture(.glance, variant: 0), windows: [0...1.0, 1.3...2.2]),
            Film(name: "listen", frames: gesture(.glance, variant: 1), windows: [0...1.0]),
            Film(name: "look-up", frames: gesture(.glance, variant: 3), windows: [0...1.0]),
            Film(name: "stretch", frames: gesture(.stretch, facing: 1), windows: [0.4...1.9, 3.1...4.6, 5.4...7.0]),
            Film(name: "wave", frames: gesture(.wave), windows: [0...1.2]),
            Film(name: "play", frames: gesture(.play), windows: [0.2...1.7, 2.0...3.4]),
            Film(name: "peek", frames: gesture(.peek), windows: [0.8...2.3, 2.6...4.0]),
            Film(name: "yawn", frames: gesture(.yawn), windows: [0.3...1.6, 2.2...3.6]),
            Film(name: "scratch", frames: gesture(.scratch), windows: [0...1.0, 1.5...2.7]),
            Film(name: "startle", frames: gesture(.startle, variant: 0), windows: [0...1.0, 2.0...2.9]),
            Film(name: "tail-play", frames: gesture(.tailPlay), windows: [0...1.2, 1.3...2.6]),
            Film(name: "loaf", frames: gesture(.loaf, variant: 0, facing: 1), windows: [0...2.0]),
            Film(name: "knead", frames: gesture(.loaf, variant: 1, facing: 1), windows: [3.4...4.8]),
            Film(name: "hunt-catch", frames: gesture(.hunt, variant: 0), windows: [3.5...5.0, 5.2...6.6, 6.5...8.0]),
            Film(name: "hunt-miss", frames: gesture(.hunt, variant: 1), windows: [6.5...8.0, 8.0...9.6]),
            Film(name: "nap", frames: gesture(.nap, facing: 1, extra: 0, idle: 400).filter { $0.t < 8 }, windows: [0...1.6, 1.5...3.0]),
        ]
        // A stroll out and back, followed across the stage.
        let stroll = run(seconds: 24, seed: 1, before: { $0.begin(.stroll, layout: layout) })
        films.append(Film(name: "stroll", frames: stroll, windows: [0...1.5, 5.0...6.2, 7.4...9.0], follows: true))
        // The overlays: the cheers (a completion), the landing after a drag, the pointer.
        for (style, personality) in [(PetCheer.hop, PetPersonality.curious), (.doubleHop, .playful), (.content, .calm)] {
            var prefs = PetPreferences(); prefs.personality = personality; prefs.activity = .none
            let frames = run(seconds: PetAnimation.cheerLength(style) + 1.0, input: { t in var i = PetInput(completions: t > 0.05 ? 1 : 0, idle: 10); i.prefs = prefs; return i })
            films.append(Film(name: "celebrate-\(style)", frames: frames, windows: [0.2...1.5]))
        }
        films.append(Film(name: "land", frames: run(seconds: 1.8, before: { $0.land() }), windows: [0...1.2]))
        films.append(Film(name: "curious", frames: run(seconds: 5, input: { t in PetInput(gaze: t > 0.3 && t < 3.5 ? PetGaze(dx: 0.9, dy: 0.3) : nil, idle: 10) }), windows: [0.2...1.2, 3.4...4.4]))
        // A click's mew (the perk), and the pointer interrupting a groom.
        films.append(Film(name: "perk", frames: run(seconds: 2.4, input: { t in
            var i = PetInput(idle: 10)
            if t >= 0.3 { let age = t - 0.3; i.perk = PetAnimation.ramp(age, 0, 0.12) * (1 - PetAnimation.ramp(age, 0.9, 1.5)); i.perkAge = age }
            return i
        }), windows: [0.2...1.2]))
        films.append(Film(name: "interrupt-groom", frames: run(seconds: 4, before: { $0.begin(.groom, layout: layout) }, input: { t in PetInput(gaze: t > 1.2 && t < 2.6 ? PetGaze(dx: 0.8, dy: 0.2) : nil, idle: 10) }), windows: [1.0...2.2, 2.4...3.6]))
        // Waking from the night's sleep (the bedtime), and a nap of its own cut short by the user coming back.
        films.append(Film(name: "wake", frames: run(seconds: PetAnimation.wakeLength() + 0.8, before: { $0.fallAsleep(); $0.wake() }, input: { _ in PetInput(idle: 400) }), windows: [0...1.4, 1.3...2.7, 2.6...4.0]))
        films.append(Film(name: "nap-interrupted", frames: run(seconds: 12, before: { $0.begin(.nap, layout: layout) }, input: { t in PetInput(idle: t < 8 ? 400 : 0) }).filter { $0.t >= 7 }, windows: [7.9...9.4]))
        // The sad cat of the question before quitting: its entrance and a sigh.
        films.append(Film(name: "sad", frames: stride(from: 0.0, through: 9, by: 1 / fps).map { Frame(t: $0, pose: PetAnimation.sad(time: $0, amount: PetAnimation.sadAmount(at: $0))) }, windows: [0...1.2]))
        return films
    }

    // MARK: Drawing

    /// One frame on the home's black stage, cropped to 120 by 92 points round the cat's home (or round the cat, following it).
    static func image(_ pose: PetPose, t: Double, ppp: CGFloat, follow: Bool) -> CGImage {
        let w = 120.0, h = Double(height)
        let left = follow ? homeX + pose.x - 56 : homeX - 56
        let cg = CGContext(data: nil, width: Int(w * ppp), height: Int(h * ppp), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.scaleBy(x: ppp, y: ppp)
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // The ground line, so a hop and a landing read against it.
        cg.setFillColor(CGColor(gray: 0.18, alpha: 1)); cg.fill(CGRect(x: 0, y: Double(HomePetView.ground) - 0.5, width: w, height: 0.5))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        cg.saveGState()
        cg.translateBy(x: -left, y: 0)
        HomePetView.paint(pose, look: PetLook(), scale: scale, homeX: homeX, in: cg)
        cg.restoreGState()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 6, weight: .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        (String(format: "%.3f", t) as NSString).draw(at: CGPoint(x: 3, y: h - 9), withAttributes: attributes)
        return cg.makeImage()!
    }

    static func writeSheet(_ frames: [Frame], every: Int, columns: Int, ppp: CGFloat, follow: Bool, to url: URL) throws {
        let picked = stride(from: 0, to: frames.count, by: max(1, every)).map { frames[$0] }
        guard !picked.isEmpty else { return }
        try PetRender.writePNG(PetRender.sheet(picked.map { image($0.pose, t: $0.t, ppp: ppp, follow: follow) }, columns: min(columns, picked.count), gap: 3), to: url)
    }

    // MARK: Measures

    /// The numbers of a pose that are drawn as places, in rig units (an angle counted by how far its edge moves, as `displacement` does).
    static func parts(_ p: PetPose) -> [(String, CGFloat)] {
        var r: [(String, CGFloat)] = [("x", p.x / scale), ("y", p.y), ("head.x", p.head.x), ("head.y", p.head.y), ("tilt", p.tilt * 9.3), ("headScale", p.headScale * 9.3),
                                      ("earL", p.earL * 8), ("earR", p.earR * 8), ("look.x", p.look.x), ("look.y", p.look.y),
                                      ("haunch.cx", p.haunch.cx), ("haunch.cy", p.haunch.cy), ("haunch.rx", p.haunch.rx), ("haunch.ry", p.haunch.ry), ("haunch.angle", p.haunch.angle * 8),
                                      ("chest.cx", p.chest.cx), ("chest.cy", p.chest.cy), ("chest.rx", p.chest.rx), ("chest.ry", p.chest.ry), ("chest.angle", p.chest.angle * 8),
                                      ("tail.p0.x", p.tail.p0.x), ("tail.p0.y", p.tail.p0.y), ("tail.c1.x", p.tail.c1.x * 0.5), ("tail.c1.y", p.tail.c1.y * 0.5),
                                      ("tail.c2.x", p.tail.c2.x * 0.5), ("tail.c2.y", p.tail.c2.y * 0.5), ("tail.p3.x", p.tail.p3.x), ("tail.p3.y", p.tail.p3.y), ("tail.width", p.tail.width * 0.5)]
        let names = ["farHind", "farFront", "nearHind", "nearFront"]
        for (i, leg) in p.legs.enumerated() {
            r += [("\(names[i]).hip.x", leg.hip.x), ("\(names[i]).hip.y", leg.hip.y), ("\(names[i]).knee.x", leg.knee.x), ("\(names[i]).knee.y", leg.knee.y),
                  ("\(names[i]).foot.x", leg.foot.x), ("\(names[i]).foot.y", leg.foot.y)]
        }
        return r
    }

    /// The largest step of any part between two frames (a pop) and the largest change of a part's step between two frames (a kink: its
    /// speed jumps), in pixels at the home's size; and how many frames are not the cat's own shape (a leg, the tail or the body out of
    /// what its own poses use).
    static func smoothness(_ frames: [Frame]) -> (pop: Double, popAt: Double, kink: Double, kinkAt: Double, kinkPart: String, misses: Int) {
        var pop = 0.0, popAt = 0.0, kink = 0.0, kinkAt = 0.0, part = ""
        let px = Double(pixels)
        // Which leg is which does not show while the cat turns round: the frames before are compared with their legs where this one's stand.
        func aligned(_ p: PetPose, like q: PetPose) -> PetPose {
            guard p.isFrontal != q.isFrontal else { return p }
            var r = p; r.legs = PetPose.paired(p.legs, like: q.legs); return r
        }
        for i in 1..<frames.count {
            let now = parts(frames[i].pose), before = parts(aligned(frames[i - 1].pose, like: frames[i].pose))
            let earlier = i >= 2 ? parts(aligned(frames[i - 2].pose, like: frames[i].pose)) : []
            for k in now.indices {
                let d = abs(Double(now[k].1 - before[k].1)) * px
                if d > pop { pop = d; popAt = frames[i].t }
                if i >= 2 {
                    let dd = abs(Double(now[k].1 - 2 * before[k].1 + earlier[k].1)) * px
                    if dd > kink { kink = dd; kinkAt = frames[i - 1].t; part = now[k].0 }
                }
            }
        }
        return (pop, popAt, kink, kinkAt, part, frames.filter { !sameCat($0.pose) }.count)
    }

    /// The envelope of the cat's own poses (a sit, a stand, a bow, an arch, a loaf, a curled-up nap, a crouch, its yawn and the sad cat).
    static let own: [PetPose] = {
        let t = 40.0
        return [PetAnimation.sit(time: t), PetAnimation.walk(phase: 0, amp: 0, time: t), PetAnimation.walk(phase: 1, amp: 1, time: t), PetAnimation.bow(time: t), PetAnimation.arch(time: t),
                PetAnimation.loaf(rest: 0, time: t), PetAnimation.loaf(rest: 1, curl: 1, time: t, asleep: 1), PetAnimation.crouch(time: t), PetAnimation.yawn(u: 1.6, time: t),
                PetAnimation.sad(time: t), PetAnimation.lifted(time: t)]
    }()
    static func legLength(_ l: PetLimb) -> CGFloat { hypot(l.knee.x - l.hip.x, l.knee.y - l.hip.y) + hypot(l.foot.x - l.knee.x, l.foot.y - l.knee.y) }
    static func tailLength(_ tail: PetTail) -> CGFloat {
        var length: CGFloat = 0, last = tail.p0
        for i in 1...24 {
            let u = CGFloat(i) / 24, v = 1 - u
            let point = CGPoint(x: v * v * v * tail.p0.x + 3 * v * v * u * tail.c1.x + 3 * v * u * u * tail.c2.x + u * u * u * tail.p3.x,
                                y: v * v * v * tail.p0.y + 3 * v * v * u * tail.c1.y + 3 * v * u * u * tail.c2.y + u * u * u * tail.p3.y)
            length += hypot(point.x - last.x, point.y - last.y); last = point
        }
        return length
    }
    static func sameCat(_ p: PetPose) -> Bool {
        let legs = own.flatMap { $0.legs.map(legLength) }, tails = own.map { tailLength($0.tail) }
        guard let shortest = legs.min(), let longest = legs.max(), let tailMin = tails.min(), let tailMax = tails.max() else { return true }
        for leg in p.legs where !(shortest * 0.8...longest * 1.1).contains(legLength(leg)) { return false }
        if !(tailMin * 0.8...tailMax * 1.1).contains(tailLength(p.tail)) { return false }
        let haunch = own.map(\.haunch.rx), chest = own.map(\.chest.rx)
        if !((haunch.min() ?? 0) - 0.8...(haunch.max() ?? 0) + 0.8).contains(p.haunch.rx) { return false }
        if !((chest.min() ?? 0) - 0.8...(chest.max() ?? 0) + 0.8).contains(p.chest.rx) { return false }
        return true
    }
}
