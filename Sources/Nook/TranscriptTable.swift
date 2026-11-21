import AppKit

// Markdown tables in Claude's replies. The mirror shows Claude's text, and a table arrives there as Markdown: a header row, a
// `|---|---|` rule and one line per row (tmux joins a wrapped row back into one line), each cell between pipes. As with the rest of
// the Markdown (`InlineMarkdown`), no character changes: the pipes and the rule stay in the text, so copying or selecting gives the
// Markdown back.
//
//   TranscriptTableShape    whether a line is a table's row or its rule, and where its pipes are (pure)
//   TranscriptTableColumns  how wide each column is in the room there is, or that there is not room for columns (pure)
//   TranscriptTableLayout   one table laid out in one width: its columns and the height of each of its lines
//   TranscriptTables        finds the cells of each table the styler finds, and marks its lines
//   TranscriptTable         one table: its cells and its look, and its layout for the width the mirror has now
//
// Why the table is drawn and not typeset. A cell that does not fit has to wrap inside its column, and TextKit only wraps a
// paragraph: a row is one paragraph, and the pipes cannot become paragraph breaks without changing the characters (an
// `NSTextTable` needs one paragraph per cell). So the characters of a table's lines take no room (`MirrorLayoutManager` lays each
// line out as one empty line), the layout manager gives each line the height its row needs in the mirror's width as the lines are
// laid out (`MirrorLayoutManager.hiddenLineHeight`), and it draws the table into that room: the cells, with the look the styler
// gave their characters (bold, `code`, links' colour), wrapped in their columns. The text under it is still the Markdown, so a
// selection that crosses the table highlights its rows and copies their Markdown.
//
// A table is laid out one of two ways, chosen for the width the mirror has as its lines are laid out, so an island made narrower or
// wider switches without restyling anything:
//   grid   the columns stay columns. A column that fits is as wide as its widest cell; when they do not all fit, the narrow ones keep
//          their width and the wide ones share what is left, never under what keeps their longest word whole (`TranscriptTableColumns`),
//          and their cells wrap. The header is a quiet band over a rule, hairlines part the rows
//   stack  not even that fits: each row is a card, its first cell on top as the card's title and every other value beside the name
//          of its column (under it, when the island is narrower still)

extension NSAttributedString.Key {
    /// A `TranscriptTable` on every character of a table's lines.
    static let transcriptTable = NSAttributedString.Key("nook.transcript.table")
    /// Which of its table's lines a line is: 0 the header, -1 the rule under it, 1… its rows. On every character of the line.
    static let transcriptTableLine = NSAttributedString.Key("nook.transcript.table.line")
}

// MARK: - Shape

/// What a line is to a table, read from its characters alone.
enum TranscriptTableShape: Equatable {
    enum Alignment: Equatable { case left, center, right }

    /// A row: the offsets of its pipes, the first and the last included. An escaped pipe (`\|`) is text.
    case row(pipes: [Int])
    /// The rule under the header (`|---|:---:|---:|`): its pipes, and how each column is aligned.
    case rule(pipes: [Int], alignments: [Alignment])

    var pipes: [Int] {
        switch self {
        case .row(let pipes), .rule(let pipes, _): pipes
        }
    }

    /// The line `range` of `text` (without its line break), or nil when it is not a table's: it has to start and end with a pipe.
    static func of(_ text: NSString, _ range: NSRange) -> TranscriptTableShape? {
        guard range.length >= 2, range.length <= InlineMarkdown.maxLineLength, range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        // Most lines do not start with a pipe: one look, no copy.
        var lead = range.location
        while lead < NSMaxRange(range), isSpace(text.character(at: lead)) { lead += 1 }
        guard lead < NSMaxRange(range), text.character(at: lead) == pipe else { return nil }
        var chars = [unichar](repeating: 0, count: range.length)
        text.getCharacters(&chars, range: range)
        let start = lead - range.location
        var end = chars.count
        while end > start, isSpace(chars[end - 1]) { end -= 1 }
        guard end - start >= 2, chars[end - 1] == pipe else { return nil }
        var pipes: [Int] = []
        var index = start
        while index < end {
            if chars[index] == backslash { index += 2; continue }
            if chars[index] == pipe { pipes.append(index) }
            index += 1
        }
        // The closing pipe has to be one: `| a \|` ends in text.
        guard pipes.count >= 2, pipes.last == end - 1 else { return nil }
        let absolute = pipes.map { range.location + $0 }
        guard let alignments = alignments(chars, pipes) else { return .row(pipes: absolute) }
        return .rule(pipes: absolute, alignments: alignments)
    }

