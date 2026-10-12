import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders what the island shows of Claude's start-up and state to PNG for visual review: the strip with its banner and warnings (closed and
/// open), the permission mode's chip in every mode and at the narrow widths, and the wait for background agents. Runs only when NOOK_RENDER_DIR
/// is set. The screens are fixtures with the shape Claude Code 2.1.29x draws, fed through the same reading the app uses.
@MainActor
final class SessionInfoRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The very first render of a run can come out empty; wait and draw again until something shows.
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The pane inside an island of `width`, with a 32 pt notch inset: the neck, the tab row and the pane stacked as in the app.
    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var draft: String? = nil
        var warningsOpen = false
        var promptState: SessionPane.PromptCardState = .options
        var dismissals = RecapSeenStore(defaults: nil)
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft, promptState: promptState, warningsOpen: warningsOpen, dismissals: dismissals).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    /// A model with preferences of its own: a test that changes the text size must not change the user's.
    private func makeModel() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-info-render-" + UUID().uuidString)!) }

    private func session(_ model: AppModel, text: String) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    // MARK: Fixtures

    private let banner = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
    private let sentence = "has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean, or only use * after the subcommand."

    private func warnings(_ rules: [String]) -> [String] {
        rules.flatMap { ["Permission allow rule (.claude/settings.json): \($0) \(sentence)", ""] }
    }

    /// A fresh session: the warnings and the banner Claude printed, an empty box under them.
    private func fresh(rules: [String] = [], mode: String? = "  ⏵⏵ auto mode on (shift+tab to cycle)") -> String {
        (warnings(rules) + banner + ["", rule, "❯ ", rule] + (mode.map { [$0] } ?? [])).joined(separator: "\n")
    }

    private let threeRules = ["Bash(pnpm --filter * exec prisma format*)", "Bash(pnpm --filter * exec prisma generate*)", "Bash(pnpm --filter * exec prisma migrate*)"]

    private func conversation(status: String? = nil, mode: String? = "  ⏵⏵ auto mode on (shift+tab to cycle)") -> String {
        let lines = banner + ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build y los cambios recientes.", "", "⏺ Read(apps/api/package.json)", "  ⎿  Read 64 lines", ""]
        return (lines + (status.map { [$0, ""] } ?? []) + [rule, "❯ ", rule] + (mode.map { [$0] } ?? [])).joined(separator: "\n")
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    // MARK: The strip

    func testRenderTheBannerAndItsWarnings() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        for (name, text, open) in [("banner", fresh(), false), ("warnings", fresh(rules: threeRules), false), ("warnings-open", fresh(rules: threeRules), true),
                                   ("warnings-one-open", fresh(rules: [threeRules[0]]), true), ("banner-chat", conversation(), false)] {
            let session = session(model, text: text)
            XCTAssertNotNil(session.banner, name)
            let island = Island(model: model, session: session, warningsOpen: open)
            try write(NSHostingView(rootView: island), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), to: url(directory, "info-\(name).png"))
        }
        // The same notice once it is dismissed: the banner stays, the pill is gone.
        let session = session(model, text: fresh(rules: threeRules))
        let dismissals = RecapSeenStore(defaults: nil)
        dismissals.dismiss(session.startupWarnings, in: session.id)
        XCTAssertTrue(dismissals.areDismissed(session.startupWarnings, in: session.id))
        try write(NSHostingView(rootView: Island(model: model, session: session, dismissals: dismissals)),
                  size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), to: url(directory, "info-warnings-dismissed.png"))
    }

    /// Narrow islands and a larger chat text: the line gives up its version and its plan before anything else, and the pill its words.
    func testRenderTheStripInNarrowIslandsAndWithBigText() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let session = session(model, text: fresh(rules: threeRules))
        for width in [500.0, 440.0] {
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width, warningsOpen: width == 440)),
                      size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)), to: url(directory, "info-warnings-\(Int(width)).png"))
        }
        model.display.chatSize = 16
        try write(NSHostingView(rootView: Island(model: model, session: session, height: NotchGeometry.expandedHeight(topInset: 32) + 60)),
                  size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + 60), to: url(directory, "info-warnings-bigtext.png"))
    }

    // MARK: The mode

    private func modeLine(_ words: String, glyph: String = "⏵⏵") -> String { "  \(glyph) \(words) (shift+tab to cycle)" }

    func testRenderEveryMode() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let working = "✶ Churning… (1m 2s · ↓ 3.4k tokens · thinking with high effort)"
        for (name, line, expected) in [("default", "  ? for shortcuts", nil), ("auto", modeLine("auto mode on"), ClaudeMode.Kind.auto), ("accept", modeLine("accept edits on"), .acceptEdits),
                                       ("plan", modeLine("plan mode on", glyph: "⏸"), .plan), ("bypass", modeLine("bypass permissions on"), .bypassPermissions),
                                       ("other", modeLine("yolo mode on"), nil)] {
            let session = session(model, text: conversation(status: working, mode: line))
            XCTAssertEqual(session.agentMode?.kind, expected, name)
            XCTAssertEqual(session.agentMode?.isDefault, name == "default", "Only a box with no mode named under it is the default mode: \(name)")
            try write(NSHostingView(rootView: Island(model: model, session: session)), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)),
                      to: url(directory, "info-mode-\(name).png"))
        }
        // The widest chip with the longest status, in the narrowest islands: the chip gives up its word before the status is squeezed out.
        let long = "✶ Churning… (12m 48s · ↓ 187.4k tokens · thinking with xhigh effort)"
        let tight = session(model, text: conversation(status: long, mode: modeLine("accept edits on")))
        for width in [500.0, 440.0] {
            try write(NSHostingView(rootView: Island(model: model, session: tight, width: width)), size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)),
                      to: url(directory, "info-mode-accept-\(Int(width)).png"))
        }
        // The default mode is on screen all the time, so it is the chip the narrow islands see most.
        let normal = session(model, text: conversation(status: long, mode: "  ? for shortcuts"))
        XCTAssertEqual(normal.agentMode?.isDefault, true)
        for width in [500.0, 440.0] {
            try write(NSHostingView(rootView: Island(model: model, session: normal, width: width)), size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)),
                      to: url(directory, "info-mode-default-\(Int(width)).png"))
        }
    }

    private var allModes: [ClaudeMode] {
        [.standard, ClaudeMode(kind: .auto, label: "auto mode on", hints: []), ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: []),
         ClaudeMode(kind: .plan, label: "plan mode on", hints: []), ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: []),
         ClaudeMode(kind: nil, label: "yolo mode on", hints: [])]
    }

    /// The six modes' chips on the composer's surface beside the chips that stand next to them, for judging colour and weight together.
    func testRenderTheChipsTogether() throws {
        let directory = try renderDirectory()
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(allModes.enumerated()), id: \.offset) { _, mode in
                HStack(spacing: 6) {
                    ClaudeModeChip(mode: mode) {}
                    ClaudeModelChip(model: "Sonnet 5.5") {}
                    EffortChip(effort: .xhigh) {}
                    UsageButton {}
                }
            }
        }.padding(18).frame(width: 400, alignment: .leading).composerSurface().padding(14).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        try write(NSHostingView(rootView: sheet), size: NSSize(width: 430, height: 340), to: url(directory, "info-mode-chips.png"))
    }

    /// What a click does to the chip, state by state: at rest, with the pointer over it, with the mouse down, waiting for the answer (it stays lit until
    /// the screen shows the new mode), and unable to be pressed (with the reason in its tooltip).
    func testRenderTheChipsStates() throws {
        let directory = try renderDirectory()
        let columns: [(String, ModeChipLook, String?)] = [("en reposo", .resting, nil), ("con el puntero", .hovered, nil), ("pulsado", .pressed, nil), ("esperando", .asked, nil),
                                                         ("bloqueado", .resting, "La terminal está cerrada.")]
        let shown = [allModes[0], allModes[1], allModes[2], allModes[3], allModes[4], allModes[5]]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in Text(column.0).font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading) }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, mode in
                HStack(spacing: 10) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        ClaudeModeChip(mode: mode, blocked: column.2, look: column.1) {}.frame(width: 78, alignment: .leading)
                    }
                }
            }
        }.padding(18).frame(width: 470, alignment: .leading).composerSurface().padding(14).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        try write(NSHostingView(rootView: sheet), size: NSSize(width: 500, height: 290), to: url(directory, "info-mode-states.png"))
    }

    // MARK: The wait for background agents

    func testRenderTheWaitForBackgroundAgents() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let mode = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage"
        let tree = ["", "  ⏺️ main", "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens", "  ○ fork  Charting echo failures in deliveries.log",
                    "4m 56s · ↓ 189.9k tokens", "  ○ fork  Finding AgentPrompt construction call sites", "4m 56s · ↓ 208.6k tokens"]
        func screen(_ count: Int, rows: [String]) -> String {
            (["⏺ Lancé los agentes en segundo plano.", "", "  Te aviso cuando termine cada agente.", "", "✻ Waiting for \(count) background agent\(count == 1 ? "" : "s") to finish", "", rule, "❯ ", rule, mode] + rows).joined(separator: "\n")
        }
        let three = session(model, text: screen(3, rows: tree))
        XCTAssertEqual(three.agentStatus?.background, 3)
        XCTAssertEqual(three.subagents.count, 3, "The list under the mode line feeds the agents.")
        for width in [NotchGeometry.expandedWidth, 500.0, 440.0] {
            try write(NSHostingView(rootView: Island(model: model, session: three, width: width)), size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)),
                      to: url(directory, "info-waiting-\(Int(width)).png"))
        }
        let one = session(model, text: screen(1, rows: Array(tree.prefix(4))))
        try write(NSHostingView(rootView: Island(model: model, session: one)), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)),
                  to: url(directory, "info-waiting-one.png"))
    }

    // MARK: The connection sheet

    /// What the sheet says now that a new terminal is always a tab of Terminal: no «Compartir» for a tab that is Terminal's, a word for another app
    /// the cat was dropped on, and the saved tmux session's own block for a session from before.
    func testRenderTheConnectionSheet() throws {
        let directory = try renderDirectory()
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28) + 220)
        // The cat dropped on another terminal app, with a tab of Terminal selected.
        let model = makeModel()
        _ = session(model, text: conversation())
        model.targetAppName = "iTerm2"
        model.connectionSheet = true
        try write(NSHostingView(rootView: NookPanel(model: model).environment(\.nookTintedGlass, false)), size: size, to: url(directory, "connection-other-app.png"))
        // A session saved from before (tmux), selected: its connection can still be copied.
        let saved = makeModel()
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-render-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-render", name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let legacy = TerminalSession(record: record, backend: backend, create: false)
        legacy.isRunning = true
        saved.sessions = [legacy]; saved.selectedID = legacy.id
        saved.expanded = true; saved.islandContentVisible = true
        saved.connectionSheet = true
        try write(NSHostingView(rootView: NookPanel(model: saved).environment(\.nookTintedGlass, false)), size: size, to: url(directory, "connection-saved-session.png"))
    }
}
