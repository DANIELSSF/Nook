import AppKit

/// Runs a cat: owns the director, the follow-through and the clocks, eases the working state, and hands out the pose to draw.
struct PetPlayer {
    enum Layout: Equatable {
        case compact(height: CGFloat = 32)
        case header(travel: CGFloat, scale: CGFloat = 0.5, height: CGFloat = 32)
        var stage: PetStage {
            switch self {
            case .compact(let height): .compact(height: height)
            case .header(let travel, let scale, let height): .header(travel: travel, scale: scale, height: height)
            }
        }
    }
    /// The longest time a frame may stand for. The cat waits up to half a second between frames while nobody is watching, and the time
    /// between them must still be the time that passed; a longer gap (the Mac slept) is not catching up.
    static let longestStep = 0.6
    private(set) var director: PetDirector
    private var secondary = PetSecondary()
    /// Free-running clock (system uptime), so every sitting cat on screen is in the same phase.
    private(set) var wall: Double = 0
    private(set) var alert: Double = 0
    private var last: Double?

    init(layout: PetLayout, seed: Int = 0, rhythm: PetDirector.Rhythm? = nil) { director = PetDirector(layout: layout, seed: seed, rhythm: rhythm) }
    /// A random seed, so each launch has its own routine.
    static func randomSeed() -> Int { Int.random(in: 0..<100_000) }

    /// Back at home, calm, when the view reappears; the rhythm picks up where it was.
    mutating func settle() { last = nil; director.settle(); secondary.reset() }
    /// The cat was put down after a drag.
    mutating func land() { director.land() }
    /// Whether the frames are worth drawing at the full rate.
    var isBusy: Bool { director.isBusy }
    /// How wound up the follow-through still is.
    var energy: CGFloat { secondary.energy }
    /// Puts the cat to bed for the night: asleep at once, and asleep through everything but `wake` (`PetBedtime`).
    mutating func fallAsleep(facing: CGFloat = 1) { director.fallAsleep(facing: facing) }
    /// Wakes a sleeping cat, gently (see `PetDirector.wake`); false if there was nothing to wake.
    @discardableResult
    mutating func wake(age: Double = 0, squint: CGFloat = 0) -> Bool { director.wake(age: age, squint: squint) }
    /// The cat is in bed for the night; and whether it sleeps at all (a nap included), which a click wakes.
    var isPinnedAsleep: Bool { director.isPinnedAsleep }
    var isAsleep: Bool { director.isAsleep }
    var isWaking: Bool { director.waking != nil }
    /// Starts a gesture now instead of waiting for its turn (previews and tests).
    mutating func begin(_ kind: PetDirector.Kind, layout: Layout, focus: PetFocus = .free) { director.start(kind, stage: layout.stage, focus: focus) }

    /// The temperament the cat carries itself with.
    static func temperament(_ input: PetInput) -> PetTemperament { .of(input.prefs.personality, dayPart: input.dayPart) }

    /// - Parameters:
    ///   - motion: false when Reduce Motion or the pet preference is on; the pose is then a fixed one for the state.
    ///   - input: the world as it is now: the pointer, a drag, an alert, completions, what the user is doing.
    mutating func pose(now: Double, layout: Layout, motion: Bool, input: PetInput) -> PetPose {
        guard motion else { last = nil; secondary.reset(); return PetAnimation.staticPose(working: input.working, attention: input.needsAttention) }
        let dt = last.map { min(Self.longestStep, max(0, now - $0)) } ?? 0
        last = now; wall = now
        alert = Self.follow(alert, input.working ? 1 : 0, dt / 0.6)
        let stage = layout.stage
        director.update(dt: dt, input, stage: stage)
        let smoothAlert = PetAnimation.smooth(alert)
        var pose = director.pose(wall: wall, alert: smoothAlert, input: input, stage: stage)
        // Its small life, then its follow-through, over whatever the director made.
        PetLife.apply(&pose, lifeContext(now: now, input: input))
        secondary.apply(&pose, dt: dt, scale: stage.scale)
        return pose
    }

