import AppKit
import CoreText

// Dresses Claude Code's transcript in the mirror so each voice reads differently: Daniel's own messages sit in
// a soft mint block, Claude's replies stay as plain text behind a terracotta dot, and tool calls and their results
// step back, dimmed and a point smaller. Only the presentation changes; the characters are never touched.
//
// Three pieces, all pure or AppKit-only:
// - `TranscriptClassifier` reads the shape of each line (never its meaning) and says which role it has.
// - `TranscriptStyler` turns roles into attributes, and restyles only from the edit point down.
// - `MirrorLayoutManager` paints the soft block behind user messages.
//
// Two things sit inside the roles, still recognised by shape alone (see `TranscriptClassifier.Detail`):
// - the rows of a change (`TranscriptRenderer.change`): numbered lines on a red or green band, their code coloured by
//   the file's language (`SyntaxHighlighter`), the way Claude's terminal draws an edit;
// - the fenced blocks of a reply (```lang … ```), their code coloured the same way.
//
// Every rule is conservative: a line that is not recognised with confidence is `plain` and looks exactly as it did.

// MARK: - Roles

/// What a line of Claude Code's transcript is, judged by its shape alone.
enum TranscriptRole: String, CaseIterable {
    /// Daniel's message: `> text` or `❯ text` at the left edge, wrapped lines indented under it.
    case user
    /// A reply: `⏺ text` at the left edge, wrapped lines and further paragraphs indented under it.
    case assistant
    /// A tool call: `⏺ Bash(swift test)`, `⏺ Read 3 files (ctrl+o to expand)`.
    case tool
    /// What a tool printed: `  ⎿  result` and the lines indented under it.
    case toolOutput
    /// Anything else, blank lines included.
    case plain
}

extension NSAttributedString.Key {
    /// The `TranscriptRole` raw value; absent on plain text.
    static let transcriptRole = NSAttributedString.Key("nook.transcript.role")
    /// A `TranscriptBubble` on the characters of a user message; `MirrorLayoutManager` paints it.
    static let transcriptBubble = NSAttributedString.Key("nook.transcript.bubble")
    /// An `NSColor` that `MirrorLayoutManager` paints behind the whole width of every line the characters sit on (the
    /// band of a changed row).
    static let transcriptLineFill = NSAttributedString.Key("nook.transcript.lineFill")
    /// On the dash of a list item: `MirrorLayoutManager` draws a bullet (•) in its place; the text keeps the dash.
    static let transcriptBullet = NSAttributedString.Key("nook.transcript.bullet")
}

// MARK: - Classifier

/// Reads Claude Code's plain screen text line by line. The role of a line depends only on the line itself and on
/// the lines above it (never on what follows), so restyling from any line on gives what styling everything would.
///
/// What it recognises, all anchored to the left edge where Claude draws its transcript (replies, code and results
/// are indented, so they never open a block of their own):
/// - `> text` / `❯ text`: the user's message. Menu options (`❯ 1. Yes`) are not messages.
/// - `⏺ text` / `● text`: a reply; but `⏺ Name(…`, `⏺ … (MCP)(…` and `⏺ … (ctrl+o to expand)` are tool calls.
/// - `  ⎿  text`: a tool result, and the indented lines after it.
/// - Indented lines continue the block above them, also across blank lines. Any other line at the left edge ends it.
enum TranscriptClassifier {
    /// Indentation still counted as the left edge; the same slack `AgentActivity` allows.
    static let edgeIndent = 1

    /// What the lines above leave open.
    struct State: Equatable {
        /// `.user`, `.assistant`, `.tool` or `.plain` (no block open).
        var block = TranscriptRole.plain
        /// Offset of the line that opened the block; -1 when none.
        var head = -1
        /// A `⎿` line was seen in this block: the indented lines after it are results.
        var inOutput = false
        /// The latest result is a change (see `ChangeSummary`): the numbered rows under it are code, not output.
        var change: ChangeContext?
        /// A fenced code block is open in this reply.
        var fence: FenceContext?
    }

    /// What the rows of a change are written in.
    struct ChangeContext: Equatable { var language: SyntaxLanguage? }
    /// An open fence in a reply; `language` is nil when it names none or one the highlighter does not know.
    struct FenceContext: Equatable { var language: SyntaxLanguage? }

    /// The summary line of a change, `  ⎿  Actualizado Sources/Notch.swift (+3 -2)` or `  ⎿  Creado README.md (15 líneas)`.
    struct ChangeSummary: Equatable {
        var path: NSRange
        /// `+3` and `-2`, when the line has them.
        var added: NSRange?
        var removed: NSRange?
        var language: SyntaxLanguage?
    }

    /// One row of a change: `      98   let a = 1`, `      99 - let b = 2`, `      99 + let b = 3`.
    struct ChangeRow: Equatable {
        enum Kind: Equatable { case removed, added, context, gap }
        var kind: Kind
        /// The mark ("-", "+" or the space of a context row); nil for a gap.
        var mark: NSRange?
        /// Where the code starts and ends (the line's characters, without its break); empty for a gap.
        var code: NSRange
        var language: SyntaxLanguage?
    }

    /// What a line holds beyond its role.
    enum Detail: Equatable {
        case none
        case summary(ChangeSummary)
        case row(ChangeRow)
        /// A ``` line of a reply.
        case fence
        /// A line of code inside a fence whose language is known; `start` is where the code begins (after the reply's indent).
        case code(SyntaxLanguage, start: Int)
        /// A line inside a fence whose language is not known: it keeps its plain look, and no Markdown is read in it.
        case verbatim
    }

    struct Line: Equatable {
        /// The line's characters, without its line break.
        var range: NSRange
        /// Offset just past the line break (or the end of the text).
        var end: Int
        var role: TranscriptRole
        /// Offset of the line that opened the block this line belongs to; -1 outside any block.
        var head: Int
        /// The `>`, `❯` or `⏺` that opens a block, or the `⎿` that opens a result.
        var marker: NSRange?
        /// The tool's name in `⏺ Name(…`.
        var name: NSRange?
        var isBlank: Bool
        var detail = Detail.none
    }

    // MARK: Entry points

    /// One role per line of `lines`, from index `first` on. The lines above `first` only provide context, so the
    /// result equals the tail of the roles of all lines.
    static func roles(of lines: [String], from first: Int = 0) -> [TranscriptRole] {
        guard first < lines.count else { return [] }
        let joined = lines.joined(separator: "\n") as NSString
        let offset = lines[..<first].reduce(0) { $0 + ($1 as NSString).length + 1 }
        var roles = self.lines(in: joined, from: offset).map(\.role)
        // A trailing empty line has no characters, so the scan does not visit it.
        while roles.count < lines.count - first { roles.append(.plain) }
        return roles
    }

    static func roles(of text: String) -> [TranscriptRole] { roles(of: text.components(separatedBy: "\n")) }

    /// Classifies every line from the line starting at `start` to the end. `state` is what the lines above leave
    /// open; when nil it is read from them.
    static func lines(in text: NSString, from start: Int = 0, state: State? = nil) -> [Line] {
        let length = text.length
        guard start >= 0, start < length else { return [] }
        var state = state ?? self.state(before: start, in: text)
        var chars = [unichar](repeating: 0, count: length - start)
        text.getCharacters(&chars, range: NSRange(location: start, length: length - start))
        var result: [Line] = []
        var lineStart = 0
        while lineStart < chars.count {
            var lineEnd = lineStart
            while lineEnd < chars.count, chars[lineEnd] != 0x0A { lineEnd += 1 }
            let line = classify(chars, lineStart..<lineEnd, base: start, state: &state)
            result.append(Line(range: line.range, end: min(start + lineEnd + 1, length), role: line.role, head: line.head,
                               marker: line.marker, name: line.name, isBlank: line.isBlank, detail: line.detail))
            lineStart = lineEnd + 1
        }
        return result
    }

