import Foundation

/// What the Mac is doing around the cat at one moment, in plain values (no views, no model): the input a driver turns into
/// `PetInput`. A scenario is a whole working day of those, so the cat's cost can be measured on a realistic mix.
struct PetWorldSample: Equatable {
    var working = false
    /// 0 free, 1 reading, 2 typing (the raw values of `PetFocus`).
    var focus = 0
    /// Seconds since the user last touched the Mac at all.
    var idle = 0.0
    /// The pointer is near the cat.
    var near = false
    var completions = 0
    var perk = 0.0, perkAge = 0.0
    /// For the report only: which part of the day this is.
    var label = Label.free

    enum Label: String, CaseIterable { case free, typing, reading, away, hover }
}

/// A deterministic day: the user alternates between being at the Mac (typing, reading, thinking) and away from it, Claude works
/// in bursts that finish with a completion (and now and then an alert), and the pointer visits the cat from time to time.
struct PetScenario {
    struct Segment { var start: Double; var end: Double; var kind: Kind; var idle = 0.0 }
    enum Kind { case free, typing, reading, away }

    let duration: Double
    private(set) var activity: [Segment] = []
    private(set) var work: [(start: Double, end: Double, dots: Bool)] = []
    private(set) var hovers: [(start: Double, end: Double)] = []
    private(set) var completionTimes: [Double] = []
    private(set) var alerts: [Double] = []

    /// The moments something discrete changes (a burst of work starts, the pointer arrives): a real view is told about each at
    /// once and draws a frame, so a simulation steps there as well.
    var events: [Double] {
        (work.flatMap { [$0.start, $0.end] } + hovers.flatMap { [$0.start, $0.end] } + completionTimes + alerts).sorted()
    }

    struct Mix {
        /// Minutes at the Mac, then away from it.
        var present: ClosedRange<Double> = 25...70
        var away: ClosedRange<Double> = 3...20
        /// Relative weight of each way of being at the Mac, and how long each lasts, in seconds.
        var typing = (weight: 35.0, seconds: 30.0...150.0)
        var reading = (weight: 35.0, seconds: 20.0...100.0)
        var thinking = (weight: 22.0, seconds: 20.0...120.0)
        /// Watching Claude work without touching anything: long, and the idle counter runs past the nap threshold.
        var watching = (weight: 8.0, seconds: 90.0...420.0)
        /// Minutes between bursts of Claude's work, and how long each lasts.
        var quiet: ClosedRange<Double> = 4...25
        var burst: ClosedRange<Double> = 1...15
        /// Minutes between visits of the pointer, and seconds each stays.
        var hoverEvery: ClosedRange<Double> = 4...14
        var hoverFor: ClosedRange<Double> = 3...12
        /// The share of the work that the notch shows as three dots (a terminal with no spinner Nook can read) instead of Claude's glyph.
        var dotsShare = 0.4
    }

