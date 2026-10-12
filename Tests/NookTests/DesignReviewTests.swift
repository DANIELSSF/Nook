import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What the design review fixed, held in place: a theme switch cross-fades the window instead of flipping in a frame; a press where nothing may move
/// is still seen (the label dims); the island's menus draw the labels they are given, so their look and their click motion show; a tab moves a place
/// at a time for VoiceOver, which cannot drag it. The windows here are the test's own, off screen and never made key.
@MainActor
final class DesignReviewTests: XCTestCase {
    private func window(for host: NSView, size: NSSize) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        return window
    }

    private func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: The theme

    private final class Theme: ObservableObject { @Published var preference = ThemePreference.dark }
    private struct Themed: View {
        @ObservedObject var theme: Theme
        var animations: Bool
        var body: some View {
            Color.nookScreenSolid.frame(width: 80, height: 40).nookTheme(theme.preference).nookMotion(animations)
        }
    }

    private func themeFade(animations: Bool) throws -> (atFirst: Bool, afterSwitch: Bool) {
        let theme = Theme()
        let host = NSHostingView(rootView: Themed(theme: theme, animations: animations))
        let window = window(for: host, size: NSSize(width: 80, height: 40))
        wait(0.2)
        let layer = try XCTUnwrap(window.contentView?.layer, "the window's root is layer-backed")
        let atFirst = layer.animation(forKey: NookAppearanceView.fadeKey) != nil
        theme.preference = .light
        wait(0.05)
        let after = layer.animation(forKey: NookAppearanceView.fadeKey) != nil
        XCTAssertEqual(window.appearance?.name, .aqua, "the window takes the new theme either way")
        return (atFirst, after)
    }

    func testSwitchingTheThemeCrossFadesTheWindow() throws {
        let fade = try themeFade(animations: true)
        XCTAssertFalse(fade.atFirst, "a window that just came on screen takes its theme without a fade")
        XCTAssertTrue(fade.afterSwitch, "the user's switch fades from the old look to the new one")
    }

    func testWithTheAnimationsOffTheThemeFlips() throws {
        let fade = try themeFade(animations: false)
        XCTAssertFalse(fade.afterSwitch)
    }

    // MARK: A press without motion

    private struct Pressable: View {
        var animations: Bool
        var body: some View {
            Button {} label: { Color.white.frame(width: 60, height: 30) }
                .nookPress(.pop).accessibilityLabel("Botón de prueba")
                .frame(width: 100, height: 50).background(Color.black)
                .nookMotion(animations)
        }
    }

    /// The brightness of the middle of the button, with the pointer down on it or not.
    private func brightness(animations: Bool, pressed: Bool) throws -> Double {
        let host = NSHostingView(rootView: Pressable(animations: animations).environment(\.colorScheme, .dark))
        let window = window(for: host, size: NSSize(width: 100, height: 50))
        wait(0.2)
        if pressed {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 25), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            wait(0.3)
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if pressed {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 50, y: 25), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    func testAPressIsSeenEvenWhereNothingMayMove() throws {
        XCTAssertGreaterThan(try brightness(animations: false, pressed: false), 0.95, "at rest the label is as it is")
        XCTAssertLessThan(try brightness(animations: false, pressed: true), 0.75, "pressed with the animations off, it dims instead of sinking")
        XCTAssertGreaterThan(try brightness(animations: true, pressed: true), 0.95, "with motion, the press is the sink, not a dim")
    }

    // MARK: Menus

    /// The island's menus (`nookMenu`) draw their label as it is written; the system's borderless menu drew only its image and title, and so none of the
    /// label's colours, pill or motion.
    func testAMenuDrawsTheLabelItIsGiven() throws {
        let view = Menu { Button("A") {} } label: { Color(red: 1, green: 0, blue: 0).frame(width: 40, height: 24) }
            .nookMenu().frame(width: 80, height: 40).background(Color.black)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        _ = window(for: host, size: NSSize(width: 80, height: 40))
        wait(0.3)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // The window's colour space shifts the pure red a little; the borderless menu drew none of it (the black came through).
        XCTAssertGreaterThan(middle.redComponent, 0.8)
        XCTAssertLessThan(middle.greenComponent, 0.4, "the label's own fill is drawn")
    }

    // MARK: Moving a tab without dragging it

    func testATabMovesAPlaceAtATimeForVoiceOver() {
        let name = "nook-design-review-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.sessions = ["Alfa", "Beta", "Gamma"].enumerated().map { index, title in
            TerminalSession(tab: TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: index + 1, tty: "/dev/ttys09\(index)", customTitle: title, processes: ["login", "-zsh"],
                                                     busy: false, selected: false, text: ""), backend: .bundled, bridge: model.terminalBridge)
        }
        let first = model.sessions[0].id
        model.moveSession(first, by: 1)
        XCTAssertEqual(model.sessions.map(\.displayTitle), ["Beta", "Alfa", "Gamma"])
        model.moveSession(first, by: 1)
        model.moveSession(first, by: 1)
        XCTAssertEqual(model.sessions.map(\.displayTitle), ["Beta", "Gamma", "Alfa"], "past the end it stays at the end")
        model.moveSession(first, by: -2)
        XCTAssertEqual(model.sessions.map(\.displayTitle), ["Alfa", "Beta", "Gamma"])
        model.moveSession(first, by: -1)
        XCTAssertEqual(model.sessions.map(\.displayTitle), ["Alfa", "Beta", "Gamma"], "before the start it stays first")
    }
}
