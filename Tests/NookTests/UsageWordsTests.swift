import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Claude's words in the usage card, in Spanish (`UsageWords`), and how the card keeps what belongs together together when a line breaks (`UsageFigures.unbroken`).
@MainActor
final class UsageWordsTests: XCTestCase {
    func testWhatThePanelSaysOfTheCreditsIsInSpanish() {
        XCTAssertEqual(UsageWords.insight("Usage credits are off · /usage-credits to turn them on"), "Los créditos de uso están desactivados · /usage-credits los activa")
        XCTAssertEqual(UsageWords.insight("Usage credits are on"), "Los créditos de uso están activados")
        XCTAssertEqual(UsageWords.insight("Usage credits are on · /usage-credits to turn them off"), "Los créditos de uso están activados · /usage-credits los desactiva")
        XCTAssertEqual(UsageWords.insight("Usage credits are on · /usage-credits to manage them"), "Los créditos de uso están activados · /usage-credits los gestiona")
        XCTAssertEqual(UsageWords.insight("Usage credits are off · something Claude adds later"), "Los créditos de uso están desactivados · something Claude adds later",
                       "What follows the dot and is not known stays as Claude wrote it.")
        XCTAssertEqual(UsageWords.insight("Unlimited"), "Sin límite")
        XCTAssertEqual(UsageWords.title("Usage credits"), "Créditos de uso", "…under the heading the panel already had in Spanish.")
    }

    func testALimitThatIsStillLoadingSaysHowFullItIsInSpanish() {
        XCTAssertEqual(UsageWords.insight("Current session · 3% used"), "Sesión actual · 3 % usado")
        XCTAssertEqual(UsageWords.insight("Current week (Sonnet only) · 12.5% used"), "Semana actual (solo Sonnet) · 12.5 % usado")
        XCTAssertEqual(UsageWords.insight("Extra usage · 3% used"), "Extra usage · 3 % usado", "A title it does not know stays, with its percent said.")
        XCTAssertEqual(UsageWords.insight("Loading usage data…"), "Cargando los datos de uso…")
    }

    func testTheRemarksUnderANearlyFullLimitAreInSpanish() {
        XCTAssertEqual(UsageWords.insight("You are close to this limit"), "Estás cerca de este límite")
        XCTAssertEqual(UsageWords.insight("You've used most of your session limit"), "Has usado casi todo el límite de tu sesión")
        XCTAssertEqual(UsageWords.insight("You’ve used most of your session limit"), "Has usado casi todo el límite de tu sesión", "A curly apostrophe too.")
    }

    func testWhatIsNotKnownComesBackAsItWas() {
        for text in ["Usage credits are mostly off", "Credits? Maybe.", "Something new Claude says", "", "Unlimited usage"] {
            XCTAssertEqual(UsageWords.insight(text), text, "«\(text)»")
        }
    }

    func testTheRemarkAfterTheCostIsHereAndStaysClaudesWhenUnknown() {
        XCTAssertEqual(UsageWords.costNote(" costs may be inaccurate due to usage of unknown models "), "El costo puede ser inexacto: se usaron modelos que Claude no conoce")
        XCTAssertEqual(UsageWords.costNote("Costs may be inaccurate due to usage of unknown models"), "El costo puede ser inexacto: se usaron modelos que Claude no conoce")
        XCTAssertEqual(UsageWords.costNote("a remark Claude adds later"), "a remark Claude adds later")
    }

    func testEveryLineTheTwoOfSamplesScreensLeaveOverIsInSpanish() throws {
        for (name, screen) in [("whole", ClaudeUsageFixtures.whole), ("terminal", ClaudeUsageFixtures.terminal)] {
            let usage = try XCTUnwrap(ClaudeUsageFixtures.usage(screen))
            for row in usage.leftovers {
                guard let text = ClaudePanel.text(of: row) else { continue }
                let shown: String
                if case .heading = row { shown = UsageWords.title(text) } else { shown = UsageWords.insight(text) }
                XCTAssertNotEqual(shown, text, "\(name): «\(text)» has its Spanish.")
            }
        }
    }

    // MARK: What stays together

    func testACommandStaysWithItsSlashAndATimeStaysInOnePiece() {
        XCTAssertEqual(UsageFigures.unbroken("Usa /compact a mitad de una tarea y /clear al pasar a otra."), "Usa /\u{2060}compact a mitad de una tarea y /\u{2060}clear al pasar a otra.")
        XCTAssertEqual(UsageFigures.unbroken("Desactivados · /usage-credits los activa"), "Desactivados\u{00A0}· /\u{2060}usage-credits los activa", "The dot stays with the words before it.")
        XCTAssertEqual(UsageFigures.unbroken("(/review)"), "(/\u{2060}review)")
        XCTAssertEqual(UsageFigures.unbroken("/clear"), "/\u{2060}clear", "At the start of the line too.")
        XCTAssertEqual(UsageFigures.unbroken("Reinicia el 13 oct · 6 a. m."), "Reinicia el 13 oct\u{00A0}· 6\u{00A0}a.\u{00A0}m.")
        XCTAssertEqual(UsageFigures.unbroken("Reinicia a las 12 p. m. (UTC)"), "Reinicia a las 12\u{00A0}p.\u{00A0}m. (UTC)")
        // What is not a command, or a time, is left alone.
        XCTAssertEqual(UsageFigures.unbroken("10 skills · ~301 tok/turno"), "10 skills\u{00A0}· ~301 tok/turno")
        for text in ["~376 tok/turno", "and/or", "https://claude.ai/code", "~/Documents/app", "6 a la derecha", "", "/", "/ 5"] {
            XCTAssertEqual(UsageFigures.unbroken(text), text, "«\(text)»")
        }
        // Nothing but invisible joiners and no-break spaces is added: what is read out, and what is compared, is the text.
        let text = "Usa /compact a las 6 a. m. y /clear"
        let kept = UsageFigures.unbroken(text).replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertEqual(kept, text)
    }

    // MARK: The advice, in full

    private func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheAdviceIsShownInFullWhereTheCardHasRoomAndInTwoLinesWhereItIsDense() {
        let long = "Sessions that last all day long cost more even when everything is cached, because every new turn carries all that came before it. Compact in the middle of a task and clear when you switch to a new one, and keep background loops on a cheaper model."
        let item = ClaudeUsage.Insight(headline: "89% of your usage was at >150k context", advice: long, share: 0.89)
        let roomy = height(UsageInsightRow(item: item, index: 0, metrics: UsageMetrics(dense: false)), width: 230)
        let dense = height(UsageInsightRow(item: item, index: 0, metrics: UsageMetrics(dense: true)), width: 230)
        let oneLine = UsageMetrics(dense: false)(9.5) * 1.2
        XCTAssertGreaterThan(roomy, dense + 3 * oneLine, "Six lines of advice, not two: nothing is cut with «…».")
        // A short advice is the same either way: nothing to cut.
        let short = ClaudeUsage.Insight(headline: "89% of your usage was at >150k context", advice: "Compact now.", share: 0.89)
        XCTAssertEqual(height(UsageInsightRow(item: short, index: 0, metrics: UsageMetrics(dense: false)), width: 230),
                       height(UsageInsightRow(item: short, index: 0, metrics: UsageMetrics(dense: true)), width: 230), accuracy: 6)
    }
}
