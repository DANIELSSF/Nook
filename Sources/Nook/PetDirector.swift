import AppKit

/// Where a cat lives: the collapsed island's wing (in place, always on screen) or the expanded header (a stage to stroll on).
enum PetLayout: Equatable { case compact, header }

/// How much the user is doing, from the cat's point of view. Typing and reading call for quiet, small movements.
enum PetFocus: Int, Comparable {
    case free, reading, typing
    static func < (a: PetFocus, b: PetFocus) -> Bool { a.rawValue < b.rawValue }

    /// Typing wins over reading. `keyAge` and `scrollAge` are seconds since the last key or scroll anywhere on the
    /// Mac; `composing` is a draft in Nook's own field; `panelKey` the expanded panel having the keyboard.
    static func from(keyAge: Double, scrollAge: Double, composing: Bool = false, panelKey: Bool = false) -> PetFocus {
        if composing || keyAge < typingWindow { return .typing }
        if panelKey || scrollAge < readingWindow { return .reading }
        return .free
    }
    static let typingWindow = 4.0, readingWindow = 8.0
}

/// What the director is told on each frame: the state of the world, in plain values (no views, no model).
struct PetInput: Equatable {
    /// The terminal is working: the cat is on duty (no idle gestures in the wing).
    var working = false
    /// The pointer is near the cat, or over the island: where it is. Nil when it is far away.
    var gaze: PetGaze?
    /// The cat is being dragged to a terminal.
    var dragging = false
    /// An alert's pull on the cat (the peek's timeline, 0...1) and how long ago it began.
    var perk: CGFloat = 0
    var perkAge = 0.0
    /// `AppModel.completions`: the cat celebrates when it grows.
    var completions = 0
    var focus = PetFocus.free
    /// Seconds since the user last touched the Mac at all.
    var idle = 0.0
    /// A notice waits unread: only used by the static pose, which cannot move to say so.
    var needsAttention = false
}

/// The room the cat has, in the units the rig needs.
struct PetStage: Equatable {
    var layout: PetLayout
    /// Header: points of room to the right of home, and the cat's scale.
    var travel: CGFloat = 0
    var scale: CGFloat = 0.5
    /// The lowest rig y that is drawn: the island's bottom edge (collapsed) or the stage's (header).
    var ledge: CGFloat
    /// Points of height the cat has to work in.
    var room: CGFloat = 32

    /// The collapsed island of `height` points: the cat's feet are `height / 2 - 9` points above its bottom edge.
    static func compact(height: CGFloat) -> PetStage {
        PetStage(layout: .compact, scale: PetAnimation.compactScale, ledge: -(height / 2 - 9) / PetAnimation.compactScale, room: height)
    }
    static func header(travel: CGFloat, scale: CGFloat = 0.5, height: CGFloat = 32) -> PetStage {
        PetStage(layout: .header, travel: travel, scale: scale, ledge: -HeaderPetView.ground / scale, room: height)
    }
    /// A peek sinks the cat behind the edge with its face still above it, which takes about a 4 point strip of face and
    /// ears plus the room to duck. Every real island has it (28 points on a screen without a notch, 32 with one); a
    /// layout that ever came up shorter would simply never peek, and the gesture would live in the expanded header.
    static let peekRoom: CGFloat = 26
    var canPeek: Bool { room >= Self.peekRoom }
}

/// Decides what the cat does and when, and composes the frame. Pure state in, pose out: the views only feed it time
/// and the world's state, so priorities, interruptions and rhythm are all testable without a window.
///
/// Priority, highest first: the user (pointer near, a drag) → an alert that needs attention → a completion's
/// celebration → decorative gestures. A higher one interrupts a lower one with a smooth fade (a drag within a
/// tenth of a second), and a lower one never starts while a higher one is on.
struct PetDirector {
    enum Kind: Equatable, CaseIterable { case groom, glance, stretch, wave, play, peek, nap, stroll, home }

    /// Seconds between idle gestures, measured from the end of one to the start of the next.
    struct Rhythm: Equatable {
        var first: ClosedRange<Double>
        var between: ClosedRange<Double>
    }
    static let compactRhythm = Rhythm(first: 15...40, between: 40...90)
    /// The header only exists while the island is open, so its first gesture comes a little sooner.
    static let headerRhythm = Rhythm(first: 8...20, between: 40...90)
    /// Real inactivity before the cat may nap, in seconds without any input.
    static let napAfter = 150.0
    /// After an interrupted gesture, at least this long before the next one.
    static let afterInterruption = 20.0
    /// A completion's celebration waits at least this long (an alert peek starts a turn later and takes priority)
    /// and is forgotten after `celebrationExpiry`; two completions closer than `celebrationCooldown` are one.
    static let celebrationDelay = 0.25, celebrationExpiry = 8.0, celebrationCooldown = 4.0
    /// Quiet after the user, an alert or a celebration has had the cat's attention, before it does anything of its own.
    static let calmAfter = 8.0
    /// How long each kind of interruption takes to fade out.
    static let fadeUser = 0.35, fadeDrag = 0.1, fadeAlert = 0.35, fadeCelebration = 0.3, fadeFocus = 0.6, fadeWake = 0.9, fadeStroll = 0.7

