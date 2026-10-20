import AppKit
import CoreGraphics
import VisionHarnessCore

// MARK: - macOS privacy permissions (Screen Recording, Accessibility)
//
// macOS ties a privacy grant to the app's code signature. Builds up to 0.16.7 were ad-hoc signed, so every
// update had a new identity and macOS quietly ignored the old grant even though its switch in System Settings
// still showed on ("Failed to match existing code requirement" in the system log). From 0.16.8 every release is
// signed with the same certificate, so a grant made once keeps working across updates. Reset removes a stale
// entry so macOS asks again — the one-time repair after moving off the ad-hoc builds.

enum MacPermissions {
    enum Service: String, CaseIterable {
        case screenRecording = "ScreenCapture"
        case accessibility = "Accessibility"

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }

        var settingsAnchor: String {
            switch self {
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            }
        }
    }

    /// Whether macOS currently lets this build capture the screen (no prompt is shown).
    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The tccutil arguments that drop this app's entry for `service` (and only this app's).
    static func resetArguments(_ service: Service, bundleID: String = AppIdentity.bundleIdentifier) -> [String] {
        ["reset", service.rawValue, bundleID]
    }

    /// The Terminal command a person can run when the automatic reset can't.
    static func resetCommand(_ service: Service, bundleID: String = AppIdentity.bundleIdentifier) -> String {
        "tccutil " + resetArguments(service, bundleID: bundleID).joined(separator: " ")
    }

    static func openSettings(_ service: Service) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(service.settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Remove this app's entry for `service`, then reopen the app so macOS asks again on first use.
    @MainActor
    static func resetAndRelaunch(_ service: Service) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = resetArguments(service, bundleID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        var ok = false
        do {
            try task.run()
            task.waitUntilExit()
            ok = task.terminationStatus == 0
        } catch {}

        guard ok else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't reset \(service.title) automatically"
            alert.informativeText = """
            In System Settings ▸ Privacy & Security ▸ \(service.title), select \(AppIdentity.name) and remove it with \
            the “–” button, or run this in Terminal, then reopen \(AppIdentity.name):

            \(resetCommand(service, bundleID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier))
            """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { openSettings(service) }
            return
        }
        relaunch()
    }

    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
