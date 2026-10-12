import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the model button and its list to PNG for visual review: the chip among the others, the list open with what Claude's picker taught Nook, with
/// only the aliases, with a list from an older Claude Code, the chip while Claude works, and the whole row in the narrowest islands. Runs only when
/// NOOK_RENDER_DIR is set. (The chip's symbols, family by family, are in `ChipGlyphRenderTests`.) The screens are fixtures in the shapes Claude Code draws, read the way the app reads them.
@MainActor
final class ClaudeModelRenderTests: XCTestCase {
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
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The row settles in a few turns (its chips choose their words by the room the status leaves them).
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

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var menuOpen = false
        var highlight: Int? = nil
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, dismissals: RecapSeenStore(defaults: nil), modelMenuOpen: menuOpen, modelHighlight: highlight).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func makeModel() -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-model-render-" + UUID().uuidString)!)
        // Nothing here may reach a real terminal.
        model.commandSender = { _, _ in }
        model.keySender = { _, _ in }
        return model
    }

    private func session(_ model: AppModel, text: String) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    // MARK: Fixtures

    private func banner(model: String = "Sonnet 5.5", version: String = "2.1.290") -> [String] {
        ["▗ ▗   ▖ ▖  Claude Code v\(version)", "           \(model) with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
    }

    private func screen(model: String = "Sonnet 5.5", status: String? = nil, mode: String = "  ? for shortcuts") -> String {
        let lines = banner(model: model) + ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build y los cambios recientes.", "", "⏺ Read(apps/api/package.json)", "  ⎿  Read 64 lines", ""]
        return (lines + (status.map { [$0, ""] } ?? []) + [rule, "❯ ", rule, mode]).joined(separator: "\n")
    }

    /// What Claude's /model picker draws, as a dialog.
    private let picker = [" Select model", " Switch between Claude models. Applies to this session and future sessions.", "",
                          "   1. Default (recommended) ✔  Opus 4.6 with 1M context · Most capable for complex work", " ❯ 2. Sonnet                   Sonnet 5.5 · Best for everyday tasks",
                          "   3. Sonnet (1M context)      Sonnet 5.5 with 1M context · Billed as extra usage", "   4. Haiku                    Haiku 4.5 · Fastest for quick answers", "",
                          "   ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]

    private func learn(_ model: AppModel, version: String) throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(picker.joined(separator: "\n")))
        XCTAssertTrue(ClaudeModelStore.isModelPicker(prompt))
        model.models.learn(prompt, version: version, folder: nil)
    }

    private func render(_ name: String, text: String, widths: [Double] = [NotchGeometry.expandedWidth], open: Bool = false, highlight: Int? = nil, learned: String? = "2.1.290",
                        height: CGFloat = NotchGeometry.expandedHeight(topInset: 32), in directory: String) throws {
        let model = makeModel()
        if let learned { try learn(model, version: learned) }
        let session = session(model, text: text)
        for width in widths {
            let suffix = widths.count > 1 || width != NotchGeometry.expandedWidth ? "-\(Int(width))" : ""
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width, height: height, menuOpen: open, highlight: highlight)),
                      size: NSSize(width: width, height: height), to: url(directory, "\(name)\(suffix).png"))
        }
    }

    // MARK: The chip and the list

    func testRenderTheChipAmongTheOthers() throws {
        let directory = try renderDirectory()
        try render("model-chip", text: screen(), widths: [NotchGeometry.expandedWidth, 500, 440], in: directory)
        try render("model-chip-mode", text: screen(mode: "  ⏵⏵ accept edits on (shift+tab to cycle)"), widths: [NotchGeometry.expandedWidth, 500, 440], in: directory)
    }

    func testRenderTheListWithWhatClaudesPickerTaughtNook() throws {
        let directory = try renderDirectory()
        try render("model-menu", text: screen(), open: true, in: directory)
        try render("model-menu-keys", text: screen(), open: true, highlight: 1, in: directory)
        try render("model-menu-last", text: screen(), open: true, highlight: 5, in: directory)
        try render("model-menu-tall-keys", text: screen(), open: true, highlight: 2, height: NotchGeometry.expandedHeight(topInset: 32) + 120, in: directory)
        try render("model-menu", text: screen(), widths: [500, 440], open: true, in: directory)
        try render("model-menu-tall", text: screen(), open: true, height: NotchGeometry.expandedHeight(topInset: 32) + 120, in: directory)
    }

    func testRenderTheListWithOnlyTheAliasesAndWithAnOldOne() throws {
        let directory = try renderDirectory()
        try render("model-menu-aliases", text: screen(), open: true, learned: nil, in: directory)
        try render("model-menu-stale", text: screen(), open: true, learned: "2.1.280", in: directory)
        try render("model-menu-stale-440", text: screen(), widths: [440], open: true, learned: "2.1.280", in: directory)
    }

    func testRenderTheChipWhileClaudeWorks() throws {
        let directory = try renderDirectory()
        let working = "✶ Churning… (1m 2s · ↓ 3.4k tokens · thinking with high effort)"
        try render("model-blocked", text: screen(status: working), in: directory)
    }

    /// The longest model name and a long status, in the narrowest islands: the chips are symbols, so the status keeps the room.
    func testRenderTheRowWithALongStatus() throws {
        let directory = try renderDirectory()
        let long = "✶ Churning… (12m 48s · ↓ 187.4k tokens · thinking with xhigh effort)"
        try render("model-ladder", text: screen(model: "Opus 4.6 (1M context)", status: long, mode: "  ⏵⏵ accept edits on (shift+tab to cycle)"), widths: [NotchGeometry.expandedWidth, 500, 440], in: directory)
    }
}
