import XCTest
import AppKit
@testable import Nook

/// Tests for the integrated LiveTerminalScrollView (setTheme + restyle inside setText).
@MainActor
final class TranscriptIntegrationTests: XCTestCase {
    private let screen1 = ["> hola", "", "⏺ Bash(ls)", "  ⎿  a", "", "⏺ Listo."].joined(separator: "\n")
    private let screen2 = ["> hola", "", "⏺ Bash(ls)", "  ⎿  a", "", "⏺ Listo.", "", "> otra", "  cosa"].joined(separator: "\n")

    private func scroll() -> LiveTerminalScrollView {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 138))
        scroll.setTheme(dark: true, transcript: true)
        return scroll
    }

    private func attributes(_ scroll: LiveTerminalScrollView) -> [NSDictionary] {
        let storage = scroll.textView.textStorage!
        return (0..<storage.length).map { storage.attributes(at: $0, effectiveRange: nil) as NSDictionary }
    }

    func testClaudeTextIsStyledAndIncrementalUpdatesMatchAFreshPass() {
        let live = scroll()
        live.setText(screen1)
        live.setText(screen2)
        let fresh = scroll()
        fresh.setText(screen2)
        XCTAssertEqual(attributes(live), attributes(fresh))
        XCTAssertNotNil(live.textView.textStorage!.attribute(.transcriptBubble, at: 0, effectiveRange: nil))
        XCTAssertTrue(live.textView.layoutManager is MirrorLayoutManager)
        XCTAssertNil(live.textView.textLayoutManager)
    }

    func testShellTextStaysExactlyAsBefore() {
        let plain = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 138))
        plain.setTheme(dark: true, transcript: false)
        plain.setText(screen2)
        plain.setText(screen2 + "\n$ ls")
        let storage = plain.textView.textStorage!
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.transcriptRole]); XCTAssertNil(attributes[.transcriptBubble])
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .white)
        }
    }

    func testSwitchingTheAgentRestylesAndUnstylesWhatIsShown() {
        let live = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 138))
        live.setTheme(dark: true, transcript: false)
        live.setText(screen2)
        live.setTheme(dark: true, transcript: true)
        XCTAssertNotNil(live.textView.textStorage!.attribute(.transcriptBubble, at: 0, effectiveRange: nil))
        live.setTheme(dark: true, transcript: false)
        live.textView.textStorage!.enumerateAttributes(in: NSRange(location: 0, length: live.textView.textStorage!.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.transcriptRole]); XCTAssertNil(attributes[.transcriptBubble]); XCTAssertNil(attributes[.kern])
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .white)
        }
        XCTAssertEqual(live.textView.string, screen2)
    }

    func testThemeChangesRecolorEverythingAndTheTextThatArrivesLater() {
        let live = scroll()
        live.setText(screen1)
        live.setTheme(dark: false, transcript: true)
        live.setText(screen2)
        let fresh = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 138))
        fresh.setTheme(dark: false, transcript: true)
        fresh.setText(screen2)
        XCTAssertEqual(attributes(live), attributes(fresh))
        XCTAssertEqual(live.appearance?.name, .aqua)
    }

    func testSelectionAndCopySurviveStyledUpdates() {
        let live = scroll()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        live.textView.pasteboard = pasteboard
        live.setText(screen1)
        live.textView.setSelectedRange(NSRange(location: 2, length: 4))
        XCTAssertTrue(live.textView.copySelection())
        XCTAssertEqual(pasteboard.string(forType: .string), "hola")
        live.setText(screen2)
        XCTAssertEqual(live.textView.selectedRange(), NSRange(location: 2, length: 4))
    }

    func testClickingADimmedLineDoesNotPassItsLookToLaterText() {
        let live = scroll()
        live.setText(screen1)
        // Copy-on-select clicks put the selection inside styled lines, and the text view's typing attributes follow it.
        live.textView.setSelectedRange(NSRange(location: (screen1 as NSString).range(of: "Bash").location, length: 3))
        live.setTheme(dark: true, transcript: false)
        live.setText(screen1 + "\n$ ls")
        let storage = live.textView.textStorage!
        let index = (storage.string as NSString).range(of: "$ ls").location
        XCTAssertEqual((storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize, 11)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, .white)
        XCTAssertNil(storage.attribute(.transcriptRole, at: index, effectiveRange: nil))
    }

    func testTheBottomBlockIsNotClippedAtTheEndOfTheDocument() throws {
        let live = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 60))
        live.setTheme(dark: true, transcript: true)
        live.setText("⏺ Hola\n\n> último mensaje")
        live.layoutSubtreeIfNeeded()
        let manager = try XCTUnwrap(live.textView.layoutManager)
        let used = manager.usedRect(for: try XCTUnwrap(live.textView.textContainer))
        XCTAssertGreaterThanOrEqual(live.textView.frame.height - (used.maxY + live.textView.textContainerOrigin.y), MirrorLayoutManager.verticalPadding + 0.5)
    }
}
