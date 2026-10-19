import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A plan whose terms allow only interactive use (the Qwen Coding Plan) never works unattended.
@MainActor
final class InteractiveOnlyTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Done.\nGOAL_COMPLETE") }
        defaultsSuite = "vision-interactive-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = [
            ProviderProfile(kind: .openAICompat, name: "Qwen Coding Plan", baseURL: "http://plan.test/v1", model: "stub-model",
                            interactiveOnly: true),
            ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.test/v1", model: "stub-model"),
        ]
        config.activeRoute = config.providers[0].routeID
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.05 })
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private let refusal = "Qwen Coding Plan is for interactive use only under its plan's terms, so the queue won't run on it. Make another model primary for unattended work."

    func testTheQueueWontStartOnIt() {
        transport.queueAdd("Task A")
        transport.startQueue()
        XCTAssertFalse(transport.queueRunning)
        XCTAssertEqual(transport.banner, refusal)
        XCTAssertTrue(FakeModelServer.seen.isEmpty, "nothing was sent")
    }

    func testAGoalWontStartOnItButAnInteractiveChatDoes() async throws {
        let vm = transport.newSession(cwd: dir.path)
        transport.send("/goal build the thing", sessionID: vm.id)
        XCTAssertTrue(vm.entries.contains { $0.message?.text.hasPrefix("Qwen Coding Plan is for interactive use only") == true })
        XCTAssertTrue(FakeModelServer.seen.isEmpty)

        transport.send("hello", sessionID: vm.id)
        let deadline = Date().addingTimeInterval(10)
        while !vm.entries.contains(where: { $0.message?.role == .assistant }) {
            if Date() > deadline { return XCTFail("the chat never answered") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(FakeModelServer.seen.count, 1, "a chat with you is interactive")
    }

    func testWithAnotherPrimaryTheQueueRuns() async throws {
        transport.config.makeMain(transport.config.providers[1].routeID)
        let task = transport.queueAdd("Task A")
        transport.startQueue()
        XCTAssertTrue(transport.queueRunning)
        let deadline = Date().addingTimeInterval(15)
        while transport.queueRunning {
            if Date() > deadline { return XCTFail("the queue never finished") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
    }

    func testUnattendedWorkUsesNoInteractiveOnlyBackupOrSubagentServer() async throws {
        let config = transport.config
        let plan = config.providers[0], spark = config.providers[1]
        config.makeMain(spark.routeID)
        config.setBackup(plan.routeID, true)
        config.setSubagentWorker(plan.routeID, true)
        transport.refreshFleet()

        XCTAssertEqual(transport.backupProfiles().map(\.name), ["Qwen Coding Plan"], "a chat with you may fall back to it")
        XCTAssertTrue(transport.backupProfiles(unattended: true).isEmpty, "unattended work may not")

        let ordinary = try await transport.fleet.acquire()
        XCTAssertEqual(ordinary.label, "Qwen Coding Plan", "a subagent from a chat with you runs on the worker")
        ordinary.release()
        transport.fleet.usePrimaryWhenWorkersBusy = false
        let unattended = try await transport.fleet.acquire(unattended: true)
        XCTAssertEqual(unattended.label, "Spark", "an unattended one keeps off it")
        unattended.release()
    }

    /// Each chat has its own model, so it's the chat's route that matters: when the user marks it interactive-only
    /// while a goal runs, the goal stops (changing the app's primary no longer moves a running chat — see
    /// `ChatRouteTests`).
    func testAGoalStopsWhenItsChatsModelBecomesInteractiveOnly() async throws {
        let config = transport.config
        config.makeMain(config.providers[1].routeID)
        let gate = DispatchSemaphore(value: 0)
        FakeModelServer.reset { _, _ in
            gate.wait()
            return .text("Working on it.")
        }
        let vm = transport.newSession(cwd: dir.path)
        transport.send("/goal build the thing", sessionID: vm.id)
        var deadline = Date().addingTimeInterval(10)
        while FakeModelServer.seen.isEmpty {
            if Date() > deadline { return XCTFail("the goal never started") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // While round 1 runs, the user marks this chat's model (Spark) as interactive-only.
        XCTAssertEqual(vm.routeID, config.providers[1].routeID)
        config.providers[1].interactiveOnly = true
        gate.signal()
        deadline = Date().addingTimeInterval(10)
        while vm.running {
            if Date() > deadline { gate.signal(); return XCTFail("the goal kept going") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(FakeModelServer.seen.count, 1, "no second round on it")
        XCTAssertTrue(vm.entries.contains { $0.message?.text.hasPrefix("Spark is for interactive use only") == true })
    }
}

