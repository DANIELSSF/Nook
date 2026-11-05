import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The way back to the end of the conversation (`JumpToLatest.swift`): when the button shows, the glide it starts, and the button over the mirror.
/// Nothing here makes a window key or sends events through the system: the windows are plain borderless ones (which can never be key) ordered in far
/// off the screen, and the clicks go straight to them (`NSWindow.sendEvent`), so a live Nook keeps the keyboard while they run.
@MainActor
final class JumpToLatestTests: XCTestCase {
    override func tearDown() {
        NookContrast.force(nil)
        JumpPresenceProbe.sample = nil
        ClickMotionProbe.sample = nil
        super.tearDown()
    }

    // MARK: When it shows

    func testTheButtonComesFromFiveLinesUpAndGoesWithinTwo() {
        // Coming up from the end: nothing until five lines.
        XCTAssertFalse(JumpToLatest.shows(linesAway: 0, showing: false), "At the end.")
        XCTAssertFalse(JumpToLatest.shows(linesAway: 2, showing: false))
        XCTAssertFalse(JumpToLatest.shows(linesAway: 4.9, showing: false), "Within five lines it does not come.")
        XCTAssertTrue(JumpToLatest.shows(linesAway: 5, showing: false))
        XCTAssertTrue(JumpToLatest.shows(linesAway: 40, showing: false))
        // Going back down: it stays until the reader is within two lines, so a reader resting near five does not make it blink.
        XCTAssertTrue(JumpToLatest.shows(linesAway: 4.9, showing: true))
        XCTAssertTrue(JumpToLatest.shows(linesAway: 2.1, showing: true))
        XCTAssertFalse(JumpToLatest.shows(linesAway: 2, showing: true))
        XCTAssertFalse(JumpToLatest.shows(linesAway: 0, showing: true))
        // Wobbling around either threshold changes nothing.
        var showing = false
        var changes = 0
        for lines in [4.6, 5.1, 4.8, 5.3, 4.4, 2.6, 3.4, 2.2, 2.9, 1.8, 2.3, 1.9, 2.4] as [CGFloat] {
            let now = JumpToLatest.shows(linesAway: lines, showing: showing)
            if now != showing { changes += 1 }
            showing = now
        }
        XCTAssertEqual(changes, 2, "It came once (at 5.1) and went once (at 1.8).")
    }

    // MARK: The mirror says where the reader is

    private func conversation(_ count: Int = 80) -> String {
        (1...count).map { "⏺ línea \($0) de la conversación" }.joined(separator: "\n")
    }

    /// A mirror of the given size with a long conversation in it, at its end.
    private func mirror(lines: Int = 80, height: CGFloat = 140, fontSize: Double = DisplaySettings.defaultChatSize) -> LiveTerminalScrollView {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        scroll.setFontSize(fontSize)
        scroll.setText(conversation(lines))
        scroll.layoutSubtreeIfNeeded()
        return scroll
    }

    private func line(_ scroll: LiveTerminalScrollView) -> CGFloat { LiveTerminalScrollView.lineHeight(of: scroll.font) }

    private func end(_ scroll: LiveTerminalScrollView) -> CGFloat { scroll.textView.frame.height - scroll.contentSize.height }

