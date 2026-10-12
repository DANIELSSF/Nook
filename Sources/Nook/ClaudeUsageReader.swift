import Foundation
import os

// Claude's usage panel, read whole. Claude draws /usage (Settings › Usage) in a box the height of its terminal, with its tab row
// fixed on top and the rest scrolling under it: ↓ and ↑ move it one row (its `scrollBy(±1)`), and a "↑" or "↓" at the right edge
// of the first or last row says more lies beyond. In a short terminal most of the panel is below. Nook keeps every part of the
// panel it has seen as one, so its card can show all of it:
//
//   ClaudePanelPage      one screen's panel: the head that stays put (edge, tab row) and the rows that scroll, marks taken off
//   UsagePanelStitcher   pages laid over one another where their rows agree: the panel as far as it has been seen
//   ClaudeUsageReader    a tab's panel over time: the stitched one while Claude's usage panel is open, the screen's for any other
//   ClaudeUsageWalk      in a Nook session, scrolls the panel to its end and back through tmux, so it is read without the user
//
// A Terminal tab is never walked: a key to Terminal needs Accessibility and brings it to the front. Its panel grows with what the
// user scrolls through themselves.

let usageLog = Logger(subsystem: "dev.nook.mac", category: "usage")

/// One screen's panel, split where Claude splits it.
struct ClaudePanelPage: Equatable {
    /// The lines that stay put: the panel's edge, the tab row and the blank line under it.
    var head: [String]
    /// The rows that scroll, without Claude's marks.
    var body: [String]
    var moreAbove: Bool
    var moreBelow: Bool

    /// Nil for a panel without a tab row at its top: only Claude's Settings scroll this way.
    init?(_ text: String) {
        let lines = text.components(separatedBy: "\n").map(Self.trimmedEnd)
        guard let tabs = lines.prefix(6).firstIndex(where: ClaudeComposer.isTabRow) else { return nil }
        var start = tabs + 1
        while start < lines.count, lines[start].isEmpty { start += 1 }
        head = Array(lines[..<start])
        var body = Array(lines[start...])
        moreAbove = false; moreBelow = false
        // Claude draws "↑" over the first row it shows and "↓" over the last, at the right edge.
        if let first = body.first, let unmarked = Self.unmarked(first, by: Self.upMarks) { body[0] = unmarked; moreAbove = true }
        if let last = body.indices.last, let unmarked = Self.unmarked(body[last], by: Self.downMarks) { body[last] = unmarked; moreBelow = true }
        self.body = body
    }

    /// The page as a panel's text again (without its marks).
    var text: String { (head + body).joined(separator: "\n") }

    /// Claude is still filling something in ("Loading usage data…", "Scanning local sessions…", "Refreshing…"): what replaces
    /// the line moves the rows under it.
    var isLoading: Bool { body.contains(where: Self.loading) }

    static func loading(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).range(of: #"^(Loading|Scanning|Refreshing)\b.*…$"#, options: .regularExpression) != nil
    }

    private static let upMarks: Set<Character> = ["↑", "▲", "⌃"]
    private static let downMarks: Set<Character> = ["↓", "▼", "⌄"]

    private static func unmarked(_ line: String, by marks: Set<Character>) -> String? {
        guard let last = line.last, marks.contains(last) else { return nil }
        return trimmedEnd(String(line.dropLast()))
    }

    private static func trimmedEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
    }
}

/// The pages of one panel laid over one another: each goes where its rows agree with the rows read so far, its own rows (the
/// newer) replacing theirs. Rows are compared with their numbers masked, so a figure Claude updates meanwhile ("last activity
/// 1m 11s ago") does not stop a page from fitting; a few rows that differ more are allowed in a long overlap.
///
/// What was read is never dropped while the panel stays open. A page that shares no rows with it (the user scrolled the
/// console several screens at once, or the panel was first seen halfway down) is placed by the sections it shows ("Session",
/// "Current week (all models)", "What's contributing…", a table's title), in panel order, as a piece of its own with an unread
/// gap beside it. Pieces join as soon as a page overlaps both, and the panel is complete only once it is one piece from its
/// top to its end.
struct UsagePanelStitcher: Equatable {
    /// Rows read in one run, and their keys (`key`).
    struct Piece: Equatable {
        var rows: [String]
        var keys: [String]
    }

    private(set) var head: [String] = []
    /// In panel order, an unread gap between each two.
    private var pieces: [Piece]
    /// The first piece starts where the panel does.
    private(set) var sawTop = false
    /// …and the last one ends where it does.
    private(set) var sawBottom = false
    /// The piece Claude's view of the panel is in, and where its first row is in that piece.
    private(set) var current = 0
    private(set) var offset = 0

