import AppKit
import XCTest
@testable import Nook

/// What each new thing the cat does is, in numbers: it starts and ends at the sit (so the director can chain them), it does what it says
/// (the mouth opens wide, the leg comes up to the ear and scratches, the speck is chased and pounced on), and it stays where it can be drawn.
@MainActor
final class PetBehaviorTests: XCTestCase {
    private func times(_ span: Double, step: Double = 1.0 / 60) -> StrideThrough<Double> { stride(from: 0, through: span, by: step) }
    private let rest = PetAnimation.sit(time: 5)

    // MARK: Every gesture comes from the sit and goes back to it

    func testEveryGestureStartsAndEndsAtTheSit() {
        let cases: [(String, Double, (Double) -> PetPose)] = [
            ("yawn", PetAnimation.yawnLength, { PetAnimation.yawn(u: $0, time: 5) }),
            ("scratch", PetAnimation.scratchLength, { PetAnimation.scratch(u: $0, time: 5) }),
            ("startle right", PetAnimation.startleLength, { PetAnimation.startle(u: $0, time: 5, variant: 0) }),
            ("startle left", PetAnimation.startleLength, { PetAnimation.startle(u: $0, time: 5, variant: 1) }),
            ("tail play", PetAnimation.tailPlayLength, { PetAnimation.tailPlay(u: $0, time: 5) }),
            ("groom the paw", PetAnimation.groomLength, { PetAnimation.groom(u: $0, time: 5, variant: 0) }),
            ("groom the chest", PetAnimation.groomLength, { PetAnimation.groom(u: $0, time: 5, variant: 1) }),
            ("glance round", PetAnimation.glanceLength, { PetAnimation.glance(u: $0, time: 5, variant: 0) }),
            ("listen right", PetAnimation.glanceLength, { PetAnimation.glance(u: $0, time: 5, variant: 1) }),
            ("listen left", PetAnimation.glanceLength, { PetAnimation.glance(u: $0, time: 5, variant: 2) }),
            ("look up", PetAnimation.glanceLength, { PetAnimation.glance(u: $0, time: 5, variant: 3) }),
            ("loaf", 12, { PetAnimation.loafing(u: $0, length: 12, time: 5, variant: 0) }),
            ("loaf facing left", 12, { PetAnimation.loafing(u: $0, length: 12, time: 5, variant: 0, facing: -1) }),
            ("knead", 18, { PetAnimation.loafing(u: $0, length: 18, time: 5, variant: 1) }),
            ("hunt caught", PetAnimation.huntLength(variant: 0), { PetAnimation.hunt(u: $0, length: PetAnimation.huntLength(variant: 0), time: 5, variant: 0) }),
            ("hunt missed", PetAnimation.huntLength(variant: 1), { PetAnimation.hunt(u: $0, length: PetAnimation.huntLength(variant: 1), time: 5, variant: 1) }),
            ("hunt facing left", PetAnimation.huntLength(variant: 0), { PetAnimation.hunt(u: $0, length: PetAnimation.huntLength(variant: 0), time: 5, variant: 0, facing: -1) }),
            ("stretch", 7, { PetAnimation.perform(.stretch, u: $0, length: 7, time: 5, alert: 0) }),
            ("stretch facing left", 7, { PetAnimation.perform(.stretch, u: $0, length: 7, time: 5, facing: -1, alert: 0) }),
            ("nap", 40, { PetAnimation.perform(.sleep, u: $0, length: 40, time: 5, alert: 0) }),
            ("celebrate hop", PetAnimation.cheerLength(.hop), { PetAnimation.celebrate(u: $0, time: 5, style: .hop) }),
            ("celebrate twice", PetAnimation.cheerLength(.doubleHop), { PetAnimation.celebrate(u: $0, time: 5, style: .doubleHop) }),
            ("celebrate content", PetAnimation.cheerLength(.content), { PetAnimation.celebrate(u: $0, time: 5, style: .content) }),
        ]
        for (name, length, pose) in cases {
            XCTAssertLessThan(pose(0).distance(to: rest), 0.06, "\(name) starts from the sit")
            XCTAssertLessThan(pose(length).distance(to: rest), 0.06, "\(name) ends in it")
        }
    }

    // MARK: Yawn

