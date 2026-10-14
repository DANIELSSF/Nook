import SwiftUI
import AppKit

// What Claude's status line adds to the usage card (`ClaudeUsage.filled(from:)`), as the card says it: which figures came from there ("en vivo"), the figures only
// it has (the context window, the spend limit's dollars) and the glance the usage button's tip gives at the limits without opening the panel.
//
//   ClaudeLiveUsage.upToDate   the readings that still describe the present: a limit whose reset has passed belongs to a window that is over
//   UsageLive                  the words and figures of it (plain values, so they are tested without a window)
//   UsageLiveMark              the small dot beside a figure that came from the status line, and what it says when the pointer rests on it
//   UsageSnapshot              the words of a figure that is Claude's last reading instead (the per-model weeks, which the status line never sends): how old it is
//   UsageSnapshotMark          the small ring beside such a figure, hollow where the live dot is filled
//   UsageGlance                what the usage button's tip says of the limits
//
// The status line's figures are the freshest Claude gave Nook, not a stream: each carries the time it was read, and the tip of its dot says how long ago that was.
// Claude's own reading is older still: it is as old as the last time Claude asked for the usage (opening /usage), which can be hours, so the card says its age in plain
// sight once it is old enough to matter.

extension ClaudeLiveUsage {
    /// What still describes the present. A limit whose reset time has passed is of a window that is over (Claude itself leaves such a limit out of what it sends), so it
    /// goes; with nothing left of the limits their reading goes too. Nil when nothing is left at all.
    func upToDate(at now: Date) -> ClaudeLiveUsage? {
        var live = self
        if var limits = live.limits {
            func current(_ limit: ClaudeStatusPayload.Limit?) -> ClaudeStatusPayload.Limit? {
                guard let limit else { return nil }
                if let resets = limit.resetsAt, resets <= now { return nil }
                return limit
            }
            limits.fiveHour = current(limits.fiveHour)
            limits.sevenDay = current(limits.sevenDay)
            limits.spendLimit = current(limits.spendLimit)
            live.limits = limits.isEmpty ? nil : limits
            if live.limits == nil { live.limitsAt = nil }
        }
        live.saved = live.saved?.upToDate(at: now)
        return live.session == nil && live.limits == nil ? nil : live
    }
}

// MARK: - Words and figures

enum UsageLive {
    /// What the dot says it is, under "En vivo".
    static let words = "Claude se lo pasa a Nook al responder; no hace falta abrir /usage."

    /// How long ago, in a few words: "hace unos segundos", "hace 3 min", "hace 2 h", "hace 2 d".
    static func ago(_ seconds: TimeInterval) -> String {
        let span = max(0, seconds)
        if span < 45 { return "hace unos segundos" }
        if span < 3600 { return "hace \(max(1, Int((span / 60).rounded()))) min" }
        if span < 86_400 { return "hace \(Int((span / 3600).rounded())) h" }
        return "hace \(Int((span / 86_400).rounded())) d"
    }

    /// A count of tokens in a few characters, for the size of a window: 200 000 is "200k", 1 000 000 is "1M", 1 500 000 is "1,5M".
    static func tokens(_ count: Int) -> String {
        func short(_ value: Double, _ unit: String) -> String {
            value.rounded() == value ? "\(Int(value))\(unit)" : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") + unit
        }
        if count >= 1_000_000 { return short(Double(count) / 1_000_000, "M") }
        if count >= 1000 { return short(Double(count) / 1000, "k") }
        return "\(count)"
    }

    /// An amount of money as the card writes it: "$50", "$12.30".
    static func money(_ value: Double) -> String {
        value.rounded() == value ? "$\(Int(value))" : String(format: "$%.2f", value)
    }