    /// What the cat's small life is told right now.
    func lifeContext(now: Double, input: PetInput) -> PetLife.Context {
        var life = PetLife.Context(time: now, temperament: Self.temperament(input))
        life.restful = director.lifeWeight
        life.quiet = Self.quiet(input.focus)
        life.rate = Self.rate(input.focus)
        life.breath = Self.breath(input.focus)
        life.alert = PetAnimation.smooth(alert)
        // Nobody is looking at a Mac that has not been touched for a minute and a half: the cat sits through it, breathing.
        if input.idle >= PetCadence.awayAfter { life.rate *= 0.25; life.quiet = min(life.quiet, 0.3); life.breath = min(life.breath, 0.5) }
        return life
    }

    /// How much of its small movements a cat allows itself while the user is typing, reading, or free to be watched.
    static func quiet(_ focus: PetFocus) -> CGFloat {
        switch focus { case .free: 1; case .reading: 0.55; case .typing: 0.3 }
    }
    /// How often its small movements come in each of those, against the plain cat's.
    static func rate(_ focus: PetFocus) -> Double {
        switch focus { case .free: 1.5; case .reading: 1.0; case .typing: 0.6 }
    }
    /// How visibly it breathes in each of those.
    static func breath(_ focus: PetFocus) -> CGFloat {
        switch focus { case .free: 1; case .reading: 0.75; case .typing: 0.5 }
    }

    private static func follow(_ value: Double, _ target: Double, _ step: Double) -> Double {
        value < target ? min(target, value + step) : max(target, value - step)
    }
}

// MARK: - Frame pacing

/// How often the cat is drawn: by how far its picture moves between two frames, so a cat that is still costs next to nothing and
/// one that moves gets a frame whenever the eye would see the difference.
struct PetPace {
    /// The shortest interval (the layout's top rate) and the longest (only breathing).
    var fast: Double
    var slow = PetAnimation.restInterval
    /// Device pixels per point of the cat's drawing (2 on a Retina display).
    var backing: CGFloat = 2
    /// How far, in device pixels, the picture may move between two frames before the motion would show as steps.
    var stepPixels: CGFloat = 1.5
    /// A little time at the faster rate after the motion has stopped, so the pauses between the beats of a movement (a blink
    /// closing and opening) do not drop the rate in the middle of it.
    var dwell = 0.12

    /// The rates a frame interval is rounded to (the shortest that is no longer than what the motion asks): a handful of values,
    /// so the timer behind it is retuned rarely, not on every frame.
    static let levels: [Double] = [1.0 / 60, 1.0 / 30, 1.0 / 20, 1.0 / 12, 1.0 / 8, 1.0 / 6, 1.0 / 5, 1.0 / 4, 1.0 / 3, 1.0 / 2.5, 1.0 / 2]
    var medium: Double { min(slow, fast * 2) }

    private var last: (pose: PetPose, time: Double)?
    private var current: Double?
    private var quietSince: Double?

    init(fast: Double, slow: Double = PetAnimation.restInterval, backing: CGFloat = 2) { self.fast = fast; self.slow = slow; self.backing = backing }

    /// The interval until the next frame. `scale` is the points per rig unit the cat is drawn at; `ceiling` the longest the next
    /// interval may be right now (a gesture is under way, and its next beat may start at any moment); `due` the seconds until
    /// something small starts (a blink), so the frame comes when it does.
    mutating func interval(for pose: PetPose, now: Double, scale: CGFloat = PetAnimation.compactScale, ceiling: Double? = nil, due: Double? = nil) -> Double {
        defer { last = (pose, now) }
        var wanted = slow
        if let last, now > last.time {
            let pixelsPerSecond = pose.displacement(to: last.pose, scale: scale) * backing / CGFloat(now - last.time)
            if pixelsPerSecond > 0.0001 { wanted = min(slow, max(fast, Double(stepPixels / pixelsPerSecond))) }
        } else { wanted = fast }
        let level = Self.round(wanted, fast: fast, slow: slow)
        // Slowing down waits for the motion to have stayed quiet; speeding up is at once.
        if let current, level > current {
            let since = quietSince ?? now
            quietSince = since
            if now - since < dwell { return clamp(current, ceiling, due) }
        } else { quietSince = nil }
        current = level
        return clamp(level, ceiling, due)
    }

    private func clamp(_ interval: Double, _ ceiling: Double?, _ due: Double?) -> Double {
        var result = interval
        if let ceiling { result = min(result, max(fast, ceiling)) }
        if let due { result = min(result, max(fast, due)) }
        return result
    }

