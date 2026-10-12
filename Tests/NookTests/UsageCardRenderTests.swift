import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The usage card (`ClaudeUsageCard.swift`): the numbers and names it works out of Claude's words, how it lays its sections out, what it shows of Sample's two
/// /usage screens, and the renders for review at each island size and text size (which run only when NOOK_RENDER_DIR is set).
@MainActor
final class UsageCardRenderTests: XCTestCase {
    // MARK: Figures

    func testClaudesCountsAreNumbers() {
        XCTAssertEqual(UsageFigures.count("381"), 381)
        XCTAssertEqual(UsageFigures.count("23.5k"), 23_500)
        XCTAssertEqual(UsageFigures.count("2.0m"), 2_000_000)
        XCTAssertEqual(UsageFigures.count("110.7k"), 110_700)
        XCTAssertEqual(UsageFigures.count("1.2b"), 1_200_000_000)
        XCTAssertEqual(UsageFigures.count(" 44 "), 44)
        XCTAssertNil(UsageFigures.count("many")); XCTAssertNil(UsageFigures.count("")); XCTAssertNil(UsageFigures.count(nil))
        XCTAssertEqual(UsageFigures.dollars("$1.75"), 1.75); XCTAssertEqual(UsageFigures.dollars("$0.0003"), 0.0003)
        XCTAssertEqual(UsageFigures.dollars("$1,234.50"), 1234.5); XCTAssertNil(UsageFigures.dollars("free")); XCTAssertNil(UsageFigures.dollars(nil))
        XCTAssertEqual(UsageFigures.share("42%"), 0.42); XCTAssertEqual(UsageFigures.share(" 9 % "), 0.09); XCTAssertNil(UsageFigures.share("42")); XCTAssertEqual(UsageFigures.share("140%"), 1)
    }

    func testAResetIsToldApartFromItsZone() {
        let split = UsageFigures.zoneSplit("Se reinicia el 13 oct a las 6 a. m. (America/Bogota)")
        XCTAssertEqual(split.words, "Se reinicia el 13 oct a las 6 a. m."); XCTAssertEqual(split.zone, "America/Bogota")
        XCTAssertEqual(UsageFigures.zoneSplit("Se reinicia a las 1 p. m. (UTC)").zone, "UTC")
        XCTAssertNil(UsageFigures.zoneSplit("Se reinicia el 2 ene a las 12 p. m.").zone)
        XCTAssertNil(UsageFigures.zoneSplit("Crédito único · Vence el 13 de octubre").zone)
        XCTAssertNil(UsageFigures.zoneSplit("Se reinicia (cuando pase la ventana)").zone, "Words in parentheses are no zone.")
        let same = ["Resets 1pm (America/Bogota)", "Resets Oct 13 at 6am (America/Bogota)"]
        XCTAssertEqual(UsageFigures.commonZone(of: same), "America/Bogota", "Said once for all of them.")
        XCTAssertNil(UsageFigures.commonZone(of: [same[0], "Resets Oct 13 at 6am (UTC)"]), "Two zones: each reset says its own.")
        XCTAssertEqual(UsageFigures.commonZone(of: [same[0], nil]), "America/Bogota", "A limit with no reset has nothing to name a zone for.")
        XCTAssertNil(UsageFigures.commonZone(of: [nil, nil]))
    }

    func testALimitsTitleIsToldApartFromWhatItIsFor() {
        XCTAssertTrue(UsageFigures.titleParts("Semana actual (todos los modelos)") == ("Semana actual", "todos los modelos"))
        XCTAssertTrue(UsageFigures.titleParts("Semana actual (solo Sonnet)") == ("Semana actual", "solo Sonnet"))
        XCTAssertTrue(UsageFigures.titleParts("Sesión actual") == ("Sesión actual", nil))
        XCTAssertTrue(UsageFigures.titleParts("(sin nombre)") == ("(sin nombre)", nil))
    }

