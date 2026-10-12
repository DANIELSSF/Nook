import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The island's own tooltips (`NookTip.swift`): where the bubble stands, how long the pointer rests before it shows, what each control of the composer's row
/// says, and what the bubble does not do (take a click, leave the text's I-beam over it, outlive a click). The renders of every tip are at the end and run only
/// when NOOK_RENDER_DIR is set.
@MainActor
final class NookTipTests: XCTestCase {
    private let pane = CGSize(width: 572, height: 204)

    // MARK: Where it stands

    func testTheBubbleIsCentredOverTheControlAndAboveIt() {
        let control = CGRect(x: 200, y: 150, width: 24, height: 24)
        let frame = NookTipGeometry.frame(of: CGSize(width: 120, height: 36), over: control, in: pane)
        XCTAssertEqual(frame.midX, control.midX, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, control.minY - NookTipGeometry.gap, accuracy: 0.01, "It stands above the control, a few points clear of it.")
        XCTAssertFalse(frame.intersects(control), "Never over what it explains.")
    }

    func testTheBubbleStaysBetweenThePanesMarginsWhateverControlItExplains() {
        let size = CGSize(width: 250, height: 36)
        for x in stride(from: CGFloat(0), through: pane.width - 24, by: 12) {
            let control = CGRect(x: x, y: 150, width: 24, height: 24)
            let frame = NookTipGeometry.frame(of: size, over: control, in: pane)
            XCTAssertGreaterThanOrEqual(frame.minX, NookTipGeometry.margin, "Control at x \(x): not clipped at the left.")
            XCTAssertLessThanOrEqual(frame.maxX, pane.width - NookTipGeometry.margin, "Control at x \(x): not clipped at the right.")
            XCTAssertTrue(frame.minX <= control.midX && frame.maxX >= control.midX, "Control at x \(x): it still stands over the control it explains.")
        }
    }

    func testTheBubbleStandsBelowOnlyWhereThereIsNoRoomAbove() {
        let size = CGSize(width: 120, height: 36)
        let high = CGRect(x: 100, y: 20, width: 24, height: 24)
        let below = NookTipGeometry.frame(of: size, over: high, in: pane)
        XCTAssertEqual(below.minY, high.maxY + NookTipGeometry.gap, accuracy: 0.01)
        let low = CGRect(x: 100, y: 120, width: 24, height: 24)
        XCTAssertLessThan(NookTipGeometry.frame(of: size, over: low, in: pane).minY, low.minY, "With room above it is above.")
    }

    func testABubbleWiderThanThePaneStillFitsBetweenTheMargins() {
        // The layout hands the bubble at most the pane less its margins; a frame for exactly that width starts at the left margin.
        let width = pane.width - 2 * NookTipGeometry.margin
        let frame = NookTipGeometry.frame(of: CGSize(width: width, height: 40), over: CGRect(x: 500, y: 150, width: 24, height: 24), in: pane)
        XCTAssertEqual(frame.minX, NookTipGeometry.margin, accuracy: 0.01)
        XCTAssertEqual(frame.maxX, pane.width - NookTipGeometry.margin, accuracy: 0.01)
    }

    // MARK: How long it waits

    func testTheFirstTipWaitsAndTheNextOneAlongTheRowDoesNot() {
        var warmth = NookTipWarmth()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(warmth.delay(at: start), NookTipTiming.delay, "A cold row waits the whole time.")
        warmth.came(at: start)
        warmth.went(at: start)
        XCTAssertEqual(warmth.delay(at: start.addingTimeInterval(0.3)), NookTipTiming.warmDelay, "Going from one control to the next, the second tip is there at once.")
        XCTAssertEqual(warmth.delay(at: start.addingTimeInterval(NookTipTiming.warmWindow + 0.01)), NookTipTiming.delay, "A pause cools the row again.")
        XCTAssertLessThan(NookTipTiming.warmDelay, NookTipTiming.delay)
        XCTAssertTrue((0.3...0.8).contains(NookTipTiming.delay), "Long enough for a pointer passing by to show nothing, short enough not to be waited on.")
    }

