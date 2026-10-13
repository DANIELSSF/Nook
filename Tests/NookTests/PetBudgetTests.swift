import AppKit
import XCTest
@testable import Nook

/// What the cat costs: how many frames it draws on a realistic day (typing, reading, away, Claude working, the pointer visiting), how often it
/// wakes the Mac to do it, what a frame costs, and what it gives up on a Mac that is saving power. The numbers of the cat as it was before it
/// was reworked were measured on these very days (`PetScenario`) and are kept here, so "not more than before" is a test and not a promise.
final class PetBudgetTests: XCTestCase {
    /// The cat as it was, on the same simulated days: frames drawn a minute (the wing repainted: the cat changed or the dots waved) and
    /// timer ticks a minute. Collapsed island: 3 seeds of 8 hours; open island's header: 3 seeds of 20 visits of 4 minutes. Release build.
    enum Legacy {
        static let collapsedPaints = 837.0, collapsedTicks = 837.0
        static let collapsedRest = 740.0      // typing, reading, thinking, away: the cat only sitting there
        static let collapsedWorking = 1022.0   // working, with the dots' floor of 15 a second
        static let headerPaints = 1958.0, headerTicks = 1958.0
    }

    // MARK: Frames a minute

    func testTheCollapsedCatIsDrawnAFractionOfTheFramesItWas() {
        var total = PetBudget.Report()
        for seed in [UInt64(1), 2] {
            for (state, tally) in PetBudget.compactDay(hours: 3, seed: seed).report { total[state, default: PetBudget.Tally()].add(tally) }
        }
        print(PetBudget.format("collapsed island, 2 seeds x 3 h (before: \(Legacy.collapsedPaints) frames a minute)", total))
        let all = PetBudget.total(total)
        XCTAssertLessThan(all.paintsPerMinute, Legacy.collapsedPaints * 0.42, "less than half the frames it drew before: \(all.paintsPerMinute) a minute against \(Legacy.collapsedPaints)")
        XCTAssertLessThan(all.ticksPerMinute, Legacy.collapsedTicks * 0.65, "and it wakes the Mac far less often: \(all.ticksPerMinute) ticks against \(Legacy.collapsedTicks)")
        // Where the cat only sits (the user is typing, reading or away) it is drawn three to six times less than it was.
        for state in ["typing", "reading", "free", "away"] {
            let tally = try! XCTUnwrap(total[state], state)
            XCTAssertLessThan(tally.paintsPerMinute, Legacy.collapsedRest * 0.42, "\(state): \(tally.paintsPerMinute) a minute")
        }
        XCTAssertLessThan(try! XCTUnwrap(total["typing"]).paintsPerMinute, 170, "while the user types it hardly moves")
        // Working, it was drawn ~1000 times a minute (and the dots asked for 15 a second): now the cat adds little over the dots' own eight.
        let working = try! XCTUnwrap(total["working"])
        XCTAssertLessThan(working.paintsPerMinute, Legacy.collapsedWorking * 0.55, "working: \(working.paintsPerMinute) a minute")
        XCTAssertLessThan(working.paintsPerMinute, 60 * (1 / PetAnimation.dotsInterval) * 0.6 + 300, "no more than the dots would ask for and a few gestures")
    }

    func testTheHeadersCatIsDrawnAFractionOfTheFramesItWas() {
        let result = PetBudget.openIsland(sessions: 20, minutes: 4, seed: 1).report
        print(PetBudget.format("open island's header, 20 visits (before: \(Legacy.headerPaints) frames a minute)", result))
        let all = PetBudget.total(result)
        XCTAssertLessThan(all.paintsPerMinute, Legacy.headerPaints * 0.25, "a quarter of the frames: \(all.paintsPerMinute) against \(Legacy.headerPaints)")
        XCTAssertLessThan(all.ticksPerMinute, Legacy.headerTicks * 0.35)
        for (state, tally) in result { XCTAssertLessThan(tally.paintsPerMinute, 650, "\(state): \(tally.paintsPerMinute) a minute, and the header used to draw up to 3600") }
    }

