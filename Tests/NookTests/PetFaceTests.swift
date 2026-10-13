import AppKit
import XCTest
@testable import Nook

/// The face holds together however many layers turn it (`PetFace`): the eyes stay in the head and clear of an open mouth, the mouth
/// goes where the face turns and stays above the chin, and an ear turns without lifting its base off the head. Also the painter's
/// side of it: Daniel's frame (the greeting, the pointer off to one side, a mew) paints two eyes and a mouth apart, and the tabby's
/// flanks match.
@MainActor
final class PetFaceTests: XCTestCase {
    private let head = PetFace.head

    /// Points round an oval, grown by `grow` on every side.
    private func outline(_ r: CGRect, grow: CGFloat = 0, count: Int = 120) -> [CGPoint] {
        let cx = r.midX, cy = r.midY, rx = r.width / 2 + grow, ry = r.height / 2 + grow
        return (0..<count).map { i in
            let a = Double(i) / Double(count) * 2 * .pi
            return CGPoint(x: cx + rx * CGFloat(cos(a)), y: cy + ry * CGFloat(sin(a)))
        }
    }
    /// Negative inside the oval `r`, positive outside.
    private func level(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let x = (p.x - r.midX) / (r.width / 2), y = (p.y - r.midY) / (r.height / 2)
        return x * x + y * y - 1
    }
    private func headRect(inset: CGFloat) -> CGRect { CGRect(x: -head.width + inset, y: -head.height + inset, width: 2 * (head.width - inset), height: 2 * (head.height - inset)) }

    /// What is wrong with the face of `pose`, if anything: an eye or the mouth out of the head (by the margins given), or the two touching.
    private func faults(_ pose: PetPose, eyeMargin: CGFloat = 0.4, mouthMargin: CGFloat = 0.25, gap: CGFloat = 0.3) -> [String] {
        let face = PetFace(pose)
        var out: [String] = []
        for side: CGFloat in [-1, 1] {
            let eye = face.eyeRect(side)
            if outline(eye, count: 48).contains(where: { level($0, headRect(inset: eyeMargin)) > 0 }) { out.append("eye \(side) leaves the face") }
            if let mouth = face.mouth {
                // Grown by half the gap each, no point of one may fall inside the other.
                let a = eye.insetBy(dx: -gap / 2, dy: -gap / 2), b = mouth.insetBy(dx: -gap / 2, dy: -gap / 2)
                if outline(a).contains(where: { level($0, b) < 0 }) || outline(b).contains(where: { level($0, a) < 0 }) { out.append("eye \(side) runs into the mouth") }
            }
        }
        if let mouth = face.mouth, outline(mouth, count: 72).contains(where: { level($0, headRect(inset: mouthMargin)) > 0 }) { out.append("the mouth leaves the face") }
        return out
    }

    // MARK: Any look

