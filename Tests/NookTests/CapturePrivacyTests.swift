import AppKit
import XCTest
@testable import Nook

/// Only fake backend calls are exercised here. Windows are allocated offscreen and never
/// ordered front; these tests do not assert effectiveness against any screen recorder.
@MainActor
final class CapturePrivacyTests: XCTestCase {
    private final class Backend: CaptureExclusionBackend {
        struct Call: Equatable {
            let window: ObjectIdentifier
            let region: CGRect?
        }
        var isAvailable = true
        var error: Error?
        var calls: [Call] = []

        func setExclusion(on window: NSWindow, region: CGRect?) throws {
            calls.append(Call(window: ObjectIdentifier(window), region: region))
            if let error { throw error }
        }
    }

    /// A native failure as WindowServer would report it, for the fake backend to throw.
    private struct NativeFailure: LocalizedError {
        let code: Int
        var errorDescription: String? { "WindowServer devolvió CGError \(code)." }
    }

    private final class UnallocatedWindow: NSWindow {
        override var windowNumber: Int { -1 }
    }

    private func defaults() -> UserDefaults {
        let name = "nook-capture-privacy-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func window(size: CGSize = CGSize(width: 180, height: 90)) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertGreaterThan(window.windowNumber, 0, "These offscreen AppKit tests require WindowServer access.")
        XCTAssertFalse(window.isVisible)
        return window
    }

