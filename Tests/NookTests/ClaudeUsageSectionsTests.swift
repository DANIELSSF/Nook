import XCTest
@testable import Nook

/// Claude Code 2.1.293's usage panel (Settings › Usage) as its terminal shows it. `terminal` is Sample's Terminal tab of 120×51
/// (2026-10-08, transcribed from his screenshot): the whole panel but its end, with Claude's "↓" on the last row. `body` is the
/// same panel laid out the way Claude lays it in a Nook tab of 73 columns (its text wrapped at the box's 69, the limits' bars 50
/// wide, the insights' advice one column in), from its first row to its last, with the part below Sample's screen: two tables,
/// the day/week keys, the usage credits and the hint. `screen(top:height:)` is what such a tab shows scrolled to `top`.
enum ClaudeUsageFixtures {
    static let status = "✻ Gallivanting… (5m 32s · ↓ 23.5k tokens)"
    static let tabs = "  Settings  Status   Config   Usage   Stats"

    /// Claude's limit bar: `filled` cells of blocks, the rest of its 50 left as background-coloured spaces, then its percent.
    static func bar(_ filled: Int, _ label: String) -> String {
        String(repeating: "█", count: filled) + String(repeating: " ", count: 50 - filled) + " " + label
    }

    static var terminal: String {
        ["· Gallivanting… (5m 32s · ↓ 23.5k tokens · deep in thought with xhigh effort)",
         String(repeating: "▔", count: 120),
         tabs, "",
         "  Session", "",
         "  Total cost:            $1.75",
         "  Total duration (API):  4m 14s",
         "  Total duration (wall): 8m 16s",
         "  Total code changes:    0 lines added, 0 lines removed",
         "  Usage by model:",
         "      claude-haiku-5-5:  1.4k input, 381 output, 0 cache read, 0 cache write ($0.0003)",
         "       claude-opus-5-5:  44 input, 23.5k output, 2.0m cache read, 110.7k cache write ($1.75)",
         "  Prompt cache (main):   22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m",
         "  11s ago)", "", "",
         "  Plugin skill-listing footprint",
         "  What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP",
         "  tools not yet counted.", "",
         "  Notion                     10 skills · ~301 tok/turn",
         "  codex                      2 skills · ~75 tok/turn", "",
         "  Total                      ~376 tok/turn", "",
         "  Current session",
         "  " + bar(14, "28% used"),
         "  Resets 1pm (America/Bogota)", "",
         "  Current week (all models)",
         "  " + bar(37, "74% used"),
         "  Resets Oct 13 at 6am (America/Bogota)", "",
         "  Current week (Fable)",
         "  " + bar(0, "0% used"),
         "  Resets Oct 13 at 6am (America/Bogota)", "",
         "  What's contributing to your limits usage?",
         "  Approximate, based on local sessions on this machine — does not include other devices or claude.ai", "",
         "  Last 24h · these are independent characteristics of your usage, not a breakdown", "",
         "  89% of your usage was at >150k context",
         "   Longer sessions are more expensive even when cached. /compact mid-task, /clear",
         "   when switching to new tasks.", "",
         "  80% of your usage came from sessions active for 8+ hours",
         "   These are often background/loop sessions. Continuous usage can add up quickly",
         "   so make sure it is intentional.",
         String(repeating: " ", count: 118) + "↓"].joined(separator: "\n")
    }

    /// Greedy word wrap at `width`, as Ink wraps a text box: a line that fits stays as it is (its own spacing included).
    static func wrap(_ text: String, width: Int) -> [String] {
        guard text.count > width else { return [text] }
        let head = Array(text)
        var cut = width
        while cut > 0, head[cut] != " " { cut -= 1 }
        if cut == 0 { cut = width }
        let first = String(head[..<cut]).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        let rest = String(head[cut...]).trimmingCharacters(in: .whitespaces)
        return [first] + wrap(rest, width: width)
    }

