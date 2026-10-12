import AppKit
import XCTest
import SwiftUI
@testable import Nook

/// What the island says of a Claude session's start and state: the words of the banner's strip and of the startup warnings' notice, which
/// warnings are one, the dismissals, the permission mode's chip (its words and its colours) and the wait for background agents in Spanish.
final class SessionInfoTests: XCTestCase {
    // MARK: The banner's words

    func testEffortIsToldAsTheChipTellsIt() {
        XCTAssertEqual(SessionInfoText.effort("xhigh"), "Muy alto")
        XCTAssertEqual(SessionInfoText.effort("MAX"), "Máximo")
        XCTAssertEqual(SessionInfoText.effort("ultra"), "Ultra", "A level Nook does not know keeps Claude's word.")
        let banner = ClaudeBanner(version: "2.1.290", model: "Sonnet 5.5", effort: "xhigh", plan: "Claude Team", directory: "~/Documents/app")
        XCTAssertEqual(SessionInfoText.effortTitle(banner, live: nil), "Muy alto", "The level the session started with.")
        XCTAssertEqual(SessionInfoText.effortTitle(banner, live: .low), "Bajo", "What Claude reported since wins over the banner.")
        XCTAssertNil(SessionInfoText.effortTitle(ClaudeBanner(version: "2"), live: nil))
    }

    func testTheDetailsListWhatTheBannerSaid() {
        let banner = ClaudeBanner(version: "2.1.290", model: "Sonnet 5.5", effort: "xhigh", plan: "Claude Team", directory: "~/Documents/app")
        XCTAssertEqual(SessionInfoText.details(banner, effort: nil),
                       ["Claude Code 2.1.290", "Modelo: Sonnet 5.5", "Esfuerzo: Muy alto", "Plan: Claude Team", "Carpeta: ~/Documents/app"])
        XCTAssertEqual(SessionInfoText.details(ClaudeBanner(version: "2.1.290", directory: "/tmp/x"), effort: .high), ["Claude Code 2.1.290", "Esfuerzo: Alto", "Carpeta: /tmp/x"],
                       "What the banner did not say is left out.")
    }

    func testTheWarningsNoticeCountsInSpanish() {
        XCTAssertEqual(SessionInfoText.warningsLabel(1), "1 aviso de configuración")
        XCTAssertEqual(SessionInfoText.warningsLabel(3), "3 avisos de configuración")
        XCTAssertEqual(SessionInfoText.warningsShortLabel(1), "1 aviso")
        XCTAssertEqual(SessionInfoText.warningsShortLabel(12), "12 avisos")
    }

    func testTheStripFollowsTheChatTextSize() {
        XCTAssertEqual(SessionStrip.fontSize(chatSize: 11), 10)
        XCTAssertEqual(SessionStrip.fontSize(chatSize: 9), 9, "Never under 9 points.")
        XCTAssertEqual(SessionStrip.fontSize(chatSize: 18), 15, "Nor over 15.")
        XCTAssertEqual(SessionStrip.height(chatSize: 11), 17)
        XCTAssertGreaterThan(SessionStrip.height(chatSize: 16), SessionStrip.height(chatSize: 11))
        XCTAssertEqual(SessionStrip.room(chatSize: 11), SessionStrip.height(chatSize: 11) + SessionStrip.topInset)
    }

    // MARK: The warnings

    private let sentence = "has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean, or only use * after the subcommand."

    private func warning(_ rule: String, kind: String = "allow", source: String = ".claude/settings.json") -> ClaudeStartupWarning {
        ClaudeStartupWarning(source: source, text: "Permission \(kind) rule (\(source)): \(rule) \(sentence)")
    }

