import AppKit

/// Copies on select, like a terminal: releasing the mouse after a selection fills the clipboard.
final class MirrorTextView: NSTextView, PointerClaiming {
    var onCopy: (() -> Void)?
    var pasteboard = NSPasteboard.general
    /// Hears the pointer come onto the text, move over it and leave it (false), for the copy buttons (`LiveTerminalScrollView.refreshCopyTargets`).
    var onPointer: ((Bool) -> Void)?
    /// The copy buttons' actions for VoiceOver, on the text itself: they are on show only under the pointer.
    var copyActions: (() -> [NSAccessibilityCustomAction])?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // Always, as the island is a panel that is seldom the key window.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?(true)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(false)
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let own = super.accessibilityCustomActions() ?? []
        let copies = copyActions?() ?? []
        return own.isEmpty && copies.isEmpty ? nil : own + copies
    }
    /// The caret moved: the copy buttons follow it while the pointer is elsewhere, when the keyboard moved it (the keyboard's way to
    /// them; a click that only selected some text leaves nothing behind once the pointer goes).
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { onSelection?() }
    }
    var onSelection: (() -> Void)?
    /// The selection last moved with the keyboard, not the mouse.
    private(set) var selectionFromKeyboard = false
    override func keyDown(with event: NSEvent) {
        selectionFromKeyboard = true
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        defer { onSelection?() }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        selectionFromKeyboard = false
        defer { onSelection?() }
        return super.resignFirstResponder()
    }
    /// False while a card covers the conversation (`setClaimsPointer`): then no I-beam and no link hand, which would show over the card. The same
    /// where chrome floats over the text (`pointerHole()`): the arrow, and the text around it keeps its I-beam.
    var claimsPointer = true
    override func cursorUpdate(with event: NSEvent) {
        if pointerHeldBack(at: event) { NSCursor.arrow.set() } else { super.cursorUpdate(with: event) }
    }
    override func mouseMoved(with event: NSEvent) {
        if pointerHeldBack(at: event) { NSCursor.arrow.set() } else { super.mouseMoved(with: event) }
        onPointer?(true)
    }
    override func mouseDown(with event: NSEvent) {
        selectionFromKeyboard = false
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

    /// The copy buttons over the text (`MirrorCopyControls`): the SwiftUI side that draws them hands its model over, and hears here which
    /// buttons show and where; a click comes back to `copy(_:)`.
    var copyModel: MirrorCopyModel? {
        didSet { copyModel?.perform = { [weak self] target in self?.copy(target) ?? false } }
    }
    /// The text is Claude's record (its replies are the Markdown Claude wrote), not its screen (`MirrorReplies.markdown`).
    var fromRecord = true
    /// The first text shown opens at its top, not at its end (a document to read rather than a conversation that grows).
    var opensAtTop = false
    /// The pointer is over the text; when the text last scrolled under it, and the look that brings the buttons back once it stops.
    private var pointerInside = false
    private var copyScrolledAt: CFTimeInterval = 0
    private var copySettle: DispatchWorkItem?
    /// Claude's transcript is on show: only its replies and blocks have copy buttons.
    private var showsTranscript: Bool { theme?.transcript == true }

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
        // Every scroll, the reader's or the mirror's own, may take the reader away from the end of the text or back to it (`noteDistanceToEnd`).
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        textView.onPointer = { [weak self] inside in self?.pointerMoved(inside: inside) }
        textView.onSelection = { [weak self] in self?.refreshCopyTargets() }
        textView.copyActions = { [weak self] in self?.copyAccessibilityActions() ?? [] }
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
        lineHeight = Self.lineHeight(of: font)
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
        // A reader on the way to the end (`jumpToEnd`) asked for the end, and finds it there on coming back.
        savedPositions[contentID] = isFollowingOutput || glide != nil ? .end : .offset(contentView.bounds.origin.y)
        stopGlide()
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
        // A document opens at its top, whatever an earlier pass asked for.
        let followOutput = previous.length == 0 && opensAtTop ? false : restore.map { $0 == .end } ?? pendingFollowOutput ?? (previous.length == 0 || isFollowingOutput)
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
        // A glide to the end (`jumpToEnd`) holds the reader where it last put them and takes them to the end itself, where the text has grown to by then.
        glide == nil && documentVisibleRect.maxY >= textView.bounds.maxY - 24
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
        // Text that arrived below a reader who stays where they are takes the end further away from them, with no scroll to say so.
        noteDistanceToEnd()
        // The text under the copy buttons may have moved or gone.
        refreshCopyTargets()
    }

    // MARK: The way back to the end

    /// How the mirror gets to the end of its text when the reader asks for it (`jumpToEnd`): it glides there; it cross-fades to it where Reduce
    /// Motion asks for less movement; it is there at once with the app's animations off.
    enum JumpMotion { case glide, fade, cut }

    /// The reader is far enough up from the end of the text for the way back to it to show (`JumpToLatest`). `onAwayFromEndChange` hears each change.
    private(set) var awayFromEnd = false
    var onAwayFromEndChange: ((Bool) -> Void)?
    /// The glide `jumpToEnd` started, while it plays; the display link that plays it; and where the glide last left the reader, which tells a scroll
    /// of the reader's own (it moves them from there) from the glide's.
    private(set) var glide: MirrorGlide?
    private var glideLink: CADisplayLink?
    private var glideOffset: CGFloat = 0
    /// One line of the mirror's font, which the button's thresholds are counted in.
    private var lineHeight = LiveTerminalScrollView.lineHeight(of: LiveTerminalScrollView.baseFont)
    static let jumpFadeDuration: CFTimeInterval = 0.2
    /// The key the cross-fade is found under: Core Animation keeps a transition under its own key, whatever it is added with.
    static let jumpFadeKey = kCATransition

    static func lineHeight(of font: NSFont) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: font)) }

    /// How far the end of the text is below what shows: in points, and in lines of the mirror's font.
    var distanceToEnd: CGFloat { max(0, textView.bounds.maxY - documentVisibleRect.maxY) }
    var linesToEnd: CGFloat { distanceToEnd / max(1, lineHeight) }

    /// The offset that shows the end of the text.
    private var endOffset: CGFloat { max(0, textView.frame.height - contentSize.height) }

    @objc private func clipViewScrolled(_ note: Notification) {
        noteDistanceToEnd()
        scrolledUnderCopyButtons()
    }

    /// Says again whether the reader is away from the end. A reader a glide is taking there is on the way back, not away.
    private func noteDistanceToEnd() {
        let away = glide == nil && JumpToLatest.shows(linesAway: linesToEnd, showing: awayFromEnd)
        guard away != awayFromEnd else { return }
        awayFromEnd = away
        onAwayFromEndChange?(away)
    }

    /// Takes the reader to the end of the text, the latest message sent or received, from where the mirror follows the output again. The button
    /// goes at once (the reader is on the way back). A glide reads where the end is on every frame, so text that arrives while it plays is
    /// reached too; a scroll of the reader's own stops it where it is.
    func jumpToEnd(_ motion: JumpMotion, now: CFTimeInterval = CACurrentMediaTime()) {
        stopGlide()
        let start = contentView.bounds.origin.y, end = endOffset
        guard end - start > 0.5 else { noteDistanceToEnd(); return }
        switch motion {
        case .cut:
            scroll(toOffset: end)
        case .fade:
            // The text does not travel: what shows now fades into its end.
            if let layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Self.jumpFadeDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: Self.jumpFadeKey)
            }
            scroll(toOffset: end)
        case .glide:
            let planned = MirrorGlide.plan(from: start, end: end, viewport: contentSize.height, at: now)
            glide = planned
            glideOffset = start
            noteDistanceToEnd()
            // A reader far up starts a few screens above the end (`MirrorGlide.maxScreens`); the first frame of the glide is as quick as that.
            if planned.from > start { moveGlide(to: planned.from) }
            startGlideLink()
            // The display link plays it while the island is on screen. Should it not tick (the window went away meanwhile), the glide still
            // ends where it was going.
            DispatchQueue.main.asyncAfter(deadline: .now() + planned.duration + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.glide == planned else { return }
                    self.stepGlide(at: planned.start + planned.duration + 1)
                }
            }
        }
    }

    /// One frame of the glide, at `now`: true while it goes on. A reader who scrolled meanwhile has taken over, and it stops where they are.
    @discardableResult func stepGlide(at now: CFTimeInterval) -> Bool {
        guard let glide else { return false }
        guard abs(contentView.bounds.origin.y - glideOffset) < 1 else {
            stopGlide()
            noteDistanceToEnd()
            return false
        }
        let (y, done) = glide.offset(at: now, end: endOffset)
        if done { stopGlide() }
        moveGlide(to: y)
        return !done
    }

    private func moveGlide(to y: CGFloat) {
        scroll(toOffset: y)
        glideOffset = contentView.bounds.origin.y
    }

    private func startGlideLink() {
        guard glideLink == nil else { return }
        let link = displayLink(target: GlideLinkTarget(self), selector: #selector(GlideLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func stopGlide() {
        glide = nil
        glideLink?.invalidate()
        glideLink = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Taken out of its window mid-glide: the reader is at the end when it is back.
        if window == nil, glide != nil {
            stopGlide()
            scroll(toOffset: endOffset)
        }
    }

    /// The display link retains its target; a weak hop keeps it from keeping the mirror alive. Each frame is computed for the moment it will
    /// be seen.
    private final class GlideLinkTarget: NSObject {
        weak var mirror: LiveTerminalScrollView?
        init(_ mirror: LiveTerminalScrollView) { self.mirror = mirror }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                // The run loop keeps the link: one whose mirror has gone would tick for nothing.
                guard let mirror else { return link.invalidate() }
                let now = CACurrentMediaTime()
                mirror.stepGlide(at: now + max(0, min(0.1, link.targetTimestamp - now)))
            }
        }
    }
}