    var complete: Bool { pieces.count == 1 && sawTop && sawBottom }
    /// Every row read, piece after piece.
    var rows: [String] { pieces.flatMap(\.rows) }
    /// The pieces' rows, for a look at the gaps.
    var pieceRows: [[String]] { pieces.map(\.rows) }

    init(_ page: ClaudePanelPage) {
        head = page.head
        pieces = [Piece(rows: page.body, keys: page.body.map(Self.key))]
        sawTop = !page.moreAbove
        sawBottom = !page.moreBelow
    }

    /// Lays `page` where its rows agree with the piece Claude's view is in (the nearest such place to `hint`, the view itself by
    /// default). Returns where its first row went, counted in that piece as it was (negative when it reaches above it), or nil
    /// with nothing changed when it fits nowhere there. The walk's own step: its pages always overlap.
    @discardableResult mutating func merge(_ page: ClaudePanelPage, near hint: Int? = nil) -> Int? {
        let pageKeys = page.body.map(Self.key)
        guard let at = Self.placement(of: pageKeys, in: pieces[current].keys, near: hint ?? offset) else { return nil }
        lay(page, keys: pageKeys, into: current, at: at, truncating: false)
        return at
    }

    /// Lays a page read from the screen into what was read, wherever it goes: by its rows in any piece, by a section both show, or
    /// as a piece of its own in panel order. Nothing read is lost.
    mutating func absorb(_ page: ClaudePanelPage) {
        // The whole panel on one screen: nothing else to know.
        if !page.moreAbove, !page.moreBelow { self = UsagePanelStitcher(page); return }
        let pageKeys = page.body.map(Self.key)
        var best: (piece: Int, at: Int, score: Int)?
        for (index, piece) in pieces.enumerated() {
            guard let at = Self.placement(of: pageKeys, in: piece.keys, near: index == current ? offset : 0) else { continue }
            let score = Self.agreement(of: pageKeys, in: piece.keys, at: at) + (index == current ? 1 : 0)
            if best.map({ score > $0.score }) ?? true { best = (index, at, score) }
        }
        if best == nil, let anchored = anchor(pageKeys) { best = (anchored.piece, anchored.at, 0) }
        if let best { lay(page, keys: pageKeys, into: best.piece, at: best.at, truncating: false); return }
        // Read nowhere yet: a piece of its own where its sections go, its top first and its end last.
        var index: Int
        if !page.moreAbove { index = 0 }
        else if !page.moreBelow { index = pieces.count }
        else if let rank = Self.rank(of: pageKeys) {
            index = pieces.indices.reduce(0) { at, piece in Self.rank(of: pieces[piece].keys).map { $0 <= rank ? piece + 1 : at } ?? at }
        } else { index = current + 1 }
        // Nothing goes above the panel's top or below its end, as read.
        if page.moreAbove, sawTop { index = max(index, 1) }
        if page.moreBelow, sawBottom { index = min(index, pieces.count - 1) }
        pieces.insert(Piece(rows: page.body, keys: pageKeys), at: index)
        if index == 0 { sawTop = !page.moreAbove }
        if index == pieces.count - 1 { sawBottom = !page.moreBelow }
        current = index; offset = 0
        head = page.head
    }

    /// Lays `page` at `at` without looking for its place, dropping whatever was read below it: for a page Claude changed where it
    /// stood (a section that finished loading), which is known not to have scrolled.
    mutating func replace(with page: ClaudePanelPage, at: Int) {
        lay(page, keys: page.body.map(Self.key), into: current, at: min(max(at, 0), pieces[current].rows.count), truncating: true)
    }

    private mutating func lay(_ page: ClaudePanelPage, keys pageKeys: [String], into index: Int, at: Int, truncating: Bool) {
        let piece = pieces[index]
        let (joined, shift) = Self.joined(piece, Piece(rows: page.body, keys: pageKeys), at: at, keepingBase: false, truncating: truncating)
        let end = at + page.body.count
        // A page reaching past what was read says whether there is more there. One inside it only confirms an end: Claude's marks
        // follow a scroll a moment late, and a missing mark there is not proof.
        if index == 0 { if at < 0 { sawTop = !page.moreAbove } else if at == 0, !page.moreAbove { sawTop = true } }
        if index == pieces.count - 1 {
            if truncating || end > piece.rows.count { sawBottom = !page.moreBelow } else if end == piece.rows.count, !page.moreBelow { sawBottom = true }
        }
        pieces[index] = joined
        head = page.head
        current = index; offset = at + shift
        joinNeighbours()
    }