    func testTheYawnOpensTheMouthWideSqueezesTheEyesAndFlattensTheEars() {
        var mouthOpen = 0.0, eyesShut = 0.0, widest: CGFloat = 0, narrowest: CGFloat = 1, ears: CGFloat = 0, lift: CGFloat = 0, opened: Double?, closed: Double?
        for u in times(PetAnimation.yawnLength) {
            let p = PetAnimation.yawn(u: u, time: 5)
            XCTAssertEqual(p.action, .yawn)
            if p.mouth > 0.8 { mouthOpen += 1.0 / 60 }
            if p.eyes < 0.2 { eyesShut += 1.0 / 60 }
            widest = max(widest, p.mouth); narrowest = min(narrowest, p.eyes); ears = max(ears, p.earL); lift = max(lift, p.head.y - rest.head.y)
            if opened == nil, p.mouth > 0.5 { opened = u }
            if opened != nil, closed == nil, p.mouth < 0.5 { closed = u }
        }
        XCTAssertGreaterThan(widest, 0.9, "wide open"); XCTAssertGreaterThan(mouthOpen, 1.0, "and held there for a moment")
        XCTAssertLessThan(narrowest, 0.1); XCTAssertGreaterThan(eyesShut, 1.2, "eyes squeezed shut")
        XCTAssertGreaterThan(ears, 0.25, "ears back"); XCTAssertGreaterThan(lift, 1.2, "the head tips up")
        XCTAssertLessThan(opened ?? 99, 1.0, "it takes about half a second to open"); XCTAssertGreaterThan(closed ?? 0, 2.2)
        // And one shake of the head at the end.
        let shake = times(0.6).map { PetAnimation.yawn(u: 3.0 + $0, time: 5).tilt }
        XCTAssertGreaterThan(shake.max()! - shake.min()!, 0.1)
    }

    // MARK: Scratch

    func testTheScratchBringsAHindLegToTheEarAndScratchesFast() {
        var raised = 0.0, turns = 0, last: CGFloat = 0, rising = false, tilt: CGFloat = 0
        for u in times(PetAnimation.scratchLength, step: 1.0 / 240) {
            let p = PetAnimation.scratch(u: u, time: 5)
            XCTAssertEqual(p.action, .scratch)
            let foot = p.legs[2].foot
            if foot.y > PetAnimation.raisedAbove { raised += 1.0 / 240 }
            if u > 0.8, u < 1.6 {
                if foot.y > last + 1e-6 { rising = true } else if foot.y < last - 1e-6, rising { turns += 1; rising = false }
            }
            last = foot.y
            tilt = min(tilt, p.tilt)
            // The other three legs stay put.
            XCTAssertEqual(p.legs[3], rest.legs[3]); XCTAssertEqual(p.legs[1], rest.legs[1])
        }
        XCTAssertGreaterThan(raised, 1.4, "the leg is up beside the ear for most of it (drawn over the head, with its seam)")
        XCTAssertGreaterThan(turns, 4, "and it moves quickly: \(turns) strokes in 0.8 s")
        XCTAssertLessThan(tilt, -0.2, "the head tips toward the leg")
    }

    // MARK: Startle

    func testAStartleIsAHopWithAPuffedTailThenAGlanceTowardTheNoise() {
        for variant in [0, 1] {
            var peak: CGFloat = 0, puff: CGFloat = 0, turned: CGFloat = 0
            for u in times(PetAnimation.startleLength) {
                let p = PetAnimation.startle(u: u, time: 5, variant: variant)
                peak = max(peak, p.y); puff = max(puff, p.tail.width - rest.tail.width)
                if abs(p.look.x) > abs(turned) { turned = p.look.x }
            }
            XCTAssertGreaterThan(peak, 2.2); XCTAssertLessThan(peak, 3.5, "a small start")
            XCTAssertGreaterThan(puff, 1.4, "the tail puffs")
            XCTAssertEqual(turned > 0, variant == 0, "it looks to the side of the noise")
            XCTAssertGreaterThan(abs(turned), 1.5)
            XCTAssertEqual(PetAnimation.startle(u: PetAnimation.startleLength, time: 5, variant: variant).tail.width, rest.tail.width, accuracy: 0.05, "the puff has gone down")
        }
        let flat = PetAnimation.startle(u: 0.18, time: 5)
        XCTAssertGreaterThan(flat.earL, rest.earL + 0.2); XCTAssertGreaterThan(flat.eyes, 1.15, "ears flat, eyes wide, in the first instant")
    }

    // MARK: Tail play

