import AppKit

/// Copies on select, like a terminal: releasing the mouse after a selection fills the clipboard.
final class MirrorTextView: NSTextView, PointerClaiming {
    var onCopy: (() -> Void)?
    var pasteboard = NSPasteboard.general
    /// False while a card covers the conversation (`setClaimsPointer`): then no I-beam and no link hand, which would show over the card. The same
    /// where chrome floats over the text (`pointerHole()`): the arrow, and the text around it keeps its I-beam.
    var claimsPointer = true
    override func cursorUpdate(with event: NSEvent) {
        if pointerHeldBack(at: event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if pointerHeldBack(at: event) { NSCursor.arrow.set() } else { super.mouseMoved(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks the drag, double and triple clicks until the mouse is released.
        super.mouseDown(with: event)
        copySelection()
    }
    /// The first message's tab (see `TranscriptBubble.label`) stands in the room the text view keeps above it, which the text
    /// view's own drawing cannot reach (it clips to the text container), so it is drawn first, before that clip is set.
    override func draw(_ dirtyRect: NSRect) {
        if let storage = textStorage, storage.length > 0,
           let bubble = storage.attribute(.transcriptBubble, at: 0, effectiveRange: nil) as? TranscriptBubble, bubble.label != nil {
            bubble.drawTab(atX: textContainerOrigin.x + 10, bottomY: textContainerOrigin.y)
        }
        super.draw(dirtyRect)
    }

    @discardableResult func copySelection() -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        pasteboard.clearContents()
        pasteboard.setString((string as NSString).substring(with: range), forType: .string)
        onCopy?()
        return true
    }
}

/// A text mirror that reflows to the viewport without changing the original terminal.
final class LiveTerminalScrollView: NSScrollView {
    /// The mirror's default font (11 pt); the user's chat text size replaces it (`setFontSize`).
    static let baseFont = DisplaySettings.chatFont(size: DisplaySettings.defaultChatSize)
    /// The mirror's own font. The text view's `font` reports the first character's, which a styled transcript changes.
    private(set) var font = LiveTerminalScrollView.baseFont
    let textView = MirrorTextView.makeTranscriptCapable()
    /// The theme and whether the text is Claude's transcript (dressed per role) or plain output; set by `setTheme`.
    private var theme: (dark: Bool, transcript: Bool)?
    /// The colours of the user's messages, which are the tab's, in the theme's shades (`TabTint.voice(_:)`); set by `setVoice`. Until one is set they are mint's in the
    /// theme's own, so a mirror that has no tab to ask never shows the dark island's pale text on paper.
    private var chosenVoice: TabVoice?
    var voice: TabVoice { chosenVoice ?? TabTint.mint.voice(theme?.dark == false ? .light : .dark) }
    /// Messages that stand after the conversation until Claude's record has them (`setMessages`), the conversation's own text
    /// (what `setText` was given), and where those messages' blocks are in the text on show.
    private(set) var messages: [MirrorMessage] = []
    private var conversationText = ""
    /// Whether the text on show was composed as Claude's transcript (with its messages after it).
    private var shownAsTranscript = false
    private var blocks: [MirrorMessages.Block] = []
    private var fittingText = false
    private var fittedViewport = NSSize.zero
    private var pendingFollowOutput: Bool?
    /// Which text is shown (Claude's conversation or an agent's) and where the reader was in each of the others.
    private(set) var contentID = ""
    private var savedPositions: [String: ScrollPosition] = [:]
    /// Set by `setContent`: the next text that arrives belongs to the new content and opens where the reader left it.
    private var pendingPosition: ScrollPosition?

    enum ScrollPosition: Equatable {
        case end
        case offset(CGFloat)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The clip view that makes the text's claim on the pointer (it leaves out the places chrome floats over it).
        contentView = TextClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Room for the user message's block above the first line and below the last one.
        textView.textContainerInset = NSSize(width: 2, height: Self.topInset)
        // A link in a reply keeps the colour and the underline the styler gave it (the text view would paint its own blue).
        textView.linkTextAttributes = Self.linkAttributes(dark: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        textView.defaultParagraphStyle = paragraph
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The attributes of unstyled text. The text view's own typing attributes follow the selection, so a click on a dimmed
    /// tool line would pass that look on to the text that arrives next.
    private var plainAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let color = theme.map { TranscriptPalette(dark: $0.dark).text } ?? NSColor.textColor
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// How the text view paints a link: the theme's colour for it, which the text view applies over the one the styler gave the range (so it has to be the
    /// theme's own: the dark theme's pale blue is 2 : 1 on the paper), underlined, with the pointing hand.
    static func linkAttributes(dark: Bool) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: TranscriptPalette(dark: dark).link, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// Sets the light or dark theme and whether the text is Claude's transcript. A change restyles what is already
    /// shown; plain output (a shell, Codex) keeps the original look.
    func setTheme(dark: Bool, transcript: Bool) {
        guard theme?.dark != dark || theme?.transcript != transcript else { return }
        theme = (dark, transcript)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        textView.linkTextAttributes = Self.linkAttributes(dark: dark)
        // Also the color of text that arrives later; it recolors everything now, so styling follows.
        textView.textColor = TranscriptPalette(dark: dark).text
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        restyleAll(storage, dark: dark, transcript: transcript)
        fitText(followOutput: pendingFollowOutput ?? isFollowingOutput)
    }

    /// Everything shown dressed again: the transcript (or the plain output) and, over it, the blocks of the messages on their way.
    private func restyleAll(_ storage: NSTextStorage, dark: Bool, transcript: Bool, label: String? = nil) {
        if transcript {
            TranscriptStyler.restyle(storage, from: 0, dark: dark, font: font, taskLabel: label ?? taskLabel, voice: voice)
            styleMessageBlocks(storage)
        } else { TranscriptStyler.reset(storage, dark: dark, font: font) }
    }

    /// Sets the colours of the user's messages (the tab's). What is already shown is restyled once, which only happens when the
    /// user changes the tab's colour: each tab has its own mirror, so switching tabs never gets here with text on show.
    func setVoice(_ voice: TabVoice) {
        guard voice != chosenVoice else { return }
        chosenVoice = voice
        guard let theme, theme.transcript, let storage = textView.textStorage, storage.length > 0 else { return }
        restyleAll(storage, dark: theme.dark, transcript: true)
        textView.needsDisplay = true
        fitText(followOutput: pendingFollowOutput ?? isFollowingOutput)
    }

    /// Sets the text size (the user's chat size). Everything shown is restyled once with the new font; text that arrives
    /// later is styled with it from the start. Where the reader was in the conversation is kept: at the end it stays at
    /// the end, elsewhere at the same place in the text.
    func setFontSize(_ size: Double) {
        guard abs(Double(font.pointSize) - size) > 0.01 else { return }
        font = DisplaySettings.chatFont(size: size)
        textView.font = font
        guard let theme, let storage = textView.textStorage, storage.length > 0 else { return }
        let followOutput = pendingFollowOutput ?? isFollowingOutput
        restyleAll(storage, dark: theme.dark, transcript: theme.transcript)
        fitText(followOutput: followOutput)
    }

    /// A word for the top edge of the text's first message ("Tarea" in an agent's conversation, whose first message is its task
    /// from Claude). The text view keeps room above it for the word; nil takes both away.
    private(set) var taskLabel: String?
    private static let topInset: CGFloat = 4

    func setTaskLabel(_ label: String?) {
        guard label != taskLabel else { return }
        taskLabel = label
        textView.textContainerInset = NSSize(width: 2, height: Self.topInset + (label == nil ? 0 : TranscriptBubble.tabRoom))
        textView.needsDisplay = true
        guard let theme, theme.transcript, let storage = textView.textStorage, storage.length > 0 else { return }
        restyleAll(storage, dark: theme.dark, transcript: true, label: label)
        fitText(followOutput: pendingFollowOutput ?? isFollowingOutput)
    }

    /// Says which text the mirror shows from now on. Leaving one text for another remembers where the reader was in the first
    /// (at its end, or at an offset), and the next `setText` opens the second where the reader last left it, or at its end.
    func setContent(_ id: String) {
        guard id != contentID else { return }
        savedPositions[contentID] = isFollowingOutput ? .end : .offset(contentView.bounds.origin.y)
        contentID = id
        pendingPosition = savedPositions[id] ?? .end
    }

    func setText(_ text: String) { update(text: text, messages: messages) }

    /// The messages on their way (sent and not in Claude's record yet, or held in its queue) that stand after the conversation. They
    /// only count in Claude's transcript, where `TranscriptStyler` dresses their blocks.
    func setMessages(_ new: [MirrorMessage]) { update(text: conversationText, messages: new) }

    /// The conversation's text and the messages after it, set together so the text view is laid out once.
    func update(text: String, messages new: [MirrorMessage]) {
        let changed = new != messages
        // Every redraw of the island passes the same conversation again: with nothing new to show nothing is compared or copied (it
        // was a copy of up to 240,000 characters per redraw). Same storage, so the comparison is immediate.
        guard changed || text != conversationText || pendingPosition != nil || shownAsTranscript != (theme?.transcript == true) else { return }
        conversationText = text
        messages = new
        // Only a change of the messages can leave the words as they were; the text (up to 240,000 characters) is not copied for nothing.
        let before = changed ? textView.string : nil
        show()
        // The same words in another state (delivered, now queued): the blocks are dressed again, from the first of them.
        guard let before, textView.string == before, let storage = textView.textStorage, let theme, theme.transcript, let first = blocks.first else { return }
        TranscriptStyler.restyle(storage, from: first.range.location, dark: theme.dark, font: font, taskLabel: taskLabel, voice: voice)
        styleMessageBlocks(storage)
        fitText(followOutput: pendingFollowOutput ?? isFollowingOutput)
    }

    /// The conversation and its messages, as the text view shows them.
    private func show() {
        shownAsTranscript = theme?.transcript == true
        let composed = MirrorMessages.compose(conversationText, with: theme?.transcript == true ? messages : [])
        blocks = composed.blocks
        replaceText(with: composed.text)
    }

    /// Paints the blocks of the messages that are not in the conversation yet: a queued one grey, a sending one with its tag. A
    /// message that is only waiting a moment for Claude's record is a message like any other, and is left as it is. The pill takes
    /// room at the right of the block's first paragraph, so its text wraps before it.
    private func styleMessageBlocks(_ storage: NSTextStorage) {
        guard blocks.contains(where: { $0.state != .waiting }) else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        for block in blocks where block.state != .waiting && NSMaxRange(block.range) <= storage.length {
            let look = MirrorMessageLook(block.state, voice: voice, dark: theme?.dark ?? true)
            // The styler's block runs on through the line break after its last line; the new one must cover the same characters, or
            // what is left of the old one is painted over it.
            var run = block.range
            let existing = storage.attribute(.transcriptBubble, at: block.range.location, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptBubble
            if existing == nil { run = block.range }
            storage.addAttribute(.transcriptBubble, value: TranscriptBubble(id: existing?.id ?? block.range.location, fill: look.fill, stroke: look.stroke, accent: look.marker, tag: look.tag), range: run)
            storage.addAttribute(.foregroundColor, value: look.marker, range: block.marker)
            let body = NSRange(location: NSMaxRange(block.marker), length: NSMaxRange(block.range) - NSMaxRange(block.marker))
            storage.addAttribute(.foregroundColor, value: look.text, range: body)
            guard look.tag != nil else { continue }
            let first = NSIntersectionRange((storage.string as NSString).paragraphRange(for: NSRange(location: block.range.location, length: 0)), block.range)
            let current = storage.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil) as? NSParagraphStyle
            let paragraph = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            paragraph.tailIndent = -TranscriptBubble.tagGutter
            storage.addAttribute(.paragraphStyle, value: paragraph, range: first)
        }
    }

    private func replaceText(with text: String) {
        // The storage's own characters, not a copy of them (`textView.string` copied up to 240,000 characters on every update). They
        // change with the edit below, so their length is read before it.
        let previous: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
        let updated = text as NSString
        let common = Self.commonPrefix(previous, updated)
        guard common < previous.length || common < updated.length else { return }
        // Text of other content opens at its saved place: the end follows the output, an offset stays where it was.
        let restore = pendingPosition
        pendingPosition = nil
        let followOutput = restore.map { $0 == .end } ?? pendingFollowOutput ?? (previous.length == 0 || isFollowingOutput)
        let selection = textView.selectedRange()
        // Output changes at the end; replacing only the changed tail keeps the layout of everything
        // above it, instead of laying out up to 80,000 characters again on every update.
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: common, length: previous.length - common),
                                      with: NSAttributedString(string: updated.substring(from: common), attributes: plainAttributes))
            // Only the changed tail and its message block are restyled, never the whole history.
            if let theme, theme.transcript {
                TranscriptStyler.restyle(storage, from: common, dark: theme.dark, font: font, taskLabel: taskLabel, voice: voice)
                styleMessageBlocks(storage)
            }
            storage.endEditing()
        } else { textView.string = text }
        // New output must not drop a selection whose text is still in place.
        // A selection keeps pointing at the same text only inside the untouched beginning; anywhere else
        // the same range could now cover different text, so it is cleared instead of copied wrongly.
        if selection.length > 0 {
            textView.setSelectedRange(NSMaxRange(selection) <= common ? selection : NSRange(location: 0, length: 0))
        }
        fitText(followOutput: followOutput)
        if case .offset(let y)? = restore { scroll(toOffset: y) }
    }

    /// Puts the reader `y` points down the text, kept inside it.
    private func scroll(toOffset y: CGFloat) {
        let bottom = max(0, textView.frame.height - contentSize.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), bottom)))
        reflectScrolledClipView(contentView)
    }

    /// Length of the shared beginning, compared in blocks and moved back to a whole character.
    static func commonPrefix(_ a: NSString, _ b: NSString) -> Int {
        let limit = min(a.length, b.length)
        var start = 0
        var left = [unichar](repeating: 0, count: 4096), right = left
        while start < limit {
            let range = NSRange(location: start, length: min(4096, limit - start))
            a.getCharacters(&left, range: range); b.getCharacters(&right, range: range)
            guard let offset = (0..<range.length).first(where: { left[$0] != right[$0] }) else { start += range.length; continue }
            start += offset
            break
        }
        return start < b.length ? b.rangeOfComposedCharacterSequence(at: start).location : start
    }

    override func layout() {
        super.layout()
        if contentSize != fittedViewport { fitText(followOutput: pendingFollowOutput ?? isFollowingOutput) }
    }

    private var isFollowingOutput: Bool {
        documentVisibleRect.maxY >= textView.bounds.maxY - 24
    }

    private func fitText(followOutput: Bool) {
        let viewport = contentSize
        guard !fittingText else { return }
        pendingFollowOutput = followOutput
        guard viewport.width > 0, viewport.height > 0,
              let container = textView.textContainer, let manager = textView.layoutManager else { return }
        pendingFollowOutput = nil
        fittingText = true
        defer { fittingText = false }
        let position = contentView.bounds.origin
        fittedViewport = viewport
        textView.setFrameSize(NSSize(width: viewport.width, height: max(textView.frame.height, viewport.height)))
        container.containerSize = NSSize(width: max(1, viewport.width - textView.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(viewport.height, ceil(manager.usedRect(for: container).maxY + textView.textContainerInset.height * 2))
        textView.setFrameSize(NSSize(width: viewport.width, height: height))
        let bottom = max(0, height - viewport.height)
        contentView.scroll(to: NSPoint(x: 0, y: followOutput ? bottom : min(max(0, position.y), bottom)))
        reflectScrolledClipView(contentView)
    }
}
