import AppKit

// The block-level Markdown of Claude's replies that the mirror draws rather than prints: fenced code blocks and block quotes. As
// everywhere in the mirror (`InlineMarkdown`, `TranscriptTable`), no character changes: the fences and the `>` marks stay in the
// text, so a selection copies the Markdown back.
//
//   code block  ```lang … ```. The fence lines take no room (their characters are laid out as an empty line, `MirrorLayoutManager`),
//               the code sits on a soft rounded tile, coloured by its language or, without one, in the colour of inline `code`, and
//               the tile has its own copy button at its top right (`TranscriptCodeBlocks.copyText`: the code alone, no fences and no
//               indent, ready to paste in a terminal). The button rests drawn here, quiet; the mirror's hover stands the live one
//               over it (`MirrorCopyControls`)
//   quote       `> …`. The marks keep their room but are not drawn; a thin bar stands in each one's place, and the text is quieter
//               and slanted, as Claude's own terminal shows a quote. A quote is most often a message Claude drafted to be pasted
//               somewhere else, so each one (a run of `>` lines, its empty `>` lines included) has a copy button too, at the end of its
//               first line, which copies the quote's own Markdown (`TranscriptQuotes.copyText`)

extension NSAttributedString.Key {
    /// A `TranscriptCodeBlock` on every character of a fenced block's lines, its fences included.
    static let transcriptCodeBlock = NSAttributedString.Key("nook.transcript.codeBlock")
    /// A `TranscriptQuoteBlock` on every character of a quote's lines.
    static let transcriptQuoteBlock = NSAttributedString.Key("nook.transcript.quoteBlock")
    /// How many quotes deep a reply's line is (`> > text` is 2), on the whole line: a bar is drawn for each.
    static let transcriptQuote = NSAttributedString.Key("nook.transcript.quote")
}

/// One fenced block of a reply: its tile's colours. It travels with the text as an attribute, so a theme change repaints it, and
/// neighbouring blocks stay apart through their `id`.
final class TranscriptCodeBlock: NSObject {
    /// The offset of the block's first line (its opening fence).
    let id: Int
    /// Where the tile starts, from the start of its lines: the reply's text column.
    let indent: CGFloat
    let fill: NSColor
    let stroke: NSColor
    /// The copy button at rest.
    let icon: NSColor
    /// One line of the code's font: the copy button stands beside the first.
    let lineHeight: CGFloat

    init(id: Int, indent: CGFloat, fill: NSColor, stroke: NSColor, icon: NSColor, lineHeight: CGFloat) {
        self.id = id; self.indent = indent; self.fill = fill; self.stroke = stroke; self.icon = icon; self.lineHeight = lineHeight
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptCodeBlock else { return false }
        return id == other.id && indent == other.indent && fill == other.fill && stroke == other.stroke && icon == other.icon && lineHeight == other.lineHeight
    }
    override var hash: Int { id }
}

/// One quote of a reply (a run of `>` lines): its copy button. Neighbouring quotes stay apart through their `id`.
final class TranscriptQuoteBlock: NSObject {
    /// The offset of the quote's first line.
    let id: Int
    /// The copy button at rest.
    let icon: NSColor
    let lineHeight: CGFloat

    init(id: Int, icon: NSColor, lineHeight: CGFloat) {
        self.id = id; self.icon = icon; self.lineHeight = lineHeight
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TranscriptQuoteBlock else { return false }
        return id == other.id && icon == other.icon && lineHeight == other.lineHeight
    }
    override var hash: Int { id }
}

enum TranscriptQuotes {
    /// The start of the run of quoted lines right above the line that starts at `location` (or `location`): a quote is one block, so a
    /// change to one of its lines restyles it from its first line, which names it. A quote's lines are a reply's: two columns in, or
    /// Claude's dot on the reply's first line.
    static func firstLine(above location: Int, in text: NSString) -> Int {
        var start = location
        while start > 0 {
            let line = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard let opens = quoteLine(text, line) else { break }
            start = line.location
            if opens { break }
        }
        return start
    }

