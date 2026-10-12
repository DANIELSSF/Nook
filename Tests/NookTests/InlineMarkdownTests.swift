import XCTest
import AppKit
@testable import Nook

/// What the parser finds in a line of a reply.
final class InlineMarkdownTests: XCTestCase {
    /// The dressed stretches of a line as (text, style) pairs, in order.
    private func found(_ line: String) -> [(text: String, style: MarkupStyle)] {
        let text = line as NSString
        return InlineMarkdown.parse(line)?.runs.map { (text.substring(with: $0.range), $0.style) } ?? []
    }

    private func assertRuns(_ line: String, _ expected: [(String, MarkupStyle)], file: StaticString = #filePath, line number: UInt = #line) {
        let actual = found(line)
        XCTAssertEqual(actual.map(\.text), expected.map(\.0), line, file: file, line: number)
        XCTAssertEqual(actual.map(\.style.rawValue), expected.map(\.1.rawValue), line, file: file, line: number)
    }

    private func assertPlain(_ line: String, file: StaticString = #filePath, line number: UInt = #line) {
        let actual = found(line)
        XCTAssertTrue(actual.isEmpty, "\(line.debugDescription) was dressed: \(actual)", file: file, line: number)
    }

    // MARK: Emphasis

    func testBoldAndItalicShowTheirTextAndHideTheirMarks() {
        assertRuns("**Cómo queda:**", [("**", .hidden), ("Cómo queda:", .bold), ("**", .hidden)])
        assertRuns("__negrita__", [("__", .hidden), ("negrita", .bold), ("__", .hidden)])
        assertRuns("*cursiva*", [("*", .hidden), ("cursiva", .italic), ("*", .hidden)])
        assertRuns("_cursiva_", [("_", .hidden), ("cursiva", .italic), ("_", .hidden)])
        assertRuns("***ambas***", [("***", .hidden), ("ambas", [.bold, .italic]), ("***", .hidden)])
        assertRuns("uno **dos** tres", [("**", .hidden), ("dos", .bold), ("**", .hidden)])
    }

    func testEmphasisNestsAndMixes() {
        assertRuns("**negrita *y cursiva* más**", [("**", .hidden), ("negrita ", .bold), ("*", .hidden), ("y cursiva", [.bold, .italic]), ("*", .hidden), (" más", .bold), ("**", .hidden)])
        assertRuns("*uno* y **dos**", [("*", .hidden), ("uno", .italic), ("*", .hidden), ("**", .hidden), ("dos", .bold), ("**", .hidden)])
        // Marks that touch are one hidden stretch.
        assertRuns("**_ambas_**", [("**_", .hidden), ("ambas", [.bold, .italic]), ("_**", .hidden)])
    }

    func testMarksNextToPunctuationStillPair() {
        assertRuns("(**ok**)", [("**", .hidden), ("ok", .bold), ("**", .hidden)])
        assertRuns("**ok**.", [("**", .hidden), ("ok", .bold), ("**", .hidden)])
        assertRuns("\"*x*\", dijo", [("*", .hidden), ("x", .italic), ("*", .hidden)])
        assertRuns("*¿Y ahora?*", [("*", .hidden), ("¿Y ahora?", .italic), ("*", .hidden)])
        assertRuns("| **a** | b |", [("**", .hidden), ("a", .bold), ("**", .hidden)])
    }

    func testThingsThatLookLikeMarksButAreNotStayPlain() {
        for line in ["file_name_here", "usa snake_case y other_name", "2 * 3 * 4", "**", "*", "_", "a*b*c", "5*3 y 4*2", "src/**/*.swift", "*.js y *.ts", "rm -rf /tmp/*",
                     "**kwargs sin cerrar", "**negrita sin cerrar", "x * y = z", "¿ * ?", "a ** b ** c", "snake_case_ y _snake_case", "****", "1 _ 2 _ 3",
                     "ruta /Users/me/_x_/y", "\\*no cursiva\\*", "precio*", "*", "* "] {
            assertPlain(line)
        }
        // Marks that pair with nothing stay, the ones that do pair do not.
        assertRuns("**kwargs y *args*", [("*", .hidden), ("args", .italic), ("*", .hidden)])
    }

    func testMarkdownSemanticsThatSurprisePeopleAreTheSameAsMarkdowns() {
        assertRuns("__init__", [("__", .hidden), ("init", .bold), ("__", .hidden)])
    }

    // MARK: Code

