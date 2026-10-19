import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Chats at the machine, in the app: /control, the waiting line, the global stop.
@MainActor
final class MachineHostTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-machine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "vision-machine-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
    }

    override func tearDown() async throws {
        transport?.stopAll()
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    func testControlCommandLimitsAndFreesAChat() {
        let vm = transport.newSession(cwd: nil)
        let only = transport.setControlScope(vm, argument: "only Safari, Godot")
        XCTAssertTrue(only.hasPrefix("This chat may control only the apps it starts and godot, safari."), only)
        XCTAssertTrue(transport.machineSeat(for: vm.id, vm: vm).isRestricted)
        let any = transport.setControlScope(vm, argument: "any")
        XCTAssertTrue(any.hasPrefix("This chat may control any app"), any)
        XCTAssertFalse(transport.machineSeat(for: vm.id, vm: vm).isRestricted)
        transport.config.machineControl.restrictToOwnApps = true
        transport.machineControlSettingsChanged()
        XCTAssertFalse(transport.machineSeat(for: vm.id, vm: vm).isRestricted, "/control any outranks the setting")
        _ = transport.setControlScope(vm, argument: "default")
        XCTAssertTrue(transport.machineSeat(for: vm.id, vm: vm).isRestricted)
    }

    func testAWaitingChatSaysSoAndTheGlowNamesWhoHasTheMouse() {
        let a = transport.newSession(cwd: nil), b = transport.newSession(cwd: nil)
        a.title = "Fix the build"
        b.running = true
        transport.controlChanged(ControlSnapshot(holder: ControlHolder(id: a.id, chatID: a.id, label: "Fix the build"),
                                                 waiting: [ControlHolder(id: b.id, chatID: b.id, label: b.title)]))
        XCTAssertEqual(b.activity, "Waiting for the mouse — “Fix the build” is using it. It goes to the next chat when that one is done; ⌃⌥⌘. stops all control.")
        XCTAssertTrue(transport.machineInUse)
        XCTAssertEqual(MachineGlowController.shared.model.text, "Vision AI · “Fix the build” has the mouse and keyboard · 1 waiting · ⌃⌥⌘. stops")
        transport.controlChanged(.idle)
        XCTAssertNil(b.activity, "cleared once it isn't waiting")
        XCTAssertFalse(transport.machineInUse)
    }

    func testTheGlobalStopStopsTheChatsAtTheMachineAndMakesThemAskAgain() {
        let a = transport.newSession(cwd: nil)
        let grants = ComputerGrants()
        grants.grant(.control)
        transport.computerGrants[a.id] = grants
        transport.machineToolStarted("mouse", in: a)
        let stopped = transport.stopMachineControl()
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(grants.has(.control), "it asks again before controlling anything")
        XCTAssertFalse(transport.machineInUse)
    }

    /// A background subagent acting on an app without the real mouse (ui_action) after its chat's turn ended: the glow
    /// lights and names the chat, goes out when the tool is done, and ⌃⌥⌘. stops the chat (and so its background
    /// agents) and takes back the approvals it shares with them.
    func testABackgroundSubagentsMachineWorkLightsTheGlowAndTheGlobalStopReachesIt() async throws {
        let a = transport.newSession(cwd: nil)
        a.title = "Fix the build"
        let grants = ComputerGrants()
        grants.grant(.control)
        transport.computerGrants[a.id] = grants
        let sub = transport.machineSeat(for: a.id, vm: a).child()
        XCTAssertFalse(a.running, "the chat's own turn is over")

        sub.noteToolWork(.started(tool: "ui_action"))
        sub.setActivity(.background(app: "Safari"))
        try await waitUntil { MachineGlowController.shared.model.text == "Vision AI · “Fix the build” is working in Safari — your mouse is free · ⌃⌥⌘. stops" }
        XCTAssertTrue(transport.machineInUse)
        sub.noteToolWork(.finished)
        try await waitUntil { !self.transport.machineInUse }

        sub.noteToolWork(.started(tool: "ui_action"))
        try await waitUntil { self.transport.machineInUse }
        XCTAssertEqual(transport.stopMachineControl(), 1)
        XCTAssertEqual(transport.banner, "Stopped AI control of the Mac in 1 chat. Each asks again before it controls anything.")
        XCTAssertFalse(grants.has(.control), "the chat and its subagents ask again")
        XCTAssertFalse(transport.machineInUse)
        sub.noteToolWork(.ended)   // the stopped subagent's engine ends later: nothing comes back on
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(transport.machineInUse)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition never became true") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