    func testAMixOfPersonalitiesAndActivityNeverCostsMoreThanTheOldCat() {
        // The liveliest setting (a playful cat with a lot to do) is still below what the old plain cat cost; the calmest costs the least.
        func paints(_ personality: PetPersonality, _ activity: PetActivity) -> Double {
            var prefs = PetPreferences(); prefs.personality = personality; prefs.activity = activity
            return PetBudget.total(PetBudget.compactDay(hours: 2, seed: 3, prefs: prefs).report).paintsPerMinute
        }
        let lively = paints(.playful, .high), plain = paints(.curious, .normal), calm = paints(.calm, .low), still = paints(.curious, .none)
        print("frames a minute: playful and busy \(lively), plain \(plain), calm and quiet \(calm), nothing to do \(still)")
        XCTAssertLessThan(lively, Legacy.collapsedPaints * 0.6); XCTAssertLessThan(plain, lively); XCTAssertLessThan(calm, plain)
        XCTAssertLessThanOrEqual(still, calm * 1.05, "a cat asked to do nothing starts no gesture of its own")
        XCTAssertLessThan(still, Legacy.collapsedPaints * 0.3, "it only breathes, blinks and reacts, and costs under a third of what the old cat did")
    }

    func testAMacSavingPowerDrawsTheCatFarLessStill() {
        func paints(_ power: PetPower) -> Double { PetBudget.total(PetBudget.compactDay(hours: 2, seed: 2, power: power).report).paintsPerMinute }
        let normal = paints(.normal), saving = paints(.saving)
        print("frames a minute: normal \(normal), saving power \(saving)")
        XCTAssertLessThan(saving, normal * 0.8, "Low Power Mode: slower frames and only the cheap gestures")
        XCTAssertLessThan(PetBudget.total(PetBudget.openIsland(sessions: 6, minutes: 4, seed: 2, power: .saving).report).paintsPerMinute, PetBudget.total(PetBudget.openIsland(sessions: 6, minutes: 4, seed: 2).report).paintsPerMinute)
    }

    // MARK: What the cat asks of the frame rate

    func testAnIdleCatIsDrawnAtMostAFewTimesASecondAndLessWhileTheUserWorks() {
        func rate(_ focus: PetFocus, idle: Double = 10, power: PetPower = .normal) -> (draws: Double, ticks: Double) {
            var driver = PetDriver(layout: .compact, seed: 5)
            var prefs = PetPreferences(); prefs.activity = .none
            var now = 1000.0, ticks = 0, draws = 0
            while now < 1000 + 600 {
                var input = PetInput(focus: focus, idle: idle); input.prefs = prefs; input.power = power
                let tick = driver.tick(now: now, layout: .compact(height: 32), input: input)
                ticks += 1; if tick.draw { draws += 1 }
                now += tick.interval
            }
            return (Double(draws) / 600, Double(ticks) / 600)
        }
        let free = rate(.free), reading = rate(.reading), typing = rate(.typing), away = rate(.free, idle: 300), saving = rate(.free, power: .saving)
        print("a cat with nothing to do, draws and ticks a second: free \(free), reading \(reading), typing \(typing), away \(away), saving power \(saving)")
        XCTAssertLessThan(free.draws, 5, "while it is watched it is drawn a few times a second: the old cat was drawn 12")
        XCTAssertLessThan(reading.draws, free.draws); XCTAssertLessThan(typing.draws, reading.draws)
        XCTAssertLessThan(typing.draws, 2)
        XCTAssertLessThan(away.draws, 1.6, "nobody is there to see it")
        XCTAssertLessThan(saving.draws, free.draws)
        XCTAssertLessThan(typing.ticks, 5, "and it wakes the Mac a few times a second at most")
    }

