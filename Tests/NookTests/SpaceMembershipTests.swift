import AppKit
import XCTest
@testable import Nook

/// The island at the notch on every Space. Sample's Mac woke with its lid opened (2026-10-09 07:38) and from then on the collapsed island was not
/// there when he swiped to Microsoft Edge in full screen; the open island was. WindowServer said why: the collapsed island's window was a member of
/// the desktop (Space 1) only, the open island's of the desktop and Edge's full-screen Space (111). These tests give the windows that state through a
/// stand-in for WindowServer and check that each way back into view repairs it: a panel coming on screen, a swipe, a wake. The windows are a quiet
/// controller's (all but transparent, taking no pointer) or off every display, and the notifications are posted on a center of the test's own, so
/// nothing reaches the running app or the user's log.
@MainActor
final class SpaceMembershipTests: XCTestCase {
    /// WindowServer as Sample's Mac had it: one display with the desktop and Edge's full-screen Space.
    private final class FakeSpaces: SpaceBackend {
        var isAvailable = true
        var displays: [[UInt64]] = [[1, 111]]
        var memberships: [Int: [UInt64]] = [:]
        /// The Spaces WindowServer refuses to add a window to (the call answers nothing either way).
        var refused: Set<UInt64> = []
        private(set) var added: [(window: Int, spaces: [UInt64])] = []
        private(set) var asked: [Int] = []
        func spaces(of windowNumber: Int) -> [UInt64] { asked.append(windowNumber); return memberships[windowNumber] ?? [] }
        func displaySpaces() -> [[UInt64]] { displays }
        func add(_ windowNumber: Int, to spaces: [UInt64]) {
            added.append((windowNumber, spaces))
            memberships[windowNumber] = ((memberships[windowNumber] ?? []) + spaces.filter { !refused.contains($0) }).sorted()
        }
        @MainActor func addedSpaces(of window: NSWindow) -> [[UInt64]] { added.filter { $0.window == window.windowNumber }.map(\.spaces) }
    }

    private var original: SpaceMembership!
    private var spaces: FakeSpaces!
    private var journal: [String] = []
    private var windows: [NSWindow] = []
    private var controllers: [(AppModel, NotchController)] = []

    override func setUp() {
        super.setUp()
        original = SpaceMembership.shared
        spaces = FakeSpaces()
        journal = []
        SpaceMembership.shared = SpaceMembership(backend: spaces) { [weak self] line in self?.journal.append(line) }
    }

