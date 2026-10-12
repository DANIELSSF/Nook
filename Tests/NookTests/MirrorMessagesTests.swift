import AppKit
import XCTest
@testable import Nook

/// The messages the conversation shows before Claude's record has them: where they stand after the text, and how the mirror dresses
/// each state (a message being delivered, one delivered and not in the record yet, one Claude holds in its queue).
@MainActor
final class MirrorMessagesTests: XCTestCase {
    // MARK: Composing

    func testABlockFollowsTheConversationAfterABlankLineHoweverItEnded() {
        let message = [MirrorMessage(text: "hola", state: .waiting)]
        XCTAssertEqual(MirrorMessages.compose("⏺ Listo", with: message).text, "⏺ Listo\n\n> hola", "A screen's text ends with none.")
        XCTAssertEqual(MirrorMessages.compose("⏺ Listo\n", with: message).text, "⏺ Listo\n\n> hola")
        XCTAssertEqual(MirrorMessages.compose("⏺ Listo\n\n", with: message).text, "⏺ Listo\n\n> hola", "Claude's record ends with a blank line already: no second one.")
        XCTAssertEqual(MirrorMessages.compose("", with: message).text, "> hola", "Nothing above, nothing to set it apart from.")
        XCTAssertEqual(MirrorMessages.compose("⏺ Listo", with: []).text, "⏺ Listo")
        XCTAssertTrue(MirrorMessages.compose("⏺ Listo", with: []).blocks.isEmpty)
    }

    func testEachBlockIsFoundByItsRangeAndMarker() {
        let composed = MirrorMessages.compose("⏺ Listo\n\n", with: [MirrorMessage(text: "uno", state: .queued), MirrorMessage(text: "dos\ny tres", state: .sending)])
        XCTAssertEqual(composed.text, "⏺ Listo\n\n> uno\n\n> dos\n  y tres", "Later lines hang under the marker, as the user's own messages' do.")
        let text = composed.text as NSString
        XCTAssertEqual(composed.blocks.map { text.substring(with: $0.range) }, ["> uno", "> dos\n  y tres"])
        XCTAssertEqual(composed.blocks.map { text.substring(with: $0.marker) }, [">", ">"])
        XCTAssertEqual(composed.blocks.map(\.state), [.queued, .sending])
    }

    func testAMessageWithNothingToShowIsLeftOut() {
        let composed = MirrorMessages.compose("⏺ Listo", with: [MirrorMessage(text: " \n ", state: .queued), MirrorMessage(text: "  sí  ", state: .waiting)])
        XCTAssertEqual(composed.text, "⏺ Listo\n\n> sí")
        XCTAssertEqual(composed.blocks.count, 1)
    }