    func testAPermissionWarningIsTakenApart() {
        let parts = StartupWarningParts(warning("Bash(pnpm --filter * exec prisma format*)"))
        XCTAssertEqual(parts.title, "Regla de permiso «allow»")
        XCTAssertEqual(parts.source, ".claude/settings.json")
        XCTAssertEqual(parts.rule, "Bash(pnpm --filter * exec prisma format*)")
        XCTAssertEqual(parts.message, sentence, "The sentence goes on from the rule, whole.")
        XCTAssertEqual(StartupWarningParts(warning("Bash(rm *)", kind: "deny")).title, "Regla de permiso «deny»")
        XCTAssertEqual(StartupWarningParts(warning("Read(./.env)", kind: "ask")).title, "Regla de permiso «ask»")
    }

    func testARuleWithParenthesesInsideIsOneRule() {
        let parts = StartupWarningParts(warning("Bash(git commit -m \"fix (parser)\" *)"))
        XCTAssertEqual(parts.rule, "Bash(git commit -m \"fix (parser)\" *)")
        XCTAssertEqual(parts.message, sentence)
    }

    func testAWarningOfAnotherShapeKeepsItsWholeText() {
        let other = ClaudeStartupWarning(source: nil, text: "Permission allow rule (.claude/settings.json): The rule is odd and has no tool in front.")
        let parts = StartupWarningParts(other)
        XCTAssertNil(parts.rule, "A first word that is only a word is no rule.")
        XCTAssertEqual(parts.message, "The rule is odd and has no tool in front.")
        let unknown = StartupWarningParts(ClaudeStartupWarning(source: "settings.json", text: "Something else Claude says"))
        XCTAssertEqual(unknown.title, "Aviso de Claude")
        XCTAssertEqual(unknown.source, "settings.json")
        XCTAssertEqual(unknown.message, "Something else Claude says", "Nothing is cut from what Claude said.")
    }

