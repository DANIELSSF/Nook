import AVFoundation
import Speech
import XCTest
@testable import Nook

final class PermissionsTests: XCTestCase {
    func testEachPermissionOpensItsOwnPaneAndHasAGuide() {
        let panes = NookPermission.allCases.map { $0.settingsURL.absoluteString }
        XCTAssertEqual(Set(panes).count, NookPermission.allCases.count)
        XCTAssertTrue(panes.allSatisfy { $0.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") })
        for permission in NookPermission.allCases {
            XCTAssertGreaterThanOrEqual(permission.steps.count, 2, "\(permission) explains how to do it by hand.")
            XCTAssertTrue(permission.steps[0].contains("Privacidad y seguridad"))
            XCTAssertFalse(permission.purpose.isEmpty)
        }
        XCTAssertEqual(NookPermission.allCases.filter(\.essential), [.automation], "Only Terminal control is needed to follow tabs.")
    }

    func testStatesComeFromWhatMacOSReports() {
        XCTAssertEqual(NookPermission.automationState(noErr), .granted)
        XCTAssertEqual(NookPermission.automationState(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(NookPermission.automationState(OSStatus(errAEEventWouldRequireUserConsent)), .notAsked)
        XCTAssertEqual(NookPermission.automationState(OSStatus(procNotFound)), .unknown, "Terminal closed: its permission can't be read.")
        XCTAssertEqual(NookPermission.captureState(.authorized), .granted)
        XCTAssertEqual(NookPermission.captureState(.notDetermined), .notAsked)
        XCTAssertEqual(NookPermission.captureState(.restricted), .denied)
        XCTAssertEqual(NookPermission.speechState(.denied), .denied)
        XCTAssertEqual(NookPermission.speechState(.notDetermined), .notAsked)
    }

    func testAccessibilityResetForgetsOnlyNooksOwnRecord() {
        XCTAssertEqual(DirectKeys.resetArguments(bundle: "dev.nook.mac"), ["reset", "Accessibility", "dev.nook.mac"],
                       "Naming the service and the bundle: a bare reset would clear every app's Accessibility.")
    }
}