    /// What the lines above `offset` (the start of a line) leave open: the block opened by the last left-edge line, whether
    /// a result is open and what it is (a change), and whether a fence is.
    static func state(before offset: Int, in text: NSString) -> State {
        var state = State()
        var inOutput = false
        // The nearest "⎿" above decides what the rows below it are.
        var change: ChangeContext?
        var seenOutput = false
        // Fence lines of the reply, nearest first. A "⎿" turns every line below it into a result, so they stop counting.
        var fences: [FenceMark] = []
        var end = min(offset, text.length)
        while end > 0 {
            let line = text.lineRange(for: NSRange(location: end - 1, length: 0))
            let content = lineChars(text, NSRange(location: line.location, length: max(0, min(line.length, end - line.location))))
            let shape = probe(content, 0..<content.count)
            switch shape.kind {
            case .blank: break
            case .output:
                inOutput = true
                if !seenOutput, let marker = shape.marker {
                    seenOutput = true
                    change = summary(content, 0..<content.count, marker: marker, base: 0).map { ChangeContext(language: $0.language) }
                }
                fences.removeAll()
            case .indented:
                if let mark = fenceMark(content, 0..<content.count, from: 0) { fences.append(mark) }
            case .user, .assistant, .tool:
                state.block = shape.kind == .user ? .user : shape.kind == .tool ? .tool : .assistant
                state.head = line.location
                state.inOutput = inOutput
                state.change = change
                if shape.kind == .assistant {
                    if let marker = shape.marker, let mark = fenceMark(content, 0..<content.count, from: marker.upperBound) { fences.append(mark) }
                    state.fence = replay(fences.reversed())
                }
                return state
            case .edge:
                // A left-edge line that opens nothing ends whatever was open before it, but a "⎿" below it still counts.
                return State(block: .plain, head: -1, inOutput: inOutput, change: change)
            }
            end = line.location
        }
        return State(block: .plain, head: -1, inOutput: inOutput, change: change)
    }

    // MARK: Lines

    private enum Kind { case blank, user, assistant, tool, output, indented, edge }

    private struct Probe {
        var kind: Kind
        var marker: Range<Int>?
        var name: Range<Int>?
    }

    private static func lineChars(_ text: NSString, _ range: NSRange) -> [unichar] {
        var chars = [unichar](repeating: 0, count: range.length)
        if range.length > 0 { text.getCharacters(&chars, range: range) }
        // The line break itself is not part of the content.
        while let last = chars.last, last == 0x0A { chars.removeLast() }
        return chars
    }

    private static func classify(_ chars: [unichar], _ span: Range<Int>, base: Int, state: inout State) -> (range: NSRange, role: TranscriptRole, head: Int, marker: NSRange?, name: NSRange?, isBlank: Bool, detail: Detail) {
        let shape = probe(chars, span)
        let range = NSRange(location: base + span.lowerBound, length: span.count)
        func shifted(_ r: Range<Int>?) -> NSRange? { r.map { NSRange(location: base + $0.lowerBound, length: $0.count) } }
        let lineStart = base + span.lowerBound
        switch shape.kind {
        case .blank:
            return (range, .plain, -1, nil, nil, true, .none)
        case .user:
            state = State(block: .user, head: lineStart, inOutput: false)
            return (range, .user, lineStart, shifted(shape.marker), nil, false, .none)
        case .assistant:
            state = State(block: .assistant, head: lineStart, inOutput: false)
            // A reply may open with a fence on its very first line ("⏺ ```swift").
            let detail = shape.marker.map { fenceDetail(chars, span, from: $0.upperBound, base: base, state: &state) } ?? .none
            return (range, .assistant, lineStart, shifted(shape.marker), nil, false, detail)
        case .tool:
            state = State(block: .tool, head: lineStart, inOutput: false)
            return (range, .tool, lineStart, shifted(shape.marker), shifted(shape.name), false, .none)
        case .edge:
            state = State()
            return (range, .plain, -1, nil, nil, false, .none)
        case .output:
            state.inOutput = true
            let found = shape.marker.flatMap { summary(chars, span, marker: $0, base: base) }
            state.change = found.map { ChangeContext(language: $0.language) }
            return (range, .toolOutput, state.head, shifted(shape.marker), nil, false, found.map(Detail.summary) ?? .none)
        case .indented:
            let role: TranscriptRole = state.inOutput || state.block == .tool ? .toolOutput : state.block
            var detail = Detail.none
            if role == .assistant { detail = fenceDetail(chars, span, from: span.lowerBound, base: base, state: &state) }
            else if role == .toolOutput, let change = state.change { detail = row(chars, span, base: base, in: change).map(Detail.row) ?? .none }
            return (range, role, state.head, nil, nil, false, detail)
        }
    }

    // MARK: Changes

    private static let updatedVerb = Array("Actualizado ".utf16)
    private static let createdVerb = Array("Creado ".utf16)
    /// The rows of a change start after `TranscriptRenderer.changeIndent`.
    private static let changeIndent = TranscriptRenderer.changeIndent.utf16.count

    /// The summary line of a change: the verb, the path, and the counts in parentheses. The marker is the "⎿".
    private static func summary(_ chars: [unichar], _ span: Range<Int>, marker: Range<Int>, base: Int) -> ChangeSummary? {
        var i = marker.upperBound
        while i < span.upperBound, isSpace(chars[i]) { i += 1 }
        let updated = matches(updatedVerb, in: chars, at: i, upTo: span.upperBound)
        guard updated || matches(createdVerb, in: chars, at: i, upTo: span.upperBound) else { return nil }
        let pathStart = i + (updated ? updatedVerb.count : createdVerb.count)
        var end = span.upperBound
        while end > pathStart, isSpace(chars[end - 1]) { end -= 1 }
        // The counts are the last parenthesis of the line; a path may hold parentheses of its own.
        guard end > pathStart, chars[end - 1] == 0x29 else { return nil }
        var open = end - 2
        while open > pathStart, chars[open] != 0x28 { open -= 1 }
        guard open > pathStart, chars[open] == 0x28, isSpace(chars[open - 1]) else { return nil }
        var pathEnd = open - 1
        while pathEnd > pathStart, isSpace(chars[pathEnd - 1]) { pathEnd -= 1 }
        guard pathEnd > pathStart else { return nil }
        func shifted(_ r: Range<Int>) -> NSRange { NSRange(location: base + r.lowerBound, length: r.count) }
        var result = ChangeSummary(path: shifted(pathStart..<pathEnd), language: SyntaxLanguage.forPath(String(decoding: chars[pathStart..<pathEnd], as: UTF16.self)))
        guard updated else { return result }
        // "+3 -2": each count is a sign and digits, separated by spaces.
        var k = open + 1
        while k < end - 1 {
            while k < end - 1, isSpace(chars[k]) { k += 1 }
            let start = k
            while k < end - 1, !isSpace(chars[k]) { k += 1 }
            guard k - start >= 2, isDigit(chars[start + 1]) else { continue }
            if chars[start] == 0x2B { result.added = shifted(start..<k) } else if chars[start] == 0x2D { result.removed = shifted(start..<k) }
        }
        return result
    }

    private static func matches(_ word: [unichar], in chars: [unichar], at index: Int, upTo end: Int) -> Bool {
        guard index + word.count <= end else { return false }
        for (offset, unit) in word.enumerated() where chars[index + offset] != unit { return false }
        return true
    }

