import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the mirror's block Markdown (tables, fenced blocks, quotes) in both themes and at the island's widths, to PNG for review.
/// Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class MirrorBlocksRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The mirror alone over the island's surface (black, or the paper), `width` wide and as tall as its text.
    private func render(_ text: String, dark: Bool, width: CGFloat, height: CGFloat, to name: String, prepare: (LiveTerminalScrollView) -> Void = { _ in }) throws {
        let directory = try renderDirectory()
        let size = NSSize(width: width, height: height)
        let scroll = LiveTerminalScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.setTheme(dark: dark, transcript: true)
        scroll.setText(text)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NookPalette.screenSolid.resolved(dark: dark).cgColor
        host.addSubview(scroll)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        scroll.contentView.scroll(to: .zero)
        prepare(scroll)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NookPalette.screenSolid.resolved(dark: dark).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(out.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    static let cases = """
    Los mensajes del formulario, caso por caso:

    | Caso | Lo que dice |
    |---|---|
    | Formulario vacío | «Escribe su nombre.» / «Escribe sus apellidos.» / «Escribe un correo o un celular: con uno basta.» |
    | Sin cuenta | nada |
    | Coincide una parte | «El correo es de una cuenta con otro celular.» Se puede elegir esa cuenta o que la persona confirme al entrar |
    | Correo sin verificar | «Hay una cuenta con este correo, pero no lo ha verificado.» |

    En la lista «Equipo» quedan tres estados.
    """

    static let tests = """
    Resultado de los tests:

    | Suite | Tests | Fallos | Tiempo |
    |:--|--:|--:|--:|
    | RemoteAccessTests | 49 | 0 | 2,1 s |
    | PreviewNotesFocusTests | 13 | 0 | 0,4 s |
    | **Total** | 2506 | 8 | 3 min |
    """

    static let command = """
    El deploy de la 763 **falló otra vez al subir** (error 408 de red).

    Reinténtalo; hasta ahora siempre salió al segundo intento:

    ```
    ! bash /Users/danielssf/Documents/Chamba/VIBE/.claude/tmp/deploy-dev-168fcca1.sh
    ```

    Cuando termine bien, agenteA hace la prueba en vivo.
    """

    static let swift = """
    Así queda la función:

    ```swift
    func greet(name: String) -> String {
        // Say hello
        let text = "Hola, \\(name)"
        return text.uppercased()
    }
    ```
    """

    static let quote = """
    Este es para pegar el lunes:

    > Eres el arquitecto de VIBE. Antes de nada, lee `.claude/tmp/handoff-2026-11-23.md` completo.
    >
    > - Mira si agenteA y agenteB siguen vivos (`ListAgents`).
    > - Sigue la § 6 del relevo del 11-23.
    >
    > **Reglas:** nunca toques `main` ni hagas force-push.

    Y listo.
    """

    private var conversation: String {
        TranscriptFixtures.render([TranscriptFixtures.prompt("¿Cómo quedan los mensajes?"), TranscriptFixtures.reply(Self.cases), TranscriptFixtures.reply(Self.tests),
                                   TranscriptFixtures.reply(Self.command), TranscriptFixtures.reply(Self.swift), TranscriptFixtures.reply(Self.quote)])
    }

    func testRenderBlocks() throws {
        for dark in [true, false] {
            let theme = dark ? "dark" : "light"
            try render(conversation, dark: dark, width: 540, height: 1180, to: "blocks-\(theme)-540.png")
            try render(conversation, dark: dark, width: 300, height: 1700, to: "blocks-\(theme)-300.png")
        }
        try render(conversation, dark: true, width: 900, height: 1000, to: "blocks-dark-900.png")
    }
}

extension MirrorBlocksRenderTests {
    private static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        for child in view.subviews { if let found = find(type, in: child) { return found } }
        return nil
    }

    /// A quote's copy button: at rest beside its first line, then live with the caret in the quote, and right after it copied.
    func testRenderQuoteCopyButton() throws {
        let directory = try renderDirectory()
        let text = TranscriptFixtures.render([TranscriptFixtures.prompt("¿Me lo escribes?"), TranscriptFixtures.reply(Self.quote)])
        for dark in [true, false] {
            let size = NSSize(width: 540, height: 260)
            let host = NSHostingView(rootView: LiveTerminalSurface(text: text, transcript: true).environment(\.colorScheme, dark ? .dark : .light)
                .background(Color.nookScreenSolid))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let mirror = try XCTUnwrap(Self.find(LiveTerminalScrollView.self, in: host))
            mirror.contentView.scroll(to: .zero)
            let theme = dark ? "dark" : "light"
            func snap(_ name: String) throws {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            try snap("quote-button-rest-\(theme).png")
            XCTAssertTrue(window.makeFirstResponder(mirror.textView))
            let s = mirror.textView.string as NSString
            mirror.textView.setSelectedRange(NSRange(location: s.range(of: "Mira si").location, length: 0))
            if let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
                mirror.textView.keyDown(with: right)
            }
            XCTAssertNotNil(mirror.copyModel?.quote)
            try snap("quote-button-live-\(theme).png")
            if let quote = mirror.copyModel?.quote { mirror.copyModel?.copy(quote) }
            try snap("quote-button-copied-\(theme).png")
        }
    }

    /// The copy buttons as the mirror shows them: the caret in a command's block brings the reply's button and the block's; the second
    /// picture is right after the block's was clicked.
    func testRenderCopyButtons() throws {
        let directory = try renderDirectory()
        let text = TranscriptFixtures.render([TranscriptFixtures.prompt("¿Y ahora?"), TranscriptFixtures.reply(Self.command), TranscriptFixtures.reply(Self.swift)])
        for dark in [true, false] {
            let size = NSSize(width: 540, height: 330)
            let host = NSHostingView(rootView: LiveTerminalSurface(text: text, transcript: true).environment(\.colorScheme, dark ? .dark : .light)
                .background(Color.nookScreenSolid))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let mirror = try XCTUnwrap(Self.find(LiveTerminalScrollView.self, in: host))
            mirror.contentView.scroll(to: .zero)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertTrue(window.makeFirstResponder(mirror.textView))
            let s = mirror.textView.string as NSString
            mirror.textView.setSelectedRange(NSRange(location: s.range(of: "! bash").location + 3, length: 0))
            // → moves the caret on, as the keyboard does: the buttons follow it.
            if let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
                mirror.textView.keyDown(with: right)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            XCTAssertNotNil(mirror.copyModel?.code)
            let theme = dark ? "dark" : "light"
            func snap(_ name: String) throws {
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
            try snap("copy-buttons-\(theme).png")
            if let code = mirror.copyModel?.code { mirror.copyModel?.copy(code) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            try snap("copy-buttons-copied-\(theme).png")
        }
    }
}

/// The recap's and the compaction's controls in the tab row, over a conversation with the compaction's divider.
private struct CompactionRow: View {
    var summary: String?
    var pinned: String?
    var open = false
    var conversation: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer()
                SessionRecapButton(sessionID: "render", recap: "Mejorando Nook: tablas, bloques de código y citas.", store: Self.seen)
                SessionRecapButton(sessionID: "render", recap: summary, kind: .compaction, store: RecapSeenStore(defaults: nil), initiallyOpen: open, keepsOpen: true,
                                   cardWidth: 440, maxBodyHeight: 230)
                Image(systemName: "arrow.up.right.square").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.nookSecondary).frame(width: 28, height: 28)
            }
            .padding(.horizontal, 15).frame(height: 30).zIndex(1)
            LiveTerminalSurface(text: conversation, transcript: true).padding(.horizontal, 10)
        }
        .overlayPreferenceValue(NookTipKey.self) { NookTipLayer(entry: $0, animated: false) }
        .environment(\.nookTipPinned, pinned)
        .frame(width: 560, height: 340)
        .background(Color.nookScreenSolid)
    }

    /// The recap read already: its chip at rest, without the badge.
    static let seen: RecapSeenStore = {
        let store = RecapSeenStore(defaults: nil)
        store.markSeen("Mejorando Nook: tablas, bloques de código y citas.", in: "render")
        return store
    }()
}

