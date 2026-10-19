import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A chat on Claude Code end to end: the turn goes to a stand-in `claude` (a real process that records what it was
/// given — arguments, the prompt, its permission answers, a Stop — and prints stream-json), and everything around it —
/// the timeline, the session it carries on, the permission card, the recap when the chat moves between models, /goal,
/// Stop, a Sensitive chat — is the real harness.
@MainActor
final class ClaudeCodeChatTests: XCTestCase {
    private var dir: URL!
    private var cli: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    private static let flags: Set<String> = [
        "--print", "--output-format", "--input-format", "--verbose", "--include-partial-messages", "--model", "--effort",
        "--permission-mode", "--session-id", "--resume", "--append-system-prompt", "--add-dir", "--system-prompt", "--tools",
        "--no-session-persistence",
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
        // Not the person's own ~/.claude.json: no folder is trusted unless a test says so.
        transport.claudeCode.isTrusted = { _, _ in false }
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
        IFS= read -r first; printf '%s\\n' "$first" > "$d/stdin-$n"
        if [ -f "$d/ask-and-die" ]; then
          cat "$d/ask-and-die"; echo "it crashed" >&2; exit 3
        fi
        if [ -f "$d/ask" ]; then
          cat "$d/ask"
          IFS= read -r answer; printf '%s\\n' "$answer" > "$d/answer-$n"
        fi
        if [ -f "$d/hang" ]; then
          echo '{"type":"system","subtype":"init","session_id":"S","model":"claude-sonnet-5-5"}'
          while IFS= read -r line; do
            case "$line" in *interrupt*)
              printf '%s\\n' "$line" > "$d/interrupt-$n"
              echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","session_id":"S","num_turns":1,"terminal_reason":"aborted_streaming"}'
              exit 0;;
            esac
          done
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
             "claude_code_version": "2.1.299", "cwd": .string(root), "tools": ["Edit"], "permissionMode": "default"],
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
             "modelUsage": ["claude-sonnet-5-5": ["contextWindow": 1_000_000, "costUSD": .number(cost)]],
             "permission_denials": []],
        ]
        return lines.map { $0.serialized() }.joined(separator: "\n") + "\n"
    }

    private func setOutput(_ text: String) throws {
        try text.write(to: cli.appendingPathComponent("out"), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: cli.appendingPathComponent(name), encoding: .utf8)
    }

    private func args(_ n: Int) throws -> [String] { try read("args-\(n)").split(separator: "\n").map(String.init) }

    private func prompt(_ n: Int) throws -> String {
        JSONValue(parsing: try read("stdin-\(n)"))?["message"]?["content"]?.array?.first?["text"]?.string ?? ""
    }

    private func runs() -> Int {
        Int(((try? read("count")) ?? "0").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func waitWhileRunning(_ vm: SessionVM, seconds: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        try await Task.sleep(nanoseconds: 50_000_000)
        while vm.running {
            if Date() > deadline { return XCTFail("the turn never ended") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func send(_ text: String, to vm: SessionVM) async throws {
        transport.send(text, sessionID: vm.id)
        try await waitWhileRunning(vm)
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
        XCTAssertTrue(texts(vm, .notice).contains("Claude Code: 2 steps · 1,906 tokens in (1,800 cached) · 40 out · about $0.04 at API prices — covered by your Claude plan."),
                      "\(texts(vm, .notice))")
        XCTAssertTrue(texts(vm, .error).isEmpty, "\(texts(vm, .error))")
        let stored = transport.log.claudeSession(vm.id)
        XCTAssertEqual(stored.session, "S1", "stored with the chat")
        XCTAssertEqual(stored.cost, 0.04)
        XCTAssertNotNil(stored.syncedAt)
        XCTAssertEqual(vm.contextUsed, 3 + 100 + 900)
        XCTAssertEqual(transport.contextLimit(for: vm), 1_000_000, "the window the result reported")
        XCTAssertEqual(transport.turnRoute[vm.id]?.model, "claude-sonnet-5-5")
        XCTAssertEqual(vm.promptHistory.last?.outcome, .completed)
        XCTAssertEqual(vm.promptHistory.last?.route, "Claude Code")

        let first = try args(1)
        XCTAssertEqual(Array(first.prefix(13)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                                 "--include-partial-messages", "--model", "sonnet", "--permission-mode", "default",
                                                 "--permission-prompt-tool", "stdio"])
        let sessionFlag = try XCTUnwrap(first.firstIndex(of: "--session-id"))
        XCTAssertNotNil(UUID(uuidString: first[sessionFlag + 1]), "a new session under an id Vision made")
        XCTAssertEqual(first[first.firstIndex(of: "--append-system-prompt")! + 1], ClaudeCodeTurn.systemNote)
        XCTAssertEqual(try prompt(1), "fix the greeting", "a new chat has nothing to recap")

        // The next message carries on the same Claude Code session; the cost shown is this turn's share.
        try setOutput(turn("And the farewell too.", cost: 0.07))
        try await send("and the farewell", to: vm)
        let second = try args(2)
        XCTAssertEqual(second[try XCTUnwrap(second.firstIndex(of: "--resume")) + 1], "S1")
        XCTAssertFalse(second.contains("--session-id"))
        XCTAssertEqual(try prompt(2), "and the farewell", "the session has seen everything: no recap")
        XCTAssertTrue(texts(vm, .notice).last?.hasSuffix("about $0.03 at API prices — covered by your Claude plan.") == true,
                      "\(texts(vm, .notice).last ?? "")")
    }

    func testAPermissionQuestionIsAskedOnTheChatsCard() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try (#"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"toolu_q"}}"#
             + "\n").write(to: cli.appendingPathComponent("ask"), atomically: true, encoding: .utf8)
        try setOutput(turn("Cleaned."))
        transport.send("clean the build", sessionID: vm.id)
        let deadline = Date().addingTimeInterval(10)
        while vm.pendingGates.isEmpty {
            if Date() > deadline { return XCTFail("no permission card") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let gate = try XCTUnwrap(vm.pendingGates.first)
        XCTAssertEqual(gate.name, "run_shell_command")
        XCTAssertEqual(gate.detail, "Run command: rm -rf build")
        transport.answerGate(sessionID: vm.id, gateID: gate.id, allow: true)
        try await waitWhileRunning(vm)
        XCTAssertEqual(JSONValue(parsing: try read("answer-1")),
                       ["type": "control_response", "response": ["subtype": "success", "request_id": "req-1",
                        "response": ["behavior": "allow", "updatedInput": ["command": "rm -rf build"], "toolUseID": "toolu_q"]]])
        XCTAssertEqual(texts(vm, .assistant).last, "Cleaned.")

        // A read-only command goes ahead without a card; a declined one tells Claude so.
        try (#"{"type":"control_request","request_id":"req-2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_r"}}"#
             + "\n").write(to: cli.appendingPathComponent("ask"), atomically: true, encoding: .utf8)
        try await send("list it", to: vm)
        XCTAssertEqual(JSONValue(parsing: try read("answer-2"))?["response"]?["response"]?["behavior"], "allow")

        try (#"{"type":"control_request","request_id":"req-3","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/etc/hosts"},"tool_use_id":"toolu_s"}}"#
             + "\n").write(to: cli.appendingPathComponent("ask"), atomically: true, encoding: .utf8)
        transport.send("edit hosts", sessionID: vm.id)
        while vm.pendingGates.isEmpty {
            if Date() > deadline.addingTimeInterval(10) { return XCTFail("no permission card") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vm.pendingGates.first?.detail, "Write outside the project: /etc/hosts")
        transport.answerGate(sessionID: vm.id, gateID: vm.pendingGates[0].id, allow: false)
        try await waitWhileRunning(vm)
        XCTAssertEqual(JSONValue(parsing: try read("answer-3"))?["response"]?["response"],
                       ["behavior": "deny", "message": .string(ClaudeCodePermissions.declined), "toolUseID": "toolu_s"])
    }

    func testMovingBetweenClaudeCodeAndAnotherModelKeepsTheConversation() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("Done — fixed it."))
        try await send("fix the greeting", to: vm)

        // On another model, the conversation is rebuilt from the rows, Claude Code's turn and its tool work included.
        transport.setRoute(transport.config.providers[1].routeID, for: vm)
        try await send("what did you change?", to: vm)
        let toSpark = try XCTUnwrap(FakeModelServer.seen.last?.messages)
        XCTAssertTrue(toSpark.contains { $0["role"] == "user" && $0["content"] == "fix the greeting" }, "\(toSpark)")
        XCTAssertTrue(toSpark.contains { $0["role"] == "assistant" && $0["content"] == "Done — fixed it." }, "\(toSpark)")
        XCTAssertTrue(toSpark.contains { $0["role"] == "assistant" && ($0["content"] ?? "").contains("[earlier tool activity]") }, "\(toSpark)")
        XCTAssertEqual(texts(vm, .assistant).last, "Spark says hi.")

        // Back on Claude Code: the session carries on, and what it missed goes along first.
        transport.setRoute(transport.config.providers[0].routeID, for: vm)
        try setOutput(turn("You're welcome."))
        try await send("thanks", to: vm)
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume S1"))
        let recap = try prompt(2)
        XCTAssertTrue(recap.hasPrefix(ClaudeCodeRecap.header), recap)
        XCTAssertTrue(recap.contains("Person: what did you change?\n\nAssistant: Spark says hi."), recap)
        XCTAssertFalse(recap.contains("fix the greeting"), "it saw that one itself")
        XCTAssertTrue(recap.hasSuffix(ClaudeCodeRecap.footer + "\n\nthanks"), recap)
        XCTAssertTrue(texts(vm, .notice).contains("This chat now uses Claude Code — Sonnet, on your Claude plan through the claude app on this computer."),
                      "\(texts(vm, .notice))")
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
        XCTAssertTrue(texts(vm, .error).contains(ClaudeCodeError.notSignedIn.errorDescription!), "\(texts(vm, .error))")
        XCTAssertTrue(texts(vm, .notice).contains("Not delivered to the model: hello"))
        XCTAssertEqual(transport.log.claudeSession(vm.id).session, "75eaed3b", "the session it opened is the one to carry on")

        try setOutput(turn("Hi!"))
        try await send("hello again", to: vm)
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume 75eaed3b"))
        XCTAssertEqual(texts(vm, .assistant).last, "Hi!")
    }

    func testALostSessionStartsANewOneWithARecap() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("First."))
        try await send("first message", to: vm)
        // Claude Code lost the session: --resume finds nothing, so the turn starts over with the chat so far.
        try """
            {"type":"result","subtype":"error_during_execution","is_error":true,"result":"","session_id":"S1","num_turns":0,"errors":["No conversation found with session ID: S1"]}

            """.write(to: cli.appendingPathComponent("out-2"), atomically: true, encoding: .utf8)
        try setOutput(turn("Second.", session: "S2"))
        try await send("second message", to: vm)
        XCTAssertEqual(runs(), 3)
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume S1"))
        XCTAssertTrue(try args(3).contains("--session-id"))
        let recap = try prompt(3)
        XCTAssertTrue(recap.hasPrefix(ClaudeCodeRecap.header), recap)
        XCTAssertTrue(recap.contains("Person: first message"), recap)
        XCTAssertTrue(recap.hasSuffix("second message"), recap)
        XCTAssertTrue(texts(vm, .notice).contains("Claude Code no longer had this chat's session, so a new one starts here, with a recap of the chat so far."))
        XCTAssertEqual(transport.log.claudeSession(vm.id).session, "S2")
        XCTAssertEqual(texts(vm, .assistant).last, "Second.")
    }

    func testAGoalRunsOneClaudeCodeTurnPerRound() async throws {
        let vm = transport.newSession(cwd: dir.path)
        try turn("Still going.").write(to: cli.appendingPathComponent("out-1"), atomically: true, encoding: .utf8)
        try setOutput(turn("All done.\nGOAL_COMPLETE"))
        try await send("/goal fix every greeting", to: vm)
        XCTAssertEqual(runs(), 2, "two rounds, each one claude -p")
        XCTAssertTrue(try prompt(1).contains("fix every greeting"))
        XCTAssertTrue(try prompt(1).hasSuffix(ClaudeCodeTurn.goalNote), "a goal round says how to end it on Claude Code")
        XCTAssertTrue(try args(2).joined(separator: " ").contains("--resume S1"), "round 2 carries on round 1's session")
        XCTAssertTrue(texts(vm, .notice).contains { $0.hasPrefix("✅ Goal complete after 2 rounds") }, "\(texts(vm, .notice))")
        XCTAssertEqual(vm.promptHistory.last?.source, .goal)
        XCTAssertEqual(vm.promptHistory.last?.outcome, .completed)
    }

    func testStopInterruptsAClaudeCodeTurn() async throws {
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
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Claude Code's own interrupt was enough")
        XCTAssertEqual(JSONValue(parsing: try read("interrupt-1"))?["request"]?["subtype"], "interrupt")
        XCTAssertTrue(texts(vm, .notice).contains("Stopped."), "\(texts(vm, .notice))")
        XCTAssertEqual(vm.promptHistory.last?.outcome, .stopped)
        XCTAssertEqual(transport.log.claudeSession(vm.id).session, "S", "the session it opened is kept")
    }

    func testAFoldersOwnSettingsLoadOnlyWhenTrustedInClaudeCode() async throws {
        // A cloned repository's MCP servers (or hooks): headless, Claude Code would start them without asking anyone.
        try "{}".write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let claude = cli.appendingPathComponent("claude").path
        transport.claudeCode.installOverride = ClaudeCodeInstall(path: claude, version: "2.1.299",
                                                                 flags: Self.flags.union(["--setting-sources"]), commands: ["auth"])
        await transport.claudeCode.refresh()
        let vm = transport.newSession(cwd: dir.path)
        try setOutput(turn("Done."))
        try await send("look around", to: vm)
        let first = try args(1)
        XCTAssertEqual(first[try XCTUnwrap(first.firstIndex(of: "--setting-sources")) + 1], "user", "only the person's own settings")
        let notice = ClaudeCodeTrust.skippedNotice([".mcp.json"])
        XCTAssertTrue(texts(vm, .notice).contains(notice), "\(texts(vm, .notice))")
        try await send("again", to: vm)
        XCTAssertTrue(try args(2).contains("--setting-sources"))
        XCTAssertEqual(texts(vm, .notice).filter { $0 == notice }.count, 1, "said once")

        // Trusted in Claude Code itself: the folder's own settings load, as they would in a terminal.
        transport.claudeCode.isTrusted = { _, _ in true }
        try await send("and now", to: vm)
        XCTAssertFalse(try args(3).contains("--setting-sources"))

        // A CLI that can't leave them out never runs in a folder that has them and isn't trusted.
        transport.claudeCode.isTrusted = { _, _ in false }
        transport.claudeCode.installOverride = ClaudeCodeInstall(path: claude, version: "2.1.299", flags: Self.flags, commands: ["auth"])
        await transport.claudeCode.refresh()
        try await send("one more", to: vm)
        XCTAssertEqual(runs(), 3, "the claude command didn't run")
        XCTAssertTrue(texts(vm, .error).contains(ClaudeCodeTrust.cantSkipMessage(version: "2.1.299", files: [".mcp.json"])),
                      "\(texts(vm, .error))")
        XCTAssertTrue(texts(vm, .notice).contains("Not delivered to the model: one more"))
    }

    func testAQuestionStillOpenWhenClaudeCodeEndsIsAnsweredNoAndGoesAway() async throws {
        let vm = transport.newSession(cwd: dir.path)
        // Claude Code asks, then dies before anyone answers: the card must not outlive the turn (it would hold the
        // chat's task queue, and its answer could only go to a closed pipe).
        try (#"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"toolu_q"}}"#
             + "\n").write(to: cli.appendingPathComponent("ask-and-die"), atomically: true, encoding: .utf8)
        try setOutput(turn("never"))
        try await send("clean the build", to: vm)
        XCTAssertTrue(vm.pendingGates.isEmpty, "\(vm.pendingGates)")
        XCTAssertTrue(texts(vm, .error).contains { $0.hasPrefix("Claude Code stopped without answering") }, "\(texts(vm, .error))")

        // The next turn runs normally (nothing waits on the old question).
        try FileManager.default.removeItem(at: cli.appendingPathComponent("ask-and-die"))
        try setOutput(turn("Cleaned."))
        try await send("try again", to: vm)
        XCTAssertEqual(texts(vm, .assistant).last, "Cleaned.")
        XCTAssertTrue(vm.pendingGates.isEmpty)
    }

    func testWhatVisionHandsClaudeCodeGoesThroughTheShield() async throws {
        ProviderClients.shield = ShieldPolicy()
        defer { ProviderClients.shield = nil }
        let key = "sk-ant-api03-" + String(repeating: "Qq11", count: 6)
        let vm = transport.newSession(cwd: dir.path)
        // An earlier turn on another model…
        transport.setRoute(transport.config.providers[1].routeID, for: vm)
        try await send("Mail pat@example.com the report", to: vm)
        // …goes to Claude Code as a masked recap; the new message keeps the address (Claude Code may need to write it)
        // but not the key.
        transport.setRoute(transport.config.providers[0].routeID, for: vm)
        try setOutput(turn("Sent."))
        try await send("Now use \(key) for pat@example.com", to: vm)
        let sent = try prompt(1)
        XCTAssertTrue(sent.hasPrefix(ClaudeCodeRecap.header + "\n" + ClaudeCodeShield.recapNote + "\n\n"), sent)
        XCTAssertTrue(sent.contains("Person: Mail ⟦EMAIL_1⟧ the report"), sent)
        XCTAssertTrue(sent.hasSuffix(ClaudeCodeRecap.footer + "\n\nNow use ⟦SECRET_1⟧ for pat@example.com"), sent)
        XCTAssertFalse(sent.contains(key))
        XCTAssertTrue(texts(vm, .notice).contains(ClaudeCodeShield.notice), "\(texts(vm, .notice))")
        let answer = try XCTUnwrap(vm.currentAnswerID)
        XCTAssertEqual(vm.masked[answer]?.counts, [.secret: 1, .email: 1], "the shield chip on the answer says what")
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
