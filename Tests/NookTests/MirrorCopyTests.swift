import AppKit
import XCTest
@testable import Nook

/// The copy buttons on Claude's replies and fenced blocks: which reply a character belongs to, the Markdown a reply copies as, the code a
/// block copies as, and the buttons the mirror publishes for the caret.
@MainActor
final class MirrorCopyTests: XCTestCase {
    private func reply(at piece: String, in text: String) -> String? {
        let s = text as NSString
        return MirrorReplies.reply(containing: s.range(of: piece).location, in: s).map(s.substring)
    }

    // MARK: Replies

    func testAReplyRunsFromItsDotToItsLastWords() {
        let text = "> hola\n\n⏺ Primera línea.\n\n  Segundo párrafo,\n  con dos líneas.\n\n⏺ Bash(ls)\n  ⎿  a.txt\n\n⏺ Otra respuesta.\n"
        XCTAssertEqual(reply(at: "con dos", in: text), "⏺ Primera línea.\n\n  Segundo párrafo,\n  con dos líneas.")
        XCTAssertEqual(reply(at: "Primera", in: text), reply(at: "con dos", in: text), "Any of its characters, its first line's too.")
        XCTAssertEqual(reply(at: "Otra", in: text), "⏺ Otra respuesta.", "A reply at the end, without the line break after it.")
        XCTAssertNil(reply(at: "hola", in: text), "A prompt is not Claude's.")
        XCTAssertNil(reply(at: "Bash", in: text), "Nor is a tool call.")
        XCTAssertNil(reply(at: "a.txt", in: text), "Nor its result.")
        XCTAssertEqual(MirrorReplies.last(in: text as NSString).map((text as NSString).substring), "⏺ Otra respuesta.")
        XCTAssertNil(MirrorReplies.last(in: "> solo yo" as NSString))
    }

    func testARecordsReplyCopiesAsTheMarkdownClaudeWrote() {
        let markdown = """
        **Hecho.** Cambié `Sources/App.swift`:

        - una lista
          - anidada con *énfasis*

        ```bash
        swift test --filter Foo
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        > una cita
        """
        // How Claude's record reaches the mirror: the dot on the first line, two columns in front of every other.
        let mirror = "> pregunta\n\n" + TranscriptRenderer.indented("⏺ ", markdown) + "\n\n⏺ Read(x)\n  ⎿  Read 3 lines\n"
        let range = MirrorReplies.reply(containing: (mirror as NSString).range(of: "anidada").location, in: mirror as NSString)
        XCTAssertEqual(range.map { MirrorReplies.markdown((mirror as NSString).substring(with: $0), fromRecord: true) }, markdown)
    }

    /// A paragraph as Claude's terminal wraps it: as many words as fit in `width` columns on each line.
    private func wrapped(_ paragraph: String, width: Int) -> [String] {
        var lines: [String] = []
        for word in paragraph.split(separator: " ").map(String.init) {
            if let last = lines.last, last.count + 1 + word.count <= width { lines[lines.count - 1] = last + " " + word } else { lines.append(word) }
        }
        return lines
    }

    func testAScreensReplyIsJoinedWhereTheTerminalWrappedIt() {
        let first = "El deploy de la 763 falló otra vez al subir (error 408 de red). Dev sigue en web-00654 sin la 763."
        let item = "Mira si agenteA y agenteB siguen vivos. Si alguno no está, dime y te doy su prompt."
        let opening = wrapped(first, width: 48)
        let items = wrapped(item, width: 46)
        var screen = ["⏺ " + opening[0]] + opening.dropFirst().map { "  " + $0 } + [""]
        screen += ["  - " + items[0]] + items.dropFirst().map { "    " + $0 }
        screen += ["  - Sigue la § 6.", "  Corto.", "  Otra línea corta."]
        XCTAssertGreaterThan(opening.count, 2)
        XCTAssertEqual(MirrorReplies.markdown(screen.joined(separator: "\n"), fromRecord: false),
                       [first, "", "- " + item, "- Sigue la § 6.", "Corto.", "Otra línea corta."].joined(separator: "\n"))
        XCTAssertEqual(MirrorReplies.markdown("⏺️ Con el punto en emoji.   ", fromRecord: false), "Con el punto en emoji.")
        XCTAssertEqual(MirrorReplies.markdown("● Con el punto de la pantalla.", fromRecord: false), "Con el punto de la pantalla.")
    }

