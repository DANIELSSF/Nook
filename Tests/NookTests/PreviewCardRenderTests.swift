import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the card of Claude's question whose options carry a preview (Sample's dialog of 2026-10-09 and its variants) to PNG for visual review: at the sizes of the island
/// (the smallest, Compact, Normal, Wide, Tall), with the highlight on each option, the fold of a mock Claude cut, notes written, notes the terminal holds or has open, a single
/// question, the step that reviews the answers, a long mock and a wide one, an option without a preview, other text sizes and tab colours. Runs only when NOOK_RENDER_DIR is
/// set. The screens are `PreviewQuestionFixtures`, read the way the app reads them; nothing here reaches Terminal, a real session or the keyboard.
@MainActor
final class PreviewCardRenderTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures

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

    private func makeModel() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-preview-render-" + UUID().uuidString)!) }

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

    /// The pane inside an island with a 32 pt notch inset, as the app lays it out.
    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var notes: String?
        var state: SessionPane.PromptCardState = .options
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, promptState: state, promptNotes: notes).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark)
                .environment(\.nookDarkBackdrop, true)
                .environment(\.nookTintedGlass, false)
        }
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// The sizes the island has: the smallest, Compact, Normal, Wide and Tall (width, height with the notch's 32 pt inset).
    private let smallest = CGSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.minExpandedHeight(topInset: 32))
    private let compact = CGSize(width: NotchGeometry.expandedWidth + IslandPreset.compact.widthExtra, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.compact.heightExtra)
    private let normal = CGSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
    private let wide = CGSize(width: NotchGeometry.expandedWidth + IslandPreset.wide.widthExtra, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.wide.heightExtra)
    private let tall = CGSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.tall.heightExtra)
    /// The narrowest island as tall as the Tall preset: the stacked arrangement with the whole card in view.
    private let narrowTall = CGSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.tall.heightExtra)

    private func render(_ name: String, _ rows: [String], at size: CGSize, notes: String? = nil, state: SessionPane.PromptCardState = .options, tint: TabTint? = nil, chatSize: Double? = nil,
                        in directory: String) throws {
        let model = makeModel()
        if let chatSize { model.display.chatSize = chatSize }
        let session = session(model, rows: rows, tint: tint)
        let prompt = try XCTUnwrap(session.prompt, name)
        XCTAssertTrue(prompt.takesNotes || name.contains("review") || name.contains("nexttab"), name)
        try write(NSHostingView(rootView: Island(model: model, session: session, width: size.width, height: size.height, notes: notes, state: state)), size: NSSize(width: size.width, height: size.height),
                  to: url(directory, "preview-\(name)-\(Int(size.width))x\(Int(size.height)).png"))
    }

    // MARK: Sample's dialog

    /// The dialog he sent, at the Normal island and the smallest, with the first option highlighted and a mock Claude folds (5 lines hidden).
    func testRenderSamplesDialogAtTheNormalAndTheSmallestIsland() throws {
        let directory = try renderDirectory()
        try render("sample", F.sample(), at: normal, in: directory)
        try render("sample", F.sample(), at: smallest, in: directory)
        try render("sample", F.sample(), at: compact, in: directory)
        try render("sample", F.sample(), at: wide, in: directory)
        try render("sample", F.sample(), at: tall, in: directory)
        try render("sample", F.sample(), at: narrowTall, in: directory)
        try render("notes-typed", F.sample(), at: narrowTall, notes: "el logo a la izquierda y el nombre de la empresa en dos líneas", in: directory)
    }

    /// The highlight on the second option (its own, shorter mock, no fold) and on «Chat about this» (the box keeps the second option's).
    func testRenderTheHighlightOnTheOtherOptions() throws {
        let directory = try renderDirectory()
        try render("highlight2", F.sample(highlight: 2), at: normal, in: directory)
        try render("highlight2", F.sample(highlight: 2), at: smallest, in: directory)
        try render("chat", F.sample(highlight: 3), at: normal, in: directory)
        try render("chat", F.sample(highlight: 3), at: tall, in: directory)
    }

    /// The dialog on a tab the user came back to: the option already answered carries Claude's «✔», which the row says («Actual») and which narrows the title's room.
    func testRenderTheOptionAlreadyAnswered() throws {
        let directory = try renderDirectory()
        try render("answered", F.sample(highlight: 1, ticked: 2), at: normal, in: directory)
        try render("answered", F.sample(highlight: 1, ticked: 2), at: tall, in: directory)
    }

    // MARK: Notes

    /// Notes written in Nook's field (`typed`), notes the terminal holds with its field closed (`held`), its field open and empty (`open`), and its field with text being
    /// typed in it (`typing`, told from held notes by the key hint naming the editor). In the last two the options are dimmed and the notice says to close the field.
    func testRenderNotesTypedHeldOpenAndTypingInTheTerminal() throws {
        let directory = try renderDirectory()
        let written = "el logo a la izquierda y el nombre de la empresa en dos líneas"
        try render("notes-typed", F.sample(), at: normal, notes: written, in: directory)
        try render("notes-typed", F.sample(), at: smallest, notes: written, in: directory)
        try render("notes-typed", F.sample(), at: tall, notes: written, in: directory)
        try render("notes-held", F.sample(notes: "el logo a la izquierda"), at: normal, in: directory)
        try render("notes-held", F.sample(notes: "el logo a la izquierda"), at: tall, in: directory)
        try render("notes-open", F.sample(notes: "Add notes on this design…"), at: normal, in: directory)
        try render("notes-open", F.sample(notes: "Add notes on this design…"), at: tall, in: directory)
        // Text typed into the terminal's field: the notice quotes it (three lines at most).
        let typing = "el logo a la izquierda y el nombre de la empresa en dos líneas"
        try render("notes-typing", F.sample(notes: typing, focused: true), at: normal, in: directory)
        try render("notes-typing", F.sample(notes: typing, focused: true), at: tall, in: directory)
        try render("notes-typing", F.sample(notes: typing, focused: true), at: narrowTall, in: directory)
        try render("notes-typing-long", F.sample(notes: String(repeating: "una nota muy larga que no cabe en tres líneas del aviso ", count: 4), focused: true), at: tall, in: directory)
        try render("single-typing", F.single(notes: typing, focused: true), at: tall, in: directory)
    }

    /// The card folded away with its chevron: the composer has its place, and says the question waits (and how to get the options back).
    func testRenderTheCardFoldedAway() throws {
        let directory = try renderDirectory()
        try render("hidden", F.sample(), at: normal, state: .hidden, in: directory)
    }

    // MARK: Other questions

    /// One question alone: its label over the question, no tabs, a shorter box.
    func testRenderASingleQuestion() throws {
        let directory = try renderDirectory()
        try render("single", F.single(), at: normal, in: directory)
        try render("single", F.single(), at: smallest, in: directory)
        try render("single", F.single(highlight: 2), at: tall, in: directory)
    }

    /// The step that reviews the answers after the preview questions, and the next question of the dialog (no previews): the cards they always were.
    func testRenderTheStepsAroundThePreviewQuestion() throws {
        let directory = try renderDirectory()
        let review = F.above + [F.rule(106), "←  ☒ Navbar  ☒ Tarjetas  ✔ Submit  →", "", "Review your answers", "",
                                "│ ● ¿Qué hacemos con el header de la consola en el celular (imagen 2)? Es compartido por toda la consola de",
                                "│   proveedores y por /admin.", "  → Rediseñarlo aquí (Recomendada)", "│ ● ¿Cómo dejamos las tarjetas?", "  → Blancas con borde fino", "",
                                "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        try render("review", review, at: normal, in: directory)
        try render("review", review, at: tall, in: directory)
        try render("nexttab", F.nextTab, at: normal, in: directory)
    }

    // MARK: Mocks of other shapes

    private func question(_ mock: [String], width: Int, hidden: Int = 0, options: [String] = ["❯ 1. Rediseñarlo aquí", "  2. Ticket aparte"]) -> [String] {
        F.above + [F.rule(150), "←  ☐ Navbar  ☐ Tarjetas  ✔ Submit  →", ""] + F.question + [""]
            + F.columns(options, F.box(mock, width: width, hidden: hidden))
            + ["", String(repeating: " ", count: F.boxColumn) + "Notes: press n to add notes", "", F.rule(150), "  Chat about this", "", F.hint]
    }

    /// A mock of 40 lines (a tall terminal's box): it scrolls inside its box at the Normal island and shows more of itself as the island grows.
    func testRenderALongMock() throws {
        let directory = try renderDirectory()
        let mock = (1...40).map { index -> String in index % 7 == 0 ? "" : "  línea \(index) del mock: \(String(repeating: "▒", count: index % 11 + 3))" }
        let rows = question(mock, width: 60, hidden: 12)
        try render("longmock", rows, at: normal, in: directory)
        try render("longmock", rows, at: tall, in: directory)
        try render("longmock", rows, at: smallest, in: directory)
    }

    /// A mock wider than the room beside the options: the card stacks them (and the mock shrinks to fit); wider than even that, the box scrolls across.
    func testRenderAWideMock() throws {
        let directory = try renderDirectory()
        let wideMock = ["┌" + String(repeating: "─", count: 84) + "┐"] + (1...6).map { "│ Columna \($0)  " + String(repeating: "·", count: 62) + String(repeating: " ", count: 4) + "│" }
            + ["└" + String(repeating: "─", count: 84) + "┘"]
        let rows = question(wideMock, width: 90)
        try render("widemock", rows, at: normal, in: directory)
        try render("widemock", rows, at: wide, in: directory)
        try render("widemock", rows, at: tall, in: directory)
        let huge = ["┌" + String(repeating: "─", count: 140) + "┐"] + (1...4).map { _ in "│ " + String(repeating: "x", count: 138) + " │" } + ["└" + String(repeating: "─", count: 140) + "┘"]
        try render("hugemock", question(huge, width: 144), at: normal, in: directory)
        try render("hugemock", question(huge, width: 144), at: tall, in: directory)
    }

    /// An option Claude gave no preview: its box says so.
    func testRenderAnOptionWithoutAPreview() throws {
        let directory = try renderDirectory()
        let rows = question(["No preview available"], width: 44)
        try render("nopreview", rows, at: normal, in: directory)
        try render("nopreview", rows, at: smallest, in: directory)
    }

    // MARK: Text sizes and colours

    func testRenderOtherTextSizesAndTabColours() throws {
        let directory = try renderDirectory()
        try render("big", F.sample(), at: normal, chatSize: DisplaySettings.chatSizeRange.upperBound, in: directory)
        try render("big", F.sample(), at: tall, chatSize: DisplaySettings.chatSizeRange.upperBound, in: directory)
        try render("small", F.sample(), at: normal, chatSize: DisplaySettings.chatSizeRange.lowerBound, in: directory)
        for tint in [TabTint.blue, .rose] { try render("tint-\(tint)", F.sample(), at: tall, notes: "el logo a la izquierda", tint: tint, in: directory) }
    }
}
