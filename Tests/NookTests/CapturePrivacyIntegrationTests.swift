import AppKit
import SwiftUI
import XCTest
@testable import Nook

@MainActor
final class CapturePrivacyIntegrationTests: XCTestCase {
    private final class Backend: CaptureExclusionBackend {
        var isAvailable = true
        var calls: [(region: CGRect?, frameAtCall: CGRect)] = []
        func setExclusion(on window: NSWindow, region: CGRect?) throws {
            MainActor.assumeIsolated { calls.append((region, window.frame)) }
        }
    }

    private func defaults() -> UserDefaults {
        let name = "nook-privacy-integration-" + UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        return store
    }

    func testPanelAndDetachedTerminalPrepareGrowthBeforeChangingTheFrame() {
        _ = NSApplication.shared
        let original = CGRect(x: -40000, y: -40000, width: 200, height: 100)
        let panel = NotchPanel(contentRect: original, styleMask: .borderless, backing: .buffered, defer: false)
        let mirror = CapturePrivacyWindow(contentRect: original, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        for window in [panel, mirror] as [NSWindow] {
            window.isReleasedWhenClosed = false
            defer { window.close() }
            XCTAssertGreaterThan(window.windowNumber, 0)
            let backend = Backend()
            let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
            privacy.enabled = true
            if let panel = window as? NotchPanel { panel.capturePrivacy = privacy }
            if let mirror = window as? CapturePrivacyWindow { mirror.capturePrivacy = privacy }
            backend.calls.removeAll()
            let before = window.frame
            let grown = CGRect(origin: before.origin, size: CGSize(width: 600, height: 380))
            window.setFrame(grown, display: false)
            XCTAssertEqual(backend.calls.first?.region, CGRect(origin: .zero, size: grown.size))
            XCTAssertEqual(backend.calls.first?.frameAtCall, before, "The new area must be excluded before growth exposes it.")
            XCTAssertEqual(backend.calls.last?.region?.size, window.frame.size)
            backend.calls.removeAll()
            window.setFrame(before, display: false)
            XCTAssertEqual(backend.calls.last?.region, CGRect(origin: .zero, size: before.size), "Shrink must leave the exclusion at the final size.")
            XCTAssertFalse(window.isVisible, "No test window is ever ordered on screen.")
            privacy.enabled = false
            XCTAssertNil(backend.calls.last?.region)
            backend.calls.removeAll()
            window.setFrame(grown, display: false)
            XCTAssertTrue(backend.calls.isEmpty, "Ordinary resizing stays unchanged when privacy is off.")
        }
    }

    func testPopoverAttachmentRegistersItsWindowBeforePresentation() {
        _ = NSApplication.shared
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        privacy.enabled = true
        let window = NSWindow(contentRect: CGRect(x: -40000, y: -40000, width: 320, height: 180), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let attachment = CapturePrivacyAttachment.AttachmentView()
        attachment.privacy = privacy
        window.contentView = attachment
        XCTAssertEqual(backend.calls.last?.region, CGRect(origin: .zero, size: window.frame.size))
        XCTAssertFalse(window.isVisible)
        privacy.enabled = false
    }

    func testPrivacyCardFitsAndResettingDisplayDoesNotChangePrivacy() {
        _ = NSApplication.shared
        let store = defaults()
        let model = AppModel(receivesSignals: false, defaults: store)
        model.settingsTab = .privacy
        XCTAssertFalse(model.capturePrivacy.enabled)
        let permissions = PermissionsModel(states: [:], claudeFolders: [])
        let host = NSHostingView(rootView: SettingsCard(model: model, screen: CGSize(width: 1280, height: 720), topInset: 32, permissions: permissions))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, SettingsCard.width, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 250)
        XCTAssertLessThan(host.fittingSize.height, 520, "The privacy card stays compact.")
        model.capturePrivacy.enabled = true
        model.display = DisplaySettings()
        XCTAssertTrue(model.capturePrivacy.enabled)
        model.capturePrivacy.enabled = false
    }

    /// Optional visual artifact. It never orders a window or reads the user's sessions.
    func testRenderPrivacySettingsOffscreen() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_PRIVACY_RENDER_DIR"] else {
            throw XCTSkip("Set NOOK_PRIVACY_RENDER_DIR for a privacy card preview.")
        }
        _ = NSApplication.shared
        let model = AppModel(receivesSignals: false, defaults: defaults())
        model.settingsTab = .privacy
        let permissions = PermissionsModel(states: [:], claudeFolders: [])
        let host = NSHostingView(rootView: SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: permissions)
            .padding(24).background(Color(white: 0.2)).environment(\.nookTintedGlass, false))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -40000, y: -40000), size: host.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("privacy-settings.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
    }
}
