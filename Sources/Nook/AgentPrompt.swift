import Foundation

/// A question an agent (Claude Code, Codex) shows in its terminal and waits on: a permission request, a multiple-choice
/// question, a plan approval or a selector. Nook reads it from the mirror's text and offers it as a card with one button
/// per option; the original terminal stays the source of truth, so nothing here answers by itself.
///
/// The parser is deliberately conservative: it returns nil unless the screen has the exact shape of a dialog at its
/// end. A wrong card would sit over the composer, a missing one only leaves the key strip as before. What it accepts:
///
/// - **Numbered options** (`❯ 1. Yes` / `  2. No`): the numbers run 1…N without gaps, exactly one option carries the
///   highlight (`❯` or `›`), and nothing but blank lines, rules, key hints and the options' own descriptions follows
///   the last one. A numbered list inside a reply has no highlight; a prompt that scrolled away has output after it.
/// - **Unnumbered selectors** (`❯ Opus` / `  Sonnet` / `  Haiku`): a highlighted line with peers of the same indent
///   above or below, followed by a key hint ("Enter to confirm · Esc to exit"). Without the hint a highlighted line is
///   just a shell prompt or the input box.
///
/// The wording of Claude Code's and Codex's dialogs was not read from their renderers (only from what users see), so
/// the patterns are collected at the top of `Patterns` and every test states the shape it covers.
struct AgentPrompt: Equatable {
    enum Kind: Equatable {
        /// "Do you want to proceed?" with Yes / No: a permission request or a plan approval.
        case approval
        /// A numbered question with its own options.
        case question
        /// A list of choices without numbers (model picker, resume list).
        case selector
    }

    /// What choosing an option leads to.
    enum Input: Equatable {
        case none
        /// The option is itself a text field ("Type something."): once highlighted, typed text goes into it and Enter
        /// sends it, so Nook only moves the highlight there and lets the user type.
        case inline
        /// The option leaves the dialog and asks the user to tell the agent something next ("No, and tell Claude what
        /// to do differently"): Nook presses it, then the user types a message as usual.
        case followUp
    }

    struct Option: Equatable, Identifiable {
        /// Position in the list, from 0.
        var index: Int
        /// The number the terminal prints, nil in a selector.
        var number: Int?
        var title: String
        /// The description under the option, when there is one.
        var detail: String?
        /// The key the option names for itself, "esc" in "No, and tell Claude what to do differently (esc)".
        var shortcut: String?
        var input: Input
        var id: Int { index }
    }

    var kind: Kind
    /// The line above the options ("Do you want to proceed?"); empty when the screen has none.
    var question: String
    /// The tool call the question is about ("Bash(rm -rf build)"), when it is on screen just above.
    var context: String?
    var options: [Option]
    /// The option the terminal has highlighted, as an index into `options`.
    var highlighted: Int
    /// How many lines, counted from the end of the text, belong to the prompt (heading, options and hints).
    var tailLines: Int
    /// What identifies the prompt apart from where the highlight is: the same dialog keeps its signature while the user
    /// moves through it, a new one gets another.
    var signature: String

    /// The keys that choose `index`: the arrows from the highlighted option, then Enter. A text field is only reached,
    /// never confirmed; an option that is already highlighted needs just Enter (which works without Accessibility).
    func keys(choosing index: Int) -> [TerminalKey] {
        guard options.indices.contains(index) else { return [] }
        let delta = index - highlighted
        var keys = [TerminalKey](repeating: delta > 0 ? .down : .up, count: abs(delta))
        if options[index].input != .inline { keys.append(.enter) }
        return keys
    }

    /// How many arrow presses reach `index`; they are what needs Accessibility in a Terminal tab.
    func moves(to index: Int) -> Int { abs(index - highlighted) }

    // MARK: - Reading the screen

    /// The prompt at the end of `text`, or nil when it does not end in one.
    static func parse(_ text: String) -> AgentPrompt? {
        let rows = text.suffix(Limits.characters).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(Limits.rows).map { Row(String($0)) }
        guard rows.count >= 2 else { return nil }
        return numbered(rows) ?? selector(rows)
    }

    /// `text` without the prompt's own lines, which the card shows instead. The context above them stays, so the user
    /// still reads what is being asked about. Unchanged when there is no prompt.
    static func withoutPrompt(_ text: String) -> String {
        guard let prompt = parse(text) else { return text }
        var cut = text.endIndex
        var newlines = 0
        while cut > text.startIndex, newlines < prompt.tailLines {
            cut = text.index(before: cut)
            if text[cut].isNewline { newlines += 1 }
        }
        // Fewer line breaks than the prompt has lines: it starts at the very beginning.
        var kept = newlines == prompt.tailLines ? text[..<cut] : text[..<text.startIndex]
        while let last = kept.last, last.isWhitespace { kept = kept.dropLast() }
        return String(kept)
    }

