import AppKit
import Combine
import ApplicationServices

enum AppleScriptText {
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}

/// What of a message may reach an agent's terminal: its text, tabs and line breaks. Any other control character would act instead
/// of being read: Esc ends a paste early or interrupts, ^C interrupts, ^D quits, ^U and ^W wipe Claude's box, DEL deletes, and
/// some terminals take the C1 range (U+0080–U+009F) as escapes of their own. They go, in every way a message travels (typed or
/// pasted, a Terminal tab or a Nook session).
enum TerminalText {
    static func sendable(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.lazy.filter { !isControl($0) })
        return String(kept)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: false
        case 0x00...0x1F, 0x7F...0x9F: true
        default: false
        }
    }
}

struct TerminalTabSnapshot: Identifiable, Equatable {
    let windowID: Int
    let windowTitle: String
    let index: Int
    let tty: String
    let customTitle: String
    let processes: [String]
    let busy: Bool
    let selected: Bool
    let text: String
    /// False when only the visible screen was read (collapsed island), not the scrollback.
    var history = true
    var id: String { tty }
    var agent: TerminalAgent? { TerminalAgent(processes: processes) }
    var title: String {
        if !customTitle.isEmpty { return customTitle }
        let process = agent?.rawValue ?? processes.last(where: { !["login", "zsh", "-zsh", "bash", "-bash", "sh"].contains($0) })
        return process.map { "\(index) · \($0)" } ?? "Terminal · \(index)"
    }
}

enum KeyDelivery { case sent, needsPermission, failed }

/// Where the keyboard was before a key brought Terminal forward (`TerminalAppBridge.press`), so it goes back there once the key is in.
struct KeyFocus: Equatable {
    /// The app in front.
    var app: pid_t
    /// Nook's island had the keyboard. It is a non-activating panel: it takes the keyboard without its app coming to the front.
    var island = false
}

/// A local record of each delivery's steps, so a failed send can be understood afterwards. It holds
/// the user's own messages and stays on this Mac, capped in size, readable by the user alone (0600).
enum DeliveryJournal {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook/deliveries.log") }
    static func append(_ entry: String) { append(entry, to: url) }

    static func append(_ entry: String, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.utf8.count > 200_000 { text = String(text.suffix(100_000)) }
        text += "\(Date().formatted(date: .numeric, time: .standard)) \(entry)\n\n"
        write(Data(text.utf8), to: url)
    }

    /// Writes the whole log in place, created as 0600 and brought back to 0600 if an earlier build left it readable by others
    /// (an atomic write made it 0644: a new file in the umask's mode, renamed over the old one). Never through a link put in its
    /// place (`O_NOFOLLOW`). A write cut short leaves a shorter log, which is all it is.
    static func write(_ data: Data, to url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base + written, buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                written += count
            }
        }
    }
}

/// The message went into Claude's box behind text that was already there; no Enter was pressed.
enum DeliveryError: Error {
    case joined(String)
    /// The message is still in Claude's box after every Enter: not sent, and the field gets it back.
    case stuck
    /// A message with images never showed in Claude's box (nor in its chat): Claude drops the Return of such a paste, so nothing
    /// says it went. Not reported as sent; the field gets it back.
    case unseen
}
enum DeliveryOutcome { case sent, joined(String), failed }

/// Synthetic key presses need the user's Accessibility permission; Nook only asks after explaining why.
enum DirectKeys {
    static var allowed: Bool { AXIsProcessTrusted() }
    /// `tccutil`'s arguments that make macOS forget Nook's Accessibility record.
    static func resetArguments(bundle: String) -> [String] { ["reset", "Accessibility", bundle] }
    static func request() {
        DispatchQueue.global(qos: .userInitiated).async {
            // While Nook is not trusted, any record macOS keeps is either off or stale. A stale one (pinned to an earlier build's
            // exact hash) still shows Nook switched on in System Settings, and toggling it keeps the same record. Forgetting it
            // first lets the prompt below list Nook afresh, so switching it on once is enough.
            if !allowed, let bundle = Bundle.main.bundleIdentifier { _ = try? Shell.run("/usr/bin/tccutil", resetArguments(bundle: bundle)) }
            DispatchQueue.main.async {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
        }
    }
    static func post(_ key: TerminalKey, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down) else { continue }
            // Only the key's own modifier: held ones must not turn Tab into Shift-Tab or an arrow into a word jump.
            event.flags = key.modifiers
            event.postToPid(pid)
        }
    }
}

struct TerminalWindowSnapshot: Identifiable {
    let id: Int
    let title: String
    let tabs: [TerminalTabSnapshot]
}

struct TrackedTerminalTab: Codable, Equatable {
    let windowID: Int
    let tty: String
    /// When the tab's login began (`TerminalTabIdentity`): with it, a later tab that reuses the TTY is not taken for this one.
    /// Saved tabs from before have none.
    var login: String? = nil
}

enum TerminalBridgeError: LocalizedError {
    case automationDenied, failed(String), malformedResponse
    var errorDescription: String? {
        switch self {
        case .automationDenied: return "Permite a Nook controlar Terminal en Ajustes del Sistema → Privacidad y seguridad → Automatización. Después pulsa Buscar de nuevo."
        case .failed(let message): return message
        case .malformedResponse: return "Terminal devolvió una respuesta que no se pudo leer."
        }
    }
}

/// One long-lived helper process runs every script on its own main thread. Launching a process per
/// poll cost far more than the scripts themselves.
final class ScriptHelper {
    static let shared = ScriptHelper()
    private let executable: URL?
    private let arguments: [String]
    private let lock = NSLock()
    private var process: Process?
    private var requests: FileHandle?
    private var responses: FileHandle?
    private var pending = Data()

    /// The helper is replaced, between two requests, once its footprint passes this. It stays near 25 MB however long it polls
    /// (`ScriptHelperTests`); whatever it might leak one day ends here instead of at the gigabytes an undrained pool once reached.
    static let defaultFootprintLimit: Int64 = 160 << 20
    /// Its footprint is read every this many requests: one system call, a leak is caught within a minute of polling.
    static let checkEvery = 20
    private let footprintLimit: Int64
    private var sinceCheck = 0
    /// Asked for from any thread (`recycle`) and honoured before the next request, never in the middle of one.
    private let recycleLock = NSLock()
    private var recycleRequested = false
    /// How many helpers were replaced for their size or on request.
    private(set) var recycled = 0

    init(executable: URL? = Bundle.main.executableURL, arguments: [String] = ["--terminal-script"], footprintLimit: Int64 = ScriptHelper.defaultFootprintLimit) {
        self.executable = executable; self.arguments = arguments; self.footprintLimit = footprintLimit
    }

    /// A fresh helper for the next request (memory pressure, a trim). It never waits for a request in flight.
    func recycle() {
        recycleLock.lock(); recycleRequested = true; recycleLock.unlock()
    }

    /// Between requests: a helper that grew past its limit, or one asked to go, is stopped; the request starts a new one.
    private func recycleIfDue() {
        recycleLock.lock(); let requested = recycleRequested; recycleRequested = false; recycleLock.unlock()
        sinceCheck += 1
        guard let process, process.isRunning else { return }
        var bytes: Int64?
        if !requested {
            guard sinceCheck >= Self.checkEvery else { return }
            sinceCheck = 0
            bytes = MemoryFootprint.of(process.processIdentifier)
            guard let bytes, bytes > footprintLimit else { return }
        }
        if let bytes { memoryLog.error("script helper at \(MemoryFootprint.megabytes(bytes), privacy: .public) MB; replacing it") }
        else { memoryLog.notice("script helper replaced on request") }
        stop()
        recycled += 1
    }

    func run(_ source: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        recycleIfDue()
        var line = try JSONSerialization.data(withJSONObject: ["source": source])
        line.append(0x0A)
        // Nothing has run yet if the request can't be written, so a dead helper is replaced once.
        // A failure after that is never retried: running a `do script` twice would send twice.
        do { try start(); try requests?.write(contentsOf: line) }
        catch { stop(); try start(); try requests?.write(contentsOf: line) }
        do { return try receive() } catch { stop(); throw error }
    }

    private func receive() throws -> [String: Any] {
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let message = Data(pending[..<end])
                pending = Data(pending[(end + 1)...])
                guard let json = try JSONSerialization.jsonObject(with: message) as? [String: Any] else { throw TerminalBridgeError.malformedResponse }
                return json
            }
            // Whatever has arrived; a sized read would wait for bytes a short reply never sends.
            guard let chunk = responses?.availableData, !chunk.isEmpty else { throw TerminalBridgeError.malformedResponse }
            pending.append(chunk)
        }
    }

    private func start() throws {
        if process?.isRunning == true { return }
        guard let executable else { throw TerminalBridgeError.malformedResponse }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Nook's own ends stay out of whatever Nook starts later: SwiftTerm forks tmux without closing inherited descriptors, and a
        // tmux server holding the write end would keep the helper waiting for requests long after Nook quit.
        for handle in [input.fileHandleForWriting, output.fileHandleForReading] { _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) }
        self.process = process
        requests = input.fileHandleForWriting; responses = output.fileHandleForReading; pending = Data()
    }

    private func stop() {
        try? requests?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; requests = nil; responses = nil; pending = Data()
    }
}

/// Terminal owns the shell and PTY. This adapter reads its public scripting
/// interface and addresses input by TTY, never by a potentially reordered tab index.
final class TerminalAppBridge: ObservableObject {
    @Published var windows: [TerminalWindowSnapshot] = []
    @Published var searching = false
    @Published var error: String?
    private(set) var trackedTabs: [TrackedTerminalTab] = []
    var connectedWindowIDs: Set<Int> { Set(trackedTabs.map(\.windowID)) }
    /// Tabs, the TTYs asked for, and when the reading started (to tell stale ones apart).
    var onSnapshot: (([TerminalTabSnapshot], Set<String>, Date) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Reads the tabs for a snapshot script; tests replace it to fail or succeed without Terminal.
    var reader: (String) throws -> [TerminalTabSnapshot] = {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return [] }
        return try TerminalAppBridge.snapshot($0)
    }
    /// Every script that addresses Terminal's tabs runs here, one at a time (`perform`, `refresh`, `openTab`). Each block drains its
    /// own autorelease pool: a reading's descriptors and texts (up to 80,000 characters a tab) go as soon as it is handed over.
    let queue = DispatchQueue(label: "dev.nook.terminal-app", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let deliveryQueue = DispatchQueue(label: "dev.nook.terminal-app.delivery", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var timer: Timer?
    private var reading = false
    private var lightReads = 0
    /// While the island is open the mirror needs the scrollback twice a second; collapsed, the
    /// visible screen every 2 s keeps the notch's activity, and the history follows every 10 s.
    var detailed = false {
        didSet {
            guard detailed != oldValue, timer != nil else { return }
            startMonitoring()
            if detailed { refresh() }
        }
    }
    /// Nobody can see the screen (displays asleep, screen locked, another user's session): nothing is
    /// read until it can be seen again, and then at once. A question still on screen or a turn that
    /// ended meanwhile is noticed on that first reading; Claude's hooks don't depend on reading at all.
    var resting = false {
        didSet {
            guard resting != oldValue else { return }
            if resting {
                paused = timer != nil
                timer?.invalidate(); timer = nil
            } else if paused {
                paused = false
                startMonitoring(); refresh()
            }
        }
    }
    /// Monitoring that a rest stopped, to start again when it ends.
    private var paused = false
    var isMonitoring: Bool { timer != nil }
    static func interval(detailed: Bool) -> TimeInterval { detailed ? 0.5 : 2 }

    static var terminalPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
    }

    private static func authorizeTerminal() throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent { throw TerminalBridgeError.automationDenied }
        if status != noErr { throw TerminalBridgeError.failed("No se pudo verificar el permiso de Terminal (\(status)).") }
    }

