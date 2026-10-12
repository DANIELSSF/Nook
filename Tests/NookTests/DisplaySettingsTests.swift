import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The display settings: defaults, clamping, persistence, the island's size for every preset on several screens, and what the
/// pane derives from it.
@MainActor
final class DisplaySettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "nook-display-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// Screens as AppKit reports them: size in points and the safe-area inset at the top (the notch's height, 0 without one).
    private let screens: [(name: String, size: CGSize, inset: CGFloat)] = [
        ("14\" MacBook Pro", CGSize(width: 1512, height: 982), 32),
        ("16\" MacBook Pro", CGSize(width: 1728, height: 1117), 32),
        ("13\" MacBook Air", CGSize(width: 1470, height: 956), 38),
        ("external 1080p", CGSize(width: 1920, height: 1080), 0),
        ("external 4K scaled", CGSize(width: 2560, height: 1440), 0),
        ("small 1280x800", CGSize(width: 1280, height: 800), 0),
        ("tiny 700x520", CGSize(width: 700, height: 520), 0),
    ]

    // MARK: Defaults

    func testDefaultsAreTheLookTheIslandAlwaysHad() {
        let settings = DisplaySettings()
        XCTAssertEqual(settings.chatSize, 11, "The mirror's text was 11 pt.")
        XCTAssertEqual(settings.inputSize, 13, "The field's text was 13 pt.")
        XCTAssertEqual(settings.inputLines, 3)
        XCTAssertEqual(settings.widthExtra, 0)
        XCTAssertEqual(settings.heightExtra, 0)
        XCTAssertTrue(settings.isDefault)
        XCTAssertEqual(settings.preset, .normal)
        XCTAssertEqual(settings.chatFont.pointSize, 11)
        XCTAssertTrue(settings.chatFont.isFixedPitch)
        XCTAssertEqual(settings.inputFont.pointSize, 13)
        XCTAssertEqual(LiveTerminalScrollView.baseFont, settings.chatFont, "The mirror's default font is the setting's default.")
        XCTAssertEqual(DisplaySettings.load(from: suite()), settings, "A Mac that never touched them has the defaults.")
    }

    func testTheNormalIslandIsExactlyTodaysSizeOnEveryScreen() {
        for screen in screens {
            let size = NotchGeometry.expandedSize(screen: screen.size, topInset: screen.inset)
            XCTAssertEqual(size.width, min(572, screen.size.width - 32), "\(screen.name)")
            XCTAssertEqual(size.height, min(NotchGeometry.expandedHeight(topInset: screen.inset), screen.size.height - 40), "\(screen.name)")
            let frame = NotchGeometry.expandedFrame(screen: CGRect(origin: .zero, size: screen.size), centerX: screen.size.width / 2, topInset: screen.inset)
            XCTAssertEqual(frame.size, size, "\(screen.name): the frame without settings is the Normal island")
        }
        let notch = NotchGeometry.expandedSize(screen: CGSize(width: 1512, height: 982), topInset: 32)
        XCTAssertEqual(notch, CGSize(width: 572, height: 266), "572 × 266 with a 32 pt notch, as the README says.")
        XCTAssertEqual(NotchGeometry.expandedSize(screen: CGSize(width: 1920, height: 1080), topInset: 0).height, 262, "262 without one.")
    }

    // MARK: Clamping

    func testEveryValueIsBroughtInsideItsRange() {
        var settings = DisplaySettings()
        settings.chatSize = 3; settings.inputSize = 99; settings.inputLines = 0; settings.widthExtra = -9999; settings.heightExtra = 99999
        let fixed = settings.clamped()
        XCTAssertEqual(fixed.chatSize, 9)
        XCTAssertEqual(fixed.inputSize, 20)
        XCTAssertEqual(fixed.inputLines, 1)
        XCTAssertEqual(fixed.widthExtra, DisplaySettings.widthExtraRange.lowerBound)
        XCTAssertEqual(fixed.heightExtra, DisplaySettings.heightExtraRange.upperBound)
        settings.inputLines = 40
        XCTAssertEqual(settings.clamped().inputLines, 6)
        settings.chatSize = 11.4; settings.inputSize = 12.6
        XCTAssertEqual(settings.clamped().chatSize, 11, "Whole points, so the shortcuts and the sliders meet.")
        XCTAssertEqual(settings.clamped().inputSize, 13)
    }

    func testNothingThatIsNotANumberSurvives() {
        var settings = DisplaySettings()
        settings.chatSize = .nan; settings.inputSize = .infinity; settings.widthExtra = .nan; settings.heightExtra = -.infinity
        let fixed = settings.clamped()
        XCTAssertEqual(fixed, DisplaySettings(), "NaN and infinity go back to the defaults.")
    }

    func testTheChatSizeStepsByAPointAndStopsAtItsEnds() {
        var settings = DisplaySettings()
        XCTAssertEqual(settings.applying(.larger).chatSize, 12)
        XCTAssertEqual(settings.applying(.smaller).chatSize, 10)
        for _ in 0..<20 { settings = settings.applying(.larger) }
        XCTAssertEqual(settings.chatSize, 18, "⌘+ stops at the largest.")
        for _ in 0..<20 { settings = settings.applying(.smaller) }
        XCTAssertEqual(settings.chatSize, 9, "⌘− stops at the smallest.")
        XCTAssertEqual(settings.applying(.reset).chatSize, 11, "⌘0 is the default.")
        settings.inputSize = 17; settings.widthExtra = 40
        let reset = settings.applying(.reset)
        XCTAssertEqual(reset.inputSize, 17, "Only the chat's size is reset by it.")
        XCTAssertEqual(reset.widthExtra, 40)
    }

    // MARK: Persistence

    func testSettingsAreSavedAndLoadedBack() {
        let defaults = suite()
        var settings = DisplaySettings()
        settings.chatSize = 15; settings.inputSize = 16; settings.inputLines = 5; settings.widthExtra = 148; settings.heightExtra = -44
        settings.save(to: defaults)
        XCTAssertEqual(DisplaySettings.load(from: defaults), settings)
        XCTAssertEqual(defaults.double(forKey: DisplaySettings.Key.chatSize), 15)
        XCTAssertEqual(defaults.integer(forKey: DisplaySettings.Key.inputLines), 5)
    }

    func testWhatIsStoredIsClampedAndGarbageIsTheDefault() {
        let defaults = suite()
        defaults.set(99.0, forKey: DisplaySettings.Key.chatSize)
        defaults.set("grande", forKey: DisplaySettings.Key.inputSize)
        defaults.set(-4, forKey: DisplaySettings.Key.inputLines)
        defaults.set(Double.nan, forKey: DisplaySettings.Key.widthExtra)
        let loaded = DisplaySettings.load(from: defaults)
        XCTAssertEqual(loaded.chatSize, 18)
        XCTAssertEqual(loaded.inputSize, 13, "A string is not a size.")
        XCTAssertEqual(loaded.inputLines, 1)
        XCTAssertEqual(loaded.widthExtra, 0)
    }

    func testTheModelSavesEveryChangeAndClampsWhatItIsGiven() {
        let defaults = suite()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        XCTAssertEqual(model.display, DisplaySettings())
        model.display.chatSize = 14
        XCTAssertEqual(defaults.double(forKey: DisplaySettings.Key.chatSize), 14, "Saved as it changes.")
        model.display.inputLines = 99
        XCTAssertEqual(model.display.inputLines, 6, "Out of range is brought back.")
        XCTAssertEqual(defaults.integer(forKey: DisplaySettings.Key.inputLines), 6)
        model.display = model.display.applying(.wide)
        let again = AppModel(receivesSignals: false, defaults: defaults)
        XCTAssertEqual(again.display, model.display, "A new run starts with what was set.")
        again.display = DisplaySettings()
        XCTAssertEqual(DisplaySettings.load(from: defaults), DisplaySettings(), "Restablecer saves the defaults.")
    }

    func testAValueThatDidNotChangeIsNotWritten() {
        let defaults = suite()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.display.chatSize = 11   // already 11
        XCTAssertNil(defaults.object(forKey: DisplaySettings.Key.chatSize), "Nothing changed, nothing saved.")
        model.display.chatSize = 12
        XCTAssertEqual(defaults.double(forKey: DisplaySettings.Key.chatSize), 12)
    }

    // MARK: The theme

    func testTheThemeFollowsMacOSUntilTheUserChoosesOne() {
        XCTAssertEqual(DisplaySettings().theme, .system, "Sistema is the default: a Mac in dark mode sees the island as it always was")
        XCTAssertEqual(DisplaySettings.load(from: suite()).theme, .system)
    }

    func testTheThemeIsSavedAndLoadedBack() {
        for theme in ThemePreference.allCases {
            let defaults = suite()
            var settings = DisplaySettings()
            settings.theme = theme
            settings.save(to: defaults)
            XCTAssertEqual(DisplaySettings.load(from: defaults).theme, theme)
            XCTAssertEqual(defaults.string(forKey: DisplaySettings.Key.theme), theme.rawValue)
        }
    }

    func testAThemeNobodyKnowsIsTheDefault() {
        let defaults = suite()
        defaults.set("sepia", forKey: DisplaySettings.Key.theme)
        XCTAssertEqual(DisplaySettings.load(from: defaults).theme, .system)
        defaults.set(3, forKey: DisplaySettings.Key.theme)
        XCTAssertEqual(DisplaySettings.load(from: defaults).theme, .system, "A number is not a theme")
    }

    func testTheModelSavesTheThemeAsItChangesAndANewRunStartsWithIt() {
        let defaults = suite()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.display.theme = .light
        XCTAssertEqual(defaults.string(forKey: DisplaySettings.Key.theme), "light")
        XCTAssertEqual(AppModel(receivesSignals: false, defaults: defaults).display.theme, .light)
        model.display.theme = .system
        XCTAssertEqual(AppModel(receivesSignals: false, defaults: defaults).display.theme, .system)
    }

    func testRestablecerKeepsTheTheme() {
        var settings = DisplaySettings()
        settings.theme = .dark
        XCTAssertTrue(settings.isDefault, "The theme is not a measure of the island: a dark island of its usual size is still at its defaults")
        settings.chatSize = 15; settings.widthExtra = 148
        XCTAssertFalse(settings.isDefault)
        let reset = settings.resetKeepingTheme()
        XCTAssertEqual(reset.theme, .dark, "putting the island back to its size must not turn it from dark to light")
        XCTAssertEqual(reset.chatSize, 11)
        XCTAssertEqual(reset.widthExtra, 0)
        XCTAssertTrue(reset.isDefault)
    }

    // MARK: Presets

    func testPresetsAreOffsetsFromTheNormalIslandAndAreRecognised() {
        XCTAssertEqual(IslandPreset.allCases.map(\.title), ["Compacta", "Normal", "Amplia", "Alta"])
        for preset in IslandPreset.allCases {
            XCTAssertEqual(DisplaySettings().applying(preset).preset, preset)
        }
        var custom = DisplaySettings().applying(.wide)
        custom.heightExtra += 12
        XCTAssertNil(custom.preset, "A size of the user's own matches none.")
        var texts = DisplaySettings(); texts.chatSize = 15
        XCTAssertEqual(texts.applying(.tall).chatSize, 15, "A preset sets the island's size and leaves the text alone.")
    }

    func testEveryPresetFitsEveryScreenWithItsMarginsAndStaysCentredOnTheNotch() {
        for screen in screens {
            let rect = CGRect(origin: CGPoint(x: 0, y: 0), size: screen.size)
            for preset in IslandPreset.allCases {
                let settings = DisplaySettings().applying(preset)
                let frame = NotchGeometry.expandedFrame(screen: rect, centerX: rect.midX, topInset: screen.inset, settings: settings)
                let label = "\(screen.name), \(preset.title)"
                XCTAssertLessThanOrEqual(frame.width, screen.size.width - 32, label)
                XCTAssertLessThanOrEqual(frame.height, screen.size.height - 40, label)
                XCTAssertGreaterThanOrEqual(frame.minX, 16 - 0.5, label + ": 16 pt of margin at the sides")
                XCTAssertLessThanOrEqual(frame.maxX, screen.size.width - 16 + 0.5, label)
                XCTAssertEqual(frame.maxY, rect.maxY, label + ": hangs from the top edge")
                XCTAssertEqual(frame.midX, rect.midX, accuracy: 0.5, label + ": centred on the notch")
                XCTAssertGreaterThanOrEqual(frame.height, NotchGeometry.minExpandedHeight(topInset: screen.inset) - 0.5, label)
                if screen.size.width - 32 >= NotchGeometry.minExpandedWidth {
                    XCTAssertGreaterThanOrEqual(frame.width, NotchGeometry.minExpandedWidth, label)
                }
            }
        }
    }

    func testThePresetsOnA14InchMacBookProAreTheNumbersTheyPromise() {
        let screen = CGSize(width: 1512, height: 982)
        func size(_ preset: IslandPreset) -> CGSize { NotchGeometry.expandedSize(screen: screen, topInset: 32, settings: DisplaySettings().applying(preset)) }
        XCTAssertEqual(size(.compact), CGSize(width: 500, height: 222))
        XCTAssertEqual(size(.normal), CGSize(width: 572, height: 266))
        XCTAssertEqual(size(.wide), CGSize(width: 720, height: 350))
        XCTAssertEqual(size(.tall), CGSize(width: 572, height: 486))
    }

    func testASmallScreenClampsEvenTheBiggestSettingAndKeepsTheMargins() {
        var huge = DisplaySettings()
        huge.widthExtra = 2400; huge.heightExtra = 2400
        let screen = CGSize(width: 1280, height: 800)
        let size = NotchGeometry.expandedSize(screen: screen, topInset: 0, settings: huge)
        XCTAssertEqual(size, CGSize(width: 1248, height: 760))
        let tiny = NotchGeometry.expandedSize(screen: CGSize(width: 400, height: 300), topInset: 0, settings: DisplaySettings())
        XCTAssertEqual(tiny, CGSize(width: 368, height: 260), "The screen's own clamp has the last word, below the minimum too.")
        var small = DisplaySettings(); small.widthExtra = -140; small.heightExtra = -80
        let least = NotchGeometry.expandedSize(screen: CGSize(width: 1920, height: 1080), topInset: 32, settings: small)
        XCTAssertEqual(least.width, 440)
        XCTAssertEqual(least.height, 202, "The smallest island: header + tab row + room for the composer.")
    }

    func testTheSlidersReachWhatTheScreenAllowsAndNormalIsInsideThem() {
        for screen in screens {
            let width = NotchGeometry.widthRange(screen: screen.size), height = NotchGeometry.heightRange(screen: screen.size, topInset: screen.inset)
            XCTAssertEqual(width.upperBound, screen.size.width - 32, screen.name)
            XCTAssertEqual(height.upperBound, screen.size.height - 40, screen.name)
            XCTAssertLessThanOrEqual(width.lowerBound, width.upperBound)
            XCTAssertLessThanOrEqual(height.lowerBound, height.upperBound)
            let normal = NotchGeometry.expandedSize(screen: screen.size, topInset: screen.inset)
            XCTAssertTrue(width.contains(normal.width) && height.contains(normal.height), "\(screen.name): the Normal island is on the sliders")
        }
    }

    func testASizeComesBackAsTheSameSettingsAndAsTheSameSize() {
        let screen = CGSize(width: 1512, height: 982)
        for target in [CGSize(width: 640, height: 300), CGSize(width: 440, height: 202), CGSize(width: 1480, height: 942), CGSize(width: 572, height: 266)] {
            let settings = NotchGeometry.settings(for: target, screen: screen, topInset: 32, from: DisplaySettings())
            XCTAssertEqual(NotchGeometry.expandedSize(screen: screen, topInset: 32, settings: settings), target)
        }
        let beyond = NotchGeometry.settings(for: CGSize(width: 9000, height: 9000), screen: screen, topInset: 32, from: DisplaySettings())
        XCTAssertEqual(NotchGeometry.expandedSize(screen: screen, topInset: 32, settings: beyond), CGSize(width: 1480, height: 942), "A drag past the screen's edge stops at the clamp.")
        var texts = DisplaySettings(); texts.chatSize = 16; texts.inputLines = 2
        let kept = NotchGeometry.settings(for: CGSize(width: 600, height: 300), screen: screen, topInset: 32, from: texts)
        XCTAssertEqual(kept.chatSize, 16)
        XCTAssertEqual(kept.inputLines, 2)
    }

    // MARK: The header's cat

    func testTheCatsRoomFollowsTheIslandAndNeverReachesTheNotch() {
        for cutout in [CGFloat(180), 200, 230] {
            var last: CGFloat = 0
            for width in stride(from: CGFloat(440), through: 1100, by: 20) {
                let stage = NotchGeometry.petStageWidth(islandWidth: width, cutout: cutout)
                XCTAssertGreaterThanOrEqual(stage, 60)
                XCTAssertGreaterThanOrEqual(stage, last, "A wider island never gives the cat less room.")
                // Stage starts 12 pt in from the island's edge and must end before the notch.
                let end = 12 + stage, notchLeft = (width - cutout) / 2
                if (width - cutout) / 2 - 24 >= 60 { XCTAssertLessThanOrEqual(end, notchLeft, "width \(width), notch \(cutout)") }
                last = stage
            }
        }
        XCTAssertEqual(NotchGeometry.petStageWidth(islandWidth: 572, cutout: 180), 164, "The Normal island's cat room is what it was.")
        XCTAssertLessThan(NotchGeometry.petStageWidth(islandWidth: 500, cutout: 180), 164, "A narrower island shortens the walk.")
        XCTAssertGreaterThan(NotchGeometry.petStageWidth(islandWidth: 720, cutout: 180), 164, "A wider one lengthens it.")
    }

    func testTheHeaderCatsWalkingRangeFollowsItsViewsWidth() {
        let narrow = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 90, height: 32))
        let wide = HeaderPetView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        XCTAssertLessThan(narrow.travel, wide.travel)
        XCTAssertGreaterThanOrEqual(narrow.travel, 0)
    }

    // MARK: The pane

    private func pane(_ preset: IslandPreset, neck: CGFloat = 32, _ edit: (inout DisplaySettings) -> Void = { _ in }) -> PaneLayout {
        var settings = DisplaySettings().applying(preset)
        edit(&settings)
        let size = NotchGeometry.expandedSize(screen: CGSize(width: 2560, height: 1440), topInset: neck, settings: settings)
        return PaneLayout.of(island: size, neck: neck, settings: settings)
    }

    func testTheNormalIslandsPaneKeepsEveryNumberItHadBefore() {
        let layout = pane(.normal)
        XCTAssertEqual(layout.height, 204, "266 less the 32 pt header and the 30 pt tab row.")
        XCTAssertEqual(layout.lineHeight, 16)
        XCTAssertEqual(ComposerMetrics.fieldHeight(lines: 1, size: 13), 22)
        XCTAssertEqual(layout.composerHeight(lines: 1), 66, "The composer was 66 pt tall.")
        XCTAssertEqual(layout.fieldLines, 3)
        XCTAssertEqual(layout.slashRows(composerHeight: 66), 5, "The \"/\" menu showed five rows.")
        XCTAssertEqual(layout.cardRows, 6, "The question card showed six options.")
        XCTAssertEqual(layout.cardOptionsBesideMirror, 4)
        XCTAssertEqual(layout.tabListMaxHeight, 178)
        XCTAssertEqual(layout.tabListWidth, 440)
        XCTAssertEqual(layout.capsuleListMaxHeight(composerHeight: 66), 130)
        XCTAssertEqual(layout.recapWidth, 360)
        XCTAssertEqual(layout.recapMaxBodyHeight, 124)
        XCTAssertEqual(AgentPromptCard.visibleRows, 6)
        XCTAssertEqual(AgentPromptCard.optionsBesideMirror, 4)
        XCTAssertEqual(SlashMenuState.visibleRows, 5)
        XCTAssertEqual(TabAgentListLayout.maxHeight, 178)
        XCTAssertEqual(SubagentCapsule.listMaxHeight, 130)
        XCTAssertEqual(SessionRecapCard.maxBodyHeight, 124)
        // Same on a screen without a notch (a 28 pt header, a 262 pt island).
        let flat = pane(.normal, neck: 28)
        XCTAssertEqual(flat.height, 204)
        XCTAssertEqual(flat.slashRows(composerHeight: 66), 5)
    }

    func testTheMenuShowsMoreRowsWhenThereIsRoomAndFewerWhenThereIsNot() {
        XCTAssertEqual(pane(.compact).slashRows(composerHeight: 66), 3)
        XCTAssertEqual(pane(.normal).slashRows(composerHeight: 66), 5)
        XCTAssertGreaterThan(pane(.wide).slashRows(composerHeight: 66), 5)
        XCTAssertEqual(pane(.tall).slashRows(composerHeight: 66), 14, "A tall island shows many rows, up to the cap.")
        // A taller composer (a long draft) leaves the menu less room.
        XCTAssertLessThan(pane(.normal).slashRows(composerHeight: 98), pane(.normal).slashRows(composerHeight: 66))
        // Whatever the size, the menu never reaches over the tab row.
        for preset in IslandPreset.allCases {
            let layout = pane(preset)
            for lines in 1...3 {
                // The field never grows past what the pane can spare (`fieldLines`), so that is the composer the menu sits over.
                let composer = layout.composerHeight(lines: min(lines, layout.fieldLines))
                let rows = layout.slashRows(composerHeight: composer)
                XCTAssertTrue(PaneLayout.slashRowRange.contains(rows))
                let menu = SlashMenuView.height(rows: 100, visible: rows) + SlashMenuView.gap
                XCTAssertLessThanOrEqual(menu, layout.height - ComposerMetrics.bottomInset - composer, "\(preset.title), \(lines) lines: the menu fits under the pane's top")
            }
        }
        // The smallest island still holds the smallest menu.
        var least = DisplaySettings(); least.widthExtra = -140; least.heightExtra = -80
        let size = NotchGeometry.expandedSize(screen: CGSize(width: 1920, height: 1080), topInset: 32, settings: least)
        let layout = PaneLayout.of(island: size, neck: 32, settings: least)
        let menu = SlashMenuView.height(rows: 100, visible: layout.slashRows(composerHeight: 66)) + SlashMenuView.gap
        XCTAssertLessThanOrEqual(menu, layout.height - ComposerMetrics.bottomInset - 66)
    }

    func testTheFieldGrowsToTheUsersLinesAndTheConversationKeepsItsRoom() {
        for preset in IslandPreset.allCases {
            for neck in [CGFloat(28), 32] {
                for (chat, input) in [(9.0, 10.0), (11.0, 13.0), (18.0, 20.0)] {
                    for lines in 1...6 {
                        let layout = pane(preset, neck: neck) { $0.inputLines = lines; $0.chatSize = chat; $0.inputSize = input }
                        let label = "\(preset.title), neck \(neck), input \(input) pt, \(lines) lines"
                        XCTAssertGreaterThanOrEqual(layout.fieldLines, 1, label)
                        XCTAssertLessThanOrEqual(layout.fieldLines, lines, label + ": never more than the user asked")
                        if layout.fieldLines > 1 {
                            let used = ComposerMetrics.bottomInset + layout.composerHeight(lines: layout.fieldLines) + ComposerMetrics.spacing
                            XCTAssertGreaterThanOrEqual(layout.height - used, ComposerMetrics.minConversation, label + ": the conversation keeps its room")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(pane(.normal).fieldLines, 3)
        XCTAssertEqual(pane(.compact).fieldLines, 2, "A small island cannot spare a third line.")
        XCTAssertEqual(pane(.tall) { $0.inputLines = 6 }.fieldLines, 6)
        XCTAssertEqual(pane(.normal) { $0.inputLines = 6 }.fieldLines, 5, "Six lines would leave the conversation too little.")
        XCTAssertEqual(pane(.normal) { $0.inputLines = 1 }.fieldLines, 1)
    }

    func testTheQuestionCardAdaptsItsRowsToTheIsland() {
        XCTAssertEqual(pane(.compact).cardRows, 4, "A compact pane shows fewer rows (header 32 + rows + 7 must fit in 151 pt).")
        XCTAssertGreaterThan(pane(.tall).cardRows, 6)
        XCTAssertGreaterThan(pane(.tall).cardOptionsBesideMirror, 4, "A tall island leaves room for more options beside the conversation.")
        for preset in IslandPreset.allCases {
            let layout = pane(preset)
            let card = AgentPromptCard.cardHeight(options: 40, visibleRows: layout.cardRows)
            XCTAssertLessThanOrEqual(card, layout.cardRoom + 0.5, "\(preset.title): the card fits in the pane")
        }
        XCTAssertEqual(AgentPromptCard.cardHeight(options: 4, visibleRows: 6), 138)
        XCTAssertEqual(AgentPromptCard.cardHeight(options: 9, visibleRows: 6), 188, "Six rows and the header fill the Normal pane, as the card always did.")
    }

    func testTheListsOverTheConversationStayInsideTheIsland() {
        for preset in IslandPreset.allCases {
            let layout = pane(preset)
            XCTAssertLessThan(layout.tabListMaxHeight, layout.height, preset.title)
            XCTAssertLessThanOrEqual(layout.tabListWidth, layout.width - 2 * TabAgentListLayout.margin, preset.title)
            XCTAssertLessThanOrEqual(layout.recapWidth, layout.width - 24 + 0.5, preset.title)
            XCTAssertLessThanOrEqual(layout.capsuleListMaxHeight(composerHeight: 66), layout.height - 66 - ComposerMetrics.bottomInset + ComposerMetrics.topPadding, preset.title)
            XCTAssertGreaterThanOrEqual(layout.capsuleListMaxHeight(composerHeight: 66), 80, preset.title)
        }
        XCTAssertGreaterThan(pane(.tall).tabListMaxHeight, pane(.normal).tabListMaxHeight)
        XCTAssertLessThan(pane(.compact).tabListMaxHeight, pane(.normal).tabListMaxHeight)
    }

    func testAMenuWithMoreRowsScrollsOnlyPastTheNewLimit() {
        var state = SlashMenuState()
        let commands = (0..<30).map { SlashCommand(name: "cmd\($0)") }
        state.update(commands)
        state.setVisibleRows(10)
        XCTAssertEqual(state.visible, 10)
        for _ in 0..<8 { _ = state.press(.down) }
        XCTAssertEqual(state.top, 0, "Nine rows down is still inside a window of ten (one row of context below it).")
        for _ in 0..<5 { _ = state.press(.down) }
        XCTAssertGreaterThan(state.top, 0, "Past the window it scrolls.")
        XCTAssertGreaterThanOrEqual(state.highlighted, state.top)
        XCTAssertLessThan(state.highlighted, state.top + 10)
        state.setVisibleRows(4)
        XCTAssertLessThan(state.highlighted, state.top + 4, "A smaller window keeps the highlighted row in it.")
        XCTAssertGreaterThanOrEqual(state.highlighted, state.top)
        XCTAssertEqual(SlashMenuView.height(rows: 30, visible: 10), 10 * 22 - 1 + 8)
        XCTAssertEqual(SlashMenuView.height(rows: 3, visible: 10), 3 * 22 - 1 + 8, "Fewer commands than rows: the menu is as tall as its commands.")
    }

    // MARK: Fonts reach the views

    func testTheChatSizeReachesTheMirrorsStylingForTranscriptsAndPlainText() throws {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.setTheme(dark: true, transcript: true)
        let text = "> hola\n\n⏺ respuesta\n\n⏺ Read(a.swift)\n  ⎿  Read 3 lines\n"
        scroll.setText(text)
        func sizes() -> Set<CGFloat> {
            guard let storage = scroll.textView.textStorage else { return [] }
            var found = Set<CGFloat>()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let font = value as? NSFont { found.insert(font.pointSize) }
            }
            return found
        }
        /// The font of the characters of `word` in the mirror's text.
        func size(of word: String) throws -> CGFloat {
            let range = (scroll.textView.string as NSString).range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound, word)
            return try XCTUnwrap(scroll.textView.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont).pointSize
        }
        XCTAssertEqual(try size(of: "respuesta"), 11, "The default is 11 pt.")
        XCTAssertEqual(try size(of: "Read(a"), 10, "Tool lines are a point smaller.")
        scroll.setFontSize(16)
        XCTAssertEqual(try size(of: "respuesta"), 16, "Every voice is restyled with the new size.")
        XCTAssertEqual(try size(of: "hola"), 16, "…the user's message block too.")
        XCTAssertEqual(try size(of: "Read 3"), 15, "…and the tools' lines, still a point smaller.")
        XCTAssertEqual(scroll.font.pointSize, 16)
        // Text that arrives later is styled at the new size from the start.
        scroll.setText(text + "\n⏺ otra respuesta\n")
        XCTAssertEqual(try size(of: "otra"), 16)
        scroll.setFontSize(9)
        XCTAssertEqual(try size(of: "otra"), 9)
        XCTAssertEqual(try size(of: "hola"), 9)
        XCTAssertEqual(scroll.font.pointSize, 9)

        let plain = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        plain.setTheme(dark: true, transcript: false)
        plain.setText("$ ls\nfile.txt\n")
        plain.setFontSize(14)
        let storage = try XCTUnwrap(plain.textView.textStorage)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 14, "Plain output follows the size too.")
        plain.setText("$ ls\nfile.txt\n$ pwd\n")
        let tail = try XCTUnwrap(plain.textView.textStorage?.attribute(.font, at: (plain.textView.string as NSString).length - 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(tail.pointSize, 14, "…and so does what is added to it.")
    }

    func testABlankLineGrowsWithTheText() {
        XCTAssertEqual(TranscriptStyler.blankLineHeight(for: DisplaySettings.chatFont(size: 11)), TranscriptStyler.blankLineHeight, "9 pt at the default size.")
        XCTAssertGreaterThan(TranscriptStyler.blankLineHeight(for: DisplaySettings.chatFont(size: 18)), 9)
        XCTAssertLessThan(TranscriptStyler.blankLineHeight(for: DisplaySettings.chatFont(size: 9)), 9)
    }

    func testTheLiveTerminalFollowsTheChatSize() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-size-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-size-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        XCTAssertEqual(session.terminal.font.pointSize, 11)
        session.applyConsoleSize(15)
        XCTAssertEqual(session.terminal.font.pointSize, 15)
        XCTAssertTrue(session.terminal.font.isFixedPitch)
        session.applyConsoleSize(15)
        XCTAssertEqual(session.terminal.font.pointSize, 15)
        let mirror = session.makeMirror()
        defer { session.releaseMirror(mirror) }
        XCTAssertEqual(mirror.font.pointSize, 11, "A full-window mirror keeps its own size.")
    }

    // MARK: Resize drag

    func testDraggingACornerKeepsItUnderThePointer() {
        let start = CGSize(width: 572, height: 266)
        let right = IslandResizeDrag(corner: .right, startSize: start, startPointer: CGPoint(x: 1000, y: 800))
        XCTAssertEqual(right.size(at: CGPoint(x: 1000, y: 800)), start, "No movement, no change.")
        XCTAssertEqual(right.size(at: CGPoint(x: 1040, y: 800)).width, 652, "The right corner 40 pt out: the island is 80 pt wider (40 on each side).")
        XCTAssertEqual(right.size(at: CGPoint(x: 960, y: 800)).width, 492)
        XCTAssertEqual(right.size(at: CGPoint(x: 1000, y: 760)).height, 306, "Down is taller.")
        XCTAssertEqual(right.size(at: CGPoint(x: 1000, y: 840)).height, 226)
        let left = IslandResizeDrag(corner: .left, startSize: start, startPointer: CGPoint(x: 400, y: 800))
        XCTAssertEqual(left.size(at: CGPoint(x: 360, y: 800)).width, 652, "The left corner 40 pt out (to the left) widens it as well.")
        XCTAssertEqual(left.size(at: CGPoint(x: 440, y: 800)).width, 492)
    }

    func testTheGripAnswersOnlyOnTheCornersAndOnlyWhileTheIslandIsOpen() {
        let grip = IslandResizeGrip(frame: NSRect(x: 0, y: 0, width: 572, height: 266))
        let reach = IslandResizeGrip.reach
        XCTAssertEqual(grip.corner(at: NSPoint(x: 572 - reach / 2 + 2, y: reach / 2 + 2)), .right)
        XCTAssertEqual(grip.corner(at: NSPoint(x: reach / 2 - 2, y: reach / 2 + 2)), .left)
        XCTAssertNil(grip.corner(at: NSPoint(x: 572 - 1, y: 1)), "The very corner is outside the island's rounded shape: not a handle.")
        XCTAssertNil(grip.corner(at: NSPoint(x: 286, y: 10)), "The middle of the bottom edge is the composer's.")
        XCTAssertNil(grip.corner(at: NSPoint(x: 572 - 30, y: 10)), "Past the reach.")
        XCTAssertNil(grip.corner(at: NSPoint(x: 572 - 10, y: 30)), "Above the reach.")
        XCTAssertNotNil(grip.hitTest(NSPoint(x: 572 - 8, y: 12)))
        XCTAssertNil(grip.hitTest(NSPoint(x: 286, y: 130)), "Everywhere else clicks pass through.")
        grip.isActive = { false }
        XCTAssertNil(grip.hitTest(NSPoint(x: 572 - 8, y: 12)), "An island that is opening or closing has no handles.")
    }

    func testTheSendButtonIsNotUnderTheHandle() {
        // The send circle's right edge is 21 pt from the island's edge (15 margin + 6 padding) and 15 pt up (9 + 6).
        let grip = IslandResizeGrip(frame: NSRect(x: 0, y: 0, width: 572, height: 266))
        for y in stride(from: CGFloat(15), through: 43, by: 2) {
            XCTAssertNil(grip.corner(at: NSPoint(x: 572 - 21.5, y: y)), "y \(y)")
        }
    }
}

/// The settings card's window and the shortcuts that reach the island's panel.
@MainActor
final class SettingsWindowTests: XCTestCase {
    func testTheCardIsCentredOnTheNotchsAxisWhateverTheIslandsWidth() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let card = CGSize(width: 332, height: 340)
        var origins = Set<CGFloat>()
        for width in stride(from: CGFloat(440), through: 1400, by: 60) {
            let island = CGRect(x: screen.midX - width / 2, y: screen.maxY - 266, width: width, height: 266)
            let frame = SettingsPlacement.frame(island: island, screen: screen, card: card)
            origins.insert(frame.minX)
            XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.5, "Centred under the island")
            XCTAssertEqual(frame.maxY, island.minY - SettingsPlacement.gap, accuracy: 0.5, "A little under the island's bottom edge")
        }
        XCTAssertEqual(origins.count, 1, "The card does not move sideways while the island grows and shrinks: a slider under the pointer stays under it.")
    }

    func testTheCardKeepsInsideTheScreenAndFallsBackOverTheIslandWhenThereIsNoRoomBelow() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let card = CGSize(width: 332, height: 340)
        // An island at the very left of the screen (an external display's notch-less layout): the card stays inside.
        let corner = CGRect(x: 0, y: screen.maxY - 266, width: 500, height: 266)
        let beside = SettingsPlacement.frame(island: corner, screen: screen, card: card)
        XCTAssertGreaterThanOrEqual(beside.minX, SettingsPlacement.margin)
        // A tall island leaves 40 pt below it: the card sits over the island's lower part, inside the screen.
        let tall = CGRect(x: 322, y: 40, width: 636, height: 760)
        let over = SettingsPlacement.frame(island: tall, screen: screen, card: card)
        XCTAssertGreaterThanOrEqual(over.minY, screen.minY + SettingsPlacement.margin)
        XCTAssertLessThanOrEqual(over.maxY, tall.maxY)
        XCTAssertTrue(screen.contains(over))
    }

    func testTheWindowTakesTheCardsSizeAndFollowsTheIsland() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-settings-window-" + UUID().uuidString)!)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let window = SettingsWindow(model: model, screen: screen.size, topInset: 32, level: .normal) {}
        XCTAssertEqual(window.cardSize.width, SettingsCard.width)
        XCTAssertGreaterThan(window.cardSize.height, 250)
        // 460 before «Apariencia» (the three pictures of the island and their names) joined the card, which takes about 115 pt.
        XCTAssertLessThan(window.cardSize.height, 580, "The card is compact: a screen's worth of controls would not be a card.")
        let small = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: small, on: screen)
        XCTAssertFalse(window.isVisible, "Placing it does not show it.")
        let first = window.cardFrame
        XCTAssertEqual(first.midX, small.midX, accuracy: 0.5)
        let big = CGRect(x: screen.midX - 360, y: screen.maxY - 350, width: 720, height: 350)
        window.place(under: big, on: screen)
        XCTAssertEqual(window.cardFrame.minX, first.minX, accuracy: 0.5, "Same x for any width.")
        XCTAssertEqual(window.cardFrame.maxY, big.minY - SettingsPlacement.gap, accuracy: 0.5, "The card follows the island's bottom edge.")
    }

    func testSliderValuesSnapToFourPoints() {
        XCTAssertEqual(SettingsCard.snapped(571), 572)
        XCTAssertEqual(SettingsCard.snapped(573.9), 572)
        XCTAssertEqual(SettingsCard.snapped(574.1), 576)
        XCTAssertEqual(SettingsCard.snapped(440), 440)
    }

    func testThePanelHandsCommandKeysToTheIslandBeforeItsViews() throws {
        let panel = NotchPanel(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var seen: [ChatSizeShortcut] = []
        panel.onKeyEquivalent = { event in
            guard let shortcut = ChatSizeShortcut(event: event) else { return false }
            seen.append(shortcut)
            return true
        }
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(panel.performKeyEquivalent(with: key("=", .command, code: 24)))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("+", [.command, .shift], code: 24)))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("-", .command, code: 27)))
        XCTAssertTrue(panel.performKeyEquivalent(with: key("0", .command, code: 29)))
        XCTAssertEqual(seen, [.larger, .larger, .smaller, .reset])
        XCTAssertFalse(panel.performKeyEquivalent(with: key("x", .command, code: 7)), "Other command keys are not the island's.")
        XCTAssertEqual(seen.count, 4)
    }
}