    func testRulesThatShareASentenceAreOneNotice() {
        let warnings = [warning("Bash(pnpm * exec prisma format*)"), warning("Bash(pnpm * exec prisma generate*)"), warning("Bash(pnpm * exec prisma migrate*)")]
        let groups = StartupWarningGroup.groups(warnings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].first.rule, "Bash(pnpm * exec prisma format*)")
        XCTAssertEqual(groups[0].others, ["Bash(pnpm * exec prisma generate*)", "Bash(pnpm * exec prisma migrate*)"])
        XCTAssertEqual(groups[0].count, 3)
        // Another file, another kind or another sentence is another notice; so is a warning with no rule.
        let mixed = warnings.prefix(1) + [warning("Bash(a *)", source: ".claude/settings.local.json"), warning("Bash(b *)", kind: "deny"),
                                          ClaudeStartupWarning(source: nil, text: "Something else"), ClaudeStartupWarning(source: nil, text: "Something else")]
        XCTAssertEqual(StartupWarningGroup.groups(Array(mixed)).map(\.count), [1, 1, 1, 1, 1])
    }

    func testTheClipboardGetsEveryWarningAsClaudeWroteIt() {
        let warnings = [warning("Bash(a *)"), warning("Bash(b *)")]
        XCTAssertEqual(SessionInfoText.clipboardText(warnings), warnings.map(\.text).joined(separator: "\n\n"))
    }

    func testDismissingIsPerSessionAndPerText() {
        let store = RecapSeenStore(defaults: nil)
        let warnings = [warning("Bash(a *)"), warning("Bash(b *)")]
        XCTAssertFalse(store.areDismissed(warnings, in: "tab"), "Nothing is dismissed until the user says so.")
        store.dismiss(warnings, in: "tab")
        XCTAssertTrue(store.areDismissed(warnings, in: "tab"))
        XCTAssertFalse(store.areDismissed(warnings, in: "other tab"), "Another tab has its own notice.")
        XCTAssertFalse(store.areDismissed(warnings + [warning("Bash(c *)")], in: "tab"), "A new warning brings the notice back.")
        XCTAssertFalse(store.areDismissed([], in: "tab"), "No warnings, nothing to be dismissed.")
        store.dismiss([], in: "tab")
        XCTAssertTrue(store.areDismissed(warnings, in: "tab"), "Dismissing nothing changes nothing.")
    }

    func testTheDismissalsSurviveARelaunch() {
        let suite = "nook-warnings-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let warnings = [warning("Bash(a *)")]
        RecapSeenStore(defaults: defaults, key: "k").dismiss(warnings, in: "tab")
        XCTAssertTrue(RecapSeenStore(defaults: defaults, key: "k").areDismissed(warnings, in: "tab"))
    }

    // MARK: The mode

    func testEachModeHasItsWordsItsGlyphAndItsHint() {
        func style(_ kind: ClaudeMode.Kind?, _ label: String) -> ClaudeModeStyle { ClaudeModeStyle(ClaudeMode(kind: kind, label: label, hints: [])) }
        XCTAssertEqual(style(.auto, "auto mode on").title, "Auto")
        XCTAssertEqual(style(.acceptEdits, "accept edits on").title, "Aceptar ediciones")
        XCTAssertEqual(style(.plan, "plan mode on").title, "Plan")
        XCTAssertEqual(style(.bypassPermissions, "bypass permissions on").title, "Sin permisos")
        XCTAssertEqual(ClaudeModeStyle(.standard).title, "Normal")
        let kinds: [ClaudeMode.Kind?] = [.auto, .acceptEdits, .plan, .bypassPermissions]
        let symbols = kinds.map { style($0, "x").symbol } + [ClaudeModeStyle(.standard).symbol]
        XCTAssertEqual(Set(symbols).count, 5, "Each mode has its own glyph, so the colour is not all that tells them apart.")
        for symbol in symbols { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) is a symbol the system has.") }
        for chip in kinds.map({ style($0, "x") }) + [ClaudeModeStyle(.standard)] {
            XCTAssertTrue(chip.tooltip().contains("⇧⇥"), "Every tooltip says a click does what ⇧⇥ does.")
        }
    }

    func testTheDefaultModeIsAQuietChipOfItsOwn() {
        XCTAssertTrue(ClaudeMode.standard.isDefault)
        XCTAssertFalse(ClaudeMode(kind: nil, label: "yolo mode on", hints: []).isDefault, "A mode Nook does not know by name is not the default one.")
        let normal = ClaudeModeStyle(.standard), other = ClaudeModeStyle(ClaudeMode(kind: nil, label: "yolo mode on", hints: []))
        XCTAssertEqual(other.title, "Yolo mode", "…and keeps Claude's words.")
        XCTAssertLessThan(normal.wash, ClaudeModeStyle(ClaudeMode(kind: .auto, label: "auto mode on", hints: [])).wash, "The mode a session is in most of the time takes the least colour.")
        XCTAssertLessThan(normal.edge, other.edge)
        XCTAssertTrue(normal.summary.contains("te pide permiso"))
    }

    func testTheChipWaitsWhereAKeyPressWouldDoHarm() {
        XCTAssertNil(ClaudeModeStyle.block(running: true, questionOpen: false, panelOpen: false))
        XCTAssertEqual(ClaudeModeStyle.block(running: false, questionOpen: false, panelOpen: false), "La terminal está cerrada.")
        XCTAssertTrue(ClaudeModeStyle.block(running: true, questionOpen: true, panelOpen: false)?.contains("pregunta") == true,
                      "⇧⇥ would pick the option named after it in an open question's card.")
        XCTAssertTrue(ClaudeModeStyle.block(running: true, questionOpen: false, panelOpen: true)?.contains("panel") == true)
        XCTAssertEqual(ClaudeModeStyle.block(running: false, questionOpen: true, panelOpen: true), "La terminal está cerrada.", "A closed terminal is the first thing to say.")
    }

    func testTheTooltipSaysWhatTheModeDoesAndWhatAClickDoes() {
        let style = ClaudeModeStyle(ClaudeMode(kind: .plan, label: "plan mode on", hints: []))
        let lines = style.tooltip().components(separatedBy: "\n")
        XCTAssertEqual(lines.first, style.summary)
        XCTAssertEqual(lines.last, "Pulsa para pasar al siguiente modo (⇧⇥ en la terminal).")
        XCTAssertTrue(style.tooltip(needsAccessibility: true).contains("Accesibilidad"), "A Terminal tab needs the permission for the key.")
        XCTAssertFalse(style.tooltip().contains("Accesibilidad"))
        // What stands in the way replaces the invitation: pressing is not offered.
        let blocked = style.tooltip(blocked: "La terminal está cerrada.", needsAccessibility: true)
        XCTAssertTrue(blocked.hasSuffix("La terminal está cerrada."))
        XCTAssertFalse(blocked.contains("Pulsa para pasar"))
        XCTAssertFalse(blocked.contains("Accesibilidad"))
        XCTAssertEqual(ClaudeModeStyle.cycleHint, "Pasa al siguiente modo, como ⇧⇥ en la terminal.")
    }

    func testAModeNookDoesNotKnowKeepsClaudesWords() {
        let mode = ClaudeMode(kind: nil, label: "yolo mode on", hints: [])
        XCTAssertEqual(ClaudeModeStyle(mode).title, "Yolo mode")
        XCTAssertTrue(ClaudeModeStyle(mode).summary.contains("yolo mode on"))
        XCTAssertEqual(ClaudeModeStyle.plainName(of: "plan mode"), "Plan mode")
        XCTAssertEqual(ClaudeModeStyle.plainName(of: " on"), "Modo")
    }

    /// WCAG relative luminance, to hold the chip's text to the contrast it needs on the island's dark surfaces.
    private func luminance(_ c: TabRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }
    private func contrast(_ a: TabRGB, _ b: TabRGB) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testTheChipsTextReadsOnTheDarkSurfaceAndTheModesAreToldApart() {
        let named = [("auto", ClaudeModeStyle.autoColor), ("accept", ClaudeModeStyle.acceptEditsColor), ("plan", ClaudeModeStyle.planColor), ("bypass", ClaudeModeStyle.bypassColor)]
        let quiet = [("other", ClaudeModeStyle.otherColor), ("normal", ClaudeModeStyle.normalColor)]
        for (name, color) in named + quiet {
            // The lightest surface the chip stands on (the composer's flat fill, white at 7 %, over the island's black, with a margin), under its own wash
            // (13 %, or what the default mode takes, and up to the 25 % the chip lights to while it is pressed).
            let surface = TabRGB(0.09, 0.09, 0.09)
            for wash in [0.07, 0.13, 0.25] {
                XCTAssertGreaterThanOrEqual(contrast(color, surface.mixed(with: color, by: wash)), 4.5, "\(name) text on its chip (wash \(wash))")
            }
        }
        // The four named modes look different from one another, and none of the colours is the tab's mint or the notices' amber.
        for (i, first) in named.enumerated() {
            for second in named.dropFirst(i + 1) {
                let distance = abs(first.1.red - second.1.red) + abs(first.1.green - second.1.green) + abs(first.1.blue - second.1.blue)
                XCTAssertGreaterThan(distance, 0.3, "\(first.0) and \(second.0) look alike")
            }
        }
        func rgb(_ color: NSColor) -> TabRGB { let c = color.usingColorSpace(.sRGB)!; return TabRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) }
        // Nook's mint and the notices' amber, as they are on black (`NookPalette`).
        let mint = rgb(NookPalette.mintOnBlack), amber = rgb(NookPalette.amberOnBlack)
        for (name, color) in named + quiet {
            XCTAssertGreaterThan(abs(color.red - mint.red) + abs(color.green - mint.green) + abs(color.blue - mint.blue), 0.3, "\(name) looks like mint")
            XCTAssertGreaterThan(abs(color.red - amber.red) + abs(color.green - amber.green) + abs(color.blue - amber.blue), 0.3, "\(name) looks like amber")
        }
    }

    // MARK: The wait for background agents

    private func waiting(_ text: String, count: Int) -> ClaudeStatus { ClaudeStatus(glyph: "✻", text: text, working: true, background: count) }

    func testTheWaitIsToldInSpanishAndShortensInSteps() {
        XCTAssertEqual(ClaudeStatusCopy.waiting(waiting("Waiting for 3 background agents to finish", count: 3)),
                       ["Esperando a 3 agentes en segundo plano", "Esperando 3 agentes en segundo plano", "Esperando a 3 agentes", "Esperando 3 agentes", "Esperando…"])
        XCTAssertEqual(ClaudeStatusCopy.waiting(waiting("Waiting for 1 background agent to finish", count: 1)).first, "Esperando a 1 agente en segundo plano")
        XCTAssertEqual(ClaudeStatusCopy.waiting(waiting("Waiting for 2 background tasks to finish", count: 2)).first, "Esperando 2 tareas en segundo plano", "Tasks are not people: no «a».")
        XCTAssertEqual(ClaudeStatusCopy.waiting(waiting("Waiting for 1 background job to finish", count: 1)).first, "Esperando 1 trabajo en segundo plano")
    }

    func testWhatClaudePrintedAfterTheWaitGoesOnAfterIt() {
        let status = waiting("Waiting for 3 background agents to finish… (1m 2s · ↓ 3k tokens · esc to interrupt)", count: 3)
        XCTAssertEqual(ClaudeStatusCopy.waiting(status).first, "Esperando a 3 agentes en segundo plano (1m 2s · ↓ 3k tokens)")
        XCTAssertEqual(ClaudeStatusCopy.waiting(waiting("Waiting for 3 background agents to finish", count: 3)).first, "Esperando a 3 agentes en segundo plano", "Nothing after it, nothing added.")
    }

    func testOnlyTheWaitIsTranslated() {
        let churning = ClaudeStatus(glyph: "✶", text: "Churning… (1m 2s · ↓ 3.4k tokens)", working: true)
        XCTAssertTrue(ClaudeStatusCopy.waiting(churning).isEmpty, "Claude's own verbs stay in Claude's words.")
        XCTAssertNil(ClaudeStatusCopy.explanation(churning))
        XCTAssertEqual(ClaudeStatusCopy.explanation(waiting("Waiting for 3 background agents to finish", count: 3)),
                       "Claude terminó su parte y espera a que acaben 3 agentes en segundo plano antes de seguir.")
        // What Claude's parser makes of the line is what the copy reads.
        let parsed = ClaudeStatus(line: "✻ Waiting for 3 background agents to finish")
        XCTAssertEqual(parsed?.background, 3)
        XCTAssertEqual(parsed.map(ClaudeStatusCopy.waiting)?.first, "Esperando a 3 agentes en segundo plano")
    }
}

