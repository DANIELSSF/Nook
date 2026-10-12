import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The welcome of a fresh Claude (`ClaudeWelcomeView.swift`): its words, its creature, that it fits every size of island and of text without cutting anything,
/// and the renders for review (which run only when NOOK_RENDER_DIR is set).
@MainActor
final class ClaudeWelcomeTests: XCTestCase {
    private let work = ClaudeBanner(version: "2.1.293", model: "Opus 5.5", effort: "xhigh", plan: "Claude Team", directory: "~/Documents/Examples/New project")
    private let personal = ClaudeBanner(version: "2.1.290", model: "Sonnet 5.5", effort: "high", plan: "Claude Max", directory: "~/Documents/app")

    // MARK: Words

    func testTheEffortIsSaidInTheIslandsOwnWords() {
        XCTAssertEqual(ClaudeWelcomeText.effort(work, live: nil), "Esfuerzo muy alto", "The banner's level, in the picker's words.")
        XCTAssertEqual(ClaudeWelcomeText.effort(work, live: .low), "Esfuerzo bajo", "What Claude reports now beats what the banner started with.")
        XCTAssertEqual(ClaudeWelcomeText.effort(ClaudeBanner(version: "1", effort: "turbo"), live: nil), "Esfuerzo turbo", "A level Nook does not know keeps Claude's word.")
        XCTAssertNil(ClaudeWelcomeText.effort(ClaudeBanner(version: "1"), live: nil))
        XCTAssertEqual(ClaudeWelcomeText.version(work), "v2.1.293")
    }

