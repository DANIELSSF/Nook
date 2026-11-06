import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders Nook Remoto's side of the settings card to PNG for visual review, in the dark theme and the light one (set NOOK_RENDER_DIR; `remote-<scene>-<dark|light>.png`): the tab in every
/// state (on a real `RemoteAccess` where it can listen, and drawn from plain values where it cannot, like «Activando» or a phone that has the page open), the code at the sizes a screen
/// gives it, and «Acerca de» at rest and after each of the five taps. Nothing is read or asked of the system, and the pane copies nothing to the clipboard.
@MainActor
final class RemoteSettingsRenderTests: XCTestCase {
    private typealias Probe = SettingsTabBarProbe
    private var remotes: [RemoteAccess] = []

    override func tearDown() {
        remotes.forEach { $0.stop() }
        remotes = []
        super.tearDown()
    }

    private func renderDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render Nook Remoto's settings.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    private let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted, .screenRecording: .granted]
    private let key = "Qz3x9Vb_2LkfG-ZyR8mT1uWcN6sHa4PdE0jXoIiYtAw"
    private let looks: [(name: String, theme: ThemePreference, backdrop: Double)] = [("dark", .dark, 0.3), ("light", .light, 0.8)]

    // MARK: Drawing

    /// A window of `size` (offscreen, in the appearance of `theme`) holding `view`, settled.
    private func window(_ view: some View, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.environment(\.nookTintedGlass, false)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        Probe.settle(0.6)
        return window
    }

    /// The window as big as its content wants, as it is now.
    private func fit(_ window: NSWindow) {
        guard let host = window.contentView as? NSHostingView<AnyView> else { return }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        Probe.settle(0.4)
    }