    // MARK: - Limits and patterns

    private enum Limits {
        /// Only the end of the screen can hold a live prompt.
        static let characters = 6000
        static let rows = 40
        static let options = 12
        /// Description lines kept under one option.
        static let detailRows = 3
        /// A selector's rows are short; a long line is prose.
        static let selectorWidth = 120
    }

    private enum Patterns {
        /// Box-drawing characters that make up rules and frames.
        static let frame: Set<Character> = ["─", "━", "═", "╌", "┄", "╍", "┈", "┉", "┅", "│", "┃", "║", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╔", "╗", "╚", "╝"]
        static let verticals: Set<Character> = ["│", "┃", "║"]
        /// The highlight Claude (❯) and Codex (›) put in front of the current option.
        static let markers: Set<Character> = ["❯", "›"]
        /// What opens a reply, a tool result or a quoted message.
        static let proseMarks: Set<Character> = ["⏺", "●", "•", "⎿", ">"]
        static let plainRule = Pattern(#"^[-=_]{5,}$"#)
        static let numbered = Pattern(#"^(\d{1,2})[.)]\s+(\S.*)$"#)
        static let tool = Pattern(#"^[⏺●]\x{FE0F}?\s+([A-Za-z][\w:.-]*\(.*)$"#)
        /// "(esc)", "(shift+tab)", "(y)": the key an option names for itself.
        static let shortcut = Pattern(#"\s*\((esc|tab|shift\+tab|ctrl\+[a-z]|[a-z])\)\s*$"#, caseInsensitive: true)

        /// What the dialogs print under their options. "esc to interrupt" (the spinner's hint) is not one of them.
        static let hints = ["esc to ", "esc ·", "enter to ", "press enter", "to select", "to navigate", "to confirm", "to cancel", "to exit",
                            "tab to ", "ctrl+e", "↑/↓", "↑↓", "space to"]
        /// Claude's mode line and Codex's footer, which may follow a dialog.
        static let modeLines = ["⏵⏵", "shift+tab to cycle", "for shortcuts", "bypass permissions", "accept edits on", "plan mode on", "auto mode on", "context left"]

        /// Options that are a text field themselves: highlighting one is enough, the user types into it.
        static let inline = Pattern(#"^(type something|type your|type here|something else|write your|enter your|enter something|escribe|(other|otro|otra)\b.{0,20}$)"#, caseInsensitive: true)
        /// Options that end the dialog and invite the user to tell the agent what to do next.
        static let followUp = Pattern(#"(tell (claude|codex|it|the agent)\b|what to do differently|what to change|chat about this|give (claude|codex) (feedback|instructions)|provide feedback)"#, caseInsensitive: true)
    }

    private struct Pattern {
        let expression: NSRegularExpression

        init(_ pattern: String, caseInsensitive: Bool = false) {
            // The patterns are constants in this file; a typo shows up in the first test run.
            expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        }

        func groups(in text: String) -> [String?]? {
            let source = text as NSString
            guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
            return (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
        }

        func matches(_ text: String) -> Bool { groups(in: text) != nil }
    }

    // MARK: - Rows

    /// One screen line, read once.
    private struct Row {
        /// Without the box border some dialogs draw around themselves, and without surrounding blanks.
        let text: String
        /// Blanks before `text` (inside the border, if any).
        let indent: Int
        let isFrame: Bool
        let isHint: Bool
        let isModeLine: Bool
        /// Starts with the highlight.
        let marked: Bool
        /// `text` without the highlight.
        let body: String
        /// The column where `body` starts: the same for every option of a list, marked or not.
        let bodyColumn: Int
        let number: Int?
        let optionText: String

        init(_ raw: String) {
            var line = Substring(raw)
            var lead = line.prefix(while: \.isWhitespace).count
            line = line.dropFirst(lead)
            // Codex's older dialogs draw themselves inside a box: "│ ❯ 1. Yes │".
            if line.count >= 2, let first = line.first, let last = line.last, Patterns.verticals.contains(first), Patterns.verticals.contains(last) {
                line = line.dropFirst().dropLast()
                lead = line.prefix(while: \.isWhitespace).count
                line = line.dropFirst(lead)
            }
            text = line.trimmingCharacters(in: .whitespaces)
            indent = lead
            let lower = text.lowercased()
            let drawing = text.filter { Patterns.frame.contains($0) }.count
            isFrame = (drawing >= 1 && drawing + text.filter(\.isWhitespace).count == text.count) || Patterns.plainRule.matches(text)
            // A reply line ("⏺ Press Enter to select it") or a quoted message is prose, not the dialog's own hint.
            let prose = text.first.map { Patterns.proseMarks.contains($0) } ?? false
            isHint = !prose && !lower.contains("to interrupt") && Patterns.hints.contains { lower.contains($0) }
            isModeLine = Patterns.modeLines.contains { lower.contains($0) }
            if let first = text.first, Patterns.markers.contains(first), text.dropFirst().first.map(\.isWhitespace) ?? true {
                let rest = text.dropFirst()
                let spaces = rest.prefix(while: \.isWhitespace).count
                marked = true
                body = String(rest.dropFirst(spaces))
                bodyColumn = lead + 1 + spaces
            } else {
                marked = false
                body = text
                bodyColumn = lead
            }
            if let groups = Patterns.numbered.groups(in: body), let value = groups[1].flatMap(Int.init), let option = groups[2] {
                number = value
                optionText = option
            } else {
                number = nil
                optionText = ""
            }
        }

        var isBlank: Bool { text.isEmpty }
        /// Lines that may follow a dialog without meaning that it scrolled away.
        var isQuiet: Bool { isBlank || isFrame || isHint || isModeLine }
        /// "⏺ Bash(rm -rf build)": the call a permission question is about.
        var isToolCall: Bool { indent <= 1 && Patterns.tool.matches(text) }
    }

    // MARK: - Numbered options

    private static func numbered(_ rows: [Row]) -> AgentPrompt? {
        guard let last = rows.lastIndex(where: { $0.number != nil }), quietTail(rows, after: last) else { return nil }
        var picked = [last]
        while let first = picked.first, let number = rows[first].number, number > 1 {
            guard let previous = optionAbove(rows, first), rows[previous].number == number - 1 else { return nil }
            picked.insert(previous, at: 0)
        }
        guard (2...Limits.options).contains(picked.count), picked.filter({ rows[$0].marked }).count == 1,
              let low = picked.map({ rows[$0].bodyColumn }).min(), let high = picked.map({ rows[$0].bodyColumn }).max(), high - low <= 1 else { return nil }
        let ends = picked.dropFirst() + [descriptionEnd(rows, after: last)]
        let options = zip(picked, ends).enumerated().map { position, pair in
            makeOption(index: position, number: rows[pair.0].number, text: rows[pair.0].optionText, detail: describing(rows, from: pair.0 + 1, to: pair.1))
        }
        return build(rows, firstOption: picked[0], options: options, highlighted: picked.firstIndex { rows[$0].marked } ?? 0, selector: false)
    }

    /// Only blank lines, rules, hints and the last option's own description may follow it.
    private static func quietTail(_ rows: [Row], after last: Int) -> Bool {
        var described = 0
        var closed = false
        var quiet = 0
        for row in rows[(last + 1)...] {
            if row.isBlank { closed = true; continue }
            if row.isQuiet { closed = true; quiet += 1; continue }
            guard !closed, row.indent > rows[last].bodyColumn, described < Limits.detailRows else { return false }
            described += 1
        }
        return quiet <= 6
    }

    /// The option above `index`: between the two there are only blank lines, rules and the upper option's description.
    private static func optionAbove(_ rows: [Row], _ index: Int) -> Int? {
        var k = index - 1
        while k >= 0, index - k <= Limits.detailRows + 3 {
            if rows[k].number != nil {
                let between = rows[(k + 1)..<index]
                return between.allSatisfy { $0.isBlank || $0.isFrame || ($0.indent > rows[k].bodyColumn && !$0.marked) } ? k : nil
            }
            k -= 1
        }
        return nil
    }

    /// Where the description rows after `index` end.
    private static func descriptionEnd(_ rows: [Row], after index: Int) -> Int {
        var end = index + 1
        while end < rows.count, !rows[end].isQuiet { end += 1 }
        return end
    }

    private static func describing(_ rows: [Row], from start: Int, to end: Int) -> [String] {
        guard start < end else { return [] }
        return rows[start..<end].filter { !$0.isBlank && !$0.isFrame }.prefix(Limits.detailRows).map(\.text)
    }

    // MARK: - Selectors without numbers

    private static func selector(_ rows: [Row]) -> AgentPrompt? {
        // The hint is what tells a selector from a shell prompt: the last one on screen, with the highlight above it.
        guard let hint = rows.lastIndex(where: { $0.isHint }),
              let marked = rows[..<hint].lastIndex(where: { $0.marked && $0.number == nil && !$0.body.isEmpty }) else { return nil }
        func peer(_ row: Row) -> Bool {
            !row.isQuiet && !row.marked && row.number == nil && row.indent == rows[marked].bodyColumn && row.text.count <= Limits.selectorWidth
        }
        var top = marked, bottom = marked
        while top > 0, peer(rows[top - 1]) { top -= 1 }
        while bottom + 1 < rows.count, peer(rows[bottom + 1]) { bottom += 1 }
        guard bottom < hint, (2...Limits.options).contains(bottom - top + 1), rows[marked].body.count <= Limits.selectorWidth,
              rows[(bottom + 1)...].allSatisfy(\.isQuiet), rows[(bottom + 1)...].filter({ !$0.isBlank }).count <= 6 else { return nil }
        let options = (top...bottom).enumerated().map { position, row in
            makeOption(index: position, number: nil, text: rows[row].body, detail: [])
        }
        return build(rows, firstOption: top, options: options, highlighted: marked - top, selector: true)
    }

    // MARK: - Assembly

    private static func makeOption(index: Int, number: Int?, text: String, detail: [String]) -> Option {
        var title = text
        var detail = detail
        // "Opus (recommended)  Most capable": selectors align a description in a column after two or more spaces.
        if let gap = title.range(of: #"\s{2,}"#, options: .regularExpression) {
            let described = String(title[gap.upperBound...]).trimmingCharacters(in: .whitespaces)
            let left = String(title[..<gap.lowerBound])
            if !left.isEmpty, !described.isEmpty { title = left; detail.insert(described, at: 0) }
        }
        var shortcut: String?
        if let groups = Patterns.shortcut.groups(in: title), let whole = groups[0], let key = groups[1] {
            shortcut = key.lowercased()
            title = String(title.dropLast(whole.count))
        }
        let input: Input = Patterns.inline.matches(title) ? .inline : (Patterns.followUp.matches(title) ? .followUp : .none)
        return Option(index: index, number: number, title: title, detail: detail.isEmpty ? nil : detail.joined(separator: " "), shortcut: shortcut, input: input)
    }

    private static func build(_ rows: [Row], firstOption: Int, options: [Option], highlighted: Int, selector: Bool) -> AgentPrompt {
        let heading = heading(rows, above: firstOption)
        let start = min(heading?.row ?? firstOption, firstOption)
        let context = (max(0, start - 12)..<start).reversed().first { rows[$0].isToolCall }.map { String(rows[$0].text.drop(while: { !$0.isLetter }).prefix(160)) }
        let titles = options.map { $0.title.lowercased() }
        let affirmative = titles.contains { $0.hasPrefix("yes") || $0.hasPrefix("allow") || $0.hasPrefix("approve") || $0.hasPrefix("sí") }
        let negative = titles.contains { $0 == "no" || $0.hasPrefix("no,") || $0.hasPrefix("no ") || $0.hasPrefix("deny") || $0.hasPrefix("reject") }
        let kind: Kind = selector ? .selector : (affirmative && negative ? .approval : .question)
        let question = heading?.text ?? ""
        let signature = ([String(describing: kind), context ?? "", question] + options.map(\.title)).joined(separator: "\u{1F}")
        return AgentPrompt(kind: kind, question: question, context: context, options: options, highlighted: highlighted,
                           tailLines: rows.count - start, signature: signature)
    }

    /// The question or title right above the options: the nearest line, or the first line of a short title followed by
    /// its description ("Select model" over "Switch between Claude models.").
    private static func heading(_ rows: [Row], above index: Int) -> (text: String, row: Int)? {
        var k = index - 1
        var skipped = 0
        while k >= 0, rows[k].isBlank || rows[k].isFrame, skipped < 2 { k -= 1; skipped += 1 }
        guard k >= 0, !rows[k].isBlank, !rows[k].isFrame, !rows[k].isToolCall, rows[k].number == nil, !rows[k].marked else { return nil }
        var group = [k]
        while let top = group.first, top > 0, group.count < 4, !rows[top - 1].isQuiet, !rows[top - 1].isToolCall, rows[top - 1].number == nil, !rows[top - 1].marked {
            group.insert(top - 1, at: 0)
        }
        func ends(_ text: String, in marks: [Character]) -> Bool { text.last.map(marks.contains) ?? false }
        if group.count >= 2, let title = group.first, rows[title].text.count <= 40, !ends(rows[title].text, in: [".", "?", "!", ":", ","]), ends(rows[k].text, in: ["."]) {
            return (rows[title].text, title)
        }
        // A long question wraps: the lines above it at the same indent and without a full stop belong to it.
        var parts = [rows[k].text]
        var first = k
        while ends(rows[first].text, in: ["?", ":"]), parts.count < 3, let above = group.last(where: { $0 < first }), above == first - 1,
              rows[above].indent == rows[first].indent, !ends(rows[above].text, in: [".", "?", "!", ":", ")"]) {
            parts.insert(rows[above].text, at: 0)
            first = above
        }
        return (parts.joined(separator: " "), first)
    }
}