    /// Scrolls as the reader would, without telling the scroll view anything else: what it hears is the clip view moving.
    private func put(_ scroll: LiveTerminalScrollView, linesUp lines: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end(scroll) - lines * line(scroll)))
    }

    func testTheMirrorSaysWhenTheReaderIsAwayCountedInLinesOfItsFont() {
        let scroll = mirror()
        var heard: [Bool] = []
        scroll.onAwayFromEndChange = { heard.append($0) }
        XCTAssertEqual(scroll.distanceToEnd, 0, accuracy: 0.5, "A new conversation opens at its end.")
        XCTAssertFalse(scroll.awayFromEnd)

        put(scroll, linesUp: 3)
        XCTAssertEqual(scroll.linesToEnd, 3, accuracy: 0.05)
        XCTAssertFalse(scroll.awayFromEnd, "Three lines up is still near the end.")
        put(scroll, linesUp: 6)
        XCTAssertTrue(scroll.awayFromEnd, "Six lines up, the way back shows.")
        put(scroll, linesUp: 3)
        XCTAssertTrue(scroll.awayFromEnd, "Coming back down, it stays until the reader is nearly there.")
        put(scroll, linesUp: 1)
        XCTAssertFalse(scroll.awayFromEnd)
        XCTAssertEqual(heard, [true, false], "Told once each way.")

        // A bigger chat size has taller lines: the same points up are fewer of them.
        let large = mirror(fontSize: 18)
        XCTAssertGreaterThan(line(large), line(scroll) * 1.4)
        large.contentView.scroll(to: NSPoint(x: 0, y: end(large) - 6 * line(scroll)))
        XCTAssertFalse(large.awayFromEnd, "Six small lines are under four large ones.")
        put(large, linesUp: 5.5)
        XCTAssertTrue(large.awayFromEnd)
    }

    func testChangingTheChatSizeCountsTheLinesAgain() {
        let scroll = mirror(height: 160)
        put(scroll, linesUp: 7)
        XCTAssertTrue(scroll.awayFromEnd)
        // The reader stays where they were in the text; at a size where those points are under two lines it goes.
        let before = scroll.distanceToEnd
        scroll.setFontSize(9)
        XCTAssertLessThan(LiveTerminalScrollView.lineHeight(of: scroll.font), before / 2 + 1)
        XCTAssertEqual(scroll.awayFromEnd, JumpToLatest.shows(linesAway: scroll.linesToEnd, showing: true))
    }

    func testTextThatArrivesBelowAReaderWhoStaysUpTakesTheEndAwayFromThem() {
        let scroll = mirror()
        put(scroll, linesUp: 3)
        XCTAssertFalse(scroll.awayFromEnd)
        let place = scroll.contentView.bounds.origin.y
        // Three lines up the mirror no longer follows the output: what arrives piles up below.
        scroll.setText(conversation(80) + "\n" + (1...4).map { "⏺ nueva \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, place, accuracy: 0.5, "The reader stays where they are.")
        XCTAssertTrue(scroll.awayFromEnd, "Seven lines up now, with no scroll of theirs: the way back shows.")
    }

    // MARK: Going there

    func testAJumpWithTheAnimationsOffIsAtTheEndAtOnceAndFollowsTheOutputFromThere() {
        let scroll = mirror()
        put(scroll, linesUp: 20)
        XCTAssertTrue(scroll.awayFromEnd)
        scroll.jumpToEnd(.cut)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5)
        XCTAssertFalse(scroll.awayFromEnd)
        XCTAssertNil(scroll.glide)
        scroll.setText(conversation(80) + "\n⏺ más")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5, "At the end, the mirror follows the output again.")
    }

    func testAJumpWithReduceMotionCrossFadesToTheEnd() {
        let scroll = mirror()
        scroll.wantsLayer = true
        put(scroll, linesUp: 20)
        scroll.jumpToEnd(.fade)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5, "The text does not travel: it is there.")
        XCTAssertNotNil(scroll.layer?.animation(forKey: LiveTerminalScrollView.jumpFadeKey), "…and what showed fades into it.")
        XCTAssertFalse(scroll.awayFromEnd)
    }

    func testTheButtonGoesTheMomentTheGlideStarts() {
        let scroll = mirror()
        var heard: [Bool] = []
        put(scroll, linesUp: 12)
        scroll.onAwayFromEndChange = { heard.append($0) }
        scroll.jumpToEnd(.glide, now: 100)
        XCTAssertEqual(heard, [false], "Gone before the text has moved.")
        XCTAssertNotNil(scroll.glide)
        // While the glide plays the reader is on the way back: nothing it passes brings the button back.
        for t in stride(from: 100.0, through: 100.2, by: 0.02) { scroll.stepGlide(at: t) }
        XCTAssertEqual(heard, [false])
    }

    func testTheGlideOnlyGoesDownSettlesOnTheEndAndStopsThere() throws {
        let scroll = mirror()
        put(scroll, linesUp: 12)
        let start = scroll.contentView.bounds.origin.y
        scroll.jumpToEnd(.glide, now: 100)
        let glide = try XCTUnwrap(scroll.glide)
        XCTAssertGreaterThanOrEqual(glide.duration, MirrorGlide.shortest)
        XCTAssertLessThanOrEqual(glide.duration, MirrorGlide.longest)
        var offsets: [CGFloat] = [start]
        var t = 100.0
        while scroll.stepGlide(at: t) { offsets.append(scroll.contentView.bounds.origin.y); t += 1.0 / 60 }
        offsets.append(scroll.contentView.bounds.origin.y)
        XCTAssertGreaterThan(offsets.count, 12, "Frames in between: \(offsets.count).")
        XCTAssertEqual(offsets, offsets.sorted(), "Only down.")
        XCTAssertEqual(offsets.last ?? 0, end(scroll), accuracy: 0.5, "At the end exactly.")
        // Ease-out: the first half of the time covers most of the way, the second half the last lines.
        let half = offsets[offsets.count / 2]
        XCTAssertGreaterThan((half - start) / (end(scroll) - start), 0.75)
        XCTAssertNil(scroll.glide)
        XCTAssertFalse(scroll.awayFromEnd)
        scroll.setText(conversation(80) + "\n⏺ más")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5, "It follows the output from there.")
    }

    func testTheGlideEndsAtTheTrueEndEvenWhenTextArrivesWhileItPlays() {
        let scroll = mirror()
        put(scroll, linesUp: 15)
        scroll.jumpToEnd(.glide, now: 100)
        scroll.stepGlide(at: 100.05)
        let midway = scroll.contentView.bounds.origin.y
        XCTAssertLessThan(midway, end(scroll) - 1, "On its way.")
        // Output arrives twice during the glide, the second time close to its end, where a mirror that thought it was following would snap.
        let grown = conversation(80) + "\n" + (1...10).map { "⏺ nueva \($0)" }.joined(separator: "\n")
        scroll.setText(grown)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, midway, accuracy: 0.5, "New text does not move a gliding reader: the glide does.")
        scroll.stepGlide(at: 100.2)
        scroll.setText(grown + "\n⏺ y otra más")
        var t = 100.21
        while scroll.stepGlide(at: t) { t += 1.0 / 60 }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5, "At the end of the text as it is now, not as it was when the glide began.")
        XCTAssertTrue(scroll.textView.string.hasSuffix("y otra más"))
        XCTAssertFalse(scroll.awayFromEnd)
    }

    func testAReaderFarUpGlidesOnlyTheLastScreens() throws {
        let scroll = mirror(lines: 900)
        put(scroll, linesUp: 800)
        let viewport = scroll.contentSize.height
        scroll.jumpToEnd(.glide, now: 100)
        let glide = try XCTUnwrap(scroll.glide)
        XCTAssertEqual(glide.from, end(scroll) - MirrorGlide.maxScreens * viewport, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, glide.from, accuracy: 0.5, "It starts a few screens above the end.")
        XCTAssertEqual(glide.duration, MirrorGlide.longest, accuracy: 0.001)
        var t = 100.0
        while scroll.stepGlide(at: t) { t += 1.0 / 60 }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5)
    }

    func testTheReadersOwnScrollStopsTheGlideWhereTheyAre() {
        let scroll = mirror()
        put(scroll, linesUp: 20)
        scroll.jumpToEnd(.glide, now: 100)
        scroll.stepGlide(at: 100.04)
        // The reader scrolls back up meanwhile.
        put(scroll, linesUp: 18)
        let theirs = scroll.contentView.bounds.origin.y
        XCTAssertFalse(scroll.stepGlide(at: 100.08), "The glide gave way.")
        XCTAssertNil(scroll.glide)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, theirs, accuracy: 0.5)
        XCTAssertTrue(scroll.awayFromEnd, "Eighteen lines up: the way back is there again.")
    }

    func testLeavingAConversationMidGlideKeepsItsEndForComingBack() {
        let scroll = mirror()
        put(scroll, linesUp: 20)
        scroll.jumpToEnd(.glide, now: 100)
        scroll.stepGlide(at: 100.03)
        scroll.setContent("call-a")
        XCTAssertNil(scroll.glide, "The glide stops with the conversation it was in.")
        scroll.setText("⏺ el agente")
        scroll.setContent("")
        scroll.setText(conversation(80) + "\n⏺ llegó mientras tanto")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5, "The reader asked for the end, and is there on coming back.")
    }

    func testTheGlideEndsWhereItWasGoingEvenWithNoFramesToPlayIt() {
        // No window, so no display link: the glide's own deadline takes the reader to the end.
        let scroll = mirror()
        put(scroll, linesUp: 12)
        scroll.jumpToEnd(.glide)
        let deadline = Date().addingTimeInterval(2)
        while scroll.glide != nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertNil(scroll.glide)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5)
    }

    func testAJumpAtTheEndDoesNothing() {
        let scroll = mirror()
        scroll.jumpToEnd(.glide, now: 100)
        XCTAssertNil(scroll.glide)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end(scroll), accuracy: 0.5)
    }

    // MARK: The glide's curve

    func testTheGlidesCurve() {
        let near = MirrorGlide.plan(from: 900, end: 1000, viewport: 150, at: 5)
        XCTAssertEqual(near.from, 900, "A reader a few lines up starts where they are.")
        XCTAssertLessThan(near.duration, 0.33, "A short way is quick.")
        let far = MirrorGlide.plan(from: 0, end: 10_000, viewport: 150, at: 5)
        XCTAssertEqual(far.from, 10_000 - 450)
        XCTAssertEqual(far.duration, MirrorGlide.longest, accuracy: 0.0001)
        XCTAssertEqual(near.offset(at: 5, end: 1000).y, 900, accuracy: 0.001)
        XCTAssertFalse(near.offset(at: 5, end: 1000).done)
        XCTAssertTrue(near.offset(at: 5 + near.duration + 0.001, end: 1000).done)
        XCTAssertEqual(near.offset(at: 5 + near.duration + 0.001, end: 1060).y, 1060, "It ends where the end is by then.")
        XCTAssertEqual(MirrorGlide.ease(0), 0)
        XCTAssertEqual(MirrorGlide.ease(1), 1)
        XCTAssertGreaterThan(MirrorGlide.ease(0.5), 0.85)
    }

    // MARK: The button over the mirror

    private final class Place: ObservableObject {
        @Published var covered = false
        @Published var animations = true
    }

    private struct Harness: View {
        @ObservedObject var place: Place
        var text: String
        var tint: TabTint = .rose
        var body: some View {
            LiveTerminalSurface(text: text)
                .frame(width: 420, height: 200)
                .environment(\.nookCovered, place.covered)
                .nookMotion(place.animations)
                .tabTint(tint)
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookFlatGlass, true)
        }
    }

    private func mount(_ place: Place, text: String) throws -> (window: NSWindow, host: NSView, mirror: LiveTerminalScrollView) {
        let host = NSHostingView(rootView: Harness(place: place, text: text))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 200)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 420, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Ordered in far off the screen, as SwiftUI's buttons only answer clicks in a window that is: a borderless window never becomes key.
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        settle(0.3)
        let mirror = try XCTUnwrap(find(LiveTerminalScrollView.self, in: host))
        return (window, host, mirror)
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }

    func testTheButtonComesWhenTheReaderScrollsUpAndTakesThemBackToTheEnd() throws {
        let place = Place()
        let (window, _, mirror) = try mount(place, text: conversation(120))
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "At the end there is no button.")

        put(mirror, linesUp: 3)
        settle(0.3)
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "Three lines up, still none.")

        put(mirror, linesUp: 10)
        settle(0.5)
        let holes = PointerHoles.frames(in: window)
        XCTAssertEqual(holes.count, 1, "Ten lines up the button is there, and marks itself over the text.")
        let button = try XCTUnwrap(holes.first)
        let area = mirror.convert(mirror.bounds, to: nil)
        XCTAssertEqual(button.midX, area.midX, accuracy: 1, "Centred over the mirror…")
        XCTAssertEqual(button.minY - area.minY, JumpToLatestButton.margin, accuracy: 1, "…just above its bottom edge.")
        XCTAssertEqual(button.width, JumpToLatestButton.diameter, accuracy: 0.5)
        // The text under it gives the pointer up there, and a click there does not reach the text.
        let centre = NSPoint(x: button.midX, y: button.midY)
        let hit = window.contentView?.hitTest(window.contentView?.superview?.convert(centre, from: nil) ?? centre)
        XCTAssertFalse(hit?.isDescendant(of: mirror) ?? true, "The click is the button's, not the text's: \(String(describing: hit)).")

        // A click on it takes the reader to the end, and it goes.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        settle(0.05)
        XCTAssertNotNil(mirror.glide, "The click started the glide.")
        // Off the screen the display link has no frames to give: the glide's own deadline ends it (on screen it plays at the display's rate).
        settle(1)
        XCTAssertEqual(mirror.contentView.bounds.origin.y, end(mirror), accuracy: 0.5)
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "Back at the end the button has gone.")
        XCTAssertEqual(mirror.textView.selectedRange().length, 0, "The click selected nothing.")
    }

    func testUnderACardTheButtonGoesAndComesBackWithTheText() throws {
        let place = Place()
        let (window, _, mirror) = try mount(place, text: conversation(120))
        put(mirror, linesUp: 10)
        settle(0.5)
        XCTAssertEqual(PointerHoles.frames(in: window).count, 1)
        place.covered = true
        settle(0.5)
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "A card covers the text: the button does not stand where the card's controls are.")
        place.covered = false
        settle(0.5)
        XCTAssertEqual(PointerHoles.frames(in: window).count, 1, "The reader is still up there when the card goes.")
    }

    func testAShellsOutputHasItTooNamedForItsEnd() throws {
        // The conversation's button says where it goes…
        let place = Place()
        let (conversationWindow, _, conversationMirror) = try mount(place, text: conversation(120))
        put(conversationMirror, linesUp: 10)
        settle(0.5)
        XCTAssertNotNil(AccessibilityLookup.center(of: "Ir al último mensaje", in: conversationWindow))

        // …and a shell's output, shown in the conversation's place, has its own, for its latest output.
        let output = ShellOutput(text: (1...150).map { "[build] paso \($0) de la compilación" }.joined(separator: "\n"))
        let pane = ShellOutputPane(id: "bjump0001", shell: nil, output: output, onBack: {})
            .frame(width: 420, height: 220).tabTint(.sky).environment(\.colorScheme, .dark).environment(\.nookFlatGlass, true)
        let host = NSHostingView(rootView: pane)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 420, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        settle(0.4)
        let mirror = try XCTUnwrap(find(LiveTerminalScrollView.self, in: host))
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "Following the output, there is no button.")
        put(mirror, linesUp: 10)
        settle(0.5)
        XCTAssertEqual(PointerHoles.frames(in: window).count, 1)
        XCTAssertNotNil(AccessibilityLookup.center(of: "Ir al final", in: window))
        XCTAssertNil(AccessibilityLookup.center(of: "Ir al último mensaje", in: window))
    }

    // MARK: How it comes and goes

    /// Scrolls up until the button comes, then back to the end until it goes, and says what its coming and going were given at each step, and the
    /// phases of the arrow's nod.
    private func watchPresence(animations: Bool) throws -> (coming: [Double], nod: [Double], going: [Double]) {
        let place = Place()
        place.animations = animations
        let (window, _, mirror) = try mount(place, text: conversation(120))
        var coming: [Double] = [], nod: [Double] = [], going: [Double] = []
        JumpPresenceProbe.sample = { coming.append($0) }
        ClickMotionProbe.sample = { nod.append($0) }
        put(mirror, linesUp: 10)
        settle(0.9)
        ClickMotionProbe.sample = nil
        JumpPresenceProbe.sample = { going.append($0) }
        put(mirror, linesUp: 0)
        settle(0.5)
        JumpPresenceProbe.sample = nil
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "Back at the end, it has gone.")
        return (coming, nod, going)
    }

    func testTheButtonRisesInWithAPopNodsAndSinksAwayAndJustAppearsWithTheAnimationsOff() throws {
        let animated = try watchPresence(animations: true)
        XCTAssertTrue(animated.coming.contains { $0 > 0.15 && $0 < 0.85 }, "Steps in between: \(animated.coming.count) values.")
        XCTAssertGreaterThan(animated.coming.max() ?? 0, 1, "The spring takes it a touch past its place.")
        XCTAssertEqual(animated.coming.last ?? 0, 1, accuracy: 0.01, "…and it settles there.")
        XCTAssertTrue(animated.nod.contains { $0 - $0.rounded(.down) > 0.1 }, "Once in, the arrow nods toward the end.")
        XCTAssertTrue(animated.going.contains { $0 > 0.15 && $0 < 0.85 }, "It goes step by step too: \(animated.going.count) values.")
        XCTAssertEqual(animated.going, animated.going.sorted(by: >), "Only away.")

        let still = try watchPresence(animations: false)
        XCTAssertFalse((still.coming + still.going).contains { $0 > 0.01 && $0 < 0.99 }, "With the animations off it is simply there, and simply gone.")
        XCTAssertFalse(still.nod.contains { $0 - $0.rounded(.down) > 0.01 }, "…and the arrow holds still.")
    }

    func testReduceMotionKeepsAFadeAndTheAnimationsOffKeepNothing() {
        let moving = JumpPresence.transition(moves: true, fades: true)
        XCTAssertNotNil(moving.animation)
        let reduced = JumpPresence.transition(moves: false, fades: true)
        XCTAssertNotNil(reduced.animation, "Reduce Motion asks for less movement, not for no change: it fades.")
        XCTAssertNil(JumpPresence.transition(moves: false, fades: false).animation)
    }

    // MARK: Colour and words

    private func resolved(_ color: NSColor, dark: Bool) -> TabRGB {
        var out = TabRGB(0, 0, 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = TabRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return out
    }

    private func contrast(_ a: TabRGB, _ b: TabRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: TabRGB) -> Double { 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue) }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testOnlyTheArrowIsTheTabsColourAndItReadsOnGlassAndOnTheFlatBubble() {
        let black = TabRGB(0, 0, 0), paper = TabRGB(0.953, 0.941, 0.914)
        for dark in [true, false] {
            // The bubble where glass is not used is neutral: the island's chip, never a colour.
            let bubble = resolved(JumpToLatestButton.bubble, dark: dark)
            XCTAssertEqual(bubble.red, bubble.green, accuracy: 0.001); XCTAssertEqual(bubble.green, bubble.blue, accuracy: 0.001)
            for tint in TabTint.allCases {
                NookContrast.force(false)
                let arrow = resolved(tint.jumpArrow, dark: dark)
                XCTAssertEqual(contrast(arrow, dark ? tint.shades.pastel : tint.shades.deepMarker), 1, accuracy: 0.01, "\(tint): the tab's own colour.")
                XCTAssertGreaterThanOrEqual(contrast(arrow, bubble), 4.5, "\(tint), dark \(dark): on the flat bubble.")
                // Clear glass over the island: its surface seen through it, and a glass that has lifted it a good deal (light over the black, a
                // shade darker over the paper, with dark text blurred behind it).
                XCTAssertGreaterThanOrEqual(contrast(arrow, dark ? black : paper), 4.5, "\(tint), dark \(dark): on glass over the island's surface.")
                XCTAssertGreaterThanOrEqual(contrast(arrow, dark ? TabRGB(0.3, 0.3, 0.3) : TabRGB(0.85, 0.85, 0.85)), 4, "\(tint), dark \(dark): on a glass that lifted it.")
                // Increase Contrast always has the flat bubble, and the arrow goes a step further from it.
                NookContrast.force(true)
                let increasedBubble = resolved(JumpToLatestButton.bubble, dark: dark)
                XCTAssertGreaterThanOrEqual(contrast(resolved(tint.jumpArrow, dark: dark), increasedBubble), 7, "\(tint), dark \(dark), Increase Contrast.")
            }
        }
    }

    func testItsWordsAreSpanishAndSayWhereItGoes() {
        XCTAssertEqual(MirrorEnd.latestMessage.title, "Ir al último mensaje")
        XCTAssertEqual(MirrorEnd.latestOutput.title, "Ir al final")
        XCTAssertEqual(MirrorEnd.latestMessage.tip, NookTip("Ir al último mensaje", detail: MirrorEnd.latestMessage.detail))
        XCTAssertTrue(MirrorEnd.latestOutput.detail.contains("salida"))
    }
}