    func testTheTailComesRoundToTheFrontAndTheCatSwatsAtItsTip() {
        var farthest: CGFloat = -99, swats = 0, rising = false, last: CGFloat = 0, headDown: CGFloat = 0
        for u in times(PetAnimation.tailPlayLength, step: 1.0 / 120) {
            let p = PetAnimation.tailPlay(u: u, time: 5)
            farthest = max(farthest, p.tail.p3.x)
            if p.legs[3].foot.y > last + 1e-6 { rising = true } else if p.legs[3].foot.y < last - 1e-6, rising, last > 4 { swats += 1; rising = false }
            last = p.legs[3].foot.y
            headDown = min(headDown, p.head.y - rest.head.y)
        }
        XCTAssertGreaterThan(farthest, 9, "the tip is on the far side of the body: it has come round the front")
        XCTAssertEqual(swats, 2, "two swats of the near paw")
        XCTAssertLessThan(headDown, -1, "the cat looks down at it")
    }

    // MARK: Loaf and knead

    func testALoafLiesDownWithHalfClosedEyesAndKneadingAlternatesTheFrontPaws() {
        let plain = PetAnimation.loafing(u: 6, length: 12, time: 5, variant: 0)
        XCTAssertLessThan(plain.head.y, rest.head.y - 8, "down on its belly")
        XCTAssertLessThan(plain.eyes, 0.95); XCTAssertEqual(plain.action, .loaf)
        var plainMax: CGFloat = 0
        for u in times(12) { let p = PetAnimation.loafing(u: u, length: 12, time: 5, variant: 0); plainMax = max(plainMax, p.legs[1].foot.y, p.legs[3].foot.y) }
        XCTAssertLessThan(plainMax, 3.1, "no kneading in the plain loaf")
        var far = [CGFloat](), near = [CGFloat]()
        for u in stride(from: 6.0, through: 12, by: 1.0 / 30) {
            let p = PetAnimation.loafing(u: u, length: 18, time: 5, variant: 1)
            far.append(p.legs[1].foot.y); near.append(p.legs[3].foot.y)
        }
        XCTAssertGreaterThan(far.max()! - far.min()!, 2.2, "the far paw presses"); XCTAssertGreaterThan(near.max()! - near.min()!, 2.2, "and the near one")
        // In turn: when one is up the other is down.
        let meanFar = far.reduce(0, +) / CGFloat(far.count), meanNear = near.reduce(0, +) / CGFloat(near.count)
        let covariance = zip(far, near).map { ($0 - meanFar) * ($1 - meanNear) }.reduce(0, +) / CGFloat(far.count)
        XCTAssertLessThan(covariance, -0.2, "alternately")
        // Facing left it is the mirror of facing right.
        let a = PetAnimation.loafing(u: 6, length: 12, time: 5, variant: 0, facing: 1), b = PetAnimation.loafing(u: 6, length: 12, time: 5, variant: 0, facing: -1)
        XCTAssertEqual(b.head.x, -a.head.x, accuracy: 0.01)
    }

    // MARK: Hunt

