import AppKit
import XCTest
@testable import Nook

final class AlertPeekTests: XCTestCase {
    private func alert(_ id: Int, _ kind: NookAlert.Kind = .finished, title: String = "api", message: String = "Claude terminó.") -> NookAlert {
        NookAlert(id: id, sessionID: "s\(id)", kind: kind, title: title, message: message)
    }
    private func started(_ id: Int = 1, at now: Double = 0, motion: Bool = true) -> AlertPeekTimeline {
        var timeline = AlertPeekTimeline()
        timeline.begin(alert(id), now: now, motion: motion)
        return timeline
    }
    private func times(_ from: Double, _ to: Double, step: Double) -> [Double] { Array(stride(from: from, through: to, by: step)) }

    // MARK: Schedule

    func testThePeekGrowsHoldsAndSettlesBack() {
        var timeline = AlertPeekTimeline()
        XCTAssertEqual(timeline.phase(at: 0), .idle)
        XCTAssertEqual(timeline.frame(at: 0), .empty)
        timeline.begin(alert(1), now: 10, motion: true)
        XCTAssertEqual(timeline.phase(at: 10.2), .entering)
        XCTAssertEqual(timeline.phase(at: 10.6), .holding)
        XCTAssertEqual(timeline.phase(at: 13.5), .holding, "A few seconds in all: it does not linger.")
        XCTAssertEqual(timeline.phase(at: 13.7), .leaving)
        XCTAssertEqual(timeline.phase(at: 14.05), .idle)

        XCTAssertEqual(timeline.frame(at: 10).progress, 0)
        XCTAssertEqual(timeline.frame(at: 10).content, 0, "The text waits for the island.")
        let growing = timeline.frame(at: 10.2)
        XCTAssertGreaterThan(growing.progress, 0.3)
        XCTAssertLessThan(growing.progress, 1.05)
        let open = timeline.frame(at: 11)
        XCTAssertEqual(open.progress, 1)
        XCTAssertEqual(open.content, 1)
        XCTAssertEqual(open.surface, 1)
        XCTAssertEqual(open.alert, alert(1))
        let closing = timeline.frame(at: 13.8)
        XCTAssertLessThan(closing.progress, 1)
        XCTAssertLessThan(closing.content, 1)
        XCTAssertEqual(timeline.frame(at: 14.1), .empty)

        timeline.advance(to: 14.1)
        XCTAssertFalse(timeline.isActive, "Once it has settled back there is nothing left to run.")
    }

    func testTheSpringSettlesWithAHairOfOvershootAndTheShrinkIsMonotonic() {
        var peak: CGFloat = 0, previous: CGFloat = 0
        for t in times(0, 0.499, step: 0.002) {
            let v = AlertPeekTimeline.spring(t)
            XCTAssertGreaterThanOrEqual(v, 0)
            peak = max(peak, v)
            if t < 0.3 { XCTAssertGreaterThanOrEqual(v, previous, "It rises without stalling at first (t=\(t)).") }
            previous = v
        }
        XCTAssertGreaterThan(peak, 1.005, "A little life.")
        XCTAssertLessThan(peak, 1.04, "But it never wobbles.")
        XCTAssertEqual(previous, 1, accuracy: 0.01, "Settled before it snaps.")
        XCTAssertEqual(AlertPeekTimeline.spring(0.5), 1)

        let timeline = started()
        var last = timeline.frame(at: 3.6).progress
        for t in times(3.6, 3.98, step: 0.01) {
            let p = timeline.frame(at: t).progress
            XCTAssertLessThanOrEqual(p, last + 1e-9, "Closing only ever shrinks (t=\(t)).")
            last = p
        }
        XCTAssertLessThan(last, 0.01)
    }