    func testTheRestingCadenceFollowsWhatTheUserDoesAndWhatTheMacCanSpare() {
        XCTAssertLessThan(PetCadence.rest(focus: .free, power: .normal), PetCadence.rest(focus: .reading, power: .normal))
        XCTAssertLessThan(PetCadence.rest(focus: .reading, power: .normal), PetCadence.rest(focus: .typing, power: .normal))
        XCTAssertEqual(PetCadence.rest(focus: .free, idle: 200, power: .normal), 0.5, "away: twice a second")
        for focus in [PetFocus.free, .reading, .typing] { XCTAssertGreaterThan(PetCadence.rest(focus: focus, power: .saving), PetCadence.rest(focus: focus, power: .normal)) }
        XCTAssertLessThanOrEqual(PetCadence.rest(focus: .typing, power: .saving), 0.5)
        // Sixty a second while the cat moves, thirty while it only rests (its blinks and flicks are drawn as they always were).
        XCTAssertEqual(PetCadence.fast(.compact, power: .normal), 1.0 / 60); XCTAssertEqual(PetCadence.fast(.header, power: .normal), 1.0 / 60)
        XCTAssertEqual(PetCadence.fast(.compact, power: .normal, moving: false), 1.0 / 30); XCTAssertEqual(PetCadence.fast(.header, power: .normal, moving: false), 1.0 / 30)
        XCTAssertEqual(PetCadence.fast(.compact, power: .saving), 1.0 / 30, "half the rate on a Mac saving power")
        XCTAssertEqual(PetCadence.fast(.compact, power: .saving, moving: false), 1.0 / 15)
        XCTAssertLessThan(PetCadence.threshold(focus: .free, power: .normal), PetCadence.threshold(focus: .typing, power: .normal))
        XCTAssertGreaterThan(PetCadence.threshold(focus: .free, power: .saving), PetCadence.threshold(focus: .free, power: .normal))
        // Sixty and thirty a second divide what every screen refreshes at: no frame is held longer than the one before it.
        for refresh in [60.0, 120.0] { XCTAssertEqual(refresh / 60, (refresh / 60).rounded()); XCTAssertEqual(refresh / 30, (refresh / 30).rounded()) }
        XCTAssertGreaterThanOrEqual(PetAnimation.compactInterval, 1.0 / 60 - 1e-9); XCTAssertLessThanOrEqual(PetAnimation.restInterval, 0.25)
    }

    func testTheDriverDrawsOnlyWhatMovedAndIgnoresATickRightAfterAnother() {
        var driver = PetDriver(layout: .compact, seed: 3)
        var prefs = PetPreferences(); prefs.activity = .none
        var input = PetInput(idle: 10); input.prefs = prefs
        let first = driver.tick(now: 100, layout: .compact(), input: input)
        XCTAssertTrue(first.draw, "the first frame is drawn")
        let again = driver.tick(now: 100.004, layout: .compact(), input: input)
        XCTAssertFalse(again.draw, "a second tick a few milliseconds later (the model changed) says nothing new")
        XCTAssertEqual(again.interval, first.interval); XCTAssertEqual(again.pose, first.pose)
        // A pose that changed by a hair is not drawn; one that changed by a pixel is.
        var drawn = 0, ticks = 0
        var now = 100.5
        for _ in 0..<200 {
            let tick = driver.tick(now: now, layout: .compact(), input: input)
            ticks += 1; if tick.draw { drawn += 1 }
            now += tick.interval
        }
        XCTAssertLessThan(drawn, ticks, "some ticks find the picture where it was")
        // When the world changes the cat moves and is drawn at the fast rate.
        input.completions = 1
        _ = driver.tick(now: now, layout: .compact(), input: input)
        input.completions = 2
        var intervals = [Double](), celebrating = false
        for _ in 0..<80 {
            now += 1.0 / 30
            let tick = driver.tick(now: now, layout: .compact(), input: input)
            if driver.player.director.celebration != nil { celebrating = true; intervals.append(tick.interval) }
        }
        XCTAssertTrue(celebrating)
        XCTAssertLessThanOrEqual(intervals.max() ?? 1, 1.0 / 20 + 1e-9, "a cheer is drawn at 20 a second or better")
    }

    func testABlinkGetsAFrameWhenItStartsAndAFewWhileItLasts() {
        var driver = PetDriver(layout: .compact, seed: 4)
        var prefs = PetPreferences(); prefs.activity = .none
        var times = [Double](), drawn = [Bool]()
        var now = 2000.0
        while now < 2000 + 120 {
            var input = PetInput(idle: 10); input.prefs = prefs
            let tick = driver.tick(now: now, layout: .compact(), input: input)
            times.append(now); drawn.append(tick.draw)
            now += tick.interval
        }
        let temperament = PetTemperament()
        let period = temperament.blinkEvery / PetPlayer.rate(.free)
        var starts = [Double](), was: CGFloat = 0
        for t in stride(from: 2000.0, to: 2120, by: 0.002) {
            let c = PetLife.blinkClosure(t, period: period, length: temperament.blinkLength, salt: 1)
            if was < 0.05, c >= 0.05 { starts.append(t) }
            was = c
        }
        XCTAssertGreaterThan(starts.count, 15)
        var onTime = 0, frames = 0
        for s in starts {
            // A tick lands within a twentieth of a second of the moment the lid begins to drop, and a few more while it moves.
            if times.contains(where: { $0 > s - 0.05 && $0 < s + 0.08 }) { onTime += 1 }
            frames += zip(times, drawn).filter { $0 >= s - 0.01 && $0 <= s + 0.25 && $1 }.count
        }
        XCTAssertGreaterThan(Double(onTime) / Double(starts.count), 0.88, "\(onTime) of \(starts.count) blinks were drawn as they began")
        XCTAssertGreaterThan(Double(frames) / Double(starts.count), 2.5, "a blink is several frames, not one")
        XCTAssertLessThan(Double(frames) / Double(starts.count), 9)
    }