    /// Every look the layers could add up to (far past anything one of them asks for), with every opening of the mouth and the eyes
    /// that come with it: a mew with wide eyes, a sigh, a yawn with its lids squeezed down.
    func testTheEyesStayInTheFaceAndClearOfTheMouthWhateverTheLook() {
        let faces: [(mouth: CGFloat, eyes: [CGFloat])] = [
            (0, [0, 1, 1.6]), (0.15, [0.74, 1.6]), (0.3, [1, 1.6]), (0.5, [0, 1, 1.3, 1.6]), (0.55, [1.6]),
            (0.7, [0.06, 0.4, 0.6]), (0.85, [0.06, 0.35]), (1, [0, 0.06, 0.25]),
        ]
        var checked = 0
        for x in stride(from: -8.0, through: 8.0, by: 0.25) {
            for y in stride(from: -6.0, through: 6.0, by: 0.25) {
                for (mouth, eyes) in faces {
                    for open in eyes {
                        var pose = PetPose()
                        pose.look = CGPoint(x: x, y: y); pose.mouth = mouth; pose.eyes = open
                        let found = faults(pose)
                        XCTAssertTrue(found.isEmpty, "look (\(x), \(y)), mouth \(mouth), eyes \(open): \(found.joined(separator: ", "))")
                        if !found.isEmpty { return }
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 60_000)
    }

    /// The frames the cat really makes when the layers stack: the home's player with the pointer held all round it and a click (the
    /// mew) at several moments, over each gesture that moves the face; the stacked scenes of the renders; and every frame of the
    /// collapsed cat's gestures, the waking and the sad cat.
    func testEveryFrameTheLayersMakeKeepsTheFaceTogether() {
        var poses: [(String, PetPose)] = PetFaceScenes.states
        let layout = PetPlayer.Layout.header(travel: 40, scale: 3, height: 104)
        let gazes = stride(from: 0.0, to: 2 * .pi, by: .pi / 4).map { PetGaze(dx: CGFloat(cos($0)), dy: CGFloat(sin($0))) }
        for kind in [PetDirector.Kind.wave, .yawn, .glance, .startle, .hunt, .play, .groom] {
            for gaze in gazes {
                for click in [0.2, 0.9, 1.6] {
                    let frames = PetSim.run(layout, seconds: 3.2, fps: 15, seed: 2, before: { $0.begin(kind, layout: layout) }, input: { t in
                        var input = PetInput(gaze: t > 0.4 ? gaze : nil, idle: 2)
                        if t >= click { let age = t - click; input.perk = PetAnimation.ramp(age, 0, 0.12) * (1 - PetAnimation.ramp(age, 0.9, 1.5)); input.perkAge = age }
                        return input
                    })
                    poses += frames.map { ("\(kind) gaze (\(gaze.dx), \(gaze.dy)) click \(click) at \($0.t)", $0.pose) }
                }
            }
        }
        poses += PetSim.compactPoses(step: 0.1).map { ("compact", $0) }
        poses += stride(from: 0, through: PetAnimation.wakeLength(), by: 0.05).map { ("waking \($0)", PetAnimation.waking(u: $0, time: 3 + $0, sleptAge: 9, sleptLength: 1e9)) }
        poses += stride(from: 0, through: 12, by: 0.05).map { ("sad \($0)", PetAnimation.sad(time: $0, amount: PetAnimation.sadAmount(at: $0))) }
        var opened = 0
        for (name, pose) in poses {
            let found = faults(pose)
            XCTAssertTrue(found.isEmpty, "\(name): \(found.joined(separator: ", ")) (look \(pose.look), mouth \(pose.mouth), eyes \(pose.eyes))")
            if !found.isEmpty { return }
            if pose.mouth > 0.02 { opened += 1 }
        }
        XCTAssertGreaterThan(opened, 200, "plenty of the frames have the mouth open")
    }

    // MARK: The face turns

    func testTheMouthTheGlassesAndATearGoWhereTheFaceTurns() {
        var pose = PetPose(); pose.mouth = 0.5
        let still = PetFace(pose)
        XCTAssertEqual(still.turn, .zero); XCTAssertEqual(still.mouth?.midX ?? 1, 0, accuracy: 1e-9)
        // A look within what one layer asks for is drawn as it is, and the face turns with it by its share.
        pose.look = CGPoint(x: 1.5, y: -0.8)
        let turned = PetFace(pose)
        XCTAssertEqual(turned.eyes.x, 1.5, accuracy: 1e-9); XCTAssertEqual(turned.eyes.y, -0.8, accuracy: 1e-9)
        XCTAssertEqual(turned.turn.x, 1.5 * PetFace.turnShare, accuracy: 1e-9); XCTAssertEqual(turned.turn.y, -0.8 * PetFace.turnShare, accuracy: 1e-9)
        XCTAssertEqual(turned.mouth?.midX ?? 0, turned.turn.x, accuracy: 1e-9, "the mouth goes with the face")
        XCTAssertEqual((turned.mouth?.midY ?? 0) - (still.mouth?.midY ?? 0), turned.turn.y, accuracy: 1e-9)
        // Past that, however far the layers push, the eyes only creep toward their reach, and do it smoothly.
        var previous = CGFloat(0)
        for x in stride(from: CGFloat(0), through: 12, by: 0.05) {
            pose.look = CGPoint(x: x, y: 0)
            let e = PetFace(pose).eyes.x
            XCTAssertLessThanOrEqual(e, PetFace.eyeReach.x); XCTAssertGreaterThanOrEqual(e, previous - 1e-9, "it never turns back")
            XCTAssertLessThanOrEqual(e - previous, 0.05 + 1e-9, "and never jumps")
            previous = e
        }
        XCTAssertGreaterThan(previous, PetFace.eyeReach.x - 0.05)
        // The painter draws the glasses and a tear where the face has turned: they move with the look.
        var sad = PetAnimation.sad(time: 2.5); sad.tear = 0.4
        func pixels(_ p: PetPose, _ look: PetLook) -> [UInt8] { paint(p, look: look, scale: 6) }
        var glancing = sad; glancing.look.x += 1.5
        XCTAssertNotEqual(blackOutside(pixels(sad, PetLook(accessory: .glasses)), pixels(sad, PetLook())), blackOutside(pixels(glancing, PetLook(accessory: .glasses)), pixels(glancing, PetLook())), "the rims move")
    }

    // MARK: The ears

    func testTheEarsTurnWithoutLiftingTheirBasesOffTheHead() {
        let headOval = headRect(inset: 0)
        let rest = (left: PetFace.ear(side: -1, angle: 0), right: PetFace.ear(side: 1, angle: 0))
        XCTAssertEqual(rest.right.tip, CGPoint(x: 7.5, y: 12.2)); XCTAssertEqual(rest.left.outer, CGPoint(x: -9.1, y: 1.6))
        var last = rest.right
        for angle in stride(from: CGFloat(-2.5), through: 2.5, by: 0.01) {
            for side: CGFloat in [-1, 1] {
                let ear = PetFace.ear(side: side, angle: angle), at = side < 0 ? rest.left : rest.right
                // The base's corners stay where they rest or go into the head; neither sticks out past its place on the outline.
                XCTAssertLessThanOrEqual(level(ear.outer, headOval), level(at.outer, headOval) + 1e-9, "angle \(angle) side \(side): the outer corner stays on the head")
                XCTAssertLessThanOrEqual(level(ear.inner, headOval), level(at.inner, headOval) + 1e-9, "angle \(angle) side \(side): the inner corner stays on the head")
                // The left ear is the right one mirrored.
                let mirror = PetFace.ear(side: -side, angle: angle)
                XCTAssertEqual(ear.tip.x, -mirror.tip.x, accuracy: 1e-9); XCTAssertEqual(ear.tip.y, mirror.tip.y, accuracy: 1e-9)
            }
            // However far the layers turn it, the ear stops where an ear can go, and it moves smoothly to there.
            let turn = PetFace.earTurn(angle)
            XCTAssertGreaterThanOrEqual(turn, -PetFace.earForward.reach); XCTAssertLessThanOrEqual(turn, PetFace.earBack.reach)
            let ear = PetFace.ear(side: 1, angle: angle)
            if angle > -2.5 { XCTAssertLessThan(hypot(ear.tip.x - last.tip.x, ear.tip.y - last.tip.y), 0.15, "angle \(angle): no jump") }
            last = ear
        }
        // What one layer asks for is drawn as it is: the alert's ears, a perk's, the sad cat's.
        for angle: CGFloat in [-0.26, -0.1, 0, 0.28, 0.6] { XCTAssertEqual(PetFace.earTurn(angle), angle, accuracy: 1e-9) }
        // Pricked, the tip goes in toward the middle of the head; laid back, out and down.
        XCTAssertLessThan(PetFace.ear(side: 1, angle: -0.3).tip.x, 7.5); XCTAssertGreaterThan(PetFace.ear(side: 1, angle: 0.5).tip.x, 7.5)
        XCTAssertLessThan(PetFace.ear(side: 1, angle: 0.5).tip.y, 12.2)
    }

    // MARK: Painted

    /// `pose` painted on mid grey at `scale` pixels per rig unit, its feet near the bottom of the canvas, as RGBA bytes.
    private let canvas = (width: 44, height: 40)
    private func paint(_ pose: PetPose, look: PetLook = PetLook(), scale: CGFloat) -> [UInt8] {
        let w = Int(CGFloat(canvas.width) * scale), h = Int(CGFloat(canvas.height) * scale)
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(gray: 0.5, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.scaleBy(x: scale, y: scale); cg.translateBy(x: CGFloat(canvas.width) / 2, y: 4)
        PetPainter.draw(pose, look: look, in: cg)
        let data = cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return Array(UnsafeBufferPointer(start: data, count: w * h * 4))
    }
    /// How many separate black shapes there are (each at least `least` pixels).
    private func blackShapes(_ p: [UInt8], scale: CGFloat, least: Int = 30) -> Int {
        let w = Int(CGFloat(canvas.width) * scale), h = Int(CGFloat(canvas.height) * scale)
        var seen = [Bool](repeating: false, count: w * h)
        func black(_ i: Int) -> Bool { p[i * 4] < 50 && p[i * 4 + 1] < 50 && p[i * 4 + 2] < 50 }
        var shapes = 0
        for start in 0..<(w * h) where !seen[start] && black(start) {
            var stack = [start], size = 0
            seen[start] = true
            while let i = stack.popLast() {
                size += 1
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && black(j) { seen[j] = true; stack.append(j) }
                }
            }
            if size >= least { shapes += 1 }
        }
        return shapes
    }
    /// The black pixels of `p` that are not black in `q`.
    private func blackOutside(_ p: [UInt8], _ q: [UInt8]) -> [Int] { stride(from: 0, to: p.count, by: 4).filter { p[$0] < 60 && q[$0] > 200 } }

    /// Daniel's frame, and the others that stack a mew over a look: the painter draws two eyes and a mouth, three shapes apart.
    func testTheStackedFramesPaintTwoEyesAndAMouthApart() {
        for (name, pose) in PetFaceScenes.states where pose.mouth > 0.1 {
            XCTAssertEqual(blackShapes(paint(pose, scale: 10), scale: 10), 3, "\(name): two eyes and a mouth, apart")
        }
        XCTAssertEqual(blackShapes(paint(PetFaceScenes.greetingToTheSide, scale: 10), scale: 10), 3, "the greeting with the pointer off to the side")
    }

    /// The tabby's flanks: the stripes on the near side (where the near legs are drawn over the body) are as whole as on the far side.
    func testTheTabbysFlanksMatch() {
        let scale: CGFloat = 10
        let pose = PetAnimation.sit(time: 3)
        let tabby = paint(pose, look: PetLook(coat: .tabby), scale: scale), plain = paint(pose, look: PetLook(coat: .snow), scale: scale)
        let w = Int(CGFloat(canvas.width) * scale), h = Int(CGFloat(canvas.height) * scale)
        func stripes(xFrom: CGFloat, xTo: CGFloat) -> Int {
            var count = 0
            for y in 0..<h {
                let rigY = CGFloat(h - 1 - y) / scale - 4
                guard rigY > 2, rigY < 12 else { continue }
                for x in 0..<w {
                    let rigX = CGFloat(x) / scale - CGFloat(canvas.width) / 2
                    guard rigX >= xFrom, rigX < xTo else { continue }
                    let i = (y * w + x) * 4
                    if plain[i] > 200, tabby[i] < 140 { count += 1 }
                }
            }
            return count
        }
        let far = stripes(xFrom: -10, xTo: -4), near = stripes(xFrom: 4, xTo: 10)
        XCTAssertGreaterThan(far, 100)
        XCTAssertEqual(Double(near), Double(far), accuracy: Double(far) * 0.15, "both flanks show both their stripes (far \(far), near \(near))")
    }
}