    /// The piece Claude's view is in joins the pieces beside it once their rows agree: the gap between them is read.
    private mutating func joinNeighbours() {
        if current + 1 < pieces.count, let at = Self.placement(of: pieces[current + 1].keys, in: pieces[current].keys, near: pieces[current].rows.count) {
            pieces[current] = Self.joined(pieces[current], pieces[current + 1], at: at, keepingBase: true, truncating: false).piece
            pieces.remove(at: current + 1)
        }
        if current > 0, let at = Self.placement(of: pieces[current - 1].keys, in: pieces[current].keys, near: -pieces[current - 1].rows.count) {
            let (joined, shift) = Self.joined(pieces[current], pieces[current - 1], at: at, keepingBase: true, truncating: false)
            pieces[current] = joined
            pieces.remove(at: current - 1)
            current -= 1; offset += shift
        }
    }

    /// `other` laid over `base` with its first row at `at`, and how far `base`'s rows moved down (rows `other` adds above them).
    /// In the overlap `base`'s rows stay when `keepingBase` (they are the newer), `other`'s otherwise; `truncating` drops what
    /// `base` had below `other`.
    private static func joined(_ base: Piece, _ other: Piece, at: Int, keepingBase: Bool, truncating: Bool) -> (piece: Piece, shift: Int) {
        let low = min(0, at), end = at + other.rows.count
        let high = truncating ? end : max(base.rows.count, end)
        var rows: [String] = [], keys: [String] = []
        rows.reserveCapacity(high - low); keys.reserveCapacity(high - low)
        for index in low..<high {
            let inBase = index >= 0 && index < base.rows.count, inOther = index >= at && index < end
            if inOther, !(keepingBase && inBase) { rows.append(other.rows[index - at]); keys.append(other.keys[index - at]) }
            else { rows.append(base.rows[index]); keys.append(base.keys[index]) }
        }
        return (Piece(rows: rows, keys: keys), -low)
    }

    /// A section's title the page shares with one piece, once in each: the page goes where it lines up.
    private func anchor(_ pageKeys: [String]) -> (piece: Int, at: Int)? {
        for (row, key) in pageKeys.enumerated() where Self.isAnchor(key) && pageKeys.filter({ $0 == key }).count == 1 {
            for (index, piece) in pieces.enumerated() {
                let found = piece.keys.indices.filter { piece.keys[$0] == key }
                if found.count == 1 { return (index, found[0] - row) }
            }
        }
        return nil
    }

    /// How many rows of text agree at `at`.
    private static func agreement(of page: [String], in rows: [String], at: Int) -> Int {
        (max(0, -at)..<min(page.count, rows.count - at)).reduce(0) { $0 + (!page[$1].isEmpty && page[$1] == rows[at + $1] ? 1 : 0) }
    }

    /// The titles of the panel's sections and tables, as keys: what places a page that shares no other row with what was read.
    static func isAnchor(_ key: String) -> Bool { anchorRank(key) != nil }

    /// Where a row of the panel's own words sits in it, top to bottom; nil for a row that could be anywhere.
    static func anchorRank(_ key: String) -> Int? {
        if key == "Session" || key.hasPrefix("Session (") { return 0 }
        if key.hasPrefix("Usage by model:") { return 5 }
        if key.hasSuffix("skill-listing footprint") { return 10 }
        if key == "Current session" || key.hasPrefix("Current session · ") { return 20 }
        if key == "Current week (all models)" || key.hasPrefix("Current week (all models) · ") { return 21 }
        if key.hasPrefix("Current week") { return 22 }
        if key.hasPrefix("What"), key.contains("contributing to your limits usage") { return 30 }
        if key.hasSuffix("% of usage") { return 34 }
        if key == "Usage credits" { return 37 }
        return nil
    }

    /// Where a row sits in the panel, for ordering a page by any row it shows (the titles above, and rows only one section has).
    private static func rowRank(_ key: String) -> Int? {
        if let rank = anchorRank(key) { return rank }
        if key.hasPrefix("Total cost:") { return 1 }
        if key.hasPrefix("Total duration (API)") { return 2 }
        if key.hasPrefix("Total duration (wall)") { return 3 }
        if key.hasPrefix("Total code changes:") { return 4 }
        if key.contains(" input, "), key.contains(" output") { return 6 }
        if key.hasPrefix("Prompt cache") { return 7 }
        if key.hasSuffix("tok/turn") { return 11 }
        if key.hasPrefix("Approximate, based on local sessions") { return 31 }
        if key.hasPrefix("Last #"), key.contains(" · ") { return 32 }
        if key.hasPrefix("#% of your usage") { return 33 }
        if key.hasSuffix(" to day · w to week") || key == "d to day · w to week" { return 36 }
        return nil
    }

    /// A page's place in the panel: its first row that has one.
    private static func rank(of keys: [String]) -> Int? { keys.lazy.compactMap(rowRank).first }

