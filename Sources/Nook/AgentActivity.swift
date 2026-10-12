import Foundation

/// One subagent (or a message to another agent) that Claude Code showed in a session's conversation.
struct SubagentActivity: Identifiable, Equatable {
    enum State: String { case running, done, failed }
    enum Role: String { case agent, message }

    /// Stable across screen refreshes: it comes from the description, never from the position on screen.
    var id: String
    var role: Role = .agent
    /// What the agent was asked to do, as Claude prints it ("Design cat pet animations").
    var name: String
    /// The agent type when Claude shows one ("Explore", "general-purpose").
    var kind: String?
    var state: State
    /// Launched in the background: it keeps working while Claude answers other things.
    var background = false
    var toolUses: Int?
    /// As Claude prints it ("41.2k").
    var tokens: String?
    /// As Claude prints it ("3m 12s").
    var duration: String?
    /// Extra word for endings that are not a plain "Done" ("Interrumpido").
    var note: String?
    /// The model it runs on ("sonnet"), when the launch named one.
    var model: String?
    /// The tool call it is running right now ("Read(Sources/Nook/Pet.swift)"), from its own record.
    var activity: String?
    /// The name the launch gave it ("designer"), which Claude's list under the mode line may show instead of its type.
    var alias: String?

    var isRunning: Bool { state == .running }

    /// Counters in Spanish, "23 herramientas · 41.2k tokens · 3m 12s", or a short state word when Claude printed none.
    var detail: String {
        var parts: [String] = []
        if let toolUses { parts.append(toolUses == 1 ? "1 herramienta" : "\(toolUses) herramientas") }
        if let tokens { parts.append("\(tokens) tokens") }
        if let duration { parts.append(duration) }
        if state == .failed, let note { parts.insert(note, at: 0) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch state {
        case .running: return background ? "En segundo plano" : "Iniciando…"
        case .done: return role == .message ? "Enviado" : "Listo"
        case .failed: return note ?? "Falló"
        }
    }
}

/// How many agents are in each state; messages to other agents are not counted.
struct SubagentSummary: Equatable {
    var running = 0
    var done = 0
    var failed = 0
    var total: Int { running + done + failed }

    init(_ activities: [SubagentActivity]) {
        for activity in activities where activity.role == .agent {
            switch activity.state {
            case .running: running += 1
            case .done: done += 1
            case .failed: failed += 1
            }
        }
    }
}

/// Reads Claude Code's own screen text and finds the subagents it launched.
///
/// Every wording below was read from Claude Code 2.1.287's own renderer, except the ones marked "unverified".
/// All of them are anchored to the left edge of the screen, where Claude draws its tool calls; replies and code
/// are indented, so ordinary conversation never matches. Anything unknown is ignored rather than guessed. To adjust
/// a wording, change the patterns in `Patterns`.
///
/// - `⏺ Agent(description)` / `⏺ Task(description)` / `⏺ Explore(description)`: one subagent (the name is the
///   agent type, "Agent" for the general-purpose one). Its result lines follow, indented: `⎿  Initializing…`, up to
///   three nested tool lines and `… +5 tool uses (ctrl+o to expand)`, then `⎿  Backgrounded agent (↓ to manage ·
///   ctrl+o to expand)` or `⎿  Done (23 tool uses · 41.2k tokens · 3m 12s)` or `⎿  Interrupted · What should
///   Claude do instead?`. A failure line starting with `Error` is unverified.
/// - `⏺ Running 3 agents…` / `⏺ 3 Explore agents finished` / `⏺ 3 background agents launched`: parallel agents,
///   one `├─ description · 5 tool uses · 12k tokens` row each, with `│  ⎿  Done` (or `Initializing…`, or the last
///   tool) under it. Background launches have no second line.
/// - A background agent's completion arrives later; `Agent "description" completed` / `was stopped by the user`
///   is unverified (Claude sends that text to the model; how the screen shows it is not known).
/// - The mode line's `N background` pill and `Waiting for N background agents to finish` cap how many
///   background agents can still be running, which retires ones whose completion line was never seen.
enum AgentActivity {
    /// The newest lines considered; older history cannot be a running agent worth showing.
    static let maxLines = 700
    /// The most agents returned; running ones win over finished ones.
    static let limit = 6
    /// Messages to other agents are context only; the newest few are kept.
    static let messageLimit = 2

