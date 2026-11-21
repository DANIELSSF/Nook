import Foundation

/// Whether Claude's own record of a session (its JSONL file) holds a message since a moment: as a prompt Claude took (a `user` entry),
/// or as one it queued while it worked (a `queue-operation` enqueue). Claude writes either only once the message has reached it,
/// whatever its screen showed: a long paste shows there only as "[Pasted text #1 +66 lines]", while the record keeps its words (inside
/// `<pasted_content>`). A delivery asks it when the screen never showed the message arrive (`TerminalAppBridge.deliver`), so a message
/// Claude has is never given back to the field to be sent twice (21/11 00:11 and 00:12: the same 66-line paste, taken both times).
/// Only the end of the file is read, where the newest entries are; any thread.
enum ClaudeRecordArrival {
    /// How much of the record's end is read: far more than the entries of one delivery, far less than a long session's whole record.
    static let tailBytes = 1 << 20

    static func holds(_ message: String, in record: URL, since: Date, tailBytes: Int = tailBytes) -> Bool {
        let keys = keys(for: message)
        guard !keys.isEmpty, let lines = tail(of: record, bytes: tailBytes) else { return false }
        return lines.contains { line in
            guard let text = entryText(line, since: since) else { return false }
            let squeezed = squeeze(text)
            return keys.contains { squeezed.contains($0) }
        }
    }

    /// What of the message the record shows, however it wrapped it: its first characters without whitespace (as `MessageEcho.key`),
    /// also without the "!" of Claude's shell mode (recorded as `<bash-input>`) and without the paths of its images (their words). A
    /// message too short to tell has none: it is never taken for another.
    static func keys(for message: String) -> [String] {
        let text = TerminalText.sendable(message)
        let shellless = text.hasPrefix("!") && text.count > 1 ? String(text.dropFirst()) : text
        let words = ClaudeImagePaste.parts(text).words
        var keys: [String] = []
        for candidate in [text, shellless, words] {
            let key = String(squeeze(candidate).prefix(40))
            if key.count >= 3, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// The words of an entry written at or after `since` that carries a message to Claude; nil for any other entry.
    static func entryText(_ line: Substring, since: Date) -> String? {
        // Most entries are Claude's own (replies, tools, bookkeeping): only these two kinds are parsed.
        guard line.contains("\"user\"") || line.contains("queue-operation"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let stamp = object["timestamp"] as? String, let date = date(stamp), date >= since else { return nil }
        switch object["type"] as? String {
        case "queue-operation":
            return object["operation"] as? String == "enqueue" ? object["content"] as? String : nil
        case "user":
            // Notes Claude adds itself, and a compaction's summary (which may quote earlier messages), are no message it got.
            guard object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true,
                  let content = (object["message"] as? [String: Any])?["content"] else { return nil }
            if let text = content as? String { return text }
            let blocks = (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            return blocks.isEmpty ? nil : blocks.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// The record's last `bytes`, as lines; the first one dropped when the read started inside it.
    static func tail(of record: URL, bytes: Int) -> [Substring]? {
        guard let handle = try? FileHandle(forReadingFrom: record) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return start > 0 ? Array(lines.dropFirst()) : lines
    }

    /// Claude's timestamps ("2026-11-21T05:10:53.082Z"), with or without their milliseconds.
    private static func date(_ stamp: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }

    /// Text without whitespace or invisible format characters (Claude strips those from what is pasted into its box).
    private static func squeeze(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace && $0.properties.generalCategory != .format }))
    }
}
