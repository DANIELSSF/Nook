import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The composer's message field: text that wraps and grows line by line up to the number the user chose, then scrolls
// inside itself. SwiftUI's own text field is one line (its multi-line variant has no way to tell the caret's line, and it
// sends on ⇧↵), so the field is an NSTextView that lives in a small scroll view:
//
//   ComposerKey        the keys the pane gets to answer before the text view does (pure; `classify` is tested)
//   ComposerTextView   the text view: key handling, placeholder, caret line, no automatic text rewriting
//   ComposerScrollView the scroll view around it
//   ComposerFieldView  the view SwiftUI holds: the scroll view with the field's vertical padding outside it, so a line that
//                      does not fit never peeks through the padding
//   ComposerMeasure    how many lines a text takes at a width (for the field's height before it is laid out)
//   ComposerField      the SwiftUI side: the binding, the focus request, the height
//
// What the keys do (the pane decides, see `SessionPane.composerKey`):
//   ↵                  sends at once (the field clears)        ⇧↵ ⌥↵ ⌃↵   a line break
//   ↑ ↓                the "/" menu's rows while it shows; otherwise the caret walks the lines of the draft and only
//                      on the first / last line does the key recall the sent messages (like Claude's own box)
//   ⇥  ⎋               the menu's keys; ⎋ with no menu goes on to collapse the island; ⇥ never types a tab. On an empty
//                      field ⇥ (and →) take Claude's grey suggestion, as in Claude's own box
//   ⌃V                 pastes the clipboard's image into the agent; ⌘V does too when the clipboard holds an image and no text

/// A key the pane is asked about before the text view acts on it.
enum ComposerKey: Equatable {
    case submit, newline, up, down, right, tab, escape, pasteImage

    /// What a key stands for in the composer, or nil when it is an ordinary key for the text view (letters, ←, →,
    /// ⇧↑ to extend a selection, ⌘C…). `characters` are the key's characters ignoring modifiers.
    static func classify(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> ComposerKey? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch keyCode {
        case 36, 76:   // Return and the keypad's Enter
            return flags.isDisjoint(with: [.shift, .option, .control]) ? .submit : .newline
        case 126: return flags.isEmpty ? .up : nil
        case 125: return flags.isEmpty ? .down : nil
        case 124: return flags.isEmpty ? .right : nil
        case 48: return flags.isEmpty ? .tab : nil
        case 53: return flags.isEmpty ? .escape : nil
        default:
            if characters?.lowercased() == "v", flags.contains(.control), !flags.contains(.command) { return .pasteImage }
            return nil
        }
    }
}

/// What ⌘V should paste. Text wins: a clipboard with a string (or a file, whose path is text) pastes as it always did, even
/// when it also carries an image (a copied web page often does). Only an image with no text is the image paste, the same
/// one ⌃V does, because users press ⌘V by habit.
enum ClipboardPaste: Equatable {
    case text, image

    static func kind(types: [NSPasteboard.PasteboardType]) -> ClipboardPaste {
        func conforms(_ type: NSPasteboard.PasteboardType, to parent: UTType) -> Bool { UTType(type.rawValue)?.conforms(to: parent) == true }
        // A string, or a file or link (their paths and addresses are text): the ordinary paste.
        if types.contains(where: { $0 == .string || $0 == .fileURL || $0 == .URL || conforms($0, to: .plainText) }) { return .text }
        return types.contains { conforms($0, to: .image) } ? .image : .text
    }

    static func kind(of pasteboard: NSPasteboard) -> ClipboardPaste { kind(types: pasteboard.types ?? []) }
}

/// Which visual line of the draft the caret is on, as far as the arrows are concerned.
struct ComposerCaret: Equatable {
    var onFirstLine = true
    var onLastLine = true
}

// MARK: - Text view

final class ComposerTextView: NSTextView {
    /// The keys the pane answers; returns whether it took the key.
    var onKey: ((ComposerKey, ComposerCaret) -> Bool)?
    /// What ⌘V reads to choose between text and an image.
    var pasteboard = NSPasteboard.general
    /// The grey text shown while the field is empty (Claude's suggestion, or what to write).
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    /// Set for a field made with text in it: the first time it has a size it scrolls to the caret.
    var scrollsToCaretWhenSized = false
    /// The field's text size and the lines it grows to before it scrolls (set by the representable).
    private(set) var fontSize = DisplaySettings.defaultInputSize
    var maxLines = DisplaySettings.defaultLines