    /// Hours of the day for the collapsed island's cat (always on screen).
    static func day(hours: Double, seed: UInt64, mix: Mix = Mix()) -> PetScenario {
        var rng = SplitMix64(seed: seed)
        var s = PetScenario(duration: hours * 3600)
        func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * rng.unit() }
        // At the Mac and away.
        var t = 0.0, present = true
        while t < s.duration {
            let span = (present ? r(mix.present) : r(mix.away)) * 60
            let end = min(s.duration, t + span)
            if present {
                var u = t
                while u < end {
                    let total = mix.typing.weight + mix.reading.weight + mix.thinking.weight + mix.watching.weight
                    var pick = rng.unit() * total
                    let kind: Kind, range: ClosedRange<Double>
                    if pick < mix.typing.weight { kind = .typing; range = mix.typing.seconds }
                    else { pick -= mix.typing.weight
                        if pick < mix.reading.weight { kind = .reading; range = mix.reading.seconds }
                        else { pick -= mix.reading.weight
                            if pick < mix.thinking.weight { kind = .free; range = mix.thinking.seconds } else { kind = .free; range = mix.watching.seconds } } }
                    let stop = min(end, u + r(range))
                    s.activity.append(Segment(start: u, end: stop, kind: kind, idle: kind == .typing ? 0.5 + 2 * rng.unit() : kind == .reading ? 1 + 4 * rng.unit() : 8 + 12 * rng.unit()))
                    u = stop
                }
            } else {
                s.activity.append(Segment(start: t, end: end, kind: .away, idle: 15 + 20 * rng.unit()))
            }
            t = end; present.toggle()
        }
        // Claude's work.
        t = r(mix.quiet) * 60 * 0.4
        var burst = 0
        while t < s.duration {
            let end = min(s.duration, t + r(mix.burst) * 60)
            s.work.append((t, end, Double(burst % 5) / 5 < mix.dotsShare)); burst += 1
            if end < s.duration {
                s.completionTimes.append(end + 0.1)
                if burst % 3 == 0 { s.alerts.append(end + 0.3) }
            }
            t = end + r(mix.quiet) * 60
        }
        // The pointer visits, only while the user is at the Mac.
        t = r(mix.hoverEvery) * 60
        while t < s.duration {
            let end = t + r(mix.hoverFor)
            if let seg = s.segment(at: t), seg.kind != .away, end < seg.end { s.hovers.append((t, end)) }
            t = end + r(mix.hoverEvery) * 60
        }
        return s
    }

    /// The island open for `sessions` visits of `minutes` each, back to back (the header's cat only exists while it is).
    /// At the open panel the user mostly reads or types; the pointer hardly ever comes near the cat.
    static func openIsland(sessions: Int, minutes: Double, seed: UInt64) -> PetScenario {
        var rng = SplitMix64(seed: seed)
        var s = PetScenario(duration: Double(sessions) * minutes * 60)
        func r(_ range: ClosedRange<Double>) -> Double { range.lowerBound + (range.upperBound - range.lowerBound) * rng.unit() }
        var t = 0.0
        while t < s.duration {
            let end = min(s.duration, t + r(20...90))
            let pick = rng.unit()
            let kind: Kind = pick < 0.35 ? .typing : pick < 0.9 ? .reading : .free
            s.activity.append(Segment(start: t, end: end, kind: kind, idle: kind == .typing ? 0.5 + 2 * rng.unit() : kind == .reading ? 1 + 4 * rng.unit() : 8 + 12 * rng.unit()))
            t = end
        }
        t = r(30...150)
        var burst = 0
        while t < s.duration {
            let end = min(s.duration, t + r(60...300))
            s.work.append((t, end, false)); burst += 1
            if end < s.duration { s.completionTimes.append(end + 0.1) }
            t = end + r(90...400)
        }
        t = r(120...400)
        while t < s.duration {
            let end = t + r(2...6)
            s.hovers.append((t, end)); t = end + r(120...400)
        }
        return s
    }

    private func segment(at t: Double) -> Segment? {
        var low = 0, high = activity.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if t < activity[mid].start { high = mid - 1 } else if t >= activity[mid].end { low = mid + 1 } else { return activity[mid] }
        }
        return activity.last
    }

    /// Whether the three dots are what the notch shows for the work going on at `t`.
    func dots(at t: Double) -> Bool { work.first { t >= $0.start && t < $0.end }?.dots ?? false }

    func sample(at t: Double) -> PetWorldSample {
        var w = PetWorldSample()
        let seg = segment(at: t)
        if let seg {
            switch seg.kind {
            case .typing: w.focus = 2; w.idle = seg.idle; w.label = .typing
            case .reading: w.focus = 1; w.idle = seg.idle; w.label = .reading
            case .free: w.focus = 0; w.idle = seg.idle + (t - seg.start); w.label = .free
            case .away: w.focus = 0; w.idle = seg.idle + (t - seg.start); w.label = .away
            }
        }
        w.working = work.contains { t >= $0.start && t < $0.end }
        w.near = hovers.contains { t >= $0.start && t < $0.end }
        if w.near { w.label = .hover }
        w.completions = completionTimes.filter { $0 <= t }.count
        if let a = alerts.last(where: { $0 <= t }), t - a < 5.5 {
            let u = t - a
            func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
            w.perk = smooth(u / 0.3) * (1 - smooth((u - 4.7) / 0.8)); w.perkAge = u
        }
        return w
    }
}

/// A small deterministic random source (the scenario must be the same on every run and in every build).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0..<1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
