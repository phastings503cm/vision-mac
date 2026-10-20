import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Reset drops only Vision's own entry, for the service named — never everyone's (a bare `tccutil reset
/// ScreenCapture` would wipe every app's Screen Recording grant).
final class MacPermissionsTests: XCTestCase {
    func testResetNamesTheServiceAndOnlyThisApp() {
        XCTAssertEqual(MacPermissions.resetArguments(.screenRecording), ["reset", "ScreenCapture", "com.503cm.vision.mac"])
        XCTAssertEqual(MacPermissions.resetArguments(.accessibility), ["reset", "Accessibility", "com.503cm.vision.mac"])
        for service in MacPermissions.Service.allCases {
            XCTAssertEqual(MacPermissions.resetArguments(service).count, 3, "a reset without a bundle id resets every app")
        }
    }

    func testTheFallbackCommandIsTheSameReset() {
        XCTAssertEqual(MacPermissions.resetCommand(.screenRecording, bundleID: "com.503cm.vision.mac"),
                       "tccutil reset ScreenCapture com.503cm.vision.mac")
    }

    func testSettingsAnchorsOpenTheRightPanes() {
        XCTAssertEqual(MacPermissions.Service.screenRecording.settingsAnchor, "Privacy_ScreenCapture")
        XCTAssertEqual(MacPermissions.Service.accessibility.settingsAnchor, "Privacy_Accessibility")
    }
}
