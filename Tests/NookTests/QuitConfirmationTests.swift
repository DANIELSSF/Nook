import AppKit
import XCTest
@testable import Nook

/// Quitting asks first, in the island, without a modal loop: AppKit's quit is cancelled while the question is up, and the answer
/// "Salir" quits again with a one-shot pass. ⌘Q again while it is up confirms; the Mac logging out, restarting or shutting down,
/// and another app's quit, never wait for it. Nothing here quits the test process: the model's own way of quitting is inert.
@MainActor
final class QuitConfirmationTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-quit-" + UUID().uuidString)!)
    }

    // MARK: Who asks

    private func quitEvent(reason: OSType? = nil, asParameter: Bool = false) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            let value = NSAppleEventDescriptor(enumCode: reason)
            if asParameter { event.setParam(value, forKeyword: AEKeyword(kAEQuitReason)) } else { event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason)) }
        }
        return event
    }

    func testNooksOwnMenusAndCommandQAsk() {
        XCTAssertEqual(QuitRequest(event: nil), .user, "⌘Q and the menus' items call terminate with no Apple event")
        XCTAssertTrue(QuitRequest(event: nil).asks)
        let open = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertEqual(QuitRequest(event: open), .user, "another event being handled is no quit event")
    }

    func testLogoutRestartAndShutdownNeverWait() {
        for reason: OSType in [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown] {
            XCTAssertEqual(QuitRequest(event: quitEvent(reason: reason)), .system)
            XCTAssertEqual(QuitRequest(event: quitEvent(reason: reason, asParameter: true)), .system)
            XCTAssertFalse(QuitRequest(event: quitEvent(reason: reason)).asks)
        }
    }

    func testAnotherAppsQuitAsksToo() {
        XCTAssertEqual(QuitRequest(event: quitEvent()), .external, "a script's or Activity Monitor's quit carries no reason")
        XCTAssertEqual(QuitRequest(event: quitEvent(reason: OSType(0x7878_7878))), .external)
        XCTAssertTrue(QuitRequest.external.asks)
    }

    // MARK: The question

    func testQuittingAsksInTheIslandAndQuittingAgainConfirms() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        var quits = 0
        model.terminateApp = { quits += 1 }

        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel, "no modal loop: this quit is cancelled while the island asks")
        XCTAssertEqual(model.quitPrompt, QuitPrompt(id: 1))
        XCTAssertEqual(host.shown, 1)
        XCTAssertEqual(model.shouldTerminate(.user, keyRepeat: true), .terminateCancel, "⌘Q held down is one press: the key's repeats don't answer")
        XCTAssertEqual(model.quitPrompt, QuitPrompt(id: 1))
        XCTAssertEqual(host.shown, 1)
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow, "⌘Q again while it is up is the answer")
        XCTAssertNil(model.quitPrompt)
        XCTAssertEqual(quits, 0, "AppKit itself goes on quitting")
    }

    func testSalirQuitsOnceWithoutAskingAgain() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        var quits = 0
        model.terminateApp = { quits += 1 }
        _ = model.shouldTerminate(.user)
        model.answerQuit(true)
        XCTAssertNil(model.quitPrompt)
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(host.dismissed, 0)
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow, "the quit that follows passes straight through")
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel, "the pass is for that quit only")
        XCTAssertEqual(model.quitPrompt, QuitPrompt(id: 2))
    }

    func testQuedarmeTakesTheQuestionAway() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        var quits = 0
        model.terminateApp = { quits += 1 }
        _ = model.shouldTerminate(.user)
        model.answerQuit(false)
        XCTAssertNil(model.quitPrompt)
        XCTAssertEqual(host.dismissed, 1)
        XCTAssertEqual(quits, 0)
        model.answerQuit(false)
        XCTAssertEqual(host.dismissed, 1, "no question, nothing to take away")
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel, "the next quit asks again")
    }

    func testTheSystemQuitsAtOnceEvenWithTheQuestionUp() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        XCTAssertEqual(model.shouldTerminate(.system), .terminateNow)
        XCTAssertEqual(host.shown, 0)
        _ = model.shouldTerminate(.user)
        XCTAssertEqual(model.shouldTerminate(.system), .terminateNow)
        XCTAssertNil(model.quitPrompt)
    }

    func testAnotherAppsQuitAsksInTheIsland() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        XCTAssertEqual(model.shouldTerminate(.external), .terminateCancel, "a script's quit is confirmed like the user's own")
        XCTAssertEqual(host.shown, 1)
        XCTAssertNotNil(model.quitPrompt)
        XCTAssertEqual(model.shouldTerminate(.external), .terminateCancel, "a script's second quit is not the user's answer")
        XCTAssertNotNil(model.quitPrompt, "the question stays up")
        XCTAssertEqual(host.shown, 1, "and is not asked twice")
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow, "the user's own second ⌘Q is the answer")
        XCTAssertNil(model.quitPrompt)
    }

    func testTheQuestionGoesWithTheIsland() {
        let model = model(), host = RecordingQuitHost()
        model.quitPromptHost = host
        model.expanded = true
        _ = model.shouldTerminate(.user)
        XCTAssertNotNil(model.quitPrompt)
        model.expanded = false
        XCTAssertNil(model.quitPrompt, "a closed island never leaves the question up")
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel, "the next quit asks again")
    }

    func testWithoutAnIslandAPlainAlertAsks() {
        let model = model()
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow, "no island and no alert: nobody to ask, Nook quits")

        var asked = 0, answer = false
        model.quitFallback = { asked += 1; return answer }
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel)
        answer = true
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow)
        XCTAssertEqual(asked, 2)
        XCTAssertNil(model.quitPrompt, "the alert asked; the island has no question up")

        let host = RecordingQuitHost()
        host.canShowQuitPrompt = false
        model.quitPromptHost = host
        XCTAssertEqual(model.shouldTerminate(.user), .terminateNow)
        XCTAssertEqual(asked, 3, "an island that can't show it falls back to the alert")
        XCTAssertEqual(host.shown, 0)
    }

    // MARK: In the island

    /// The real island, quiet (invisible, deaf to the pointer) and never given the keyboard.
    private func island() throws -> (AppModel, NotchController, FocuslessQuitHost) {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = model()
        let controller = NotchController(model: model, quiet: true)
        let host = FocuslessQuitHost(controller)
        model.quitPromptHost = host
        addTeardownBlock {
            controller.collapse(force: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            controller.panel.close(); controller.petPanel.close()
            model.controller = nil
        }
        return (model, controller, host)
    }

    func testTheIslandOpensForTheQuestionAndGoesBackAfterQuedarme() throws {
        let (model, _, host) = try island()
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel)
        XCTAssertTrue(model.expanded, "the island opens to ask")
        model.answerQuit(false)
        XCTAssertEqual(host.dismissed, 1)
        XCTAssertFalse(model.expanded, "it opened for the question, so it closes again")
    }

    func testPuttingTheIslandAwayAnswersStay() throws {
        let (model, controller, host) = try island()
        _ = model.shouldTerminate(.user)
        controller.collapse()   // what Esc in a Nook session's terminal, a click outside or the pointer's timer end in
        XCTAssertNil(model.quitPrompt, "a collapse never leaves the question up unanswered")
        XCTAssertEqual(host.dismissed, 1)
        XCTAssertFalse(model.expanded, "it opened for the question, so it closes again")
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel, "and the next quit asks again")
    }

    func testTheIslandAsksOnlyWhereTheUserCanSeeIt() {
        XCTAssertTrue(NotchController.islandReachesUser(hasScreen: true, screensDark: false, windowsShow: true))
        XCTAssertFalse(NotchController.islandReachesUser(hasScreen: false, screensDark: false, windowsShow: true), "no screen to show it on")
        XCTAssertFalse(NotchController.islandReachesUser(hasScreen: true, screensDark: true, windowsShow: true), "the screens sleep, or the Mac is locked")
        XCTAssertFalse(NotchController.islandReachesUser(hasScreen: true, screensDark: false, windowsShow: false), "an island nobody can see")
    }

    func testAnIslandThatCannotBeSeenLeavesTheQuestionToThePlainAlert() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = model()
        let controller = NotchController(model: model, quiet: true)
        addTeardownBlock {
            controller.panel.close(); controller.petPanel.close()
            model.controller = nil
        }
        XCTAssertTrue(model.quitPromptHost === controller, "the island is the host")
        XCTAssertFalse(controller.canShowQuitPrompt, "a quiet island is all but invisible")
        var asked = 0
        model.quitFallback = { asked += 1; return false }
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel)
        XCTAssertEqual(asked, 1, "the plain alert asked instead")
        XCTAssertNil(model.quitPrompt, "no question went up where nobody could see it")
        XCTAssertFalse(model.expanded)
    }

    func testEscOnTheQuestionLeavesAnOpenIslandOpen() throws {
        let (model, controller, host) = try island()
        defer { withExtendedLifetime(host) {} }   // the model holds its host weakly
        controller.expand(focus: false)
        XCTAssertEqual(model.shouldTerminate(.user), .terminateCancel)
        controller.collapse(force: true)   // Esc and the chevron
        XCTAssertNil(model.quitPrompt)
        XCTAssertTrue(model.expanded, "it was open before the question: it stays")
        controller.collapse(force: true)
        XCTAssertFalse(model.expanded, "the next Esc puts it away as always")
    }
}

/// A host that records what the model asks of it.
final class RecordingQuitHost: QuitPromptHost {
    var canShowQuitPrompt = true
    private(set) var shown = 0, dismissed = 0
    func showQuitPrompt() { shown += 1 }
    func quitPromptDismissed() { dismissed += 1 }
}

/// The island's own handling, with the keyboard left where it is.
final class FocuslessQuitHost: QuitPromptHost {
    let controller: NotchController
    private(set) var dismissed = 0
    init(_ controller: NotchController) { self.controller = controller }
    /// The quiet island is invisible by design, so it would never say it can ask (`NotchController.canShowQuitPrompt`): this host
    /// stands for an island the user can see, whatever the test machine's screens are doing.
    var canShowQuitPrompt: Bool { true }
    func showQuitPrompt() { controller.showQuitPrompt(focus: false) }
    func quitPromptDismissed() { dismissed += 1; controller.quitPromptDismissed() }
}
