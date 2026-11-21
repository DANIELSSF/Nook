import AppKit
import SwiftUI

// Copy buttons on what Claude writes in the mirror: one on each reply, which copies the reply as Markdown; one on each fenced block,
// which copies the block's code alone, ready to paste in a terminal; and one on each quote, which copies what it quotes (a message
// Claude drafted to be pasted elsewhere, most often) as Markdown, without its `>`.
//
//   MirrorReplies       where a reply of Claude's starts and ends in the mirror's text, and the Markdown it was written in (pure)
//   MirrorCopyModel     the buttons on show: the reply, block and quote the pointer is on, and where each stands (the mirror's AppKit
//                       side publishes it, `LiveTerminalScrollView.refreshCopyTargets`)
//   MirrorCopyControls  the buttons themselves, over the mirror
//
// Why SwiftUI buttons over the text, and only the ones under the pointer. They are the island's controls like any other (its press,
// its tips, its pointer holes, VoiceOver), and there are one or two of them at a time, so the text view keeps no views of its own and
// scrolling costs nothing: a scroll puts them away and they come back where the pointer rests once it stops. A block's button at rest
// is drawn by the layout manager with the text (`MirrorLayoutManager.drawCodeButtons`), which scrolls with it for free; the live one
// stands right over it, on the tile's own colour, and only adds the hover.
//
// Where a reply's Markdown comes from. With Claude's record (the usual case) the mirror's text is the record's: each reply is its
// text block with `⏺ ` before it and two spaces before every other line (`TranscriptRenderer.indented`), nothing else, so taking those
// off gives back the Markdown Claude wrote, byte for byte. Without the record the mirror is Claude's screen, which has its own line
// breaks where the terminal wrapped; they are joined back (`MirrorReplies.unwrapped`).

enum MirrorReplies {
    /// The reply of Claude's that holds the character at `index`: from its `⏺` line to its last line that is not blank, without the
    /// line break after it. Nil on anything else (a prompt, a tool call or its result, what is not a conversation).
    static func reply(containing index: Int, in text: NSString) -> NSRange? {
        guard text.length > 0 else { return nil }
        var line = text.lineRange(for: NSRange(location: min(max(0, index), text.length - 1), length: 0))
        // Up to the line that opened what this line is in.
        while true {
            switch TranscriptClassifier.opening(text, line: content(of: line, in: text)) {
            case .assistant?: return NSRange(location: line.location, length: end(ofReplyAt: line, in: text) - line.location)
            case nil:
                guard line.location > 0 else { return nil }
                line = text.lineRange(for: NSRange(location: line.location - 1, length: 0))
            default: return nil
            }
        }
    }

    /// The last reply of the text, nil when it has none.
    static func last(in text: NSString) -> NSRange? {
        var end = text.length
        while end > 0 {
            let line = text.lineRange(for: NSRange(location: end - 1, length: 0))
            if TranscriptClassifier.opening(text, line: content(of: line, in: text)) == .assistant { return reply(containing: line.location, in: text) }
            end = line.location
        }
        return nil
    }

    /// Where the reply whose first line is `head` ends: the end of its last line that is not blank, before the next line that opens
    /// something of its own.
    private static func end(ofReplyAt head: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(content(of: head, in: text))
        var next = NSMaxRange(head)
        while next < text.length {
            let line = text.lineRange(for: NSRange(location: next, length: 0))
            let words = content(of: line, in: text)
            guard TranscriptClassifier.opening(text, line: words) == nil else { break }
            if !isBlank(words, in: text) { end = NSMaxRange(words) }
            next = NSMaxRange(line)
        }
        return end
    }

