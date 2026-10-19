import Foundation
import VisionHarnessCore

// MARK: - Screenshot mode: the Prompts timeline, the chat's tasks, background activity
//
// The made-up history and live state the new scenes show: a timeline with every kind of ending, a /goal at work with
// its plan, subagents on two model servers, three prompts queued after it, and a project with uncommitted changes.

extension SnapshotSeed {
    /// The main chat's timeline: earlier prompts with each kind of ending, and the run the chat scene shows.
    static func promptRecords(chatID: String, start: Date, finished: Date, state: TurnPhaseState) -> [PromptRecord] {
        let day: TimeInterval = 86_400
        var older = PromptRecord(chatID: chatID, text: "What does `ledger report` print for a month with no transactions?",
                                 source: .typed, at: start.addingTimeInterval(-3 * 3_600), outcome: .completed,
                                 finishedAt: start.addingTimeInterval(-3 * 3_600 + 41), etaSeconds: 20,
                                 taskKind: "research", model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock")
        older.evidence = [.init(kind: .check, title: "The model's closing summary",
                                detail: "An empty month prints its header and zero totals.", at: start.addingTimeInterval(-3 * 3_600 + 40))]
        older.completionNote = "Validated: the reply matches what was asked."
        let stopped = PromptRecord(chatID: chatID, text: "Rename `Ledger.load` to `Ledger.read` everywhere",
                                   source: .typed, at: start.addingTimeInterval(-day - 2 * 3_600), outcome: .stopped,
                                   finishedAt: start.addingTimeInterval(-day - 2 * 3_600 + 95), etaSeconds: 180,
                                   taskKind: "codeEdit", model: "Qwen/Qwen3-Coder-30B-A3B-Instruct", route: "DGX Spark",
                                   reason: "Stopped before it finished.")
        let failed = PromptRecord(chatID: chatID, text: "Run the benchmark suite and chart the results",
                                  source: .task, at: start.addingTimeInterval(-day - 3 * 3_600), outcome: .failed,
                                  finishedAt: start.addingTimeInterval(-day - 3 * 3_600 + 312), etaSeconds: 240, attempts: 1,
                                  taskKind: "buildRun", model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock",
                                  reason: "benchmarks/run.py: No module named 'matplotlib' — the suite needs it installed.")
        var main = PromptRecord(chatID: chatID, text: prompt, source: .typed, at: start, outcome: .completed,
                                finishedAt: finished, etaSeconds: state.etaSeconds, attempts: 1, taskKind: "codeEdit",
                                model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock",
                                promptTokens: 91_383, completionTokens: 4_452, turnID: state.turnID,
                                entryText: prompt, entryAt: start)
        main.evidence = state.evidence
        main.completionNote = "Validated against the plan: 6 of 6 steps done.\n\nAdded `--by-category`; the default output is byte-identical and 14 tests pass."
        return [failed, stopped, older, main]
    }

    /// Timelines for the other chats, so All Prompts has something from each.
    static func otherTimelines(now: Date) -> [String: [PromptRecord]] {
        let csv = "8C2D1F60-3B7E-4F2A-A1D9-6E5C4B3A2F10"
        let notes = "1E9B7A44-0C3D-4B8E-9F21-7D6A5C4B3E22"
        let quotas = "4F6E2B19-7A8C-4D3E-B5F0-1C2D3E4F5A33"
        return [
            csv: [PromptRecord(chatID: csv, text: "test_import_handles_bom fails about one run in five. Find out why and fix it.",
                               source: .goal, at: now.addingTimeInterval(-3 * 3_600 - 600), outcome: .completed,
                               finishedAt: now.addingTimeInterval(-3 * 3_600), etaSeconds: 300, attempts: 2, rounds: 3,
                               taskKind: "codeEdit", model: "Qwen/Qwen3-Coder-30B-A3B-Instruct", route: "DGX Spark",
                               evidence: [.init(kind: .runOutput, title: "20 runs in a row pass", detail: "")],
                               completionNote: "The fixture is written as UTF-8 with a BOM explicitly.")],
            notes: [PromptRecord(chatID: notes, text: "Draft release notes for 0.3.0 from the commits since 0.2.0.",
                                 at: now.addingTimeInterval(-26 * 3_600 - 120), outcome: .completed,
                                 finishedAt: now.addingTimeInterval(-26 * 3_600), etaSeconds: 120, taskKind: "writing",
                                 model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock")],
            quotas: [PromptRecord(chatID: quotas, text: "How do Bedrock quotas work for cross-region inference profiles?",
                                  at: now.addingTimeInterval(-52 * 3_600 - 40), outcome: .completed,
                                  finishedAt: now.addingTimeInterval(-52 * 3_600), etaSeconds: 75, taskKind: "research",
                                  model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock")],
        ]
    }

    /// The goal the tasks, activity and project-status scenes show at work.
    static let goalText = "Add CSV export to `ledger report` (--format csv), with tests, and update the README"

    /// Make the main chat look busy: a /goal on round 3 with its plan, two subagents on two servers working its
    /// steps, a background agent, and three prompts queued after it. Undone by `unstageBusy`.
    static func stageBusy(_ vm: SessionVM, transport: AppTransport) {
        let now = Date()
        let started = now.addingTimeInterval(-6 * 60 - 12)
        vm.running = true
        vm.goal = SessionVM.GoalState(text: goalText, round: 3, started: started)
        vm.todos = [
            TodoItem(id: "1", content: "Read how report rows are built", status: .completed),
            TodoItem(id: "2", content: "Add a CSV writer for report rows", status: .completed),
            TodoItem(id: "3", content: "Wire --format csv into the CLI", status: .inProgress),
            TodoItem(id: "4", content: "Write tests for the CSV output", status: .inProgress),
            TodoItem(id: "5", content: "Update the README", status: .pending),
        ]
        var state = TurnPhaseState(turnID: "busy-turn")
        state.beginPlanning(prompt: goalText, kind: .codeEdit, scope: 1.4, at: started)
        state.beginExecution(plan: vm.todos.map { "• \($0.content)" }.joined(separator: "\n"),
                             etaSeconds: 540, basis: "learned from 7 similar tasks", at: started.addingTimeInterval(30))
        state.addStep("read ledger/report.py", at: started.addingTimeInterval(70))
        state.addStep("write ledger/csv_out.py", at: started.addingTimeInterval(190))
        vm.turnPhase = state
        var record = PromptRecord(chatID: vm.id, text: goalText, source: .goal, at: started, outcome: .running,
                                  etaSeconds: 540, rounds: 3, taskKind: "codeEdit",
                                  model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock", turnID: state.turnID)
        record.entryText = "🎯 /goal \(goalText)"
        vm.promptHistory.append(record)
        vm.currentPromptID = record.id
        vm.turnPromptTokens = 48_210
        vm.turnCompletionTokens = 3_904
        transport.turnRoute[vm.id] = .init(model: "global.anthropic.claude-sonnet-5-5", route: "Amazon Bedrock")

        var cli = AgentRun(id: "s1", description: "Wire --format csv into the CLI", agentType: "worker",
                           isBackground: false, startedAt: now.addingTimeInterval(-95), activity: "edit: ledger/cli.py", steps: 6)
        cli.route = "DGX Spark"
        cli.model = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
        cli.assignment = "Wire --format csv into the CLI"
        cli.promptTokens = 0
        var tests = AgentRun(id: "s2", description: "Write tests for CSV output", agentType: "worker",
                             isBackground: false, startedAt: now.addingTimeInterval(-80),
                             activity: "run: python3 -m unittest tests.test_csv", steps: 4)
        tests.route = "Amazon Bedrock"
        tests.model = "global.anthropic.claude-haiku-4-5"
        tests.assignment = "Write tests for the CSV output"
        tests.placement = "its agent file asks for “spark-2”, which was busy or not answering"
        var explore = AgentRun(id: "s0", description: "Find how report rows are built", agentType: "explore",
                               isBackground: false, startedAt: now.addingTimeInterval(-300), status: .done,
                               activity: "done", steps: 9, finishedAt: now.addingTimeInterval(-240))
        explore.route = "DGX Spark"
        explore.model = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
        explore.assignment = "Read how report rows are built"
        var audit = AgentRun(id: "s3", description: "Audit README examples", agentType: "explore",
                             isBackground: true, startedAt: now.addingTimeInterval(-40), activity: "grep: ledger report", steps: 2)
        audit.route = "DGX Spark"
        audit.model = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
        vm.agentRuns = [explore, cli, tests, audit]

        transport.chatTasksPaused[vm.id] = nil
        for text in ["Run the whole suite again and paste the summary",
                     "Bump the version to 0.4.0 and add a changelog entry",
                     "/goal Publish a wheel to the local index and check it installs in a fresh venv"] {
            transport.queue.addChatTask(text, chatID: vm.id, cwd: vm.cwd)
        }
    }

    static func unstageBusy(_ vm: SessionVM, transport: AppTransport) {
        transport.chatTasksPaused[vm.id] = "Paused."
        transport.queue.removeChatTasks(vm.id)
        transport.queue = TaskQueue(tasks: transport.queue.tasks.filter { $0.chatID != vm.id })
        vm.running = false
        vm.goal = nil
        vm.agentRuns = []
        vm.currentPromptID = nil
        vm.promptHistory.removeAll { $0.outcome == .running }
        transport.chatTasksPaused[vm.id] = nil
    }
}
