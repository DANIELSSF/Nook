import AppKit
import Darwin
import os

// Claude Code's status line as a live feed for Nook. Claude runs a `statusLine` command whenever its state changes (a reply, a
// model or mode change, a limit's reset) and hands it a JSON payload on stdin: the session's cost and durations, the context
// window, the prompt cache, the model and effort, and the account's rate limits. Nook installs, only when the user asks, a tiny
// /bin/sh script as that command: it leaves the payload in a private folder and prints nothing, so a Terminal tab gets the
// limits live without a key or a scroll. A status line the user already had is chained: the script runs it after, with the
// same input, and prints what it prints.
//
//   NookStatusLine          install / uninstall per config folder, its state, the script
//   ClaudeStatusPayload     what Claude sends, decoded
//   ClaudeStatusWatcher     the private folder, watched: one reading per session, stale ones pruned
//   ClaudeLiveUsage         one tab's live figures, with its account's freshest limits (AppModel.applyStatus)
//
// What Claude draws: the status line's row sits under its input box, above the mode line. Empty output leaves a blank row in
// fullscreen and none otherwise; while any status line is configured Claude drops the footer's "? for shortcuts" hints. A
// chained status line's text is told apart from the conversation by the lines the script saw it print (`isShownLine`).

let statusLog = Logger(subsystem: "dev.nook.mac", category: "statusline")

enum NookStatusLine {
    /// The script Claude runs: a private copy in Nook's support folder, like the hooks' helper.
    static var scriptURL: URL { supportFolder.appendingPathComponent("nook-statusline.sh") }
    private static var supportFolder: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Nook") }
    /// Where the script leaves each session's payload: private to the user (0700, its files 0600).
    static var statusFolder: URL { URL(fileURLWithPath: "/tmp/nook-\(getuid())/status") }

    /// The command Nook installs: `/bin/sh '<script>'`, and `--chain '<the user's command>'` when it replaced one.
    static func command(script: URL = scriptURL, chaining original: String? = nil) -> String {
        "/bin/sh " + Shell.quote(script.path) + (original.map { " --chain " + Shell.quote($0) } ?? "")
    }

    /// One config folder's status line, as the Permisos row shows it.
    enum State: Equatable {
        /// No status line: installing adds Nook's.
        case off
        /// Nook's, alone.
        case on
        /// Nook's, running the user's own after it (`original`, the command it replaced).
        case chained(original: String)
        /// A status line of the user's: installing chains it, so it shows as before.
        case foreign(command: String)
        /// Settings that are not readable JSON: nothing is changed in any folder while one is like this.
        case unreadable

        /// Nook's status line is there, alone or chained.
        var isNooks: Bool {
            switch self {
            case .on, .chained: true
            default: false
            }
        }
    }

    struct Folder: Equatable {
        var url: URL
        var state: State
        /// How it reads: "~/.claude-work".
        var name: String { "~/" + url.lastPathComponent }
    }

