import XCTest
import AppKit
@testable import Nook

final class TranscriptClassifierTests: XCTestCase {
    private func roles(_ text: String) -> [TranscriptRole] { TranscriptClassifier.roles(of: text) }

    func testUserMessagesAreRecognisedAtTheLeftEdge() {
        XCTAssertEqual(roles("> hola"), [.user])
        XCTAssertEqual(roles("❯ hola"), [.user])
        XCTAssertEqual(roles("> /compact"), [.user])
    }

    func testWrappedLinesAndLaterParagraphsStayInTheirMessage() {
        let text = ["> una frase larga que Claude partió", "  en dos líneas", "", "  y un segundo párrafo", "", "⏺ Hecho."].joined(separator: "\n")
        XCTAssertEqual(roles(text), [.user, .user, .plain, .user, .plain, .assistant])
    }

    func testRepliesAndTheirContinuations() {
        let text = ["⏺ Primer párrafo que se", "  parte en dos.", "", "  Segundo párrafo.", "  1. punto", "     sangrado"].joined(separator: "\n")
        XCTAssertEqual(roles(text), [.assistant, .assistant, .plain, .assistant, .assistant, .assistant])
        XCTAssertEqual(roles("● Hola"), [.assistant], "Claude draws ● where ⏺ is missing.")
        XCTAssertEqual(roles("⏺"), [.assistant], "A bare dot is Claude starting to write.")
    }

    func testToolCallsAreToolsWhateverTheirName() {
        for line in ["⏺ Bash(swift test --filter X)", "⏺ Read(Sources/Nook/Session.swift)", "⏺ MultiEdit(a.swift)", "⏺ Agent(Design cat pet animations)",
                     "⏺ mcp__slack__search(query: \"x\")", "⏺ codex:codex-rescue(Fix the flaky test)", "⏺ slack - Search messages (MCP)(query: \"x\")",
                     "⏺ Read 3 files (ctrl+o to expand)", "⏺ Running 3 Explore agents…  (ctrl+o to expand)", "⏺ 2 background agents launched (↓ to manage)",
                     "⏺ Bash(cat <<'EOF'"] {
            XCTAssertEqual(roles(line), [.tool], line)
        }
    }

    func testToolResultsAndTheirContinuation() {
        let text = ["⏺ Bash(swift test)", "  ⎿  Test Suite passed", "     Executed 14 tests", "", "     más salida tras un hueco", "⏺ Listo"].joined(separator: "\n")
        XCTAssertEqual(roles(text), [.tool, .toolOutput, .toolOutput, .plain, .toolOutput, .assistant])
        // The wrapped arguments of a call belong to the call's block, not to the reply that follows.
        XCTAssertEqual(roles(["⏺ Bash(echo uno &&", "  echo dos)", "  ⎿  uno", "⏺ Ok"].joined(separator: "\n")), [.tool, .toolOutput, .toolOutput, .assistant])
    }

    func testResultsKeepTheirPlaceInAnyBlock() {
        XCTAssertEqual(roles(["> /cost", "  ⎿  Total cost: $0.12", "     Total duration: 5s"].joined(separator: "\n")), [.user, .toolOutput, .toolOutput])
        XCTAssertEqual(roles(["⏺ Hecho.", "  ⎿  Tip: usa /help", "", "⏺ Otra"].joined(separator: "\n")), [.assistant, .toolOutput, .plain, .assistant])
        XCTAssertEqual(roles("  ⎿  Sin cabecera"), [.toolOutput])
    }

    func testBlankLinesAreNeverStyledAndKeepTheBlockOpen() {
        XCTAssertEqual(roles(""), [.plain])
        XCTAssertEqual(roles("\n\n"), [.plain, .plain, .plain])
        XCTAssertEqual(roles(["⏺ a", "   ", "  b"].joined(separator: "\n")), [.assistant, .plain, .assistant], "A line of spaces is blank.")
    }

