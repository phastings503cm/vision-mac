import XCTest
import SQLite3
@testable import VisionHarnessCore

/// Chats from other AI tools read as Vision rows: one test per format, plus discovery, the preview cache, exports,
/// Guardian (paged, against a scripted Guardian) and the search across chats.
final class ChatImportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to path: String) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func iso(_ text: String) -> Date { ImportDates.iso(text)! }

    // MARK: Claude Code

    func testAClaudeCodeSessionBecomesTheRowsVisionWrites() throws {
        let chat = try XCTUnwrap(ClaudeCodeChats.parse(Data(ChatImportFixtures.claudeCodeSession.utf8), fallbackID: "file-stem"))
        XCTAssertEqual(chat.source, .claudeCode)
        XCTAssertEqual(chat.sourceID, "5b1c9a1e-0000-4000-8000-000000000001", "the session id from its lines, not the file name")
        XCTAssertEqual(chat.title, "Login page fixes", "the person's own title wins over the AI's")
        XCTAssertEqual(chat.cwd, "/Users/pat/code/demo")
        XCTAssertEqual(chat.model, "claude-fable-5", "the synthetic error row doesn't count as a model")
        XCTAssertFalse(chat.automated)
        XCTAssertEqual(chat.createdAt, iso("2026-08-25T20:43:49.500Z"))
        XCTAssertEqual(chat.updatedAt, iso("2026-09-29T19:11:31.883Z"))

        let rows = chat.rows
        XCTAssertEqual(rows.map(\.kind), [.user, .assistant, .tool, .tool, .assistant, .notice, .notice, .user, .user,
                                          .notice, .compaction, .error])
        XCTAssertEqual(rows[0].text, "Fix the login page", "the harness's reminder is not the person's words")
        XCTAssertEqual(rows[0].at, iso("2026-08-25T20:43:49.500Z"), "every row keeps the time it was said")
        XCTAssertEqual(rows[1].text, "I'll look at the login form first.\n\nThen I'll run the tests.",
                       "one reply written over several lines is one message; thinking is left out")

        XCTAssertEqual(rows[2].toolName, "Bash")
        XCTAssertEqual(rows[2].argSummary, "npm test -- login")
        XCTAssertEqual(rows[2].output, "PASS login.test.ts\n3 tests passed")
        XCTAssertEqual(rows[2].text, "PASS login.test.ts")
        XCTAssertFalse(rows[2].isError)
        XCTAssertEqual(rows[3].toolName, "Read")
        XCTAssertEqual(rows[3].argSummary, "/Users/pat/code/demo/missing.ts")
        XCTAssertTrue(rows[3].isError)
        XCTAssertEqual(rows[3].text, "failed: File does not exist.")

        XCTAssertEqual(rows[4].text, "The login tests pass; the old helper file is gone.")
        XCTAssertFalse(rows.contains { $0.text?.contains("subagent's own prompt") == true }, "sidechain lines are a subagent's")
        XCTAssertFalse(rows.contains { $0.text?.contains("Caveat") == true }, "meta lines are the harness's")
        XCTAssertEqual(rows[5].text, "Ran /model claude-opus-5 in Claude Code.")
        XCTAssertEqual(rows[6].text, "Set model to claude-opus-5")
        XCTAssertEqual(rows[7].text, "[image]\n\nHere is the broken screen")
        XCTAssertEqual(rows[8].text, "also check the signup page", "a prompt typed while a turn ran is still a prompt")
        XCTAssertEqual(rows[9].text, "Background task completed: Recon finished",
                       "the notification once, not again from the queue")
        XCTAssertEqual(rows[10].text, "This session is being continued from a previous conversation.\n\nSummary: the login page was fixed.")
        XCTAssertEqual(rows[10].argSummary, "5", "how many messages the summary stands for")
        XCTAssertEqual(rows[11].text, "Please run /login · API Error: 401")
        XCTAssertEqual(chat.messageCount, 5)
    }

    func testDiscoveryFindsSessionsButNotSubagentsAndCountsThem() throws {
        let root = dir.appendingPathComponent(".claude/projects", isDirectory: true)
        let session = try write(ChatImportFixtures.claudeCodeSession, to: ".claude/projects/-Users-pat-code-demo/5b1c9a1e.jsonl")
        _ = try write(#"{"type":"user","isSidechain":true,"message":{"role":"user","content":"sub"},"timestamp":"2026-08-25T20:44:00Z"}"#,
                      to: ".claude/projects/-Users-pat-code-demo/5b1c9a1e/subagents/agent-a1.jsonl")
        _ = try write("{}", to: ".claude/projects/-Users-pat-code-demo/5b1c9a1e/workflows/w1/agents/agent-b2.jsonl")
        _ = try write("{}", to: ".claude/projects/-Users-pat-code-demo/5b1c9a1e/tool-results/r1.jsonl")
        _ = try write("# memory", to: ".claude/projects/-Users-pat-code-demo/memory/MEMORY.md")

        XCTAssertEqual(ClaudeCodeChats.root(home: dir, environment: [:]), root)
        XCTAssertEqual(ClaudeCodeChats.root(home: dir, environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"]).path, "/tmp/cc/projects")
        XCTAssertEqual(ClaudeCodeChats.sessionFiles(root: root).map(\.lastPathComponent), ["5b1c9a1e.jsonl"])
        XCTAssertEqual(ClaudeCodeChats.subagentCount(for: session), 2, "subagents and workflow agents, not tool results")
        let chat = try XCTUnwrap(ClaudeCodeChats.read(session))
        XCTAssertEqual(chat.subagents, 2)
        let notice = ChatImportText.notice(chat, importedAt: iso("2026-10-19T12:00:00Z"), folderOnThisMac: false)
        XCTAssertTrue(notice.hasPrefix("Imported from Claude Code on Oct 19, 2026: 5 messages, Aug 25, 2026 – Sep 29, 2026, in /Users/pat/code/demo (not on this computer, so it continues without a project)."), notice)
        XCTAssertTrue(notice.contains("It ran 2 subagents whose own transcripts stayed in Claude Code."))
        XCTAssertTrue(notice.hasSuffix("Any model can carry on from here: earlier tool calls are shown as cards and reach the model as a written summary."))
    }

    func testThePreviewSkipsBigToolLinesButCountsAndDatesTheSame() throws {
        let big = String(repeating: "x", count: 40_000)
        let lines = ChatImportFixtures.claudeCodeSession + "\n" + [
            #"{"parentUuid":"as7","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_9","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_big","name":"Write","input":{"file_path":"/a","content":"\#(big)"}}]},"type":"assistant","uuid":"as9","timestamp":"2026-09-30T10:00:00.000Z","sessionId":"5b1c9a1e-0000-4000-8000-000000000001"}"#,
            #"{"parentUuid":"as9","isSidechain":false,"promptId":"p9","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_big","type":"tool_result","content":"\#(big)"}]},"uuid":"u99","timestamp":"2026-09-30T10:00:05.000Z","toolUseResult":{"timestamp":"2030-01-01T00:00:00Z"},"sessionId":"5b1c9a1e-0000-4000-8000-000000000001"}"#,
        ].joined(separator: "\n")
        let full = try XCTUnwrap(ClaudeCodeChats.parse(Data(lines.utf8), fallbackID: "f"))
        let quick = try XCTUnwrap(ClaudeCodeChats.parse(Data(lines.utf8), fallbackID: "f", preview: true))
        XCTAssertEqual(quick.messageCount, full.messageCount)
        XCTAssertEqual(quick.title, full.title)
        XCTAssertEqual(quick.updatedAt, iso("2026-09-30T10:00:05.000Z"), "the skipped line's own time, not one inside its result")
        XCTAssertEqual(full.updatedAt, quick.updatedAt)
        XCTAssertEqual(full.rows.last?.toolName, "Write")
        XCTAssertEqual(full.rows.last?.output?.count, ChatImportLimits.toolOutput + "\n… [20000 more characters not imported]".count)
    }

    func testARewoundBranchIsLeftOutButParallelToolResultsStay() throws {
        func line(_ uuid: String, _ parent: String?, _ type: String, _ content: String, _ at: String) -> String {
            let up = parent.map { "\"\($0)\"" } ?? "null"
            return #"{"parentUuid":\#(up),"isSidechain":false,"type":"\#(type)","message":{"role":"\#(type)","content":\#(content)},"uuid":"\#(uuid)","timestamp":"\#(at)","sessionId":"s"}"#
        }
        let lines = [
            line("u1", nil, "user", #""First question""#, "2026-10-01T10:00:00Z"),
            line("a1", "u1", "assistant", #"[{"type":"tool_use","id":"tA","name":"Read","input":{"file_path":"/a"}}]"#, "2026-10-01T10:00:01Z"),
            line("a2", "a1", "assistant", #"[{"type":"tool_use","id":"tB","name":"Read","input":{"file_path":"/b"}}]"#, "2026-10-01T10:00:02Z"),
            line("rA", "a1", "user", #"[{"type":"tool_result","tool_use_id":"tA","content":"A says hi"}]"#, "2026-10-01T10:00:03Z"),
            line("rB", "a2", "user", #"[{"type":"tool_result","tool_use_id":"tB","content":"B says hi"}]"#, "2026-10-01T10:00:04Z"),
            line("a3", "rB", "assistant", #"[{"type":"text","text":"An answer the person rewound"}]"#, "2026-10-01T10:00:05Z"),
            line("u2", "a3", "user", #""A question on the abandoned branch""#, "2026-10-01T10:00:06Z"),
            line("u3", "rB", "user", #""The edited question""#, "2026-10-01T10:01:00Z"),
            line("a4", "u3", "assistant", #"[{"type":"text","text":"The answer that stayed"}]"#, "2026-10-01T10:01:05Z"),
        ].joined(separator: "\n")
        let chat = try XCTUnwrap(ClaudeCodeChats.parse(Data(lines.utf8), fallbackID: "f"))
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .tool, .tool, .user, .assistant])
        XCTAssertEqual(chat.rows[1].output, "A says hi", "a parallel call's result is a sibling, not on the branch, and stays")
        XCTAssertEqual(chat.rows[2].output, "B says hi")
        XCTAssertEqual(chat.rows.compactMap(\.text).filter { $0.contains("rewound") || $0.contains("abandoned") }, [])
        XCTAssertEqual(chat.rows[3].text, "The edited question")
        // A parent the file doesn't hold (a session resumed from another file): nothing is dropped.
        let orphan = lines.replacingOccurrences(of: #"{"parentUuid":null"#, with: #"{"parentUuid":"elsewhere""#)
        XCTAssertEqual(ClaudeCodeChats.parse(Data(orphan.utf8), fallbackID: "f")?.messageCount, 5)
    }

    func testClaudeCodesOtherTaggedMessagesReadAsVisionForWindowsReadsThem() throws {
        func user(_ content: String, origin: String? = nil) -> String {
            let kind = origin.map { #","origin":{"kind":"\#($0)"}"# } ?? ""
            return #"{"type":"user","isSidechain":false,"message":{"role":"user","content":\#(content)},"timestamp":"2026-10-01T10:00:00Z"\#(kind)}"#
        }
        let lines = [
            user(#""<bash-input>git status</bash-input>""#),
            user(#""<bash-stdout>On branch main</bash-stdout><bash-stderr>warning: x</bash-stderr>""#),
            user(#""[Request interrupted by user for tool use]""#),
            user(#""Rebase finished on main""#, origin: "peer"),
            #"{"type":"assistant","isSidechain":false,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]},"timestamp":"2026-10-01T10:00:01Z"}"#,
            #"{"type":"agent-name","agentName":"Release helper","sessionId":"s"}"#,
        ].joined(separator: "\n")
        let chat = try XCTUnwrap(ClaudeCodeChats.parse(Data(lines.utf8), fallbackID: "f"))
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .notice, .notice, .notice, .error])
        XCTAssertEqual(chat.rows.map { $0.text ?? "" }, ["! git status", "On branch main\nwarning: x", "Interrupted by the user.",
                                                       "Message from another session: Rebase finished on main",
                                                       "No response requested."])
        XCTAssertEqual(chat.title, "Release helper")
        XCTAssertEqual(ImportText.resultSummary("<result>\n  ok then\n</result>", isError: false), "ok then", "a wrapper's tag says nothing")
        XCTAssertEqual(ImportText.resultSummary("", isError: true), "failed")
    }

    func testASessionWithNoConversationIsNotOffered() {
        let lines = #"{"type":"custom-title","customTitle":"Empty"}"# + "\n" + #"{"type":"queue-operation","operation":"enqueue"}"#
        XCTAssertNil(ClaudeCodeChats.parse(Data(lines.utf8), fallbackID: "x"))
    }

    // MARK: Codex

    func testACodexRolloutBecomesAChat() throws {
        let names = Dictionary(uniqueKeysWithValues: JSONLines.objects(ChatImportFixtures.codexIndex).compactMap { line -> (String, String)? in
            guard let id = line["id"] as? String, let name = line["thread_name"] as? String else { return nil }
            return (id, name)
        })
        let chat = try XCTUnwrap(CodexChats.parse(Data(ChatImportFixtures.codexRollout.utf8), fallbackID: "f", names: names))
        XCTAssertEqual(chat.source, .codex)
        XCTAssertEqual(chat.sourceID, ChatImportFixtures.codexID)
        XCTAssertEqual(chat.title, "Provision bucket", "the name Codex gave the thread")
        XCTAssertEqual(chat.cwd, "/Users/pat/infra")
        XCTAssertEqual(chat.model, "gpt-5.4")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .assistant, .tool, .tool, .tool, .tool, .assistant, .notice])
        XCTAssertEqual(chat.rows[0].text, "I need an S3 bucket in Oregon", "the typed prompt once; environment and instructions are not the person's")
        XCTAssertEqual(chat.rows[0].at, iso("2026-05-07T10:03:45.440Z"))
        XCTAssertEqual(chat.rows[1].text, "I'll inspect the workspace first.", "the response item, not its event echo too")
        XCTAssertEqual(chat.rows[2].argSummary, "ls -la")
        XCTAssertFalse(chat.rows[2].isError)
        XCTAssertEqual(chat.rows[3].argSummary, "terraform plan")
        XCTAssertTrue(chat.rows[3].isError, "exit code 1")
        XCTAssertEqual(chat.rows[4].toolName, "apply_patch")
        XCTAssertEqual(chat.rows[4].argSummary, "Add File: /Users/pat/infra/bucket.tf")
        XCTAssertEqual(chat.rows[4].output, "Success. Updated the following files:\nA /Users/pat/infra/bucket.tf\n")
        XCTAssertEqual(chat.rows[5].toolName, "web_search")
        XCTAssertEqual(chat.rows[5].argSummary, "terraform s3 bucket oregon")
        XCTAssertEqual(chat.rows[7].text, "The turn was interrupted in Codex.")
    }

    func testAnOlderCodexRolloutWithoutEventsStillReads() throws {
        let chat = try XCTUnwrap(CodexChats.parse(Data(ChatImportFixtures.codexLegacy.utf8), fallbackID: "f"))
        XCTAssertEqual(chat.sourceID, "legacy-1")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(chat.rows[0].text, "What does main.py do?")
        XCTAssertEqual(chat.rows[1].argSummary, "cat main.py")
        XCTAssertEqual(chat.rows[1].output, "print('hi')")
        XCTAssertEqual(chat.title, "What does main.py do?")
    }

    func testCodexFilesAndThreadNamesAreFound() throws {
        let file = try write(ChatImportFixtures.codexRollout,
                             to: ".codex/sessions/2026/05/07/rollout-2026-05-07T03-02-09-\(ChatImportFixtures.codexID).jsonl")
        _ = try write(ChatImportFixtures.codexIndex, to: ".codex/session_index.jsonl")
        let home = CodexChats.home(home: dir, environment: [:])
        XCTAssertEqual(CodexChats.sessionFiles(codexHome: home).map(\.lastPathComponent), [file.lastPathComponent])
        XCTAssertEqual(CodexChats.threadNames(codexHome: home)[ChatImportFixtures.codexID], "Provision bucket")
        XCTAssertEqual(CodexChats.idFromFileName(file), ChatImportFixtures.codexID)
    }

    // MARK: OpenClaw

    /// An agent database with OpenClaw's tables (the columns the reader uses) holding `sessions`.
    private func openClawDatabase(_ sessions: [(id: String, key: String, label: String?, via: String?, events: [String])]) throws -> URL {
        let url = dir.appendingPathComponent(".openclaw/agents/main/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db))) }
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE session_nodes (session_key TEXT PRIMARY KEY, current_session_id TEXT, entry_json TEXT, updated_at INTEGER, created_via TEXT, label TEXT, display_name TEXT)")
        exec("CREATE TABLE session_windows (session_id TEXT PRIMARY KEY, session_key TEXT, created_at INTEGER, updated_at INTEGER, model TEXT, channel TEXT, display_name TEXT)")
        exec("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER, PRIMARY KEY (session_id, seq))")
        for session in sessions {
            let label = session.label.map { "'\($0)'" } ?? "NULL"
            let via = session.via.map { "'\($0)'" } ?? "NULL"
            exec("INSERT INTO session_nodes VALUES ('\(session.key)', '\(session.id)', '{}', 1788220802938, \(via), \(label), NULL)")
            exec("INSERT INTO session_windows VALUES ('\(session.id)', '\(session.key)', 1788220802938, 1788220900000, 'm', NULL, NULL)")
            for (seq, event) in session.events.enumerated() {
                exec("INSERT INTO transcript_events VALUES ('\(session.id)', \(seq), '\(event.replacingOccurrences(of: "'", with: "''"))', \(1788220802938 + seq))")
            }
        }
        return url
    }

    func testOpenClawSessionsComeFromItsDatabaseOnTheBranchTheyEndedOn() throws {
        let database = try openClawDatabase([
            ("7f0c2a11-0000-4000-8000-0000000000aa", "agent:main:dashboard:d1", nil, "operator", ChatImportFixtures.openClawChatEvents),
            ("9a9a9a9a-0000-4000-8000-0000000000bb", "agent:main:cron:c4a1e000", "Cron: helpdesk-sweep-30min", "cron",
             ChatImportFixtures.openClawCronEvents),
        ])
        let previews = try OpenClawChats.previews(database: database, agent: "main").sorted { $0.title < $1.title }
        XCTAssertEqual(previews.count, 2)
        let cron = try XCTUnwrap(previews.first { $0.sourceID.hasPrefix("9a9a") })
        XCTAssertEqual(cron.title, "Cron: helpdesk-sweep-30min")
        XCTAssertTrue(cron.automated)
        XCTAssertEqual(cron.detail, "Cron run")
        XCTAssertEqual(cron.messageCount, 2)
        let chatPreview = try XCTUnwrap(previews.first { $0.sourceID.hasPrefix("7f0c") })
        XCTAssertEqual(chatPreview.title, "How many open tickets are there?", "no label: the first prompt")
        XCTAssertFalse(chatPreview.automated)
        XCTAssertEqual(chatPreview.detail, "Chat")
        XCTAssertNil(chatPreview.cwd, "OpenClaw's own workspace is no project")
        XCTAssertEqual(chatPreview.location, .openClawDatabase(database, sessionID: "7f0c2a11-0000-4000-8000-0000000000aa"))

        let chat = try XCTUnwrap(OpenClawChats.read(database: database, sessionID: "7f0c2a11-0000-4000-8000-0000000000aa"))
        XCTAssertEqual(chat.source, .openClaw)
        XCTAssertEqual(chat.model, "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .assistant, .tool, .assistant])
        XCTAssertEqual(chat.rows[2].argSummary, "python3 tickets.py --open")
        XCTAssertEqual(chat.rows[2].output, "12 open")
        XCTAssertEqual(chat.rows[3].text, "There are 12 open tickets.", "the rewound answer (15) is not on the branch the chat ended on")
        XCTAssertEqual(chat.rows[0].at, iso("2026-09-01T00:00:03.000Z"))
    }

    func testOpenClawTranscriptFilesPreviewQuicklyAndReadTheSame() throws {
        let agent = dir.appendingPathComponent(".openclaw/agents/main", isDirectory: true)
        let archive = try write(ChatImportFixtures.openClawChatEvents.joined(separator: "\n"),
                                to: ".openclaw/agents/main/session-sqlite-import-archive/archive-tier.7f0c2a11-0000-4000-8000-0000000000aa.jsonl.imported-1790000000000")
        _ = try write("{}", to: ".openclaw/agents/main/session-sqlite-import-archive/archive-tier.7f0c.trajectory.jsonl.imported-1")
        _ = try write("{}", to: ".openclaw/agents/main/sessions/abc.jsonl.deleted.2026-09-16T18-04-36.539Z.ef9a.zst")
        let reset = try write(ChatImportFixtures.openClawCronEvents.joined(separator: "\n"),
                              to: ".openclaw/agents/main/sessions/9a9a9a9a-0000-4000-8000-0000000000bb.jsonl.reset.2026-08-31T15-45-07.411Z")
        XCTAssertEqual(OpenClawChats.transcriptFiles(agentFolder: agent).map(\.lastPathComponent).sorted(),
                       [archive.lastPathComponent, reset.lastPathComponent].sorted())

        let preview = try XCTUnwrap(OpenClawChats.preview(file: archive, agent: "main"))
        XCTAssertEqual(preview.sourceID, "7f0c2a11-0000-4000-8000-0000000000aa")
        XCTAssertEqual(preview.title, "How many open tickets are there?")
        XCTAssertEqual(preview.messageCount, 4, "every user and assistant line, the rewound one too (the preview doesn't walk the tree)")
        XCTAssertEqual(preview.createdAt, iso("2026-09-01T00:00:03.000Z"))
        let chat = try XCTUnwrap(OpenClawChats.read(file: archive))
        XCTAssertEqual(chat.messageCount, 3)
        XCTAssertEqual(chat.rows.last?.text, "There are 12 open tickets.")

        let cron = try XCTUnwrap(OpenClawChats.preview(file: reset, agent: "main"))
        XCTAssertTrue(cron.automated)
        XCTAssertEqual(cron.title, "Cron: helpdesk-sweep-30min")
        XCTAssertEqual(cron.detail, "Before a reset")
    }

    // MARK: Exports

    func testAClaudeAIExportZipBecomesChats() throws {
        let zip = try AttachmentFixtures.zip(["conversations.json": ChatImportFixtures.claudeAIExport,
                                              "users.json": "[]"])
        let url = dir.appendingPathComponent("data-2026-05-03.zip")
        try zip.write(to: url)
        let scan = try ExportFileChats.read(url)
        XCTAssertEqual(scan.candidates.count, 1, "the conversation without messages is left out")
        XCTAssertEqual(scan.problems, ["1 conversation in data-2026-05-03.zip had no messages and was left out."])
        let chat = try XCTUnwrap(scan.loaded[ChatImportKey.make(.claudeAI, "c0ffee00-0000-4000-8000-000000000001")])
        XCTAssertEqual(chat.title, "Trip planning")
        XCTAssertEqual(chat.createdAt, iso("2026-05-01T17:43:26.474Z"), "six fraction digits read")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .tool, .assistant])
        XCTAssertEqual(chat.rows[0].text, "Plan a weekend in Portland\n\n[Attached: budget.txt]\nBudget: $400\n\n[File: map.png]")
        XCTAssertEqual(chat.rows[1].toolName, "web_search")
        XCTAssertEqual(chat.rows[1].argSummary, "portland weekend events")
        XCTAssertEqual(chat.rows[1].output, "Saturday market")
        XCTAssertEqual(chat.rows[2].text, "Here's a plan: Saturday market, then Powell's.")
        XCTAssertEqual(scan.candidates.first?.location, .loaded)
    }

    func testAChatGPTExportFollowsTheBranchChatGPTShowed() throws {
        let url = try write(ChatImportFixtures.chatGPTExport, to: "export/conversations.json")
        let scan = try ExportFileChats.read(url.deletingLastPathComponent())   // the unzipped folder works too
        let chat = try XCTUnwrap(scan.loaded.values.first)
        XCTAssertEqual(chat.source, .chatGPT)
        XCTAssertEqual(chat.sourceID, "6790aaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(chat.title, "Fibonacci in Python")
        XCTAssertEqual(chat.model, "gpt-4o")
        XCTAssertEqual(chat.createdAt, Date(timeIntervalSince1970: 1767225600.5))
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .tool, .assistant, .user])
        XCTAssertEqual(chat.rows[0].text, "[image]\nWrite fib in Python")
        XCTAssertEqual(chat.rows[1].toolName, "python")
        XCTAssertEqual(chat.rows[1].argSummary, "def fib(n):")
        XCTAssertEqual(chat.rows[1].output, "55")
        XCTAssertEqual(chat.rows[2].text, "fib(10) is 55.")
        XCTAssertFalse(chat.rows.contains { $0.text == "An abandoned first answer" }, "a regenerated answer's other branch")
        XCTAssertEqual(chat.rows[3].at, Date(timeIntervalSince1970: 1767225700))
    }

    func testAFileThatIsNoChatExportSaysSo() throws {
        let url = try write(#"{"hello":"world"}"#, to: "notes.json")
        XCTAssertThrowsError(try ExportFileChats.read(url)) { error in
            XCTAssertEqual(error as? ChatImportError, .unknownFormat("notes.json"))
        }
    }

    // MARK: Vision's own chat files and the Guardian payload

    private func document() -> ChatExportDocument {
        let at = iso("2026-10-01T09:30:00.250Z")
        return ChatExportDocument(
            id: "AB12-cd34", title: "Release / notes: v1?", cwd: "/Users/pat/code/demo", source: .claudeCode,
            sourceID: "5b1c9a1e", createdAt: at, updatedAt: at.addingTimeInterval(120),
            rows: [
                ImportedRow(kind: .notice, text: "Imported from Claude Code.", at: at),
                ImportedRow(kind: .user, text: "Write the notes", at: at.addingTimeInterval(1)),
                ImportedRow(kind: .tool, text: "done", toolName: "Bash", argSummary: "git log `--oneline`",
                            output: "abc fix\n```\ncode\n```", isError: false, at: at.addingTimeInterval(2)),
                ImportedRow(kind: .assistant, text: "Here they are.", at: at.addingTimeInterval(3)),
                ImportedRow(kind: .error, text: "Rate limited", isError: true, at: at.addingTimeInterval(4)),
            ])
    }

    func testJSONExportReadsBackOnImportWithItsTimesAndOrigin() throws {
        let data = ChatExport.json(document(), exportedAt: iso("2026-10-19T12:00:00Z"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""format" : "vision-chat""#))
        XCTAssertTrue(text.contains(#""at" : "2026-10-01T09:30:00.250Z""#), "ISO times with milliseconds")
        let scan = try ExportFileChats.parse(data, name: "chat.json")
        let chat = try XCTUnwrap(scan.loaded.values.first)
        XCTAssertEqual(chat.source, .claudeCode, "a chat Vision imported keeps where it really came from")
        XCTAssertEqual(chat.sourceID, "5b1c9a1e")
        XCTAssertEqual(chat.preferredID, "AB12-cd34")
        XCTAssertEqual(chat.rows, document().rows)
        XCTAssertEqual(chat.title, "Release / notes: v1?")
    }

    func testTheGuardianPayloadStaysReadableByVision015AndByThisImporter() throws {
        let payload = ChatExport.guardianPayload(document())
        // Vision for macOS 0.15 restores it with a plain JSONDecoder (dates as reference-date seconds).
        struct Legacy: Decodable {
            var id: String
            var title: String
            var cwd: String?
            var rows: [Row]
            struct Row: Decodable { var kind: String; var text: String?; var isError: Bool; var at: Date }
        }
        let legacy = try JSONDecoder().decode(Legacy.self, from: payload)
        XCTAssertEqual(legacy.rows.map(\.at), document().rows.map(\.at))
        XCTAssertEqual(legacy.rows.map(\.kind), ["notice", "user", "tool", "assistant", "error"])
        let back = try XCTUnwrap(GuardianChatImport.harnessChat(id: "AB12-cd34", title: "x", updatedAt: .now, payload: payload))
        XCTAssertEqual(back.rows, document().rows)
        XCTAssertEqual(back.source, .claudeCode)
    }

    func testAChatVisionForWindowsKeptInGuardianImports() throws {
        // Vision for Windows' payload: ISO or reference seconds, a plan row, its own harness name.
        let payload = #"{"id":"win-chat-1","title":"From Windows","cwd":"C:\\code","rows":[{"kind":"user","text":"hi","isError":false,"at":"2026-10-18T00:00:00Z"},{"kind":"todos","text":"step one","isError":false,"at":781920000.5},{"kind":"weird","text":"x","isError":false,"at":1},{"kind":"assistant","text":"hello","isError":false,"at":1792886400000}],"harness":"vision-windows"}"#
        let chat = try XCTUnwrap(GuardianChatImport.harnessChat(id: "win-chat-1", title: "From Windows", updatedAt: .now,
                                                                payload: Data(payload.utf8)))
        XCTAssertEqual(chat.source, .vision)
        XCTAssertEqual(chat.sourceID, "win-chat-1")
        XCTAssertEqual(chat.preferredID, "win-chat-1")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .notice, .assistant])
        XCTAssertEqual(chat.rows[1].text, "Plan:\nstep one")
        XCTAssertEqual(chat.rows[1].at, Date(timeIntervalSinceReferenceDate: 781920000.5))
        XCTAssertEqual(chat.rows[2].at, Date(timeIntervalSince1970: 1792886400), "epoch milliseconds")
    }

    func testMarkdownExportReadsLikeTheChat() {
        let markdown = ChatExport.markdown(document(), exportedAt: iso("2026-10-19T12:00:00Z"))
        XCTAssertTrue(markdown.hasPrefix("# Release / notes: v1?\n\n- Exported from Vision on "))
        XCTAssertTrue(markdown.contains("- Imported from Claude Code (5b1c9a1e)\n- Folder: /Users/pat/code/demo\n- 2 messages, "))
        XCTAssertTrue(markdown.contains("> Imported from Claude Code."))
        XCTAssertTrue(markdown.contains("**You** · "))
        XCTAssertTrue(markdown.contains("\n\nWrite the notes\n"))
        XCTAssertTrue(markdown.contains("**Tool: Bash** `git log '--oneline'` → done"))
        XCTAssertTrue(markdown.contains("<details><summary>Output</summary>\n\n````text\nabc fix\n```\ncode\n```\n````"),
                      "a fence longer than any inside the output")
        XCTAssertTrue(markdown.contains("**Assistant** · "))
        XCTAssertTrue(markdown.contains("**Error** · "))
        XCTAssertEqual(ChatExport.fileName("Release / notes: v1?", ext: "md"), "Release   notes  v1.md")
        XCTAssertEqual(ChatExport.fileName("...", ext: "json"), "Chat.json")
    }

    // MARK: Guardian

    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        var routes: [String: String] = [:]
        func add(_ r: URLRequest) { lock.lock(); log.append(r); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private func client(_ wire: Wire) throws -> GuardianClient {
        try GuardianClient(baseURL: "https://guardian.test", session: GuardianSession(userID: "u1", email: "pat@503cm.com",
                                                                                      name: "Pat", token: "tok")) { request in
            wire.add(request)
            let url = request.url!
            let key = url.path + (url.query.map { "?" + $0 } ?? "")
            guard let body = wire.routes[key] else {
                return GuardianHTTPResponse(data: Data(#"{"error":"not found"}"#.utf8), status: 404, headers: [:])
            }
            return GuardianHTTPResponse(data: Data(body.utf8), status: 200, headers: [:])
        }
    }

    func testGuardianChatsAreListedAndReadAPageAtATime() async throws {
        let wire = Wire()
        wire.routes = [
            "/api/chats": #"[{"id":"c1","title":"Quarterly numbers","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-02T10:00:00.000Z","modelId":"claude-opus","sharedWithMe":false,"owner":{"id":"u1","email":"pat@503cm.com","name":"Pat"},"person":null},{"id":"c2","title":"","updatedAt":"2026-10-05T10:00:00.000Z","sharedWithMe":true,"owner":{"email":"ann@503cm.com","name":"Ann"},"person":{"displayName":"Dash"}}]"#,
            "/api/chats/c1?messages=latest&limit=2": #"{"id":"c1","title":"Quarterly numbers","messages":[{"id":"m3","role":"ASSISTANT","content":"Revenue was up 4%.","createdAt":"2026-10-01T10:00:03.000Z","toolCalls":[{"id":"t1","name":"run_query","args":{"query":"select sum(revenue)"},"output":"4.1","status":"done"}]},{"id":"m4","role":"USER","content":"Thanks","createdAt":"2026-10-01T10:05:00.000Z"}],"paging":{"hasMore":true,"before":"m3","olderCount":2,"hasNewer":false,"after":null,"newerCount":0,"limit":2}}"#,
            "/api/chats/c1/messages?before=m3&limit=2": #"{"messages":[{"id":"m1","role":"SYSTEM","content":"You are Guardian.","createdAt":"2026-10-01T10:00:00.000Z"},{"id":"m2","role":"USER","content":"How did Q3 go?","createdAt":"2026-10-01T10:00:01.000Z"}],"hasMore":false,"before":null,"olderCount":0}"#,
        ]
        let guardian = try client(wire)
        let list = try await guardian.guardianChats()
        XCTAssertEqual(list.map(\.id), ["c2", "c1"], "newest first")
        XCTAssertEqual(list[0].title, "Guardian chat")
        XCTAssertEqual(list[0].candidate.detail, "Shared with you by Ann")
        XCTAssertNil(list[0].candidate.messageCount)
        XCTAssertEqual(list[1].candidate.location, .guardianChat("c1"))

        let chatPages = try await guardian.guardianChatMessages(id: "c1", pageSize: 2)
        XCTAssertEqual(chatPages.compactMap { $0["id"] as? String }, ["m1", "m2", "m3", "m4"], "oldest page first")
        let chat = try XCTUnwrap(GuardianChatImport.chat(summary: list[1], messages: chatPages))
        XCTAssertEqual(chat.source, .guardian)
        XCTAssertEqual(chat.sourceID, "c1")
        XCTAssertEqual(chat.rows.map(\.kind), [.user, .tool, .assistant, .user], "Guardian's own system prompt is left out")
        XCTAssertEqual(chat.rows[1].toolName, "run_query")
        XCTAssertEqual(chat.rows[1].argSummary, "select sum(revenue)")
        XCTAssertEqual(chat.rows[1].output, "4.1")
        XCTAssertEqual(chat.rows[0].at, iso("2026-10-01T10:00:01.000Z"))
        let paths = wire.requests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/api/chats", "/api/chats/c1", "/api/chats/c1/messages"])
        XCTAssertTrue(wire.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
    }

    func testAGuardianWithoutPagingSendsTheWholeTranscriptAtOnce() async throws {
        let wire = Wire()
        wire.routes = ["/api/chats/old?messages=latest&limit=200": #"{"id":"old","messages":[{"id":"a","role":"USER","content":"hello","createdAt":"2026-01-01T00:00:00Z"},{"id":"b","role":"ASSISTANT","content":"hi","createdAt":"2026-01-01T00:00:01Z"}]}"#]
        let chat = try await client(wire).importGuardianChat(GuardianChatSummary(id: "old", title: "Old", updatedAt: .now))
        XCTAssertEqual(chat?.rows.map(\.text), ["hello", "hi"])
        XCTAssertEqual(wire.requests.count, 1)
    }

    func testAGuardianChatThatGuardianImportedSaysWhereFrom() throws {
        let list = GuardianChatImport.summaries(Data(#"""
        {"chats":[{"id":"g1","title":"Login fixes","updatedAt":"2026-10-02T10:00:00Z","importSource":"claude-code","externalId":"5b1c9a1e"},
                  {"id":"g2","title":"Kept","updatedAt":"2026-10-03T10:00:00Z","importSource":"vision-mac","externalId":"AB12-cd34"},
                  {"id":"g3","title":"Mine","updatedAt":"2026-10-04T10:00:00Z","importSource":null,"externalId":null}]}
        """#.utf8))
        XCTAssertEqual(list.map(\.candidate.alsoKnownAs), [["claude-code:5b1c9a1e"], ["vision:AB12-cd34"], nil])
        XCTAssertEqual(list.map(\.candidate.id), ["guardian:g1", "guardian:g2", "guardian:g3"], "still fetched by its Guardian id")
        XCTAssertEqual(GuardianChatSummary(id: "g", title: "t", updatedAt: .now, importSource: "vision-windows", externalID: "w1").originKey,
                       "vision:w1")
    }

    // MARK: The scanner and its cache

    func testTheScannerRemembersFilesItHasReadAndPicksUpNewOnes() throws {
        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        let scanner = ChatImportScanner(home: dir, environment: [:], cacheFolder: cache)
        XCTAssertFalse(scanner.isPresent(.claudeCode))
        let first = try write(ChatImportFixtures.claudeCodeSession, to: ".claude/projects/-Users-pat-demo/one.jsonl")
        let pinned = iso("2026-01-01T00:00:00Z")
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: first.path)
        XCTAssertTrue(scanner.isPresent(.claudeCode))
        var scan = scanner.scan(.claudeCode)
        XCTAssertEqual(scan.candidates.map(\.title), ["Login page fixes"])
        XCTAssertEqual(scan.candidates.first?.messageCount, 5)
        XCTAssertEqual(scan.candidates.first?.detail, "demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("claude-code.json").path))

        // Unchanged: answered from the cache (proved by making the file unreadable as JSON without touching its stamp).
        let size = (try FileManager.default.attributesOfItem(atPath: first.path)[.size] as? NSNumber)?.intValue ?? 0
        try Data(repeating: 0x20, count: size).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: first.path)
        scan = scanner.scan(.claudeCode)
        XCTAssertEqual(scan.candidates.map(\.title), ["Login page fixes"])

        // A new session appears; a changed one is read again.
        var second = ChatImportFixtures.claudeCodeSession.replacingOccurrences(of: "5b1c9a1e-0000-4000-8000-000000000001", with: "second-session")
        second = second.replacingOccurrences(of: "Login page fixes", with: "Second session")
        _ = try write(second, to: ".claude/projects/-Users-pat-demo/two.jsonl")
        scan = scanner.scan(.claudeCode)
        XCTAssertEqual(Set(scan.candidates.map(\.title)), ["Login page fixes", "Second session"])
        try FileManager.default.removeItem(at: first)
        scan = scanner.scan(.claudeCode)
        XCTAssertEqual(scan.candidates.map(\.title), ["Second session"], "a deleted file leaves the preview and the cache")
        let read = try XCTUnwrap(scanner.read(scan.candidates[0]))
        XCTAssertEqual(read.sourceID, "second-session")
    }

    func testTheScannerReadsOpenClawFromItsDatabaseAndFilesWithoutDoubles() throws {
        _ = try write("{}", to: ".openclaw/openclaw.json")
        _ = try openClawDatabase([("7f0c2a11-0000-4000-8000-0000000000aa", "agent:main:dashboard:d1", nil, "operator",
                                   ChatImportFixtures.openClawChatEvents)])
        _ = try write(ChatImportFixtures.openClawChatEvents.joined(separator: "\n"),
                      to: ".openclaw/agents/main/sessions/7f0c2a11-0000-4000-8000-0000000000aa.jsonl")
        _ = try write(ChatImportFixtures.openClawCronEvents.joined(separator: "\n"),
                      to: ".openclaw/agents/main/session-sqlite-import-archive/archive-tier.9a9a9a9a-0000-4000-8000-0000000000bb.jsonl.imported-1")
        let scanner = ChatImportScanner(home: dir, environment: [:], cacheFolder: nil)
        XCTAssertTrue(scanner.isPresent(.openClaw))
        let scan = scanner.scan(.openClaw)
        XCTAssertEqual(scan.candidates.count, 2, "the session in both the database and a file is offered once")
        let live = try XCTUnwrap(scan.candidates.first { $0.sourceID.hasPrefix("7f0c") })
        guard case .openClawDatabase = live.location else { return XCTFail("the database is the live copy") }
        XCTAssertNotNil(try scanner.read(live))
        let cron = try XCTUnwrap(scan.candidates.first { $0.sourceID.hasPrefix("9a9a") })
        XCTAssertNotNil(try scanner.read(cron))
    }

    func testOneClaudeCodeSessionInTwoProjectFoldersIsOfferedOnceTheFullerCopy() throws {
        // A session continued in a worktree: Claude Code copies it into the worktree's project folder, and the copy
        // left behind stops growing. Both files hold one session id.
        func line(_ type: String, _ text: String, _ at: String) -> String {
            let message = type == "user" ? #"{"role":"user","content":"\#(text)"}"#
                : #"{"model":"m","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}"#
            return #"{"type":"\#(type)","isSidechain":false,"message":\#(message),"timestamp":"\#(at)","cwd":"/Users/pat/code/demo","sessionId":"dup-1"}"#
        }
        let early = [line("user", "Fix the build", "2026-09-22T22:00:00.000Z"), line("assistant", "Fixed.", "2026-09-22T22:01:00.000Z")]
        let late = early + [line("user", "Now the tests", "2026-09-22T23:10:00.000Z"), line("assistant", "Green.", "2026-09-22T23:15:00.000Z")]
        let full = try write(late.joined(separator: "\n"), to: ".claude/projects/-Users-pat-code-demo/dup-1.jsonl")
        let stale = try write(early.joined(separator: "\n"),
                              to: ".claude/projects/-Users-pat-code-demo--claude-worktrees-x/dup-1.jsonl")
        let scanner = ChatImportScanner(home: dir, environment: [:], cacheFolder: dir.appendingPathComponent("cache"))
        for pass in ["cold", "cached"] {
            let scan = scanner.scan(.claudeCode)
            XCTAssertEqual(scan.candidates.count, 1, "\(pass): one session id, one line")
            let offered = try XCTUnwrap(scan.candidates.first)
            guard case .file(let offeredFile) = offered.location else { return XCTFail("\(pass): a file") }
            XCTAssertEqual(offeredFile.resolvingSymlinksInPath().path, full.resolvingSymlinksInPath().path,
                           "\(pass): the copy used last, not \(stale.deletingLastPathComponent().lastPathComponent)'s")
            XCTAssertEqual(offered.messageCount, 4)
            XCTAssertEqual(try scanner.read(offered)?.messageCount, 4)
        }

        // Same last use: the longer copy; same everything: always the same one.
        let a = ChatImportCandidate(source: .claudeCode, sourceID: "s", title: "t", updatedAt: iso("2026-09-22T23:15:00Z"),
                                    messageCount: 4, location: .file(stale))
        var b = a
        b.messageCount = 9
        b.location = .file(full)
        XCTAssertEqual(ChatImportCandidate.onePerID([b, a]).map(\.messageCount), [9])
        XCTAssertEqual(ChatImportCandidate.onePerID([a, b]).map(\.messageCount), [9])
        b.messageCount = 4
        XCTAssertEqual(ChatImportCandidate.onePerID([a, b]), ChatImportCandidate.onePerID([b, a]))
    }

    // MARK: Search

    private func searchDocs() -> [ChatSearchDocument] {
        let at = iso("2026-10-01T00:00:00Z")
        return [
            ChatSearchDocument(chatID: "a", title: "Résumé review", source: nil, updatedAt: at, rows: [
                .init(seq: 0, kind: "user", text: "Look at my resume please", at: at),
                .init(seq: 1, kind: "assistant", text: "Your résumé reads well; tighten the summary.", at: at),
            ]),
            ChatSearchDocument(chatID: "b", title: "Login fixes", source: .claudeCode, updatedAt: at.addingTimeInterval(60), rows: [
                .init(seq: 0, kind: "notice", text: "Imported from Claude Code", at: at),
                .init(seq: 1, kind: "user", text: "the login page shows a blank screen", at: at),
                .init(seq: 2, kind: "tool", text: "Bash npm test -- login PASS", more: "Tests: 3 passed (jest)", at: at),
            ]),
            ChatSearchDocument(chatID: "c", title: "Weekend", source: .chatGPT, updatedAt: at.addingTimeInterval(120), rows: [
                .init(seq: 0, kind: "user", text: "blank page in my notebook, and a resume tip", at: at),
            ]),
        ]
    }

    func testSearchFindsEveryWordAcrossTitlesAndTextIgnoringCaseAndAccents() {
        let docs = searchDocs()
        XCTAssertEqual(ChatSearch.search("RESUME", in: docs).map(\.chatID), ["a", "c"], "title matches first, then newest")
        XCTAssertEqual(ChatSearch.search("login blank", in: docs).map(\.chatID), ["b"], "every word, anywhere in the chat")
        XCTAssertEqual(ChatSearch.search("\"blank screen\"", in: docs).map(\.chatID), ["b"], "a quoted phrase is one word")
        XCTAssertEqual(ChatSearch.search("blank", in: docs).map(\.chatID), ["c", "b"])
        XCTAssertEqual(ChatSearch.search("blank", in: docs, scope: .source(.claudeCode)).map(\.chatID), ["b"])
        XCTAssertEqual(ChatSearch.search("resume", in: docs, scope: .madeHere).map(\.chatID), ["a"])
        XCTAssertEqual(ChatSearch.search("   ", in: docs), [])
        let hit = ChatSearch.search("npm", in: docs)[0]
        XCTAssertEqual(hit.seq, 2)
        XCTAssertEqual(hit.kind, "tool")
        XCTAssertEqual(hit.snippet, "Bash npm test -- login PASS")
        XCTAssertEqual(ChatSearch.snippet(String(repeating: "a ", count: 100) + "needle" + String(repeating: " b", count: 100),
                                          word: "needle", radius: 10),
                       "…a a a a a needle b b b b b…")
        XCTAssertEqual(ChatSearch.search("jest", in: docs).first?.snippet, "Tests: 3 passed (jest)", "a tool's output is searched too")
        XCTAssertEqual(ChatSearchDocument.searchText(kind: "tool", text: "ok", toolName: "Bash", argSummary: "ls"), "Bash ls ok")
        let row = ChatSearchDocument.row(seq: 1, kind: "tool", text: "ok", toolName: "Bash", argSummary: "ls",
                                         output: String(repeating: "y", count: 9_000), at: .now)
        XCTAssertEqual(row?.more.count, ChatSearchDocument.outputLimit)
        XCTAssertNil(ChatSearchDocument.searchText(kind: "todos", text: nil, toolName: nil, argSummary: nil))
    }

    // MARK: Small pieces

    func testDatesInTheShapesTheToolsWrite() {
        XCTAssertEqual(ImportDates.iso("2026-05-07T10:03:49.450383Z"), Date(timeIntervalSince1970: 1778148229.450))
        XCTAssertEqual(ImportDates.iso("2026-05-07T10:03:49Z"), Date(timeIntervalSince1970: 1778148229))
        XCTAssertEqual(ImportDates.iso("2026-05-07 10:03:49"), Date(timeIntervalSince1970: 1778148229))
        XCTAssertEqual(ImportDates.iso("2026-05-07T10:03:49.5-07:00"), Date(timeIntervalSince1970: 1778148229.5 + 7 * 3600))
        XCTAssertEqual(ImportDates.any(1788220802938), Date(timeIntervalSince1970: 1788220802.938))
        XCTAssertEqual(ImportDates.any(1767225600.5), Date(timeIntervalSince1970: 1767225600.5))
        XCTAssertNil(ImportDates.iso("yesterday"))
    }

    func testToolArgumentsAndLongTextAreShapedForCards() {
        XCTAssertEqual(ImportText.argSummary(["command": ["/bin/zsh", "-lc", "ls -la"]]), "ls -la")
        XCTAssertEqual(ImportText.argSummary(#"{"cmd":"pwd","workdir":"/x"}"#), "pwd")
        XCTAssertEqual(ImportText.argSummary(["b": 1, "a": "x"]), #"{"a":"x","b":1}"#)
        XCTAssertEqual(ImportText.clip(String(repeating: "x", count: 30), 10), "xxxxxxxxxx\n… [20 more characters not imported]")
        XCTAssertEqual(ImportText.title(fromPrompt: "\n\n## Fix the build\nmore"), "Fix the build")
        XCTAssertEqual(ImportText.stripReminders("a <system-reminder>x</system-reminder> b"), "a  b")
        var builder = ImportTranscriptBuilder()
        builder.toolCall(id: "1", name: "Bash", input: ["command": "sleep 1"], at: .now)
        XCTAssertEqual(builder.finish().first?.text, "no result recorded")
    }

    // MARK: The real files on this Mac (read-only; run with VISION_REAL_CHAT_IMPORT=1)

    func testRealSessionsOnThisMacScanAndRead() throws {
        guard ProcessInfo.processInfo.environment["VISION_REAL_CHAT_IMPORT"] == "1" else {
            throw XCTSkip("reads this Mac's real ~/.claude, ~/.codex and ~/.openclaw — set VISION_REAL_CHAT_IMPORT=1")
        }
        let scanner = ChatImportScanner(cacheFolder: dir.appendingPathComponent("cache"))
        for source in ChatSource.local where scanner.isPresent(source) {
            let started = Date()
            let scan = scanner.scan(source)
            let seconds = Date().timeIntervalSince(started)
            let again = Date()
            _ = scanner.scan(source)
            let cachedSeconds = Date().timeIntervalSince(again)
            let messages = scan.candidates.compactMap(\.messageCount).reduce(0, +)
            print("[real] \(source.label): \(scan.candidates.count) chats (\(scan.candidates.filter(\.automated).count) automated), \(messages) messages, scan \(String(format: "%.1f", seconds)) s, cached \(String(format: "%.2f", cachedSeconds)) s, problems: \(scan.problems.prefix(3))")
            for candidate in scan.candidates.prefix(3) {
                let readStart = Date()
                let chat = try scanner.read(candidate)
                print("[real]   \(candidate.title.prefix(50)) — preview \(candidate.messageCount ?? -1) / read \(chat?.messageCount ?? -1) messages, \(chat?.rows.count ?? 0) rows, \(String(format: "%.2f", Date().timeIntervalSince(readStart))) s")
                XCTAssertNotNil(chat)
            }
        }
    }
}
