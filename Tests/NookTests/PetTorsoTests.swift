import AppKit
import XCTest
@testable import Nook

/// The cat's body as one figure (`PetTorso`): the haunch and the chest joined by a back line and a belly line instead of two ovals stuck
/// together. It must hold both ovals (nothing a pose puts in the body is cut off), fill the notch between them, be carried as one piece by
/// a cat on its feet, bend with the pose, stay the same figure when the cat turns round, and fit in the bounds the views repaint.
@MainActor
final class PetTorsoTests: XCTestCase {
    private func outline(_ pose: PetPose) -> CGPath {
        let path = CGMutablePath()
        PetTorso(pose).trace(move: { path.move(to: $0) }, curve: { path.addCurve(to: $2, control1: $0, control2: $1) })
        path.closeSubpath()
        return path
    }

    /// Every pose the cat's gestures go through, a wake and the sad cat, each also turned the other way.
    private var poses: [PetPose] {
        var all: [PetPose] = []
        for kind in PetDirector.Kind.allCases where kind != .home {
            all += PetSim.gesture(kind, in: PetRender.notched, extra: 0.3, fps: 6)
        }
        all += stride(from: 0.0, through: PetAnimation.wakeLength(), by: 0.1).map { PetAnimation.waking(u: $0, time: 3 + $0, sleptAge: 9, sleptLength: 1e9) }
        all += stride(from: 0.0, through: 6, by: 0.25).map { PetAnimation.sad(time: $0) }
        all += [PetAnimation.lifted(time: 1), PetAnimation.bow(time: 1), PetAnimation.arch(time: 1), PetAnimation.crouch(time: 1), PetAnimation.loaf(rest: 1, curl: 1, time: 1)]
        return all + all.map { $0.mirrored() }
    }

    func testTheOutlineHoldsBothOvalsInEveryPose() {
        let list = poses
        XCTAssertGreaterThan(list.count, 400)
        for (i, pose) in list.enumerated() {
            let path = outline(pose)
            for o in [pose.haunch, pose.chest] {
                // Points just inside each oval's own outline are inside the body's.
                let inner = PetOval(o.cx, o.cy, o.rx - 0.05, o.ry - 0.05, o.angle)
                for k in 0..<48 where !path.contains(inner.point(at: CGFloat(k) / 48 * 2 * .pi)) {
                    XCTFail("pose \(i) (\(pose.action)): the body cuts into an oval at \(inner.point(at: CGFloat(k) / 48 * 2 * .pi))")
                    return
                }
            }
            XCTAssertTrue(pose.bounds.offsetBy(dx: 0, dy: -pose.y).insetBy(dx: -0.01, dy: -0.01).contains(path.boundingBoxOfPath), "pose \(i): the bounds hold the body")
        }
    }

    func testTheNotchBetweenTheOvalsIsFilledByOneCurve() {
        // The standing cat's two ovals, given a waist (as a cat that sits, bows or crouches has): just above where their tops cross there
        // was a notch; the back runs over it.
        var stand = PetAnimation.walk(phase: 0, amp: 0, time: 1)
        stand.carriage = 0
        let notch = CGPoint(x: -1.45, y: 16.37)
        XCTAssertGreaterThan(stand.haunch.level(of: notch), -0.05, "the point is where the two outlines cross")
        XCTAssertGreaterThan(stand.chest.level(of: notch), -0.05)
        let above = CGPoint(x: notch.x, y: notch.y + 0.6)
        XCTAssertTrue(outline(stand).contains(above), "the back fills the notch")
        XCTAssertGreaterThan(stand.haunch.level(of: above), 0); XCTAssertGreaterThan(stand.chest.level(of: above), 0)
        // But with a waist it is not a capsule: the back dips below the line over the two tops.
        XCTAssertFalse(outline(stand).contains(CGPoint(x: notch.x, y: 18.1)), "the back dips between the haunch and the shoulders")
    }