    func testDoubtfulLinesStayPlain() {
        // Menu options, not messages.
        XCTAssertEqual(roles("❯ 1. Yes"), [.plain])
        XCTAssertEqual(roles("> 2) No"), [.plain])
        // No space after the mark, or nothing after it.
        XCTAssertEqual(roles(">hola"), [.plain])
        XCTAssertEqual(roles(">> hola"), [.plain])
        XCTAssertEqual(roles("> "), [.plain])
        XCTAssertEqual(roles("❯"), [.plain])
        XCTAssertEqual(roles("⏺hola"), [.plain], "A dot glued to a word is not a marker.")
        // Shell prompts and other left-edge text.
        XCTAssertEqual(roles("! ls"), [.plain])
        XCTAssertEqual(roles("$ git status"), [.plain])
        XCTAssertEqual(roles("✻ Welcome to Claude Code!"), [.plain])
        XCTAssertEqual(roles("╭──────────────╮"), [.plain])
        XCTAssertEqual(roles("│ ✻ Welcome │"), [.plain])
        XCTAssertEqual(roles("※ Tip: usa /help"), [.plain])
    }

    func testReplyTextThatLooksLikeSomethingElseStaysAReply() {
        XCTAssertEqual(roles("⏺ print(x) imprime x"), [.assistant], "A lowercase word before a parenthesis is a sentence.")
        XCTAssertEqual(roles("⏺ El Agent(foo) del que hablas ya terminó"), [.assistant])
        XCTAssertEqual(roles("⏺ 3 agents are great for this"), [.assistant])
        XCTAssertEqual(roles("⏺ Listo (ver arriba)"), [.assistant])
        XCTAssertEqual(roles("⏺ Hecho. Mira el resultado (ctrl+o to expand) si quieres."), [.assistant], "Only a hint at the end of the line counts.")
        XCTAssertEqual(roles(["⏺ Así se ve una llamada:", "  ⏺ Agent(Design cat)", "    ⎿  Done", "  > cita"].joined(separator: "\n")),
                       [.assistant, .assistant, .toolOutput, .toolOutput], "Indented dots and quotes are inside the reply; a result stays a result.")
    }

    func testIndentedMarksNeverOpenABlock() {
        XCTAssertEqual(roles("  > hola"), [.plain])
        XCTAssertEqual(roles("    ⏺ Bash(ls)"), [.plain])
        XCTAssertEqual(roles(" > hola"), [.user], "One space of slack, like the rest of Nook's Claude parsing.")
        XCTAssertEqual(roles(" ⏺ Hola"), [.assistant])
    }

    func testAnUnknownLeftEdgeLineEndsTheBlock() {
        let text = ["> hola", "  sigue", "✻ algo raro", "  sangrado tras la línea rara", "⏺ ok"].joined(separator: "\n")
        XCTAssertEqual(roles(text), [.user, .user, .plain, .plain, .assistant])
        XCTAssertEqual(roles("  texto sangrado al principio\n  otra"), [.plain, .plain], "A screen cut in the middle of a block opens nothing.")
    }

    func testOutputFlagSurvivesAnUnknownLeftEdgeLine() {
        // After a plain line a "⎿" still turns what follows into results, as when classifying from the top.
        XCTAssertEqual(roles(["texto", "  ⎿  uno", "     dos"].joined(separator: "\n")), [.plain, .toolOutput, .toolOutput])
    }

    func testClassifyingFromAnyLineGivesTheRolesOfTheWholeTail() {
        let samples = [
            "> a\n  b\n\n  c\n\n⏺ r\n  s\n\n⏺ Bash(x)\n  ⎿  o\n     p\n\n  q\n⏺ z\n> y\n  ⎿  out\n     more\nplain\n  ind\n⏺ \n",
            "  ⎿  x\n  y\n> u\n\n\n  v\n✻ w\n  ⎿  z\n  t\n⏺ Read 2 files (ctrl+o to expand)\n  ⎿  Read\n\n> ok",
            "",
            "\n\n⏺ a\n\n\n",
        ]
        for text in samples {
            let lines = text.components(separatedBy: "\n")
            let all = TranscriptClassifier.roles(of: lines)
            for first in 0..<lines.count {
                XCTAssertEqual(TranscriptClassifier.roles(of: lines, from: first), Array(all[first...]), "from \(first) in \(text.debugDescription)")
            }
        }
    }