    func testATipThatIsUpKeepsTheRowWarmHoweverLongItStaysAndWhateverTheOrderOfTheNextWait() {
        var warmth = NookTipWarmth()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        warmth.came(at: start)
        // The pointer leaves one control and reaches the next in the same breath: the next one's wait may begin before the first tip has gone.
        XCTAssertEqual(warmth.delay(at: start.addingTimeInterval(30)), NookTipTiming.warmDelay, "A tip that has been up a long while still warms the row.")
        warmth.went(at: start.addingTimeInterval(30))
        XCTAssertEqual(warmth.delay(at: start.addingTimeInterval(30.3)), NookTipTiming.warmDelay, "…and for a moment after it goes.")
        XCTAssertEqual(warmth.delay(at: start.addingTimeInterval(30 + NookTipTiming.warmWindow + 0.01)), NookTipTiming.delay, "…and then the row is cold.")
        warmth.went(at: start.addingTimeInterval(31))
        XCTAssertEqual(warmth.up, 0, "A tip that goes twice does not leave the count below none.")
    }

    func testMotionFollowsReduceMotionAndTheAnimationsPreference() {
        XCTAssertNotNil(NookTipMotion.animation(reduceMotion: false, animationsOn: true))
        XCTAssertNil(NookTipMotion.animation(reduceMotion: true, animationsOn: true), "Reduce Motion: it just appears.")
        XCTAssertNil(NookTipMotion.animation(reduceMotion: false, animationsOn: false), "The app's animations off: it just appears.")
    }

    // MARK: What each control says