    /// The period of the spend limit, in Spanish; nil for one this does not know.
    static func period(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "monthly", "month": "mensual"
        case "weekly", "week": "semanal"
        case "daily", "day": "diario"
        case "yearly", "year", "annual": "anual"
        default: nil
        }
    }

    /// The spend limit's dollars, which the panel's bar does not say: "$12.30 de $50 · mensual". Nil when Claude gave no dollars.
    static func spend(_ limit: ClaudeStatusPayload.Limit?) -> String? {
        guard let limit, let used = limit.usedUSD else { return nil }
        var words = limit.limitUSD.map { "\(money(used)) de \(money($0))" } ?? "\(money(used)) gastados"
        if let period = period(limit.period) { words += " · " + period }
        return words
    }

    /// An effort level as the island names it, in lower case for a sentence: "alto", "muy alto". Nil for a level it does not know.
    static func effort(_ raw: String?) -> String? {
        raw.flatMap { ClaudeEffort(rawValue: $0.lowercased()) }.map { $0.title.lowercased() }
    }

    /// What the session's context cell says on hover: the window it is of, the model and its effort. Nil when Claude said none of them.
    static func contextTip(_ payload: ClaudeStatusPayload?, now: Date = Date()) -> NookTip? {
        guard let payload, let used = payload.context?.usedPercentage else { return nil }
        var parts: [String] = []
        if let size = payload.context?.size { parts.append("Ventana de \(tokens(size)) tokens") }
        if let model = payload.modelName ?? payload.modelID.map(UsageFigures.modelName) { parts.append(model) }
        if let level = effort(payload.effort) { parts.append("esfuerzo \(level)") }
        guard !parts.isEmpty else { return nil }
        return NookTip("Contexto", value: "\(Int(used.rounded())) % usado", detail: parts.joined(separator: " · "))
    }

    /// A reset in the few words the card's tiles use, for a limit that resets at `date`: "Reinicia a las 1 p. m.", "Reinicia el 13 oct · 6 a. m.".
    static func reset(_ date: Date, dated: Bool, now: Date, zone: TimeZone) -> String {
        let english = ClaudeUsage.resets(date, dated: dated, now: now, zone: zone)
        return UsageFigures.shortReset(UsageFigures.zoneSplit(UsageWords.resets(english)).words)
    }
}

// MARK: - The mark

/// A small dot beside a figure that Claude's status line gave Nook instead of the panel's own text. It says nothing until the pointer rests on it: then, how long ago Claude
/// gave it, and that no /usage is needed.
struct UsageLiveMark: View {
    /// When Claude gave it (nil when that is not known).
    var since: Date?
    var metrics: UsageMetrics
    /// What tells this mark's tip from another's.
    var id: String
    var now = Date()

    var body: some View {
        Circle().fill(UsageMetrics.mint.opacity(0.9)).frame(width: metrics(4.5), height: metrics(4.5))
            .padding(metrics(3.5))
            .contentShape(Circle())
            .nookTip(NookTip("En vivo", value: since.map { UsageLive.ago(now.timeIntervalSince($0)) }, detail: UsageLive.words), id: "usage-live-" + id)
            .accessibilityHidden(true)
    }
}

// MARK: - Claude's last reading

/// The words of a figure that is Claude's own last reading of the usage (`ClaudeUsage.Source.snapshot`) and not the status line's: a limit the status line never sends (the week of
/// one model), or one Claude's reading is the newer for. It is as old as the last time Claude asked, so the card says how old. Plain values, so they are tested without a window.
enum UsageSnapshot {
    /// What the ring says it is, under "Última lectura de Claude".
    static let words = "Claude la guarda cada vez que consulta tu uso (al abrir /usage)."
    /// What the limit of a model adds to it: why it can never be live.
    static let perModel = "La barra de estado no envía los límites por modelo."
    /// How old the reading may be before the card says so beside the figure, and not only when the pointer rests on the ring: what the usage button's tip waits for too.
    static let staleAfter = UsageGlance.staleAfter

    /// How long ago Claude took the reading: "hace 25 min". Nil when that is not known.
    static func age(_ since: Date?, now: Date) -> String? {
        since.map { UsageLive.ago(now.timeIntervalSince($0)) }
    }

    /// The line the card puts once under its limits, with a ring as its key, when the reading is old enough to matter: "Última lectura de Claude, hace 25 min". Nil for a fresher one
    /// (the ring's tip has its age), and for one whose age is not known.
    static func note(_ since: Date?, now: Date) -> String? {
        guard let since, now.timeIntervalSince(since) > staleAfter else { return nil }
        return spoken(since: since, now: now)
    }

    /// The note under a section of limits: said once for the whole section, when any of its limits is Claude's last reading and that reading is old enough to matter. A dense card
    /// has no room for it and leaves it to the rings' tips.
    static func note(for meters: [ClaudeUsage.Meter], since: Date?, now: Date, dense: Bool = false) -> String? {
        guard !dense, meters.contains(where: { $0.source == .snapshot }) else { return nil }
        return note(since, now: now)
    }

    /// What the ring says when the pointer rests on it, for the limit `title` ("Current week (Fable)").
    static func tip(limit title: String, since: Date?, now: Date) -> NookTip {
        NookTip("Última lectura de Claude", value: age(since, now: now), detail: UsageGlance.modelName(title) == nil ? words : words + " " + perModel)
    }

