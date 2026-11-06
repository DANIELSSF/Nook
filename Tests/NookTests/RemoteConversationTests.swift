import XCTest
@testable import Nook

/// The conversation on the phone: lines already classified as the island dresses them, sent as an append while the text grows and
/// as a reset (a new epoch) when it is another text, with paging back (docs/REMOTE_API.md, "Conversation lines").
final class RemoteConversationTests: XCTestCase {
    /// Claude's transcript as the island shows it, as `TranscriptRenderer` writes it.
    private let transcript = [
        "> Revisa por qué falla el build 🙂",
        "  y dime qué cambió",
        "",
        "⏺ Voy a mirar **el log** y `swift test` en [la guía](https://example.com/guía).",
        "",
        "⏺ Read(Sources/Nook/Pet.swift)",
        "  ⎿  Read 64 lines",
        "",
        "⏺ Update(Sources/Notch.swift)",
        "  ⎿  Actualizado Sources/Notch.swift (+2 -1)",
        "       96   struct NotchGeometry {",
        "       97 -     static let expandedWidth: CGFloat = 572",
        "       97 +     static let expandedWidth: CGFloat = 600",
        "       …",
        "",
        "⏺ Así queda:",
        "  ```swift",
        "  let a = \"hola\" // 🙂",
        "  ```",
    ].joined(separator: "\n")

