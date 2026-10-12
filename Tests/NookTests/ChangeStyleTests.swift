import XCTest
import AppKit
@testable import Nook

/// How the classifier reads a change's rows and the fences of a reply, and how the styler dresses them.
final class ChangeClassifierTests: XCTestCase {
    private func lines(_ text: String) -> [TranscriptClassifier.Line] { TranscriptClassifier.lines(in: text as NSString) }
    private func edit() -> String { TranscriptFixtures.render(TranscriptFixtures.swiftEdit()) }

    private func rows(_ found: [TranscriptClassifier.Line]) -> [TranscriptClassifier.ChangeRow] {
        found.compactMap { if case .row(let row) = $0.detail { row } else { nil } }
    }

    func testTheSummaryLineNamesThePathTheCountsAndTheLanguage() throws {
        let text = edit() as NSString
        let found = lines(text as String)
        guard case .summary(let summary) = found[1].detail else { return XCTFail("\(found[1])") }
        XCTAssertEqual(text.substring(with: summary.path), "Sources/Notch.swift")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(summary.added)), "+7")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(summary.removed)), "-4")
        XCTAssertEqual(summary.language, .swift)
        XCTAssertEqual(found[1].role, .toolOutput, "A summary is still a result.")
    }

    func testANewFileSummaryHasNoPlusAndMinus() throws {
        let text = TranscriptFixtures.render(TranscriptFixtures.newFile()) as NSString
        guard case .summary(let summary) = lines(text as String)[1].detail else { return XCTFail() }
        XCTAssertEqual(text.substring(with: summary.path), "README.md")
        XCTAssertNil(summary.added); XCTAssertNil(summary.removed)
        XCTAssertEqual(summary.language, .markdown)
    }

    func testEveryRowOfAnEditHasItsKindMarkAndCode() throws {
        let text = edit() as NSString
        let found = lines(text as String)
        let all = rows(found)
        let kinds = all.map(\.kind)
        XCTAssertEqual(kinds, [.context, .removed, .added, .added, .context, .context, .removed, .added, .added, .context, .gap,
                               .context, .removed, .added, .context, .removed, .added, .added, .context])
        // Every row but the gap has its mark ("-", "+" or the space of a context row) and the code after it.
        let marks = all.map { $0.mark.map { text.substring(with: $0) } }
        XCTAssertEqual(marks[1], "-"); XCTAssertEqual(marks[2], "+"); XCTAssertEqual(marks[0], " "); XCTAssertNil(marks[10])
        XCTAssertEqual(text.substring(with: all[1].code), "    static let expandedWidth: CGFloat = 572")
        XCTAssertEqual(text.substring(with: all[0].code), "struct NotchGeometry {")
        XCTAssertEqual(all[4].code.length, 0, "A context row for an empty line has no code.")
        XCTAssertTrue(all.filter { $0.kind != .gap }.allSatisfy { $0.language == .swift })
        // The rows are results: a row's role is what the lines under a "⎿" always had.
        XCTAssertTrue(found.dropFirst(2).filter { !$0.isBlank }.allSatisfy { $0.role == .toolOutput })
    }

    func testRowsKeepTheirOwnNumbersAndAreNotConfusedWithTheNumberColumn() {
        // Wide numbers shift the column; the code is whatever follows the mark.
        let details: [String: Any] = ["filePath": "/Users/me/app/big.py", "structuredPatch": [
            ["oldStart": 998, "newStart": 998, "lines": [" a = 1", "-b = 2 - 3", "+b = 20 + 30", " c = 4"]]]]
        let change = TranscriptRenderer.change(details, cwd: "/Users/me/app")!
        let found = lines(change)
        let all = rows(found)
        XCTAssertEqual(all.map(\.kind), [.context, .removed, .added, .context])
        let text = change as NSString
        XCTAssertEqual(text.substring(with: all[1].code), "b = 2 - 3")
        XCTAssertEqual(text.substring(with: all[2].code), "b = 20 + 30")
        XCTAssertEqual(all.first?.language, .python)
    }

    func testTheGapAndTheLinesLeftOutAreGapRows() {
        let found = lines(TranscriptFixtures.render(TranscriptFixtures.newFile()))
        let all = rows(found)
        XCTAssertEqual(all.count, 13)
        XCTAssertEqual(all.last?.kind, .gap, "The preview ends with `… +3 líneas`.")
        XCTAssertEqual(all.dropLast().map(\.kind), Array(repeating: .context, count: 12))
        let long = TranscriptRenderer.change(["filePath": "/a/long.swift", "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": (1...30).map { "+línea \($0)" }]]], cwd: "/a", limit: 5)!
        let tail = lines(long).last!
        guard case .row(let row) = tail.detail else { return XCTFail("The row of the lines left out: \(tail)") }
        XCTAssertEqual(row.kind, .gap)
    }

    func testRowsMustFollowAChangeSummary() {
        // A tool's own output that happens to look like a numbered row is output.
        let text = ["⏺ Bash(grep -n x a.txt)", "  ⎿  3 matches", "      12 + 3 = 5", "      13 - 1 = 0"].joined(separator: "\n")
        XCTAssertTrue(rows(lines(text)).isEmpty)
        // The change ends where its block ends.
        let after = edit() + "\n\n⏺ Bash(ls)\n  ⎿  a\n      99 - x\n"
        let found = lines(after)
        XCTAssertEqual(rows(found).count, 19, "Only the edit's own rows.")
        // A later result in the same block is judged by itself.
        let two = ["  ⎿  Actualizado a.swift (+1 -0)", "       1 + let a = 1", "  ⎿  Listo", "       2 + let b = 2"].joined(separator: "\n")
        XCTAssertEqual(rows(lines(two)).count, 1)
    }

    func testRowsWhoseTrailingSpacesWereTrimmedAreStillRows() {
        let change = TranscriptRenderer.change(["filePath": "/a/x.swift", "structuredPatch": [["oldStart": 5, "newStart": 5, "lines": [" a", " ", "-b", "+c", " "]]]], cwd: "/a")!
        let trimmed = change.components(separatedBy: "\n").map { $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }.joined(separator: "\n")
        XCTAssertEqual(rows(lines(trimmed)).map(\.kind), [.context, .context, .removed, .added, .context])
    }

    func testAnUnknownLanguageStillGetsItsRows() {
        let change = TranscriptRenderer.change(["filePath": "/a/notes.xyz", "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": ["-uno", "+dos"]]]], cwd: "/a")!
        let all = rows(lines(change))
        XCTAssertEqual(all.map(\.kind), [.removed, .added])
        XCTAssertNil(all.first?.language, "Rows are banded all the same; their code is just not coloured.")
    }

    // MARK: Fences

    private func details(_ text: String) -> [TranscriptClassifier.Detail] { lines(text).map(\.detail) }

    func testAFencedBlockInAReplyIsItsFenceLinesAndCode() throws {
        let text = ["⏺ Mira:", "", "  ```swift", "  let a = 1", "    foo()", "", "  ```", "", "  fuera"].joined(separator: "\n")
        let found = details(text)
        XCTAssertEqual(found[0], .none)
        XCTAssertEqual(found[2], .fence)
        let code = (text as NSString).range(of: "let a")
        XCTAssertEqual(found[3], .code(.swift, start: code.location), "The reply's own two-column indent is not code.")
        XCTAssertEqual(found[4], .code(.swift, start: (text as NSString).range(of: "    foo").location + 2), "Code keeps the indentation it has beyond the reply's.")
        XCTAssertEqual(found[5], .none, "A blank line inside the fence is a blank line.")
        XCTAssertEqual(found[6], .fence)
        XCTAssertEqual(found[8], .none)
    }

    func testAFenceWithAnUnknownLanguageOrNoneColoursNothingButStillPairs() {
        let text = ["⏺ A:", "  ```", "  no se colorea", "  ```", "  ```brainfuck", "  ++>", "  ```", "  texto"].joined(separator: "\n")
        // Inside a fence of a language nobody knows the lines keep their plain look, and no Markdown is read in them.
        XCTAssertEqual(details(text), [.none, .fence, .verbatim, .fence, .fence, .verbatim, .fence, .none])
    }

    func testAReplyThatStartsWithAFenceAndOtherWaysToWriteOne() {
        XCTAssertEqual(details("⏺ ```json\n  {\"a\": 1}\n  ```").map { if case .code = $0 { "code" } else { "\($0)" } }, ["fence", "code", "fence"])
        XCTAssertEqual(details("⏺ Mira:\n  ~~~python\n  x = 1\n  ~~~").dropFirst().first, .fence)
        XCTAssertEqual(details("⏺ Usa ```code``` en línea\n  y ```otra```").map { $0 }, [.none, .none], "Fences in a line of text are inline code.")
    }

    func testAFenceInsideAFenceIsCodeAndTheNextBlockEndsAnOpenOne() {
        let text = ["⏺ Ejemplo:", "  ```markdown", "  ```swift", "  # Título", "  ```", "  luego", "⏺ Otra respuesta", "  sigue", "  ```swift", "  let a = 1", "> Mi mensaje", "  ```swift", "  let b = 2"].joined(separator: "\n")
        let found = details(text)
        XCTAssertEqual(found[1], .fence)
        if case .code(.markdown, _) = found[2] {} else { XCTFail("A fence with a language inside a fence is part of the example: \(found[2])") }
        if case .code(.markdown, _) = found[3] {} else { XCTFail("\(found[3])") }
        XCTAssertEqual(found[4], .fence, "A bare fence closes it.")
        XCTAssertEqual(found[5], .none)
        XCTAssertEqual(found[7], .none, "A new reply starts with no fence open.")
        XCTAssertEqual(found[8], .fence)
        if case .code(.swift, _) = found[9] {} else { XCTFail("\(found[9])") }
        XCTAssertEqual(found[11], .none, "Fences inside a user's message are plain text.")
        XCTAssertEqual(found[12], .none)
    }

    func testFencesInResultsAndToolsAreNotFences() {
        let text = ["⏺ Bash(cat README.md)", "  ⎿  ```swift", "     let a = 1", "     ```", "⏺ Listo", "  ⎿  ```", "  ```swift", "  let b = 2"].joined(separator: "\n")
        for detail in details(text) { XCTAssertEqual(detail, .none) }
    }

    // MARK: Reading from any line

    func testDetailsFromAnyLineMatchTheWholePass() {
        let samples = [
            edit() + "\n\n" + TranscriptFixtures.render(TranscriptFixtures.newFile()) + "\n\n⏺ Hecho",
            "⏺ Mira:\n  ```swift\n  let a = 1\n\n  let b = 2\n  ```\n  texto\n  ```python\n  x = 1\n⏺ Otra\n  y\n  ```\n  z",
            "  ⎿  Actualizado a.swift (+1 -1)\n       1 - a\n       1 + b\n⏺ Bash(x)\n  ⎿  hola\n       2 + falso\n\n  ⎿  Creado b.md (1 línea)\n       1   hola",
            "⏺ A\n  ```js\n  1\n  ⎿  Done\n  2\n  ```\n  3\n  ```\n  4",
        ]
        for text in samples {
            let ns = text as NSString
            let all = TranscriptClassifier.lines(in: ns)
            for index in all.indices {
                let tail = TranscriptClassifier.lines(in: ns, from: all[index].range.location)
                XCTAssertEqual(tail.map(\.detail), all[index...].map(\.detail), "from line \(index) of \(text.debugDescription)")
                XCTAssertEqual(tail.map(\.role), all[index...].map(\.role))
            }
        }
    }
}

