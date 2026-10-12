import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The model button and its list: the words a model is called by, what the list says (the picker's models, the aliases and how fresh that is), the
/// chip and the rows as buttons, and the click-away that closes the list. (The chip's symbols are in `ChipGlyphTests`.)
final class ClaudeModelNamesTests: XCTestCase {
    func testTheChipsTooltipSaysTheModelAsClaudeNamesItWithoutWhatItAddsInBrackets() {
        XCTAssertEqual(ClaudeModelName.short("Sonnet 5.5"), "Sonnet 5.5")
        XCTAssertEqual(ClaudeModelName.short("Opus 4.6 (1M context)"), "Opus 4.6")
        XCTAssertEqual(ClaudeModelName.short("  Haiku 4.5 [1m]  "), "Haiku 4.5")
        XCTAssertEqual(ClaudeModelName.short("claude-sonnet-4-5-20250929"), "Sonnet 4.5", "A model id is said as the agents' lists say it.")
        XCTAssertNil(ClaudeModelName.short(nil))
        XCTAssertNil(ClaudeModelName.short("   "))
        XCTAssertNil(ClaudeModelName.short("(1M context)"), "A name that is only brackets says nothing.")
    }
}

final class ModelMenuPlanTests: XCTestCase {
    private func learned(_ label: String, _ detail: String? = nil, current: Bool = false) -> ClaudeModelChoice {
        ClaudeModelChoice(label: label, detail: detail, argument: ClaudeModelStore.argument(forLabel: label), isCurrent: current)
    }

    func testTheModelsThePickerNamedComeBeforeTheAliasesItDidNot() {
        let choices = [learned("Default (recommended)", "Opus 4.6 · Most capable"), learned("Sonnet", "Sonnet 5.5 · Everyday tasks", current: true), learned("Opus (1M context)", "Opus 4.6 with 1M context")]
            + ClaudeModelStore.aliases.filter { $0.argument == "haiku" }
        let plan = ModelMenuPlan(choices: choices, stale: false)
        XCTAssertEqual(plan.learned.map(\.label), ["Default (recommended)", "Sonnet", "Opus (1M context)"])
        XCTAssertEqual(plan.aliases.map(\.label), ["Haiku"])
        XCTAssertEqual(plan.rows.map(\.label), ["Default (recommended)", "Sonnet", "Opus (1M context)", "Haiku"], "The arrows walk them in the order the list shows them.")
        XCTAssertEqual(plan.current?.label, "Sonnet")
        XCTAssertNil(plan.note)
        XCTAssertNil(plan.noteText)
        XCTAssertFalse(plan.openerStandsOut, "A fresh list needs no push to open Claude's picker.")
    }

    func testAListNookHasNotSeenSaysSoAndPointsToClaudesPicker() {
        let plan = ModelMenuPlan(choices: ClaudeModelStore.aliases, stale: false)
        XCTAssertTrue(plan.learned.isEmpty)
        XCTAssertEqual(plan.aliases.count, 4)
        XCTAssertEqual(plan.note, .onlyAliases)
        XCTAssertTrue(plan.noteText?.hasPrefix("Solo conozco los alias") == true)
        XCTAssertFalse(plan.noteText?.contains("\n") == true, "One line, under the last row's title.")
        XCTAssertTrue(plan.openerStandsOut)
    }

    func testAListFromAnotherVersionOfClaudeCodeIsSaidToBeOldWhateverItHolds() {
        let plan = ModelMenuPlan(choices: [learned("Default (recommended)"), learned("Sonnet")] + ClaudeModelStore.aliases.filter { $0.argument == "opus" }, stale: true)
        XCTAssertEqual(plan.note, .stale)
        XCTAssertTrue(plan.noteText?.hasPrefix("Lista de otra versión de Claude Code") == true)
        XCTAssertTrue(plan.openerStandsOut)
        XCTAssertEqual(ModelMenuPlan(choices: ClaudeModelStore.aliases, stale: true).note, .stale, "Stale is the more useful thing to say when both are true.")
    }

    func testWhatToTellOfAModelOnlyClaudesPickerCanChoose() {
        XCTAssertEqual(ModelMenuPlan.pickerHint(needsAccessibility: false), "Nook lo elige en el selector de Claude.")
        XCTAssertTrue(ModelMenuPlan.pickerHint(needsAccessibility: true).hasSuffix("necesita el permiso de Accesibilidad."))
    }

    func testAListThatLacksRowsOfClaudesPickerSaysHowMany() {
        let whole = [learned("Default (recommended)"), learned("Opus 5.5"), learned("Sonnet 5.5")]
        XCTAssertNil(ModelMenuPlan(choices: whole, stale: false, missing: 0).note, "Claude Code's own list is whole: nothing to say.")
        XCTAssertNil(ModelMenuPlan(choices: whole, stale: false, missing: nil).note, "Nothing says how many are missing: nothing is said of it.")
        let lacking = ModelMenuPlan(choices: whole, stale: false, missing: 3)
        XCTAssertEqual(lacking.note, .missing(3))
        XCTAssertEqual(lacking.noteText, "Faltan 3 modelos de la lista de Claude. Ábrelo para verlos.")
        XCTAssertEqual(ModelMenuPlan(choices: whole, stale: false, missing: 1).noteText, "Falta 1 modelo de la lista de Claude. Ábrelo para verlo.")
        XCTAssertTrue(lacking.openerStandsOut, "The row that opens Claude's picker is the one to press.")
        XCTAssertEqual(ModelMenuPlan(choices: whole, stale: true, missing: 3).note, .stale, "Old is the more useful thing to say.")
        XCTAssertEqual(ModelMenuPlan(choices: ClaudeModelStore.aliases, stale: false, missing: 3).note, .onlyAliases)
        XCTAssertEqual(lacking.rows.map(\.label), ["Default (recommended)", "Opus 5.5", "Sonnet 5.5"], "The rows are Claude's, in its order.")
        XCTAssertEqual(ModelMenuPlan(choices: [learned("A"), learned("B", current: true), learned("C")], stale: false).currentIndex, 1)
    }

    func testTheModelsAModelStoreOffersGoThroughThePlanAsTheyAre() throws {
        // A home of its own: Claude Code's list on this Mac's disk is not what this test is about.
        let store = ClaudeModelStore(defaults: UserDefaults(suiteName: "nook-menu-plan-" + UUID().uuidString)!, home: FileManager.default.temporaryDirectory.appendingPathComponent("nook-empty-" + UUID().uuidString))
        let picker = try XCTUnwrap(AgentPrompt.parse([" Select model", " Switch between Claude models.", "", "   1. Default (recommended) ✔  Opus 4.6 · Most capable", " ❯ 2. Sonnet                   Sonnet 5.5 · Everyday tasks",
                                                       "   3. Opus (1M context)        Opus 4.6 with 1M context", "", " Enter to confirm · Esc to exit"].joined(separator: "\n")))
        store.learn(picker, version: "2.1.290", folder: nil)
        let plan = ModelMenuPlan(choices: store.choices(folder: nil, current: "Sonnet 5.5"), stale: store.isStale(folder: nil, version: "2.1.290"))
        XCTAssertEqual(plan.learned.map(\.label), ["Default (recommended)", "Sonnet", "Opus (1M context)"])
        XCTAssertEqual(plan.aliases.map(\.argument), ["opus", "haiku"], "The aliases the picker did not name (\"Opus (1M context)\" is not the alias).")
        XCTAssertEqual(plan.current?.label, "Sonnet")
        XCTAssertNil(plan.note)
        XCTAssertEqual(ModelMenuPlan(choices: store.choices(folder: nil, current: "Sonnet 5.5"), stale: store.isStale(folder: nil, version: "2.1.300")).note, .stale)
    }
}

/// The part of the list that shows when the models do not all fit: it ends under a row, never through one, so the last row (Claude's picker) never
/// covers a model's description.
final class ModelMenuListFitTests: XCTestCase {
    func testTheVisiblePartEndsUnderAWholeRow() {
        // Rows end at 42, 81 and 120 points from the top of the list, and the part that shows ends 4 points under one.
        func snapped(_ room: CGFloat, _ ends: [CGFloat] = [42, 81, 120]) -> CGFloat { ClaudeModelMenu.snappedHeight(room: room, rowEnds: ends, breath: 4) }
        XCTAssertEqual(snapped(98), 85, "Two whole rows and their margin, not a third cut through its text.")
        XCTAssertEqual(snapped(130), 124)
        XCTAssertEqual(snapped(85), 85, "A row whose margin ends exactly at the room counts.")
        XCTAssertEqual(snapped(84), 46, "…and one that is a point short does not.")
        XCTAssertEqual(snapped(98, [120, 42, 81]), 85, "The rows come in whatever order they were measured.")
        XCTAssertEqual(ClaudeModelMenu.snappedHeight(room: 98, rowEnds: [42, 81, 120]), 81 + ClaudeModelMenu.rowBreath, "The margin is the card's own unless it is told another.")
    }

    func testWhenNotEvenTheFirstRowFitsTheRoomIsTheHeight() {
        XCTAssertEqual(ClaudeModelMenu.snappedHeight(room: 40, rowEnds: [42, 81]), 40)
        XCTAssertEqual(ClaudeModelMenu.snappedHeight(room: 90, rowEnds: []), 90, "Before the rows are measured nothing is cut.")
    }

    @MainActor
    func testAScrollingListNeverMakesTheCardTallerThanItsRoom() throws {
        let choices = (1...8).map { ClaudeModelChoice(label: "Model \($0)", detail: "A description of the model number \($0) that fits one line", argument: nil, isCurrent: $0 == 2) }
        for maxHeight: CGFloat in [120, 150, 200] {
            let card = ClaudeModelMenu(plan: ModelMenuPlan(choices: choices, stale: false), width: 380, maxHeight: maxHeight)
                .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
            let host = NSHostingView(rootView: card.fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
            XCTAssertLessThanOrEqual(host.fittingSize.height, maxHeight + 1, "The card, its last row included, stays inside the room it was given (\(maxHeight) pt).")
            XCTAssertGreaterThan(host.fittingSize.height, maxHeight - 55, "…and takes most of it: no more than a row (and its margin) is left unused (\(maxHeight) pt).")
            window.close()
        }
    }
}

/// The keyboard on the list: the arrows walk its rows (the last opens Claude's picker) and ↵ chooses.
final class ModelMenuKeyTests: XCTestCase {
    func testTheArrowsWalkTheRowsAndStopAtEitherEnd() {
        // Four models, then the row that opens Claude's picker: rows 0 to 4.
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .down, models: 4), 0, "The first ↓ goes to the first row.")
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .up, models: 4), 4, "The first ↑ goes to the last row, the one that opens Claude's picker.")
        XCTAssertEqual(ModelMenuKey.moved(from: 0, by: .down, models: 4), 1)
        XCTAssertEqual(ModelMenuKey.moved(from: 3, by: .down, models: 4), 4)
        XCTAssertEqual(ModelMenuKey.moved(from: 4, by: .down, models: 4), 4, "It stops at the end.")
        XCTAssertEqual(ModelMenuKey.moved(from: 4, by: .up, models: 4), 3)
        XCTAssertEqual(ModelMenuKey.moved(from: 0, by: .up, models: 4), 0, "And at the start.")
        XCTAssertEqual(ModelMenuKey.moved(from: 9, by: .down, models: 4), 4, "A list that got shorter under the highlight pulls it back.")
    }

    func testTheArrowsStartAtTheModelInUse() {
        // Nine models, the fourth (index 3) in use: the first arrow goes to its neighbour, so the list is walked from where the tab is.
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .down, models: 9, current: 3), 4)
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .up, models: 9, current: 3), 2)
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .up, models: 9, current: 0), 0, "It stops at the top.")
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .down, models: 9, current: 9), 9)
        XCTAssertEqual(ModelMenuKey.moved(from: 6, by: .down, models: 9, current: 3), 7, "Once a row is highlighted the model in use no longer matters.")
        XCTAssertEqual(ModelMenuKey.moved(from: nil, by: .down, models: 9, current: nil), 0, "With none in use it starts at the ends, as it always did.")
    }

    func testTheKeysThatDoNotWalkAreLeftToThePane() {
        for key in [ComposerKey.submit, .newline, .right, .tab, .escape, .pasteImage, .letter("s")] {
            XCTAssertNil(ModelMenuKey.moved(from: 1, by: key, models: 4), "\(key) does not move the highlight.")
        }
    }

    func testEnterChoosesTheHighlightedRowAndTheLastOpensClaudesPicker() {
        XCTAssertNil(ModelMenuKey.chosen(nil, models: 4), "With nothing highlighted ↵ is the field's own.")
        XCTAssertEqual(ModelMenuKey.chosen(0, models: 4), .model(0))
        XCTAssertEqual(ModelMenuKey.chosen(3, models: 4), .model(3))
        XCTAssertEqual(ModelMenuKey.chosen(4, models: 4), .picker)
        XCTAssertEqual(ModelMenuKey.chosen(7, models: 4), .picker, "A highlight past the end is the last row.")
    }
}

