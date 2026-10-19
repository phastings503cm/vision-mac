import Foundation

// MARK: - Claude Code as a subagent server
//
// A route on Claude Code that is ticked "Use for subagents" works a chat's side tasks the way Claude Code works: each
// task is one `claude -p` in the chat's folder (its scratch folder without a project), with no session kept, under the
// chat's permissions (Plan only for a read-only agent type) — its permission questions answered as a chat turn's are,
// the person asked on the chat's own card. Its last message is the report, followed by the list of tool calls it made,
// and goes back to the main agent like any subagent's. Stopping the task stops the CLI (interrupt, then the signals).
// What it changes in a git repository is recorded into the parent turn's checkpoint, so Rewind covers it. Claude Code
// is never private: it never takes a sensitive task and is never in a Sensitive chat's pool (see `SubagentPool`).

public struct ClaudeCodeSubagent: ExternalSubagent {
    /// What every job is told first (the same words on Windows).
    public static let note = "You are running inside Vision as a subagent of another model's chat. Work the task in the message on your own: don't ask questions; make reasonable assumptions and state them. Your final message is your report — it goes back to the main agent, not to a person: keep it concise and factual, and list each file you changed."
    /// The report when Claude Code wrote nothing.
    public static let noReply = "(Claude Code worked on this without a written reply.)"
    /// In front of the report when it ran out of steps.
    public static let stepLimitPrefix = "It reached its step limit before finishing. "
    /// What a checkpoint records as having changed a file.
    public static let checkpointTool = "claude code subagent"
    /// Vision's names for the tools that change the workspace (Claude Code's Edit, MultiEdit, NotebookEdit, Write, Bash).
    public static let mutatingTools: Set<String> = ["edit", "write_file", "run_shell_command"]
    /// How many tool calls the report lists.
    static let listedCalls = 40

    public let install: ClaudeCodeInstall
    public let launcher: any ClaudeCodeLauncher
    public let environment: [String: String]
    /// The route's Claude Code alias ("sonnet").
    public let model: String
    /// `--effort` from the route's own thinking level (nil = Claude Code's default).
    public let effort: String?
    /// Whether the person trusted a folder in Claude Code (then its own settings load).
    public let isTrusted: @Sendable (URL, [String: String]) -> Bool

    public init(install: ClaudeCodeInstall, launcher: any ClaudeCodeLauncher, environment: [String: String], model: String,
                effort: String? = nil, isTrusted: @escaping @Sendable (URL, [String: String]) -> Bool = { _, _ in false }) {
        self.install = install
        self.launcher = launcher
        self.environment = environment
        self.model = model
        self.effort = effort
        self.isTrusted = isTrusted
    }

    /// The command line of one job.
    public func invocation(for job: ExternalSubagentJob, projectSettings: Bool) -> ClaudeCodeInvocation {
        // Without --no-session-persistence a fresh id at least keeps it apart from every chat's session.
        let keepsSessions = !install.supports("--no-session-persistence")
        return ClaudeCodeInvocation(model: model, effort: effort, preset: job.preset,
                                    session: keepsSessions ? .new(UUID().uuidString.lowercased()) : nil,
                                    appendSystemPrompt: job.systemNote, projectSettings: projectSettings,
                                    maxTurns: job.maxSteps, noSessionPersistence: true)
    }

