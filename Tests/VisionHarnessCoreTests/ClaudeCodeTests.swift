import XCTest
@testable import VisionHarnessCore

/// Claude Code as an engine: finding and checking the CLI, its command line, reading its stream-json, answering its
/// permission questions, the turn.
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

    private func notices(_ events: [ClaudeCodeEvent]) -> [String] {
        events.compactMap { if case .notice(let t) = $0 { t } else { nil } }
    }

    private func failure(_ parser: ClaudeCodeStreamParser, exit: ClaudeCodeExit = ClaudeCodeExit(exitCode: 1)) -> ClaudeCodeError? {
        ClaudeCodeTurn.failure(ClaudeCodeTurn.LockedParser.Snapshot(
            sessionID: parser.sessionID, progressed: parser.progressed, result: parser.result, usage: parser.usage,
            lastReplyText: parser.lastReplyText, contextTokens: parser.contextTokens, model: parser.model,
            apiKeySource: parser.apiKeySource, apiError: parser.apiError, rateLimit: parser.rateLimit, unparsed: parser.unparsed),
            exit: exit)
    }

    func testAFullTurnBecomesVisionsEvents() {
        let (parser, events) = parse(ClaudeCodeFixtures.toolTurn)
        let engine = engineEvents(events)
        XCTAssertEqual(parser.sessionID, ClaudeCodeFixtures.sessionID)
        XCTAssertEqual(parser.model, "claude-sonnet-5-5")
        XCTAssertEqual(parser.apiKeySource, "none")
        XCTAssertTrue(parser.progressed)
        XCTAssertNil(parser.apiError)

        // Streamed text arrives once — the whole assistant messages that follow the deltas don't repeat it.
        XCTAssertEqual(streamedText(events), "I'll fix the greeting.Done — fixed the typo.")
        XCTAssertEqual(engine.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }, ["The greeting has a typo."])

        // The text before a tool call goes with it; the closing text on its own.
        let messages = engine.compactMap { e -> (String, [ToolCall])? in
            if case .assistantMessage(_, let text, let calls) = e { (text, calls) } else { nil }
        }
        XCTAssertEqual(messages.map(\.0), ["I'll fix the greeting.", "", "", "", "Done — fixed the typo."])
        XCTAssertEqual(messages.flatMap(\.1).map(\.name), ["edit", "run_shell_command", "write_file", "todo_write"])

        let started = engine.compactMap { e -> String? in
            if case .toolStarted(_, let name, let preview) = e { "\(name): \(preview)" } else { nil }
        }
        XCTAssertEqual(started, ["edit: hello.txt", "run_shell_command: cat hello.txt", "write_file: NOTES.md", "todo_write: 2 steps"])
        let finished = engine.compactMap { e -> String? in
            if case .toolFinished(_, let name, let ok, let summary, _) = e { "\(name) \(ok) \(summary)" } else { nil }
        }
        XCTAssertEqual(finished, ["edit true Edited hello.txt (+1 −1)", "run_shell_command true hello world",
                                  "write_file true Created NOTES.md", "todo_write true Plan updated"])

        let changes = engine.flatMap { e -> [FileChange] in if case .filesChanged(let c) = e { c } else { [] } }
        XCTAssertEqual(changes, [FileChange(URL(fileURLWithPath: "/tmp/project/hello.txt"), .modified),
                                 FileChange(URL(fileURLWithPath: "/tmp/project/NOTES.md"), .created)])
        let todos = engine.compactMap { e -> [TodoItem]? in if case .todos(let t) = e { t } else { nil } }
        XCTAssertEqual(todos.first?.map(\.content), ["Fix the typo", "Write a note"])
        XCTAssertEqual(todos.first?.map(\.status), [.completed, .inProgress])

        // How it ended: success, the result's usage (input + both cache counts as the prompt), the last request's
        // context, the closing text.
        guard case .finished(let usage)? = engine.last else { return XCTFail("the turn didn't finish") }
        XCTAssertEqual(usage, LLMUsage(promptTokens: 31_512, completionTokens: 420, cachedTokens: 30_000))
        XCTAssertEqual(parser.usage, usage)
        XCTAssertEqual(parser.result?.numTurns, 4)
        XCTAssertEqual(parser.result?.totalCostUSD, 0.0421)
        XCTAssertEqual(parser.contextTokens, 4 + 150 + 10_900)
        XCTAssertEqual(parser.lastReplyText, "Done — fixed the typo.")
        XCTAssertNil(failure(parser, exit: ClaudeCodeExit(exitCode: 0)))
    }

    func testWithoutPartialMessagesTheWholeMessagesAreDrawn() {
        let (parser, events) = parse(ClaudeCodeFixtures.plainTurn)
        XCTAssertEqual(streamedText(events), "Looking at it.It says hello world.")
        let messages = engineEvents(events).compactMap { e -> String? in
            if case .assistantMessage(_, let text, _) = e { text } else { nil }
        }
        XCTAssertEqual(messages, ["Looking at it.", "It says hello world."])
        let summaries = engineEvents(events).compactMap { e -> String? in
            if case .toolFinished(_, _, _, let summary, _) = e { summary } else { nil }
        }
        XCTAssertEqual(summaries, ["Read 1 line of hello.txt"])
        XCTAssertEqual(parser.lastReplyText, "It says hello world.")
    }

    func testTheRealNotSignedInStream() {
        let (parser, events) = parse(ClaudeCodeFixtures.notLoggedIn)
        XCTAssertFalse(parser.progressed, "a synthetic error message is not the model answering")
        XCTAssertEqual(parser.sessionID, "75eaed3b-8da5-4492-8a96-9893fcfccdac")
        XCTAssertEqual(parser.version, "2.1.299")
        XCTAssertEqual(parser.apiError?.category, "authentication_failed")
        XCTAssertEqual(parser.apiError?.text, "Not logged in · Please run /login")
        XCTAssertTrue(streamedText(events).isEmpty, "the error is not drawn as a reply")
        XCTAssertEqual(failure(parser), .notSignedIn)
        XCTAssertEqual(ClaudeCodeError.notSignedIn.errorDescription,
                       "Claude Code isn't signed in on this computer. Open a terminal, run  claude auth login  (choose your Claude account), then send again.")
    }

    func testARefusedCommandCountsAsADenial() {
        let (parser, events) = parse(ClaudeCodeFixtures.deniedTurn)
        let finished = engineEvents(events).compactMap { e -> String? in
            if case .toolFinished(_, _, let ok, let summary, _) = e { "\(ok) \(summary)" } else { nil }
        }
        XCTAssertEqual(finished, ["false Permission to use Bash with command rm -rf build has been denied."])
        XCTAssertEqual(parser.result?.denials, 1)
    }

    func testASubagentsStepsAreTheWorkingLine() {
        let (_, events) = parse(ClaudeCodeFixtures.subagentTurn)
        let started = engineEvents(events).compactMap { e -> String? in
            if case .toolStarted(_, let name, let preview) = e { "\(name): \(preview)" } else { nil }
        }
        XCTAssertEqual(started, ["agent: Find the greeting"], "only the main conversation becomes rows")
        let activity = events.compactMap { e -> String? in if case .activity(let t?) = e { t } else { nil } }
        XCTAssertEqual(activity, ["Subagent: Search greeting  in src"])
        XCTAssertEqual(streamedText(events), "The greeting lives in src/app.js.", "its text stays inside it")
    }

    func testRetriesCompactionAndStatus() {
        let (_, events) = parse(ClaudeCodeFixtures.retryTurn)
        var retries: [String] = []
        var recovered: [Int] = []
        for case .engine(let e) in events {
            if case .retrying(let attempt, let delay, let reason) = e { retries.append("\(attempt) \(delay) \(reason)") }
            if case .recovered(let attempts) = e { recovered.append(attempts) }
        }
        XCTAssertEqual(retries, ["1 2.0 Claude Code: overloaded, HTTP 529", "2 4.0 Claude Code: overloaded, HTTP 529"])
        XCTAssertEqual(recovered, [2])
        XCTAssertEqual(notices(events), ["Claude Code compacted the conversation to make room: ~180,000 → ~21,000 tokens.",
                                         "Claude Code: The model is slow right now."])
        let activity = events.compactMap { e -> String?? in if case .activity(let t) = e { t } else { nil } }
        XCTAssertEqual(activity, ["Claude Code is compacting the conversation…", nil], "the result clears the working line")
    }

    func testTheStepLimitAndThePlansLimits() {
        let (maxTurns, _) = parse(ClaudeCodeFixtures.maxTurnsTurn)
        XCTAssertEqual(failure(maxTurns), .failed("Claude Code stopped: it reached its limit of steps for one turn. Send “keep going” to carry on."))

        let (limit, _) = parse(ClaudeCodeFixtures.usageLimitTurn)
        XCTAssertEqual(failure(limit), .rateLimited("You've reached your Claude plan's usage limit. Pick another model for this chat from the model menu, or send again once it resets."))
        XCTAssertTrue(ClaudeCodeError.rateLimited("x").isPermanent)

        let (rejected, _) = parse(ClaudeCodeFixtures.rejectedTurn)
        XCTAssertEqual(rejected.rateLimit?.typeWords, "weekly")
        guard case .rateLimited(let words)? = failure(rejected) else { return XCTFail("\(String(describing: failure(rejected)))") }
        XCTAssertTrue(words.hasPrefix("You've reached your Claude plan's weekly limit — it resets "), words)
        XCTAssertTrue(words.hasSuffix(". Pick another model for this chat from the model menu, or send again once it resets."))

        let (warned, events) = parse(ClaudeCodeFixtures.warningTurn)
        XCTAssertNil(failure(warned, exit: ClaudeCodeExit(exitCode: 0)))
        XCTAssertEqual(notices(events).count, 1, "one warning per kind of limit")
        XCTAssertTrue(notices(events)[0].hasPrefix("Your Claude plan: 82% of your five-hour limit used — it resets "), notices(events)[0])
        let reset = ClaudeCodeRateLimit(status: "allowed_warning", type: "five_hour", utilization: 0.5,
                                        resetsAt: Date(timeIntervalSince1970: 1_792_000_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(reset.resetWords(now: Date(timeIntervalSince1970: 1_791_990_000), calendar: calendar), " — it resets at 17:46")
        XCTAssertEqual(reset.resetWords(now: Date(timeIntervalSince1970: 1_791_800_000), calendar: calendar), " — it resets Wed 14 Oct, 17:46")
    }

    func testAPlanGoesToThePlanPanel() {
        let (_, events) = parse(ClaudeCodeFixtures.planTurn)
        let calls = engineEvents(events).flatMap { e -> [ToolCall] in if case .assistantMessage(_, _, let c) = e { c } else { [] } }
        XCTAssertEqual(calls.map(\.name), [ExitPlanModeTool.name])
        XCTAssertEqual(JSONArgs.string(calls[0].arguments, "plan"), "1. Fix the typo\n2. Run the tests")
    }

    func testControlRequestsComeBackToTheCaller() throws {
        let (_, events) = parse(ClaudeCodeFixtures.permissionTurn)
        let requests = events.compactMap { e -> ClaudeCodePermissionRequest? in if case .permission(let r) = e { r } else { nil } }
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.requestID, "req-1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolUseID, "toolu_q")
        XCTAssertEqual(request.input?["command"], "rm -rf build")
        XCTAssertEqual(request.decisionReasonType, "safetyCheck")
        XCTAssertEqual(request.classifierApprovable, false)
        let unhandled = events.compactMap { e -> String? in
            if case .unhandledControl(let id, let subtype) = e { "\(id) \(subtype)" } else { nil }
        }
        XCTAssertEqual(unhandled, ["req-2 hook_callback"])
    }

    func testFailuresWithoutAResult() {
        let parser = ClaudeCodeStreamParser(workspace: workspace)
        _ = parser.consume("Error: something exploded")
        XCTAssertEqual(failure(parser, exit: ClaudeCodeExit(exitCode: 1, stderr: "Error: No conversation found with session ID: abc")),
                       .sessionNotFound)
        XCTAssertEqual(failure(parser, exit: ClaudeCodeExit(exitCode: 1, stderr: "Error: Session ID abc is already in use.")), .sessionInUse)
        XCTAssertEqual(failure(parser, exit: ClaudeCodeExit(exitCode: 2, stderr: "error: unknown option '--frobnicate'\n")),
                       .failed("Claude Code stopped without answering: error: unknown option '--frobnicate'"))
        XCTAssertEqual(failure(parser, exit: ClaudeCodeExit(exitCode: 3)),
                       .failed("Claude Code stopped without answering: Error: something exploded"), "a line that wasn't JSON says why")
        XCTAssertEqual(failure(ClaudeCodeStreamParser(workspace: workspace), exit: ClaudeCodeExit(exitCode: 3)),
                       .failed("Claude Code stopped without answering (exit code 3)."))
    }

    func testDanglingCallsAreClosed() {
        let parser = ClaudeCodeStreamParser(workspace: workspace)
        _ = parser.consume(ClaudeCodeFixtures.lines(ClaudeCodeFixtures.permissionTurn)[1])
        let closed = parser.closeDangling("Stopped before it finished").compactMap { e -> String? in
            if case .engine(.toolFinished(let id, _, let ok, let summary, _)) = e { "\(id) \(ok) \(summary)" } else { nil }
        }
        XCTAssertEqual(closed, ["toolu_q false Stopped before it finished"])
        XCTAssertTrue(parser.closeDangling("again").isEmpty)
    }

    // MARK: - Permission questions

    private func ask(_ tool: String, _ input: JSONValue, preset: PermissionPreset = .workspaceWrite,
                     reasonType: String? = nil, reason: String? = nil) -> ClaudeCodePermissionDecision {
        ClaudeCodePermissions.decide(ClaudeCodePermissionRequest(requestID: "r", toolName: tool, input: input, toolUseID: "t",
                                                                 decisionReason: reason, decisionReasonType: reasonType),
                                     policy: PermissionPolicy(preset: preset, workspaceRoot: workspace))
    }

    func testPermissionQuestionsAreDecidedLikeVisionsOwnEngine() {
        // Workspace write: reads and edits inside, read-only commands go ahead; the rest asks.
        XCTAssertEqual(ask("Read", ["file_path": "/tmp/project/notes.md"]), .allow)
        XCTAssertEqual(ask("Edit", ["file_path": "/tmp/project/a.swift"]), .allow)
        XCTAssertEqual(ask("Write", ["file_path": "/Users/me/elsewhere.txt"]),
                       .ask(name: "write_file", detail: "Write outside the project: /Users/me/elsewhere.txt"))
        XCTAssertEqual(ask("Bash", ["command": "ls -la"]), .allow)
        XCTAssertEqual(ask("Bash", ["command": "rm -rf build"]), .ask(name: "run_shell_command", detail: "Run command: rm -rf build"))
        XCTAssertEqual(ask("mcp__github__create_issue", ["title": "x"]),
                       .ask(name: "mcp__github__create_issue", detail: "Use MCP github · create_issue: {\"title\":\"x\"}"))
        XCTAssertEqual(ask("WebFetch", ["url": "https://example.com"]), .allow)
        // A safety check always asks, with Claude Code's reason (escape codes stripped).
        XCTAssertEqual(ask("Bash", ["command": "ls"], reasonType: "safetyCheck", reason: "\u{1B}[1mls\u{1B}[0m outside the folder"),
                       .ask(name: "run_shell_command", detail: "Run command: ls — Claude Code says: ls outside the folder"))
        // Full access: everything goes ahead.
        XCTAssertEqual(ask("Bash", ["command": "rm -rf build"], preset: .fullAccess), .allow)
        XCTAssertEqual(ask("mcp__github__create_issue", [:], preset: .fullAccess), .allow)
        // Plan only: writes ask; the plan is shown and Claude stops.
        XCTAssertEqual(ask("Edit", ["file_path": "/tmp/project/a.swift"], preset: .plan),
                       .ask(name: "edit", detail: "Write: /tmp/project/a.swift"))
        XCTAssertEqual(ask("ExitPlanMode", ["plan": "x"], preset: .plan), .deny(ClaudeCodePermissions.planShown))
        XCTAssertEqual(ask("ExitPlanMode", ["plan": "x"]), .allow)
        XCTAssertEqual(ask("AskUserQuestion", [:]), .deny(ClaudeCodePermissions.askInReply))
    }

    func testAReadOutsideTheProjectAsks() throws {
        // Claude Code asks only about reads outside its folders — ~/.aws, ~/.ssh — and what it reads goes to Anthropic.
        let home = NSHomeDirectory()
        XCTAssertEqual(ask("Read", ["file_path": "~/.aws/credentials"]),
                       .ask(name: "read_file", detail: "Read outside the project: \(home)/.aws/credentials"))
        XCTAssertEqual(ask("Read", ["file_path": "/etc/hosts"]), .ask(name: "read_file", detail: "Read outside the project: /etc/hosts"))
        XCTAssertEqual(ask("Read", ["file_path": "../other/secret.txt"]),
                       .ask(name: "read_file", detail: "Read outside the project: /tmp/other/secret.txt"))
        XCTAssertEqual(ask("Grep", ["pattern": "AKIA", "path": "~/.ssh"]),
                       .ask(name: "grep", detail: "Read outside the project: \(home)/.ssh"))
        XCTAssertEqual(ask("Glob", ["pattern": "~/.ssh/id_*"]), .ask(name: "glob", detail: "Read outside the project: \(home)/.ssh"))
        XCTAssertEqual(ask("Glob", ["pattern": "/**/*.pem"]), .ask(name: "glob", detail: "Read outside the project: /"))
        XCTAssertEqual(ask("Glob", ["pattern": "../other/**/*.env"]), .ask(name: "glob", detail: "Read outside the project: /tmp/other"))
        XCTAssertEqual(ask("LS", ["path": "/Users"]), .ask(name: "list_directory", detail: "Read outside the project: /Users"))
        // Inside the project (relative, absolute, a pattern with no path) goes ahead.
        XCTAssertEqual(ask("Glob", ["pattern": "**/*.swift"]), .allow)
        XCTAssertEqual(ask("Grep", ["pattern": "TODO"]), .allow)
        XCTAssertEqual(ask("Read", ["file_path": "Sources/a.swift"]), .allow)
        XCTAssertEqual(ask("Glob", ["pattern": "/tmp/project/**/*.md"]), .allow)
        // Plan only asks too; Full access says yes.
        XCTAssertEqual(ask("Read", ["file_path": "/etc/hosts"], preset: .plan), .ask(name: "read_file", detail: "Read outside the project: /etc/hosts"))
        XCTAssertEqual(ask("Read", ["file_path": "/etc/hosts"], preset: .fullAccess), .allow)
        // Where Vision saved an attachment's text is readable without asking.
        let store = URL(fileURLWithPath: "/tmp/vision-attachments/chat-1")
        XCTAssertEqual(ClaudeCodePermissions.decide(ClaudeCodePermissionRequest(requestID: "r", toolName: "Read",
                                                                                input: ["file_path": "/tmp/vision-attachments/chat-1/a.txt"]),
                                                    policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: workspace),
                                                    readRoots: [store]), .allow)

        // A symbolic link in the project that points out of it is outside; /tmp and /private/tmp are the same place.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("proj"), outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: outside)
        let policy = PermissionPolicy(preset: .workspaceWrite, workspaceRoot: project)
        func read(_ path: String) -> ClaudeCodePermissionDecision {
            ClaudeCodePermissions.decide(ClaudeCodePermissionRequest(requestID: "r", toolName: "Read", input: ["file_path": .string(path)]),
                                         policy: policy)
        }
        XCTAssertNotEqual(read(project.appendingPathComponent("escape/key.pem").path), .allow)
        XCTAssertEqual(read(project.appendingPathComponent("a.txt").path), .allow)
        XCTAssertEqual(read(ClaudeCodeTrust.realPath(project.path) + "/new/file.txt"), .allow, "the real path of the project")
    }

    func testACommandNamingAFileInTheHomeFolderAsks() {
        for command in ["cat ~/.aws/credentials", "head -5 $HOME/.ssh/id_ed25519", "cat \"${HOME}/.netrc\"",
                        "grep -r token ../../../../..\(NSHomeDirectory())/.config", "ls ~", "base64 < ~/.ssh/id_rsa"] {
            XCTAssertEqual(ask("Bash", ["command": .string(command)]),
                           .ask(name: "run_shell_command", detail: "Run command: \(command)"), command)
            XCTAssertEqual(ask("Bash", ["command": .string(command)], preset: .fullAccess), .allow, command)
        }
        for command in ["ls -la", "cat README.md", "grep -rn TODO Sources", "ls /usr/local/bin", "git log -3",
                        "cat /tmp/project/notes.md", "wc -l ./a.swift"] {
            XCTAssertEqual(ask("Bash", ["command": .string(command)]), .allow, command)
        }
    }

    func testAMessagesPicturesAndPDFsStayWithinItsTotals() {
        func kinds(_ parts: [AttachmentWirePart]) -> [String] {
            parts.map { part in
                switch part {
                case .text: "text"
                case .image: "image"
                case .document: "document"
                }
            }
        }
        let two = AttachmentReader.digested(MessageAttachment(kind: .file, name: "two.pdf", data: AttachmentFixtures.textPDF(["One.", "Two."])))
        let three = AttachmentReader.digested(MessageAttachment(kind: .file, name: "three.pdf",
                                                                data: AttachmentFixtures.textPDF(["A.", "B.", "C."])))
        XCTAssertEqual(two.digest?.pages, 2)
        // PDF pages in all: the one that would pass the limit goes as its text (and one over it alone says so on its chip).
        let pages = AttachmentRoute(vision: true, documents: true, maxDocumentPages: 4)
        XCTAssertEqual(kinds(AttachmentWire.parts(for: [two, three], route: pages)), ["document", "text"])
        XCTAssertEqual(AttachmentWire.delivery(three, route: AttachmentRoute(vision: true, documents: true, maxDocumentPages: 2)), .text)
        // Bytes in all, pictures and PDFs together.
        let png = AttachmentFixtures.png(of: "42")
        let pictures = (1...3).map { MessageAttachment(kind: .image, name: "p\($0).png", data: png) }
        let budget = AttachmentRoute(vision: true, documents: true, maxTotalBytes: png.count * 2 + 10)
        XCTAssertEqual(kinds(AttachmentWire.parts(for: pictures, route: budget)), ["image", "image", "text"])
        let mixed = AttachmentRoute(vision: true, documents: true, maxTotalBytes: two.data.count + png.count / 2)
        XCTAssertEqual(kinds(AttachmentWire.parts(for: [two, pictures[0]], route: mixed)), ["document", "text"])
        XCTAssertEqual(AttachmentWire.delivery(two, route: AttachmentRoute(vision: true, documents: true, maxTotalBytes: 10)), .text)
        // Claude Code's own limits.
        let route = ClaudeCodeInput.attachmentRoute
        XCTAssertEqual(route.maxImages, 20)
        XCTAssertEqual(route.maxDocuments, 5)
        XCTAssertEqual(route.maxDocumentPages, 100)
        XCTAssertEqual(route.maxTotalBytes, 12 * 1024 * 1024)
        XCTAssertLessThanOrEqual(route.maxImageBytes ?? .max, 5 * 1024 * 1024 * 3 / 4, "an image's 5 MB is counted on its base64")
    }

    // MARK: - Whose settings a turn loads

    func testOnlyAFolderTrustedInClaudeCodeLoadsItsOwnSettings() throws {
        let home = "/Users/me"
        func trusted(_ folder: String, _ projects: [String: Bool]) -> Bool {
            let config: [String: Any] = ["projects": projects.mapValues { ["hasTrustDialogAccepted": $0, "allowedTools": []] }]
            return ClaudeCodeTrust.isTrusted(URL(fileURLWithPath: folder), config: try? JSONSerialization.data(withJSONObject: config),
                                             home: home)
        }
        XCTAssertTrue(trusted("/Users/me/code/app", ["/Users/me/code/app": true]))
        XCTAssertTrue(trusted("/Users/me/code/app/sub", ["/Users/me/code/app": true]), "a folder above it")
        XCTAssertTrue(trusted("/Users/me/code/app/", ["/Users/me/code/app": true]))
        XCTAssertFalse(trusted("/Users/me/code/app", ["/Users/me/code/app": false]))
        XCTAssertFalse(trusted("/Users/me/code/app", ["/Users/me/code/other": true]))
        XCTAssertFalse(trusted("/Users/me/code/app", ["/Users/me": true]), "never inherited from the home folder")
        XCTAssertFalse(trusted("/Users/me/code/app", ["/": true]), "nor from /")
        XCTAssertTrue(trusted("/Users/me", ["/Users/me": true]), "the home folder itself, when that is the chat's folder")
        XCTAssertFalse(ClaudeCodeTrust.isTrusted(URL(fileURLWithPath: "/x"), config: Data("not json".utf8), home: home))
        XCTAssertFalse(ClaudeCodeTrust.isTrusted(URL(fileURLWithPath: "/x"), config: nil, home: home))

        // Claude Code's own config file, with the turn's environment.
        XCTAssertEqual(ClaudeCodeTrust.configFile(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path, "/cfg/.claude.json")
        XCTAssertEqual(ClaudeCodeTrust.configFile(environment: ["HOME": "/h"], home: home).path, "/h/.claude.json")
        XCTAssertEqual(ClaudeCodeTrust.configFile(environment: [:], home: home).path, "/Users/me/.claude.json")
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["projects": [ClaudeCodeTrust.realPath(project.path): ["hasTrustDialogAccepted": true]]])
            .write(to: dir.appendingPathComponent(".claude.json"))
        XCTAssertTrue(ClaudeCodeTrust.isTrusted(project, environment: ["CLAUDE_CONFIG_DIR": dir.path]),
                      "the key is the real path (/private/var/…), the folder Vision's (/var/…)")
        XCTAssertFalse(ClaudeCodeTrust.isTrusted(project, environment: ["HOME": dir.appendingPathComponent("nobody").path]))

        // What a turn loads: a cloned repository's hooks and servers stay off unless trusted.
        XCTAssertEqual(ClaudeCodeTrust.settings(for: project, install: everything, trusted: false), .userOnly(skipped: []))
        try "{}".write(to: project.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: project.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try "# Notes".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCodeTrust.settings(for: project, install: everything, trusted: false),
                       .userOnly(skipped: ["CLAUDE.md", ".claude/settings.json", ".mcp.json"]))
        XCTAssertEqual(ClaudeCodeTrust.settings(for: project, install: everything, trusted: true), .trusted)
        let old = ClaudeCodeInstall(path: "/x/claude", version: "1.0.20", flags: ["--print", "--output-format", "--input-format"])
        XCTAssertEqual(ClaudeCodeTrust.settings(for: project, install: old, trusted: false),
                       .cantSkip(skipped: ["CLAUDE.md", ".claude/settings.json", ".mcp.json"]))
        XCTAssertEqual(ClaudeCodeTrust.skippedNotice(["CLAUDE.md", ".mcp.json"]),
                       "Claude Code isn't using this folder's own settings (CLAUDE.md, .mcp.json): you haven't trusted the folder in Claude Code, so its hooks and MCP servers stay off. To use them, run  claude  once in this folder in a terminal and accept its trust question.")
        XCTAssertEqual(ClaudeCodeTrust.cantSkipMessage(version: "1.0.20", files: [".mcp.json"]),
                       "This folder has Claude Code settings of its own (.mcp.json), and Claude Code 1.0.20 can't be told to leave them out — their hooks and MCP servers would run without asking. Update it in a terminal (claude update), or trust the folder: run  claude  once in it and accept its trust question.")
        XCTAssertTrue(ClaudeCodeError.untrustedFolder("x").isPermanent)
    }

    // MARK: - The shield on what Vision hands over

    func testTheRecapIsMaskedAndTheMessageKeepsAllButSecrets() throws {
        let key = "sk-ant-api03-" + String(repeating: "Qq11", count: 6)
        let recap = try XCTUnwrap(ClaudeCodeRecap.build([.user("Mail pat@example.com the report, key \(key)"),
                                                          LLMMessage(role: .assistant, content: "Sent to pat@example.com.")]))
        let detector = SensitiveDetector(settings: ShieldSettings(), vaultValues: ["vault-value-123"])
        let masked = ClaudeCodeShield.mask(recap: recap, message: "Now email pat@example.com with \(key) and vault-value-123",
                                           parts: [.text("--- notes.md ---\ntoken \(key)"), .image(mime: "image/png", data: Data([1]))],
                                           detector: detector)
        let sentRecap = try XCTUnwrap(masked.recap)
        XCTAssertTrue(sentRecap.hasPrefix(ClaudeCodeRecap.header + "\n" + ClaudeCodeShield.recapNote + "\n\nPerson: Mail ⟦EMAIL_1⟧ the report, key ⟦SECRET_1⟧"),
                      sentRecap)
        XCTAssertFalse(sentRecap.contains("pat@example.com"))
        XCTAssertFalse(sentRecap.contains(key))
        XCTAssertTrue(sentRecap.hasSuffix(ClaudeCodeRecap.footer))
        // The person's new message keeps what Claude Code may need written as it is — only its secrets are masked, with
        // the same placeholder as in the recap.
        XCTAssertEqual(masked.message, "Now email pat@example.com with ⟦SECRET_1⟧ and ⟦SECRET_2⟧")
        XCTAssertEqual(masked.parts, [.text("--- notes.md ---\ntoken ⟦SECRET_1⟧"), .image(mime: "image/png", data: Data([1]))])
        XCTAssertEqual(masked.counts, [.secret: 2, .email: 1])
        XCTAssertTrue(masked.unchecked, "a picture goes as it is")

        // Nothing to mask: the recap as it was, no note. The shield off: everything as it is.
        let plain = ClaudeCodeShield.mask(recap: "\(ClaudeCodeRecap.header)\n\nPerson: hi\n\n\(ClaudeCodeRecap.footer)", message: "go",
                                          parts: [], detector: detector)
        XCTAssertEqual(plain.recap, "\(ClaudeCodeRecap.header)\n\nPerson: hi\n\n\(ClaudeCodeRecap.footer)")
        XCTAssertEqual(plain.counts, [:])
        XCTAssertFalse(plain.unchecked)
        let off = ClaudeCodeShield.mask(recap: recap, message: key, parts: [], detector: nil)
        XCTAssertEqual(off.recap, recap)
        XCTAssertEqual(off.message, key)
        // Secrets switched off: the vault's values are still masked.
        var noSecrets = ShieldSettings()
        noSecrets.secrets = false
        let vaultOnly = ClaudeCodeShield.mask(recap: nil, message: "\(key) vault-value-123", parts: [],
                                              detector: SensitiveDetector(settings: noSecrets, vaultValues: ["vault-value-123"]))
        XCTAssertEqual(vaultOnly.message, "\(key) ⟦SECRET_1⟧")
    }

    // MARK: - The command line and stdin

    private let everything = ClaudeCodeInstall(path: "/usr/local/bin/claude", version: "2.1.299",
                                               flags: ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help).flags,
                                               commands: ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help).commands)

    func testTheRealHelpListsWhatVisionUses() {
        let parsed = ClaudeCodeInstall.parseHelp(ClaudeCodeFixtures.help)
        for flag in ["--print", "--output-format", "--input-format", "--include-partial-messages", "--verbose", "--model",
                     "--effort", "--permission-mode", "--session-id", "--resume", "--append-system-prompt", "--add-dir",
                     "--system-prompt", "--tools", "--no-session-persistence", "--setting-sources", "--strict-mcp-config"] {
            XCTAssertTrue(parsed.flags.contains(flag), flag)
        }
        XCTAssertTrue(parsed.commands.isSuperset(of: ["auth", "mcp", "update", "upgrade", "plugin", "plugins", "doctor"]))
        XCTAssertFalse(parsed.commands.contains { !$0.allSatisfy { $0.isLetter || $0 == "-" } }, "\(parsed.commands.sorted())")
        XCTAssertTrue(everything.canRunHeadless)
        XCTAssertEqual(ClaudeCodeInstall.parseVersion("2.1.299 (Claude Code)\n"), "2.1.299")
        XCTAssertNil(ClaudeCodeInstall.parseVersion("command not found"))
    }

    func testTheCommandLine() {
        XCTAssertEqual(ClaudeCodeInvocation(model: "sonnet", effort: "high", preset: .workspaceWrite, session: .new("1111"),
                                            appendSystemPrompt: "NOTE", addDirs: ["/tmp/att"]).arguments(for: everything), [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", "sonnet", "--effort", "high", "--permission-mode", "default", "--permission-prompt-tool", "stdio",
            "--setting-sources", "user", "--session-id", "1111", "--append-system-prompt", "NOTE", "--add-dir", "/tmp/att",
        ])
        let plan = ClaudeCodeInvocation(model: "opus", preset: .plan, session: .resume("abc")).arguments(for: everything)
        XCTAssertTrue(plan.joined(separator: " ").hasSuffix("--model opus --permission-mode plan --permission-prompt-tool stdio --setting-sources user --resume abc"),
                      plan.joined(separator: " "))
        // A folder the person trusted in Claude Code: its own settings load, as in a terminal.
        let trusted = ClaudeCodeInvocation(model: "opus", session: .resume("abc"), projectSettings: true).arguments(for: everything)
        XCTAssertFalse(trusted.contains("--setting-sources"))
        XCTAssertFalse(trusted.contains("--strict-mcp-config"))
        XCTAssertTrue(ClaudeCodeInvocation(model: "haiku", preset: .fullAccess).arguments(for: everything)
            .joined(separator: " ").contains("--permission-mode acceptEdits --permission-prompt-tool stdio"))
        XCTAssertFalse(ClaudeCodeInvocation(model: "default").arguments(for: everything).contains("--model"))
    }

    func testAnOlderCLIGetsOnlyTheOptionalOptionsItKnows() {
        let old = ClaudeCodeInstall(path: "/x/claude", version: "1.0.80",
                                    flags: ["--print", "--output-format", "--input-format", "--verbose", "--model", "--resume"])
        let args = ClaudeCodeInvocation(model: "sonnet", effort: "max", preset: .fullAccess, session: .new("u"),
                                        appendSystemPrompt: "NOTE", addDirs: ["/a"]).arguments(for: old)
        XCTAssertEqual(args, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                              "--model", "sonnet", "--permission-mode", "acceptEdits", "--permission-prompt-tool", "stdio"])
    }

    func testAOneShotSideTask() {
        let args = ClaudeCodeInvocation(model: "haiku", oneShotSystemPrompt: "Summarize.").arguments(for: everything)
        XCTAssertEqual(Array(args.suffix(8)), ["--setting-sources", "user", "--strict-mcp-config",
                                               "--system-prompt", "Summarize.", "--tools", "", "--no-session-persistence"])
        XCTAssertFalse(args.contains("--permission-prompt-tool"))
        XCTAssertTrue(ClaudeCodeInvocation(model: "haiku", oneShotSystemPrompt: "S.", projectSettings: true).arguments(for: everything)
            .contains("--strict-mcp-config"), "a side task never loads anyone's servers")
    }

    func testWhatGoesDownStdin() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let pdf = Data("%PDF-1.4".utf8)
        let line = ClaudeCodeInput.line(text: "fix it\nplease", parts: [.image(mime: "image/png", data: png), .document(name: "spec.pdf", data: pdf),
                                                                       .text("--- notes.md ---\nhi")])
        XCTAssertFalse(line.contains("\n"), "one line: newlines in the text are escaped")
        let json = try XCTUnwrap(JSONValue(parsing: line))
        XCTAssertEqual(json["type"], "user")
        XCTAssertEqual(json["session_id"], "")
        XCTAssertEqual(json["parent_tool_use_id"], .null)
        let content = try XCTUnwrap(json["message"]?["content"]?.array)
        XCTAssertEqual(content.map { $0["type"]?.string }, ["text", "image", "document", "text"])
        XCTAssertEqual(content[0]["text"], "fix it\nplease")
        XCTAssertEqual(content[1]["source"]?["data"]?.string, png.base64EncodedString())
        XCTAssertEqual(content[2]["source"]?["media_type"], "application/pdf")
        XCTAssertEqual(content[2]["title"], "spec.pdf")
        XCTAssertEqual(JSONValue(parsing: ClaudeCodeInput.line(text: ""))?["message"]?["content"]?[0]?["text"], "(empty message)")

        let allow = try XCTUnwrap(JSONValue(parsing: ClaudeCodeInput.allow(requestID: "r1", input: ["command": "ls"], toolUseID: "t1")))
        XCTAssertEqual(allow, ["type": "control_response", "response": ["subtype": "success", "request_id": "r1",
                               "response": ["behavior": "allow", "updatedInput": ["command": "ls"], "toolUseID": "t1"]]])
        let deny = try XCTUnwrap(JSONValue(parsing: ClaudeCodeInput.deny(requestID: "r2", message: "no", toolUseID: nil)))
        XCTAssertEqual(deny, ["type": "control_response", "response": ["subtype": "success", "request_id": "r2",
                              "response": ["behavior": "deny", "message": "no"]]])
        XCTAssertEqual(JSONValue(parsing: ClaudeCodeInput.unhandled(requestID: "r3", subtype: "hook_callback")),
                       ["type": "control_response", "response": ["subtype": "error", "request_id": "r3",
                                                                 "error": "Vision doesn't handle hook_callback requests."]])
        XCTAssertEqual(JSONValue(parsing: ClaudeCodeInput.interrupt(requestID: "vision-stop-1")),
                       ["type": "control_request", "request_id": "vision-stop-1", "request": ["subtype": "interrupt"]])
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
        XCTAssertEqual(status.summary, "Claude Code 2.1.299 is ready — signed in as pat@example.com, using your Claude Max plan.")
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
        XCTAssertEqual(status.summary, "Claude Code 2.1.299 is installed but not signed in. Sign in once in a terminal: claude auth login")
        XCTAssertEqual(status.steps.compactMap(\.command), ["claude auth login"])
        XCTAssertTrue(status.canRun, "a turn still runs and says so in Claude Code's words")
        XCTAssertFalse(status.isUsable)
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
        XCTAssertEqual(status.summary, "Claude Code 1.0.20 is installed. (This version can't say whether it's signed in — your first message will.)")
    }

    func testMissingBrokenAndTooOld() async {
        let missing = await ClaudeCodeDetector.check(search: search([]), runner: Scripted { _, _ in AWSCLIResult(exitCode: 0) })
        XCTAssertEqual(missing, .missing)
        XCTAssertEqual(missing.summary, "Claude Code isn't installed on this computer (Vision looked on PATH and where its installers put it).")
        XCTAssertEqual(missing.steps.compactMap(\.command), ["curl -fsSL https://claude.ai/install.sh | bash",
                                                             "npm install -g @anthropic-ai/claude-code", "claude auth login"])
        XCTAssertFalse(missing.canRun)

        let broken = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, _ in
            AWSCLIResult(exitCode: 127, stderr: "env: node: No such file or directory\n")
        })
        XCTAssertEqual(broken, .broken(path: "/a/claude", problem: "env: node: No such file or directory"))
        XCTAssertEqual(broken.summary, "Claude Code at /a/claude didn't start properly (env: node: No such file or directory).")

        let tooOld = await ClaudeCodeDetector.check(search: search(["/a/claude"]), runner: Scripted { _, args in
            args.first == "--version" ? AWSCLIResult(exitCode: 0, stdout: "0.2.9") : AWSCLIResult(exitCode: 0, stdout: "Options:\n  -p, --print\n")
        })
        guard case .tooOld = tooOld else { return XCTFail("\(tooOld)") }
        XCTAssertEqual(tooOld.steps.compactMap(\.command), ["claude update"])
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
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "api_key", apiProvider: "firstParty").describe,
                       "an Anthropic API key — billed to that key, not your subscription")
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "none", apiProvider: "bedrock").describe,
                       "Amazon Bedrock (the CLI's own AWS settings)")
        XCTAssertEqual(ClaudeCodeAuth(loggedIn: true, authMethod: "oauth_token").describe, "your Claude subscription")
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

    func testTheEnvironmentDropsAParentSessionAndKeepsCredentials() {
        let env = ClaudeCodeEnvironment.environment(for: "/Users/me/.nvm/versions/node/v22.1.0/bin/claude", base: [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-ant-x", "CLAUDECODE": "1",
            "CLAUDE_CODE_SIMPLE": "1", "CLAUDE_CODE_SSE_PORT": "9", "CLAUDE_CODE_OAUTH_TOKEN": "kept", "LANG": "en_US.UTF-8",
        ], home: "/Users/me")
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_SIMPLE"])
        XCTAssertNil(env["CLAUDE_CODE_SSE_PORT"])
        XCTAssertNil(env["AWS_PAGER"])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-x", "credentials pass through untouched — a turn says when a key pays")
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "kept")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/Users/me/.nvm/versions/node/v22.1.0/bin:/usr/bin:/bin:/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin")
        XCTAssertNotNil(env["SHELL"])
    }

    // MARK: - Cost, recap

    func testTheLineUnderATurn() {
        let result = ClaudeCodeResult(subtype: "success", isError: false, text: "x", numTurns: 3, totalCostUSD: 0.3)
        let usage = LLMUsage(promptTokens: 12_400, completionTokens: 84, cachedTokens: 8_000)
        XCTAssertEqual(ClaudeCodeTurn.usageLine(result: result, usage: usage, previousTotal: 0.28, apiKeySource: "none"),
                       "Claude Code: 3 steps · 12,400 tokens in (8,000 cached) · 84 out · about $0.02 at API prices — covered by your Claude plan.")
        XCTAssertEqual(ClaudeCodeTurn.usageLine(result: result, usage: LLMUsage(promptTokens: 5, completionTokens: 1), previousTotal: nil,
                                                apiKeySource: "ANTHROPIC_API_KEY"),
                       "Claude Code: 3 steps · 5 tokens in · 1 out · about $0.30 at API prices — billed to the API key.")
        XCTAssertEqual(ClaudeCodeTurn.costWords(0.004), "under $0.01")
        XCTAssertEqual(ClaudeCodeTurn.costWords(1.54), "about $1.5")
        XCTAssertEqual(ClaudeCodeTurn.turnCost(total: 0.05, previousTotal: 0.20), 0.05, "a smaller total means the session started over")
    }

    func testTheRecapOfTheChatSoFar() throws {
        XCTAssertNil(ClaudeCodeRecap.build([]))
        let text = try XCTUnwrap(ClaudeCodeRecap.build([.user("What is 2+2?"), .assistant("4"), .system("Earlier: hello")]))
        XCTAssertEqual(text, ClaudeCodeRecap.header + "\n\nPerson: What is 2+2?\n\nAssistant: 4\n\nSummary: Earlier: hello\n\n" + ClaudeCodeRecap.footer)
        XCTAssertEqual(ClaudeCodeRecap.header, "[Earlier in this chat — before this Claude Code session. Another model (or an earlier session) answered these; carry on from here rather than starting over.]")
        let long = (1...40).map { LLMMessage.user("message \($0) " + String(repeating: "y", count: 990)) }
        let capped = try XCTUnwrap(ClaudeCodeRecap.build(long))
        XCTAssertTrue(capped.contains("message 40 "), "the newest are kept")
        XCTAssertFalse(capped.contains("message 1 "))
        XCTAssertTrue(capped.contains("Person: …"), "the oldest one that fits is cut from the front")
        XCTAssertLessThan(capped.count, ClaudeCodeRecap.defaultBudget + 400)
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
        XCTAssertEqual(ClaudeCodeModels.choices.map { "\($0.name): \($0.detail)" },
                       ["Opus: the most capable — long, hard work", "Sonnet: fast and capable — the everyday choice",
                        "Haiku: the quickest — small jobs"])
    }

    // MARK: - The real process

    /// A stand-in `claude`: records its arguments (one per line) and the first stdin line, then — with an `ask` file —
    /// prints that control request and records the answer line; with a `hang` file waits for the interrupt request
    /// and answers it with an interrupted result; otherwise prints `out`.
    static func fakeCLI(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        d="$(cd "$(dirname "$0")" && pwd)"
        n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/count"
        : > "$d/args-$n"; for a in "$@"; do printf '%s\\n' "$a" >> "$d/args-$n"; done
        IFS= read -r first; printf '%s\\n' "$first" > "$d/stdin-$n"
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
        return script
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTheRealLauncherAnswersPermissionQuestionsOnStdin() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try Self.fakeCLI(in: dir)
        let lines = ClaudeCodeFixtures.lines(ClaudeCodeFixtures.permissionTurn)
        try (lines[2] + "\n").write(to: dir.appendingPathComponent("ask"), atomically: true, encoding: .utf8)
        try (ClaudeCodeFixtures.toolTurn + "\n").write(to: dir.appendingPathComponent("out"), atomically: true, encoding: .utf8)
        let install = ClaudeCodeInstall(path: script.path, version: "2.1.299", flags: everything.flags, commands: ["auth"])
        let invocation = ClaudeCodeInvocation(model: "sonnet", preset: .workspaceWrite, session: .new("u-1"),
                                              appendSystemPrompt: ClaudeCodeTurn.systemNote)
        let texts = TextRecorder()
        let asked = TextRecorder()
        let outcome = try await ClaudeCodeTurn.run(
            install: install, invocation: invocation, message: ClaudeCodeInput.line(text: "fix the greeting"), workspace: dir,
            environment: ClaudeCodeEnvironment.environment(for: script.path, base: ProcessInfo.processInfo.environment),
            launcher: ProcessClaudeCodeLauncher(), decide: { request in
                asked.add(request.toolName)
                return .allow
            }) { event in
            if case .engine(.textDelta(let t)) = event { texts.add(t) }
        }
        XCTAssertNil(outcome.failure)
        XCTAssertFalse(outcome.interrupted)
        XCTAssertTrue(outcome.progressed)
        XCTAssertEqual(outcome.sessionID, ClaudeCodeFixtures.sessionID)
        XCTAssertEqual(outcome.lastReplyText, "Done — fixed the typo.")
        XCTAssertEqual(texts.all.joined(), "I'll fix the greeting.Done — fixed the typo.")
        XCTAssertEqual(asked.all, ["Bash"])
        // What the CLI really received: its arguments, the prompt, and the answer to its question.
        let args = try String(contentsOf: dir.appendingPathComponent("args-1"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, invocation.arguments(for: install))
        let stdin = try String(contentsOf: dir.appendingPathComponent("stdin-1"), encoding: .utf8)
        XCTAssertEqual(JSONValue(parsing: stdin)?["message"]?["content"]?[0]?["text"], "fix the greeting")
        let answer = try String(contentsOf: dir.appendingPathComponent("answer-1"), encoding: .utf8)
        XCTAssertEqual(JSONValue(parsing: answer), ["type": "control_response", "response": ["subtype": "success", "request_id": "req-1",
                       "response": ["behavior": "allow", "updatedInput": ["command": "rm -rf build", "description": "Clean"], "toolUseID": "toolu_q"]]])
    }

    func testStopSendsClaudeCodesOwnInterrupt() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try Self.fakeCLI(in: dir)
        try Data().write(to: dir.appendingPathComponent("hang"))
        let install = ClaudeCodeInstall(path: script.path, version: "2.1.299", flags: everything.flags)
        let started = Date()
        let task = Task {
            try await ClaudeCodeTurn.run(install: install, invocation: ClaudeCodeInvocation(model: "sonnet", session: .new("u")),
                                         message: ClaudeCodeInput.line(text: "wait"), workspace: dir,
                                         environment: ProcessInfo.processInfo.environment,
                                         launcher: ProcessClaudeCodeLauncher(interruptGrace: 10, killGrace: 2),
                                         decide: { _ in .allow }) { _ in }
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
        XCTAssertEqual(outcome.result?.terminalReason, "aborted_streaming", "Claude Code ended its turn and said so")
        let request = try String(contentsOf: dir.appendingPathComponent("interrupt-1"), encoding: .utf8)
        XCTAssertEqual(JSONValue(parsing: request)?["request"]?["subtype"], "interrupt")
        XCTAssertTrue(JSONValue(parsing: request)?["request_id"]?.string?.hasPrefix("vision-stop-") == true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 9, "it didn't need SIGTERM")
    }

    func testACLIThatCantStart() async {
        do {
            _ = try await ClaudeCodeTurn.run(install: ClaudeCodeInstall(path: "/nonexistent/claude", version: "2.1.299"),
                                             invocation: ClaudeCodeInvocation(), message: ClaudeCodeInput.line(text: "x"),
                                             workspace: workspace, environment: [:], launcher: ProcessClaudeCodeLauncher(),
                                             decide: { _ in .allow }) { _ in }
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
