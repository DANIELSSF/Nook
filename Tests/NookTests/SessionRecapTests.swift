import XCTest
@testable import Nook

final class SessionRecapTests: XCTestCase {
    private let sample = "Mejorando Nook para tus sesiones de Claude: ya publiqué el Enter que se ejecuta solo y la cápsula de subagentes en el pie y el notch. Lo siguiente es que lo pruebes con tu Claude real y me digas qué ves."

    func testCleanJoinsLinesAndDropsTheLabel() {
        XCTAssertNil(RecapText.clean(nil))
        XCTAssertNil(RecapText.clean("  \n \t "))
        XCTAssertEqual(RecapText.clean("※ recap:  Hola\n  mundo  "), "Hola mundo")
        XCTAssertEqual(RecapText.clean("recap: Uno"), "Uno")
    }

    func testSplitTakesTheTopicOnlyWhenItLooksLikeOne() {
        let parts = RecapText.split(sample)
        XCTAssertEqual(parts.topic, "Mejorando Nook para tus sesiones de Claude")
        XCTAssertTrue(parts.body.hasPrefix("Ya publiqué el Enter"))
        XCTAssertTrue(parts.body.hasSuffix("qué ves."))
        XCTAssertNil(RecapText.split("Terminé el refactor. Lo siguiente: pruebas").topic)
        XCTAssertNil(RecapText.split("Next: ship it").topic)
        XCTAssertNil(RecapText.split("Sin dos puntos aquí").topic)
        XCTAssertNil(RecapText.split("Revisando src/app/main.swift: listo").topic)
        XCTAssertEqual(RecapText.split("Fixing the notch layout: shipped the fix. Next: test it").topic, "Fixing the notch layout")
    }

    func testDigestIsStableAndDistinguishes() {
        XCTAssertEqual(RecapText.digest(""), "cbf29ce484222325")
        XCTAssertEqual(RecapText.digest("a"), RecapText.digest("a"))
        XCTAssertNotEqual(RecapText.digest("a"), RecapText.digest("b"))
    }

    func testARecapIsNewUntilItsCardIsOpenedAndTheMemorySurvivesARelaunch() {
        let suite = "nook.recap.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecapSeenStore(defaults: defaults, key: "k")
        XCTAssertTrue(store.isNew("uno", in: "s1"))
        store.markSeen("uno", in: "s1")
        XCTAssertFalse(store.isNew("uno", in: "s1"))
        XCTAssertTrue(store.isNew("uno", in: "s2"), "each session remembers on its own")
        XCTAssertTrue(store.isNew("dos", in: "s1"), "a different recap is new again")
        XCTAssertFalse(RecapSeenStore(defaults: defaults, key: "k").isNew("uno", in: "s1"))
    }

    func testTheOldestSessionsAreForgottenPastTheLimit() {
        let store = RecapSeenStore(defaults: nil)
        for index in 0..<(RecapSeenStore.limit + 10) { store.markSeen("r", in: "s\(index)") }
        XCTAssertTrue(store.isNew("r", in: "s0"))
        XCTAssertFalse(store.isNew("r", in: "s\(RecapSeenStore.limit + 9)"))
    }

    func testEachTabKeepsItsOwnRecapAndReadState() {
        func tab(_ tty: String, _ recap: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: false, text: "⏺ Hola\n\n※ recap: " + recap)
        }
        let bridge = TerminalAppBridge()
        let first = TerminalSession(tab: tab("/dev/ttys041", "Sesión uno: arreglando el Enter."), backend: .bundled, bridge: bridge)
        let second = TerminalSession(tab: tab("/dev/ttys042", "Sesión dos: diseñando el gato."), backend: .bundled, bridge: bridge)
        XCTAssertEqual(first.recap, "Sesión uno: arreglando el Enter.")
        XCTAssertEqual(second.recap, "Sesión dos: diseñando el gato.")
        XCTAssertNotEqual(first.id, second.id, "The button is rebuilt per session id, so switching tabs swaps the recap.")

        let suite = "nook-recap-tabs-" + UUID().uuidString
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = RecapSeenStore(defaults: UserDefaults(suiteName: suite)!)
        store.markSeen(first.recap!, in: first.id)
        XCTAssertFalse(store.isNew(first.recap!, in: first.id))
        XCTAssertTrue(store.isNew(second.recap!, in: second.id), "Reading one tab's recap leaves the other one new.")
        XCTAssertTrue(store.isNew(first.recap!, in: second.id))
    }
}