    public func run(_ job: ExternalSubagentJob) async throws -> ExternalSubagentResult {
        // A folder whose own Claude Code settings can't be left out runs nothing (headless, its hooks would run unasked).
        let folder = ClaudeCodeTrust.settings(for: job.workspace, install: install, trusted: isTrusted(job.workspace, environment))
        if case .cantSkip(let files) = folder {
            throw ClaudeCodeError.untrustedFolder(ClaudeCodeTrust.cantSkipMessage(version: install.version, files: files))
        }
        let policy = PermissionPolicy(preset: job.preset, workspaceRoot: job.workspace)
        let ask = job.requestPermission
        let decide: @Sendable (ClaudeCodePermissionRequest) async -> ClaudeCodePermissionDecision = { request in
            let decision = ClaudeCodePermissions.decide(request, policy: policy)
            guard case .ask(let name, let detail) = decision else { return decision }
            return await ask(request.toolUseID ?? request.requestID, name, detail) ? .allow : .deny(ClaudeCodePermissions.declined)
        }
        let log = ToolLog()
        // What it changes in a git repository goes into the parent turn's checkpoint, as a shell command's does.
        let checkpoint = TurnCheckpoint.current
        let workspace = job.workspace
        let baseline = await RunShellCommandTool.offPool { checkpoint?.gitBaseline(in: workspace) }
        let outcome = try await ClaudeCodeTurn.run(
            install: install, invocation: invocation(for: job, projectSettings: folder.loadsProjectSettings),
            message: ClaudeCodeInput.line(text: job.prompt), workspace: job.workspace, environment: environment,
            launcher: launcher, decide: decide) { event in
            switch event {
            case .engine(.toolStarted(let id, let name, let preview)):
                guard log.start(id: id, name: name, preview: preview) else { return }
                job.activity("\(name): \(String(preview.prefix(60)))", true)
                if Self.mutatingTools.contains(name) { job.noteMutation() }
            case .engine(.toolFinished(let id, _, let ok, _, _)):
                if !ok { log.fail(id: id) }
            case .activity(let text?):
                job.activity(text, false)
            default:
                break
            }
        }
        if let checkpoint, let baseline {
            await RunShellCommandTool.offPool { checkpoint.recordGitChanges(since: baseline, by: Self.checkpointTool) }
        }
        if outcome.interrupted { throw CancellationError() }
        let hitTurnLimit = outcome.result?.subtype == "error_max_turns"
        if let failure = outcome.failure, !hitTurnLimit {
            if case .rateLimited(let sentence) = failure {
                // The plan's limit: keep subagent work off Claude Code until it resets.
                throw SubagentServerPaused(message: sentence, until: outcome.rateLimit?.resetsAt)
            }
            throw failure
        }
        let usage = outcome.usage ?? outcome.result?.usage
        return ExternalSubagentResult(ok: true,
                                      report: Self.report(reply: outcome.lastReplyText, toolLog: log.entries,
                                                          hitTurnLimit: hitTurnLimit),
                                      mutated: log.mutated, promptTokens: usage?.promptTokens ?? 0,
                                      completionTokens: usage?.completionTokens ?? 0, costUSD: outcome.result?.totalCostUSD)
    }

    /// The report: Claude Code's last message (or a line saying it wrote none), then the tool calls it made — so the
    /// main agent sees what was done even when the reply doesn't say. (The same text on Windows.)
    public static func report(reply: String, toolLog: [String], hitTurnLimit: Bool) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = noReply }
        if !toolLog.isEmpty {
            let shown = toolLog.prefix(listedCalls)
            let more = toolLog.count - shown.count
            text += "\n\nClaude Code's tool calls: " + shown.joined(separator: "; ") + (more > 0 ? "; … and \(more) more" : "") + "."
        }
        return hitTurnLimit ? stepLimitPrefix + text : text
    }

    /// The calls a job made, in order: "read_file hello.txt", "run_shell_command swift test (failed)".
    final class ToolLog: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = []
        private var calls: [String: (name: String, preview: String, failed: Bool)] = [:]

        /// Whether this is a call it hadn't seen.
        func start(id: String, name: String, preview: String) -> Bool {
            lock.withLock {
                guard calls[id] == nil else { return false }
                order.append(id)
                calls[id] = (name, preview, false)
                return true
            }
        }

        func fail(id: String) {
            lock.withLock { calls[id]?.failed = true }
        }

        var entries: [String] {
            lock.withLock {
                order.compactMap { id in
                    guard let call = calls[id] else { return nil }
                    let preview = call.preview.trimmingCharacters(in: .whitespaces)
                    return (preview.isEmpty ? call.name : "\(call.name) \(preview)") + (call.failed ? " (failed)" : "")
                }
            }
        }

        var mutated: Bool {
            lock.withLock { calls.values.contains { ClaudeCodeSubagent.mutatingTools.contains($0.name) } }
        }
    }
}
