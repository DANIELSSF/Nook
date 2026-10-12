import XCTest
@testable import Nook

/// Edge cases of the model list: broken or odd catalog files, ids that need care in `/model <id>`, a picker that fits whole.
final class ClaudeModelEdgeTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-modeledge-" + UUID().uuidString)! }
    private func homeWith(files: [String: Data]) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-modeledge-" + UUID().uuidString)
        let folder = url.appendingPathComponent(".claude/cache/model-catalog")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try! data.write(to: folder.appendingPathComponent(name)) }
        return url
    }
    private let good = Data(#"{"fetchedAt":5,"catalog":{"surface":"cc","config":{"models":[{"id":"claude-a","name":"A 1","brand_new_field":[1,2]}]}}}"#.utf8)

    func testNoCacheFolderAtAllFallsBackToAliases() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("nook-modeledge-" + UUID().uuidString)
        let store = ClaudeModelStore(defaults: suite(), home: empty)
        XCTAssertNil(store.cached(folder: ".claude"))
        XCTAssertNil(store.cached(folder: nil))
        XCTAssertEqual(store.choices(folder: ".claude", current: nil).map(\.argument), ["default", "opus", "sonnet", "haiku"])
        XCTAssertNil(store.missingRows(folder: ".claude"))
        XCTAssertFalse(store.isStale(folder: ".claude", version: "2.1.290"))
    }

    func testACorruptOrEmptyFileIsIgnoredAndAGoodNeighbourStillCounts() {
        let junk: [String: Data] = ["a-cc.json": Data("{ truncated".utf8), "b-cc.json": Data(), "c-cc.json": Data(#"{"catalog":{"surface":"cc","config":{"models":[]}}}"#.utf8),
                                    "d-cc.json": Data(#"{"catalog":{"surface":"cc","config":{"models":[{"name":"no id"}]}}}"#.utf8), "notes.txt": good]
        let store = ClaudeModelStore(defaults: suite(), home: homeWith(files: junk))
        XCTAssertNil(store.cached(folder: ".claude"), "Nothing usable: the aliases stand.")
        var withGood = junk; withGood["e-cc.json"] = good
        let store2 = ClaudeModelStore(defaults: suite(), home: homeWith(files: withGood))
        XCTAssertEqual(store2.cached(folder: ".claude")?.models.map(\.name), ["A 1"], "Unknown fields are ignored; broken neighbours don't hide a good file.")
    }

    func testTheNewestOfSeveralFilesWins() {
        let older = Data(#"{"fetchedAt":1,"catalog":{"surface":"cc","config":{"models":[{"id":"old","name":"Old"}]}}}"#.utf8)
        let store = ClaudeModelStore(defaults: suite(), home: homeWith(files: ["a-cc.json": older, "b-cc.json": good]))
        XCTAssertEqual(store.cached(folder: ".claude")?.models.map(\.name), ["A 1"])
    }

    /// A catalog id is sent to the terminal as `/model <id>`: it must never carry a line break, which would send a second command.
    func testAModelIdWithALineBreakNeverReachesTheTerminalAsASecondCommand() {
        let id = "claude-x\n/exit"
        let data = Data(#"{"fetchedAt":5,"catalog":{"surface":"cc","config":{"models":[{"id":"claude-x\n/exit","name":"X"}]}}}"#.utf8)
        let model = AppModel(receivesSignals: false, defaults: suite())
        model.models = ClaudeModelStore(defaults: suite(), home: homeWith(files: ["a-cc.json": data]))
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "t", index: 1, tty: "/dev/ttys001", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Opus 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/x", rule, "❯ ", rule].joined(separator: "\n"))
        model.terminalBridge.directKeysAllowed = { true }
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        var sent: [String] = []
        model.commandSender = { text, _ in sent.append(text) }
        let weird = ClaudeModelChoice(label: "X", argument: id, row: 2)
        model.setModel(weird, on: session)
        XCTAssertTrue(sent.allSatisfy { !$0.contains("\n") }, "Sent: \(sent)")
    }

    func testAnIdWithSpacesOrQuotesStaysOneArgumentOrFallsBackToThePicker() {
        let model = AppModel(receivesSignals: false, defaults: suite())
        model.models = ClaudeModelStore(defaults: suite(), home: homeWith(files: [:]))
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "t", index: 1, tty: "/dev/ttys001", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Opus 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/x", rule, "❯ ", rule].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        var sent: [String] = []
        model.commandSender = { text, _ in sent.append(text) }
        // Spaces, quotes and shell characters: never typed after /model; Claude's picker is opened instead, to reach row 2.
        model.setModel(ClaudeModelChoice(label: "Q", argument: "my model\"; rm -rf ~ #", row: 2), on: session)
        XCTAssertEqual(sent, ["/model"])
        // A plain id, brackets and all, goes as one argument.
        sent = []
        model.setModel(ClaudeModelChoice(label: "S", argument: "claude-sonnet-4-6[1m]", row: 3), on: session)
        XCTAssertEqual(sent, ["/model claude-sonnet-4-6[1m]"])
        for bad in ["", "a b", "x\ty", "x\ry", "claude-x\n/exit", "\"q\"", "a;b", "$(id)", String(repeating: "a", count: 101)] {
            XCTAssertFalse(ClaudeModelStore.isSafeArgument(bad), bad)
        }
        // From the list on disk, such an id leaves its row to the picker.
        let data = Data(#"{"fetchedAt":5,"catalog":{"surface":"cc","config":{"models":[{"id":"bad id","name":"B 1"},{"id":"claude-b-2","name":"B 2"}]}}}"#.utf8)
        let store = ClaudeModelStore(defaults: suite(), home: homeWith(files: ["a-cc.json": data]))
        XCTAssertEqual(store.choices(folder: ".claude", current: nil).map(\.argument), ["default", nil, "claude-b-2"])
    }

    /// A picker with exactly nine rows and no "… +N models": nothing is missing, and it is still a model picker.
    func testANinePickerRowWithNoMoreLineMissesNothing() throws {
        let rows = (1...9).map { ($0 == 2 ? " ❯  " : "    ") + "\($0).  Model \($0)   Does thing \($0)" }
        let screen = ["⏺ Listo.", "", rule, " Select model", " Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with",
                      " --model.", ""] + rows + ["", " ● xHigh effort ←/→ to adjust", "", " Enter to set as default · s to use this session only · Esc to cancel"]
        let joined = screen.joined(separator: "\n")
        let picker = try XCTUnwrap(AgentPrompt.parse(joined))
        XCTAssertTrue(ClaudeModelStore.isModelPicker(picker))
        XCTAssertEqual(picker.options.count, 9)
        XCTAssertEqual(picker.moreBelow, 0)
        let store = ClaudeModelStore(defaults: suite(), home: FileManager.default.temporaryDirectory.appendingPathComponent("nook-modeledge-" + UUID().uuidString))
        store.learn(picker, version: "2.1.290", folder: ".claude")
        XCTAssertEqual(store.missingRows(folder: ".claude"), 0)
        XCTAssertEqual(store.catalog(folder: ".claude")?.total, 9)
    }
}
