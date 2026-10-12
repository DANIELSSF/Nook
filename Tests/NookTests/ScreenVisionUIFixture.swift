import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What the screen vision tests share besides `ScreenVisionFixture`: a screen vision that does nothing real (a capturer and a registrar that only
/// answer, a folder and a socket of its own) inside an app model, and Claude's and Codex's tabs.
@MainActor
enum ScreenVisionUIFixture {
    static func vision(enabled: Bool = true, attach: Bool = false, registrar: ScreenVisionRegistering = FakeRegistrar(), capturer: FakeScreenCapturer = FakeScreenCapturer()) throws -> ScreenVision {
        let vision = ScreenVision(defaults: ScreenVisionFixture.defaults(), capturer: capturer, registrar: registrar, folder: try ScreenVisionFixture.folder(),
                                  relayPath: ScreenVisionFixture.socketPath(), ownPID: 4242, timeout: 2, now: { ScreenVisionFixture.date })
        vision.enabled = enabled
        vision.attachToMessages = attach
        return vision
    }

    static func model(_ vision: ScreenVision) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-sv-ui-" + UUID().uuidString)!, screenVision: vision)
        model.commandSender = { _, _ in }
        model.keySender = { _, _ in }
        return model
    }

    private static let rule = String(repeating: "─", count: 72)

    /// What Claude Code's screen shows: banner, a little conversation, the box, and the mode under it.
    static func claudeScreen(status: String? = nil, mode: String = "  ⏵⏵ auto mode on (shift+tab to cycle)") -> String {
        let banner = ["▗ ▗   ▖ ▖  Claude Code v2.1.290", "           Sonnet 5.5 with high effort · Claude Team", " ▘▘   ▝▝   ~/Documents/app"]
        let lines = banner + ["", "> Revisa por qué falla el build de la API.", "", "⏺ Voy a mirar el log del último build y los cambios recientes.", "", "⏺ Read(apps/api/package.json)", "  ⎿  Read 64 lines", ""]
        return (lines + (status.map { [$0, ""] } ?? []) + [rule, "❯ ", rule, mode]).joined(separator: "\n")
    }

    static let codexScreen = ["╭────────────────────────────────────────╮", "│ >_ OpenAI Codex (v0.50.0)              │", "│ model: gpt-5-codex   /model to change  │", "╰────────────────────────────────────────╯", "",
                              "› Revisa por qué falla el build de la API.", "", "• Voy a mirar el log del último build.", "", "› ", "  ⏎ send   ⌃J newline   ⌃T transcript"].joined(separator: "\n")

    /// A tab of Terminal with an agent on it, selected in `model`, with the island open (as the renders and tests that look at its row need).
    static func session(in model: AppModel, agent: String = "claude", text: String? = nil, tty: String = "/dev/ttys099") -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: agent == "codex" ? "Codex" : "Claude Code", processes: ["login", "-zsh", agent], busy: false,
                                      selected: true, text: text ?? (agent == "codex" ? codexScreen : claudeScreen()))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return session
    }

    /// The permissions' model with the states given: reading them again (as the tab does when it appears) gives the same states, and nothing is asked of the
    /// system or opened.
    static func permissions(_ states: [NookPermission: NookPermission.State]) -> PermissionsModel {
        PermissionsModel(services: PermissionsModel.Services(readStates: { $0(states) }, readClaude: { $0([]) }, request: { _, done in done(.granted) },
                                                             openSettings: { _ in }, openTerminal: { $0() }),
                         states: states, claudeFolders: [], center: NotificationCenter(), workspace: NotificationCenter())
    }

    /// Lets the main queue run (where registration jobs report back) until `condition` holds.
    static func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// The same, for a test that is `async`: it suspends between looks, which a main-queue block (a publisher's hop to the main queue, say) needs to run at all while
    /// the test body is itself a job on that queue.
    static func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Lets time pass, suspended, until `date`.
    static func pause(until date: Date) async {
        while Date() < date { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// A started screen vision with the registration done: `.ready` with both folders (or `.failed` when `registrar` says so).
    static func started(_ vision: ScreenVision) {
        vision.start(serving: false)
        waitUntil { if case .working = vision.registration { return false } else { return true } }
    }

    // MARK: Pictures of views

    /// A view drawn offscreen at `size`, on the island's black, as pixels. Nothing is ordered on screen.
    static func bitmap<V: View>(of view: V, size: CGSize, settle: TimeInterval = 0.3) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        return capture(host)
    }

    static func capture(_ host: NSView) -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The bytes of a picture, to tell whether two are the same.
    static func bytes(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:]) ?? Data() }

    /// The average colour of the pixels of a picture that are not black, as red, green and blue in 0...1 (and how many there were).
    static func average(_ rep: NSBitmapImageRep, within rect: CGRect? = nil) -> (red: Double, green: Double, blue: Double, count: Int) {
        var red = 0.0, green = 0.0, blue = 0.0, count = 0
        let area = rect ?? CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 0.06 {
                    red += color.redComponent; green += color.greenComponent; blue += color.blueComponent; count += 1
                }
            }
        }
        guard count > 0 else { return (0, 0, 0, 0) }
        return (red / Double(count), green / Double(count), blue / Double(count), count)
    }
}


/// A registrar that does not answer until it is let go, so a tab can be looked at while the tool is being added.
final class BlockingRegistrar: ScreenVisionRegistering, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)

    /// Lets one waiting job go (call it once for each job that was started).
    func release() { gate.signal() }

    func register() throws -> ScreenVisionRegistrationResult {
        gate.wait()
        return ScreenVisionRegistrationResult(folders: ["~/.claude"], added: ["~/.claude"])
    }

    func unregister() throws -> ScreenVisionRegistrationResult {
        gate.wait()
        return ScreenVisionRegistrationResult(folders: [])
    }
}