    /// Every row of the panel's scrolling part in a 73-column Nook tab.
    static var body: [String] {
        let width = 69
        var rows: [String] = []
        func line(_ text: String, indent: Int = 0) {
            rows += wrap(text, width: width - indent).map { "  " + String(repeating: " ", count: indent) + $0 }
        }
        func blank(_ count: Int = 1) { rows += Array(repeating: "", count: count) }
        line("Session"); blank()
        line("Total cost:            $1.75")
        line("Total duration (API):  4m 14s")
        line("Total duration (wall): 8m 16s")
        line("Total code changes:    0 lines added, 0 lines removed")
        line("Usage by model:")
        line("    claude-haiku-5-5:  1.4k input, 381 output, 0 cache read, 0 cache write ($0.0003)")
        line("     claude-opus-5-5:  44 input, 23.5k output, 2.0m cache read, 110.7k cache write ($1.75)")
        line("Prompt cache (main):   22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)")
        blank(2)
        line("Plugin skill-listing footprint")
        line("What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP tools not yet counted.")
        blank()
        line("Notion                     10 skills · ~301 tok/turn")
        line("codex                      2 skills · ~75 tok/turn")
        blank()
        line("Total                      ~376 tok/turn")
        blank()
        line("Current session"); line(bar(14, "28% used")); line("Resets 1pm (America/Bogota)"); blank()
        line("Current week (all models)"); line(bar(37, "74% used")); line("Resets Oct 13 at 6am (America/Bogota)"); blank()
        line("Current week (Fable)"); line(bar(0, "0% used")); line("Resets Oct 13 at 6am (America/Bogota)"); blank()
        line("What's contributing to your limits usage?")
        line("Approximate, based on local sessions on this machine — does not include other devices or claude.ai")
        blank()
        line("Last 24h · these are independent characteristics of your usage, not a breakdown")
        blank()
        line("89% of your usage was at >150k context")
        line("Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.", indent: 1)
        blank()
        line("80% of your usage came from sessions active for 8+ hours")
        line("These are often background/loop sessions. Continuous usage can add up quickly so make sure it is intentional.", indent: 1)
        blank()
        line("Skills                    % of usage")
        line("/review                        42%")
        line("/simplify                      12%")
        blank()
        line("Subagents                 % of usage")
        line("general-purpose                61%")
        line("Explore                         9%")
        blank()
        line("d to day · w to week")
        blank()
        line("Usage credits")
        line("Usage credits are off · /usage-credits to turn them on")
        blank()
        line("Esc to cancel")
        return rows
    }

    static let columns = 73
    static let head = [status, String(repeating: "▔", count: columns), tabs, ""]

    /// A 73-column tab's screen with the panel scrolled to `top`, `height` rows of it on show, and Claude's marks where it has them
    /// (none when it runs over by two rows or less).
    static func screen(top: Int, height: Int, body: [String] = body) -> String {
        var window = Array(body[min(top, body.count)..<min(body.count, top + height)])
        window += Array(repeating: "", count: max(0, height - window.count))
        let overflow = body.count - height > 2
        if overflow, top > 0 { window[0] = marked(window[0], "↑") }
        if overflow, top < body.count - height { window[height - 1] = marked(window[height - 1], "↓") }
        return (head + window).joined(separator: "\n")
    }

    static func marked(_ line: String, _ mark: String) -> String {
        let column = columns - 2
        return (line.count < column ? line + String(repeating: " ", count: column - line.count) : String(line.prefix(column))) + mark
    }

    /// The whole panel on one screen tall enough for it: what a complete reading must equal.
    static var whole: String { (head + body).joined(separator: "\n") }

    static func usage(_ screen: String) -> ClaudeUsage? {
        ClaudeComposer.split(screen).panel.map(ClaudePanel.init).flatMap(ClaudeUsage.init)
    }
}

