import AppKit
import XCTest
@testable import Nook

/// The sad cat of the question before quitting (`PetSad.swift`): it is the same cat (the same rig, the same painter), drooped: head low, ears down, tail limp, wet eyes and a tear now and
/// then. Its pose is a pure function of the seconds since the question appeared, so everything here is checked as numbers and pixels.
@MainActor
final class PetSadTests: XCTestCase {
    // MARK: The pose

    func testItIsTheSameCatDrooped() {
        let sit = PetAnimation.sit(time: 5)
        let sad = PetAnimation.sad(time: 5)
        XCTAssertEqual(sad.action, .sad)
        XCTAssertLessThan(sad.head.y, sit.head.y - 2, "its head hangs")
        XCTAssertGreaterThan(sad.earL, sit.earL + 0.4, "its ears are down")
        XCTAssertGreaterThan(sad.earR, sit.earR + 0.4)
        XCTAssertLessThan(sad.eyes, sit.eyes, "heavy eyes")
        XCTAssertEqual(sad.glisten, 1, "and wet")
        XCTAssertLessThan(sad.look.y, sit.look.y, "looking down")
        XCTAssertLessThan(sad.tail.p3.y, 4, "the tail lies on the ground, limp")
        XCTAssertLessThan(sad.tail.c2.y, sit.tail.c2.y)
        XCTAssertLessThan(sad.chest.cy, sit.chest.cy, "slumped")
        // Same body: the same ovals and legs as the sit's (it sits, it does not become another animal).
        XCTAssertEqual(sad.legs.nearFront.hip, sit.legs.nearFront.hip)
        XCTAssertEqual(sad.haunch.cy, sit.haunch.cy, accuracy: 0.8)
    }

    func testItDroopsAsTheQuestionComesUpHeadAndEarsFirst() {
        let none = PetAnimation.sad(time: 0, amount: 0)
        XCTAssertEqual(none, PetAnimation.sit(time: 0), "before it droops it is the idle sit")
        var previous = PetAnimation.sad(time: 0, amount: 0).head.y
        for step in 1...20 {
            let amount = CGFloat(step) / 20
            let pose = PetAnimation.sad(time: 0, amount: amount)
            XCTAssertLessThanOrEqual(pose.head.y, previous + 1e-9, "its head only goes down")
            previous = pose.head.y
        }
        // Head and ears lead: a third of the way down, the head is further along than the tail.
        let third = PetAnimation.sad(time: 0, amount: 0.34), full = PetAnimation.sad(time: 0, amount: 1), sit = PetAnimation.sit(time: 0)
        let headDone = (sit.head.y - third.head.y) / (sit.head.y - full.head.y)
        let tailDone = (sit.tail.p3.y - third.tail.p3.y) / (sit.tail.p3.y - full.tail.p3.y)
        XCTAssertGreaterThan(headDone, tailDone + 0.1, "the head leads and the tail follows")
    }

    func testTheEntranceIsAnEaseInThenHolds() {
        XCTAssertEqual(PetAnimation.sadAmount(at: 0), 0)
        XCTAssertEqual(PetAnimation.sadAmount(at: 0.1), 0, accuracy: 1e-9, "a beat of waiting")
        XCTAssertEqual(PetAnimation.sadAmount(at: 0.1 + PetAnimation.sadEntrance), 1, accuracy: 1e-9)
        XCTAssertEqual(PetAnimation.sadAmount(at: 30), 1)
        var last = 0.0
        for step in 0...100 {
            let amount = Double(PetAnimation.sadAmount(at: Double(step) / 50))
            XCTAssertGreaterThanOrEqual(amount, last); last = amount
        }
    }

