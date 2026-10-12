import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import Nook

/// Renders the expanded island to PNG for visual review. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class PanelRenderTests: XCTestCase {
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
        // The very first render of a run can come out empty; wait and draw again until something shows.
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func claudeSession(_ model: AppModel, text: String, tty: String = "/dev/ttys099", processes: [String] = ["login", "-zsh", "claude"]) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: processes.last == "codex" ? "Codex" : "Claude Code", processes: processes, busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// A publication preview with fictional project work and labels matching each session's CLI.
    func testRenderReadmePreview() throws {
        let directory = try renderDirectory()
        let screen = ["> Update the welcome page for a small website.", "",
                      "⏺ Done. The layout now adapts to mobile and desktop.", "",
                      "  The navigation is clearer, and the preview is ready to review.", "",
                      rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
        let model = AppModel(receivesSignals: false)
        model.animations = false
        _ = claudeSession(model, text: screen)
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("readme-preview.png").path)
    }

    /// The whole panel, the way the app lays it out without a notch (28 pt neck, 262 pt tall).
    func testRenderExpandedIslandWithClaudeTab() throws {
        let directory = try renderDirectory()
        let screen = ["⏺ Listo: el envío ahora pulsa un Enter aparte para Claude y Codex.",
                      "  Las líneas largas del espejo se ajustan al ancho del panel y solo se desplazan en vertical, sin cambiar el texto original.",
                      "", "⏺ ¿Algo más?", "", "                                          ✔ Update installed · Restart to update",
                      rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"].joined(separator: "\n")
        let slash = ["⏺ ¿Algo más?", "", rule, "❯ /h", rule,
                     "  /help                       Show help and available commands",
                     "  /hooks                      Manage hook configurations for tool events",
                     "  /hud                        Toggle the heads-up display"].joined(separator: "\n")
        let working = ["⏺ Revisando el código del notch.", "", "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
        let agents = ["⏺ Voy a lanzar dos agentes en paralelo.", "",
                      "⏺ Agent(Design cat pet animations)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "",
                      "⏺ Agent(Review the notch layout)", "  ⎿  Done (23 tool uses · 41.2k tokens · 3m 12s)", "",
                      "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · 1 background · ← for agents"].joined(separator: "\n")
        let suggestion = ["⏺ Listo, ya publiqué la versión.", "", "※ recap: Mejorando Nook para tus sesiones de Claude: ya publiqué el Enter que se ejecuta solo y la cápsula de subagentes. Lo siguiente es que lo pruebes.", "", "✻ Churned for 3m 58s · done 4:01 p.m.", "", rule, "❯ ok avísame cuando esté listo", rule, "  ⏵⏵ auto mode on"].joined(separator: "\n")
        let conversation = (1...6).flatMap { n in
            ["> Pregunta número \(n): ¿puedes revisar cómo se ve el espejo cuando hay mucha conversación?", "",
             "⏺ Respuesta \(n). El texto se ajusta al ancho del panel y el espejo sigue la salida más reciente mientras no te desplaces.", "",
             "⏺ Read(Sources/Nook/PanelView.swift)", "  ⎿  Read 575 lines", ""]
        }.joined(separator: "\n") + "\n" + ["✶ Churning… (12m 48s · ↓ 187.4k tokens · thinking with high effort)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on"].joined(separator: "\n")
        let pendingBase = ["> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", "⏺ Claude suggests: sí, hazlo también en Codex", "", rule, "❯ sí, hazlo también en Codex", rule].joined(separator: "\n")
        let model = AppModel(receivesSignals: false)
        let scenarios: [(String, ColorScheme, String, (TerminalSession) -> Void)] = [
            ("dark", .dark, screen, { _ in }), ("light", .light, screen, { _ in }), ("slash", .dark, slash, { _ in }),
            ("working", .dark, working, { _ in }), ("agents", .dark, agents, { _ in }), ("suggestion", .dark, suggestion, { _ in }),
            ("long", .dark, conversation, { _ in }),
            ("pending", .dark, pendingBase, { $0.showPending("sí, hazlo también en Codex y avísame cuando esté listo") }),
            ("sending", .dark, working, { $0.sending = true }),
        ]
        for (name, scheme, text, configure) in scenarios {
            let session = claudeSession(model, text: text)
            configure(session)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, scheme))
            try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("island-\(name).png").path)
        }
    }

    /// The session pane inside a 266 pt island with a 32 pt notch inset: neck, tab row and pane stacked as in the app.
    private struct NotchInsetIsland: View {
        var model: AppModel
        var session: TerminalSession
        var draft = ""
        var keysOpen = false
        var promptState: SessionPane.PromptCardState = .options
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft, keysOpen: keysOpen, promptState: promptState).id(session.id)
            }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32), alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    func testRenderPaneWithNotchInset() throws {
        let directory = try renderDirectory()
        let working = ["⏺ Revisando el código del notch.", "", "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
        let agents = ["⏺ Voy a lanzar dos agentes en paralelo.", "",
                      "⏺ Agent(Design cat pet animations)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", "",
                      "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on · 1 background · ← for agents"].joined(separator: "\n")
        let model = AppModel(receivesSignals: false)
        // A draft makes the send button active glass, and active glass leaves an offscreen render completely empty,
        // so the typing state cannot be rendered here.
        let menu = ["⏺ Bash(rm -rf build)", "", " Bash command", "   rm -rf build", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        let finished = ["⏺ Listo, ya publiqué la versión.", "", "✻ Sautéed for 18m 17s · done 9:14 p.m.", "", rule, "❯ ", rule].joined(separator: "\n")
        for (name, text, draft, keys) in [("notch-empty", "⏺ Listo.", "", false),
                                          ("notch-working", working, "", false),
                                          ("notch-agents", agents, "", false),
                                          ("notch-finished", finished, "", false),
                                          ("notch-keys", finished, "", true),
                                          ("notch-menu", menu, "", false)] {
            let session = claudeSession(model, text: text)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            let host = NSHostingView(rootView: NotchInsetIsland(model: model, session: session, draft: draft, keysOpen: keys))
            try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("island-\(name).png").path)
        }
    }

    /// The "/" menu open above the composer. The commands are Claude Code's reference plus the session's own skills; the
    /// island is not expanded through `AppModel.expanded`, which would read the real prompt history.
    func testRenderSlashMenu() throws {
        let directory = try renderDirectory()
        let finished = ["⏺ Listo, ya publiqué la versión.", "", "Aquí va una respuesta larga del espejo para ver el menú encima de texto real, no solo sobre el negro del panel.", "",
                        "✻ Sautéed for 18m 17s · done 9:14 p.m.", "", rule, "❯ ", rule].joined(separator: "\n")
        let skills = ["usage": "", "codex:rescue": "Delegate investigation, an explicit fix request, or follow-up rescue work to the Codex rescue subagent",
                      "superpowers:requesting-code-review": "Use when completing tasks, implementing major features, or before merging to verify the work meets requirements",
                      "ruta": "Nueva ruta"]
        let model = AppModel(receivesSignals: false)
        for (name, draft, keys) in [("all", "/", false), ("us", "/us", false), ("res", "/res", false), ("few", "/mod", false), ("one", "/usage", false),
                                    ("keys", "/c", true), ("none", "/zzz", false), ("message", "hola /us", false), ("path", "/Users/me/x", false),
                                    ("alias", "/new", false), ("long", "/super", false), ("typo", "/Us", false)] {
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "codex", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: finished)
            let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            session.applyTranscript(nil, recap: nil, skills: skills, usedCommands: [])
            model.sessions = [session]; model.selectedID = session.id
            model.islandContentVisible = true
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            let host = NSHostingView(rootView: NotchInsetIsland(model: model, session: session, draft: draft, keysOpen: keys))
            try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("slash-\(name).png").path)
        }
    }

    /// What the composer (or a question's card) looks like while files are dragged over the island. The feedback is read from
    /// `AppModel.fileDrop`, which the real drop view sets on entering and clears on leaving.
    func testRenderFileDropFeedback() throws {
        let directory = try renderDirectory()
        let finished = ["⏺ Listo, ya publiqué la versión.", "", "Aquí va una respuesta larga del espejo para ver el aviso encima de texto real, no solo sobre el negro del panel.", "",
                        "✻ Sautéed for 18m 17s · done 9:14 p.m.", "", rule, "❯ ", rule].joined(separator: "\n")
        let permission = ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
                          " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        let model = AppModel(receivesSignals: false)
        for (name, files, draft, text, state) in [("empty", 1, "", finished, SessionPane.PromptCardState.options),
                                                  ("typed", 1, "evalúa este archivo y dime qué falta", finished, .options),
                                                  ("several", 3, "", finished, .options),
                                                  ("card", 1, "", permission, .options)] {
            let session = claudeSession(model, text: text)
            model.fileDrop.files = files
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            let host = NSHostingView(rootView: NotchInsetIsland(model: model, session: session, draft: draft, promptState: state))
            try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("drop-\(name).png").path)
        }
        model.fileDrop.files = 0
    }

    /// The card an agent's question turns the composer into, in the dialogs' usual shapes. Texts are the ones users see in
    /// Claude Code and Codex, not captured from a real session.
    func testRenderPromptCards() throws {
        let directory = try renderDirectory()
        let permission = ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
                          " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)", "", " Esc to cancel · Tab to amend"]
        let middle = permission.map { $0.replacingOccurrences(of: " ❯ 1.", with: "   1.").replacingOccurrences(of: "   2. Yes, and", with: " ❯ 2. Yes, and") }
        let edit = ["⏺ Update(Sources/Nook/PanelView.swift)", "  ⎿  Updated Sources/Nook/PanelView.swift with 4 additions and 1 removal", "", " Edit file", " Sources/Nook/PanelView.swift", "",
                    "  295  -        conversation.frame(maxWidth: .infinity, minHeight: 40)", "  295  +        conversation.frame(maxWidth: .infinity, minHeight: 24)", "",
                    " Do you want to make this edit to PanelView.swift?", " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)", "   3. No, and tell Claude what to do differently (esc)"]
        let question = ["⏺ Antes de seguir necesito una decisión tuya.", "", "☐ Database", "", "Which database should we use for the new service?", "",
                        "❯ 1. PostgreSQL", "     Relational, strong consistency and a great ecosystem", "  2. SQLite", "     Embedded, zero configuration, single file",
                        "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let selector = ["⏺ Listo.", "", " Select model", " Switch between Claude models. Applies to this session and future sessions.", "", " ❯ Opus (recommended)  Most capable for complex work", "   Sonnet               Best for everyday tasks",
                        "   Haiku                Fastest for quick answers", "", " Enter to confirm · Esc to exit"]
        let plan = ["⏺ Este es el plan:", "", "  1. Mover el composer a un componente propio.", "  2. Añadir la tarjeta de preguntas.", "  3. Cubrirlo con pruebas.", "",
                    " Would you like to proceed?", "", " ❯ 1. Yes, and auto-accept edits", "   2. Yes, and manually approve edits", "   3. No, keep planning"]
        let codex = ["• Voy a subir los cambios.", "", "  Would you like to run the following command?", "", "  Reason: needs network access", "", "  $ git push origin main", "",
                     "› 1. Yes, proceed (y)", "  2. Yes, and don't ask again for this command (p)", "  3. No, and tell Codex what to do differently (esc)", "", "  Press enter to confirm or esc to cancel"]
        let many = ["⏺ Elige la sesión que quieres retomar.", "", " Resume Session", "", " ❯ Fix the island's collapse while a question is open", "   Redesign the composer with glass", "   Add recap card to the tab row",
                    "   Subagent capsule polish", "   Pet animation timing", "   Terminal bridge delivery logging", "   Image paste with control V", "", " Enter to select · Esc to cancel"]
        let long = ["⏺ Bash(swift test --filter PanelRenderTests --cache-path .build/cache --config-path .build/config --security-path .build/security)", "",
                    " Do you want to proceed with the very long command shown above, which takes quite some time to run?", " ❯ 1. Yes",
                    "   2. Yes, and don't ask again for swift test commands in /Users/me/Documents/Examples/New project", "   3. No, and tell Claude what to do differently (esc)"]
        // Claude's older builds draw the same dialog inside a box.
        let boxed = ["⏺ Bash(rm -rf build)", "╭" + String(repeating: "─", count: 62) + "╮", "│ Bash command" + String(repeating: " ", count: 49) + "│", "│" + String(repeating: " ", count: 62) + "│",
                     "│   rm -rf build" + String(repeating: " ", count: 47) + "│", "│" + String(repeating: " ", count: 62) + "│", "│ Do you want to proceed?" + String(repeating: " ", count: 38) + "│",
                     "│ ❯ 1. Yes" + String(repeating: " ", count: 53) + "│", "│   2. Yes, and don't ask again for rm commands in this project" + String(repeating: " ", count: 1) + "│",
                     "│   3. No, and tell Claude what to do differently (esc)" + String(repeating: " ", count: 9) + "│", "╰" + String(repeating: "─", count: 62) + "╯"]
        let model = AppModel(receivesSignals: false)
        let scenarios: [(String, String, [String], SessionPane.PromptCardState, Bool, (TerminalSession) -> Void)] = [
            ("boxed", "claude", boxed, .options, false, { _ in }),
            ("agents", "claude", ["⏺ Agent(Design cat pet animations)", "  ⎿  Backgrounded agent (↓ to manage · ctrl+o to expand)", ""] + permission, .options, false, { _ in }),
            ("permission", "claude", permission, .options, false, { _ in }),
            ("permission-middle", "claude", middle, .options, false, { _ in }),
            ("permission-busy", "claude", permission, .options, false, { _ = $0.beginAnswer() }),
            ("edit", "claude", edit, .options, false, { _ in }),
            ("question", "claude", question, .options, false, { _ in }),
            ("selector", "claude", selector, .options, false, { _ in }),
            ("plan", "claude", plan, .options, false, { _ in }),
            ("codex", "codex", codex, .options, false, { _ in }),
            ("many", "claude", many, .options, false, { _ in }),
            ("long", "claude", long, .options, false, { _ in }),
            // The field of the question chosen on its card, which is what a click on «Type something.» leaves: the composer answers it (see `FieldAnswerRenderTests`).
            ("typing", "claude", question, .typing, false, { session in
                if let dialog = session.prompt, let field = dialog.options.firstIndex(where: { $0.input == .inline }) { session.chooseField(field, of: dialog) }
            }),
            ("hidden", "claude", permission, .hidden, true, { _ in }),
        ]
        for (name, agent, rows, state, keys, configure) in scenarios {
            let session = claudeSession(model, text: rows.joined(separator: "\n"), processes: ["login", "-zsh", agent])
            configure(session)
            XCTAssertNotNil(session.prompt, name)
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            let host = NSHostingView(rootView: NotchInsetIsland(model: model, session: session, keysOpen: keys, promptState: state))
            try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("prompt-\(name).png").path)
        }
    }

    /// The whole island with a question waiting in another tab: the tab carries a small mark, and the selected tab shows
    /// its own conversation untouched.
    func testRenderTabWithAQuestionWaiting() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false)
        func tab(_ tty: String, _ title: String, _ text: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        }
        let working = TerminalSession(tab: tab("/dev/ttys097", "nook", "⏺ Revisando el código del notch."), backend: .bundled, bridge: model.terminalBridge)
        let waiting = TerminalSession(tab: tab("/dev/ttys098", "api", [" Do you want to proceed?", " ❯ 1. Yes", "   2. No"].joined(separator: "\n")), backend: .bundled, bridge: model.terminalBridge)
        XCTAssertNotNil(waiting.prompt)
        model.sessions = [working, waiting]; model.selectedID = working.id
        model.expanded = true; model.islandContentVisible = true
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try write(NSHostingView(rootView: NookPanel(model: model)), size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("prompt-tab-mark.png").path)
    }

    /// An owned tmux session shows SwiftTerm's live terminal, which must blend with the island too. The process behind it
    /// is `true`, which exits at once; the text is fed straight into the terminal.
    func testRenderOwnedTmuxSession() throws {
        let directory = try renderDirectory()
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-render-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-render", name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        let esc = "\u{1b}["
        let lines = ["\(esc)38;5;173m⏺\(esc)0m Voy a revisar el notch.",
                     "\(esc)2m  ⎿  Read 575 lines\(esc)0m",
                     "\(esc)48;5;236m\(esc)38;5;158m > ¿puedes dejar el texto sin recuadro? \(esc)0m",
                     "\(esc)38;5;173m⏺\(esc)0m Listo: el espejo queda directo sobre el negro.",
                     "\(esc)32m+ let accent = Color.mint\(esc)0m   \(esc)31m- let card = Color.gray\(esc)0m   \(esc)34mblue\(esc)0m \(esc)36mcyan\(esc)0m \(esc)33myellow\(esc)0m",
                     "~/Documents/ChatGPT % "]
        session.terminal.feed(text: lines.joined(separator: "\r\n"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        session.isRunning = true
        let model = AppModel(receivesSignals: false)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
        let host = NSHostingView(rootView: NotchInsetIsland(model: model, session: session))
        try write(host, size: size, to: URL(fileURLWithPath: directory).appendingPathComponent("island-tmux.png").path)
    }

    /// The agents' list open above its capsule, placed where the capsule sits in the composer (top right of the text row).
    func testRenderSubagentListOpen() throws {
        let directory = try renderDirectory()
        let agents = [SubagentActivity(id: "a", name: "Design cat pet animations", kind: "general-purpose", state: .running, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s"),
                      SubagentActivity(id: "b", name: "Review the notch layout", kind: "Explore", state: .done, toolUses: 9, tokens: "12.0k", duration: "1m 4s"),
                      SubagentActivity(id: "c", name: "Run the test suite", state: .failed, note: "Interrumpido")]
        let view = ZStack(alignment: .topTrailing) {
            Color.black
            HStack { Spacer(); SubagentCapsule(agents: agents, alwaysVisible: true, initiallyOpen: true) }
                .padding(.trailing, 25).padding(.top, 187 + 9)
        }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        try write(NSHostingView(rootView: view), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)),
                  to: URL(fileURLWithPath: directory).appendingPathComponent("island-agent-list.png").path)
    }
}