    /// A text view on its own TextKit 1 stack, which is what tells the caret's line and the lines' heights exactly.
    static func make() -> ComposerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.configure()
        return view
    }

    static func attributes(size: Double) -> [NSAttributedString.Key: Any] {
        let height = ComposerMetrics.lineHeight(size: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        return [.font: DisplaySettings.inputFont(size: size), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }
    var attributes: [NSAttributedString.Key: Any] { Self.attributes(size: fontSize) }

    private func configure() {
        // A message is plain text: nothing is rewritten (smart quotes would corrupt a command), nothing is rich, nothing is checked.
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        usesFindBar = false
        if #available(macOS 15.0, *) { writingToolsBehavior = .none }
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // The field's vertical padding is outside its scroll view (`ComposerFieldView`), so no inset here.
        textContainerInset = .zero
        insertionPointColor = .white
        // The island is dark in every system appearance.
        appearance = NSAppearance(named: .darkAqua)
        applyStyle(size: fontSize)
    }

    /// Sets the text size: the font, the line height and the attributes new text takes. Text already there is restyled.
    func applyStyle(size: Double) {
        fontSize = size
        let attributes = Self.attributes(size: size)
        typingAttributes = attributes
        defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        font = attributes[.font] as? NSFont
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        needsDisplay = true
    }

    // MARK: Lines

    /// The visual lines of the text as laid out now (a wrapped line counts as many), and the empty one after a final newline.
    private func lineRanges() -> [NSRange] {
        guard let layout = layoutManager, let container = textContainer else { return [NSRange(location: 0, length: 0)] }
        layout.ensureLayout(for: container)
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
            ranges.append(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        if layout.extraLineFragmentRect.height > 0 || ranges.isEmpty { ranges.append(NSRange(location: (string as NSString).length, length: 0)) }
        return ranges
    }

    var lineCount: Int { lineRanges().count }

    /// The line the caret is on. At the seam between two wrapped lines the caret is on the second, as it is drawn.
    var caret: ComposerCaret {
        let ranges = lineRanges()
        let selection = selectedRange()
        func line(at index: Int) -> Int { ranges.lastIndex { $0.location <= index } ?? 0 }
        return ComposerCaret(onFirstLine: line(at: selection.location) == 0, onLastLine: line(at: NSMaxRange(selection)) == ranges.count - 1)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // An input method with a composition under way (accents, Japanese…) gets every key first: ↵ confirms it.
        if hasMarkedText() { super.keyDown(with: event); return }
        guard let key = ComposerKey.classify(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else {
            super.keyDown(with: event); return
        }
        switch key {
        case .newline:
            insertNewlineIgnoringFieldEditor(nil)
        case .submit:
            // A key held down must not send again (the field is already empty, and Enter on an empty field takes the suggestion).
            if !event.isARepeat { _ = onKey?(.submit, caret) }
        case .tab:
            // Never types a tab into a message: the menu takes it, otherwise it does nothing.
            _ = onKey?(.tab, caret)
        case .pasteImage:
            if onKey?(.pasteImage, caret) != true { super.keyDown(with: event) }
        case .up, .down, .right, .escape:
            // Not taken: the caret walks the draft (↑ ↓ →), or the key goes on up the responder chain (⎋ collapses the island).
            if onKey?(key, caret) != true { super.keyDown(with: event) }
        }
    }

    /// ⌘V (and Paste in the menus): text pastes as always; an image with no text goes to the pane as the image paste.
    override func paste(_ sender: Any?) {
        if ClipboardPaste.kind(of: pasteboard) == .image, onKey?(.pasteImage, caret) == true { return }
        super.paste(sender)
    }

    override func insertTab(_ sender: Any?) {}
    override func insertBacktab(_ sender: Any?) {}

    // MARK: Scrolling

    /// While the text fits the lines the field grows to, it never scrolls: the field grows instead. Past that, the caret
    /// is kept in view as in any text view.
    override func scrollRangeToVisible(_ range: NSRange) {
        if lineCount <= maxLines { enclosingScrollView?.contentView.scroll(to: .zero); enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView); return }
        super.scrollRangeToVisible(range)
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, !hasMarkedText() else { return }
        var attributes = self.attributes
        attributes[.foregroundColor] = NSColor.placeholderTextColor
        if let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        let area = NSRect(x: 0, y: 0, width: max(0, bounds.width), height: ComposerMetrics.lineHeight(size: fontSize))
        (placeholder as NSString).draw(with: area, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

// MARK: - Measuring

/// How many lines a text takes at a width, laid out as the field lays it out (same font, same line height, no padding).
/// The field's height has to be known before its view is, so SwiftUI asks this instead of the view. The last answer is
/// kept: the same text is asked about at every redraw.
@MainActor
enum ComposerMeasure {
    private static let storage = NSTextStorage()
    private static let layout = NSLayoutManager()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return container
    }()
    private static var last: (text: String, width: CGFloat, size: Double, lines: Int)?

    static func lines(of text: String, width: CGFloat, size: Double) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        if let last, last.text == text, last.width == width, last.size == size { return last.lines }
        storage.setAttributedString(NSAttributedString(string: text, attributes: ComposerTextView.attributes(size: size)))
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in count += 1 }
        if layout.extraLineFragmentRect.height > 0 { count += 1 }
        count = max(1, count)
        last = (text, width, size, count)
        return count
    }
}

// MARK: - Scroll view

final class ComposerScrollView: NSScrollView {
    let textView = ComposerTextView.make()

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        contentView.drawsBackground = false
        appearance = NSAppearance(named: .darkAqua)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentView = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The text view fills the field even when its text is shorter, so a click anywhere in it lands in the text.
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        if textView.scrollsToCaretWhenSized, contentSize.width > 0, contentSize.height > 0 {
            textView.scrollsToCaretWhenSized = false
            // After this layout pass: the text view has taken the width by then.
            DispatchQueue.main.async { [weak textView] in textView.map { $0.scrollRangeToVisible($0.selectedRange()) } }
        }
    }
}

// MARK: - Field view

/// What SwiftUI holds: the scroll view, inset from the top and the bottom by the field's padding. The padding is outside
/// the scroll view on purpose: inside it, the part of a fourth line that does not fit would show through the padding.
final class ComposerFieldView: NSView {
    let scroll = ComposerScrollView()
    var textView: ComposerTextView { scroll.textView }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: ComposerMetrics.verticalInset)
    }
}