    private func write(_ window: NSWindow, _ name: String, in directory: URL) throws {
        fit(window)
        let host = try XCTUnwrap(window.contentView)
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            Probe.settle(0.4)
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// The card as the app has it, on a backdrop, in `theme`.
    private func card(_ model: AppModel, theme: ThemePreference, backdrop: Double, screen: CGSize, version: NookVersion = NookVersion(short: "0.2.1", build: "3")) -> NSWindow {
        model.display.theme = theme
        let permissions = ScreenVisionUIFixture.permissions(granted)
        permissions.refresh()
        let card = SettingsCard(model: model, screen: screen, topInset: 32, permissions: permissions, version: version).padding(30).background(Color(white: backdrop))
        return window(card, size: CGSize(width: SettingsCard.width + 60, height: 1600))
    }

    /// Preferences of the test's own, taken out again when it is over.
    private func makeDefaults() -> UserDefaults {
        let name = "nook-remote-render-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel(tab: SettingsTab, unlocked: Bool = true) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: makeDefaults())
        model.animations = false
        if unlocked { model.remote.unlock() }
        model.settingsTab = tab
        return model
    }

    /// The tab drawn from plain values inside the card's chrome (a header's place, the bar with its seven tabs, the surface), for the states a real remote cannot be held in.
    private struct PaneInCard: View {
        var state: RemotePaneState
        var theme: ThemePreference
        var backdrop: Double
        var now: Date
        var maxHeight: CGFloat = 3000

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.nookMint)
                    Text("Ajustes de Nook").font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.nookSecondary).frame(width: 22, height: 22)
                }.padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
                SettingsTabBar(tabs: SettingsTab.allCases, selection: .constant(.remote), attention: []).padding(.horizontal, 16).padding(.bottom, 12)
                RemotePaneContent(state: state, maxHeight: maxHeight, now: now)
            }
            .frame(width: SettingsCard.width)
            .nookGlassCard(radius: 18, dim: 0.96, dimColor: Color.nookSettings, fill: Color.nookSettings, stroke: Color.nookWash(0.1, light: 0.13))
            .nookCardShadow(0.5, radius: 16, y: 6)
            .nookTheme(theme)
            .padding(30).background(Color(white: backdrop))
        }
    }

    private func device(_ id: String, _ label: String, seen secondsAgo: TimeInterval, now: Date) -> RemoteDevice {
        RemoteDevice(id: id, label: label, pairedAt: now.addingTimeInterval(-7200), lastSeen: now.addingTimeInterval(-secondsAgo))
    }

    // MARK: The tab in every state

    func testRenderTheTabInEveryStateFromPlainValues() throws {
        let directory = try renderDirectory()
        let now = Date()
        let on = RemoteAccess.Status.on(url: URL(string: "http://192.168.1.20:8765")!, port: 8765)
        let link = URL(string: "http://192.168.1.20:8765/pair?k=\(key)")
        let three = [device("a", "iPhone · Safari", seen: 4, now: now), device("b", "iPad · Safari", seen: 190, now: now), device("c", "Mac · Chrome", seen: 7300, now: now)]
        let eight = (0..<RemoteRegistry.maxDevices).map { device("d\($0)", $0 % 3 == 0 ? "iPad · Safari" : "iPhone · Safari", seen: TimeInterval($0 * 700 + 5), now: now) }
        let scenes: [(String, RemotePaneState)] = [
            ("starting", RemotePaneState(status: .starting)),
            ("failed-ports", RemotePaneState(status: .failed("Los puertos 8765 a 8775 de este Mac están ocupados por otras apps. Ciérralas y vuelve a intentarlo."))),
            ("failed-network", RemotePaneState(status: .failed("Nook Remoto dejó de funcionar: la red cambió. Vuelve a activarlo."))),
            ("on-three-devices-watching", RemotePaneState(status: on, pairingURL: link, devices: three, watching: true)),
            ("on-ipv6", RemotePaneState(status: .on(url: URL(string: "http://[fe80::1c2b:3a4d:5e6f:7081]:8765")!, port: 8765), pairingURL: URL(string: "http://[fe80::1c2b:3a4d:5e6f:7081]:8765/pair?k=\(key)"),
                                        devices: [three[0]], watching: false)),
            ("on-five-digit-port", RemotePaneState(status: .on(url: URL(string: "http://10.0.0.5:51234")!, port: 51234), pairingURL: URL(string: "http://10.0.0.5:51234/pair?k=\(key)"))),
            ("on-no-link-yet", RemotePaneState(status: on, pairingURL: nil)),
            ("on-full", RemotePaneState(status: on, pairingURL: link, devices: eight, watching: true)),
        ]
        for look in looks {
            for (name, state) in scenes {
                let w = window(PaneInCard(state: state, theme: look.theme, backdrop: look.backdrop, now: now), size: CGSize(width: SettingsCard.width + 60, height: 1800))
                defer { w.close() }
                try write(w, "remote-\(name)-\(look.name)", in: directory)
            }
        }
    }

    func testRenderTheCardOnARealRemote() throws {
        let directory = try renderDirectory()
        for look in looks {
            // Off, in the card as the app has it.
            let off = makeModel(tab: .remote)
            let offWindow = card(off, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1512, height: 3000))
            defer { offWindow.close() }
            try write(offWindow, "remote-card-off-\(look.name)", in: directory)

            // Failed: no home network.
            let failing = makeModel(tab: .remote)
            failing.remote.policy = RemoteSettingsTests.noHomeNetwork()
            failing.remote.start()
            remotes.append(failing.remote)
            let failedWindow = card(failing, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1512, height: 3000))
            defer { failedWindow.close() }
            try write(failedWindow, "remote-card-failed-\(look.name)", in: directory)

            // On, with phones that paired (two of them, an iPhone and an iPad): the whole tab, and the tab as a 14-inch MacBook shows it (the card stops at the room under the island).
            let live = makeModel(tab: .remote)
            let remote = try RemoteFixture.started(live)
            remotes.append(remote)
            let empty = card(live, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1512, height: 3000))
            defer { empty.close() }
            try write(empty, "remote-card-on-empty-\(look.name)", in: directory)
            _ = RemoteFixture.pair(remote)
            RemoteFixture.waitUntil { remote.devices.count == 1 }
            let ipad = RemoteFixture.request("GET", "/pair?k=" + (remote.currentPairingKey ?? ""), remote: remote,
                                             headers: ["user-agent": "Mozilla/5.0 (iPad; CPU OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"])
            _ = RemoteFixture.call(remote, ipad)
            RemoteFixture.waitUntil { remote.devices.count == 2 }
            Probe.settle(0.6)
            try write(empty, "remote-card-on-devices-\(look.name)", in: directory)
            let small = card(live, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1512, height: 982))
            defer { small.close() }
            try write(small, "remote-card-on-14inch-\(look.name)", in: directory)
            let short = card(live, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1280, height: 720))
            defer { short.close() }
            try write(short, "remote-card-on-short-\(look.name)", in: directory)
            remote.stop()
        }
    }

    // MARK: «Acerca de»

    func testRenderTheAboutLineAtRestAndAfterEachTap() throws {
        let directory = try renderDirectory()
        for look in looks {
            let model = makeModel(tab: .island, unlocked: false)
            let w = card(model, theme: look.theme, backdrop: look.backdrop, screen: CGSize(width: 1512, height: 982))
            defer { w.close() }
            let version = "Nook 0.2.1 (3)"
            try write(w, "remote-about-rest-\(look.name)", in: directory)
            for tap in 1...5 {
                XCTAssertTrue(Probe.press(version, in: w))
                if tap >= 3 { try write(w, "remote-about-tap\(tap)-\(look.name)", in: directory) }
            }
            // The card goes to the new tab after a beat; the island's tab is back for the "already active" line.
            Probe.settle(SettingsCard.revealDelay + 0.5)
            try write(w, "remote-about-after-unlock-\(look.name)", in: directory)
            model.settingsTab = .island
            Probe.settle(0.4)
            XCTAssertTrue(Probe.press(version, in: w))
            try write(w, "remote-about-already-\(look.name)", in: directory)
        }
        // Where the bundle has no version (a run from the package): the line says so.
        let dev = makeModel(tab: .island, unlocked: false)
        let w = card(dev, theme: .dark, backdrop: 0.3, screen: CGSize(width: 1512, height: 982), version: NookVersion(info: nil))
        defer { w.close() }
        try write(w, "remote-about-no-version-dark", in: directory)
    }

    // MARK: The code

    func testRenderTheCodeAtTheSizesAScreenGivesIt() throws {
        let directory = try renderDirectory()
        let link = "http://192.168.1.20:8765/pair?k=\(key)"
        let sheet = HStack(alignment: .top, spacing: 14) {
            ForEach([1, 2, 5, 10], id: \.self) { pixels in
                VStack(spacing: 6) {
                    if let image = QRCode.image(for: link, pixelsPerModule: pixels) {
                        Image(decorative: image, scale: 1).interpolation(.none)
                    }
                    Text("\(pixels) px").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.white.opacity(0.8))
                }
            }
        }.padding(16).background(Color(white: 0.3))
        let w = window(sheet, size: CGSize(width: 1200, height: 600))
        defer { w.close() }
        try write(w, "remote-code-sizes", in: directory)
    }
}
