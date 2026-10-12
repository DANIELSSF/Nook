import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Claude's own /model picker as a card (Sample's, Claude Code 2.1.290): the rows of the model button's list with the numbers the picker prints, the effort
/// with its ← →, and «Usar por defecto» (↵) and «Solo esta sesión» (S) under them. Clicking a row only chooses it; the buttons apply it.
@MainActor
final class ModelPickerCardTests: XCTestCase {
    private let rule = String(repeating: "─", count: 72)

    /// The screen of Sample's picker (imagen-06102026042015), transcribed as `ClaudeDialogTests` has it.
    private var realPicker: [String] {
        ["⏺ Listo.", "", rule,
         " Select model",
         " Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with",
         " --model.", "",
         "    1.  Default (recommended)  Sonnet 5.5 · Efficient for routine tasks",
         " ❯  2.  Opus 5.5 ✔             For complex work and everyday tasks",
         "    3.  Fable 5.1              For your toughest challenges",
         "    4.  Sonnet 5.5             Most efficient for simpler tasks",
         "    5.  Haiku 4.5              Fastest for quick answers",
         "    6.  Sonnet 5               Efficient for routine tasks",
         "    7.  Opus 5                 Best for everyday, complex tasks",
         "    8.  Fable 5                Most capable for your hardest and longest-running tasks",
         " ↓  9.  Opus 4.8               Best for everyday, complex tasks",
         "    … +3 models", "",
         " ● xHigh effort ←/→ to adjust", "",
         " Enter to set as default · s to use this session only · Esc to cancel"]
    }

    private var prompt: AgentPrompt { AgentPrompt.parse(realPicker.joined(separator: "\n"))! }

    /// The picker's nine rows as the list offers them (the choices Claude Code's list would give, with the picker's descriptions).
    private var choices: [ClaudeModelChoice] {
        prompt.options.map { ClaudeModelChoice(label: $0.title, detail: $0.detail, argument: $0.number == 1 ? "default" : "claude-" + $0.title.lowercased().replacingOccurrences(of: " ", with: "-"),
                                               row: $0.number, isCurrent: $0.current) }
    }

    private final class Picks { var picked: [String] = [] }

    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func centre(of label: String, in window: NSWindow) -> NSPoint? { AccessibilityLookup.center(of: label, in: window) }

    private func shown(_ picks: Picks, width: CGFloat = 540, chatSize: Double = DisplaySettings.defaultChatSize, busy: Bool = false) -> NSWindow {
        let context = ModelPickerContext(plan: ModelMenuPlan(choices: choices, stale: false), needsAccessibility: false) { picks.picked.append($0.label + ($1 == .default ? " · defecto" : " · sesión")) }
        let card = AgentPromptCard(prompt: prompt, busy: busy, chatSize: chatSize, modelPicker: context).frame(width: width)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: card.fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return window
    }

    func testTheRealPickerIsAModelPickerAndItsRowsAreTheListsRows() throws {
        XCTAssertTrue(ClaudeModelStore.isModelPicker(prompt))
        XCTAssertEqual(prompt.kind, .selector)
        XCTAssertEqual(choices.count, 9)
        XCTAssertEqual(choices.map(\.row), (1...9).map { $0 })
        XCTAssertEqual(choices.first { $0.isCurrent }?.label, "Opus 5.5")
        XCTAssertEqual(choices.map(\.family), [.sonnet, .opus, .fable, .sonnet, .haiku, .sonnet, .opus, .fable, .opus],
                       "«Default (recommended)» wears the symbol of the model it stands for, Sonnet 5.5; each other row its own family's.")
    }

    func testClickingARowOnlyChoosesItAndTheButtonsApplyItAsTheDefaultOrForThisSessionOnly() throws {
        let picks = Picks()
        let window = shown(picks)
        let primary = try XCTUnwrap(centre(of: "Usar por defecto", in: window))
        let secondary = try XCTUnwrap(centre(of: "Solo esta sesión", in: window))
        // The row Claude's picker has highlighted is the one chosen to begin with: Opus 5.5.
        click(window, at: secondary)
        XCTAssertEqual(picks.picked, ["Opus 5.5 · sesión"])
        // A click on another row chooses it and changes nothing else.
        click(window, at: try XCTUnwrap(centre(of: "Modelo 3: Fable 5.1", in: window)))
        XCTAssertEqual(picks.picked.count, 1, "Choosing a row is not applying it.")
        click(window, at: primary)
        XCTAssertEqual(picks.picked.last, "Fable 5.1 · defecto")
        click(window, at: try XCTUnwrap(centre(of: "Modelo 5: Haiku 4.5", in: window)))
        click(window, at: secondary)
        XCTAssertEqual(picks.picked.last, "Haiku 4.5 · sesión")
        window.close()
    }