    func testTheHuntWatchesCrouchesWigglesAndPounces() {
        let d = PetAnimation.huntLength(variant: 0)
        func at(_ u: Double, variant: Int = 0, facing: CGFloat = 1) -> PetPose { PetAnimation.hunt(u: u, length: PetAnimation.huntLength(variant: variant), time: 5, variant: variant, facing: facing) }
        // The speck appears, flutters on the right at the height of the head, and the cat follows it with eyes and head.
        XCTAssertEqual(at(0).moteSize, 0); XCTAssertEqual(at(1.2).moteSize, 1, accuracy: 0.001)
        var xs = [CGFloat](), looks = [CGFloat]()
        for u in stride(from: 1.0, through: 3.0, by: 0.05) { let p = at(u); xs.append(p.mote.x); looks.append(p.look.x) }
        XCTAssertGreaterThan(xs.min()!, 11, "the speck stays clear of the cat")
        XCTAssertLessThan(xs.max()!, 19, "and inside the wing")
        XCTAssertGreaterThan(looks.min()!, 0.5, "the pupils are on the right, where the speck is")
        XCTAssertLessThan(at(2).earL, rest.earL - 0.1, "ears pointing at it")
        // It lands low in front of the nose; the cat crouches: the head is low and level, the chest down, the eyes huge.
        let crouched = at(5.0)
        XCTAssertLessThan(crouched.head.y, 11); XCTAssertGreaterThan(crouched.eyes, 1.1)
        XCTAssertEqual(crouched.mote.y, 2.5, accuracy: 0.8); XCTAssertEqual(crouched.action, .hunt)
        // The rear wiggles from side to side before the spring.
        let wiggle = stride(from: 5.6, through: 6.6, by: 1.0 / 60).map { at($0).haunch.cx }
        XCTAssertGreaterThan(wiggle.max()! - wiggle.min()!, 1.2)
        // The pounce: a small arc forward with the front paws out.
        var peak: CGFloat = 0, reach: CGFloat = 0
        for u in stride(from: 6.5, through: 8.0, by: 1.0 / 60) { let p = at(u); peak = max(peak, p.y); reach = max(reach, p.legs[3].foot.x) }
        XCTAssertGreaterThan(peak, 3); XCTAssertLessThan(peak, 4, "an arc of about two points")
        XCTAssertGreaterThan(reach, 16.5, "the front paws are thrown forward")
        // Caught: the speck is gone under the paws and stays gone; the cat looks round, pleased, and sits up again.
        XCTAssertEqual(at(7.4).moteSize, 0, accuracy: 0.001); XCTAssertEqual(at(d - 0.1).moteSize, 0)
        XCTAssertLessThan(at(8.7).eyes, 0.6, "a slow blink once it has it")
        // Missed: it darts away up and to the right, still in sight a moment later, and the cat follows it with its head.
        let miss = at(7.4, variant: 1)
        XCTAssertGreaterThan(miss.moteSize, 0.5); XCTAssertGreaterThan(miss.mote.y, 8)
        XCTAssertGreaterThan(at(7.5, variant: 1).look.y, 0.7, "looking up after it")
        XCTAssertEqual(at(9.7, variant: 1).moteSize, 0)
        // Facing left it is all the other way round, from the same sit.
        let left = at(5, facing: -1)
        XCTAssertEqual(left.head.x, -crouched.head.x, accuracy: 0.01); XCTAssertEqual(left.mote.x, -crouched.mote.x, accuracy: 0.01)
        XCTAssertEqual(at(1.2, facing: -1).look.x, -at(1.2).look.x, accuracy: 0.01, "it watches the speck on its other side")
    }

    // MARK: Stretch, nap and cheers

    func testAStretchBowsThenArchesItsBackAndComesBackToTheSit() {
        let d = 7.0
        func at(_ u: Double) -> PetPose { PetAnimation.perform(.stretch, u: u, length: d, time: 5, alert: 0) }
        let bow = at(2.5), arch = at(d - 2.5)
        XCTAssertLessThan(bow.head.y, 9, "the front end is down in the bow"); XCTAssertGreaterThan(bow.haunch.cy, 13, "and the rear up")
        XCTAssertGreaterThan(arch.chest.cy, bow.chest.cy + 4, "the arch lifts the whole back"); XCTAssertLessThan(arch.tilt, -0.25, "with the head tucked")
        XCTAssertEqual(arch.legs[3].foot.y, 0.2, accuracy: 0.5, "standing on straight legs")
        let hook = PetAnimation.arch(time: 5)
        XCTAssertLessThan(hook.tail.p3.y, 6, "the tail hangs in a hook")
        // The order of it.
        var bowedAt: Double?, archedAt: Double?
        for u in times(d, step: 0.05) {
            let p = at(u)
            if bowedAt == nil, p.head.y < 9, p.haunch.cy > 13 { bowedAt = u }
            if archedAt == nil, p.chest.cy > 14.5, p.tilt < -0.25 { archedAt = u }
        }
        XCTAssertNotNil(bowedAt); XCTAssertNotNil(archedAt); XCTAssertLessThan(bowedAt!, archedAt!, "first the bow, then the arch")
    }

