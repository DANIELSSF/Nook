import Darwin
import Foundation

/// One background command Claude Code started in a session: a `Bash` call with `run_in_background`, or one Claude moved to the
/// background once it ran past its timeout. Claude's status line counts them ("· 1 shell") but its conversation only says so in
/// passing; Nook lists them from Claude's record, like its subagents, and shows the output of the one the user enters
/// (`TerminalSession.viewedShell`).
struct ShellActivity: Identifiable, Equatable {
    enum State: String { case running, completed, failed, stopped }

    /// Claude's id for the task ("bjoijjfvn"): its notifications and TaskStop name it.
    var id: String
    /// What it was started for: the call's description ("Build and push the image"), or else the command's first line.
    var name: String
    /// The command as Claude ran it (long ones cut); empty for one known only from its end (started before what was read).
    var command: String
    var state: State
    /// The exit code Claude reported, when it did.
    var exitCode: Int?
    /// Why it was stopped, when Claude said more than that ("sin memoria").
    var note: String?
    /// Started in the foreground and moved to the background once it ran past its timeout.
    var movedToBackground = false
    /// When it started (its call) and ended (its notification or stop); nil when the record doesn't say.
    var started: Date?
    var ended: Date?
    /// Where Claude writes its output, as the record says. Untrusted text: only `ShellOutputFile` opens it.
    var outputPath: String?

    var isRunning: Bool { state == .running }

    /// The state in words: "en curso", "terminó", "falló (código 1)", "detenido".
    var stateText: String {
        switch state {
        case .running: return "en curso"
        case .completed: return exitCode.map { $0 == 0 ? "terminó" : "terminó (código \($0))" } ?? "terminó"
        case .failed: return exitCode.map { "falló (código \($0))" } ?? "falló"
        case .stopped: return note.map { "detenido (\($0))" } ?? "detenido"
        }
    }

    /// "45s", "3m 12s", "1h 4m" (`SubagentWatch.duration`): from its start to its end, or to `now` while it runs; nil without a
    /// start. Not kept in the list, so a running shell doesn't republish it every second: a row that shows it ticks on its own.
    func duration(at now: Date = Date()) -> String? {
        started.map { SubagentWatch.duration((ended ?? now).timeIntervalSince($0)) }
    }

    /// The state and the time: "en curso · 3m 12s", "falló (código 1) · 12s", "detenido".
    func detail(at now: Date = Date()) -> String { ([stateText] + [duration(at: now)].compactMap { $0 }).joined(separator: " · ") }

    /// How many shells Claude's mode line counts ("⏵⏵ auto mode on · 1 shell · ↓ to manage"), from its hints; nil when they
    /// name none. Only a hint: the line is not always on screen, and no count there does not mean none run.
    static func count(inHints hints: [String]) -> Int? {
        for hint in hints {
            guard let found = hint.range(of: #"\b\d+(?=\s+shells?\b)"#, options: .regularExpression) else { continue }
            return Int(hint[found])
        }
        return nil
    }
}

/// The background shells of one record. A `Bash` call's result launches one (its `backgroundTaskId`); a task notification or a
/// TaskStop/KillShell that worked ends it. Only ids this record launched change state: other tasks (subagents, monitors) share
/// the notifications. A background command whose launch is older than what was read joins once it ends, from the notification's
/// own words; a stop of an id nobody knows changes nothing.
struct TranscriptShells {
    struct Launch: Equatable {
        /// Claude's task id.
        let id: String
        /// The `Bash` call's id.
        var call: String?
        var name: String
        var command: String
        var outputPath: String?
        var started: Date?
        var ended: Date?
        var state: ShellActivity.State = .running
        var exitCode: Int?
        var note: String?
        var movedToBackground = false
    }

    private(set) var launches: [Launch] = []

    /// A `Bash` or stop call waiting for its result: what it runs, or which task it stops.
    private struct Call {
        var tool: String
        var command = ""
        var description: String?
        var background = false
        var target: String?
        var date: Date?
    }
    /// Oldest first; a call left without a result (Claude was interrupted) goes once newer ones push it out.
    private var calls: [(id: String, call: Call)] = []

