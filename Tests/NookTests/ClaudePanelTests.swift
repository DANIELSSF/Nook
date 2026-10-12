import AppKit
import XCTest
@testable import Nook

/// The screens Claude draws its panels with, as the tests and the renders share them. They are the shapes Claude Code shows (what
/// its source and its users' screens say), not captures of a real session.
enum ClaudePanelFixtures {
    static let wide = String(repeating: "─", count: 110)

    /// Sample's /usage (Claude Code 2.1.288, fullscreen, a 110-column terminal): Settings with its Usage tab open. The bars are
    /// Claude's own: blocks for the filled part (with one partial block) and plain spaces for the rest.
    static var usage: String {
        ["✻ Waiting for 1 background agent to finish", wide, "",
         "   Settings   Status   Config   Usage   Stats", "",
         "   Session", "",
         "   Total cost:            $253.64",
         "   Total duration (API):  9h 56m 36s",
         "   Total duration (wall): 15h 2m 11s",
         "   Total code changes:    1523 lines added, 212 lines removed",
         "   Usage by model:",
         "        claude-opus-5-5:  17.9k input, 888.7k output, 41.3m cache read ($87.40)",
         "      claude-sonnet-5-5:  2.1k input, 120.4k output, 3.2m cache read ($4.12)", "",
         "   Plugin skill-listing footprint", "   12 plugins · 41 skills · about 6.2k tokens per session", "",
         "   Current session",
         "   " + "█████████▎" + String(repeating: " ", count: 40) + " 25% used",
         "   Resets 8:59pm (America/Bogota)", "",
         "   Current week (all models)",
         "   " + String(repeating: "█", count: 33) + "▍" + String(repeating: " ", count: 16) + " 67% used",
         "   Resets Oct 7, 9am (America/Bogota)", "",
         "   Current week (Sonnet only)",
         "   " + String(repeating: "█", count: 48) + "▌" + " 98% used",
         "   Resets Oct 7, 9am (America/Bogota)",
         String(repeating: " ", count: 100) + "↓"].joined(separator: "\n")
    }

    /// A short Usage tab with more content below it: the "↓" at the end.
    static var short: String {
        ["✻ Waiting for 1 background agent to finish", wide, "",
         "   Settings   Status   Config   Usage   Stats", "",
         "   Current session",
         "   " + "█████████▎" + String(repeating: " ", count: 40) + " 25% used",
         "   Resets 8:59pm (America/Bogota)", "",
         "   Current week (all models)",
         "   " + String(repeating: "█", count: 33) + "▍" + String(repeating: " ", count: 16) + " 67% used",
         String(repeating: " ", count: 100) + "↓"].joined(separator: "\n")
    }

    /// Claude's older boxed dialog with a tab row and a hint.
    static var boxed: String {
        let inner = 62
        func row(_ text: String) -> String { "│ " + text + String(repeating: " ", count: max(0, inner - 1 - text.count)) + "│" }
        return ["╭" + String(repeating: "─", count: inner) + "╮",
                row("Settings:  Status   Config   Usage"), row(""),
                row("Version:        2.1.288"), row("Session ID:     9f1c2a7e-41d0-4b7e-9c52-0d1f6a2e8b13"),
                row("cwd:            /Users/developer/Documents/Examples/New project"),
                row("Login method:   Claude Max Account"), row("Model:          Default Opus 5.5 · Most capable"),
                row("MCP servers:    playwright ✔, figma ✔, notion ✘"),
                "╰" + String(repeating: "─", count: inner) + "╯",
                "  ←/→ tab to switch · Esc to exit"].joined(separator: "\n")
    }

    /// Settings' Config tab: a search box and a list with the cursor on its second row (Claude's "❯").
    static var list: String {
        [String(repeating: "─", count: 100), "",
         "   Settings   Status   Config   Usage   Stats", "",
         "   ╭" + String(repeating: "─", count: 60) + "╮", "   │ ⌕ Search settings…" + String(repeating: " ", count: 40) + "│", "   ╰" + String(repeating: "─", count: 60) + "╯",
         "     Auto-compact                       true",
         "   ❯ Verbose output                     false",
         "     Theme                              Dark mode",
         "     Notifications                      Auto",
         "     Editor mode                        normal",
         "     Thinking mode                      true",
         "     Output style                       default",
         "     Default permission mode            Accept edits",
         "     Respect .gitignore in file picker  true",
         "     Show turn duration                 true"].joined(separator: "\n")
    }