    func testFramesStayInsideTheWindowAndNeverJump() {
        let layout = AlertPeekLayout(compact: CGSize(width: 246, height: 32))
        let bounds = CGRect(origin: .zero, size: layout.windowSize)
        var last = timelineProgress(started(), 0)
        for t in times(0, 4.2, step: 1.0 / 120) {
            let frame = started().frame(at: t)
            XCTAssertTrue(bounds.contains(layout.shapeRect(progress: frame.progress)), "t=\(t) p=\(frame.progress)")
            XCTAssertLessThan(abs(frame.progress - last), 0.06, "No frame jumps at 120 Hz (t=\(t)).")
            last = frame.progress
        }
    }
    private func timelineProgress(_ timeline: AlertPeekTimeline, _ t: Double) -> CGFloat { timeline.frame(at: t).progress }

    // MARK: Bell

    func testTheBellShakesBrieflyThenStops() {
        var crossings = 0, last: CGFloat = 0, widest: CGFloat = 0
        for t in times(0.001, 1.249, step: 0.002) {
            let angle = AlertPeekTimeline.ring(t)
            widest = max(widest, abs(angle))
            if last != 0, angle != 0, (angle < 0) != (last < 0) { crossings += 1 }
            if angle != 0 { last = angle }
        }
        XCTAssertGreaterThanOrEqual(crossings, 4, "Several swings, like a bell.")
        XCTAssertLessThanOrEqual(widest, 0.4 + 1e-9)
        XCTAssertLessThan(abs(AlertPeekTimeline.ring(1.2)), 0.01, "It has died away by the end.")

        let timeline = started()
        XCTAssertEqual(timeline.frame(at: 0.1).bell, 0, "It does not ring before the island is out.")
        XCTAssertNotEqual(timeline.frame(at: 0.3).bell, 0)
        XCTAssertEqual(timeline.frame(at: 1.6).bell, 0, "Still, once it has rung.")
        XCTAssertEqual(timeline.frame(at: 3).bell, 0)
    }

    func testOnlyMovingMomentsNeedFrames() {
        let timeline = started()
        XCTAssertTrue(timeline.isAnimating(at: 0.1), "Growing.")
        XCTAssertTrue(timeline.isAnimating(at: 0.8), "Ringing.")
        XCTAssertFalse(timeline.isAnimating(at: 1.6), "Sitting there: no display link.")
        XCTAssertEqual(timeline.nextWake(at: 1.6), 3.6, "One timer, for the moment it starts to close.")
        XCTAssertNil(timeline.nextWake(at: 0.8), "While frames are drawn nothing else is needed.")
        XCTAssertTrue(timeline.isAnimating(at: 3.7), "Closing.")
        XCTAssertFalse(AlertPeekTimeline().isAnimating(at: 5))
        XCTAssertNil(AlertPeekTimeline().nextWake(at: 5))
    }

    // MARK: Hover

    func testHoveringKeepsThePeekOpenAndLeavingLetsItFinish() {
        var timeline = started()
        timeline.setHover(true, now: 2)
        XCTAssertEqual(timeline.phase(at: 5), .holding, "Past the usual end, still open under the pointer.")
        XCTAssertEqual(timeline.frame(at: 5).progress, 1)
        XCTAssertEqual(timeline.frame(at: 60).progress, 1)
        XCTAssertNil(timeline.nextWake(at: 5), "Nothing is scheduled while the pointer holds it.")

        timeline.setHover(false, now: 6)
        XCTAssertEqual(timeline.phase(at: 7.1), .holding, "A moment to look away from it.")
        XCTAssertEqual(timeline.nextWake(at: 6.5) ?? -1, 7.2, accuracy: 1e-9)
        XCTAssertEqual(timeline.phase(at: 7.3), .leaving)
        XCTAssertEqual(timeline.phase(at: 7.7), .idle)

        // Leaving early gives it no extra time beyond its own end.
        var brief = started()
        brief.setHover(true, now: 1); brief.setHover(false, now: 1.2)
        XCTAssertEqual(brief.nextWake(at: 1.6) ?? -1, 3.6, accuracy: 1e-9)
    }

