import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The cue that a capture happened: what it says and in whose colour, where its window hangs for the collapsed island, the open one, a card under it and a
/// screen's edges, and how long it stays. The island it hangs from is a stand-in, far off every display, so no test touches the real one or puts anything on screen
/// that anybody could see.
@MainActor
final class ScreenVisionCueTests: XCTestCase {
    private func capture(_ origin: ScreenVisionOrigin, screens: Int = 1) -> ScreenVisionCapture {
        let shot = ScreenShot(path: "/tmp/nook-501/images/pantalla-20261007-140322.png", mimeType: "image/png", display: "Pantalla integrada", width: 1512, height: 982, date: ScreenVisionFixture.date)
        return ScreenVisionCapture(date: ScreenVisionFixture.date, origin: origin, shots: Array(repeating: shot, count: screens))
    }

    // MARK: What it says

    func testTheCueIsTheCapturesOwnWordsAndSaysHowManyScreensWhenThereAreSeveral() {
        let claude = ScreenVisionCueStyle(capture(.claude))
        XCTAssertEqual(claude.title, "Claude miró tu pantalla"); XCTAssertNil(claude.detail)
        XCTAssertEqual(claude.spoken, "Claude miró tu pantalla")
        let message = ScreenVisionCueStyle(capture(.composer))
        XCTAssertEqual(message.title, "Pantalla adjunta al mensaje")
        let several = ScreenVisionCueStyle(capture(.claude, screens: 3))
        XCTAssertEqual(several.detail, "3 pantallas", "A capture of every display does not pass for one.")
        XCTAssertEqual(several.spoken, "Claude miró tu pantalla. 3 pantallas")
        XCTAssertEqual(ScreenVisionCueStyle(capture(.claude, screens: 2)).detail, "2 pantallas")
        for style in [claude, message, several] { XCTAssertNotNil(NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil), style.symbol) }
    }

    func testClaudesOwnLookStaysLongerThanTheMessagesAndBothAreBrief() {
        let claude = ScreenVisionCueStyle(capture(.claude)).hold, message = ScreenVisionCueStyle(capture(.composer)).hold
        XCTAssertGreaterThan(claude, message, "What Claude decided by itself is read; what the user just sent is acknowledged.")
        XCTAssertGreaterThanOrEqual(claude, 3, "Long enough to read a line of five words.")
        XCTAssertLessThanOrEqual(claude, 5, "Short enough not to wait on: the island's notices stay five seconds.")
        XCTAssertLessThanOrEqual(message, 2.5)
    }

    func testTheColourSaysWhoIsSpeakingTerracottaForClaudeAndTheTabsOwnForTheUser() {
        let claude = ScreenVisionCueStyle(capture(.claude)), message = ScreenVisionCueStyle(capture(.composer))
        for tint in TabTint.allCases {
            XCTAssertEqual(claude.color(tint: tint), claudeSpinner, "Claude's look is Claude's colour in every tab.")
            XCTAssertEqual(message.color(tint: tint), tint.voice.marker.color, "The message's is the tab's, as the send button is.")
        }
    }

    private func luminance(_ c: TabRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }
    private func contrast(_ a: TabRGB, _ b: TabRGB) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testTheEyeReadsOnTheBlackPillInEveryColourItWears() {
        let ns = PetView.claudeSpinner.usingColorSpace(.sRGB)!
        let terracotta = TabRGB(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        let black = TabRGB(0, 0, 0)
        // The eye's own disc starts at two fifths of its colour and settles to a fifth: the brightest it gets under the glyph.
        for (name, color) in [("claude", terracotta)] + TabTint.allCases.map({ ($0.rawValue, $0.voice.marker) }) {
            for wash in [0.2, 0.4] {
                XCTAssertGreaterThanOrEqual(contrast(color, black.mixed(with: color, by: wash)), 3, "\(name) eye on its disc (\(wash))")
            }
            XCTAssertGreaterThanOrEqual(contrast(TabRGB(0.95, 0.95, 0.95), black), 7, "The words are near white on black")
        }
    }

    func testThePillFitsItsWindowWithRoomForItsShadowEvenForTheLongestCue() {
        for capture in [capture(.claude), capture(.claude, screens: 4), capture(.composer)] {
            let pill = NSHostingView(rootView: ScreenVisionCuePill(style: ScreenVisionCueStyle(capture), tint: .mint, entered: true))
            XCTAssertEqual(pill.fittingSize.height, ScreenVisionCuePill.height, accuracy: 0.5, "One line.")
            XCTAssertLessThanOrEqual(pill.fittingSize.width, ScreenVisionCue.windowSize.width - 40, "Room around it in the window for its shadow: \(pill.fittingSize.width)")
        }
        XCTAssertLessThan(ScreenVisionCuePill.height, ScreenVisionCue.windowSize.height - 20)
    }

    // MARK: Where it hangs

    private let screen = CGRect(x: -40000, y: -40000, width: 1512, height: 982)
    private var compact: CGRect { CGRect(x: screen.midX - 120, y: screen.maxY - 38, width: 240, height: 38) }
    private var open: CGRect { CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266) }

    /// The pill's own rectangle inside a window: centred, `ScreenVisionCuePill.height` tall.
    private func pillTop(_ window: CGRect) -> CGFloat { window.midY + ScreenVisionCuePill.height / 2 }

    func testItHangsUnderTheCollapsedIslandCentredOnIt() {
        let window = ScreenVisionCue.frame(island: compact, screen: screen)
        XCTAssertEqual(window.size, ScreenVisionCue.windowSize)
        XCTAssertEqual(window.midX, compact.midX, accuracy: 0.5, "On the notch's axis.")
        XCTAssertEqual(pillTop(window), compact.minY - ScreenVisionCue.gap, accuracy: 0.5, "A few points under the island's bottom edge.")
        XCTAssertLessThan(window.maxY, compact.maxY, "Under the screen's top.")
    }

    func testItHangsUnderTheOpenIslandsBottomEdgeAndNotOverItsContents() {
        let window = ScreenVisionCue.frame(island: open, screen: screen)
        XCTAssertEqual(pillTop(window), open.minY - ScreenVisionCue.gap, accuracy: 0.5)
        XCTAssertEqual(window.midX, open.midX, accuracy: 0.5)
    }

    func testItGoesUnderTheSettingsCardWhenOneHangsFromTheIslandAndUnderAnAlertsPeek() {
        let card = CGRect(x: open.midX - 176, y: open.minY - SettingsPlacement.gap - 330, width: SettingsCard.width, height: 330)
        let underCard = ScreenVisionCue.frame(island: open, screen: screen, avoiding: card)
        XCTAssertEqual(pillTop(underCard), card.minY - ScreenVisionCue.gap, accuracy: 0.5, "It never covers the card.")
        let above = CGRect(x: open.midX - 176, y: open.minY + 5, width: SettingsCard.width, height: 40)
        XCTAssertEqual(pillTop(ScreenVisionCue.frame(island: open, screen: screen, avoiding: above)), open.minY - ScreenVisionCue.gap, accuracy: 0.5, "A card that is not lower than the island changes nothing.")
        let chin = AlertPeekLayout(compact: compact.size).chin
        let underPeek = ScreenVisionCue.frame(island: compact, screen: screen, extraDrop: chin)
        XCTAssertEqual(pillTop(underPeek), compact.minY - chin - ScreenVisionCue.gap, accuracy: 0.5, "The collapsed island's alert hangs by its chin: the pill goes under that.")
    }

    func testItStaysOnTheScreenAtItsSidesAndItsBottom() {
        let left = CGRect(x: screen.minX + 10, y: screen.maxY - 38, width: 240, height: 38)
        XCTAssertEqual(ScreenVisionCue.frame(island: left, screen: screen).minX, screen.minX + ScreenVisionCue.margin, accuracy: 0.5, "Not past the left edge.")
        let right = CGRect(x: screen.maxX - 250, y: screen.maxY - 38, width: 240, height: 38)
        XCTAssertEqual(ScreenVisionCue.frame(island: right, screen: screen).maxX, screen.maxX - ScreenVisionCue.margin, accuracy: 0.5, "Nor the right one.")
        // An island as tall as the screen leaves no room under it: the pill sits over its lower part instead of leaving the display.
        let tall = CGRect(x: screen.midX - 286, y: screen.minY + 30, width: 572, height: screen.height - 30)
        let window = ScreenVisionCue.frame(island: tall, screen: screen)
        let room = (window.height - ScreenVisionCuePill.height) / 2
        XCTAssertGreaterThanOrEqual(window.minY + room, screen.minY + ScreenVisionCue.margin - 0.5, "The pill itself is on the display.")
    }

    // MARK: The window

    private final class Host: ScreenVisionCueHost {
        let cueModel: AppModel
        var cueIsland: CGRect
        var cueScreen: CGRect
        var cueDrop: CGFloat = 0
        var cueAvoids: CGRect?
        var cueLevel = NSWindow.Level.floating
        init(model: AppModel, island: CGRect, screen: CGRect) { cueModel = model; cueIsland = island; cueScreen = screen }
    }

    /// The hosts the test made: the cue holds its island weakly, so the test holds it.
    private var hosts: [Host] = []

    private func make(holdScale: Double = 0.05) throws -> (ScreenVisionCue, Host, ScreenVision, AppModel) {
        let vision = try ScreenVisionUIFixture.vision()
        let model = ScreenVisionUIFixture.model(vision)
        let host = Host(model: model, island: compact, screen: screen)
        hosts.append(host)
        return (ScreenVisionCue(host: host, holdScale: holdScale), host, vision, model)
    }

    func testNothingIsOnScreenUntilACaptureHappens() throws {
        let (cue, _, _, _) = try make()
        XCTAssertFalse(cue.isShowing); XCTAssertNil(cue.window, "No window is made until there is something to say.")
        XCTAssertNil(cue.style)
    }

    func testACapturesCueComesUpUnderTheIslandAsAWindowThatTakesNothingAndGoesByItself() async throws {
        let (cue, host, vision, _) = try make(holdScale: 0.25)
        defer { cue.cancel() }
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        XCTAssertTrue(cue.isShowing)
        XCTAssertEqual(cue.style?.title, "Claude miró tu pantalla")
        XCTAssertEqual(cue.windowFrame, ScreenVisionCue.frame(island: host.cueIsland, screen: host.cueScreen))
        let window = try XCTUnwrap(cue.window)
        XCTAssertTrue(window.ignoresMouseEvents, "It takes no clicks: nothing under it is covered.")
        XCTAssertFalse(window.canBecomeKey); XCTAssertFalse(window.canBecomeMain, "It never takes the keyboard.")
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel), "Nor does it bring Nook forward.")
        XCTAssertEqual(window.level, host.cueLevel)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces) && window.collectionBehavior.contains(.fullScreenAuxiliary), "It shows over a full-screen app too.")
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.hasShadow, "Its shadow is the pill's own.")
        XCTAssertFalse(window.isOpaque)
        XCTAssertFalse(cue.isLeaving)
        // It stays for its time, then fades, then the window goes.
        await ScreenVisionUIFixture.eventually(3) { cue.isLeaving }
        XCTAssertTrue(cue.isLeaving, "After its time it starts to go.")
        XCTAssertTrue(window.isVisible, "Still there while it fades.")
        await ScreenVisionUIFixture.eventually(3) { !cue.isShowing }
        XCTAssertFalse(cue.isShowing); XCTAssertFalse(window.isVisible, "Then it is put away: nothing is left on screen between captures.")
        XCTAssertNil(cue.style)
    }

    func testAMessagesPictureGetsItsOwnShorterCueInTheTabsColour() async throws {
        let (cue, _, vision, model) = try make(holdScale: 0.25)
        defer { cue.cancel() }
        let session = ScreenVisionUIFixture.session(in: model)
        session.tint = .lavender
        _ = try await vision.capture(.pointer, origin: .composer)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        XCTAssertEqual(cue.style?.title, "Pantalla adjunta al mensaje")
        XCTAssertEqual(cue.tint, .lavender, "The colour of the tab the message was sent from.")
        XCTAssertEqual(cue.style?.hold, ScreenVisionCueStyle.composerHold)
    }

    func testANewCaptureReplacesTheCueAndTheOldOnesTimeDoesNotTakeItAway() async throws {
        let (cue, _, vision, _) = try make(holdScale: 0.5)
        defer { cue.cancel() }
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        let started = Date(), first = cue.count
        // Claude's cue holds for 3.6 s × 0.5 = 1.8 s. A message's picture at 1.5 s has its own 1.0 s (it ends at about 2.6 s): the first one's end, at 1.8 s, would
        // come in the middle of it, and has gone by 2.2 s, where the second is looked at.
        await ScreenVisionUIFixture.pause(until: started.addingTimeInterval(1.5))
        _ = try await vision.capture(.pointer, origin: .composer)
        await ScreenVisionUIFixture.eventually { cue.style?.origin == .composer }
        XCTAssertEqual(cue.style?.origin, .composer, "The newest capture is the one told.")
        XCTAssertGreaterThan(cue.count, first, "A new pill: it comes in again, so it is noticed again.")
        XCTAssertFalse(cue.isLeaving)
        await ScreenVisionUIFixture.pause(until: started.addingTimeInterval(2.2))
        XCTAssertTrue(cue.isShowing, "The first cue's end (1.8 s) has passed (and its fade, 0.2 s more) and the second is still there.")
        XCTAssertEqual(cue.style?.origin, .composer)
        XCTAssertFalse(cue.isLeaving, "The first one's end did not start the second one's going.")
        await ScreenVisionUIFixture.eventually(4) { !cue.isShowing }
        XCTAssertFalse(cue.isShowing, "It goes after its own time.")
    }

    func testTheCueFollowsTheIslandAsItOpens() async throws {
        let (cue, host, vision, model) = try make(holdScale: 1)
        defer { cue.cancel() }
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        let collapsed = try XCTUnwrap(cue.windowFrame)
        host.cueIsland = open
        model.expanded = true
        await ScreenVisionUIFixture.eventually { cue.windowFrame != collapsed }
        XCTAssertEqual(cue.windowFrame, ScreenVisionCue.frame(island: open, screen: screen), "Under the open island's bottom edge, not over its contents.")
        host.cueIsland = compact
        model.expanded = false
        await ScreenVisionUIFixture.eventually { cue.windowFrame == collapsed }
        XCTAssertEqual(cue.windowFrame, collapsed, "And back under the collapsed one.")
    }

    func testTheCueKeepsOffTheSettingsCard() async throws {
        let (cue, host, vision, model) = try make(holdScale: 1)
        defer { cue.cancel() }
        host.cueIsland = open
        model.expanded = true
        host.cueAvoids = CGRect(x: open.midX - 176, y: open.minY - SettingsPlacement.gap - 330, width: SettingsCard.width, height: 330)
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        XCTAssertEqual(cue.windowFrame, ScreenVisionCue.frame(island: open, screen: screen, avoiding: host.cueAvoids), "Under the card the island carries.")
    }

    func testTheCueDoesNotMoveWhenTheAnimationsAreOffAndCancelPutsItAwayAtOnce() async throws {
        let (cue, _, vision, model) = try make(holdScale: 1)
        model.animations = false
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        XCTAssertFalse(cue.animates, "The app's own preference for the pet's animations is honoured: the pill just appears (Reduce Motion is read by the pill itself).")
        let window = try XCTUnwrap(cue.window)
        cue.cancel()
        XCTAssertFalse(cue.isShowing); XCTAssertFalse(window.isVisible, "A change of screens puts it away at once.")
        model.animations = true
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.eventually { cue.isShowing }
        XCTAssertTrue(cue.animates)
        cue.cancel()
    }

    func testAGoneHostLeavesNothingToShowOn() async throws {
        let vision = try ScreenVisionUIFixture.vision()
        let model = ScreenVisionUIFixture.model(vision)
        var host: Host? = Host(model: model, island: compact, screen: screen)
        let cue = ScreenVisionCue(host: host!, holdScale: 1)
        host = nil
        _ = try await vision.capture(.pointer, origin: .claude)
        await ScreenVisionUIFixture.pause(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(cue.isShowing, "The cue holds its island weakly and says nothing to one that is gone.")
    }

    // MARK: How the pill looks and moves

    func testThePillComesInAndGoesWithMotionAndJustAppearsWithout() {
        let style = ScreenVisionCueStyle(capture(.claude))
        let size = CGSize(width: 300, height: 60)
        // Not yet in: nothing to see, the pill waits to come.
        func pill(entered: Bool, leaving: Bool, motion: Bool) -> Data {
            ScreenVisionUIFixture.bytes(ScreenVisionUIFixture.bitmap(of: ScreenVisionCuePill(style: style, tint: .mint, leaving: leaving, motion: motion, entered: entered).frame(width: size.width, height: size.height), size: size, settle: 0.1))
        }
        let shown = pill(entered: true, leaving: false, motion: true)
        XCTAssertNotEqual(shown, pill(entered: true, leaving: true, motion: true), "Leaving, it fades.")
        let gone = ScreenVisionUIFixture.average(ScreenVisionUIFixture.bitmap(of: ScreenVisionCuePill(style: style, tint: .mint, leaving: true, motion: true, entered: true).frame(width: size.width, height: size.height), size: size, settle: 0.8))
        XCTAssertEqual(gone.count, 0, "Faded out: nothing of the pill is left.")
        // No motion: it is simply there from the first frame, and simply gone when it leaves.
        let still = ScreenVisionUIFixture.average(ScreenVisionUIFixture.bitmap(of: ScreenVisionCuePill(style: style, tint: .mint, motion: false).frame(width: size.width, height: size.height), size: size, settle: 0.05))
        XCTAssertGreaterThan(still.count, 500, "With no motion the pill is there at once.")
        let leftStill = ScreenVisionUIFixture.average(ScreenVisionUIFixture.bitmap(of: ScreenVisionCuePill(style: style, tint: .mint, leaving: true, motion: false).frame(width: size.width, height: size.height), size: size, settle: 0.05))
        XCTAssertEqual(leftStill.count, 0, "And gone at once.")
    }

    func testClaudesPillIsTerracottaAndTheMessagesWearsTheTabsColour() {
        let size = CGSize(width: 300, height: 60)
        func colour(_ origin: ScreenVisionOrigin, tint: TabTint) -> (red: Double, green: Double, blue: Double, count: Int) {
            // The eye's disc, at the left end of the pill (which starts 20 pt in).
            let pill = ScreenVisionCuePill(style: ScreenVisionCueStyle(capture(origin)), tint: tint, entered: true).padding(.leading, 20).frame(width: size.width, height: size.height, alignment: .leading)
            let rep = ScreenVisionUIFixture.bitmap(of: pill, size: size)
            let scale = Double(rep.pixelsWide) / size.width
            return ScreenVisionUIFixture.average(rep, within: CGRect(x: 24 * scale, y: 18 * scale, width: 22 * scale, height: 24 * scale))
        }
        let claude = colour(.claude, tint: .lavender)
        XCTAssertGreaterThan(claude.red, claude.blue + 0.05, "Terracotta is red-orange, whatever the tab's colour.")
        let message = colour(.composer, tint: .lavender)
        XCTAssertGreaterThan(message.blue, message.green, "The message's cue in a lavender tab is violet.")
        let mint = colour(.composer, tint: .mint)
        XCTAssertGreaterThan(mint.green, mint.red, "And in a mint tab, mint.")
    }
}
