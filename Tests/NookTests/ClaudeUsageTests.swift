import XCTest
@testable import Nook

/// /usage in a Terminal tab narrower than when Claude drew it (Sample's screen of 2026-10-04): the Settings edge in eighth blocks,
/// the "more above" mark at the end of a line, and lines Claude wrapped at its width. Then the panel as meters for Nook's card.
final class ClaudeUsageTests: XCTestCase {
    static let narrow: String = {
        let edge = String(repeating: "▔", count: 118)
        return [edge,
                " Settings:  Status   Config   Usage   Stats", "",
                "  Total duration (wall):  58m 53s" + String(repeating: " ", count: 60) + "↑",
                "  Total code changes:     206 lines added, 18 lines removed",
                "  Usage by model:",
                "      claude-haiku-4-5:  52.9k input, 1.3k output, 0 cache read, 0 cache write ($0.0592)",
                "       claude-opus-5-5:  208 input, 127.6k output, 16.7m cache read, 258.3k cache write ($7.97)",
                "  Prompt cache (main):    103 requests · 98% of input tokens from cache · no misses · warm (1h TTL, last activity 9m",
                "  14s ago)", "",
                "  Plugin skill-listing footprint",
                "  What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP",
                "  tools not yet counted.", "",
                "  Notion                     10 skills · ~301 tok/turn",
                "  codex                      2 skills · ~75 tok/turn", "",
                "  Total                      ~376 tok/turn", "",
                "  Current session",
                "  ███▌" + String(repeating: " ", count: 46) + " 7% used",
                "  Resets 10:30am (America/Bogota)", "",
                "  Current week (all models)",
                "  " + String(repeating: "█", count: 39) + "▌" + String(repeating: " ", count: 10) + " 79% used",
                "  Resets Oct 6 at 6am (America/Bogota)",
                String(repeating: " ", count: 100) + "↓"].joined(separator: "\n")
    }()

    private func texts(_ panel: ClaudePanel) -> [String] { panel.rows.compactMap(ClaudePanel.text(of:)) }

    func testTheEdgeTheMarksAndTheWrappedLinesAreReadAsSuch() {
        let panel = ClaudePanel(Self.narrow)
        XCTAssertFalse(panel.rows.contains { ClaudePanel.text(of: $0)?.contains("▔") == true }, "The block edge is a frame, not text.")
        XCTAssertTrue(panel.moreAbove); XCTAssertTrue(panel.moreBelow)
        let rows = texts(panel)
        XCTAssertTrue(rows.contains("Total duration (wall):  58m 53s"), "No arrow left in the value.")
        XCTAssertTrue(rows.contains { $0.hasSuffix("last activity 9m 14s ago)") }, "The cut line joins the one it continues.")
        XCTAssertTrue(rows.contains { $0.hasSuffix("Agents and MCP tools not yet counted.") })
        XCTAssertFalse(rows.contains("14s ago)"))
        XCTAssertTrue(rows.contains { $0.hasPrefix("claude-opus-5-5:") }, "A row of its own is never joined to the one above.")
        XCTAssertEqual(panel.name, "Settings · Usage")
    }

    func testTheUsagePanelBecomesMetersAndDetails() throws {
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel(Self.narrow)))
        XCTAssertEqual(usage.meters.map(\.title), ["Current session", "Current week (all models)"])
        XCTAssertEqual(usage.meters.map(\.label), ["7% used", "79% used"])
        XCTAssertEqual(usage.meters[0].fraction, 0.07, accuracy: 0.001)
        XCTAssertEqual(usage.meters[1].resets, "Resets Oct 6 at 6am (America/Bogota)")
        let details = usage.details.compactMap(ClaudePanel.text(of:))
        XCTAssertTrue(details.contains("Total code changes:     206 lines added, 18 lines removed"))
        XCTAssertFalse(details.contains { $0.contains("Current session") || $0.contains("Resets") || $0.contains("Status") }, "Meters and tabs are not details.")

        // Sample's other /usage, with three limits.
        let three = try XCTUnwrap(ClaudeUsage(ClaudePanel(ClaudePanelFixtures.usage)))
        XCTAssertEqual(three.meters.map(\.title), ["Current session", "Current week (all models)", "Current week (Sonnet only)"])
        XCTAssertEqual(three.meters.map(\.resets), ["Resets 8:59pm (America/Bogota)", "Resets Oct 7, 9am (America/Bogota)", "Resets Oct 7, 9am (America/Bogota)"])
    }

    func testOtherPanelsAreNotUsage() {
        XCTAssertNil(ClaudeUsage(ClaudePanel(["   Settings   Status   Config   Usage   Stats", "", "   Version: 2.1.289", "   Session ID: abc"].joined(separator: "\n"))))
    }
}