final class ClaudeUsageSectionsTests: XCTestCase {
    private typealias Fixtures = ClaudeUsageFixtures

    // MARK: Sample's screen

    func testSamplesTerminalScreenReadsAsSectionsWithNothingLeftOver() throws {
        let usage = try XCTUnwrap(Fixtures.usage(Fixtures.terminal))

        XCTAssertEqual(usage.meters, [
            .init(title: "Current session", fraction: 0.28, label: "28% used", resets: "Resets 1pm (America/Bogota)"),
            .init(title: "Current week (all models)", fraction: 0.74, label: "74% used", resets: "Resets Oct 13 at 6am (America/Bogota)"),
            .init(title: "Current week (Fable)", fraction: 0, label: "0% used", resets: "Resets Oct 13 at 6am (America/Bogota)"),
        ])

        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.cost, "$1.75"); XCTAssertNil(session.costNote)
        XCTAssertEqual(session.apiDuration, "4m 14s")
        XCTAssertEqual(session.wallDuration, "8m 16s")
        XCTAssertEqual(session.linesAdded, 0); XCTAssertEqual(session.linesRemoved, 0)
        XCTAssertEqual(session.models, [
            .init(name: "claude-haiku-5-5", input: "1.4k", output: "381", cacheRead: "0", cacheWrite: "0", cost: "$0.0003"),
            .init(name: "claude-opus-5-5", input: "44", output: "23.5k", cacheRead: "2.0m", cacheWrite: "110.7k", cost: "$1.75"),
        ])
        XCTAssertEqual(session.promptCache, "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)",
                       "The line Claude wrapped is one piece.")
        XCTAssertEqual(session.other, [])

        let footprint = try XCTUnwrap(usage.footprint)
        XCTAssertEqual(footprint.title, "Plugin skill-listing footprint")
        XCTAssertEqual(footprint.note, "What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP tools not yet counted.")
        XCTAssertEqual(footprint.plugins, [.init(name: "Notion", detail: "10 skills · ~301 tok/turn", skills: 10, tokens: 301),
                                           .init(name: "codex", detail: "2 skills · ~75 tok/turn", skills: 2, tokens: 75)])
        XCTAssertEqual(footprint.total, "~376 tok/turn"); XCTAssertEqual(footprint.totalTokens, 376); XCTAssertNil(footprint.totalNote)

        let insights = try XCTUnwrap(usage.insights)
        XCTAssertEqual(insights.title, "What's contributing to your limits usage?")
        XCTAssertEqual(insights.note, "Approximate, based on local sessions on this machine — does not include other devices or claude.ai")
        XCTAssertEqual(insights.window, "Last 24h · these are independent characteristics of your usage, not a breakdown")
        XCTAssertEqual(insights.items, [
            .init(headline: "89% of your usage was at >150k context",
                  advice: "Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.", share: 0.89),
            .init(headline: "80% of your usage came from sessions active for 8+ hours",
                  advice: "These are often background/loop sessions. Continuous usage can add up quickly so make sure it is intentional.", share: 0.8),
        ], "Advice Claude wrapped at 80 columns is one piece.")
        XCTAssertEqual(insights.tables, []); XCTAssertEqual(insights.messages, [])

