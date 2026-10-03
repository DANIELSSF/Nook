import Foundation

/// The subagents a Claude session launched, read from its record rather than the screen, where their
/// lines scroll away (and, in fullscreen rendering, never stay). The main record says when each one
/// starts and ends; each agent's own record (`<session>/subagents/agent-<id>.jsonl`) says what it is
/// doing meanwhile.
struct TranscriptAgents {
    struct Launch: Equatable {
        /// The `Agent` tool call's id.
        let call: String
        var name: String
        var kind: String?
        var model: String?
        var background: Bool
        /// The agent's own id, from the launch's result or its metadata file; names its record.
        var agentID: String?
        var started: Date?
        var ended: Date?
        var state: SubagentActivity.State = .running
        var note: String?
    }

    private(set) var launches: [Launch] = []

    mutating func launch(call: String, input: [String: Any], at date: Date?) {
        guard !launches.contains(where: { $0.call == call }) else { return }
        let name = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Subagente"
        launches.append(Launch(call: call, name: name, kind: input["subagent_type"] as? String, model: input["model"] as? String,
                               background: input["run_in_background"] as? Bool ?? false, started: date))
        // Long sessions launch many; the finished ones beyond the latest few are history.
        let finished = launches.indices.filter { launches[$0].state != .running }
        if finished.count > 30 { launches.remove(atOffsets: IndexSet(finished.prefix(finished.count - 30))) }
    }

    /// The launch's result: a background agent answers at once with its id and keeps working; any
    /// other ends here.
    mutating func result(call: String, text: String, error: Bool, at date: Date?) {
        guard let index = launches.firstIndex(where: { $0.call == call }) else { return }
        if let id = text.range(of: #"(?<=agentId: )[A-Za-z0-9_-]+"#, options: .regularExpression) {
            launches[index].agentID = String(text[id])
            if text.contains("launched") { launches[index].background = true; return }
        }
        finish(index, state: error ? .failed : .done, note: error ? "Falló" : nil, at: date)
    }

    /// A line of the main record that tells a background agent's end: its task notification or the
    /// report it handed back. Other tasks (background commands) share the format; only known agents count.
    mutating func notice(_ line: String, at date: Date?) {
        if line.contains("<task-notification>"),
           let id = line.range(of: #"(?<=<task-id>)[^<]+"#, options: .regularExpression),
           let status = line.range(of: #"(?<=<status>)[^<]+"#, options: .regularExpression),
           let index = launches.firstIndex(where: { $0.agentID == String(line[id]) }) {
            switch line[status].lowercased() {
            case "completed": finish(index, state: .done, note: nil, at: date)
            case "failed", "error": finish(index, state: .failed, note: "Falló", at: date)
            case "running": break
            default: finish(index, state: .failed, note: "Detenido", at: date)
            }
        }
        if line.contains("[Subagent hand-back]"),
           let id = line.range(of: #"(?<=<agent-message from=\\")[A-Za-z0-9_-]+"#, options: .regularExpression),
           let index = launches.firstIndex(where: { $0.agentID == String(line[id]) }), launches[index].state == .running {
            finish(index, state: .done, note: nil, at: date)
        }
    }

    /// Only these launches, in their order (the ones worth showing).
    mutating func keep(_ calls: [String]) {
        let wanted = Set(calls)
        launches.removeAll { !wanted.contains($0.call) }
    }

    /// The agent ids found in the agents' metadata files, for launches whose result didn't name one.
    mutating func identify(_ ids: [String: String]) {
        for index in launches.indices where launches[index].agentID == nil {
            if let id = ids[launches[index].call] { launches[index].agentID = id }
        }
    }

    private mutating func finish(_ index: Int, state: SubagentActivity.State, note: String?, at date: Date?) {
        guard launches[index].state == .running else { return }
        launches[index].state = state; launches[index].note = note; launches[index].ended = date
    }

    static func date(_ entry: [String: Any]) -> Date? {
        (entry["timestamp"] as? String).flatMap { stamp in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
        }
    }
}

/// What one subagent is doing, from its own record: read only from where the last look stopped.
final class SubagentProgress {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private var open: [(id: String, line: String)] = []
    private(set) var toolUses = 0
    private(set) var tokens = 0
    /// The tool call it is running now ("Read(Sources/Nook/Pet.swift)"), nil between calls.
    var activity: String? { open.last?.line }

    init(url: URL) { self.url = url }

    func poll(cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial = Data(partial[(newline + 1)...])
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            if let usage = message["usage"] as? [String: Any] {
                // Claude's own count is the context of the latest request.
                tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "tool_use":
                    toolUses += 1
                    let name = block["name"] as? String ?? "Tool"
                    let summary = TranscriptRenderer.summary(of: block["input"] as? [String: Any] ?? [:], cwd: cwd)
                    open.append((block["id"] as? String ?? "", summary.isEmpty ? name : "\(name)(\(summary))"))
                case "tool_result":
                    open.removeAll { $0.id == block["tool_use_id"] as? String }
                default: break
                }
            }
        }
    }
}

/// Follows the agents of one record: their states from the main record, their progress from theirs.
final class SubagentWatch {
    let folder: URL
    private var progress: [String: SubagentProgress] = [:]
    private var identified: Set<String> = []

    /// `record` is the session's main record; its agents live in a folder named after it.
    init(record: URL) { folder = record.deletingPathExtension().appendingPathComponent("subagents") }

    /// Call ids → agent ids, from the metadata files not read yet.
    func metadata() -> [String: String] {
        var ids: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".meta.json") && !identified.contains(name) {
            identified.insert(name)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let call = meta["toolUseId"] as? String else { continue }
            ids[call] = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
        }
        return ids
    }

    /// The agents as Nook shows them; running ones read their own record first.
    func activities(_ agents: TranscriptAgents, cwd: String?, now: Date = Date()) -> [SubagentActivity] {
        agents.launches.map { launch in
            var shown = SubagentActivity(id: launch.call, name: launch.name, kind: launch.kind, state: launch.state, background: launch.background)
            shown.note = launch.note
            shown.model = launch.model
            if let id = launch.agentID {
                let watch = progress[id] ?? SubagentProgress(url: folder.appendingPathComponent("agent-\(id).jsonl"))
                progress[id] = watch
                if launch.state == .running { watch.poll(cwd: cwd) }
                if watch.toolUses > 0 { shown.toolUses = watch.toolUses }
                if watch.tokens > 0 { shown.tokens = Self.tokens(watch.tokens) }
                if launch.state == .running { shown.activity = watch.activity }
            }
            if let start = launch.started { shown.duration = Self.duration((launch.ended ?? now).timeIntervalSince(start)) }
            return shown
        }
    }

    /// "41.2k", the way Claude prints it.
    static func tokens(_ count: Int) -> String {
        guard count >= 1000 else { return "\(count)" }
        let thousands = (Double(count) / 100).rounded() / 10
        return thousands == thousands.rounded() ? "\(Int(thousands))k" : "\(thousands)k"
    }

    /// "45s", "3m 12s", "1h 4m", whole seconds so a running agent's line changes once a second.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