    /// A ruled panel ending in Claude's key hint, with no tabs.
    static var ruled: String {
        [String(repeating: "─", count: 60), " Usage", "", " Current week (all models)", " ██████░░░░ 61% used · resets Oct 7", "", " Esc to cancel"].joined(separator: "\n")
    }

    /// What the tab shows once the panel is closed: the conversation and Claude's box again.
    static var closed: String {
        ["> /usage", "", "⏺ Listo.", "", String(repeating: "─", count: 80), "❯ ", String(repeating: "─", count: 80), "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
    }

    static func screen(_ panel: String) -> String { "> /usage\n\n" + panel }
}

final class ClaudePanelTests: XCTestCase {
    private func parsed(_ screen: String) throws -> ClaudePanel {
        ClaudePanel(try XCTUnwrap(ClaudeComposer.split(ClaudePanelFixtures.screen(screen)).panel))
    }

    // MARK: Sample's /usage

    func testSamplesUsageScreenBecomesTabsHeadingsValuesAndBars() throws {
        let panel = try parsed(ClaudePanelFixtures.usage)
        // Claude's rule and the blank line after it are the card's frame; the row of tabs leads.
        guard case .tabs(let title, let names, let active) = panel.rows[0] else { return XCTFail("\(panel.rows[0])") }
        XCTAssertEqual(title, "Settings")
        XCTAssertEqual(names, ["Status", "Config", "Usage", "Stats"])
        XCTAssertEqual(active, 2, "What the panel shows is the Usage tab's: it is the open one.")
        XCTAssertEqual(panel.name, "Settings · Usage")
        XCTAssertEqual(panel.rows[1], .blank)
        XCTAssertEqual(panel.rows[2], .heading(indent: 0, text: "Session"))
        XCTAssertEqual(panel.rows[4], .text(indent: 0, label: "Total cost:            ", body: "$253.64"), "Columns kept: the label carries its gap.")
        XCTAssertEqual(panel.rows[8], .heading(indent: 0, text: "Usage by model:"), "A label that opens an indented block names it.")
        XCTAssertEqual(panel.rows[9], .text(indent: 5, label: "claude-opus-5-5:  ", body: "17.9k input, 888.7k output, 41.3m cache read ($87.40)"))
        XCTAssertEqual(panel.rows[10], .text(indent: 3, label: "claude-sonnet-5-5:  ", body: "2.1k input, 120.4k output, 3.2m cache read ($4.12)"), "Indents are relative to the panel's own margin.")

        let bars = panel.rows.compactMap { row -> (Double, String)? in if case .bar(_, _, let fraction, let trailing) = row { (fraction, trailing) } else { nil } }
        XCTAssertEqual(bars.map(\.1), ["25% used", "67% used", "98% used"])
        XCTAssertEqual(bars.map(\.0), [0.25, 0.67, 0.98], "The percent Claude prints is the bar's value.")
        let index = try XCTUnwrap(panel.rows.firstIndex { if case .bar = $0 { true } else { false } })
        XCTAssertEqual(panel.rows[index - 1], .heading(indent: 0, text: "Current session"))
        XCTAssertEqual(panel.rows[index + 1], .caption(indent: 0, text: "Resets 8:59pm (America/Bogota)"), "The line under a bar is Claude's dim caption.")

        XCTAssertTrue(panel.moreBelow, "The lone ↓ at the right edge means Claude has more below.")
        XCTAssertFalse(panel.moreAbove)
        XCTAssertFalse(panel.rows.contains { ClaudePanel.text(of: $0) == "↓" }, "…and it is a flag, not a row of text.")
        XCTAssertEqual(panel.rows.last, .caption(indent: 0, text: "Resets Oct 7, 9am (America/Bogota)"), "No rule or blank line trails the panel.")
        XCTAssertEqual(panel.columns, 5 + "claude-opus-5-5:  17.9k input, 888.7k output, 41.3m cache read ($87.40)".count, "The widest text row, for fitting the font.")
        XCTAssertNil(panel.cursorIndex)
    }