    func testTheShrinkingIslandComesBackWhenThePointerDoes() {
        var timeline = started()
        let before = timeline.frame(at: 3.8)
        XCTAssertLessThan(before.progress, 1)
        XCTAssertEqual(timeline.phase(at: 3.8), .leaving)
        timeline.setHover(true, now: 3.8)
        XCTAssertEqual(timeline.frame(at: 3.8).progress, before.progress, accuracy: 1e-9, "It continues from what is on screen.")
        XCTAssertEqual(timeline.phase(at: 3.9), .entering)
        XCTAssertEqual(timeline.frame(at: 4.5).progress, 1)
        XCTAssertEqual(timeline.phase(at: 4.5), .holding)
        XCTAssertEqual(timeline.phase(at: 30), .holding)
    }

    // MARK: Replacement and cancel

    func testANewerAlertReplacesTheOneOnScreenAndRestartsTheClock() {
        var timeline = started(1)
        timeline.begin(alert(2, .question, title: "web", message: "Do you want to proceed?"), now: 2, motion: true)
        let swap = timeline.frame(at: 2)
        XCTAssertEqual(swap.progress, 1, "The island stays out; only its text changes.")
        XCTAssertEqual(swap.alert?.id, 2)
        XCTAssertEqual(swap.outgoing?.id, 1)
        XCTAssertEqual(swap.outgoingContent, 1, accuracy: 1e-9)
        XCTAssertEqual(swap.content, 0, accuracy: 1e-9)
        let fadingOut = timeline.frame(at: 2.06)
        XCTAssertEqual(fadingOut.outgoingContent, 0.5, accuracy: 0.01)
        XCTAssertEqual(fadingOut.content, 0, accuracy: 1e-9, "One line after the other: never two on top of each other.")
        let fadingIn = timeline.frame(at: 2.18)
        XCTAssertEqual(fadingIn.content, 0.5, accuracy: 0.01)
        XCTAssertEqual(fadingIn.outgoingContent, 0, accuracy: 1e-9)
        let done = timeline.frame(at: 2.3)
        XCTAssertNil(done.outgoing)
        XCTAssertEqual(done.content, 1)

        XCTAssertEqual(timeline.phase(at: 5.0), .holding, "The new alert gets its own few seconds.")
        XCTAssertEqual(timeline.phase(at: 5.2), .leaving)
        XCTAssertNotEqual(timeline.frame(at: 2.15).bell, 0, "The bell rings again for it.")

        let same = timeline.frame(at: 3)
        timeline.begin(alert(2, .question, title: "web", message: "Do you want to proceed?"), now: 3, motion: true)
        XCTAssertEqual(timeline.frame(at: 3), same, "The same alert twice is one peek.")
    }

    func testReplacingWhileItGrowsOrClosesContinuesFromWhatIsOnScreen() {
        var growing = started(1)
        let expected = growing.frame(at: 0.2).progress
        growing.begin(alert(2), now: 0.2, motion: true)
        XCTAssertEqual(growing.frame(at: 0.2).progress, expected, accuracy: 1e-9)
        XCTAssertEqual(growing.frame(at: 0.4).progress, started(1).frame(at: 0.4).progress, accuracy: 1e-9, "The growth carries on.")
        XCTAssertEqual(growing.phase(at: 3.5), .holding)

        var closing = started(1)
        let onScreen = closing.frame(at: 3.8).progress
        closing.begin(alert(2), now: 3.8, motion: true)
        XCTAssertEqual(closing.frame(at: 3.8).progress, onScreen, accuracy: 1e-9)
        XCTAssertEqual(closing.phase(at: 3.9), .entering, "It opens again.")
        XCTAssertEqual(closing.frame(at: 4.5).progress, 1)
        XCTAssertEqual(closing.phase(at: 7.3), .holding)
        XCTAssertEqual(closing.phase(at: 7.5), .leaving)
    }