    /// The panel as one screen's text: its head, every row read (a blank line where a gap is), and Claude's own marks where
    /// something lies unread above or below Claude's view.
    var text: String {
        let width = (head + rows).map(\.count).max() ?? 0
        let mark = { (symbol: String) in String(repeating: " ", count: max(0, width - 2)) + symbol }
        let above = !sawTop || current > 0, below = !sawBottom || current < pieces.count - 1
        let body = pieces.enumerated().flatMap { index, piece in (index > 0 ? [""] : []) + piece.rows }
        return (head + (above ? [mark("↑")] : []) + body + (below ? [mark("↓")] : [])).joined(separator: "\n")
    }

    /// A row as compared: numbers masked ("1m 11s" is "#m #s"), runs of spaces as one, no indent.
    static func key(_ line: String) -> String {
        var out = ""
        var space = true, digit = false
        for character in line {
            if character.isWhitespace { if !space { out.append(" ") }; space = true; digit = false; continue }
            if character.isNumber || (digit && (character == "." || character == ",")) {
                if !digit { out.append("#") }
                digit = true; space = false
                continue
            }
            out.append(character); space = false; digit = false
        }
        if out.last == " " { out.removeLast() }
        return out
    }

    /// Where a page's rows agree with the rows read: at least three rows of text in common (all of them on a page with fewer),
    /// and at most one row in six that differs. The best agreement wins; between equals, the place nearest `hint`.
    static func placement(of page: [String], in rows: [String], near hint: Int) -> Int? {
        let solid = page.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
        guard solid > 0, !rows.isEmpty else { return nil }
        let needed = min(3, solid)
        var best: (at: Int, score: Int, distance: Int)?
        for at in (1 - page.count)..<rows.count {
            var matches = 0, conflicts = 0
            for index in max(0, -at)..<min(page.count, rows.count - at) {
                let read = rows[at + index], seen = page[index]
                if read.isEmpty, seen.isEmpty { continue }
                if read == seen { matches += 1 } else { conflicts += 1 }
            }
            guard matches >= needed, conflicts <= matches / 6 else { continue }
            let score = matches - 3 * conflicts, distance = abs(at - hint)
            if best.map({ score > $0.score || (score == $0.score && distance < $0.distance) }) ?? true { best = (at, score, distance) }
        }
        return best?.at
    }
}

/// A tab's panel as the island shows it (`TerminalSession.panel`): while Claude's usage panel is open, every part of it read since
/// it opened (the screen's page laid into the rest); any other panel, as the screen has it. What was read goes when the panel
/// closes or Settings moves to another tab. Used on the main thread.
final class ClaudeUsageReader {
    private(set) var stitcher: UsagePanelStitcher?
    /// Counts the usage panels read: one more each time the panel opens again, comes back from another tab, or no longer fits
    /// what was read of it.
    private(set) var generation = 0
    private var startedAt = Date.distantPast
    private var goneSince: Date?
    private var escapedAt: Date?
    /// The user pressed a key on the panel since it opened: the scrolling is theirs, Nook does not walk it.
    private(set) var touched = false
    /// The walk under way (`ClaudeUsageWalk`), and how many ran since the panel opened.
    private(set) var walk: ClaudeUsageWalk?
    private var walks = 0
    private var walkedGeneration: Int?
    private var recheckPending = false
    /// The rows of the usage panel's scrolling part the screen showed last.
    private(set) var pageRows: Int?
    /// When "más" last scrolled the usage panel, until the page it scrolled to is read.
    private var scrolledAt: Date?

    /// How long a panel missing from the screen is kept (a reading caught while Claude redraws misses it).
    static var hold: TimeInterval = 1.5
    /// How long after the panel appears a walk may start: Claude fills in its sections in the first moments.
    static var walkDelay: TimeInterval = 0.4
    static let walksPerOpening = 2
    /// How long "más" waits for the page it scrolled to before it may scroll again.
    static var scrollWait: TimeInterval = 1.5

    /// The panel as read so far, when it is the usage panel.
    var text: String? { stitcher?.text }

    /// The panel to show for one reading of the screen (`found` is the screen's panel, nil when it shows none).
    func read(_ found: String?, now: Date = Date()) -> String? {
        guard let found else { missing(now); return nil }
        if let since = goneSince, now.timeIntervalSince(since) > Self.hold { close() }
        goneSince = nil
        // While Nook walks the panel only the walk's pages are laid in: a screen read meanwhile may show one it already left, or
        // one caught halfway through a redraw. The walk itself stops when the panel goes or changes.
        if walk != nil, let current = stitcher { return current.text }
        guard let page = ClaudePanelPage(found) else { forget(); return found }
        let panel = ClaudePanel(found)
        // Settings moved to another tab: what was read of Usage no longer stands. A page that does not say which tab is open is
        // still the usage panel read so far (a window of its advice has no clue of its own).
        if let tab = Self.openTab(panel), tab != "usage" { forget(); return found }
        if var current = stitcher {
            current.absorb(page)
            // The page "más" scrolled to is in: it may scroll again.
            if current != stitcher { scrolledAt = nil }
            stitcher = current; pageRows = page.body.count
            return current.text
        }
        guard ClaudeUsage(panel) != nil else { forget(); return found }
        pageRows = page.body.count
        scrolledAt = nil
        stitcher = UsagePanelStitcher(page)
        generation += 1
        startedAt = now
        return stitcher?.text
    }

