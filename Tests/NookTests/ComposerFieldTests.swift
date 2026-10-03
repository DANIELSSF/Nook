import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The key classification, and the multi-line field driven by real AppKit key events in an offscreen window. Nothing here
/// starts the app or touches Terminal.
final class ComposerKeyTests: XCTestCase {
    private func key(_ code: UInt16, _ chars: String? = nil, _ flags: NSEvent.ModifierFlags = []) -> ComposerKey? {
        ComposerKey.classify(keyCode: code, characters: chars, modifiers: flags)
    }

    func testEnterSendsAndShiftOptionOrControlEnterAddALine() {
        XCTAssertEqual(key(36), .submit)
        XCTAssertEqual(key(76), .submit, "The keypad's Enter sends too.")
        XCTAssertEqual(key(36, nil, .command), .submit, "⌘↵ is a send as well.")
        XCTAssertEqual(key(36, nil, .shift), .newline)
        XCTAssertEqual(key(36, nil, .option), .newline)
        XCTAssertEqual(key(36, nil, .control), .newline)
        XCTAssertEqual(key(36, nil, [.shift, .option]), .newline)
        XCTAssertEqual(key(76, nil, .shift), .newline)
        XCTAssertEqual(key(36, nil, [.capsLock]), .submit, "Caps Lock changes nothing.")
    }

    func testArrowsTabAndEscapeAreTheFieldsOnlyWithoutModifiers() {
        XCTAssertEqual(key(126, nil, [.function, .numericPad]), .up, "The arrows report the function and keypad flags; they do not count.")
        XCTAssertEqual(key(125, nil, [.function, .numericPad]), .down)
        XCTAssertNil(key(126, nil, [.shift, .function, .numericPad]), "⇧↑ extends the selection: the text view's.")
        XCTAssertNil(key(125, nil, [.option, .function, .numericPad]), "⌥↓ moves by paragraph: the text view's.")
        XCTAssertNil(key(126, nil, [.command, .function, .numericPad]))
        XCTAssertEqual(key(124, nil, [.function, .numericPad]), .right, "→ is asked about too: it takes Claude's suggestion from an empty field.")
        XCTAssertNil(key(124, nil, [.option, .function, .numericPad]), "⌥→ moves by word: the text view's.")
        XCTAssertNil(key(124, nil, [.shift, .function, .numericPad]))
        XCTAssertEqual(key(48), .tab)
        XCTAssertNil(key(48, nil, .shift), "⇧⇥ is not completion.")
        XCTAssertEqual(key(53), .escape)
        XCTAssertNil(key(53, nil, .command))
    }

    func testControlVPastesTheImageAndNothingElseDoes() {
        XCTAssertEqual(key(9, "v", .control), .pasteImage)
        XCTAssertEqual(key(9, "V", [.control, .shift]), .pasteImage)
        XCTAssertNil(key(9, "v"), "A plain v is a letter.")
        XCTAssertNil(key(9, "v", .command), "⌘V is the system's paste.")
        XCTAssertNil(key(9, "v", [.control, .command]))
        XCTAssertNil(key(0, "a", .control))
    }

    func testCommandVRoutingFollowsWhatTheClipboardHolds() {
        func kind(_ types: [NSPasteboard.PasteboardType]) -> ClipboardPaste { ClipboardPaste.kind(types: types) }
        let jpeg = NSPasteboard.PasteboardType("public.jpeg")
        XCTAssertEqual(kind([.png]), .image, "An image alone: the image paste.")
        XCTAssertEqual(kind([.tiff]), .image)
        XCTAssertEqual(kind([jpeg]), .image)
        XCTAssertEqual(kind([.tiff, .png]), .image, "A screenshot or a copied image carries several formats.")
        XCTAssertEqual(kind([.string]), .text)
        XCTAssertEqual(kind([NSPasteboard.PasteboardType("public.utf8-plain-text")]), .text)
        XCTAssertEqual(kind([.string, .png]), .text, "Text wins: a clipboard with a string pastes as it always did.")
        XCTAssertEqual(kind([.tiff, NSPasteboard.PasteboardType("public.utf8-plain-text")]), .text)
        XCTAssertEqual(kind([.fileURL, .png]), .text, "A file copied in Finder carries its icon as an image; its path is the text.")
        XCTAssertEqual(kind([.URL, .tiff]), .text)
        XCTAssertEqual(kind([.html, .png]), .image, "A web image with HTML and no string is still an image.")
        XCTAssertEqual(kind([]), .text, "An empty clipboard is the ordinary paste (which does nothing).")
        XCTAssertEqual(kind([.rtf]), .text)
        XCTAssertEqual(kind([NSPasteboard.PasteboardType("com.example.unknown")]), .text)
    }

