import SwiftUI
import XCTest
@testable import Nook

/// A message that went with images carries their paths in its text (`MessageAttachments.message`). Wherever the island shows such a message again it shows its words
/// and its pictures, not the paths: the bubble on its way (and Claude's queue), and the history ↑ walks. And a message that could not be delivered goes back to the
/// tab's own stores, the pane that sent it having possibly gone.
@MainActor
final class SentMessagePicturesTests: XCTestCase {
    private let folder = MessageAttachments.folder
    private var one: String { folder + "imagen-1.png" }
    private var two: String { folder + "pantalla-2.png" }

    // MARK: The bubble on its way

    func testTheBubbleShowsImagePlaceholdersWhereThePathsWere() {
        XCTAssertEqual(SessionPane.displayedMessage("mira esto " + one), "mira esto [Image #1]", "The way Claude's own record writes it.")
        XCTAssertEqual(SessionPane.displayedMessage("compara " + one + " " + two), "compara [Image #1] [Image #2]")
        XCTAssertEqual(SessionPane.displayedMessage(one), "[Image #1]", "A message of only an image.")
        XCTAssertEqual(SessionPane.displayedMessage("revisa por qué falla el build"), "revisa por qué falla el build", "A message without images is as it was.")
        XCTAssertEqual(SessionPane.displayedMessage("mira /Users/me/notas.txt"), "mira /Users/me/notas.txt", "A path that is not an image stays a word.")
        XCTAssertEqual(SessionPane.displayedMessage("mira " + one + " y dime"), "mira " + one + " y dime", "A path in the middle of the words is the user's own; only those the message ends with were attached.")
        XCTAssertFalse(SessionPane.displayedMessage("mira esto " + one).contains("/tmp/"), "No path shows.")
    }

    func testWhatGoesOutIsUntouchedByHowItIsShown() {
        let sent = MessageAttachments.message(text: "mira esto", files: [one, two])
        XCTAssertEqual(sent, "mira esto " + one + " " + two, "The agent opens the files by their paths.")
        XCTAssertEqual(MessageAttachments.parts(of: sent).files, [one, two])
        XCTAssertNotEqual(SessionPane.displayedMessage(sent), sent)
    }

    // MARK: The history

    private func step(_ cursor: inout HistoryCursor, older: Bool, history: [String], draft: String, attachments: [String]) -> (draft: String, attachments: [String])? {
        cursor.step(older: older, history: history, draft: draft, attachments: attachments)
    }