/// The chip as a button: a click reaches the pane's action once, and a chip that waits takes none.
@MainActor
final class ClaudeModeChipClickTests: XCTestCase {
    private final class Clicks { var count = 0 }

    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// The chip (a 24 pt circle, 20 pt in from the corner of a 220 × 64 window), pressed in its middle.
    private func press(_ mode: ClaudeMode, blocked: String? = nil, clicks: Clicks) -> NSWindow {
        let chip = ClaudeModeChip(mode: mode, blocked: blocked) { clicks.count += 1 }.padding(20).frame(width: 220, height: 64, alignment: .topLeading)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: chip)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 220, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // The test closes it, and a window made in code is released by closing unless it is told not to be.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        click(window, at: NSPoint(x: 20 + 12, y: 32))
        return window
    }

    func testAClickOnTheChipPassesToTheNextMode() {
        for mode in [ClaudeMode.standard, ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: [])] {
            let clicks = Clicks()
            let window = press(mode, clicks: clicks)
            XCTAssertEqual(clicks.count, 1, "One click, one pass to the next mode: \(mode.label.isEmpty ? "default" : mode.label)")
            window.close()
        }
    }

    func testAChipThatWaitsTakesNoClick() {
        let clicks = Clicks()
        let window = press(.standard, blocked: "Hay una pregunta abierta: respóndela antes, porque ⇧⇥ podría contestarla.", clicks: clicks)
        XCTAssertEqual(clicks.count, 0, "With a question open, ⇧⇥ could answer it: the chip does not press it.")
        window.close()
    }
}