    /// Every config folder Nook knows (`ClaudeHooks.folders`), read off the main thread: it opens each `settings.json`.
    static func states(folders: [URL] = ClaudeHooks.folders(), script: URL = scriptURL) -> [Folder] {
        folders.map { folder in
            let url = ClaudeSettingsFile.resolved(ClaudeHooks.settingsURL(in: folder))
            guard FileManager.default.fileExists(atPath: url.path) else { return Folder(url: folder, state: .off) }
            guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Folder(url: folder, state: .unreadable)
            }
            return Folder(url: folder, state: state(of: json, script: script))
        }
    }

    static func state(of settings: [String: Any], script: URL = scriptURL) -> State {
        guard let value = settings["statusLine"], !(value is NSNull) else { return .off }
        // A status line in a shape Nook doesn't know is the user's: never overwritten, never removed.
        guard let line = value as? [String: Any] else { return .foreign(command: "") }
        let command = line["command"] as? String ?? ""
        let own = Self.command(script: script)
        if command == own { return .on }
        if command.hasPrefix(own + " --chain "), let original = unquote(String(command.dropFirst(own.count + " --chain ".count))) { return .chained(original: original) }
        return .foreign(command: command)
    }

    /// Nook's status line into each folder's settings: added where there is none, chained where the user has one of the command
    /// kind, left alone where it is already Nook's. Everything else in the file stays, and each file changed gets a backup next
    /// to it first (`ClaudeSettingsFile`). A folder whose settings can't be read stops the whole change: nothing is written
    /// anywhere. Returns the folders left as they were because their status line can't be chained (not a command, or not a
    /// shape Nook knows), so the user is told. Only the user's own click calls this: Nook never installs or changes it by itself.
    @discardableResult
    static func install(in folders: [URL], script: URL = scriptURL, statusFolder: URL = statusFolder) throws -> [URL] {
        try installScript(at: script, statusFolder: statusFolder)
        var skipped: [URL] = []
        try ClaudeSettingsFile.change(folders) { folder, settings in
            switch state(of: settings, script: script) {
            case .on, .chained, .unreadable: return nil
            case .off:
                var updated = settings
                updated["statusLine"] = ["type": "command", "command": command(script: script)]
                return updated
            case .foreign(let original):
                guard var line = settings["statusLine"] as? [String: Any], line["type"] as? String ?? "command" == "command", !original.isEmpty else {
                    skipped.append(folder); return nil
                }
                line["command"] = command(script: script, chaining: original)
                var updated = settings
                updated["statusLine"] = line
                return updated
            }
        }
        return skipped
    }

    /// Nook's status line out of each folder: no status line where Nook added it; where it chained the user's own, that one's
    /// command back in the status line as it is now (any field changed since stays changed). A status line that isn't Nook's is
    /// never touched. Once none is left in these folders the status folder, with every payload in it, goes too.
    static func uninstall(from folders: [URL], script: URL = scriptURL, statusFolder: URL = statusFolder) throws {
        try ClaudeSettingsFile.change(folders) { _, settings in
            var updated = settings
            switch state(of: settings, script: script) {
            case .on:
                updated.removeValue(forKey: "statusLine")
            case .chained(let original):
                var line = settings["statusLine"] as? [String: Any] ?? [:]
                line["command"] = original
                updated["statusLine"] = line
            case .off, .foreign, .unreadable: return nil
            }
            return updated
        }
        if !states(folders: folders, script: script).contains(where: { $0.state.isNooks }) { removeStatusFolder(statusFolder) }
    }

    /// The status folder and every payload in it, when it is a directory of the user's own; anything else there is only unlinked.
    static func removeStatusFolder(_ folder: URL = statusFolder) {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { unlink(folder.path); return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A session id the script writes a file for: letters, digits, `-` and `_`, 128 at most.
    static func isSessionID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The text `Shell.quote` made of a command: nil for anything it doesn't make.
    static func unquote(_ quoted: String) -> String? {
        guard quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") else { return nil }
        let inner = String(quoted.dropFirst().dropLast())
        let text = inner.replacingOccurrences(of: "'\\''", with: "'")
        return Shell.quote(text) == quoted ? text : nil
    }

    // MARK: The script

    /// Writes the script (0700), naming `statusFolder` in it: the uid is the user's own, so the script never asks for it.
    static func installScript(at url: URL = scriptURL, statusFolder: URL = statusFolder) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(scriptSource(statusFolder: statusFolder).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// The script Claude runs on every change of state in every session: shell builtins but for `/bin/mv` (and `/bin/mkdir` the
    /// first time, `/bin/rm` after a failed write; with `--chain`, the user's command and one more `/bin/mv`), all by full path.
    /// It reads the payload whole, takes its session id (letters, digits, `-` and `_`, 128 at most, whitespace allowed after the
    /// colon; anything else and nothing is written), and leaves it as `<session id>.json` wrapped with its parent's pid: written
    /// aside with noclobber and moved in, so Nook never reads half of one, and only in a folder that is a real directory of the
    /// user's own. It prints nothing, errors included. With `--chain '<command>'` it then runs that command as Claude would
    /// (`/bin/sh -c`) with the same input, prints what it printed (nothing when it printed nothing), keeps a copy as
    /// `<session id>.line` (Nook's parsers tell that row from the conversation), and exits as it did. Anything failing is
    /// skipped: it always ends at once.
    static func scriptSource(statusFolder: URL) -> String {
        let folder = Shell.quote(statusFolder.path)
        return """
        #!/bin/sh
        # Nook (dev.nook.mac): keeps the status line payload Claude Code sends, for Nook's usage card. It prints nothing of its own;
        # with --chain it then runs the status line it replaced, with the same input, and prints what that prints.
        umask 077
        set -C
        d=\(folder)
        p=''
        while IFS= read -r l; do p="$p$l
        "; done
        p="$p$l"
        s=${p#*\\"session_id\\":}
        [ "$s" = "$p" ] && s=''
        while :; do case $s in ' '*|'\t'*) s=${s#?} ;; *) break ;; esac; done
        case $s in \\"*) s=${s#\\"}; s=${s%%\\"*} ;; *) s='' ;; esac
        [ ${#s} -le 128 ] || s=''
        case $s in ''|*[!A-Za-z0-9_-]*) s='' ;; esac
        safe() {
          [ -n "$s" ] || return 1
          [ -d "$d" ] || /bin/mkdir -p "$d" 2>/dev/null
          [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] && [ ! -L "${d%/*}" ] && [ -O "${d%/*}" ]
        }
        if safe; then
          t="${d:?}/.${s:?}.$$"
          { printf '{"nook_ppid":%s,"payload":' "${PPID:-0}"; printf '%s' "$p"; printf '}\\n'; } 2>/dev/null >"$t" && /bin/mv -f "$t" "$d/$s.json" 2>/dev/null || /bin/rm -f "${t:?}" 2>/dev/null
        fi
        if [ "$1" = --chain ] && [ -n "$2" ]; then
          o=$(printf '%s' "$p" | /bin/sh -c "$2"); r=$?
          [ -n "$o" ] && printf '%s\\n' "$o"
          if safe; then
            if [ -n "$o" ]; then
              t="${d:?}/.${s:?}.$$.line"
              printf '%s\\n' "$o" 2>/dev/null >"$t" && /bin/mv -f "$t" "$d/$s.line" 2>/dev/null || /bin/rm -f "${t:?}" 2>/dev/null
            else
              /bin/rm -f "${d:?}/${s:?}.line" 2>/dev/null
            fi
          fi
          exit $r
        fi
        exit 0

        """
    }

    // MARK: Chained lines on screen

    private static let shownLock = NSLock()
    private static var shown: [String] = []

    /// The lines a chained status line printed last, in any session (`ClaudeStatusWatcher`): its row on screen is Claude's
    /// footer, not the conversation.
    static func setShownLines(_ lines: [String]) {
        let clean = lines.map(plain).filter { !$0.isEmpty }
        shownLock.lock(); shown = clean; shownLock.unlock()
    }

    /// Whether a line of the screen is a chained status line's row: one of its lines, whole or cut short by Claude ("…").
    static func isShownLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        shownLock.lock(); defer { shownLock.unlock() }
        guard !shown.isEmpty else { return false }
        return shown.contains { known in
            if known == text { return true }
            guard text.hasSuffix("…") else { return false }
            let cut = text.dropLast().trimmingCharacters(in: .whitespaces)
            return cut.count >= 8 && known.hasPrefix(cut)
        }
    }

    /// A status line's output as the screen shows it: no colour codes or links, trimmed.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\x{1B}\]8;[^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}


// MARK: - Claude's settings files

/// Claude's `settings.json`, as Nook changes it (its status line here, its hooks in ClaudeSignals.swift). Every folder is read
/// first, so a malformed file stops the change before anything is written. Each file is written where it really is (through a
/// link, as a dotfiles setup has it: the link stays), only if it still holds what was read (Claude rewrites it for /model and
/// /effort), after a backup of what it held. The backup and the new file are created private (0600) from the start: the file
/// may hold `env` tokens. Each folder keeps Nook's newest `backupsKept` backups.
enum ClaudeSettingsFile {
    static let backupsKept = 5
    /// Called right before a file is read again to be written: tests change the file there.
    static var willWrite: ((URL) -> Void)?

    /// The file a settings path names, through any link.
    static func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    /// `transform` gets each folder's settings ([:] when it has no file) and returns them changed, or nil to leave the file be.
    static func change(_ folders: [URL], _ transform: (URL, [String: Any]) -> [String: Any]?) throws {
        var reads: [(folder: URL, url: URL, settings: [String: Any], data: Data?)] = []
        for folder in folders {
            let url = resolved(ClaudeHooks.settingsURL(in: folder))
            guard FileManager.default.fileExists(atPath: url.path) else { reads.append((folder, url, [:], nil)); continue }
            let data = try Data(contentsOf: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TerminalBridgeError.failed("No se pudo leer \(ClaudeHooks.describe([folder])). No se modificó nada.")
            }
            reads.append((folder, url, json, data))
        }
        for read in reads {
            guard let updated = transform(read.folder, read.settings) else { continue }
            willWrite?(read.url)
            guard FileManager.default.contents(atPath: read.url.path) == read.data else {
                throw TerminalBridgeError.failed("\(ClaudeHooks.describe([read.folder])) cambió mientras Nook lo editaba (Claude lo reescribe al cambiar de modelo o de esfuerzo). No se modificó; vuelve a intentarlo.")
            }
            if let original = read.data { try backup(original, besides: read.url) }
            try FileManager.default.createDirectory(at: read.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(read.url, with: JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]))
        }
    }

    /// `settings.nook-backup-XXXXXXXX.json` beside the file, private from its creation; the oldest beyond `backupsKept` go.
    static func backup(_ data: Data, besides url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try create(folder.appendingPathComponent("settings.nook-backup-\(UUID().uuidString.prefix(8)).json"), with: data)
        let manager = FileManager.default
        let backups = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("settings.nook-backup-") && $0.hasSuffix(".json") }
            .map { folder.appendingPathComponent($0) }
            .sorted { modified($0) > modified($1) }
        for old in backups.dropFirst(backupsKept) { try? manager.removeItem(at: old) }
    }

    /// The file's new content, written aside (0600) and moved over it in one step: readers never see half of it.
    static func replace(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).nook-\(UUID().uuidString.prefix(8))")
        try create(temporary, with: data)
        guard rename(temporary.path, url.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw TerminalBridgeError.failed("No se pudo escribir \(url.path) (\(reason)).")
        }
    }

    /// A new file, never over an existing one nor through a link, readable by the user alone.
    private static func create(_ url: URL, with data: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalBridgeError.failed("No se pudo crear \(url.path) (\(String(cString: strerror(errno)))).") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: data) } catch {
            unlink(url.path)
            throw TerminalBridgeError.failed("No se pudo escribir \(url.path).")
        }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
}

