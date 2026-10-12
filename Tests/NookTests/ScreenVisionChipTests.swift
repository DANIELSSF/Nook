import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The composer's screen toggle: when the row offers it, what it says, how it looks in its states and in every tab colour, what a click does, and how it shows a
/// wait and a capture. Nothing real is captured: the screen vision has a capturer that only answers.
@MainActor
final class ScreenVisionChipTests: XCTestCase {
    // MARK: When the row offers it

    func testTheRowOffersTheChipOnlyWhileTheSettingIsOnForAnAgentAndTheKeysAreAway() throws {
        let off = try ScreenVisionUIFixture.vision(enabled: false), on = try ScreenVisionUIFixture.vision(enabled: true)
        for agent in [TerminalAgent.claude, .codex, nil] {
            XCTAssertFalse(ScreenVisionChipCopy.offers(off, agent: agent, keysOpen: false), "The setting is off: no chip, whoever runs in the tab (\(String(describing: agent))).")
        }
        XCTAssertTrue(ScreenVisionChipCopy.offers(on, agent: .claude, keysOpen: false))
        XCTAssertTrue(ScreenVisionChipCopy.offers(on, agent: .codex, keysOpen: false), "Codex opens an image path too: its tabs have the chip as well.")
        XCTAssertFalse(ScreenVisionChipCopy.offers(on, agent: nil, keysOpen: false), "A plain shell would run the path as an argument.")
        XCTAssertFalse(ScreenVisionChipCopy.offers(on, agent: .claude, keysOpen: true), "The strip of menu keys needs the room, as for Claude's chips.")
        // It follows the model's own rule for the toggle, which the logic tests hold.
        for agent in [TerminalAgent.claude, .codex, nil] { XCTAssertEqual(ScreenVisionChipCopy.offers(on, agent: agent, keysOpen: false), on.offersToggle(for: agent)) }
    }

