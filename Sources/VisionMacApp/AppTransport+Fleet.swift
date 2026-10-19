import Foundation
import VisionHarnessCore

// MARK: - Subagents across servers
//
// Everything the host adds around a chat's engine so subagents can run on more than one machine:
//  * the fleet — with several model servers (say two DGX Sparks and Amazon Bedrock) the main route is
//    the primary, the chat's own server, and the routes flagged "Use for subagents" are workers; a
//    subagent runs on the least busy worker (the primary only as overflow) and moves to another server
//    if its own dies
//  * a roster per chat, so the UI can show who is working on what, and where
//  * the agent types a chat offers (built-in plus the user's and the project's agent files)

extension AppTransport {
    // MARK: Fleet

    /// Rebuild the fleet from the configured routes. Called whenever the routes, the main model or the
    /// subagent settings change (see `AppConfig.onRoutesChanged`).
    func refreshFleet() {
        var servers: [FleetServer] = []
        if let main = config.mainRoute {
            servers.append(FleetServer(
                id: main.routeID, label: Self.routeLabel(main), isPrimary: true,
                maxParallel: Self.clamp(main.subagentParallel ?? 4), isPrivate: main.isPrivateRoute,
                interactiveOnly: main.isInteractiveOnly,
                // The main route is probed the way the chat probes it (and shares its cache).
                resolve: { [weak self] in
                    guard let self else { throw LLMError.noModel }
                    return try await self.resolvePrimaryTarget()
                }))
        }
        for route in workerRoutes {
            servers.append(FleetServer(
                id: route.routeID, label: Self.routeLabel(route), isPrimary: false,
                maxParallel: Self.clamp(route.subagentParallel ?? 2), isPrivate: route.isPrivateRoute,
                interactiveOnly: route.isInteractiveOnly,
                resolve: { [weak self] in
                    guard let self else { throw LLMError.noModel }
                    return try await self.resolveWorkerTarget(route)
                }))
        }
        fleet.usePrimaryWhenWorkersBusy = config.subagentsUsePrimary
        fleet.configure(servers)
    }

    private static func clamp(_ parallel: Int) -> Int { min(max(parallel, 1), 16) }

    private func resolvePrimaryTarget() async throws -> FleetTarget {
        guard let profile = await resolveRoute() else { throw LLMError.noModel }
        return FleetTarget(client: ProviderClients.make(profile), model: profile.model, contextWindow: contextLimit(route: profile),
                           vision: visionOn(for: profile), temperature: profile.temperature,
                           maxOutputTokens: profile.maxOutputTokens)
    }

    /// The live client, model and window for a worker, resolved when a lease is granted: a Spark may
    /// have swapped models since the route was configured, so it is asked what it serves right now
    /// (the answer is reused for a minute). A server that names no model at all isn't answering.
    private func resolveWorkerTarget(_ route: ProviderProfile) async throws -> FleetTarget {
        var profile = route
        let key = config.apiKey(for: route)
        profile.apiKey = key.isEmpty ? nil : key
        let client = ProviderClients.make(profile)
        var model = profile.model
        var window = profile.contextWindow
        if profile.kind != .bedrock {
            var info = workerProbe[route.routeID].flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.info : nil }
            if info == nil {
                let fresh = await client.modelInfo(nil)
                if let fresh, !fresh.servedModels.isEmpty {
                    workerProbe[route.routeID] = (fresh, Date())
                    info = fresh
                } else if !Self.workerNeedsModelList(profile) {
                    // A hosted API (Kimi, Z.ai, OpenRouter…) may not list models for this key or plan; its configured
                    // model is the answer, and the first request says whether it works (a refusal moves the task on).
                } else {
                    throw LLMError.connection("\(route.baseURL) didn't answer")
                }
            }
            if let served = info?.id, !served.isEmpty { model = served }
            window = window ?? info?.contextWindow
        }
        // The worker's own settings — never the main route's temperature, output limit or thinking level.
        return FleetTarget(client: client, model: model,
                           contextWindow: window ?? FallbackContextWindow.limit(for: model) ?? FallbackContextWindow.defaultLimit,
                           vision: visionOn(for: profile), temperature: profile.temperature,
                           maxOutputTokens: profile.maxOutputTokens, ownSettings: true, thinking: profile.thinking)
    }

    /// A worker counts as reachable only if it lists its models — true for a server you run yourself (a Spark that is
    /// down or swapping lists nothing). A hosted API is trusted with its configured model instead: some plans' keys
    /// can't list models, and treating that as "down" sent every subagent to the main model without a word.
    static func workerNeedsModelList(_ profile: ProviderProfile) -> Bool {
        profile.isSelfHosted || profile.model.trimmingCharacters(in: .whitespaces).isEmpty
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

    /// The subagent servers and whether each is private, as the main agent is told about them.
    var subagentServerEntries: [SubagentServers.Entry] {
        workerRoutes.map { SubagentServers.Entry(name: Self.routeLabel($0), isPrivate: $0.isPrivateRoute) }
    }

    // MARK: /agents

    /// `/agents`: the kinds of subagent, the servers they run on and how busy each is, and what is
    /// running now.
    func agentsCommand(_ vm: SessionVM) {
        var lines = ["**Subagent types** (the agent tool's `agent_type`):"]
        for type in agentCatalog(for: vm).all {
            let origin = type.origin == "built-in" ? "" : " *(\(type.origin))*"
            lines.append("- `\(type.name)` — \(String(type.description.prefix(110)))\(origin)")
        }
        lines.append("")
        let servers = fleet.snapshot()
        if servers.isEmpty {
            lines.append("**Model servers:** none configured.")
        } else {
            lines.append(servers.count == 1
                ? "**Model server:** subagents share the one server. Turn on “Use for subagents” for more routes in Settings › Models to spread them across machines."
                : "**Model servers** (the main model handles the chat; subagents go to the other servers first):")
            for server in servers {
                let health = server.healthy ? "" : " — not answering, skipped for a minute"
                let failed = server.failed > 0 ? ", \(server.failed) failed" : ""
                let privacy = config.providers.first { $0.routeID == server.id }.map { $0.isPrivateRoute ? " · private" : " · not private" } ?? ""
                lines.append("- \(server.isPrimary ? "🖥 main" : "⚙ subagents") **\(server.label)**\(privacy) — \(server.inFlight)/\(server.maxParallel) busy, \(server.completed) done\(failed)\(health)")
            }
        }
        let running = vm.agentRuns.filter(\.isRunning)
        lines.append("")
        if running.isEmpty {
            lines.append("No subagents running in this chat.")
        } else {
            lines.append("**Running now:**")
            for run in running {
                let where_ = run.server.map { " · \($0)" } ?? ""
                lines.append("- \(run.description) (\(run.agentType)\(where_)) — \(run.activity)")
            }
        }
        vm.note(lines.joined(separator: "\n"))
    }
}