/// The chip, the rows and the click-away as the buttons they are, in a real window with real mouse events.
@MainActor
final class ClaudeModelMenuClickTests: XCTestCase {
    private final class Clicks { var chip = 0; var closed = 0; var chosen: [String] = []; var picker = 0 }

    private func window(_ view: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testAClickOnTheChipOpensTheListAndABlockedChipTakesNone() {
        let clicks = Clicks()
        let open = window(ClaudeModelChip(model: "Sonnet 5.5") { clicks.chip += 1 }.padding(20).frame(width: 220, height: 64, alignment: .topLeading), width: 220, height: 64)
        click(open, at: NSPoint(x: 20 + 12, y: 32))
        XCTAssertEqual(clicks.chip, 1)
        open.close()
        let blocked = window(ClaudeModelChip(model: "Sonnet 5.5", blocked: "Claude está trabajando; podrás cambiar el modelo cuando termine.") { clicks.chip += 1 }
            .padding(20).frame(width: 220, height: 64, alignment: .topLeading), width: 220, height: 64)
        click(blocked, at: NSPoint(x: 20 + 12, y: 32))
        XCTAssertEqual(clicks.chip, 1, "While Claude works the chip does nothing: a /model sent now would wait in its queue.")
        blocked.close()
    }

    private var plan: ModelMenuPlan {
        ModelMenuPlan(choices: [ClaudeModelChoice(label: "Default (recommended)", detail: "Opus 4.6 · Most capable", argument: "default"),
                                ClaudeModelChoice(label: "Sonnet", detail: "Sonnet 5.5 · Everyday tasks", argument: "sonnet", isCurrent: true),
                                ClaudeModelChoice(label: "Opus (1M context)", detail: "Opus 4.6 with 1M context")] + ClaudeModelStore.aliases.filter { $0.argument == "haiku" }, stale: false)
    }

    private final class Choices { var selected: [Int] = []; var applied: [String] = []; var steps: [Int] = []; var picker = 0 }

    /// The list with its selection kept, as the pane keeps it.
    private struct MenuHost: View {
        var plan: ModelMenuPlan
        var choices: Choices
        @State private var highlighted: Int?
        var body: some View {
            ClaudeModelMenu(plan: plan, highlighted: highlighted, width: 380, maxHeight: 700, effort: .high,
                            onSelect: { highlighted = $0; choices.selected.append($0) }, onChoose: { choices.applied.append($0.label + ($1 == .default ? " · defecto" : " · sesión")) },
                            onEffortStep: { choices.steps.append($0) }, onOpenPicker: { choices.picker += 1 }).padding(10)
                .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        }
    }

    /// Where an element with this accessibility label stands in the window, from its top left (what `click` takes).
    /// Where an element with this accessibility label stands in the window, from its top left (what `click` takes).
    private func centre(of label: String, in window: NSWindow) -> NSPoint? { AccessibilityLookup.center(of: label, in: window) }

    func testARowIsChosenWithAClickAndAppliedWithTheButtonsAsClaudesPickerApplies() throws {
        let choices = Choices()
        let host = NSHostingView(rootView: MenuHost(plan: plan, choices: choices))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        let shown = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        shown.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        shown.isReleasedWhenClosed = false
        shown.contentView = host
        shown.makeKeyAndOrderFront(nil)
        // The card settles (it measures its rows) before its size is read, and the window takes that size.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        shown.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let primary = try XCTUnwrap(centre(of: "Usar por defecto", in: shown), "The button that applies the model as the default.")
        let secondary = try XCTUnwrap(centre(of: "Solo esta sesión", in: shown), "The button that applies it for this session only.")
        // Until a row is chosen the buttons have nothing to apply.
        click(shown, at: primary)
        XCTAssertEqual(choices.applied, [], "Nothing is chosen yet.")
        // A click on a row only chooses it.
        click(shown, at: try XCTUnwrap(centre(of: "Sonnet", in: shown)))
        XCTAssertEqual(choices.selected, [1], "The second row, which is the model in use here, is chosen.")
        XCTAssertEqual(choices.applied, [], "A row is applied with the buttons, not by being clicked.")
        click(shown, at: primary)
        XCTAssertEqual(choices.applied, ["Sonnet · defecto"], "«Usar por defecto» is Enter in Claude's picker.")
        click(shown, at: secondary)
        XCTAssertEqual(choices.applied.last, "Sonnet · sesión", "«Solo esta sesión» is S.")
        click(shown, at: try XCTUnwrap(centre(of: "Default (recommended)", in: shown)))
        click(shown, at: secondary)
        XCTAssertEqual(choices.applied.last, "Default (recommended) · sesión")
        XCTAssertEqual(choices.picker, 0)
        shown.close()
    }

    func testTheEffortStepsAndTheLastRowOpensClaudesPicker() throws {
        let choices = Choices()
        let host = NSHostingView(rootView: MenuHost(plan: plan, choices: choices))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        let shown = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        shown.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        shown.isReleasedWhenClosed = false
        shown.contentView = host
        shown.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        shown.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        click(shown, at: try XCTUnwrap(centre(of: "Más esfuerzo", in: shown)))
        click(shown, at: try XCTUnwrap(centre(of: "Menos esfuerzo", in: shown)))
        XCTAssertEqual(choices.steps, [1, -1], "› takes the effort up a level and ‹ down.")
        click(shown, at: try XCTUnwrap(centre(of: "Ver el selector de Claude", in: shown)))
        XCTAssertEqual(choices.picker, 1, "The last row opens Claude's selector.")
        XCTAssertEqual(choices.applied, [])
        shown.close()
    }

    func testAnyClickAwayFromTheListClosesItAndDoesNothingElse() {
        final class Box { var closed = 0; var under = 0 }
        let box = Box()
        let row = Color.gray.opacity(0.3).frame(width: 300, height: 40).onTapGesture { box.under += 1 }
        let host = VStack(spacing: 0) {
            Color.clear.frame(height: 150)
            row.modelMenu(isOpen: true, onClose: { box.closed += 1 }) { Color.blue.frame(width: 120, height: 60).onTapGesture { box.under += 100 } }
            Color.clear.frame(height: 60)
        }.frame(width: 400, height: 250, alignment: .top)
        let shown = window(host, width: 400, height: 250)
        // On the conversation above the row, well away from the card: the click closes the list.
        click(shown, at: NSPoint(x: 40, y: 30))
        XCTAssertEqual(box.closed, 1)
        // On the row it stands over: the click closes the list and the row does not get it.
        click(shown, at: NSPoint(x: 100, y: 150 + 20))
        XCTAssertEqual(box.closed, 2)
        XCTAssertEqual(box.under, 0, "The first click only closes the list, as in any menu.")
        // On the card itself: the card's own.
        click(shown, at: NSPoint(x: 400 - 60, y: 150 - 6 - 30))
        XCTAssertEqual(box.under, 100)
        XCTAssertEqual(box.closed, 2)
        shown.close()
    }
}

/// The letters the pane asks the message field for while the model list is out (S: this session only): taken only when nothing else is held with them,
/// and never typed.
@MainActor
final class ComposerCapturedLetterTests: XCTestCase {
    func testAPlainCapturedLetterIsTheKeyAndAnythingElseIsTheFields() {
        let captured: Set<Character> = ["s"]
        XCTAssertEqual(ComposerKey.capturedLetter(characters: "s", modifiers: [], among: captured), .letter("s"))
        XCTAssertEqual(ComposerKey.capturedLetter(characters: "S", modifiers: [.shift], among: captured), .letter("s"), "Shift or caps lock does not change which key it is.")
        XCTAssertEqual(ComposerKey.capturedLetter(characters: "s", modifiers: [.capsLock], among: captured), .letter("s"))
        for held: NSEvent.ModifierFlags in [.command, .control, .option] {
            XCTAssertNil(ComposerKey.capturedLetter(characters: "s", modifiers: held, among: captured), "⌘S, ⌃S and ⌥S are not S.")
        }
        XCTAssertNil(ComposerKey.capturedLetter(characters: "a", modifiers: [], among: captured), "Another letter is the message's.")
        XCTAssertNil(ComposerKey.capturedLetter(characters: "ss", modifiers: [], among: captured))
        XCTAssertNil(ComposerKey.capturedLetter(characters: nil, modifiers: [], among: captured))
        XCTAssertNil(ComposerKey.capturedLetter(characters: "s", modifiers: [], among: []), "With none asked for, the field types every letter.")
    }

    private func keyDown(_ letter: String, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                         characters: letter, charactersIgnoringModifiers: letter, isARepeat: repeating, keyCode: 1)!
    }

    func testTheFieldHandsACapturedLetterToThePaneInsteadOfTypingItAndIgnoresItsRepeats() {
        let field = ComposerTextView.make()
        var asked: [ComposerKey] = []
        field.capturedLetters = ["s"]
        field.onKey = { key, _ in asked.append(key); return true }
        field.keyDown(with: keyDown("s"))
        XCTAssertEqual(asked, [.letter("s")])
        XCTAssertEqual(field.string, "", "The pane took it: it is not in the message.")
        field.keyDown(with: keyDown("s", repeating: true))
        XCTAssertEqual(asked, [.letter("s")], "A key held down chooses once.")
        XCTAssertEqual(field.string, "")
    }

    func testTheFieldAsksNothingOfTheLettersItWasNotToldAbout() {
        let field = ComposerTextView.make()
        var asked: [ComposerKey] = []
        field.onKey = { key, _ in asked.append(key); return true }
        field.keyDown(with: keyDown("s"))
        XCTAssertEqual(asked, [], "With no letters captured the field takes the key as it always did.")
    }
}