    func testInlineCodeHidesItsBackticksAndIsNotRead() {
        assertRuns("usa `swift test` ya", [("`", .hidden), ("swift test", .code), ("`", .hidden)])
        assertRuns("`**no es negrita**`", [("`", .hidden), ("**no es negrita**", .code), ("`", .hidden)])
        assertRuns("``con ` dentro``", [("``", .hidden), ("con ` dentro", .code), ("``", .hidden)])
        assertRuns("**`archivo.swift`**", [("**`", .hidden), ("archivo.swift", [.bold, .code]), ("`**", .hidden)])
        assertRuns("usa `*` y `**`", [("`", .hidden), ("*", .code), ("`", .hidden), ("`", .hidden), ("**", .code), ("`", .hidden)])
        assertPlain("un ` suelto y otro `` distinto")
        assertPlain("vacío `` aquí")
    }

    // MARK: Headings and bullets

    func testHeadingsHideTheirHashesAndAreBold() {
        assertRuns("## Título", [("## ", .hidden), ("Título", .heading)])
        assertRuns("# Uno", [("# ", .hidden), ("Uno", .heading)])
        assertRuns("###### Seis", [("###### ", .hidden), ("Seis", .heading)])
        assertRuns("  ## Con sangría", [("## ", .hidden), ("Con sangría", .heading)])
        assertRuns("## Un **título** con `código`", [("## ", .hidden), ("Un ", .heading), ("**", .hidden), ("título", [.heading, .bold]), ("**", .hidden),
                                                      (" con ", .heading), ("`", .hidden), ("código", [.heading, .code]), ("`", .hidden)])
        for line in ["#sinespacio", "####### siete", "#", "## ", "# ", "texto # no es título"] { assertPlain(line) }
    }

    func testBulletsAreMarkedAndTheRestOfTheLineIsRead() {
        assertRuns("- uno", [("-", .bullet)])
        assertRuns("* uno", [("*", .bullet)])
        assertRuns("+ uno", [("+", .bullet)])
        assertRuns("    - anidado", [("-", .bullet)])
        assertRuns("- **negrita** aquí", [("-", .bullet), ("**", .hidden), ("negrita", .bold), ("**", .hidden)])
        assertRuns("* *cursiva*", [("*", .bullet), ("*", .hidden), ("cursiva", .italic), ("*", .hidden)])
        for line in ["---", "***", "* * *", "- - -", "-x", "- ", "1. uno", "2) dos", "texto - con guion", "-5 grados"] { assertPlain(line) }
    }

    func testListItemsSayWhereTheirTextStarts() {
        XCTAssertEqual(InlineMarkdown.parse("- uno")?.hang, 2)
        XCTAssertEqual(InlineMarkdown.parse("  - uno")?.hang, 4)
        XCTAssertEqual(InlineMarkdown.parse("    * anidado")?.hang, 6)
        XCTAssertEqual(InlineMarkdown.parse("1. uno")?.hang, 3)
        XCTAssertEqual(InlineMarkdown.parse("  12) doce")?.hang, 6)
        XCTAssertTrue(InlineMarkdown.parse("1. uno")?.runs.isEmpty ?? false, "A numbered item is left as it is; only its wrapped lines hang.")
        XCTAssertEqual(InlineMarkdown.parse(String(repeating: " ", count: 30) + "- profundo")?.hang, InlineMarkdown.maxHang)
        for line in ["texto", "1.5 es un número", "2024-05-01", "-5", "1.sin espacio", "1234. cuatro dígitos", "- "] { XCTAssertNil(InlineMarkdown.parse(line)?.hang, line) }
    }

    // MARK: Links