// MARK: - The payload

/// What Claude Code 2.1.29x sends its status line, the parts Nook uses (`SCo` in its source). Every part is optional: an older
/// or newer Claude may leave any out.
struct ClaudeStatusPayload: Equatable {
    struct Limit: Equatable {
        /// 0...100.
        var usedPercentage: Double
        var resetsAt: Date?
        /// The spend limit's dollars, when Claude says.
        var usedUSD: Double? = nil
        var limitUSD: Double? = nil
        var period: String? = nil
    }

    struct RateLimits: Equatable {
        var fiveHour: Limit?
        var sevenDay: Limit?
        var spendLimit: Limit?
        var isEmpty: Bool { fiveHour == nil && sevenDay == nil && spendLimit == nil }
    }

    struct Cost: Equatable {
        var totalUSD: Double?
        var durationMS: Double?
        var apiDurationMS: Double?
        var linesAdded: Int?
        var linesRemoved: Int?
    }

    struct Context: Equatable {
        var usedPercentage: Double?
        var remainingPercentage: Double?
        var size: Int?
        var inputTokens: Int?
    }

    struct PromptCache: Equatable {
        var warm: Bool?
        var ttl: String?
        var expiresAt: Date?
        var requests: Int?
        var misses: Int?
        /// 0...1.
        var hitRatio: Double?
    }

