import AppKit
import XCTest
@testable import Nook

final class TerminalBridgeTests: XCTestCase {
    func testHelperPreservesAppleScriptBooleansAndNestedLists() throws {
        let result = try TerminalAppBridge.execute("return {true, false, {42, \"pestaña 🚀\"}}")
        let value = try XCTUnwrap(TerminalAppBridge.structuredValue(result) as? [Any])
        XCTAssertEqual(value[0] as? Bool, true)
        XCTAssertEqual(value[1] as? Bool, false)
        let nested = try XCTUnwrap(value[2] as? [Any])
        XCTAssertEqual(nested[0] as? Int32, 42)
        XCTAssertEqual(nested[1] as? String, "pestaña 🚀")
    }
    func testMessageRemainsLiteralAcrossAppleScriptBoundary() throws {
        let input = "Hola \"gato\" \\ carpeta\nsegunda línea\rtab\t$(printf BAD); `printf BAD` 🐈"
        let result = try TerminalAppBridge.execute("return " + AppleScriptText.literal(input))
        XCTAssertEqual(result.stringValue, input)
    }

    func testScriptsCompileWithInstalledTerminalDictionary() throws {
        for source in [TerminalAppBridge.snapshotScript(includeText: false),
                       TerminalAppBridge.snapshotScript(windowIDs: [42, 100], ttys: ["/dev/ttys003", "/dev/ttys008"], includeText: true),
                       TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: "do script \(AppleScriptText.literal("text\nline")) in t"),
                       TerminalAppBridge.targetScript(windowID: 42, tty: "/dev/ttys003", action: "set selected of t to true\nset miniaturized of targetWindow to false\nset index of targetWindow to 1\nactivate")] {
            var details: NSDictionary?
            XCTAssertTrue(NSAppleScript(source: source)!.compileAndReturnError(&details), details?.description ?? "")
        }
    }

    func testSnapshotsPreserveUnicodeAndBoundariesWithoutTextDelimiters() throws {
        let row = NSAppleEventDescriptor.list()
        let processes = NSAppleEventDescriptor.list()
        processes.insert(NSAppleEventDescriptor(string: "zsh"), at: 1)
        processes.insert(NSAppleEventDescriptor(string: "claude"), at: 2)
        let items: [NSAppleEventDescriptor] = [.init(int32: 42), .init(string: "IA · gato"), .init(int32: 2), .init(string: "/dev/ttys003"), .init(string: "Trabajo"), processes, .init(boolean: true), .init(boolean: false), .init(string: "línea\ncon\ttab y 🚀")]
        for (i, item) in items.enumerated() { row.insert(item, at: i + 1) }
        let response = NSAppleEventDescriptor.list(); response.insert(row, at: 1)
        let tab = try XCTUnwrap(TerminalAppBridge.decode(response).first)
        XCTAssertEqual(tab.tty, "/dev/ttys003")
        XCTAssertEqual(tab.windowID, 42)
        XCTAssertEqual(tab.processes, ["zsh", "claude"])
        XCTAssertEqual(tab.title, "Trabajo")
        XCTAssertEqual(tab.text, "línea\ncon\ttab y 🚀")
        XCTAssertTrue(tab.busy)
        XCTAssertFalse(tab.selected)
        XCTAssertThrowsError(try TerminalAppBridge.decode(NSAppleEventDescriptor(string: "unexpected")))
    }

    func testMirrorKeepsOriginalTTYWhenTabsAreReordered() {
        let bridge = TerminalAppBridge()
        let first = TerminalTabSnapshot(windowID: 42, windowTitle: "IA", index: 2, tty: "/dev/ttys003", customTitle: "", processes: ["zsh", "claude"], busy: true, selected: true, text: "respuesta inicial")
        let session = TerminalSession(tab: first, backend: .bundled, bridge: bridge)
        let originalID = session.id
        let reordered = TerminalTabSnapshot(windowID: 42, windowTitle: "IA", index: 1, tty: "/dev/ttys003", customTitle: "Proyecto", processes: ["zsh", "claude"], busy: true, selected: true, text: "respuesta actualizada\n")
        session.update(reordered)
        XCTAssertEqual(session.id, originalID)
        XCTAssertEqual(session.externalTTY, "/dev/ttys003")
        XCTAssertEqual(session.mirroredText, "respuesta actualizada")
        XCTAssertEqual(session.title, "Proyecto")
        XCTAssertFalse(session.record.ownsSession)
        let activity = session.lastOutput
        session.update(reordered)
        XCTAssertEqual(session.lastOutput, activity, "Una consulta sin cambios no cuenta como nueva salida.")
    }

    func testAKeyIsPostedBeforeASelectionQueuedAfterIt() {
        let bridge = TerminalAppBridge()
        let lock = NSLock()
        var log: [String] = []
        func record(_ entry: String) { lock.lock(); log.append(entry); lock.unlock() }
        bridge.directKeysAllowed = { true }
        bridge.terminalProcess = { 4242 }
        bridge.runScript = { script in
            Thread.sleep(forTimeInterval: 0.05)
            record(script.contains("frontmost") ? "verificar A" : "seleccionar B")
        }
        bridge.postKey = { _, _ in record("tecla A") }
        let done = expectation(description: "selection finished")
        bridge.press(.down, windowID: 1, tty: "/dev/ttysA") { _ in }
        // The user picks another tab while the key's script is still running.
        bridge.select(windowID: 1, tty: "/dev/ttysB") { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(log, ["verificar A", "tecla A", "seleccionar B"])
    }

    func testATabMovedToAnotherWindowKeepsBeingFollowed() {
        let tracked = [TrackedTerminalTab(windowID: 10, tty: "/dev/ttys080"), TrackedTerminalTab(windowID: 10, tty: "/dev/ttys081")]
        let moved = TerminalTabSnapshot(windowID: 22, windowTitle: "Otra", index: 3, tty: "/dev/ttys080", customTitle: "", processes: ["claude"], busy: false, selected: true, text: "")
        XCTAssertEqual(TerminalAppBridge.adopted(tracked, [moved]), [TrackedTerminalTab(windowID: 22, tty: "/dev/ttys080"), TrackedTerminalTab(windowID: 10, tty: "/dev/ttys081")])
        XCTAssertTrue(TerminalAppBridge.snapshotScript(ttys: ["/dev/ttys080"], includeText: true).contains("if true then"), "All windows are searched.")
    }
}
