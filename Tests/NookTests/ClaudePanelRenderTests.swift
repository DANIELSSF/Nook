import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the island with a panel of Claude's open (/usage, a boxed dialog, a list) at each island size and text size, for
/// visual review. Runs only when NOOK_RENDER_DIR is set. The screens are in `ClaudePanelFixtures`.
@MainActor
final class ClaudePanelRenderTests: XCTestCase {
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
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    // MARK: Rendering

    /// The whole island at the size the settings give, with the panel open on its Claude tab.
    private func render(_ name: String, text: String, settings: DisplaySettings = DisplaySettings(), neck: CGFloat = 32, to directory: String,
                        configure: (AppModel, TerminalSession) -> Void = { _, _ in }) throws {
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.neckWithoutWindow = neck
        model.display = settings
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: "> /usage\n\n" + text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNotNil(session.panel, name)
        configure(model, session)
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("panel-\(name).png").path)
    }

    func testRenderPanelsAtEachIslandSize() throws {
        let directory = try renderDirectory()
        for preset in IslandPreset.allCases {
            try render("usage-\(preset.rawValue)", text: ClaudePanelFixtures.usage, settings: DisplaySettings().applying(preset), to: directory)
        }
        try render("short-normal", text: ClaudePanelFixtures.short, to: directory)
        try render("ruled-normal", text: ClaudePanelFixtures.ruled, to: directory)
        try render("boxed-normal", text: ClaudePanelFixtures.boxed, to: directory)
        try render("list-normal", text: ClaudePanelFixtures.list, to: directory)
        try render("boxed-compact", text: ClaudePanelFixtures.boxed, settings: DisplaySettings().applying(.compact), to: directory)
        try render("list-tall", text: ClaudePanelFixtures.list, settings: DisplaySettings().applying(.tall), to: directory)
    }

    func testRenderPanelsAtEachTextSize() throws {
        let directory = try renderDirectory()
        for size in [9.0, 14.0, 18.0] {
            var settings = DisplaySettings(); settings.chatSize = size
            try render("usage-text\(Int(size))", text: ClaudePanelFixtures.usage, settings: settings, to: directory)
            var tall = settings.applying(.tall)
            tall.chatSize = size
            try render("usage-text\(Int(size))-tall", text: ClaudePanelFixtures.usage, settings: tall, to: directory)
        }
        var big = DisplaySettings().applying(.compact); big.chatSize = 18
        try render("list-text18-compact", text: ClaudePanelFixtures.list, settings: big, to: directory)
    }
}
