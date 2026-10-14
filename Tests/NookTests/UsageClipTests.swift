import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Nothing of the usage card is drawn wider than the room it is given: whatever the width of the island, the size of the chat's text or what Claude's panel holds,
/// every part of it stays inside the card's own edge (a part that did not would be cut by the card, or by the island, as a figure or a word half drawn).
@MainActor
final class UsageClipTests: XCTestCase {
    // MARK: What Claude's panel can hold

    private func screen(_ rows: [String]) -> String {
        ([ClaudeUsageFixtures.status, String(repeating: "▔", count: 120), ClaudeUsageFixtures.tabs, ""] + rows).joined(separator: "\n")
    }

    /// Sample's Terminal tab as the island showed it at 13:16 on 8 Oct: the panel scrolled to its middle (Claude's «↑» on its first row), one model, the plugins, three limits
    /// and four findings with their table.
    private var live: String {
        let bar = ClaudeUsageFixtures.bar
        return screen([
            "  Usage by model:",
            "      claude-sonnet-5-5:  399.1k input, 856.2k output, 276.8m cache read, 2.7m cache write ($71.35)",
            "  Prompt cache (main):   62 requests · 98% of input tokens from cache · no misses · warm (1h TTL, last activity 39m 14s ago)", "",
            "  Plugin skill-listing footprint",
            "  What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP tools not yet counted.", "",
            "  Notion                     10 skills · ~301 tok/turn",
            "  codex                      2 skills · ~75 tok/turn", "",
            "  Total                      ~376 tok/turn", "",
            "  Current session", "  " + bar(1, "3% used"), "  Resets 6:10pm (America/Bogota)", "",
            "  Current week (all models)", "  " + bar(43, "86% used"), "  Resets Oct 13 at 6am (America/Bogota)", "",
            "  Current week (Fable)", "  " + bar(0, "0% used"), "  Resets Oct 13 at 6am (America/Bogota)", "",
            "  What's contributing to your limits usage?",
            "  Approximate, based on local sessions on this machine — does not include other devices or claude.ai", "",
            "  Last 24h · these are independent characteristics of your usage, not a breakdown", "",
            "  91% of your usage was at >150k context",
            "   Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.", "",
            "  83% of your usage came from subagent-heavy sessions",
            "   Each subagent runs its own requests. Be deliberate about spawning them — and consider configuring a cheaper model for simpler subagents.", "",
            "  59% of your usage came from sessions active for 8+ hours",
            "   These are often background/loop sessions. Continuous usage can add up quickly so make sure it is intentional.", "",
            "  25% of your usage came from subagents under \"coder\"",
            "   If this runs frequently, consider configuring its subagents with a cheaper model or tightening their prompts.", "",
            "  Subagents                 % of usage",
            "  coder                         25%",
            "  logic-engineer                14%",
            "  ui-designer                   13%",
            "  general-purpose-with-a-very-long-name-indeed   9%",
            String(repeating: " ", count: 118) + "↓"])
    }

