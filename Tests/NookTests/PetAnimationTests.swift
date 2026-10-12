import AppKit
import XCTest
@testable import Nook

/// The cat's rigs and drawing: every pose fits where it is drawn, the new gestures say what they are meant to,
/// walking keeps its feet on the ground, and a cat that must not move shows fixed poses.
@MainActor
final class PetAnimationTests: XCTestCase {
    private func times(_ span: Double, step: Double) -> StrideThrough<Double> { stride(from: 0, through: span, by: step) }

    /// Drawn extent of a pose in the collapsed wing, in points: (left, right, bottom, top) of an island `height` tall.
    private func compactExtent(_ pose: PetPose, height: CGFloat) -> (left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat) {
        let b = pose.bounds, ground = height / 2 - 9, s = PetAnimation.compactScale
        return (PetAnimation.compactAnchor + pose.x + b.minX * s, PetAnimation.compactAnchor + pose.x + b.maxX * s, ground + b.minY * s, ground + b.maxY * s)
    }

    /// Every pose the collapsed cat can be in: each gesture sampled through its whole length, every way of looking at the
    /// pointer, and each frame of an alert's reaction over all of them.
    private func everyCompactPose(height: CGFloat, step: Double = 0.05) -> [PetPose] {
        var poses = PetSim.compactPoses(step: step, height: height)
        for dx: CGFloat in [-1, 0, 1] { for dy: CGFloat in [-1, 0, 1] { for age in times(2, step: step) {
            poses.append(PetAnimation.curious(PetAnimation.sit(time: age), gaze: PetGaze(dx: dx, dy: dy), amount: 1, age: age))
        } } }
        for working in [0, 1] { for t in times(10, step: 0.25) { poses.append(PetAnimation.sit(time: t, alert: CGFloat(working))) } }
        return poses
    }

    // MARK: Drawing limits

    func testEveryGestureStaysInsideTheCollapsedWing() {
        for height: CGFloat in [28, 32] {
            for pose in everyCompactPose(height: height) {
                let e = compactExtent(pose, height: height)
                let what = "\(pose.action) y=\(pose.y) h=\(height)"
                XCTAssertGreaterThanOrEqual(e.left, PetAnimation.wing.lowerBound, what)
                XCTAssertLessThanOrEqual(e.right, PetAnimation.wing.upperBound, what)
                XCTAssertLessThan(PetAnimation.wing.upperBound, 30, "the camera cutout starts at 30 pt")
                XCTAssertLessThanOrEqual(e.top, height, what)
                // Only a cat sunk behind the ledge goes below the island's bottom edge, and the mask cuts it there.
                if pose.y > -1 { XCTAssertGreaterThanOrEqual(e.bottom, 0, what) }
            }
        }
    }

    /// Paints the cat into a bitmap the size of the island and checks every pixel: nothing outside the island's own shape,
    /// nothing over the camera cutout, however deep the cat sinks behind the edge.
    func testNothingIsPaintedOutsideTheIslandOrOverTheCameraCutout() throws {
        let ppp = 2, island = (width: 246, cutout: 30)
        func pixels(_ height: Int, _ draw: () -> Void) -> [UInt8] {
            let w = island.width * ppp, h = height * ppp
            let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.scaleBy(x: CGFloat(ppp), y: CGFloat(ppp))
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            draw()
            let data = cg.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
            return (0..<(w * h)).map { data[$0 * 4 + 3] }
        }
        for height in [28, 32] {
            let bounds = NSRect(x: 0, y: 0, width: island.width, height: height)
            let inside = pixels(height) { NSColor.black.setFill(); PetView.islandPath(bounds).fill() }
            var peeking = 0
            for pose in everyCompactPose(height: CGFloat(height), step: 0.1) {
                let painted = pixels(height) { PetView.drawCat(pose, bounds: bounds) }
                var outside = 0, overCutout = 0
                for (i, alpha) in painted.enumerated() where alpha > 0 {
                    if inside[i] == 0 { outside += 1 }
                    if i % (island.width * ppp) >= island.cutout * ppp { overCutout += 1 }
                }
                XCTAssertEqual(outside, 0, "\(pose.action) y=\(pose.y) h=\(height): painted outside the island")
                XCTAssertEqual(overCutout, 0, "\(pose.action) y=\(pose.y) h=\(height): painted over the camera cutout")
                if pose.y < -10 { peeking += 1 }
            }
            XCTAssertGreaterThan(peeking, 20, "the check covered a cat sunk behind the edge")
        }
    }

