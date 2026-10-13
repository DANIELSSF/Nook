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
    /// How the user has set the cat up: who it is, how much it does, whether it cheers.
    var prefs = PetPreferences()
    /// What the Mac can spare, and the part of the day.
    var power = PetPower.normal
    var dayPart = PetDayPart.day
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
    /// The least room to the right of home for a stroll to be worth it (in points).
    static let leastTravel: CGFloat = 20
}

/// Decides what the cat does and when, and composes the frame. Pure state in, pose out: the views only feed it time
/// and the world's state, so priorities, interruptions and rhythm are all testable without a window.
///
/// Priority, highest first: the user (pointer near, a drag) → an alert that needs attention → a completion's
/// celebration → decorative gestures. A higher one interrupts a lower one with a smooth fade (a drag within a
/// tenth of a second), and a lower one never starts while a higher one is on.
///
/// What it picks among the decorative gestures depends on who the cat is (its personality), the hour, what the user is doing, how
/// recently each was done, and what the Mac can spare; and some gestures lead to another (a startled cat washes itself as if it had
/// meant to), so its day is not a list read in turn.
struct PetDirector {
    enum Kind: Int, Equatable, CaseIterable {
        case groom, glance, stretch, wave, play, peek, nap, stroll, home
        case yawn, loaf, hunt, scratch, startle, tailPlay
        var index: Int { rawValue }
    }

