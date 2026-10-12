import AppKit
import XCTest
@testable import Nook

/// The cat that sleeps when Nook opens at night, and wakes gently (`PetWake.swift`): the state (asleep at launch only at night, woken by a click or the lights coming on, never put back to
/// sleep), the director holding it in bed and waking it, the beats of the waking pose, and every cat's view following the same bedtime. The clock is the test's own.
@MainActor
final class PetWakeTests: XCTestCase {
    // MARK: The bedtime

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private func date(hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: hour, minute: 30))! }

    private final class Clock { var now = 1_000.0 }

    private func bedtime(_ clock: Clock) -> PetBedtime { PetBedtime(clock: { clock.now }) }

    func testItIsNightWhereThePetSystemSaysItIs() {
        for hour in [23, 0, 1, 3, 5] { XCTAssertTrue(PetBedtime.isNight(date(hour: hour), calendar: calendar), "\(hour) h") }
        for hour in [6, 9, 12, 17, 18, 22] { XCTAssertFalse(PetBedtime.isNight(date(hour: hour), calendar: calendar), "\(hour) h") }
        for hour in 0..<24 {
            XCTAssertEqual(PetBedtime.isNight(date(hour: hour), calendar: calendar), PetDayPart.of(hour: hour) == .night, "the same night as the director's")
        }
    }

    func testStartingAtNightPutsTheCatToBedAndStartingByDayDoesNot() {
        let clock = Clock(), bed = bedtime(clock)
        XCTAssertFalse(bed.isAsleep, "a bedtime starts awake: only the running app puts the cat to bed")
        bed.launch(at: date(hour: 23), calendar: calendar)
        XCTAssertTrue(bed.isAsleep)
        bed.launch(at: date(hour: 14), calendar: calendar)
        XCTAssertFalse(bed.isAsleep)
        XCTAssertFalse(bed.click(), "a cat that is up has nothing to wake")
        XCTAssertEqual(bed.wakes, 0)
    }

    func testAClickWakesItOnceAndForGood() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 2), calendar: calendar)
        clock.now += 30
        XCTAssertTrue(bed.click())
        XCTAssertFalse(bed.isAsleep)
        XCTAssertEqual(bed.wakes, 1)
        XCTAssertEqual(bed.wokeAt, clock.now)
        XCTAssertEqual(bed.reason, .click)
        XCTAssertFalse(bed.click(), "awake, a click wakes nothing")
        XCTAssertEqual(bed.wakes, 1)
        // Time passing, the hour, the light: nothing puts it back.
        clock.now += 86_400
        bed.lights(dark: true); bed.lights(dark: false); bed.lights(dark: true)
        XCTAssertFalse(bed.isAsleep, "once woken it stays awake")
    }

    func testTheLightsComingOnWakeItAndTheLightsGoingOutNeverPutItToSleep() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        bed.lights(dark: true)           // the island is dark: how it is
        clock.now += 60
        bed.lights(dark: true)
        XCTAssertTrue(bed.isAsleep, "nothing changed")
        bed.lights(dark: false)          // the user switched to Claro (or Sistema turned light)
        XCTAssertFalse(bed.isAsleep, "it wakes")
        XCTAssertEqual(bed.reason, .light)
        XCTAssertEqual(bed.wakes, 1)
        bed.lights(dark: true)           // and back
        XCTAssertFalse(bed.isAsleep, "back to dark does not put it to sleep again")
        XCTAssertEqual(bed.wakes, 1)
    }

    /// The window takes the island's theme as it first shows: that is Nook settling in, not a hand on a switch.
    func testTheLightSettlingInAtLaunchDoesNotWakeIt() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        bed.lights(dark: true)
        clock.now += 0.4
        bed.lights(dark: false)
        XCTAssertTrue(bed.isAsleep, "a change inside the first \(PetBedtime.settling) seconds is the theme being applied")
        clock.now += PetBedtime.settling
        bed.lights(dark: true); bed.lights(dark: false)
        XCTAssertFalse(bed.isAsleep, "after them it is the user's")
    }

    func testAnIslandThatWasLightFromTheStartDoesNotWakeTheCat() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        clock.now += 60
        bed.lights(dark: false)     // the first look at it: light. Nothing was switched.
        bed.lights(dark: false)
        XCTAssertTrue(bed.isAsleep, "a user of the light theme still has a sleeping cat at night, until a click")
        XCTAssertTrue(bed.click())
    }

    func testAGreetingWakesItToo() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 0), calendar: calendar)
        XCTAssertTrue(bed.wake(.greeting))
        XCTAssertEqual(bed.reason, .greeting)
    }

    // MARK: The director

    private func rig(seed: Int = 3) -> (director: PetDirector, stage: PetStage) { (PetDirector(layout: .header, seed: seed), .header(travel: 100)) }

    /// Runs `seconds` of the cat's life at 30 frames a second.
    private func run(_ director: inout PetDirector, stage: PetStage, seconds: Double, input: PetInput = PetInput(idle: 60), dt: Double = 1.0 / 30) {
        var t = 0.0
        while t < seconds { director.update(dt: dt, input, stage: stage); t += dt }
    }

    func testAnAsleepCatIsAsleepDeepInItsSleepWithItsZs() {
        var (director, stage) = rig()
        director.fallAsleep()
        XCTAssertTrue(director.isAsleep); XCTAssertTrue(director.isPinnedAsleep)
        let pose = director.pose(wall: 5, alert: 0, input: PetInput(), stage: stage)
        XCTAssertEqual(pose.action, .sleep)
        XCTAssertLessThan(pose.eyes, 0.05, "its eyes are shut")
        XCTAssertGreaterThan(pose.zAlpha, 0.5, "the z's of its dream")
        // Curled: its tail comes round to the front.
        XCTAssertGreaterThan(pose.tail.p3.x, 0)
        run(&director, stage: stage, seconds: 1)
        XCTAssertEqual(director.pose(wall: 6, alert: 0, input: PetInput(), stage: stage).action, .sleep)
    }

    /// It sleeps through the user coming and going, the pointer, a working terminal, an alert, the island opening and closing, and the whole night.
    func testNothingButAWakeWakesACatThatWentToBed() {
        var (director, stage) = rig()
        director.fallAsleep()
        run(&director, stage: stage, seconds: 20, input: PetInput(gaze: PetGaze(dx: 0.5, dy: 0), idle: 0))
        XCTAssertTrue(director.isPinnedAsleep, "the pointer on it")
        run(&director, stage: stage, seconds: 20, input: PetInput(working: true, focus: .typing, idle: 0))
        XCTAssertTrue(director.isPinnedAsleep, "a working terminal and typing")
        var alert = PetInput(idle: 0); alert.perk = 1; alert.perkAge = 1
        run(&director, stage: stage, seconds: 5, input: alert)
        XCTAssertTrue(director.isPinnedAsleep, "an alert")
        var saving = PetInput(idle: 60); saving.power = .saving
        run(&director, stage: stage, seconds: 5, input: saving)
        XCTAssertTrue(director.isPinnedAsleep, "a Mac saving power")
        for _ in 0..<5 { director.settle(); run(&director, stage: stage, seconds: 10) }
        XCTAssertTrue(director.isPinnedAsleep, "the island opening and closing")
        run(&director, stage: stage, seconds: 3600, input: PetInput(idle: 3000), dt: 0.5)
        XCTAssertTrue(director.isPinnedAsleep, "a night of it")
        XCTAssertEqual(director.pose(wall: 9, alert: 0, input: PetInput(), stage: stage).action, .sleep)
    }

    func testACatInBedStartsNothingAndDoesNotTurnToThePointer() {
        var (director, stage) = rig()
        director.fallAsleep()
        director.start(.groom, stage: stage)
        director.start(.stroll, stage: stage)
        XCTAssertTrue(director.isPinnedAsleep, "asked to do something, it stays in bed")
        XCTAssertEqual(director.activity, .gesture(.nap))
        var near = PetInput(idle: 60); near.gaze = PetGaze(dx: 1, dy: 0.5)
        run(&director, stage: stage, seconds: 3, input: near)
        let looking = director.pose(wall: 4, alert: 0, input: near, stage: stage)
        let alone = director.pose(wall: 4, alert: 0, input: PetInput(), stage: stage)
        XCTAssertEqual(looking.head, alone.head, "it does not turn its head to a pointer: it is asleep")
        XCTAssertEqual(looking.look, alone.look)
    }

    /// A cat asleep for the night costs next to nothing: no frame wanted at a high rate, no hurry.
    func testASleepingCatKeepsTheStillCatsFrameBudget() {
        var (director, stage) = rig()
        director.fallAsleep()
        run(&director, stage: stage, seconds: 2)
        XCTAssertFalse(director.isBusy)
        XCTAssertNil(director.frameCeiling, "nothing is about to begin: the frames may be as slow as a breathing cat's")
        director.wake()
        XCTAssertTrue(director.isBusy, "waking is motion: it gets its frames")
        XCTAssertNotNil(director.frameCeiling)
    }

    func testAWakeBeginsAGentleWakingAndEndsInTheSitAndTheCatsOwnLife() {
        var (director, stage) = rig()
        director.fallAsleep()
        run(&director, stage: stage, seconds: 5)
        XCTAssertTrue(director.wake())
        XCTAssertNotNil(director.waking)
        XCTAssertFalse(director.isAsleep, "it is waking, not asleep")
        XCTAssertFalse(director.isPinnedAsleep)
        XCTAssertFalse(director.wake(), "a second click while it wakes wakes nothing more")
        let length = director.waking!.length
        run(&director, stage: stage, seconds: length - 1)
        XCTAssertNotNil(director.waking, "it is still waking a second before the end")
        run(&director, stage: stage, seconds: 1.2)
        XCTAssertNil(director.waking)
        XCTAssertFalse(director.isAsleep); XCTAssertFalse(director.isPinnedAsleep)
        XCTAssertEqual(director.pose(wall: 40, alert: 0, input: PetInput(), stage: stage).action, .sit)
        // Awake for good: a long quiet day has no sleep in it unless the cat's own rules say so (and they need real inactivity).
        run(&director, stage: stage, seconds: 600, input: PetInput(idle: 20))
        XCTAssertFalse(director.isPinnedAsleep)
    }

    func testTheCatGoesOnWithItsLifeAfterWaking() {
        var (director, stage) = rig()
        director.fallAsleep()
        director.wake()
        run(&director, stage: stage, seconds: director.waking!.length + 0.5)
        var kinds = Set<PetDirector.Kind>()
        var t = 0.0
        while t < 300 {
            director.update(dt: 0.1, PetInput(idle: 20), stage: stage)
            if case .gesture(let kind) = director.activity { kinds.insert(kind) }
            t += 0.1
        }
        XCTAssertFalse(kinds.isEmpty, "it does things again: \(kinds)")
        XCTAssertFalse(kinds.contains(.nap), "and does not go straight back to sleep: it was only just woken")
    }

    func testNothingInterruptsAWaking() {
        var (director, stage) = rig()
        director.fallAsleep(); director.wake()
        var busy = PetInput(working: true, gaze: PetGaze(dx: 1, dy: 0), focus: .typing, idle: 0)
        busy.perk = 1
        run(&director, stage: stage, seconds: 3, input: busy)
        XCTAssertNotNil(director.waking, "the pointer, an alert and a working terminal do not cut it short")
        let pose = director.pose(wall: 5, alert: 0, input: busy, stage: stage)
        XCTAssertNotEqual(pose.action, .curious, "and nothing is laid over it")
        director.start(.groom, stage: stage)
        XCTAssertNil(director.running, "it starts no gesture while it wakes")
    }

    /// A cat asleep for any other reason (its own nap) wakes the same way when it is clicked.
    func testItsOwnNapsWakeTheSameWay() {
        var (director, stage) = rig()
        director.start(.nap, stage: stage)
        run(&director, stage: stage, seconds: 6, input: PetInput(idle: 400))
        XCTAssertTrue(director.isAsleep, "a nap is a sleep")
        XCTAssertFalse(director.isPinnedAsleep, "of its own")
        XCTAssertTrue(director.wake(), "a click wakes it")
        XCTAssertNotNil(director.waking)
        XCTAssertNil(director.running)
        let length = director.waking!.length
        run(&director, stage: stage, seconds: length + 0.2)
        XCTAssertNil(director.waking)
        XCTAssertEqual(director.pose(wall: 99, alert: 0, input: PetInput(), stage: stage).action, .sit)
    }

    func testAnAwakeCatHasNothingToWake() {
        var (director, stage) = rig()
        XCTAssertFalse(director.wake())
        director.start(.groom, stage: stage)
        XCTAssertFalse(director.wake(), "a cat washing is awake")
        XCTAssertNotNil(director.running)
    }

    /// A cat woken while it was out of sight is up when it is seen again: a waking that ran its course is over at once.
    func testAWakingThatAlreadyRanItsCourseIsOver() {
        var (director, _) = rig()
        director.fallAsleep()
        XCTAssertTrue(director.wake(age: 60))
        XCTAssertNil(director.waking)
        XCTAssertNil(director.running)
        XCTAssertFalse(director.isAsleep)
        var halfway = rig().director
        halfway.fallAsleep()
        XCTAssertTrue(halfway.wake(age: 2))
        XCTAssertEqual(halfway.waking?.age ?? 0, 2, accuracy: 1e-9, "one woken a moment ago is as far along as the moment says")
        var squinting = rig().director
        squinting.fallAsleep()
        XCTAssertTrue(squinting.wake(age: 4, squint: 1))
        XCTAssertNotNil(squinting.waking, "four seconds after the light came on, the cat is still waking: it squinted for the first of them")
    }

    /// The waking is the website's cat's: four seconds, and the one woken by the light has a second of squinting before it.
    func testAWakingTakesFourSecondsAndOneWokenByTheLightASecondMore() {
        XCTAssertEqual(PetAnimation.wakeLength(), 4.0, accuracy: 1e-9)
        XCTAssertEqual(PetAnimation.wakeLength(squint: 1), PetAnimation.wakeLength() + PetWakeBeats.squintLead, accuracy: 1e-9)
        XCTAssertEqual(PetWakeBeats.squintLead, 1.0, accuracy: 1e-9)
        for seed in 0..<12 {
            var (director, _) = rig(seed: seed)
            director.fallAsleep(); director.wake()
            XCTAssertEqual(director.waking!.length, 4.0, accuracy: 1e-9, "every click wakes the cat the same way")
        }
        var (light, _) = rig()
        light.fallAsleep(); light.wake(squint: 1)
        XCTAssertEqual(light.waking!.length, 5.0, accuracy: 1e-9)
    }

    func testACatThatLayFacingLeftWakesFacingLeft() {
        var (director, stage) = rig()
        director.fallAsleep(facing: -1)
        let asleep = director.pose(wall: 3, alert: 0, input: PetInput(), stage: stage)
        XCTAssertEqual(asleep.facing, -1)
        director.wake()
        run(&director, stage: stage, seconds: 2)
        let waking = director.pose(wall: 3, alert: 0, input: PetInput(), stage: stage)
        XCTAssertEqual(waking.facing, -1, "it does not turn round to wake")
    }

    // MARK: The pose

    /// The waking sampled at 120 frames a second from the click (the squint before it included when `squint` is more than 0). The cat's own clock reads the same at the same beat of the
    /// waking either way, so a waking and the same one after a squint can be set side by side.
    private func sample(squint: CGFloat = 0, from age: Double = 9) -> [(u: Double, pose: PetPose)] {
        let lead = squint > 0 ? PetWakeBeats.squintLead : 0
        return stride(from: 0.0, through: PetAnimation.wakeLength(squint: squint), by: 1.0 / 120).map { u in
            (u, PetAnimation.waking(u: u, time: 40 + u - lead, sleptAge: age, sleptLength: 1e9, squint: squint))
        }
    }

    func testItBeginsWhereTheSleepWasAndEndsInTheSit() {
        for squint in [CGFloat(0), 1] {
            let frames = sample(squint: squint)
            let asleep = PetAnimation.perform(.sleep, u: 9, length: 1e9, time: 40 - (squint > 0 ? PetWakeBeats.squintLead : 0), facing: 1, alert: 0)
            XCTAssertLessThan(frames[0].pose.distance(to: asleep), 0.01, "no jump at the click (squint: \(squint))")
            let end = frames.last!
            XCTAssertLessThan(end.pose.distance(to: PetAnimation.sit(time: 40 + end.u - (squint > 0 ? PetWakeBeats.squintLead : 0))), 0.2, "it ends in the idle sit (squint: \(squint))")
            XCTAssertEqual(end.pose.action, .sit)
        }
    }

    /// Probed headlessly: sampled at 120 frames a second, no beat of the waking jumps from one frame to the next (the picture's own measure of how far it moved, in points at 3 a unit).
    func testTheWakingIsSmoothFromFrameToFrame() {
        for squint in [CGFloat(0), 1] {
            let frames = sample(squint: squint)
            var worst = 0.0, at = 0.0
            for (a, b) in zip(frames, frames.dropFirst()) {
                // The cat's own breathing is in both frames (their clock is a frame apart): what is measured is how far the picture moved.
                let d = Double(b.pose.displacement(to: a.pose, scale: 3))
                if d > worst { worst = d; at = b.u }
            }
            XCTAssertLessThan(worst, 4.5, "the largest step at \(at) s, at 120 fps and 3 points a unit (squint: \(squint))")
        }
    }

    /// The beats of the website's waking, at the seconds the website has them.
    func testTheBeatsComeInTheOrderOfAWakingCat() {
        let frames = sample()
        func at(_ u: Double) -> PetPose { frames[Int((u * 120).rounded())].pose }
        let beats = PetWakeBeats.self
        // An ear flicks, and flicks again, with the eyes still shut.
        let rest = at(0).earR
        XCTAssertLessThan(at(0.2).earR, rest - 0.2, "the ear flick")
        XCTAssertGreaterThan(at(0.37).earR, at(0.2).earR + 0.2, "and it comes back")
        XCTAssertLessThan(at(0.54).earR, rest - 0.15, "and flicks again")
        XCTAssertLessThan(at(0.2).eyes, 0.05, "eyes shut through the first")
        // The eyes open in fits: a crack from 0.3 to 0.95, a heavy lid sinking again by 1.6, then open by 2.0.
        XCTAssertGreaterThan(at(0.95).eyes, 0.4); XCTAssertLessThan(at(0.95).eyes, 0.7, "a crack")
        XCTAssertLessThan(at(1.6).eyes, at(0.95).eyes - 0.3, "the lid sinks again")
        XCTAssertGreaterThan(at(2.0).eyes, 0.8, "then they are open")
        // The z's of the dream are gone by 0.8.
        XCTAssertGreaterThan(at(0).zAlpha, 0.5); XCTAssertEqual(at(beats.zFade).zAlpha, 0, accuracy: 1e-9)
        // It rises into the stretch from 1.4 (the front legs out, the head down), and arches its back out of it.
        XCTAssertEqual(at(1.3).action, .sleep, "still lying at 1.3")
        let bow = frames.filter { $0.u > beats.bow.upperBound - 0.1 && $0.u < beats.arch.lowerBound + 0.1 }
        XCTAssertGreaterThan(bow.map { $0.pose.legs.nearFront.foot.x }.max() ?? 0, 11, "the front legs reach out")
        XCTAssertLessThan(bow.map { $0.pose.head.y }.min() ?? 99, 12, "its head goes down")
        let arch = frames.filter { $0.u > beats.arch.upperBound - 0.2 && $0.u < beats.arch.upperBound + 0.02 }
        XCTAssertGreaterThan(arch.map { $0.pose.haunch.cy }.max() ?? 0, 13, "its back is arched: the rear is up")
        XCTAssertTrue(frames.contains { $0.pose.action == .stretch })
        // It yawns through the stretch, 2.0 to 3.3: the mouth opens as it rises and shuts as it sits, and the eyes squeeze shut.
        XCTAssertGreaterThan(frames.map { $0.pose.mouth }.max() ?? 0, 0.8, "the yawn")
        XCTAssertEqual(at(1.9).mouth, 0, accuracy: 0.01, "not before it stretches")
        XCTAssertGreaterThan(at(2.7).mouth, 0.8, "open at the top of the stretch")
        XCTAssertEqual(at(3.4).mouth, 0, accuracy: 0.01, "shut by the time it has sat down")
        XCTAssertLessThan(at(2.7).eyes, 0.25, "eyes squeezed shut by the yawn")
        // It sits down from 3.0, and blinks slowly, the last thing it does: the eyes close and open again by 3.97.
        XCTAssertGreaterThan(at(3.3).eyes, 0.8)
        XCTAssertLessThan(at(3.71).eyes, 0.15, "a slow blink")
        XCTAssertGreaterThan(at(3.99).eyes, 0.9)
        XCTAssertEqual(frames.last!.u, PetWakeBeats.length, accuracy: 1e-6)
        XCTAssertEqual(frames.last!.pose.action, .sit)
    }

    /// The light: a second of squinting before anything else (ears back, head tucked, the cat still lying there), and then the same waking.
    func testWokenByTheLightItSquintsForASecondAndThenWakesTheSame() {
        let plain = sample(squint: 0), glare = sample(squint: 1)
        let lead = PetWakeBeats.squintLead
        func plainAt(_ u: Double) -> PetPose { plain[Int((u * 120).rounded())].pose }
        func glareAt(_ raw: Double) -> PetPose { glare[Int((raw * 120).rounded())].pose }
        // The squint: ears back and the head tucked within half a second, held to the end of the first second, the cat where it lay.
        XCTAssertGreaterThan(glareAt(0.4).earL, plainAt(0).earL + 0.15, "ears back")
        XCTAssertGreaterThan(glareAt(0.4).earR, plainAt(0).earR + 0.15)
        XCTAssertLessThan(glareAt(0.4).head.y, plainAt(0).head.y - 0.35, "head tucked")
        XCTAssertGreaterThan(glareAt(lead - 0.02).earL, plainAt(0).earL + 0.18, "still back at the end of the squint")
        XCTAssertGreaterThan(glareAt(lead - 0.02).eyes, 0.1, "its eyes are slits against the light")
        XCTAssertLessThan(glareAt(lead - 0.02).eyes, 0.3)
        XCTAssertEqual(glareAt(lead - 0.02).zAlpha, 0, accuracy: 1e-9, "the dream is gone")
        XCTAssertEqual(glareAt(lead - 0.02).action, .sleep, "it has not got up yet")
        XCTAssertEqual(glareAt(lead - 0.02).legs.nearFront.foot.x, plainAt(0).legs.nearFront.foot.x, accuracy: 0.5, "and has not moved")
        XCTAssertEqual(glareAt(lead - 0.02).mouth, 0)
        // The flinch: a moment's lift of the head and a crack of an eye, then it tucks.
        XCTAssertGreaterThan(glareAt(0.18).eyes, glareAt(0.02).eyes + 0.1, "an eye cracks open")
        XCTAssertLessThan(glareAt(0.5).eyes, glareAt(0.18).eyes, "and shuts again")
        // Then it wakes as a cat woken by a click does: from a second in the glare has let go and the two are the same cat at the same beat.
        for u in stride(from: 1.0, through: PetAnimation.wakeLength(), by: 0.25) {
            XCTAssertLessThan(glareAt(lead + u).distance(to: plainAt(u)), 1e-6, "\(u) s into the waking")
        }
        XCTAssertLessThan(glareAt(lead + 0.45).distance(to: plainAt(0.45)), 1.5, "the glare is let go over the first of its waking")
        XCTAssertEqual(glare.last!.pose.distance(to: plain.last!.pose), 0, accuracy: 0.01)
    }

    /// Every frame is the same cat: nothing the waking blends or adds takes the cat's head, body, legs or tail outside what the cat's own poses use (a sit, a stand, a bow, an arch, a
    /// loaf, a curled-up nap, its own yawn), so it never stretches, shrinks or twists in between.
    func testEveryFrameIsTheSameCat() {
        let t = 40.0
        let own: [PetPose] = [PetAnimation.sit(time: t), PetAnimation.walk(phase: 0, amp: 0, time: t), PetAnimation.bow(time: t), PetAnimation.arch(time: t), PetAnimation.loaf(rest: 0, time: t),
                              PetAnimation.loaf(rest: 1, curl: 1, time: t, asleep: 1), PetAnimation.yawn(u: 1.6, time: t), PetAnimation.sad(time: t)]
        func legLength(_ l: PetLimb) -> CGFloat { hypot(l.knee.x - l.hip.x, l.knee.y - l.hip.y) + hypot(l.foot.x - l.knee.x, l.foot.y - l.knee.y) }
        /// The tail's own length along its curve (its control points fold back on themselves in between two poses, which is no shortening of the tail).
        func tailLength(_ tail: PetTail) -> CGFloat {
            var length: CGFloat = 0, last = tail.p0
            for i in 1...24 {
                let u = CGFloat(i) / 24, v = 1 - u
                let point = CGPoint(x: v * v * v * tail.p0.x + 3 * v * v * u * tail.c1.x + 3 * v * u * u * tail.c2.x + u * u * u * tail.p3.x,
                                    y: v * v * v * tail.p0.y + 3 * v * v * u * tail.c1.y + 3 * v * u * u * tail.c2.y + u * u * u * tail.p3.y)
                length += hypot(point.x - last.x, point.y - last.y); last = point
            }
            return length
        }
        func envelope(_ value: (PetPose) -> CGFloat) -> ClosedRange<CGFloat> {
            let values = own.map(value)
            return (values.min() ?? 0)...(values.max() ?? 0)
        }
        let headScale = envelope { $0.headScale }, tilt = envelope { $0.tilt }, ears = envelope { max($0.earL, $0.earR) }
        let shortestLeg = envelope { p in p.legs.map(legLength).min() ?? 0 }.lowerBound, longestLeg = envelope { p in p.legs.map(legLength).max() ?? 0 }.upperBound
        let tail = envelope { tailLength($0.tail) }, haunch = envelope { $0.haunch.rx }, chest = envelope { $0.chest.rx }
        for squint in [CGFloat(0), 1] {
            for (u, pose) in sample(squint: squint) {
                let at = "at \(u) s (squint \(squint))"
                XCTAssertTrue((headScale.lowerBound - 0.03...headScale.upperBound + 0.03).contains(pose.headScale), "the head keeps its size \(at): \(pose.headScale)")
                XCTAssertTrue((tilt.lowerBound - 0.06...tilt.upperBound + 0.2).contains(pose.tilt), "and does not twist \(at): \(pose.tilt)")
                XCTAssertLessThanOrEqual(max(pose.earL, pose.earR), ears.upperBound + 0.3, "its ears stay where ears go \(at)")
                for leg in pose.legs {
                    XCTAssertTrue((shortestLeg * 0.8...longestLeg * 1.1).contains(legLength(leg)), "no leg shrinks to a stub or stretches to a stick \(at): \(legLength(leg))")
                }
                XCTAssertTrue((tail.lowerBound * 0.8...tail.upperBound * 1.1).contains(tailLength(pose.tail)), "the tail is the cat's tail \(at): \(tailLength(pose.tail))")
                XCTAssertTrue((haunch.lowerBound - 0.8...haunch.upperBound + 0.8).contains(pose.haunch.rx), "the body keeps its size \(at): \(pose.haunch.rx)")
                XCTAssertTrue((chest.lowerBound - 0.8...chest.upperBound + 0.8).contains(pose.chest.rx), "\(at): \(pose.chest.rx)")
                XCTAssertLessThanOrEqual(pose.mouth, 1.0, "its mouth never opens wider than its own yawn \(at)")
            }
        }
    }

    func testEveryFrameOfTheWakingStaysInsideTheRoomTheCatHas() {
        for squint in [CGFloat(0), 1] {
            for frame in sample(squint: squint) {
                let b = frame.pose.bounds
                XCTAssertGreaterThanOrEqual(b.minX, -PetAnimation.reach.left - 1, "at \(frame.u)")
                XCTAssertLessThanOrEqual(b.maxX, PetAnimation.reach.right + 1, "at \(frame.u)")
                for value in [frame.pose.head.x, frame.pose.head.y, frame.pose.eyes, frame.pose.zAlpha, frame.pose.mouth] { XCTAssertTrue(value.isFinite) }
                XCTAssertTrue((0...1.4).contains(frame.pose.eyes), "at \(frame.u): \(frame.pose.eyes)")
            }
        }
    }

    func testAMirroredWakingIsTheSameCatTheOtherWay() {
        let pose = PetAnimation.waking(u: 2.7, time: 12, sleptAge: 9, sleptLength: 1e9)
        let mirrored = pose.mirrored()
        XCTAssertEqual(mirrored.facing, -1)
        XCTAssertEqual(mirrored.head.x, -pose.head.x, accuracy: 1e-9)
        XCTAssertEqual(mirrored.earL, pose.earR)
    }

    func testAStillSleepingCatIsCurledUpWithItsEyesShut() {
        let still = PetAnimation.staticPose(working: false, attention: false, asleep: true)
        XCTAssertEqual(still, PetAnimation.asleepPose())
        XCTAssertEqual(still.action, .sleep)
        XCTAssertLessThan(still.eyes, 0.05)
        XCTAssertGreaterThan(still.zAlpha, 0.4)
        XCTAssertNotEqual(PetAnimation.staticPose(working: false, attention: false, asleep: false), still)
        XCTAssertEqual(PetAnimation.staticPose(working: false, attention: false, asleep: true), PetAnimation.staticPose(working: true, attention: true, asleep: true), "asleep, nothing else matters")
    }

    // MARK: The player

    func testThePlayerShowsASleepingCatAWakingCatAndThenTheSit() {
        var player = PetPlayer(layout: .header, seed: 4)
        let layout = PetPlayer.Layout.header(travel: 100, scale: 0.5, height: 32)
        player.fallAsleep()
        XCTAssertTrue(player.isPinnedAsleep); XCTAssertTrue(player.isAsleep)
        var now = 100.0
        func step(_ seconds: Double) -> PetPose {
            var pose = PetPose()
            let end = now + seconds
            while now < end { now += 1.0 / 30; pose = player.pose(now: now, layout: layout, motion: true, input: PetInput(idle: 60)) }
            return pose
        }
        XCTAssertEqual(step(3).action, .sleep)
        XCTAssertTrue(player.wake())
        XCTAssertTrue(player.isWaking)
        let early = step(0.2)
        XCTAssertEqual(early.action, .sleep, "it begins from the sleep")
        let mid = step(2)
        XCTAssertEqual(mid.action, .stretch, "two seconds in it is in the stretch")
        let end = step(8)
        XCTAssertFalse(player.isWaking)
        XCTAssertEqual(end.action, .sit)
    }

    // MARK: Every cat follows the bedtime

    func testACatsViewPutsItsCatToBedAndKeepsItThere() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        var player = PetPlayer(layout: .compact, seed: 1)
        var follower = PetBedtimeFollower()
        XCTAssertTrue(follower.follow(bed, player: &player, now: clock.now))
        XCTAssertTrue(player.isPinnedAsleep)
        XCTAssertFalse(follower.follow(bed, player: &player, now: clock.now), "once is enough")
        player.settle()
        XCTAssertTrue(player.isPinnedAsleep, "across the island coming and going")
    }

    func testACatWokenWhileInSightWakesGentlyAndOneWokenOutOfSightIsUp() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        var seen = PetPlayer(layout: .header, seed: 1), away = PetPlayer(layout: .compact, seed: 2)
        var seenFollower = PetBedtimeFollower(), awayFollower = PetBedtimeFollower()
        seenFollower.follow(bed, player: &seen, now: clock.now)
        awayFollower.follow(bed, player: &away, now: clock.now)
        // A click on the cat that is in sight.
        clock.now += 20
        bed.click()
        XCTAssertTrue(seenFollower.follow(bed, player: &seen, now: clock.now))
        XCTAssertTrue(seen.isWaking, "the cat in sight wakes gently")
        // The other cat's view looks a minute later: it was woken while it could not be seen.
        clock.now += 60
        XCTAssertTrue(awayFollower.follow(bed, player: &away, now: clock.now))
        XCTAssertFalse(away.isPinnedAsleep); XCTAssertFalse(away.isWaking); XCTAssertFalse(away.isAsleep)
        XCTAssertFalse(awayFollower.follow(bed, player: &away, now: clock.now))
    }

    func testAViewWithoutABedtimeChangesNothing() {
        var player = PetPlayer(layout: .compact, seed: 1)
        var follower = PetBedtimeFollower()
        XCTAssertFalse(follower.follow(nil, player: &player, now: 0))
        XCTAssertFalse(player.isAsleep)
    }

    func testALightWakingSquintsAndAClickWakingDoesNot() {
        let clock = Clock(), bed = bedtime(clock)
        bed.launch(at: date(hour: 1), calendar: calendar)
        var player = PetPlayer(layout: .header, seed: 1)
        var follower = PetBedtimeFollower()
        follower.follow(bed, player: &player, now: clock.now)
        bed.lights(dark: true)
        clock.now += 30
        bed.lights(dark: false)
        follower.follow(bed, player: &player, now: clock.now)
        XCTAssertEqual(player.director.waking?.squint, 1)
        var clicked = PetPlayer(layout: .header, seed: 1)
        var other = PetBedtimeFollower()
        let second = bedtime(clock)
        second.launch(at: date(hour: 1), calendar: calendar)
        other.follow(second, player: &clicked, now: clock.now)
        second.click()
        other.follow(second, player: &clicked, now: clock.now)
        XCTAssertEqual(clicked.director.waking?.squint, 0)
    }

    // MARK: The views

    /// The header's cat, held still (the animations off or Reduce Motion): asleep it is the sleeping pose, and the click that wakes it changes the pose calmly, with no motion.
    func testAStillHeaderCatSleepsAndAClickWakesItWithoutMotion() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-wake-" + UUID().uuidString)!)
        let controller = NotchController(model: model, quiet: true)
        addTeardownBlock {
            controller.panel.close(); controller.petPanel.close()
            model.controller = nil
        }
        model.petBedtime.launch(at: date(hour: 2), calendar: calendar)
        let view = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        view.controller = controller
        view.animated = false
        XCTAssertEqual(view.pose, PetAnimation.asleepPose(), "the still sleeping cat")
        XCTAssertEqual(view.frameInterval, 0, "and no timer")
        view.wakeFromClick()
        XCTAssertFalse(model.petBedtime.isAsleep)
        XCTAssertEqual(view.pose, PetAnimation.staticPose(working: false, attention: false), "calmly awake")
        XCTAssertEqual(view.frameInterval, 0, "still no timer")
    }
}
