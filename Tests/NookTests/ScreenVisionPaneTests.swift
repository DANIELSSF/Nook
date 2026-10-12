import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The settings card's "Pantalla" tab: what each row says for each state, how the tab acts on the model, how tall it is, and the dot on its tab. The model
/// is one with a capturer and a registrar of their own, started (when a test needs the registration) without a socket; the permissions' model reads and asks
/// nothing real.
@MainActor
final class ScreenVisionPaneTests: XCTestCase {
    typealias State = NookPermission.State
    private typealias Copy = ScreenVisionPanePresentation

    /// Stands in for the system under the permissions' model, and remembers what the tab asked of it.
    private final class Recorder {
        var states: [NookPermission: State] = [.screenRecording: .granted]
        var requests: [NookPermission] = []
        var settingsOpened: [NookPermission] = []
        var reads = 0
        var services: PermissionsModel.Services {
            PermissionsModel.Services(readStates: { [self] done in reads += 1; done(states) }, readClaude: { $0([]) },
                                      request: { [self] permission, done in requests.append(permission); done(states[permission] ?? .granted) },
                                      openSettings: { [self] permission in settingsOpened.append(permission) }, openTerminal: { $0() })
        }
        func model() -> PermissionsModel { PermissionsModel(services: services, states: states, claudeFolders: [], center: NotificationCenter(), workspace: NotificationCenter()) }
    }

    // MARK: What the rows say

    func testThePermissionRowSpeaksLouderOnceTheFeatureNeedsIt() {
        let granted = Copy.permission(.granted)
        XCTAssertEqual(granted.chip, "Activado"); XCTAssertEqual(granted.tone, .good)
        XCTAssertNil(granted.action, "Nothing to press when it is on."); XCTAssertNil(granted.detail, "A line when it is on, like the Permisos tab's rows.")

        let notAsked = Copy.permission(.notAsked)
        XCTAssertEqual(notAsked.chip, "Sin activar")
        XCTAssertEqual(notAsked.tone, .attention, "In the Permisos tab it is neutral; here the feature cannot work without it.")
        XCTAssertEqual(notAsked.action, .request, "macOS can still ask once.")

        let denied = Copy.permission(.denied)
        XCTAssertEqual(denied.chip, "Denegado"); XCTAssertEqual(denied.tone, .attention)
        XCTAssertEqual(denied.action, .openSettings, "A refused permission is switched on in System Settings.")

        let unknown = Copy.permission(.unknown)
        XCTAssertEqual(unknown.action, .openSettings); XCTAssertEqual(unknown.tone, .neutral)

        let unread = Copy.permission(nil)
        XCTAssertEqual(unread.chip, "Leyendo…"); XCTAssertNil(unread.action)
    }

    func testOnlyAMissingPermissionSaysWhatMacOSAsksNext() throws {
        for state in [State.notAsked, .denied] {
            let detail = try XCTUnwrap(Copy.permission(state).detail, "\(state)")
            XCTAssertTrue(detail.contains("«Salir y volver a abrir»"), "macOS offers to relaunch Nook once the switch is on: say to accept it. \(detail)")
            XCTAssertTrue(detail.localizedCaseInsensitiveContains("capturar la pantalla"), "It says what the permission is for. \(detail)")
        }
        XCTAssertEqual(Copy.permission(.unknown).detail, Copy.permissionPurpose, "What it is for, without the relaunch advice: it is not known to be missing.")
        XCTAssertNil(Copy.permission(.granted).detail)
    }

