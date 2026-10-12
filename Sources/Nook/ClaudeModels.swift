import Foundation
import Combine

/// A model Nook's model button offers for a Claude tab: one row of Claude's own /model picker.
struct ClaudeModelChoice: Equatable, Identifiable, Codable {
    /// As Claude's picker names it ("Default (recommended)", "Opus 5.5", "Fable 5.1").
    var label: String
    /// The picker's description ("For complex work and everyday tasks"), when there is one.
    var detail: String?
    /// What `/model` takes for it: the model's id ("claude-opus-5-5") or an alias ("default"). nil when only Claude's picker can
    /// choose it; Nook then opens the picker and moves to the row.
    var argument: String?
    /// Its number in Claude's picker ("Default" is 1), when known; the picker is driven to it for "this session only".
    var row: Int?
    /// The model the tab uses now.
    var isCurrent = false
    /// One of Claude Code's documented aliases (`default`, `opus`, `sonnet`, `haiku`), offered only while Nook knows no list.
    var isAlias = false
    var id: String { argument.map { "model:" + $0 } ?? "label:" + label }
}

/// Where a model choice applies, as Claude's picker offers it: Enter sets it as the default for new sessions, "s" uses it in
/// this session only.
enum ClaudeModelScope: Equatable {
    case `default`
    case sessionOnly
}

/// Claude Code's own list of the models an account may pick, as it caches it on disk: `<config>/cache/model-catalog/<…>-cc.json`
/// (`catalog.config.models` in the picker's order, after its "Default" row, and `catalog.state.model`, the saved choice).
/// Checked against Daniel's picker of 2026-10-06 (Claude Code 2.1.290): the same eleven models in the same order behind
/// "Default", the ✔ on `state.model`. Only these fields are decoded; the overflow models carry no description there (the picker
/// has its own), so a description learned from the picker fills in.
struct ClaudeModelCacheFile: Equatable {
    struct Model: Decodable, Equatable {
        let id: String
        let name: String
        let description: String?
        let minClaudeCodeVersion: String?
    }
    let models: [Model]
    /// The account's saved choice ("claude-opus-5-5").
    let selected: String?
    let fetchedAt: Date
    /// When Claude itself would fetch the list again.
    let staleAt: Date?

    private struct Raw: Decodable {
        struct Catalog: Decodable {
            struct Config: Decodable { let models: [Model] }
            struct State: Decodable { let model: String? }
            let surface: String?
            let config: Config
            let state: State?
        }
        let fetchedAt: Double?
        let staleAt: Double?
        let catalog: Catalog
    }

    /// The newest Claude Code list in a config folder (`~/.claude-work`), or nil when it has none.
    static func load(folder: URL) -> ClaudeModelCacheFile? {
        let directory = folder.appendingPathComponent("cache/model-catalog")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix("-cc.json") }.compactMap { parse(contentsOf: directory.appendingPathComponent($0)) }.max { $0.fetchedAt < $1.fetchedAt }
    }

    static func parse(contentsOf url: URL) -> ClaudeModelCacheFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> ClaudeModelCacheFile? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? decoder.decode(Raw.self, from: data), raw.catalog.surface ?? "cc" == "cc", !raw.catalog.config.models.isEmpty else { return nil }
        func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        return ClaudeModelCacheFile(models: raw.catalog.config.models, selected: raw.catalog.state?.model, fetchedAt: date(raw.fetchedAt) ?? .distantPast, staleAt: date(raw.staleAt))
    }

    /// "2.1.280" ≤ "2.1.290", number by number.
    static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return true
    }
}

/// The rows of Claude's /model picker Nook has seen, for one config folder: the fallback when Claude Code's own list isn't on
/// disk, and the descriptions that list lacks. The picker scrolls ("… +3 models", `AgentPrompt.moreBelow`), so rows add up by
/// number across views.
struct ClaudeModelCatalog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var label: String
        var detail: String?
        var row: Int?
    }
    /// The Claude Code version that drew it ("2.1.290"); a different version may list other models.
    var version: String?
    var entries: [Entry]
    /// How many rows the picker has in all, when a view said how many were left below ("… +3 models").
    var total: Int?
    var learnedAt: Date
}

/// What Nook knows about the models a Claude tab can switch to, without a hardcoded list: Claude Code's own cached list for the
/// tab's config folder (complete, and updated whenever Claude fetches it), else the picker rows Nook has seen, else Claude
/// Code's documented aliases.
final class ClaudeModelStore: ObservableObject {
    @Published private(set) var catalogs: [String: ClaudeModelCatalog] = [:]
    private let defaults: UserDefaults
    private let home: URL
    static let key = "claudeModelCatalogs"

