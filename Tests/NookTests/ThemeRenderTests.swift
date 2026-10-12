import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the island, its cards and the settings card in the light theme and in the dark one, to PNG for visual review (set NOOK_RENDER_DIR), and checks
/// what can be checked without eyes: that each theme paints the surface it says it does and that the text on it keeps its contrast.
@MainActor
final class ThemeRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func models() -> AppModel {
        let name = "nook-theme-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        return model
    }

    /// Draws `host` in a window of the appearance `scheme` and returns what it painted.
    private func paint(_ host: NSView, size: NSSize, scheme: ColorScheme) throws -> NSBitmapImageRep {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        return rep
    }

    @discardableResult
    private func write(_ view: some View, size: NSSize, scheme: ColorScheme, name: String) throws -> NSBitmapImageRep {
        let directory = try renderDirectory()
        // The flat look of the glass is what an offscreen render can show of it (and what those who ask for Reduce Transparency see).
        let rep = try paint(NSHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false).environment(\.nookFlatGlass, true)), size: size, scheme: scheme)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        return rep
    }

    private func claudeSession(_ model: AppModel, text: String, processes: [String] = ["login", "-zsh", "claude"], tint: TabTint = .mint, icon: TabIcon = .dot) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: processes, busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint; session.icon = icon
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    private var conversation: String {
        ["> Actualiza la página de bienvenida de un sitio pequeño.", "",
         "⏺ Listo. La disposición ahora se adapta al móvil y al escritorio.", "",
         "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", "",
         "⏺ Update(Sources/Nook/PanelView.swift)", "  ⎿  Actualizado Sources/Nook/PanelView.swift (+1 -1)",
         "      295  -        conversation.frame(maxWidth: .infinity, minHeight: 40)", "      295  +        conversation.frame(maxWidth: .infinity, minHeight: 24)", "",
         "⏺ Así queda la vista, con `NookPanel` y un [enlace](https://example.com):", "", "  ```swift", "  struct Isla { let ancho = 572 }", "  ```", "",
         "✻ Churned for 3m 58s · done 4:01 p.m.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    // MARK: The island

    /// The whole island, as the app lays it out without a notch (28 pt neck), in both themes and with a few tab colours.
    func testRenderTheIslandInBothThemes() throws {
        for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = models()
            model.display.theme = scheme == .dark ? .dark : .light
            _ = claudeSession(model, text: conversation)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            let rep = try write(NookPanel(model: model), size: size, scheme: scheme, name: "theme-island-\(name)")
            // The body of the island is the theme's own surface: black in the dark one, paper in the light one.
            let body = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2 + 40)).usingColorSpace(.sRGB)!
            if scheme == .light { XCTAssertGreaterThan(body.redComponent, 0.8, "paper under the conversation") }
            // The header strip is the notch's black in both.
            let strip = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 6)).usingColorSpace(.sRGB)!
            XCTAssertLessThan(strip.redComponent, 0.05, "\(name): the header strip is black")
        }
    }

    /// Where the light island meets the notch, checked without a picture: the strip under the notch is the notch's black in both themes, the bezel round the
    /// paper is black too, and the body is paper in the light theme and black in the dark one. The probes are in points from the corner, where nothing but the
    /// surface is: the content keeps 15 pt from the island's edge.
    func testTheStripAndTheBezelAreBlackAndTheBodyIsThemes() throws {
        for scheme in [ColorScheme.dark, .light] {
            let model = models()
            model.display.theme = scheme == .dark ? .dark : .light
            _ = claudeSession(model, text: conversation)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false).environment(\.nookFlatGlass, true))
            let rep = try paint(host, size: size, scheme: scheme)
            let scale = Double(rep.pixelsWide) / Double(size.width)
            func color(_ x: Double, _ y: Double) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)) }
            let name = scheme == .dark ? "dark" : "light"
            XCTAssertLessThan(try color(size.width / 2, 6).redComponent, 0.05, "\(name): the strip under the notch is black")
            XCTAssertLessThan(try color(2.5, size.height / 2).redComponent, 0.08, "\(name): the bezel at the side is black")
            XCTAssertLessThan(try color(size.width / 2, size.height - 2.5).redComponent, 0.08, "\(name): the bezel at the bottom is black")
            for fraction in [0.42, 0.55] {
                let body = try color(9, size.height * fraction)
                if scheme == .light {
                    XCTAssertGreaterThan(body.redComponent, 0.85, "light: paper at the island's side (\(fraction))")
                    XCTAssertGreaterThan(body.greenComponent, 0.85)
                } else {
                    XCTAssertLessThan(body.redComponent, 0.06, "dark: the island's black at its side (\(fraction))")
                }
            }
        }
    }

    /// The light island at each size preset (and with a notch's 32 pt neck): the bezel and the paper follow the island's size, and the black strip keeps the
    /// notch's height.
    func testRenderTheIslandAtEachPresetInBothThemes() throws {
        _ = try renderDirectory()
        for preset in IslandPreset.allCases {
            for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                let model = models()
                model.neckWithoutWindow = 32
                model.display = DisplaySettings().applying(preset)
                model.display.theme = scheme == .dark ? .dark : .light
                _ = claudeSession(model, text: conversation)
                try write(NookPanel(model: model), size: model.islandSize, scheme: scheme, name: "theme-preset-\(preset.rawValue)-\(name)")
            }
        }
    }

    /// The island and the settings card with Increase Contrast on: stronger hairlines and washes, darker status colours on the paper, and the flat look of the
    /// glass (which is what the system's own setting asks for).
    func testRenderTheIslandWithIncreaseContrast() throws {
        _ = try renderDirectory()
        NookContrast.force(true)
        addTeardownBlock { NookContrast.force(nil) }
        for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = models()
            model.display.theme = scheme == .dark ? .dark : .light
            _ = claudeSession(model, text: conversation)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            try write(NookPanel(model: model), size: size, scheme: scheme, name: "theme-ic-island-\(name)")
            let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:], claudeFolders: []))
            model.settingsTab = .island
            try write(card.padding(20).background(Color(nsColor: scheme == .dark ? NSColor(white: 0.02, alpha: 1) : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1))),
                      size: NSSize(width: 392, height: 640), scheme: scheme, name: "theme-ic-settings-\(name)")
        }
    }

    /// Only the light island, for a quick look.
    func testRenderTheLightIslandOnly() throws {
        let model = models()
        model.display.theme = .light
        _ = claudeSession(model, text: conversation)
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try write(NookPanel(model: model), size: size, scheme: .light, name: "theme-island-light-only")
    }

    func testRenderTheIslandWithEveryTabColour() throws {
        _ = try renderDirectory()
        for tint in TabTint.allCases {
            for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                let model = models()
                model.display.theme = scheme == .dark ? .dark : .light
                let session = claudeSession(model, text: conversation, tint: tint, icon: [.heart, .bolt, .leaf, .moon, .wave, .paw, .flame, .star, .code, .sun, .spark, .gem][TabTint.allCases.firstIndex(of: tint)! % 12])
                session.customTitle = tint.name
                let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
                try write(NookPanel(model: model), size: size, scheme: scheme, name: "theme-tint-\(tint.rawValue)-\(name)")
            }
        }
    }

    // MARK: The tab editor and the settings card

    func testRenderTheTabEditor() throws {
        _ = try renderDirectory()
        for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = models()
            model.display.theme = scheme == .dark ? .dark : .light
            let session = claudeSession(model, text: "⏺ hola", tint: .violet, icon: .flame)
            let editor = TabEditor(model: model, session: session).background(Color.nookCard)
            try write(editor.padding(20).background(Color(nsColor: scheme == .dark ? .black : NSColor(srgbRed: 0.85, green: 0.84, blue: 0.82, alpha: 1))),
                      size: NSSize(width: 340, height: 380), scheme: scheme, name: "theme-editor-\(name)")
        }
    }

    func testRenderTheSettingsCard() throws {
        _ = try renderDirectory()
        for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = models()
            model.display.theme = scheme == .dark ? .dark : .light
            _ = claudeSession(model, text: "⏺ hola")
            let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:], claudeFolders: []))
            for tab in [SettingsTab.island, .pet, .permissions, .privacy] {
                model.settingsTab = tab
                try write(card.padding(20).background(Color(nsColor: scheme == .dark ? NSColor(white: 0.02, alpha: 1) : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1))),
                          size: NSSize(width: 392, height: 640), scheme: scheme, name: "theme-settings-\(tab.rawValue)-\(name)")
            }
        }
    }

    /// The Pantalla tab (screen vision), with a fixture that touches nothing real: ready, and the first-time setup that still has to ask macOS.
    func testRenderTheScreenTabOfTheSettings() throws {
        _ = try renderDirectory()
        let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]
        for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            for (label, vision, states) in [("ready", try ScreenVisionUIFixture.vision(attach: true), granted),
                                            ("first", try ScreenVisionUIFixture.vision(attach: true), granted.merging([.screenRecording: .notAsked]) { $1 }),
                                            ("off", try ScreenVisionUIFixture.vision(enabled: false), granted)] {
                if label != "off" { ScreenVisionUIFixture.started(vision) }
                let model = ScreenVisionUIFixture.model(vision)
                model.animations = false
                model.display.theme = scheme == .dark ? .dark : .light
                model.settingsTab = .screen
                _ = claudeSession(model, text: "⏺ hola")
                let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: ScreenVisionUIFixture.permissions(states))
                try write(card.padding(20).background(Color(nsColor: scheme == .dark ? NSColor(white: 0.02, alpha: 1) : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1))),
                          size: NSSize(width: 392, height: 640), scheme: scheme, name: "theme-settings-screen-\(label)-\(name)")
            }
        }
    }
}
