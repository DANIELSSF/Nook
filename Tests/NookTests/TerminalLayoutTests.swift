import XCTest
import AppKit
@testable import Nook

@MainActor
final class TerminalLayoutTests: XCTestCase {
    func testLongUnbrokenOutputWrapsAndReflowsWithoutChangingTheText() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        let text = "https://example.test/" + String(repeating: "abcdef0123456789", count: 60)
        scroll.setText(text)
        scroll.layoutSubtreeIfNeeded()
        let narrowHeight = scroll.textView.frame.height

        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.textView.frame.width, scroll.contentSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(narrowHeight, scroll.contentSize.height)
        assertTextFits(scroll)

        scroll.setFrameSize(NSSize(width: 360, height: 80))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.textView.frame.height, narrowHeight)
        XCTAssertEqual(scroll.textView.string, text)
        assertTextFits(scroll)
    }

    func testNewOutputFollowsTheEndButPreservesReadingOlderLines() {
        let scroll = LiveTerminalScrollView(frame: .zero)
        let text = (1...40).map { "Línea \($0): salida de la terminal" }.joined(separator: "\n")
        scroll.setText(text)
        scroll.setFrameSize(NSSize(width: 240, height: 80))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.documentVisibleRect.maxY, scroll.textView.frame.height, accuracy: 1)
        scroll.setText(text + "\nNueva salida")
        XCTAssertEqual(scroll.documentVisibleRect.maxY, scroll.textView.frame.height, accuracy: 1)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.setText(text + "\nNueva salida\nOtra línea")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 20, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0)
    }

    func testSelectionIsCopiedAndSurvivesNewOutput() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        scroll.textView.pasteboard = pasteboard
        var copies = 0
        scroll.textView.onCopy = { copies += 1 }
        scroll.setText("⏺ Respuesta con /ruta/al/archivo.swift\nmás salida")
        XCTAssertFalse(scroll.textView.copySelection(), "Without a selection nothing is copied.")
        scroll.textView.setSelectedRange(NSRange(location: 16, length: 22))
        XCTAssertTrue(scroll.textView.copySelection())
        XCTAssertEqual(pasteboard.string(forType: .string), "/ruta/al/archivo.swift")
        XCTAssertEqual(copies, 1)
        scroll.setText("⏺ Respuesta con /ruta/al/archivo.swift\nmás salida\nnueva línea")
        XCTAssertEqual(scroll.textView.selectedRange(), NSRange(location: 16, length: 22))
        scroll.setText("Otra pantalla")
        XCTAssertEqual(scroll.textView.selectedRange().length, 0)
    }

    func testASelectionNeverEndsUpOnDifferentText() {
        // Codex's case: a prefix leaves the history while output grows, and the old range still fits.
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let output = (1...30).map { "More output \($0)" }.joined(separator: "\n")
        scroll.setText("Abriendo /src/file.swift\n" + output)
        scroll.textView.setSelectedRange(NSRange(location: 9, length: 15))
        XCTAssertEqual((scroll.textView.string as NSString).substring(with: scroll.textView.selectedRange()), "/src/file.swift")
        scroll.setText(output + "\nMore output 31\nMore output 32")
        XCTAssertEqual(scroll.textView.selectedRange().length, 0, "Cleared rather than pointing at other text.")
    }

    func testOnlyTheChangedTailIsReplacedAndTheResultIsExact() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        let base = (1...300).map { "Línea \($0) 🐈 con acentos y más texto" }.joined(separator: "\n")
        scroll.setText(base + "\n✶ Churning… (1s)")
        scroll.setText(base + "\n✻ Churning… (2s)")
        XCTAssertEqual(scroll.textView.string, base + "\n✻ Churning… (2s)")
        scroll.setText(base + "\n🐈‍⬛ gato negro")
        XCTAssertEqual(scroll.textView.string, base + "\n🐈‍⬛ gato negro")
        scroll.setText("Otra pantalla")
        XCTAssertEqual(scroll.textView.string, "Otra pantalla")
        XCTAssertEqual(LiveTerminalScrollView.commonPrefix("abc🐈x" as NSString, "abc🐈y" as NSString), 5, "The emoji is two UTF-16 units.")
        XCTAssertEqual(LiveTerminalScrollView.commonPrefix("abc🐈" as NSString, "abc🐕" as NSString), 3, "A changed emoji is replaced whole.")
        XCTAssertEqual(scroll.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, scroll.textView.font)
    }

    private func assertTextFits(_ scroll: LiveTerminalScrollView, file: StaticString = #filePath, line: UInt = #line) {
        let container = scroll.textView.textContainer!
        let manager = scroll.textView.layoutManager!
        manager.ensureLayout(for: container)
        let usedWidth = manager.usedRect(for: container).maxX + scroll.textView.textContainerInset.width * 2
        XCTAssertLessThanOrEqual(usedWidth, scroll.contentSize.width + 0.5, file: file, line: line)
    }
}