    func testNothingIsAppliedWhileTheKeysOfAnAnswerAreOnTheirWay() throws {
        let picks = Picks()
        let window = shown(picks, busy: true)
        click(window, at: try XCTUnwrap(centre(of: "Usar por defecto", in: window)))
        XCTAssertEqual(picks.picked, [], "The buttons wait for the screen to show the result.")
        window.close()
    }

    func testTheEstimateFollowsTheCardAsLaidOutAtTheWidthsOfTheIsland() throws {
        for width in [542.0, 404.0] {
            let picks = Picks()
            let window = shown(picks, width: width)
            let real = try XCTUnwrap(window.contentView?.fittingSize.height)
            let estimate = PromptCardText.estimatedHeight(prompt, width: width, hasAccessory: false, modelPicker: true)
            XCTAssertEqual(estimate, real, accuracy: 14, "at \(Int(width)) pt: estimated \(estimate), laid out \(real)")
            window.close()
        }
    }

    func testTheCardCoversTheConversationWithADozenRowsAndTheOldCardDidNotKnowTheButtons() throws {
        // Nine rows with a description each: far taller than the Normal island's pane (195 pt for the card).
        XCTAssertTrue(AgentPromptCard.coversMirror(cardHeight: PromptCardText.estimatedHeight(prompt, width: 542, hasAccessory: true, modelPicker: true), room: 195))
        // The buttons are part of what stands under the rows: beside the effort when the card is wide enough for both, under it when it is not.
        XCTAssertEqual(PromptCardText.estimatedFooter(prompt, modelPicker: true, width: 542), AgentPromptCard.footerGap + 28)
        XCTAssertEqual(PromptCardText.estimatedFooter(prompt, modelPicker: true, width: 404), AgentPromptCard.footerGap + 28, "Even in the narrowest island, with the effort's ring and arrows only.")
        XCTAssertEqual(PromptCardText.estimatedFooter(prompt, modelPicker: true, width: 360), AgentPromptCard.footerGap + 28 + 6 + 28)
        var plain = prompt
        plain.adjustment = nil
        XCTAssertEqual(PromptCardText.estimatedFooter(plain, modelPicker: true, width: 404), AgentPromptCard.footerGap + 28, "With no effort to show the buttons have the row.")
        XCTAssertEqual(PromptCardText.estimatedFooter(prompt, modelPicker: false), AgentPromptCard.footerGap + AgentPromptCard.footerRowHeight, "Any other list keeps its own.")
    }

    func testTheButtonsSayWhatTheyDoAndWhatTheyNeed() {
        let sonnet = ClaudeModelChoice(label: "Sonnet 5.5", argument: "claude-sonnet-5-5", row: 4)
        let overflow = ClaudeModelChoice(label: "Opus 4.7", row: 10)
        XCTAssertEqual(ModelScopeButtons.title(.default), "Usar por defecto")
        XCTAssertEqual(ModelScopeButtons.title(.sessionOnly), "Solo esta sesión")
        XCTAssertEqual(ModelScopeButtons.key(.default), "↵")
        XCTAssertEqual(ModelScopeButtons.key(.sessionOnly), "S")
        XCTAssertEqual(ModelScopeButtons.help(.default, for: nil, needsAccessibility: false), "Elige antes un modelo de la lista.")
        let byDefault = ModelScopeButtons.help(.default, for: sonnet, needsAccessibility: true)
        XCTAssertTrue(byDefault.contains("Sonnet 5.5") && byDefault.contains("por defecto") && byDefault.contains("sesiones nuevas"))
        XCTAssertFalse(byDefault.contains("Accesibilidad"), "A model with an id goes as a /model message: no keys.")
        XCTAssertTrue(ModelScopeButtons.help(.default, for: overflow, needsAccessibility: true).contains("Accesibilidad"), "A row only the picker can choose is chosen with keys.")
        XCTAssertFalse(ModelScopeButtons.help(.default, for: overflow, needsAccessibility: false).contains("Accesibilidad"))
        let session = ModelScopeButtons.help(.sessionOnly, for: sonnet, needsAccessibility: true)
        XCTAssertTrue(session.contains("solo en esta sesión") && session.contains("Accesibilidad"), "S goes through Claude's picker with the arrows, in a Terminal tab with the permission.")
        XCTAssertFalse(ModelScopeButtons.help(.sessionOnly, for: sonnet, needsAccessibility: false).contains("Accesibilidad"))
    }
}

