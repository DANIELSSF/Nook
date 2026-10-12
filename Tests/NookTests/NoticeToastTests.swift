import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The countdown of a notice: five seconds that only run while the island is on screen and the pointer is away from the card, and that keep what is left
/// while they are held.
final class NoticeCountdownTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testANoticeLastsFiveSecondsAndNeverGoesBelowNothing() {
        XCTAssertEqual(NoticeCountdown.standard, 5)
        let countdown = NoticeCountdown(now: t0)
        XCTAssertTrue(countdown.isRunning)
        XCTAssertEqual(countdown.remaining(at: t0), 5)
        XCTAssertEqual(countdown.remaining(at: at(2)), 3, accuracy: 1e-9)
        XCTAssertFalse(countdown.isOver(at: at(4.99)))
        XCTAssertTrue(countdown.isOver(at: at(5)))
        XCTAssertEqual(countdown.remaining(at: at(60)), 0)
        XCTAssertEqual(countdown.end, at(5), "The moment it runs out, for whoever waits for it.")
    }

    func testThePointerOnTheCardHoldsItAndLeavingGoesOnFromWhereItWas() {
        var countdown = NoticeCountdown(now: t0)
        countdown.setHovering(true, now: at(2))
        XCTAssertFalse(countdown.isRunning)
        XCTAssertNil(countdown.end, "Held, there is nothing to wait for.")
        XCTAssertEqual(countdown.remaining(at: at(2)), 3, accuracy: 1e-9)
        XCTAssertEqual(countdown.remaining(at: at(500)), 3, accuracy: 1e-9, "Held for as long as the pointer stays.")
        XCTAssertFalse(countdown.isOver(at: at(500)))
        countdown.setHovering(false, now: at(10))
        XCTAssertTrue(countdown.isRunning)
        XCTAssertEqual(countdown.remaining(at: at(11)), 2, accuracy: 1e-9, "It did not start over: three seconds were left, and one has gone.")
        XCTAssertEqual(countdown.end, at(13))
    }

    func testEachVisitOfThePointerHoldsWhatIsLeftThen() {
        var countdown = NoticeCountdown(now: t0)
        countdown.setHovering(true, now: at(1))      // 4 left
        countdown.setHovering(false, now: at(3))
        countdown.setHovering(true, now: at(4))      // 3 left
        countdown.setHovering(false, now: at(9))
        XCTAssertEqual(countdown.remaining(at: at(9)), 3, accuracy: 1e-9)
        XCTAssertEqual(countdown.end, at(12))
    }

    func testANoticeSetWithTheIslandOutOfSightWaitsForIt() {
        var countdown = NoticeCountdown(onScreen: false, now: t0)
        XCTAssertFalse(countdown.isRunning)
        XCTAssertEqual(countdown.remaining(at: at(30)), 5, "Nothing was spent while nobody could read it.")
        countdown.setOnScreen(true, now: at(30))
        XCTAssertEqual(countdown.remaining(at: at(32)), 3, accuracy: 1e-9)
        // The island going away again holds it where it is.
        countdown.setOnScreen(false, now: at(33))
        XCTAssertEqual(countdown.remaining(at: at(100)), 2, accuracy: 1e-9)
    }

    func testItRunsOnlyWhenBothConditionsHold() {
        var countdown = NoticeCountdown(now: t0)
        countdown.setHovering(true, now: at(1))
        countdown.setOnScreen(false, now: at(2))
        // The pointer leaves while the island is out of sight: still held.
        countdown.setHovering(false, now: at(3))
        XCTAssertFalse(countdown.isRunning)
        XCTAssertFalse(countdown.runs)
        XCTAssertEqual(countdown.remaining(at: at(50)), 4, accuracy: 1e-9)
        // The island comes back under the pointer: held again.
        countdown.setHovering(true, now: at(60))
        countdown.setOnScreen(true, now: at(61))
        XCTAssertFalse(countdown.isRunning)
        countdown.setHovering(false, now: at(70))
        XCTAssertTrue(countdown.isRunning)
        XCTAssertEqual(countdown.remaining(at: at(71)), 3, accuracy: 1e-9)
    }

    func testAnInputThatDoesNotChangeChangesNothing() {
        var countdown = NoticeCountdown(now: t0)
        let before = countdown
        countdown.setHovering(false, now: at(3))
        countdown.setOnScreen(true, now: at(4))
        XCTAssertEqual(countdown, before, "Same inputs, same value: it does not restart the wait on the end of the countdown.")
        countdown.setHovering(true, now: at(1))
        XCTAssertNotEqual(countdown, before, "Held is another value, so whoever waits on it waits again.")
    }

    func testAPointerThatStartsOnTheCardHoldsItFromTheStart() {
        var countdown = NoticeCountdown(hovering: true, now: t0)
        XCTAssertFalse(countdown.isRunning)
        XCTAssertEqual(countdown.remaining(at: at(20)), 5)
        countdown.setHovering(false, now: at(20))
        XCTAssertEqual(countdown.end, at(25))
    }

    func testTheRingGoesDownFromFullToNothingAndNeverOutsideThat() {
        let countdown = NoticeCountdown(now: t0)
        XCTAssertEqual(countdown.fraction(at: t0), 1)
        XCTAssertEqual(countdown.fraction(at: at(2.5)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(countdown.fraction(at: at(5)), 0)
        XCTAssertEqual(countdown.fraction(at: at(99)), 0)
        XCTAssertEqual(countdown.fraction(at: at(-3)), 1, "A frame whose date trails the moment the clock started has spent nothing.")
        let along = stride(from: 0.0, through: 6.0, by: 0.1).map { countdown.fraction(at: at($0)) }
        XCTAssertEqual(along, along.sorted(by: >), "It only goes down.")
    }

    func testWithNoMotionTheRingGoesDownAFifthAtATime() {
        let countdown = NoticeCountdown(now: t0)
        let steps = stride(from: 0.0, through: 5.0, by: 0.05).map { countdown.fraction(at: at($0), stepped: true) }
        XCTAssertEqual(Set(steps.map { ($0 * 5).rounded() }), [5, 4, 3, 2, 1, 0], "Five whole steps and the end.")
        XCTAssertEqual(steps, steps.sorted(by: >))
        XCTAssertEqual(countdown.fraction(at: at(0.4), stepped: true), 1)
        XCTAssertEqual(countdown.fraction(at: at(1.2), stepped: true), 0.8, accuracy: 1e-9)
        XCTAssertEqual(countdown.fraction(at: at(4.7), stepped: true), 0.2, accuracy: 1e-9, "The last fifth stays until the end.")
        XCTAssertEqual(countdown.fraction(at: at(5), stepped: true), 0)
    }

    func testAShorterCountdownIsTheSameShape() {
        let countdown = NoticeCountdown(duration: 0.5, now: t0)
        XCTAssertEqual(countdown.fraction(at: at(0.25)), 0.5, accuracy: 1e-9)
        XCTAssertTrue(countdown.isOver(at: at(0.5)))
        XCTAssertEqual(countdown.fraction(at: t0, stepped: true), 1, "A step is never more than all of it.")
    }
}

/// What closes a notice: only the text the card shows, so the end of an old card never closes a newer notice.
@MainActor
final class NoticeClosingTests: XCTestCase {
    private func model() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-notice-\(UUID().uuidString)")!) }

    func testClosingTheNoticeTheCardShowsClearsIt() {
        let model = model()
        model.notice = "No hay ninguna imagen en el portapapeles."
        model.closeNotice("No hay ninguna imagen en el portapapeles.")
        XCTAssertNil(model.notice)
    }

    func testTheEndOfAnOldCardDoesNotCloseANewerNotice() {
        let model = model()
        model.notice = "Primero."
        model.notice = "Segundo."
        model.closeNotice("Primero.")
        XCTAssertEqual(model.notice, "Segundo.", "The first card's ✕ or timeout came late: the second notice is not theirs to close.")
        model.closeNotice("Segundo.")
        XCTAssertNil(model.notice)
    }

    func testClosingWhenThereIsNothingToCloseDoesNothing() {
        let model = model()
        model.closeNotice("Nada.")
        XCTAssertNil(model.notice)
    }
}

/// How the card comes and goes, and how long it stays by default.
final class NoticeMotionTests: XCTestCase {
    func testTheCardComesAndGoesWithMotionOnlyWhenMotionIsAllowed() {
        XCTAssertNotNil(NoticeMotion.animation(reduceMotion: false, animationsOn: true))
        XCTAssertNil(NoticeMotion.animation(reduceMotion: true, animationsOn: true), "Reduce Motion asks for none.")
        XCTAssertNil(NoticeMotion.animation(reduceMotion: false, animationsOn: false), "The app's animations switched off ask for none.")
        XCTAssertNil(NoticeMotion.animation(reduceMotion: true, animationsOn: false))
        XCTAssertLessThanOrEqual(NoticeMotion.duration, 0.2, "As short as the island's other cards.")
    }

    func testTheIslandCountsTheStandardFiveSecondsUnlessATestSaysOtherwise() {
        XCTAssertEqual(EnvironmentValues().noticeDuration, 5)
        XCTAssertEqual(EnvironmentValues().noticeDuration, NoticeCountdown.standard)
    }
}

/// The card in windows: where it stands, what it does with the clock and with clicks.
@MainActor
final class NoticeToastTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    // MARK: Setup

    private func model(neck: CGFloat = 32) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-notice-\(UUID().uuidString)")!)
        model.neckWithoutWindow = neck
        model.islandContentVisible = true
        return model
    }

    @discardableResult
    private func claudeSession(_ model: AppModel, text: String? = nil) -> TerminalSession {
        let screen = text ?? ["> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", rule, "❯ ", rule].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: screen)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// A window the screen never shows (borderless, so it cannot take the keyboard either), in front so that SwiftUI draws and times as it does on screen.
    private func show<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)
        // SwiftUI builds its accessibility nodes only when assistive technology is on, and a lookup tells the app it is (see `AccessibilityLookup`); once
        // is enough, so that the lookups below need not wait.
        _ = AccessibilityLookup.center(of: "Aviso", in: window)
        wait(0.25)
        return window
    }

    private func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func layer(_ model: AppModel, duration: TimeInterval, look: NoticeToastLook = .resting) -> NSWindow {
        show(NoticeToastLayer(model: model, area: nil, look: look).environment(\.noticeDuration, duration).background(Color.black), size: NSSize(width: 560, height: 220))
    }

    /// Where the element with this accessibility label stands in the window, from its top left; nil when there is none.
    private func frame(of label: String, in window: NSWindow) -> CGRect? {
        func search(_ element: AnyObject) -> NSRect? {
            guard let node = element as? NSObject else { return nil }
            if node.value(forKey: "accessibilityLabel") as? String == label, let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, frame != .zero { return frame }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        guard let host = window.contentView else { return nil }
        for child in host.accessibilityChildren() ?? [] {
            if let screen = search(child as AnyObject) {
                let inWindow = window.convertFromScreen(screen)
                return CGRect(x: inWindow.minX, y: host.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            }
        }
        return nil
    }

    private func shows(_ window: NSWindow) -> Bool { frame(of: "Cerrar aviso", in: window) != nil }

    private func click(_ window: NSWindow, on label: String) throws {
        let frame = try XCTUnwrap(self.frame(of: label, in: window), label)
        let location = NSPoint(x: frame.midX, y: window.contentView!.bounds.height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        wait(0.3)
    }

    private let plain = "No hay ninguna imagen en el portapapeles."
    private let aboutPermission = "Activa Nook en Privacidad y seguridad → Accesibilidad, una sola vez. Si ya aparecía activado, Nook se registró de nuevo y lo verás apagado."

    // MARK: Time

    func testANoticeShowsAndGoesByItself() {
        let model = model()
        let window = layer(model, duration: 1)
        XCTAssertFalse(shows(window), "Nothing to say, nothing shown.")
        model.notice = plain
        wait(0.3)
        XCTAssertTrue(shows(window))
        XCTAssertEqual(model.notice, plain, "Still there a third of the way through.")
        wait(1.3)
        XCTAssertNil(model.notice, "Its time is up: the notice is closed, not just hidden.")
        XCTAssertFalse(shows(window))
    }

    func testADifferentNoticeGetsTheWholeOfItsOwnTime() {
        let model = model()
        let window = layer(model, duration: 1)
        model.notice = "Primero."
        wait(0.6)
        model.notice = "Segundo."
        wait(0.7)
        // The first one's time ran out at 1.0 s; the second one began at 0.6 s.
        XCTAssertEqual(model.notice, "Segundo.", "The first card's end did not close the second notice.")
        XCTAssertTrue(shows(window))
        wait(1.2)
        XCTAssertNil(model.notice, "The second one ended a whole second after it came.")
    }

    func testTheSameTextSetAgainWhileItShowsDoesNotStartItOver() {
        let model = model()
        _ = layer(model, duration: 1)
        model.notice = plain
        wait(0.6)
        model.notice = plain
        wait(0.7)
        XCTAssertNil(model.notice, "It is the same notice: it ends when the first one's time does.")
    }

    func testAnErrorThatKeepsRepeatingComesBackAfterItEnds() {
        // The terminal bridge says its error again on every failed read; the notice goes at its time and the next one brings it back, as a card of its own.
        let model = model()
        let window = layer(model, duration: 0.6)
        model.notice = "Terminal no respondió."
        wait(1.1)
        XCTAssertNil(model.notice)
        XCTAssertFalse(shows(window))
        model.notice = "Terminal no respondió."
        wait(0.4)
        XCTAssertTrue(shows(window))
        XCTAssertEqual(model.notice, "Terminal no respondió.")
    }

    func testThePointerOnTheCardHoldsItsTime() {
        let model = model()
        let window = layer(model, duration: 0.5, look: .hovered)
        model.notice = aboutPermission
        wait(1.6)
        XCTAssertEqual(model.notice, aboutPermission, "Three times its time has passed with the pointer on it: it is still there to read.")
        XCTAssertTrue(shows(window))
    }

    func testANoticeSetWithTheIslandOutOfSightOrBehindTheSheetCountsOnlyOnceItCanBeSeen() {
        for (name, hide, reveal) in [("island out of sight", { (m: AppModel) in m.islandContentVisible = false }, { (m: AppModel) in m.islandContentVisible = true }),
                                     ("connection sheet", { (m: AppModel) in m.connectionSheet = true }, { (m: AppModel) in m.connectionSheet = false })] as [(String, (AppModel) -> Void, (AppModel) -> Void)] {
            let model = model()
            hide(model)
            _ = layer(model, duration: 0.5)
            model.notice = plain
            wait(1.3)
            XCTAssertEqual(model.notice, plain, "\(name): nobody could see it, so none of its time went.")
            reveal(model)
            wait(0.3)
            XCTAssertEqual(model.notice, plain, "\(name): it has its time from the moment it can be seen.")
            wait(0.9)
            XCTAssertNil(model.notice, "\(name): and it goes when that time is up.")
        }
    }

    func testTheRingRunsDownWhileItShows() throws {
        let model = model()
        let window = layer(model, duration: 1.6)
        model.notice = plain
        wait(0.25)
        let ring = try XCTUnwrap(frame(of: "Cerrar aviso", in: window))
        func mint() -> Int { Self.mintPixels(in: window, over: ring) }
        let early = mint()
        wait(0.6)
        let middle = mint()
        wait(0.6)
        let late = mint()
        XCTAssertGreaterThan(early, 20, "The ring starts nearly whole.")
        XCTAssertLessThan(middle, early, "It goes down as time does.")
        XCTAssertLessThan(late, middle)
    }

    func testTheRingStopsWhereItIsWhileThePointerHoldsIt() throws {
        let model = model()
        let window = layer(model, duration: 1.6, look: .hovered)
        model.notice = plain
        wait(0.3)
        let ring = try XCTUnwrap(frame(of: "Cerrar aviso", in: window))
        let first = Self.mintPixels(in: window, over: ring)
        wait(0.9)
        let later = Self.mintPixels(in: window, over: ring)
        XCTAssertGreaterThan(first, 20)
        XCTAssertEqual(first, later, "Held: the ring does not move.")
    }

    /// How many pixels of the island's mint (the arc) are in `area` of the window, counted on a fresh drawing of it.
    private static func mintPixels(in window: NSWindow, over area: CGRect) -> Int {
        guard let host = window.contentView, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        var count = 0
        for x in Int(area.minX * scale)..<Int(area.maxX * scale) {
            for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // Mint is (0.32, 0.73, 0.61), and half of it over the card's grey (0.13) is about (0.23, 0.43, 0.37): more green than red, where the card, the track
                // and the ✕ are grey.
                if color.greenComponent > 0.3, color.greenComponent - color.redComponent > 0.12 { count += 1 }
            }
        }
        return count
    }

    // MARK: Closing

    func testTheXClosesTheNotice() throws {
        let model = model()
        let window = layer(model, duration: 30)
        model.notice = plain
        wait(0.3)
        try click(window, on: "Cerrar aviso")
        XCTAssertNil(model.notice)
        wait(0.3)
        XCTAssertFalse(shows(window))
    }

    func testTheXIsATargetOfAtLeast24Points() throws {
        let model = model()
        let window = layer(model, duration: 30)
        model.notice = plain
        wait(0.3)
        let target = try XCTUnwrap(frame(of: "Cerrar aviso", in: window))
        XCTAssertGreaterThanOrEqual(target.width, 24 - 0.5, "The old ✕ was a 9 pt glyph.")
        XCTAssertGreaterThanOrEqual(target.height, 24 - 0.5)
    }

    func testANoticeAboutAPermissionOffersThePermisosTabAndClosingItThroughThere() throws {
        let model = model()
        let window = layer(model, duration: 30)
        model.notice = aboutPermission
        wait(0.3)
        XCTAssertNotNil(frame(of: "Ver permisos", in: window))
        try click(window, on: "Ver permisos")
        XCTAssertNil(model.notice, "Going to the permissions closes the notice, as it always did.")
    }

    func testAPlainNoticeOffersNoWayToThePermissions() {
        let model = model()
        let window = layer(model, duration: 30)
        model.notice = plain
        wait(0.3)
        XCTAssertNil(frame(of: "Ver permisos", in: window))
    }

    // MARK: Clicks

    func testOnlyTheCardTakesClicksAndEverythingElseUnderTheLayerKeepsThem() throws {
        final class Counts { var corner = 0, underCard = 0 }
        let counts = Counts()
        let model = model()
        // Two buttons under the layer: one in a corner, far from the card, and one exactly where the card hangs (at the top, a margin down).
        let view = ZStack {
            Color.black
            Button { counts.corner += 1 } label: { Color.blue.frame(width: 60, height: 30) }.buttonStyle(.plain).position(x: 50, y: 30)
            Button { counts.underCard += 1 } label: { Color.red.frame(width: 120, height: 30) }.buttonStyle(.plain).position(x: 280, y: 25)
            NoticeToastLayer(model: model, area: nil).environment(\.noticeDuration, 30)
        }.frame(width: 560, height: 220)
        let window = show(view, size: NSSize(width: 560, height: 220))
        func clickAt(_ point: NSPoint) {
            let location = NSPoint(x: point.x, y: 220 - point.y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            wait(0.15)
        }
        clickAt(NSPoint(x: 50, y: 30))
        clickAt(NSPoint(x: 280, y: 25))
        XCTAssertEqual(counts.corner, 1, "With no notice the layer is not there for clicks.")
        XCTAssertEqual(counts.underCard, 1)
        model.notice = plain
        wait(0.3)
        clickAt(NSPoint(x: 50, y: 30))
        XCTAssertEqual(counts.corner, 2, "With a notice up, what is away from the card still gets its clicks.")
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        XCTAssertTrue(card.contains(NSPoint(x: 280, y: 25)), "The second button is under the card.")
        clickAt(NSPoint(x: card.minX + 8, y: card.midY))
        XCTAssertEqual(counts.underCard, 1, "A click on the card is the card's: it does not reach the button under it.")
        XCTAssertNotNil(model.notice, "And a click on its words does not close it.")
    }

    // MARK: The card's measures

    func testAShortNoticeIsAsWideAsItsWordsAndALongOneWrapsAtTheCap() {
        let short = NSHostingView(rootView: NoticeToast(text: plain).environment(\.colorScheme, .dark)).fittingSize
        let long = NSHostingView(rootView: NoticeToast(text: String(repeating: "Un aviso largo que se corta en varias líneas. ", count: 6)).environment(\.colorScheme, .dark)).fittingSize
        XCTAssertLessThan(short.width, 360, "Compact: as wide as its words, not the whole conversation. \(short)")
        XCTAssertGreaterThan(short.width, 200)
        XCTAssertEqual(long.width, NoticeMetrics.maxWidth, accuracy: 24, "Wrapped at its cap, not wider. \(long)")
        XCTAssertLessThanOrEqual(long.width, NoticeMetrics.maxWidth + 0.5)
        XCTAssertGreaterThan(long.height, short.height + 30, "More words, more lines.")
        XCTAssertEqual(short.height, 38, accuracy: 2, "One line: the ring's row and the padding round it.")
    }

    func testTheCardNeverTakesMoreHeightThanItIsGivenAndScrollsItsWordsInstead() throws {
        let words = String(repeating: "Un aviso largo que se corta en varias líneas. ", count: 8)
        let window = show(NoticeToast(text: words, maxHeight: 52, onClose: {}).padding(20).frame(width: 520, height: 120), size: NSSize(width: 520, height: 120))
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        XCTAssertEqual(card.height, 52, accuracy: 1.5, "As tall as the room it was given, and no more.")
        XCTAssertNotNil(frame(of: "Cerrar aviso", in: window), "The ✕ stays where it is while the words scroll.")
    }

    func testTheWayToThePermissionsIsAlwaysInViewWhateverTheRoomTheCardHas() throws {
        // A notice about a permission, in rooms from the Normal island's down to the smallest: the words give way, the button does not.
        for height in [140.0, 90, 64, 52, 48] as [CGFloat] {
            let window = show(NoticeToast(text: aboutPermission, maxHeight: height, onClose: {}).padding(20).frame(width: 520, height: 180), size: NSSize(width: 520, height: 180))
            let card = try XCTUnwrap(frame(of: "Aviso", in: window), "height \(height)")
            let button = try XCTUnwrap(frame(of: "Ver permisos", in: window), "height \(height): the way to the Permisos tab")
            XCTAssertLessThanOrEqual(card.height, height + 0.5, "height \(height): the card takes no more than it is given. \(card)")
            XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(button), "height \(height): the button is on the card, not scrolled out of it. card \(card), button \(button)")
            let close = try XCTUnwrap(frame(of: "Cerrar aviso", in: window))
            XCTAssertFalse(close.intersects(button), "height \(height): and not under the ✕. \(close), \(button)")
        }
    }

    // MARK: Where it stands

    /// The island as the app lays it out, with a Claude conversation, and what the card does there.
    private func island(_ model: AppModel, duration: TimeInterval = 30) -> (NSWindow, NSSize) {
        let size = model.islandSize
        return (show(NookPanel(model: model).environment(\.noticeDuration, duration), size: size), size)
    }

    func testTheCardHangsFromTheTopOfTheChatAreaCentredAcrossItAndAboveTheComposer() throws {
        let model = model()
        claudeSession(model)
        model.notice = plain
        let (window, size) = island(model)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        let host = try XCTUnwrap(window.contentView)
        let composer = try XCTUnwrap(Self.descendants(of: host, as: ComposerFieldView.self).first)
        let composerTop = size.height - composer.convert(composer.bounds, to: nil).maxY
        let paneTop = model.neckHeight + PaneLayout.tabRowHeight
        XCTAssertEqual(card.midX, size.width / 2, accuracy: 1.5, "Centred across the island.")
        XCTAssertEqual(card.minY, paneTop + NoticeMetrics.margin, accuracy: 1.5, "Hanging from the top of the chat area, the island's 6 pt under the tabs. \(card)")
        XCTAssertLessThanOrEqual(card.maxY, composerTop - ComposerMetrics.topPadding, "Not over the composer. \(card), composer top \(composerTop)")
        XCTAssertLessThan(card.midY, paneTop + (composerTop - paneTop) / 2, "In the upper half of the chat, not in the middle of it. \(card)")
        XCTAssertLessThan(card.width, size.width - 120, "A compact card over the text, not a full-width banner.")
    }

    func testTheCardStaysOffTheComposerAndTheTabsInTheSmallestIslandWhateverItSays() throws {
        let model = model()
        var smallest = DisplaySettings(); smallest.widthExtra = -140; smallest.heightExtra = -80
        model.display = smallest
        claudeSession(model)
        model.notice = String(repeating: "Un aviso largo que se corta en varias líneas. ", count: 8)
        let (window, size) = island(model)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        let host = try XCTUnwrap(window.contentView)
        let composer = try XCTUnwrap(Self.descendants(of: host, as: ComposerFieldView.self).first)
        let composerTop = size.height - composer.convert(composer.bounds, to: nil).maxY
        XCTAssertEqual(card.minY, model.neckHeight + PaneLayout.tabRowHeight + NoticeMetrics.margin, accuracy: 1.5, "Hanging from the top of the chat area. \(card)")
        XCTAssertLessThanOrEqual(card.maxY, composerTop - ComposerMetrics.topPadding + 0.5, "Not over the composer. \(card), composer top \(composerTop)")
        XCTAssertNotNil(frame(of: "Cerrar aviso", in: window), "And the ✕ is still on it.")
    }

    func testInTheCompactIslandTheWayToThePermissionsStaysOnTheCardAboveTheComposer() throws {
        let model = model()
        model.display = DisplaySettings().applying(.compact)
        claudeSession(model)
        model.notice = aboutPermission
        let (window, size) = island(model)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        let button = try XCTUnwrap(frame(of: "Ver permisos", in: window))
        let host = try XCTUnwrap(window.contentView)
        let composer = try XCTUnwrap(Self.descendants(of: host, as: ComposerFieldView.self).first)
        let composerTop = size.height - composer.convert(composer.bounds, to: nil).maxY
        XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(button), "card \(card), button \(button)")
        XCTAssertLessThanOrEqual(card.maxY, composerTop - ComposerMetrics.topPadding + 0.5, "Not over the composer. \(card), composer top \(composerTop)")
        XCTAssertGreaterThanOrEqual(card.minY, model.neckHeight + PaneLayout.tabRowHeight, "Not over the tabs. \(card)")
    }

    func testWhenAQuestionsCardTakesThePaneTheCardHangsFromUnderItsBarAndNotOverTheTabs() throws {
        // Nine options leave the conversation no room: the question's card has the whole pane.
        let many = (["⏺ Elige el modelo.", "", " Select model", "   Switch between Claude models."] + (1...9).map { ($0 == 2 ? " ❯ " : "   ") + "\($0). Opción número \($0) del selector" }).joined(separator: "\n")
        let model = model()
        let session = claudeSession(model, text: many)
        XCTAssertNotNil(session.prompt)
        model.notice = plain
        let (window, size) = island(model)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        let cancel = try XCTUnwrap(frame(of: "Cancelar la pregunta", in: window), "The card's «Cancelar» is on show.")
        let paneTop = model.neckHeight + PaneLayout.tabRowHeight
        XCTAssertGreaterThanOrEqual(card.minY, paneTop + 2, "Not over the tabs. \(card)")
        XCTAssertLessThanOrEqual(card.maxY, size.height - ComposerMetrics.bottomInset + 0.5, "Not out of the island. \(card)")
        XCTAssertEqual(card.midX, size.width / 2, accuracy: 1.5)
        // It hangs from under the question's bar (the question and «Cancelar» on its first row), a margin down, and covers neither.
        XCTAssertGreaterThanOrEqual(card.minY, cancel.maxY + NoticeMetrics.margin - 4, "Under the question's bar. \(card), «Cancelar» \(cancel)")
        XCTAssertFalse(card.intersects(cancel), "«Cancelar» stays in reach. \(card), \(cancel)")
        XCTAssertLessThan(card.minY, paneTop + 2 + AgentPromptCard.headerHeight + 3 * NoticeMetrics.margin + 12, "And near the top of the card, not in the middle of it. \(card)")
    }

    func testTheWelcomeGetsItAtTheTopOfItsContentCentredAcrossIt() throws {
        let model = model()
        model.notice = plain
        let (window, size) = island(model)
        XCTAssertTrue(model.sessions.isEmpty)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window))
        XCTAssertEqual(card.midX, size.width / 2, accuracy: 1.5)
        XCTAssertEqual(card.minY, model.neckHeight + NoticeMetrics.margin, accuracy: 1.5, "A margin under the header, which it never covers. \(card)")
    }

    func testWhileClaudesPanelTakesThePaneTheCardHangsFromUnderItsToolbar() throws {
        let model = model()
        let session = claudeSession(model, text: "> /usage\n\n" + ClaudePanelFixtures.usage)
        XCTAssertNotNil(session.panel)
        model.notice = plain
        let (window, size) = island(model)
        let card = try XCTUnwrap(frame(of: "Aviso", in: window), "The panel is on show, and so is the notice.")
        let close = try XCTUnwrap(frame(of: "Cerrar el panel", in: window), "The panel's toolbar is on show.")
        let paneTop = model.neckHeight + PaneLayout.tabRowHeight
        XCTAssertEqual(card.midX, size.width / 2, accuracy: 1.5)
        // The pane's 2 pt of air, the toolbar, and the island's gap under it.
        XCTAssertEqual(card.minY, paneTop + 2 + ClaudePanelCard.toolbarHeight + NoticeMetrics.margin, accuracy: 1.5, "\(card)")
        XCTAssertGreaterThanOrEqual(card.minY, close.maxY, "The panel's «Cerrar» is not covered. \(card), \(close)")
        XCTAssertLessThanOrEqual(card.maxY, size.height - ComposerMetrics.bottomInset, "Within the panel.")
    }

    // MARK: Under a bar

    private func agent(_ id: String = "call-run") -> SubagentActivity {
        SubagentActivity(id: id, name: "Diseñar el gato", kind: "general-purpose", state: .running, background: true, toolUses: 12, tokens: "30k", duration: "2m 8s")
    }

    private func shell(_ id: String = "bdev00001") -> ShellActivity {
        ShellActivity(id: id, name: "Dev server", command: "pnpm dev", state: .running, exitCode: nil, note: nil, movedToBackground: false, started: Date().addingTimeInterval(-65),
                      outputPath: "/private/tmp/claude-501/-Users-me-app/s/tasks/x.output")
    }

    /// A Claude session that knows these agents and shells, as the record would tell it, with the island showing it.
    private func claudeSessionKnowing(_ model: AppModel, agents: [SubagentActivity] = [], shells: [ShellActivity] = []) -> TerminalSession {
        // Nothing here may reach for Terminal or go looking for Claude's record on disk.
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.loginStampsReader = { [:] }
        var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys240", customTitle: "", processes: ["claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on · ↓ to manage"].joined(separator: "\n"))
        tab.history = true
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.transcriptLocated = Date()
        session.applyTranscript("> pregunta\n\n⏺ respuesta\n\n", recap: nil, agents: agents, shells: shells)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// The island with the notice, and with an agent's conversation or a shell's output on show; the card and the bar's way back, as they stand.
    private func underABar(_ viewing: String, settings: DisplaySettings = DisplaySettings(), notice: String? = nil) throws -> (card: CGRect, back: CGRect, composer: CGRect, size: NSSize, model: AppModel) {
        let model = model()
        model.display = settings
        if viewing == "agent" {
            let working = agent()
            let session = claudeSessionKnowing(model, agents: [working])
            model.openAgent(working, in: session)
            XCTAssertEqual(session.viewedAgent, working.id)
        } else {
            let running = shell()
            let session = claudeSessionKnowing(model, shells: [running])
            model.openShell(running, in: session)
            session.applyShellOutput(ShellOutput(text: "ready on :3000\nGET / 200\n"), id: running.id)
            XCTAssertEqual(session.viewedShell, running.id)
        }
        model.notice = notice ?? plain
        let (window, size) = island(model)
        let host = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(Self.descendants(of: host, as: ComposerFieldView.self).first)
        let fieldFrame = field.convert(field.bounds, to: nil)
        return (try XCTUnwrap(frame(of: "Aviso", in: window), viewing), try XCTUnwrap(frame(of: "Volver a Claude", in: window), "The bar's way back is on show."),
                CGRect(x: fieldFrame.minX, y: size.height - fieldFrame.maxY, width: fieldFrame.width, height: fieldFrame.height), size, model)
    }

    func testUnderTheBarOfAnAgentsConversationAndOfAShellsOutputTheCardHangsJustBelowItAndLeavesTheWayBackInView() throws {
        for viewing in ["agent", "shell"] {
            let (card, back, _, size, model) = try underABar(viewing)
            let paneTop = model.neckHeight + PaneLayout.tabRowHeight
            XCTAssertEqual(card.midX, size.width / 2, accuracy: 1.5, "\(viewing): still centred across the island.")
            XCTAssertEqual(card.minY, paneTop + NoticeMetrics.viewBar + NoticeMetrics.margin, accuracy: 1.5, "\(viewing): hanging from the bar's lower edge, the island's gap under it. \(card)")
            XCTAssertGreaterThanOrEqual(card.minY, back.maxY + 2, "\(viewing): under the way back, not over it. card \(card), button \(back)")
            XCTAssertFalse(card.intersects(back), "\(viewing)")
        }
    }

    func testTheNoticeOverAShellsOutputStandsWhereItDoesOverAnAgentsConversation() throws {
        let agent = try underABar("agent"), shell = try underABar("shell")
        XCTAssertEqual(shell.card.minY, agent.card.minY, accuracy: 0.5, "Both bars are the same height, and the card hangs from the same place under either.")
        XCTAssertEqual(shell.card.midX, agent.card.midX, accuracy: 0.5)
    }

    func testInTheCompactIslandUnderABarTheCardKeepsToTheRoomThereIsAndTheWayToThePermissions() throws {
        let (card, back, composer, size, model) = try underABar("shell", settings: DisplaySettings().applying(.compact), notice: aboutPermission)
        XCTAssertGreaterThanOrEqual(card.minY, back.maxY + 2, "Under the bar. \(card), \(back)")
        XCTAssertLessThanOrEqual(card.maxY, composer.minY - ComposerMetrics.topPadding + 0.5, "Not over the composer. \(card), field \(composer)")
        XCTAssertGreaterThanOrEqual(card.minY, model.neckHeight + PaneLayout.tabRowHeight, "Not over the tabs.")
        XCTAssertLessThan(card.width, size.width)
    }

    func testInTheSmallestIslandUnderABarTheCardKeepsItsLineAndNeverReachesTheMessageField() throws {
        var smallest = DisplaySettings(); smallest.widthExtra = -140; smallest.heightExtra = -80
        for viewing in ["agent", "shell"] {
            let (card, back, composer, _, _) = try underABar(viewing, settings: smallest)
            XCTAssertGreaterThanOrEqual(card.minY, back.maxY + 2, "\(viewing): under the bar. \(card), \(back)")
            XCTAssertGreaterThanOrEqual(card.height, NoticeMetrics.minHeight - 0.5, "\(viewing): a whole line, never less. \(card)")
            // What little room the bar leaves (the gap above the composer, and the empty band at its top) is all it may use: never the field's own place.
            XCTAssertLessThanOrEqual(card.maxY, composer.minY + 0.5, "\(viewing): not over the message field. \(card), field \(composer)")
        }
    }

    /// How much of the card shows (the red of a point on its left padding, 0 for the island's black and about 0.16 for the card), sampled for a third of a
    /// second after `change`.
    private func levels(animations: Bool, after change: (AppModel) -> Void, startingWith notice: String?) throws -> [Double] {
        let model = model()
        model.animations = animations
        model.notice = notice
        let window = layer(model, duration: 30)
        let card = notice == nil ? nil : try XCTUnwrap(frame(of: "Aviso", in: window))
        let host = try XCTUnwrap(window.contentView)
        // The card as it will stand: the same place whichever way the sampling goes.
        let probe = card ?? CGRect(x: 133, y: NoticeMetrics.margin, width: 294, height: 38)
        func level() -> Double {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            return Double(rep.colorAt(x: Int((probe.minX + 5) * scale), y: Int(probe.midY * scale))?.usingColorSpace(.deviceRGB)?.redComponent ?? -1)
        }
        change(model)
        var seen: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 0.35 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            seen.append(level())
        }
        return seen
    }

    func testTheCardFadesInAndOutWithMotionAndJustComesAndGoesWithout() throws {
        let card = 0.16
        func between(_ levels: [Double]) -> Bool { levels.contains { $0 > 0.005 && $0 < card - 0.03 } }
        /// The fade lasts 0.16 s on the wall clock, and every sample is a full off-screen redraw: under load the samples can be further apart than the
        /// fade, so none lands in between. That says nothing about the card, so the animated half takes a few runs and needs one to have been seen mid-fade.
        func fade(after change: @escaping (AppModel) -> Void, startingWith notice: String?) throws -> [Double] {
            var last: [Double] = []
            for _ in 0..<5 {
                last = try levels(animations: true, after: change, startingWith: notice)
                if between(last) { break }
            }
            return last
        }
        // Going: a fade through the levels in between, down to nothing; or, with the animations off, from the card to the black with nothing between.
        let fadingOut = try fade(after: { $0.notice = nil }, startingWith: plain)
        XCTAssertTrue(between(fadingOut), "Seen: \(fadingOut)")
        XCTAssertEqual(fadingOut.last ?? -1, 0, accuracy: 0.005)
        XCTAssertEqual(fadingOut, fadingOut.sorted(by: >), "It only fades.")
        let goneAtOnce = try levels(animations: false, after: { $0.notice = nil }, startingWith: plain)
        XCTAssertFalse(between(goneAtOnce), "Seen: \(goneAtOnce)")
        XCTAssertEqual(goneAtOnce.last ?? -1, 0, accuracy: 0.005)
        // Coming: the same, the other way.
        let fadingIn = try fade(after: { $0.notice = self.plain }, startingWith: nil)
        XCTAssertTrue(between(fadingIn), "Seen: \(fadingIn)")
        XCTAssertEqual(fadingIn.last ?? -1, card, accuracy: 0.02)
        let comesAtOnce = try levels(animations: false, after: { $0.notice = self.plain }, startingWith: nil)
        XCTAssertFalse(between(comesAtOnce), "Seen: \(comesAtOnce)")
        XCTAssertEqual(comesAtOnce.last ?? -1, card, accuracy: 0.02)
    }

    func testTheCardComesBackOverTheSessionWhenTheTabChanges() throws {
        let model = model()
        claudeSession(model)
        model.notice = plain
        let (window, _) = island(model, duration: 30)
        let first = try XCTUnwrap(frame(of: "Aviso", in: window))
        // Another tab: the pane is rebuilt for it, and the notice (which is the island's, not the tab's) is still there, in the same place.
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 2, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: false, text: "⏺ Otra pestaña.")
        let other = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions.append(other)
        model.select(other)
        wait(0.5)
        let second = try XCTUnwrap(frame(of: "Aviso", in: window))
        XCTAssertEqual(second.midX, first.midX, accuracy: 1.5)
        XCTAssertEqual(second.midY, first.midY, accuracy: 3)
    }

    // MARK: Helpers

    private static func descendants<V: NSView>(of root: NSView, as type: V.Type) -> [V] {
        var found: [V] = []
        func visit(_ view: NSView) { if let match = view as? V { found.append(match) }; view.subviews.forEach(visit) }
        visit(root)
        return found
    }
}

