import Foundation

// MARK: - agent (subagents)
//
// Spawns a child `Engine` that works a self-contained task in a bounded loop, then returns a final
// report. The child inherits the parent's permission gate, workspace and policy; it does NOT inherit
// the agent tools themselves (no nested subagents). What it *is* depends on its agent type (see
// `AgentDefinition`): a read-only explorer, a planner, a reviewer, an implementer, or one the user
// defined. Where it *runs* depends on the fleet: with several model servers, subagents go to the
// workers (least loaded first) and fall back to the primary, and a server that fails hands the task to
// another one.

public struct AgentTool: ToolExecutor {
    public static let name = "agent"
    public static let spec: ToolSpec = AgentTool.spec(for: .default)

    /// A subagent's default step budget; agent types may set their own.
    private static let defaultMaxSteps = 30
    /// How many times a task moves to another server after its server fails.
    private static let maxFailovers = 2

    /// The agent types the tool's description offers (nil = the built-in ones). Which types a call may
    /// *use* comes from the context (`ToolContext.agentTypes`), the chat's own definitions.
    public let catalog: AgentCatalog?
    /// The subagent servers and whether each is private, for the description (nil = not said).
    public let servers: [SubagentServers.Entry]?

    public init(catalog: AgentCatalog? = nil, servers: [SubagentServers.Entry]? = nil) {
        self.catalog = catalog
        self.servers = servers
    }

    public var spec: ToolSpec { Self.spec(for: catalog ?? .default, servers: servers) }

    public static func spec(for catalog: AgentCatalog, servers: [SubagentServers.Entry]? = nil) -> ToolSpec {
        var description = "Spawn a subagent to work a self-contained task (e.g. 'find every usage of X and report the call sites'). It works autonomously in a bounded loop and returns a final report. Prefer this over doing long exploration yourself when the task is well-scoped. "
            + "Pick agent_type for a specialist — " + catalog.describe() + ". Omit it for the general worker. "
            + "Several agent calls in one turn run at the same time. Set run_in_background to true to launch it in the background and keep working: check on it with agent_status (you're also told automatically when one finishes) and stop one with agent_stop. To fan out many independent tasks in one go, use `delegate`."
        if let note = SubagentServers.note(servers ?? []) { description += " " + note }
        return ToolSpec(
            name: name,
            description: description,
            parameters: #"{"type":"object","properties":{"description":{"type":"string","description":"What to name this subagent"},"prompt":{"type":"string","description":"The complete task for the subagent. It cannot ask you questions and cannot see this conversation — everything it needs goes here."},"agent_type":{"type":"string","description":"The kind of subagent (default: general)"},"run_in_background":{"type":"boolean","description":"Start it in the background and return at once (default false: wait for its report)"},"sensitive":{"type":"boolean","description":""#
                + SubagentServers.sensitiveParameter + #""}},"required":["description","prompt"]}"#
        )
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let desc = Self.string(args, "description") ?? "subagent"
        let prompt = Self.string(args, "prompt") ?? ""
        guard !prompt.isEmpty else {
            return ToolResult(output: "Error: prompt is required.")
        }
        guard context.depth < 1 else {
            return ToolResult(output: "Error: nested subagents are not allowed (depth limit).")
        }
        let types = context.agentTypes ?? .default
        let typeName = Self.string(args, "agent_type")
        guard let definition = types.find(typeName) else {
            return ToolResult(output: "Error: unknown agent_type '\(typeName ?? "")'. Available: \(types.describe()).")
        }
        let sensitive = JSONArgs.bool(args, "sensitive", default: false)

        if JSONArgs.bool(args, "run_in_background", default: false) {
            guard let pool = context.backgroundAgents else {
                return ToolResult(output: "Error: background subagents aren't available here; call agent without run_in_background.")
            }
            // The background run belongs to the pool (stop / agent_stop cancel it), not to this call.
            let launched = pool.launch(description: desc, work: {
                let outcome = try await Self.runCore(prompt: prompt, description: desc, definition: definition,
                                                     background: true, sensitive: sensitive, context: context)
                return (outcome.ok, outcome.report)
            })
            switch launched {
            case .success(let job):
                return ToolResult(output: "Started background agent \(job.id) “\(desc)”. It works while you continue — you'll be told automatically when it finishes; agent_status {\"id\":\"\(job.id)\",\"wait_seconds\":120} waits for it, agent_stop stops it.")
            case .failure(let error):
                return ToolResult(output: "Error: " + (error.errorDescription ?? "can't start another background agent."))
            }
        }

        do {
            let outcome = try await Self.runCore(prompt: prompt, description: desc, definition: definition,
                                                 background: false, sensitive: sensitive, context: context)
            return ToolResult(output: Self.present(description: desc, outcome: outcome))
        } catch {
            return ToolResult(output: "Error: cancelled by user.")
        }
    }

