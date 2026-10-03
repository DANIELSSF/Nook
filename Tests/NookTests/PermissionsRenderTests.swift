import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the settings card's Permisos tab in mixed states, with guides open, to PNG for visual review.
/// Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class PermissionsRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the permissions.") }
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

    /// The card on a tab, with the permissions in the given state. Nothing is read or asked.
    private func render(_ name: String, tab: SettingsTab = .permissions, states: [NookPermission: NookPermission.State], folders: [ClaudeFolder]? = nil, signals: Bool = false,
                        open: Set<String> = [], screen: CGSize = CGSize(width: 1512, height: 982), to directory: String) throws {
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.settingsTab = tab
        model.claudeSignalsEnabled = signals
        let permissions = PermissionsModel(states: states, claudeFolders: folders, openGuides: open)
        let view = SettingsCard(model: model, screen: screen, topInset: 32, permissions: permissions).padding(30).background(Color(white: 0.3))
        let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
        try write(host, size: host.fittingSize, to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png").path)
    }

    private func session(_ model: AppModel) {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: "⏺ Listo: revisé los cambios.\n\n⏺ Read(Sources/Nook/PanelView.swift)\n  ⎿  Read 575 lines\n\n⏺ Todo en orden.")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
    }

    /// The island with a notice about a permission, and the connection sheet with Terminal's refusal: both offer "Ver permisos".
    func testRenderTheOffersToOpenThePermisosTab() throws {
        let directory = try renderDirectory()
        for (name, setup) in [
            ("notice-accessibility", { (model: AppModel) in model.notice = "Activa Nook en Privacidad y seguridad → Accesibilidad. Si instalas una versión nueva de Nook, macOS puede pedir el permiso otra vez." }),
            ("notice-plain", { (model: AppModel) in model.notice = "No hay ninguna imagen en el portapapeles." }),
            ("connection-denied", { (model: AppModel) in model.connectionSheet = true; model.terminalBridge.error = TerminalBridgeError.automationDenied.errorDescription }),
        ] as [(String, (AppModel) -> Void)] {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
            model.neckWithoutWindow = 32
            session(model)
            setup(model)
            let size = model.islandSize
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
            try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("perms-\(name).png").path)
        }
    }

    private let both = [ClaudeFolder(name: "~/.claude", enabled: true), ClaudeFolder(name: "~/.claude-work", enabled: false)]

    func testRenderThePermissionsTab() throws {
        let directory = try renderDirectory()
        // The normal day: everything on.
        try render("perms-all-granted", states: [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted],
                   folders: [ClaudeFolder(name: "~/.claude", enabled: true)], signals: true, to: directory)
        // Every state at once: Terminal closed (can't be read), Accessibility off, microphone refused, speech on; Claude on in one folder.
        try render("perms-mixed", states: [.automation: .unknown, .accessibility: .notAsked, .microphone: .denied, .speech: .granted], folders: both, to: directory)
        // The needed permission is missing, the rest on.
        try render("perms-essential-missing", states: [.automation: .notAsked, .accessibility: .granted, .microphone: .notAsked, .speech: .notAsked],
                   folders: [ClaudeFolder(name: "~/.claude", enabled: false)], to: directory)
        try render("perms-essential-denied", states: [.automation: .denied, .accessibility: .notAsked, .microphone: .granted, .speech: .granted],
                   folders: [ClaudeFolder(name: "~/.claude", enabled: true)], signals: true, to: directory)
        // Before the first read.
        try render("perms-checking", states: [:], to: directory)
    }

    func testRenderTheGuides() throws {
        let directory = try renderDirectory()
        try render("perms-guide-accessibility", states: [.automation: .granted, .accessibility: .notAsked, .microphone: .notAsked, .speech: .notAsked],
                   folders: both, open: [NookPermission.accessibility.id], to: directory)
        try render("perms-guide-terminal", states: [.automation: .denied, .accessibility: .granted, .microphone: .granted, .speech: .granted],
                   folders: both, open: [NookPermission.automation.id], to: directory)
        try render("perms-guide-claude", states: [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted],
                   folders: both, open: [PermissionsModel.claudeKey], to: directory)
        try render("perms-guides-all", states: [.automation: .unknown, .accessibility: .denied, .microphone: .notAsked, .speech: .granted], folders: both,
                   open: Set(NookPermission.allCases.map(\.id) + [PermissionsModel.claudeKey]), to: directory)
    }

    func testRenderTheTabBarAndAShortScreen() throws {
        let directory = try renderDirectory()
        // The island's tab, with the dot on "Permisos" because the needed permission is off.
        try render("perms-island-tab-dot", tab: .island, states: [.automation: .notAsked, .accessibility: .granted, .microphone: .granted, .speech: .granted], to: directory)
        try render("perms-island-tab", tab: .island, states: [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted], to: directory)
        // A 13-inch screen with the guides open: the list scrolls instead of the card running off it.
        try render("perms-short-screen", states: [.automation: .unknown, .accessibility: .notAsked, .microphone: .notAsked, .speech: .granted], folders: both,
                   open: [NookPermission.accessibility.id], screen: CGSize(width: 1280, height: 720), to: directory)
    }
}