    func testANapCurlsUpBreathesSlowlyAndDreams() {
        let d = 60.0
        func at(_ u: Double) -> PetPose { PetAnimation.perform(.sleep, u: u, length: d, time: 100 + u, alert: 0) }
        let asleep = at(25)
        XCTAssertGreaterThan(asleep.tail.p3.x, 10, "the tail has come round the front of its face")
        XCTAssertLessThan(asleep.eyes, 0.05); XCTAssertGreaterThan(asleep.zAlpha, 0.9)
        // Slow breathing: about one breath in 6 or 7 seconds.
        let mean = stride(from: 10.0, through: 50, by: 0.1).map { at($0).chest.ry }.reduce(0, +) / 401
        var crossings = [Double](), previous: CGFloat?
        for u in stride(from: 10.0, through: 50, by: 0.05) {
            let v = at(u).chest.ry - mean
            if let previous, previous <= 0, v > 0 { crossings.append(u) }
            previous = v
        }
        XCTAssertGreaterThan(crossings.count, 3)
        let period = (crossings.last! - crossings.first!) / Double(crossings.count - 1)
        XCTAssertEqual(period, 2 * .pi / 0.95, accuracy: 0.8, "a breath every \(period) s")
        // Now and then an ear (and a paw) twitch: a dream. A sleeper's ear lies back at about 0.35.
        var twitches = 0, inside = false
        for u in stride(from: 12.0, through: 48, by: 1.0 / 60) {
            if at(u).earR < 0.2 { if !inside { twitches += 1 }; inside = true } else { inside = false }
        }
        XCTAssertGreaterThanOrEqual(twitches, 3, "it dreams: \(twitches) twitches in half a minute")
    }

    func testEachWayOfCheeringIsItsOwn() {
        func heights(_ style: PetCheer) -> [CGFloat] { stride(from: 0.0, through: PetAnimation.cheerLength(style), by: 1.0 / 60).map { PetAnimation.celebrate(u: $0, time: 5, style: style).y } }
        func peaks(_ ys: [CGFloat]) -> [CGFloat] {
            var result = [CGFloat](), last: CGFloat = 0, rising = false
            for y in ys { if y > last + 1e-6 { rising = true } else if y < last - 1e-6, rising { result.append(last); rising = false }; last = y }
            return result
        }
        XCTAssertEqual(peaks(heights(.hop)).count, 1)
        let double = peaks(heights(.doubleHop))
        XCTAssertEqual(double.count, 2, "two hops"); XCTAssertGreaterThan(double[1], double[0], "the second one higher")
        XCTAssertEqual(heights(.content).max(), 0, "the content one stays on the ground")
        let content = stride(from: 0.0, through: PetAnimation.cheerLength(.content), by: 0.05).map { PetAnimation.celebrate(u: $0, time: 5, style: .content) }
        XCTAssertGreaterThan(content.map { $0.tail.p3.y }.max()!, 22, "its tail rises in a curl")
        XCTAssertLessThan(content.map(\.eyes).min()!, 0.4, "a squint of pleasure")
        XCTAssertGreaterThan(content.map(\.sparkle).max()!, 0.5)
        XCTAssertEqual([PetCheer.hop, .doubleHop, .content].map { PetAnimation.cheerLength($0) }, [1.25, 2.0, 2.3])
        XCTAssertEqual(PetDirector.cheer(for: .curious), .hop); XCTAssertEqual(PetDirector.cheer(for: .playful), .doubleHop)
        XCTAssertEqual(PetDirector.cheer(for: .calm), .content); XCTAssertEqual(PetDirector.cheer(for: .sleepy), .content)
    }

    // MARK: The pointer, an alert

    func testALingeringPointerGetsASlowBlinkNowAndThenButAStareDoesNot() {
        func eyes(_ age: Double, sniff: Bool = true) -> CGFloat { PetAnimation.curious(rest, gaze: PetGaze(dx: 0.6, dy: 0), amount: 1, age: age, sniff: sniff).eyes }
        let before = stride(from: 0.4, to: PetAnimation.slowBlinkAfter, by: 0.05).map { eyes($0) }
        XCTAssertGreaterThan(before.min()!, 0.7, "nothing but the sniffs before it has been there a while")
        let first = stride(from: PetAnimation.slowBlinkAfter, through: PetAnimation.slowBlinkAfter + 1.6, by: 0.02).map { eyes($0) }
        XCTAssertLessThan(first.min()!, 0.2, "the lids come down"); XCTAssertGreaterThan(first.last!, 0.9, "and rise again")
        // Slowly: it takes the better part of a second to close and the same to open.
        let closed = first.firstIndex { $0 < 0.2 }!
        XCTAssertGreaterThan(Double(closed) * 0.02, 0.3, "not a flick")
        XCTAssertLessThan(eyes(PetAnimation.slowBlinkAfter + PetAnimation.slowBlinkEvery + 0.5), 0.3, "and again, every few seconds")
        XCTAssertGreaterThan(stride(from: 3.0, through: 12, by: 0.05).map { eyes($0, sniff: false) }.min()!, 0.9, "a cat that is dragged stares: it does not blink at you")
    }

