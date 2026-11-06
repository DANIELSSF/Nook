import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import Nook

/// Nook Remoto in the settings card: the five taps on the version in «Acerca de», the version line, the tab (in the bar only once unlocked), the words and the states of its pane, the QR
/// that carries the pairing link, and the pane working on a real `RemoteAccess` (the switch, the code following each new key, «Quitar», the full list, a failure, hiding the tab).
/// The server itself, its keys and its devices are `RemoteAccessTests`' and `RemoteSecurityTests`'. Windows are offscreen and borderless, nothing is clicked (an element is pressed the way
/// VoiceOver presses it), and the clipboard is never touched: the pane copies through a closure the test hands in.
@MainActor
final class RemoteSettingsTests: XCTestCase {
    private typealias Probe = SettingsTabBarProbe
    private typealias Copy = RemotePanePresentation

    private var remotes: [RemoteAccess] = []

    override func tearDown() {
        remotes.forEach { $0.stop() }
        remotes = []
        super.tearDown()
    }

    // MARK: Looking at the accessibility tree

    /// Where the node that says `text` is, from the window's top left: by its label (a button's, an element's) or, for a plain text, by its value (SwiftUI gives a text its words as its
    /// value, and no label). Nil when nothing says it.
    private func says(_ text: String, in window: NSWindow) -> NSRect? {
        // Tells the app assistive technology is on, once for the window.
        _ = Probe.node(text, in: window)
        guard let host = window.contentView else { return nil }
        func search(_ element: AnyObject) -> NSRect? {
            guard let node = element as? NSObject else { return nil }
            let said = [node.value(forKey: "accessibilityLabel"), node.value(forKey: "accessibilityValue")].compactMap { $0 as? String }
            if said.contains(text), let screen = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, screen != .zero {
                let inWindow = window.convertFromScreen(screen)
                return NSRect(x: inWindow.minX, y: host.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
            }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        for child in host.accessibilityChildren() ?? [] { if let found = search(child as AnyObject) { return found } }
        return nil
    }

    /// What VoiceOver reads after the label of the element with this label: its value, or, for an element that is not a control, its value description.
    private func valueOf(_ label: String, in window: NSWindow) -> String? {
        guard let node = Probe.node(label, in: window) else { return nil }
        return (node.value(forKey: "accessibilityValue") as? String) ?? (node.value(forKey: "accessibilityValueDescription") as? String)
    }

    // MARK: The five taps

    func testFiveTapsInARowUnlockAndTheThirdOneStartsToCountDown() {
        var taps = UnlockTapCounter()
        let outcomes = [0.0, 0.3, 0.6, 0.9, 1.2].map { taps.tap(at: $0) }
        XCTAssertEqual(outcomes, [.counting, .counting, .remaining(2), .remaining(1), .unlocked], "Two taps say nothing, the third says two are left, the fifth unlocks.")
        XCTAssertEqual(taps.count, 0, "Unlocking starts the count over.")
        XCTAssertEqual(UnlockTapCounter.needed, 5)
        XCTAssertEqual(UnlockTapCounter.hintsFrom, 3)
    }

    func testAPauseTooLongBetweenTapsStartsTheCountOver() {
        var taps = UnlockTapCounter()
        XCTAssertEqual(taps.tap(at: 0), .counting)
        XCTAssertEqual(taps.tap(at: 0.4), .counting)
        // The third tap comes after a pause longer than the window: it is the first of a new run, not the third of the old one.
        XCTAssertEqual(taps.tap(at: 0.4 + UnlockTapCounter.window + 0.1), .counting)
        XCTAssertEqual(taps.count, 1)
        let start = 0.4 + UnlockTapCounter.window + 0.1
        XCTAssertEqual([0.2, 0.4, 0.6, 0.8].map { taps.tap(at: start + $0) }, [.counting, .remaining(2), .remaining(1), .unlocked], "It takes five new taps in a row.")
    }

    func testAPauseExactlyAsLongAsTheWindowKeepsTheRun() {
        var taps = UnlockTapCounter()
        var now = 10.0
        var outcomes: [UnlockTapCounter.Outcome] = []
        for _ in 0..<UnlockTapCounter.needed { outcomes.append(taps.tap(at: now)); now += UnlockTapCounter.window }
        XCTAssertEqual(outcomes.last, .unlocked, "A pause as long as the window is not past it.")
        var slow = UnlockTapCounter()
        now = 10
        outcomes = []
        for _ in 0..<(2 * UnlockTapCounter.needed) { outcomes.append(slow.tap(at: now)); now += UnlockTapCounter.window + 0.01 }
        XCTAssertFalse(outcomes.contains(.unlocked), "A hair past the window every time never gets anywhere.")
        XCTAssertEqual(slow.count, 1)
    }

    func testTheWindowIsAboutTwoSeconds() {
        XCTAssertTrue((1.5...2).contains(UnlockTapCounter.window), "Long enough to read «Faltan 2 toques», short enough that a stray click does not add up: \(UnlockTapCounter.window)")
    }

    func testOnceUnlockedATapOnlySaysSoAndNothingCounts() {
        var taps = UnlockTapCounter()
        _ = taps.tap(at: 0); _ = taps.tap(at: 0.1)
        XCTAssertEqual(taps.tap(at: 0.2, alreadyUnlocked: true), .alreadyUnlocked)
        XCTAssertEqual(taps.count, 0)
        for time in stride(from: 0.3, through: 3, by: 0.3) { XCTAssertEqual(taps.tap(at: time, alreadyUnlocked: true), .alreadyUnlocked) }
        // Locked again (the tab was hidden): five taps are needed once more.
        XCTAssertEqual([4.0, 4.2, 4.4, 4.6, 4.8].map { taps.tap(at: $0) }, [.counting, .counting, .remaining(2), .remaining(1), .unlocked])
    }

    func testAClockThatGoesBackStartsTheCountOver() {
        var taps = UnlockTapCounter()
        _ = taps.tap(at: 100); _ = taps.tap(at: 100.2)
        XCTAssertEqual(taps.tap(at: 50), .counting, "Time that runs backwards is not a run of taps.")
        XCTAssertEqual(taps.count, 1)
    }

    func testTheLineSaysHowManyTapsAreLeftInTheRightNumber() {
        XCTAssertEqual(SettingsAboutCopy.remaining(2), "Faltan 2 toques para desbloquear Remoto")
        XCTAssertEqual(SettingsAboutCopy.remaining(1), "Falta 1 toque para desbloquear Remoto", "Singular for one.")
        XCTAssertEqual(SettingsAboutCopy.unlocked, "Nook Remoto desbloqueado")
        XCTAssertEqual(SettingsAboutCopy.alreadyUnlocked, "Nook Remoto ya está desbloqueado")
        XCTAssertNil(SettingsAboutNote.make(for: .counting), "The first taps say nothing.")
        let two = SettingsAboutNote.make(for: .remaining(2)), one = SettingsAboutNote.make(for: .remaining(1))
        XCTAssertEqual(two?.text, SettingsAboutCopy.remaining(2)); XCTAssertEqual(one?.text, SettingsAboutCopy.remaining(1))
        XCTAssertEqual(two?.lifetime, UnlockTapCounter.window, "A count goes when the pause that would start it over has passed: it is not true after that.")
        let done = SettingsAboutNote.make(for: .unlocked), already = SettingsAboutNote.make(for: .alreadyUnlocked)
        XCTAssertEqual(done?.kind, .done); XCTAssertEqual(done?.text, "Nook Remoto desbloqueado")
        XCTAssertEqual(already?.kind, .quiet); XCTAssertEqual(already?.text, "Nook Remoto ya está desbloqueado")
        XCTAssertGreaterThan(done?.lifetime ?? 0, 2, "The one that says it worked stays long enough to be read.")
    }

    // MARK: The version

    func testTheVersionLineIsReadFromTheBundleKeys() throws {
        XCTAssertEqual(NookVersion(info: ["CFBundleShortVersionString": "0.2.1", "CFBundleVersion": "3"]).line, "Nook 0.2.1 (3)")
        // The app's own Info.plist: whatever it says, the line is the two keys in this shape.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let short = try XCTUnwrap(info["CFBundleShortVersionString"] as? String), build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertEqual(NookVersion(info: info).line, "Nook \(short) (\(build))")
    }

    func testTheVersionLineFallsBackGracefully() {
        XCTAssertEqual(NookVersion(info: ["CFBundleShortVersionString": "0.2.1"]).line, "Nook 0.2.1")
        XCTAssertEqual(NookVersion(info: ["CFBundleVersion": "3"]).line, "Nook (3)")
        XCTAssertEqual(NookVersion(info: nil).line, "Nook (versión de desarrollo)", "No bundle at all: `swift run`.")
        XCTAssertEqual(NookVersion(info: [:]).line, "Nook (versión de desarrollo)")
        XCTAssertEqual(NookVersion(info: ["CFBundleShortVersionString": "  ", "CFBundleVersion": ""]).line, "Nook (versión de desarrollo)", "Blank is none.")
        XCTAssertEqual(NookVersion(info: ["CFBundleShortVersionString": 1, "CFBundleVersion": 2]).line, "Nook (versión de desarrollo)", "Not text is none.")
        XCTAssertEqual(NookVersion(short: " 0.2.1 \n", build: " 3 ").line, "Nook 0.2.1 (3)", "Spaces around it are not part of it.")
        // Under a test the bundle is the runner's: whatever it has, there is a line.
        XCTAssertTrue(NookVersion.current.line.hasPrefix("Nook"))
    }

    // MARK: The tab

    func testRemotoIsTheSeventhTabWithATitleAndASymbolOfItsOwn() {
        XCTAssertEqual(SettingsTab.remote.title, "Remoto")
        XCTAssertEqual(SettingsTab(rawValue: "remote"), .remote)
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsTab.remote.symbol, accessibilityDescription: nil), SettingsTab.remote.symbol)
        XCTAssertEqual(SettingsTab.allCases.last, .remote)
        XCTAssertEqual(SettingsTab.allCases.count, 7)
        XCTAssertEqual(Set(SettingsTab.allCases.map(\.symbol)).count, 7, "Every tab has a symbol of its own.")
        XCTAssertEqual(SettingsTab.remote.attentionNote, "Nook Remoto no está funcionando")
    }

