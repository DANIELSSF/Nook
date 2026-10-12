import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The home, the greeting, the question before quitting, the sound tab and the tab editor, rendered in the light theme and in the dark one to PNG for visual review (set
/// NOOK_RENDER_DIR; `home-<scene>-dark.png` and `home-<scene>-light.png`), and what can be checked without eyes about them: that each fits the island it is for.
@MainActor
final class HomeRenderTests: XCTestCase {
    /// The model holds the host of its question weakly: these hold them for the test.
    private var hosts: [RecordingQuitHost] = []

    /// Asks the question before quitting, in `model`'s island.
    private func askToQuit(_ model: AppModel) {
        let host = RecordingQuitHost()
        hosts.append(host)
        model.quitPromptHost = host
        _ = model.shouldTerminate(.user)
    }

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the home.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeModel(theme: ThemePreference, welcomed: Bool = true, neck: CGFloat = 32) -> AppModel {
        let name = "nook-home-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        if welcomed { defaults.set(true, forKey: AppModel.welcomedKey) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        model.neckWithoutWindow = neck
        model.display.theme = theme
        model.expanded = true; model.islandContentVisible = true
        return model
    }

    private func claude(_ model: AppModel, title: String = "Claude Code", tint: TabTint = .mint, tty: String = "/dev/ttys097") -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["⏺ Listo. Ahora se adapta al móvil y al escritorio.", "", "✻ Churned for 3m 58s · done 4:01 p.m.", "", String(repeating: "─", count: 72), "❯ ", String(repeating: "─", count: 72)].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        model.sessions.append(session); model.selectedID = session.id
        model.updateActivity()
        return session
    }

    @discardableResult
    private func write(_ view: some View, size: NSSize, scheme: ColorScheme, name: String, background: NSColor? = nil) throws -> NSBitmapImageRep {
        let directory = try renderDirectory()
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false).environment(\.nookFlatGlass, true))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if let background { window.backgroundColor = background }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("home-\(name).png"))
        return rep
    }

    private func scene(_ name: String, welcomed: Bool = true, neck: CGFloat = 32, display: DisplaySettings? = nil, prepare: (AppModel) -> Void = { _ in },
                       _ build: (AppModel) -> some View) throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = makeModel(theme: scheme == .dark ? .dark : .light, welcomed: welcomed, neck: neck)
            if let display { var settings = display; settings.theme = model.display.theme; model.display = settings }
            prepare(model)
            try write(build(model), size: model.islandSize, scheme: scheme, name: "\(name)-\(label)")
        }
    }

    // MARK: The home

    func testRenderTheHomeInTheDefaultIsland() throws {
        try scene("island-notch") { NookPanel(model: $0) }
        try scene("island-flat", neck: 28) { NookPanel(model: $0) }
    }

    func testRenderTheHomeAtEveryPresetAndTheSmallestIsland() throws {
        for preset in IslandPreset.allCases {
            try scene("preset-\(preset.rawValue)", display: DisplaySettings().applying(preset)) { NookPanel(model: $0) }
        }
        var smallest = DisplaySettings()
        smallest.widthExtra = -140; smallest.heightExtra = -80
        try scene("smallest", display: smallest) { NookPanel(model: $0) }
    }

    func testRenderTheHomeInAWideIsland() throws {
        var wide = DisplaySettings()
        wide.widthExtra = 360; wide.heightExtra = 110
        try scene("wide", display: wide) { NookPanel(model: $0) }
    }

    /// The home's stage in its moods: the cat as it is drawn at the pose it is given, with the bubble it has said.
    func testRenderTheStageWithTheCatTalking() throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = makeModel(theme: scheme == .dark ? .dark : .light)
            let talk = HomeTalk()
            talk.say("¡Miau!", for: 60)
            let view = HStack(spacing: 16) {
                HomeStage(model: model, size: CGSize(width: 190, height: 100), scale: HomeMetrics.scale(stageHeight: 100), still: PetAnimation.sit(time: 0), talk: talk)
                HomeStage(model: model, size: CGSize(width: 190, height: 100), scale: HomeMetrics.scale(stageHeight: 100), still: PetAnimation.wave(time: 0.3, amount: 1), talk: talk)
                HomeStage(model: model, size: CGSize(width: 190, height: 100), scale: HomeMetrics.scale(stageHeight: 100), still: PetAnimation.asleepPose(), talk: HomeTalk())
            }.padding(18).background(scheme == .dark ? Color.black : Color.nookScreen)
            try write(view, size: NSSize(width: 3 * 190 + 2 * 16 + 36, height: 136), scheme: scheme, name: "stage-\(label)")
        }
    }

    // MARK: The greeting

    func testRenderTheGreeting() throws {
        try scene("greeting", welcomed: false) { NookPanel(model: $0) }
        try scene("greeting-replay", prepare: { model in _ = self.claude(model); model.greetingReplay = true }) { NookPanel(model: $0) }
    }

    func testRenderTheGreetingInTheSmallestIsland() throws {
        var smallest = DisplaySettings()
        smallest.widthExtra = -140; smallest.heightExtra = -80
        try scene("greeting-smallest", welcomed: false, display: smallest) { NookPanel(model: $0) }
    }

    /// Between the default island and the smallest: the compact preset, where the text column is narrow and the hint goes under the button.
    func testRenderTheGreetingInTheCompactPreset() throws {
        try scene("greeting-compact", welcomed: false, display: DisplaySettings().applying(.compact)) { NookPanel(model: $0) }
    }

    // MARK: The question before quitting

    func testRenderTheQuestionBeforeQuitting() throws {
        try scene("quit", prepare: { model in
            _ = self.claude(model)
            self.askToQuit(model)
        }) { NookPanel(model: $0) }
    }

    func testRenderTheQuestionBeforeQuittingInTheSmallestIsland() throws {
        var smallest = DisplaySettings()
        smallest.widthExtra = -140; smallest.heightExtra = -80
        try scene("quit-smallest", display: smallest, prepare: { model in
            _ = self.claude(model)
            self.askToQuit(model)
        }) { NookPanel(model: $0) }
    }

    // MARK: Increase Contrast

    /// The home, the greeting and the question with Increase Contrast on: stronger edges and secondary text, flat surfaces.
    func testRenderTheHomeAndTheQuestionWithIncreasedContrast() throws {
        NookContrast.force(true)
        addTeardownBlock { NookContrast.force(nil) }
        try scene("contrast-home") { NookPanel(model: $0) }
        try scene("contrast-greeting", welcomed: false) { NookPanel(model: $0) }
        try scene("contrast-quit", prepare: { model in
            _ = self.claude(model)
            self.askToQuit(model)
        }) { NookPanel(model: $0) }
    }

    // MARK: The sound tab, the tabs and the editor

    func testRenderTheSoundTab() throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            for (name, muted, enabled, tabs) in [("on", false, true, 3), ("mixed", true, true, 3), ("off", false, false, 2), ("none", false, true, 0)] {
                let model = makeModel(theme: scheme == .dark ? .dark : .light)
                for (index, title) in ["Claude Code", "Codex", "ui"].prefix(tabs).enumerated() {
                    let session = claude(model, title: title, tint: [.mint, .violet, .peach][index], tty: "/dev/ttys09\(index)")
                    if muted && index == 1 { model.setAlertSound(false, for: session) }
                }
                model.alertSound.enabled = enabled
                model.settingsTab = .sound
                let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:], claudeFolders: []))
                // At the height the card measures itself to (as its window does), not stretched to the canvas.
                try write(card.fixedSize(horizontal: false, vertical: true).padding(20).frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: scheme == .dark ? NSColor(white: 0.02, alpha: 1) : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1))),
                          size: NSSize(width: 392, height: 640), scheme: scheme, name: "sound-\(name)-\(label)")
            }
        }
    }

    func testRenderTheIslandTabSettingsWithTheWelcomeButton() throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = makeModel(theme: scheme == .dark ? .dark : .light)
            _ = claude(model)
            model.settingsTab = .island
            let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: PermissionsModel(states: [:], claudeFolders: []))
            try write(card.fixedSize(horizontal: false, vertical: true).padding(20).frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: scheme == .dark ? NSColor(white: 0.02, alpha: 1) : NSColor(srgbRed: 0.8, green: 0.8, blue: 0.78, alpha: 1))),
                      size: NSSize(width: 392, height: 640), scheme: scheme, name: "settings-island-\(label)")
        }
    }

    func testRenderTheTabEditorWithItsSoundSwitch() throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = makeModel(theme: scheme == .dark ? .dark : .light)
            let session = claude(model, tint: .violet)
            model.setAlertSound(false, for: session)
            let editor = TabEditor(model: model, session: session).background(Color.nookCard)
            try write(editor.padding(20).background(Color(nsColor: scheme == .dark ? .black : NSColor(srgbRed: 0.85, green: 0.84, blue: 0.82, alpha: 1))),
                      size: NSSize(width: 340, height: 440), scheme: scheme, name: "editor-\(label)")
        }
    }

    func testRenderTheTabRowWithAMutedTab() throws {
        try scene("tabs", prepare: { model in
            let first = self.claude(model, title: "Claude Code", tint: .coral, tty: "/dev/ttys090")
            _ = first
            let second = self.claude(model, title: "Codex", tint: .sky, tty: "/dev/ttys091")
            model.setAlertSound(false, for: second)
            _ = self.claude(model, title: "ui", tint: .lime, tty: "/dev/ttys092")
            model.selectedID = second.id
        }) { NookPanel(model: $0) }
    }
}
