import Foundation

/// A command an agent takes after "/": "usage", "model", a skill such as "codex:rescue".
struct SlashCommand: Equatable, Hashable, Identifiable {
    let name: String
    var detail: String?
    /// Times it was typed before, for ordering.
    var uses = 0
    /// Its arguments as the reference writes them ("[model]", "<path>"), when known.
    var hint: String?
    /// Other names that run it ("/new" runs "/clear").
    var aliases: [String] = []
    var id: String { name }
    var text: String { "/" + name }
}

/// Each agent's built-in commands, from its official reference: `Resources/claude-commands.json`
/// (code.claude.com/docs/en/commands) and `Resources/codex-commands.json`
/// (developers.openai.com/codex/cli/slash-commands), regenerated with
/// `Scripts/update-agent-commands.py`. Not every command is offered to every user (platform,
/// plan, settings); the agent answers that it doesn't know one that isn't.
enum CommandReference {
    static let claude = load(file("claude-commands.json"))
    static let codex = load(file("codex-commands.json"))

    static func file(_ name: String) -> URL? {
        let bundled = (Bundle.main.resourcePath ?? "") + "/" + name
        let development = FileManager.default.currentDirectoryPath + "/Resources/" + name
        return [bundled, development].first { FileManager.default.fileExists(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    static func load(_ url: URL?) -> [SlashCommand] {
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (root["commands"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, SlashCatalog.isName(name) else { return nil }
            return SlashCommand(name: name, detail: (entry["detail"] as? String).map(SlashCatalog.short),
                                hint: entry["hint"] as? String, aliases: (entry["aliases"] as? [String] ?? []).filter(SlashCatalog.isName))
        }
    }
}

/// Reading and ranking commands. Every name comes from a real source (the agent's prompt history,
/// its own menu on screen, Claude's skill listing); nothing here lists commands by itself.
enum SlashCatalog {
    static func isName<S: StringProtocol>(_ name: S) -> Bool {
        name.count <= 60 && name.range(of: #"^[A-Za-z0-9][A-Za-z0-9:_.-]*$"#, options: .regularExpression) != nil
    }

    /// The command being typed: "/us" gives "us", "/" gives "". Nil for other text, once arguments
    /// start, or for a path ("/Users/…").
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let rest = draft.dropFirst()
        guard rest.isEmpty || isName(rest) else { return nil }
        return String(rest)
    }

    /// Commands for a draft, matched the way Claude Code's own menu does: from the start of the name,
    /// then of an alias, separators ignored ("/adddir" finds "add-dir", "/new" finds "clear"), then from
    /// the start of a word within the name ("/res" finds "codex:rescue"); the most used first in each.
    static func matches(_ commands: [SlashCommand], draft: String) -> [SlashCommand] {
        guard let typed = query(in: draft) else { return [] }
        let query = joined(typed)
        func tier(_ command: SlashCommand) -> Int? {
            // The name typed in full comes first, so Enter runs what was written.
            if command.name.lowercased() == typed.lowercased() { return -1 }
            if joined(command.name).hasPrefix(query) { return 0 }
            if command.aliases.contains(where: { joined($0).hasPrefix(query) }) { return 1 }
            let words = command.name.lowercased().split(whereSeparator: { separators.contains($0) })
            return words.contains(where: { $0.hasPrefix(query) }) ? 2 : nil
        }
        return commands.compactMap { command in tier(command).map { (command, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.0.uses != b.0.uses { return a.0.uses > b.0.uses }
                return a.0.name < b.0.name
            }
            .map(\.0)
    }

    private static let separators: Set<Character> = [":", "-", "_", "."]
    private static func joined<S: StringProtocol>(_ name: S) -> String { String(name.lowercased().filter { !separators.contains($0) }) }

    /// Claude's skill listing ("- name: description" lines), as Claude records it for each session.
    static func skills(listing content: String, names: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for name in names where isName(name) { found[name] = "" }
        for line in content.split(separator: "\n") where line.hasPrefix("- ") {
            let body = line.dropFirst(2)
            guard let colon = body.range(of: ": ") else { continue }
            let name = String(body[..<colon.lowerBound])
            guard names.isEmpty ? isName(name) : found[name] != nil else { continue }
            found[name] = short(String(body[colon.upperBound...]))
        }
        return found
    }

    private static let menuRow = try! NSRegularExpression(
        pattern: #"^\s{0,6}(?:[❯›>▸▶]\s*)?/([A-Za-z0-9][A-Za-z0-9:_.-]*)(?:\s+\([^)]{1,40}\))?\s{2,}(\S.*?)\s*$"#)

    /// The rows of the agent's own command menu ("  /usage      Show plan usage limits",
    /// "  /clear (reset, new)   Clear conversation…"). Only a run of two or more counts, so a lone
    /// line of output that starts with a slash is never taken for the menu.
    static func menu(_ lines: [String]) -> [SlashCommand] {
        var best: [SlashCommand] = [], run: [SlashCommand] = []
        for line in lines + [""] {
            let range = NSRange(line.startIndex..., in: line)
            if let match = menuRow.firstMatch(in: line, range: range),
               let name = Range(match.range(at: 1), in: line), let detail = Range(match.range(at: 2), in: line) {
                run.append(SlashCommand(name: String(line[name]), detail: short(String(line[detail]))))
            } else {
                if run.count >= 2, run.count > best.count { best = run }
                run = []
            }
        }
        return best
    }

    /// Commands typed before, counted by name: Claude's `display` or Codex's `text` lines.
    static func typed(in text: String, field: String) -> [String: Int] {
        count(text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return entry[field] as? String
        })
    }

    static func count(_ messages: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for message in messages where message.hasPrefix("/") {
            let name = message.dropFirst().prefix { !$0.isWhitespace }
            if isName(name) { counts[String(name), default: 0] += 1 }
        }
        return counts
    }

    /// The first line of a description, short enough for a menu row.
    static func short(_ text: String) -> String {
        let first = (text.split(separator: "\n").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        return first.count > 160 ? String(first.prefix(159)) + "…" : first
    }
}

/// What Nook knows of each agent's commands: what was typed before (the agent's own prompt
/// history) and what its own menu showed on screen, kept across launches. Each session adds
/// Claude's skill listing from its record.
final class SlashCommandStore {
    private(set) var typed: [TerminalAgent: [String: Int]] = [:]
    private(set) var seen: [TerminalAgent: [String: String]] = [:]
    private var read: [String: Date] = [:]
    private let home: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "dev.nook.commands", qos: .utility)
    private static let key = "agentCommands"

    private let reference: [TerminalAgent: [SlashCommand]]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard,
         reference: [TerminalAgent: [SlashCommand]] = [.claude: CommandReference.claude, .codex: CommandReference.codex]) {
        self.home = home; self.defaults = defaults; self.reference = reference
        for (agent, names) in defaults.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:] {
            if let agent = TerminalAgent(rawValue: agent) { seen[agent] = names }
        }
    }

    /// The prompt histories: `~/.claude*/history.jsonl` and `~/.codex/history.jsonl`.
    func histories() -> [(agent: TerminalAgent, url: URL, field: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names.filter { $0.hasPrefix(".claude") }.map { (TerminalAgent.claude, home.appendingPathComponent($0).appendingPathComponent("history.jsonl"), "display") }
            + [(TerminalAgent.codex, home.appendingPathComponent(".codex/history.jsonl"), "text")]
    }

    /// Reads the histories again when one changed; off the main thread, applied on it. Called on main.
    func refresh(completion: @escaping () -> Void = {}) {
        let known = read
        queue.async { [self] in
            let files = histories().map { ($0, try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
            let stamps = Dictionary(files.compactMap { file, date in date.map { (file.url.path, $0) } }, uniquingKeysWith: { a, _ in a })
            guard stamps != known else { return DispatchQueue.main.async(execute: completion) }
            var counts: [TerminalAgent: [String: Int]] = [:]
            for (file, date) in files where date != nil {
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                counts[file.agent, default: [:]].merge(SlashCatalog.typed(in: text, field: file.field), uniquingKeysWith: +)
            }
            DispatchQueue.main.async { self.typed = counts; self.read = stamps; completion() }
        }
    }

    /// Keeps the rows of an agent's menu; a longer description replaces a cut one.
    func learn(_ rows: [SlashCommand], agent: TerminalAgent) {
        var names = seen[agent] ?? [:]
        for row in rows {
            let detail = row.detail ?? ""
            if let known = names[row.name], known.count >= detail.count { continue }
            names[row.name] = detail
        }
        guard names != seen[agent] ?? [:] else { return }
        seen[agent] = names
        defaults.set(Dictionary(uniqueKeysWithValues: seen.map { ($0.key.rawValue, $0.value) }), forKey: Self.key)
    }

    /// One session's commands. A name typed only once counts when another source confirms it
    /// (the reference, its menu, Claude's listing, Claude's record of it running): a single typo is
    /// not a command. The reference's description wins over a menu row the terminal may have cut.
    func commands(agent: TerminalAgent, skills: [String: String] = [:], accepted: Set<String> = [], sent: [String] = []) -> [SlashCommand] {
        let known = Dictionary((reference[agent] ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var details = (seen[agent] ?? [:]).merging(known.compactMapValues(\.detail)) { _, documented in documented }
        details.merge(skills.filter { !$0.value.isEmpty || details[$0.key] == nil }) { _, new in new }
        // What Nook sent also reaches Claude's history, so the larger count is kept rather than both.
        let uses = (typed[agent] ?? [:]).merging(SlashCatalog.count(sent), uniquingKeysWith: max)
        var names = Set(details.keys).union(accepted).union(known.keys)
        for (name, count) in uses where count >= 2 { names.insert(name) }
        return names.map { name in
            SlashCommand(name: name, detail: details[name].flatMap { $0.isEmpty ? nil : $0 }, uses: uses[name] ?? 0,
                         hint: known[name]?.hint, aliases: known[name]?.aliases ?? [])
        }
    }
}
