import AppKit
import Combine
import SwiftTerm

enum Shell {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum SessionKind: String, Codable, CaseIterable {
    case shell, claude, codex
    var title: String { switch self { case .shell: "Terminal"; case .claude: "Claude Code"; case .codex: "Codex" } }
    var symbol: String { switch self { case .shell: "terminal"; case .claude: "sparkle"; case .codex: "chevron.left.forwardslash.chevron.right" } }
    var shellCommand: String {
        switch self {
        case .shell: return "/bin/zsh -l"
        case .claude, .codex:
            return "/bin/zsh -lc " + Shell.quote("if command -v \(rawValue) >/dev/null 2>&1; then \(rawValue); else printf '\\nNo se encontró \(title). Instala su CLI o usa esta terminal.\\n'; fi; exec /bin/zsh -l")
        }
    }
}

struct SessionRecord: Codable, Identifiable {
    var id: String
    var name: String
    var kind: SessionKind
    var directory: String
    var socket: String
    var ownsSession: Bool
}

struct TmuxBackend {
    let executable: String
    let socket: String
    let configuration: String

    static var bundled: TmuxBackend {
        let resources = Bundle.main.resourcePath ?? ""
        let developmentRoot = FileManager.default.currentDirectoryPath
        let bundled = resources + "/tmux"
        let executable = FileManager.default.isExecutableFile(atPath: bundled) ? bundled : developmentRoot + "/Vendor/bin/tmux"
        let config = FileManager.default.fileExists(atPath: resources + "/tmux.conf") ? resources + "/tmux.conf" : developmentRoot + "/Resources/tmux.conf"
        let socketDirectory = "/tmp/nook-\(getuid())"
        try? FileManager.default.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return TmuxBackend(executable: executable, socket: socketDirectory + "/shared.sock", configuration: config)
    }

    func arguments(socket override: String? = nil) -> [String] { ["-S", override ?? socket, "-f", configuration] }
    func attachmentCommand(for record: SessionRecord) -> String {
        ([executable] + arguments(socket: record.socket) + ["attach-session", "-t", "=" + record.id]).map(Shell.quote).joined(separator: " ")
    }
    func exists(_ record: SessionRecord) -> Bool {
        (try? Shell.run(executable, arguments(socket: record.socket) + ["has-session", "-t", "=" + record.id]).0) == 0
    }
    func sessions(socket candidate: String) -> [String] {
        guard let result = try? Shell.run(executable, arguments(socket: candidate) + ["list-sessions", "-F", "#{session_name}"]), result.0 == 0 else { return [] }
        return result.1.split(separator: "\n").map(String.init)
    }
    func close(_ record: SessionRecord) {
        _ = try? Shell.run(executable, arguments(socket: record.socket) + ["kill-session", "-t", "=" + record.id])
    }
}

final class ActivityTerminalView: LocalProcessTerminalView {
    var onActivity: (() -> Void)?
    var onData: ((ArraySlice<UInt8>) -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onActivity?()
        onData?(slice)
    }
    override func cancelOperation(_ sender: Any?) {
        if let delegate = NSApp.delegate as? AppDelegate { delegate.controller.collapse() }
    }
}

final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let record: SessionRecord
    var id: String { record.socket + "::" + record.id }
    @Published var title: String
    @Published var isRunning = true
    /// Read on the activity tick only; publishing it would re-render the panel on every output.
    var lastOutput = Date.distantPast
    @Published var mirroredText = ""
    /// What Nook shows: the raw mirror minus the agent's own input box, which Nook replaces.
    @Published var displayText = ""
    /// What is already typed in Claude's own box in the original terminal.
    @Published var agentInput: String?
    /// Claude's spinner or "done" line, shown beside the chat instead of inside it.
    @Published var agentStatus: ClaudeStatus?
    /// The newest status from any read, also the screen-only ones of a collapsed island; it feeds
    /// the notch without re-rendering the hidden panel.
    private(set) var liveStatus: ClaudeStatus?
    /// Claude's latest session recap, shown outside the chat.
    @Published var recap: String?
    /// The question the agent is waiting on at the end of its screen (a permission, a choice), if any. It is read on
    /// every pass, also the collapsed island's screen-only ones: a new prompt is what brings the island forward.
    @Published private(set) var prompt: AgentPrompt?
    /// An answer's keys are on their way. The card ignores clicks until the screen shows the result (or a moment
    /// passes), so a double click can never send arrows and Enter into whatever comes next.
    @Published private(set) var answering = false
    private var answeringFrom: AgentPrompt?
    private var answeringToken = 0
    /// The answer's keys are still being pressed; the screen changing meanwhile (the first arrow already moved the
    /// highlight) does not end the answer.
    private var keysInFlight = false
    /// Claude's box after Nook's message landed behind text already there. Until the box changes,
    /// Nook never pastes again (that duplicated messages); the user sends it as is or fixes it.
    @Published var joinedBox: String?
    /// The message just sent, shown in the mirror at once until the terminal's own echo arrives.
    @Published var pendingMessage: String?
    private var pendingBaseline = ""
    private var pendingSince = Date.distantPast
    /// Claude's own record of this tab's conversation. When found, the mirror shows it in full (in
    /// fullscreen rendering Terminal only holds the visible screen); the screen still feeds the box,
    /// status, prompts and agents.
    var transcript: TranscriptFollower?
    var transcriptByGuess = false
    var transcriptLocated = Date.distantPast
    /// The session id Claude's hooks report for this tab.
    var claudeSessionID: String? { didSet { if claudeSessionID != oldValue { transcriptLocated = .distantPast } } }
    private(set) var transcriptText: String?

    func applyTranscript(_ text: String?, recap: String?, skills: [String: String] = [:], usedCommands: Set<String> = [], agents: [SubagentActivity]? = nil) {
        if let text {
            transcriptText = text
            if viewedAgent == nil, displayText != text { displayText = text }
        }
        if let recap, self.recap != recap { self.recap = recap }
        self.skills = skills; self.usedCommands = usedCommands
        if let agents, subagents != agents { subagents = agents }
    }

    /// The subagent (its launch's call id) whose own conversation the mirror shows instead of Claude's,
    /// like entering an agent's view in Claude's terminal; nil shows the main conversation.
    @Published private(set) var viewedAgent: String?
    /// The main conversation as the screen shows it, for coming back when there is no record.
    private var screenConversation = ""

    func view(agent call: String?) {
        guard viewedAgent != call else { return }
        viewedAgent = call
        // An agent's text arrives with the next reading of its record; until then the mirror is empty.
        let shown = call == nil ? (transcriptText ?? screenConversation) : ""
        if displayText != shown { displayText = shown }
    }

    func applyAgentText(_ text: String, call: String) {
        guard viewedAgent == call, displayText != text else { return }
        displayText = text
    }

    /// The commands this session's agent showed or ran, for completing "/" in Nook's field: Claude's
    /// skill listing and the commands it ran (from its record), and the rows of its own menu.
    private(set) var skills: [String: String] = [:]
    private(set) var usedCommands: Set<String> = []
    private(set) var menu: [SlashCommand] = []

