import AppKit
import XCTest
@testable import Nook

/// What the cat does and when: rhythm, priorities, interruptions, celebration triggers and the quiet rules. All on
/// simulated time and simulated state: no window, no session, no pointer.
final class PetDirectorTests: XCTestCase {
    /// A director and a world to drive it: `run` advances time, letting each test change the input as it goes.
    private final class Rig {
        var director: PetDirector
        var stage: PetStage
        var input = PetInput()
        var time = 0.0
        var dt = 1.0 / 30
        var poses: [PetPose] = []
        var kinds: [PetDirector.Kind?] = []
        var recordPoses = true
        /// How many celebrations began, and how many steps the cat was busy beyond breathing.
        var celebrationStarts = 0, busySteps = 0
        /// For each frame, whether a celebration was on.
        var celebratingFrames: [Bool] = []
        private var celebrating = false

        init(_ layout: PetLayout = .compact, seed: Int = 1, stage: PetStage? = nil) {
            director = PetDirector(layout: layout, seed: seed)
            self.stage = stage ?? (layout == .compact ? .compact(height: 32) : .header(travel: 100))
        }

        func run(_ seconds: Double, _ change: ((inout PetInput, Double) -> Void)? = nil) {
            let end = time + seconds - 1e-9
            while time < end {
                change?(&input, time)
                director.update(dt: dt, input, stage: stage)
                kinds.append(director.running?.kind)
                if director.isBusy { busySteps += 1 }
                let now = director.celebration != nil
                if now && !celebrating { celebrationStarts += 1 }
                celebrating = now
                celebratingFrames.append(now)
                if recordPoses { poses.append(director.pose(wall: 1000 + time, alert: 0, input: input, stage: stage)) }
                time += dt
            }
        }
        /// Runs until `condition` holds (or `limit` seconds pass); true when it did.
        @discardableResult func run(until limit: Double, _ change: ((inout PetInput, Double) -> Void)? = nil, _ condition: () -> Bool) -> Bool {
            let end = time + limit
            while time < end {
                run(dt, change)
                if condition() { return true }
            }
            return false
        }
        /// The largest change between two frames in `range` of the recorded poses.
        func jump(_ range: Range<Int>) -> CGFloat { worstJump(range).size }
        /// The largest change between two frames in `range`, where it was, and what was going on there.
        func worstJump(_ range: Range<Int>) -> (size: CGFloat, at: Int, what: String) {
            var worst: (size: CGFloat, at: Int, what: String) = (0, 0, "")
            for i in range.dropFirst() where i < poses.count {
                let d = poses[i].distance(to: poses[i - 1])
                if d > worst.size {
                    // Which numbers of the pose moved most (their index in `PetPose.combined`'s order).
                    var moved: [String] = []
                    _ = poses[i].combined(poses[i - 1]) { a, b in if abs(a - b) > d / 2 { moved.append("#\(moved.count)") }; return a }
                    var index = 0, big: [String] = []
                    _ = poses[i].combined(poses[i - 1]) { a, b in if abs(a - b) > d / 2 { big.append("\(index):\(Int(abs(a - b)))") }; index += 1; return a }
                    worst = (d, i, "frame \(i) t=\(Double(i) / 30): \(poses[i - 1].action) -> \(poses[i].action), gesture \(String(describing: kinds[i - 1])) -> \(String(describing: kinds[i])), moved \(big)")
                }
            }
            return worst
        }
    }

    // MARK: Rhythm

    /// Starts and ends of the gestures a long, undisturbed life makes.
    private func life(_ layout: PetLayout, seed: Int, hours: Double, input: PetInput = PetInput(idle: 60)) -> (starts: [Double], ends: [Double], kinds: [PetDirector.Kind]) {
        let rig = Rig(layout, seed: seed)
        rig.recordPoses = false; rig.dt = 0.1; rig.input = input
        var starts: [Double] = [], ends: [Double] = [], kinds: [PetDirector.Kind] = []
        var was: PetDirector.Kind?
        rig.run(hours * 3600) { _, _ in }
        for (i, kind) in rig.kinds.enumerated() {
            let t = Double(i) * rig.dt
            if kind != was {
                if let kind { starts.append(t); kinds.append(kind) } else { ends.append(t) }
                was = kind
            }
        }
        return (starts, ends, kinds)
    }

    /// The pauses between gestures, from the end of one to the start of the next, leaving out the ones that follow another (a startled
    /// cat washes itself a moment later): those are the chains, and they are tested on their own.
    private func independentGaps(_ result: (starts: [Double], ends: [Double], kinds: [PetDirector.Kind])) -> [Double] {
        var gaps: [Double] = []
        for (i, start) in result.starts.enumerated().dropFirst() { gaps.append(start - result.ends[i - 1]) }
        return gaps.filter { $0 > 5 }
    }