    func testTheOpenTabIsOnlyNamedWhenThePanelShowsWhichItIs() throws {
        let names = ["Status", "Config", "Usage", "Stats"]
        XCTAssertEqual(ClaudePanel.activeTab(among: names, content: ["Version: 2.1.288", "Session ID: abc", "Login method: Max"]), 0)
        XCTAssertEqual(ClaudePanel.activeTab(among: names, content: ["Search settings…", "Auto-compact   true", "Verbose output  false"]), 1)
        XCTAssertEqual(ClaudePanel.activeTab(among: names, content: ["Current session", "25% used", "Resets 8:59pm"]), 2)
        XCTAssertEqual(ClaudePanel.activeTab(among: names, content: ["Favorite model: Opus", "Total tokens: 1.2m", "Longest session: 2h"]), 3)
        XCTAssertNil(ClaudePanel.activeTab(among: names, content: ["Something Claude added later", "with no clue in it"]), "Nothing matches: nothing is claimed.")
        XCTAssertNil(ClaudePanel.activeTab(among: names, content: ["Version: 2.1.288", "Current session"]), "A tie is not an answer.")
        XCTAssertEqual(ClaudePanel.activeTab(among: names, content: ["Version: 2.1.288", "Session ID: abc", "Current session"]), 0, "The one with the most clues wins.")
        XCTAssertNil(ClaudePanel.activeTab(among: ["Foo", "Bar", "Baz"], content: ["Version: 1"]), "Tabs the table does not know are never picked.")
        let unknown = ClaudePanel("   Settings   Status   Config   Usage   Stats\n\n   Something else entirely\n   Esc to close")
        guard case .tabs(_, _, let active) = unknown.rows[0] else { return XCTFail() }
        XCTAssertNil(active)
        XCTAssertEqual(unknown.name, "Settings", "Without an open tab the name is the dialog's.")
    }

    // MARK: Boxes, rules and hints

    func testABoxLosesItsFrameAndKeepsItsRows() throws {
        let panel = try parsed(ClaudePanelFixtures.boxed)
        guard case .tabs(let title, let names, _) = panel.rows[0] else { return XCTFail("\(panel.rows[0])") }
        XCTAssertEqual(title, "Settings", "The title's colon is Claude's punctuation.")
        XCTAssertEqual(names, ["Status", "Config", "Usage"])
        XCTAssertEqual(panel.rows[2], .text(indent: 0, label: "Version:        ", body: "2.1.288"))
        XCTAssertEqual(panel.rows[3], .text(indent: 0, label: "Session ID:     ", body: "9f1c2a7e-41d0-4b7e-9c52-0d1f6a2e8b13"))
        XCTAssertEqual(panel.rows.last, .hint("←/→ tab to switch · Esc to exit"), "Claude's own hint stays, quiet, at the end.")
        XCTAssertFalse(panel.rows.contains { ClaudePanel.text(of: $0)?.contains("│") == true }, "The side bars are gone.")
        XCTAssertEqual(panel.rows.filter { $0 == .rule }.count, 1, "The box's top edge is the card's own; its bottom edge is a rule before the hint.")
        XCTAssertEqual(panel.rows[panel.rows.count - 2], .rule)
        XCTAssertEqual(panel.name, "Settings · Status", "Version and session id are what Status shows.")
    }

    func testARuleBetweenRowsStaysAndOneAtTheEdgesGoes() throws {
        let rule = String(repeating: "─", count: 30)
        let panel = ClaudePanel([rule, " Heading", "", " one", rule, " two", rule].joined(separator: "\n"))
        XCTAssertEqual(panel.rows, [.heading(indent: 0, text: "Heading"), .blank, .text(indent: 0, label: "", body: "one"), .rule, .text(indent: 0, label: "", body: "two")])
        XCTAssertEqual(ClaudePanel("").rows, [])
        XCTAssertEqual(ClaudePanel("\n\n").rows, [])
        XCTAssertTrue(ClaudePanel("").isEmpty)
        XCTAssertEqual(ClaudePanel(" a\n\n\n\n b").rows.count, 3, "Runs of blank lines are one.")
    }

    func testARuledPanelWithoutTabsIsNamedByItsHeading() throws {
        let panel = try parsed(ClaudePanelFixtures.ruled)
        XCTAssertEqual(panel.name, "Usage")
        XCTAssertEqual(panel.rows.first, .heading(indent: 0, text: "Usage"))
        XCTAssertEqual(panel.rows.last, .hint("Esc to cancel"))
        guard case .bar(_, _, let fraction, let trailing) = panel.rows[3] else { return XCTFail("\(panel.rows[3])") }
        XCTAssertEqual(fraction, 0.61, accuracy: 0.0001)
        XCTAssertEqual(trailing, "61% used · resets Oct 7")
    }

