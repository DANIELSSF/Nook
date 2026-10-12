import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Nook

/// The pointer over the island's controls. SwiftTerm's view claims an I-beam over all of its bounds, and a Nook session keeps that view laid
/// out under the whole pane while Claude's conversation is mirrored. Drawn clear it still counted for AppKit (a cursor rect looks at what the
/// view is, never at what is drawn over it), so the I-beam showed over the effort levels, the buttons and a question's card. These tests hold
/// the terminal to being hidden from AppKit, and the pane to having nothing claim the pointer but the two text fields' own.
@MainActor
final class CursorTests: XCTestCase {
    /// A cursor rect somebody asked AppKit for. `rect` is in the owner's coordinates.
    private struct Claim {
        var owner: NSView
        var rect: NSRect
        var cursor: NSCursor
        /// Where AppKit would apply it, in window coordinates: the rect clipped to what its owner shows of itself, which is nothing for a hidden view.
        var applied: NSRect? {
            let shown = rect.intersection(owner.visibleRect)
            return shown.isEmpty ? nil : owner.convert(shown, to: nil)
        }
    }

    private final class Recording { var claims: [Claim] = [] }

    /// What the views under `root` ask for when the window has them set up their cursor rects, as it does on every layout, whether or not
    /// they are applied. Only the claims AppKit would apply are returned.
    private func appliedClaims(under root: NSView) -> [Claim] {
        let recording = Recording()
        let method = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:)))!
        let record: @convention(block) (NSView, NSRect, NSCursor) -> Void = { owner, rect, cursor in recording.claims.append(Claim(owner: owner, rect: rect, cursor: cursor)) }
        let original = method_setImplementation(method, imp_implementationWithBlock(record))
        defer { method_setImplementation(method, original) }
        func visit(_ view: NSView) { view.resetCursorRects(); view.subviews.forEach(visit) }
        visit(root)
        return recording.claims.filter { $0.applied != nil }
    }

    private func descendants<V: NSView>(of root: NSView, as type: V.Type) -> [V] {
        var found: [V] = []
        func visit(_ view: NSView) { if let match = view as? V { found.append(match) }; view.subviews.forEach(visit) }
        visit(root)
        return found
    }

    private func mount<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        settle(host)
        return (window, host)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
    }

    private static let tty = "/dev/ttys042"

    /// A Nook session (tmux, nothing behind it: the process is `true`) with Claude on its pane, so its conversation is mirrored.
    private func claudeSession(_ model: AppModel, screen: [String]) -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-cursor-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-cursor-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: Self.tty, processes: ["claude"], text: screen.joined(separator: "\n"))
        // The process behind the session is `true`, which ends at once and says so; the island shows a live one.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        session.isRunning = true
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        return session
    }

    // MARK: The terminal

    /// The terminal as `SessionPane.hiddenTerminal` stands it: the width of the pane less the margins, drawn clear, taking no clicks.
    private struct Underlay: View {
        var session: TerminalSession
        var hidden: Bool
        var fontSize = 13.0
        var width: CGFloat = 600
        var body: some View {
            Color.clear.frame(width: width, height: 300)
                .background {
                    TerminalSurface(session: session, fontSize: fontSize, hidden: hidden)
                        .padding(.horizontal, 28).padding(.vertical, 4).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }

    private func anySession() -> TerminalSession {
        claudeSession(AppModel(receivesSignals: false), screen: ["> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", String(repeating: "─", count: 72), "❯ ", String(repeating: "─", count: 72)])
    }

    func testATerminalDrawnClearButNotHiddenClaimsTheIBeamOverItsWholeArea() {
        // The premise of hiding it: SwiftTerm's view claims the I-beam across its bounds, and opacity 0 does not stop that.
        let session = anySession()
        let (window, host) = mount(Underlay(session: session, hidden: false), size: NSSize(width: 600, height: 300))
        let claims = appliedClaims(under: host).filter { $0.owner === session.terminal }
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(claims.first?.cursor, NSCursor.iBeam)
        XCTAssertEqual(claims.first?.applied?.size, session.terminal.frame.size, "Over its whole area.")
        _ = window
    }

    func testAHiddenTerminalClaimsNothingYetIsSizedLikeAShownOne() {
        let hiddenSession = anySession(), shownSession = anySession()
        let (hiddenWindow, hiddenHost) = mount(Underlay(session: hiddenSession, hidden: true), size: NSSize(width: 600, height: 300))
        let (shownWindow, _) = mount(Underlay(session: shownSession, hidden: false), size: NSSize(width: 600, height: 300))
        let hidden = hiddenSession.terminal, shown = shownSession.terminal

        XCTAssertTrue(hidden.isHidden)
        XCTAssertTrue(appliedClaims(under: hiddenHost).filter { $0.owner === hidden }.isEmpty, "A hidden view's rect is clipped away.")
        // Hidden, it is still laid out: tmux sizes the agent's pane to this view, and a pane that shrank would make Claude redraw for nobody.
        XCTAssertNotNil(hidden.window)
        XCTAssertEqual(hidden.frame.size, NSSize(width: 544, height: 292))
        XCTAssertEqual(hidden.frame.size, shown.frame.size)
        XCTAssertEqual(hidden.getTerminal().cols, shown.getTerminal().cols)
        XCTAssertEqual(hidden.getTerminal().rows, shown.getTerminal().rows)
        XCTAssertGreaterThan(hidden.getTerminal().cols, 40)
        _ = (hiddenWindow, shownWindow)
    }

    func testAHiddenTerminalKeepsFollowingTheIslandsSizeAndTheTextSize() {
        let session = anySession()
        let (window, host) = mount(Underlay(session: session, hidden: true), size: NSSize(width: 600, height: 300))
        let before = (cols: session.terminal.getTerminal().cols, rows: session.terminal.getTerminal().rows)
        host.rootView = Underlay(session: session, hidden: true, fontSize: 16, width: 520)
        host.setFrameSize(NSSize(width: 520, height: 300))
        settle(host)
        XCTAssertEqual(session.terminal.frame.width, 464, "The pane's width follows the island's.")
        XCTAssertLessThan(session.terminal.getTerminal().cols, before.cols)
        XCTAssertLessThan(session.terminal.getTerminal().rows, before.rows, "A larger text size takes fewer rows.")
        XCTAssertTrue(session.terminal.isHidden)
        _ = window
    }

    func testTheSessionsOneTerminalIsShownAgainWhereItsConversationIsNotMirrored() {
        // The same view stands in two places (hidden under the mirror, or the conversation itself), so each pass says which.
        let session = anySession()
        let (window, host) = mount(Underlay(session: session, hidden: true), size: NSSize(width: 600, height: 300))
        XCTAssertTrue(session.terminal.isHidden)
        host.rootView = Underlay(session: session, hidden: false)
        settle(host)
        XCTAssertFalse(session.terminal.isHidden)
        XCTAssertFalse(session.terminal.visibleRect.isEmpty)
        host.rootView = Underlay(session: session, hidden: true)
        settle(host)
        XCTAssertTrue(session.terminal.isHidden)
        _ = window
    }

    // MARK: The pane

    private enum PaneState: String, CaseIterable { case closed, levelsOpen, attachments, question, keys, usageCard, coveringQuestion }

    private let conversationScreen = ["> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", String(repeating: "─", count: 72), "❯ ", String(repeating: "─", count: 72)]

    private let permission = ["⏺ Voy a limpiar la carpeta de compilación.", "", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "   Delete the build folder", "",
                              " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"]

    /// So many options that the card takes the pane and the conversation steps aside.
    private let manyOptions = ["⏺ Elige la sesión que quieres retomar.", "", " Resume Session", "", " ❯ Fix the island's collapse while a question is open", "   Redesign the composer with glass",
                               "   Add recap card to the tab row", "   Subagent capsule polish", "   Pet animation timing", "   Terminal bridge delivery logging", "   Image paste with control V", "",
                               " Enter to select · Esc to cancel"]

    private struct PaneIsland: View {
        var model: AppModel
        var session: TerminalSession
        var keysOpen = false
        var attachments: [String]?
        var effortOpen = false
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 28)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, keysOpen: keysOpen, attachments: attachments, effortOpen: effortOpen).id(session.id)
            }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28), alignment: .top).background(Color.black)
                .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        }
    }

    private var islandSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)) }

    func testOnlyTheMirrorAndTheMessageFieldClaimThePointerInTheIslandsPane() throws {
        let image = try AttachmentsTests.writeImage()
        for state in PaneState.allCases {
            let model = AppModel(receivesSignals: false)
            let screen: [String]
            switch state {
            case .question: screen = permission
            case .coveringQuestion: screen = manyOptions
            case .usageCard: screen = ClaudePanelFixtures.usage.components(separatedBy: "\n")
            case .closed, .levelsOpen, .attachments, .keys: screen = conversationScreen
            }
            let session = claudeSession(model, screen: screen)
            XCTAssertTrue(session.mirrorsAgent, state.rawValue)
            if state == .question || state == .coveringQuestion { XCTAssertNotNil(session.prompt, state.rawValue) }
            if state == .usageCard { XCTAssertNotNil(session.panel, state.rawValue) }
            let island = PaneIsland(model: model, session: session, keysOpen: state == .keys, attachments: state == .attachments ? [image] : nil, effortOpen: state == .levelsOpen)
            let (window, host) = mount(island, size: islandSize)
            let claims = appliedClaims(under: host)
            let ibeams = claims.filter { $0.cursor == NSCursor.iBeam }
            let owners = ibeams.map { String(describing: type(of: $0.owner)) }

            XCTAssertTrue(session.terminal.isHiddenOrHasHiddenAncestor, "\(state): the terminal under the mirror is hidden.")
            XCTAssertFalse(claims.contains { $0.owner === session.terminal }, "\(state): the hidden terminal claims the pointer. \(owners)")
            // The I-beam is claimed by the two text fields' clip views (the mirror's and the message field's), which are the text, and by
            // nothing else. (An overlay scroller shows its own arrow while it is out; that is harmless and comes and goes.)
            for claim in ibeams {
                let scroll = (claim.owner as? NSClipView)?.enclosingScrollView
                XCTAssertTrue(scroll is LiveTerminalScrollView || scroll is ComposerScrollView, "\(state): a \(type(of: claim.owner)) that is no text field claims the I-beam.")
            }
            // The mirror and the field, so the check is looking at something. A question's card stands where the field would. A card that has
            // taken the pane (Claude's panel, or a question with many options) has hidden the text under it, which then claims nothing.
            let expected = state == .question ? 1 : (state == .usageCard || state == .coveringQuestion ? 0 : 2)
            XCTAssertEqual(ibeams.count, expected, "\(state): \(owners)")
            // The text under a card gives up the pointer but is not hidden: the keyboard may be in it (Esc must still reach the island).
            let mirror = try XCTUnwrap(descendants(of: host, as: LiveTerminalScrollView.self).first, state.rawValue)
            XCTAssertEqual(mirror.textView.claimsPointer, expected != 0, "\(state): the mirror gives up the pointer exactly when a card has covered it.")
            XCTAssertFalse(mirror.isHidden, state.rawValue)
            if let field = descendants(of: host, as: ComposerFieldView.self).first {
                XCTAssertEqual(field.textView.claimsPointer, state != .usageCard, "\(state): the field gives it up only under Claude's panel.")
                XCTAssertFalse(field.isHidden, state.rawValue)
            }

            // And none of what is claimed reaches the controls row, which is under the field.
            if expected == 2 {
                let field = try XCTUnwrap(descendants(of: host, as: ComposerFieldView.self).first, state.rawValue)
                let fieldBottom = field.convert(field.bounds, to: nil).minY
                for claim in claims { XCTAssertGreaterThanOrEqual(try XCTUnwrap(claim.applied).minY, fieldBottom - 0.5, "\(state): a claim reaches the controls row.") }
            }
            _ = window
        }
    }

    // MARK: Under a card

    func testTheTextUnderClaudesPanelGivesUpThePointerOnlyOnceTheFadeEndsAndTakesItBackAsSoonAsTheCardGoes() throws {
        let holdBefore = ClaudePanelHold.delay
        ClaudePanelHold.delay = 0.05
        defer { ClaudePanelHold.delay = holdBefore }
        let model = AppModel(receivesSignals: false)
        let session = claudeSession(model, screen: conversationScreen)
        XCTAssertNil(session.panel)
        let (window, host) = mount(PaneIsland(model: model, session: session), size: islandSize)
        let mirror = try XCTUnwrap(descendants(of: host, as: LiveTerminalScrollView.self).first)
        let field = try XCTUnwrap(descendants(of: host, as: ComposerFieldView.self).first)
        func iBeams() -> Int { appliedClaims(under: host).filter { $0.cursor == NSCursor.iBeam }.count }
        XCTAssertTrue(mirror.textView.claimsPointer); XCTAssertTrue(field.textView.claimsPointer)
        XCTAssertEqual(iBeams(), 2)

        // Claude's panel opens: its card fades in over the conversation for 0.18 s. Taking the I-beam away at once would not show, but the
        // fade is the card's to run, and the text is still on show while it does.
        session.applyPane(tty: Self.tty, processes: ["claude"], text: ClaudePanelFixtures.usage)
        XCTAssertNotNil(session.panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(mirror.textView.claimsPointer, "Mid-fade the text is still there, and still the text's.")
        XCTAssertTrue(field.textView.claimsPointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(mirror.textView.claimsPointer, "Once the fade is over it gives the pointer up.")
        XCTAssertFalse(field.textView.claimsPointer)
        XCTAssertEqual(iBeams(), 0, "No I-beam over the card.")
        XCTAssertFalse(mirror.isHidden); XCTAssertFalse(field.isHidden)

        // The screen stops showing the panel: after its short hold the card goes, and the text has the pointer back as the fade in begins.
        session.applyPane(tty: Self.tty, processes: ["claude"], text: conversationScreen.joined(separator: "\n"))
        XCTAssertNil(session.panel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        XCTAssertTrue(mirror.textView.claimsPointer, "Back while the card is still fading out, not after it.")
        XCTAssertTrue(field.textView.claimsPointer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(iBeams(), 2, "And so are its I-beams.")
        // The pane gives the keyboard back to the field as the panel goes.
        XCTAssertTrue(window.firstResponder === field.textView, "The keyboard is in the field again: \(String(describing: window.firstResponder)).")
        _ = window
    }

    /// What a text view answers when the pointer enters it, which cursor rects alone do not tell (`NSTextView` tracks the pointer itself).
    private func cursorAnswered(by textView: NSTextView, in window: NSWindow) -> NSCursor {
        NSCursor.crosshair.set()
        let event = NSEvent.enterExitEvent(with: .cursorUpdate, location: NSPoint(x: 8, y: 8), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        textView.cursorUpdate(with: event)
        return NSCursor.current
    }

    func testATextViewThatGivesUpThePointerAnswersTheArrowNotTheIBeam() {
        let mirror = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        mirror.setText("hola\nmás texto")
        let field = ComposerFieldView(frame: NSRect(x: 0, y: 110, width: 300, height: 40))
        field.textView.string = "borrador"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        content.addSubview(mirror); content.addSubview(field)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()

        for (name, scroll, text) in [("mirror", mirror as NSScrollView, mirror.textView as NSTextView), ("field", field.scroll as NSScrollView, field.textView as NSTextView)] {
            XCTAssertEqual(cursorAnswered(by: text, in: window), NSCursor.iBeam, "\(name): the text's own cursor, as ever.")
            XCTAssertEqual(appliedClaims(under: scroll).filter { $0.cursor == NSCursor.iBeam }.count, 1, "\(name): and the clip view's claim of it.")
            scroll.setClaimsPointer(false)
            XCTAssertEqual(cursorAnswered(by: text, in: window), NSCursor.arrow, "\(name): it answers the arrow while a card covers it.")
            XCTAssertTrue(appliedClaims(under: scroll).filter { $0.cursor == NSCursor.iBeam }.isEmpty, "\(name): and nothing claims the I-beam.")
            XCTAssertFalse(scroll.isHidden)
            scroll.setClaimsPointer(true)
            XCTAssertEqual(cursorAnswered(by: text, in: window), NSCursor.iBeam, "\(name): back as it was.")
            XCTAssertEqual(appliedClaims(under: scroll).filter { $0.cursor == NSCursor.iBeam }.count, 1)
        }
    }

    private final class Cover: ObservableObject { @Published var covers = false }

    /// The pane's own arrangement, small: the conversation (mirror and field) faded out under a card, with the fade animated or not.
    private struct CoverHarness: View {
        @ObservedObject var cover: Cover
        var animated: Bool
        var body: some View {
            ZStack {
                VStack(spacing: 0) {
                    LiveTerminalSurface(text: "hola")
                    ComposerField(text: .constant(""), placeholder: "", fontSize: 13, maxLines: 3, focusRequest: 0, onKey: { _, _ in false }).frame(height: 30)
                }.opacity(cover.covers ? 0 : 1).underCover(cover.covers)
                if cover.covers { Color.black.transition(.opacity) }
            }.animation(animated ? .easeOut(duration: 0.18) : nil, value: cover.covers).frame(width: 300, height: 200)
        }
    }

    /// Covers and uncovers the harness and says whether the mirror had given up the pointer 0.05 s into the cover, 0.5 s into it, and had it
    /// back 0.04 s into the uncovering.
    private func playCover(animated: Bool) throws -> (during: Bool, after: Bool, back: Bool) {
        let cover = Cover()
        let (window, host) = mount(CoverHarness(cover: cover, animated: animated), size: NSSize(width: 300, height: 200))
        let mirror = try XCTUnwrap(descendants(of: host, as: LiveTerminalScrollView.self).first)
        XCTAssertTrue(mirror.textView.claimsPointer)
        cover.covers = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let during = !mirror.textView.claimsPointer
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = !mirror.textView.claimsPointer
        cover.covers = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        let back = mirror.textView.claimsPointer
        withExtendedLifetime(window) {}
        return (during, after, back)
    }

    func testWithAFadeTheTextGivesUpThePointerAfterItAndWithoutOneAtOnce() throws {
        let faded = try playCover(animated: true)
        XCTAssertFalse(faded.during, "Mid-fade the text still has it.")
        XCTAssertTrue(faded.after)
        XCTAssertTrue(faded.back)
        let instant = try playCover(animated: false)
        XCTAssertTrue(instant.during, "With Reduce Motion there is no fade to wait for.")
        XCTAssertTrue(instant.after)
        XCTAssertTrue(instant.back)
    }

    // MARK: Chrome over the text

    /// The text of the two text views' scroll views, and where chrome floats over it, in a small window of their own.
    private func scrollViewsWithAMarker(marker: NSRect) -> (window: NSWindow, content: NSView, mirror: LiveTerminalScrollView, field: ComposerFieldView, hole: PointerHoleView) {
        let mirror = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        mirror.setText("hola\nmás texto")
        let field = ComposerFieldView(frame: NSRect(x: 0, y: 110, width: 300, height: 40))
        field.textView.string = "borrador"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        content.addSubview(mirror); content.addSubview(field)
        let hole = PointerHoleView(frame: marker)
        content.addSubview(hole)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return (window, content, mirror, field, hole)
    }

    func testCarvingLeavesExactlyWhatTheHolesDoNotCover() {
        // A small grid of whole numbers, so that every cell is either in a piece or not, with no rounding to argue over.
        var seed: UInt64 = 20261004
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        for round in 0..<200 {
            let area = NSRect(x: 0, y: 0, width: 40, height: 30)
            let holes = (0..<(round % 5)).map { _ in NSRect(x: next(50) - 5, y: next(40) - 5, width: 1 + next(25), height: 1 + next(20)) }
            let pieces = PointerHoles.carve(area, around: holes)
            var wrong: [String] = []
            for x in 0..<40 {
                for y in 0..<30 {
                    let cell = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    let wanted = !holes.contains { $0.contains(cell) }
                    if pieces.filter({ $0.contains(cell) }).count != (wanted ? 1 : 0) { wrong.append("\(x),\(y)") }
                }
            }
            XCTAssertTrue(wrong.isEmpty, "Round \(round): a cell is in exactly one piece when no hole covers it, in none when one does. Wrong: \(wrong.prefix(5)).")
            XCTAssertTrue(pieces.allSatisfy { area.contains($0) && !$0.isEmpty }, "Round \(round): inside the area.")
        }
        XCTAssertEqual(PointerHoles.carve(NSRect(x: 0, y: 0, width: 10, height: 10), around: []), [NSRect(x: 0, y: 0, width: 10, height: 10)])
        XCTAssertTrue(PointerHoles.carve(NSRect(x: 0, y: 0, width: 10, height: 10), around: [NSRect(x: -5, y: -5, width: 30, height: 30)]).isEmpty, "Covered whole.")
    }

    func testAMarkerStandsWhereSwiftUIDrawsItsViewOffsetIncluded() {
        struct Chrome: View {
            var body: some View {
                ZStack(alignment: .bottomLeading) {
                    Color.clear.frame(width: 300, height: 200)
                    Rectangle().frame(width: 100, height: 40).pointerHole().offset(x: 30, y: -20)
                }.frame(width: 300, height: 200)
            }
        }
        let (window, _) = mount(Chrome(), size: NSSize(width: 300, height: 200))
        // Bottom-left of the area, then 30 right and 20 up: x 30-130, and from the bottom 20-60 (140-180 from the top).
        let frames = PointerHoles.frames(in: window)
        XCTAssertEqual(frames.count, 1)
        let frame = frames.first ?? .zero
        XCTAssertEqual(frame.minX, 30, accuracy: 0.5); XCTAssertEqual(frame.minY, 20, accuracy: 0.5)
        XCTAssertEqual(frame.width, 100, accuracy: 0.5); XCTAssertEqual(frame.height, 40, accuracy: 0.5)
    }

    func testTheTextClaimsTheIBeamAroundAMarkerAndAnswersTheArrowInsideIt() throws {
        // In window coordinates (y up): the mirror is y 0-100 of the content, the field y 110-150, and the marker stands over the mirror.
        let (window, content, mirror, field, hole) = scrollViewsWithAMarker(marker: NSRect(x: 100, y: 40, width: 80, height: 30))
        _ = content
        let holeFrame = hole.convert(hole.bounds, to: nil)
        let mirrorFrame = mirror.convert(mirror.bounds, to: nil)
        XCTAssertTrue(mirrorFrame.contains(holeFrame), "The marker stands over the mirror.")

        // The claim: the mirror's whole text area but for the hole.
        let ibeams = appliedClaims(under: mirror).filter { $0.cursor == NSCursor.iBeam }.compactMap(\.applied)
        XCTAssertFalse(ibeams.contains { $0.intersects(holeFrame) }, "Nothing claims the I-beam where the chrome stands.")
        for x in stride(from: mirrorFrame.minX + 3, to: mirrorFrame.maxX - 3, by: 7) {
            for y in stride(from: mirrorFrame.minY + 3, to: mirrorFrame.maxY - 3, by: 7) {
                let point = NSPoint(x: x, y: y)
                if holeFrame.insetBy(dx: -2, dy: -2).contains(point) && !holeFrame.insetBy(dx: 2, dy: 2).contains(point) { continue }
                XCTAssertEqual(ibeams.contains { $0.contains(point) }, !holeFrame.contains(point), "\(point): the text around the hole keeps its I-beam.")
            }
        }
        // What the text view answers when the pointer enters or moves: the arrow over the chrome, the text's own cursor beside it.
        func answered(_ send: (NSEvent) -> Void, at point: NSPoint) -> NSCursor {
            NSCursor.crosshair.set()
            send(NSEvent.enterExitEvent(with: .cursorUpdate, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
            return NSCursor.current
        }
        let inside = NSPoint(x: holeFrame.midX, y: holeFrame.midY), beside = NSPoint(x: holeFrame.maxX + 20, y: holeFrame.midY)
        XCTAssertEqual(answered({ mirror.textView.cursorUpdate(with: $0) }, at: inside), NSCursor.arrow, "Over the chrome the text view answers the arrow.")
        XCTAssertEqual(answered({ mirror.textView.cursorUpdate(with: $0) }, at: beside), NSCursor.iBeam, "Beside it, its own I-beam.")
        NSCursor.crosshair.set()
        mirror.textView.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: inside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        XCTAssertEqual(NSCursor.current, NSCursor.arrow, "Moving over the chrome keeps the arrow.")

        // The field is not under it, and keeps its whole claim.
        XCTAssertEqual(appliedClaims(under: field).filter { $0.cursor == NSCursor.iBeam }.count, 1)
        XCTAssertFalse(appliedClaims(under: field).filter { $0.cursor == NSCursor.iBeam }.compactMap(\.applied).contains { $0.intersects(holeFrame) })
    }

    func testAMarkerOverTheFieldTakesTheFieldsClaimOutAsWell() {
        let (_, _, _, field, hole) = scrollViewsWithAMarker(marker: NSRect(x: 150, y: 115, width: 60, height: 20))
        let holeFrame = hole.convert(hole.bounds, to: nil)
        let claims = appliedClaims(under: field).filter { $0.cursor == NSCursor.iBeam }.compactMap(\.applied)
        XCTAssertFalse(claims.isEmpty)
        XCTAssertFalse(claims.contains { $0.intersects(holeFrame) }, "A card over the message field leaves it the arrow too.")
    }

    /// Records which views a window was asked to set the cursor rects of again.
    private func invalidations(in window: NSWindow, during body: () -> Void) -> [NSView] {
        final class Box { var views: [NSView] = [] }
        let box = Box()
        let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.invalidateCursorRects(for:)))!
        let record: @convention(block) (NSWindow, NSView) -> Void = { _, view in box.views.append(view) }
        let original = method_setImplementation(method, imp_implementationWithBlock(record))
        defer { method_setImplementation(method, original) }
        body()
        return box.views
    }

    func testAMarkerComingMovingHidingAndGoingMakesTheTextClaimItsPointerAgain() {
        let (window, content, mirror, field, hole) = scrollViewsWithAMarker(marker: NSRect(x: 100, y: 40, width: 80, height: 30))
        let clips = [mirror.contentView, field.scroll.contentView]
        func told(_ views: [NSView]) -> Bool { clips.allSatisfy { clip in views.contains { $0 === clip } } }

        XCTAssertTrue(told(invalidations(in: window) { hole.setFrameOrigin(NSPoint(x: 120, y: 40)) }), "Moved.")
        XCTAssertTrue(told(invalidations(in: window) { hole.setFrameSize(NSSize(width: 90, height: 30)) }), "Resized.")
        XCTAssertTrue(told(invalidations(in: window) { hole.isHidden = true }), "Hidden.")
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty, "A hidden marker stands nowhere.")
        XCTAssertTrue(told(invalidations(in: window) { hole.isHidden = false }), "Shown again.")
        XCTAssertEqual(PointerHoles.frames(in: window).count, 1)
        XCTAssertTrue(told(invalidations(in: window) { hole.removeFromSuperview() }), "Gone.")
        XCTAssertTrue(PointerHoles.frames(in: window).isEmpty)
        XCTAssertTrue(told(invalidations(in: window) { content.addSubview(hole) }), "Back.")
    }

    // MARK: What a click would reach

    /// The invariant the holes serve, asked of AppKit's own hit test, so it holds for chrome whether or not anyone marked it: over a text view the
    /// I-beam is claimed exactly where a click would reach that text view, and nowhere chrome stands over it. Says how many of the sampled points
    /// were the text's and how many something else's.
    private func iBeamFollowsClicks<V: NSView>(over viewType: V.Type, in host: NSView, window: NSWindow, label: String) throws -> (text: Int, chrome: Int) {
        let view = try XCTUnwrap(descendants(of: host, as: viewType).first, label)
        let frame = view.convert(view.bounds, to: nil)
        let ibeams = appliedClaims(under: host).filter { $0.cursor == NSCursor.iBeam && $0.owner.isDescendant(of: view) }.compactMap(\.applied)
        let content = try XCTUnwrap(window.contentView)
        let holes = PointerHoles.frames(in: window)
        var text = 0, chrome = 0
        var wrong: [String] = []
        for x in stride(from: frame.minX + 4, to: frame.maxX - 4, by: 9) {
            for y in stride(from: frame.minY + 4, to: frame.maxY - 4, by: 9) {
                let point = NSPoint(x: x, y: y)
                // The border of a claim is rounding's; the border of a hole is also the rounded corners of the card it marks (a rectangle is as near
                // as a hole gets), which are a few points deep.
                func near(_ rect: NSRect, _ depth: CGFloat) -> Bool { rect.insetBy(dx: -depth, dy: -depth).contains(point) && !rect.insetBy(dx: depth, dy: depth).contains(point) }
                if ibeams.contains(where: { near($0, 2) }) || holes.contains(where: { near($0, 5) }) { continue }
                let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
                let reachesText = hit.map { $0.isDescendant(of: view) } ?? false
                let claimed = ibeams.contains { $0.contains(point) }
                if claimed != reachesText { wrong.append("(\(Int(x)),\(Int(y))) claimed=\(claimed) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")") }
                if reachesText { text += 1 } else { chrome += 1 }
            }
        }
        XCTAssertTrue(wrong.isEmpty, "\(label): the I-beam is claimed where a click would not reach the text, or not where it would. \(wrong.count) of \(text + chrome) points, for instance \(wrong.prefix(4)).")
        return (text, chrome)
    }

    private enum Floating: String, CaseIterable { case nothing, menu, smallMenu, joinedWarning, notice, connectionSheet }

    func testTheTextKeepsItsIBeamExactlyWhereAClickWouldReachItWhateverFloatsOverIt() throws {
        for floating in Floating.allCases {
            let model = AppModel(receivesSignals: false)
            let session = claudeSession(model, screen: conversationScreen)
            switch floating {
            case .nothing: break
            case .menu: session.draft = "/"
            case .smallMenu: session.draft = "/us"
            case .joinedWarning: session.joinedBox = "Tu mensaje quedó en la caja de Claude"
            case .notice: model.notice = "Aviso de prueba que flota sobre el panel de la isla."
            case .connectionSheet: model.connectionSheet = true
            }
            let (window, host) = mount(NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false), size: islandSize)
            let mirror = try iBeamFollowsClicks(over: LiveTerminalScrollView.self, in: host, window: window, label: "\(floating) / mirror")
            let field = try iBeamFollowsClicks(over: ComposerFieldView.self, in: host, window: window, label: "\(floating) / field")
            let label = floating.rawValue
            switch floating {
            case .nothing:
                XCTAssertEqual(mirror.chrome + field.chrome, 0, "\(label): nothing floats, so every point is the text's.")
                XCTAssertGreaterThan(mirror.text, 0); XCTAssertGreaterThan(field.text, 0)
            case .menu:
                XCTAssertGreaterThan(mirror.chrome, 0, "\(label): the menu stands over the mirror.")
            case .smallMenu:
                XCTAssertGreaterThan(mirror.chrome, 0, "\(label): the menu stands over the mirror.")
                XCTAssertGreaterThan(mirror.text, 0, "\(label): and the mirror around it keeps its I-beam.")
            case .joinedWarning:
                XCTAssertGreaterThan(mirror.chrome + field.chrome, 0, "\(label): the card stands over the text.")
                XCTAssertGreaterThan(mirror.text, 0, "\(label): and the text around it keeps its I-beam.")
            case .notice:
                // It hangs from the top of the conversation (not over the composer), so it stands over the mirror and leaves the text around it its I-beam.
                XCTAssertGreaterThan(mirror.chrome, 0, "\(label): the card stands over the mirror.")
                XCTAssertGreaterThan(mirror.text, 0, "\(label): and the text around it keeps its I-beam.")
                XCTAssertEqual(field.chrome, 0, "\(label): it does not reach the composer's field.")
                XCTAssertGreaterThan(field.text, 0)
            case .connectionSheet:
                XCTAssertEqual(mirror.text + field.text, 0, "\(label): the sheet covers the island: nothing under it is the text's.")
                XCTAssertGreaterThan(mirror.chrome, 0)
            }
        }
    }

    private static func agent(_ id: String, _ name: String, _ state: SubagentActivity.State) -> SubagentActivity { SubagentActivity(id: id, name: name, state: state) }

    func testTheAgentsListAndTheRecapCardOverTheMirrorHaveTheArrowAndTheTextAroundThemTheIBeam() throws {
        // As the island lays them out: the recap button in the tab row above the text, its card hanging over it; the agents' capsule in the composer's
        // row below, its list opening upward over it.
        struct Lists: View {
            var showsList: Bool
            var body: some View {
                VStack(spacing: 0) {
                    HStack { Spacer(); if !showsList { SessionRecapButton(sessionID: "s", recap: "Resumen: se corrigió el cursor y se probó con renders y con la suite completa.",
                                                                          store: RecapSeenStore(defaults: nil), initiallyOpen: true, keepsOpen: true) } }
                        .padding(.horizontal, 8).frame(height: 30).zIndex(1)
                    LiveTerminalSurface(text: String(repeating: "una línea de texto del espejo, bastante larga para llenar el ancho\n", count: 14))
                    HStack { Spacer(); if showsList { SubagentCapsule(agents: [CursorTests.agent("a", "Diseñar las animaciones del gato", .running), CursorTests.agent("b", "Revisar el notch", .done)],
                                                                     alwaysVisible: true, initiallyOpen: true) } }
                        .padding(.horizontal, 8).frame(height: 30)
                }.frame(width: 560, height: 260)
            }
        }
        for (name, showsList) in [("agents' list", true), ("recap card", false)] {
            let (window, host) = mount(Lists(showsList: showsList), size: NSSize(width: 560, height: 260))
            XCTAssertFalse(PointerHoles.frames(in: window).isEmpty, "\(name): it marked itself.")
            let mirror = try iBeamFollowsClicks(over: LiveTerminalScrollView.self, in: host, window: window, label: name)
            XCTAssertGreaterThan(mirror.chrome, 0, "\(name): it stands over the mirror.")
            XCTAssertGreaterThan(mirror.text, 0, "\(name): and the text around it keeps its I-beam.")
        }
    }

    func testTheMirrorTextBesideTheMenuStaysSelectableWithTheMouse() throws {
        try requireKeyCapableSession()
        // As the island's own window gets mouse events: a panel that can be key, away from the screen. The same drag without a menu is the control.
        for draft in ["", "/us"] {
            let model = AppModel(receivesSignals: false)
            let session = claudeSession(model, screen: conversationScreen)
            session.draft = draft
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
            host.frame = NSRect(origin: .zero, size: islandSize)
            let window = NotchPanel(contentRect: NSRect(x: -30000, y: -30000, width: islandSize.width, height: islandSize.height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            settle(host)
            let text = try XCTUnwrap(descendants(of: host, as: LiveTerminalScrollView.self).first).textView
            XCTAssertEqual(!PointerHoles.frames(in: window).isEmpty, !draft.isEmpty, "The menu is open over the mirror exactly when something was typed.")
            XCTAssertTrue(text.isSelectable)

            // A drag along the first line of the conversation, which is above the menu.
            let layout = try XCTUnwrap(text.layoutManager), container = try XCTUnwrap(text.textContainer)
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: min(10, (text.string as NSString).length)), actualCharacterRange: nil)
            var line = layout.boundingRect(forGlyphRange: glyphs, in: container)
            line.origin.x += text.textContainerOrigin.x; line.origin.y += text.textContainerOrigin.y
            let start = text.convert(NSPoint(x: line.minX + 1, y: line.midY), to: nil), end = text.convert(NSPoint(x: line.maxX - 1, y: line.midY), to: nil)
            XCTAssertFalse(PointerHoles.contains(start, in: window) || PointerHoles.contains(end, in: window), "The first line is not under the menu.")
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            // The text view tracks the drag until the button goes up, so the rest of the gesture is queued before it begins.
            NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
            window.sendEvent(mouse(.leftMouseDown, start))
            XCTAssertGreaterThan(text.selectedRange().length, 0, "Draft \(draft.debugDescription): dragging over the text selects it.")
        }
    }
}
