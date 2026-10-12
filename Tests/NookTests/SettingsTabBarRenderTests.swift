import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the settings card's tab bar to PNG for visual review: the card with each tab selected and both dots out, in a dark window and a light one
/// (the card itself is always dark: it is the island's own surface). Runs only when NOOK_RENDER_DIR is set. Nothing is read or asked of the system.
@MainActor
final class SettingsTabBarRenderTests: XCTestCase {
    private func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the settings card's tabs.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    private func write(_ host: NSView, size: NSSize, appearance: NSAppearance.Name = .darkAqua, to url: URL) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    /// The permissions' states with a needed permission off and the screen recording not yet allowed: the two tabs that can wear the dot do.
    private let missing: [NookPermission: NookPermission.State] = [.automation: .notAsked, .accessibility: .notAsked, .screenRecording: .notAsked]
    private let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]

    /// The card on `tab`: with both dots out, or none. Screen vision is on, which is what puts the dot on "Pantalla".
    private func card(_ tab: SettingsTab, dots: Bool, look: NSAppearance.Name = .darkAqua) throws -> (NSHostingView<AnyView>, NSAppearance.Name) {
        let model = ScreenVisionUIFixture.model(try ScreenVisionUIFixture.vision(enabled: true))
        model.settingsTab = tab
        let permissions = ScreenVisionUIFixture.permissions(dots ? missing : granted)
        permissions.refresh()
        let view = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: permissions)
            .padding(30).background(Color(white: look == .darkAqua ? 0.3 : 0.86)).environment(\.nookTintedGlass, false)
        return (NSHostingView(rootView: AnyView(view)), look)
    }

    func testRenderTheSettingsCardWithEachTab() throws {
        let directory = try renderDirectory()
        for tab in SettingsTab.allCases {
            let (host, look) = try card(tab, dots: true)
            try write(host, size: host.fittingSize, appearance: look, to: directory.appendingPathComponent("card-\(tab.rawValue)-dots.png"))
        }
        // No dot at all: the quiet day.
        let (clean, look) = try card(.island, dots: false)
        try write(clean, size: clean.fittingSize, appearance: look, to: directory.appendingPathComponent("card-island-clean.png"))
        // The same card in a light window.
        for tab in [SettingsTab.island, .permissions] {
            let (host, look) = try card(tab, dots: true, look: .aqua)
            try write(host, size: host.fittingSize, appearance: look, to: directory.appendingPathComponent("card-\(tab.rawValue)-dots-light.png"))
        }
    }

    // MARK: The bar on its own

    /// Every tab selected in turn, one bar under another, `width` wide (the card's width, 352, is the one the app has; the others are for the day the card is narrower or wider).
    private func sheet<Tab: SettingsTabItem>(_ tabs: [Tab], width: CGFloat, attention: Set<Tab>, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.white.opacity(0.75))
            VStack(spacing: 0) {
                ForEach(tabs) { tab in
                    SettingsTabBarHarness(tabs: tabs, selection: SettingsTabBarSelection(tab), attention: attention, width: width)
                }
            }
        }.padding(14).background(Color(white: 0.3))
    }

    func testRenderTheBarAtEachWidthWithFiveTabsAndWithSix() throws {
        let directory = try renderDirectory()
        for width in [300, 352, 420] as [CGFloat] {
            let five = sheet(SettingsTab.allCases, width: width, attention: [.permissions, .screen], caption: "\(Int(width)) pt · 5 tabs · dots on Permisos and Pantalla")
            let fiveHost = NSHostingView(rootView: five)
            try write(fiveHost, size: fiveHost.fittingSize, to: directory.appendingPathComponent("bar-\(Int(width))-5tabs.png"))
            let six = sheet(Array(SixTabs.allCases), width: width, attention: [.permissions, .screen, .notifications], caption: "\(Int(width)) pt · 6 tabs · dots on Permisos, Pantalla and Notificaciones")
            let sixHost = NSHostingView(rootView: six)
            try write(sixHost, size: sixHost.fittingSize, to: directory.appendingPathComponent("bar-\(Int(width))-6tabs.png"))
        }
        let quiet = sheet(SettingsTab.allCases, width: 352, attention: [], caption: "352 pt · 5 tabs · no dots")
        let quietHost = NSHostingView(rootView: quiet)
        try write(quietHost, size: quietHost.fittingSize, to: directory.appendingPathComponent("bar-352-5tabs-quiet.png"))
    }

    /// The switch from one tab to another, a frame every 20 ms or so, as the window draws it: each frame is a PNG named by its time.
    private func film<Tab: SettingsTabItem>(_ name: String, tabs: [Tab], from: Tab, to: Tab, attention: Set<Tab>, width: CGFloat? = nil, in directory: URL) throws {
        for frame in try SettingsTabBarProbe.film(tabs: tabs, from: from, to: to, attention: attention, width: width ?? SettingsCard.width) {
            try XCTUnwrap(frame.image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(String(format: "film-%@-%04d.png", name, frame.millis)))
        }
    }

    func testRenderTheSwitchFrameByFrame() throws {
        let directory = try renderDirectory()
        try film("island-to-privacy", tabs: SettingsTab.allCases, from: .island, to: .privacy, attention: [.permissions, .screen], in: directory)
        try film("screen-to-pet", tabs: SettingsTab.allCases, from: .screen, to: .pet, attention: [.permissions, .screen], in: directory)
    }
}