    /// The system backend omits the window from captures (sharing type `.none`) rather than
    /// redacting a shape, which macOS paints as a gray block in screen shares.
    func testSystemBackendTogglesTheWindowSharingType() throws {
        let backend = SystemCaptureExclusionBackend()
        let window = window()
        defer { window.close() }

        XCTAssertTrue(backend.isAvailable)
        XCTAssertEqual(window.sharingType, .readOnly)
        try backend.setExclusion(on: window, region: CGRect(origin: .zero, size: window.frame.size))
        XCTAssertEqual(window.sharingType, .none)
        try backend.setExclusion(on: window, region: nil)
        XCTAssertEqual(window.sharingType, .readOnly)
        let unallocated = UnallocatedWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 50),
                                            styleMask: .borderless, backing: .buffered, defer: true)
        unallocated.isReleasedWhenClosed = false
        defer { unallocated.close() }
        XCTAssertThrowsError(try backend.setExclusion(on: unallocated, region: nil))
    }

    func testDefaultOffDoesNotMutateWindowsOrWritePreference() {
        let store = defaults()
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: store, backend: backend)
        let window = window()
        defer { window.close() }

        privacy.prepare(window)
        privacy.prepare(window, size: CGSize(width: 300, height: 200))
        privacy.enabled = false

        XCTAssertFalse(privacy.enabled)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNil(store.object(forKey: CapturePrivacy.defaultsKey))
        XCTAssertNil(privacy.issue)
        XCTAssertFalse(window.isVisible)
    }

    func testPreferencePersistsInTheSuppliedDomainWithoutGlobalWindowDiscovery() {
        let store = defaults()
        let firstBackend = Backend()
        let first = CapturePrivacy(defaults: store, backend: firstBackend)
        let unrelated = window()
        defer { unrelated.close() }

        first.enabled = true
        XCTAssertTrue(store.bool(forKey: CapturePrivacy.defaultsKey))
        XCTAssertTrue(firstBackend.calls.isEmpty)

        let secondBackend = Backend()
        let second = CapturePrivacy(defaults: store, backend: secondBackend)
        XCTAssertTrue(second.enabled)
        XCTAssertTrue(secondBackend.calls.isEmpty, "Construction must not modify unrelated NSApp windows.")
        second.enabled = false
        XCTAssertFalse(CapturePrivacy(defaults: store, backend: Backend()).enabled)
    }

    func testEnableDisableReenableAndLateRegistration() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let first = window()
        let second = window(size: CGSize(width: 210, height: 110))
        defer { first.close(); second.close() }

        privacy.prepare(first)
        privacy.enabled = true
        XCTAssertEqual(backend.calls, [.init(window: ObjectIdentifier(first), region: CGRect(origin: .zero, size: first.frame.size))])
        privacy.prepare(first)
        privacy.prepare(first)
        XCTAssertEqual(backend.calls.count, 1, "Repeated app updates do not repeat an identical native call.")

        privacy.prepare(second)
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertEqual(backend.calls.last?.window, ObjectIdentifier(second))
        privacy.enabled = false
        XCTAssertEqual(backend.calls.count, 4)
        XCTAssertTrue(backend.calls.suffix(2).allSatisfy { $0.region == nil }, "Disabling clears every attempted exclusion with a null region.")
        privacy.prepare(first)
        XCTAssertEqual(backend.calls.count, 4)

        privacy.enabled = true
        XCTAssertEqual(backend.calls.count, 6)
        XCTAssertTrue(backend.calls.suffix(2).allSatisfy { $0.region != nil })
        XCTAssertNil(privacy.issue)
    }

    func testProposedResizeUsesWindowLocalBoundsAndDeduplicates() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        defer { window.close() }
        privacy.enabled = true

        let proposed = CGSize(width: 620, height: 340)
        privacy.prepare(window, size: proposed)
        XCTAssertEqual(backend.calls.last?.region, CGRect(origin: .zero, size: proposed))
        XCTAssertNotEqual(window.frame.size, proposed, "The exclusion is prepared before the frame changes.")
        window.setFrame(CGRect(origin: window.frame.origin, size: proposed), display: false)
        privacy.prepare(window)
        XCTAssertEqual(backend.calls.count, 1)
        privacy.prepare(window, size: CGSize(width: 700, height: 340))
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertEqual(backend.calls.last?.region?.origin, .zero)
    }

    func testEmptyNonfiniteAndUnallocatedWindowsAreSkipped() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let normal = window()
        let unallocated = UnallocatedWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 50),
                                            styleMask: .borderless, backing: .buffered, defer: true)
        unallocated.isReleasedWhenClosed = false
        defer { normal.close(); unallocated.close() }
        privacy.enabled = true

        privacy.prepare(normal, size: .zero)
        privacy.prepare(normal, size: CGSize(width: CGFloat.infinity, height: 80))
        privacy.prepare(normal, size: CGSize(width: 100, height: CGFloat.nan))
        privacy.prepare(normal, size: CGSize(width: -1, height: 80))
        privacy.prepare(unallocated)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertNil(privacy.issue)
    }

    func testCloseClearsBeforeDisableAndReopeningDoesNotLeaveAStaleExclusion() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        privacy.prepare(window)
        privacy.enabled = true
        XCTAssertEqual(backend.calls.count, 1)
        window.close()
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertNil(backend.calls.last?.region, "Close must clear even when the NSWindow is retained for reuse.")

        privacy.enabled = false
        privacy.prepare(window)
        XCTAssertEqual(backend.calls.count, 2, "Reopening while disabled cannot leave the old exclusion applied.")
        privacy.enabled = true
        XCTAssertEqual(backend.calls.count, 3, "Explicitly preparing a retained window registers it again.")
        privacy.enabled = false
        XCTAssertNil(privacy.issue)
    }

    func testFailedCloseCleanupIsRetriedWhenDisablingAndPreservesTheIssue() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        privacy.prepare(window)
        privacy.enabled = true
        backend.error = NativeFailure(code: 1001)
        window.close()
        XCTAssertTrue(privacy.issue?.contains("retirar") == true)
        backend.error = nil
        privacy.enabled = false
        XCTAssertEqual(backend.calls.count, 3)
        XCTAssertNil(backend.calls.last?.region)
        XCTAssertNil(privacy.issue)
        privacy.prepare(window)
        XCTAssertEqual(backend.calls.count, 3)
    }

    func testUnavailableBackendIsReportedWithoutCallingMissingFunctions() {
        let backend = Backend()
        backend.isAvailable = false
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        defer { window.close() }

        XCTAssertFalse(privacy.isAvailable)
        XCTAssertNil(privacy.issue)
        privacy.prepare(window)
        privacy.enabled = true
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertTrue(privacy.issue?.contains("no está disponible") == true)
        privacy.enabled = false
        XCTAssertNil(privacy.issue, "No exclusion was attempted, so there is nothing to undo.")
    }

    func testNativeFailureIsRetainedWithoutBusyRetryAndDisableStillClears() {
        let backend = Backend()
        backend.error = NativeFailure(code: 1000)
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        defer { window.close() }
        privacy.prepare(window)
        privacy.enabled = true

        XCTAssertTrue(privacy.issue?.contains("CGError 1000") == true)
        privacy.prepare(window)
        XCTAssertEqual(backend.calls.count, 1, "A failed identical request is not retried every app update.")
        XCTAssertNotNil(privacy.issue)

        backend.error = nil
        privacy.enabled = false
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertNil(backend.calls.last?.region)
        XCTAssertNil(privacy.issue)
    }

    func testFailedRemovalRemainsReportedUntilAReenableDisableSucceeds() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let window = window()
        defer { window.close() }
        privacy.prepare(window)
        privacy.enabled = true
        backend.error = NativeFailure(code: 1001)
        privacy.enabled = false

        XCTAssertTrue(privacy.issue?.contains("retirar") == true)
        XCTAssertTrue(privacy.issue?.contains("1001") == true)
        privacy.prepare(window)
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertNotNil(privacy.issue)

        backend.error = nil
        privacy.enabled = true
        privacy.enabled = false
        XCTAssertEqual(backend.calls.count, 4)
        XCTAssertNil(privacy.issue)
    }

    func testAHealthyWindowDoesNotEraseAnotherWindowsFailure() {
        let backend = Backend()
        let privacy = CapturePrivacy(defaults: defaults(), backend: backend)
        let failing = window()
        let healthy = window()
        defer { failing.close(); healthy.close() }
        privacy.enabled = true
        backend.error = NativeFailure(code: 1000)
        privacy.prepare(failing)
        backend.error = nil
        privacy.prepare(healthy)

        XCTAssertNotNil(privacy.issue)
        privacy.prepare(failing, size: CGSize(width: 220, height: 120))
        XCTAssertNil(privacy.issue, "A changed request retries that window and can clear its failure.")
    }
}