    /// The tab Settings say is open, lowercased, when they say.
    private static func openTab(_ panel: ClaudePanel) -> String? {
        for row in panel.rows {
            guard case .tabs(_, let names, let active) = row else { continue }
            return active.flatMap { names.indices.contains($0) ? names[$0].lowercased() : nil }
        }
        return nil
    }

    /// A key the user pressed on the panel (`AppModel.press`): a walk stops before it, and none starts again until the panel
    /// closes. Esc closes the panel: what was read goes as soon as the screen shows it closed.
    func userPressed(_ key: TerminalKey, now: Date = Date()) {
        touched = true
        walk?.cancel()
        if key == .escape { escapedAt = now }
    }

    /// How many rows "más" scrolls Claude's usage panel (`AppModel.scrollPanel`): a screen of it less the rows the next page needs
    /// in common with this one to be laid after it (a quarter of the screen, at least 5: three rows of text must agree, and some
    /// are blank). 1 for any other panel, where ↓ may move a cursor rather than scroll.
    var scrollStep: Int {
        guard stitcher != nil, let rows = pageRows else { return 1 }
        return max(1, rows - max(5, rows / 4))
    }

    /// Whether "más" may scroll now: not before the page its last press scrolled to was read, or a second press would jump past
    /// what was read, which would then be lost.
    func mayScroll(now: Date = Date()) -> Bool { scrolledAt.map { now.timeIntervalSince($0) > Self.scrollWait } ?? true }

    /// "más" scrolled the usage panel.
    func scrolled(now: Date = Date()) { if stitcher != nil { scrolledAt = now } }

    /// When a walk of the panel read so far is due (now or later), or nil when none is wanted: the whole panel is already read,
    /// one runs or ran for it, the user has been pressing keys on it, or enough ran since it opened.
    func walkDue() -> Date? {
        guard let stitcher, !stitcher.complete, walk == nil, !touched, walkedGeneration != generation, walks < Self.walksPerOpening else { return nil }
        return startedAt.addingTimeInterval(Self.walkDelay)
    }

    /// One later look at `walkDue` at a time.
    func scheduleRecheck() -> Bool {
        guard !recheckPending else { return false }
        recheckPending = true
        return true
    }
    func recheckDone() { recheckPending = false }

    func begin(_ walk: ClaudeUsageWalk) {
        self.walk = walk
        walkedGeneration = generation
        walks += 1
    }

    /// What the walk has read so far, while its panel is still the one open.
    func adopt(_ stitched: UsagePanelStitcher, from walk: ClaudeUsageWalk) {
        guard walk === self.walk, walk.generation == generation, stitcher != nil else { return }
        stitcher = stitched
    }

    func finish(_ walk: ClaudeUsageWalk) {
        if walk === self.walk { self.walk = nil }
    }

    private func missing(_ now: Date) {
        guard stitcher != nil || touched || walks > 0 else { return }
        // Closed with Esc: the screen saying so is enough.
        if let escapedAt, now.timeIntervalSince(escapedAt) < ClaudePanelHold.askedWindow { return close() }
        if let since = goneSince { if now.timeIntervalSince(since) > Self.hold { close() } } else { goneSince = now }
    }

    /// The panel closed: the next one is read afresh, walked again, and the user's keys on this one no longer count.
    private func close() {
        forget()
        touched = false; walks = 0; walkedGeneration = nil
        goneSince = nil; escapedAt = nil
    }

    /// Another of Settings' tabs, or another panel: what was read of the usage panel no longer stands.
    private func forget() {
        walk?.cancel()
        stitcher = nil
        pageRows = nil; scrolledAt = nil
    }
}

/// Scrolls Claude's usage panel in a Nook session to its end and back through tmux, reading each page on the way: tmux types the
/// keys into the session's pane, so nothing comes to the front and no permission is needed. Only ↓ and ↑ are ever pressed (they
/// scroll the panel one row each; past its ends they do nothing), never Enter, Esc or a tab key.
///
/// The first press is a single ↓ that has to move the panel by whole rows; after it each press scrolls about two thirds of a
/// screen, so consecutive pages overlap and are laid where their rows agree. Should Claude take a burst of keys as fewer, the
/// walk sees it scroll less than asked and goes on one key per write. Keys go a few per write, and before each write the
/// screen has to show the panel still: a key never lands in anything else (a question Claude asked meanwhile would take ↑ and
/// ↓ as a change of answer; `AppModel.answer` reads its highlight again anyway). The walk stops, leaving the panel to the
/// user, on a cancel (anything the user sends the tab, a key, an answer, a message or an interrupt: `TerminalSession.userInput`;
/// `cancel()` waits for a key being sent, so theirs always lands after the walk's last), when the panel goes or changes, when a
/// page fits nowhere, when ↓ moves nothing, or past its limits. Unless cancelled or gone, it scrolls the panel back to where
/// it was.
final class ClaudeUsageWalk {
    /// What the walk reads and presses.
    struct Terminal {
        /// The terminal's screen, as plain text; nil when it cannot be read.
        var screen: () -> String?
        /// Presses the key `count` times; false when it could not.
        var press: (_ key: TerminalKey, _ count: Int) -> Bool
        var pause: (TimeInterval) -> Void
        var now: () -> Date
    }