    func testTheCatKeepsLookingWhenAnotherAlertComes() {
        var timeline = started(1)
        XCTAssertEqual(timeline.perk(at: 1), 1, accuracy: 1e-9)
        timeline.begin(alert(2), now: 1, motion: true)
        XCTAssertEqual(timeline.perk(at: 1), 1, accuracy: 0.05, "No drop and second perk-up.")
        XCTAssertGreaterThan(timeline.perk(at: 1.2), 0.9)
        // It still relaxes while the peek is showing.
        XCTAssertEqual(timeline.perk(at: 3.5), 0, accuracy: 1e-9)
        XCTAssertEqual(timeline.phase(at: 3.5), .holding)
    }

    func testCancelEndsAtOnceWithNothingLeft() {
        var timeline = started()
        timeline.setHover(true, now: 1)
        timeline.cancel()
        XCTAssertFalse(timeline.isActive)
        XCTAssertEqual(timeline.phase(at: 1.01), .idle)
        XCTAssertEqual(timeline.frame(at: 1.01), .empty)
        XCTAssertEqual(timeline.perk(at: 1.01), 0)
        XCTAssertFalse(timeline.isAnimating(at: 1.01))
        XCTAssertNil(timeline.nextWake(at: 1.01))
        // And a later alert starts clean.
        timeline.begin(alert(5), now: 20, motion: true)
        XCTAssertEqual(timeline.phase(at: 20.1), .entering)
        XCTAssertFalse(timeline.hovering)
    }

    // MARK: Reduce Motion

    func testReducedMotionOnlyFadesInAndOut() {
        var timeline = started(1, motion: false)
        for t in times(0, 3.6, step: 0.05) {
            let frame = timeline.frame(at: t)
            XCTAssertEqual(frame.progress, 1, "Nothing grows (t=\(t)).")
            XCTAssertEqual(frame.bell, 0, "The bell never shakes (t=\(t)).")
            XCTAssertEqual(timeline.perk(at: t), 0, "The cat stays put (t=\(t)).")
        }
        XCTAssertEqual(timeline.frame(at: 0).surface, 0)
        let fading = timeline.frame(at: 0.15).surface
        XCTAssertGreaterThan(fading, 0.2); XCTAssertLessThan(fading, 0.8)
        XCTAssertEqual(timeline.frame(at: 0.5).surface, 1)
        XCTAssertEqual(timeline.frame(at: 0.5).content, 1)
        var last: CGFloat = 1
        for t in times(3.4, 3.7, step: 0.02) {
            let s = timeline.frame(at: t).surface
            XCTAssertLessThanOrEqual(s, last + 1e-9); last = s
        }
        XCTAssertEqual(timeline.frame(at: 3.75), .empty)
        XCTAssertFalse(timeline.isAnimating(at: 1.5), "Between the fades nothing runs.")
        XCTAssertEqual(timeline.nextWake(at: 1.5), 3.4)

        // A newer alert only crossfades the text.
        timeline.begin(alert(2), now: 1, motion: false)
        XCTAssertEqual(timeline.frame(at: 1.1).progress, 1)
        XCTAssertEqual(timeline.frame(at: 1.1).surface, 1)
        XCTAssertEqual(timeline.frame(at: 1.1).bell, 0)
    }