    /// Whether `line` is shaped like a quoted line of a reply: nil when it isn't, true when it is Claude's first line of a reply
    /// (nothing above it is in the same quote).
    private static func quoteLine(_ text: NSString, _ line: NSRange) -> Bool? {
        let end = NSMaxRange(line)
        var index = line.location
        var marker = false
        if index < end, [0x23FA, 0x25CF].contains(text.character(at: index)) {
            marker = true
            index += 1
            if index < end, text.character(at: index) == 0xFE0F { index += 1 }
        }
        var spaces = 0
        while index < end, text.character(at: index) == 0x20 { index += 1; spaces += 1 }
        guard marker ? spaces >= 1 : spaces >= 2, index < end, text.character(at: index) == 0x3E else { return nil }
        let next = index + 1
        guard next >= end || [0x20, 0x3E, 0x0A, 0x0D].contains(text.character(at: next)) else { return nil }
        return marker
    }

    /// What a quote's copy button copies: the quote's Markdown as it would be pasted. `lines` are its lines as the mirror has them:
    /// Claude's dot or the reply's two columns come off each, then the quote's own `>` and the space after it (a quote inside it keeps
    /// its own), and nothing blank stays at either end. Everything else of the Markdown stays (bold, lists, `code`). From the screen
    /// (`fromRecord` false), the lines the terminal wrapped are joined back, as a reply's are (`MirrorReplies.unwrapped`).
    static func copyText(_ lines: [String], fromRecord: Bool) -> String {
        var quoted = lines.map { line -> String in
            var text = Substring(line)
            if let first = text.unicodeScalars.first, first == "⏺" || first == "●" {
                text = Substring(text.unicodeScalars.dropFirst().drop { $0 == "\u{FE0F}" })
                if text.first == " " { text = text.dropFirst() }
            } else {
                for _ in 0..<2 where text.first == " " { text = text.dropFirst() }
            }
            for _ in 0..<3 where text.first == " " { text = text.dropFirst() }
            if text.first == ">" {
                text = text.dropFirst()
                if text.first == " " { text = text.dropFirst() }
            }
            return String(text)
        }
        if !fromRecord { quoted = MirrorReplies.unwrapped(quoted.map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }) }
        while quoted.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { quoted.removeFirst() }
        while quoted.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { quoted.removeLast() }
        return quoted.joined(separator: "\n")
    }
}

enum TranscriptCodeBlocks {
    /// Between the tile's left edge and the code, and between the code and the room kept for the copy button.
    static let padding: CGFloat = 8
    /// The room kept free at the tile's right for its copy button.
    static let buttonRoom: CGFloat = 18
    /// The height of a fence's line: the tile's own room above its first line of code and below its last.
    static let fenceHeight: CGFloat = 5
    static let cornerRadius: CGFloat = 6
    /// The copy button: its square, and the symbol in it.
    static let buttonSize: CGFloat = 20
    static let symbolSize: CGFloat = 10.5

    /// What a block's copy button copies: the code alone, as it would be typed. `lines` are the block's lines as the mirror has them,
    /// its fences included: the fences go, then the reply's indent (two columns, `TranscriptRenderer.indented`) and the fence's own
    /// indent come off every line, as Markdown takes them off; trailing spaces and blank lines at either end go too. A block whose
    /// opening fence is on the reply's first line (`⏺ ```bash`) is read the same way.
    static func copyText(_ lines: [String]) -> String {
        var body = lines
        // The block's characters end in its last line break.
        while body.last?.isEmpty == true { body.removeLast() }
        var indent = 0
        if let first = body.first, let found = Self.fenceIndent(first) {
            indent = found
            body.removeFirst()
        }
        if let last = body.last, Self.fenceIndent(last) != nil { body.removeLast() }
        var code = body.map { line -> String in
            var characters = Substring(line)
            for _ in 0..<2 where characters.first == " " { characters = characters.dropFirst() }
            for _ in 0..<indent where characters.first == " " { characters = characters.dropFirst() }
            return String(characters).replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
        }
        while code.first?.isEmpty == true { code.removeFirst() }
        while code.last?.isEmpty == true { code.removeLast() }
        return code.joined(separator: "\n")
    }

    /// A fence line of the mirror: its indent past the reply's own (or past Claude's dot on a reply's first line). Nil for any other line.
    private static func fenceIndent(_ line: String) -> Int? {
        var text = Substring(line)
        var marker = false
        if let first = text.unicodeScalars.first, first == "⏺" || first == "●" {
            text = text.drop { !$0.isWhitespace }
            marker = true
        }
        let spaces = text.prefix { $0 == " " }.count
        let rest = text.dropFirst(spaces)
        guard rest.hasPrefix("```") || rest.hasPrefix("~~~") else { return nil }
        return marker ? 0 : max(0, spaces - 2)
    }
}

