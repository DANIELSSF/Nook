import AppKit
import Darwin

/// A Terminal tab's identity across its life: its TTY plus the moment its login session began. macOS hands a closed tab's
/// /dev/ttysNNN to the next tab that opens, so the TTY alone gave a new tab the closed one's name, colour and history.
enum TerminalTabIdentity {
    /// The login records are read through one shared cursor (`getutxent`), so readers take turns.
    private static let lock = NSLock()

    /// When each TTY's current login session began, from the system's login records (utmpx, what `who` and `last` read):
    /// "/dev/ttys003" → "1759766567.123456". Terminal starts every tab through `login`, which writes that record.
    static func loginStamps() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var stamps: [String: String] = [:]
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard !line.isEmpty else { continue }
            let time = entry.pointee.ut_tv
            stamps["/dev/" + line] = String(format: "%ld.%06d", time.tv_sec, time.tv_usec)
        }
        return stamps
    }

    /// The tab's key: "/dev/ttys003@1759766567.123456", or the bare TTY when its login can't be told.
    static func key(tty: String, login: String?) -> String { login.map { tty + "@" + $0 } ?? tty }
    /// The login part of a key, if it has one.
    static func login(in key: String) -> String? {
        guard let at = key.firstIndex(of: "@") else { return nil }
        return String(key[key.index(after: at)...])
    }
    /// Whether the tab Terminal shows on `tty` now is not the one a key was made for: both logins are known and differ.
    static func replaced(_ known: String?, by current: String?) -> Bool {
        guard let known, let current else { return false }
        return known != current
    }

    static let terminalPrefix = "terminal.app::"

    /// Saved names, colours and histories from before tabs had an identity were keyed by the TTY alone. Each moves to the
    /// identity of the tab on that TTY only when that tab is provably the one it was saved for (`keep`: bare key → full key);
    /// every other bare Terminal key goes, so it can't land on a tab that reused the TTY. Keys of tabs whose TTY now holds a
    /// different login (the tab closed for good) go too. Nook's own tmux sessions are left alone.
    static func migrated<Value>(_ entries: [String: Value], keep: [String: String], logins: [String: String]) -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, value) in entries {
            guard key.hasPrefix(terminalPrefix) else { result[key] = value; continue }
            let tabKey = String(key.dropFirst(terminalPrefix.count))
            if let login = login(in: tabKey) {
                let tty = String(tabKey.prefix { $0 != "@" })
                // Without login records at all nothing can be told apart: keep it.
                if logins.isEmpty || !replaced(login, by: logins[tty]) && logins[tty] != nil { result[key] = value }
            } else if let moved = keep[key], result[moved] == nil {
                result[moved] = value
            }
        }
        return result
    }

    /// `migrated`, for what Nook keeps by the id of a tab of either kind (the strip's order, the tabs whose alert sound is off): Terminal's tabs
    /// as `migrated` says, and of Nook's own tmux sessions only the ones restored at this launch (`nookTabs`). A session that ended while Nook
    /// was away, or whose tab was closed for good, is not coming back, so what was kept for it goes rather than staying in the preferences forever.
    static func migrated<Value>(_ entries: [String: Value], keep: [String: String], logins: [String: String], nookTabs: Set<String>) -> [String: Value] {
        migrated(entries, keep: keep, logins: logins).filter { id, _ in id.hasPrefix(terminalPrefix) || nookTabs.contains(id) }
    }

    /// The tabs Nook followed when it last saved that are still the same tabs. A tab whose TTY now holds a different login is
    /// gone. A tab saved before tabs had an identity is the same one only if its login began before Nook last wrote its
    /// preferences (`savedAt`): a tab opened later can't be one Nook was following. Kept tabs carry their login from now on.
    static func sameTabs(_ tracked: [TrackedTerminalTab], logins: [String: String], savedAt: Date?) -> [TrackedTerminalTab] {
        guard !logins.isEmpty else { return tracked }
        return tracked.compactMap { tab in
            guard let current = logins[tab.tty] else { return tab }   // no login record to compare: as before
            if let known = tab.login { return known == current ? tab : nil }
            if let savedAt, let began = Double(current), Date(timeIntervalSince1970: began) > savedAt { return nil }
            var adopted = tab; adopted.login = current
            return adopted
        }
    }
}

/// What a new tab runs: a login shell in the folder for a terminal; the agent's CLI there for Claude Code and Codex, with a
/// word in Spanish when it isn't installed. Either way the shell stays when the CLI exits, like any Terminal tab.
enum NewTerminalCommand {
    static func command(_ kind: SessionKind, directory: String) -> String {
        let folder = "cd " + Shell.quote(directory)
        switch kind {
        case .shell: return folder
        case .claude, .codex:
            let missing = Shell.quote("No se encontró \(kind.title). Instala su CLI o usa esta terminal.")
            return folder + " && if command -v \(kind.rawValue) >/dev/null 2>&1; then \(kind.rawValue); else echo \(missing); fi"
        }
    }

