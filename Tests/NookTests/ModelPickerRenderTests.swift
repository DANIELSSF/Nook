import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the model button's list and Claude's own /model picker (its card) to PNG for visual review, with Sample's twelve models (Claude Code 2.1.290,
/// his picker of 2026-10-06): the list at the island's widths and in a taller island, with the model in use on a row in the middle, with a list that lacks
/// rows or is old, and the picker's card with its real rows. Runs only when NOOK_RENDER_DIR is set. The catalog is a file in a home of the test's own, as Claude
/// Code writes it, so nothing of this Mac's reaches the pictures.
@MainActor
final class ModelPickerRenderTests: XCTestCase {
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
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            host.layoutSubtreeIfNeeded()
        }
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            clearScrollBackgrounds(host)
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// An offscreen render paints a scroll view white where the app has the island's black behind it.
    private func clearScrollBackgrounds(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false; scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    // MARK: Fixtures

    private func catalogHome(selected: String = "claude-opus-5-5", stale: Bool = false, withList: Bool = true) throws -> URL {
        try ModelCatalogFixture.home(selected: selected, stale: stale, withList: withList)
    }

    /// The screen of Sample's picker (imagen-06102026042015), transcribed as `ClaudeDialogTests` has it.
    private var picker: [String] {
        ["⏺ Listo.", "", rule, " Select model",
         " Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with",
         " --model.", "",
         "    1.  Default (recommended)  Sonnet 5.5 · Efficient for routine tasks",
         " ❯  2.  Opus 5.5 ✔             For complex work and everyday tasks",
         "    3.  Fable 5.1              For your toughest challenges",
         "    4.  Sonnet 5.5             Most efficient for simpler tasks",
         "    5.  Haiku 4.5              Fastest for quick answers",
         "    6.  Sonnet 5               Efficient for routine tasks",
         "    7.  Opus 5                 Best for everyday, complex tasks",
         "    8.  Fable 5                Most capable for your hardest and longest-running tasks",
         " ↓  9.  Opus 4.8               Best for everyday, complex tasks",
         "    … +3 models", "",
         " ● xHigh effort ←/→ to adjust", "",
         " Enter to set as default · s to use this session only · Esc to cancel"]
    }

    /// The screen of a Claude tab (Sonnet 5.5 is its model, its effort xhigh) that is not asking anything.
    private func conversation(model: String = "Opus 5.5") -> String {
        let banner = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           \(model) with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
        let lines = banner + ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build y los cambios recientes.", "", "⏺ Read(apps/api/package.json)", "  ⎿  Read 64 lines", ""]
        return (lines + [rule, "❯ ", rule, "  ? for shortcuts"]).joined(separator: "\n")
    }

    private func makeModel(home: URL) -> AppModel {
        let defaults = UserDefaults(suiteName: "nook-picker-render-" + UUID().uuidString)!
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.models = ClaudeModelStore(defaults: defaults, home: home)
        // Nothing here may reach a real terminal.
        model.commandSender = { _, _ in }
        model.keySender = { _, _ in }
        return model
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

    private func session(_ model: AppModel, text: String) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// Claude's picker as the app learns it: its rows fill in the descriptions Claude Code's list leaves out and "Default"'s own.
    private func learnPicker(_ model: AppModel) throws {
        let prompt = try XCTUnwrap(AgentPrompt.parse(picker.joined(separator: "\n")))
        model.models.learn(prompt, version: "2.1.290", folder: nil)
    }

    private func render(_ name: String, text: String, home: URL, learn: Bool = true, widths: [Double] = [NotchGeometry.expandedWidth], menuOpen: Bool = false, highlight: Int? = nil,
                        extraHeight: CGFloat = 0, in directory: String) throws {
        let model = makeModel(home: home)
        if learn { try learnPicker(model) }
        let session = session(model, text: text)
        for width in widths {
            let height = NotchGeometry.expandedHeight(topInset: 32) + extraHeight
            let suffix = widths.count > 1 || width != NotchGeometry.expandedWidth ? "-\(Int(width))" : ""
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width, height: height, menuOpen: menuOpen, highlight: highlight)),
                      size: NSSize(width: width, height: height), to: url(directory, "\(name)\(extraHeight > 0 ? "-tall" : "")\(suffix).png"))
        }
    }

    // MARK: The list

    /// Sample's twelve models, the one in use on the second row: at the island's widths and in a taller island.
    func testRenderTheListWithTheTwelveModels() throws {
        let directory = try renderDirectory()
        let home = try catalogHome()
        try render("picker-list", text: conversation(), home: home, widths: [NotchGeometry.expandedWidth, 500, 440], menuOpen: true, in: directory)
        try render("picker-list", text: conversation(), home: home, menuOpen: true, extraHeight: 120, in: directory)
        try render("picker-list", text: conversation(), home: home, widths: [440], menuOpen: true, extraHeight: 120, in: directory)
    }

    /// The model in use in the middle of the list (Haiku 4.5, the fifth), another row chosen: the list opens at the one in use, and the buttons are live.
    func testRenderTheListWithTheModelInUseInTheMiddleAndARowChosen() throws {
        let directory = try renderDirectory()
        let home = try catalogHome(selected: "claude-haiku-4-5-20251001")
        try render("picker-list-middle", text: conversation(model: "Haiku 4.5"), home: home, widths: [NotchGeometry.expandedWidth, 440], menuOpen: true, highlight: 5, in: directory)
        try render("picker-list-middle", text: conversation(model: "Haiku 4.5"), home: home, menuOpen: true, highlight: 5, extraHeight: 120, in: directory)
    }

    /// Claude Code's own list is not on disk: the rows Nook saw in the picker (nine) and Claude's aliases, with the note that three of the picker's rows are
    /// missing and the row that opens Claude's picker; and a list past the time Claude would fetch it again.
    func testRenderTheListThatLacksRowsAndTheOneThatIsOld() throws {
        let directory = try renderDirectory()
        try render("picker-list-incomplete", text: conversation(), home: try catalogHome(withList: false), widths: [NotchGeometry.expandedWidth, 440], menuOpen: true, in: directory)
        try render("picker-list-incomplete", text: conversation(), home: try catalogHome(withList: false), menuOpen: true, extraHeight: 120, in: directory)
        try render("picker-list-stale", text: conversation(), home: try catalogHome(stale: true), widths: [NotchGeometry.expandedWidth, 440], menuOpen: true, in: directory)
    }

    /// With no list at all: only Claude's aliases and the way to Claude's picker.
    func testRenderTheListWithOnlyTheAliases() throws {
        let directory = try renderDirectory()
        try render("picker-list-aliases", text: conversation(), home: try catalogHome(withList: false), learn: false, menuOpen: true, in: directory)
    }

    /// Claude is working: the chip waits (dimmed, its tooltip says why) and the list is not offered.
    func testRenderTheRowWhileClaudeWorks() throws {
        let directory = try renderDirectory()
        let working = conversation().replacingOccurrences(of: "  ⎿  Read 64 lines\n", with: "  ⎿  Read 64 lines\n\n✶ Churning… (1m 2s · ↓ 3.4k tokens · thinking with high effort)\n")
        try render("picker-blocked", text: working, home: try catalogHome(), widths: [NotchGeometry.expandedWidth, 440], in: directory)
    }

    // MARK: Claude's picker

    /// Claude's own picker on the tab: the card with the rows of the list (Claude Code's own, twelve, where the picker shows nine), the effort and the two
    /// buttons; then with only the nine rows the picker shows (Claude Code's list not on disk), with its "… +3 models".
    func testRenderClaudesPickerAsACard() throws {
        let directory = try renderDirectory()
        let text = picker.joined(separator: "\n")
        try render("picker-card", text: text, home: try catalogHome(), widths: [NotchGeometry.expandedWidth, 500, 440], in: directory)
        try render("picker-card", text: text, home: try catalogHome(), extraHeight: 120, in: directory)
        try render("picker-card", text: text, home: try catalogHome(), widths: [440], extraHeight: 120, in: directory)
        try render("picker-card-nine", text: text, home: try catalogHome(withList: false), extraHeight: 120, in: directory)
        // Tall enough for every row, down to the line that says three more are in the picker.
        try render("picker-card-nine-full", text: text, home: try catalogHome(withList: false), extraHeight: 300, in: directory)
        try render("picker-card-full", text: text, home: try catalogHome(), extraHeight: 300, in: directory)
        try render("picker-card-nine", text: text, home: try catalogHome(withList: false), widths: [NotchGeometry.expandedWidth, 440], in: directory)
    }
}
