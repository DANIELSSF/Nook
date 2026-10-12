import Foundation

/// Claude Code's own record of a conversation (one JSON object per line), turned into the mirror's
/// text. In fullscreen rendering Claude keeps the conversation on the terminal's alternate screen, so
/// Terminal only holds what is visible; the record always holds all of it. The format follows the
/// terminal's look ("> " prompts, "⏺ " replies and tool calls, "  ⎿  " results) so the mirror's
/// per-voice styling, scrolling and copying work unchanged.
struct TranscriptRenderer {
    /// Finished entries; only ever appended, so the mirror grows at its end.
    private(set) var committed = "" { didSet { version &+= 1 } }
    /// `committed`'s length in UTF-16 units, kept as it grows: counting it again after every entry walked up to 240,000
    /// characters each time.
    private var committedLength = 0
    /// Tool calls still waiting for their result, drawn after the committed text.
    private var pending: [(id: String, line: String)] = [] { didSet { version &+= 1 } }
    /// Changes whenever `text` may have: comparing it is how a reading knows something new arrived, without building the text
    /// (up to 240,000 characters) twice per reading to compare.
    private(set) var version = 0
    private(set) var recap: String?
    /// Skills Claude listed for this session (name → description), and the commands it ran.
    private(set) var skills: [String: String] = [:] { didSet { if skills != oldValue { commandsVersion += 1 } } }
    private(set) var usedCommands: Set<String> = [] { didSet { if usedCommands != oldValue { commandsVersion += 1 } } }
    private(set) var commandsVersion = 0
    /// The subagents this session launched and how they ended.
    private(set) var agents = TranscriptAgents()
    /// The commands this session ran in the background and how they ended.
    private(set) var shells = TranscriptShells()
    var cwd: String?
    /// A subagent's own record is all sidechain entries; the main record's sidechain is skipped.
    var includeSidechain = false
    /// Older text is dropped in large steps once the record grows past this many UTF-16 units.
    var limit = 240_000

    var text: String {
        guard !pending.isEmpty || shellCommand != nil else { return committed }
        let running = shellCommand.map { $0 + "\n  ⎿  …\n\n" } ?? ""
        return committed + running + (pending.isEmpty ? "" : pending.map { $0.line + "\n  ⎿  …" }.joined(separator: "\n\n") + "\n\n")
    }

    mutating func identifyAgents(_ ids: [String: String]) { agents.identify(ids) }

    mutating func consume(_ line: String) {
        guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if entry["isSidechain"] as? Bool == true, !includeSidechain { return }
        if cwd == nil, let directory = entry["cwd"] as? String { cwd = directory }
        let notifies = line.contains("<task-notification>")
        if notifies || line.contains("[Subagent hand-back]") { agents.notice(line, at: TranscriptAgents.date(entry)) }
        // Only what Claude Code itself delivers ends a shell; a reply or a tool's result quoting a notification doesn't.
        if notifies { Self.deliveredTexts(entry).forEach { shells.notice($0, at: TranscriptAgents.date(entry)) } }
        switch entry["type"] as? String {
        case "user": consumeUser(entry)
        case "assistant": consumeAssistant(entry)
        case "system":
            // Claude's session recap, shown by Nook's Resumen button rather than in the chat.
            if entry["subtype"] as? String == "away_summary", let content = entry["content"] as? String, !content.isEmpty { recap = content }
        case "attachment":
            guard let attachment = entry["attachment"] as? [String: Any] else { return }
            switch attachment["type"] as? String {
            case "skill_listing":
                // Later listings only add skills, so they join the first one.
                skills.merge(SlashCatalog.skills(listing: attachment["content"] as? String ?? "", names: attachment["names"] as? [String] ?? [])) { _, new in new }
            case "queued_command":
                // A message the user sent while Claude worked, taken in the middle of its turn. Task notifications and other
                // sessions' messages travel the same way but are not the user's.
                let origin = (attachment["origin"] as? [String: Any])?["kind"] as? String ?? "human"
                guard attachment["commandMode"] as? String == "prompt", origin == "human" else { return }
                if let text = attachment["prompt"] as? String { prompt(text) } else { userBlocks(attachment["prompt"] as? [[String: Any]] ?? []) }
            default: break
            }
        case "queue-operation": queue(entry)
        default: break
        }
    }