    static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        // NSAppleScript is a main-thread API. A short-lived helper keeps it on
        // its own main thread while the island stays responsive.
        if !Thread.isMainThread { return try executeInHelper(source) }
        var details: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw TerminalBridgeError.malformedResponse }
        let result = script.executeAndReturnError(&details)
        guard details == nil else {
            let code = details?[NSAppleScript.errorNumber] as? Int
            if code == -1743 { throw TerminalBridgeError.automationDenied }
            throw TerminalBridgeError.failed(details?[NSAppleScript.errorMessage] as? String ?? "No se pudo conectar con Terminal.")
        }
        return result
    }

    private static func executeInHelper(_ source: String) throws -> NSAppleEventDescriptor {
        descriptor(try helperValue(source))
    }

    /// The helper's answer as it arrives (lists, numbers, booleans and strings), or its error.
    private static func helperValue(_ source: String) throws -> Any {
        let json = try ScriptHelper.shared.run(source)
        if let code = json["errorCode"] as? Int {
            if code == -1743 { throw TerminalBridgeError.automationDenied }
            if code == -1712 { throw TerminalBridgeError.failed("Terminal tardó demasiado en responder. Si macOS muestra un permiso para Nook, acéptalo y pulsa Buscar de nuevo.") }
            throw TerminalBridgeError.failed(json["error"] as? String ?? "No se pudo conectar con Terminal.")
        }
        guard let value = json["value"] else { throw TerminalBridgeError.malformedResponse }
        return value
    }

    /// Runs a snapshot script and reads its tabs. Off the main thread the helper's answer is read as it arrives, without turning every
    /// tab's text into an Apple event descriptor and back: two more copies of up to 80,000 characters a tab, twice a second.
    static func snapshot(_ source: String) throws -> [TerminalTabSnapshot] {
        if Thread.isMainThread { return try decode(execute(source)) }
        return try decode(rows: helperValue(source))
    }

    private static func descriptor(_ value: Any) -> NSAppleEventDescriptor {
        if let list = value as? [Any] {
            let result = NSAppleEventDescriptor.list()
            for (i, item) in list.enumerated() { result.insert(descriptor(item), at: i + 1) }
            return result
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return NSAppleEventDescriptor(boolean: number.boolValue) }
            return NSAppleEventDescriptor(int32: number.int32Value)
        }
        return NSAppleEventDescriptor(string: value as? String ?? "")
    }

    static func structuredValue(_ descriptor: NSAppleEventDescriptor) -> Any {
        if descriptor.descriptorType == typeAEList { return (0..<descriptor.numberOfItems).map { structuredValue(descriptor.atIndex($0 + 1)!) } }
        if descriptor.descriptorType == typeTrue { return true }
        if descriptor.descriptorType == typeFalse { return false }
        if descriptor.descriptorType == typeBoolean { return descriptor.booleanValue }
        if descriptor.descriptorType == typeSInt32 { return descriptor.int32Value }
        return descriptor.stringValue ?? ""
    }

    /// The helper's side of `ScriptHelper`: one JSON request per line in, one JSON response per line
    /// out, until Nook closes the pipe. Repeated scripts (the mirror's poll) compile once.
    static func serveFromCLI() {
        // Register this command-line helper with AppKit for inter-app Apple events.
        NSApplication.shared.setActivationPolicy(.prohibited)
        // The helper goes with Nook, even when another process still holds the requests pipe open (an orphaned helper is still
        // "Nook" to Launch Services, which then only activates it instead of opening the app).
        let parent = getppid()
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        watch.setEventHandler { exit(0) }
        watch.resume()
        if getppid() != parent { exit(0) }
        defer { watch.cancel() }
        var compiled: [String: NSAppleScript] = [:]
        while let line = readLine() {
            // No run loop ever turns here to drain the main thread's autorelease pool, so each request
            // drains its own: otherwise every result descriptor, its text and the reply stayed alive for
            // the helper's whole life (GBs within a day of polling).
            autoreleasepool {
                guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let source = request["source"] as? String else {
                    reply(["errorCode": -1, "error": "No se pudo leer la petición."]); return
                }
                if compiled.count > 16 { compiled.removeAll() }
                let script = compiled[source] ?? NSAppleScript(source: source)
                compiled[source] = script
                var details: NSDictionary?
                let result = script?.executeAndReturnError(&details)
                if let details { reply(["errorCode": details[NSAppleScript.errorNumber] ?? -1, "error": details[NSAppleScript.errorMessage] ?? "No se pudo conectar con Terminal."]) }
                else if let result { reply(["value": structuredValue(result)]) }
                else { reply(["errorCode": -1, "error": "No se pudo ejecutar la conexión."]) }
            }
        }
    }

    private static func reply(_ response: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    static func snapshotScript(windowIDs: Set<Int>? = nil, ttys: Set<String>? = nil, includeText: Bool, screenOnly: Bool = false) -> String {
        let ids = (windowIDs ?? []).sorted().map(String.init).joined(separator: ", ")
        let filter = windowIDs == nil ? "true" : "(id of w) is in {\(ids)}"
        let tabFilter = ttys.map { "tty of t is in {" + $0.sorted().map(AppleScriptText.literal).joined(separator: ", ") + "}" } ?? "true"
        // The visible screen is far cheaper for Terminal to produce than the whole scrollback. Inside
        // the loop `t` is a reference and `contents of t` would dereference it into the tab itself, so
        // the tab's text property is asked for through an explicit element specifier.
        let text = !includeText ? "set screenText to \"\"" : screenOnly ? "set screenText to contents of tab tabIndex of w" : """
            set screenText to history of t
            if (length of screenText) > 80000 then set screenText to text -80000 thru -1 of screenText
            """
        return """
        with timeout of \(includeText ? 4 : 30) seconds
            if application id "com.apple.Terminal" is not running then return {}
            tell application id "com.apple.Terminal"
                set rows to {}
                repeat with w in windows
                    if \(filter) then
                        set tabIndex to 0
                        repeat with t in tabs of w
                            set tabIndex to tabIndex + 1
                            if \(tabFilter) then
                                \(text)
                                set end of rows to {id of w, name of w, tabIndex, tty of t, custom title of t, processes of t, busy of t, selected of t, screenText}
                            end if
                        end repeat
                    end if
                end repeat
                return rows
            end tell
        end timeout
        """
    }

    static func decode(_ result: NSAppleEventDescriptor) throws -> [TerminalTabSnapshot] {
        guard result.descriptorType == typeAEList else { throw TerminalBridgeError.malformedResponse }
        var tabs: [TerminalTabSnapshot] = []
        for i in 0..<result.numberOfItems {
            guard let row = result.atIndex(i + 1), row.numberOfItems == 9,
                  let tty = row.atIndex(4)?.stringValue, !tty.isEmpty else { throw TerminalBridgeError.malformedResponse }
            let list = row.atIndex(6)
            let processes = (0..<(list?.numberOfItems ?? 0)).compactMap { list?.atIndex($0 + 1)?.stringValue }
            tabs.append(TerminalTabSnapshot(windowID: Int(row.atIndex(1)!.int32Value), windowTitle: row.atIndex(2)?.stringValue ?? "Terminal", index: Int(row.atIndex(3)!.int32Value), tty: tty, customTitle: row.atIndex(5)?.stringValue ?? "", processes: processes, busy: row.atIndex(7)?.booleanValue ?? false, selected: row.atIndex(8)?.booleanValue ?? false, text: row.atIndex(9)?.stringValue ?? ""))
        }
        return tabs
    }

    /// `decode` for the helper's answer as it arrives: the same rows, the same checks.
    static func decode(rows value: Any) throws -> [TerminalTabSnapshot] {
        guard let rows = value as? [Any] else { throw TerminalBridgeError.malformedResponse }
        return try rows.map { item in
            guard let row = item as? [Any], row.count == 9, let tty = row[3] as? String, !tty.isEmpty else { throw TerminalBridgeError.malformedResponse }
            func string(_ index: Int) -> String? { row[index] as? String ?? (row[index] as? NSNumber)?.stringValue }
            func number(_ index: Int) -> Int { (row[index] as? NSNumber)?.intValue ?? Int(row[index] as? String ?? "") ?? 0 }
            func flag(_ index: Int) -> Bool { (row[index] as? NSNumber)?.boolValue ?? false }
            let processes = (row[5] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
            return TerminalTabSnapshot(windowID: number(0), windowTitle: string(1) ?? "Terminal", index: number(2), tty: tty, customTitle: string(4) ?? "",
                                       processes: processes, busy: flag(6), selected: flag(7), text: string(8) ?? "")
        }
    }

    func discover(completion: (([TerminalWindowSnapshot]) -> Void)? = nil) {
        guard !searching else { return }
        searching = true; error = nil
        // Discovery must not launch a new Terminal or open another shell.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else {
            windows = []; searching = false; completion?([]); return
        }
        queue.async { [weak self] in
            let result = Result { () throws -> [TerminalTabSnapshot] in
                try Self.authorizeTerminal()
                return try Self.snapshot(Self.snapshotScript(includeText: false))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.searching = false
                switch result {
                case .success(let tabs):
                    let ids = tabs.reduce(into: [Int]()) { if !$0.contains($1.windowID) { $0.append($1.windowID) } }
                    self.windows = ids.map { id in
                        let group = tabs.filter { $0.windowID == id }
                        return TerminalWindowSnapshot(id: id, title: group.first?.windowTitle ?? "Terminal", tabs: group)
                    }
                    completion?(self.windows)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func connect(tab: TerminalTabSnapshot, login: String? = nil) {
        trackedTabs.removeAll { $0.tty == tab.tty }
        trackedTabs.append(TrackedTerminalTab(windowID: tab.windowID, tty: tab.tty, login: login))
        error = nil
        startMonitoring()
        refresh()
    }

    func restore(tabs: [TrackedTerminalTab]) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return }
        trackedTabs = tabs
        if !connectedWindowIDs.isEmpty { startMonitoring(); refresh() }
    }

    /// Follows a tab that moved to another window.
    func adopt(_ tabs: [TerminalTabSnapshot]) { trackedTabs = Self.adopted(trackedTabs, tabs) }
    static func adopted(_ tracked: [TrackedTerminalTab], _ tabs: [TerminalTabSnapshot]) -> [TrackedTerminalTab] {
        tracked.map { entry in tabs.first { $0.tty == entry.tty }.map { TrackedTerminalTab(windowID: $0.windowID, tty: entry.tty, login: entry.login) } ?? entry }
    }

    func disconnect(tty: String) {
        trackedTabs.removeAll { $0.tty == tty }
        if connectedWindowIDs.isEmpty { timer?.invalidate(); timer = nil; paused = false }
    }

    func startMonitoring() {
        timer?.invalidate()
        // Connected while nobody can see the screen: it starts when the rest ends.
        guard !resting else { timer = nil; paused = true; return }
        // No overlapping Apple events; all scripting work stays off the UI thread.
        let interval = Self.interval(detailed: detailed)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !reading, delivering == 0, !resting, !trackedTabs.isEmpty else { return }
        reading = true
        let ttys = Set(trackedTabs.map(\.tty))
        let requested = Date()
        let history = detailed || lightReads % 5 == 0
        let reader = self.reader
        lightReads = detailed ? 0 : lightReads + 1
        queue.async { [weak self] in
            let result = Result { () throws -> [TerminalTabSnapshot] in
                // Every window is searched (text is read only for the followed TTYs): a tab dragged to
                // another window keeps being followed instead of looking closed.
                return try reader(Self.snapshotScript(ttys: ttys, includeText: true, screenOnly: !history))
                    .map { var tab = $0; tab.history = history; return tab }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                switch result {
                case .success(let tabs):
                    self.error = nil
                    self.adopt(tabs)
                    let activeTTYs = Set(self.trackedTabs.map(\.tty))
                    let scope = ttys.intersection(activeTTYs)
                    self.onSnapshot?(tabs.filter { scope.contains($0.tty) }, scope, requested)
                case .failure(let error):
                    // One notice per failing streak: the same failure on every poll would bring it back as soon as it is closed.
                    let message = error.localizedDescription, repeated = self.error == message
                    self.error = message
                    if !repeated { self.onFailure?(message) }
                    if case TerminalBridgeError.automationDenied = error { self.timer?.invalidate(); self.timer = nil }
                }
            }
        }
    }

    static func targetScript(windowID: Int, tty: String, action: String) -> String {
        """
        with timeout of 4 seconds
            if application id "com.apple.Terminal" is not running then error "Terminal ya se cerró. No se envió el mensaje."
            tell application id "com.apple.Terminal"
                if not (exists window id \(windowID)) then error "La ventana original ya se cerró."
                set targetWindow to window id \(windowID)
                repeat with t in tabs of targetWindow
                    if tty of t is \(AppleScriptText.literal(tty)) then
                        \(action)
                        return true
                    end if
                end repeat
                error "La pestaña original ya se cerró. No se envió el mensaje."
            end tell
        end timeout
        """
    }

    /// Terminal writes the text and its own Return in one chunk (a byte logger shows `text\r`; a line break inside is `\n`):
    /// a shell runs it. An agent TUI tells typing from pasting by timing, so a short chunk is usually typed (the Return sends
    /// it at once) and a longer one a paste (the Return stays a new line).
    static func typeAction(_ text: String) -> String { "do script \(AppleScriptText.literal(text)) in t" }
    static let returnAction = "do script \"\" in t"

    /// Short one-line messages travel as typed text, as they always have: the agent reads keys and Terminal's own Return
    /// sends them. Anything longer, or with line breaks, would not: Terminal hands a long text over in pieces of 1022 bytes
    /// (byte logger), and Claude took a later piece for typing and its line breaks for Enter, sending half a message.
    /// A message to Claude that ends with Nook's attached images is always pasted: only a paste attaches them as images
    /// (`ClaudeImagePaste`); typed, Claude would get their paths as words.
    static func typesDirectly(_ text: String, agent: TerminalAgent? = nil) -> Bool {
        !text.contains(where: \.isNewline) && text.utf8.count <= typedLimit && !(agent == .claude && MessageAttachments.endsWithAttachments(text))
    }
    static let typedLimit = 200

    /// The message for an agent's tab. A long or multi-line one goes inside bracketed-paste marks (ESC[200~ … ESC[201~, which
    /// `do script` passes through untouched): the agent reads it as one paste however Terminal splits it, and the Return
    /// Terminal adds after the marks is a single Enter. A leading "!" (Claude's shell mode) stays a key in front of the paste.
    /// An Escape in the text itself would end the paste early (or interrupt the agent), so it never travels, nor does any other
    /// control character (`TerminalText`).
    static func messageAction(_ text: String, agent: TerminalAgent? = nil) -> String {
        let clean = TerminalText.sendable(text)
        guard !typesDirectly(clean, agent: agent) else { return typeAction(clean) }
        let bang = clean.hasPrefix("!") && clean.count > 1
        let body = bang ? String(clean.dropFirst()) : clean
        let paste = "(character id 27) & \"[200~\" & \(AppleScriptText.literal(body)) & (character id 27) & \"[201~\""
        return "do script (\(bang ? "\"!\" & " : "")\(paste)) in t"
    }
    /// Keys are delivered only after Terminal confirms this exact tab is selected in its front window.
    static let presentForKeysAction = """
        set selected of t to true
        set miniaturized of targetWindow to false
        set index of targetWindow to 1
        activate
        repeat 40 times
            if frontmost and (selected of t) and (index of targetWindow is 1) then exit repeat
            delay 0.025
        end repeat
        if not (frontmost and (selected of t) and (index of targetWindow is 1)) then error "Terminal no mostró la pestaña elegida; no se envió la tecla."
        """
    /// A key sent with Terminal left where it is (`press`): only when the tab's window already is Terminal's front one, the window
    /// AppKit hands Terminal's keys to, also (as far as it does; the screen tells) while another app is in front. Nothing is raised
    /// or activated, which would show it; the tab is selected if it isn't, which only that window shows.
    static let backgroundKeyAction = """
        if (miniaturized of targetWindow) or (index of targetWindow is not 1) then error "La ventana de la pestaña no es la de delante en Terminal."
        if not (selected of t) then set selected of t to true
        """

    /// The answer to an agent's dialog as one `do script`: the arrows as the bytes a terminal sends for them, and Terminal's own
    /// Return as the Enter that confirms (a multi-select's Enter ticks the box). Nothing comes forward and no key event is
    /// posted, so it needs neither Accessibility nor Terminal in front. The arrows go in their CSI form (ESC [ A, ESC [ B):
    /// what Terminal sends for them unless an app asks for application cursor keys (ESC O A), and both Claude Code's and
    /// Codex's key readers take either form. Claude Code reads every key of one chunk in turn, committing each before the
    /// next, so ↓ ↓ ⏎ in one write lands as three presses; as sequences, never as text, they are never taken for a paste.
    /// nil for keys of any other shape (a text field reached by arrows alone, Tab, Esc) or more arrows than `answerArrowLimit`.
    static func answerText(_ keys: [TerminalKey]) -> String? {
        guard keys.last == .enter else { return nil }
        let arrows = keys.dropLast()
        guard arrows.count <= answerArrowLimit, arrows.allSatisfy({ $0 == .up || $0 == .down }) else { return nil }
        guard !arrows.isEmpty else { return "\"\"" }
        return "(" + arrows.map { "(character id 27) & \"[\($0 == .up ? "A" : "B")\"" }.joined(separator: " & ") + ")"
    }
    static func answerAction(_ keys: [TerminalKey]) -> String? { answerText(keys).map { "do script \($0) in t" } }
    /// A dialog shows at most 12 options (`AgentPrompt`), so every choice fits. 12 arrows and the Return are 37 bytes: well
    /// under the 64 below which Claude Code's reader takes every control byte of a chunk as a key of its own.
    static let answerArrowLimit = 12

    /// What of the user's answer goes into a dialog's text field: no control character (`TerminalText`), its line breaks and
    /// tabs as single spaces, and nothing blank at either end. The field takes several lines (Claude Code 2.1.295 draws it as
    /// a multiline input, and a paste keeps its line breaks), but an answer to a question is a phrase, and its rows would be
    /// read as more of the dialog: the screen check (`AgentPrompt.field(_:shows:)`) must find the answer in the option's row.
    /// Nor does it end in a backslash: Claude's input turns a backslash before the cursor and Enter into a line break instead of
    /// sending (`if(j&&!te&&b.offset>0&&b.text[b.offset-1]==="\\")` in its key handler).
    static func fieldText(_ text: String) -> String {
        var clean = TerminalText.sendable(text)
            .replacingOccurrences(of: #"[ \t]*[\r\n]+[ \t\r\n]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix("\\") { clean = String(clean.dropLast()).trimmingCharacters(in: .whitespaces) }
        return clean
    }

    /// The answer to a dialog's text field as one `do script`: the arrows that reach the field (as `answerText` writes them),
    /// then the text between bracketed-paste marks, and Terminal's own Return as the Enter that sends it. What Claude Code
    /// (2.1.295) does with that chunk, from its source:
    ///
    /// - Its reader splits the chunk into events, in order: each arrow a key, the marks and what lies between them one
    ///   `paste` event (the text, however Terminal cut it, up to 2 s apart), the Return a key. With more than one event in a
    ///   chunk it flushes React's work between them (`if(M&&_)Gt.flushSyncWork()` in its key dispatch), so each event finds
    ///   the screen the previous one left, effects included (a concurrent root: a discrete render's effects run with it).
    /// - The arrow that lands on the free-text option ("Type something.", value `__other__`) makes the option draw a text
    ///   input in its place, which takes focus on mount (`Dh(ref, focus)`); the paste event goes to the focused element
    ///   (`dispatchPasteEvent` → `focusManager.activeElement`), so the text lands in the field, whole, as a paste.
    /// - A Return that arrives while a paste is being applied is held and pressed once it is in (the input's paste hook:
    ///   `if(T.current&&E.key==="return"){E.preventDefault(),w.current=!0;return}`, replayed after a 0 ms timer). Enter in
    ///   the field submits it (`onSubmit`: with text, the option is chosen with it; empty, the dialog is cancelled), so the
    ///   Return always comes after the text.
    ///
    /// The text goes as a paste rather than typed: typed, a digit could pick an option by its number if the highlight were
    /// not on the field yet, and a long run of keys is taken for a paste anyway. nil when there is nothing to write, or for
    /// arrows of any other shape or more than `answerArrowLimit`.
    static func fieldAnswerText(arrows: [TerminalKey], text: String) -> String? {
        guard arrows.count <= answerArrowLimit, arrows.allSatisfy({ $0 == .up || $0 == .down }) else { return nil }
        let clean = fieldText(text)
        guard !clean.isEmpty else { return nil }
        let keys = arrows.map { "(character id 27) & \"[\($0 == .up ? "A" : "B")\"" }
        let paste = ["(character id 27) & \"[200~\"", AppleScriptText.literal(clean), "(character id 27) & \"[201~\""]
        return "(" + (keys + paste).joined(separator: " & ") + ")"
    }
    static func fieldAnswerAction(arrows: [TerminalKey], text: String) -> String? { fieldAnswerText(arrows: arrows, text: text).map { "do script \($0) in t" } }

    /// An option of Claude's question with a preview and the user's notes on it (`AgentPrompt.takesNotes`), as one `do script`: the
    /// arrows to the option (`AgentPrompt.notesArrows(to:)`, as `answerText` writes them), "n", the notes between bracketed-paste
    /// marks, and Terminal's own Return. What Claude Code (2.1.295) does with that chunk, from its source:
    ///
    /// - Its reader splits it into events, in order: each arrow a key, the "n" a key of its own (a run of text between two escape
    ///   sequences), the marks and what lies between them one `paste` event, the Return a key; and it flushes React's work between
    ///   them, so each event finds the screen the previous one left.
    /// - The arrows move the highlight, which marks the question as moved. "n" opens the notes field in the notes row
    ///   (`if(key==="n"&&!ctrl&&!meta)openNotes()`, only while the list has the keys), a text input that takes focus on mount; the
    ///   paste lands in it, whole; a Return that arrives while the paste is applied is held and pressed once it is in.
    /// - Enter in the field (`onSubmit`) closes it and, with notes and a moved highlight, answers the highlighted option. Claude
    ///   keeps the notes with the question and sends them with the answers: `annotations[question] = {preview, notes}`, which the
    ///   model reads as `"question"="option" selected preview: … notes: …`. One question is sent at once; with several the dialog
    ///   moves to the next tab, or to the review step, and the notes go with the rest. The record on screen shows the option only
    ///   ("→ option"), never the notes.
    ///
    /// The field must be closed and empty when this goes (`answerNotes` checks the reading right before): open, the arrows would
    /// move its cursor and the "n" would be typed into it; with notes in it the paste would land inside them, at the cursor it kept.
    /// The write's own script checks that reading's lines again right before writing (`answerScript`).
    ///
    /// Why one write and not two (arrows and "n", a reading that the field opened, then the notes): `do script` always ends in
    /// Terminal's Return, and Claude 2.1.295 has no key that would make it harmless after "n". In the empty field Enter closes it and
    /// answers with what the question already had; a trailing "\" (Enter as a line break) or an unclosed paste only hold in the
    /// field, and in the list, should "n" not have opened it, the Return answers the highlighted option. Keys posted one by one
    /// would need Terminal in front. What remains: Claude changing what it shows between that check and reading the write, a frame.
    /// nil when there is nothing to write, or for arrows of any other shape or more than `answerArrowLimit`.
    static func notesAnswerText(arrows: [TerminalKey], notes: String) -> String? {
        guard arrows.count <= answerArrowLimit, arrows.allSatisfy({ $0 == .up || $0 == .down }) else { return nil }
        let clean = fieldText(notes)
        guard !clean.isEmpty else { return nil }
        let keys = arrows.map { "(character id 27) & \"[\($0 == .up ? "A" : "B")\"" }
        let paste = ["\"n\"", "(character id 27) & \"[200~\"", AppleScriptText.literal(clean), "(character id 27) & \"[201~\""]
        return "(" + (keys + paste).joined(separator: " & ") + ")"
    }
    static func notesAnswerAction(arrows: [TerminalKey], notes: String) -> String? { notesAnswerText(arrows: arrows, notes: notes).map { "do script \($0) in t" } }

    func send(windowID: Int, tty: String, text: String, completion: @escaping (Bool) -> Void) {
        perform(Self.targetScript(windowID: windowID, tty: tty, action: Self.typeAction(text)), completion: completion)
    }

    /// Sends a message to an agent and its Enter separately. Deliveries poll the tab, so they run
    /// beside the mirror's refreshes instead of holding them up.
    /// The steps of the latest deliveries, for the diagnostic the user can copy.
    private(set) var deliveryLog: [String] = []

    /// Mirror refreshes wait while a message is delivered: they share the script helper, and a full
    /// history read in between would delay every check of the delivery.
    private var delivering = 0

    func deliver(windowID: Int, tty: String, text: String, agent: TerminalAgent, completion: @escaping (DeliveryOutcome) -> Void) {
        delivering += 1
        deliveryQueue.async { [weak self] in
            var steps: [String] = []
            let started = Date()
            let result = Result {
                // The box is on the visible screen, which is far quicker to read than the history.
                try Self.deliver(text, agent: agent,
                                 run: { _ = try Self.execute(Self.targetScript(windowID: windowID, tty: tty, action: $0)) },
                                 read: { try Self.snapshot(Self.snapshotScript(windowIDs: [windowID], ttys: [tty], includeText: true, screenOnly: true)).first { $0.tty == tty }?.text },
                                 trace: { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) })
            }
            if case .failure(let error) = result, !(error is DeliveryError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.delivering -= 1
                let entry = "\(agent.title) · «\(text.prefix(60))»\n  " + steps.joined(separator: "\n  ")
                self.deliveryLog = Array((self.deliveryLog + [entry]).suffix(5))
                DeliveryJournal.append(entry)
                if case .failure(DeliveryError.joined(let box)) = result { completion(.joined(box)); return }
                // Not a transport failure: Terminal and the tab are fine, Claude just kept the message (or never showed it).
                if case .failure(DeliveryError.stuck) = result { completion(.failed); return }
                if case .failure(DeliveryError.unseen) = result { completion(.failed); return }
                self.finish(result) { completion($0 ? .sent : .failed) }
            }
        }
    }

    /// `hold`: how long Claude must keep the whole message in its box before Nook presses Enter for it. A typed message is
    /// briefly in the box before Terminal's own Return reaches Claude; an Enter then would land on whatever that Return opened.
    /// `images`: how long a pasted message with images has to show up instead of `echo`: Claude reads (and scales) every image
    /// before its box shows anything.
    struct DeliveryTiming { var poll = 0.1, echo = 3.0, hold = 0.8, settle = 1.5, retries = 2, images = 8.0 }

    /// One step of a delivery: the message itself (in a Terminal tab with Terminal's own Return right after it), or one more Enter.
    enum DeliveryStep: Equatable { case message, enter }

    /// What Claude did with a message `do script` wrote, Return included.
    enum Arrival: Equatable {
        /// It took it: its box emptied, or gave way to a dialog or panel the message opened (`/model`), and the screen changed.
        case taken
        /// The whole message sat in its box (or a dialog's text field) for `hold`: the Return became a new line.
        case waiting
        /// Nothing on screen says either.
        case unseen
    }

    /// Claude used to get its Enter only after its box showed the message, and blind after 3 s otherwise. But Terminal's own
    /// Return already sends a typed message (most of them: the log showed "no se vio en 3 s; Enter igualmente" for every
    /// short one), so that blind Enter landed on whatever the message opened: `/model`'s picker took it as choosing the
    /// current model and closed. Now Enter goes only when Claude visibly holds the message; a message it took gets nothing
    /// more. Claude empties its box when it takes a message; while it still holds the whole one, one more Return follows.
    /// `run` gets the scripts for this Terminal tab: the message (`messageAction`) and Enters (`returnAction`).
    static func deliver(_ text: String, agent: TerminalAgent, timing: DeliveryTiming = .init(), run: (String) throws -> Void, read: () throws -> String?, trace: (String) -> Void = { _ in }) throws {
        // What travels is what the screen is compared with: control characters never reach the box.
        let text = TerminalText.sendable(text)
        try deliver(text, agent: agent, typed: typesDirectly(text, agent: agent), withReturn: true, timing: timing,
                    send: { try run($0 == .enter ? returnAction : messageAction(text, agent: agent)) }, read: read, trace: trace)
    }

    /// The delivery itself, for any transport: `send` writes the message (`typed`, or pasted between bracketed-paste marks; with
    /// its own Return after it when `withReturn`) or one Enter, and `read` returns the screen as it is now. A Terminal tab and a
    /// Nook session's pane (`TerminalSession.send`) go through the same checks.
    ///
    /// A message with images is pasted (`typesDirectly`) and Claude drops the Return of such a paste (`ClaudeImagePaste`): it waits
    /// in the box as "[Image #1]…", and the Enter Nook presses once the box has held it for `hold` is what sends it. Until the box
    /// shows it Claude is reading the images, so nothing else on screen counts as an arrival (`arrival`), and a message that never
    /// shows up is not reported as sent (`DeliveryError.unseen`).
    static func deliver(_ text: String, agent: TerminalAgent, typed: Bool, withReturn: Bool, timing: DeliveryTiming = .init(), send: (DeliveryStep) throws -> Void,
                        read: () throws -> String?, trace: (String) -> Void = { _ in }) throws {
        let images = typed ? 0 : ClaudeImagePaste.parts(text).images.count
        var screen: String?
        /// What Claude's box holds on the latest reading, nil without a box.
        func boxText() -> String? { screen.flatMap { ClaudeComposer.split($0).input } }
        /// The box for the log, at most about 100 characters (its start and its end); without a box, the end of the screen, which
        /// shows why. Only for the log: it is never what the user gets back.
        func box() -> String {
            if let input = boxText() { return Self.excerpt(input) }
            let tail = (screen ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
            return "— sin caja; pantalla: " + (tail.isEmpty ? "vacía" : tail.count > Self.excerptLimit ? "…" + String(tail.suffix(Self.excerptLimit)) : tail)
        }
        func showsMessage() -> Bool {
            screen = (try? read()) ?? nil
            return screen.map { MessageEcho.pending(text, in: $0, agent: agent) } ?? false
        }
        // Claude empties its box when it takes the message; Enter again only while it still holds
        // the whole message (a Return that arrived inside a paste becomes a new line).
        // Retries only while Claude's own input box still holds the whole message: a dialog on
        // screen (even one showing the text just sent) must never get an extra Enter, which would
        // accept its highlighted option.
        // The message showing up in the conversation above the box is Claude taking it, even when its box then shows the
        // same text again as its grey suggestion (after "! infra/gcp/deploy.sh dev" ran, Claude suggests running it again).
        var before: String? { didSet { echoes = before.flatMap { MessageEcho.echoes(of: text, inChatOf: $0) } } }
        var echoes: Int?
        func sent() -> Bool {
            guard let echoes, let now = screen.flatMap({ MessageEcho.echoes(of: text, inChatOf: $0) }) else { return false }
            return now > echoes
        }
        func stillInBox() -> Bool {
            screen = (try? read()) ?? nil
            if sent() { return false }
            return screen.flatMap { ClaudeComposer.split($0).input }.map { MessageEcho.boxHolds($0, text) } ?? false
        }
        func settle() throws {
            for _ in 0..<timing.retries {
                if wait(timing.settle, poll: timing.poll, until: { !stillInBox() }) { trace("caja vacía: enviado"); return }
                trace("seguía en la caja «\(box())»: otro Enter")
                try send(.enter)
            }
            if wait(timing.settle, poll: timing.poll, until: { !stillInBox() }) { trace("caja vacía: enviado"); return }
            // Never a silent loss: the field gets the message back.
            trace("sigue en la caja tras los reintentos; no enviado")
            throw DeliveryError.stuck
        }
        if agent == .claude {
            screen = (try? read()) ?? nil
            before = screen
            trace("caja antes: «\(box())»")
            // The box may already show exactly this message: typed there (pasting would double it), or Claude's grey
            // suggestion, which plain text can't tell apart. Enter sends typed text; a suggestion doesn't take Enter (5/10:
            // "! infra/gcp/deploy.sh dev" stayed through three of them), and then the message is typed the usual way, which
            // replaces the suggestion.
            if let input = screen.flatMap({ ClaudeComposer.split($0).input }), MessageEcho.same(input, text) {
                trace("ya estaba en la caja: Enter")
                try send(.enter)
                let shown = ClaudeComposer.split(screen ?? "").conversation
                func untouched() -> Bool {
                    screen = (try? read()) ?? nil
                    guard let screen, !sent() else { return false }
                    let now = ClaudeComposer.split(screen)
                    return now.conversation == shown && now.input.map { MessageEcho.same($0, text) } == true
                }
                if wait(timing.settle, poll: timing.poll, until: { !untouched() }) { return try settle() }
                // Claude suggests only when idle: while it works, the box holds a real message and typing would double it.
                let working = [before, screen].contains { $0.flatMap { ClaudeComposer.split($0).status?.working } == true }
                if working { return try settle() }
                trace("era la sugerencia gris de Claude: se escribe")
                before = screen
            }
        }
        try send(.message)
        let pictures = images == 0 ? "" : images == 1 ? ", 1 imagen" : ", \(images) imágenes"
        trace(typed ? "escrito con su Enter" : "pegado entre marcas\(withReturn ? " con su Enter" : "") (\(text.utf8.count) bytes\(pictures))")
        do {
            if agent == .claude {
                switch arrival(of: text, before: before, timing: timing, pasted: !typed, read: { screen = (try? read()) ?? nil; return screen }) {
                case .taken:
                    trace("Claude lo tomó: enviado")
                    return
                case .unseen where images > 0:
                    // Claude never showed it: still reading the images, or something else had the keys. No Enter on a guess, and
                    // no "sent" either: the message comes back to the field.
                    trace("no apareció en la caja en \(Int(timing.images)) s; sin Enter, no enviado")
                    throw DeliveryError.unseen
                case .unseen:
                    // No Enter on a guess: it would land on whatever is on screen (a dialog, a picker).
                    trace("sin cambios en \(Int(timing.echo)) s; sin Enter")
                    return
                case .waiting:
                    trace("en la caja «\(box())»")
                }
                // Text typed earlier in Claude's box would go out with the message; the user decides what to keep.
                if let screen, let joined = MessageEcho.joined(text, in: screen) {
                    trace("unido a texto previo; sin Enter")
                    throw DeliveryError.joined(joined)
                }
                try send(.enter)
                trace(images > 0 ? "Enter (Claude descarta el del pegado con imágenes)" : "Enter")
                return try settle()
            }
            // Codex reads a paste between the marks as one, and the Return after them as its Enter. Typed text keeps the
            // old way: Codex's own paste detection turns that Return into a new line, so Enter follows the echo.
            guard typed else { return }
            let shown = wait(timing.echo, poll: timing.poll, until: showsMessage)
            trace(shown ? "visto en la caja «\(box())»" : "no se vio en \(Int(timing.echo)) s; Enter igualmente")
            try send(.enter)
            trace("Enter")
        } catch let error as DeliveryError {
            throw error
        } catch {
            // The message is already in the box: it must never be pasted a second time. What the box holds, or (without a box on
            // screen) the message itself, is what the user gets told about; never the log's description of the screen.
            trace("error tras pegar: \(error.localizedDescription)")
            throw DeliveryError.joined(boxText().flatMap { $0.isEmpty ? nil : $0 } ?? text)
        }
    }

    /// How much of a box or screen a log line keeps (`DeliveryJournal` holds the user's messages; the header keeps 60 characters).
    static let excerptLimit = 100
    /// `text` for a log line: whole when short, else its start and its end around "…", about `excerptLimit` characters.
    static func excerpt(_ text: String) -> String {
        guard text.count > excerptLimit else { return text }
        return String(text.prefix(excerptLimit * 6 / 10)) + " … " + String(text.suffix(excerptLimit * 4 / 10 - 3))
    }

    /// Watches Claude's screen after the message went. Taken needs two readings in a row (a screen caught mid-redraw has no
    /// box) and a screen that differs from `before`; holding needs the whole message in the box for `timing.hold`, so the
    /// moment between the typed text and Terminal's Return reaching Claude never counts. A dialog's text field counts as
    /// holding only when the message answered that dialog: a dialog the message opened (`/model`) means it was taken.
    ///
    /// A `pasted` message with images is different: Claude reads its images before its box shows anything, for up to
    /// `timing.images`, and the screen may change meanwhile (a spinner, a hint) while the box still shows what it showed before.
    /// So a changed screen counts only once the box has shown some of the message ("[Image #1]", its words); before that, only
    /// its echo in the chat says Claude took it. A box that still shows what it showed before (an "[Image #4]" left there holds a
    /// message that is only images) shows nothing of it yet. The hold starts again whenever the box changes, as images and words
    /// come in.
    static func arrival(of text: String, before: String?, timing: DeliveryTiming, pasted: Bool = false, read: () -> String?, now: () -> Date = Date.init) -> Arrival {
        let answering = before.map { screen in
            let split = ClaudeComposer.split(screen)
            return split.input == nil && AgentPrompt.parse(split.conversation) != nil
        } ?? false
        let echoes = before.flatMap { MessageEcho.echoes(of: text, inChatOf: $0) }
        let images = pasted && !ClaudeImagePaste.parts(text).images.isEmpty
        let boxBefore = images ? before.flatMap { ClaudeComposer.split($0).input } : nil
        let deadline = now().addingTimeInterval(images ? timing.images : timing.echo)
        var holdingSince: Date?, heldBox: String?, takenReadings = 0, landed = !images
        repeat {
            Thread.sleep(forTimeInterval: timing.poll)
            guard let screen = read() else { continue }
            // In the conversation above the box: taken, whatever the box shows (Claude may suggest the same text again).
            if let echoes, let now = MessageEcho.echoes(of: text, inChatOf: screen), now > echoes {
                takenReadings += 1
                if takenReadings >= 2 { return .taken }
                continue
            }
            let input = ClaudeComposer.split(screen).input
            let unchanged = boxBefore != nil && input == boxBefore
            let holds = !unchanged && (answering ? MessageEcho.pending(text, in: screen, agent: .claude) : input.map { MessageEcho.boxHolds($0, text) } ?? false)
            if holds {
                takenReadings = 0
                landed = true
                if images, input != heldBox { holdingSince = nil; heldBox = input }
                let since = holdingSince ?? now()
                holdingSince = since
                if now().timeIntervalSince(since) >= timing.hold { return .waiting }
                continue
            }
            holdingSince = nil
            // Claude is still typing it in ("hol" of "hola"): neither taken nor held yet.
            let typing = !unchanged && (input.map { MessageEcho.partial($0, of: text) } ?? false)
            if typing { landed = true }
            if landed, screen != before, !typing { takenReadings += 1 } else { takenReadings = 0 }
            if takenReadings >= 2 { return .taken }
        } while now() < deadline
        return holdingSince == nil ? .unseen : .waiting
    }

    private static func wait(_ seconds: Double, poll: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            Thread.sleep(forTimeInterval: poll)
            if condition() { return true }
        } while Date() < deadline
        return false
    }

    /// The transports behind `perform` and `press`; tests replace them to observe ordering.
    var runScript: (String) throws -> Void = { _ = try TerminalAppBridge.execute($0) }
    var postKey: (TerminalKey, pid_t) -> Void = { DirectKeys.post($0, to: $1) }
    var directKeysAllowed: () -> Bool = { DirectKeys.allowed }
    var terminalProcess: () -> pid_t? = { TerminalAppBridge.terminalPID }
    /// The transports behind `openTab`: scripts whose answer is read, ⌘T, and the login records.
    var queryScript: (String) throws -> NSAppleEventDescriptor = { try TerminalAppBridge.execute($0) }
    var postNewTab: (pid_t) -> Void = { DirectKeys.postNewTab(to: $0) }
    var loginStampsReader: () -> [String: String] = { TerminalTabIdentity.loginStamps() }
    /// Where the keyboard is now; AppModel adds whether the island has it. Tests replace it.
    var currentFocus: () -> KeyFocus? = { NSWorkspace.shared.frontmostApplication.map { KeyFocus(app: $0.processIdentifier) } }
    /// Gives the keyboard back once a burst of keys is in (`press`). AppModel sets it (the island is its controller's); tests record it.
    var returnFocus: (KeyFocus) -> Void = { _ in }
    /// How long after the last key of a burst the keyboard goes back. The key is already in Terminal's queue (posted right after
    /// the script saw Terminal in front), but AppKit hands a keyDown to the key window, which Terminal loses once it is no longer
    /// in front: it must have read the key by then, which takes it a frame or two even when busy, far below this. The rest of
    /// the wait is for the next key of a burst: a sequence presses it as soon as the last one is in, the key strip's quick taps a
    /// few tenths of a second apart. Every key in that time finds Terminal still in front, and the keyboard goes back once.
    var focusReturnDelay: TimeInterval = 0.35
    /// Direct keys whose script hasn't finished, where the keyboard was before the first of them, whether any of them brought
    /// Terminal forward, and the return planned for it.
    private var keysOut = 0
    private var focusBefore: KeyFocus?
    private var broughtForward = false
    private var focusReturn: DispatchWorkItem?

    /// Keys sent with Terminal left behind (`press`). Off unless the app turns it on (`AppDelegate`): tests and previews never read a
    /// real tab's screen, and a test that wants it replaces `screenReader` too.
    var backgroundKeys = false
    /// Reads a tab's visible screen, the quick reading `deliver` uses, to see whether a key sent in the background arrived.
    var screenReader: (Int, String) throws -> String? = { windowID, tty in
        try TerminalAppBridge.snapshot(TerminalAppBridge.snapshotScript(windowIDs: [windowID], ttys: [tty], includeText: true, screenOnly: true)).first { $0.tty == tty }?.text
    }
    /// The clock and the pause of that wait, and where each attempt is told (`KeyAttempt.log`); tests replace them.
    var keyClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var keyPause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var keyReport: (KeyAttempt) -> Void = { $0.log() }
    /// How long a key sent in the background has to show on screen. Past Claude Code's double-press window (800 ms), so a key
    /// that did arrive but showed late and is pressed again can't read as Esc Esc (its rewind). A key shows within a frame or
    /// two of an agent that isn't busy; this waits on a busy one. A reading every `keyPoll`; two in a row must show it.
    static let keyVerifyWindow: TimeInterval = 1.0
    static let keyPoll: TimeInterval = 0.1
    /// After a key showed, the next ones to the same tab within this time go in the background without the wait: a burst on the
    /// key strip, or a sequence, doesn't wait for each of them.
    static let keyTrust: TimeInterval = 2.0
    /// Until when keys to a tab (by TTY) go unchecked. Only the scripting queue touches it.
    private var trustedUntil: [String: TimeInterval] = [:]

    /// Keys other than Enter are key events. When the tab's window is already Terminal's front one, the key goes with Terminal
    /// left where it is, and a reading of the screen tells whether it arrived (`KeyEffect`): an agent's key with a check, while
    /// `backgroundKeys` is on. Otherwise, or when the screen doesn't show it in time, Terminal must be in front with this tab
    /// selected: the tab comes forward, the key is posted, and once a burst of keys is in, the keyboard goes back where it was
    /// (`planFocusReturn`). Choosing an option of a dialog doesn't come here when it can go as one write (`answer`).
    func press(_ key: TerminalKey, windowID: Int, tty: String, agent: TerminalAgent? = nil, completion: @escaping (KeyDelivery) -> Void) {
        guard key.needsDirectKeys else {
            perform(Self.targetScript(windowID: windowID, tty: tty, action: Self.returnAction)) { completion($0 ? .sent : .failed) }
            return
        }
        guard directKeysAllowed(), let pid = terminalProcess() else { completion(directKeysAllowed() ? .failed : .needsPermission); return }
        // The first key of a burst notes where the keyboard is; the next ones may find Terminal in front, brought by an earlier one.
        focusReturn?.cancel(); focusReturn = nil
        if focusBefore == nil { focusBefore = currentFocus() }
        keysOut += 1
        let background = backgroundKeys && KeyEffect.checkable(key) ? agent : nil
        sendKey(key, to: pid, windowID: windowID, tty: tty, background: background) { [weak self] delivered, forward in
            self?.keysOut -= 1
            if forward { self?.broughtForward = true }
            // A sequence presses its next key from here, before the return is planned. A failed script may have brought
            // Terminal forward all the same, so the keyboard goes back either way.
            completion(delivered ? .sent : .failed)
            self?.planFocusReturn(terminal: pid)
        }
    }

    /// `key` pressed `count` times as one burst (a page of Claude's panel: `AppModel.scrollPanel`): Terminal comes forward once with
    /// the tab selected, the key is posted `count` times in a row, and the keyboard goes back once they are in (`planFocusReturn`),
    /// as for a burst of single presses but with one script instead of one per key. Nothing reads the screen here: the caller sees
    /// where the panel went on its next reading. One key is an ordinary `press`.
    func press(_ key: TerminalKey, count: Int, windowID: Int, tty: String, completion: @escaping (KeyDelivery) -> Void) {
        guard key == .up || key == .down, count <= Self.burstLimit else { completion(.failed); return }
        guard count > 1 else { press(key, windowID: windowID, tty: tty, completion: completion); return }
        guard directKeysAllowed(), let pid = terminalProcess() else { completion(directKeysAllowed() ? .failed : .needsPermission); return }
        focusReturn?.cancel(); focusReturn = nil
        if focusBefore == nil { focusBefore = currentFocus() }
        keysOut += 1
        let run = runScript, post = postKey, pause = keyPause
        queue.async { [weak self] in
            // Posted in the same serialized step that brought the tab forward, like a single key.
            let result = Result {
                try run(Self.targetScript(windowID: windowID, tty: tty, action: Self.presentForKeysAction))
                for index in 0..<count {
                    if index > 0 { pause(Self.burstSpacing) }
                    post(key, pid)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.keysOut -= 1
                self.broughtForward = true
                self.finish(result) { completion($0 ? .sent : .failed) }
                self.planFocusReturn(terminal: pid)
            }
        }
    }
    /// Between two keys of a burst: Terminal takes them in order however close, this only keeps the event queue from flooding.
    static let burstSpacing: TimeInterval = 0.004
    /// The most keys one burst may carry: a page of the tallest panel, and then some.
    static let burstLimit = 200

    /// The transports of one key, taken when it is pressed: the scripting queue uses them while the main thread goes on.
    private struct KeyTransport {
        let run: (String) throws -> Void
        let post: (TerminalKey, pid_t) -> Void
        let read: (Int, String) throws -> String?
        let clock: () -> TimeInterval
        let pause: (TimeInterval) -> Void
        let report: (KeyAttempt) -> Void
    }

    /// One key on the scripting queue: in the background first when `background` names the agent, else (or when that didn't show)
    /// with Terminal in front. `forward`: Terminal was asked to come forward.
    private func sendKey(_ key: TerminalKey, to pid: pid_t, windowID: Int, tty: String, background agent: TerminalAgent?,
                         completion: @escaping (_ delivered: Bool, _ forward: Bool) -> Void) {
        let transport = KeyTransport(run: runScript, post: postKey, read: screenReader, clock: keyClock, pause: keyPause, report: keyReport)
        queue.async { [weak self] in
            let begun = transport.clock()
            var forward = false
            var failure: Error?
            do {
                var late: ((String) -> Bool)?
                if let agent, let self {
                    switch self.sendInBackground(key, to: pid, windowID: windowID, tty: tty, agent: agent, transport) {
                    case .delivered: break
                    case .fallBack(let check): late = check; forward = true
                    }
                } else { forward = true }
                if forward {
                    // The key is posted in the same serialized step that verified the tab, so no selection Nook
                    // queues meanwhile can change the destination. A tab switch made by hand in Terminal in
                    // those milliseconds remains possible; only tmux addresses a session's own terminal.
                    try transport.run(Self.targetScript(windowID: windowID, tty: tty, action: Self.presentForKeysAction))
                    if let late, Self.arrived(late, windowID: windowID, tty: tty, transport) {
                        transport.report(KeyAttempt(key: key, outcome: .late, milliseconds: Int(((transport.clock() - begun) * 1000).rounded())))
                    } else {
                        transport.post(key, pid)
                    }
                }
            } catch { failure = error }
            let result: Result<Void, Error> = failure.map { .failure($0) } ?? .success(())
            let wentForward = forward
            DispatchQueue.main.async { self?.finish(result) { completion($0, wentForward) } }
        }
    }

    private enum BackgroundKey { case delivered, fallBack(((String) -> Bool)?) }

    /// The key with Terminal left where it is (scripting queue only). The tab's window must already be Terminal's front one: the
    /// script never raises it. Right after a key to this tab showed (`keyTrust`) it goes without a check; otherwise the screen is
    /// read before and after, and the key counts once two readings in a row show it (`KeyEffect`) within `keyVerifyWindow`. A key
    /// that didn't show is pressed again with Terminal in front, unless it shows by then (`arrived`); the check comes back for that.
    private func sendInBackground(_ key: TerminalKey, to pid: pid_t, windowID: Int, tty: String, agent: TerminalAgent, _ transport: KeyTransport) -> BackgroundKey {
        let start = transport.clock()
        func report(_ outcome: KeyAttempt.Outcome, _ detail: String = "") {
            transport.report(KeyAttempt(key: key, outcome: outcome, milliseconds: Int(((transport.clock() - start) * 1000).rounded()), detail: detail))
        }
        do { try transport.run(Self.targetScript(windowID: windowID, tty: tty, action: Self.backgroundKeyAction)) }
        catch { trustedUntil[tty] = nil; report(.behind, error.localizedDescription); return .fallBack(nil) }
        if let until = trustedUntil[tty], start < until {
            transport.post(key, pid)
            trustedUntil[tty] = transport.clock() + Self.keyTrust
            report(.trusted)
            return .delivered
        }
        guard let before = try? transport.read(windowID, tty), let shows = KeyEffect.check(key, agent: agent, before: before) else {
            report(.unchecked); return .fallBack(nil)
        }
        transport.post(key, pid)
        var streak = 0
        repeat {
            transport.pause(Self.keyPoll)
            let screen = try? transport.read(windowID, tty)
            streak = screen.map(shows) == true ? streak + 1 : 0
            if streak == 2 {
                trustedUntil[tty] = transport.clock() + Self.keyTrust
                report(.verified)
                return .delivered
            }
        } while transport.clock() - start < Self.keyVerifyWindow
        trustedUntil[tty] = nil
        report(.unverified)
        return .fallBack(shows)
    }

    /// A key sent in the background that hadn't shown, read again once Terminal is in front: two readings in a row that show it
    /// mean it arrived late (a busy agent) and is not pressed a second time.
    private static func arrived(_ shows: (String) -> Bool, windowID: Int, tty: String, _ transport: KeyTransport) -> Bool {
        for reading in 0..<2 {
            if reading > 0 { transport.pause(keyPoll) }
            guard let screen = try? transport.read(windowID, tty), shows(screen) else { return false }
        }
        return true
    }

    /// Once no key has been on its way for `focusReturnDelay`, the keyboard goes back where it was. Not when no key of the burst
    /// brought Terminal forward, nor when Terminal was already in front then (unless the island had the keyboard, which it takes
    /// back without changing the app in front), nor when the user moved to another app meanwhile: Terminal must still be the one
    /// in front, brought by the keys.
    private func planFocusReturn(terminal pid: pid_t) {
        guard keysOut == 0, focusBefore != nil else { return }
        // Every key of the burst went in the background: the keyboard never moved.
        guard broughtForward else { focusBefore = nil; return }
        focusReturn?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keysOut == 0, let before = self.focusBefore else { return }
            self.focusBefore = nil; self.broughtForward = false; self.focusReturn = nil
            guard self.currentFocus()?.app == pid, before.app != pid || before.island else { return }
            self.returnFocus(before)
        }
        focusReturn = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusReturnDelay, execute: work)
    }

    /// Chooses an option of an agent's dialog with `keys` (arrows, then Enter) in one write (`answerAction`): Terminal stays where
    /// it is and no Accessibility is needed. False, with nothing sent, when the keys don't fit it. The write goes only while the tab
    /// still runs a program in its foreground (`answerScript`); otherwise nothing is written, `refused` hears why, and the result is
    /// `.failed` without the bridge's failure (which stops every Terminal tab's session).
    func answer(_ keys: [TerminalKey], windowID: Int, tty: String, refused: @escaping (FieldAnswerError) -> Void = { _ in },
                completion: @escaping (KeyDelivery) -> Void) -> Bool {
        guard let action = Self.answerAction(keys) else { return false }
        let run = runScript
        queue.async { [weak self] in
            let result = Result { try run(Self.answerScript(windowID: windowID, tty: tty, action: action)) }.mapError(Self.answerOutcome)
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error as FieldAnswerError) = result { refused(error); completion(.failed); return }
                self.finish(result) { completion($0 ? .sent : .failed) }
            }
        }
        return true
    }

    /// What an answer's script raises, with nothing written, when the tab no longer runs a program in its foreground: the agent quit
    /// and its shell is back, where an arrow and Terminal's Return would recall and run the last command (`answerScript`).
    static let agentGoneError = "La pestaña ya no tiene un programa en marcha. No se envió nada."
    /// What an answer's script raises, with nothing written, when the screen no longer shows a line the answer was counted from.
    static let screenChangedError = "La pregunta cambió en la pestaña. No se envió nada."

    /// `action` (an answer to the agent's dialog) in tab `tty` of window `windowID`, as `targetScript` sends it, behind checks made in
    /// the same script, right before it, so nothing else runs between them and the write:
    ///
    /// - The tab is `busy`: Terminal's word for a program running in its foreground other than the shell (the agent). Once the agent
    ///   quits the shell is back and the tab isn't busy, and the answer's bytes would go to the shell's line editor: ↑ recalls the last
    ///   command and Terminal's Return runs it. Not for messages sent to a shell on purpose, which never come here.
    /// - With `anchors` (`AgentPrompt.screenAnchors`), the tab's visible screen still holds every one of those lines, exactly: the rows
    ///   with the highlight, the notes row and the key hint as the reading the keys were counted from had them. A highlight moved, the
    ///   notes field opened or a dialog gone since then leaves one of them missing, and nothing is written.
    ///
    /// A check that fails raises `agentGoneError` or `screenChangedError` (`answerOutcome` reads them back).
    static func answerScript(windowID: Int, tty: String, anchors: [String] = [], action: String) -> String {
        """
        with timeout of 4 seconds
            if application id "com.apple.Terminal" is not running then error "Terminal ya se cerró. No se envió el mensaje."
            tell application id "com.apple.Terminal"
                if not (exists window id \(windowID)) then error "La ventana original ya se cerró."
                set targetWindow to window id \(windowID)
                set tabIndex to 0
                repeat with t in tabs of targetWindow
                    set tabIndex to tabIndex + 1
                    if tty of t is \(AppleScriptText.literal(tty)) then
        \(busyGuard)
        \(anchors.isEmpty ? "" : "set screenNow to contents of tab tabIndex of targetWindow\n" + screenGuard(anchors))
                        \(action)
                        return true
                    end if
                end repeat
                error "La pestaña original ya se cerró. No se envió el mensaje."
            end tell
        end timeout
        """
    }

    /// `answerScript`'s first check, on the tab `t`.
    static let busyGuard = "if not (busy of t) then error \(AppleScriptText.literal(agentGoneError))"

    /// `answerScript`'s second check, on the screen's text in `screenNow`: every anchor in it, case and all. (A tab's own `contents`
    /// is asked for through `tab tabIndex of targetWindow`: `contents of t` would dereference the loop's reference instead.)
    static func screenGuard(_ anchors: [String]) -> String {
        (["considering case"] + anchors.map { "if screenNow does not contain \(AppleScriptText.literal($0)) then error \(AppleScriptText.literal(screenChangedError))" }
            + ["end considering"]).joined(separator: "\n")
    }

    /// An answer script's error as the outcome it stands for: a check of `answerScript` that failed wrote nothing (`.agentGone`,
    /// `.changed`); any other error stays as it is.
    static func answerOutcome(_ error: Error) -> Error {
        guard case TerminalBridgeError.failed(let message) = error else { return error }
        if message.contains(agentGoneError) { return FieldAnswerError.agentGone }
        if message.contains(screenChangedError) { return FieldAnswerError.changed }
        return error
    }

    /// One write of an answer through `run`, behind `answerScript`'s checks. A check that failed wrote nothing: `trace` says which,
    /// and its outcome is thrown (`answerOutcome`).
    static func write(_ action: String, anchors: [String] = [], windowID: Int, tty: String, run: (String) throws -> Void,
                      trace: (String) -> Void) throws {
        do { try run(answerScript(windowID: windowID, tty: tty, anchors: anchors, action: action)) } catch {
            let outcome = answerOutcome(error)
            switch outcome as? FieldAnswerError {
            case .agentGone?: trace("la pestaña ya no tiene un programa en marcha; no se escribió")
            case .changed?: trace("la pantalla ya no muestra la pregunta como se leyó; no se escribió")
            default: break
            }
            throw outcome
        }
    }

    // MARK: Answering a dialog's text field

    /// One step of an answer written into a dialog's text field (`answerField`).
    enum FieldStep: Equatable {
        /// The arrows from the highlight to the field, then the answer pasted into it. A Terminal tab's write carries Terminal's
        /// own Return after them (`fieldAnswerAction`); a Nook session's tmux presses nothing after the paste.
        case answer(arrows: [TerminalKey], text: String)
        /// One more Enter.
        case enter
    }

    /// Why an answer to a dialog's text field did not go (`answerField`).
    enum FieldAnswerError: Error, Equatable {
        /// Nothing is left to write once the control characters went.
        case empty
        /// The screen could not be read right before writing: nothing was sent.
        case unread
        /// The screen no longer shows that dialog, or that option is no longer a text field: nothing was sent.
        case changed
        /// The answer never showed in the field and the dialog stayed as it was. Nook pressed no Enter of its own (on an empty
        /// field Enter cancels Claude's question); in a Terminal tab, Terminal's Return went with the write all the same.
        case unseen
        /// The answer still sits in the field after the one Enter Nook adds: not sent.
        case stuck
        /// The question closed with Claude's record of no answer ("User declined to answer questions"): the Return reached an
        /// empty field (the paste didn't land) and cancelled it.
        case declined
        /// The question closed with an answer that isn't this one ("User answered Claude's questions" without it, or the user
        /// chose to chat about it): the Return chose the highlighted option, not the field.
        case otherAnswer
        /// The question went away and nothing on screen says Claude took this answer.
        case unconfirmed
        /// Claude's notes field has the terminal's keyboard (`AgentPrompt.notesFocused`), empty or with text: the arrows would move its
        /// cursor, the "n" would be typed into it, and Enter would answer the option Claude has highlighted. Nothing was sent.
        case notesFieldOpen
        /// The tab no longer runs a program in its foreground when the write was to go (`answerScript`): the agent quit, and its keys
        /// would have gone to the shell. That write, and any after it, didn't go.
        case agentGone
    }

    /// What a reading of the screen says about an answer written into option `index`'s field.
    enum FieldState: Equatable {
        /// The dialog is as it was: the field still shows its placeholder.
        case untouched
        /// The field shows the answer, in the same question. `checked`: the option's box, in a question that takes several
        /// answers; nil without one.
        case holding(checked: Bool?)
        /// That question is no longer on screen: the dialog closed, or moved on (its next question, its review step), or a
        /// reading caught it mid-redraw. Only the screen's record says whether it took the answer (`FieldRecords`).
        case gone
    }

    /// The dialog at the end of an agent's screen, found the way a tab's reading finds it (`TerminalSession.readPrompt`).
    static func prompt(onScreen screen: String, agent: TerminalAgent?) -> AgentPrompt? {
        AgentPrompt.parse(TerminalSession.screen(screen.trimmingCharacters(in: .newlines), agent: agent).conversation)
    }

    /// Where an answer written into option `index` of `expected` (the reading before the write) stands on `screen`.
    static func fieldState(_ screen: String, agent: TerminalAgent?, option index: Int, text: String, expected: AgentPrompt) -> FieldState {
        guard let prompt = prompt(onScreen: screen, agent: agent) else { return .gone }
        // The answer replaces the field's placeholder in its row, and so changes the dialog's signature: a dialog that still
        // reads as before is untouched, even for an answer that reads like the placeholder ("Type something."), which no Enter
        // may ever be pressed on. The highlight is no part of the signature: the arrows alone leave it as it was.
        if prompt.signature == expected.signature { return .untouched }
        // Holding is the same question with its field (a field before the write) showing the answer: the next question, or
        // another dialog, whose option `index` happens to read the same is gone, and never gets Nook's Enter.
        guard expected.options.indices.contains(index), expected.options[index].input == .inline,
              prompt.identity(ignoringOption: index) == expected.identity(ignoringOption: index), prompt.field(index, shows: text) else { return .gone }
        return .holding(checked: prompt.options[index].checked)
    }

    /// What Claude's conversation records about the answers to its questions, counted on one screen (Claude Code 2.1.295, the
    /// AskUserQuestion result: "⏺ User answered Claude's questions:" over one "⎿ · <question> → <answer>" row per question;
    /// "⏺ User declined to answer questions" when the dialog was cancelled; "⏺ User asked Claude for more questions" for
    /// "Chat about this"). The review step of a dialog with tabs shows the same "→ <answer>" rows. Compared without whitespace,
    /// as wrapped rows join, and against the counts before the write: an older record of the same answer higher up doesn't count.
    struct FieldRecords: Equatable {
        /// "→ <answer>": this answer, recorded or on the review step.
        var answer = 0
        /// Answers recorded at all, this one or another.
        var answered = 0
        var declined = 0

        init(_ screen: String, agent: TerminalAgent?, text: String) {
            let chat = TerminalSession.screen(screen.trimmingCharacters(in: .newlines), agent: agent).conversation.filter { !$0.isWhitespace }
            func count(_ mark: String) -> Int { mark.isEmpty ? 0 : chat.components(separatedBy: mark).count - 1 }
            answer = count("→" + MessageEcho.key(text))
            answered = count("UseransweredClaude'squestions") + count("UseraskedClaudeformorequestions")
            declined = count("Userdeclinedtoanswerquestions")
        }
    }

    /// What closes a gone question, from its record and the dialog now on screen.
    enum FieldVerdict: Equatable {
        /// Claude took this answer: recorded with it, on the review step with it, or (a dialog with tabs) its next question
        /// showing one more tab answered.
        case taken
        case declined
        case otherAnswer
        /// Nothing says yet.
        case open
    }

    /// The same row of tabs, read on two screens. Claude shortens the titles to fit, giving the open tab more room, so a title
    /// may come cut ("Infraestruc…") on one screen and whole on the other.
    static func sameTabs(_ one: [AgentPrompt.Tab], _ other: [AgentPrompt.Tab]) -> Bool {
        func stem(_ title: String) -> String { title.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased() }
        return one.count == other.count && zip(one, other).allSatisfy { pair in
            let (a, b) = (stem(pair.0.title), stem(pair.1.title))
            return !a.isEmpty && !b.isEmpty && (a.hasPrefix(b) || b.hasPrefix(a))
        }
    }

    static func fieldVerdict(_ screen: String, agent: TerminalAgent?, text: String, before: FieldRecords, expected: AgentPrompt) -> FieldVerdict {
        let now = FieldRecords(screen, agent: agent, text: text)
        if now.answer > before.answer { return .taken }
        // The same dialog's next question: its tabs (the open one is drawn in colour, which plain text doesn't keep) with one more
        // answered than when the answer went.
        if !expected.tabs.isEmpty, let next = prompt(onScreen: screen, agent: agent), sameTabs(next.tabs, expected.tabs),
           next.tabs.filter(\.answered).count > expected.tabs.filter(\.answered).count {
            return .taken
        }
        if now.declined > before.declined { return .declined }
        if now.answered > before.answered { return .otherAnswer }
        return .open
    }

    /// Writes `text` (as `fieldText` leaves it) into option `index` of the dialog on screen, a text field, and sends it, for any
    /// transport: `send` writes each step, `read` returns the visible screen as it is now. Nothing goes unless a reading right
    /// before shows the same dialog (`signature`) with that option still a text field, and the arrows are counted from that
    /// reading's highlight, not from the card the user clicked.
    ///
    /// `withReturn`: the answer's own write carries its Enter (a Terminal tab, where `do script` always adds Terminal's Return).
    /// A field that still shows the answer after `timing.hold` lost that Return (Claude drops the Return of a paste it reads
    /// images from) and gets one Enter, safe because the field holds the text. Without it (a Nook session's tmux), Enter goes
    /// once the field shows the answer. Never an Enter on a field that doesn't: on an empty field Enter cancels the question.
    ///
    /// Sent means Claude took this answer, not merely that the dialog went: the Return travels with the text, so a paste that
    /// didn't land leaves it on an empty field (which cancels Claude's question) or on another option (which answers with it),
    /// and the dialog goes either way. Once the question is gone, Claude's record must show the answer (`fieldVerdict`), within
    /// `timing.echo`; its record of a cancelled question or of another answer ends it as not sent at once (two readings in a
    /// row), and no record at all as `unconfirmed`. Another agent's records aren't known: there the question going is enough.
    ///
    /// A question that takes several answers keeps its dialog: writing into the field ticks the option's box and Enter toggles
    /// it (Claude Code 2.1.295: `updateInputValue` ticks a field with text; the list's Enter is `toggleValue`, and the field's
    /// own submit does nothing there). The box showing ticked with the answer, in that same question, is the end; an empty one
    /// after `timing.hold` gets one Enter.
    ///
    /// `now` and `pause` are the clock the waits are measured on and the pause between readings; tests drive both.
    static func answerField(_ text: String, option index: Int, expecting signature: String, agent: TerminalAgent?, withReturn: Bool,
                            timing: DeliveryTiming = .init(), send: (FieldStep) throws -> Void, read: () throws -> String?,
                            trace: (String) -> Void = { _ in }, now: () -> Date = Date.init,
                            pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let text = fieldText(text)
        guard !text.isEmpty else { trace("respuesta vacía; nada enviado"); throw FieldAnswerError.empty }
        guard let screen = (try? read()) ?? nil else { trace("no se pudo leer la pantalla; nada enviado"); throw FieldAnswerError.unread }
        guard let live = prompt(onScreen: screen, agent: agent), live.signature == signature, live.options.indices.contains(index),
              live.options[index].input == .inline else {
            trace("la pregunta ya no es la misma; nada enviado")
            throw FieldAnswerError.changed
        }
        let records = FieldRecords(screen, agent: agent, text: text)
        let arrows = live.arrows(to: index)
        trace("campo «\(live.options[index].title)» (opción \(index + 1)), resaltada la \(live.highlighted + 1)\(live.multiSelect ? ", varias respuestas" : "")")
        try send(.answer(arrows: arrows, text: text))
        let moves = arrows.isEmpty ? "" : String(repeating: arrows[0] == .up ? "↑" : "↓", count: arrows.count) + " y "
        trace("\(moves)texto pegado\(withReturn ? " con su Enter" : "") (\(text.utf8.count) bytes)")
        let several = live.multiSelect, name = agent?.title ?? "La terminal", recorded = agent == .claude
        var enters = 0, goneReadings = 0, shown = false
        var holdingSince: Date?, heldChecked: Bool?, goneSince: Date?, verdictSeen: FieldVerdict?
        var deadline = now().addingTimeInterval(timing.echo)
        repeat {
            pause(timing.poll)
            guard let screen = (try? read()) ?? nil else { continue }
            switch fieldState(screen, agent: agent, option: index, text: text, expected: live) {
            case .gone:
                holdingSince = nil
                goneReadings += 1
                guard recorded else {
                    if goneReadings >= 2 { trace("\(name) cerró la pregunta: enviado"); return }
                    continue
                }
                // A slow Claude gets its time to show the record once the question went.
                if goneSince == nil { goneSince = now(); deadline = max(deadline, now().addingTimeInterval(timing.echo)) }
                let verdict = fieldVerdict(screen, agent: agent, text: text, before: records, expected: live)
                defer { verdictSeen = verdict }
                switch verdict {
                case .taken:
                    trace(several || !live.tabs.isEmpty ? "\(name) tomó la respuesta y siguió: enviado" : "\(name) registró la respuesta: enviado")
                    return
                case .declined where verdictSeen == .declined:
                    trace("\(name) cerró la pregunta sin respuesta (el Enter llegó a un campo vacío); no enviado")
                    throw FieldAnswerError.declined
                case .otherAnswer where verdictSeen == .otherAnswer:
                    trace("\(name) respondió la pregunta con otra opción; no enviado")
                    throw FieldAnswerError.otherAnswer
                default: break
                }
            case .untouched:
                goneReadings = 0; holdingSince = nil; goneSince = nil; verdictSeen = nil
            case .holding(let checked):
                goneReadings = 0; goneSince = nil; verdictSeen = nil
                if !shown { shown = true; trace("la respuesta en el campo\(checked == false ? ", sin marcar" : checked == true ? ", marcada" : "")") }
                // The hold starts again whenever the box changes: a Return still on its way may toggle it.
                if holdingSince == nil || heldChecked != checked {
                    holdingSince = now(); heldChecked = checked
                    deadline = max(deadline, now().addingTimeInterval(timing.hold + timing.poll * 3))
                }
                let held = now().timeIntervalSince(holdingSince ?? now())
                // A Return in flight (Terminal's own, or Nook's Enter) is given its time; an answer that went without one gets
                // its Enter as soon as it shows.
                let wait = withReturn || enters > 0 ? timing.hold : 0
                if several, checked == true {
                    if held >= wait { trace("casilla marcada con la respuesta: enviado"); return }
                    continue
                }
                guard held >= (several ? timing.hold : wait) else { continue }
                guard enters == 0 else { trace("sigue en el campo tras el Enter; no enviado"); throw FieldAnswerError.stuck }
                try send(.enter)
                enters += 1; holdingSince = nil
                deadline = now().addingTimeInterval(timing.settle)
                trace(several ? "Enter para marcar la casilla" : withReturn ? "Enter (el del pegado no llegó)" : "Enter")
            }
        } while now() < deadline
        if goneSince != nil {
            switch verdictSeen {
            case .declined?: trace("\(name) cerró la pregunta sin respuesta; no enviado"); throw FieldAnswerError.declined
            case .otherAnswer?: trace("\(name) respondió la pregunta con otra opción; no enviado"); throw FieldAnswerError.otherAnswer
            default:
                trace("la pregunta se fue sin que \(name) registrara la respuesta en \(Int(timing.echo)) s; no enviado")
                throw FieldAnswerError.unconfirmed
            }
        }
        if enters > 0 || shown { trace("sigue en el campo sin confirmar; no enviado"); throw FieldAnswerError.stuck }
        trace(withReturn ? "no apareció en el campo en \(Int(timing.echo)) s y la pregunta sigue igual; el Return de Terminal fue con el texto, Nook no añade otro"
                         : "no apareció en el campo en \(Int(timing.echo)) s; sin Enter (en un campo vacío cancelaría la pregunta)")
        throw FieldAnswerError.unseen
    }

    /// How long an answer to a dialog's field waits on the screen (`answerField`); tests shorten it.
    var fieldTiming = DeliveryTiming()
    /// Where those answers' steps are written (`DeliveryJournal`); tests keep them out of the user's log.
    var fieldJournal: (String) -> Void = { DeliveryJournal.append($0) }

    /// The user's answer written into a dialog's text field in this Terminal tab, and sent (`answerField`): one write with the
    /// arrows, the text and Terminal's Return (`fieldAnswerAction`), with readings of the tab's visible screen before and after.
    /// Nothing comes forward and no key event is posted, so it needs no Accessibility. Mirror refreshes wait meanwhile, as for a
    /// message, and the steps go to the delivery log. A transport failure is told like any other script's (`onFailure`); the
    /// reasons in `FieldAnswerError` are left to the caller.
    func answerField(windowID: Int, tty: String, agent: TerminalAgent?, option index: Int, expecting signature: String, text: String,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        delivering += 1
        let run = runScript, read = screenReader, timing = fieldTiming
        deliveryQueue.async { [weak self] in
            var steps: [String] = []
            let started = Date()
            let trace: (String) -> Void = { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) }
            let result = Result {
                try Self.answerField(text, option: index, expecting: signature, agent: agent, withReturn: true, timing: timing, send: { step in
                    switch step {
                    case .answer(let arrows, let text):
                        guard let action = Self.fieldAnswerAction(arrows: arrows, text: text) else { throw FieldAnswerError.changed }
                        try Self.write(action, windowID: windowID, tty: tty, run: run, trace: trace)
                    case .enter:
                        try Self.write(Self.returnAction, windowID: windowID, tty: tty, run: run, trace: trace)
                    }
                }, read: { try read(windowID, tty) }, trace: trace)
            }
            if case .failure(let error) = result, !(error is FieldAnswerError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.delivering -= 1
                // The answer's own words stay out of the log: only how long it was.
                let entry = "\(agent?.title ?? "Terminal") · respuesta en el campo de la pregunta (\(text.count) caracteres)\n  " + steps.joined(separator: "\n  ")
                self.deliveryLog = Array((self.deliveryLog + [entry]).suffix(5))
                self.fieldJournal(entry)
                switch result {
                case .success: self.refresh(); completion(result)
                case .failure(let error) where error is FieldAnswerError: completion(result)
                case .failure: self.finish(result) { _ in }; completion(result)
                }
            }
        }
    }

    // MARK: Answering with notes

    /// One step of an answer with notes (`answerNotes`).
    enum NotesStep: Equatable {
        /// The arrows to the option, "n" and the notes pasted into the field it opens. A Terminal tab's write carries Terminal's own
        /// Return after them (`notesAnswerAction`); a Nook session's tmux presses nothing after the paste.
        case answer(arrows: [TerminalKey], notes: String)
        /// One more Enter.
        case enter
    }

    /// What a reading of the screen says about notes written for an option of `expected`.
    enum NotesState: Equatable {
        /// The same question without notes in its row (the field closed, or open and empty).
        case untouched
        /// The same question, its notes row showing these notes, its highlight on option `highlighted`.
        case holding(highlighted: Int)
        /// The same question with other notes in its row.
        case other
        /// That question is no longer on screen: the dialog closed, moved on (its next question, its review step), or a reading
        /// caught it mid-redraw. Only the screen's record says whether it took the answer (`fieldVerdict`).
        case gone
    }

    static func notesState(_ screen: String, agent: TerminalAgent?, notes: String, expected: AgentPrompt) -> NotesState {
        // The notes, the highlight and the preview are no part of the signature: the same question keeps it while they change.
        guard let prompt = prompt(onScreen: screen, agent: agent), prompt.signature == expected.signature, prompt.takesNotes else { return .gone }
        if prompt.notesShow(notes) { return .holding(highlighted: prompt.highlighted) }
        return prompt.notes == nil ? .untouched : .other
    }

    /// Answers option `index` of the question with a preview on screen with `notes` (as `fieldText` leaves them), for any transport:
    /// `send` writes each step, `read` returns the visible screen as it is now. Nothing goes unless a reading right before shows the
    /// same question (`signature`) with its notes field closed and empty; the arrows are counted from that reading's highlight.
    ///
    /// `withReturn`: the write carries its Enter (a Terminal tab). Notes that still show in the same question after `timing.hold`
    /// lost it, or Claude closed the field without answering, and get one Enter, safe on the highlighted option once the notes are
    /// in: Enter answers it, field open or closed. Without it (a Nook session's tmux), Enter goes once the notes show. Never an Enter
    /// while the row has no notes: the field would close empty, or answer with what the question had before.
    ///
    /// Sent means Claude took the option, as for a text field (`answerField`): its record ("→ option"), the review step showing
    /// it, or the next tab with one more answered. The notes themselves never show in Claude's record; they went if the option did,
    /// since the field took them before its Enter answered.
    ///
    /// `anchored` hears, right before the first write, the lines of that reading the write must still find on screen
    /// (`AgentPrompt.screenAnchors`): a Terminal tab checks them in the write's own script (`answerScript`).
    static func answerNotes(_ notes: String, option index: Int, expecting signature: String, agent: TerminalAgent?, withReturn: Bool,
                            timing: DeliveryTiming = .init(), send: (NotesStep) throws -> Void, read: () throws -> String?,
                            anchored: ([String]) -> Void = { _ in }, trace: (String) -> Void = { _ in }, now: () -> Date = Date.init,
                            pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let notes = fieldText(notes)
        guard !notes.isEmpty else { trace("notas vacías; nada enviado"); throw FieldAnswerError.empty }
        guard let screen = (try? read()) ?? nil else { trace("no se pudo leer la pantalla; nada enviado"); throw FieldAnswerError.unread }
        guard let live = prompt(onScreen: screen, agent: agent), live.signature == signature, let arrows = live.notesArrows(to: index) else {
            trace("la pregunta ya no es la misma; nada enviado")
            throw FieldAnswerError.changed
        }
        // Open, the field takes every key of the write as its own; closed with notes, the paste would land inside them.
        guard !live.notesFocused, !live.notesOpen else { trace("el campo de notas está abierto en la terminal; nada enviado"); throw FieldAnswerError.notesFieldOpen }
        guard live.notes == nil else { trace("la pregunta ya tiene notas en la terminal; nada enviado"); throw FieldAnswerError.changed }
        let title = live.options[index].title
        let records = FieldRecords(screen, agent: agent, text: title)
        trace("opción «\(title)» (\(index + 1)) con notas, resaltada la \(live.highlighted + 1)")
        anchored(live.screenAnchors)
        try send(.answer(arrows: arrows, notes: notes))
        trace(arrows.map { $0 == .up ? "↑" : "↓" }.joined() + ", n y notas pegadas\(withReturn ? " con su Enter" : "") (\(notes.utf8.count) bytes)")
        let name = agent?.title ?? "La terminal", recorded = agent == .claude
        var enters = 0, goneReadings = 0, shown = false, otherSeen = false
        var holdingSince: Date?, goneSince: Date?, verdictSeen: FieldVerdict?
        var deadline = now().addingTimeInterval(timing.echo)
        repeat {
            pause(timing.poll)
            guard let screen = (try? read()) ?? nil else { continue }
            switch notesState(screen, agent: agent, notes: notes, expected: live) {
            case .gone:
                holdingSince = nil
                goneReadings += 1
                guard recorded else {
                    if goneReadings >= 2 { trace("\(name) cerró la pregunta: enviado"); return }
                    continue
                }
                if goneSince == nil { goneSince = now(); deadline = max(deadline, now().addingTimeInterval(timing.echo)) }
                let verdict = fieldVerdict(screen, agent: agent, text: title, before: records, expected: live)
                defer { verdictSeen = verdict }
                switch verdict {
                case .taken:
                    trace(live.tabs.isEmpty ? "\(name) registró la opción: enviado con sus notas" : "\(name) tomó la opción y siguió: enviado con sus notas")
                    return
                case .declined where verdictSeen == .declined:
                    trace("\(name) cerró la pregunta sin respuesta; no enviado")
                    throw FieldAnswerError.declined
                case .otherAnswer where verdictSeen == .otherAnswer:
                    trace("\(name) respondió la pregunta con otra opción; no enviado")
                    throw FieldAnswerError.otherAnswer
                default: break
                }
            case .untouched:
                goneReadings = 0; holdingSince = nil; goneSince = nil; verdictSeen = nil
            case .other:
                goneReadings = 0; holdingSince = nil; goneSince = nil; verdictSeen = nil
                if !otherSeen { otherSeen = true; trace("la fila de notas muestra otro texto") }
            case .holding(let highlighted):
                goneReadings = 0; goneSince = nil; verdictSeen = nil
                if !shown { shown = true; trace("notas en su fila") }
                if holdingSince == nil { holdingSince = now(); deadline = max(deadline, now().addingTimeInterval(timing.hold + timing.poll * 3)) }
                // A Return in flight (Terminal's own, or Nook's Enter) is given its time; notes that went without one get their Enter
                // as soon as they show.
                let wait = withReturn || enters > 0 ? timing.hold : 0
                guard now().timeIntervalSince(holdingSince ?? now()) >= wait else { continue }
                guard enters == 0 else { trace("las notas siguen en su fila tras el Enter; no enviado"); throw FieldAnswerError.stuck }
                guard highlighted == index else { trace("el resaltado no está en la opción \(index + 1); sin Enter"); throw FieldAnswerError.stuck }
                try send(.enter)
                enters += 1; holdingSince = nil
                deadline = now().addingTimeInterval(timing.settle)
                trace(withReturn ? "Enter (el del pegado no respondió)" : "Enter")
            }
        } while now() < deadline
        if goneSince != nil {
            switch verdictSeen {
            case .declined?: trace("\(name) cerró la pregunta sin respuesta; no enviado"); throw FieldAnswerError.declined
            case .otherAnswer?: trace("\(name) respondió la pregunta con otra opción; no enviado"); throw FieldAnswerError.otherAnswer
            default:
                trace("la pregunta se fue sin que \(name) registrara la opción en \(Int(timing.echo)) s; no enviado")
                throw FieldAnswerError.unconfirmed
            }
        }
        if enters > 0 || shown || otherSeen { trace("las notas quedaron en la pregunta sin responderla; no enviado"); throw FieldAnswerError.stuck }
        trace(withReturn ? "las notas no aparecieron en \(Int(timing.echo)) s y la pregunta sigue igual; el Return de Terminal fue con ellas, Nook no añade otro"
                         : "las notas no aparecieron en \(Int(timing.echo)) s; sin Enter")
        throw FieldAnswerError.unseen
    }

    /// The user's option and notes in this Terminal tab (`answerNotes`): one write with the arrows, "n", the notes and Terminal's
    /// Return (`notesAnswerAction`), with readings of the tab's visible screen before and after. Nothing comes forward and no key
    /// event is posted. Mirror refreshes wait meanwhile, and the steps go to the delivery log, as for a text field's answer.
    func answerNotes(windowID: Int, tty: String, agent: TerminalAgent?, option index: Int, expecting signature: String, notes: String,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        delivering += 1
        let run = runScript, read = screenReader, timing = fieldTiming
        deliveryQueue.async { [weak self] in
            var steps: [String] = []
            var anchors: [String] = []
            let started = Date()
            let trace: (String) -> Void = { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) }
            let result = Result {
                try Self.answerNotes(notes, option: index, expecting: signature, agent: agent, withReturn: true, timing: timing, send: { step in
                    switch step {
                    case .answer(let arrows, let notes):
                        // One write: Terminal's `do script` always ends in its Return, so the arrows, "n" and the notes can't go in two
                        // writes with a reading between (a Return after "n" closes the empty field, and answers with what the question
                        // had). The reading the arrows were counted from is checked again inside the write's own script instead
                        // (`answerScript`'s anchors): what's left is the time Claude takes to draw what it already took in, a frame.
                        guard let action = Self.notesAnswerAction(arrows: arrows, notes: notes) else { throw FieldAnswerError.changed }
                        try Self.write(action, anchors: anchors, windowID: windowID, tty: tty, run: run, trace: trace)
                    case .enter:
                        try Self.write(Self.returnAction, windowID: windowID, tty: tty, run: run, trace: trace)
                    }
                }, read: { try read(windowID, tty) }, anchored: { anchors = $0 }, trace: trace)
            }
            if case .failure(let error) = result, !(error is FieldAnswerError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.delivering -= 1
                // The notes' own words stay out of the log: only how long they were.
                let entry = "\(agent?.title ?? "Terminal") · opción \(index + 1) con notas (\(notes.count) caracteres)\n  " + steps.joined(separator: "\n  ")
                self.deliveryLog = Array((self.deliveryLog + [entry]).suffix(5))
                self.fieldJournal(entry)
                switch result {
                case .success: self.refresh(); completion(result)
                case .failure(let error) where error is FieldAnswerError: completion(result)
                case .failure: self.finish(result) { _ in }; completion(result)
                }
            }
        }
    }

    // MARK: Choosing an option of a question with a preview

    /// Chooses option `index` of Claude's question with a preview (`AgentPrompt.takesNotes`) with no notes, for any transport: `send`
    /// writes the keys (arrows, then Enter) in one go, `read` returns the visible screen as it is now. Nothing goes unless a reading
    /// right before shows the same question (`signature`), with its notes field closed: open, empty or with text, it would take the
    /// arrows as cursor moves and its Enter would answer the option Claude has highlighted (`AgentPrompt.notesFocused`). The keys are
    /// counted from that reading's highlight. Notes held with the field closed go with the option, as Claude sends them.
    /// `send` gets the keys and the lines of that reading the write must still find on screen (`AgentPrompt.screenAnchors`).
    static func answerPreview(option index: Int, expecting signature: String, agent: TerminalAgent?, send: ([TerminalKey], [String]) throws -> Void,
                              read: () throws -> String?, trace: (String) -> Void = { _ in }) throws {
        guard let screen = (try? read()) ?? nil else { trace("no se pudo leer la pantalla; nada enviado"); throw FieldAnswerError.unread }
        guard let live = prompt(onScreen: screen, agent: agent), live.signature == signature, live.takesNotes, live.options.indices.contains(index) else {
            trace("la pregunta ya no es la misma; nada enviado")
            throw FieldAnswerError.changed
        }
        guard !live.notesFocused, !live.notesOpen else { trace("el campo de notas está abierto en la terminal; nada enviado"); throw FieldAnswerError.notesFieldOpen }
        let keys = live.keys(choosing: index)
        guard !keys.isEmpty, answerAction(keys) != nil else { trace("no hay teclas para esa opción; nada enviado"); throw FieldAnswerError.changed }
        try send(keys, live.screenAnchors)
        trace("opción «\(live.options[index].title)» (\(index + 1)), resaltada la \(live.highlighted + 1): "
              + keys.map { $0 == .up ? "↑" : $0 == .down ? "↓" : "⏎" }.joined())
    }

    /// The user's choice of option `index` in Claude's question with a preview in this Terminal tab (`answerPreview`): one reading of
    /// the tab's visible screen, then the arrows and Terminal's Return in one write (`answerAction`), behind the checks of its own script
    /// (`answerScript`: the tab still busy, the reading's lines still on screen). Nothing comes forward and no key event is posted;
    /// mirror refreshes wait meanwhile. Only a choice that didn't go is written to the delivery log.
    func answerPreview(windowID: Int, tty: String, agent: TerminalAgent?, option index: Int, expecting signature: String,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        delivering += 1
        let run = runScript, read = screenReader
        deliveryQueue.async { [weak self] in
            var steps: [String] = []
            let started = Date()
            let trace: (String) -> Void = { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) }
            let result = Result {
                try Self.answerPreview(option: index, expecting: signature, agent: agent, send: { keys, anchors in
                    // The reading the keys were counted from is checked again inside the write's own script (`answerScript`).
                    guard let action = Self.answerAction(keys) else { throw FieldAnswerError.changed }
                    try Self.write(action, anchors: anchors, windowID: windowID, tty: tty, run: run, trace: trace)
                }, read: { try read(windowID, tty) }, trace: trace)
            }
            if case .failure(let error) = result, !(error is FieldAnswerError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.delivering -= 1
                if case .failure = result {
                    let entry = "\(agent?.title ?? "Terminal") · opción \(index + 1) de una pregunta con vista previa\n  " + steps.joined(separator: "\n  ")
                    self.deliveryLog = Array((self.deliveryLog + [entry]).suffix(5))
                    self.fieldJournal(entry)
                }
                switch result {
                case .success: self.refresh(); completion(result)
                case .failure(let error) where error is FieldAnswerError: completion(result)
                case .failure: self.finish(result) { _ in }; completion(result)
                }
            }
        }
    }

    func select(windowID: Int, tty: String, raise: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let action = "set selected of t to true" + (raise ? "\nset miniaturized of targetWindow to false\nset index of targetWindow to 1\nactivate" : "")
        perform(Self.targetScript(windowID: windowID, tty: tty, action: action)) { completion?($0) }
    }

    /// `then` runs on the scripting queue right after a successful script, before anything queued later.
    private func perform(_ source: String, then: (() -> Void)? = nil, completion: @escaping (Bool) -> Void) {
        let run = runScript
        queue.async { [weak self] in
            let result = Result { try run(source) }
            if case .success = result { then?() }
            DispatchQueue.main.async { self?.finish(result, completion: completion) }
        }
    }

    private func finish(_ result: Result<Void, Error>, completion: (Bool) -> Void) {
        switch result {
        case .success: completion(true); refresh()
        case .failure(let error): self.error = error.localizedDescription; onFailure?(error.localizedDescription); completion(false)
        }
    }
}