    func testModelsAreNamedAsTheIslandNamesThem() {
        XCTAssertEqual(UsageFigures.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(UsageFigures.modelName("claude-haiku-5-5"), "Haiku 5.5")
        XCTAssertEqual(UsageFigures.modelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5", "A date is no version.")
        XCTAssertEqual(UsageFigures.modelName("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(UsageFigures.modelName("claude-fable-5-1"), "Fable 5.1", "A family Nook has no rule for is named all the same.")
        XCTAssertEqual(UsageFigures.modelName("claude-opus-5-5[1m]"), "Opus 5.5")
        XCTAssertEqual(UsageFigures.modelName("gpt-5"), "gpt-5", "What is not a Claude id stays as it is.")
        XCTAssertEqual(UsageFigures.modelName("claude-mystery"), "Mystery")
    }

    func testClaudesRemarkOnTheCostIsSaidInSpanishWhenItIsOneItMakes() {
        XCTAssertEqual(UsageWords.costNote("costs may be inaccurate due to usage of unknown models"), "El costo puede ser inexacto: se usaron modelos que Claude no conoce")
        XCTAssertEqual(UsageWords.costNote("a remark Claude adds later"), "a remark Claude adds later", "What it does not know stays as Claude wrote it.")
    }

    func testTheInsightsHeadingIsShortEnoughForItsHeaderAndTheOthersAreClaudesWords() {
        XCTAssertEqual(UsageFigures.heading("What's contributing to your limits usage?"), "¿Qué consume tus límites?")
        XCTAssertEqual(UsageFigures.heading("Plugin skill-listing footprint"), UsageWords.section("Plugin skill-listing footprint"))
        XCTAssertEqual(UsageFigures.heading("Something new"), "Something new", "A heading Claude adds later is shown as it is.")
    }

    func testThePromptCacheLineIsTakenApartAndNothingIsLost() {
        let warm = UsageFigures.cache("22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity 1m 11s ago)")
        XCTAssertEqual(warm.requests, 22); XCTAssertEqual(warm.percent, 95); XCTAssertEqual(warm.misses, "sin fallos")
        XCTAssertEqual(warm.state, .warm(ttl: "1h", idle: "1m 11s")); XCTAssertEqual(warm.rest, [])
        let cold = UsageFigures.cache("1 request · 0% of input tokens from cache · 2 misses · cold — idle 9m 2s, next turn re-caches 82.1k tokens")
        XCTAssertEqual(cold.requests, 1); XCTAssertEqual(cold.percent, 0); XCTAssertEqual(cold.misses, "2 fallos")
        XCTAssertEqual(cold.state, .cold(idle: "9m 2s", tokens: "82.1k"))
        let odd = UsageFigures.cache("no prompt caching reported by the API · something new")
        XCTAssertEqual(odd.rest, ["la API no informa de caché de prompts", "something new"], "What it does not know is kept, as Claude wrote it.")
        XCTAssertTrue(UsageFigures.cache("").isEmpty)
    }

    // MARK: The columns

    func testTheColumnsFollowTheWidthAndTheSectionsGoWhereTheyEndLowest() {
        let layout = UsageMasonry(gap: 8, minColumn: 205)
        XCTAssertEqual(layout.columns(for: 384), 1, "A small island: one column.")
        XCTAssertEqual(layout.columns(for: 516), 2, "The usual island: two.")
        XCTAssertEqual(layout.columns(for: 664), 3, "A wide one: three.")
        XCTAssertEqual(layout.columns(for: 2000), 3, "…and no more.")
        XCTAssertEqual(layout.columns(for: 0), 1)
        // Sample's sections at the usual width: the session, the models, the plugins, what spends the limits.
        let heights: [CGFloat] = [150, 160, 105, 190]
        let placed = layout.arrange(heights: heights, width: 516)
        XCTAssertTrue(placed.origins[0] == (0, 0), "The first section stands at the top of the first column.")
        func bottoms(_ placed: (origins: [(column: Int, y: CGFloat)], height: CGFloat), _ heights: [CGFloat], columns: Int) -> [CGFloat] {
            var bottoms = [CGFloat](repeating: 0, count: columns)
            for (index, origin) in placed.origins.enumerated() { bottoms[origin.column] = max(bottoms[origin.column], origin.y + heights[index]) }
            return bottoms
        }
        let ends = bottoms(placed, heights, columns: 2)
        XCTAssertEqual(placed.height, ends.max())
        // No division ends lower than the one chosen: try all of them.
        var lowest = CGFloat.greatestFiniteMagnitude
        for mask in 0..<(1 << heights.count) {
            var filled: [CGFloat] = [0, 0]
            for index in heights.indices { let column = (mask >> index) & 1; filled[column] += (filled[column] > 0 ? 8 : 0) + heights[index] }
            lowest = min(lowest, filled.max() ?? 0)
        }
        XCTAssertEqual(placed.height, lowest, accuracy: 0.5, "Nowhere lower than this.")
        XCTAssertLessThan(placed.height, heights.reduce(0, +) / 2 + 40, "About half of what one column would be.")
        // Within a column the sections keep their order.
        for column in 0..<2 {
            let ys = placed.origins.enumerated().filter { $0.element.column == column }.map { $0.element.y }
            XCTAssertEqual(ys, ys.sorted(), "Column \(column).")
        }
        // One column: they stack in order, a gap apart.
        let stacked = layout.arrange(heights: [10, 20, 30], width: 300)
        XCTAssertEqual(stacked.origins.map(\.y), [0, 18, 46]); XCTAssertEqual(stacked.height, 76)
        XCTAssertEqual(layout.arrange(heights: [], width: 500).height, 0)
        XCTAssertEqual(layout.arrange(heights: [40], width: 700).height, 40)
        // Three columns, six sections: each of them is used.
        let wide = layout.arrange(heights: [100, 120, 90, 110, 130, 70], width: 664)
        XCTAssertEqual(Set(wide.origins.map(\.column)), [0, 1, 2])
    }

    func testTheTilesDivideIntoRowsEvenly() {
        let grid = UsageTileGrid(minTile: 128, gap: 16, rowGap: 12)
        XCTAssertEqual(grid.columns(count: 3, width: 496), 3, "Three limits side by side in the usual island.")
        XCTAssertEqual(grid.columns(count: 3, width: 430), 3, "…and in the compact one.")
        XCTAssertEqual(grid.columns(count: 3, width: 364), 2, "…two and one in the smallest.")
        XCTAssertEqual(grid.columns(count: 3, width: 200), 1)
        XCTAssertEqual(grid.columns(count: 4, width: 430), 2, "Four where three would fit are two and two, not three and one.")
        XCTAssertEqual(grid.columns(count: 4, width: 700), 4, "…and all four in a row where they all fit.")
        XCTAssertEqual(grid.columns(count: 5, width: 430), 3, "Five are three and two.")
        XCTAssertEqual(grid.columns(count: 2, width: 700), 2)
        XCTAssertEqual(grid.columns(count: 1, width: 700), 1)
        XCTAssertEqual(grid.columns(count: 0, width: 700), 1)
    }

    func testAResetIsShortenedForATileAndNothingElseIs() {
        XCTAssertEqual(UsageFigures.shortReset("Se reinicia el 13 oct a las 6 a. m."), "Reinicia el 13 oct · 6 a. m.")
        XCTAssertEqual(UsageFigures.shortReset("Se reinicia a las 1 p. m."), "Reinicia a las 1 p. m.")
        XCTAssertEqual(UsageFigures.shortReset("Se reinicia when the window rolls"), "Reinicia when the window rolls")
        XCTAssertEqual(UsageFigures.shortReset("Crédito único · Vence el 13 de octubre"), "Crédito único · Vence el 13 de octubre")
    }

    // MARK: What Sample's screens give

    private func usage(_ screen: String) throws -> ClaudeUsage { try XCTUnwrap(ClaudeUsageFixtures.usage(screen)) }

    /// The panel's text as the island's card receives it (`session.panel`): from the panel's top edge to the end of the screen.
    private func panelText(_ screen: String) throws -> String { try XCTUnwrap(ClaudeComposer.split(screen).panel) }

    func testSamplesTerminalScreenHasEverythingTheCardDraws() throws {
        let usage = try usage(ClaudeUsageFixtures.terminal)
        XCTAssertFalse(usage.complete, "His Terminal tab shows the panel but its end: «más» stays useful.")
        // What the card draws of it, from the same words the card uses.
        XCTAssertEqual(usage.meters.map { UsageFigures.titleParts(UsageWords.title($0.title)).main }, ["Sesión actual", "Semana actual", "Semana actual"])
        XCTAssertEqual(UsageFigures.commonZone(of: usage.meters.map(\.resets)), "America/Bogota")
        XCTAssertEqual(usage.session?.models.map { UsageFigures.modelName($0.name) }, ["Haiku 5.5", "Opus 5.5"])
        let cache = UsageFigures.cache(try XCTUnwrap(usage.session?.promptCache))
        XCTAssertEqual(cache.requests, 22); XCTAssertEqual(cache.percent, 95)
        XCTAssertEqual(usage.footprint?.plugins.map(\.name), ["Notion", "codex"])
        XCTAssertEqual(usage.insights?.items.compactMap(\.share), [0.89, 0.8])
    }

    func testMasIsOfferedOnlyWhileNookHoldsPartOfThePanel() throws {
        func offers(_ screen: String) throws -> (above: Bool, below: Bool, complete: Bool) {
            let panel = ClaudePanel(try panelText(screen))
            let usage = try XCTUnwrap(ClaudeUsage(panel))
            let more = UsageContent.offersMore(usage: usage, panel: panel)
            return (more.above, more.below, usage.complete)
        }
        let top = try offers(ClaudeUsageFixtures.terminal)
        XCTAssertFalse(top.complete); XCTAssertTrue(top.below); XCTAssertFalse(top.above, "Sample's Terminal tab: «↓» only.")
        let middle = try offers(ClaudeUsageFixtures.screen(top: 6, height: 22))
        XCTAssertTrue(middle.above); XCTAssertTrue(middle.below, "A window cut at both ends: both ways.")
        let end = try offers(ClaudeUsageFixtures.screen(top: ClaudeUsageFixtures.body.count - 20, height: 20))
        XCTAssertTrue(end.above); XCTAssertFalse(end.below)
        let whole = try offers(ClaudeUsageFixtures.whole)
        XCTAssertTrue(whole.complete)
        XCTAssertFalse(whole.above); XCTAssertFalse(whole.below, "The whole panel in hand: no «más».")
        // Even with Claude's marks on the last screen, a panel Nook holds whole offers none.
        var marked = ClaudePanel(try panelText(ClaudeUsageFixtures.whole))
        marked.moreBelow = true; marked.moreAbove = true
        let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel(try panelText(ClaudeUsageFixtures.whole))))
        XCTAssertTrue(usage.complete)
        XCTAssertEqual(UsageContent.offersMore(usage: usage, panel: marked).above, false); XCTAssertEqual(UsageContent.offersMore(usage: usage, panel: marked).below, false)
    }

    /// A press of «más» reaches whoever scrolls the panel, and a button that is not enabled (the terminal is closed) reaches nobody.
    func testAPressOfMasGoesToWhoScrollsThePanel() {
        func press(down: Bool, enabled: Bool) -> [Bool] {
            var presses: [Bool] = []
            let host = NSHostingView(rootView: UsageMoreButton(down: down, enabled: enabled) { presses.append($0) }.padding(10).frame(width: 200, height: 40).environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            // It stands at the trailing edge of its row, 20 pt tall in a 40 pt window.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 200 - 10 - 28, y: 20), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return presses
        }
        XCTAssertEqual(press(down: true, enabled: true), [true], "«↓ más» scrolls down.")
        XCTAssertEqual(press(down: false, enabled: true), [false], "«↑ más» scrolls up.")
        XCTAssertEqual(press(down: true, enabled: false), [], "With the terminal closed it does nothing.")
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The card as the pane gives it room in an island of this size: the pane less the tab row and the margins.
    private func cardSize(width: CGFloat, height: CGFloat, neck: CGFloat = 28) -> CGSize {
        CGSize(width: width - 30, height: ClaudePanelCard.height(inIsland: height, neck: neck))
    }

    func testTheIslandHeightAndTheCardHeightAreEachOthersInverse() {
        for neck in [28.0, 32.0] {
            for island in [NotchGeometry.minExpandedHeight(topInset: neck), NotchGeometry.expandedHeight(topInset: neck), 482, 700] {
                let card = ClaudePanelCard.height(inIsland: island, neck: neck)
                XCTAssertEqual(ClaudePanelCard.island(forCard: card, neck: neck), island, accuracy: 0.001)
            }
        }
        // The usual island (28 pt neck) leaves the card 193 pt, of which its toolbar takes 34.
        XCTAssertEqual(ClaudePanelCard.height(inIsland: NotchGeometry.expandedHeight(topInset: 28), neck: 28), 193)
        XCTAssertEqual(ClaudePanelCard.height(inIsland: NotchGeometry.expandedHeight(topInset: 28), neck: 28) - ClaudePanelCard.toolbarHeight, 159, "The content's room: what the dense card is made for.")
        XCTAssertLessThan(159, UsageMetrics.denseBelow)
        XCTAssertGreaterThan(ClaudePanelCard.height(inIsland: NotchGeometry.expandedHeight(topInset: 28) + IslandPreset.wide.heightExtra, neck: 28) - ClaudePanelCard.toolbarHeight, UsageMetrics.denseBelow,
                             "A wide island has room for the card's regular layout.")
    }

    private struct Card: View {
        var text: String
        var size: CGSize
        var chat = DisplaySettings.defaultChatSize
        var tint: TabTint = .mint
        var reading = false
        var body: some View {
            ClaudePanelCard(text: text, fontSize: chat, reading: reading).tabTint(tint)
                .frame(width: size.width, height: size.height).padding(15)
                .background(Color.black).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        }
    }

    private var islands: [(name: String, width: CGFloat, height: CGFloat)] {
        let width = NotchGeometry.expandedWidth, height = NotchGeometry.expandedHeight(topInset: 28)
        return [("minima", NotchGeometry.minExpandedWidth, NotchGeometry.minExpandedHeight(topInset: 28)),
                ("compacta", width + IslandPreset.compact.widthExtra, height + IslandPreset.compact.heightExtra),
                ("normal", width, height),
                ("amplia", width + IslandPreset.wide.widthExtra, height + IslandPreset.wide.heightExtra),
                ("alta", width, height + IslandPreset.tall.heightExtra)]
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// Sample's two screens (the terminal tab's, cut at its ↓; and the whole panel of a Nook tab) at each island size.
    func testRenderTheUsageCardAtEveryIslandSize() throws {
        let directory = try renderDirectory()
        let terminal = try panelText(ClaudeUsageFixtures.terminal), whole = try panelText(ClaudeUsageFixtures.whole)
        for island in islands {
            let size = cardSize(width: island.width, height: island.height)
            let canvas = CGSize(width: size.width + 30, height: size.height + 30)
            try save(Card(text: terminal, size: size), size: canvas, to: url(directory, "usage-terminal-\(island.name).png"))
            try save(Card(text: whole, size: size), size: canvas, to: url(directory, "usage-whole-\(island.name).png"))
        }
    }

    /// The card tall enough for all of it (what it would need if the island grew), at the usual width: how tall that is.
    func testRenderTheWholeUsageCardWithAllTheRoomItWants() throws {
        let directory = try renderDirectory()
        let whole = try panelText(ClaudeUsageFixtures.whole), terminal = try panelText(ClaudeUsageFixtures.terminal)
        for (name, text) in [("whole", whole), ("terminal", terminal)] {
            for width in [NotchGeometry.expandedWidth, NotchGeometry.expandedWidth + IslandPreset.wide.widthExtra, NotchGeometry.minExpandedWidth] {
                let size = CGSize(width: width - 30, height: 700)
                try save(Card(text: text, size: size), size: CGSize(width: size.width + 30, height: 730), to: url(directory, "usage-tall-\(name)-\(Int(width)).png"))
            }
        }
    }

    /// What a card asks of the island (`IslandRoomKey`) as it is drawn in a window of the given size, once it has been laid out.
    private func room(of text: String, width: CGFloat, height: CGFloat = 300, chat: Double = 11, grows: Bool = true) -> IslandRoom? {
        final class Box { var room: IslandRoom?; var calls = 0 }
        struct Probe: View {
            var text: String
            var width: CGFloat
            var height: CGFloat
            var chat: Double
            var grows: Bool
            var box: Box
            var body: some View {
                ClaudePanelCard(text: text, fontSize: chat, growsIsland: grows).frame(width: width, height: height).padding(15)
                    .background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                    .onPreferenceChange(IslandRoomKey.self) { box.room = $0; box.calls += 1 }
            }
        }
        let box = Box()
        let host = NSHostingView(rootView: Probe(text: text, width: width, height: height, chat: chat, grows: grows, box: box))
        host.frame = NSRect(x: 0, y: 0, width: width + 30, height: height + 30)
        // On the screen list, far off it: a window that is not shown does not run its views' updates.
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width + 30, height: height + 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // The card learns how tall its content is as it is drawn, and says so once it has been.
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            if box.room != nil { break }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        return box.room
    }

    /// How tall the card wants to be for all of it to show at once (`IslandRoomKey`), by the island's width and the screen: what the island is given. The numbers go to
    /// the test's log; the card never wants less than its toolbar, and never more than a screen has.
    func testTheHeightTheCardWantsToShowAllOfItAtOnce() throws {
        var report: [String] = []
        XCTAssertNil(room(of: ClaudePanelFixtures.list, width: 540), "Only the usage card asks for room: any other panel is plain text that scrolls.")
        XCTAssertNil(room(of: try panelText(ClaudeUsageFixtures.whole), width: 540, grows: false), "A card in an island that does not grow asks for nothing.")
        for (name, screen) in [("terminal", ClaudeUsageFixtures.terminal), ("whole", ClaudeUsageFixtures.whole)] {
            let text = try panelText(screen)
            for island in islands {
                for chat in [11.0, 14.0] {
                    let asked = try XCTUnwrap(room(of: text, width: island.width - 30, chat: chat), "\(name) \(island.name): it asks.")
                    XCTAssertGreaterThan(asked.height, ClaudePanelCard.toolbarHeight, "\(name) \(island.name): it reports a height.")
                    XCTAssertLessThan(asked.height, 1500)
                    XCTAssertEqual(asked.width, island.width - 30, accuracy: 1, "\(name) \(island.name): the width it measured at is its own.")
                    XCTAssertEqual(asked.width, ClaudePanelCard.width(inIsland: island.width), accuracy: 1)
                    report.append("\(name) / \(island.name) (\(Int(island.width)) wide) / chat \(Int(chat)): the card wants \(Int(asked.height.rounded())) pt")
                }
            }
        }
        print("IDEALHEIGHT\n" + report.joined(separator: "\n"))
    }

    /// What the card asks does not depend on how tall the room it is drawn in is: the island is given the height the card asks for, and the card, in that room, asks for
    /// the same again, so the island settles in one step and stays. (A dense card, drawn for a short viewport, would ask for less, and the island would grow twice.)
    func testWhatTheCardAsksDoesNotDependOnTheRoomItIsDrawnIn() throws {
        for screen in [ClaudeUsageFixtures.terminal, ClaudeUsageFixtures.whole] {
            let text = try panelText(screen)
            let heights = try [140.0, 190.0, 300.0, 700.0].map { height -> CGFloat in try XCTUnwrap(room(of: text, width: 542, height: CGFloat(height)), "\(height)").height }
            for height in heights { XCTAssertEqual(height, heights[0], accuracy: 1, "The same height whatever the viewport: \(heights).") }
            XCTAssertGreaterThan(heights[0], 400, "It is the whole card: its first screen in the usual island is much less.")
        }
    }

    /// The panel in states Sample's screens do not show: limits nearly full, a credit, a remote session with remarks and a web search, a cold cache, the older
    /// panel's shape, a panel still loading, and a window of it cut where Claude's «↓» says there is more.
    func testRenderTheUsageCardInItsOtherStates() throws {
        let directory = try renderDirectory()
        let bar = ClaudeUsageFixtures.bar
        let alarm = ["  Session (remote)", "",
                     "  Total cost:            $12.40 (costs may be inaccurate due to usage of unknown models)",
                     "  Total duration (API):  1h 2m",
                     "  Total duration (wall): 3h 40m",
                     "  Total code changes:    120 lines added, 45 lines removed",
                     "  Total web search requests:  3",
                     "  Usage by model:",
                     "      claude-opus-5-5:  2k input, 3k output, 1m cache read, 0 cache write, 4 web search ($11.90)",
                     "      claude-sonnet-4-5-20250929:  12 input, 4 output, 2 thoughts ($0.50)",
                     "  Prompt cache (main):   9 requests · 12% of input tokens from cache · 3 misses · cold — idle 9m 2s, next turn re-caches 82.1k tokens", "",
                     "  Current session", "  " + bar(41, "82% used"), "  Resets 1pm (America/Bogota)", "",
                     "  Current week (all models)", "  " + bar(48, "97% used"), "  Resets Oct 13 at 6am (America/Bogota)", "  You are close to this limit", "",
                     "  Current week (Opus only)", "  " + bar(50, "100% used"), "  Resets Oct 13 at 6am (America/Bogota)", "",
                     "  Claude Code and Cowork credit", "  " + bar(5, "10% used"), "  One-time credit · Expires October 13", "",
                     "  Loading usage data…"]
        func screen(_ lines: [String]) -> String { ((["✻ Working…", String(repeating: "▔", count: 73), ClaudeUsageFixtures.tabs, ""]) + lines).joined(separator: "\n") }
        let size = cardSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28) + IslandPreset.tall.heightExtra)
        let canvas = CGSize(width: size.width + 30, height: size.height + 30)
        let tall = CGSize(width: size.width, height: 700), tallCanvas = CGSize(width: size.width + 30, height: 730)
        try save(Card(text: try panelText(screen(alarm)), size: tall), size: tallCanvas, to: url(directory, "usage-state-alarm.png"))
        // The older panel (Claude Code 2.1.288), as Sample's earlier screen.
        try save(Card(text: try panelText(ClaudePanelFixtures.screen(ClaudePanelFixtures.usage)), size: size), size: canvas, to: url(directory, "usage-state-older.png"))
        // Only the panel's title and its «Loading…»: the usage tab is open on nothing the card knows yet.
        try save(Card(text: try panelText(screen(["  Loading usage data…", "", "  Esc to cancel"])), size: size, reading: true), size: canvas, to: url(directory, "usage-state-loading.png"))
        // A Terminal tab scrolled to the end of the panel: the tables, and no «más» below.
        let tail = ClaudeUsageFixtures.screen(top: ClaudeUsageFixtures.body.count - 20, height: 20)
        try save(Card(text: try panelText(tail), size: size), size: canvas, to: url(directory, "usage-state-tail.png"))
        // A window cut at both ends: «más» both ways.
        let middle = ClaudeUsageFixtures.screen(top: 6, height: 22)
        try save(Card(text: try panelText(middle), size: size, reading: true), size: canvas, to: url(directory, "usage-state-middle.png"))
    }

    func testRenderTheUsageCardAtEachTextSizeAndInTwoColours() throws {
        let directory = try renderDirectory()
        let whole = try panelText(ClaudeUsageFixtures.whole)
        let size = cardSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28) + IslandPreset.tall.heightExtra)
        for chat in [9.0, 14.0, 18.0] {
            try save(Card(text: whole, size: size, chat: chat), size: CGSize(width: size.width + 30, height: size.height + 30), to: url(directory, "usage-chat\(Int(chat)).png"))
        }
        for tint in [TabTint.blue, .rose] {
            try save(Card(text: whole, size: size, tint: tint), size: CGSize(width: size.width + 30, height: size.height + 30), to: url(directory, "usage-tint-\(tint.rawValue).png"))
        }
        try save(Card(text: whole, size: size), size: CGSize(width: size.width + 30, height: size.height + 30), appearance: .aqua, to: url(directory, "usage-light-appearance.png"))
    }
}
