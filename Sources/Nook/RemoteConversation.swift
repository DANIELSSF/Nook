import Foundation

// The selected tab's conversation on the phone (docs/REMOTE_API.md, "Conversation lines"), and the event stream that carries it.
//
// The conversation is the text the island shows, split into lines that go out already classified the way the island dresses them
// (`TranscriptClassifier`, `SyntaxHighlighter`, `InlineMarkdown`), so the page draws them as the island does without knowing how.
// It only grows at its end most of the time, so the phone gets the lines from the first one that changed (an append), and the
// whole window again only when the text is another one (a reset, with a new epoch).
//
//   RemoteLines                    lines of a text as the contract's `Line`s, written once as JSON
//   RemoteConversationTracker      the text the phones hold, by lines: what changed since the last one
//   RemoteBroadcaster              the phones with the event stream open: state and conversation for each, pings, paging

// MARK: - Lines

enum RemoteLines {
    /// Lines `range` of `text` (whose lines start at `starts`) as a JSON array of `Line`s. Claude's transcript is classified, its
    /// code coloured and its Markdown read; any other text goes as plain lines. Every range is in UTF-16 units within the line's
    /// own text, as JavaScript counts.
    static func json(_ text: NSString, starts: [Int], range: Range<Int>, transcript: Bool) -> [UInt8] {
        var out: [UInt8] = [0x5B]
        var first = true
        func append(_ line: RemoteJSON) {
            if !first { out.append(0x2C) }
            first = false
            line.write(into: &out)
        }
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= starts.count else { out.append(0x5D); return out }
        let end = range.upperBound < starts.count ? starts[range.upperBound] : text.length
        if !transcript {
            for index in range {
                let lineEnd = index + 1 < starts.count ? starts[index + 1] - 1 : contentEnd(of: text)
                append(plain(index, text.substring(with: NSRange(location: starts[index], length: max(0, lineEnd - starts[index])))))
            }
            out.append(0x5D)
            return out
        }
        // The lines above only give context to the classifier, and the lines below don't count: the text is cut where the range ends.
        let scope = end < text.length ? text.substring(to: end) as NSString : text
        let classified = TranscriptClassifier.lines(in: scope, from: starts[range.lowerBound])
        for (offset, line) in classified.enumerated() where offset < range.count {
            append(self.line(range.lowerBound + offset, line, in: scope))
        }
        out.append(0x5D)
        return out
    }

    /// Where the text's last line ends: before a final line break, which starts no line of its own.
    static func contentEnd(of text: NSString) -> Int {
        text.length > 0 && text.character(at: text.length - 1) == 0x0A ? text.length - 1 : text.length
    }

    static func plain(_ index: Int, _ text: String) -> RemoteJSON {
        .object([("i", .int(index)), ("text", .string(text)), ("role", .string("plain")), ("head", .bool(false)), ("marker", .null), ("name", .null),
                 ("detail", .object([("kind", .string("none"))])), ("spans", .array([])), ("md", .array([]))])
    }