@MainActor
final class ChangeStylerTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let palette = TranscriptPalette(dark: true)

    private func styled(_ text: String, font: NSFont? = nil, dark: Bool = true) -> NSTextStorage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [.font: font ?? self.font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        TranscriptStyler.restyle(storage, from: 0, dark: dark, font: font ?? self.font)
        return storage
    }

    /// The attributes where `needle` starts (its `occurrence`th time), after `after` when given.
    private func attributes(_ storage: NSTextStorage, _ needle: String, after: String? = nil, occurrence: Int = 0) -> [NSAttributedString.Key: Any] {
        let text = storage.string as NSString
        var from = after.map { NSMaxRange(text.range(of: $0)) } ?? 0
        var range = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            range = text.range(of: needle, range: NSRange(location: from, length: text.length - from))
            from = NSMaxRange(range)
        }
        XCTAssertNotEqual(range.location, NSNotFound, needle)
        return storage.attributes(at: range.location, effectiveRange: nil)
    }

    private var edit: String { TranscriptFixtures.render(TranscriptFixtures.swiftEdit()) }

    func testRemovedAndAddedRowsGetTheirBandsAndMarks() {
        let storage = styled(edit)
        let removed = attributes(storage, "static let expandedWidth: CGFloat = 572")
        let added = attributes(storage, "static let expandedWidth: CGFloat = 600")
        XCTAssertEqual(removed[.transcriptLineFill] as? NSColor, palette.removedFill)
        XCTAssertEqual(added[.transcriptLineFill] as? NSColor, palette.addedFill)
        let context = attributes(storage, "struct NotchGeometry")
        XCTAssertNil(context[.transcriptLineFill], "Context rows have no band.")
        // The whole row is banded: its number, its mark, its code and its line break.
        let text = storage.string as NSString
        let line = text.lineRange(for: text.range(of: "      97 - "))
        XCTAssertNotNil(storage.attribute(.transcriptLineFill, at: line.location, effectiveRange: nil), "Even the row's indent.")
        XCTAssertNotNil(storage.attribute(.transcriptLineFill, at: NSMaxRange(line) - 1, effectiveRange: nil), "And its line break, so a band is unbroken.")
        XCTAssertEqual(storage.attribute(.transcriptLineFill, at: NSMaxRange(line), effectiveRange: nil) as? NSColor, palette.addedFill, "The next row is the added one.")
        // The marks take the colour of what they say.
        XCTAssertEqual(attributes(storage, "-", after: "      97 ")[.foregroundColor] as? NSColor, palette.removedMark)
        XCTAssertEqual(attributes(storage, "+", after: "      97 - ")[.foregroundColor] as? NSColor, palette.addedMark)
        // The number column steps back.
        XCTAssertEqual(attributes(storage, "97", after: "Actualizado")[.foregroundColor] as? NSColor, palette.gutter)
    }

    func testTheCodeOfARowIsColouredByItsLanguage() {
        let storage = styled(edit)
        XCTAssertEqual(attributes(storage, "static", after: "      97 - ")[.foregroundColor] as? NSColor, palette.color(.keyword))
        XCTAssertEqual(attributes(storage, "CGFloat", after: "      97 - ")[.foregroundColor] as? NSColor, palette.color(.type))
        XCTAssertEqual(attributes(storage, "572")[.foregroundColor] as? NSColor, palette.color(.number))
        XCTAssertEqual(attributes(storage, "// never taller")[.foregroundColor] as? NSColor, palette.color(.comment))
        XCTAssertEqual(attributes(storage, "\"top\"")[.foregroundColor] as? NSColor, palette.color(.comment), "A quote inside a comment is comment.")
        XCTAssertEqual(attributes(storage, "expandedWidth", after: "      97 - ")[.foregroundColor] as? NSColor, palette.changedCode, "Names are plain code.")
        // Context code sits back.
        XCTAssertEqual((attributes(storage, "struct")[.foregroundColor] as? NSColor)?.alphaComponent ?? 1, 0.72, accuracy: 0.001)
    }

    func testTheSummaryHighlightsThePathAndColoursTheCounts() {
        let storage = styled(edit)
        XCTAssertEqual(attributes(storage, "Actualizado")[.foregroundColor] as? NSColor, palette.output)
        XCTAssertEqual(attributes(storage, "Sources/Notch.swift", after: "Actualizado")[.foregroundColor] as? NSColor, palette.changePath)
        XCTAssertEqual(attributes(storage, "+7")[.foregroundColor] as? NSColor, palette.addedMark)
        XCTAssertEqual(attributes(storage, "-4")[.foregroundColor] as? NSColor, palette.removedMark)
        XCTAssertEqual(attributes(storage, "⎿")[.foregroundColor] as? NSColor, palette.outputMarker, "The marker keeps its look.")
    }

    func testGapRowsAreDimAndHaveNoBand() {
        let storage = styled(TranscriptFixtures.render(TranscriptFixtures.newFile()))
        let gap = attributes(storage, "+3 líneas")
        XCTAssertEqual(gap[.foregroundColor] as? NSColor, palette.outputMarker)
        XCTAssertNil(gap[.transcriptLineFill])
    }

    func testRowsFollowTheChatSizeAndWrapUnderTheirCode() {
        for size in [9.0, 11.0, 14.0, 18.0] {
            let storage = styled(edit, font: DisplaySettings.chatFont(size: size))
            let code = attributes(storage, "static", after: "      97 - ")
            XCTAssertEqual((code[.font] as? NSFont)?.pointSize ?? 0, max(8, size - 1), accuracy: 0.01, "Rows are a point smaller than the chat, like the tool lines.")
            let paragraph = code[.paragraphStyle] as? NSParagraphStyle
            let column = ("0" as NSString).size(withAttributes: [.font: code[.font] as Any]).width
            // The row's text is 6 + 3 + 3 columns, then the code's own four spaces: wrapped lines hang there.
            XCTAssertEqual(paragraph?.headIndent ?? 0, column * 16, accuracy: 1.0, "size \(size)")
            XCTAssertEqual(paragraph?.firstLineHeadIndent ?? -1, 0)
            // The whole row has the same indent, whatever piece it is.
            let number = attributes(storage, "97", after: "Actualizado")
            XCTAssertEqual((number[.paragraphStyle] as? NSParagraphStyle)?.headIndent, paragraph?.headIndent)
        }
    }

    func testRowsAreResultsAndNeverChangeTheCharacters() {
        let text = edit
        let storage = styled(text)
        XCTAssertEqual(storage.string, text)
        for needle in ["static", "572", "      97 - ", "Notch.swift"] {
            XCTAssertEqual(attributes(storage, needle, after: "Actualizado")[.transcriptRole] as? String, TranscriptRole.toolOutput.rawValue, needle)
        }
        XCTAssertNil(attributes(storage, "static", after: "      97 - ")[.transcriptBubble])
    }

    func testFencedCodeIsColouredAndItsFencesAreDimmed() {
        let storage = styled("⏺ Mira:\n\n  ```swift\n  let a = \"x\" // hola\n  ```\n\n  fuera let")
        XCTAssertEqual(attributes(storage, "let", after: "```swift")[.foregroundColor] as? NSColor, palette.color(.keyword))
        XCTAssertEqual(attributes(storage, "\"x\"")[.foregroundColor] as? NSColor, palette.color(.string))
        XCTAssertEqual(attributes(storage, "// hola")[.foregroundColor] as? NSColor, palette.color(.comment))
        XCTAssertEqual(attributes(storage, "```swift")[.foregroundColor] as? NSColor, palette.output)
        XCTAssertEqual(attributes(storage, "let", after: "fuera")[.foregroundColor] as? NSColor, palette.text, "Text after the fence is a reply again.")
        XCTAssertEqual((attributes(storage, "let", after: "```swift")[.font] as? NSFont)?.pointSize, 11, "Code in a reply keeps the chat's size.")
        XCTAssertNil(attributes(storage, "let", after: "```swift")[.transcriptLineFill])
    }

    func testAReplyThatOpensWithAFenceKeepsClaudesDot() {
        let storage = styled("⏺ ```json\n  {\"a\": 1}\n  ```")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, palette.assistantMarker)
        XCTAssertEqual(attributes(storage, "```json")[.foregroundColor] as? NSColor, palette.output)
        XCTAssertEqual(attributes(storage, "1")[.foregroundColor] as? NSColor, palette.color(.number))
    }

    func testTheLightThemeHasItsOwnBandsAndColours() {
        let light = TranscriptPalette(dark: false)
        let storage = styled(edit, dark: false)
        XCTAssertEqual(attributes(storage, "static let expandedWidth: CGFloat = 572")[.transcriptLineFill] as? NSColor, light.removedFill)
        XCTAssertNotEqual(light.removedFill, palette.removedFill)
        XCTAssertNotEqual(light.color(.keyword), palette.color(.keyword))
    }

    func testRestylingForAnotherThemeOrSizeGivesWhatStylingFromScratchGives() {
        let text = edit + "\n\n" + TranscriptFixtures.render(TranscriptFixtures.newFile()) + "\n\n⏺ Y:\n  ```python\n  x = 1\n  ```\n"
        let recolored = styled(text, dark: true)
        TranscriptStyler.restyle(recolored, from: 0, dark: false, font: font)
        let fresh = styled(text, dark: false)
        XCTAssertEqual(recolored.string, fresh.string)
        for index in 0..<fresh.length {
            XCTAssertTrue((recolored.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(fresh.attributes(at: index, effectiveRange: nil)), "at \(index)")
        }
    }

    // MARK: The band is painted

    func testTheBandIsPaintedAcrossTheWholeWidthOfEveryLineOfARow() throws {
        let view = MirrorTextView.makeTranscriptCapable()
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        let long = String(repeating: "word ", count: 40)
        let text = TranscriptRenderer.change(["filePath": "/a/x.swift", "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": [" a", "-" + long, "+short", " z"]]]], cwd: "/a")!
        let storage = try XCTUnwrap(view.textStorage)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.ensureLayout(for: try XCTUnwrap(view.textContainer))
        let nsText = storage.string as NSString
        /// The rects of the lines a row takes, in the view's coordinates.
        func lines(of row: String) -> [NSRect] {
            let range = nsText.lineRange(for: nsText.range(of: row))
            var found: [NSRect] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                found.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
            }
            return found
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        func isBand(x: CGFloat, y: CGFloat, _ expected: NSColor) -> Bool {
            guard let found = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB), let want = expected.usingColorSpace(.deviceRGB) else { return false }
            return abs(found.redComponent - want.redComponent) < 0.02 && abs(found.greenComponent - want.greenComponent) < 0.02 && abs(found.blueComponent - want.blueComponent) < 0.02
        }
        let removed = lines(of: "      2 - word")
        XCTAssertGreaterThan(removed.count, 1, "The long row wraps.")
        for rect in removed {
            XCTAssertTrue(isBand(x: 296, y: rect.midY, palette.removedFill), "The right end of the line at y \(rect.midY) is banded, far from any text.")
            XCTAssertTrue(isBand(x: 6, y: rect.midY, palette.removedFill), "And its left end.")
        }
        // Lines of one row, and rows one under another, leave no seam.
        for (above, below) in zip(removed, removed.dropFirst()) { XCTAssertEqual(above.maxY, below.minY, accuracy: 0.01) }
        let added = try XCTUnwrap(lines(of: "      2 + short").first)
        XCTAssertTrue(isBand(x: 296, y: added.midY, palette.addedFill))
        XCTAssertEqual(try XCTUnwrap(removed.last).maxY, added.minY, accuracy: 0.01, "The green band starts where the red one ends.")
        let context = try XCTUnwrap(lines(of: "      3   z").first)
        XCTAssertFalse(isBand(x: 296, y: context.midY, palette.addedFill))
        XCTAssertFalse(isBand(x: 296, y: context.midY, palette.removedFill))
    }
}

