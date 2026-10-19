import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Each chat's own model leads its own subagents: its pool is every route enlisted "Use for subagents" — Guardian's
/// models and Claude Code included — except its own machine and what it may not use. The tool description (and so the
/// prompt cache) changes only when the pool does.
@MainActor
final class SubagentPoolHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("vision-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("All done.") }
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private func route(_ name: String, host: String, worker: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host)/v1", model: "stub-model",
                        subagentWorker: worker ? true : nil)
    }

    private let bedrock = ProviderProfile(kind: .bedrock, name: "Amazon Bedrock", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                          model: "claude-sonnet-5-5", awsProfile: "vision", awsRegion: "us-east-1", subagentWorker: true)

    private func makeTransport(_ routes: [ProviderProfile], defaults suite: String? = nil) -> AppTransport {
        defaultsSuite = suite ?? "vision-pool-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = routes.first?.routeID
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport = t
        return t
    }

    private func chat(on route: ProviderProfile) -> SessionVM {
        let vm = transport.newSession(cwd: dir.path)
        vm.routeID = route.routeID
        return vm
    }

    private func pool(_ vm: SessionVM, unattended: Bool = false) -> SubagentPool {
        transport.subagentPool(for: vm, profile: transport.chatRoute(vm)!, unattended: unattended)
    }

    // MARK: Per chat

    func testTwoChatsOnDifferentModelsEachLeadTheirOwnPool() {
        let sparkA = route("Spark A", host: "192.168.1.40:8002", worker: true)
        let dgx = route("DGX Spark", host: "192.168.1.43:8002", worker: true)
        let t = makeTransport([sparkA, dgx, bedrock])
        XCTAssertEqual(t.fleet.servers.map(\.handle), ["spark-a", "dgx-spark", "amazon-bedrock"], "every enlisted route, the primary too")

        let onA = pool(chat(on: sparkA))
        XCTAssertEqual(onA.entries.map(\.id), ["dgx-spark", "amazon-bedrock", "primary"])
        XCTAssertEqual(onA.primary?.label, "Spark A")
        XCTAssertEqual(onA.dropped.map(\.reason), ["this chat's own machine"])

        let onDGX = pool(chat(on: dgx))
        XCTAssertEqual(onDGX.entries.map(\.id), ["spark-a", "amazon-bedrock", "primary"],
                       "the app's primary is a subagent server for a chat on another model")
        XCTAssertEqual(onDGX.entries.first { $0.id == "amazon-bedrock" }?.isPrivate, true, "Bedrock in your account is private")
        XCTAssertEqual(onDGX.entries.first { $0.id == "spark-a" }?.tier, .local)
    }

    func testASensitiveChatsPoolLeavesOutWhatItMayNotUse() {
        let claude = ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL,
                                     model: "sonnet", subagentWorker: true)
        let t = makeTransport([route("Spark A", host: "192.168.1.40:8002"), claude, route("Kimi", host: "kimi.test", worker: true)])
        let vm = chat(on: t.config.providers[0])
        XCTAssertEqual(pool(vm).workers.map(\.id), ["claude-code", "kimi"])
        vm.sensitive = true
        XCTAssertEqual(pool(vm).workers.map(\.id), ["kimi"], "Claude Code never; an online route only masked")
        t.config.shield.enabled = false
        XCTAssertEqual(pool(vm).workers.map(\.id), [], "shield off: online routes are out too")
        XCTAssertEqual(pool(vm).dropped.map(\.reason), ["not available in a Sensitive chat", "not available in a Sensitive chat"])
    }

    func testAChatOnClaudeCodeHasNoPool() {
        let claude = ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL, model: "sonnet")
        let t = makeTransport([claude, route("Spark", host: "spark.test", worker: true)])
        let vm = chat(on: claude)
        XCTAssertTrue(pool(vm).chatOwnAgent)
        XCTAssertTrue(pool(vm).entries.isEmpty)
        let lines = AppTransport.agentsLines(pool: pool(vm), chatLabel: "Claude Code", chatModel: "sonnet",
                                             status: t.fleet.snapshot(), homeID: claude.routeID)
        XCTAssertEqual(lines, ["This chat runs on Claude Code, which uses its own subagents. Vision's subagent servers serve chats on other models."])
    }

    // MARK: Guardian's models

    func testAGuardianModelTickedInTheMapServesWhileSignedInWithTheTokenOfTheMoment() async throws {
        let suite = "vision-pool-tests-\(UUID().uuidString)"
        let t = makeTransport([route("Spark A", host: "192.168.1.40:8002")], defaults: suite)
        let config = t.config
        config.guardianModelBase = "https://guardian.test/v1"
        config.guardianToken = "token-1"
        config.guardianModels = [GuardianModel(id: "claude-haiku-5-5", contextWindow: 1_000_000)]
        config.setSubagentWorker("Guardian|claude-haiku-5-5", true)
        XCTAssertEqual(config.guardianSubagents, ["claude-haiku-5-5": 0], "kept in the map, not as a route")
        XCTAssertEqual(config.providers.count, 1)
        XCTAssertEqual(t.fleet.servers.map(\.id), ["Guardian|claude-haiku-5-5"])

        let vm = chat(on: config.providers[0])
        let entry = try XCTUnwrap(pool(vm).workers.first)
        XCTAssertEqual(entry.id, "guardian")
        XCTAssertEqual(entry.provider, "Guardian")
        XCTAssertEqual(entry.tier, .org)
        XCTAssertTrue(entry.isPrivate)
        XCTAssertEqual(entry.context, "1M")

        // The sign-in's token is read when a lease is granted, so a new sign-in renews it.
        var target = try await t.resolveWorkerTarget("Guardian|claude-haiku-5-5")
        XCTAssertEqual((target.client as? any ProviderClient)?.profile.apiKey, "token-1")
        config.guardianToken = "token-2"
        target = try await t.resolveWorkerTarget("Guardian|claude-haiku-5-5")
        XCTAssertEqual((target.client as? any ProviderClient)?.profile.apiKey, "token-2")

        // Signed out: Guardian's models leave every pool, and a lease already on its way is a server fault.
        config.guardianToken = nil
        do {
            _ = try await t.resolveWorkerTarget("Guardian|claude-haiku-5-5")
            XCTFail("signed out")
        } catch {
            XCTAssertTrue(AgentFleet.isServerFault(error), "\(error)")
        }
        config.guardianModels = []
        t.refreshFleet()
        XCTAssertTrue(pool(vm).workers.isEmpty)
        XCTAssertTrue(t.fleet.servers.isEmpty)

        // The tick survives a relaunch.
        let reloaded = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore())
        XCTAssertEqual(reloaded.guardianSubagents, ["claude-haiku-5-5": 0])
    }

    // MARK: The prompt cache

    func testTheEngineIsRebuiltWhenThePoolChangesButNotWhenTheLoadDoes() async throws {
        let t = makeTransport([route("Main", host: "main.test"), route("Worker", host: "worker.test", worker: true),
                               route("Spare", host: "spare.test")])
        let vm = t.newSession(cwd: dir.path)
        let home = t.fleetHome(for: vm, profile: t.chatRoute(vm)!)
        try await turn(vm, "one")
        XCTAssertNil(t.engineKeys[vm.id]?.servers.workers.first?.context, "nothing learned about the worker yet")
        // The first lease asks the worker what it serves: the catalogue learns its window once (a real change).
        let probe = try await t.fleet.acquire(FleetRequest(home: home))
        probe.release()
        try await turn(vm, "two")
        let learned = try XCTUnwrap(t.engineKeys[vm.id])
        XCTAssertNotNil(learned.servers.workers.first?.context)

        // A subagent server gets busy: the description doesn't change, so neither does the engine.
        let lease = try await t.fleet.acquire(FleetRequest(home: home))
        try await turn(vm, "three")
        XCTAssertEqual(t.engineKeys[vm.id], learned)
        lease.release()

        // Another route enlisted: a new pool, a new description.
        t.config.setSubagentWorker(route("Spare", host: "spare.test").routeID, true)
        try await turn(vm, "four")
        XCTAssertNotEqual(t.engineKeys[vm.id], learned)
        XCTAssertEqual(t.engineKeys[vm.id]?.servers.workers.map(\.id), ["worker", "spare"])
    }

    private func turn(_ vm: SessionVM, _ text: String) async throws {
        let before = vm.entries.filter { $0.message?.role == .assistant }.count
        transport.send(text, sessionID: vm.id)
        let deadline = Date().addingTimeInterval(15)
        while vm.running || vm.entries.filter({ $0.message?.role == .assistant }).count <= before {
            if Date() > deadline { return XCTFail("no reply to \(text)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Settings carried over

    func testAFlaggedPrimaryFromAnEarlierBuildLoadsUnchanged() throws {
        let suite = "vision-pool-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let old = #"[{"kind":"openAICompat","name":"Spark","baseURL":"http://spark:8002/v1","model":"qwen","subagentWorker":true,"subagentParallel":3},{"kind":"openAICompat","name":"Spark 2","baseURL":"http://spark2:8002/v1","model":"qwen","subagentWorker":true}]"#
        store.set(Data(old.utf8), forKey: "providers.v2")
        store.set("Spark|qwen", forKey: "activeModel.v2")
        store.set(false, forKey: "subagents.usePrimary.v1")
        let config = AppConfig(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(config.enlistedRoutes.map(\.name), ["Spark", "Spark 2"], "the flagged primary now serves other chats too")
        XCTAssertEqual(config.providers.first?.subagentParallel, 3)
        XCTAssertFalse(config.subagentsUsePrimary, "same key: now \"let subagents use the chat's own model too\"")
        XCTAssertTrue(config.guardianSubagents.isEmpty, "the Guardian map starts empty")
    }
}
