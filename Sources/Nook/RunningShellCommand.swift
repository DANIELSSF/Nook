import Foundation

/// A "!" command running in the foreground, as Claude draws it at the end of its conversation. Claude's record says nothing of it
/// until it ends or Claude moves it to the background (then it is a shell, `TranscriptShells`): until then its words come from
/// the screen.
///
///     !  infra/gcp/deploy.sh dev
///       ⎿  default gcloudignore file used (see `$ gcloud topic gcloudignore` to learn
///          more).
///          +23 lines (56s)
///          (ctrl+b to run in background)
struct RunningShellCommand: Equatable {
    var command: String
    /// The lines Claude shows of what it printed so far, without Claude's margin.
    var output: [String]
    /// How many earlier lines Claude folded ("+23 lines").
    var folded: Int?
    /// How long it has run, as Claude writes it ("56s", "2m 5s").
    var elapsed: String?

    /// The command running at the end of a screen's conversation; nil when the last thing there is anything else. Only a command
    /// typed at Claude's margin ("!") counts: Claude's own Bash calls ("⏺ Bash(…)") show the same hint, and their record has them.
    static func parse(_ conversation: String) -> RunningShellCommand? {
        let lines = conversation.suffix(8_000).components(separatedBy: "\n")
        var end = lines.endIndex
        while end > lines.startIndex, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        // "(ctrl+b to run in background)", "(ctrl+b ctrl+b (twice) to run in background)" under tmux, or the key the user chose.
        guard end > lines.startIndex, lines[end - 1].range(of: #"^\s+\(.+ to run in background\)\s*$"#, options: .regularExpression) != nil else { return nil }
        var start = end - 1
        while start > lines.startIndex {
            start -= 1
            let line = lines[start]
            if line.hasPrefix("!") {
                let command = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { return nil }
                return RunningShellCommand(command: command, block: Array(lines[(start + 1)..<(end - 1)]))
            }
            // Anything else at the margin (a reply's "⏺", a prompt's "❯") ends the search: the hint is not a "!" command's.
            if let first = line.first, !first.isWhitespace { return nil }
        }
        return nil
    }

    private init(command: String, block: [String]) {
        self.command = command
        var output = block.map { line -> String in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("⎿") ? text.dropFirst().trimmingCharacters(in: .whitespaces) : text
        }
        while output.last?.isEmpty == true { output.removeLast() }
        // "+23 lines (56s)", or the time alone.
        if let last = output.last, last.range(of: #"^(\+\d+ lines? )?\(\d[^()]*\)$"#, options: .regularExpression) != nil {
            folded = last.range(of: #"(?<=^\+)\d+"#, options: .regularExpression).flatMap { Int(last[$0]) }
            elapsed = last.range(of: #"(?<=\()[^()]+(?=\)$)"#, options: .regularExpression).map { String(last[$0]) }
            output.removeLast()
        }
        self.output = output.filter { !$0.isEmpty }
    }

    /// As the mirror shows a command still running ("> ! git status", then "  ⎿  …"): what it printed so far, and a last line with
    /// the folded lines and the time.
    var text: String {
        let more = [folded.map { "+\($0) \($0 == 1 ? "línea" : "líneas")" }, elapsed].compactMap { $0 }.joined(separator: " · ")
        let shown = output.map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 } + ["…" + (more.isEmpty ? "" : " " + more)]
        return "> ! " + command + "\n  ⎿  " + shown.joined(separator: "\n     ") + "\n\n"
    }

    /// The text to show after a record's conversation, nil once the record has this command: its newest prompt is the command (it
    /// ended, or went to the background, a moment before the screen was redrawn).
    func shown(after record: String) -> String? {
        let start = record.range(of: "\n> ", options: .backwards).map { record.index(after: $0.lowerBound) } ?? (record.hasPrefix("> ") ? record.startIndex : nil)
        if let start, record[start...].hasPrefix("> ! " + command) { return nil }
        return text
    }
}
