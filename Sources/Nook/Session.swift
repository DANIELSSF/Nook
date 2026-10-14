import AppKit
import Combine
import os
import SwiftTerm

/// Why a tab left Nook: every removal says so, readable with `log show --predicate 'subsystem == "dev.nook.mac"'`.
let tabLog = Logger(subsystem: "dev.nook.mac", category: "tabs")

enum Shell {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// `input` goes to the command's standard input, which is then closed: what a command reads there never shows in its arguments,
    /// which any process can list (`ps`).
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, input: Data? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe(), feed = input.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = output
        if let feed { process.standardInput = feed }
        try process.run()
        if let input, let feed {
            // A command that exits without reading it must not end Nook (or a test) with SIGPIPE.
            _ = fcntl(feed.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? feed.fileHandleForWriting.write(contentsOf: input)
            try? feed.fileHandleForWriting.close()
        }
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

struct SessionRecord: Codable, Identifiable, Equatable {
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
    enum Presence { case present, gone, unknown }
    /// Whether the session is still there. `unknown` when tmux could not answer (it could not run, or failed for a reason of its
    /// own, say a rebuild replacing it), so a saved session is never forgotten for a failure on Nook's side.
    func presence(_ record: SessionRecord) -> Presence {
        guard let (status, output) = try? Shell.run(executable, arguments(socket: record.socket) + ["has-session", "-t", "=" + record.id]) else { return .unknown }
        if status == 0 { return .present }
        return Self.saysGone(output) ? .gone : .unknown
    }
    /// tmux's own words for a session or server that is not there.
    static func saysGone(_ output: String) -> Bool {
        ["can't find session", "no server running", "error connecting to"].contains { output.contains($0) }
    }
    func exists(_ record: SessionRecord) -> Bool { presence(record) == .present }
    func sessions(socket candidate: String) -> [String] {
        guard let result = try? Shell.run(executable, arguments(socket: candidate) + ["list-sessions", "-F", "#{session_name}"]), result.0 == 0 else { return [] }
        return result.1.split(separator: "\n").map(String.init)
    }
    func close(_ record: SessionRecord) {
        _ = try? Shell.run(executable, arguments(socket: record.socket) + ["kill-session", "-t", "=" + record.id])
    }
    /// The device of the session's pane ("/dev/ttys003"), where its agent's processes are found.
    func paneTTY(_ record: SessionRecord) -> String? {
        guard let result = try? Shell.run(executable, arguments(socket: record.socket) + ["display-message", "-p", "-t", "=" + record.id + ":", "#{pane_tty}"]),
              result.0 == 0 else { return nil }
        let tty = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }
    /// What the pane shows, scrollback first, with wrapped lines joined: the same plain text Terminal gives for its tabs.
    func capture(_ record: SessionRecord, lines: Int = 2000) -> String? {
        guard let result = try? Shell.run(executable, arguments(socket: record.socket) + ["capture-pane", "-p", "-J", "-t", "=" + record.id + ":", "-S", "-\(lines)"]),
              result.0 == 0 else { return nil }
        return result.1
    }
    /// The pane's visible screen alone, wrapped lines joined: the quick reading a delivery checks after each step.
    func screen(_ record: SessionRecord) -> String? {
        guard let result = try? Shell.run(executable, arguments(socket: record.socket) + ["capture-pane", "-p", "-J", "-t", "=" + record.id + ":"]),
              result.0 == 0 else { return nil }
        return result.1
    }
    /// Pastes `text` into the session's pane as tmux's own paste: between bracketed-paste marks when the program asked for them
    /// (Claude does), its line breaks as they are, and nothing pressed after it. Control characters never travel (`TerminalText`):
    /// an Escape would end the paste early. The text reaches tmux on standard input, never in a command's arguments, and the buffer
    /// it goes through never outlives the paste.
    func paste(_ text: String, into record: SessionRecord) throws {
        let buffer = "nook-send-" + UUID().uuidString.prefix(8), base = arguments(socket: record.socket)
        let loaded = try Shell.run(executable, base + ["load-buffer", "-b", buffer, "-"], input: Data(TerminalText.sendable(text).utf8)).0 == 0
        guard loaded, try Shell.run(executable, base + ["paste-buffer", "-d", "-p", "-r", "-b", buffer, "-t", "=" + record.id + ":"]).0 == 0 else {
            _ = try? Shell.run(executable, base + ["delete-buffer", "-b", buffer])
            throw TerminalBridgeError.failed("tmux no pudo pegar el mensaje en la sesión.")
        }
    }
    /// One key in the session's pane, by tmux's name for it ("Enter").
    func press(_ key: String, in record: SessionRecord) throws {
        guard try Shell.run(executable, arguments(socket: record.socket) + ["send-keys", "-t", "=" + record.id + ":", key]).0 == 0 else {
            throw TerminalBridgeError.failed("tmux no pudo pulsar \(key) en la sesión.")
        }
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
    /// Claude's welcome banner for this tab's session (version, model, effort, plan, folder), out of the chat.
    @Published private(set) var banner: ClaudeBanner?
    /// Claude is open in the tab and waits for the first message of its conversation: its banner is known and nothing was said yet,
    /// neither a message of the user's nor an answer (Claude's grey suggestion in its box is no message). A message just sent from
    /// Nook (`pendingMessage`), one Claude holds in its queue, or a turn under way counts as begun, so nothing flashes after a send.
    /// Kept up to date as readings arrive (`noteFirstMessage`): reading it costs nothing.
    @Published private(set) var awaitsFirstMessage = false
    /// The conversation on show has a message or an answer in it: Claude's record, or the screen after Claude's newest banner.
    private var recordBegun = false, screenBegun = false
    /// What Claude warned about as it started (permission rules it flags in a settings file…), once each, out of the chat.
    @Published private(set) var startupWarnings: [ClaudeStartupWarning] = []
    /// Claude's permission mode as named under its box ("auto mode on", "plan mode on") with its key hints, or
    /// `ClaudeMode.standard` in the default mode. A reading that can't tell (no box, the "/" menu in its place) keeps the last
    /// one; nil while Claude isn't running in the tab. ⇧⇥ cycles it (`AppModel.cycleMode(on:)`).
    @Published private(set) var agentMode: ClaudeMode?
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
    @Published var pendingMessage: String? { didSet { if pendingMessage != oldValue { noteFirstMessage() } } }
    /// The screen's conversation and Claude's record when the message went, so only what came after counts as its arrival.
    private var pendingBaseline = ""
    private var pendingRecordBaseline: String?
    private var pendingSince = Date.distantPast
    /// What was sent while Claude worked and Claude still holds (grey in its terminal), oldest first, from its record. Sent from
    /// Nook or typed in the terminal alike.
    @Published private(set) var claudeQueue: [String] = []
    /// The message on its way is held in Claude's queue: Claude takes it when its turn allows.
    var pendingQueued: Bool { pendingMessage.map { pending in claudeQueue.contains { MessageEcho.same($0, pending) } } ?? false }
    /// Claude's own record of this tab's conversation. When found, the mirror shows it in full (in
    /// fullscreen rendering Terminal only holds the visible screen); the screen still feeds the box,
    /// status, prompts and agents.
    var transcript: TranscriptFollower?
    var transcriptByGuess = false
    var transcriptLocated = Date.distantPast
    /// The session id Claude's hooks report for this tab, and when they last did (it may disagree with Claude's own file for its
    /// process, `ClaudeRecordLocator`: the newer says which record the tab's Claude writes).
    var claudeSessionID: String? {
        didSet {
            claudeSessionIDAt = Date()
            if claudeSessionID != oldValue { transcriptLocated = .distantPast }
        }
    }
    private(set) var claudeSessionIDAt = Date.distantPast
    /// What a hook says about the session. Every event names the one the tab's Claude works on now, except SessionEnd: it names
    /// the one that just ended, and as hooks run async it lands after a /clear has already moved Claude to the next. Taken as a
    /// claim, it would be the newest word and hold the tab on the old record; it only withdraws that claim, so Claude's own
    /// file names the next.
    func noteClaudeHook(_ event: String, sessionID: String) {
        guard !sessionID.isEmpty else { return }
        if event != "SessionEnd" { claudeSessionID = sessionID } else if claudeSessionID == sessionID { claudeSessionID = nil }
    }
    /// Finds this tab's record from what its Claude process says about itself; made for the device it runs on, and anew when Claude
    /// leaves the tab. Used on the reading queue.
    private(set) var recordLocator: ClaudeRecordLocator?
    func recordLocator(tty: String, make: (String) -> ClaudeRecordLocator) -> ClaudeRecordLocator {
        if let locator = recordLocator, locator.tty == tty { return locator }
        let locator = make(tty)
        recordLocator = locator
        return locator
    }
    private(set) var transcriptText: String?

    func applyTranscript(_ text: String?, recap: String?, skills: [String: String] = [:], usedCommands: Set<String> = [], agents: [SubagentActivity]? = nil,
                         queued: [String]? = nil, shells: [ShellActivity]? = nil) {
        if let text {
            if transcriptText != text { recordBegun = ClaudeExchange.begun(text) }
            transcriptText = text
            if viewedAgent == nil, displayText != text { displayText = text }
        }
        // Task notifications and other sessions' messages share Claude's queue; they start with their tag.
        if let queued = queued?.filter({ !$0.hasPrefix("<") }), queued != claudeQueue { claudeQueue = queued }
        if text != nil || queued != nil { settlePending(screen: screenConversation); noteFirstMessage() }
        if let recap, self.recap != recap { self.recap = recap }
        self.skills = skills; self.usedCommands = usedCommands
        if let agents { recordAgents = agents; showAgents() }
        if let shells, self.shells != shells { self.shells = shells }
    }

    /// The agents Claude's record names (nil without a record), and the list Claude draws under its mode line on the latest
    /// screen. The record knows every agent and what each was asked; the list says, in Claude's words, what runs right now.
    private var recordAgents: [SubagentActivity]?
    private var screenTree: [SubagentActivity]?

    /// One list for the pill and the tab: the record's agents with the list's live words, and agents only the list shows.
    private func showAgents() {
        let shown = AgentActivity.merged(recordAgents ?? [], tree: screenTree)
        if subagents != shown { subagents = shown }
    }

    /// The subagent (its launch's call id) whose own conversation the mirror shows instead of Claude's,
    /// like entering an agent's view in Claude's terminal; nil shows the main conversation.
    @Published private(set) var viewedAgent: String?
    /// The main conversation as the screen shows it, for coming back when there is no record.
    private var screenConversation = ""

    func view(agent call: String?) {
        // Back to Claude, or into an agent: a shell's output on show goes too.
        leaveShell()
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

    // MARK: Background shells

    /// The commands Claude runs in the background in this tab (Claude's "· 1 shell"), from its record: running ones, and finished
    /// ones for ten minutes after they end, in launch order. Empty without Claude's record.
    @Published private(set) var shells: [ShellActivity] = []
    /// The shell (its task id) whose output is on show instead of Claude's conversation; nil shows the conversation. Entering a
    /// shell leaves an agent's view and entering an agent (or going back to Claude, `view(agent: nil)`) leaves the shell's.
    /// The conversation (`displayText`) stays Claude's meanwhile, ready for coming back.
    @Published private(set) var viewedShell: String?
    /// The viewed shell's output as last read: nil until its first reading arrives after entering.
    @Published private(set) var shellOutput: ShellOutput?
    /// Counts the enterings: the first reading after each one hands the output over even when nothing new was written.
    private(set) var shellViewEpoch = 0

    /// How many shells Claude's mode line counts right now ("· 1 shell"), when it shows a count; a hint for shells the record
    /// doesn't name (started before what Nook read of it). No count does not mean none run.
    var screenShellCount: Int? { agent == .claude ? agentMode.flatMap { ShellActivity.count(inHints: $0.hints) } : nil }

    func view(shell id: String?) {
        if id != nil, viewedAgent != nil { view(agent: nil) }
        guard viewedShell != id else { return }
        viewedShell = id
        shellViewEpoch += 1
        if shellOutput != nil { shellOutput = nil }
    }

    func applyShellOutput(_ output: ShellOutput, id: String) {
        guard viewedShell == id, shellOutput != output else { return }
        shellOutput = output
    }

    private func leaveShell() {
        guard viewedShell != nil || shellOutput != nil else { return }
        if viewedShell != nil { viewedShell = nil }
        if shellOutput != nil { shellOutput = nil }
        shellViewEpoch += 1
    }

    /// Without Claude's record there are no shells to show.
    private func forgetShells() {
        leaveShell()
        if !shells.isEmpty { shells = [] }
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
    @Published var icon: TabIcon = .dot
    @Published var taskState: TaskState = .idle
    @Published var unreadNotice: String?
    /// This tab's own switch for the alert sound, on unless the user turned it off (`AppModel.setAlertSound(_:for:)`, which keeps
    /// it by the tab's id); `AppModel.alertSound` has the switch for every tab at once.
    @Published fileprivate(set) var alertSoundOn = true
    /// Claude's reasoning effort as its screen last reported it; nil until it says.
    @Published private(set) var effort: ClaudeEffort?
    var displayTitle: String { customTitle.isEmpty ? title : customTitle }
    var externalTTY: String?
    var isExternal: Bool { externalTTY != nil }
    /// The tab is the one its Terminal window shows (the selected tab of that window).
    var shownInWindow = false
    weak var terminalBridge: TerminalAppBridge?
    var onSignal: ((String) -> Void)?
    private var signalParser = TerminalSignalParser()
    /// The session's own terminal view, made when first asked for. A Terminal tab never shows one (Nook mirrors Terminal's text),
    /// so it never pays for SwiftTerm's view, its buffers and its layers.
    var terminal: ActivityTerminalView {
        if let ownTerminal { return ownTerminal }
        let view = ActivityTerminalView(frame: isExternal ? .zero : NSRect(x: 0, y: 0, width: 680, height: 310))
        ownTerminal = view
        if !isExternal { configure(view) }
        return view
    }
    private var ownTerminal: ActivityTerminalView?
    /// Whether the session's terminal view was made (`terminal`).
    var hasTerminalView: Bool { ownTerminal != nil }
    private var mirrors: [ActivityTerminalView] = []
    let backend: TmuxBackend
    var externalWindowID: Int?
    var externalAppPID: pid_t?

    init(record: SessionRecord, backend: TmuxBackend, create: Bool) {
        self.record = record
        self.backend = backend
        title = record.name
        super.init()
        var args = backend.arguments(socket: record.socket)
        if create {
            args += ["new-session", "-A", "-s", record.id, "-c", record.directory, record.kind.shellCommand]
        } else { args += ["attach-session", "-t", "=" + record.id] }
        terminal.startProcess(executable: backend.executable, args: args, environment: Self.environment, currentDirectory: record.directory)
    }

    /// `login` makes the tab's identity (`TerminalTabIdentity`): its id, and so its saved name, colour and history, belong to
    /// this tab and not to the TTY, which macOS hands to the next tab once this one closes.
    init(tab: TerminalTabSnapshot, backend: TmuxBackend, bridge: TerminalAppBridge, login: String? = nil) {
        record = SessionRecord(id: TerminalTabIdentity.key(tty: tab.tty, login: login), name: tab.title, kind: .shell, directory: "", socket: "terminal.app", ownsSession: false)
        self.backend = backend
        title = tab.title
        externalTTY = tab.tty
        shownInWindow = tab.selected
        externalWindowID = tab.windowID
        externalAppPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
        terminalBridge = bridge
        super.init()
        update(tab)
    }

    func update(_ tab: TerminalTabSnapshot) {
        // Every published assignment re-renders SwiftUI, so unchanged values are not reassigned.
        if title != tab.title { title = tab.title }
        if busy != tab.busy { busy = tab.busy }
        if !isRunning { isRunning = true }
        externalWindowID = tab.windowID
        applyScreen(tab.text, foreground: tab.agent, history: tab.history)
    }

    /// One reading of an agent's screen, a Terminal tab's or a Nook session's pane: the mirror, Claude's box, status, prompts,
    /// panel and agents. `history` is false when only the visible screen was read.
    private func applyScreen(_ raw: String, foreground: TerminalAgent?, history: Bool) {
        let text = raw.trimmingCharacters(in: .newlines)
        guard history else { return updateScreen(text, foreground: foreground) }
        guard mirroredText != text || agent != foreground else { return }
        if mirroredText != text {
            archive = Self.archived(archive, previous: mirroredText, next: text, limit: archiveLimit)
            mirroredText = text; lastOutput = Date()
        }
        if agent != foreground { agent = foreground }
        if foreground != .claude, transcript != nil { transcript = nil; transcriptText = nil; recordBegun = false; transcriptLocated = .distantPast; skills = [:]; usedCommands = []; viewedAgent = nil; forgetShells() }
        if foreground != .claude { recordLocator = nil }
        if foreground != .claude, effort != nil { effort = nil }
        noteEffort(in: text)
        // With Claude's record the conversation comes from there: only the window is split (box, status, prompt, panel, agents), not
        // the 320,000 characters with what slid out of it, and that conversation is not kept. Without a record the screen is the
        // mirror, all of it.
        let fromRecord = transcriptText != nil && foreground == .claude
        let split = fromRecord ? Self.screen(text, agent: foreground, earlier: archive) : Self.screen(archive + text, agent: foreground)
        menu = split.menu
        screenConversation = fromRecord ? "" : split.conversation
        // Published only when it changed: every assignment redraws the island, also with the same 240,000 characters.
        if viewedAgent == nil, displayText != (transcriptText ?? split.conversation) { displayText = transcriptText ?? split.conversation }
        readPrompt(in: split.conversation, agent: foreground)
        showPanel(split.panel, agent: foreground)
        watchTurn(status: split.status, conversation: split.conversation)
        if agentInput != split.input { agentInput = split.input }
        liveStatus = split.status
        if agentStatus != split.status { agentStatus = split.status }
        if transcriptText == nil, recap != split.recap { recap = split.recap }
        if banner != split.banner { banner = split.banner }
        if startupWarnings != split.warnings { startupWarnings = split.warnings }
        let mode = split.mode ?? (foreground == .claude ? agentMode : nil)
        if agentMode != mode { agentMode = mode }
        // The banner names the effort the session started with; anything Claude reported since wins.
        if foreground == .claude, effort == nil, let level = split.banner?.effort.flatMap(ClaudeEffort.init(rawValue:)) { effort = level }
        if let joined = joinedBox, !MessageEcho.same(split.input ?? "", joined) { joinedBox = nil }
        settlePending(screen: split.conversation)
        // Only a screen whose box was found is split for sure: one caught mid-redraw keeps its box line ("❯ Try …") in the chat.
        if foreground != .claude { screenBegun = false } else if split.input != nil { screenBegun = ClaudeExchange.begun(split.conversation) }
        noteFirstMessage()
        // With Claude's record, its agents come from there (they scroll off the screen) and the list under the mode line adds
        // its live words. Otherwise the raw screen, whose mode line's background count closes finished agents.
        if transcript == nil {
            recordAgents = nil; screenTree = nil
            let found = foreground == .claude ? AgentActivity.parse(text) : []
            if subagents != found { subagents = found }
        } else {
            let tree = AgentActivity.tree(text)
            if tree != screenTree { screenTree = tree; showAgents() }
        }
    }

    /// What slid out of the 80,000 characters Terminal returns. Kept in front of them so the mirror
    /// only grows at its end: older text stays readable and an update never shifts what is being
    /// read (and only the changed tail is laid out again).
    private(set) var archive = ""

    /// The tab left Nook (closed, or gone from Terminal): its texts, Claude's record as read and its agents go now. A view on its way out
    /// may still hold the tab itself for a while (the tab strip's context menu was seen to), and must not hold megabytes with it.
    /// A tab that comes back is a new one.
    func releaseClosed() {
        archive = ""; screenConversation = ""; screenText = ""; pendingBaseline = ""; pendingRecordBaseline = nil
        transcript = nil; transcriptText = nil; recordAgents = nil; screenTree = nil; menu = []; recordLocator = nil; recordBegun = false; screenBegun = false
        forgetShells()
        if !mirroredText.isEmpty { mirroredText = "" }
        if !displayText.isEmpty { displayText = "" }
    }

    /// What this tab can do without while nobody looks at it (`AppModel.trimMemory`): the text that slid out of Terminal's window (a
    /// mirror without Claude's record starts again from what Terminal holds), and Claude's record as read so far (a new reader
    /// reads the same text from the file at the next look), with the output of a shell on show (read again when the tab is).
    func releaseHiddenMemory() {
        archive = ""
        if let follower = transcript { transcript = TranscriptFollower(url: follower.url) }
        if shellOutput != nil { shellOutput = nil; shellViewEpoch += 1 }
    }
    static let archiveLimit = 240_000
    /// This tab's cap on `archive`, in UTF-16 units (tests lower it).
    var archiveLimit = TerminalSession.archiveLimit

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

    /// Claude's window alone, when its conversation comes from Claude's record. Its banner (version, model, effort) may have scrolled
    /// out of the window into `earlier`; it is looked for there, as the whole text would show it, only when the window has none.
    static func screen(_ text: String, agent: TerminalAgent?, earlier: String) -> ClaudeScreen {
        // The last lines before the window go with it: Terminal's cut may run through a banner, its warnings or the latest status.
        var start = earlier.endIndex, lines = 0
        while start > earlier.startIndex, lines < 200 {
            let previous = earlier.index(before: start)
            if earlier[previous] == "\n" { lines += 1; if lines == 200 { break } }
            start = previous
        }
        var screen = screen(earlier[start...] + text, agent: agent)
        if agent == .claude, screen.banner == nil, !earlier.isEmpty, let found = ClaudeStartup.newest(in: earlier, before: text) {
            screen.banner = found.banner; screen.warnings = found.warnings
        }
        return screen
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
        noteEffort(in: text)
        let split = Self.screen(text, agent: foreground)
        menu = split.menu
        liveStatus = split.status
        readPrompt(in: split.conversation, agent: foreground)
        showPanel(split.panel, agent: foreground)
        watchTurn(status: split.status, conversation: split.conversation)
        if let joined = joinedBox, !MessageEcho.same(split.input ?? "", joined) { joinedBox = nil }
        settlePending(screen: split.conversation)
        noteFirstMessage()
    }

    /// A panel Claude draws instead of its box (/usage, /status, /config, /mcp…), live from the screen:
    /// Claude's record never holds it. A question with options gets its card instead. Claude's usage panel is all of it read
    /// since it opened, also what scrolled out of the screen (`ClaudeUsageReader`).
    @Published private(set) var panel: String?
    /// When Esc last went to the open panel (see `AppModel.press`): the closing that follows is what the user asked for.
    var panelEscapedAt: Date?
    /// Claude's usage panel as read over time, and the walk that reads the rest of it in a Nook session (ClaudeUsageReader.swift).
    let usageReader = ClaudeUsageReader()
    /// Nook is scrolling Claude's usage panel in this session to read the rest of it (`ClaudeUsageWalk`).
    @Published var readingPanel = false
    /// What Claude's status line reports for this tab, live (NookStatusLine.swift): its cost, context and cache, and its
    /// account's rate limits. Nil while Nook's status line is not installed, or Claude has not run it for this tab yet.
    @Published var liveUsage: ClaudeLiveUsage?
    /// Nook's own usage card is open in this tab (`AppModel.openUsage`): made from `liveUsage`, with nothing typed in the
    /// terminal, and closed in Nook alone. Claude's own panel, when one opens, is shown in its place.
    @Published var usageCardOpen = false
    private func showPanel(_ found: String?, agent: TerminalAgent?) {
        let shown = usageReader.read(agent == .claude && prompt == nil ? found : nil)
        if panel != shown { panel = shown }
        walkUsagePanelIfDue()
    }
    /// The usage panel read further than the screen shows (a walk's page): on the island at once.
    func showReadPanel() {
        guard panel != nil, let whole = usageReader.text, panel != whole else { return }
        panel = whole
    }

    /// Called when Claude's /model picker comes up (or changes) on this tab's screen.
    var onModelPicker: ((AgentPrompt) -> Void)?
    /// The model Claude says this tab uses: its banner's, kept up to date by its answers to /model.
    var currentModel: String? { banner?.model }
    /// The config folder Claude keeps this tab's record in (".claude", ".claude-work"): one account, one set of models.
    var claudeFolder: String? {
        guard let parts = transcript?.url.pathComponents, let projects = parts.lastIndex(of: "projects"), projects > 0 else { return nil }
        return parts[projects - 1]
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
        if prompt != found {
            prompt = found
            // Claude's /model picker is where Nook learns which models this account offers.
            if agent == .claude, let found, ClaudeModelStore.isModelPicker(found) { onModelPicker?(found) }
        }
        // The screen changed (the dialog closed or the highlight moved): the answer's effect is visible.
        if answering, !keysInFlight, found != answeringFrom { answering = false }
        noteChosenField(found)
        noteFilledField(found)
    }

    /// The text field of the dialog on screen that the user chose on its card (`AppModel.answer(_:option:on:)` with a `.inline`
    /// option): nothing was pressed for it, and the next message from Nook's composer is its answer (`AppModel.fieldAnswer(for:)`).
    /// Published: the pane turns the composer into that field's answer box while it stands.
    @Published private(set) var chosenField: (signature: String, option: Int)?
    func chooseField(_ index: Int, of prompt: AgentPrompt) { chosenField = (prompt.signature, index); chosenFieldGoneSince = nil }
    func forgetChosenField() {
        chosenFieldGoneSince = nil
        if chosenField != nil { chosenField = nil }
    }
    /// How long the screen must show no dialog at all before the chosen field is forgotten: a reading caught mid-redraw has none
    /// for a moment, and the same question must not lose its field for it; once the dialog is really gone, an identical question
    /// asked later must not find its field already chosen. As long as `AppModel.updatePrompt` takes to forget a prompt. Tests
    /// shorten it.
    var chosenFieldGrace: TimeInterval = 3
    /// Since when the readings show no dialog while a field is chosen.
    private var chosenFieldGoneSince: Date?

    /// The chosen field after a reading that found `found`: another dialog drops it at once. No dialog starts the grace, and any
    /// reading once it has run out drops the field, also one that shows the same question again: a screen that stays still after
    /// the dialog went is read only once (an unchanged screen isn't parsed again), so the absence is timed from that reading. A
    /// reading with the dialog within the grace was a redraw caught midway, and starts it over.
    private func noteChosenField(_ found: AgentPrompt?, now: Date = Date()) {
        guard let chosen = chosenField else { chosenFieldGoneSince = nil; return }
        if let since = chosenFieldGoneSince, now.timeIntervalSince(since) >= chosenFieldGrace { forgetChosenField(); return }
        guard let found else {
            if chosenFieldGoneSince == nil { chosenFieldGoneSince = now }
            return
        }
        chosenFieldGoneSince = nil
        if found.signature != chosen.signature { forgetChosenField() }
    }

    /// The text field Nook last wrote an answer into that stays on screen with it: a question that takes several answers keeps its
    /// dialog, its field holding the text and its box ticked, and Claude keeps the highlight there. Pasting into it again would
    /// add to that text (the input keeps it, its cursor at the end, and has no key that clears a wrapped field in one go: Ctrl+U
    /// only reaches the start of the row on screen), so it is no field to answer any more (`AppModel.fieldAnswer(for:)`), and
    /// choosing it on the card toggles its box as Enter does there. Kept by the question's identity, which the text in the field
    /// doesn't change; dropped like a chosen field when another dialog shows, or none for `chosenFieldGrace`.
    private(set) var filledField: (identity: String, option: Int)?
    private var filledFieldGoneSince: Date?
    func noteFilledField(_ index: Int, of prompt: AgentPrompt) {
        filledField = (prompt.identity(ignoringOption: index), index); filledFieldGoneSince = nil
    }
    func isFilledField(_ index: Int, of prompt: AgentPrompt) -> Bool {
        guard let filled = filledField, filled.option == index else { return false }
        return filled.identity == prompt.identity(ignoringOption: index)
    }
    /// The same rule as `noteChosenField`, by identity.
    private func noteFilledField(_ found: AgentPrompt?, now: Date = Date()) {
        guard let filled = filledField else { filledFieldGoneSince = nil; return }
        if let since = filledFieldGoneSince, now.timeIntervalSince(since) >= chosenFieldGrace { filledField = nil; filledFieldGoneSince = nil; return }
        guard let found else {
            if filledFieldGoneSince == nil { filledFieldGoneSince = now }
            return
        }
        filledFieldGoneSince = nil
        if !isFilledField(filled.option, of: found) { filledField = nil }
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

    // MARK: An agent in a Nook session

    /// A Nook session's pane device, read once; the agent's processes and Claude's record are found through it.
    private(set) var paneTTY: String?
    /// The device the agent runs on: a Terminal tab's, or a Nook session's pane.
    var agentTTY: String? { externalTTY ?? paneTTY }
    /// Nook shows the agent's conversation instead of its terminal: every Terminal tab, and a Nook session while Claude or Codex
    /// runs in it. A shell keeps showing the terminal itself.
    var mirrorsAgent: Bool { isExternal || agent != nil }
    /// After each reading of a Nook session's pane; the model follows Claude's record from there.
    var onPaneRead: (() -> Void)?
    private var paneReading = false, paneDirty = false
    private var lastPaneRead = Date.distantPast
    /// While output flows, the pane is read often when an agent runs (its spinner, box and questions) and seldom for a shell,
    /// where only an agent starting matters. Nothing is read while the pane is quiet.
    static let agentPaneInterval: TimeInterval = 0.25, shellPaneInterval: TimeInterval = 1

    /// Output arrived in a Nook session: its pane is read again soon, one reading at a time, and once more if output kept coming.
    func paneChanged() {
        guard !isExternal else { return }
        guard !paneReading else { paneDirty = true; return }
        paneReading = true
        let interval = agent == nil ? Self.shellPaneInterval : Self.agentPaneInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.03, interval - Date().timeIntervalSince(lastPaneRead))) { [weak self] in self?.readPane() }
    }

    private func readPane() {
        let backend = backend, record = record, known = paneTTY
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Up to four readings a second while output flows: each one's processes, pipes and text go with it.
            let (tty, processes, text) = autoreleasepool { () -> (String?, [String], String?) in
                let tty = known ?? backend.paneTTY(record)
                let processes = tty.map(Self.foregroundCommands(tty:)) ?? []
                // A shell's screen is the terminal itself: only an agent's is read for the mirror.
                return (tty, processes, TerminalAgent(processes: processes) == nil ? nil : backend.capture(record))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastPaneRead = Date(); self.paneReading = false
                self.applyPane(tty: tty, processes: processes, text: text)
                if self.paneDirty { self.paneDirty = false; self.paneChanged() }
            }
        }
    }

    /// A reading of a Nook session's pane: an agent's screen goes through the same parts as a Terminal tab's; an agent that
    /// quit leaves the terminal on show again.
    func applyPane(tty: String?, processes: [String], text: String?) {
        if paneTTY == nil { paneTTY = tty }
        let foreground = TerminalAgent(processes: processes)
        if let text, foreground != nil { applyScreen(text, foreground: foreground, history: true) }
        else if agent != nil { applyScreen("", foreground: nil, history: true) }
        onPaneRead?()
    }

    /// The commands in the foreground of a terminal device, oldest first, as `TerminalAgent(processes:)` reads them.
    /// The arguments, not the process name: Claude's binary is named after its version ("2.1.289").
    static func foregroundCommands(tty: String) -> [String] {
        guard let list = try? Shell.run("/bin/ps", ["-t", (tty as NSString).lastPathComponent, "-o", "pid=,stat=,args="]).1 else { return [] }
        return foregroundCommands(ps: list)
    }

    /// Rows of `ps -o pid=,stat=,args=`; a "+" in the state marks the foreground process group.
    static func foregroundCommands(ps list: String) -> [String] {
        list.split(separator: "\n").compactMap { row -> (Int, String)? in
            let fields = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]), fields[1].contains("+") else { return nil }
            return (pid, fields[2].trimmingCharacters(in: .whitespaces))
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func noteEffort(in text: String) {
        guard agent == .claude, let reported = ClaudeEffort.reported(in: String(text.suffix(6000))), reported != effort else { return }
        effort = reported
    }

    /// `awaitsFirstMessage` from what the latest readings found; published only when it changes.
    private func noteFirstMessage() {
        let waits = agent == .claude && banner != nil && !recordBegun && !screenBegun && pendingMessage == nil && claudeQueue.isEmpty
            && liveStatus?.working != true
        if awaitsFirstMessage != waits { awaitsFirstMessage = waits }
    }

    func showPending(_ message: String) {
        // /effort and /model never show in the chat (`ClaudeSettingsEcho`): a bubble for them would wait there for nothing.
        if agent == .claude, ClaudeSettingsEcho.isCommand(message) { return }
        pendingBaseline = screenConversation; pendingRecordBaseline = transcriptText
        pendingSince = Date(); pendingMessage = message
    }
    /// The placeholder stays until the message is in the conversation the mirror shows. With Claude's record that is the record:
    /// Claude writes a message there only once it takes it (as a turn of its own or in the middle of one), so a message it holds
    /// while it works stays, as queued, however long the turn lasts. Its grey echo on screen is not an arrival. Without the record,
    /// the echo in the screen's conversation counts. A message that shows up nowhere goes after a while.
    private func settlePending(screen: String, now: Date = Date()) {
        guard let pending = pendingMessage else { return }
        let taken: Bool
        if let record = transcriptText {
            taken = MessageEcho.appears(pending, in: Self.fresh(record, since: pendingRecordBaseline ?? ""))
            if !taken, pendingQueued || liveStatus?.working == true { pendingSince = now; return }
        } else {
            taken = MessageEcho.appears(pending, in: Self.fresh(screen, since: pendingBaseline))
        }
        if taken || now.timeIntervalSince(pendingSince) > 12 { pendingMessage = nil }
    }

    /// The activity tick's look at the message on its way (`AppModel.updateActivity`). Readings only bring a look when something
    /// changed, and an idle Claude changes nothing: without it, a message that never showed up stayed until the next one was sent.
    func settlePendingOnTick(now: Date = Date()) {
        guard pendingMessage != nil else { return }
        settlePending(screen: screenConversation, now: now)
    }
    private static func fresh(_ text: String, since baseline: String) -> String {
        (text as NSString).substring(from: LiveTerminalScrollView.commonPrefix(baseline as NSString, text as NSString))
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
        if view === ownTerminal { view.onData = { [weak self] bytes in
            guard let self else { return }
            for message in self.signalParser.feed(bytes) { self.onSignal?(message) }
            self.paneChanged()
        } }
        applyTheme(view)
    }

    func applyTheme(_ view: ActivityTerminalView? = nil) {
        // Only views that exist: one made later is themed as it is configured.
        for terminalView in view.map({ [$0] }) ?? (Array([ownTerminal].compactMap { $0 }) + mirrors) {
            if terminalView === ownTerminal {
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
        ownTerminal?.terminate()
        mirrors.forEach { $0.terminate() }
        mirrors.removeAll()
    }
    func send(_ draft: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard !sending else { completion(false); return }
        // A walk of Claude's usage panel stops before anything the user sends goes (ClaudeUsageReader.swift).
        userInput(.enter)
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
        // Control characters never travel with a message (`TerminalText`): an Escape would end the paste early, ^C or ^U act on the agent.
        let text = TerminalText.sendable(draft)
        if agent == .claude, MessageAttachments.endsWithAttachments(text) { return deliverToPane(text, completion: completion) }
        // Paste mode keeps multiline text together; Enter is a deliberate user action.
        if terminal.getTerminal().bracketedPasteMode {
            terminal.send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else { terminal.send(txt: text) }
        // An agent that receives Enter together with the paste treats it as part of the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.terminal.send(txt: "\r"); self.sending = false; completion(true)
        }
    }
    /// How a message reaches Claude in this Nook session's pane through `deliverToPane`: tmux's paste and Enter, and its visible
    /// screen. Tests replace them with a fake screen.
    lazy var paneSend: (TerminalAppBridge.DeliveryStep, String) throws -> Void = { [backend, record] step, text in
        switch step {
        case .message: try backend.paste(text, into: record)
        case .enter: try backend.press("Enter", in: record)
        }
    }
    lazy var paneScreen: () -> String? = { [backend, record] in backend.screen(record) }
    var paneTiming = TerminalAppBridge.DeliveryTiming()
    /// Where those deliveries' steps are written (`DeliveryJournal`); tests keep them out of the user's log.
    var paneJournal: (String) -> Void = { DeliveryJournal.append($0) }
    private static let paneDeliveries = DispatchQueue(label: "dev.nook.pane-delivery", qos: .userInitiated)

    /// A message with images for Claude in this Nook session. Claude drops the Return of a paste with images (`ClaudeImagePaste`),
    /// and the old way here (paste, Return 0.35 s later) lost it while Claude still read them: the message stayed in its box while
    /// Nook said it went. It goes like a Terminal tab's instead (`TerminalAppBridge.deliver`): tmux pastes it (bracketed, so Claude
    /// attaches the images), and Enter follows once the box holds it, with the same checks, retries and outcomes. The steps go to
    /// the delivery log like a Terminal tab's.
    private func deliverToPane(_ text: String, completion: @escaping (Bool) -> Void) {
        let send = paneSend, read = paneScreen, timing = paneTiming, journal = paneJournal
        Self.paneDeliveries.async { [weak self] in
            var steps: [String] = []
            let started = Date()
            let result = Result {
                try TerminalAppBridge.deliver(text, agent: .claude, typed: false, withReturn: false, timing: timing, send: { try send($0, text) }, read: read,
                                              trace: { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) })
            }
            if case .failure(let error) = result, !(error is DeliveryError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                journal("Claude (sesión de Nook) · «\(text.prefix(60))»\n  " + steps.joined(separator: "\n  "))
                guard let self else { return }
                self.sending = false
                if case .failure(DeliveryError.joined(let box)) = result { self.joinedBox = box }
                if case .success = result { completion(true) } else { completion(false) }
            }
        }
    }

    /// Claude's grey suggestion (or text typed in its box), offered in Nook's own field.
    var suggestion: String? {
        guard agent == .claude, !sending, let input = agentInput, !input.isEmpty else { return nil }
        return input.replacingOccurrences(of: "\n", with: " ")
    }
    /// Agents in an owned session are known by kind; external tabs by their foreground process.
    var drivesAgent: Bool { agent != nil || record.kind != .shell }
    /// Chooses an option of the agent's dialog with `keys` (arrows, then Enter) in one write, when this is a Terminal tab and they
    /// fit (`TerminalAppBridge.answerAction`): Terminal stays where it is and no Accessibility is needed. False, with nothing sent,
    /// otherwise; a tmux session presses its keys one by one, as before.
    /// The write goes only while the tab still runs the agent in its foreground; otherwise nothing is written and `refused` hears why
    /// (`TerminalAppBridge.answerScript`).
    func choose(_ keys: [TerminalKey], refused: @escaping (TerminalAppBridge.FieldAnswerError) -> Void = { _ in },
                completion: @escaping (KeyDelivery) -> Void) -> Bool {
        guard let tty = externalTTY, let windowID = externalWindowID, let terminalBridge else { return false }
        if let key = keys.first { userInput(key) }
        return terminalBridge.answer(keys, windowID: windowID, tty: tty, refused: refused, completion: completion)
    }

    /// Chooses option `index` of `prompt`, Claude's question with a preview, in this Terminal tab: the tab's screen is read once more,
    /// and the keys counted from it go in one write, unless it no longer shows that question or its notes field has the keyboard
    /// (`TerminalAppBridge.answerPreview`). False, with nothing sent, when this is no Terminal tab.
    func choosePreview(option index: Int, of prompt: AgentPrompt, completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard let tty = externalTTY, let windowID = externalWindowID, let terminalBridge else { return false }
        userInput(.enter)
        terminalBridge.answerPreview(windowID: windowID, tty: tty, agent: agent, option: index, expecting: prompt.signature, completion: completion)
        return true
    }

    /// How an answer reaches a dialog's text field in this Nook session's pane (`answerField`): tmux presses the arrows by name
    /// (it encodes them for the pane's cursor mode), pastes the text (bracketed, as Claude asked) and presses Enter on its own
    /// step, after the screen shows the text. Tests replace it.
    lazy var paneField: (TerminalAppBridge.FieldStep) throws -> Void = { [backend, record] step in
        switch step {
        case .answer(let arrows, let text):
            for key in arrows { try backend.press(key.tmuxName, in: record) }
            try backend.paste(text, into: record)
        case .enter: try backend.press("Enter", in: record)
        }
    }

    /// Writes `text` into option `index` of `prompt`, a text field of the dialog on screen, and sends it
    /// (`TerminalAppBridge.answerField`): the screen is read again first, and nothing goes unless it still shows that dialog.
    /// A Terminal tab gets the arrows, the text and Terminal's Return in one write, with Terminal left where it is; a Nook session
    /// gets them through tmux, its Enter once the field shows the text. Either way the steps go to the delivery log.
    func answerField(option index: Int, of prompt: AgentPrompt, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // The answer is something the user sends: a walk of Claude's usage panel stops first, and the composer waits for it as for
        // a message (`sending`), so a second send can't write it twice.
        userInput(.enter)
        sending = true
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in self?.sending = false; completion(result) }
        let signature = prompt.signature, agent = agent
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            terminalBridge.answerField(windowID: windowID, tty: tty, agent: agent, option: index, expecting: signature, text: text, completion: completion)
            return
        }
        let send = paneField, read = paneScreen, timing = paneTiming, journal = paneJournal
        Self.paneDeliveries.async {
            var steps: [String] = []
            let started = Date()
            let result = Result {
                try TerminalAppBridge.answerField(text, option: index, expecting: signature, agent: agent, withReturn: false, timing: timing, send: send,
                                                  read: read, trace: { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) })
            }
            if case .failure(let error) = result, !(error is TerminalAppBridge.FieldAnswerError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                // The answer's own words stay out of the log: only how long it was.
                journal("\(agent?.title ?? "Terminal") (sesión de Nook) · respuesta en el campo de la pregunta (\(text.count) caracteres)\n  " + steps.joined(separator: "\n  "))
                completion(result)
            }
        }
    }

    /// How an option and its notes reach Claude's question with a preview in this Nook session's pane (`answerNotes`): tmux presses
    /// the arrows by name and "n", pastes the notes (bracketed, as Claude asked) and presses Enter on its own step, once the screen
    /// shows the notes. Tests replace it.
    lazy var paneNotes: (TerminalAppBridge.NotesStep) throws -> Void = { [backend, record] step in
        switch step {
        case .answer(let arrows, let notes):
            for key in arrows { try backend.press(key.tmuxName, in: record) }
            try backend.press("n", in: record)
            try backend.paste(notes, into: record)
        case .enter: try backend.press("Enter", in: record)
        }
    }

    /// Answers option `index` of `prompt`, Claude's question with a preview on screen, with `notes` on it (`TerminalAppBridge.answerNotes`):
    /// the screen is read again first, and nothing goes unless it still shows that question with its notes field closed and empty.
    /// A Terminal tab gets the arrows, "n", the notes and Terminal's Return in one write, with Terminal left where it is; a Nook
    /// session gets them through tmux, its Enter once the notes show. Either way the steps go to the delivery log.
    func answerNotes(option index: Int, of prompt: AgentPrompt, notes: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Something the user sends, like a text field's answer: a walk of Claude's usage panel stops, and the composer waits.
        userInput(.enter)
        sending = true
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in self?.sending = false; completion(result) }
        let signature = prompt.signature, agent = agent
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            terminalBridge.answerNotes(windowID: windowID, tty: tty, agent: agent, option: index, expecting: signature, notes: notes, completion: completion)
            return
        }
        let send = paneNotes, read = paneScreen, timing = paneTiming, journal = paneJournal
        Self.paneDeliveries.async {
            var steps: [String] = []
            let started = Date()
            let result = Result {
                try TerminalAppBridge.answerNotes(notes, option: index, expecting: signature, agent: agent, withReturn: false, timing: timing, send: send,
                                                  read: read, trace: { steps.append(String(format: "%.1fs %@", Date().timeIntervalSince(started), $0)) })
            }
            if case .failure(let error) = result, !(error is TerminalAppBridge.FieldAnswerError) { steps.append("error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                // The notes' own words stay out of the log: only how long they were.
                journal("\(agent?.title ?? "Terminal") (sesión de Nook) · opción \(index + 1) con notas (\(notes.count) caracteres)\n  " + steps.joined(separator: "\n  "))
                completion(result)
            }
        }
    }
    func press(_ key: TerminalKey, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        // Every key pressed on the user's behalf (the island's, an answer's, the model picker's, an interrupt's) stops a walk of
        // Claude's usage panel first; the walk's own keys never come here.
        userInput(key)
        if let tty = externalTTY, let windowID = externalWindowID, let terminalBridge {
            // The agent lets the bridge try the key with Terminal left behind, and check it on the screen (`KeyEffect`).
            terminalBridge.press(key, windowID: windowID, tty: tty, agent: agent, completion: completion)
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
        userInput(.escape)
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
        if source === ownTerminal { isRunning = false }
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
            updateReadDetail()
            if expanded, !oldValue {
                commands.refresh(); alert = nil
                // Opening the island shows the selected tab: its notice has been seen.
                if let selected { markSeen(selected) }
            }
            // A list asked for by the agent pill is no use to an island that closed before showing it.
            if !expanded { agentListRequest = nil }
            // Nothing that only an open island shows outlives it: the quit question is answered "stay" (`NotchController.collapse`
            // already does that; this is the net under it), and a tab drag can't go on.
            if !expanded {
                if quitPrompt != nil { quitPrompt = nil }
                if tabDragInProgress { tabDragInProgress = false }
            }
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
    /// A tab is being dragged along the strip (`moveSession`). It holds the island open like the pin, so a drag that strays past
    /// its edge for a moment doesn't put it away; the island lets go of it once no button is down (`NotchController.trackPointer`),
    /// and a collapsed island has no drag.
    @Published var tabDragInProgress = false
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
    /// How the user has set the cat up: who it is, how much it does, what it looks like and whether it cheers (`PetPreferences`).
    /// Every change is saved; the cats read it on their next frame.
    @Published var pet: PetPreferences {
        didSet {
            guard pet != oldValue else { return }
            pet.save(to: defaults)
        }
    }
    /// Whether the cat is asleep because Nook opened at night, and what wakes it (`PetBedtime`). Awake until the running app puts it to bed (`AppDelegate`): no test or preview
    /// starts asleep.
    let petBedtime = PetBedtime()
    /// How alerts sound, for every tab at once: on or off, the sound of each kind and the volume (`AlertSoundSettings`); each tab
    /// has its own switch too (`TerminalSession.alertSoundOn`). Every change is saved.
    @Published var alertSound: AlertSoundSettings {
        didSet {
            guard alertSound != oldValue else { return }
            alertSound.save(to: defaults)
        }
    }
    /// Plays the alerts' sounds. Silent until the running app installs the Mac's (`AppDelegate`): no test or preview makes a noise.
    var alertSoundPlayer: AlertSoundPlaying = SilentAlertSoundPlayer()
    /// The tabs whose own alert sound is off, by id (`TerminalSession.alertSoundOn`).
    private var mutedTabs: Set<String>
    private var lastAlertSoundAt = Date.distantPast
    /// Nook greeted the user, or the user has started using it (their first tab): the first-run greeting is over for good.
    @Published private(set) var hasBeenWelcomed: Bool
    /// The greeting was asked for again (Ajustes → «Ver la bienvenida otra vez»): the island shows it, tabs or no tabs, until the user closes it. Not saved.
    @Published var greetingReplay = false
    /// The island's question before quitting, while it is up (`shouldTerminate`, `answerQuit`).
    @Published private(set) var quitPrompt: QuitPrompt?
    private var quitPromptSerial = 0
    /// The user said "Salir": the next quit goes through without asking, once.
    private var quitConfirmed = false
    /// How Nook quits once the user said so. Inert until the running app installs `NSApp.terminate` (`AppDelegate`), so a test that
    /// answers the question never ends its own process.
    var terminateApp: () -> Void = {}
    /// How the question is asked when there is no island to ask it in: the running app installs a plain alert (`QuitAlert`); true
    /// quits. Without one, Nook quits at once: there is nobody it could ask.
    var quitFallback: (() -> Bool)?
    /// Where the question is asked: the island (`NotchController` makes itself the host).
    weak var quitPromptHost: QuitPromptHost?
    /// Nook's own order of the tab strip (`TabOrder`). Read from the preferences at launch (`restore`), not here: a model that never
    /// restores (a test, a preview) starts from no order rather than one another model left behind.
    private var tabOrder = TabOrder() {
        didSet { if tabOrder != oldValue { tabOrder.save(to: defaults) } }
    }
    /// The card with those settings is out (a window of its own under the island).
    @Published var settingsOpen = false
    /// The tab the card shows: the island's looks, or the permissions.
    @Published var settingsTab: SettingsTab = .island
    /// What the card's Permisos tab shows and does. Here, and not in the card, so the island can tell that a macOS prompt is
    /// waiting for an answer and the user can be sent back to the tab (`NotchController.permissionsHandOff`).
    let permissions = PermissionsModel()
    let capturePrivacy: CapturePrivacy
    /// Screen vision: Claude sees the screen, in a screenshot attached to each message (the composer's toggle) or with its
    /// `capture_screen` tool. Off until the user turns it on; inert until the app calls `start()`, so tests and previews never
    /// reach Claude's configuration or the running app's socket.
    let screenVision: ScreenVision
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
    /// Watches the folder Nook's status line writes to (NookStatusLine.swift); only the running app has one.
    let statusWatcher: ClaudeStatusWatcher?
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
    /// `screenVision` is for tests and previews, which pass one with a capturer and a registrar of their own.
    init(receivesSignals: Bool = true, defaults: UserDefaults = .standard, screenVision: ScreenVision? = nil) {
        self.defaults = defaults
        capturePrivacy = CapturePrivacy(defaults: defaults)
        self.screenVision = screenVision ?? ScreenVision(defaults: defaults)
        display = DisplaySettings.load(from: defaults)
        pet = PetPreferences.load(from: defaults)
        alertSound = AlertSoundSettings.load(from: defaults)
        mutedTabs = Set(defaults.stringArray(forKey: AlertSoundSettings.Key.mutedTabs) ?? [])
        hasBeenWelcomed = defaults.bool(forKey: Self.welcomedKey)
        signalReceiver = receivesSignals ? ClaudeSignalReceiver() : nil
        statusWatcher = receivesSignals ? ClaudeStatusWatcher() : nil
        if let data = UserDefaults.standard.data(forKey: "tabAppearances") { appearances = (try? JSONDecoder().decode([String: TabAppearance].self, from: data)) ?? [:] }
        terminalBridge.onSnapshot = { [weak self] tabs, scope, requested in self?.updateExternalTabs(tabs, ttys: scope, requestedAt: requested) }
        terminalBridge.onFailure = { [weak self] error in
            self?.notice = error
            self?.sessions.filter(\.isExternal).forEach { $0.isRunning = false }
        }
        // A key that brings Terminal forward gives the keyboard back where it was (`TerminalAppBridge.press`): the island counts
        // as having it when it is the key window, whichever app is in front.
        terminalBridge.currentFocus = { [weak self] in
            NSWorkspace.shared.frontmostApplication.map { KeyFocus(app: $0.processIdentifier, island: self?.controller?.panel.isKeyWindow == true) }
        }
        terminalBridge.returnFocus = { [weak self] focus in self?.controller?.returnKeyboard(focus) }
        // Snapshots update activity as they arrive; this timer only lets recent output fade out.
        let activityTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateActivity() }
        activityTimer.tolerance = 0.3
        RunLoop.main.add(activityTimer, forMode: .common)
        self.activityTimer = activityTimer
        signalReceiver?.onEvent = { [weak self] event in self?.receiveClaude(event) }
        statusWatcher?.onChange = { [weak self] readings in self?.applyStatus(readings) }
        // Watched (and created) only while Nook's status line is on in some folder (NookStatusLine.swift).
        refreshStatusWatcher()
        watchRest()
    }

    /// Why nobody can see the screen right now ("pantallas", "bloqueo", "sesión").
    private(set) var restReasons = Set<String>()
    private var restObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The lock and unlock, heard even while Nook is not the active app (`PetDistributedListener`).
    private var lockListeners: [PetDistributedListener] = []
    func rest(_ reason: String, _ resting: Bool) {
        if resting { restReasons.insert(reason) } else { restReasons.remove(reason) }
        terminalBridge.resting = !restReasons.isEmpty
    }
    deinit { restObservers.forEach { $0.0.removeObserver($0.1) } }
    private func watchRest() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: String, _ change: @escaping (AppModel) -> Void) {
            restObservers.append((center, center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self.map(change) }))
        }
        on(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.rest("pantallas", true) }
        on(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.rest("pantallas", false) }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.rest("sesión", true) }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.rest("sesión", false) }
        // AppKit holds distributed notifications back from an app that is not active unless they are asked for at once, and Nook is
        // almost never the active app: the unlock could wait for the next click into Nook, with Terminal's reading paused until then.
        lockListeners = [PetDistributedListener("com.apple.screenIsLocked") { [weak self] in self?.rest("bloqueo", true) },
                         PetDistributedListener("com.apple.screenIsUnlocked") { [weak self] in self?.rest("bloqueo", false) }]
        // Back from the Mac's own sleep (every process was frozen): read what changed meanwhile.
        on(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.terminalBridge.refresh() }
    }

    func restore() {
        _ = try? Shell.run(backend.executable, backend.arguments() + ["source-file", backend.configuration])
        // Nook saved its tabs before (every launch does, below): whoever ran it knows it, and gets no first-run greeting.
        if UserDefaults.standard.object(forKey: "sessions") != nil { markWelcomed() }
        if let data = UserDefaults.standard.data(forKey: "sessions"), let records = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            let kept = records.filter { record in
                switch backend.presence(record) {
                case .present: return true
                case .gone: tabLog.notice("restore dropped \(record.id, privacy: .public): tmux has no such session"); return false
                case .unknown: tabLog.error("restore kept \(record.id, privacy: .public): tmux could not answer"); return true
                }
            }
            sessions = kept.map { TerminalSession(record: $0, backend: backend, create: false) }
        }
        let launchDate = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.launchDate
        let logins = terminalBridge.loginStampsReader()
        var kept: [TrackedTerminalTab] = []
        if let data = UserDefaults.standard.data(forKey: "trackedTerminalTabs"), let tabs = try? JSONDecoder().decode([TrackedTerminalTab].self, from: data), !tabs.isEmpty {
            if launchDate == UserDefaults.standard.object(forKey: "terminalLaunchDate") as? Date {
                kept = TerminalTabIdentity.sameTabs(tabs, logins: logins, savedAt: Self.preferencesSavedAt())
                if kept.count < tabs.count { tabLog.notice("restore dropped \(tabs.count - kept.count) Terminal tabs: their TTYs belong to newer tabs") }
                terminalBridge.restore(tabs: kept)
            }
            else { tabLog.notice("restore dropped \(tabs.count) Terminal tabs: Terminal was relaunched or is not running") }
        }
        forgetOtherTabs(keeping: kept, logins: logins)
        // The Terminal tabs restored arrive with their first reading, which is never in before this (`TerminalAppBridge.refresh`):
        // they take their saved places then.
        restoreTabState(keeping: kept, logins: logins)
        selectedID = sessions.first?.id
        sessions.forEach(applyAppearance)
        save()
    }
    /// When Nook last wrote its preferences, read before this launch writes any: the last moment it was following its tabs.
    static func preferencesSavedAt() -> Date? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(bundle).plist")
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    /// Names, colours and histories saved for Terminal tabs belong to those tabs alone. Ones saved by the bare TTY (before tabs
    /// had an identity) move to the tab restored on it, the one provably the same; the rest go, together with those of tabs that
    /// closed for good, so none of them can reach a later tab that reuses the TTY.
    private func forgetOtherTabs(keeping restored: [TrackedTerminalTab], logins: [String: String]) {
        let keep = Self.carriedKeys(restored)
        let keptAppearances = TerminalTabIdentity.migrated(appearances, keep: keep, logins: logins)
        if keptAppearances != appearances {
            appearances = keptAppearances
            UserDefaults.standard.set(try? JSONEncoder().encode(appearances), forKey: "tabAppearances")
        }
        let keptHistories = TerminalTabIdentity.migrated(histories, keep: keep, logins: logins)
        if keptHistories != histories {
            histories = keptHistories
            UserDefaults.standard.set(histories, forKey: "sentHistory")
        }
    }
    /// What a Terminal tab saved under its bare TTY (before tabs had an identity) moves to: the full key of the tab restored on
    /// that TTY, the one provably the same.
    private static func carriedKeys(_ restored: [TrackedTerminalTab]) -> [String: String] {
        let prefix = TerminalTabIdentity.terminalPrefix
        var keep: [String: String] = [:]
        for tab in restored { if let login = tab.login { keep[prefix + tab.tty] = prefix + TerminalTabIdentity.key(tty: tab.tty, login: login) } }
        return keep
    }
    /// At launch, what Nook keeps by tab id in its own preferences follows the rules of names and colours (`forgetOtherTabs`): the
    /// strip's order (`TabOrder`), read here, and the tabs whose alert sound is off. Both keep Nook's own tmux sessions only while they
    /// are restored, so neither grows with every session that ever ended. The sessions restored so far take their saved places;
    /// Terminal's tabs take theirs as they arrive (`place`).
    func restoreTabState(keeping restored: [TrackedTerminalTab], logins: [String: String]) {
        let keep = Self.carriedKeys(restored)
        let nookTabs = Set(sessions.filter { !$0.isExternal }.map(\.id))
        var order = TabOrder.load(from: defaults)
        order.migrate(keep: keep, logins: logins, nookTabs: nookTabs)
        tabOrder = order
        let arranged = order.arranged(sessions, id: \.id)
        if arranged.map(\.id) != sessions.map(\.id) { sessions = arranged }
        let muted = TerminalTabIdentity.migrated(Dictionary(uniqueKeysWithValues: mutedTabs.map { ($0, true) }), keep: keep, logins: logins, nookTabs: nookTabs)
        if Set(muted.keys) != mutedTabs { mutedTabs = Set(muted.keys); saveMutedTabs() }
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
    /// `login`: the tab's, when the caller already knows it; otherwise it is read now.
    func connectTerminalTab(_ tab: TerminalTabSnapshot, login: String? = nil) {
        let login = login ?? terminalBridge.loginStampsReader()[tab.tty]
        // The tab Nook knew on this TTY closed, and Terminal gave its TTY to this one: nothing of the old one carries over.
        if let stale = sessions.first(where: { $0.externalTTY == tab.tty }), TerminalTabIdentity.replaced(Self.login(of: stale), by: login) {
            tabLog.notice("\(tab.tty, privacy: .public) now belongs to another tab; \(stale.displayTitle, privacy: .public) closed")
            remember(closed: stale)
            sessions.removeAll { $0 === stale }
        }
        if let existing = sessions.first(where: { $0.externalTTY == tab.tty }) { selectedID = existing.id }
        else {
            let session = TerminalSession(tab: tab, backend: backend, bridge: terminalBridge, login: login)
            applyAppearance(session); place(session); selectedID = session.id
        }
        terminalBridge.connect(tab: tab, login: login)
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
    /// Terminal tabs missing from the latest successful readings, by TTY.
    private var externalMisses: [String: Int] = [:]
    static let missesBeforeClosing = 2

    func updateExternalTabs(_ tabs: [TerminalTabSnapshot], ttys: Set<String>, requestedAt: Date = .distantFuture) {
        // A reading in flight when the user picked another tab still shows the old one selected.
        let stale = requestedAt < selectedAt
        let knownWindows = Set(sessions.filter { ttys.contains($0.externalTTY ?? "") }.compactMap(\.externalWindowID)).union(tabs.map(\.windowID))
        let liveIDs = Set(tabs.map(\.tty))
        let previouslySelectedWindow = selected?.isExternal == true ? selected?.externalWindowID : nil
        var changed = false
        // Each tab's login now: a TTY whose login changed holds a new tab, not the one Nook followed (macOS reuses TTYs).
        let logins = tabs.isEmpty ? [:] : terminalBridge.loginStampsReader()
        var replaced: [TerminalSession] = [], replacedTTYs: [String] = []
        for tab in tabs {
            if let existing = sessions.first(where: { $0.externalTTY == tab.tty }) {
                if TerminalTabIdentity.replaced(Self.login(of: existing), by: logins[tab.tty]) { replaced.append(existing); continue }
                if existing.externalWindowID != tab.windowID { changed = true }   // moved to another window
                existing.shownInWindow = tab.selected
                existing.update(tab)
                if !existing.menu.isEmpty, let agent = existing.agent { commands.learn(existing.menu, agent: agent) }
                // A collapsed island still follows the record for the agents in the notch; the hidden chat waits.
                followTranscript(existing, showingText: tab.history)
            } else {
                // A tab restored from the last launch: it is followed only while its TTY still holds the login it had.
                let tracked = terminalBridge.trackedTabs.first { $0.tty == tab.tty }?.login
                if TerminalTabIdentity.replaced(tracked, by: logins[tab.tty]) { replacedTTYs.append(tab.tty); continue }
                let session = TerminalSession(tab: tab, backend: backend, bridge: terminalBridge, login: tracked ?? logins[tab.tty])
                applyAppearance(session); place(session); changed = true
            }
        }
        // A tab goes only when two readings in a row lack it: one reading that left it out (Terminal in the middle of a change)
        // must not drop it for good.
        for tty in liveIDs { externalMisses[tty] = nil }
        var removed: [TerminalSession] = []
        for session in sessions where session.isExternal && ttys.contains(session.externalTTY!) && !liveIDs.contains(session.externalTTY!) {
            let tty = session.externalTTY!, misses = (externalMisses[tty] ?? 0) + 1
            if misses < Self.missesBeforeClosing {
                externalMisses[tty] = misses
                tabLog.info("Terminal reading lacked \(tty, privacy: .public) once; keeping it")
                continue
            }
            externalMisses[tty] = nil
            removed.append(session)
            tabLog.notice("closed \(tty, privacy: .public) (\(session.displayTitle, privacy: .public)): Terminal no longer has it; asked \(ttys.sorted(), privacy: .public), got \(liveIDs.sorted(), privacy: .public) in windows \(Set(tabs.map(\.windowID)).sorted(), privacy: .public)")
            remember(closed: session)
        }
        for session in replaced {
            tabLog.notice("closed \(session.externalTTY!, privacy: .public) (\(session.displayTitle, privacy: .public)): its TTY now belongs to another tab")
            remember(closed: session)
            removed.append(session)
        }
        for tty in replacedTTYs {
            tabLog.notice("stopped following \(tty, privacy: .public): it now belongs to another tab")
            terminalBridge.disconnect(tty: tty); changed = true
        }
        if !removed.isEmpty { changed = true }
        removed.forEach { terminalBridge.disconnect(tty: $0.externalTTY!) }
        // Only when a tab went: `removeAll` on a published array announces a change even when it removes nothing, and this runs on every
        // snapshot of Terminal (twice a second while the island is open), each one a render of the whole open island.
        if !removed.isEmpty { sessions.removeAll { session in removed.contains { $0 === session } } }
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
        updateReadDetail()
        updateActivity()
    }
    /// Terminal tabs are read whole and twice a second while the island is open, and also while one of them shows a panel of
    /// Claude's, collapsed island or not: the usage panel is kept as read (`ClaudeUsageReader`), so it is read from the moment it
    /// opens, and a scroll in Terminal is seen a screen at a time. Otherwise every two seconds, the visible screen only.
    private func updateReadDetail() {
        let wanted = expanded || sessions.contains { $0.isExternal && $0.panel != nil }
        if terminalBridge.detailed != wanted { terminalBridge.detailed = wanted }
    }
    func disconnectTerminalTab(_ tty: String) {
        terminalBridge.disconnect(tty: tty)
        sessions.removeAll { $0.externalTTY == tty }
        if selected == nil { selectedID = sessions.first?.id }
        save()
    }

    // MARK: Tab order

    /// Every tab that comes into the strip comes through here: one Nook had before (restored at launch, reopened, connected again)
    /// goes back to its place in Nook's order (`TabOrder`), a new one goes at the end. Its first tab means the user has started:
    /// the first-run greeting is over.
    private func place(_ session: TerminalSession) {
        let index = tabOrder.place(session.id, among: sessions.map(\.id))
        sessions.insert(session, at: min(index, sessions.count))
        markWelcomed()
    }

    /// Moves the tab `id` to `index` among `sessions` (its final place there, clamped to the strip), as dragging it along the strip
    /// does; called again as the drag passes each tab, the tabs swap live. The order is Nook's: Terminal's own tabs never move, and
    /// it is kept across launches (`TabOrder`). The selection stays with the same tab. One change, published once; nothing for a
    /// tab already there or not in the strip.
    func moveSession(_ id: String, to index: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), sessions.count - 1)
        guard to != from else { return }
        var reordered = sessions
        reordered.insert(reordered.remove(at: from), at: to)
        sessions = reordered
        tabOrder.follow(reordered.map(\.id), moved: id)
    }

    /// Moves the tab `id` one place or more along the strip (`offset` places; negative is to the left): what VoiceOver's actions on a tab do, which
    /// cannot drag it.
    func moveSession(_ id: String, by offset: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        moveSession(id, to: from + offset)
    }

    // MARK: Recently closed

    /// A tab that left Nook, kept so it can come back: a Terminal tab is followed again, a Nook session (which keeps running
    /// when its tab closes) is reattached. Its name, colour and icon come back with it.
    enum ClosedTab: Equatable {
        /// `login`: the tab's (`TerminalTabIdentity`), so a later tab on the same TTY is never reopened in its place.
        case terminal(tty: String, title: String, login: String? = nil)
        case nook(SessionRecord, title: String)
        var title: String { switch self { case .terminal(_, let title, _), .nook(_, let title): title } }
    }
    /// The login a followed Terminal tab is known by, when Nook knows it.
    static func login(of session: TerminalSession) -> String? { TerminalTabIdentity.login(in: session.record.id) }
    /// Newest first.
    @Published private(set) var recentlyClosed: [ClosedTab] = []
    /// Whether tmux still has a Nook session; tests replace it.
    lazy var tmuxHas: (SessionRecord) -> Bool = { [backend] in backend.exists($0) }
    static let closedLimit = 5

    /// Every way a tab leaves Nook goes through here, just before it goes: it is remembered for reopening, and lets go of what it held
    /// (`TerminalSession.releaseClosed`).
    private func remember(closed session: TerminalSession) {
        let entry: ClosedTab = session.externalTTY.map { .terminal(tty: $0, title: session.displayTitle, login: Self.login(of: session)) } ?? .nook(session.record, title: session.displayTitle)
        recentlyClosed = Array(([entry] + recentlyClosed.filter { $0 != entry }).prefix(Self.closedLimit))
        // After this pass: what the island draws for the tab now is not pulled from under it.
        DispatchQueue.main.async { [weak session] in session?.releaseClosed() }
    }

    func reopenLastClosed() { if let last = recentlyClosed.first { reopen(last) } }

    func reopen(_ closed: ClosedTab) {
        recentlyClosed.removeAll { $0 == closed }
        switch closed {
        case .nook(let record, _):
            if let open = sessions.first(where: { $0.record.id == record.id && $0.record.socket == record.socket }) { select(open); return }
            guard tmuxHas(record) else { notice = "«\(closed.title)» ya terminó; no se puede reabrir."; return }
            let session = TerminalSession(record: record, backend: backend, create: false)
            applyAppearance(session); place(session); select(session); save()
            tabLog.notice("reopened \(record.id, privacy: .public)")
            controller?.expand(focus: true)
        case .terminal(let tty, _, let login):
            if let open = sessions.first(where: { $0.externalTTY == tty && !TerminalTabIdentity.replaced(login, by: Self.login(of: $0)) }) { select(open); return }
            terminalBridge.discover { [weak self] windows in
                guard let self else { return }
                let current = self.terminalBridge.loginStampsReader()[tty]
                // A tab on that TTY with another login is a newer tab that took the TTY: the closed one is gone.
                guard let tab = windows.flatMap(\.tabs).first(where: { $0.tty == tty }), !TerminalTabIdentity.replaced(login, by: current) else {
                    self.notice = "La pestaña de Terminal «\(closed.title)» ya no existe."; return
                }
                tabLog.notice("reopened \(tty, privacy: .public)")
                self.connectTerminalTab(tab, login: login ?? current)
            }
        }
    }
    /// A new terminal is always a tab of Terminal: a new tab of its front window, or a new window when it has none (or when
    /// Nook can't press ⌘T). Nook then follows it like a tab connected by hand; it never hosts a terminal of its own. The tab
    /// opens asynchronously, so nothing is returned; it is selected and named ("Claude Code", "Claude Code 2"…) once open.
    @discardableResult func create(_ kind: SessionKind, directory: String? = nil) -> TerminalSession? {
        let command = NewTerminalCommand.command(kind, directory: directory ?? NSHomeDirectory())
        // Terminal comes forward to take ⌘T; the island stays meanwhile.
        controller?.keepIslandWithTerminal(appPID: TerminalAppBridge.terminalPID)
        terminalBridge.openTab(running: command) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (opened, tab)):
                tabLog.notice("opened \(kind.rawValue, privacy: .public) in \(tab.tty, privacy: .public) (\(String(describing: opened.placement), privacy: .public))")
                self.connectTerminalTab(tab, login: opened.login)
                if let session = self.sessions.first(where: { $0.externalTTY == tab.tty }) {
                    self.customize(session, title: NewTerminalCommand.name(kind, taken: self.sessions.filter { $0 !== session }.map(\.displayTitle)), tint: session.tint)
                }
                if opened.placement == .windowWithoutPermission, !self.defaults.bool(forKey: Self.newTabHintKey) {
                    self.defaults.set(true, forKey: Self.newTabHintKey)
                    self.notice = "Nook abrió la terminal en una ventana nueva. Para que se abra como pestaña de una ventana de Terminal que ya tengas, activa Nook en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad."
                }
            case .failure(let error):
                tabLog.error("could not open \(kind.rawValue, privacy: .public) in Terminal: \(error.localizedDescription, privacy: .public)")
                self.notice = "No se pudo abrir \(kind.title) en Terminal. \(error.localizedDescription)"
            }
        }
        return nil
    }
    /// The one-time word that Accessibility lets new terminals open as tabs was already said.
    static let newTabHintKey = "newTabPermissionHinted"
    func importSession(name: String, socket: String) {
        if let existing = sessions.first(where: { $0.record.id == name && $0.record.socket == socket }) { selectedID = existing.id; connectionSheet = false; return }
        let record = SessionRecord(id: name, name: name, kind: .shell, directory: NSHomeDirectory(), socket: socket, ownsSession: false)
        guard backend.exists(record) else { notice = "Esta sesión ya no está disponible."; return }
        let session = TerminalSession(record: record, backend: backend, create: false)
        applyAppearance(session)
        place(session); selectedID = session.id; save(); connectionSheet = false
        controller?.expand(focus: true)
    }
    func close(_ session: TerminalSession) {
        tabLog.notice("closed \(session.externalTTY ?? session.record.id, privacy: .public) (\(session.displayTitle, privacy: .public)) by the user")
        remember(closed: session)
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
            capturePrivacy.prepare(alert.window)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            backend.close(session.record)
        }
        close(session)
    }

    /// Without an icon, the tab keeps the one it has.
    func customize(_ session: TerminalSession, title: String, tint: TabTint, icon: TabIcon? = nil) {
        session.customTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        session.tint = tint
        if let icon { session.icon = icon }
        appearances[session.id] = TabAppearance(title: session.customTitle, tint: tint, icon: session.icon)
        UserDefaults.standard.set(try? JSONEncoder().encode(appearances), forKey: "tabAppearances")
    }
    /// The effort control: Claude's own command with the level, sent like a message, so its slider never opens.
    func setEffort(_ effort: ClaudeEffort, on session: TerminalSession) {
        guard session.agent == .claude, session.isRunning else { return }
        session.send(effort.command)
    }

    // MARK: Models

    /// The models a tab can switch to: Claude Code's own list on disk, else the picker rows Nook has seen; the button reads them.
    lazy var models = ClaudeModelStore(defaults: defaults)
    /// A model asked for on the button that needs Claude's picker, until that tab's picker comes up.
    private var pendingModel: [String: (choice: ClaudeModelChoice, scope: ClaudeModelScope, until: Date)] = [:]

    /// What the model button offers for a tab, in the order of Claude's picker, with the tab's current model marked.
    func availableModels(for session: TerminalSession) -> [ClaudeModelChoice] {
        models.choices(folder: session.claudeFolder, version: session.banner?.version, current: session.currentModel, live: session.prompt)
    }
    /// Rows of Claude's picker missing from `availableModels`: 0 when Claude Code's list is on disk, nil when unknown. The
    /// button can say the list is incomplete and offer `openModelPicker`.
    func missingModels(for session: TerminalSession) -> Int? { models.missingRows(folder: session.claudeFolder) }
    /// The list may lack a model Anthropic shipped since (see `ClaudeModelStore.isStale`).
    func modelListIsStale(for session: TerminalSession) -> Bool {
        models.isStale(folder: session.claudeFolder, version: session.banner?.version)
    }
    /// Why the model can't be changed from Nook right now, worded for the button's help; nil when it can. A /model sent while
    /// Claude works would wait in its queue and switch models in the middle of the turn, so the button waits for the turn.
    func modelSwitchBlocked(on session: TerminalSession) -> String? {
        guard session.agent == .claude, session.isRunning else { return "Claude no está abierto en esta pestaña." }
        if session.sending { return "Enviando un mensaje…" }
        if let status = session.agentStatus, status.working, status.background == nil { return "Claude está trabajando; podrás cambiar el modelo cuando termine." }
        if let prompt = session.prompt, !ClaudeModelStore.isModelPicker(prompt) { return "Claude espera una respuesta en la pestaña." }
        if session.panel != nil { return "Cierra antes el panel de Claude." }
        return nil
    }
    /// Switches the tab's model, as Claude's picker would. As the default for new sessions (Enter in the picker), a model with an
    /// argument goes as `/model <id or alias>`, a message like any other: no keys, no Accessibility. For this session only ("s"
    /// in the picker), or a row without an argument, Nook opens Claude's picker (or uses the open one), moves to the row with
    /// the arrows and presses "s" or Enter, which in a Terminal tab needs Accessibility like any key. The banner's model follows
    /// Claude's answer ("Set model to …"), and the answer stays out of the chat (`ClaudeSettingsEcho`).
    func setModel(_ choice: ClaudeModelChoice, on session: TerminalSession, scope: ClaudeModelScope = .default) {
        guard modelSwitchBlocked(on: session) == nil, !session.answering else { return }
        if let live = session.prompt, ClaudeModelStore.isModelPicker(live) { return pick(choice, in: live, on: session, scope: scope) }
        // Only an argument that is one plain word is typed; any other goes through the picker, by its row.
        if scope == .default, let argument = choice.argument, ClaudeModelStore.isSafeArgument(argument) { command("/model " + argument, on: session); return }
        pendingModel[session.id] = (choice, scope, Date().addingTimeInterval(8))
        command("/model", on: session)
    }
    /// Opens Claude's own picker; its rows fill in the list when Claude Code's own isn't on disk.
    func openModelPicker(on session: TerminalSession) {
        guard modelSwitchBlocked(on: session) == nil, !(session.prompt.map(ClaudeModelStore.isModelPicker) ?? false) else { return }
        command("/model", on: session)
    }
    /// Where the model button's commands go instead of the tab; only tests set it, so a command never reaches a real terminal.
    var commandSender: ((String, TerminalSession) -> Void)?
    private func command(_ text: String, on session: TerminalSession) {
        if let commandSender { commandSender(text, session) } else { session.send(text) }
    }
    /// The keys that take the open picker from its highlighted row to the choice's row and apply it there. The row is found by
    /// its label on screen, else by its number in the list (the picker scrolls: rows below its view are reached by moving on).
    static func pickerKeys(for choice: ClaudeModelChoice, in picker: AgentPrompt, scope: ClaudeModelScope) -> [TerminalKey]? {
        let rows = picker.options.enumerated().map { ($1.number ?? $0 + 1, $1.title) }
        guard let target = rows.first(where: { $0.1 == choice.label })?.0 ?? choice.row, picker.options.indices.contains(picker.highlighted) else { return nil }
        let from = picker.options[picker.highlighted].number ?? picker.highlighted + 1
        let moves = Array(repeating: target > from ? TerminalKey.down : .up, count: abs(target - from))
        return moves + [scope == .sessionOnly ? .keyS : .enter]
    }
    private func pick(_ choice: ClaudeModelChoice, in picker: AgentPrompt, on session: TerminalSession, scope: ClaudeModelScope) {
        // A picker whose hint names its keys and has no "s" can't apply a model to this session only.
        if scope == .sessionOnly, !picker.actions.isEmpty, !picker.actions.contains(where: { $0.key == "s" }) {
            notice = "Este Claude no permite usar un modelo solo en esta sesión; elígelo como predeterminado."
            return
        }
        guard let keys = Self.pickerKeys(for: choice, in: picker, scope: scope) else {
            notice = "El selector de Claude no muestra «\(choice.label)»; elígelo en él."
            return
        }
        pressInPicker(keys, on: session)
    }
    /// One key after the other while the tab still shows the picker; anything else on screen stops them.
    private func pressInPicker(_ keys: [TerminalKey], on session: TerminalSession) {
        guard let key = keys.first else { return }
        guard session.prompt.map(ClaudeModelStore.isModelPicker) == true else {
            notice = "El selector de modelos de Claude se cerró antes de terminar; no envié el resto de las teclas."
            return
        }
        session.press(key) { [weak self, weak session] result in
            guard let self, let session else { return }
            self.handle(result, for: session, key: key)
            if result == .sent { self.pressInPicker(Array(keys.dropFirst()), on: session) }
        }
    }
    /// A tab's screen shows Claude's /model picker (`TerminalSession.onModelPicker`): its rows are learned, and a model the
    /// button asked for is picked in it.
    func modelPickerShown(_ picker: AgentPrompt, on session: TerminalSession) {
        models.learn(picker, version: session.banner?.version, folder: session.claudeFolder)
        guard let pending = pendingModel.removeValue(forKey: session.id), pending.until > Date() else { return }
        pick(pending.choice, in: picker, on: session, scope: pending.scope)
    }
    /// Claude's usage panel (/usage), which Nook then shows as it shows any of Claude's panels.
    /// The usage button. With Claude's status line on, Nook has the limits itself: its own card opens, nothing is typed in the
    /// terminal and closing it never reaches there. Without it, Claude's /usage panel opens in the terminal and the island shows it.
    func openUsage(on session: TerminalSession) {
        guard session.agent == .claude, session.isRunning else { return }
        guard session.liveUsage?.upToDate(at: Date()) != nil else { return session.send("/usage") }
        // A /usage opened since in another tab of the same account may have left Claude a newer reading.
        refreshUsageSnapshots()
        session.usageCardOpen = true
    }
    func closeUsageCard(on session: TerminalSession) {
        if session.usageCardOpen { session.usageCardOpen = false }
    }
    /// Claude's full /usage panel from Nook's card (what only it shows: the tokens by model, what feeds the limits), read fresh.
    func openClaudeUsage(on session: TerminalSession) {
        guard session.agent == .claude, session.isRunning else { return }
        session.usageCardOpen = false
        session.send("/usage")
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
        if let appearance = appearances[session.id] { session.customTitle = appearance.title; session.tint = appearance.tint; session.icon = appearance.icon }
        let soundOn = !mutedTabs.contains(session.id)
        if session.alertSoundOn != soundOn { session.alertSoundOn = soundOn }
        session.onSignal = { [weak self, weak session] message in if let session { self?.receiveNotice(for: session, message: message) } }
        session.onAlert = { [weak self, weak session] kind, message in if let session { self?.raiseAlert(kind, for: session, message: message) } }
        session.onCompletion = { [weak self, weak session] in if let session { self?.noteCompletion(for: session) } }
        session.onModelPicker = { [weak self, weak session] picker in if let session { self?.modelPickerShown(picker, on: session) } }
        session.onPaneRead = { [weak self, weak session] in
            guard let self, let session, let agent = session.agent else { return }
            if !session.menu.isEmpty { self.commands.learn(session.menu, agent: agent) }
            // Like a Terminal tab: a collapsed island follows the record for the notch's agents; the hidden chat waits.
            self.followTranscript(session, showingText: self.islandContentVisible)
        }
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
        followShownShell()
        for session in sessions where session.pendingMessage != nil { session.settlePendingOnTick() }
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

    /// Chooses option `index` of `prompt` with the keys that reach it: a click is the only trigger, and the keys are computed
    /// from the highlight on screen right now, never from what the card showed a moment ago. Nothing is sent when the screen
    /// no longer shows that same prompt. A Terminal tab gets the arrows and Enter in one write, with nothing brought forward
    /// (`TerminalSession.choose`); otherwise (tmux) they are pressed one after another, and a failure stops the sequence.
    ///
    /// A text field ("Type something.") takes no key here: its arrows go with the answer's text (`answer(_:option:text:on:)`),
    /// since arrows alone in a Terminal tab are key events that bring Terminal forward. The field is remembered as the target of
    /// the next message from Nook's composer (`fieldAnswer(for:)`), and the result is `.sent`: the card's part is done.
    ///
    /// Refused, with nothing sent and the model's notice saying why, while Claude's notes field has the terminal's keyboard
    /// (`AgentPrompt.notesFocused`): the arrows would move its cursor and Enter would answer the option Claude has highlighted. Notes
    /// held with the field closed don't stop it: Enter answers the option and Claude sends them with it. The check is made on a
    /// reading taken right before the keys: a Nook session's pane, and a Terminal tab's screen for that question (`answerPreview`).
    func answer(_ prompt: AgentPrompt, option index: Int, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        guard session.isRunning, let live = session.prompt, live.signature == prompt.signature else { completion(.failed); return }
        if refusesNotesField(live, on: session) { completion(.failed); return }
        // A field Nook already wrote into, still on screen (`TerminalSession.filledField`), is an option like any other: Enter on
        // it toggles its box.
        if live.options.indices.contains(index), live.options[index].input == .inline, !session.isFilledField(index, of: live) {
            session.chooseField(index, of: live)
            completion(.sent)
            return
        }
        // A Nook session's highlight is read again from its pane right before the arrows go: Nook's own walk of Claude's usage
        // panel may have moved it since the last reading (the walk stops at a dialog, a few keys late at most). Nook never presses
        // keys in a Terminal tab on its own, and reading its screen takes a script: there the last reading stands, except in Claude's
        // question with a preview, whose notes field the user may have opened at the terminal since (`answerPreview`).
        if session.isExternal, live.takesNotes { return answerPreview(live, option: index, on: session, completion: completion) }
        guard !session.isExternal else { return deliverAnswer(live, option: index, on: session, completion: completion) }
        // Quiet while the pane is read: a second click must not send the keys twice.
        guard session.beginAnswer() else { completion(.failed); return }
        session.promptOnScreen { [weak self, weak session] current in
            guard let self, let session else { return }
            session.finishAnswer(delivered: false)
            guard let current, current.signature == live.signature else {
                self.notice = "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal."
                completion(.failed)
                return
            }
            self.deliverAnswer(current, option: index, on: session, completion: completion)
        }
    }

    /// Answers option `index` of `prompt`, a text field ("Type something."), with `text`: the highlight moves to it, the text goes
    /// into it and Enter sends it, as one write in a Terminal tab (no Accessibility, Terminal left where it is) or through tmux in
    /// a Nook session (`TerminalSession.answerField`). Like a choice, it is refused with nothing sent when the screen no longer
    /// shows that prompt, and the card stays quiet while it goes (`beginAnswer`). The screen is read again right before writing
    /// and after: the result is `.sent` only once the dialog took the answer (or, in a question with several answers, the box
    /// shows ticked with it). Line breaks become spaces and control characters go (`TerminalAppBridge.fieldText`); an empty
    /// answer is refused, since Enter on an empty field cancels Claude's question.
    func answer(_ prompt: AgentPrompt, option index: Int, text: String, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        let answer = TerminalAppBridge.fieldText(text)
        guard !answer.isEmpty, session.isRunning else { completion(.failed); return }
        guard answer.count <= Self.answerLimit else {
            notice = "Tu respuesta es demasiado larga (más de \(Self.answerLimit) caracteres); acórtala y vuelve a enviarla. No envié nada."
            completion(.failed)
            return
        }
        // A message on its way would interleave with the answer's write.
        guard !session.sending else {
            notice = "Todavía se está enviando un mensaje a la terminal; espera a que llegue y vuelve a enviar tu respuesta."
            completion(.failed)
            return
        }
        guard let live = session.prompt, live.signature == prompt.signature, live.options.indices.contains(index), live.options[index].input == .inline else {
            notice = "La pregunta cambió antes de que enviara tu respuesta; no envié nada. Revisa la terminal."
            completion(.failed)
            return
        }
        guard !session.isFilledField(index, of: live) else {
            notice = "Ese campo ya tiene tu respuesta y su casilla marcada; para cambiarla, edítala en la terminal."
            completion(.failed)
            return
        }
        // Quiet while it goes: a second send must not write the answer twice.
        guard session.beginAnswer() else { completion(.failed); return }
        let name = session.agent?.title ?? "la IA", subject = session.agent?.title ?? "La IA", external = session.isExternal
        session.answerField(option: index, of: live, text: answer) { [weak self, weak session] result in
            let delivered: Bool
            if case .success = result { delivered = true } else { delivered = false }
            session?.finishAnswer(delivered: delivered)
            if delivered {
                session?.forgetChosenField()
                // A question with several answers keeps its dialog, the answer in the field.
                if live.multiSelect { session?.noteFilledField(index, of: live) }
            }
            if case .failure(let error) = result, let self {
                switch error as? TerminalAppBridge.FieldAnswerError {
                case .changed?: self.notice = "La pregunta cambió antes de que enviara tu respuesta; no envié nada. Revisa la terminal."
                case .unread?: self.notice = "No pude leer la pestaña para comprobar la pregunta; no envié tu respuesta."
                case .unseen?:
                    // In a Terminal tab the write carried Terminal's own Return; Nook added none.
                    self.notice = external
                        ? "Tu respuesta no apareció en el campo de \(name) y la pregunta sigue abierta. Revisa la terminal antes de enviarla de nuevo."
                        : "Tu respuesta no apareció en el campo de \(name); no pulsé Enter. Revisa la terminal."
                case .stuck?: self.notice = "Tu respuesta quedó escrita en el campo de \(name) sin enviarse. Revisa la terminal."
                case .declined?: self.notice = "\(subject) cerró la pregunta sin tu respuesta (la dio por no respondida). Tu texto vuelve a la caja; revisa la terminal."
                case .otherAnswer?: self.notice = "\(subject) respondió la pregunta con otra opción, no con tu texto. Tu texto vuelve a la caja; revisa la terminal."
                case .unconfirmed?: self.notice = "La pregunta se cerró, pero \(name) no muestra tu respuesta en su conversación. Tu texto vuelve a la caja; revisa la terminal antes de enviarlo de nuevo."
                // Only an answer with notes checks the notes field; a text field's question has none.
                case .notesFieldOpen?: self.notice = Self.notesFieldNotice(agent: session?.agent)
                case .agentGone?: self.notice = Self.agentGoneNotice(agent: session?.agent)
                case .empty?: break
                // A failed script already explained itself through `notice`; tmux failures have no other voice.
                case nil: if self.notice == nil { self.notice = "No pude enviar tu respuesta a la terminal. Revisa la pestaña original." }
                }
            }
            completion(delivered ? .sent : .failed)
        }
    }

    /// Answers option `index` of `prompt`, Claude's question with a preview (`AgentPrompt.takesNotes`), with `notes` for Claude: the
    /// highlight moves to the option, "n" opens the notes field, the notes go in and Enter answers, as one write in a Terminal tab
    /// (no Accessibility, Terminal left where it is) or through tmux in a Nook session (`TerminalSession.answerNotes`). Claude sends
    /// the option with its preview and the notes; with several questions it moves on to the next tab, the notes kept for the end.
    /// Like a choice it is refused, with nothing sent, when the screen no longer shows that question, and the card stays quiet
    /// while it goes. Also refused when the question already holds notes or has its notes field open in the terminal, empty or not
    /// (`AgentPrompt.notesFocused`): what Nook writes would land inside them, the "n" typed into an open field. The bridge checks a
    /// reading taken right before the write again (`TerminalAppBridge.answerNotes`). The result is `.sent` once Claude took the option
    /// (its record, its review step, its next tab). Line breaks become spaces and control characters go (`TerminalAppBridge.fieldText`);
    /// without notes, choose the option with `answer(_:option:on:)`.
    func answer(_ prompt: AgentPrompt, option index: Int, notes: String, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void = { _ in }) {
        let written = TerminalAppBridge.fieldText(notes)
        guard !written.isEmpty, session.isRunning else { completion(.failed); return }
        guard written.count <= Self.answerLimit else {
            notice = "Tus notas son demasiado largas (más de \(Self.answerLimit) caracteres); acórtalas y vuelve a intentarlo. No envié nada."
            completion(.failed)
            return
        }
        guard !session.sending else {
            notice = "Todavía se está enviando un mensaje a la terminal; espera a que llegue y vuelve a enviar tu respuesta."
            completion(.failed)
            return
        }
        guard let live = session.prompt, live.signature == prompt.signature, live.notesArrows(to: index) != nil else {
            notice = "La pregunta cambió antes de que enviara tu respuesta; no envié nada. Revisa la terminal."
            completion(.failed)
            return
        }
        if refusesNotesField(live, on: session) { completion(.failed); return }
        guard live.notes == nil else {
            notice = "Esa pregunta ya tiene notas a medio escribir en la terminal; termínalas allí o bórralas y vuelve a intentarlo."
            completion(.failed)
            return
        }
        // Quiet while it goes: a second send must not write the notes twice.
        guard session.beginAnswer() else { completion(.failed); return }
        let name = session.agent?.title ?? "la IA", subject = session.agent?.title ?? "La IA", external = session.isExternal
        session.answerNotes(option: index, of: live, notes: written) { [weak self, weak session] result in
            let delivered: Bool
            if case .success = result { delivered = true } else { delivered = false }
            session?.finishAnswer(delivered: delivered)
            if case .failure(let error) = result, let self {
                switch error as? TerminalAppBridge.FieldAnswerError {
                case .changed?: self.notice = "La pregunta cambió antes de que enviara tu respuesta; no envié nada. Revisa la terminal."
                case .unread?: self.notice = "No pude leer la pestaña para comprobar la pregunta; no envié tu respuesta."
                case .unseen?:
                    // In a Terminal tab the write carried Terminal's own Return; Nook added none.
                    self.notice = external
                        ? "Tus notas no aparecieron en la pregunta de \(name) y sigue abierta. Revisa la terminal antes de enviarlas de nuevo."
                        : "Tus notas no aparecieron en la pregunta de \(name); no pulsé Enter. Revisa la terminal."
                case .stuck?: self.notice = "Tus notas quedaron escritas en la pregunta de \(name) sin responderla. Revisa la terminal."
                case .declined?: self.notice = "\(subject) cerró la pregunta sin tu respuesta (la dio por no respondida). Revisa la terminal."
                case .otherAnswer?: self.notice = "\(subject) respondió la pregunta con otra opción, no con la que elegiste. Revisa la terminal."
                case .unconfirmed?: self.notice = "La pregunta se cerró, pero \(name) no muestra tu respuesta en su conversación. Revisa la terminal antes de enviarla de nuevo."
                // The reading right before the write found the field open: the user opened it in the terminal since the card's reading.
                case .notesFieldOpen?: self.notice = Self.notesFieldNotice(agent: session?.agent)
                case .agentGone?: self.notice = Self.agentGoneNotice(agent: session?.agent)
                case .empty?: break
                // A failed script already explained itself through `notice`; tmux failures have no other voice.
                case nil: if self.notice == nil { self.notice = "No pude enviar tu respuesta a la terminal. Revisa la pestaña original." }
                }
            }
            completion(delivered ? .sent : .failed)
        }
    }

    /// The text field a message from Nook's composer answers instead of going to the agent's box: the one chosen on the card
    /// (`answer(_:option:on:)` with a `.inline` option, which pressed nothing), or else the highlighted option when it is one (the
    /// user moved there at the terminal; what Claude would get typed is its answer). Nil when the dialog on screen has no such
    /// field, or there is none: the message goes the usual way (`TerminalSession.send`).
    func fieldAnswer(for session: TerminalSession) -> (prompt: AgentPrompt, option: Int)? {
        guard session.isRunning, let prompt = session.prompt else { return nil }
        // A field Nook already filled, still on screen with its text, would get the next answer after that text.
        func isField(_ index: Int) -> Bool {
            prompt.options.indices.contains(index) && prompt.options[index].input == .inline && !session.isFilledField(index, of: prompt)
        }
        if let chosen = session.chosenField, chosen.signature == prompt.signature, isField(chosen.option) { return (prompt, chosen.option) }
        return isField(prompt.highlighted) ? (prompt, prompt.highlighted) : nil
    }

    /// A message from Nook's composer, sent as the answer to the dialog's text field when there is one (`fieldAnswer(for:)`,
    /// `answer(_:option:text:on:)`). False, with nothing sent and `completion` never called, when there is none: the message
    /// goes the usual way. `completion` says whether the answer went; when it didn't, the composer should get the text back.
    @discardableResult func sendToField(_ text: String, on session: TerminalSession, completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard let target = fieldAnswer(for: session) else { return false }
        answer(target.prompt, option: target.option, text: text, on: session) { completion($0 == .sent) }
        return true
    }

    /// What the model says when Claude's notes field has the terminal's keyboard and a choice or notes from the card would land in it.
    static func notesFieldNotice(agent: TerminalAgent?) -> String {
        "El campo de notas de \(agent?.title ?? "la IA") está abierto en la terminal: ciérralo allí con Esc, o termina allí tu respuesta. No envié nada."
    }

    /// What the model says when an answer's write found the tab without the agent in its foreground (`TerminalAppBridge.answerScript`):
    /// the agent quit, and its keys would have gone to the shell.
    static func agentGoneNotice(agent: TerminalAgent?) -> String {
        "\(agent?.title ?? "La IA") ya no está en marcha en esa pestaña, así que no envié lo que faltaba de tu respuesta. Revisa la terminal."
    }

    /// The longest answer to a question's text field, or notes on an option, that Nook sends (characters, once cleaned): longer is
    /// refused before anything goes, and the card keeps the text.
    static let answerLimit = 4_000

    /// True, with the model's notice saying why, when `live` is Claude's question with a preview whose notes field has the terminal's
    /// keyboard (`AgentPrompt.notesFocused`): an option's arrows and Enter, or the "n" and the notes of an answer with notes, would
    /// land in it. The caller then sends nothing.
    private func refusesNotesField(_ live: AgentPrompt, on session: TerminalSession) -> Bool {
        guard live.takesNotes, live.notesFocused || live.notesOpen else { return false }
        notice = Self.notesFieldNotice(agent: session.agent)
        return true
    }

    /// A choice in Claude's question with a preview in a Terminal tab (`TerminalSession.choosePreview`): one more reading of the tab
    /// right before, and the keys counted from it in one write, with nothing brought forward. Refused, with nothing sent and the
    /// model's notice saying why, when that reading shows another question or the notes field with the keyboard. The card stays
    /// quiet meanwhile, so a second click can't send the keys twice.
    private func answerPreview(_ live: AgentPrompt, option index: Int, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void) {
        guard session.beginAnswer() else { completion(.failed); return }
        let started = session.choosePreview(option: index, of: live) { [weak self, weak session] result in
            let delivered: Bool
            if case .success = result { delivered = true } else { delivered = false }
            session?.finishAnswer(delivered: delivered)
            if case .failure(let error) = result, let self {
                switch error as? TerminalAppBridge.FieldAnswerError {
                case .notesFieldOpen?: self.notice = Self.notesFieldNotice(agent: session?.agent)
                case .agentGone?: self.notice = Self.agentGoneNotice(agent: session?.agent)
                case .unread?: self.notice = "No pude leer la pestaña para comprobar la pregunta; no envié ninguna tecla."
                case .changed?: self.notice = "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal."
                // A failed script already explained itself through `notice`.
                default: if self.notice == nil { self.notice = "No pude enviar la respuesta a la terminal. Revisa la pestaña original." }
                }
            }
            completion(delivered ? .sent : .failed)
        }
        guard started else { session.finishAnswer(delivered: false); completion(.failed); return }
    }

    /// The keys from `live`'s highlight to option `index`, delivered as `answer` describes.
    private func deliverAnswer(_ live: AgentPrompt, option index: Int, on session: TerminalSession, completion: @escaping (KeyDelivery) -> Void) {
        // The reading the keys are counted from (a Nook session's is fresh from its pane) is checked too.
        if refusesNotesField(live, on: session) { completion(.failed); return }
        // A text field comes here only once Nook filled it: then Enter toggles its box. Never Enter on an empty one, which cancels
        // Claude's question.
        let field = live.options.indices.contains(index) && live.options[index].input == .inline
        guard !field || session.isFilledField(index, of: live) else { completion(.failed); return }
        let keys = field ? live.arrows(to: index) + [.enter] : live.keys(choosing: index)
        // Only an option that isn't there has no key.
        guard !keys.isEmpty else { completion(.sent); return }
        guard session.beginAnswer() else { completion(.failed); return }
        let finished: (KeyDelivery) -> Void = { [weak self, weak session] result in
            guard let session else { return }
            session.finishAnswer(delivered: result == .sent)
            // A failed script already explained itself through `notice`; tmux failures have no other voice.
            if result == .failed, self?.notice == nil { self?.notice = "No pude enviar la respuesta a la terminal. Revisa la pestaña original." }
            completion(result)
        }
        let refused: (TerminalAppBridge.FieldAnswerError) -> Void = { [weak self, weak session] error in
            self?.notice = error == .agentGone ? Self.agentGoneNotice(agent: session?.agent)
                : "La pregunta cambió antes de que respondiera; no envié ninguna tecla. Revisa la terminal."
        }
        if session.choose(keys, refused: refused, completion: finished) { return }
        pressSequence(keys, on: session, whileShowing: live.signature, completion: finished)
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
    /// alert, with its sound when the user has them on (`playAlertSound`). Nothing for the tab already
    /// open in front of the user; the same kind again within a few seconds (a hook and the screen
    /// telling the same thing) only updates the notice.
    func raiseAlert(_ kind: NookAlert.Kind, for session: TerminalSession, message: String, now: Date = Date()) {
        // Like Claude's own bell: nothing for the tab the user is looking at. Its turn is over all the same, so a hook's
        // "working" must not outlive it (the notch would stay busy).
        if inFront(session) {
            if session.taskState == .working { session.taskState = .idle; updateActivity() }
            return
        }
        // A question or an error says more than a plain "finished", which never replaces them.
        if kind != .finished || session.unreadNotice == nil { session.unreadNotice = String(message.prefix(180)) }
        if kind != .finished || session.taskState != .attention { session.taskState = kind == .finished ? .finished : .attention }
        defer { updateActivity() }
        if let last = lastAlerts[session.id], last.kind == kind, now.timeIntervalSince(last.at) < 10 { return }
        lastAlerts[session.id] = (kind, now)
        alertSerial += 1
        alert = NookAlert(id: alertSerial, sessionID: session.id, kind: kind, title: session.displayTitle, message: String(message.prefix(180)))
        playAlertSound(kind, for: session, now: now)
    }
    /// Where the keys pressed on a tab's behalf go instead of the terminal; only tests set it, so a key never reaches a real one.
    var keySender: ((TerminalKey, TerminalSession) -> Void)?
    func press(_ key: TerminalKey, on session: TerminalSession) {
        if key == .escape, session.panel != nil { session.panelEscapedAt = Date() }
        // A walk of Claude's usage panel stops before the user's key goes (`ClaudeUsageWalk.cancel`).
        if session.panel != nil { session.usageReader.userPressed(key) }
        if let keySender { keySender(key, session); return }
        session.press(key) { [weak self] result in self?.handle(result, for: session, key: key) }
    }
    /// "más" on Claude's panel: Claude's usage panel scrolls about a screen (`ClaudeUsageReader.scrollStep`) in one burst of ↓ or ↑,
    /// any other panel one key. A Terminal tab gets the burst through Accessibility with Terminal brought forward once and the
    /// keyboard given back once; a Nook session through tmux. The page it lands on is laid into the panel read so far, so the card
    /// grows. The user is scrolling: a walk of the panel stops and none starts. A press before the last one's page was read waits.
    func scrollPanel(down: Bool, on session: TerminalSession) {
        guard session.isRunning, session.panel != nil, session.usageReader.mayScroll() else { return }
        let key: TerminalKey = down ? .down : .up
        let count = session.usageReader.scrollStep
        session.usageReader.userPressed(key)
        session.usageReader.scrolled()
        if let keySender { for _ in 0..<count { keySender(key, session) }; return }
        session.press(key, count: count) { [weak self] result in self?.handle(result, for: session, key: key) }
    }

    /// Esc, with a panel of Claude's open in the selected tab: it closes the panel (Claude does the closing). False when there is
    /// none, so the key keeps its other meanings (an agent's conversation going back, the island going away).
    @discardableResult func dismissPanel() -> Bool {
        guard let session = selected, session.isRunning, session.panel != nil else { return false }
        press(.escape, on: session)
        return true
    }
    func interrupt(_ session: TerminalSession) {
        session.interrupt { [weak self] result in self?.handle(result, for: session, key: .escape) }
    }
    /// ⇧⇥ in a tab running Claude: Claude moves to its next permission mode (default → accept edits → plan → auto…), and
    /// `agentMode` follows from the reading that comes right after the key. Like any key but Enter, a Terminal tab needs
    /// Accessibility for it.
    func cycleMode(on session: TerminalSession) {
        guard session.agent == .claude, session.isRunning else { return }
        press(.backtab, on: session)
    }
    private func handle(_ result: KeyDelivery, for session: TerminalSession, key: TerminalKey) {
        switch result {
        case .sent:
            // The original tab may have come forward to receive the key; the island stays with it until the keyboard goes back
            // (`TerminalAppBridge.press`). A key that went with Terminal left behind changes nothing here.
            if session.isExternal && key.needsDirectKeys { controller?.keepIslandWithTerminal(appPID: TerminalAppBridge.terminalPID) }
        case .needsPermission: requestDirectKeys()
        case .failed: break
        }
    }
    /// Pastes the clipboard's image into the agent. Wherever Nook shows the agent's conversation (a Terminal tab, or a Nook
    /// session with an agent in it) the image goes with Nook's own message: it is saved as a file and attached, and the agent
    /// opens it when the message arrives. ⌃V would put it in the agent's own box instead, out of sight (and a Terminal tab
    /// would have to come to the front for the key). Only a Nook session showing its raw terminal gets ⌃V, through tmux.
    func pasteImage(into session: TerminalSession, attachPath: @escaping (String) -> Void) {
        guard NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) else { notice = "No hay ninguna imagen en el portapapeles."; return }
        guard session.drivesAgent else { notice = "Pegar imágenes funciona en pestañas con Claude o Codex."; return }
        if session.mirrorsAgent {
            // Images still attached to a message survive the pruning that comes with a new one.
            let attached = MainActor.assumeIsolated { MessageAttachments.shared.attachedPaths }
            guard let path = Self.saveImage(from: .general, keeping: attached) else { notice = "No se pudo guardar la imagen del portapapeles."; return }
            attachPath(path)
            notice = "Añadí la imagen al mensaje como archivo; \(session.agent?.title ?? "la IA") la abrirá cuando lo reciba."
            return
        }
        session.press(.pasteImage) { [weak self] result in self?.handle(result, for: session, key: .pasteImage) }
    }

    /// Writes the pasteboard's image as PNG in Nook's private temporary folder, as screen vision writes its pictures (`ScreenShotFile`):
    /// in a folder that is the user's alone, as a new file (never over an existing one nor through a link) only the user can read,
    /// named with a fixed 24-hour stamp ("imagen-20261008-092924"). Then the clipboard images older than a day go, except those in
    /// `attached` (`MessageAttachments.prune`).
    static func saveImage(from pasteboard: NSPasteboard, folder: URL = ScreenShotFile.folder, now: Date = Date(), keeping attached: Set<String> = []) -> String? {
        guard let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        guard (try? ScreenShotFile.prepare(folder)) != nil,
              let url = try? ScreenShotFile.write(png, named: MessageAttachments.clipboardPrefix + ScreenShotFile.stamp(now), ext: "png", in: folder) else { return nil }
        MessageAttachments.prune(folder, now: now, keeping: attached.union([url.path]))
        return url.path
    }

    func requestDirectKeys() {
        let alert = NSAlert()
        alert.messageText = "Pulsar teclas en tu pestaña de Terminal"
        alert.informativeText = "Para pulsar flechas, Tab, Esc o ⇧⇥ en una pestaña de Terminal (las teclas de la barra, los menús y selectores de Claude o Codex, los modelos y el modo de Claude), Nook necesita el permiso de Accesibilidad de macOS. Con él, Nook pulsa la tecla en la pestaña elegida: sin traer Terminal al frente cuando su ventana ya es la de delante y la pantalla confirma la tecla; si no, trae un momento al frente solo esa pestaña, comprueba que es la correcta, pulsa la tecla allí y te devuelve a donde estabas. También lo usa para pulsar ⌘T y abrir las terminales nuevas como pestaña de tu ventana de Terminal; sin él, se abren en una ventana nueva. Los mensajes, Enter, elegir una opción en la tarjeta de preguntas y responder en su campo de texto funcionan sin este permiso.\n\nTras activar Nook en Ajustes, vuelve a pulsar la tecla."
        alert.addButton(withTitle: "Abrir Ajustes…"); alert.addButton(withTitle: "Ver permisos"); alert.addButton(withTitle: "Ahora no")
        capturePrivacy.prepare(alert.window)
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: showPermissions(); return
        default: return
        }
        DirectKeys.request()
        notice = "Activa Nook en Privacidad y seguridad → Accesibilidad, una sola vez. Si ya aparecía activado, Nook se registró de nuevo y lo verás apagado."
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
        capturePrivacy.prepare(alert.window)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.setEnabled(!claudeSignalsEnabled)
            claudeSignalsEnabled = ClaudeHooks.enabled
            notice = claudeSignalsEnabled ? "Avisos de Claude activados. En una sesión ya abierta, revisa /hooks para aprobar o cargar el cambio; algunas versiones requieren reabrir Claude." : "Avisos de Claude desactivados."
        } catch { notice = error.localizedDescription }
    }
    func receiveClaude(_ event: ClaudeSignal) {
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
                // A session moved to the background runs in a process of Claude's own, on a terminal no tab has: its hooks name the
                // session, and its tab is the one showing that session's record.
                let shown = matching.isEmpty && !event.sessionID.isEmpty
                    ? Set(self.sessions.filter { $0.transcript.map { Self.sessionID(of: $0.url) } == event.sessionID }.map(\.id)) : matching
                for session in self.sessions where shown.contains(session.id) { self.applyClaude(event, to: session) }
            }
        }
    }
    /// Each reading drains its own autorelease pool: the records' decoded lines go as soon as it ends.
    private let transcriptQueue = DispatchQueue(label: "dev.nook.transcripts", qos: .utility, autoreleaseFrequency: .workItem)

    /// Keeps a Claude tab's mirror on Claude's own record: found by the session id its hooks report,
    /// or else by the Claude process's working directory and the prompt on screen. Reading happens
    /// off the main thread and only touches what was appended.
    func followTranscript(_ session: TerminalSession, showingText: Bool = true) {
        guard session.agent == .claude, let tty = session.agentTTY else { return }
        let lookup = claudeProcesses, configs = claudeConfigs
        let locator = session.recordLocator(tty: tty) { ClaudeRecordLocator(tty: $0, lookup: lookup, configs: configs()) }
        let hook = session.claudeSessionID.map { ClaudeRecordLocator.Claim(id: $0, at: session.claudeSessionIDAt) }
        if let follower = session.transcript {
            let viewing = showingText ? session.viewedAgent : nil
            // A shell's output is read only while it is on show; collapsed, its reader goes and the next showing reads it again.
            let shell = showingText ? session.viewedShell : nil, epoch = session.shellViewEpoch
            transcriptQueue.async {
                if follower.poll() != nil { follower.unshown = true }
                // New text goes out only when the chat is on screen; read while collapsed, it waits until then.
                let text = showingText && follower.unshown ? follower.renderer.text : nil
                if text != nil { follower.unshown = false }
                let renderer = follower.renderer
                let agents = follower.agents()
                let agentText = follower.agentText(call: viewing)
                let shells = follower.shells()
                let output = follower.shellOutput(id: shell, epoch: epoch)
                let queued = renderer.queued
                guard text != nil || agentText != nil || output != nil || renderer.commandsVersion != follower.reportedCommands || agents != follower.reportedAgents
                        || shells != follower.reportedShells || queued != follower.reportedQueue else { return }
                follower.reportedCommands = renderer.commandsVersion; follower.reportedAgents = agents; follower.reportedShells = shells; follower.reportedQueue = queued
                DispatchQueue.main.async {
                    if session.transcript === follower {
                        session.applyTranscript(text, recap: renderer.recap, skills: renderer.skills, usedCommands: renderer.usedCommands, agents: agents, queued: queued,
                                                shells: shells)
                        if let viewing, let agentText { session.applyAgentText(agentText, call: viewing) }
                        if let shell, let output { session.applyShellOutput(output, id: shell) }
                    }
                }
            }
            // What Claude says about its record (its process's file, its hooks) is checked on every reading, cheaply: it wins over a
            // guess, and a /clear or --resume in the same process moves the tab to the new record at once.
            transcriptQueue.async {
                guard let url = locator.record(hook: hook), Self.sessionID(of: url) != Self.sessionID(of: follower.url) else { return }
                DispatchQueue.main.async {
                    guard session.transcript === follower, session.agent == .claude else { return }
                    session.transcript = TranscriptFollower(url: url); session.transcriptByGuess = false; session.transcriptLocated = Date()
                    self.followTranscript(session, showingText: showingText)
                }
            }
            // A guessed record is checked again now and then: /clear or another session may take over.
            guard session.transcriptByGuess, Date().timeIntervalSince(session.transcriptLocated) > 60 else { return }
        } else if Date().timeIntervalSince(session.transcriptLocated) < 10 { return }
        session.transcriptLocated = Date()
        let screen = session.mirroredText
        let taken = Set(sessions.compactMap { $0 === session ? nil : $0.transcript?.url })
        transcriptQueue.async {
            // Claude's word first; without it (an older Claude, no hooks), the record of its folder whose last prompt the screen shows.
            // Only what follows Claude's newest banner is this session's: a prompt above it belongs to an earlier Claude in the tab,
            // whose record would show that old conversation in place of the new one.
            var url = locator.record(hook: hook)
            let byGuess = url == nil
            if url == nil, let directory = TranscriptLocator.claudeDirectory(tty: tty) {
                url = TranscriptLocator.guess(directory: directory, screen: String(ClaudeStartup.sinceNewestBanner(screen)), excluding: taken)
            }
            guard let url else { return }
            DispatchQueue.main.async {
                guard session.transcript?.url != url, session.agent == .claude else { return }
                let follower = TranscriptFollower(url: url)
                session.transcript = follower; session.transcriptByGuess = byGuess
                self.followTranscript(session, showingText: showingText)
            }
        }
    }

    /// A record's session id: its file's name.
    private static func sessionID(of record: URL) -> String { record.deletingPathExtension().lastPathComponent }

    /// How the Claude process on a tab's terminal is found, and Claude's configuration folders; tests pass their own.
    var claudeProcesses = ClaudeProcessLookup.live
    var claudeConfigs: () -> [URL] = { TranscriptLocator.configs() }

    /// The status line's latest readings, and Claude's own copy of its usage reading for each config folder (`ClaudeUsageSnapshot`),
    /// read on their own queue; tests pass their own reader.
    var statusReadings: [ClaudeStatusReading] = []
    var usageSnapshots: [String: ClaudeUsageSnapshot] = [:]
    var usageSnapshotReader = ClaudeUsageSnapshotReader()
    let usageSnapshotQueue = DispatchQueue(label: "dev.nook.usage-snapshots", qos: .utility)

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

    /// Esc, or the bar's button, in an agent's conversation or a shell's output: back to Claude's. False when neither is shown,
    /// so the key keeps its other meaning (collapsing the island).
    @discardableResult func leaveAgentView() -> Bool {
        guard let session = selected, session.viewedAgent != nil || session.viewedShell != nil else { return false }
        view(agent: nil, in: session)
        return true
    }

    /// Shows a background shell's output in the tab instead of Claude's conversation (nil: back to it), read at once.
    func view(shell id: String?, in session: TerminalSession) {
        session.view(shell: id)
        followTranscript(session)
    }

    /// A click on a shell's row: its output opens. A shell of another tab brings that tab forward first.
    func openShell(_ shell: ShellActivity, in session: TerminalSession) {
        if selectedID != session.id { select(session) }
        view(shell: shell.id, in: session)
    }

    /// A Nook session's pane is read when it changes, and so is Claude's record with it; a shell's output on show keeps coming
    /// while Claude is quiet, so it is read on the activity tick too (Terminal tabs are read on their own clock).
    private func followShownShell(now: Date = Date()) {
        guard islandContentVisible, let session = selected, !session.isExternal, session.viewedShell != nil,
              now.timeIntervalSince(shellReadAt) >= 0.9 else { return }
        shellReadAt = now
        followTranscript(session)
    }
    private var shellReadAt = Date.distantPast

    private func applyClaude(_ event: ClaudeSignal, to session: TerminalSession) {
        session.noteClaudeHook(event.event, sessionID: event.sessionID)
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
                      "Panel: \(session.panel.map { "detectado, \($0.components(separatedBy: "\n").count) líneas" } ?? "no") · pregunta: \(session.prompt.map { "\($0.kind) «\($0.question)»" } ?? "no")",
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

    // MARK: Alert sound

    /// Alerts this close together ring once: several tabs finishing at the same moment are one sound, not a chord.
    static let alertSoundGap: TimeInterval = 1

    /// The sound of an alert just raised (`raiseAlert`, past its checks: never for the tab in front of the user, nor for a hook and
    /// the screen telling the same thing): its kind's sound, when the switch for every tab and the tab's own are both on.
    private func playAlertSound(_ kind: NookAlert.Kind, for session: TerminalSession, now: Date) {
        guard let sound = alertSound.sound(for: kind, tabOn: session.alertSoundOn), abs(now.timeIntervalSince(lastAlertSoundAt)) >= Self.alertSoundGap else { return }
        lastAlertSoundAt = now
        alertSoundPlayer.play(sound, volume: alertSound.volume)
    }

    /// Turns a tab's own alert sound on or off. Kept by the tab's id, so it holds when the tab is closed and reopened or Nook starts
    /// again, and it goes with the tab's name and colour (`restoreTabState`): a later tab on the same TTY starts with it on.
    func setAlertSound(_ on: Bool, for session: TerminalSession) {
        if session.alertSoundOn != on { session.alertSoundOn = on }
        let muted = on ? mutedTabs.subtracting([session.id]) : mutedTabs.union([session.id])
        guard muted != mutedTabs else { return }
        mutedTabs = muted
        saveMutedTabs()
        // What depends on every tab (`alertSoundOnForAllTabs`) is the model's to tell.
        objectWillChange.send()
    }

    /// Every tab's own switch at once. On clears them all, also those of tabs closed for now; off turns off the tabs in the strip.
    func setAlertSoundForAllTabs(_ on: Bool) {
        for session in sessions where session.alertSoundOn != on { session.alertSoundOn = on }
        let muted = on ? [] : mutedTabs.union(sessions.map(\.id))
        guard muted != mutedTabs else { return }
        mutedTabs = muted
        saveMutedTabs()
        objectWillChange.send()
    }

    /// Whether the tabs in the strip have their own alert sound on: true if all do, false if none does, nil when some do (and nil
    /// without tabs).
    var alertSoundOnForAllTabs: Bool? {
        let switches = Set(sessions.map(\.alertSoundOn))
        return switches.count == 1 ? switches.first : nil
    }

    /// Plays `sound`, or else the sound of `kind`, as an alert would, at the volume set and whatever the switches say: the settings
    /// let the user hear what they pick.
    func previewAlertSound(_ sound: AlertSound? = nil, for kind: NookAlert.Kind = .finished) {
        alertSoundPlayer.play(sound ?? alertSound.sound(for: kind), volume: alertSound.volume)
    }

    private func saveMutedTabs() { defaults.set(mutedTabs.sorted(), forKey: AlertSoundSettings.Key.mutedTabs) }

    // MARK: Welcome

    static let welcomedKey = "welcomed"

    /// The first-run greeting is over, for good: the user dismissed it, or started using Nook (their first tab, `place`).
    func markWelcomed() {
        guard !hasBeenWelcomed else { return }
        hasBeenWelcomed = true
        defaults.set(true, forKey: Self.welcomedKey)
    }

    // MARK: Quitting

    /// AppKit asks whether Nook may quit (`AppDelegate.applicationShouldTerminate`). The user quitting from Nook is asked first, in the
    /// island: this quit is cancelled, the question goes up (`quitPrompt`) and the island opens with the keyboard and stays open while
    /// it is up (`NotchController.showQuitPrompt`). The user quitting again while it is up is the answer, as ⌘Q twice is in a browser;
    /// a ⌘Q held down (`keyRepeat`, the key's own repeats) is one press, not two. Another app's or a script's quit asks the same way, and
    /// is never the answer: two quit events in a row from a script would otherwise get past the question. Only the Mac logging out,
    /// restarting or shutting down goes at once (`QuitRequest`), and so does the quit the user confirmed (`answerQuit`). Without an island
    /// to ask in, the question is a plain alert (`quitFallback`).
    func shouldTerminate(_ request: QuitRequest, keyRepeat: Bool = false) -> NSApplication.TerminateReply {
        if quitConfirmed || !request.asks {
            quitConfirmed = false
            if quitPrompt != nil { quitPrompt = nil }
            return .terminateNow
        }
        if quitPrompt != nil {
            guard request == .user, !keyRepeat else { return .terminateCancel }
            quitPrompt = nil
            return .terminateNow
        }
        guard let host = quitPromptHost, host.canShowQuitPrompt else {
            return (quitFallback?() ?? true) ? .terminateNow : .terminateCancel
        }
        quitPromptSerial += 1
        quitPrompt = QuitPrompt(id: quitPromptSerial)
        host.showQuitPrompt()
        return .terminateCancel
    }

    /// The user's answer to the island's question. Quit ("Salir"): Nook quits, and that quit goes through without asking again.
    /// Stay ("Quedarme", Esc, a click outside the island): the question goes and the island is left as it was before it was asked.
    func answerQuit(_ quit: Bool) {
        let asked = quitPrompt != nil
        if asked { quitPrompt = nil }
        if quit {
            quitConfirmed = true
            terminateApp()
        } else if asked {
            quitPromptHost?.quitPromptDismissed()
        }
    }

    // MARK: Memory

    /// Nook's own footprint, watched; the app starts it (`watchMemory`), tests and previews don't.
    private(set) var memoryWatch: MemoryWatch?

    func watchMemory(_ watch: MemoryWatch = MemoryWatch()) {
        memoryWatch?.stop()
        watch.onTrim = { [weak self] reason in self?.trimMemory(reason) }
        watch.onAlarm = { [weak self] bytes in
            self?.notice = "Nook está usando \(MemoryFootprint.megabytes(bytes)) MB de memoria, mucho más de lo normal. Ya liberó lo que pudo; si sigue así, sal de Nook y vuelve a abrirlo."
        }
        watch.start()
        memoryWatch = watch
    }

    /// Lets go of what can be rebuilt, for the tabs nobody is looking at (every tab while the island is collapsed): what slid out
    /// of Terminal's window and Claude's record as read so far (read again from its file at the next look). The script helper starts
    /// afresh, and the memory freed goes back to the system at once. Nothing on screen changes.
    func trimMemory(_ reason: MemoryWatch.Reason) {
        let hidden = sessions.filter { !(expanded && $0.id == selectedID) }
        hidden.forEach { $0.releaseHiddenMemory() }
        ScriptHelper.shared.recycle()
        MemoryFootprint.relieve()
        memoryLog.notice("trimmed \(hidden.count, privacy: .public) hidden tabs (\(String(describing: reason), privacy: .public))")
    }
}