    /// A pane of `session` in a window far off every display, settled.
    private func pane(_ model: AppModel, _ session: TerminalSession) -> NSWindow {
        let host = NSHostingView(rootView: SessionPane(model: model, session: session, dismissals: RecapSeenStore(defaults: nil)).frame(width: 500, height: 300)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return window
    }

    func testTheChipIsInTheRowOfClaudeAndCodexTabsButNotOfAShellOrWhileTheSettingIsOff() throws {
        let vision = try ScreenVisionUIFixture.vision()
        let model = ScreenVisionUIFixture.model(vision)
        let label = ScreenVisionChipCopy.label
        for agent in ["claude", "codex"] {
            let window = pane(model, ScreenVisionUIFixture.session(in: model, agent: agent))
            XCTAssertNotNil(AccessibilityLookup.center(of: label, in: window), "The \(agent) tab's row has the chip.")
            window.close()
        }
        // A plain shell: the picture's path would be run as an argument.
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-sv-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-sv-" + UUID().uuidString.prefix(6), name: "Terminal", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        let shell = TerminalSession(record: record, backend: backend, create: false)
        model.sessions = [shell]; model.selectedID = shell.id
        let shellWindow = pane(model, shell)
        XCTAssertNil(shell.agent)
        XCTAssertNil(AccessibilityLookup.center(of: label, in: shellWindow), "A shell has no use for it.")
        shellWindow.close()
        // The same Claude row with the setting off is the row it always was, and turning the setting on brings the chip in without rebuilding anything.
        vision.enabled = false
        let window = pane(model, ScreenVisionUIFixture.session(in: model, agent: "claude"))
        XCTAssertNil(AccessibilityLookup.center(of: label, in: window), "Off, the row is the row it always was.")
        vision.enabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotNil(AccessibilityLookup.center(of: label, in: window), "The pane follows the setting: it observes screen vision, which the model does not forward.")
        vision.enabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(AccessibilityLookup.center(of: label, in: window), "And follows it out again.")
        window.close()
    }

    /// The accessibility node with this label (or, for a line of text, this value), nil when there is none.
    private func node(labelled label: String, in window: NSWindow) -> NSObject? {
        _ = AccessibilityLookup.center(of: label, in: window)
        func search(_ element: AnyObject) -> NSObject? {
            guard let node = element as? NSObject else { return nil }
            if node.value(forKey: "accessibilityLabel") as? String == label || node.value(forKey: "accessibilityValue") as? String == label { return node }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { if let found = search(child as AnyObject) { return found } }
            return nil
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { if let found = search(child as AnyObject) { return found } }
        return nil
    }

    func testWhileAMessageWaitsForItsPictureTheRowSaysSoAndSendWaitsToo() throws {
        let capturer = FakeScreenCapturer()
        capturer.delay = 1.0
        let vision = try ScreenVisionUIFixture.vision(attach: true, capturer: capturer)
        let model = ScreenVisionUIFixture.model(vision)
        let session = ScreenVisionUIFixture.session(in: model, agent: "claude")
        // A second message is already being written, so Send would be live if it were not for the wait.
        let host = NSHostingView(rootView: SessionPane(model: model, session: session, draft: "otra cosa", dismissals: RecapSeenStore(defaults: nil)).frame(width: 500, height: 300)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(node(labelled: "Capturando tu pantalla…", in: window), "Nothing is being captured.")
        let send = try XCTUnwrap(node(labelled: "Enviar", in: window))
        XCTAssertEqual(send.value(forKey: "accessibilityEnabled") as? Bool, true, "A message is ready, so Send is live.")

        var delivered = false
        vision.prepareMessage(files: [], withScreen: true, deliver: { _ in delivered = true }, failed: { XCTFail($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(vision.capturing)
        XCTAssertNotNil(node(labelled: "Capturando tu pantalla…", in: window), "The row's line says what it waits for, in the status line's place.")
        XCTAssertEqual(try XCTUnwrap(node(labelled: "Enviar", in: window)).value(forKey: "accessibilityEnabled") as? Bool, false, "Send waits for the picture, as it does while a message is being sent.")
        ScreenVisionUIFixture.waitUntil(4) { delivered }
        XCTAssertTrue(delivered)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNil(node(labelled: "Capturando tu pantalla…", in: window), "The picture is in: the line is gone.")
        XCTAssertEqual(try XCTUnwrap(node(labelled: "Enviar", in: window)).value(forKey: "accessibilityEnabled") as? Bool, true, "And Send is live again.")
    }

    // MARK: What it says

    func testTheTooltipSaysWhatTheChipIsDoingAndWhatAClickDoes() {
        let on = ScreenVisionChipCopy.help(attaching: true, capturing: false, agent: .claude)
        XCTAssertTrue(on.hasPrefix("Pantalla adjunta"), on)
        XCTAssertTrue(on.contains("Claude") && on.contains("sin las ventanas de Nook") && on.contains("donde está el puntero"), "It says whose picture it is and what is left out. \(on)")
        XCTAssertTrue(on.contains("Pulsa para dejar de adjuntarla"), "A click turns it off. \(on)")
        let off = ScreenVisionChipCopy.help(attaching: false, capturing: false, agent: .codex)
        XCTAssertTrue(off.hasPrefix("Pantalla sin adjuntar"), off)
        XCTAssertTrue(off.contains("Codex") && off.contains("Pulsa para que cada mensaje"), "It is the tab's own agent that is named, and a click turns it on. \(off)")
        XCTAssertEqual(ScreenVisionChipCopy.help(attaching: true, capturing: true, agent: .claude), "Capturando tu pantalla para el mensaje…", "While a message waits the tooltip says so.")
        XCTAssertNotEqual(on, off)
        XCTAssertTrue(ScreenVisionChipCopy.help(attaching: true, capturing: false, agent: nil).contains("el agente"))
    }

    func testVoiceOverHearsAToggleWithItsStateAndWhatAPressDoes() {
        XCTAssertEqual(ScreenVisionChipCopy.label, "Adjuntar mi pantalla a cada mensaje")
        XCTAssertEqual(ScreenVisionChipCopy.value(attaching: true, capturing: false), "activado")
        XCTAssertEqual(ScreenVisionChipCopy.value(attaching: false, capturing: false), "desactivado")
        XCTAssertEqual(ScreenVisionChipCopy.value(attaching: true, capturing: true), "capturando")
        XCTAssertNotEqual(ScreenVisionChipCopy.hint(attaching: true), ScreenVisionChipCopy.hint(attaching: false))
        XCTAssertTrue(ScreenVisionChipCopy.hint(attaching: true).hasPrefix("Deja de"), "On, a press stops it.")
        XCTAssertTrue(ScreenVisionChipCopy.hint(attaching: false).hasPrefix("Adjunta"), "Off, a press starts it.")
    }

    // MARK: How it looks

    private func host(_ vision: ScreenVision, tint: TabTint = .mint, look: ScreenVisionChipLook = .resting, animated: Bool = true) -> some View {
        ScreenVisionChip(vision: vision, agent: .claude, animated: animated, look: look).environment(\.tabTint, tint).padding(8)
    }

    func testTheChipIsARoundChipTheSizeOfTheOthers() throws {
        for attach in [false, true] {
            let chip = NSHostingView(rootView: ScreenVisionChip(vision: try ScreenVisionUIFixture.vision(attach: attach), agent: .claude))
            XCTAssertEqual(chip.fittingSize, CGSize(width: ChipMetrics.side, height: ChipMetrics.side), "On or off, 24 pt square, like the model's, the effort's and the usage's.")
        }
        XCTAssertEqual(ScreenVisionChip.side, ClaudeModelChip.height); XCTAssertEqual(ScreenVisionChip.side, ClaudeModeChip.height)
        for symbol in ["eye", "eye.slash"] { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol) }
    }

    func testOnTheChipWearsTheTabColourAndOffStaysNeutral() throws {
        let off = try ScreenVisionUIFixture.vision(attach: false), on = try ScreenVisionUIFixture.vision(attach: true)
        let size = CGSize(width: 40, height: 40)
        // Neutral: the island's grey, whatever the tab colour.
        for tint in TabTint.allCases {
            let grey = ScreenVisionUIFixture.average(ScreenVisionUIFixture.bitmap(of: host(off, tint: tint), size: size))
            XCTAssertGreaterThan(grey.count, 50, "\(tint): the chip is drawn")
            XCTAssertLessThan(max(abs(grey.red - grey.green), abs(grey.green - grey.blue), abs(grey.red - grey.blue)), 0.03, "\(tint): off, the chip carries no colour of the tab's")
        }
        // On: the tab's colour. Compared with the grey above, the chip is clearly tinted toward the tab's own hue.
        for tint in TabTint.allCases where tint != .gray {
            let colour = ScreenVisionUIFixture.average(ScreenVisionUIFixture.bitmap(of: host(on, tint: tint), size: size))
            let voice = tint.voice.accent
            XCTAssertGreaterThan(max(abs(colour.red - colour.green), abs(colour.green - colour.blue), abs(colour.red - colour.blue)), 0.04, "\(tint): on, the chip is coloured")
            // The dominant channel of the tab's accent is the chip's brightest too.
            let accentTop = [voice.red, voice.green, voice.blue].enumerated().max { $0.element < $1.element }!.offset
            let chipTop = [colour.red, colour.green, colour.blue].enumerated().max { $0.element < $1.element }!.offset
            XCTAssertEqual(chipTop, accentTop, "\(tint): the chip leans toward the tab's hue")
        }
        // On is also a different shape (a ring and an open eye), so it does not rest on colour alone.
        let a = ScreenVisionUIFixture.bytes(ScreenVisionUIFixture.bitmap(of: host(off, tint: .gray), size: size)), b = ScreenVisionUIFixture.bytes(ScreenVisionUIFixture.bitmap(of: host(on, tint: .gray), size: size))
        XCTAssertNotEqual(a, b, "Even in the grey tab, on and off differ.")
    }

    private func luminance(_ c: TabRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }
    private func contrast(_ a: TabRGB, _ b: TabRGB) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testTheOpenEyeReadsOnItsWashInEveryTabColour() {
        // The lightest surface the chip stands on (the composer's flat fill over the island's black, with a margin), under the wash it takes at rest, with the
        // pointer over it and with the mouse down.
        let surface = TabRGB(0.09, 0.09, 0.09)
        for tint in TabTint.allCases {
            let glyph = tint.voice.marker
            for (state, wash, needed) in [("at rest", ScreenVisionChip.onWash(hovered: false, pressed: false), 4.5), ("hovered", ScreenVisionChip.onWash(hovered: true, pressed: false), 4.5),
                                          ("pressed", ScreenVisionChip.onWash(hovered: true, pressed: true), 3.0)] {
                XCTAssertGreaterThanOrEqual(contrast(glyph, surface.mixed(with: tint.voice.accent, by: wash)), needed, "\(tint) \(state)")
            }
        }
        // Off: the island's own label grey (primary at 78 %) on its neutral wash.
        let label = surface.mixed(with: TabRGB(1, 1, 1), by: 0.78)
        XCTAssertGreaterThanOrEqual(contrast(label, surface.mixed(with: TabRGB(1, 1, 1), by: ChipWash.pressed)), 4.5)
    }

    // MARK: What a click does

    private func window(_ view: some View, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        let location = NSPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testAClickOnTheChipFlipsTheSwitchAndItIsRemembered() throws {
        let defaults = ScreenVisionFixture.defaults()
        let vision = ScreenVision(defaults: defaults, capturer: FakeScreenCapturer(), registrar: FakeRegistrar(), folder: try ScreenVisionFixture.folder(), relayPath: ScreenVisionFixture.socketPath(),
                                  ownPID: 4242, timeout: 2, now: { ScreenVisionFixture.date })
        vision.enabled = true
        let shown = window(ScreenVisionChip(vision: vision, agent: .claude).padding(20).frame(width: 120, height: 64, alignment: .topLeading), size: CGSize(width: 120, height: 64))
        defer { shown.close() }
        let middle = NSPoint(x: 20 + 12, y: 20 + 12)
        XCTAssertFalse(vision.attachToMessages)
        click(shown, at: middle)
        XCTAssertTrue(vision.attachToMessages, "A click attaches the screen to each message from now on.")
        XCTAssertTrue(vision.attachesToMessages)
        XCTAssertTrue(defaults.bool(forKey: ScreenVision.attachKey), "It is remembered.")
        click(shown, at: middle)
        XCTAssertFalse(vision.attachToMessages, "And a second click takes it back.")
        XCTAssertFalse(defaults.bool(forKey: ScreenVision.attachKey))
        // The corner of its 24 pt square is not the circle: a click there is not the chip's.
        click(shown, at: NSPoint(x: 20 + 1, y: 20 + 1))
        XCTAssertFalse(vision.attachToMessages, "The chip is round, and so is the place that answers.")
        // The whole circle answers, edge to edge.
        click(shown, at: NSPoint(x: 20 + 23, y: 20 + 12))
        XCTAssertTrue(vision.attachToMessages)
    }

    // MARK: The wait and the shutter

    /// A picture of the chip as it is now, in a window that stays, so a state that comes later shows in the same view.
    @MainActor private final class Live {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(_ view: some View, size: CGSize) {
            host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)))
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }
        func picture(after seconds: TimeInterval) -> Data {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            return ScreenVisionUIFixture.bytes(ScreenVisionUIFixture.capture(host))
        }
        deinit { MainActor.assumeIsolated { window.close() } }
    }

    func testAShortWaitShowsNothingAndALongOneShowsTheArcUntilThePictureIsTaken() throws {
        let capturer = FakeScreenCapturer()
        capturer.delay = 0.9
        let vision = try ScreenVisionUIFixture.vision(attach: true, capturer: capturer)
        let live = Live(ScreenVisionChip(vision: vision, agent: .claude, busyAfter: 0.2).padding(8), size: CGSize(width: 40, height: 40))
        let idle = live.picture(after: 0.3)
        vision.prepareMessage(files: [], withScreen: true, deliver: { _ in }, failed: { XCTFail($0) })
        XCTAssertTrue(vision.capturing)
        XCTAssertEqual(live.picture(after: 0.05), idle, "Within the first moments the chip is as it was: a ring for an instant would only flicker.")
        let waiting = live.picture(after: 0.45)
        XCTAssertNotEqual(waiting, idle, "Past the grace, the chip shows it waits.")
        ScreenVisionUIFixture.waitUntil(3) { !vision.capturing }
        XCTAssertFalse(vision.capturing)
        // The picture is in: the wait is over (and the shutter has gone off, which the next test looks at).
        let after = live.picture(after: 1.2)
        XCTAssertEqual(after, idle, "Nothing of the wait or the shutter is left a moment later.")
    }

    func testAFastCaptureNeverShowsTheArc() throws {
        let vision = try ScreenVisionUIFixture.vision(attach: true)
        let live = Live(ScreenVisionChip(vision: vision, agent: .claude, busyAfter: 0.5).padding(8), size: CGSize(width: 40, height: 40))
        let idle = live.picture(after: 0.3)
        var delivered = false
        vision.prepareMessage(files: [], withScreen: true, deliver: { _ in delivered = true }, failed: { XCTFail($0) })
        ScreenVisionUIFixture.waitUntil(3) { delivered }
        XCTAssertTrue(delivered)
        XCTAssertFalse(vision.capturing)
        // The shutter is the only thing that happened to the chip, and it ends.
        XCTAssertEqual(live.picture(after: 1.2), idle)
    }

    func testTheShutterFlashesForAMessagesPictureAndNotForClaudes() throws {
        let vision = try ScreenVisionUIFixture.vision(attach: true)
        let live = Live(ScreenVisionChip(vision: vision, agent: .claude).padding(8), size: CGSize(width: 40, height: 40))
        let idle = live.picture(after: 0.3)
        // Claude's own look is told elsewhere (the cue under the island): this chip is about the message's.
        _ = try runCapture(vision, origin: .claude)
        XCTAssertEqual(live.picture(after: 0.15), idle, "A capture Claude asked for does not flash the composer's chip.")
        _ = try runCapture(vision, origin: .composer)
        let flashed = live.picture(after: 0.12)
        XCTAssertNotEqual(flashed, idle, "A message's picture flashes the chip.")
        XCTAssertEqual(live.picture(after: 1.2), idle, "And the flash is over in a moment.")
    }

    func testWithoutMotionTheFlashIsHeldAWhileAndThenGone() throws {
        let vision = try ScreenVisionUIFixture.vision(attach: true)
        let live = Live(ScreenVisionChip(vision: vision, agent: .claude, animated: false).padding(8), size: CGSize(width: 40, height: 40))
        let idle = live.picture(after: 0.3)
        _ = try runCapture(vision, origin: .composer)
        let held = live.picture(after: 0.2)
        XCTAssertNotEqual(held, idle, "It still says a picture was taken: a brighter chip, with nothing that moves.")
        XCTAssertEqual(live.picture(after: 0.3), held, "Held: the same picture while it lasts, not a frame of an animation.")
        XCTAssertEqual(live.picture(after: 1.0), idle, "And gone after \(ScreenVisionChip.heldSeconds) s.")
    }

    /// A capture, taken as the model's two ways in take it.
    private func runCapture(_ vision: ScreenVision, origin: ScreenVisionOrigin) throws -> [ScreenShot] {
        var result: Result<[ScreenShot], Error>?
        Task { @MainActor in
            do { result = .success(try await vision.capture(.pointer, origin: origin)) } catch { result = .failure(error) }
        }
        ScreenVisionUIFixture.waitUntil(5) { result != nil }
        return try XCTUnwrap(result, "The capture answered").get()
    }
}