    /// The same for a plain string (tests).
    static func of(_ line: String) -> TranscriptTableShape? { of(line as NSString, NSRange(location: 0, length: (line as NSString).length)) }

    /// Each cell of a rule is dashes, with a colon on the side (or both sides) its column is aligned to; nil when a cell is anything else.
    private static func alignments(_ chars: [unichar], _ pipes: [Int]) -> [Alignment]? {
        var result: [Alignment] = []
        for (open, close) in zip(pipes, pipes.dropFirst()) {
            var low = open + 1, high = close
            while low < high, isSpace(chars[low]) { low += 1 }
            while high > low, isSpace(chars[high - 1]) { high -= 1 }
            guard high > low else { return nil }
            let left = chars[low] == colon, right = chars[high - 1] == colon
            let dashes = chars[(low + (left ? 1 : 0))..<(high - (right ? 1 : 0))]
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == dash }) else { return nil }
            result.append(left && right ? .center : right ? .right : .left)
        }
        return result
    }

    /// The words of each cell of a row: what lies between two pipes, without the spaces around it. An empty cell is an empty range
    /// right after its pipe.
    static func cells(_ text: NSString, pipes: [Int]) -> [NSRange] {
        zip(pipes, pipes.dropFirst()).map { open, close in
            var low = open + 1, high = close
            while low < high, isSpace(text.character(at: low)) { low += 1 }
            while high > low, isSpace(text.character(at: high - 1)) { high -= 1 }
            return NSRange(location: low, length: high - low)
        }
    }

    private static let pipe: unichar = 0x7C
    private static let backslash: unichar = 0x5C
    private static let dash: unichar = 0x2D
    private static let colon: unichar = 0x3A
    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x0D }
}

// MARK: - Columns

enum TranscriptTableColumns {
    /// How wide each column is in `available` points (the room for the cells, without the gaps between them), or nil when the
    /// columns cannot all be legible there and the table is stacked instead.
    ///
    /// `natural` is each column's widest cell on one line; `minimum` the least it can take and stay legible (its longest word, within
    /// bounds `TranscriptTables` sets). When everything fits each column is as wide as its widest cell. When it does not, every column
    /// starts at its minimum and the room left is poured in from the narrowest need up: a column whose whole cell fits in an even share
    /// of what is left gets it all (a short "Sí" or a date never wraps), and once none does, the rest is shared in proportion to what
    /// each still lacks, so the long columns wrap about as much as each other.
    static func widths(natural: [CGFloat], minimum: [CGFloat], available: CGFloat) -> [CGFloat]? {
        guard !natural.isEmpty, natural.count == minimum.count else { return natural.isEmpty ? [] : nil }
        if natural.reduce(0, +) <= available + 0.5 { return natural }
        var widths = zip(natural, minimum).map { min($0, $1) }
        var room = available - widths.reduce(0, +)
        guard room >= -0.5 else { return nil }
        var open = Array(natural.indices)
        while !open.isEmpty, room > 0.5 {
            let share = room / CGFloat(open.count)
            let whole = open.filter { natural[$0] - widths[$0] <= share }
            guard !whole.isEmpty else {
                let lacking = open.reduce(CGFloat(0)) { $0 + natural[$1] - widths[$1] }
                for column in open { widths[column] += room * (natural[column] - widths[column]) / lacking }
                room = 0
                break
            }
            for column in whole {
                room -= natural[column] - widths[column]
                widths[column] = natural[column]
            }
            open.removeAll { whole.contains($0) }
        }
        return widths.map { ($0 * 2).rounded(.down) / 2 }
    }
}

