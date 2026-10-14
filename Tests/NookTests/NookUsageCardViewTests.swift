import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Nook's own usage card (the usage button's, `ClaudePanelCard(nookUsage:)`) as the island shows it: the words of Claude's last reading (the ring beside the per-model weeks, how old
/// it is, what is spoken), the toolbar with no keys of a panel's, the ways out that never press anything in the terminal, the card's place in the pane (Claude's own panel wins, nothing
/// to show is no card), and the renders for review (which run only when NOOK_RENDER_DIR is set). Nothing here makes a window key or sends a key: the cards are in borderless windows
/// far off the screen, read through their accessibility tree and pressed through it.
@MainActor
final class NookUsageCardViewTests: XCTestCase {
    // MARK: Fixtures

    /// What the status line sends for a session: its cost, its context, the model and the prompt cache.
    private func payload() -> ClaudeStatusPayload {
        let json: [String: Any] = [
            "session_id": "abc123", "transcript_path": "/Users/x/.claude/projects/p/abc123.jsonl",
            "cost": ["total_cost_usd": 1.75, "total_duration_ms": 496_000.0, "total_api_duration_ms": 254_000.0, "total_lines_added": 12, "total_lines_removed": 3],
            "context_window": ["used_percentage": 38.0, "remaining_percentage": 62.0, "context_window_size": 200_000, "total_input_tokens": 76_000],
            "model": ["id": "claude-opus-5-5", "display_name": "Opus 5.5"], "effort": ["level": "xhigh"],
            "prompt_cache": ["warm": true, "ttl": "1h", "requests": 22, "misses": 0, "hit_ratio": 0.95, "expires_at": Date().addingTimeInterval(3000).timeIntervalSince1970]]
        return ClaudeStatusPayload(json: json)!
    }