    /// The longest level that is not longer than `seconds`, between `fast` and `slow`.
    static func round(_ seconds: Double, fast: Double, slow: Double) -> Double {
        var best = fast
        for level in levels where level >= fast - 1e-9 && level <= slow + 1e-9 && level <= seconds + 1e-9 { best = max(best, level) }
        return best
    }

    mutating func reset() { last = nil; current = nil; quietSince = nil }
}

/// What the cat's cadence depends on besides its own motion: the user's focus and the Mac's power state.
enum PetCadence {
    /// The slowest frame interval, while the cat only breathes: the cat is drawn less while the user works, and less on battery.
    static func rest(focus: PetFocus, idle: Double = 0, power: PetPower) -> Double {
        var base: Double
        switch focus { case .free: base = 1.0 / 4; case .reading: base = 1.0 / 3; case .typing: base = 1.0 / 2.5 }
        // Nobody is looking at a Mac nobody has touched for a minute and a half.
        if idle >= awayAfter { base = 1.0 / 2 }
        return power == .normal ? base : min(1.0 / 2, base * 1.6)
    }
    static let awayAfter = 90.0
    /// The fastest: a cat on a Mac that is saving power moves at half the rate.
    static func fast(_ layout: PetLayout, power: PetPower) -> Double {
        let base = layout == .compact ? PetAnimation.compactInterval : PetAnimation.headerInterval
        return power == .normal ? base : base * 2
    }
    /// How far, in device pixels, the picture has to differ from the one on screen before it is worth drawing again.
    static func threshold(focus: PetFocus, idle: Double = 0, power: PetPower) -> CGFloat {
        var base: CGFloat
        switch focus { case .free: base = 0.22; case .reading: base = 0.3; case .typing: base = 0.4 }
        if idle >= awayAfter { base = 0.6 }
        return power == .normal ? base : base * 1.5
    }
}

/// Everything a cat view does on a tick except the views' own business (the window, the pointer, the model): feed the world to the
/// player, choose when to come back, and say whether the picture changed enough to draw. The views call this and nothing else, so
/// what the simulated days in the tests measure is what the app does.
struct PetDriver {
    var player: PetPlayer
    var pace: PetPace
    let layout: PetLayout
    /// The pose that is on screen: the last one that was drawn.
    private(set) var drawn = PetPose()
    private var lastTick = -1000.0
    private var lastInterval: Double

    struct Tick: Equatable {
        var pose: PetPose
        /// The seconds until the next tick.
        var interval: Double
        /// Whether the picture changed enough to draw it again.
        var draw: Bool
    }

    init(layout: PetLayout, seed: Int = PetPlayer.randomSeed(), backing: CGFloat = 2, rhythm: PetDirector.Rhythm? = nil) {
        self.layout = layout
        player = PetPlayer(layout: layout, seed: seed, rhythm: rhythm)
        pace = PetPace(fast: PetCadence.fast(layout, power: .normal), backing: backing)
        lastInterval = pace.slow
    }

    mutating func settle() { player.settle(); pace.reset(); lastTick = -1000 }

    /// One tick at `now` (seconds of system uptime) with the cat in `stage`'s layout.
    mutating func tick(now: Double, layout stage: PetPlayer.Layout, input: PetInput) -> Tick {
        // A second tick right after another (the model announced a change a few milliseconds after a frame) has nothing new to say.
        if now - lastTick < 0.012 { return Tick(pose: drawn, interval: lastInterval, draw: false) }
        lastTick = now
        pace.fast = PetCadence.fast(layout, power: input.power)
        pace.slow = PetCadence.rest(focus: input.focus, idle: input.idle, power: input.power)
        let next = player.pose(now: now, layout: stage, motion: true, input: input)
        let scale = stage.stage.scale
        // A gesture under way may begin its next beat at any moment, and the pointer, an alert or a hop need the picture to follow.
        var ceiling = player.director.frameCeiling
        if input.perk > 0 { ceiling = min(ceiling ?? 1, 1.0 / 20) }
        // A blink or a flick that is under way is drawn in a few frames; one that is about to start gets a frame as it does.
        let timing = PetLife.timing(player.lifeContext(now: now, input: input))
        if timing.busyFor > 0 { ceiling = min(ceiling ?? 1, 1.0 / 20) }
        let interval = pace.interval(for: next, now: now, scale: scale, ceiling: ceiling, due: timing.due - 0.02)
        lastInterval = interval
        let moved = next.displacement(to: drawn, scale: scale) * pace.backing
        let draw = moved >= PetCadence.threshold(focus: input.focus, idle: input.idle, power: input.power)
        if draw { drawn = next }
        return Tick(pose: next, interval: interval, draw: draw)
    }
}

