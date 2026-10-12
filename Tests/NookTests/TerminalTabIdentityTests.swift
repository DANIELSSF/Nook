import AppKit
import XCTest
@testable import Nook

/// A Terminal tab is the tab, not its TTY: macOS hands a closed tab's /dev/ttysNNN to the next one (seen on this Mac: ttys008
/// closed on 5 Oct at 10:13 and came back as a new tab on 6 Oct at 06:52, which then showed the old tab's name).
@MainActor
final class TerminalTabIdentityTests: XCTestCase {
    /// Each test gets TTYs and logins of its own: names and histories are saved in the test process's preferences.
    private let tty = "/dev/ttys9" + String(Int.random(in: 10...99)) + String(UUID().uuidString.prefix(4))
    private var logins: [String: String] = [:]

    private func model() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-identity-" + UUID().uuidString)!)
        model.terminalBridge.runScript = { _ in }       // selecting must not reach the real Terminal
        model.terminalBridge.resting = true             // connecting must not start reading the real Terminal
        model.terminalBridge.loginStampsReader = { [unowned self] in self.logins }
        return model
    }
    private func tab(_ tty: String, window: Int = 7) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: window, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["login", "-zsh"], busy: false, selected: true, text: "")
    }

    // MARK: Identity

    func testTheSystemsLoginRecordsGiveEachTTYAStamp() {
        let stamps = TerminalTabIdentity.loginStamps()
        XCTAssertFalse(stamps.isEmpty, "this Mac has at least the console's login")
        for (tty, stamp) in stamps {
            XCTAssertTrue(tty.hasPrefix("/dev/"), tty)
            XCTAssertNotNil(stamp.range(of: #"^\d+\.\d{6}$"#, options: .regularExpression), stamp)
        }
    }

    func testAKeyCarriesItsLogin() {
        XCTAssertEqual(TerminalTabIdentity.key(tty: "/dev/ttys003", login: "1759766567.123456"), "/dev/ttys003@1759766567.123456")
        XCTAssertEqual(TerminalTabIdentity.key(tty: "/dev/ttys003", login: nil), "/dev/ttys003")
        XCTAssertEqual(TerminalTabIdentity.login(in: "/dev/ttys003@1759766567.123456"), "1759766567.123456")
        XCTAssertNil(TerminalTabIdentity.login(in: "/dev/ttys003"))
        XCTAssertTrue(TerminalTabIdentity.replaced("1", by: "2"))
        XCTAssertFalse(TerminalTabIdentity.replaced("1", by: "1"))
        XCTAssertFalse(TerminalTabIdentity.replaced(nil, by: "2"), "without a known login nothing can be told")
        XCTAssertFalse(TerminalTabIdentity.replaced("1", by: nil), "a missing record is no proof of another tab")
    }

    // MARK: Bug: a new tab took a closed tab's name

    func testANewTabOnAReusedTTYGetsNothingOfTheClosedOne() throws {
        let model = model()
        logins[tty] = "1759600000.000001"
        model.connectTerminalTab(tab(tty))
        let old = try XCTUnwrap(model.sessions.first)
        model.customize(old, title: "VIBE", tint: .sand, icon: .orbit)
        model.remember("hola", for: old)

        // The tab closes and Terminal gives its TTY to a new tab, between two readings.
        logins[tty] = "1759700000.000002"
        model.updateExternalTabs([tab(tty)], ttys: [tty])
        XCTAssertTrue(model.sessions.isEmpty, "the tab Nook followed is gone; the new one was never chosen")
        XCTAssertFalse(model.terminalBridge.trackedTabs.contains { $0.tty == tty }, "the new tab is not followed in its place")
        guard case .terminal(let closedTTY, let title, let login) = model.recentlyClosed.first else { return XCTFail("remembered as closed") }
        XCTAssertEqual([closedTTY, title, login], [tty, "VIBE", "1759600000.000001"])

        // The user connects the new tab: it starts clean.
        model.connectTerminalTab(tab(tty))
        let new = try XCTUnwrap(model.sessions.first)
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertEqual(new.displayTitle, "Terminal · 1", "Terminal's own title, not the closed tab's name")
        XCTAssertEqual(new.tint, .mint)
        XCTAssertEqual(new.icon, .dot)
        XCTAssertEqual(new.sentHistory, [])
    }

    func testConnectingANewTabOverAStaleOneReplacesIt() throws {
        let model = model()
        logins[tty] = "1759600000.000001"
        model.connectTerminalTab(tab(tty))
        model.customize(try XCTUnwrap(model.sessions.first), title: "app", tint: .rose)
        logins[tty] = "1759700000.000002"
        model.connectTerminalTab(tab(tty))
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions.first?.displayTitle, "Terminal · 1")
        XCTAssertEqual(model.terminalBridge.trackedTabs, [TrackedTerminalTab(windowID: 7, tty: tty, login: "1759700000.000002")])
    }

    func testTheSameTabKeepsItsLookAndHistoryWhenItComesBack() throws {
        let model = model()
        logins[tty] = "1759600000.000001"
        model.connectTerminalTab(tab(tty))
        let session = try XCTUnwrap(model.sessions.first)
        model.customize(session, title: "app", tint: .rose, icon: .bars)
        model.remember("revisa el lint", for: session)
        model.close(session)   // the ×: the tab lives on in Terminal
        XCTAssertTrue(model.sessions.isEmpty)

        model.connectTerminalTab(tab(tty))   // what reopening does once Terminal shows the tab
        let back = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(back.id, session.id)
        XCTAssertEqual(back.displayTitle, "app")
        XCTAssertEqual(back.tint, .rose)
        XCTAssertEqual(back.icon, .bars)
        XCTAssertEqual(back.sentHistory, ["revisa el lint"])

        // A new model (Nook relaunched while Terminal kept the tab) reads the same tab back.
        let relaunched = self.model()
        relaunched.updateExternalTabs([tab(tty)], ttys: [tty])
        XCTAssertEqual(relaunched.sessions.first?.displayTitle, "app")
        XCTAssertEqual(relaunched.sessions.first?.sentHistory, ["revisa el lint"])
    }

    func testAMovedTabKeepsBeingTheSameTab() {
        let model = model()
        logins[tty] = "1759600000.000001"
        model.connectTerminalTab(tab(tty, window: 7))
        model.updateExternalTabs([tab(tty, window: 9)], ttys: [tty])
        XCTAssertEqual(model.sessions.map(\.externalWindowID), [9])
        XCTAssertEqual(model.terminalBridge.trackedTabs.first?.login, "1759600000.000001", "following it to another window keeps its login")
    }

    func testARestoredTabWhoseTTYNowHoldsAnotherLoginIsNotFollowed() {
        let model = model()
        logins[tty] = "1759700000.000002"
        model.terminalBridge.restore(tabs: [TrackedTerminalTab(windowID: 7, tty: tty, login: "1759600000.000001")])
        model.updateExternalTabs([tab(tty)], ttys: [tty])
        XCTAssertTrue(model.sessions.isEmpty)
    }

    // MARK: Relaunch and the bare-TTY keys saved before

    func testOnlyTheSameTabsAreRestored() {
        let saved = Date(timeIntervalSince1970: 1_759_650_000)
        let logins = ["/dev/ttys001": "1759600000.000001", "/dev/ttys002": "1759700000.000002", "/dev/ttys003": "1759600000.000003", "/dev/ttys004": "1759700000.000004"]
        let tracked = [TrackedTerminalTab(windowID: 1, tty: "/dev/ttys001", login: "1759600000.000001"),   // same tab
                       TrackedTerminalTab(windowID: 1, tty: "/dev/ttys002", login: "1759600000.000009"),   // TTY reused
                       TrackedTerminalTab(windowID: 1, tty: "/dev/ttys003"),                               // saved before logins; older than the save
                       TrackedTerminalTab(windowID: 1, tty: "/dev/ttys004"),                               // saved before logins; opened after the save
                       TrackedTerminalTab(windowID: 1, tty: "/dev/ttys005")]                               // no record to compare
        XCTAssertEqual(TerminalTabIdentity.sameTabs(tracked, logins: logins, savedAt: saved), [
            TrackedTerminalTab(windowID: 1, tty: "/dev/ttys001", login: "1759600000.000001"),
            TrackedTerminalTab(windowID: 1, tty: "/dev/ttys003", login: "1759600000.000003"),
            TrackedTerminalTab(windowID: 1, tty: "/dev/ttys005")])
        XCTAssertEqual(TerminalTabIdentity.sameTabs(tracked, logins: [:], savedAt: saved), tracked, "no login records at all: as before")
    }

    func testBareTTYKeysMoveOnlyToTheTabProvenTheSameAndClosedTabsAreForgotten() {
        let entries = ["terminal.app::/dev/ttys001": "app",                    // restored tab: moves to its identity
                       "terminal.app::/dev/ttys008": "VIBE",                   // not restored: could be any tab now; goes
                       "terminal.app::/dev/ttys009@1759600000.000009": "Nook", // still that tab: stays
                       "terminal.app::/dev/ttys006@1759600000.000006": "EP",   // its TTY holds another tab now: goes
                       "terminal.app::/dev/ttys007@1759600000.000007": "ui",   // no login on its TTY (closed): goes
                       "/tmp/nook-501/shared.sock::nook-d07ec56a": "Terminal 2"]
        let logins = ["/dev/ttys001": "1759600000.000001", "/dev/ttys008": "1759700000.000008", "/dev/ttys009": "1759600000.000009", "/dev/ttys006": "1759700000.000006"]
        let keep = ["terminal.app::/dev/ttys001": "terminal.app::/dev/ttys001@1759600000.000001"]
        XCTAssertEqual(TerminalTabIdentity.migrated(entries, keep: keep, logins: logins), [
            "terminal.app::/dev/ttys001@1759600000.000001": "app",
            "terminal.app::/dev/ttys009@1759600000.000009": "Nook",
            "/tmp/nook-501/shared.sock::nook-d07ec56a": "Terminal 2"])
        XCTAssertEqual(TerminalTabIdentity.migrated(["terminal.app::/dev/ttys009@1759600000.000009": "Nook"], keep: [:], logins: [:]),
                       ["terminal.app::/dev/ttys009@1759600000.000009": "Nook"], "without login records nothing is thrown away")
    }

    // MARK: New terminals open in Terminal

    func testNewNamesAreNumberedAmongTheOpenTabsOnly() {
        XCTAssertEqual(NewTerminalCommand.name(.claude, taken: []), "Claude Code")
        XCTAssertEqual(NewTerminalCommand.name(.claude, taken: ["Claude Code", "Terminal"]), "Claude Code 2")
        XCTAssertEqual(NewTerminalCommand.name(.claude, taken: ["Claude Code 2"]), "Claude Code", "a closed tab's name is free again")
        XCTAssertEqual(NewTerminalCommand.name(.shell, taken: ["Terminal", "Terminal 2", "Terminal 4"]), "Terminal 3")
    }

    func testTheCommandGoesToTheFolderWhateverItsNameAndRunsTheCLIOrSaysItIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook tabs \(UUID().uuidString.prefix(4))")
        let folder = root.appendingPathComponent("it's \"$HOME\" `x` $(echo no)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = String(cString: realpath(folder.path, nil))   // /var/folders… is /private/var/folders… to `pwd -P`

        let shell = try Shell.run("/bin/zsh", ["-f", "-c", NewTerminalCommand.command(.shell, directory: folder.path) + " && pwd -P"])
        XCTAssertEqual(shell.0, 0)
        XCTAssertEqual(shell.1.trimmingCharacters(in: .newlines), real)

        let missing = try Shell.run("/bin/zsh", ["-f", "-c", NewTerminalCommand.command(.claude, directory: folder.path)], environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(missing.1.trimmingCharacters(in: .newlines), "No se encontró Claude Code. Instala su CLI o usa esta terminal.")

        let fake = bin.appendingPathComponent("codex")
        try "#!/bin/sh\necho \"codex en $(pwd -P)\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let found = try Shell.run("/bin/zsh", ["-f", "-c", NewTerminalCommand.command(.codex, directory: folder.path)], environment: ["PATH": bin.path + ":/usr/bin:/bin"])
        XCTAssertEqual(found.1.trimmingCharacters(in: .newlines), "codex en " + real)

        // And it crosses into AppleScript literally.
        let command = NewTerminalCommand.command(.claude, directory: folder.path)
        XCTAssertEqual(try TerminalAppBridge.execute("return " + AppleScriptText.literal(command)).stringValue, command)
    }

    func testOpeningScriptsCompileWithTerminalsDictionary() {
        let command = NewTerminalCommand.command(.claude, directory: "/tmp/a \"b\"")
        for source in [TerminalAppBridge.frontWindowScript, TerminalAppBridge.raiseWindowScript(42), TerminalAppBridge.windowTTYsScript(42),
                       TerminalAppBridge.newWindowScript(command),
                       TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: TerminalAppBridge.runCommandAction(command))] {
            var details: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
        }
    }

    /// Plays Terminal for the opener: one window with one tab; ⌘T adds a tab after `delay` polls (never, when nil).
    private final class FakeTerminal {
        var windows: [Int: [String]] = [42: ["/dev/ttys100"]]
        var newTabAfter: Int? = 1
        var raiseFails = false
        var log: [String] = []
        private var polls = 0
        private var pressed = false
        func opener() -> TerminalTabOpener {
            TerminalTabOpener(
                frontWindow: { self.windows.keys.sorted().first.map { (id: $0, ttys: self.windows[$0]!) } },
                raise: { self.log.append("raise \($0)"); if self.raiseFails { throw TerminalBridgeError.failed("no") } },
                pressNewTab: { self.log.append("⌘T"); self.pressed = true },
                ttys: { id in
                    self.polls += 1
                    if self.pressed, let after = self.newTabAfter, self.polls >= after, !(self.windows[id] ?? []).contains("/dev/ttys101") { self.windows[id, default: []].append("/dev/ttys101") }
                    return self.windows[id] ?? []
                },
                run: { self.log.append("run \($0) \($1) \($2)") },
                newWindow: { self.log.append("window \($0)"); return (77, "/dev/ttys200") },
                sleep: { _ in })
        }
    }

    func testANewTerminalIsATabOfTheFrontWindow() throws {
        let terminal = FakeTerminal(); terminal.newTabAfter = 3
        let opened = try terminal.opener().open("cd /tmp", tabsAllowed: true)
        XCTAssertEqual(opened, OpenedTerminalTab(windowID: 42, tty: "/dev/ttys101", placement: .tab))
        XCTAssertEqual(terminal.log, ["raise 42", "⌘T", "run 42 /dev/ttys101 cd /tmp"], "the command goes to the tab that appeared, nowhere else")
    }

    func testWithoutAWindowANewWindowOpens() throws {
        let terminal = FakeTerminal(); terminal.windows = [:]
        let opened = try terminal.opener().open("cd /tmp", tabsAllowed: true)
        XCTAssertEqual(opened.placement, .firstWindow)
        XCTAssertEqual(terminal.log, ["window cd /tmp"])
    }

    func testWithoutPermissionANewWindowOpensAndNoKeyIsPressed() throws {
        let terminal = FakeTerminal()
        let opened = try terminal.opener().open("cd /tmp", tabsAllowed: false)
        XCTAssertEqual(opened, OpenedTerminalTab(windowID: 77, tty: "/dev/ttys200", placement: .windowWithoutPermission))
        XCTAssertEqual(terminal.log, ["window cd /tmp"])
    }

    func testATabThatNeverShowsUpFallsBackToAWindowWithoutTouchingTheOldTabs() throws {
        let terminal = FakeTerminal(); terminal.newTabAfter = nil
        let opened = try terminal.opener().open("cd /tmp", tabsAllowed: true)
        XCTAssertEqual(opened.placement, .windowAfterUnconfirmedTab)
        XCTAssertEqual(terminal.log, ["raise 42", "⌘T", "window cd /tmp"])
    }

    func testTheFallbackComesWithinABoundedNumberOfReadsWhateverTheTiming() throws {
        for timing in [TerminalTabOpener.Timing(), .init(poll: 0, confirm: 3), .init(poll: 0.1, confirm: .greatestFiniteMagnitude), .init(poll: 1, confirm: 0), .init(poll: 0.1, confirm: .infinity), .init(poll: 0.1, confirm: .nan), .init(poll: 0.1, confirm: -5)] {
            let terminal = FakeTerminal(); terminal.newTabAfter = nil
            var reads = 0
            var opener = terminal.opener()
            let ttys = opener.ttys
            opener.ttys = { reads += 1; return try ttys($0) }
            XCTAssertEqual(try opener.open("cd /tmp", tabsAllowed: true, timing: timing).placement, .windowAfterUnconfirmedTab)
            XCTAssertTrue((1...100).contains(reads), "\(timing): \(reads) reads")
            XCTAssertEqual(reads, timing.reads)
        }
        XCTAssertEqual(TerminalTabOpener.Timing().reads, 30)
    }

    func testNamingEndsEvenWithManyTabsOpen() {
        let taken = ["Terminal"] + (2...500).map { "Terminal \($0)" }
        XCTAssertEqual(NewTerminalCommand.name(.shell, taken: taken), "Terminal 501")
    }

    func testAWindowThatWontComeForwardFallsBackToAWindow() throws {
        let terminal = FakeTerminal(); terminal.raiseFails = true
        let opened = try terminal.opener().open("cd /tmp", tabsAllowed: true)
        XCTAssertEqual(opened.placement, .windowAfterUnconfirmedTab)
        XCTAssertEqual(terminal.log, ["raise 42", "window cd /tmp"], "no ⌘T unless the window is in front")
    }

    // MARK: create()

    private func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        for (i, item) in items.enumerated() { result.insert(item, at: i + 1) }
        return result
    }

    /// Wires the model's bridge to a scripted Terminal: one window (42) unless `windowless`; ⌘T adds `newTTY`.
    private func scriptedTerminal(_ model: AppModel, newTTY: String, windowless: Bool = false, allowed: Bool = true) -> (scripts: () -> [String], keys: () -> Int) {
        let lock = NSLock()
        var scripts: [String] = [], keys = 0, pressed = false
        let bridge = model.terminalBridge
        bridge.directKeysAllowed = { allowed }
        bridge.terminalProcess = { 4242 }
        bridge.postNewTab = { _ in lock.lock(); keys += 1; pressed = true; lock.unlock() }
        bridge.queryScript = { [unowned self] source in
            lock.lock(); scripts.append(source); let tabbed = pressed; lock.unlock()
            if source.contains("set chosen to 0") {
                return windowless ? self.list([]) : self.list([.init(int32: 42), self.list([.init(string: "/dev/ttys100")])])
            }
            if source.contains("return tty of every tab of window id") {
                return self.list([.init(string: "/dev/ttys100")] + (tabbed ? [.init(string: newTTY)] : []))
            }
            if source.contains("set wasRunning") { return self.list([.init(int32: 77), .init(string: newTTY)]) }
            if source.contains("set rows to {}") { throw TerminalBridgeError.malformedResponse }   // the opener copes without a reading
            return NSAppleEventDescriptor(boolean: true)
        }
        return ({ lock.lock(); defer { lock.unlock() }; return scripts }, { lock.lock(); defer { lock.unlock() }; return keys })
    }

    private func waitForSession(_ model: AppModel, tty: String) {
        let deadline = Date().addingTimeInterval(5)
        while !model.sessions.contains(where: { $0.externalTTY == tty }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(model.sessions.contains { $0.externalTTY == tty }, "tab followed")
    }

    func testCreateOpensATabInTerminalAndFollowsIt() throws {
        let model = model()
        let newTTY = tty + "n"
        logins[newTTY] = "1759800000.000001"
        let terminal = scriptedTerminal(model, newTTY: newTTY)
        model.sessions = []
        XCTAssertNil(model.create(.claude, directory: "/tmp/mi carpeta"))
        waitForSession(model, tty: newTTY)
        let session = try XCTUnwrap(model.sessions.first { $0.externalTTY == newTTY })
        XCTAssertEqual(model.selectedID, session.id)
        XCTAssertEqual(session.displayTitle, "Claude Code")
        XCTAssertTrue(session.isExternal, "Nook follows Terminal's tab; it hosts no terminal of its own")
        XCTAssertEqual(session.id, "terminal.app::" + newTTY + "@1759800000.000001")
        XCTAssertEqual(terminal.keys(), 1)
        let run = try XCTUnwrap(terminal.scripts().first { $0.contains("do script") })
        XCTAssertTrue(run.contains("if tty of t is \"\(newTTY)\""), "typed into the new tab only")
        XCTAssertTrue(run.contains(AppleScriptText.literal(NewTerminalCommand.command(.claude, directory: "/tmp/mi carpeta"))))
        XCTAssertNil(model.notice)

        // A second one is numbered among the open tabs.
        let second = tty + "m"
        logins[second] = "1759800000.000002"
        _ = scriptedTerminal(model, newTTY: second)
        model.create(.claude)
        waitForSession(model, tty: second)
        XCTAssertEqual(model.sessions.first { $0.externalTTY == second }?.displayTitle, "Claude Code 2")
    }

    func testCreateWithoutPermissionOpensAWindowAndSaysWhyOnce() throws {
        let model = model()
        let first = tty + "a", second = tty + "b"
        _ = scriptedTerminal(model, newTTY: first, allowed: false)
        model.create(.shell)
        waitForSession(model, tty: first)
        XCTAssertEqual(model.sessions.first { $0.externalTTY == first }?.displayTitle, "Terminal")
        XCTAssertTrue(model.notice?.contains("Accesibilidad") == true, model.notice ?? "no notice")
        model.notice = nil
        let terminal = scriptedTerminal(model, newTTY: second, allowed: false)
        model.create(.shell)
        waitForSession(model, tty: second)
        XCTAssertNil(model.notice, "said once")
        XCTAssertEqual(terminal.keys(), 0, "no ⌘T without permission")
        XCTAssertTrue(terminal.scripts().contains { $0.contains("set wasRunning") })
    }

    func testCreateWithTerminalWindowlessOpensAWindowWithoutAsking() {
        let model = model()
        let newTTY = tty + "w"
        let terminal = scriptedTerminal(model, newTTY: newTTY, windowless: true)
        model.create(.codex)
        waitForSession(model, tty: newTTY)
        XCTAssertEqual(terminal.keys(), 0)
        XCTAssertNil(model.notice, "Terminal had no window: a window is what anyone would expect")
    }
}