// MARK: - Drawing

extension MirrorLayoutManager {
    /// The tile of a fenced block, in the text view's coordinates (with `origin` applied), from its first line to its last, from the
    /// reply's text column to the container's right edge. `range` is the block's characters.
    func codeBlockFrame(_ block: TranscriptCodeBlock, characters range: NSRange, origin: NSPoint = .zero) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0, let container = textContainers.first else { return nil }
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        // The last line of a block ends in its line break, which sits on that line's fragment.
        let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let left = first.minX + container.lineFragmentPadding + block.indent
        let right = first.maxX - container.lineFragmentPadding
        guard right > left, last.maxY > first.minY else { return nil }
        return NSRect(x: left, y: first.minY, width: right - left, height: last.maxY - first.minY).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The block's copy button: its square at the tile's top right, beside the first line of code (in the middle of a block of one).
    static func codeBlockButton(in frame: NSRect, lineHeight line: CGFloat) -> NSRect {
        let size = TranscriptCodeBlocks.buttonSize
        let mid = frame.height <= 2 * TranscriptCodeBlocks.fenceHeight + line + 1 ? frame.midY : frame.minY + TranscriptCodeBlocks.fenceHeight + line / 2
        return NSRect(x: frame.maxX - size - 2, y: (mid - size / 2).rounded(), width: size, height: size)
    }

    /// Every fenced block in `glyphsToShow`, whole: the character range and the tile of each.
    func codeBlocks(forGlyphRange glyphsToShow: NSRange) -> [(block: TranscriptCodeBlock, characters: NSRange)] {
        wholeRuns(of: .transcriptCodeBlock, as: TranscriptCodeBlock.self, forGlyphRange: glyphsToShow).map { ($0.0, $0.1) }
    }

    /// Every run of `key` with a `T` in `glyphsToShow`, whole even where the part drawn cuts it.
    func wholeRuns<T: NSObject>(of key: NSAttributedString.Key, as type: T.Type, forGlyphRange glyphsToShow: NSRange) -> [(T, NSRange)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        var found: [(T, NSRange)] = []
        var location = shown.location
        while location < NSMaxRange(shown) {
            var run = NSRange(location: location, length: 0)
            let value = storage.attribute(key, at: location, longestEffectiveRange: &run, in: shown)
            defer { location = max(location + 1, NSMaxRange(run)) }
            guard let block = value as? T else { continue }
            var full = run
            storage.attribute(key, at: run.location, longestEffectiveRange: &full, in: whole)
            found.append((block, full))
        }
        return found
    }

    /// A quote's copy button, in the container's coordinates: at the end of the quote's first line, in the room that line keeps
    /// (`TranscriptStyler.replyButtonRoom`). A quote that opens on Claude's first line of a reply has its button left of the reply's.
    func quoteButton(_ quote: TranscriptQuoteBlock, characters range: NSRange) -> NSRect? {
        guard let storage = textStorage, range.location < storage.length, let container = textContainers.first else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let size = TranscriptCodeBlocks.buttonSize
        let room = TranscriptStyler.replyButtonRoom
        let beside = [0x23FA, 0x25CF].contains(storage.mutableString.character(at: range.location)) ? room : 0
        let right = line.maxX - container.lineFragmentPadding - beside
        return NSRect(x: right - size + 1, y: (used.midY - size / 2).rounded(), width: size, height: size)
    }