    func testIdleGesturesComeAtTheRhythmWithVariation() {
        for (layout, rhythm) in [(PetLayout.compact, PetDirector.compactRhythm), (.header, PetDirector.headerRhythm)] {
            let result = life(layout, seed: 5, hours: 6)
            XCTAssertGreaterThan(result.starts.count, 200, "\(layout)")
            XCTAssertGreaterThanOrEqual(result.starts[0], rhythm.first.lowerBound - 0.2); XCTAssertLessThanOrEqual(result.starts[0], rhythm.first.upperBound + 0.2, "the first gesture of a launch")
            let gaps = independentGaps(result)
            XCTAssertGreaterThan(gaps.count, 150)
            XCTAssertGreaterThanOrEqual(gaps.min() ?? 0, rhythm.between.lowerBound - 0.25, "never closer than the rhythm says (\(layout))")
            XCTAssertLessThanOrEqual(gaps.max() ?? 0, rhythm.between.upperBound + 0.25, "never further (\(layout))")
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let spread = (gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)).squareRoot()
            XCTAssertEqual(mean, (rhythm.between.lowerBound + rhythm.between.upperBound) / 2, accuracy: 4, "centred between the two (\(layout))")
            XCTAssertGreaterThan(spread, 8, "with variation, not a metronome (\(layout))")
            XCTAssertGreaterThan(Set(gaps.map { ($0 * 2).rounded() }).count, 40, "many different pauses (\(layout))")
        }
    }

    /// What matters for the idle cost of the collapsed island is how often it is drawn (`PetBudgetTests` counts the frames); this checks the
    /// share of the time the cat is doing something beyond breathing: gestures are a few seconds out of every minute.
    func testTheCollapsedCatIsBusyOnlyAFractionOfTheTime() {
        for seed in 0..<3 {
            let rig = Rig(.compact, seed: seed)
            rig.recordPoses = false; rig.dt = 0.1
            rig.input = PetInput(idle: 60)
            rig.run(6 * 3600) { _, _ in }
            let share = Double(rig.busySteps) / Double(rig.kinds.count)
            XCTAssertLessThan(share, 0.14, "seed \(seed): busy \(share)")
            XCTAssertGreaterThan(share, 0.04, "but it still does things")
        }
    }

    func testDifferentSeedsGiveDifferentLives() {
        let a = life(.compact, seed: 1, hours: 1), b = life(.compact, seed: 2, hours: 1)
        XCTAssertNotEqual(a.starts, b.starts)
        XCTAssertNotEqual(a.kinds, b.kinds)
    }

    func testNoGestureRepeatsRightAwayAndGroomingNeverComesTwiceRunning() {
        for layout in [PetLayout.compact, .header] {
            for seed in 0..<4 {
                let kinds = life(layout, seed: seed, hours: 4).kinds
                XCTAssertGreaterThan(kinds.count, 100)
                for (a, b) in zip(kinds, kinds.dropFirst()) { XCTAssertNotEqual(a, b, "\(layout) seed \(seed)") }
                XCTAssertFalse(zip(kinds, kinds.dropFirst()).contains { $0 == .groom && $1 == .groom })
            }
        }
        for pick in 0..<5000 {
            for focus in [PetFocus.free, .reading, .typing] {
                XCTAssertNotEqual(PetDirector.choose(after: .groom, pick: pick, seed: 3, layout: .compact, focus: focus, idle: 10, working: false), .groom)
            }
        }
    }

    func testEveryGestureIsReachable() {
        let wing = Set(life(.compact, seed: 7, hours: 12, input: PetInput(idle: 400)).kinds)
        let everyone: Set<PetDirector.Kind> = [.groom, .glance, .stretch, .wave, .play, .peek, .nap, .yawn, .loaf, .hunt, .scratch, .startle, .tailPlay]
        XCTAssertEqual(wing, everyone, "the wing has no strolls")
        let header = Set(life(.header, seed: 7, hours: 12, input: PetInput(idle: 400)).kinds)
        XCTAssertEqual(header, everyone.union([.stroll]))
    }

    // MARK: Napping, typing, reading, working

    func testNapsNeedRealInactivity() {
        for pick in 0..<4000 {
            for idle in [0.0, 5, 60, 149.9] {
                XCTAssertNotEqual(PetDirector.choose(after: nil, pick: pick, seed: 1, layout: .compact, focus: .free, idle: idle, working: false), .nap, "idle \(idle)")
                XCTAssertEqual(PetDirector.weight(.nap, layout: .header, focus: .free, idle: idle, working: false), 0)
            }
        }
        XCTAssertGreaterThan(PetDirector.weight(.nap, layout: .compact, focus: .free, idle: PetDirector.napAfter, working: false), 0)
        let napped = (0..<2000).filter { PetDirector.choose(after: nil, pick: $0, seed: 1, layout: .compact, focus: .free, idle: 300, working: false) == .nap }.count
        XCTAssertGreaterThan(napped, 200, "a user who has gone away is the one who gets a sleeping cat")
        // Not while the terminal works, and not while the user types or reads, however long it has been.
        XCTAssertEqual(PetDirector.weight(.nap, layout: .header, focus: .free, idle: 900, working: true), 0)
        XCTAssertEqual(PetDirector.weight(.nap, layout: .header, focus: .typing, idle: 900, working: false), 0)
        XCTAssertEqual(PetDirector.weight(.nap, layout: .header, focus: .reading, idle: 900, working: false), 0)
        // A whole evening at the keyboard: no nap.
        XCTAssertFalse(life(.compact, seed: 3, hours: 6, input: PetInput(idle: 20)).kinds.contains(.nap))
        XCTAssertFalse(life(.header, seed: 3, hours: 6, input: PetInput(idle: 100)).kinds.contains(.nap))
    }

    func testANapEndsGentlyWhenTheUserComesBackAndTheCatYawns() {
        let rig = Rig(.compact, seed: 2)
        rig.input = PetInput(idle: 400)
        rig.director.start(.nap, stage: rig.stage)
        rig.run(12) { _, _ in }
        XCTAssertEqual(rig.director.running?.kind, .nap)
        let back = rig.poses.count
        rig.run(until: 5, { input, _ in input.idle = 0 }) { rig.director.running == nil }
        XCTAssertNil(rig.director.running, "awake")
        let frames = rig.poses.count - back
        XCTAssertGreaterThan(Double(frames) / 30, 0.8, "waking takes its time")
        XCTAssertLessThan(Double(frames) / 30, 1.2)
        XCTAssertLessThan(rig.jump(back..<rig.poses.count), 3.5, "no jump out of bed (a cat curled the other way round swings its tail over as it wakes)")
        // It yawns, as a cat does on waking; and only then goes back to the usual pauses.
        var yawned = false
        rig.run(until: 2, { input, _ in input.idle = 0 }) { yawned = rig.director.running?.kind == .yawn; return yawned }
        XCTAssertTrue(yawned, "a woken cat yawns")
        rig.run(until: PetAnimation.yawnLength + 1, { input, _ in input.idle = 0 }) { rig.director.running == nil }
        XCTAssertGreaterThanOrEqual(rig.director.nextAt - rig.director.clock, PetDirector.compactRhythm.between.lowerBound - 0.5, "and then the pause before the next gesture")
    }

    func testTypingLeavesOnlyDiscreteGesturesAndReadingFewLivelyOnes() {
        for layout in [PetLayout.compact, .header] {
            var typing = Set<PetDirector.Kind>(), reading = Set<PetDirector.Kind>(), free = Set<PetDirector.Kind>()
            var strolls = (free: 0, reading: 0)
            for pick in 0..<4000 {
                if let kind = PetDirector.choose(after: nil, pick: pick, seed: 9, layout: layout, focus: .typing, idle: 999, working: false) { typing.insert(kind) }
                if let kind = PetDirector.choose(after: nil, pick: pick, seed: 9, layout: layout, focus: .reading, idle: 999, working: false) { reading.insert(kind); if kind == .stroll { strolls.reading += 1 } }
                if let kind = PetDirector.choose(after: nil, pick: pick, seed: 9, layout: layout, focus: .free, idle: 999, working: false) { free.insert(kind); if kind == .stroll { strolls.free += 1 } }
            }
            XCTAssertEqual(typing, [.groom, .glance, .yawn], "typing: only the discrete ones (\(layout))")
            XCTAssertTrue(reading.contains(.groom), "reading still allows discrete gestures")
            if layout == .header {
                XCTAssertGreaterThan(strolls.free, 0)
                XCTAssertLessThan(Double(strolls.reading), Double(strolls.free) * 0.5, "reading: far fewer walks")
            }
        }
        // And when it does stroll while the user reads, it does not go far.
        let rig = Rig(.header, seed: 4)
        rig.input = PetInput(focus: .reading, idle: 10)
        rig.dt = 0.1
        rig.run(1800) { _, _ in }
        let farthest = rig.poses.map(\.x).max() ?? 0
        XCTAssertGreaterThan(farthest, 1, "it still wanders a little")
        XCTAssertLessThanOrEqual(farthest, 0.6 * 100 + 0.5, "but never beyond 60% of the stage")
        for index in PetAnimation.shortRoutes { XCTAssertLessThanOrEqual(PetAnimation.routes[index].map(\.to).max() ?? 0, 0.6) }
    }

    func testStartingToTypeWindsDownALivelyGestureButLetsGroomingFinish() {
        let lively = Rig(.compact, seed: 1)
        lively.director.start(.stretch, stage: lively.stage)
        lively.run(1.5) { _, _ in }
        let at = lively.poses.count
        lively.run(until: 2, { input, _ in input.focus = .typing }) { lively.director.running == nil }
        XCTAssertNil(lively.director.running, "the stretch gave way")
        XCTAssertLessThan(Double(lively.poses.count - at) / 30, PetDirector.fadeFocus + 0.2)
        XCTAssertLessThan(lively.jump(at..<lively.poses.count), 5)

        let quiet = Rig(.compact, seed: 1)
        quiet.director.start(.groom, stage: quiet.stage)
        quiet.run(1.0) { input, _ in input.focus = .typing }
        XCTAssertEqual(quiet.director.running?.kind, .groom, "grooming is quiet enough to carry on")
        let glance = Rig(.compact, seed: 1)
        glance.director.start(.glance, stage: glance.stage)
        glance.run(1.0) { input, _ in input.focus = .typing }
        XCTAssertEqual(glance.director.running?.kind, .glance, "and so is a look around")
    }

    func testTheWorkingCatInTheWingDoesNothingIdleButTheHeaderMayStillPlay() {
        let wing = life(.compact, seed: 3, hours: 3, input: PetInput(working: true, idle: 500))
        XCTAssertTrue(wing.kinds.isEmpty, "on duty")
        let header = life(.header, seed: 3, hours: 3, input: PetInput(working: true, idle: 500))
        XCTAssertFalse(header.kinds.isEmpty)
        XCTAssertFalse(header.kinds.contains(.nap), "but never asleep on the job")
        // When the terminal starts working the wing's gesture ends, gently.
        let rig = Rig(.compact, seed: 1)
        rig.director.start(.play, stage: rig.stage)
        rig.run(1) { _, _ in }
        let at = rig.poses.count
        rig.run(until: 2, { input, _ in input.working = true }) { rig.director.running == nil }
        XCTAssertNil(rig.director.running)
        XCTAssertLessThan(rig.jump(at..<rig.poses.count), 5)
    }

    func testAPeekNeedsRoomAndIsReservedForTheHeaderOtherwise() {
        XCTAssertTrue(PetStage.compact(height: 28).canPeek); XCTAssertTrue(PetStage.compact(height: 32).canPeek)
        XCTAssertFalse(PetStage.compact(height: 20).canPeek, "a wing too short for it keeps no peek")
        XCTAssertTrue(PetStage.header(travel: 100).canPeek)
        for pick in 0..<3000 {
            XCTAssertNotEqual(PetDirector.choose(after: nil, pick: pick, seed: 1, layout: .compact, focus: .free, idle: 10, working: false, canPeek: false), .peek)
        }
        XCTAssertEqual(PetDirector.weight(.peek, layout: .compact, focus: .typing, idle: 0, working: false), 0, "never while typing")
    }

    // MARK: Priorities and interruptions

    func testThePointerInterruptsAGestureSmoothlyAndHoldsTheRestOffWhileItStays() {
        let rig = Rig(.compact, seed: 1)
        rig.director.start(.groom, stage: rig.stage)
        rig.run(1.0) { _, _ in }
        XCTAssertEqual(rig.director.activity, .gesture(.groom))
        let at = rig.poses.count
        rig.run(1.0) { input, _ in input.gaze = PetSim.pointer }
        XCTAssertNil(rig.director.running, "the gesture was let go")
        XCTAssertEqual(rig.director.activity, .curious)
        XCTAssertLessThan(rig.jump(at..<rig.poses.count), 4, "a fade, not a cut")
        XCTAssertGreaterThan(rig.director.curious, 0.95)
        // Staying near for ten minutes: nothing decorative ever starts.
        rig.recordPoses = false
        rig.run(600) { input, _ in input.gaze = PetSim.pointer }
        XCTAssertTrue(rig.kinds.suffix(18000).allSatisfy { $0 == nil })
        // Leaving: it returns to the plain sit, smoothly.
        rig.recordPoses = true
        let left = rig.poses.count
        rig.run(1.5) { input, _ in input.gaze = nil }
        XCTAssertEqual(rig.director.activity, .resting)
        XCTAssertLessThan(rig.jump(left..<rig.poses.count), 2.5)
        XCTAssertEqual(rig.director.curious, 0)
        let rest = PetAnimation.sit(time: 1000 + rig.time - rig.dt)
        XCTAssertLessThan(rig.poses.last!.distance(to: rest), 0.05, "back to the posture it had")
    }

    func testADragTakesOverAtOnce() {
        for kind in [PetDirector.Kind.stretch, .play, .groom, .peek] {
            let rig = Rig(.compact, seed: 1)
            rig.director.start(kind, stage: rig.stage)
            rig.run(kind == .peek ? 3.2 : 1.5) { _, _ in }
            XCTAssertNotNil(rig.director.running)
            let at = rig.poses.count
            rig.run(0.2) { input, _ in input.gaze = PetSim.pointer; input.dragging = true }
            XCTAssertNil(rig.director.running, "\(kind): gone within a fifth of a second")
            XCTAssertEqual(rig.director.activity, .dragged, "\(kind)")
            XCTAssertLessThan(Double(rig.poses.count - at) / 30, 0.25)
        }
        // While it is dragged the cat only watches: no sniffing, no gestures, and a celebration waits.
        let rig = Rig(.compact, seed: 1)
        rig.input.completions = 1
        rig.run(1) { input, _ in input.dragging = true; input.gaze = PetSim.pointer }
        rig.run(20) { input, _ in input.dragging = true; input.gaze = PetSim.pointer; input.completions = 2 }
        XCTAssertNil(rig.director.celebration)
        XCTAssertEqual(rig.director.activity, .dragged)
    }

    func testAnAlertOutranksGesturesAndCelebrations() {
        let rig = Rig(.compact, seed: 1)
        rig.input.completions = 3
        rig.director.start(.stretch, stage: rig.stage)
        rig.run(1) { _, _ in }
        let at = rig.poses.count
        // The alert begins and the finish arrives at the same moment, as a hook does.
        rig.run(0.6) { input, _ in input.perk = 1; input.completions = 4 }
        XCTAssertNil(rig.director.running, "the stretch gave way to the alert")
        XCTAssertNil(rig.director.celebration, "and the celebration waits its turn")
        XCTAssertLessThan(rig.jump(at..<rig.poses.count), 5)
        rig.run(6) { input, _ in input.perk = 1 }
        XCTAssertNil(rig.director.celebration, "while the alert is on")
        XCTAssertTrue(rig.kinds.allSatisfy { $0 == nil || $0 == .stretch }, "and no gesture starts either")
        // The alert is over: now it celebrates, within the time it remains relevant.
        var started = false
        rig.run(until: 3, { input, _ in input.perk = 0 }) { started = rig.director.celebration != nil; return started }
        XCTAssertTrue(started, "after the alert, the celebration")
        XCTAssertEqual(rig.director.activity, .celebrating)
    }

    func testACelebrationThatWaitedTooLongIsForgotten() {
        let rig = Rig(.compact, seed: 1)
        rig.recordPoses = false
        rig.input.completions = 0
        rig.run(1) { _, _ in }
        rig.run(PetDirector.celebrationExpiry + 3) { input, _ in input.completions = 1; input.perk = 1 }
        var celebrated = false
        rig.run(20) { input, _ in input.perk = 0; input.completions = 1; celebrated = celebrated || rig.director.celebration != nil }
        XCTAssertFalse(celebrated, "a finish from ten seconds ago is old news")
    }

    func testACompletionBeatsDecorativeGesturesAndTheUserBeatsTheCompletion() {
        let rig = Rig(.compact, seed: 1)
        rig.director.start(.groom, stage: rig.stage)
        rig.run(0.5) { _, _ in }
        let at = rig.poses.count
        rig.run(until: 2, { input, _ in input.completions = 1 }) { rig.director.celebration != nil }
        XCTAssertNotNil(rig.director.celebration)
        XCTAssertLessThan(Double(rig.poses.count - at) / 30, 0.5, "it starts after a short moment")
        XCTAssertGreaterThanOrEqual(Double(rig.poses.count - at) / 30, PetDirector.celebrationDelay - 0.05, "but not before the alert had its chance")
        rig.run(2) { input, _ in input.completions = 1 }
        XCTAssertNil(rig.director.celebration, "one hop, over")
        XCTAssertLessThan(rig.jump(at..<rig.poses.count), 5)

        // The user is near when a task finishes: the pointer wins, and the hop waits until it goes.
        let near = Rig(.compact, seed: 1)
        near.input.completions = 5
        near.run(1) { _, _ in }
        near.run(3) { input, _ in input.gaze = PetSim.pointer; input.completions = 6 }
        XCTAssertNil(near.director.celebration)
        var played = false
        near.run(until: 4, { input, _ in input.gaze = nil; input.completions = 6 }) { played = near.director.celebration != nil; return played }
        XCTAssertTrue(played, "still worth celebrating a few seconds later")

        // And a celebration under way gives way to the pointer.
        let busy = Rig(.compact, seed: 1)
        busy.input.completions = 0
        busy.run(1) { _, _ in }
        busy.run(until: 2, { input, _ in input.completions = 1 }) { busy.director.celebration != nil }
        busy.run(0.3) { input, _ in input.completions = 1 }
        let from = busy.poses.count
        busy.run(1) { input, _ in input.completions = 1; input.gaze = PetSim.pointer }
        XCTAssertNil(busy.director.celebration)
        XCTAssertLessThan(busy.jump(from..<busy.poses.count), 5)
    }

    func testNothingDecorativeStartsWhileAHigherPriorityIsOn() {
        let cases: [(String, (inout PetInput) -> Void)] = [("pointer", { $0.gaze = PetSim.pointer }), ("drag", { $0.dragging = true }), ("alert", { $0.perk = 0.6 })]
        for (name, apply) in cases {
            for layout in [PetLayout.compact, .header] {
                let rig = Rig(layout, seed: 3)
                rig.recordPoses = false; rig.dt = 0.1
                rig.run(900) { input, _ in input = PetInput(idle: 400); apply(&input) }
                XCTAssertTrue(rig.kinds.allSatisfy { $0 == nil }, "\(name) in \(layout)")
            }
        }
    }

    /// A day compressed: the world's state flips at random moments among everything it can be.
    private func shuffledDay(_ layout: PetLayout, seed: Int, drags: Bool) -> Rig {
        let rig = Rig(layout, seed: seed)
        var generator = SeededGenerator(seed: UInt64(seed + 11))
        var current = PetInput(idle: 200), nextChange = 0.0
        var completions = 0, perk: CGFloat = 0
        rig.run(40 * 60) { input, t in
            if t >= nextChange {
                nextChange = t + Double.random(in: 1...25, using: &generator)
                current = PetInput(working: Bool.random(using: &generator) && Int.random(in: 0..<4, using: &generator) == 0,
                                   gaze: Int.random(in: 0..<5, using: &generator) == 0 ? PetGaze(dx: .random(in: -2...2, using: &generator), dy: .random(in: -2...2, using: &generator)) : nil,
                                   dragging: drags && Int.random(in: 0..<25, using: &generator) == 0,
                                   perk: Int.random(in: 0..<8, using: &generator) == 0 ? 1 : 0, perkAge: 1,
                                   completions: completions, focus: [.free, .free, .reading, .typing].randomElement(using: &generator)!,
                                   idle: [0, 30, 400].randomElement(using: &generator)!)
                if current.dragging { current.gaze = PetGaze(dx: 1, dy: 0) }
                if Int.random(in: 0..<6, using: &generator) == 0 { completions += 1; current.completions = completions }
            }
            // The alert's pull follows its timeline: it rises over 0.3 s and falls over 0.8 s, never a step.
            let target = current.perk
            perk = target > perk ? min(target, perk + CGFloat(rig.dt / 0.3)) : max(target, perk - CGFloat(rig.dt / 0.8))
            input = current
            input.perk = perk
        }
        return rig
    }

    func testRandomInterruptionsNeverMakeThePoseJump() {
        for layout in [PetLayout.compact, .header] {
            for seed in 0..<3 {
                let calm = shuffledDay(layout, seed: seed, drags: false)
                let worst = calm.worstJump(0..<calm.poses.count)
                XCTAssertLessThan(worst.size, 7, "\(layout) seed \(seed): every interruption is a fade (\(worst.what))")
                // A drag is the exception: it takes over within a tenth of a second, whatever the cat was in the middle of.
                let dragged = shuffledDay(layout, seed: seed, drags: true)
                XCTAssertLessThan(dragged.jump(0..<dragged.poses.count), 16, "\(layout) seed \(seed)")
            }
        }
    }

    func testRandomLivesNeverLeaveTheDrawingArea() {
        for layout in [PetLayout.compact, .header] {
            for seed in 0..<3 {
                let rig = shuffledDay(layout, seed: seed, drags: true)
                let scale = rig.stage.scale
                for pose in rig.poses {
                    let b = pose.bounds
                    let what = "\(layout) \(pose.action) y=\(pose.y) head=\(pose.head) spark=\(pose.sparkle)"
                    switch layout {
                    case .compact:
                        let left = PetAnimation.compactAnchor + pose.x + b.minX * scale, right = PetAnimation.compactAnchor + pose.x + b.maxX * scale
                        XCTAssertGreaterThanOrEqual(left, PetAnimation.wing.lowerBound, what); XCTAssertLessThanOrEqual(right, PetAnimation.wing.upperBound, what)
                        XCTAssertLessThanOrEqual(7 + b.maxY * scale, 32, what)
                        if pose.y > -1 { XCTAssertGreaterThanOrEqual(7 + b.minY * scale, 0, what) }
                    case .header:
                        XCTAssertGreaterThanOrEqual(HeaderPetView.homeX + pose.x + b.minX * scale, 0, what)
                        XCTAssertLessThanOrEqual(HeaderPetView.homeX + pose.x + b.maxX * scale, 164, what)
                        XCTAssertLessThanOrEqual(HeaderPetView.ground + b.maxY * scale, 32, what)
                        if pose.y > -1 { XCTAssertGreaterThanOrEqual(HeaderPetView.ground + b.minY * scale, 0, what) }
                    }
                }
            }
        }
    }

    func testAStrollThatIsInterruptedStopsWhereItIsAndWalksHomeAfterwards() {
        let rig = Rig(.header, seed: 4)
        rig.director.start(.stroll, stage: rig.stage)
        // Walk until it is well on its way.
        rig.run(until: 12, nil) { rig.poses.last.map { $0.x > 25 && $0.action == .walk } ?? false }
        XCTAssertGreaterThan(rig.poses.last?.x ?? 0, 25)
        let from = rig.poses.count
        rig.run(3) { input, _ in input.gaze = PetSim.pointer }
        XCTAssertNil(rig.director.running)
        let stopped = rig.director.restX
        XCTAssertGreaterThan(stopped, 20, "it stays where it stopped")
        XCTAssertLessThan(rig.jump(from..<rig.poses.count), 4)
        for pose in rig.poses.suffix(30) { XCTAssertEqual(pose.x, stopped, accuracy: 0.01) }
        // The pointer leaves: after a few calm seconds it walks home and nothing else starts first.
        var kinds: [PetDirector.Kind] = []
        rig.run(until: 40, { input, _ in input.gaze = nil }) {
            if let kind = rig.director.running?.kind, kinds.last != kind { kinds.append(kind) }
            return rig.director.restX == 0 && rig.director.running == nil
        }
        XCTAssertEqual(kinds, [.home], "straight home")
        XCTAssertEqual(rig.poses.last?.x ?? 1, 0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(rig.director.nextAt - rig.director.clock, 5, "and a rest before the next gesture")
    }

    func testLandingAfterADragIsSoftAndGivesWayToTheUser() {
        let rig = Rig(.header, seed: 1)
        rig.run(1) { _, _ in }
        rig.director.land()
        XCTAssertEqual(rig.director.activity, .landing)
        let from = rig.poses.count
        rig.run(PetAnimation.landLength + 0.3) { _, _ in }
        XCTAssertNil(rig.director.landing, "over within a second")
        XCTAssertGreaterThan(rig.poses[from...].map(\.y).max() ?? 0, 2, "it came down from above")
        XCTAssertGreaterThanOrEqual(rig.poses[from...].map(\.y).min() ?? 0, 0)
        XCTAssertLessThan(rig.jump(from..<rig.poses.count), 5)
        // Dragged again: no landing.
        let again = Rig(.header, seed: 1)
        again.run(0.5) { input, _ in input.dragging = true; input.gaze = PetSim.pointer }
        again.director.land()
        XCTAssertNil(again.director.landing)
        // The pointer arriving mid-landing takes over.
        let busy = Rig(.header, seed: 1)
        busy.run(0.2) { _, _ in }
        busy.director.land()
        busy.run(0.3) { _, _ in }
        busy.run(0.6) { input, _ in input.gaze = PetSim.pointer }
        XCTAssertNil(busy.director.landing)
    }

    func testTheLandingWaitsForTheConnectionToFinishThenLandsOnce() {
        var landing = PetLanding()
        XCTAssertFalse(landing.ready(now: 0, expanded: true, contentVisible: true, connectionSheet: false), "nothing was dropped")
        landing.dropped(at: 10)
        XCTAssertFalse(landing.ready(now: 10.1, expanded: false, contentVisible: false, connectionSheet: false), "the island is still opening")
        XCTAssertFalse(landing.ready(now: 10.5, expanded: true, contentVisible: false, connectionSheet: false), "its content is not showing yet")
        XCTAssertFalse(landing.ready(now: 11, expanded: true, contentVisible: true, connectionSheet: true), "the connection sheet covers the header")
        XCTAssertTrue(landing.ready(now: 14, expanded: true, contentVisible: true, connectionSheet: false), "connected: it lands")
        XCTAssertFalse(landing.ready(now: 14.1, expanded: true, contentVisible: true, connectionSheet: false), "once")
        landing.dropped(at: 100)
        XCTAssertFalse(landing.ready(now: 100 + PetLanding.patience + 1, expanded: true, contentVisible: true, connectionSheet: false), "forgotten after a while")
        landing.dropped(at: 200); landing.cancel()
        XCTAssertFalse(landing.ready(now: 201, expanded: true, contentVisible: true, connectionSheet: false), "the island closed first")
    }

    // MARK: Celebration

    func testTheCatCelebratesOnlyWhenCompletionsGrowAndNeverRepeatsForTheSameOne() {
        func celebrations(_ run: (Rig) -> Void) -> Int {
            let rig = Rig(.compact, seed: 1)
            rig.recordPoses = false
            run(rig)
            return rig.celebrationStarts
        }
        // Completions that were already there when the cat appeared are history.
        XCTAssertEqual(celebrations { rig in rig.input.completions = 7; rig.run(60) { _, _ in } }, 0)
        // One more: one celebration, however long the number stays.
        XCTAssertEqual(celebrations { rig in rig.input.completions = 7; rig.run(1) { _, _ in }; rig.input.completions = 8; rig.run(60) { _, _ in } }, 1)
        // The same completion arriving by two channels (the number moves twice within moments): one celebration.
        XCTAssertEqual(celebrations { rig in
            rig.input.completions = 1; rig.run(1) { _, _ in }
            rig.run(0.5) { input, _ in input.completions = 2 }; rig.run(2) { input, _ in input.completions = 3 }; rig.run(30) { _, _ in }
        }, 1)
        // A later, separate finish: a second one.
        XCTAssertEqual(celebrations { rig in
            rig.input.completions = 1; rig.run(1) { _, _ in }
            rig.input.completions = 2; rig.run(PetDirector.celebrationCooldown + 3) { _, _ in }
            rig.input.completions = 3; rig.run(10) { _, _ in }
        }, 2)
        // The number going down or staying put is not a finish.
        XCTAssertEqual(celebrations { rig in rig.input.completions = 5; rig.run(1) { _, _ in }; rig.input.completions = 2; rig.run(30) { _, _ in }; rig.input.completions = 2; rig.run(30) { _, _ in } }, 0)
        // Completions that arrived while the cat was out of sight are not celebrated when it comes back.
        let rig = Rig(.header, seed: 1)
        rig.input.completions = 1; rig.run(1) { _, _ in }
        rig.director.settle()
        rig.input.completions = 4
        rig.run(20) { _, _ in }
        XCTAssertEqual(rig.celebrationStarts, 0)
    }

    /// The alert's own timeline (as the peek runs it in the app) drives the cat's reaction here.
    func testAFinishedTaskIsFirstAnAlertAndThenOneCelebration() {
        var timeline = AlertPeekTimeline()
        timeline.begin(NookAlert(id: 1, sessionID: "a", kind: .finished, title: "api", message: "Claude terminó."), now: 0, motion: true)
        let rig = Rig(.compact, seed: 1)
        var perks: [CGFloat] = []
        rig.run(8) { input, t in
            // The hook's Stop reaches the model at the same moment as the alert: the finish is told a moment before the peek.
            input.completions = t > 0.05 ? 1 : 0
            input.perk = timeline.perk(at: t); input.perkAge = t
            perks.append(input.perk)
        }
        XCTAssertEqual(rig.celebrationStarts, 1)
        let start = rig.celebratingFrames.firstIndex(of: true) ?? 0
        XCTAssertGreaterThan(perks.max() ?? 0, 0.99, "it looked up first")
        XCTAssertGreaterThan(Double(start) / 30, 2.5, "the alert had the cat's attention")
        XCTAssertLessThan(Double(start) / 30, 4.5, "and the hop follows while the finish is still news")
        for (i, celebrating) in rig.celebratingFrames.enumerated() where celebrating { XCTAssertEqual(perks[i], 0, accuracy: 0.001, "never both at once (frame \(i))") }
        XCTAssertGreaterThan(rig.poses.suffix(60).map { $0.y }.max() ?? 1, -1)
    }

    func testAQuestionThatNeedsAnAnswerPerksTheCatAndIsNeverCelebrated() {
        var timeline = AlertPeekTimeline()
        timeline.begin(NookAlert(id: 2, sessionID: "a", kind: .question, title: "api", message: "Do you want to proceed?"), now: 0, motion: true)
        let rig = Rig(.compact, seed: 1)
        rig.input.completions = 4
        rig.run(10) { input, t in input.completions = 4; input.perk = timeline.perk(at: t); input.perkAge = t }
        XCTAssertEqual(rig.celebrationStarts, 0, "a permission request is not a success")
        XCTAssertGreaterThan(rig.poses.map { $0.look.x }.max() ?? 0, 1.5, "it looks toward the bell")
        XCTAssertGreaterThan(rig.poses.map { $0.eyes }.max() ?? 0, 1.1, "eyes wide")
        XCTAssertTrue(rig.kinds.allSatisfy { $0 == nil }, "and no idle gesture while the island is calling or just after")
        XCTAssertEqual(rig.director.activity, .resting)
    }

    func testOnlyTrustedCompletionsReachTheCat() {
        // The model grows `completions` for Claude's own closing line or its Stop hook; errors and questions never do.
        let model = AppModel(receivesSignals: false)
        model.terminalBridge.runScript = { _ in }
        let tab = TerminalTabSnapshot(windowID: 3, windowTitle: "IA", index: 1, tty: "/dev/ttys080", customTitle: "", processes: ["claude"], busy: true, selected: true, text: "⏺ hola", history: false)
        model.updateExternalTabs([tab], ttys: ["/dev/ttys080"])
        let session = model.sessions[0]
        let rig = Rig(.compact, seed: 1)
        func sync() { rig.input.completions = model.completions; rig.run(3) { _, _ in } }
        sync()
        let now = Date()
        model.raiseAlert(.failed, for: session, message: "Claude terminó con un error.", now: now)
        model.raiseAlert(.question, for: session, message: "Do you want to proceed?", now: now.addingTimeInterval(20))
        sync()
        XCTAssertEqual(model.completions, 0)
        XCTAssertEqual(rig.celebrationStarts, 0, "no celebration for errors, cancellations or permission requests")
        model.noteCompletion(for: session, now: now.addingTimeInterval(40))
        model.noteCompletion(for: session, now: now.addingTimeInterval(41))
        sync()
        rig.run(5) { _, _ in }
        XCTAssertEqual(model.completions, 1)
        XCTAssertEqual(rig.celebrationStarts, 1)
    }

    // MARK: Who the cat is

    private func counts(_ prefs: PetPreferences, layout: PetLayout = .compact, idle: Double = 999, dayPart: PetDayPart = .day, picks: Int = 8000) -> [PetDirector.Kind: Int] {
        var counts: [PetDirector.Kind: Int] = [:]
        for pick in 0..<picks {
            if let kind = PetDirector.choose(after: nil, pick: pick, seed: 5, layout: layout, focus: .free, idle: idle, working: false, personality: prefs.personality, dayPart: dayPart) { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    func testEachPersonalityFavoursItsOwnGestures() {
        func prefs(_ personality: PetPersonality) -> PetPreferences { var p = PetPreferences(); p.personality = personality; return p }
        let curious = counts(prefs(.curious), idle: 20), playful = counts(prefs(.playful), idle: 20), calm = counts(prefs(.calm), idle: 20), sleepy = counts(prefs(.sleepy), idle: 20)
        XCTAssertGreaterThan(playful[.hunt, default: 0], curious[.hunt, default: 0] * 3 / 2); XCTAssertGreaterThan(curious[.hunt, default: 0], calm[.hunt, default: 0] * 2)
        XCTAssertGreaterThan(playful[.play, default: 0], curious[.play, default: 0]); XCTAssertLessThan(sleepy[.play, default: 0], curious[.play, default: 0] / 3)
        XCTAssertGreaterThan(calm[.loaf, default: 0], curious[.loaf, default: 0] * 3 / 2); XCTAssertGreaterThan(sleepy[.yawn, default: 0], curious[.yawn, default: 0] * 2)
        XCTAssertGreaterThan(curious[.peek, default: 0], calm[.peek, default: 0] * 0 + 1)
        // A cat that has been left alone for long: the sleepy one naps most of the time, the playful one rarely.
        let napsSleepy = counts(prefs(.sleepy))[.nap, default: 0], napsCurious = counts(prefs(.curious))[.nap, default: 0], napsPlayful = counts(prefs(.playful))[.nap, default: 0]
        XCTAssertGreaterThan(napsSleepy, napsCurious); XCTAssertGreaterThan(napsCurious, napsPlayful)
        XCTAssertGreaterThan(Double(napsSleepy) / 8000, 0.3)
    }

    func testASleepyCatNapsSoonerAndEveryCatSoonerAtNight() {
        XCTAssertEqual(PetDirector.napThreshold(personality: .curious, dayPart: .day), PetDirector.napAfter, "the plain cat: two and a half minutes, as always")
        XCTAssertLessThan(PetDirector.napThreshold(personality: .sleepy, dayPart: .day), PetDirector.napAfter / 2)
        XCTAssertGreaterThan(PetDirector.napThreshold(personality: .playful, dayPart: .day), PetDirector.napAfter)
        for personality in PetPersonality.allCases { XCTAssertLessThan(PetDirector.napThreshold(personality: personality, dayPart: .night), PetDirector.napThreshold(personality: personality, dayPart: .day)) }
        XCTAssertEqual(PetDirector.weight(.nap, layout: .compact, focus: .free, idle: 80, working: false, personality: .sleepy), 6 * 3, "after a minute and a bit, a sleepy cat is ready")
        XCTAssertEqual(PetDirector.weight(.nap, layout: .compact, focus: .free, idle: 80, working: false, personality: .curious), 0)
        XCTAssertGreaterThan(PetDirector.weight(.nap, layout: .compact, focus: .free, idle: 100, working: false, personality: .curious, dayPart: .night), 0)
    }

    func testTheHourTiltsWhatTheCatFeelsLike() {
        let night = counts(PetPreferences(), idle: 20, dayPart: .night), day = counts(PetPreferences(), idle: 20), morning = counts(PetPreferences(), idle: 20, dayPart: .morning)
        XCTAssertGreaterThan(night[.yawn, default: 0], day[.yawn, default: 0] * 3 / 2, "yawns at night")
        XCTAssertGreaterThan(morning[.stretch, default: 0], day[.stretch, default: 0] * 13 / 10, "stretches in the morning")
        XCTAssertLessThan(night[.hunt, default: 0], day[.hunt, default: 0])
        XCTAssertEqual(PetDirector.bias(.groom, personality: .curious, dayPart: .day), 1, "the plain cat in the daytime is the unbiased one")
        for kind in PetDirector.Kind.allCases { XCTAssertEqual(PetDirector.bias(kind, personality: .curious, dayPart: .evening) > 0, true) }
    }

    func testActivityStretchesTheWaitBetweenGesturesAndNoneStartsNothing() {
        func meanGap(_ activity: PetActivity, personality: PetPersonality = .curious) -> Double {
            var prefs = PetPreferences(); prefs.activity = activity; prefs.personality = personality
            let rig = Rig(.compact, seed: 3)
            rig.recordPoses = false; rig.dt = 0.1; rig.input = PetInput(idle: 20); rig.input.prefs = prefs
            rig.run(4 * 3600) { _, _ in }
            var starts = [Double](), ends = [Double](), was: PetDirector.Kind?
            for (i, kind) in rig.kinds.enumerated() {
                if kind != was { if kind != nil { starts.append(Double(i) * 0.1) } else { ends.append(Double(i) * 0.1) }; was = kind }
            }
            let gaps = zip(starts.dropFirst(), ends).map { $0 - $1 }.filter { $0 > 5 }
            return gaps.isEmpty ? .infinity : gaps.reduce(0, +) / Double(gaps.count)
        }
        let low = meanGap(.low), normal = meanGap(.normal), high = meanGap(.high)
        XCTAssertGreaterThan(low, normal * 1.6); XCTAssertGreaterThan(normal, high * 1.6, "low \(low), normal \(normal), high \(high)")
        XCTAssertEqual(normal, 52.5, accuracy: 6)
        XCTAssertEqual(meanGap(.none), .infinity, "a cat asked to do nothing starts nothing")
        XCTAssertGreaterThan(meanGap(.normal, personality: .sleepy), normal, "a sleepy cat takes longer"); XCTAssertLessThan(meanGap(.normal, personality: .playful), normal)
        // Changing the setting takes effect: a cat that had been told to do nothing, now told to do a lot, soon does something.
        var prefs = PetPreferences(); prefs.activity = .none
        let rig = Rig(.compact, seed: 4)
        rig.recordPoses = false; rig.input = PetInput(idle: 20); rig.input.prefs = prefs
        rig.run(600) { _, _ in }
        XCTAssertTrue(rig.kinds.allSatisfy { $0 == nil })
        var started = false
        rig.run(until: 90, { input, _ in input.prefs.activity = .high }) { started = rig.director.running != nil; return started }
        XCTAssertTrue(started, "it gets going within a minute and a half")
    }

    // MARK: What follows what

    func testAStartledCatOftenWashesItselfAfterwardsAsIfItHadMeantTo() {
        var followed = 0
        let trials = 200
        for seed in 0..<trials {
            let rig = Rig(.compact, seed: seed)
            rig.recordPoses = false; rig.input = PetInput(idle: 20)
            rig.director.start(.startle, stage: rig.stage)
            var next: PetDirector.Kind?
            rig.run(until: 12, nil) { if rig.director.running?.kind != .startle, let k = rig.director.running?.kind { next = k; return true }; return false }
            if next == .groom { followed += 1 }
        }
        XCTAssertGreaterThan(Double(followed) / Double(trials), 0.5); XCTAssertLessThan(Double(followed) / Double(trials), 0.8, "about two in three: \(followed) of \(trials)")
        let (kind, delay, chance) = PetDirector.followUp(after: .startle, variant: 0)!
        XCTAssertEqual(kind, .groom); XCTAssertLessThan(delay.upperBound, 2); XCTAssertEqual(chance, 0.65)
        XCTAssertEqual(PetDirector.followUp(after: .hunt, variant: 1)?.kind, .groom, "a missed pounce is washed off"); XCTAssertEqual(PetDirector.followUp(after: .stretch, variant: 0)?.kind, .yawn)
        XCTAssertNil(PetDirector.followUp(after: .nap, variant: 0)); XCTAssertNil(PetDirector.followUp(after: .peek, variant: 0))
    }

    func testAFollowUpGivesWayToTheUserAndToAnAlert() {
        for interruption in ["pointer", "alert", "drag"] {
            var washed = 0
            for seed in 0..<40 {
                let rig = Rig(.compact, seed: seed)
                rig.recordPoses = false; rig.input = PetInput(idle: 20)
                rig.director.start(.startle, stage: rig.stage)
                rig.run(until: 5, nil) { rig.director.running == nil }
                rig.run(0.05) { input, _ in
                    switch interruption {
                    case "pointer": input.gaze = PetSim.pointer
                    case "alert": input.perk = 1
                    default: input.dragging = true; input.gaze = PetSim.pointer
                    }
                }
                rig.run(10) { input, _ in
                    switch interruption {
                    case "pointer": input.gaze = PetSim.pointer
                    case "alert": input.perk = 1
                    default: input.dragging = true; input.gaze = PetSim.pointer
                    }
                    if rig.director.running?.kind == .groom { washed += 1 }
                }
            }
            XCTAssertEqual(washed, 0, "\(interruption): nothing decorative starts while the user or an alert has the cat")
        }
    }

    func testAWokenCatYawnsButNotOnDuty() {
        let rig = Rig(.compact, seed: 3)
        rig.director.start(.nap, stage: rig.stage)
        rig.input = PetInput(idle: 400); rig.recordPoses = false
        rig.run(10) { _, _ in }
        var yawned = false
        rig.run(until: 4, { input, _ in input.working = true; input.idle = 0 }) { if rig.director.running?.kind == .yawn { yawned = true }; return false }
        XCTAssertFalse(yawned, "a cat on duty in the wing does nothing but watch")
    }

    func testAGestureJustDoneIsLessLikelyToComeAgain() {
        let plain = (0..<6000).filter { PetDirector.choose(after: nil, pick: $0, seed: 2, layout: .compact, focus: .free, idle: 20, working: false) == .groom }.count
        let weary = (0..<6000).filter { PetDirector.choose(after: nil, pick: $0, seed: 2, PetDirector.Mood(layout: .compact, focus: .free, idle: 20, working: false), recent: { $0 == .groom ? 0.2 : 1 }) == .groom }.count
        XCTAssertLessThan(weary, plain / 2, "grooming that was done a moment ago: \(weary) against \(plain)")
        // In a life: how long since each kind decides, so a day does not repeat itself in a pattern.
        let life = self.life(.compact, seed: 12, hours: 6, input: PetInput(idle: 20)).kinds
        var windows = 0, repeats = 0
        for i in 0..<(life.count - 3) { windows += 1; if life[i] == life[i + 2] { repeats += 1 } }
        XCTAssertLessThan(Double(repeats) / Double(windows), 0.16, "the same kind two gestures later is rarer than chance would have it (\(repeats) of \(windows))")
    }

    // MARK: What the frame rate and the small life are told

    func testWhatTheCatDoesDecidesItsFrameCeilingAndHowMuchOfItsSmallLifeGoesOn() {
        let rig = Rig(.compact, seed: 1)
        rig.recordPoses = false
        XCTAssertNil(rig.director.frameCeiling, "resting: only breathing"); XCTAssertEqual(rig.director.lifeWeight, 1)
        rig.director.start(.groom, stage: rig.stage)
        rig.run(1.5) { _, _ in }
        XCTAssertEqual(rig.director.frameCeiling, 1.0 / 8); XCTAssertLessThan(rig.director.lifeWeight, 0.5, "a gesture has the body")
        let nap = Rig(.compact, seed: 2)
        nap.input = PetInput(idle: 400); nap.recordPoses = false
        nap.director.start(.nap, stage: nap.stage)
        nap.run(1) { _, _ in }
        XCTAssertEqual(nap.director.frameCeiling, 1.0 / 8, "lying down is drawn properly")
        nap.run(12) { _, _ in }
        XCTAssertNil(nap.director.frameCeiling, "asleep it only breathes"); XCTAssertEqual(nap.director.lifeWeight, 0, accuracy: 0.001, "and does nothing else")
        let cheer = Rig(.compact, seed: 3)
        cheer.input.completions = 0; cheer.recordPoses = false
        cheer.run(1) { _, _ in }
        cheer.run(until: 2, { input, _ in input.completions = 1 }) { cheer.director.celebration != nil }
        cheer.run(0.4) { input, _ in input.completions = 1 }
        XCTAssertEqual(cheer.director.frameCeiling, 1.0 / 20); XCTAssertEqual(cheer.director.lifeWeight, 0, accuracy: 0.001)
        let looking = Rig(.compact, seed: 4)
        looking.recordPoses = false
        looking.run(1) { input, _ in input.gaze = PetSim.pointer }
        XCTAssertEqual(looking.director.frameCeiling, 1.0 / 20); XCTAssertLessThan(looking.director.lifeWeight, 0.5)
        XCTAssertGreaterThan(looking.director.lifeWeight, 0, "it still blinks at the pointer")
    }

    // MARK: The celebration follows what was chosen

    func testTheCatCheersTheWayItsTemperAndTheSettingsSay() {
        for (personality, style) in [(PetPersonality.curious, PetCheer.hop), (.playful, .doubleHop), (.calm, .content), (.sleepy, .content)] {
            var prefs = PetPreferences(); prefs.personality = personality
            let rig = Rig(.compact, seed: 1)
            rig.recordPoses = false; rig.input.prefs = prefs; rig.input.completions = 0
            rig.run(1) { _, _ in }
            rig.run(until: 3, { input, _ in input.completions = 1 }) { rig.director.celebration != nil }
            XCTAssertEqual(rig.director.celebration?.style, style, "\(personality)")
            XCTAssertEqual(rig.director.celebration?.length ?? 0, PetAnimation.cheerLength(style), accuracy: 1e-9)
        }
        // Told not to cheer, it never does, however many tasks finish.
        var quiet = PetPreferences(); quiet.celebrates = false
        let rig = Rig(.compact, seed: 1)
        rig.recordPoses = false; rig.input.prefs = quiet; rig.input.completions = 0
        rig.run(1) { _, _ in }
        for n in 1...5 { rig.run(PetDirector.celebrationCooldown + 6) { input, _ in input.completions = n } }
        XCTAssertEqual(rig.celebrationStarts, 0)
        // Turned back on, the next finish is celebrated.
        quiet.celebrates = true
        rig.input.prefs = quiet
        rig.run(PetDirector.celebrationCooldown + 6) { input, _ in input.completions = 6 }
        XCTAssertEqual(rig.celebrationStarts, 1)
    }

    func testAHeaderCatHuntsTowardTheRoomItHasAndNeverLeavesTheStage() {
        for seed in 0..<30 {
            let rig = Rig(.header, seed: seed, stage: .header(travel: 40))
            rig.director.start(.hunt, stage: rig.stage)
            XCTAssertEqual(rig.director.running?.facing, 1, "to the right: that is where the stage is")
            rig.run(11) { _, _ in }
            for pose in rig.poses { XCTAssertGreaterThanOrEqual(pose.x, -0.001); XCTAssertLessThanOrEqual(pose.x, 40.001) }
        }
    }

    // MARK: Small rules

    func testThePointerIsNoticedFromAwayAndForgottenFurtherOut() {
        XCTAssertTrue(PetDirector.pointerNear(distance: 40, wasNear: false, enter: 48, leave: 64))
        XCTAssertFalse(PetDirector.pointerNear(distance: 55, wasNear: false, enter: 48, leave: 64))
        XCTAssertTrue(PetDirector.pointerNear(distance: 55, wasNear: true, enter: 48, leave: 64), "once noticed it stays noticed a little further out")
        XCTAssertFalse(PetDirector.pointerNear(distance: 70, wasNear: true, enter: 48, leave: 64))
        XCTAssertFalse(PetDirector.pointerNear(distance: .nan, wasNear: true, enter: 48, leave: 64))
        XCTAssertFalse(PetDirector.pointerNear(distance: .infinity, wasNear: false, enter: 48, leave: 64))
        XCTAssertEqual(PetGaze(dx: .nan, dy: .infinity), PetGaze(dx: 0, dy: 0))
        XCTAssertEqual(PetGaze(dx: 9, dy: -9), PetGaze(dx: 1, dy: -1))
    }

    func testTypingAndReadingAreToldApart() {
        XCTAssertEqual(PetFocus.from(keyAge: 1, scrollAge: 100), .typing)
        XCTAssertEqual(PetFocus.from(keyAge: 100, scrollAge: 3), .reading)
        XCTAssertEqual(PetFocus.from(keyAge: 100, scrollAge: 100, panelKey: true), .reading)
        XCTAssertEqual(PetFocus.from(keyAge: 100, scrollAge: 100, composing: true), .typing, "a draft in Nook's own field")
        XCTAssertEqual(PetFocus.from(keyAge: 100, scrollAge: 100), .free)
        XCTAssertEqual(PetFocus.from(keyAge: 2, scrollAge: 1, panelKey: true), .typing, "typing wins")
        XCTAssertLessThan(PetFocus.free, .reading); XCTAssertLessThan(PetFocus.reading, .typing)
    }

    func testPlayerHandsOutPosesFromTheDirectorAndEasesTheWorkingState() {
        var player = PetPlayer(layout: .compact, seed: 3)
        var now = 50.0
        var previous = player.pose(now: now, layout: .compact(), motion: true, input: PetInput())
        for _ in 0..<30 { now += 1.0 / 12; previous = player.pose(now: now, layout: .compact(), motion: true, input: PetInput()) }
        var jump: CGFloat = 0
        for _ in 0..<40 {
            now += 1.0 / 12
            let pose = player.pose(now: now, layout: .compact(), motion: true, input: PetInput(working: true))
            jump = max(jump, pose.distance(to: previous)); previous = pose
        }
        XCTAssertEqual(player.alert, 1, accuracy: 0.001)
        XCTAssertLessThan(jump, 8, "working eases in instead of snapping")
        XCTAssertEqual(player.wall, now, "the sit shares one clock with every other cat on screen")
    }
}

/// A repeatable random source for the shuffled-state tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
