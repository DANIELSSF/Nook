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

/// A local record of each delivery's steps, so a failed send can be understood afterwards. It holds
/// the user's own messages and stays on this Mac, capped in size.
enum DeliveryJournal {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook/deliveries.log") }
    static func append(_ entry: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.utf8.count > 200_000 { text = String(text.suffix(100_000)) }
        text += "\(Date().formatted(date: .numeric, time: .standard)) \(entry)\n\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The message went into Claude's box behind text that was already there; no Enter was pressed.
enum DeliveryError: Error { case joined(String) }
enum DeliveryOutcome { case sent, joined(String), failed }

/// Synthetic key presses need the user's Accessibility permission; Nook only asks after explaining why.
enum DirectKeys {
    static var allowed: Bool { AXIsProcessTrusted() }
    static func request() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
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

    init(executable: URL? = Bundle.main.executableURL, arguments: [String] = ["--terminal-script"]) {
        self.executable = executable; self.arguments = arguments
    }

    func run(_ source: String) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
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
    private let queue = DispatchQueue(label: "dev.nook.terminal-app", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(label: "dev.nook.terminal-app.delivery", qos: .userInitiated)
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
        let json = try ScriptHelper.shared.run(source)
        if let code = json["errorCode"] as? Int {
            if code == -1743 { throw TerminalBridgeError.automationDenied }
            if code == -1712 { throw TerminalBridgeError.failed("Terminal tardó demasiado en responder. Si macOS muestra un permiso para Nook, acéptalo y pulsa Buscar de nuevo.") }
            throw TerminalBridgeError.failed(json["error"] as? String ?? "No se pudo conectar con Terminal.")
        }
        guard let value = json["value"] else { throw TerminalBridgeError.malformedResponse }
        return descriptor(value)
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
        var compiled: [String: NSAppleScript] = [:]
        while let line = readLine() {
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let source = request["source"] as? String else {
                reply(["errorCode": -1, "error": "No se pudo leer la petición."]); continue
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
                return try Self.decode(Self.execute(Self.snapshotScript(includeText: false)))
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

    func connect(tab: TerminalTabSnapshot) {
        trackedTabs.removeAll { $0.tty == tab.tty }
        trackedTabs.append(TrackedTerminalTab(windowID: tab.windowID, tty: tab.tty))
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
        tracked.map { entry in tabs.first { $0.tty == entry.tty }.map { TrackedTerminalTab(windowID: $0.windowID, tty: entry.tty) } ?? entry }
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
        lightReads = detailed ? 0 : lightReads + 1
        queue.async { [weak self] in
            let result = Result { () throws -> [TerminalTabSnapshot] in
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return [] }
                // Every window is searched (text is read only for the followed TTYs): a tab dragged to
                // another window keeps being followed instead of looking closed.
                return try Self.decode(Self.execute(Self.snapshotScript(ttys: ttys, includeText: true, screenOnly: !history)))
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
                    self.error = error.localizedDescription; self.onFailure?(error.localizedDescription)
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

    /// Terminal writes the text and its own Return in one chunk: a shell runs it, while agent TUIs
    /// read the chunk as a paste and keep the Return as a new line.
    static func typeAction(_ text: String) -> String { "do script \(AppleScriptText.literal(text)) in t" }
    static let returnAction = "do script \"\" in t"
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
                                 read: { try Self.decode(Self.execute(Self.snapshotScript(windowIDs: [windowID], ttys: [tty], includeText: true, screenOnly: true))).first { $0.tty == tty }?.text },
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
                self.finish(result) { completion($0 ? .sent : .failed) }
            }
        }
    }

    struct DeliveryTiming { var poll = 0.1, echo = 3.0, settle = 1.5, retries = 2 }

    /// A busy agent reads whatever has accumulated in one go, so a Return sent on a timer can land
    /// inside the paste again. The Return goes only once the agent shows the message (it has read
    /// that chunk); Claude empties its box when it takes it, otherwise one more Return follows.
    static func deliver(_ text: String, agent: TerminalAgent, timing: DeliveryTiming = .init(), run: (String) throws -> Void, read: () throws -> String?, trace: (String) -> Void = { _ in }) throws {
        var screen: String?
        func box() -> String {
            if let input = screen.flatMap({ ClaudeComposer.split($0).input }) { return input }
            // No box recognised: the end of the screen shows why.
            let tail = (screen ?? "").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)
            return "— sin caja; pantalla: " + (tail.isEmpty ? "vacía" : tail.map { String($0.prefix(100)) }.joined(separator: " ⏎ "))
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
        func stillInBox() -> Bool {
            screen = (try? read()) ?? nil
            return screen.flatMap { ClaudeComposer.split($0).input }.map { MessageEcho.boxHolds($0, text) } ?? false
        }
        func settle() throws {
            for _ in 0..<timing.retries {
                if wait(timing.settle, poll: timing.poll, until: { !stillInBox() }) { trace("caja vacía: enviado"); return }
                trace("seguía en la caja «\(box())»: otro Enter")
                try run(returnAction)
            }
            trace(wait(timing.settle, poll: timing.poll, until: { !stillInBox() }) ? "caja vacía: enviado" : "sigue en la caja tras los reintentos")
        }
        if agent == .claude {
            screen = (try? read()) ?? nil
            trace("caja antes: «\(box())»")
            // The box may already hold exactly this message (an accepted suggestion, or the same text
            // typed there): pasting would double it, so only Enter goes. Enter on a grey suggestion may
            // just fill the box first; the settle check then presses it once more.
            if let input = screen.flatMap({ ClaudeComposer.split($0).input }), MessageEcho.same(input, text) {
                trace("ya estaba en la caja: solo Enter")
                try run(returnAction)
                return try settle()
            }
        }
        try run(typeAction(text))
        trace("pegado")
        do {
            let shown = wait(timing.echo, poll: timing.poll, until: showsMessage)
            trace(shown ? "visto en la caja «\(box())»" : "no se vio en \(Int(timing.echo)) s; Enter igualmente")
            // Text typed earlier in Claude's box would go out with the message; the user decides what to keep.
            if shown, agent == .claude, let screen, let joined = MessageEcho.joined(text, in: screen) {
                trace("unido a texto previo; sin Enter")
                throw DeliveryError.joined(joined)
            }
            try run(returnAction)
            trace("Enter")
            guard agent == .claude else { return }
            try settle()
        } catch let error as DeliveryError {
            throw error
        } catch {
            // The message is already in the box: it must never be pasted a second time.
            trace("error tras pegar: \(error.localizedDescription)")
            throw DeliveryError.joined(box() == "—" ? text : box())
        }
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

    func press(_ key: TerminalKey, windowID: Int, tty: String, completion: @escaping (KeyDelivery) -> Void) {
        guard key.needsDirectKeys else {
            perform(Self.targetScript(windowID: windowID, tty: tty, action: Self.returnAction)) { completion($0 ? .sent : .failed) }
            return
        }
        guard directKeysAllowed(), let pid = terminalProcess() else { completion(directKeysAllowed() ? .failed : .needsPermission); return }
        // The key is posted in the same serialized step that verified the tab, so no selection Nook
        // queues meanwhile can change the destination. A tab switch made by hand in Terminal in
        // those milliseconds remains possible; only tmux addresses a session's own terminal.
        let post = postKey
        perform(Self.targetScript(windowID: windowID, tty: tty, action: Self.presentForKeysAction), then: { post(key, pid) }) { completion($0 ? .sent : .failed) }
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