    /// Claude's own copy of its latest usage reading, taken `ago` seconds before `now`: the session, the week and the week of Fable (which only it has).
    private func snapshot(_ now: Date, ago: TimeInterval = 25 * 60, fable: Double = 41) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(fetchedAt: now.addingTimeInterval(-ago), limits: [
            .init(title: "Current session", percent: 3, resetsAt: now.addingTimeInterval(3 * 3600), dated: false),
            .init(title: "Current week (all models)", percent: 12, resetsAt: now.addingTimeInterval(5 * 86_400), dated: true),
            .init(title: "Current week (Fable)", percent: fable, resetsAt: now.addingTimeInterval(6 * 86_400), dated: true)])
    }

    /// The status line's reading, `read` seconds old, with Claude's own copy: the session and the week are live (the newer), the week of Fable is the copy's.
    private func live(_ now: Date, read: TimeInterval = 30, ago: TimeInterval = 25 * 60, spend: Bool = false, saved: Bool = true, session: Bool = true) -> ClaudeLiveUsage {
        let limits = ClaudeStatusPayload.RateLimits(
            fiveHour: .init(usedPercentage: 28, resetsAt: now.addingTimeInterval(4 * 3600)), sevenDay: .init(usedPercentage: 74, resetsAt: now.addingTimeInterval(5 * 86_400)),
            spendLimit: spend ? .init(usedPercentage: 24.6, resetsAt: now.addingTimeInterval(12 * 86_400), usedUSD: 12.3, limitUSD: 50, period: "monthly") : nil)
        return ClaudeLiveUsage(session: session ? payload() : nil, sessionAt: now.addingTimeInterval(-read), limits: limits, limitsAt: now.addingTimeInterval(-read),
                               saved: saved ? snapshot(now, ago: ago) : nil)
    }

    // MARK: The words

    func testTheRingSaysWhatItIsHowOldItIsAndWhyItIsNotLive() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let since = now.addingTimeInterval(-25 * 60)
        let tip = UsageSnapshot.tip(limit: "Current week (Fable)", since: since, now: now)
        XCTAssertEqual(tip.title, "Última lectura de Claude")
        XCTAssertEqual(tip.value, "hace 25 min")
        XCTAssertEqual(tip.detail, "Claude la guarda cada vez que consulta tu uso (al abrir /usage). La barra de estado no envía los límites por modelo.")
        // A limit the status line could have sent says only where the reading comes from: it is here because Claude's reading is the newer.
        let week = UsageSnapshot.tip(limit: "Current week (all models)", since: since, now: now)
        XCTAssertEqual(week.detail, "Claude la guarda cada vez que consulta tu uso (al abrir /usage).")
        XCTAssertEqual(UsageSnapshot.tip(limit: "Current session", since: since, now: now).detail, week.detail)
        // Without the time it was taken there is no age to say, and the rest is as it was.
        XCTAssertNil(UsageSnapshot.tip(limit: "Current week (Fable)", since: nil, now: now).value)
        XCTAssertEqual(UsageSnapshot.tip(limit: "Current week (Fable)", since: nil, now: now).detail, tip.detail)
        // Not the live dot's words.
        XCTAssertNotEqual(tip.title, "En vivo"); XCTAssertFalse(tip.detail?.contains(UsageLive.words) ?? true)
    }

    func testTheAgeIsSaidInPlainSightOnlyOnceItMatters() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        func line(_ ago: TimeInterval?) -> String? { UsageSnapshot.note(ago.map { now.addingTimeInterval(-$0) }, now: now) }
        XCTAssertEqual(UsageSnapshot.staleAfter, 15 * 60, "The same minutes the usage button's tip waits for.")
        XCTAssertNil(line(60)); XCTAssertNil(line(14 * 60), "Fresh enough to need no line: the ring's tip has its age.")
        XCTAssertNil(line(15 * 60), "At the limit it is not yet old.")
        XCTAssertEqual(line(16 * 60), "Última lectura de Claude, hace 16 min")
        XCTAssertEqual(line(25 * 60), "Última lectura de Claude, hace 25 min")
        XCTAssertEqual(line(5 * 3600), "Última lectura de Claude, hace 5 h")
        XCTAssertEqual(line(3 * 86_400), "Última lectura de Claude, hace 3 d")
        XCTAssertNil(line(nil), "Not knowing how old it is says nothing.")
        XCTAssertNil(UsageSnapshot.note(now.addingTimeInterval(120), now: now), "A clock a little behind is no old reading.")
    }

    /// Said once for the whole section, and only where some limit of it is that reading.
    func testTheNoteIsOnePerSectionAndOnlyWhereALimitIsTheLastReading() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let since = now.addingTimeInterval(-25 * 60)
        func meter(_ title: String, _ source: ClaudeUsage.Source) -> ClaudeUsage.Meter { .init(title: title, fraction: 0.4, label: "40% used", resets: nil, source: source, resetsSource: source) }
        let mixed = [meter("Current session", .live), meter("Current week (all models)", .live), meter("Current week (Fable)", .snapshot)]
        XCTAssertEqual(UsageSnapshot.note(for: mixed, since: since, now: now), "Última lectura de Claude, hace 25 min")
        XCTAssertEqual(UsageSnapshot.note(for: mixed.map { var meter = $0; meter.source = .snapshot; return meter }, since: since, now: now), "Última lectura de Claude, hace 25 min",
                       "Every limit being the reading does not say it three times: the note is the section's.")
        XCTAssertNil(UsageSnapshot.note(for: mixed.dropLast(), since: since, now: now), "No limit of it is the last reading: nothing to say.")
        XCTAssertNil(UsageSnapshot.note(for: mixed, since: now.addingTimeInterval(-5 * 60), now: now), "A fresh reading says it in the ring's tip.")
        XCTAssertNil(UsageSnapshot.note(for: mixed, since: since, now: now, dense: true), "A dense card leaves it to the tips.")
        XCTAssertNil(UsageSnapshot.note(for: mixed, since: nil, now: now))
        XCTAssertNil(UsageSnapshot.note(for: [], since: since, now: now))
    }

    /// What the tips drawn say is what the tips say, with "/usage" kept whole where the line breaks.
    func testTheTipsAreDrawnWithTheCommandInOnePiece() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        let since = now.addingTimeInterval(-25 * 60)
        let plain = UsageSnapshot.tip(limit: "Current week (Fable)", since: since, now: now), drawn = UsageSnapshot.drawnTip(limit: "Current week (Fable)", since: since, now: now)
        XCTAssertEqual(drawn.title, plain.title); XCTAssertEqual(drawn.value, plain.value)
        XCTAssertEqual(drawn.detail?.replacingOccurrences(of: "\u{2060}", with: ""), plain.detail)
        XCTAssertTrue(drawn.detail?.contains("/\u{2060}usage") ?? false, "No line ends on the slash alone.")
        let open = ClaudePanelCard.Own.openTip(running: true)
        XCTAssertEqual(open.title, "Detalle en Claude")
        // What it has to say: it opens /usage in Claude's terminal, for the full detail (the tokens by model, what feeds the limits), and refreshes the per-model reading.
        let detail = (open.detail ?? "").replacingOccurrences(of: "\u{2060}", with: "")
        for words in ["Abre /usage en la terminal de Claude", "detalle completo", "los tokens por modelo", "qué consume tus límites", "actualiza la lectura de los límites por modelo"] {
            XCTAssertTrue(detail.contains(words), "«\(words)» is missing from: \(detail)")
        }
        XCTAssertEqual(ClaudePanelCard.Own.openTip(running: false).detail, "La terminal está cerrada.")
        XCTAssertEqual(ClaudePanelCard.Own.closeTip.detail, "Esc también lo cierra")
    }

    func testWhatIsSpokenOfALastReading() {
        let now = Date(timeIntervalSince1970: 1_791_900_000)
        XCTAssertEqual(UsageSnapshot.spoken(since: now.addingTimeInterval(-25 * 60), now: now), "Última lectura de Claude, hace 25 min")
        XCTAssertEqual(UsageSnapshot.spoken(since: nil, now: now), "Última lectura de Claude")
        XCTAssertEqual(UsageSnapshot.age(now.addingTimeInterval(-10), now: now), "hace unos segundos")
        XCTAssertNil(UsageSnapshot.age(nil, now: now))
    }

    // MARK: The card, read through its accessibility tree

    private struct Node {
        var label: String
        var value: String
        var help: String
        var object: NSObject
    }

    /// Every labelled element of the window with its spoken value and help. SwiftUI builds its accessibility nodes only when assistive technology is on: the app is told it is (the
    /// setter `AccessibilityLookup` uses, called by its selector's name so the build has no warning for it).
    private func nodes(in window: NSWindow) -> [Node] {
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: true as NSNumber, with: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [Node] = []
        func walk(_ element: AnyObject) {
            guard let node = element as? NSObject else { return }
            if let label = node.value(forKey: "accessibilityLabel") as? String, !label.isEmpty {
                let value = (node.value(forKey: "accessibilityValue") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (node.value(forKey: "accessibilityValueDescription") as? String) ?? ""
                found.append(Node(label: label, value: value, help: node.value(forKey: "accessibilityHelp") as? String ?? "", object: node))
            }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child as AnyObject) }
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { walk(child as AnyObject) }
        return found
    }

    /// The window's accessibility "press" on the element with this label, as assistive technology would give it: no event, no key window. False when there is no such element.
    @discardableResult
    private func press(_ label: String, in window: NSWindow) -> Bool {
        guard let node = nodes(in: window).first(where: { $0.label == label }) else { return false }
        _ = node.object.perform(NSSelectorFromString("accessibilityPerformPress"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return true
    }

    private func hosted<V: View>(_ view: V, width: CGFloat = 540, height: CGFloat = 760) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return window
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private var keyLabels: [String] { [TerminalKey.left, .right, .up, .down, .tab, .enter].map(\.label) }

    func testALastReadingIsMarkedAndSpokenWithItsAgeAndALiveFigureIsNot() throws {
        let now = Date()
        let window = hosted(ClaudePanelCard(nookUsage: live(now, spend: true), growsIsland: true, now: now))
        defer { window.close() }
        let said = nodes(in: window)
        func value(_ label: String) -> String? { said.first { $0.label == label }?.value }
        let fable = try XCTUnwrap(value("Semana actual (Fable)"), "\(said.map(\.label))")
        XCTAssertTrue(fable.contains("Última lectura de Claude, hace 25 min"), fable)
        XCTAssertTrue(fable.hasPrefix("41 % usado"), "The figure Claude's own reading has, which the status line never sends: \(fable)")
        XCTAssertFalse(fable.contains("en vivo"), fable)
        // The session and the week came from the status line, newer than the copy: live, and not a last reading.
        let session = try XCTUnwrap(value("Sesión actual")), week = try XCTUnwrap(value("Semana actual (todos los modelos)"))
        XCTAssertTrue(session.contains("en vivo") && week.contains("en vivo"), "\(session) / \(week)")
        XCTAssertFalse(session.contains("Última lectura") || week.contains("Última lectura"), "\(session) / \(week)")
        XCTAssertTrue(session.hasPrefix("28 % usado"), session)
        // What the status line adds of the session is there too.
        XCTAssertNotNil(value(UsageWords.stat("Total cost")))
        XCTAssertTrue(try XCTUnwrap(value("Contexto")).hasPrefix("38 %"))
    }

    func testAFreshReadingIsMarkedAllTheSameAndSaysItsAge() throws {
        let now = Date()
        let window = hosted(ClaudePanelCard(nookUsage: live(now, ago: 4 * 60), growsIsland: true, now: now))
        defer { window.close() }
        let fable = try XCTUnwrap(nodes(in: window).first { $0.label == "Semana actual (Fable)" }?.value)
        XCTAssertTrue(fable.contains("Última lectura de Claude, hace 4 min"), "The mark is for what it is, not for how old: \(fable)")
    }

    func testNooksCardHasNoKeysOfAPanelAndNoPanelWords() throws {
        let now = Date()
        let window = hosted(ClaudePanelCard(nookUsage: live(now), growsIsland: true, now: now))
        defer { window.close() }
        let said = nodes(in: window)
        let labels = said.map(\.label)
        for key in keyLabels { XCTAssertFalse(labels.contains(key), "\(key) is a key of Claude's panel: \(labels)") }
        XCTAssertFalse(labels.contains("Cerrar el panel"), "That one presses Esc in the terminal.")
        XCTAssertFalse(labels.contains("Panel de Claude"), "It is Nook's card: \(labels)")
        XCTAssertFalse(said.contains { $0.help.contains("Claude muestra este panel") }, "The panel's help is not the card's.")
        XCTAssertFalse(said.contains { $0.help.contains("Se cierra con Esc") })
        XCTAssertTrue(labels.contains("Uso y límites"), "It says what it is: \(labels)")
        XCTAssertTrue(labels.contains("Cerrar uso y límites"), "\(labels)")
        XCTAssertTrue(labels.contains("Ver el detalle en Claude"), "\(labels)")
    }

    /// The control: Claude's own panel card still has its keys, its «Cerrar el panel» and its words, and none of Nook's.
    func testClaudesOwnPanelCardIsAsItWas() throws {
        let window = hosted(ClaudePanelCard(text: ClaudePanelFixtures.usage, growsIsland: true))
        defer { window.close() }
        let said = nodes(in: window)
        let labels = said.map(\.label)
        for key in keyLabels { XCTAssertTrue(labels.contains(key), "\(key): \(labels)") }
        XCTAssertTrue(labels.contains("Cerrar el panel")); XCTAssertTrue(labels.contains("Panel de Claude"))
        XCTAssertTrue(said.contains { $0.help.contains("Claude muestra este panel") || $0.help.contains("cerrar el panel de Claude") }, "Its helps: \(said.map(\.help))")
        XCTAssertFalse(labels.contains("Cerrar uso y límites")); XCTAssertFalse(labels.contains("Ver el detalle en Claude"))
    }

    func testCerrarAndEscCloseNooksCardAndNothingElseIsAKeyOfIt() throws {
        let now = Date()
        var closed = 0, opened = 0
        let window = hosted(ClaudePanelCard(nookUsage: live(now), growsIsland: true, now: now, onClose: { closed += 1 }, onOpenClaude: { opened += 1 }))
        defer { window.close() }
        XCTAssertTrue(press("Cerrar uso y límites", in: window))
        XCTAssertEqual(closed, 1, "«Cerrar · esc» closes the card.")
        XCTAssertEqual(opened, 0)
        // Esc is the card's own key: it takes the keyboard like the panel's card does, and closes the card.
        let catcher = try XCTUnwrap(Self.find(PanelKeyView.self, in: try XCTUnwrap(window.contentView)), "The card takes the keyboard for Esc.")
        catcher.onKey?(.escape)
        XCTAssertEqual(closed, 2, "Esc closes it too.")
        // The keys of a panel are nobody's here: none of them does anything.
        for key in [TerminalKey.left, .right, .up, .down, .tab, .enter] { catcher.onKey?(key) }
        XCTAssertEqual(closed, 2); XCTAssertEqual(opened, 0)
    }

    func testDetalleEnClaudeAsksForClaudesPanelAndWaitsWhileItOpens() throws {
        let now = Date()
        var opened = 0, closed = 0
        let window = hosted(ClaudePanelCard(nookUsage: live(now), growsIsland: true, now: now, onClose: { closed += 1 }, onOpenClaude: { opened += 1 }))
        defer { window.close() }
        XCTAssertTrue(press("Ver el detalle en Claude", in: window))
        XCTAssertEqual(opened, 1); XCTAssertEqual(closed, 0, "Asking for Claude's panel is not closing Nook's card: the island hands it over.")
        // While that /usage is on its way it is not a button but what is happening: it does not ask twice.
        var again = 0
        let waiting = self.hosted(ClaudePanelCard(nookUsage: live(now), growsIsland: true, opening: true, now: now, onOpenClaude: { again += 1 }))
        defer { waiting.close() }
        XCTAssertFalse(press("Ver el detalle en Claude", in: waiting), "No button to press while it opens.")
        XCTAssertEqual(again, 0)
        XCTAssertTrue(nodes(in: waiting).contains { $0.label == "Abriendo el detalle en Claude" }, "It says what is happening.")
        // And with the terminal closed there is nowhere to ask it, though the card closes all the same.
        var dead = 0, deadClosed = 0
        let gone = self.hosted(ClaudePanelCard(nookUsage: live(now), running: false, growsIsland: true, now: now, onClose: { deadClosed += 1 }, onOpenClaude: { dead += 1 }))
        defer { gone.close() }
        press("Ver el detalle en Claude", in: gone)
        XCTAssertEqual(dead, 0, "No terminal, no /usage.")
        press("Cerrar uso y límites", in: gone)
        XCTAssertEqual(deadClosed, 1, "Closing needs no terminal.")
    }

    func testNooksCardAsksTheIslandForRoomAsTheUsageCardDoes() throws {
        final class Box { var room: IslandRoom? }
        let box = Box()
        let now = Date()
        let view = ClaudePanelCard(nookUsage: live(now), growsIsland: true, now: now).frame(width: 510, height: 300).padding(15)
            .onPreferenceChange(IslandRoomKey.self) { box.room = $0 }
        let window = hosted(view, width: 540, height: 330)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let room = try XCTUnwrap(box.room, "It asks, as the usage card does.")
        XCTAssertGreaterThan(room.height, ClaudePanelCard.toolbarHeight + 100)
        XCTAssertEqual(room.width, 510, accuracy: 1)
        // An island that does not grow for it asks for nothing.
        let quiet = Box()
        let still = self.hosted(ClaudePanelCard(nookUsage: live(now), growsIsland: false, now: now).frame(width: 510, height: 300).padding(15)
            .onPreferenceChange(IslandRoomKey.self) { quiet.room = $0 }, width: 540, height: 330)
        defer { still.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(quiet.room)
    }

    func testWithNothingToShowTheCardIsEmptyAndNooksCardAsksForNothing() throws {
        XCTAssertNil(ClaudeUsage.nookCard(from: nil))
        // Every limit it had has reset, and there is no session: nothing is left.
        let now = Date()
        let over = ClaudeLiveUsage(session: nil, sessionAt: nil, limits: .init(fiveHour: .init(usedPercentage: 9, resetsAt: now.addingTimeInterval(-60)), sevenDay: nil, spendLimit: nil), limitsAt: now)
        XCTAssertNil(ClaudeUsage.nookCard(from: over, now: now))
        let window = hosted(ClaudePanelCard(nookUsage: over, growsIsland: true, now: now))
        defer { window.close() }
        let labels = nodes(in: window).map(\.label)
        XCTAssertTrue(labels.contains("Uso y límites"))
        XCTAssertFalse(labels.contains { $0.hasPrefix("Sesión") || $0.hasPrefix("Semana") }, "No figure is made up: \(labels)")
    }

    // MARK: The card in the pane

    /// A tab in an island's pane with Nook's card asked for. Nothing can reach a terminal: the keys are caught by `AppModel.keySender`, and the session has no bridge.
    @MainActor private final class Rig {
        /// What the island reports and what it presses, kept where the closures given to SwiftUI and to the model can reach before the rig is whole.
        final class Recorder { var sent: [TerminalKey] = []; var room: IslandRoom?; var rooms: [IslandRoom?] = []; var noticeBelow: CGFloat?; var tip: NookTipEntry? }

        let recorder = Recorder()
        let model: AppModel
        let session: TerminalSession
        let window: NSWindow
        let host: NSHostingView<AnyView>
        var sent: [TerminalKey] { recorder.sent }
        var room: IslandRoom? { recorder.room }
        /// Every ask the card made of the island, in order.
        var rooms: [IslandRoom?] { recorder.rooms }
        /// How far under the card's top a notice hangs, as the pane reports it (`NoticeAreaKey`).
        var noticeBelow: CGFloat? { recorder.noticeBelow }
        /// The tip the island has to show (`NookTipKey`): one that is pinned, as no pointer is resting on anything here.
        var tip: NookTipEntry? { recorder.tip }

        init(live: ClaudeLiveUsage?, open: Bool = true, screen: String = ClaudePanelFixtures.closed, pinned: String? = nil) {
            model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-usagecard-pane-" + UUID().uuidString)!)
            session = TerminalSession(tab: Self.tab(screen), backend: .bundled, bridge: model.terminalBridge)
            session.terminalBridge = nil
            session.transcriptLocated = Date()
            session.liveUsage = live
            session.usageCardOpen = open
            model.sessions = [session]; model.selectedID = session.id
            let recorder = self.recorder
            model.keySender = { key, _ in recorder.sent.append(key) }
            host = NSHostingView(rootView: AnyView(SessionPane(model: model, session: session, growsIsland: true).frame(width: 572, height: 460)
                .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false).environment(\.nookTipPinned, pinned)
                .onPreferenceChange(IslandRoomKey.self) { recorder.room = $0; recorder.rooms.append($0) }
                .onPreferenceChange(NookTipKey.self) { recorder.tip = $0 }
                .backgroundPreferenceValue(NoticeAreaKey.self) { area in Color.clear.onChange(of: area?.below, initial: true) { _, below in recorder.noticeBelow = below } }))
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 572, height: 460), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            Self.settle(0.6)
        }

        static func tab(_ screen: String, processes: [String] = ["login", "-zsh", "claude"]) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "", processes: processes, busy: false, selected: true, text: screen)
        }

        static func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        /// Runs the island until `done` holds (or `timeout` passes): a card leaves after a task's sleep and an animation, and how long that takes depends on the machine's load.
        static func settle(until done: () -> Bool, timeout: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        func clearRooms() { recorder.rooms = [] }
        func close() { window.close() }
    }

    private func labels(_ rig: Rig) -> [String] { nodes(in: rig.window).map(\.label) }

    func testTheUsageButtonsCardTakesTheConversationsPlaceAndClosingItPressesNothing() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        let shown = labels(rig)
        XCTAssertTrue(shown.contains("Uso y límites"), "Nook's card is on show: \(shown)")
        XCTAssertTrue(shown.contains("Semana actual (Fable)"), "With the week of Fable, which was the card's missing figure: \(shown)")
        XCTAssertFalse(shown.contains("Panel de Claude"))
        // The conversation's composer is under the card (and out of VoiceOver's way): with the card not asked for, it is there.
        let composer: Set<String> = ["Enviar", "Mensaje", "Mostrar las teclas de menú"]
        let plain = Rig(live: live(Date()), open: false)
        defer { plain.close() }
        XCTAssertFalse(composer.isDisjoint(with: labels(plain)), "The control: the composer's own labels are in the tree: \(labels(plain))")
        XCTAssertTrue(composer.isDisjoint(with: shown), "The composer is under the card: \(shown)")
        XCTAssertNotNil(Self.find(PanelKeyView.self, in: rig.host), "It has the keyboard, for Esc.")
        XCTAssertNotNil(rig.room, "The island grows for it as it does for the panel's usage card.")
        XCTAssertTrue(press("Cerrar uso y límites", in: rig.window))
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen, "«Cerrar» closes it in Nook.")
        XCTAssertEqual(rig.sent, [], "Nothing was pressed in the terminal.")
        XCTAssertNil(rig.session.pendingMessage, "Nothing was typed in it.")
        Rig.settle(until: { !self.labels(rig).contains("Uso y límites") })
        XCTAssertFalse(labels(rig).contains("Uso y límites"), "The conversation and its field are back.")
        XCTAssertNil(rig.room, "…and the island is asked for nothing.")
    }

    /// The card is made again whenever its figures change (and every minute, for the ages): it is the same card, so it keeps the keyboard and its measure, and the island it
    /// has grown is not asked to shrink and grow again.
    func testTheCardKeepsItsKeyboardAndItsAskWhenItsFiguresChange() throws {
        let now = Date()
        let rig = Rig(live: live(now))
        defer { rig.close() }
        let before = try XCTUnwrap(Self.find(PanelKeyView.self, in: rig.host))
        let asked = try XCTUnwrap(rig.room)
        rig.clearRooms()
        // Claude answered: a new reading of the session, a new limit figure.
        var next = live(now, read: 5)
        next.limits?.fiveHour = .init(usedPercentage: 31, resetsAt: now.addingTimeInterval(4 * 3600))
        rig.session.liveUsage = next
        Rig.settle(0.8)
        XCTAssertTrue(Self.find(PanelKeyView.self, in: rig.host) === before, "The key view is the same one: the card was not rebuilt from nothing.")
        XCTAssertFalse(rig.rooms.contains { $0 == nil }, "The card never took its ask back: \(rig.rooms)")
        XCTAssertEqual(rig.room?.height ?? 0, asked.height, accuracy: 6, "…and it asks for what it did.")
        XCTAssertTrue(labels(rig).contains("Uso y límites"))
        let said = nodes(in: rig.window)
        XCTAssertTrue(said.first { $0.label == "Sesión actual" }?.value.hasPrefix("31 % usado") ?? false, "The new figure is on show: \(said.first { $0.label == "Sesión actual" }?.value ?? "none")")
    }

    /// A notice (a file dropped, an error) hangs from under the card's toolbar, as it does under Claude's panel's: the card reports where, through the minute's timeline too.
    func testANoticeHangsFromUnderNooksCardsToolbar() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        XCTAssertEqual(rig.noticeBelow, ClaudePanelCard.toolbarHeight, "The card's own area, under its toolbar.")
        let plain = Rig(live: live(Date()), open: false)
        defer { plain.close() }
        XCTAssertEqual(plain.noticeBelow, 0, "The conversation's, when the card is not on show.")
    }

    /// The tips the card adds reach the island's own layer, which draws them over the control: pinned, since no pointer rests on anything here.
    func testTheCardsTipsReachTheIslandsLayer() throws {
        for (id, title) in [("usage-open-claude", "Detalle en Claude"), ("usage-card-close", "Cerrar"), ("usage-saved-limit-Current week (Fable)", "Última lectura de Claude")] {
            let rig = Rig(live: live(Date()), pinned: id)
            defer { rig.close() }
            let entry = try XCTUnwrap(rig.tip, "\(id): the island has a tip to show.")
            XCTAssertEqual(entry.id, id)
            XCTAssertEqual(entry.tip.title, title)
            switch id {
            case "usage-open-claude": XCTAssertEqual(entry.tip, ClaudePanelCard.Own.openTip(running: true))
            case "usage-card-close": XCTAssertEqual(entry.tip, ClaudePanelCard.Own.closeTip)
            default:
                XCTAssertEqual(entry.tip.value, "hace 25 min")
                XCTAssertTrue(entry.tip.detail?.contains("por modelo") ?? false, "The week of a model says why it is never live: \(entry.tip.detail ?? "")")
            }
        }
    }

    func testEscClosesTheCardInNookAndNeverPressesAKey() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        let catcher = try XCTUnwrap(Self.find(PanelKeyView.self, in: rig.host))
        catcher.onKey?(.left); catcher.onKey?(.enter)
        XCTAssertTrue(rig.session.usageCardOpen, "The keys of a panel are not the card's.")
        catcher.onKey?(.escape)
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen)
        XCTAssertEqual(rig.sent, [], "Esc stayed in Nook: the terminal never saw it (and Terminal never came to the front for it).")
        XCTAssertNil(rig.session.panelEscapedAt)
    }

    func testClaudesOwnPanelTakesTheCardsPlaceAndNooksCardIsClosed() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        XCTAssertTrue(labels(rig).contains("Uso y límites"))
        // The user typed /usage in the terminal: Claude's panel is open.
        rig.session.update(Rig.tab(ClaudePanelFixtures.screen(ClaudePanelFixtures.usage)))
        Rig.settle(until: { self.labels(rig).contains("Panel de Claude") })
        let shown = labels(rig)
        XCTAssertTrue(shown.contains("Panel de Claude"), "Claude's own panel wins: \(shown)")
        XCTAssertFalse(shown.contains("Uso y límites"), "…and Nook's card gives way: \(shown)")
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen, "It does not wait behind Claude's panel to come back when that closes.")
        // Claude's panel, once it closes, leaves the conversation: Nook's card does not come back.
        rig.session.update(Rig.tab(ClaudePanelFixtures.closed))
        Rig.settle(until: { !self.labels(rig).contains("Panel de Claude") }, timeout: 6)
        Rig.settle(0.3)
        XCTAssertFalse(labels(rig).contains("Uso y límites"))
        XCTAssertFalse(labels(rig).contains("Panel de Claude"))
    }

    func testNoFigureNoCard() throws {
        let now = Date()
        let over = ClaudeLiveUsage(session: nil, sessionAt: nil, limits: .init(fiveHour: .init(usedPercentage: 9, resetsAt: now.addingTimeInterval(-60)), sevenDay: nil, spendLimit: nil), limitsAt: now)
        let rig = Rig(live: over)
        defer { rig.close() }
        XCTAssertFalse(labels(rig).contains("Uso y límites"), "With nothing to show the pane shows no card: \(labels(rig))")
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen, "…and does not keep one asked for, which would come back by itself with the next figures.")
        // Not asked for: no card either, whatever the figures.
        let closed = Rig(live: live(now), open: false)
        defer { closed.close() }
        XCTAssertFalse(labels(closed).contains("Uso y límites"))
    }

    func testTheCardGoesWhenClaudeQuitsInTheTab() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        XCTAssertEqual(rig.session.agent, .claude)
        XCTAssertTrue(labels(rig).contains("Uso y límites"))
        // Claude quit: the tab is a shell again. A usage card of Claude's has nothing to be about, and «Detalle en Claude» nothing to ask.
        rig.session.update(Rig.tab("~ % ", processes: ["login", "-zsh"]))
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen)
        XCTAssertNil(rig.session.agent)
        Rig.settle(0.4)
        XCTAssertFalse(labels(rig).contains("Uso y límites"))
        XCTAssertEqual(rig.sent, [])
    }

    func testPuttingTheIslandAwayClosesTheCard() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        rig.model.islandContentVisible = true
        Rig.settle(0.3)
        XCTAssertTrue(rig.session.usageCardOpen)
        rig.model.islandContentVisible = false
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen, "A glance at the limits does not wait for the island's next opening.")
    }

    func testWhileClaudesPanelIsOnItsWayNooksCardStaysAndThenHandsOver() throws {
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        // «Detalle en Claude»: the model closes Nook's card and types /usage (with no bridge in this tab, nothing reaches a terminal here); the pane keeps the card up, so that the
        // conversation does not show for a moment between the two.
        XCTAssertTrue(press("Ver el detalle en Claude", in: rig.window))
        Rig.settle(until: { !rig.session.usageCardOpen })
        XCTAssertFalse(rig.session.usageCardOpen, "The model closed it.")
        Rig.settle(0.3)
        XCTAssertTrue(labels(rig).contains("Uso y límites"), "…and the card stays until Claude's panel is there: \(labels(rig))")
        // Claude's panel arrives: it takes the card's place.
        rig.session.update(Rig.tab(ClaudePanelFixtures.screen(ClaudePanelFixtures.usage)))
        Rig.settle(until: { self.labels(rig).contains("Panel de Claude") })
        XCTAssertTrue(labels(rig).contains("Panel de Claude"))
        XCTAssertFalse(labels(rig).contains("Uso y límites"), "The panel took over.")
    }

    func testTheCardLetsGoWhenClaudesPanelNeverComes() throws {
        // Long enough to look at the card while it waits (reading the accessibility tree takes the run loop a moment each time), short enough not to hold the test up.
        let hold = UsageCardLifecycle.handoffHold
        UsageCardLifecycle.handoffHold = 2.5
        defer { UsageCardLifecycle.handoffHold = hold }
        let rig = Rig(live: live(Date()))
        defer { rig.close() }
        XCTAssertTrue(press("Ver el detalle en Claude", in: rig.window))
        Rig.settle(until: { !rig.session.usageCardOpen })
        let waiting = labels(rig)
        XCTAssertTrue(waiting.contains("Uso y límites"), "Held while Claude's panel is awaited: \(waiting)")
        XCTAssertTrue(waiting.contains("Abriendo el detalle en Claude"), "…and the toolbar says so: \(waiting)")
        // No panel arrives (the terminal did not take the /usage): the card goes and the conversation is back.
        Rig.settle(until: { !self.labels(rig).contains("Uso y límites") }, timeout: 6)
        XCTAssertFalse(labels(rig).contains("Uso y límites"), "It does not wait for ever.")
        XCTAssertFalse(rig.session.usageCardOpen)
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the usage card.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name = .darkAqua, to path: String) throws {
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

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// The card as the pane gives it room in an island this wide, tall enough for all of it (what the island grows to for it), in the island's own dark or light.
    private struct Card: View {
        var live: ClaudeLiveUsage
        var now: Date
        var size: CGSize
        var chat = DisplaySettings.defaultChatSize
        var opening = false
        var scheme: ColorScheme = .dark
        /// The island grows for the card (the real island's); without it the card is drawn for the room it has, dense where that is little.
        var grows = true
        var body: some View {
            ClaudePanelCard(nookUsage: live, fontSize: chat, growsIsland: grows, opening: opening, now: now).tabTint(.mint)
                .frame(width: size.width, height: size.height).padding(15)
                .background(scheme == .dark ? Color.black : Color(white: 0.97)).environment(\.colorScheme, scheme).environment(\.nookDarkBackdrop, scheme == .dark).environment(\.nookTintedGlass, false)
        }
    }

    /// Nook's own usage card in the cases that matter: the week of Fable from a reading 25 minutes old beside live limits and the session's figures; one fresh, one hours old, one
    /// that is all Claude's reading; at the usual island's width and the narrowest, in dark and in light.
    func testRenderNooksOwnUsageCard() throws {
        let directory = try renderDirectory()
        let now = Date()
        let usual = CGSize(width: NotchGeometry.expandedWidth - 30, height: 470)
        let narrow = CGSize(width: NotchGeometry.minExpandedWidth - 30, height: 520)
        let wide = CGSize(width: NotchGeometry.expandedWidth + IslandPreset.wide.widthExtra - 30, height: 400)
        func canvas(_ size: CGSize) -> CGSize { CGSize(width: size.width + 30, height: size.height + 30) }
        try write(Card(live: live(now, spend: true), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-25min.png"))
        try write(Card(live: live(now, ago: 4 * 60), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-fresh.png"))
        try write(Card(live: live(now, ago: 5 * 3600), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-5h.png"))
        try write(Card(live: live(now, read: 3600, ago: 25 * 60), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-all-saved.png"))
        try write(Card(live: live(now, saved: false), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-no-saved.png"))
        try write(Card(live: live(now, session: false), now: now, size: usual), size: canvas(usual), to: url(directory, "nook-card-limits-only.png"))
        try write(Card(live: live(now), now: now, size: narrow), size: canvas(narrow), to: url(directory, "nook-card-narrow.png"))
        try write(Card(live: live(now), now: now, size: wide), size: canvas(wide), to: url(directory, "nook-card-wide.png"))
        try write(Card(live: live(now), now: now, size: usual, opening: true), size: canvas(usual), to: url(directory, "nook-card-opening.png"))
        // An island that does not grow for it (a pane in a preview): the usual island's room, which makes the card dense.
        let short = CGSize(width: usual.width, height: ClaudePanelCard.height(inIsland: NotchGeometry.expandedHeight(topInset: 28), neck: 28))
        try write(Card(live: live(now), now: now, size: short, grows: false), size: canvas(short), to: url(directory, "nook-card-dense.png"))
        try write(Card(live: live(now), now: now, size: usual, scheme: .light), size: canvas(usual), appearance: .aqua, to: url(directory, "nook-card-light.png"))
        try write(Card(live: live(now, ago: 5 * 3600), now: now, size: usual, scheme: .light), size: canvas(usual), appearance: .aqua, to: url(directory, "nook-card-5h-light.png"))
        for chat in [9.0, 14.0, 18.0] {
            try write(Card(live: live(now), now: now, size: CGSize(width: usual.width, height: 560), chat: chat), size: CGSize(width: usual.width + 30, height: 590), to: url(directory, "nook-card-chat\(Int(chat)).png"))
        }
    }

    /// Claude's own panel card of a Terminal tab scrolled past the limits, with the status line on: the week of Fable comes from Claude's last reading there too, with its ring and the
    /// note under the limits (the panel's own rows win wherever the screen has them).
    func testRenderClaudesPanelCardWithTheLastReadingFillingTheWeekOfAModel() throws {
        let directory = try renderDirectory()
        let now = Date()
        let cut = ClaudeUsageFixtures.screen(top: ClaudeUsageFixtures.body.firstIndex { $0.contains("What's contributing") }!, height: 40)
        let view = ClaudePanelCard(text: cut, growsIsland: true, live: live(now), now: now).frame(width: 690, height: 760).padding(15).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        try write(view, size: CGSize(width: 720, height: 790), to: url(directory, "claude-panel-with-last-reading.png"))
    }

    /// The tips the card adds: the ring's, and the toolbar's two.
    func testRenderTheTipsOfNooksCard() throws {
        let directory = try renderDirectory()
        let now = Date()
        let tips: [NookTip] = [
            UsageSnapshot.drawnTip(limit: "Current week (Fable)", since: now.addingTimeInterval(-25 * 60), now: now),
            UsageSnapshot.drawnTip(limit: "Current week (all models)", since: now.addingTimeInterval(-3 * 3600), now: now),
            ClaudePanelCard.Own.openTip(running: true),
            ClaudePanelCard.Own.openTip(running: false),
            ClaudePanelCard.Own.closeTip,
            try XCTUnwrap(UsageGlance.tip(from: live(now), now: now)),
        ]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in NookTipBubble(tip: tip).frame(maxWidth: 300, alignment: .leading) }
        }.padding(24).frame(width: 350, alignment: .leading).background(Color(white: 0.06)).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: view)
        try write(view, size: host.fittingSize, to: url(directory, "nook-card-tips.png"))
    }

    /// The whole island with Nook's card open on a Claude tab: the usual island, which the card grows (the controller does that; here the island keeps its size and the card scrolls)
    /// and the tall one.
    func testRenderTheIslandWithNooksCard() throws {
        let directory = try renderDirectory()
        for (name, settings) in [("normal", DisplaySettings()), ("tall", DisplaySettings().applying(.tall)), ("wide", DisplaySettings().applying(.wide))] {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
            model.neckWithoutWindow = 32
            model.display = settings
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "claude", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                          text: ClaudePanelFixtures.closed)
            let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true; model.islandContentVisible = true
            model.updateActivity()
            session.liveUsage = live(Date(), spend: true)
            session.usageCardOpen = true
            let size = model.islandSize
            try write(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: size, to: url(directory, "nook-island-\(name).png"))
        }
    }
}