    struct Limits {
        /// Keys pressed in all, the way back included: the walk itself takes at most half, so the way back always fits.
        var keys = 400
        /// The whole walk, the way back included: every wait ends by then.
        var duration: TimeInterval = 20
        /// Between two readings of the screen.
        var poll: TimeInterval = 0.06
        /// How long Claude has to answer a press (it draws slower while it works).
        var reaction: TimeInterval = 2.5
        /// How long a section still loading is waited for.
        var loading: TimeInterval = 6
        /// Between two writes of keys.
        var spacing: TimeInterval = 0.015
        /// Keys in one write, the screen read again before each: a dialog that took the panel's place meanwhile gets this many at
        /// most (and `AppModel.answer` reads its highlight again before answering it).
        var chunk = 4
    }

    enum Outcome: Equatable {
        /// The panel was read from top to bottom.
        case complete
        /// It stopped before: what was read stays, marked as not the whole panel.
        case partial(String)
        case cancelled
        /// The panel closed or the screen could not be read.
        case gone
    }

    let generation: Int
    let limits: Limits
    private let lock = NSLock()
    private var cancelled = false
    /// When the walk must be over, the way back included (`Limits.duration`). Only the walk's own thread uses it.
    private var stopBy = Date.distantFuture

    init(generation: Int, limits: Limits = Limits()) {
        self.generation = generation
        self.limits = limits
    }

    /// Stops the walk before its next key. Returns once no key of the walk is on its way.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// The terminal of a Nook session's pane: its visible screen, and keys typed by tmux.
    static func tmux(executable: String, arguments: [String], target: String) -> Terminal {
        Terminal(
            screen: {
                guard let (status, output) = try? Shell.run(executable, arguments + ["capture-pane", "-p", "-J", "-t", target]), status == 0 else { return nil }
                return output
            },
            press: { key, count in
                (try? Shell.run(executable, arguments + ["send-keys", "-t", target, "-N", String(count), key.tmuxName]).0) == 0
            },
            pause: { Thread.sleep(forTimeInterval: $0) },
            now: Date.init)
    }

    /// The panel on a screen, when it shows Claude's Settings.
    static func page(in screen: String) -> ClaudePanelPage? {
        ClaudeComposer.split(screen).panel.flatMap(ClaudePanelPage.init)
    }

