import AppKit
import XCTest
@testable import Nook

/// The summary Claude Code writes when it compacts a session's context: told from the record by its flag and from the screen by its
/// opening, kept out of the chat (a divider stands in its place), and offered by its own control.
final class CompactionSummaryTests: XCTestCase {
    static let summary = """
    This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.

    <system-reminder>
    <tools-used-before-summary>Agent, Bash, Read</tools-used-before-summary>
    </system-reminder>
    Summary:
    1. Primary Request and Intent:
       - The user wants the island to show **tables** properly.

    2. Key Technical Concepts:
       - `NSLayoutManager`, line fragments.

    9. Optional Next Step:
       - Run the render tests.

    Continue the conversation from where it left off without asking the user any further questions. Resume directly — do not acknowledge the summary.
    """

    // MARK: Record

    private func entry(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testTheRecordsSummaryIsNoPromptButADividerAndItsTextIsKept() {
        var renderer = TranscriptRenderer()
        renderer.consume(entry(["type": "user", "message": ["role": "user", "content": "hola"]]))
        renderer.consume(entry(["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"]))
        renderer.consume(entry(["type": "user", "isCompactSummary": true, "isVisibleInTranscriptOnly": true, "message": ["role": "user", "content": Self.summary]]))
        renderer.consume(entry(["type": "user", "message": ["role": "user", "content": "sigue con lo de las tablas"]]))
        renderer.consume(entry(["type": "assistant", "message": ["content": [["type": "text", "text": "Sigo."]]]]))
        let text = renderer.text
        XCTAssertFalse(text.contains("This session is being continued"), "Never drawn as the user's message.")
        XCTAssertFalse(text.contains("Primary Request"))
        XCTAssertTrue(text.contains("\n\n" + CompactionSummary.marker + "\n\n"), text)
        XCTAssertTrue(text.contains("> sigue con lo de las tablas"), "The messages after it are kept.")
        XCTAssertTrue(text.contains("⏺ Sigo."))
        let kept = try! XCTUnwrap(renderer.compactSummary)
        XCTAssertTrue(kept.hasPrefix("This session is being continued"))
        XCTAssertTrue(kept.contains("1. Primary Request and Intent:"))
        XCTAssertFalse(kept.contains("system-reminder"), "Claude Code's notes to itself go.")
        XCTAssertFalse(kept.contains("tools-used-before-summary"))
    }

    func testASummaryOpeningWithTheTagAboutOthersContentIsToldByItsFlagToo() {
        var renderer = TranscriptRenderer()
        let tagged = "<artifact-content-authored-by-others/>\nThe summarized conversation included Artifact content written by people other than you.\n\n" + Self.summary
        renderer.consume(entry(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": tagged]]))
        XCTAssertEqual(renderer.text, CompactionSummary.marker + "\n\n")
        XCTAssertEqual(renderer.compactSummary?.hasPrefix("The summarized conversation included"), true)
        XCTAssertFalse(renderer.compactSummary?.contains("<artifact") ?? true)
    }

    func testAUserMessageThatOnlyQuotesTheOpeningIsAMessage() {
        var renderer = TranscriptRenderer()
        let quoting = "¿Por qué sale esto?: \"This session is being continued from a previous conversation that ran out of context.\""
        renderer.consume(entry(["type": "user", "message": ["role": "user", "content": quoting]]))
        XCTAssertTrue(renderer.text.hasPrefix("> ¿Por qué sale esto?"))
        XCTAssertNil(renderer.compactSummary)
        // Without the flag, even a message that starts with the sentence is the user's: the record says who wrote what.
        var pasted = TranscriptRenderer()
        pasted.consume(entry(["type": "user", "message": ["role": "user", "content": Self.summary]]))
        XCTAssertTrue(pasted.text.hasPrefix("> This session is being continued"))
        XCTAssertNil(pasted.compactSummary)
    }

    // MARK: Screen

    /// The summary as Claude's screen draws a prompt: "> " on its first line, two columns in front of the others.
    private static var onScreen: [String] {
        let lines = summary.components(separatedBy: "\n")
        return ["> " + lines[0]] + lines.dropFirst().map { $0.isEmpty ? "" : "  " + $0 }
    }

    func testAWholeSummaryOnTheScreenGivesWayToTheDivider() throws {
        let screen = (["⏺ Listo.", ""] + Self.onScreen + ["", "> sigue con lo de las tablas", "", "⏺ Sigo con las tablas."]).joined(separator: "\n")
        let (text, found) = CompactionSummary.stripped(screen)
        XCTAssertEqual(text, ["⏺ Listo.", "", CompactionSummary.marker, "", "> sigue con lo de las tablas", "", "⏺ Sigo con las tablas."].joined(separator: "\n"),
                       "The messages after it are kept, and so are the blank lines around it.")
        let summary = try XCTUnwrap(found)
        XCTAssertTrue(summary.hasPrefix(CompactionSummary.opening))
        XCTAssertTrue(summary.contains("1. Primary Request and Intent:\n   - The user wants"), "Without the prompt's two columns: \(summary)")
        XCTAssertFalse(summary.contains("system-reminder"))
    }

    func testASummaryWhoseOpeningScrolledAwayIsToldByItsPhrases() throws {
        // The screen starts in the middle of the summary: its first lines are indented under a prompt that is no longer there.
        let screen = (Self.onScreen.dropFirst(7) + ["", "> sigue", "", "⏺ Sigo."]).joined(separator: "\n")
        let (text, found) = CompactionSummary.stripped(screen)
        XCTAssertEqual(text, [CompactionSummary.marker, "> sigue", "", "⏺ Sigo."].joined(separator: "\n"))
        XCTAssertNotNil(found)
        // A screen whose first lines are some other indented text keeps them.
        let other = "  una línea que quedó de una respuesta\n  y otra\n\n⏺ Hola"
        XCTAssertEqual(CompactionSummary.stripped(other).text, other)
        XCTAssertNil(CompactionSummary.stripped(other).summary)
    }

    func testAMessageThatQuotesTheOpeningMidTextIsAMessage() {
        let screen = ["> ¿Por qué Nook muestra «This session is being continued from a previous conversation that ran out of context.»?", "",
                      "⏺ Porque es el resumen de la compactación."].joined(separator: "\n")
        XCTAssertEqual(CompactionSummary.stripped(screen).text, screen)
        XCTAssertNil(CompactionSummary.stripped(screen).summary)
        // A reply that quotes it at the start of a line is not a prompt either.
        let reply = "⏺ Claude escribe:\n  This session is being continued from a previous conversation that ran out of context."
        XCTAssertEqual(CompactionSummary.stripped(reply).text, reply)
    }

    func testTheReadableSummaryDropsClaudesOwnNotes() {
        XCTAssertEqual(CompactionSummary.readable("A\n<system-reminder>\nx\n</system-reminder>\n\n\n\nB  \n"), "A\n\nB")
    }

    // MARK: The tab

    func testATabsRecordOrScreenGivesTheSummaryToItsControlAndTheChatADivider() throws {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: (["⏺ Listo.", ""] + Self.onScreen + ["", "> sigue", "", "⏺ Sigo."]).joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertTrue(session.displayText.contains(CompactionSummary.marker), session.displayText)
        XCTAssertFalse(session.displayText.contains("Primary Request"))
        XCTAssertTrue(session.displayText.contains("> sigue"))
        XCTAssertEqual(session.compactSummary?.hasPrefix(CompactionSummary.opening), true)
        // With the record, its summary wins; a reading without one leaves none.
        session.applyTranscript("> hola\n\n" + CompactionSummary.marker + "\n\n", recap: nil, compactSummary: "Del registro")
        XCTAssertEqual(session.compactSummary, "Del registro")
        session.applyTranscript("> otra\n\n", recap: nil)
        XCTAssertNil(session.compactSummary)
    }

    // MARK: The divider

    func testTheDividerIsAQuietCentredLineBetweenHairlines() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = "> hola\n\n" + CompactionSummary.marker + "\n\n> sigue"
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let at = (text as NSString).range(of: CompactionSummary.marker).location
        XCTAssertNotNil(storage.attribute(.transcriptDivider, at: at, effectiveRange: nil))
        XCTAssertEqual((storage.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor, TranscriptPalette(dark: true).outputMarker)
        XCTAssertNil(storage.attribute(.transcriptBubble, at: at, effectiveRange: nil), "Not a message.")
        XCTAssertEqual(storage.string, text)
        // The same words inside a message are the message's.
        let quoted = NSTextStorage(string: "> " + CompactionSummary.marker, attributes: [.font: font])
        TranscriptStyler.restyle(quoted, from: 0, dark: true, font: font)
        XCTAssertNil(quoted.attribute(.transcriptDivider, at: 3, effectiveRange: nil))
    }

    func testTheKindsSayWhatTheyAre() {
        XCTAssertEqual(RecapKind.recap.tip.title, "Resumen")
        XCTAssertEqual(RecapKind.compaction.tip.title, "Resumen de la compactación")
        XCTAssertNotEqual(RecapKind.recap.storeKey("s"), RecapKind.compaction.storeKey("s"), "Each is read on its own.")
        XCTAssertNil(RecapKind.compaction.text("  \n "))
        XCTAssertEqual(RecapKind.compaction.text("1. Uno\n2. Dos"), "1. Uno\n2. Dos", "The summary keeps its lines; the recap is one.")
        // The card leaves out the paragraph every summary opens with: its title says it.
        let shown = try! XCTUnwrap(RecapKind.compaction.text(CompactionSummaryTests.summary))
        XCTAssertTrue(shown.hasPrefix("Summary:\n1. Primary Request and Intent:"), shown)
        XCTAssertNil(RecapKind.compaction.text(CompactionSummary.opening))
        XCTAssertEqual(RecapKind.recap.text("※ recap: a\nb"), "a b")
    }
}