    func testAKeyHintIsOnlyAHintAtTheEnd() {
        let panel = ClaudePanel(["Press Esc to cancel the build, then retry.", "", "  one", "  two", "  three", "  four", " Esc to cancel"].joined(separator: "\n"))
        XCTAssertEqual(panel.rows.first, .text(indent: 0, label: "", body: "Press Esc to cancel the build, then retry."), "Inside the panel it is plain text.")
        XCTAssertEqual(panel.rows.last, .hint("Esc to cancel"))
    }

    // MARK: Bars

    private func bar(_ line: String) -> (indent: Int, lead: String, fraction: Double, trailing: String)? {
        // A first line at the edge, so the bar keeps its own indent.
        for row in ClaudePanel("x\n" + line).rows { if case .bar(let indent, let lead, let fraction, let trailing) = row { return (indent, lead, fraction, trailing) } }
        return nil
    }

    func testBarsAreReadFromTheirBlocksAndTheirPercent() throws {
        // Claude's own: blocks, one partial block, then spaces; its "N% used" is the value.
        let block = try XCTUnwrap(bar("  ████████▌" + String(repeating: " ", count: 30) + " 17% used"))
        XCTAssertEqual(block.indent, 2)
        XCTAssertEqual(block.fraction, 0.17, accuracy: 0.0001)
        XCTAssertEqual(block.trailing, "17% used")
        // Shaded empty part, no percent: the blocks are the value.
        let shaded = try XCTUnwrap(bar("██████░░░░"))
        XCTAssertEqual(shaded.fraction, 0.6, accuracy: 0.0001)
        let partial = try XCTUnwrap(bar("███▌░░░░░░"))
        XCTAssertEqual(partial.fraction, 3.5 / 10, accuracy: 0.0001, "A half block is half a cell.")
        // The pill variant.
        XCTAssertEqual(try XCTUnwrap(bar("▰▰▰▰▱▱▱▱▱▱ 40%")).fraction, 0.4, accuracy: 0.0001)
        // A label before the bar.
        let labelled = try XCTUnwrap(bar("Opus  ████░░░░░░ 40%"))
        XCTAssertEqual(labelled.lead, "Opus")
        XCTAssertEqual(labelled.trailing, "40%")
        // A bar at zero is only spaces before "0% used".
        let empty = try XCTUnwrap(bar(String(repeating: " ", count: 53) + "0% used"))
        XCTAssertEqual(empty.fraction, 0)
        XCTAssertEqual(empty.indent, 0)
        // At 1–5% Claude's limit bar is a block or two before the long gap and its percent.
        let low = try XCTUnwrap(bar("  █" + String(repeating: " ", count: 50) + "2% used"))
        XCTAssertEqual(low.fraction, 0.02, accuracy: 0.0001)
        XCTAssertNil(bar("█ 2% used"), "Without the gap it is a line of text.")
        // Full and over-full are kept inside the track.
        XCTAssertEqual(try XCTUnwrap(bar("██████████ 100% used")).fraction, 1)
        XCTAssertEqual(try XCTUnwrap(bar("██████████ 140% used")).fraction, 1)
    }

    func testBlocksThatAreNotABarStayText() {
        XCTAssertNil(bar("██░░██░░██░░"), "A heat map's shades are not a bar.")
        XCTAssertNil(bar("███ 3 files"), "Too short to be a bar.")
        XCTAssertNil(bar("▌ Heading"), "A lone partial block is a decoration.")
        XCTAssertNil(bar("Usage is 25% used of a very long label that goes on and on ██████████ 10%"), "A sentence with blocks in it is a sentence.")
        XCTAssertNil(bar("   Total cost:  $1.25"))
        XCTAssertNil(bar("  25% used"), "The percent alone, without the long gap Claude leaves, is text.")
    }

    // MARK: Cursor rows, labels and headings

    func testTheCursorRowKeepsItsColumnsBesideItsSiblings() throws {
        let panel = try parsed(ClaudePanelFixtures.list)
        let cursor = try XCTUnwrap(panel.cursorIndex)
        XCTAssertEqual(panel.rows[cursor], .cursor(indent: 0, text: "Verbose output                     false"))
        XCTAssertEqual(panel.rows[cursor - 1], .text(indent: 2, label: "", body: "Auto-compact                       true"), "The text after the mark lines up with the rows around it (2 columns in).")
        XCTAssertEqual(panel.name, "Settings · Config")
        XCTAssertEqual(ClaudePanel("   ❯ one\n     two").cursorIndex, 0)
        XCTAssertNil(ClaudePanel("❯not a cursor\n  two").cursorIndex, "The mark is followed by a space.")
        XCTAssertNil(ClaudePanel("  one\n  two").cursorIndex)
    }