    /// Tool names that always mean a subagent.
    static let agentTools: Set<String> = ["Task", "Agent"]
    /// Agent types Claude Code ships; their name alone proves a subagent. Any other name needs evidence in its result lines.
    static let knownKinds: Set<String> = ["Explore", "Plan", "general-purpose", "statusline-setup", "claude-code-guide", "output-style-setup"]

    /// The subagents visible in `rawText`, oldest first, without repeats. Works on the whole screen (the mode line
    /// at the bottom is used when present) or on the conversation alone. Returns `[]` when there is nothing.
    static func parse(_ rawText: String) -> [SubagentActivity] {
        var raw = lastLines(rawText, maxLines).map(String.init)
        // The list under the mode line is live: it is read apart and has the last word on the agents it names.
        let tree = treeRows(raw)
        if let tree { raw.removeSubrange(tree.start...) }
        var scan = Scan(lines: raw.map { Line(Substring($0)) })
        scan.run()
        scan.retireStaleBackground()
        scan.retireFinishedForeground()
        if let tree { scan.apply(tree: tree.agents) }
        return scan.result()
    }

    // MARK: - The list under the mode line

    /// The agents in the list Claude draws under its mode line while agents run ("← for agents · ↓ to manage"), in its
    /// order; nil when the screen does not end with that list. Their names repeat ("fork", "coder") and say what kind of
    /// agent they are; `activity` is Claude's own words for what each does now. The ids are positions in the list.
    static func tree(_ text: String) -> [SubagentActivity]? {
        treeRows(lastLines(text, 80).map(String.init))?.agents
    }

    /// The last `count` lines of `text`, the same as `split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    /// .suffix(count)`, without splitting a whole screen (80,000 characters, every reading) to keep its end.
    static func lastLines(_ text: String, _ count: Int) -> ArraySlice<Substring> {
        var start = text.endIndex, breaks = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isNewline {
                breaks += 1
                if breaks == count { break }
            }
            start = previous
        }
        return text[start...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).suffix(count)
    }

    /// `text` without that list, for anything that shows the conversation (and the blank lines that led to it).
    static func withoutTree(_ text: String) -> String {
        // Only the end can hold the list: the last 80 lines are split, not a long mirror.
        var head = text.endIndex
        var count = 0
        while head > text.startIndex, count < 80 {
            head = text.index(before: head)
            if text[head] == "\n" { count += 1 }
        }
        if count == 80 { head = text.index(after: head) }
        var lines = text[head...].components(separatedBy: "\n")
        guard let tree = treeRows(lines) else { return text }
        lines.removeSubrange(tree.start...)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var kept = String(text[..<head]) + lines.joined(separator: "\n")
        while let last = kept.last, last.isWhitespace { kept.removeLast() }
        return kept
    }

    /// Agents from Claude's record (`agents`, named by what they were asked) with the list's live words: a row updates the
    /// running agent it names (same name, or same kind in launch order) with what it does now, its time and tokens, and a
    /// row no agent matches is added. Without a list the record's agents come back as they are.
    static func merged(_ agents: [SubagentActivity], tree: [SubagentActivity]?) -> [SubagentActivity] {
        guard let tree, !tree.isEmpty else { return agents }
        var result = agents
        var taken = Set<Int>()
        for row in tree {
            let key = Scan.key(row.name)
            // Only the record's agents: two rows of the list are two agents, even with one name.
            let candidates = agents.indices.filter { !taken.contains($0) && result[$0].role == .agent }
            func names(_ agent: SubagentActivity) -> Bool {
                Scan.key(agent.name) == key || agent.kind.map(Scan.key) == key || agent.alias.map(Scan.key) == key
            }
            // A running agent of that name first, in launch order; then the newest one the record thinks finished (it was
            // woken up again), so a row with a record behind it opens that record.
            let match = candidates.first { names(result[$0]) && result[$0].isRunning } ?? candidates.last { names(result[$0]) }
            guard let position = match else { result.append(row); continue }
            taken.insert(position)
            if let activity = row.activity { result[position].activity = activity }
            if let tokens = row.tokens { result[position].tokens = tokens }
            if let duration = row.duration { result[position].duration = duration }
            // The list is live: what it says now wins over the record.
            if result[position].state != row.state { result[position].state = row.state; if row.state == .running { result[position].note = nil } }
        }
        return result
    }

