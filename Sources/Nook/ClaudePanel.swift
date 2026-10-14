import Foundation
import AppKit

// A panel Claude draws in its terminal instead of its input box (/usage, /status, /config, /mcp, a skills list…), read from the
// screen's plain text and shaped for the island to draw. `ClaudeComposer.panel` finds the panel; this file only works out what
// is on it: rules, a row of tabs, headings, bars, the row the cursor is on, and everything else as text with its columns kept.
//
//   ClaudePanel         the parsed rows, the panel's name for the header and which way Claude's own content continues
//   ClaudeUsage         the usage panel (/usage) as data: limits, the session's figures, the plugins' footprint, the insights
//   ClaudePanelKey      which of the island's keys reach the panel (pure, so the routing is tested without an event)
//   ClaudePanelMetrics  how big the monospaced text may be so the panel's widest line still fits the island
//
// Nothing is guessed from colors (the screen is plain text): a bar is read from its block characters and its "25% used", the
// active tab from what the panel shows, and anything not recognised stays plain text. When in doubt, a row is text.

struct ClaudePanel: Equatable {
    enum Row: Equatable {
        case blank
        /// A line drawn across the panel (Claude's own rules and the edges of its boxes).
        case rule
        /// "Settings  Status  Config  Usage  Stats": the dialog's title and its tabs. `active` is nil when the panel does not say which.
        case tabs(title: String?, names: [String], active: Int?)
        case heading(indent: Int, text: String)
        /// A line of text. `label` is the quiet part of "Total cost:   $253.64" (the colon and the gap after it); empty for plain text.
        case text(indent: Int, label: String, body: String)
        /// The line under a bar ("Resets 8:59pm"), which Claude draws dim.
        case caption(indent: Int, text: String)
        /// The row the cursor is on ("❯ Verbose output"); `text` follows the mark, so it lines up with its sibling rows.
        case cursor(indent: Int, text: String)
        /// A progress bar with what stood before it and after it ("25% used"). `fraction` is 0...1.
        case bar(indent: Int, lead: String, fraction: Double, trailing: String)
        /// Claude's own key hint ("Esc to cancel").
        case hint(String)
    }

    var rows: [Row] = []
    /// What the header says next to "Panel de Claude": "Settings · Usage", or the panel's own title.
    var name: String?
    /// Claude marks content beyond its screen with a lone "↑" or "↓" at the right edge.
    var moreAbove = false
    var moreBelow = false
    /// The widest text row in columns, once the indent every row shares is gone: what the island's font has to fit.
    var columns = 0

    /// The row the cursor is on, if the panel is a list.
    var cursorIndex: Int? { rows.firstIndex { if case .cursor = $0 { true } else { false } } }

    var isEmpty: Bool { rows.isEmpty }