    func testLinesCarryTheirMarkersAndBlockHeads() throws {
        let text = "> hola\n  mundo\n\n⏺ Bash(ls)\n  ⎿  a\n⏺ Listo" as NSString
        let lines = TranscriptClassifier.lines(in: text)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[0].marker, NSRange(location: 0, length: 1))
        XCTAssertEqual(lines[0].head, 0)
        XCTAssertEqual(lines[1].head, 0, "A wrapped line belongs to the message that opened it.")
        XCTAssertTrue(lines[2].isBlank)
        let call = lines[3]
        XCTAssertEqual(text.substring(with: try XCTUnwrap(call.marker)), "⏺")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(call.name)), "Bash")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(lines[4].marker)), "⎿")
        XCTAssertEqual(lines[4].head, call.range.location)
        XCTAssertEqual(lines[5].end, text.length)
        XCTAssertNil(lines[5].name)
    }

    func testAVariationSelectorStaysInsideTheMarker() throws {
        let text = "⏺\u{FE0F} Hola" as NSString
        let line = try XCTUnwrap(TranscriptClassifier.lines(in: text).first)
        XCTAssertEqual(line.role, .assistant)
        XCTAssertEqual(line.marker, NSRange(location: 0, length: 2))
    }

    func testWindowsLineEndingsAndNonBreakingSpacesDoNotMatter() {
        XCTAssertEqual(roles("> hola\r\n  mundo\r\n\r\n⏺ Ok\r\n"), [.user, .user, .plain, .assistant, .plain])
        XCTAssertEqual(roles("> hola\n\u{00A0}\u{00A0}mundo"), [.user, .user])
    }
}