    /// What was being written for this tab; switching tabs recreates the field, not the draft.
    var draft = ""
    /// Messages sent from Nook to this session, oldest first, for ↑ and ↓ in the field.
    var sentHistory: [String] = []
    /// Subagents Claude launched in this tab, read from its own tool lines.
    @Published var subagents: [SubagentActivity] = []
    @Published var agent: TerminalAgent?
    @Published var busy = false
    @Published var sending = false
    @Published var customTitle = ""
    @Published var tint: TabTint = .mint
    @Published var taskState: TaskState = .idle
    @Published var unreadNotice: String?
    var displayTitle: String { customTitle.isEmpty ? title : customTitle }
    var externalTTY: String?
    var isExternal: Bool { externalTTY != nil }
    /// The tab is the one its Terminal window shows (the selected tab of that window).
    var shownInWindow = false
    weak var terminalBridge: TerminalAppBridge?
    var onSignal: ((String) -> Void)?
    private var signalParser = TerminalSignalParser()
    let terminal: ActivityTerminalView
    private var mirrors: [ActivityTerminalView] = []
    let backend: TmuxBackend
    var externalWindowID: Int?
    var externalAppPID: pid_t?

    init(record: SessionRecord, backend: TmuxBackend, create: Bool) {
        self.record = record
        self.backend = backend
        title = record.name
        terminal = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 310))
        super.init()
        configure(terminal)
        var args = backend.arguments(socket: record.socket)
        if create {
            args += ["new-session", "-A", "-s", record.id, "-c", record.directory, record.kind.shellCommand]
        } else { args += ["attach-session", "-t", "=" + record.id] }
        terminal.startProcess(executable: backend.executable, args: args, environment: Self.environment, currentDirectory: record.directory)
    }

    init(tab: TerminalTabSnapshot, backend: TmuxBackend, bridge: TerminalAppBridge) {
        record = SessionRecord(id: tab.tty, name: tab.title, kind: .shell, directory: "", socket: "terminal.app", ownsSession: false)
        self.backend = backend
        title = tab.title
        externalTTY = tab.tty
        shownInWindow = tab.selected
        externalWindowID = tab.windowID
        externalAppPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
        terminalBridge = bridge
        terminal = ActivityTerminalView(frame: .zero)
        super.init()
        update(tab)
    }

    func update(_ tab: TerminalTabSnapshot) {
        // Every published assignment re-renders SwiftUI, so unchanged values are not reassigned.
        if title != tab.title { title = tab.title }
        if busy != tab.busy { busy = tab.busy }
        if !isRunning { isRunning = true }
        externalWindowID = tab.windowID
        let text = tab.text.trimmingCharacters(in: .newlines)
        let foreground = tab.agent
        guard tab.history else { return updateScreen(text, foreground: foreground) }
        guard mirroredText != text || agent != foreground else { return }
        if mirroredText != text {
            archive = Self.archived(archive, previous: mirroredText, next: text)
            mirroredText = text; lastOutput = Date()
        }
        if agent != foreground { agent = foreground }
        if foreground != .claude, transcript != nil { transcript = nil; transcriptText = nil; transcriptLocated = .distantPast; skills = [:]; usedCommands = []; viewedAgent = nil }
        let full = archive + text
        let split = Self.screen(full, agent: foreground)
        menu = split.menu
        screenConversation = split.conversation
        if viewedAgent == nil { displayText = transcriptText ?? split.conversation }
        readPrompt(in: split.conversation, agent: foreground)
        watchTurn(status: split.status, conversation: split.conversation)
        if agentInput != split.input { agentInput = split.input }
        liveStatus = split.status
        if agentStatus != split.status { agentStatus = split.status }
        if transcriptText == nil, recap != split.recap { recap = split.recap }
        if let joined = joinedBox, !MessageEcho.same(split.input ?? "", joined) { joinedBox = nil }
        settlePending(split.conversation)
        // With Claude's record, its agents come from there (they scroll off the screen). Otherwise the
        // raw screen, whose mode line's background count closes finished agents.
        if transcript == nil {
            let found = foreground == .claude ? AgentActivity.parse(text) : []
            if subagents != found { subagents = found }
        }
    }

    /// What slid out of the 80,000 characters Terminal returns. Kept in front of them so the mirror
    /// only grows at its end: older text stays readable and an update never shifts what is being
    /// read (and only the changed tail is laid out again).
    private(set) var archive = ""
    static let archiveLimit = 240_000

    /// The window normally starts somewhere inside the previous one: what lies before that point
    /// joins the archive. When it doesn't (the agent cleared and redrew everything, which already
    /// repeats the conversation) the archive starts over instead of doubling it.
    static func archived(_ archive: String, previous: String, next: String, limit: Int = archiveLimit) -> String {
        guard !previous.isEmpty, !next.isEmpty else { return archive }
        // Long enough to be unique, short enough to fit what both windows share after a big jump.
        let probe = String(next.prefix(200))
        if previous.hasPrefix(probe) { return archive }
        guard let start = previous.range(of: probe) else { return "" }
        let kept = (archive + previous[..<start.lowerBound]) as NSString
        guard kept.length > limit else { return kept as String }
        // Trimmed in large steps, at a line start, so the mirror's beginning rarely moves.
        let cut = kept.range(of: "\n", range: NSRange(location: kept.length - limit * 3 / 4, length: limit * 3 / 4)).location
        return cut == NSNotFound ? "" : kept.substring(from: cut + 1)
    }

    /// Claude's screen is split into its parts; another agent's menu is read from the screen's end.
    static func screen(_ text: String, agent: TerminalAgent?) -> ClaudeScreen {
        if agent == .claude { return ClaudeComposer.split(text) }
        var screen = ClaudeScreen(conversation: text)
        if agent != nil { screen.menu = SlashCatalog.menu(text.suffix(3000).split(separator: "\n", omittingEmptySubsequences: false).suffix(16).map(String.init)) }
        return screen
    }

    private var screenText = ""
    /// A collapsed island reads only the visible screen, enough for the notch's activity and Claude's
    /// spinner. Nothing the hidden panel shows is published, so SwiftUI stays idle until it opens and
    /// the next history read brings the mirror, box, status, recap and agents up to date.
    private func updateScreen(_ text: String, foreground: TerminalAgent?) {
        if screenText != text { screenText = text; lastOutput = Date() }
        if agent != foreground { agent = foreground }
        let split = Self.screen(text, agent: foreground)
        menu = split.menu
        liveStatus = split.status
        readPrompt(in: split.conversation, agent: foreground)
        watchTurn(status: split.status, conversation: split.conversation)
        if let joined = joinedBox, !MessageEcho.same(split.input ?? "", joined) { joinedBox = nil }
        settlePending(split.conversation)
    }

    /// Called when the screen shows this tab's agent finished a turn or started asking something.
    var onAlert: ((NookAlert.Kind, String) -> Void)?
    /// Called when a turn ended with Claude's own closing line ("Churned for 3m 58s") on screen.
    var onCompletion: (() -> Void)?
    private var turn = TurnWatch()
    private var announcedPrompt: String?

    /// The screen's version of the terminal's bell, for tabs whose agent sends Nook no signal of its own.
    func watchTurn(status: ClaudeStatus?, conversation: String, now: Date = Date()) {
        let name = agent?.title ?? "La terminal"
        let asking = prompt.map { $0.kind != .selector } ?? false
        if let prompt, asking, prompt.signature != announcedPrompt {
            announcedPrompt = prompt.signature
            onAlert?(.question, prompt.question.isEmpty ? "\(name) necesita tu respuesta." : prompt.question)
        }
        // A new turn makes the next dialog new, even one that looks the same.
        if status?.working == true, prompt == nil { announcedPrompt = nil }
        // A turn the user stopped needs no alert.
        if turn.observe(working: status?.working == true, asking: asking, now: now), !conversation.suffix(800).contains("Interrupted") {
            onAlert?(.finished, "\(name) terminó.")
            // Only Claude's closing line says the turn really completed; a spinner that just went away doesn't.
            if let status, !status.working { onCompletion?() }
        }
    }

    /// Only an agent's screen can hold its prompt; a shell's output never is one.
    private func readPrompt(in text: String, agent: TerminalAgent?) {
        let found = agent == nil ? nil : AgentPrompt.parse(text)
        if prompt != found { prompt = found }
        // The screen changed (the dialog closed or the highlight moved): the answer's effect is visible.
        if answering, !keysInFlight, found != answeringFrom { answering = false }
    }

    /// Marks an answer as being delivered; false when one already is or there is no prompt to answer.
    func beginAnswer() -> Bool {
        guard !answering, let prompt else { return false }
        answering = true; keysInFlight = true; answeringFrom = prompt; answeringToken += 1
        return true
    }
    /// The keys are done. Delivered: the card stays quiet until the screen shows the result, or `seconds` pass. Not
    /// delivered: the answer can be tried again at once.
    func finishAnswer(delivered: Bool, settle seconds: Double = 2.5) {
        keysInFlight = false
        answeringToken += 1
        guard delivered, prompt == answeringFrom else { answering = false; return }
        let token = answeringToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.answeringToken == token else { return }
            self.answering = false
        }
    }

    func showPending(_ message: String) {
        pendingBaseline = displayText; pendingSince = Date(); pendingMessage = message
    }
    /// The placeholder goes once the message appears in new output (the agent's box is already
    /// left out), or after a while if it never echoes.
    private func settlePending(_ shown: String) {
        guard let pending = pendingMessage else { return }
        let fresh = (shown as NSString).substring(from: LiveTerminalScrollView.commonPrefix(pendingBaseline as NSString, shown as NSString))
        if MessageEcho.appears(pending, in: fresh) || Date().timeIntervalSince(pendingSince) > 12 { pendingMessage = nil }
    }

    static var environment: [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = "en_US.UTF-8"
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + inherited
        env.removeValue(forKey: "TMUX")
        return env.map { "\($0.key)=\($0.value)" }
    }

    private func configure(_ view: ActivityTerminalView) {
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.processDelegate = self
        view.onActivity = { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastOutput) > 0.7 { self.lastOutput = Date() }
        }
        if view === terminal { view.onData = { [weak self] bytes in
            guard let self else { return }
            for message in self.signalParser.feed(bytes) { self.onSignal?(message) }
        } }
        applyTheme(view)
    }

    func applyTheme(_ view: ActivityTerminalView? = nil) {
        for terminalView in view.map({ [$0] }) ?? ([terminal] + mirrors) {
            if terminalView === terminal {
                // The island's own terminal has no card behind it: it takes the island's black and light text,
                // whatever the system appearance is.
                terminalView.nativeBackgroundColor = .black
                terminalView.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
            } else {
                // Mirrors live in ordinary windows and follow the system.
                terminalView.nativeBackgroundColor = NSColor.controlBackgroundColor
                terminalView.nativeForegroundColor = NSColor.labelColor
            }
            terminalView.caretColor = NSColor.systemMint
        }
    }

    /// The island's own terminal follows the user's chat text size (a full-window mirror keeps its own). SwiftTerm refits
    /// its rows and columns to the view, and tmux follows the client's new size.
    func applyConsoleSize(_ size: Double) {
        guard abs(Double(terminal.font.pointSize) - size) > 0.01 else { return }
        terminal.font = DisplaySettings.chatFont(size: size)
    }

    func makeMirror() -> ActivityTerminalView {
        let view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        configure(view)
        view.startProcess(executable: backend.executable, args: backend.arguments(socket: record.socket) + ["attach-session", "-t", "=" + record.id], environment: Self.environment, currentDirectory: record.directory)
        mirrors.append(view)
        return view
    }

    func releaseMirror(_ view: ActivityTerminalView) {
        view.terminate()
        mirrors.removeAll { $0 === view }
    }
    func disconnectClients() {
        guard !isExternal else { return }
        terminal.terminate()
        mirrors.forEach { $0.terminate() }
        mirrors.removeAll()
    }
    func send(_ draft: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !sending else { completion(false); return }
        sending = true
        // The message goes to Claude itself: its conversation comes back to show it arriving.
        view(agent: nil)
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            // A shell runs the line on Terminal's own Return; an agent needs its own Enter.
            if let agent {
                terminalBridge.deliver(windowID: windowID, tty: tty, text: draft, agent: agent) { [weak self] outcome in
                    self?.sending = false
                    switch outcome {
                    case .sent: completion(true)
                    case .joined(let box): self?.joinedBox = box; completion(false)
                    case .failed: completion(false)
                    }
                }
            } else {
                terminalBridge.send(windowID: windowID, tty: tty, text: draft) { [weak self] success in self?.sending = false; completion(success) }
            }
            return
        }
        // Paste mode keeps multiline text together; Enter is a deliberate user action.
        if terminal.getTerminal().bracketedPasteMode {
            terminal.send(txt: "\u{1b}[200~" + draft + "\u{1b}[201~")
        } else { terminal.send(txt: draft) }
        // An agent that receives Enter together with the paste treats it as part of the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.terminal.send(txt: "\r"); self.sending = false; completion(true)
        }
    }
    /// Claude's grey suggestion (or text typed in its box), offered in Nook's own field.
    var suggestion: String? {
        guard agent == .claude, !sending, let input = agentInput, !input.isEmpty else { return nil }
        return input.replacingOccurrences(of: "\n", with: " ")
    }
    /// Agents in an owned session are known by kind; external tabs by their foreground process.
    var drivesAgent: Bool { agent != nil || record.kind != .shell }
    func press(_ key: TerminalKey, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            terminalBridge.press(key, windowID: windowID, tty: tty, completion: completion)
            return
        }
        // tmux encodes each key for the pane's current mode, e.g. application cursor keys.
        let executable = backend.executable
        let arguments = backend.arguments(socket: record.socket) + ["send-keys", "-t", "=" + record.id + ":", key.tmuxName]
        DispatchQueue.global(qos: .userInitiated).async {
            let delivered = (try? Shell.run(executable, arguments).0) == 0
            DispatchQueue.main.async { completion(delivered ? .sent : .failed) }
        }
    }
    func interrupt(completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        // Agents stop on Escape; a second Control-C would quit them, and Terminal's
        // Return would arrive in the same chunk as the Control-C.
        if drivesAgent { press(.escape, completion: completion); return }
        if isExternal { send("\u{03}") { completion($0 ? .sent : .failed) } }
        else { terminal.send(txt: "\u{03}"); completion(.sent) }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if source === terminal { isRunning = false }
    }
}

