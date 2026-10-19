import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Each chat has its own model: two projects open with prompts running in both use two servers; a new chat starts
/// with its project's last choice; the choice survives a relaunch; retries, queue tasks and subagents stay on it.
@MainActor
final class ChatRouteTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-chatroute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { seen, _ in .slow(0.25, "Answered by \(seen.host).") }
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.test/v1", model: "stub-model")
    private let kimi = ProviderProfile(kind: .openAICompat, name: "Kimi", baseURL: "http://kimi.test/v1", model: "stub-model")

    private func makeTransport(suite: String? = nil) -> AppTransport {
        let name = suite ?? "vision-chatroute-tests-\(UUID().uuidString)"
        defaultsSuite = name
        let config = AppConfig(defaults: UserDefaults(suiteName: name)!, secrets: MemorySecretStore())
        if config.providers.allSatisfy({ $0.routeID != spark.routeID }) {
            config.providers = [spark, kimi]
            config.activeRoute = spark.routeID
        }
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        t.goalErrorBackoff = { _ in 0.02 }
        transport = t
        return t
    }

    private func project(_ name: String) -> String {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func waitForReply(_ vm: SessionVM, _ reply: String, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(vm.entries.contains { $0.message?.role == .assistant && $0.message?.text.contains(reply) == true } && !vm.running) {
            if Date() > deadline { return XCTFail("no reply “\(reply)” in \(vm.title)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The hosts that requests carrying `text` went to.
    private func hosts(for text: String) -> Set<String> {
        Set(FakeModelServer.seen.filter { $0.allUserText.contains(text) }.map(\.host))
    }

    // MARK: Two chats at once

    /// Patrick's report: two projects, a prompt in each, and the model chosen in one chat was used by both. Now
    /// each chat's requests go to its own server, while both run at the same time — and changing the primary
    /// mid-run moves neither.
    func testTwoChatsInTwoProjectsRunAtOnceOnTheirOwnServers() async throws {
        let t = makeTransport()
        let first = t.newSession(cwd: project("app-one"))
        let second = t.newSession(cwd: project("app-two"))
        t.setRoute(kimi.routeID, for: second)
        XCTAssertEqual(first.routeID, spark.routeID)
        XCTAssertEqual(second.routeID, kimi.routeID)
        XCTAssertEqual(t.config.activeRoute, spark.routeID, "choosing in a chat doesn't change the primary")

        t.send("question for app one", sessionID: first.id)
        t.send("question for app two", sessionID: second.id)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(first.running && second.running, "both chats are working at the same time")
        // The user makes Kimi the primary while both run.
        t.config.makeMain(kimi.routeID)
        try await waitForReply(first, "Answered by spark.test.")
        try await waitForReply(second, "Answered by kimi.test.")
        XCTAssertEqual(hosts(for: "question for app one"), ["spark.test"])
        XCTAssertEqual(hosts(for: "question for app two"), ["kimi.test"])

        // And the next turn in the first chat still goes to its own server, not the new primary.
        t.send("follow-up for app one", sessionID: first.id)
        let deadline = Date().addingTimeInterval(15)
        while first.running || first.entries.filter({ $0.message?.role == .assistant && $0.message?.text.contains("Answered by") == true }).count < 2 {
            if Date() > deadline { return XCTFail("no second reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(hosts(for: "follow-up for app one"), ["spark.test"])
        XCTAssertEqual(t.modelID(for: first), "stub-model")
        XCTAssertEqual(t.chatRouteID(first), spark.routeID)
    }

    // MARK: Where a chat's model comes from

    func testANewChatStartsWithItsProjectsLastChoice() {
        let t = makeTransport()
        let two = project("app-two")
        let chat = t.newSession(cwd: two)
        t.setRoute(kimi.routeID, for: chat)
        t.setThinking(.high, for: chat)

        let next = t.newSession(cwd: two)
        XCTAssertEqual(next.routeID, kimi.routeID, "the project's last choice")
        XCTAssertEqual(next.thinking, .high)
        let elsewhere = t.newSession(cwd: project("app-one"))
        XCTAssertEqual(elsewhere.routeID, spark.routeID, "another project starts on the primary")
        XCTAssertNil(elsewhere.thinking)
        let plain = t.newSession(cwd: nil)
        XCTAssertEqual(plain.routeID, spark.routeID)
    }

    func testTheChoiceIsKeptWithTheConversation() throws {
        let suite = "vision-chatroute-tests-\(UUID().uuidString)"
        let t = makeTransport(suite: suite)
        let chat = t.newSession(cwd: project("app-two"))
        t.setRoute(kimi.routeID, for: chat)
        t.setThinking(.low, for: chat)
        t.log.flush(wait: true)

        // A relaunch: the same settings and log, a new transport.
        let relaunched = makeTransport(suite: suite)
        let back = try XCTUnwrap(relaunched.sessions.first { $0.id == chat.id })
        XCTAssertEqual(back.routeID, kimi.routeID)
        XCTAssertEqual(back.thinking, .low)
        XCTAssertEqual(relaunched.config.lastChoice(forProject: project("app-two"))?.route, kimi.routeID)
    }

    /// A chat whose route was removed falls back to the primary and says so, instead of failing.
    func testAChatWhoseModelWasRemovedTakesThePrimary() async throws {
        let t = makeTransport()
        let chat = t.newSession(cwd: project("app-two"))
        t.setRoute(kimi.routeID, for: chat)
        t.config.providers.removeAll { $0.routeID == kimi.routeID }
        t.send("still there?", sessionID: chat.id)
        try await waitForReply(chat, "Answered by spark.test.")
        XCTAssertEqual(chat.routeID, spark.routeID)
        XCTAssertTrue(chat.entries.contains { $0.message?.text.contains("no longer set up") == true })
    }

    // MARK: Background paths

    /// A model call that fails is retried on the chat's own server — not on whatever the primary is by then.
    func testARetryStaysOnTheChatsOwnServer() async throws {
        let t = makeTransport()
        FakeModelServer.reset { seen, index in
            index == 1 ? .http(503, #"{"error":"overloaded"}"#) : .text("Answered by \(seen.host).")
        }
        let chat = t.newSession(cwd: project("app-two"))
        t.setRoute(kimi.routeID, for: chat)
        t.send("retry me", sessionID: chat.id)
        try await waitForReply(chat, "Answered by kimi.test.")
        XCTAssertEqual(FakeModelServer.seen.filter { $0.allUserText.contains("retry me") }.count, 2)
        XCTAssertEqual(hosts(for: "retry me"), ["kimi.test"])
    }

    /// A queue task queued from a chat runs on that chat's model.
    func testAQueueTaskRunsOnTheModelOfTheChatThatQueuedIt() async throws {
        let t = makeTransport()
        FakeModelServer.reset { seen, _ in .text("Done on \(seen.host).\nGOAL_COMPLETE") }
        t.adoptProject(URL(fileURLWithPath: project("app-two")))
        let task = t.queueAdd("Tidy the README")
        t.queue.setRoute(id: task.id, routeID: kimi.routeID, thinking: ThinkingLevel.low.rawValue)
        t.startQueue()
        let deadline = Date().addingTimeInterval(15)
        while t.queueRunning || t.queue.task(task.id)?.status != .complete {
            if Date() > deadline { return XCTFail("queue didn't finish: \(String(describing: t.queue.task(task.id)?.status))") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let chat = try XCTUnwrap(t.sessions.first { $0.id == t.queue.task(task.id)?.sessionID })
        XCTAssertEqual(chat.routeID, kimi.routeID)
        XCTAssertEqual(chat.thinking, .low)
        XCTAssertEqual(hosts(for: "Tidy the README"), ["kimi.test"])
    }

    /// The fleet's "primary" for a chat's subagents is that chat's own server.
    func testAChatsSubagentsFallBackToItsOwnServer() async throws {
        let t = makeTransport()
        let chat = t.newSession(cwd: project("app-two"))
        t.setRoute(kimi.routeID, for: chat)
        let home = t.fleetHome(for: chat, profile: try XCTUnwrap(t.chatRoute(chat)))
        XCTAssertEqual(home.id, kimi.routeID)
        let lease = try await t.fleet.acquire(home: home)
        defer { lease.release() }
        XCTAssertEqual(lease.label, "Kimi")
        XCTAssertEqual((lease.target.client as? any ProviderClient)?.profile.baseURL, "http://kimi.test/v1")
        // Without a chat, the primary.
        let primary = try await t.fleet.acquire()
        defer { primary.release() }
        XCTAssertEqual(primary.label, "Spark")
    }

    // MARK: The thinking picker

    /// Only the levels the chat's model takes: Kimi K2.7 Code none, GLM-5.3 Low/High/Max.
    func testTheThinkingLevelsFollowTheChatsModel() {
        let t = makeTransport()
        let k27 = ProviderProfile(kind: .openAICompat, name: "Moonshot", baseURL: "https://api.moonshot.ai/v1", model: "kimi-k2.7-code")
        let glm = ProviderProfile(kind: .openAICompat, name: "GLM Coding Plan", baseURL: "https://api.z.ai/api/coding/paas/v4", model: "glm-5.3")
        t.config.providers += [k27, glm]
        let a = t.newSession(cwd: nil), b = t.newSession(cwd: nil), c = t.newSession(cwd: nil)
        t.setRoute(k27.routeID, for: a)
        t.setRoute(glm.routeID, for: b)
        XCTAssertEqual(t.requestRules(for: a)?.thinkingLevels, [])
        XCTAssertEqual(t.requestRules(for: a)?.alwaysThinks, true)
        XCTAssertEqual(t.requestRules(for: b)?.thinkingLevels, [.low, .high, .max])
        XCTAssertEqual(t.requestRules(for: c)?.thinkingLevels, ThinkingLevel.allCases, "a server you run takes them all")
        XCTAssertEqual(AppTransport.thinkingCaveat(.medium, rules: t.requestRules(for: b)),
                       " This model offers Low, High, Max, so it gets High.")
    }
}