    struct Running: Equatable {
        var kind: Kind
        var steps: [PetAnimation.Step] = []
        var startX: CGFloat = 0
        var length: Double
        var age = 0.0
        /// Seconds since it was interrupted, and how long its fade lasts; nil while it runs on.
        var release: Double?
        var fade = 0.35
        var weight: CGFloat { release.map { 1 - PetAnimation.smooth($0 / fade) } ?? 1 }
        /// A stroll stops walking the moment it is interrupted instead of finishing its step.
        var freezes: Bool { kind == .stroll || kind == .home }
    }
    /// A one-off reaction played over everything decorative: the celebration, the landing after a drag.
    struct Overlay: Equatable {
        var length: Double
        var age = 0.0
        var release: Double?
        var fade = 0.3
        var weight: CGFloat { release.map { 1 - PetAnimation.smooth($0 / fade) } ?? 1 }
    }

    let rhythm: Rhythm
    let seed: Int
    private(set) var clock = 0.0
    private(set) var nextAt: Double
    private(set) var picks = 0
    private(set) var last: Kind?
    private(set) var running: Running?
    private(set) var celebration: Overlay?
    private(set) var landing: Overlay?
    private var celebrationAsked: Double?
    private var celebrationAt = -1000.0
    private var seen: Int?
    /// Where the cat sits on the stage, in points right of home. Zero in the wing.
    private(set) var restX: CGFloat = 0
    private var calmSince = 0.0
    /// How far the cat has turned toward the pointer (0...1), where it looks, and how long it has been looking.
    private(set) var curious: Double = 0
    private(set) var gaze = PetGaze()
    private(set) var curiousAge = 0.0

    init(layout: PetLayout, seed: Int = 0) {
        rhythm = layout == .compact ? Self.compactRhythm : Self.headerRhythm
        self.seed = seed
        nextAt = Self.draw(rhythm.first, PetAnimation.hash(0, seed &+ 71))
    }

    // MARK: Rules (pure)

