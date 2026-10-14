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
    /// "interactive" for a terminal's Claude, "bg" for a session Claude runs in the background (2.1.299 and later).
    var kind: String?
    /// A background session's job ("782bea23"): it keeps it across a /clear, which changes its session id.
    var jobID: String?
    /// The job a terminal's Claude moved its session to (moved to the background). Its `sessionId` then stays the one it had, whose
    /// record ends there; the conversation goes on in the background session of that job, which the terminal shows.
    var parkedJobID: String?

    /// Claude's file is a few hundred bytes; anything much larger is not one.
    static let maxBytes = 64 * 1024

    /// The file's fields, or nil for anything that isn't one: malformed, too large, or with a session id that isn't plain.
    static func parse(_ data: Data) -> ClaudeSessionFile? {
        guard data.count <= maxBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0, let id = plain(object["sessionId"]) else { return nil }
        var file = ClaudeSessionFile(pid: pid, sessionID: id)
        file.procStart = object["procStart"] as? String
        file.status = object["status"] as? String
        file.cwd = object["cwd"] as? String
        file.updatedAt = (object["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        file.kind = object["kind"] as? String
        file.jobID = plain(object["jobId"])
        file.parkedJobID = plain(object["parkedJobId"])
        return file
    }

    /// An id fit for a file name: letters, digits, "-" and "_".
    private static func plain(_ value: Any?) -> String? {
        guard let id = value as? String, id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Whether this is the file of the background session that runs `job`.
    func runs(job: String) -> Bool { kind == "bg" && jobID == job }

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
/// session id, whichever spoke last when they disagree. A session moved to the background is followed there, through its job's file.
/// Asked on every reading, so it is cheap: the process is looked up once (again only when it is gone), its file is read again only
/// when it changed, and a record is searched for only for a new session id.
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
    /// A session file as last read, by its path, size and modification date: read again only when one of them changes.
    private struct Reading {
        var path: String
        var size: UInt64
        var modified: Date
        var file: ClaudeSessionFile?
    }
    /// The process's own file, last read.
    private var read: Reading?
    /// The file of the background session the process moved its conversation to, last read, and when it was last searched for.
    private var job: (id: String, reading: Reading)?
    private var jobSearched: (id: String, at: Date)?
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
            guard let reading = Self.read(config.appendingPathComponent("sessions/\(process.pid).json").path, cached: read) else { continue }
            read = reading
            if let file = reading.file, file.matches(pid: process.pid, startedAt: process.started) {
                return parked(file, sessions: config.appendingPathComponent("sessions"), now: now) ?? file
            }
        }
        // No file of its own: an older Claude, or the process is gone (Claude restarted in this tab) and is looked up again.
        if lookup.started(process.pid).map({ abs($0.timeIntervalSince(process.started)) < 1 }) != true { self.process = nil }
        return nil
    }

    /// While the process's session is in the background, what the terminal shows: the session its job's file names (a /clear
    /// there moves it too), and the job's status. Nil while it isn't parked, or until the job's file is found (then the process's
    /// own file is all there is).
    private func parked(_ file: ClaudeSessionFile, sessions: URL, now: Date) -> ClaudeSessionFile? {
        guard let id = file.parkedJobID else { job = nil; return nil }
        // The job's file is named by its process's pid, which only reading the folder tells: the one found is followed while it
        // still runs the job, and the folder is searched again only now and then. Caught mid-write or gone, the job's last word
        // stands: going back to the process's own session would show the record that ended when it moved.
        if let known = job, known.id == id, let reading = Self.read(known.reading.path, cached: known.reading), reading.file?.runs(job: id) == true {
            job = (id, reading)
        } else if jobSearched?.id != id || now.timeIntervalSince(jobSearched?.at ?? .distantPast) >= Self.searchInterval {
            jobSearched = (id, now)
            if let found = Self.job(id, in: sessions) { job = (id, found) }
        }
        guard let known = job, known.id == id, let background = known.reading.file else { return nil }
        var shown = file
        shown.sessionID = background.sessionID
        shown.status = background.status
        shown.cwd = background.cwd ?? file.cwd
        shown.updatedAt = max(file.updatedAt ?? .distantPast, background.updatedAt ?? .distantPast)
        return shown
    }

    /// The file at `path` if it can be Claude's, read again only when it changed since `cached`.
    private static func read(_ path: String, cached: Reading?) -> Reading? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= ClaudeSessionFile.maxBytes else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        if let cached, cached.path == path, cached.size == UInt64(info.st_size), cached.modified == modified { return cached }
        let data = FileManager.default.contents(atPath: path).flatMap { $0.count <= ClaudeSessionFile.maxBytes ? $0 : nil }
        return Reading(path: path, size: UInt64(info.st_size), modified: modified, file: data.flatMap(ClaudeSessionFile.parse))
    }

    /// The file of the background session running `id` in a `sessions` folder; of several (one left by a process that is gone),
    /// the one written last.
    private static func job(_ id: String, in sessions: URL) -> Reading? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0.dropLast(5).allSatisfy(\.isNumber) }
            .compactMap { read(sessions.appendingPathComponent($0).path, cached: nil) }
            .filter { $0.file?.runs(job: id) == true }
            .max { ($0.file?.updatedAt ?? .distantPast) < ($1.file?.updatedAt ?? .distantPast) }
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
