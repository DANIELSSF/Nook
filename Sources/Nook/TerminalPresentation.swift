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

/// Whether an agent's screen shows a message Nook just typed. Compared without whitespace,
/// since agents wrap long input across lines.
enum MessageEcho {
    static func key(_ text: String) -> String { String(text.filter { !$0.isWhitespace }.prefix(40)) }

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
        return !message.isEmpty && squeezed(box).hasSuffix(message)
    }

    /// The box's text when something already typed there sits in front of the message ("t/usage").
    /// A grey suggestion disappears as soon as the message is pasted, so it never counts.
    static func joined(_ text: String, in screen: String) -> String? {
        guard let input = ClaudeComposer.split(screen).input, !input.contains("[Pasted text") else { return nil }
        // An image pasted with ⌃V sits in front as "[Image #1]"; it belongs with the message.
        let box = squeezed(input.replacingOccurrences(of: #"\[[Ii]mage[^\]]*\]"#, with: "", options: .regularExpression)), message = squeezed(text)
        return !message.isEmpty && box.hasSuffix(message) && box != message ? input : nil
    }

    /// Whether the message shows anywhere in `text`, however it was wrapped.
    static func appears(_ message: String, in text: String) -> Bool {
        let key = key(message)
        return !key.isEmpty && squeezed(text).contains(key)
    }

    /// Whether the box holds exactly this message, however Claude wrapped it.
    static func same(_ box: String, _ text: String) -> Bool {
        !box.contains("[Pasted text") && !squeezed(text).isEmpty && squeezed(box) == squeezed(text)
    }

    private static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}

/// Keys that drive an agent's own menus: the real options always come from the session.
enum TerminalKey: String, CaseIterable, Identifiable {
    /// ⌃V asks Claude or Codex to paste the clipboard's image, as in their own terminal.
    case up, down, tab, escape, enter, pasteImage
    /// The keys of the menu strip.
    static let menuKeys: [TerminalKey] = [.up, .down, .tab, .escape, .enter]
    var id: String { rawValue }
    var tmuxName: String {
        switch self { case .up: "Up"; case .down: "Down"; case .tab: "Tab"; case .escape: "Escape"; case .enter: "Enter"; case .pasteImage: "C-v" }
    }
    var keyCode: CGKeyCode {
        switch self { case .up: 126; case .down: 125; case .tab: 48; case .escape: 53; case .enter: 36; case .pasteImage: 9 }
    }
    var modifiers: CGEventFlags { self == .pasteImage ? .maskControl : [] }
    var symbol: String {
        switch self { case .up: "arrow.up"; case .down: "arrow.down"; case .tab: "arrow.right.to.line"; case .escape: "escape"; case .enter: "return"; case .pasteImage: "photo" }
    }
    /// The escape symbol reads as "undo" at this size; the key's own name is clearer.
    var caption: String? { self == .escape ? "esc" : nil }
    var label: String {
        switch self {
        case .up: "Flecha arriba"; case .down: "Flecha abajo"; case .tab: "Tab"
        case .escape: "Escape"; case .enter: "Enter"; case .pasteImage: "Pegar imagen"
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

    static let spinner: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽"]

    init(glyph: String?, text: String, working: Bool) { self.glyph = glyph; self.text = text; self.working = working }

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
        } else { return nil }
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
        var status: ClaudeStatus?
        var recap: String?
        var recapLines: [String]?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
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
        return ClaudeScreen(conversation: conversation, input: input, status: status, recap: recap.flatMap { $0.isEmpty ? nil : $0 }, menu: menu)
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
        return Double(drawn) / Double(trimmed.count) >= 0.75
    }

    static func isPrompt(_ line: String) -> Bool {
        guard atEdge(line) else { return false }
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.first == "│" { text = text.dropFirst().drop(while: { $0 == " " }) }
        guard let mark = text.first, ["❯", ">", "!"].contains(mark) else { return false }
        let rest = text.dropFirst()
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return false }
        // "❯ 1. Yes" is a highlighted option in a dialog, never the input line.
        return rest.drop(while: \.isWhitespace).range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil
    }

    /// Claude's mode line under the box ("⏵⏵ auto mode on (shift+tab to cycle) · 1 background · ← for agents").
    static func isFooterLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["shift+tab", "⏵⏵", "⏸", "for shortcuts", "auto mode", "accept edits", "plan mode", "bypass permissions",
                "for agents", "auto-compact", "context left", "background"].contains { lower.contains($0) }
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