    /// Tools that stop a background task: TaskStop now, KillShell and KillBash in older builds.
    static let stopTools: Set<String> = ["TaskStop", "KillShell", "KillBash"]
    /// The most finished shells kept; long sessions start hundreds.
    static let finishedLimit = 30
    /// How long a finished shell stays listed, as subagents do.
    static let shownAfterEnd: TimeInterval = 600

    mutating func call(id: String, tool: String, input: [String: Any], at date: Date?) {
        var call = Call(tool: tool, date: date)
        if tool == "Bash" {
            call.command = Self.capped(input["command"] as? String ?? "", 2_000)
            call.description = (input["description"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            // A bool, or the string "true" from newer builds (as for agents).
            call.background = input["run_in_background"] as? Bool ?? ((input["run_in_background"] as? String)?.lowercased() == "true")
        } else if Self.stopTools.contains(tool) {
            call.target = (input["task_id"] ?? input["shell_id"] ?? input["bash_id"]) as? String
        } else { return }
        calls.removeAll { $0.id == id }
        calls.append((id, call))
        if calls.count > 64 { calls.removeFirst(calls.count - 64) }
    }

    /// A call's result: a background launch names its task, a stop that worked ends one.
    mutating func result(call id: String, text: String, details: [String: Any]?, error: Bool, at date: Date?) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        let call = calls.remove(at: index).call
        guard !error else { return }
        if call.tool == "Bash" { return launch(call, id: id, text: text, details: details, at: date) }
        // {"message":"Successfully stopped task: b5kaobp6m (caffeinate -dims)","task_id":"b5kaobp6m","task_type":"local_bash"}
        let said = ((details?["message"] as? String) ?? text).lowercased()
        guard said.contains("success") || said.contains("stopped") || said.contains("killed"),
              let target = (details?["task_id"] ?? details?["shell_id"]) as? String ?? call.target,
              let known = launches.lastIndex(where: { $0.id == target }) else { return }
        finish(known, state: .stopped, at: date)
    }

    private mutating func launch(_ call: Call, id: String, text: String, details: [String: Any]?, at date: Date?) {
        // "Command running in background with ID: bjoijjfvn. Output is being written to: /private/tmp/…/bjoijjfvn.output. …", or
        // "Command did not complete within its 120s timeout and was moved to the background (ID: bj74spjc4). Output is being…".
        let named = (details?["backgroundTaskId"] as? String) ?? Self.first(#"(?<=with ID: |\(ID: )[A-Za-z0-9_-]+"#, in: text)
        guard let task = named, Self.isTaskID(task), !launches.contains(where: { $0.id == task }) else { return }
        let firstLine = call.command.components(separatedBy: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        var launch = Launch(id: task, call: id, name: call.description ?? firstLine.map { Self.capped($0, 200) } ?? "Shell", command: call.command)
        launch.outputPath = Self.first(#"(?<=Output is being written to: )/.+?\.output(?=\.?(\s|$))"#, in: text)
        launch.started = call.date ?? date
        launch.movedToBackground = !call.background
        append(launch)
    }

    /// Every `<task-notification>` in a message Claude Code delivered (a user message, its queue, a queued command).
    mutating func notice(_ text: String, at date: Date?) {
        var rest = text[...]
        while let open = rest.range(of: "<task-notification>") {
            // A block ends at its closing tag, or where the next one opens when it has none.
            let close = rest.range(of: "</task-notification>", range: open.upperBound..<rest.endIndex)
            let next = rest.range(of: "<task-notification>", range: open.upperBound..<rest.endIndex)
            let end = [close?.lowerBound, next?.lowerBound].compactMap { $0 }.min() ?? rest.endIndex
            notification(rest[open.upperBound..<end], at: date)
            rest = rest[(close.map { $0.lowerBound == end ? $0.upperBound : end } ?? end)...]
        }
    }

    private mutating func notification(_ block: Substring, at date: Date?) {
        guard let id = Self.tag("task-id", in: block), let status = Self.tag("status", in: block),
              let state = Self.state(status: status) else { return }
        let summary = Self.tag("summary", in: block) ?? ""
        let code = Self.first(#"(?<=exit code )-?\d+"#, in: summary).flatMap { Int($0) }
        // "… was stopped because the system is running low on memory"
        let note = summary.lowercased().contains("low on memory") ? "sin memoria" : nil
        if let index = launches.lastIndex(where: { $0.id == id }) {
            if launches[index].outputPath == nil { launches[index].outputPath = Self.tag("output-file", in: block) }
            return finish(index, state: state, code: code, note: note, at: date)
        }
        // Launched before what was read: only a background command's own words make it a shell. Agents and monitors say otherwise.
        let source = summary as NSString
        guard Self.isTaskID(id), let match = Self.backgroundCommand.firstMatch(in: summary, range: NSRange(location: 0, length: source.length)) else { return }
        let name = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        var launch = Launch(id: id, call: Self.tag("tool-use-id", in: block), name: name.isEmpty ? "Shell" : Self.capped(name, 200), command: "")
        launch.outputPath = Self.tag("output-file", in: block)
        launch.state = state; launch.exitCode = code; launch.note = note; launch.ended = date
        append(launch)
    }

    /// A notification's status as a shell's ending; nil for one that is not an ending.
    static func state(status: String) -> ShellActivity.State? {
        switch status.lowercased() {
        case "running", "pending", "started": return nil
        case "completed", "success", "succeeded", "done": return .completed
        case "failed", "error", "errored": return .failed
        // "killed", "stopped", and any other word: it ended without finishing.
        default: return .stopped
        }
    }

    private mutating func finish(_ index: Int, state: ShellActivity.State, code: Int? = nil, note: String? = nil, at date: Date?) {
        guard launches[index].state == .running else { return }
        launches[index].state = state; launches[index].ended = date
        launches[index].exitCode = code; launches[index].note = note
        trim()
    }

    private mutating func append(_ launch: Launch) {
        launches.append(launch)
        trim()
    }

    private mutating func trim() {
        let finished = launches.indices.filter { launches[$0].state != .running }
        if finished.count > Self.finishedLimit { launches.remove(atOffsets: IndexSet(finished.prefix(finished.count - Self.finishedLimit))) }
    }

    /// The shells as Nook shows them: running ones, and finished ones for ten minutes after they end, in launch order.
    func shown(now: Date = Date()) -> [ShellActivity] {
        launches.filter { $0.state == .running || ($0.ended ?? $0.started).map { now.timeIntervalSince($0) < Self.shownAfterEnd } == true }.map { launch in
            ShellActivity(id: launch.id, name: launch.name, command: launch.command, state: launch.state, exitCode: launch.exitCode, note: launch.note,
                          movedToBackground: launch.movedToBackground, started: launch.started, ended: launch.ended, outputPath: launch.outputPath)
        }
    }

    // MARK: Words

    /// `Background command "Build and push…" completed (exit code 0)`, "… failed with exit code 1", "… was stopped": its description.
    private static let backgroundCommand = try! NSRegularExpression(pattern: #"^Background command "(.*)" (?:completed|failed|was |killed|stopped)"#)

    /// Claude's task ids are short and plain ("bjoijjfvn", "bash_1"); anything else is not one.
    static func isTaskID(_ id: String) -> Bool { id.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }

    /// The text of `<name>…</name>` in a notification, trimmed; nil when it is missing or empty.
    static func tag(_ name: String, in block: Substring) -> String? {
        guard let open = block.range(of: "<\(name)>"), let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex) else { return nil }
        let value = block[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    private static func capped(_ text: String, _ limit: Int) -> String { text.count > limit ? String(text.prefix(limit - 1)) + "…" : text }
}

/// The output file of a background shell, opened only when it is one Claude Code itself writes: a regular file, not a link and
/// with no other name, ending in ".output", inside the user's own `claude-<uid>` folder of the system's temporary directory, and
/// owned by the user. Its path comes from the record's text, where tool results and fetched pages also put words.
enum ShellOutputFile {
    /// Where Claude Code keeps its task output for this user.
    static var roots: [String] { ["/private/tmp/claude-\(getuid())", "/tmp/claude-\(getuid())"] }

    /// The path with every link resolved, when it may be read; nil otherwise.
    static func validated(_ path: String, roots: [String] = roots, owner: uid_t = getuid()) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0"), path.hasSuffix(".output"), !(path as NSString).lastPathComponent.hasPrefix("."),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        // A root must be the user's own folder, not a link someone else left in the shared temporary directory.
        let trusted = roots.compactMap { root -> String? in
            var info = stat()
            guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner else { return nil }
            return resolved(root)
        }
        guard let real = resolved(path), trusted.contains(where: { real.hasPrefix($0 + "/") }) else { return nil }
        // The file itself, not what a link in its place points to (the folders above it may be links: /tmp is one).
        var info = stat()
        guard lstat(path, &info) == 0, isPlainFile(info, owner: owner) else { return nil }
        return real
    }

    /// Opens a validated path without following a link put in its place since, and checks the open file once more.
    static func open(_ path: String, owner: uid_t = getuid()) -> FileHandle? {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isPlainFile(info, owner: owner) else { Darwin.close(descriptor); return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func isPlainFile(_ info: stat, owner: uid_t) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner && info.st_nlink == 1
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// The output of a viewed shell, as the island shows it.
struct ShellOutput: Equatable {
    /// The last part of the output, as a terminal would leave it (`ShellOutputText.clean`).
    var text = ""
    /// Earlier output was left out: only the last `ShellOutputTail.limit` bytes are read and kept.
    var clipped = false
    /// False when there is no output to read: Claude named no file, it is gone, or it is not one Nook may open.
    var available = true
}

/// Follows one shell's output file from its end: the last `limit` bytes when it starts, then only what was appended, and never
/// more than `limit` bytes per look (output that came faster than that is skipped). Finished lines are kept cleaned, up to about
/// `limit` characters; the unfinished last line is kept raw, since a carriage return may still draw over it.
final class ShellOutputTail {
    let path: String
    let limit: Int
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var skipToLineStart = false
    /// The unfinished last line, raw.
    private var partial = Data()
    private var lines = ""
    private var linesLength = 0
    /// Earlier output was skipped or trimmed.
    private(set) var clipped = false
    /// Changes whenever `text` may have.
    private(set) var version = 0

    /// An unfinished line longer than this is cut: at its last carriage return (an overwrite starts over), or else ended.
    static let partialLimit = 64 * 1024

    /// Nil when the path is not a shell output Nook may read (`ShellOutputFile`).
    init?(path: String, limit: Int = 200_000, roots: [String] = ShellOutputFile.roots) {
        guard let real = ShellOutputFile.validated(path, roots: roots), let handle = ShellOutputFile.open(real) else { return nil }
        self.path = real
        self.limit = limit
        self.handle = handle
        let size = self.size
        if size > UInt64(limit) { offset = size - UInt64(limit); skipToLineStart = true; clipped = true }
    }

    var text: String { partial.isEmpty ? lines : lines + ShellOutputText.clean(Self.decoded(partial)) }

    private var size: UInt64 {
        var info = stat()
        return fstat(handle.fileDescriptor, &info) == 0 ? UInt64(max(0, info.st_size)) : 0
    }

    /// Reads what was appended since the last look; false when nothing was.
    @discardableResult func poll() -> Bool {
        let size = self.size
        if size < offset {
            // Written anew and shorter: read again from its start, or its last part.
            reset(); offset = size > UInt64(limit) ? size - UInt64(limit) : 0; skipToLineStart = offset > 0
        }
        if size - offset > UInt64(limit) {
            // More than a look keeps came at once: only its end matters.
            reset(); offset = size - UInt64(limit); skipToLineStart = true; clipped = true
        }
        guard size > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return false }
        offset += UInt64(data.count)
        consume(data)
        version &+= 1
        return true
    }

    private func reset() {
        partial = Data(); lines = ""; linesLength = 0
    }

    private func consume(_ data: Data) {
        var buffer = partial.isEmpty ? data : partial + data
        if skipToLineStart, let newline = buffer.firstIndex(of: 0x0A) {
            buffer = Data(buffer[(newline + 1)...]); skipToLineStart = false
        }
        var start = buffer.startIndex
        var added = ""
        autoreleasepool {
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                added += ShellOutputText.clean(Self.decoded(buffer[start..<newline])) + "\n"
                start = newline + 1
            }
        }
        partial = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        if partial.count > Self.partialLimit {
            if let back = partial.lastIndex(of: 0x0D), partial.endIndex - back <= Self.partialLimit {
                partial = Data(partial[back...])
            } else {
                added += ShellOutputText.clean(Self.decoded(partial.suffix(Self.partialLimit))) + "\n"
                partial = Data()
            }
        }
        guard !added.isEmpty else { return }
        lines += added
        linesLength += added.utf16.count
        guard linesLength > limit else { return }
        // Trimmed at a line start, a quarter at a time, so the viewer's start rarely moves.
        let ns = lines as NSString
        let cut = ns.range(of: "\n", range: NSRange(location: ns.length - limit * 3 / 4, length: limit * 3 / 4)).location
        lines = cut == NSNotFound ? "" : ns.substring(from: cut + 1)
        linesLength = (lines as NSString).length
        clipped = true
    }

    /// UTF-8, without the bytes of a character still being written at the end.
    private static func decoded(_ bytes: Data) -> String {
        var end = bytes.endIndex
        // Back over continuation bytes to the last lead byte: drop it if its character is not all there.
        var back = end
        while back > bytes.startIndex, end - back < 4 {
            back -= 1
            let byte = bytes[back]
            guard byte & 0xC0 == 0x80 else {
                let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if end - back < length { end = back }
                break
            }
        }
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }
}

/// A command's output line as a terminal would leave it on screen.
enum ShellOutputText {
    /// One line (no newline in it): colour, cursor and title codes go; a carriage return starts the line over and what follows
    /// writes over it (a progress bar keeps its last frame); "erase line" codes erase; a backspace steps back; other control
    /// characters go. Tabs stay.
    static func clean(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || (0x7F...0x9F).contains($0.value) }) else { return line }
        let scalars = Array(line.unicodeScalars)
        var cells: [Unicode.Scalar] = []
        var cursor = 0
        func write(_ scalar: Unicode.Scalar) {
            if cursor < cells.count { cells[cursor] = scalar }
            else { cells.append(contentsOf: repeatElement(" ", count: cursor - cells.count)); cells.append(scalar) }
            cursor += 1
        }
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x0D: cursor = 0
            case 0x08: cursor = max(0, cursor - 1)
            case 0x09: write(scalar)
            case 0x1B:
                guard index < scalars.count else { break }
                let kind = scalars[index]
                index += 1
                switch kind {
                case "[": index = csi(scalars, from: index, cells: &cells, cursor: &cursor)
                case "]", "P", "X", "^", "_": index = stringEnd(scalars, from: index)
                case "(", ")", "*", "+", "-", ".", "/", "#", "%", " ": index = min(scalars.count, index + 1)
                default: break   // a two-character code ("ESC 7", "ESC =", "ESC M")
                }
            case 0x9B: index = csi(scalars, from: index, cells: &cells, cursor: &cursor)
            case 0x9D, 0x90, 0x98, 0x9E, 0x9F: index = stringEnd(scalars, from: index)
            case 0..<0x20, 0x7F...0x9F: break
            default: write(scalar)
            }
        }
        return String(String.UnicodeScalarView(cells))
    }

    /// A control sequence after "ESC [": its parameters, then one final character. Only the ones that change a line's text act
    /// (erase in line, column moves); colours and the rest go. Returns where the text goes on; an unfinished one takes the rest.
    private static func csi(_ scalars: [Unicode.Scalar], from start: Int, cells: inout [Unicode.Scalar], cursor: inout Int) -> Int {
        var index = start
        while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) { index += 1 }
        guard index < scalars.count, (0x40...0x7E).contains(scalars[index].value) else { return scalars.count }
        let parameters = String(String.UnicodeScalarView(scalars[start..<index]))
        let number = Int(parameters.split(separator: ";").first ?? "")
        switch scalars[index] {
        case "K":
            switch number ?? 0 {
            case 0: if cursor < cells.count { cells.removeSubrange(cursor...) }
            case 1: for column in 0..<min(cursor + 1, cells.count) { cells[column] = " " }
            default: cells.removeAll()
            }
        case "G": cursor = max(0, (number ?? 1) - 1)
        case "C": cursor += max(1, number ?? 1)
        case "D": cursor = max(0, cursor - max(1, number ?? 1))
        default: break
        }
        return index + 1
    }

    /// The end of a string sequence (a title, a hyperlink): BEL or "ESC \"; an unfinished one takes the rest.
    private static func stringEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            if scalars[index] == "\u{07}" || scalars[index] == "\u{9C}" { return index + 1 }
            if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
            index += 1
        }
        return scalars.count
    }
}