    /// The longest words Claude's panel can put in the card: a cold cache with its long line, a long model id, plugins with long names, a long zone, a long limit's title.
    private var worst: String {
        let bar = ClaudeUsageFixtures.bar
        return screen([
            "  Session (remote)", "",
            "  Total cost:            $1,234.56 (costs may be inaccurate due to usage of unknown models)",
            "  Total duration (API):  12h 59m 59s",
            "  Total duration (wall): 123h 59m 59s",
            "  Total code changes:    123456 lines added, 123456 lines removed",
            "  Total web search requests:  1234",
            "  Usage by model:",
            "      claude-3-5-sonnet-20241022-extended-context:  123.4k input, 123.4k output, 123.4m cache read, 123.4m cache write, 123 web search ($1,234.56)",
            "  Prompt cache (main):   9999 requests · 100% of input tokens from cache · 123 misses · cold — idle 123h 59m, next turn re-caches 1234.5k tokens", "",
            "  Plugin skill-listing footprint",
            "  Agents and MCP tools not yet counted.", "",
            "  a-very-long-plugin-name-that-goes-on-and-on     123 skills · ~12345 tok/turn",
            "  codex                      2 skills · ~75 tok/turn", "",
            "  Total                      ~123456 tok/turn", "",
            "  Current session", "  " + bar(14, "28% used"), "  Resets 12:59pm (America/Argentina/ComodRivadavia)", "",
            "  Current week (Claude Code and Cowork credit for the whole organization)", "  " + bar(37, "74% used"), "  Resets Oct 13 at 6am (America/Argentina/ComodRivadavia)", "",
            "  What's contributing to your limits usage?", "",
            "  89% of your usage was at >150k context",
            "   Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.", "",
            "  Skills                    % of usage",
            "  /some-extremely-long-skill-name-that-nobody-would-ever-type                42%",
            "",
            "  Usage credits", "  Usage credits are off · /usage-credits to turn them on", "", "  Esc to cancel"])
    }

    private var fixtures: [(name: String, text: String)] {
        [("terminal", ClaudeUsageFixtures.terminal), ("whole", ClaudeUsageFixtures.whole), ("live", live), ("worst", worst)]
    }

    // MARK: How far past its room the card draws

    private func usageContent(of text: String, width: CGFloat, chat: Double, dense: Bool, live: ClaudeLiveUsage? = nil) throws -> some View {
        let panel = ClaudePanel(try XCTUnwrap(ClaudeComposer.split(text).panel))
        let usage = try XCTUnwrap(ClaudeUsage(panel)).filled(from: live)
        return UsageContent(usage: usage, panel: panel, chatSize: chat, dense: dense, reading: true, onMore: { _ in }, enabled: true)
            .frame(width: width, alignment: .leading).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
    }

    /// How many points of `content` (given `width` to be in) are drawn to the right of that room (0: none). It is drawn in a canvas wider than the room, with nothing
    /// to cut what goes past.
    private func pastTheRoom<V: View>(_ content: V, width: CGFloat) throws -> CGFloat {
        // How tall it is at this width, so the canvas is no taller than it needs to be.
        let height = ceil(NSHostingView(rootView: content.fixedSize(horizontal: false, vertical: true)).fittingSize.height) + 8
        let canvas = CGSize(width: width + 240, height: height)
        let view = ZStack(alignment: .topLeading) { Color.black; content }.frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / canvas.width
        let data = try XCTUnwrap(rep.bitmapData)
        let perPixel = rep.bitsPerPixel / 8, rowBytes = rep.bytesPerRow
        let first = Int(width * scale) + 1
        var rightmost = first - 1
        for y in 0..<rep.pixelsHigh {
            var x = rep.pixelsWide - 1
            while x >= first {
                let at = y * rowBytes + x * perPixel
                if Int(data[at]) + Int(data[at + 1]) + Int(data[at + 2]) > 18 { rightmost = max(rightmost, x); break }
                x -= 1
            }
        }
        return max(0, CGFloat(rightmost + 1 - Int(width * scale)) / scale - 1 / scale)
    }

    private func overflow(of text: String, width: CGFloat, chat: Double, dense: Bool = false, live: ClaudeLiveUsage? = nil) throws -> CGFloat {
        try pastTheRoom(try usageContent(of: text, width: width, chat: chat, dense: dense, live: live), width: width)
    }

    /// A Terminal tab's screen scrolled past the session and the limits: Claude's panel shows from what spends them down, and the status line gives the rest.
    private var cut: String { ClaudeUsageFixtures.screen(top: ClaudeUsageFixtures.body.firstIndex { $0.contains("What's contributing") }!, height: 40) }