    /// Seconds between idle gestures, measured from the end of one to the start of the next.
    struct Rhythm: Equatable {
        var first: ClosedRange<Double>
        var between: ClosedRange<Double>
    }
    static let compactRhythm = Rhythm(first: 12...32, between: 30...75)
    /// The header only exists while the island is open, so its first gesture comes a little sooner.
    static let headerRhythm = Rhythm(first: 6...16, between: 30...75)
    /// The home's cat is the one thing on the screen to look at, so it does something every so often: its first gesture comes within a few seconds, and then one every
    /// ten to twenty (the activity the user chose still stretches or shrinks the pauses).
    static let homeRhythm = Rhythm(first: 2.5...5, between: 10...22)
    /// Real inactivity before the cat may nap, in seconds without any input (the plain cat's; see `napThreshold`).
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
        /// Which way the gesture goes where it can go either way (a glance to the right or the left, a hunt that catches or misses,
        /// a groom of the paw or of the chest), and which way the cat faces for those that turn it round.
        var variant = 0
        var facing: CGFloat = 1
        /// Seconds since it was interrupted, and how long its fade lasts; nil while it runs on.
        var release: Double?
        var fade = 0.35
        /// A sleep that nothing interrupts but `wake` (the cat went to bed because Nook opened at night): the user coming back, a working terminal, the pointer and the island closing
        /// and opening do not wake it, and it has no end of its own.
        var pinned = false
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
        var style = PetCheer.hop
        var weight: CGFloat { release.map { 1 - PetAnimation.smooth($0 / fade) } ?? 1 }
    }

    /// The cat waking up from a sleep, gently (`PetAnimation.waking`): what it wakes from (how far into its nap it was, and how long the nap, and which way it lay), how much it
    /// squints (woken by the light), and how far into the waking it is.
    struct Waking: Equatable {
        var age = 0.0
        var sleptAge: Double
        var sleptLength: Double
        var facing: CGFloat
        var squint: CGFloat
        var length: Double { PetAnimation.wakeLength(squint: squint) }
    }
    /// How long the nap of a cat put to bed at night is (it has no end: this is longer than any night), and how far into it the cat is when Nook opens: asleep for a good while.
    static let bedtimeNap = 1e9, bedtimeAge = 8.0

    let rhythm: Rhythm
    let seed: Int
    private(set) var clock = 0.0
    private(set) var nextAt: Double
    private(set) var picks = 0
    private(set) var last: Kind?
    private(set) var running: Running?
    private(set) var celebration: Overlay?
    private(set) var landing: Overlay?
    private(set) var waking: Waking?
    private var celebrationAsked: Double?
    private var celebrationAt = -1000.0
    private var seen: Int?
    /// When each kind last ended (the director's own clock), so one that was just done is less likely to be wanted again.
    private var endedAt = [Double](repeating: -1000, count: Kind.allCases.count)
    /// A gesture that follows the one that just ended (a startled cat washes itself): which, and until when it is still worth doing.
    private var followUp: (kind: Kind, expires: Double)?
    /// Where the cat sits on the stage, in points right of home. Zero in the wing.
    private(set) var restX: CGFloat = 0
    private var calmSince = 0.0
    /// How far the cat has turned toward the pointer (0...1), where it looks, and how long it has been looking.
    private(set) var curious: Double = 0
    private(set) var gaze = PetGaze()
    private(set) var curiousAge = 0.0
    /// What the user last set the cat up as: it decides the pauses, the weights and the way of cheering.
    private(set) var prefs = PetPreferences()

    init(layout: PetLayout, seed: Int = 0, rhythm custom: Rhythm? = nil) {
        rhythm = custom ?? (layout == .compact ? Self.compactRhythm : Self.headerRhythm)
        self.seed = seed
        nextAt = Self.draw(rhythm.first, PetAnimation.hash(0, seed &+ 71))
    }

    // MARK: Rules (pure)

    /// A value in `range` for `r` in 0..<1.
    static func draw(_ range: ClosedRange<Double>, _ r: Double) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * r }

    /// Everything a gesture's weight may depend on.
    struct Mood {
        var layout: PetLayout
        var focus: PetFocus
        var idle: Double
        var working: Bool
        var canPeek = true
        /// The stage has room to walk on (a stage that is all cat has none, and a stroll there would be a walk on the spot).
        var canStroll = true
        var personality = PetPersonality.curious
        var dayPart = PetDayPart.day
        var power = PetPower.normal
    }

    /// Real inactivity before this cat may nap: a sleepy one goes down after a minute, a playful one almost never does, and at night
    /// every cat does sooner.
    static func napThreshold(personality: PetPersonality, dayPart: PetDayPart) -> Double {
        var t: Double
        switch personality { case .curious: t = napAfter; case .playful: t = 240; case .calm: t = 120; case .sleepy: t = 70 }
        if dayPart == .night { t *= 0.6 }
        return t
    }

    /// How much more or less a cat of this temper (at this hour) feels like `kind`, against the plain cat.
    static func bias(_ kind: Kind, personality: PetPersonality, dayPart: PetDayPart) -> Double {
        var w: Double
        switch (personality, kind) {
        case (.curious, .glance), (.curious, .peek): w = 1.3
        case (.curious, .hunt): w = 1.2
        case (.playful, .play), (.playful, .tailPlay): w = 2
        case (.playful, .hunt): w = 2.3
        case (.playful, .stroll): w = 1.6
        case (.playful, .startle), (.playful, .wave), (.playful, .peek): w = 1.4
        case (.playful, .stretch): w = 1.2
        case (.playful, .loaf), (.playful, .nap): w = 0.45
        case (.playful, .yawn), (.playful, .groom): w = 0.7
        case (.calm, .loaf): w = 2.2
        case (.calm, .groom): w = 1.5
        case (.calm, .glance), (.calm, .yawn), (.calm, .stretch): w = 1.25
        case (.calm, .play), (.calm, .wave): w = 0.5
        case (.calm, .hunt), (.calm, .startle): w = 0.4
        case (.sleepy, .nap): w = 3
        case (.sleepy, .yawn): w = 2.8
        case (.sleepy, .loaf): w = 2.2
        case (.sleepy, .stretch), (.sleepy, .groom): w = 1.4
        case (.sleepy, .play), (.sleepy, .hunt), (.sleepy, .tailPlay): w = 0.25
        case (.sleepy, .peek), (.sleepy, .wave), (.sleepy, .stroll): w = 0.4
        default: w = 1
        }
        switch (dayPart, kind) {
        case (.night, .yawn): w *= 2
        case (.night, .nap), (.night, .loaf): w *= 1.4
        case (.night, .play), (.night, .hunt), (.night, .stroll): w *= 0.6
        case (.morning, .stretch): w *= 1.6
        case (.morning, .yawn): w *= 1.3
        case (.evening, .play): w *= 1.2
        default: break
        }
        return w
    }

    /// Whether a Mac in this power state can spare `kind`: one that is saving power leaves the cat the gestures that are cheap to
    /// draw (no chases, no games, no strolls), and a hot one leaves it none.
    static func allowed(_ kind: Kind, power: PetPower) -> Bool {
        switch power {
        case .normal: return true
        case .minimal: return false
        case .saving:
            switch kind { case .hunt, .play, .wave, .stroll, .scratch, .startle, .tailPlay, .stretch: return false; default: return true }
        }
    }

    /// How much the cat feels like `kind` right now; zero means it won't. Naps need real inactivity; typing leaves only
    /// discrete gestures, reading cuts the lively ones to a quarter, and a cat on duty in the wing does nothing. A Mac that is
    /// saving power leaves the cat the gestures that are cheap to draw.
    static func weight(_ kind: Kind, _ m: Mood) -> Double {
        if m.working && m.layout == .compact { return 0 }
        func lively(_ w: Double, walk: Bool = false) -> Double { m.focus == .free ? w : m.focus == .reading ? w * (walk ? 0.1 : 0.25) : 0 }
        /// Quiet enough to carry on while the user reads, and to be seen at the corner of the eye while they type.
        func quiet(_ w: Double, typing: Double) -> Double { m.focus == .free ? w : m.focus == .reading ? w * 0.7 : w * typing }
        if !allowed(kind, power: m.power) { return 0 }
        let base: Double
        switch kind {
        case .nap: base = m.idle >= napThreshold(personality: m.personality, dayPart: m.dayPart) && m.focus == .free && !m.working ? 6 : 0
        case .groom: base = 3
        case .glance: base = 2.5
        case .yawn: base = quiet(1.8, typing: 0.35)
        case .stretch: base = lively(2)
        case .wave: base = lively(1.2)
        case .play: base = lively(2)
        case .peek: base = m.canPeek ? lively(1.5) : 0
        case .loaf: base = lively(1.6)
        case .hunt: base = lively(1.6)
        case .scratch: base = lively(1.4)
        case .startle: base = lively(0.45)
        case .tailPlay: base = lively(0.8)
        case .stroll: base = m.layout == .header && m.canStroll ? lively(3, walk: true) : 0
        case .home: base = 0
        }
        return base * bias(kind, personality: m.personality, dayPart: m.dayPart)
    }

    /// The old way in: the plain cat in the daytime.
    static func weight(_ kind: Kind, layout: PetLayout, focus: PetFocus, idle: Double, working: Bool, canPeek: Bool = true,
                       personality: PetPersonality = .curious, dayPart: PetDayPart = .day, power: PetPower = .normal) -> Double {
        weight(kind, Mood(layout: layout, focus: focus, idle: idle, working: working, canPeek: canPeek, personality: personality, dayPart: dayPart, power: power))
    }

    /// The next gesture: a weighted pick that never repeats the one just done. `recent` is a factor per kind for how long ago it was
    /// last done (1 for one that has not been for a while). Nil when nothing is wanted right now.
    static func choose(after last: Kind?, pick: Int, seed: Int, _ m: Mood, recent: (Kind) -> Double = { _ in 1 }) -> Kind? {
        let options = Kind.allCases.filter { $0 != last }.map { ($0, weight($0, m) * recent($0)) }.filter { $0.1 > 0 }
        let total = options.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var r = PetAnimation.hash(pick, seed &+ 13) * total
        for (kind, w) in options { if r < w { return kind }; r -= w }
        return options.last?.0
    }

    static func choose(after last: Kind?, pick: Int, seed: Int, layout: PetLayout, focus: PetFocus, idle: Double, working: Bool, canPeek: Bool = true,
                       personality: PetPersonality = .curious, dayPart: PetDayPart = .day, power: PetPower = .normal) -> Kind? {
        choose(after: last, pick: pick, seed: seed, Mood(layout: layout, focus: focus, idle: idle, working: working, canPeek: canPeek, personality: personality, dayPart: dayPart, power: power))
    }

    /// The pause before the next gesture: what the rhythm says, stretched or shrunk by how active the cat is and who it is.
    func gap() -> Double {
        let raw = Self.draw(rhythm.between, PetAnimation.hash(picks, seed &+ 29))
        return raw * (prefs.activity.pauseScale ?? 1) * Self.pauseScale(prefs.personality)
    }
    /// A playful cat has less time between gestures; a calm or sleepy one more.
    static func pauseScale(_ personality: PetPersonality) -> Double {
        switch personality { case .curious: 1; case .playful: 0.75; case .calm: 1.2; case .sleepy: 1.35 }
    }

    /// Naps last as long as the user's absence is likely to.
    static func napLength(pick: Int, seed: Int) -> Double { draw(30...60, PetAnimation.hash(pick, seed &+ 47)) }

    /// How long a lie-down lasts, and whether it has kneading in it.
    static func loafLength(pick: Int, seed: Int, kneads: Bool) -> Double { draw(kneads ? 15...24 : 9...18, PetAnimation.hash(pick, seed &+ 53)) }

    /// The gestures that follow the one that just ended, if any: `(kind, delay, chance)`. Whether they do is decided by a hash of the
    /// pick, so a day is repeatable.
    static func followUp(after kind: Kind, variant: Int) -> (kind: Kind, delay: ClosedRange<Double>, chance: Double)? {
        switch kind {
        case .startle: return (.groom, 0.8...1.6, 0.65)
        case .hunt: return variant == 1 ? (.groom, 0.9...1.6, 0.7) : (.glance, 0.8...1.4, 0.3)
        case .stretch: return (.yawn, 0.4...0.9, 0.35)
        case .groom: return (.glance, 0.6...1.2, 0.15)
        default: return nil
        }
    }

    /// How long a pointer has to be within `enter` points to start being noticed, and beyond `leave` to be forgotten.
    static func pointerNear(distance: CGFloat, wasNear: Bool, enter: CGFloat, leave: CGFloat) -> Bool {
        distance.isFinite && distance < (wasNear ? leave : enter)
    }

    /// How a cat of this temper cheers.
    static func cheer(for personality: PetPersonality) -> PetCheer {
        switch personality { case .curious: .hop; case .playful: .doubleHop; case .calm, .sleepy: .content }
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
        if celebration != nil || landing != nil || waking != nil { return true }
        // A cat asleep for the night does not follow the pointer: it only breathes.
        if curious > 0 && !isPinnedAsleep { return true }
        guard let r = running else { return false }
        return !settled(r)
    }
    /// A nap or a lie-down that has settled only breathes.
    private func settled(_ r: Running) -> Bool {
        (r.kind == .nap || r.kind == .loaf) && r.release == nil && r.age > 3.2 && r.age < r.length - 3.2
    }

    /// The longest a frame may wait right now, for the beat of what the cat is doing: nil while it only breathes. A gesture can begin
    /// its next beat at any moment, and the pointer, an alert or a hop need the picture to follow.
    var frameCeiling: Double? {
        if waking != nil { return 1.0 / 12 }
        if (curious > 0 && !isPinnedAsleep) || celebration != nil || landing != nil { return 1.0 / 20 }
        guard let r = running else { return nil }
        return settled(r) ? nil : 1.0 / 8
    }

    /// How much of the cat's small life (its blinks, flicks and glances) goes on right now: all of it at rest, little while a gesture has
    /// the body, none while it sleeps or hops. Each layer that takes the cat over does so in and out smoothly, and so does this: the
    /// small movements under way when a gesture ends must not jump in size.
    var lifeWeight: CGFloat {
        // Waking is all of the cat: its eyes and ears are doing what the waking says.
        if waking != nil { return 0 }
        var taken: CGFloat = CGFloat(min(1, curious)) * 0.6
        if dragging { taken = 1 }
        if let c = celebration { taken = max(taken, c.weight * PetAnimation.ramp(c.age, 0, 0.18) * (1 - PetAnimation.ramp(c.age, c.length - 0.4, c.length))) }
        if let l = landing { taken = max(taken, l.weight * (1 - PetAnimation.ramp(l.age, l.length - 0.3, l.length))) }
        if let r = running {
            let presence = r.weight * PetAnimation.ramp(r.age, 0, 0.8) * (1 - PetAnimation.ramp(r.age, r.length - 0.8, r.length))
            taken = max(taken, presence * (r.kind == .nap ? 1 : 0.65))
        }
        return 1 - taken
    }

    /// The view came back (the island opened, the wing reappeared): whatever was under way is dropped, the
    /// cat is at home, and the rhythm carries on where it was.
    mutating func settle() {
        // A cat put to bed for the night is still in it when the island opens and closes.
        if !isPinnedAsleep { running = nil }
        waking = nil; celebration = nil; landing = nil; celebrationAsked = nil; followUp = nil
        // A completion that happened while the cat was out of sight is not celebrated afterwards.
        seen = nil
        restX = 0; curious = 0; curiousAge = 0; calmSince = clock
    }

    /// The cat was just put down after a drag: it lands softly. Not while the user is busy with it again.
    mutating func land() {
        guard curious < 0.5, !dragging, !isPinnedAsleep, waking == nil else { return }
        release(fade: Self.fadeUser)
        landing = Overlay(length: PetAnimation.landLength)
    }

    // MARK: Sleeping and waking

    /// The cat is in bed for the night (`PetBedtime`): it is asleep, deep in its sleep, and stays asleep through everything but `wake`.
    var isPinnedAsleep: Bool { running?.pinned == true }

    /// The cat is asleep, in a nap of its own or in bed for the night, and not already waking: a click has something to wake.
    var isAsleep: Bool {
        guard waking == nil, let r = running else { return false }
        return r.kind == .nap && r.release == nil
    }

    /// Puts the cat to bed: it is asleep at once, deep in its sleep, and nothing wakes it but `wake`.
    mutating func fallAsleep(facing: CGFloat = 1) {
        var r = Running(kind: .nap, length: Self.bedtimeNap)
        r.age = Self.bedtimeAge; r.pinned = true; r.facing = facing
        running = r; waking = nil
        celebration = nil; landing = nil; celebrationAsked = nil; followUp = nil
    }

    /// Wakes a sleeping cat, gently (`PetAnimation.waking`): it does not sit up at once. `age` is how far into the waking it is already, for a cat woken while it was out of sight (a waking
    /// that has run its course is over at once); `squint` (0...1), a cat woken by the light. Returns whether there was a sleeper to wake: a cat that is up has nothing to wake.
    @discardableResult
    mutating func wake(age: Double = 0, squint: CGFloat = 0) -> Bool {
        guard isAsleep, let r = running else { return false }
        picks += 1
        var w = Waking(sleptAge: r.age, sleptLength: r.length, facing: r.facing, squint: min(1, max(0, squint)))
        running = nil
        if age >= w.length {
            wokeUp()
            return true
        }
        w.age = max(0, age)
        waking = w
        return true
    }

    /// The waking is over: the cat is up and settled, and goes on with its day (it will not nap again at once).
    private mutating func wokeUp() {
        last = .nap
        endedAt[Kind.nap.index] = clock
        nextAt = max(nextAt, clock + Self.draw(4...9, PetAnimation.hash(picks, seed &+ 127)))
        calmSince = clock
    }

    // MARK: Time

    mutating func update(dt rawDt: Double, _ input: PetInput, stage: PetStage) {
        let dt = min(PetPlayer.longestStep, max(0, rawDt))
        clock += dt
        lastTravel = max(1, stage.travel); lastScale = stage.scale
        // The user's choices: a change in how active the cat should be moves its next gesture to match.
        if input.prefs.activity != prefs.activity || input.prefs.personality != prefs.personality {
            prefs = input.prefs
            if prefs.activity.pauseScale != nil { nextAt = min(nextAt, clock + gap()) }
        }
        prefs = input.prefs
        // The stage can shrink while the cat is away from home; it never ends up beyond the room it has.
        restX = min(restX, max(0, stage.travel))
        dragging = input.dragging
        let interacting = input.gaze != nil || input.dragging

        // Completions: only an increase counts, and one celebration answers however many arrive together. A cat that was asked
        // not to cheer takes it in stride.
        if let before = seen, input.completions > before, input.prefs.celebrates, clock - celebrationAt > Self.celebrationCooldown, celebrationAsked == nil, celebration == nil {
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
            followUp = nil
        }

        // An alert that needs attention outranks the celebration and everything decorative.
        let alerted = input.perk > 0.001
        if alerted {
            release(fade: Self.fadeAlert)
            releaseOverlays(fade: Self.fadeAlert)
            followUp = nil
        }

        // The terminal works: a cat on duty in the wing drops its idle gesture; a napper wakes anywhere.
        if input.working, let r = running, stage.layout == .compact || r.kind == .nap { release(fade: Self.fadeFocus) }
        // Typing calls for quiet: a lively gesture winds down (grooming, glancing and yawning are quiet enough to finish).
        if input.focus == .typing, let r = running, r.kind != .groom, r.kind != .glance, r.kind != .nap, r.kind != .yawn { release(fade: Self.fadeFocus) }
        // A napper wakes, slowly, when the user is back.
        if let r = running, r.kind == .nap, input.idle < 3 || input.focus != .free { release(fade: Self.fadeWake) }
        // A power state that cannot spare a gesture ends it.
        if input.power != .normal, let r = running, r.kind != .home, !Self.allowed(r.kind, power: input.power) { release(fade: Self.fadeFocus) }

        advance(dt)

        // A celebration takes the cat from whatever decorative thing it was doing: that fades out first, then the hop starts
        // from the sit. It waits its turn behind the user and an alert, and is forgotten if the moment passes.
        if let asked = celebrationAsked {
            if clock - asked > Self.celebrationExpiry { celebrationAsked = nil }
            else if !interacting, !alerted {
                release(fade: Self.fadeCelebration)
                if clock - asked >= Self.celebrationDelay, landing == nil, running == nil {
                    celebrationAsked = nil; celebrationAt = clock
                    let style = Self.cheer(for: input.prefs.personality)
                    celebration = Overlay(length: PetAnimation.cheerLength(style), style: style)
                }
            }
        }

        // Whatever had the cat's attention, it gets a few quiet moments afterwards before anything of its own.
        if interacting || alerted || celebration != nil || landing != nil { nextAt = max(nextAt, clock + Self.calmAfter) }

        // Rest: back home if an interruption left the cat away from it; otherwise the next idle gesture is due.
        let free = !interacting && !alerted && running == nil && celebration == nil && landing == nil && celebrationAsked == nil && waking == nil
        if !free { calmSince = clock; return }
        if stage.layout == .header, restX != 0 {
            if clock - calmSince > 3 { startHome(stage: stage) }
            return
        }
        restX = 0
        guard clock >= nextAt else { return }
        let mood = Mood(layout: stage.layout, focus: input.focus, idle: input.idle, working: input.working, canPeek: stage.canPeek, canStroll: stage.travel >= PetStage.leastTravel,
                        personality: input.prefs.personality, dayPart: input.dayPart, power: input.power)
        // A follow-up gesture (the startled cat washes itself) goes first, if it is still the thing to do and it is allowed.
        if let follow = followUp {
            followUp = nil
            if clock <= follow.expires, input.prefs.activity.pauseScale != nil, Self.weight(follow.kind, mood) > 0 {
                start(follow.kind, stage: stage, focus: input.focus); return
            }
        }
        // A cat that was asked to do nothing on its own starts nothing.
        guard input.prefs.activity.pauseScale != nil else { nextAt = clock + 10; return }
        let kind = Self.choose(after: last, pick: picks, seed: seed, mood, recent: { [clock, endedAt] kind in
            let since = clock - endedAt[kind.index]
            return 0.2 + 0.8 * min(1, max(0, since / 180))
        })
        guard let kind else { nextAt = clock + 5; return }
        start(kind, stage: stage, focus: input.focus)
    }

    /// Lets go of the running gesture: it fades out over `fade` seconds and ends. Asked again while it fades, nothing
    /// changes, except that a `hard` interruption (a drag) shortens what is left of the fade to its own.
    private mutating func release(fade: Double, hard: Bool = false) {
        guard var r = running, !r.pinned else { return }
        if r.release == nil {
            // A stroll stops where it is (and takes a moment to turn back from its walk, unless the user is dragging it);
            // the cat stays there until it walks home. A gesture that takes the whole body a long way from the sit (a nap, a hunt, a
            // stretch, a lie-down) lets go over at least half a second, and a sleeper wakes over its usual time: none of them
            // springs back in a few frames, unless it is dragged.
            r.release = 0
            r.fade = r.freezes && !hard ? max(fade, Self.fadeStroll) : fade
            if !hard { r.fade = max(r.fade, Self.minimumFade(of: r.kind)) }
            if r.freezes { restX = holdPosition(of: r) }
            running = r
        } else if hard, r.fade - (r.release ?? 0) > fade {
            r.fade = (r.release ?? 0) + fade
            running = r
        }
    }
    /// The shortest a gesture lets go over, unless it is dragged.
    static func minimumFade(of kind: Kind) -> Double {
        switch kind { case .nap: fadeWake; case .hunt, .stretch, .loaf: 0.5; default: 0 }
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
                else {
                    last = r.kind; endedAt[r.kind.index] = clock
                    nextAt = clock + (interrupted ? Self.afterInterruption : gap())
                    // What comes next, if this one leads to something: a woken cat yawns; a startled one washes itself.
                    if interrupted {
                        if r.kind == .nap { followUp = (.yawn, clock + 6); nextAt = clock + 0.3 }
                    } else if let f = Self.followUp(after: r.kind, variant: r.variant), PetAnimation.hash(picks, seed &+ 89) < f.chance {
                        followUp = (f.kind, clock + 8)
                        nextAt = clock + Self.draw(f.delay, PetAnimation.hash(picks, seed &+ 91))
                    }
                }
            } else { running = r }
        }
        if var w = waking {
            w.age += dt
            if w.age >= w.length { waking = nil; wokeUp() } else { waking = w }
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
        // A cat in bed, or waking, starts nothing.
        guard !isPinnedAsleep, waking == nil else { return }
        let pick = picks
        picks += 1
        var r = Running(kind: kind, length: 0)
        func roll(_ salt: Int) -> Double { PetAnimation.hash(pick, seed &+ salt) }
        r.facing = roll(97) < 0.5 ? 1 : -1
        switch kind {
        case .groom: r.length = PetAnimation.groomLength; r.variant = roll(83) < 0.35 ? 1 : 0
        case .glance: r.length = PetAnimation.glanceLength; r.variant = Int(roll(83) * 4) % 4
        case .stretch: r.length = 7.0
        case .wave: r.length = 3.4
        case .play: r.length = 6.4
        case .peek: r.length = PetAnimation.peekLength
        case .nap: r.length = Self.napLength(pick: pick, seed: seed)
        case .yawn: r.length = PetAnimation.yawnLength
        case .scratch: r.length = PetAnimation.scratchLength
        case .startle: r.length = PetAnimation.startleLength; r.variant = roll(83) < 0.5 ? 0 : 1
        case .tailPlay: r.length = PetAnimation.tailPlayLength
        case .loaf: r.variant = roll(83) < 0.55 ? 1 : 0; r.length = Self.loafLength(pick: pick, seed: seed, kneads: r.variant == 1)
        case .hunt:
            r.variant = roll(83) < 0.45 ? 1 : 0; r.length = PetAnimation.huntLength(variant: r.variant)
            // In the header the room is to the right of home: the cat hunts that way.
            if stage.layout == .header { r.facing = 1 }
        case .stroll:
            // Reading, it only strolls a little way.
            let pool = focus == .free ? Array(PetAnimation.routes.indices) : PetAnimation.shortRoutes
            r.steps = PetAnimation.routes[pool[Int(roll(61) * Double(pool.count)) % pool.count]]
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
        // Waking is the whole cat, from the sleep it was in to the sit: nothing else is laid over it.
        if let w = waking {
            var p = PetAnimation.waking(u: w.age, time: wall, sleptAge: w.sleptAge, sleptLength: w.sleptLength, squint: w.squint)
            if w.facing < 0 { p = p.mirrored() }
            p.x = restX
            return p
        }
        var pose = PetAnimation.sit(time: wall, alert: alert)
        pose.x = restX
        if let r = running {
            // Gestures that turn the cat round (a stretch, a nap, a hunt, a walk home) fade in and out in stages: head, body, legs.
            // A cat that was asleep wakes the other way round, head first.
            let g = gesture(r, wall: wall, alert: alert, stage: stage)
            switch r.kind {
            case .nap, .loaf: pose = pose.staged(to: g, r.weight, order: r.release == nil ? .headFirst : .legsFirst)
            case .stretch, .hunt, .stroll, .home: pose = pose.staged(to: g, r.weight)
            default: pose = pose.blended(to: g, r.weight)
            }
            // A nap cut short loses its z's before the head has come up into them (a waking cat's head leads, so they go sooner).
            if r.kind == .nap { pose.zAlpha *= pow(r.weight, r.release == nil ? 4 : 12) }
            // A stroll that is stopped stays where it was.
            if r.freezes, r.release != nil { pose.x = restX }
        }
        if let c = celebration {
            var p = PetAnimation.celebrate(u: c.age, time: wall, style: c.style)
            p.x = pose.x
            pose = pose.blended(to: p, c.weight * PetAnimation.ramp(c.age, 0, 0.18))
        }
        if let l = landing {
            // It is put down from where the pointer let go of it: it is in the air from its first frame (the view showed the cat in the
            // pointer's hand until then), never rising there from the sit.
            var p = PetAnimation.land(u: l.age, time: wall)
            p.x = pose.x
            pose = pose.blended(to: p, l.weight)
        }
        if input.perk > 0 { pose = PetAnimation.perked(from: pose, time: wall, amount: input.perk, age: input.perkAge) }
        // A cat in bed does not turn to look at the pointer.
        if curious > 0, !isPinnedAsleep { pose = PetAnimation.curious(pose, gaze: gaze, amount: PetAnimation.smooth(curious), age: curiousAge, sniff: !dragging) }
        return pose
    }

    /// One gesture at its own moment.
    func gesture(_ r: Running, wall: Double, alert: CGFloat, stage: PetStage) -> PetPose {
        let compact = stage.layout == .compact
        var p: PetPose
        switch r.kind {
        case .groom: p = PetAnimation.groom(u: r.age, time: wall, alert: alert, variant: r.variant)
        case .glance: p = PetAnimation.glance(u: r.age, time: wall, alert: alert, variant: r.variant)
        case .stretch: p = PetAnimation.perform(.stretch, u: r.age, length: r.length, time: wall, facing: r.facing, alert: alert, shift: compact ? -0.5 : 0)
        case .wave: p = PetAnimation.perform(.wave, u: r.age, length: r.length, time: wall, alert: alert)
        case .play: p = PetAnimation.perform(.play, u: r.age, length: r.length, time: wall, alert: alert, shift: compact ? -0.8 : 0)
        case .nap: p = PetAnimation.perform(.sleep, u: r.age, length: r.length, time: wall, facing: r.facing, alert: alert)
        case .peek: p = PetAnimation.peek(u: r.age, time: wall, ledge: stage.ledge, shift: compact ? 3.5 : 2)
        case .yawn: p = PetAnimation.yawn(u: r.age, time: wall)
        case .scratch: p = PetAnimation.scratch(u: r.age, time: wall)
        case .startle: p = PetAnimation.startle(u: r.age, time: wall, variant: r.variant)
        case .tailPlay: p = PetAnimation.tailPlay(u: r.age, time: wall)
        case .loaf: p = PetAnimation.loafing(u: r.age, length: r.length, time: wall, variant: r.variant, facing: r.facing)
        case .hunt: p = PetAnimation.hunt(u: r.age, length: r.length, time: wall, variant: r.variant, facing: r.facing, shift: compact ? -1.2 : 0)
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