    func testHeaderGesturesStayInsideTheStageAndNeverReachTheNotch() {
        for width: CGFloat in [60, 120, 164] {
            let view = HeaderPetView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
            for seed in 0..<12 {
                for kind in PetDirector.Kind.allCases where kind != .home {
                    var player = PetPlayer(layout: .header, seed: seed)
                    player.begin(kind, layout: view.layout)
                    var t = 0.0
                    while let running = player.director.running, t < 90 {
                        let pose = player.pose(now: 500 + t, layout: view.layout, motion: true, input: PetInput(idle: 400))
                        let b = pose.bounds
                        let what = "w=\(width) \(running.kind) \(pose.action) t=\(t)"
                        XCTAssertGreaterThanOrEqual(pose.x, -0.001, what)
                        XCTAssertLessThanOrEqual(pose.x, view.travel + 0.001, what)
                        XCTAssertGreaterThanOrEqual(b.minX, -PetAnimation.reach.left, what)
                        XCTAssertLessThanOrEqual(b.maxX, PetAnimation.reach.right, what)
                        // Drawn extent in stage points: it never leaves the stage, which ends before the notch.
                        XCTAssertGreaterThanOrEqual(HeaderPetView.homeX + pose.x + b.minX * view.scale, 0, what)
                        XCTAssertLessThanOrEqual(HeaderPetView.homeX + pose.x + b.maxX * view.scale, width, what)
                        XCTAssertLessThanOrEqual(HeaderPetView.ground + b.maxY * view.scale, 32, what)
                        if pose.y > -1 { XCTAssertGreaterThanOrEqual(HeaderPetView.ground + b.minY * view.scale, 0, what) }
                        t += 0.1
                    }
                }
            }
        }
    }

    func testALandingInTheHeaderStaysInsideTheStageToo() {
        for height: CGFloat in [28, 32] {
            let scale = min(0.5, max(0.3, (height - 15.5) / 31.5))
            var player = PetPlayer(layout: .header, seed: 2)
            let layout = PetPlayer.Layout.header(travel: 100, scale: scale, height: height)
            _ = player.pose(now: 10, layout: layout, motion: true, input: PetInput())
            player.land()
            var t = 10.0, highest: CGFloat = 0
            while t < 12 {
                t += 1.0 / 60
                let pose = player.pose(now: t, layout: layout, motion: true, input: PetInput())
                let b = pose.bounds
                highest = max(highest, pose.y)
                XCTAssertLessThanOrEqual(HeaderPetView.ground + b.maxY * scale, height, "h=\(height) t=\(t)")
                XCTAssertGreaterThanOrEqual(HeaderPetView.ground + b.minY * scale, 0)
            }
            XCTAssertGreaterThan(highest, 4, "it did come down from above")
        }
    }