// MARK: - Clocks

/// Seconds since the user last touched the keyboard, scrolled, or did anything at all, read from the system's input
/// counters (no permission needed). Asked at most once a second, however often the cat's frames call it.
struct PetUserProbe {
    private var at = -1000.0
    private(set) var keyAge = 1e9, scrollAge = 1e9, idle = 0.0
    mutating func read(now: Double) {
        guard now - at >= 1 else { return }
        at = now
        func age(_ type: CGEventType) -> Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) }
        keyAge = age(.keyDown); scrollAge = age(.scrollWheel)
        idle = CGEventType(rawValue: ~0).map(age) ?? min(keyAge, scrollAge, age(.mouseMoved), age(.leftMouseDown))
    }
}

/// The hour of the day, read at most once a minute.
struct PetClock {
    private var at = -1000.0
    private(set) var part = PetDayPart.day
    mutating func read(now: Double) {
        guard now - at >= 60 else { return }
        at = now
        part = .of(hour: Calendar.current.component(.hour, from: Date()))
    }
}

/// The notch's three working dots keep their own eight frames a second. The cat's ticks come in between whenever it moves (thirty a
/// second through a blink or a gesture), and repainting the dots on each of those would draw them up to four times as often as their
/// wave needs; so the dots are repainted only when their own frame is due, and the next tick is asked for no later than that.
struct PetDotsClock {
    private var drawnAt = -1000.0

    /// Whether the dots' frame is due at `now` (they are then repainted, and their clock starts over), and the longest the next tick
    /// may wait for them: nil while they do not wave.
    mutating func frame(now: Double, waving: Bool) -> (draw: Bool, within: Double?) {
        guard waving else { drawnAt = -1000; return (false, nil) }
        let interval = PetAnimation.dotsInterval
        // A tick that comes a little early (the cat's own, a display link frame) is taken as the dots' frame rather than asking for one
        // more tick of their own a few hundredths later: a wave a second long shows no difference between 0.09 s and 0.125 s apart.
        if now - drawnAt >= interval - 0.035 { drawnAt = now; return (true, interval) }
        return (false, max(0.012, drawnAt + interval - now))
    }
}

/// Whether anyone can see a cat's view right now: its window is on screen and not covered (a window stays "visible" under a
/// full-screen app; only occlusion says it is seen), the view is not hidden, and a screen is awake and unlocked. A cat nobody can see
/// keeps no timer at all: it is woken by what brings it back (its window's occlusion changing, a `NotchPanel` coming on screen, the
/// screens waking, the model or SwiftUI telling the view something).
enum PetSight {
    /// Tests stand in for the window server and the screens here. Nil asks the real ones.
    static var windowOverride: ((NSView) -> Bool)?
    static var screensDarkOverride: Bool?

    static func canSee(_ view: NSView) -> Bool {
        if screensDarkOverride ?? PetPowerMonitor.shared.screensDark { return false }
        if let windowOverride { return windowOverride(view) }
        guard let window = view.window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
    }

    /// Posted by a `NotchPanel` (object: the panel) as it comes on screen, and as it is put away.
    static let cameOnScreen = Notification.Name("dev.nook.PetWindowCameOnScreen")
    static let wentOffScreen = Notification.Name("dev.nook.PetWindowWentOffScreen")

    /// Observers (on the default center) that call `wake` whenever `window` may have come into sight or gone out of it: its occlusion
    /// changed, or it was ordered in or out. The screens waking is heard through `PetPowerMonitor.didChange`; at these moments the monitor
    /// also asks the system again, so a lock or a sleep whose end it missed cannot keep a cat still that someone is looking at.
    static func wakeups(for window: NSWindow, _ wake: @escaping () -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return [NSWindow.didChangeOcclusionStateNotification, cameOnScreen, wentOffScreen].map { name in
            center.addObserver(forName: name, object: window, queue: .main) { _ in
                if PetPowerMonitor.shared.screensDark { PetPowerMonitor.shared.recheck() }
                wake()
                // A window just ordered in may not have its occlusion worked out yet, and its change is not always reported: one more look a
                // moment later, so nothing stays still in a window that is in plain sight.
                if name == cameOnScreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: wake) }
            }
        }
    }
}

