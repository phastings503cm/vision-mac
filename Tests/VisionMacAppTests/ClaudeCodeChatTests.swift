import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A chat on Claude Code end to end: the turn goes to a stand-in `claude` (a real process that records what it was
/// given and prints stream-json), and everything around it — the timeline, the session it resumes, the recap when
/// the chat moves between models, /goal, Stop, a Sensitive chat — is the real harness.
@MainActor
final class ClaudeCodeChatTests: XCTestCase {
    private var dir: URL!
    private var cli: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    private static let flags: Set<String> = [
        "--print", "--output-format", "--input-format", "--verbose", "--include-partial-messages", "--model", "--effort",
        "--permission-mode", "--permission-prompts", "--allowedTools", "--disallowedTools", "--session-id", "--resume",
        "--append-system-prompt", "--add-dir", "--system-prompt", "--tools", "--no-session-persistence",
    ]

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-cc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cli = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try Self.writeFakeCLI(in: cli)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Spark says hi.") }
        defaultsSuite = "vision-cc-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.providers = [
            ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL, model: "sonnet"),
            ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.test/v1", model: "stub-model"),
        ]
        config.activeRoute = config.providers[0].routeID
        config.preset = PermissionPreset.workspaceWrite.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.05 })
        transport.goalErrorBackoff = { _ in 0.05 }
        transport.claudeCode.installOverride = ClaudeCodeInstall(path: cli.appendingPathComponent("claude").path, version: "2.1.299",
                                                                 flags: Self.flags, commands: ["auth"])
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    // MARK: The stand-in CLI

    private static func writeFakeCLI(in folder: URL) throws {
        let script = folder.appendingPathComponent("claude")
        try """
        #!/bin/sh
        d="$(cd "$(dirname "$0")" && pwd)"
        n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
        : > "$d/args-$n"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/args-$n"; done
        cat > "$d/stdin-$n"
        if [ -f "$d/hang" ]; then
          trap 'exit 130' INT
          echo '{"type":"system","subtype":"init","session_id":"S","model":"claude-sonnet-5-5"}'
          sleep 30 >/dev/null 2>&1 &
          wait
          exit 0
        fi
        cat "$d/out-$n" 2>/dev/null || cat "$d/out"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// One turn's stream-json: some text, an Edit of hello.txt, the closing reply, the result.
    private func turn(_ reply: String, session: String = "S1", cost: Double = 0.04) -> String {
        let root = dir.path
        let usage: JSONValue = ["input_tokens": 3, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 900, "output_tokens": 5]
        func assistant(_ id: String, _ block: JSONValue) -> JSONValue {
            ["type": "assistant", "message": ["id": .string(id), "role": "assistant", "model": "claude-sonnet-5-5",
                                              "content": [block], "usage": usage],
             "parent_tool_use_id": nil, "session_id": .string(session)]
        }
        let lines: [JSONValue] = [
            ["type": "system", "subtype": "init", "session_id": .string(session), "model": "claude-sonnet-5-5", "apiKeySource": "none",
             "claude_code_version": "2.1.299", "cwd": .string(root), "tools": ["Edit"], "permissionMode": "acceptEdits"],
            assistant("m1", ["type": "text", "text": "On it."]),
            assistant("m1", ["type": "tool_use", "id": "t1", "name": "Edit",
                             "input": ["file_path": .string(root + "/hello.txt"), "old_string": "helo", "new_string": "hello"]]),
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1",
                                                                      "content": .string("The file \(root)/hello.txt has been updated.")]]],
             "parent_tool_use_id": nil, "session_id": .string(session)],
            assistant("m2", ["type": "text", "text": .string(reply)]),
            ["type": "result", "subtype": "success", "is_error": false, "num_turns": 2, "duration_ms": 3_000,
             "result": .string(reply), "session_id": .string(session), "total_cost_usd": .number(cost),
             "usage": ["input_tokens": 6, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1_800, "output_tokens": 40],
             "permission_denials": []],
        ]
        return lines.map { $0.serialized() }.joined(separator: "\n") + "\n"
    }

    private func setOutput(_ text: String) throws {
        try text.write(to: cli.appendingPathComponent("out"), atomically: true, encoding: .utf8)
    }

    private func args(_ n: Int) throws -> [String] {
        try String(contentsOf: cli.appendingPathComponent("args-\(n)"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func prompt(_ n: Int) throws -> String {
        let data = try Data(contentsOf: cli.appendingPathComponent("stdin-\(n)"))
        return JSONValue(parsing: data)?["message"]?["content"]?.array?.last?["text"]?.string ?? ""
    }

    private func runs() -> Int {
        Int((try? String(contentsOf: cli.appendingPathComponent("count"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
    }

    private func send(_ text: String, to vm: SessionVM) async throws {
        transport.send(text, sessionID: vm.id)
        let deadline = Date().addingTimeInterval(20)
        try await Task.sleep(nanoseconds: 50_000_000)
        while vm.running {
            if Date() > deadline { return XCTFail("the turn never ended") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func texts(_ vm: SessionVM, _ role: MessageBody.Role) -> [String] {
        vm.entries.compactMap { $0.message?.role == role ? $0.message?.text : nil }
    }

    // MARK: Tests

    func testATurnRunsOnClaudeCodeAndTheNextOneResumesIt() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("Done — fixed it.", cost: 0.04))
        try await send("fix the greeting", to: vm)

        XCTAssertEqual(texts(vm, .assistant), ["On it.", "Done — fixed it."])
        XCTAssertEqual(vm.entries.compactMap { $0.tool?.name }, ["edit"])
        XCTAssertEqual(vm.entries.compactMap { $0.tool?.summary }, ["Edited hello.txt"])
        XCTAssertTrue(texts(vm, .notice).contains("Claude Code · claude-sonnet-5-5 · 2 steps · 1,906 in · 40 out · 3s · ≈ $0.04 at API prices (your Claude plan covers it)"),
                      "\(texts(vm, .notice))")
        XCTAssertTrue(texts(vm, .error).isEmpty, "\(texts(vm, .error))")
        XCTAssertEqual(vm.claudeCode?.sessionID, "S1")
        XCTAssertEqual(vm.claudeCode?.started, true)
        XCTAssertEqual(vm.claudeCode?.lastTotalCostUSD, 0.04)
        XCTAssertEqual(transport.log.claudeCode(vm.id), vm.claudeCode, "stored with the chat")
        XCTAssertEqual(vm.contextUsed, 3 + 100 + 900)
        XCTAssertEqual(vm.promptHistory.last?.outcome, .completed)
        XCTAssertEqual(vm.promptHistory.last?.route, "Claude Code")

        let first = try args(1)
        XCTAssertEqual(Array(first.prefix(9)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                                "--include-partial-messages", "--model", "sonnet"])
        let sessionFlag = try XCTUnwrap(first.firstIndex(of: "--session-id"))
        XCTAssertNotNil(UUID(uuidString: first[sessionFlag + 1]), "a new session under an id Vision made")
        XCTAssertTrue(first.joined(separator: " ").contains("--permission-mode acceptEdits"))
        XCTAssertEqual(try prompt(1), "fix the greeting", "a new chat has nothing to recap")

        // The next message continues the same Claude Code session; the cost shown is this turn's share.
        try setOutput(turn("And the farewell too.", cost: 0.07))
        try await send("and the farewell", to: vm)
        let second = try args(2)
        let resume = try XCTUnwrap(second.firstIndex(of: "--resume"))
        XCTAssertEqual(second[resume + 1], "S1")
        XCTAssertFalse(second.contains("--session-id"))
        XCTAssertEqual(try prompt(2), "and the farewell", "the session has seen everything: no recap")
        XCTAssertTrue(texts(vm, .notice).last?.hasSuffix("≈ $0.03 at API prices (your Claude plan covers it)") == true,
                      "\(texts(vm, .notice).last ?? "")")
    }

    func testMovingBetweenClaudeCodeAndAnotherModelKeepsTheConversation() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("Done — fixed it."))
        try await send("fix the greeting", to: vm)

        // On another model, the conversation includes Claude Code's turn and what its tools did.
        transport.setRoute(transport.config.providers[1].routeID, for: vm)
        try await send("what did you change?", to: vm)
        let toSpark = try XCTUnwrap(FakeModelServer.seen.last?.messages)
        XCTAssertTrue(toSpark.contains { $0["role"] == "user" && $0["content"] == "fix the greeting" })
        XCTAssertTrue(toSpark.contains { $0["role"] == "assistant"
            && $0["content"] == "Done — fixed it.\n\n[Claude Code's tool work this turn: Edit hello.txt]" }, "\(toSpark)")
        XCTAssertEqual(texts(vm, .assistant).last, "Spark says hi.")

        // Back on Claude Code: the session resumes, and what it missed goes along first.
        transport.setRoute(transport.config.providers[0].routeID, for: vm)
        try setOutput(turn("You're welcome."))
        try await send("thanks", to: vm)
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume S1"))
        let recap = try prompt(2)
        XCTAssertTrue(recap.hasPrefix("[Earlier in this Vision chat — messages you haven't seen"), recap)
        XCTAssertTrue(recap.contains("Person: what did you change?\n\nAssistant: Spark says hi."), recap)
        XCTAssertFalse(recap.contains("Person: fix the greeting"), "it saw that one itself")
        XCTAssertTrue(recap.hasSuffix("[End of earlier messages. The new message:]\n\nthanks"), recap)
    }

    func testASensitiveChatCantUseClaudeCode() async throws {
        transport.isSensitiveChat = { _ in true }
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("never"))
        try await send("summarise the patient notes", to: vm)
        XCTAssertEqual(runs(), 0, "the claude command never ran")
        XCTAssertTrue(texts(vm, .error).contains(ClaudeCodeTurn.sensitiveRefusal), "\(texts(vm, .error))")
        XCTAssertTrue(texts(vm, .notice).contains("Not delivered to the model: summarise the patient notes"))
        XCTAssertTrue(texts(vm, .user).isEmpty)
    }

    func testNotSignedInSaysHowToSignIn() async throws {
        let vm = transport.newSession(cwd: dir.path)
        // What Claude Code 2.1.299 prints with no sign-in (trimmed to the fields Vision reads).
        try setOutput("""
            {"type":"system","subtype":"init","session_id":"75eaed3b","model":"claude-sonnet-5-5","apiKeySource":"none","claude_code_version":"2.1.299"}
            {"type":"assistant","message":{"id":"x","model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Not logged in · Please run /login"}]},"parent_tool_use_id":null,"session_id":"75eaed3b","error":"authentication_failed","is_api_error_message":true}
            {"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"Not logged in · Please run /login","session_id":"75eaed3b","total_cost_usd":0,"permission_denials":[]}

            """)
        try await send("hello", to: vm)
        XCTAssertTrue(texts(vm, .error).contains { $0.hasPrefix("Claude Code isn't signed in on this Mac. In Terminal, run `claude auth login`") },
                      "\(texts(vm, .error))")
        XCTAssertEqual(vm.claudeCode?.started, false, "nothing to resume")
        XCTAssertTrue(texts(vm, .notice).contains("Not delivered to the model: hello"))
        let firstID = try args(1)[try XCTUnwrap(try args(1).firstIndex(of: "--session-id")) + 1]

        try setOutput(turn("Hi!"))
        try await send("hello again", to: vm)
        let second = try args(2)
        let secondID = second[try XCTUnwrap(second.firstIndex(of: "--session-id")) + 1]
        XCTAssertNotEqual(firstID, secondID, "a fresh session id, so Claude Code never says it is already in use")
        XCTAssertEqual(texts(vm, .assistant).last, "Hi!")
    }

    func testAGoalRunsOneClaudeCodeTurnPerRound() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try turn("Still going.").write(to: cli.appendingPathComponent("out-1"), atomically: true, encoding: .utf8)
        try setOutput(turn("All done.\nGOAL_COMPLETE"))
        try await send("/goal fix every greeting", to: vm)
        XCTAssertEqual(runs(), 2, "two rounds, each one claude -p")
        XCTAssertTrue(try prompt(1).contains("fix every greeting"))
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume S1"), "round 2 continues round 1's session")
        XCTAssertTrue(texts(vm, .notice).contains { $0.hasPrefix("✅ Goal complete after 2 rounds") }, "\(texts(vm, .notice))")
        XCTAssertEqual(vm.promptHistory.last?.source, .goal)
        XCTAssertEqual(vm.promptHistory.last?.outcome, .completed)
    }

    func testStopEndsAClaudeCodeTurn() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try Data().write(to: cli.appendingPathComponent("hang"))
        transport.send("take your time", sessionID: vm.id)
        let started = Date()
        while !FileManager.default.fileExists(atPath: cli.appendingPathComponent("stdin-1").path) {
            if Date().timeIntervalSince(started) > 10 { return XCTFail("the CLI never started") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        transport.stopSession(vm.id)
        while vm.running {
            if Date().timeIntervalSince(started) > 10 { return XCTFail("Stop didn't stop it") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "SIGINT was enough")
        XCTAssertTrue(texts(vm, .notice).contains("Stopped."), "\(texts(vm, .notice))")
        XCTAssertEqual(vm.promptHistory.last?.outcome, .stopped)
    }

    func testAddingClaudeCodeFromTheCard() {
        let config = transport.config
        config.providers = []
        config.activeRoute = nil
        let routes = ClaudeCodeRoutes.add(["sonnet", "opus"], to: config)
        XCTAssertEqual(routes.map(\.routeID), ["Claude Code|sonnet", "Claude Code|opus"])
        XCTAssertEqual(config.activeRoute, "Claude Code|sonnet", "with no primary yet, the first one leads")
        XCTAssertEqual(ClaudeCodeRoutes.add(["opus"], to: config).count, 1)
        XCTAssertEqual(config.providers.count, 2, "adding again doesn't duplicate")
        config.providers[1].subagentWorker = true
        config.providers[1].backup = true
        XCTAssertTrue(config.flaggedWorkers.isEmpty, "Claude Code never serves Vision's subagents")
        XCTAssertTrue(config.backupRoutes.isEmpty, "nor stands in as a backup")
    }
}