    /// Walks the panel; `progress` gets what is read after each page. Blocks: run it off the main thread.
    func run(_ terminal: Terminal, progress: (UsagePanelStitcher) -> Void) -> Outcome {
        stopBy = terminal.now().addingTimeInterval(limits.duration)
        // The walk leaves itself the time to take the panel back.
        let walkBy = stopBy.addingTimeInterval(-limits.reaction)
        guard var page = opening(terminal, by: walkBy), ClaudeUsage(ClaudePanel(page.text)) != nil else { return .gone }
        var stitcher = UsagePanelStitcher(page)
        progress(stitcher)
        guard !stitcher.complete else { return .complete }
        // Where the user's view of the panel is: the walk takes it back there. It counts in the stitched rows, which grow at the
        // top when the walk reads above where it started.
        var home = stitcher.offset
        var keys = 0, step = 0
        // Claude took a burst of keys as fewer: one key per write from then on.
        var spaced = false
        var outcome = Outcome.complete
        walking: for key in [TerminalKey.down, .up] {
            while !(key == .down ? stitcher.sawBottom : stitcher.sawTop) {
                if isCancelled { return .cancelled }
                // One row first, to see that ↓ scrolls; then about two thirds of a screen at a time.
                let rows = page.body.count
                let count = step == 0 ? 1 : max(1, (rows - max(4, rows / 3)) / step)
                if terminal.now() >= walkBy || keys + count > limits.keys / 2 { outcome = .partial("limits"); break walking }
                let before = stitcher.offset
                guard press(key, count, one: spaced, over: page, terminal) else { return refusal(terminal) }
                keys += count
                let sign = key == .down ? 1 : -1
                switch reaction(to: page, in: stitcher, near: before + sign * count * max(step, 1), by: walkBy, terminal) {
                case .gone: return isCancelled ? .cancelled : .gone
                case .still:
                    if isCancelled { return .cancelled }
                    // The press moved nothing: this panel does not scroll the way the walk expects. The user still can.
                    outcome = .partial(step == 0 ? "no scroll" : "stuck"); break walking
                case .lost:
                    if isCancelled { return .cancelled }
                    outcome = .partial("lost"); break walking
                case .moved(let next, let at, var stitched):
                    let moved = abs(at - before)
                    if step == 0 { step = max(1, moved / count) }
                    // Fewer rows than keys with more still to go that way: the keys arrived as fewer.
                    if !spaced, count > 1, moved < count * step, key == .down ? next.moreBelow : next.moreAbove { spaced = true }
                    home += max(0, -at)
                    if next.isLoading, let loaded = loaded(after: next, by: walkBy, terminal) { stitched.replace(with: loaded, at: stitched.offset); page = loaded } else { page = next }
                    stitcher = stitched
                    progress(stitcher)
                }
            }
        }
        if isCancelled { return .cancelled }
        // Back to where the user's view was, in one go: past the panel's ends a key does nothing.
        let back = stitcher.offset - home
        if back != 0, step > 0 {
            let presses = (abs(back) + step - 1) / step
            if press(back > 0 ? .up : .down, presses, one: spaced, over: page, terminal),
               case .moved(_, _, let stitched) = reaction(to: page, in: stitcher, near: home, by: stopBy, terminal) {
                stitcher = stitched
                progress(stitcher)
            }
        }
        if isCancelled { return .cancelled }
        return stitcher.complete ? .complete : outcome == .complete ? .partial("unfinished") : outcome
    }

    /// Presses `key` `count` times, in writes of `Limits.chunk` keys (`one`: one key each), while the walk was not cancelled and the
    /// screen, read again before every write, shows the panel: the very page the walk last read before the first, the same
    /// Settings (their edge and tab row) before the others, which find it scrolled. A dialog that takes the panel's place stops
    /// the keys there. Each write holds the lock, so `cancel()` returns only once no key of the walk is on its way.
    private func press(_ key: TerminalKey, _ count: Int, one: Bool, over page: ClaudePanelPage, _ terminal: Terminal) -> Bool {
        guard key == .down || key == .up, count > 0 else { return false }
        let size = one ? 1 : max(1, limits.chunk)
        var left = count, first = true
        while left > 0 {
            if !first { terminal.pause(limits.spacing) }
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, let screen = terminal.screen(), let shown = Self.page(in: screen), first ? shown == page : shown.head == page.head else { return false }
            let keys = min(size, left)
            guard terminal.press(key, keys) else { return false }
            left -= keys; first = false
        }
        return true
    }

    /// Why a press did not go: the user's key, the panel gone, or the screen no longer the page the walk read.
    private func refusal(_ terminal: Terminal) -> Outcome {
        if isCancelled { return .cancelled }
        guard let screen = terminal.screen(), Self.page(in: screen) != nil else { return .gone }
        return .partial("screen changed")
    }

    /// The panel once it holds still (two readings alike) and, for a while, once nothing on it is loading.
    private func opening(_ terminal: Terminal, by end: Date) -> ClaudePanelPage? {
        let deadline = min(terminal.now().addingTimeInterval(limits.loading), end)
        var last: ClaudePanelPage?, misses = 0
        while !isCancelled {
            guard let screen = terminal.screen() else { return nil }
            if let page = Self.page(in: screen) {
                if page == last, !page.isLoading || terminal.now() >= deadline { return page }
                last = page
            } else {
                misses += 1
                if misses > 8 { return nil }
            }
            if terminal.now() >= min(deadline.addingTimeInterval(limits.reaction), end) { return last }
            terminal.pause(limits.poll * 4)
        }
        return nil
    }

    private enum Reaction {
        case moved(ClaudePanelPage, at: Int, UsagePanelStitcher)
        case still, lost, gone
    }

    /// The screen after a press: read until it holds still and differs from `previous` in where it stands or in its marks.
    private func reaction(to previous: ClaudePanelPage, in stitcher: UsagePanelStitcher, near hint: Int, by end: Date, _ terminal: Terminal) -> Reaction {
        let deadline = min(terminal.now().addingTimeInterval(limits.reaction), end)
        var last: ClaudePanelPage?, misses = 0
        while terminal.now() < deadline, !isCancelled {
            terminal.pause(limits.poll)
            guard let screen = terminal.screen() else { return .gone }
            guard let page = Self.page(in: screen) else {
                // A reading caught while Claude redraws may miss the panel; one that stays away closed.
                misses += 1
                if misses > 8 { return .gone }
                continue
            }
            misses = 0
            defer { last = page }
            guard page == last, page != previous else { continue }
            var trial = stitcher
            guard let at = trial.merge(page, near: hint) else { return .lost }
            if trial.offset != stitcher.offset + max(0, -at) || trial.sawTop != stitcher.sawTop || trial.sawBottom != stitcher.sawBottom {
                return .moved(page, at: at, trial)
            }
            // Changed where it stood (a figure Claude updated): the scroll is still to come.
        }
        return .still
    }

