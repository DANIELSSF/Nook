import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the session tabs' agent badges and lists to PNG for visual review. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class TabAgentRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Mounts `view` in an offscreen window, lets `steps` change the data between run loop turns (the tabs' trackers
    /// only see changes after they exist), and writes the final image.
    private func render<V: View>(_ view: V, size: NSSize, settle: Double = 0.3, steps: [() -> Void] = [], to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        for step in steps {
            step()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        clearScrollBackgrounds(host)
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            clearScrollBackgrounds(host)
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(blackBacked(rep).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The panel's embedded AppKit views (the tab row's scroll view) leave their area transparent in an offscreen
    /// render, where the app has the island's black behind them. Composite over black so the tabs read as they do there.
    private func blackBacked(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// An offscreen render paints the tab row's scroll view white (the app shows it transparent); clear it so the tabs
    /// can be judged against the island's black.
    private func clearScrollBackgrounds(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false; scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    private func agent(_ id: String, _ name: String, kind: String? = "general-purpose", model: String? = nil, state: SubagentActivity.State = .running,
                       tools: Int? = nil, tokens: String? = nil, duration: String? = nil, activity: String? = nil, note: String? = nil) -> SubagentActivity {
        var shown = SubagentActivity(id: id, name: name, kind: kind, state: state, background: true, toolUses: tools, tokens: tokens, duration: duration, note: note)
        shown.model = model
        shown.activity = activity
        return shown
    }

    private func session(_ model: AppModel, _ title: String, _ tty: String, tint: TabTint = .mint) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: "⏺ Revisando el código del notch.")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        return session
    }

    private struct Scenario {
        var model: AppModel
        var sessions: [TerminalSession]
        /// The tab with two working agents, one with a live activity line.
        var busy: TerminalSession { sessions[0] }
    }

    /// The island's tabs: "nook" (selected) has two background agents on different models, "api" has one that just
    /// finished, "docs" has none, "web" has one working and one failed.
    private func scenario() -> Scenario {
        let model = AppModel(receivesSignals: false)
        let nook = session(model, "nook", "/dev/ttys090", tint: .mint)
        let api = session(model, "api", "/dev/ttys091", tint: .blue)
        let docs = session(model, "docs", "/dev/ttys092", tint: .lavender)
        let web = session(model, "web", "/dev/ttys093", tint: .peach)
        nook.subagents = [
            agent("a", "Cat pet animation improvements", kind: "general-purpose", model: "sonnet", tools: 23, tokens: "41.2k", duration: "3m 12s", activity: "Read(Sources/Nook/Pet.swift)"),
            agent("b", "Review the notch layout and the tab row", kind: "Explore", model: "opus", tools: 9, tokens: "12k", duration: "1m 4s"),
            agent("c", "Run the test suite", kind: "general-purpose", model: "haiku", state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s"),
        ]
        api.subagents = [agent("d", "Audit the API routes", model: "sonnet", tools: 14, tokens: "20.1k", duration: "2m 2s", activity: "Bash(swift test --filter PanelRenderTests)")]
        web.subagents = [agent("e", "Fix the login form", model: "opus", tools: 4, tokens: "6.3k", duration: "40s", activity: "Edit(src/components/LoginForm.tsx)"),
                         agent("f", "Check the migration", state: .failed, tools: 2, duration: "12s", note: "Falló")]
        model.sessions = [nook, api, docs, web]
        model.selectedID = nook.id
        model.expanded = true; model.islandContentVisible = true
        return Scenario(model: model, sessions: model.sessions)
    }

    private var size: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)) }
    private func path(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// The whole island: the tab with working agents shows a terracotta badge, the one whose agent just ended a mint
    /// check, the one with none shows nothing, and the one with a failure beside a working agent carries an amber dot.
    func testRenderTabsWithAgentBadges() throws {
        let directory = try renderDirectory()
        let scenario = scenario()
        let api = scenario.sessions[1]
        let running = api.subagents
        // "api" starts with a working agent and finishes it after the tab exists: finished agents show for a minute.
        api.subagents = running
        try render(NookPanel(model: scenario.model), size: size, steps: [{ api.subagents = running.map { var done = $0; done.state = .done; done.activity = nil; return done } }],
                   to: path(directory, "tabs-badges.png"))
    }

    /// The same, with the list of the selected tab open, and with the list of the last tab (kept inside the island).
    func testRenderTabAgentLists() throws {
        let directory = try renderDirectory()
        let scenario = scenario()
        let presenter = TabAgentListPresenter()
        presenter.toggle(scenario.busy.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try render(NookPanel(model: scenario.model, agentList: presenter), size: size, to: path(directory, "tabs-list-open.png"))

        let other = self.scenario()
        let last = TabAgentListPresenter()
        last.toggle(other.sessions[3].id, frame: CGRect(x: 400, y: 4, width: 28, height: 22))
        try render(NookPanel(model: other.model, agentList: last), size: size, to: path(directory, "tabs-list-open-last.png"))

        // The badge reports its real place, so the list follows it whatever place it was opened with.
        let third = self.scenario()
        let middle = TabAgentListPresenter()
        middle.toggle(third.sessions[1].id, frame: CGRect(x: 430, y: 4, width: 28, height: 22))
        try render(NookPanel(model: third.model, agentList: middle), size: size, to: path(directory, "tabs-list-open-second.png"))
    }

    /// Six agents in one tab: the list scrolls under a fade instead of running past the island.
    func testRenderTabAgentListScrolls() throws {
        let directory = try renderDirectory()
        let scenario = scenario()
        scenario.busy.subagents = [
            agent("1", "Cat pet animation improvements", model: "sonnet", tools: 23, tokens: "41.2k", duration: "3m 12s", activity: "Read(Sources/Nook/Pet.swift)"),
            agent("2", "Review the notch layout and the tab row", kind: "Explore", model: "opus", tools: 9, tokens: "12k", duration: "1m 4s"),
            agent("3", "Write the release notes", kind: "general-purpose", model: "haiku", tools: 3, tokens: "3.1k", duration: "20s", activity: "Write(CHANGELOG.md)"),
            agent("4", "Profile the collapsed island", model: "sonnet", tools: 12, tokens: "30k", duration: "2m 8s", activity: "Bash(sample Nook 3 -file /tmp/nook.txt)"),
            agent("5", "Run the test suite", model: "haiku", state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s"),
            agent("6", "Check the migration", state: .failed, tools: 2, duration: "12s", note: "Falló"),
        ]
        let presenter = TabAgentListPresenter()
        presenter.toggle(scenario.busy.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try render(NookPanel(model: scenario.model, agentList: presenter), size: size, to: path(directory, "tabs-list-scrolls.png"))
    }

    /// Long names and tags: the type gives way first, then the model, and the name is cut only when it must be.
    func testRenderTabAgentListWithLongNames() throws {
        let directory = try renderDirectory()
        let scenario = scenario()
        scenario.busy.subagents = [
            agent("1", "Investigate why the collapsed island keeps redrawing the tab row every half second while nothing visible changes", model: "claude-sonnet-4-5-20250929",
                  tools: 23, tokens: "41.2k", duration: "3m 12s", activity: "Bash(grep -rn \"objectWillChange\" Sources/Nook --include=*.swift | head -50)"),
            agent("2", "Review the notch layout", kind: "claude-code-guide", model: "opus", state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s"),
            agent("3", "Summarise how the transcript follower reads the subagent records and what it does with background agents", kind: "general-purpose", model: "haiku",
                  state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s"),
            agent("4", "Check the migration", state: .failed, tools: 2, duration: "12s", note: "Interrumpido"),
        ]
        let presenter = TabAgentListPresenter()
        presenter.toggle(scenario.busy.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try render(NookPanel(model: scenario.model, agentList: presenter), size: size, to: path(directory, "tabs-list-long.png"))
    }

    /// The composer capsule's list now carries each agent's model and live activity too.
    func testRenderComposerListWithModels() throws {
        let directory = try renderDirectory()
        let agents = [agent("a", "Cat pet animation improvements", model: "sonnet", tools: 23, tokens: "41.2k", duration: "3m 12s", activity: "Read(Sources/Nook/Pet.swift)"),
                      agent("b", "Review the notch layout", kind: "Explore", model: "opus", tools: 9, tokens: "12k", duration: "1m 4s"),
                      agent("c", "Run the test suite", model: "haiku", state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s"),
                      agent("d", "Check the migration", state: .failed, tools: 2, duration: "12s", note: "Falló")]
        let view = ZStack(alignment: .topTrailing) {
            Color.black
            HStack { Spacer(); SubagentCapsule(agents: agents, alwaysVisible: true, initiallyOpen: true) }
                .padding(.trailing, 25).padding(.top, 187 + 9)
        }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        try render(view, size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), settle: 0.05, to: path(directory, "composer-list-models.png"))
    }

    /// The badges on their own, at the tab's size, in every state, on a selected and a resting tab.
    func testRenderBadgeStates() throws {
        let directory = try renderDirectory()
        func state(_ running: Int, failed: Int = 0, done: Int = 0, lingering: Bool = false) -> TabAgentState {
            TabAgentState((0..<running).map { agent("r\($0)", "r") } + (0..<failed).map { agent("f\($0)", "f", state: .failed) } + (0..<done).map { agent("d\($0)", "d", state: .done) },
                          lingering: lingering)
        }
        let states = [state(1), state(2), state(3, failed: 1), state(12), state(0, failed: 2, done: 1, lingering: true), state(0, done: 3, lingering: true)]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach([true, false], id: \.self) { selected in
                HStack(spacing: 14) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        HStack(spacing: 4) {
                            Text("nook").font(.system(size: 10, weight: selected ? .semibold : .regular))
                            TabAgentBadge(state: state, animated: false)
                        }.padding(.horizontal, 8).padding(.vertical, 5)
                            .background(TabTint.mint.color.opacity(selected ? 0.19 : 0.065), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                }
            }
        }.padding(16).frame(width: 640, height: 90, alignment: .topLeading).background(Color.black).environment(\.colorScheme, .dark)
        try render(view, size: NSSize(width: 640, height: 90), to: path(directory, "badge-states.png"))
    }
}
