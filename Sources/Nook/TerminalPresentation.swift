import Foundation
import CoreGraphics

/// The interactive agent in the foreground of a terminal tab, if any.
enum TerminalAgent: String {
    case claude, codex

    /// Children follow their parents in Terminal's list, so the first agent is the visible TUI
    /// (a Codex helper launched by Claude still means the tab shows Claude).
    init?(processes: [String]) {
        for process in processes {
            let name = (process.split(separator: " ").first.map(String.init) ?? process)
            if let agent = TerminalAgent(rawValue: (name as NSString).lastPathComponent.lowercased()) { self = agent; return }
        }
        return nil
    }
    var title: String { self == .claude ? "Claude" : "Codex" }
}

/// What Claude Code makes of a text pasted into its box (2.1.293, its paste handler; a typed text never goes through it). The text is
/// cut before every " /" (a path) and at its line breaks; a piece that names an image file (.png, .jpg, .jpeg, .gif, .webp, also
/// quoted or with its spaces escaped) is read and attached as an image, and the box shows "[Image #N]" for it instead of the path,
/// in front of the rest of the text (its pieces joined by line breaks). N counts the session's images ("[Image #10]"). The Return
/// that came with such a paste is dropped: Claude forgets it once the images are read, so the message waits in its box for
/// another Enter. Only an absolute path can be read; when no piece can, the paste stays plain text (its Return dropped all the
/// same). A path typed in stays plain text.
enum ClaudeImagePaste {
    private static let cut = try! NSRegularExpression(pattern: #" (?=/|[A-Za-z]:\\)|\n"#)
    private static let image = try! NSRegularExpression(pattern: #"\.(png|jpe?g|gif|webp)$"#, options: .caseInsensitive)
    /// "[Image #3]" as Claude's box, its chat and its record write it (older shapes too: "[image]").
    static let placeholderPattern = #"\[[Ii]mage[^\]]*\]"#
    private static let placeholder = try! NSRegularExpression(pattern: placeholderPattern)

    /// The pieces of a pasted text that become images (their paths, unquoted and unescaped), and the words left of it.
    static func parts(_ text: String) -> (words: String, images: [String]) {
        guard text.contains(".") else { return (text, []) }
        var words: [String] = [], images: [String] = []
        for piece in pieces(text) {
            if let path = imagePath(piece) { images.append(path) } else { words.append(piece) }
        }
        return images.isEmpty ? (text, []) : (words.joined(separator: "\n"), images)
    }

    /// The text cut as Claude cuts a paste, without the blank pieces.
    private static func pieces(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = [], from = 0
        for match in cut.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: from, length: match.range.location - from)))
            from = NSMaxRange(match.range)
        }
        pieces.append(ns.substring(from: from))
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The image file a piece names, as Claude reads it: trimmed, without the quotes around it, with "\ " as a space; an absolute
    /// path, the only kind Claude can open.
    static func imagePath(_ piece: String) -> String? {
        var path = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == "\"" || first == "'", path.last == first { path = String(path.dropFirst().dropLast()) }
        let mark = "\u{0}"
        path = path.replacingOccurrences(of: #"\\"#, with: mark).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: mark, with: #"\"#)
        let ns = path as NSString
        return path.hasPrefix("/") && image.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)) != nil ? path : nil
    }

    static func placeholders(in text: String) -> Int {
        guard text.contains("[") else { return 0 }
        return placeholder.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func withoutPlaceholders(_ text: String) -> String {
        guard text.contains("[") else { return text }
        return placeholder.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }
}

/// Whether an agent's screen shows a message Nook just typed. Compared without whitespace,
/// since agents wrap long input across lines. A message with images is also recognised in the form Claude gives a pasted one
/// (`ClaudeImagePaste`): "[Image #N]" for each image, wherever Claude puts it, and the words.
enum MessageEcho {
    static func key(_ text: String) -> String { String(text.filter { !$0.isWhitespace }.prefix(40)) }

    /// What of a message shows in Claude's chat or record once it went as Claude attaches its images: its first 40 characters; for
    /// one with images, those of its words (the images show as "[Image #N]"), or the placeholder's own start when it has no words.
    /// Where Claude kept the paths as text (typed, or an image it couldn't read), `key` finds it.
    static func echoKey(_ text: String) -> String {
        let parts = ClaudeImagePaste.parts(text)
        guard !parts.images.isEmpty else { return key(text) }
        let words = key(parts.words)
        return words.count >= 3 ? words : "[Image#"
    }

    /// Whether the agent shows the message waiting to be sent: Claude in its box (long pastes show as
    /// a placeholder), Codex near the bottom of its screen.
    static func pending(_ text: String, in screen: String, agent: TerminalAgent) -> Bool {
        if agent == .claude {
            let split = ClaudeComposer.split(screen)
            if let input = split.input { return boxHolds(input, text) }
            // No box, but a dialog open: an option that is a text field ("Type something.") shows what was pasted
            // into it a few lines above the end. Without it the delivery would wait for an echo that never comes.
            guard AgentPrompt.parse(split.conversation) != nil else { return false }
            return key(text).count >= 3 && shows(text, inTheLast: 8, linesOf: screen)
        }
        // Codex shows a long paste as "[Pasted Content 1520 chars]" instead of its text.
        if screen.components(separatedBy: "\n").suffix(20).contains(where: { $0.contains("[Pasted Content") }) { return true }
        return shows(text, inTheLast: 20, linesOf: screen)
    }

    private static func shows(_ text: String, inTheLast count: Int, linesOf screen: String) -> Bool {
        let key = key(text)
        return !key.isEmpty && squeezed(screen.split(separator: "\n").suffix(count).joined()).contains(key)
    }

    /// The box ends with the whole message, alone or behind text already there. Never a fragment:
    /// a short message ("sí", "ok") is often part of the grey suggestion Claude shows next, and
    /// matching that sent extra Enters and left text in the box.
    static func boxHolds(_ box: String, _ text: String) -> Bool {
        if box.contains("[Pasted text") { return true }
        let message = squeezed(text)
        if !message.isEmpty && (squeezed(box).hasSuffix(message) || squeezed(box).hasSuffix(shellless(message))) { return true }
        return holdsImages(box, text)
    }

    /// The box shows a message with images as Claude turns a pasted one: an "[Image #N]" (wherever Claude put it) and the words at
    /// the end, or the images alone for a message without words. A box whose reading failed for some image holds fewer of them.
    private static func holdsImages(_ box: String, _ text: String) -> Bool {
        guard ClaudeImagePaste.placeholders(in: box) > 0 else { return false }
        let parts = ClaudeImagePaste.parts(text)
        return !parts.images.isEmpty && squeezed(ClaudeImagePaste.withoutPlaceholders(box)).hasSuffix(squeezed(parts.words))
    }