    private func lines(_ text: String, transcript: Bool = true, range: Range<Int>? = nil) throws -> [[String: Any]] {
        let ns = text as NSString
        let starts = RemoteLines.starts(of: ns, from: 0)
        let data = Data(RemoteLines.json(ns, starts: starts, range: range ?? 0..<starts.count, transcript: transcript))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// The UTF-16 slice `range` ([from, to]) of `text`, as JavaScript's `slice` would cut it.
    private func slice(_ text: Any?, _ range: Any?) -> String? {
        guard let text = text as? String, let bounds = range as? [Int], bounds.count == 2 else { return nil }
        return (text as NSString).substring(with: NSRange(location: bounds[0], length: bounds[1] - bounds[0]))
    }

    private func span(_ entry: [String: Any], in line: [String: Any]) -> String? {
        slice(line["text"], [entry["from"] as! Int, entry["to"] as! Int])
    }

    // MARK: Lines

    func testEveryLineCarriesItsRoleAsTheIslandClassifiesIt() throws {
        let found = try lines(transcript)
        XCTAssertEqual(found.count, 19)
        XCTAssertEqual(found.map { $0["i"] as? Int }, Array(0..<19))
        let roles = found.map { $0["role"] as? String ?? "" }
        XCTAssertEqual(roles, ["user", "user", "plain", "assistant", "plain", "tool", "toolOutput", "plain", "tool", "toolOutput", "toolOutput", "toolOutput", "toolOutput",
                               "toolOutput", "plain", "assistant", "assistant", "assistant", "assistant"])
        let expected = TranscriptClassifier.roles(of: transcript).map(\.rawValue)
        XCTAssertEqual(roles, expected, "The same roles the island's styler gives.")
        XCTAssertEqual(found[0]["head"] as? Bool, true, "The first line of the user's message opens its block…")
        XCTAssertEqual(found[1]["head"] as? Bool, false, "…its wrapped line does not.")
        XCTAssertEqual(found[6]["head"] as? Bool, false, "A result belongs to its call's block.")
        XCTAssertEqual(slice(found[0]["text"], found[0]["marker"]), ">")
        XCTAssertEqual(slice(found[5]["text"], found[5]["marker"]), "⏺")
        XCTAssertEqual(slice(found[5]["text"], found[5]["name"]), "Read")
        XCTAssertEqual(slice(found[6]["text"], found[6]["marker"]), "⎿")
        XCTAssertTrue(found[2]["marker"] is NSNull, "Nothing absent is left out: it is null.")
        XCTAssertEqual(found[0]["text"] as? String, "> Revisa por qué falla el build 🙂")
    }

    func testAReplysMarkdownIsReadInUTF16Units() throws {
        let line = try lines(transcript)[3]
        let md = try XCTUnwrap(line["md"] as? [[String: Any]])
        let bold = try XCTUnwrap(md.first { $0["style"] as? String == "bold" })
        XCTAssertEqual(span(bold, in: line), "el log")
        let code = try XCTUnwrap(md.first { $0["style"] as? String == "code" })
        XCTAssertEqual(span(code, in: line), "swift test")
        let link = try XCTUnwrap(md.first { $0["style"] as? String == "link" })
        XCTAssertEqual(span(link, in: line), "la guía")
        XCTAssertEqual(link["url"] as? String, "https://example.com/guía")
        let hidden = md.filter { $0["style"] as? String == "hidden" }.compactMap { span($0, in: line) }
        XCTAssertTrue(hidden.contains("**") && hidden.contains("`"), "The marks the island hides are named, so the page hides them too: \(hidden)")
        XCTAssertTrue((try lines("⏺ 🙂🙂 **sí**")[0]["md"] as? [[String: Any]])!.contains { $0["style"] as? String == "bold" && $0["from"] as? Int == 9 },
                      "An emoji is two units, as JavaScript counts: ⏺ (1) space (1) 🙂🙂 (4) space (1) ** (2).")
        XCTAssertEqual((try lines(transcript)[5]["md"] as? [Any])?.count, 0, "A tool call has no Markdown.")
    }

    func testAChangeCarriesItsSummaryRowsAndColouredCode() throws {
        let found = try lines(transcript)
        let summary = try XCTUnwrap(found[9]["detail"] as? [String: Any])
        XCTAssertEqual(summary["kind"] as? String, "summary")
        XCTAssertEqual(summary["path"] as? String, "Sources/Notch.swift")
        XCTAssertEqual(summary["added"] as? Int, 2)
        XCTAssertEqual(summary["removed"] as? Int, 1)
        XCTAssertEqual(slice(found[9]["text"], summary["pathRange"]), "Sources/Notch.swift")
        let context = try XCTUnwrap(found[10]["detail"] as? [String: Any])
        XCTAssertEqual(context["kind"] as? String, "row")
        XCTAssertEqual(context["row"] as? String, "context")
        XCTAssertEqual(context["number"] as? Int, 96)
        XCTAssertEqual(slice(found[10]["text"], context["code"]), "struct NotchGeometry {")
        let removed = try XCTUnwrap(found[11]["detail"] as? [String: Any])
        XCTAssertEqual(removed["row"] as? String, "removed")
        XCTAssertEqual(removed["number"] as? Int, 97)
        XCTAssertEqual(slice(found[11]["text"], removed["mark"]), "-")
        XCTAssertEqual((found[12]["detail"] as? [String: Any])?["row"] as? String, "added")
        XCTAssertEqual((found[13]["detail"] as? [String: Any])?["row"] as? String, "gap")
        XCTAssertTrue((found[13]["detail"] as? [String: Any])?["number"] is NSNull)
        let spans = try XCTUnwrap(found[12]["spans"] as? [[String: Any]])
        XCTAssertEqual(spans.first { span($0, in: found[12]) == "static" }?["style"] as? String, "keyword")
        XCTAssertEqual(spans.first { span($0, in: found[12]) == "600" }?["style"] as? String, "number")
        XCTAssertEqual(spans.first { span($0, in: found[12]) == "CGFloat" }?["style"] as? String, "type")
    }

    func testFencedCodeIsColouredByItsLanguage() throws {
        let found = try lines(transcript)
        XCTAssertEqual((found[16]["detail"] as? [String: Any])?["kind"] as? String, "fence")
        let code = try XCTUnwrap(found[17]["detail"] as? [String: Any])
        XCTAssertEqual(code["kind"] as? String, "code")
        XCTAssertEqual(code["language"] as? String, "swift")
        let spans = try XCTUnwrap(found[17]["spans"] as? [[String: Any]])
        XCTAssertEqual(spans.first { span($0, in: found[17]) == "let" }?["style"] as? String, "keyword")
        XCTAssertEqual(spans.first { span($0, in: found[17]) == "\"hola\"" }?["style"] as? String, "string")
        XCTAssertEqual(spans.first { span($0, in: found[17]) == "// 🙂" }?["style"] as? String, "comment", "The comment's range takes the emoji's two units.")
        XCTAssertEqual((found[17]["md"] as? [Any])?.count, 0, "Code is never Markdown.")
        let verbatim = try lines("⏺ Mira:\n  ```klingon\n  qaStaH nuq?\n  ```")
        XCTAssertEqual((verbatim[2]["detail"] as? [String: Any])?["kind"] as? String, "verbatim", "A language the highlighter doesn't know keeps its plain look.")
    }

    func testPlainTerminalTextIsNeverClassified() throws {
        let found = try lines("$ ls\n> no es Claude\n⏺ tampoco", transcript: false)
        XCTAssertEqual(found.map { $0["role"] as? String }, ["plain", "plain", "plain"])
        XCTAssertTrue(found.allSatisfy { $0["marker"] is NSNull && ($0["spans"] as? [Any])?.isEmpty == true && $0["head"] as? Bool == false })
        XCTAssertEqual(found[1]["text"] as? String, "> no es Claude")
    }

    func testAWindowClassifiesItsLinesAsTheWholeTextWould() throws {
        let whole = try lines(transcript)
        let window = try lines(transcript, range: 10..<13)
        XCTAssertEqual(window.map { $0["i"] as? Int }, [10, 11, 12])
        for (part, full) in zip(window, whole[10..<13]) {
            XCTAssertEqual(part["role"] as? String, full["role"] as? String)
            XCTAssertEqual((part["detail"] as? [String: Any])?["row"] as? String, (full["detail"] as? [String: Any])?["row"] as? String)
            XCTAssertEqual((part["spans"] as? [Any])?.count, (full["spans"] as? [Any])?.count)
        }
    }

    func testLineStartsCountLinesAsTheClassifierDoes() {
        XCTAssertEqual(RemoteLines.starts(of: "", from: 0), [])
        XCTAssertEqual(RemoteLines.starts(of: "a\nb", from: 0), [0, 2])
        XCTAssertEqual(RemoteLines.starts(of: "a\nb\n", from: 0), [0, 2], "A final line break starts no line.")
        XCTAssertEqual(RemoteLines.starts(of: "a\n\nb", from: 0), [0, 2, 3])
        XCTAssertEqual(RemoteLines.starts(of: "a\nb\nc", from: 2), [2, 4])
    }

    // MARK: Tracker

    private func source(_ text: String, tab: String = "t1", view: String = "", strip: Bool = false, transcript: Bool = true) -> RemoteConversationSource {
        RemoteConversationSource(tab: tab, text: text, transcript: transcript, view: view, stripPrompt: strip)
    }

    func testAGrowingConversationIsSentFromItsFirstChangedLine() {
        let tracker = RemoteConversationTracker()
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hol")), .reset, "The first text is a reset.")
        let epoch = tracker.epoch
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hola, ¿qué")), .append(from: 2), "The last line grew: it goes again, from itself.")
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hola, ¿qué tal?\n\n> bien")), .append(from: 2))
        XCTAssertEqual(tracker.count, 5)
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hola, ¿qué tal?\n\n> bien")), .none, "Nothing new.")
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hola, ¿qué tal?\n\n> bien\n")), .none, "A final line break adds no line.")
        XCTAssertEqual(tracker.update(source("> hola\n\n⏺ Hola, ¿qué tal?\n\n> bien\n⏺ ok")), .append(from: 5), "A new line after a final break: the old ones stand.")
        XCTAssertEqual(tracker.epoch, epoch, "Appends keep the epoch: every line before them is as the phone has it.")
    }

    func testATextChangedInTheMiddleIsSentFromThere() {
        let tracker = RemoteConversationTracker()
        _ = tracker.update(source("uno\ndos\ntres\ncuatro"))
        XCTAssertEqual(tracker.update(source("uno\nDOS\ntres\ncuatro")), .append(from: 1))
        XCTAssertEqual(tracker.update(source("uno\nDOS")), .append(from: 2), "Lines that went: the phone drops what it has from there.")
        XCTAssertEqual(tracker.count, 2)
        XCTAssertEqual(tracker.update(source("uno\nDO")), .append(from: 1), "A line that shrank goes again.")
    }

    func testAnotherTabOrAnAgentsConversationIsAResetWithANewEpoch() {
        let tracker = RemoteConversationTracker()
        _ = tracker.update(source("> hola"))
        let first = tracker.epoch
        XCTAssertEqual(tracker.update(source("> hola", tab: "t2")), .reset, "The same words in another tab are another conversation.")
        XCTAssertGreaterThan(tracker.epoch, first)
        let second = tracker.epoch
        XCTAssertEqual(tracker.update(source("⏺ Read(a)", tab: "t2", view: "toolu_1")), .reset, "An agent's own conversation.")
        XCTAssertGreaterThan(tracker.epoch, second)
        XCTAssertEqual(tracker.update(source("⏺ Read(a)", tab: "t2", view: "toolu_1", transcript: false)), .reset, "Drawn another way.")
    }

    func testTooBigAChangeIsAResetInsteadOfAHugeAppend() {
        let tracker = RemoteConversationTracker()
        _ = tracker.update(source("> hola"))
        let epoch = tracker.epoch
        let huge = (0..<1500).map { "⏺ línea \($0)" }.joined(separator: "\n")
        XCTAssertEqual(tracker.update(source(huge)), .reset)
        XCTAssertGreaterThan(tracker.epoch, epoch)
        XCTAssertEqual(tracker.count, 1500)
    }

    func testAQuestionsCardLeavesTheEndOfTheTextAsOnTheIsland() {
        let tracker = RemoteConversationTracker()
        let screen = ["⏺ Voy a borrar la carpeta.", "", "⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                      " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                      "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
        XCTAssertNotNil(AgentPrompt.parse(screen))
        _ = tracker.update(source(screen, strip: true))
        XCTAssertEqual(tracker.text as String, AgentPrompt.withoutPrompt(screen))
        XCTAssertFalse((tracker.text as String).contains("Do you want to proceed?"), "The card shows the question; the conversation ends at what it is about.")
        let answered = ["⏺ Voy a borrar la carpeta.", "", "⏺ Bash(rm -rf build)", "  ⎿  (No content)"].joined(separator: "\n")
        XCTAssertEqual(tracker.update(source(answered)), .append(from: 3), "The card went: the text goes on from where it was cut.")
    }

    func testUnchangedLinesAreCountedByWhereTheyEnd() {
        func count(_ old: String, _ new: String) -> Int {
            RemoteConversationTracker.unchangedLines(old: old as NSString, starts: RemoteLines.starts(of: old as NSString, from: 0), new: new as NSString)
        }
        XCTAssertEqual(count("a\nb", "a\nb"), 2)
        XCTAssertEqual(count("a\nb", "a\nbc"), 1)
        XCTAssertEqual(count("a\nb", "a\nb\nc"), 2)
        XCTAssertEqual(count("a\nb\n", "a\nb\nc"), 2)
        XCTAssertEqual(count("a\nb", "a"), 1)
        XCTAssertEqual(count("a\nb", "x\nb"), 0)
        XCTAssertEqual(count("", "a"), 0)
        XCTAssertEqual(count("🙂\n🙂", "🙂\n🙃"), 1, "A change inside an emoji's two units counts as its line's.")
    }

    // MARK: Broadcaster

    private func frame(_ text: String, tab: String = "t1", notice: String? = nil, strip: Bool = false) -> RemoteFrame {
        RemoteFrame(head: [("v", .int(1)), ("selected", .string(tab))], detail: [("id", .string(tab))], notice: notice,
                    conversation: source(text, tab: tab, strip: strip))
    }

    private func settle(_ broadcaster: RemoteBroadcaster) { broadcaster.queue.sync {} }

    func testAStreamGetsTheStateAndTheLastWindowFirst() throws {
        let broadcaster = RemoteBroadcaster()
        let sink = RecordingSink()
        broadcaster.add(sink)
        let long = (0..<900).map { "⏺ línea \($0)" }.joined(separator: "\n")
        broadcaster.publish(frame(long))
        settle(broadcaster)
        XCTAssertEqual(sink.events.map(\.name), ["state", "conversation"], "The state first, then the conversation.")
        let state = try XCTUnwrap(sink.named("state").first)
        let update = try XCTUnwrap(sink.named("conversation").first)
        XCTAssertEqual((state["detail"] as? [String: Any])?["conversationEpoch"] as? Int, update["epoch"] as? Int, "The state names the epoch the lines have.")
        XCTAssertEqual(update["reset"] as? Bool, true)
        XCTAssertEqual(update["tab"] as? String, "t1")
        XCTAssertEqual(update["from"] as? Int, 300, "The last 600 lines.")
        XCTAssertEqual(update["hasEarlier"] as? Bool, true)
        XCTAssertEqual(update["transcript"] as? Bool, true)
        let lines = try XCTUnwrap(update["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 600)
        XCTAssertEqual(lines.first?["i"] as? Int, 300)
        XCTAssertEqual(lines.last?["text"] as? String, "⏺ línea 899")
    }

    func testOnlyWhatChangedIsSent() throws {
        let broadcaster = RemoteBroadcaster()
        let sink = RecordingSink()
        broadcaster.add(sink)
        broadcaster.publish(frame("> hola\n\n⏺ Hol"))
        broadcaster.publish(frame("> hola\n\n⏺ Hol"))
        settle(broadcaster)
        XCTAssertEqual(sink.events.map(\.name), ["state", "conversation"], "The same picture twice sends nothing more.")
        broadcaster.publish(frame("> hola\n\n⏺ Hola, ¿qué tal?"))
        settle(broadcaster)
        XCTAssertEqual(sink.events.map(\.name), ["state", "conversation", "conversation"], "The state is unchanged: only the lines go.")
        let append = try XCTUnwrap(sink.named("conversation").last)
        XCTAssertEqual(append["reset"] as? Bool, false)
        XCTAssertEqual(append["from"] as? Int, 2)
        XCTAssertEqual((append["lines"] as? [[String: Any]])?.map { $0["text"] as? String }, ["⏺ Hola, ¿qué tal?"])
        broadcaster.publish(frame("> hola\n\n⏺ Hola, ¿qué tal?", notice: "Diagnóstico copiado."))
        settle(broadcaster)
        XCTAssertEqual(sink.events.last?.name, "state")
        XCTAssertEqual(sink.named("state").last?["notice"] as? String, "Diagnóstico copiado.")
    }

    func testANewStreamStartsWithTheWholeWindowWhileOthersGetAppends() throws {
        let broadcaster = RemoteBroadcaster()
        let first = RecordingSink(), second = RecordingSink()
        broadcaster.add(first)
        broadcaster.publish(frame("> hola"))
        broadcaster.add(second)
        broadcaster.publish(frame("> hola\n⏺ buenas"))
        settle(broadcaster)
        XCTAssertEqual(first.named("conversation").map { $0["reset"] as? Bool }, [true, false])
        XCTAssertEqual(second.named("conversation").map { $0["reset"] as? Bool }, [true], "A newcomer gets the window, not the append.")
        XCTAssertEqual(second.named("state").count, 1, "And the state, though it did not change.")
        XCTAssertEqual((second.named("conversation").first?["lines"] as? [Any])?.count, 2)
    }

    func testAChangeBeforeAStreamsWindowGivesItTheWindowAgainInTheSameEpoch() throws {
        let broadcaster = RemoteBroadcaster()
        let sink = RecordingSink()
        broadcaster.add(sink)
        var lines = (0..<900).map { "⏺ línea \($0)" }
        broadcaster.publish(frame(lines.joined(separator: "\n")))
        lines[100] = "⏺ línea cambiada"
        broadcaster.publish(frame(lines.joined(separator: "\n")))
        settle(broadcaster)
        let updates = sink.named("conversation")
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[1]["reset"] as? Bool, true, "Line 100 is before the 300 the phone starts at: no append could fill the gap.")
        XCTAssertEqual(updates[1]["from"] as? Int, 300)
        XCTAssertEqual(updates[1]["epoch"] as? Int, updates[0]["epoch"] as? Int, "The lines keep their numbers: paging stays valid.")
    }

    func testSwitchingTabsResetsEveryStream() throws {
        let broadcaster = RemoteBroadcaster()
        let sink = RecordingSink()
        broadcaster.add(sink)
        broadcaster.publish(frame("> hola", tab: "t1"))
        broadcaster.publish(frame("> otra pestaña", tab: "t2"))
        settle(broadcaster)
        let updates = sink.named("conversation")
        XCTAssertEqual(updates.map { $0["tab"] as? String }, ["t1", "t2"])
        XCTAssertEqual(updates.map { $0["reset"] as? Bool }, [true, true])
        XCTAssertNotEqual(updates[0]["epoch"] as? Int, updates[1]["epoch"] as? Int)
        XCTAssertEqual(sink.named("state").count, 2, "The selected tab changed.")
    }

    func testPagingGivesEarlierLinesAndRefusesAnotherEpochOrTab() throws {
        let broadcaster = RemoteBroadcaster()
        let text = (0..<900).map { "⏺ línea \($0)" }.joined(separator: "\n")
        var page: RemoteBroadcaster.Page?
        let done = expectation(description: "page")
        broadcaster.page(frame(text), tab: "t1", before: 300, limit: 400, epoch: nil) { page = $0; done.fulfill() }
        wait(for: [done], timeout: 3)
        guard case .lines(let json)? = page, let body = try JSONSerialization.jsonObject(with: json.data) as? [String: Any] else { return XCTFail("\(String(describing: page))") }
        let lines = try XCTUnwrap(body["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 300, "Only what is before line 300.")
        XCTAssertEqual(lines.first?["i"] as? Int, 0)
        XCTAssertEqual(lines.last?["i"] as? Int, 299)
        XCTAssertEqual(body["hasEarlier"] as? Bool, false)
        let epoch = try XCTUnwrap(body["epoch"] as? Int)

        let stale = expectation(description: "stale")
        broadcaster.page(frame(text), tab: "t1", before: 300, limit: 400, epoch: epoch + 7) { page = $0; stale.fulfill() }
        wait(for: [stale], timeout: 3)
        guard case .moved(let current)? = page else { return XCTFail("Another epoch is refused.") }
        XCTAssertEqual(current, epoch)

        let other = expectation(description: "other tab")
        broadcaster.page(frame(text), tab: "t9", before: 300, limit: 400, epoch: nil) { page = $0; other.fulfill() }
        wait(for: [other], timeout: 3)
        guard case .moved? = page else { return XCTFail("Another tab's conversation is not the one followed.") }

        let middle = expectation(description: "middle")
        broadcaster.page(frame(text), tab: "t1", before: 700, limit: 100, epoch: epoch) { page = $0; middle.fulfill() }
        wait(for: [middle], timeout: 3)
        guard case .lines(let window)? = page, let part = try JSONSerialization.jsonObject(with: window.data) as? [String: Any] else { return XCTFail() }
        XCTAssertEqual((part["lines"] as? [[String: Any]])?.map { $0["i"] as? Int }.first, 600)
        XCTAssertEqual(part["hasEarlier"] as? Bool, true)
    }

    func testAStreamThatClosesIsForgottenAndTheOldestGivesWayBeyondTheLimit() {
        let broadcaster = RemoteBroadcaster()
        var counts: [Int] = []
        let lock = NSLock()
        broadcaster.onCount = { lock.lock(); counts.append($0); lock.unlock() }
        let sinks = (0...RemoteBroadcaster.maxClients).map { _ in RecordingSink() }
        sinks.forEach(broadcaster.add)
        settle(broadcaster)
        XCTAssertTrue(sinks[0].closed, "One more than the limit closes the oldest.")
        XCTAssertEqual(broadcaster.count, RemoteBroadcaster.maxClients)
        sinks[1].close()
        settle(broadcaster)
        XCTAssertEqual(broadcaster.count, RemoteBroadcaster.maxClients - 1)
        broadcaster.closeAll()
        settle(broadcaster)
        XCTAssertEqual(broadcaster.count, 0)
        XCTAssertTrue(sinks.allSatisfy(\.closed))
        lock.lock(); XCTAssertEqual(counts.last, 0); lock.unlock()
    }
}