    var sessionID: String
    var sessionName: String?
    var transcriptPath: String?
    var cwd: String?
    var modelID: String?
    var modelName: String?
    var version: String?
    var effort: String?
    var cost: Cost?
    var context: Context?
    var rateLimits: RateLimits?
    var promptCache: PromptCache?

    /// The config folder the session belongs to, from its record's path (".../.claude-work/projects/<project>/<id>.jsonl").
    var configFolder: String? {
        guard let path = transcriptPath else { return nil }
        let parts = (path as NSString).pathComponents
        guard let projects = parts.lastIndex(of: "projects"), projects > 0 else { return nil }
        return NSString.path(withComponents: Array(parts[..<projects]))
    }

    init?(json: [String: Any]) {
        guard let id = json["session_id"] as? String, !id.isEmpty else { return nil }
        sessionID = id
        sessionName = json["session_name"] as? String
        transcriptPath = (json["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        cwd = json["cwd"] as? String
        let model = json["model"] as? [String: Any]
        modelID = model?["id"] as? String
        modelName = model?["display_name"] as? String
        version = json["version"] as? String
        effort = (json["effort"] as? [String: Any])?["level"] as? String
        if let cost = json["cost"] as? [String: Any] {
            self.cost = Cost(totalUSD: Self.number(cost["total_cost_usd"]), durationMS: Self.number(cost["total_duration_ms"]),
                             apiDurationMS: Self.number(cost["total_api_duration_ms"]), linesAdded: Self.number(cost["total_lines_added"]).map { Int($0) },
                             linesRemoved: Self.number(cost["total_lines_removed"]).map { Int($0) })
        }
        if let window = json["context_window"] as? [String: Any] {
            context = Context(usedPercentage: Self.number(window["used_percentage"]), remainingPercentage: Self.number(window["remaining_percentage"]),
                              size: Self.number(window["context_window_size"]).map { Int($0) }, inputTokens: Self.number(window["total_input_tokens"]).map { Int($0) })
        }
        if let limits = json["rate_limits"] as? [String: Any] {
            let found = RateLimits(fiveHour: Self.limit(limits["five_hour"]), sevenDay: Self.limit(limits["seven_day"]), spendLimit: Self.limit(limits["spend_limit"]))
            rateLimits = found.isEmpty ? nil : found
        }
        if let cache = json["prompt_cache"] as? [String: Any] {
            promptCache = PromptCache(warm: cache["warm"] as? Bool, ttl: cache["ttl"] as? String, expiresAt: Self.number(cache["expires_at"]).map { Date(timeIntervalSince1970: $0) },
                                      requests: Self.number(cache["requests"]).map { Int($0) }, misses: Self.number(cache["misses"]).map { Int($0) },
                                      hitRatio: Self.number(cache["hit_ratio"]))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func limit(_ value: Any?) -> Limit? {
        guard let json = value as? [String: Any], let used = number(json["used_percentage"]) else { return nil }
        return Limit(usedPercentage: used, resetsAt: number(json["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                     usedUSD: number(json["used_usd"]), limitUSD: number(json["limit_usd"]), period: json["period"] as? String)
    }
}

/// One file of the status folder: a session's latest payload, when it was written, and who wrote it.
struct ClaudeStatusReading: Equatable {
    var payload: ClaudeStatusPayload
    /// The file's modification time: when Claude last ran the status line for this session.
    var at: Date
    /// The terminal of the Claude that ran it ("/dev/ttys004"), from the script's parent; nil when it couldn't be told.
    var tty: String?
    /// What a chained status line printed last for this session.
    var line: String?
}

/// One tab's live figures: its own payload (cost, durations, context, prompt cache, model, effort) and its account's rate
/// limits, the freshest any session of its config folder reported (limits belong to the account, not the session).
struct ClaudeLiveUsage: Equatable {
    var session: ClaudeStatusPayload?
    var sessionAt: Date?
    var limits: ClaudeStatusPayload.RateLimits?
    var limitsAt: Date?
    /// Claude's own copy of its latest usage reading for this tab's config (`ClaudeUsageSnapshot`): the per-model weekly limits
    /// the status line never sends.
    var saved: ClaudeUsageSnapshot?
}

// MARK: - The folder, watched

/// Watches the status folder with a dispatch source (no polling): every change of its entries (the script moving a payload in)
/// schedules one reading of the whole folder a moment later, at most a few a second. Files older than `keep` go.
final class ClaudeStatusWatcher {
    let folder: URL
    /// A session's payload goes an hour after Claude last wrote it: it holds more than the card shows (paths, names).
    var keep: TimeInterval = 3600
    /// The readings after each change, on the main thread.
    var onChange: (([ClaudeStatusReading]) -> Void)?
    private let queue = DispatchQueue(label: "dev.nook.statusline", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var scheduled = false
    /// The terminal of each script parent seen, by pid and the process's start time: a pid the system hands to a new process
    /// is a new key.
    private var terminals: [String: String] = [:]
    var terminalOf: (pid_t) -> String = { ClaudeHooks.terminal(from: $0) }
    /// When a process started, nil once it is gone.
    var processStart: (pid_t) -> String? = { ClaudeStatusWatcher.startTime(of: $0) }

    init(folder: URL = NookStatusLine.statusFolder) { self.folder = folder }

    deinit { source?.cancel() }

    /// Prepares the folder (private, the user's own) and starts watching it; reads what is already there.
    func start() {
        guard source == nil else { return }
        do { try ScreenShotFile.prepare(folder) } catch {
            statusLog.error("status folder not private: \(error.localizedDescription, privacy: .public)")
            return
        }
        let descriptor = open(folder.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        schedule()
    }

    func stop() { source?.cancel(); source = nil }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let readings = self.scan()
            DispatchQueue.main.async { self.onChange?(readings) }
        }
    }

    /// Every session's latest reading in the folder, the stale ones pruned. Runs on the watcher's queue (and in tests).
    func scan(now: Date = Date()) -> [ClaudeStatusReading] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var readings: [ClaudeStatusReading] = []
        var lines: [String] = []
        for name in names {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            // Old payloads, and leftovers of a write that never finished.
            if now.timeIntervalSince(modified) > (name.hasPrefix(".") ? 60 : keep) { unlink(path); continue }
            guard !name.hasPrefix("."), name.hasSuffix(".json"), info.st_size < 1_000_000,
                  let data = manager.contents(atPath: path), let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let json = wrapper["payload"] as? [String: Any], let payload = ClaudeStatusPayload(json: json) else { continue }
            let pid = (wrapper["nook_ppid"] as? NSNumber).map { pid_t(truncating: $0) } ?? 0
            let line = NookStatusLine.isSessionID(payload.sessionID) ? Self.small(folder.appendingPathComponent(payload.sessionID + ".line")) : nil
            if let line { lines += line.components(separatedBy: "\n") }
            readings.append(ClaudeStatusReading(payload: payload, at: modified, tty: pid > 1 ? terminal(of: pid) : nil, line: line))
        }
        NookStatusLine.setShownLines(lines)
        return readings.sorted { $0.at < $1.at }
    }

    private func terminal(of pid: pid_t) -> String? {
        // A process that is gone can't be told apart from one that took its pid: no terminal for it.
        guard let started = processStart(pid) else { return nil }
        let key = "\(pid)@\(started)"
        if let known = terminals[key] { return known.isEmpty ? nil : known }
        let found = terminalOf(pid)
        if terminals.count > 200 { terminals.removeAll() }
        terminals[key] = found
        return found.isEmpty ? nil : found
    }

    /// A regular file of the user's own, small enough to be a status line's output, as text.
    private static func small(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size < 64_000 else { return nil }
        return FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The process's start time ("1791500000.123456"), nil when there is no such process.
    static func startTime(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&request, u_int(request.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return "\(start.tv_sec).\(start.tv_usec)"
    }
}

// MARK: - Readings to tabs

extension AppModel {
    /// Hands each Claude tab its live figures: its own reading (found by its record's path, its session id, or its terminal),
    /// and its config folder's freshest rate limits, which every tab of that folder shares. Claude's own copy of its usage reading
    /// for each folder follows a moment later (`refreshUsageSnapshots`).
    func applyStatus(_ readings: [ClaudeStatusReading]) {
        statusReadings = readings
        assignStatus(readings)
        refreshUsageSnapshots()
    }

    /// Reads again, off the main thread, the usage snapshot of every config folder a tab or a reading belongs to (a stat when
    /// nothing changed), and hands the tabs whatever changed.
    func refreshUsageSnapshots() {
        let folders = Set(statusReadings.compactMap(\.payload.configFolder) + sessions.compactMap { $0.transcript.flatMap { Self.configFolder(of: $0.url) } })
        guard !folders.isEmpty else { return }
        let reader = usageSnapshotReader
        usageSnapshotQueue.async { [weak self] in
            var found: [String: ClaudeUsageSnapshot] = [:]
            for folder in folders { found[folder] = reader.snapshot(config: folder) }
            DispatchQueue.main.async {
                guard let self, found != self.usageSnapshots else { return }
                self.usageSnapshots = found
                self.assignStatus(self.statusReadings)
            }
        }
    }

    private func assignStatus(_ readings: [ClaudeStatusReading]) {
        var limits: [String: (ClaudeStatusPayload.RateLimits, Date)] = [:]
        for reading in readings {
            guard let folder = reading.payload.configFolder, let found = reading.payload.rateLimits else { continue }
            if limits[folder].map({ $0.1 < reading.at }) ?? true { limits[folder] = (found, reading.at) }
        }
        for session in sessions {
            let record = session.transcript?.url
            let own = readings.last { reading in
                if let record, reading.payload.transcriptPath == record.path { return true }
                if let record, record.deletingPathExtension().lastPathComponent == reading.payload.sessionID { return true }
                if let id = session.claudeSessionID, id == reading.payload.sessionID { return true }
                guard let tty = reading.tty, record == nil else { return false }
                return tty == session.agentTTY
            }
            let folder = own?.payload.configFolder ?? record.map { Self.configFolder(of: $0) } ?? nil
            let shared = folder.flatMap { limits[$0] }
            // Claude's snapshot alone makes no live figures: they come with its status line, which the user turned on.
            let live = own == nil && shared == nil ? nil
                : ClaudeLiveUsage(session: own?.payload, sessionAt: own?.at, limits: shared?.0, limitsAt: shared?.1, saved: folder.flatMap { usageSnapshots[$0] })
            if session.liveUsage != live { session.liveUsage = live }
            // Nook's own usage card is made of these figures: with none left it has nothing to show.
            if live == nil, session.usageCardOpen { session.usageCardOpen = false }
        }
    }

    /// ".../.claude-work" for ".../.claude-work/projects/<project>/<id>.jsonl".
    static func configFolder(of record: URL) -> String? {
        let parts = record.pathComponents
        guard let projects = parts.lastIndex(of: "projects"), projects > 0 else { return nil }
        return NSString.path(withComponents: Array(parts[..<projects]))
    }
}

// MARK: - The user's click

extension AppModel {
    /// "Límites en vivo" in Permisos: Nook's status line into every config folder, or out of them, after the user confirms. The
    /// only way it is ever installed or removed.
    func toggleClaudeStatusLine() {
        let folders = ClaudeHooks.folders()
        let states = NookStatusLine.states(folders: folders)
        // Taken out only where it is in every folder; in some it is put in the rest (as the hooks are), which is what the row's «Activar…» says for "1 de 2 carpetas".
        let installed = !states.isEmpty && states.allSatisfy { if case .on = $0.state { true } else if case .chained = $0.state { true } else { false } }
        let alert = NSAlert()
        // The words are the row's (`ClaudeLimitsPresentation`), where they are held to what is really kept.
        let words = ClaudeLimitsPresentation.confirmation(installed: installed, files: ClaudeHooks.describe(folders), chains: states.contains { if case .foreign = $0.state { true } else { false } })
        alert.messageText = words.title
        alert.informativeText = words.text
        alert.addButton(withTitle: installed ? "Quitar" : "Activar"); alert.addButton(withTitle: "Cancelar")
        capturePrivacy.prepare(alert.window)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if installed {
                try NookStatusLine.uninstall(from: folders)
                notice = "Límites en vivo desactivados."
            } else {
                let skipped = try NookStatusLine.install(in: folders)
                notice = skipped.isEmpty ? "Límites en vivo activados. Cada sesión de Claude los envía al responder."
                    : skipped.count == folders.count
                    ? "No se activaron los límites en vivo: \(ClaudeHooks.describe(skipped)) tiene una línea de estado que Nook no puede encadenar. No se modificó."
                    : "Límites en vivo activados, salvo en \(ClaudeHooks.describe(skipped)): su línea de estado no es un comando que Nook pueda encadenar, y se dejó como estaba."
            }
        } catch { notice = error.localizedDescription }
        refreshStatusWatcher()
    }

    /// The status folder is watched (and created) only while Nook's status line is on in some config folder: their settings are
    /// read off the main thread. Off, the tabs lose their live figures.
    func refreshStatusWatcher() {
        guard let watcher = statusWatcher else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let on = NookStatusLine.states().contains { $0.state.isNooks }
            DispatchQueue.main.async {
                if on { watcher.start() } else { watcher.stop(); self?.applyStatus([]) }
            }
        }
    }
}