@MainActor
final class TranscriptStylerTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private func typing(dark: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black, .paragraphStyle: paragraph]
    }

    private func styled(_ text: String, dark: Bool = true) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: typing(dark: dark))
        TranscriptStyler.restyle(storage, from: 0, dark: dark, font: font)
        return storage
    }

    /// What the scroll view does for each screen update: replace the changed tail, then restyle from there.
    private func update(_ storage: NSTextStorage, to text: String, dark: Bool = true) {
        let old = storage.string as NSString
        let new = text as NSString
        let common = LiveTerminalScrollView.commonPrefix(old, new)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: common, length: old.length - common),
                                  with: NSAttributedString(string: new.substring(from: common), attributes: typing(dark: dark)))
        TranscriptStyler.restyle(storage, from: common, dark: dark, font: font)
        storage.endEditing()
    }

    private func assertSameAttributes(_ a: NSTextStorage, _ b: NSTextStorage, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.string, b.string, message(), file: file, line: line)
        guard a.string == b.string else { return }
        for index in 0..<a.length {
            let left = a.attributes(at: index, effectiveRange: nil) as NSDictionary
            let right = b.attributes(at: index, effectiveRange: nil) as NSDictionary
            if !left.isEqual(right) {
                XCTFail("Attributes differ at \(index) (\((a.string as NSString).substring(with: NSRange(location: index, length: 1)).debugDescription)) in \(a.string.debugDescription): \(left) vs \(right). \(message())", file: file, line: line)
                return
            }
        }
    }

    private func columnWidth(of font: NSFont) -> CGFloat {
        var space: unichar = 0x20
        var glyph = CGGlyph(0)
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &space, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return advance.width
    }

    private func attribute<T>(_ key: NSAttributedString.Key, in storage: NSTextStorage, at text: String, occurrence: Int = 0) -> T? {
        var range = NSRange(location: 0, length: 0)
        var from = 0
        for _ in 0...occurrence {
            range = (storage.string as NSString).range(of: text, options: [], range: NSRange(location: from, length: storage.length - from))
            from = NSMaxRange(range)
        }
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(key, at: range.location, effectiveRange: nil) as? T
    }

    // MARK: Look per role

    private let conversation = [
        "> arregla el notch", "  y agrega una prueba", "", "⏺ Bash(swift test)", "  ⎿  Executed 14 tests", "     con 0 fallos", "",
        "⏺ Listo, todo en verde.", "  Segunda línea.", "", "$ salida suelta",
    ].joined(separator: "\n")

    func testEachRoleGetsItsOwnLook() throws {
        let storage = styled(conversation)
        let palette = TranscriptPalette(dark: true)
        func color(_ text: String) -> NSColor? { attribute(.foregroundColor, in: storage, at: text) }
        func size(_ text: String) -> CGFloat? { (attribute(.font, in: storage, at: text) as NSFont?)?.pointSize }

        XCTAssertEqual(color("arregla"), palette.userText)
        XCTAssertEqual(color(">"), palette.userMarker)
        XCTAssertEqual(color("Listo"), palette.text)
        XCTAssertEqual(color("⏺ Listo"), palette.assistantMarker)
        XCTAssertEqual(color("Bash"), palette.toolName)
        XCTAssertEqual(color("swift test"), palette.tool)
        XCTAssertEqual(color("Executed"), palette.output)
        XCTAssertEqual(color("con 0 fallos"), palette.output)
        XCTAssertEqual(color("$ salida"), palette.text)
        // Tool lines step back by a point; replies and the user keep the mirror's size.
        XCTAssertEqual(size("Executed"), 10)
        XCTAssertEqual(size("swift test"), 10)
        XCTAssertEqual(size("Listo"), 11)
        XCTAssertEqual(size("arregla"), 11)
    }

    func testTheDotTakesClaudesColorAndOneColumn() throws {
        let storage = styled("⏺ Hola\n  mundo")
        let palette = TranscriptPalette(dark: true)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.assistantMarker)
        let marker = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // The color emoji font is the system's fallback for ⏺ and ignores the text color; the dot needs a text font.
        if NSFont(name: "STIXTwoMath-Regular", size: 12) != nil {
            XCTAssertFalse(marker.fontName.localizedCaseInsensitiveContains("emoji"), "\(marker.fontName)")
            XCTAssertEqual(marker.fontName, "STIXTwoMath-Regular")
            // dot + kern + the space after it must span the same two columns as the indent of the lines under it.
            let kern = try XCTUnwrap(storage.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat)
            let column = columnWidth(of: font)
            var char: unichar = 0x23FA
            var glyph = CGGlyph(0)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(marker, &char, &glyph, 1))
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(marker, .horizontal, &glyph, &advance, 1)
            XCTAssertEqual(advance.width + kern, column, accuracy: 0.05)
        }
    }

    func testTheResultMarkerKeepsTheColumnOfTheTextAfterIt() throws {
        let storage = styled("⏺ Bash(ls)\n  ⎿  a\n     b")
        let mark = (storage.string as NSString).range(of: "⎿")
        let font = try XCTUnwrap(storage.attribute(.font, at: mark.location, effectiveRange: nil) as? NSFont)
        let kern = try XCTUnwrap(storage.attribute(.kern, at: mark.location, effectiveRange: nil) as? CGFloat)
        var char: unichar = 0x23BF
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &char, &glyph, 1) else { return XCTFail("\(font.fontName) lacks ⎿") }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        XCTAssertEqual(advance.width + kern, columnWidth(of: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)), accuracy: 0.05)
    }

    func testAMarkerThatNeedsNoFontKeepsTheMonospacedFontAndHeight() throws {
        // "●" is in the monospaced font; "⏺" + variation selector is an emoji whatever the font. Neither gets the dot's font.
        for marker in ["●", "⏺\u{FE0F}"] {
            let storage = styled("\(marker) Hola\n  mundo")
            let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertNotEqual(font.fontName, "STIXTwoMath-Regular", marker)
            XCTAssertNil(storage.attribute(.kern, at: 0, effectiveRange: nil), marker)
            XCTAssertEqual((storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing, 0, marker)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, TranscriptPalette(dark: true).assistantMarker, marker)
        }
    }

    func testOnlyUserMessagesCarryABubbleAndEachMessageHasItsOwn() throws {
        let storage = styled("> uno\n  dos\n\n> tres\n> cuatro\n⏺ Hola\n  ⎿  salida")
        func bubble(_ text: String) -> TranscriptBubble? { attribute(.transcriptBubble, in: storage, at: text) }
        let first = try XCTUnwrap(bubble("uno"))
        XCTAssertEqual(first, try XCTUnwrap(bubble("dos")), "A wrapped line is the same block.")
        XCTAssertNil(storage.attribute(.transcriptBubble, at: ("> uno\n  dos\n" as NSString).length, effectiveRange: nil), "The blank line between messages has no block.")
        let third = try XCTUnwrap(bubble("tres")), fourth = try XCTUnwrap(bubble("cuatro"))
        XCTAssertNotEqual(first, third)
        XCTAssertNotEqual(third, fourth, "Back-to-back messages are two blocks.")
        XCTAssertNil(bubble("Hola"))
        XCTAssertNil(bubble("salida"))
        XCTAssertNotNil(storage.attribute(.transcriptBubble, at: 0, effectiveRange: nil), "The marker belongs to the block.")
    }

    func testLinesThatAreNotClaudesAreIdenticalToUnstyledText() {
        let text = "$ ls -la\ntotal 8\n  drwxr-xr-x  3 user\n❯ 1. Yes\n╭────╮\n✻ Welcome"
        let storage = styled(text)
        let plain = NSTextStorage(string: text, attributes: typing(dark: true))
        assertSameAttributes(storage, plain, "Plain lines must keep the mirror's own attributes.")
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.transcriptRole])
            XCTAssertNil(attributes[.transcriptBubble])
            XCTAssertNil(attributes[.kern])
        }
    }

    func testStylingNeverChangesTheCharacters() {
        let storage = styled(conversation)
        XCTAssertEqual(storage.string, conversation)
    }

    func testBlankLinesAreCompactAndGapsAppearOnlyWhereNothingSeparatesBlocks() throws {
        let storage = styled("> hola\n\n⏺ Hecho\n> otro\n  ⎿  salida\n⏺ Fin")
        func paragraph(_ text: String) throws -> NSParagraphStyle { try XCTUnwrap(attribute(.paragraphStyle, in: storage, at: text)) }
        let blank = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(blank.maximumLineHeight, TranscriptStyler.blankLineHeight)
        XCTAssertEqual(try paragraph("Hecho").paragraphSpacingBefore, 0, "A blank line already separates it from the message.")
        XCTAssertEqual(try paragraph("otro").paragraphSpacingBefore, 0)
        XCTAssertEqual(try paragraph("salida").paragraphSpacingBefore, TranscriptStyler.gapAfterBubble, "Nothing separates a result from the message above.")
        XCTAssertEqual(try paragraph("Fin").paragraphSpacingBefore, 0)
        let storage2 = styled("> uno\n> dos")
        XCTAssertEqual(try XCTUnwrap(attribute(.paragraphStyle, in: storage2, at: "dos") as NSParagraphStyle?).paragraphSpacingBefore, TranscriptStyler.gapAfterBubble)
    }

    func testThemesChangeColorsAndNothingElse() throws {
        let dark = styled(conversation, dark: true)
        let light = styled(conversation, dark: false)
        XCTAssertNotEqual(attribute(.foregroundColor, in: dark, at: "arregla") as NSColor?, attribute(.foregroundColor, in: light, at: "arregla") as NSColor?)
        XCTAssertNotEqual(attribute(.transcriptBubble, in: dark, at: "arregla") as TranscriptBubble?, attribute(.transcriptBubble, in: light, at: "arregla") as TranscriptBubble?)
        let darkBubble: TranscriptBubble? = attribute(.transcriptBubble, in: dark, at: "arregla")
        let lightBubble: TranscriptBubble? = attribute(.transcriptBubble, in: light, at: "arregla")
        XCTAssertEqual(darkBubble?.id, lightBubble?.id)
        // Restyling dark text for the light theme gives what styling it for light from the start gives.
        let recolored = styled(conversation, dark: true)
        TranscriptStyler.restyle(recolored, from: 0, dark: false, font: font)
        assertSameAttributes(recolored, light)
    }

    func testResetGivesBackPlainText() {
        let storage = styled(conversation)
        TranscriptStyler.reset(storage, dark: true, font: font)
        assertSameAttributes(storage, NSTextStorage(string: conversation, attributes: typing(dark: true)))
    }

    func testWorksOnEmptyAndTinyText() {
        let storage = NSTextStorage()
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        TranscriptStyler.restyle(storage, from: 5, dark: true, font: font)
        TranscriptStyler.reset(storage, dark: true, font: font)
        XCTAssertEqual(storage.length, 0)
        update(storage, to: "\n")
        update(storage, to: ">")
        update(storage, to: "> ")
        update(storage, to: "> a")
        update(storage, to: "")
        XCTAssertEqual(storage.length, 0)
    }

    // MARK: Incremental restyle

    func testGrowingOneCharacterAtATimeMatchesStylingEverythingAtOnce() {
        let text = (conversation + "\n\n> otra pregunta\n  larga\n\n⏺ Read(a.swift)\n  ⎿  Read 3 lines (ctrl+o to expand)\n⏺ ok").replacingOccurrences(of: "\n\n\n", with: "\n\n")
        let storage = NSTextStorage(string: "", attributes: typing(dark: true))
        var shown = ""
        for character in text {
            shown.append(character)
            update(storage, to: shown)
            if shown.hasSuffix("\n") || shown.count % 7 == 0 { assertSameAttributes(storage, styled(shown), "after \(shown.count) characters") }
        }
        assertSameAttributes(storage, styled(text))
    }

    func testRandomEditsRestyleLikeAFullPass() {
        var random = SeededRandom(seed: 0x4E00C)
        let pool = [
            "> pregunta corta", "❯ otra pregunta", "  continuación sangrada", "", "", "   ", "⏺ Respuesta de Claude", "⏺ Bash(swift test)", "⏺ Read 3 files (ctrl+o to expand)", "⏺",
            "  ⎿  resultado", "     más resultado", "texto suelto", "$ ls", "❯ 1. Yes", "> ", "  > cita sangrada", "⏺ print(x) es una frase", "✻ Pensando…", "  ⎿  Done (1 tool use)", "   ⏺ no es marcador",
            " ⏺ casi en el borde", "⏺ Update(a.swift)", "      294 + línea de diff",
            // A change's summary and rows, a new file's, and the fences of a reply (also unclosed, and as the reply's first line).
            "  ⎿  Actualizado Sources/a.swift (+1 -1)", "  ⎿  Creado notas.md (2 líneas)", "      12 - let a = 1", "      12 + let b = \"x\" // y", "      13   contexto",
            "          … ", "      … +4 líneas", "      14", "  ```swift", "  let x = 1", "  ```", "⏺ ```py", "  ```", "  ~~~", "    return 1",
            // Markdown in replies (and the look-alikes that must stay as they are).
            "⏺ **Cómo queda:** hola `x` y *cursiva*", "  ## Título **fuerte**", "  - punto con `código`", "  * otro _punto_", "  2 * 3 * 4 y file_name_here", "  [guía](https://x.com/a_b) y más",
            "  `sin cerrar", "> **mi** mensaje `x`", "  ⎿  **salida** `y`", "  ```raro", "  **dentro** de una valla",
        ]
        for round in 0..<150 {
            var lines = (0..<Int(random.next(below: 14)) + 1).map { _ in pool[Int(random.next(below: UInt64(pool.count)))] }
            let storage = NSTextStorage(string: "", attributes: typing(dark: round % 3 != 0))
            let dark = round % 3 != 0
            var text = lines.joined(separator: "\n")
            update(storage, to: text, dark: dark)
            for step in 0..<12 {
                switch random.next(below: 6) {
                case 0: lines.append(pool[Int(random.next(below: UInt64(pool.count)))])                                  // new line at the end
                case 1: if !lines.isEmpty { lines.removeLast() }                                                         // screen shrinks
                case 2: if !lines.isEmpty { lines.insert(pool[Int(random.next(below: UInt64(pool.count)))], at: Int(random.next(below: UInt64(lines.count)))) }
                case 3: if !lines.isEmpty { lines[Int(random.next(below: UInt64(lines.count)))] = pool[Int(random.next(below: UInt64(pool.count)))] }
                case 4: if !lines.isEmpty { lines.remove(at: Int(random.next(below: UInt64(lines.count)))) }
                default:
                    // The last line grows or is cut, as streamed text does.
                    if let last = lines.last { lines[lines.count - 1] = random.next(below: 2) == 0 ? last + " más" : String(last.dropLast(Int(random.next(below: 4)))) }
                }
                text = lines.joined(separator: "\n") + (random.next(below: 4) == 0 ? "\n" : "")
                update(storage, to: text, dark: dark)
                assertSameAttributes(storage, styled(text, dark: dark), "round \(round) step \(step)")
            }
        }
    }

    func testAnOpenUserMessageIsRestyledFromItsFirstLine() {
        let storage = styled("⏺ Hola\n\n> una frase\n  que sigue")
        update(storage, to: "⏺ Hola\n\n> una frase\n  que sigue\n  y sigue más")
        let bubbleIDs = Set((0..<storage.length).compactMap { (storage.attribute(.transcriptBubble, at: $0, effectiveRange: nil) as? TranscriptBubble)?.id })
        XCTAssertEqual(bubbleIDs.count, 1)
        // Its first line is rewritten, so the display repaints the whole block, not only the new line.
        let recorder = EditRecorder()
        storage.delegate = recorder
        update(storage, to: "⏺ Hola\n\n> una frase\n  que sigue\n  y sigue más\n  y todavía más")
        XCTAssertEqual(recorder.edited.first?.location, ("⏺ Hola\n\n" as NSString).length)
    }

    func testAnUpdateAtTheEndOnlyTouchesTheTailOfALongTranscript() {
        var lines: [String] = []
        for index in 0..<1500 { lines += ["> pregunta \(index)", "", "⏺ Respuesta \(index) con algo de texto para que la línea sea larga", "  ⎿  salida", ""] }
        let text = lines.joined(separator: "\n")
        XCTAssertGreaterThan(text.count, 60_000)
        let storage = styled(text)
        let recorder = EditRecorder()
        storage.delegate = recorder
        update(storage, to: text + "\n⏺ Nueva línea")
        update(storage, to: text + "\n⏺ Nueva línea que crece")
        let first = (text as NSString).length - 8
        for range in recorder.edited { XCTAssertGreaterThan(range.location, first, "Restyling reached back to \(range.location) in \(storage.length) characters.") }
        XCTAssertEqual(recorder.edited.count, 2)
    }

    func testStylingALongTranscriptStaysFast() {
        var lines: [String] = []
        for index in 0..<1500 { lines += ["> pregunta \(index)", "", "⏺ Respuesta \(index) con algo de texto para que la línea sea larga", "  ⎿  salida", ""] }
        let text = lines.joined(separator: "\n")
        let started = Date()
        let storage = styled(text)
        let full = Date().timeIntervalSince(started)
        let tailStarted = Date()
        update(storage, to: text + "\n⏺ Nueva línea")
        let tail = Date().timeIntervalSince(tailStarted)
        XCTAssertLessThan(full, 2.0, "A full pass over 60,000 characters took \(full) s.")
        XCTAssertLessThan(tail, 0.1, "A tail update took \(tail) s.")
    }

    // MARK: Drawing

    func testTheBubbleIsPaintedBehindTheMessageOnly() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        XCTAssertTrue(view.layoutManager is MirrorLayoutManager)
        XCTAssertNil(view.textLayoutManager, "The mirror must stay on TextKit 1 for its layout manager.")
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: "⏺ Antes\n\n> mensaje\n\n⏺ Después", attributes: typing(dark: false)))
        TranscriptStyler.restyle(storage, from: 0, dark: false, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)

        let text = storage.string as NSString
        func lineRect(_ word: String) -> NSRect {
            let glyphs = manager.glyphRange(forCharacterRange: text.range(of: word), actualCharacterRange: nil)
            return manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func alpha(_ point: NSPoint) -> CGFloat { rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.alphaComponent ?? -1 }
        let message = lineRect("mensaje")
        XCTAssertGreaterThan(alpha(NSPoint(x: 150, y: message.midY)), 0.05, "The message's block is painted at the right of its text.")
        XCTAssertGreaterThan(alpha(NSPoint(x: 150, y: message.minY - 1.5)), 0.05, "…and a little above and below the line.")
        XCTAssertEqual(alpha(NSPoint(x: 150, y: lineRect("Antes").midY)), 0, accuracy: 0.001, "A reply has no block.")
        XCTAssertEqual(alpha(NSPoint(x: 150, y: lineRect("Después").midY)), 0, accuracy: 0.001)
        XCTAssertEqual(alpha(NSPoint(x: 150, y: message.maxY + 7)), 0, accuracy: 0.001, "The block does not spill past its padding.")
        // The block spans the text container: from its left edge, and no further.
        XCTAssertGreaterThan(alpha(NSPoint(x: 3, y: message.midY)), 0.05)
        XCTAssertEqual(alpha(NSPoint(x: 0.5, y: message.midY)), 0, accuracy: 0.001)
    }

    func testGrowingAMessageRepaintsItsWholeBlock() throws {
        // The block's rounded bottom is drawn once; when the message grows, the old bottom must be repainted too.
        let storage = NSTextStorage()
        let layout = MirrorLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container)
        view.textContainerInset = NSSize(width: 2, height: 4)
        let first = "⏺ Antes\n\n> una frase\n  que sigue"
        storage.setAttributedString(NSAttributedString(string: first, attributes: typing(dark: true)))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        layout.ensureLayout(for: container)
        let oldLast = layout.lineFragmentRect(forGlyphAt: layout.glyphRange(forCharacterRange: (first as NSString).range(of: "que sigue"), actualCharacterRange: nil).location, effectiveRange: nil)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        view.dirty.removeAll()
        update(storage, to: first + "\n  y todavía más")
        layout.ensureLayout(for: container)
        let corner = NSRect(x: 2, y: oldLast.maxY - 4, width: 6, height: 4)
        XCTAssertTrue(view.dirty.contains { $0.intersects(corner) }, "The old bottom edge at \(corner) was not invalidated: \(view.dirty)")
    }

    func testNeighbouringBlocksStayApart() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: "> uno\n> dos", attributes: typing(dark: false)))
        TranscriptStyler.restyle(storage, from: 0, dark: false, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let first = manager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil).offsetBy(dx: 0, dy: view.textContainerOrigin.y)
        let second = manager.lineFragmentUsedRect(forGlyphAt: manager.glyphRange(forCharacterRange: (storage.string as NSString).range(of: "dos"), actualCharacterRange: nil).location, effectiveRange: nil)
            .offsetBy(dx: 0, dy: view.textContainerOrigin.y)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func alpha(y: CGFloat) -> CGFloat { rep.colorAt(x: Int(150 * scale), y: Int(y * scale))?.alphaComponent ?? -1 }
        XCTAssertGreaterThan(alpha(y: first.midY), 0.05)
        XCTAssertGreaterThan(alpha(y: second.midY), 0.05)
        let gap = (first.maxY + MirrorLayoutManager.verticalPadding + second.minY - MirrorLayoutManager.verticalPadding) / 2
        XCTAssertGreaterThan(second.minY - first.maxY, 2 * MirrorLayoutManager.verticalPadding, "The second message's line sits further down than the padding of both blocks.")
        XCTAssertEqual(alpha(y: gap), 0, accuracy: 0.001, "Two messages in a row are two blocks with a gap, not one.")
    }

    func testLineHeightsDoNotGrowBecauseOfTheMarkers() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: "> uno\n  dos\n\n⏺ Hola\n  mundo\n\n⏺ Bash(ls)\n  ⎿  a\n     b\n\nplano", attributes: typing(dark: true)))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        var heights: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in heights.append(rect.height) }
        XCTAssertEqual(heights.count, 11)
        for (index, height) in heights.enumerated() {
            if [2, 5, 9].contains(index) { XCTAssertEqual(height, TranscriptStyler.blankLineHeight, "blank line \(index)"); continue }
            // A symbol font may add a point to its own line; nothing may add the 4 points the dot's leading would.
            XCTAssertLessThanOrEqual(height, 14.01, "line \(index)")
            XCTAssertGreaterThanOrEqual(height, 11.99, "line \(index)")
        }
    }
}

/// A text view that remembers what it was asked to repaint.
private final class RecordingTextView: NSTextView {
    var dirty: [NSRect] = []
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        dirty.append(rect)
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }
}

/// Records the edited ranges the text storage reports, to see how far back restyling reaches.
private final class EditRecorder: NSObject, NSTextStorageDelegate {
    var edited: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        edited.append(editedRange)
    }
}

/// A small deterministic generator, so a failing round can be replayed.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next(below limit: UInt64) -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return (state >> 33) % max(1, limit)
    }
}
