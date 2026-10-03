import Foundation

/// Claude Code's own record of a conversation (one JSON object per line), turned into the mirror's
/// text. In fullscreen rendering Claude keeps the conversation on the terminal's alternate screen, so
/// Terminal only holds what is visible; the record always holds all of it. The format follows the
/// terminal's look ("> " prompts, "⏺ " replies and tool calls, "  ⎿  " results) so the mirror's
/// per-voice styling, scrolling and copying work unchanged.
struct TranscriptRenderer {
    /// Finished entries; only ever appended, so the mirror grows at its end.
    private(set) var committed = ""
    /// Tool calls still waiting for their result, drawn after the committed text.
    private var pending: [(id: String, line: String)] = []
    private(set) var recap: String?
    /// Skills Claude listed for this session (name → description), and the commands it ran.
    private(set) var skills: [String: String] = [:] { didSet { if skills != oldValue { commandsVersion += 1 } } }
    private(set) var usedCommands: Set<String> = [] { didSet { if usedCommands != oldValue { commandsVersion += 1 } } }
    private(set) var commandsVersion = 0
    /// The subagents this session launched and how they ended.
    private(set) var agents = TranscriptAgents()
    var cwd: String?
    /// A subagent's own record is all sidechain entries; the main record's sidechain is skipped.
    var includeSidechain = false
    /// Older text is dropped in large steps once the record grows past this many UTF-16 units.
    var limit = 240_000

    var text: String {
        guard !pending.isEmpty else { return committed }
        return committed + pending.map { $0.line + "\n  ⎿  …" }.joined(separator: "\n\n") + "\n\n"
    }

    mutating func identifyAgents(_ ids: [String: String]) { agents.identify(ids) }

    mutating func consume(_ line: String) {
        guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if entry["isSidechain"] as? Bool == true, !includeSidechain { return }
        if cwd == nil, let directory = entry["cwd"] as? String { cwd = directory }
        if line.contains("<task-notification>") || line.contains("[Subagent hand-back]") { agents.notice(line, at: TranscriptAgents.date(entry)) }
        switch entry["type"] as? String {
        case "user": consumeUser(entry)
        case "assistant": consumeAssistant(entry)
        case "system":
            // Claude's session recap, shown by Nook's Resumen button rather than in the chat.
            if entry["subtype"] as? String == "away_summary", let content = entry["content"] as? String, !content.isEmpty { recap = content }
        case "attachment":
            // Later listings only add skills, so they join the first one.
            guard let listing = entry["attachment"] as? [String: Any], listing["type"] as? String == "skill_listing" else { return }
            skills.merge(SlashCatalog.skills(listing: listing["content"] as? String ?? "", names: listing["names"] as? [String] ?? [])) { _, new in new }
        default: break
        }
    }