/// The cat's heartbeat. Slow ticks (a cat that only breathes) come from one timer source that is only retuned, never rebuilt; fast ones
/// (a cat that moves) from a display link, so each frame lands on a refresh of the screen it is on and the pose can be computed for
/// the moment the frame will be seen (`fire`'s lead). Neither exists while the cat is still, and `stop()` leaves nothing behind; a cat
/// nobody can see `pause()`s them instead, so it wakes nothing until it is seen and then builds nothing to run again.
///
/// The timer's leeway is a fifth of its interval, which the system uses to coalesce the cat's wakeups with others (measured on an idle
/// Mac it fires late by most of it: a resting tick of 0.25 s lands some 45 ms late, which a frame of breathing does not show).
final class PetTicker {
    private var source: DispatchSourceTimer?
    private var link: CADisplayLink?
    private(set) var interval: TimeInterval = 0
    /// Called on every tick with how far ahead of now the display link's frame will be seen (seconds), or nil for a timer tick. A lead,
    /// not a timestamp: the link's clock and the system's uptime need not count from the same moment, and a difference is safe to add.
    private let fire: (CFTimeInterval?) -> Void
    /// The view whose screen paces motion frames; its display link also pauses when it isn't visible.
    weak var host: NSView?
    init(_ fire: @escaping () -> Void) { self.fire = { _ in fire() } }
    init(timed fire: @escaping (CFTimeInterval?) -> Void) { self.fire = fire }
    deinit { stop() }

    /// A tick every `seconds`. A call that asks for the interval already in force does nothing.
    func run(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        if seconds <= 1.0 / 20, let host {
            if link == nil {
                let made = host.displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
                made.add(to: .main, forMode: .common)
                link = made
            }
            let rate = Float((1 / seconds).rounded())
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: max(10, rate / 2), maximum: rate, preferred: rate)
            link?.isPaused = false
            source?.schedule(deadline: .distantFuture)
            return
        }
        link?.isPaused = true
        let timer: DispatchSourceTimer
        if let source { timer = source } else {
            timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.fire(nil) }
            timer.resume()
            source = timer
        }
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(Int(seconds * 200)))
    }

    func stop() {
        source?.cancel(); source = nil
        link?.invalidate(); link = nil
        interval = 0
    }

    /// No tick at all until `run(every:)` is asked again, keeping the timer source and the display link for then: a cat that nobody can
    /// see (its island put away, the screens asleep) costs nothing, and coming back into sight builds nothing.
    func pause() {
        guard interval != 0 else { return }
        source?.schedule(deadline: .distantFuture)
        link?.isPaused = true
        interval = 0
    }

    /// The display link retains its target; a weak hop keeps it from keeping the ticker alive.
    private final class LinkTarget: NSObject {
        weak var ticker: PetTicker?
        init(_ ticker: PetTicker) { self.ticker = ticker }
        @objc func tick(_ link: CADisplayLink) { ticker?.fire(max(0, min(0.1, link.targetTimestamp - CACurrentMediaTime()))) }
    }
}

extension NSView {
    /// Whether the pointer is within `margin` points of `rect` (view coordinates), even while another app is active.
    func pointerIsNear(_ rect: NSRect, margin: CGFloat) -> Bool {
        guard let window else { return false }
        return rect.insetBy(dx: -margin, dy: -margin).contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    /// What the pointer pulls on a cat whose head is at `head` (view coordinates): nil unless it is within `enter`
    /// points (`leave` once it has been noticed, so the edge doesn't flicker) or `over` the cat itself. Works while
    /// another app is active.
    func petGaze(head: CGPoint, enter: CGFloat, leave: CGFloat, noticed: inout Bool, over: Bool) -> PetGaze? {
        guard let window else { noticed = false; return nil }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let dx = point.x - head.x, dy = point.y - head.y
        let near = over || PetDirector.pointerNear(distance: hypot(dx, dy), wasNear: noticed, enter: enter, leave: leave)
        noticed = near
        return near ? PetGaze(dx: dx / 40, dy: dy / 24) : nil
    }
}
