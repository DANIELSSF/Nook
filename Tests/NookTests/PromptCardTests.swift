import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What the question's card puts on screen of a dialog (the words it chooses, when a question goes in the bar, when the card takes the pane) and
/// how several background agents read in the list and the pill when some come from Claude's own list and have no record, no model and no tool counts.
@MainActor
final class PromptCardTests: XCTestCase {
    private func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") }

    private func prompt(_ rows: [String], file: StaticString = #filePath, line: UInt = #line) throws -> AgentPrompt {
        try XCTUnwrap(AgentPrompt.parse(lines(rows)), "The fixture is not a dialog", file: file, line: line)
    }

    // MARK: Where the question goes

    func testAShortQuestionSitsBesideTheMarkAndALongOneOpensTheBody() throws {
        let short = try prompt(["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"])
        XCTAssertTrue(PromptCardText.isInline(short, hasAccessory: false))
        XCTAssertTrue(PromptCardText.isInline(short, hasAccessory: true))
        var long = short
        long.question = String(repeating: "x", count: 45)
        XCTAssertTrue(PromptCardText.isInline(long, hasAccessory: false))
        XCTAssertFalse(PromptCardText.isInline(long, hasAccessory: true), "With the agents' capsule beside it, the bar has less room.")
        long.question = String(repeating: "x", count: 60)
        XCTAssertFalse(PromptCardText.isInline(long, hasAccessory: false))
        var paragraphs = short
        paragraphs.question = "One paragraph.\nAnother."
        XCTAssertFalse(PromptCardText.isInline(paragraphs, hasAccessory: false), "Several paragraphs read in the body.")
        var tabbed = short
        tabbed.tabs = [AgentPrompt.Tab(title: "Database", answered: false, isSubmit: false)]
        XCTAssertFalse(PromptCardText.isInline(tabbed, hasAccessory: false), "The tabs stand over the question.")
        var empty = short
        empty.question = ""
        XCTAssertFalse(PromptCardText.isInline(empty, hasAccessory: false), "With no question, the bar says who is asking.")
    }

    func testTheTabThatSendsIsCalledByWhatItDoes() {
        XCTAssertEqual(PromptCardText.tabTitle(AgentPrompt.Tab(title: "Submit", answered: false, isSubmit: true)), "Enviar")
        XCTAssertEqual(PromptCardText.tabTitle(AgentPrompt.Tab(title: "Database", answered: true, isSubmit: false)), "Database")
    }

    func testASettingChangedInPlaceIsToldInSpanishWhenItIsTheEffort() {
        let medium = PromptCardText.adjustment("Medium effort (default)")
        XCTAssertEqual(medium.effort, .medium)
        XCTAssertEqual(medium.label, "Esfuerzo: Medio (predeterminado)")
        XCTAssertEqual(PromptCardText.adjustment("High effort").label, "Esfuerzo: Alto")
        XCTAssertEqual(PromptCardText.adjustment("xhigh effort").label, "Esfuerzo: Muy alto")
        XCTAssertEqual(PromptCardText.adjustment("Max effort (recommended)").label, "Esfuerzo: Máximo (recommended)", "A note that is not «default» stays as Claude says it.")
        let other = PromptCardText.adjustment("Brightness 40%")
        XCTAssertNil(other.effort)
        XCTAssertEqual(other.label, "Brightness 40%", "Anything else is the dialog's own words.")
        XCTAssertNil(PromptCardText.adjustment("Extreme effort").effort, "A level Nook does not know is not guessed.")
    }

    func testWhatVoiceOverHearsOfAnOption() {
        func option(checked: Bool? = nil, current: Bool = false) -> AgentPrompt.Option {
            AgentPrompt.Option(index: 0, number: 1, title: "x", detail: nil, shortcut: nil, input: .none, checked: checked, current: current)
        }
        XCTAssertEqual(PromptCardText.spoken(option(), highlighted: false), "")
        XCTAssertEqual(PromptCardText.spoken(option(), highlighted: true), "resaltada")
        XCTAssertEqual(PromptCardText.spoken(option(checked: true), highlighted: false), "con casilla marcada")
        XCTAssertEqual(PromptCardText.spoken(option(checked: false, current: true), highlighted: true), "con casilla sin marcar, actual, resaltada")
    }