    func testAnyOrderOfEventsKeepsTheFramesSane() {
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for round in 0..<40 {
            var timeline = AlertPeekTimeline()
            var now = Double(round) * 100, id = 0, motion = round % 3 != 0
            for _ in 0..<120 {
                now += next() * (next() < 0.2 ? 2.5 : 0.15)
                switch Int(next() * 6) {
                case 0: id += 1; timeline.begin(alert(id, [.finished, .question, .failed][id % 3]), now: now, motion: motion)
                case 1: if id > 0 { timeline.begin(alert(id), now: now, motion: motion) }
                case 2: timeline.setHover(true, now: now)
                case 3: timeline.setHover(false, now: now)
                case 4: if next() < 0.15 { timeline.cancel() }
                default: motion = round % 3 != 0
                }
                timeline.advance(to: now)
                let frame = timeline.frame(at: now), phase = timeline.phase(at: now)
                XCTAssertEqual(timeline.isActive, phase != .idle, "round \(round)")
                XCTAssertEqual(frame == .empty, phase == .idle, "round \(round)")
                for value in [frame.progress, frame.surface, frame.content, frame.outgoingContent, timeline.perk(at: now)] {
                    XCTAssertTrue(value.isFinite && value >= 0 && value <= 1.04, "round \(round): \(value)")
                }
                XCTAssertLessThanOrEqual(abs(frame.bell), 0.4 + 1e-9)
                if let wake = timeline.nextWake(at: now) { XCTAssertGreaterThanOrEqual(wake, now); XCTAssertFalse(timeline.hovering) }
                if timeline.hovering, timeline.isActive { XCTAssertNotEqual(phase, .leaving, "round \(round): the pointer never watches it close") }
            }
            // Left alone, whatever is on screen finishes by itself, unless the pointer holds it.
            timeline.setHover(false, now: now)
            XCTAssertEqual(timeline.phase(at: now + 10), .idle, "round \(round)")
        }
    }

    // MARK: Policy

    func testOnlyANewAlertOnAClosedVisibleIslandPeeks() {
        let a = alert(7)
        XCTAssertTrue(AlertPeekTimeline.shouldPeek(a, shown: nil, expanded: false, visible: true))
        XCTAssertTrue(AlertPeekTimeline.shouldPeek(a, shown: 6, expanded: false, visible: true))
        XCTAssertFalse(AlertPeekTimeline.shouldPeek(nil, shown: nil, expanded: false, visible: true))
        XCTAssertFalse(AlertPeekTimeline.shouldPeek(a, shown: 7, expanded: false, visible: true), "Each alert peeks once.")
        XCTAssertFalse(AlertPeekTimeline.shouldPeek(a, shown: nil, expanded: true, visible: true), "An open island has no peek.")
        XCTAssertFalse(AlertPeekTimeline.shouldPeek(a, shown: nil, expanded: false, visible: false), "Nobody sees a hidden island.")
    }

    // MARK: Layout

