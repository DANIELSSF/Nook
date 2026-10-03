import XCTest
@testable import Nook

final class ComposerFlowTests: XCTestCase {
    func testArrowsWalkTheSentHistoryLikeAShell() {
        var cursor = HistoryCursor()
        let history = ["/usage", "continúa", "revisa el gato"]
        XCTAssertNil(cursor.step(older: false, history: history, draft: "borrador"), "↓ keeps its meaning outside the history.")
        XCTAssertEqual(cursor.step(older: true, history: history, draft: "borrador"), "revisa el gato")
        XCTAssertEqual(cursor.step(older: true, history: history, draft: "revisa el gato"), "continúa")
        XCTAssertEqual(cursor.step(older: true, history: history, draft: "continúa"), "/usage")
        XCTAssertEqual(cursor.step(older: true, history: history, draft: "/usage"), "/usage", "Stays on the oldest.")
        XCTAssertEqual(cursor.step(older: false, history: history, draft: "/usage"), "continúa")
        XCTAssertEqual(cursor.step(older: false, history: history, draft: "continúa"), "revisa el gato")
        XCTAssertEqual(cursor.step(older: false, history: history, draft: "revisa el gato"), "borrador", "Past the newest, the draft comes back.")
        XCTAssertNil(cursor.index)
        XCTAssertNil(cursor.step(older: true, history: [], draft: "x"))
    }

    func testHistoryIsKeptPerTabWithoutRepeatsAndCapped() {
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys060", customTitle: "", processes: ["claude"], busy: false, selected: true, text: "")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.remember("hola", for: session)
        model.remember("hola", for: session)
        XCTAssertEqual(session.sentHistory, ["hola"])
        for i in 0..<60 { model.remember("mensaje \(i)", for: session) }
        XCTAssertEqual(session.sentHistory.count, 50)
        XCTAssertEqual(session.sentHistory.last, "mensaje 59")
    }

    func testSentMessageShowsAtOnceAndGoesWhenTheTerminalEchoesIt() {
        let rule = String(repeating: "─", count: 80)
        func screen(_ body: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys061", customTitle: "", processes: ["claude"], busy: false, selected: true, text: body + "\n" + rule + "\n❯ \n" + rule)
        }
        let session = TerminalSession(tab: screen("> continúa\n\n⏺ Hecho."), backend: .bundled, bridge: TerminalAppBridge())
        session.showPending("continúa")
        session.update(screen("> continúa\n\n⏺ Hecho.\n\n✶ Thinking…"))
        XCTAssertEqual(session.pendingMessage, "continúa", "An earlier identical message is not its echo.")
        session.update(screen("> continúa\n\n⏺ Hecho.\n\n> continúa"))
        XCTAssertNil(session.pendingMessage)
    }

    func testNumberedMenuIsRecognisedAtTheBottomOfTheMirror() {
        let permission = ["⏺ Bash(rm -rf build)", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again", "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        XCTAssertTrue(SessionPane.showsNumberedMenu(permission))
        XCTAssertTrue(SessionPane.showsNumberedMenu(permission.replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "❯ 2.")), "The highlight can sit on any option.")
        XCTAssertTrue(SessionPane.showsNumberedMenu(["Select model", "  1. Default (recommended)", "› 2. Opus", "  3. Haiku"].joined(separator: "\n")))
        let reply = ["⏺ Pendiente:", "  1. Reconecta la pestaña.", "  2. Dímelo si no la quitaste tú.", "  3. No he probado a mano Enter."].joined(separator: "\n")
        XCTAssertFalse(SessionPane.showsNumberedMenu(reply), "A numbered list in a reply has no highlighted option.")
        XCTAssertFalse(SessionPane.showsNumberedMenu("> 1. una pregunta\n> 2. otra"), "Messages open with >, menus with ❯.")
        XCTAssertFalse(SessionPane.showsNumberedMenu("⏺ Hecho."))
        XCTAssertFalse(SessionPane.showsNumberedMenu(""))
        let old = permission + "\n" + (1...14).map { "línea \($0)" }.joined(separator: "\n")
        XCTAssertFalse(SessionPane.showsNumberedMenu(old), "A menu that scrolled away is not open any more.")
    }

