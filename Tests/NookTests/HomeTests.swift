import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The home and the greeting (`HomeView.swift`): that they come when they should, that the home fits every island there can be (the stage and the cards are measured for the room
/// they have), that the cat on its stage is a whole cat, and the words.
@MainActor
final class HomeTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-home-" + UUID().uuidString)! }
    private func model(welcomed: Bool, defaults: UserDefaults? = nil) -> AppModel {
        let defaults = defaults ?? suite()
        if welcomed { defaults.set(true, forKey: AppModel.welcomedKey) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.resting = true
        model.terminalBridge.loginStampsReader = { [:] }
        return model
    }
    private func tab(_ tty: String = "/dev/ttys0" + String(Int.random(in: 10...99))) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 7, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["login", "-zsh"], busy: false, selected: true, text: "")
    }

    // MARK: When

    func testTheFirstRunGetsTheGreetingAndTheEmptyIslandAfterItGetsTheHome() {
        let model = model(welcomed: false)
        XCTAssertTrue(model.showsGreeting, "a Mac that never ran Nook is greeted")
        model.markWelcomed()
        XCTAssertFalse(model.showsGreeting, "dismissing it ends it for good")
        XCTAssertTrue(model.sessions.isEmpty, "and the island, with no tab, shows the home")
    }

    func testStartingUsingNookEndsTheGreeting() {
        let model = model(welcomed: false)
        XCTAssertTrue(model.showsGreeting)
        model.connectTerminalTab(tab())
        XCTAssertFalse(model.showsGreeting, "the first tab is the user starting")
        XCTAssertTrue(model.hasBeenWelcomed)
    }

    /// The user who already has tabs never saw the greeting; Ajustes brings it back, over whatever the island has, until it is closed.
    func testTheGreetingCanBeAskedForAgainWithTabsOpen() {
        let model = model(welcomed: true)
        model.connectTerminalTab(tab())
        XCTAssertFalse(model.showsGreeting)
        model.greetingReplay = true
        XCTAssertTrue(model.showsGreeting, "tabs or not")
        model.greetingReplay = false
        XCTAssertFalse(model.showsGreeting)
        XCTAssertFalse(model.sessions.isEmpty, "the tabs were there all along")
    }

    func testAReplayDoesNotChangeWhatIsSaved() {
        let defaults = suite()
        let model = model(welcomed: true, defaults: defaults)
        model.greetingReplay = true
        XCTAssertNil(defaults.object(forKey: "greetingReplay"))
        XCTAssertTrue(AppModel(receivesSignals: false, defaults: defaults).hasBeenWelcomed)
        XCTAssertFalse(AppModel(receivesSignals: false, defaults: defaults).greetingReplay, "a replay lasts until it is closed, not across launches")
    }

    // MARK: What fits

    private func neck(_ screenNotch: Bool) -> CGFloat { screenNotch ? 32 : 28 }

    /// The home's room is the island's body: its width and its height less the header's strip. Every size the island can be (the presets, the smallest, a very wide one and a very
    /// tall one), with a notch and without, gives the home a stage and cards that fit it.
    func testTheHomeFitsEveryIsland() {
        var sizes: [(String, CGSize)] = []
        for notch in [true, false] {
            for preset in IslandPreset.allCases {
                let island = NotchGeometry.expandedSize(screen: CGSize(width: 10_000, height: 10_000), topInset: neck(notch), settings: DisplaySettings().applying(preset))
                sizes.append(("\(preset.title), notch \(notch)", CGSize(width: island.width, height: island.height - neck(notch))))
            }
            var smallest = DisplaySettings()
            smallest.widthExtra = -140; smallest.heightExtra = -80
            let least = NotchGeometry.expandedSize(screen: CGSize(width: 10_000, height: 10_000), topInset: neck(notch), settings: smallest)
            sizes.append(("smallest, notch \(notch)", CGSize(width: least.width, height: least.height - neck(notch))))
        }
        sizes.append(("very wide", CGSize(width: 1400, height: 330)))
        sizes.append(("very tall", CGSize(width: 572, height: 900)))
        for (name, size) in sizes {
            let metrics = HomeMetrics.of(size: size)
            let room = size.height - HomeMetrics.topInset - HomeMetrics.bottomInset
            XCTAssertLessThanOrEqual(metrics.height, room + 0.5, "\(name): the content (\(metrics.height)) fits the room (\(room))")
            XCTAssertGreaterThanOrEqual(metrics.stage.height, HomeMetrics.leastStage, name)
            XCTAssertLessThanOrEqual(metrics.stage.height, HomeMetrics.mostStage, name)
            XCTAssertLessThanOrEqual(metrics.contentWidth, min(size.width - 2 * HomeMetrics.sideInset, HomeMetrics.widest) + 0.5, name)
            // The stage leaves the words a column of their own.
            XCTAssertGreaterThanOrEqual(metrics.contentWidth - HomeMetrics.heroGap - metrics.stage.width, 190, "\(name): room for the words beside the stage")
            XCTAssertGreaterThanOrEqual(metrics.cardHeight, 44, name)
        }
    }

    /// The cat on its stage is a whole cat: its tail to the left of home and its body (and a raised paw) to the right fit in the stage's width, and it fits its height.
    func testTheCatFitsItsStage() {
        for height in stride(from: HomeMetrics.leastStage, through: 188, by: 6) {
            for width in [CGFloat(112), 150, 190, 240] {
                for fraction in [HomeMetrics.homeFraction, 0.5] {
                    let stage = CGSize(width: width, height: height)
                    let scale = HomeMetrics.scale(stage: stage, homeFraction: fraction)
                    XCTAssertGreaterThan(scale, 0)
                    let home = width * fraction
                    // The painted extent of a cat: its tail 19.5 rig units behind home, its body and a raised paw 22 in front; 31.4 units tall, standing `ground` points up.
                    if scale > 0.8 {
                        XCTAssertGreaterThanOrEqual(home - 19.5 * scale, 5.9, "the tail fits (stage \(stage), home at \(fraction))")
                        XCTAssertLessThanOrEqual(home + PetAnimation.reach.right * scale, width - 5.9, "the paw fits")
                        XCTAssertLessThanOrEqual(HomePetView.ground + 31.4 * scale, height - 4.9, "and the ears")
                    }
                }
            }
        }
    }

    func testTheHomeCatHasRoomToStrollOnItsOwnStage() {
        for size in [CGSize(width: 572, height: 234), CGSize(width: 500, height: 190), CGSize(width: 440, height: 147 + 23), CGSize(width: 572, height: 486), CGSize(width: 720, height: 350)] {
            let metrics = HomeMetrics.of(size: size)
            let travel = metrics.stage.width - metrics.stage.width * HomeMetrics.homeFraction - PetAnimation.reach.right * metrics.scale - 4
            XCTAssertGreaterThanOrEqual(travel, PetStage.leastTravel, "a stage of \(metrics.stage) in an island's body of \(size) lets the cat walk")
        }
    }

    func testNarrowIslandsGetSnugCards() {
        XCTAssertTrue(HomeMetrics.of(size: CGSize(width: 440, height: 170)).snugCards)
        XCTAssertTrue(HomeMetrics.of(size: CGSize(width: 500, height: 190)).snugCards)
        XCTAssertFalse(HomeMetrics.of(size: CGSize(width: 572, height: 234)).snugCards)
        XCTAssertTrue(HomeMetrics.of(size: CGSize(width: 572, height: 234)).showsCardDetail, "the default island has the second line")
        XCTAssertFalse(HomeMetrics.of(size: CGSize(width: 440, height: 170)).showsCardDetail)
    }

    func testTheStageGrowsWithTheRoomButNotWithoutEnd() {
        let small = HomeMetrics.of(size: CGSize(width: 572, height: 200)).stage.height
        let normal = HomeMetrics.of(size: CGSize(width: 572, height: 234)).stage.height
        let tall = HomeMetrics.of(size: CGSize(width: 572, height: 700)).stage.height
        XCTAssertLessThan(small, normal)
        XCTAssertLessThanOrEqual(normal, tall)
        XCTAssertEqual(tall, HomeMetrics.mostStage)
    }

    // MARK: The words

    func testTheCatSaysGoodDayByTheHour() {
        XCTAssertEqual(HomeCopy.overline(hour: 7), "Buenos días")
        XCTAssertEqual(HomeCopy.overline(hour: 12), "Buenos días")
        XCTAssertEqual(HomeCopy.overline(hour: 13), "Buenas tardes")
        XCTAssertEqual(HomeCopy.overline(hour: 19), "Buenas tardes")
        XCTAssertEqual(HomeCopy.overline(hour: 20), "Buenas noches")
        XCTAssertEqual(HomeCopy.overline(hour: 3), "Buenas noches")
        for hour in 0..<24 { XCTAssertFalse(HomeCopy.overline(hour: hour).isEmpty) }
    }

    func testTheCardsOpenWhatTheirNamesSayInTheOrderTheyAreOffered() {
        XCTAssertEqual(HomeCopy.kinds, [.claude, .codex, .shell])
        XCTAssertEqual(Set(HomeCopy.kinds), Set(SessionKind.allCases), "every way to start has a card")
        for kind in HomeCopy.kinds {
            XCTAssertFalse(HomeCopy.detail(kind).isEmpty)
            XCTAssertTrue(HomeCopy.spoken(kind).contains("Terminal"), "it says where the session opens")
        }
        XCTAssertTrue(HomeCopy.spoken(.claude).contains("Claude Code"))
        XCTAssertTrue(HomeCopy.spoken(.codex).contains("Codex"))
    }

    func testTheGreetingSaysWhoNookIsAndWhatItDoes() {
        XCTAssertEqual(HomeCopy.greetingTitle, "¡Hola! Soy Nook.")
        XCTAssertEqual(HomeCopy.features.count, 3)
        for feature in HomeCopy.features {
            XCTAssertNotNil(NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil), feature.symbol)
            XCTAssertFalse(feature.title.isEmpty); XCTAssertFalse(feature.detail.isEmpty)
        }
        XCTAssertEqual(HomeCopy.start, "Empezar")
        XCTAssertEqual(HomeCopy.understood, "Entendido")
    }

    func testEverySymbolOfTheHomeExists() {
        for name in HomeCopy.kinds.map(\.symbol) + ["arrow.up.right", "link", "hand.draw", "arrow.right", "heart.fill", "power", "speaker.slash.fill", "speaker.wave.2.fill", "hand.wave"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    // MARK: The cat talks

    func testWhatTheCatSaysGoesByItself() async throws {
        let talk = HomeTalk()
        talk.say("¡Miau!", for: 0.15)
        XCTAssertEqual(talk.line, "¡Miau!")
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertNil(talk.line)
    }

    func testANewLineTakesTheOldOnesPlaceAndHushingOnlyStopsWhatWasSaid() async throws {
        let talk = HomeTalk()
        talk.say("uno", for: 0.2)
        talk.say("dos", for: 5)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(talk.line, "dos", "the first line's end did not take the second away")
        talk.hush("otra cosa")
        XCTAssertEqual(talk.line, "dos")
        talk.hush("dos")
        XCTAssertNil(talk.line)
        talk.say("tres", for: 5)
        talk.hush()
        XCTAssertNil(talk.line)
    }

    // MARK: The cat

    /// A cat that must not move is drawn as the pose it is given, with no timer at all, whether or not it could be seen.
    func testTheHomeCatHoldsAPoseWithNoTimer() {
        let view = HomePetView(frame: NSRect(x: 0, y: 0, width: 200, height: 110))
        view.scale = 2.8
        view.still = PetAnimation.wave(time: 0.2, amount: 1)
        XCTAssertEqual(view.pose.action, .wave)
        XCTAssertEqual(view.frameInterval, 0, "a still cat has no timer")
        view.animated = true
        view.wake()
        XCTAssertEqual(view.frameInterval, 0, "and asking for motion does not start one while a pose is held")
        view.still = nil
    }

    /// With the pets' animations off the cat is the still pose of its state, and nothing runs.
    func testTheHomeCatStandsStillWhenTheAnimationsAreOff() {
        let view = HomePetView(frame: NSRect(x: 0, y: 0, width: 200, height: 110))
        view.animated = false
        view.wake()
        XCTAssertEqual(view.frameInterval, 0)
        XCTAssertEqual(view.pose, PetPose(), "the idle sit")
    }

    func testTheCatIsPaintedWhereItsStandsAndItsRectIsAroundIt() {
        let view = HomePetView(frame: NSRect(x: 0, y: 0, width: 200, height: 110))
        view.scale = 2.8
        let rect = view.catRect()
        XCTAssertTrue(NSRect(x: 0, y: 0, width: 200, height: 110).contains(rect.insetBy(dx: 4, dy: 3)), "the cat is inside its stage: \(rect)")
        XCTAssertTrue(rect.contains(NSPoint(x: view.homeX, y: HomePetView.ground + 10 * view.scale)), "its body is on it")
        XCTAssertFalse(rect.contains(NSPoint(x: 190, y: 100)), "the empty corner is not the cat")
    }
}