    /// The tip as it is drawn: the same words, with "/usage" kept in one piece where the line breaks (`UsageFigures.unbroken`).
    static func drawnTip(limit title: String, since: Date?, now: Date) -> NookTip {
        let words = tip(limit: title, since: since, now: now)
        return NookTip(words.title, value: words.value, detail: words.detail.map(UsageFigures.unbroken))
    }

    /// What is spoken after the limit's figures, where a live one says "en vivo": "Última lectura de Claude, hace 25 min".
    static func spoken(since: Date?, now: Date) -> String {
        "Última lectura de Claude" + (age(since, now: now).map { ", " + $0 } ?? "")
    }
}

/// The ring itself, hollow where `UsageLiveMark`'s dot is filled: the figure beside it is a record, not a live one.
struct UsageSnapshotRing: View {
    var metrics: UsageMetrics

    var body: some View {
        Circle().strokeBorder(UsageMetrics.secondary, lineWidth: metrics(1.1)).frame(width: metrics(5.5), height: metrics(5.5))
    }
}

/// A small ring beside a figure that is Claude's last reading instead of the status line's. It says nothing until the pointer rests on it: then, how long ago Claude took the reading
/// and why this one is not live (and the limits' section says it in plain sight, once, when the reading is old: `UsageSnapshot.note`).
struct UsageSnapshotMark: View {
    /// The limit it is beside ("Current week (Fable)").
    var title: String
    /// When Claude took the reading (nil when that is not known).
    var since: Date?
    var metrics: UsageMetrics
    /// What tells this mark's tip from another's.
    var id: String
    var now = Date()

    var body: some View {
        // The ring's outside is the dot's size and the room around it the same, so one stands where the other would.
        UsageSnapshotRing(metrics: metrics)
            .padding(metrics(3))
            .contentShape(Circle())
            .nookTip(UsageSnapshot.drawnTip(limit: title, since: since, now: now), id: "usage-saved-" + id)
            .accessibilityHidden(true)
    }
}

// MARK: - The glance

/// What the usage button's tip says when Claude's status line has given Nook the limits: where the session and the week stand and when they reset, without opening
/// /usage. Nothing for a tab with no limits (the tip is then the button's own).
enum UsageGlance {
    /// How old a reading may be before the tip says so.
    static let staleAfter: TimeInterval = 15 * 60

    static func tip(from live: ClaudeLiveUsage?, now: Date = Date(), zone: TimeZone = .current) -> NookTip? {
        guard let live = live?.upToDate(at: now), let limits = live.limits else { return nil }
        var figures: [String] = []
        var lines: [String] = []
        for (name, limit, dated) in [("sesión", limits.fiveHour, false), ("semana", limits.sevenDay, true)] {
            guard let limit else { continue }
            figures.append("\(name) \(Int(limit.usedPercentage.rounded(.down))) %")
            if let date = limit.resetsAt {
                let words = UsageLive.reset(date, dated: dated, now: now, zone: zone)
                lines.append(UsageFigures.unbroken(name.prefix(1).uppercased() + name.dropFirst() + ": " + words.prefix(1).lowercased() + words.dropFirst()))
            }
        }
        guard !figures.isEmpty else { return nil }
        // How old the reading is, when it is old enough to matter.
        if let at = live.limitsAt, now.timeIntervalSince(at) > staleAfter { lines.append("Dato de " + UsageLive.ago(now.timeIntervalSince(at))) }
        // The per-model weeks, from Claude's own latest usage reading: the status line never sends them.
        let models = (live.saved?.limits ?? []).compactMap { limit -> (String, Double)? in
            guard let name = modelName(limit.title) else { return nil }
            return (name, limit.percent)
        }
        figures += models.map { "\($0.0) \(Int($0.1.rounded(.down))) %" }
        if let saved = live.saved, !models.isEmpty, now.timeIntervalSince(saved.fetchedAt) > staleAfter {
            lines.append(models.map(\.0).joined(separator: ", ") + ": dato de " + UsageLive.ago(now.timeIntervalSince(saved.fetchedAt)))
        }
        lines.append("Pulsa para ver el detalle")
        return NookTip("Uso y límites", value: figures.joined(separator: " · "), detail: lines.joined(separator: "\n"))
    }

    /// "Fable" for "Current week (Fable)"; nil for the week of all models and anything that isn't a model's week.
    static func modelName(_ title: String) -> String? {
        guard title.hasPrefix("Current week ("), title.hasSuffix(")") else { return nil }
        let name = String(title.dropFirst("Current week (".count).dropLast())
        return name.isEmpty || name == "all models" ? nil : name
    }
}