    func testALongMessageShowsItsFirstLinesAndSaysThereIsMore() {
        let long = (1...20).map { "línea \($0)" }.joined(separator: "\n")
        let composed = MirrorMessages.compose("", with: [MirrorMessage(text: long, state: .queued)])
        let lines = composed.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, MirrorMessages.maxLines + 1)
        XCTAssertEqual(lines.first, "> línea 1"); XCTAssertEqual(lines[MirrorMessages.maxLines - 1], "  línea \(MirrorMessages.maxLines)")
        XCTAssertEqual(lines.last, "  …")
        XCTAssertEqual(composed.blocks.first?.range.length, (composed.text as NSString).length, "The block is all of it.")
        // Exactly as many lines as fit are shown whole.
        let exact = (1...MirrorMessages.maxLines).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertFalse(MirrorMessages.compose("", with: [MirrorMessage(text: exact, state: .queued)]).text.contains("…"))
    }

    func testRangesCountUTF16LikeTheTextViewDoes() {
        let composed = MirrorMessages.compose("⏺ Listo 🎉", with: [MirrorMessage(text: "¿qué tal? 👋", state: .queued)])
        let text = composed.text as NSString
        XCTAssertEqual(text.substring(with: composed.blocks[0].range), "> ¿qué tal? 👋")
    }

    // MARK: How the mirror dresses them

    private func mirror(_ conversation: String, _ messages: [MirrorMessage], voice: TabVoice = .mint) -> LiveTerminalScrollView {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setVoice(voice)
        scroll.update(text: conversation, messages: messages)
        return scroll
    }

    private func bubble(_ scroll: LiveTerminalScrollView, at text: String) -> TranscriptBubble? {
        let storage = scroll.textView.textStorage!
        let range = (storage.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : storage.attribute(.transcriptBubble, at: range.location, effectiveRange: nil) as? TranscriptBubble
    }

    private func color(_ scroll: LiveTerminalScrollView, at text: String) -> NSColor? {
        let storage = scroll.textView.textStorage!
        let range = (storage.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    private let conversation = "> primero\n\n⏺ Hecho.\n\n"

    func testAQueuedMessageIsGreyWithItsTagAndTheConversationAboveIsUntouched() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "y el notch", state: .queued)])
        let queued = try XCTUnwrap(bubble(scroll, at: "y el notch"))
        let look = MirrorMessageLook(.queued, voice: .mint)
        XCTAssertEqual(queued.fill, look.fill); XCTAssertEqual(queued.stroke, look.stroke)
        XCTAssertEqual(queued.tag?.text, "En cola")
        XCTAssertEqual(color(scroll, at: "y el notch"), look.text)
        XCTAssertEqual(color(scroll, at: "> y el"), look.marker, "The marker is greyed too.")
        let sent = try XCTUnwrap(bubble(scroll, at: "primero"))
        XCTAssertEqual(sent.fill, TranscriptPalette.mint.withAlphaComponent(0.15), "What Claude already has stays the user's colour.")
        XCTAssertNil(sent.tag)
        XCTAssertNotEqual(sent, queued, "A neighbouring message is its own block.")
    }

    func testTheTagsRoomIsKeptOnTheFirstParagraphOnly() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "una línea\ny otra", state: .queued)])
        let storage = scroll.textView.textStorage!
        let text = storage.string as NSString
        let first = text.range(of: "una línea").location, second = text.range(of: "y otra").location
        let one = try XCTUnwrap(storage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle)
        let two = try XCTUnwrap(storage.attribute(.paragraphStyle, at: second, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(one.tailIndent, -TranscriptBubble.tagGutter, "The pill stands there.")
        XCTAssertEqual(two.tailIndent, 0, "The rest of the message uses the whole width.")
    }

    func testAMessageBeingDeliveredIsTheUsersColourWithItsTag() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "avísame", state: .sending)], voice: TabTint.rose.voice)
        let sending = try XCTUnwrap(bubble(scroll, at: "avísame"))
        XCTAssertEqual(sending.fill, TabTint.rose.voice.accent.nsColor.withAlphaComponent(0.15), "Still the user's, in the tab's colour.")
        XCTAssertEqual(sending.tag?.text, "Enviando")
        XCTAssertEqual(color(scroll, at: "avísame"), TabTint.rose.voice.text.nsColor)
    }

    func testAMessageDeliveredAndNotInTheRecordYetIsAMessageLikeAnyOther() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "ya lo mandé", state: .waiting)])
        let waiting = try XCTUnwrap(bubble(scroll, at: "ya lo mandé"))
        XCTAssertEqual(waiting.fill, TranscriptPalette.mint.withAlphaComponent(0.15))
        XCTAssertNil(waiting.tag)
        XCTAssertEqual(scroll.textView.string, conversation + "> ya lo mandé")
    }

    func testTheStateChangesTheLookWithoutChangingTheWords() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "hola", state: .sending)])
        let words = scroll.textView.string
        XCTAssertEqual(bubble(scroll, at: "hola")?.tag?.text, "Enviando")
        scroll.setMessages([MirrorMessage(text: "hola", state: .queued)])
        XCTAssertEqual(scroll.textView.string, words, "Only the look changes.")
        XCTAssertEqual(bubble(scroll, at: "hola")?.tag?.text, "En cola")
        XCTAssertEqual(color(scroll, at: "hola"), MirrorMessageLook(.queued, voice: .mint).text)
        scroll.setMessages([MirrorMessage(text: "hola", state: .waiting)])
        let waiting = try XCTUnwrap(bubble(scroll, at: "hola"))
        XCTAssertNil(waiting.tag, "The grey and the pill are gone.")
        XCTAssertEqual(waiting.fill, TranscriptPalette.mint.withAlphaComponent(0.15))
        let storage = scroll.textView.textStorage!
        let at = (storage.string as NSString).range(of: "hola").location
        XCTAssertEqual((storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.tailIndent, 0, "And so is the room the pill took.")
    }

    func testWhenClaudeTakesTheMessageItsPlaceholderGoes() {
        let scroll = mirror(conversation, [MirrorMessage(text: "hola", state: .queued)])
        XCTAssertTrue(scroll.textView.string.hasSuffix("> hola"))
        // Claude's record has it now: the conversation is the record's, and nothing stands after it.
        scroll.update(text: conversation + "> hola\n\n", messages: [])
        XCTAssertEqual(scroll.textView.string, conversation + "> hola\n\n")
        XCTAssertNil(bubble(scroll, at: "hola")?.tag)
        XCTAssertEqual(bubble(scroll, at: "hola")?.fill, TranscriptPalette.mint.withAlphaComponent(0.15), "It is a message like any other now.")
    }

    func testSeveralQueuedMessagesStandInOrderAndNewTextKeepsThem() {
        let scroll = mirror("⏺ Trabajando.", [MirrorMessage(text: "uno", state: .queued), MirrorMessage(text: "dos", state: .queued)])
        XCTAssertEqual(scroll.textView.string, "⏺ Trabajando.\n\n> uno\n\n> dos")
        // The conversation grows above them: they stay after it, still grey.
        scroll.update(text: "⏺ Trabajando.\n\n⏺ Y sigo.", messages: scroll.messages)
        XCTAssertEqual(scroll.textView.string, "⏺ Trabajando.\n\n⏺ Y sigo.\n\n> uno\n\n> dos")
        XCTAssertEqual(bubble(scroll, at: "uno")?.tag?.text, "En cola")
        XCTAssertEqual(bubble(scroll, at: "dos")?.tag?.text, "En cola")
        XCTAssertNotEqual(bubble(scroll, at: "uno"), bubble(scroll, at: "dos"))
        // The line break after a block belongs to it: nothing of the styler's own block is left under the new one, or it would be
        // painted over it (a green strip over a grey message).
        let storage = scroll.textView.textStorage!
        let after = NSMaxRange((storage.string as NSString).range(of: "uno"))
        XCTAssertEqual(storage.attribute(.transcriptBubble, at: after, effectiveRange: nil) as? TranscriptBubble, bubble(scroll, at: "uno"))
    }

    func testAQueuedMessageThatWrapsIsOneBlockOnTwoLines() throws {
        let long = String(repeating: "palabra ", count: 40)
        let scroll = mirror(conversation, [MirrorMessage(text: long, state: .queued), MirrorMessage(text: "otra", state: .queued)])
        let storage = scroll.textView.textStorage!
        let text = storage.string as NSString
        let first = text.range(of: "palabra").location
        var run = NSRange(location: 0, length: 0)
        let found = storage.attribute(.transcriptBubble, at: first, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length)) as? TranscriptBubble
        XCTAssertEqual(found?.tag?.text, "En cola")
        let end = NSMaxRange(text.range(of: "palabra ", options: .backwards))
        XCTAssertGreaterThanOrEqual(NSMaxRange(run), end, "One bubble for the whole message, however many lines it takes.")
    }

    func testAChangeOfTheTabsColourKeepsTheGreyAndFollowsTheRest() throws {
        let scroll = mirror(conversation, [MirrorMessage(text: "gris", state: .queued), MirrorMessage(text: "enviando", state: .sending)])
        scroll.setVoice(TabTint.blue.voice)
        XCTAssertEqual(bubble(scroll, at: "gris")?.fill, MirrorMessageLook(.queued, voice: .mint).fill, "Grey is nobody's colour.")
        XCTAssertEqual(bubble(scroll, at: "enviando")?.fill, TabTint.blue.voice.accent.nsColor.withAlphaComponent(0.15))
        XCTAssertEqual(bubble(scroll, at: "primero")?.fill, TabTint.blue.voice.accent.nsColor.withAlphaComponent(0.15))
    }

    func testAMirrorOfPlainOutputIgnoresThem() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        scroll.setTheme(dark: true, transcript: false)
        scroll.update(text: "$ ls\nREADME.md", messages: [MirrorMessage(text: "hola", state: .queued)])
        XCTAssertEqual(scroll.textView.string, "$ ls\nREADME.md", "Codex and shells get their placeholder as a line of text from the pane, not from here.")
    }

    func testTheOldCallsStillWork() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setText("> hola\n")
        XCTAssertEqual(scroll.textView.string, "> hola\n")
        XCTAssertEqual(scroll.messages, [])
    }

    // MARK: The look

    func testQueuedIsGreyAndTheOtherStatesFollowTheTab() {
        let queued = MirrorMessageLook(.queued, voice: TabTint.rose.voice)
        XCTAssertEqual(queued.fill, MirrorMessageLook(.queued, voice: .mint).fill, "Whatever the tab.")
        for state in [MirrorMessage.State.sending, .waiting] {
            XCTAssertEqual(MirrorMessageLook(state, voice: TabTint.rose.voice).stroke, TabTint.rose.voice.accent.nsColor.withAlphaComponent(0.24), "\(state)")
        }
        XCTAssertNotNil(MirrorMessageLook(.queued, voice: .mint).tag); XCTAssertNotNil(MirrorMessageLook(.sending, voice: .mint).tag)
        XCTAssertNil(MirrorMessageLook(.waiting, voice: .mint).tag, "Nothing to say about a message that is there in a moment.")
    }
}
