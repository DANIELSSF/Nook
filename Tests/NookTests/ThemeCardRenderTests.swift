import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The island's panes and the cards that float over them, each in the dark theme and the light one, rendered to PNG for visual review (set NOOK_RENDER_DIR;
/// `card-<scene>-dark.png` and `card-<scene>-light.png`). The scenes are the ones the other render tests draw, with their texts, put through one helper that
/// knows the theme: the island's shell (black), its header strip (black in both), and the paper under it in the light theme.
@MainActor
final class ThemeCardRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeModel(theme: ThemePreference) -> AppModel {
        let name = "nook-theme-cards-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = false
        model.display.theme = theme
        // Nothing here may reach a real terminal.
        model.commandSender = { _, _ in }
        model.keySender = { _, _ in }
        return model
    }

    private func claude(_ model: AppModel, text: String, processes: [String] = ["login", "-zsh", "claude"], tint: TabTint = .mint) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: processes.last == "codex" ? "Codex" : "Claude Code", processes: processes, busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// Draws `view` in a window of `scheme`'s appearance and writes it, and returns what was painted.
    @discardableResult
    private func write(_ view: some View, size: NSSize, scheme: ColorScheme, name: String, background: NSColor? = nil, quick: Bool = false) throws -> NSBitmapImageRep {
        let directory = try renderDirectory()
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false).environment(\.nookFlatGlass, true))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        if let background { window.backgroundColor = background }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The row settles in a few turns (its chips choose their words by the room the status leaves them).
        // `quick`: the capsule's list closes by itself 0.6 s after the pointer is off it, so those scenes are taken before that.
        for _ in 0..<(quick ? 1 : 5) { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(quick ? 0.12 : 0.35))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("card-\(name).png"))
        return rep
    }

    /// The pane in an island: the header strip (the notch's black), the tab row with the tab, and the pane, in the shell and the paper.
    private struct ThemedIsland: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var draft: String? = nil
        var keysOpen = false
        var promptState = SessionPane.PromptCardState.options
        var effortOpen = false
        var modelMenuOpen = false
        var modelHighlight: Int? = nil
        var warningsOpen = false
        var attachments: [String]? = nil
        var promptNotes: String? = nil
        var dictationError: String? = nil

        var body: some View {
            VStack(spacing: 0) {
                Color.black.frame(height: 32)
                HStack(spacing: 8) {
                    SessionTab(model: model, session: session, agentList: TabAgentListPresenter())
                    Spacer()
                    Image(systemName: "plus").frame(width: 24, height: 26)
                }.padding(.horizontal, 15).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft, keysOpen: keysOpen, promptState: promptState, dictationError: dictationError, attachments: attachments, effortOpen: effortOpen,
                            warningsOpen: warningsOpen, dismissals: RecapSeenStore(defaults: nil), modelMenuOpen: modelMenuOpen, modelHighlight: modelHighlight,
                            promptNotes: promptNotes).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background { ZStack { Color.black; IslandPaper(neck: 32) } }
                .clippedToIslandOutline()
                .environment(\.nookDarkBackdrop, true)
                .environment(\.islandSeen, true)
        }
    }

    /// Renders `build`'s island in both themes. `build` gets a model of the theme and returns the island's view.
    private func scene(_ name: String, size: NSSize = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), quick: Bool = false,
                       _ build: (AppModel) throws -> some View) throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let model = makeModel(theme: scheme == .dark ? .dark : .light)
            try write(try build(model), size: size, scheme: scheme, name: "\(name)-\(label)", quick: quick)
        }
    }

    // MARK: Screens

    private var chat: String {
        ["> Actualiza la página de bienvenida.", "",
         "⏺ Listo. Ahora se adapta al móvil y al escritorio.", "",
         "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", "",
         "⏺ Update(Sources/Nook/PanelView.swift)", "  ⎿  Actualizado Sources/Nook/PanelView.swift (+1 -1)",
         "      295  -        conversation.frame(maxWidth: .infinity, minHeight: 40)", "      295  +        conversation.frame(maxWidth: .infinity, minHeight: 24)", "",
         "✻ Churned for 3m 58s · done 4:01 p.m.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    private var working: String {
        ["> Revisa el notch.", "", "⏺ Voy a mirar el código del notch.", "", "⏺ Read(Sources/Nook/NotchController.swift)", "  ⎿  Read 843 lines", "",
         "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    private var permission: String {
        ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
         " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)", "", " Esc to cancel · Tab to amend"].joined(separator: "\n")
    }

    private var question: String {
        ["⏺ Antes de seguir necesito una decisión tuya.", "", "☐ Database", "", "Which database should we use for the new service?", "",
         "❯ 1. PostgreSQL", "     Relational, strong consistency and a great ecosystem", "  2. SQLite", "     Embedded, zero configuration, single file",
         "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
    }

    private var plan: String {
        ["⏺ Este es el plan:", "", "  1. Mover el composer a un componente propio.", "  2. Añadir la tarjeta de preguntas.", "  3. Cubrirlo con pruebas.", "",
         " Would you like to proceed?", "", " ❯ 1. Yes, and auto-accept edits", "   2. Yes, and manually approve edits", "   3. No, keep planning"].joined(separator: "\n")
    }

    private var selector: String {
        ["⏺ Listo.", "", " Select model", " Switch between Claude models. Applies to this session and future sessions.", "", " ❯ Opus (recommended)  Most capable for complex work", "   Sonnet               Best for everyday tasks",
         "   Haiku                Fastest for quick answers", "", " Enter to confirm · Esc to exit"].joined(separator: "\n")
    }

    private func banner(model: String = "Sonnet 5.5", version: String = "2.1.290") -> [String] {
        ["▗ ▗   ▖ ▖  Claude Code v\(version)", "           \(model) with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
    }

    // MARK: The pane

    func testRenderTheConversationTheComposerAndTheirStates() throws {
        try scene("chat") { model in ThemedIsland(model: model, session: claude(model, text: chat)) }
        try scene("working") { model in ThemedIsland(model: model, session: claude(model, text: working)) }
        try scene("typing") { model in ThemedIsland(model: model, session: claude(model, text: chat), draft: "revisa también el modo claro del composer") }
        try scene("keys") { model in ThemedIsland(model: model, session: claude(model, text: chat), keysOpen: true) }
        try scene("effort") { model in ThemedIsland(model: model, session: claude(model, text: chat), effortOpen: true) }
        try scene("slash") { model in ThemedIsland(model: model, session: claude(model, text: chat), draft: "/h") }
        try scene("chat-rose") { model in ThemedIsland(model: model, session: claude(model, text: chat, tint: .rose), draft: "otro color") }
        try scene("dictation-error") { model in
            ThemedIsland(model: model, session: claude(model, text: chat), draft: "mira esto", dictationError: "No se pudo usar el micrófono. Revisa el permiso en Ajustes de macOS.")
        }
    }

    func testRenderTheQuestionsAsCards() throws {
        try scene("permission") { model in ThemedIsland(model: model, session: claude(model, text: permission)) }
        try scene("question") { model in ThemedIsland(model: model, session: claude(model, text: question, tint: .violet)) }
        try scene("plan") { model in ThemedIsland(model: model, session: claude(model, text: plan, tint: .sky)) }
        try scene("selector") { model in ThemedIsland(model: model, session: claude(model, text: selector)) }
        try scene("answering") { model in
            let session = claude(model, text: question)
            if let dialog = session.prompt, let field = dialog.options.firstIndex(where: { $0.input == .inline }) { session.chooseField(field, of: dialog) }
            return ThemedIsland(model: model, session: session, promptState: .typing)
        }
    }

    func testRenderTheWelcomeAndTheStrip() throws {
        let fresh = (banner() + ["", rule, "❯ ", rule, "  ? for shortcuts"]).joined(separator: "\n")
        try scene("welcome") { model in ThemedIsland(model: model, session: claude(model, text: fresh)) }
        let said = (banner() + ["", "> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", rule, "❯ ", rule, "  ? for shortcuts"]).joined(separator: "\n")
        try scene("strip") { model in ThemedIsland(model: model, session: claude(model, text: said)) }
    }

    func testRenderTheModelList() throws {
        let picker = [" Select model", " Switch between Claude models. Applies to this session and future sessions.", "",
                      "   1. Default (recommended) ✔  Opus 4.6 with 1M context · Most capable for complex work", " ❯ 2. Sonnet                   Sonnet 5.5 · Best for everyday tasks",
                      "   3. Sonnet (1M context)      Sonnet 5.5 with 1M context · Billed as extra usage", "   4. Haiku                    Haiku 4.5 · Fastest for quick answers", "",
                      "   ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]
        let text = (banner() + ["", "> Revisa por qué falla el build.", "", "⏺ Voy a mirar el log.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on"]).joined(separator: "\n")
        try scene("models", size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + 120)) { model in
            let prompt = try XCTUnwrap(AgentPrompt.parse(picker.joined(separator: "\n")))
            model.models.learn(prompt, version: "2.1.290", folder: nil)
            return ThemedIsland(model: model, session: claude(model, text: text), height: NotchGeometry.expandedHeight(topInset: 32) + 120, modelMenuOpen: true, modelHighlight: 1)
        }
    }

    func testRenderTheFileDrop() throws {
        try scene("drop") { model in
            model.fileDrop.files = 1
            return ThemedIsland(model: model, session: claude(model, text: chat, tint: .coral))
        }
        addTeardownBlock { @MainActor in }
    }

    // MARK: The usage and Claude's panels

    func testRenderClaudesPanelAndTheUsageCard() throws {
        let status = ["⏺ Listo.", "", rule, " Status   Config   Usage   Stats", "", " Version: 2.1.290", " Session name: /rename to add a name", " Model: Sonnet 5.5", " Working directory: ~/Documents/app", "", " ↑/↓ to scroll · Esc to cancel"].joined(separator: "\n")
        try scene("panel") { model in ThemedIsland(model: model, session: claude(model, text: status)) }
        try scene("usage", size: NSSize(width: 720, height: 420)) { model in
            let session = claude(model, text: ClaudeUsageFixtures.terminal)
            return ThemedIsland(model: model, session: session, width: 720, height: 420)
        }
    }

    // MARK: Over the whole island

    /// The island as the app lays it out (28 pt neck, no window), with a notice, the connection sheet, the welcome, or the tabs' agents.
    private func panel(_ model: AppModel, agentList: TabAgentListPresenter? = nil) -> some View {
        NookPanel(model: model, agentList: agentList ?? TabAgentListPresenter()).environment(\.noticeDuration, 600)
    }

    private var panelSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)) }

    func testRenderTheNoticesTheSheetAndTheWelcome() throws {
        let permission = "Activa Nook en Privacidad y seguridad → Accesibilidad, una sola vez. Si ya aparecía activado, Nook se registró de nuevo y lo verás apagado."
        try scene("notice", size: panelSize) { model in
            _ = claude(model, text: chat)
            model.notice = "No hay ninguna imagen en el portapapeles."
            return panel(model)
        }
        try scene("notice-permission", size: panelSize) { model in
            _ = claude(model, text: chat)
            model.notice = permission
            return panel(model)
        }
        try scene("sheet", size: panelSize) { model in
            _ = claude(model, text: chat)
            model.connectionSheet = true
            return panel(model)
        }
        try scene("welcome-empty", size: panelSize) { model in
            model.expanded = true; model.islandContentVisible = true
            return panel(model)
        }
    }

    func testRenderTheTabsAgentsAndTheirList() throws {
        func agent(_ id: String, _ name: String, kind: String? = "general-purpose", model: String? = nil, state: SubagentActivity.State = .running, tools: Int? = nil,
                   tokens: String? = nil, duration: String? = nil, activity: String? = nil, note: String? = nil) -> SubagentActivity {
            var shown = SubagentActivity(id: id, name: name, kind: kind, state: state, background: true, toolUses: tools, tokens: tokens, duration: duration, note: note)
            shown.model = model; shown.activity = activity
            return shown
        }
        func session(_ model: AppModel, _ title: String, _ tty: String, tint: TabTint) -> TerminalSession {
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: "⏺ Revisando el código del notch.")
            let made = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            made.tint = tint
            return made
        }
        try scene("tabs", size: panelSize) { model in
            let nook = session(model, "nook", "/dev/ttys090", tint: .mint), api = session(model, "api", "/dev/ttys091", tint: .blue)
            let docs = session(model, "docs", "/dev/ttys092", tint: .lavender), web = session(model, "web", "/dev/ttys093", tint: .peach)
            nook.icon = .heart; api.icon = .bolt; docs.icon = .leaf; web.icon = .flame
            nook.subagents = [agent("a", "Cat pet animation improvements", model: "sonnet", tools: 23, tokens: "41.2k", duration: "3m 12s", activity: "Read(Sources/Nook/Pet.swift)"),
                              agent("b", "Review the notch layout and the tab row", kind: "Explore", model: "opus", tools: 9, tokens: "12k", duration: "1m 4s"),
                              agent("c", "Run the test suite", model: "haiku", state: .done, tools: 31, tokens: "88.4k", duration: "6m 40s")]
            api.subagents = [agent("d", "Audit the API routes", model: "sonnet", tools: 14, tokens: "20.1k", duration: "2m 2s", activity: "Bash(swift test)")]
            web.subagents = [agent("e", "Fix the login form", model: "opus", tools: 4, tokens: "6.3k", duration: "40s", activity: "Edit(src/LoginForm.tsx)"),
                             agent("f", "Check the migration", state: .failed, tools: 2, duration: "12s", note: "Falló")]
            model.sessions = [nook, api, docs, web]; model.selectedID = nook.id
            model.expanded = true; model.islandContentVisible = true
            let presenter = TabAgentListPresenter()
            presenter.toggle(nook.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
            return panel(model, agentList: presenter)
        }
    }

    func testRenderTheCardsThatFloatOverThePane() throws {
        let recap = "Mejorando Nook para tus sesiones de Claude: ya publiqué el Enter que se ejecuta solo y la cápsula de subagentes. Lo siguiente es que lo pruebes en Terminal."
        try scene("recap") { model in
            ZStack(alignment: .topLeading) {
                ThemedIsland(model: model, session: claude(model, text: chat))
                SessionRecapCard(text: recap, isNew: true).padding(.leading, 120).padding(.top, 64)
            }
        }
        let sentence = "has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean."
        let warnings = ["Bash(pnpm --filter * exec prisma format*)", "Bash(pnpm --filter * exec prisma generate*)", "Bash(pnpm --filter * exec prisma migrate*)"]
            .flatMap { ["Permission allow rule (.claude/settings.json): \($0) \(sentence)", ""] }
        let withWarnings = (warnings + banner() + ["", "> hola", "", "⏺ Hola.", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on"]).joined(separator: "\n")
        try scene("warnings") { model in ThemedIsland(model: model, session: claude(model, text: withWarnings), warningsOpen: true) }
        let agents = [SubagentActivity(id: "a", name: "Design cat pet animations", kind: "general-purpose", state: .running, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s"),
                      SubagentActivity(id: "b", name: "Review the notch layout", kind: "Explore", state: .done, toolUses: 9, tokens: "12.0k", duration: "1m 4s"),
                      SubagentActivity(id: "c", name: "Run the test suite", state: .failed, note: "Interrumpido")]
        try scene("capsule", quick: true) { model in
            ZStack(alignment: .topTrailing) {
                ThemedIsland(model: model, session: claude(model, text: chat))
                SubagentCapsule(agents: agents, alwaysVisible: true, initiallyOpen: true).padding(.trailing, 25).padding(.top, 187 + 9 + 30 - 30)
            }
        }
        try scene("tips", size: NSSize(width: 520, height: 230)) { model in
            VStack(alignment: .leading, spacing: 16) {
                NookTipBubble(tip: NookTip("Modo", value: "Auto", detail: "Claude aprueba solo lo que ve seguro · ⇧⇥ para cambiar"))
                NookTipBubble(tip: NookTip("Enviar", detail: "↵ envía · ⇧↵ añade una línea"))
                NookTipBubble(tip: NookTip("Dictar", detail: "Habla y revisa el texto antes de enviarlo"))
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { ZStack { Color.black; Rectangle().fill(Color.nookScreen).padding(6) } }
        }
    }

    // MARK: Questions in their other shapes

    private var multiSelect: String {
        ["⏺ Antes de seguir, dime qué servicios necesitas.", "", "☐ Services", "", "Which services should we set up for the new environment?", "",
         "❯ 1. [ ] PostgreSQL", "       Relational database for contacts and deals", "  2. [✔] Redis", "       In-memory cache and job queues",
         "  3. [ ] MinIO", "       S3-compatible storage for attachments, with its own console", "  4. Type something.", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
    }

    private var tabbed: String {
        ["⏺ Tengo dos preguntas antes de empezar.", "", "← ☒ Database  ☐ Cache  ✔ Submit →", "", "Which cache should we use for sessions and rate limiting?", "",
         "❯ 1. Redis", "     In-memory, supports TTL and pub/sub", "  2. Memcached", "     Simple and fast, no persistence", "  3. Type something.", String(repeating: "─", count: 60),
         "  4. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"].joined(separator: "\n")
    }

    private var review: String {
        ["⏺ Tengo dos preguntas sobre el alta del número.", "", rule, "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
         "│ ● Según la doc de Meta (Embedded Signup v4), en el modo coexistencia el navegador recibe el id de la cuenta de",
         "│   WhatsApp Business (waba_id), pero NO el id del número (phone_number_id). La spec 18a exige ese id del número para",
         "│   conectar en todos los modos. ¿Qué hacemos?", "  → Opcional + lo busca el servidor (Recomendado)",
         "│ ● La doc de Meta v4 también dice que el modo (número nuevo o coexistencia) lo fija la configuración de Login for",
         "│   Business (config_id), no un parámetro del navegador como asume la spec. ¿Qué hacemos?", "  → Dejarlo para EP2026-363 (Recomendado)", "",
         "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
    }

    private var reviewWithWarning: String {
        ["⏺ Antes de lanzar necesito tres datos.", "", rule, "←  ☒ Platforms  ☐ Database  ☒ Notes  ✔ Submit  →", "", "Review your answers", "", "⚠ You have not answered all questions", "",
         "│ ● Which platforms should the release support?", "  → macOS, iOS",
         "│ ● Which database should we use for the cache layer that sits in front of the billing service when", "│   it is under load?",
         "│ ● Anything else?", "  → Keep the old endpoint alive until the mobile app ships the new client, then remove it", "    in the next release.", "",
         "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
    }

    private var tallSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + 300) }

    func testRenderTheReviewTheBoxesAndTheTabs() throws {
        let tall = tallSize
        try scene("review", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: review, tint: .violet), height: tall.height) }
        try scene("review-warning", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: reviewWithWarning, tint: .coral), height: tall.height) }
        try scene("multi", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: multiSelect, tint: .teal), height: tall.height) }
        try scene("question-tabs", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: tabbed, tint: .blue), height: tall.height) }
    }

    /// The question whose options carry a preview: the mock box, the notes, the key hint.
    func testRenderTheQuestionWithAPreview() throws {
        let tall = tallSize
        let sample = PreviewQuestionFixtures.sample().joined(separator: "\n")
        try scene("preview", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: sample, tint: .peach), height: tall.height) }
        try scene("preview-notes", size: tall) { model in
            ThemedIsland(model: model, session: claude(model, text: sample, tint: .peach), height: tall.height, promptNotes: "el logo a la izquierda y el nombre en dos líneas")
        }
        let single = PreviewQuestionFixtures.single(highlight: 2).joined(separator: "\n")
        try scene("preview-single", size: tall) { model in ThemedIsland(model: model, session: claude(model, text: single, tint: .lavender), height: tall.height) }
    }

    // MARK: The composer's extras

    /// The pictures pasted into the message, above the field.
    func testRenderTheAttachedPictures() throws {
        let first = try AttachmentsTests.writeImage(named: "imagen-20261004-111500.png", width: 1280, height: 800)
        let second = try AttachmentsTests.writeImage(named: "imagen-20261004-111512.png", width: 600, height: 900)
        try scene("attach") { model in ThemedIsland(model: model, session: claude(model, text: chat, tint: .rose), draft: "¿qué pasa en esta captura?", attachments: [first, second]) }
    }

    /// The composer's chips (mode, model, effort, usage) for each of Claude's modes, on the composer's own surface.
    func testRenderTheChipsOfTheComposer() throws {
        let modes: [ClaudeMode] = [.standard, ClaudeMode(kind: .auto, label: "auto mode on", hints: []), ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: []),
                                   ClaudeMode(kind: .plan, label: "plan mode on", hints: []), ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: [])]
        try scene("chips", size: NSSize(width: 330, height: 300)) { model in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                    HStack(spacing: 6) {
                        ClaudeModeChip(mode: mode) {}
                        ClaudeModelChip(model: "Sonnet 5.5") {}
                        EffortChip(effort: .high) {}
                        UsageButton {}
                    }
                }
                HStack(spacing: 6) {
                    ForEach([ClaudeEffort.low, .medium, .high, .xhigh, .max], id: \.self) { EffortChip(effort: $0) {} }
                }
            }.padding(14).frame(width: 330, height: 300, alignment: .topLeading).composerSurface().padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { ZStack { Color.black; Rectangle().fill(Color.nookScreen).padding(5) } }
        }
    }

    /// Screen vision's chip in the row of the island, off and on.
    func testRenderScreenVisionsChipInTheRow() throws {
        _ = try renderDirectory()
        for (scheme, label) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            let vision = try ScreenVisionUIFixture.vision(attach: true)
            let model = ScreenVisionUIFixture.model(vision)
            model.animations = false
            model.display.theme = scheme == .dark ? .dark : .light
            let session = ScreenVisionUIFixture.session(in: model)
            try write(ThemedIsland(model: model, session: session), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)),
                      scheme: scheme, name: "vision-\(label)")
        }
    }

    // MARK: What the mirror shows besides the conversation

    /// A Claude tab whose mirror is drawn from Claude's own record (`claudeText`, as the transcript renderer writes it), with the agents and shells it lists.
    private func recorded(_ model: AppModel, claudeText: String, agents: [SubagentActivity] = [], shells: [ShellActivity] = [], tint: TabTint = .mint) -> TerminalSession {
        let hints = shells.isEmpty ? "" : " · \(shells.count) shell · ↓ to manage"
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "nook", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)\(hints)"].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        // Nothing here may go looking for Claude's record on disk.
        session.transcriptLocated = Date()
        session.applyTranscript(claudeText, recap: nil, agents: agents, shells: shells)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// The edit with its two hunks, a new file, and a reply with fenced code in Swift and Python: the diff's colours and the syntax's.
    func testRenderTheDiffAndTheCode() throws {
        let python = "Y en Python:\n\n```python\ndef greet(name):\n    # Say hello\n    return f\"Hola, {name}\".upper()\n```"
        let edit = TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600.")] + TranscriptFixtures.swiftEdit()
                                             + [TranscriptFixtures.reply("Hecho: el ancho es 600 y la altura se calcula desde el notch.")])
        let tall = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try scene("diff", size: tall) { model in _ = recorded(model, claudeText: edit); return panel(model) }
        let code = TranscriptFixtures.render([TranscriptFixtures.prompt("Dame un ejemplo de la función."), TranscriptFixtures.reply(TranscriptFixtures.fencedReply), TranscriptFixtures.reply(python)])
        try scene("code", size: tall) { model in _ = recorded(model, claudeText: code, tint: .violet); return panel(model) }
        let file = TranscriptFixtures.render([TranscriptFixtures.prompt("Crea el README.")] + TranscriptFixtures.newFile())
        try scene("newfile", size: tall) { model in _ = recorded(model, claudeText: file, tint: .sky); return panel(model) }
    }

    /// A subagent's own conversation, under the bar that says whose it is and takes the user back.
    func testRenderTheAgentConversation() throws {
        func agent(_ state: SubagentActivity.State, activity: String? = nil) -> SubagentActivity {
            var shown = SubagentActivity(id: "call-1", name: "Cat pet animation improvements", kind: "general-purpose", state: state, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s")
            shown.model = "sonnet"; shown.activity = activity
            return shown
        }
        let record = TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600 y deja la altura calculada. Responde con el diff."),
                                                TranscriptFixtures.reply("Empiezo por leer la geometría del notch."),
                                                TranscriptFixtures.call("r1", "Read", ["file_path": TranscriptFixtures.cwd + "/Sources/Notch.swift"]),
                                                TranscriptFixtures.result("r1", "     1\timport AppKit\n     2\t\n     3\tenum NotchGeometry {")] + TranscriptFixtures.swiftEdit(id: "ag-edit")
                                               + [TranscriptFixtures.reply("Listo: el ancho es 600 y la altura se calcula a partir del notch.")])
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try scene("agentview", size: size) { model in
            let session = recorded(model, claudeText: "> Lanza un agente para el notch.\n\n⏺ Voy a lanzar un agente.\n\n", agents: [agent(.running, activity: "Read(Sources/Nook/Pet.swift)")], tint: .lime)
            session.view(agent: "call-1")
            session.applyAgentText(record, call: "call-1")
            return panel(model)
        }
        try scene("agentview-done", size: size) { model in
            let session = recorded(model, claudeText: "> Lanza un agente para el notch.\n\n⏺ Voy a lanzar un agente.\n\n", agents: [agent(.done)], tint: .lime)
            session.view(agent: "call-1")
            session.applyAgentText(record, call: "call-1")
            return panel(model)
        }
    }

    /// A background shell's output where the mirror is, running, failed and done, and the capsule's list with shells in it.
    func testRenderTheShellOutput() throws {
        func shell(_ id: String, _ name: String, command: String, state: ShellActivity.State = .running, exit: Int? = nil, ran: TimeInterval = 192) -> ShellActivity {
            var shown = ShellActivity(id: id, name: name, command: command, state: state, exitCode: exit, note: nil, movedToBackground: false,
                                      started: Date().addingTimeInterval(-ran), outputPath: "/private/tmp/claude-501/-Users-me-nook/s/tasks/x.output")
            if state != .running { shown.ended = Date().addingTimeInterval(-5) }
            return shown
        }
        let build = "gcloud builds submit --tag \"gcr.io/sampleapp/web:cfcefc7\" ."
        let output = ["Creating temporary archive of 214 file(s) totalling 3.1 MiB before compression.", "Uploading tarball of [.] to [gs://sampleapp-cloudbuild/source/1790000000.1-ab12cd.tgz]",
                      "Logs are available at [ https://console.cloud.google.com/cloud-build/builds/9f1c2e3a?project=sampleapp ].", "----------------------- REMOTE BUILD OUTPUT -----------------------",
                      "starting build \"9f1c2e3a-6b0e-4d5c-9f0a-1a2b3c4d5e6f\"", "", "FETCHSOURCE", "BUILD", "Step 1/12 : FROM node:20-alpine AS deps", " ---> 7a8f2c4e1b3d",
                      "Step 2/12 : WORKDIR /app", " ---> Using cache", "Step 3/12 : COPY package.json pnpm-lock.yaml ./", "Packages: +1184", ""].joined(separator: "\n")
        let failure = "src/Pet.swift:41: error: cannot find 'foo' in scope\n  41 |     foo()\n     |     `- error: cannot find 'foo' in scope\n\nError: command failed with exit code 1\n"
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let chat = "> Lanza el build en segundo plano y avísame cuando termine.\n\n⏺ Listo, el build corre en segundo plano.\n\n"
        try scene("shell-running", size: size) { model in
            let running = shell("b1", "Build and push the cfcefc7 image via Cloud Build", command: build)
            let session = recorded(model, claudeText: chat, shells: [running], tint: .sand)
            model.view(shell: "b1", in: session)
            session.applyShellOutput(ShellOutput(text: output), id: "b1")
            return panel(model)
        }
        try scene("shell-failed", size: size) { model in
            let failed = shell("b3", "Run lint, typecheck and test gate", command: "pnpm gate", state: .failed, exit: 1, ran: 74)
            let session = recorded(model, claudeText: chat, shells: [failed], tint: .sand)
            model.view(shell: "b3", in: session)
            session.applyShellOutput(ShellOutput(text: failure), id: "b3")
            return panel(model)
        }
        let list = [shell("b1", "Build and push the cfcefc7 image", command: build), shell("b2", "Dev server", command: "pnpm dev", ran: 1_820),
                    shell("b3", "Run lint, typecheck and test gate", command: "pnpm gate", state: .failed, exit: 1, ran: 74),
                    shell("b4", "Deploy to staging", command: "pnpm deploy:staging", state: .completed, exit: 0, ran: 331)]
        try scene("shell-list", quick: true) { model in
            let session = claude(model, text: chat, tint: .sand)
            return ZStack(alignment: .topTrailing) {
                ThemedIsland(model: model, session: session)
                SubagentCapsule(agents: [], shells: list, screenShellCount: 2, animated: false, alwaysVisible: true, initiallyOpen: true, listMaxHeight: 220, onManage: {},
                                onOpen: { _ in }, onOpenShell: { _ in }).padding(.trailing, 25).padding(.top, 187 + 9)
            }
        }
    }

    // MARK: Nook's own terminal

    /// A session of Nook's own (tmux; nothing behind it) with `processes` on its pane, shown as a live one.
    private func nookOwn(_ model: AppModel, processes: [String], screen: String = "", tint: TabTint = .mint) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-theme-render-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-theme-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.tint = tint
        session.applyPane(tty: "/dev/ttys0\(Int.random(in: 10...99))", processes: processes, text: screen)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        session.isRunning = true
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        return session
    }

    /// The live terminal of a Nook session that holds a plain shell: the 16 ANSI colours, bold, a dim line and the cursor, on the island's black and on its paper.
    func testRenderTheLiveTerminal() throws {
        let sample = ["sample@mac ~/app % ls --color", "\u{1b}[1;34mSources\u{1b}[0m  \u{1b}[1;34mTests\u{1b}[0m  \u{1b}[0;32mbuild.sh\u{1b}[0m  README.md  \u{1b}[0;31merror.log\u{1b}[0m",
                      "sample@mac ~/app % git status -sb", "## main...origin/main", " \u{1b}[31mM\u{1b}[0m Sources/Nook/PanelView.swift", "\u{1b}[32mA\u{1b}[0m  Sources/Nook/NookTheme.swift", "\u{1b}[33m??\u{1b}[0m notes.txt",
                      "sample@mac ~/app % echo $(seq 30 37 | xargs -I{} printf '\\033[%dm##\\033[0m' {})",
                      "\u{1b}[30m## \u{1b}[31m## \u{1b}[32m## \u{1b}[33m## \u{1b}[34m## \u{1b}[35m## \u{1b}[36m## \u{1b}[37m##\u{1b}[0m  \u{1b}[90m## \u{1b}[91m## \u{1b}[92m## \u{1b}[93m## \u{1b}[94m## \u{1b}[95m## \u{1b}[96m## \u{1b}[97m##\u{1b}[0m",
                      "\u{1b}[2mdim line\u{1b}[0m  \u{1b}[7mreverse\u{1b}[0m  \u{1b}[4munderline\u{1b}[0m  \u{1b}[1mbold\u{1b}[0m", "sample@mac ~/app % "]
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try scene("terminal", size: size) { model in
            let session = nookOwn(model, processes: ["/bin/zsh -l"])
            session.terminal.feed(text: sample.joined(separator: "\r\n"))
            return panel(model)
        }
    }
}