    private static func content(of line: NSRange, in text: NSString) -> NSRange {
        var content = line
        while content.length > 0, [0x0A, 0x0D].contains(text.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
        return content
    }

    private static func isBlank(_ range: NSRange, in text: NSString) -> Bool {
        (range.location..<NSMaxRange(range)).allSatisfy { [0x20, 0x09].contains(text.character(at: $0)) }
    }

    /// A reply as the mirror shows it (`reply(containing:in:)`), as Markdown: Claude's dot and the space after it off its first line,
    /// the reply's two columns off every other one, and nothing blank at either end. `fromRecord` says the text is Claude's record,
    /// whose lines are the Markdown's own; the screen's are joined where the terminal wrapped them, and lose the spaces it pads with.
    static func markdown(_ reply: String, fromRecord: Bool) -> String {
        var lines = reply.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }
        lines[0] = withoutMarker(lines[0])
        for index in lines.indices.dropFirst() {
            var line = Substring(lines[index])
            for _ in 0..<2 where line.first == " " { line = line.dropFirst() }
            lines[index] = String(line)
        }
        if !fromRecord { lines = unwrapped(lines.map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }) }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// `⏺ text` → `text`: the dot (with its emoji selector, if any) and one space.
    private static func withoutMarker(_ line: String) -> String {
        var scalars = Substring.UnicodeScalarView(line.unicodeScalars.drop { $0 == " " })
        guard let first = scalars.first, first == "⏺" || first == "●" else { return line }
        scalars = scalars.dropFirst()
        if scalars.first == "\u{FE0F}" { scalars = scalars.dropFirst() }
        if scalars.first == " " { scalars = scalars.dropFirst() }
        return String(scalars)
    }

    /// The screen's lines with the terminal's wraps joined back: a line goes on the one above when that one was full, that is, when
    /// this line's first word would not have fitted after it in the widest line's width, and neither of them is a block of its own
    /// (an item of a list, a heading, a quote, a table's row, a fence).
    static func unwrapped(_ lines: [String]) -> [String] {
        let width = lines.map(\.count).max() ?? 0
        var joined: [String] = []
        // The line above as the screen had it: whether it was full is told by its own length, not by what it was joined to.
        var above: String?
        for line in lines {
            let words = line.drop { $0 == " " }
            if let above, let last = joined.last, !above.trimmingCharacters(in: .whitespaces).isEmpty, !words.isEmpty, !startsBlock(words), !isRow(above),
               above.count + 1 + (words.firstIndex(of: " ").map { words.distance(from: words.startIndex, to: $0) } ?? words.count) > width {
                joined[joined.count - 1] = last + " " + words
            } else {
                joined.append(line)
            }
            above = line
        }
        return joined
    }

    private static func startsBlock(_ words: Substring) -> Bool {
        if ["- ", "* ", "+ ", "• ", "> ", "#", "|", "```", "~~~"].contains(where: { words.hasPrefix($0) }) { return true }
        let digits = words.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && digits.count <= 3 && [". ", ") "].contains { words.dropFirst(digits.count).hasPrefix($0) }
    }

    private static func isRow(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
}

// MARK: - The buttons on show

@MainActor
final class MirrorCopyModel: ObservableObject {
    struct Target: Equatable {
        enum Kind: Equatable { case reply, code, quote }
        var kind: Kind
        /// The first character of the reply, the block (`TranscriptCodeBlock.id`) or the quote (`TranscriptQuoteBlock.id`): what the
        /// button copies is found from there when it is clicked.
        var id: Int
        /// Where the button stands, in the mirror's own space (from its top left, as SwiftUI lays out over it).
        var frame: CGRect

        func same(_ other: Target?) -> Bool { other?.kind == kind && other?.id == id }
    }

    @Published private(set) var reply: Target?
    @Published private(set) var code: Target?
    @Published private(set) var quote: Target?
    /// The button that just copied: it answers with a check mark for a moment.
    @Published private(set) var copied: Target?
    /// What the mirror copies for a button; false when there was nothing to copy (the text changed under it).
    var perform: ((Target) -> Bool)?
    private var copiedReset: DispatchWorkItem?
    /// How long the check mark stays.
    static let confirmation: TimeInterval = 1.4

    /// The buttons the pointer (or the caret) is on now. Only a real change is published: the pointer moves all the time.
    func show(reply: Target?, code: Target?, quote: Target? = nil) {
        if self.reply != reply { self.reply = reply }
        if self.code != code { self.code = code }
        if self.quote != quote { self.quote = quote }
    }