    /// The texts of an entry that Claude Code delivered to Claude: a user message's own text, its queue's entries, and the
    /// commands it queued. Never an assistant's reply or a tool's result.
    static func deliveredTexts(_ entry: [String: Any]) -> [String] {
        switch entry["type"] as? String {
        case "user":
            let content = (entry["message"] as? [String: Any])?["content"]
            if let text = content as? String { return [text] }
            return (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        case "queue-operation": return (entry["content"] as? String).map { [$0] } ?? []
        case "attachment":
            guard let attachment = entry["attachment"] as? [String: Any], attachment["type"] as? String == "queued_command" else { return [] }
            if let text = attachment["prompt"] as? String { return [text] }
            return (attachment["prompt"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        default: return []
        }
    }

    // MARK: Claude's queue

    /// What was sent while Claude worked and Claude still holds (grey in its terminal), oldest first. Claude's own queue also
    /// carries task notifications and other sessions' messages, which start with their tag.
    private(set) var queued: [String] = []

    /// What the latest dequeue took out, until the message it delivered is read: that message must not take a second entry out.
    private var lastDequeued: String?

    private mutating func queue(_ entry: [String: Any]) {
        // An image alone has no text; it still holds its place in the queue.
        let content = entry["content"] as? String ?? ""
        switch entry["operation"] as? String {
        case "enqueue": queued.append(content)
        case "dequeue": lastDequeued = queued.isEmpty ? nil : queued.removeFirst()
        case "remove":
            // Claude may write another session's message back without the attributes it was queued with (its hop chain).
            if let index = queued.firstIndex(of: content) ?? queued.firstIndex(where: { Self.sameQueued($0, content) }) { queued.remove(at: index) }
        case "popAll": queued.removeAll()
        default: break
        }
    }

    /// A message Claude took (a prompt, or a notice of its own recorded as a meta message) leaves the queue, if Claude's own
    /// queue records didn't already take it out. The dequeue right before it was that message leaving.
    private mutating func delivered(_ text: String) {
        defer { lastDequeued = nil }
        if let popped = lastDequeued, Self.sameQueued(popped, text) { return }
        if let index = queued.firstIndex(where: { Self.sameQueued($0, text) }) { queued.remove(at: index) }
    }

    /// One queued message, however Claude wrote it each time: the same text, or the same but for the attributes of the tag it
    /// opens with (`<cross-session-message from="…" hop-chain="…" …>` queued, the same without `hop-chain` when taken).
    static func sameQueued(_ entry: String, _ text: String) -> Bool {
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines), text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry == text { return true }
        guard entry.hasPrefix("<"), text.hasPrefix("<") else { return false }
        func bare(_ value: String) -> String { value.replacingOccurrences(of: #"^<([A-Za-z_-]+)[^>]*>"#, with: "<$1>", options: .regularExpression) }
        return bare(entry) == bare(text)
    }

    private mutating func consumeUser(_ entry: [String: Any]) {
        guard let message = entry["message"] as? [String: Any] else { return }
        let meta = entry["isMeta"] as? Bool == true
        if let text = message["content"] as? String {
            // A meta message is Claude Code's own (a reminder, another session's idle notice): never the user's words, but one that
            // waited in the queue was delivered all the same.
            if meta { delivered(text) } else { prompt(text) }
            return
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            if block["type"] as? String == "tool_result" { result(block, at: TranscriptAgents.date(entry), details: entry["toolUseResult"] as? [String: Any]) }
            else if !meta { userBlocks([block]) }
        }
    }

    /// A prompt's text and images.
    private mutating func userBlocks(_ blocks: [[String: Any]]) {
        for block in blocks {
            switch block["type"] as? String {
            case "text": if let text = block["text"] as? String { prompt(text) }
            case "image": append("> [Imagen]")
            default: break
            }
        }
    }

    private mutating func consumeAssistant(_ entry: [String: Any]) {
        guard let message = entry["message"] as? [String: Any] else { return }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(Self.indented("⏺ ", text)) }
            case "tool_use":
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                if name == "Agent" || name == "Task", let id = block["id"] as? String { agents.launch(call: id, input: input, at: TranscriptAgents.date(entry)) }
                if name == "Bash" || TranscriptShells.stopTools.contains(name), let id = block["id"] as? String {
                    shells.call(id: id, tool: name, input: input, at: TranscriptAgents.date(entry))
                }
                pending.append((block["id"] as? String ?? UUID().uuidString, "⏺ \(name)(\(Self.summary(of: input, cwd: cwd)))"))
            default: break   // thinking stays private to Claude's own view
            }
        }
    }

    /// A real prompt; messages Claude Code injects (task notifications, reminders, command records) are not the user's.
    private mutating func prompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Taken, however Claude's queue let it go: a turn of its own or the middle of another.
        delivered(trimmed)
        if let tag = trimmed.range(of: #"^<([a-zA-Z_-]+)"#, options: .regularExpression) {
            let name = trimmed[tag].dropFirst()
            // Claude's shell mode ("! git status"): the command, then what it printed.
            if name == "bash-input" { return shellInput(trimmed) }
            if name == "bash-stdout" || name == "bash-stderr" { return shellOutput(trimmed) }
            // A slash command is recorded as tags; it shows the way it was typed.
            if name == "command-name" || name == "command-message",
               let command = trimmed.range(of: #"(?<=<command-name>)[^<]+"#, options: .regularExpression) {
                let args = trimmed.range(of: #"(?<=<command-args>)[^<]+"#, options: .regularExpression).map { " " + trimmed[$0] } ?? ""
                let typed = String(trimmed[command]).trimmingCharacters(in: .whitespaces)
                let name = typed.hasPrefix("/") ? String(typed.dropFirst()) : typed
                if SlashCatalog.isName(name) { usedCommands.insert(name) }
                let line = "> " + (typed.hasPrefix("/") ? typed : "/" + typed) + args
                // /effort and /model wait for Claude's answer, the next record: one that worked hides both.
                if ClaudeSettingsEcho.isCommand(String(line.dropFirst(2))) { flushSettings(); heldSettings = line; return }
                return append(line)
            }
            if name == "local-command-stdout" || name == "local-command-stderr" { return answerSettings(trimmed, error: name == "local-command-stderr") }
            guard name == "pasted_content" else { return }
            let inner = trimmed.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            return append(Self.indented("> ", inner.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        append(Self.indented("> ", trimmed))
    }

    private mutating func result(_ block: [String: Any], at date: Date?, details: [String: Any]? = nil) {
        let id = block["tool_use_id"] as? String
        let index = pending.firstIndex { $0.id == id }
        let call = index.map { pending.remove(at: $0).line }
        let body = Self.resultText(block["content"])
        if let id {
            agents.result(call: id, text: body, error: block["is_error"] as? Bool == true, at: date)
            shells.result(call: id, text: body, details: details, error: block["is_error"] as? Bool == true, at: date)
        }
        // An edit or a new file shows its lines, as Claude draws them, instead of the tool's message.
        if block["is_error"] as? Bool != true, let details, let change = Self.change(details, cwd: cwd) {
            return append((call.map { $0 + "\n" } ?? "") + change)
        }
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        append((call.map { $0 + "\n" } ?? "") + Self.resultBlock(lines, error: block["is_error"] as? Bool == true))
    }

    /// A result as Claude's terminal shows it: "  ⎿  " and its first three lines ("Error: " before the first for a failure), "… +N
    /// líneas" for the rest, "(sin salida)" for none.
    static func resultBlock(_ lines: [String], error: Bool = false) -> String {
        let more = max(0, lines.count - 3)
        var shown = Array(lines.prefix(3)).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
        if error, !shown.isEmpty { shown[0] = "Error: " + shown[0] }
        if shown.isEmpty { shown = ["(sin salida)"] }
        if more > 0 { shown.append("… +\(more) líneas") }
        return "  ⎿  " + shown.joined(separator: "\n     ")
    }

    // MARK: Claude's shell mode

    /// A "!" command the user ran through Claude, until its output arrives: drawn after the committed text, as running.
    private var shellCommand: String? { didSet { version &+= 1 } }

    /// `<bash-input> git status</bash-input>`: the command shows as the user typed it, "> ! git status".
    private mutating func shellInput(_ record: String) {
        flushShell()
        let command = Self.tagged("bash-input", in: record) ?? ""
        shellCommand = Self.indented("> ", "! " + command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>`: what the command printed, under it, like a tool's result. What
    /// went to stderr is marked as an error; colour codes and redraws go as in a shell's output.
    private mutating func shellOutput(_ record: String) {
        func lines(_ tag: String) -> [String] {
            (Self.tagged(tag, in: record) ?? "").components(separatedBy: "\n")
                .map { ShellOutputText.clean($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let output = lines("bash-stdout"), errors = lines("bash-stderr")
        let command = shellCommand
        shellCommand = nil
        // Only errors: the result is a failure, as a tool's. Errors after some output start with the word.
        let shown = output.isEmpty ? errors : output + errors.enumerated().map { $0.offset == 0 ? "Error: " + $0.element : $0.element }
        append((command.map { $0 + "\n" } ?? "") + Self.resultBlock(shown, error: output.isEmpty && !errors.isEmpty))
    }

    /// A command whose output never came shows alone.
    private mutating func flushShell() {
        guard let command = shellCommand else { return }
        shellCommand = nil
        append(command)
    }

    /// The text between `<tag>` and `</tag>`, nil without the tag.
    private static func tagged(_ tag: String, in record: String) -> String? {
        guard let open = record.range(of: "<\(tag)>") else { return nil }
        let close = record.range(of: "</\(tag)>", range: open.upperBound..<record.endIndex)
        return String(record[open.upperBound..<(close?.lowerBound ?? record.endIndex)])
    }

    /// A /effort or /model echo waiting for Claude's answer (`ClaudeSettingsEcho`).
    private var heldSettings: String?

    /// Claude's answer to the held settings command: a confirmation hides both; an error or anything else shows under it.
    /// Answers to other commands stay out of the chat, as before.
    private mutating func answerSettings(_ record: String, error: Bool) {
        guard let held = heldSettings else { return }
        heldSettings = nil
        let answer = record.replacingOccurrences(of: #"</?local-command-std(out|err)>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !error, ClaudeSettingsEcho.isConfirmation(answer) { return }
        append(held + (answer.isEmpty ? "" : "\n" + Self.indented("  ⎿  ", answer)))
    }

    /// A held command whose answer never came shows as it was typed.
    private mutating func flushSettings() {
        guard let held = heldSettings else { return }
        heldSettings = nil
        append(held)
    }

    private mutating func append(_ block: String) {
        flushSettings()
        flushShell()
        committed += block + "\n\n"
        committedLength += block.utf16.count + 2
        guard committedLength > limit else { return }
        // Trimmed at an entry boundary, three quarters at a time, so the mirror's start rarely moves.
        let ns = committed as NSString
        let length = ns.length
        let cut = ns.range(of: "\n\n", range: NSRange(location: length - limit * 3 / 4, length: limit * 3 / 4)).location
        committed = cut == NSNotFound ? "" : ns.substring(from: cut + 2)
        committedLength = (committed as NSString).length
    }

    /// Rows of a change, after its summary line: six spaces, the line number right-aligned to the
    /// widest one, then "-" (removed, old numbering), "+" (added) or a space (context, new numbering),
    /// a space and the code. A gap between hunks is a row of "…" in the number's place.
    static let changeIndent = "      "

    /// An edit's or a new file's result the way Claude's terminal shows it:
    /// "  ⎿  Actualizado Sources/App.swift (+2 -1)" over its numbered lines.
    static func change(_ details: [String: Any], cwd: String?, limit: Int = 80, preview: Int = 12) -> String? {
        var path = details["filePath"] as? String ?? ""
        if let cwd, path.hasPrefix(cwd + "/") { path = String(path.dropFirst(cwd.count + 1)) }
        var rows: [(number: Int?, mark: Character, code: String)] = []
        let summary: String
        if let hunks = details["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            var added = 0, removed = 0
            for (index, hunk) in hunks.enumerated() {
                var old = hunk["oldStart"] as? Int ?? 1, new = hunk["newStart"] as? Int ?? 1
                if index > 0 { rows.append((nil, " ", "")) }
                for line in hunk["lines"] as? [String] ?? [] {
                    let code = String(line.dropFirst())
                    switch line.first {
                    case "-": rows.append((old, "-", code)); old += 1; removed += 1
                    case "+": rows.append((new, "+", code)); new += 1; added += 1
                    case "\\": continue   // "\ No newline at end of file"
                    default: rows.append((new, " ", code)); old += 1; new += 1
                    }
                }
            }
            summary = "Actualizado \(path) (+\(added) -\(removed))"
        } else if details["type"] as? String == "create", let content = details["content"] as? String {
            let lines = content.components(separatedBy: "\n")
            let count = lines.last == "" ? lines.count - 1 : lines.count
            rows = lines.prefix(min(count, preview)).enumerated().map { ($0.offset + 1, " ", $0.element) }
            summary = "Creado \(path) (\(count) \(count == 1 ? "línea" : "líneas"))"
            if count > preview { rows.append((nil, " ", "+\(count - preview) líneas")) }
        } else { return nil }
        let width = String(rows.compactMap(\.number).max() ?? 1).count
        var shown = rows.prefix(limit).map { row -> String in
            guard let number = row.number else { return changeIndent + String(repeating: " ", count: width) + " … " + row.code }
            let label = String(number)
            return changeIndent + String(repeating: " ", count: width - label.count) + label + " \(row.mark) " + row.code
        }
        if rows.count > limit { shown.append(changeIndent + "… +\(rows.count - limit) líneas") }
        return (["  ⎿  " + summary] + shown).joined(separator: "\n")
    }

    static func indented(_ mark: String, _ text: String) -> String {
        text.components(separatedBy: "\n").enumerated().map { $0.offset == 0 ? mark + $0.element : "  " + $0.element }.joined(separator: "\n")
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "image" ? "[Imagen]" : block["text"] as? String
        }.joined(separator: "\n")
    }

    /// What a tool call shows between parentheses, like Claude's own line: its command, file or query.
    static func summary(of input: [String: Any], cwd: String?) -> String {
        for key in ["command", "file_path", "notebook_path", "path", "pattern", "description", "url", "query", "skill", "prompt"] {
            guard var value = input[key] as? String, !value.isEmpty else { continue }
            value = value.components(separatedBy: "\n").first ?? value
            if let cwd, value.hasPrefix(cwd + "/") { value = String(value.dropFirst(cwd.count + 1)) }
            return value.count > 90 ? String(value.prefix(89)) + "…" : value
        }
        return ""
    }
}

/// Follows one record file: reads only what was appended since the last look.
final class TranscriptFollower {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var renderer = TranscriptRenderer()
    /// The renderer's commands version last handed to the session (touched on the reading queue only).
    var reportedCommands = 0
    var reportedAgents: [SubagentActivity] = []
    var reportedShells: [ShellActivity] = []
    var reportedQueue: [String] = []
    /// Text read while the chat was hidden (collapsed island), not handed to the session yet.
    var unshown = false
    private lazy var watch = SubagentWatch(record: url)

    /// The subagent whose conversation is being read (its launch's call id), and its record's follower.
    private var viewing: (call: String, follower: TranscriptFollower?)?

    /// How many subagents' records are being followed for their progress.
    var watchedAgents: Int { watch.watched }

    /// One subagent's own record, once Claude has named the agent.
    func agentRecord(call: String) -> URL? {
        if renderer.agents.launches.contains(where: { $0.call == call && $0.agentID == nil }) { renderer.identifyAgents(watch.metadata()) }
        // "agent:<id>": an agent known by its id alone (resumed, or launched before what was read).
        let named = call.hasPrefix("agent:") ? String(call.dropFirst("agent:".count)) : nil
        guard let id = named ?? renderer.agents.launches.first(where: { $0.call == call })?.agentID,
              !id.isEmpty, !id.contains("/"), !id.contains(".") else { return nil }
        let url = watch.folder.appendingPathComponent("agent-\(id).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A subagent's conversation as the mirror shows it, read incrementally like the main one; nil
    /// while it has no record yet, or with `call` nil (back to the main conversation).
    func agentText(call: String?) -> String? {
        guard let call else { viewing = nil; return nil }
        if viewing?.call != call { viewing = (call, nil) }
        if viewing?.follower == nil, let url = agentRecord(call: call) { viewing?.follower = TranscriptFollower(url: url, sidechain: true) }
        guard let agent = viewing?.follower else { return nil }
        _ = agent.poll()
        return agent.renderer.text
    }

    /// The background shell whose output is being read (its task id), the entering it was read for (`TerminalSession.shellViewEpoch`),
    /// its reader once its file could be opened, and what was handed over last: the reader's version and that entering.
    private var viewingShell: (id: String, tail: ShellOutputTail?, delivered: (version: Int, epoch: Int)?)?

    /// How many shell outputs are being read: one while a shell is viewed, none otherwise.
    var watchedShellOutputs: Int { viewingShell?.tail == nil ? 0 : 1 }

    /// The session's background shells now: running ones, and finished ones for ten minutes after they end.
    func shells(now: Date = Date()) -> [ShellActivity] { renderer.shells.shown(now: now) }

    /// Where shell output may be read from (`ShellOutputFile`); tests point it elsewhere.
    var shellRoots = ShellOutputFile.roots

    /// A background shell's output, read from its file's end and then only what was appended: nil when nothing changed since the
    /// last call for this entering (`epoch`), or with `id` nil (no shell viewed: its reader goes).
    func shellOutput(id: String?, epoch: Int = 0) -> ShellOutput? {
        guard let id else { viewingShell = nil; return nil }
        if viewingShell?.id != id { viewingShell = (id, nil, nil) }
        if viewingShell?.tail == nil, let path = renderer.shells.launches.last(where: { $0.id == id })?.outputPath {
            viewingShell?.tail = ShellOutputTail(path: path, roots: shellRoots)
        }
        guard let tail = viewingShell?.tail else {
            // Nothing to read (yet): said once per entering.
            guard viewingShell?.delivered?.epoch != epoch else { return nil }
            viewingShell?.delivered = (-1, epoch)
            return ShellOutput(available: false)
        }
        tail.poll()
        if let delivered = viewingShell?.delivered, delivered.version == tail.version, delivered.epoch == epoch { return nil }
        viewingShell?.delivered = (tail.version, epoch)
        return ShellOutput(text: tail.text, clipped: tail.clipped)
    }

    /// The session's subagents now: running ones, and finished ones for ten minutes after they end.
    func agents(now: Date = Date()) -> [SubagentActivity] {
        if renderer.agents.launches.contains(where: { $0.state == .running && $0.agentID == nil }) { renderer.identifyAgents(watch.metadata()) }
        let recent = renderer.agents.launches.filter { launch in
            launch.state == .running || (launch.ended ?? launch.started).map { now.timeIntervalSince($0) < 600 } == true
        }
        var shown = renderer.agents
        shown.keep(recent.map(\.call))
        return watch.activities(shown, cwd: renderer.cwd, now: now)
    }

    /// A long record starts from its last `initialBytes`; the mirror keeps the recent part anyway.
    /// Claude lists the session's skills near the start, so a skipped start is searched for that list.
    /// `limit`: how much of the conversation the mirror keeps, in UTF-16 units (`TranscriptRenderer.limit`).
    init(url: URL, initialBytes: UInt64 = 3_000_000, headBytes: Int = 1_000_000, sidechain: Bool = false, limit: Int = 240_000) {
        self.url = url
        renderer.includeSidechain = sidechain
        renderer.limit = limit
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        offset = size > initialBytes ? size - initialBytes : 0
        skipToLineStart = offset > 0
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: min(headBytes, Int(offset)))) ?? Data()
        for line in head.split(separator: 0x0A) where line.range(of: Data("\"skill_listing\"".utf8)) != nil {
            renderer.consume(String(decoding: line, as: UTF8.self))
        }
    }
    private var skipToLineStart: Bool

    /// The mirror text when something new arrived, nil otherwise.
    func poll() -> String? {
        let before = renderer.version
        guard Self.readLines(of: url, offset: &offset, partial: &partial, skipToLineStart: &skipToLineStart, each: { renderer.consume(String(decoding: $0, as: UTF8.self)) }) else { return nil }
        return renderer.version == before ? nil : renderer.text
    }

    /// Reads what was appended to a record since `offset`, hands each complete line over, and keeps an unfinished last line in
    /// `partial` for the next look. The file is read a megabyte at a time (a subagent's record is read from its start, and can
    /// be tens of megabytes), lines are walked in place (cutting the buffer after each one copied the rest of it, megabytes at a
    /// time on a first read), and every few dozen lines drain their own autorelease pool: a first read peaks at one chunk and one
    /// batch of decoded lines, not at the whole record. False when nothing new was there.
    @discardableResult
    static func readLines(of url: URL, offset: inout UInt64, partial: inout Data, skipToLineStart: inout Bool, chunk: Int = 1 << 20,
                          each consume: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return false }
        var read = false
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            read = true
            offset += UInt64(data.count)
            let buffer = partial.isEmpty ? data : partial + data
            var start = buffer.startIndex
            if skipToLineStart {
                guard let newline = buffer[start...].firstIndex(of: 0x0A) else { partial = buffer; continue }
                start = newline + 1; skipToLineStart = false
            }
            var done = false
            while !done {
                autoreleasepool {
                    for _ in 0..<64 {
                        guard let newline = buffer[start...].firstIndex(of: 0x0A) else { done = true; return }
                        consume(buffer[start..<newline])
                        start = newline + 1
                    }
                }
            }
            partial = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        }
        return read
    }
}

/// Finds which record belongs to a terminal tab.
enum TranscriptLocator {
    /// Claude's configuration folders (`~/.claude` and variants such as `~/.claude-work`).
    static func roots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix(".claude") }.map { home.appendingPathComponent($0).appendingPathComponent("projects") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Those folders themselves, where Claude also keeps a file per running process (`sessions/<pid>.json`).
    static func configs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        roots(home: home).map { $0.deletingLastPathComponent() }
    }

    /// The record of a session id reported by Claude's hooks.
    static func record(session id: String, roots: [URL] = roots()) -> URL? {
        guard !id.isEmpty, !id.contains("/") else { return nil }
        for root in roots {
            for project in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let url = root.appendingPathComponent(project).appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Claude names a project's folder after its working directory with every other character as "-".
    static func folderName(for directory: String) -> String {
        directory.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    /// Without hooks: the record of the tab's working directory whose latest prompt the screen shows as a prompt, and none
    /// otherwise. Never the most recently written one by default: several Claudes often share a directory, and a Claude just
    /// started has no record yet, so that guess showed another session's whole conversation. A record another tab already
    /// follows belongs to that tab's Claude.
    static func guess(directory: String, screen: String, excluding taken: Set<URL> = [], roots: [URL] = roots(), now: Date = Date()) -> URL? {
        let folder = folderName(for: directory)
        let candidates = roots.flatMap { root -> [(URL, Date)] in
            let project = root.appendingPathComponent(folder)
            return ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
                .filter { now.timeIntervalSince($0.1) < 48 * 3600 }
        }.sorted { $0.1 > $1.1 }
        let followed = Set(taken.map { $0.resolvingSymlinksInPath().path })
        return candidates.first { !followed.contains($0.0.resolvingSymlinksInPath().path) && (lastPrompt(in: $0.0).map { shows(prompt: $0, on: screen) } ?? false) }?.0
    }

    /// Whether the screen shows this prompt where Claude draws the user's turns: a line starting "❯ " (or "> ") at the edge, with
    /// the lines it wraps onto. Anywhere else the words prove nothing: Claude's welcome lists recent conversations, a reply may
    /// quote them, and a short prompt ("sí") is in almost any screen.
    static func shows(prompt: String, on screen: String) -> Bool {
        let key = String(prompt.filter { !$0.isWhitespace }.prefix(120))
        guard !key.isEmpty else { return false }
        var blocks: [String] = [], current: String?
        for line in screen.components(separatedBy: "\n") {
            let indent = line.prefix(while: \.isWhitespace).count
            let text = line.trimmingCharacters(in: .whitespaces)
            if indent <= 1, text.hasPrefix("❯ ") || text.hasPrefix("> ") {
                if let block = current { blocks.append(block) }
                current = String(text.dropFirst(2))
            } else if let block = current, !text.isEmpty, indent >= 2 || !opensSomethingElse(text) {
                // Wrapped lines go on indented, or at the edge when the terminal wrapped them (Terminal hands its rows back
                // as they are drawn).
                current = block + text
            } else if let block = current {
                blocks.append(block); current = nil
            }
        }
        if let block = current { blocks.append(block) }
        return blocks.contains { $0.filter { !$0.isWhitespace }.hasPrefix(key) }
    }

    /// A line at the edge that starts a reply, a tool line, a status, the input box or another prompt, never the rest of one.
    private static func opensSomethingElse(_ text: String) -> Bool {
        // By scalar, so "⏺️" (with its emoji selector) is "⏺".
        guard let first = text.unicodeScalars.first else { return true }
        let marks: Set<Unicode.Scalar> = ["⏺", "●", "⎿", "❯", ">", "›", "※", "✻", "✶", "✳", "✢", "✽", "·", "─", "━", "═", "╭", "╰", "│", "┌", "└", "▔", "▁"]
        return marks.contains(first)
    }

    /// The latest real prompt near the end of a record. A guess runs every few seconds for a tab whose record isn't found yet and reads
    /// every recent record of its folder; a record that didn't change since is answered from `promptCache` instead of read again.
    static func lastPrompt(in url: URL, tailBytes: UInt64 = 400_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = url.path + "#\(tailBytes)"
        promptLock.lock()
        let cached = promptCache[key]
        promptLock.unlock()
        if let cached, cached.size == size, cached.modified == modified { return cached.prompt }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let prompt: String? = autoreleasepool {
            var renderer = TranscriptRenderer()
            String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { renderer.consume(String($0)) }
            // A "!" command shows on Claude's screen as "! …", never as a prompt: it can't tell which record a screen shows.
            return renderer.committed.components(separatedBy: "\n").last { $0.hasPrefix("> ") && $0 != "> [Imagen]" && !$0.hasPrefix("> ! ") }.map { String($0.dropFirst(2)) }
        }
        promptLock.lock()
        // A few dozen records at most are recent at once; past that the cache starts over rather than grow.
        if promptCache.count >= 64 { promptCache.removeAll() }
        promptCache[key] = (size, modified, prompt)
        promptLock.unlock()
        return prompt
    }
    private static let promptLock = NSLock()
    nonisolated(unsafe) private static var promptCache: [String: (size: UInt64, modified: Date?, prompt: String?)] = [:]

    /// The working directory of the Claude process on a terminal, from `ps` and `lsof`.
    static func claudeDirectory(tty: String) -> String? {
        guard let pid = claudePID(tty: tty), let output = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).1 else { return nil }
        return output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// The Claude process on a terminal (the newest, if several), from `ps`.
    static func claudePID(tty: String) -> Int32? {
        guard let list = try? Shell.run("/bin/ps", ["-t", (tty as NSString).lastPathComponent, "-o", "pid=,comm="]).1 else { return nil }
        return claudePID(ps: list)
    }

    /// Rows of `ps -o pid=,comm=`. `ps` pads a short pid with spaces ("  7177 claude"), which a split at the first space once lost.
    static func claudePID(ps list: String) -> Int32? {
        list.split(separator: "\n").compactMap { row -> Int32? in
            let parts = row.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && (parts[1] as NSString).lastPathComponent == "claude" ? Int32(parts[0]) : nil
        }.last
    }

    /// When a process started, from the kernel; nil when there is no such process.
    static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