    func testTheLedgeIsWhereThePetViewsPaintLastAndPeeksSinkBelowIt() {
        let notched = PetStage.compact(height: 32), flat = PetStage.compact(height: 28)
        XCTAssertEqual(notched.ledge, -7 / PetAnimation.compactScale, accuracy: 1e-9, "the island's bottom edge is 7 pt under the cat's feet")
        XCTAssertEqual(flat.ledge, -5 / PetAnimation.compactScale, accuracy: 1e-9)
        let header = PetStage.header(travel: 100)
        XCTAssertEqual(header.ledge, -HeaderPetView.ground / 0.5, accuracy: 1e-9)
        for stage in [notched, flat, header] {
            let heights = PetAnimation.peekHeights(ledge: stage.ledge)
            let head = PetPose().head.y
            XCTAssertLessThan(heights.hidden + head + 12.2, stage.ledge, "hidden: even the ear tips are behind the edge")
            XCTAssertGreaterThan(heights.ears + head + 12.2, stage.ledge, "ears: the tips show")
            XCTAssertLessThan(heights.ears + head + 7.4 * 0.0, stage.ledge + 6, "ears: only the tips")
            XCTAssertGreaterThan(heights.face + head + 0.3 - 1.45, stage.ledge, "face: the eyes show whole")
            XCTAssertLessThan(heights.face + head - 7.4, stage.ledge, "face: the chin is still behind the edge")
        }
    }

    // MARK: Gestures

    func testGroomingLiftsAPawToTheFaceAndWipesItTwiceWithHalfClosedEyes() {
        XCTAssertGreaterThanOrEqual(PetAnimation.groomLength, 2); XCTAssertLessThanOrEqual(PetAnimation.groomLength, 3)
        let rest = PetAnimation.sit(time: 5)
        var raised = 0.0, ups = 0, previous: CGFloat = 0, rising = false, wipeStart: Double? = nil
        for u in times(PetAnimation.groomLength, step: 0.01) {
            let p = PetAnimation.groom(u: u, time: 5)
            XCTAssertEqual(p.action, .groom)
            if p.legs[3].foot.y > PetAnimation.raisedAbove { raised += 0.01 }
            // The paw sweeps up the cheek twice: two peaks in the wipe's stretch.
            if u >= 1.05, u <= 2.15 {
                wipeStart = wipeStart ?? u
                if p.legs[3].foot.y > previous + 1e-6 { rising = true }
                else if p.legs[3].foot.y < previous - 1e-6, rising { ups += 1; rising = false }
            }
            previous = p.legs[3].foot.y
        }
        XCTAssertEqual(ups, 2, "two wipes")
        XCTAssertGreaterThan(raised, 1.2, "the paw is at the face for most of it")
        let mid = PetAnimation.groom(u: 1.0, time: 5)
        XCTAssertLessThan(mid.eyes, 0.3, "eyes half closed")
        XCTAssertGreaterThan(abs(mid.tilt - rest.tilt), 0.08, "a small tilt of the head")
        XCTAssertLessThan(abs(mid.tilt - rest.tilt), 0.25)
        XCTAssertLessThan(PetAnimation.groom(u: 0, time: 5).distance(to: rest), 0.01, "starts from the sit")
        XCTAssertLessThan(PetAnimation.groom(u: PetAnimation.groomLength, time: 5).distance(to: rest), 0.01, "and ends in it")
        XCTAssertGreaterThan(raised, 0)
        // The raised paw is drawn over the head with a seam, so it reads on the white face.
        XCTAssertGreaterThan(PetAnimation.groom(u: 1.5, time: 5).legs[3].foot.y, PetAnimation.raisedAbove)
    }

