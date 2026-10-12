import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the composer answering a dialog's text field ("Type something.") to PNG for visual review: the question's card with that option, the composer after
/// the click (empty, with an answer written, with it on its way, hinting that nothing is written), a question that takes several answers, a long question, the
/// field the terminal already has highlighted with the card folded away, other widths, text sizes and tab colours. Runs only when NOOK_RENDER_DIR is set. The
/// dialogs are fixtures in the shapes Claude Code draws, read the way the app reads them; nothing here reaches Terminal, a real session or the keyboard.
@MainActor
final class FieldAnswerRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            host.layoutSubtreeIfNeeded()
        }
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            clearScrollBackgrounds(host)
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// An offscreen render paints a scroll view white where the app has the island's black behind it.
    private func clearScrollBackgrounds(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false; scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    private func makeModel() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-field-answer-render-" + UUID().uuidString)!) }

    private func session(_ model: AppModel, rows: [String], tint: TabTint? = nil) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: rows.joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        if let tint { session.tint = tint }
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// The pane inside a 266 pt island with a 32 pt notch inset, as the app lays it out.
    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var draft: String?
        var promptState: SessionPane.PromptCardState = .typing
        var sentAnswer: String?
        var nudged = false
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, draft: draft, promptState: promptState, sentAnswer: sentAnswer, answerNudged: nudged).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    // MARK: Fixtures

    private let rule = String(repeating: "─", count: 72)

    /// One question with one answer, its highlight on the first option.
    private let question = ["⏺ Antes de seguir necesito una decisión tuya.", "", "☐ Database", "", "Which database should we use for the new service?", "",
                            "❯ 1. PostgreSQL", "     Relational, strong consistency and a great ecosystem", "  2. SQLite", "     Embedded, zero configuration, single file",
                            "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same question with the highlight already on the field (the user moved there at the terminal).
    private var onTheField: [String] {
        question.map { $0 == "❯ 1. PostgreSQL" ? "  1. PostgreSQL" : $0 == "  3. Type something." ? "❯ 3. Type something." : $0 }
    }
    /// A question that takes several answers: the field sits behind its own box.
    private let platforms = ["⏺ Antes de lanzar necesito saber para qué plataformas.", "", "☐ Platforms", "", "Which platforms should the release support?", "",
                             "❯ 1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "  3. [ ] Linux", "  4. [ ] Type something", "",
                             "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same question once Nook wrote the user's text into its field: the dialog stays, the field shows the text with its box ticked and the highlight (the text
    /// still reads as a free-text option to the parser: it opens like one).
    private let platformsFilled = ["⏺ Antes de lanzar necesito saber para qué plataformas.", "", "☐ Platforms", "", "Which platforms should the release support?", "",
                                   "  1. [ ] macOS", "       Apple Silicon and Intel", "  2. [✔] iOS", "  3. [ ] Linux", "❯ 4. [✔] Otro proveedor", "",
                                   "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same, with the highlight moved to the first option and the filled field's box cleared by a click (its text stays).
    private var platformsFilledElsewhere: [String] {
        platformsFilled.map { $0 == "  1. [ ] macOS" ? "❯ 1. [ ] macOS" : $0 == "❯ 4. [✔] Otro proveedor" ? "  4. [ ] Otro proveedor" : $0 }
    }
    /// A long question with no label, as a plan's would be.
    private let longQuestion = ["⏺ Revisé el plan de migración.", "",
                                "We are about to move the CRM from a single SQLite file to a hosted database, and the migration will touch contacts, deals and the activity timeline. Which database should we use for the new service, considering that the team already runs Postgres for billing?", "",
                                "❯ 1. PostgreSQL", "  2. MySQL", "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// Two questions at once: the one on show is the first.
    private let tabbed = ["⏺ Tengo dos preguntas antes de empezar.", "", "← ☐ Database  ☐ Cache  ✔ Submit →", "", "Which database should we use for the new service?", "",
                          "❯ 1. PostgreSQL", "  2. SQLite", "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel"]

    private func prompt(_ rows: [String], file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        try XCTUnwrap(AgentPrompt.parse(rows.joined(separator: "\n")), "The fixture is not a dialog", file: file, line: line)
    }

    /// Renders `rows` with the field chosen on the card (what a click on it leaves), or with the card folded away, at each of `widths`.
    private func render(_ name: String, _ rows: [String], chosen: Bool = true, filled: Bool = false, state: SessionPane.PromptCardState = .typing, draft: String? = nil,
                        sentAnswer: String? = nil, nudged: Bool = false, tint: TabTint? = nil, widths: [CGFloat] = [NotchGeometry.expandedWidth], extraHeight: CGFloat = 0,
                        chatSize: Double? = nil, multi: Bool = false, in directory: String) throws {
        let model = makeModel()
        if let chatSize { model.display.chatSize = chatSize }
        let session = session(model, rows: rows, tint: tint)
        let dialog = try XCTUnwrap(session.prompt, name)
        XCTAssertEqual(dialog.multiSelect, multi, name)
        let field = try XCTUnwrap(dialog.options.firstIndex { $0.input == .inline }, name)
        if chosen { session.chooseField(field, of: dialog) }
        // Nook wrote the user's text into this field and the dialog stayed (a question with several answers): it is no target for more text.
        if filled { session.noteFilledField(field, of: dialog); XCTAssertTrue(session.isFilledField(field, of: dialog), name) }
        // The composer must be answering: the state under test is the field's, not a message's (the card's own picture has no field chosen).
        if state != .options { XCTAssertNotNil(model.fieldAnswer(for: session), name) }
        if filled { XCTAssertNil(model.fieldAnswer(for: session), "A filled field is no target: \(name)") }
        for width in widths {
            let height = NotchGeometry.expandedHeight(topInset: 32) + extraHeight
            let suffix = widths.count > 1 || width != NotchGeometry.expandedWidth ? "-\(Int(width))" : ""
            try write(NSHostingView(rootView: Island(model: model, session: session, width: width, height: height, draft: draft, promptState: state, sentAnswer: sentAnswer, nudged: nudged)),
                      size: NSSize(width: width, height: height), to: url(directory, "answer-\(name)\(extraHeight > 0 ? "-tall" : "")\(suffix).png"))
        }
    }

    // MARK: The card and the composer after the click

    /// What the user clicks (the card with the field), what he gets (the composer with the question over it), with an answer written, and with it on its way.
    func testRenderTheFieldFromTheCardToTheSentAnswer() throws {
        let directory = try renderDirectory()
        // The card as it stands, with the field as one of its options: the click is on that row.
        let model = makeModel()
        let card = session(model, rows: question)
        XCTAssertNil(card.chosenField)
        try write(NSHostingView(rootView: Island(model: model, session: card, promptState: .options)), size: NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)),
                  to: url(directory, "answer-0-card.png"))
        try render("1-empty", question, in: directory)
        try render("2-typed", question, draft: "Usa MongoDB con réplica de lectura", in: directory)
        try render("3-sending", question, sentAnswer: "Usa MongoDB con réplica de lectura", in: directory)
        try render("4-missing", question, nudged: true, in: directory)
    }

    func testRenderAQuestionThatTakesSeveralAnswers() throws {
        let directory = try renderDirectory()
        try render("multi-empty", platforms, multi: true, in: directory)
        try render("multi-typed", platforms, draft: "Linux en ARM", multi: true, in: directory)
    }

    /// The card of a question with several answers once a field holds the user's text: its row says whose text it is (no pencil, «Tu respuesta») and a click toggles
    /// the box, like on the other options. Ticked and highlighted, and unticked with the highlight elsewhere; narrow, and at the largest text.
    func testRenderTheCardWithAFieldThatAlreadyHoldsTheAnswer() throws {
        let directory = try renderDirectory()
        try render("filled-card", platformsFilled, chosen: false, filled: true, state: .options, multi: true, in: directory)
        try render("filled-card-unticked", platformsFilledElsewhere, chosen: false, filled: true, state: .options, extraHeight: 70, multi: true, in: directory)
        try render("filled-card", platformsFilled, chosen: false, filled: true, state: .options, widths: [440], extraHeight: 0, multi: true, in: directory)
        try render("filled-card-big", platformsFilled, chosen: false, filled: true, state: .options, chatSize: DisplaySettings.chatSizeRange.upperBound, multi: true, in: directory)
        // For comparison: the same dialog before the field was written into, as the card shows it.
        try render("filled-card-before", platforms, chosen: false, state: .options, multi: true, in: directory)
    }

    func testRenderALongQuestionAndALongAnswer() throws {
        let directory = try renderDirectory()
        try render("long", longQuestion, draft: "Prefiero PostgreSQL gestionado con una réplica de lectura en otra zona, siempre que el costo no pase de 50 dólares al mes y el equipo pueda operarlo sin ayuda.", in: directory)
        try render("long", longQuestion, draft: "Prefiero PostgreSQL gestionado con una réplica de lectura en otra zona, siempre que el costo no pase de 50 dólares al mes.", extraHeight: 90, in: directory)
        try render("tabs", tabbed, draft: "Una base propia", in: directory)
    }

    /// The field the terminal already has highlighted, with the card folded away with its chevron: nothing was clicked.
    func testRenderTheFieldTheTerminalAlreadyHas() throws {
        let directory = try renderDirectory()
        try render("highlighted", onTheField, chosen: false, state: .hidden, in: directory)
        try render("highlighted-typed", onTheField, chosen: false, state: .hidden, draft: "Usa MongoDB", in: directory)
    }

    func testRenderOtherWidthsTextSizesAndTabColours() throws {
        let directory = try renderDirectory()
        try render("narrow", question, draft: "Usa MongoDB con réplica", widths: [NotchGeometry.expandedWidth, 440, 360], in: directory)
        try render("big", question, draft: "Usa MongoDB con réplica", chatSize: DisplaySettings.chatSizeRange.upperBound, in: directory)
        try render("small", question, draft: "Usa MongoDB con réplica", chatSize: DisplaySettings.chatSizeRange.lowerBound, in: directory)
        for tint in [TabTint.blue, .rose, .sand] {
            try render("tint-\(tint)", question, draft: "Usa MongoDB con réplica", tint: tint, in: directory)
        }
    }

    /// The smallest island (440 × 202): the bar and the conversation share a pane of 140 pt.
    func testRenderTheSmallestIsland() throws {
        let directory = try renderDirectory()
        let drop = NotchGeometry.minExpandedHeight(topInset: 32) - NotchGeometry.expandedHeight(topInset: 32)
        try render("smallest", question, draft: "Usa MongoDB con réplica", widths: [NotchGeometry.minExpandedWidth], extraHeight: drop, in: directory)
        try render("smallest-long", longQuestion, draft: "Prefiero PostgreSQL gestionado con una réplica de lectura en otra zona, siempre que el costo no pase de 50 dólares al mes.",
                   widths: [NotchGeometry.minExpandedWidth], extraHeight: drop, in: directory)
        try render("smallest-card", question, chosen: false, state: .options, widths: [NotchGeometry.minExpandedWidth], extraHeight: drop, in: directory)
    }

    /// The whole panel in the system's light and dark appearance, with the state reached the way a user reaches it: a click on the card's «Type something.» row. The
    /// island is black in both. (Offscreen and never key: the click goes to the window by hand, and nothing can answer a question in a real terminal.)
    func testRenderTheWholePanelInLightAndDarkAfterTheClick() throws {
        let directory = try renderDirectory()
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
            let model = makeModel()
            let session = session(model, rows: question)
            // Nothing reaches the real Terminal from a click: its transports are stubs.
            model.terminalBridge.runScript = { _ in }
            model.terminalBridge.postKey = { _, _ in }
            model.terminalBridge.reader = { _ in [] }
            let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
            let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
            XCTAssertNil(session.chosenField)
            // The third option's row, 58 pt under the panel's top (the neck and the tab row) and 157 pt into the pane.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: size.height - (58 + 157)), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            XCTAssertEqual(session.chosenField?.option, 2, "The click chose the field")
            session.draft = "Usa MongoDB con réplica"
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                clearScrollBackgrounds(host)
                host.cacheDisplay(in: host.bounds, to: rep)
                if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
                rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            }
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: url(directory, "answer-panel-\(name).png")))
            window.orderOut(nil)
        }
    }
}
