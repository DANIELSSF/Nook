import AppKit
import XCTest
@testable import Nook

/// The cat's heartbeat and the views that use it: one retunable timer for the slow ticks (never rebuilt, nothing left behind), the cat
/// dressed as the user chose, and the same still cat when nothing may move.
@MainActor
final class PetTickerTests: XCTestCase {
    private func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Runs the loop until `done` holds or `timeout` passes, and returns the seconds it took. A machine under load (or a test run at
    /// utility priority, whose timers the system coalesces) delivers ticks late, never early, so the tests wait for the ticks they
    /// need instead of counting what fits in a fixed window.
    @discardableResult private func pump(until done: () -> Bool, timeout: Double = 3) -> Double {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < timeout { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return Date().timeIntervalSince(start)
    }

    func testATickerHasNoTimerUntilItIsAskedAndLeavesNoneBehind() {
        var ticks = 0
        let ticker = PetTicker { ticks += 1 }
        XCTAssertEqual(ticker.interval, 0)
        pump(0.15)
        XCTAssertEqual(ticks, 0, "nothing runs before it is asked to")
        ticker.run(every: 0.05)
        XCTAssertEqual(ticker.interval, 0.05)
        let took = pump(until: { ticks >= 5 })
        XCTAssertGreaterThanOrEqual(ticks, 5, "it runs")
        XCTAssertLessThanOrEqual(ticks, Int(took / 0.05 * 1.3) + 2, "and never faster than it was asked to: \(ticks) in \(took) s")
        ticker.stop()
        XCTAssertEqual(ticker.interval, 0)
        let after = ticks
        pump(0.3)
        XCTAssertEqual(ticks, after, "and nothing runs once it is stopped")
        ticker.run(every: 0.05)
        pump(0.2)
        XCTAssertGreaterThan(ticks, after, "it can be started again")
        ticker.stop()
    }

    func testAskingForTheIntervalInForceDoesNothingAndANewOneRetunesTheSameTimer() {
        var ticks = 0
        let ticker = PetTicker { ticks += 1 }
        ticker.run(every: 0.04)
        pump(0.35)
        let fast = ticks
        ticker.run(every: 0.04)
        XCTAssertEqual(ticker.interval, 0.04)
        ticker.run(every: 0.5)
        XCTAssertEqual(ticker.interval, 0.5)
        ticks = 0
        pump(0.45)
        XCTAssertLessThanOrEqual(ticks, 1, "slowed down: it was \(fast) in the time it is now one")
        ticker.run(every: 0.04)
        ticks = 0
        pump(until: { ticks >= 5 })
        XCTAssertGreaterThanOrEqual(ticks, 5, "and quick again")
        ticker.stop()
    }

    func testAPausedTickerTicksNoMoreAndRunsAgainWhenAsked() {
        var ticks = 0
        let ticker = PetTicker { ticks += 1 }
        ticker.pause()
        XCTAssertEqual(ticker.interval, 0, "pausing a ticker that never ran does nothing")
        ticker.run(every: 0.04)
        pump(until: { ticks >= 2 })
        ticker.pause()
        XCTAssertEqual(ticker.interval, 0)
        let paused = ticks
        pump(0.3)
        XCTAssertEqual(ticks, paused, "nothing runs while it is paused")
        ticker.run(every: 0.04)
        XCTAssertEqual(ticker.interval, 0.04)
        pump(until: { ticks >= paused + 2 })
        XCTAssertGreaterThanOrEqual(ticks, paused + 2, "and the same timer runs again")
        ticker.stop()
    }

    func testATickerThatIsLetGoStopsItself() {
        var ticks = 0
        var ticker: PetTicker? = PetTicker { ticks += 1 }
        ticker?.run(every: 0.04)
        pump(until: { ticks > 0 })
        XCTAssertGreaterThan(ticks, 0)
        ticker = nil
        let seen = ticks
        pump(0.3)
        XCTAssertEqual(ticks, seen, "a ticker that is let go leaves no timer running")
    }

    func testTimerTicksCarryNoDisplayTime() {
        var times = [CFTimeInterval?]()
        let ticker = PetTicker(timed: { times.append($0) })
        ticker.run(every: 0.05)
        pump(until: { times.count >= 2 })
        ticker.stop()
        XCTAssertFalse(times.isEmpty); XCTAssertTrue(times.allSatisfy { $0 == nil }, "only a display link knows the time its frame will be seen")
    }

    // MARK: The views

    private func pixels(of view: NSView) throws -> [(r: Int, g: Int, b: Int)] {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var out = [(r: Int, g: Int, b: Int)]()
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            out.append((Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)))
        } }
        return out
    }

    func testTheHeaderCatIsDressedAsTheUserChoseAndRedrawnAtOnce() throws {
        let header = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 164, height: 32))
        header.animated = false
        XCTAssertEqual(header.look, PetLook())
        let white = try pixels(of: header)
        XCTAssertTrue(white.contains { $0.r > 240 && $0.g > 240 && $0.b > 240 }, "a white cat")
        XCTAssertFalse(white.contains { $0.r > $0.b + 60 }, "with nothing orange in it")
        var prefs = PetPreferences(); prefs.coat = .ginger; prefs.accessory = .collar
        header.pet = prefs
        XCTAssertEqual(header.look, PetLook(coat: .ginger, accessory: .collar))
        let ginger = try pixels(of: header)
        XCTAssertTrue(ginger.contains { $0.r > 220 && $0.g > 140 && $0.g < 200 && $0.b < 140 }, "an orange cat")
        XCTAssertTrue(ginger.contains { $0.g > $0.r + 40 }, "with a mint collar")
        XCTAssertFalse(ginger.contains { $0.r > 240 && $0.g > 240 && $0.b > 240 }, "and nothing white left")
        header.pet = PetPreferences()
        XCTAssertEqual(header.look, PetLook())
        XCTAssertEqual(header.frameInterval, 0, "a still cat has no timer, whatever it wears")
    }

    func testTheCollapsedCatFollowsTheModelsLook() throws {
        let defaults = UserDefaults(suiteName: "nook-pet-view-" + UUID().uuidString)!
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        pet.injectedModel = model
        XCTAssertEqual(pet.look, PetLook())
        model.pet.coat = .silver; model.pet.accessory = .bow
        pump(0.15)
        XCTAssertEqual(pet.look, PetLook(coat: .silver, accessory: .bow), "the next time the model changes the view hears it")
        XCTAssertEqual(pet.frameInterval, 0, "and with the animations off there is still no timer")
        let wing = try pixels(of: pet)
        XCTAssertTrue(wing.contains { $0.b > $0.r + 25 && $0.b > 150 }, "a cool grey cat in the wing")
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
    }

    func testTheWingShowsThreeMintDotsWhileClaudeWorksAndNothingWhenItDoesNot() throws {
        let suite = "nook-pet-dots-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        pet.injectedModel = model
        /// The mint pixels in the wing's right side, where the dots wave (the cat's own are white, the island black).
        func mint() throws -> Int {
            let rep = try XCTUnwrap(pet.bitmapImageRepForCachingDisplay(in: pet.bounds))
            pet.cacheDisplay(in: pet.bounds, to: rep)
            var count = 0
            for y in 0..<rep.pixelsHigh { for x in (rep.pixelsWide * 4 / 5)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.greenComponent > 0.5 && c.greenComponent > c.redComponent + 0.2 { count += 1 }
            } }
            return count
        }
        XCTAssertEqual(try mint(), 0, "nothing on the right while Claude is not working")
        model.working = true
        XCTAssertGreaterThan(try mint(), 15, "three dots while it is")
        XCTAssertEqual(pet.frameInterval, 0, "and with the animations off they stand still, with no timer")
        model.working = false
        XCTAssertEqual(try mint(), 0, "and they are gone when it stops")
    }

    func testTheOverlayCatAndTheGhostTakeTheLookToo() throws {
        let icon = CatIconView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        icon.scaleFactor = 1
        icon.look = PetLook(coat: .ginger)
        let image = try pixels(of: icon)
        XCTAssertTrue(image.contains { $0.r > 220 && $0.g > 140 && $0.b < 140 })
    }

    func testTheDraggedCatSwingsAgainstTheWayItIsCarriedAndHangsStraightAgain() {
        XCTAssertLessThan(CatIconView.swingTarget(velocity: 500), 0, "carried right, it swings back to the left")
        XCTAssertGreaterThan(CatIconView.swingTarget(velocity: -500), 0)
        XCTAssertEqual(CatIconView.swingTarget(velocity: 0), 0)
        XCTAssertEqual(CatIconView.swingTarget(velocity: 1e9), -0.4, "never far enough to leave its window")
        XCTAssertEqual(CatIconView.swingTarget(velocity: -1e9), 0.4)
        // A pendulum: pulled by a quick move it passes the target, comes back past upright, and settles.
        var swing = PetSpring()
        var seen = [CGFloat]()
        for frame in 0..<240 {
            let velocity: CGFloat = frame < 20 ? 700 : 0
            seen.append(swing.advance(to: CatIconView.swingTarget(velocity: velocity), PetSpring.Step(w: 8, zeta: 0.28, dt: 1.0 / 60)))
        }
        XCTAssertLessThan(seen.min()!, -0.2); XCTAssertGreaterThan(seen[20...120].max()!, 0.03, "it swings back the other way")
        XCTAssertEqual(seen.last!, 0, accuracy: 0.01)
        XCTAssertTrue(seen.allSatisfy { abs($0) < 0.6 })
    }

    // MARK: A cat nobody can see

    override func tearDown() {
        PetSight.windowOverride = nil; PetSight.screensDarkOverride = nil
        super.tearDown()
    }

    /// A collapsed cat with its model, in a borderless window that is never ordered in: whether it can be seen is what `seen` says (the
    /// window server is not asked, and a Mac running the tests may well be locked).
    private func petInAWindow(seen: @escaping () -> Bool) throws -> (pet: PetView, window: NSWindow, model: AppModel, done: () -> Void) {
        try XCTSkipIf(PetAnimation.motionReduced, "Reduce Motion is on: the cat holds still and has no timer, by design")
        PetSight.screensDarkOverride = false
        PetSight.windowOverride = { _ in seen() }
        let suite = "nook-pet-sight-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = true
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        pet.injectedModel = model
        let window = NSWindow(contentRect: pet.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pet
        return (pet, window, model, { window.contentView = nil; defaults.removePersistentDomain(forName: suite) })
    }

    func testACatNobodyCanSeeHasNoTimerAndOneThatComesIntoSightStartsAtOnce() throws {
        var seen = false
        let rig = try petInAWindow(seen: { seen })
        defer { rig.done() }
        XCTAssertEqual(rig.pet.frameInterval, 0, "in a window nobody can see: no timer, not even a slow one")
        XCTAssertEqual(rig.pet.ticks, 0)
        // Its panel comes on screen: the panel says so, and the cat starts at once (no watchdog to wait for).
        seen = true
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: rig.window)
        XCTAssertEqual(rig.pet.ticks, 1)
        XCTAssertGreaterThan(rig.pet.frameInterval, 0, "it has its timer again")
        // Covered (the island opened over it, a full-screen app): the occlusion change stops it, timer and all.
        seen = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)
        XCTAssertEqual(rig.pet.frameInterval, 0)
        // Another window's news is not its business.
        seen = true
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: NSWindow())
        XCTAssertEqual(rig.pet.frameInterval, 0)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: rig.window)
        XCTAssertGreaterThan(rig.pet.frameInterval, 0, "uncovered, it runs again")
    }

    func testACatStopsWhileTheScreensSleepOrAreLockedAndWakesWithThem() throws {
        let rig = try petInAWindow(seen: { true })
        defer { rig.done() }
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: rig.window)
        XCTAssertGreaterThan(rig.pet.frameInterval, 0)
        // The displays sleep (or the screen locks): a window does not always learn it from its occlusion, the monitor does.
        PetSight.screensDarkOverride = true
        NotificationCenter.default.post(name: PetPowerMonitor.didChange, object: nil)
        pump(until: { rig.pet.frameInterval == 0 }, timeout: 1)
        XCTAssertEqual(rig.pet.frameInterval, 0, "nothing runs while no screen can be seen")
        let ticks = rig.pet.ticks
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: rig.window)
        XCTAssertEqual(rig.pet.ticks, ticks, "and nothing brings it back but a screen")
        PetSight.screensDarkOverride = false
        NotificationCenter.default.post(name: PetPowerMonitor.didChange, object: nil)
        XCTAssertGreaterThan(rig.pet.ticks, ticks)
        XCTAssertGreaterThan(rig.pet.frameInterval, 0, "the screens wake, and so does the cat")
    }

    func testTheMonitorKnowsWhenNoScreenCanBeSeen() {
        let monitor = PetPowerMonitor.shared
        let before = monitor.screensDark
        var posts = 0
        let watch = NotificationCenter.default.addObserver(forName: PetPowerMonitor.didChange, object: monitor, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(watch) }
        monitor.screens("prueba", dark: true)
        XCTAssertTrue(monitor.screensDark)
        XCTAssertEqual(posts, before ? 0 : 1, "the cats hear of it only when it changes whether a screen can be seen")
        monitor.screens("prueba", dark: true)
        XCTAssertEqual(posts, before ? 0 : 1, "the same news twice is news once")
        monitor.screens("prueba", dark: false)
        XCTAssertEqual(monitor.screensDark, before, "and it is as it was when that reason ends")
        XCTAssertEqual(posts, before ? 0 : 2)
    }

    func testTheCollapsedCatTicksForWhatItShowsAndNotForTheRestOfTheModel() throws {
        let rig = try petInAWindow(seen: { true })
        defer { rig.done() }
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: rig.window)
        pump(0.05)
        // Terminal's snapshots, the tabs, a notice: the model announces them all, several a second. None is the cat's business; the
        // cat's own timer may tick meanwhile, so what counts is that the model's traffic adds nothing to it.
        func ticks(during change: () -> Void) -> Int {
            let start = rig.pet.ticks
            for _ in 0..<20 { change(); pump(0.005) }
            return rig.pet.ticks - start
        }
        let quiet = ticks { }
        let traffic = ticks { rig.model.objectWillChange.send(); rig.model.notice = UUID().uuidString; rig.model.objectWillChange.send() }
        XCTAssertLessThanOrEqual(traffic, quiet + 2, "the model's traffic is no reason for a frame: \(traffic) ticks against \(quiet) without it")
        // Claude starting to work is: the cat takes a frame for it at once.
        let before = rig.pet.ticks
        rig.model.working = true
        pump(0.005)
        XCTAssertGreaterThan(rig.pet.ticks, before, "the cat answers what it shows at once")
    }

    func testTheDotsKeepTheirOwnEightFramesASecondHoweverOftenTheCatTicks() {
        var clock = PetDotsClock()
        XCTAssertEqual(clock.frame(now: 10, waving: false).draw, false)
        XCTAssertNil(clock.frame(now: 10, waving: false).within, "no dots, nothing to ask of the timer")
        // A cat moving at thirty frames a second, and the dots waving under it.
        var frames = [Double](), t = 100.0
        while t < 110 {
            let frame = clock.frame(now: t, waving: true)
            if frame.draw { frames.append(t) }
            XCTAssertLessThanOrEqual(frame.within ?? 1, PetAnimation.dotsInterval + 1e-9)
            t += min(1.0 / 30, frame.within ?? 1)
        }
        let rate = Double(frames.count) / 10
        XCTAssertGreaterThanOrEqual(rate, 7.5); XCTAssertLessThanOrEqual(rate, 11, "about their eight a second, not the cat's thirty: \(rate)")
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $1 - $0 >= 0.085 })
        // A resting cat (four a second): the dots ask for their own ticks in between.
        clock = PetDotsClock(); frames = []; t = 200
        while t < 210 {
            let frame = clock.frame(now: t, waving: true)
            if frame.draw { frames.append(t) }
            t += min(0.25, frame.within ?? 1)
        }
        XCTAssertEqual(Double(frames.count) / 10, 8, accuracy: 0.6)
    }

    func testTheOverlayCatIsRepaintedOnlyWhenWhatItShowsChanges() {
        let icon = CatIconView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertTrue(icon.show(color: .white, look: PetLook(), animated: false, working: false), "the first values it is given")
        XCTAssertFalse(icon.show(color: .white, look: PetLook(), animated: false, working: false), "the panel updating with the same values")
        XCTAssertTrue(icon.show(color: .white, look: PetLook(coat: .tabby), animated: false, working: false), "a new coat")
        XCTAssertTrue(icon.show(color: .white, look: PetLook(coat: .tabby), animated: false, working: true), "Claude starting to work")
        XCTAssertFalse(icon.show(color: .white, look: PetLook(coat: .tabby), animated: false, working: true))
    }

    func testTheCatsOwnPaintingOfAFrameDoesNotNeedAWindow() throws {
        let pet = PetView(frame: NSRect(x: 0, y: 0, width: 246, height: 32))
        let wing = try pixels(of: pet)
        XCTAssertGreaterThan(wing.filter { $0.r < 5 && $0.g < 5 && $0.b < 5 }.count, wing.count / 2, "the island's black")
    }
}