    /// One classified line of Claude's transcript.
    static func line(_ index: Int, _ line: TranscriptClassifier.Line, in text: NSString) -> RemoteJSON {
        let range = line.range
        let content = text.substring(with: range)
        var spans: [RemoteJSON] = []
        var md: [RemoteJSON] = []
        let detail: RemoteJSON
        func code(_ code: NSRange, _ language: SyntaxLanguage) {
            guard code.length > 0 else { return }
            for span in SyntaxHighlighter.spans(in: text, range: code, language: language) {
                let from = span.range.location - range.location
                spans.append(.object([("from", .int(from)), ("to", .int(from + span.range.length)), ("style", .string(style(span.token)))]))
            }
        }
        switch line.detail {
        case .none:
            detail = .object([("kind", .string("none"))])
        case .summary(let summary):
            func count(_ part: NSRange?) -> RemoteJSON { part.flatMap { Int(text.substring(with: $0).dropFirst()) }.map(RemoteJSON.int) ?? .null }
            detail = .object([
                ("kind", .string("summary")), ("path", .string(text.substring(with: summary.path))), ("added", count(summary.added)), ("removed", count(summary.removed)),
                ("pathRange", .range(summary.path, in: range)), ("addedRange", .range(summary.added, in: range)), ("removedRange", .range(summary.removed, in: range)),
            ])
        case .row(let row):
            let kind: String
            switch row.kind {
            case .removed: kind = "removed"
            case .added: kind = "added"
            case .context: kind = "context"
            case .gap: kind = "gap"
            }
            // The number is the digits the row starts with, after its indent.
            let digits = row.kind == .gap ? "" : String(content.drop { $0 == " " }.prefix { $0.isASCII && $0.isNumber })
            detail = .object([("kind", .string("row")), ("row", .string(kind)), ("number", .int(Int(digits))), ("code", .range(row.code, in: range)),
                              ("mark", .range(row.mark, in: range))])
            if row.kind != .gap, let language = row.language { code(row.code, language) }
        case .fence:
            detail = .object([("kind", .string("fence"))])
        case .code(let language, let start):
            detail = .object([("kind", .string("code")), ("language", .string(language.rawValue)), ("start", .int(start - range.location))])
            code(NSRange(location: start, length: NSMaxRange(range) - start), language)
        case .verbatim:
            detail = .object([("kind", .string("verbatim"))])
        }
        // A reply's own text (after its dot, or a whole continuation line) is Markdown, as the island reads it.
        if line.role == .assistant, line.detail == .none, !line.isBlank {
            let textStart = line.marker.map { NSMaxRange($0) } ?? range.location
            if let found = InlineMarkdown.parse(text, range: NSRange(location: textStart, length: max(0, NSMaxRange(range) - textStart))) {
                for run in found.runs {
                    let from = run.range.location - range.location, to = from + run.range.length
                    for (flag, name) in markupNames where run.style.contains(flag) {
                        let url = flag == .link ? found.links.first { NSIntersectionRange($0.range, run.range).length > 0 }?.url : nil
                        md.append(.object([("from", .int(from)), ("to", .int(to)), ("style", .string(name)), ("url", .string(url))]))
                    }
                }
            }
        }
        return .object([
            ("i", .int(index)),
            ("text", .string(content)),
            ("role", .string(line.role.rawValue)),
            ("head", .bool(line.head >= 0 && line.head == range.location)),
            ("marker", .range(line.marker, in: range)),
            ("name", .range(line.name, in: range)),
            ("detail", detail),
            ("spans", .array(spans)),
            ("md", .array(md)),
        ])
    }

    /// The contract's names for a kind of code. `function` is a call; `variable`, `inserted` and `deleted` are the highlighter's own.
    static func style(_ token: SyntaxToken) -> String {
        switch token {
        case .keyword: "keyword"
        case .string: "string"
        case .number: "number"
        case .comment: "comment"
        case .type: "type"
        case .function: "call"
        case .attribute: "attribute"
        case .variable: "variable"
        case .inserted: "inserted"
        case .deleted: "deleted"
        }
    }

    /// Each look a run of Markdown may have, by its name in the contract (one entry per look: a bold link is two).
    static let markupNames: [(MarkupStyle, String)] = [
        (.bold, "bold"), (.italic, "italic"), (.code, "code"), (.link, "link"), (.heading, "heading"), (.bullet, "bullet"), (.hidden, "hidden"),
    ]

    /// Where each line of `text` starts, from the line that starts at `offset` on: a line ends at a line break, and a final line
    /// break starts no line of its own (the classifier counts lines the same way).
    static func starts(of text: NSString, from offset: Int) -> [Int] {
        let length = text.length
        guard offset < length else { return [] }
        var starts = [offset]
        var chars = [unichar](repeating: 0, count: length - offset)
        text.getCharacters(&chars, range: NSRange(location: offset, length: length - offset))
        for (index, char) in chars.enumerated() where char == 0x0A && offset + index + 1 < length { starts.append(offset + index + 1) }
        return starts
    }
}

// MARK: - Tracker

/// The conversation the phones hold: one text by lines, with an epoch that changes when the text is another one. Classifying a line
/// depends only on the lines above it, so a line that did not change keeps its look and needs no sending again: an update is the
/// lines from the first that changed on ("append"), and the phones replace theirs from there. A different text (another tab, an
/// agent's conversation), or a change too big to send that way, is a reset: a new epoch and a fresh window. Used on one queue.
final class RemoteConversationTracker {
    enum Change: Equatable {
        case none
        /// Lines from `from` on are new or changed; the ones before are as they were.
        case append(from: Int)
        /// Another text, or too much changed: a new epoch.
        case reset
    }

    /// Lines a phone gets when it starts on a text.
    static let window = 600
    /// More changed lines than this go as a reset instead.
    static let maxAppend = 1000

    private(set) var key: String?
    private(set) var text: NSString = ""
    private(set) var starts: [Int] = []
    private(set) var transcript = false
    private(set) var epoch = 0
    private var raw: String?
    private var stripped = false
    private var nextEpoch: Int

    init(firstEpoch: Int = 1) { nextEpoch = firstEpoch }

    var count: Int { starts.count }