    func testAWorkAccountAndAPersonalOneWearDifferentSymbols() {
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("Claude Team"), "person.2.fill")
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("Claude Max"), "person.fill")
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("Claude Pro"), "person.fill")
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("Claude Enterprise"), "building.2.fill")
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("API Usage Billing"), "key.fill")
        XCTAssertEqual(ClaudeWelcomeText.planSymbol("Something else"), "person.crop.circle.fill")
        for plan in ["Claude Team", "Claude Max", "Claude Pro", "Claude Enterprise", "API Usage Billing", "Something else"] {
            XCTAssertNotNil(NSImage(systemSymbolName: ClaudeWelcomeText.planSymbol(plan), accessibilityDescription: nil), "\(plan): the system has the symbol.")
        }
        XCTAssertNotEqual(ClaudeWelcomeText.planSymbol("Claude Team"), ClaudeWelcomeText.planSymbol("Claude Max"), "Work and personal are told apart before the words are read.")
    }

    func testTheFolderIsSplitSoItsNameCanStandOut() {
        XCTAssertTrue(ClaudeWelcomeText.folder("~/Documents/Examples/New project") == ("~/Documents/ChatGPT/", "New project"))
        XCTAssertTrue(ClaudeWelcomeText.folder("~/Documents/app") == ("~/Documents/", "app"))
        XCTAssertTrue(ClaudeWelcomeText.folder("~/Documents/app/") == ("~/Documents/", "app"), "A trailing slash is not part of the name.")
        XCTAssertTrue(ClaudeWelcomeText.folder("~") == ("", "~"))
        XCTAssertTrue(ClaudeWelcomeText.folder("/") == ("", "/"))
        XCTAssertTrue(ClaudeWelcomeText.folder("app") == ("", "app"))
        XCTAssertTrue(ClaudeWelcomeText.folder("/Users/me/work") == ("/Users/me/", "work"))
    }

    func testOnlyClaudesOwnGreySuggestionIsASuggestion() {
        XCTAssertEqual(ClaudeWelcomeText.suggestion(from: "Try \"write a test for <filepath>\""), "write a test for <filepath>")
        XCTAssertEqual(ClaudeWelcomeText.suggestion(from: "  Try “fix the lint errors”  "), "fix the lint errors", "Curly quotes too.")
        XCTAssertNil(ClaudeWelcomeText.suggestion(from: "revisa por qué falla el build"), "What somebody typed in Claude's own box is not Claude's suggestion.")
        XCTAssertNil(ClaudeWelcomeText.suggestion(from: "Try the new thing"), "Without its quotes it is a sentence, not a suggestion.")
        XCTAssertNil(ClaudeWelcomeText.suggestion(from: "Try \"\""))
        XCTAssertNil(ClaudeWelcomeText.suggestion(from: nil))
        XCTAssertNil(ClaudeWelcomeText.suggestion(from: ""))
    }

    func testVoiceOverGetsTheWholeWelcomeInOneSentence() {
        let spoken = ClaudeWelcomeText.spoken(work, effort: nil)
        for part in ["Claude Code 2.1.293", "Opus 5.5", "esfuerzo muy alto", "Claude Team", "~/Documents/Examples/New project"] {
            XCTAssertTrue(spoken.contains(part), "\(part) is in «\(spoken)».")
        }
    }

    // MARK: The creature

    func testTheCreatureIsSymmetricAndKeepsEverythingInsideItsGrid() {
        let width = CritterGeometry.width, height = CritterGeometry.height
        let all = [CritterGeometry.body] + CritterGeometry.arms + CritterGeometry.feet + CritterGeometry.eyes
        for rect in all {
            XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertLessThanOrEqual(rect.maxX, width)
            XCTAssertGreaterThanOrEqual(rect.minY, 0); XCTAssertLessThanOrEqual(rect.maxY, height)
        }
        func mirrored(_ rects: [CGRect]) -> [CGRect] { rects.map { CGRect(x: width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) } }
        func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
            a.count == b.count && a.allSatisfy { rect in b.contains { abs($0.minX - rect.minX) < 0.001 && abs($0.minY - rect.minY) < 0.001 && abs($0.width - rect.width) < 0.001 } }
        }
        XCTAssertTrue(same(CritterGeometry.eyes, mirrored(CritterGeometry.eyes)), "Two eyes, one the other's mirror.")
        XCTAssertTrue(same(CritterGeometry.feet, mirrored(CritterGeometry.feet)), "Four feet, two and two.")
        XCTAssertTrue(same(CritterGeometry.arms, mirrored(CritterGeometry.arms)), "A stub on each side.")
        for eye in CritterGeometry.eyes { XCTAssertTrue(CritterGeometry.body.contains(eye), "The eyes are on the body, a glance included.") }
        for eye in CritterGeometry.eyes.map({ $0.offsetBy(dx: CritterGeometry.glance, dy: 0) }) + CritterGeometry.eyes.map({ $0.offsetBy(dx: -CritterGeometry.glance, dy: 0) }) {
            XCTAssertTrue(CritterGeometry.body.contains(eye), "…and so are they after a glance to either side.")
        }
        XCTAssertEqual(CritterGeometry.eyeLine, CritterGeometry.eyes[0].midY, accuracy: 0.001, "A blink closes the eyes around their own middle.")
    }

    func testTheSizesFollowTheChatTextWithoutRunningAway() {
        for size in stride(from: DisplaySettings.chatSizeRange.lowerBound, through: DisplaySettings.chatSizeRange.upperBound, by: 1) {
            XCTAssertGreaterThanOrEqual(ClaudeWelcomeMetrics.body(chatSize: size), 9, "\(size): still legible.")
            XCTAssertLessThanOrEqual(ClaudeWelcomeMetrics.headline(chatSize: size), 24, "\(size): still a headline, not a banner.")
            XCTAssertGreaterThan(ClaudeWelcomeMetrics.headline(chatSize: size), ClaudeWelcomeMetrics.body(chatSize: size), "\(size): the model is what stands out.")
            XCTAssertLessThan(ClaudeWelcomeMetrics.minimumHeight(chatSize: size), ComposerMetrics.minConversation, "\(size): the smallest layout fits where the conversation is smallest.")
        }
        XCTAssertEqual(ClaudeWelcomeMetrics.headline(chatSize: DisplaySettings.defaultChatSize), 16)
    }

    func testTheWarningsCardStaysInsideTheSpaceItHangsIn() {
        XCTAssertEqual(StartupWarningsNotice.cardShift(cardWidth: 470, pillEdge: nil), 0, "A pill at the end of its row: the card hangs from it as it always did.")
        XCTAssertEqual(StartupWarningsNotice.cardShift(cardWidth: 470, pillEdge: 520), 0, "Room enough to its left.")
        XCTAssertEqual(StartupWarningsNotice.cardShift(cardWidth: 470, pillEdge: 300), 170, "A pill nearer the space's start moves the card right by what would have stuck out.")
        XCTAssertEqual(StartupWarningsNotice.cardShift(cardWidth: 410, pillEdge: 410), 0)
    }

    // MARK: Fit

    /// The conversation's room in an island of this size: the pane less the composer, as `SessionPane` lays it out (one line of field).
    private func room(width: CGFloat, height: CGFloat, neck: CGFloat = 28) -> CGSize {
        let pane = height - neck - PaneLayout.tabRowHeight
        let composer = ComposerMetrics.composerHeight(lines: 1, size: DisplaySettings.defaultInputSize)
        return CGSize(width: width - 2 * 15, height: pane - ComposerMetrics.bottomInset - composer - ComposerMetrics.spacing)
    }

    /// The five island sizes the settings can make (the preset sizes and the least), as the room each leaves the conversation.
    private var rooms: [(name: String, size: CGSize)] {
        let normalHeight = NotchGeometry.expandedHeight(topInset: 28), normalWidth = NotchGeometry.expandedWidth
        return [("minima", room(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.minExpandedHeight(topInset: 28))),
                ("compacta", room(width: normalWidth + IslandPreset.compact.widthExtra, height: normalHeight + IslandPreset.compact.heightExtra)),
                ("normal", room(width: normalWidth, height: normalHeight)),
                ("amplia", room(width: normalWidth + IslandPreset.wide.widthExtra, height: normalHeight + IslandPreset.wide.heightExtra)),
                ("alta", room(width: normalWidth, height: normalHeight + IslandPreset.tall.heightExtra))]
    }

    private func welcome(_ banner: ClaudeBanner, chat: Double, suggestion: String? = "Try \"write a test for <filepath>\"", warnings: [ClaudeStartupWarning] = [],
                         open: Bool = false, look: ClaudeCritterLook = .resting, size: CGSize) -> some View {
        ClaudeWelcome(banner: banner, effort: nil, suggestion: suggestion, warnings: warnings, chatSize: chat, islandVisible: true, animated: false, warningsOpen: open, keepsOpen: open, look: look)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
    }

    private func bitmap<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        return rep
    }

    /// The box, in pixels, of everything on the image that is not black (or the faint light behind the creature).
    private func contentBounds(_ rep: NSBitmapImageRep) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 0.42 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testTheWelcomeFitsEveryIslandAtEveryTextSizeWithoutCuttingAnything() throws {
        let sizes: [Double] = [9, 11, 14, 18]
        for banner in [work, personal] {
            for (name, size) in rooms where size.height >= ClaudeWelcomeMetrics.minimumHeight(chatSize: 18) {
                for chat in sizes {
                    let rep = try bitmap(welcome(banner, chat: chat, size: size), size: size)
                    let box = try XCTUnwrap(contentBounds(rep), "\(name) / \(chat): something is drawn.")
                    let scale = CGFloat(rep.pixelsWide) / size.width
                    let label = "\(banner.plan ?? "") \(name) \(Int(size.width))x\(Int(size.height)) chat \(Int(chat))"
                    XCTAssertGreaterThan(box.minX, 0, "\(label): not cut at the left.")
                    XCTAssertGreaterThan(box.minY, 0, "\(label): not cut at the top.")
                    XCTAssertLessThan(box.maxX, CGFloat(rep.pixelsWide), "\(label): not cut at the right.")
                    XCTAssertLessThan(box.maxY, CGFloat(rep.pixelsHigh), "\(label): not cut at the bottom.")
                    XCTAssertGreaterThanOrEqual(box.minX / scale, 4, "\(label): a margin at the left.")
                    XCTAssertLessThanOrEqual(box.maxX / scale, size.width - 4, "\(label): a margin at the right.")
                    XCTAssertGreaterThanOrEqual(box.minY / scale, 2, "\(label): a margin at the top.")
                    XCTAssertLessThanOrEqual(box.maxY / scale, size.height - 2, "\(label): a margin at the bottom.")
                }
            }
        }
    }

    // MARK: In the pane

    private let rule = String(repeating: "─", count: 80)
    private let warningLines = ["Permission allow rule (.claude/settings.json): Bash(pnpm * exec prisma format*) has a wildcard before the rest of the command.", "",
                                "Permission allow rule (.claude/settings.json): Bash(pnpm * exec prisma generate*) has a wildcard before the rest of the command.", ""]

    /// Sample's `claude2` as it opened (the screenshot): the banner, nothing said, the box with its grey suggestion. `said` adds a conversation.
    private func freshScreen(warnings: Bool = false, said: Bool = false) -> String {
        let banner = [" ▐▛███▛█   Claude Code v2.1.293", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Examples/New project"]
        let talk = said ? ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build."] : []
        return ((warnings ? warningLines : []) + banner + talk + ["", rule, "❯ " + (said ? "" : "Try \"write a test for <filepath>\""), rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"]).joined(separator: "\n")
    }

    private func makeModel() -> AppModel { AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-welcome-" + UUID().uuidString)!) }

    private func session(_ model: AppModel, text: String) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: text)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    private struct Island: View {
        var model: AppModel
        var session: TerminalSession
        var width = NotchGeometry.expandedWidth
        var height = NotchGeometry.expandedHeight(topInset: 32)
        var warningsOpen = false
        var dismissals = RecapSeenStore(defaults: nil)
        var body: some View {
            VStack(spacing: 0) {
                Color.white.opacity(0.05).frame(height: 32)
                Color.white.opacity(0.025).frame(height: 30)
                SessionPane(model: model, session: session, warningsOpen: warningsOpen, dismissals: dismissals).id(session.id)
            }.frame(width: width, height: height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
                .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true).environment(\.nookTintedGlass, false)
        }
    }

    private func mount<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private var islandSize: NSSize { NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32)) }

    /// The welcome marks the whole conversation as a pointer hole; the strip marks nothing (without warnings it has no card to).
    private func welcomeFrame(in window: NSWindow) -> NSRect? {
        PointerHoles.frames(in: window).first { $0.width > 400 && $0.height > 40 }
    }

    func testAFreshClaudeGreetsInTheConversationsPlaceAndTheStripTakesOverOnceSomethingIsSaid() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        XCTAssertTrue(fresh.awaitsFirstMessage)
        let (window, _) = mount(Island(model: model, session: fresh), size: islandSize)
        let hero = try XCTUnwrap(welcomeFrame(in: window), "The welcome stands over the conversation.")
        XCTAssertGreaterThan(hero.minY, ComposerMetrics.composerHeight(lines: 1, size: 13), "Above the composer.")

        // Something was said: the conversation is under way, so the strip is what shows and the welcome has gone.
        let talking = session(model, text: freshScreen(said: true))
        XCTAssertFalse(talking.awaitsFirstMessage)
        let (window2, _) = mount(Island(model: model, session: talking), size: islandSize)
        XCTAssertNil(welcomeFrame(in: window2), "No welcome over a conversation.")
    }

    func testAMessageJustSentFromNookEndsTheWelcomeAtOnce() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        let (window, host) = mount(Island(model: model, session: fresh), size: islandSize)
        XCTAssertNotNil(welcomeFrame(in: window))
        fresh.showPending("Revisa por qué falla el build de la API.")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(fresh.awaitsFirstMessage)
        XCTAssertNil(welcomeFrame(in: window), "The welcome does not wait for Claude to answer: nothing flashes after a send.")
    }

    func testTheWelcomeStaysOutOfTheWayOfWhatMattersMore() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        // Too small a conversation for even its smallest layout: the strip is what the room allows.
        let tiny = NSSize(width: NotchGeometry.minExpandedWidth, height: 150)
        let (window, _) = mount(Island(model: model, session: fresh, width: tiny.width, height: tiny.height), size: tiny)
        XCTAssertNil(welcomeFrame(in: window), "No room for the welcome.")
        // A shell's tab never has one.
        let shell = TerminalSession(tab: TerminalTabSnapshot(windowID: 1, windowTitle: "t", index: 1, tty: "/dev/ttys098", customTitle: "", processes: ["login", "-zsh"], busy: false, selected: true, text: "developer % ls"),
                                    backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [shell]; model.selectedID = shell.id
        let (shellWindow, _) = mount(Island(model: model, session: shell), size: islandSize)
        XCTAssertNil(welcomeFrame(in: shellWindow))
    }

    func testTheStartupWarningsStayReachableFromTheWelcome() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen(warnings: true))
        XCTAssertEqual(fresh.startupWarnings.count, 2)
        // Closed: the pill is in the welcome's first row; open: the card hangs over it. Either way the welcome is the one on show.
        let (closedWindow, _) = mount(Island(model: model, session: fresh), size: islandSize)
        XCTAssertNotNil(welcomeFrame(in: closedWindow))
        let (openWindow, _) = mount(Island(model: model, session: fresh, warningsOpen: true), size: islandSize)
        XCTAssertGreaterThan(PointerHoles.frames(in: openWindow).count, PointerHoles.frames(in: closedWindow).count, "The open card marks itself too: it hangs over the conversation.")
        // The dismissal is the strip's own memory: dismissed warnings leave the welcome without a pill, and come back only when Claude says something else.
        let dismissals = RecapSeenStore(defaults: nil)
        dismissals.dismiss(fresh.startupWarnings, in: fresh.id)
        XCTAssertTrue(dismissals.areDismissed(fresh.startupWarnings, in: fresh.id))
    }

    func testClaudesPanelAndAQuestionWinOverTheWelcome() throws {
        // A /usage sent from the welcome is no conversation: its bubble goes after a while and the session waits for a first message again, with the panel open.
        let model = makeModel()
        let banner = [" ▐▛███▛█   Claude Code v2.1.293", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Examples/New project"]
        let panel = ["   Settings   Status   Config   Usage   Stats", "", "   Current session", "   █████████▎" + String(repeating: " ", count: 40) + " 25% used",
                     "   Resets 8:59pm (America/Bogota)", "", "   Esc to cancel"]
        let withPanel = session(model, text: (banner + [""] + panel).joined(separator: "\n"))
        XCTAssertNotNil(withPanel.panel, "The fixture is a Claude with its usage panel open.")
        XCTAssertTrue(withPanel.awaitsFirstMessage, "…and nothing said: the case the welcome must not take for its own.")
        let (panelWindow, _) = mount(Island(model: model, session: withPanel), size: islandSize)
        XCTAssertNil(welcomeFrame(in: panelWindow), "The panel is what shows.")
        // A question Claude has open wins as well.
        let question = (banner + ["", "⏺ Bash(rm -rf build)", " Bash command", "", "   rm -rf build", "", " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]).joined(separator: "\n")
        let asking = session(model, text: question)
        XCTAssertNotNil(asking.prompt)
        let (questionWindow, _) = mount(Island(model: model, session: asking), size: islandSize)
        XCTAssertNil(welcomeFrame(in: questionWindow), "A question's card wins over the welcome.")
    }

    func testTheChipTakesClaudesExampleWithoutItsWrapper() throws {
        XCTAssertEqual(ClaudeWelcomeText.suggestion(from: "Try \"write a test for <filepath>\""), "write a test for <filepath>")
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        XCTAssertEqual(fresh.suggestion, "Try \"write a test for <filepath>\"", "The session mirrors the box's grey text as it is.")
    }

    // MARK: The suggestion is said once

    /// A window of this size on the screen list, far off every display: its accessibility nodes exist, and a click or a lookup finds what is in it.
    private func shown<V: View>(_ view: V, size: NSSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private let chipLabel = "Usar la sugerencia de Claude"

    func testClaudesSuggestionIsOnTheWelcomesChipAndNotAlsoInTheField() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        XCTAssertEqual(fresh.suggestion, "Try \"write a test for <filepath>\"")
        let (window, host) = shown(Island(model: model, session: fresh), size: islandSize)
        defer { window.close() }
        XCTAssertNotNil(welcomeFrame(in: window), "The welcome is up.")
        XCTAssertNotNil(AccessibilityLookup.center(of: chipLabel, in: window), "…with Claude's suggestion as its chip.")
        let field = try XCTUnwrap(find(ComposerTextView.self, in: host))
        XCTAssertEqual(field.placeholder, "Mensaje o /comando para Claude…", "The field has the placeholder it has with no suggestion: the suggestion is on screen once.")
    }

    func testTheTagThatSaysTabTakesTheSuggestionIsBesideTheFieldOnlyWhereTheFieldShowsIt() {
        typealias Pane = SessionPane
        XCTAssertTrue(Pane.showsSuggestionTag(draft: "", recording: false, suggestion: "ok avísame", onWelcome: false), "The suggestion is the field's placeholder: ⇥ takes it.")
        XCTAssertFalse(Pane.showsSuggestionTag(draft: "", recording: false, suggestion: "Try \"x\"", onWelcome: true), "The welcome's chip has it, with its own ⇥.")
        XCTAssertFalse(Pane.showsSuggestionTag(draft: "", recording: false, suggestion: nil, onWelcome: false), "Nothing to take.")
        XCTAssertFalse(Pane.showsSuggestionTag(draft: "hola", recording: false, suggestion: "ok", onWelcome: false), "Something is typed.")
        XCTAssertFalse(Pane.showsSuggestionTag(draft: "", recording: true, suggestion: "ok", onWelcome: false), "Dictating.")
    }

    func testTheFieldHasTheSuggestionAgainWhenTheWelcomeIsNotThere() throws {
        let model = makeModel()
        // Too little room for the welcome: the strip is what shows, and the suggestion is the field's, as it always was.
        let fresh = session(model, text: freshScreen())
        let tiny = NSSize(width: NotchGeometry.minExpandedWidth, height: 150)
        let (window, host) = shown(Island(model: model, session: fresh, width: tiny.width, height: tiny.height), size: tiny)
        defer { window.close() }
        XCTAssertNil(welcomeFrame(in: window))
        XCTAssertNil(AccessibilityLookup.center(of: chipLabel, in: window))
        let field = try XCTUnwrap(find(ComposerTextView.self, in: host))
        XCTAssertEqual(field.placeholder, "Try \"write a test for <filepath>\"")
    }

    func testTheSuggestionIsOnScreenExactlyOnceAtEveryHeightOfIsland() throws {
        // Where the welcome has the room for its chip the field does not say the suggestion; where its layout has none (a smaller one) the field does.
        for height in [150.0, 170, 185, 200, 215, 235, 266, 330] {
            let model = makeModel()
            let fresh = session(model, text: freshScreen())
            let size = NSSize(width: NotchGeometry.expandedWidth, height: height)
            let (window, host) = shown(Island(model: model, session: fresh, width: size.width, height: size.height), size: size)
            defer { window.close() }
            let chip = AccessibilityLookup.center(of: chipLabel, in: window) != nil
            let field = try XCTUnwrap(find(ComposerTextView.self, in: host))
            let inField = field.placeholder == fresh.suggestion
            XCTAssertNotEqual(chip, inField, "Island \(Int(height)) pt tall: the suggestion is on the chip (\(chip)) or in the field (\(inField)), never both and never neither.")
        }
    }

    func testTheChipTakesTheExampleIntoTheFieldAndEnterOnAnEmptyFieldDoesTheSame() throws {
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        let (window, host) = shown(Island(model: model, session: fresh), size: islandSize)
        defer { window.close() }
        let field = try XCTUnwrap(find(ComposerTextView.self, in: host))
        let chip = try XCTUnwrap(AccessibilityLookup.center(of: chipLabel, in: window), "The chip is on the welcome.")
        func click(at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: islandSize.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        click(at: chip)
        XCTAssertEqual(field.string, "write a test for <filepath>", "The example, without Claude's «Try» and its quotes.")
        XCTAssertEqual(fresh.draft, "write a test for <filepath>")
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func save<V: View>(_ view: V, size: CGSize, to path: String) throws {
        let rep = try bitmap(view, size: size)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func url(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    private let threeWarnings = [ClaudeStartupWarning(source: ".claude/settings.json", text: "Permission allow rule (.claude/settings.json): Bash(pnpm * exec prisma format*) has a wildcard before the rest of the command."),
                                 ClaudeStartupWarning(source: ".claude/settings.json", text: "Permission allow rule (.claude/settings.json): Bash(pnpm * exec prisma generate*) has a wildcard before the rest of the command."),
                                 ClaudeStartupWarning(source: ".claude/settings.json", text: "Permission allow rule (.claude/settings.json): Bash(pnpm * exec prisma migrate*) has a wildcard before the rest of the command.")]

    /// The welcome in the real pane, as the island lays it out: Sample's `claude2` as it opened, with and without warnings, in the usual island and in the least one,
    /// and the same session once something has been said.
    func testRenderTheWelcomeInThePane() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let size = islandSize
        let small = NSSize(width: NotchGeometry.minExpandedWidth, height: NotchGeometry.minExpandedHeight(topInset: 32))
        let wide = NSSize(width: NotchGeometry.expandedWidth + IslandPreset.wide.widthExtra, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.wide.heightExtra)
        let tall = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32) + IslandPreset.tall.heightExtra)
        let fresh = session(model, text: freshScreen())
        try save(Island(model: model, session: fresh), size: size, to: url(directory, "welcome-pane.png"))
        try save(Island(model: model, session: fresh, width: small.width, height: small.height), size: small, to: url(directory, "welcome-pane-small.png"))
        try save(Island(model: model, session: fresh, width: wide.width, height: wide.height), size: wide, to: url(directory, "welcome-pane-wide.png"))
        try save(Island(model: model, session: fresh, width: tall.width, height: tall.height), size: tall, to: url(directory, "welcome-pane-tall.png"))
        let warned = session(model, text: freshScreen(warnings: true))
        try save(Island(model: model, session: warned), size: size, to: url(directory, "welcome-pane-warnings.png"))
        try save(Island(model: model, session: warned, warningsOpen: true), size: size, to: url(directory, "welcome-pane-warnings-open.png"))
        try save(Island(model: model, session: warned, width: small.width, height: small.height), size: small, to: url(directory, "welcome-pane-warnings-small.png"))
        let talking = session(model, text: freshScreen(warnings: true, said: true))
        try save(Island(model: model, session: talking), size: size, to: url(directory, "welcome-pane-after.png"))
        // The strip's own notice, open: it hangs from the pill at the strip's end, as it always did.
        try save(Island(model: model, session: talking, warningsOpen: true), size: size, to: url(directory, "welcome-pane-after-open.png"))
    }

    /// The three things this batch draws (the welcome, a tip, the usage card) in the whole island with the system in its light appearance: the island is black either
    /// way, so each is the same as in the dark one.
    func testRenderTheIslandInTheLightSystemAppearance() throws {
        let directory = try renderDirectory()
        let model = makeModel()
        let fresh = session(model, text: freshScreen())
        let size = model.islandSize
        func island(_ scheme: ColorScheme) -> some View {
            NookPanel(model: model).environment(\.colorScheme, scheme).environment(\.nookTintedGlass, false).environment(\.nookTipPinned, "mode")
        }
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let host = NSHostingView(rootView: island(scheme))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            for _ in 0..<4 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.cacheDisplay(in: host.bounds, to: rep)
                if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
                rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            }
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: url(directory, "island-\(name)-welcome-and-tip.png")))
        }
        _ = fresh
    }

    /// The welcome in each island's room, at the default text size and at the largest, for the work account and the personal one.
    func testRenderTheWelcomeInEveryRoom() throws {
        let directory = try renderDirectory()
        for (name, size) in rooms {
            for chat in [9.0, 11.0, 14.0, 18.0] {
                try save(welcome(work, chat: chat, size: size), size: size, to: url(directory, "welcome-\(name)-chat\(Int(chat)).png"))
            }
        }
        let normal = room(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        try save(welcome(personal, chat: 11, size: normal), size: normal, to: url(directory, "welcome-personal.png"))
        try save(welcome(personal, chat: 11, suggestion: nil, size: normal), size: normal, to: url(directory, "welcome-no-suggestion.png"))
        try save(welcome(work, chat: 11, warnings: threeWarnings, size: normal), size: normal, to: url(directory, "welcome-warnings.png"))
        try save(welcome(work, chat: 11, warnings: threeWarnings, open: true, size: CGSize(width: normal.width, height: 330)), size: CGSize(width: normal.width, height: 330), to: url(directory, "welcome-warnings-open.png"))
        try save(welcome(work, chat: 11, look: .blinking, size: normal), size: normal, to: url(directory, "welcome-blink.png"))
        try save(welcome(work, chat: 11, look: .glancing, size: normal), size: normal, to: url(directory, "welcome-glance.png"))
        let odd = ClaudeBanner(version: "2.1.293", model: "Claude Fable 5.1 (1M context)", effort: nil, plan: "API Usage Billing", directory: "~/Documents/Repositorios_sampleapp/app-tareas/apps/api/very-long-folder-name")
        try save(welcome(odd, chat: 11, size: normal), size: normal, to: url(directory, "welcome-odd.png"))
        let bare = ClaudeBanner(version: "2.1.293")
        try save(welcome(bare, chat: 11, size: normal), size: normal, to: url(directory, "welcome-bare.png"))
    }
}
