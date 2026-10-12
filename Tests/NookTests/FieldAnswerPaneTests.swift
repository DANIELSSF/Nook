import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The composer answering a dialog's text field ("Type something."), as the pane drives it: a real `SessionPane` in an offscreen window that never becomes key,
/// its field fed key events by calling the text view directly (nothing is posted to the system, nothing takes the keyboard), and every transport a recorder. What
/// reaches the terminal is what the tests read: the scripts the bridge would run and the keys it would post. Nothing here reaches Terminal, a real session or the
/// user's delivery log.
@MainActor
final class FieldAnswerPaneTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)
    /// The screen never shows the answer, and the wait for it lasts long enough for a test to look at the field while the answer is on its way.
    private let unseen = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.9, hold: 0.06, settle: 0.25)

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    /// One question with one answer, its highlight on the first option.
    private let question = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                            "❯ 1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                            "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "",
                            "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same question with the highlight already on the field, still empty.
    private var onTheField: [String] {
        question.map { $0 == "❯ 1. PostgreSQL" ? "  1. PostgreSQL" : $0 == "  3. Type something." ? "❯ 3. Type something." : $0 }
    }
    /// Claude took the answer: the dialog closed, its record of the answer in the chat and its box back.
    private func answered(_ answer: String) -> String {
        lines(["⏺ Antes de seguir necesito una decisión.", "", "⏺ User answered Claude's questions:", "  ⎿  · Which database should we use? → \(answer)", "",
               "✻ Pondering… (2s · esc to interrupt)", "", rule, "❯ ", rule])
    }
    /// A question that takes several answers: the field sits behind its own box.
    private let platforms = ["⏺ Antes de lanzar necesito saber para qué plataformas.", "", "☐ Platforms", "", "Which platforms should the release support?", "",
                             "❯ 1. [ ] macOS", "     Apple Silicon and Intel", "  2. [✔] iOS", "  3. [ ] Linux", "  4. [ ] Type something", "",
                             "Enter to select · ↑/↓ to navigate · Esc to cancel"]
    /// The same once Nook wrote the user's text into its field (it reads like a free-text option still): the dialog stays, the field holds the text, ticked, with the highlight.
    private var platformsFilled: [String] {
        platforms.map { $0 == "❯ 1. [ ] macOS" ? "  1. [ ] macOS" : $0 == "  4. [ ] Type something" ? "❯ 4. [✔] Otro proveedor" : $0 }
    }
    /// A permission request, which has no text field.
    private let permission = ["⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
                              " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
                              "   3. No, and tell Claude what to do differently (esc)"]

    private func tab(_ text: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys093", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
    }

    private final class Escapes: ObservableObject { var count = 0 }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var escapes: Escapes
        var draft: String
        var promptState: SessionPane.PromptCardState
        var body: some View {
            SessionPane(model: model, session: session, draft: draft, promptState: promptState)
                .frame(width: 572, height: 204).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                .onExitCommand { escapes.count += 1 }
        }
    }

    /// What the bridge would have run and posted, from any thread.
    private final class Recorder {
        private let lock = NSLock()
        private var _scripts: [String] = [], _keys: [TerminalKey] = []
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
        var keys: [TerminalKey] { lock.lock(); defer { lock.unlock() }; return _keys }
        func run(_ script: String) { lock.lock(); _scripts.append(script); lock.unlock() }
        func post(_ key: TerminalKey) { lock.lock(); _keys.append(key); lock.unlock() }
    }

    /// A pane over a Terminal tab showing `screen`, with the field chosen on its card (or not), whose transports record: the scripts it would run, the keys it would
    /// post, its journal, and a screen that changes to `after` once a script wrote the answer.
    @MainActor private final class Rig {
        let model: AppModel
        let session: TerminalSession
        let escapes = Escapes()
        let window: NSWindow
        let host: NSHostingView<Island>
        private let recorder = Recorder()
        var scripts: [String] { recorder.scripts }
        var keys: [TerminalKey] { recorder.keys }

        init(_ test: FieldAnswerPaneTests, screen: [String], after: @escaping (String) -> String, state: SessionPane.PromptCardState = .typing, choosesTheField: Bool = true,
             draft: String = "", filledOption: Int? = nil) throws {
            let defaults = UserDefaults(suiteName: "nook-field-pane-" + UUID().uuidString)!
            model = AppModel(receivesSignals: false, defaults: defaults)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = test.timing
            bridge.reader = { _ in [] }
            let recorder = self.recorder
            bridge.runScript = { script in recorder.run(script) }
            bridge.postKey = { key, _ in recorder.post(key) }
            bridge.fieldJournal = { _ in }
            let before = test.lines(screen)
            bridge.screenReader = { _, _ in
                let written = recorder.scripts.first { $0.contains("[200~") }
                return written.map(after) ?? before
            }
            session = TerminalSession(tab: test.tab(before), backend: .bundled, bridge: bridge)
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true; model.islandContentVisible = true
            if choosesTheField, let dialog = session.prompt, let field = dialog.options.firstIndex(where: { $0.input == .inline }) { session.chooseField(field, of: dialog) }
            // A field Nook already wrote into, which the dialog keeps on screen (a question with several answers).
            if let filledOption, let dialog = session.prompt { session.noteFilledField(filledOption, of: dialog) }
            // What the tab holds as its draft is what the pane has typed (the pane copies the field to it as it changes).
            session.draft = draft
            host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes, draft: draft, promptState: state))
            host.frame = NSRect(x: 0, y: 0, width: 572, height: 204)
            // Borderless: it can never become the key window, so nothing here can take the keyboard from whoever has it.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: host.frame.width, height: host.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            // Far off any screen and never key: it is ordered in (a window that is not on screen takes no clicks) without ever being seen or taking the keyboard.
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            Self.settle(0.6)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }

        static func settle(_ seconds: TimeInterval = 0.25) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        /// Runs the main loop until `condition` holds (or `seconds` pass).
        func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            Self.settle(0.1)
        }

        /// The composer's text view, when the composer is on screen (the card stands in its place otherwise).
        var field: ComposerTextView? { Self.find(ComposerFieldView.self, in: host)?.textView }

        enum Key { case enter, escape
            var code: UInt16 { self == .enter ? 36 : 53 }
            var characters: String { self == .enter ? "\r" : "\u{1b}" }
        }

        /// A key given to the field the way the window would, without a window that can have the keyboard.
        func press(_ key: Key, file: StaticString = #filePath, line: UInt = #line) throws {
            let view = try XCTUnwrap(field, "The composer is not on screen", file: file, line: line)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code))
            view.keyDown(with: event)
            Self.settle()
        }
    }

    private func assertNothingReachedTheTerminal(_ rig: Rig, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.scripts, [], message, file: file, line: line)
        XCTAssertEqual(rig.keys, [], message, file: file, line: line)
    }

    // MARK: The composer after the click

    /// The click on «Type something.» left the field chosen and the card out of the way: the composer is the answer's, and writing in it sends nothing by itself.
    func testTheComposerAnswersTheFieldChosenOnTheCard() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") })
        let field = try XCTUnwrap(rig.field, "The card gave the composer its place.")
        XCTAssertEqual(field.placeholder, FieldAnswerCopy.placeholder)
        XCTAssertEqual(field.accessibilityLabel(), "Respuesta", "What is written there is an answer, not a message.")
        XCTAssertNotNil(rig.model.fieldAnswer(for: rig.session))
        assertNothingReachedTheTerminal(rig, "Choosing the field presses nothing.")
    }

    /// Enter sends what is written into that field: the arrows to it, the text between paste marks and the Return, in one write; the field empties at once, no
    /// message is queued for the conversation, and the field stops being a target once the dialog took the answer.
    func testEnterSendsTheTextToTheFieldInOneWriteAndEmptiesTheField() throws {
        let answer = "Usa MongoDB con réplica"
        let rig = try Rig(self, screen: question, after: { _ in self.answered(answer) }, draft: answer)
        try rig.press(.enter)
        XCTAssertEqual(rig.field?.string, "", "The field empties at once, as it does for any send.")
        rig.wait { rig.scripts.count == 1 && rig.session.chosenField == nil }
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B" & (character id 27) & "[B" & (character id 27) & "[200~" & "Usa MongoDB con réplica" & (character id 27) & "[201~") in t"#), script)
        XCTAssertEqual(rig.scripts.count, 1, "Arrows, text and Terminal's Return in one script.")
        XCTAssertEqual(rig.keys, [], "No key event: Terminal never comes forward.")
        XCTAssertNil(rig.model.notice)
        XCTAssertNil(rig.session.chosenField, "Answered: the field is no target any more.")
        XCTAssertNil(rig.session.pendingMessage, "Claude records its own answer: no bubble for it in the conversation.")
        XCTAssertEqual(rig.session.sentHistory.last, answer, "↑ brings it back, as any message.")
    }

    /// The text is sent as it is written, without the line breaks at its ends and with nothing attached: the images the user attached stay in the composer.
    func testTheAttachedImagesStayForTheNextMessage() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("sí") }, draft: "\nsí\n")
        MessageAttachments.shared.set(["/tmp/nook-field-answer-picture.png"], for: rig.session.id)
        defer { MessageAttachments.shared.set([], for: rig.session.id) }
        try rig.press(.enter)
        rig.wait { rig.scripts.count == 1 }
        XCTAssertTrue(rig.scripts.first?.contains(#"& "[200~" & "sí" & (character id 27) & "[201~""#) == true, rig.scripts.first ?? "no script")
        XCTAssertEqual(MessageAttachments.shared.paths(for: rig.session.id), ["/tmp/nook-field-answer-picture.png"], "An answer is a line of text: the picture is for a message.")
    }

    /// Enter on an empty field would cancel Claude's whole question: it sends nothing, and the composer stays the answer's.
    func testAnEmptyAnswerSendsNothing() throws {
        for draft in ["", "   ", "\n \n"] {
            let rig = try Rig(self, screen: question, after: { _ in self.answered("x") }, draft: draft)
            try rig.press(.enter)
            rig.wait(0.5) { false }
            assertNothingReachedTheTerminal(rig, "«\(draft)» is no answer.")
            XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta", "Still the answer's composer.")
            XCTAssertNotNil(rig.session.chosenField)
            XCTAssertFalse(rig.session.sending)
        }
    }

    /// The screen never shows the answer in the field: nothing more is pressed, the model says why, the text is back in the field and the composer is still the
    /// answer's, so it can be sent again.
    func testAFailedAnswerGivesTheTextBackAndTheModelSaysWhy() throws {
        let answer = "Usa MongoDB con réplica"
        let rig = try Rig(self, screen: question, after: { _ in self.lines(self.question) }, draft: answer)
        rig.model.terminalBridge.fieldTiming = unseen
        try rig.press(.enter)
        XCTAssertEqual(rig.field?.string, "", "It left the field while it went…")
        rig.wait { rig.field?.string == answer }
        XCTAssertEqual(rig.field?.string, answer, "…and comes back when it fails.")
        XCTAssertEqual(rig.session.draft, answer)
        // A Terminal tab's write carried Terminal's own Return: the notice doesn't claim that no Enter went.
        XCTAssertEqual(rig.model.notice, "Tu respuesta no apareció en el campo de Claude y la pregunta sigue abierta. Revisa la terminal antes de enviarla de nuevo.")
        XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta")
        XCTAssertNotNil(rig.session.chosenField, "The field is still the target: it can be tried again.")
        XCTAssertEqual(rig.scripts.count, 1, "The write, and no Enter after it.")
    }

    // MARK: Back to the options

    /// Esc is the way back: the card returns, the field is forgotten, what was written stays, and nothing is sent: not an Esc to Claude, which would cancel the
    /// question, nor anything for the island, which stays open.
    func testEscGoesBackToTheOptionsWithoutSendingAnythingOrPuttingTheIslandAway() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") }, draft: "Usa Mon")
        XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta")
        try rig.press(.escape)
        rig.wait { rig.field == nil }
        XCTAssertNil(rig.field, "The card is back in the composer's place.")
        XCTAssertNil(rig.session.chosenField, "A message is no answer to the field any more.")
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
        XCTAssertEqual(rig.session.draft, "Usa Mon", "What was written is kept.")
        assertNothingReachedTheTerminal(rig, "Going back is Nook's own: nothing for the dialog.")
        XCTAssertEqual(rig.escapes.count, 0, "The key was taken: the island stays.")
    }

    /// The same way back when the field was highlighted at the terminal and the card folded away: the card comes back.
    func testEscFromAFieldTheTerminalAlreadyHadBringsTheCardBack() throws {
        let rig = try Rig(self, screen: onTheField, after: { _ in self.answered("x") }, state: .hidden, choosesTheField: false)
        XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta", "The highlighted field is the target without any click.")
        try rig.press(.escape)
        rig.wait { rig.field == nil }
        XCTAssertNil(rig.field)
        assertNothingReachedTheTerminal(rig, "Nothing is sent to go back.")
    }

    // MARK: The clicks

    /// A click as the window would deliver it, to the offscreen window that can never be key; `y` is measured from the top of the pane.
    private func click(_ rig: Rig, x: CGFloat, y: CGFloat) throws {
        let point = NSPoint(x: x, y: 204 - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            rig.window.sendEvent(event)
            Rig.settle(0.1)
        }
        Rig.settle(0.3)
    }

    /// The whole way: the card's «Type something.» row (nothing pressed, the composer comes back as the answer's), «‹ Opciones» in its bar (the card comes back, the field is
    /// forgotten, nothing sent), and the row again, with what was written still in the field.
    func testClickingTheFieldOnTheCardBringsTheComposerAndTheBarBringsTheCardBack() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") }, state: .options, choosesTheField: false)
        XCTAssertNil(rig.field, "The card has the composer's place.")
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
        // The third option's row, in the Normal island's card.
        try click(rig, x: 200, y: 157)
        rig.wait { rig.field != nil }
        let field = try XCTUnwrap(rig.field, "The click gave the composer its place.")
        XCTAssertEqual(field.accessibilityLabel(), "Respuesta")
        XCTAssertEqual(field.placeholder, FieldAnswerCopy.placeholder)
        XCTAssertEqual(rig.session.chosenField?.option, 2)
        assertNothingReachedTheTerminal(rig, "Choosing the field presses nothing.")
        field.insertText("Usa Mon", replacementRange: field.selectedRange())
        Rig.settle()
        XCTAssertEqual(rig.session.draft, "Usa Mon")
        // «‹ Opciones esc», at the bar's right end.
        try click(rig, x: 497, y: 123)
        rig.wait { rig.field == nil }
        XCTAssertNil(rig.field, "The card is back.")
        XCTAssertNil(rig.session.chosenField)
        assertNothingReachedTheTerminal(rig, "Going back sends nothing, not even an Esc to Claude.")
        XCTAssertEqual(rig.escapes.count, 0)
        // The same row again: what was written is there to continue.
        try click(rig, x: 200, y: 157)
        rig.wait { rig.field != nil }
        XCTAssertEqual(rig.field?.string, "Usa Mon", "The answer was kept while the options were on screen.")
        XCTAssertEqual(rig.session.chosenField?.option, 2)
    }

    /// The user chose the field, went to another tab and came back: the pane is made again while the model still remembers the choice, and the card must not stand over the
    /// composer that was answering (its draft is in the tab).
    func testAPaneMadeWhileTheFieldIsChosenStartsAsTheAnswers() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") }, state: .options, choosesTheField: true, draft: "Usa Mon")
        let field = try XCTUnwrap(rig.field, "The composer has its place, not the card.")
        XCTAssertEqual(field.accessibilityLabel(), "Respuesta")
        XCTAssertEqual(field.string, "Usa Mon")
        assertNothingReachedTheTerminal(rig, "Coming back presses nothing.")
    }

    /// The probes above must be invisible to whoever is using the Mac: no window of theirs becomes key, and the test process never takes the front.
    func testTheProbesNeverTakeTheKeyboardOrTheFront() throws {
        // Other UI tests may already have activated XCTest; these probes must not change that state.
        let wasActive = NSApp.isActive
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") }, state: .options, choosesTheField: false)
        try click(rig, x: 200, y: 157)
        rig.wait { rig.field != nil }
        try rig.press(.escape)
        XCTAssertFalse(rig.window.isKeyWindow)
        XCTAssertFalse(rig.window.isMainWindow)
        XCTAssertEqual(NSApp.isActive, wasActive, "The probes do not change application activation.")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, before, "Whatever was in front stays there.")
    }

    // MARK: A field that already holds the answer

    /// A question with several answers keeps its dialog after Nook wrote the user's text into the field: that field is no target for more text. A click on its row on
    /// the card toggles its box with the keys, like on any option: one write, no composer, no field chosen.
    func testClickingAFilledFieldTogglesItsBoxInOneWriteAndDoesNotEnterAnswerMode() throws {
        let rig = try Rig(self, screen: platformsFilled, after: { _ in "" }, state: .options, choosesTheField: false, filledOption: 3)
        let dialog = try XCTUnwrap(rig.session.prompt)
        XCTAssertEqual(dialog.options[3].input, .inline, "Fixture: the answer's row still reads as a field.")
        XCTAssertTrue(rig.session.isFilledField(3, of: dialog))
        XCTAssertNil(rig.field, "The card has the composer's place.")
        // The filled field's row, the last one the card shows, highlighted.
        try click(rig, x: 200, y: 176)
        rig.wait { rig.scripts.count == 1 }
        XCTAssertEqual(rig.scripts.count, 1, "The toggle is one write.")
        let script = try XCTUnwrap(rig.scripts.first)
        XCTAssertTrue(script.contains(TerminalAppBridge.returnAction), "Enter, from where the highlight already is: \(script)")
        XCTAssertFalse(script.contains("[200~"), "No text is pasted into it again: \(script)")
        XCTAssertEqual(rig.keys, [], "No key event: Terminal stays where it is.")
        Rig.settle(0.5)
        XCTAssertNil(rig.field, "The card stays: the composer did not take its place.")
        XCTAssertNil(rig.session.chosenField, "No field is chosen to be written into.")
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
        XCTAssertNil(rig.model.notice)
    }

    /// The whole way through a question with several answers: the text goes into the field, the dialog stays with the field's box ticked, and the pane gives the card back with the
    /// field marked as holding the answer (no composer left in answer mode, nothing chosen, and a message to the field would be refused by the model).
    func testAnAnswerToAQuestionWithSeveralAnswersLeavesTheCardWithItsFieldFilled() throws {
        let answer = "Otro proveedor"
        let rig = try Rig(self, screen: platforms, after: { _ in self.lines(self.platformsFilled) }, draft: answer)
        XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta")
        try rig.press(.enter)
        rig.wait { rig.scripts.count == 1 && rig.session.filledField != nil }
        XCTAssertEqual(rig.scripts.count, 1)
        XCTAssertTrue(rig.scripts.first?.contains(#"& "[200~" & "Otro proveedor" & (character id 27) & "[201~""#) == true, rig.scripts.first ?? "no script")
        XCTAssertNil(rig.session.chosenField, "Answered: no field is chosen any more.")
        XCTAssertNil(rig.model.notice)
        // The screen the next reading finds: the same dialog, its field holding the text, ticked, with the highlight.
        rig.session.update(tab(lines(platformsFilled)))
        let filled = try XCTUnwrap(rig.session.prompt)
        XCTAssertTrue(rig.session.isFilledField(3, of: filled), "The model remembers the field holds the answer.")
        rig.wait { rig.field == nil }
        XCTAssertNil(rig.field, "The card is back (the dialog is another question's card to the pane: its field's text changed), not an answer composer.")
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
        XCTAssertEqual(rig.keys, [])
    }

    /// The field that still waits for its text, on the same kind of dialog, is the one that brings the composer: what tells them apart is what the model did with the click.
    func testTheFieldOfAQuestionWithSeveralAnswersStillBringsTheComposerBeforeItHoldsAnything() throws {
        let rig = try Rig(self, screen: platforms, after: { _ in "" }, state: .options, choosesTheField: false)
        XCTAssertNil(rig.field)
        // The card's last row («Type something»), at the bottom edge of the card.
        try click(rig, x: 200, y: 183)
        rig.wait { rig.field != nil }
        XCTAssertEqual(rig.field?.accessibilityLabel(), "Respuesta", "Nothing was written into it yet: it is the answer's target.")
        XCTAssertEqual(rig.session.chosenField?.option, 3)
        assertNothingReachedTheTerminal(rig, "Choosing the field presses nothing.")
    }

    /// With the card folded away, the highlighted field that already holds the answer is no answer box: the composer stays the message composer it was.
    func testAFilledFieldTheTerminalHighlightsIsNoAnswerTargetEither() throws {
        let rig = try Rig(self, screen: platformsFilled, after: { _ in "" }, state: .hidden, choosesTheField: false, filledOption: 3)
        let field = try XCTUnwrap(rig.field)
        XCTAssertEqual(field.accessibilityLabel(), "Mensaje", "A message is not an answer to a field that is full.")
        XCTAssertNotEqual(field.placeholder, FieldAnswerCopy.placeholder)
        XCTAssertNil(rig.model.fieldAnswer(for: rig.session))
    }

    /// What the row says and what VoiceOver hears: the user's own text, no invitation to write, and what the click does.
    func testTheFilledFieldsRowSaysWhatItHoldsAndWhatAClickDoes() throws {
        let dialog = try XCTUnwrap(AgentPrompt.parse(lines(platformsFilled)))
        let field = dialog.options[3]
        let help = try XCTUnwrap(PromptCardText.inputHelp(field, agentName: "Claude", filled: true))
        XCTAssertEqual(help, "Ya tiene tu respuesta; para cambiar el texto, edítalo en la terminal.")
        XCTAssertFalse(help.contains("Escribes"), "It takes no more text from Nook.")
        XCTAssertEqual(PromptCardText.inputHelp(field, agentName: "Claude"), "Escribes tu texto en Nook y se envía a este campo de Claude; al enviarlo, su casilla queda marcada.",
                       "An empty field is as it was.")
        XCTAssertEqual(PromptCardText.spoken(field, highlighted: true, filled: true), "con casilla marcada, con tu respuesta, resaltada")
        XCTAssertEqual(PromptCardText.spoken(field, highlighted: false), "con casilla marcada", "Without the flag it is as it was.")
        // The estimate counts the mark that stands where the pencil did.
        var long = dialog
        long.options[3].title = String(repeating: "Otro proveedor ", count: 8)
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(long, inline: false, width: 440, filled: [3]), PromptCardText.estimatedBodyHeight(long, inline: false, width: 440),
                             "«Tu respuesta» takes more of the row than the pencil: a long text wraps sooner.")
    }

    // MARK: A field the terminal already has

    func testAHighlightedFieldTakesWhatIsWrittenWithNoArrows() throws {
        let rig = try Rig(self, screen: onTheField, after: { _ in self.answered("sí, la réplica") }, state: .hidden, choosesTheField: false, draft: "sí, la réplica")
        XCTAssertEqual(rig.field?.placeholder, FieldAnswerCopy.placeholder)
        try rig.press(.enter)
        rig.wait { rig.scripts.count == 1 }
        XCTAssertTrue(rig.scripts.first?.contains(#"do script ((character id 27) & "[200~" & "sí, la réplica" & (character id 27) & "[201~") in t"#) == true, rig.scripts.first ?? "no script")
        XCTAssertEqual(rig.keys, [])
    }

    // MARK: What does not change

    /// A dialog with no text field is the old composer: its field is for messages, Enter asks before sending into the question, and Esc goes on to the island.
    func testWithoutAFieldTheComposerIsTheMessageComposerItWas() throws {
        let rig = try Rig(self, screen: permission, after: { _ in "" }, state: .hidden, choosesTheField: false, draft: "hola")
        let field = try XCTUnwrap(rig.field)
        XCTAssertEqual(field.accessibilityLabel(), "Mensaje")
        XCTAssertNotEqual(field.placeholder, FieldAnswerCopy.placeholder)
        try rig.press(.enter)
        XCTAssertTrue(rig.model.notice?.contains("tiene una pregunta abierta") == true, "The open question's confirmation stands for what is not a field.")
        assertNothingReachedTheTerminal(rig, "The first Enter only asks.")
        XCTAssertEqual(rig.field?.string, "hola", "The message stays in the field.")
        try rig.press(.escape)
        XCTAssertEqual(rig.escapes.count, 1, "Esc is not taken: it goes on to the island.")
    }

    /// «/» in an answer is a character: the menu of commands must not take the Enter that sends it.
    func testTheCommandsMenuStaysOutOfAnAnswer() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("/mod") }, draft: "/mod")
        try rig.press(.enter)
        rig.wait { rig.scripts.count == 1 }
        XCTAssertTrue(rig.scripts.first?.contains(#"& "[200~" & "/mod" & (character id 27) & "[201~""#) == true, "The answer is «/mod» as written, not a completed command: \(rig.scripts.first ?? "no script")")
    }

    /// An image has no place in a field: the paste is refused with a word, and nothing is attached.
    func testAnImagePasteIsRefusedWhileAnswering() throws {
        let rig = try Rig(self, screen: question, after: { _ in self.answered("x") })
        let field = try XCTUnwrap(rig.field)
        let board = NSPasteboard(name: NSPasteboard.Name("nook-field-answer-" + UUID().uuidString))
        board.clearContents()
        let picture = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        board.writeObjects([picture])
        field.pasteboard = board
        field.paste(nil)
        XCTAssertEqual(rig.model.notice, FieldAnswerCopy.imageRefusal)
        XCTAssertEqual(MessageAttachments.shared.paths(for: rig.session.id), [])
        assertNothingReachedTheTerminal(rig, "Refusing is Nook's own.")
    }

    // MARK: Words and decisions

    func testWhatEnterDoesWhileAnswering() {
        XCTAssertEqual(FieldAnswerEnter.decide(draft: "Usa MongoDB", busy: false), .send("Usa MongoDB"))
        XCTAssertEqual(FieldAnswerEnter.decide(draft: "\n  Usa MongoDB \n", busy: false), .send("  Usa MongoDB "), "Only the breaks at the ends go; the text is the user's.")
        XCTAssertEqual(FieldAnswerEnter.decide(draft: "", busy: false), .missing)
        XCTAssertEqual(FieldAnswerEnter.decide(draft: " \n\t ", busy: false), .missing, "Blank is no answer: Enter on an empty field cancels Claude's question.")
        XCTAssertEqual(FieldAnswerEnter.decide(draft: "Usa MongoDB", busy: true), .wait, "Something is on its way: the draft stays.")
        XCTAssertEqual(FieldAnswerEnter.decide(draft: "", busy: true), .wait)
    }

    func testTheBarsTitleIsTheQuestionOrWhoIsAsking() throws {
        let dialog = try XCTUnwrap(AgentPrompt.parse(lines(question)))
        XCTAssertEqual(FieldAnswerCopy.title(for: dialog, agentName: "Claude"), "Which database should we use?")
        var bare = dialog
        bare.question = ""
        XCTAssertEqual(FieldAnswerCopy.title(for: bare, agentName: "Claude"), "Claude pregunta")
        XCTAssertEqual(FieldAnswerCopy.sent("Usa MongoDB"), "Enviando «Usa MongoDB»")
        XCTAssertEqual(FieldAnswerCopy.sent("uno\ndos\n\ntres"), "Enviando «uno dos tres»", "A pasted paragraph reads as the line it goes as.")
    }

    func testTheCardSaysWhatTheFieldDoesNow() throws {
        let single = try XCTUnwrap(AgentPrompt.parse(lines(question)))
        let field = try XCTUnwrap(single.options.first { $0.input == .inline })
        let help = try XCTUnwrap(PromptCardText.inputHelp(field, agentName: "Claude"))
        XCTAssertEqual(help, "Escribes tu respuesta en Nook y se envía a este campo de Claude.")
        XCTAssertFalse(help.contains("Te lleva"), "It no longer takes anyone to the terminal's field.")
        XCTAssertEqual(PromptCardText.inputHelp(single.options[3], agentName: "Claude"), "Elige esta opción y después escribes en Nook lo que Claude debe hacer.", "«Chat about this» is as it was.")
        XCTAssertNil(PromptCardText.inputHelp(single.options[0], agentName: "Claude"))
        let several = try XCTUnwrap(AgentPrompt.parse(lines([" ☐ Platforms", "", "Which platforms should the release support?", "", "❯ 1. [ ] macOS", "  2. [✔] iOS", "  3. [ ] Type something", "",
                                                             "Enter to select · ↑/↓ to navigate · Esc to cancel"])))
        let box = try XCTUnwrap(several.options.first { $0.input == .inline })
        XCTAssertEqual(PromptCardText.inputHelp(box, agentName: "Claude"), "Escribes tu texto en Nook y se envía a este campo de Claude; al enviarlo, su casilla queda marcada.")
    }
}
