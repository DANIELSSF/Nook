import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A Nook session with Claude in it shows Claude's conversation in its pane, and keeps its own terminal laid out underneath at the width it
/// had on show: tmux sizes the agent's pane to the view that holds the terminal.
@MainActor
final class NookSessionPaneTests: XCTestCase {
    private func session(_ model: AppModel, processes: [String], screen: String?) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-pane-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-pane-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: "/dev/ttys0\(Int.random(in: 10...99))", processes: processes, text: screen)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        return session
    }

    /// The pane in an island-sized window, laid out.
    private func mount(_ model: AppModel, _ session: TerminalSession) -> (NSHostingView<AnyView>, NSWindow) {
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let view = AnyView(SessionPane(model: model, session: session).id(session.id)
            .frame(width: size.width, height: size.height).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    func testTheTerminalKeepsItsWidthWhetherItOrTheMirrorShows() throws {
        let rule = String(repeating: "─", count: 60)
        let claudeScreen = ["⏺ Listo.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")

        let shellModel = AppModel(receivesSignals: false)
        let shell = session(shellModel, processes: ["/bin/zsh -l"], screen: nil)
        XCTAssertFalse(shell.mirrorsAgent)
        let shellMount = mount(shellModel, shell)
        XCTAssertNotNil(shell.terminal.window, "A shell's terminal is on show.")
        let shown = shell.terminal.frame.width

        let claudeModel = AppModel(receivesSignals: false)
        let claude = session(claudeModel, processes: ["claude"], screen: claudeScreen)
        XCTAssertTrue(claude.mirrorsAgent)
        let claudeMount = mount(claudeModel, claude)
        XCTAssertNotNil(claude.terminal.window, "With the mirror on show the terminal is still in the window, under it.")
        XCTAssertEqual(claude.terminal.frame.width, shown, accuracy: 0.5, "tmux sizes the pane to this view: the same width as when it showed.")
        XCTAssertGreaterThan(shown, 400)
        withExtendedLifetime((shellMount, claudeMount)) {}
    }

    func testTheMirrorHasTheKeyboardNotTheHiddenTerminal() throws {
        let rule = String(repeating: "─", count: 60)
        let model = AppModel(receivesSignals: false)
        let claude = session(model, processes: ["claude"], screen: ["⏺ Listo.", "", rule, "❯ ", rule].joined(separator: "\n"))
        let mounted = mount(model, claude)
        XCTAssertFalse(mounted.1.firstResponder === claude.terminal, "Typing into a terminal nobody sees would reach Claude unseen.")
        withExtendedLifetime(mounted) {}
    }
}
