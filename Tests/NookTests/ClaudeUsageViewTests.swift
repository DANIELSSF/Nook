import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The usage card's words: Claude's English titles, resets and percentages in Spanish, and the card built from Sample's two /usage screens.
@MainActor
final class ClaudeUsageViewTests: XCTestCase {
    func testTheLimitsTitlesAreInSpanishAndWhatIsUnknownStaysAsClaudeWroteIt() {
        XCTAssertEqual(UsageWords.title("Current session"), "Sesión actual")
        XCTAssertEqual(UsageWords.title("Current week (all models)"), "Semana actual (todos los modelos)")
        XCTAssertEqual(UsageWords.title("Current week (Sonnet only)"), "Semana actual (solo Sonnet)")
        XCTAssertEqual(UsageWords.title("Current week (Opus only)"), "Semana actual (solo Opus)")
        XCTAssertEqual(UsageWords.title("Current week"), "Semana actual")
        XCTAssertEqual(UsageWords.title("Current week (Opus 4.5)"), "Semana actual (Opus 4.5)")
        XCTAssertEqual(UsageWords.title("  Extra usage "), "Extra usage", "A limit Claude adds later is shown as it is.")
        XCTAssertEqual(UsageWords.title(""), "")
    }

    func testAResetIsToldInSpanishWithItsDateItsClockAndItsZone() {
        XCTAssertEqual(UsageWords.resets("Resets Oct 6 at 6am (America/Bogota)"), "Se reinicia el 6 oct a las 6 a. m. (America/Bogota)")
        XCTAssertEqual(UsageWords.resets("Resets Oct 7, 9am (America/Bogota)"), "Se reinicia el 7 oct a las 9 a. m. (America/Bogota)")
        XCTAssertEqual(UsageWords.resets("Resets 10:30am (America/Bogota)"), "Se reinicia a las 10:30 a. m. (America/Bogota)", "No date, so none is made up.")
        XCTAssertEqual(UsageWords.resets("Resets 8:59pm (America/Bogota)"), "Se reinicia a las 8:59 p. m. (America/Bogota)")
        XCTAssertEqual(UsageWords.resets("Resets Jan 2 at 12pm"), "Se reinicia el 2 ene a las 12 p. m.", "No zone, no parentheses.")
        XCTAssertEqual(UsageWords.resets("Resets Dec 31, 11:45pm (UTC)"), "Se reinicia el 31 dic a las 11:45 p. m. (UTC)")
        XCTAssertEqual(UsageWords.resets("Resets Sept 3 at 1pm (UTC)"), "Se reinicia el 3 sep a las 1 p. m. (UTC)", "Four-letter months too.")
        XCTAssertEqual(UsageWords.resets("Resets when the window rolls"), "Se reinicia when the window rolls", "Words it does not know: only the first is said.")
        XCTAssertEqual(UsageWords.resets("Next window soon"), "Next window soon")
    }

    func testThePercentIsTheNumberClaudePrintsAndTheWordThatFollowsIt() {
        XCTAssertEqual(UsageWords.percent("79% used").value, "79 %"); XCTAssertEqual(UsageWords.percent("79% used").rest, "usado")
        XCTAssertEqual(UsageWords.percent("7% used").value, "7 %")
        XCTAssertEqual(UsageWords.percent(" 98.5 % used ").value, "98.5 %")
        XCTAssertEqual(UsageWords.percent("Unlimited").value, "Unlimited"); XCTAssertEqual(UsageWords.percent("Unlimited").rest, "")
    }

    func testSamplesTwoUsageScreensGiveMetersWithSpanishWordsAndNothingLeftOver() throws {
        for (name, text, titles) in [("narrow", ClaudeUsageTests.narrow, ["Sesión actual", "Semana actual (todos los modelos)"]),
                                     ("full", ClaudePanelFixtures.usage, ["Sesión actual", "Semana actual (todos los modelos)", "Semana actual (solo Sonnet)"])] {
            let usage = try XCTUnwrap(ClaudeUsage(ClaudePanel(text)), name)
            XCTAssertEqual(usage.meters.map { UsageWords.title($0.title) }, titles, name)
            for meter in usage.meters {
                XCTAssertTrue(UsageWords.percent(meter.label).rest == "usado", "\(name): \(meter.label)")
                XCTAssertTrue(meter.resets.map(UsageWords.resets)?.hasPrefix("Se reinicia") == true, "\(name): \(String(describing: meter.resets))")
                XCTAssertFalse(meter.resets.map(UsageWords.resets)?.contains("Resets") == true)
            }
        }
    }

    func testTheCardIsTheUsageCardOnlyForTheUsagePanel() {
        // Both build; what each shows is in the renders. A panel that is not usage keeps the generic rows.
        _ = ClaudePanelCard(text: ClaudePanelFixtures.usage)
        _ = ClaudePanelCard(text: ClaudePanelFixtures.list)
        XCTAssertNotNil(ClaudeUsage(ClaudePanel(ClaudePanelFixtures.usage)))
        XCTAssertNil(ClaudeUsage(ClaudePanel(ClaudePanelFixtures.list)))
        XCTAssertNil(ClaudeUsage(ClaudePanel(ClaudePanelFixtures.boxed)))
    }
}
