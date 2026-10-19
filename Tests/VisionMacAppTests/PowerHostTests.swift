import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The harness end to end for the "power" features: a Sensitive chat refuses a model it may not use, and a turn's
/// file changes can be rewound (and the model hears about it).
@MainActor
final class PowerHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-power-\(UUID().uuidString)", isDirectory: true)
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

    private func makeTransport(_ routes: [ProviderProfile], shield: Bool = true) -> AppTransport {
        defaultsSuite = "vision-power-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = routes[0].routeID
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        config.shield.enabled = shield
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport = t
        return t
    }

    private func waitIdle(_ vm: SessionVM, replies: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(15)
        while vm.running || transport.runTasks[vm.id] != nil
                || vm.entries.filter({ $0.message?.role == .assistant || $0.message?.role == .error }).count < replies {
            if Date() > deadline { return XCTFail("the turn didn't finish") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private let kimi = ProviderProfile(kind: .openAICompat, name: "Kimi Code", baseURL: "https://kimi.test/v1", model: "stub-model")
    private let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "stub-model")

    // MARK: Sensitive

    func testASensitiveChatRefusesAnOnlineModelWhileTheShieldIsOffAndSendsNothing() async throws {
        let t = makeTransport([kimi], shield: false)
        FakeModelServer.reset { _, _ in .text("should not be asked") }
        let vm = t.newSession(cwd: dir.path)
        XCTAssertFalse(vm.sensitive)
        t.setSensitive(true, for: vm)
        XCTAssertEqual(t.sensitivityAdmission(for: vm)?.code, "refused")
        XCTAssertTrue(t.sensitivityHeader(for: vm)?.contains("can't be used in this chat") == true)
        XCTAssertFalse(t.sensitivityAllows(kimi, in: vm))
        XCTAssertTrue(t.sensitivityAllows(spark, in: vm))

        t.send("summarise the patient notes", sessionID: vm.id)
        try await waitIdle(vm)
        XCTAssertTrue(FakeModelServer.seen.isEmpty, "nothing left the Mac")
        let error = vm.entries.last { $0.message?.role == .error }?.message?.text ?? ""
        XCTAssertTrue(error.hasPrefix("This chat is Sensitive. Kimi Code is an online service"), error)
        XCTAssertFalse(vm.entries.contains { $0.message?.role == .user }, "the prompt never went out")

        // The shield on: the same model is allowed, masked.
        t.config.shield.enabled = true
        XCTAssertEqual(t.sensitivityAdmission(for: vm), .masked)
        FakeModelServer.reset { _, _ in .text("ok") }
        t.send("hello", sessionID: vm.id)
        try await waitIdle(vm, replies: 2)
        XCTAssertEqual(FakeModelServer.seen.count, 1)
        XCTAssertTrue(FakeModelServer.seen[0].messages.first?["content"]?.contains("--- Sensitive chat ---") == true,
                      "the model is told the chat is Sensitive")
    }

    func testAProjectCanStartItsChatsSensitiveAndTheChatRemembers() async throws {
        let t = makeTransport([spark])
        t.setProjectStartsSensitive(true, path: dir.path)
        let vm = t.newSession(cwd: dir.path)
        XCTAssertTrue(vm.sensitive)
        XCTAssertEqual(t.sensitivityAdmission(for: vm), .privateRoute(why: "your own hardware"))
        XCTAssertEqual(t.log.list().first { $0.id == vm.id }?.sensitive, true)
        let plain = t.newSession(cwd: nil)
        XCTAssertFalse(plain.sensitive, "chats without a project have their own default")
        t.sensitiveCommand("off", vm: vm)
        XCTAssertFalse(vm.sensitive)
        XCTAssertNil(t.log.list().first { $0.id == vm.id }?.sensitive)
    }

    func testASensitiveChatFallsOverOnlyToModelsItMayUse() async throws {
        let t = makeTransport([spark, kimi], shield: false)
        t.config.setBackup(kimi.routeID, true)
        XCTAssertEqual(t.backupProfiles(sensitive: false).map(\.name), ["Kimi Code"])
        XCTAssertEqual(t.backupProfiles(sensitive: true).map(\.name), [])
        let vm = t.newSession(cwd: dir.path)
        t.setSensitive(true, for: vm)
        XCTAssertTrue(t.privateSubagentsOnly(vm), "with the shield off, subagents stay on private servers")
    }

    // MARK: Rewind

    func testATurnsFileChangesShowAndRewindAndTheModelIsTold() async throws {
        let t = makeTransport([spark])
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("old\n".utf8).write(to: notes)
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("write_file", #"{"file_path":"notes.txt","content":"new\n"}"#) : .text("Done.")
        }
        let vm = t.newSession(cwd: dir.path)
        t.send("update the notes", sessionID: vm.id)
        try await waitIdle(vm)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "new\n")
        let deadline = Date().addingTimeInterval(5)
        while vm.checkpoint == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let record = try XCTUnwrap(vm.checkpoint)
        XCTAssertEqual(record.title, "update the notes")
        XCTAssertEqual(record.changedFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["notes.txt"])
        let diff = t.diff(record.changedFiles[0])
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)

        t.send("/rewind", sessionID: vm.id)
        XCTAssertTrue(vm.entries.last?.message?.text.hasPrefix("Recent turns that changed files") == true)
        XCTAssertEqual(t.rewindRequest?.chatID, vm.id)

        let result = t.rewind(t.rewindPlan(t.checkpoints(for: vm)[0]), includeConflicts: false, in: vm)
        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "old\n")
        XCTAssertTrue(vm.entries.last?.message?.text.hasPrefix("↺ Rewound “update the notes”: put back 1 file (notes.txt)") == true)
        XCTAssertNotNil(vm.checkpoint?.rewoundAt)

        FakeModelServer.reset { _, _ in .text("ok") }
        t.send("what now?", sessionID: vm.id)
        try await waitIdle(vm, replies: 2)
        let sent = try XCTUnwrap(FakeModelServer.seen.last)
        XCTAssertTrue(sent.lastUser.hasPrefix("[Automatic message: the user rewound the file changes of an earlier turn (“update the notes”)"))
        XCTAssertTrue(sent.lastUser.hasSuffix("what now?"))
        XCTAssertEqual(vm.entries.last { $0.message?.role == .user }?.message?.text, "what now?", "the chat shows what was typed")
    }

    func testTheCommandsParse() {
        XCTAssertEqual(SlashCommand.parse("/sensitive"), .sensitive(nil))
        XCTAssertEqual(SlashCommand.parse("/sensitive on"), .sensitive("on"))
        XCTAssertEqual(SlashCommand.parse("/rewind 2"), .rewind("2"))
        XCTAssertEqual(SlashCommand.parse("/checkpoints"), .rewind(nil))
        XCTAssertEqual(SlashCommand.parse("/mcp reload"), .mcp("reload"))
    }

    func testTheMCPCommandWithNoServersSaysWhereToAddThem() async throws {
        let t = makeTransport([spark])
        let vm = t.newSession(cwd: dir.path)
        t.send("/mcp", sessionID: vm.id)
        XCTAssertTrue(vm.entries.last?.message?.text.hasPrefix("No MCP servers yet") == true)
        XCTAssertTrue(t.discoverMCPImports().isEmpty, "a home with no other apps' settings has nothing to import")
    }
}