    /// What Claude's status line can add, as wide as it gets: the three limits (the spend one with its dollars), every figure of the session and a context at its fullest.
    private var statusLine: ClaudeLiveUsage {
        let now = Date()
        let json: [String: Any] = [
            "session_id": "widest", "model": ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5 with 1M context"], "effort": ["level": "xhigh"],
            "cost": ["total_cost_usd": 1234.56, "total_duration_ms": 446_399_000.0, "total_api_duration_ms": 9_000_000.0, "total_lines_added": 123456, "total_lines_removed": 123456],
            "context_window": ["used_percentage": 100.0, "context_window_size": 1_000_000],
            "prompt_cache": ["warm": false, "ttl": "1h", "requests": 9999, "misses": 123, "hit_ratio": 0.99, "expires_at": now.addingTimeInterval(-440_000).timeIntervalSince1970]]
        let limits = ClaudeStatusPayload.RateLimits(
            fiveHour: .init(usedPercentage: 100, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: .init(usedPercentage: 99.9, resetsAt: now.addingTimeInterval(5 * 86_400)),
            spendLimit: .init(usedPercentage: 100, resetsAt: now.addingTimeInterval(12 * 86_400), usedUSD: 12_345.67, limitUSD: 123_456.78, period: "monthly"))
        return ClaudeLiveUsage(session: ClaudeStatusPayload(json: json), sessionAt: now.addingTimeInterval(-3 * 3600), limits: limits, limitsAt: now.addingTimeInterval(-3 * 3600))
    }

    /// The control: a line that cannot be shortened, in a room too narrow for it, is seen going past it (and one that fits is not).
    func testTheDetectorSeesWhatGoesPastAndNothingElse() throws {
        let line = Text(String(repeating: "Claude ", count: 12)).font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1).fixedSize()
        XCTAssertGreaterThan(try pastTheRoom(line.frame(width: 200, alignment: .leading), width: 200), 100, "A line 400 pt long in a room of 200: it goes past.")
        XCTAssertEqual(try pastTheRoom(Text("Claude").font(.system(size: 12)).foregroundStyle(Color.white).frame(width: 200, alignment: .leading), width: 200), 0, accuracy: 0.6)
    }

    /// A picture of what the card draws at this width, with a red line at its room's edge (for review).
    private func save(_ text: String, width: CGFloat, chat: Double, to path: String) throws {
        let content = try usageContent(of: text, width: width, chat: chat, dense: false)
        let height = ceil(NSHostingView(rootView: content.fixedSize(horizontal: false, vertical: true)).fittingSize.height) + 8
        let canvas = CGSize(width: width + 240, height: height)
        let view = ZStack(alignment: .topLeading) {
            Color.black
            content
            Rectangle().fill(Color.red).frame(width: 1, height: canvas.height).offset(x: width)
        }.frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    func testRenderTheCasesWhereTheCardDrawsPastItsRoom() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cases: [(String, String, CGFloat, Double)] = [("terminal", ClaudeUsageFixtures.terminal, 384, 18), ("worst", worst, 384, 11), ("worst", worst, 444, 11), ("worst", worst, 516, 18), ("live", live, 384, 14)]
        for (name, text, width, chat) in cases {
            try save(text, width: width, chat: chat, to: URL(fileURLWithPath: directory).appendingPathComponent("clip-\(name)-\(Int(width))-chat\(Int(chat)).png").path)
        }
    }

    func testNothingOfTheUsageCardIsDrawnPastTheRoomItIsGivenAtAnyWidthOrTextSize() throws {
        var found: [String] = []
        for (name, text) in fixtures {
            // The widths of the card in every island the settings can make (the island less the 15 pt the pane leaves at each side and the 13 the card leaves at each
            // side of its text: from the smallest island, 440, to the wide one, 720, and the screen's own width), and the chat's text at its smallest, usual and biggest.
            for width in [384.0, 444, 516, 586, 616, 664, 734, 974] {
                for chat in [9.0, 11, 12, 14, 16, 18] {
                    let past = try overflow(of: text, width: CGFloat(width), chat: chat)
                    if past > 0.5 { found.append("\(name) at \(Int(width)) pt, chat \(Int(chat)): \(String(format: "%.1f", past)) pt past") }
                }
            }
            // The dense layout, which a card with no island of its own to grow uses.
            for width in [384.0, 516, 664] {
                let past = try overflow(of: text, width: CGFloat(width), chat: 11, dense: true)
                if past > 0.5 { found.append("\(name) dense at \(Int(width)) pt: \(String(format: "%.1f", past)) pt past") }
            }
        }
        XCTAssertEqual(found, [], "Drawn past the card's edge:\n" + found.joined(separator: "\n"))
    }

