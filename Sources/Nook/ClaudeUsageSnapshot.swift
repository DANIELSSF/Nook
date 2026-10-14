import Darwin
import Foundation

/// Claude's own copy of its latest usage reading: `cachedUsageUtilization` in the config's global file (`.claude.json`). Claude
/// writes it whenever it asks its usage endpoint (opening /usage, at most once a minute) and every session of that config shares
/// it. It holds what the status line never sends: the per-model weekly limits ("Current week (Fable)"). Read only, never written.
///
/// `{"cachedUsageUtilization":{"fetchedAtMs":1791897194355,"accountUuid":"sample-account","utilization":{"limits":[
///   {"kind":"session","group":"session","percent":3,"resets_at":"2026-10-13T18:00:00.233636+00:00",…},
///   {"kind":"weekly_all","group":"weekly","percent":0,…},
///   {"kind":"weekly_scoped","group":"weekly","percent":0,"scope":{"model":{"display_name":"Fable"}},…}],…}},
///  "oauthAccount":{"accountUuid":"sample-account",…}}`
struct ClaudeUsageSnapshot: Equatable {
    struct Limit: Equatable {
        /// Claude's panel title for it: "Current session", "Current week (all models)", "Current week (Fable)".
        var title: String
        /// 0...100.
        var percent: Double
        var resetsAt: Date?
        /// The session's window resets within the day: its reset is written without a date, as Claude does.
        var dated: Bool
    }

    var fetchedAt: Date
    var limits: [Limit]

    /// A reading older than this says too little about the present to be shown.
    static let maxAge: TimeInterval = 24 * 3600
    /// The global file holds the user's whole Claude setup (a few hundred kB); anything far larger is not read.
    static let maxBytes = 16 * 1024 * 1024

    /// The snapshot in a global file's contents; nil without one, or when it is of another account than the one signed in.
    static func parse(_ data: Data) -> ClaudeUsageSnapshot? {
        guard data.count <= maxBytes, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = json["cachedUsageUtilization"] as? [String: Any], let fetched = number(cached["fetchedAtMs"]),
              let utilization = cached["utilization"] as? [String: Any], let rows = utilization["limits"] as? [[String: Any]] else { return nil }
        // Claude drops a reading of an account that is no longer the signed-in one; so does Nook.
        let account = (json["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        guard cached["accountUuid"] as? String == account else { return nil }
        let limits = rows.compactMap { row -> Limit? in
            guard let kind = row["kind"] as? String, let percent = number(row["percent"]) else { return nil }
            let resets = (row["resets_at"] as? String).flatMap(date)
            switch kind {
            case "session": return Limit(title: "Current session", percent: percent, resetsAt: resets, dated: false)
            case "weekly_all": return Limit(title: "Current week (all models)", percent: percent, resetsAt: resets, dated: true)
            case "weekly_scoped":
                let scope = row["scope"] as? [String: Any]
                guard let name = (scope?["model"] as? [String: Any])?["display_name"] as? String, !name.isEmpty, name.count <= 64 else { return nil }
                return Limit(title: "Current week (\(name))", percent: percent, resetsAt: resets, dated: true)
            default: return nil
            }
        }
        return limits.isEmpty ? nil : ClaudeUsageSnapshot(fetchedAt: Date(timeIntervalSince1970: fetched / 1000), limits: limits)
    }

    /// What still describes the present: a limit whose reset has passed is of a window that is over, and a reading older than a
    /// day goes whole. Nil when nothing is left.
    func upToDate(at now: Date) -> ClaudeUsageSnapshot? {
        guard now.timeIntervalSince(fetchedAt) <= Self.maxAge else { return nil }
        var snapshot = self
        snapshot.limits = limits.filter { limit in limit.resetsAt.map { $0 > now } ?? true }
        return snapshot.limits.isEmpty ? nil : snapshot
    }

    /// The global file of a config folder, as Claude picks it: `<folder>/.config.json` when there is one; otherwise
    /// `.claude.json` in the folder for a `CLAUDE_CONFIG_DIR` (`~/.claude-work`), in the home folder for the default `~/.claude`.
    static func files(config folder: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let isDefault = folder.standardizedFileURL.path == home.appendingPathComponent(".claude").standardizedFileURL.path
        return [folder.appendingPathComponent(".config.json"), (isDefault ? home : folder).appendingPathComponent(".claude.json")]
    }

    /// "2026-10-13T18:00:00.233636+00:00": Claude's dates carry microseconds, more than ISO8601DateFormatter reads.
    static func date(_ text: String) -> Date? {
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
}

/// Reads each config folder's snapshot, again only when its global file changed (path, size, modification date). Used on one
/// queue only.
final class ClaudeUsageSnapshotReader {
    private let home: URL
    private var read: [String: (size: Int64, modified: Date, snapshot: ClaudeUsageSnapshot?)] = [:]

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) { self.home = home }

    /// The snapshot of the config folder at `path` (".../.claude-work"); nil without one.
    func snapshot(config path: String) -> ClaudeUsageSnapshot? {
        for file in ClaudeUsageSnapshot.files(config: URL(fileURLWithPath: path), home: home) {
            var info = stat()
            // Claude's own file, a regular one of this user's: a link or someone else's file is never followed.
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            if let known = read[file.path], known.size == info.st_size, known.modified == modified { return known.snapshot }
            let snapshot = info.st_size <= ClaudeUsageSnapshot.maxBytes ? FileManager.default.contents(atPath: file.path).flatMap(ClaudeUsageSnapshot.parse) : nil
            read[file.path] = (info.st_size, modified, snapshot)
            return snapshot
        }
        return nil
    }
}