    /// A numbered row of a change: six spaces (more, for narrower numbers), the number, a space, the mark, a space and
    /// the code. A row of "…" stands for a gap between hunks or for the lines left out. Anything else is not a row.
    private static func row(_ chars: [unichar], _ span: Range<Int>, base: Int, in change: ChangeContext) -> ChangeRow? {
        var i = span.lowerBound
        while i < span.upperBound, chars[i] == 0x20 { i += 1 }
        guard i - span.lowerBound >= changeIndent, i < span.upperBound else { return nil }
        func shifted(_ r: Range<Int>) -> NSRange { NSRange(location: base + r.lowerBound, length: r.count) }
        if chars[i] == 0x2026 { return ChangeRow(kind: .gap, mark: nil, code: shifted(span.upperBound..<span.upperBound), language: nil) }
        var j = i
        while j < span.upperBound, isDigit(chars[j]) { j += 1 }
        guard j > i else { return nil }
        // Rows may arrive with their trailing spaces trimmed: the number alone, or the number and the mark.
        var kind = ChangeRow.Kind.context
        var mark: Range<Int>?
        var codeStart = span.upperBound
        if j < span.upperBound {
            guard chars[j] == 0x20 else { return nil }
            if j + 1 < span.upperBound {
                switch chars[j + 1] {
                case 0x2D: kind = .removed
                case 0x2B: kind = .added
                case 0x20: kind = .context
                default: return nil
                }
                mark = (j + 1)..<(j + 2)
                if j + 2 < span.upperBound {
                    guard chars[j + 2] == 0x20 else { return nil }
                    codeStart = j + 3
                }
            }
        }
        return ChangeRow(kind: kind, mark: mark.map(shifted), code: shifted(min(codeStart, span.upperBound)..<span.upperBound), language: change.language)
    }

    // MARK: Fences

    struct FenceMark: Equatable {
        /// Nothing after the backticks: it can close a fence as well as open one.
        var bare: Bool
        var info: String
    }

    /// A ``` (or ~~~) line: three or more of the same mark, then at most a language name. `from` skips what is not text
    /// (the reply's marker).
    static func fenceMark(_ chars: [unichar], _ span: Range<Int>, from start: Int) -> FenceMark? {
        var i = max(start, span.lowerBound)
        while i < span.upperBound, isSpace(chars[i]) { i += 1 }
        guard i + 2 < span.upperBound, chars[i] == 0x60 || chars[i] == 0x7E else { return nil }
        let mark = chars[i]
        var j = i
        while j < span.upperBound, chars[j] == mark { j += 1 }
        guard j - i >= 3 else { return nil }
        let info = String(decoding: chars[j..<span.upperBound], as: UTF16.self).trimmingCharacters(in: .whitespaces)
        // "```code```" on one line is inline code, not a fence.
        if mark == 0x60, info.contains("`") { return nil }
        return FenceMark(bare: info.isEmpty, info: info)
    }

    /// The fence a reply has open after these lines, oldest first.
    private static func replay(_ marks: [FenceMark]) -> FenceContext? {
        var open: FenceContext?
        for mark in marks {
            if open == nil { open = FenceContext(language: SyntaxLanguage.forFence(mark.info)) }
            else if mark.bare { open = nil }
        }
        return open
    }

    /// Advances the fence state over one line of a reply and says what the line is.
    private static func fenceDetail(_ chars: [unichar], _ span: Range<Int>, from start: Int, base: Int, state: inout State) -> Detail {
        if let mark = fenceMark(chars, span, from: start) {
            if state.fence == nil { state.fence = FenceContext(language: SyntaxLanguage.forFence(mark.info)); return .fence }
            if mark.bare { state.fence = nil; return .fence }
            // A fence with a language inside a fence is code (a Markdown example), not the end of it.
        }
        guard let open = state.fence else { return .none }
        guard let language = open.language else { return .verbatim }
        // The reply's own indent (two columns) is not part of the code.
        var code = span.lowerBound
        while code < span.upperBound, code < span.lowerBound + 2, chars[code] == 0x20 { code += 1 }
        return .code(language, start: base + code)
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x0D }
    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    private static let userMarks: Set<unichar> = [0x3E, 0x276F]   // > ❯
    private static let bullets: Set<unichar> = [0x23FA, 0x25CF]   // ⏺ ●
    private static let resultMark: unichar = 0x23BF               // ⎿

    private static func probe(_ chars: [unichar], _ span: Range<Int>) -> Probe {
        var i = span.lowerBound
        while i < span.upperBound, isSpace(chars[i]) { i += 1 }
        guard i < span.upperBound else { return Probe(kind: .blank) }
        let indent = i - span.lowerBound
        let first = chars[i]
        guard indent <= edgeIndent else {
            return first == resultMark ? Probe(kind: .output, marker: i..<(i + 1)) : Probe(kind: .indented)
        }
        if userMarks.contains(first) {
            // "> text": the mark, a space, then something that is not a numbered menu option ("❯ 1. Yes").
            guard i + 1 < span.upperBound, isSpace(chars[i + 1]) else { return Probe(kind: .edge) }
            var j = i + 1
            while j < span.upperBound, isSpace(chars[j]) { j += 1 }
            guard j < span.upperBound else { return Probe(kind: .edge) }
            var k = j
            while k < span.upperBound, isDigit(chars[k]) { k += 1 }
            if k > j, k < span.upperBound, chars[k] == 0x2E || chars[k] == 0x29, k + 1 == span.upperBound || isSpace(chars[k + 1]) {
                return Probe(kind: .edge)
            }
            return Probe(kind: .user, marker: i..<(i + 1))
        }
        if bullets.contains(first) {
            var after = i + 1
            if after < span.upperBound, chars[after] == 0xFE0F { after += 1 }
            let marker = i..<after
            // A bare dot is Claude starting to write; a dot glued to a word is not a marker.
            guard after < span.upperBound else { return Probe(kind: .assistant, marker: marker) }
            guard isSpace(chars[after]) else { return Probe(kind: .edge) }
            var start = after
            while start < span.upperBound, isSpace(chars[start]) { start += 1 }
            guard start < span.upperBound else { return Probe(kind: .assistant, marker: marker) }
            let content = String(utf16CodeUnits: Array(chars[start..<min(span.upperBound, start + 400)]), count: min(span.upperBound, start + 400) - start)
            if let call = toolCall(content) {
                return Probe(kind: .tool, marker: marker, name: call == 0 ? nil : start..<(start + call))
            }
            return Probe(kind: .assistant, marker: marker)
        }
        return Probe(kind: .edge)
    }

    /// Whether the text after a `⏺` is a tool call. Returns the length of the tool's name (0 when it has none to
    /// show, as in "Read 3 files (ctrl+o to expand)"), or nil when it is a reply. Replies win when unsure.
    private static func toolCall(_ content: String) -> Int? {
        let whole = NSRange(location: 0, length: (content as NSString).length)
        if let match = Patterns.call.firstMatch(in: content, range: whole) { return match.range(at: 1).length }
        if Patterns.mcp.firstMatch(in: content, range: whole) != nil { return 0 }
        if Patterns.expand.firstMatch(in: content, range: whole) != nil { return 0 }
        return nil
    }

