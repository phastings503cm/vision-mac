import Foundation
import VisionHarnessCore

/// The made-up workspace the screenshot mode opens: a small Python project, a few chats, and a set of model routes.
/// Everything is written into the isolated folder (`IsolatedRun`); nothing here has a secret in it.
@MainActor
enum SnapshotSeed {
    /// The chat the screenshots are about.
    static let mainChatID = "5A1C0E8B-6D4F-4C1A-9E57-2F0B7D3A9C11"
    static let projectName = "ledger"
    /// The files code mode has open; the last one shows.
    static let codeSceneFiles = ["tests/test_report.py", "ledger/report.py"]
    /// Code mode's editor scrolls to what the agent added.
    static let codeSceneAnchor = "def category_totals"
    /// What code mode's terminal runs.
    static let terminalCommand = "python3 -m unittest && python3 -m ledger report data/*.csv --by-category --month 2026-10"

    /// What the user asks in the chat (the live run sends it for real).
    static let prompt = """
        Add a `--by-category` option to `ledger report` that breaks each month's spending down by category, \
        biggest first. Without the flag the output must stay exactly as it is. Plan it as a checklist and tick \
        items off as you go, add tests, and run the whole suite.
        """

    /// The model routes Settings ▸ AI Models lists. The first is the main model.
    static func routes(live: Snapshot.Live?) -> [ProviderProfile] {
        [
            ProviderProfile(kind: .bedrock, name: "Amazon Bedrock", baseURL: "",
                            model: live?.model ?? "global.anthropic.claude-sonnet-5-5",
                            awsProfile: live?.profile ?? AppIdentity.awsProfile, awsRegion: live?.region ?? "us-west-2"),
            ProviderProfile(kind: .openAICompat, name: "DGX Spark", baseURL: "http://spark.local:8000/v1",
                            model: "Qwen/Qwen3-Coder-30B-A3B-Instruct", contextWindow: 131_072,
                            subagentWorker: true, isPrivate: true),
            ProviderProfile(kind: .openRouter, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                            model: "z-ai/glm-4.6", backup: true),
            ProviderProfile(kind: .ollama, name: "Ollama", baseURL: "http://127.0.0.1:11434/v1",
                            model: "gpt-oss:20b", enabled: false),
        ]
    }

    /// Routes the provider scenes add: Kimi K2.7 Code on Moonshot, GLM-5.3 on Z.ai's General API (no keys).
    static let kimiRoute = ProviderProfile(kind: .openAICompat, name: "Moonshot", baseURL: "https://api.moonshot.ai/v1",
                                           model: "kimi-k2.7-code")
    static let zaiRoute = ProviderProfile(kind: .openAICompat, name: "Z.ai API", baseURL: ZAIErrors.Endpoint.general.baseURL,
                                          model: "glm-5.3")

    // MARK: Writing it

    /// Write the workspace into `home` (the isolated home folder) and the app's isolated settings and data folder.
    static func install(home: URL, live: Snapshot.Live?) {
        let projects = home.appendingPathComponent("Projects", isDirectory: true)
        let project = projects.appendingPathComponent(projectName, isDirectory: true)
        write(SnapshotProject.files, into: project)
        git(["init", "-q", "-b", "main"], in: project)
        git(["add", "-A"], in: project)
        git(["-c", "user.name=Vision", "-c", "user.email=vision@example.com", "commit", "-q", "-m", "ledger 0.3.0"],
            in: project)
        if live == nil {
            // The seeded chat's run already happened: the project is as the agent left it.
            write(SnapshotProject.changes, into: project)
        }
        var recents = [project.path]
        for other in ["storefront-api", "field-notes-ios"] {
            let folder = projects.appendingPathComponent(other, isDirectory: true)
            write(["README.md": "# \(other)\n"], into: folder)
            recents.append(folder.path)
        }

        let config = AppConfig.shared
        // These routes and no others (a new settings file starts with examples).
        let routes = routes(live: live)
        config.providers = routes
        config.activeRoute = routes[0].routeID
        config.preset = PermissionPreset.workspaceWrite.rawValue
        config.recentProjects = recents
        config.wizardCompleted = true
        config.lastMode = WorkspaceMode.chat.rawValue
        config.planPanelOpen = true
        // The agent never drives this Mac from here.
        config.computerToolsEnabled = false

        installChats(project: project, live: live)
    }