    func testCelebrationIsOneSmallHopWithAPrepAndASoftLanding() {
        let d = PetAnimation.celebrateLength
        XCTAssertGreaterThanOrEqual(d, 1); XCTAssertLessThanOrEqual(d, 1.5)
        let rest = PetAnimation.sit(time: 5)
        var peak: CGFloat = 0, peaks = 0, lastY: CGFloat = 0, climbing = false, lowestHead = rest.head.y
        var crouchedBeforeLeaving = false, landedLow = false, sparkleSeconds = 0.0, left = false
        for u in times(d, step: 0.01) {
            let p = PetAnimation.celebrate(u: u, time: 5)
            XCTAssertGreaterThanOrEqual(p.y, 0, "never below the ground")
            peak = max(peak, p.y)
            if p.y > lastY + 1e-6 { climbing = true } else if p.y < lastY - 1e-6, climbing { peaks += 1; climbing = false }
            lastY = p.y
            if p.y == 0 && !left && p.head.y < rest.head.y - 1.5 { crouchedBeforeLeaving = true }
            if p.y > 0.2 { left = true }
            if left && p.y == 0 && p.head.y < rest.head.y - 1.5 { landedLow = true }
            lowestHead = min(lowestHead, p.head.y)
            if p.sparkle > 0 { sparkleSeconds += 0.01 }
        }
        XCTAssertEqual(peaks, 1, "a single hop")
        XCTAssertGreaterThan(peak, 3); XCTAssertLessThan(peak, 6, "small")
        XCTAssertTrue(crouchedBeforeLeaving, "a little preparation before the jump")
        XCTAssertTrue(landedLow, "a small compression on landing")
        XCTAssertGreaterThan(sparkleSeconds, 0.3); XCTAssertLessThan(sparkleSeconds, 0.9, "a brief glint")
        XCTAssertLessThan(PetAnimation.celebrate(u: 0, time: 5).distance(to: rest), 0.01)
        XCTAssertLessThan(PetAnimation.celebrate(u: d, time: 5).distance(to: rest), 0.01)
        XCTAssertEqual(PetAnimation.celebrate(u: d, time: 5).sparkle, 0)
    }

    func testThePeekShowsTheEarsThenTheFaceThenAPawAndNeverMoreThanTheMask() {
        for stage in [PetStage.compact(height: 32), .compact(height: 28), .header(travel: 100)] {
            let ledge = stage.ledge
            var ears: Double?, face: Double?, paw: Double?, hidden: Double?
            for u in times(PetAnimation.peekLength, step: 0.01) {
                let p = PetAnimation.peek(u: u, time: 5, ledge: ledge)
                XCTAssertEqual(p.action, .peek)
                let top = p.head.y + p.y
                if hidden == nil, top + 12.2 < ledge - 2 { hidden = u }
                if hidden != nil, ears == nil, top + 12.2 > ledge + 1 { ears = u }
                if ears != nil, face == nil, top + 0.3 - 1.5 > ledge { face = u }
                // The paw shows above the edge: its tip, with its radius, is over the line.
                let foot = p.legs[3].foot
                if face != nil, paw == nil, foot.y + p.y - p.legs[3].width / 2 > ledge + 0.5, p.legs[3].foot.x > 8 { paw = u }
            }
            let first = [hidden, ears, face, paw].compactMap { $0 }
            XCTAssertEqual(first.count, 4, "hides, then shows its ears, its face and a paw (\(stage.layout))")
            XCTAssertEqual(first, first.sorted(), "in that order")
            XCTAssertLessThan((paw ?? 0), PetAnimation.peekLength - 1)
            // It comes back to the plain sit.
            XCTAssertEqual(PetAnimation.peek(u: PetAnimation.peekLength, time: 5, ledge: ledge, shift: 0).distance(to: PetAnimation.sit(time: 5)), 0, accuracy: 0.01)
            XCTAssertEqual(PetAnimation.peek(u: 0, time: 5, ledge: ledge).distance(to: PetAnimation.sit(time: 5)), 0, accuracy: 0.01)
        }
    }