    private enum Patterns {
        /// `Bash(…`, `MultiEdit(…`, `mcp__server__tool(…`, `codex:codex-rescue(…`: tool names are PascalCase or qualified.
        /// A bare lowercase word before a parenthesis ("print(x) shows…") is a sentence.
        static let call = try! NSRegularExpression(pattern: #"^((?:[A-Z][A-Za-z0-9]*|mcp__[A-Za-z0-9_-]+|[a-z][a-z0-9_-]*:[A-Za-z0-9_.:-]+))\("#)
        /// `slack - Search messages (MCP)(query: "x")`.
        static let mcp = try! NSRegularExpression(pattern: #"^[^()]{1,80}\(MCP\)"#)
        /// Collapsed tool summaries: `Read 3 files (ctrl+o to expand)`, `2 background agents launched (↓ to manage)`.
        static let expand = try! NSRegularExpression(pattern: #"\((?:ctrl\+o to expand|↓ to manage)[^)]*\)\s*$"#)
    }
}

// MARK: - Look

/// A soft block behind a user message. It travels with the text as an attribute, so a theme change that restyles
/// the text repaints the block, and neighbouring messages stay apart through their `id`.
final class TranscriptBubble: NSObject {
    let id: Int
    let fill: NSColor
    let stroke: NSColor
    /// A small word on the block's top edge ("Tarea" on the first message of an agent's conversation).
    let label: String?
    /// The colour of that word: the block's own.
    let accent: NSColor
    /// A word on a pill inside the block's right end ("En cola"): a message that is not in the conversation yet.
    let tag: Tag?

    struct Tag: Equatable {
        var text: String
        var fill: NSColor
        var ink: NSColor
    }

    init(id: Int, fill: NSColor, stroke: NSColor, label: String? = nil, accent: NSColor = TranscriptPalette.mint, tag: Tag? = nil) {
        self.id = id; self.fill = fill; self.stroke = stroke; self.label = label; self.accent = accent; self.tag = tag
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptBubble else { return false }
        return id == other.id && fill == other.fill && stroke == other.stroke && label == other.label && accent == other.accent && tag == other.tag
    }
    override var hash: Int { id }
}

/// Colors for the transcript, for the dark island and for the light one. The user's messages wear the tab's color (mint unless the user chose
/// another: Nook's own accent), in the shades it has in each theme (`TabTint.voice(_:)`); terracotta is Claude's own spinner color. In the light theme
/// everything that is read (text, markers, code) keeps 4.5 : 1 on the paper (`Tests/TranscriptStyleTests`), and what is only drawn (a bar, a block's fill) 3 : 1.
struct TranscriptPalette {
    static let mint = TabTint.mint.shades.accent.nsColor
    static let terracotta = NookPalette.terracottaOnBlack

    /// Plain text and Claude's replies.
    let text: NSColor
    let userText: NSColor
    let userMarker: NSColor
    /// The solid color of the user's message block (its fill and outline are this one, faint).
    let accent: NSColor
    /// The color of the small words that stand on a block (the task's tab): the accent on black, and on paper a deeper shade, which is readable.
    let labelInk: NSColor
    let assistantMarker: NSColor
    let toolMarker: NSColor
    let toolName: NSColor
    let tool: NSColor
    let output: NSColor
    let outputMarker: NSColor
    let bubbleFill: NSColor
    let bubbleStroke: NSColor
    /// A change's rows: the band behind a removed or an added line, the number column, the "-" and "+" marks, and the code.
    let removedFill: NSColor
    let addedFill: NSColor
    let gutter: NSColor
    let removedMark: NSColor
    let addedMark: NSColor
    /// Code on a changed row, and on a row that is only there for context.
    let changedCode: NSColor
    let contextCode: NSColor
    /// The path in a change's summary line.
    let changePath: NSColor
    /// The Markdown of a reply: a heading, `inline code` (its colour and the soft block behind it), and a link.
    let heading: NSColor
    let inlineCode: NSColor
    let inlineCodeFill: NSColor
    let link: NSColor
    private let syntax: [SyntaxToken: NSColor]

    /// The colour of a kind of code.
    func color(_ token: SyntaxToken) -> NSColor { syntax[token] ?? text }

    /// The island's warm ink, which the light palette's text is made of.
    private static let ink = NSColor(srgbRed: 0.110, green: 0.105, blue: 0.095, alpha: 1)
    private static func inked(_ alpha: CGFloat) -> NSColor { ink.withAlphaComponent(alpha) }

    /// `voice` is the tab's, in the theme's shades (the dark palette takes the light-on-black ones, the light palette the deep ones); without one it is mint's,
    /// in the theme's own.
    init(dark: Bool, voice: TabVoice? = nil) {
        let voice = voice ?? TabTint.mint.voice(dark ? .dark : .light)
        if dark {
            text = .white
            userText = voice.text.nsColor
            userMarker = voice.marker.nsColor
            accent = voice.accent.nsColor
            labelInk = voice.accent.nsColor
            assistantMarker = Self.terracotta
            toolMarker = NSColor(white: 1, alpha: 0.34)
            toolName = NSColor(white: 1, alpha: 0.72)
            tool = NSColor(white: 1, alpha: 0.56)
            output = NSColor(white: 1, alpha: 0.46)
            outputMarker = NSColor(white: 1, alpha: 0.38)
            bubbleFill = voice.accent.nsColor.withAlphaComponent(0.15)
            bubbleStroke = voice.accent.nsColor.withAlphaComponent(0.24)
            removedFill = NSColor(red: 0.30, green: 0.10, blue: 0.12, alpha: 1)
            addedFill = NSColor(red: 0.09, green: 0.25, blue: 0.14, alpha: 1)
            gutter = NSColor(white: 1, alpha: 0.36)
            removedMark = NSColor(red: 1.0, green: 0.46, blue: 0.46, alpha: 1)
            addedMark = NSColor(red: 0.46, green: 0.90, blue: 0.56, alpha: 1)
            changedCode = NSColor(white: 1, alpha: 0.94)
            contextCode = NSColor(white: 1, alpha: 0.66)
            changePath = NSColor(white: 1, alpha: 0.92)
            heading = NSColor(red: 1.0, green: 0.87, blue: 0.78, alpha: 1)
            inlineCode = NSColor(red: 0.66, green: 0.83, blue: 1.0, alpha: 1)
            inlineCodeFill = NSColor(white: 1, alpha: 0.10)
            link = NSColor(red: 0.50, green: 0.75, blue: 1.0, alpha: 1)
            syntax = [
                .keyword: NSColor(red: 0.85, green: 0.62, blue: 0.97, alpha: 1), .string: NSColor(red: 0.96, green: 0.72, blue: 0.50, alpha: 1),
                .number: NSColor(red: 0.74, green: 0.89, blue: 0.66, alpha: 1), .comment: NSColor(red: 0.56, green: 0.62, blue: 0.60, alpha: 1),
                .type: NSColor(red: 0.45, green: 0.85, blue: 0.83, alpha: 1), .function: NSColor(red: 0.96, green: 0.90, blue: 0.64, alpha: 1),
                .attribute: NSColor(red: 0.58, green: 0.78, blue: 1.0, alpha: 1), .variable: NSColor(red: 0.66, green: 0.85, blue: 0.98, alpha: 1),
                .inserted: NSColor(red: 0.46, green: 0.90, blue: 0.56, alpha: 1), .deleted: NSColor(red: 1.0, green: 0.50, blue: 0.50, alpha: 1),
            ]
        } else {
            text = Self.ink
            userText = voice.text.nsColor
            userMarker = voice.marker.nsColor
            accent = voice.accent.nsColor
            labelInk = voice.marker.nsColor
            // Claude's marker is drawn, not read: the brighter rust (3.4 : 1 on the paper), as the glyph in its spinner is.
            assistantMarker = NookPalette.terracottaFillLight
            toolMarker = Self.inked(0.49)
            toolName = Self.inked(0.76)
            tool = Self.inked(0.64)
            output = Self.inked(0.64)
            outputMarker = Self.inked(0.49)
            bubbleFill = voice.accent.nsColor.withAlphaComponent(0.15)
            bubbleStroke = voice.accent.nsColor.withAlphaComponent(0.30)
            removedFill = NSColor(red: 0.99, green: 0.86, blue: 0.85, alpha: 1)
            addedFill = NSColor(red: 0.84, green: 0.95, blue: 0.84, alpha: 1)
            gutter = Self.inked(0.52)
            removedMark = NSColor(red: 0.72, green: 0.11, blue: 0.15, alpha: 1)
            addedMark = NSColor(red: 0.06, green: 0.46, blue: 0.18, alpha: 1)
            changedCode = Self.inked(0.92)
            contextCode = Self.inked(0.68)
            changePath = Self.inked(0.88)
            heading = NSColor(red: 0.62, green: 0.25, blue: 0.10, alpha: 1)
            inlineCode = NSColor(red: 0.08, green: 0.34, blue: 0.62, alpha: 1)
            inlineCodeFill = Self.inked(0.07)
            link = NSColor(red: 0.05, green: 0.36, blue: 0.80, alpha: 1)
            syntax = [
                .keyword: NSColor(red: 0.55, green: 0.18, blue: 0.70, alpha: 1), .string: NSColor(red: 0.66, green: 0.30, blue: 0.06, alpha: 1),
                .number: NSColor(red: 0.10, green: 0.43, blue: 0.19, alpha: 1), .comment: NSColor(red: 0.36, green: 0.42, blue: 0.40, alpha: 1),
                .type: NSColor(red: 0.03, green: 0.42, blue: 0.46, alpha: 1), .function: NSColor(red: 0.47, green: 0.35, blue: 0.0, alpha: 1),
                .attribute: NSColor(red: 0.10, green: 0.32, blue: 0.72, alpha: 1), .variable: NSColor(red: 0.12, green: 0.36, blue: 0.62, alpha: 1),
                .inserted: NSColor(red: 0.06, green: 0.46, blue: 0.18, alpha: 1), .deleted: NSColor(red: 0.72, green: 0.11, blue: 0.15, alpha: 1),
            ]
        }
    }
}

// MARK: - Styler

enum TranscriptStyler {
    /// Height of a blank line: paragraphs breathe, but a blank line does not cost a whole text line.
    static let blankLineHeight: CGFloat = 9
    /// A blank line grows with the text: 9 pt at the default 11 pt, in proportion for the user's chat size.
    static func blankLineHeight(for font: NSFont) -> CGFloat {
        (blankLineHeight * font.pointSize / CGFloat(DisplaySettings.defaultChatSize)).rounded()
    }
    /// Space kept between a message block and a line that follows it with nothing in between.
    static let gapAfterBubble: CGFloat = 8

    /// Restyles the text from the line that holds `location` to the end. Call it inside the same editing session
    /// that replaced the text from `location` on (everything before it must be unchanged): the result is what
    /// `restyle(storage, from: 0, …)` gives. A user message still open at that point is restyled from its first
    /// line, so its block is repainted as one piece.
    ///
    /// `taskLabel` puts that word on the top edge of the text's first message (the task an agent's conversation opens with).
    /// `voice` is the colours of the user's messages: the tab's.
    static func restyle(_ storage: NSTextStorage, from location: Int, dark: Bool, font: NSFont, taskLabel: String? = nil, voice: TabVoice? = nil) {
        let length = storage.length
        guard length > 0 else { return }
        let text = storage.mutableString as NSString
        let sheet = Sheet(dark: dark, font: font, taskLabel: taskLabel, voice: voice)

        // Where attributes are rewritten from, and the line above it, read only to know what sits next to it.
        var apply = 0
        if location > 0 {
            apply = text.lineRange(for: NSRange(location: min(location, length), length: 0)).location
            let open = TranscriptClassifier.state(before: apply, in: text)
            if open.block == .user, !open.inOutput, open.head >= 0 { apply = min(apply, open.head) }
        }
        let context = apply > 0 ? text.lineRange(for: NSRange(location: apply - 1, length: 0)).location : 0

        storage.beginEditing()
        defer { storage.endEditing() }
        var pending: (range: NSRange, key: Sheet.Key)?
        var attributes: [Sheet.Key: [NSAttributedString.Key: Any]] = [:]
        func flush() {
            guard let item = pending else { return }
            let found = attributes[item.key] ?? sheet.attributes(item.key)
            attributes[item.key] = found
            storage.setAttributes(found, range: item.range)
            pending = nil
        }
        func put(_ range: NSRange, _ key: Sheet.Key) {
            guard range.length > 0 else { return }
            if var item = pending, item.key == key, NSMaxRange(item.range) == range.location {
                item.range.length += range.length
                pending = item
            } else {
                flush()
                pending = (range, key)
            }
        }

        // The addresses of links, put on their text once everything else is written.
        var links: [InlineMarkdown.Link] = []
        var previous: TranscriptClassifier.Line?
        for line in TranscriptClassifier.lines(in: text, from: context) {
            defer { previous = line }
            guard line.range.location >= apply else { continue }
            // Room below a user message that nothing separates from the next line.
            let gap = previous.map { $0.role == .user && !line.isBlank && !($0.head == line.head && line.role == .user) } ?? false
            let whole = NSRange(location: line.range.location, length: line.end - line.range.location)
            let block = line.role == .user ? line.head : -1
            // A "●" is in the monospaced font already, and "⏺" followed by a variation selector is an emoji whatever the
            // font: both keep the system's own drawing, with the line's own font and height.
            var native = false
            if let marker = line.marker, line.role == .assistant || line.role == .tool {
                native = marker.length > 1 || text.character(at: marker.location) == 0x25CF
            }
            var fit = Sheet.Fit.none
            if line.marker != nil, !native {
                switch line.role {
                case .assistant: fit = .assistantDot
                case .tool: fit = .toolDot
                case .toolOutput: fit = .result
                default: break
                }
            }
            // The first message of the text, when it is the one that carries the label.
            let task = taskLabel != nil && block == 0
            // The Markdown of a reply's line (the text after its dot, or the whole continuation line) is read once: it gives the
            // line's pieces, and where a list item's wrapped lines hang.
            var markdown: InlineMarkdown.Result?
            var textStart = line.range.location
            if line.role == .assistant, line.detail == .none, !line.isBlank {
                textStart = line.marker.map { NSMaxRange($0) } ?? line.range.location
                markdown = InlineMarkdown.parse(text, range: NSRange(location: textStart, length: max(0, NSMaxRange(line.range) - textStart)))
            }
            let indent = markdown?.hang.map { $0 + textStart - line.range.location } ?? 0
            func key(_ kind: Sheet.Kind) -> Sheet.Key { Sheet.Key(kind: kind, gap: gap, block: block, fit: fit, native: native, task: task, indent: indent) }
            // The code of a row or of a fenced line, split by what each stretch is.
            func putCode(_ code: NSRange, language: SyntaxLanguage?, as codeLine: Sheet.CodeLine, hang: Int = 0) {
                func codeKey(_ token: SyntaxToken?) -> Sheet.Key { Sheet.Key(kind: .code(codeLine, token), gap: gap, block: block, hang: hang) }
                var cursor = code.location
                if let language, code.length > 0 {
                    for span in SyntaxHighlighter.spans(in: text, range: code, language: language) {
                        put(NSRange(location: cursor, length: span.range.location - cursor), codeKey(nil))
                        put(span.range, codeKey(span.token))
                        cursor = NSMaxRange(span.range)
                    }
                }
                // The rest of the code, and the line break.
                put(NSRange(location: cursor, length: NSMaxRange(whole) - cursor), codeKey(nil))
            }
            // The text of a line. In a reply, the Markdown in it (bold, italic, `code`, headings, bullets, links) is dressed;
            // nothing else ever is.
            func putText(_ range: NSRange) {
                guard line.role == .assistant, line.detail == .none, range.length > 0 else { return put(range, key(.text(line.role))) }
                guard let found = markdown else { return put(range, key(.text(line.role))) }
                var cursor = range.location
                for run in found.runs {
                    put(NSRange(location: cursor, length: run.range.location - cursor), key(.text(line.role)))
                    put(run.range, key(.markup(run.style)))
                    cursor = NSMaxRange(run.range)
                }
                put(NSRange(location: cursor, length: NSMaxRange(range) - cursor), key(.text(line.role)))
                links += found.links
            }
            if line.isBlank {
                put(whole, Sheet.Key(kind: .blank))
            } else if case .row(let row) = line.detail {
                // A row's wrapped lines hang under the first character of its code, as an editor's soft wrap does.
                var hang = 0
                if row.kind != .gap {
                    var indent = row.code.location
                    while indent < NSMaxRange(row.code), text.character(at: indent) == 0x20 { indent += 1 }
                    hang = min(indent - line.range.location, Sheet.maxHang)
                }
                let codeLine: Sheet.CodeLine = row.kind == .removed ? .removed : row.kind == .added ? .added : .context
                if row.kind == .gap {
                    put(whole, Sheet.Key(kind: .gap, hang: 0))
                } else {
                    func rowKey(_ kind: Sheet.Kind) -> Sheet.Key { Sheet.Key(kind: kind, hang: hang) }
                    if let mark = row.mark {
                        let (before, after) = split(NSRange(location: line.range.location, length: row.code.location - line.range.location), at: mark)
                        put(before, rowKey(.gutter(codeLine)))
                        put(mark, rowKey(.mark(codeLine)))
                        put(after, rowKey(.gutter(codeLine)))
                    } else {
                        put(NSRange(location: line.range.location, length: row.code.location - line.range.location), rowKey(.gutter(codeLine)))
                    }
                    putCode(row.code, language: row.language, as: codeLine, hang: hang)
                }
            } else if let marker = line.marker {
                let (before, rest) = split(whole, at: marker)
                put(before, key(.text(line.role)))
                put(marker, key(.marker(line.role)))
                if let name = line.name, name.location >= NSMaxRange(marker) {
                    let (between, tail) = split(rest, at: name)
                    put(between, key(.text(line.role)))
                    put(name, key(.toolName))
                    put(tail, key(.text(line.role)))
                } else if case .summary(let summary) = line.detail {
                    // "Actualizado path (+3 -2)": the path stands out, the counts take the colours of the rows.
                    let (lead, afterPath) = split(rest, at: summary.path)
                    put(lead, key(.text(line.role)))
                    put(summary.path, key(.changePath))
                    var cursor = NSMaxRange(summary.path)
                    for (count, added) in [(summary.added, true), (summary.removed, false)].compactMap({ pair in pair.0.map { ($0, pair.1) } }).sorted(by: { $0.0.location < $1.0.location }) {
                        put(NSRange(location: cursor, length: count.location - cursor), key(.text(line.role)))
                        put(count, key(.changeCount(added: added)))
                        cursor = NSMaxRange(count)
                    }
                    put(NSRange(location: cursor, length: NSMaxRange(afterPath) - cursor), key(.text(line.role)))
                } else if line.detail == .fence {
                    // A reply that opens with a fence: the marker keeps Claude's dot, the fence is dimmed.
                    put(rest, key(.fence))
                } else {
                    putText(rest)
                }
            } else if case .code(let language, let start) = line.detail {
                put(NSRange(location: line.range.location, length: start - line.range.location), key(.text(line.role)))
                putCode(NSRange(location: start, length: NSMaxRange(line.range) - start), language: language, as: .fenced)
            } else if line.detail == .fence {
                put(whole, key(.fence))
            } else {
                putText(whole)
            }
        }
        flush()
        // A link's text opens its address when clicked, and says where it goes when pointed at.
        for link in links {
            var attributes: [NSAttributedString.Key: Any] = [.toolTip: link.url]
            if link.opens, let url = URL(string: link.url) { attributes[.link] = url }
            storage.addAttributes(attributes, range: link.range)
        }
    }

    /// Takes every transcript attribute off the text and gives it plain attributes again: for a tab that stopped
    /// showing Claude, or any text that is not a transcript.
    static func reset(_ storage: NSTextStorage, dark: Bool, font: NSFont) {
        guard storage.length > 0 else { return }
        let sheet = Sheet(dark: dark, font: font)
        storage.beginEditing()
        storage.setAttributes(sheet.attributes(Sheet.Key(kind: .text(.plain))), range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// The part of `range` before `piece` and the part from the end of `piece` on.
    private static func split(_ range: NSRange, at piece: NSRange) -> (NSRange, NSRange) {
        let head = NSRange(location: range.location, length: max(0, piece.location - range.location))
        let tailStart = min(NSMaxRange(range), NSMaxRange(piece))
        return (head, NSRange(location: tailStart, length: NSMaxRange(range) - tailStart))
    }

    // MARK: Sheet

    /// Every attribute set the styler can produce, for one theme and one base font.
    struct Sheet {
        enum Kind: Hashable {
            case blank
            case text(TranscriptRole)
            case marker(TranscriptRole)
            case toolName
            /// The path and the counts of a change's summary line.
            case changePath
            case changeCount(added: Bool)
            /// A change's row: its number column, its mark, its code (by kind of token; nil is plain code), and a gap.
            case gutter(CodeLine)
            case mark(CodeLine)
            case code(CodeLine, SyntaxToken?)
            case gap
            /// A ``` line of a reply.
            case fence
            /// A stretch of a reply the Markdown dresses (see `InlineMarkdown`).
            case markup(MarkupStyle)
        }

        /// Which kind of line a piece of code sits on: the band behind it and the weight of its colours follow.
        enum CodeLine: Hashable { case removed, added, context, fenced }

        /// Which glyph on the line comes from a font of its own, and so changes the line's height.
        enum Fit: Hashable { case none, assistantDot, toolDot, result }

        struct Key: Hashable {
            var kind: Kind
            /// Directly below a message block: gets a little room above.
            var gap = false
            /// The user message the characters belong to (its first line's offset); -1 for anything else.
            var block = -1
            var fit = Fit.none
            /// The line's marker needs no font of its own (see `restyle`).
            var native = false
            /// For a row of a change: how many columns its code starts at, where its wrapped lines hang.
            var hang = 0
            /// The message block carries the sheet's task label.
            var task = false
            /// For a reply's list item: how many columns of the reply's font its text starts at, where wrapped lines hang.
            var indent = 0
        }

        /// The most columns a wrapped row hangs by, so a deeply indented line still has room to wrap.
        static let maxHang = 32

        /// A glyph the monospaced font lacks, in a font that has it.
        struct Glyph {
            var font: NSFont
            /// Restores the width of one column of the line's own font.
            var kern: CGFloat
            /// Cancels the leading the glyph's font adds to its line.
            var spacing: CGFloat
        }

        let palette: TranscriptPalette
        let base: NSFont
        let small: NSFont
        let smallName: NSFont
        let userMarker: NSFont
        let userText: NSFont
        /// A change's rows and marks: the tool lines' size, and the mark a little heavier.
        let rowMark: NSFont
        /// One column of the rows' font, for the hanging indent of a wrapped row.
        let rowColumn: CGFloat
        /// `⏺` would fall back to the color emoji font: a tile two columns wide that ignores the text color. A text font
        /// draws it as a plain dot that takes Claude's color.
        let assistantDot: Glyph?
        let toolDot: Glyph?
        /// `⎿` is not in the monospaced font either; its fallback is proportional and shifts the text after it.
        let resultMark: Glyph?

        /// The word on the first message's top edge, for the keys that ask for it.
        let taskLabel: String?
        /// The reply's fonts for bold, italic and both. `italicSkew` is true when the monospaced font has no italic of its own:
        /// the letters are slanted instead.
        let bold: NSFont
        let italic: NSFont
        let boldItalic: NSFont
        let italicSkew: Bool
        /// One column of the reply's font: the room a hidden mark gives back.
        let column: CGFloat

        init(dark: Bool, font: NSFont, taskLabel: String? = nil, voice: TabVoice? = nil) {
            palette = TranscriptPalette(dark: dark, voice: voice)
            self.taskLabel = taskLabel
            base = font
            column = ("0" as NSString).size(withAttributes: [.font: font]).width
            let heavy = font.isFixedPitch ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold) : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            bold = heavy
            let manager = NSFontManager.shared
            func slanted(_ f: NSFont) -> NSFont? {
                let converted = manager.convert(f, toHaveTrait: .italicFontMask)
                return manager.traits(of: converted).contains(.italicFontMask) ? converted : nil
            }
            italic = slanted(font) ?? font
            boldItalic = slanted(heavy) ?? heavy
            italicSkew = slanted(font) == nil
            func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
                font.isFixedPitch ? .monospacedSystemFont(ofSize: size, weight: weight) : NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            }
            let smaller = mono(max(8, font.pointSize - 1), .regular)
            small = smaller
            smallName = mono(max(8, font.pointSize - 1), .medium)
            userMarker = mono(font.pointSize, .bold)
            userText = mono(font.pointSize, .medium)
            rowMark = mono(max(8, font.pointSize - 1), .bold)
            rowColumn = ("0" as NSString).size(withAttributes: [.font: smaller]).width
            assistantDot = Sheet.glyph(0x23FA, in: "STIXTwoMath-Regular", size: font.pointSize + 1, line: font)
            toolDot = Sheet.glyph(0x23FA, in: "STIXTwoMath-Regular", size: smaller.pointSize + 1, line: smaller)
            resultMark = Sheet.glyph(0x23BF, in: "AppleSymbols", size: smaller.pointSize + 3, line: smaller)
        }

        /// The font `name` for `unit`, with the kern that keeps the column as wide as the line's own font makes it and
        /// the spacing that takes back the leading the font adds to its line. Nil when the font is missing or lacks the
        /// glyph: the system fallback applies then.
        private static func glyph(_ unit: unichar, in name: String, size: CGFloat, line: NSFont) -> Glyph? {
            guard let font = NSFont(name: name, size: size) else { return nil }
            var char = unit
            var glyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1), glyph != 0 else { return nil }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            var space: unichar = 0x20
            var spaceGlyph = CGGlyph(0)
            var column = CGSize.zero
            guard CTFontGetGlyphsForCharacters(line, &space, &spaceGlyph, 1) else { return nil }
            CTFontGetAdvancesForGlyphs(line, .horizontal, &spaceGlyph, &column, 1)
            return Glyph(font: font, kern: column.width - advance.width, spacing: -font.leading)
        }

        func attributes(_ key: Key) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any]
            switch key.kind {
            case .blank:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let blank = TranscriptStyler.blankLineHeight(for: base)
                paragraph.minimumLineHeight = blank
                paragraph.maximumLineHeight = blank
                return [.font: base, .foregroundColor: palette.text, .paragraphStyle: paragraph]
            case .text(.plain):
                return [.font: base, .foregroundColor: palette.text, .paragraphStyle: paragraph(key)]
            case .text(let role):
                switch role {
                case .user: attributes = [.font: userText, .foregroundColor: palette.userText]
                case .assistant: attributes = [.font: base, .foregroundColor: palette.text]
                case .tool: attributes = [.font: small, .foregroundColor: palette.tool]
                case .toolOutput: attributes = [.font: small, .foregroundColor: palette.output]
                case .plain: attributes = [:]
                }
                attributes[.transcriptRole] = role.rawValue
            case .marker(let role):
                var glyph: Glyph?
                switch role {
                case .user: attributes = [.font: userMarker, .foregroundColor: palette.userMarker]
                case .tool: attributes = [.font: small, .foregroundColor: palette.toolMarker]; glyph = toolDot
                case .toolOutput: attributes = [.font: small, .foregroundColor: palette.outputMarker]; glyph = resultMark
                default: attributes = [.font: base, .foregroundColor: palette.assistantMarker]; glyph = assistantDot
                }
                if let glyph, !key.native {
                    attributes[.font] = glyph.font
                    attributes[.kern] = glyph.kern
                }
                attributes[.transcriptRole] = role.rawValue
            case .toolName:
                attributes = [.font: smallName, .foregroundColor: palette.toolName, .transcriptRole: TranscriptRole.tool.rawValue]
            case .changePath:
                attributes = [.font: smallName, .foregroundColor: palette.changePath, .transcriptRole: TranscriptRole.toolOutput.rawValue]
            case .changeCount(let added):
                attributes = [.font: smallName, .foregroundColor: added ? palette.addedMark : palette.removedMark, .transcriptRole: TranscriptRole.toolOutput.rawValue]
            case .gap:
                attributes = [.font: small, .foregroundColor: palette.outputMarker, .transcriptRole: TranscriptRole.toolOutput.rawValue]
            case .fence:
                attributes = [.font: base, .foregroundColor: palette.output, .transcriptRole: TranscriptRole.assistant.rawValue]
            case .markup(let style):
                attributes = markupAttributes(style)
            case .gutter(let line):
                attributes = [.font: line == .fenced ? base : small, .foregroundColor: palette.gutter, .transcriptRole: Self.role(of: line).rawValue]
                if let fill = fill(line) { attributes[.transcriptLineFill] = fill }
            case .mark(let line):
                let color = line == .removed ? palette.removedMark : line == .added ? palette.addedMark : palette.gutter
                attributes = [.font: rowMark, .foregroundColor: color, .transcriptRole: Self.role(of: line).rawValue]
                if let fill = fill(line) { attributes[.transcriptLineFill] = fill }
            case .code(let line, let token):
                var color = token.map(palette.color) ?? (line == .context ? palette.contextCode : line == .fenced ? palette.text : palette.changedCode)
                // Lines kept only for context sit back, as in Claude's own diff.
                if line == .context, token != nil { color = color.withAlphaComponent(0.72) }
                attributes = [.font: line == .fenced ? base : small, .foregroundColor: color, .transcriptRole: Self.role(of: line).rawValue]
                if let fill = fill(line) { attributes[.transcriptLineFill] = fill }
            }
            attributes[.paragraphStyle] = paragraph(key)
            if key.block >= 0 {
                attributes[.transcriptBubble] = TranscriptBubble(id: key.block, fill: palette.bubbleFill, stroke: palette.bubbleStroke, label: key.task ? taskLabel : nil,
                                                                 accent: palette.labelInk)
            }
            return attributes
        }

