import Darwin
import Foundation

/// What Claude Code (2.1.292 and later) writes for each running interactive process: `<config>/sessions/<pid>.json`, with the
/// session the process works on now (`/clear` and `--resume` change it in place), the moment the process started and whether
/// Claude is busy. It names a tab's record exactly, where guessing needs the last prompt on screen.
///
/// `{"pid":7078,"sessionId":"09ce6639-…","cwd":"/Users/me/app","startedAt":1791326330396,"procStart":"Tue Oct  6 22:38:49 2026",
/// "version":"2.1.292","kind":"interactive","status":"busy","updatedAt":1791407427688,…}`
struct ClaudeSessionFile: Equatable {
    var pid: Int32
    var sessionID: String
    /// When the process started, as `ps -o lstart` prints it in the C locale and UTC.
    var procStart: String?
    /// "busy" or "idle", as Claude last wrote it. Not shown anywhere yet.
    var status: String?
    var updatedAt: Date?
    var cwd: String?

    /// Claude's file is a few hundred bytes; anything much larger is not one.
    static let maxBytes = 64 * 1024

    /// The file's fields, or nil for anything that isn't one: malformed, too large, or with a session id that isn't plain.
    static func parse(_ data: Data) -> ClaudeSessionFile? {
        guard data.count <= maxBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let id = object["sessionId"] as? String, id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        var file = ClaudeSessionFile(pid: pid, sessionID: id)
        file.procStart = object["procStart"] as? String
        file.status = object["status"] as? String
        file.cwd = object["cwd"] as? String
        file.updatedAt = (object["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return file
    }

    /// `procStart` as a moment: "Tue Oct  6 22:38:49 2026" (UTC), however many spaces stand between its words.
    static func date(procStart: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: procStart.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    /// Whether this is the file of the process `pid` that started at `start`: macOS hands a finished process's pid to a later one,
    /// and the file of a Claude that is gone may still be there.
    func matches(pid: Int32, startedAt start: Date) -> Bool {
        guard pid == self.pid, let procStart, let written = Self.date(procStart: procStart) else { return false }
        // `ps` prints whole seconds.
        return abs(written.timeIntervalSince1970 - start.timeIntervalSince1970.rounded(.down)) < 1.5
    }
}

/// How the Claude process on a terminal is found: its pid, and when it started. Tests pass their own.
struct ClaudeProcessLookup {
    var pid: (_ tty: String) -> Int32?
    var started: (_ pid: Int32) -> Date?

    static let live = ClaudeProcessLookup(pid: TranscriptLocator.claudePID(tty:), started: TranscriptLocator.startTime(pid:))
}

/// Which record a tab's Claude writes, from what Claude says about it: its process's own file (`ClaudeSessionFile`) and its hooks'
/// session id, whichever spoke last when they disagree. Asked on every reading, so it is cheap: the process is looked up once (again
/// only when it is gone), its file is read again only when it changed, and a record is searched for only for a new session id.
/// Used on the reading queue only.
final class ClaudeRecordLocator {
    /// A session id Claude's hooks reported, and when it last did.
    struct Claim: Equatable {
        var id: String
        var at: Date
    }

    let tty: String
    private let lookup: ClaudeProcessLookup
    /// Claude's configuration folders (`~/.claude`, `~/.claude-work`): their `sessions` and `projects`.
    private let configs: [URL]
    private var process: (pid: Int32, started: Date)?
    private var lookedUp = Date.distantPast
    /// The file last read, by its path, size and modification date: read again only when one of them changes.
    private var read: (path: String, size: UInt64, modified: Date?, file: ClaudeSessionFile?)?
    /// The latest session id asked about and its record; a record not written yet is searched for again after a while.
    private var resolved: (id: String, url: URL?, at: Date)?

    /// How often a terminal whose Claude process isn't known is asked again (`ps`).
    static let lookupInterval: TimeInterval = 10
    /// How often a session id whose record doesn't exist yet (a fresh `/clear`) is searched for again.
    static let searchInterval: TimeInterval = 5

    init(tty: String, lookup: ClaudeProcessLookup = .live, configs: [URL] = TranscriptLocator.configs()) {
        self.tty = tty
        self.lookup = lookup
        self.configs = configs
    }

    /// The verified file of the terminal's Claude process; nil without one (an older Claude, a file of another process).
    func sessionFile(now: Date = Date()) -> ClaudeSessionFile? {
        if process == nil, now.timeIntervalSince(lookedUp) >= Self.lookupInterval {
            lookedUp = now
            process = lookup.pid(tty).flatMap { pid in lookup.started(pid).map { (pid, $0) } }
        }
        guard let process else { return nil }
        for config in configs {
            let path = config.appendingPathComponent("sessions/\(process.pid).json").path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= ClaudeSessionFile.maxBytes else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            if read?.path != path || read?.size != UInt64(info.st_size) || read?.modified != modified {
                let data = FileManager.default.contents(atPath: path).flatMap { $0.count <= ClaudeSessionFile.maxBytes ? $0 : nil }
                read = (path, UInt64(info.st_size), modified, data.flatMap(ClaudeSessionFile.parse))
            }
            if let file = read?.file, file.matches(pid: process.pid, startedAt: process.started) { return file }
        }
        // No file of its own: an older Claude, or the process is gone (Claude restarted in this tab) and is looked up again.
        if lookup.started(process.pid).map({ abs($0.timeIntervalSince(process.started)) < 1 }) != true { self.process = nil }
        return nil
    }

    /// The session Claude says this terminal works on: its file's or its hooks', the newer when they disagree.
    func sessionID(hook: Claim?, now: Date = Date()) -> String? {
        let file = sessionFile(now: now)
        guard let file else { return hook?.id }
        guard let hook, hook.id != file.sessionID else { return file.sessionID }
        return (file.updatedAt ?? .distantPast) >= hook.at ? file.sessionID : hook.id
    }

    /// The record of that session; nil when Claude says nothing (then guessing is up to the caller) or hasn't written it yet.
    func record(hook: Claim?, now: Date = Date()) -> URL? {
        guard let id = sessionID(hook: hook, now: now) else { return nil }
        if let resolved, resolved.id == id, resolved.url != nil || now.timeIntervalSince(resolved.at) < Self.searchInterval { return resolved.url }
        let url = TranscriptLocator.record(session: id, roots: configs.map { $0.appendingPathComponent("projects") })
        resolved = (id, url, now)
        return url
    }
}