// MARK: - Copy buttons

extension LiveTerminalScrollView {
    /// The pointer came onto the text, moved over it, or left it.
    fileprivate func pointerMoved(inside: Bool) {
        pointerInside = inside
        refreshCopyTargets()
    }

    /// A scroll moves the text under the buttons: they go at once, and come back where the pointer rests once the text stops.
    fileprivate func scrolledUnderCopyButtons() {
        guard let copyModel else { return }
        copyScrolledAt = CACurrentMediaTime()
        copyModel.show(reply: nil, code: nil)
        copySettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            self?.copySettle = nil
            self?.refreshCopyTargets()
        }
        copySettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
    }

    /// The character the buttons are for: the one under the pointer while it is over the text's lines, else the caret's while the
    /// text has the keyboard. Nil over the margins below the text, or with neither.
    private func copyFocus() -> Int? {
        guard let storage = textView.textStorage, storage.length > 0, let manager = textView.layoutManager, let container = textView.textContainer else { return nil }
        if pointerInside, let window = textView.window {
            let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard textView.visibleRect.contains(point) else { return nil }
            let origin = textView.textContainerOrigin
            let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            guard local.y >= 0, local.y <= manager.usedRect(for: container).maxY else { return nil }
            let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
            return manager.characterIndexForGlyph(at: glyph)
        }
        guard textView.window?.firstResponder === textView, textView.selectionFromKeyboard else { return nil }
        let caret = textView.selectedRange().location
        return caret < storage.length ? caret : nil
    }

    /// Works out which buttons show and where, and publishes them (`MirrorCopyModel`): Claude's transcript only, and none while the
    /// text is scrolling.
    func refreshCopyTargets() {
        guard let copyModel else { return }
        // While the text moves the buttons stay away; the scroll's own look brings them back (`scrolledUnderCopyButtons`).
        guard showsTranscript, copySettle == nil, CACurrentMediaTime() - copyScrolledAt > 0.1, let index = copyFocus(),
              let storage = textView.textStorage, let manager = textView.layoutManager as? MirrorLayoutManager, let container = textView.textContainer else {
            copyModel.show(reply: nil, code: nil)
            return
        }
        let text = storage.mutableString as NSString
        let origin = textView.textContainerOrigin
        var reply: MirrorCopyModel.Target?
        if let range = MirrorReplies.reply(containing: index, in: text), range.length > 0 {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let first = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let size = MirrorCopyControls.replySize
            let right = origin.x + container.size.width - container.lineFragmentPadding
            // Beside the reply's first line, in the room it keeps (`TranscriptStyler.replyButtonRoom`); for a long reply whose start has
            // gone up out of sight, at the top of what shows of it, never past its end.
            let beside = origin.y + first.midY - size / 2
            let top = max(beside, textView.visibleRect.minY + 4)
            let y = min(top, max(beside, origin.y + last.maxY - size))
            reply = MirrorCopyModel.Target(kind: .reply, id: range.location, frame: overlayFrame(NSRect(x: right - size + 2, y: y.rounded(), width: size, height: size)))
        }
        var code: MirrorCopyModel.Target?
        var run = NSRange(location: 0, length: 0)
        if let block = storage.attribute(.transcriptCodeBlock, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptCodeBlock,
           let tile = manager.codeBlockFrame(block, characters: run) {
            let button = MirrorLayoutManager.codeBlockButton(in: tile.offsetBy(dx: origin.x, dy: origin.y), lineHeight: block.lineHeight)
            code = MirrorCopyModel.Target(kind: .code, id: block.id, frame: overlayFrame(button))
        }
        var quote: MirrorCopyModel.Target?
        if let found = storage.attribute(.transcriptQuoteBlock, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptQuoteBlock,
           let button = manager.quoteButton(found, characters: run) {
            quote = MirrorCopyModel.Target(kind: .quote, id: found.id, frame: overlayFrame(button.offsetBy(dx: origin.x, dy: origin.y)))
        }
        // A quote right under the reply's first line (after one blank line) would have its button touch the reply's: each gives way half.
        if var above = reply, var below = quote, above.frame.minX < below.frame.maxX, below.frame.minX < above.frame.maxX {
            let overlap = above.frame.maxY + 1 - below.frame.minY
            if overlap > 0, overlap < below.frame.height {
                above.frame.origin.y -= ceil(overlap / 2)
                below.frame.origin.y += ceil(overlap / 2)
                reply = above
                quote = below
            }
        }
        copyModel.show(reply: reply, code: code, quote: quote)
    }

    /// A rect of the text view in the mirror's own space, from its top left (SwiftUI's).
    private func overlayFrame(_ rect: NSRect) -> CGRect {
        let inScroll = convert(rect, from: textView)
        return CGRect(x: inScroll.minX, y: isFlipped ? inScroll.minY : bounds.height - inScroll.maxY, width: inScroll.width, height: inScroll.height)
    }

    /// What a button copies, onto the pasteboard. False when the text under it no longer holds it.
    func copy(_ target: MirrorCopyModel.Target) -> Bool {
        guard let text = copyText(for: target) else { return false }
        textView.pasteboard.clearContents()
        textView.pasteboard.setString(text, forType: .string)
        textView.onCopy?()
        return true
    }

    /// A reply's Markdown, a block's code, or a quote's Markdown (`MirrorReplies`, `TranscriptCodeBlocks.copyText`, `TranscriptQuotes.copyText`).
    func copyText(for target: MirrorCopyModel.Target) -> String? {
        guard let storage = textView.textStorage, target.id < storage.length else { return nil }
        let text = storage.mutableString as NSString
        switch target.kind {
        case .reply:
            guard let range = MirrorReplies.reply(containing: target.id, in: text), range.location == target.id else { return nil }
            let markdown = MirrorReplies.markdown(text.substring(with: range), fromRecord: fromRecord)
            return markdown.isEmpty ? nil : markdown
        case .code:
            var run = NSRange(location: 0, length: 0)
            guard let block = storage.attribute(.transcriptCodeBlock, at: target.id, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptCodeBlock,
                  block.id == target.id else { return nil }
            let code = TranscriptCodeBlocks.copyText(text.substring(with: run).components(separatedBy: "\n"))
            return code.isEmpty ? nil : code
        case .quote:
            var run = NSRange(location: 0, length: 0)
            guard let quote = storage.attribute(.transcriptQuoteBlock, at: target.id, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptQuoteBlock,
                  quote.id == target.id else { return nil }
            let quoted = TranscriptQuotes.copyText(text.substring(with: run).components(separatedBy: "\n"), fromRecord: fromRecord)
            return quoted.isEmpty ? nil : quoted
        }
    }

    /// For VoiceOver, on the text: the reply, the block and the quote the caret is in, and the latest of each.
    fileprivate func copyAccessibilityActions() -> [NSAccessibilityCustomAction] {
        guard showsTranscript, let storage = textView.textStorage, storage.length > 0 else { return [] }
        let text = storage.mutableString as NSString
        var actions: [NSAccessibilityCustomAction] = []
        func action(_ name: String, _ target: MirrorCopyModel.Target?) {
            guard let target, copyText(for: target) != nil else { return }
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in self?.copy(target) ?? false })
        }
        let caret = textView.selectedRange().location
        if caret < storage.length, let here = MirrorReplies.reply(containing: caret, in: text) {
            action("Copiar esta respuesta de Claude", MirrorCopyModel.Target(kind: .reply, id: here.location, frame: .zero))
        }
        if caret < storage.length, let block = storage.attribute(.transcriptCodeBlock, at: caret, effectiveRange: nil) as? TranscriptCodeBlock {
            action("Copiar este bloque de código", MirrorCopyModel.Target(kind: .code, id: block.id, frame: .zero))
        }
        if caret < storage.length, let quote = storage.attribute(.transcriptQuoteBlock, at: caret, effectiveRange: nil) as? TranscriptQuoteBlock {
            action("Copiar esta cita", MirrorCopyModel.Target(kind: .quote, id: quote.id, frame: .zero))
        }
        if let last = MirrorReplies.last(in: text) { action("Copiar la última respuesta de Claude", MirrorCopyModel.Target(kind: .reply, id: last.location, frame: .zero)) }
        var lastBlock: TranscriptCodeBlock?
        storage.enumerateAttribute(.transcriptCodeBlock, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, _, stop in
            if let block = value as? TranscriptCodeBlock { lastBlock = block; stop.pointee = true }
        }
        if let lastBlock { action("Copiar el último bloque de código", MirrorCopyModel.Target(kind: .code, id: lastBlock.id, frame: .zero)) }
        var lastQuote: TranscriptQuoteBlock?
        storage.enumerateAttribute(.transcriptQuoteBlock, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, _, stop in
            if let quote = value as? TranscriptQuoteBlock { lastQuote = quote; stop.pointee = true }
        }
        if let lastQuote { action("Copiar la última cita", MirrorCopyModel.Target(kind: .quote, id: lastQuote.id, frame: .zero)) }
        return actions
    }
}
