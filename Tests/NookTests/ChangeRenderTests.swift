import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the mirror's look for code changes and fenced blocks, and the agent's view, to PNG for review. Runs only when
/// NOOK_RENDER_DIR is set.
@MainActor
final class ChangeRenderTests: XCTestCase {
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
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(blackBacked(rep).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The mirror is transparent over the island's black; composite so the PNG shows what the user sees.
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

    private func path(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// The mirror alone, at the width of the island's conversation, over black.
    private func renderMirror(_ text: String, chatSize: Double = DisplaySettings.defaultChatSize, size: NSSize = NSSize(width: 540, height: 330), taskLabel: String? = nil, to path: String) throws {
        let scroll = LiveTerminalScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setFontSize(chatSize)
        scroll.setText(text)
        scroll.setTaskLabel(taskLabel)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.addSubview(scroll)
        try write(host, size: size, to: path)
    }

    private var editText: String {
        TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600 y deja la altura calculada.")] +
                                  [TranscriptFixtures.reply("Voy a cambiar la geometría del notch.")] + TranscriptFixtures.swiftEdit())
    }

    func testRenderAnEditAndANewFile() throws {
        let directory = try renderDirectory()
        try renderMirror(editText, size: NSSize(width: 540, height: 360), to: path(directory, "diff-edit.png"))
        let created = TranscriptFixtures.render([TranscriptFixtures.prompt("Crea el README.")] + TranscriptFixtures.newFile(lines: 15))
        try renderMirror(created, size: NSSize(width: 540, height: 260), to: path(directory, "diff-newfile.png"))
    }

    func testRenderFencedCodeInAReply() throws {
        let directory = try renderDirectory()
        let python = "Y en Python:\n\n```python\n@app.route(\"/hola\")\ndef hola(nombre: str = \"mundo\") -> dict:\n    # respuesta simple\n    return {\"mensaje\": f\"Hola {nombre}\", \"total\": 42}\n```\n\nY un comando:\n\n```bash\nswift test --filter ChangeRenderTests && echo \"listo\" # corre\n```"
        let text = TranscriptFixtures.render([TranscriptFixtures.prompt("Dame un ejemplo de la función.")] + [TranscriptFixtures.reply(TranscriptFixtures.fencedReply), TranscriptFixtures.reply(python)])
        try renderMirror(text, size: NSSize(width: 540, height: 420), to: path(directory, "fenced-reply.png"))
    }

    func testRenderMarkdownInAReply() throws {
        let directory = try renderDirectory()
        let markdown = "**Cómo queda:** ahora el espejo dibuja el *énfasis*, la **negrita**, el `código en línea` y los [enlaces](https://example.com/guia).\n\n## Qué cambió\n\n- **Negrita y cursiva:** se ven como en la terminal de Claude, sin asteriscos.\n- El archivo `Sources/Nook/TranscriptStyle.swift` y la ruta `src/**/*.swift` no se tocan.\n  - Un punto anidado con _cursiva_ y **negrita _mezclada_**.\n1. Una lista numerada queda igual.\n\n### Lo que no cambia\n\nSnake_case, file_name_here, 2 * 3 * 4 y `**` solos se quedan como están.\n\nListo: ya puedes **probarlo**."
        let text = TranscriptFixtures.render([TranscriptFixtures.prompt("¿Cómo se ve el markdown?"), TranscriptFixtures.reply(markdown)])
        try renderMirror(text, size: NSSize(width: 540, height: 470), to: path(directory, "markdown-reply.png"))
        try renderMirror(text, chatSize: 15, size: NSSize(width: 540, height: 640), to: path(directory, "markdown-reply-large.png"))
        try renderMirror(text, chatSize: 9, size: NSSize(width: 540, height: 360), to: path(directory, "markdown-reply-small.png"))
    }

    func testRenderMarkdownInTheIsland() throws {
        let directory = try renderDirectory()
        let reply = "**Cómo queda:** el espejo dibuja la *cursiva*, la **negrita** y el `código en línea`.\n\n## Qué cambió\n\n- **Negrita:** sin asteriscos.\n- Una ruta `src/**/*.swift` y [una guía](https://example.com).\n\nListo, 2 * 3 * 4 y file_name_here quedan igual."
        let conversation = TranscriptFixtures.render([TranscriptFixtures.prompt("¿Cómo se ve?"), TranscriptFixtures.reply(reply)])
        try island("markdown-normal", viewing: false, agents: [], text: "", claudeText: conversation, to: directory)
        var large = DisplaySettings(); large.chatSize = 14
        try island("markdown-large", settings: large.applying(.tall), viewing: false, agents: [], text: "", claudeText: conversation, to: directory)
    }

    func testRenderTheTaskLabel() throws {
        let directory = try renderDirectory()
        let short = TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600 y deja la altura calculada."), TranscriptFixtures.reply("Empiezo por leer la geometría del notch."),
                                               TranscriptFixtures.call("r1", "Read", ["file_path": TranscriptFixtures.cwd + "/Sources/Notch.swift"]), TranscriptFixtures.result("r1", "     1\timport AppKit")])
        try renderMirror(short, size: NSSize(width: 540, height: 200), taskLabel: "Tarea", to: path(directory, "task-label.png"))
        try renderMirror(short, chatSize: 16, size: NSSize(width: 540, height: 220), taskLabel: "Tarea", to: path(directory, "task-label-large.png"))
        try renderMirror(TranscriptFixtures.render([TranscriptFixtures.prompt("Una tarea larga para el agente: " + String(repeating: "revisa el panel y avisa. ", count: 6))]),
                         size: NSSize(width: 540, height: 120), taskLabel: "Tarea", to: path(directory, "task-label-long.png"))
    }

    func testRenderTheChatSizes() throws {
        let directory = try renderDirectory()
        try renderMirror(editText, chatSize: 9, size: NSSize(width: 540, height: 300), to: path(directory, "diff-size-9.png"))
        try renderMirror(editText, chatSize: 14, size: NSSize(width: 540, height: 420), to: path(directory, "diff-size-14.png"))
        try renderMirror(editText, chatSize: 18, size: NSSize(width: 540, height: 480), to: path(directory, "diff-size-18.png"))
    }

    // MARK: The agent's view

    private func agent(_ id: String, _ name: String, state: SubagentActivity.State = .running, activity: String? = nil) -> SubagentActivity {
        var shown = SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s")
        shown.model = "sonnet"
        shown.activity = activity
        return shown
    }

    /// The agent's own record: its task from Claude, a few tool calls and an edit with its rows.
    private var agentText: String {
        TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600 y deja la altura calculada. Responde con el diff.")] +
                                  [TranscriptFixtures.reply("Empiezo por leer la geometría del notch."),
                                   TranscriptFixtures.call("r1", "Read", ["file_path": TranscriptFixtures.cwd + "/Sources/Notch.swift"]),
                                   TranscriptFixtures.result("r1", "     1\timport AppKit\n     2\t\n     3\tenum NotchGeometry {")] + TranscriptFixtures.swiftEdit(id: "ag-edit") +
                                  [TranscriptFixtures.reply("Listo: el ancho es 600 y la altura se calcula a partir del notch.")])
    }

    private func island(_ name: String, settings: DisplaySettings = DisplaySettings(), neck: CGFloat = 32, viewing: Bool, viewID: String? = nil, agents: [SubagentActivity], text: String, claudeText: String? = nil,
                        settle: TimeInterval = 0.6, to directory: String) throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
        model.neckWithoutWindow = neck
        model.display = settings
        let rule = String(repeating: "─", count: 60)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "nook", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.transcriptLocated = Date()
        session.applyTranscript(claudeText ?? "> Lanza un agente para el notch.\n\n⏺ Voy a lanzar un agente.\n\n", recap: nil, agents: agents)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        if viewing, let id = viewID ?? agents.first?.id {
            session.view(agent: id)
            if !text.isEmpty { session.applyAgentText(text, call: id) }
        }
        let size = model.islandSize
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(blackBacked(rep).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path(directory, "island-\(name).png")))
    }

    func testRenderTheAgentView() throws {
        let directory = try renderDirectory()
        let working = agent("call-1", "Cat pet animation improvements", activity: "Read(Sources/Nook/Pet.swift)")
        let done = agent("call-1", "Cat pet animation improvements", state: .done)
        try island("agentview-working", viewing: true, agents: [working, agent("call-2", "Review the notch layout", state: .done)], text: agentText, to: directory)
        try island("agentview-done", viewing: true, agents: [done], text: agentText, to: directory)
        try island("agentview-compact", settings: DisplaySettings().applying(.compact), viewing: true, agents: [working], text: agentText, to: directory)
        var large = DisplaySettings(); large.chatSize = 14
        try island("agentview-large", settings: large.applying(.tall), viewing: true, agents: [working], text: agentText, to: directory)
        try island("agentview-empty", viewing: true, agents: [working], text: "", settle: 1.6, to: directory)
        // An agent that left the list (it finished a while ago): the bar still shows, with the record.
        try island("agentview-gone", viewing: true, viewID: "call-gone", agents: [], text: agentText, to: directory)
    }

    func testRenderTheDiffInTheIsland() throws {
        let directory = try renderDirectory()
        let conversation = TranscriptFixtures.render([TranscriptFixtures.prompt("Sube el ancho de la isla a 600."), TranscriptFixtures.reply(TranscriptFixtures.fencedReply),
                                                      TranscriptFixtures.reply("Voy a cambiar la geometría del notch.")] + TranscriptFixtures.swiftEdit())
        try island("diff-normal", viewing: false, agents: [], text: "", claudeText: conversation, to: directory)
        var small = DisplaySettings(); small.chatSize = 9
        try island("diff-small", settings: small.applying(.wide), viewing: false, agents: [], text: "", claudeText: conversation, to: directory)
        var large = DisplaySettings(); large.chatSize = 15
        try island("diff-large", settings: large.applying(.tall), viewing: false, agents: [], text: "", claudeText: conversation, to: directory)
        try island("diff-newfile", viewing: false, agents: [], text: "", claudeText: TranscriptFixtures.render([TranscriptFixtures.prompt("Crea el README.")] + TranscriptFixtures.newFile()), to: directory)
    }

    // MARK: The collapsed pill

    func testRenderTheCollapsedPillAndItsTooltip() throws {
        let directory = try renderDirectory()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "nook", processes: ["claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        for (name, agents) in [("one", [agent("a", "Cat pet animation improvements")]),
                               ("many", (1...5).map { agent("n\($0)", ["Review the notch layout", "Audit the tab row", "Profile the collapsed island", "Write the release notes", "Check the migration"][$0 - 1]) })] {
            session.subagents = agents
            model.updateActivity()
            let screen = NSRect(x: 0, y: 0, width: 420, height: 170)
            let container = NSView(frame: screen)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
            let pet = PetView(frame: NSRect(x: 87, y: 138, width: 245, height: 32))
            pet.injectedModel = model
            container.addSubview(pet)
            let text = AgentPillTooltip.text(try XCTUnwrap(model.agentPill))
            let size = AgentPillTipView.size(for: text)
            let pill = try XCTUnwrap(AgentNotchBadge.rect(running: model.runningSubagents, in: pet.bounds)).offsetBy(dx: pet.frame.minX, dy: pet.frame.minY)
            let tipFrame = AgentPillTip.frame(size: size, pill: pill, island: pet.frame, screen: screen)
            let tip = AgentPillTipView(frame: tipFrame)
            tip.setText(text)
            container.addSubview(tip)
            try write(container, size: screen.size, to: path(directory, "pill-tooltip-\(name).png"))
        }
    }
}