    /// The documented aliases, in Claude's own order; each one is the newest model of its family.
    static let aliases: [ClaudeModelChoice] = [
        ClaudeModelChoice(label: "Default", argument: "default", isAlias: true),
        ClaudeModelChoice(label: "Opus", argument: "opus", isAlias: true),
        ClaudeModelChoice(label: "Sonnet", argument: "sonnet", isAlias: true),
        ClaudeModelChoice(label: "Haiku", argument: "haiku", isAlias: true),
    ]

    /// `home` holds the config folders (`.claude`, `.claude-work`…); tests pass a folder of their own.
    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode([String: ClaudeModelCatalog].self, from: data) { catalogs = stored }
    }

    // MARK: Claude Code's list on disk

    private var cacheReads: [String: (at: Date, file: ClaudeModelCacheFile?)] = [:]

    /// Claude Code's list for a folder (".claude-work"), or the newest of any folder when the tab's is unknown. Read again at
    /// most every few seconds: the button may ask on every redraw.
    func cached(folder: String?, now: Date = Date()) -> ClaudeModelCacheFile? {
        let key = folder ?? "*"
        if let read = cacheReads[key], now.timeIntervalSince(read.at) < 5 { return read.file }
        let file: ClaudeModelCacheFile?
        if let folder { file = ClaudeModelCacheFile.load(folder: home.appendingPathComponent(folder)) }
        else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
            file = names.filter { $0.hasPrefix(".claude") }.compactMap { ClaudeModelCacheFile.load(folder: home.appendingPathComponent($0)) }.max { $0.fetchedAt < $1.fetchedAt }
        }
        cacheReads[key] = (now, file)
        return file
    }

    // MARK: The picker

    /// Whether a prompt is Claude's model picker ("Select model" / "Switch between Claude models.").
    static func isModelPicker(_ prompt: AgentPrompt) -> Bool {
        guard !prompt.options.isEmpty else { return false }
        // Its title, however the parser classes a view scrolled away from row 1; any other selector naming models too.
        if prompt.question.lowercased().hasPrefix("select model") { return true }
        return prompt.kind == .selector && (prompt.question + " " + (prompt.note ?? "")).lowercased().contains("model")
    }

    /// Keeps the rows a picker on screen shows, adding to the ones seen before by their number (the picker scrolls). A different
    /// Claude Code version starts the list over. Saved only when something changed.
    func learn(_ prompt: AgentPrompt, version: String?, folder: String?, now: Date = Date()) {
        guard Self.isModelPicker(prompt) else { return }
        let key = folder ?? ""
        var catalog = catalogs[key].flatMap { $0.version == version ? $0 : nil } ?? ClaudeModelCatalog(version: version, entries: [], learnedAt: now)
        for (index, option) in prompt.options.enumerated() {
            let row = option.number ?? index + 1
            let entry = ClaudeModelCatalog.Entry(label: option.title, detail: option.detail, row: row)
            if let at = catalog.entries.firstIndex(where: { $0.row == row }) { catalog.entries[at] = entry } else { catalog.entries.append(entry) }
        }
        catalog.entries.sort { ($0.row ?? 0) < ($1.row ?? 0) }
        // "… +3 models" under the last row: that many more below it (a bare "↓" says at least one).
        let last = prompt.options.last.map { $0.number ?? prompt.options.count } ?? 0
        catalog.total = max(catalog.total ?? 0, last + prompt.moreBelow, catalog.entries.count)
        guard catalog.entries != catalogs[key]?.entries || catalog.total != catalogs[key]?.total || catalog.version != catalogs[key]?.version else { return }
        catalog.learnedAt = now
        catalogs[key] = catalog
        defaults.set(try? JSONEncoder().encode(catalogs), forKey: Self.key)
    }

    /// The picker rows seen for a folder, or the newest seen anywhere when the folder is unknown or has none yet.
    func catalog(folder: String?) -> ClaudeModelCatalog? {
        if let folder, let own = catalogs[folder] { return own }
        return catalogs.values.max { $0.learnedAt < $1.learnedAt }
    }

    // MARK: What the button offers

    /// The picker's rows in its order, with the tab's current model marked. From Claude Code's list when it is on disk (every
    /// model, the ones the tab's version can't run left out, as the picker does), else from the rows Nook has seen plus the
    /// aliases they don't name. `current` is the model Claude last named ("Opus 5.5"); `live` is the picker open on screen,
    /// whose ✔ wins.
    func choices(folder: String?, version: String? = nil, current: String?, live: AgentPrompt? = nil) -> [ClaudeModelChoice] {
        let seen = catalog(folder: folder)
        var choices: [ClaudeModelChoice]
        if let cache = cached(folder: folder) {
            let first = seen?.entries.first { $0.row == 1 }
            choices = [ClaudeModelChoice(label: first?.label ?? "Default (recommended)", detail: first?.detail, argument: "default", row: 1)]
            for model in cache.models where version.map({ running in model.minClaudeCodeVersion.map { ClaudeModelCacheFile.version(running, isAtLeast: $0) } ?? true }) ?? true {
                let detail = model.description ?? seen?.entries.first { $0.label == model.name }?.detail
                // An id Nook wouldn't type as is (a line break, a space…) leaves the row to the picker.
                choices.append(ClaudeModelChoice(label: model.name, detail: detail, argument: Self.isSafeArgument(model.id) ? model.id : nil, row: choices.count + 1))
            }
        } else {
            let entries = live.flatMap { Self.isModelPicker($0) ? $0.options.enumerated().map { ClaudeModelCatalog.Entry(label: $1.title, detail: $1.detail, row: $1.number ?? $0 + 1) } : nil }
                ?? seen?.entries ?? []
            choices = entries.map { ClaudeModelChoice(label: $0.label, detail: $0.detail, argument: Self.argument(forLabel: $0.label), row: $0.row) }
            let covered = Set(choices.compactMap(\.argument))
            choices += Self.aliases.filter { !covered.contains($0.argument ?? "") }
        }
        if let live, Self.isModelPicker(live), let ticked = live.options.first(where: \.current), let index = choices.firstIndex(where: { $0.label == ticked.title }) {
            choices[index].isCurrent = true
        } else if let index = Self.currentIndex(in: choices, current: current) ?? cached(folder: folder)?.selected.flatMap({ id in choices.firstIndex { $0.argument == id } }) {
            choices[index].isCurrent = true
        }
        return choices
    }

    /// Rows of the picker Nook hasn't seen: 0 with Claude Code's list on disk (it has them all), nil when nothing says how many.
    func missingRows(folder: String?) -> Int? {
        if cached(folder: folder) != nil { return 0 }
        guard let seen = catalog(folder: folder), let total = seen.total else { return nil }
        return max(0, total - seen.entries.count)
    }

    /// The list may lack a model: Claude Code's list on disk is past the time Claude would fetch it again, or the rows Nook saw
    /// come from another Claude Code version than the tab's. The documented aliases never go stale.
    func isStale(folder: String?, version: String?, now: Date = Date()) -> Bool {
        if let cache = cached(folder: folder, now: now) { return cache.staleAt.map { now > $0 } ?? false }
        guard let version, let kept = catalog(folder: folder)?.version else { return false }
        return kept != version
    }

    /// Whether a model id or alias can be typed after `/model` as one plain word: letters, digits and `.` `-` `_` `[` `]` `:`
    /// ("claude-opus-5-5", "sonnet[1m]"), at most 100 of them. The list on disk is another program's file; anything else in it
    /// (a line break would send a second command) is never typed.
    static func isSafeArgument(_ argument: String) -> Bool {
        argument.range(of: #"^[A-Za-z0-9._\-\[\]:]{1,100}$"#, options: .regularExpression) != nil
    }

    /// `/model`'s argument for a picker label Nook can't find in Claude Code's list: only the documented aliases, named by the
    /// picker exactly ("Sonnet", "Default (recommended)"). Any other row is chosen in the picker itself.
    static func argument(forLabel label: String) -> String? {
        var name = label.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("(recommended)") { name = name.dropLast("(recommended)".count).trimmingCharacters(in: .whitespaces) }
        return ["default", "opus", "sonnet", "haiku"].contains(name) ? name : nil
    }

    /// The choice that is the model Claude named last: its label, or the model its description starts with ("Sonnet 5.5 · …"),
    /// a specific row before "Default", which may stand for the same model; else the alias of its family.
    private static func currentIndex(in choices: [ClaudeModelChoice], current: String?) -> Int? {
        guard let current = current?.trimmingCharacters(in: .whitespaces), !current.isEmpty else { return nil }
        func names(_ choice: ClaudeModelChoice) -> Bool {
            let detailModel = choice.detail?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces)
            return choice.label.caseInsensitiveCompare(current) == .orderedSame || detailModel?.caseInsensitiveCompare(current) == .orderedSame
        }
        if let specific = choices.firstIndex(where: { names($0) && $0.argument != "default" }) { return specific }
        if let named = choices.firstIndex(where: names) { return named }
        if current.lowercased().hasPrefix("default") { return choices.firstIndex { $0.argument == "default" } }
        let family = current.split(separator: " ").first.map { $0.lowercased() }
        return choices.firstIndex { $0.isAlias && $0.argument == family }
    }
}