    func testCuriosityMovesOnlyTheHeadEyesAndEarsWithinFixedLimitsForAnyPointer() {
        let rest = PetAnimation.sit(time: 3)
        // Any pointer at all, including nonsense, produces a mild turn.
        let wild: [CGFloat] = [-1e9, -50, -1, -0.3, 0, 0.3, 1, 50, 1e9, .infinity, -.infinity, .nan]
        for dx in wild { for dy in wild {
            for age in [0.0, 0.35, 0.5, 0.65, 0.8, 1.2, 5] {
                let p = PetAnimation.curious(rest, gaze: PetGaze(dx: dx, dy: dy), amount: 1, age: age)
                // The body, legs and tail are exactly as they were: the click target does not move.
                XCTAssertEqual(p.haunch, rest.haunch); XCTAssertEqual(p.chest, rest.chest); XCTAssertEqual(p.legs, rest.legs); XCTAssertEqual(p.tail, rest.tail)
                XCTAssertEqual(p.x, rest.x); XCTAssertEqual(p.y, rest.y)
                // The head turns a little, never far.
                XCTAssertLessThanOrEqual(abs(p.head.x - rest.head.x), 1.9)
                XCTAssertLessThanOrEqual(abs(p.head.y - rest.head.y), 2.0)
                XCTAssertLessThanOrEqual(abs(p.tilt - rest.tilt), 0.16, "limited tilt")
                XCTAssertLessThanOrEqual(abs(p.look.x - rest.look.x), 2.0, "pupils stay in the eyes")
                XCTAssertLessThanOrEqual(abs(p.look.y - rest.look.y), 1.1)
                XCTAssertLessThanOrEqual(abs(p.earL - rest.earL), 0.5); XCTAssertLessThanOrEqual(abs(p.earR - rest.earR), 0.5)
            }
        } }
        // It tips its head even when the pointer is straight ahead, and toward a pointer to one side.
        XCTAssertNotEqual(PetAnimation.curious(rest, gaze: PetGaze(), amount: 1, age: 5).tilt, rest.tilt)
        XCTAssertLessThan(PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 0), amount: 1, age: 5).tilt, rest.tilt, "toward the right")
        XCTAssertGreaterThan(PetAnimation.curious(rest, gaze: PetGaze(dx: -1, dy: 0), amount: 1, age: 5).tilt, rest.tilt, "toward the left")
        // It sniffs: three quick pulses of the head, then it holds still.
        var pulses = 0, rising = false, last: CGFloat = 0
        for age in times(1.5, step: 0.005) {
            let y = PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 0), amount: 1, age: age).head.y
            if y > last + 1e-9 { rising = true } else if y < last - 1e-9, rising { pulses += 1; rising = false }
            last = y
        }
        XCTAssertEqual(pulses, 3, "three sniffs")
        XCTAssertEqual(PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 0), amount: 1, age: 1.2).head.y, PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 0), amount: 1, age: 1.4).head.y, accuracy: 1e-9)
        // Staring (a drag) does not sniff.
        let stare = stride(from: 0.3, through: 1.0, by: 0.05).map { PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 0), amount: 1, age: $0, sniff: false).head.y }
        XCTAssertEqual(Set(stare).count, 1)
        // Nothing at all when there is no reaction, and the way back is the way it was.
        XCTAssertEqual(PetAnimation.curious(rest, gaze: PetGaze(dx: 1, dy: 1), amount: 0, age: 1), rest)
    }

    func testLandingDropsInSquashesAndSettlesIntoTheSit() {
        let rest = PetAnimation.sit(time: 4)
        XCTAssertGreaterThan(PetAnimation.land(u: 0, time: 4).y, 5, "starts in the air")
        var squashed = false, lastY = PetAnimation.land(u: 0, time: 4).y, fell = true
        for u in times(PetAnimation.landLength, step: 0.01) {
            let p = PetAnimation.land(u: u, time: 4)
            XCTAssertGreaterThanOrEqual(p.y, 0)
            if u < 0.3 { fell = fell && p.y <= lastY + 1e-9 }
            lastY = p.y
            if p.head.y < rest.head.y - 1.5 { squashed = true }
        }
        XCTAssertTrue(fell, "it falls without rising")
        XCTAssertTrue(squashed, "a soft squash on the ground")
        XCTAssertLessThan(PetAnimation.land(u: PetAnimation.landLength, time: 4).distance(to: rest), 0.01)
    }

    // MARK: Walking and turning

    func testFeetStayPlantedWhileWalking() {
        // Body speed is one cycle (`4 * halfStride` units) per `2 * pi` of phase. A foot that is down moves back by exactly
        // that, so its place on the ground does not change; and no foot is ever under the ground.
        let perCycle = 4 * Double(PetAnimation.halfStride)
        var planted = 0
        var previous: [CGFloat?] = [nil, nil, nil, nil]
        for phase in stride(from: 0.0, to: 8 * .pi, by: 0.01) {
            let walker = PetAnimation.walk(phase: phase, amp: 1, time: 0)
            let body = CGFloat(phase / (2 * .pi) * perCycle)
            for (i, leg) in walker.legs.enumerated() {
                XCTAssertGreaterThanOrEqual(leg.foot.y, 0, "no foot below the ground")
                if leg.foot.y == 0 {
                    let world = body + leg.foot.x
                    if let before = previous[i] { XCTAssertEqual(world, before, accuracy: 1e-4, "foot \(i) slid at phase \(phase)"); planted += 1 }
                    previous[i] = world
                } else { previous[i] = nil }
            }
        }
        XCTAssertGreaterThan(planted, 1000)
        // Two feet are always down (a trot), so the cat is never off its legs.
        for phase in stride(from: 0.0, to: 2 * .pi, by: 0.05) {
            let down = PetAnimation.walk(phase: phase, amp: 1, time: 0).legs.filter { $0.foot.y == 0 }.count
            XCTAssertGreaterThanOrEqual(down, 2, "phase \(phase)")
        }
    }

    func testAStrollKeepsItsFeetOnTheGroundInTheMiddleOfTheWalk() {
        let steps = [PetAnimation.Step(.walk, 8, to: 0.8)]
        let travel: CGFloat = 100, scale: CGFloat = 0.5
        var previous: [CGFloat?] = [nil, nil, nil, nil]
        var planted = 0
        for u in stride(from: 3.0, to: 5.0, by: 1.0 / 60) {
            let pose = PetAnimation.route(steps, u: u, startX: 0, travel: travel, scale: scale, time: 0, alert: 0)
            XCTAssertGreaterThanOrEqual(pose.legs.map(\.foot.y).min() ?? 0, 0)
            for (i, leg) in pose.legs.enumerated() {
                if leg.foot.y == 0 {
                    // The cat moves in points; its feet are in rig units (a point is 1 / scale units).
                    let world = pose.x / scale + leg.foot.x
                    if let before = previous[i] { XCTAssertEqual(world, before, accuracy: 0.02, "foot \(i) slid at u=\(u)"); planted += 1 }
                    previous[i] = world
                } else { previous[i] = nil }
            }
        }
        XCTAssertGreaterThan(planted, 100)
    }

    func testTurningLeadsWithTheHeadThenTheBodyThenTheLegs() {
        let sit = PetAnimation.sit(time: 2), walker = PetAnimation.walk(phase: 0, amp: 0, time: 2)
        func progress(_ pose: PetPose) -> (head: CGFloat, body: CGFloat, legs: CGFloat) {
            ((pose.head.x - sit.head.x) / (walker.head.x - sit.head.x), (pose.haunch.cx - sit.haunch.cx) / (walker.haunch.cx - sit.haunch.cx),
             (pose.legs[3].foot.x - sit.legs[3].foot.x) / (walker.legs[3].foot.x - sit.legs[3].foot.x))
        }
        var last = (head: CGFloat(0), body: CGFloat(0), legs: CGFloat(0))
        for t in stride(from: 0.05, to: 0.95, by: 0.05) {
            let p = progress(sit.staged(to: walker, CGFloat(t)))
            XCTAssertGreaterThanOrEqual(p.head, p.body - 1e-6, "head ahead of the body at \(t)")
            XCTAssertGreaterThanOrEqual(p.body, p.legs - 1e-6, "body ahead of the legs at \(t)")
            XCTAssertGreaterThanOrEqual(p.head, last.head - 1e-6); XCTAssertGreaterThanOrEqual(p.body, last.body - 1e-6); XCTAssertGreaterThanOrEqual(p.legs, last.legs - 1e-6)
            last = p
        }
        XCTAssertEqual(sit.staged(to: walker, 0).distance(to: sit), 0, accuracy: 1e-9)
        XCTAssertEqual(sit.staged(to: walker, 1).distance(to: walker), 0, accuracy: 1e-9)
        // Sitting down runs the other way round: the legs settle first and the head last.
        let down = walker.staged(to: sit, 0.4, order: .legsFirst), q = progress(down)
        XCTAssertLessThan(q.legs, q.body); XCTAssertLessThan(q.body, q.head)
    }

    func testAStrollTurnsOverMoreThanAThirdOfASecondAndNeverFlipsInAFrame() {
        let steps = PetAnimation.routes[0]
        var previous = PetAnimation.route(steps, u: 0, startX: 0, travel: 100, scale: 0.5, time: 0, alert: 0), worst: CGFloat = 0
        for u in stride(from: 1.0 / 60, through: PetAnimation.length(of: steps), by: 1.0 / 60) {
            let pose = PetAnimation.route(steps, u: u, startX: 0, travel: 100, scale: 0.5, time: u, alert: 0)
            worst = max(worst, pose.distance(to: previous)); previous = pose
        }
        XCTAssertLessThan(worst, 1.5, "no sudden change of pose or orientation at 60 frames a second")
    }

    // MARK: Fixed poses (Reduce Motion, animations off)

    func testAFixedPoseForEachStateWhenMotionIsOff() {
        var player = PetPlayer(layout: .compact, seed: 4)
        let calm = PetAnimation.staticPose(working: false, attention: false)
        XCTAssertEqual(calm, PetPose())
        XCTAssertNotEqual(PetAnimation.staticPose(working: true, attention: false), calm, "on duty: sitting alert")
        XCTAssertNotEqual(PetAnimation.staticPose(working: false, attention: true), calm, "a notice waits: ears forward, looking toward it")
        XCTAssertGreaterThan(PetAnimation.staticPose(working: false, attention: true).look.x, 1)
        XCTAssertEqual(PetAnimation.staticPose(working: true, attention: true), PetAnimation.staticPose(working: false, attention: true), "a notice outranks the rest")
        for i in 0..<400 {
            let t = 100 + Double(i) / 7
            // Whatever happens (pointer, drag, alert, completions, a long idle), the pose depends on the state alone.
            let input = PetInput(working: i % 5 == 0, gaze: i % 3 == 0 ? PetGaze(dx: 1, dy: 1) : nil, dragging: i % 7 == 0, perk: i % 2 == 0 ? 1 : 0, perkAge: 1, completions: i / 50, focus: .typing, idle: 999, needsAttention: i % 11 == 0)
            let pose = player.pose(now: t, layout: i.isMultiple(of: 2) ? .compact() : .header(travel: 100), motion: false, input: input)
            XCTAssertEqual(pose, PetAnimation.staticPose(working: input.working, attention: input.needsAttention), "frame \(i)")
        }
        XCTAssertEqual(player.director.clock, 0, "no clock runs while motion is off")
        XCTAssertNil(player.director.running); XCTAssertNil(player.director.celebration)
    }

    func testViewsHoldAFixedPoseAndNoTimerWhenAnimationsAreOff() {
        let header = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 164, height: 32))
        header.animated = false
        XCTAssertEqual(header.pose, PetPose())
        XCTAssertEqual(header.frameInterval, 0, "a still cat has no timer")
        header.working = true
        XCTAssertEqual(header.pose, PetAnimation.staticPose(working: true, attention: false))
        header.needsAttention = true
        XCTAssertEqual(header.pose, PetAnimation.staticPose(working: true, attention: true))
        XCTAssertEqual(header.frameInterval, 0)

        let model = AppModel(receivesSignals: false)
        model.animations = false
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        pet.injectedModel = model
        XCTAssertEqual(pet.pose, PetPose())
        XCTAssertEqual(pet.frameInterval, 0)
        model.working = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(pet.pose, PetAnimation.staticPose(working: true, attention: false), "the state is told by the pose")
        XCTAssertEqual(pet.frameInterval, 0)
    }

    func testAnimatedViewsKeepNoTimerAtAllWhileTheyCannotBeSeen() {
        let model = AppModel(receivesSignals: false)
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        pet.injectedModel = model
        // No window on screen: no frames, and no slow check either (what brings the island back wakes the cat: `PetSight`).
        XCTAssertEqual(pet.frameInterval, 0)
        XCTAssertEqual(pet.ticks, 0)
        // A header that is in a window that is not on screen.
        let header = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 164, height: 32))
        let window = NSWindow(contentRect: header.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = header
        XCTAssertEqual(header.frameInterval, 0)
        header.wake()
        XCTAssertEqual(header.frameInterval, 0, "told to look again, it still cannot be seen")
        window.contentView = nil
        XCTAssertEqual(header.frameInterval, 0, "and none once it has left its window")
    }

    // MARK: Blending

    func testBlendingEndpointsAndMirroring() {
        let a = PetAnimation.sit(time: 1), b = PetAnimation.walk(phase: 1, amp: 1, time: 1)
        XCTAssertEqual(a.blended(to: b, 0).distance(to: a), 0, accuracy: 1e-9)
        XCTAssertEqual(a.blended(to: b, 1).distance(to: b), 0, accuracy: 1e-9)
        XCTAssertEqual(b.mirrored().mirrored().distance(to: b), 0, accuracy: 1e-9)
        XCTAssertEqual(b.mirrored().facing, -1)
        XCTAssertEqual(b.mirrored().bounds.minX, -b.bounds.maxX, accuracy: 0.001)
        // Lift, hop and glint blend and mirror like everything else; they never flip sides.
        var c = a; c.y = 4; c.sparkle = 0.5
        XCTAssertEqual(c.mirrored().y, 4); XCTAssertEqual(c.mirrored().sparkle, 0.5)
        XCTAssertEqual(a.blended(to: c, 0.5).y, 2, accuracy: 1e-9)
        XCTAssertGreaterThan(c.bounds.maxY, a.bounds.maxY)
    }

    func testGaitFeetNeverGoBackwardsInTheAir() {
        var last: CGFloat = 1
        for p in stride(from: 0.0, to: 1.0, by: 0.01) {
            let ph = p * 2 * .pi + .pi / 2
            let g = PetAnimation.gait(ph)
            if p < 0.5 { XCTAssertLessThanOrEqual(g.swing, last + 1e-9); XCTAssertEqual(g.lift, 0) }
            last = g.swing
        }
        XCTAssertEqual(PetAnimation.gait(0).lift, 1, accuracy: 1e-9, "mid-swing at phase 0, as the old gait")
        XCTAssertEqual(PetAnimation.gait(0).swing, 0, accuracy: 1e-9)
    }

    func testPlayerAnimatesWithoutWindowsAndCostsLittlePerFrame() {
        var player = PetPlayer(layout: .compact, seed: 9)
        let started = Date()
        var pose = PetPose()
        for i in 0..<20000 { pose = player.pose(now: 1000 + Double(i) / 24, layout: .compact(), motion: true, input: PetInput(working: i % 900 < 300, idle: Double(i % 400))) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "a debug build still spends well under 200 microseconds a frame")
        XCTAssertNotEqual(pose, PetPose())
    }
}