    func testTheToolRowFollowsTheRegistrationAndOnlyAFailureCanBeTriedAgain() {
        let cases: [(ScreenVision.Registration, String, PermissionTone, Bool, Bool)] = [
            (.idle, "Sin añadir", .neutral, false, false),
            (.working("Añadiendo la herramienta a Claude Code…"), "En curso", .neutral, true, false),
            (.ready(["~/.claude", "~/.claude-work"]), "Lista", .good, false, false),
            (.failed("No se pudo añadir la herramienta en ~/.claude."), "No se pudo", .bad, false, true),
        ]
        for (registration, chip, tone, working, retry) in cases {
            let shown = Copy.tool(registration)
            XCTAssertEqual(shown.chip, chip, "\(registration)"); XCTAssertEqual(shown.tone, tone); XCTAssertEqual(shown.working, working); XCTAssertEqual(shown.canRetry, retry)
            XCTAssertEqual(shown.sentence, ScreenVision.describe(registration), "The sentence is the model's own, not a second wording of it.")
            XCTAssertNotNil(NSImage(systemSymbolName: shown.symbol, accessibilityDescription: nil), shown.symbol)
        }
        XCTAssertTrue(Copy.tool(.ready(["~/.claude", "~/.claude-work"])).sentence.contains("~/.claude y ~/.claude-work"), "It names the folders it is in.")
    }

    /// The tab tells the user what they are agreeing to: which screen, when, where the pictures stay and for how long, what Nook adds to Claude Code, and who else
    /// could ask for a capture. All of it before the switch is turned on.
    func testTheTabSaysWhatIsCapturedWhenWhereItStaysAndWhoCouldAsk() {
        let facts = Copy.facts.map { "\($0.lead) \($0.text)" }.joined(separator: "\n")
        for word in ["puntero", "sin las ventanas de Nook", "principal o todas", "botón del ojo", "capture_screen", "/tmp", "solo por tu usuario", "24 horas"] {
            XCTAssertTrue(facts.contains(word), "The tab says «\(word)».\n\(facts)")
        }
        XCTAssertTrue(Copy.facts.map(\.lead).contains("En Claude Code."), "It says what changes in Claude Code, and that it is undone.")
        XCTAssertTrue(Copy.facts.map(\.text).joined().contains("la quita"))
        XCTAssertTrue(Copy.privacyNote.contains("cualquier programa") && Copy.privacyNote.contains("tu usuario") && Copy.privacyNote.contains("Mientras esté activada"), Copy.privacyNote)
        for fact in Copy.facts { XCTAssertNotNil(NSImage(systemSymbolName: fact.symbol, accessibilityDescription: nil), fact.symbol) }
        XCTAssertEqual(Copy.switchTitle, "Dejar que Claude vea mi pantalla")
    }