    /// One line of the list: `⏺ main` (the main conversation), an agent's row (`○ fork  Reading NotchController…
    /// 4m 56s · ↓ 187.3k tokens`), or, on a narrow screen, the counters that wrapped onto a line of their own at the edge.
    private enum TreeLine {
        case main
        case agent(glyph: Character?, name: String, activity: String?, detail: Detail)
        case counters(Detail)
        case more
    }

    private static func treeLine(_ raw: String) -> TreeLine? {
        guard raw.prefix(while: \.isWhitespace).count <= 6 else { return nil }
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty, text.count <= 400 else { return nil }
        if let detail = counters(String(text)) { return .counters(detail) }
        if Patterns.treeMore.matches(String(text)) { return .more }
        // With the list focused the row under the cursor gains "❯" in front of its own mark.
        if text.first == "❯", text.dropFirst().first?.isWhitespace == true { text = text.dropFirst().drop(while: \.isWhitespace) }
        // A status mark in front ("○", "⏺", "✓"), one character and a space.
        var glyph: Character?
        if let first = text.first, !first.isLetter, !first.isNumber, !"@_(\"'`[".contains(first) {
            let rest = text.dropFirst()
            guard rest.first?.isWhitespace == true else { return nil }
            glyph = first
            text = rest.drop(while: \.isWhitespace)
        }
        var parts = String(text).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let name = parts.first, name.count <= 40, let lead = name.first, lead.isLetter || lead == "@", !name.contains(" · ") else { return nil }
        if name.lowercased() == "main" { return parts.count == 1 || counters(parts.dropFirst().joined(separator: "  ")) != nil ? .main : nil }
        parts.removeFirst()
        var detail = Detail()
        if let last = parts.last, let found = counters(last) { detail = found; parts.removeLast() }
        // Only the mark or the counters make it a row of the list rather than a stray line of text.
        guard glyph != nil || detail.isSet, parts.count <= 1 else { return nil }
        return .agent(glyph: glyph, name: name, activity: parts.first, detail: detail)
    }

    /// "4m 56s · ↓ 187.3k tokens": nothing but counters.
    private static func counters(_ text: String) -> Detail? {
        let segments = Detail.segments(of: text.trimmingCharacters(in: .whitespaces))
        var detail = Detail()
        detail.absorb(segments)
        let known = segments.allSatisfy { segment in
            let value = segment.trimmingCharacters(in: .whitespaces)
            return Patterns.toolUses.matches(value) || Patterns.tokens.matches(value) || Patterns.duration.matches(value)
        }
        return known && detail.isSet ? detail : nil
    }

    /// Where the list starts in `lines` and its agents, when the screen ends with it. `ClaudeAgentTree` says what the list is
    /// (its "⏺ main" right under Claude's box, mode line or "↑/↓ to select"); this reads its rows. A line no row shape fits is
    /// passed over: it is still the list's, the chat drops it all the same.
    private static func treeRows(_ lines: [String]) -> (start: Int, agents: [SubagentActivity])? {
        guard let range = ClaudeAgentTree.range(in: lines) else { return nil }
        var agents: [SubagentActivity] = []
        for line in lines[range] where !line.trimmingCharacters(in: .whitespaces).isEmpty && !ClaudeAgentTree.isMainRow(line) {
            switch treeLine(line) {
            case nil, .main?, .more?: continue
            case .counters(let detail)?:
                // Counters that wrapped belong to the row above them.
                guard let last = agents.indices.last, agents[last].tokens == nil, agents[last].duration == nil else { continue }
                agents[last].toolUses = detail.toolUses; agents[last].tokens = detail.tokens; agents[last].duration = detail.duration
            case .agent(let glyph, let name, let activity, let detail)?:
                var agent = SubagentActivity(id: "tree:\(agents.count)", name: name, state: treeState(glyph: glyph, activity: activity))
                agent.kind = name
                agent.activity = activity
                agent.toolUses = detail.toolUses; agent.tokens = detail.tokens; agent.duration = detail.duration
                agents.append(agent)
            }
        }
        return (range.lowerBound, agents)
    }

