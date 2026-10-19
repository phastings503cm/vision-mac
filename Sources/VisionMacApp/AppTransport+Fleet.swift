import Foundation
import VisionHarnessCore

// MARK: - Subagents across servers
//
// Everything the host adds around a chat's engine so subagents can run on more than one machine:
//  * the fleet — every route enlisted "Use for subagents" (a second DGX Spark, Amazon Bedrock, a plan, a Guardian model,
//    Claude Code) is a server; each chat's own model is the *primary* for its own subagents, and its pool is every
//    enlisted route except its own machine and what it may not use (`subagentPool(for:)`). The primary picks a server
//    by name (`server`) or lets Vision pick the least busy; a task whose server dies moves to another one
//  * a roster per chat, so the UI can show who is working on what, where, and why there
//  * the agent types a chat offers (built-in plus the user's and the project's agent files)

extension AppTransport {
    // MARK: Fleet

    /// Rebuild the fleet from the enlisted routes. Called whenever the routes, the subagent settings or Guardian's
    /// models change (see `AppConfig.onRoutesChanged`, `GuardianService`).
    func refreshFleet() {
        let routes = config.enlistedRoutes
        let handles = subagentHandles()
        var servers: [FleetServer] = []
        for route in routes where !servers.contains(where: { $0.id == route.routeID }) {
            let routeID = route.routeID
            servers.append(FleetServer(
                id: routeID, label: Self.routeLabel(route), isPrimary: false,
                maxParallel: Self.clamp(route.subagentParallel ?? 2), isPrivate: SensitivityPolicy.isPrivate(route),
                interactiveOnly: route.isInteractiveOnly, handle: handles[routeID], machine: AppConfig.machineOf(route),
                kind: SubagentPool.Kind(route.kind).rawValue,
                resolve: { [weak self] in
                    guard let self else { throw LLMError.noModel }
                    return try await self.resolveWorkerTarget(routeID)
                }))
        }
        fleet.usePrimaryWhenWorkersBusy = config.subagentsUsePrimary
        fleet.configure(servers)
    }

    private static func clamp(_ parallel: Int) -> Int { min(max(parallel, 1), 16) }