    /// The copy buttons of the quotes at rest, over the text. Under the pointer the live one (`MirrorCopyControls`) stands right over it.
    func drawQuoteButtons(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        for (quote, characters) in wholeRuns(of: .transcriptQuoteBlock, as: TranscriptQuoteBlock.self, forGlyphRange: glyphsToShow) {
            guard let button = quoteButton(quote, characters: characters)?.offsetBy(dx: origin.x, dy: origin.y),
                  let image = MirrorCopySymbol.image(color: quote.icon) else { continue }
            let size = image.size
            image.draw(in: NSRect(x: button.midX - size.width / 2, y: button.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The tiles of the fenced blocks, under the selection.
    func drawCodeBlocks(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        for (block, characters) in codeBlocks(forGlyphRange: glyphsToShow) {
            guard let frame = codeBlockFrame(block, characters: characters, origin: origin) else { continue }
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: TranscriptCodeBlocks.cornerRadius, yRadius: TranscriptCodeBlocks.cornerRadius)
            block.fill.setFill()
            path.fill()
            block.stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    /// The copy buttons of the blocks at rest, over the text. Under the pointer the live one (`MirrorCopyControls`) stands right over
    /// it, on the tile's own colour.
    func drawCodeButtons(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        for (block, characters) in codeBlocks(forGlyphRange: glyphsToShow) {
            guard let frame = codeBlockFrame(block, characters: characters, origin: origin) else { continue }
            let button = Self.codeBlockButton(in: frame, lineHeight: block.lineHeight)
            guard let image = MirrorCopySymbol.image(color: block.icon) else { continue }
            let size = image.size
            image.draw(in: NSRect(x: button.midX - size.width / 2, y: button.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// A bar in the room of each `>` of a quoted line, the whole height of each of its lines (one that wraps too), so a quote of
    /// several lines reads as one.
    func drawQuoteBars(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let text = storage.mutableString as NSString
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
            let first = self.characterIndexForGlyph(at: glyphs.location)
            guard first < storage.length, let depth = storage.attribute(.transcriptQuote, at: first, effectiveRange: nil) as? Int, depth > 0,
                  let color = storage.attribute(.transcriptQuoteBar, at: first, effectiveRange: nil) as? NSColor else { return }
            // The marks are on the paragraph's first line: a line it wraps onto takes its bars from there.
            var index = text.paragraphRange(for: NSRange(location: first, length: 0)).location
            var marks: [Int] = []
            let end = min(text.length, index + 400)
            while index < end, marks.count < depth {
                let character = text.character(at: index)
                if character == 0x3E { marks.append(index) } else if character == 0x0A { break }
                else if character != 0x20 && character != 0x23FA && character != 0x25CF && character != 0xFE0F, !marks.isEmpty { break }
                index += 1
            }
            color.setFill()
            for mark in marks {
                let glyph = self.glyphIndexForCharacter(at: mark)
                let x = rect.minX + origin.x + self.location(forGlyphAt: glyph).x + 1
                // Square ends: the bars of a quote's lines meet into one.
                NSRect(x: x, y: rect.minY + origin.y, width: 2, height: rect.height).fill()
            }
        }
    }
}

extension NSAttributedString.Key {
    /// The colour of the hairlines either side of the line that stands where a compaction's summary was (`CompactionSummary.marker`).
    static let transcriptDivider = NSAttributedString.Key("nook.transcript.divider")
}

extension MirrorLayoutManager {
    /// A hairline from each edge of the container to a little short of the divider's words, at their middle.
    func drawDividers(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, storage.length > 0 else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, used, container, glyphs, _ in
            let first = self.characterIndexForGlyph(at: glyphs.location)
            guard first < storage.length, let color = storage.attribute(.transcriptDivider, at: first, effectiveRange: nil) as? NSColor else { return }
            // The words alone, without the line break's room.
            var words = glyphs
            while words.length > 0, storage.mutableString.character(at: self.characterIndexForGlyph(at: NSMaxRange(words) - 1)) == 0x0A { words.length -= 1 }
            guard words.length > 0 else { return }
            let text = self.boundingRect(forGlyphRange: words, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let left = rect.minX + origin.x + container.lineFragmentPadding, right = rect.maxX + origin.x - container.lineFragmentPadding
            let y = (text.midY).rounded() - 0.25
            let gap: CGFloat = 10
            color.setFill()
            if text.minX - gap > left { NSRect(x: left, y: y, width: text.minX - gap - left, height: 0.5).fill() }
            if right > text.maxX + gap { NSRect(x: text.maxX + gap, y: y, width: right - text.maxX - gap, height: 0.5).fill() }
        }
    }
}

extension NSAttributedString.Key {
    /// The colour of a quote's bars, beside `transcriptQuote`.
    static let transcriptQuoteBar = NSAttributedString.Key("nook.transcript.quoteBar")
}

/// The copy symbol the mirror draws itself (a block's button at rest), the same the live button shows.
enum MirrorCopySymbol {
    static let name = "doc.on.doc"
    static let copiedName = "checkmark"

    /// Drawing happens on the main thread only.
    nonisolated(unsafe) private static var cache: [NSColor: NSImage] = [:]

    static func image(color: NSColor) -> NSImage? {
        if let image = cache[color] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: TranscriptCodeBlocks.symbolSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        if cache.count > 16 { cache.removeAll() }
        cache[color] = image
        return image
    }
}