    func testTheTabIsTheFourthAndHasAnImage() {
        XCTAssertEqual(SettingsTab.screen.title, "Pantalla")
        XCTAssertEqual(SettingsTab.allCases.last, .screen, "The tabs that were there keep their places.")
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsTab.screen.symbol, accessibilityDescription: nil))
        XCTAssertEqual(SettingsTab(rawValue: "screen"), .screen)
    }

    // MARK: Acting on the model

    private func window(_ view: some View, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return window
    }

    /// The accessibility node with this label, nil when there is none.
    private func node(of label: String, in window: NSWindow) -> NSObject? {
        // SwiftUI builds its accessibility nodes only when assistive technology is on: the lookup tells the app it is (and waits for the nodes).
        _ = AccessibilityLookup.center(of: label, in: window)
        func search(_ element: AnyObject) -> NSObject? {
            guard let node = element as? NSObject else { return nil }
            if node.value(forKey: "accessibilityLabel") as? String == label, let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, frame != .zero { return node }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { if let found = search(child as AnyObject) { return found } }
        return nil
    }

    /// Where the element with this accessibility label stands in the window, from its top left; nil when there is none.
    private func frame(of label: String, in window: NSWindow) -> NSRect? {
        guard let node = node(of: label, in: window), let host = window.contentView,
              let screen = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return nil }
        let inWindow = window.convertFromScreen(screen)
        return NSRect(x: inWindow.minX, y: host.bounds.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// What VoiceOver says after the label.
    private func value(of label: String, in window: NSWindow) -> String? { node(of: label, in: window)?.value(forKey: "accessibilityValue") as? String }

    /// A click at `point`, from the window's top left.
    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    /// A click in the middle of a button.
    private func click(_ window: NSWindow, on label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(frame(of: label, in: window), "«\(label)» is on the tab.", file: file, line: line)
        click(window, at: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// A click on a switch: the labelled row is the label and, at its end, the switch.
    private func flip(_ window: NSWindow, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(frame(of: label, in: window), "«\(label)» is on the tab.", file: file, line: line)
        click(window, at: NSPoint(x: frame.maxX - 12, y: frame.midY))
    }

    private func hasElement(_ label: String, in window: NSWindow) -> Bool { frame(of: label, in: window) != nil }

    func testTheMainSwitchTurnsTheFeatureOnAndOffAndItIsRemembered() throws {
        let defaults = ScreenVisionFixture.defaults()
        let registrar = FakeRegistrar()
        let vision = ScreenVision(defaults: defaults, capturer: FakeScreenCapturer(), registrar: registrar, folder: try ScreenVisionFixture.folder(), relayPath: ScreenVisionFixture.socketPath(),
                                  ownPID: 4242, timeout: 2, now: { ScreenVisionFixture.date })
        vision.start(serving: false)
        let recorder = Recorder()
        let shown = window(ScreenVisionPane(vision: vision, permissions: recorder.model(), maxHeight: 700).frame(width: 352), size: CGSize(width: 352, height: 700))
        defer { shown.close() }
        XCTAssertFalse(vision.enabled)
        XCTAssertFalse(hasElement("Adjuntar mi pantalla a cada mensaje", in: shown), "The per-message switch and the rows are for when it is on.")
        XCTAssertFalse(hasElement("Grabación de pantalla, Activado", in: shown))

        try flip(shown, Copy.switchTitle)
        XCTAssertTrue(vision.enabled, "A click on the switch turns screen vision on.")
        XCTAssertTrue(defaults.bool(forKey: ScreenVision.enabledKey), "It is remembered.")
        ScreenVisionUIFixture.waitUntil { registrar.calls.contains("register") }
        XCTAssertEqual(registrar.calls, ["register"], "Turning it on adds the tool to Claude Code, once.")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(hasElement("Adjuntar mi pantalla a cada mensaje", in: shown), "The switch that is the composer's chip appears.")
        XCTAssertTrue(hasElement("Grabación de pantalla, Activado", in: shown), "The permission's row appears with its state.")
        XCTAssertTrue(hasElement("Herramienta para Claude, Lista", in: shown), "And the tool's, which the fake registrar has added.")

        try flip(shown, Copy.attachTitle)
        XCTAssertTrue(vision.attachToMessages); XCTAssertTrue(defaults.bool(forKey: ScreenVision.attachKey), "The same switch as the composer's chip.")

        try flip(shown, Copy.switchTitle)
        XCTAssertFalse(vision.enabled)
        ScreenVisionUIFixture.waitUntil { registrar.calls.contains("unregister") }
        XCTAssertEqual(registrar.calls, ["register", "unregister"], "Turning it off takes the tool out again.")
    }

    func testThePermissionsButtonAsksForItAndTheRowFollowsTheAnswer() throws {
        let recorder = Recorder()
        recorder.states = [.screenRecording: .notAsked]
        let vision = try ScreenVisionUIFixture.vision()
        let permissions = recorder.model()
        let shown = window(ScreenVisionPane(vision: vision, permissions: permissions, maxHeight: 700).frame(width: 352), size: CGSize(width: 352, height: 700))
        defer { shown.close() }
        XCTAssertGreaterThanOrEqual(recorder.reads, 1, "The tab reads the permission as it appears.")
        XCTAssertTrue(hasElement("Grabación de pantalla, Sin activar", in: shown))
        try click(shown, on: "Pedir permiso")
        XCTAssertEqual(recorder.requests, [.screenRecording], "The button asks macOS for Screen Recording, and for nothing else.")
        XCTAssertTrue(recorder.settingsOpened.isEmpty)

        recorder.states = [.screenRecording: .denied]
        permissions.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(hasElement("Grabación de pantalla, Denegado", in: shown))
        try click(shown, on: "Abrir Ajustes")
        XCTAssertEqual(recorder.settingsOpened, [.screenRecording], "A refused permission is switched on in System Settings, at its own pane.")
        XCTAssertEqual(recorder.requests, [.screenRecording], "No second prompt: macOS would show nothing.")
    }

    func testAFailureCanBeTriedAgainAndTheRestartNoteIsReadOnce() throws {
        let registrar = FakeRegistrar()
        registrar.registerResult = .failure(ScreenVisionRegistrationError.timedOut("claude"))
        let vision = try ScreenVisionUIFixture.vision(registrar: registrar)
        ScreenVisionUIFixture.started(vision)
        guard case .failed = vision.registration else { return XCTFail("\(vision.registration)") }
        let shown = window(ScreenVisionPane(vision: vision, permissions: Recorder().model(), maxHeight: 700).frame(width: 352), size: CGSize(width: 352, height: 700))
        defer { shown.close() }
        XCTAssertTrue(hasElement("Herramienta para Claude, No se pudo", in: shown))
        XCTAssertFalse(hasElement("Entendido", in: shown), "Nothing was added: no restart to tell of.")

        registrar.registerResult = .success(ScreenVisionRegistrationResult(folders: ["~/.claude"], added: ["~/.claude"]))
        try click(shown, on: "Reintentar")
        ScreenVisionUIFixture.waitUntil { if case .ready = vision.registration { return true } else { return false } }
        XCTAssertEqual(registrar.calls, ["register", "register"], "«Reintentar» runs the registration again.")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(hasElement("Herramienta para Claude, Lista", in: shown))
        XCTAssertTrue(vision.needsClaudeRestart)
        XCTAssertTrue(hasElement("Entendido", in: shown), "The tool was just added: sessions already open need a restart, and the note says so.")
        try click(shown, on: "Entendido")
        XCTAssertFalse(vision.needsClaudeRestart, "Read once, it goes.")
        XCTAssertFalse(hasElement("Entendido", in: shown))
    }

    // MARK: How tall it is

    /// The tab's own height with all the room it wants.
    private func height(_ vision: ScreenVision, permission: State, maxHeight: CGFloat = 5000) -> CGFloat {
        let recorder = Recorder()
        recorder.states = [.screenRecording: permission]
        let host = NSHostingView(rootView: ScreenVisionPane(vision: vision, permissions: recorder.model(), maxHeight: maxHeight).frame(width: SettingsCard.width).environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheTabFitsUnderTheIslandOnTheScreensItsCardHas() throws {
        // The card's own room: the screen less the island, the gap and the margin, and less the header and the tabs.
        func room(_ screen: CGFloat) -> CGFloat {
            max(360, screen - NotchGeometry.expandedHeight(topInset: 32) - SettingsPlacement.gap - SettingsPlacement.margin) - SettingsCard.chromeHeight
        }
        let off = try ScreenVisionUIFixture.vision(enabled: false)
        let first = try ScreenVisionUIFixture.vision(attach: true)
        ScreenVisionUIFixture.started(first)
        XCTAssertTrue(first.needsClaudeRestart)
        let offHeight = height(off, permission: .granted)
        XCTAssertLessThan(offHeight, 360, "Off, the tab is a switch and what it means: a short card.")
        let ready = height(first, permission: .granted)
        let setup = height(first, permission: .notAsked)
        XCTAssertGreaterThan(ready, offHeight, "On, it grows by what it needs: the switch and the two rows.")
        XCTAssertGreaterThan(setup, ready, "A missing permission says more.")
        // The first time: the permission missing, the tool just added and its note. It fits a MacBook's screen without scrolling.
        XCTAssertLessThanOrEqual(setup, room(982), "Everything the first setup shows fits the card on a 14-inch screen. It is \(setup) and the room is \(room(982)).")
        // A short screen scrolls instead of running off it: the tab never asks for more than it is given.
        XCTAssertLessThanOrEqual(height(first, permission: .notAsked, maxHeight: room(720)), room(720) + 0.5)
    }

    // MARK: The card's window and the dot on the tab

    private func makeWindow(_ screen: CGSize, vision: ScreenVision, states: [NookPermission: State]) -> (SettingsWindow, AppModel) {
        let model = ScreenVisionUIFixture.model(vision)
        model.settingsTab = .screen
        let recorder = Recorder()
        recorder.states = states
        return (SettingsWindow(model: model, screen: screen, topInset: 32, level: .normal, permissions: recorder.model()) {}, model)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }

    func testTheWindowFollowsTheTabAsTheFeatureIsTurnedOnAndOff() throws {
        let screen = CGRect(x: -40000, y: -40000, width: 1512, height: 982)
        let vision = try ScreenVisionUIFixture.vision(enabled: false)
        let (window, _) = makeWindow(screen.size, vision: vision, states: [.screenRecording: .notAsked])
        let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: island, on: screen)
        window.panel.orderFrontRegardless()
        defer { window.hide() }
        settle()
        let off = window.cardSize.height, top = window.cardFrame.maxY
        XCTAssertEqual(top, island.minY - SettingsPlacement.gap, accuracy: 0.5)

        vision.enabled = true
        settle()
        XCTAssertGreaterThan(window.cardSize.height, off + 100, "On, the rows come in and the window grew to hold them.")
        XCTAssertLessThanOrEqual(window.cardSize.height, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin + 1, "Never past the screen.")
        XCTAssertEqual(window.cardFrame.maxY, top, accuracy: 0.5, "The card's top edge stays under the island.")

        vision.enabled = false
        settle()
        // The first measure is made before the card is in a window, where the small switch is measured at its regular size (4 pt more); every one after it is true.
        XCTAssertEqual(window.cardSize.height, off, accuracy: 5, "Off again, the card is as short as it was.")
        vision.enabled = true; settle(); vision.enabled = false; settle()
        let settled = window.cardSize.height
        vision.enabled = true; settle(); vision.enabled = false; settle()
        XCTAssertEqual(window.cardSize.height, settled, accuracy: 0.5, "And from then on it comes back to exactly the same height.")
    }

    func testOnAShortScreenTheTabScrollsInsteadOfOverflowing() throws {
        let screen = CGRect(x: -40000, y: -40000, width: 1280, height: 720)
        let vision = try ScreenVisionUIFixture.vision()
        ScreenVisionUIFixture.started(vision)
        let (window, _) = makeWindow(screen.size, vision: vision, states: [.screenRecording: .notAsked])
        let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: island, on: screen)
        window.panel.orderFrontRegardless()
        defer { window.hide() }
        settle()
        XCTAssertLessThanOrEqual(window.cardSize.height, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin + 1)
        XCTAssertTrue(screen.contains(window.cardFrame))
    }

    func testTheTabOfAFeatureThatCannotWorkWearsTheDot() throws {
        let screen = CGRect(x: -40000, y: -40000, width: 1512, height: 982)
        let dot = "Falta el permiso de grabación de pantalla"
        for (enabled, state, shown) in [(true, State.notAsked, true), (true, .denied, true), (true, .granted, false), (false, .notAsked, false), (true, .unknown, false)] {
            let (window, _) = makeWindow(screen.size, vision: try ScreenVisionUIFixture.vision(enabled: enabled), states: [.screenRecording: state])
            let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
            window.place(under: island, on: screen)
            window.panel.orderFrontRegardless()
            settle()
            XCTAssertEqual(value(of: "Pantalla", in: window.panel) ?? "", shown ? dot : "", "enabled \(enabled), \(state)")
            XCTAssertEqual(value(of: "Permisos", in: window.panel) ?? "", "", "The needed permission (Terminal's) is not in question here: the card's other dot is off.")
            window.hide()
        }
    }
}