    func testTheMirrorKeepsWhatSlidOutOfTerminalsWindow() {
        // Terminal returns only its last characters: the window slides as output grows.
        let lines = (1...40).map { "línea \($0) de la conversación" }
        let first = lines[0..<30].joined(separator: "\n")
        let second = lines[10..<40].joined(separator: "\n")
        let archive = TerminalSession.archived("", previous: first, next: second)
        XCTAssertEqual(archive + second, lines.joined(separator: "\n"), "Nothing is lost and nothing repeats.")
        XCTAssertEqual(TerminalSession.archived(archive, previous: second, next: second + "\nnueva"), archive, "Growth at the end keeps the archive.")
        XCTAssertEqual(TerminalSession.archived(archive, previous: second, next: "⏺ Conversación redibujada desde el principio"), "", "A full redraw starts over instead of doubling it.")
        let long = String(repeating: "x", count: 99) + "\n"
        let trimmed = TerminalSession.archived(String(repeating: long, count: 30), previous: "aaaa" + second, next: second, limit: 2000)
        XCTAssertLessThanOrEqual((trimmed as NSString).length, 2000)
        XCTAssertTrue(trimmed.hasPrefix("x"), "Trimmed at a line start.")
    }

    func testMirrorUpdatesOnlyGrowAtTheEndWhenTheWindowSlides() {
        let lines = (1...60).map { "⏺ línea \($0)" }
        func tab(_ range: Range<Int>) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys062", customTitle: "", processes: ["zsh"], busy: false, selected: true, text: lines[range].joined(separator: "\n"))
        }
        let session = TerminalSession(tab: tab(0..<40), backend: .bundled, bridge: TerminalAppBridge())
        let before = session.displayText
        session.update(tab(20..<60))
        XCTAssertTrue(session.displayText.hasPrefix(before), "Earlier text stays where it was.")
        XCTAssertEqual(session.displayText, lines.joined(separator: "\n"))
    }

    func testImagePasteKeyAndAttachments() throws {
        XCTAssertFalse(TerminalKey.menuKeys.contains(.pasteImage), "⌃V is not a menu key.")
        XCTAssertEqual(TerminalKey.pasteImage.tmuxName, "C-v")
        XCTAssertEqual(TerminalKey.pasteImage.modifiers, .maskControl)
        XCTAssertEqual(TerminalKey.down.modifiers, [], "Menu keys carry no modifiers.")
        // An image Claude shows as "[Image #1]" in front of the message is not leftover text.
        let rule = String(repeating: "─", count: 80)
        let screen = ["⏺ Hola", rule, "❯ [Image #1] mira esta captura", rule].joined(separator: "\n")
        XCTAssertNil(MessageEcho.joined("mira esta captura", in: screen))
        XCTAssertNotNil(MessageEcho.joined("captura", in: screen), "Typed text in front still counts.")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nook-image-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemMint.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pasteboard.clearContents(); pasteboard.writeObjects([image])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-images-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try XCTUnwrap(AppModel.saveImage(from: pasteboard, folder: folder))
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertNotNil(NSImage(contentsOfFile: path))
    }

    func testAStaleReadingDoesNotUndoTheUsersPick() {
        let model = AppModel(receivesSignals: false)
        model.terminalBridge.runScript = { _ in }   // selecting must not reach the real Terminal
        func tab(_ tty: String, selected: Bool) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 7, windowTitle: "IA", index: tty == "/dev/ttys070" ? 1 : 2, tty: tty, customTitle: "", processes: ["zsh"], busy: false, selected: selected, text: tty)
        }
        let ttys: Set<String> = ["/dev/ttys070", "/dev/ttys071"]
        model.updateExternalTabs([tab("/dev/ttys070", selected: true), tab("/dev/ttys071", selected: false)], ttys: ttys)
        let first = model.sessions.first { $0.externalTTY == "/dev/ttys070" }!
        let second = model.sessions.first { $0.externalTTY == "/dev/ttys071" }!
        model.select(first)
        let readingStarted = Date()
        second.draft = "borrador a medias"
        model.select(second)
        // The reading that began before the pick still reports the first tab as selected.
        model.updateExternalTabs([tab("/dev/ttys070", selected: true), tab("/dev/ttys071", selected: false)], ttys: ttys, requestedAt: readingStarted)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(second.draft, "borrador a medias", "The draft belongs to the tab, not to the recreated field.")
    }
}