    private let notched = NotchGeometry.idleFrame(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), left: CGRect(x: 0, y: 950, width: 663, height: 32), right: CGRect(x: 849, y: 950, width: 663, height: 32), topInset: 32)
    private let flat = NotchGeometry.idleFrame(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), left: nil, right: nil, topInset: 0)

    func testThePeekWindowSitsOnTheCollapsedIslandWithAndWithoutANotch() {
        for (name, compact, screenTop) in [("notch", notched, CGFloat(982)), ("flat", flat, CGFloat(900))] {
            let layout = AlertPeekLayout(compact: compact.size)
            let frame = layout.windowFrame(compactFrame: compact)
            XCTAssertEqual(frame.size, layout.windowSize, name)
            XCTAssertEqual(frame.maxY, screenTop, "\(name): flush with the top of the screen")
            XCTAssertEqual(frame.midX, compact.midX, accuracy: 1e-9, "\(name): centred on the island")
            let inside = layout.compactRect
            XCTAssertEqual(frame.origin.x + inside.origin.x, compact.origin.x, accuracy: 1e-9, "\(name): the collapsed island lines up pixel for pixel")
            XCTAssertEqual(frame.origin.y + inside.origin.y, compact.origin.y, accuracy: 1e-9, name)
            XCTAssertEqual(inside.size, compact.size, name)
            XCTAssertEqual(layout.screenRect(progress: 0, windowFrame: frame), compact, "\(name): the island opens from exactly where the collapsed one is")
            XCTAssertEqual(layout.screenRect(progress: 1, windowFrame: frame).maxY, screenTop, "\(name)")
            XCTAssertGreaterThan(layout.full.width, compact.width + 40, "\(name): room for a line of text")
            XCTAssertGreaterThanOrEqual(layout.chin, 28)
            XCTAssertLessThanOrEqual(frame.height, compact.height + 40, "\(name): a peek, not a panel")
        }
    }

    func testTheGrownShapeAlwaysCoversTheCollapsedIsland() {
        for compact in [notched, flat] {
            let layout = AlertPeekLayout(compact: compact.size)
            let window = CGRect(origin: .zero, size: layout.windowSize)
            XCTAssertEqual(layout.shapeRect(progress: 0), layout.compactRect)
            XCTAssertEqual(layout.shapeRect(progress: 1), layout.fullRect)
            let inner = layout.compactRect
            let r = layout.compactRadius
            let corners = [(inner.minX + r, inner.minY + r, CGFloat.pi), (inner.maxX - r, inner.minY + r, 1.5 * CGFloat.pi)]
            for p in stride(from: CGFloat(0.02), through: 1.04, by: 0.02) {
                let rect = layout.shapeRect(progress: p)
                XCTAssertEqual(rect.maxY, window.maxY, accuracy: 1e-9, "The top edge never moves.")
                XCTAssertTrue(window.contains(rect), "p=\(p)")
                let outline = IslandView.outline(rect, radius: layout.radius(progress: p))
                for (cx, cy, from) in corners {
                    for step in 0...8 {
                        let angle = from + CGFloat(step) / 8 * (.pi / 2)
                        XCTAssertTrue(outline.contains(CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))), "The island's own corner never peeks out (p=\(p))")
                    }
                }
            }
        }
    }

    func testTheOutlineMorphsLikeTheIslandsOwn() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        let layout = AlertPeekLayout(compact: notched.size)
        XCTAssertEqual(elements(IslandView.outline(layout.shapeRect(progress: 0), radius: layout.radius(progress: 0))),
                       elements(IslandView.outline(layout.shapeRect(progress: 1), radius: layout.radius(progress: 1))))
    }

    // MARK: Words

    func testTheLineIsOneCalmLine() {
        XCTAssertEqual(AlertPeekStyle.line("Do you want\nto proceed?\n"), "Do you want to proceed?")
        XCTAssertEqual(AlertPeekStyle.line("  a \t b   c "), "a b c")
        XCTAssertEqual(AlertPeekStyle.line(""), "")
        XCTAssertEqual(AlertPeekStyle.spoken(alert(1)), "api: Claude terminó.")
        XCTAssertEqual(AlertPeekStyle.spoken(alert(1, title: "")), "Claude terminó.")
        XCTAssertNotEqual(AlertPeekStyle.color(.finished), AlertPeekStyle.color(.question))
        XCTAssertNotEqual(AlertPeekStyle.color(.question), AlertPeekStyle.color(.failed))
        XCTAssertEqual(AlertPeekStyle.color(.finished), TranscriptPalette.mint, "Finished is Nook's mint.")
    }

    func testBellTitleAndMessageAlwaysFitTheChinInOrder() {
        let layout = AlertPeekLayout(compact: CGSize(width: 246, height: 32))
        let view = AlertPeekView(layout: layout)
        let chin = layout.chinRect
        let long = String(repeating: "Do you want to proceed with this very long question? ", count: 4)
        let cases: [(String, String)] = [("api", "Claude terminó."), ("", "Claude terminó."), ("build", ""), ("", ""),
                                         ("Claude Code · nook-notch-island", long), (String(repeating: "t", count: 90), "ok"),
                                         ("api", String(long.prefix(180))), ("日本語のタブ", "質問があります。続けますか？")]
        for (index, (title, message)) in cases.enumerated() {
            let row = view.row(for: NookAlert(id: 100 + index, sessionID: "s", kind: .question, title: title, message: message))
            let pieces = [("title", row.title), ("message", row.message)].filter { $0.1.width > 0 }
            XCTAssertGreaterThanOrEqual(row.bell.x - 6.5, chin.minX + 17.9, "case \(index): the bell stays off the corner")
            for (name, rect) in pieces {
                XCTAssertGreaterThanOrEqual(rect.minX, row.bell.x + 6.5, "case \(index): \(name) after the bell")
                XCTAssertLessThanOrEqual(rect.maxX, chin.maxX - 17.9, "case \(index): \(name) inside the chin")
                XCTAssertGreaterThanOrEqual(rect.minY, chin.minY); XCTAssertLessThanOrEqual(rect.maxY, chin.maxY)
            }
            if row.title.width > 0, row.message.width > 0 {
                XCTAssertLessThanOrEqual(row.title.maxX + 10, row.message.minX, "case \(index): room for the dot")
                XCTAssertNotNil(row.dot)
                XCTAssertGreaterThanOrEqual(row.message.width, 12, "case \(index): the message is never squeezed out by the title")
            } else { XCTAssertNil(row.dot) }
            // Centred as a group while it fits.
            let first = row.bell.x - 6.5, last = max(row.title.maxX, row.message.maxX)
            XCTAssertEqual((first + last) / 2, chin.midX, accuracy: 1.0, "case \(index)")
        }
    }

    // MARK: The cat

    func testThePerkedCatReactsAndStaysInsideTheLeftWing() {
        let base = PetAnimation.sit(time: 3)
        XCTAssertEqual(PetAnimation.perked(from: base, time: 3, amount: 0, age: 1), base, "No reaction, no change.")
        let full = PetAnimation.perked(from: base, time: 3, amount: 1, age: 3)
        XCTAssertGreaterThan(full.eyes, base.eyes, "Eyes wide.")
        XCTAssertLessThan(full.earL, base.earL, "Ears forward.")
        XCTAssertGreaterThan(full.look.x, 1, "Looking toward the bell.")
        XCTAssertGreaterThan(full.head.y, base.head.y, "Sitting tall.")
        XCTAssertEqual(full.action, .sit)

        for (i, base) in PetSim.compactPoses(step: 0.37).enumerated() {
            let t = Double(i)
            for amount: CGFloat in [0.25, 0.5, 0.75, 1] {
                for age in [0.0, 0.15, 0.4, 1, 3] {
                    // Whatever the cat was doing when the alert came.
                    let pose = PetAnimation.perked(from: base, time: t, amount: amount, age: age)
                    let b = pose.bounds
                    XCTAssertGreaterThanOrEqual(PetAnimation.compactAnchor + pose.x + b.minX * PetAnimation.compactScale, PetAnimation.wing.lowerBound, "t=\(t) a=\(amount) age=\(age)")
                    XCTAssertLessThanOrEqual(PetAnimation.compactAnchor + pose.x + b.maxX * PetAnimation.compactScale, PetAnimation.wing.upperBound, "t=\(t) a=\(amount) age=\(age)")
                    // A cat caught mid-peek is still partly behind the island's edge; the mask the view draws with cuts it there.
                    if pose.y > -1 { XCTAssertGreaterThanOrEqual(b.minY * PetAnimation.compactScale + 7, 0) }
                    XCTAssertLessThanOrEqual(b.maxY * PetAnimation.compactScale + 7, 32)
                }
            }
        }
    }

    func testThePerkEasesInAndRelaxesBeforeThePeekEnds() {
        let timeline = started()
        XCTAssertEqual(timeline.perk(at: 0), 0)
        XCTAssertEqual(timeline.perk(at: 0.15), 0.5, accuracy: 0.01)
        XCTAssertEqual(timeline.perk(at: 1), 1)
        var last: CGFloat = 1
        for t in times(1.9, 2.7, step: 0.05) {
            let v = timeline.perk(at: t)
            XCTAssertLessThanOrEqual(v, last + 1e-9, "t=\(t)"); last = v
        }
        XCTAssertEqual(timeline.perk(at: 3), 0, "The cat is calm again while the peek is still up.")
        XCTAssertEqual(timeline.phase(at: 3), .holding)
        XCTAssertEqual(timeline.perk(at: 99), 0)
    }
}
