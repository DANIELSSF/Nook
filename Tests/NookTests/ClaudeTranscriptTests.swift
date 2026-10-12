import XCTest
@testable import Nook

final class ClaudeTranscriptTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    private func user(_ content: Any, meta: Bool = false) -> String { line(["type": "user", "isMeta": meta, "message": ["role": "user", "content": content]]) }
    private func assistant(_ blocks: [[String: Any]]) -> String { line(["type": "assistant", "cwd": "/Users/me/app", "message": ["role": "assistant", "content": blocks]]) }

    func testRecordBecomesTheMirrorsConversation() {
        var renderer = TranscriptRenderer()
        [user("revisa el notch\ny dime qué ves"),
         user("recordatorio interno", meta: true),
         user("<task-notification>agente terminó</task-notification>"),
         user("<command-name>/usage</command-name><command-args></command-args>"),
         assistant([["type": "thinking", "thinking": "privado"], ["type": "text", "text": "Voy a mirarlo."]]),
         assistant([["type": "tool_use", "id": "a", "name": "Read", "input": ["file_path": "/Users/me/app/Sources/Notch.swift"]],
                    ["type": "tool_use", "id": "b", "name": "Bash", "input": ["command": "swift test\n--verbose"]]]),
         user([["type": "tool_result", "tool_use_id": "a", "content": "línea 1\nlínea 2\nlínea 3\nlínea 4\nlínea 5"]]),
        ].forEach { renderer.consume($0) }
        // The Bash call is still running: it shows after what is finished.
        XCTAssertTrue(renderer.text.hasSuffix("⏺ Bash(swift test)\n  ⎿  …\n\n"))
        renderer.consume(user([["type": "tool_result", "tool_use_id": "b", "is_error": true, "content": [["type": "text", "text": "falló la compilación"]]]]))
        renderer.consume(user([["type": "image", "source": [:]], ["type": "text", "text": "mira esta captura"]]))
        renderer.consume(line(["type": "system", "subtype": "away_summary", "content": "Mejorando Nook."]))
        renderer.consume(line(["type": "user", "isSidechain": true, "message": ["role": "user", "content": "de un subagente"]]))
        XCTAssertEqual(renderer.text, """
        > revisa el notch
          y dime qué ves

        > /usage

        ⏺ Voy a mirarlo.

        ⏺ Read(Sources/Notch.swift)
          ⎿  línea 1
             línea 2
             línea 3
             … +2 líneas

        ⏺ Bash(swift test)
          ⎿  Error: falló la compilación

        > [Imagen]

        > mira esta captura


        """)
        XCTAssertEqual(renderer.recap, "Mejorando Nook.")
    }

    func testPastedContentShowsItsTextAndOldEntriesAreTrimmedAtABoundary() {
        var renderer = TranscriptRenderer()
        renderer.consume(user("<pasted_content id=\"x\">\nhola desde el portapapeles\n</pasted_content>"))
        XCTAssertEqual(renderer.text, "> hola desde el portapapeles\n\n")
        var small = TranscriptRenderer(); small.limit = 200
        for i in 0..<20 { small.consume(user("mensaje número \(i) con algo de texto")) }
        XCTAssertLessThanOrEqual((small.text as NSString).length, 200)
        XCTAssertTrue(small.text.hasPrefix("> mensaje número"), "Cut at an entry boundary.")
        XCTAssertTrue(small.text.contains("mensaje número 19"))
    }

    func testFollowerReadsOnlyWhatWasAppended() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-record-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (user("primero") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let follower = TranscriptFollower(url: url)
        XCTAssertEqual(follower.poll(), "> primero\n\n")
        XCTAssertNil(follower.poll(), "Nothing new, nothing to redraw.")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let next = user("segundo")
        try handle.write(contentsOf: Data((next.prefix(10)).utf8))
        XCTAssertNil(follower.poll(), "Half a line waits for the rest.")
        try handle.write(contentsOf: Data((next.dropFirst(10) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(follower.poll(), "> primero\n\n> segundo\n\n")

        // A long record starts at a line boundary inside its last bytes.
        let tail = TranscriptFollower(url: url, initialBytes: UInt64((next + "\n").utf8.count + 3))
        XCTAssertEqual(tail.poll(), "> segundo\n\n")
    }

    func testRecordsAreFoundBySessionOrByFolderAndScreen() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-home-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = TranscriptLocator.folderName(for: "/Users/me/My project")
        XCTAssertEqual(folder, "-Users-me-My-project")
        let project = home.appendingPathComponent(".claude-work/projects").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let older = project.appendingPathComponent("aaaa.jsonl"), newer = project.appendingPathComponent("bbbb.jsonl")
        try (user("pregunta de la otra sesión") + "\n").write(to: older, atomically: true, encoding: .utf8)
        try (user("revisa el notch por favor") + "\n").write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: older.path)
        let roots = TranscriptLocator.roots(home: home)
        XCTAssertEqual(roots.map(\.lastPathComponent), ["projects"])
        XCTAssertEqual(TranscriptLocator.record(session: "aaaa", roots: roots)?.lastPathComponent, "aaaa.jsonl")
        XCTAssertNil(TranscriptLocator.record(session: "../aaaa", roots: roots))
        // The screen shows the other session's prompt: that record wins over the most recent one.
        XCTAssertEqual(TranscriptLocator.guess(directory: "/Users/me/My project", screen: "❯ pregunta de la otra sesión", roots: roots)?.lastPathComponent, "aaaa.jsonl")
        // Nothing on screen says which: no record, rather than another session's (a Claude just started has none yet).
        XCTAssertNil(TranscriptLocator.guess(directory: "/Users/me/My project", screen: "nada reconocible", roots: roots))
        XCTAssertNil(TranscriptLocator.guess(directory: "/Users/me/My project", screen: "╭─ Claude Code ─╮\n│ Recent activity │\n│ revisa el notch por favor │", roots: roots),
                     "Words in Claude's welcome are not a prompt.")
        XCTAssertNil(TranscriptLocator.guess(directory: "/Users/me/My project", screen: "❯ pregunta de la otra sesión", excluding: [older], roots: roots),
                     "A record another tab follows is that tab's.")
    }

    func testAPromptCountsOnlyWhereClaudeDrawsTheUsersTurns() {
        let screen = ["⏺ Hecho.", "", "❯ revisa por qué falla la prueba del notch y dime qué cambió en la", "  ventana", "", "⏺ Voy."].joined(separator: "\n")
        XCTAssertTrue(TranscriptLocator.shows(prompt: "revisa por qué falla la prueba del notch y dime qué cambió en la ventana", on: screen), "Wrapped lines join.")
        XCTAssertTrue(TranscriptLocator.shows(prompt: "revisa por qué falla", on: screen), "A prompt's first line starts its block.")
        XCTAssertFalse(TranscriptLocator.shows(prompt: "Hecho.", on: screen), "A reply is not a prompt.")
        XCTAssertFalse(TranscriptLocator.shows(prompt: "sí", on: "⏺ Sí, lo hago.\n  sí claro"), "A short word anywhere is not a prompt.")
        XCTAssertFalse(TranscriptLocator.shows(prompt: "", on: screen))
    }

    func testTheRecordKeepsTheMirrorWhileTheScreenFeedsTheRest() {
        let rule = String(repeating: "─", count: 80)
        func tab(_ text: String) -> TerminalTabSnapshot {
            TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys090", customTitle: "", processes: ["claude"], busy: true, selected: true, text: text)
        }
        let session = TerminalSession(tab: tab("⏺ solo lo visible\n✶ Churning… (3s)\n" + rule + "\n❯ \n" + rule), backend: .bundled, bridge: TerminalAppBridge())
        session.applyTranscript("> pregunta antigua\n\n⏺ respuesta completa\n\n", recap: "Resumen del archivo")
        session.update(tab("⏺ otra parte visible\n✻ Churned for 1m 2s\n" + rule + "\n❯ \n" + rule))
        XCTAssertEqual(session.displayText, "> pregunta antigua\n\n⏺ respuesta completa\n\n")
        XCTAssertEqual(session.recap, "Resumen del archivo")
        XCTAssertEqual(session.agentStatus?.text, "Churned for 1m 2s", "Status still comes from the screen.")
    }

    func testEditsShowTheirNumberedLinesLikeClaudesTerminal() {
        var renderer = TranscriptRenderer()
        renderer.consume(assistant([["type": "tool_use", "id": "e", "name": "Edit", "input": ["file_path": "/Users/me/app/Sources/Notch.swift"]]]))
        renderer.consume(line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "e", "content": "The file has been updated."]]],
                               "toolUseResult": ["filePath": "/Users/me/app/Sources/Notch.swift", "structuredPatch": [
                                   ["oldStart": 98, "oldLines": 3, "newStart": 98, "newLines": 4, "lines": [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4", " }"]],
                                   ["oldStart": 120, "oldLines": 1, "newStart": 121, "newLines": 1, "lines": ["-old()", "+new()", "\\ No newline at end of file"]],
                               ]]]))
        XCTAssertEqual(renderer.text, """
        ⏺ Edit(Sources/Notch.swift)
          ⎿  Actualizado Sources/Notch.swift (+3 -2)
               98   let a = 1
               99 - let b = 2
               99 + let b = 3
              100 + let c = 4
              101   }
                  … 
              120 - old()
              121 + new()


        """)
    }

    func testANewFileShowsItsFirstLines() {
        var renderer = TranscriptRenderer()
        renderer.cwd = "/Users/me/app"
        let content = (1...15).map { "línea \($0)" }.joined(separator: "\n") + "\n"
        renderer.consume(line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "w", "content": "File created"]]],
                               "toolUseResult": ["type": "create", "filePath": "/Users/me/app/README.md", "content": content, "structuredPatch": []]]))
        let lines = renderer.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "  ⎿  Creado README.md (15 líneas)")
        XCTAssertEqual(lines[1], "       1   línea 1")
        XCTAssertEqual(lines[12], "      12   línea 12")
        XCTAssertEqual(lines[13], "         … +3 líneas")
        var failed = TranscriptRenderer()
        failed.consume(line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "x", "is_error": true, "content": "String not found"]]],
                             "toolUseResult": ["filePath": "/a.swift", "structuredPatch": [["oldStart": 1, "newStart": 1, "lines": ["+x"]]]]]))
        XCTAssertTrue(failed.text.hasPrefix("  ⎿  Error: String not found"), "A failed edit shows its error, not a diff.")
    }
}
