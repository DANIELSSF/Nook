import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the island at each size and text size to PNG for visual review. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class DisplayRenderTests: XCTestCase {
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

    private func claudeSession(_ model: AppModel, text: String, draft: String = "", tty: String = "/dev/ttys098") -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "codex", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.draft = draft
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    private var conversation: String {
        let turns = (1...5).flatMap { n in
            ["> Pregunta número \(n): ¿puedes revisar cómo se ve el espejo cuando hay mucha conversación?", "",
             "⏺ Respuesta \(n). El texto se ajusta al ancho del panel y el espejo sigue la salida más reciente mientras no te desplaces.", "",
             "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", ""]
        }.joined(separator: "\n")
        return turns + "\n" + ["⏺ Listo: el tamaño de la isla y del texto ahora se ajustan desde los ajustes.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    /// One island, laid out the way the app does: `NookPanel` at the size the settings give, on a screen with this notch inset.
    private func render(_ name: String, settings: DisplaySettings, neck: CGFloat = 28, draft: String = "", text: String? = nil, to directory: String,
                        configure: (AppModel, TerminalSession) -> Void = { _, _ in }) throws {
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.neckWithoutWindow = neck
        model.display = settings
        let session = claudeSession(model, text: text ?? conversation, draft: draft)
        configure(model, session)
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("island-\(name).png").path)
    }

    func testRenderEachPreset() throws {
        let directory = try renderDirectory()
        for preset in IslandPreset.allCases {
            try render("preset-\(preset.rawValue)", settings: DisplaySettings().applying(preset), to: directory)
        }
        // With a notch (a taller header), the same presets.
        for preset in IslandPreset.allCases {
            try render("preset-\(preset.rawValue)-notch", settings: DisplaySettings().applying(preset), neck: 32, to: directory)
        }
    }

    func testRenderTextSizes() throws {
        let directory = try renderDirectory()
        var small = DisplaySettings(); small.chatSize = 9; small.inputSize = 10
        var large = DisplaySettings(); large.chatSize = 18; large.inputSize = 20
        try render("text-small", settings: small, neck: 32, draft: "mensaje corto", to: directory)
        try render("text-default", settings: DisplaySettings(), neck: 32, draft: "mensaje corto", to: directory)
        try render("text-large", settings: large, neck: 32, draft: "mensaje corto", to: directory)
        var wideLarge = large; wideLarge = wideLarge.applying(.wide)
        try render("text-large-wide", settings: wideLarge, neck: 32, draft: "mensaje corto", to: directory)
    }

    func testRenderTheMultiLineField() throws {
        let directory = try renderDirectory()
        let paragraph = "Quiero que revises el flujo de envío cuando el mensaje es largo: que el campo crezca hasta tres líneas, que después se desplace dentro de sí mismo y que Enter siga enviando al instante."
        let long = (1...7).map { "línea \($0): " + String(paragraph.prefix(30 + $0 * 4)) }.joined(separator: "\n")
        try render("input-one-line", settings: DisplaySettings(), neck: 32, draft: "mensaje corto", to: directory)
        try render("input-two-lines", settings: DisplaySettings(), neck: 32, draft: "primera línea\nsegunda línea", to: directory)
        try render("input-wrapped-3", settings: DisplaySettings(), neck: 32, draft: paragraph + " " + paragraph, to: directory)
        try render("input-scrolled", settings: DisplaySettings(), neck: 32, draft: long, to: directory)
        var six = DisplaySettings(); six.inputLines = 6
        try render("input-six-lines", settings: six, neck: 32, draft: long, to: directory)
        try render("input-wrapped-compact", settings: DisplaySettings().applying(.compact), neck: 32, draft: paragraph + " " + paragraph, to: directory)
        try render("input-wrapped-tall", settings: DisplaySettings().applying(.tall), neck: 32, draft: paragraph + " " + paragraph, to: directory)
    }

    func testRenderClaudesSuggestionInTheField() throws {
        let directory = try renderDirectory()
        let withSuggestion = ["⏺ Listo, ya publiqué la versión.", "", "✻ Churned for 3m 58s · done 4:01 p.m.", "", rule, "❯ ok avísame cuando esté listo", rule, "  ⏵⏵ auto mode on"].joined(separator: "\n")
        try render("suggestion", settings: DisplaySettings(), neck: 32, text: withSuggestion, to: directory)
        try render("suggestion-wide-large", settings: { var s = DisplaySettings().applying(.wide); s.inputSize = 16; return s }(), neck: 32, text: withSuggestion, to: directory)
    }

    func testRenderTheSettingsCard() throws {
        let directory = try renderDirectory()
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        for (name, settings) in [("default", DisplaySettings()), ("custom", { var s = DisplaySettings().applying(.wide); s.chatSize = 14; s.inputLines = 5; return s }())] {
            let model = AppModel(receivesSignals: false, defaults: suite)
            model.display = settings
            let view = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32).padding(30).background(Color(white: 0.3))
            let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
            let fitting = host.fittingSize
            try write(host, size: fitting, to: URL(fileURLWithPath: directory).appendingPathComponent("settings-\(name).png").path)
        }
    }

    // MARK: What floats over the conversation

    private var permission: String {
        ["⏺ Bash(rm -rf build)", "", " Bash command", "   rm -rf build", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
         "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
    }
    private var manyOptions: String {
        (["⏺ Elige el modelo.", "", " Select model", "   Switch between Claude models."] + (1...9).map { ($0 == 2 ? " ❯ " : "   ") + "\($0). Opción número \($0) del selector" }).joined(separator: "\n")
    }

    func testRenderTheSlashMenuAndTheQuestionCardAtEachSize() throws {
        let directory = try renderDirectory()
        for preset in [IslandPreset.compact, .normal, .tall] {
            let settings = DisplaySettings().applying(preset)
            try render("slash-\(preset.rawValue)", settings: settings, neck: 32, draft: "/", to: directory)
            try render("question-\(preset.rawValue)", settings: settings, neck: 32, text: permission, to: directory)
            try render("question-many-\(preset.rawValue)", settings: settings, neck: 32, text: manyOptions, to: directory)
        }
    }

    func testRenderTheTabsAgentListAndTheRecapAtEachSize() throws {
        let directory = try renderDirectory()
        func agent(_ id: String, _ name: String, state: SubagentActivity.State = .running, activity: String? = nil) -> SubagentActivity {
            var shown = SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 12, tokens: "30k", duration: "2m 8s")
            shown.model = "sonnet"; shown.activity = activity
            return shown
        }
        for preset in [IslandPreset.compact, .normal, .tall] {
            let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
            let model = AppModel(receivesSignals: false, defaults: suite)
            model.neckWithoutWindow = 32
            model.display = DisplaySettings().applying(preset)
            let session = claudeSession(model, text: conversation)
            session.subagents = (1...8).map { agent("\($0)", "Agente número \($0) revisando el panel", state: $0 > 5 ? .done : .running, activity: $0 > 5 ? nil : "Read(Sources/Nook/Pet.swift)") }
            let presenter = TabAgentListPresenter()
            presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
            let size = model.islandSize
            let host = NSHostingView(rootView: NookPanel(model: model, agentList: presenter).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
            try write(host, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("island-agents-\(preset.rawValue).png").path)

            let layout = PaneLayout.of(island: size, neck: 32, settings: model.display)
            let recap = "Mejorando Nook: ya puedes ajustar el tamaño de la isla y de las letras. " + String(repeating: "Lo siguiente es que lo pruebes con un mensaje largo. ", count: 6)
            let card = SessionRecapCard(text: recap, isNew: true, width: layout.recapWidth, maxBodyHeight: layout.recapMaxBodyHeight)
                .padding(20).environment(\.colorScheme, .dark)
            let cardHost = NSHostingView(rootView: ZStack { Color(white: 0.3); card })
            try write(cardHost, size: NSSize(width: layout.recapWidth + 40, height: layout.recapMaxBodyHeight + 26 + 40), to: URL(fileURLWithPath: directory).appendingPathComponent("recap-\(preset.rawValue).png").path)
        }
    }

    func testRenderTheWelcomeAndANoticeInTheSmallestIsland() throws {
        let directory = try renderDirectory()
        var least = DisplaySettings(); least.widthExtra = -140; least.heightExtra = -80
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.neckWithoutWindow = 32
        model.display = least
        model.islandContentVisible = true
        let size = model.islandSize
        let welcome = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        try write(welcome, size: NSSize(width: size.width, height: size.height), to: URL(fileURLWithPath: directory).appendingPathComponent("island-welcome-smallest.png").path)
        try render("notice-smallest", settings: least, neck: 32, to: directory) { model, _ in
            model.notice = "Claude tiene una pregunta abierta: lo que envíes no se escribiría en ella y el Enter podría responderla sin querer. Elige una opción o pulsa Enter otra vez."
        }
        try render("smallest", settings: least, neck: 32, draft: "primera línea\nsegunda línea\ntercera línea", to: directory)
    }

    func testRenderTheSettingsCardNextToTheIsland() throws {
        let directory = try renderDirectory()
        let suite = UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!
        let model = AppModel(receivesSignals: false, defaults: suite)
        model.neckWithoutWindow = 32
        model.display = DisplaySettings().applying(.wide)
        _ = claudeSession(model, text: conversation, draft: "")
        let screen = CGSize(width: 1512, height: 982)
        let island = model.islandSize
        let card = SettingsCard(model: model, screen: screen, topInset: 32)
        let scene = ZStack(alignment: .top) {
            Color(white: 0.22)
            VStack(spacing: SettingsPlacement.gap) {
                NookPanel(model: model).frame(width: island.width, height: island.height)
                card
            }
        }.environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: scene)
        try write(host, size: NSSize(width: 820, height: island.height + 420), to: URL(fileURLWithPath: directory).appendingPathComponent("settings-with-island.png").path)
    }
}
