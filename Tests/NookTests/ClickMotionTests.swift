import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What a button does when it is clicked (`ClickMotion.swift`): the curves are plain numbers and are checked as such; the one-shot that plays them is watched frame by frame in a hosted view;
/// and at rest the press style looks exactly as the system's plain one did.
@MainActor
final class ClickMotionTests: XCTestCase {
    // MARK: The curves

    func testEveryMotionStartsAtRestAndEndsAtRest() {
        for motion in ClickMotion.allCases where motion != .spin {
            let start = motion.pose(at: 0), end = motion.pose(at: 1)
            XCTAssertEqual(start, ClickPose(), "\(motion) begins at rest")
            XCTAssertEqual(end.dx, 0, accuracy: 1e-9, "\(motion) ends at rest")
            XCTAssertEqual(end.dy, 0, accuracy: 1e-9)
            XCTAssertEqual(end.scaleX, 1, accuracy: 1e-9)
            XCTAssertEqual(end.scaleY, 1, accuracy: 1e-9)
            XCTAssertEqual(end.degrees, 0, accuracy: 1e-9)
        }
    }

    /// A ✕ or a + turned a quarter looks as it did: the motion ends exactly there, and begins at nothing.
    func testTheSpinEndsAQuarterTurnedWhichIsRestForASymbolThatLooksTheSameTurned() {
        XCTAssertEqual(ClickMotion.spin.pose(at: 0).degrees, 0, accuracy: 1e-9)
        XCTAssertEqual(ClickMotion.spin.pose(at: 1).degrees, 90, accuracy: 1e-9)
        // It goes past the quarter on the way (a flick, not a slide) and never turns back.
        let degrees = stride(from: 0.0, through: 1.0, by: 0.02).map { ClickMotion.spin.pose(at: $0).degrees }
        XCTAssertGreaterThan(degrees.max() ?? 0, 90, "a little overshoot")
        XCTAssertLessThan(degrees.max() ?? 0, 100)
        XCTAssertGreaterThanOrEqual(degrees.min() ?? 0, 0)
    }

    func testTheMotionsAreSmallAndSmooth() {
        for motion in ClickMotion.allCases {
            var previous = motion.pose(at: 0)
            for u in stride(from: 0.01, through: 1.0, by: 0.01) {
                let pose = motion.pose(at: u)
                for value in [pose.dx, pose.dy, pose.scaleX, pose.scaleY, pose.degrees] { XCTAssertTrue(value.isFinite, "\(motion) at \(u)") }
                XCTAssertLessThan(abs(pose.dx), 6, "\(motion): a nudge, not a leap")
                XCTAssertLessThan(abs(pose.dy), 6)
                XCTAssertTrue((0.7...1.5).contains(pose.scaleX), "\(motion) scale \(pose.scaleX) at \(u)")
                XCTAssertTrue((0.7...1.5).contains(pose.scaleY))
                XCTAssertLessThan(abs(pose.degrees), 100)
                // No frame at a hundredth of the motion jumps: the curve is continuous.
                XCTAssertLessThan(abs(pose.degrees - previous.degrees), 14, "\(motion) turns smoothly")
                XCTAssertLessThan(abs(pose.dy - previous.dy), 1.6)
                XCTAssertLessThan(abs(pose.scaleX - previous.scaleX), 0.09)
                previous = pose
            }
        }
    }

    func testEachMotionMovesTheWayItIsNamedFor() {
        let up = (0..<50).map { ClickMotion.nudgeUp.pose(at: Double($0) / 50).dy }
        XCTAssertLessThan(up.min() ?? 0, -3, "the send arrow flies up")
        let down = (0..<50).map { ClickMotion.nudgeDown.pose(at: Double($0) / 50).dy }
        XCTAssertGreaterThan(down.max() ?? 0, 3)
        let diagonal = ClickMotion.nudgeUpRight.pose(at: 0.2)
        XCTAssertGreaterThan(diagonal.dx, 0); XCTAssertLessThan(diagonal.dy, 0)
        let right = (0..<50).map { ClickMotion.nudgeRight.pose(at: Double($0) / 50) }
        XCTAssertGreaterThan(right.map(\.dx).max() ?? 0, 3, "«Empezar →»'s arrow goes the way it points")
        XCTAssertTrue(right.allSatisfy { $0.dy == 0 })
        XCTAssertLessThan((0..<50).map { ClickMotion.nudgeLeft.pose(at: Double($0) / 50).dx }.min() ?? 0, -3)
        let tilt = (0..<50).map { ClickMotion.tilt.pose(at: Double($0) / 50).degrees }
        XCTAssertLessThan(tilt.min() ?? 0, -10, "the pin tilts")
        let wiggle = (0..<60).map { ClickMotion.wiggle.pose(at: Double($0) / 60).degrees }
        XCTAssertGreaterThan(wiggle.max() ?? 0, 5); XCTAssertLessThan(wiggle.min() ?? 0, -5)
        XCTAssertGreaterThan((0..<50).map { ClickMotion.pulse.pose(at: Double($0) / 50).scaleX }.max() ?? 1, 1.2, "the mic swells")
        let squeeze = ClickMotion.squeeze.pose(at: 0.25)
        XCTAssertGreaterThan(squeeze.scaleX, 1); XCTAssertLessThan(squeeze.scaleY, 1)
        XCTAssertEqual(ClickMotion.none.pose(at: 0.5), ClickPose())
    }

    func testAStrengthScalesTheMotion() {
        let full = ClickMotion.pop.pose(at: 0.3).scaleX - 1, half = ClickMotion.pop.pose(at: 0.3, strength: 0.5).scaleX - 1
        XCTAssertEqual(half, full / 2, accuracy: 1e-9)
    }

