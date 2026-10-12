import AppKit
import SwiftUI
import XCTest
@testable import Nook

private func sheetLabel(_ text: String, width: CGFloat) -> some View {
    Text(text).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
}

/// Renders the chips of the composer's row to PNG for visual review: each effort level and each model family as a symbol alone, state by state, the
/// four chips together, and the island's row at its widths with other models, levels and modes. Runs only when NOOK_RENDER_DIR is set. The sheets are
/// drawn at three times their size (the symbols are vectors) so they can be judged; the island's rows are at the size the app has.
@MainActor
final class ChipGlyphRenderTests: XCTestCase {
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

    // MARK: Each level, each family

    /// Each effort level as the chip draws it, at rest, with the pointer over it, with the mouse down and while it waits for Claude to confirm it.
    func testRenderEachEffortLevel() throws {
        let directory = try renderDirectory()
        let columns: [(String, ModeChipLook, Bool)] = [("en reposo", .resting, false), ("con el puntero", .hovered, false), ("pulsado", .pressed, false), ("pidiendo", .resting, true)]
        let rows: [(String, ClaudeEffort?)] = ClaudeEffort.allCases.map { ($0.title, $0) } + [("sin leer", nil)]
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                sheetLabel("", width: 54)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in sheetLabel(column.0, width: 52) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    sheetLabel(row.0, width: 54)
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        EffortChip(effort: row.1, asking: column.2, look: column.1) {}.frame(width: 52)
                    }
                }
            }
        }
        try sheet(content, size: CGSize(width: 330, height: 250), in: directory, as: "chips-effort-levels.png")
        try sheet(content, size: CGSize(width: 330, height: 250), scale: 1, in: directory, as: "chips-effort-levels-1x.png")
    }

    /// Each model family as the chip draws it (the list's own names are in the list), state by state.
    func testRenderEachModelFamily() throws {
        let directory = try renderDirectory()
        let looks: [(String, ModeChipLook, Bool, Bool, String?)] = [("en reposo", .resting, false, false, nil), ("con el puntero", .hovered, false, false, nil), ("pulsado", .pressed, false, false, nil),
                                                                    ("lista abierta", .resting, true, false, nil), ("esperando", .resting, false, true, nil),
                                                                    ("bloqueado", .resting, false, false, "Claude está trabajando; podrás cambiar el modelo cuando termine.")]
        let rows: [(String, String?)] = [("Opus", "Opus 4.6 (1M context)"), ("Sonnet", "Sonnet 5.5"), ("Haiku", "Haiku 4.5"), ("Fable", "Fable 1"), ("nueva", "Mythos 2"), ("sin leer", nil)]
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sheetLabel("", width: 46)
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in sheetLabel(look.0, width: 46) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    sheetLabel(row.0, width: 46)
                    ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                        ClaudeModelChip(model: row.1, open: look.2, blocked: look.4, waiting: look.3, look: look.1) {}.frame(width: 46)
                    }
                }
            }
        }
        try sheet(content, size: CGSize(width: 400, height: 230), in: directory, as: "chips-model-families.png")
        try sheet(content, size: CGSize(width: 400, height: 230), scale: 1, in: directory, as: "chips-model-families-1x.png")
    }

    /// The four chips as they stand in the row, for each mode, with a family and a level each (every family and every level shows somewhere).
    func testRenderTheWholeSet() throws {
        let directory = try renderDirectory()
        let modes: [ClaudeMode] = [.standard, ClaudeMode(kind: .auto, label: "auto mode on", hints: []), ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: []),
                                   ClaudeMode(kind: .plan, label: "plan mode on", hints: []), ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: []),
                                   ClaudeMode(kind: nil, label: "yolo mode on", hints: [])]
        let models: [String?] = ["Sonnet 5.5", "Opus 4.6", "Haiku 4.5", "Fable 1", "Mythos 2", nil]
        let efforts: [ClaudeEffort?] = [.medium, .max, .low, .high, .xhigh, nil]
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(modes.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    ClaudeModeChip(mode: modes[index]) {}
                    ClaudeModelChip(model: models[index]) {}
                    EffortChip(effort: efforts[index]) {}
                    UsageButton {}
                }
            }
        }
        try sheet(content, size: CGSize(width: 140, height: 230), in: directory, as: "chips-set.png")
        try sheet(content, size: CGSize(width: 140, height: 230), scale: 1, in: directory, as: "chips-set-1x.png")
    }

    // MARK: The row in the island

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, dismissals: RecapSeenStore(defaults: nil)).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func screen(model: String, effort: String, mode: String, status: String? = nil) -> String {
        let banner = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           \(model) with \(effort) effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
        let lines = banner + ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build y los cambios recientes.", "", "⏺ Read(apps/api/package.json)", "  ⎿  Read 64 lines", ""]
        return (lines + (status.map { [$0, ""] } ?? []) + [rule, "❯ ", rule, mode]).joined(separator: "\n")
    }

    private func renderIsland(_ name: String, _ text: String, widths: [Double], in directory: String) throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-chip-render-" + UUID().uuidString)!)
        model.commandSender = { _, _ in }
        model.keySender = { _, _ in }
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        for width in widths {
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width)), size: NSSize(width: width, height: NotchGeometry.expandedHeight(topInset: 32)),
                      to: url(directory, "\(name)-\(Int(width)).png"))
        }
    }

    /// The island's row with each family and some levels and modes, in the three widths: the status has the room the chips no longer take.
    func testRenderTheRowInTheIsland() throws {
        let directory = try renderDirectory()
        let widths: [Double] = [NotchGeometry.expandedWidth, 500, 440]
        try renderIsland("chips-island-sonnet-xhigh", screen(model: "Sonnet 5.5", effort: "xhigh", mode: "  ? for shortcuts"), widths: widths, in: directory)
        try renderIsland("chips-island-opus-max", screen(model: "Opus 4.6", effort: "max", mode: "  ⏵⏵ accept edits on (shift+tab to cycle)"), widths: widths, in: directory)
        try renderIsland("chips-island-haiku-low", screen(model: "Haiku 4.5", effort: "low", mode: "  ⏸ plan mode on (shift+tab to cycle)"), widths: widths, in: directory)
        try renderIsland("chips-island-fable-medium", screen(model: "Fable 1", effort: "medium", mode: "  ⏵⏵ auto mode on (shift+tab to cycle)"), widths: widths, in: directory)
        try renderIsland("chips-island-new-high", screen(model: "Mythos 2", effort: "high", mode: "  ⏵⏵ bypass permissions on (shift+tab to cycle)"), widths: widths, in: directory)
        // With Claude working, a long status: the model's chip waits, and the status line has room to tell what Claude does.
        try renderIsland("chips-island-working", screen(model: "Opus 4.6", effort: "high", mode: "  ? for shortcuts", status: "✶ Churning… (12m 48s · ↓ 187.4k tokens · thinking with high effort)"),
                         widths: widths, in: directory)
    }
}