    /// Takes the text the island shows now.
    func update(_ source: RemoteConversationSource) -> Change {
        if source.key == key, source.stripPrompt == stripped, raw == source.text { return .none }
        // The card's question leaves the end of the text, as on the island.
        let shown = (source.stripPrompt ? AgentPrompt.withoutPrompt(source.text) : source.text) as NSString
        raw = source.text; stripped = source.stripPrompt
        guard source.key == key else {
            key = source.key; transcript = source.transcript
            return replace(with: shown)
        }
        let unchanged = Self.unchangedLines(old: text, starts: starts, new: shown)
        let start = unchanged == 0 ? 0 : min(shown.length, lineEnd(unchanged - 1) + 1)
        let tail = start < shown.length ? RemoteLines.starts(of: shown, from: start) : []
        let total = unchanged + tail.count
        if total - unchanged > Self.maxAppend { return replace(with: shown) }
        let before = starts.count
        text = shown
        starts = Array(starts[0..<unchanged]) + tail
        return unchanged == before && total == before ? .none : .append(from: unchanged)
    }

    /// No conversation (no tab).
    func clear() {
        key = nil; raw = nil; text = ""; starts = []
    }

    private func replace(with shown: NSString) -> Change {
        text = shown
        starts = RemoteLines.starts(of: shown, from: 0)
        epoch = nextEpoch
        nextEpoch += 1
        return .reset
    }

    /// Where line `index`'s characters end (its line break, or the text's end).
    private func lineEnd(_ index: Int) -> Int { index + 1 < starts.count ? starts[index + 1] - 1 : RemoteLines.contentEnd(of: text) }

    /// How many of `old`'s lines, from the first, `new` has unchanged: a line is, when everything up to its end is the same and in
    /// `new` it ends there too (with a line break, or the text's end).
    static func unchangedLines(old: NSString, starts: [Int], new: NSString) -> Int {
        guard !starts.isEmpty else { return 0 }
        let common = LiveTerminalScrollView.commonPrefix(old, new)
        let lastEnd = RemoteLines.contentEnd(of: old)
        func end(_ index: Int) -> Int { index + 1 < starts.count ? starts[index + 1] - 1 : lastEnd }
        // Lines whose end (their line break included) is inside the common part: a prefix of the lines, found by halving.
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if end(middle) < common { low = middle + 1 } else { high = middle }
        }
        // The next line may end exactly where the common part does, the new text ending there or breaking the line there too.
        if low < starts.count, end(low) == common, common == new.length || new.character(at: common) == 0x0A { low += 1 }
        return low
    }

    /// Lines `range` as JSON.
    func lines(_ range: Range<Int>) -> [UInt8] { RemoteLines.json(text, starts: starts, range: range, transcript: transcript) }
}

// MARK: - Broadcaster

