import Foundation

// Claude writes its replies in Markdown, and its own terminal draws them: bold, italic, `inline code`, headings, bullets
// and links. The mirror shows the same text, so the same marks have to read as what they mean instead of as asterisks.
//
// This finds them, one line at a time, and says how each character should look. It never changes a character: marks that
// are not shown (`**`, backticks, the `#` of a heading, the address of a link) stay in the text, hidden by the styler,
// and copying gives the raw Markdown back.
//
// Conservative on purpose. A false positive turns somebody's `2 * 3 * 4` or `file_name_here` into something it is not, so
// emphasis only opens at the start of a word and closes at the end of one, with something that is not a space inside the
// marks; `*` and `_` that are not that stay as they are. Everything is per line (a reply's lines are paragraphs), so
// restyling from any line on gives what styling everything gives.

/// How a character of a reply looks beyond plain text. Several can apply at once (a bold word inside a heading).
struct MarkupStyle: OptionSet, Hashable {
    let rawValue: UInt8
    static let bold = MarkupStyle(rawValue: 1)
    static let italic = MarkupStyle(rawValue: 2)
    /// Inside `backticks`.
    static let code = MarkupStyle(rawValue: 4)
    /// The text of a `#` heading.
    static let heading = MarkupStyle(rawValue: 8)
    /// A mark that is not shown: it takes no room and no colour.
    static let hidden = MarkupStyle(rawValue: 16)
    /// The text of a link.
    static let link = MarkupStyle(rawValue: 32)
    /// The dash of a bullet.
    static let bullet = MarkupStyle(rawValue: 64)
}

enum InlineMarkdown {
    struct Run: Equatable {
        var range: NSRange
        var style: MarkupStyle
    }

    /// A link's visible text and where it goes.
    struct Link: Equatable {
        var range: NSRange
        var url: String
        /// Only web and mail addresses open when clicked; a file path in a link just says where it points.
        var opens: Bool { ["http://", "https://", "mailto:"].contains { url.lowercased().hasPrefix($0) } }
    }

    struct Result: Equatable {
        /// The stretches that look different, in order and without overlaps; the text between them is plain.
        var runs: [Run]
        var links: [Link]
        /// The column, counted from the start of the line, where the text of a list item begins: its wrapped lines hang there.
        var hang: Int?
    }

    /// The most columns a wrapped list item hangs by.
    static let maxHang = 12

    /// Longest part of a line that is read; a paragraph of 20,000 characters keeps its raw look past this.
    static let maxLineLength = 5000

    /// What the line `range` of `text` (without its line break) holds, or nil when it is plain.
    static func parse(_ text: NSString, range: NSRange) -> Result? {
        let length = min(range.length, maxLineLength)
        guard length > 0, range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        var chars = [unichar](repeating: 0, count: length)
        text.getCharacters(&chars, range: NSRange(location: range.location, length: length))
        // Most lines have none of the characters that start anything: no work for them.
        let lead = chars.firstIndex { $0 != 0x20 && $0 != 0x09 } ?? 0
        let first = chars[lead]
        guard first == 0x23 || first == 0x2D || first == 0x2B || (first >= 0x30 && first <= 0x39)
                || chars.contains(where: { $0 == 0x60 || $0 == 0x2A || $0 == 0x5F || $0 == 0x5B }) else { return nil }
        var parser = Parser(chars)
        let touched = parser.run()
        guard touched || parser.hang != nil else { return nil }
        return parser.result(base: range.location)
    }

    /// The same for a plain string (tests, previews).
    static func parse(_ line: String) -> Result? {
        parse(line as NSString, range: NSRange(location: 0, length: (line as NSString).length))
    }
}

private struct Parser {
    let c: [unichar]
    let n: Int
    var style: [UInt8]
    /// The line as emphasis sees it: code spans are one solid word, and so is the address of a link.
    var mask: [unichar]
    var links: [(start: Int, end: Int, url: String)] = []
    var touched = false
    var hang: Int?

    init(_ chars: [unichar]) {
        c = chars; n = chars.count
        style = [UInt8](repeating: 0, count: chars.count)
        mask = chars
    }

    // MARK: Characters

    private static let star: unichar = 0x2A, underscore: unichar = 0x5F, backtick: unichar = 0x60