    // MARK: A Mac that cannot spare it

    func testALowPowerMacTakesTheCatsCostlyGesturesAwayAndAHotOneAllOfThem() {
        let costly: [PetDirector.Kind] = [.hunt, .play, .wave, .stroll, .scratch, .startle, .tailPlay, .stretch]
        let cheap: [PetDirector.Kind] = [.groom, .glance, .yawn, .loaf, .nap, .peek]
        for kind in costly {
            XCTAssertFalse(PetDirector.allowed(kind, power: .saving), "\(kind)")
            XCTAssertEqual(PetDirector.weight(kind, layout: .header, focus: .free, idle: 999, working: false, power: .saving), 0)
            XCTAssertTrue(PetDirector.allowed(kind, power: .normal))
        }
        for kind in cheap {
            XCTAssertTrue(PetDirector.allowed(kind, power: .saving), "\(kind)")
            XCTAssertGreaterThan(PetDirector.weight(kind, layout: .compact, focus: .free, idle: 999, working: false, power: .saving), 0)
            XCTAssertEqual(PetDirector.weight(kind, layout: .compact, focus: .free, idle: 999, working: false, power: .minimal), 0, "hot: nothing")
        }
        // Whatever it was doing that it can no longer afford, it lets go of.
        let rig = DirectorDay(.compact)
        rig.director.start(.hunt, stage: rig.stage)
        rig.run(2) { _ in }
        XCTAssertEqual(rig.director.running?.kind, .hunt)
        rig.run(2) { $0.power = .saving }
        XCTAssertNil(rig.director.running, "the chase is over when the Mac starts saving power")
        // And a day of it never starts one.
        let day = DirectorDay(.header, seed: 6)
        var kinds = Set<PetDirector.Kind>()
        day.run(4 * 3600, dt: 0.5) { $0.power = .saving; $0.idle = 400 }
        for kind in day.kindsSeen { kinds.insert(kind) }
        XCTAssertTrue(kinds.isDisjoint(with: costly), "saving power: \(kinds)")
        XCTAssertFalse(kinds.isEmpty, "it still does the cheap things")
    }

    // MARK: What a frame costs

    func testAFrameIsCheapToMakeAndAPoseCostsNoAllocation() {
        let micros = PetBudget.costOfPose(frames: 20000)
        print("pose and player: \(String(format: "%.2f", micros)) us a frame (debug build)")
        XCTAssertLessThan(micros, 120, "a debug build still spends well under a tenth of a millisecond on the whole of a frame")
        // A pose is plain values (no arrays, no references): its size is its stride, and copying it is a copy.
        XCTAssertEqual(MemoryLayout<PetPose>.size, MemoryLayout<PetPose>.stride)
        XCTAssertLessThan(MemoryLayout<PetPose>.size, 1100)
        let paint = PetBudget.costOfDrawing(PetSim.compactPoses(step: 0.3).prefix(400).map { $0 }, rounds: 3)
        print("painting the wing: \(String(format: "%.1f", paint)) us a frame (debug build)")
        XCTAssertLessThan(paint, 400)
    }
}

/// The director on its own, for tests that run a long life of it with one thing changed at a time.
final class DirectorDay {
    var director: PetDirector
    let stage: PetStage
    var input = PetInput(idle: 400)
    private(set) var kindsSeen = [PetDirector.Kind]()
    private var time = 0.0
    init(_ layout: PetLayout, seed: Int = 1) {
        director = PetDirector(layout: layout, seed: seed)
        stage = layout == .compact ? .compact(height: 32) : .header(travel: 100)
    }
    func run(_ seconds: Double, dt: Double = 1.0 / 30, _ change: (inout PetInput) -> Void) {
        let end = time + seconds
        var was: PetDirector.Kind?
        while time < end {
            change(&input)
            director.update(dt: dt, input, stage: stage)
            let now = director.running?.kind
            if now != was, let now { kindsSeen.append(now) }
            was = now
            time += dt
        }
    }
}