    func testEveryIconGetsTheMotionItsSymbolCallsFor() {
        XCTAssertEqual(ClickMotion.forSymbol("pin"), .tilt)
        XCTAssertEqual(ClickMotion.forSymbol("pin.fill"), .tilt)
        XCTAssertEqual(ClickMotion.forSymbol("chevron.up"), .nudgeUp)
        XCTAssertEqual(ClickMotion.forSymbol("arrow.up"), .nudgeUp, "the send arrow")
        XCTAssertEqual(ClickMotion.forSymbol("chevron.down"), .nudgeDown)
        XCTAssertEqual(ClickMotion.forSymbol("arrow.up.right.square"), .nudgeUpRight)
        XCTAssertEqual(ClickMotion.forSymbol("arrow.right"), .nudgeRight)
        XCTAssertEqual(ClickMotion.forSymbol("chevron.left"), .nudgeLeft)
        XCTAssertEqual(ClickMotion.forSymbol("xmark"), .spin)
        XCTAssertEqual(ClickMotion.forSymbol("plus"), .spin)
        XCTAssertEqual(ClickMotion.forSymbol("mic"), .pulse)
        XCTAssertEqual(ClickMotion.forSymbol("bell.badge.fill"), .wiggle)
        XCTAssertEqual(ClickMotion.forSymbol("doc.on.doc"), .pop, "anything else hops")
    }

    func testEveryMotionHasADurationItIsPlayedFor() {
        for motion in ClickMotion.allCases where motion != .none { XCTAssertTrue((0.3...0.6).contains(motion.duration), "\(motion): quick, and over") }
        XCTAssertEqual(ClickMotion.none.duration, 0)
    }

    // MARK: Playing one

    private struct Rig: View {
        var trigger: Int
        var body: some View {
            Image(systemName: "pin").frame(width: 28, height: 28).clickMotion(.tilt, trigger: trigger)
        }
    }

    private final class Trigger: ObservableObject { @Published var count = 0 }
    private struct Driven: View {
        @ObservedObject var trigger: Trigger
        var body: some View { Rig(trigger: trigger.count) }
    }

    private func watch(animations: Bool, seconds: Double) -> [Double] {
        let trigger = Trigger()
        let host = NSHostingView(rootView: Driven(trigger: trigger).environment(\.nookMotion, animations))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        var phases: [Double] = []
        ClickMotionProbe.sample = { phases.append($0) }
        defer { ClickMotionProbe.sample = nil; window.close() }
        trigger.count += 1
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        return phases
    }

    /// Clicking sets one run of the motion going: the phase climbs from one whole number to the next in about the motion's own time, smoothly, and stops.
    func testAClickPlaysTheMotionOnceInItsOwnTime() {
        let phases = watch(animations: true, seconds: ClickMotion.tilt.duration + 0.5)
        XCTAssertGreaterThan(phases.count, 6, "it was drawn in several frames")
        XCTAssertEqual(phases.last ?? 0, 1, accuracy: 1e-6, "and ends on the next whole number")
        XCTAssertEqual(phases.sorted(), phases, "never backwards")
        XCTAssertTrue(phases.contains { $0 > 0.2 && $0 < 0.8 }, "through the middle of the motion")
    }

    func testWithTheAnimationsOffNothingMoves() {
        let phases = watch(animations: false, seconds: 0.6)
        XCTAssertTrue(phases.allSatisfy { $0 == 0 }, "no click plays a motion: \(phases)")
    }

    /// Nothing runs at rest: no frame is drawn while the button is left alone.
    func testNothingIsDrawnWhileNothingIsClicked() {
        let trigger = Trigger()
        let host = NSHostingView(rootView: Driven(trigger: trigger))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var frames = 0
        ClickMotionProbe.sample = { _ in frames += 1 }
        defer { ClickMotionProbe.sample = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(frames, 0)
    }

    // MARK: At rest

    private func paint(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        window.close()
        return rep
    }

    private struct Samples: View {
        var press: Bool
        var enabled: Bool
        var body: some View {
            HStack(spacing: 10) {
                let label = Image(systemName: "pin.fill").font(.system(size: 14)).foregroundStyle(Color.white).frame(width: 40, height: 40).background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
                if press { Button {} label: { label }.nookPress(.tilt).disabled(!enabled) } else { Button {} label: { label }.buttonStyle(.plain).disabled(!enabled) }
                Text("Hola").foregroundStyle(Color.white).padding(8)
                    .background(Color.green, in: Capsule())
            }.padding(10).frame(width: 240, height: 80, alignment: .leading).background(Color.black)
        }
    }

    /// A button in the press style is, at rest, the very picture the system's plain style gives (and dimmed the same way when it is disabled): the swap changes no button's look.
    func testAtRestItLooksAsThePlainStyleDid() throws {
        for enabled in [true, false] {
            let plain = try paint(Samples(press: false, enabled: enabled)), mine = try paint(Samples(press: true, enabled: enabled))
            XCTAssertEqual(plain.pixelsWide, mine.pixelsWide)
            var worst = 0.0
            for y in stride(from: 0, to: plain.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: plain.pixelsWide, by: 2) {
                    guard let a = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = mine.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    worst = max(worst, abs(Double(a.redComponent - b.redComponent)), abs(Double(a.greenComponent - b.greenComponent)), abs(Double(a.blueComponent - b.blueComponent)))
                }
            }
            XCTAssertLessThan(worst, 0.03, "enabled: \(enabled)")
        }
    }
}