    /// A message for Claude's shell mode ("! git status") shows in its box without the "!", which became the box's mark.
    private static func shellless(_ message: String) -> String { message.hasPrefix("!") && message.count > 1 ? String(message.dropFirst()) : message }

    /// The box's text when something already typed there sits in front of the message ("t/usage").
    /// A grey suggestion disappears as soon as the message is pasted, so it never counts.
    static func joined(_ text: String, in screen: String) -> String? {
        guard let input = ClaudeComposer.split(screen).input, !input.contains("[Pasted text") else { return nil }
        // An image pasted with ⌃V sits in front as "[Image #1]"; it belongs with the message.
        let box = squeezed(ClaudeImagePaste.withoutPlaceholders(input)), message = squeezed(text)
        if !message.isEmpty && box.hasSuffix(message) && box != message { return input }
        // A message with images, as Claude shows a pasted one: its own images are no earlier text, but words in front of its words
        // are, and so are more images than it brought.
        let parts = ClaudeImagePaste.parts(text)
        guard !parts.images.isEmpty, holdsImages(input, text) else { return nil }
        return box != squeezed(parts.words) || ClaudeImagePaste.placeholders(in: input) > parts.images.count ? input : nil
    }

    /// Whether the message shows anywhere in `text`, however it was wrapped. One with images shows by its words (Claude's record keeps
    /// "[Image #1]" in their place); one that is only images by its placeholder, or by the record's "[Imagen]".
    static func appears(_ message: String, in text: String) -> Bool {
        let raw = key(message), key = echoKey(message), text = squeezed(text)
        guard !raw.isEmpty else { return false }
        return text.contains(raw) || text.contains(key) || key == "[Image#" && text.contains("[Imagen]")
    }

    /// How many times the message shows in the conversation above Claude's box (its echo "> …", "! …" in shell mode, or its
    /// grey copy while queued). One more than before the message went means Claude took it. nil without the box (a dialog's
    /// own rows, such as the answer typed into its field, are no echo) and for a message too short to tell.
    static func echoes(of text: String, inChatOf screen: String) -> Int? {
        let keys = Set([key(text), echoKey(text)]).filter { $0.count >= 3 }, split = ClaudeComposer.split(screen)
        guard !keys.isEmpty, split.input != nil else { return nil }
        // Either form of a message with images, whichever Claude showed: each count only grows with a new echo.
        let chat = squeezed(split.conversation)
        return keys.map { chat.components(separatedBy: $0).count - 1 }.max()
    }

    /// The box holds the start of the message and not yet all of it: Claude is still reading the typed keys, or has shown only part
    /// of a pasted message with images (its images without its words, or the words before their images).
    static func partial(_ box: String, of text: String) -> Bool {
        let squeezedBox = squeezed(box), message = squeezed(text)
        guard !squeezedBox.isEmpty else { return false }
        if squeezedBox != message && squeezedBox != shellless(message) && (message.hasPrefix(squeezedBox) || shellless(message).hasPrefix(squeezedBox)) { return true }
        let parts = ClaudeImagePaste.parts(text)
        guard !parts.images.isEmpty, !holdsImages(box, text) else { return false }
        let words = squeezed(parts.words), shown = squeezed(ClaudeImagePaste.withoutPlaceholders(box))
        return words.hasPrefix(shown) && (ClaudeImagePaste.placeholders(in: box) > 0 || !shown.isEmpty)
    }

    /// Whether the box holds exactly this message, however Claude wrapped it; one with images also as Claude shows it pasted, with
    /// as many "[Image #N]" as it has images. Not one that is only images: a placeholder doesn't say which image it stands for, and
    /// an "[Image #4]" left in the box would be sent in place of the new one.
    static func same(_ box: String, _ text: String) -> Bool {
        guard !box.contains("[Pasted text") else { return false }
        if !squeezed(text).isEmpty && squeezed(box) == squeezed(text) { return true }
        let parts = ClaudeImagePaste.parts(text), shown = ClaudeImagePaste.placeholders(in: box), words = squeezed(parts.words)
        return !parts.images.isEmpty && !words.isEmpty && shown == parts.images.count && squeezed(ClaudeImagePaste.withoutPlaceholders(box)) == words
    }

    private static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}

/// Keys that drive an agent's own menus: the real options always come from the session.
enum TerminalKey: String, CaseIterable, Identifiable {
    /// ⌃V asks Claude or Codex to paste the clipboard's image, as in their own terminal.
    /// ← and → switch the tabs of Claude's own panels (Settings: Status, Config, Usage).
    /// ⇧⇥ cycles Claude's permission mode (default, accept edits, plan, auto…); Nook's mode chip presses it, no key row shows it.
    /// "s" in Claude's model picker uses the highlighted model for this session only (Enter makes it the default); the model
    /// button presses it, no key row shows it.
    case up, down, tab, escape, enter, pasteImage, left, right, backtab, keyS
    /// The keys of the menu strip.
    static let menuKeys: [TerminalKey] = [.up, .down, .tab, .escape, .enter]
    /// The keys of a panel Claude draws instead of its box.
    static let panelKeys: [TerminalKey] = [.left, .right, .up, .down, .tab, .enter, .escape]
    var id: String { rawValue }
    var tmuxName: String {
        switch self {
        case .up: "Up"; case .down: "Down"; case .tab: "Tab"; case .escape: "Escape"; case .enter: "Enter"; case .pasteImage: "C-v"
        case .left: "Left"; case .right: "Right"; case .backtab: "BTab"; case .keyS: "s"
        }
    }
    var keyCode: CGKeyCode {
        switch self { case .up: 126; case .down: 125; case .tab, .backtab: 48; case .escape: 53; case .enter: 36; case .pasteImage: 9; case .left: 123; case .right: 124; case .keyS: 1 }
    }
    var modifiers: CGEventFlags {
        switch self { case .pasteImage: .maskControl; case .backtab: .maskShift; default: [] }
    }
    var symbol: String {
        switch self {
        case .up: "arrow.up"; case .down: "arrow.down"; case .tab: "arrow.right.to.line"; case .escape: "escape"; case .enter: "return"; case .pasteImage: "photo"
        case .left: "arrow.left"; case .right: "arrow.right"; case .backtab: "arrow.left.to.line"; case .keyS: "s.square"
        }
    }
    /// The escape symbol reads as "undo" at this size; the key's own name is clearer.
    var caption: String? { self == .escape ? "esc" : nil }
    var label: String {
        switch self {
        case .up: "Flecha arriba"; case .down: "Flecha abajo"; case .tab: "Tab"
        case .escape: "Escape"; case .enter: "Enter"; case .pasteImage: "Pegar imagen"
        case .left: "Flecha izquierda"; case .right: "Flecha derecha"; case .backtab: "Mayúsculas + Tab"; case .keyS: "S"
        }
    }
    /// Terminal's `do script` always appends Return, so only Enter can travel that way.
    var needsDirectKeys: Bool { self != .enter }
}