// MARK: - Layout

/// One table laid out in one width: plain numbers, so the rules are tested without a window.
struct TranscriptTableLayout: Equatable {
    enum Mode: Equatable { case grid, stack }

    var mode: Mode
    /// The table's own width, from its left edge (where the reply's text starts).
    var width: CGFloat
    /// Grid: where each column's cells start, from the table's left edge, and how wide they are.
    var starts: [CGFloat] = []
    var widths: [CGFloat] = []
    /// Stack: how wide the column names are, beside their values; 0 when they stand over them.
    var label: CGFloat = 0
    /// The height of each of the table's lines in the text, in order: the header, the rule, then the rows.
    var heights: [CGFloat] = []

    /// The height of the table's line `line` (0 the header, -1 the rule, 1… the rows).
    func height(ofLine line: Int) -> CGFloat {
        let index = line == 0 ? 0 : line < 0 ? 1 : line + 1
        return heights.indices.contains(index) ? heights[index] : 0
    }
}

// MARK: - One table

/// One table, as the layout needs it. Every character of the table's lines carries it.
final class TranscriptTable: NSObject {
    /// The colours a table is drawn with, beyond its cells' own.
    struct Look: Equatable {
        /// The hairline around the table and the band behind its header.
        var border: NSColor
        var headerFill: NSColor
        /// Under the header, and between the rows.
        var headerRule: NSColor
        var hairline: NSColor
        /// The column names beside a stacked row's values.
        var label: NSColor
    }

    /// The offset of the header's line: tables apart stay apart.
    let id: Int
    /// Where the table starts, from the start of its lines (the reply's indent).
    let indent: CGFloat
    /// The header's cells and each row's, as ranges of the text: a cell's words, without the spaces around them.
    let header: [NSRange]
    let rows: [[NSRange]]
    let alignments: [TranscriptTableShape.Alignment]
    /// One column of the reply's font, and its line's height: what the table's room is counted in.
    let column: CGFloat
    let lineHeight: CGFloat
    let look: Look

    init(id: Int, indent: CGFloat, header: [NSRange], rows: [[NSRange]], alignments: [TranscriptTableShape.Alignment], column: CGFloat,
         lineHeight: CGFloat, look: Look) {
        self.id = id; self.indent = indent; self.header = header; self.rows = rows; self.alignments = alignments
        self.column = column; self.lineHeight = lineHeight; self.look = look
    }

    var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// The cells' text with the look the styler gave it, made once (the text under a table never changes without it being dressed
    /// again, which makes a new table), and the layout for the last width asked for.
    private var cellText: (header: [NSAttributedString], rows: [[NSAttributedString]])?
    private var stackText: (header: [NSAttributedString], rows: [[NSAttributedString]])?
    private var cached: (width: CGFloat, layout: TranscriptTableLayout)?

    /// The table laid out in a container whose lines are `width` wide.
    func layout(width: CGFloat, in text: NSAttributedString) -> TranscriptTableLayout {
        if let cached, abs(cached.width - width) < 0.25 { return cached.layout }
        let cells = self.cells(in: text)
        let result = TranscriptTables.layout(header: cells.header, rows: cells.rows, stacked: { self.stackCells(in: text) }, available: max(0, width - indent),
                                             column: column, lineHeight: lineHeight)
        cached = (width, result)
        return result
    }

    /// The cells as a stacked row shows them: every one aligned to the left, a column's name in the quiet colour of a label.
    func stackCells(in text: NSAttributedString) -> (header: [NSAttributedString], rows: [[NSAttributedString]]) {
        if let stackText { return stackText }
        let cells = self.cells(in: text)
        let made = (cells.header.map { TranscriptTables.label(TranscriptTables.drawable($0, alignment: .left), color: look.label) },
                    cells.rows.map { $0.map { TranscriptTables.drawable($0, alignment: .left) } })
        stackText = made
        return made
    }