/// The model list driven from the message field, as a user does: ↑ ↓ choose a row, ↵ applies it as the default and S for this session only, each as the
/// command it sends (a model with an id goes as `/model <id>`; for this session only Nook opens Claude's picker with `/model`, which it then drives).
@MainActor
final class ModelListKeysTests: XCTestCase {
    private final class Sent { var commands: [String] = [] }

    private func pane(highlight: Int?, sent: Sent) throws -> (NSWindow, ComposerTextView) {
        let defaults = UserDefaults(suiteName: "nook-list-keys-" + UUID().uuidString)!
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.models = ClaudeModelStore(defaults: defaults, home: try ModelCatalogFixture.home())
        model.commandSender = { text, _ in sent.commands.append(text) }
        model.keySender = { _, _ in }
        let rule = String(repeating: "─", count: 72)
        let screen = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Opus 5.5 with xhigh effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app", "", "> Hola", "", "⏺ Hola.", "", rule, "❯ ", rule, "  ? for shortcuts"].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys098", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: screen)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        XCTAssertNil(model.modelSwitchBlocked(on: session), "The tab is idle: the list may apply a model.")
        let view = SessionPane(model: model, session: session, dismissals: RecapSeenStore(defaults: nil), modelMenuOpen: true, modelHighlight: highlight).id(session.id)
            .frame(width: 572, height: 204).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 572, height: 204)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.06)); host.layoutSubtreeIfNeeded() }
        func find(_ view: NSView) -> ComposerTextView? {
            if let field = view as? ComposerTextView { return field }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let field = try XCTUnwrap(find(host), "The message field is in the pane.")
        window.makeFirstResponder(field)
        return (window, field)
    }

    private func press(_ field: ComposerTextView, keyCode: UInt16, characters: String) {
        field.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    func testTheArrowsChooseARowAndEnterAppliesItAsTheDefault() throws {
        let sent = Sent()
        let (window, field) = try pane(highlight: nil, sent: sent)
        // The model in use is Opus 5.5 (the second row): ↓ goes to the one after it, Fable 5.1.
        press(field, keyCode: 125, characters: "\u{F701}")
        XCTAssertEqual(sent.commands, [], "Choosing a row sends nothing.")
        press(field, keyCode: 36, characters: "\r")
        XCTAssertEqual(sent.commands, ["/model claude-fable-5-1"], "↵ is Enter in Claude's picker: the default for new sessions, as a /model message with the model's id.")
        window.close()
    }

    func testSAppliesTheRowChosenForThisSessionOnlyThroughClaudesPicker() throws {
        let sent = Sent()
        let (window, field) = try pane(highlight: 3, sent: sent)
        XCTAssertEqual(field.capturedLetters, ["s"], "With a row chosen the field leaves S to the list.")
        press(field, keyCode: 1, characters: "s")
        XCTAssertEqual(sent.commands, ["/model"], "For this session only Nook opens Claude's picker, which it then moves and presses S in.")
        XCTAssertEqual(field.string, "", "S is not typed into the message.")
        window.close()
    }

    func testBeforeARowIsChosenSAndEnterAreTheMessagesOwn() throws {
        let sent = Sent()
        let (window, field) = try pane(highlight: nil, sent: sent)
        XCTAssertTrue(field.capturedLetters.isEmpty, "Nothing is chosen: S is a letter of the message.")
        press(field, keyCode: 36, characters: "\r")
        XCTAssertEqual(sent.commands, [], "↵ with nothing chosen sends no model: it closes the list and does what it always does.")
        window.close()
    }
}
