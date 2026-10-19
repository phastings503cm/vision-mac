import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Imported chats in the app, end to end: stored with their own times and where they came from, never twice, carried
/// on by a model that sees the earlier conversation (tool calls as written text), exported (Markdown, JSON, Guardian)
/// and found by the search across chats.
@MainActor
final class ChatImportHostTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-importhost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Carrying on.") }
        suite = "vision-importhost-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.workspaceWrite.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private let t0 = Date(timeIntervalSince1970: 1_787_000_000)

    private func project() -> URL {
        let url = dir.appendingPathComponent("demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeCodeChat(id: String = "s1", cwd: String? = nil) -> ImportedChat {
        ImportedChat(source: .claudeCode, sourceID: id, title: "Login fixes", createdAt: t0, updatedAt: t0.addingTimeInterval(30),
                     cwd: cwd, model: "claude-fable-5", rows: [
                        ImportedRow(kind: .user, text: "Fix the login page", at: t0),
                        ImportedRow(kind: .tool, text: "PASS login.test.ts", toolName: "Bash", argSummary: "npm test",
                                    output: "PASS login.test.ts\n3 passed", at: t0.addingTimeInterval(10)),
                        ImportedRow(kind: .assistant, text: "The login tests pass.", at: t0.addingTimeInterval(30)),
                     ], subagents: 1)
    }

    private func waitUntil(_ seconds: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Importing

    func testAnImportedChatArrivesWithItsTimesAndOriginAndOnlyOnce() throws {
        let folder = project().path
        let result = transport.importChats([claudeCodeChat(cwd: folder)], now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(result.imported.count, 1)
        XCTAssertEqual(result.summary, "Imported 1 chat (2 messages).")
        var big = ChatImportResult()
        big.imported = Array(repeating: "x", count: 12)
        big.messages = 1_840
        big.alreadyHere = 3
        big.failed = ["a"]
        XCTAssertEqual(big.summary, "Imported 12 chats (1,840 messages). 3 were already in Vision. 1 couldn't be read.",
                       "Vision for Windows' words")
        XCTAssertEqual(ChatImportResult().summary, "Nothing new to import.")
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == result.imported[0] })
        XCTAssertEqual(vm.title, "Login fixes")
        XCTAssertEqual(vm.cwd, folder, "its folder is on this Mac, so it opens as a chat in that project")
        XCTAssertEqual(vm.importSource, .claudeCode)
        XCTAssertEqual(vm.updatedAt, t0.addingTimeInterval(30), "it sorts by when it was last used, not when it was imported")
        XCTAssertNil(vm.routeID, "no model chosen yet: it takes the primary, and any model can be picked")

        let stored = transport.log.peekItems(vm.id)
        XCTAssertEqual(stored.map(\.kind), ["notice", "user", "tool", "assistant"])
        XCTAssertTrue(stored[0].text?.hasPrefix("Imported from Claude Code on ") == true)
        XCTAssertTrue(stored[0].text?.contains(", in \(folder).") == true)
        XCTAssertTrue(stored[0].text?.contains("It ran 1 subagent whose own transcripts stayed in Claude Code.") == true)
        XCTAssertEqual(stored.map(\.at), [t0, t0, t0.addingTimeInterval(10), t0.addingTimeInterval(30)])
        XCTAssertEqual(stored[2].toolName, "Bash")
        XCTAssertEqual(stored[2].output, "PASS login.test.ts\n3 passed")
        let session = try XCTUnwrap(transport.log.session(vm.id))
        XCTAssertEqual(session.source, "claude-code")
        XCTAssertEqual(session.sourceID, "s1")
        XCTAssertEqual(session.importedAt, t0.addingTimeInterval(86_400))

        let again = transport.importChats([claudeCodeChat(cwd: folder), claudeCodeChat(id: "s2")])
        XCTAssertEqual(again.alreadyHere, 1, "the same session twice is one chat")
        XCTAssertEqual(again.imported.count, 1, "a new session comes in")
        XCTAssertEqual(again.summary, "Imported 1 chat (2 messages). 1 was already in Vision.")
        let candidate = ChatImportCandidate(claudeCodeChat(), location: .loaded)
        XCTAssertTrue(transport.isAlreadyImported(candidate))

        // A chat the person deleted can be brought in again.
        transport.deleteSession(vm.id)
        XCTAssertFalse(transport.isAlreadyImported(candidate))
        XCTAssertEqual(transport.importChats([claudeCodeChat()]).imported.count, 1)
    }

    func testAFolderThatIsNotOnThisMacOrOpenClawsWorkspaceMakesAChatWithoutAProject() throws {
        let away = transport.importChats([claudeCodeChat(cwd: "/Users/nobody/gone")])
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == away.imported.first })
        XCTAssertNil(vm.cwd)
        XCTAssertTrue(vm.isPlain)
        XCTAssertTrue(transport.log.peekItems(vm.id).first?.text?.contains("(not on this computer, so it continues without a project)") == true)

        var openClaw = claudeCodeChat(id: "oc1", cwd: project().path)
        openClaw.source = .openClaw
        let claw = transport.importChats([openClaw])
        XCTAssertNil(transport.sessions.first { $0.id == claw.imported.first }?.cwd, "OpenClaw's own workspace isn't a project")
    }

    func testAnyModelCarriesOnFromAnImportedChat() async throws {
        let id = try XCTUnwrap(transport.importChats([claudeCodeChat()]).imported.first)
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == id })
        transport.hydrate(vm)
        transport.send("carry on", sessionID: id)
        try await waitUntil { vm.entries.contains { $0.message?.role == .assistant && $0.message?.text == "Carrying on." } && !vm.running }

        // What the model was sent: the imported conversation, tool calls as written text, then the new prompt.
        let request = try XCTUnwrap(FakeModelServer.seen.last)
        let turns = request.messages.filter { $0["role"] != "system" }
        XCTAssertEqual(turns.map { $0["role"] ?? "" }, ["user", "assistant", "assistant", "user"])
        XCTAssertEqual(turns[0]["content"], "Fix the login page")
        XCTAssertEqual(turns[1]["content"], "[earlier tool activity]\n- Bash(npm test) → PASS login.test.ts")
        XCTAssertEqual(turns[2]["content"], "The login tests pass.")
        XCTAssertEqual(turns[3]["content"], "carry on")
        XCTAssertFalse(request.messages.contains { $0["content"]?.contains("Imported from Claude Code") == true },
                       "the import notice is for the person, not the model")
        XCTAssertEqual(transport.log.peekItems(id).last?.text, "Carrying on.")
    }

    func testAVisionChatComesBackAsItselfWithItsOwnID() throws {
        let doc = ChatExportDocument(id: "kept-chat-1", title: "Kept", updatedAt: t0, rows: [
            ImportedRow(kind: .user, text: "hello", at: t0), ImportedRow(kind: .assistant, text: "hi", at: t0.addingTimeInterval(1)),
        ])
        let chat = try XCTUnwrap(GuardianChatImport.harnessChat(id: "kept-chat-1", title: "Kept", updatedAt: t0,
                                                                payload: ChatExport.guardianPayload(doc)))
        let result = transport.importChats([chat])
        XCTAssertEqual(result.imported, ["kept-chat-1"])
        XCTAssertEqual(transport.log.peekItems("kept-chat-1").map(\.kind), ["user", "assistant"], "no import notice: it is a Vision chat")
        XCTAssertNil(transport.log.session("kept-chat-1")?.source)
        let candidate = GuardianChatImport.harnessCandidate(id: "kept-chat-1", title: "Kept", updatedAt: t0)
        XCTAssertTrue(transport.isAlreadyImported(candidate), "a chat with that id is already here")
        XCTAssertEqual(transport.importChats([chat]).alreadyHere, 1)
    }

    // MARK: Export

    func testExportReadsTheStoredChatEvenWhenItIsNotOpen() throws {
        let id = try XCTUnwrap(transport.importChats([claudeCodeChat()]).imported.first)
        let doc = try XCTUnwrap(transport.exportDocument(id))
        XCTAssertEqual(doc.rows.map(\.kind), [.notice, .user, .tool, .assistant])
        XCTAssertEqual(doc.source, .claudeCode)
        XCTAssertEqual(doc.sourceID, "s1")
        let markdown = String(decoding: ChatExportActions.data(.markdown, for: doc), as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix("# Login fixes\n"))
        XCTAssertTrue(markdown.contains("**Tool: Bash** `npm test` → PASS login.test.ts"))
        let json = ChatExportActions.data(.json, for: doc)
        let back = try XCTUnwrap(ExportFileChats.parse(json, name: "x.json").loaded.values.first)
        XCTAssertEqual(back.rows, doc.rows)
        XCTAssertEqual(back.key, ChatImportKey.make(.claudeCode, "s1"), "imported again elsewhere, it is still that session")
    }

    func testSendToGuardianPostsAPayloadThatAnOlderVisionCanRestore() async throws {
        final class Wire: @unchecked Sendable {
            private let lock = NSLock()
            private var requests: [URLRequest] = []
            private var bodies: [String: Data] = [:]
            func add(_ request: URLRequest, key: String, body: Data) {
                lock.lock(); requests.append(request); bodies[key] = body; lock.unlock()
            }
            func body(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return bodies[key] }
            func request(path: String) -> URLRequest? {
                lock.lock(); defer { lock.unlock() }; return requests.first { $0.url?.path == path }
            }
        }
        let wire = Wire()
        let routes: [String: (Int, String)] = [
            "POST /api/auth/login": (200, #"{"ok":true,"token":"sess-1","session":{"userId":"u1","email":"pat@503cm.com","name":"Pat"}}"#),
            "GET /api/harness/me": (200, #"{"user":{"id":"u1","email":"pat@503cm.com"},"orgs":[],"modules":[],"permissions":[],"limits":[]}"#),
            "GET /api/harness/limits": (200, #"{"limits":[]}"#),
            "GET /api/harness/vault": (200, #"{"secrets":[]}"#),
            "GET /api/harness/eta": (200, #"{"byKind":{}}"#),
        ]
        let service = GuardianService(appSupport: dir, secrets: MemorySecretStore()) { request in
            let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
            wire.add(request, key: key, body: request.httpBody ?? Data(HostFixtures.bodyText(request).utf8))
            if key.hasPrefix("POST /api/harness/chats/") {
                return GuardianHTTPResponse(data: Data(#"{"ok":true}"#.utf8), status: 200, headers: [:])
            }
            let (status, body) = routes[key] ?? (404, #"{"error":"not found"}"#)
            return GuardianHTTPResponse(data: Data(body.utf8), status: status, headers: [:])
        }
        service.transport = transport
        let id = try XCTUnwrap(transport.importChats([claudeCodeChat()]).imported.first)
        let doc = try XCTUnwrap(transport.exportDocument(id))
        let refused = await service.sendChat(doc)
        XCTAssertEqual(refused, "Sign in to Guardian first (Settings ▸ Guardian).")

        let ok = await service.signIn(address: GuardianService.defaultURL, email: "pat@503cm.com", password: "pw")
        XCTAssertTrue(ok, service.lastError ?? "")
        let sent = await service.sendChat(doc)
        XCTAssertEqual(sent, "Sent “Login fixes” to Guardian.")
        let body = wire.body("POST /api/harness/chats/\(id)")
        let request = wire.request(path: "/api/harness/chats/\(id)")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sess-1")
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
        XCTAssertEqual(envelope["title"] as? String, "Login fixes")
        XCTAssertNotNil(envelope["updatedAt"] as? String)
        let payload = Data(try XCTUnwrap(envelope["payload"] as? String).utf8)
        // Vision for macOS 0.15's restore: a plain JSONDecoder.
        struct Legacy: Decodable {
            var id: String
            var rows: [Row]
            struct Row: Decodable { var kind: String; var text: String?; var isError: Bool; var at: Date }
        }
        let legacy = try JSONDecoder().decode(Legacy.self, from: payload)
        XCTAssertEqual(legacy.id, id)
        XCTAssertEqual(legacy.rows.map(\.kind), ["notice", "user", "tool", "assistant"])
        XCTAssertEqual(legacy.rows[1].at, t0)

    }

    func testAGuardianChatGuardianImportedFromSomethingAlreadyHereShowsAsImported() throws {
        let imported = try XCTUnwrap(transport.importChats([claudeCodeChat()]).imported.first)
        let local = transport.newSession(cwd: nil)
        func guardianChat(_ source: String, _ external: String) -> ChatImportCandidate {
            GuardianChatSummary(id: "g-\(external)", title: "t", updatedAt: t0, importSource: source, externalID: external).candidate
        }
        XCTAssertTrue(transport.isAlreadyImported(guardianChat("claude-code", "s1")), "the Claude Code session imported here")
        XCTAssertTrue(transport.isAlreadyImported(guardianChat("vision-mac", local.id)), "a chat made here, sent, then opened in Guardian")
        XCTAssertTrue(transport.isAlreadyImported(guardianChat("vision-windows", imported)))
        XCTAssertFalse(transport.isAlreadyImported(guardianChat("claude-code", "s9")))
        XCTAssertFalse(transport.isAlreadyImported(guardianChat("vision", "gone-chat")))
        XCTAssertFalse(transport.isAlreadyImported(GuardianChatSummary(id: "g", title: "t", updatedAt: t0).candidate))
    }

    // MARK: Search

    func testTheSearchFindsImportedAndLocalChatsAndJumpsToTheRow() async throws {
        let imported = try XCTUnwrap(transport.importChats([claudeCodeChat()]).imported.first)
        let local = transport.newSession(cwd: nil)
        transport.renameSession(local.id, to: "Groceries")
        transport.send("buy oat milk and login cookies", sessionID: local.id)
        try await waitUntil { !local.running && local.entries.contains { $0.message?.role == .assistant } }

        let search = ChatSearchModel()
        search.transport = transport
        search.debounce = 0
        search.query = "login"
        await search.run()
        XCTAssertEqual(Set(search.hits.map(\.chatID)), [imported, local.id])
        XCTAssertEqual(search.hits.first?.chatID, imported, "its title holds the word")

        search.scope = .madeHere
        await search.run()
        XCTAssertEqual(search.hits.map(\.chatID), [local.id])
        search.scope = .source(.claudeCode)
        search.query = "npm"
        await search.run()
        let hit = try XCTUnwrap(search.hits.first)
        XCTAssertEqual(hit.chatID, imported)
        XCTAssertEqual(hit.kind, "tool")
        XCTAssertEqual(hit.snippet, "Bash npm test PASS login.test.ts")

        // The hit's row in the chat once it is open.
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == imported })
        transport.hydrate(vm)
        let entryID = try XCTUnwrap(transport.entryID(forSearchHit: hit, in: vm))
        let entry = try XCTUnwrap(vm.entries.first { $0.id == entryID })
        guard case .tool(let tool) = entry.kind else { return XCTFail("the tool card") }
        XCTAssertEqual(tool.name, "Bash")

        // A chat changed since the index was built is read again.
        transport.renameSession(local.id, to: "Errands npm")
        await search.run()
        search.scope = .all
        await search.run()
        XCTAssertTrue(search.hits.contains { $0.chatID == local.id && $0.titleMatch })
        search.clear()
        XCTAssertTrue(search.hits.isEmpty)
    }

    // MARK: The sheet's model

    func testTheSheetKeepsTheFullerCopyWhenAnIDRepeats() {
        let model = ChatImportModel(transport: transport, guardian: nil,
                                    scanner: ChatImportScanner(home: dir, environment: [:], cacheFolder: nil))
        let stale = ChatImportCandidate(source: .claudeCode, sourceID: "s", title: "t", updatedAt: t0, messageCount: 857,
                                        location: .file(dir.appendingPathComponent("worktree/s.jsonl")))
        var full = stale
        full.updatedAt = t0.addingTimeInterval(900)
        full.messageCount = 876
        full.location = .file(dir.appendingPathComponent("main/s.jsonl"))
        XCTAssertEqual(model.merge([full, stale]), [full.id])
        XCTAssertEqual(model.candidates, [full], "newest first in, older second: the older one doesn't replace it")
        XCTAssertEqual(model.merge([stale]), [], "nor does it later")
        XCTAssertEqual(model.candidates, [full])
        model.merge([ChatImportCandidate(source: .codex, sourceID: "c", title: "c", updatedAt: t0, messageCount: 1, location: .loaded)])
        XCTAssertEqual(model.candidates.map(\.messageCount), [876, 1])
    }

    func testTheImportSheetOffersWhatIsNewAndImportsWhatWasTicked() async throws {
        let session = [
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"Deploy the site"},"timestamp":"2026-10-01T10:00:00.000Z","cwd":"/nowhere","sessionId":"cc-1","entrypoint":"claude-desktop"}"#,
            #"{"type":"assistant","isSidechain":false,"message":{"model":"m","role":"assistant","content":[{"type":"text","text":"Deployed."}]},"timestamp":"2026-10-01T10:01:00.000Z","sessionId":"cc-1"}"#,
        ].joined(separator: "\n")
        let scripted = session.replacingOccurrences(of: "cc-1", with: "cc-2").replacingOccurrences(of: "claude-desktop", with: "sdk-cli")
            .replacingOccurrences(of: "Deploy the site", with: "Nightly check")
        for (name, text) in [("cc-1", session), ("cc-2", scripted)] {
            let url = dir.appendingPathComponent(".claude/projects/-nowhere/\(name).jsonl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let model = ChatImportModel(transport: transport, guardian: nil,
                                    scanner: ChatImportScanner(home: dir, environment: [:], cacheFolder: dir.appendingPathComponent("cache")))
        model.lookEverywhere()
        try await waitUntil { model.states[.claudeCode] == .ready(2) }
        XCTAssertEqual(model.states[.codex], .missing)
        XCTAssertEqual(model.states[.guardian], .signedOut)
        XCTAssertEqual(model.visible.map(\.title), ["Deploy the site"], "scripted runs are hidden until asked for")
        XCTAssertEqual(model.automatedCount, 1)
        model.showAutomated = true
        XCTAssertEqual(model.visible.count, 2)
        model.filter = "nightly"
        XCTAssertEqual(model.visible.map(\.title), ["Nightly check"])
        model.filter = ""
        model.showAutomated = false

        // The same session as Guardian imported it: ticked with it, it comes in once, from Claude Code itself.
        let viaGuardian = GuardianChatSummary(id: "g-cc-1", title: "Deploy the site", updatedAt: t0,
                                              importSource: "claude-code", externalID: "cc-1").candidate
        model.merge([viaGuardian])
        model.selectAllShown()
        XCTAssertEqual(model.pickedCount, 2)
        model.importPicked()
        try await waitUntil { !model.importing && model.result != nil }
        XCTAssertEqual(model.result, "Imported 1 chat (2 messages).", "the Guardian copy wasn't fetched (no Guardian here) or imported")
        XCTAssertTrue(model.isImported(viaGuardian))
        XCTAssertTrue(transport.sessions.contains { $0.title == "Deploy the site" && $0.importSource == .claudeCode })
        let first = try XCTUnwrap(model.visible.first)
        XCTAssertTrue(model.isImported(first), "shown as imported; it can't be ticked again")
        model.toggle(first)
        XCTAssertEqual(model.pickedCount, 0)

        // A second look offers only what is new.
        model.lookEverywhere()
        try await waitUntil { model.states[.claudeCode] == .ready(2) }
        XCTAssertEqual(model.candidates.filter { !model.isImported($0) }.map(\.title), ["Nightly check"])
    }
}