    func testEveryModeSaysWhatItIsAndHowToPassToTheNext() {
        let modes: [ClaudeMode] = [.standard,
                                   ClaudeMode(kind: .auto, label: "auto mode on", hints: []), ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: []),
                                   ClaudeMode(kind: .plan, label: "plan mode on", hints: []), ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: []),
                                   ClaudeMode(kind: nil, label: "yolo mode on", hints: [])]
        for mode in modes {
            let style = ClaudeModeStyle(mode)
            let tip = style.tip()
            XCTAssertEqual(tip.title, "Modo")
            XCTAssertEqual(tip.value, style.title, "The tip names the mode the chip is in.")
            XCTAssertTrue(tip.detail?.contains("⇧⇥") == true, "\(style.title): it says how to change it.")
            XCTAssertFalse(style.blurb.isEmpty)
        }
        let blocked = ClaudeModeStyle(.standard).tip(blocked: "Cierra antes el panel de Claude.")
        XCTAssertEqual(blocked.detail, "Cierra antes el panel de Claude.", "A chip that cannot be pressed says why, and nothing else.")
        XCTAssertTrue(ClaudeModeStyle(.standard).tip(needsAccessibility: true).detail?.contains("Accesibilidad") == true)
        XCTAssertFalse(ClaudeModeStyle(.standard).tip().detail?.contains("Accesibilidad") == true)
    }

    func testTheModelAndTheEffortTipsNameTheirState() {
        XCTAssertEqual(ClaudeModelChip.tip(model: "Opus 5.5")?.value, "Opus 5.5")
        XCTAssertEqual(ClaudeModelChip.tip(model: "Opus 4.6 (1M context)")?.value, "Opus 4.6", "Without what Claude adds in brackets.")
        XCTAssertEqual(ClaudeModelChip.tip(model: nil)?.value, "sin leer")
        XCTAssertNil(ClaudeModelChip.tip(model: "Opus 5.5", open: true), "While its list is open the chip has no tip: the list is what it explains.")
        XCTAssertEqual(ClaudeModelChip.tip(model: "Opus 5.5", blocked: "Claude está trabajando.")?.detail, "Claude está trabajando.")
        for level in ClaudeEffort.allCases {
            let tip = EffortChip.tip(effort: level)
            XCTAssertEqual(tip.title, "Esfuerzo")
            XCTAssertEqual(tip.value, level.title)
            XCTAssertTrue(tip.detail?.contains(level.detail) == true)
        }
        XCTAssertEqual(EffortChip.tip(effort: nil).value, "sin leer")
        XCTAssertTrue(EffortChip.tip(effort: .high, asking: true).detail?.contains("Esperando") == true)
    }

    func testTheScreenChipSaysWhetherTheScreenGoesWithEachMessage() {
        let on = ScreenVisionChipCopy.tip(attaching: true, capturing: false, agent: .claude)
        let off = ScreenVisionChipCopy.tip(attaching: false, capturing: false, agent: .claude)
        XCTAssertEqual(on.value, "adjunta")
        XCTAssertEqual(off.value, "sin adjuntar")
        XCTAssertTrue(on.detail?.contains("quitarla") == true, "On: a click takes it away.")
        XCTAssertTrue(off.detail?.contains("adjuntar") == true, "Off: a click attaches it.")
        XCTAssertEqual(ScreenVisionChipCopy.tip(attaching: true, capturing: true, agent: .claude).title, "Capturando tu pantalla…")
    }

    // MARK: Hover works where the island is hovered

    func testHoverIsTrackedWhileThePanelIsNeitherKeyNorActive() {
        // The island opens on a hover without becoming key, in an app that is not the active one. SwiftUI's hover reaches the hosting view through a
        // tracking area; the tips rest on it, so it has to be one that is not tied to the key window or the active app.
        struct Probe: View { @State var over = false; var body: some View { Color.red.frame(width: 60, height: 24).onHover { over = $0 } } }
        let host = NSHostingView(rootView: Probe())
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        let panel = NotchPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(panel.isKeyWindow)
        let always = host.trackingAreas.filter { $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.activeAlways) }
        XCTAssertFalse(always.isEmpty, "A hover is heard whether or not the panel is key: \(host.trackingAreas.map { $0.options.rawValue }).")
    }

    // MARK: In the pane

    private func makeModel() -> AppModel { ScreenVisionUIFixture.model(try! ScreenVisionUIFixture.vision(enabled: true)) }

    /// The pane as the island lays it out, `pinned` being the control whose tip shows.
    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var pinned: String?
        var width: CGFloat = NotchGeometry.expandedWidth
        var height: CGFloat = NotchGeometry.expandedHeight(topInset: 32)
        var keysOpen = false
        var effortOpen = false
        var modelMenuOpen = false
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, keysOpen: keysOpen, effortOpen: effortOpen, modelMenuOpen: modelMenuOpen).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
                .environment(\.nookTipPinned, pinned)
        }
    }

    private func mount<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// A window that is on the screen list, far off it: the events a test sends reach it as a real click would.
    private func shown<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private var islandSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)) }

    /// The ids of the controls the composer's row offers while Claude runs in the tab with the screen chip on.
    private let rowControls = ["screen", "mode", "model", "effort", "usage", "keys", "mic", "send"]

    func testNoTipShowsUntilThePointerRests() {
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        let (window, _) = mount(Island(model: model, session: session, pinned: nil), size: islandSize)
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "Nothing floats over the pane at rest.")
    }

    func testEveryControlOfTheRowHasATipAboveItBetweenThePanesMargins() throws {
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        XCTAssertNotNil(session.agentMode, "The fixture's screen names a mode, so its chip stands in the row.")
        for id in rowControls {
            let (window, _) = mount(Island(model: model, session: session, pinned: id), size: islandSize)
            let holes = PointerHoles.frames(in: window)
            XCTAssertEqual(holes.count, 1, "\(id): one bubble, and it marks itself so the text under it gives up the pointer.")
            let frame = try XCTUnwrap(holes.first, id)
            // Window coordinates: y runs up from the island's bottom. The row is the bottom 9 + 35 points of the pane.
            let rowTop = ComposerMetrics.bottomInset + ComposerMetrics.controlsHeight
            XCTAssertGreaterThanOrEqual(frame.minY, rowTop, "\(id): above the controls' row, never over it.")
            XCTAssertGreaterThanOrEqual(frame.minX, NookTipGeometry.margin - 0.5, "\(id): not clipped at the left.")
            XCTAssertLessThanOrEqual(frame.maxX, islandSize.width - NookTipGeometry.margin + 0.5, "\(id): not clipped at the right.")
            XCTAssertLessThanOrEqual(frame.maxY, islandSize.height - 62, "\(id): inside the pane, under the tab row.")
        }
    }

    func testTheTipsOfTheKeysAndOfTheLevelsAreThereWhileTheirRowsAre() throws {
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        for (id, keysOpen, effortOpen) in [("key-up", true, false), ("interrupt", true, false), ("level-xhigh", false, true), ("levels-close", false, true), ("levels-label", false, true)] {
            let (window, _) = mount(Island(model: model, session: session, pinned: id, keysOpen: keysOpen, effortOpen: effortOpen), size: islandSize)
            XCTAssertEqual(PointerHoles.frames(in: window).count, 1, "\(id) has a tip.")
        }
    }

    func testTheTipOfAControlThatIsNotInTheRowIsNotShown() {
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        let (window, _) = mount(Island(model: model, session: session, pinned: "nothing-like-it"), size: islandSize)
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty)
    }

    func testTheModelChipsTipGivesWayToItsListWhileItIsOpen() {
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        // The list is a card that marks itself too: what the tip would add is what is compared.
        let (listWindow, _) = mount(Island(model: model, session: session, pinned: nil, modelMenuOpen: true), size: islandSize)
        let (pinnedWindow, _) = mount(Island(model: model, session: session, pinned: "model", modelMenuOpen: true), size: islandSize)
        XCTAssertFalse(PointerHoles.frames(in: listWindow).isEmpty, "The open list marks itself.")
        XCTAssertEqual(PointerHoles.frames(in: pinnedWindow), PointerHoles.frames(in: listWindow), "The list hangs over the row: a tip over the chip would be under it.")
    }

    // MARK: How long it waits, through the real modifier

    private final class Pointer: ObservableObject { @Published var over: String? }

    /// Two controls side by side with a virtual pointer to put on either.
    private struct Row: View {
        @ObservedObject var pointer: Pointer
        var body: some View {
            HStack(spacing: 120) {
                Color.blue.frame(width: 24, height: 24).nookTip(NookTip("Uno", detail: "El primero"), id: "a")
                Color.green.frame(width: 24, height: 24).nookTip(NookTip("Dos", detail: "El segundo"), id: "b")
            }.padding(.top, 70).padding(.horizontal, 60).frame(width: 400, height: 120, alignment: .bottomLeading)
                .overlayPreferenceValue(NookTipKey.self) { NookTipLayer(entry: $0) }
                .environment(\.nookTipPointer, pointer.over)
        }
    }

    func testTheTipComesAfterItsWaitGoesWithThePointerAndTheNextOneComesAtOnce() throws {
        NookTipWarmthClock.shared.reset()
        let pointer = Pointer()
        let (window, _) = shown(Row(pointer: pointer), size: NSSize(width: 400, height: 120))
        defer { window.close() }
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func bubbles() -> [NSRect] { PointerHoles.frames(in: window) }

        XCTAssertTrue(bubbles().isEmpty, "Nothing before the pointer comes.")
        pointer.over = "a"
        wait(NookTipTiming.delay * 0.4)
        XCTAssertTrue(bubbles().isEmpty, "Not yet: the pointer has only just come.")
        wait(NookTipTiming.delay + 0.9)
        let first = try XCTUnwrap(bubbles().first, "It has rested long enough: the tip is there.")
        XCTAssertEqual(bubbles().count, 1)
        // Leaving takes it away at once, and a pointer that came and went in less than the wait showed nothing.
        pointer.over = nil
        wait(0.25)
        XCTAssertTrue(bubbles().isEmpty, "The pointer left: so did the tip.")
        // Once the row has cooled, a pointer that is only passing by shows nothing, now or later.
        wait(NookTipTiming.warmWindow + 0.1)
        pointer.over = "a"
        wait(NookTipTiming.delay * 0.5)
        XCTAssertTrue(bubbles().isEmpty, "Not yet.")
        pointer.over = nil
        wait(NookTipTiming.delay + 0.2)
        XCTAssertTrue(bubbles().isEmpty, "A pointer that was there for less than the wait showed nothing.")

        // A tip that has just been up warms the row: the next control's comes at once, not after the whole wait.
        pointer.over = "a"
        wait(NookTipTiming.delay + 0.9)
        XCTAssertEqual(bubbles().count, 1)
        pointer.over = "b"
        wait(NookTipTiming.warmDelay + 0.3)
        let second = try XCTUnwrap(bubbles().first, "Going along the row, the second tip is there at once.")
        XCTAssertGreaterThan(second.midX, first.midX + 60, "…and it is over the second control.")
        // After a pause the row is cold again.
        pointer.over = nil
        wait(NookTipTiming.warmWindow + 0.3)
        pointer.over = "a"
        wait(NookTipTiming.delay * 0.4)
        XCTAssertTrue(bubbles().isEmpty, "Cold again: the whole wait.")
    }

    // MARK: What the bubble does not do

    /// A control with a button behind the place where its tip stands, to see where a click goes.
    private struct Harness: View {
        var pinned: String? = "chip"
        var onBehind: () -> Void
        var body: some View {
            ZStack(alignment: .bottomLeading) {
                Button(action: onBehind) { Color.gray.opacity(0.2).frame(width: 400, height: 160) }.buttonStyle(.plain)
                Color.blue.frame(width: 24, height: 24).nookTip(NookTip("Modelo", value: "Opus 5.5", detail: "Pulsa para cambiar"), id: "chip").padding(.leading, 180).padding(.bottom, 8)
            }.frame(width: 400, height: 160)
                .overlayPreferenceValue(NookTipKey.self) { NookTipLayer(entry: $0) }
                .environment(\.nookTipPinned, pinned)
        }
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            // The application's own dispatch, which the local monitors hear (a window's `sendEvent` alone is not heard by them).
            NSApp.sendEvent(event)
        }
    }

    func testTheBubbleTakesNoClicksAndAClickPutsItAway() throws {
        // The control run: with no tip showing the click lands on the button, so the test's own clicks do reach it.
        var control = 0
        let (quietWindow, _) = shown(Harness(pinned: nil) { control += 1 }, size: NSSize(width: 400, height: 160))
        defer { quietWindow.close() }
        click(at: NSPoint(x: 100, y: 100), in: quietWindow)
        XCTAssertEqual(control, 1, "The harness's button answers a click.")
        var behind = 0
        let (window, host) = shown(Harness { behind += 1 }, size: NSSize(width: 400, height: 160))
        defer { window.close() }
        let bubble = try XCTUnwrap(PointerHoles.frames(in: window).first, "The tip shows (pinned).")
        XCTAssertGreaterThan(bubble.minY, 8 + 24, "Above the control.")
        click(at: NSPoint(x: bubble.midX, y: bubble.midY), in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(behind, 1, "The click went through the bubble to what is under it.")
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "A click puts the tip away.")
    }

    func testAKeyPutsTheBubbleAwayToo() throws {
        let (window, host) = shown(Harness { }, size: NSSize(width: 400, height: 160))
        defer { window.close() }
        XCTAssertEqual(PointerHoles.frames(in: window).count, 1)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        NSApp.sendEvent(key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty)
    }

    func testTheTextUnderTheBubbleGivesUpTheIBeamWhereTheBubbleStands() throws {
        // As the pane lays it out: the composer's field under where the bubble stands over a chip of the row.
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        let (window, host) = mount(Island(model: model, session: session, pinned: "model"), size: islandSize)
        let bubble = try XCTUnwrap(PointerHoles.frames(in: window).first)
        var fields: [ComposerFieldView] = []
        func visit(_ view: NSView) { if let field = view as? ComposerFieldView { fields.append(field) }; view.subviews.forEach(visit) }
        visit(host)
        let field = try XCTUnwrap(fields.first)
        XCTAssertTrue(field.convert(field.bounds, to: nil).intersects(bubble), "The bubble stands over the message field in the Normal island.")
        // The field's clip view claims the I-beam over its text less the holes: none of it where the bubble is.
        let clip = try XCTUnwrap(field.scroll.contentView as? TextClipView)
        clip.resetCursorRects()
        let holes = PointerHoles.frames(in: window).map { clip.convert($0, from: nil) }
        XCTAssertFalse(PointerHoles.carve(clip.bounds, around: holes).contains { clip.convert($0, to: nil).intersects(bubble.insetBy(dx: 1, dy: 1)) },
                       "What is left of the I-beam's claim does not reach the bubble.")
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, appearance: NSAppearance.Name = .darkAqua, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// The tip of every control of the row, in the Normal island and in the smallest one (and the tips of the strip of keys and of the levels).
    func testRenderTheTips() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let session = ScreenVisionUIFixture.session(in: model)
        for id in rowControls {
            try write(NSHostingView(rootView: Island(model: model, session: session, pinned: id)), size: islandSize, to: url(directory, "tip-\(id).png"))
        }
        let small = NSSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.minExpandedHeight(topInset: 32))
        for id in ["screen", "mode", "send"] {
            try write(NSHostingView(rootView: Island(model: model, session: session, pinned: id, width: small.width, height: small.height)), size: small, to: url(directory, "tip-small-\(id).png"))
        }
        for (id, keys, effort) in [("key-tab", true, false), ("interrupt", true, false), ("level-xhigh", false, true), ("levels-close", false, true)] {
            try write(NSHostingView(rootView: Island(model: model, session: session, pinned: id, keysOpen: keys, effortOpen: effort)), size: islandSize, to: url(directory, "tip-\(id).png"))
        }
        // Light system appearance: the island is black in both, so the tip is the same.
        try write(NSHostingView(rootView: Island(model: model, session: session, pinned: "model")), size: islandSize, appearance: .aqua, to: url(directory, "tip-model-light.png"))
    }
}