    func cells(in text: NSAttributedString) -> (header: [NSAttributedString], rows: [[NSAttributedString]]) {
        if let cellText { return cellText }
        func cell(_ range: NSRange, _ column: Int) -> NSAttributedString {
            guard range.length > 0, NSMaxRange(range) <= text.length else { return NSAttributedString() }
            let alignment: NSTextAlignment = switch column < alignments.count ? alignments[column] : .left {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            return TranscriptTables.drawable(text.attributedSubstring(from: range), alignment: alignment)
        }
        let made = (header.enumerated().map { cell($1, $0) }, rows.map { $0.enumerated().map { cell($1, $0) } })
        cellText = made
        return made
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptTable else { return false }
        return id == other.id && indent == other.indent && header == other.header && rows == other.rows && alignments == other.alignments
            && column == other.column && lineHeight == other.lineHeight && look == other.look
    }
    override var hash: Int { id }
}

// MARK: - Dressing and measuring

enum TranscriptTables {
    /// The room inside the table's edge, left and right, and above and below each cell's text.
    static let padding: CGFloat = 8
    static let cellPadding: CGFloat = 4
    /// Between two columns of the grid, and between a stacked row's column name and its value.
    static let gap: CGFloat = 14
    static let labelGap: CGFloat = 10
    /// The least a column takes, and the most its longest word may ask for, in columns of the reply's font: under that a column is
    /// not legible, and a longer word (a path) breaks rather than squeeze the others.
    static let minimumColumns: CGFloat = 5
    static let wordColumns: CGFloat = 16
    /// A stacked row's value needs at least this many columns beside its name; with fewer, the name goes over it.
    static let valueColumns: CGFloat = 14
    /// Between a stacked row's title and its first value, and between its values.
    static let stackSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 6

    /// A run of a reply's lines shaped like a table's, as the styler meets them.
    struct Found {
        var lines: [TranscriptClassifier.Line] = []
        var shapes: [TranscriptTableShape] = []

        mutating func add(_ line: TranscriptClassifier.Line, _ shape: TranscriptTableShape) {
            lines.append(line)
            shapes.append(shape)
        }
    }

    /// The start of the run of table lines right above the line that starts at `location` (or `location` when there is none):
    /// a table is measured over all its rows, so a change to one restyles the table from its first line.
    static func firstLine(above location: Int, in text: NSString) -> Int {
        var start = location
        while start > 0 {
            let line = text.lineRange(for: NSRange(location: start - 1, length: 0))
            var content = line
            while content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            guard TranscriptTableShape.of(text, content) != nil else { break }
            start = line.location
        }
        return start
    }

