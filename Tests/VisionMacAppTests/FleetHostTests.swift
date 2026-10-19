import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The whole path, with two fake model servers: routes → fleet → engine → `agent` tool → the right server.
/// The fake serves every host; the requests it saw say which server each one went to.
@MainActor
final class FleetHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("vision-fleet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private func route(_ name: String, host: String, worker: Bool = false, parallel: Int? = nil) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host)/v1", model: "stub-model",
                        subagentWorker: worker ? true : nil, subagentParallel: parallel)
    }

    private func makeTransport(_ routes: [ProviderProfile]) -> AppTransport {
        defaultsSuite = "vision-fleet-tests-\(UUID().uuidString)"
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

    private func project() -> URL {
        let url = dir.appendingPathComponent("project", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Sends one chat message and waits for the main model's closing words; returns the tool results it saw.
    /// (`send` starts the run asynchronously, so "not running" is true before it begins — wait for the reply.)
    private func ask(_ text: String, until reply: String = "All done.") async throws -> (vm: SessionVM, toolResults: [String]) {
        transport.adoptProject(project())
        let vm = transport.newSession(cwd: project().path)
        transport.send(text, sessionID: vm.id)
        try await waitUntil("the chat to finish") {
            !vm.running && vm.entries.contains { entry in
                if case .message(let block) = entry.kind { return block.role == .assistant && block.text.contains(reply) }
                return false
            }
        }
        let results = FakeModelServer.seen.flatMap { $0.messages }.filter { $0["role"] == "tool" }.compactMap { $0["content"] }
        return (vm, results)
    }

    private func hosts() -> [String] { FakeModelServer.seen.map(\.host) }

    /// The main model asks for one subagent; every other request just answers.
    private nonisolated static func delegating(mainHost: String, task: String = "count the files",
                                   subagentAnswer: String = "There are 3 files.") -> @Sendable (SeenRequest, Int) -> FakeReply {
        { seen, _ in
            if seen.host == mainHost, seen.lastUser == "please scan", seen.fresh {
                return .toolCall("agent", #"{"description":"scan","prompt":"\#(task)"}"#)
            }
            if seen.lastUser == task { return .text(subagentAnswer) }
            return .text("All done.")
        }
    }

    // MARK: Tests

    func testASubagentRunsOnTheWorkerAndTheReportNamesTheServer() async throws {
        _ = makeTransport([route("Main", host: "main.test"), route("Worker", host: "worker.test", worker: true)])
        FakeModelServer.reset(Self.delegating(mainHost: "main.test"))
        let (_, results) = try await ask("please scan")

        let subagentRequests = FakeModelServer.seen.filter { $0.lastUser == "count the files" }
        XCTAssertEqual(subagentRequests.map(\.host), ["worker.test"], "the side task went to the other machine")
        XCTAssertFalse(hosts().filter { $0 == "main.test" }.isEmpty, "and the chat stayed on the main one")
        XCTAssertTrue(results.contains { $0.contains("Subagent 'scan' finished") && $0.contains("on worker") }, "the report names the server by its handle: \(results)")
    }

    func testWithoutAWorkerTheSubagentSharesTheMainServerAndTheReportDoesNotNameOne() async throws {
        _ = makeTransport([route("Main", host: "main.test")])
        FakeModelServer.reset(Self.delegating(mainHost: "main.test"))
        let (_, results) = try await ask("please scan")

        XCTAssertEqual(Set(hosts()), ["main.test"])
        XCTAssertTrue(results.contains { $0.contains("Subagent 'scan' finished") && !$0.contains(" on Main") }, "\(results)")
    }

    func testAWorkerThatIsDownHandsItsTaskToTheMainServer() async throws {
        _ = makeTransport([route("Main", host: "main.test"), route("Worker", host: "worker.test", worker: true)])
        FakeModelServer.reset { seen, _ in
            if seen.host == "worker.test", seen.lastUser == "count the files" { return .http(503, "overloaded") }
            return Self.delegating(mainHost: "main.test")(seen, 0)
        }
        let (_, results) = try await ask("please scan")

        XCTAssertTrue(hosts().contains("worker.test"), "it tried the worker first")
        XCTAssertTrue(FakeModelServer.seen.contains { $0.host == "main.test" && $0.lastUser == "count the files" },
                      "and then did the work on the main server")
        XCTAssertTrue(results.contains { $0.contains("Subagent 'scan' finished") && $0.contains("on primary") && $0.contains("1 server failure") },
                      "the report says where it ran and that a server failed on the way: \(results)")
        let fleet = transport.fleet.snapshot()
        XCTAssertEqual(fleet.first { $0.label == "Worker" }?.healthy, false, "the dead worker is skipped for a while")
    }

    /// The main route's temperature, output limit and thinking level stay on the main route: a worker that has
    /// none of its own sends none (a Kimi or GLM server that rejects them would answer 400 and the subagent would end
    /// up elsewhere). The chat's subagent list says the model and route it really ran on.
    func testASubagentOnAWorkerSendsTheWorkersSettingsNotTheMainRoutes() async throws {
        var main = route("Main", host: "main.test")
        main.temperature = 0.7
        main.maxOutputTokens = 30_000
        var worker = route("Kimi", host: "worker.test", worker: true)
        worker.model = "stub-model"
        _ = makeTransport([main, worker])
        FakeModelServer.reset(Self.delegating(mainHost: "main.test"))
        transport.adoptProject(project())
        let vm = transport.newSession(cwd: project().path)
        vm.thinking = .high
        transport.send("please scan", sessionID: vm.id)
        try await waitUntil("the chat to finish") {
            !vm.running && vm.entries.contains { $0.message?.role == .assistant && $0.message?.text.contains("All done.") == true }
        }
        let mainRequest = try XCTUnwrap(FakeModelServer.seen.first { $0.host == "main.test" })
        XCTAssertEqual(mainRequest.temperature, 0.7)
        XCTAssertEqual(mainRequest.maxTokens, 30_000)
        XCTAssertTrue(mainRequest.reasoning, "the chat thinks hard on its own route")
        let sub = try XCTUnwrap(FakeModelServer.seen.first { $0.host == "worker.test" && $0.lastUser == "count the files" })
        XCTAssertNil(sub.temperature, "not the main route's 0.7")
        XCTAssertNil(sub.maxTokens, "not the main route's 30,000")
        XCTAssertFalse(sub.reasoning, "not the chat's thinking level")
        try await waitUntil("the roster to land") { vm.agentRuns.first?.route != nil }
        let run = try XCTUnwrap(vm.agentRuns.first)
        XCTAssertEqual(run.route, "Kimi")
        XCTAssertEqual(run.model, "stub-model")
        XCTAssertEqual(run.placementLabel, "stub-model on Kimi")
    }

    /// A hosted API's key may not be allowed to list models; that is not "down". A server you run yourself that lists
    /// nothing is.
    func testOnlySelfHostedWorkersMustListTheirModels() {
        let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8000/v1", model: "qwen")
        let kimi = ProviderProfile(kind: .openAICompat, name: "Kimi", baseURL: "https://api.kimi.com/coding/v1", model: "kimi-for-coding")
        let zai = ProviderProfile(kind: .openAICompat, name: "GLM", baseURL: "https://api.z.ai/api/coding/paas/v4", model: "glm-5.3")
        let unnamed = ProviderProfile(kind: .openAICompat, name: "X", baseURL: "https://openrouter.ai/api/v1", model: "")
        XCTAssertTrue(AppTransport.workerNeedsModelList(spark))
        XCTAssertFalse(AppTransport.workerNeedsModelList(kimi))
        XCTAssertFalse(AppTransport.workerNeedsModelList(zai))
        XCTAssertTrue(AppTransport.workerNeedsModelList(unnamed), "with no model named there is nothing to trust")
    }

    func testMakingAnotherRouteThePrimarySendsANewChatThere() async throws {
        let t = makeTransport([route("Alpha", host: "alpha.test"), route("Beta", host: "beta.test", worker: true)])
        FakeModelServer.reset { _, _ in .text("hello") }
        t.config.makeMain(route("Beta", host: "beta.test").routeID)
        t.resetRouteCache()
        _ = try await ask("hi", until: "hello")
        XCTAssertEqual(Set(hosts().filter { $0 != "" }), ["beta.test"], "new chats start on Beta now: \(hosts())")
        XCTAssertEqual(t.config.enlistedRoutes.map(\.name), ["Beta"], "no flag changed")
        XCTAssertEqual(t.fleet.snapshot().map(\.label), ["Beta"])
    }

    /// The catalogue of subagent servers is in the agent tool's description — once, with what the primary needs to
    /// choose — and no longer in the system prompt.
    func testTheMainAgentIsToldAboutItsSubagentServersInTheAgentTool() async throws {
        var spark = route("Spark 2", host: "spark2.local", worker: true)
        spark.baseURL = "http://192.168.1.43:8002/v1"
        _ = makeTransport([route("Main", host: "main.test"), spark, route("Kimi Code", host: "kimi.test", worker: true)])
        FakeModelServer.reset { _, _ in .text("All done.") }
        let (vm, _) = try await ask("hi")
        let system = try XCTUnwrap(FakeModelServer.seen.first?.messages.first { $0["role"] == "system" }?["content"])
        XCTAssertFalse(system.contains("--- Subagent servers ---"), "said once, in the tool")
        let agent = try XCTUnwrap(transport.engines[vm.id]?.registry.specs.first { $0.name == "agent" })
        XCTAssertTrue(agent.description.contains("\n\nSubagent servers — set `server` to one of these ids"), agent.description)
        XCTAssertTrue(agent.description.contains("\n- spark-2: OpenAI-compatible server · stub-model ·"), agent.description)
        XCTAssertTrue(agent.description.contains(" · private · local · "), agent.description)
        XCTAssertTrue(agent.description.contains("\n- kimi-code: OpenAI-compatible server · stub-model ·"), agent.description)
        XCTAssertTrue(agent.description.contains("\n- primary: this chat's own model (stub-model on Main) · used when the others are busy"))
        XCTAssertTrue(agent.description.contains("Servers that aren't private must not receive sensitive data."))
        XCTAssertEqual(transport.fleet.servers.map(\.isPrivate), [true, false], "Kimi Code is an online service")
    }

    func testWithoutSubagentServersThereIsNoCatalogue() async throws {
        _ = makeTransport([route("Main", host: "main.test")])
        FakeModelServer.reset { _, _ in .text("All done.") }
        let (vm, _) = try await ask("hi")
        let agent = try XCTUnwrap(transport.engines[vm.id]?.registry.specs.first { $0.name == "agent" })
        XCTAssertFalse(agent.description.contains("Subagent servers"))
    }

    func testTheFleetFollowsTheRoutesAsTheyChange() {
        let t = makeTransport([route("Main", host: "main.test"), route("Other", host: "other.test")])
        XCTAssertTrue(t.fleet.snapshot().isEmpty, "nothing enlisted: subagents run on their chat's own model")
        t.config.setSubagentWorker(route("Other", host: "other.test").routeID, true)
        t.config.setSubagentParallel(route("Other", host: "other.test").routeID, 5)
        XCTAssertEqual(t.fleet.snapshot().map(\.label), ["Other"])
        XCTAssertEqual(t.fleet.snapshot().last?.maxParallel, 5)
        XCTAssertEqual(t.fleet.servers.first?.handle, "other")
        t.config.subagentsUsePrimary = false
        XCTAssertFalse(t.fleet.usePrimaryWhenWorkersBusy)
    }
}
