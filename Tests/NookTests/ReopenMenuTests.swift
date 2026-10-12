import XCTest
@testable import Nook

/// The "+" menu lists the tabs that left the row, newest first, so a slip of the ✕ is one pick from undone.
@MainActor
final class ReopenMenuTests: XCTestCase {
    private func terminal(_ tty: String, _ title: String) -> AppModel.ClosedTab { .terminal(tty: tty, title: title) }

    private func nook(_ id: String, _ title: String) -> AppModel.ClosedTab {
        .nook(SessionRecord(id: id, name: title, kind: .claude, directory: "/tmp", socket: "/tmp/nook-test.sock", ownsSession: true), title: title)
    }

    func testNothingClosedOffersNothing() {
        XCTAssertEqual(ReopenMenu.entries([]), [])
    }

    func testTheTabThatClosedLastIsNamedAsSuchAndTheOthersByTheirTitle() {
        let entries = ReopenMenu.entries([terminal("/dev/ttys006", "EP2026-214"), nook("nook-1", "Claude Code"), terminal("/dev/ttys004", "ui")])
        XCTAssertEqual(entries.map(\.label), ["Reabrir pestaña cerrada: «EP2026-214»", "Reabrir «Claude Code»", "Reabrir «ui»"])
    }

    func testEachEntryKeepsItsTabAndItsPlace() {
        let closed = [terminal("/dev/ttys006", "a"), nook("nook-1", "b"), terminal("/dev/ttys004", "a")]
        let entries = ReopenMenu.entries(closed)
        XCTAssertEqual(entries.map(\.tab), closed, "choosing an entry reopens that tab, in the order the model keeps them")
        XCTAssertEqual(Set(entries.map(\.id)).count, 3, "two tabs with one title are two entries")
    }

    func testALongTitleIsCutWithAnEllipsis() {
        let title = String(repeating: "abcdefghij", count: 6)
        let label = ReopenMenu.label(for: title, newest: false)
        XCTAssertEqual(label, "Reabrir «" + String(title.prefix(ReopenMenu.titleLimit)) + "…»")
    }

    func testATitleAtTheLimitIsShownWhole() {
        let title = String(repeating: "x", count: ReopenMenu.titleLimit)
        XCTAssertEqual(ReopenMenu.label(for: title, newest: true), "Reabrir pestaña cerrada: «\(title)»")
    }

    func testATitleOnSeveralLinesIsOneLine() {
        XCTAssertEqual(ReopenMenu.label(for: "  ✳ Revisar\nlas pestañas \n", newest: false), "Reabrir «✳ Revisar las pestañas»")
    }

    func testATabWithoutATitleCanStillBeReopened() {
        XCTAssertEqual(ReopenMenu.label(for: "", newest: true), "Reabrir pestaña cerrada")
        XCTAssertEqual(ReopenMenu.label(for: " \n ", newest: false), "Reabrir otra pestaña sin nombre")
    }

    /// The model's own close puts the tab in the menu: nothing here fills the list by hand.
    func testClosingATabThroughTheModelOffersItInTheMenu() {
        let model = AppModel(receivesSignals: false)
        func session(_ tty: String, _ title: String) -> TerminalSession {
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false,
                                          selected: true, text: "⏺ Revisando.")
            return TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        }
        let ui = session("/dev/ttys086", "ui"), docs = session("/dev/ttys087", "docs")
        model.sessions = [ui, docs]
        XCTAssertEqual(ReopenMenu.entries(model.recentlyClosed), [], "nothing has closed: the menu has no such section")
        model.close(ui)
        XCTAssertEqual(ReopenMenu.entries(model.recentlyClosed).map(\.label), ["Reabrir pestaña cerrada: «\(ui.displayTitle)»"])
        model.close(docs)
        XCTAssertEqual(ReopenMenu.entries(model.recentlyClosed).map(\.label), ["Reabrir pestaña cerrada: «\(docs.displayTitle)»", "Reabrir «\(ui.displayTitle)»"],
                       "the one closed last leads")
    }

    func testOnlyTheLastFewClosedTabsAreOffered() {
        let model = AppModel(receivesSignals: false)
        let sessions = (0..<(AppModel.closedLimit + 2)).map { index -> TerminalSession in
            let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: index + 1, tty: "/dev/ttys08\(index)", customTitle: "tab \(index)", processes: ["login", "-zsh"], busy: false,
                                          selected: false, text: "")
            return TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        }
        model.sessions = sessions
        sessions.forEach { model.close($0) }
        let entries = ReopenMenu.entries(model.recentlyClosed)
        XCTAssertEqual(entries.count, AppModel.closedLimit)
        XCTAssertEqual(entries.first?.label, "Reabrir pestaña cerrada: «\(sessions.last!.displayTitle)»")
    }
}