    func testACatOnItsFeetIsCarriedAsOnePiece() {
        // Standing and all through a stride: the body is one piece, not two lobes with a pinched waist (an infinity sign). (Turned the other
        // way it is the same figure: `testTheSeatedCatIsSymmetricAndATurnedCatIsTheSameFigure`.)
        var poses = [PetAnimation.walk(phase: 0, amp: 0, time: 1)]
        poses += stride(from: 0.0, to: 2 * .pi, by: 0.35).map { PetAnimation.walk(phase: $0, amp: 1, time: 1 + $0) }
        for pose in poses {
            XCTAssertEqual(pose.carriage, 1)
            let torso = PetTorso(pose), path = outline(pose)
            // The back runs straight from the rump to the shoulders: the line between its ends touches both ovals and the outline follows it.
            let a = pose.haunch.point(at: torso.backHaunch), b = pose.chest.point(at: torso.backChest)
            let length = hypot(b.x - a.x, b.y - a.y), ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let up = CGPoint(x: -uy, y: ux)
            XCTAssertGreaterThan(up.y, 0.9)
            let height = up.x * a.x + up.y * a.y
            XCTAssertEqual(pose.haunch.support(up.x, up.y).reach, height, accuracy: 0.001, "the back lies on the rump")
            XCTAssertEqual(pose.chest.support(up.x, up.y).reach, height, accuracy: 0.001, "the back lies on the shoulders")
            for k in 1..<20 {
                let u = CGFloat(k) / 20, p = CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
                XCTAssertTrue(path.contains(CGPoint(x: p.x - 0.05 * up.x, y: p.y - 0.05 * up.y)), "the back does not dip at \(p)")
                XCTAssertFalse(path.contains(CGPoint(x: p.x + 0.05 * up.x, y: p.y + 0.05 * up.y)), "the back is straight at \(p)")
            }
            // The belly reaches the chest on the two ovals' common tangent below, where the cat is deepest, and from there runs back
            // almost straight: it never arches up between the legs, but tucks in a little in front of the thigh.
            let e = pose.chest.point(at: torso.bellyChest), d = pose.chest.direction(at: torso.bellyChest)
            let dn = hypot(d.x, d.y), down = CGPoint(x: d.y / dn, y: -d.x / dn)
            XCTAssertLessThan(down.y, -0.9)
            let low = down.x * e.x + down.y * e.y
            XCTAssertEqual(pose.haunch.support(down.x, down.y).reach, low, accuracy: 0.001, "the belly's line is the tangent under both ovals")
            let h = pose.haunch.point(at: torso.bellyHaunch)
            var deepest: CGFloat = 0
            for k in 1..<20 {
                let u = CGFloat(k) / 20, q = CGPoint(x: e.x + (h.x - e.x) * u, y: e.y + (h.y - e.y) * u)
                // The point on the tangent under `q`, and how far above it the belly is there.
                let along = (q.x - e.x) * -down.y + (q.y - e.y) * down.x, base = CGPoint(x: e.x - down.y * along, y: e.y + down.x * along)
                var rise: CGFloat = 0
                while rise < 2, !path.contains(CGPoint(x: base.x - down.x * rise, y: base.y - down.y * rise)) { rise += 0.01 }
                deepest = max(deepest, rise)
            }
            XCTAssertLessThan(deepest, 0.35, "the belly does not arch up between the legs")
            XCTAssertGreaterThan(deepest, 0.15, "the flank tucks in a little in front of the thigh")
        }
    }

    func testTheCarriageBlendsTheFigureSmoothly() {
        // From a waist to one piece, the line ends move a little at a time: a cat that gets up and walks off fills out as it goes, and a
        // seated cat (its sides neither above the other) hardly changes.
        for base in [PetAnimation.walk(phase: 0, amp: 0, time: 1), PetAnimation.sit(time: 1), PetAnimation.bow(time: 1)] {
            var last: PetTorso?
            for k in 0...40 {
                var pose = base; pose.carriage = CGFloat(k) / 40
                let torso = PetTorso(pose)
                if let last {
                    for (x, y) in [(last.backHaunch, torso.backHaunch), (last.backChest, torso.backChest), (last.bellyHaunch, torso.bellyHaunch), (last.bellyChest, torso.bellyChest)] {
                        XCTAssertLessThan(abs(x - y), 0.03, "\(base.action): no jump at carriage \(pose.carriage)")
                    }
                }
                last = torso
            }
        }
    }