        XCTAssertEqual(usage.leftovers, [], "Every line on Sample's screen has its place.")
        XCTAssertFalse(usage.complete, "Claude's ↓: the panel goes on below.")
        XCTAssertFalse(usage.details.contains { ClaudePanel.text(of: $0)?.contains("% used") == true }, "The former details still leave the meters out.")
        XCTAssertTrue(usage.details.contains { ClaudePanel.text(of: $0)?.hasPrefix("Total cost:") == true })
    }

    // MARK: A Nook tab

    func testTheWholePanelInANookTabReadsToItsEnd() throws {
        let usage = try XCTUnwrap(Fixtures.usage(Fixtures.whole))
        XCTAssertTrue(usage.complete)
        XCTAssertEqual(usage.meters.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertEqual(usage.meters.map(\.fraction), [0.28, 0.74, 0])
        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.models.map(\.name), ["claude-haiku-5-5", "claude-opus-5-5"], "Model lines wrapped at 69 columns are whole again.")
        XCTAssertEqual(session.models.last?.cacheWrite, "110.7k"); XCTAssertEqual(session.models.last?.cost, "$1.75")
        XCTAssertEqual(session.promptCache, "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)")
        XCTAssertEqual(usage.footprint?.note, "What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP tools not yet counted.")
        let insights = try XCTUnwrap(usage.insights)
        XCTAssertEqual(insights.note, "Approximate, based on local sessions on this machine — does not include other devices or claude.ai")
        XCTAssertEqual(insights.window, "Last 24h · these are independent characteristics of your usage, not a breakdown")
        XCTAssertEqual(insights.items.map(\.headline), ["89% of your usage was at >150k context", "80% of your usage came from sessions active for 8+ hours"])
        XCTAssertEqual(insights.items.map(\.advice), ["Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.",
                                                      "These are often background/loop sessions. Continuous usage can add up quickly so make sure it is intentional."])
        XCTAssertEqual(insights.tables, [
            .init(title: "Skills", columns: ["% of usage"], rows: [.init(name: "/review", values: ["42%"]), .init(name: "/simplify", values: ["12%"])]),
            .init(title: "Subagents", columns: ["% of usage"], rows: [.init(name: "general-purpose", values: ["61%"]), .init(name: "Explore", values: ["9%"])]),
        ])
        XCTAssertEqual(usage.leftovers, [.heading(indent: 0, text: "Usage credits"), .text(indent: 0, label: "", body: "Usage credits are off · /usage-credits to turn them on")],
                       "What this does not know stays, in order; the day/week keys and Esc's hint do not.")
    }

    func testThe32RowScreenOfANookTabReadsAsFarAsItGoes() throws {
        let screen = Fixtures.screen(top: 0, height: 28)
        XCTAssertEqual(screen.components(separatedBy: "\n").count, 32)
        let usage = try XCTUnwrap(Fixtures.usage(screen))
        XCTAssertFalse(usage.complete)
        XCTAssertEqual(usage.session?.models.count, 2)
        XCTAssertEqual(usage.footprint?.plugins.count, 2)
        XCTAssertEqual(usage.meters.map(\.title), ["Current session"], "Only the first limit made it on screen.")
        XCTAssertNil(usage.insights)
        XCTAssertEqual(usage.leftovers, [])
    }

    func testAWindowWithoutAnyBarIsStillTheUsagePanel() throws {
        // 18 rows: the session and the footprint's title, no limit.
        let usage = try XCTUnwrap(Fixtures.usage(Fixtures.screen(top: 0, height: 18)))
        XCTAssertEqual(usage.meters, [])
        XCTAssertNotNil(usage.session)
        // Scrolled to the end: only the insights' tail and what follows them.
        let tail = try XCTUnwrap(Fixtures.usage(Fixtures.screen(top: Fixtures.body.count - 20, height: 20)))
        XCTAssertEqual(tail.insights?.tables.count, 2)
        XCTAssertEqual(tail.insights?.title, "What's contributing to your limits usage?", "No title on screen: Claude's own is assumed.")
        XCTAssertFalse(tail.complete)
        // The Usage tab open on nothing this knows yet is the usage panel too.
        let loading = try XCTUnwrap(ClaudeUsage(ClaudePanel([String(repeating: "▔", count: 73), Fixtures.tabs, "", "  Loading usage data…", "", "  Esc to cancel",
                                                             "", "  Current session · 3% used"].joined(separator: "\n"))))
        XCTAssertEqual(loading.leftovers.compactMap(ClaudePanel.text(of:)), ["Loading usage data…", "Current session · 3% used"])
    }

    func testInATerminalOf80RowsThePanelIsFoundFromItsOwnEdge() throws {
        // 76 rows of panel under the status line, the edge and the tab row: the tab row is more than 60 lines above the last.
        let screen = Fixtures.screen(top: 0, height: 76)
        XCTAssertEqual(screen.components(separatedBy: "\n").count, 80)
        let panel = try XCTUnwrap(ClaudeComposer.split(screen).panel)
        XCTAssertTrue(panel.hasPrefix(String(repeating: "▔", count: 73) + "\n" + Fixtures.tabs), "From its edge, tab row included.")
        let usage = try XCTUnwrap(Fixtures.usage(screen))
        XCTAssertTrue(usage.complete)
        XCTAssertEqual(usage.session?.cost, "$1.75", "The top of the panel is not lost.")
        XCTAssertEqual(usage.meters.count, 3)
        // An old tab row above a reply is not this screen's panel: past the reply, the conversation went on.
        let old = ([String(repeating: "▔", count: 73), Fixtures.tabs, "", "  Session", "  Total cost:   $1.75", "", "⏺ Listo, cerré el panel."]
            + (1...70).map { "  línea \($0) de la salida" } + ["", "  Esc to cancel"]).joined(separator: "\n")
        XCTAssertFalse(ClaudeComposer.split(old).panel?.contains("Settings") ?? false)
    }

    func testOtherTabsAreNeverUsage() {
        XCTAssertNil(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Version: 2.1.293", "  Session ID: abc", "  Login method: Claude Max Account"].joined(separator: "\n"))))
        XCTAssertNil(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Favorite model: Opus 5.5", "  Total tokens: 12.3m", "  Longest session: 9h"].joined(separator: "\n"))))
    }

    // MARK: Limits as Claude draws them

    func testANarrowTerminalPutsTheResetBesideTheTitleAndThePercentUnderTheBar() throws {
        // Under 64 columns: the title and its reset on one line, the bar on its own, the percent under it; at 0% the bar is spaces.
        let panel = ClaudePanel([Fixtures.tabs, "",
                                 "  Current session · Resets 1pm (America/Bogota)",
                                 "  " + String(repeating: "█", count: 17),
                                 "  28% used", "",
                                 "  Current week (Fable) · Resets Oct 13 at 6am (America/Bogota)",
                                 "  You are close to this limit",
                                 "  " + String(repeating: " ", count: 60),
                                 "  0% used"].joined(separator: "\n"))
        let usage = try XCTUnwrap(ClaudeUsage(panel))
        XCTAssertEqual(usage.meters, [
            .init(title: "Current session", fraction: 0.28, label: "28% used", resets: "Resets 1pm (America/Bogota)"),
            .init(title: "Current week (Fable)", fraction: 0, label: "0% used", resets: "Resets Oct 13 at 6am (America/Bogota)", notes: ["You are close to this limit"]),
        ])
        XCTAssertEqual(usage.leftovers, [])
    }

    func testThePercentAloneIsEnoughForAMeter() throws {
        // A bar drawn only in background colours leaves nothing of it in the text: "28% used" is the value.
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Current session", "  28% used", "  Resets 1pm (America/Bogota)",
                                                           "  You've used most of your session limit"].joined(separator: "\n"))))
        XCTAssertEqual(usage.meters, [.init(title: "Current session", fraction: 0.28, label: "28% used", resets: "Resets 1pm (America/Bogota)",
                                            notes: ["You've used most of your session limit"])])
        // A credit, and the ruled panel's percent with its reset beside it.
        let credit = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Claude Code and Cowork credit", "  " + Fixtures.bar(5, "10% used"),
                                                            "  One-time credit · Expires October 13"].joined(separator: "\n"))))
        XCTAssertEqual(credit.meters.first?.resets, "One-time credit · Expires October 13")
        let ruled = try XCTUnwrap(ClaudeUsage(ClaudePanel(ClaudePanelFixtures.ruled)))
        XCTAssertEqual(ruled.meters, [.init(title: "Current week (all models)", fraction: 0.61, label: "61% used", resets: "resets Oct 7")])
    }

    // MARK: The other sections, line by line

    func testSessionLinesThisDoesNotKnowStayInTheSession() throws {
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Session (remote)", "",
                                                           "  Total cost:            $12.40 (costs may be inaccurate due to usage of unknown models)",
                                                           "  Total code changes:    1 line added, 12 lines removed",
                                                           "  Total web search requests:  3",
                                                           "  Usage by model:",
                                                           "        claude-opus-5-5:  2k input, 3k output, 1m cache read, 0 cache write, 4 web search ($12.40)",
                                                           "     claude-mystery-1:  12 input, 4 output, 2 thoughts"].joined(separator: "\n"))))
        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.title, "Session (remote)")
        XCTAssertEqual(session.cost, "$12.40")
        XCTAssertEqual(session.costNote, "costs may be inaccurate due to usage of unknown models")
        XCTAssertEqual(session.linesAdded, 1); XCTAssertEqual(session.linesRemoved, 12)
        XCTAssertEqual(session.models, [
            .init(name: "claude-opus-5-5", input: "2k", output: "3k", cacheRead: "1m", cacheWrite: "0", webSearch: "4", cost: "$12.40"),
            .init(name: "claude-mystery-1", input: "12", output: "4", extra: ["2 thoughts"]),
        ])
        XCTAssertEqual(session.other, [.init(label: "Total web search requests", value: "3")])
        XCTAssertEqual(usage.leftovers, [])
    }

    func testTheOlderFootprintLineIsItsNote() throws {
        // Sample's /usage of Claude Code 2.1.288: one line under the footprint's title, three limits, no cache write.
        let usage = try XCTUnwrap(ClaudeUsageFixtures.usage(ClaudePanelFixtures.screen(ClaudePanelFixtures.usage)))
        XCTAssertEqual(usage.footprint?.note, "12 plugins · 41 skills · about 6.2k tokens per session")
        XCTAssertEqual(usage.footprint?.plugins, [])
        XCTAssertEqual(usage.session?.models.first, .init(name: "claude-opus-5-5", input: "17.9k", output: "888.7k", cacheRead: "41.3m", cost: "$87.40"))
        XCTAssertEqual(usage.meters.count, 3)
        XCTAssertEqual(usage.leftovers, [])
        XCTAssertFalse(usage.complete)
    }

    func testTheInsightsOtherShapes() throws {
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Current session", "  " + Fixtures.bar(1, "2% used"), "",
                                                           "  What's contributing to your limits usage?",
                                                           "  Approximate, based on local sessions on this machine — does not include other devices or claude.ai", "",
                                                           "  Last 7d · these are independent characteristics of your usage, not a breakdown", "",
                                                           "  Nothing over 10% in this period — try the other window.", "",
                                                           "  Skills, subagents, plugins, and MCP servers",
                                                           "  No attribution data yet · accumulates as you use Claude", "",
                                                           "  Loops                         every  runs  tokens  last run",
                                                           "  check the deploy              5m       12    1.2m    3h ago",
                                                           "  … 2 more", "",
                                                           "  d to day · w to week", "",
                                                           "  Usage credits", "  Unlimited", "", "  Esc to cancel"].joined(separator: "\n"))))
        let insights = try XCTUnwrap(usage.insights)
        XCTAssertEqual(insights.window, "Last 7d · these are independent characteristics of your usage, not a breakdown")
        XCTAssertEqual(insights.messages, ["Nothing over 10% in this period — try the other window."])
        XCTAssertEqual(insights.items, [.init(headline: "Skills, subagents, plugins, and MCP servers", advice: "No attribution data yet · accumulates as you use Claude")])
        XCTAssertEqual(insights.tables, [.init(title: "Loops", columns: ["every", "runs", "tokens", "last run"],
                                               rows: [.init(name: "check the deploy", values: ["5m", "12", "1.2m", "3h ago"])], more: "… 2 more")])
        XCTAssertEqual(usage.leftovers.compactMap(ClaudePanel.text(of:)), ["Usage credits", "Unlimited"], "What follows the insights is not theirs.")
        // Still scanning.
        let scanning = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  What's contributing to your limits usage?",
                                                              "  Approximate, based on local sessions on this machine — does not include other devices or claude.ai", "",
                                                              "  Scanning local sessions…"].joined(separator: "\n"))))
        XCTAssertEqual(scanning.insights?.messages, ["Scanning local sessions…"])
    }

    func testAFootprintOverItsBudgetSaysSo() throws {
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel([Fixtures.tabs, "", "  Plugin skill-listing footprint", "",
                                                           "  Notion                     1 skill · ~1.2k tok/turn", "",
                                                           "  Total                      ~1.2k tok/turn (capped at the listing budget; per-plugin figures above are pre-truncation)"]
            .joined(separator: "\n"))))
        let footprint = try XCTUnwrap(usage.footprint)
        XCTAssertNil(footprint.note)
        XCTAssertEqual(footprint.plugins, [.init(name: "Notion", detail: "1 skill · ~1.2k tok/turn", skills: 1, tokens: 1200)])
        XCTAssertEqual(footprint.total, "~1.2k tok/turn"); XCTAssertEqual(footprint.totalTokens, 1200)
        XCTAssertEqual(footprint.totalNote, "capped at the listing budget; per-plugin figures above are pre-truncation")
    }
}