    func testOnlyShortLabelsAreSplitFromTheirValues() {
        XCTAssertEqual(ClaudePanel("Version: 2.1.288").rows, [.text(indent: 0, label: "Version: ", body: "2.1.288")])
        XCTAssertEqual(ClaudePanel("Total cost:   $1.25").rows, [.text(indent: 0, label: "Total cost:   ", body: "$1.25")])
        XCTAssertEqual(ClaudePanel("Note that this sentence goes on: and then continues with more words").rows,
                       [.text(indent: 0, label: "", body: "Note that this sentence goes on: and then continues with more words")], "A long sentence with a colon in it stays whole.")
        XCTAssertEqual(ClaudePanel("Time 8:59pm sharp").rows, [.text(indent: 0, label: "", body: "Time 8:59pm sharp")], "A colon with no space after it is a clock.")
        XCTAssertEqual(ClaudePanel("Usage by model:").rows, [.text(indent: 0, label: "", body: "Usage by model:")], "A label with no value is text, a heading only if it opens a block.")
    }

    func testHeadingsAreShortLinesThatNameWhatFollows() {
        let panel = ClaudePanel(["Installed servers", "", "  playwright", "", "A full sentence is a paragraph, not a heading.", "", "Loading…", "", "Servers:", "  a", "  b"].joined(separator: "\n"))
        XCTAssertEqual(panel.rows[0], .heading(indent: 0, text: "Installed servers"))
        XCTAssertEqual(panel.rows[2], .text(indent: 2, label: "", body: "playwright"), "Indented rows are never headings.")
        XCTAssertEqual(panel.rows[4], .text(indent: 0, label: "", body: "A full sentence is a paragraph, not a heading."))
        XCTAssertEqual(panel.rows[6], .text(indent: 0, label: "", body: "Loading…"))
        XCTAssertEqual(panel.rows[8], .heading(indent: 0, text: "Servers:"))
    }

    func testOnlyTheDialogsOwnTabRowIsTabs() {
        let table = ClaudePanel(["Settings   Status   Config   Usage", "", "  a", "  b", "  c", "", "Name   Type   Size", "x   y   z"].joined(separator: "\n"))
        var count = 0
        for row in table.rows { if case .tabs = row { count += 1 } }
        XCTAssertEqual(count, 1, "A table's header lower down is plain text.")
        XCTAssertEqual(table.rows.last, .text(indent: 0, label: "", body: "x   y   z"))
        guard case .tabs(let title, let names, _) = ClaudePanel("Status   Config   Usage").rows[0] else { return XCTFail() }
        XCTAssertNil(title, "With no title word the row is all tabs.")
        XCTAssertEqual(names, ["Status", "Config", "Usage"])
    }

    func testMarksOfMoreContentAboveAndBelow() {
        let panel = ClaudePanel(["      ↑", " one", " two", "           ↓"].joined(separator: "\n"))
        XCTAssertTrue(panel.moreAbove)
        XCTAssertTrue(panel.moreBelow)
        XCTAssertEqual(panel.rows.count, 2)
        XCTAssertFalse(ClaudePanel(" ↓ more files below").moreBelow, "Only a lone mark counts.")
    }

    // MARK: Keys

    func testTheKeysTheIslandHandsToThePanel() {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> TerminalKey? { ClaudePanelKey.key(keyCode: code, modifiers: flags) }
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        XCTAssertEqual(key(123, arrow), .left)
        XCTAssertEqual(key(124, arrow), .right)
        XCTAssertEqual(key(126, arrow), .up)
        XCTAssertEqual(key(125, arrow), .down)
        XCTAssertEqual(key(48), .tab)
        XCTAssertEqual(key(36), .enter)
        XCTAssertEqual(key(76), .enter, "The keypad's Enter too.")
        XCTAssertEqual(key(53), .escape)
        XCTAssertEqual(key(36, [.capsLock]), .enter, "Caps Lock changes nothing.")
        XCTAssertNil(key(48, .shift), "⇧⇥ goes backwards, which the panel's keys do not include.")
        XCTAssertNil(key(123, [.option, .function, .numericPad]), "⌥← is a word jump, not a tab.")
        XCTAssertNil(key(53, .command))
        XCTAssertNil(key(36, .shift))
        XCTAssertNil(key(0), "Letters are not the panel's.")
        let codes: [UInt16] = [123, 124, 125, 126, 48, 36, 53]
        XCTAssertEqual(Set(codes.compactMap { key($0, arrow) }), Set(TerminalKey.panelKeys), "The keys that get through are exactly the panel's.")
    }

