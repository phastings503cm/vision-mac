import XCTest
@testable import VisionHarnessCore

/// Claude Code as an engine: finding and checking the CLI, its command line, reading its stream-json, the turn.
final class ClaudeCodeTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/tmp/project")

    // MARK: - Reading the stream

    private func parse(_ blob: String) -> (ClaudeCodeStreamParser, [ClaudeCodeEvent]) {
        let parser = ClaudeCodeStreamParser(workspace: workspace)
        var events: [ClaudeCodeEvent] = []
        for line in ClaudeCodeFixtures.lines(blob) { events += parser.consume(line) }
        events += parser.finish()
        return (parser, events)
    }

    private func engineEvents(_ events: [ClaudeCodeEvent]) -> [EngineEvent] {
        events.compactMap { if case .engine(let e) = $0 { e } else { nil } }
    }

    private func streamedText(_ events: [ClaudeCodeEvent]) -> String {
        engineEvents(events).compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
    }

    func testAFullTurnBecomesVisionsEvents() {
        let (parser, events) = parse(ClaudeCodeFixtures.toolTurn)
        let engine = engineEvents(events)
        XCTAssertEqual(parser.sessionID, ClaudeCodeFixtures.sessionID)
        XCTAssertEqual(parser.model, "claude-sonnet-5-5")
        XCTAssertEqual(parser.apiKeySource, "none")
        XCTAssertTrue(parser.reachedModel)
        XCTAssertNil(parser.apiError)

        // Streamed text arrives once — the whole assistant messages that follow the deltas don't repeat it.
        XCTAssertEqual(streamedText(events), "I'll fix the greeting.Done — fixed the typo.")
        let reasoning = engine.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }
        XCTAssertEqual(reasoning, ["The greeting has a typo."])

        // The text before a tool call goes with it; the closing text on its own.
        let messages = engine.compactMap { e -> (String, [ToolCall])? in
            if case .assistantMessage(_, let text, let calls) = e { (text, calls) } else { nil }
        }
        XCTAssertEqual(messages.map(\.0), ["I'll fix the greeting.", "", "", "", "Done — fixed the typo."])
        XCTAssertEqual(messages.flatMap(\.1).map(\.name), ["edit", "run_shell_command", "write_file", "todo_write"])

        let started = engine.compactMap { e -> String? in
            if case .toolStarted(_, let name, let preview) = e { "\(name): \(preview)" } else { nil }
        }
        XCTAssertEqual(started, ["edit: hello.txt", "run_shell_command: cat hello.txt", "write_file: NOTES.md", "todo_write: 2 items"])
        let finished = engine.compactMap { e -> String? in
            if case .toolFinished(_, let name, let ok, let summary, _) = e { "\(name) \(ok) \(summary)" } else { nil }
        }
        XCTAssertEqual(finished, ["edit true Edited hello.txt", "run_shell_command true hello world",
                                  "write_file true Wrote NOTES.md", "todo_write true Updated the plan"])

        let changes = engine.flatMap { e -> [FileChange] in if case .filesChanged(let c) = e { c } else { [] } }
        XCTAssertEqual(changes, [FileChange(URL(fileURLWithPath: "/tmp/project/hello.txt"), .modified),
                                 FileChange(URL(fileURLWithPath: "/tmp/project/NOTES.md"), .created)])
        let todos = engine.compactMap { e -> [TodoItem]? in if case .todos(let t) = e { t } else { nil } }
        XCTAssertEqual(todos.first?.map(\.content), ["Fix the typo", "Write a note"])
        XCTAssertEqual(todos.first?.map(\.status), [.completed, .inProgress])

        // How it ended: success, the result's usage (input + both cache counts as the prompt), the last request's
        // context, the closing text.
        guard case .finished(let usage)? = engine.last else { return XCTFail("the turn didn't finish: \(engine.last.map { "\($0)" } ?? "nothing")") }
        XCTAssertEqual(usage, LLMUsage(promptTokens: 31_512, completionTokens: 420, cachedTokens: 30_000))
        XCTAssertEqual(parser.result?.numTurns, 4)
        XCTAssertEqual(parser.result?.totalCostUSD, 0.0421)
        XCTAssertEqual(parser.contextTokens, 4 + 150 + 10_900)
        XCTAssertEqual(parser.lastReplyText, "Done — fixed the typo.")
        XCTAssertEqual(parser.toolLog, ["Edit hello.txt", "Bash cat hello.txt", "Write NOTES.md", "TodoWrite 2 items"])
    }

    func testWithoutPartialMessagesTheWholeMessagesAreDrawn() {
        let (parser, events) = parse(ClaudeCodeFixtures.plainTurn)
        XCTAssertEqual(streamedText(events), "Looking at it.It says hello world.")
        let messages = engineEvents(events).compactMap { e -> String? in
            if case .assistantMessage(_, let text, _) = e { text } else { nil }
        }
        XCTAssertEqual(messages, ["Looking at it.", "It says hello world."])
        XCTAssertEqual(parser.lastReplyText, "It says hello world.")
    }

    func testTheRealNotSignedInStream() {
        let (parser, events) = parse(ClaudeCodeFixtures.notLoggedIn)
        XCTAssertFalse(parser.reachedModel, "a synthetic error message is not the model answering")
        XCTAssertEqual(parser.sessionID, "75eaed3b-8da5-4492-8a96-9893fcfccdac")
        XCTAssertEqual(parser.version, "2.1.299")
        XCTAssertEqual(parser.apiError?.category, "authentication_failed")
        XCTAssertEqual(parser.apiError?.text, "Not logged in · Please run /login")
        XCTAssertTrue(streamedText(events).isEmpty, "the error is not drawn as a reply")
        XCTAssertEqual(parser.result?.isError, true)
        XCTAssertEqual(ClaudeCodeTurn.failure(result: parser.result, apiError: parser.apiError, exit: ClaudeCodeExit(exitCode: 1)),
                       .notSignedIn)
    }

    func testARefusedCommandIsCountedAndExplained() {
        let (parser, events) = parse(ClaudeCodeFixtures.deniedTurn)
        let finished = engineEvents(events).compactMap { e -> String? in
            if case .toolFinished(_, _, let ok, let summary, _) = e { "\(ok) \(summary)" } else { nil }
        }
        XCTAssertEqual(finished, ["false Permission to use Bash with command rm -rf build has been denied."])
        XCTAssertEqual(parser.result?.denials.map(\.toolName), ["Bash"], "the event and the result's list are one denial")
        XCTAssertEqual(parser.result?.denials.first?.detail, "rm -rf build")
        XCTAssertEqual(ClaudeCodeTurn.denialNote(parser.result!.denials, preset: .workspaceWrite),
                       "Claude Code was refused 1 tool call (Bash) — this chat's permission setting doesn't let it run that unattended. Switch the chat to Full access to let it.")
        XCTAssertEqual(ClaudeCodeTurn.denialNote(parser.result!.denials + parser.result!.denials, preset: .plan),
                       "Claude Code was refused 2 tool calls (Bash ×2) — this chat is Plan only, so it can read and plan but not change anything.")
        XCTAssertNil(ClaudeCodeTurn.denialNote([], preset: .fullAccess))
    }

    func testASubagentsWorkShowsUnderItsTask() {
        let (parser, events) = parse(ClaudeCodeFixtures.subagentTurn)
        let started = engineEvents(events).compactMap { e -> String? in
            if case .toolStarted(_, let name, let preview) = e { "\(name): \(preview)" } else { nil }
        }
        XCTAssertEqual(started, ["agent: Find the greeting", "grep: Find the greeting › greeting in src"])
        // Its text stays inside it; only the main loop's reply is drawn.
        XCTAssertEqual(streamedText(events), "The greeting lives in src/app.js.")
        XCTAssertEqual(parser.toolLog, ["Agent Find the greeting"], "the subagent's own calls stay out of the summary")
    }

    func testRetriesAndCompactionAreAnnounced() {
        let (_, events) = parse(ClaudeCodeFixtures.retryTurn)
        var retries: [String] = []
        var recovered: [Int] = []
        var notices: [String] = []
        for event in events {
            switch event {
            case .engine(.retrying(let attempt, let delay, let reason)): retries.append("\(attempt) \(delay) \(reason)")
            case .engine(.recovered(let attempts)): recovered.append(attempts)
            case .notice(let text): notices.append(text)
            default: break
            }
        }
        XCTAssertEqual(retries, ["1 2.0 Claude Code: overloaded (529)", "2 4.0 Claude Code: overloaded (529)"])
        XCTAssertEqual(recovered, [2])
        XCTAssertEqual(notices, ["Claude Code compacted its conversation (it was about 180,000 tokens)."])
    }

    func testTheStepLimitIsNotAFailure() {
        let (parser, events) = parse(ClaudeCodeFixtures.maxTurnsTurn)
        XCTAssertEqual(parser.result?.hitTurnLimit, true)
        guard case .finished? = engineEvents(events).last else { return XCTFail("a turn at its step limit still finishes") }
        XCTAssertNil(ClaudeCodeTurn.failure(result: parser.result, apiError: parser.apiError, exit: ClaudeCodeExit(exitCode: 1)))
    }

    func testThePlansUsageLimitIsNamed() {
        let (parser, _) = parse(ClaudeCodeFixtures.usageLimitTurn)
        let failure = ClaudeCodeTurn.failure(result: parser.result, apiError: parser.apiError, exit: ClaudeCodeExit(exitCode: 1))
        XCTAssertEqual(failure, .usageLimit("You've hit your limit · resets 3pm (America/Los_Angeles)"))
        XCTAssertEqual(failure?.errorDescription,
                       "Claude Code stopped: your Claude plan's usage limit is reached (You've hit your limit · resets 3pm (America/Los_Angeles)). It resets on your plan's schedule — or pick another model for this chat.")
    }

    func testAPlanGoesToThePlanPanel() {
        let (_, events) = parse(ClaudeCodeFixtures.planTurn)
        let calls = engineEvents(events).flatMap { e -> [ToolCall] in if case .assistantMessage(_, _, let c) = e { c } else { [] } }
        XCTAssertEqual(calls.map(\.name), [ExitPlanModeTool.name])
        XCTAssertEqual(JSONArgs.string(calls[0].arguments, "plan"), "1. Fix the typo\n2. Run the tests")
    }

    func testFailuresWithoutAResult() {
        XCTAssertEqual(ClaudeCodeTurn.failure(result: nil, apiError: nil,
                                              exit: ClaudeCodeExit(exitCode: 1, stderr: "Error: No conversation found with session ID: abc")),
                       .sessionNotFound)
        XCTAssertEqual(ClaudeCodeTurn.failure(result: nil, apiError: nil,
                                              exit: ClaudeCodeExit(exitCode: 1, stderr: "Error: Session ID abc is already in use.")),
                       .sessionInUse)
        XCTAssertEqual(ClaudeCodeTurn.failure(result: nil, apiError: nil, exit: ClaudeCodeExit(exitCode: 2, stderr: "error: unknown option '--frobnicate'\n")),
                       .failed("Claude Code stopped without finishing (exit code 2): error: unknown option '--frobnicate'"))
    }

    // MARK: - The command line

    private let everything = ClaudeCodeInstall(path: "/usr/local/bin/claude", version: "2.1.299",
                                               flags: ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help).flags,
                                               commands: ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help).commands)

    func testTheRealHelpListsWhatVisionUses() {
        let parsed = ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help)
        for flag in ["--print", "--output-format", "--input-format", "--include-partial-messages", "--verbose", "--model",
                     "--effort", "--permission-mode", "--permission-prompts", "--allowedTools", "--allowed-tools",
                     "--disallowedTools", "--session-id", "--resume", "--append-system-prompt", "--add-dir", "--system-prompt",
                     "--tools", "--no-session-persistence", "--mcp-config"] {
            XCTAssertTrue(parsed.flags.contains(flag), flag)
        }
        XCTAssertFalse(parsed.flags.contains("--max-turns"), "2.1.299's help doesn't list it, so Vision doesn't pass it")
        XCTAssertTrue(parsed.commands.isSuperset(of: ["auth", "mcp", "update", "upgrade", "plugin", "plugins", "doctor"]))
        XCTAssertFalse(parsed.commands.contains { !$0.allSatisfy { $0.isLetter || $0 == "-" } }, "\(parsed.commands.sorted())")
        XCTAssertTrue(everything.canRunHeadless)
        XCTAssertEqual(ClaudeCodeInstall.parseVersion("2.1.299 (Claude Code)\n"), "2.1.299")
        XCTAssertNil(ClaudeCodeInstall.parseVersion("command not found"))
    }

    func testANewWorkspaceWriteTurn() {
        let invocation = ClaudeCodeInvocation(model: "sonnet", effort: "high", preset: .workspaceWrite,
                                              session: .new("1111"), appendSystemPrompt: "NOTE", addDirs: ["/tmp/att"])
        XCTAssertEqual(invocation.arguments(for: everything), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", "sonnet", "--effort", "high",
            "--permission-mode", "acceptEdits", "--allowedTools", "Bash,WebFetch,WebSearch",
            "--disallowedTools", "Bash(rm *),Bash(sudo *),Bash(mv *),Bash(cp *),Bash(mkdir *),Bash(chmod *),Bash(chown *),Bash(dd *),Bash(git push *),Bash(git commit *),Bash(git checkout *),Bash(git reset *),Bash(git rebase *),Bash(git merge *),Bash(git branch -d *),Bash(brew install *),Bash(pip install *),Bash(npm install *)",
            "--permission-prompts", "none",
            "--session-id", "1111", "--append-system-prompt", "NOTE", "--add-dir", "/tmp/att",
        ])
    }

    func testPresetsAndResume() {
        let plan = ClaudeCodeInvocation(model: "default", preset: .plan, session: .resume("abc")).arguments(for: everything)
        XCTAssertFalse(plan.contains("--model"), "default lets Claude Code choose")
        XCTAssertTrue(plan.joined(separator: " ").contains("--permission-mode plan --permission-prompts none --resume abc"), plan.joined(separator: " "))
        let full = ClaudeCodeInvocation(model: "opus", preset: .fullAccess).arguments(for: everything)
        XCTAssertTrue(full.joined(separator: " ").contains("--permission-mode acceptEdits --allowedTools Bash,WebFetch,WebSearch --permission-prompts none"))
        XCTAssertFalse(full.contains("--disallowedTools"))
    }

    func testAnOlderCLIGetsOnlyWhatItKnows() {
        let old = ClaudeCodeInstall(path: "/x/claude", version: "1.0.80",
                                    flags: ["--print", "--output-format", "--input-format", "--verbose", "--model", "--resume",
                                            "--permission-mode", "--allowedTools", "--disallowedTools"])
        let args = ClaudeCodeInvocation(model: "sonnet", effort: "max", preset: .fullAccess, session: .new("u"),
                                        appendSystemPrompt: "NOTE", addDirs: ["/a"]).arguments(for: old)
        XCTAssertEqual(args, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                              "--model", "sonnet", "--permission-mode", "acceptEdits", "--allowedTools", "Bash,WebFetch,WebSearch"])
    }

    func testAOneShotSideTask() {
        let args = ClaudeCodeInvocation(model: "haiku", oneShotSystemPrompt: "Summarize.").arguments(for: everything)
        XCTAssertEqual(Array(args.suffix(5)), ["--system-prompt", "Summarize.", "--tools", "", "--no-session-persistence"])
        XCTAssertFalse(args.contains("--permission-mode"))
    }

    func testThePromptGoesInAsOneStreamJSONMessage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let line = ClaudeCodeInput.line(text: "fix it\nplease", images: [ClaudeCodeImage(mediaType: "image/png", data: png)])
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "one line: newlines in the text are escaped")
        let json = try XCTUnwrap(JSONValue(parsing: line))
        XCTAssertEqual(json["type"], "user")
        XCTAssertEqual(json["parent_tool_use_id"], .null)
        XCTAssertEqual(json["message"]?["role"], "user")
        let content = try XCTUnwrap(json["message"]?["content"]?.array)
        XCTAssertEqual(content.map { $0["type"]?.string }, ["image", "text"])
        XCTAssertEqual(content[0]["source"]?["media_type"], "image/png")
        XCTAssertEqual(content[0]["source"]?["data"]?.string, png.base64EncodedString())
        XCTAssertEqual(content[1]["text"], "fix it\nplease")
    }

    func testAttachmentsGoTheWayClaudeCodeReadsThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cc-att-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
        let pdf = Data("%PDF-1.4 fake".utf8)
        let long = String(repeating: "x", count: 40_001)
        let prepared = ClaudeCodeInput.prepare([
            MessageAttachment(kind: .file, name: "notes.md", data: Data("# Notes\nhi".utf8)),
            MessageAttachment(kind: .image, name: "shot.png", data: png),
            MessageAttachment(kind: .file, name: "../report.pdf", data: pdf),
            MessageAttachment(kind: .file, name: "big.txt", data: Data(long.utf8)),
        ], folder: folder)
        XCTAssertEqual(prepared.images, [ClaudeCodeImage(mediaType: "image/png", data: png)])
        XCTAssertTrue(prepared.saved)
        XCTAssertTrue(prepared.text.contains("--- notes.md ---\n# Notes\nhi\n--- end of notes.md ---"))
        XCTAssertTrue(prepared.text.contains("[Picture attached: shot.png]"))
        XCTAssertTrue(prepared.text.contains("[Attached file ../report.pdf is saved at \(folder.appendingPathComponent("report.pdf").path) — open it with your Read tool.]"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("report.pdf")), pdf)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("big.txt"), encoding: .utf8).count, 40_001)
        XCTAssertEqual(ClaudeCodeInput.safeName(".."), "attachment")
    }

    // MARK: - Finding it and asking whether it is signed in

    private struct Scripted: ClaudeCodeCommandRunner {
        let answers: @Sendable (String, [String]) -> AWSCLIResult
        func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> AWSCLIResult {
            answers(executable, arguments)
        }
    }

    private func search(_ paths: [String]) -> AWSCLISearch {
        AWSCLISearch(pathDirectories: [], knownLocations: paths, fileName: "claude", fileExists: { _ in true })
    }

    private static let signedInJSON = #"{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "pat@example.com", "subscriptionType": "max"}"#

    func testReadyWhenSignedInWithAClaudePlan() async {
        let status = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, args in
            switch args.first {
            case "--version": AWSCLIResult(exitCode: 0, stdout: "2.1.299 (Claude Code)\n")
            case "--help": AWSCLIResult(exitCode: 0, stdout: ClaudeCodeFixtures.help)
            default: AWSCLIResult(exitCode: 0, stdout: Self.signedInJSON)
            }
        })
        guard case .ready(let install, let auth) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(install.path, "/a/claude")
        XCTAssertEqual(install.version, "2.1.299")
        XCTAssertTrue(auth.usesSubscription)
        XCTAssertEqual(status.summary, "Claude Code 2.1.299 — Signed in with your Claude Max plan as pat@example.com.")
        XCTAssertTrue(status.steps.isEmpty)
    }

    func testTheRealSignedOutAnswer() async {
        let real = """
            {
              "loggedIn": false,
              "authMethod": "none",
              "apiProvider": "firstParty",
              "analyticsDisabled": false,
              "projectsDirectory": "/Users/me/.claude/projects",
              "configDirectory": "/Users/me/.claude"
            }
            """
        let asked = TextRecorder()
        let status = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, args in
            asked.add(args.joined(separator: " "))
            switch args.first {
            case "--version": return AWSCLIResult(exitCode: 0, stdout: "2.1.299 (Claude Code)\n")
            case "--help": return AWSCLIResult(exitCode: 0, stdout: ClaudeCodeFixtures.help)
            default: return AWSCLIResult(exitCode: 1, stdout: real)
            }
        })
        guard case .signedOut = status else { return XCTFail("\(status)") }
        XCTAssertEqual(asked.all, ["--version", "--help", "auth status"])
        XCTAssertEqual(status.summary, "Claude Code 2.1.299 is installed but not signed in.")
        XCTAssertEqual(status.steps.compactMap(\.command), ["claude auth login"])
    }

    func testAnOldCLIIsNeverAskedAuthStatus() async {
        let asked = TextRecorder()
        let help = "Usage: claude [options]\nOptions:\n  -p, --print  Print\n  --output-format <f>\n  --input-format <f>\n"
        let status = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, args in
            asked.add(args.joined(separator: " "))
            return args.first == "--version" ? AWSCLIResult(exitCode: 0, stdout: "1.0.20 (Claude Code)") : AWSCLIResult(exitCode: 0, stdout: help)
        })
        guard case .unknownSignIn = status else { return XCTFail("\(status)") }
        XCTAssertEqual(asked.all, ["--version", "--help"], "without an auth command, 'auth status' would be a prompt")
        XCTAssertTrue(status.isUsable)
    }

    func testMissingBrokenAndTooOld() async {
        let missing = await ClaudeCodeDetector.check(search: search([]), runner: Scripted { _, _ in AWSCLIResult(exitCode: 0) })
        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(missing.steps.first?.command, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(missing.steps.compactMap(\.command).last, "claude auth login")

        let broken = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, _ in
            AWSCLIResult(exitCode: 127, stderr: "env: node: No such file or directory\n")
        })
        XCTAssertEqual(broken, .broken(path: "/a/claude", problem: "env: node: No such file or directory"))

        let tooOld = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, args in
            args.first == "--version" ? AWSCLIResult(exitCode: 0, stdout: "0.2.9") : AWSCLIResult(exitCode: 0, stdout: "Options:\n  -p, --print\n")
        })
        guard case .tooOld = tooOld else { return XCTFail("\(tooOld)") }
        XCTAssertEqual(tooOld.steps.map(\.command), ["claude update"])
    }

    func testABrokenCandidateDoesntHideAWorkingOne() async {
        let status = await ClaudeCodeDetector.check(search: search(["/broken/claude", "/good/claude"]), runner: Scripted { path, args in
            if path == "/broken/claude" { return AWSCLIResult(exitCode: 1, stderr: "boom") }
            switch args.first {
            case "--version": return AWSCLIResult(exitCode: 0, stdout: "2.1.299 (Claude Code)")
            case "--help": return AWSCLIResult(exitCode: 0, stdout: ClaudeCodeFixtures.help)
            default: return AWSCLIResult(exitCode: 0, stdout: Self.signedInJSON)
            }
        })
        XCTAssertEqual(status.install?.path, "/good/claude")
    }

    func testWhoPays() {
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "api_key", apiProvider: "firstParty").summary,
                       "Signed in with an Anthropic API key — Claude Code bills that key's account, not a Claude plan.")
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "none", apiProvider: "bedrock").summary,
                       "Signed in, but Claude Code is set to use Amazon Bedrock — it bills that account, not a Claude plan.")
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "oauth_token").summary, "Signed in with your Claude plan.")
        XCTAssertEqual(ClaudeCodeAuth.parse("Logged in as pat")?.loggedIn, true)
        XCTAssertEqual(ClaudeCodeAuth.parse("Not logged in. Run claude auth login")?.loggedIn, false)
        XCTAssertNil(ClaudeCodeAuth.parse("usage: claude"))
    }

    func testWhereItLooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cc-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let root = home + "/Library/Application Support/Claude/claude-code"
        for version in ["2.1.30", "2.1.299", "2.1.295"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(version)/abc/claude.app/Contents/MacOS", withIntermediateDirectories: true)
        }
        XCTAssertEqual(ClaudeCodeLocator.desktopAppLocations(home: home).map { $0.replacingOccurrences(of: root + "/", with: "") },
                       ["2.1.299/abc/claude.app/Contents/MacOS/claude", "2.1.295/abc/claude.app/Contents/MacOS/claude",
                        "2.1.30/abc/claude.app/Contents/MacOS/claude"])
        let search = ClaudeCodeLocator.search(explicitPath: "~/bin/claude", environment: ["PATH": "/usr/bin:/opt/homebrew/bin"], home: home)
        XCTAssertEqual(search.explicitPath, home + "/bin/claude")
        XCTAssertEqual(search.pathDirectories, ["/usr/bin", "/opt/homebrew/bin"])
        XCTAssertEqual(search.fileName, "claude")
        XCTAssertEqual(Array(search.knownLocations.prefix(2)), [home + "/.local/bin/claude", home + "/.claude/local/claude"])
        XCTAssertEqual(search.knownLocations.last, root + "/2.1.30/abc/claude.app/Contents/MacOS/claude", "the desktop app's copy comes last")
        XCTAssertEqual(ClaudeCodeLocator.source(of: root + "/2.1.299/abc/claude.app/Contents/MacOS/claude", explicitPath: nil, home: home), .desktopApp)
        XCTAssertEqual(ClaudeCodeLocator.source(of: home + "/bin/claude", explicitPath: home + "/bin/claude", home: home), .chosen)
    }

    func testTheEnvironmentNeverCarriesAnAPIKeyOrAnotherSession() {
        let env = ClaudeCodeEnvironment.environment(for: "/Users/me/.nvm/versions/node/v22.1.0/bin/claude", base: [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-ant-x", "CLAUDECODE": "1",
            "CLAUDE_CODE_SIMPLE": "1", "CLAUDE_CODE_OAUTH_TOKEN": "kept", "LANG": "en_US.UTF-8",
        ], home: "/Users/me")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SIMPLE"])
        XCTAssertNil(env["AWS_PAGER"])
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "kept", "the person's own long-lived Claude token is theirs to use")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/Users/me/.nvm/versions/node/v22.1.0/bin:/usr/bin:/bin:/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin")
        XCTAssertNotNil(env["SHELL"])
    }

    // MARK: - Cost, recap, session

    func testCostPerTurn() {
        XCTAssertEqual(ClaudeCodeTurn.turnCost(total: 0.30, previousTotal: 0.20, resumed: true, version: "2.1.299")!, 0.10, accuracy: 1e-9)
        XCTAssertEqual(ClaudeCodeTurn.turnCost(total: 0.30, previousTotal: 0.20, resumed: true, version: "2.1.200"), 0.30,
                       "before 2.1.277 a resumed run reported only itself")
        XCTAssertEqual(ClaudeCodeTurn.turnCost(total: 0.05, previousTotal: nil, resumed: false, version: "2.1.299"), 0.05)
        XCTAssertEqual(ClaudeCodeTurn.turnCost(total: 0.05, previousTotal: 0.20, resumed: true, version: "2.1.299"), 0.05,
                       "a smaller total means a reset: it is this turn's own")
        XCTAssertEqual(ClaudeCodeTurn.formatCost(0.0421), "≈ $0.04")
        XCTAssertEqual(ClaudeCodeTurn.formatCost(0.0042), "≈ $0.0042")
        let result = ClaudeCodeResult(subtype: "success", isError: false, text: "x", numTurns: 4, durationMs: 8_123, totalCostUSD: 0.0421,
                                      usage: LLMUsage(promptTokens: 31_512, completionTokens: 420))
        XCTAssertEqual(ClaudeCodeTurn.usageLine(model: "claude-sonnet-5-5", result: result, cost: 0.0421, apiKeySource: "none"),
                       "Claude Code · claude-sonnet-5-5 · 4 steps · 31,512 in · 420 out · 8s · ≈ $0.04 at API prices (your Claude plan covers it)")
        XCTAssertTrue(ClaudeCodeTurn.usageLine(model: nil, result: result, cost: 1.5, apiKeySource: "ANTHROPIC_API_KEY")
            .hasSuffix("≈ $1.50 at API prices (billed to your API key)"))
    }

    func testTheRecapOfMessagesTheSessionHasntSeen() throws {
        XCTAssertNil(ClaudeCodeRecap.preface([]))
        let text = try XCTUnwrap(ClaudeCodeRecap.preface([
            ClaudeCodeRecapItem(role: .person, text: "What is 2+2?"),
            ClaudeCodeRecapItem(role: .assistant, text: "4"),
            ClaudeCodeRecapItem(role: .tool, text: "Run swift build — Build complete"),
        ]))
        XCTAssertEqual(text, "[Earlier in this Vision chat — messages you haven't seen (they ran on another model). Read them as context, then answer the new message below.]\n\nPerson: What is 2+2?\n\nAssistant: 4\n\nTool activity: Run swift build — Build complete\n\n[End of earlier messages. The new message:]\n\n")
        let many = (1...40).map { ClaudeCodeRecapItem(role: .person, text: "message \($0) " + String(repeating: "y", count: 990)) }
        let capped = try XCTUnwrap(ClaudeCodeRecap.preface(many))
        XCTAssertTrue(capped.contains("message 40 "), "the newest are kept")
        XCTAssertFalse(capped.contains("message 1 "))
        XCTAssertTrue(capped.contains("older messages were left out."))
        XCTAssertLessThan(capped.count, ClaudeCodeRecap.maxCharacters + 600)
    }

    func testTheReplyOtherModelsAreGiven() {
        XCTAssertEqual(ClaudeCodeTurn.transcriptReply("Done.", toolLog: []), "Done.")
        XCTAssertEqual(ClaudeCodeTurn.transcriptReply("", toolLog: ["Edit a.swift", "Bash swift test (failed)"]),
                       "(Claude Code worked on this without a written reply.)\n\n[Claude Code's tool work this turn: Edit a.swift; Bash swift test (failed)]")
        let long = ClaudeCodeTurn.transcriptReply("ok", toolLog: (1...100).map { "Read file\($0).swift" }, limit: 100)
        XCTAssertTrue(long.contains("… and "), long)
    }

    func testWhichSessionATurnUses() {
        XCTAssertEqual(ClaudeCodeLink.choice(for: nil, newID: { "fresh" }), .new("fresh"))
        XCTAssertEqual(ClaudeCodeLink.choice(for: ClaudeCodeLink(sessionID: "s", started: false), newID: { "fresh" }), .new("fresh"),
                       "a session that never reached the model may not exist: start a new one")
        XCTAssertEqual(ClaudeCodeLink.choice(for: ClaudeCodeLink(sessionID: "s", started: true), newID: { "fresh" }), .resume("s"))
    }

    func testClaudeCodeRoutesAreNeverPrivateOrHelpers() {
        var route = ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL, model: "sonnet")
        XCTAssertFalse(route.isPrivateRoute)
        route.isPrivate = true
        XCTAssertFalse(route.isPrivateRoute, "a stored choice can't make it private: it reads files itself")
        XCTAssertTrue(route.readsFilesDirectly)
        XCTAssertFalse(route.runsVisionEngine)
        let rules = ModelRequestRules.for(route, model: "sonnet")
        XCTAssertEqual(rules.thinkingLevels, [.low, .medium, .high, .max])
        XCTAssertEqual(rules.effortWord(.off), "low")
        XCTAssertEqual(rules.effortWord(.max), "max")
        XCTAssertEqual(ClaudeCodeModels.contextWindow("opus[1m]"), 1_000_000)
        XCTAssertEqual(ClaudeCodeModels.contextWindow("sonnet"), 200_000)
    }

    // MARK: - The real process

    /// A stand-in `claude`: records its arguments (one per line) and standard input, prints `out`, or — with a
    /// `hang` file — waits until SIGINT and then prints a result for the interrupted turn.
    static func fakeCLI(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        d="$(cd "$(dirname "$0")" && pwd)"
        n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
        : > "$d/args-$n"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/args-$n"; done
        cat > "$d/stdin-$n"
        if [ -f "$d/hang" ]; then
          trap 'echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"error_during_execution\\",\\"is_error\\":true,\\"result\\":\\"\\",\\"session_id\\":\\"S\\",\\"num_turns\\":1,\\"errors\\":[\\"interrupted\\"]}"; exit 130' INT
          echo '{"type":"system","subtype":"init","session_id":"S","model":"claude-sonnet-5-5"}'
          sleep 30 >/dev/null 2>&1 &
          wait
          exit 0
        fi
        cat "$d/out"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testTheRealLauncherPipesArgumentsInputAndLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try Self.fakeCLI(in: dir)
        try (ClaudeCodeFixtures.toolTurn + "\n").write(to: dir.appendingPathComponent("out"), atomically: true, encoding: .utf8)
        let install = ClaudeCodeInstall(path: script.path, version: "2.1.299", flags: everything.flags, commands: ["auth"])
        let invocation = ClaudeCodeInvocation(model: "sonnet", preset: .workspaceWrite, session: .new("u-1"),
                                              appendSystemPrompt: ClaudeCodeTurn.visionNote)
        let events = TextRecorder()
        let outcome = try await ClaudeCodeTurn.run(install: install, invocation: invocation, prompt: "fix the greeting",
                                                   workspace: dir, environment: ClaudeCodeEnvironment.environment(for: script.path, base: ProcessInfo.processInfo.environment),
                                                   launcher: ProcessClaudeCodeLauncher()) { event in
            if case .engine(.textDelta(let t)) = event { events.add(t) }
        }
        XCTAssertNil(outcome.failure)
        XCTAssertFalse(outcome.interrupted)
        XCTAssertTrue(outcome.reachedModel)
        XCTAssertEqual(outcome.sessionID, ClaudeCodeFixtures.sessionID)
        XCTAssertEqual(outcome.lastReplyText, "Done — fixed the typo.")
        XCTAssertEqual(events.all.joined(), "I'll fix the greeting.Done — fixed the typo.")
        // What the CLI really received.
        let args = try String(contentsOf: dir.appendingPathComponent("args-1"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, invocation.arguments(for: install))
        XCTAssertTrue(args.contains("Bash(rm *),Bash(sudo *),Bash(mv *),Bash(cp *),Bash(mkdir *),Bash(chmod *),Bash(chown *),Bash(dd *),Bash(git push *),Bash(git commit *),Bash(git checkout *),Bash(git reset *),Bash(git rebase *),Bash(git merge *),Bash(git branch -d *),Bash(brew install *),Bash(pip install *),Bash(npm install *)"),
                      "the deny rules arrive as one argument")
        let stdin = try Data(contentsOf: dir.appendingPathComponent("stdin-1"))
        XCTAssertEqual(JSONValue(parsing: stdin)?["message"]?["content"]?[0]?["text"], "fix the greeting")
    }

    func testStopEndsTheTurnWithSIGINT() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try Self.fakeCLI(in: dir)
        try Data().write(to: dir.appendingPathComponent("hang"))
        let install = ClaudeCodeInstall(path: script.path, version: "2.1.299", flags: everything.flags)
        let lines = TextRecorder()
        let started = Date()
        let task = Task {
            try await ClaudeCodeTurn.run(install: install, invocation: ClaudeCodeInvocation(model: "sonnet", session: .new("u")),
                                         prompt: "wait", workspace: dir, environment: ProcessInfo.processInfo.environment,
                                         launcher: ProcessClaudeCodeLauncher(interruptGrace: 10, killGrace: 2)) { event in
                if case .notice(let text) = event { lines.add(text) }
            }
        }
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("stdin-1").path) {
            if Date().timeIntervalSince(started) > 10 { return XCTFail("the CLI never started") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let outcome = try await task.value
        XCTAssertTrue(outcome.interrupted)
        XCTAssertNil(outcome.failure, "a stop is not a failure")
        XCTAssertEqual(outcome.result?.errors, ["interrupted"], "SIGINT let the CLI end its turn and say so")
        XCTAssertLessThan(Date().timeIntervalSince(started), 9, "it didn't need SIGTERM")
    }

    func testACLIThatCantStart() async {
        do {
            _ = try await ClaudeCodeTurn.run(install: ClaudeCodeInstall(path: "/nonexistent/claude", version: "2.1.299"),
                                             invocation: ClaudeCodeInvocation(), prompt: "x", workspace: workspace,
                                             environment: [:], launcher: ProcessClaudeCodeLauncher()) { _ in }
            XCTFail("it can't start")
        } catch let error as ClaudeCodeError {
            guard case .couldNotStart = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }
}

/// Collects values from any thread.
final class TextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}