    /// The same page once the sections loading on it are in, or nil when they do not come in time.
    private func loaded(after page: ClaudePanelPage, by end: Date, _ terminal: Terminal) -> ClaudePanelPage? {
        let deadline = min(terminal.now().addingTimeInterval(limits.loading), end)
        var last: ClaudePanelPage?
        while terminal.now() < deadline, !isCancelled {
            terminal.pause(limits.poll * 4)
            guard let screen = terminal.screen(), let next = Self.page(in: screen) else { return nil }
            if next == last, !next.isLoading { return next }
            last = next
        }
        return nil
    }
}

extension TerminalSession {
    /// The most arrows one burst may carry (`press(_:count:)`): the tallest panel, and then some.
    static let burstLimit = 200

    /// ↑ or ↓ pressed `count` times in one go (at most `burstLimit`): a Terminal tab's as one burst with Terminal brought forward
    /// once (`TerminalAppBridge.press(_:count:…)`), a Nook session's as one tmux write. One key is an ordinary `press`; any
    /// other key is refused.
    func press(_ key: TerminalKey, count: Int, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        guard key == .up || key == .down, (1...Self.burstLimit).contains(count) else { completion(.failed); return }
        guard count > 1 else { press(key, completion: completion); return }
        userInput(key)
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            terminalBridge.press(key, count: count, windowID: windowID, tty: tty, completion: completion)
            return
        }
        let executable = backend.executable
        let arguments = backend.arguments(socket: record.socket) + ["send-keys", "-t", "=" + record.id + ":", "-N", String(count), key.tmuxName]
        DispatchQueue.global(qos: .userInitiated).async {
            let delivered = (try? Shell.run(executable, arguments).0) == 0
            DispatchQueue.main.async { completion(delivered ? .sent : .failed) }
        }
    }

    /// The question on this Nook session's screen right now, read again from its pane off the main thread the way a reading does
    /// (`applyPane`); nil when it shows none or cannot be read. A Terminal tab's screen takes a script: it is not read this way.
    func promptOnScreen(_ done: @escaping (AgentPrompt?) -> Void) {
        let backend = backend, record = record, agent = agent
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = agent == nil ? nil : backend.capture(record).flatMap { text in
                AgentPrompt.parse(TerminalSession.screen(text.trimmingCharacters(in: .newlines), agent: agent).conversation)
            }
            DispatchQueue.main.async { done(prompt) }
        }
    }

    /// Something the user sends this tab (a key, an answer, a message, an interrupt) is about to go: a walk of Claude's usage panel
    /// stops before it (`ClaudeUsageWalk.cancel` returns once no key of the walk is on its way), and none starts for the panel
    /// open now. Nothing to do without a panel or a walk: what opens the panel (/usage and its Enter) must not keep it from being
    /// walked.
    func userInput(_ key: TerminalKey) {
        guard panel != nil || usageReader.walk != nil else { return }
        usageReader.userPressed(key)
    }

    /// Reads the rest of Claude's usage panel in a Nook session by walking it (`ClaudeUsageWalk`), when one is due: once per
    /// panel, only while the user has not pressed a key on it. A Terminal tab is never walked.
    func walkUsagePanelIfDue(now: Date = Date()) {
        guard !isExternal, agent == .claude, isRunning, let due = usageReader.walkDue() else { return }
        guard due <= now else {
            // Claude is still filling the panel in: one more look then (every reading of the screen looks too).
            guard usageReader.scheduleRecheck() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + due.timeIntervalSince(now)) { [weak self] in
                self?.usageReader.recheckDone()
                self?.walkUsagePanelIfDue()
            }
            return
        }
        let walk = ClaudeUsageWalk(generation: usageReader.generation)
        usageReader.begin(walk)
        if !readingPanel { readingPanel = true }
        let terminal = ClaudeUsageWalk.tmux(executable: backend.executable, arguments: backend.arguments(socket: record.socket), target: "=" + record.id + ":")
        let name = record.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = walk.run(terminal) { stitched in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.usageReader.adopt(stitched, from: walk)
                    self.showReadPanel()
                }
            }
            usageLog.info("usage walk \(name, privacy: .public): \(String(describing: outcome), privacy: .public)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.usageReader.finish(walk)
                if self.usageReader.walk == nil, self.readingPanel { self.readingPanel = false }
                self.showReadPanel()
            }
        }
    }
}