    func testEveryPanelKeyHasAHelpAndAccessibilityIsMentionedWhenMissing() {
        for key in TerminalKey.panelKeys {
            let help = ClaudePanelCard.help(for: key, needsAccessibility: false)
            XCTAssertTrue(help.hasPrefix(key.label), help)
            XCTAssertFalse(help.contains("Accesibilidad"))
            XCTAssertEqual(ClaudePanelCard.help(for: key, needsAccessibility: true).contains("Accesibilidad"), key.needsDirectKeys, "Enter works without the permission.")
        }
        XCTAssertTrue(ClaudePanelCard.help(for: .escape, needsAccessibility: false).contains("cerrar el panel"))
    }

    // MARK: Sizes

    func testTheTextShrinksOnlyAsFarAsItMustAndNeverBelowItsFloor() {
        let column = ClaudePanelMetrics.columnWidth(size: 11)
        XCTAssertEqual(column, 11 * ClaudePanelMetrics.advance)
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 40, width: 400, chatSize: 11), 11, "It fits: the user's size.")
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 0, width: 400, chatSize: 11), 11)
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 80, width: 0, chatSize: 11), 11, "No width yet: nothing to fit.")
        let tight = ClaudePanelMetrics.fontSize(columns: 80, width: 80 * ClaudePanelMetrics.columnWidth(size: 10), chatSize: 11)
        XCTAssertEqual(tight, 10, accuracy: 0.26, "Just under 10 pt gets the line exactly in.")
        XCTAssertLessThanOrEqual(CGFloat(tight) * ClaudePanelMetrics.advance * 80, 80 * ClaudePanelMetrics.columnWidth(size: 10) + 0.01, "…and never wider than the room.")
        let floor = ClaudePanelMetrics.fontSize(columns: 400, width: 200, chatSize: 11)
        XCTAssertEqual(floor, 11 * ClaudePanelMetrics.smallestShare, accuracy: 0.01, "Past the floor, long lines wrap instead.")
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 400, width: 200, chatSize: 9), 8, "Never under 8 pt.")
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 400, width: 200, chatSize: 18), 18 * ClaudePanelMetrics.smallestShare, accuracy: 0.01)
        XCTAssertEqual(ClaudePanelMetrics.fontSize(columns: 400, width: 200, chatSize: 7), 7, "A size the user chose under the floor is kept.")
        var last = 0.0
        for width in stride(from: 100.0, through: 900.0, by: 50.0) {
            let size = ClaudePanelMetrics.fontSize(columns: 90, width: CGFloat(width), chatSize: 14)
            XCTAssertGreaterThanOrEqual(size, last, "More room never makes the text smaller.")
            last = size
        }
    }

    func testSamplesScreenFitsEveryIslandAtItsOwnTextSize() throws {
        let panel = try parsed(ClaudePanelFixtures.usage)
        // The widest island text column (the island less the card's inset and the pane's margin) at the Normal and Wide sizes.
        for island in [572.0, 720.0] {
            let width = CGFloat(island) - 2 * 15 - 2 * ClaudePanelCard.inset
            let size = ClaudePanelMetrics.fontSize(columns: panel.columns, width: width, chatSize: 11)
            XCTAssertGreaterThanOrEqual(size, 10.5, "At \(island) pt the widest line (\(panel.columns) columns) fits at the user's size or a hair under it.")
            if island > 600 { XCTAssertEqual(size, 11) }
        }
        let compact = ClaudePanelMetrics.fontSize(columns: panel.columns, width: 500 - 2 * 15 - 2 * ClaudePanelCard.inset, chatSize: 11)
        XCTAssertLessThan(compact, 11, "The Compact island trades a little size for keeping Claude's columns.")
        XCTAssertGreaterThanOrEqual(compact, 11 * ClaudePanelMetrics.smallestShare)
    }
}