    /// The live client, model and window for a subagent server, resolved when a lease is granted: a Spark may have
    /// swapped models since the route was configured, so it is asked what it serves right now (the answer is reused for
    /// a minute); a Guardian model takes the sign-in's token as it is now; Claude Code is found on this Mac. A server
    /// that names no model at all isn't answering.
    func resolveWorkerTarget(_ routeID: String) async throws -> FleetTarget {
        // Signed out of Guardian: a server fault, so the next server takes the task.
        if config.isGuardianModel(routeID), config.guardianToken == nil {
            throw LLMError.rejected(status: 401, message: GuardianSignInNeeded.message, body: "signed out of Guardian", permanent: true)
        }
        guard let route = config.usableRoute(routeID) else {
            throw LLMError.connection("\(routeID) is no longer set up (or is switched off)")
        }
        if route.kind == .claudeCode { return try await claudeCodeWorkerTarget(route) }
        let profile = route
        let client = ProviderClients.make(profile)
        var model = profile.model
        var window = profile.contextWindow
        if profile.kind != .bedrock {
            var info = workerProbe[routeID].flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.info : nil }
            if info == nil {
                let fresh = await client.modelInfo(nil)
                if let fresh, !fresh.servedModels.isEmpty {
                    workerProbe[routeID] = (fresh, Date())
                    info = fresh
                } else if !Self.workerNeedsModelList(profile) {
                    // A hosted API (Kimi, Z.ai, OpenRouter, Guardian…) may not list models for this key or plan; its
                    // configured model is the answer, and the first request says whether it works (a refusal moves the
                    // task on).
                } else {
                    throw LLMError.connection("\(route.baseURL) didn't answer")
                }
            }
            if let served = info?.id, !served.isEmpty { model = served }
            window = window ?? info?.contextWindow
            if let info, let served = info.id.isEmpty ? nil : info.id {
                let seen = (model: served, context: info.contextWindow ?? workerSeen[routeID]?.context)
                if workerSeen[routeID]?.model != seen.model || workerSeen[routeID]?.context != seen.context {
                    workerSeen[routeID] = seen
                }
            }
        }
        // The worker's own settings — never the main route's temperature, output limit or thinking level.
        return FleetTarget(client: client, model: model,
                           contextWindow: window ?? FallbackContextWindow.limit(for: model) ?? FallbackContextWindow.defaultLimit,
                           vision: visionOn(for: profile), temperature: profile.temperature,
                           maxOutputTokens: profile.maxOutputTokens, ownSettings: true, thinking: profile.thinking)
    }

    /// Claude Code as a subagent server: each task one `claude -p` job in the chat's folder (`ClaudeCodeSubagent`). Not
    /// on this Mac is a server fault, so the next server takes the task.
    private func claudeCodeWorkerTarget(_ route: ProviderProfile) async throws -> FleetTarget {
        let (found, status) = await claudeCode.usableInstall()
        guard let install = found else { throw ClaudeCodeError.notInstalled(ClaudeCodeHost.notReadyMessage(status)) }
        let environment = ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment)
        let effort = route.thinking.flatMap { ModelRequestRules.for(route, model: route.model).effortWord($0) }
        return FleetTarget(client: ClaudeCodeClient(profile: route), model: route.model,
                           contextWindow: ClaudeCodeModels.contextWindow(route.model), vision: false, ownSettings: true,
                           thinking: route.thinking,
                           external: ClaudeCodeSubagent(install: install, launcher: claudeCode.launcher, environment: environment,
                                                        model: route.model, effort: effort, isTrusted: claudeCode.isTrusted))
    }

    /// A worker counts as reachable only if it lists its models — true for a server you run yourself (a Spark that is
    /// down or swapping lists nothing). A hosted API is trusted with its configured model instead: some plans' keys
    /// can't list models, and treating that as "down" sent every subagent to the main model without a word. Guardian,
    /// the Anthropic API and Claude Code are never asked.
    static func workerNeedsModelList(_ profile: ProviderProfile) -> Bool {
        switch profile.kind {
        case .guardian, .anthropic, .claudeCode, .bedrock: return false
        default: return profile.isSelfHosted || profile.model.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: A chat's pool

    /// Every route a chat could enlist, in Settings order, then Guardian's live models: what the handles are worked out
    /// over (so a handle is the same in every chat).
    private var enlistableRoutes: [ProviderProfile] { config.providers + config.guardianModelRoutes }

    /// Route id → handle ("dgx-spark"), for every enlistable route.
    func subagentHandles() -> [String: String] {
        let routes = enlistableRoutes
        let handles = SubagentPool.handles(for: routes.map { poolFacts($0, enlisted: false) })
        var out: [String: String] = [:]
        for (route, handle) in zip(routes, handles) where out[route.routeID] == nil { out[route.routeID] = handle }
        return out
    }

    /// The pool facts of a route: the model its server last reported, the window Vision settled on, whether it takes
    /// pictures.
    func poolFacts(_ route: ProviderProfile, enlisted: Bool, live: ProviderProfile? = nil) -> SubagentPool.RouteFacts {
        let seen = workerSeen[route.routeID]
        let model = live?.model ?? seen?.model ?? route.model
        let window: Int?
        if route.kind == .claudeCode {
            window = ClaudeCodeModels.contextWindow(route.model)
        } else if let live {
            window = contextLimit(route: live)
        } else {
            window = route.contextWindow ?? seen?.context ?? FallbackContextWindow.limit(for: model)
        }
        return SubagentPool.RouteFacts(route: route, enlisted: enlisted, model: model, contextWindow: window,
                                       images: visionOn(for: route))
    }

    /// The chat's subagent pool: every enlisted route except its own machine, what a Sensitive chat may not use, what an
    /// unattended run may not use, and Guardian while signed out — then its own model as "primary". `profile` is the
    /// chat's route as its turn resolved it (the model its server serves now).
    func subagentPool(for vm: SessionVM, profile: ProviderProfile, unattended: Bool) -> SubagentPool {
        let routes = enlistableRoutes.map { route in
            poolFacts(route, enlisted: route.isEnabled && route.isSubagentWorker)
        }
        return SubagentPool.build(routes: routes, chat: poolFacts(profile, enlisted: false, live: profile),
                                  guardianSignedIn: config.guardianToken != nil, sensitive: vm.sensitive, shieldOn: shieldOn,
                                  unattended: unattended, overflow: config.subagentsUsePrimary)
    }

    // MARK: Per-chat helpers

    /// This chat's subagent roster (created on first use); its changes are mirrored into the session
    /// so the UI can show who is doing what, and where.
    func roster(for sessionID: String) -> AgentRoster {
        if let existing = rosters[sessionID] { return existing }
        let roster = AgentRoster()
        roster.onChange = { [weak self, weak roster] run in
            Task { @MainActor [weak self] in
                guard let vm = self?.sessions.first(where: { $0.id == sessionID }) else { return }
                let isNew = !run.id.isEmpty && !vm.agentRuns.contains(where: { $0.id == run.id })
                vm.upsertAgent(run)
                // A subagent that just started works one of the plan's steps: say which, so the plan can show who is
                // working it (name and model). The agent tool's step argument names it; without one, the best guess
                // from its words (none on a tie).
                if isNew, run.assignment == nil,
                   let step = PlanAssignment.step(requested: run.requestedStep, description: run.description,
                                                  prompt: run.prompt ?? "", todos: vm.todos) {
                    roster?.setAssignment(run.id, step)
                }
            }
        }
        rosters[sessionID] = roster
        return roster
    }

    /// The subagent types this chat offers: the built-in ones plus agent files from the user's folders
    /// and the project's. A file added or edited while the app runs is picked up at the next turn (the
    /// stamp is a few directory listings).
    func agentCatalog(for vm: SessionVM) -> AgentCatalog {
        let key = vm.workspaceURL?.path ?? ""
        let stamp = AgentCatalog.stamp(workspace: vm.workspaceURL)
        if let known = agentCatalogs[key], known.stamp == stamp { return known.catalog }
        let catalog = AgentCatalog.load(workspace: vm.workspaceURL)
        agentCatalogs[key] = (catalog, stamp)
        return catalog
    }

    /// Changes whenever an agent file is added, removed or edited in this chat's folders — so the engine
    /// (which carries the agent types, their tools and the prompt that lists them) is rebuilt.
    func agentsStamp(for vm: SessionVM) -> String {
        AgentCatalog.stamp(workspace: vm.workspaceURL)
    }

    /// Forget what was learned about the subagent servers (Settings changed, or the user asked).
    func resetWorkerProbes() { workerProbe.removeAll() }

    // MARK: /agents

    /// `/agents`: the kinds of subagent, this chat's model and the subagent servers it may hand work to (how busy
    /// each is), what it can't use and why, and what is running now.
    func agentsCommand(_ vm: SessionVM) {
        var lines = ["**Subagent types** (the agent tool's `agent_type`):"]
        for type in agentCatalog(for: vm).all {
            let origin = type.origin == "built-in" ? "" : " *(\(type.origin))*"
            lines.append("- `\(type.name)` — \(String(type.description.prefix(110)))\(origin)")
        }
        lines.append("")
        if let route = chatRoute(vm) {
            let live = effective(route)
            lines.append(contentsOf: Self.agentsLines(pool: subagentPool(for: vm, profile: live, unattended: isUnattended(vm)),
                                                      chatLabel: Self.routeLabel(route), chatModel: live.model,
                                                      status: fleet.snapshot(), homeID: route.routeID))
        } else {
            lines.append("**This chat's model:** none set up.")
        }
        let running = vm.agentRuns.filter(\.isRunning)
        lines.append("")
        if running.isEmpty {
            lines.append("No subagents running in this chat.")
        } else {
            lines.append("**Running now:**")
            for run in running {
                let where_ = (run.route ?? run.server).map { " · \($0)" } ?? ""
                let why = SubagentPlacement.Reason.label(run.placementReason).map { " · \($0)" } ?? ""
                lines.append("- \(run.description) (\(run.agentType)\(where_)\(why)) — \(run.activity)")
            }
        }
        vm.note(lines.joined(separator: "\n"))
    }

    /// The pool part of `/agents`.
    static func agentsLines(pool: SubagentPool, chatLabel: String, chatModel: String, status: [FleetStatus],
                            homeID: String) -> [String] {
        if pool.chatOwnAgent {
            return ["This chat runs on Claude Code, which uses its own subagents. Vision's subagent servers serve chats on other models."]
        }
        var lines = ["**This chat's model (primary):** \(chatLabel) — \(chatModel)"]
        let workers = pool.workers
        if workers.isEmpty {
            lines.append("**Its subagent servers:** none — tick “Subagent” on other models in Settings ▸ AI Models, and this chat's model can hand side tasks to them.")
        } else {
            lines.append("**Its subagent servers:**")
            for entry in workers {
                let state = status.first { $0.id == entry.routeID }
                var line = "- `\(entry.id)` \(entry.provider) · \(entry.model) · \(entry.isPrivate ? "private" : "not private") · \(entry.tier.rawValue)"
                line += " — \(state?.inFlight ?? 0)/\(entry.parallel) busy, \(state?.completed ?? 0) done"
                if let failed = state?.failed, failed > 0 { line += ", \(failed) failed" }
                if state?.healthy == false { line += " — not answering, skipped for a minute" }
                lines.append(line)
            }
        }
        if !pool.dropped.isEmpty {
            lines.append("Not for this chat: " + pool.dropped.map { "\($0.label) (\($0.reason))" }.joined(separator: ", "))
        }
        return lines
    }
}