    private static func installChats(project: URL, live: Snapshot.Live?) {
        let log = ConversationLog.shared
        let now = Date()
        func chat(_ id: String, _ title: String, cwd: String?, ago: TimeInterval, _ rows: [(MessageBody.Role, String)]) {
            let updated = now.addingTimeInterval(-ago)
            let entries = rows.enumerated().map { index, row in
                ChatEntry(at: updated.addingTimeInterval(Double(index - rows.count) * 40), kind: .message(.init(role: row.0, text: row.1)))
            }
            log.store(LogSession(id: id, title: title, cwd: cwd, preset: PermissionPreset.workspaceWrite.rawValue,
                                 updatedAt: updated),
                      items: AppTransport.logRows(for: entries, sessionID: id))
        }
        chat("8C2D1F60-3B7E-4F2A-A1D9-6E5C4B3A2F10", "Fix the flaky CSV import test", cwd: project.path, ago: 3 * 3_600, [
            (.user, "test_import_handles_bom fails about one run in five. Find out why and fix it."),
            (.assistant, "The test wrote its fixture with the system default encoding, so the BOM check depended on the machine. It now writes UTF-8 with a BOM explicitly; 20 runs in a row pass."),
        ])
        chat("1E9B7A44-0C3D-4B8E-9F21-7D6A5C4B3E22", "Draft release notes for 0.3.0", cwd: project.path, ago: 26 * 3_600, [
            (.user, "Draft release notes for 0.3.0 from the commits since 0.2.0."),
            (.assistant, "## 0.3.0\n- `--month` limits the report to one month\n- Blank categories are reported as Uncategorized\n- Amounts are exact (Decimal), so totals no longer drift by a cent"),
        ])
        chat("4F6E2B19-7A8C-4D3E-B5F0-1C2D3E4F5A33", "How do Bedrock quotas work?", cwd: nil, ago: 52 * 3_600, [
            (.user, "How do Bedrock quotas work for cross-region inference profiles?"),
            (.assistant, "Each model has requests-per-minute and tokens-per-minute quotas per Region; a global inference profile spreads requests over several Regions and draws on its own quota. You can see and request increases in Service Quotas."),
        ])

        let timelines = PromptTimelineStore(directory: AppPaths.support.appendingPathComponent("prompt-timeline", isDirectory: true))
        for (chatID, records) in otherTimelines(now: now) { timelines.save(chatID, records) }

        guard live == nil, let transcript = transcript else { return }
        let start = now.addingTimeInterval(-transcript.duration - 120)
        let entries = transcript.entries(startingAt: start)
        log.store(LogSession(id: mainChatID, title: transcript.title, cwd: project.path,
                             preset: PermissionPreset.workspaceWrite.rawValue,
                             updatedAt: start.addingTimeInterval(transcript.duration)),
                  items: AppTransport.logRows(for: entries, sessionID: mainChatID))
    }

    /// What a stored chat doesn't keep — the plan, tool cards' order with the plan between them, the files the agent
    /// changed, the last turn's usage — put back on the seeded chat once it is open.
    static func restoreLiveState(of vm: SessionVM) {
        guard let transcript else { return }
        let start = vm.entries.first?.at ?? Date().addingTimeInterval(-transcript.duration - 120)
        vm.entries = transcript.entries(startingAt: start)
        vm.todos = transcript.finalTodos
        if let prompt = transcript.promptTokens, let completion = transcript.completionTokens {
            vm.lastUsage = LLMUsage(promptTokens: prompt, completionTokens: completion)
        }
        vm.contextUsed = transcript.contextUsed
        if let root = vm.workspaceURL {
            let edited = transcript.rows.filter { $0.kind == "tool" && ["edit", "write_file"].contains($0.name ?? "") }
            vm.changedFiles = []
            vm.recordFileChanges(edited.compactMap { row in
                guard let path = row.preview?.split(separator: " ").first.map(String.init), !path.isEmpty else { return nil }
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                return FileChange(url, SnapshotProject.files[path] == nil ? .created : .modified)
            })
        }
        seedPhases(of: vm, start: start)
    }

