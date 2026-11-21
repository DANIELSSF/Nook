import AppKit
import XCTest
@testable import Nook

/// Markdown tables in Claude's replies: which lines are a table's, how the styler dresses them, and how the mirror lays them out
/// as a grid when they fit and as a stack of rows when they do not.
@MainActor
final class TranscriptTableTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private let table = [
        "⏺ Quedan tres comprobaciones:", "", "  | Qué | Cuánto toma | Cuándo |", "  |---|---|---|",
        "  | **816:** correr `ghl:setup` para crear el campo | unos 5 min | cuando quieras |",
        "  | **818:** una venta con creadora | unos 15 min | cuando quieras |",
        "  | **467:** ver que el token se renovó | un vistazo | mañana |", "", "  ¿Hacemos ahora la 816?",
    ].joined(separator: "\n")

    private func typing(dark: Bool = true) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black, .paragraphStyle: paragraph]
    }

    private func styled(_ text: String, dark: Bool = true) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: typing(dark: dark))
        TranscriptStyler.restyle(storage, from: 0, dark: dark, font: font)
        return storage
    }

    private func update(_ storage: NSTextStorage, to text: String) {
        let old = storage.string as NSString
        let new = text as NSString
        let common = LiveTerminalScrollView.commonPrefix(old, new)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: common, length: old.length - common),
                                  with: NSAttributedString(string: new.substring(from: common), attributes: typing()))
        TranscriptStyler.restyle(storage, from: common, dark: true, font: font)
        storage.endEditing()
    }

    private func assertSameAttributes(_ a: NSTextStorage, _ b: NSTextStorage, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.string, b.string, message, file: file, line: line)
        guard a.string == b.string else { return }
        for index in 0..<a.length where !(a.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(b.attributes(at: index, effectiveRange: nil)) {
            return XCTFail("Attributes differ at \(index) in \(a.string.debugDescription). \(message)", file: file, line: line)
        }
    }

    private func location(of piece: String, in storage: NSTextStorage, occurrence: Int = 0) -> Int {
        var from = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = (storage.string as NSString).range(of: piece, options: [], range: NSRange(location: from, length: storage.length - from))
            from = NSMaxRange(found)
        }
        return found.location
    }

    // MARK: Shape

    func testRowsAndRulesAreToldByTheirPipes() {
        XCTAssertEqual(TranscriptTableShape.of("| a | b |"), .row(pipes: [0, 4, 8]))
        XCTAssertEqual(TranscriptTableShape.of("  | a | b |  "), .row(pipes: [2, 6, 10]), "The reply's indent and trailing spaces are not cells.")
        XCTAssertEqual(TranscriptTableShape.of("| solo |"), .row(pipes: [0, 7]))
        XCTAssertEqual(TranscriptTableShape.of("|---|---|"), .rule(pipes: [0, 4, 8], alignments: [.left, .left]))
        XCTAssertEqual(TranscriptTableShape.of("| :-- | :-: | --: |"), .rule(pipes: [0, 6, 12, 18], alignments: [.left, .center, .right]))
        XCTAssertEqual(TranscriptTableShape.of(#"| a \| b | c |"#), .row(pipes: [0, 9, 13]), "An escaped pipe is text.")
    }

    func testLinesThatAreNotATablesStayText() {
        for line in ["a | b | c", "| sin cierre", "sin apertura |", "|", "||x", #"| a \|"#, "", "   ", "- | lista |", "`| código |` y más"] {
            XCTAssertNil(TranscriptTableShape.of(line), line)
        }
        // A rule needs dashes in every cell: anything else is a row.
        XCTAssertEqual(TranscriptTableShape.of("|---| x |"), .row(pipes: [0, 4, 8]))
        XCTAssertEqual(TranscriptTableShape.of("| | |"), .row(pipes: [0, 2, 4]))
    }

    func testCellsAreTheWordsBetweenThePipes() {
        let line = "  | **816:** uno |  | dos  |" as NSString
        guard case .row(let pipes) = TranscriptTableShape.of(line, NSRange(location: 0, length: line.length)) else { return XCTFail() }
        let cells = TranscriptTableShape.cells(line, pipes: pipes).map { line.substring(with: $0) }
        XCTAssertEqual(cells, ["**816:** uno", "", "dos"], "No padding, and an empty cell is empty.")
    }

    // MARK: Styling

    func testATableIsDressedAndItsCharactersAreKept() throws {
        let storage = styled(table)
        XCTAssertEqual(storage.string, table, "The Markdown stays as it was: copying gives it back.")
        let header = location(of: "Qué", in: storage)
        let tableObject = try XCTUnwrap(storage.attribute(.transcriptTable, at: header, effectiveRange: nil) as? TranscriptTable)
        XCTAssertEqual(tableObject.id, location(of: "  | Qué", in: storage))
        // The header is quieter and heavier than the rows.
        let headerFont = try XCTUnwrap(storage.attribute(.font, at: header, effectiveRange: nil) as? NSFont)
        let weight = (headerFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        XCTAssertGreaterThan(weight ?? 0, 0, "\(headerFont)")
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: header, effectiveRange: nil) as? NSColor, NSColor.white)
        // Its cells are known by their words, the header's and each row's.
        let s = storage.string as NSString
        XCTAssertEqual(tableObject.header.map(s.substring), ["Qué", "Cuánto toma", "Cuándo"])
        XCTAssertEqual(tableObject.rows.count, 3)
        XCTAssertEqual(tableObject.rows[1].map(s.substring), ["**818:** una venta con creadora", "unos 15 min", "cuando quieras"])
        XCTAssertEqual(tableObject.columns, 3)
        // Every line says which of the table's it is, and none of them is drawn by the text system.
        func line(_ piece: String) -> Int? { storage.attribute(.transcriptTableLine, at: location(of: piece, in: storage), effectiveRange: nil) as? Int }
        XCTAssertEqual([line("  | Qué"), line("  |---"), line("  | **816"), line("  | **818"), line("  | **467")], [0, -1, 1, 2, 3])
        for piece in ["  | Qué", "  |---", "  | **467"] {
            XCTAssertNotNil(storage.attribute(.transcriptHiddenLine, at: location(of: piece, in: storage), effectiveRange: nil), piece)
        }
        // Markdown inside a cell is still dressed: the cell is drawn with it.
        XCTAssertEqual(storage.attribute(.foregroundColor, at: location(of: "**816", in: storage), effectiveRange: nil) as? NSColor, NSColor.clear)
        // What follows the table is a reply's text again.
        XCTAssertNil(storage.attribute(.transcriptTable, at: location(of: "¿Hacemos", in: storage), effectiveRange: nil))
        XCTAssertNil(storage.attribute(.transcriptHiddenLine, at: location(of: "¿Hacemos", in: storage), effectiveRange: nil))
    }

    func testOnlyAReplysTableWithItsRuleIsATable() {
        let notTables = [
            "⏺ Sin regla:\n  | a | b |\n  | c | d |",
            "> | mi | tabla |\n  |---|---|\n  | x | y |",
            "⏺ Bash(cat t.md)\n  ⎿  | a | b |\n     |---|---|\n     | x | y |",
            "⏺ En una valla:\n  ```\n  | a | b |\n  |---|---|\n  ```",
            "⏺ | en la línea del punto |\n  |---|",
        ]
        for text in notTables {
            let storage = styled(text)
            XCTAssertFalse((0..<storage.length).contains { storage.attribute(.transcriptTable, at: $0, effectiveRange: nil) != nil }, text)
        }
    }

    func testAlignedColumnsKeepTheirAlignment() throws {
        let storage = styled("⏺ Cuentas:\n  | Nombre | Total | Medio |\n  |:--|--:|:-:|\n  | a | 12 | x |")
        let table = try XCTUnwrap(storage.attribute(.transcriptTable, at: location(of: "  | a", in: storage), effectiveRange: nil) as? TranscriptTable)
        XCTAssertEqual(table.alignments, [.left, .right, .center])
        let cells = table.cells(in: storage)
        XCTAssertEqual((cells.rows[0][1].attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        XCTAssertEqual((cells.header[2].attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)
    }

    // MARK: Restyling

    func testATableGrowingLineByLineMatchesStylingItAtOnce() {
        let storage = NSTextStorage(string: "", attributes: typing())
        var shown = ""
        for character in table {
            shown.append(character)
            update(storage, to: shown)
            if character == "\n" || shown.count % 5 == 0 { assertSameAttributes(storage, styled(shown), "after \(shown.count) characters") }
        }
        assertSameAttributes(storage, styled(table))
    }

    func testANewRowBelowRestylesTheWholeTable() throws {
        let storage = styled("⏺ T:\n  | a | b |\n  |---|---|\n  | x | y |")
        update(storage, to: "⏺ T:\n  | a | b |\n  |---|---|\n  | x | y |\n  | una celda mucho más ancha | z |")
        assertSameAttributes(storage, styled(storage.string))
        let table = try XCTUnwrap(storage.attribute(.transcriptTable, at: location(of: "  | a", in: storage), effectiveRange: nil) as? TranscriptTable)
        XCTAssertEqual(table.rows.count, 2, "The header's line knows the new row.")
    }

    func testRemovingTheRuleUndoesTheTable() {
        let storage = styled("⏺ T:\n  | a | b |\n  |---|---|\n  | x | y |")
        update(storage, to: "⏺ T:\n  | a | b |\n  | x | y |")
        assertSameAttributes(storage, styled(storage.string))
        XCTAssertFalse((0..<storage.length).contains { storage.attribute(.transcriptTable, at: $0, effectiveRange: nil) != nil })
        XCTAssertFalse((0..<storage.length).contains { storage.attribute(.transcriptHiddenLine, at: $0, effectiveRange: nil) != nil })
    }

    // MARK: Columns

    func testColumnsThatFitAreAsWideAsTheirWidestCell() {
        XCTAssertEqual(TranscriptTableColumns.widths(natural: [40, 80, 30], minimum: [30, 50, 30], available: 300), [40, 80, 30])
        XCTAssertEqual(TranscriptTableColumns.widths(natural: [], minimum: [], available: 10), [])
    }

    func testNarrowColumnsKeepTheirWidthAndWideOnesShareTheRest() throws {
        // "Caso" needs 120 and fits an even share; the long column takes what is left and wraps.
        let widths = try XCTUnwrap(TranscriptTableColumns.widths(natural: [120, 700], minimum: [60, 80], available: 400))
        XCTAssertEqual(widths[0], 120)
        XCTAssertEqual(widths[1], 280)
        // Two long columns share in proportion to what each lacks.
        let shared = try XCTUnwrap(TranscriptTableColumns.widths(natural: [500, 300], minimum: [100, 100], available: 400))
        XCTAssertEqual(shared.reduce(0, +), 400, accuracy: 1)
        XCTAssertGreaterThan(shared[0], shared[1])
        XCTAssertGreaterThanOrEqual(shared[1], 100, "Never under a column's minimum.")
    }

    func testColumnsThatCannotBeLegibleAreNoColumns() {
        XCTAssertNil(TranscriptTableColumns.widths(natural: [200, 200, 200], minimum: [90, 90, 90], available: 200))
        // A column narrower than its minimum only asks for what it has.
        XCTAssertEqual(TranscriptTableColumns.widths(natural: [10, 300], minimum: [60, 100], available: 200).map { $0[0] }, 10)
    }

    // MARK: Layout

    private func mirror(_ text: String, width: CGFloat) throws -> (MirrorTextView, NSLayoutManager, NSTextContainer) {
        let view = MirrorTextView.makeTranscriptCapable()
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: text, attributes: typing()))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        return (view, manager, container)
    }

    /// The line fragment the line that starts with `piece` is laid out on.
    private func fragment(_ piece: String, _ view: MirrorTextView, _ manager: NSLayoutManager) -> NSRect {
        let index = location(of: piece, in: view.textStorage!)
        return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
    }

    private func layout(_ view: MirrorTextView, _ container: NSTextContainer) throws -> TranscriptTableLayout {
        let storage = try XCTUnwrap(view.textStorage)
        let table = try XCTUnwrap(storage.attribute(.transcriptTable, at: location(of: "|", in: storage), effectiveRange: nil) as? TranscriptTable)
        return table.layout(width: container.size.width - 2 * container.lineFragmentPadding, in: storage)
    }

    func testATableThatFitsIsAGridOfOneLinePerRow() throws {
        let text = "⏺ Cuentas:\n  | Nombre | Total |\n  |---|--:|\n  | uno | 12 |\n  | un nombre largo | 3 |\n\n  Fin."
        let (view, manager, container) = try mirror(text, width: 600)
        let found = try layout(view, container)
        XCTAssertEqual(found.mode, .grid)
        let line = TranscriptStyler.Sheet.lineHeight(of: font)
        let row = line + 2 * TranscriptTables.cellPadding
        // Each of the table's lines is one line fragment, as tall as its row; the rule takes no room.
        for piece in ["  | Nombre", "  | uno", "  | un nombre"] {
            XCTAssertEqual(fragment(piece, view, manager).height, row, accuracy: 0.5, piece)
        }
        XCTAssertEqual(fragment("  |---", view, manager).height, 0, accuracy: 0.5)
        // The rows stack in order, and the reply goes on under the table.
        XCTAssertEqual(fragment("  | uno", view, manager).minY, fragment("  | Nombre", view, manager).maxY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(fragment("  Fin.", view, manager).minY, fragment("  | un nombre", view, manager).maxY)
        // The grid is as wide as its cells and gaps, well inside the mirror.
        let names = ("un nombre largo" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(found.widths[0], names - 1)
        XCTAssertLessThan(found.width, 300)
        XCTAssertEqual(found.starts[1], found.starts[0] + found.widths[0] + TranscriptTables.gap, accuracy: 0.5)
    }

    func testALongCellWrapsInsideItsColumn() throws {
        let long = "una celda larga que no cabe junto a las otras en una isla de este ancho y tiene que partirse"
        let text = "⏺ T:\n  | Caso | Lo que dice |\n  |---|---|\n  | Sin cuenta | nada |\n  | Coincide una parte | \(long) |"
        let (view, manager, container) = try mirror(text, width: 380)
        let found = try layout(view, container)
        XCTAssertEqual(found.mode, .grid, "Two columns stay columns.")
        let line = TranscriptStyler.Sheet.lineHeight(of: font)
        // The short column keeps its words on one line; the long cell wraps, and its row grows.
        let caso = ("Coincide una parte" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(found.widths[0], ceil(caso))
        XCTAssertEqual(fragment("  | Sin cuenta", view, manager).height, line + 2 * TranscriptTables.cellPadding, accuracy: 0.5)
        XCTAssertGreaterThan(fragment("  | Coincide", view, manager).height, 2 * line + 2 * TranscriptTables.cellPadding - 0.5)
        XCTAssertLessThanOrEqual(found.width, container.size.width, "The grid stays in the mirror.")
    }

    func testATableThatCannotKeepItsColumnsStacksItsRowsAndSwitchesBackWhenWider() throws {
        let (view, manager, container) = try mirror(table, width: 200)
        let narrow = try layout(view, container)
        XCTAssertEqual(narrow.mode, .stack)
        // The header gives its names to the rows and takes no room of its own; each row is a card, as tall as its values.
        XCTAssertEqual(fragment("  | Qué", view, manager).height, 0, accuracy: 0.5)
        XCTAssertGreaterThan(fragment("  | **816", view, manager).height, 3 * TranscriptStyler.Sheet.lineHeight(of: font))
        // Wider again, the same text is a grid, without restyling.
        view.frame.size.width = 1400
        container.size = NSSize(width: 1400 - 4, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        XCTAssertEqual(try layout(view, container).mode, .grid)
        XCTAssertEqual(fragment("  | **816", view, manager).height, TranscriptStyler.Sheet.lineHeight(of: font) + 2 * TranscriptTables.cellPadding, accuracy: 0.5)
    }

    func testSelectingTheTableCopiesItsMarkdown() throws {
        let (view, _, _) = try mirror(table, width: 540)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook.tests.table.\(UUID().uuidString)"))
        view.pasteboard = pasteboard
        let s = view.string as NSString
        let start = s.range(of: "  | Qué").location
        let end = NSMaxRange(s.range(of: "mañana |"))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertTrue(view.copySelection())
        XCTAssertEqual(pasteboard.string(forType: .string), s.substring(with: NSRange(location: start, length: end - start)))
        XCTAssertTrue(pasteboard.string(forType: .string)?.contains("|---|---|---|") == true)
    }
}
