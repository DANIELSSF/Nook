import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders what a Nook session with Claude running in it looks like (its conversation mirrored, the way a Terminal tab's is), with
/// the queue, the effort control, the usage card and an attached image on it, for visual review. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class NookSessionRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func path(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// Mounts `view` in an offscreen window and writes it over black (an offscreen render leaves the tab row's scroll view white).
    private func render<V: View>(_ view: V, size: NSSize, settle: Double = 0.4, to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
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

    private func clearScrollBackgrounds(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false; scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    // MARK: Scenarios

    private var islandSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)) }

    /// A Nook session (tmux, nothing behind it: the process is `true`) with Claude on its pane, as `applyPane` reads it.
    private func nookSession(_ model: AppModel, screen: String, tint: TabTint = .mint, title: String = "Terminal", processes: [String] = ["claude"]) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-render-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-render-" + UUID().uuidString.prefix(6), name: title, kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.tint = tint
        session.applyPane(tty: "/dev/ttys0\(Int.random(in: 10...99))", processes: processes, text: screen)
        // The process behind the session is `true`, which ends at once and says so; the island shows a live one.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        session.isRunning = true
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        return session
    }

    private var conversation: [String] {
        ["> revisa por qué falla la prueba del notch", "",
         "⏺ Read(Sources/Nook/NotchController.swift)", "  ⎿  Read 610 lines", "",
         "⏺ Encontré la causa: el tamaño se calculaba antes de que la ventana existiera. Lo corrijo y vuelvo a correr la prueba.", ""]
    }

    private func screen(_ lines: [String], status: String? = nil) -> String {
        (lines + (status.map { [$0, ""] } ?? []) + [rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"]).joined(separator: "\n")
    }

    /// The island with a Nook session running Claude: its conversation, without Claude's box, and the composer of every agent tab.
    func testRenderNookSessionWithClaude() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        let session = nookSession(model, screen: screen(conversation, status: "✶ Warping… (3m 24s · thinking with max effort)"))
        // What the terminal itself holds must not show: it is laid out under the mirror, invisible.
        session.terminal.feed(text: "RAW TERMINAL TEXT THAT MUST NOT SHOW\r\n")
        XCTAssertTrue(session.mirrorsAgent)
        try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "nook-session-claude.png"))
    }

    /// Claude is working: what Claude holds in its queue stands grey after the conversation (also what was typed in its own terminal),
    /// and the message just sent stands in the user's colour, tagged while Nook still delivers it.
    func testRenderTheQueueAndAMessageBeingSent() throws {
        let directory = try renderDirectory()
        let record = "> revisa por qué falla la prueba del notch\n\n⏺ Read(Sources/Nook/NotchController.swift)\n  ⎿  Read 610 lines\n\n⏺ Voy a corregir el tamaño de la ventana y a volver a correr la prueba.\n\n"
        for (name, tint, sending, pending) in [("queue-sending", TabTint.mint, true, "ok, también actualiza el README"),
                                               ("queue-waiting", .rose, false, "ok, también actualiza el README")] {
            let model = AppModel(receivesSignals: false)
            let session = nookSession(model, screen: screen(conversation, status: "✶ Warping… (3m 24s · thinking with max effort)"), tint: tint)
            session.applyTranscript(record, recap: nil, queued: ["agrega una prueba para el tamaño de la ventana", "y avísame cuando termine, con un resumen corto de lo que cambió"])
            session.showPending(pending)
            session.sending = sending
            try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "\(name).png"))
        }
    }

    /// The same, with the message Claude holds being the one Nook sent: it stands once, queued, and the placeholder is not doubled.
    func testRenderASentMessageThatClaudeHolds() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        let session = nookSession(model, screen: screen(conversation, status: "✶ Warping… (3m 24s · thinking with max effort)"), tint: .blue)
        session.applyTranscript("> revisa por qué falla la prueba del notch\n\n⏺ Voy a corregir el tamaño de la ventana.\n\n", recap: nil, queued: [])
        session.showPending("y el notch")
        session.applyTranscript(nil, recap: nil, queued: ["y el notch"])
        XCTAssertTrue(session.pendingQueued)
        try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "queue-held.png"))
    }

    /// The session pane inside the island, the way `PanelRenderTests` lays it out, with the preview states a render needs (a draft, the key
    /// strip, the levels out, an attached image).
    private struct PaneIsland: View {
        var model: AppModel
        var session: TerminalSession
        var draft = ""
        var keysOpen = false
        var effortOpen = false
        var attachments: [String]? = nil
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 28)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft, keysOpen: keysOpen, attachments: attachments, effortOpen: effortOpen).id(session.id)
            }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28), alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .overlay { IslandRim(tint: session.tint) }
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func claudeWithEffort(_ model: AppModel, effort: ClaudeEffort?, tint: TabTint = .mint) -> TerminalSession {
        let said = effort.map { ["  ⎿  Set effort level to \($0.rawValue) (saved as your default for new sessions)", ""] } ?? []
        let session = nookSession(model, screen: screen(conversation + said), tint: tint)
        XCTAssertEqual(session.effort, effort)
        return session
    }

    /// Claude's controls in the composer's bottom row: the chip with the level it reported, the usage button, the levels out in the row.
    func testRenderTheEffortControl() throws {
        let directory = try renderDirectory()
        for (name, effort, effortOpen, keysOpen, tint) in [("effort-chip", ClaudeEffort.high, false, false, TabTint.mint), ("effort-unknown", nil, false, false, .mint),
                                                           ("effort-max-rose", .max, false, false, .rose), ("effort-picker", .xhigh, true, false, .mint),
                                                           ("effort-picker-blue", .low, true, false, .blue), ("effort-keys-open", .high, false, true, .mint)] {
            let model = AppModel(receivesSignals: false)
            let session = claudeWithEffort(model, effort: effort, tint: tint)
            try render(PaneIsland(model: model, session: session, keysOpen: keysOpen, effortOpen: effortOpen), size: islandSize, to: path(directory, "\(name).png"))
        }
    }

    /// The levels unfolding out of the chip's side: the controls row at points of the transition from 0 (shut) to 1 (open), one row each over
    /// the island's black. The status line and the chips fade as the levels rise in turn, the item beside the chip first.
    func testRenderTheLevelsUnfolding() throws {
        let directory = try renderDirectory()
        struct Frames: View {
            var effort: ClaudeEffort
            var body: some View {
                VStack(spacing: 8) {
                    ForEach([0.0, 0.1, 0.2, 0.3, 0.4, 0.55, 0.7, 0.85, 1.0], id: \.self) { progress in
                        HStack(spacing: 10) {
                            ZStack(alignment: .leading) {
                                HStack(spacing: 10) {
                                    Text("Claude · en vivo · ↵ enviar").font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                    HStack(spacing: 6) {
                                        EffortChip(effort: effort) {}
                                        UsageButton {}
                                    }.layoutPriority(1)
                                }.modifier(EffortClosedFade(unfold: progress))
                                EffortPicker(current: effort, highlighted: effort, onPick: { _ in }, onClose: {}).modifier(EffortUnfold(unfold: progress))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.09)).frame(width: 28, height: 28) } }
                        }.padding(.leading, 13).padding(.trailing, 6)
                    }
                }.padding(.vertical, 10).padding(.horizontal, 15).frame(width: NotchGeometry.expandedWidth).background(Color.black)
                    .tabTint(.mint).environment(\.colorScheme, .dark)
            }
        }
        for (name, effort) in [("unfold-high", ClaudeEffort.high), ("unfold-max", .max)] {
            try render(Frames(effort: effort), size: NSSize(width: NotchGeometry.expandedWidth, height: 9 * 36 + 28), to: path(directory, "\(name).png"))
        }
    }

    /// Claude's /usage as the card of its own: Sample's earlier screens in two colours, and a panel that is not usage (it keeps the generic rows). The card at
    /// each island size, with the panel of Claude Code 2.1.293, is in `UsageCardRenderTests`.
    func testRenderTheUsageCard() throws {
        let directory = try renderDirectory()
        struct Card: View {
            var text: String
            var tint: TabTint = .mint
            var body: some View {
                ClaudePanelCard(text: text).tabTint(tint)
                    .frame(width: NotchGeometry.expandedWidth - 30, height: 206).padding(15)
                    .background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
            }
        }
        let size = NSSize(width: NotchGeometry.expandedWidth, height: 236)
        for (name, text, tint) in [("usage-narrow", ClaudeUsageTests.narrow, TabTint.mint), ("usage-full", ClaudePanelFixtures.usage, .mint),
                                   ("usage-full-blue", ClaudePanelFixtures.usage, .blue), ("usage-short", ClaudePanelFixtures.short, .rose), ("usage-not", ClaudePanelFixtures.list, .mint)] {
            try render(Card(text: text, tint: tint), size: size, to: path(directory, "\(name).png"))
        }
    }

    /// The whole island with Claude's usage panel open in a Nook session.
    func testRenderTheIslandWithTheUsagePanelOpen() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        let session = nookSession(model, screen: ClaudePanelFixtures.usage, tint: .blue)
        XCTAssertNotNil(session.panel)
        try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "usage-island.png"))
    }

    /// An image pasted into the message: a thumbnail above the field, alone and with words and a second image; the send button is live
    /// with only an image to send.
    func testRenderTheAttachedImages() throws {
        let directory = try renderDirectory()
        let first = try AttachmentsTests.writeImage(named: "imagen-20261004-111500.png", width: 1280, height: 800)
        let second = try AttachmentsTests.writeImage(named: "imagen-20261004-111512.png", width: 600, height: 900)
        for (name, draft, files, tint) in [("attach-one", "", [first], TabTint.mint), ("attach-two", "¿qué pasa en esta captura?", [first, second], .rose)] {
            let model = AppModel(receivesSignals: false)
            let session = nookSession(model, screen: screen(conversation), tint: tint)
            try render(PaneIsland(model: model, session: session, draft: draft, attachments: files), size: islandSize, to: path(directory, "\(name).png"))
        }
    }

    /// A Nook session with only a shell keeps showing its terminal.
    func testRenderNookSessionWithAShell() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        let session = nookSession(model, screen: "", processes: ["/bin/zsh -l"])
        session.terminal.feed(text: "sample@mac ~ % ls\r\nREADME.md  Sources  Tests\r\nsample@mac ~ % ")
        XCTAssertFalse(session.mirrorsAgent)
        try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "nook-session-shell.png"))
    }
}