    func testTheChatSizeShortcuts() {
        func shortcut(_ chars: String, _ flags: NSEvent.ModifierFlags) -> ChatSizeShortcut? { ChatSizeShortcut(characters: chars, modifiers: flags) }
        XCTAssertEqual(shortcut("+", [.command, .shift]), .larger, "⌘+ on a US layout is ⌘⇧=.")
        XCTAssertEqual(shortcut("=", .command), .larger, "⌘= works too.")
        XCTAssertEqual(shortcut("+", [.command, .numericPad]), .larger, "The keypad's +.")
        XCTAssertEqual(shortcut("-", .command), .smaller)
        XCTAssertEqual(shortcut("-", [.command, .numericPad]), .smaller)
        XCTAssertEqual(shortcut("0", .command), .reset)
        XCTAssertNil(shortcut("0", [.command, .shift]))
        XCTAssertNil(shortcut("+", .shift), "Without ⌘ it is a character.")
        XCTAssertNil(shortcut("-", [.command, .option]))
        XCTAssertNil(shortcut("-", [.command, .control]))
        XCTAssertNil(shortcut("a", .command))
    }
}

@MainActor
final class ComposerFieldTests: XCTestCase {
    final class Box: ObservableObject {
        @Published var text = ""
        var keys: [ComposerKey] = []
        var carets: [ComposerCaret] = []
        /// What the field's owner answers for each key; true means it took it.
        var takes: Set<ComposerKey> = [.submit, .pasteImage]
        var escapes = 0
    }

    private struct Host: View {
        @ObservedObject var box: Box
        var lines = 3
        var size = 13.0
        var placeholder = "Mensaje"
        var body: some View {
            ComposerField(text: $box.text, placeholder: placeholder, fontSize: size, maxLines: lines, focusRequest: 0,
                          onKey: { key, caret in box.keys.append(key); box.carets.append(caret); return box.takes.contains(key) })
                .frame(width: 400).padding(10)
                .onExitCommand { box.escapes += 1 }
        }
    }

    private final class Rig {
        let box = Box()
        let window: NSWindow
        let host: NSHostingView<Host>
        let field: ComposerTextView
        let fieldView: ComposerFieldView
        var scroll: ComposerScrollView { fieldView.scroll }

        init(lines: Int = 3, size: Double = 13, placeholder: String = "Mensaje", text: String = "") throws {
            box.text = text
            host = NSHostingView(rootView: Host(box: box, lines: lines, size: size, placeholder: placeholder))
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 420, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            Self.settle(0.4)
            fieldView = try XCTUnwrap(Self.find(ComposerFieldView.self, in: host))
            field = fieldView.textView
            window.makeFirstResponder(field)
            Self.settle(0.1)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        static func settle(_ seconds: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        func type(_ text: String) {
            field.insertText(text, replacementRange: field.selectedRange())
            Self.settle()
        }

        enum Key {
            case enter, keypadEnter, up, down, tab, escape, v, left, right
            var code: UInt16 { switch self { case .enter: 36; case .keypadEnter: 76; case .up: 126; case .down: 125; case .tab: 48; case .escape: 53; case .v: 9; case .left: 123; case .right: 124 } }
            var characters: String { switch self { case .enter, .keypadEnter: "\r"; case .up: "\u{F700}"; case .down: "\u{F701}"; case .tab: "\t"; case .escape: "\u{1b}"; case .v: "v"; case .left: "\u{F702}"; case .right: "\u{F703}" } }
        }

        func press(_ key: Key, _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) {
            var flags = flags
            if [.up, .down, .left, .right].contains(key) { flags.formUnion([.function, .numericPad]) }
            let chars = key == .v && flags.contains(.control) ? "\u{16}" : key.characters
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: key.characters == "v" ? "v" : key.characters, isARepeat: repeating, keyCode: key.code)!
                window.sendEvent(event)
            }
            Self.settle()
        }

        /// Where the caret is, as a line number counted from 0 among the text's own lines (split on newlines).
        var caretLine: Int {
            let before = (field.string as NSString).substring(to: field.selectedRange().location)
            return before.filter { $0 == "\n" }.count
        }
    }