/// The phones with the event stream open, and what each of them has: the last state and the conversation's epoch and window. Every
/// picture of the model (`RemoteFrame`, at most a few a second) goes through `publish`: the conversation is brought up to date
/// first, then each phone gets the state when it changed (or it has none yet) and the conversation's update (a reset when it holds
/// another epoch or none). Pings keep the stream open through idle minutes. All of it on its own queue.
final class RemoteBroadcaster: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.nook.remote.events", qos: .userInitiated)
    /// Event streams open at once; one more closes the oldest (a page reloaded, or left open on another device).
    static let maxClients = 6
    static let pingInterval: TimeInterval = 15

    private final class Client {
        let id: Int
        let sink: RemoteEventSink
        var hasState = false
        var epoch: Int?
        /// The first line of the window it was last given; lines it paged in before that are the page's own.
        var windowStart = 0
        init(id: Int, sink: RemoteEventSink) { self.id = id; self.sink = sink }
    }

    private var clients: [Client] = []
    private var serial = 0
    private let tracker = RemoteConversationTracker()
    private var lastState: [UInt8]?
    private var ping: DispatchSourceTimer?
    /// Hears how many streams are open, on the broadcaster's queue, whenever that changes.
    var onCount: ((Int) -> Void)?

    // MARK: Streams

    /// A phone opened the stream: it gets the state and the conversation with the next picture (the caller asks for one now).
    func add(_ sink: RemoteEventSink) {
        let queue = queue
        queue.async { [weak self] in
            guard let self else { return sink.close() }
            self.serial += 1
            let client = Client(id: self.serial, sink: sink)
            let id = client.id
            sink.onClose = { [weak self] in queue.async { self?.remove(id) } }
            self.clients.append(client)
            while self.clients.count > Self.maxClients { self.clients.removeFirst().sink.close() }
            self.startPinging()
            self.onCount?(self.clients.count)
        }
    }

    private func remove(_ id: Int) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients.remove(at: index)
        if clients.isEmpty { ping?.cancel(); ping = nil }
        onCount?(clients.count)
    }

    /// Every stream ends, and the conversation is forgotten (Nook Remote went off).
    func closeAll() {
        queue.async {
            let open = self.clients
            self.clients = []
            self.ping?.cancel(); self.ping = nil
            self.lastState = nil
            self.tracker.clear()
            open.forEach { $0.sink.onClose = nil; $0.sink.close() }
            self.onCount?(0)
        }
    }

    var count: Int { queue.sync { clients.count } }

    private func startPinging() {
        guard ping == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let event = Self.event("ping", Array("{}".utf8))
            self.clients.forEach { $0.sink.write(event) }
        }
        ping = timer
        timer.resume()
    }

    static func event(_ name: String, _ json: [UInt8]) -> Data {
        var data = Data("event: \(name)\ndata: ".utf8)
        data.append(contentsOf: json)
        data.append(contentsOf: [0x0A, 0x0A])
        return data
    }

    // MARK: Pictures

    /// Brings everything up to date with a picture of the model, sends each phone what it lacks, and hands back the whole `State`
    /// as JSON (on the broadcaster's queue).
    func publish(_ frame: RemoteFrame, then: (([UInt8]) -> Void)? = nil) {
        queue.async {
            // Applied whether or not anyone waits for the state (`then?(apply…)` would skip it).
            let state = self.apply(frame)
            then?(state)
        }
    }

    private func apply(_ frame: RemoteFrame) -> [UInt8] {
        let change: RemoteConversationTracker.Change
        if let source = frame.conversation { change = tracker.update(source) } else { tracker.clear(); change = .none }
        let state = frame.state(epoch: tracker.key == nil ? 0 : tracker.epoch).bytes
        let stateChanged = state != lastState
        lastState = state
        let stateEvent = Self.event("state", state)
        for client in clients where stateChanged || !client.hasState {
            client.sink.write(stateEvent)
            client.hasState = true
        }
        guard let tab = frame.conversation?.tab else { return state }
        let count = tracker.count
        // Written once, for every phone that needs the same.
        var window: (from: Int, lines: [UInt8])?
        var appended: [UInt8]?
        for client in clients {
            var resets = change == .reset || client.epoch != tracker.epoch
            // A change that starts before the lines this phone holds would leave it a gap: it gets the window again instead.
            if case .append(let from) = change, from < client.windowStart { resets = true }
            if resets {
                if window == nil {
                    let from = max(0, count - RemoteConversationTracker.window)
                    window = (from, tracker.lines(from..<count))
                }
                client.epoch = tracker.epoch
                client.windowStart = window!.from
                client.sink.write(Self.event("conversation", update(tab: tab, reset: true, from: window!.from, hasEarlier: window!.from > 0, lines: window!.lines)))
            } else if case .append(let from) = change {
                if appended == nil { appended = tracker.lines(from..<count) }
                client.sink.write(Self.event("conversation", update(tab: tab, reset: false, from: from, hasEarlier: client.windowStart > 0, lines: appended!)))
            }
        }
        return state
    }

    private func update(tab: String, reset: Bool, from: Int, hasEarlier: Bool, lines: [UInt8]) -> [UInt8] {
        RemoteJSON.object([("tab", .string(tab)), ("epoch", .int(tracker.epoch)), ("reset", .bool(reset)), ("from", .int(from)),
                           ("hasEarlier", .bool(hasEarlier)), ("transcript", .bool(tracker.transcript)), ("lines", .raw(lines))]).bytes
    }

    // MARK: Paging

    enum Page {
        case lines(RemoteJSON)
        /// The conversation is another one now (another tab or epoch): the page starts over from the stream.
        case moved(epoch: Int)
    }

    /// Up to `limit` lines before line `before` of `tab`'s conversation, brought up to date with `frame` first. `epoch`: the one the
    /// page holds, when it says; another one is refused.
    func page(_ frame: RemoteFrame, tab: String, before: Int, limit: Int, epoch: Int?, then: @escaping (Page) -> Void) {
        queue.async {
            _ = self.apply(frame)
            guard self.tracker.key != nil, frame.conversation?.tab == tab, epoch.map({ $0 == self.tracker.epoch }) ?? true else {
                return then(.moved(epoch: self.tracker.epoch))
            }
            let end = min(max(0, before), self.tracker.count)
            let start = max(0, end - limit)
            then(.lines(.object([("lines", .raw(self.tracker.lines(start..<end))), ("hasEarlier", .bool(start > 0)), ("epoch", .int(self.tracker.epoch)),
                                 ("from", .int(start))])))
        }
    }
}
