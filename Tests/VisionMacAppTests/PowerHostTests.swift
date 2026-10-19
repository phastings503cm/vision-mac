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

    func testASensitiveChatsConversationGoesOnlyWhereItsTurnsMay() async throws {
        let t = makeTransport([kimi], shield: true)
        FakeModelServer.reset { _, _ in .text("first answer") }
        let vm = t.newSession(cwd: dir.path)
        t.send("hello", sessionID: vm.id)
        try await waitIdle(vm)
        // Marked Sensitive, and the shield turned off: Kimi may no longer see this chat.
        t.config.shield.enabled = false
        t.setSensitive(true, for: vm)
        FakeModelServer.reset { _, _ in .text("must not be asked") }

        t.send("/compact", sessionID: vm.id)
        try await waitIdle(vm, replies: 2)
        XCTAssertTrue(FakeModelServer.seen.isEmpty, "/compact sent nothing")
        let compactError = vm.entries.last { $0.message?.role == .error }?.message?.text ?? ""
        XCTAssertTrue(compactError.hasPrefix("This chat is Sensitive. Kimi Code is an online service"), compactError)

        t.send("/skill new a helper for these notes", sessionID: vm.id)
        try await waitIdle(vm, replies: 3)
        XCTAssertTrue(FakeModelServer.seen.isEmpty, "/skill new sent nothing")
        XCTAssertTrue(vm.entries.last { $0.message?.role == .error }?.message?.text.hasPrefix("This chat is Sensitive.") == true)

        // Skills ▸ New Skill "from this chat".
        do {
            _ = try await t.generateSkill(goal: "notes", from: vm)
            XCTFail("refused")
        } catch let refusal as SensitivityRefusal {
            XCTAssertTrue(refusal.message.hasPrefix("This chat is Sensitive."))
        }
        XCTAssertTrue(FakeModelServer.seen.isEmpty)

        // The composer keeps them like a prompt (they send the conversation); other commands still run.
        XCTAssertTrue(ChatView.goesToModel("/compact"))
        XCTAssertTrue(ChatView.goesToModel("/compact keep the decisions"))
        XCTAssertTrue(ChatView.goesToModel("/skill new notes helper"))
        XCTAssertFalse(ChatView.goesToModel("/skill off"))
        XCTAssertFalse(ChatView.goesToModel("/rewind"))
    }

    func testWorkMadeFromASensitiveChatStaysSensitive() async throws {
        let t = makeTransport([spark])
        let vm = t.newSession(cwd: dir.path)
        t.setSensitive(true, for: vm)
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("queue_task", #"{"title":"Follow up","details":"check the notes"}"#) : .text("Queued.")
        }
        t.send("queue a follow-up", sessionID: vm.id)
        try await waitIdle(vm)
        let task = try XCTUnwrap(t.queue.tasks.last)
        XCTAssertEqual(task.title, "Follow up")
        XCTAssertEqual(task.sensitive, true, "its chat will be Sensitive too")
        let json = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
        XCTAssertTrue(json.contains(#""sensitive":true"#), json)
        XCTAssertEqual(try JSONDecoder().decode(QueueTask.self, from: Data(json.utf8)).sensitive, true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(QueueTask(title: "plain")), as: UTF8.self).contains("sensitive"))

        // A chat sent to Guardian or exported as JSON says so; one coming back (from Guardian, a JSON file or
        // another tool) is Sensitive when it was, or when its project starts chats Sensitive.
        let doc = try XCTUnwrap(t.exportDocument(vm.id))
        XCTAssertTrue(doc.sensitive)
        XCTAssertTrue(String(decoding: ChatExport.guardianPayload(doc), as: UTF8.self).contains(#""sensitive":true"#))
        XCTAssertTrue(String(decoding: ChatExport.json(doc), as: UTF8.self).contains(#""sensitive" : true"#))
        var plainDoc = doc
        plainDoc.sensitive = false
        XCTAssertFalse(String(decoding: ChatExport.guardianPayload(plainDoc), as: UTF8.self).contains(#""sensitive":"#))
        t.setProjectStartsSensitive(true, path: dir.path)
        func payload(_ id: String, cwd: String?, sensitive: Bool?) throws -> Data {
            var chat: [String: Any] = ["id": id, "title": id, "rows": [["kind": "user", "text": "hi", "isError": false, "at": 0]]]
            if let cwd { chat["cwd"] = cwd }
            if let sensitive { chat["sensitive"] = sensitive }
            return try JSONSerialization.data(withJSONObject: chat)
        }
        var chats: [ImportedChat] = []
        for (id, cwd, sensitive) in [("g-project", dir.path, nil), ("g-marked", nil, true), ("g-plain", nil, nil)] as [(String, String?, Bool?)] {
            chats.append(try XCTUnwrap(GuardianChatImport.harnessChat(id: id, title: id, updatedAt: Date(),
                                                                       payload: try payload(id, cwd: cwd, sensitive: sensitive))))
        }
        let other = ImportedChat(source: .claudeCode, sourceID: "cc-1", title: "From Claude Code", createdAt: Date(),
                                 updatedAt: Date(), cwd: dir.path,
                                 rows: [ImportedRow(kind: .user, text: "hi", at: Date())])
        XCTAssertEqual(t.importChats(chats + [other]).imported.count, 4)
        XCTAssertEqual(t.sessions.first { $0.id == "g-project" }?.sensitive, true, "its project starts chats Sensitive")
        XCTAssertEqual(t.sessions.first { $0.id == "g-marked" }?.sensitive, true)
        XCTAssertEqual(t.sessions.first { $0.id == "g-plain" }?.sensitive, false)
        XCTAssertEqual(t.sessions.first { $0.title == "From Claude Code" }?.sensitive, true, "its project starts chats Sensitive")
    }

    // MARK: Rewind

    /// One turn that rewrites notes.txt ("old" → "new"); its record.
    private func writeTurn(_ t: AppTransport, _ vm: SessionVM) async throws -> TurnCheckpointRecord {
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("old\n".utf8).write(to: notes)
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("write_file", #"{"file_path":"notes.txt","content":"new\n"}"#) : .text("Done.")
        }
        t.send("update the notes", sessionID: vm.id)
        try await waitIdle(vm)
        let deadline = Date().addingTimeInterval(5)
        while vm.checkpoint == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return try XCTUnwrap(vm.checkpoint)
    }

    func testARunningTurnCantBeRewoundUnderTheAgent() async throws {
        let t = makeTransport([spark])
        let vm = t.newSession(cwd: dir.path)
        let record = try await writeTurn(t, vm)
        let notes = dir.appendingPathComponent("notes.txt")
        // As if that turn were still running.
        vm.running = true
        vm.currentPromptID = record.id
        defer { vm.running = false; vm.currentPromptID = nil }
        XCTAssertEqual(t.rewindBlocked(turnID: record.id, in: vm), "Wait for the turn to finish (or stop it) to rewind it.")
        XCTAssertNil(t.rewindBlocked(turnID: "another-turn", in: vm))
        let result = t.rewind(t.rewindPlan(record), includeConflicts: false, in: vm)
        XCTAssertEqual(result.changedCount, 0)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "new\n", "nothing was put back under the agent")
        XCTAssertEqual(vm.entries.last?.message?.text, "Wait for the turn to finish (or stop it) to rewind it.")
        t.rewindRequest = nil
        t.rewindCommand("1", vm: vm)
        XCTAssertNil(t.rewindRequest, "/rewind 1 doesn't open the confirmation either")
        vm.running = false
        XCTAssertNil(t.rewindBlocked(turnID: record.id, in: vm))
    }

    func testTheLatestTurnsChangesComeBackAfterARelaunch() async throws {
        let t = makeTransport([spark])
        let vm = t.newSession(cwd: dir.path)
        let record = try await writeTurn(t, vm)
        XCTAssertEqual(t.checkpoint(chatID: vm.id, turnID: record.id)?.changedFiles.count, 1, "a prompt's results find it")
        t.log.flush(wait: true)

        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        let relaunched = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                      queueFile: dir.appendingPathComponent("task-queue.json"),
                                      skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                      vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        defer { relaunched.stopAll() }
        let reopened = try XCTUnwrap(relaunched.sessions.first { $0.id == vm.id })
        relaunched.hydrate(reopened)   // (the launch may already have loaded it: the selected chat)
        XCTAssertEqual(reopened.checkpoint?.id, record.id, "the card under the latest turn is back")
        XCTAssertEqual(reopened.checkpoint?.changedFiles.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["notes.txt"])
    }

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
