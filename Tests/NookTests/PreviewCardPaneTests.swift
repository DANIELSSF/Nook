import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Claude's question with a preview, answered from the card as the pane drives it: a real `SessionPane` in an offscreen window that never becomes key, the notes' field fed text
/// by calling its text view directly, the rows clicked by handing the window mouse events (nothing is posted to the system, nothing takes the keyboard or the front), and every
/// transport a recorder. What reaches the terminal is what the tests read: the scripts the bridge would run and the keys it would post. The screens are
/// `PreviewQuestionFixtures`. Nothing here reaches Terminal, a real session or the user's delivery log.
@MainActor
final class PreviewCardPaneTests: XCTestCase {
    private typealias F = PreviewQuestionFixtures
    private let timing = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 2, hold: 0.06, settle: 0.5)
    private let notes = "el logo a la izquierda"
    private static let height: CGFloat = 440
    private static let width: CGFloat = 572

    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    override func tearDown() {
        WrittenNotesStore.shared.set(nil, for: "/dev/ttys094")
        super.tearDown()
    }

    private func tab(_ text: String) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys094", customTitle: "", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
    }

    private final class Escapes: ObservableObject { var count = 0 }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var escapes: Escapes
        var body: some View {
            SessionPane(model: model, session: session)
                .frame(width: PreviewCardPaneTests.width, height: PreviewCardPaneTests.height).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                .onExitCommand { escapes.count += 1 }
        }
    }

    /// What the bridge would have run and posted, and the screen it would read, from any thread.
    private final class Recorder {
        private let lock = NSLock()
        private var _scripts: [String] = [], _keys: [TerminalKey] = []
        private var _screen: String
        private var _reads = 0
        init(screen: String) { _screen = screen }
        /// How many times the bridge read the tab's screen.
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
        var keys: [TerminalKey] { lock.lock(); defer { lock.unlock() }; return _keys }
        /// The tab's screen as the bridge reads it now (a plain click reads it once before it writes, and an answer with notes reads it again for the proof).
        var screen: String {
            get { lock.lock(); defer { lock.unlock() }; return _screen }
            set { lock.lock(); _screen = newValue; lock.unlock() }
        }
        /// A reading of the screen: what the bridge finds now, counted.
        func read(proof later: String) -> String {
            lock.lock(); defer { lock.unlock() }
            _reads += 1
            return _scripts.contains { $0.contains("[200~") } ? later : _screen
        }
        func run(_ script: String) { lock.lock(); _scripts.append(script); lock.unlock() }
        func post(_ key: TerminalKey) { lock.lock(); _keys.append(key); lock.unlock() }
    }

    /// A pane over a Terminal tab showing `screen`, whose transports record: the scripts it would run, the keys it would post, and a screen that changes to `after` once a
    /// script wrote notes. The pane is tall enough for the whole card, so no row is scrolled out of reach.
    @MainActor private final class Rig {
        let model: AppModel
        let session: TerminalSession
        let escapes = Escapes()
        let window: NSWindow
        let host: NSHostingView<Island>
        private let recorder: Recorder
        var scripts: [String] { recorder.scripts }
        var keys: [TerminalKey] { recorder.keys }
        /// How many readings of the tab's screen the bridge made (a plain click on a question with a preview reads it once before it writes).
        var reads: Int { recorder.reads }
        /// The screen the bridge reads: a test that changes the tab (`session.update`) changes this too, or the read before a click's write would still see the old one.
        var current: String {
            get { recorder.screen }
            set { recorder.screen = newValue }
        }

        init(_ test: PreviewCardPaneTests, screen: [String], after: [String], timing: TerminalAppBridge.DeliveryTiming? = nil) {
            let defaults = UserDefaults(suiteName: "nook-preview-pane-" + UUID().uuidString)!
            model = AppModel(receivesSignals: false, defaults: defaults)
            let bridge = model.terminalBridge
            bridge.directKeysAllowed = { true }
            bridge.terminalProcess = { 4242 }
            bridge.fieldTiming = timing ?? test.timing
            bridge.reader = { _ in [] }
            let recorder = Recorder(screen: test.lines(screen))
            self.recorder = recorder
            bridge.runScript = { script in recorder.run(script) }
            bridge.postKey = { key, _ in recorder.post(key) }
            bridge.fieldJournal = { _ in }
            let before = test.lines(screen), later = test.lines(after)
            bridge.screenReader = { _, _ in recorder.read(proof: later) }
            session = TerminalSession(tab: test.tab(before), backend: .bundled, bridge: bridge)
            // The tab's notes are kept for the tab (its id is its TTY, the same in every test): none carried over from another test.
            WrittenNotesStore.shared.set(nil, for: session.id)
            model.sessions = [session]; model.selectedID = session.id
            model.expanded = true; model.islandContentVisible = true
            host = NSHostingView(rootView: Island(model: model, session: session, escapes: escapes))
            host.frame = NSRect(x: 0, y: 0, width: PreviewCardPaneTests.width, height: PreviewCardPaneTests.height)
            // Borderless: it can never become the key window, so nothing here can take the keyboard from whoever has it.
            window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: host.frame.width, height: host.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            // Far off any screen and never key: it is ordered in (a window that is not on screen takes no clicks) without ever being seen or taking the keyboard.
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            Self.settle(0.8)
        }

        static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }

        static func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        /// Runs the main loop until `condition` holds (or `seconds` pass).
        func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            Self.settle(0.1)
        }

        /// The notes' field, when the card has one (the composer is not on screen while the card is).
        var notesField: ComposerTextView? { Self.find(ComposerFieldView.self, in: host)?.textView }

        func type(_ text: String) {
            guard let field = notesField else { return }
            field.insertText(text, replacementRange: field.selectedRange())
            Self.settle()
        }

        enum Key { case enter, escape
            var code: UInt16 { self == .enter ? 36 : 53 }
            var characters: String { self == .enter ? "\r" : "\u{1b}" }
        }

        /// A key given to the notes' field the way the window would, without a window that can have the keyboard.
        func press(_ key: Key, file: StaticString = #filePath, line: UInt = #line) throws {
            let view = try XCTUnwrap(notesField, "The notes' field is not on screen", file: file, line: line)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code))
            view.keyDown(with: event)
            Self.settle()
        }

        /// A key as the window dispatches it to whatever has the keyboard (SwiftUI's key view for the card, the notes' field once it has been given it).
        func send(_ characters: String, code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            window.sendEvent(event)
            Self.settle(0.3)
        }

        /// The vertical centre, in points from the pane's top, of each row of options on the card: the number's box (a rounded square in a column of its own, 36 pt in from the
        /// pane's edge) is the one thing that stands in that column, and the row the terminal highlights is filled with the tab's colour as well. The runs of lit pixels
        /// there, top to bottom, are the tabs' ‹ button (when there are tabs), the options, «Chat about this» and the notes' field.
        func rowCentres() throws -> [CGFloat] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            let column = Int(36.5 * scale)
            var runs: [(start: Int, end: Int)] = []
            var start: Int?
            for y in 0..<rep.pixelsHigh {
                let colour = rep.colorAt(x: column, y: y)?.usingColorSpace(.sRGB)
                let lit = colour.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 > 0.105 } ?? false
                if lit, start == nil { start = y }
                if !lit, let begin = start { if y - begin >= Int(10 * scale) { runs.append((begin, y)) }; start = nil }
            }
            return runs.map { CGFloat($0.start + $0.end) / 2 / scale }
        }

        /// A click as the window would deliver it, to the offscreen window that can never be key; `y` is measured from the top of the pane.
        func click(x: CGFloat, y: CGFloat, quick: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
            let point = NSPoint(x: x, y: PreviewCardPaneTests.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0), file: file, line: line)
                window.sendEvent(event)
                Self.settle(quick ? 0.01 : 0.1)
            }
            Self.settle(quick ? 0.01 : 0.3)
        }

        /// Clicks down the options' column, from just under the card's bar to the pane's bottom, so every row (and whatever else stands there) is pressed once whatever the layout
        /// is. Never above the card: the conversation's text view tracks a mouse-down until the button is up, which a click made of two events handed to the window never lets it see.
        func sweep(x: CGFloat = 110, step: CGFloat = 7) throws {
            let prompt = try XCTUnwrap(session.prompt)
            let card = PromptCardText.estimatedHeight(prompt, width: PreviewCardPaneTests.width - 30, hasAccessory: true)
            var y = PreviewCardPaneTests.height - 9 - card + 40
            while y < PreviewCardPaneTests.height - 12 { try click(x: x, y: y, quick: true); y += step }
            Self.settle(0.3)
        }

        /// The click on option `number` (1, 2) or on «Chat about this» (3): rows are counted from the bottom, where the notes' field is the last run.
        func clickOption(_ number: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let centres = try rowCentres()
            XCTAssertGreaterThanOrEqual(centres.count, 4, "The rows and the notes' field are on the card: \(centres)", file: file, line: line)
            let rows = Array(centres.dropLast().suffix(3))
            guard rows.count == 3 else { return }
            try click(x: 110, y: rows[number - 1], file: file, line: line)
        }
    }

    private func assertNothingReachedTheTerminal(_ rig: Rig, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.scripts, [], message, file: file, line: line)
        XCTAssertEqual(rig.keys, [], message, file: file, line: line)
    }

    /// One script, no key event, nothing brought forward: what every answer from the card has to be.
    private func assertOneQuietWrite(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(rig.scripts.count, 1, "One script for the whole answer.", file: file, line: line)
        XCTAssertEqual(rig.keys, [], "No key event, though Accessibility is on: Terminal stays where it is.", file: file, line: line)
        let script = rig.scripts.first ?? ""
        for word in ["activate", "set index", "set selected", "frontmost", "miniaturized"] { XCTAssertFalse(script.contains(word), "«\(word)» in \(script)", file: file, line: line) }
        XCTAssertTrue(script.contains(#"if tty of t is "/dev/ttys094" then"#), "Addressed to the tab by its TTY.", file: file, line: line)
        return script
    }

    // MARK: The card on screen

    /// The card of a question with a preview stands where the composer was: no message field, and the notes' field is the only text view on it.
    func testTheCardShowsTheNotesFieldAndNoComposer() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        let field = try XCTUnwrap(rig.notesField, "The notes' field is on the card.")
        XCTAssertEqual(field.accessibilityLabel(), PreviewCopy.fieldLabel, "What is written there is a note, not a message.")
        XCTAssertEqual(field.placeholder, PreviewCopy.placeholder)
        XCTAssertEqual(try XCTUnwrap(rig.session.prompt).options.count, 3)
        assertNothingReachedTheTerminal(rig, "Showing the card presses nothing.")
        // Four things stand in the options' column: the tabs' ‹ button, the two options, «Chat about this» and the notes' field.
        XCTAssertEqual(try rig.rowCentres().count, 5)
    }

    /// A question without a preview (the next tab of Sample's dialog) is the card it always was: no notes' field, nothing of the preview's arrangement.
    func testAQuestionWithoutAPreviewHasNoNotes() throws {
        let rig = Rig(self, screen: F.nextTab, after: F.nextTab)
        XCTAssertNil(rig.notesField, "No field of notes where the question takes none.")
        let prompt = try XCTUnwrap(rig.session.prompt)
        XCTAssertFalse(prompt.takesNotes)
        assertNothingReachedTheTerminal(rig, "Showing the card presses nothing.")
    }

    // MARK: Choosing an option

    /// Without notes a click is what it always was: the arrows to the option and Terminal's own Return, in one write.
    func testAClickWithoutNotesIsOneWriteWithTheArrowsAndNoNotes() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        try rig.clickOption(2)
        rig.wait { !rig.scripts.isEmpty }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B") in t"#), "↓ to the second option, then Terminal's Return: \(script)")
        XCTAssertFalse(script.contains("[200~"), "Nothing is pasted: no notes were written.")
        XCTAssertEqual(rig.reads, 1, "One fresh reading of the screen before the write (the highlight and the notes field are checked on it), and no more.")
        XCTAssertNil(rig.model.notice)
    }

    /// With notes written, the same click sends the option and its notes as one answer: the arrows, «n», the notes between paste marks and Terminal's own Return. One script, no
    /// key event, nothing brought forward; the screen is read before and after (the proof that Claude took it), and the notes are given up once they went.
    func testAClickWithNotesIsOneWriteWithTheOptionAndItsNotes() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        XCTAssertEqual(rig.notesField?.string, notes)
        try rig.clickOption(2)
        rig.wait { !rig.scripts.isEmpty }
        rig.wait(1.5) { false }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.down], notes: notes))), script)
        XCTAssertNil(rig.model.notice, "It went: nothing to explain.")
        XCTAssertEqual(rig.escapes.count, 0)
    }

    /// The first option (already highlighted) goes away and back so Claude answers it, with the notes; the highlight on the other option means ↑ for it.
    func testTheNotesGoWithWhicheverOptionIsClicked() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        try rig.clickOption(1)
        rig.wait { !rig.scripts.isEmpty }
        rig.wait(1.5) { false }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.down, .up], notes: notes))), "Already highlighted: away and back. \(script)")
        let other = Rig(self, screen: F.sample(highlight: 2), after: F.nextTab)
        other.type(notes)
        try other.clickOption(1)
        other.wait { !other.scripts.isEmpty }
        other.wait(1.5) { false }
        XCTAssertTrue(assertOneQuietWrite(other).contains(try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.up], notes: notes))))
    }

    /// «Chat about this» takes no notes: the click is the plain one (the arrows to it, Terminal's Return) and what was written stays in the field for the card that comes back.
    func testChatAboutThisGoesAloneAndKeepsTheNotes() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        try rig.clickOption(3)
        rig.wait { !rig.scripts.isEmpty }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B" & (character id 27) & "[B") in t"#), "↓ ↓ to «Chat about this», then Return: \(script)")
        XCTAssertFalse(script.contains("[200~"), "The notes are not sent with it.")
        XCTAssertEqual(rig.reads, 1, "A plain click: one reading, then the write.")
        XCTAssertEqual(rig.notesField?.string, notes, "…and not lost.")
    }

    /// ↵ in the notes' field sends them with the option the preview belongs to, as ↵ does in the terminal's own notes field.
    func testEnterInTheNotesSendsThemWithTheOptionOfThePreview() throws {
        let rig = Rig(self, screen: F.sample(highlight: 2), after: F.nextTab)
        rig.type(notes)
        try rig.press(.enter)
        rig.wait { !rig.scripts.isEmpty }
        rig.wait(1.5) { false }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(try XCTUnwrap(TerminalAppBridge.notesAnswerAction(arrows: [.up, .down], notes: notes))), "The option the preview shows (the second): \(script)")
    }

    /// ↵ with nothing written sends nothing: an Enter on an empty field would answer with what the question had, or with «(notes only)».
    func testEnterWithNothingWrittenSendsNothing() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        try rig.press(.enter)
        rig.wait(0.5) { false }
        assertNothingReachedTheTerminal(rig, "Nothing written, nothing sent.")
        rig.type("   ")
        try rig.press(.enter)
        rig.wait(0.5) { false }
        assertNothingReachedTheTerminal(rig, "Blanks are no notes.")
    }

    /// Esc in the notes' field gives the keyboard back to the card and keeps what is written: the island stays (the key was taken) and nothing is sent.
    func testEscInTheNotesKeepsThemAndTheIslandStays() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        try rig.press(.escape)
        XCTAssertEqual(rig.notesField?.string, notes)
        XCTAssertEqual(rig.escapes.count, 0, "The key was taken: the island stays.")
        assertNothingReachedTheTerminal(rig, "Leaving the field is Nook's own.")
    }

    /// Esc on the card goes on to the island, as it always did (it puts the island away); Esc in the notes' field is the field's (it gives the keyboard back to the card and keeps
    /// what is written), and the next Esc, on the card again, is the island's.
    func testEscOnTheCardIsTheIslandsAndEscInTheNotesIsTheFields() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        XCTAssertFalse(rig.window.firstResponder is NSTextView, "The card has the keyboard.")
        rig.send("\u{1b}", code: 53)
        XCTAssertEqual(rig.escapes.count, 1, "Esc on the card reaches the island.")
        rig.send("n", code: 45)
        let field = try XCTUnwrap(rig.notesField)
        XCTAssertTrue(rig.window.firstResponder === field, "«n» gave the field the keyboard.")
        rig.type(notes)
        rig.send("\u{1b}", code: 53)
        XCTAssertEqual(rig.escapes.count, 1, "Esc in the notes does not reach the island.")
        XCTAssertFalse(rig.window.firstResponder === field, "The keyboard is back with the card.")
        XCTAssertEqual(field.string, notes, "What was written stays.")
        rig.send("\u{1b}", code: 53)
        XCTAssertEqual(rig.escapes.count, 2, "On the card again, Esc is the island's.")
        assertNothingReachedTheTerminal(rig, "No Esc goes to the terminal: Nook's Esc is Nook's own.")
    }

    /// The probes above must be invisible to whoever is using the Mac: no window of theirs becomes key, and the test process never takes the front.
    func testTheProbesNeverTakeTheKeyboardOrTheFront() throws {
        // Other UI tests may already have activated XCTest; these probes must not change that state.
        let wasActive = NSApp.isActive
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        try rig.clickOption(2)
        rig.wait { !rig.scripts.isEmpty }
        try rig.press(.escape)
        XCTAssertFalse(rig.window.isKeyWindow)
        XCTAssertFalse(rig.window.isMainWindow)
        XCTAssertEqual(NSApp.isActive, wasActive, "The probes do not change application activation.")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, before, "Whatever was in front stays there.")
    }

    // MARK: What the terminal holds

    /// The terminal already has notes: the card shows them and takes none of its own (no field), and a click answers as it always did: the terminal sends what it holds.
    func testNotesTheTerminalHoldsAreShownAndTheClickIsThePlainOne() throws {
        let rig = Rig(self, screen: F.sample(notes: "el logo a la izquierda"), after: F.nextTab)
        XCTAssertNil(rig.notesField, "No field of Nook's where the terminal's notes are.")
        let prompt = try XCTUnwrap(rig.session.prompt)
        XCTAssertEqual(prompt.notes, "el logo a la izquierda")
        // What stands in the options' column: the tabs' ‹ button, the two options, «Chat about this» and the box the terminal's notes are shown in (not a field).
        let centres = try rig.rowCentres()
        XCTAssertEqual(centres.count, 5, "\(centres)")
        try rig.click(x: 110, y: centres[2])
        rig.wait { !rig.scripts.isEmpty }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B") in t"#), script)
        XCTAssertFalse(script.contains("[200~"))
    }

    /// The terminal's own notes field has the keyboard, empty or with text being typed in it (`AgentPrompt.notesFocused`): a click's arrows and Enter would land in it (Enter
    /// would answer the option Claude has highlighted, not the clicked one), so the options wait and nothing is sent. (The same sweep of clicks over the same dialog with the
    /// field closed does answer, which is what makes the empty result mean something.) The card has no field of its own then, and the model has nothing to refuse: the click
    /// never reaches it.
    func testWhileTheTerminalsNotesFieldHasTheKeyboardTheOptionsSendNothing() throws {
        let control = Rig(self, screen: F.sample(), after: F.nextTab)
        try control.sweep()
        XCTAssertFalse(control.scripts.isEmpty, "Control: the sweep presses the options of the card.")
        for (name, rows) in [("open and empty", F.sample(notes: "Add notes on this design…")), ("with text being typed", F.sample(notes: notes, focused: true)),
                             ("a single question, typing", F.single(notes: notes, focused: true))] {
            let rig = Rig(self, screen: rows, after: F.nextTab)
            XCTAssertNil(rig.notesField, "\(name): no field of Nook's while the terminal's has the keyboard.")
            let prompt = try XCTUnwrap(rig.session.prompt)
            XCTAssertTrue(prompt.notesFocused, name)
            try rig.sweep()
            assertNothingReachedTheTerminal(rig, "\(name): the options are dimmed and wait for the terminal's field to close.")
            XCTAssertEqual(rig.reads, 0, "\(name): the click never reached the model, which would have read the screen.")
            XCTAssertNil(rig.model.notice, "\(name): nor did it leave a notice.")
        }
    }

    /// The user opened the terminal's notes field after the card was last drawn (the mirror has not caught up): the click finds the card as it was, and the model's own reading
    /// right before the write finds the field. It sends nothing and says why; the card (with its notes, when it had some) stays as it is, to try again once the field is closed.
    func testAClickAfterTheTerminalsFieldOpenedSendsNothingAndTheModelSaysWhy() throws {
        let refusal = "El campo de notas de Claude está abierto en la terminal: ciérralo allí con Esc, o termina allí tu respuesta. No envié nada."
        XCTAssertEqual(AppModel.notesFieldNotice(agent: .claude), refusal)
        // Plain click.
        let plain = Rig(self, screen: F.sample(), after: F.nextTab)
        plain.current = lines(F.sample(notes: "Add notes on this design…"))
        try plain.clickOption(2)
        plain.wait(2) { plain.model.notice != nil }
        XCTAssertEqual(plain.model.notice, refusal)
        assertNothingReachedTheTerminal(plain, "The field has the keys: nothing is sent.")
        XCTAssertEqual(plain.reads, 1, "The one fresh reading that found it.")
        // A click with notes: the field opened with text in it, which is what the hint's editor tells.
        let withNotes = Rig(self, screen: F.sample(), after: F.nextTab)
        withNotes.type(notes)
        withNotes.current = lines(F.sample(notes: "otra cosa escrita allí", focused: true))
        try withNotes.clickOption(2)
        withNotes.wait(2) { withNotes.model.notice != nil }
        XCTAssertEqual(withNotes.model.notice, refusal)
        assertNothingReachedTheTerminal(withNotes, "Nor are notes pasted into a field that has someone's text in it.")
        XCTAssertEqual(withNotes.notesField?.string, notes, "The notes stay in the card.")
    }

    /// Notes typed into the terminal's field stop being a field's the moment it closes: held with the field closed, the same text is shown read only and a click answers
    /// plainly, which is the terminal's own behaviour (it sends the notes it holds).
    func testTheSameTextOnceTheFieldIsClosedIsHeldAndTheClickAnswers() throws {
        let rig = Rig(self, screen: F.sample(notes: notes, focused: true), after: F.nextTab)
        try rig.sweep()
        assertNothingReachedTheTerminal(rig, "Typing in the terminal: the options wait.")
        // Esc in the terminal closed the field and left its text as held notes: the tab shows that now, and so does what the bridge reads before a click's write.
        rig.current = lines(F.sample(notes: notes))
        rig.session.update(tab(lines(F.sample(notes: notes))))
        rig.wait { (rig.session.prompt?.notesFocused ?? true) == false }
        let held = try XCTUnwrap(rig.session.prompt)
        XCTAssertEqual(PreviewNotesState(held), .held(notes))
        let centres = try rig.rowCentres()
        XCTAssertEqual(centres.count, 5, "\(centres)")
        try rig.click(x: 110, y: centres[2])
        rig.wait { !rig.scripts.isEmpty }
        let script = assertOneQuietWrite(rig)
        XCTAssertTrue(script.contains(#"do script ((character id 27) & "[B") in t"#), "The plain click: \(script)")
        XCTAssertFalse(script.contains("[200~"))
        XCTAssertEqual(rig.reads, 1, "One fresh reading, which now shows the field closed: the write goes.")
    }

    // MARK: When the answer does not go

    /// The notes were written into the terminal but Claude never showed them (the screen stays as it was): Nook presses no Enter of its own, the model says why, and the card
    /// keeps what was written so it can be sent again.
    func testAFailedAnswerKeepsTheNotesAndTheModelSaysWhy() throws {
        let unseen = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 0.6, hold: 0.06, settle: 0.25)
        let rig = Rig(self, screen: F.sample(), after: F.sample(), timing: unseen)
        rig.type(notes)
        try rig.clickOption(2)
        rig.wait(6) { rig.model.notice != nil }
        XCTAssertEqual(rig.model.notice, "Tus notas no aparecieron en la pregunta de Claude y sigue abierta. Revisa la terminal antes de enviarlas de nuevo.")
        XCTAssertEqual(rig.scripts.count, 1, "The write, and no Enter after it.")
        XCTAssertEqual(rig.notesField?.string, notes, "The card still has the notes.")
        XCTAssertEqual(rig.keys, [])
    }

    /// The question moved on (the next tab of the dialog): its card is another question's, with no notes field (it has no preview), and what was written for the first one is
    /// not there for any other.
    func testAnotherQuestionNeverInheritsTheNotes() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        rig.current = lines(F.nextTab)
        rig.session.update(tab(lines(F.nextTab)))
        rig.wait { rig.notesField == nil }
        XCTAssertNil(rig.notesField, "The next question has no preview and takes no notes.")
        // Back on a question with a preview that is another one: its notes start empty.
        rig.current = lines(F.single())
        rig.session.update(tab(lines(F.single())))
        rig.wait { rig.notesField != nil }
        XCTAssertEqual(rig.notesField?.string, "", "Another question, another notes' field.")
        assertNothingReachedTheTerminal(rig, "Nothing is sent by the screen changing.")
    }

    /// The card folded away with its chevron and brought back (the pane rebuilds it) finds the notes it had: they are the question's, kept by the pane.
    func testTheNotesSurviveTheCardBeingFoldedAwayAndBack() throws {
        let rig = Rig(self, screen: F.sample(), after: F.nextTab)
        rig.type(notes)
        // The chevron at the right end of the card's bar, 29 pt over the centre of the tabs' ‹ button (the bar is 32 pt tall and the button sits 13 pt under it).
        let tabs = try XCTUnwrap(try rig.rowCentres().first)
        try rig.click(x: Self.width - 15 - 18, y: tabs - 29)
        rig.wait { rig.notesField?.accessibilityLabel() == "Mensaje" }
        XCTAssertEqual(rig.notesField?.accessibilityLabel(), "Mensaje", "The composer has its place again.")
        // «Opciones», in the composer's last row after «Claude espera tu respuesta», gives the card back.
        try rig.click(x: 232, y: Self.height - 9 - 17)
        rig.wait { rig.notesField?.accessibilityLabel() == PreviewCopy.fieldLabel }
        XCTAssertEqual(rig.notesField?.accessibilityLabel(), PreviewCopy.fieldLabel, "The card is back.")
        XCTAssertEqual(rig.notesField?.string, notes, "What was written is still there.")
        assertNothingReachedTheTerminal(rig, "Folding the card away and back sends nothing.")
    }
}
