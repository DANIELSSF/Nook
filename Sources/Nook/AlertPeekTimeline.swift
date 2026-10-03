import Foundation
import CoreGraphics

/// The collapsed island's version of the terminal bell: when an alert arrives the island grows a little
/// below the notch, rings a bell and shows who is calling for a few seconds, then settles back.
///
/// Everything here is a pure function of time. The view and the controller only ask "what does the peek look
/// like at this moment" and "when does it next change", so the schedule, replacement, hover and
/// reduced-motion rules are all testable without a window.
struct AlertPeekTimeline {
    enum Phase: Equatable { case idle, entering, holding, leaving }

    struct Timing: Equatable {
        /// The island reaches its full size (the spring has settled).
        var grow = 0.5
        /// Fully open, before it starts to close.
        var hold = 3.1
        var shrink = 0.38
        /// Least time left after the pointer leaves, so a glance never ends the peek under the pointer.
        var afterHover = 1.2
        /// Reduced motion: the dissolve in and out, with no movement.
        var fade = 0.3
        /// A newer alert replacing the text of an open peek: the old line fades out, then the new one fades in.
        var swap = 0.24
        /// The bell's shake: when it starts after the peek begins, and how long it lasts.
        var ringDelay = 0.18, ringLength = 1.25
        /// The cat's reaction: it perks up, holds, and relaxes while the peek is still showing.
        var perkAttack = 0.3, perkHold = 1.9, perkRelease = 0.8
    }

    /// One growing or shrinking stretch of the island, remembered from where it started so an
    /// interruption (a newer alert, the pointer coming back) continues from what is on screen.
    private struct Move: Equatable {
        var from: CGFloat
        var start: Double
        var opening: Bool
    }

    let timing: Timing
    private(set) var alert: NookAlert?
    private var outgoing: NookAlert?
    private var swapStart: Double?
    private var motion = true
    private var move = Move(from: 0, start: 0, opening: true)
    private var leaveAt = 0.0
    private var ringStart = 0.0
    private var perkStart = 0.0
    private(set) var hovering = false

    init(timing: Timing = Timing()) { self.timing = timing }

    var isActive: Bool { alert != nil }
    private var openDuration: Double { motion ? timing.grow : timing.fade }
    private var closeDuration: Double { motion ? timing.shrink : timing.fade }

    // MARK: Events

    /// Starts the peek for `alert`, or swaps the content of one that is already showing. The same alert
    /// again changes nothing. `motion` is false for Reduce Motion or the pet preference: the peek then only fades.
    mutating func begin(_ alert: NookAlert, now: Double, motion: Bool) {
        advance(to: now)
        guard let current = self.alert else {
            self = AlertPeekTimeline(timing: timing)
            self.alert = alert; self.motion = motion
            move = Move(from: 0, start: now, opening: true)
            leaveAt = now + openDuration + timing.hold
            ringStart = now + timing.ringDelay
            perkStart = now
            return
        }
        guard alert.id != current.id else { return }
        // A newer alert takes the place of the one on screen: the island keeps its size and the text crossfades.
        let reached = perk(at: now)
        outgoing = current; swapStart = now; self.alert = alert
        if !move.opening { move = Move(from: presence(at: now), start: now, opening: true) }
        leaveAt = max(now, move.start + openDuration) + timing.hold
        ringStart = now + timing.swap / 2
        // The cat is already perked: it stays so instead of dropping and perking up again.
        perkStart = now - timing.perkAttack * Double(reached)
    }

    /// The island expanded (or the peek stopped mattering): gone at once, with no fade.
    mutating func cancel() { self = AlertPeekTimeline(timing: timing) }

    /// The pointer is over the peek: it stays open while it is, and lets go a moment after it leaves.
    mutating func setHover(_ hovering: Bool, now: Double) {
        advance(to: now)
        guard alert != nil, hovering != self.hovering else { return }
        self.hovering = hovering
        if hovering {
            if !move.opening { move = Move(from: presence(at: now), start: now, opening: true) }
        } else {
            leaveAt = max(leaveAt, now + timing.afterHover)
        }
    }

