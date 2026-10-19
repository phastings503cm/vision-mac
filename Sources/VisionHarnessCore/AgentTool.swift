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
    static let defaultMaxSteps = 30
    /// How many times a task moves to another server after its server fails.
    private static let maxFailovers = 2

    /// The agent types the tool's description offers (nil = the built-in ones). Which types a call may
    /// *use* comes from the context (`ToolContext.agentTypes`), the chat's own definitions.
    public let catalog: AgentCatalog?
    /// The chat's subagent servers, listed in the description (nil = not said).
    public let pool: SubagentPool?

    public init(catalog: AgentCatalog? = nil, pool: SubagentPool? = nil) {
        self.catalog = catalog
        self.pool = pool
    }

    public var spec: ToolSpec { Self.spec(for: catalog ?? .default, pool: pool) }

    /// The description: what a subagent is, the agent types, and — with servers besides the chat's own model — the
    /// stable catalogue of them (`SubagentPool.describe`; how busy they are comes back in results instead).
    public static func spec(for catalog: AgentCatalog, pool: SubagentPool? = nil) -> ToolSpec {
        var description = "Spawn a subagent to work a self-contained task (e.g. 'find every usage of X and report the call sites'). It works autonomously in a bounded loop and returns a final report. Prefer this over doing long exploration yourself when the task is well-scoped. "
            + "Pick agent_type for a specialist — " + catalog.describe() + ". Omit it for the general worker. "
            + "Several agent calls in one turn run at the same time. Set run_in_background to true to launch it in the background and keep working: check on it with agent_status (you're also told automatically when one finishes) and stop one with agent_stop. To fan out many independent tasks in one go, use `delegate`."
        if let pool, let catalogue = SubagentPool.describe(pool) { description += "\n\n" + catalogue }
        return ToolSpec(name: name, description: description, parameters: parameters)
    }

    /// The parameters (the same on Windows; compared structurally by the shared fixture).
    public static let parameters = #"{"type":"object","properties":{"description":{"type":"string","description":"What to name this subagent"},"prompt":{"type":"string","description":"The complete task for the subagent. It cannot ask you questions and cannot see this conversation — everything it needs goes here."},"agent_type":{"type":"string","description":"The kind of subagent (default: general)"},"server":{"type":"string","description":"#
        + jsonString(SubagentServers.serverParameter)
        + #"},"run_in_background":{"type":"boolean","description":"Start it in the background and return at once (default false: wait for its report)"},"step":{"type":"string","description":"#
        + jsonString(stepParameter) + #"},"sensitive":{"type":"boolean","description":"#
        + jsonString(SubagentServers.sensitiveParameter) + #"}},"required":["description","prompt"]}"#

    /// A string as a JSON literal, quotes included.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// The `step` argument of agent and delegate's tasks: which plan step the subagent works, so the plan, the Tasks
    /// tab and the activity menu show it there (the same words on Windows).
    public static let stepParameter =
        "Which step of your plan (todo_write) this subagent works: its number in the plan (1 = the first) or its text. Shown on that step."

    /// The step argument as text (models send a number or a string).
    static func stepArgument(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            return String(Int64(double.rounded()))
        default:
            return nil
        }
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
        // Where the main agent wants it: checked before anything starts.
        let pin: SubagentPool.Entry?
        switch Self.serverChoice(Self.string(args, "server"), context: context) {
        case .entry(let entry): pin = entry
        case .error(let message): return ToolResult(output: message)
        case nil: pin = nil
        }
        // A Sensitive chat with the shield off keeps every subagent on a private server.
        let sensitive = JSONArgs.bool(args, "sensitive", default: false) || context.privateSubagentsOnly
        let step = Self.stepArgument(JSONArgs.dictionary(args)["step"])

        if JSONArgs.bool(args, "run_in_background", default: false) {
            guard let pool = context.backgroundAgents else {
                return ToolResult(output: "Error: background subagents aren't available here; call agent without run_in_background.")
            }
            // The background run belongs to the pool (stop / agent_stop cancel it), not to this call.
            let launched = pool.launch(description: desc, work: {
                let outcome = try await Self.runCore(prompt: prompt, description: desc, definition: definition,
                                                     background: true, sensitive: sensitive, step: step, pin: pin,
                                                     context: context)
                // A task that ran elsewhere than the main agent picked says so in front of its report.
                return (outcome.ok, outcome.fallbackLine().map { $0 + "\n\n" + outcome.report } ?? outcome.report)
            })
            switch launched {
            case .success(let job):
                return ToolResult(output: Self.withLoad("Started background agent \(job.id) “\(desc)”. It works while you continue — you'll be told automatically when it finishes; agent_status {\"id\":\"\(job.id)\",\"wait_seconds\":120} waits for it, agent_stop stops it.", context: context))
            case .failure(let error):
                return ToolResult(output: "Error: " + (error.errorDescription ?? "can't start another background agent."))
            }
        }

        do {
            let outcome = try await Self.runCore(prompt: prompt, description: desc, definition: definition,
                                                 background: false, sensitive: sensitive, step: step, pin: pin, context: context)
            return ToolResult(output: Self.withLoad(Self.present(description: desc, outcome: outcome), context: context))
        } catch {
            return ToolResult(output: "Error: cancelled by user.")
        }
    }

    /// What a `server` argument names in this chat (nil when it isn't given).
    static func serverChoice(_ raw: String?, context: ToolContext) -> SubagentPool.Choice? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pool = context.fleetPool ?? SubagentPool.from(servers: context.fleet?.servers ?? [])
        return SubagentPool.match(raw, in: pool)
    }

    /// `text`, then — after a blank line — how busy each of the chat's subagent servers is now (when it has any
    /// besides its own model). Results only: descriptions stay stable for the prompt cache.
    static func withLoad(_ text: String, context: ToolContext) -> String {
        guard let line = loadLine(context: context) else { return text }
        return text + "\n\n" + line
    }

    /// "Subagent servers now: dgx-spark 1/2 busy · primary 0/4 busy." (nil without servers besides the chat's own).
    static func loadLine(context: ToolContext) -> String? {
        guard let fleet = context.fleet, let pool = context.fleetPool, pool.hasWorkers else { return nil }
        return SubagentPool.loadLine(pool, loads: fleet.loads(for: pool, home: context.fleetHome))
    }

    /// The report as the parent sees it. The first line keeps a fixed shape; a specialist type or a named
    /// server is added on a line of its own, and a task that ran elsewhere than the main agent picked says so.
    static func present(description: String, outcome: SubagentOutcome) -> String {
        var text = outcome.ok ? "Subagent '\(description)' finished." : "Subagent '\(description)' failed: \(outcome.report)"
        let details = outcome.details()
        if !details.isEmpty { text += "\n" + details }
        if let moved = outcome.fallbackLine() { text += "\n" + moved }
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
    /// an outcome. `pin` is the server the main agent picked (`server`).
    static func runCore(prompt firstPrompt: String, description: String, definition: AgentDefinition,
                        background: Bool, sensitive: Bool = false, step: String? = nil, pin: SubagentPool.Entry? = nil,
                        context: ToolContext) async throws -> SubagentOutcome {
        let roster = context.roster
        let runID = roster?.begin(description: description, agentType: definition.name, background: background,
                                  prompt: firstPrompt, step: step)
        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> TimeInterval {
            let duration = started.duration(to: clock.now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        var failovers = 0
        var firstServer: String?
        // The report names the server only when there was a choice of servers; a lone one is just "the model".
        let poolIDs = context.fleetPool?.workerRouteIDs
        let choice = (context.fleet?.choiceCount(home: context.fleetHome, pool: poolIDs) ?? 0) > 1
        func named(_ handle: String?) -> String? { choice ? handle : nil }
        // The pinned server's fleet id: the chat's own server for "primary".
        let pinnedID: String? = pin.map { entry in
            entry.isPrimary ? (context.fleetHome?.id ?? context.fleet?.servers.first(where: \.isPrimary)?.id ?? entry.routeID)
                : entry.routeID
        }
        var prompt = firstPrompt
        var movedNote: String?
        var placement: (reason: SubagentPlacement.Reason?, note: String?) = (nil, nil)
        let trace = AttemptTrace()
        func outcome(ok: Bool, report: String, server: String?) -> SubagentOutcome {
            SubagentOutcome(ok: ok, report: report, agentType: definition.name, server: named(server), elapsed: elapsed(),
                            failovers: failovers, reason: placement.reason, note: placement.note,
                            pinned: placement.reason == .fallback ? pin?.id : nil)
        }
        do {
            while true {
                var lease: FleetLease?
                let target: FleetTarget
                if let fleet = context.fleet {
                    if let runID {
                        roster?.note(runID, pin.map { "waiting for \($0.id), which the primary picked (up to \(SubagentPlacement.waitWords(fleet.pinWait)))" }
                            ?? "waiting for a free server")
                    }
                    do {
                        // A task that needs sensitive data runs only on a private server.
                        lease = try await fleet.acquire(FleetRequest(
                            pinned: pinnedID, preferred: definition.server, sensitive: sensitive, unattended: context.unattended,
                            home: context.fleetHome, pool: poolIDs, sensitiveChat: context.sensitiveChat))
                    } catch let unavailable as FleetUnavailableError {
                        if let runID { roster?.finish(runID, status: .failed, report: unavailable.message) }
                        return outcome(ok: false, report: unavailable.message, server: firstServer)
                    }
                    let leased = lease!
                    target = leased.target
                    if firstServer == nil { firstServer = leased.handle }
                    if let runID, choice { roster?.setServer(runID, leased.label) }
                    placement = Self.placement(lease: leased, movedNote: movedNote, choice: choice || pin != nil)
                    if let runID {
                        roster?.setPlacement(runID, route: leased.label, model: target.model, reason: placement.reason?.rawValue,
                                             note: Self.placementNote(definition: definition, lease: leased, fleet: fleet,
                                                                      note: placement.note))
                    }
                } else {
                    // No fleet: it would run on the chat's own model — for a sensitive task, only if that is private
                    // (as a Sensitive chat counts it: own hardware, Guardian, Bedrock in your account).
                    if sensitive, !((context.client as? any ProviderClient).map { SensitivityPolicy.isPrivate($0.profile) } ?? false) {
                        if let runID { roster?.finish(runID, status: .failed, report: AgentFleet.noPrivateServer) }
                        return outcome(ok: false, report: AgentFleet.noPrivateServer, server: nil)
                    }
                    target = FleetTarget(client: context.client, model: context.model, contextWindow: context.contextWindow)
                    if let runID { roster?.setPlacement(runID, route: "this chat's model", model: context.model) }
                }

                do {
                    let (ok, report): (Bool, String)
                    if let external = target.external {
                        // An engine of its own (Claude Code): one job in the chat's folder, its report back like any.
                        (ok, report) = try await runExternal(external, prompt: prompt, definition: definition, target: target,
                                                             context: context, runID: runID, trace: trace)
                    } else {
                        // With one server there is nowhere to fail over to: wait it out as long as the main agent would.
                        (ok, report) = try await runEngine(prompt: prompt, definition: definition, target: target, context: context,
                                                           runID: runID, boundedRetries: choice, trace: trace)
                    }
                    lease?.release()
                    if let runID { roster?.finish(runID, status: ok ? .done : .failed, report: report) }
                    return outcome(ok: ok, report: report, server: lease?.handle ?? firstServer)
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
                    movedNote = SubagentPlacement.movedNote(from: failed.handle, error: error.localizedDescription)
                    // The task starts again from the top on the next server — after work that already changed things,
                    // it has to look before it repeats a step (a migration, a commit, a deploy).
                    if trace.mutated { prompt = Self.interruptedNote + firstPrompt }
                    if let runID { roster?.note(runID, "\(failed.label) failed — trying another server") }
                } catch {
                    lease?.fail(error)
                    lease?.release()
                    let message = error.localizedDescription
                    if let runID { roster?.finish(runID, status: .failed, report: message) }
                    return outcome(ok: false, report: message, server: lease?.handle ?? firstServer)
                }
            }
        } catch is CancellationError {
            if let runID { roster?.finish(runID, status: .stopped, report: "Stopped before it finished.") }
            throw CancellationError()
        }
    }

    /// How the lease's server was chosen, as the roster and the report say it: after a failover, a fallback "moved
    /// here"; with no choice of servers (and no pick), nothing.
    static func placement(lease: FleetLease, movedNote: String?, choice: Bool) -> (reason: SubagentPlacement.Reason?, note: String?) {
        if let movedNote { return (.fallback, movedNote) }
        guard choice else { return (nil, nil) }
        return (lease.reason, lease.reason == .fallback ? lease.note : nil)
    }

    /// Why a subagent runs where it does when that isn't the obvious place: the main agent's pick or its agent file
    /// asked for a server it didn't get, or servers tried first couldn't take it. Nil when it runs where it was meant to.
    static func placementNote(definition: AgentDefinition, lease: FleetLease, fleet: AgentFleet, note: String? = nil) -> String? {
        var notes: [String] = []
        if let note {
            notes.append(note)
        } else if lease.reason == nil, let wanted = definition.server, !wanted.isEmpty,
                  !AgentFleet.matches(lease.server, preferred: wanted) {
            notes.append(fleet.servers.contains(where: { AgentFleet.matches($0, preferred: wanted) })
                         ? SubagentPlacement.agentFileBusy(wanted) : SubagentPlacement.agentFileMissing(wanted))
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
        // Same chat to the machine (its name, its scope), its own place in line for the mouse. Its machine tools are
        // reported on the seat, so the app's glow and the global stop (⌃⌥⌘.) see them like the chat's own.
        let seat = context.machine?.child()
        defer { seat?.noteToolWork(.ended) }
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
            // The chat's approvals: allowed once covers its subagents, and ⌃⌥⌘. takes them back from all of them.
            computerGrants: context.computerGrants ?? ComputerGrants(),
            vault: context.vault,
            vaultGrants: context.vaultGrants,
            machineSeat: seat
        )

        let roster = context.roster
        let result = try await engine.run(messages: [], userText: prompt, sink: { event in
            switch event {
            case .toolStarted(_, let name, _) where ComputerAccess.forTool(name) != nil:
                seat?.noteToolWork(.started(tool: name))
            case .toolFinished(_, let name, _, _, _) where ComputerAccess.forTool(name) != nil:
                seat?.noteToolWork(.finished)
            default:
                break
            }
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

    /// A task on a server that runs its own agent (Claude Code): one job in the chat's folder, under the chat's
    /// permissions (Plan only for a read-only type), its steps on the roster, its report back like any subagent's.
    private static func runExternal(_ external: any ExternalSubagent, prompt: String, definition: AgentDefinition,
                                    target: FleetTarget, context: ToolContext, runID: String?,
                                    trace: AttemptTrace) async throws -> (ok: Bool, report: String) {
        let roster = context.roster
        var note = ClaudeCodeSubagent.note
        if !definition.prompt.isEmpty { note += "\n\n" + definition.prompt }
        let job = ExternalSubagentJob(
            prompt: prompt, systemNote: note, workspace: context.workspace,
            preset: definition.isReadOnly ? .plan : context.policy.preset, readOnly: definition.isReadOnly,
            maxSteps: definition.maxSteps ?? defaultMaxSteps,
            activity: { text, step in
                guard let runID, let roster else { return }
                roster.note(runID, text, step: step)
            },
            noteMutation: { trace.noteMutation() },
            requestPermission: context.requestPermission)
        let result = try await external.run(job)
        if result.mutated { trace.noteMutation() }
        if let runID, let roster {
            roster.addTokens(runID, prompt: result.promptTokens, completion: result.completionTokens)
            if let cost = result.costUSD {
                roster.note(runID, "≈ " + (cost < 0.01 ? "under $0.01" : "$" + String(format: "%.2f", cost))
                            + " at API prices (paid by your Claude plan)")
            }
        }
        return (result.ok, result.report)
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
    /// The server it ran on, as the main agent names it ("dgx-spark") — only when there was a choice of servers.
    public var server: String?
    public var elapsed: TimeInterval
    /// How many times its task moved to another server after one failed.
    public var failovers: Int
    /// How its server was chosen (nil when there was no choice).
    public var reason: SubagentPlacement.Reason?
    /// Why it ran where it did, for a fallback.
    public var note: String?
    /// The server the main agent picked, when it ran somewhere else.
    public var pinned: String?

    public init(ok: Bool, report: String, agentType: String, server: String? = nil,
                elapsed: TimeInterval = 0, failovers: Int = 0, reason: SubagentPlacement.Reason? = nil,
                note: String? = nil, pinned: String? = nil) {
        self.ok = ok
        self.report = report
        self.agentType = agentType
        self.server = server
        self.elapsed = elapsed
        self.failovers = failovers
        self.reason = reason
        self.note = note
        self.pinned = pinned
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

    /// "Ran on bedrock instead of spark-2: spark-2 stayed busy for 2 minutes." — when it didn't run where the main
    /// agent picked.
    public func fallbackLine() -> String? {
        guard reason == .fallback, let pinned, let server, server != pinned, let note else { return nil }
        return "Ran on \(server) instead of \(pinned): \(note)."
    }
}