    func copy(_ target: Target) {
        guard perform?(target) == true else { return }
        copied = target
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copied = nil }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmation, execute: reset)
    }
}

// MARK: - The buttons

/// The copy buttons over the mirror: the reply's at the end of its first line (or, for a long reply whose start has scrolled away,
/// at the top of what shows of it), and the block's at its tile's top right. They come and go with a short fade.
struct MirrorCopyControls: View {
    @ObservedObject var model: MirrorCopyModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nookMotion) private var animations

    /// The reply's button; a block's is `TranscriptCodeBlocks.buttonSize`.
    static let replySize: CGFloat = 22

    var body: some View {
        let fade: Animation? = animations ? .easeOut(duration: 0.16) : nil
        // Only the buttons take room (and clicks): each is moved from the mirror's top left to where it stands.
        ZStack(alignment: .topLeading) {
            if let reply = model.reply { place(reply).id("reply-\(reply.id)") }
            if let code = model.code { place(code).id("code-\(code.id)") }
            if let quote = model.quote { place(quote).id("quote-\(quote.id)") }
        }
        .animation(fade, value: model.reply?.id)
        .animation(fade, value: model.code?.id)
        .animation(fade, value: model.quote?.id)
    }

    private func place(_ target: MirrorCopyModel.Target) -> some View {
        MirrorCopyButton(kind: target.kind, copied: target.same(model.copied), animated: animations && !reduceMotion) { model.copy(target) }
            .frame(width: target.frame.width, height: target.frame.height)
            .offset(x: target.frame.minX, y: target.frame.minY)
            .transition(.opacity)
    }
}

/// One copy button: a ghost of the copy symbol, quiet at rest, lit under the pointer, a check mark for a moment once it has copied.
/// It stands on the surface it covers (the island's, or a block's tile), so the text under it never shows through. A reply's, a block's
/// and a quote's look and act alike; only their words differ.
struct MirrorCopyButton: View {
    var kind: MirrorCopyModel.Target.Kind
    var copied: Bool
    var animated = true
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = TranscriptPalette(dark: scheme == .dark)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            ZStack {
                shape.fill(Color.nookScreenSolid)
                if kind == .code { shape.fill(Color(nsColor: palette.codeBlockFill)) }
                shape.fill(Color.nookWash(hovering ? 0.10 : 0, light: hovering ? 0.07 : 0))
                Image(systemName: copied ? MirrorCopySymbol.copiedName : MirrorCopySymbol.name)
                    .font(.system(size: TranscriptCodeBlocks.symbolSize, weight: copied ? .bold : .medium))
                    .foregroundStyle(copied ? Color.nookMint : hovering ? Color.nookText.opacity(0.88) : Color(nsColor: palette.codeButton))
                    .contentTransition(animated ? .symbolEffect(.replace) : .identity)
            }
            .contentShape(shape)
        }
        .nookPress(.pop)
        .onHover { hovering = $0 }
        .animation(animated ? .easeOut(duration: 0.15) : nil, value: hovering)
        .animation(animated ? .easeOut(duration: 0.18) : nil, value: copied)
        // The arrow, not the text's I-beam, over the button.
        .pointerHole()
        .nookTip(words.tip, id: words.id)
        .accessibilityLabel(copied ? "Copiado" : words.label)
        .accessibilityHint(words.hint)
    }

    /// What the button says, by what it copies.
    private var words: (tip: NookTip, id: String, label: String, hint: String) {
        switch kind {
        case .reply: (NookTip("Copiar respuesta", detail: "En Markdown, como la escribió Claude"), "mirrorCopyReply", "Copiar respuesta",
                      "Copia el mensaje de Claude en Markdown")
        case .code: (NookTip("Copiar código", detail: "Solo el contenido del bloque, listo para pegar"), "mirrorCopyCode", "Copiar código",
                     "Copia solo el código del bloque, sin las vallas ni la sangría")
        case .quote: (NookTip("Copiar cita", detail: "Solo el texto citado, en Markdown, listo para pegar"), "mirrorCopyQuote", "Copiar cita",
                      "Copia solo el texto de la cita en Markdown, sin los signos >")
        }
    }
}
