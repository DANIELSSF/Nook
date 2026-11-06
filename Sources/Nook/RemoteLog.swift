import Foundation

// The phone's own errors, written on the Mac (`POST /api/log`, docs/REMOTE_API.md). Safari's Web Inspector needs a cable to reach
// the iPhone; this way what goes wrong in the page (an exception, a call that failed) can be read in ~/Library/Logs/Nook/remote.log.
//
// One line per entry: when, which device, and the entry's fields, every line break and control character escaped, so an entry can
// never pass for another. The file is the user's alone (0600, never written through a link) and capped like the Spaces log: past
// `limit` only its newest half is kept. Each device may write `perMinute` entries a minute; the rest are dropped.

enum RemoteLog {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook/remote.log") }
    /// Past this size only the newest half is kept.
    static let limit = 64_000
    /// The largest entry the page may send.
    static let maxBody = 8 * 1024
    /// Entries a device may write in a minute.
    static let perMinute = 20
    static let levels: Set<String> = ["error", "warn", "info"]
    private static let queue = DispatchQueue(label: "dev.nook.remote.log", qos: .utility)

    /// One entry from the page.
    struct Entry: Equatable {
        var level: String
        var message: String
        var detail: String?
        var url: String?
        var line: Int?
        var userAgent: String?
    }

    /// The line written for `entry` from `device`.
    static func line(_ entry: Entry, device: String, at date: Date = Date()) -> String {
        var parts = ["\(date.formatted(date: .numeric, time: .standard)) [\(escaped(device))] \(entry.level): \(escaped(entry.message))"]
        if let detail = entry.detail { parts.append("detail: " + escaped(detail)) }
        if let url = entry.url { parts.append("url: " + escaped(url) + (entry.line.map { ":\($0)" } ?? "")) } else if let line = entry.line { parts.append("line: \(line)") }
        if let agent = entry.userAgent { parts.append("ua: " + escaped(agent)) }
        return parts.joined(separator: " · ")
    }

    /// `text` on one line: backslashes doubled, line breaks and tabs as `\n` `\r` `\t`, any other control character as `\u{…}`.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}", "\u{2029}": out += "\\u{\(String(scalar.value, radix: 16))}"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) { out += "\\u{\(String(scalar.value, radix: 16))}" }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Appends `line` to the log at `url`, off the caller's thread; `done` (tests) runs once it is written.
    static func append(_ line: String, to url: URL = url, done: (() -> Void)? = nil) {
        queue.async {
            write(line, to: url)
            done?()
        }
    }

    /// The log with `line` added, its newest half only once it grew past `limit` (cut at a line's start), written in place as the
    /// user's alone (`DeliveryJournal.write`).
    static func write(_ line: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var text = RemotePageSource.read(url, limit: limit * 4).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if text.utf8.count > limit {
            // Cut by bytes; a character cut in two decodes as a replacement, and goes with the partial first line.
            let kept = String(decoding: Array(text.utf8.suffix(limit / 2)), as: UTF8.self)
            text = kept.firstIndex(of: "\n").map { String(kept[kept.index(after: $0)...]) } ?? ""
        }
        text += line + "\n"
        DeliveryJournal.write(Data(text.utf8), to: url)
    }
}

/// How many entries each device wrote in the last minute, from any thread.
final class RemoteLogLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String: [Date]] = [:]

    /// Whether `device` may write one more entry now (and counts it if so).
    func allows(_ device: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var recent = (written[device] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < RemoteLog.perMinute else { written[device] = recent; return false }
        recent.append(now)
        written[device] = recent
        return true
    }

    func reset() {
        lock.lock(); written = [:]; lock.unlock()
    }
}