extension MirrorBlocksRenderTests {
    /// The two icons at rest (with a compaction and without), the compaction's tip as the pointer resting on it shows it, its card open,
    /// and the divider where the summary was, in both themes.
    func testRenderCompactionControls() throws {
        let directory = try renderDirectory()
        let conversation = TranscriptFixtures.render([TranscriptFixtures.prompt("Sigue con las tablas.")]) + CompactionSummary.marker + "\n\n"
            + TranscriptFixtures.render([TranscriptFixtures.prompt("¿Y los bloques de código?"), TranscriptFixtures.reply("Ya tienen su botón de copiar.")])
        let summary = CompactionSummary.readable(CompactionSummaryTests.summary)
        let cases: [(String, String?, String?, Bool)] = [("rest", summary, nil, false), ("absent", nil, nil, false), ("tip", summary, "compactionSummary", false),
                                                         ("recap-tip", summary, "sessionRecap", false), ("open", summary, nil, true)]
        for dark in [true, false] {
            for (name, summary, pinned, open) in cases {
                let host = NSHostingView(rootView: CompactionRow(summary: summary, pinned: pinned, open: open, conversation: conversation)
                    .environment(\.colorScheme, dark ? .dark : .light))
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 340)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(pinned == nil ? 0.5 : 1.0))
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("compaction-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

private extension NSColor {
    /// The colour as the island's theme draws it.
    func resolved(dark: Bool) -> NSColor {
        var color = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { color = self.usingColorSpace(.sRGB) ?? self }
        return color
    }
}
