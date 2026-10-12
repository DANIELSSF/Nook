import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The settings card's tab bar: how wide each tab is, that every tab is in the bar whole and can be reached, what each says to the pointer and to VoiceOver, and that the
/// dot stays on its tab. The windows are offscreen and borderless (they cannot take the keyboard) and nothing is clicked: a tab is pressed the way VoiceOver presses it.
/// Five tabs (the card's today) and six (one more, with the longest name a tab is likely to get) are tried at the card's width and a little under and over it.
@MainActor
final class SettingsTabBarTests: XCTestCase {
    private typealias Probe = SettingsTabBarProbe
    /// Between the bar's edge and its first tab.
    private let inner = SettingsTabMetrics.inset

    // MARK: How wide each tab is

    func testEachTabTakesWhatItNeedsAndAnEqualShareOfWhatIsLeft() {
        let need: [CGFloat] = [36, 36, 101, 36, 36]
        let widths = SettingsTabRow.widths(of: need, floors: [24, 24, 101, 24, 24], in: 314, spacing: 2)
        XCTAssertEqual(widths.reduce(0, +) + 4 * 2, 314, accuracy: 0.001, "The row is filled, gaps included.")
        let shares = zip(widths, need).map { $0 - $1 }
        XCTAssertGreaterThan(shares[0], 0, "There was room to spare.")
        for share in shares { XCTAssertEqual(share, shares[0], accuracy: 0.001, "Every tab gets the same share.") }
    }

    func testARowTooNarrowTakesFromTheSelectedNameBeforeAnythingElse() {
        // Five symbols of 24 (a symbol and 4 pt each side) and a selected tab of 112 whose name can give down to 54.
        let need: [CGFloat] = [24, 24, 112, 24, 24, 24]
        let floors: [CGFloat] = [24, 24, 54, 24, 24, 24]
        // 24 × 5 + 112 + 5 × 2 = 242: 22 pt too many for 220.
        let widths = SettingsTabRow.widths(of: need, floors: floors, in: 220, spacing: 2)
        XCTAssertEqual(widths.reduce(0, +) + 5 * 2, 220, accuracy: 0.001)
        for (index, width) in widths.enumerated() where index != 2 { XCTAssertEqual(width, 24, accuracy: 0.001, "A symbol keeps what it needs.") }
        XCTAssertEqual(widths[2], 90, accuracy: 0.001, "The selected tab gives the 22 pt: its name is the one that gives way.")
    }

    func testARowTooNarrowEvenForTheFloorsShrinksEverythingInProportion() {
        let widths = SettingsTabRow.widths(of: [36, 36, 101, 36], floors: [24, 24, 101, 24], in: 150, spacing: 2)
        XCTAssertEqual(widths.reduce(0, +) + 3 * 2, 150, accuracy: 0.001)
        XCTAssertTrue(widths.allSatisfy { $0 > 0 })
        XCTAssertEqual(widths[2] / widths[0], 101 / 24, accuracy: 0.001)
    }

    func testNoTabsAndNoRoom() {
        XCTAssertEqual(SettingsTabRow.widths(of: [], floors: [], in: 300, spacing: 2), [])
        XCTAssertEqual(SettingsTabRow.widths(of: [36, 36], floors: [24, 24], in: 0, spacing: 2), [0, 0])
    }

    // MARK: What each tab says