    func testItCriesOneTearAtATimeAndNotAtOnce() {
        XCTAssertEqual(PetAnimation.tearProgress(at: 0), 0)
        XCTAssertEqual(PetAnimation.tearProgress(at: PetAnimation.tearFirst - 0.01), 0, "the first well up comes a moment in")
        XCTAssertEqual(PetAnimation.tearProgress(at: PetAnimation.tearFirst + PetAnimation.tearLength / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PetAnimation.tearProgress(at: PetAnimation.tearFirst + PetAnimation.tearLength + 0.5), 0, "then none for a while")
        let second = PetAnimation.tearFirst + PetAnimation.tearEvery + PetAnimation.tearLength / 2
        XCTAssertEqual(PetAnimation.tearProgress(at: second), 0.5, accuracy: 1e-9, "and another")
        let moments = stride(from: 0.0, to: 60, by: 0.05).map { PetAnimation.tearProgress(at: $0) }
        XCTAssertLessThan(Double(moments.filter { $0 > 0 }.count) / Double(moments.count), 0.4, "it is not crying all the time")
        XCTAssertGreaterThan(moments.filter { $0 > 0 }.count, 20)
        XCTAssertTrue(moments.allSatisfy { (0...1).contains($0) })
    }

    func testTheSadCatBreathesBlinksAndSighsSlowly() {
        let times = stride(from: 0.0, to: 40, by: 0.05).map { $0 }
        let poses = times.map { PetAnimation.sad(time: $0) }
        XCTAssertGreaterThan(poses.map(\.eyes).max()! - poses.map(\.eyes).min()!, 0.5, "a long blink now and then")
        XCTAssertGreaterThan(poses.map(\.mouth).max() ?? 0, 0.1, "a sigh")
        XCTAssertLessThan(poses.map(\.mouth).max() ?? 1, 0.3, "a small one")
        // Slow: no frame at 20 a second moves the picture by more than a little, at the island's scale. (The tear's number goes back to 0 when it has run its course, after it has
        // faded to nothing: that jump is not one the picture shows.)
        var worst: CGFloat = 0
        for (a, b) in zip(poses, poses.dropFirst()) {
            var before = a, after = b
            before.tear = 0; after.tear = 0
            worst = max(worst, after.displacement(to: before, scale: 3))
        }
        XCTAssertLessThan(worst, 2.2, "the sad cat moves calmly (\(worst) points a frame at 3 points a unit)")
        // And the tear itself runs smoothly, and is gone (faded) by the time its number starts again.
        for (a, b) in zip(times, times.dropFirst()) {
            let before = PetAnimation.tearProgress(at: a), after = PetAnimation.tearProgress(at: b)
            if after >= before { XCTAssertLessThan(after - before, 0.05) } else { XCTAssertGreaterThan(before, 0.97, "it only starts over when it has run its whole way") }
        }
    }

    func testEverythingItDrawsIsInsideTheRoomACatHas() {
        for t in stride(from: 0.0, to: 60, by: 0.1) {
            let pose = PetAnimation.sad(time: t, amount: PetAnimation.sadAmount(at: t))
            let b = pose.bounds
            XCTAssertGreaterThanOrEqual(b.minX, -PetAnimation.reach.left - 1)
            XCTAssertLessThanOrEqual(b.maxX, PetAnimation.reach.right + 1)
            XCTAssertGreaterThanOrEqual(b.minY, -1)
            XCTAssertLessThanOrEqual(b.maxY, 34)
            for value in [pose.head.x, pose.head.y, pose.eyes, pose.tear, pose.glisten, pose.mouth, pose.tail.p3.x, pose.tail.p3.y] { XCTAssertTrue(value.isFinite) }
        }
    }

    func testTheNewNumbersBlendAndAreComparedLikeTheOthers() {
        var a = PetPose(), b = PetPose()
        b.tear = 1; b.glisten = 1
        let halfway = a.blended(to: b, 0.5)
        XCTAssertEqual(halfway.tear, 0.5); XCTAssertEqual(halfway.glisten, 0.5)
        XCTAssertGreaterThan(a.displacement(to: b, scale: 3), 3, "a tear is a change the picture shows")
        a.tear = 0.5
        XCTAssertNotEqual(a, PetPose())
    }

    // MARK: The painting

    /// Paints `pose` at `scale` on black and says how many pixels are bluish (the tear's colour) and how many are bright.
    private func paint(_ pose: PetPose, scale: CGFloat = 4) -> (blue: Int, bright: Int, image: CGImage) {
        let width = 150, height = 150
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 90, y: 4); cg.scaleBy(x: scale, y: scale)
        PetPainter.draw(pose, in: cg)
        let data = cg.data!.assumingMemoryBound(to: UInt8.self)
        var blue = 0, bright = 0
        for i in 0..<(width * height) {
            let r = Int(data[i * 4]), g = Int(data[i * 4 + 1]), b = Int(data[i * 4 + 2])
            if b > 200 && b > r + 40 && g > r + 20 { blue += 1 }
            if r > 200 && g > 200 && b > 200 { bright += 1 }
        }
        return (blue, bright, cg.makeImage()!)
    }