final class AppModel: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: String? {
        didSet {
            // Switching tabs puts the tab left back on Claude's own conversation: an agent's view belongs to its tab's visit.
            guard let old = oldValue, old != selectedID else { return }
            sessions.first { $0.id == old }?.view(agent: nil)
        }
    }
    @Published var expanded = false {
        didSet {
            terminalBridge.detailed = expanded
            if expanded, !oldValue {
                commands.refresh(); alert = nil
                // Opening the island shows the selected tab: its notice has been seen.
                if let selected { markSeen(selected) }
            }
            // A list asked for by the agent pill is no use to an island that closed before showing it.
            if !expanded { agentListRequest = nil }
        }
    }
    /// The latest alert for the collapsed island; cleared when the island opens. The tab keeps its
    /// notice (and the notch its badge) until the user looks at it.
    @Published private(set) var alert: NookAlert?
    /// Grows each time a turn ends in a way Nook can trust: Claude's Stop hook, or its closing line
    /// on screen. Never for errors, questions or interrupted turns; the cat celebrates it.
    @Published private(set) var completions = 0
    private var lastCompletions: [String: Date] = [:]
    private var alertSerial = 0
    private var lastAlerts: [String: (kind: NookAlert.Kind, at: Date)] = [:]
    /// Each agent's commands, for completing "/" in the field.
    let commands = SlashCommandStore()
    @Published var islandContentVisible = false
    @Published var pinned = false
    @Published var connectionSheet = false
    /// How the open island looks: text sizes, size and the message field's lines. Every change is saved and the island's
    /// window follows it (`NotchController.displayChanged`); anything out of range is brought back inside.
    @Published var display: DisplaySettings {
        didSet {
            let valid = display.clamped()
            if valid != display { display = valid }
            guard display != oldValue else { return }
            display.save(to: defaults)
            controller?.displayChanged(from: oldValue)
        }
    }
    /// The card with those settings is out (a window of its own under the island).
    @Published var settingsOpen = false
    /// The tab the card shows: the island's looks, or the permissions.
    @Published var settingsTab: SettingsTab = .island
    /// What the card's Permisos tab shows and does. Here, and not in the card, so the island can tell that a macOS prompt is
    /// waiting for an answer and the user can be sent back to the tab (`NotchController.permissionsHandOff`).
    let permissions = PermissionsModel()
    private let defaults: UserDefaults
    @Published var notice: String?
    /// Files being dragged over the island; the composer's drop feedback reads it. Its own object, so a drag redraws the
    /// feedback and not the panel.
    let fileDrop = FileDropState()
    @Published var targetAppName: String?
    @Published var animations = UserDefaults.standard.object(forKey: "animations") as? Bool ?? true
    let backend = TmuxBackend.bundled
    let terminalBridge = TerminalAppBridge()
    private var selectedExternalTabs: [Int: String] = [:]
    @Published var working = false
    @Published var unreadCount = 0
    /// The spinner symbol Claude shows right now in the selected tab, for the notch.
    @Published var activityGlyph: String?
    @Published var runningSubagents = 0
    /// The collapsed island's agent pill was clicked: the tab whose agent list the open island shows (`NookPanel` opens it
    /// once its content is on screen and clears this).
    @Published var agentListRequest: AgentListRequest?
    @Published var editingSessionID: String?
    /// The prompt of the selected tab that is already announced, so the island comes forward once per prompt.
    private var announcedPrompt: String?
    /// The prompt the user put the island away on: it neither holds the island open nor opens it again.
    private var dismissedPrompt: String?
    private var promptGoneSince: Date?
    private var activityTimer: Timer?
    private var appearances: [String: TabAppearance] = [:]
    private var histories: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "sentHistory") as? [String: [String]]) ?? [:]
    private let signalReceiver: ClaudeSignalReceiver?
    @Published var claudeSignalsEnabled = ClaudeHooks.enabled
    var controller: NotchController?
    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
    /// The open island's size: the window's own when there is one; without a window (previews, tests) the size the settings
    /// give on a screen with no limit.
    var islandSize: CGSize {
        controller?.expandedFrame.size ?? NotchGeometry.expandedSize(screen: CGSize(width: 10_000, height: 10_000), topInset: neckWithoutWindow, settings: display)
    }
    /// The header's height without a window to ask (previews, tests); with one it is the notch's, or 28 pt on a screen without one.
    var neckWithoutWindow: CGFloat = 28
    /// The header's height: the notch's, or 28 pt on a screen without one.
    var neckHeight: CGFloat { controller?.neckHeight ?? neckWithoutWindow }

    /// Previews and tests pass false so they never take over the running app's event socket, and a suite of their own
    /// so the display settings they change never reach the real preferences.
    init(receivesSignals: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        display = DisplaySettings.load(from: defaults)
        signalReceiver = receivesSignals ? ClaudeSignalReceiver() : nil
        if let data = UserDefaults.standard.data(forKey: "tabAppearances") { appearances = (try? JSONDecoder().decode([String: TabAppearance].self, from: data)) ?? [:] }
        terminalBridge.onSnapshot = { [weak self] tabs, scope, requested in self?.updateExternalTabs(tabs, ttys: scope, requestedAt: requested) }
        terminalBridge.onFailure = { [weak self] error in
            self?.notice = error
            self?.sessions.filter(\.isExternal).forEach { $0.isRunning = false }
        }
        // Snapshots update activity as they arrive; this timer only lets recent output fade out.
        let activityTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateActivity() }
        activityTimer.tolerance = 0.3
        RunLoop.main.add(activityTimer, forMode: .common)
        self.activityTimer = activityTimer
        signalReceiver?.onEvent = { [weak self] event in self?.receiveClaude(event) }
        watchRest()
    }

    /// Why nobody can see the screen right now ("pantallas", "bloqueo", "sesión").
    private(set) var restReasons = Set<String>()
    private var restObservers: [(NotificationCenter, NSObjectProtocol)] = []
    func rest(_ reason: String, _ resting: Bool) {
        if resting { restReasons.insert(reason) } else { restReasons.remove(reason) }
        terminalBridge.resting = !restReasons.isEmpty
    }
    deinit { restObservers.forEach { $0.0.removeObserver($0.1) } }
    private func watchRest() {
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: String, _ change: @escaping (AppModel) -> Void) {
            restObservers.append((center, center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self.map(change) }))
        }
        on(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.rest("pantallas", true) }
        on(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.rest("pantallas", false) }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.rest("sesión", true) }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.rest("sesión", false) }
        on(distributed, "com.apple.screenIsLocked") { $0.rest("bloqueo", true) }
        on(distributed, "com.apple.screenIsUnlocked") { $0.rest("bloqueo", false) }
        // Back from the Mac's own sleep (every process was frozen): read what changed meanwhile.
        on(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.terminalBridge.refresh() }
    }

    func restore() {
        _ = try? Shell.run(backend.executable, backend.arguments() + ["source-file", backend.configuration])
        if let data = UserDefaults.standard.data(forKey: "sessions"), let records = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessions = records.filter { backend.exists($0) }.map { TerminalSession(record: $0, backend: backend, create: false) }
        }
        selectedID = sessions.first?.id
        let launchDate = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.launchDate
        if launchDate == UserDefaults.standard.object(forKey: "terminalLaunchDate") as? Date {
            if let data = UserDefaults.standard.data(forKey: "trackedTerminalTabs"), let tabs = try? JSONDecoder().decode([TrackedTerminalTab].self, from: data) { terminalBridge.restore(tabs: tabs) }
        }
        sessions.forEach(applyAppearance)
        save()
    }
    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(sessions.filter { !$0.isExternal }.map(\.record)), forKey: "sessions")
        UserDefaults.standard.set(try? JSONEncoder().encode(terminalBridge.trackedTabs), forKey: "trackedTerminalTabs")
        UserDefaults.standard.set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.launchDate, forKey: "terminalLaunchDate")
    }

    func showConnections(windowID: Int? = nil) {
        connectionSheet = true
        terminalBridge.discover { [weak self] windows in
            guard let self, let windowID, let window = windows.first(where: { $0.id == windowID }), let tab = window.tabs.first(where: \.selected) ?? window.tabs.first else { return }
            self.connectTerminalTab(tab)
        }
    }
    func connectTerminalTab(_ tab: TerminalTabSnapshot) {
        if let existing = sessions.first(where: { $0.externalTTY == tab.tty }) { selectedID = existing.id }
        else {
            let session = TerminalSession(tab: tab, backend: backend, bridge: terminalBridge)
            applyAppearance(session); sessions.append(session); selectedID = session.id
        }
        terminalBridge.connect(tab: tab)
        connectionSheet = false; notice = nil; save()
        controller?.expand(focus: true)
    }
    /// When the user last picked a tab in Nook; readings that started earlier can't override it.
    private var selectedAt = Date.distantPast
    /// The tab's notice was seen: its bell goes away, and the notch's when no other tab has one.
    func markSeen(_ session: TerminalSession) {
        guard session.unreadNotice != nil || session.taskState == .attention || session.taskState == .finished else { return }
        session.unreadNotice = nil
        if session.taskState == .attention || session.taskState == .finished { session.taskState = .idle }
        updateActivity()
    }
    /// The Terminal window in front of the user, when Terminal is the active app. Replaceable in tests.
    var frontTerminalWindow: () -> Int? = AppModel.frontmostTerminalWindow
    static func frontmostTerminalWindow() -> Int? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Terminal" else { return nil }
        // Front to back; Terminal's window ids are the window server's numbers.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }
    /// The tab is in front of the user: open in the island, or shown in the active Terminal window.
    func inFront(_ session: TerminalSession) -> Bool {
        if expanded, selectedID == session.id { return true }
        return session.shownInWindow && session.externalWindowID != nil && session.externalWindowID == frontTerminalWindow()
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        selectedAt = Date()
        markSeen(session)
        if let tty = session.externalTTY, let windowID = session.externalWindowID {
            selectedExternalTabs[windowID] = tty
            terminalBridge.select(windowID: windowID, tty: tty)
        }
    }
    func updateExternalTabs(_ tabs: [TerminalTabSnapshot], ttys: Set<String>, requestedAt: Date = .distantFuture) {
        // A reading in flight when the user picked another tab still shows the old one selected.
        let stale = requestedAt < selectedAt
        let knownWindows = Set(sessions.filter { ttys.contains($0.externalTTY ?? "") }.compactMap(\.externalWindowID)).union(tabs.map(\.windowID))
        let liveIDs = Set(tabs.map(\.tty))
        let previouslySelectedWindow = selected?.isExternal == true ? selected?.externalWindowID : nil
        var changed = false
        for tab in tabs {
            if let existing = sessions.first(where: { $0.externalTTY == tab.tty }) {
                if existing.externalWindowID != tab.windowID { changed = true }   // moved to another window
                existing.shownInWindow = tab.selected
                existing.update(tab)
                if !existing.menu.isEmpty, let agent = existing.agent { commands.learn(existing.menu, agent: agent) }
                // A collapsed island still follows the record for the agents in the notch; the hidden chat waits.
                followTranscript(existing, showingText: tab.history)
            } else { let session = TerminalSession(tab: tab, backend: backend, bridge: terminalBridge); applyAppearance(session); sessions.append(session); changed = true }
        }
        let removed = sessions.filter { $0.isExternal && ttys.contains($0.externalTTY!) && !liveIDs.contains($0.externalTTY!) }
        if !removed.isEmpty { changed = true }
        removed.forEach { terminalBridge.disconnect(tty: $0.externalTTY!) }
        sessions.removeAll { $0.isExternal && ttys.contains($0.externalTTY!) && !liveIDs.contains($0.externalTTY!) }
        for windowID in knownWindows {
            let group = tabs.filter { $0.windowID == windowID }
            if group.isEmpty {
                selectedExternalTabs.removeValue(forKey: windowID)
                continue
            }
            if !stale, let current = group.first(where: \.selected) {
                let previous = selectedExternalTabs[windowID]
                if previous != nil && previous != current.tty && previouslySelectedWindow == windowID {
                    selectedID = sessions.first { $0.externalTTY == current.tty }?.id
                }
                selectedExternalTabs[windowID] = current.tty
            }
        }
        if selected == nil { selectedID = sessions.first?.id }
        // A notice is seen once its tab is in front, here or in Terminal (Nook follows Terminal's tab switches).
        if sessions.contains(where: { $0.unreadNotice != nil }) {
            for session in sessions where session.unreadNotice != nil && inFront(session) { markSeen(session) }
        }
        // Snapshots arrive several times a second; preferences are written only when tabs come or go.
        if changed { save() }
        updateActivity()
    }
    func disconnectTerminalTab(_ tty: String) {
        terminalBridge.disconnect(tty: tty)
        sessions.removeAll { $0.externalTTY == tty }
        if selected == nil { selectedID = sessions.first?.id }
        save()
    }
    @discardableResult func create(_ kind: SessionKind, directory: String? = nil) -> TerminalSession? {
        guard FileManager.default.isExecutableFile(atPath: backend.executable) else { notice = "Falta el componente de terminal. Vuelve a construir Nook."; return nil }
        let count = sessions.filter { $0.record.kind == kind }.count
        let name = count == 0 ? kind.title : kind.title + " \(count + 1)"
        let record = SessionRecord(id: "nook-" + UUID().uuidString.prefix(8).lowercased(), name: name, kind: kind, directory: directory ?? NSHomeDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: true)
        applyAppearance(session)
        sessions.append(session)
        selectedID = session.id
        save()
        controller?.expand(focus: true)
        return session
    }
    func importSession(name: String, socket: String) {
        if let existing = sessions.first(where: { $0.record.id == name && $0.record.socket == socket }) { selectedID = existing.id; connectionSheet = false; return }
        let record = SessionRecord(id: name, name: name, kind: .shell, directory: NSHomeDirectory(), socket: socket, ownsSession: false)
        guard backend.exists(record) else { notice = "Esta sesión ya no está disponible."; return }
        let session = TerminalSession(record: record, backend: backend, create: false)
        applyAppearance(session)
        sessions.append(session); selectedID = session.id; save(); connectionSheet = false
        controller?.expand(focus: true)
    }
    func close(_ session: TerminalSession) {
        if let tty = session.externalTTY { disconnectTerminalTab(tty); updateActivity(); return }
        controller?.closeMirror(for: session)
        session.disconnectClients()
        sessions.removeAll { $0 === session }
        if selectedID == session.id { selectedID = sessions.first?.id }
        save(); updateActivity()
    }
    func terminate(_ session: TerminalSession) {
        guard !session.isExternal else { return }
        if session.record.ownsSession && backend.exists(session.record) {
            let alert = NSAlert()
            alert.messageText = "¿Terminar \(session.displayTitle)?"
            alert.informativeText = "Se terminará esta sesión y los procesos que estén ejecutándose en ella."
            alert.addButton(withTitle: "Cerrar sesión"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            backend.close(session.record)
        }
        close(session)
    }

    func customize(_ session: TerminalSession, title: String, tint: TabTint) {
        session.customTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        session.tint = tint
        appearances[session.id] = TabAppearance(title: session.customTitle, tint: tint)
        UserDefaults.standard.set(try? JSONEncoder().encode(appearances), forKey: "tabAppearances")
    }
    /// Like a shell's history: kept per tab across launches, without repeats in a row, capped.
    func remember(_ message: String, for session: TerminalSession) {
        guard session.sentHistory.last != message else { return }
        session.sentHistory = Array((session.sentHistory + [message]).suffix(50))
        histories[session.id] = session.sentHistory
        if histories.count > 30 { histories = histories.filter { id, _ in sessions.contains { $0.id == id } } }
        UserDefaults.standard.set(histories, forKey: "sentHistory")
    }
    /// The commands that complete what is being typed after "/" in this tab's field, best first.
    func completions(for session: TerminalSession, draft: String) -> [SlashCommand] {
        guard SlashCatalog.query(in: draft) != nil,
              let agent = session.agent ?? TerminalAgent(rawValue: session.record.kind.rawValue) else { return [] }
        return SlashCatalog.matches(commands.commands(agent: agent, skills: session.skills, accepted: session.usedCommands, sent: session.sentHistory), draft: draft)
    }
    private func applyAppearance(_ session: TerminalSession) {
        session.sentHistory = histories[session.id] ?? []
        if let appearance = appearances[session.id] { session.customTitle = appearance.title; session.tint = appearance.tint }
        session.onSignal = { [weak self, weak session] message in if let session { self?.receiveNotice(for: session, message: message) } }
        session.onAlert = { [weak self, weak session] kind, message in if let session { self?.raiseAlert(kind, for: session, message: message) } }
        session.onCompletion = { [weak self, weak session] in if let session { self?.noteCompletion(for: session) } }
    }
    func updateActivity() {
        let active = selected.map { session in
            // Claude's own spinner is the most precise signal; otherwise hooks or recent output.
            if let status = session.liveStatus { return status.working || session.taskState == .working }
            return session.taskState == .working || (session.taskState == .idle && Date().timeIntervalSince(session.lastOutput) < 2.5)
        } ?? false
        if working != active { working = active }
        let glyph = selected?.liveStatus.flatMap { $0.working ? $0.glyph : nil }
        if activityGlyph != glyph { activityGlyph = glyph }
        let agents = selected?.subagents.filter { $0.role == .agent && $0.isRunning }.count ?? 0
        if runningSubagents != agents { runningSubagents = agents }
        let count = sessions.filter { $0.unreadNotice != nil }.count
        if unreadCount != count { unreadCount = count }
        updatePrompt()
    }

    // MARK: Agent prompts

    /// Whether the selected tab shows a question the user has not answered or put away. While it does, the island stays
    /// open as if pinned: collapsing it would hide the one thing that is waiting on the user. Only an explicit
    /// collapse (the chevron, Esc) lets go, and then the same prompt never holds or opens the island again.
    var promptHoldsIsland: Bool {
        guard let signature = attention?.signature else { return false }
        return signature != dismissedPrompt
    }
    func dismissPrompt() { dismissedPrompt = attention?.signature }

    /// The selected tab's prompt when it is the agent asking for something: a permission, a plan, a question. A selector
    /// without numbers (`/resume`, `/config`) is a menu the user opened at the terminal themselves, so it gets its card
    /// when the island is open but never opens or holds it.
    private var attention: AgentPrompt? {
        guard let prompt = selected?.prompt, prompt.kind != .selector else { return nil }
        return prompt
    }

    /// A prompt that appears in the selected tab brings a collapsed island forward, without taking focus from whatever the
    /// user is doing. It is announced once: answering, collapsing by hand or switching tabs does not reopen it.
    func updatePrompt(now: Date = Date()) {
        guard let signature = attention?.signature else {
            // A prompt that flickers off for a moment (a redraw) is still the same one; only a lasting absence forgets it.
            if let since = promptGoneSince {
                if now.timeIntervalSince(since) > 3 { announcedPrompt = nil; dismissedPrompt = nil }
            } else { promptGoneSince = now }
            return
        }
        promptGoneSince = nil
        guard signature != announcedPrompt else { return }
        announcedPrompt = signature
        if signature != dismissedPrompt, !expanded { controller?.expand(focus: false) }
    }

    /// Chooses option `index` of `prompt` by pressing the keys that reach it, one after another: a click is the only
    /// trigger, and the keys are computed from the highlight on screen right now, never from what the card showed
    /// a moment ago. Nothing is sent when the screen no longer shows that same prompt. A failure stops the sequence.
    func answer(_ prompt: AgentPrompt, option index: Int, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        guard session.isRunning, let live = session.prompt, live.signature == prompt.signature else { completion(.failed); return }
        let keys = live.keys(choosing: index)
        // A text field that is already highlighted needs no key: the user can type into it.
        guard !keys.isEmpty else { completion(.sent); return }
        guard session.beginAnswer() else { completion(.failed); return }
        pressSequence(keys, on: session, whileShowing: live.signature) { [weak self, weak session] result in
            guard let session else { return }
            session.finishAnswer(delivered: result == .sent)
            // A failed script already explained itself through `notice`; tmux failures have no other voice.
            if result == .failed, self?.notice == nil { self?.notice = "No pude enviar la respuesta a la terminal. Revisa la pestaña original." }
            completion(result)
        }
    }

    /// Esc, which every dialog reads as "cancel".
    func cancelPrompt(on session: TerminalSession) {
        guard session.isRunning, session.beginAnswer() else { return }
        pressSequence([.escape], on: session) { [weak session] result in
            session?.finishAnswer(delivered: result == .sent)
        }
    }

    /// Presses `keys` one after another. With `signature`, each key after the first waits for the screen (read in the
    /// meantime) to still show that prompt: if the dialog is gone, the rest of the keys would land in whatever came
    /// next, so they are not sent.
    private func pressSequence(_ keys: [TerminalKey], on session: TerminalSession, whileShowing signature: String? = nil, completion: @escaping (KeyDelivery) -> Void) {
        guard let key = keys.first else { completion(.sent); return }
        session.press(key) { [weak self] result in
            guard let self else { return }
            self.handle(result, for: session, key: key)
            guard result == .sent else { completion(result); return }
            let rest = Array(keys.dropFirst())
            if let signature, !rest.isEmpty, session.prompt?.signature != signature {
                self.notice = "La pregunta cambió mientras respondía; no envié el resto de las teclas. Revisa la terminal."
                completion(.failed)
                return
            }
            self.pressSequence(rest, on: session, whileShowing: signature, completion: completion)
        }
    }
    /// A hook and the screen telling the same finish count once.
    func noteCompletion(for session: TerminalSession, now: Date = Date()) {
        if let last = lastCompletions[session.id], now.timeIntervalSince(last) < 15 { return }
        lastCompletions[session.id] = now
        completions += 1
    }
    func receiveNotice(for session: TerminalSession, message: String) {
        raiseAlert(.question, for: session, message: message)
    }
    /// An agent finished or asks for something: the tab gets its notice and a collapsed island its
    /// alert. Nothing for the tab already open in front of the user; the same kind again within a few
    /// seconds (a hook and the screen telling the same thing) only updates the notice.
    func raiseAlert(_ kind: NookAlert.Kind, for session: TerminalSession, message: String, now: Date = Date()) {
        // Like Claude's own bell: nothing for the tab the user is looking at.
        if inFront(session) { return }
        // A question or an error says more than a plain "finished", which never replaces them.
        if kind != .finished || session.unreadNotice == nil { session.unreadNotice = String(message.prefix(180)) }
        if kind != .finished || session.taskState != .attention { session.taskState = kind == .finished ? .finished : .attention }
        defer { updateActivity() }
        if let last = lastAlerts[session.id], last.kind == kind, now.timeIntervalSince(last.at) < 10 { return }
        lastAlerts[session.id] = (kind, now)
        alertSerial += 1
        alert = NookAlert(id: alertSerial, sessionID: session.id, kind: kind, title: session.displayTitle, message: String(message.prefix(180)))
    }
    func press(_ key: TerminalKey, on session: TerminalSession) {
        session.press(key) { [weak self] result in self?.handle(result, for: session, key: key) }
    }
    func interrupt(_ session: TerminalSession) {
        session.interrupt { [weak self] result in self?.handle(result, for: session, key: .escape) }
    }
    private func handle(_ result: KeyDelivery, for session: TerminalSession, key: TerminalKey) {
        switch result {
        case .sent:
            // The original tab came forward to receive the key; the island stays with it.
            if session.isExternal && key.needsDirectKeys { controller?.keepIslandWithTerminal(appPID: TerminalAppBridge.terminalPID) }
        case .needsPermission: requestDirectKeys()
        case .failed: break
        }
    }
    /// Pastes the clipboard's image into the agent the way ⌃V does in its terminal: the agent reads
    /// the image itself and shows it as "[Image #1]". Without Accessibility a Terminal tab can't get
    /// that key, so the image is saved as a file and its path goes into the message instead.
    func pasteImage(into session: TerminalSession, attachPath: @escaping (String) -> Void) {
        guard NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) else { notice = "No hay ninguna imagen en el portapapeles."; return }
        guard session.drivesAgent else { notice = "Pegar imágenes funciona en pestañas con Claude o Codex."; return }
        if session.isExternal && !DirectKeys.allowed {
            guard let path = Self.saveImage(from: .general) else { notice = "No se pudo guardar la imagen del portapapeles."; return }
            attachPath(path)
            notice = "Añadí la imagen como archivo al mensaje; \(session.agent?.title ?? "la IA") puede abrirla al enviarlo. Para pegarla como con ⌃V en la terminal, activa Nook en Accesibilidad."
            return
        }
        session.press(.pasteImage) { [weak self] result in self?.handle(result, for: session, key: .pasteImage) }
    }

    /// Writes the pasteboard's image as PNG in Nook's private temporary folder.
    static func saveImage(from pasteboard: NSPasteboard, folder: URL = URL(fileURLWithPath: "/tmp/nook-\(getuid())/images")) -> String? {
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .filter(\.isNumber)
        let url = folder.appendingPathComponent("imagen-\(stamp).png")
        return (try? png.write(to: url)) != nil ? url.path : nil
    }

    func requestDirectKeys() {
        let alert = NSAlert()
        alert.messageText = "Usar flechas, Tab y Escape en Terminal"
        alert.informativeText = "Para elegir opciones en los menús de Claude o Codex de una pestaña de Terminal, Nook necesita el permiso de Accesibilidad de macOS. Con él, Nook trae al frente solo la pestaña elegida, comprueba que es la correcta y pulsa la tecla allí. Los mensajes y Enter funcionan sin este permiso.\n\nTras activar Nook en Ajustes, vuelve a pulsar la tecla."
        alert.addButton(withTitle: "Abrir Ajustes…"); alert.addButton(withTitle: "Ver permisos"); alert.addButton(withTitle: "Ahora no")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: showPermissions(); return
        default: return
        }
        DirectKeys.request()
        notice = "Activa Nook en Privacidad y seguridad → Accesibilidad. Si instalas una versión nueva de Nook, macOS puede pedir el permiso otra vez."
    }
    func openLatestNotice() {
        guard let session = sessions.last(where: { $0.unreadNotice != nil }), let text = session.unreadNotice else { return }
        select(session); notice = "\(session.displayTitle): \(text)"; controller?.expand(focus: true)
    }
    func enableClaudeSignals() {
        let alert = NSAlert()
        alert.messageText = claudeSignalsEnabled ? "Desactivar avisos de Claude" : "Activar avisos de Claude en Nook"
        let files = ClaudeHooks.describe(ClaudeHooks.folders())
        alert.informativeText = claudeSignalsEnabled ? "Se quitarán únicamente los hooks de Nook de \(files). Tus otros ajustes y hooks se conservan." : "Añade hooks locales a \(files) para que Nook sepa al instante cuándo Claude trabaja, termina o necesita tu atención. Conserva tus otros ajustes y crea una copia de seguridad de cada archivo. Solo las pestañas que sigues en Nook mostrarán avisos."
        alert.addButton(withTitle: claudeSignalsEnabled ? "Desactivar" : "Activar"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.setEnabled(!claudeSignalsEnabled)
            claudeSignalsEnabled = ClaudeHooks.enabled
            notice = claudeSignalsEnabled ? "Avisos de Claude activados. En una sesión ya abierta, revisa /hooks para aprobar o cargar el cambio; algunas versiones requieren reabrir Claude." : "Avisos de Claude desactivados."
        } catch { notice = error.localizedDescription }
    }
    private func receiveClaude(_ event: ClaudeSignal) {
        if let session = sessions.first(where: { $0.externalTTY == event.tty && !event.tty.isEmpty }) { applyClaude(event, to: session); return }
        // A Claude process inside tmux has a pane TTY; its visible client has another.
        let candidates = sessions.map { ($0.id, $0.record, $0.externalTTY) }
        let backend = backend
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var matching = Set<String>()
            if let socket = event.tmuxSocket, let pane = event.tmuxPane {
                let name = (try? Shell.run(backend.executable, backend.arguments(socket: socket) + ["display-message", "-p", "-t", pane, "#{session_name}"]).1.trimmingCharacters(in: .newlines)) ?? ""
                let clientTTYs = (try? Shell.run(backend.executable, backend.arguments(socket: socket) + ["list-clients", "-t", "=" + name, "-F", "#{client_tty}"]).1.split(separator: "\n").map(String.init)) ?? []
                for (id, record, tty) in candidates {
                    if (record.socket == socket && record.id == name) || tty.map({ clientTTYs.contains($0) }) == true { matching.insert(id) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for session in self.sessions where matching.contains(session.id) { self.applyClaude(event, to: session) }
            }
        }
    }
    private let transcriptQueue = DispatchQueue(label: "dev.nook.transcripts", qos: .utility)

    /// Keeps a Claude tab's mirror on Claude's own record: found by the session id its hooks report,
    /// or else by the Claude process's working directory and the prompt on screen. Reading happens
    /// off the main thread and only touches what was appended.
    func followTranscript(_ session: TerminalSession, showingText: Bool = true) {
        guard session.agent == .claude, let tty = session.externalTTY else { return }
        if let follower = session.transcript {
            let viewing = showingText ? session.viewedAgent : nil
            transcriptQueue.async {
                if follower.poll() != nil { follower.unshown = true }
                // New text goes out only when the chat is on screen; read while collapsed, it waits until then.
                let text = showingText && follower.unshown ? follower.renderer.text : nil
                if text != nil { follower.unshown = false }
                let renderer = follower.renderer
                let agents = follower.agents()
                let agentText = follower.agentText(call: viewing)
                guard text != nil || agentText != nil || renderer.commandsVersion != follower.reportedCommands || agents != follower.reportedAgents else { return }
                follower.reportedCommands = renderer.commandsVersion; follower.reportedAgents = agents
                DispatchQueue.main.async {
                    if session.transcript === follower {
                        session.applyTranscript(text, recap: renderer.recap, skills: renderer.skills, usedCommands: renderer.usedCommands, agents: agents)
                        if let viewing, let agentText { session.applyAgentText(agentText, call: viewing) }
                    }
                }
            }
            // A guessed record is checked again now and then: /clear or another session may take over.
            guard session.transcriptByGuess, Date().timeIntervalSince(session.transcriptLocated) > 60 else { return }
        } else if Date().timeIntervalSince(session.transcriptLocated) < 10 { return }
        session.transcriptLocated = Date()
        let id = session.claudeSessionID, screen = session.mirroredText
        transcriptQueue.async {
            var url = id.flatMap { TranscriptLocator.record(session: $0) }
            let byGuess = url == nil
            if url == nil, let directory = TranscriptLocator.claudeDirectory(tty: tty) { url = TranscriptLocator.guess(directory: directory, screen: screen) }
            guard let url else { return }
            DispatchQueue.main.async {
                guard session.transcript?.url != url, session.agent == .claude else { return }
                let follower = TranscriptFollower(url: url)
                session.transcript = follower; session.transcriptByGuess = byGuess
                self.followTranscript(session, showingText: showingText)
            }
        }
    }

    /// Shows a subagent's own conversation in the tab's mirror (nil: back to Claude's), read at once.
    func view(agent call: String?, in session: TerminalSession) {
        session.view(agent: call)
        followTranscript(session)
    }

    /// A click on an agent's row: its conversation opens in the mirror. An agent of another tab brings that tab forward first.
    func openAgent(_ agent: SubagentActivity, in session: TerminalSession) {
        guard agent.role == .agent else { return }
        if selectedID != session.id { select(session) }
        view(agent: agent.id, in: session)
    }

    /// Esc, or the bar's button, in an agent's conversation: back to Claude's. False when no agent is shown, so the key
    /// keeps its other meaning (collapsing the island).
    @discardableResult func leaveAgentView() -> Bool {
        guard let session = selected, session.viewedAgent != nil else { return false }
        view(agent: nil, in: session)
        return true
    }

    private func applyClaude(_ event: ClaudeSignal, to session: TerminalSession) {
        if !event.sessionID.isEmpty { session.claudeSessionID = event.sessionID }
        switch event.event {
        case "UserPromptSubmit": session.taskState = .working; session.unreadNotice = nil
        case "Stop": noteCompletion(for: session); return raiseAlert(.finished, for: session, message: "Claude terminó su respuesta.")
        case "StopFailure": return raiseAlert(.failed, for: session, message: "Claude terminó con un error. Revisa la terminal.")
        case "Notification": return raiseAlert(.question, for: session, message: event.message)
        case "SessionEnd": session.taskState = .idle
        default: return
        }
        updateActivity()
    }
    /// What Nook saw and did for this tab, for the user to share when something misbehaves:
    /// the end of the raw screen (before any filtering) and the steps of the latest sends.
    func copyDiagnostics(_ session: TerminalSession) {
        let report = ["Nook · diagnóstico · \(Date().formatted(date: .abbreviated, time: .standard))",
                      "Pestaña: \(session.displayTitle) · \(session.agent?.title ?? "sin IA") · \(session.externalTTY ?? session.record.id)",
                      "Caja: «\(session.agentInput ?? "—")» · estado: \(session.agentStatus?.text ?? "—") · unido: \(session.joinedBox ?? "—")",
                      "", "— Últimos envíos —", terminalBridge.deliveryLog.isEmpty ? "(ninguno)" : terminalBridge.deliveryLog.joined(separator: "\n"),
                      "", "— Pantalla, últimos 4.000 caracteres sin filtrar —", String(session.mirroredText.suffix(4000))].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notice = "Diagnóstico copiado. Incluye el final de la pantalla de esta pestaña; pégalo donde quieras revisarlo."
    }
    func copyConnection() {
        guard let session = selected, !session.isExternal else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(backend.attachmentCommand(for: session.record), forType: .string)
        notice = "Comando copiado. Pégalo en una terminal libre para compartir esta sesión."
    }
}
