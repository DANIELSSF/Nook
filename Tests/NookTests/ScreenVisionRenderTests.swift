import AppKit
import SwiftUI
import XCTest
@testable import Nook

private func sheetLabel(_ text: String, width: CGFloat) -> some View {
    Text(text).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
}

/// Renders screen vision's UI to PNG for visual review: the composer's chip in its states and its place in the island's row, the settings tab, and the cue.
/// Runs only when NOOK_RENDER_DIR is set. The chip and the cue are drawn at three times their size (they are vectors) as well as at the size the app has.
@MainActor
final class ScreenVisionRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render screen vision's UI.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, to path: String, background: NSColor = .black) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = background
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            host.layoutSubtreeIfNeeded()
        }
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// A sheet of `size` at `scale` times that, on the island's black and the composer's surface.
    private func sheet(_ content: some View, size: CGSize, scale: CGFloat = 3, in directory: String, as name: String) throws {
        let framed = content.padding(14).frame(width: size.width, height: size.height, alignment: .topLeading).composerSurface().padding(8)
            .frame(width: size.width + 16, height: size.height + 16, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading).frame(width: (size.width + 16) * scale, height: (size.height + 16) * scale, alignment: .topLeading).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        try write(NSHostingView(rootView: framed), size: NSSize(width: (size.width + 16) * scale, height: (size.height + 16) * scale), to: url(directory, name))
    }

    // MARK: The chip

    func testRenderTheChipInEachState() throws {
        let directory = try renderDirectory()
        let off = try ScreenVisionUIFixture.vision(attach: false), on = try ScreenVisionUIFixture.vision(attach: true)
        let looks: [(String, ScreenVisionChipLook)] = [("en reposo", .resting), ("con el puntero", .hovered), ("pulsado", .pressed), ("esperando", .busy), ("captura", .flash)]
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                sheetLabel("", width: 66)
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in sheetLabel(look.0, width: 66) }
            }
            ForEach([("sin adjuntar", off), ("adjuntando", on)], id: \.0) { row in
                HStack(spacing: 10) {
                    sheetLabel(row.0, width: 66)
                    ForEach(Array(looks.enumerated()), id: \.offset) { _, look in ScreenVisionChip(vision: row.1, agent: .claude, look: look.1).frame(width: 66) }
                }
            }
            // The island's seven tab colours, with the chip on.
            HStack(spacing: 8) {
                sheetLabel("colores", width: 66)
                ForEach(TabTint.allCases, id: \.self) { tint in ScreenVisionChip(vision: on, agent: .claude).environment(\.tabTint, tint) }
            }
        }
        try sheet(content, size: CGSize(width: 440, height: 130), in: directory, as: "sv-chip-states.png")
        try sheet(content, size: CGSize(width: 440, height: 130), scale: 1, in: directory, as: "sv-chip-states-1x.png")
    }

    /// The chip beside the others as the row has them, off and on, with every other chip in its usual state.
    func testRenderTheChipAmongTheOthers() throws {
        let directory = try renderDirectory()
        let off = try ScreenVisionUIFixture.vision(attach: false), on = try ScreenVisionUIFixture.vision(attach: true)
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach([off, on], id: \.attachToMessages) { vision in
                HStack(spacing: 6) {
                    ScreenVisionChip(vision: vision, agent: .claude)
                    ClaudeModeChip(mode: ClaudeMode(kind: .auto, label: "auto mode on", hints: [])) {}
                    ClaudeModelChip(model: "Sonnet 5.5") {}
                    EffortChip(effort: .high) {}
                    UsageButton {}
                }
            }
            HStack(spacing: 6) {
                ScreenVisionChip(vision: on, agent: .claude)
                ClaudeModeChip(mode: .standard) {}
                ClaudeModelChip(model: "Opus 4.6") {}
                EffortChip(effort: .max) {}
                UsageButton {}
            }
        }
        try sheet(content, size: CGSize(width: 190, height: 110), in: directory, as: "sv-chip-set.png")
        try sheet(content, size: CGSize(width: 190, height: 110), scale: 1, in: directory, as: "sv-chip-set-1x.png")
    }

    // MARK: The row in the island

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var keysOpen = false
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, keysOpen: keysOpen, dismissals: RecapSeenStore(defaults: nil)).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    func testRenderTheRowInTheIsland() throws {
        let directory = try renderDirectory()
        let widths: [Double] = [NotchGeometry.expandedWidth, 500, 440]
        let working = ScreenVisionUIFixture.claudeScreen(status: "✶ Churning… (12m 48s · ↓ 187.4k tokens · thinking with high effort)", mode: "  ? for shortcuts")
        let scenarios: [(String, String, String, Bool, Bool, Bool)] = [
            ("claude-off", "claude", ScreenVisionUIFixture.claudeScreen(), false, true, false),
            ("claude-on", "claude", ScreenVisionUIFixture.claudeScreen(), true, true, false),
            ("claude-working", "claude", working, true, true, false),
            ("claude-keys", "claude", ScreenVisionUIFixture.claudeScreen(), true, true, true),
            ("codex-off", "codex", ScreenVisionUIFixture.codexScreen, false, true, false),
            ("codex-on", "codex", ScreenVisionUIFixture.codexScreen, true, true, false),
            ("claude-setting-off", "claude", ScreenVisionUIFixture.claudeScreen(), true, false, false),
        ]
        for (name, agent, text, attach, enabled, keys) in scenarios {
            let vision = try ScreenVisionUIFixture.vision(enabled: enabled, attach: attach)
            let model = ScreenVisionUIFixture.model(vision)
            let session = ScreenVisionUIFixture.session(in: model, agent: agent, text: text)
            for width in widths {
                try write(NSHostingView(rootView: Island(model: model, session: session, width: width, keysOpen: keys)), size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)),
                          to: url(directory, "sv-row-\(name)-\(Int(width)).png"))
            }
        }
    }

    // MARK: The settings

    private func card(_ name: String, tab: SettingsTab = .screen, vision: ScreenVision, states: [NookPermission: NookPermission.State], screen: CGSize = CGSize(width: 1512, height: 982),
                      in directory: String) throws {
        let model = ScreenVisionUIFixture.model(vision)
        model.settingsTab = tab
        let permissions = ScreenVisionUIFixture.permissions(states)
        let view = SettingsCard(model: model, screen: screen, topInset: 32, permissions: permissions).padding(30).background(Color(white: 0.3))
        let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
        try write(host, size: host.fittingSize, to: url(directory, "\(name).png"))
    }

    private let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]

    func testRenderTheSettingsTab() throws {
        let directory = try renderDirectory()
        // Off: the switch, the three lines and the note.
        try card("sv-tab-off", vision: try ScreenVisionUIFixture.vision(enabled: false), states: granted, in: directory)
        // The normal day: on, allowed, the tool in both folders.
        let ready = try ScreenVisionUIFixture.vision(attach: true)
        ScreenVisionUIFixture.started(ready)
        try card("sv-tab-ready", vision: ready, states: granted, in: directory)
        // Just turned on: macOS has not been asked, and the tool is still being added.
        let slow = BlockingRegistrar()
        let working = try ScreenVisionUIFixture.vision(registrar: slow)
        working.start(serving: false)
        try card("sv-tab-new", vision: working, states: granted.merging([.screenRecording: .notAsked]) { $1 }, in: directory)
        slow.release()
        // The first setup once it is done: the tool is in, Claude's open sessions need a restart, and macOS has still not been asked: the tallest the tab gets.
        let first = try ScreenVisionUIFixture.vision(attach: true)
        ScreenVisionUIFixture.started(first)
        try card("sv-tab-first-time", vision: first, states: granted.merging([.screenRecording: .notAsked]) { $1 }, in: directory)
        // Refused, and the tool could not be added (Claude Code is not installed).
        let failing = FakeRegistrar()
        failing.registerResult = .failure(ScreenVisionRegistrationError.claudeNotFound(manual: "claude mcp add --scope user --transport stdio nook-screen -- '/Users/sample/Library/Application Support/Nook/nook-hook' --mcp-screen"))
        let failed = try ScreenVisionUIFixture.vision(registrar: failing)
        ScreenVisionUIFixture.started(failed)
        try card("sv-tab-failed", vision: failed, states: granted.merging([.screenRecording: .denied]) { $1 }, in: directory)
        // Claude's open sessions need a restart to see the tool.
        let added = try ScreenVisionUIFixture.vision(attach: true)
        ScreenVisionUIFixture.started(added)
        XCTAssertTrue(added.needsClaudeRestart)
        try card("sv-tab-restart", vision: added, states: granted.merging([.screenRecording: .unknown]) { $1 }, in: directory)
        // A 13-inch screen with everything out: the tab scrolls instead of running off it.
        try card("sv-tab-short", vision: added, states: granted.merging([.screenRecording: .notAsked]) { $1 }, screen: CGSize(width: 1280, height: 720), in: directory)
        // The tab bar with four tabs, on another tab, and the dot on "Pantalla".
        try card("sv-tabs-island-dot", tab: .island, vision: added, states: granted.merging([.screenRecording: .notAsked]) { $1 }, in: directory)
        try card("sv-tabs-permissions", tab: .permissions, vision: ready, states: granted.merging([.automation: .notAsked]) { $1 }, in: directory)
    }

    // MARK: The cue

    private func capture(_ origin: ScreenVisionOrigin, screens: Int = 1) -> ScreenVisionCapture {
        let shot = ScreenShot(path: "/tmp/nook-501/images/pantalla-20261007-140322.png", mimeType: "image/png", display: "Pantalla integrada", width: 1512, height: 982, date: ScreenVisionFixture.date)
        return ScreenVisionCapture(date: ScreenVisionFixture.date, origin: origin, shots: Array(repeating: shot, count: screens))
    }

    func testRenderTheCuePill() throws {
        let directory = try renderDirectory()
        let styles: [(String, ScreenVisionCapture, TabTint)] = [("Claude", capture(.claude), .mint), ("Claude, dos pantallas", capture(.claude, screens: 2), .mint),
                                                                 ("mensaje", capture(.composer), .mint), ("mensaje, pestaña lavanda", capture(.composer), .lavender)]
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(styles.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 12) {
                    sheetLabel(entry.0, width: 110)
                    ScreenVisionCuePill(style: ScreenVisionCueStyle(entry.1), tint: entry.2, entered: true)
                }
            }
        }
        try sheet(content, size: CGSize(width: 400, height: 170), in: directory, as: "sv-cue-pills.png")
        try sheet(content, size: CGSize(width: 400, height: 170), scale: 1, in: directory, as: "sv-cue-pills-1x.png")
    }

    /// The pill where it hangs: under the collapsed island (a notch's width and its two wings), and under the open one, over a desktop.
    func testRenderTheCueUnderTheIsland() throws {
        let directory = try renderDirectory()
        let desktop = LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.36, green: 0.3, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        struct Collapsed: View {
            var capture: ScreenVisionCapture
            var desktop: LinearGradient
            var body: some View {
                VStack(spacing: ScreenVisionCue.gap) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(Color.black).frame(width: 240, height: 38)
                        .overlay { Circle().fill(Color(white: 0.12)).frame(width: 8, height: 8) }
                    ScreenVisionCuePill(style: ScreenVisionCueStyle(capture), tint: .mint, entered: true)
                }.frame(width: 380, height: 110, alignment: .top).background(desktop)
            }
        }
        for origin in [ScreenVisionOrigin.claude, .composer] {
            try write(NSHostingView(rootView: Collapsed(capture: capture(origin), desktop: desktop)), size: NSSize(width: 380, height: 110), to: url(directory, "sv-cue-collapsed-\(origin.rawValue).png"))
        }
        // The open island, and the pill just under its bottom edge.
        let vision = try ScreenVisionUIFixture.vision(attach: true)
        let model = ScreenVisionUIFixture.model(vision)
        let session = ScreenVisionUIFixture.session(in: model)
        for origin in [ScreenVisionOrigin.claude, .composer] {
            let island = Island(model: model, session: session)
            let view = VStack(spacing: ScreenVisionCue.gap) {
                island
                ScreenVisionCuePill(style: ScreenVisionCueStyle(capture(origin)), tint: session.tint, entered: true)
            }.frame(width: NotchGeometry.expandedWidth + 40, height: NotchGeometry.expandedHeight(topInset: 32) + 60, alignment: .top).background(desktop)
            try write(NSHostingView(rootView: view), size: NSSize(width: NotchGeometry.expandedWidth + 40, height: NotchGeometry.expandedHeight(topInset: 32) + 60),
                      to: url(directory, "sv-cue-open-\(origin.rawValue).png"))
        }
    }
}