    // MARK: Enter

    func testEnterAsksThePaneToSendAndNeverTypesANewline() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.enter)
        XCTAssertEqual(rig.box.keys, [.submit])
        XCTAssertEqual(rig.box.text, "hola", "The field itself does not clear: the pane does when it sends.")
        rig.press(.keypadEnter)
        XCTAssertEqual(rig.box.keys, [.submit, .submit])
        XCTAssertFalse(rig.field.string.contains("\n"))
    }

    func testShiftAndOptionEnterInsertALineBreakAtTheCaretAndSendNothing() throws {
        let rig = try Rig()
        rig.type("uno")
        rig.press(.enter, .shift)
        XCTAssertEqual(rig.box.text, "uno\n", "⇧↵ adds a line to the draft.")
        rig.type("dos")
        rig.press(.enter, .option)
        XCTAssertEqual(rig.box.text, "uno\ndos\n", "⌥↵ too.")
        rig.press(.enter, .control)
        XCTAssertEqual(rig.box.text, "uno\ndos\n\n", "⌃↵ too.")
        XCTAssertFalse(rig.box.keys.contains(.submit), "None of them sends.")
        // In the middle of the text the break goes where the caret is.
        rig.field.setSelectedRange(NSRange(location: 3, length: 0))
        rig.press(.enter, .shift)
        XCTAssertEqual(rig.box.text, "uno\n\ndos\n\n")
        XCTAssertEqual(rig.field.selectedRange().location, 4)
    }

    func testAKeyHeldDownSendsOnlyOnce() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.enter)
        rig.press(.enter, repeating: true)
        rig.press(.enter, repeating: true)
        XCTAssertEqual(rig.box.keys, [.submit], "Auto-repeat would send again from an empty field, and Enter on an empty field takes the suggestion.")
    }

    func testAnInputMethodsCompositionKeepsEnter() throws {
        let rig = try Rig()
        // The user is composing (an accent dead key, an IME candidate): the text is marked and Enter belongs to the method.
        rig.field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(rig.field.hasMarkedText())
        rig.press(.enter)
        XCTAssertEqual(rig.box.keys, [], "The pane never hears about it.")
    }

    // MARK: Other keys

    func testTabIsTheMenusAndNeverTypesATab() throws {
        let rig = try Rig()
        rig.type("hola")
        rig.press(.tab)
        XCTAssertEqual(rig.box.keys, [.tab])
        XCTAssertEqual(rig.box.text, "hola")
        rig.press(.tab, .shift)
        XCTAssertEqual(rig.box.text, "hola", "⇧⇥ does not type one either.")
        XCTAssertEqual(rig.box.keys, [.tab], "...and is not the menu's.")
    }

    func testCommandVWithAnImageAndNoTextIsTheImagePaste() throws {
        let rig = try Rig()
        let board = NSPasteboard(name: NSPasteboard.Name("nook-composer-paste-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemMint.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.clearContents(); board.writeObjects([image])
        rig.field.pasteboard = board
        XCTAssertEqual(ClipboardPaste.kind(of: board), .image)
        rig.field.paste(nil)
        XCTAssertEqual(rig.box.keys, [.pasteImage], "The field hands an image with no text to the pane, as ⌃V does.")
        XCTAssertEqual(rig.box.text, "")
        // With text on it as well, the ordinary paste takes it (checked by the decision: pasting would read the real clipboard).
        board.clearContents(); board.writeObjects([image]); board.setString("texto", forType: .string)
        XCTAssertEqual(ClipboardPaste.kind(of: board), .text)
    }

    func testControlVIsTheImagePasteAndTypesNothing() throws {
        let rig = try Rig()
        rig.press(.v, .control)
        XCTAssertEqual(rig.box.keys, [.pasteImage])
        XCTAssertEqual(rig.box.text, "")
    }

    func testEscapeReachesThePaneFirstAndGoesOnToTheIslandWhenItDoesNotTakeIt() throws {
        let rig = try Rig()
        rig.press(.escape)
        XCTAssertEqual(rig.box.keys, [.escape])
        XCTAssertEqual(rig.box.escapes, 1, "Not taken: Esc goes up to the island, which collapses.")
        rig.box.takes.insert(.escape)
        rig.press(.escape)
        XCTAssertEqual(rig.box.escapes, 1, "Taken (the menu closes): the island stays.")
    }

    // MARK: Arrows and the caret's line

    func testArrowsReportWhichLineTheCaretIsOn() throws {
        let rig = try Rig(text: "uno\ndos\ntres")
        // The caret sits at the end of the text, on the last line.
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: false, onLastLine: true), "Asked on the last line.")
        XCTAssertEqual(rig.caretLine, 1, "Not taken: the text view moves the caret up a line itself.")
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: false, onLastLine: false), "Asked on the middle line.")
        XCTAssertEqual(rig.caretLine, 0)
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: true, onLastLine: false), "Now the first line: the pane may recall the history.")
        XCTAssertEqual(rig.caretLine, 0, "(Not taken either: the caret goes to the start of the text.)")
        rig.press(.down)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: true, onLastLine: false))
        XCTAssertEqual(rig.caretLine, 1)
        rig.press(.down)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: false, onLastLine: false))
        rig.press(.down)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: false, onLastLine: true), "The last line: ↓ may bring back a newer message.")
    }

    func testAWrappedLineCountsAsSeveralForTheCaret() throws {
        let long = Array(repeating: "palabra", count: 90).joined(separator: " ")
        let rig = try Rig(lines: 3, text: long)
        XCTAssertGreaterThan(rig.field.lineCount, 3, "It wraps over several lines in a 400 pt field.")
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last?.onFirstLine, false, "The caret at the end of a wrapped paragraph is not on its first line.")
        XCTAssertEqual(rig.box.carets.last?.onLastLine, true)
        rig.field.setSelectedRange(NSRange(location: 3, length: 0))
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: true, onLastLine: false))
    }

    func testAnEmptyAndASingleLineFieldAreBothFirstAndLast() throws {
        let rig = try Rig()
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: true, onLastLine: true))
        rig.type("hola")
        rig.press(.down)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: true, onLastLine: true))
    }

    func testATextEndingInANewlineHasAnEmptyLastLine() throws {
        let rig = try Rig(text: "uno\n")
        rig.press(.up)
        XCTAssertEqual(rig.box.carets.last, ComposerCaret(onFirstLine: false, onLastLine: true), "The caret is on the empty line after the break.")
        XCTAssertEqual(rig.caretLine, 0)
    }

    func testRightArrowIsAskedAboutAndWalksTheCaretWhenNotTaken() throws {
        let rig = try Rig(text: "hola")
        rig.field.setSelectedRange(NSRange(location: 1, length: 0))
        rig.press(.right)
        XCTAssertEqual(rig.box.keys, [.right], "The pane hears about →.")
        XCTAssertEqual(rig.field.selectedRange().location, 2, "Not taken: the caret moves right as always.")
        rig.box.takes.insert(.right)
        rig.press(.right)
        XCTAssertEqual(rig.field.selectedRange().location, 2, "Taken: the pane did something with it instead (the text view leaves it alone).")
    }

    func testShiftArrowsAndOtherKeysAreLeftToTheTextView() throws {
        let rig = try Rig(text: "uno\ndos")
        rig.press(.up, .shift)
        XCTAssertEqual(rig.box.keys, [], "⇧↑ extends the selection and is not the pane's.")
        XCTAssertGreaterThan(rig.field.selectedRange().length, 0)
        rig.press(.left)
        XCTAssertEqual(rig.box.keys, [])
    }

    // MARK: Height

    func testTheFieldGrowsLineByLineAndScrollsPastTheLimit() throws {
        let rig = try Rig(lines: 3)
        let one = ComposerMetrics.fieldHeight(lines: 1, size: 13)
        XCTAssertEqual(one, 22, "With the default text one line is the single-line field's 22 pt.")
        XCTAssertEqual(rig.fieldView.frame.height, one, accuracy: 0.5)
        rig.type("uno"); rig.press(.enter, .shift); rig.type("dos")
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 2, size: 13), accuracy: 0.5)
        rig.press(.enter, .shift); rig.type("tres")
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 3, size: 13), accuracy: 0.5)
        XCTAssertEqual(rig.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "Everything fits: nothing is scrolled.")
        // Past the third line the field stops growing and scrolls inside itself, keeping the caret in view.
        for word in ["cuatro", "cinco", "seis"] { rig.press(.enter, .shift); rig.type(word) }
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 3, size: 13), accuracy: 0.5, "Still three lines tall.")
        XCTAssertGreaterThan(rig.scroll.contentView.bounds.origin.y, 0, "The text scrolled to the caret.")
        let visible = rig.scroll.documentVisibleRect
        let layout = try XCTUnwrap(rig.field.layoutManager)
        let last = layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
        XCTAssertGreaterThanOrEqual(visible.maxY, last.maxY, "The last line, where the caret is, shows.")
        XCTAssertLessThanOrEqual(visible.minY, last.minY)
        // Back to one line: the field shrinks and the scroll returns to the top.
        rig.box.text = ""
        ComposerFieldTests.Rig.settle(0.3)
        XCTAssertEqual(rig.fieldView.frame.height, one, accuracy: 0.5)
        XCTAssertEqual(rig.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(rig.field.string, "", "Cleared from outside, as a sent message does.")
    }

    func testTheLimitComesFromTheSettingAndTheTextSize() throws {
        let one = try Rig(lines: 1)
        one.type("uno"); one.press(.enter, .shift); one.type("dos")
        XCTAssertEqual(one.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 1, size: 13), accuracy: 0.5, "A limit of one line scrolls from the second.")

        let six = try Rig(lines: 6)
        for word in ["1", "2", "3", "4", "5", "6", "7"] { six.type(word); six.press(.enter, .shift) }
        XCTAssertEqual(six.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 6, size: 13), accuracy: 0.5)

        let big = try Rig(lines: 2, size: 18)
        big.type("uno"); big.press(.enter, .shift); big.type("dos"); big.press(.enter, .shift); big.type("tres")
        XCTAssertEqual(big.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 2, size: 18), accuracy: 0.5)
        XCTAssertGreaterThan(ComposerMetrics.fieldHeight(lines: 1, size: 18), 22, "Bigger text, taller lines.")
    }

    func testAWrappedParagraphGrowsTheFieldToo() throws {
        let long = Array(repeating: "palabra", count: 60).joined(separator: " ")
        let rig = try Rig(lines: 3, text: long)
        XCTAssertEqual(rig.fieldView.frame.height, ComposerMetrics.fieldHeight(lines: 3, size: 13), accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(rig.field.lineCount, 3)
    }

    // MARK: Text

    func testTheDraftComesInAndGoesOutWithTheCaretAtTheEnd() throws {
        let rig = try Rig()
        rig.box.text = "/usage "
        Rig.settle(0.3)
        XCTAssertEqual(rig.field.string, "/usage ")
        XCTAssertEqual(rig.field.selectedRange(), NSRange(location: 7, length: 0), "A completion leaves the caret after it, so typing continues.")
        rig.type("x")
        XCTAssertEqual(rig.box.text, "/usage x")
        rig.field.setSelectedRange(NSRange(location: 2, length: 0))
        rig.type("Z")
        XCTAssertEqual(rig.box.text, "/uZsage x", "Typing in the middle stays in the middle.")
    }

    func testPlainTextOnlyAndNothingIsRewritten() throws {
        let rig = try Rig()
        rig.type("\"cita\" -- a -> b")
        XCTAssertEqual(rig.box.text, "\"cita\" -- a -> b", "No smart quotes or dashes in a command.")
        XCTAssertFalse(rig.field.isRichText)
        XCTAssertFalse(rig.field.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(rig.field.isContinuousSpellCheckingEnabled)
        // Text with several lines (a paste, a dictation) keeps them.
        rig.box.text = "uno\ndos\ntres"
        Rig.settle(0.2)
        XCTAssertEqual(rig.field.string, "uno\ndos\ntres")
        XCTAssertEqual(rig.field.lineCount, 3)
    }

    func testTheMessagePlaceholderShowsOnlyWhileEmpty() throws {
        let rig = try Rig(placeholder: "Sugerencia de Claude")
        XCTAssertEqual(rig.field.placeholder, "Sugerencia de Claude")
        XCTAssertTrue(rig.field.string.isEmpty)
        rig.type("a")
        XCTAssertEqual(rig.field.string, "a")
    }

    func testUndoTakesBackWhatWasTypedAndTheBindingFollows() throws {
        let rig = try Rig()
        rig.type("hola")
        let undo = try XCTUnwrap(rig.field.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        Rig.settle(0.2)
        XCTAssertEqual(rig.field.string, "")
        XCTAssertEqual(rig.box.text, "", "The draft follows an undo (the single-line field's editor never reported it).")
        undo.redo()
        Rig.settle(0.2)
        XCTAssertEqual(rig.box.text, "hola")
    }
}