    /// A value in `range` for `r` in 0..<1.
    static func draw(_ range: ClosedRange<Double>, _ r: Double) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * r }

    /// How much the cat feels like `kind` right now; zero means it won't. Naps need real inactivity; typing leaves only
    /// discrete gestures, reading cuts the lively ones to a quarter, and a cat on duty in the wing does nothing.
    static func weight(_ kind: Kind, layout: PetLayout, focus: PetFocus, idle: Double, working: Bool, canPeek: Bool = true) -> Double {
        if working && layout == .compact { return 0 }
        func lively(_ w: Double, walk: Bool = false) -> Double { focus == .free ? w : focus == .reading ? w * (walk ? 0.1 : 0.25) : 0 }
        switch kind {
        case .nap: return idle >= napAfter && focus == .free && !working ? 6 : 0
        case .groom: return 3
        case .glance: return 2.5
        case .stretch: return lively(2)
        case .wave: return lively(1.5)
        case .play: return lively(2)
        case .peek: return canPeek ? lively(1.5) : 0
        case .stroll: return layout == .header ? lively(3, walk: true) : 0
        case .home: return 0
        }
    }

    /// The next gesture: a weighted pick that never repeats the one just done. Nil when nothing is wanted right now.
    static func choose(after last: Kind?, pick: Int, seed: Int, layout: PetLayout, focus: PetFocus, idle: Double, working: Bool, canPeek: Bool = true) -> Kind? {
        let options = Kind.allCases.filter { $0 != last }.map { ($0, weight($0, layout: layout, focus: focus, idle: idle, working: working, canPeek: canPeek)) }.filter { $0.1 > 0 }
        let total = options.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var r = PetAnimation.hash(pick, seed &+ 13) * total
        for (kind, w) in options { if r < w { return kind }; r -= w }
        return options.last?.0
    }

    /// The pause before the next gesture.
    func gap() -> Double { Self.draw(rhythm.between, PetAnimation.hash(picks, seed &+ 29)) }

    /// Naps last as long as the user's absence is likely to.
    static func napLength(pick: Int, seed: Int) -> Double { draw(30...60, PetAnimation.hash(pick, seed &+ 47)) }

    /// How long a pointer has to be within `enter` points to start being noticed, and beyond `leave` to be forgotten.
    static func pointerNear(distance: CGFloat, wasNear: Bool, enter: CGFloat, leave: CGFloat) -> Bool {
        distance.isFinite && distance < (wasNear ? leave : enter)
    }

    // MARK: State

    /// What the cat is doing now, for the pace of its frames and for tests.
    enum Activity: Equatable { case resting, gesture(Kind), celebrating, landing, curious, dragged }
    var activity: Activity {
        if curious > 0.5 { return dragging ? .dragged : .curious }
        if landing != nil { return .landing }
        if celebration != nil { return .celebrating }
        if let running { return .gesture(running.kind) }
        return .resting
    }
    private var dragging = false
    /// True while anything is moving beyond the idle breathing, so frames are worth drawing at the full rate.
    var isBusy: Bool {
        if celebration != nil || landing != nil || curious > 0 { return true }
        guard let r = running else { return false }
        // A nap that has settled only breathes.
        return !(r.kind == .nap && r.release == nil && r.age > 3 && r.age < r.length - 3)
    }

    /// The view came back (the island opened, the wing reappeared): whatever was under way is dropped, the
    /// cat is at home, and the rhythm carries on where it was.
    mutating func settle() {
        running = nil; celebration = nil; landing = nil; celebrationAsked = nil
        // A completion that happened while the cat was out of sight is not celebrated afterwards.
        seen = nil
        restX = 0; curious = 0; curiousAge = 0; calmSince = clock
    }

    /// The cat was just put down after a drag: it lands softly. Not while the user is busy with it again.
    mutating func land() {
        guard curious < 0.5, !dragging else { return }
        release(fade: Self.fadeUser)
        landing = Overlay(length: PetAnimation.landLength)
    }

    // MARK: Time

    mutating func update(dt rawDt: Double, _ input: PetInput, stage: PetStage) {
        let dt = min(0.2, max(0, rawDt))
        clock += dt
        lastTravel = max(1, stage.travel); lastScale = stage.scale
        // The stage can shrink while the cat is away from home; it never ends up beyond the room it has.
        restX = min(restX, max(0, stage.travel))
        dragging = input.dragging
        let interacting = input.gaze != nil || input.dragging

        // Completions: only an increase counts, and one celebration answers however many arrive together.
        if let before = seen, input.completions > before, clock - celebrationAt > Self.celebrationCooldown, celebrationAsked == nil, celebration == nil {
            celebrationAsked = clock
        }
        seen = input.completions

        // The user: look at the pointer, softly; a drag takes over at once.
        if let g = input.gaze {
            let k = min(1, dt / 0.12)
            gaze = PetGaze(dx: gaze.dx + (g.dx - gaze.dx) * k, dy: gaze.dy + (g.dy - gaze.dy) * k)
        }
        let turn = input.dragging ? Self.fadeDrag : interacting ? Self.fadeUser : 0.5
        curious = Self.follow(curious, interacting ? 1 : 0, dt / turn)
        curiousAge = interacting ? curiousAge + dt : 0
        if interacting {
            release(fade: input.dragging ? Self.fadeDrag : Self.fadeUser, hard: input.dragging)
            releaseOverlays(fade: input.dragging ? Self.fadeDrag : Self.fadeUser)
        }

        // An alert that needs attention outranks the celebration and everything decorative.
        let alerted = input.perk > 0.001
        if alerted {
            release(fade: Self.fadeAlert)
            releaseOverlays(fade: Self.fadeAlert)
        }

        // The terminal works: a cat on duty in the wing drops its idle gesture; a napper wakes anywhere.
        if input.working, let r = running, stage.layout == .compact || r.kind == .nap { release(fade: Self.fadeFocus) }
        // Typing calls for quiet: a lively gesture winds down (grooming and glancing are quiet enough to finish).
        if input.focus == .typing, let r = running, r.kind != .groom, r.kind != .glance, r.kind != .nap { release(fade: Self.fadeFocus) }
        // A napper wakes, slowly, when the user is back.
        if let r = running, r.kind == .nap, input.idle < 3 || input.focus != .free { release(fade: Self.fadeWake) }

        advance(dt)

        // A celebration takes the cat from whatever decorative thing it was doing: that fades out first, then the hop starts
        // from the sit. It waits its turn behind the user and an alert, and is forgotten if the moment passes.
        if let asked = celebrationAsked {
            if clock - asked > Self.celebrationExpiry { celebrationAsked = nil }
            else if !interacting, !alerted {
                release(fade: Self.fadeCelebration)
                if clock - asked >= Self.celebrationDelay, landing == nil, running == nil {
                    celebrationAsked = nil; celebrationAt = clock
                    celebration = Overlay(length: PetAnimation.celebrateLength)
                }
            }
        }

        // Whatever had the cat's attention, it gets a few quiet moments afterwards before anything of its own.
        if interacting || alerted || celebration != nil || landing != nil { nextAt = max(nextAt, clock + Self.calmAfter) }

        // Rest: back home if an interruption left the cat away from it; otherwise the next idle gesture is due.
        let free = !interacting && !alerted && running == nil && celebration == nil && landing == nil && celebrationAsked == nil
        if !free { calmSince = clock; return }
        if stage.layout == .header, restX != 0 {
            if clock - calmSince > 3 { startHome(stage: stage) }
            return
        }
        restX = 0
        guard clock >= nextAt else { return }
        let kind = Self.choose(after: last, pick: picks, seed: seed, layout: stage.layout, focus: input.focus, idle: input.idle, working: input.working, canPeek: stage.canPeek)
        guard let kind else { nextAt = clock + 5; return }
        start(kind, stage: stage, focus: input.focus)
    }

    /// Lets go of the running gesture: it fades out over `fade` seconds and ends. Asked again while it fades, nothing
    /// changes, except that a `hard` interruption (a drag) shortens what is left of the fade to its own.
    private mutating func release(fade: Double, hard: Bool = false) {
        guard var r = running else { return }
        if r.release == nil {
            // A stroll stops where it is (and takes a moment to turn back from its walk, unless the user is dragging it);
            // the cat stays there until it walks home.
            r.release = 0; r.fade = r.freezes && !hard ? max(fade, Self.fadeStroll) : fade
            if r.freezes { restX = holdPosition(of: r) }
            running = r
        } else if hard, r.fade - (r.release ?? 0) > fade {
            r.fade = (r.release ?? 0) + fade
            running = r
        }
    }
    private mutating func releaseOverlays(fade: Double) {
        if var c = celebration, c.release == nil { c.release = 0; c.fade = fade; celebration = c }
        if var l = landing, l.release == nil { l.release = 0; l.fade = fade; landing = l }
    }

    private func holdPosition(of r: Running) -> CGFloat {
        PetAnimation.route(r.steps, u: r.age, startX: r.startX, travel: lastTravel, scale: lastScale, time: 0, alert: 0).x
    }
    private var lastTravel: CGFloat = 1, lastScale: CGFloat = 0.5

    private mutating func advance(_ dt: Double) {
        if var r = running {
            if r.release == nil || !r.freezes { r.age += dt }
            if let release = r.release { r.release = release + dt }
            if r.age >= r.length || (r.release ?? 0) >= r.fade {
                let interrupted = r.release != nil
                running = nil
                if r.freezes, !interrupted { restX = 0 }
                if r.kind == .home { nextAt = max(nextAt, clock + 10) }
                else { last = r.kind; nextAt = clock + (interrupted ? Self.afterInterruption : gap()) }
            } else { running = r }
        }
        if var c = celebration {
            c.age += dt; if let release = c.release { c.release = release + dt }
            celebration = c.age >= c.length || (c.release ?? 0) >= c.fade ? nil : c
        }
        if var l = landing {
            l.age += dt; if let release = l.release { l.release = release + dt }
            landing = l.age >= l.length || (l.release ?? 0) >= l.fade ? nil : l
        }
    }

    /// Starts `kind` now, as the rhythm would when its time comes (previews and tests use it to see one gesture).
    mutating func start(_ kind: Kind, stage: PetStage, focus: PetFocus = .free) {
        let pick = picks
        picks += 1
        var r = Running(kind: kind, length: 0)
        switch kind {
        case .groom: r.length = PetAnimation.groomLength
        case .glance: r.length = PetAnimation.glanceLength
        case .stretch: r.length = 5.6
        case .wave: r.length = 3.4
        case .play: r.length = 6.4
        case .peek: r.length = PetAnimation.peekLength
        case .nap: r.length = Self.napLength(pick: pick, seed: seed)
        case .stroll:
            // Reading, it only strolls a little way.
            let pool = focus == .free ? Array(PetAnimation.routes.indices) : PetAnimation.shortRoutes
            r.steps = PetAnimation.routes[pool[Int(PetAnimation.hash(pick, seed &+ 61) * Double(pool.count)) % pool.count]]
            r.length = PetAnimation.length(of: r.steps)
        case .home: break
        }
        running = r
    }

    private mutating func startHome(stage: PetStage) {
        let from = restX / lastTravel
        var r = Running(kind: .home, length: 0)
        r.steps = PetAnimation.homeward(from: from); r.startX = from
        r.length = PetAnimation.length(of: r.steps)
        running = r
    }

    private static func follow(_ value: Double, _ target: Double, _ step: Double) -> Double {
        value < target ? min(target, value + step) : max(target, value - step)
    }

    // MARK: Pose

    /// The frame: the idle sit, the running gesture over it, the celebration or landing over that, the alert's
    /// reaction over that, and the user's attention over everything.
    func pose(wall: Double, alert: CGFloat, input: PetInput, stage: PetStage) -> PetPose {
        var pose = PetAnimation.sit(time: wall, alert: alert)
        pose.x = restX
        if let r = running {
            // Gestures that turn the cat round (a stretch, a nap, a walk home) fade in and out in stages: head, body, legs.
            let g = gesture(r, wall: wall, alert: alert, stage: stage)
            pose = r.kind == .nap || r.kind == .stretch || r.freezes ? pose.staged(to: g, r.weight) : pose.blended(to: g, r.weight)
            // A nap cut short loses its z's before the head has come up into them.
            if r.kind == .nap { pose.zAlpha *= r.weight * r.weight * r.weight * r.weight }
            // A stroll that is stopped stays where it was.
            if r.freezes, r.release != nil { pose.x = restX }
        }
        if let c = celebration {
            var p = PetAnimation.celebrate(u: c.age, time: wall)
            p.x = pose.x
            pose = pose.blended(to: p, c.weight * PetAnimation.ramp(c.age, 0, 0.18))
        }
        if let l = landing {
            var p = PetAnimation.land(u: l.age, time: wall)
            p.x = pose.x
            pose = pose.blended(to: p, l.weight * PetAnimation.ramp(l.age, 0, 0.12))
        }
        if input.perk > 0 { pose = PetAnimation.perked(from: pose, time: wall, amount: input.perk, age: input.perkAge) }
        if curious > 0 { pose = PetAnimation.curious(pose, gaze: gaze, amount: PetAnimation.smooth(curious), age: curiousAge, sniff: !dragging) }
        return pose
    }

    /// One gesture at its own moment.
    func gesture(_ r: Running, wall: Double, alert: CGFloat, stage: PetStage) -> PetPose {
        let compact = stage.layout == .compact
        var p: PetPose
        switch r.kind {
        case .groom: p = PetAnimation.groom(u: r.age, time: wall, alert: alert)
        case .glance: p = PetAnimation.glance(u: r.age, time: wall, alert: alert)
        case .stretch: p = PetAnimation.perform(.stretch, u: r.age, length: r.length, time: wall, alert: alert, shift: compact ? -0.5 : 0)
        case .wave: p = PetAnimation.perform(.wave, u: r.age, length: r.length, time: wall, alert: alert)
        case .play: p = PetAnimation.perform(.play, u: r.age, length: r.length, time: wall, alert: alert, shift: compact ? -0.8 : 0)
        case .nap: p = PetAnimation.perform(.sleep, u: r.age, length: r.length, time: wall, alert: alert)
        case .peek: p = PetAnimation.peek(u: r.age, time: wall, ledge: stage.ledge, shift: compact ? 3.5 : 2)
        case .stroll, .home:
            return PetAnimation.route(r.steps, u: r.age, startX: r.startX, travel: max(1, stage.travel), scale: stage.scale, time: wall, alert: alert)
        }
        p.x += restX
        return p
    }
}

/// The cat put down after a drag lands softly once the expanded header is showing it again. This keeps that moment:
/// asked about every frame, it says yes once, when the island is open with its content visible and no connection sheet
/// hides the header (so after the terminal is connected), and forgets the drop after half a minute.
struct PetLanding: Equatable {
    static let patience = 30.0
    private(set) var droppedAt: Double?

    mutating func dropped(at now: Double) { droppedAt = now }
    mutating func cancel() { droppedAt = nil }
    var isPending: Bool { droppedAt != nil }

    mutating func ready(now: Double, expanded: Bool, contentVisible: Bool, connectionSheet: Bool) -> Bool {
        guard let dropped = droppedAt else { return false }
        guard now - dropped < Self.patience else { droppedAt = nil; return false }
        guard expanded, contentVisible, !connectionSheet else { return false }
        droppedAt = nil
        return true
    }
}
