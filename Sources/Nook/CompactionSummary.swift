import Foundation

// When Claude Code compacts a session's context, it writes the summary of everything before into its record as a message in the
// user's place: an entry of type "user" with `isCompactSummary: true` (and `isVisibleInTranscriptOnly: true`), right after a
// "compact_boundary" system entry. Its text is long (the request, the files, the errors, the next step…) and opens with a fixed
// sentence, "This session is being continued from a previous conversation that ran out of context.". Read as any other user entry,
// Nook drew it as a giant message the user had typed.
//
// The mirror shows a quiet divider in its place (`marker`, dressed by `TranscriptStyler`), and the summary goes to its own control
// beside "Resumen" (`SessionRecapButton`, kind `.compaction`).
//
//   from the record   the entry's own flag (`TranscriptRenderer.consumeUser`): exact, whatever the text says
//   from the screen   without the record the mirror is Claude's screen, and a summary shows there as a prompt that opens with that
//                     sentence; a block whose opening has scrolled away is told by phrases only a summary carries (`stripped`)

enum CompactionSummary {
    /// How every summary opens.
    static let opening = "This session is being continued from a previous conversation that ran out of context."
    /// The line the mirror shows where a summary was: `TranscriptStyler` draws it as a divider.
    static let marker = "Contexto compactado"
    /// What the screen's first line of a summary must start with: the opening, as far as any terminal fits it on one line.
    private static let openingStart = "This session is being continued from a previous conversation"
    /// Phrases of a summary's body: they tell a summary whose opening has scrolled out of the screen.
    static let signatures = ["Primary Request and Intent:", "Continue the conversation from where it left off without asking the user",
                             "The summary below covers the earlier portion of the conversation."]

    /// The summary as it is worth reading: without Claude Code's notes to itself (`<system-reminder>…</system-reminder>`, the tools
    /// it used) or its tag about content written by others, and with nothing blank at either end.
    static func readable(_ text: String) -> String {
        var clean = text.replacingOccurrences(of: #"(?s)<system-reminder>.*?</system-reminder>\n?"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"<artifact-content-authored-by-others\s*/>\n?"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The summary as its card shows (and copies) it: without the paragraph that opens every summary, which the card's title says in
    /// its own words. Nil when nothing is left.
    static func shown(_ text: String?) -> String? {
        guard var body = text.map(readable) else { return nil }
        if body.hasPrefix(opening) {
            let end = body.range(of: "\n\n")?.upperBound ?? body.endIndex
            body = String(body[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.isEmpty ? nil : body
    }

    /// Claude's screen with each summary shown on it replaced by the `marker` line, and the latest summary's words (nil when the screen
    /// shows none). A summary is a prompt (`> ` or `❯ ` at the left edge) whose first line starts with the opening sentence, with the
    /// lines indented under it and the blank ones between them; it ends at the next line at the left edge, whatever that line opens.
    /// Lines that open the screen indented under nothing (the start of a prompt scrolled away) are a summary when they carry its
    /// phrases. A message that only quotes the sentence after other words is a message.
    static func stripped(_ screen: String) -> (text: String, summary: String?) {
        guard screen.contains(openingStart) || signatures.contains(where: screen.contains) else { return (screen, nil) }
        let lines = screen.components(separatedBy: "\n")
        var kept: [String] = []
        var summary: String?
        var index = 0
        // A summary that started above the screen: the lines before the first one at the left edge.
        let lead = lines.firstIndex { !isBlank($0) && indent($0) <= 1 } ?? lines.count
        if lead > 0, lines[..<lead].contains(where: { line in signatures.contains { line.contains($0) } }) {
            summary = words(lines[..<lead], first: nil)
            kept.append(marker)
            index = lead
        }
        while index < lines.count {
            let line = lines[index]
            guard let first = summaryHead(line) else {
                kept.append(line)
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count, isBlank(lines[end]) || indent(lines[end]) >= 2 { end += 1 }
            // The blank lines at its end part it from what follows, as before.
            var last = end
            while last > index + 1, isBlank(lines[last - 1]) { last -= 1 }
            summary = words(lines[(index + 1)..<last], first: first)
            kept.append(marker)
            kept.append(contentsOf: lines[last..<end])
            index = end
        }
        return (kept.joined(separator: "\n"), summary.map(readable))
    }

    /// The words after the prompt's mark, when `line` is the first line of a summary.
    private static func summaryHead(_ line: String) -> String? {
        guard indent(line) <= 1 else { return nil }
        let text = line.drop { $0 == " " }
        guard let mark = text.first, mark == ">" || mark == "❯" else { return nil }
        let words = text.dropFirst().drop { $0 == " " }
        return words.hasPrefix(openingStart) ? String(words) : nil
    }

    /// A summary's text from the screen: its first line's words, then its other lines without the prompt's two columns.
    private static func words(_ lines: ArraySlice<String>, first: String?) -> String {
        let rest = lines.map { line -> String in
            var text = Substring(line)
            for _ in 0..<2 where text.first == " " { text = text.dropFirst() }
            return String(text).replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }
        return ((first.map { [$0] } ?? []) + rest).joined(separator: "\n")
    }

    private static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }
}