    func testTheSpineBendsWithThePose() {
        // The arch rounds the back out over both ovals and draws the belly in; the stretch's bow dips the back.
        let arch = PetAnimation.arch(time: 1), bow = PetAnimation.bow(time: 1)
        let archTop = outline(arch).boundingBoxOfPath.maxY
        XCTAssertGreaterThan(archTop, max(arch.haunch.cy + arch.haunch.halfHeight, arch.chest.cy + arch.chest.halfHeight), "the arched back rises over both ovals")
        // Under the arch, between the legs, the belly stays up: it is drawn in well above the line under the two ovals' lowest points.
        let rear = arch.haunch.point(at: arch.haunch.support(0, -1).angle), front = arch.chest.point(at: arch.chest.support(0, -1).angle)
        let under = rear.y + (front.y - rear.y) * (0 - rear.x) / (front.x - rear.x)
        XCTAssertFalse(outline(arch).contains(CGPoint(x: 0, y: under + 1.2)), "the belly is drawn in under the arch")
        // The bow's back sags below the straight line from the rump to the shoulders.
        let path = outline(bow)
        let rump = bow.haunch.point(at: bow.haunch.support(-sin(-0.44), cos(-0.44)).angle), shoulders = bow.chest.point(at: bow.chest.support(-sin(-0.44), cos(-0.44)).angle)
        let middle = CGPoint(x: (rump.x + shoulders.x) / 2, y: (rump.y + shoulders.y) / 2 - 0.3)
        XCTAssertFalse(path.contains(middle), "the back dips long and low in the stretch")
    }

    func testTheSeatedCatIsSymmetricAndATurnedCatIsTheSameFigure() {
        let sit = PetAnimation.sit(time: 2)
        let box = outline(sit).boundingBoxOfPath
        XCTAssertEqual(box.midX, 0, accuracy: 0.001, "the seated cat's body is as wide on both sides")
        for pose in [sit, PetAnimation.walk(phase: 1.1, amp: 1, time: 1), PetAnimation.arch(time: 1), PetAnimation.crouch(time: 1, wiggle: 0.6)] {
            let path = outline(pose), turned = outline(pose.mirrored())
            for x in stride(from: CGFloat(-16), through: 16, by: 0.7) {
                for y in stride(from: CGFloat(0), through: 24, by: 0.7) where path.contains(CGPoint(x: x, y: y)) != turned.contains(CGPoint(x: -x, y: y)) {
                    XCTFail("\(pose.action): the turned body differs at (\(x), \(y))")
                    return
                }
            }
        }
    }

    func testTheBodyMovesSmoothlyFromFrameToFrame() {
        // A stretch and a walk set off from the sit, frame by frame: the body's box never jumps further than the ovals themselves move.
        let frames = PetSim.gesture(.stretch, in: PetRender.notched, extra: 0.3, fps: 30)
        for (a, b) in zip(frames, frames.dropFirst()) {
            let boxA = outline(a).boundingBoxOfPath, boxB = outline(b).boundingBoxOfPath
            let ovals = max(abs(a.haunch.cx - b.haunch.cx), abs(a.haunch.cy - b.haunch.cy), abs(a.chest.cx - b.chest.cx), abs(a.chest.cy - b.chest.cy),
                            abs(a.haunch.rx - b.haunch.rx), abs(a.chest.rx - b.chest.rx), abs(a.haunch.ry - b.haunch.ry), abs(a.chest.ry - b.chest.ry),
                            abs(a.haunch.angle - b.haunch.angle) * 8, abs(a.chest.angle - b.chest.angle) * 8, abs(a.carriage - b.carriage) * PetTorso.carriageReach)
            let moved = max(abs(boxA.minX - boxB.minX), abs(boxA.maxX - boxB.maxX), abs(boxA.minY - boxB.minY), abs(boxA.maxY - boxB.maxY))
            XCTAssertLessThanOrEqual(moved, 2 * ovals + 0.01, "the body's outline follows its ovals without jumps")
        }
    }
}