    func testTheMewIsAShortOpenMouthAsTheCatLooksUpAndAStrollerStaysWhereItWas() {
        var base = PetAnimation.sit(time: 5); base.x = 47
        var widest: CGFloat = 0, openUntil = 0.0
        for age in stride(from: 0.0, through: 1.2, by: 1.0 / 60) {
            let p = PetAnimation.perked(from: base, time: 5, amount: 1, age: age)
            widest = max(widest, p.mouth); if p.mouth > 0.05 { openUntil = age }
            XCTAssertEqual(p.x, 47, accuracy: 0.001, "an alert does not walk the cat home")
        }
        XCTAssertGreaterThan(widest, 0.4); XCTAssertLessThan(widest, 0.6, "a small mew, not a yawn")
        XCTAssertLessThan(openUntil, 0.8)
        XCTAssertEqual(PetAnimation.perked(from: base, time: 5, amount: 1, age: 3).mouth, 0, "over")
    }

    // MARK: The pose itself

    func testALegsValueIsFourLimbsAndBlendsLikeAnythingElse() {
        var legs = PetPose().legs
        XCTAssertEqual(legs.count, 4); XCTAssertEqual(legs.indices, 0..<4)
        legs[2].foot.y = 9
        XCTAssertEqual(legs[2].foot.y, 9); XCTAssertEqual(legs.nearHind.foot.y, 9)
        XCTAssertEqual(legs.map(\.width), [3, 3.8, 3, 3.8])
        let literal: PetLegs = [PetLimb(x: 0, hip: 1, foot: 0), PetLimb(x: 1, hip: 1, foot: 0), PetLimb(x: 2, hip: 1, foot: 0), PetLimb(x: 3, hip: 1, foot: 0)]
        XCTAssertEqual(literal[3].hip.x, 3)
        XCTAssertEqual(literal.filter { $0.foot.y == 0 }.count, 4)
        var a = PetPose(), b = PetPose()
        a.legs[3].foot.x = 0; b.legs[3].foot.x = 10
        XCTAssertEqual(a.blended(to: b, 0.5).legs[3].foot.x, 5, accuracy: 1e-9)
        XCTAssertEqual(MemoryLayout<PetPose>.size, MemoryLayout<PetPose>.stride, "a pose is plain values: copying it allocates nothing")
    }

    func testASpeckThatIsNotThereHasNoPlaceToSlideFrom() {
        var seen = PetPose(); seen.mote = CGPoint(x: 15, y: 3); seen.moteSize = 1
        var gone = PetPose(); gone.moteSize = 0
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let fadingIn = gone.blended(to: seen, CGFloat(t)), fadingOut = seen.blended(to: gone, CGFloat(t))
            if t > 0 { XCTAssertEqual(fadingIn.mote, seen.mote, "it appears where it is") }
            if t < 1 { XCTAssertEqual(fadingOut.mote, seen.mote, "and goes where it was") }
        }
        XCTAssertEqual(gone.distance(to: seen), 1, accuracy: 1e-9, "only its size is different: where it is does not count while it is not there")
        XCTAssertEqual(PetPose().displacement(to: PetPose(), scale: 0.6), 0)
    }

    func testDisplacementIsHowFarThePictureMovesInPoints() {
        var a = PetPose(), b = PetPose()
        b.legs[3].foot.x += 10
        XCTAssertEqual(a.displacement(to: b, scale: 0.6), 6, accuracy: 1e-9, "ten units at 0.6 points a unit")
        b = PetPose(); b.x = 3
        XCTAssertEqual(a.displacement(to: b, scale: 0.5), 3, accuracy: 1e-9, "x is already in points")
        b = PetPose(); b.eyes = 0
        XCTAssertGreaterThan(a.displacement(to: b, scale: 0.6), 0.9, "a blink is seen")
        b = PetPose(); b.earL = 0.3
        XCTAssertEqual(a.displacement(to: b, scale: 0.6), 0.3 * 8 * 0.6, accuracy: 1e-9, "an angle is how far the tip of the ear goes")
        a.moteSize = 1; b = PetPose(); b.moteSize = 0
        XCTAssertGreaterThan(a.displacement(to: b, scale: 0.6), 0.5, "a speck appearing is a change")
    }
}