    /// Nook's own usage card (no panel behind it): the rings beside the limits that are Claude's last reading, the note under them, the status line's widest figures and the week of a
    /// model with a long name stay inside the room as well, at every width and text size, and in the dense layout.
    func testNooksOwnUsageCardStaysInsideTheRoomToo() throws {
        let now = Date()
        var live = statusLine
        live.saved = ClaudeUsageSnapshot(fetchedAt: now.addingTimeInterval(-5 * 3600), limits: [
            .init(title: "Current week (Claude Sonnet 4.5 with extended thinking)", percent: 100, resetsAt: now.addingTimeInterval(5 * 86_400), dated: true),
            .init(title: "Current week (Fable)", percent: 41, resetsAt: now.addingTimeInterval(5 * 86_400), dated: true)])
        let usage = try XCTUnwrap(ClaudeUsage.nookCard(from: live, now: now))
        XCTAssertEqual(usage.meters.filter { $0.source == .snapshot }.count, 2, "The two weeks of a model are Claude's last reading.")
        XCTAssertNotNil(UsageSnapshot.note(for: usage.meters, since: usage.savedAt, now: now), "…and the note says how old it is.")
        var found: [String] = []
        for width in [384.0, 444, 516, 586, 616, 664, 734, 974] {
            for chat in [9.0, 11, 14, 18] {
                let content = UsageContent(usage: usage, panel: nil, chatSize: chat, dense: false, onMore: { _ in }, enabled: true)
                    .frame(width: CGFloat(width), alignment: .leading).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                let past = try pastTheRoom(content, width: CGFloat(width))
                if past > 0.5 { found.append("Nook's card at \(Int(width)) pt, chat \(Int(chat)): \(String(format: "%.1f", past)) pt past") }
            }
        }
        for width in [384.0, 516, 664] {
            let content = UsageContent(usage: usage, panel: nil, chatSize: 11, dense: true, onMore: { _ in }, enabled: true)
                .frame(width: CGFloat(width), alignment: .leading).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
            let past = try pastTheRoom(content, width: CGFloat(width))
            if past > 0.5 { found.append("Nook's card, dense, at \(Int(width)) pt: \(String(format: "%.1f", past)) pt past") }
        }
        XCTAssertEqual(found, [], "Drawn past the card's edge:\n" + found.joined(separator: "\n"))
    }

    /// What the status line adds (the dots beside the figures it gave, the context cell, the spend limit's dollars) stays inside the room as well: on a screen that lacks the
    /// limits and the session, and on the ones that have them.
    func testWhatTheStatusLineAddsStaysInsideTheRoomToo() throws {
        var found: [String] = []
        for (name, text) in [("cut", cut), ("terminal", ClaudeUsageFixtures.terminal), ("worst", worst)] {
            for width in [384.0, 444, 516, 586, 616, 664, 734, 974] {
                for chat in [9.0, 11, 14, 18] {
                    let past = try overflow(of: text, width: CGFloat(width), chat: chat, live: statusLine)
                    if past > 0.5 { found.append("\(name) with the status line at \(Int(width)) pt, chat \(Int(chat)): \(String(format: "%.1f", past)) pt past") }
                }
            }
        }
        XCTAssertEqual(found, [], "Drawn past the card's edge:\n" + found.joined(separator: "\n"))
    }
}