/// The Spanish words of the panel's new sections (`UsageWords`): what Claude prints, said in Spanish where known, as it is otherwise.
final class UsageWordsSectionsTests: XCTestCase {
    func testSectionsAndTheSessionsFigures() {
        XCTAssertEqual(UsageWords.section("Session"), "Sesión")
        XCTAssertEqual(UsageWords.section("Session (remote)"), "Sesión (remota)")
        XCTAssertEqual(UsageWords.section("Plugin skill-listing footprint"), "Huella de las skills de los plugins")
        XCTAssertEqual(UsageWords.section("What’s contributing to your limits usage?"), "¿Qué está consumiendo tus límites?")
        XCTAssertEqual(UsageWords.section("Something new"), "Something new")
        XCTAssertEqual(UsageWords.stat("Total cost"), "Costo")
        XCTAssertEqual(UsageWords.stat("Total duration (API):"), "Tiempo en la API")
        XCTAssertEqual(UsageWords.stat("Total duration (wall)"), "Duración")
        XCTAssertEqual(UsageWords.stat("Total code changes"), "Cambios de código")
        XCTAssertEqual(UsageWords.stat("Prompt cache (main)"), "Caché de prompts (principal)")
        XCTAssertEqual(UsageWords.stat("Prompt cache (subagents)"), "Caché de prompts (subagents)")
        XCTAssertEqual(UsageWords.stat("Total widgets"), "Total widgets")
        XCTAssertEqual(UsageWords.lines(added: 0, removed: 0), "0 líneas añadidas, 0 eliminadas")
        XCTAssertEqual(UsageWords.lines(added: 1, removed: 1), "1 línea añadida, 1 eliminada")
        XCTAssertEqual(UsageWords.tokens("cache write"), "escritura de caché")
        XCTAssertEqual(UsageWords.tokens("thoughts"), "thoughts")
        XCTAssertEqual(UsageWords.promptCache("22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)"),
                       "22 solicitudes · 95 % de la entrada desde la caché · sin fallos · activa (TTL de 1h, última actividad hace 1m 11s)")
        XCTAssertEqual(UsageWords.promptCache("1 request · cold — idle 2h 5m, next turn re-caches ~120k tokens · 2 expected rebuilds (compaction or tool-result clearing)"),
                       "1 solicitud · fría: inactiva 2h 5m, el próximo turno vuelve a cachear ~120k tokens · 2 expected rebuilds (compaction or tool-result clearing)",
                       "A part it does not know stays as Claude wrote it.")
    }