    /// Gives a run its table look, once the styler has written every attribute of its lines. A run that does not open with a row
    /// and the rule under it is not a table and keeps the look it has.
    static func dress(_ found: Found, in storage: NSTextStorage, sheet: TranscriptStyler.Sheet) {
        guard found.lines.count >= 2, case .row(let headerPipes) = found.shapes[0], case .rule(_, let alignments) = found.shapes[1] else { return }
        let text = storage.mutableString as NSString
        let headerLine = found.lines[0]
        // The header's names: quieter than the rows, a little heavier. The marks Markdown hides keep their look.
        let headerFont = sheet.base.isFixedPitch ? NSFont.monospacedSystemFont(ofSize: sheet.base.pointSize, weight: .semibold) : sheet.bold
        storage.enumerateAttribute(.foregroundColor, in: headerLine.range, options: []) { value, range, _ in
            if (value as? NSColor) == NSColor.clear { return }
            storage.addAttributes([.font: headerFont, .foregroundColor: sheet.palette.toolName], range: range)
        }
        let indentRange = NSRange(location: headerLine.range.location, length: headerPipes[0] - headerLine.range.location)
        let indent = indentRange.length > 0 ? ceil(storage.attributedSubstring(from: indentRange).size().width) : 0
        let palette = sheet.palette
        let look = TranscriptTable.Look(border: palette.text.withAlphaComponent(0.16), headerFill: palette.text.withAlphaComponent(0.05),
                                        headerRule: palette.text.withAlphaComponent(0.22), hairline: palette.text.withAlphaComponent(0.09),
                                        label: palette.output)
        let rows = found.shapes.dropFirst(2).map { TranscriptTableShape.cells(text, pipes: $0.pipes) }
        let table = TranscriptTable(id: headerLine.range.location, indent: indent, header: TranscriptTableShape.cells(text, pipes: headerPipes), rows: rows,
                                    alignments: alignments, column: sheet.column, lineHeight: sheet.lineHeight, look: look)
        for (index, line) in found.lines.enumerated() {
            let whole = NSRange(location: line.range.location, length: line.end - line.range.location)
            // The line's own height is the layout manager's to give: nothing above or between its lines adds to it.
            let style = (storage.attribute(.paragraphStyle, at: line.range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            style.lineSpacing = 0
            style.headIndent = 0
            style.firstLineHeadIndent = 0
            storage.addAttributes([.paragraphStyle: style, .transcriptTable: table, .transcriptTableLine: index == 0 ? 0 : index == 1 ? -1 : index - 1,
                                   .transcriptHiddenLine: true], range: whole)
        }
    }

    /// A cell's text as it is drawn: the look its characters have in the mirror, in a paragraph that wraps by word and is aligned as
    /// its column is. A link's text keeps the link's colour but is no link (it is a picture of the text, not the text).
    static func drawable(_ cell: NSAttributedString, alignment: NSTextAlignment) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: cell)
        let whole = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        for key in [NSAttributedString.Key.link, .toolTip, .cursor] { text.removeAttribute(key, range: whole) }
        return text
    }

