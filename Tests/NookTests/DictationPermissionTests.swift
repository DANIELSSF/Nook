import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// A dictation error about a permission offers the way to the Permisos tab, beside the message in the composer's status line.
@MainActor
final class DictationPermissionTests: XCTestCase {
    /// The messages `SpeechController` raises when macOS has not been given a permission, and ones that are about something else.
    private let permission = ["Activa Reconocimiento de voz para Nook en Ajustes del Sistema → Privacidad y seguridad.",
                              "Activa el micrófono para Nook en Ajustes del Sistema → Privacidad y seguridad."]
    private let other = ["El dictado no está disponible en este momento.", "No hay un micrófono disponible."]

    func testOnlyPermissionErrorsOfferThePermissionsButton() {
        for message in permission { XCTAssertTrue(PermissionHelp.opensPermissions(message), message) }
        for message in other { XCTAssertFalse(PermissionHelp.opensPermissions(message), message) }
    }

    private func pane(error: String?, width: CGFloat = 572) -> (NSHostingView<AnyView>, NSWindow) {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-dictation-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys060", customTitle: "", processes: ["claude"], busy: false, selected: true, text: "⏺ Listo.")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.transcriptLocated = Date()
        model.sessions = [session]; model.selectedID = session.id
        let view = SessionPane(model: model, session: session, dictationError: error).frame(width: width, height: 204)
            .background(Color.black).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 204)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -40000, y: -40000))
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return (host, window)
    }

    private func render(_ host: NSView, to path: String) throws {
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The mint pixels of the pane's controls row: the connection dot, and the button's wash and text when it is there.
    private func mintPixels(_ host: NSView) throws -> Int {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var count = 0
        // The controls row is the bottom of the pane.
        for y in stride(from: rep.pixelsHigh - 90, to: rep.pixelsHigh, by: 1) {
            for x in 0..<(rep.pixelsWide * 2 / 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.greenComponent > 0.55, color.redComponent < 0.5, color.blueComponent > 0.4, color.greenComponent > color.redComponent + 0.2 { count += 1 }
            }
        }
        return count
    }

    func testThePermissionErrorShowsTheButtonAndOtherErrorsDoNot() throws {
        let (withButton, keepA) = pane(error: permission[0])
        let (without, keepB) = pane(error: other[0])
        let (none, keepC) = pane(error: nil)
        defer { _ = (keepA, keepB, keepC) }
        // The row has a little mint of its own (the connection dot); the pill adds a lot more.
        let baseline = try mintPixels(none)
        XCTAssertGreaterThan(try mintPixels(withButton), baseline + 300, "The mint pill is drawn beside the permission message.")
        XCTAssertEqual(try mintPixels(without), baseline, "No pill for an error about something else.")
    }

    func testRenderTheDictationErrors() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, error, width) in [("permission", permission[0], 572.0), ("permission-mic", permission[1], 572.0), ("permission-compact", permission[0], 500.0), ("other", other[0], 572.0)] {
            let (host, keep) = pane(error: error, width: width)
            try render(host, to: URL(fileURLWithPath: directory).appendingPathComponent("dictation-\(name).png").path)
            _ = keep
        }
    }
}