        /// A reply's text with Markdown on it. A hidden mark has no colour and gives its column back, so what is around it
        /// closes up; everything else keeps the reply's own look and adds to it.
        private func markupAttributes(_ style: MarkupStyle) -> [NSAttributedString.Key: Any] {
            if style.contains(.hidden) {
                return [.font: base, .foregroundColor: NSColor.clear, .kern: -column, .transcriptRole: TranscriptRole.assistant.rawValue]
            }
            let heavy = style.contains(.bold) || style.contains(.heading)
            let slanted = style.contains(.italic)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: heavy ? (slanted ? boldItalic : bold) : (slanted ? italic : base),
                .foregroundColor: palette.text, .transcriptRole: TranscriptRole.assistant.rawValue,
            ]
            if slanted, italicSkew { attributes[.obliqueness] = 0.2 }
            if style.contains(.heading) { attributes[.foregroundColor] = palette.heading }
            if style.contains(.bullet) { attributes[.foregroundColor] = palette.assistantMarker; attributes[.font] = bold; attributes[.transcriptBullet] = true }
            if style.contains(.link) {
                attributes[.foregroundColor] = palette.link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if style.contains(.code) {
                attributes[.foregroundColor] = palette.inlineCode
                attributes[.backgroundColor] = palette.inlineCodeFill
            }
            return attributes
        }