// MARK: - Incremental restyle and speed

@MainActor
final class ChangeIncrementalTests: XCTestCase {
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private func typing() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }

    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: typing())
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font)
        return storage
    }

    /// What the scroll view does for each update: replace the changed tail, then restyle from there.
    private func update(_ storage: NSTextStorage, to text: String) {
        let old = storage.string as NSString, new = text as NSString
        let common = LiveTerminalScrollView.commonPrefix(old, new)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: common, length: old.length - common), with: NSAttributedString(string: new.substring(from: common), attributes: typing()))
        TranscriptStyler.restyle(storage, from: common, dark: true, font: font)
        storage.endEditing()
    }

    private func assertSame(_ a: NSTextStorage, _ b: NSTextStorage, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.string, b.string, message(), file: file, line: line)
        guard a.string == b.string else { return }
        for index in 0..<a.length where !(a.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(b.attributes(at: index, effectiveRange: nil)) {
            XCTFail("Attributes differ at \(index) in \(a.string.debugDescription). \(message())", file: file, line: line)
            return
        }
    }

    func testAChangeGrowingOneCharacterAtATimeMatchesStylingItWhole() {
        let text = TranscriptFixtures.render(TranscriptFixtures.swiftEdit() + [TranscriptFixtures.reply(TranscriptFixtures.fencedReply)])
        let storage = NSTextStorage(string: "", attributes: typing())
        var shown = ""
        for character in text {
            shown.append(character)
            update(storage, to: shown)
            if shown.hasSuffix("\n") || shown.count % 11 == 0 { assertSame(storage, styled(shown), "after \(shown.count) characters") }
        }
        assertSame(storage, styled(text))
    }

    func testTheResultOfACallReplacesItsPlaceholderInTheTail() {
        // While a tool runs the mirror shows its call and "⎿  …"; the result then takes the placeholder's place.
        let before = "> hola\n\n⏺ Edit(Sources/Notch.swift)\n  ⎿  …\n\n"
        let after = "> hola\n\n" + TranscriptFixtures.render(TranscriptFixtures.swiftEdit()) + "⏺ Listo."
        let storage = styled(before)
        update(storage, to: after)
        assertSame(storage, styled(after))
        update(storage, to: before)
        assertSame(storage, styled(before))
    }

    /// A long mirror the way Claude's record renders it: prompts, replies with a fenced block, edits with a few dozen rows, commands.
    private func bigMirror(characters: Int) -> String {
        var text = ""
        var turn = 0
        while (text as NSString).length < characters {
            var records = [TranscriptFixtures.prompt("Pregunta número \(turn): arregla el notch y agrega una prueba.")]
            records.append(TranscriptFixtures.reply(TranscriptFixtures.fencedReply))
            records.append(TranscriptFixtures.reply("**Cómo queda:** el `código` y *énfasis* con [guía](https://example.com/a_b).\n\n## Pasos de la prueba \(turn)\n\n- **Primero:** corre `swift test` y revisa _todo_\n- Segundo: 2 * 3 * 4 y file_name_here\n  - anidado con `x`\n\nListo."))
            let patch: [[String: Any]] = [["oldStart": 10, "newStart": 10, "lines": (0..<26).map { $0 % 5 == 2 ? "-    let removed\($0) = \($0) // viejo" : $0 % 5 == 3 ? "+    let added\($0) = \"nuevo \($0)\" // cambio" : "     func keep\($0)(value: Int) -> Bool { value > \($0) }" }]]
            records.append(TranscriptFixtures.call("e\(turn)", "Edit", ["file_path": TranscriptFixtures.cwd + "/Sources/File\(turn).swift"]))
            records.append(TranscriptFixtures.result("e\(turn)", "ok", details: ["filePath": TranscriptFixtures.cwd + "/Sources/File\(turn).swift", "structuredPatch": patch]))
            records.append(TranscriptFixtures.call("b\(turn)", "Bash", ["command": "swift test --filter Turn\(turn)"]))
            records.append(TranscriptFixtures.result("b\(turn)", "Executed 14 tests, with 0 failures"))
            text += TranscriptFixtures.render(records)
            turn += 1
        }
        return text
    }

    func testStylingA200kMirrorWithManyChangesIsFastAndTheTailIsCheap() throws {
        let text = bigMirror(characters: 200_000)
        XCTAssertGreaterThanOrEqual((text as NSString).length, 200_000)
        XCTAssertGreaterThan(text.components(separatedBy: "      ").count, 1500, "Many diff rows.")

        let started = Date()
        let storage = styled(text)
        let full = Date().timeIntervalSince(started)
        XCTAssertLessThan(full, 3.0, "A full pass over \((text as NSString).length) characters took \(full) s.")

        // A new edit lands at the end of the mirror: only the tail is restyled.
        let tailText = text + TranscriptFixtures.render(TranscriptFixtures.swiftEdit(id: "tail"))
        let recorder = EditRecorder()
        storage.delegate = recorder
        let tailStarted = Date()
        update(storage, to: tailText)
        let tail = Date().timeIntervalSince(tailStarted)
        XCTAssertLessThan(tail, 0.15, "A tail update on a 200k mirror took \(tail) s.")
        let length = (text as NSString).length
        for range in recorder.edited { XCTAssertGreaterThanOrEqual(range.location, length - 200, "Restyling reached back to \(range.location) of \(length).") }

        // A change's rows arriving one by one at the end stay cheap, and match a full pass at the end.
        recorder.edited.removeAll()
        let grown = tailText + "⏺ Edit(a.swift)\n  ⎿  Actualizado a.swift (+3 -0)\n" + (1...60).map { "      \($0) + let value\($0) = \($0)\n" }.joined()
        let rowsStarted = Date()
        var shown = tailText + "⏺ Edit(a.swift)\n  ⎿  Actualizado a.swift (+3 -0)\n"
        update(storage, to: shown)
        for row in (1...60).map({ "      \($0) + let value\($0) = \($0)\n" }) { shown += row; update(storage, to: shown) }
        let rows = Date().timeIntervalSince(rowsStarted)
        XCTAssertLessThan(rows, 3.0, "Sixty updates on a 200k mirror took \(rows) s.")
        XCTAssertEqual(shown, grown)
        for range in recorder.edited { XCTAssertGreaterThanOrEqual(range.location, (tailText as NSString).length - 200) }
        assertSame(storage, styled(grown))
    }

    func testThemeAndSizeChangesOnA200kMirrorStayBounded() {
        let text = bigMirror(characters: 200_000)
        let storage = styled(text)
        let started = Date()
        TranscriptStyler.restyle(storage, from: 0, dark: false, font: DisplaySettings.chatFont(size: 14))
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 3.0, "Restyling a 200k mirror for a new theme and size took \(seconds) s.")
    }

    func testTheScrollViewAppendsToA200kMirrorQuickly() {
        let text = bigMirror(characters: 200_000)
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 300))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setText(text)
        let more = text + TranscriptFixtures.render(TranscriptFixtures.swiftEdit(id: "again"))
        let started = Date()
        scroll.setText(more)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertLessThan(seconds, 0.5, "Appending a change to a 200k mirror took \(seconds) s, layout included.")
    }
}