    private static func treeState(glyph: Character?, activity: String?) -> SubagentActivity.State {
        let words = activity?.lowercased() ?? ""
        let failed = glyph.map { "✗✘×".contains($0) } == true || ["failed", "error", "stopped", "killed"].contains { words.hasPrefix($0) }
        let done = glyph.map { "✓✔".contains($0) } == true || ["done", "completed", "finished"].contains { words.hasPrefix($0) }
        return failed ? .failed : (done ? .done : .running)
    }

    // MARK: - Patterns

    private enum Patterns {
        /// ⏺ on macOS, ● elsewhere. Compared by scalar so a trailing variation selector does not matter.
        static let bullets: Set<Unicode.Scalar> = ["\u{23FA}", "\u{25CF}"]
        static let glyphs: Set<Character> = ["│", "├", "└", "─", "⎿", "┃", "╰", "╭"]
        static let ruleCharacters: Set<Character> = ["─", "━", "═", "╌", "┄"]

        /// `Name(args…`: the closing parenthesis may be cut off with the description.
        static let toolCall = Rx(#"^([A-Za-z][A-Za-z0-9_:.-]*)\((.*)$"#)
        static let group = Rx(#"^(Running\s+)?(\d+)\s+(?:(?!background\b)([A-Za-z][\w:.-]*)\s+)?(background\s+)?agents?\b\s*(finished|launched|…|\.\.\.)?"#)
        static let notification = Rx(#"^(?:Background\s+)?(?:Agent|Task|agent|task)\s+["“](.+?)["”]\s+(completed|finished|failed|errored|was stopped|was killed|stopped|killed)"#)
        static let groupRowType = Rx(#"^([A-Za-z@][\w:.-]*)\s+\((.*)\)$"#)
        static let recipient = Rx(#"(?:to|recipient)\s*[:=]\s*["']?([A-Za-z0-9_@.:-]+)"#)

        static let done = Rx(#"^Done\b\s*(?:\((.*)\))?"#)
        static let failure = Rx(#"^(?:Error|Failed|API Error|Agent failed|Request failed|Tool use error)\b"#)
        static let interrupted = Rx(#"^Interrupted\b"#)
        static let backgrounded = Rx(#"^Backgrounded agent"#)
        /// Bash prints this too for its background commands, so it never proves an agent by itself.
        static let runsInBackground = Rx(#"^Running in the background"#)
        static let initializing = Rx(#"^Initializing…"#)
        /// "… +5 tool uses (ctrl+o to expand)"; older builds wrote "+5 more tool uses".
        static let moreToolUses = Rx(#"^(?:…|\.\.\.)?\s*\+\d+ (?:more )?tool uses?"#)
        static let progress = Rx(#"^In progress…"#)
        static let agentDone = Rx(#"^Done\s*\(.*\d+ tool uses?\b"#)

        static let toolUses = Rx(#"^(\d+) tool uses?$"#)
        static let tokens = Rx(#"^[↓↑]?\s*(\d[\d.,]*[kKmMbB]?) tokens?$"#)
        static let duration = Rx(#"^\d+(?:\.\d+)?[hms](?:\s+\d+(?:\.\d+)?[hms])*$"#)

        static let waiting = Rx(#"Waiting for (\d+) background agents?"#)
        /// "+3 more", "… and 2 more agents": the list says it has more rows than it shows.
        static let treeMore = Rx(#"^(?:…|\.\.\.)?\s*(?:and\s+)?\+?\d+ more\b"#)
        static let pill = Rx(#"\b(\d+) (?:background|bg|local agents?|cloud sessions?|shells?|monitors?|teams?|tasks?)\b"#)
        static let turnLine = Rx(#"^(?:[A-Z][a-z]+ed|Worked) for \d|^Waiting for \d+ background"#)
        static let footerMarkers = ["⏵", "shift+tab", "for shortcuts", "to interrupt", "ctrl+t", "for agents", "bypass permissions", "auto mode", "plan mode", "accept edits"]
    }

    // MARK: - Lines

    private struct Line {
        let text: String
        let indent: Int

        init(_ raw: Substring) {
            indent = raw.prefix(while: \.isWhitespace).count
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var isBlank: Bool { text.isEmpty }
        /// Claude draws its tool calls and spinner at the left edge; replies and code are indented.
        var isEdge: Bool { indent <= 1 }
        /// The text without tree and result glyphs: "│  ⎿  Done" becomes "Done".
        var body: String { String(text.drop(while: { Patterns.glyphs.contains($0) || $0.isWhitespace })) }
    }

    private static func isRule(_ text: String) -> Bool {
        guard text.count >= 20, let first = text.first, Patterns.ruleCharacters.contains(first) else { return false }
        return Double(text.filter { Patterns.ruleCharacters.contains($0) }.count) / Double(text.count) >= 0.75
    }

    // MARK: - Counters

    private struct Detail {
        var toolUses: Int?
        var tokens: String?
        var duration: String?

        var isSet: Bool { toolUses != nil || tokens != nil || duration != nil }

        /// Reads "23 tool uses · 41.2k tokens · 3m 12s" in any order, ignoring segments it does not know.
        mutating func absorb(_ segments: [String]) {
            for segment in segments.map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if let match = Patterns.toolUses.groups(in: segment), let count = match[1].flatMap(Int.init) { toolUses = count }
                else if let match = Patterns.tokens.groups(in: segment), let value = match[1] { tokens = value }
                else if Patterns.duration.matches(segment) { duration = segment }
            }
        }

        static func segments(of text: String) -> [String] { text.components(separatedBy: " · ") }
    }

    // MARK: - Scan

    private struct Entry {
        var activity: SubagentActivity
        var key: String
        var truncated: Bool
        /// No `Done`, error or completion line seen yet.
        var unresolved: Bool
        /// Index just past the lines that belong to the agent.
        var blockEnd: Int
    }

    private struct Scan {
        let lines: [Line]
        var entries: [Entry] = []
        /// The last line that proves Claude moved on: a reply or the user's own message.
        var lastProse = -1

        init(lines: [Line]) { self.lines = lines }

        mutating func run() {
            var index = 0
            while index < lines.count {
                let line = lines[index]
                guard line.isEdge, !line.isBlank else { index += 1; continue }
                if isUserEcho(index) { lastProse = index; index += 1; continue }
                let hasBullet = line.text.unicodeScalars.first.map(Patterns.bullets.contains) ?? false
                let content = hasBullet ? String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces) : line.text
                if let found = Patterns.notification.groups(in: content), let name = found[1], let word = found[2] {
                    resolve(name: name, word: word)
                    index += 1
                    continue
                }
                guard hasBullet else { index += 1; continue }
                let end = blockEnd(after: index)
                if let call = Patterns.toolCall.groups(in: content), let tool = call[1] {
                    handleCall(tool: tool, arguments: call[2] ?? "", at: index, end: end)
                } else if let group = Patterns.group.groups(in: content), handleGroup(group, at: index, end: end) {
                    // Rows were taken from the block.
                } else if !Patterns.turnLine.matches(content) {
                    lastProse = index
                }
                index = max(index + 1, end)
            }
        }

        /// The indented lines that follow a tool call: its results, nested tool lines and tree rows.
        func blockEnd(after index: Int) -> Int {
            var end = index + 1
            while end < lines.count, !lines[end].isBlank, lines[end].indent >= 2 { end += 1 }
            return end
        }

        /// A line the user typed into the conversation: "❯ text" with no input box rule just above it.
        func isUserEcho(_ index: Int) -> Bool {
            let text = lines[index].text
            guard text.count > 2, let mark = text.first, mark == "❯" || mark == ">", text.dropFirst().first == " " else { return false }
            if text.dropFirst().drop(while: { $0 == " " }).range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil { return false }
            guard let previous = lines[..<index].last(where: { !$0.isBlank }) else { return true }
            return !AgentActivity.isRule(previous.text)
        }

        // MARK: Single agents

        mutating func handleCall(tool: String, arguments: String, at index: Int, end: Int) {
            if tool == "SendMessage" { addMessage(arguments: arguments, end: end); return }
            let block = lines[(index + 1)..<end]
            let facts = Facts(block: block)
            let isAgent = AgentActivity.agentTools.contains(tool) || AgentActivity.knownKinds.contains(tool) || facts.evidence
            // Any other tool (Read, Bash, Edit…) is ordinary conversation.
            guard isAgent else { return }
            let description = Scan.clean(arguments, closingParenthesis: true)
            var activity = SubagentActivity(id: "", name: description.text.isEmpty ? "Agente" : description.text, state: facts.state)
            if !AgentActivity.agentTools.contains(tool) { activity.kind = tool }
            activity.background = facts.background
            activity.toolUses = facts.detail.toolUses; activity.tokens = facts.detail.tokens; activity.duration = facts.detail.duration
            activity.note = facts.note
            upsert(activity, truncated: description.truncated, unresolved: !facts.resolved, end: end)
        }

        /// What a block's result lines say about the agent.
        private struct Facts {
            var state: SubagentActivity.State = .running
            var resolved = false
            var background = false
            var evidence = false
            var detail = Detail()
            var note: String?

            init(block: ArraySlice<Line>) {
                for line in block {
                    let body = line.body
                    if let done = Patterns.done.groups(in: body) {
                        state = .done; resolved = true
                        if let inside = done[1] { detail.absorb(Detail.segments(of: inside)) }
                        if Patterns.agentDone.matches(body) { evidence = true }
                    } else if Patterns.interrupted.matches(body) {
                        state = .failed; resolved = true; note = "Interrumpido"
                    } else if Patterns.failure.matches(body) {
                        state = .failed; resolved = true; note = "Con error"
                    } else if Patterns.backgrounded.matches(body) {
                        background = true; evidence = true
                    } else if Patterns.runsInBackground.matches(body) {
                        background = true
                    } else if Patterns.initializing.matches(body) || Patterns.moreToolUses.matches(body) {
                        evidence = true
                    } else if Patterns.progress.matches(body) {
                        evidence = true
                        detail.absorb(Detail.segments(of: body))
                    }
                }
            }
        }

        // MARK: Parallel agents

        /// `⏺ Running 3 agents…` followed by `├─ description · 5 tool uses · 12k tokens` rows. Returns false
        /// when no row follows, so a reply that merely starts with "3 agents" stays ordinary text.
        mutating func handleGroup(_ group: [String?], at index: Int, end: Int) -> Bool {
            let running = group[1] != nil
            let word = group[5] ?? ""
            let finished = word == "finished"
            let launched = word == "launched" || group[4] != nil
            guard running || finished || launched else { return false }
            let headerKind = group[3]
            let block = Array(lines[(index + 1)..<end])
            let rowStarts = block.indices.filter { block[$0].text.hasPrefix("├─") || block[$0].text.hasPrefix("└─") }
            guard !rowStarts.isEmpty else { return false }
            for (position, start) in rowStarts.enumerated() {
                let stop = position + 1 < rowStarts.count ? rowStarts[position + 1] : block.count
                let sub = block[(start + 1)..<stop]
                let facts = Facts(block: sub)
                var segments = Detail.segments(of: String(block[start].text.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                let label = Scan.clean(segments.removeFirst())
                var detail = facts.detail
                detail.absorb(segments)
                var name = label.text
                var kind = headerKind
                if let typed = Patterns.groupRowType.groups(in: name), let type = typed[1], let inside = typed[2] {
                    kind = type == "Agent" ? nil : type
                    name = inside
                }
                var state = facts.state
                var resolved = facts.resolved
                if finished && !resolved { state = .done; resolved = true }
                var activity = SubagentActivity(id: "", name: name.isEmpty ? "Agente" : name, state: state)
                activity.kind = kind
                activity.background = launched && !resolved
                activity.toolUses = detail.toolUses; activity.tokens = detail.tokens; activity.duration = detail.duration
                activity.note = facts.note
                upsert(activity, truncated: label.truncated, unresolved: !resolved, end: end)
            }
            return true
        }

        // MARK: Messages

        mutating func addMessage(arguments: String, end: Int) {
            let cleaned = Scan.clean(arguments, closingParenthesis: true)
            var target = Patterns.recipient.groups(in: cleaned.text)?[1]
            if target == nil { target = cleaned.text.split(separator: " ").first.map(String.init) }
            guard let target, !target.isEmpty else { return }
            let name = target.hasPrefix("@") ? target : "@" + target
            var activity = SubagentActivity(id: "", name: name, state: .done)
            activity.role = .message
            upsert(activity, truncated: false, unresolved: false, end: end, keyPrefix: "msg:")
        }

        // MARK: Completion notices

        /// `Agent "description" completed`: closes the matching agent seen earlier.
        mutating func resolve(name: String, word: String) {
            let candidate = Scan.clean(name)
            let key = Scan.key(candidate.text)
            guard let position = entries.lastIndex(where: { $0.activity.role == .agent && Scan.same($0, key: key, truncated: candidate.truncated) }) else { return }
            entries[position].unresolved = false
            if word == "completed" || word == "finished" {
                entries[position].activity.state = .done
            } else {
                entries[position].activity.state = .failed
                entries[position].activity.note = word.contains("stopped") || word.contains("killed") ? "Detenido" : "Con error"
            }
        }

        // MARK: Dedupe

        /// Claude redraws a block as it changes, and scrolled-off frames stay in the history: the same agent
        /// shows up several times, and the newest sighting is the truth.
        mutating func upsert(_ activity: SubagentActivity, truncated: Bool, unresolved: Bool, end: Int, keyPrefix: String = "") {
            let key = keyPrefix + Scan.key(activity.name)
            var fresh = Entry(activity: activity, key: key, truncated: truncated, unresolved: unresolved, blockEnd: end)
            if let position = entries.firstIndex(where: { $0.activity.role == activity.role && Scan.same($0, key: key, truncated: truncated) }) {
                let old = entries[position]
                // A description cut off with "…" loses to the complete one, whichever came last.
                let keepOld = old.truncated != truncated ? !old.truncated : old.activity.name.count > fresh.activity.name.count
                if keepOld { fresh.activity.name = old.activity.name; fresh.key = old.key; fresh.truncated = old.truncated }
                if fresh.activity.kind == nil { fresh.activity.kind = old.activity.kind }
                fresh.activity.id = fresh.key
                entries[position] = fresh
            } else {
                fresh.activity.id = key
                entries.append(fresh)
            }
        }

        /// Collapses whitespace and notes whether Claude cut the text off with "…". `closingParenthesis` drops the
        /// ")" that ends a `Name(args)` tool call.
        static func clean(_ text: String, closingParenthesis: Bool = false) -> (text: String, truncated: Bool) {
            var value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if closingParenthesis, value.hasSuffix(")") { value.removeLast() }
            value = value.trimmingCharacters(in: .whitespaces)
            let truncated = value.hasSuffix("…") || value.hasSuffix("...")
            return (value, truncated)
        }

        static func key(_ name: String) -> String {
            var value = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for suffix in ["…", "..."] where value.hasSuffix(suffix) { value.removeLast(suffix.count) }
            return value.trimmingCharacters(in: .whitespaces)
        }

        static func same(_ entry: Entry, key: String, truncated: Bool) -> Bool {
            if entry.key == key { return true }
            let (short, long) = entry.key.count <= key.count ? (entry.key, key) : (key, entry.key)
            // Only a description that Claude cut off with "…" may be a prefix of the full one.
            let shortIsCut = entry.key.count <= key.count ? entry.truncated : truncated
            return shortIsCut && short.count >= 8 && long.hasPrefix(short)
        }

        // MARK: Reconciling with the live screen

        /// A foreground agent with no result line is over once Claude has said something else.
        mutating func retireFinishedForeground() {
            for position in entries.indices where entries[position].unresolved && !entries[position].activity.background && lastProse >= entries[position].blockEnd {
                entries[position].activity.state = .done
                entries[position].unresolved = false
            }
        }

        /// Background agents have no result line in place; the bottom of the screen says how many are left.
        mutating func retireStaleBackground() {
            guard let ceiling = backgroundCeiling() else { return }
            let live = entries.indices.filter { entries[$0].unresolved && entries[$0].activity.background && entries[$0].activity.state == .running }
            guard live.count > ceiling else { return }
            for position in live.dropLast(ceiling) {
                entries[position].activity.state = .done
                entries[position].unresolved = false
            }
        }

        /// The most background agents that can be running now, or nil when the screen does not say.
        func backgroundCeiling() -> Int? {
            let tail = lines.suffix(16).filter { !$0.isBlank }
            let waiting = tail.reversed().lazy.filter(\.isEdge).compactMap { Patterns.waiting.groups(in: $0.text)?[1].flatMap(Int.init) }.first
            if let ruleIndex = tail.lastIndex(where: { AgentActivity.isRule($0.text) }) {
                let footer = tail[(ruleIndex + 1)...]
                if footer.contains(where: { line in Patterns.footerMarkers.contains(where: { line.text.contains($0) }) }) {
                    // The mode line is visible: its pill is live, and no pill means nothing runs in the background. Newer
                    // builds drop the pill for "← for agents" and list the agents under it, so there no pill says nothing.
                    if let pill = footer.compactMap({ Patterns.pill.groups(in: $0.text)?[1].flatMap(Int.init) }).first { return pill }
                    return footer.contains { $0.text.contains("for agents") || $0.text.contains("to manage") } ? waiting : 0
                }
            }
            return waiting
        }

        /// The list under the mode line names what runs now: the agents it shows take its words, the background ones it
        /// leaves out are over, and a row that matches nothing seen in the conversation is added.
        mutating func apply(tree: [SubagentActivity]) {
            let shown = AgentActivity.merged(entries.map(\.activity), tree: tree)
            let listed = Set(shown.indices.filter { position in
                position < entries.count && tree.contains { row in
                    let key = Scan.key(row.name)
                    return Scan.key(shown[position].name) == key || shown[position].kind.map(Scan.key) == key
                }
            })
            for position in entries.indices {
                let updated = shown[position]
                if updated != entries[position].activity { entries[position].activity = updated; entries[position].unresolved = updated.isRunning }
                if entries[position].activity.background, entries[position].activity.isRunning, !listed.contains(position) {
                    entries[position].activity.state = .done
                    entries[position].unresolved = false
                }
            }
            for row in shown.dropFirst(entries.count) {
                entries.append(Entry(activity: row, key: "tree:" + Scan.key(row.name) + ":\(entries.count)", truncated: false, unresolved: row.isRunning, blockEnd: lines.count))
            }
        }

        func result() -> [SubagentActivity] {
            var messages = 0
            var candidates: [Int] = []
            for position in entries.indices.reversed() {
                if entries[position].activity.role == .message {
                    messages += 1
                    if messages > AgentActivity.messageLimit { continue }
                }
                candidates.append(position)
            }
            // `candidates` is newest first. Running agents keep their place before finished ones.
            var keep = Set<Int>()
            for position in candidates where entries[position].activity.isRunning && keep.count < AgentActivity.limit { keep.insert(position) }
            for position in candidates where keep.count < AgentActivity.limit { keep.insert(position) }
            return entries.indices.filter(keep.contains).map { entries[$0].activity }
        }
    }
}

/// A compiled pattern with the two questions the parser asks.
private struct Rx {
    let expression: NSRegularExpression

    init(_ pattern: String) {
        // The patterns are constants in this file; a typo shows up in the first test run.
        expression = try! NSRegularExpression(pattern: pattern)
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
