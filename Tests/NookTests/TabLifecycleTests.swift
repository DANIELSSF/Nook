import XCTest
@testable import Nook

/// Tabs leave Nook only for a reason that holds: the user closed them, Terminal really lost them (two readings in a row), or tmux
/// says the session is gone. A closed tab can come back.
@MainActor
final class TabLifecycleTests: XCTestCase {
    private func model() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-tabs-" + UUID().uuidString)!)
        model.terminalBridge.runScript = { _ in }   // selecting must not reach the real Terminal
        return model
    }
    private func tab(_ tty: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 7, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["zsh"], busy: false, selected: true, text: tty)
    }
    private func nookSession(executable: String = "/usr/bin/true") -> TerminalSession {
        let backend = TmuxBackend(executable: executable, socket: "/tmp/nook-tabs-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-tabs-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        return TerminalSession(record: record, backend: backend, create: false)
    }

    func testATerminalTabMissingFromOneReadingStays() {
        let model = model()
        let ttys: Set<String> = ["/dev/ttys070", "/dev/ttys071"]
        model.updateExternalTabs([tab("/dev/ttys070"), tab("/dev/ttys071")], ttys: ttys)
        XCTAssertEqual(model.sessions.count, 2)
        model.updateExternalTabs([tab("/dev/ttys070")], ttys: ttys)
        XCTAssertEqual(model.sessions.count, 2, "One reading that left a tab out does not close it.")
        model.updateExternalTabs([tab("/dev/ttys070"), tab("/dev/ttys071")], ttys: ttys)
        model.updateExternalTabs([tab("/dev/ttys070")], ttys: ttys)
        XCTAssertEqual(model.sessions.count, 2, "Seen again in between: the count starts over.")
        model.updateExternalTabs([tab("/dev/ttys070")], ttys: ttys)
        XCTAssertEqual(model.sessions.map(\.externalTTY), ["/dev/ttys070"], "Two readings in a row without it: Terminal lost it.")
        guard case .terminal(let tty, _, _) = model.recentlyClosed.first else { return XCTFail("Remembered as closed") }
        XCTAssertEqual(tty, "/dev/ttys071")
    }

    func testClosedTabsAreRememberedNewestFirstAndOnce() {
        let model = model()
        let sessions = (0..<7).map { _ in nookSession() }
        model.sessions = sessions
        for session in sessions { model.close(session) }
        XCTAssertEqual(model.recentlyClosed.count, AppModel.closedLimit)
        XCTAssertEqual(model.recentlyClosed.first, .nook(sessions[6].record, title: "Terminal"))
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testANookSessionComesBackWhileTmuxStillHasIt() {
        let model = model()
        let session = nookSession()
        model.tmuxHas = { $0 == session.record }
        model.sessions = [session]
        model.close(session)
        model.reopenLastClosed()
        XCTAssertEqual(model.sessions.map(\.record), [session.record])
        XCTAssertEqual(model.selectedID, model.sessions.first?.id)
        XCTAssertTrue(model.recentlyClosed.isEmpty)
    }

    func testASessionTmuxNoLongerHasSaysSo() {
        let model = model()
        let session = nookSession(executable: "/usr/bin/false")
        model.tmuxHas = { _ in false }
        model.sessions = [session]
        model.close(session)
        model.reopenLastClosed()
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.notice, "«Terminal» ya terminó; no se puede reabrir.")
    }

    func testOnlyTmuxsOwnWordsMakeASessionGone() {
        XCTAssertTrue(TmuxBackend.saysGone("can't find session: nook-1234"))
        XCTAssertTrue(TmuxBackend.saysGone("no server running on /tmp/nook-501/shared.sock"))
        XCTAssertTrue(TmuxBackend.saysGone("error connecting to /tmp/nook-501/shared.sock (No such file or directory)"))
        XCTAssertFalse(TmuxBackend.saysGone("/dev/null:1: unknown command: sett"), "A failure of tmux itself proves nothing about the session.")
        let record = SessionRecord(id: "nook-x", name: "Terminal", kind: .shell, directory: "/", socket: "/tmp/nook-x.sock", ownsSession: true)
        XCTAssertEqual(TmuxBackend(executable: "/nonexistent/tmux", socket: record.socket, configuration: "/dev/null").presence(record), .unknown,
                       "tmux that cannot run never makes Nook forget a saved session.")
        XCTAssertEqual(TmuxBackend(executable: "/usr/bin/true", socket: record.socket, configuration: "/dev/null").presence(record), .present)
    }
}