        private static func role(of line: CodeLine) -> TranscriptRole { line == .fenced ? .assistant : .toolOutput }

        /// The band behind a changed row; none for the others.
        private func fill(_ line: CodeLine) -> NSColor? {
            switch line {
            case .removed: palette.removedFill
            case .added: palette.addedFill
            case .context, .fenced: nil
            }
        }

        private func paragraph(_ key: Key) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            if key.hang > 0 { paragraph.headIndent = (CGFloat(key.hang) * rowColumn).rounded(.up) }
            if key.indent > 0 { paragraph.headIndent = (CGFloat(key.indent) * column).rounded(.up) }
            switch key.fit {
            case .none: break
            case .assistantDot: paragraph.lineSpacing = assistantDot?.spacing ?? 0
            case .toolDot: paragraph.lineSpacing = toolDot?.spacing ?? 0
            case .result: paragraph.lineSpacing = resultMark?.spacing ?? 0
            }
            if key.gap { paragraph.paragraphSpacingBefore = TranscriptStyler.gapAfterBubble }
            return paragraph
        }
    }
}

// MARK: - Layout manager

/// Paints the soft block behind each user message, under the text and the selection. The block spans the width of the
/// text container and the lines of the message; the characters themselves are drawn by `NSLayoutManager`.
final class MirrorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The dash of a list item (`.transcriptBullet`) is drawn as a bullet, the way Claude's terminal draws it. The glyph is
    /// swapped as glyphs are generated, so the text, its copy and its selection are untouched. Batches without a bullet (nearly
    /// all of them) are left to the default, after one look at the few attribute runs they cover.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let count = glyphRange.length
        let low = charIndexes[0], high = charIndexes[count - 1]
        guard low >= 0, high < storage.length, high >= low else { return 0 }
        var bullets: Set<Int> = []
        storage.enumerateAttribute(.transcriptBullet, in: NSRange(location: low, length: high - low + 1), options: []) { value, range, _ in
            if value != nil { for index in range.location..<NSMaxRange(range) { bullets.insert(index) } }
        }
        guard !bullets.isEmpty else { return 0 }
        var dot: unichar = 0x2022
        var dotGlyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(aFont, &dot, &dotGlyph, 1), dotGlyph != 0 else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        let properties = Array(UnsafeBufferPointer(start: props, count: count))
        let indexes = Array(UnsafeBufferPointer(start: charIndexes, count: count))
        for position in 0..<count where bullets.contains(indexes[position]) { newGlyphs[position] = dotGlyph }
        layoutManager.setGlyphs(newGlyphs, properties: properties, characterIndexes: indexes, font: aFont, forGlyphRange: glyphRange)
        return count
    }

    static let cornerRadius: CGFloat = 6
    /// How far the block reaches above the first line and below the last one.
    static let verticalPadding: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawLineFills(forGlyphRange: glyphsToShow, at: origin)
        drawBubbles(forGlyphRange: glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// The band behind a changed row: every line the row takes (a long one wraps) is filled across the whole width of
    /// the text container, so rows that follow each other make one band, as in Claude's terminal.
    private func drawLineFills(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
            let index = self.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length, let fill = storage.attribute(.transcriptLineFill, at: index, effectiveRange: nil) as? NSColor else { return }
            fill.setFill()
            rect.offsetBy(dx: origin.x, dy: origin.y).fill()
        }
    }

    private func drawBubbles(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        var location = shown.location
        while location < NSMaxRange(shown) {
            var run = NSRange(location: location, length: 0)
            let value = storage.attribute(.transcriptBubble, at: location, longestEffectiveRange: &run, in: shown)
            defer { location = max(location + 1, NSMaxRange(run)) }
            guard let bubble = value as? TranscriptBubble else { continue }
            // The dirty part may cut a message in two; the block is always painted whole.
            var full = run
            storage.attribute(.transcriptBubble, at: run.location, longestEffectiveRange: &full, in: whole)
            let glyphs = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            // The lines' own height, without the room above a paragraph, so neighbouring blocks never touch.
            let first = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let width = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            // The text view clips its background to the text container, so the block spans the container's width.
            var rect = NSRect(x: width.minX, y: first.minY, width: width.width, height: last.maxY - first.minY).offsetBy(dx: origin.x, dy: origin.y)
            rect = rect.insetBy(dx: 0, dy: -Self.verticalPadding)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            bubble.fill.setFill()
            path.fill()
            bubble.stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            bubble.drawTag(in: rect, midY: first.midY + origin.y)
        }
    }
}