    private mutating func consumeUser(_ entry: [String: Any]) {
        guard let message = entry["message"] as? [String: Any] else { return }
        if let text = message["content"] as? String {
            if entry["isMeta"] as? Bool != true { prompt(text) }
            return
        }
        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": if entry["isMeta"] as? Bool != true, let text = block["text"] as? String { prompt(text) }
            case "image": if entry["isMeta"] as? Bool != true { append("> [Imagen]") }
            case "tool_result": result(block, at: TranscriptAgents.date(entry), details: entry["toolUseResult"] as? [String: Any])
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
                pending.append((block["id"] as? String ?? UUID().uuidString, "⏺ \(name)(\(Self.summary(of: input, cwd: cwd)))"))
            default: break   // thinking stays private to Claude's own view
            }
        }
    }

    /// A real prompt; messages Claude Code injects (task notifications, reminders, command records) are not the user's.
    private mutating func prompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let tag = trimmed.range(of: #"^<([a-zA-Z_-]+)"#, options: .regularExpression) {
            let name = trimmed[tag].dropFirst()
            // A slash command is recorded as tags; it shows the way it was typed.
            if name == "command-name" || name == "command-message",
               let command = trimmed.range(of: #"(?<=<command-name>)[^<]+"#, options: .regularExpression) {
                let args = trimmed.range(of: #"(?<=<command-args>)[^<]+"#, options: .regularExpression).map { " " + trimmed[$0] } ?? ""
                let typed = String(trimmed[command]).trimmingCharacters(in: .whitespaces)
                let name = typed.hasPrefix("/") ? String(typed.dropFirst()) : typed
                if SlashCatalog.isName(name) { usedCommands.insert(name) }
                return append("> " + (typed.hasPrefix("/") ? typed : "/" + typed) + args)
            }
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
        if let id { agents.result(call: id, text: body, error: block["is_error"] as? Bool == true, at: date) }
        // An edit or a new file shows its lines, as Claude draws them, instead of the tool's message.
        if block["is_error"] as? Bool != true, let details, let change = Self.change(details, cwd: cwd) {
            return append((call.map { $0 + "\n" } ?? "") + change)
        }
        var lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let more = max(0, lines.count - 3)
        lines = Array(lines.prefix(3)).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
        if block["is_error"] as? Bool == true, !lines.isEmpty { lines[0] = "Error: " + lines[0] }
        if lines.isEmpty { lines = ["(sin salida)"] }
        if more > 0 { lines.append("… +\(more) líneas") }
        let shown = "  ⎿  " + lines.joined(separator: "\n     ")
        append((call.map { $0 + "\n" } ?? "") + shown)
    }

    private mutating func append(_ block: String) {
        committed += block + "\n\n"
        let length = (committed as NSString).length
        guard length > limit else { return }
        // Trimmed at an entry boundary, three quarters at a time, so the mirror's start rarely moves.
        let ns = committed as NSString
        let cut = ns.range(of: "\n\n", range: NSRange(location: length - limit * 3 / 4, length: limit * 3 / 4)).location
        committed = cut == NSNotFound ? "" : ns.substring(from: cut + 2)
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
    /// Text read while the chat was hidden (collapsed island), not handed to the session yet.
    var unshown = false
    private lazy var watch = SubagentWatch(record: url)

    /// The subagent whose conversation is being read (its launch's call id), and its record's follower.
    private var viewing: (call: String, follower: TranscriptFollower?)?

    /// One subagent's own record, once Claude has named the agent.
    func agentRecord(call: String) -> URL? {
        if renderer.agents.launches.contains(where: { $0.call == call && $0.agentID == nil }) { renderer.identifyAgents(watch.metadata()) }
        guard let id = renderer.agents.launches.first(where: { $0.call == call })?.agentID else { return nil }
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
    init(url: URL, initialBytes: UInt64 = 3_000_000, headBytes: Int = 1_000_000, sidechain: Bool = false) {
        self.url = url
        renderer.includeSidechain = sidechain
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
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        offset += UInt64(data.count)
        partial.append(data)
        if skipToLineStart, let newline = partial.firstIndex(of: 0x0A) {
            partial = Data(partial[(newline + 1)...]); skipToLineStart = false
        }
        let before = renderer.text
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
            partial = Data(partial[(newline + 1)...])
            renderer.consume(line)
        }
        let after = renderer.text
        return after == before ? nil : after
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

    /// Without hooks: the records of the tab's working directory, preferring the one whose latest
    /// prompt is on screen, else the most recently written.
    static func guess(directory: String, screen: String, roots: [URL] = roots(), now: Date = Date()) -> URL? {
        let folder = folderName(for: directory)
        let candidates = roots.flatMap { root -> [(URL, Date)] in
            let project = root.appendingPathComponent(folder)
            return ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
                .filter { now.timeIntervalSince($0.1) < 48 * 3600 }
        }.sorted { $0.1 > $1.1 }
        if let match = candidates.first(where: { lastPrompt(in: $0.0).map { MessageEcho.appears($0, in: screen) } ?? false }) { return match.0 }
        return candidates.first?.0
    }

    /// The latest real prompt near the end of a record.
    static func lastPrompt(in url: URL, tailBytes: UInt64 = 400_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        var renderer = TranscriptRenderer()
        String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { renderer.consume(String($0)) }
        return renderer.committed.components(separatedBy: "\n").last { $0.hasPrefix("> ") && $0 != "> [Imagen]" }.map { String($0.dropFirst(2)) }
    }

    /// The working directory of the Claude process on a terminal, from `ps` and `lsof`.
    static func claudeDirectory(tty: String) -> String? {
        let device = (tty as NSString).lastPathComponent
        guard let list = try? Shell.run("/bin/ps", ["-t", device, "-o", "pid=,comm="]).1 else { return nil }
        guard let pid = list.split(separator: "\n").compactMap({ row -> String? in
            let parts = row.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 && (parts[1] as NSString).lastPathComponent == "claude" ? parts[0] : nil
        }).last else { return nil }
        guard let output = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]).1 else { return nil }
        return output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