    func testLinksShowTheirTextAndHideTheRest() throws {
        let line = "mira [la guía](https://x.com/a_b_c) y listo"
        assertRuns(line, [("[", .hidden), ("la guía", .link), ("](https://x.com/a_b_c)", .hidden)])
        let result = try XCTUnwrap(InlineMarkdown.parse(line))
        XCTAssertEqual(result.links.map(\.url), ["https://x.com/a_b_c"])
        XCTAssertEqual((line as NSString).substring(with: result.links[0].range), "la guía")
        XCTAssertTrue(result.links[0].opens)
        // A path in a link only says where it points.
        let local = try XCTUnwrap(InlineMarkdown.parse("[Pet.swift](Sources/Nook/Pet.swift)"))
        XCTAssertFalse(local.links[0].opens)
        XCTAssertFalse(InlineMarkdown.Link(range: NSRange(), url: "javascript:alert(1)").opens)
        XCTAssertFalse(InlineMarkdown.Link(range: NSRange(), url: "file:///etc/passwd").opens)
        XCTAssertTrue(InlineMarkdown.Link(range: NSRange(), url: "mailto:a@b.co").opens)
        // Emphasis inside a link, and a link inside emphasis.
        assertRuns("[**docs**](https://x.com)", [("[**", .hidden), ("docs", [.link, .bold]), ("**](https://x.com)", .hidden)])
        assertRuns("**[docs](https://x.com)**", [("**[", .hidden), ("docs", [.bold, .link]), ("](https://x.com)**", .hidden)])
        for line in ["[a](b c)", "![imagen](x.png)", "[solo]", "- [ ] tarea", "[](x)", "[x]()", "\\[a](b)", "[a] (b)"] {
            XCTAssertTrue(InlineMarkdown.parse(line)?.links.isEmpty ?? true, line)
        }
    }

    // MARK: Positions and robustness

    func testRangesAreUTF16AndRelativeToTheWholeText() {
        let line = "**ñandú 🐈** y *más*"
        let text = line as NSString
        let whole = "primera\n  " + line + "\nultima" as NSString
        let range = whole.range(of: line)
        let result = InlineMarkdown.parse(whole, range: range)
        XCTAssertEqual(result?.runs.map { whole.substring(with: $0.range) }, ["**", "ñandú 🐈", "**", "*", "más", "*"])
        XCTAssertEqual(InlineMarkdown.parse(line)?.runs.map { text.substring(with: $0.range) }, ["**", "ñandú 🐈", "**", "*", "más", "*"])
    }

    func testRunsNeverOverlapAndStayInsideTheLine() {
        let pieces = ["*", "**", "***", "_", "__", "`", "``", "[", "]", "(", ")", "](", "#", "## ", "- ", "+ ", " ", "  ", "a", "ñ", "🐈", "word", ".", ",", "/", "\\", "http://x.co", "\u{00A0}", "\r"]
        var state: UInt64 = 0xBEEF
        func next(_ limit: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(limit)) }
        for _ in 0..<3000 {
            let line = (0..<(1 + next(16))).map { _ in pieces[next(pieces.count)] }.joined()
            let length = (line as NSString).length
            var end = 0
            for run in InlineMarkdown.parse(line)?.runs ?? [] {
                XCTAssertGreaterThanOrEqual(run.range.location, end, "\(line.debugDescription) overlaps")
                XCTAssertGreaterThan(run.range.length, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(run.range), length, "\(line.debugDescription)")
                XCTAssertNotEqual(run.style.rawValue, 0)
                end = NSMaxRange(run.range)
            }
        }
    }

    func testAMarkIsNeverShownWhenItsPartnerIsNot() {
        // Every hidden mark comes with its partner: either both are hidden or the pair is left alone.
        for line in ["**a**", "*a*", "__a__", "_a_", "`a`", "``a``", "**a *b* c**", "[a](b)", "## a", "***a***"] {
            guard let runs = InlineMarkdown.parse(line)?.runs else { return XCTFail(line) }
            let hidden = runs.filter { $0.style.contains(.hidden) }.map(\.range.length).reduce(0, +)
            let visible = (line as NSString).length - hidden
            XCTAssertGreaterThan(visible, 0, line)
        }
    }

    func testAVeryLongLineIsReadOnlyUpToTheLimit() {
        let long = String(repeating: "texto **negrita** más ", count: 1000)
        let runs = InlineMarkdown.parse(long)?.runs ?? []
        XCTAssertFalse(runs.isEmpty)
        XCTAssertLessThanOrEqual(runs.map { NSMaxRange($0.range) }.max() ?? 0, InlineMarkdown.maxLineLength)
    }

    func testLinesWithNothingToReadAreFree() {
        XCTAssertNil(InlineMarkdown.parse("Una línea de texto normal, con comas y números 12 - 3."))
        XCTAssertNil(InlineMarkdown.parse(""))
        XCTAssertNil(InlineMarkdown.parse("   "))
    }
}