    func testTheHistoryBringsBackWordsAndPicturesAndThenTheDraftWithItsOwn() throws {
        let history = ["hola", "mira esto " + one, "compara " + one + " " + two]
        var cursor = HistoryCursor()
        let mine = [folder + "mio.png"]
        var next = try XCTUnwrap(step(&cursor, older: true, history: history, draft: "borrador", attachments: mine))
        XCTAssertEqual(next.draft, "compara"); XCTAssertEqual(next.attachments, [one, two], "The newest message, with its two pictures instead of their paths.")
        next = try XCTUnwrap(step(&cursor, older: true, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(next.draft, "mira esto"); XCTAssertEqual(next.attachments, [one])
        next = try XCTUnwrap(step(&cursor, older: true, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(next.draft, "hola"); XCTAssertEqual(next.attachments, [], "A message without pictures brings none.")
        let atTheEnd = try XCTUnwrap(step(&cursor, older: true, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(atTheEnd.draft, "hola"); XCTAssertEqual(atTheEnd.attachments, [], "At the oldest message nothing moves.")
        // And back: ↓ walks forward, and past the newest the draft returns with the pictures it had.
        next = try XCTUnwrap(step(&cursor, older: false, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(next.draft, "mira esto"); XCTAssertEqual(next.attachments, [one])
        next = try XCTUnwrap(step(&cursor, older: false, history: history, draft: next.draft, attachments: next.attachments))
        next = try XCTUnwrap(step(&cursor, older: false, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(next.draft, "borrador"); XCTAssertEqual(next.attachments, mine, "The draft that was being written comes back with its own picture.")
        XCTAssertNil(step(&cursor, older: false, history: history, draft: next.draft, attachments: next.attachments), "↓ with nothing recalled keeps its usual meaning.")
    }

    func testAPathTheUserTypedInTheDraftIsNotTakenForAPictureWhenTheDraftComesBack() throws {
        // The draft is the user's own: only what the history brings is split into words and pictures.
        let history = ["hola"]
        var cursor = HistoryCursor()
        let typed = "mira " + one
        var next = try XCTUnwrap(step(&cursor, older: true, history: history, draft: typed, attachments: []))
        XCTAssertEqual(next.draft, "hola")
        next = try XCTUnwrap(step(&cursor, older: false, history: history, draft: next.draft, attachments: next.attachments))
        XCTAssertEqual(next.draft, typed, "Back as it was written, path and all.")
        XCTAssertEqual(next.attachments, [])
    }

    func testTheOldStepStillWorksAsItDid() {
        var cursor = HistoryCursor()
        XCTAssertNil(cursor.step(older: true, history: [], draft: "x"))
        XCTAssertEqual(cursor.step(older: true, history: ["a", "b"], draft: "x"), "b")
        XCTAssertEqual(cursor.step(older: true, history: ["a", "b"], draft: "x"), "a")
        XCTAssertEqual(cursor.step(older: false, history: ["a", "b"], draft: "x"), "b")
        XCTAssertEqual(cursor.step(older: false, history: ["a", "b"], draft: "x"), "x")
        cursor.reset()
        XCTAssertNil(cursor.index)
    }

    // MARK: Sending the message in Claude's box as it is

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session).id(session.id)
            }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32), alignment: .top)
                .background(Color.black)
                .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        }
    }

    func testSendingTheJoinedMessageAsItIsTakesTheChipsWithIt() throws {
        let model = ScreenVisionUIFixture.model(try ScreenVisionUIFixture.vision(enabled: false))
        let tab = ScreenVisionUIFixture.session(in: model, text: ScreenVisionUIFixture.claudeScreen())
        MessageAttachments.shared.set([one], for: tab.id)
        defer { MessageAttachments.shared.set([], for: tab.id) }
        tab.joinedBox = "Tu mensaje ya estaba en la caja"
        let host = NSHostingView(rootView: Island(model: model, session: tab))
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        // The card floats over the composer and marks itself; its buttons are in its last row, the one that sends at its end.
        let card = try XCTUnwrap(PointerHoles.frames(in: window).first { $0.width > 300 && $0.minY < 120 }, "The warning about the joined message is on show.")
        XCTAssertEqual(MessageAttachments.shared.paths(for: tab.id), [one], "The chip is on the composer.")
        let point = NSPoint(x: card.maxX - 46, y: card.minY + 22)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(tab.joinedBox, "«Enviar así» was pressed.")
        XCTAssertEqual(MessageAttachments.shared.paths(for: tab.id), [], "The images went with the message in Claude's box: they are not the next message's.")
    }

    // MARK: A message that was not delivered

    private func session() -> TerminalSession {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-giveback-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys096", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: "⏺ Listo.")
        return TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
    }

    func testAMessageThatWasNotDeliveredGoesBackToTheTabsOwnStores() {
        let tab = session()
        let store = MessageAttachments()
        let gave = SessionPane.giveBack("mira esto", files: [one], to: tab, store: store)
        XCTAssertTrue(gave.draft); XCTAssertTrue(gave.attachments)
        XCTAssertEqual(tab.draft, "mira esto", "The tab's draft is what the pane the user comes back to starts from, if the one that sent it is gone.")
        XCTAssertEqual(store.paths(for: tab.id), [one], "…and so are the tab's pictures.")
    }

    func testWhatWasWrittenMeanwhileIsNotOverwritten() {
        let tab = session()
        let store = MessageAttachments()
        tab.draft = "otra cosa"
        store.set([two], for: tab.id)
        let gave = SessionPane.giveBack("mira esto", files: [one], to: tab, store: store)
        XCTAssertFalse(gave.draft); XCTAssertFalse(gave.attachments)
        XCTAssertEqual(tab.draft, "otra cosa")
        XCTAssertEqual(store.paths(for: tab.id), [two])
        // A message with no words, or no pictures, gives back only what it has.
        let onlyWords = SessionPane.giveBack("solo palabras", files: [], to: session(), store: MessageAttachments())
        XCTAssertTrue(onlyWords.draft); XCTAssertFalse(onlyWords.attachments)
        let onlyImage = SessionPane.giveBack("", files: [one], to: session(), store: MessageAttachments())
        XCTAssertFalse(onlyImage.draft); XCTAssertTrue(onlyImage.attachments)
    }
}