/// Records the edited ranges the text storage reports, to see how far back restyling reaches.
private final class EditRecorder: NSObject, NSTextStorageDelegate {
    var edited: [NSRange] = []
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        edited.append(editedRange)
    }
}

// MARK: - The task label

@MainActor
final class TaskLabelTests: XCTestCase {
    private let task = "> Revisa el notch\n  y avisa.\n\n⏺ Empiezo.\n\n> Otro mensaje\n"

    private func scroll(label: String?) -> LiveTerminalScrollView {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setTaskLabel(label)
        return scroll
    }

    private func bubble(_ scroll: LiveTerminalScrollView, at text: String) -> TranscriptBubble? {
        let storage = scroll.textView.textStorage!
        return storage.attribute(.transcriptBubble, at: (storage.string as NSString).range(of: text).location, effectiveRange: nil) as? TranscriptBubble
    }

    func testTheLabelGoesOnTheFirstMessageOnly() {
        let live = scroll(label: "Tarea")
        live.setText(task)
        XCTAssertEqual(bubble(live, at: "Revisa")?.label, "Tarea")
        XCTAssertEqual(bubble(live, at: "y avisa")?.label, "Tarea", "A wrapped line belongs to the same message.")
        XCTAssertNil(bubble(live, at: "Otro")?.label, "Later messages are plain.")
        XCTAssertNotEqual(bubble(live, at: "Revisa"), bubble(live, at: "Otro"))
        // Without a label nothing is added.
        let plain = scroll(label: nil)
        plain.setText(task)
        XCTAssertNil(bubble(plain, at: "Revisa")?.label)
    }