    func testATabThatDoesNotWriteItsNameSaysItToThePointer() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTabHelp.tooltip(title: tab.title, selected: false, note: nil), tab.title, "\(tab.title) is a symbol alone: its tooltip is its name.")
            XCTAssertEqual(SettingsTabHelp.tooltip(title: tab.title, selected: true, note: nil), "", "The selected tab writes its name: nothing to add.")
            for selected in [false, true] {
                XCTAssertEqual(SettingsTabHelp.tooltip(title: tab.title, selected: selected, note: tab.attentionNote), tab.title + " · " + tab.attentionNote, "A dot's note comes with the name.")
            }
        }
    }

    func testTheDotsSayWhatIsMissing() {
        XCTAssertEqual(SettingsTab.permissions.attentionNote, "Falta un permiso necesario")
        XCTAssertEqual(SettingsTab.screen.attentionNote, "Falta el permiso de grabación de pantalla")
    }

    func testTheBarIsAsTallAsTheCardCountsItAndTheSymbolsExist() {
        XCTAssertEqual(SettingsTabMetrics.barHeight, 32, "The panes' room was worked out for a bar this tall.")
        XCTAssertEqual(SettingsCard.chromeHeight, 40 + 32 + 12)
        for tab in SixTabs.allCases { XCTAssertNotNil(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil), "\(tab.title): \(tab.symbol)") }
    }

    // MARK: In the card

    private func card(selected: SettingsTab, dots: Bool = true) throws -> (NSWindow, AppModel) {
        let model = ScreenVisionUIFixture.model(try ScreenVisionUIFixture.vision(enabled: true))
        model.settingsTab = selected
        let states: [NookPermission: NookPermission.State] = dots ? [.automation: .notAsked, .accessibility: .notAsked, .screenRecording: .notAsked]
            : [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]
        let permissions = ScreenVisionUIFixture.permissions(states)
        permissions.refresh()
        let window = Probe.window(SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: permissions), width: SettingsCard.width)
        return (window, model)
    }

    /// Whichever tab is selected, all six are in the bar, whole and in order, none over another and none cut, and the bar itself does not change: the same place, the same
    /// size. The tabs trade width among themselves, the selected one taking what its name needs.
    func testEveryTabIsWholeAndInItsPlaceWhicheverIsSelected() throws {
        var bars: [NSRect] = []
        for selected in SettingsTab.allCases {
            let (window, _) = try card(selected: selected)
            defer { window.close() }
            let bar = try XCTUnwrap(Probe.frame("Pestañas de los ajustes", in: window))
            bars.append(bar)
            let frames = try SettingsTab.allCases.map { try XCTUnwrap(Probe.frame($0.title, in: window), "\($0.title) is in the bar (\(selected.title) selected)") }
            XCTAssertEqual(bar.height, SettingsTabMetrics.barHeight, accuracy: 0.6, "The bar is as tall as the card counts it.")
            XCTAssertEqual(bar.minX, 16, accuracy: 1); XCTAssertEqual(bar.maxX, SettingsCard.width - 16, accuracy: 1, "The bar takes the card's width, less its 16 pt.")
            for (tab, frame) in zip(SettingsTab.allCases, frames) {
                XCTAssertEqual(frame.height, SettingsTabMetrics.chip, accuracy: 0.6, "\(tab.title) (\(selected.title) selected)")
                if tab == selected {
                    XCTAssertGreaterThanOrEqual(frame.width, Probe.selectedNeed(tab.title) - 0.5, "The selected tab holds its symbol and its whole name: \(frame.width) pt")
                    let content = SettingsTabMetrics.symbol + SettingsTabMetrics.gap + Probe.titleWidth(tab.title)
                    XCTAssertGreaterThanOrEqual((frame.width - content) / 2, 12, "The pill has room around its content, which is what cramped it before: \((frame.width - content) / 2) pt a side")
                } else {
                    // Six tabs share the bar's 314 pt, and the selected one takes what its name needs: the others still have a symbol and a good margin to point at.
                    XCTAssertGreaterThanOrEqual(frame.width, 38, "\(tab.title) is a comfortable target, not a symbol and its edges: \(frame.width) pt")
                }
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(right.minX - left.maxX, SettingsTabMetrics.spacing, accuracy: 0.6, "The tabs are \(SettingsTabMetrics.spacing) pt apart, none over another (\(selected.title) selected)")
            }
            XCTAssertEqual(try XCTUnwrap(frames.first).minX, 16 + inner, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(frames.last).maxX, SettingsCard.width - 16 - inner, accuracy: 1, "The row fills the bar")
        }
        for bar in bars { XCTAssertEqual(bar, bars[0], "The bar does not move or change size when another tab is selected.") }
    }

    /// Each tab carries its tooltip: its name when it does not write it, and its dot's note when the dot is out.
    func testEveryTabCarriesItsTooltip() throws {
        for selected in [SettingsTab.island, .screen] {
            let (window, _) = try card(selected: selected)
            defer { window.close() }
            for tab in SettingsTab.allCases {
                let note = [SettingsTab.permissions, .screen].contains(tab) ? tab.attentionNote : nil
                XCTAssertEqual(Probe.help(tab.title, in: window) ?? "", SettingsTabHelp.tooltip(title: tab.title, selected: tab == selected, note: note), "\(tab.title) (\(selected.title) selected)")
            }
        }
    }

    /// Every tab can be reached the way VoiceOver, Voice Control and Space on a focused tab reach it, and it selects itself (and only itself).
    func testEveryTabCanBePressedAndSelectsItself() throws {
        let (window, model) = try card(selected: .island)
        defer { window.close() }
        for tab in SettingsTab.allCases.reversed() + SettingsTab.allCases {
            XCTAssertTrue(Probe.press(tab.title, in: window), "\(tab.title) takes a press")
            XCTAssertEqual(model.settingsTab, tab, "Pressing \(tab.title) selects it.")
            XCTAssertEqual(Probe.isSelected(tab.title, in: window), true, "VoiceOver says \(tab.title) is selected.")
            for other in SettingsTab.allCases where other != tab {
                XCTAssertEqual(Probe.isSelected(other.title, in: window) ?? false, false, "\(other.title) is not selected while \(tab.title) is.")
            }
        }
    }

    /// The dot is on its tab whichever tab is selected, and says what it says to VoiceOver; with no permission in question, nothing.
    func testTheDotsStayOnTheirTabsWhicheverIsSelected() throws {
        for selected in SettingsTab.allCases {
            let (window, _) = try card(selected: selected)
            for tab in SettingsTab.allCases {
                let expected = [SettingsTab.permissions, .screen].contains(tab) ? tab.attentionNote : ""
                XCTAssertEqual(Probe.value(tab.title, in: window) ?? "", expected, "\(tab.title) (\(selected.title) selected)")
            }
            window.close()
        }
        let (quiet, _) = try card(selected: .island, dots: false)
        defer { quiet.close() }
        for tab in SettingsTab.allCases { XCTAssertEqual(Probe.value(tab.title, in: quiet) ?? "", "", "\(tab.title): nothing is missing.") }
    }

    // MARK: Switching

    /// The pill's place in each frame of a switch from `from` to `to`, and whether anything was drawn outside the bar (in the 16 pt the harness leaves at its sides, where
    /// there is only the card's surface).
    private func glide<Tab: SettingsTabItem>(_ tabs: [Tab], from: Tab, to: Tab, attention: Set<Tab>) throws -> (pills: [ClosedRange<CGFloat>], spill: Bool) {
        let film = try Probe.film(tabs: tabs, from: from, to: to, attention: attention, width: SettingsCard.width)
        var spill = false
        for frame in film {
            let rep = frame.image
            let scale = CGFloat(rep.pixelsWide) / rep.size.width
            let y = rep.pixelsHigh / 2
            let reference = try XCTUnwrap(rep.colorAt(x: 1, y: y)?.usingColorSpace(.deviceRGB))
            let margins = Array(0..<Int(15 * scale)) + Array(Int((SettingsCard.width - 15) * scale)..<rep.pixelsWide)
            for x in margins {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - reference.redComponent) > 0.01 || abs(color.greenComponent - reference.greenComponent) > 0.01 { spill = true }
            }
        }
        return (film.compactMap { Probe.pill(in: $0) }, spill)
    }

    /// Selecting another tab slides the pill to it while the tabs change their widths: it is caught on the way, never turns back and never overshoots, never gets small, and
    /// nothing (a name fading out, one fading in) is drawn outside the bar on the way. With Reduce Motion on, the bar changes at once, with nothing in between.
    func testThePillGlidesToTheNewTabInsteadOfJumping() throws {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (from, to) in [(SettingsTab.island, SettingsTab.privacy), (.screen, .pet), (.pet, .permissions)] {
            var run = try glide(SettingsTab.allCases, from: from, to: to, attention: [.permissions, .screen])
            func between(_ pills: [ClosedRange<CGFloat>]) -> [CGFloat] {
                guard let first = pills.first, let last = pills.last else { return [] }
                let direction: CGFloat = last.lowerBound > first.lowerBound ? 1 : -1
                return pills.map(\.lowerBound).filter { ($0 - first.lowerBound) * direction > 3 && (last.lowerBound - $0) * direction > 3 }
            }
            // A busy machine can miss the whole glide between two frames: look again before saying that it jumped.
            for _ in 0..<2 where !reduced && between(run.pills).isEmpty { run = try glide(SettingsTab.allCases, from: from, to: to, attention: [.permissions, .screen]) }
            let pills = run.pills
            let first = try XCTUnwrap(pills.first, "The pill is in the first frame"), last = try XCTUnwrap(pills.last, "and in the last")
            XCTAssertGreaterThan(abs(last.lowerBound - first.lowerBound), 20, "\(from.title) to \(to.title): the pill ends on another tab.")
            let direction: CGFloat = last.lowerBound > first.lowerBound ? 1 : -1
            for (a, b) in zip(pills, pills.dropFirst()) {
                XCTAssertGreaterThanOrEqual((b.lowerBound - a.lowerBound) * direction, -0.6, "\(from.title) to \(to.title): the pill never turns back (left edge).")
                XCTAssertGreaterThanOrEqual((b.upperBound - a.upperBound) * direction, -0.6, "\(from.title) to \(to.title): the pill never turns back (right edge).")
            }
            for pill in pills {
                XCTAssertGreaterThanOrEqual(pill.upperBound - pill.lowerBound, 60, "\(from.title) to \(to.title): the pill never gets small on the way: \(pill)")
                XCTAssertGreaterThanOrEqual((pill.lowerBound - first.lowerBound) * direction, -0.6, "never behind where it starts")
                XCTAssertGreaterThanOrEqual((last.lowerBound - pill.lowerBound) * direction, -0.6, "never past where it ends")
            }
            if reduced {
                XCTAssertTrue(between(pills).isEmpty, "\(from.title) to \(to.title): with Reduce Motion the bar changes at once.")
            } else {
                XCTAssertGreaterThanOrEqual(between(pills).count, 1, "\(from.title) to \(to.title): at least one frame is caught on the way, so it glided.")
            }
            XCTAssertFalse(run.spill, "\(from.title) to \(to.title): nothing is drawn outside the bar while it changes.")
        }
    }

    // MARK: Six tabs, and other widths

    /// A bar on its own with `tabs`, `width` wide, `selected` selected.
    private func bar<Tab: SettingsTabItem>(_ tabs: [Tab], selected: Tab, width: CGFloat, attention: Set<Tab>) -> NSWindow {
        Probe.window(SettingsTabBarHarness(tabs: tabs, selection: SettingsTabBarSelection(selected), attention: attention, width: width), width: width)
    }

    /// Six tabs, the sixth with a long name, at the card's width and either side of it: each in the bar, none over another, the row filling the bar. Over 300 pt every selected
    /// tab keeps its whole name; at the card's width a symbol has a good deal more than its edges; and in a row too narrow for the longest name (260 pt) it is the name that
    /// gives way, to an ellipsis, while every symbol keeps what it needs.
    func testSixTabsFitAtTheCardsWidthAndNothingIsLostWhenTheRowIsNarrower() throws {
        let tabs = Array(SixTabs.allCases)
        for width in [260, 300, 352, 420] as [CGFloat] {
            for selected in tabs {
                let window = bar(tabs, selected: selected, width: width, attention: [.permissions, .screen, .notifications])
                defer { window.close() }
                let frames = try tabs.map { try XCTUnwrap(Probe.frame($0.title, in: window), "\($0.title) is in the bar (\(width) pt, \(selected.title) selected)") }
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertEqual(right.minX - left.maxX, SettingsTabMetrics.spacing, accuracy: 0.6, "none over another (\(width) pt, \(selected.title) selected)")
                }
                XCTAssertEqual(try XCTUnwrap(frames.first).minX, 16 + inner, accuracy: 1)
                XCTAssertEqual(try XCTUnwrap(frames.last).maxX, width - 16 - inner, accuracy: 1, "The row fills the bar (\(width) pt)")
                for (tab, frame) in zip(tabs, frames) {
                    if tab == selected {
                        let cut = width < 300 && tab == .notifications
                        if cut {
                            XCTAssertLessThan(frame.width, Probe.selectedNeed(tab.title), "At \(width) pt the longest name does not fit whole: \(frame.width) pt")
                            XCTAssertGreaterThanOrEqual(frame.width, 2 * SettingsTabMetrics.padding + SettingsTabMetrics.symbol + SettingsTabMetrics.gap + SettingsTabMetrics.leastName - 0.5)
                        } else {
                            XCTAssertGreaterThanOrEqual(frame.width, Probe.selectedNeed(tab.title) - 0.5, "\(tab.title) keeps its whole name (\(width) pt): \(frame.width) pt")
                        }
                    } else {
                        XCTAssertGreaterThanOrEqual(frame.width, SettingsTabMetrics.symbol + 2 * SettingsTabMetrics.padding - 0.5, "\(tab.title) keeps its symbol (\(width) pt): \(frame.width) pt")
                        if width >= 352 { XCTAssertGreaterThanOrEqual(frame.width, 34, "At the card's width a symbol has room: \(frame.width) pt") }
                    }
                }
            }
        }
    }

    func testSixTabsAreAllReachableAndTheDotOnTheSixthStays() throws {
        let tabs = Array(SixTabs.allCases)
        let selection = SettingsTabBarSelection(SixTabs.island)
        let window = Probe.window(SettingsTabBarHarness(tabs: tabs, selection: selection, attention: [.notifications], width: SettingsCard.width), width: SettingsCard.width)
        defer { window.close() }
        for tab in tabs {
            XCTAssertTrue(Probe.press(tab.title, in: window), "\(tab.title) takes a press")
            XCTAssertEqual(selection.tab, tab)
        }
        XCTAssertEqual(Probe.value("Notificaciones", in: window) ?? "", "Faltan los avisos")
        XCTAssertEqual(Probe.value("Isla", in: window) ?? "", "")
    }
}