    private static let drawing: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// How much room `text` takes in `width` points, rounded up; one line's height when it is empty.
    static func size(of text: NSAttributedString, width: CGFloat, lineHeight: CGFloat) -> CGSize {
        guard text.length > 0 else { return CGSize(width: 0, height: lineHeight) }
        let rect = text.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude), options: drawing)
        return CGSize(width: ceil(rect.width), height: max(lineHeight, ceil(rect.height)))
    }

    /// The width of the longest word of `text` (by its characters; the longest few are measured).
    static func longestWord(of text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var words: [NSRange] = []
        var start: Int?
        for index in 0...string.length {
            let space = index == string.length || CharacterSet.whitespaces.contains(UnicodeScalar(string.character(at: index)) ?? " ")
            if space, let begun = start { words.append(NSRange(location: begun, length: index - begun)); start = nil }
            else if !space, start == nil { start = index }
        }
        return words.sorted { $0.length > $1.length }.prefix(3).map { ceil(text.attributedSubstring(from: $0).size().width) }.max() ?? 0
    }

    /// Lays a table out in `available` points: as a grid when its columns can be legible there (`TranscriptTableColumns`), as a stack
    /// of cards otherwise.
    /// `stacked` gives the cells as a stacked row draws them (`TranscriptTable.stackCells`), asked for only when the table is stacked.
    static func layout(header: [NSAttributedString], rows: [[NSAttributedString]], stacked: () -> (header: [NSAttributedString], rows: [[NSAttributedString]]),
                       available: CGFloat, column: CGFloat, lineHeight: CGFloat) -> TranscriptTableLayout {
        let count = max(header.count, rows.map(\.count).max() ?? 0)
        guard count > 0 else { return TranscriptTableLayout(mode: .grid, width: 0, heights: [0, 0] + rows.map { _ in 0 }) }
        let all = [header] + rows
        func cell(_ row: [NSAttributedString], _ index: Int) -> NSAttributedString { index < row.count ? row[index] : NSAttributedString() }
        var natural = [CGFloat](repeating: 0, count: count), minimum = natural
        for row in all {
            for index in 0..<count {
                let text = cell(row, index)
                natural[index] = max(natural[index], size(of: text, width: .greatestFiniteMagnitude, lineHeight: lineHeight).width)
                minimum[index] = max(minimum[index], longestWord(of: text))
            }
        }
        minimum = minimum.map { min(max($0, minimumColumns * column), wordColumns * column) }
        let room = available - 2 * padding - CGFloat(count - 1) * gap
        if let widths = TranscriptTableColumns.widths(natural: natural, minimum: minimum, available: room) {
            var starts: [CGFloat] = []
            var x = padding
            for width in widths { starts.append(x); x += width + gap }
            func height(_ row: [NSAttributedString]) -> CGFloat {
                2 * cellPadding + (0..<count).map { size(of: cell(row, $0), width: widths[$0], lineHeight: lineHeight).height }.max()!
            }
            return TranscriptTableLayout(mode: .grid, width: x - gap + padding, starts: starts, widths: widths,
                                         heights: [height(header), 0] + rows.map(height))
        }
        // The stack: a row's title over its other values, each beside (or under) the name of its column.
        let (header, rows) = stacked()
        let inner = max(1, available - 2 * padding)
        let names = (1..<count).map { cell(header, $0) }
        var label = min(names.map { size(of: $0, width: .greatestFiniteMagnitude, lineHeight: lineHeight).width }.max() ?? 0, (inner * 0.4).rounded())
        if inner - label - labelGap < valueColumns * column { label = 0 }
        func height(_ row: [NSAttributedString]) -> CGFloat {
            var total = 2 * cellPadding
            let title = cell(row, 0)
            if title.length > 0 { total += size(of: title, width: inner, lineHeight: lineHeight).height }
            for index in 1..<max(1, count) {
                let value = cell(row, index)
                guard value.length > 0 else { continue }
                let name = cell(header, index)
                if total > 2 * cellPadding { total += stackSpacing }
                total += label > 0
                    ? max(size(of: name, width: label, lineHeight: lineHeight).height, size(of: value, width: inner - label - labelGap, lineHeight: lineHeight).height)
                    : (name.length > 0 ? size(of: name, width: inner, lineHeight: lineHeight).height : 0) + size(of: value, width: inner, lineHeight: lineHeight).height
            }
            return total
        }
        return TranscriptTableLayout(mode: .stack, width: available, label: label, heights: [0, 0] + rows.map(height))
    }
}

// MARK: - Drawing

extension MirrorLayoutManager {
    /// The table a hidden line belongs to, its line's place in it, and the table's layout for `container`'s width.
    func table(at index: Int, container: NSTextContainer?) -> (TranscriptTable, Int, TranscriptTableLayout)? {
        guard let storage = textStorage, index < storage.length,
              let table = storage.attribute(.transcriptTable, at: index, effectiveRange: nil) as? TranscriptTable,
              let line = storage.attribute(.transcriptTableLine, at: index, effectiveRange: nil) as? Int, let container else { return nil }
        return (table, line, table.layout(width: container.size.width - 2 * container.lineFragmentPadding, in: storage))
    }

    /// Each table's frame: a hairline around it, the band behind its header and the rule under it, and the hairlines between its
    /// rows. Drawn under the selection, which then highlights the rows it covers.
    func drawTableChrome(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        var location = shown.location
        while location < NSMaxRange(shown) {
            var run = NSRange(location: location, length: 0)
            let value = storage.attribute(.transcriptTable, at: location, longestEffectiveRange: &run, in: shown)
            defer { location = max(location + 1, NSMaxRange(run)) }
            guard let table = value as? TranscriptTable else { continue }
            // The part being drawn may cut the table; its frame is always the whole table's.
            var full = run
            storage.attribute(.transcriptTable, at: run.location, longestEffectiveRange: &full, in: whole)
            drawChrome(of: table, characters: full, at: origin)
        }
    }

