import AppKit

// The messages the conversation shows before Claude's own record has them.
//
// A message sent to Claude is not in its record at once. While Nook delivers it, and while Claude holds it in its queue (grey in its
// terminal, until its turn allows) the message stands at the end of the mirror anyway, so the user sees what they sent; Claude's
// record replaces it when it takes it. Each is told apart by its state:
//
//   sending   Nook is putting it into Claude's box: a message block like any other, tagged "enviando".
//   waiting   Delivered, and Claude's record does not have it yet (nearly always a moment): a message block like any other.
//   queued    Claude holds it in its queue: grey, tagged "en cola", like Claude's own terminal shows it.
//
// The blocks are written the way the user's own messages are ("> text"), so `TranscriptStyler` dresses them as such; the scroll view
// then paints the grey and the tag over the ones that need it (`LiveTerminalScrollView.setMessages`).

struct MirrorMessage: Equatable {
    enum State: Equatable { case sending, waiting, queued }

    var text: String
    var state: State
}

enum MirrorMessages {
    /// One message's block in the composed text.
    struct Block: Equatable {
        /// The whole block: "> " and the message's lines.
        var range: NSRange
        /// The ">" that opens it.
        var marker: NSRange
        var state: MirrorMessage.State
    }

    /// A message that is not in the conversation yet shows its first lines only: a long paste waiting in Claude's queue would otherwise fill
    /// the mirror, and the whole of it is there once Claude's record has it.
    static let maxLines = 8

    /// The conversation's text with a block for each message after it. Blocks are apart by a blank line, as the conversation's own
    /// messages are, however the text ended (Claude's record ends with one, a screen with none). A message's later lines are
    /// indented under its ">". A message with nothing to show is left out.
    static func compose(_ base: String, with messages: [MirrorMessage]) -> (text: String, blocks: [Block]) {
        let shown = messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !shown.isEmpty else { return (base, []) }
        var text = base
        if !base.isEmpty { text += String(repeating: "\n", count: max(0, 2 - trailingNewlines(of: base))) }
        var blocks: [Block] = []
        for (index, message) in shown.enumerated() {
            if index > 0 { text += "\n\n" }
            let start = (text as NSString).length
            let lines = message.text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let kept = lines.count > maxLines ? Array(lines.prefix(maxLines)) + ["…"] : lines
            let block = "> " + kept.joined(separator: "\n  ")
            text += block
            blocks.append(Block(range: NSRange(location: start, length: (block as NSString).length), marker: NSRange(location: start, length: 1), state: message.state))
        }
        return (text, blocks)
    }

    private static func trailingNewlines(of text: String) -> Int {
        var count = 0
        for character in text.reversed() { if character == "\n" { count += 1 } else { break } }
        return count
    }
}

// MARK: - Look

/// What a message block wears in each state: its colours, and the word on its tag.
struct MirrorMessageLook {
    var fill: NSColor
    var stroke: NSColor
    /// The ">" and the message's text.
    var marker: NSColor
    var text: NSColor
    var tag: TranscriptBubble.Tag?

    /// `voice` is the tab's, in the island's theme (`TabTint.voice(_:)`): a message that is on its way is still the user's. `dark` is the theme.
    init(_ state: MirrorMessage.State, voice: TabVoice, dark: Bool = true) {
        let strokeStrength: CGFloat = dark ? 0.24 : 0.30
        switch state {
        case .queued:
            // Claude's queue shows grey, and so does Nook: the message is not part of the conversation yet.
            if dark {
                fill = NSColor(white: 1, alpha: 0.05)
                stroke = NSColor(white: 1, alpha: 0.13)
                marker = NSColor(white: 1, alpha: 0.42)
                text = NSColor(white: 1, alpha: 0.6)
                tag = TranscriptBubble.Tag(text: "En cola", fill: NSColor(white: 1, alpha: 0.09), ink: NSColor(white: 1, alpha: 0.66))
            } else {
                let ink = NSColor(srgbRed: 0.110, green: 0.105, blue: 0.095, alpha: 1)
                fill = ink.withAlphaComponent(0.05)
                stroke = ink.withAlphaComponent(0.16)
                marker = ink.withAlphaComponent(0.48)
                text = ink.withAlphaComponent(0.66)
                tag = TranscriptBubble.Tag(text: "En cola", fill: ink.withAlphaComponent(0.09), ink: ink.withAlphaComponent(0.70))
            }
        case .sending:
            fill = voice.accent.nsColor.withAlphaComponent(0.15)
            stroke = voice.accent.nsColor.withAlphaComponent(strokeStrength)
            marker = voice.marker.nsColor
            text = voice.text.nsColor
            tag = TranscriptBubble.Tag(text: "Enviando", fill: voice.accent.nsColor.withAlphaComponent(0.22), ink: voice.marker.nsColor)
        case .waiting:
            fill = voice.accent.nsColor.withAlphaComponent(0.15)
            stroke = voice.accent.nsColor.withAlphaComponent(strokeStrength)
            marker = voice.marker.nsColor
            text = voice.text.nsColor
            tag = nil
        }
    }
}