/// The card and its ring as images, for looking at. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class NoticeToastRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the notice.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private var conversation: String {
        let turns = (1...5).flatMap { n in
            ["> Pregunta número \(n): ¿puedes revisar cómo se ve el espejo cuando hay mucha conversación?", "",
             "⏺ Respuesta \(n). El texto se ajusta al ancho del panel y el espejo sigue la salida más reciente mientras no te desplaces.", "",
             "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", ""]
        }.joined(separator: "\n")
        return turns + "\n" + ["⏺ Listo: el tamaño de la isla y del texto ahora se ajustan desde los ajustes.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    private static let plain = "No hay ninguna imagen en el portapapeles."
    private static let permission = "Activa Nook en Privacidad y seguridad → Accesibilidad, una sola vez. Si ya aparecía activado, Nook se registró de nuevo y lo verás apagado."
    private static let long = "Claude tiene una pregunta abierta: lo que envíes no se escribiría en ella y el Enter podría responderla sin querer. Elige una opción (botón «Opciones»), o pulsa Enter otra vez para enviar de todos modos."

    /// The island as the app lays it out, with the notice that is asked for. The countdown is long, so what is drawn is a card that has just come.
    private func island(_ name: String, settings: DisplaySettings = DisplaySettings(), notice: String?, sessions: Bool = true, to directory: String) throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
        model.neckWithoutWindow = 32
        model.display = settings
        if sessions {
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: conversation)
            let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true
            model.updateActivity()
        }
        model.islandContentVisible = true
        model.notice = notice
        let size = model.islandSize
        let view = NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.noticeDuration, 600)
        try write(NSHostingView(rootView: view), size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-\(name).png").path)
    }

    func testRenderTheNoticeInTheIsland() throws {
        let directory = try renderDirectory()
        try island("plain", notice: Self.plain, to: directory)
        try island("permission", notice: Self.permission, to: directory)
        try island("long", notice: Self.long, to: directory)
        try island("none", notice: nil, to: directory)
        try island("welcome", notice: Self.plain, sessions: false, to: directory)
        try island("welcome-permission", notice: Self.permission, sessions: false, to: directory)
    }

    func testRenderTheNoticeInTheCompactAndTheSmallestIsland() throws {
        let directory = try renderDirectory()
        let compact = DisplaySettings().applying(.compact)
        var smallest = DisplaySettings(); smallest.widthExtra = -140; smallest.heightExtra = -80
        for (name, settings) in [("compact", compact), ("smallest", smallest)] {
            try island("\(name)-plain", settings: settings, notice: Self.plain, to: directory)
            try island("\(name)-permission", settings: settings, notice: Self.permission, to: directory)
            try island("\(name)-long", settings: settings, notice: Self.long, to: directory)
        }
        try island("wide-long", settings: DisplaySettings().applying(.wide), notice: Self.long, to: directory)
        try island("tall-permission", settings: DisplaySettings().applying(.tall), notice: Self.permission, to: directory)
    }

    /// A question's card takes the composer's place (or, with many options, the whole pane): the notice still stands over what is above it.
    func testRenderTheNoticeBesideAQuestionsCard() throws {
        let directory = try renderDirectory()
        let permission = ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
                          " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        let many = (["⏺ Elige el modelo.", "", " Select model", "   Switch between Claude models."] + (1...9).map { ($0 == 2 ? " ❯ " : "   ") + "\($0). Opción número \($0) del selector" }).joined(separator: "\n")
        for (name, text, settings) in [("question", permission, DisplaySettings()), ("question-compact", permission, DisplaySettings().applying(.compact)), ("question-many", many, DisplaySettings())] {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
            model.neckWithoutWindow = 32
            model.display = settings
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
            let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true; model.islandContentVisible = true
            model.updateActivity()
            XCTAssertNotNil(session.prompt, name)
            model.notice = Self.plain
            let size = model.islandSize
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.noticeDuration, 600))
            try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-\(name).png").path)
        }
    }

    /// An agent's conversation or a shell's output on show, under its bar, and the notice hanging from under that.
    func testRenderTheNoticeUnderTheBarOfAnAgentOrAShell() throws {
        let directory = try renderDirectory()
        var smallest = DisplaySettings(); smallest.widthExtra = -140; smallest.heightExtra = -80
        // What Claude's record says, which is what the mirror shows under the bar of an agent's conversation or beside a shell's output.
        let transcript = (1...5).flatMap { n in
            ["> Pregunta número \(n): ¿puedes revisar cómo se ve el espejo cuando hay mucha conversación?", "",
             "⏺ Respuesta \(n). El texto se ajusta al ancho del panel y el espejo sigue la salida más reciente mientras no te desplaces.", "",
             "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", ""]
        }.joined(separator: "\n")
        let output = ["> sampleapp-web@0.1.0 dev /Users/me/sampleapp-web", "> next dev -p 3000", "", "   ▲ Next.js 15.1.0", "   - Local:        http://localhost:3000", "",
                      " ✓ Starting...", " ✓ Ready in 1.8s", " GET / 200 in 412ms", " GET /api/stars 200 in 38ms"].joined(separator: "\n") + "\n"
        for (name, viewing, settings, notice) in [("agent", "agent", DisplaySettings(), Self.plain), ("shell", "shell", DisplaySettings(), Self.plain),
                                                  ("shell-permission", "shell", DisplaySettings(), Self.permission),
                                                  ("compact-shell-permission", "shell", DisplaySettings().applying(.compact), Self.permission),
                                                  ("smallest-shell", "shell", smallest, Self.plain), ("smallest-agent-long", "agent", smallest, Self.long)] {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
            model.neckWithoutWindow = 32
            model.display = settings
            model.terminalBridge.runScript = { _ in }
            model.terminalBridge.loginStampsReader = { [:] }
            let working = SubagentActivity(id: "call-run", name: "Diseñar las animaciones del gato", kind: "general-purpose", state: .running, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s")
            let running = ShellActivity(id: "bdev00001", name: "Servidor de desarrollo", command: "pnpm dev", state: .running, exitCode: nil, note: nil, movedToBackground: false,
                                        started: Date().addingTimeInterval(-192), outputPath: "/private/tmp/claude-501/-Users-me-app/s/tasks/x.output")
            var tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys240", customTitle: "claude", processes: ["claude"], busy: false, selected: true,
                                          text: ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on · ↓ to manage"].joined(separator: "\n"))
            tab.history = true
            let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            session.transcriptLocated = Date()
            session.applyTranscript(transcript, recap: nil, agents: [working], shells: [running])
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true; model.islandContentVisible = true
            model.updateActivity()
            if viewing == "agent" { model.openAgent(working, in: session) } else {
                model.openShell(running, in: session)
                session.applyShellOutput(ShellOutput(text: output), id: running.id)
            }
            model.notice = notice
            let size = model.islandSize
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.noticeDuration, 600))
            try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-under-\(name).png").path)
        }
    }

    func testRenderTheNoticeOverClaudesPanel() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
        model.neckWithoutWindow = 32
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: "> /usage\n\n" + ClaudePanelFixtures.usage)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNotNil(session.panel)
        model.notice = Self.permission
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.noticeDuration, 600))
        try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-panel.png").path)
    }

    /// The card alone on the island's black, at each look, and the ring from full to empty.
    func testRenderTheCardAndItsRing() throws {
        let directory = try renderDirectory()
        let t0 = Date().addingTimeInterval(-10)
        /// A countdown that has `left` of its 5 seconds, stopped there (the island out of sight), so it does not move while it is drawn.
        func countdown(left: Double, hovering: Bool = false) -> NoticeCountdown {
            var value = NoticeCountdown(now: t0)
            value.setOnScreen(false, now: t0.addingTimeInterval(5 - left))
            if hovering { value.setHovering(true, now: t0.addingTimeInterval(5 - left)) }
            return value
        }
        let strip = VStack(spacing: 14) {
            ForEach([false, true], id: \.self) { held in
                HStack(spacing: 18) {
                    ForEach([5.0, 4.0, 3.0, 2.0, 1.0, 0.4, 0.0], id: \.self) { left in
                        NoticeCloseButton(countdown: countdown(left: left, hovering: held), stepped: false, action: {})
                    }
                }
            }
        }.padding(24).background(Color(white: 0.13))
        try write(NSHostingView(rootView: strip.environment(\.colorScheme, .dark)), size: NSSize(width: 330, height: 130), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-ring.png").path)

        let cards = VStack(spacing: 16) {
            NoticeToast(text: Self.plain)
            NoticeToast(text: Self.plain, look: .hovered)
            NoticeToast(text: Self.permission)
            NoticeToast(text: Self.long, stepped: true)
        }.padding(24).frame(width: 520).background(Color.black)
        let host = NSHostingView(rootView: cards.environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false))
        try write(host, size: NSSize(width: 520, height: host.fittingSize.height), to: URL(fileURLWithPath: directory).appendingPathComponent("notice-cards.png").path)
    }
}