/// How the styler dresses a reply's Markdown, and where it never does.
@MainActor
final class MarkdownStylerTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let palette = TranscriptPalette(dark: true)

    private func styled(_ text: String, font: NSFont? = nil) -> NSTextStorage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: font ?? self.font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font ?? self.font)
        return storage
    }

    private func attributes(_ storage: NSTextStorage, _ needle: String, after: String? = nil) -> [NSAttributedString.Key: Any] {
        let text = storage.string as NSString
        let from = after.map { NSMaxRange(text.range(of: $0)) } ?? 0
        let range = text.range(of: needle, range: NSRange(location: from, length: text.length - from))
        XCTAssertNotEqual(range.location, NSNotFound, needle)
        return storage.attributes(at: range.location, effectiveRange: nil)
    }

    private func isHidden(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        (attributes[.foregroundColor] as? NSColor) == .clear && ((attributes[.kern] as? CGFloat) ?? 0) < -1
    }

    func testBoldItalicCodeHeadingAndBulletsInAReply() {
        let storage = styled("⏺ **Cómo queda:** el `código` y *énfasis*.\n  ## Un título\n  - un punto\n  texto normal")
        let normal = attributes(storage, "texto normal")
        XCTAssertEqual(normal[.foregroundColor] as? NSColor, palette.text)

        let bold = attributes(storage, "Cómo")
        XCTAssertEqual((bold[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertEqual((bold[.font] as? NSFont)?.pointSize, 11, "Bold keeps the chat's size.")
        XCTAssertTrue(isHidden(attributes(storage, "**")), "Marks are hidden…")
        XCTAssertEqual(storage.string, "⏺ **Cómo queda:** el `código` y *énfasis*.\n  ## Un título\n  - un punto\n  texto normal", "…and still in the text.")

        let code = attributes(storage, "código")
        XCTAssertEqual(code[.foregroundColor] as? NSColor, palette.inlineCode)
        XCTAssertEqual(code[.backgroundColor] as? NSColor, palette.inlineCodeFill)
        XCTAssertTrue(isHidden(attributes(storage, "`")))

        let italic = attributes(storage, "énfasis")
        let slanted = (italic[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true || (italic[.obliqueness] as? CGFloat ?? 0) > 0
        XCTAssertTrue(slanted, "Italic is an italic font or a slant: \(italic)")

        let heading = attributes(storage, "Un título")
        XCTAssertEqual(heading[.foregroundColor] as? NSColor, palette.heading)
        XCTAssertEqual((heading[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), true)
        XCTAssertTrue(isHidden(attributes(storage, "##")))

        let bullet = attributes(storage, "-", after: "título")
        XCTAssertEqual(bullet[.foregroundColor] as? NSColor, palette.assistantMarker, "Claude's own colour marks a bullet.")
        XCTAssertEqual(attributes(storage, "un punto")[.foregroundColor] as? NSColor, palette.text)
        // The dot of the reply keeps its look.
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.assistantMarker)
    }

    func testLinksAreStyledAndOnlyWebAddressesOpen() {
        let storage = styled("⏺ Mira [la guía](https://example.com/a) y [Pet.swift](Sources/Nook/Pet.swift).")
        let web = attributes(storage, "la guía")
        XCTAssertEqual(web[.foregroundColor] as? NSColor, palette.link)
        XCTAssertEqual(web[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(web[.link] as? URL, URL(string: "https://example.com/a"))
        XCTAssertEqual(web[.toolTip] as? String, "https://example.com/a", "Where it goes shows when it is pointed at.")
        let local = attributes(storage, "Pet.swift")
        XCTAssertNil(local[.link], "A path is not opened.")
        XCTAssertEqual(local[.toolTip] as? String, "Sources/Nook/Pet.swift")
        XCTAssertTrue(isHidden(attributes(storage, "](https://example.com/a)")))
    }

    func testOnlyRepliesAreDressed() {
        let cases = ["> **a** `b` *c*\n  y **d**", "⏺ Bash(echo **a**)", "⏺ Read(a.swift)\n  ⎿  **a** `b` *c*\n     - **d**",
                     "⏺ Listo\n  ```swift\n  let a = **b**\n  ```", "⏺ Listo\n  ```raro\n  **a** `b` *c*\n  - d\n  ```", "$ echo **a** `b`", "texto **a** suelto"]
        for text in cases {
            let storage = styled(text)
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                XCTAssertNotEqual((attributes[.foregroundColor] as? NSColor), .clear, "Hidden text in \(text.debugDescription) at \(range)")
                XCTAssertNil(attributes[.backgroundColor], "\(text.debugDescription)")
                XCTAssertNil(attributes[.obliqueness], "\(text.debugDescription)")
                XCTAssertNil(attributes[.underlineStyle], "\(text.debugDescription)")
            }
        }
        // Diff rows with markdown-looking code stay code.
        let diff = TranscriptRenderer.change(["filePath": "/a/x.md", "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": ["-**viejo** `x`", "+**nuevo** `y`", " # título"]]]], cwd: "/a")!
        let rows = styled("⏺ Edit(x.md)\n" + diff)
        XCTAssertFalse(isHidden(attributes(rows, "**", after: "      1 + ")))
    }

    func testAReplyWithoutMarkdownKeepsItsPlainLook() {
        let text = "⏺ Listo, todo en verde.\n  Segunda línea con 2 * 3 * 4 y file_name_here.\n\n⏺ Otra"
        let storage = styled(text)
        for needle in ["Listo", "2 * 3 * 4", "*", "file_name_here", "_", "Segunda"] {
            let found = attributes(storage, needle)
            XCTAssertEqual(found[.foregroundColor] as? NSColor, palette.text, needle)
            XCTAssertEqual(found[.font] as? NSFont, font, needle)
            XCTAssertNil(found[.backgroundColor]); XCTAssertNil(found[.obliqueness]); XCTAssertNil(found[.underlineStyle]); XCTAssertNil(found[.kern])
        }
    }

    func testHiddenMarksTakeNoRoom() throws {
        func width(_ text: String) throws -> CGFloat {
            let view = MirrorTextView.makeTranscriptCapable()
            view.textContainer?.widthTracksTextView = true
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
            let storage = try XCTUnwrap(view.textStorage)
            storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
            TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
            let manager = try XCTUnwrap(view.layoutManager)
            manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
            return manager.usedRect(for: try XCTUnwrap(view.textContainer)).width
        }
        let plain = try width("⏺ hola mundo")
        XCTAssertEqual(try width("⏺ **hola** mundo"), plain, accuracy: 0.6, "Bold marks give their room back.")
        XCTAssertEqual(try width("⏺ *hola* `mundo`"), plain, accuracy: 0.6)
        XCTAssertEqual(try width("⏺ ## hola mundo"), plain, accuracy: 0.6)
        XCTAssertEqual(try width("⏺ [hola](https://example.com/largo/largo/largo) mundo"), plain, accuracy: 0.6, "A link's address takes no room.")
    }

    /// A mirror laid out at `width`, with the glyphs and line fragments of `text` styled.
    private func layout(_ text: String, width: CGFloat = 400) throws -> (view: MirrorTextView, manager: NSLayoutManager) {
        let view = MirrorTextView.makeTranscriptCapable()
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        return (view, manager)
    }

    func testTheDashOfAListItemIsDrawnAsABulletAndTheTextKeepsTheDash() throws {
        let text = "⏺ Lista:\n  - uno\n  * dos\n  texto - con guion"
        let (view, manager) = try layout(text)
        let nsText = view.string as NSString
        XCTAssertEqual(view.string, text, "The text keeps its dashes: copying gives them back.")
        func glyph(at needle: String, after: String) -> CGGlyph {
            let index = nsText.range(of: needle, range: NSRange(location: nsText.range(of: after).location, length: nsText.length - nsText.range(of: after).location)).location
            return manager.cgGlyph(at: manager.glyphIndexForCharacter(at: index))
        }
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        var dot: unichar = 0x2022, dash: unichar = 0x2D
        var dotGlyph = CGGlyph(0), dashGlyph = CGGlyph(0)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(bold, &dot, &dotGlyph, 1) && CTFontGetGlyphsForCharacters(bold, &dash, &dashGlyph, 1))
        XCTAssertEqual(glyph(at: "-", after: "Lista"), dotGlyph, "- is drawn as •")
        XCTAssertEqual(glyph(at: "*", after: "uno"), dotGlyph, "* too")
        let plainDash = glyph(at: "-", after: "texto")
        XCTAssertNotEqual(plainDash, dotGlyph, "A dash inside a sentence is a dash.")
    }

    func testABulletTakesTheRoomOfItsDash() throws {
        let withBullet = try layout("⏺ Lista:\n  - punto").manager
        let withLetter = try layout("⏺ Lista:\n  x punto").manager
        func width(_ manager: NSLayoutManager) -> CGFloat { manager.usedRect(for: manager.textContainers[0]).width }
        XCTAssertEqual(width(withBullet), width(withLetter), accuracy: 0.6, "The bullet is one column wide, like the dash.")
    }

    func testWrappedListItemsHangUnderTheirText() throws {
        let long = String(repeating: "palabra ", count: 12)
        // One column of the chat's font: a list item's text starts after the dash and its space, after the reply's two columns.
        let column = ("0" as NSString).size(withAttributes: [.font: font]).width
        for (text, columns) in [("⏺ Lista:\n  - " + long, 4.0), ("⏺ Lista:\n    * " + long, 6.0), ("⏺ Lista:\n  1. " + long, 5.0), ("⏺ - " + long, 4.0)] {
            let (view, manager) = try layout(text, width: 220)
            let nsText = view.string as NSString
            let start = nsText.range(of: "palabra").location
            var fragments: [NSRect] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: start, length: nsText.length - start), actualCharacterRange: nil)) { _, used, _, _, _ in fragments.append(used) }
            XCTAssertGreaterThan(fragments.count, 1, "The item wraps in \(text.debugDescription).")
            XCTAssertEqual(fragments[1].minX, columns * column, accuracy: 1.5, "Wrapped lines of \(text.debugDescription) start under the item's text.")
        }
        // A plain paragraph wraps to the left edge, as it always did.
        let (view, manager) = try layout("⏺ Texto:\n  " + long, width: 220)
        var lefts: [CGFloat] = []
        let start = (view.string as NSString).range(of: "palabra").location
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: NSRange(location: start, length: (view.string as NSString).length - start), actualCharacterRange: nil)) { _, used, _, _, _ in lefts.append(used.minX) }
        XCTAssertGreaterThan(lefts.count, 1)
        XCTAssertEqual(lefts.dropFirst().first ?? -1, 0, accuracy: 0.01)
    }

    func testCopyingGivesTheRawMarkdown() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        let storage = try XCTUnwrap(view.textStorage)
        let text = "⏺ Hola **mundo** y `x`"
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-md-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        view.pasteboard = pasteboard
        view.setSelectedRange(NSRange(location: 2, length: (text as NSString).length - 2))
        XCTAssertTrue(view.copySelection())
        XCTAssertEqual(pasteboard.string(forType: .string), "Hola **mundo** y `x`", "Copying gives the text as Claude wrote it.")
    }

    func testSizesAndThemesRestyleLikeAFreshPass() {
        let text = "⏺ **Cómo queda:** el `código` y *énfasis*, [guía](https://x.com).\n  ## Título\n  - **punto** uno\n  - punto `dos`\n\n⏺ Otra"
        for size in [9.0, 14.0, 18.0] {
            let sized = DisplaySettings.chatFont(size: size)
            let recolored = styled(text)
            TranscriptStyler.restyle(recolored, from: 0, dark: false, font: sized)
            let fresh = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            TranscriptStyler.restyle(fresh, from: 0, dark: false, font: sized)
            for index in 0..<fresh.length {
                XCTAssertTrue((recolored.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(fresh.attributes(at: index, effectiveRange: nil)), "size \(size) at \(index)")
            }
        }
        let big = styled(text, font: DisplaySettings.chatFont(size: 18))
        XCTAssertEqual((attributes(big, "Cómo")[.font] as? NSFont)?.pointSize, 18)
        XCTAssertEqual(attributes(big, "**")[.kern] as? CGFloat ?? 0, -(("0" as NSString).size(withAttributes: [.font: DisplaySettings.chatFont(size: 18)]).width), accuracy: 0.01, "A hidden mark gives back exactly its column at every size.")
    }

    func testMarkdownLinesGrowingOneCharacterAtATimeMatchTheWholePass() {
        let text = "⏺ **Cómo queda:** el `código` y *énfasis* con [guía](https://x.com).\n  ## Título **fuerte**\n  - punto _uno_\n  2 * 3 * 4\n\n⏺ ```py\n  x = **y\n  ```\n  `a`"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let typing: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let storage = NSTextStorage(string: "", attributes: typing)
        var shown = ""
        for character in text {
            shown.append(character)
            let old = storage.string as NSString, new = shown as NSString
            let common = LiveTerminalScrollView.commonPrefix(old, new)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: NSAttributedString(string: new.substring(from: common), attributes: typing))
            TranscriptStyler.restyle(storage, from: common, dark: true, font: font)
            storage.endEditing()
            if shown.hasSuffix("\n") || shown.count % 9 == 0 {
                let fresh = styled(shown)
                for index in 0..<fresh.length where !(storage.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(fresh.attributes(at: index, effectiveRange: nil)) {
                    return XCTFail("Attributes differ at \(index) after \(shown.count) characters: \(shown.debugDescription)")
                }
            }
        }
    }
}