    /// "Claude Code", then "Claude Code 2", "Claude Code 3"…: the first name no open tab uses.
    static func name(_ kind: SessionKind, taken: [String]) -> String {
        let used = Set(taken)
        guard used.contains(kind.title) else { return kind.title }
        // At most one number per open tab is taken, so this ends within `taken.count + 2` steps.
        var number = 2
        while used.contains("\(kind.title) \(number)") { number += 1 }
        return "\(kind.title) \(number)"
    }
}

/// A tab Nook opened in Terminal: where it is, and whether it had to be a window of its own.
struct OpenedTerminalTab: Equatable {
    enum Placement: Equatable {
        /// A new tab in a window that was already open.
        case tab
        /// Terminal had no window (or wasn't running): a new window, as Terminal itself would.
        case firstWindow
        /// Without Accessibility Nook can't press ⌘T: a new window instead.
        case windowWithoutPermission
        /// ⌘T was pressed but no new tab showed up in that window in time: a new window instead.
        case windowAfterUnconfirmedTab
    }
    let windowID: Int
    let tty: String
    let placement: Placement
    /// When the tab's login began (`TerminalTabIdentity`), once its record shows up.
    var login: String?
}

/// Opens a terminal in Terminal.app: a new tab of an open window (the frontmost one), or a new window when there is none, when
/// ⌘T can't be pressed, or when its tab can't be confirmed. Never fails to open one while Terminal can be scripted at all.
/// Each step is a transport so tests can play Terminal.
struct TerminalTabOpener {
    /// The window to add a tab to and its tabs' TTYs, or nil when Terminal isn't running or has no window.
    var frontWindow: () throws -> (id: Int, ttys: [String])?
    /// Brings that window forward with Terminal active; throws if Terminal doesn't show it.
    var raise: (Int) throws -> Void
    /// Presses ⌘T in Terminal.
    var pressNewTab: () -> Void
    /// The TTYs of a window's tabs now.
    var ttys: (Int) throws -> [String]
    /// Runs the command in that window's tab on that TTY.
    var run: (_ windowID: Int, _ tty: String, _ command: String) throws -> Void
    /// Runs the command in a new window (Terminal's own startup window when it was just launched).
    var newWindow: (String) throws -> (id: Int, tty: String)
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    struct Timing {
        var poll = 0.1, confirm = 3.0
        /// How many times the window is read for the new tab: `confirm / poll`, at least 1 and at most 100, whatever the timing.
        var reads: Int {
            let ratio = (confirm / max(poll, 0.001)).rounded(.up)
            guard ratio.isFinite else { return ratio > 0 ? 100 : 1 }
            return Int(min(100, max(1, ratio)))
        }
    }

    func open(_ command: String, tabsAllowed: Bool, timing: Timing = .init()) throws -> OpenedTerminalTab {
        guard let window = try frontWindow() else {
            let made = try newWindow(command)
            return OpenedTerminalTab(windowID: made.id, tty: made.tty, placement: .firstWindow)
        }
        guard tabsAllowed else {
            let made = try newWindow(command)
            return OpenedTerminalTab(windowID: made.id, tty: made.tty, placement: .windowWithoutPermission)
        }
        do {
            try raise(window.id)
            let before = Set(window.ttys)
            pressNewTab()
            for _ in 0..<timing.reads {
                sleep(timing.poll)
                // Only a TTY that wasn't in this window before ⌘T is the new tab; nothing else is guessed.
                if let tty = ((try? ttys(window.id)) ?? []).first(where: { !before.contains($0) }) {
                    try run(window.id, tty, command)
                    return OpenedTerminalTab(windowID: window.id, tty: tty, placement: .tab)
                }
            }
        } catch {
            tabLog.error("new tab in window \(window.id) failed: \(error.localizedDescription, privacy: .public); opening a window")
        }
        let made = try newWindow(command)
        return OpenedTerminalTab(windowID: made.id, tty: made.tty, placement: .windowAfterUnconfirmedTab)
    }
}

extension DirectKeys {
    /// ⌘T, Terminal's New Tab. Only Command is set, so a modifier held meanwhile can't turn it into another shortcut.
    static func postNewTab(to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 17, keyDown: down) else { continue }   // kVK_ANSI_T
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }
}

extension TerminalAppBridge {
    /// The frontmost window that has tabs (a minimized one only when no other has), with its tabs' TTYs; {} when Terminal
    /// isn't running or has no window. It never launches Terminal.
    static let frontWindowScript = """
        with timeout of 4 seconds
            if application id "com.apple.Terminal" is not running then return {}
            tell application id "com.apple.Terminal"
                set chosen to 0
                repeat with w in windows
                    try
                        if (count of tabs of w) > 0 then
                            if chosen is 0 then set chosen to id of w
                            if not (miniaturized of w) then
                                set chosen to id of w
                                exit repeat
                            end if
                        end if
                    end try
                end repeat
                if chosen is 0 then return {}
                return {chosen, tty of every tab of window id chosen}
            end tell
        end timeout
        """