    private func drawChrome(of table: TranscriptTable, characters: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var lines: [(rect: NSRect, line: Int)] = []
        var container: NSTextContainer?
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, textContainer, range, _ in
            let first = self.characterIndexForGlyph(at: range.location)
            guard first < storage.length, let line = storage.attribute(.transcriptTableLine, at: first, effectiveRange: nil) as? Int else { return }
            container = textContainer
            lines.append((rect.offsetBy(dx: origin.x, dy: origin.y), line))
        }
        guard let container, let first = lines.first, let last = lines.last else { return }
        let layout = table.layout(width: container.size.width - 2 * container.lineFragmentPadding, in: storage)
        let left = first.rect.minX + container.lineFragmentPadding + table.indent
        let frame = NSRect(x: left, y: first.rect.minY, width: layout.width, height: last.rect.maxY - first.rect.minY).insetBy(dx: 0.25, dy: 0.25)
        guard frame.width > 1, frame.height > 1 else { return }
        let outline = NSBezierPath(roundedRect: frame, xRadius: TranscriptTables.cornerRadius, yRadius: TranscriptTables.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        for (rect, line) in lines {
            let height = layout.height(ofLine: line)
            guard height > 0 else { continue }
            if line == 0, layout.mode == .grid {
                table.look.headerFill.setFill()
                NSRect(x: frame.minX, y: rect.minY, width: frame.width, height: height).fill()
                table.look.headerRule.setFill()
                NSRect(x: frame.minX, y: rect.minY + height - 0.5, width: frame.width, height: 0.5).fill()
            } else if line > 1 {
                table.look.hairline.setFill()
                NSRect(x: frame.minX, y: rect.minY, width: frame.width, height: 0.5).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        table.look.border.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
    }

    /// The cells of the tables' lines in `glyphsToShow`, over the selection.
    func drawTableCells(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, glyphs, _ in
            let first = self.characterIndexForGlyph(at: glyphs.location)
            guard let (table, line, layout) = self.table(at: first, container: container), line != -1 else { return }
            let height = layout.height(ofLine: line)
            guard height > 0 else { return }
            let cells = table.cells(in: storage)
            let left = rect.minX + origin.x + container.lineFragmentPadding + table.indent
            let top = rect.minY + origin.y + TranscriptTables.cellPadding
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            func draw(_ text: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
                let size = TranscriptTables.size(of: text, width: width, lineHeight: table.lineHeight)
                if text.length > 0 { text.draw(with: NSRect(x: x, y: y, width: width, height: size.height), options: options) }
                return size.height
            }
            switch layout.mode {
            case .grid:
                let row = line == 0 ? cells.header : cells.rows[line - 1]
                for (index, text) in row.enumerated() where index < layout.widths.count {
                    _ = draw(text, x: left + layout.starts[index], y: top, width: layout.widths[index])
                }
            case .stack:
                guard line > 0 else { return }
                let cells = table.stackCells(in: storage)
                let row = cells.rows[line - 1]
                let inner = layout.width - 2 * TranscriptTables.padding
                let x = left + TranscriptTables.padding
                var y = top
                if let title = row.first, title.length > 0 { y += draw(title, x: x, y: y, width: inner) }
                for index in row.indices.dropFirst() where row[index].length > 0 {
                    if y > top { y += TranscriptTables.stackSpacing }
                    let name = index < cells.header.count ? cells.header[index] : NSAttributedString()
                    if layout.label > 0 {
                        let named = draw(name, x: x, y: y, width: layout.label)
                        let value = draw(row[index], x: x + layout.label + TranscriptTables.labelGap, y: y, width: inner - layout.label - TranscriptTables.labelGap)
                        y += max(named, value)
                    } else {
                        if name.length > 0 { y += draw(name, x: x, y: y, width: inner) }
                        y += draw(row[index], x: x, y: y, width: inner)
                    }
                }
            }
        }
    }
}

extension TranscriptTables {
    /// A column's name beside a stacked row's value: the header's words, in the quiet colour of a label rather than the header's.
    static func label(_ name: NSAttributedString, color: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: name)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            if (value as? NSColor) != NSColor.clear { text.addAttribute(.foregroundColor, value: color, range: range) }
        }
        return text
    }
}