    /// Applies the moves that came due by `now`: the start of the closing, and the end of the peek.
    mutating func advance(to now: Double) {
        guard alert != nil else { return }
        if move.opening, !hovering, now >= leaveAt {
            move = Move(from: presence(at: leaveAt), start: leaveAt, opening: false)
        }
        if !move.opening, now >= move.start + closeDuration { cancel() }
    }

    // MARK: Questions

    func phase(at now: Double) -> Phase {
        var state = self
        state.advance(to: now)
        guard state.alert != nil else { return .idle }
        if !state.move.opening { return .leaving }
        return now < state.move.start + state.openDuration ? .entering : .holding
    }

    /// True while something on the peek moves, so frames must be drawn; false while it only sits there.
    func isAnimating(at now: Double) -> Bool {
        var state = self
        state.advance(to: now)
        guard state.alert != nil else { return false }
        let phase = state.phase(at: now)
        if phase == .entering || phase == .leaving { return true }
        if state.motion, now < state.ringStart + timing.ringLength { return true }
        if let started = state.swapStart, now < started + timing.swap { return true }
        return false
    }

    /// When the next change is due while nothing moves: the moment it starts to close. Nil while the
    /// pointer holds it open (leaving the peek asks again) or when something is animating.
    func nextWake(at now: Double) -> Double? {
        var state = self
        state.advance(to: now)
        guard state.alert != nil, !state.hovering, !state.isAnimating(at: now) else { return nil }
        return max(now, state.leaveAt)
    }

    /// How much the cat reacts, 0...1. It never reacts without motion.
    func perk(at now: Double) -> CGFloat {
        var state = self
        state.advance(to: now)
        guard state.alert != nil, state.motion else { return 0 }
        let t = now - state.perkStart
        return PetAnimation.ramp(t, 0, timing.perkAttack) * (1 - PetAnimation.ramp(t, timing.perkHold, timing.perkHold + timing.perkRelease))
    }

    func frame(at now: Double) -> AlertPeekFrame {
        var state = self
        state.advance(to: now)
        guard let alert = state.alert else { return .empty }
        let p = state.presence(at: now)
        var frame = AlertPeekFrame(alert: alert)
        if state.motion {
            frame.progress = p; frame.surface = 1
            // The text appears once the island is mostly out, and leaves before it shrinks away.
            frame.content = PetAnimation.ramp(Double(p), 0.38, 0.88)
            let t = now - state.ringStart
            if t > 0, t < timing.ringLength {
                frame.bell = Self.ring(t)
            }
        } else {
            // No movement: the island is already full size and the whole surface dissolves.
            frame.progress = 1; frame.surface = min(1, max(0, p)); frame.content = 1
        }
        if let old = state.outgoing, let started = state.swapStart, now < started + timing.swap {
            // One after the other, so two lines of different widths are never on top of each other.
            let u = (now - started) / timing.swap
            frame.outgoing = old
            frame.outgoingContent = frame.content * (1 - PetAnimation.smooth(u / 0.5))
            frame.content *= PetAnimation.smooth((u - 0.5) / 0.5)
        }
        return frame
    }

    // MARK: Curves

    /// How open the island is: 0 collapsed, 1 fully grown; a spring on the way out slightly overshoots.
    private func presence(at now: Double) -> CGFloat {
        let t = max(0, now - move.start)
        if move.opening {
            let u = motion ? Self.spring(t, settle: timing.grow) : PetAnimation.smooth(t / timing.fade)
            return move.from + (1 - move.from) * u
        }
        return move.from * (1 - PetAnimation.smooth(t / closeDuration))
    }

