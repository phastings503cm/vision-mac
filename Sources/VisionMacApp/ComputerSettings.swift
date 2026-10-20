import SwiftUI
import AppKit
import ApplicationServices
import VisionHarnessCore

// MARK: - Settings ▸ Computer
//
// How chats see and steer this Mac: on or off, in the background first (the
// person keeps their mouse), how long a chat waits its turn for the real mouse,
// whether each chat is limited to the apps it starts, and the global stop.

struct ComputerSettings: View {
    @Environment(AppModel.self) private var model
    @State private var trusted = AXIsProcessTrusted()
    @State private var canCapture = MacPermissions.screenRecordingAllowed
    @State private var confirmReset: MacPermissions.Service?

    var body: some View {
        @Bindable var config = model.config
        Form {
            Section {
                Toggle("Let chats see and control this Mac", isOn: $config.computerToolsEnabled)
                Text("Screenshots, window lists and accessibility trees, and pressing buttons, typing and clicking in other apps. Each chat asks once before it looks and once before it controls anything.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Your mouse and keyboard") {
                Toggle("Work in the background when possible", isOn: Binding(
                    get: { config.machineControl.preferBackground },
                    set: { config.machineControl.preferBackground = $0; model.transport.machineControlSettingsChanged() }))
                Text("Buttons, menus, checkboxes and text fields are worked through Accessibility, and keys are sent to the app itself — the app can stay behind your windows and your pointer never moves, so several chats can work at once. Only a drag, a click on something with no control behind it (a game, a canvas) or typing that needs the app in front uses the real mouse and keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("When a chat needs the real mouse, wait up to", selection: Binding(
                    get: { config.machineControl.waitTimeout },
                    set: { config.machineControl.waitTimeout = $0; model.transport.machineControlSettingsChanged() })) {
                    ForEach(MachineControlOptions.waitChoices, id: \.self) { seconds in
                        Text(Self.label(seconds)).tag(seconds)
                    }
                }
                Text("One chat at a time has the real mouse and keyboard; the others wait their turn and say so (\u{201C}Waiting for the mouse\u{201D}). Nothing is clicked or typed while you are using the mouse or keyboard yourself, and your pointer is put back after a click.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Which apps a chat may control") {
                Toggle("Only the apps a chat starts, and ones you allow", isOn: Binding(
                    get: { config.machineControl.restrictToOwnApps },
                    set: { config.machineControl.restrictToOwnApps = $0; model.transport.machineControlSettingsChanged() }))
                Text("A chat may then control the programs it started (process_start) and their windows; reaching for any other app asks you first, and your answer holds for that app in that chat. In a chat, /control only [apps] and /control any change it for that chat.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Stopping") {
                LabeledContent("Stop all AI control, from any app") {
                    Text(GlobalStopHotKey.display)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                }
                Text("Stops every chat that is using or waiting for the Mac, gives the mouse and keyboard back, and makes those chats ask again before they control anything. ⌘. stops the chat in front of you.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permission") {
                permissionRow(.screenRecording, allowed: canCapture)
                Text(canCapture
                     ? "\(AppIdentity.name) can take screenshots and watch windows."
                     : "Without it, screenshots come back empty. System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording ▸ \(AppIdentity.name).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionRow(.accessibility, allowed: trusted)
                Text(trusted
                     ? "\(AppIdentity.name) can press controls and read apps' accessibility trees directly."
                     : "Without it, \(AppIdentity.name) can only use the real mouse and keyboard, and ui_action can't work. System Settings ▸ Privacy & Security ▸ Accessibility ▸ \(AppIdentity.name).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Switch already on in System Settings but still refused? That entry belongs to an older build of \(AppIdentity.name) (builds before 0.16.8 had a new signature with every update). Reset removes it and reopens \(AppIdentity.name); allow it once more when macOS asks, and later updates keep it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .confirmationDialog(confirmReset.map { "Reset \($0.title) for \(AppIdentity.name)?" } ?? "",
                            isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
                            titleVisibility: .visible) {
            if let service = confirmReset {
                Button("Reset and Reopen") { MacPermissions.resetAndRelaunch(service) }
                Button("Cancel", role: .cancel) { confirmReset = nil }
            }
        } message: {
            Text("\(AppIdentity.name) quits and reopens. The next time it needs this permission, macOS asks again — choose Allow, then Quit & Reopen.")
        }
    }

    @ViewBuilder
    private func permissionRow(_ service: MacPermissions.Service, allowed: Bool) -> some View {
        LabeledContent(service.title) {
            HStack(spacing: 8) {
                Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(allowed ? .green : .orange)
                Text(allowed ? "Allowed" : "Not allowed yet")
                if !allowed {
                    Button("Open Settings…") { MacPermissions.openSettings(service) }
                }
                Button("Reset…") { confirmReset = service }
            }
        }
    }

    private func refreshPermissions() {
        trusted = AXIsProcessTrusted()
        canCapture = MacPermissions.screenRecordingAllowed
    }

    static func label(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds" : seconds.truncatingRemainder(dividingBy: 60) == 0
            ? "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")" : "\(Int(seconds)) seconds"
    }

}