    private func isSpace(_ ch: unichar) -> Bool { ch == 0x20 || ch == 0x09 || ch == 0xA0 || ch == 0x0D }
    private func isWord(_ ch: unichar) -> Bool {
        (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch > 0x7F
    }
    private mutating func set(_ range: Range<Int>, _ flag: MarkupStyle) {
        guard !range.isEmpty else { return }
        for index in range { style[index] |= flag.rawValue }
        touched = true
    }

    // MARK: Run

    mutating func run() -> Bool {
        var lead = 0
        while lead < n, isSpace(c[lead]) { lead += 1 }
        guard lead < n else { return false }
        var start = lead
        // A heading: one to six "#" and a space. The marks and the space are hidden, the rest is the heading.
        if c[lead] == 0x23 {
            var j = lead
            while j < n, c[j] == 0x23 { j += 1 }
            if j - lead <= 6, j + 1 < n, c[j] == 0x20, c[(j + 1)...].contains(where: { !isSpace($0) }) {
                set(lead..<(j + 1), .hidden)
                set((j + 1)..<n, .heading)
                start = j + 1
            }
        } else if (c[lead] == 0x2D || c[lead] == 0x2A || c[lead] == 0x2B), lead + 2 < n, c[lead + 1] == 0x20, !isRule(from: lead) {
            // A bullet: "- ", "* " or "+ " and something after it.
            set(lead..<(lead + 1), .bullet)
            start = lead + 2
            hang = min(lead + 2, InlineMarkdown.maxHang)
        } else if c[lead] >= 0x30, c[lead] <= 0x39 {
            // A numbered item ("1. ", "12) ") is left as it is; only its wrapped lines hang under its text.
            var j = lead
            while j < n, j - lead < 3, c[j] >= 0x30, c[j] <= 0x39 { j += 1 }
            if j + 1 < n, c[j] == 0x2E || c[j] == 0x29, c[j + 1] == 0x20, j + 2 < n { hang = min(j + 2, InlineMarkdown.maxHang) }
        }
        codeSpans(from: start)
        links(from: start)
        emphasis(from: start)
        return touched
    }

    /// "---", "* * *": a rule, not a bullet.
    private func isRule(from index: Int) -> Bool {
        let mark = c[index]
        return c[index...].allSatisfy { $0 == mark || isSpace($0) } && c[index...].filter { $0 == mark }.count >= 3
    }

    // MARK: Code

    /// `code` and ``code with a ` in it``: a run of backticks closes at the next run of the same length on the line. An
    /// unclosed one is just backticks.
    private mutating func codeSpans(from start: Int) {
        var i = start
        while i < n {
            guard c[i] == Self.backtick else { i += 1; continue }
            var j = i
            while j < n, c[j] == Self.backtick { j += 1 }
            let length = j - i
            var k = j
            var close: Int?
            while k < n {
                guard c[k] == Self.backtick else { k += 1; continue }
                var m = k
                while m < n, c[m] == Self.backtick { m += 1 }
                if m - k == length { close = k; break }
                k = m
            }
            guard let close, close > j else { i = j; continue }
            set(i..<j, .hidden)
            set(j..<close, .code)
            set(close..<(close + length), .hidden)
            // Emphasis sees the whole span as one word.
            for index in i..<(close + length) { mask[index] = 0x61 }
            i = close + length
        }
    }

    // MARK: Links

    /// `[text](address)`: the text is the link, the rest is hidden. The address has no spaces.
    private mutating func links(from start: Int) {
        var i = start
        while i < n {
            guard c[i] == 0x5B, mask[i] != 0x61, i == 0 || (c[i - 1] != 0x21 && c[i - 1] != 0x5C) else { i += 1; continue }
            var close = i + 1
            while close < n, c[close] != 0x5D, c[close] != 0x5B { close += 1 }
            guard close > i + 1, close + 1 < n, c[close] == 0x5D, c[close + 1] == 0x28 else { i += 1; continue }
            var end = close + 2
            while end < n, c[end] != 0x29, !isSpace(c[end]) { end += 1 }
            guard end < n, c[end] == 0x29, end > close + 2 else { i += 1; continue }
            let url = String(decoding: c[(close + 2)..<end], as: UTF16.self)
            set(i..<(i + 1), .hidden)
            set((i + 1)..<close, .link)
            set(close..<(end + 1), .hidden)
            links.append((i + 1, close, url))
            // Emphasis never reads the address (an underscore in it is no mark); the brackets stay as punctuation.
            for index in (close + 2)..<end { mask[index] = 0x61 }
            i = end + 1
        }
    }

    // MARK: Emphasis

    /// What may stand before an opening mark: the start, a space, or an opening or separating punctuation mark. Never a
    /// letter or a digit (`snake_case`), never a "/" or a "." (paths, globs).
    private func opensAfter(_ prev: unichar?) -> Bool {
        guard let prev else { return true }
        return isSpace(prev) || "([{<\"'“‘«¿¡—–:;,|*_".utf16.contains(prev)
    }
    /// What may follow an opening mark: the first character of a word, or an opening mark of its own.
    private func opensBefore(_ next: unichar?) -> Bool {
        guard let next else { return false }
        return isWord(next) || "([\"'“‘«¿¡*_".utf16.contains(next)
    }
    /// What may stand before a closing mark: the end of a word, or a closing punctuation mark.
    private func closesAfter(_ prev: unichar?) -> Bool {
        guard let prev else { return false }
        return isWord(prev) || ".,;:!?)]}\"'”’»…%*_".utf16.contains(prev)
    }
    /// What may follow a closing mark: the end, a space, or punctuation. Never a letter or a digit.
    private func closesBefore(_ next: unichar?) -> Bool {
        guard let next else { return true }
        return isSpace(next) || ".,;:!?)]}\"'”’»…—–|*_-".utf16.contains(next)
    }

    /// `*italic*`, `_italic_`, `**bold**`, `__bold__`, `***both***`. A mark pairs with the nearest earlier one of the same
    /// kind and length; marks that pair with nothing stay as they are.
    private mutating func emphasis(from start: Int) {
        struct Opener { var index: Int; var mark: unichar; var length: Int }
        var stack: [Opener] = []
        var i = start
        while i < n {
            let mark = mask[i]
            guard mark == Self.star || mark == Self.underscore else { i += 1; continue }
            var j = i
            while j < n, mask[j] == mark { j += 1 }
            let length = j - i
            defer { i = j }
            // Escaped ("\*") or too long to be emphasis ("****"): left alone.
            guard length <= 3, i == 0 || mask[i - 1] != 0x5C else { continue }
            let prev: unichar? = i > start ? mask[i - 1] : nil
            let next: unichar? = j < n ? mask[j] : nil
            let canOpen = opensAfter(prev) && opensBefore(next)
            let canClose = closesAfter(prev) && closesBefore(next)
            if canClose, let found = stack.lastIndex(where: { $0.mark == mark && $0.length == length }) {
                let opener = stack[found]
                var flags: MarkupStyle = []
                if length != 2 { flags.insert(.italic) }
                if length >= 2 { flags.insert(.bold) }
                set(opener.index..<(opener.index + length), .hidden)
                set((opener.index + length)..<i, flags)
                set(i..<j, .hidden)
                // What was opened inside this pair and never closed dies with it.
                stack.removeSubrange(found...)
            } else if canOpen {
                stack.append(Opener(index: i, mark: mark, length: length))
            }
        }
    }

    // MARK: Result

    func result(base: Int) -> InlineMarkdown.Result {
        var runs: [InlineMarkdown.Run] = []
        var i = 0
        while i < n {
            guard style[i] != 0 else { i += 1; continue }
            // A hidden mark is only hidden, whatever the text around it is.
            func normalized(_ flags: UInt8) -> UInt8 { flags & MarkupStyle.hidden.rawValue != 0 ? MarkupStyle.hidden.rawValue : flags }
            let flags = normalized(style[i])
            var j = i + 1
            while j < n, normalized(style[j]) == flags { j += 1 }
            runs.append(InlineMarkdown.Run(range: NSRange(location: base + i, length: j - i), style: MarkupStyle(rawValue: flags)))
            i = j
        }
        return InlineMarkdown.Result(runs: runs, links: links.map { InlineMarkdown.Link(range: NSRange(location: base + $0.start, length: $0.end - $0.start), url: $0.url) }, hang: hang)
    }
}