    // MARK: Blocks

    func testABlockCopiesItsCodeAloneReadyToPaste() {
        XCTAssertEqual(TranscriptCodeBlocks.copyText(["  ```", "  ! bash /Users/me/tmp/deploy-dev.sh", "  ```"]), "! bash /Users/me/tmp/deploy-dev.sh")
        XCTAssertEqual(TranscriptCodeBlocks.copyText(["  ```swift", "  func a() {", "      return 1   ", "  }", "", "  ```"]), "func a() {\n    return 1\n}",
                       "The code's own indent stays; the reply's goes, and so do trailing spaces and blank lines at the end.")
        XCTAssertEqual(TranscriptCodeBlocks.copyText(["     ```sh", "     cd app", "       make", "     ```"]), "cd app\n  make",
                       "A fence indented in a list takes its indent off its lines.")
        XCTAssertEqual(TranscriptCodeBlocks.copyText(["  {\"a\": 1}", "  ```"]), "{\"a\": 1}", "A block opened on Claude's own line starts under it.")
        XCTAssertEqual(TranscriptCodeBlocks.copyText(["  ```", "  sin cerrar"]), "sin cerrar")
    }

    // MARK: Quotes

    func testAQuoteCopiesItsOwnMarkdownWithoutItsMarks() {
        let lines = ["  > Eres el **arquitecto** de VIBE. Lee `.claude/tmp/handoff.md`.", "  >", "  > - Mira si siguen vivos.", "  > - Sigue la § 6.", "  >", ""]
        XCTAssertEqual(TranscriptQuotes.copyText(lines, fromRecord: true),
                       "Eres el **arquitecto** de VIBE. Lee `.claude/tmp/handoff.md`.\n\n- Mira si siguen vivos.\n- Sigue la § 6.",
                       "Its Markdown stays; its marks, the reply's indent and the blank lines at its ends go.")
        XCTAssertEqual(TranscriptQuotes.copyText(["⏺ > En la primera línea.", "  > > Una cita dentro."], fromRecord: true),
                       "En la primera línea.\n> Una cita dentro.", "Claude's dot goes; a quote inside keeps its own mark.")
        // From the screen, the terminal's wraps are joined back.
        XCTAssertEqual(TranscriptQuotes.copyText(["  > Un mensaje largo que la terminal partió", "  > aquí.", "  >", "  > Otro párrafo."], fromRecord: false),
                       "Un mensaje largo que la terminal partió aquí.\n\nOtro párrafo.")
    }

    // MARK: The mirror's buttons

    private func mirror(_ text: String, size: NSSize = NSSize(width: 540, height: 400)) -> (LiveTerminalScrollView, MirrorCopyModel, NSWindow) {
        let scroll = LiveTerminalScrollView(frame: NSRect(origin: .zero, size: size))
        let model = MirrorCopyModel()
        scroll.copyModel = model
        scroll.setTheme(dark: true, transcript: true)
        scroll.setText(text)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        scroll.textView.pasteboard = NSPasteboard(name: NSPasteboard.Name("nook.tests.copy.\(UUID().uuidString)"))
        return (scroll, model, window)
    }

    /// The caret put at `index` and moved one character on with →, as the keyboard moves it.
    private func caret(_ scroll: LiveTerminalScrollView, _ window: NSWindow, at index: Int) throws {
        scroll.textView.setSelectedRange(NSRange(location: index, length: 0))
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        scroll.textView.keyDown(with: right)
    }

