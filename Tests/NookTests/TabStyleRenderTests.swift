import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders what a tab's colour and icon do to the island, for visual review: the whole island in every colour, the question's card,
/// the "/" menu and the drop outline in some, every icon in every colour and at several moments of its movement, the tabs with the
/// icons on them, and the editor that chooses them. Runs only when NOOK_RENDER_DIR is set.
///
/// An offscreen render shows the send button's glass blank (see `PanelRenderTests`), so the button is judged from a flat swatch drawn
/// from the same colours (`testRenderSendButtonColours`).
@MainActor
final class TabStyleRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func path(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// Mounts `view` in an offscreen window and writes it composited over black (an offscreen render leaves the tab row's scroll view
    /// white, where the app has the island's black behind it).
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

    private var conversation: String {
        ["> pásame el estado de las pruebas del panel", "",
         "⏺ Las pruebas pasan: 647 en total, 54 omitidas.", "",
         "> y revisa que el botón de enviar tome el color de la pestaña", "",
         "⏺ Listo. Cada pestaña lleva su color en el botón, en tus mensajes y en el borde de la isla.", "",
         rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    private func session(_ model: AppModel, _ title: String, _ tty: String, tint: TabTint = .mint, icon: TabIcon = .dot, text: String? = nil, working: Bool = false,
                         processes: [String] = ["login", "-zsh", "claude"]) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: processes, busy: false, selected: true,
                                      text: text ?? conversation)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        session.icon = icon
        if working { session.agentStatus = ClaudeStatus(glyph: "✶", text: "Churning… (1m 2s · esc to interrupt)", working: true) }
        return session
    }

    private var islandSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)) }

    /// The whole island with `tint` on its selected tab and two other tabs beside it.
    private func island(tint: TabTint, icon: TabIcon, text: String? = nil) -> (AppModel, TerminalSession) {
        let model = AppModel(receivesSignals: false)
        let mine = session(model, "nook", "/dev/ttys090", tint: tint, icon: icon, text: text, working: true)
        let other = session(model, "api", "/dev/ttys091", tint: .blue, icon: .bars, working: false)
        let docs = session(model, "docs", "/dev/ttys092", tint: .rose, icon: .spark, working: true)
        model.sessions = [mine, other, docs]
        model.selectedID = mine.id
        model.expanded = true; model.islandContentVisible = true
        return (model, mine)
    }

    /// The island in each of the seven colours, each with a different icon so every one is seen on a selected tab.
    func testRenderIslandInEveryColour() throws {
        let directory = try renderDirectory()
        let icons = TabIcon.allCases
        for (index, tint) in TabTint.allCases.enumerated() {
            let (model, _) = island(tint: tint, icon: icons[index % icons.count])
            try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize,
                       to: path(directory, "tint-island-\(tint.rawValue).png"))
        }
    }

    /// The question's card, its highlighted option and its surface, in three colours.
    func testRenderQuestionCardInColours() throws {
        let directory = try renderDirectory()
        let permission = ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
                          " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        for tint in [TabTint.mint, .blue, .rose, .sand] {
            let (model, _) = island(tint: tint, icon: .half, text: permission)
            try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize,
                       to: path(directory, "tint-question-\(tint.rawValue).png"))
        }
    }

    /// The "/" menu and the drop outline in two colours.
    func testRenderSlashMenuAndDropOutlineInColours() throws {
        let directory = try renderDirectory()
        for tint in [TabTint.blue, .peach] {
            let (model, mine) = island(tint: tint, icon: .gem)
            model.fileDrop.files = 0
            try render(NookPanelWithDraft(model: model, session: mine, draft: "/us"), size: islandSize, to: path(directory, "tint-slash-\(tint.rawValue).png"))
            model.fileDrop.files = 2
            try render(NookPanelWithDraft(model: model, session: mine, draft: ""), size: islandSize, to: path(directory, "tint-drop-\(tint.rawValue).png"))
            // Left as the app has it: nothing is being dragged.
            model.fileDrop.files = 0
        }
    }

    /// The pane the way `PanelRenderTests` shows it, so a draft can be set; the colour comes from the session, as in the app.
    private struct NookPanelWithDraft: View {
        var model: AppModel
        var session: TerminalSession
        var draft: String
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 28)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft).id(session.id)
            }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28), alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .overlay { IslandRim(tint: session.tint) }
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    // MARK: The icons

    /// Every icon in every colour, at rest and drawn large, so the shapes can be judged; then at their real size on the tabs.
    func testRenderIconsInEveryColour() throws {
        let directory = try renderDirectory()
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(TabIcon.allCases, id: \.self) { icon in
                HStack(spacing: 20) {
                    Text(icon.title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    ForEach(TabTint.allCases, id: \.self) { tint in
                        TabIconView(icon: icon, color: tint.color, size: 40)
                    }
                }
            }
        }.padding(20).frame(width: 700, height: 330, alignment: .topLeading).background(Color.black).environment(\.colorScheme, .dark)
        try render(view, size: NSSize(width: 700, height: 330), to: path(directory, "icons-every-colour.png"))
    }

    /// Frames of each icon's movement, drawn with the same code the tab runs, a fifth of a second apart.
    func testRenderIconMovementFrames() throws {
        let directory = try renderDirectory()
        let times = (0..<12).map { Double($0) * 0.25 }
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(TabIcon.allCases.filter(\.moves), id: \.self) { icon in
                HStack(spacing: 8) {
                    Text(icon.title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    ForEach(times, id: \.self) { time in
                        Canvas { context, _ in
                            TabIconArt.draw(TabIconArt.shapes(of: icon, at: time), in: &context, size: 40, color: TabTint.blue.color)
                        }.frame(width: 40, height: 40)
                    }
                }
            }
        }.padding(20).frame(width: 760, height: 260, alignment: .topLeading).background(Color.black).environment(\.colorScheme, .dark)
        try render(view, size: NSSize(width: 760, height: 260), to: path(directory, "icons-movement-frames.png"))
    }

    /// The tab row with a different icon on each tab: the selected one and the resting ones, with and without work going on.
    func testRenderTabsWithIcons() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        var sessions: [TerminalSession] = []
        for (index, icon) in TabIcon.allCases.enumerated() {
            let tint = TabTint.allCases[index % TabTint.allCases.count]
            sessions.append(session(model, "\(icon.rawValue)", "/dev/ttys1\(index)", tint: tint, icon: icon, working: index % 2 == 1))
        }
        model.sessions = sessions
        model.selectedID = sessions[1].id
        model.expanded = true; model.islandContentVisible = true
        try render(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize, to: path(directory, "icons-tabs.png"))
    }

    // MARK: The editor and the button

    /// The popover that chooses name, colour and icon, on a dark and on a light popover (it follows the system's appearance).
    func testRenderTabEditor() throws {
        let directory = try renderDirectory()
        for (scheme, background) in [(ColorScheme.dark, Color(white: 0.16)), (.light, Color(white: 0.96))] {
            let model = AppModel(receivesSignals: false)
            let mine = session(model, "nook", "/dev/ttys090", tint: .lavender, icon: .orbit)
            model.sessions = [mine]; model.selectedID = mine.id
            model.expanded = true; model.islandContentVisible = true
            // At the size the popover takes: its content's own.
            let size = NSHostingView(rootView: TabEditor(model: model, session: mine)).fittingSize
            let view = TabEditor(model: model, session: mine).background(background).environment(\.colorScheme, scheme)
            try render(view, size: size, to: path(directory, "tab-editor-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    /// The send button in each colour, as its flat look draws it (what Reduce Transparency shows), beside the idle one.
    func testRenderSendButtonColours() throws {
        let directory = try renderDirectory()
        let view = HStack(spacing: 16) {
            ForEach(TabTint.allCases, id: \.self) { tint in
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.white)
                        .frame(width: 28, height: 28).background(tint.accent, in: Circle())
                    Text(tint.name).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }.padding(20).frame(width: 440, height: 90).background(Color.black).environment(\.colorScheme, .dark)
        try render(view, size: NSSize(width: 440, height: 90), to: path(directory, "send-button-colours.png"))
    }
}