    func testTheTearIsDrawnInItsColourAndOnlyWhenItRuns() {
        var pose = PetAnimation.sad(time: 0.5)
        pose.tear = 0
        XCTAssertEqual(paint(pose).blue, 0, "no tear, nothing bluish")
        pose.tear = 0.5
        XCTAssertGreaterThan(paint(pose).blue, 6, "the drop on its cheek")
        pose.tear = 0.995
        XCTAssertLessThan(paint(pose).blue, paint(PetAnimation.sad(time: 0.5, amount: 1).withTear(0.5)).blue, "it fades out before the chin")
    }

    func testTheTearStaysOnTheFace() {
        for progress in stride(from: 0.05, through: 1.0, by: 0.05) {
            var pose = PetAnimation.sad(time: 0.5)
            pose.tear = CGFloat(progress)
            let image = paint(pose)
            XCTAssertGreaterThan(image.bright, 200, "the cat is there at \(progress)")
        }
    }

    func testWetEyesShowAGlint() {
        var dry = PetAnimation.sad(time: 0.5)
        dry.glisten = 0; dry.tear = 0
        var wet = dry
        wet.glisten = 1
        let a = paint(dry), b = paint(wet)
        XCTAssertGreaterThan(b.bright, a.bright, "the glints add white inside the eyes")
        XCTAssertLessThan(b.bright - a.bright, 60, "small ones")
    }

    /// The mouth is still painted in black after the tear and the glints (they leave the painter's colour as they found it).
    func testTheTearAndTheGlintsLeaveTheMouthBlack() {
        var pose = PetAnimation.sad(time: 0.5)
        pose.tear = 0.5; pose.mouth = 0.8
        let image = paint(pose)
        // Nothing in the middle of the face under the nose is bluish or white beyond the tear's own pixels: the count of bluish pixels is the tear's alone.
        var withoutMouth = pose
        withoutMouth.mouth = 0
        XCTAssertEqual(image.blue, paint(withoutMouth).blue, "the open mouth is not painted in the tear's colour")
    }

    func testPaintingTheSadCatLeavesTheContextAsItFoundIt() {
        let cg = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let before = cg.ctm
        var pose = PetAnimation.sad(time: 0.5)
        pose.tear = 0.4
        PetPainter.draw(pose, in: cg)
        XCTAssertEqual(cg.ctm, before)
    }

    // MARK: The views

    /// With Reduce Motion or the animations off the sad cat holds a drooped pose with a tear on its cheek, and keeps no timer.
    func testAStillSadCatHoldsItsPoseWithNoTimer() {
        let view = SadCatView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        view.animated = false
        XCTAssertEqual(view.pose, SadCatView.restingPose)
        XCTAssertEqual(view.pose.action, .sad)
        XCTAssertGreaterThan(view.pose.tear, 0.2)
        XCTAssertEqual(view.frameInterval, 0)
        view.wake()
        XCTAssertEqual(view.frameInterval, 0)
    }

    func testTheSadCatTakesNoClicks() {
        let view = SadCatView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
        XCTAssertNil(view.hitTest(NSPoint(x: 60, y: 50)))
    }
}

private extension PetPose {
    func withTear(_ tear: CGFloat) -> PetPose {
        var copy = self
        copy.tear = tear
        return copy
    }
}
