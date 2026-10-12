import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The icons a tab can wear: what is saved, what each one is called, where it draws, how it moves and when it does not.
@MainActor
final class TabIconTests: XCTestCase {
    // MARK: What is saved

    /// Raw values are saved in the user's preferences: renaming one would turn every tab that wears it back into a dot.
    func testTheSavedNamesNeverChange() {
        // The first six are what the tabs of before the light theme saved; the newer ones are appended.
        XCTAssertEqual(TabIcon.allCases.map(\.rawValue), ["dot", "half", "orbit", "bars", "spark", "gem", "heart", "bolt", "leaf", "moon", "wave", "paw", "flame", "star", "code", "sun"])
        XCTAssertEqual(TabIcon.allCases.first, .dot, "The default comes first in the picker.")
    }

    func testEveryIconRoundTripsAndAnUnknownOneBecomesTheDot() throws {
        for icon in TabIcon.allCases {
            let saved = ["a": TabAppearance(title: "API", tint: .peach, icon: icon)]
            let loaded = try JSONDecoder().decode([String: TabAppearance].self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(loaded, saved, icon.rawValue)
        }
        let unknown = try JSONDecoder().decode([String: TabAppearance].self, from: Data(#"{"a": {"title": "API", "tint": "blue", "icon": "comet"}}"#.utf8))
        XCTAssertEqual(unknown["a"]?.icon, .dot)
    }

    // MARK: Words

    func testEveryIconHasItsOwnNameForTheTooltipAndVoiceOver() {
        let titles = TabIcon.allCases.map(\.title)
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(titles).count, titles.count, "Two icons with one name cannot be told apart by ear.")
    }

    // MARK: Geometry

    private let box = CGRect(x: 0, y: 0, width: TabIconArt.box, height: TabIconArt.box)

    private func periods(of icon: TabIcon) -> Double {
        switch icon {
        case .dot: 1
        case .half: TabIconArt.halfTurn
        case .orbit: TabIconArt.orbitTurn
        case .bars: TabIconArt.barsCycle
        case .spark: TabIconArt.sparkCycle
        case .gem: TabIconArt.gemTurn
        case .heart: TabIconArt.heartBeat
        case .bolt: TabIconArt.boltCycle
        case .leaf: TabIconArt.leafSway
        case .moon: TabIconArt.moonCycle
        case .wave: TabIconArt.waveCycle
        case .paw: TabIconArt.pawCycle
        case .flame: TabIconArt.flameCycle
        case .star: TabIconArt.starTurn
        case .code: TabIconArt.codeCycle
        case .sun: TabIconArt.sunTurn
        }
    }

    /// An icon that spills out of its box would be cut by the tab, or push the title along.
    func testEveryIconStaysInsideItsBoxAtEveryMomentOfItsMovement() {
        let slack = 0.0001
        for icon in TabIcon.allCases {
            let span = periods(of: icon)
            for step in 0...200 {
                let time = span * Double(step) / 200
                for shape in TabIconArt.shapes(of: icon, at: time) {
                    let bounds = shape.bounds
                    XCTAssertGreaterThanOrEqual(bounds.minX, box.minX - slack, "\(icon) at \(time)")
                    XCTAssertGreaterThanOrEqual(bounds.minY, box.minY - slack, "\(icon) at \(time)")
                    XCTAssertLessThanOrEqual(bounds.maxX, box.maxX + slack, "\(icon) at \(time)")
                    XCTAssertLessThanOrEqual(bounds.maxY, box.maxY + slack, "\(icon) at \(time)")
                }
            }
        }
    }

    /// The same pieces, in the same places and as opaque: an icon that moves by fading (the bolt's charge, the paw's taps) moves as much as one that turns.
    private func sameShapes(_ a: [TabIconShape], _ b: [TabIconShape]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { left, right in
            let l = left.bounds, r = right.bounds
            return abs(l.minX - r.minX) < 1e-6 && abs(l.minY - r.minY) < 1e-6 && abs(l.width - r.width) < 1e-6 && abs(l.height - r.height) < 1e-6
                && abs(left.opacity - right.opacity) < 1e-6
        }
    }

    /// The still icon is where the movement begins: nothing jumps when a tab's AI starts working.
    func testTheStillFormIsTheMovementAtTimeZero() {
        for icon in TabIcon.allCases where icon != .orbit {
            XCTAssertEqual(TabIconArt.shapes(of: icon, at: nil), TabIconArt.shapes(of: icon, at: 0), icon.rawValue)
        }
        // The orbit's trail has nothing to trail behind at rest; the rest of it is the same.
        let rest = TabIconArt.shapes(of: .orbit, at: nil), moving = TabIconArt.shapes(of: .orbit, at: 0)
        XCTAssertLessThan(rest.count, moving.count)
        XCTAssertEqual(rest.last, moving.last, "The moon is where it was.")
        XCTAssertEqual(Array(rest.prefix(2)), Array(moving.prefix(2)), "And so are the track and the core.")
    }

    func testTheDotNeverMoves() {
        XCTAssertFalse(TabIcon.dot.moves)
        for time in [0.0, 0.7, 3.1, 1000.5] {
            XCTAssertEqual(TabIconArt.shapes(of: .dot, at: time), TabIconArt.shapes(of: .dot, at: nil))
        }
        for icon in TabIcon.allCases where icon != .dot { XCTAssertTrue(icon.moves, icon.rawValue) }
    }

    func testEveryOtherIconReallyMovesAndComesBackAfterOnePeriod() {
        for icon in TabIcon.allCases where icon.moves {
            let period = periods(of: icon)
            let start = TabIconArt.shapes(of: icon, at: 0.0)
            XCTAssertFalse(sameShapes(start, TabIconArt.shapes(of: icon, at: period * 0.3)), "\(icon.rawValue) stands still.")
            XCTAssertTrue(sameShapes(start, TabIconArt.shapes(of: icon, at: period)), "\(icon.rawValue) does not come back after one period.")
            // The same picture, however long the island has been open (the timeline's date is seconds since 2001).
            XCTAssertTrue(sameShapes(TabIconArt.shapes(of: icon, at: 7.3), TabIconArt.shapes(of: icon, at: 7.3 + period * 40)), icon.rawValue)
        }
    }

    func testTheMovementIsSlowEnoughToBeCalm() {
        // One turn, pulse or flip never takes less than a second and a half: these sit in the corner of the eye.
        for icon in TabIcon.allCases where icon.moves { XCTAssertGreaterThanOrEqual(periods(of: icon), 1.5, icon.rawValue) }
    }

    func testTheBarsKeepTheirHeightsInsideTheirBox() {
        for step in 0...400 {
            for height in TabIconArt.barHeights(at: Double(step) * 0.0123) {
                XCTAssertGreaterThanOrEqual(height, 3.1); XCTAssertLessThanOrEqual(height, 8.5)
            }
        }
    }

    // MARK: When they move

    func testAnIconMovesOnlyWhileItsAIWorksAndNothingHoldsItStill() {
        for icon in TabIcon.allCases {
            let expected = icon != .dot
            XCTAssertEqual(TabIconView.moves(icon, working: true, animated: true, reduceMotion: false), expected, icon.rawValue)
            XCTAssertFalse(TabIconView.moves(icon, working: false, animated: true, reduceMotion: false), "Not working: still. \(icon.rawValue)")
            XCTAssertFalse(TabIconView.moves(icon, working: true, animated: false, reduceMotion: false), "The preference or a collapsed island: still. \(icon.rawValue)")
            XCTAssertFalse(TabIconView.moves(icon, working: true, animated: true, reduceMotion: true), "Reduce Motion: still. \(icon.rawValue)")
        }
    }

    // MARK: Size

    private func fittingSize<V: View>(_ view: V) -> CGSize { NSHostingView(rootView: view).fittingSize }

    func testTheDotIsTheFivePointDotTabsAlwaysHadAndTheOthersAreTenPointsSquare() {
        XCTAssertEqual(fittingSize(TabIconView(icon: .dot, color: .white)), CGSize(width: 5, height: 5))
        for icon in TabIcon.allCases where icon != .dot {
            XCTAssertEqual(fittingSize(TabIconView(icon: icon, color: .white)), CGSize(width: 10, height: 10), icon.rawValue)
        }
        XCTAssertEqual(fittingSize(TabIconView(icon: .half, color: .white, size: 16)), CGSize(width: 16, height: 16), "The picker draws them larger.")
    }

    // MARK: Drawing

    /// The art, drawn the way a tab draws it, puts ink on the screen in the colour it was given and nowhere near the box's edge.
    func testEveryIconDrawsInItsColour() throws {
        for icon in TabIcon.allCases {
            let host = NSHostingView(rootView: TabIconView(icon: icon, color: Color(red: 1, green: 0, blue: 0), size: 40).frame(width: 40, height: 40).background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var red = 0, other = 0
            // The first render of a run can come out empty: wait and draw again until something shows.
            for _ in 0..<4 where red == 0 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                red = 0; other = 0
                for y in 0..<rep.pixelsHigh {
                    for x in 0..<rep.pixelsWide {
                        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        // Ink is anything lit on the black; it is in the colour given when red leads (the window's own colour
                        // space moves the channels a little, so the others are not expected to be exactly zero).
                        guard max(color.redComponent, color.greenComponent, color.blueComponent) > 0.25 else { continue }
                        if color.redComponent > 0.25, color.greenComponent < color.redComponent * 0.6, color.blueComponent < color.redComponent * 0.6 { red += 1 } else { other += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(red, 40, "\(icon.rawValue) drew nothing.")
            XCTAssertEqual(other, 0, "\(icon.rawValue) drew in a colour it was not given.")
        }
    }

    // MARK: The icon that moves

    /// While it moves, the icon is drawn by an AppKit view of its own (`TabIconMotionView`, so its twenty frames a second repaint only
    /// itself instead of the island's whole hosting view). At any moment its picture is the one the `Canvas` draws then.
    func testTheMovingIconPaintsWhatTheCanvasPaintsAtTheSameMoment() throws {
        let side: CGFloat = 40, scale: CGFloat = 2, px = Int(side * scale)
        // A fixed colour: a tab's own colour has a shade for each theme, and the two pictures are drawn here without a view to say which.
        let tint = TabTint.peach.shades.pastel.nsColor
        func canvas() -> CGContext {
            CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func bytes(_ cg: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: cg.data!.bindMemory(to: UInt8.self, capacity: px * px * 4), count: px * px * 4)) }
        var compared = 0
        for icon in TabIcon.allCases where icon.moves {
            for time in [0.0, 0.37, 1.1, 2.9, 7.25] {
                let shapes = TabIconArt.shapes(of: icon, at: 5000 + time)
                // SwiftUI's Canvas, as the still icon (and the moving one before) is drawn.
                let renderer = ImageRenderer(content: Canvas { context, _ in TabIconArt.draw(shapes, in: &context, size: side, color: Color(nsColor: tint)) }.frame(width: side, height: side))
                renderer.scale = scale
                let image = try XCTUnwrap(renderer.cgImage)
                let swiftUI = canvas()
                swiftUI.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
                // The AppKit view's drawing: Core Graphics in a context whose y points down, as a flipped view's is.
                let appKit = canvas()
                appKit.translateBy(x: 0, y: CGFloat(px)); appKit.scaleBy(x: scale, y: -scale)
                TabIconArt.draw(shapes, in: appKit, size: side, color: tint)
                let a = bytes(swiftUI), b = bytes(appKit)
                var inked = 0, apart = 0, worst = 0
                for k in stride(from: 0, to: a.count, by: 4) {
                    if a[k + 3] > 0 || b[k + 3] > 0 { inked += 1 }
                    let gap = (0..<4).map { abs(Int(a[k + $0]) - Int(b[k + $0])) }.max()!
                    worst = max(worst, gap)
                    if gap > 40 { apart += 1 }
                }
                XCTAssertGreaterThan(inked, 100, "\(icon) at \(time) drew something")
                // Only the antialiased edge may differ a little (two rasterizers); the shapes, their place and their colour are the same.
                XCTAssertLessThanOrEqual(Double(apart) / Double(inked), 0.01, "\(icon) at \(time): \(apart) of \(inked) pixels apart (worst \(worst))")
                compared += 1
            }
        }
        XCTAssertEqual(compared, (TabIcon.allCases.count - 1) * 5)
    }

    /// The view that moves keeps its timer only while it is in a window and the island can be seen; otherwise it is paused.
    func testTheMovingIconRunsOnlyWhileItCanBeSeen() {
        let view = TabIconMotionView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.show(.orbit, color: .white, side: 10, seen: true)
        XCTAssertEqual(view.frameInterval, 0, "out of a window: nothing runs")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertEqual(view.frameInterval, TabIconView.interval, accuracy: 1e-9, "twenty frames a second")
        view.show(.orbit, color: .white, side: 10, seen: false)
        XCTAssertEqual(view.frameInterval, 0, "nobody can see the island: paused")
        view.show(.orbit, color: .white, side: 10, seen: true)
        XCTAssertEqual(view.frameInterval, TabIconView.interval, accuracy: 1e-9, "and running again")
        window.contentView = nil
        XCTAssertEqual(view.frameInterval, 0, "and nothing once it leaves the window")
        XCTAssertNil(view.hitTest(NSPoint(x: 5, y: 5)), "the tab's button under it takes the clicks")
    }
}