    func testTheFootprintAndTheInsights() {
        XCTAssertEqual(UsageWords.footprint("10 skills · ~301 tok/turn"), "10 skills · ~301 tok/turno")
        XCTAssertEqual(UsageWords.footprint("1 skill · ~75 tok/turn"), "1 skill · ~75 tok/turno")
        XCTAssertEqual(UsageWords.footprint("~376 tok/turn"), "~376 tok/turno")
        XCTAssertEqual(UsageWords.insight("Approximate, based on local sessions on this machine — does not include other devices or claude.ai"),
                       "Aproximado, según las sesiones locales de este equipo; no incluye otros dispositivos ni claude.ai")
        XCTAssertEqual(UsageWords.insight("Last 24h · these are independent characteristics of your usage, not a breakdown"),
                       "Últimas 24 h · son rasgos independientes de tu uso, no un desglose")
        XCTAssertEqual(UsageWords.insight("Last 7d · these are independent characteristics of your usage, not a breakdown"),
                       "Últimos 7 días · son rasgos independientes de tu uso, no un desglose")
        XCTAssertEqual(UsageWords.insight("89% of your usage was at >150k context"), "El 89 % de tu uso fue con más de 150k de contexto")
        XCTAssertEqual(UsageWords.insight("80% of your usage came from sessions active for 8+ hours"), "El 80 % de tu uso vino de sesiones activas durante 8 horas o más")
        XCTAssertEqual(UsageWords.insight("61% of your usage came from subagents under \"general-purpose\""), "El 61 % de tu uso vino de subagentes de «general-purpose»")
        XCTAssertEqual(UsageWords.insight("42% of your usage came from /review"), "El 42 % de tu uso vino de /review")
        XCTAssertEqual(UsageWords.insight("12% of your usage came from the MCP server \"figma\""), "El 12 % de tu uso vino del servidor MCP «figma»")
        XCTAssertEqual(UsageWords.insight("Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks."),
                       "Las sesiones largas cuestan más aunque estén en caché. Usa /compact a mitad de una tarea y /clear al pasar a otra.")
        XCTAssertEqual(UsageWords.insight("Scanning local sessions…"), "Revisando las sesiones locales…")
        XCTAssertEqual(UsageWords.insight("% of usage"), "% del uso")
        XCTAssertEqual(UsageWords.insight("… 3 more"), "… 3 más")
        XCTAssertEqual(UsageWords.insight("12% of your usage came from somewhere new"), "12% of your usage came from somewhere new")
    }

    func testCreditsAndTheirLinesUnderTheBar() {
        XCTAssertEqual(UsageWords.title("Usage credits"), "Créditos de uso")
        XCTAssertEqual(UsageWords.title("Claude Code and Cowork credit"), "Crédito de Claude Code y Cowork")
        XCTAssertEqual(UsageWords.title("Current week (Fable)"), "Semana actual (Fable)")
        XCTAssertEqual(UsageWords.resets("One-time credit · Expires October 13"), "Crédito único · Vence el 13 de octubre")
        XCTAssertEqual(UsageWords.resets("$5.00 of $50.00 used · Expires October 13"), "$5.00 de $50.00 usados · Vence el 13 de octubre")
        XCTAssertEqual(UsageWords.resets("$12.00 / $100.00 spent this month · Resets Nov 1 at 12am (UTC)"),
                       "$12.00 / $100.00 gastados este mes · Se reinicia el 1 nov a las 12 a. m. (UTC)")
        XCTAssertEqual(UsageWords.resets("Resets Oct 13 at 6am (America/Bogota)"), "Se reinicia el 13 oct a las 6 a. m. (America/Bogota)")
    }
}
