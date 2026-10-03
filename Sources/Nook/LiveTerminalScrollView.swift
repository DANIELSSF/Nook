import AppKit

/// Copies on select, like a terminal: releasing the mouse after a selection fills the clipboard.
final class MirrorTextView: NSTextView {
    var onCopy: (() -> Void)?
    var pasteboard = NSPasteboard.general
    override func mouseDown(with event: NSEvent) {
        // NSTextView tracks the drag, double and triple clicks until the mouse is released.
        super.mouseDown(with: event)
        copySelection()
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
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = font
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Room for the user message's block above the first line and below the last one.
        textView.textContainerInset = NSSize(width: 2, height: 4)
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
        let color = theme.map { $0.dark ? NSColor.white : NSColor.black } ?? NSColor.textColor
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// Sets the light or dark theme and whether the text is Claude's transcript. A change restyles what is already
    /// shown; plain output (a shell, Codex) keeps the original look.
    func setTheme(dark: Bool, transcript: Bool) {
        guard theme?.dark != dark || theme?.transcript != transcript else { return }
        theme = (dark, transcript)
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Also the color of text that arrives later; it recolors everything now, so styling follows.
        textView.textColor = dark ? .white : .black
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        if transcript { TranscriptStyler.restyle(storage, from: 0, dark: dark, font: font) }
        else { TranscriptStyler.reset(storage, dark: dark, font: font) }
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
        if theme.transcript { TranscriptStyler.restyle(storage, from: 0, dark: theme.dark, font: font) }
        else { TranscriptStyler.reset(storage, dark: theme.dark, font: font) }
        fitText(followOutput: followOutput)
    }

    /// Says which text the mirror shows from now on. Leaving one text for another remembers where the reader was in the first
    /// (at its end, or at an offset), and the next `setText` opens the second where the reader last left it, or at its end.
    func setContent(_ id: String) {
        guard id != contentID else { return }
        savedPositions[contentID] = isFollowingOutput ? .end : .offset(contentView.bounds.origin.y)
        contentID = id
        pendingPosition = savedPositions[id] ?? .end
    }

    func setText(_ text: String) {
        let previous = textView.string as NSString
        let updated = text as NSString
        guard !previous.isEqual(to: text) else { return }
        // Text of other content opens at its saved place: the end follows the output, an offset stays where it was.
        let restore = pendingPosition
        pendingPosition = nil
        let followOutput = restore.map { $0 == .end } ?? pendingFollowOutput ?? (previous.length == 0 || isFollowingOutput)
        let selection = textView.selectedRange()
        // Output changes at the end; replacing only the changed tail keeps the layout of everything
        // above it, instead of laying out up to 80,000 characters again on every update.
        let common = Self.commonPrefix(previous, updated)
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: common, length: previous.length - common),
                                      with: NSAttributedString(string: updated.substring(from: common), attributes: plainAttributes))
            // Only the changed tail and its message block are restyled, never the whole history.
            if let theme, theme.transcript { TranscriptStyler.restyle(storage, from: common, dark: theme.dark, font: font) }
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