    func testTheBarHasRemotoOnlyOnceUnlockedAndTheRestKeepTheirPlaces() {
        let locked = SettingsTab.shown(remoteUnlocked: false), unlocked = SettingsTab.shown(remoteUnlocked: true)
        XCTAssertEqual(locked, [.island, .pet, .sound, .permissions, .privacy, .screen])
        XCTAssertEqual(unlocked, locked + [.remote], "Remoto joins after the others, which stay where they were.")
        XCTAssertFalse(locked.contains(.remote))
    }

    private let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]

    /// Preferences of the test's own, taken out again when it is over: what a model saves (the remote's unlocking) never reaches the user's.
    private func makeDefaults() -> UserDefaults {
        let name = "nook-remote-settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    /// A model with its own defaults (and so its own remote): never the user's.
    private func makeModel(unlocked: Bool = false, tab: SettingsTab = .island) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: makeDefaults())
        if unlocked { model.remote.unlock() }
        model.settingsTab = tab
        return model
    }

    /// The card in a window as tall as the screen the card is told about leaves it, so no pane scrolls and every element has its place. `tall: false`: only as tall as the card is now
    /// (a window to draw is cheaper when it is not mostly empty, and the island's tab never grows).
    private func cardWindow(_ model: AppModel, screen: CGSize = CGSize(width: 1512, height: 3000), version: NookVersion = NookVersion(short: "0.2.1", build: "3"), tall: Bool = true) -> NSWindow {
        let permissions = ScreenVisionUIFixture.permissions(granted)
        permissions.refresh()
        let card = SettingsCard(model: model, screen: screen, topInset: 32, permissions: permissions, version: version)
        return Probe.window(tall ? AnyView(card.frame(width: SettingsCard.width, height: 1500, alignment: .top)) : AnyView(card), width: SettingsCard.width)
    }

    func testALockedCardHasSixTabsAndNoRemoto() throws {
        let model = makeModel()
        let window = cardWindow(model)
        defer { window.close() }
        for tab in SettingsTab.shown(remoteUnlocked: false) { XCTAssertNotNil(Probe.node(tab.title, in: window), "\(tab.title) is in the bar.") }
        XCTAssertNil(Probe.node("Remoto", in: window), "Nothing says Nook Remoto is there.")
        XCTAssertFalse(model.remote.unlocked)
    }

    func testUnlockingPutsRemotoInTheBarAndLockingTakesItOut() throws {
        let model = makeModel()
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertNil(Probe.node("Remoto", in: window))
        model.remote.unlock()
        Probe.settle()
        for tab in SettingsTab.allCases { XCTAssertNotNil(Probe.node(tab.title, in: window), "\(tab.title) is in the bar once unlocked.") }
        let last = try XCTUnwrap(Probe.frame("Remoto", in: window)), before = try XCTUnwrap(Probe.frame("Pantalla", in: window))
        XCTAssertGreaterThan(last.minX, before.maxX, "Remoto comes after the tab that used to be the last.")
        model.remote.lock()
        Probe.settle()
        XCTAssertNil(Probe.node("Remoto", in: window), "Locked again, it is gone.")
        XCTAssertNotNil(Probe.node("Pantalla", in: window))
    }

    func testACardLeftOnRemotoShowsTheIslandsTabAgainWhenItIsLocked() throws {
        let model = makeModel(unlocked: true, tab: .remote)
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertNotNil(Probe.node(Copy.switchLabel, in: window), "The Remoto pane is on show.")
        XCTAssertNil(Probe.node("Nook 0.2.1 (3)", in: window))
        model.remote.lock()
        Probe.settle()
        XCTAssertEqual(model.settingsTab, .island, "The model is back on the island's tab, not only the card.")
        XCTAssertNil(Probe.node(Copy.switchLabel, in: window))
        XCTAssertNotNil(Probe.node("Nook 0.2.1 (3)", in: window), "The island's tab is on show.")
    }

    func testATabLeftOnRemotoWhileLockedNeverShowsItsPane() {
        let model = makeModel(unlocked: false, tab: .remote)
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertNil(Probe.node(Copy.switchLabel, in: window), "A locked remote has no pane, whatever tab the model remembers.")
        XCTAssertNotNil(Probe.node("Nook 0.2.1 (3)", in: window), "The card shows the island's tab.")
    }

    // MARK: «Acerca de» in the card

    func testTheVersionIsAtTheBottomOfTheIslandTabAndLooksLikePlainText() throws {
        let model = makeModel()
        let window = cardWindow(model, tall: false)
        defer { window.close() }
        let line = try XCTUnwrap(Probe.frame("Nook 0.2.1 (3)", in: window))
        let label = try XCTUnwrap(says("ACERCA DE", in: window), "The section has its label.")
        XCTAssertLessThan(label.minY, line.minY, "The label is over the version.")
        XCTAssertGreaterThanOrEqual(line.minX, 16 - 1)
        // Nothing of a button: with nothing pressed or pointed at, the line's whole area, padding included, is the card's own colour.
        let host = try XCTUnwrap(window.contentView)
        Probe.settle(0.2)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor { try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)) }
        let card = try color(SettingsCard.width - 24, line.midY)
        for point in [CGPoint(x: line.maxX - 3, y: line.midY), CGPoint(x: line.maxX - 3, y: line.minY + 2), CGPoint(x: line.maxX - 3, y: line.maxY - 2)] {
            let there = try color(point.x, point.y)
            XCTAssertEqual(there.redComponent, card.redComponent, accuracy: 0.01, "No chrome around the version at \(point).")
            XCTAssertEqual(there.greenComponent, card.greenComponent, accuracy: 0.01)
            XCTAssertEqual(there.blueComponent, card.blueComponent, accuracy: 0.01)
        }
        // For VoiceOver it says what it is for, since there is nothing to see.
        XCTAssertEqual(Probe.help("Nook 0.2.1 (3)", in: window), SettingsAboutCopy.hint)
    }

    /// The line has no look of a button, but it feels the press: with the mouse down it sinks a little (or, with Reduce Motion, dims), and it is back as it was once it is let go.
    func testTheVersionLineFeelsThePressAndComesBack() throws {
        let model = makeModel()
        model.display.theme = .dark
        let window = cardWindow(model, tall: false)
        defer { window.close() }
        let frame = try XCTUnwrap(Probe.frame("Nook 0.2.1 (3)", in: window))
        let host = try XCTUnwrap(window.contentView)
        /// The box the line's light pixels take in the window as it is drawn now, in pixels, and how bright they are on average.
        func look() throws -> (box: CGRect, brightness: Double) {
            Probe.settle(0.4)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, sum = 0.0, count = 0.0
            for y in Int(frame.minY * scale)..<Int(frame.maxY * scale) {
                for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
                    let brightness = Double(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.redComponent ?? 0)
                    if brightness > 0.30 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); sum += brightness; count += 1 }
                }
            }
            XCTAssertGreaterThan(count, 0, "The line is drawn.")
            return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), count > 0 ? sum / count : 0)
        }
        let rest = try look()
        // A mouse press, the way the window gets it: down on the line (its place from the window's bottom left), held.
        let point = NSPoint(x: frame.midX, y: host.bounds.height - frame.midY)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        window.sendEvent(try event(.leftMouseDown))
        let pressed = try look()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertLessThan(pressed.brightness, rest.brightness - 0.01, "With Reduce Motion a pressed line is dimmed instead of sunk.")
        } else {
            XCTAssertLessThan(pressed.box.width, rest.box.width - 4, "The line sinks while it is held: \(rest.box.width) → \(pressed.box.width) px")
            XCTAssertLessThan(pressed.box.height, rest.box.height)
        }
        window.sendEvent(try event(.leftMouseUp))
        let after = try look()
        XCTAssertEqual(after.box.width, rest.box.width, accuracy: 1, "Let go, it comes back.")
        XCTAssertEqual(after.box.height, rest.box.height, accuracy: 1)
    }

    func testFiveTapsOnTheVersionUnlockRemotoAndTheCardGoesToItsTab() throws {
        let defaults = makeDefaults()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        let window = cardWindow(model)
        defer { window.close() }
        let label = "Nook 0.2.1 (3)"
        XCTAssertTrue(Probe.press(label, in: window)); XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertFalse(model.remote.unlocked)
        XCTAssertNil(says(SettingsAboutCopy.remaining(2), in: window), "Two taps say nothing.")
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertNotNil(says(SettingsAboutCopy.remaining(2), in: window), "The third says how many are left.")
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertNotNil(says(SettingsAboutCopy.remaining(1), in: window))
        XCTAssertNil(says(SettingsAboutCopy.remaining(2), in: window), "The count is the new one.")
        XCTAssertFalse(model.remote.unlocked)
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertTrue(model.remote.unlocked, "The fifth unlocks it.")
        XCTAssertTrue(defaults.bool(forKey: RemoteAccess.unlockedKey), "For good: it is saved.")
        XCTAssertNotNil(says(SettingsAboutCopy.unlocked, in: window), "And says so.")
        XCTAssertNotNil(Probe.node("Remoto", in: window), "Its tab is in the bar.")
        XCTAssertEqual(model.settingsTab, .island, "The card waits a beat, so the words can be read.")
        Probe.settle(SettingsCard.revealDelay + 0.5)
        XCTAssertEqual(model.settingsTab, .remote, "Then it goes to the new tab.")
        XCTAssertNotNil(Probe.node(Copy.switchLabel, in: window), "Which shows its pane.")
    }

    /// The section on its own with a clock the test moves: a pause longer than the window between two taps starts the count over (and the hint goes with it), and the fifth tap of the
    /// new run unlocks, once, telling the card.
    func testAPauseBetweenTapsOnTheViewStartsTheCountOverWithoutWaiting() throws {
        let model = makeModel()
        var now = 100.0, unlocked = 0
        let section = SettingsAboutSection(version: NookVersion(short: "0.2.1", build: "3"), remote: model.remote, onUnlocked: { unlocked += 1 }, clock: { now })
        let window = Probe.window(section.padding(16).frame(width: SettingsCard.width).background(Color(white: 0.105)).environment(\.colorScheme, .dark), width: SettingsCard.width)
        defer { window.close() }
        let label = "Nook 0.2.1 (3)"
        for step in 0..<3 { now = 100 + 0.3 * Double(step); XCTAssertTrue(Probe.press(label, in: window)) }
        XCTAssertNotNil(says(SettingsAboutCopy.remaining(2), in: window), "Three taps in a row: two are left.")
        now += UnlockTapCounter.window + 1
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertNil(says(SettingsAboutCopy.remaining(2), in: window), "After the pause it is the first tap of a new run, which says nothing; the old hint is gone.")
        XCTAssertFalse(model.remote.unlocked)
        // The tap after the pause was the new run's first: its second says nothing, its third says two are left.
        for step in 1...3 {
            now += 0.3
            XCTAssertTrue(Probe.press(label, in: window))
            if step == 1 { XCTAssertNil(says(SettingsAboutCopy.remaining(2), in: window)) }
            if step == 2 { XCTAssertNotNil(says(SettingsAboutCopy.remaining(2), in: window)) }
        }
        XCTAssertFalse(model.remote.unlocked, "Four taps of the new run are not five.")
        XCTAssertEqual(unlocked, 0)
        now += 0.3
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertTrue(model.remote.unlocked, "The fifth of the new run unlocks.")
        XCTAssertEqual(unlocked, 1, "And tells the card once.")
        now += 0.3
        XCTAssertTrue(Probe.press(label, in: window))
        XCTAssertEqual(unlocked, 1, "Once unlocked a tap does not unlock again.")
    }

    func testTheCardStaysWhereTheUserWentWhileItWaitedToShowRemoto() throws {
        let model = makeModel()
        let window = cardWindow(model)
        defer { window.close() }
        for _ in 0..<5 { XCTAssertTrue(Probe.press("Nook 0.2.1 (3)", in: window)) }
        XCTAssertTrue(model.remote.unlocked)
        model.settingsTab = .pet
        Probe.settle(SettingsCard.revealDelay + 0.5)
        XCTAssertEqual(model.settingsTab, .pet, "Someone who has moved on is not taken back.")
    }

    func testAnUnlockedRemotoJustSaysItIsActiveWhenTheVersionIsTapped() throws {
        let model = makeModel(unlocked: true)
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertEqual(Probe.help("Nook 0.2.1 (3)", in: window), SettingsAboutCopy.hintUnlocked, "VoiceOver is told too.")
        XCTAssertTrue(Probe.press("Nook 0.2.1 (3)", in: window))
        XCTAssertNotNil(says(SettingsAboutCopy.alreadyUnlocked, in: window))
        Probe.settle(SettingsCard.revealDelay + 0.3)
        XCTAssertEqual(model.settingsTab, .island, "It says so and stays where it is.")
    }

    func testTheNotesGoAwayOnTheirOwn() throws {
        let model = makeModel(unlocked: true)
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertTrue(Probe.press("Nook 0.2.1 (3)", in: window))
        XCTAssertNotNil(says(SettingsAboutCopy.alreadyUnlocked, in: window))
        Probe.settle(2.5 + 0.7)
        XCTAssertNil(says(SettingsAboutCopy.alreadyUnlocked, in: window), "A note is for a moment.")
    }

    // MARK: What the pane says

    func testTheHeaderSaysEachStateInWordsATonesAndASymbol() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.1.20:8765"))
        let off = Copy.header(.off), starting = Copy.header(.starting), on = Copy.header(.on(url: url, port: 8765)), failed = Copy.header(.failed("No hay red."))
        XCTAssertEqual(off.chip, "Apagado"); XCTAssertEqual(off.tone, .neutral); XCTAssertFalse(off.switchOn); XCTAssertFalse(off.working)
        XCTAssertEqual(starting.chip, "Activando"); XCTAssertTrue(starting.switchOn, "The user has asked for it: the switch is on."); XCTAssertTrue(starting.working)
        XCTAssertEqual(on.chip, "Activo"); XCTAssertEqual(on.tone, .good); XCTAssertTrue(on.switchOn)
        XCTAssertEqual(failed.chip, "No se pudo"); XCTAssertEqual(failed.tone, .bad); XCTAssertFalse(failed.switchOn, "It is off, and the switch can turn it on again.")
        XCTAssertEqual(failed.failure, "No hay red.", "The server's own words, untouched.")
        for header in [off, starting, on] { XCTAssertNil(header.failure) }
        for header in [off, starting, on, failed] {
            for symbol in [header.symbol, header.chipSymbol] { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol) }
            XCTAssertFalse(header.detail.isEmpty)
        }
        XCTAssertEqual(Set([off, starting, on, failed].map(\.chip)).count, 4, "Four states, four words: never colour alone.")
    }

    func testEverySymbolOfThePaneExists() {
        let names = Copy.facts.map(\.symbol) + ["iphone.radiowaves.left.and.right", "iphone.slash", "exclamationmark.triangle.fill", "doc.on.doc", "checkmark", "eye.slash", "lock.shield", "arrow.clockwise",
                                                "iphone", "ipad", "laptopcomputer", "desktopcomputer", "globe", "qrcode.viewfinder"]
        for name in names { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
        for label in ["iPhone · Safari", "iPad · Safari", "Mac · Chrome", "Android · Chrome", "Windows · Edge", "Linux · Firefox", "Navegador"] {
            XCTAssertNotNil(NSImage(systemSymbolName: Copy.deviceSymbol(label), accessibilityDescription: nil), label)
        }
        XCTAssertEqual(Copy.deviceSymbol("iPhone · Safari"), "iphone")
        XCTAssertEqual(Copy.deviceSymbol("iPad"), "ipad")
        XCTAssertEqual(Copy.deviceSymbol("Navegador"), "globe")
    }

    func testTheTabSaysWhatToDoAndWhatToKnow() {
        XCTAssertEqual(Copy.oneDevicePerCode, "Cada código empareja un dispositivo; después aparece otro.")
        let facts = Copy.facts.map { "\($0.lead) \($0.text)" }.joined(separator: "\n")
        for word in ["Escanea el código", "app Cámara del iPhone", "Escáner de códigos", "mismo Wi-Fi de casa", "copia el enlace", "Portapapeles universal", "no se abre en este Mac, a propósito", "Se apaga al cerrar Nook", "código nuevo", "escanear otra vez"] {
            XCTAssertTrue(facts.contains(word), "The tab says «\(word)».\n\(facts)")
        }
        XCTAssertTrue(Copy.shareNote.contains("no lo compartas"))
        XCTAssertTrue(Copy.hideNote.contains("lo apaga") || Copy.hideNote.contains("Lo apaga"))
        XCTAssertTrue(Copy.hideNote.contains("cinco veces"), "It says how to get the tab back.")
        XCTAssertEqual(Copy.hide, "Ocultar Nook Remoto")
        XCTAssertEqual(Copy.fullTitle(8), "Ya hay 8 dispositivos emparejados")
        XCTAssertEqual(Copy.removeLabel(RemoteDevice(id: "a", label: "iPhone · Safari", pairedAt: Date(), lastSeen: Date())), "Quitar iPhone · Safari")
    }

    func testLastSeenIsCountedInWords() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func seen(_ seconds: TimeInterval) -> String { Copy.lastSeen(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(seen(0), "ahora"); XCTAssertEqual(seen(29), "ahora")
        XCTAssertEqual(seen(-5), "ahora", "A clock a little ahead of the device's is not the future.")
        XCTAssertEqual(seen(30), "hace 1 min"); XCTAssertEqual(seen(119), "hace 1 min"); XCTAssertEqual(seen(120), "hace 2 min"); XCTAssertEqual(seen(3599), "hace 59 min")
        XCTAssertEqual(seen(3600), "hace 1 h"); XCTAssertEqual(seen(86_399), "hace 23 h")
        XCTAssertEqual(seen(86_400), "hace 1 d"); XCTAssertEqual(seen(3 * 86_400 + 5), "hace 3 d")
    }

    // MARK: The QR

    private func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    private let key = "Qz3x9Vb_2LkfG-ZyR8mT1uWcN6sHa4PdE0jXoIiYtAw"
    private var links: [String] {
        ["http://192.168.1.20:8765/pair?k=\(key)", "http://192.168.100.100:8775/pair?k=\(key)", "http://10.0.0.5:51234/pair?k=\(key)",
         "http://[fe80::1c2b:3a4d:5e6f:7081]:8765/pair?k=\(key)", "http://[fd12:3456:789a:1:1c2b:3a4d:5e6f:7081]:8765/pair?k=\(key)"]
    }

    /// What a camera does with the picture: the system's own detector reads the link back, at every size the card can draw it (1× and 2× screens, any link).
    func testTheCodeReadsBackAsTheLinkAtEverySize() throws {
        for link in links {
            for pixels in [1, 2, 4, 5, 9, 10] {
                let image = try XCTUnwrap(QRCode.image(for: link, pixelsPerModule: pixels), "\(link) at \(pixels) px")
                XCTAssertEqual(decode(image), [link], "\(link) at \(pixels) px to a module")
            }
        }
    }

    func testTheCodeIsMadeOfWholePixelsBlackOnWhiteWithAQuietZoneOfFour() throws {
        let link = links[0]
        let modules = try XCTUnwrap(QRCode.modules(for: link))
        let across = QRCode.modulesAcross(modules)
        XCTAssertEqual(across, modules.count + 8, "Four modules of quiet zone on each side.")
        XCTAssertEqual(QRCode.quietZone, 4)
        XCTAssertTrue([37, 41].contains(modules.count), "A link this long is a version 5 or 6 code: \(modules.count) modules.")
        let pixels = 6
        let image = try XCTUnwrap(QRCode.image(modules: modules, pixelsPerModule: pixels))
        XCTAssertEqual(image.width, across * pixels); XCTAssertEqual(image.height, across * pixels)
        // Read the picture back: only black and white (nothing smoothed), and every module is a flat block of its own colour.
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn)
        XCTAssertTrue(data.allSatisfy { $0 == 0 || $0 == 255 }, "Hard edges: no grey anywhere.")
        for row in 0..<across {
            for column in 0..<across {
                let first = data[row * pixels * image.width + column * pixels]
                for dy in 0..<pixels { for dx in 0..<pixels { XCTAssertEqual(data[(row * pixels + dy) * image.width + column * pixels + dx], first, "Module \(column),\(row) is one flat block") } }
                let dark = first == 0
                let inSymbol = (4..<(across - 4)).contains(row) && (4..<(across - 4)).contains(column)
                XCTAssertEqual(dark, inSymbol ? modules[row - 4][column - 4] : false, "Module \(column),\(row): the quiet zone is white and the symbol is the modules'.")
            }
        }
    }

    /// The finders are at the top left, the top right and the bottom left, and not at the bottom right: the code is the right way up and not mirrored.
    func testTheCodeIsTheRightWayUp() throws {
        let modules = try XCTUnwrap(QRCode.modules(for: links[0]))
        let n = modules.count
        func finder(_ top: Int, _ left: Int) -> Bool {
            for dy in 0..<7 {
                for dx in 0..<7 {
                    let edge = dy == 0 || dy == 6 || dx == 0 || dx == 6, centre = (2...4).contains(dy) && (2...4).contains(dx)
                    if modules[top + dy][left + dx] != (edge || centre) { return false }
                }
            }
            return true
        }
        XCTAssertTrue(finder(0, 0), "Top left"); XCTAssertTrue(finder(0, n - 7), "Top right"); XCTAssertTrue(finder(n - 7, 0), "Bottom left")
        XCTAssertFalse(finder(n - 7, n - 7), "Not the bottom right.")
    }

    func testTheCodeFitsItsPaperInWholePixelsOnEveryScreen() throws {
        let paper = RemotePaneContent.paper
        XCTAssertEqual(QRCode.pixelsPerModule(fitting: paper, scale: 2, modulesAcross: 45), 10, "A Retina screen: 464 px, ten to a module.")
        XCTAssertEqual(QRCode.pixelsPerModule(fitting: paper, scale: 1, modulesAcross: 45), 5)
        XCTAssertEqual(QRCode.pixelsPerModule(fitting: paper, scale: 2, modulesAcross: 49), 9)
        XCTAssertEqual(QRCode.pixelsPerModule(fitting: 10, scale: 1, modulesAcross: 45), 1, "Never less than a pixel.")
        XCTAssertEqual(QRCode.pixelsPerModule(fitting: paper, scale: 0, modulesAcross: 45), 1)
        for scale in [1, 2, 3] as [CGFloat] {
            for link in links {
                let picture = try XCTUnwrap(QRCode.picture(for: link, fitting: paper, scale: scale))
                XCTAssertLessThanOrEqual(picture.points, paper, "\(link) at \(scale)×")
                XCTAssertGreaterThan(picture.points, paper * 0.8, "As large as whole pixels allow: \(picture.points) pt of \(paper)")
                XCTAssertEqual(picture.inset * scale, (picture.inset * scale).rounded(), accuracy: 0.001, "The picture starts on a pixel of the screen.")
                XCTAssertEqual(picture.points * scale, CGFloat(picture.image.width), accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(picture.inset, 0)
                XCTAssertLessThanOrEqual(2 * picture.inset + picture.points, paper + 0.001)
            }
        }
        // Big enough to scan from a phone at arm's length: 4.5 cm on a MacBook's screen, which has about 50 pt to the centimetre.
        XCTAssertGreaterThanOrEqual(paper, 220)
    }

    func testTheCodeHasNothingToDrawWithNothing() {
        XCTAssertNil(QRCode.modules(for: ""))
        XCTAssertNil(QRCode.image(for: "", pixelsPerModule: 4))
        XCTAssertNil(QRCode.image(modules: [], pixelsPerModule: 4))
        XCTAssertNil(QRCode.image(for: "x", pixelsPerModule: 0))
        XCTAssertNil(QRCode.modules(for: String(repeating: "x", count: 4000)), "Too long for any code.")
    }

    // MARK: The pane, state by state (no server)

    /// A device last seen 10 s before the `now` the pane windows count from (90 s after the reference date).
    private let device = RemoteDevice(id: "d1", label: "iPhone · Safari", pairedAt: Date(timeIntervalSinceReferenceDate: 0), lastSeen: Date(timeIntervalSinceReferenceDate: 80))

    private func state(_ status: RemoteAccess.Status = .off, link: String? = nil, devices: [RemoteDevice] = [], watching: Bool = false) -> RemotePaneState {
        RemotePaneState(status: status, pairingURL: link.flatMap(URL.init(string:)), devices: devices, watching: watching)
    }

    private func paneWindow(_ state: RemotePaneState, maxHeight: CGFloat = 3000, setOn: @escaping (Bool) -> Void = { _ in }, copyLink: @escaping (URL) -> Void = { _ in },
                            remove: @escaping (RemoteDevice) -> Void = { _ in }, hide: @escaping () -> Void = {}) -> NSWindow {
        let pane = RemotePaneContent(state: state, maxHeight: maxHeight, setOn: setOn, copyLink: copyLink, remove: remove, hide: hide, now: Date(timeIntervalSinceReferenceDate: 90))
        return Probe.window(pane.frame(width: SettingsCard.width, height: 1500, alignment: .top).background(Color(white: 0.105)).environment(\.colorScheme, .dark), width: SettingsCard.width)
    }

    func testOffThereIsOnlyTheSwitchTheGuidanceAndTheWayToHideTheTab() throws {
        let window = paneWindow(state())
        defer { window.close() }
        XCTAssertNotNil(Probe.node(Copy.switchLabel, in: window))
        XCTAssertNotNil(Probe.node(Copy.hide, in: window))
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window), "No code while it is off.")
        XCTAssertNil(Probe.node(Copy.portTitle, in: window))
        XCTAssertNil(Probe.node(Copy.copyLink, in: window))
        XCTAssertNil(Probe.node(Copy.retry, in: window))
    }

    func testStartingShowsNoCodeYet() {
        let window = paneWindow(state(.starting))
        defer { window.close() }
        XCTAssertNotNil(Probe.node(Copy.switchLabel, in: window))
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window))
    }

    func testFailedShowsTheServersWordsAndAWayToTryAgain() throws {
        let message = "Los puertos 8765 a 8775 de este Mac están ocupados por otras apps. Ciérralas y vuelve a intentarlo."
        var asked: [Bool] = []
        let window = paneWindow(state(.failed(message)), setOn: { asked.append($0) })
        defer { window.close() }
        XCTAssertNotNil(says(message, in: window), "The message is there, whole.")
        XCTAssertTrue(Probe.press(Copy.retry, in: window))
        XCTAssertEqual(asked, [true], "«Reintentar» asks to turn it on.")
        XCTAssertTrue(Probe.press(Copy.switchLabel, in: window), "So does the switch, which shows it off.")
        XCTAssertEqual(asked, [true, true])
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window))
        // The network changing under it is a failure too, with its own words.
        let network = "Nook Remoto dejó de funcionar: la red cambió. Vuelve a activarlo."
        let other = paneWindow(state(.failed(network)))
        defer { other.close() }
        XCTAssertNotNil(says(network, in: other))
    }

    func testOnItShowsTheCodeTheAddressAndAboveAllThePort() throws {
        let link = "http://192.168.1.20:8765/pair?k=\(key)"
        var copied: [URL] = []
        let window = paneWindow(state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: link), copyLink: { copied.append($0) })
        defer { window.close() }
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window))
        XCTAssertEqual(valueOf(Copy.qrLabel, in: window), "Dirección 192.168.1.20, puerto 8765")
        XCTAssertEqual(valueOf(Copy.addressTitle, in: window), "192.168.1.20")
        XCTAssertEqual(valueOf(Copy.portTitle, in: window), "8765")
        let address = try XCTUnwrap(Probe.frame(Copy.addressTitle, in: window)), port = try XCTUnwrap(Probe.frame(Copy.portTitle, in: window)), qr = try XCTUnwrap(Probe.frame(Copy.qrLabel, in: window))
        XCTAssertGreaterThan(address.minY, qr.maxY - 1, "Under the code.")
        XCTAssertEqual(qr.width, RemotePaneContent.paper, accuracy: 1)
        XCTAssertEqual(port.midY, address.midY, accuracy: 1, "The two sit side by side.")
        XCTAssertGreaterThan(port.width, 40); XCTAssertGreaterThan(address.minX, 16 - 1); XCTAssertLessThan(port.minX - address.maxX, 12, "Together, not at the card's two ends.")
        XCTAssertTrue(Probe.press(Copy.copyLink, in: window))
        XCTAssertEqual(copied.map(\.absoluteString), [link], "The button copies the pairing link.")
        XCTAssertNotNil(Probe.node(Copy.copiedLink, in: window), "And says it did.")
        XCTAssertNil(Probe.node(Copy.copyLink, in: window))
    }

    func testAnIPv6AddressStillFitsAndTheCodeStillShows() throws {
        let link = "http://[fe80::1c2b:3a4d:5e6f:7081]:8765/pair?k=\(key)"
        let window = paneWindow(state(.on(url: URL(string: "http://[fe80::1c2b:3a4d:5e6f:7081]:8765")!, port: 8765), link: link))
        defer { window.close() }
        let address = try XCTUnwrap(Probe.frame(Copy.addressTitle, in: window)), port = try XCTUnwrap(Probe.frame(Copy.portTitle, in: window))
        XCTAssertLessThanOrEqual(max(address.maxX, port.maxX), SettingsCard.width - 16 + 0.5, "Nothing runs off the card.")
        XCTAssertFalse(address.intersects(port), "The long address and the port do not lie over each other.")
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window))
    }

    func testTheDevicesAreListedWithWhenTheyWereSeenAndAWayToRemoveThem() throws {
        let older = RemoteDevice(id: "d2", label: "iPad · Safari", pairedAt: Date(timeIntervalSinceReferenceDate: 0), lastSeen: Date(timeIntervalSinceReferenceDate: -3600))
        var removed: [String] = []
        let window = paneWindow(state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=\(key)", devices: [device, older]), remove: { removed.append($0.id) })
        defer { window.close() }
        XCTAssertNotNil(Probe.node("Quitar iPhone · Safari", in: window)); XCTAssertNotNil(Probe.node("Quitar iPad · Safari", in: window))
        XCTAssertNotNil(says("Visto ahora", in: window), "The iPhone was seen 10 s ago.")
        XCTAssertNotNil(says("Visto hace 1 h", in: window), "The iPad an hour ago.")
        XCTAssertTrue(Probe.press("Quitar iPad · Safari", in: window))
        XCTAssertEqual(removed, ["d2"], "«Quitar» removes that device.")
        XCTAssertNil(says(Copy.noDevices, in: window))
    }

    func testWithNoDevicesTheListSaysWhenOneWillAppear() {
        let window = paneWindow(state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=\(key)"))
        defer { window.close() }
        XCTAssertNotNil(says(Copy.noDevices, in: window))
        XCTAssertNil(says(Copy.pageOpen, in: window), "No phone has the page open.")
    }

    func testAPhoneWithThePageOpenIsShown() {
        let on = RemoteAccess.Status.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765)
        let watching = paneWindow(state(on, link: "http://192.168.1.20:8765/pair?k=\(key)", devices: [device], watching: true))
        defer { watching.close() }
        XCTAssertNotNil(says(Copy.pageOpen, in: watching), "A phone has the page open: the tab says so.")
        let idle = paneWindow(state(on, link: "http://192.168.1.20:8765/pair?k=\(key)", devices: [device], watching: false))
        defer { idle.close() }
        XCTAssertNil(says(Copy.pageOpen, in: idle))
    }

    func testAFullListGivesTheCodesPlaceToTheReason() throws {
        let devices = (0..<RemoteRegistry.maxDevices).map { RemoteDevice(id: "d\($0)", label: "iPhone · Safari", pairedAt: Date(timeIntervalSinceReferenceDate: 0), lastSeen: Date(timeIntervalSinceReferenceDate: 0)) }
        let on = RemoteAccess.Status.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765)
        let full = paneWindow(state(on, link: "http://192.168.1.20:8765/pair?k=\(key)", devices: devices))
        defer { full.close() }
        XCTAssertNil(Probe.node(Copy.qrLabel, in: full), "A code that pairs nobody is not drawn.")
        XCTAssertNil(Probe.node(Copy.copyLink, in: full), "Nor offered as a link.")
        XCTAssertNotNil(Probe.node(Copy.fullTitle(8), in: full), "It says why.")
        XCTAssertEqual(valueOf(Copy.fullTitle(8), in: full), Copy.fullDetail, "And what to do.")
        XCTAssertNotNil(Probe.node("Quitar iPhone · Safari", in: full), "Every device can be removed.")
        XCTAssertNotNil(Probe.node(Copy.portTitle, in: full), "Where this Mac is stays.")
        let room = paneWindow(state(on, link: "http://192.168.1.20:8765/pair?k=\(key)", devices: Array(devices.dropLast())))
        defer { room.close() }
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: room), "With room for one more, the code is back.")
    }

    func testOnWithoutALinkYetSaysTheCodeIsBeingPrepared() {
        let window = paneWindow(state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: nil))
        defer { window.close() }
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window))
        XCTAssertNotNil(Probe.node(Copy.portTitle, in: window), "The address and port are there.")
        XCTAssertNotNil(says(Copy.preparing, in: window))
    }

    func testTheHideButtonAsksToHide() {
        var hidden = 0
        let window = paneWindow(state(), hide: { hidden += 1 })
        defer { window.close() }
        XCTAssertTrue(Probe.press(Copy.hide, in: window))
        XCTAssertEqual(hidden, 1)
    }

    func testTheSwitchAsksToTurnItOnAndOff() {
        var asked: [Bool] = []
        let off = paneWindow(state(), setOn: { asked.append($0) })
        defer { off.close() }
        XCTAssertTrue(Probe.press(Copy.switchLabel, in: off), "A switch takes a press as VoiceOver gives it.")
        XCTAssertEqual(asked, [true])
        let on = paneWindow(state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=\(key)"), setOn: { asked.append($0) })
        defer { on.close() }
        XCTAssertTrue(Probe.press(Copy.switchLabel, in: on))
        XCTAssertEqual(asked, [true, false])
    }

    /// The card's window follows the tab's height: the tab says when something that changes it changed (the code appears, devices come and go).
    func testTheTabTellsTheCardWhenItsHeightChanges() throws {
        final class Box: ObservableObject { @Published var state = RemotePaneState() }
        struct Harness: View {
            @ObservedObject var box: Box
            var changed: () -> Void
            var body: some View { RemotePaneContent(state: box.state, maxHeight: 3000, onContentChange: changed).frame(width: SettingsCard.width, height: 1500, alignment: .top) }
        }
        let box = Box()
        var changes = 0
        let window = Probe.window(Harness(box: box) { changes += 1 }, width: SettingsCard.width)
        defer { window.close() }
        XCTAssertEqual(changes, 0, "Nothing changed yet.")
        box.state = state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=\(key)")
        Probe.settle()
        XCTAssertEqual(changes, 1, "The code came in.")
        box.state = state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=\(key)", devices: [device])
        Probe.settle()
        XCTAssertEqual(changes, 2, "A device came in.")
        // A new code for the same state is the same height: nothing to tell.
        box.state = state(.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765), link: "http://192.168.1.20:8765/pair?k=Zz\(key.dropFirst(2))", devices: [device])
        Probe.settle()
        XCTAssertEqual(changes, 2)
    }

    // MARK: The pane on a real remote

    /// A Mac with no home network, only its own loopback: the way the remote fails to start when the Mac is off Wi-Fi (`RemoteAccessTests.testWithoutAHomeNetworkItSaysSo`).
    static func noHomeNetwork() -> RemoteAddressPolicy {
        RemoteAddressPolicy(allowsLoopback: true, interfaces: { [RemoteInterface(name: "lo0", address: RemoteIP("127.0.0.1")!, up: true, loopback: true)] })
    }

    /// The tab on a card of a model whose remote listens on this Mac's loopback, as the remote's own tests have it. Skips where the test cannot listen.
    private func listening(_ model: AppModel) throws -> RemoteAccess {
        let remote = try RemoteFixture.started(model)
        remotes.append(remote)
        return remote
    }

    func testTheSwitchOfTheCardTurnsTheRemoteOnAndOffAndTheCodeAppears() throws {
        let model = makeModel(unlocked: true, tab: .remote)
        // Set up to listen on this Mac's loopback as the remote's own tests have it, and then off: what is left is the card's switch.
        let remote = try listening(model)
        remote.stop()
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertEqual(remote.status, .off)
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window))
        XCTAssertTrue(Probe.press(Copy.switchLabel, in: window))
        RemoteFixture.waitUntil { remote.status.isOn || { if case .failed = remote.status { true } else { false } }() }
        guard case .on(let url, let port) = remote.status else { throw XCTSkip("Nook Remote could not listen: \(remote.status)") }
        Probe.settle(0.6)
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window), "The code is there.")
        XCTAssertEqual(valueOf(Copy.qrLabel, in: window), "Dirección \(url.host ?? ""), puerto \(port)")
        XCTAssertEqual(valueOf(Copy.portTitle, in: window), "\(port)", "The port is said, as the user asked.")
        XCTAssertTrue(Probe.press(Copy.switchLabel, in: window))
        Probe.settle(0.6)
        XCTAssertEqual(remote.status, .off, "The same switch turns it off.")
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window), "The code goes with it.")
    }

    func testTheCodeFollowsTheNextKeyAfterAPhonePairsAndRemovingAPhoneIsOneButton() throws {
        let model = makeModel(unlocked: true, tab: .remote)
        let remote = try listening(model)
        let window = cardWindow(model)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        func codes() throws -> [String] {
            Probe.settle(0.6)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return decode(try XCTUnwrap(rep.cgImage))
        }
        let first = try XCTUnwrap(remote.pairingURL)
        XCTAssertEqual(try codes(), [first.absoluteString], "What is on the screen is the pairing link: a phone's camera reads exactly it.")
        XCTAssertNotNil(RemoteFixture.pair(remote), "A phone pairs with it.")
        RemoteFixture.waitUntil { remote.pairingURL != first && remote.devices.count == 1 }
        let next = try XCTUnwrap(remote.pairingURL)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(try codes(), [next.absoluteString], "The code on screen is the new one, without anyone doing anything.")
        XCTAssertNotNil(Probe.node("Quitar iPhone · Safari", in: window), "The phone is in the list.")
        XCTAssertTrue(Probe.press("Quitar iPhone · Safari", in: window))
        RemoteFixture.waitUntil { remote.devices.isEmpty }
        XCTAssertTrue(remote.devices.isEmpty, "«Quitar» removed it from the remote.")
        Probe.settle(0.5)
        XCTAssertNil(Probe.node("Quitar iPhone · Safari", in: window), "And from the list.")
    }

    func testWithEightDevicesTheCodeIsReplacedByTheReasonUntilOneIsRemoved() throws {
        let model = makeModel(unlocked: true, tab: .remote)
        let remote = try listening(model)
        let window = cardWindow(model)
        defer { window.close() }
        let cookies = (0..<RemoteRegistry.maxDevices).compactMap { _ in RemoteFixture.pair(remote) }
        XCTAssertEqual(cookies.count, RemoteRegistry.maxDevices)
        RemoteFixture.waitUntil { remote.devices.count == RemoteRegistry.maxDevices }
        Probe.settle(0.6)
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window), "The ninth would be refused: the code is not offered.")
        XCTAssertNotNil(Probe.node(Copy.fullTitle(RemoteRegistry.maxDevices), in: window))
        XCTAssertTrue(Probe.press("Quitar iPhone · Safari", in: window))
        RemoteFixture.waitUntil { remote.devices.count == RemoteRegistry.maxDevices - 1 }
        Probe.settle(0.6)
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window), "With room for another, the code is back.")
    }

    func testAFailureIsShownAndTheSwitchTurnsItOnAgain() throws {
        let model = makeModel(unlocked: true, tab: .remote)
        let remote = try listening(model)
        let home = remote.policy
        remote.stop()
        // No home network: the way the remote fails when the Mac is off Wi-Fi.
        remote.policy = Self.noHomeNetwork()
        remote.start()
        guard case .failed(let message) = remote.status else { return XCTFail("\(remote.status)") }
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertNotNil(says(message, in: window), "The server's own sentence is on the tab.")
        XCTAssertNil(Probe.node(Copy.qrLabel, in: window))
        // The Mac is back on the network: the button asks again, and it works.
        remote.policy = home
        XCTAssertTrue(Probe.press(Copy.retry, in: window))
        RemoteFixture.waitUntil { remote.status.isOn || { if case .failed = remote.status { true } else { false } }() }
        guard remote.status.isOn else { throw XCTSkip("Nook Remote could not listen: \(remote.status)") }
        Probe.settle(0.6)
        XCTAssertNil(says(message, in: window), "The failure is gone.")
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window))
    }

    func testAFailureWhileOnAnotherTabPutsTheDotOnRemoto() throws {
        let model = makeModel(unlocked: true, tab: .island)
        let remote = model.remote
        remote.policy = Self.noHomeNetwork()
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertEqual(Probe.value("Remoto", in: window) ?? "", "", "Nothing wrong yet.")
        remote.start()
        Probe.settle(0.6)
        guard case .failed = remote.status else { return XCTFail("\(remote.status)") }
        XCTAssertEqual(Probe.value("Remoto", in: window), SettingsTab.remote.attentionNote, "The tab asks for a look, as a missing permission does.")
        remote.stop()
        Probe.settle(0.6)
        XCTAssertEqual(Probe.value("Remoto", in: window) ?? "", "", "Turned off by hand, the dot goes.")
    }

    func testHidingTheTabTurnsTheRemoteOffLocksItForGoodAndLeavesTheCardOnTheIsland() throws {
        let defaults = makeDefaults()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.remote.unlock()
        model.settingsTab = .remote
        let remote = try listening(model)
        let window = cardWindow(model)
        defer { window.close() }
        XCTAssertNotNil(Probe.node(Copy.qrLabel, in: window))
        XCTAssertTrue(Probe.press(Copy.hide, in: window))
        Probe.settle(0.6)
        XCTAssertEqual(remote.status, .off, "Hiding it turns it off.")
        XCTAssertNil(remote.pairingURL)
        XCTAssertFalse(remote.unlocked)
        XCTAssertFalse(defaults.bool(forKey: RemoteAccess.unlockedKey), "For good: it is saved.")
        XCTAssertEqual(model.settingsTab, .island)
        XCTAssertNil(Probe.node("Remoto", in: window), "The tab is out of the bar.")
        XCTAssertNil(Probe.node(Copy.switchLabel, in: window))
        XCTAssertNotNil(Probe.node("Nook 0.2.1 (3)", in: window), "The card is on the island's tab, and the five taps are there to bring it back.")
        // And they do: five taps unlock it again.
        for _ in 0..<5 { XCTAssertTrue(Probe.press("Nook 0.2.1 (3)", in: window)) }
        XCTAssertTrue(remote.unlocked)
        XCTAssertTrue(defaults.bool(forKey: RemoteAccess.unlockedKey))
        XCTAssertNotNil(Probe.node("Remoto", in: window))
    }

    // MARK: The window follows the tab

    private func makeWindow(_ screen: CGSize, model: AppModel) -> SettingsWindow {
        let permissions = ScreenVisionUIFixture.permissions(granted)
        return SettingsWindow(model: model, screen: screen, topInset: 32, level: .normal, permissions: permissions) {}
    }

    private func place(_ window: SettingsWindow, screen: CGRect) -> CGRect {
        let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: island, on: screen)
        window.panel.orderFrontRegardless()
        return island
    }

    func testTheCardGrowsWhenTheCodeAppearsAndNeverRunsOffAShortScreen() throws {
        for (screen, short) in [(CGRect(x: -40000, y: -40000, width: 1512, height: 982), false), (CGRect(x: -40000, y: -40000, width: 1280, height: 720), true)] {
            let model = makeModel(unlocked: true, tab: .remote)
            let window = makeWindow(screen.size, model: model)
            let island = place(window, screen: screen)
            defer { window.hide() }
            Probe.settle()
            let off = window.cardSize.height
            XCTAssertGreaterThan(off, 300, "A tab with its guidance is a card.")
            let remote = try listening(model)
            _ = remote
            Probe.settle(0.8)
            let room = screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin
            if !short { XCTAssertGreaterThan(window.cardSize.height, off + 100, "The code makes the card taller: \(off) → \(window.cardSize.height).") }
            XCTAssertLessThanOrEqual(window.cardSize.height, room + 1, "Never taller than the room under the island: it scrolls instead (\(window.cardSize.height) of \(room)).")
            XCTAssertTrue(screen.contains(window.cardFrame))
            XCTAssertEqual(window.cardFrame.width, SettingsCard.width, accuracy: 0.5)
            model.remote.stop()
            Probe.settle(0.8)
            XCTAssertEqual(window.cardSize.height, off, accuracy: 1, "Off again, the card is as tall as it was.")
        }
    }

    /// The Isla tab got a section («Acerca de»); it is still a compact card, and the Remoto tab (off) is no taller than it.
    func testTheIslandTabWithItsAboutLineIsStillCompact() {
        let screen = CGRect(x: -40000, y: -40000, width: 1512, height: 982)
        let model = makeModel(unlocked: true, tab: .island)
        let window = makeWindow(screen.size, model: model)
        _ = place(window, screen: screen)
        defer { window.hide() }
        Probe.settle()
        XCTAssertGreaterThan(window.cardSize.height, 400)
        XCTAssertLessThan(window.cardSize.height, 700)
        let island = window.cardSize.height
        model.settingsTab = .remote
        Probe.settle(0.6)
        XCTAssertLessThan(window.cardSize.height, island + 1, "The tab, off, is no taller than the island's.")
    }
}