    func testTheCaretShowsItsRepliesButtonsAndTheyCopy() throws {
        let markdown = "Corre esto:\n\n```\n! bash /tmp/x.sh\n```\n\nY **listo**."
        let text = "> hola\n\n" + TranscriptRenderer.indented("⏺ ", markdown) + "\n"
        let (scroll, model, window) = mirror(text)
        var copies = 0
        scroll.textView.onCopy = { copies += 1 }
        XCTAssertTrue(window.makeFirstResponder(scroll.textView))
        let s = text as NSString
        // The caret in the command: the reply's button and the block's.
        try caret(scroll, window, at: s.range(of: "/tmp/x.sh").location)
        let reply = try XCTUnwrap(model.reply)
        let code = try XCTUnwrap(model.code)
        XCTAssertEqual(reply.id, s.range(of: "⏺ Corre").location)
        // The reply's button is at the end of its first line; the block's at its tile's top right, under it.
        XCTAssertGreaterThan(reply.frame.minX, 540 - 40)
        XCTAssertLessThanOrEqual(reply.frame.maxX, 540)
        XCTAssertGreaterThan(code.frame.minY, reply.frame.maxY)
        XCTAssertEqual(code.frame.width, TranscriptCodeBlocks.buttonSize)
        model.copy(code)
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), "! bash /tmp/x.sh")
        XCTAssertTrue(code.same(model.copied))
        model.copy(reply)
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), markdown)
        XCTAssertEqual(copies, 2, "The pane says it copied, as for a selection.")
        // On the prompt there is nothing to copy.
        try caret(scroll, window, at: s.range(of: "hola").location)
        XCTAssertNil(model.reply)
        XCTAssertNil(model.code)
        // A click that selects leaves nothing behind once the pointer is elsewhere: only the keyboard's caret brings the buttons.
        scroll.textView.setSelectedRange(NSRange(location: s.range(of: "/tmp/x.sh").location, length: 0))
        XCTAssertNotNil(model.reply, "Still the keyboard's selection.")
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(model.reply, "The text gave the keyboard away.")
    }

    func testTheCaretInAQuoteShowsItsButtonAndItCopiesTheQuote() throws {
        let markdown = "Pégale esto:\n\n> Hola, **equipo**.\n>\n> - Revisen el PR.\n\nY listo."
        let text = TranscriptRenderer.indented("⏺ ", markdown) + "\n"
        let (scroll, model, window) = mirror(text)
        XCTAssertTrue(window.makeFirstResponder(scroll.textView))
        let s = text as NSString
        try caret(scroll, window, at: s.range(of: "Revisen").location)
        let quote = try XCTUnwrap(model.quote)
        let reply = try XCTUnwrap(model.reply)
        XCTAssertEqual(quote.id, s.range(of: "  > Hola").location)
        // At the end of the quote's first line, under the reply's.
        XCTAssertEqual(quote.frame.maxX, reply.frame.maxX, accuracy: 4)
        XCTAssertGreaterThanOrEqual(quote.frame.minY, reply.frame.maxY, "The two buttons never touch.")
        model.copy(quote)
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), "Hola, **equipo**.\n\n- Revisen el PR.")
        model.copy(reply)
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), markdown, "The reply's button still copies it all, its `>` too.")
        try caret(scroll, window, at: s.range(of: "listo").location)
        XCTAssertNil(model.quote)
        let actions = try XCTUnwrap(scroll.textView.accessibilityCustomActions())
        _ = actions.first { $0.name == "Copiar la última cita" }?.handler?()
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), "Hola, **equipo**.\n\n- Revisen el PR.")
    }

    func testVoiceOverCanCopyTheLatestReplyAndBlock() throws {
        let text = TranscriptRenderer.indented("⏺ ", "Uno.\n\n```\nls\n```") + "\n\n" + TranscriptRenderer.indented("⏺ ", "Dos.") + "\n"
        let (scroll, _, _) = mirror(text)
        let actions = try XCTUnwrap(scroll.textView.accessibilityCustomActions())
        let names = actions.map(\.name)
        XCTAssertTrue(names.contains("Copiar la última respuesta de Claude"), "\(names)")
        XCTAssertTrue(names.contains("Copiar el último bloque de código"), "\(names)")
        _ = actions.first { $0.name == "Copiar el último bloque de código" }?.handler?()
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), "ls")
        _ = actions.first { $0.name == "Copiar la última respuesta de Claude" }?.handler?()
        XCTAssertEqual(scroll.textView.pasteboard.string(forType: .string), "Dos.")
    }

    func testAPlainMirrorHasNoButtons() throws {
        let (scroll, model, window) = mirror("⏺ No es Claude.\n")
        scroll.setTheme(dark: true, transcript: false)
        XCTAssertTrue(window.makeFirstResponder(scroll.textView))
        try caret(scroll, window, at: 3)
        XCTAssertNil(model.reply)
        XCTAssertEqual(scroll.textView.accessibilityCustomActions()?.isEmpty ?? true, true)
    }
}