    func testAMessageThatIsNotFirstGetsNoLabel() {
        let live = scroll(label: "Tarea")
        live.setText("⏺ Antes de todo.\n\n> Mi mensaje\n")
        XCTAssertNil(bubble(live, at: "Mi mensaje")?.label, "Only a text that opens with a message has a task.")
    }

    func testTheLabelMakesRoomAboveTheTextAndGivesItBack() {
        let live = scroll(label: nil)
        let usual = live.textView.textContainerInset.height
        live.setText(task)
        live.setTaskLabel("Tarea")
        XCTAssertEqual(live.textView.textContainerInset.height, usual + TranscriptBubble.tabRoom)
        XCTAssertNotNil(bubble(live, at: "Revisa")?.label)
        live.setTaskLabel(nil)
        XCTAssertEqual(live.textView.textContainerInset.height, usual)
        XCTAssertNil(bubble(live, at: "Revisa")?.label, "What is shown is restyled without it.")
    }

    func testUpdatesKeepTheLabelAndMatchAFreshPass() {
        let live = scroll(label: "Tarea")
        live.setText("> Revisa el notch")
        live.setText("> Revisa el notch\n  y avisa.\n")
        live.setText(task)
        live.setText(task + "\n⏺ Más texto.")
        let fresh = scroll(label: "Tarea")
        fresh.setText(task + "\n⏺ Más texto.")
        let a = live.textView.textStorage!, b = fresh.textView.textStorage!
        XCTAssertEqual(a.string, b.string)
        for index in 0..<a.length {
            XCTAssertTrue((a.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(b.attributes(at: index, effectiveRange: nil)), "at \(index)")
        }
        // Setting the label after the text gives the same as before it.
        let late = scroll(label: nil)
        late.setText(task + "\n⏺ Más texto.")
        late.setTaskLabel("Tarea")
        let c = late.textView.textStorage!
        for index in 0..<c.length {
            XCTAssertTrue((c.attributes(at: index, effectiveRange: nil) as NSDictionary).isEqual(b.attributes(at: index, effectiveRange: nil)), "late, at \(index)")
        }
    }

    func testTheTabIsPaintedAboveTheFirstMessage() throws {
        let live = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        live.setTheme(dark: true, transcript: true)
        live.setTaskLabel("Tarea")
        live.setText("> Revisa el notch")
        live.layoutSubtreeIfNeeded()
        let view = live.textView
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // The tab stands in the room above the message: something is drawn there (the tab's fill and its word), nothing without a label.
        func inked(_ view: NSTextView, _ rep: NSBitmapImageRep) -> Int {
            var count = 0
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            for y in 0..<Int(view.textContainerOrigin.y * scale) - 2 { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { count += 1 } }
            return count
        }
        XCTAssertGreaterThan(inked(view, rep), 80)
        live.setTaskLabel(nil)
        live.layoutSubtreeIfNeeded()
        let bare = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bare)
        XCTAssertEqual(inked(view, bare), 0, "No label, nothing above the message.")
    }
}