// MARK: - SwiftUI

struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: Double
    /// The lines the field shows before it scrolls.
    var maxLines: Int
    /// Whenever this changes the field takes the keyboard.
    var focusRequest: Int
    var accessibilityLabel = "Mensaje"
    var accessibilityHint = ""
    /// The pane's answer to a key (`ComposerKey`); true means it took it.
    var onKey: (ComposerKey, ComposerCaret) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerFieldView {
        let field = ComposerFieldView()
        let view = field.textView
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.focusRequest = focusRequest
        view.applyStyle(size: fontSize)
        view.maxLines = max(1, maxLines)
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        // A draft that comes back with its tab (or a longer one than the field shows) is shown from where the caret is,
        // once the field has its size.
        view.scrollsToCaretWhenSized = !text.isEmpty
        return field
    }

    func updateNSView(_ field: ComposerFieldView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let view = field.textView
        if view.fontSize != fontSize { view.applyStyle(size: fontSize) }
        let cap = max(1, maxLines)
        if view.maxLines != cap { view.maxLines = cap; coordinator.settleScroll() }
        view.placeholder = placeholder
        view.setAccessibilityLabel(accessibilityLabel)
        view.setAccessibilityHelp(accessibilityHint)
        view.onKey = { [weak coordinator] key, caret in coordinator?.parent.onKey(key, caret) ?? false }
        if view.string != text { coordinator.replaceText(with: text) }
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerFieldView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let lines = min(max(1, ComposerMeasure.lines(of: text, width: width, size: fontSize)), max(1, maxLines))
        return CGSize(width: width, height: ComposerMetrics.fieldHeight(lines: lines, size: fontSize))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var view: ComposerTextView?
        var focusRequest = 0
        private var replacing = false

        init(_ parent: ComposerField) { self.parent = parent }

        /// What the user typed, pasted, dropped, undid or dictated reaches the draft. A field that gains or loses a line grows
        /// or shrinks with a short animation.
        func textDidChange(_ notification: Notification) {
            guard !replacing, let view else { return }
            let text = view.string
            settleScroll()
            let before = parent.text, width = view.bounds.width
            let size = parent.fontSize, cap = max(1, parent.maxLines)
            let grew = min(ComposerMeasure.lines(of: before, width: width, size: size), cap) != min(ComposerMeasure.lines(of: text, width: width, size: size), cap)
            if grew, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                withAnimation(.easeOut(duration: 0.12)) { parent.text = text }
            } else {
                parent.text = text
            }
        }

        /// The draft changed from outside the field (a sent message clearing it, a recalled one, a completion, a dictation, an
        /// attached path): the field shows it with the caret at its end. An empty field forgets what was typed before.
        func replaceText(with text: String) {
            guard let view else { return }
            replacing = true
            defer { replacing = false }
            let whole = NSRange(location: 0, length: (view.string as NSString).length)
            if view.shouldChangeText(in: whole, replacementString: text) {
                view.textStorage?.replaceCharacters(in: whole, with: NSAttributedString(string: text, attributes: view.attributes))
                view.didChangeText()
            }
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            if text.isEmpty { view.undoManager?.removeAllActions(withTarget: view) }
            settleScroll()
        }

        /// Back to the top while everything fits (the field grew to hold it), at the caret otherwise.
        func settleScroll() {
            guard let view else { return }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}