    // MARK: How much room the card takes

    func testTheBodyEstimateGrowsWithWhatTheDialogSays() throws {
        let plain = try prompt(["", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again", "   3. No"])
        var described = plain
        described.options[0].detail = String(repeating: "A long description. ", count: 12)
        let base = PromptCardText.estimatedBodyHeight(plain, inline: true)
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(described, inline: true), base, "A described option is taller.")
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(plain, inline: false), base, "A question that opens the body takes room there.")
        var more = plain
        more.options.append(more.options[2])
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(more, inline: true), base)
        // Three plain one-line options are the rows the card always had: 24 pt each and a point between them.
        XCTAssertEqual(PromptCardText.estimatedBodyHeight(plain, inline: true), 3 * AgentPromptCard.rowHeight + 2 * AgentPromptCard.rowGap)
    }

    func testAnOptionWrapsWhereItsTextDoesNotFit() throws {
        var long = try prompt(["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"])
        long.options[1].title = String(repeating: "Yes, and don't ask again for swift test commands in this project. ", count: 3)
        let narrow = PromptCardText.estimatedBodyHeight(long, inline: true, width: 440)
        let wide = PromptCardText.estimatedBodyHeight(long, inline: true, width: 720)
        XCTAssertGreaterThan(narrow, wide, "The same text takes more lines in a narrower card.")
        XCTAssertGreaterThan(wide, 2 * AgentPromptCard.rowHeight + AgentPromptCard.rowGap, "…and more than the compact row it used to be cut to.")
        // The text size the user chose is the card's too.
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(long, inline: true, width: 572, chatSize: 16), PromptCardText.estimatedBodyHeight(long, inline: true, width: 572, chatSize: 11))
    }

    func testTheWholeCardIsMeasuredLikeTheOldOneWhenItsRowsAreCompact() throws {
        // Four plain options and a question in the bar: 32 (bar) + 4 × 24 + 3 × 1 + 7, the height the card always had.
        let four = try prompt(["", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again", "   3. No, and tell Claude what to do differently (esc)", "   4. Maybe later"])
        XCTAssertEqual(PromptCardText.estimatedHeight(four, width: 542, hasAccessory: true), AgentPromptCard.cardHeight(options: 4, visibleRows: 6))
        XCTAssertFalse(AgentPromptCard.coversMirror(cardHeight: PromptCardText.estimatedHeight(four, width: 542, hasAccessory: true), room: 195))
        // A question that does not fit the bar opens the body, which takes a line more; the card still leaves the conversation a few lines.
        var longer = four
        longer.question = "Do you want to make this edit to PanelView.swift, as it is shown above?"
        XCTAssertGreaterThan(PromptCardText.estimatedHeight(longer, width: 542, hasAccessory: true), PromptCardText.estimatedHeight(four, width: 542, hasAccessory: true))
        // The context line is the card's to add when it covers the conversation; the decision never counts it, or it would depend on its own answer.
        var tool = four
        tool.context = "Update(Sources/Nook/PanelView.swift)"
        XCTAssertGreaterThan(PromptCardText.estimatedHeight(tool, width: 542, hasAccessory: true, showsContext: true), PromptCardText.estimatedHeight(tool, width: 542, hasAccessory: true))
        // The model picker has its adjustment row under the options.
        var picker = four
        picker.adjustment = "Medium effort (default)"
        XCTAssertEqual(PromptCardText.estimatedHeight(picker, width: 542, hasAccessory: true) - PromptCardText.estimatedHeight(four, width: 542, hasAccessory: true),
                       AgentPromptCard.footerGap + AgentPromptCard.footerRowHeight)
    }

    func testTheCardTakesThePaneWhenItLeavesTheConversationLessThanALine() {
        // The Normal island's pane: 204 pt, 195 for the card once its margin is out. Four plain options leave the conversation 51 pt, as they always did.
        let room: CGFloat = 195
        XCTAssertFalse(AgentPromptCard.coversMirror(cardHeight: AgentPromptCard.cardHeight(options: 4, visibleRows: 6), room: room))
        XCTAssertTrue(AgentPromptCard.coversMirror(cardHeight: AgentPromptCard.cardHeight(options: 5, visibleRows: 6), room: room))
        XCTAssertTrue(AgentPromptCard.coversMirror(cardHeight: 189, room: room), "A card as tall as the pane covers it whatever it holds.")
        XCTAssertFalse(AgentPromptCard.coversMirror(cardHeight: 100, room: room))
        // The old rule by count of options stays for the first frame, before the card is measured.
        XCTAssertFalse(AgentPromptCard.coversMirror(optionCount: 4))
        XCTAssertTrue(AgentPromptCard.coversMirror(optionCount: 5))
    }

    // MARK: Reading the dialogs the card now shows whole

    func testTheModelPickerCarriesWhatTheCardNeedsToLookLikeOne() throws {
        let picker = try prompt(["⏺ Listo.", "", " Select model", " Switch between Claude models. Applies to this session and future sessions.", "",
                                 "   1. Default (recommended) ✔  Opus 4.6 with 1M context · Most capable for complex work", " ❯ 2. Sonnet                   Sonnet 4.6 · Best for everyday tasks",
                                 "   3. Haiku                    Haiku 4.5 · Fastest for quick answers", "", "   ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"])
        XCTAssertEqual(picker.kind, .selector)
        XCTAssertEqual(picker.question, "Select model")
        XCTAssertEqual(picker.note, "Switch between Claude models. Applies to this session and future sessions.")
        XCTAssertEqual(picker.options.map(\.current), [true, false, false], "The model in use is marked.")
        XCTAssertEqual(picker.options[0].detail, "Opus 4.6 with 1M context · Most capable for complex work", "The description is whole.")
        XCTAssertEqual(picker.adjustment, "Medium effort (default)")
        XCTAssertEqual(PromptCardText.adjustment(try XCTUnwrap(picker.adjustment)).label, "Esfuerzo: Medio (predeterminado)")
        XCTAssertTrue(PromptCardText.isInline(picker, hasAccessory: true), "A short title sits in the bar and its note goes in the body.")
    }

    func testALongQuestionAndItsDescribedOptionsKeepEveryWord() throws {
        let question = "Which database should we use for the new service, considering that the team already runs Postgres for billing but nobody has operated Redis in production?"
        let detail = "Relational, strong consistency, a great ecosystem; the team already operates it for billing, so backups and monitoring are in place"
        let long = try prompt(["☐ Database", "", question, "", "❯ 1. PostgreSQL", "     " + detail, "  2. SQLite", "     Embedded, zero configuration", "  3. Type something.",
                               String(repeating: "─", count: 40), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"])
        XCTAssertEqual(long.header, "Database")
        XCTAssertEqual(long.question, question)
        XCTAssertEqual(long.options[0].detail, detail)
        XCTAssertEqual(long.options.map(\.title), ["PostgreSQL", "SQLite", "Type something.", "Chat about this"])
        XCTAssertFalse(PromptCardText.isInline(long, hasAccessory: false))
    }

    func testBoxesAndTabsReachTheCard() throws {
        let boxes = try prompt(["☐ Services", "", "Which services should we set up?", "", "❯ 1. [ ] PostgreSQL", "  2. [✔] Redis", "  3. Type something.", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"])
        XCTAssertTrue(boxes.multiSelect)
        XCTAssertEqual(boxes.options.map(\.checked), [false, true, nil])
        let tabbed = try prompt(["← ☒ Database  ☐ Cache  ✔ Submit →", "", "Which cache should we use?", "", "❯ 1. Redis", "  2. Memcached", "  3. Type something.", "", "Enter to select · Esc to cancel"])
        XCTAssertEqual(tabbed.tabs.map(\.title), ["Database", "Cache", "Submit"])
        XCTAssertEqual(tabbed.tabs.map(\.answered), [true, false, false])
        XCTAssertEqual(tabbed.tabs.map(\.isSubmit), [false, false, true])
    }

    // MARK: The review step

    private let reviewRows = [String(repeating: "─", count: 72), "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
                              "│ ● Which number do we connect?", "  → Optional, the server looks it up (Recommended)",
                              "│ ● Which mode does the signup use?", "  → Leave it for later (Recommended)", "",
                              "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    func testTheReviewStepIsASummaryAndNotAQuestionInTheBar() throws {
        let review = try prompt(reviewRows)
        XCTAssertTrue(PromptCardText.isReview(review))
        XCTAssertFalse(PromptCardText.isInline(review, hasAccessory: false), "Its closing question is not the bar's: the summary has the body.")
        XCTAssertFalse(PromptCardText.isReview(try prompt(["", " Do you want to proceed?", " ❯ 1. Yes", "   2. No"])))
        XCTAssertFalse(PromptCardText.isReview(try prompt(["← ☒ Database  ☐ Cache  ✔ Submit →", "", "Which cache should we use?", "", "❯ 1. Redis", "  2. Memcached", "", "Enter to select · Esc to cancel"])),
                       "A question of several is not the review.")
    }

    func testTheReviewIsToldInSpanishWhereClaudesWordsAreTheOnesItAlwaysUses() throws {
        XCTAssertEqual(PromptCardText.reviewTitle, "Revisa tus respuestas")
        XCTAssertEqual(PromptCardText.reviewWarning("You have not answered all questions"), "No has respondido todas las preguntas.")
        XCTAssertEqual(PromptCardText.reviewWarning("you have not answered all questions."), "No has respondido todas las preguntas.", "Case and a full stop do not make it another warning.")
        XCTAssertEqual(PromptCardText.reviewWarning("Two answers are too long"), "Two answers are too long", "Any other warning is Claude's own words.")
        XCTAssertEqual(PromptCardText.reviewClosing("Ready to submit your answers?"), "¿Listo para enviar tus respuestas?")
        XCTAssertEqual(PromptCardText.reviewClosing("Send them now?"), "Send them now?")
        let review = try prompt(reviewRows)
        XCTAssertEqual(review.options.map(PromptCardText.decisionTitle), ["Enviar respuestas", "Cancelar"])
        var other = review.options[1]
        other.title = "Go back and edit"
        XCTAssertEqual(PromptCardText.decisionTitle(other), "Go back and edit")
        XCTAssertEqual(PromptCardText.decisionHelp(review.options[0], agentName: "Claude"), "Envía las respuestas a Claude.")
        XCTAssertEqual(PromptCardText.decisionHelp(review.options[1], agentName: "Claude"), "Cancela sin enviar las respuestas.")
        XCTAssertNil(PromptCardText.decisionHelp(other, agentName: "Claude"), "A button Nook does not know says nothing it cannot be sure of.")
    }

    func testTheButtonThatSendsIsTheSolidOneWhicheverOrderTheOptionsComeIn() throws {
        var review = try prompt(reviewRows)
        XCTAssertEqual(PromptCardText.primaryOption(in: review), 0)
        review.options.reverse()
        for index in review.options.indices { review.options[index].index = index }
        XCTAssertEqual(review.options.map(\.title), ["Cancel", "Submit answers"])
        XCTAssertEqual(PromptCardText.primaryOption(in: review), 1, "It is found by what it says.")
        review.options[1].title = "Something else"
        XCTAssertEqual(PromptCardText.primaryOption(in: review), 0, "Without a word that sends, the first is the main one.")
    }

    func testEachQuestionIsLabelledByItsTabOrItsNumber() {
        let named = AgentPrompt.ReviewItem(question: "q", answer: "a", tab: "Id número")
        let anonymous = AgentPrompt.ReviewItem(question: "q", answer: nil, tab: nil)
        XCTAssertEqual(PromptCardText.reviewLabel(named, index: 0, of: 2), "Id número")
        XCTAssertEqual(PromptCardText.reviewLabel(anonymous, index: 1, of: 3), "Pregunta 2")
        XCTAssertNil(PromptCardText.reviewLabel(anonymous, index: 0, of: 1), "A single question needs no number.")
    }

    func testTheReviewIsTallerWhereItHasMoreToSay() throws {
        let review = try prompt(reviewRows)
        let base = PromptCardText.estimatedBodyHeight(review, inline: false, width: 542)
        var warned = review
        warned.warning = "You have not answered all questions"
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(warned, inline: false, width: 542), base, "The notice takes room.")
        var longer = review
        longer.review[0].question = String(repeating: "A long question that wraps. ", count: 12)
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(longer, inline: false, width: 542), base)
        XCTAssertGreaterThan(PromptCardText.estimatedBodyHeight(longer, inline: false, width: 440), PromptCardText.estimatedBodyHeight(longer, inline: false, width: 542), "…and more in a narrower card.")
        var unanswered = review
        unanswered.review[1].answer = nil
        XCTAssertLessThanOrEqual(PromptCardText.estimatedBodyHeight(unanswered, inline: false, width: 542), base, "A missing answer is one line, never taller than an answer.")
    }

    // MARK: Agents read from Claude's own list

    private func listAgent(_ index: Int, activity: String? = "Reading NotchController expand and keepIslandWithTerminal") -> SubagentActivity {
        var agent = SubagentActivity(id: "tree:\(index)", name: "fork", kind: "fork", state: .running, tokens: "187.3k", duration: "4m 56s")
        agent.activity = activity
        return agent
    }

    func testAnAgentOfClaudesListHasNoTagThatRepeatsItsName() {
        XCTAssertNil(listAgent(0).distinctKind, "Its type is its name.")
        XCTAssertNil(SubagentActivity(id: "x", name: "Explore", kind: "explore", state: .running).distinctKind, "Case does not make it another word.")
        XCTAssertEqual(SubagentActivity(id: "x", name: "Find the contact list", kind: "Explore", state: .running).distinctKind, "Explore")
        XCTAssertNil(SubagentActivity(id: "x", name: "Review the diff", state: .running).distinctKind)
        XCTAssertTrue(listAgent(0).isListOnly)
        XCTAssertFalse(SubagentActivity(id: "toolu_01", name: "fork", state: .running).isListOnly)
    }

    func testAWorkingAgentOfTheListFitsOneLine() {
        let working = listAgent(0)
        XCTAssertTrue(working.showsInlineActivity)
        XCTAssertFalse(working.showsActivityLine, "It has no second line: what it does shares the first.")
        XCTAssertEqual(SubagentListLayout.rowHeight(of: working), SubagentListLayout.rowHeight, "…so three of them are 75 pt, not 111.")
        XCTAssertEqual(SubagentListLayout.height(of: [working, listAgent(1), listAgent(2)]), SubagentListLayout.headerHeight + 2 * SubagentListLayout.verticalPadding + 3 * SubagentListLayout.rowHeight)
        // One with nothing to say yet keeps the usual two lines (it says "Trabajando…" on the second), and an agent with a record is never inline.
        XCTAssertFalse(listAgent(0, activity: nil).showsInlineActivity)
        XCTAssertTrue(listAgent(0, activity: nil).showsActivityLine)
        var recorded = working
        recorded.id = "toolu_01"
        XCTAssertFalse(recorded.showsInlineActivity)
        XCTAssertEqual(SubagentListLayout.rowHeight(of: recorded), SubagentListLayout.workingRowHeight)
        var done = working
        done.state = .done
        XCTAssertFalse(done.showsInlineActivity)
    }

    func testClaudesWordsForWhatAnAgentDoesAreNotMistakenForAToolCall() {
        XCTAssertTrue(AgentActivityLine.parse("Reading NotchController expand and keepIslandWithTerminal").isPhrase)
        XCTAssertFalse(AgentActivityLine.parse("Read(Sources/Nook/Pet.swift)").isPhrase)
        XCTAssertFalse(AgentActivityLine.parse("Read").isPhrase, "A bare tool name is a call.")
        XCTAssertFalse(AgentActivityLine.parse("Thinking…").isPhrase)
    }

    func testTheCollapsedIslandNamesEachAgentByWhatItDoes() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-pill-card-" + UUID().uuidString)!)
        let rule = String(repeating: "─", count: 72)
        let screen = lines(["  Te aviso cuando termine cada agente.", "", "✻ Waiting for 3 background agents to finish", "", rule, "❯ ", rule,
                            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents · ↓ to manage", "", "  ⏺️ main",
                            "  ○ fork  Reading NotchController expand and keepIslandWithTerminal", "4m 56s · ↓ 187.3k tokens", "  ○ fork  Charting echo failures in deliveries.log",
                            "4m 56s · ↓ 189.9k tokens", "  ○ fork  Finding AgentPrompt construction call sites", "4m 56s · ↓ 208.6k tokens"])
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys080", customTitle: "nook", processes: ["claude"], busy: false, selected: true, text: screen)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.updateActivity()
        XCTAssertEqual(session.subagents.count, 3, "The agents come from the list under the mode line.")
        XCTAssertEqual(model.runningSubagents, 3)
        let pill = try XCTUnwrap(model.agentPill)
        XCTAssertEqual(pill.names, ["fork · Reading NotchController expand and keepIslandWithTerminal", "fork · Charting echo failures in deliveries.log", "fork · Finding AgentPrompt construction call sites"])
        let tooltip = AgentPillTooltip.text(pill).components(separatedBy: "\n")
        XCTAssertEqual(tooltip.first, "3 subagentes trabajando en «nook»")
        XCTAssertEqual(tooltip[2], "· fork · Charting echo failures in deliveries.log", "Three agents with one name are told apart by what they do.")
        XCTAssertEqual(tooltip.last, "Clic para ver la lista")
        // The tab's badge counts them too.
        XCTAssertEqual(TabAgentState(session.subagents).count, 3)
        // An agent with a record keeps its name alone, as the tooltip has always had it.
        var recorded = SubagentActivity(id: "toolu_01", name: "Diseñar el gato", kind: "general-purpose", state: .running)
        recorded.activity = "Read(Sources/Nook/Pet.swift)"
        XCTAssertEqual(recorded.pillLabel, "Diseñar el gato")
    }
}

/// The estimate the pane decides by against the card as SwiftUI lays it out: if they drifted apart, the conversation would be hidden under a card
/// that leaves it room, or squeezed beside one that does not.
@MainActor
final class PromptCardEstimateTests: XCTestCase {
    private let fixtures: [(String, [String])] = [
        ("permission", ["", " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project", "   3. No, and tell Claude what to do differently (esc)"]),
        ("edit", ["", " Do you want to make this edit to PanelView.swift?", " ❯ 1. Yes", "   2. Yes, allow all edits during this session (shift+tab)", "   3. No, and tell Claude what to do differently (esc)"]),
        ("question", ["☐ Database", "", "Which database should we use for the new service?", "", "❯ 1. PostgreSQL", "     Relational, strong consistency and a great ecosystem", "  2. SQLite",
                      "     Embedded, zero configuration, single file", "  3. Type something.", String(repeating: "─", count: 40), "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]),
        ("long", ["☐ Database", "", "We are about to move the CRM from a single SQLite file to a hosted database, and the migration will touch contacts, deals and the activity timeline. Which database should we use for the new service, considering that the team already runs Postgres for billing but nobody has operated Redis in production?", "",
                  "❯ 1. PostgreSQL", "     Relational, strong consistency, a great ecosystem; the team already operates it for billing, so backups and monitoring are in place",
                  "  2. SQLite", "     Embedded, zero configuration, single file; fine for a prototype but it has no concurrent writers", "  3. Type something.", String(repeating: "─", count: 40),
                  "  4. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]),
        ("multi", ["☐ Services", "", "Which services should we set up for the new environment?", "", "❯ 1. [ ] PostgreSQL", "       Relational database for contacts and deals", "  2. [✔] Redis",
                   "       In-memory cache and job queues", "  3. Type something.", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]),
        ("tabs", ["← ☒ Database  ☐ Cache  ✔ Submit →", "", "Which cache should we use for sessions and rate limiting?", "", "❯ 1. Redis", "     In-memory, supports TTL and pub/sub", "  2. Memcached",
                  "     Simple and fast, no persistence", "  3. Type something.", "", "Enter to select · Esc to cancel"]),
        ("model", [" Select model", " Switch between Claude models. Applies to this session and future sessions. For other/previous model names, specify with --model.", "",
                   "   1. Default (recommended) ✔  Opus 4.6 with 1M context · Most capable for complex work", " ❯ 2. Sonnet                   Sonnet 4.6 · Best for everyday tasks",
                   "   3. Haiku                    Haiku 4.5 · Fastest for quick answers", "", "   ◐ Medium effort (default) ← → to adjust", "", " Enter to confirm · Esc to exit"]),
        ("review", [String(repeating: "─", count: 72), "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
                    "│ ● Según la doc de Meta (Embedded Signup v4), en el modo coexistencia el navegador recibe el id de la cuenta de",
                    "│   WhatsApp Business (waba_id), pero NO el id del número (phone_number_id). La spec 18a exige ese id del número para",
                    "│   conectar en todos los modos. ¿Qué hacemos?", "  → Opcional + lo busca el servidor (Recomendado)",
                    "│ ● La doc de Meta v4 también dice que el modo (número nuevo o coexistencia) lo fija la configuración de Login for",
                    "│   Business (config_id), no un parámetro del navegador como asume la spec. Para ofrecer los dos modos haría falta un",
                    "│   segundo config_id: una sexta variable de entorno y otra configuración en la app de Meta. Es la pregunta abierta de",
                    "│   la §10. ¿Qué hacemos?", "  → Dejarlo para EP2026-363 (Recomendado)", "",
                    "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]),
        ("review-warning", [String(repeating: "─", count: 72), "←  ☒ Platforms  ☐ Database  ☒ Notes  ✔ Submit  →", "", "Review your answers", "", "⚠ You have not answered all questions", "",
                            "│ ● Which platforms should the release support?", "  → macOS, iOS",
                            "│ ● Which database should we use for the cache layer that sits in front of the billing service when", "│   it is under load?",
                            "│ ● Anything else?", "  → Keep the old endpoint alive until the mobile app ships the new client, then remove it", "    in the next release.", "",
                            "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel"]),
    ]

    func testTheEstimateIsCloseToTheCardAsLaidOut() throws {
        for width in [542.0, 470.0] {
            for (name, rows) in fixtures {
                let prompt = try XCTUnwrap(AgentPrompt.parse(rows.joined(separator: "\n")), name)
                let card = AgentPromptCard(prompt: prompt, accessory: AnyView(Color.clear.frame(width: 118, height: 22)))
                    .frame(width: width).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
                let host = NSHostingView(rootView: card.fixedSize(horizontal: false, vertical: true))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                let real = host.fittingSize.height
                let estimate = PromptCardText.estimatedHeight(prompt, width: width, hasAccessory: true)
                XCTAssertEqual(estimate, real, accuracy: 4, "\(name) at \(Int(width)) pt: estimated \(estimate), laid out \(real)")
            }
        }
    }
}

/// The review step's buttons are the options of the dialog: a click on one answers as a click on its row does.
@MainActor
final class PromptCardReviewClickTests: XCTestCase {
    private final class Answers { var chosen: [Int] = [] }

    private let rows = [String(repeating: "─", count: 72), "←  ☒ Id número  ☒ Modo Meta  ✔ Submit  →", "", "Review your answers", "",
                        "│ ● Which number do we connect?", "  → Optional, the server looks it up (Recommended)",
                        "│ ● Which mode does the signup use?", "  → Leave it for later (Recommended)", "",
                        "Ready to submit your answers?", "", "❯ 1. Submit answers", "  2. Cancel", "", "Enter to select · ↑/↓ to navigate · Esc to cancel"]

    private func shown(busy: Bool, answers: Answers, width: CGFloat = 440) throws -> (NSWindow, CGFloat) {
        let prompt = try XCTUnwrap(AgentPrompt.parse(rows.joined(separator: "\n")))
        let card = AgentPromptCard(prompt: prompt, busy: busy, onChoose: { answers.chosen.append($0) }).frame(width: width)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: card.fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        let height = host.fittingSize.height
        window.setContentSize(NSSize(width: width, height: height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (window, height)
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

    func testTheButtonsAnswerAsTheOptionsDo() throws {
        let answers = Answers()
        let (window, height) = try shown(busy: false, answers: answers)
        // The buttons are the card's last row: 30 pt tall over the card's bottom edge (7 pt), the one that sends taking what the other leaves.
        let y = height - 7 - 15
        click(window, at: NSPoint(x: 100, y: y))
        XCTAssertEqual(answers.chosen, [0], "«Enviar respuestas» is the first option.")
        click(window, at: NSPoint(x: 440 - 6 - 30, y: y))
        XCTAssertEqual(answers.chosen, [0, 1], "«Cancelar» is the second.")
        window.close()
    }

    func testNothingIsSentWhileTheKeysOfAnAnswerAreOnTheirWay() throws {
        let answers = Answers()
        let (window, height) = try shown(busy: true, answers: answers)
        click(window, at: NSPoint(x: 100, y: height - 7 - 15))
        XCTAssertEqual(answers.chosen, [], "The options wait for the screen to show the result.")
        window.close()
    }
}