    /// The finished turn's phases and the chat's prompt history, so the
    /// screenshots show the results card and the prompt timeline.
    private static func seedPhases(of vm: SessionVM, start: Date) {
        guard let transcript else { return }
        let finished = start.addingTimeInterval(transcript.duration)
        var state = TurnPhaseState(turnID: "seeded-turn")
        state.beginPlanning(prompt: prompt, kind: .codeEdit, scope: 1.6, at: start)
        state.draft = "Add a `--by-category` flag to `ledger report`: extend the parser, group each month's lines by category, sort by total, and leave the default output byte-identical. Covered by new tests."
        state.beginExecution(plan: transcript.finalTodos.map { "• \($0.content)" }.joined(separator: "\n"),
                             etaSeconds: 210, basis: "learned from 5 similar tasks", at: start.addingTimeInterval(35))
        state.addStep("read ledger/report.py, cli.py", at: start.addingTimeInterval(60))
        state.addStep("edit report.py — added category_totals()", at: start.addingTimeInterval(120))
        state.addStep("edit cli.py — added --by-category", at: start.addingTimeInterval(180))
        state.addStep("run python3 -m unittest — 14 tests pass", at: start.addingTimeInterval(240))
        state.filesChanged = 4
        state.addEvidence(.init(kind: .runOutput, title: "Full suite passes — 14 tests, 0 failures",
                                detail: "python3 -m unittest → Ran 14 tests in 0.412s · OK", at: finished.addingTimeInterval(-14)))
        state.addEvidence(.init(kind: .file, title: "4 files changed",
                                detail: "report.py, cli.py, test_report.py, README.md", at: finished.addingTimeInterval(-12)))
        state.addEvidence(.init(kind: .check, title: "Matches the plan — 6 of 6 steps done",
                                detail: "Default output byte-identical to the pre-change baseline.", at: finished.addingTimeInterval(-9)))
        state.beginResults(summary: "Validated against the plan: 6 of 6 steps done.", at: finished)
        vm.turnPhase = state
        vm.promptHistory = promptRecords(chatID: vm.id, start: start, finished: finished, state: state)
        vm.promptHistoryLoaded = true
    }

    /// The seeded chat (made from a live run's `chat-transcript.json`).
    static var transcript: SnapshotTranscript? {
        try? JSONDecoder().decode(SnapshotTranscript.self, from: Data(SnapshotChat.json.utf8))
    }

    // MARK: Helpers

    private static func write(_ files: [String: String], into folder: URL) {
        let fileManager = FileManager.default
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let body = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs git on the PATH (in the isolated home); a Mac without it gets a project without history.
    private static func git(_ arguments: [String], in folder: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}

/// The Z.ai guide's scripted backend for the screenshot mode: the General API answers 1113 ("no balance"), the
/// Coding Plan endpoint answers — what a GLM Coding Plan key on the wrong endpoint looks like. No network.
@MainActor
final class SnapshotPlanBackend: PlanGuideBackend {
    func listModels(route: ProviderProfile) async throws -> [String] { ["glm-5.3", "glm-5.2", "glm-4.7"] }

    func ping(route: ProviderProfile, model: String) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        if route.baseURL == ZAIErrors.Endpoint.general.baseURL {
            throw LLMError.rejected(status: 429, message: "",
                                    body: #"{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}"#,
                                    permanent: true)
        }
    }

    func sayHello(route: ProviderProfile) async throws -> String { "Hello!" }
    func open(_ url: URL) {}
}
