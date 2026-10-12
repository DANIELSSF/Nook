import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the question's card with everything a dialog says (a long question, long descriptions, boxes to tick, tabs, the model picker) and the
/// agents' pill, list and tab badge with several background agents, to PNG for visual review. Runs only when NOOK_RENDER_DIR is set. The screens
/// are fixtures in the shapes Claude Code draws, fed through the reading the app uses.
@MainActor
final class PromptCardRenderTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `settleTurns` are the run loop turns the card gets to settle before the picture; the capsule's list closes by itself after 0.6 s with no pointer
    /// on it, so a picture of it open takes none.
    private func write(_ host: NSView, size: NSSize, settleTurns: Int = 10, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The card settles in a few turns (its height decides what the conversation keeps, and that what the card says): give it them.
        for _ in 0..<settleTurns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            host.layoutSubtreeIfNeeded()
        }
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
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

    private func makeModel() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-card-render-" + UUID().uuidString)!) }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var promptState: SessionPane.PromptCardState = .options
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, promptState: promptState).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func session(_ model: AppModel, text: String, agent: String = "claude") -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", agent], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    // MARK: Fixtures

    private let longQuestion = ["⏺ Necesito una decisión antes de tocar el modelo de datos.", "", "☐ Database", "",
        "We are about to move the CRM from a single SQLite file to a hosted database, and the migration will touch contacts, deals and the activity timeline.",
        "Which database should we use for the new service, considering that the team already runs Postgres for billing but nobody has operated Redis in production?", "",
        "❯ 1. PostgreSQL", "     Relational, strong consistency, a great ecosystem; the team already operates it for billing, so backups and monitoring are in place",
        "  2. SQLite", "     Embedded, zero configuration, single file; fine for a prototype but it has no concurrent writers",
        "  3. MySQL", "     Widely supported and well understood, although the team has no experience running it",
        "  4. MongoDB", "     Flexible documents and easier schema changes, but weaker joins for the deals pipeline",
        "  5. Type something.", String(repeating: "─", count: 60), "  6. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    private let multiSelect = ["⏺ Antes de seguir, dime qué servicios necesitas.", "", "☐ Services", "", "Which services should we set up for the new environment?", "",
        "❯ 1. [ ] PostgreSQL", "       Relational database for contacts and deals",
        "  2. [✔] Redis", "       In-memory cache and job queues",
        "  3. [ ] MinIO", "       S3-compatible storage for attachments, with its own console",
        "  4. Type something.", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    private let tabs = ["⏺ Tengo dos preguntas antes de empezar.", "", "← ☒ Database  ☐ Cache  ✔ Submit →", "", "Which cache should we use for sessions and rate limiting?", "",
        "❯ 1. Redis", "     In-memory, supports TTL and pub/sub", "  2. Memcached", "     Simple and fast, no persistence", "  3. Type something.", String(repeating: "─", count: 60),
        "  4. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]

    private let modelPicker = ["⏺ Listo.", "", " Select model", " Switch between Claude models. Applies to this session and future sessions. For other/previous model names, specify with --model.", "",
        "   1. Default (recommended) ✔  Opus 4.6 with 1M context · Most capable for complex work", " ❯ 2. Sonnet                   Sonnet 4.6 · Best for everyday tasks",
        "   3. Haiku                    Haiku 4.5 · Fastest for quick answers", "", "   ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]

    private let shortQuestion = ["⏺ Elijo el nombre del paquete.", "", "☐ Package", "", "What should the package be called?", "", "❯ 1. nook-core", "  2. nook-kit", "  3. Type something.",
        "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    private let wrappedPermission = ["⏺ Bash(swift test --filter PanelRenderTests)", " Bash command", "", "   swift test --filter PanelRenderTests", "   Run the render tests of the island", "",
        " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for swift test commands in /Users/developer/Documents/Examples/New project", "   3. No, and tell Claude what to do differently (esc)"]

    private func render(_ name: String, _ rows: [String], promptState: SessionPane.PromptCardState = .options, widths: [Double] = [NotchGeometry.expandedWidth], extraHeight: CGFloat = 0,
                        chatSize: Double? = nil, in directory: String) throws {
        let model = makeModel()
        if let chatSize { model.display.chatSize = chatSize }
        let session = session(model, text: rows.joined(separator: "\n"))
        XCTAssertNotNil(session.prompt, name)
        for width in widths {
            let height = NotchGeometry.expandedHeight(topInset: 32) + extraHeight
            let suffix = widths.count > 1 || width != NotchGeometry.expandedWidth ? "-\(Int(width))" : ""
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width, height: height, promptState: promptState)), size: NSSize(width: width, height: height),
                      to: url(directory, "card-\(name)\(extraHeight > 0 ? "-tall" : "")\(suffix).png"))
        }
    }

    // MARK: The card

    func testRenderTheLongQuestion() throws {
        let directory = try renderDirectory()
        try render("long", longQuestion, widths: [NotchGeometry.expandedWidth, 440], in: directory)
        try render("long", longQuestion, extraHeight: 220, in: directory)
    }

    func testRenderTheBoxesToTick() throws {
        let directory = try renderDirectory()
        try render("multi", multiSelect, in: directory)
        try render("multi", multiSelect, extraHeight: 60, in: directory)
    }

    func testRenderTheTabsOfSeveralQuestions() throws {
        let directory = try renderDirectory()
        try render("tabs", tabs, in: directory)
        try render("tabs", tabs, extraHeight: 60, in: directory)
    }

    func testRenderTheModelPicker() throws {
        let directory = try renderDirectory()
        try render("model", modelPicker, widths: [NotchGeometry.expandedWidth, 440], in: directory)
        try render("model", modelPicker, extraHeight: 60, in: directory)
    }

    /// Sample's session (app, 2026-10-06): the step that sends two answered questions, with the long texts of his record.
    private var review: [String] {
        ["⏺ Tengo dos preguntas sobre el alta del número.", "", rule, "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
         "│ ● Según la doc de Meta (Embedded Signup v4), en el modo coexistencia el navegador recibe el id de la cuenta de",
         "│   WhatsApp Business (waba_id), pero NO el id del número (phone_number_id). La spec 18a exige ese id del número para",
         "│   conectar en todos los modos. ¿Qué hacemos?", "  → Opcional + lo busca el servidor (Recomendado)",
         "│ ● La doc de Meta v4 también dice que el modo (número nuevo o coexistencia) lo fija la configuración de Login for",
         "│   Business (config_id), no un parámetro del navegador como asume la spec. Para ofrecer los dos modos haría falta un",
         "│   segundo config_id: una sexta variable de entorno y otra configuración en la app de Meta. Es la pregunta abierta de",
         "│   la §10. ¿Qué hacemos?", "  → Dejarlo para EP2026-363 (Recomendado)", "",
         "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    }

    /// Several answers joined on one line, a question with none, a long answer, and Claude's warning.
    private var reviewWithWarning: [String] {
        ["⏺ Antes de lanzar necesito tres datos.", "", rule, "←  ☒ Platforms  ☐ Database  ☒ Notes  ✔ Submit  →", "", "Review your answers", "", "⚠ You have not answered all questions", "",
         "│ ● Which platforms should the release support?", "  → macOS, iOS",
         "│ ● Which database should we use for the cache layer that sits in front of the billing service when", "│   it is under load?",
         "│ ● Anything else?", "  → Keep the old endpoint alive until the mobile app ships the new client, then remove it", "    in the next release.", "",
         "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    }

    func testRenderTheReviewOfSeveralQuestions() throws {
        let directory = try renderDirectory()
        try render("review", review, widths: [NotchGeometry.expandedWidth, 440], in: directory)
        try render("review", review, extraHeight: 120, in: directory)
        try render("review", review, widths: [440], extraHeight: 120, in: directory)
        // Tall enough to show the whole card, down to the buttons.
        try render("review-full", review, extraHeight: 300, in: directory)
        try render("review-full", review, widths: [440], extraHeight: 300, in: directory)
        // The chat text size the user chose is the card's: the smallest and the largest.
        try render("review-big", review, widths: [NotchGeometry.expandedWidth, 440], extraHeight: 300, chatSize: DisplaySettings.chatSizeRange.upperBound, in: directory)
        try render("review-small", review, widths: [NotchGeometry.expandedWidth], extraHeight: 120, chatSize: DisplaySettings.chatSizeRange.lowerBound, in: directory)
    }

    func testRenderTheReviewWithSeveralAnswersAnUnansweredQuestionAndAWarning() throws {
        let directory = try renderDirectory()
        try render("review-warning", reviewWithWarning, widths: [NotchGeometry.expandedWidth, 440], in: directory)
        try render("review-warning", reviewWithWarning, extraHeight: 120, in: directory)
        try render("review-warning", reviewWithWarning, widths: [440], extraHeight: 120, in: directory)
        try render("review-warning-full", reviewWithWarning, extraHeight: 300, in: directory)
        try render("review-warning-full", reviewWithWarning, widths: [440], extraHeight: 300, in: directory)
    }

    private let edit = ["⏺ Update(Sources/Nook/PanelView.swift)", "  ⎿  Updated Sources/Nook/PanelView.swift with 4 additions and 1 removal", "", " Edit file", " Sources/Nook/PanelView.swift", "",
                        "  295  -        conversation.frame(maxWidth: .infinity, minHeight: 40)", "  295  +        conversation.frame(maxWidth: .infinity, minHeight: 24)", "",
                        " Do you want to make this edit to PanelView.swift?", " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)", "   3. No, and tell Claude what to do differently (esc)"]

    func testRenderTheCompactCardsAsBefore() throws {
        let directory = try renderDirectory()
        try render("short", shortQuestion, in: directory)
        try render("wrapped", wrappedPermission, in: directory)
        // A permission whose question does not fit the bar and whose card therefore covers the conversation: it says what it is about.
        try render("edit", edit, in: directory)
        try render("command", coveringPermission, in: directory)
        try render("command", coveringPermission, extraHeight: 60, in: directory)
    }

    private let coveringPermission = ["⏺ Bash(pnpm --filter api exec prisma migrate deploy && pnpm --filter api exec prisma generate)", " Bash command", "",
                                      "   pnpm --filter api exec prisma migrate deploy && pnpm --filter api exec prisma generate", "   Apply the pending migrations and regenerate the client", "",
                                      " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for pnpm --filter api exec prisma commands in /Users/developer/Documents/app",
                                      "   3. Yes, and don't ask again for pnpm commands in every project of this account, whatever folder they are in",
                                      "   4. No, and tell Claude what to do differently (esc)"]

    // MARK: Background agents

    private let mode = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage"
    private var threeAgents: String {
        (["⏺ Lancé los agentes en segundo plano.", "", "  Te aviso cuando termine cada agente.", "", "✻ Waiting for 3 background agents to finish", "", rule, "❯ ", rule, mode, "", "  ⏺️ main",
          "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens", "  ○ fork  Charting echo failures in deliveries.log", "4m 56s · ↓ 189.9k tokens",
          "  ○ fork  Finding AgentPrompt construction call sites", "4m 56s · ↓ 208.6k tokens"]).joined(separator: "\n")
    }

    func testRenderThreeBackgroundAgents() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let session = session(model, text: threeAgents)
        XCTAssertEqual(session.subagents.count, 3)
        // The composer's capsule with its list open, where the capsule sits.
        let capsule = ZStack(alignment: .topTrailing) {
            Color.black
            HStack { Spacer(); SubagentCapsule(agents: session.subagents, alwaysVisible: true, initiallyOpen: true) }.padding(.trailing, 25).padding(.top, 187 + 9)
        }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        try write(NSHostingView(rootView: capsule), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), settleTurns: 0,
                  to: url(directory, "agents-capsule-list.png"))
        // The whole island: the tab's badge, and its list under the tab row.
        let presenter = TabAgentListPresenter()
        presenter.toggle(session.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try write(NSHostingView(rootView: NookPanel(model: model, agentList: presenter)), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)),
                  to: url(directory, "agents-tab-list.png"))
        // The pane itself, with the capsule closed.
        try write(NSHostingView(rootView: Island(model: model, session: session)), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)), to: url(directory, "agents-pane.png"))
        // What the collapsed island's pill says.
        XCTAssertEqual(model.agentPill?.names.count, 3)
        let tooltip = AgentPillTooltip.text(try XCTUnwrap(model.agentPill))
        print("PILL TOOLTIP:\n\(tooltip)")
    }
}