    init(_ text: String) {
        var raw: [String] = []
        for line in text.components(separatedBy: "\n") {
            var line = Self.trimmedEnd(line)
            let mark = line.trimmingCharacters(in: .whitespaces)
            if Self.downMarks.contains(mark) { moreBelow = true; continue }
            if Self.upMarks.contains(mark) { moreAbove = true; continue }
            // The mark may also end a line of content, past a gap: "Total duration (wall):  58m 53s          ↑".
            if let last = line.last.map(String.init), Self.downMarks.contains(last) || Self.upMarks.contains(last), line.dropLast().hasSuffix("  ") {
                if Self.downMarks.contains(last) { moreBelow = true } else { moreAbove = true }
                line = Self.trimmedEnd(String(line.dropLast()))
            }
            raw.append(Self.unboxed(line))
        }
        raw = Self.rejoined(raw)
        // The indent every line shares is Claude's own margin, not part of the panel's layout.
        let shared = raw.filter { !Self.isBlank($0) && !Self.isRule($0) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        var parsed: [Row] = []
        var tabsSeen = false
        for (index, line) in raw.enumerated() {
            if Self.isBlank(line) { parsed.append(.blank); continue }
            if Self.isRule(line) { parsed.append(.rule); continue }
            var row = Self.row(String(line.dropFirst(min(shared, line.prefix { $0 == " " }.count))), nearEnd: Self.isNearEnd(raw, index))
            // Only the dialog's own tab row, near its top, is tabs; a table's header further down is plain text.
            if case .tabs = row {
                if tabsSeen || parsed.filter({ $0 != .blank && $0 != .rule }).count > 2 { row = Self.plain(line.trimmingCharacters(in: .whitespaces), indent: line.prefix { $0 == " " }.count - shared) }
                tabsSeen = true
            }
            parsed.append(row)
        }
        parsed = Self.trimmed(parsed)
        parsed = Self.shaped(parsed)
        parsed = Self.withActiveTab(parsed)
        rows = parsed
        name = Self.name(of: parsed)
        columns = parsed.map(Self.columns(of:)).max() ?? 0
    }

    // MARK: Reading a line

    private static let downMarks: Set<String> = ["↓", "▼", "⌄"]
    private static let upMarks: Set<String> = ["↑", "▲", "⌃"]
    private static let horizontal: Set<Character> = ["─", "━", "═", "╌", "┄", "┈", "╍", "╴", "╶"]
    private static let corners: Set<Character> = ["╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╠", "╣", "╦", "╩", "╔", "╗", "╚", "╝"]
    /// Claude draws the edge of some panels (its Settings) with eighth blocks: "▔▔▔▔".
    private static let blockRules: Set<Character> = ["▔", "▁", "▀", "▄"]
    private static let fills: Set<Character> = ["█", "▰"]
    private static let empties: Set<Character> = ["░", "▱"]
    /// One to seven eighths of a cell, as Claude's progress bar ends its filled part.
    private static let partials: [Character: Double] = ["▏": 0.125, "▎": 0.25, "▍": 0.375, "▌": 0.5, "▋": 0.625, "▊": 0.75, "▉": 0.875]

    private static func trimmedEnd(_ line: String) -> String {
        var line = Substring(line)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    /// A line of nothing but rule and corner characters: Claude's rules and the borders of its boxes.
    private static func isRule(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.count >= 5 && (text.allSatisfy { horizontal.contains($0) || corners.contains($0) } || text.allSatisfy { blockRules.contains($0) })
    }

    /// Claude wraps a long line at the terminal's width, and Terminal wraps it again when its window narrows: the rest lands on a
    /// line of its own that starts lowercase or with a number ("14s ago)", "tools not yet counted."). Such a line joins the one
    /// it continues, so the island wraps the whole sentence at its own width.
    private static func rejoined(_ lines: [String]) -> [String] {
        let width = lines.filter { !isRule($0) }.map(\.count).max() ?? 0
        var out: [String] = []
        for line in lines {
            if let previous = out.last, continues(line, after: previous, width: width) {
                out[out.count - 1] = previous + " " + line.trimmingCharacters(in: .whitespaces)
            } else { out.append(line) }
        }
        return out
    }

    private static func continues(_ line: String, after previous: String, width: Int) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        // Only a line that filled a terminal's width was cut, and what follows it is prose, not columns.
        guard let first = content.first, first.isLowercase || first.isNumber || first == "(", !content.contains("   "),
              !isBlank(previous), !isRule(previous), width >= 60, previous.count >= width - 16,
              line.prefix(while: { $0 == " " }).count <= previous.prefix(while: { $0 == " " }).count else { return false }
        // A row of its own ("claude-opus-5-5:  208 input", a bar) is never the rest of another.
        return labelled(content) == nil && bar(line, indent: 0, content: content) == nil && cursorText(of: content) == nil
    }

    /// The text inside a box's side bars, kept where it was: "   │ Status   Config │" is "     Status   Config".
    private static func unboxed(_ line: String) -> String {
        guard let first = line.firstIndex(of: "│"), line[..<first].allSatisfy({ $0 == " " }),
              let last = line.lastIndex(of: "│"), last > first, line[line.index(after: last)...].allSatisfy({ $0 == " " }) else { return line }
        // The left bar becomes a space and the right one goes, so the text stays in its column.
        return trimmedEnd(String(line[..<first]) + " " + String(line[line.index(after: first)..<last]))
    }

    private static func isNearEnd(_ lines: [String], _ index: Int) -> Bool {
        lines[(index + 1)...].filter { !isBlank($0) && !isRule($0) }.count < 3
    }

    private static func row(_ line: String, nearEnd: Bool) -> Row {
        let indent = line.prefix { $0 == " " }.count
        let content = line.trimmingCharacters(in: .whitespaces)
        if ClaudeComposer.isTabRow(line) { return tabs(content) }
        if nearEnd, content.count <= 100, ClaudeComposer.isPanelHint(content) { return .hint(content) }
        if let bar = bar(line, indent: indent, content: content) { return bar }
        if let rest = cursorText(of: content) { return .cursor(indent: indent, text: rest) }
        return plain(content, indent: indent)
    }

    private static func plain(_ content: String, indent: Int) -> Row {
        if let (label, body) = labelled(content) { return .text(indent: indent, label: label, body: body) }
        return .text(indent: indent, label: "", body: content)
    }

    private static func tabs(_ content: String) -> Row {
        var names = content.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The dialog's own name leads the row ("Settings" or "Settings:") and is not a tab.
        var title: String?
        if let first = names.first, first.hasSuffix(":") || first.lowercased() == "settings" {
            title = first.hasSuffix(":") ? String(first.dropLast()) : first
            names.removeFirst()
        }
        return .tabs(title: title, names: names, active: nil)
    }

    /// "❯ Verbose output   false": the mark, one space, and what follows keeping its own spacing.
    private static func cursorText(of content: String) -> String? {
        guard content.first == "❯" else { return nil }
        let rest = content.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    /// "Total cost:   $253.64": a short label ending in a colon, then its value. Longer sentences with a colon in them stay whole.
    private static func labelled(_ content: String) -> (label: String, body: String)? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let afterColon = content.index(after: colon)
        guard afterColon < content.endIndex, content[afterColon] == " " else { return nil }
        let label = content[...colon]
        guard label.count <= 30, label.split(separator: " ").count <= 4 else { return nil }
        let gap = content[afterColon...].prefix { $0 == " " }
        let body = content[afterColon...].dropFirst(gap.count)
        guard !body.isEmpty else { return nil }
        return (String(label) + String(gap), String(body))
    }

    // MARK: Bars

    /// A progress bar: block characters (a filled part, perhaps one partial block, then an empty part drawn as shading or just
    /// space) followed by "25% used" or similar. Claude's own bars end in "N% used"; a bar at 0% is only spaces before that.
    private static func bar(_ line: String, indent: Int, content: String) -> Row? {
        let chars = Array(content)
        guard let first = chars.firstIndex(where: { fills.contains($0) || empties.contains($0) || partials[$0] != nil }) else {
            // 0%: Claude's bar is all spaces, so only the long gap before "0% used" gives it away.
            guard indent >= 20, content.range(of: #"^\d{1,3}%\s+used\b"#, options: .regularExpression) != nil, let percent = percent(in: content) else { return nil }
            return .bar(indent: 0, lead: "", fraction: percent / 100, trailing: content)
        }
        var index = first, filled = 0, partial = 0.0, empty = 0
        while index < chars.count, fills.contains(chars[index]) { filled += 1; index += 1 }
        if index < chars.count, let part = partials[chars[index]] { partial = part; index += 1 }
        while index < chars.count, empties.contains(chars[index]) { empty += 1; index += 1 }
        let glyphs = index - first
        var spaces = 0
        while index < chars.count, chars[index] == " " { spaces += 1; index += 1 }
        let trailing = String(chars[index...]).trimmingCharacters(in: .whitespaces)
        let lead = String(chars[..<first]).trimmingCharacters(in: .whitespaces)
        let percent = percent(in: trailing)
        // Claude's limit bar is 50 cells: at 1–5% it is one or two blocks, then the long run of spaces before "2% used".
        let limit = percent != nil && spaces >= 8 && trailing.range(of: #"^\d{1,3}(\.\d+)?%\s+used\b"#, options: .regularExpression) != nil
        guard lead.count <= 24, glyphs >= (percent == nil ? 8 : 3) || limit else { return nil }
        // More blocks after the bar's own (a heat map's shades, a drawing) mean it is not a bar.
        if let next = trailing.first, fills.contains(next) || empties.contains(next) || partials[next] != nil { return nil }
        let fraction: Double
        if let percent { fraction = percent / 100 }
        else if empty > 0 { fraction = (Double(filled) + partial) / Double(filled + (partial > 0 ? 1 : 0) + empty) }
        else { fraction = (Double(filled) + partial) / Double(max(1, glyphs + max(0, spaces - 1))) }
        return .bar(indent: indent, lead: lead, fraction: min(1, max(0, fraction)), trailing: trailing)
    }

    private static func percent(in text: String) -> Double? {
        guard let match = text.range(of: #"^\d{1,3}(\.\d+)?%"#, options: .regularExpression) else { return nil }
        return Double(text[match].dropLast())
    }

    // MARK: Shaping

    /// Rules and blank lines at the edges are the panel's frame, which the island draws itself; runs of them collapse.
    private static func trimmed(_ rows: [Row]) -> [Row] {
        var out: [Row] = []
        for row in rows {
            let quiet = row == .blank || row == .rule
            if quiet, let last = out.last {
                // A rule next to a blank line is one separator; two of the same kind are one.
                if last == .blank || last == .rule {
                    if row == .rule, last == .blank { out[out.count - 1] = .rule }
                    continue
                }
            } else if quiet { continue }
            out.append(row)
        }
        while let last = out.last, last == .blank || last == .rule { out.removeLast() }
        return out
    }

    /// Headings and captions, which depend on the rows around them.
    private static func shaped(_ rows: [Row]) -> [Row] {
        var out = rows
        for index in out.indices {
            guard case .text(let indent, let label, let body) = out[index], label.isEmpty else { continue }
            let previous = index > 0 ? out[index - 1] : .blank
            if case .bar = previous { out[index] = .caption(indent: indent, text: body); continue }
            guard indent == 0, isHeadingText(body) else { continue }
            // It names what follows, so something follows it (not a rule or the hint that ends the panel).
            guard let next = out[(index + 1)...].first(where: { $0 != .blank }) else { continue }
            if case .rule = next { continue }
            if case .hint = next { continue }
            let opensIndentedBlock = body.hasSuffix(":") && indentOf(next) > indent
            if isEdge(previous) || opensIndentedBlock { out[index] = .heading(indent: indent, text: body) }
        }
        return out
    }

    private static func isEdge(_ row: Row) -> Bool {
        switch row {
        case .blank, .rule, .tabs: true
        default: false
        }
    }

    /// A row's indent in columns, past the margin every row shares; 0 for the rows that only draw.
    static func indentOf(_ row: Row) -> Int {
        switch row {
        case .heading(let indent, _), .text(let indent, _, _), .caption(let indent, _), .cursor(let indent, _), .bar(let indent, _, _, _): indent
        default: 0
        }
    }

    /// A short line with no sentence in it: it names what follows.
    private static func isHeadingText(_ text: String) -> Bool {
        guard text.count <= 44, !text.contains("  "), let first = text.first, first.isLetter || first.isNumber else { return false }
        return !".,;!?…".contains(text.last ?? ".")
    }

    // MARK: The active tab

    /// What each tab of Claude's Settings shows, to tell which one is open: its tab row is plain text, the open tab being only
    /// inverted. A tab is named only when exactly one of them clearly matches what the panel shows.
    static let tabClues: [String: [String]] = [
        "status": ["version:", "session id:", "login method:", "setting sources:", "cwd:", "mcp servers:"],
        "config": ["search settings", "auto-compact", "verbose output", "editor mode", "output style", "thinking mode"],
        // A short terminal shows a window of the Usage tab: its later sections have clues of their own.
        "usage": ["current session", "current week", "% used", "resets ", "total cost", "usage by model", "prompt cache (", "skill-listing footprint",
                  "tok/turn", "contributing to your limits", "of your usage", "% of usage"],
        "stats": ["favorite model", "total tokens", "longest session", "current streak", "longest streak", "peak hour", "most active day"],
    ]

    static func activeTab(among names: [String], content: [String]) -> Int? {
        let text = content.joined(separator: "\n").lowercased()
        var scores: [(index: Int, score: Int)] = []
        for (index, name) in names.enumerated() {
            guard let clues = tabClues[name.lowercased()] else { continue }
            let score = clues.filter { text.contains($0) }.count
            if score > 0 { scores.append((index, score)) }
        }
        scores.sort { $0.score > $1.score }
        guard let best = scores.first, scores.count == 1 || scores[1].score < best.score else { return nil }
        return best.index
    }

    private static func withActiveTab(_ rows: [Row]) -> [Row] {
        guard let index = rows.firstIndex(where: { if case .tabs = $0 { true } else { false } }), case .tabs(let title, let names, _) = rows[index] else { return rows }
        let content = rows.enumerated().compactMap { $0.offset == index ? nil : text(of: $0.element) }
        var out = rows
        out[index] = .tabs(title: title, names: names, active: activeTab(among: names, content: content))
        return out
    }

    // MARK: Names and sizes

    private static func name(of rows: [Row]) -> String? {
        for row in rows {
            switch row {
            case .tabs(let title, let names, let active):
                let tab = active.flatMap { names.indices.contains($0) ? names[$0] : nil }
                let parts = [title, tab].compactMap { $0 }
                if !parts.isEmpty { return parts.joined(separator: " · ") }
                return nil
            case .heading(_, let text): return titled(text)
            case .text(0, "", let body) where body.count <= 36 && !ClaudeComposer.isPanelHint(body): return titled(body)
            default: continue
            }
        }
        return nil
    }

    private static func titled(_ text: String) -> String? {
        let title = text.hasSuffix(":") ? String(text.dropLast()) : text
        return title.isEmpty ? nil : title
    }

    /// The text a row shows, whatever its kind, or nil for the ones that only draw.
    static func text(of row: Row) -> String? {
        switch row {
        case .heading(_, let text), .caption(_, let text), .cursor(_, let text), .hint(let text): text
        case .text(_, let label, let body): label + body
        case .bar(_, let lead, _, let trailing): lead + " " + trailing
        default: nil
        }
    }

    private static func columns(of row: Row) -> Int {
        switch row {
        case .heading(let indent, let text), .caption(let indent, let text): indent + text.count
        case .text(let indent, let label, let body): indent + label.count + body.count
        case .cursor(let indent, let text): indent + 2 + text.count
        case .hint(let text): text.count
        default: 0
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Usage

/// Claude's usage panel (/usage: Settings › Usage) as data for Nook's own card. Claude Code 2.1.29x draws it as one column:
///
///   Session                          what this session cost, how long it ran, its code changes, tokens per model, the prompt cache
///   Plugin skill-listing footprint   what each plugin's skill descriptions add to every turn
///   Current session / Current week   the limits: a bar, "28% used", "Resets 1pm (America/Bogota)"
///   What's contributing…             Claude's reading of the local sessions: a window ("Last 24h"), items with advice, tables
///
/// Each section is recognised by its own rows, not by where it sits, so a window of the panel (a short terminal shows only part
/// of it) still reads as far as it goes. Whatever is not recognised stays, in order, in `leftovers`: Claude rewords its panel
/// every few releases, and a line the card cannot place is still a line the user may need.
struct ClaudeUsage: Equatable {
    /// One limit: its title, how full it is and when it resets.
    struct Meter: Equatable {
        var title: String
        /// 0...1.
        var fraction: Double
        /// What Claude prints beside the bar: "79% used".
        var label: String
        /// The line under the bar: "Resets Oct 6 at 6am (America/Bogota)", or a credit's "One-time credit · Expires October 13".
        var resets: String?
        /// More lines Claude prints under a limit (a warning about it), in order.
        var notes: [String] = []
        /// Where the bar and its percent come from: the panel, or Claude's status line (`filled(from:)`), "en vivo".
        var source: Source = .panel
        /// Where `resets` comes from: the status line's when the panel's had already passed.
        var resetsSource: Source = .panel
    }

    /// Where a figure comes from: Claude's panel as read from the screen, its status line's payload, live, or Claude's own copy
    /// of its latest usage reading (`ClaudeUsageSnapshot`, as old as `ClaudeUsage.savedAt` says).
    enum Source: Equatable { case panel, live, snapshot }

    /// The "Session" section: what this Claude session cost and used so far.
    struct SessionStats: Equatable {
        /// "Session", or "Session (remote)".
        var title = "Session"
        /// "$1.75".
        var cost: String?
        /// Claude's remark after the cost: "costs may be inaccurate due to usage of unknown models".
        var costNote: String?
        /// "4m 14s": the time spent on API calls.
        var apiDuration: String?
        /// "8m 16s": the time since the session started.
        var wallDuration: String?
        var linesAdded: Int?
        var linesRemoved: Int?
        /// "Usage by model", in Claude's order.
        var models: [ModelUsage] = []
        /// "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)".
        var promptCache: String?
        /// Lines of the section this does not know ("Total web search requests:  3"), the label without its colon; a line
        /// without a label has an empty one.
        var other: [Stat] = []
        /// The figures that came from Claude's status line (`filled(from:)`) because the panel's rows lacked them.
        var liveFields: Set<Field> = []

        enum Field: Hashable { case cost, apiDuration, wallDuration, lines, promptCache }
    }

    struct Stat: Equatable {
        var label: String
        var value: String
    }

    /// "claude-opus-5-5:  44 input, 23.5k output, 2.0m cache read, 110.7k cache write ($1.75)". The counts are Claude's own
    /// abbreviations ("23.5k", "2.0m"); a part the line does not have is nil (older versions print no cache write).
    struct ModelUsage: Equatable {
        var name: String
        var input: String?
        var output: String?
        var cacheRead: String?
        var cacheWrite: String?
        /// ", 3 web search": only when the model searched.
        var webSearch: String?
        /// "$1.75", without its parentheses.
        var cost: String?
        /// Parts of the line this does not know, as Claude wrote them.
        var extra: [String] = []
    }

    /// "Plugin skill-listing footprint": what each plugin's skill descriptions add to the system prompt on every turn.
    struct Footprint: Equatable {
        var title = "Plugin skill-listing footprint"
        /// Claude's explanation under the title, in one piece.
        var note: String?
        var plugins: [Plugin] = []
        /// "~376 tok/turn".
        var total: String?
        /// 376.
        var totalTokens: Int?
        /// Claude's remark after the total, without its parentheses: "capped at the listing budget; per-plugin figures above are pre-truncation".
        var totalNote: String?
    }

    struct Plugin: Equatable {
        var name: String
        /// "10 skills · ~301 tok/turn", as Claude wrote it.
        var detail: String
        var skills: Int?
        /// About how many tokens a turn (301).
        var tokens: Int?
    }

    /// "What's contributing to your limits usage?": Claude's reading of this machine's local sessions.
    struct Insights: Equatable {
        var title = "What's contributing to your limits usage?"
        /// "Approximate, based on local sessions on this machine — does not include other devices or claude.ai".
        var note: String?
        /// "Last 24h · these are independent characteristics of your usage, not a breakdown" (or "Last 7d · …").
        var window: String?
        var items: [Insight] = []
        /// "Skills", "Subagents", "Plugins", "MCP servers", "Loops": who used how much, when Claude has the data.
        var tables: [Table] = []
        /// The section's single lines: "Scanning local sessions…", "Nothing over 10% in this period — try the other window.".
        var messages: [String] = []
    }

    struct Insight: Equatable {
        /// "89% of your usage was at >150k context".
        var headline: String
        /// "Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.", in one piece.
        var advice: String?
        /// The headline's leading percentage, 0...1 (0.89); nil when it has none.
        var share: Double?
    }

    struct Table: Equatable {
        var title: String
        /// The header's other columns: ["% of usage"], or the loops' ["every", "runs", "tokens", …].
        var columns: [String] = []
        var rows: [TableRow] = []
        /// "… 3 more".
        var more: String?
    }

    struct TableRow: Equatable {
        var name: String
        var values: [String]
    }

    var meters: [Meter]
    var session: SessionStats?
    var footprint: Footprint?
    var insights: Insights?
    /// Every row none of the above took, in order, with the separators between them (no tab row, key hint or edge): what Claude
    /// added that this does not know yet, its loading and error lines.
    var leftovers: [ClaudePanel.Row]
    /// The reading holds the whole panel: Claude marks nothing above or below it. False while its "↑" or "↓" says there is
    /// more, which is when the card may offer to scroll; Nook's own sessions are read to the end without it (`ClaudeUsageWalk`).
    var complete: Bool
    /// Everything but the meters, in order, as the panel's generic rows (the card's former "Detalles").
    var details: [ClaudePanel.Row]
    /// Claude's status line for this tab, when Nook has it (`filled(from:)`): what the panel never shows (the context window,
    /// the model and effort, the spend limit's dollars, the prompt cache's details) is there.
    var live: ClaudeLiveUsage?
    /// When Claude took the reading the `.snapshot` meters come from.
    var savedAt: Date?

    /// Nook's own usage card (`AppModel.openUsage`): no panel, only what Claude's status line and its usage snapshot give.
    /// Nil when they give no figure to show.
    static func nookCard(from live: ClaudeLiveUsage?, now: Date = Date(), zone: TimeZone = .current) -> ClaudeUsage? {
        guard let live = live?.upToDate(at: now) else { return nil }
        let usage = ClaudeUsage(meters: []).filled(from: live, now: now, zone: zone)
        return usage.meters.isEmpty && usage.session == nil ? nil : usage
    }

    init(meters: [Meter], session: SessionStats? = nil) {
        self.meters = meters
        self.session = session
        leftovers = []
        complete = true
        details = []
    }

    /// Nil for any other panel: one with a limit's "% used", a section of its own, or Settings open on its Usage tab.
    init?(_ panel: ClaudePanel) {
        let rows = panel.rows
        var openTab: String?
        if let row = rows.first(where: { if case .tabs = $0 { true } else { false } }), case .tabs(_, let names, let active) = row,
           let active, names.indices.contains(active) { openTab = names[active].lowercased() }
        // Another of Settings' tabs is never read as usage, whatever it shares with it.
        if let openTab, openTab != "usage" { return nil }
        var reading = Reading(rows)
        let meters = reading.meters()
        let metered = reading.used
        let footprint = reading.footprint()
        let insights = reading.insights()
        let session = reading.session()
        guard !meters.isEmpty || session != nil || footprint != nil || insights != nil || openTab == "usage" else { return nil }
        self.meters = meters
        self.session = session
        self.footprint = footprint
        self.insights = insights
        leftovers = reading.rest(skipping: reading.used)
        details = reading.rest(skipping: metered)
        complete = !panel.moreAbove && !panel.moreBelow
    }

    /// The panel's rows taken section by section: `used` holds the rows already placed.
    private struct Reading {
        let rows: [ClaudePanel.Row]
        var used = Set<Int>()
        /// Runs of rows with no blank line, rule, tab row or hint between them: Claude puts a blank line between its parts.
        let blocks: [ClosedRange<Int>]

        init(_ rows: [ClaudePanel.Row]) {
            self.rows = rows
            var blocks: [ClosedRange<Int>] = []
            var start: Int?
            for index in rows.indices {
                if Self.quiet(rows[index]) {
                    if let first = start { blocks.append(first...(index - 1)); start = nil }
                } else if start == nil { start = index }
            }
            if let first = start { blocks.append(first...(rows.count - 1)) }
            self.blocks = blocks
        }

        private static func quiet(_ row: ClaudePanel.Row) -> Bool {
            switch row {
            case .blank, .rule, .tabs, .hint: true
            default: false
            }
        }

        func text(_ index: Int) -> String { (ClaudePanel.text(of: rows[index]) ?? "").trimmingCharacters(in: .whitespaces) }
        func indent(_ index: Int) -> Int { ClaudePanel.indentOf(rows[index]) }
        func block(of index: Int) -> Int? { blocks.firstIndex { $0.contains(index) } }

        /// A line of its own words (a heading or plain text), not a value under a label.
        func isPlain(_ index: Int) -> Bool {
            switch rows[index] {
            case .heading: true
            case .text(_, let label, _): label.isEmpty
            case .caption: true
            default: false
            }
        }

        /// The rows nobody took, separators between them kept (one in a row), none at the ends.
        func rest(skipping taken: Set<Int>) -> [ClaudePanel.Row] {
            var out: [ClaudePanel.Row] = []
            for (index, row) in rows.enumerated() where !taken.contains(index) {
                switch row {
                case .tabs, .hint: continue
                case .blank, .rule: if let last = out.last, last != .blank, last != .rule { out.append(row) }
                default: out.append(row)
                }
            }
            while let last = out.last, last == .blank || last == .rule { out.removeLast() }
            return out
        }

        // MARK: Meters

        /// A limit's value: a bar with "N% used" beside it, or "N% used" on a line of its own (a terminal under 64 columns
        /// puts it under the bar; a bar drawn only in background colours leaves nothing else to read).
        func value(at index: Int) -> (fraction: Double, label: String, lead: String)? {
            switch rows[index] {
            case .bar(_, let lead, let fraction, let trailing):
                guard trailing.lowercased().contains("used") else { return nil }
                return (fraction, trailing, lead)
            case .text(_, "", let body): return Self.percentUsed(body).map { ($0, body.trimmingCharacters(in: .whitespaces), "") }
            case .caption(_, let text), .heading(_, let text): return Self.percentUsed(text).map { ($0, text.trimmingCharacters(in: .whitespaces), "") }
            default: return nil
            }
        }

        static func percentUsed(_ text: String) -> Double? {
            guard let found = Usage.percentUsed.groups(text.trimmingCharacters(in: .whitespaces)), let number = found[0].flatMap(Double.init) else { return nil }
            return min(1, max(0, number / 100))
        }

        /// A bar with nothing beside it (its percent is on the next line), or a line of nothing but bar blocks.
        func isBarOnly(_ index: Int) -> Bool {
            switch rows[index] {
            case .bar(_, _, _, let trailing): return trailing.isEmpty
            case .text(_, "", let body): return !body.isEmpty && body.contains { Usage.barGlyphs.contains($0) } && body.allSatisfy { Usage.barGlyphs.contains($0) || $0 == " " }
            default: return false
            }
        }

        mutating func meters() -> [Meter] {
            var found: [Meter] = []
            for index in rows.indices where !used.contains(index) {
                guard let reading = value(at: index), let block = block(of: index) else { continue }
                let range = blocks[block]
                used.insert(index)
                var meter = Meter(title: reading.lead, fraction: reading.fraction, label: reading.label)
                // "61% used · resets Oct 7": the reset beside the percent.
                if let dot = reading.label.range(of: " · ") {
                    meter.label = String(reading.label[..<dot.lowerBound])
                    meter.resets = String(reading.label[dot.upperBound...])
                }
                var above = index - 1
                var narrow = false
                if above >= range.lowerBound, isBarOnly(above) { used.insert(above); above -= 1; narrow = true }
                if meter.title.isEmpty {
                    if narrow, above >= range.lowerBound {
                        // Under 64 columns: "Current session · Resets 1pm (…)", Claude's lines about it, the bar, "28% used".
                        name(&meter, from: range.lowerBound)
                        for line in (range.lowerBound + 1)..<(above + 1) where !used.contains(line) { meter.notes.append(text(line)); used.insert(line) }
                    } else if above >= range.lowerBound, !used.contains(above), isPlain(above) {
                        // The line right above the bar names it.
                        meter.title = text(above); used.insert(above)
                    } else if above < range.lowerBound, block > 0, titles(blocks[block - 1]) {
                        // At 0% a narrow bar is all spaces: a blank line, which leaves the title's lines apart.
                        let previous = blocks[block - 1]
                        name(&meter, from: previous.lowerBound)
                        for line in (previous.lowerBound + 1)..<(previous.upperBound + 1) { meter.notes.append(text(line)); used.insert(line) }
                    }
                }
                if !narrow {
                    // Under the bar: its reset, then any other lines, up to the next limit.
                    var below = index + 1
                    while below <= range.upperBound, !used.contains(below), value(at: below) == nil, !isBarOnly(below),
                          !(below < range.upperBound && (value(at: below + 1) != nil || isBarOnly(below + 1))) {
                        if below == index + 1, meter.resets == nil { meter.resets = text(below) } else { meter.notes.append(text(below)) }
                        used.insert(below); below += 1
                    }
                }
                found.append(meter)
            }
            return found
        }

        /// A narrow limit's title and its lines, standing apart from its "0% used": nothing in it is taken or a value, and it
        /// reads like a limit's title ("Current week (Fable) · Resets …").
        private func titles(_ range: ClosedRange<Int>) -> Bool {
            !range.contains { used.contains($0) || value(at: $0) != nil } && isPlain(range.lowerBound) && text(range.lowerBound).contains(" · ")
        }

        /// "Current session · Resets 1pm (America/Bogota)": the title, and what follows its dot as the reset.
        private mutating func name(_ meter: inout Meter, from index: Int) {
            let line = text(index)
            used.insert(index)
            guard let dot = line.range(of: " · ") else { meter.title = line; return }
            meter.title = String(line[..<dot.lowerBound])
            if meter.resets == nil { meter.resets = String(line[dot.upperBound...]) }
        }

        // MARK: Session

        mutating func session() -> SessionStats? {
            var stats = SessionStats()
            var found = false
            var own = Set<Int>()
            var titleBlock: Int?
            for index in rows.indices where !used.contains(index) {
                let line = text(index)
                if isPlain(index), line == "Session" || Usage.sessionTitle.groups(line) != nil {
                    stats.title = line; used.insert(index); found = true
                    titleBlock = block(of: index)
                    continue
                }
                if isPlain(index), line.lowercased() == "usage by model:" {
                    used.insert(index); found = true
                    if let block = block(of: index) { own.insert(block) }
                    continue
                }
                guard case .text(_, let rawLabel, let body) = rows[index], !rawLabel.isEmpty else { continue }
                let label = String(rawLabel.trimmingCharacters(in: .whitespaces).dropLast())
                switch label.lowercased() {
                case "total cost":
                    if let found = Usage.costNote.groups(body) { stats.cost = found[0]; stats.costNote = found[1] } else { stats.cost = body }
                case "total duration (api)": stats.apiDuration = body
                case "total duration (wall)": stats.wallDuration = body
                case "total code changes":
                    if let found = Usage.codeChanges.groups(body) {
                        stats.linesAdded = found[0].flatMap { Int($0) }; stats.linesRemoved = found[1].flatMap { Int($0) }
                    } else { stats.other.append(Stat(label: label, value: body)) }
                case let key where key.hasPrefix("prompt cache") && stats.promptCache == nil: stats.promptCache = body
                default:
                    guard let model = Self.model(label, body) else { continue }
                    stats.models.append(model)
                }
                used.insert(index); found = true
                if let block = block(of: index) { own.insert(block) }
            }
            // The block under the title is the section's even when it holds nothing this knows ("Loading remote cost…").
            if let titleBlock, own.isEmpty, titleBlock + 1 < blocks.count { own.insert(titleBlock + 1) }
            if let titleBlock { own.insert(titleBlock) }
            // A line of the section this does not know is still the session's.
            for block in own.sorted() {
                for index in blocks[block] where !used.contains(index) {
                    switch rows[index] {
                    case .text(_, let label, let body) where !label.isEmpty:
                        stats.other.append(Stat(label: String(label.trimmingCharacters(in: .whitespaces).dropLast()), value: body))
                    default:
                        guard isPlain(index) else { continue }
                        stats.other.append(Stat(label: "", value: text(index)))
                    }
                    used.insert(index)
                }
            }
            return found ? stats : nil
        }

        /// "claude-opus-5-5:  44 input, 23.5k output, 2.0m cache read, 110.7k cache write ($1.75)".
        static func model(_ name: String, _ body: String) -> ModelUsage? {
            var rest = body.trimmingCharacters(in: .whitespaces)
            var model = ModelUsage(name: name)
            if let found = Usage.trailingParentheses.groups(rest) { rest = found[0] ?? rest; model.cost = found[1] }
            for part in rest.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                guard let space = part.firstIndex(of: " ") else { model.extra.append(part); continue }
                let amount = String(part[..<space]), kind = part[part.index(after: space)...].lowercased()
                guard amount.first?.isNumber == true else { model.extra.append(part); continue }
                switch kind {
                case "input": model.input = amount
                case "output": model.output = amount
                case "cache read": model.cacheRead = amount
                case "cache write": model.cacheWrite = amount
                case "web search", "web searches": model.webSearch = amount
                default: model.extra.append(part)
                }
            }
            // A model's line is one that counts its tokens; anything else under a label is not.
            guard model.input != nil, model.output != nil else { return nil }
            return model
        }

        // MARK: Footprint

        mutating func footprint() -> Footprint? {
            var footprint = Footprint()
            var found = false
            for index in rows.indices where !used.contains(index) {
                let line = text(index)
                if isPlain(index), line.count <= 60, line.lowercased().contains("skill-listing footprint") {
                    footprint.title = line; used.insert(index); found = true
                    // Its explanation is the rest of its block.
                    if let block = block(of: index) {
                        var note: [String] = []
                        for next in blocks[block] where next > index && !used.contains(next) && isPlain(next) && plugin(next) == nil && Self.total(text(next)) == nil {
                            note.append(text(next)); used.insert(next)
                        }
                        if !note.isEmpty { footprint.note = note.joined(separator: " ") }
                    }
                    continue
                }
                if let plugin = plugin(index) { footprint.plugins.append(plugin); used.insert(index); found = true; continue }
                if isPlain(index), let total = Self.total(line) {
                    footprint.total = total.text; footprint.totalTokens = total.tokens; footprint.totalNote = total.note
                    used.insert(index); found = true
                }
            }
            return found ? footprint : nil
        }

        /// "Notion                     10 skills · ~301 tok/turn".
        func plugin(_ index: Int) -> Plugin? {
            guard isPlain(index), let found = Usage.plugin.groups(text(index)), let name = found[0], let detail = found[1] else { return nil }
            return Plugin(name: name, detail: detail, skills: found[2].flatMap { Int($0) }, tokens: Usage.tokens(in: detail))
        }

        /// "Total                      ~376 tok/turn (capped at the listing budget; …)".
        static func total(_ line: String) -> (text: String, tokens: Int?, note: String?)? {
            guard let found = Usage.footprintTotal.groups(line), let total = found[0] else { return nil }
            let note = found[1].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ()")) }.flatMap { $0.isEmpty ? nil : $0 }
            return (total, Usage.tokens(in: total), note)
        }

        // MARK: Insights

        mutating func insights() -> Insights? {
            // Its title, or (in a window of the panel that starts below it) its first row of its own.
            let start = rows.indices.first { !used.contains($0) && isPlain($0) && Usage.insightsTitle.groups(text($0)) != nil }
                ?? rows.indices.first { !used.contains($0) && isPlain($0) && Self.insightRow(text($0)) }
            guard let start, let first = block(of: start) else { return nil }
            var insights = Insights()
            var found = false
            for block in first..<blocks.count {
                let range = blocks[block]
                let lines = range.filter { $0 >= start && !used.contains($0) }
                guard let head = lines.first else {
                    // A limit read earlier ends the section.
                    if range.contains(where: { used.contains($0) }), block > first { break }
                    continue
                }
                let headline = text(head)
                if Self.endsInsights(headline) || range.contains(where: { used.contains($0) && $0 > start }) { break }
                if Usage.insightsTitle.groups(headline) != nil {
                    insights.title = headline
                    let note = lines.dropFirst().map(text)
                    if !note.isEmpty { insights.note = note.joined(separator: " ") }
                } else if Usage.window.groups(headline) != nil {
                    insights.window = lines.map(text).joined(separator: " ")
                } else if let table = table(lines) {
                    insights.tables.append(table)
                } else if lines.count == 1, Usage.periodHint.groups(headline) != nil {
                    // "d to day · w to week": keys Nook does not offer.
                } else if lines.count == 1, Usage.share.groups(headline) == nil {
                    insights.messages.append(headline)
                } else {
                    insights.items.append(item(lines))
                }
                for line in lines { used.insert(line) }
                found = true
            }
            return found ? insights : nil
        }

        /// A row that only the insights have: their window, an item's percentage of "your usage", a table's "% of usage".
        static func insightRow(_ line: String) -> Bool {
            Usage.window.groups(line) != nil || line.range(of: #"^\d{1,3}% of your usage\b"#, options: .regularExpression) != nil
                || line.hasSuffix("% of usage")
        }

        /// What Claude draws after the insights: its credits, its loading and error lines.
        static func endsInsights(_ line: String) -> Bool {
            let lower = line.lowercased()
            return ["usage credits", "spend limit", "error:", "refreshing", "showing last-known", "partial usage data", "per-model breakdown",
                    "could not refresh", "loading usage data"].contains { lower.hasPrefix($0) }
        }

        /// A headline and what Claude advises under it, one column in: "89% of your usage was at >150k context" / " Longer…".
        func item(_ lines: [Int]) -> Insight {
            var headline = [text(lines[0])]
            var rest = lines.dropFirst()
            // A headline Claude wrapped goes on at its own indent; its advice is one column in.
            if case .heading = rows[lines[0]] {} else {
                while let next = rest.first, indent(next) <= indent(lines[0]) { headline.append(text(next)); rest = rest.dropFirst() }
            }
            let joined = headline.joined(separator: " ")
            let advice = rest.map(text).joined(separator: " ")
            let share = Usage.share.groups(joined)?[0].flatMap(Double.init).map { min(1, $0 / 100) }
            return Insight(headline: joined, advice: advice.isEmpty ? nil : advice, share: share)
        }

        /// "Skills                    % of usage" over "/review   40%" rows, and "… 3 more".
        func table(_ lines: [Int]) -> Table? {
            guard lines.count >= 2, isPlain(lines[0]) else { return nil }
            let header = Self.cells(text(lines[0]))
            guard header.count >= 2, Usage.share.groups(header[0]) == nil, header.dropFirst().allSatisfy({ $0.count <= 16 }) else { return nil }
            var table = Table(title: header[0], columns: Array(header.dropFirst()))
            for line in lines.dropFirst() {
                let row = text(line)
                if row.hasPrefix("…") || row.hasPrefix("...") { table.more = row; continue }
                let cells = Self.cells(row)
                // A table's rows have its columns; a line that has none is no table.
                guard cells.count >= 2 || table.rows.count > 0 else { return nil }
                table.rows.append(TableRow(name: cells.first ?? row, values: Array(cells.dropFirst())))
            }
            return table.rows.isEmpty ? nil : table
        }

        static func cells(_ line: String) -> [String] {
            line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    /// The patterns the usage panel is read with, compiled once: a panel is read several times a second.
    fileprivate enum Usage {
        static let barGlyphs: Set<Character> = ["█", "▰", "░", "▱", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        static let percentUsed = Pattern(#"^(\d{1,3}(?:\.\d+)?)\s*%\s*used\b"#)
        static let sessionTitle = Pattern(#"^Session \(.+\)$"#)
        static let costNote = Pattern(#"^(\S+)\s+\((.+)\)$"#)
        static let codeChanges = Pattern(#"^(\d+) lines? added, (\d+) lines? removed"#)
        static let trailingParentheses = Pattern(#"^(.*?)\s*\(([^()]*)\)$"#)
        static let plugin = Pattern(#"^(\S.*?)\s{2,}((\d+)\s+skills?\b.*)$"#)
        static let footprintTotal = Pattern(#"^Total\s{2,}(~?[\d.,]+k?\s*tok/turn)(.*)$"#)
        static let insightsTitle = Pattern(#"^What.s contributing to your limits usage\??$"#, caseInsensitive: true)
        static let window = Pattern(#"^(?:Last|Past) \d+\s*[a-z]+ · "#)
        static let share = Pattern(#"^(\d{1,3})% "#)
        static let periodHint = Pattern(#"^\S{1,12} to day · \S{1,12} to week$"#)

        /// "~301 tok/turn" → 301, "~1.2k tok/turn" → 1200.
        static func tokens(in text: String) -> Int? {
            guard let found = Pattern.tokens.groups(text), let number = found[0].flatMap({ Double($0.replacingOccurrences(of: ",", with: "")) }) else { return nil }
            return Int((number * (found[1] == nil ? 1 : 1000)).rounded())
        }
    }

    fileprivate struct Pattern {
        static let tokens = Pattern(#"~?([\d.,]+)(k)?\s*tok/turn"#)
        let regex: NSRegularExpression

        init(_ pattern: String, caseInsensitive: Bool = false) {
            // The patterns are this file's own: one that does not compile is a bug to see at once.
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        /// The capture groups of the first match (nil for a group that did not take part), or nil when it does not match.
        func groups(_ text: String) -> [String?]? {
            let string = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: string.length)) else { return nil }
            return (1..<max(1, match.numberOfRanges)).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : string.substring(with: range)
            }
        }
    }
}

// MARK: - Live figures

extension ClaudeUsage {
    /// The panel's reading with what Claude's status line adds (`ClaudeLiveUsage`): the session's and the week's limits when the
    /// panel's rows lack them (a short screen, a part not read yet), and the session's figures likewise, each marked `.live`.
    /// Where both have a figure the panel's wins, its section being the panel's own, but a reset it shows that has already passed
    /// gives way to the status line's next one. Per-model weekly limits ("Current week (Fable)") never come with the status line:
    /// Claude's own copy of its latest usage reading (`live.saved`) fills them, and any other limit the rows lack, marked
    /// `.snapshot`; the status line's figure replaces a snapshot's when it is the newer reading. Credits and the tokens per model
    /// exist only in the panel and stay as read. `live` keeps the rest (context window, model, effort, spend, cache).
    func filled(from live: ClaudeLiveUsage?, now: Date = Date(), zone: TimeZone = .current) -> ClaudeUsage {
        guard let live else { return self }
        var usage = self
        usage.live = live
        if let saved = live.saved?.upToDate(at: now) {
            for limit in saved.limits where !usage.meters.contains(where: { $0.title.caseInsensitiveCompare(limit.title) == .orderedSame }) {
                let meter = Meter(title: limit.title, fraction: min(1, max(0, limit.percent / 100)), label: "\(Int(limit.percent.rounded(.down)))% used",
                                  resets: limit.resetsAt.map { Self.resets($0, dated: limit.dated, now: now, zone: zone) }, source: .snapshot, resetsSource: .snapshot)
                usage.meters.insert(meter, at: Self.place(limit.title, in: usage.meters))
                usage.savedAt = saved.fetchedAt
            }
        }
        if let limits = live.limits {
            for (title, limit, dated) in [("Current session", limits.fiveHour, false), ("Current week (all models)", limits.sevenDay, true), ("Spend limit", limits.spendLimit, true)] {
                guard let limit else { continue }
                let resets = limit.resetsAt.map { Self.resets($0, dated: dated, now: now, zone: zone) }
                let meter = Meter(title: title, fraction: min(1, max(0, limit.usedPercentage / 100)), label: "\(Int(limit.usedPercentage.rounded(.down)))% used",
                                  resets: resets, source: .live, resetsSource: .live)
                if let index = usage.meters.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                    if usage.meters[index].source == .snapshot {
                        if (live.limitsAt ?? .distantPast) >= (usage.savedAt ?? .distantPast) { usage.meters[index] = meter }
                    } else if let resets, let next = limit.resetsAt, next > now, let shown = usage.meters[index].resets.flatMap({ Self.resetDate($0, now: now, zone: zone) }), shown <= now {
                        usage.meters[index].resets = resets
                        usage.meters[index].resetsSource = .live
                    }
                    continue
                }
                usage.meters.insert(meter, at: Self.place(title, in: usage.meters))
            }
        }
        if !usage.meters.contains(where: { $0.source == .snapshot }) { usage.savedAt = nil }
        if let payload = live.session {
            var stats = usage.session ?? SessionStats()
            var filled = Set<SessionStats.Field>()
            if let cost = payload.cost {
                if stats.cost == nil, let dollars = cost.totalUSD { stats.cost = Self.dollars(dollars); filled.insert(.cost) }
                if stats.apiDuration == nil, let ms = cost.apiDurationMS { stats.apiDuration = Self.duration(ms / 1000); filled.insert(.apiDuration) }
                if stats.wallDuration == nil, let ms = cost.durationMS { stats.wallDuration = Self.duration(ms / 1000); filled.insert(.wallDuration) }
                if stats.linesAdded == nil, stats.linesRemoved == nil, let added = cost.linesAdded, let removed = cost.linesRemoved {
                    stats.linesAdded = added; stats.linesRemoved = removed; filled.insert(.lines)
                }
            }
            if stats.promptCache == nil, let cache = payload.promptCache, let line = Self.promptCache(cache, now: now) { stats.promptCache = line; filled.insert(.promptCache) }
            if !filled.isEmpty {
                stats.liveFields.formUnion(filled)
                usage.session = stats
            }
        }
        return usage
    }

    /// Where a limit the rows lack goes, in Claude's order: the session's first, the week's for all models next, the per-model
    /// weeks after the last week shown, anything else (a spend limit) last.
    static func place(_ title: String, in meters: [Meter]) -> Int {
        func index(_ match: (String) -> Bool) -> Int? { meters.lastIndex { match($0.title.lowercased()) }.map { $0 + 1 } }
        let session = index { $0 == "current session" }
        switch title.lowercased() {
        case "current session": return 0
        case "current week (all models)": return session ?? 0
        case let other where other.hasPrefix("current week ("): return index { $0.hasPrefix("current week (") } ?? session ?? 0
        default: return meters.count
        }
    }

    /// "$1.75", or "$0.0003" under half a dollar, as Claude prints a cost.
    static func dollars(_ value: Double) -> String {
        value > 0.5 ? String(format: "$%.2f", (value * 100).rounded() / 100) : String(format: "$%.4f", value)
    }

    /// "4m 14s", "9h 56m 36s", "12s", as Claude prints a duration.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(rest)s" }
        return minutes > 0 ? "\(minutes)m \(rest)s" : "\(rest)s"
    }

    /// The panel's prompt cache line from the status line's figures: "62 requests · 98% of input tokens from cache · no misses ·
    /// warm (1h TTL, last activity 2m 5s ago)".
    static func promptCache(_ cache: ClaudeStatusPayload.PromptCache, now: Date) -> String? {
        guard let requests = cache.requests else { return nil }
        var parts = [requests == 1 ? "1 request" : "\(requests) requests"]
        if let ratio = cache.hitRatio { parts.append("\(Int((ratio * 100).rounded()))% of input tokens from cache") }
        if let misses = cache.misses { parts.append(misses == 0 ? "no misses" : misses == 1 ? "1 miss" : "\(misses) misses") }
        if cache.warm == true {
            let ttl = cache.ttl ?? ""
            if let expires = cache.expiresAt, let seconds = Self.seconds(ttl) {
                parts.append("warm (\(ttl) TTL, last activity \(duration(now.timeIntervalSince(expires.addingTimeInterval(-seconds)))) ago)")
            } else { parts.append(ttl.isEmpty ? "warm" : "warm (\(ttl) TTL)") }
        } else if cache.warm == false { parts.append("cold") }
        return parts.joined(separator: " · ")
    }

    /// "1h" → 3600, "5m" → 300.
    private static func seconds(_ ttl: String) -> Double? {
        guard let value = Double(ttl.dropLast()) else { return nil }
        switch ttl.last { case "h": return value * 3600; case "m": return value * 60; case "s": return value; default: return nil }
    }

    /// A reset as Claude words it, so `UsageWords.resets` says it in Spanish: "Resets 6:10pm (America/Bogota)" for later today,
    /// "Resets Oct 13 at 6am (America/Bogota)" otherwise or when `dated`.
    static func resets(_ date: Date, dated: Bool, now: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        let clock = "\(hour % 12 == 0 ? 12 : hour % 12)" + (minute == 0 ? "" : String(format: ":%02d", minute)) + (hour < 12 ? "am" : "pm")
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let day = dated || !calendar.isDate(date, inSameDayAs: now) ? "\(months[(parts.month ?? 1) - 1]) \(parts.day ?? 1) at " : ""
        return "Resets \(day)\(clock) (\(zone.identifier))"
    }

    /// When a reset the panel shows falls: "Resets 1pm (America/Bogota)" is today at 1 p.m. there, "Resets Oct 13 at 6am (…)"
    /// that day in the year nearest to now. Nil for wording this does not know.
    static func resetDate(_ text: String, now: Date, zone fallback: TimeZone) -> Date? {
        let pattern = #"^Resets\s+(?:([A-Z][a-z]{2,3})\s+(\d{1,2})(?:,|\s+at)?\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*(?:\(([^)]+)\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let hourText = group(3), var hour = Int(hourText) else { return nil }
        let minute = group(4).flatMap { Int($0) } ?? 0
        hour = hour % 12 + (group(5) == "pm" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(6).flatMap { TimeZone(identifier: $0) } ?? fallback
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour; parts.minute = minute
        guard let monthName = group(1), let day = group(2).flatMap({ Int($0) }) else { return calendar.date(from: parts) }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let month = months.firstIndex(of: String(monthName.prefix(3)).lowercased()) else { return nil }
        parts.month = month + 1; parts.day = day
        let year = parts.year ?? 2026
        return [year - 1, year, year + 1].compactMap { candidate -> Date? in
            var dated = parts; dated.year = candidate
            return calendar.date(from: dated)
        }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }
}

// MARK: - Keys

/// The island's keys that go to a panel Claude has open. The panel has no field to type in, so the arrows, Tab, Enter and Esc
/// travel to Claude as they are; Esc closes the panel (it never reaches the island's own Esc, which would put the island away).
enum ClaudePanelKey {
    /// The key a press stands for, or nil when it is not one of the panel's (letters, shifted or command keys).
    static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> TerminalKey? {
        // The arrows report the function and keypad flags; they do not count.
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags.isEmpty else { return nil }
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 48: return .tab
        case 36, 76: return .enter
        case 53: return .escape
        default: return nil
        }
    }

    static func key(event: NSEvent) -> TerminalKey? { key(keyCode: event.keyCode, modifiers: event.modifierFlags) }
}

// MARK: - Presence

enum ClaudePanelHold {
    /// How long the island keeps a panel on screen after the screen stops showing it. A reading caught while Claude redraws
    /// would otherwise make the card blink away and back; a panel that really closed leaves a moment later.
    static var delay = 0.6
    /// …and after the user pressed Esc on it (Claude closing it is what they asked for): no reason to wait.
    static var afterEsc = 0.05
    /// How long after an Esc the panel's closing still counts as what it asked for.
    static var askedWindow = 4.0
}

// MARK: - Sizes

enum ClaudePanelMetrics {
    /// One column of the monospaced system font, per point of its size.
    static let advance: CGFloat = {
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: probe]).width / 100
    }()

    static func columnWidth(size: Double) -> CGFloat { advance * CGFloat(size) }

    /// The smallest the text is made, as a share of the user's chat size: below it, lines wrap instead.
    static let smallestShare = 0.74
    static let smallestSize = 8.0

    /// The font size for text `columns` wide in `width` points: the user's own when it fits, otherwise smaller (never under
    /// `smallestShare` of it, nor 8 pt) so Claude's columns stay in line. Past that floor, long lines wrap.
    static func fontSize(columns: Int, width: CGFloat, chatSize: Double) -> Double {
        guard columns > 0, width > 0 else { return chatSize }
        let needed = CGFloat(columns) * columnWidth(size: chatSize)
        guard needed > width else { return chatSize }
        let fit = chatSize * Double(width / needed)
        let lowest = min(chatSize, max(smallestSize, chatSize * smallestShare))
        // Quarter points: the text does not shiver as the panel is resized.
        return max(lowest, (fit * 4).rounded(.down) / 4)
    }
}
