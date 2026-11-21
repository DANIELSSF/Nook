import AppKit
import XCTest
@testable import Nook

/// The block Markdown of Claude's replies the mirror draws: a fenced block on its tile with its fences taking no room, and a quote
/// with its bars. Characters never change.
@MainActor
final class TranscriptBlocksTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let palette = TranscriptPalette(dark: true)

    private func typing() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }

    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: typing())
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        return storage
    }

    private func at(_ storage: NSTextStorage, _ piece: String, _ key: NSAttributedString.Key) -> Any? {
        storage.attribute(key, at: (storage.string as NSString).range(of: piece).location, effectiveRange: nil)
    }

    private func assertSameAttributes(_ a: NSTextStorage, _ b: NSTextStorage, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.string, b.string, message, file: file, line: line)
        guard a.string == b.string else { return }
        for index in 0..<a.length where !(a.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(b.attributes(at: index, effectiveRange: nil)) {
            return XCTFail("Attributes differ at \(index) in \(a.string.debugDescription). \(message)", file: file, line: line)
        }
    }

    // MARK: Fenced blocks

    private let command = "⏺ Reinténtalo:\n\n  ```\n  ! bash /Users/me/tmp/deploy-dev.sh\n  ```\n\n  Cuando termine, avísame."

    func testAFencedBlockIsATileWhoseFencesTakeNoRoom() throws {
        let storage = styled(command)
        XCTAssertEqual(storage.string, command, "The fences stay in the text: a selection copies the Markdown.")
        let s = storage.string as NSString
        let opening = s.range(of: "  ```\n").location
        let tile = try XCTUnwrap(at(storage, "! bash", .transcriptCodeBlock) as? TranscriptCodeBlock)
        XCTAssertEqual(tile.id, opening, "The block starts at its opening fence.")
        // The tile covers the fences and the code, and nothing around them.
        var range = NSRange(location: 0, length: 0)
        _ = storage.attribute(.transcriptCodeBlock, at: opening, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(s.substring(with: range), "  ```\n  ! bash /Users/me/tmp/deploy-dev.sh\n  ```\n")
        XCTAssertNil(at(storage, "Cuando", .transcriptCodeBlock))
        // Both fences are hidden lines; the code is not.
        XCTAssertNotNil(storage.attribute(.transcriptHiddenLine, at: opening, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.transcriptHiddenLine, at: s.range(of: "  ```", options: .backwards).location, effectiveRange: nil))
        XCTAssertNil(at(storage, "! bash", .transcriptHiddenLine))
        // Code in no language takes inline code's colour, and sits inside the tile with room for its button.
        XCTAssertEqual(at(storage, "! bash", .foregroundColor) as? NSColor, palette.inlineCode)
        let paragraph = try XCTUnwrap(at(storage, "  ! bash", .paragraphStyle) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, TranscriptCodeBlocks.padding)
        XCTAssertEqual(paragraph.tailIndent, -(TranscriptCodeBlocks.padding + TranscriptCodeBlocks.buttonRoom))
        XCTAssertEqual(paragraph.headIndent, TranscriptCodeBlocks.padding + ceil(2 * ("0" as NSString).size(withAttributes: [.font: font]).width), accuracy: 1,
                       "A wrapped command goes on under its first character.")
    }

    func testTheFencesLinesAreSliversOfTheTileInTheLayout() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: command, attributes: typing()))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let manager = try XCTUnwrap(view.layoutManager as? MirrorLayoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let s = storage.string as NSString
        func line(_ index: Int) -> NSRect { manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil) }
        let opening = line(s.range(of: "  ```\n").location)
        let code = line(s.range(of: "! bash").location)
        XCTAssertEqual(opening.height, TranscriptCodeBlocks.fenceHeight, accuracy: 0.5)
        XCTAssertEqual(line(s.range(of: "  ```", options: .backwards).location).height, TranscriptCodeBlocks.fenceHeight, accuracy: 0.5)
        XCTAssertEqual(code.minY, opening.maxY, accuracy: 0.5, "The code starts right under the tile's top edge.")
        // The tile and its button, for the mirror's hover.
        var range = NSRange(location: 0, length: 0)
        let tile = try XCTUnwrap(storage.attribute(.transcriptCodeBlock, at: s.range(of: "! bash").location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? TranscriptCodeBlock)
        let frame = try XCTUnwrap(manager.codeBlockFrame(tile, characters: range))
        XCTAssertEqual(frame.minY, opening.minY, accuracy: 0.5)
        let button = MirrorLayoutManager.codeBlockButton(in: frame, lineHeight: tile.lineHeight)
        XCTAssertEqual(button.maxX, frame.maxX - 2, accuracy: 0.5)
        XCTAssertTrue(frame.contains(button))
    }

    func testABlockWithALanguageIsColouredAndTheReplyGoesOnAfterIt() {
        let storage = styled("⏺ Mira:\n\n  ```swift\n  let a = 1\n  ```\n\n  fuera")
        XCTAssertEqual(at(storage, "let", .foregroundColor) as? NSColor, palette.color(.keyword))
        XCTAssertNotNil(at(storage, "let", .transcriptCodeBlock))
        XCTAssertNil(at(storage, "fuera", .transcriptCodeBlock))
        XCTAssertNil(at(storage, "fuera", .transcriptHiddenLine))
    }

    func testABlockOpenedOnClaudesLineKeepsTheDot() {
        let storage = styled("⏺ ```json\n  {\"a\": 1}\n  ```")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.assistantMarker)
        XCTAssertNil(storage.attribute(.transcriptHiddenLine, at: 0, effectiveRange: nil), "Claude's first line stays a line.")
        XCTAssertNotNil(at(storage, "{\"a\"", .transcriptCodeBlock))
        XCTAssertNotNil(at(storage, "  ```", .transcriptHiddenLine))
    }

    func testABlockGrowingLineByLineMatchesStylingItAtOnce() {
        let text = "⏺ Pasos:\n\n  ```bash\n  cd app\n\n  make test\n  ```\n\n  Y luego:\n\n  ```\n  ls\n  ```\n"
        let storage = NSTextStorage(string: "", attributes: typing())
        var shown = ""
        for character in text {
            shown.append(character)
            let old = storage.string as NSString, new = shown as NSString
            let common = LiveTerminalScrollView.commonPrefix(old, new)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: NSAttributedString(string: new.substring(from: common), attributes: typing()))
            TranscriptStyler.restyle(storage, from: common, dark: true, font: font)
            storage.endEditing()
            assertSameAttributes(storage, styled(shown), "after \(shown.count) characters")
        }
    }

    // MARK: Quotes

    func testAQuoteIsReadAsItsMarksAndItsText() throws {
        let found = try XCTUnwrap(InlineMarkdown.parse("  > Eres el **arquitecto**."))
        XCTAssertEqual(found.quote, 1)
        XCTAssertEqual(found.hang, 4, "Wrapped lines hang under the quote's text.")
        XCTAssertEqual(found.runs.first, InlineMarkdown.Run(range: NSRange(location: 2, length: 2), style: .quoteMark))
        XCTAssertTrue(found.runs.contains { $0.style == [.quote, .bold] })
        XCTAssertEqual(InlineMarkdown.parse("  > > anidada")?.quote, 2)
        XCTAssertEqual(InlineMarkdown.parse("  >")?.quote, 1, "An empty line of a quote is still the quote.")
        XCTAssertEqual(InlineMarkdown.parse("  > - un punto")?.hang, 6)
        XCTAssertEqual(InlineMarkdown.parse("  >= 5 no es una cita")?.quote ?? 0, 0)
        XCTAssertNil(InlineMarkdown.parse("  -> tampoco"))
    }

    func testAQuoteIsQuietSlantedAndBarred() throws {
        let storage = styled("⏺ Para el lunes:\n\n  > Eres el arquitecto.\n  >\n  > - Mira `main`.\n\n  Y listo.")
        XCTAssertEqual(storage.string, "⏺ Para el lunes:\n\n  > Eres el arquitecto.\n  >\n  > - Mira `main`.\n\n  Y listo.")
        XCTAssertEqual(at(storage, "Eres", .foregroundColor) as? NSColor, palette.quote)
        let slanted = try XCTUnwrap(at(storage, "Eres", .font) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: slanted).contains(.italicFontMask) || at(storage, "Eres", .obliqueness) != nil)
        // The mark is not drawn but keeps its room, where the bar goes; every line of the quote has its bar.
        XCTAssertEqual(at(storage, "> Eres", .foregroundColor) as? NSColor, NSColor.clear)
        XCTAssertNil(at(storage, "> Eres", .kern))
        for piece in ["  > Eres", "  >\n", "  > - Mira"] { XCTAssertEqual(at(storage, piece, .transcriptQuote) as? Int, 1, piece) }
        XCTAssertEqual(at(storage, "  > Eres", .transcriptQuoteBar) as? NSColor, palette.quoteBar)
        XCTAssertNil(at(storage, "Y listo", .transcriptQuote))
        // Inline code keeps its own colour inside the quote.
        XCTAssertEqual(at(storage, "main", .foregroundColor) as? NSColor, palette.inlineCode)
    }

    func testEachQuoteIsABlockWithRoomForItsButtonOnItsFirstLine() throws {
        let text = "⏺ Dos mensajes:\n\n  > Hola, equipo.\n  >\n  > - Revisen el PR.\n\n  Y otro:\n\n  > Gracias.\n"
        let storage = styled(text)
        let s = storage.string as NSString
        let first = try XCTUnwrap(at(storage, "Hola", .transcriptQuoteBlock) as? TranscriptQuoteBlock)
        XCTAssertEqual(first.id, s.range(of: "  > Hola").location, "Named by its first line.")
        var range = NSRange(location: 0, length: 0)
        _ = storage.attribute(.transcriptQuoteBlock, at: first.id, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(s.substring(with: range), "  > Hola, equipo.\n  >\n  > - Revisen el PR.\n", "Its empty `>` line is part of it; a blank line ends it.")
        XCTAssertNil(at(storage, "Y otro", .transcriptQuoteBlock))
        let second = try XCTUnwrap(at(storage, "Gracias", .transcriptQuoteBlock) as? TranscriptQuoteBlock)
        XCTAssertNotEqual(second, first, "Quotes apart are blocks apart.")
        // Only the first line keeps room at its end.
        XCTAssertEqual((at(storage, "Hola", .paragraphStyle) as? NSParagraphStyle)?.tailIndent, -TranscriptStyler.replyButtonRoom)
        XCTAssertEqual((at(storage, "Revisen", .paragraphStyle) as? NSParagraphStyle)?.tailIndent, 0)
        // On Claude's first line, beside the reply's button.
        let opening = styled("⏺ > Cita en la primera línea.\n  > y su segunda.")
        XCTAssertEqual((opening.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)?.tailIndent, -2 * TranscriptStyler.replyButtonRoom)
        XCTAssertEqual((at(opening, "y su", .transcriptQuoteBlock) as? TranscriptQuoteBlock)?.id, 0)
    }

    func testAQuoteGrowingLineByLineMatchesStylingItAtOnce() {
        let text = "⏺ Para pegar:\n\n  > Eres el **arquitecto**.\n  >\n  > - uno\n  > - dos\n\n  Fin.\n\n⏺ > Otra.\n  > Más.\n"
        let storage = NSTextStorage(string: "", attributes: typing())
        var shown = ""
        for character in text {
            shown.append(character)
            let old = storage.string as NSString, new = shown as NSString
            let common = LiveTerminalScrollView.commonPrefix(old, new)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: NSAttributedString(string: new.substring(from: common), attributes: typing()))
            TranscriptStyler.restyle(storage, from: common, dark: true, font: font)
            storage.endEditing()
            assertSameAttributes(storage, styled(shown), "after \(shown.count) characters")
        }
    }

    // MARK: Inline code

    func testInlineCodeThatWrapsHugsItsWordsOnEachLine() throws {
        // Drawn into an image: the code's background must not reach the left margin on the line it wraps onto.
        let view = MirrorTextView.makeTranscriptCapable()
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.drawsBackground = false
        let storage = try XCTUnwrap(view.textStorage)
        let text = "⏺ Lee > primero el archivo `.claude/tmp/handoff-2026-11-23.md` completo."
        storage.setAttributedString(NSAttributedString(string: text, attributes: typing()))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let manager = try XCTUnwrap(view.layoutManager)
        let s = storage.string as NSString
        let second = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: s.range(of: "handoff").location), effectiveRange: nil)
        let first = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: s.range(of: "Lee").location), effectiveRange: nil)
        XCTAssertGreaterThan(second.minY, first.minY, "The code wraps in this width.")
        // A point in the margin left of where the reply's text starts, on the wrapped line: no background there.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let y = Int((second.midY + view.textContainerOrigin.y) * scale)
        let alpha = rep.colorAt(x: Int(4 * scale), y: y)?.alphaComponent ?? 0
        XCTAssertLessThan(alpha, 0.01)
    }
}