    /// A lightly under-damped spring from 0 to 1 (about 2% overshoot), snapped to 1 once settled.
    static func spring(_ t: Double, settle: Double = 0.5) -> CGFloat {
        guard t < settle else { return 1 }
        let zeta = 0.78, w0 = 2 * Double.pi * 2.2
        let wd = w0 * (1 - zeta * zeta).squareRoot()
        return CGFloat(1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t)))
    }

    /// The bell's swing in radians `t` seconds after it starts: quick alternating swings that die away.
    static func ring(_ t: Double) -> CGFloat {
        let amplitude = 0.4
        return CGFloat(amplitude * exp(-3.2 * t) * sin(2 * Double.pi * 4.6 * t)) * PetAnimation.ramp(t, 0, 0.05)
    }

    /// Whether an alert should change what the collapsed island shows: it is new, the island is
    /// closed and on screen. An alert that arrived while it was open never peeks afterwards.
    static func shouldPeek(_ alert: NookAlert?, shown: Int?, expanded: Bool, visible: Bool) -> Bool {
        guard let alert, !expanded, visible else { return false }
        return alert.id != shown
    }
}

/// What the peek looks like at one moment.
struct AlertPeekFrame: Equatable {
    var alert: NookAlert?
    /// The alert being replaced, fading out while the new one fades in.
    var outgoing: NookAlert?
    /// 0 is the collapsed island, 1 the fully grown peek (the spring may pass slightly beyond).
    var progress: CGFloat = 0
    /// Opacity of the whole surface: 1, except while a reduced-motion peek dissolves.
    var surface: CGFloat = 0
    var content: CGFloat = 0
    var outgoingContent: CGFloat = 0
    /// The bell's rotation in radians.
    var bell: CGFloat = 0

    static let empty = AlertPeekFrame()
}

/// Where the peek sits: the collapsed island with a "chin" below it and a little more wing on each side.
/// The peek has its own window, behind the collapsed island's, so both together read as one black shape.
struct AlertPeekLayout: Equatable {
    /// The collapsed island.
    var compact: CGSize
    /// Extra width on each side, and the extra height below the island.
    var wing: CGFloat = 28
    var chin: CGFloat = 32
    /// Transparent room around the full size for the spring's overshoot.
    var slack: CGFloat = 4
    var compactRadius: CGFloat = 10, fullRadius: CGFloat = 18

    var full: CGSize { CGSize(width: compact.width + 2 * wing, height: compact.height + chin) }
    var windowSize: CGSize { CGSize(width: full.width + 2 * slack, height: full.height + slack) }

    /// The peek's window: centred on the collapsed island and flush with the top of the screen.
    func windowFrame(compactFrame: CGRect) -> CGRect {
        CGRect(x: compactFrame.minX - wing - slack, y: compactFrame.maxY - windowSize.height, width: windowSize.width, height: windowSize.height)
    }

    /// Rectangles in the window's own coordinates (origin bottom left, the top edge on the screen's).
    var compactRect: CGRect { CGRect(x: wing + slack, y: windowSize.height - compact.height, width: compact.width, height: compact.height) }
    var fullRect: CGRect { CGRect(x: slack, y: slack, width: full.width, height: full.height) }
    var chinRect: CGRect { CGRect(x: slack, y: slack, width: full.width, height: chin) }

    /// The island's rectangle while it grows; the top edge never moves.
    func shapeRect(progress p: CGFloat) -> CGRect {
        let a = compactRect, b = fullRect
        let minX = a.minX + (b.minX - a.minX) * p, maxX = a.maxX + (b.maxX - a.maxX) * p
        let minY = a.minY + (b.minY - a.minY) * p
        return CGRect(x: minX, y: minY, width: maxX - minX, height: windowSize.height - minY)
    }
    /// The island's rectangle in screen coordinates, for the window at `windowFrame`.
    func screenRect(progress p: CGFloat, windowFrame: CGRect) -> CGRect {
        shapeRect(progress: p).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
    }
    func radius(progress p: CGFloat) -> CGFloat { compactRadius + (fullRadius - compactRadius) * min(1, max(0, p)) }
}
