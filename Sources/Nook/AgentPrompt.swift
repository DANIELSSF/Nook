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
/// - **Options beside a preview** (Claude's question whose options carry a preview): the numbered options in a column of
///   their own, sharing their lines with a box that shows the highlighted option's preview, a notes row under the box and
///   "Chat about this" under a rule (`previewed`). Read from Claude Code 2.1.295's renderer.
///
/// The wording of Claude Code's and Codex's dialogs was mostly not read from their renderers (only from what users see), so
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
        /// sends it. Nook writes the user's answer there with its own keys, arrows, the text and Enter in one go
        /// (`AppModel.answer(_:option:text:on:)`); choosing it on its own sends nothing.
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
        /// A question that takes several answers draws a box in front of each option: true when it is ticked, false when
        /// empty, nil for an option without one.
        var checked: Bool? = nil
        /// The terminal marks the option as what is set now: the "✔" after the current model in Claude's model picker.
        var current = false
        var id: Int { index }
    }

    /// One question on the review step: its text whole (Claude's side bar and wrapping gone) and the answer it has.
    struct ReviewItem: Equatable {
        var question: String
        /// What follows "→" ("Opcional + lo busca el servidor (Recomendado)"; several answers as Claude joins them); nil
        /// when the question has none yet.
        var answer: String?
        /// The tab the question belongs to ("Id número"), when the tabs and the questions line up.
        var tab: String?
    }

    /// A key and what the dialog says it does.
    struct KeyAction: Equatable {
        /// Lowercased as printed: "enter", "esc", "tab", "s".
        var key: String
        var label: String
    }

    /// One tab of a dialog that asks several questions at once ("←  ☐ Database  ☒ Cache  ✔ Submit  →").
    struct Tab: Equatable {
        var title: String
        /// Its box is ticked: the question already has an answer.
        var answered: Bool
        /// The last tab, which reviews and sends the answers ("Submit").
        var isSubmit: Bool
    }

    var kind: Kind
    /// The text above the options, whole: every line of a question that wraps, joined ("Do you want to proceed?"). With a
    /// short title over a description ("Select model" over "Switch between Claude models.") it is the title, and the
    /// description goes to `note`. Empty when the screen has none.
    var question: String
    /// The description under a short title, when there is one.
    var note: String? = nil
    /// The short label Claude shows above a single question ("☐ Database" reads "Database"); nil otherwise.
    var header: String? = nil
    /// The tabs of a dialog with several questions, in order; empty with one question. Plain text does not show which
    /// tab is open (Claude marks it with colour), only which ones are answered.
    var tabs: [Tab] = []
    /// The tool call the question is about ("Bash(rm -rf build)"), when it is on screen just above.
    var context: String?
    var options: [Option]
    /// The option the terminal has highlighted, as an index into `options`.
    var highlighted: Int
    /// The options are boxes to tick: Enter ticks or clears the highlighted one and the dialog stays open.
    var multiSelect = false
    /// A setting changed in place with ← and → under the options ("Medium effort (default)" in the model picker), when the
    /// dialog has one.
    var adjustment: String? = nil
    /// How many options the list keeps out of sight above and below what the screen shows ("… +3 models"; an "↑"/"↓" in
    /// front of the first or last option without a count says only that there are more: 1).
    var moreAbove = 0
    var moreBelow = 0
    /// The keys the dialog's hint names, in its order: "Enter to set as default · s to use this session only · Esc to cancel"
    /// is enter → "set as default", s → "use this session only", esc → "cancel".
    var actions: [KeyAction] = []
    /// A letter the dialog takes besides Enter and Esc ("s" → "use this session only" in the model picker), when it has one.
    var secondaryAction: KeyAction? { actions.first { $0.key.count == 1 && $0.key.first?.isLetter == true } }
    /// What Enter does, in the dialog's words ("set as default"), when its hint says.
    var confirmLabel: String? { actions.first { $0.key == "enter" }?.label }

    /// The last step of a dialog with several questions: each question with the answer given, before sending them all.
    /// `question` is then what Claude asks about them ("Ready to submit your answers?").
    var review: [ReviewItem] = []
    /// The review step's title ("Review your answers"), nil on any other step.
    var reviewTitle: String? = nil
    /// What Claude warns about on the review step ("⚠ You have not answered all questions"), when it does.
    var warning: String? = nil

    /// The highlighted option's preview, in a question whose options carry one: the lines of the box beside the options with its
    /// frame gone, as Claude laid them out (its markdown already rendered, code without its fences), their own indentation kept.
    /// Claude wraps a line wider than the box, so a long one comes in pieces. It follows the highlight: another option, another
    /// preview, the same `signature`. Nil without a box, and for an option that has none (Claude's "No preview available").
    var preview: String? = nil
    /// The preview's lines Claude keeps out of the box, folded under "✂ N lines hidden" (the box is at most the terminal's height
    /// less 26 rows tall, so a short terminal shows a few); 0 when the box shows them all. The terminal has no key to see them.
    var previewHiddenLines = 0
    /// The option `preview` belongs to: the highlighted one, or the last numbered one while "Chat about this" has the highlight
    /// (Claude reaches it with ↓ from the last option and keeps that option's preview in the box). Nil without a preview layout.
    var previewOption: Int? {
        guard takesNotes, options.indices.contains(highlighted) else { return nil }
        return options[highlighted].number != nil ? highlighted : options.lastIndex { $0.number != nil }
    }
    /// The question takes notes on the chosen option (the row "Notes: press n to add notes" under the preview): Claude sends them
    /// with the answer, after the option and its preview ("notes: …"). Only the layout with a preview has them.
    var takesNotes = false
    /// The notes the question holds, as its notes row shows them; nil while it has none. The field may be closed (they are held, and
    /// go with whichever option is answered) or open with them in it: `notesFocused` tells which.
    var notes: String? = nil
    /// The notes field is open in the terminal and empty (its placeholder "Add notes on this design…" shows). Open with text in it,
    /// `notes` has the text and this is false: see `notesFocused`.
    var notesOpen = false
    /// The notes field has the terminal's keyboard, empty or with text in it. Keys meant for the options land in it: an arrow moves
    /// its cursor, Enter closes it and answers the option Claude has highlighted (once the highlight moved in that question), or the
    /// answer the question already had, or "(notes only)": never the option Nook meant. Esc closes it and keeps its text as held
    /// notes. Plain text doesn't show the cursor, so two things tell it: the placeholder (`notesOpen`), and the key hint, which names
    /// the external editor only while the field is open ("… · ctrl+g to edit in Vim · Esc to cancel"; Claude Code 2.1.295:
    /// `At&&mo&&chord("ctrl+g","edit in ${mo}")`, `mo` the editor from the settings, $VISUAL, $EDITOR or the first of code, vi and
    /// nano on the PATH, so a Mac always has one). The hint wraps at the terminal's width like any text; its rows are read as one.
    var notesFocused = false
    /// Lines of the screen exactly as this reading had them (trailing blanks aside) that show only while the question is as read:
    /// the rows with the highlight (the box's row beside them included), "Chat about this", the notes row and the key hint. Another
    /// highlight, the notes field opened or written into, or the dialog gone leaves one of them off the screen. A write counted
    /// from this reading checks them in its own script (`TerminalAppBridge.answerScript`). Only the layout with a preview has them.
    var screenAnchors: [String] = []

    /// How many lines, counted from the end of the text, belong to the prompt (heading, options and hints).
    var tailLines: Int
    /// What identifies the prompt apart from where the highlight is: the same dialog keeps its signature while the user
    /// moves through it, a new one gets another.
    var signature: String

    /// The keys that choose `index`: the arrows from the highlighted option, then Enter. A text field is only reached,
    /// never confirmed; an option that is already highlighted needs just Enter. Arrows then Enter reach a Terminal tab in one
    /// write, without Accessibility (`TerminalAppBridge.answerAction`). A text field's arrows travel with the answer's text
    /// instead (`TerminalAppBridge.fieldAnswerAction`), never on their own.
    func keys(choosing index: Int) -> [TerminalKey] {
        guard options.indices.contains(index) else { return [] }
        var keys = arrows(to: index)
        if options[index].input != .inline { keys.append(.enter) }
        return keys
    }

    /// The arrows from the highlighted option to `index`, none when it is the highlighted one.
    func arrows(to index: Int) -> [TerminalKey] {
        guard options.indices.contains(index) else { return [] }
        let delta = index - highlighted
        return [TerminalKey](repeating: delta > 0 ? .down : .up, count: abs(delta))
    }

    /// How many arrow presses reach `index`.
    func moves(to index: Int) -> Int { abs(index - highlighted) }

    /// The arrows that put the highlight on option `index` before notes are written for it (`TerminalAppBridge.notesAnswerAction`);
    /// nil when it is no option that takes notes ("Chat about this", a question without a preview). Claude's notes field answers
    /// with the highlighted option only once the highlight moved in that question (2.1.295: `if(notes.trim()&&moved)answer(highlighted)`;
    /// unmoved, Enter in the field answers with the answer the question already had, or with "(notes only)"), and the screen doesn't
    /// tell whether it did: an option already highlighted is left and come back to (↑ ↓, or ↓ ↑ for the first). From "Chat about
    /// this" the first ↑ only returns to the options, which is no move.
    func notesArrows(to index: Int) -> [TerminalKey]? {
        guard takesNotes, options.indices.contains(index), options[index].number != nil, options.indices.contains(highlighted) else { return nil }
        var arrows = arrows(to: index)
        let moves = options[highlighted].number == nil ? arrows.count - 1 : arrows.count
        if moves <= 0 { arrows += index > 0 ? [.up, .down] : [.down, .up] }
        return arrows.count <= TerminalAppBridge.answerArrowLimit ? arrows : nil
    }

    /// Whether the notes row shows `text`: compared without whitespace, as notes that wrap join with a space where Claude broke them.
    func notesShow(_ text: String) -> Bool {
        let squeeze = { (value: String) in value.filter { !$0.isWhitespace } }
        guard let notes, !squeeze(text).isEmpty else { return false }
        return squeeze(notes) == squeeze(text)
    }
    /// Choosing `index` in a Terminal tab needs Accessibility: no option does any more. Every choice goes as one write
    /// (`keys(choosing:)`), and a text field takes no key until its answer goes, arrows and text together in one write
    /// (`AppModel.answer(_:option:text:on:)`). Arrows alone used to bring Terminal forward to post them as key events.
    func needsDirectKeys(choosing index: Int) -> Bool {
        guard options.indices.contains(index), options[index].input != .inline else { return false }
        let keys = keys(choosing: index)
        return !keys.isEmpty && TerminalAppBridge.answerAction(keys) == nil
    }

    /// Which question this is, apart from option `index`'s own row (a text field, whose row shows what is written into it) and
    /// from what the user changes while answering: the highlight, the boxes, the tabs' answered marks (a question with several
    /// answers marks its tab as soon as its field has text), and the kind, which reads the options' words. The same question
    /// with its field written into keeps it; the next question of a dialog with tabs, or another dialog, doesn't.
    func identity(ignoringOption index: Int) -> String {
        let rows = options.enumerated().map { $0.offset == index ? "\u{1E}" : $0.element.title }
        return ([context ?? "", header ?? "", question, tabs.map(\.title).joined(separator: "\u{1E}"), String(options.count)] + rows).joined(separator: "\u{1F}")
    }

    /// Whether option `index` is a text field that now shows `text`: Claude draws what was written into the field in the
    /// option's row instead of its placeholder ("❯ 3. Usa MongoDB" where "Type something." was), wrapping a long answer onto
    /// the rows under it, which read as the option's description. Compared without whitespace: whole when the answer is
    /// short, by its first `MessageEcho.key` characters when long. A placeholder that merely starts like the answer ("Type")
    /// never counts: the answer has to be all there is.
    func field(_ index: Int, shows text: String) -> Bool {
        guard options.indices.contains(index) else { return false }
        let squeeze = { (value: String) in value.filter { !$0.isWhitespace } }
        let answer = squeeze(text), key = MessageEcho.key(text)
        guard key.count >= 1 else { return false }
        let option = options[index]
        let shown = squeeze(option.title + (option.detail ?? ""))
        return answer.count <= key.count ? shown == answer : shown.hasPrefix(key)
    }

    // MARK: - Reading the screen

    /// The prompt at the end of `text`, or nil when it does not end in one.
    static func parse(_ text: String) -> AgentPrompt? {
        // Claude's list of agents under its mode line ("⏺ main", "○ fork  Reading…") is chrome, like the mode line.
        let text = AgentActivity.withoutTree(text)
        // First: its option rows also hold the preview's box, which the numbered rules would take for the options' text.
        if let found = previewed(text) { return found }
        let rows = text.suffix(Limits.characters).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(Limits.rows).map { Row(String($0)) }
        guard rows.count >= 2 else { return nil }
        return numbered(rows) ?? selector(rows)
    }

    /// `text` without the prompt's own lines, which the card shows instead. The context above them stays, so the user
    /// still reads what is being asked about. Unchanged when there is no prompt.
    static func withoutPrompt(_ text: String) -> String {
        guard let prompt = parse(text) else { return text }
        let text = AgentActivity.withoutTree(text)
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
        /// Only the end of the screen can hold a live prompt; a question with long descriptions fills a tall screen.
        static let characters = 14_000
        static let rows = 90
        static let options = 12
        /// Description lines under one option: a long description wraps over several.
        static let detailRows = 10
        /// Lines of the question above the options.
        static let questionRows = 12
        /// How far above the options a question's row of tabs may be.
        static let chipDistance = 30
        /// Quiet lines (hints, the mode line, Claude's agent list) that may follow the dialog.
        static let quietRows = 12
        /// Rows a dialog's key hint may wrap onto past its first: Claude's longest is about 130 columns.
        static let hintRows = 3
        /// A selector's rows are short; a long line is prose.
        static let selectorWidth = 200
    }

    private enum Patterns {
        /// Box-drawing characters that make up rules and frames.
        static let frame: Set<Character> = ["─", "━", "═", "╌", "┄", "╍", "┈", "┉", "┅", "│", "┃", "║", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╔", "╗", "╚", "╝"]
        static let verticals: Set<Character> = ["│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋", "▏", "▕"]
        /// What opens a line of the review step: a question ("● …"), its answer ("→ …") or Claude's warning ("⚠ …").
        static let reviewMarks: Set<Character> = ["●", "•", "○", "◯", "→", "⚠"]
        static let noAnswer = Pattern(#"^\(?(no answer|not answered|unanswered|sin respuesta)\)?\.?$"#, caseInsensitive: true)
        /// The highlight Claude (❯) and Codex (›) put in front of the current option.
        static let markers: Set<Character> = ["❯", "›"]
        /// What Claude's model picker puts in front of the first or last option it shows when there are more.
        static let scrollMarks: Set<Character> = ["↓", "↑", "▼", "▲"]
        /// "… +3 models", "↑ … +2 more": options the list does not show.
        static let more = Pattern(#"^([↑↓▲▼])?\s*(?:…|\.\.\.)\s*\+(\d+)\s+\S+(?:\s+\S+)?$"#)
        /// What opens a reply, a tool result or a quoted message.
        static let proseMarks: Set<Character> = ["⏺", "●", "•", "⎿", ">"]
        static let plainRule = Pattern(#"^[-=_]{5,}$"#)
        static let numbered = Pattern(#"^(\d{1,2})[.)]\s+(\S.*)$"#)
        static let tool = Pattern(#"^[⏺●]\x{FE0F}?\s+([A-Za-z][\w:.-]*\(.*)$"#)
        /// "(esc)", "(shift+tab)", "(y)": the key an option names for itself.
        static let shortcut = Pattern(#"\s*\((esc|tab|shift\+tab|ctrl\+[a-z]|[a-z])\)\s*$"#, caseInsensitive: true)

        /// What the dialogs print under their options. "esc to interrupt" (the spinner's hint) is not one of them.
        static let hints = ["esc to ", "esc ·", "enter to ", "press enter", "to select", "to navigate", "to confirm", "to cancel", "to exit",
                            "tab to ", "ctrl+e", "ctrl+g", "ctrl-g", "↑/↓", "↑↓", "space to", "to adjust", "to toggle", "to submit", "←/→", "← →"]
        /// How a dialog's own key hint opens, when it has no "·" between its parts.
        static let hintOpeners = ["esc", "enter", "press", "tab", "space", "↑", "←", "ctrl", "shift", "type to"]
        /// Claude's mode line and Codex's footer, which may follow a dialog.
        static let modeLines = ["⏵⏵", "shift+tab to cycle", "for shortcuts", "bypass permissions", "accept edits on", "plan mode on", "auto mode on", "context left",
                                "for agents", "↓ to manage"]
        /// Claude's line while background agents keep a turn open ("✻ Waiting for 1 background agent to finish").
        static let waiting = Pattern(#"^\S?\s*Waiting for \d+ background agents?"#)
        /// A setting changed in place, under a picker's options: "◐ Medium effort (default) ← → to adjust".
        static let adjustment = Pattern(#"^(.*?)\s*(?:←\s*/?\s*→|◀\s*/?\s*▶)\s*to (?:adjust|change)\b"#, caseInsensitive: true)
        /// "[ ] PostgreSQL", "[✔] SQLite", "☐ Redis", "☒ Redis": a box in front of an option that takes several answers.
        static let checkbox = Pattern(#"^(?:\[([ xX✓✔×*])\]|([☐☑☒]))\s+(\S.*)$"#)
        /// "✔ Database", "☐ Cache": one tab of a dialog with several questions, or the label of a single question.
        static let chip = Pattern(#"^([☐☑☒✔✓□■])\s+(\S.*)$"#)
        /// The mark Claude puts after what is set now ("Sonnet ✔").
        static let currentMark: Set<Character> = ["✔", "✓"]

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
        /// A hint by its shape too ("Enter to select · Esc to cancel", "Esc to exit"): a question that merely contains
        /// "to confirm" is not one.
        let isKeyHint: Bool
        let isModeLine: Bool
        /// Starts with the highlight.
        let marked: Bool
        /// `text` without the highlight.
        let body: String
        /// The column where `body` starts: the same for every option of a list, marked or not.
        let bodyColumn: Int
        let number: Int?
        let optionText: String
        /// "↓" or "↑" in front of an option: the list goes on past the screen that way (Claude's model picker).
        let scrollMark: Character?
        /// "… +3 models": how many options the list hides, and which way when the line says ("↑ … +3 models").
        let more: Int?
        let moreMark: Character?

        init(_ raw: String) {
            var line = Substring(raw)
            var lead = line.prefix(while: \.isWhitespace).count
            line = line.dropFirst(lead)
            // Codex's older dialogs draw themselves inside a box: "│ ❯ 1. Yes │". Claude's review step draws a bar on the left
            // only ("│ ● Según la doc…", "│   WhatsApp Business…"). Neither is part of the text.
            if line.count >= 2, let first = line.first, let last = line.last, Patterns.verticals.contains(first), Patterns.verticals.contains(last) {
                line = line.dropFirst().dropLast()
                lead = line.prefix(while: \.isWhitespace).count
                line = line.dropFirst(lead)
            } else if line.count >= 3, let first = line.first, Patterns.verticals.contains(first) || (first == "|" && !line.dropFirst().contains("|")),
                      line.dropFirst().first?.isWhitespace == true {
                line = line.dropFirst()
                lead = line.prefix(while: \.isWhitespace).count
                line = line.dropFirst(lead)
            }
            if line.count >= 3, let last = line.last, Patterns.verticals.contains(last), line.dropLast().last?.isWhitespace == true {
                line = line.dropLast()
            }
            text = line.trimmingCharacters(in: .whitespaces)
            indent = lead
            let lower = text.lowercased()
            let drawing = text.filter { Patterns.frame.contains($0) }.count
            isFrame = (drawing >= 1 && drawing + text.filter(\.isWhitespace).count == text.count) || Patterns.plainRule.matches(text)
            // A reply line ("⏺ Press Enter to select it") or a quoted message is prose, not the dialog's own hint.
            let prose = text.first.map { Patterns.proseMarks.contains($0) } ?? false
            // "● xHigh effort ←/→ to adjust": the effort's dot is no reply's bullet.
            isHint = (!prose && !lower.contains("to interrupt") && Patterns.hints.contains { lower.contains($0) }) || Patterns.adjustment.matches(text)
            isKeyHint = isHint && (text.contains(" · ") || Patterns.hintOpeners.contains { lower.hasPrefix($0) })
            isModeLine = Patterns.modeLines.contains { lower.contains($0) } || Patterns.waiting.matches(text)
            if let groups = Patterns.more.groups(in: text), let count = groups[2].flatMap(Int.init) {
                more = count
                moreMark = groups[1]?.first
            } else {
                more = nil
                moreMark = nil
            }
            let scrolled = text.first.map(Patterns.scrollMarks.contains) == true && text.dropFirst().first?.isWhitespace == true
                && Patterns.numbered.matches(text.dropFirst().trimmingCharacters(in: .whitespaces))
            if let first = text.first, Patterns.markers.contains(first) || scrolled, text.dropFirst().first.map(\.isWhitespace) ?? true {
                let rest = text.dropFirst()
                let spaces = rest.prefix(while: \.isWhitespace).count
                marked = !scrolled
                scrollMark = scrolled ? first : nil
                body = String(rest.dropFirst(spaces))
                bodyColumn = lead + 1 + spaces
            } else {
                marked = false
                scrollMark = nil
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
        var isQuiet: Bool { isBlank || isFrame || isHint || isModeLine || more != nil }
        /// "⏺ Bash(rm -rf build)": the call a permission question is about.
        var isToolCall: Bool { indent <= 1 && Patterns.tool.matches(text) }
    }

    // MARK: - Numbered options

    private static func numbered(_ rows: [Row]) -> AgentPrompt? {
        guard let last = rows.lastIndex(where: { $0.number != nil }), quietTail(rows, after: last) else { return nil }
        var picked = [last]
        while let first = picked.first, let number = rows[first].number, number > 1 {
            if let previous = optionAbove(rows, first), rows[previous].number == number - 1 { picked.insert(previous, at: 0); continue }
            // A list scrolled past its start keeps its real numbers: it may begin at 4 under "↑ … +3 models" or an "↑".
            guard scrolledAbove(rows, first) else { return nil }
            break
        }
        guard (2...Limits.options).contains(picked.count), picked.filter({ rows[$0].marked }).count == 1,
              let low = picked.map({ rows[$0].bodyColumn }).min(), let high = picked.map({ rows[$0].bodyColumn }).max(), high - low <= 1 else { return nil }
        let ends = picked.dropFirst() + [descriptionEnd(rows, after: last)]
        let options = zip(picked, ends).enumerated().map { position, pair in
            makeOption(index: position, number: rows[pair.0].number, text: rows[pair.0].optionText, detail: describing(rows, from: pair.0 + 1, to: pair.1))
        }
        return build(rows, firstOption: picked[0], lastOption: last, options: options, highlighted: picked.firstIndex { rows[$0].marked } ?? 0, selector: false)
    }

    /// A line right under an option, indented past the option's text: its description, even when it happens to contain a
    /// hint's words ("Press Enter to confirm the deploy"). Real hints sit at the dialog's margin.
    private static func describes(_ row: Row, option: Row) -> Bool {
        !row.isBlank && !row.isFrame && !row.marked && row.number == nil && row.more == nil && row.indent > option.bodyColumn
    }

    private static func scrolledAbove(_ rows: [Row], _ index: Int) -> Bool {
        if rows[index].scrollMark == "↑" || rows[index].scrollMark == "▲" { return true }
        guard let above = rows[..<index].lastIndex(where: { !$0.isBlank }) else { return false }
        return rows[above].more != nil
    }

    /// Only blank lines, rules, hints and the last option's own description may follow it.
    private static func quietTail(_ rows: [Row], after last: Int) -> Bool {
        var described = 0
        var closed = false
        var quiet = 0
        for row in rows[(last + 1)...] {
            if row.isBlank { closed = true; continue }
            if !closed, describes(row, option: rows[last]) {
                guard described < Limits.detailRows else { return false }
                described += 1
                continue
            }
            guard row.isQuiet else { return false }
            closed = true; quiet += 1
        }
        return quiet <= Limits.quietRows
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
        while end < rows.count, !rows[end].isQuiet || describes(rows[end], option: rows[index]) { end += 1 }
        return end
    }

    private static func describing(_ rows: [Row], from start: Int, to end: Int) -> [String] {
        guard start < end else { return [] }
        return rows[start..<end].filter { !$0.isBlank && !$0.isFrame }.prefix(Limits.detailRows).map(\.text)
    }

    // MARK: - Options beside a preview

    /// Claude's question whose options carry a preview, as Claude Code 2.1.295 draws it (its renderer, read for this): one answer
    /// only, any option with a `preview`, not in screen-reader mode. Under the tabs and the question, a row holds two columns: the
    /// options, 30 columns wide, and 4 columns to their right the highlighted option's preview in a box, at most the terminal's
    /// width less 34 columns and its height less 26 rows (a fold "✂ N lines hidden" says how many lines it keeps out), with the
    /// notes row under it. Then "Chat about this" under a rule and the key hint:
    ///
    ///     ❯ 1. Rediseñarlo aquí             ┌────────────────────────────────┐
    ///         (Recomendada)                 │ Hoy:                           │
    ///       2. Ticket aparte                │ …                              │
    ///                                       ├─── ✂ ─── 5 lines hidden ───────┤
    ///                                       └────────────────────────────────┘
    ///
    ///                                       Notes: press n to add notes
    ///
    ///     ──────────────────────────────────────────────────────────────────────
    ///       Chat about this
    ///
    ///     Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · Esc to cancel
    ///
    /// The options and the box share their lines, so the numbered rules don't fit it: the box's rows after the last option are
    /// neither its description nor quiet, and each option's text would run into the box. Every line is cut at the box's column
    /// first (`sides`). A title too long for its column wraps under itself, four columns in; options have no descriptions here.
    /// Nothing else changes with the terminal's size: a narrow one gets a narrower box beside the options, never one under them.
    ///
    /// The keys are those of a numbered question: ↑/↓ move the highlight (and the preview with it), Enter answers the highlighted
    /// option (and moves to the next tab, or the review step, in a dialog with several questions), ↓ past the last option reaches
    /// "Chat about this", a digit only moves the highlight. `n` opens the notes field: see `notesArrows(to:)` and `notesFocused`.
    private static func previewed(_ text: String) -> AgentPrompt? {
        // Cheap first: the notes row is near the end, and no other dialog has one.
        guard text.suffix(Preview.notesReach).contains(Preview.notesLabel) else { return nil }
        let lines = text.suffix(Preview.characters).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(Preview.rows).map(String.init)
        guard let notesRow = lines.indices.reversed().prefix(Preview.notesDistance).first(where: {
            lines[$0].contains(Preview.notesLabel) && sides(lines[$0]).right.hasPrefix(Preview.notesLabel)
        }) else { return nil }
        // Up from the notes row, past the blank row above it: the box's bottom edge, then its rows up to its top edge.
        var bottom = notesRow - 1
        while bottom >= 0, notesRow - bottom <= 2, sides(lines[bottom]).right.isEmpty { bottom -= 1 }
        guard bottom > 0, isEdge(sides(lines[bottom]).right, "└", "┘") else { return nil }
        var top = bottom - 1
        while top >= 0, !isEdge(sides(lines[top]).right, "┌", "┐") {
            guard bottom - top <= Preview.rows, let mark = sides(lines[top]).right.first, mark == "│" || mark == "├" else { return nil }
            top -= 1
        }
        guard top >= 0 else { return nil }
        let rows = lines.map(Row.init)
        // The block of options ends at the rule over "Chat about this" (or at the hint, should a build leave it out).
        var end = notesRow + 1
        while end < rows.count, !(rows[end].isFrame && !rows[end].isBlank), !rows[end].isKeyHint { end += 1 }

        // The options' column: a number at its margin opens an option, anything further in continues its title.
        var picked: [(number: Int, marked: Bool, parts: [String])] = []
        // The screen's own lines that show only while the question is as read (`screenAnchors`).
        var anchors: [String] = []
        for row in top..<end {
            let side = sides(lines[row])
            guard !side.left.isEmpty else { continue }
            if side.indent <= 2, let groups = Preview.option.groups(in: side.left), let number = groups[2].flatMap(Int.init), let title = groups[3] {
                picked.append((number, groups[1] != nil, [title]))
                if groups[1] != nil { anchors.append(lines[row]) }
            } else if !picked.isEmpty, side.indent >= 3 {
                picked[picked.count - 1].parts.append(side.left)
            } else { return nil }
        }
        guard (2...Limits.options).contains(picked.count), picked.map(\.number) == Array(1...picked.count) else { return nil }
        var options = picked.enumerated().map { index, option -> Option in
            // "✔" after a title: the answer the question already has (a tab the user came back to).
            var current = false
            let parts = option.parts.map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let last = trimmed.last, Patterns.currentMark.contains(last), trimmed.dropLast().last?.isWhitespace ?? true else { return trimmed }
                current = true
                return String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            let title = parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // Enter answers any of them: none is a text field here, whatever its words ("Otro enfoque").
            return Option(index: index, number: option.number, title: title, detail: nil, shortcut: nil, input: .none, current: current)
        }

        // "Chat about this" under the rule: ↓ past the last option reaches it, and it has the highlight then (the option above
        // keeps its mark as well).
        var chatMarked = false
        var after = end
        if end < rows.count, rows[end].isFrame, let chat = rows[(end + 1)...].firstIndex(where: { !$0.isBlank }), Patterns.followUp.matches(rows[chat].body) {
            options.append(Option(index: options.count, number: nil, title: rows[chat].body, detail: nil, shortcut: nil, input: .followUp))
            chatMarked = rows[chat].marked
            after = chat + 1
            anchors.append(lines[chat])
        }
        let tail = rows[after...]
        // The key hint wraps at the terminal's width like any text, and the notes field makes it longer ("· ctrl+g to edit in Vim"):
        // a row it wrapped onto ("cancel") is part of it, not something after the dialog.
        let hint = keyHint(tail)
        guard tail.indices.allSatisfy({ tail[$0].isQuiet || hint.rows.contains($0) }), tail.filter({ !$0.isBlank }).count <= Limits.quietRows else { return nil }
        let actions = hint.text.map(keyActions) ?? []
        let marked = picked.indices.filter { picked[$0].marked }
        guard chatMarked ? marked.count <= 1 : marked.count == 1 else { return nil }
        let highlighted = chatMarked ? options.count - 1 : marked[0]

        // The box's rows, its frame gone; the fold says how many more lines there are.
        var shown: [String] = []
        var hidden = 0
        for row in (top + 1)..<bottom {
            var right = Substring(sides(lines[row]).right)
            if right.first == "├" {
                if let count = Preview.fold.groups(in: String(right))?[1].flatMap(Int.init) { hidden = count }
                continue
            }
            right = right.dropFirst()
            if right.last == "│" { right = right.dropLast() }
            if right.first == " " { right = right.dropFirst() }
            shown.append(String(right.reversed().drop(while: \.isWhitespace).reversed()))
        }
        while shown.last?.isEmpty == true { shown.removeLast() }
        let preview = shown.joined(separator: "\n")

        // The notes row: Claude's invitation, its placeholder while the field is open and empty, or the notes, wrapped under
        // themselves.
        var written = String(sides(lines[notesRow]).right.dropFirst(Preview.notesLabel.count)).trimmingCharacters(in: .whitespaces)
        anchors.append(lines[notesRow])
        for row in (notesRow + 1)..<max(notesRow + 1, end) {
            let more = sides(lines[row]).right
            guard !more.isEmpty else { break }
            written += " " + more
            anchors.append(lines[row])
        }
        anchors += hint.rows.map { lines[$0] }
        let open = written.hasPrefix(Preview.notesPlaceholder)
        let notes = open || written.isEmpty || written.lowercased() == Preview.notesInvitation ? nil : written
        // Only the open field draws its placeholder, and only then does the hint offer the external editor for it.
        let focused = open || actions.contains { $0.key == Preview.editorKey && $0.label.lowercased().hasPrefix(Preview.editorAction) }

        let heading = heading(rows, above: top)
        let start = min(heading?.row ?? top, top)
        let titles = options.map { $0.title.lowercased() }
        let affirmative = titles.contains { $0.hasPrefix("yes") || $0.hasPrefix("sí") }
        let negative = titles.contains { $0 == "no" || $0.hasPrefix("no,") || $0.hasPrefix("no ") }
        let kind: Kind = affirmative && negative ? .approval : .question
        let question = heading?.question ?? ""
        let signature = ([String(describing: kind), "", heading?.header ?? "", question] + options.map(\.title)).joined(separator: "\u{1F}")
        return AgentPrompt(kind: kind, question: question, note: heading?.note, header: heading?.header, tabs: heading?.tabs ?? [], context: nil,
                           options: options, highlighted: highlighted, actions: actions,
                           preview: preview.isEmpty || preview == Preview.none ? nil : preview, previewHiddenLines: hidden,
                           takesNotes: true, notes: notes, notesOpen: open, notesFocused: focused,
                           screenAnchors: anchors.map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }.filter { !$0.isEmpty },
                           tailLines: rows.count - start, signature: signature)
    }

    /// The dialog's key hint among `rows` (what follows its options): the first row that is one, and the rows it wrapped onto, read as
    /// one line. Claude's hint is parts "key to action" between " · ", its last "Esc to cancel"; Ink breaks it at a space, so a row
    /// continues it only where a break can fall: the hint so far stops inside a part ("… · Esc" over "to cancel", "… · Esc to" over
    /// "cancel", "… questions ·" over "ctrl+g to edit in Vim · Esc to cancel"), or the row opens with the next part ("· Esc to cancel"),
    /// or with the rest of an action before the next part ("… ctrl+g to edit" over "in Vim · Esc to cancel"). The rows taken are the
    /// most that read, whole, as keys and what they do. A line under a hint that is whole (Claude's mode line) is not part of it.
    private static func keyHint(_ rows: ArraySlice<Row>) -> (text: String?, rows: Range<Int>) {
        guard let first = rows.firstIndex(where: \.isKeyHint) else { return (nil, rows.startIndex..<rows.startIndex) }
        var text = rows[first].text, best = (text: text, end: first + 1), end = first + 1
        while end < rows.endIndex, end - first <= Limits.hintRows, !rows[end].isBlank, !rows[end].isModeLine {
            let next = rows[end].text
            let head = next.components(separatedBy: "·")[0].trimmingCharacters(in: .whitespaces)
            guard !readsAsKeys(text) || (next.contains("·") && keyActions(head).isEmpty) else { break }
            text += " " + next
            end += 1
            if readsAsKeys(text) { best = (text, end) }
        }
        return (best.text, first..<best.end)
    }

    /// Every part of a hint names a key and what it does ("Enter to select · ↑/↓ to navigate · Esc to cancel").
    private static func readsAsKeys(_ hint: String) -> Bool {
        keyActions(hint).count == hint.components(separatedBy: "·").count
    }

    private enum Preview {
        /// The options' column is 30 wide and the box starts 4 columns to its right: what starts this far into a line, past a gap,
        /// is the box's side (the notes row, its wrapped lines). Kept short of 30 for wide characters, which Terminal's text
        /// counts once.
        static let column = 26
        /// Characters from the end that hold the notes row: the rule, "Chat about this", the hint and Claude's mode line after it.
        static let notesReach = 6_000
        /// Rows from the end where the notes row may be.
        static let notesDistance = 24
        /// The box grows with the terminal's height (its rows less 26): a tall terminal's dialog is longer than other dialogs.
        static let rows = 240
        static let characters = 60_000
        static let notesLabel = "Notes:"
        static let notesInvitation = "press n to add notes"
        static let notesPlaceholder = "Add notes on this design"
        /// The key hint's part while the notes field is open: "ctrl+g to edit in Vim" (the chord as Claude prints it by default).
        static let editorKey = "ctrl+g"
        static let editorAction = "edit in "
        static let none = "No preview available"
        /// The box's left edge in each of its rows: its corners, its side, the fold.
        static let edges: Set<Character> = ["┌", "│", "├", "└"]
        static let fold = Pattern(#"✂\s*─*\s*(\d+)\s+lines?\s+hidden"#)
        /// "❯ 1. Rediseñarlo aquí", "  2. Ticket aparte": the highlight, the number, the title's first line.
        static let option = Pattern(#"^([❯›])?\s*(\d{1,2})\.\s+(\S.*)$"#)
    }

    /// A line of that layout cut at the box's column: the options' side (its text, and the column it starts at) and the box's side
    /// (a frame row, a row of the preview, the notes). The box's side starts after a gap of two blanks or more, on a box edge at
    /// any column or on anything past `Preview.column`; a line that starts there has nothing on the options' side.
    private static func sides(_ line: String) -> (left: String, indent: Int, right: String) {
        let characters = Array(line)
        guard let first = characters.firstIndex(where: { !$0.isWhitespace }) else { return ("", 0, "") }
        var index = first
        while index < characters.count {
            let opens = index == first || (characters[index - 1] == " " && characters[index - 2] == " ")
            if opens, !characters[index].isWhitespace, index >= Preview.column || Preview.edges.contains(characters[index]) { break }
            index += 1
        }
        let left = String(characters[first..<index]).trimmingCharacters(in: .whitespaces)
        let right = String(characters[index...].reversed().drop(while: \.isWhitespace).reversed())
        return (left, first, right)
    }

    /// "┌──────┐", "└──────┘": a box's top or bottom edge.
    private static func isEdge(_ text: String, _ open: Character, _ close: Character) -> Bool {
        text.count >= 3 && text.first == open && text.last == close && text.dropFirst().dropLast().allSatisfy { $0 == "─" }
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
        return build(rows, firstOption: top, lastOption: bottom, options: options, highlighted: marked - top, selector: true)
    }

    // MARK: - Assembly

    private static func makeOption(index: Int, number: Int?, text: String, detail: [String]) -> Option {
        var title = text
        var detail = detail
        // "[ ] PostgreSQL", "☒ Redis": a question that takes several answers.
        var checked: Bool?
        if let groups = Patterns.checkbox.groups(in: title), let rest = groups[3] {
            let box = groups[1] ?? groups[2] ?? " "
            checked = !(box == " " || box == "☐")
            title = rest
        }
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
        // "Sonnet ✔" or "Sonnet 4.6 for daily use ✔": the mark after what is set now, on the title or its description.
        var current = false
        func unmarked(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let last = trimmed.last, Patterns.currentMark.contains(last), trimmed.dropLast().last?.isWhitespace ?? true else { return nil }
            return String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let plain = unmarked(title), !plain.isEmpty { title = plain; current = true }
        if let first = detail.first, let plain = unmarked(first) { detail[0] = plain; current = true }
        if let last = detail.last, let plain = unmarked(last) { detail[detail.count - 1] = plain; current = true }
        detail = detail.filter { !$0.isEmpty }
        let input: Input = Patterns.inline.matches(title) ? .inline : (Patterns.followUp.matches(title) ? .followUp : .none)
        return Option(index: index, number: number, title: title, detail: detail.isEmpty ? nil : detail.joined(separator: " "), shortcut: shortcut, input: input,
                      checked: checked, current: current)
    }

    private static func build(_ rows: [Row], firstOption: Int, lastOption: Int, options: [Option], highlighted: Int, selector: Bool) -> AgentPrompt {
        let heading = heading(rows, above: firstOption)
        let start = min(heading?.row ?? firstOption, firstOption)
        let context = (max(0, start - 12)..<start).reversed().first { rows[$0].isToolCall }.map { String(rows[$0].text.drop(while: { !$0.isLetter }).prefix(160)) }
        let titles = options.map { $0.title.lowercased() }
        let affirmative = titles.contains { $0.hasPrefix("yes") || $0.hasPrefix("allow") || $0.hasPrefix("approve") || $0.hasPrefix("sí") }
        let negative = titles.contains { $0 == "no" || $0.hasPrefix("no,") || $0.hasPrefix("no ") || $0.hasPrefix("deny") || $0.hasPrefix("reject") }
        let after = rows[(lastOption + 1)...]
        let before = rows[max(0, firstOption - 3)..<firstOption]
        let moreAbove = before.compactMap(\.more).last ?? ((rows[firstOption].scrollMark).map { "↑▲".contains($0) ? 1 : 0 } ?? 0)
        let belowCount = after.prefix(3).first(where: { $0.more != nil && !"↑▲".contains($0.moreMark ?? "↓") })?.more
        let moreBelow = belowCount ?? ((rows[lastOption].scrollMark).map { "↓▼".contains($0) ? 1 : 0 } ?? 0)
        let actions = after.last(where: \.isKeyHint).map { keyActions($0.text) } ?? []
        let adjustment = after.lazy.compactMap { row -> String? in
            guard row.isHint, let lead = Patterns.adjustment.groups(in: row.text)?[1] else { return nil }
            // The level's own drawing ("◐", "▌▌▌") goes; the words stay.
            let words = lead.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? nil : words
        }.first
        // A numbered menu the user opened with a slash command (the model picker, an output style) closes with "Esc to
        // exit" and marks what is set now; Claude's own questions and permissions say "Esc to cancel".
        let exits = after.contains { $0.isHint && $0.text.lowercased().contains("esc to exit") }
        let asks = heading?.header != nil || !(heading?.tabs.isEmpty ?? true) || options.contains { $0.input != .none }
        // The model picker says "Esc to cancel" like a question, but sets a default and takes a letter ("s"), and scrolls: any
        // of those, scrolled away from its ticked row or not, makes it the menu it is.
        let setting = actions.contains { $0.key == "enter" && $0.label.lowercased().contains("default") } || actions.contains { $0.key.count == 1 && $0.key.first?.isLetter == true }
        let menu = options.contains(where: \.current) || ((exits || setting || moreAbove > 0 || moreBelow > 0) && !asks)
        let kind: Kind = selector ? .selector : (affirmative && negative ? .approval : (menu ? .selector : .question))
        let question = heading?.question ?? ""
        let signature = ([String(describing: kind), context ?? "", heading?.header ?? "", question] + options.map(\.title)).joined(separator: "\u{1F}")
        return AgentPrompt(kind: kind, question: question, note: heading?.note, header: heading?.header, tabs: heading?.tabs ?? [], context: context,
                           options: options, highlighted: highlighted, multiSelect: options.filter { $0.checked != nil }.count >= 2,
                           adjustment: adjustment, moreAbove: moreAbove, moreBelow: moreBelow, actions: actions,
                           review: heading?.review ?? [], reviewTitle: heading?.reviewTitle, warning: heading?.warning,
                           tailLines: rows.count - start, signature: signature)
    }

    /// "Enter to set as default · s to use this session only · Esc to cancel" → its keys and what each does.
    private static func keyActions(_ hint: String) -> [KeyAction] {
        hint.components(separatedBy: "·").compactMap { part in
            let words = part.trimmingCharacters(in: .whitespaces)
            guard let range = words.range(of: " to ") else { return nil }
            let key = words[..<range.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
            let label = words[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 12, !label.isEmpty else { return nil }
            return KeyAction(key: key, label: label)
        }
    }

    private struct Heading {
        var question: String
        var note: String?
        var header: String?
        var tabs: [Tab] = []
        var review: [ReviewItem] = []
        var reviewTitle: String?
        var warning: String?
        /// The first row the heading takes, where the prompt starts.
        var row: Int
    }

    /// A line that may belong to the text above the options.
    private static func isHeadingText(_ row: Row) -> Bool {
        guard !row.isBlank, !row.isFrame, !row.isModeLine, !row.isKeyHint, !row.isToolCall, row.number == nil, !row.marked else { return false }
        return !(row.text.first.map(Patterns.proseMarks.contains) ?? false)
    }

    /// The text above the options. Claude's questions open with a row of tabs or a label ("☐ Database"): everything
    /// between it and the options is the question. Otherwise it is the nearest paragraph: the lines right above the
    /// options at one indent (so the command a permission is about, indented deeper, stays out), wrapped lines joined.
    private static func heading(_ rows: [Row], above index: Int) -> Heading? {
        if let chips = chips(rows, above: index) {
            if let review = review(Array(rows[(chips.row + 1)..<index]), tabs: chips.tabs) {
                return Heading(question: review.question, note: nil, header: nil, tabs: chips.tabs, review: review.items, reviewTitle: review.title,
                               warning: review.warning, row: chips.row)
            }
            var paragraphs: [String] = []
            var current: [String] = []
            for row in rows[(chips.row + 1)..<index] {
                if row.isBlank || row.isFrame {
                    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
                } else { current.append(row.text) }
            }
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            let single = chips.tabs.count == 1 && !chips.arrows
            return Heading(question: paragraphs.joined(separator: "\n"), note: nil, header: single ? chips.tabs[0].title : nil,
                           tabs: single ? [] : chips.tabs, row: chips.row)
        }
        var k = index - 1
        var skipped = 0
        while k >= 0, rows[k].isBlank || rows[k].isFrame, skipped < 2 { k -= 1; skipped += 1 }
        guard k >= 0, isHeadingText(rows[k]) else { return nil }
        var group = [k]
        while let top = group.first, top > 0, group.count < Limits.questionRows, isHeadingText(rows[top - 1]), rows[top - 1].indent == rows[k].indent {
            group.insert(top - 1, at: 0)
        }
        func ends(_ text: String, in marks: [Character]) -> Bool { text.last.map(marks.contains) ?? false }
        // A short title over its description: "Select model" over "Switch between Claude models."
        if group.count >= 2, let title = group.first, rows[title].text.count <= 40, !ends(rows[title].text, in: [".", "?", "!", ":", ","]), ends(rows[k].text, in: [".", ")"]) {
            return Heading(question: rows[title].text, note: group.dropFirst().map { rows[$0].text }.joined(separator: " "), row: title)
        }
        return Heading(question: group.map { rows[$0].text }.joined(separator: " "), row: group[0])
    }

    private static func isReviewRow(_ row: Row) -> Bool {
        guard let first = row.text.first else { return false }
        return Patterns.reviewMarks.contains(first) && row.text.dropFirst().first?.isWhitespace == true
    }

    /// The review step between the tabs and the options: a title ("Review your answers"), one "● question" per question with
    /// its wrapped lines and its "→ answer", maybe a "⚠" warning, and what Claude asks last ("Ready to submit your answers?").
    /// Nil unless the rows have that shape: at least one "●" question, and an answer or a title that says it is a review.
    private static func review(_ rows: [Row], tabs: [Tab]) -> (title: String?, items: [ReviewItem], warning: String?, question: String)? {
        guard let firstItem = rows.firstIndex(where: { isReviewRow($0) && "●•○◯".contains($0.text.first!) }) else { return nil }
        func words(_ parts: [String]) -> String {
            parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func body(_ row: Row) -> String { String(row.text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let isWarning = { (row: Row) in isReviewRow(row) && row.text.first == "⚠" }
        let title = words(rows[..<firstItem].filter { !$0.isBlank && !$0.isFrame && !isWarning($0) }.map(\.text))
        var items: [ReviewItem] = []
        var question: [String] = []
        var answers: [String] = []
        var warning = rows[..<firstItem].first(where: isWarning).map { words([body($0)]) }
        var closing: [[String]] = []
        var listOver = false
        func close() {
            guard !question.isEmpty else { return }
            // "(no answer)": Claude's words for a question still open.
            let given = answers.filter { !Patterns.noAnswer.matches($0) }
            items.append(ReviewItem(question: words(question), answer: given.isEmpty ? nil : given.joined(separator: ", ")))
            question = []; answers = []
        }
        for row in rows[firstItem...] {
            if row.isBlank || row.isFrame {
                // A blank after the list ends it; what follows is Claude's closing question.
                if !question.isEmpty || !items.isEmpty { close(); listOver = true; closing.append([]) }
                continue
            }
            let mark = row.text.first!
            if isReviewRow(row), mark == "⚠" { close(); warning = words([body(row)]); continue }
            if listOver {
                if closing.isEmpty { closing.append([]) }
                closing[closing.count - 1].append(row.text)
                continue
            }
            if isReviewRow(row), "●•○◯".contains(mark) { close(); question = [body(row)]; continue }
            if isReviewRow(row), mark == "→" { answers.append(words([body(row)])); continue }
            // A wrapped line of the question, or of a long answer.
            if answers.isEmpty { question.append(row.text) } else { answers[answers.count - 1] = words([answers[answers.count - 1], row.text]) }
        }
        close()
        let lowerTitle = title.lowercased()
        guard !items.isEmpty, items.contains(where: { $0.answer != nil }) || lowerTitle.contains("review") || lowerTitle.contains("revis") else { return nil }
        // The questions follow the tabs, Submit aside, when the counts agree.
        let named = tabs.filter { !$0.isSubmit }
        if named.count == items.count { for index in items.indices { items[index].tab = named[index].title } }
        let asked = closing.map(words).filter { !$0.isEmpty }.joined(separator: "\n")
        return (title.isEmpty ? nil : title, items, warning, asked)
    }

    /// The row of tabs or the label over a Claude question ("←  ☐ Database  ☒ Cache  ✔ Submit  →", "☐ Database"), when
    /// only the question's text lies between it and the options.
    private static func chips(_ rows: [Row], above index: Int) -> (row: Int, tabs: [Tab], arrows: Bool)? {
        var k = index - 1
        while k >= 0, index - k <= Limits.chipDistance {
            let row = rows[k]
            if let found = tabs(in: row.text) { return (k, found.tabs, found.arrows) }
            guard row.isBlank || row.isFrame || isHeadingText(row) || isReviewRow(row) else { return nil }
            k -= 1
        }
        return nil
    }

    private static func tabs(in text: String) -> (tabs: [Tab], arrows: Bool)? {
        var line = Substring(text)
        var arrows = false
        if line.first == "←" { line = line.dropFirst(); arrows = true }
        if line.last == "→" { line = line.dropLast(); arrows = true }
        let parts = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= Limits.options else { return nil }
        var tabs: [Tab] = []
        for part in parts {
            guard let groups = Patterns.chip.groups(in: part), let box = groups[1], let title = groups[2], title.count <= 40 else { return nil }
            let submit = ["submit", "enviar"].contains(title.lowercased())
            tabs.append(Tab(title: title, answered: ["☑", "☒", "✔", "✓", "■"].contains(box) && !submit, isSubmit: submit))
        }
        // A lone "✔ Done" line is a reply's tick, not a question's label.
        if tabs.count == 1, !arrows, !["☐", "☑", "☒", "□", "■"].contains(text.first.map(String.init) ?? "") { return nil }
        return (tabs, arrows)
    }
}