    /// The report as the parent sees it. The first line keeps a fixed shape; a specialist type or a named
    /// server is added on a line of its own.
    static func present(description: String, outcome: SubagentOutcome) -> String {
        var text = outcome.ok ? "Subagent '\(description)' finished." : "Subagent '\(description)' failed: \(outcome.report)"
        let details = outcome.details()
        if !details.isEmpty { text += "\n" + details }
        if outcome.ok { text += "\n\n" + outcome.report }
        return text
    }

    /// Run a general subagent to completion; returns its report (or the failure).
    static func run(desc: String, prompt: String, context: ToolContext) async -> (ok: Bool, report: String) {
        guard let outcome = try? await runCore(prompt: prompt, description: desc, definition: AgentDefinition.builtIn[0],
                                               background: false, context: context) else {
            return (false, "Stopped before it finished.")
        }
        return (outcome.ok, outcome.report)
    }

    // MARK: Running

    /// The whole life of one subagent: wait for a server, run, fail over if the server dies, and keep the
    /// roster current. Throws only `CancellationError` (the run was stopped); every other way it can end is
    /// an outcome.
    static func runCore(prompt firstPrompt: String, description: String, definition: AgentDefinition,
                        background: Bool, sensitive: Bool = false, context: ToolContext) async throws -> SubagentOutcome {
        let roster = context.roster
        let runID = roster?.begin(description: description, agentType: definition.name, background: background,
                                  prompt: firstPrompt)
        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> TimeInterval {
            let duration = started.duration(to: clock.now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        var failovers = 0
        var firstServer: String?
        // The report names the server only when there was a choice of servers; a lone one is just "the model".
        let choice = (context.fleet?.servers.count ?? 0) > 1
        func named(_ label: String?) -> String? { choice ? label : nil }
        var prompt = firstPrompt
        let trace = AttemptTrace()
        do {
            while true {
                var lease: FleetLease?
                let target: FleetTarget
                if let fleet = context.fleet {
                    if let runID { roster?.note(runID, "waiting for a free server") }
                    do {
                        // A task that needs sensitive data runs only on a private server.
                        lease = try await fleet.acquire(preferred: definition.server, sensitive: sensitive,
                                                        unattended: context.unattended, home: context.fleetHome)
                    } catch let unavailable as FleetUnavailableError {
                        if let runID { roster?.finish(runID, status: .failed, report: unavailable.message) }
                        return SubagentOutcome(ok: false, report: unavailable.message, agentType: definition.name,
                                               server: named(firstServer), elapsed: elapsed(), failovers: failovers)
                    }
                    let leased = lease!
                    target = leased.target
                    if firstServer == nil { firstServer = leased.label }
                    if let runID, choice { roster?.setServer(runID, leased.label) }
                    if let runID {
                        roster?.setPlacement(runID, route: leased.label, model: target.model,
                                             note: Self.placementNote(definition: definition, lease: leased, fleet: fleet))
                    }
                } else {
                    // No fleet: it would run on the chat's own model — for a sensitive task, only if that is private.
                    if sensitive, (context.client as? any ProviderClient)?.profile.isPrivateRoute != true {
                        if let runID { roster?.finish(runID, status: .failed, report: AgentFleet.noPrivateServer) }
                        return SubagentOutcome(ok: false, report: AgentFleet.noPrivateServer, agentType: definition.name,
                                               server: nil, elapsed: elapsed(), failovers: failovers)
                    }
                    target = FleetTarget(client: context.client, model: context.model, contextWindow: context.contextWindow)
                    if let runID { roster?.setPlacement(runID, route: "this chat's model", model: context.model) }
                }

                do {
                    // With one server there is nowhere to fail over to: wait it out as long as the main agent would.
                    let (ok, report) = try await runEngine(prompt: prompt, definition: definition, target: target, context: context,
                                                           runID: runID, boundedRetries: choice, trace: trace)
                    lease?.release()
                    if let runID { roster?.finish(runID, status: ok ? .done : .failed, report: report) }
                    return SubagentOutcome(ok: ok, report: report, agentType: definition.name,
                                           server: named(lease?.label ?? firstServer), elapsed: elapsed(), failovers: failovers)
                } catch where error is CancellationError || Task.isCancelled {
                    lease?.abandon()
                    lease?.release()
                    throw CancellationError()
                } catch where choice && lease != nil && AgentFleet.isServerFault(error) && failovers < Self.maxFailovers {
                    // The server, not the task, was the problem: another one may not have it.
                    let failed = lease!
                    failed.fail(error)
                    failed.release()
                    failovers += 1
                    // The task starts again from the top on the next server — after work that already changed things,
                    // it has to look before it repeats a step (a migration, a commit, a deploy).
                    if trace.mutated { prompt = Self.interruptedNote + firstPrompt }
                    if let runID { roster?.note(runID, "\(failed.label) failed — trying another server") }
                } catch {
                    lease?.fail(error)
                    lease?.release()
                    let message = error.localizedDescription
                    if let runID { roster?.finish(runID, status: .failed, report: message) }
                    return SubagentOutcome(ok: false, report: message, agentType: definition.name,
                                           server: named(lease?.label ?? firstServer), elapsed: elapsed(), failovers: failovers)
                }
            }
        } catch is CancellationError {
            if let runID { roster?.finish(runID, status: .stopped, report: "Stopped before it finished.") }
            throw CancellationError()
        }
    }

    /// Why a subagent runs where it does when that isn't the obvious place: its agent file asked for a server it
    /// didn't get, or servers tried first couldn't take it. Nil when it runs where it was meant to.
    static func placementNote(definition: AgentDefinition, lease: FleetLease, fleet: AgentFleet) -> String? {
        var notes: [String] = []
        if let wanted = definition.server, !wanted.isEmpty, !AgentFleet.matches(lease.server, preferred: wanted) {
            if fleet.servers.contains(where: { AgentFleet.matches($0, preferred: wanted) }) {
                notes.append("its agent file asks for “\(wanted)”, which was busy or not answering")
            } else {
                notes.append("its agent file asks for “\(wanted)”, but no model server by that name is set up (Settings ▸ AI Models: turn on “Use for subagents” for that route)")
            }
        }
        if !lease.skipped.isEmpty {
            notes.append("tried first: " + lease.skipped.map { String($0.prefix(140)) }.joined(separator: "; "))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private static let interruptedNote =
        "[Note: an earlier attempt at this task was cut short when its model server failed, after it had already changed things. "
        + "Look at the current state of the workspace first and do not repeat steps that are already done.]\n\n"

    /// Tools that never change the workspace, so running one leaves nothing a retry must know about.
    /// (The same list as the tool cache's read-only set in the Windows app.)
    static let nonMutatingTools: Set<String> = [
        "read_file", "read_many_files", "glob", "grep", "list_directory", "web_fetch", "todo_write", "exit_plan_mode",
        "use_skill", "vault_search", "memory_search", "memory_save", "memory_forget", "goal_complete",
        "goal_blocked", "queue_task", "propose_skill",
    ]

    /// What an attempt did that a retry must know about.
    private final class AttemptTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false
        var mutated: Bool { lock.withLock { changed } }
        func noteMutation() { lock.withLock { changed = true } }
    }

    /// A tool as the subagent's registry holds it: it notes when a call really starts running. Only a call that
    /// got that far can have changed anything — not one that was denied, refused or left unrun — and only the
    /// tool itself knows it was reached, past the permission and credential checks.
    private struct WatchedTool: ToolExecutor {
        /// Unused: the registry looks a tool up by its instance name, which is the wrapped tool's.
        static let name = "watched"
        static let spec = ToolSpec(name: "watched", description: "", parameters: "{}")

        let inner: any ToolExecutor
        let trace: AttemptTrace

        var name: String { inner.name }
        var spec: ToolSpec { inner.spec }

        func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
            if !AgentTool.nonMutatingTools.contains(inner.name) { trace.noteMutation() }
            return await inner.execute(args: args, in: context)
        }
    }

    private static func runEngine(prompt: String, definition: AgentDefinition, target: FleetTarget, context: ToolContext,
                                  runID: String?, boundedRetries: Bool, trace: AttemptTrace) async throws -> (ok: Bool, report: String) {
        // Same capabilities as the parent, minus the agent tools themselves: start from the parent's registry
        // and drop them. That way a process the parent launched is readable here, and a "debug this game
        // window" task can screenshot and drive without the parent relaying every observation.
        // (goal_complete / goal_blocked are the /goal loop's: a subagent must not end the parent's goal.)
        var registry = context.registry.removing(AgentTool.name, DelegateTool.name, AgentStatusTool.name, AgentStopTool.name,
                                                 QueueAddTool.name, "goal_complete", "goal_blocked")
        if let allowed = definition.tools, !allowed.isEmpty { registry = registry.only(allowed) }
        if let denied = definition.disallowedTools, !denied.isEmpty { registry = registry.removing(denied) }
        registry = registry.mapping { WatchedTool(inner: $0, trace: trace) }

        let window = target.contextWindow ?? context.contextWindow
        // On a fleet, a server that keeps failing should hand the task on, not be waited on for ever:
        // two quick retries, then the task moves to another server.
        let retry: RetryPolicy
        if boundedRetries {
            var bounded = context.retry ?? RetryPolicy(delay: { TimeInterval(min($0, 2)) })
            bounded.maxFailures = 2
            retry = bounded
        } else {
            retry = context.retry ?? .standard
        }
        let settings = Self.settings(for: target, context: context)
        var config = EngineConfig(
            maxIterations: definition.maxSteps ?? Self.defaultMaxSteps,
            toolTimeout: 300,
            model: target.model,
            // The leased server's own settings when it has them (a worker without vision must not be sent screenshots).
            temperature: settings.temperature,
            maxOutputTokens: settings.maxOutputTokens,
            contextWindow: window,
            thinking: settings.thinking,
            visionEnabled: target.vision ?? context.visionEnabled,
            retry: retry
        )
        // Out of steps, a subagent still owes its caller a report.
        config.wrapUpAtLimit = true
        config.depth = context.depth + 1

        let client = target.client
        let model = target.model
        let engine = Engine(
            client: client,
            registry: registry,
            systemPrompt: Self.subagentPrompt(workspace: context.workspace,
                                              permissionPreset: context.policy.preset,
                                              definition: definition),
            config: config,
            workspace: context.workspace,
            policy: context.policy,
            permissionGate: context.requestPermission,
            onTodos: { _ in },
            compaction: { used, messages in
                // Same window the parent resolved (server probe, override, or fallback) — without this, a
                // long subagent task runs uncompacted until it hits the server's hard limit. A subagent's
                // run is one `.user` message followed by many tool round-trips, never a second one — the
                // default user-only boundary would never find a cut, so it opts into the assistant-boundary
                // rule (still never orphans a call from its own result).
                guard let limit = window,
                      let plan = Compaction.plan(usedTokens: used, limit: limit, transcript: messages,
                                                 allowAssistantBoundary: true) else {
                    return messages
                }
                guard let summary = await Compaction.summarize(client: client, plan: plan, model: model) else {
                    return messages
                }
                return [LLMMessage(role: .system, content: Compaction.summaryHeader + summary)] + plan.toKeep
            },
            vault: context.vault,
            vaultGrants: context.vaultGrants,
            // Same chat to the machine (its name, its scope), its own place in line for the mouse.
            machineSeat: context.machine?.child()
        )

        let roster = context.roster
        let result = try await engine.run(messages: [], userText: prompt, sink: { event in
            guard let runID, let roster else { return }
            switch event {
            case .toolStarted(_, let name, let preview):
                roster.note(runID, "\(name): \(String(preview.prefix(60)))", step: true)
            case .retrying(_, _, let reason):
                roster.note(runID, "server not answering (\(reason)) — retrying")
            case .assistantMessage(_, _, let calls) where calls.isEmpty:
                roster.note(runID, "writing the report")
            default:
                break
            }
        })
        if let runID, let usage = result.usage { roster?.addTokens(runID, prompt: usage.promptTokens, completion: usage.completionTokens) }
        if result.stalled { return (false, result.lastReplyText) }
        let text = result.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.lastReplyText : result.finalText
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (true, "Subagent completed without a final report. Its tool work (if any) has already been applied in the workspace.")
            : (true, text)
    }

    /// The model settings a subagent sends: a target on another route uses that route's own (nil = its provider's
    /// default) — never the parent chat's temperature, output limit or thinking level; the primary (or no fleet)
    /// shares the parent's.
    static func settings(for target: FleetTarget, context: ToolContext)
        -> (temperature: Double?, maxOutputTokens: Int?, thinking: ThinkingLevel?) {
        if target.ownSettings { return (target.temperature, target.maxOutputTokens, target.thinking) }
        return (target.temperature ?? context.temperature, target.maxOutputTokens ?? context.maxOutputTokens, context.thinking)
    }

    static func subagentPrompt(workspace: URL, permissionPreset: PermissionPreset,
                               definition: AgentDefinition? = nil) -> String {
        var text = """
        You are a focused subagent. Work autonomously: read and run tools as needed to answer \
        the task in the user message. Do not ask questions — make reasonable assumptions and \
        state them in your final answer. Keep your final answer concise and factual; it is \
        returned to the main agent, not to a human.
        Workspace: \(workspace.path)
        Permission preset: \(permissionPreset.rawValue). If a tool is denied, do not retry the \
        same action; note the limitation in your report instead.
        """
        if let prompt = definition?.prompt, !prompt.isEmpty { text += "\n\n" + prompt }
        return text
    }
}

/// How a subagent's run ended.
public struct SubagentOutcome: Sendable {
    public var ok: Bool
    public var report: String
    public var agentType: String
    /// The server it ran on — only when there was a choice of servers.
    public var server: String?
    public var elapsed: TimeInterval
    /// How many times its task moved to another server after one failed.
    public var failovers: Int

    public init(ok: Bool, report: String, agentType: String, server: String? = nil,
                elapsed: TimeInterval = 0, failovers: Int = 0) {
        self.ok = ok
        self.report = report
        self.agentType = agentType
        self.server = server
        self.elapsed = elapsed
        self.failovers = failovers
    }

    /// "(explore agent · on spark-2 · 34s)" — empty for a plain general agent on the only server.
    public func details() -> String {
        var parts: [String] = []
        if agentType.caseInsensitiveCompare(AgentDefinition.general) != .orderedSame { parts.append(agentType + " agent") }
        if let server { parts.append("on " + server) }
        if failovers > 0 { parts.append("after \(failovers) server failure\(failovers == 1 ? "" : "s")") }
        if !parts.isEmpty { parts.append(elapsed.formattedDuration) }
        return parts.isEmpty ? "" : "(" + parts.joined(separator: " · ") + ")"
    }
}