extension TranscriptBubble {
    /// The room a tagged block keeps free at the right end of its first paragraph, for the pill (see `MirrorMessageLook`).
    static let tagGutter: CGFloat = 76

    /// Draws the tag's pill at the right end of the block `rect`, centred on `midY` (the block's first line), in a flipped view. Nothing
    /// when there is no tag.
    func drawTag(in rect: NSRect, midY: CGFloat) {
        guard let tag else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7, weight: .bold), .kern: 0.8, .foregroundColor: tag.ink]
        let text = tag.text.uppercased() as NSString
        let size = text.size(withAttributes: attributes)
        let pill = NSRect(x: rect.maxX - ceil(size.width) - 10 - 8, y: midY - 6, width: ceil(size.width) + 10, height: 12)
        tag.fill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + (pill.height - size.height) / 2 - 0.3), withAttributes: attributes)
    }

    /// The tab a labelled block wears: a small word on a tab of the block's own colours, standing on the block's top edge.
    static let tabHeight: CGFloat = 9
    /// How much room the text view keeps over the first message, on top of its usual inset, for the tab to stand in.
    static let tabRoom: CGFloat = 7

    /// Draws the tab with its bottom edge at `y` and its left edge at `x`, in a flipped view. Nothing when there is no label.
    func drawTab(atX x: CGFloat, bottomY y: CGFloat) {
        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold), .kern: 0.8,
            .foregroundColor: accent.withAlphaComponent(0.95),
        ]
        let text = label.uppercased() as NSString
        let size = text.size(withAttributes: attributes)
        let tab = NSRect(x: x, y: y - Self.tabHeight, width: ceil(size.width) + 10, height: Self.tabHeight)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Rounded at the top only: the bottom corners are drawn below the tab and cut away.
        NSBezierPath(rect: tab).addClip()
        let path = NSBezierPath(roundedRect: NSRect(x: tab.minX + 0.25, y: tab.minY + 0.25, width: tab.width - 0.5, height: tab.height + 6), xRadius: 3, yRadius: 3)
        fill.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = 0.5; path.stroke()
        text.draw(at: NSPoint(x: tab.minX + 5, y: tab.minY + (tab.height - size.height) / 2 - 0.3), withAttributes: attributes)
    }
}

extension MirrorTextView {
    /// A mirror text view on its own TextKit 1 stack with `MirrorLayoutManager`. TextKit 2 (the default for a bare
    /// `NSTextView`) has no layout manager to subclass, and the mirror needs the same stack for its layout anyway.
    static func makeTranscriptCapable() -> MirrorTextView {
        let storage = NSTextStorage()
        let layout = MirrorLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        return MirrorTextView(frame: .zero, textContainer: container)
    }
}