    /// Brings a window forward with Terminal active, and waits until Terminal says so: ⌘T goes to the front window.
    static func raiseWindowScript(_ windowID: Int) -> String {
        """
        with timeout of 4 seconds
            tell application id "com.apple.Terminal"
                if not (exists window id \(windowID)) then error "La ventana de Terminal ya se cerró."
                set targetWindow to window id \(windowID)
                set miniaturized of targetWindow to false
                set index of targetWindow to 1
                activate
                repeat 40 times
                    if frontmost and (index of targetWindow is 1) then exit repeat
                    delay 0.025
                end repeat
                if not (frontmost and (index of targetWindow is 1)) then error "Terminal no mostró la ventana elegida."
            end tell
        end timeout
        """
    }

    static func windowTTYsScript(_ windowID: Int) -> String {
        """
        with timeout of 4 seconds
            tell application id "com.apple.Terminal"
                if not (exists window id \(windowID)) then return {}
                return tty of every tab of window id \(windowID)
            end tell
        end timeout
        """
    }

    /// A new window running the command. A Terminal that isn't running opens its own startup window when launched, and a second
    /// one would come with the command; so a just-launched Terminal gets the command in that first window instead.
    static func newWindowScript(_ command: String) -> String {
        """
        with timeout of 15 seconds
            set wasRunning to application id "com.apple.Terminal" is running
            tell application id "com.apple.Terminal"
                if not wasRunning then
                    activate
                    repeat 60 times
                        if (count of windows) > 0 then exit repeat
                        delay 0.05
                    end repeat
                end if
                if (not wasRunning) and (count of windows) > 0 then
                    set newTab to selected tab of window 1
                    do script \(AppleScriptText.literal(command)) in newTab
                else
                    set newTab to do script \(AppleScriptText.literal(command))
                end if
                set newTTY to tty of newTab
                activate
                repeat with w in windows
                    try
                        if (tty of every tab of w) contains newTTY then return {id of w, newTTY}
                    end try
                end repeat
                error "Terminal no mostró la ventana nueva."
            end tell
        end timeout
        """
    }

    /// Types the command into the tab `t` of `targetScript` with its Return: the tab's shell runs it.
    static func runCommandAction(_ command: String) -> String { "do script \(AppleScriptText.literal(command)) in t" }

    /// Opens a terminal running `command` (a tab of the front window when it can, else a window) and hands back the tab as
    /// Terminal reads it, with its login, ready to be followed. Runs on the scripting queue, after anything queued before.
    func openTab(running command: String, completion: @escaping (Result<(OpenedTerminalTab, TerminalTabSnapshot), Error>) -> Void) {
        let query = queryScript, post = postNewTab, pid = terminalProcess(), allowed = directKeysAllowed()
        let opener = TerminalTabOpener(
            frontWindow: {
                let value = TerminalAppBridge.structuredValue(try query(TerminalAppBridge.frontWindowScript)) as? [Any] ?? []
                guard value.count == 2, let id = (value[0] as? Int32).map(Int.init) else { return nil }
                return (id: id, ttys: (value[1] as? [Any] ?? []).compactMap { $0 as? String })
            },
            raise: { _ = try query(TerminalAppBridge.raiseWindowScript($0)) },
            pressNewTab: { if let pid { post(pid) } },
            ttys: { ((TerminalAppBridge.structuredValue(try query(TerminalAppBridge.windowTTYsScript($0))) as? [Any]) ?? []).compactMap { $0 as? String } },
            run: { windowID, tty, command in
                _ = try query(TerminalAppBridge.targetScript(windowID: windowID, tty: tty, action: TerminalAppBridge.runCommandAction(command)))
            },
            newWindow: { command in
                let value = TerminalAppBridge.structuredValue(try query(TerminalAppBridge.newWindowScript(command))) as? [Any] ?? []
                guard value.count == 2, let id = (value[0] as? Int32).map(Int.init), let tty = value[1] as? String else { throw TerminalBridgeError.malformedResponse }
                return (id: id, tty: tty)
            })
        let stamps = loginStampsReader
        queue.async {
            let result = Result { () throws -> (OpenedTerminalTab, TerminalTabSnapshot) in
                var opened = try opener.open(command, tabsAllowed: allowed && pid != nil)
                // `login` writes the tab's record as the tab starts; wait for it briefly, so the tab is known by its identity
                // from the first moment (and a later tab on its TTY can't pass for it).
                for _ in 0..<20 {
                    if let login = stamps()[opened.tty] { opened.login = login; break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let tab = (try? TerminalAppBridge.decode(query(TerminalAppBridge.snapshotScript(windowIDs: [opened.windowID], ttys: [opened.tty], includeText: false))))?.first
                    ?? TerminalTabSnapshot(windowID: opened.windowID, windowTitle: "Terminal", index: 1, tty: opened.tty, customTitle: "", processes: [], busy: false, selected: true, text: "")
                return (opened, tab)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