    override func tearDown() {
        for (model, controller) in controllers {
            controller.collapse(force: true)
            controller.panel.orderOut(nil); controller.petPanel.orderOut(nil)
            model.controller = nil
        }
        controllers = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        SpaceMembership.shared = original
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A sticky panel like the island's, far off every display.
    private func stickyPanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 40, height: 20), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.allowsKey = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.alphaValue = 0.01; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.spaceRole = "prueba"
        windows.append(panel)
        return panel
    }

    /// A quiet controller listening on `center`, with the island collapsed or open and settled.
    private func controller(expanded: Bool, center: NotificationCenter) throws -> NotchController {
        try XCTSkipIf(NSScreen.screens.isEmpty, "There is no display to put the island on.")
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-spaces-" + UUID().uuidString)!)
        // Open, it stays open while the test looks, wherever the pointer is.
        model.pinned = expanded
        let controller = NotchController(model: model, quiet: true, workspace: center)
        controllers.append((model, controller))
        controller.expand(focus: false)
        if !expanded {
            controller.collapse(force: true)
            let end = Date().addingTimeInterval(3)
            while Date() < end, controller.panel.isVisible || !controller.petPanel.isVisible { settle(0.05) }
        } else { settle(0.5) }
        XCTAssertEqual(controller.petPanel.isVisible, !expanded); XCTAssertEqual(controller.panel.isVisible, expanded)
        return controller
    }

    // MARK: Which Spaces are missing

    func testTheMissingSpacesAreThoseOfTheWindowsDisplayItIsNotIn() {
        // Sample's collapsed island after the wake, and his open one.
        XCTAssertEqual(SpaceMembership.missing(current: [1], displays: [[1, 111]]), [111])
        XCTAssertEqual(SpaceMembership.missing(current: [1, 111], displays: [[1, 111]]), [])
        XCTAssertEqual(SpaceMembership.missing(current: [111], displays: [[1, 111]]), [1], "Missing from the desktop it is on is missing too.")
        // With a second display, only the Spaces of the window's own display count.
        XCTAssertEqual(SpaceMembership.missing(current: [5], displays: [[1, 111], [5, 7, 9]]), [7, 9])
        XCTAssertEqual(SpaceMembership.missing(current: [1], displays: [[1, 111], [5, 7]]), [111])
        // A window in no Space yet is still being ordered in: WindowServer makes it a member of every Space itself.
        XCTAssertEqual(SpaceMembership.missing(current: [], displays: [[1, 111]]), [])
        XCTAssertEqual(SpaceMembership.missing(current: [42], displays: [[1, 111]]), [], "A Space no display has is not something to repair from.")
    }

    func testWindowServersDescriptionIsReadAsEachDisplaysSpaces() {
        // CGSCopyManagedDisplaySpaces on Sample's Mac (2026-10-09), with the keys it had.
        let displays: [[String: Any]] = [[
            "Display Identifier": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            "Current Space": ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""],
            "Spaces": [
                ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""],
                ["ManagedSpaceID": 111, "id64": 111, "type": 4, "uuid": "AE0E618F-C364-4591-BB6F-410BE2A8FC9B", "fs_wid": 9052, "pid": 1229,
                 "TileLayoutManager": [String: Any](), "WallSpace": [String: Any]()],
            ],
        ]]
        XCTAssertEqual(WindowServerSpaces.parse(displays), [[1, 111]])
        XCTAssertEqual(WindowServerSpaces.parse([["Spaces": [["id64": 3], ["id64": 4]]]]), [[3, 4]], "Only id64: still read.")
        XCTAssertEqual(WindowServerSpaces.parse([["Spaces": [[String: Any]]()], ["Display Identifier": "Main"]]), [], "A display with no Spaces says nothing.")
    }

    func testTheSpacesLogKeepsItsNewestHalfPastItsLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nook-spaces-\(UUID().uuidString)/spaces.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SpacesJournal.write("primera\n", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "primera\n", "The folder is made when it is missing.")
        let line = String(repeating: "x", count: 999) + "\n"
        for _ in 0..<70 { SpacesJournal.write(line, to: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(text.utf8.count, SpacesJournal.limit + line.utf8.count)
        XCTAssertFalse(text.contains("primera"), "The oldest lines go first.")
        XCTAssertTrue(text.hasSuffix(line))
    }

    /// The log is the user's alone: made with mode 0600, and one an earlier build left readable by others is made private when next written.
    func testTheSpacesLogIsReadableByTheUserAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-spaces-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func mode(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) }
        let fresh = folder.appendingPathComponent("spaces.log")
        SpacesJournal.write("primera\n", to: fresh)
        XCTAssertEqual(try mode(fresh), 0o600)
        for _ in 0..<70 { SpacesJournal.write(String(repeating: "x", count: 999) + "\n", to: fresh) }
        XCTAssertEqual(try mode(fresh), 0o600, "Trimming past the limit keeps the mode.")
        let old = folder.appendingPathComponent("old.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: old.path, contents: Data("antes\n".utf8), attributes: [.posixPermissions: 0o644]))
        SpacesJournal.write("después\n", to: old)
        XCTAssertEqual(try mode(old), 0o600)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "antes\ndespués\n", "Made private without losing what it held.")
    }

    func testWindowServersCallsAreFoundOnThisMac() {
        XCTAssertTrue(WindowServerSpaces().isAvailable, "Looked up by name; without them the island could not be repaired.")
    }

    // MARK: Repairing a window

    func testAStickyPanelMissingTheFullScreenSpaceIsAddedToItAndTheLogSaysSo() {
        let panel = stickyPanel()
        spaces.memberships[panel.windowNumber] = [1]
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [111])
        XCTAssertEqual(spaces.addedSpaces(of: panel), [[111]])
        XCTAssertEqual(journal, ["prueba · prueba: faltaba en 111 (estaba en 1); añadida, ahora en 1·111"])
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [], "On every Space now: nothing more to do.")
        XCTAssertEqual(spaces.added.count, 1)
    }

    /// `CGSAddWindowsToSpaces` answers nothing: the log says what WindowServer shows afterwards, never a repair that did not happen.
    func testTheLogSaysWhatTheWindowIsReallyInAfterTheAdd() {
        let panel = stickyPanel()
        spaces.memberships[panel.windowNumber] = [1]
        spaces.refused = [111]
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [], "Nothing gained: nothing reported as repaired.")
        XCTAssertEqual(journal.last, "prueba · prueba: faltaba en 111 (estaba en 1); no se pudo añadir (sigue en 1)")
        // A second full-screen app: one Space taken, the other refused.
        spaces.displays = [[1, 111, 222]]
        spaces.refused = [222]
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [111])
        XCTAssertEqual(journal.last, "prueba · prueba: faltaba en 111·222 (estaba en 1); añadida a 111 pero sigue faltando en 222, ahora en 1·111")
        // A refused repair does not count as one for the controller's checks either.
        XCTAssertEqual(SpaceMembership.shared.rejoinVisible([panel], reason: "prueba"), 0, "Not on screen: not looked at.")
        panel.orderFrontRegardless()
        XCTAssertEqual(SpaceMembership.shared.rejoinVisible([panel], reason: "prueba"), 0, "Still missing 222, and nothing was gained.")
    }

    func testAWindowThatIsNotStickyInNoSpaceYetOrWithoutWindowServersCallsIsLeftAlone() {
        let panel = stickyPanel()
        spaces.memberships[panel.windowNumber] = []
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [], "Still being ordered in.")
        spaces.memberships[panel.windowNumber] = [1]
        panel.collectionBehavior = [.moveToActiveSpace]
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [], "Only windows meant to be on every Space.")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        spaces.isAvailable = false
        XCTAssertEqual(SpaceMembership.shared.rejoin(panel, reason: "prueba"), [], "Without the calls nothing is changed.")
        XCTAssertTrue(spaces.added.isEmpty); XCTAssertTrue(journal.isEmpty)
    }

    /// The collapsed island's window was put away while the island was open; it lost Edge's Space meanwhile. Coming back on screen as the island
    /// closes is the moment it is repaired, before the user can swipe.
    func testAPanelComingOnScreenIsRepairedOnTheWayInOnly() {
        let panel = stickyPanel()
        spaces.memberships[panel.windowNumber] = [1]
        panel.orderFrontRegardless()
        XCTAssertEqual(spaces.addedSpaces(of: panel), [[111]])
        XCTAssertEqual(journal.first, "al mostrarse · prueba: faltaba en 111 (estaba en 1); añadida, ahora en 1·111")
        // Already on screen (the drag ghost is ordered on every move of the pointer): nothing is asked.
        let asked = spaces.asked.count
        panel.orderFrontRegardless(); panel.order(.above, relativeTo: 0)
        XCTAssertEqual(spaces.asked.count, asked)
        // Put away and lost again, then ordered in by the other ways AppKit has.
        panel.orderOut(nil); spaces.memberships[panel.windowNumber] = [1]
        panel.order(.below, relativeTo: 0)
        XCTAssertEqual(spaces.addedSpaces(of: panel), [[111], [111]])
        panel.orderOut(nil); spaces.memberships[panel.windowNumber] = [1]
        panel.orderOut(nil)
        XCTAssertEqual(spaces.added.count, 2, "Ordering out repairs nothing: a window out of view is seen to when it comes back.")
    }

    // MARK: The controller

    /// Sample's case: collapsed, then a swipe to the full-screen app. The cat's window is added to the Space he arrives at.
    func testASwipeGivesTheCollapsedIslandTheSpaceItWasMissing() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: false, center: center)
        spaces.memberships[controller.petPanel.windowNumber] = [1]
        spaces.memberships[controller.panel.windowNumber] = [1]
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(spaces.addedSpaces(of: controller.petPanel), [[111]])
        XCTAssertTrue(spaces.addedSpaces(of: controller.panel).isEmpty, "The open island's window is put away: it is seen to when it comes back.")
        XCTAssertTrue(controller.petPanel.isVisible)
        XCTAssertTrue(NotchController.sameFrame(controller.petPanel.frame, controller.compactFrame), "\(controller.petPanel.frame)")
        XCTAssertEqual(journal, ["cambio de espacio · isla cerrada: faltaba en 111 (estaba en 1); añadida, ahora en 1·111"])
        // AppKit keeps the window on whole points while the notch's centre falls on a half (633 against 633.5 on this Mac): a swipe does not take
        // that for a move and set the frame again.
        let frame = controller.petPanel.frame
        XCTAssertTrue(NotchController.sameFrame(NSRect(x: 633, y: 950, width: 245, height: 32), NSRect(x: 633.5, y: 950, width: 245, height: 32)))
        XCTAssertFalse(NotchController.sameFrame(NSRect(x: 333, y: 650, width: 245, height: 32), NSRect(x: 633.5, y: 950, width: 245, height: 32)))
        // Swiping on: nothing left to repair, nothing written, nothing moved.
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(spaces.added.count, 1); XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(controller.petPanel.frame, frame)
    }

    func testASwipeGivesTheOpenIslandTheSpaceItWasMissing() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: true, center: center)
        spaces.memberships[controller.panel.windowNumber] = [1]
        spaces.memberships[controller.petPanel.windowNumber] = [1]
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(spaces.addedSpaces(of: controller.panel), [[111]])
        XCTAssertTrue(spaces.addedSpaces(of: controller.petPanel).isEmpty)
        XCTAssertTrue(controller.panel.isVisible); XCTAssertFalse(controller.petPanel.isVisible, "Open, the cat's window stays away.")
    }

    /// After a wake the windows are checked without waiting for a swipe: the first check writes what it found, then repairs. A cat's window that
    /// something had put away and moved comes back at the notch.
    func testAWakeRepairsTheIslandBeforeAnySwipeAndLeavesEvidence() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: false, center: center)
        controller.petPanel.orderOut(nil)
        controller.petPanel.setFrameOrigin(NSPoint(x: controller.compactFrame.minX - 300, y: controller.compactFrame.minY - 300))
        spaces.memberships[controller.petPanel.windowNumber] = [1]
        spaces.memberships[controller.panel.windowNumber] = [1, 111]
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(controller.petPanel.isVisible, "Not at once: WindowServer and the Dock are still putting the Spaces back.")
        let end = Date().addingTimeInterval(3)
        while Date() < end, !controller.petPanel.isVisible { settle(0.05) }
        XCTAssertTrue(controller.petPanel.isVisible)
        XCTAssertTrue(NotchController.sameFrame(controller.petPanel.frame, controller.compactFrame), "Back at the notch: \(controller.petPanel.frame)")
        XCTAssertEqual(spaces.addedSpaces(of: controller.petPanel), [[111]])
        XCTAssertEqual(journal.count, 3, journal.joined(separator: "\n"))
        XCTAssertTrue(journal[0].hasPrefix("despertar · isla cerrada: oculta, "), journal[0])
        XCTAssertTrue(journal[0].contains("espacios 1 de 1·111 · isla abierta: oculta, "), journal[0])
        XCTAssertTrue(journal[0].hasSuffix("espacios 1·111 de 1·111"), journal[0])
        // Coming back on screen repaired it on its way in; the check found nothing more to do.
        XCTAssertEqual(journal[1], "al mostrarse · isla cerrada: faltaba en 111 (estaba en 1); añadida, ahora en 1·111")
        XCTAssertEqual(journal[2], "despertar · isla cerrada: no estaba en pantalla, vuelve a mostrarse")
    }

    func testTheChecksAfterAWakeRunAgainAndANewNotificationStartsThemOver() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: false, center: center)
        controller.checkSpacesSoon(reason: "despertar", delays: [0.05, 0.3])
        controller.checkSpacesSoon(reason: "sesión activa", delays: [0.1, 0.4])
        // Lost between the two checks: the later one gives it back.
        settle(0.2)
        spaces.memberships[controller.petPanel.windowNumber] = [1]
        settle(0.4)
        XCTAssertEqual(journal.filter { $0.hasPrefix("despertar") }, [], "The first series was replaced by the second.")
        XCTAssertEqual(journal.filter { $0.hasPrefix("sesión activa") }.count, 2, journal.joined(separator: "\n"))
        XCTAssertTrue(journal.last?.hasPrefix("sesión activa · isla cerrada: faltaba en 111") == true, journal.joined(separator: "\n"))
    }

    /// A swipe while the island is closing does not bring the cat out under the shape that is still on its way to the notch.
    func testASwipeWhileTheIslandClosesWaitsForItToClose() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: true, center: center)
        controller.model.pinned = false
        controller.collapse(force: true)
        guard controller.panel.isVisible else { throw XCTSkip("With Reduce Motion the island closes at once: there is no closing to wait for.") }
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertFalse(controller.petPanel.isVisible)
        let end = Date().addingTimeInterval(3)
        while Date() < end, !controller.petPanel.isVisible { settle(0.05) }
        XCTAssertTrue(controller.petPanel.isVisible); XCTAssertFalse(controller.panel.isVisible)
    }

    func testAControllerLetGoOfLeavesItsWindowsClosed() throws {
        let center = NotificationCenter()
        let controller = try controller(expanded: false, center: center)
        controller.petPanel.orderOut(nil)
        controller.model.controller = nil
        controller.keepOnEverySpace(reason: "cambio de espacio")
        XCTAssertFalse(controller.petPanel.isVisible)
        controller.model.controller = controller
    }
}