/// Hides Claude Code's own bottom input box from Nook's mirror. Only the presentation changes:
/// the original terminal and the raw history stay untouched. When in doubt, nothing is hidden.
/// Claude's spinner line ("✻ Churning… (1m 2s · esc to interrupt)") or its summary when done
/// ("Churned for 3m 58s · done 4:01 p.m."). Nook shows it beside the chat, not inside it.
struct ClaudeStatus: Equatable {
    var glyph: String?
    var text: String
    var working: Bool
    /// Claude's own turn is over and it waits for this many background agents before going on
    /// ("✻ Waiting for 3 background agents to finish"); nil for any other status.
    var background: Int?

    static let spinner: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    init(glyph: String?, text: String, working: Bool, background: Int? = nil) {
        self.glyph = glyph; self.text = text; self.working = working; self.background = background
    }

    /// Only lines at the left edge in Claude's exact shapes match; replies are indented.
    init?(line: String) {
        guard line.prefix(while: \.isWhitespace).count <= 1 else { return nil }
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        guard let first = rest.first, ClaudeStatus.spinner.contains(first) || first.isUppercase else { return nil }
        var glyph: String?
        if ClaudeStatus.spinner.contains(first), rest.dropFirst().first?.isWhitespace == true {
            glyph = String(first); rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        let body = String(rest)
        // The whole line must have the status shape: "Churning… (1m 2s · ↓ 3k tokens)" or "Churned for 3m 58s · done …".
        if glyph != nil, body.range(of: #"^\p{Lu}[\p{L}'-]*…(\s*\([^)]*\))?(\s+·\s+.*)?$"#, options: .regularExpression) != nil {
            self.init(glyph: glyph, text: body, working: true)
        } else if body.contains("ed for "), body.range(of: #"^\p{Lu}\p{Ll}+ed for( \d+(\.\d+)?[hms])+(\s+·\s+.*)?$"#, options: .regularExpression) != nil {
            self.init(glyph: glyph, text: body, working: false)
        } else if glyph != nil, let count = Self.backgroundWait(body) {
            // The turn is not over: Claude goes on once its agents report back.
            self.init(glyph: glyph, text: body, working: true, background: count)
        } else { return nil }
    }

    private static let waiting = try! NSRegularExpression(pattern: #"^Waiting for (\d+) background (?:agents?|tasks?|jobs?) to finish…?(\s*\([^)]*\))?(\s+·\s+.*)?$"#)

    /// "Waiting for 1 background agent to finish" → 1.
    static func backgroundWait(_ body: String) -> Int? {
        let ns = body as NSString
        guard let match = waiting.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }
}

/// Claude's reasoning effort, as `/effort` names its levels. Which levels a model takes depends on the model; Claude itself
/// answers when one isn't available.
enum ClaudeEffort: String, CaseIterable {
    case low, medium, high, xhigh, max

    /// Sets it without Claude's slider: the command with the level.
    var command: String { "/effort " + rawValue }

    private static let report = try! NSRegularExpression(pattern: #"thinking(?: \w+)? with (\w+) effort|[Ss]et effort level to (\w+)|(?:Opus|Sonnet|Haiku|Fable) [\d.]+ with (\w+) effort"#)

    /// The level Claude last reported on screen: its spinner while it thinks ("thinking with max effort"), its answer to
    /// /effort ("Set effort level to xhigh") or its banner ("Sonnet 5.5 with xhigh effort"). The newest wins; nil when the
    /// screen says none of them.
    static func reported(in text: String) -> ClaudeEffort? {
        let ns = text as NSString
        for match in report.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let group = (1...3).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { continue }
            if let effort = ClaudeEffort(rawValue: ns.substring(with: group)) { return effort }
        }
        return nil
    }
}

/// What Nook reads from a Claude screen: the chat to mirror and the pieces shown elsewhere.
struct ClaudeScreen: Equatable {
    var conversation: String
    var input: String?
    var status: ClaudeStatus?
    var recap: String?
    /// Rows of the agent's own command menu, shown under its box while "/" is being typed there.
    var menu: [SlashCommand] = []
    /// A panel Claude draws instead of its box (/usage, /status, /config, /mcp, a skills list…), as
    /// the screen shows it; nil while the box is there.
    var panel: String?
    /// Claude's welcome banner (version, model, effort, plan, folder), the newest on screen. Never part of the chat.
    var banner: ClaudeBanner?
    /// The warnings Claude printed as that session started, once each. Never part of the chat.
    var warnings: [ClaudeStartupWarning] = []
    /// The mode named under Claude's box ("auto mode on"); nil in the default mode or without a box.
    var mode: ClaudeMode?
}

/// Claude Code's welcome banner, drawn beside its logo when a session starts:
///
///     ▗ ▗   ▖ ▖  Claude Code v2.1.290
///                Sonnet 5.5 with xhigh effort · Claude Team
///      ▘▘   ▝▝   ~/Documents/crm
struct ClaudeBanner: Equatable {
    var version: String
    /// "Sonnet 5.5".
    var model: String?
    /// The level word as Claude writes it ("xhigh"); `ClaudeEffort(rawValue:)` reads the known ones.
    var effort: String?
    /// "Claude Team", "Claude Max", "API Usage Billing"…
    var plan: String?
    /// The working folder as Claude shows it ("~/Documents/crm").
    var directory: String?
}

extension ClaudeBanner {
    /// The model Claude's answer to /model names, under the command on screen: "  ⎿  Set model to Sonnet 5.5 and saved as your
    /// default for new sessions", "  ⎿  Kept model as Opus 5.5", "  ⎿  Set model to Sonnet 4.6". Its record keeps the same words
    /// with the name in backticks (`<local-command-stdout>Set model to `Fable 5.1` and saved…`), so those go too.
    static func modelChange(in line: String) -> (model: String, effort: String?)? {
        guard line.contains(" model "), let mark = line.firstIndex(of: "⎿"), line[..<mark].allSatisfy(\.isWhitespace) else { return nil }
        var rest = line[line.index(after: mark)...].trimmingCharacters(in: .whitespaces)
        guard let lead = ["Set model to ", "Kept model as "].first(where: { rest.hasPrefix($0) }) else { return nil }
        // Older versions bolded the name with escapes (`\u{1b}[1mOpus 5\u{1b}[22m`) in the record; the screen has none.
        rest = String(rest.dropFirst(lead.count)).replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
        // The effort may come after the name or at the very end: "… and saved as your default for new sessions with max effort".
        var effort: String?
        if let range = rest.range(of: #" with \w+ effort"#, options: .regularExpression) {
            effort = rest[range].split(separator: " ").dropFirst().first.map(String.init)
            rest.removeSubrange(range)
        }
        if let saved = rest.range(of: " and saved") { rest = String(rest[..<saved.lowerBound]) }
        // A choice for this session only ("s" in the picker) says so after the name, as /effort does ("(this session only)").
        rest = rest.replacingOccurrences(of: #"\s*(\((for )?this session( only)?\)|for this session( only)?)\s*[.:]?.*$"#, with: "", options: .regularExpression)
        rest = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return rest.contains(where: \.isLetter) ? (rest, effort) : nil
    }
}

/// A warning Claude prints as it starts, such as a permission rule it flags in a settings file:
/// "Permission allow rule (.claude/settings.json): Bash(pnpm --filter * exec prisma format*) has a wildcard before…".
struct ClaudeStartupWarning: Equatable, Hashable {
    /// The settings file it names (".claude/settings.json"), when it names one.
    var source: String?
    /// The whole warning on one line.
    var text: String
}

/// Claude's mode line under its box: "⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage". In the default
/// mode Claude draws no such line; `ClaudeMode.standard` stands for it.
struct ClaudeMode: Equatable {
    enum Kind: String { case auto, acceptEdits, plan, bypassPermissions }
    /// nil for the default mode (`isDefault`) and for a mode Nook doesn't know by name, which `label` still says.
    var kind: Kind?
    /// "auto mode on"; empty in the default mode, which Claude doesn't name.
    var label: String
    /// The key hints after it, as Claude words them: "shift+tab to cycle", "← for agents", "↓ to manage".
    var hints: [String]

    /// Only Claude's own shape counts: its mode glyph (⏵⏵, ⏸) or the "shift+tab to cycle" hint, and a mode that is on.
    static func parse(_ line: String) -> ClaudeMode? {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        let glyphs: Set<Character> = ["⏵", "⏸", "⏴", "▶", "⏯"]
        let marked = text.first.map(glyphs.contains) ?? false
        text = text.drop { glyphs.contains($0) || $0.isWhitespace }
        guard marked || text.lowercased().contains("shift+tab to cycle") else { return nil }
        var segments = text.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !segments.isEmpty else { return nil }
        var label = segments.removeFirst(), hints: [String] = []
        // "auto mode on (shift+tab to cycle)": the parenthesis is a hint of its own.
        if let open = label.lastIndex(of: "("), label.hasSuffix(")") {
            hints.append(String(label[label.index(after: open)..<label.index(before: label.endIndex)]))
            label = label[..<open].trimmingCharacters(in: .whitespaces)
        }
        let lower = label.lowercased()
        guard lower.hasSuffix(" on") || lower.contains("mode") else { return nil }
        let kind: Kind? = lower.contains("auto mode") ? .auto : lower.contains("accept edits") ? .acceptEdits
            : lower.contains("plan mode") ? .plan : lower.contains("bypass permissions") ? .bypassPermissions : nil
        return ClaudeMode(kind: kind, label: label, hints: hints + segments)
    }

    /// The default mode: the box is there and nothing under it names a mode. ⇧⇥ cycles from it like from any other.
    static let standard = ClaudeMode(kind: nil, label: "", hints: [])
    var isDefault: Bool { kind == nil && label.isEmpty }

    /// What the lines under the box say about the mode: its line, the default mode when they are only Claude's quiet footer
    /// ("? for shortcuts", the context left…), or nil when something else stands there (the "/" menu, a passing hint) and the
    /// mode can't be told.
    static func read(under lines: [String]) -> ClaudeMode? {
        let shown = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let named = shown.lazy.compactMap(parse).first { return named }
        // A mode named in a shape Nook doesn't read is still a mode, not the default.
        if shown.contains(where: { line in ["mode on", "edits on", "permissions on"].contains { line.lowercased().contains($0) } }) { return nil }
        return shown.allSatisfy(ClaudeComposer.isFooterLine) ? standard : nil
    }
}

/// What Claude prints as a session starts: its banner, and the warnings before it. Nook shows them apart from the chat.
enum ClaudeStartup {
    private static let firstLine = try! NSRegularExpression(pattern: #"^([\s\x{2580}-\x{259F}]*)Claude Code v(\d[\w.+-]*)\s*$"#)
    private static let warningStart = try! NSRegularExpression(pattern: #"^\s{0,2}(?:⚠\s*)?Permission (?:allow|deny|ask) rule \(([^)]*)\):\s"#)
    private static func isLogo(_ c: Character) -> Bool {
        c.isWhitespace || c.unicodeScalars.allSatisfy { (0x2580...0x259F).contains($0.value) }
    }

    /// The banner starting at `index`, and how many lines it takes.
    static func banner(at index: Int, in lines: [String]) -> (banner: ClaudeBanner, count: Int)? {
        let line = lines[index], ns = line as NSString
        guard line.contains("Claude Code v"), let match = firstLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var banner = ClaudeBanner(version: ns.substring(with: match.range(at: 2)))
        let column = (ns.substring(with: match.range(at: 1)) as String).count
        // The next lines carry text in the same column, after the rest of the logo (or blanks).
        func text(_ offset: Int) -> String? {
            guard index + offset < lines.count else { return nil }
            let next = lines[index + offset]
            guard next.prefix(column).allSatisfy(isLogo) else { return nil }
            let rest = next.dropFirst(column).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        var count = 1
        if let details = text(1), details.range(of: #"^(Opus|Sonnet|Haiku|Fable|Claude|claude-)|\swith \w+ effort|\s·\s"#, options: .regularExpression) != nil {
            var parts = details.components(separatedBy: " · ")
            let model = parts.removeFirst()
            if let effort = model.range(of: #" with (\w+) effort$"#, options: .regularExpression) {
                banner.model = String(model[..<effort.lowerBound])
                banner.effort = model[effort].replacingOccurrences(of: " with ", with: "").replacingOccurrences(of: " effort", with: "")
            } else { banner.model = model }
            banner.plan = parts.isEmpty ? nil : parts.joined(separator: " · ")
            count = 2
            if let folder = text(2), folder.hasPrefix("~") || folder.hasPrefix("/") { banner.directory = folder; count = 3 }
        } else if let folder = text(1), folder.hasPrefix("~") || folder.hasPrefix("/") { banner.directory = folder; count = 2 }
        return (banner, count)
    }

    /// The warning a line starts, if it starts one.
    static func warning(startingAt line: String) -> ClaudeStartupWarning? {
        let ns = line as NSString
        guard line.contains("Permission"), let match = warningStart.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        return ClaudeStartupWarning(source: ns.substring(with: match.range(at: 1)), text: text.hasPrefix("⚠") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text)
    }

    /// The newest banner in `earlier` (what slid out of Terminal's window) and its warnings, as `read` would find them in
    /// `earlier + text` when `text` (the window) shows none. Only a few lines around each "Claude Code v" are read, newest first, not
    /// the whole 240,000 characters; the window's first lines join `earlier`'s end, where Terminal cut a line in two.
    static func newest(in earlier: String, before text: String, context: Int = 200) -> (banner: ClaudeBanner, warnings: [ClaudeStartupWarning])? {
        let ns = earlier as NSString
        var end = ns.length
        func lineStart(_ location: Int) -> Int {
            let newline = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location))
            return newline.location == NSNotFound ? 0 : newline.location + 1
        }
        // A conversation about Claude Code may name it often: a mention after anything but the logo is passed over at once.
        for _ in 0..<1_000 where end > 0 {
            let found = ns.range(of: "Claude Code v", options: .backwards, range: NSRange(location: 0, length: end))
            guard found.location != NSNotFound else { return nil }
            let line = lineStart(found.location)
            guard ns.substring(with: NSRange(location: line, length: found.location - line)).allSatisfy(isLogo) else { end = line; continue }
            // `context` lines above it, where its warnings are, and the banner's own lines below.
            var start = line
            for _ in 0..<context where start > 0 { start = lineStart(start - 1) }
            var stop = NSMaxRange(found), below = 0
            while below < 4, stop < ns.length {
                let newline = ns.range(of: "\n", range: NSRange(location: stop, length: ns.length - stop))
                if newline.location == NSNotFound { stop = ns.length; break }
                stop = newline.location + 1; below += 1
            }
            var window = ns.substring(with: NSRange(location: start, length: stop - start))
            if stop == ns.length { window += text.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false).prefix(4).joined(separator: "\n") }
            let read = read(window.components(separatedBy: "\n"))
            if let banner = read.banner { return (banner, read.warnings) }
            end = line
        }
        return nil
    }

    /// A banner Claude printed as a session started, at the left edge of the screen: a reply that quotes one is indented.
    static func startsSession(_ line: String) -> Bool { line.prefix(while: \.isWhitespace).count <= 1 }

    /// `text` from the newest banner that started a session on (`startsSession`), or all of it when it shows none. Only the lines
    /// that hold "Claude Code v" are looked at, newest first.
    static func sinceNewestBanner(_ text: String) -> Substring {
        var end = text.endIndex
        while let found = text.range(of: "Claude Code v", options: .backwards, range: text.startIndex..<end) {
            let start = text[..<found.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
            let stop = text[found.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[start..<stop])
            if startsSession(line), banner(at: 0, in: [line]) != nil { return text[start...] }
            end = start
        }
        return text[...]
    }

    /// The lines after the newest banner that started a session, without banners and their warnings, plus that banner and its
    /// session's warnings. What came before that banner belongs to whatever ran in the tab earlier (the shell and the command
    /// that started Claude, an earlier Claude): it is not this conversation, so it goes. A resumed conversation is printed after
    /// the banner and stays; /clear prints a new banner and starts afresh. A warning counts only when nothing but blank lines and
    /// other warnings separate it from the banner after it. The blank lines between them (Claude clears a stretch of screen
    /// before its banner) go too.
    static func read(_ lines: [String]) -> (lines: [String], banner: ClaudeBanner?, warnings: [ClaudeStartupWarning]) {
        guard lines.contains(where: { $0.contains("Claude Code v") }) else { return (lines, nil, []) }
        var kept: [String] = [], pending: [String] = [], pendingWarnings: [ClaudeStartupWarning] = []
        var banner: ClaudeBanner?, warnings: [ClaudeStartupWarning] = [], started = false
        var index = 0
        // Lines held back while a run of warnings and blanks might lead to a banner.
        func release() { kept += pending; pending = []; pendingWarnings = [] }
        while index < lines.count {
            let line = lines[index]
            if let found = Self.banner(at: index, in: lines) {
                banner = found.banner
                var unique: [ClaudeStartupWarning] = []
                for warning in pendingWarnings where !unique.contains(warning) { unique.append(warning) }
                warnings = unique
                // The run of warnings and the banner go; so does everything above a banner that started a session. One quoted
                // in a reply only leaves the chat (the blank lines before it stay).
                pending = []; pendingWarnings = []
                if startsSession(line) { kept = []; started = true }
                index += found.count
                continue
            }
            if var warning = Self.warning(startingAt: line) {
                if pendingWarnings.isEmpty { release() }
                pending.append(line)
                // A warning wrapped onto more lines continues until a blank line or the next warning.
                var next = index + 1
                while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).isEmpty,
                      Self.warning(startingAt: lines[next]) == nil, Self.banner(at: next, in: lines) == nil {
                    warning.text += " " + lines[next].trimmingCharacters(in: .whitespaces)
                    pending.append(lines[next]); next += 1
                }
                pendingWarnings.append(warning)
                index = next
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty, !pendingWarnings.isEmpty { pending.append(line) }
            // The blank lines between a session's banner and its conversation.
            else if started, kept.isEmpty, pending.isEmpty, line.trimmingCharacters(in: .whitespaces).isEmpty {}
            else {
                release(); kept.append(line)
                // Claude's answer to /model: the banner keeps the model in use, not the one the session started with.
                if banner != nil, let change = ClaudeBanner.modelChange(in: line) {
                    banner?.model = change.model
                    if let effort = change.effort { banner?.effort = effort }
                }
            }
            index += 1
        }
        release()
        return (kept, banner, warnings)
    }
}

/// Whether a Claude conversation (its record as Nook renders it, or the chat of its screen) has begun: a line at the edge that is
/// the user's turn ("> …", "❯ …", "! …" in shell mode) or Claude's ("⏺ …"). Claude's notices after its banner ("▎ Using Sonnet 5.5
/// (from .claude/settings.json)", tips) are neither; replies and what they quote are indented.
enum ClaudeExchange {
    static func begun(_ conversation: String) -> Bool {
        var found = false
        conversation.enumerateLines { line, stop in
            guard line.prefix(while: \.isWhitespace).count <= 1 else { return }
            let text = line.drop(while: \.isWhitespace)
            // By scalar, so "⏺️" (with its emoji selector) is "⏺"; other platforms draw "●".
            guard let mark = text.unicodeScalars.first else { return }
            switch mark {
            case "⏺", "●": found = true
            case "❯", ">", "!": found = text.dropFirst().first?.isWhitespace == true && !text.dropFirst().allSatisfy(\.isWhitespace)
            default: break
            }
            if found { stop = true }
        }
        return found
    }
}

/// Claude's settings commands and its answers to them, as Daniel's records hold them (Claude Code 2.1.223–2.1.291):
/// "/effort max" → "Set effort level to max (this session only): Maximum capability…", "/model" → "Set model to `Sonnet 5.5` and
/// saved as your default for new sessions", "Kept model as `Opus 5.5`", or "Cancelled" when the picker closed with Esc. Nook's
/// chips and banner show that state, so a round trip that worked never shows in the chat; an error or any other answer stays,
/// with its command, and so does every other command. ⇧⇥ (the mode) is a key and leaves nothing in the chat.
enum ClaudeSettingsEcho {
    /// "/effort", "/effort high", "/model sonnet": a slash, one of the two names, then arguments or nothing.
    static func isCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^/(effort|model)(\s.*)?$"#, options: .regularExpression) != nil
    }

    /// Claude's answer when the command worked (older versions bold the name with escapes, which don't change the start).
    static func isConfirmation(_ answer: String) -> Bool {
        let text = answer.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "Cancelled" || ["Set effort level to ", "Set model to ", "Kept model as "].contains { text.hasPrefix($0) }
    }

    /// The screen's lines without those round trips: the echo ("> /effort high", "❯ /model sonnet" at the edge), Claude's "⎿"
    /// answer under it with the lines it wraps onto, and the blank line that separated it from what follows.
    static func strip(_ lines: [String]) -> [String] {
        guard lines.contains(where: { $0.contains("/effort") || $0.contains("/model") }) else { return lines }
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        var index = 0
        while index < lines.count {
            guard let end = roundTrip(at: index, in: lines) else { kept.append(lines[index]); index += 1; continue }
            index = end
            if index < lines.count, blank(lines[index]), kept.last.map(blank) ?? true { index += 1 }
        }
        return kept
    }

    private static func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Where a round trip that starts at `index` ends (the line after it), or nil when none starts there.
    private static func roundTrip(at index: Int, in lines: [String]) -> Int? {
        let line = lines[index]
        guard line.prefix(while: \.isWhitespace).count <= 1 else { return nil }
        let text = Substring(line.trimmingCharacters(in: .whitespaces))
        guard let mark = text.first, mark == ">" || mark == "❯", text.dropFirst().first == " ", isCommand(String(text.dropFirst(2))) else { return nil }
        var next = index + 1
        while next < lines.count, next - index <= 2, blank(lines[next]) { next += 1 }
        guard next < lines.count else { return nil }
        let answer = lines[next].trimmingCharacters(in: .whitespaces)
        guard answer.hasPrefix("⎿"), isConfirmation(String(answer.dropFirst())) else { return nil }
        next += 1
        // A long answer ("…May use excessive tokens…") wraps onto lines indented under it.
        while next < lines.count, lines[next].prefix(while: \.isWhitespace).count >= 3, !blank(lines[next]),
              !lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("⎿") { next += 1 }
        return next
    }
}

/// The list of agents Claude draws at the very bottom of its screen while background agents run:
///
///       ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage
///
///       ⏺ main
///       ○ fork  Reading NotchController expand and keepIslandWithTerminal
///     4m 56s · ↓ 187.3k tokens
///
/// Its right-aligned times wrap to the left edge in a narrow pane. With the list focused (↓ to manage) the rows gain "❯" marks
/// and "↑/↓ to select" replaces the mode line. Nook lists agents itself; the chat never shows this.
///
/// This is the one place that recognises the list: the chat drops `range(in:)`, and `AgentActivity` reads the agents from the
/// same range (`AgentActivity.tree`), so the two never disagree on what is the list.
enum ClaudeAgentTree {
    static func isMainRow(_ line: String) -> Bool {
        guard line.prefix(while: \.isWhitespace).count <= 4 else { return false }
        // Terminal may hand "⏺" back with its emoji selector ("⏺️"), and other platforms draw "●".
        var text = Substring(line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FE0F}", with: ""))
        if text.first == "❯" { text = text.dropFirst().drop(while: \.isWhitespace) }
        return text == "⏺ main" || text == "● main"
    }

    /// From the list's first line (its "↑/↓ to select" hint when focused) to the end of the screen. Only a list right under
    /// Claude's box (its rule or mode line) counts, so a reply that happens to read "⏺ main" stays.
    static func range(in lines: [String]) -> Range<Int>? {
        let floor = max(0, lines.count - 80)
        guard let main = (floor..<lines.count).reversed().first(where: { isMainRow(lines[$0]) }) else { return nil }
        var above = main - 1
        while above >= 0, lines[above].trimmingCharacters(in: .whitespaces).isEmpty { above -= 1 }
        guard above >= 0 else { return nil }
        let previous = lines[above]
        if ClaudeComposer.isRule(previous) || ClaudeComposer.isFooterLine(previous) && !isSelectHint(previous) { return main..<lines.count }
        if isSelectHint(previous) { return above..<lines.count }
        return nil
    }

    /// "↑/↓ to select", shown above the list while it has the keys.
    static func isSelectHint(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        return text.count < 60 && (text.hasPrefix("↑/↓") || text.hasPrefix("↑↓")) && text.contains("select")
    }
}

/// Claude's session recap ("※ recap: …"), shown by Nook beside the chat. Wrapped text continues on indented lines.
enum ClaudeRecap {
    static func start(_ line: String) -> String? {
        let indent = line.prefix(while: \.isWhitespace).count
        guard indent <= 2 else { return nil }
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        let marked = rest.first == "※"
        if marked { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        // Without its mark only a line at the left edge counts; replies are indented.
        guard rest.lowercased().hasPrefix("recap:"), marked || indent <= 1 else { return nil }
        return rest.dropFirst(6).trimmingCharacters(in: .whitespaces)
    }

    static func continues(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return line.prefix(while: \.isWhitespace).count >= 2 && !text.isEmpty && !text.hasPrefix("⎿")
    }
}

enum ClaudeComposer {
    /// The mirror without Claude's box, status and recap lines, plus what the box shows (nil when no
    /// box is on screen): Claude's grey suggestion or text typed in the terminal, which plain text can't
    /// tell apart. Nook shows it in its own field instead.
    static func split(_ text: String) -> ClaudeScreen {
        // The banner and its warnings, and the agent list under the box, are never chat.
        let startup = ClaudeStartup.read(text.components(separatedBy: "\n"))
        var source = startup.lines
        if let tree = ClaudeAgentTree.range(in: source) { source.removeSubrange(tree) }
        // Settings commands that worked show in the chips, not in the chat (their answers already updated the banner above).
        source = ClaudeSettingsEcho.strip(source)
        var status: ClaudeStatus?
        var recap: String?
        var recapLines: [String]?
        var lines: [String] = []
        for line in source {
            if let collected = recapLines {
                if collected.count < 12, ClaudeRecap.continues(line) { recapLines = collected + [line.trimmingCharacters(in: .whitespaces)]; continue }
                recap = collected.joined(separator: " "); recapLines = nil
            }
            if let found = ClaudeStatus(line: line) { status = found }
            else if let start = ClaudeRecap.start(line) { recapLines = [start] }
            else { lines.append(line) }
        }
        if let collected = recapLines { recap = collected.joined(separator: " ") }
        let (conversation, input, menu) = composer(lines)
        // The mode line sits under the box; without a box there's no telling.
        let mode = input == nil ? lines.suffix(12).reversed().lazy.compactMap(ClaudeMode.parse).first : underBox(lines).flatMap(ClaudeMode.read(under:))
        return ClaudeScreen(conversation: conversation, input: input, status: status, recap: recap.flatMap { $0.isEmpty ? nil : $0 }, menu: menu,
                            panel: input == nil ? panel(lines) : nil, banner: startup.banner, warnings: startup.warnings, mode: mode)
    }

    /// The panel at the end of a screen without Claude's box: it ends with a key hint ("Esc to cancel",
    /// "←/→ to switch") and starts at its top border, or right after the conversation's last
    /// reply or prompt. Without such a hint there is no panel: a screen caught mid-redraw stays as is.
    static func panel(_ lines: [String]) -> String? {
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let floor = max(0, last - 60)
        // Claude's Settings (/status, /config, /usage, /stats) fill the screen under a rule with their
        // tab row; their key hint is often scrolled out of view (a "↓" marks the rest). The rule may be
        // drawn with block characters ("▔▔▔"), and the row alone counts when it opens the screen.
        if let row = (floor...last).first(where: { isTabRow(lines[$0]) }) {
            let rule = (max(floor, row - 3)..<row).reversed().first { isRule(lines[$0]) || isBlockRule(lines[$0]) }
            // Without an edge, only a row with no conversation above it (a status line at most) opens a panel.
            let above = lines[floor..<row].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let opensScreen = above.count <= 2 && !above.contains { $0.hasPrefix("⏺") || $0.hasPrefix("> ") || $0.hasPrefix("❯") }
            if let start = rule ?? (opensScreen ? row : nil) { return lines[start...last].joined(separator: "\n") }
        } else if let row = tallTabRow(lines, floor: floor, last: last) {
            // A terminal taller than the window: the Settings fill it from further up, under their edge.
            if let start = (max(0, row - 3)..<row).reversed().first(where: { isRule(lines[$0]) || isBlockRule(lines[$0]) }) ?? (row < 3 ? row : nil) {
                return lines[start...last].joined(separator: "\n")
            }
        }
        let tail = lines[...last].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(4)
        // Claude's mode line under its box ("shift+tab to cycle") reads like a hint, but it is no panel's.
        guard tail.contains(where: { isPanelHint($0) && !isFooterLine($0) }) else { return nil }
        // The conversation ends at the last reply or prompt drawn at the edge.
        let stop = (floor...last).reversed().first { index in
            let line = lines[index]
            return atEdge(line) && (line.hasPrefix("⏺") || line.hasPrefix("> ") || line.hasPrefix("❯ "))
        }
        // An agent's numbered dialog, which its card answers, is no conversation's end: what follows its highlighted option is the
        // rest of the dialog, never a panel. Claude's question with a preview beside its options read as a panel of "Chat about
        // this" and its key hint.
        if let stop, endsInDialog(lines, at: stop, floor: floor) { return nil }
        let start = stop.map { $0 + 1 } ?? floor
        guard start <= last else { return nil }
        // Its top border, when it has one, is where it begins.
        let top = (start...last).first { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("╭") || trimmed.hasPrefix("┌") || isRule(lines[index])
        } ?? start
        let body = lines[top...last].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return body.isEmpty ? nil : body.joined(separator: "\n")
    }

    /// Whether the line `panel` took for the conversation's last prompt is a dialog's instead: its highlighted numbered option at
    /// the edge ("❯ 1. Yes", which `isPrompt` keeps apart from the input line the same way), or a row the dialog highlights under
    /// its options ("❯ Chat about this", the option above it keeping its own mark) with such an option above it before any reply.
    private static func endsInDialog(_ lines: [String], at stop: Int, floor: Int) -> Bool {
        if isHighlightedOption(lines[stop]) { return true }
        guard lines[stop].hasPrefix("❯ ") else { return false }
        var index = stop - 1
        while index >= max(floor, stop - 40) {
            let line = lines[index]
            if isHighlightedOption(line) { return true }
            if atEdge(line) && (line.hasPrefix("⏺") || line.hasPrefix("> ") || line.hasPrefix("❯ ")) { return false }
            index -= 1
        }
        return false
    }

    /// How far above the window `panel` looks for the tab row of Settings drawn in a tall terminal: a screen of 400 rows.
    static let tallestPanel = 400

    /// The tab row of Claude's Settings above the window `panel` reads, in a terminal taller than it (about 62 rows): going up
    /// from the window while the lines are still the panel's, at most `tallestPanel` lines. A reply or a prompt drawn at the edge
    /// ends the panel, in the window or above it: a tab row past it is an old one, from before the conversation went on. Only a
    /// line short enough and with gaps in it is looked at closely, so a long screen costs little.
    private static func tallTabRow(_ lines: [String], floor: Int, last: Int) -> Int? {
        guard floor > 0, !(floor...last).contains(where: { conversationLine(lines[$0]) }) else { return nil }
        var index = floor - 1
        let limit = max(0, last - tallestPanel)
        while index >= limit {
            let line = lines[index]
            if conversationLine(line) { return nil }
            if line.utf16.count <= 160, line.contains("  "), isTabRow(line) { return index }
            index -= 1
        }
        return nil
    }

    /// A reply or a prompt drawn at the edge: the conversation, which no panel holds.
    private static func conversationLine(_ line: String) -> Bool {
        atEdge(line) && (line.hasPrefix("⏺") || line.hasPrefix("> ") || line.hasPrefix("❯ "))
    }

    /// A full-width line of block characters ("▔▔▔▔", "▁▁▁▁"), as Claude draws some panels' edges.
    static func isBlockRule(_ line: String) -> Bool {
        guard line.prefix(while: \.isWhitespace).count <= 1 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let blocks: Set<Character> = ["▔", "▁", "▀", "▄", "─", "━", "═"]
        return trimmed.count >= 20 && Double(trimmed.filter { blocks.contains($0) }.count) / Double(trimmed.count) >= 0.75
    }

    /// A row of tab names: three to eight short capitalised words two or more spaces apart
    /// ("Settings  Status   Config   Usage   Stats").
    static func isTabRow(_ line: String) -> Bool {
        guard line.prefix(while: \.isWhitespace).count <= 4 else { return false }
        let words = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (3...8).contains(words.count) && words.allSatisfy { $0.count <= 14 && $0.first?.isUppercase == true && !$0.contains(" ") }
    }

    static func isPanelHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["esc to", "enter to", "tab to", "to cycle", "to close", "to cancel", "to go back", "to navigate", "to select", "to confirm",
                "to switch", "to exit", "←/→", "← →", "↑/↓", "↑↓"].contains { lower.contains($0) }
    }

    /// The lines under the box's bottom rule, or nil without one near the end.
    static func underBox(_ lines: [String]) -> [String]? {
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let bottom = (max(0, last - 24)...last).reversed().first(where: { isRule(lines[$0]) }) else { return nil }
        return Array(lines[(bottom + 1)...])
    }

    private static func composer(_ source: [String]) -> (conversation: String, input: String?, menu: [SlashCommand]) {
        var lines = source
        func blank(_ index: Int) -> Bool { lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
        guard let last = lines.indices.last(where: { !blank($0) }) else { return (source.joined(separator: "\n"), nil, []) }
        // The composer is the last box on screen; suggestions or a short status line may follow it.
        guard let bottom = (max(0, last - 24)...last).reversed().first(where: { isRule(lines[$0]) }), bottom > 0,
              let top = (max(0, bottom - 40)..<bottom).reversed().first(where: { isRule(lines[$0]) }),
              top + 1 < bottom, isPrompt(lines[top + 1]) else { return (source.joined(separator: "\n"), nil, []) }
        let inputLines = Array(lines[(top + 1)..<bottom])
        let below = lines[(bottom + 1)..<(last + 1)].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // A selector drawn between rules ("❯ Opus", "Sonnet", "Enter to confirm · Esc to exit") is a
        // dialog, not the input box: it stays whole.
        if (inputLines + below).contains(where: isDialogHint) { return (source.joined(separator: "\n"), nil, []) }
        let menu = SlashCatalog.menu(below)
        let input = typed(inputLines)
        // Only Claude's own status line under the box is dropped. Anything not recognised (an error,
        // suggestions, a menu's instructions) stays visible.
        let keepsBelow = !below.allSatisfy(isFooterLine)
        var start = top
        var probe = top - 1
        while probe >= 0, blank(probe) || isNotice(lines[probe]) {
            if !blank(probe) { start = probe }
            probe -= 1
        }
        lines.removeSubrange(keepsBelow ? start...bottom : start...(lines.count - 1))
        while let final = lines.last, final.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (lines.joined(separator: "\n"), input, menu)
    }

    static func conversation(_ text: String) -> String { split(text).conversation }

    /// The box's text without the prompt mark and borders. Plain text can't tell Claude's grey
    /// suggestion from typed text, so nothing is discarded: Nook shows it in its own field.
    private static func typed(_ lines: [String]) -> String {
        let text = lines.enumerated().map { index, line -> String in
            var rest = Substring(line.trimmingCharacters(in: .whitespaces))
            if rest.first == "│" { rest = rest.dropFirst() }
            if rest.last == "│" { rest = rest.dropLast() }
            rest = rest.drop(while: \.isWhitespace)
            if index == 0, let mark = rest.first, ["❯", ">", "!"].contains(mark) { rest = rest.dropFirst() }
            return rest.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static let horizontal: Set<Character> = ["─", "━", "═", "╌", "┄"]
    private static let corners: Set<Character> = ["╭", "╮", "╰", "╯", "┌", "┐", "└", "┘"]

    /// Claude indents its replies; its input box starts at the left edge. This keeps rules and
    /// quotes inside replies (and code blocks with separators) out of the match.
    private static func atEdge(_ line: String) -> Bool { line.prefix(while: \.isWhitespace).count <= 1 }

    static func isRule(_ line: String) -> Bool {
        guard atEdge(line) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20, let first = trimmed.first, let end = trimmed.last,
              horizontal.contains(first) || corners.contains(first), horizontal.contains(end) || corners.contains(end) else { return false }
        // A short label inside the rule is fine; text with a few dashes is not a rule.
        let drawn = trimmed.filter { horizontal.contains($0) || corners.contains($0) }.count
        return Double(drawn) / Double(trimmed.count) >= 0.75 || isLabelledRule(trimmed)
    }

    /// Claude names the session in its box's top rule ("──────── ui-designer ─"). In a narrow terminal, or with a long name, the
    /// label outweighs the dashes, yet the shape is unmistakable: dashes, one label padded with spaces, dashes.
    private static func isLabelledRule(_ trimmed: String) -> Bool {
        let drawn = { (c: Character) in horizontal.contains(c) || corners.contains(c) }
        let lead = trimmed.prefix(while: drawn), tail = trimmed.reversed().prefix(while: drawn)
        guard lead.count >= 3, !tail.isEmpty, lead.count + tail.count < trimmed.count else { return false }
        let label = trimmed.dropFirst(lead.count).dropLast(tail.count)
        return label.first == " " && label.last == " " && !label.contains(where: drawn) && !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func isPrompt(_ line: String) -> Bool {
        guard atEdge(line) else { return false }
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.first == "│" { text = text.dropFirst().drop(while: { $0 == " " }) }
        guard let mark = text.first, ["❯", ">", "!"].contains(mark) else { return false }
        let rest = text.dropFirst()
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return false }
        // "❯ 1. Yes" is a highlighted option in a dialog, never the input line.
        return !isNumbered(rest)
    }

    /// "❯ 1. Yes" at the edge: the highlighted option of an agent's numbered dialog.
    static func isHighlightedOption(_ line: String) -> Bool {
        guard atEdge(line) else { return false }
        let text = Substring(line.trimmingCharacters(in: .whitespaces))
        guard text.first == "❯", text.dropFirst().first?.isWhitespace == true else { return false }
        return isNumbered(text.dropFirst())
    }

    private static func isNumbered(_ rest: Substring) -> Bool {
        rest.drop(while: \.isWhitespace).range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    /// Claude's mode line under the box ("⏵⏵ auto mode on (shift+tab to cycle) · 1 background · ← for agents").
    static func isFooterLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["shift+tab", "⏵⏵", "⏸", "for shortcuts", "auto mode", "accept edits", "plan mode", "bypass permissions",
                "for agents", "auto-compact", "context left", "background"].contains { lower.contains($0) }
            // The row a status line Nook chained prints under the box (NookStatusLine.swift).
            || NookStatusLine.isShownLine(line)
    }

    private static func isDialogHint(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["to confirm", "to select", "to navigate", "esc to exit", "esc to cancel", "enter to "].contains { lower.contains($0) }
    }

    private static func isNotice(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("update installed") || lower.contains("restart to update") || lower.contains("auto-update")
    }
}
