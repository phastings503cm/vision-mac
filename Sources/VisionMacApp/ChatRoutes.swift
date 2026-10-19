import Foundation
import VisionHarnessCore

// MARK: - Each chat's own model
//
// Two projects open, a prompt in each: the model picked in one chat must not become the other's. A chat carries its
// own route and thinking level (stored with the conversation); a new chat starts with what its project's chats last
// chose (else the primary), and every path that works for a chat — its turns, retries, `/goal`, the queue task
// running in it, its subagents' fallback server, compaction, carrying on after background agents — uses that chat's
// route. The primary in Settings ▸ AI Models is the default for new projects and the fleet's main server; choosing a
// model in a chat changes only that chat (and what its project's next chats start with).

/// A chat's model choice: the route it talks to and its thinking level (`ThinkingLevel` raw value).
public struct ChatChoice: Codable, Hashable, Sendable {
    public var route: String?
    public var thinking: String?

    public init(route: String?, thinking: String?) {
        self.route = route
        self.thinking = thinking
    }
}

extension AppConfig {
    /// The key a project's choice is kept under: its folder ("" for chats without a project).
    static func projectKey(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// What a new chat in this project starts with (nil = nothing chosen there yet).
    public func lastChoice(forProject path: String?) -> ChatChoice? {
        projectChoices[Self.projectKey(path)]
    }

    public func rememberChoice(_ choice: ChatChoice, forProject path: String?) {
        let key = Self.projectKey(path)
        guard projectChoices[key] != choice else { return }
        projectChoices[key] = choice
    }

    /// A configured route that is switched on, with its API key from the Keychain (nil when it is gone or off).
    public func usableRoute(_ routeID: String?) -> ProviderProfile? {
        guard let routeID, let stored = providers.first(where: { $0.routeID == routeID }), stored.isEnabled else { return nil }
        var resolved = stored
        let key = apiKey(for: stored)
        resolved.apiKey = key.isEmpty ? nil : key
        return resolved
    }
}

extension AppTransport {
    /// The route a chat talks to: its own while that is configured and on, else the primary.
    @MainActor
    func chatRoute(_ vm: SessionVM?) -> ProviderProfile? {
        config.usableRoute(vm?.routeID) ?? config.activeProvider
    }

    /// The configured route a chat shows in its model menu (its own, else the primary).
    @MainActor
    public func chatRouteID(_ vm: SessionVM?) -> String? {
        chatRoute(vm)?.routeID
    }

    /// The model the chat's route serves now (follows a Spark swap).
    @MainActor
    public func modelID(for vm: SessionVM?) -> String? {
        chatRoute(vm).map(effective)?.model
    }

    /// What the chat's model takes: which thinking levels its picker offers.
    @MainActor
    public func requestRules(for vm: SessionVM?) -> ModelRequestRules? {
        guard let route = chatRoute(vm) else { return nil }
        let live = effective(route)
        return ModelRequestRules.for(live, model: live.model)
    }

    /// A new chat starts with its project's last choice — or the queue task's, for the chat a task runs in — else
    /// the primary.
    @MainActor
    func assignInitialChoice(_ vm: SessionVM, routeID: String? = nil, thinking: String? = nil) {
        let inherited = config.lastChoice(forProject: vm.cwd)
        let route = config.usableRoute(routeID)?.routeID
            ?? config.usableRoute(inherited?.route)?.routeID
            ?? config.activeRoute
        vm.routeID = route
        vm.thinking = (routeID != nil ? thinking : inherited?.thinking).flatMap(ThinkingLevel.init(rawValue:))
        log.setChoice(id: vm.id, route: vm.routeID, thinking: vm.thinking?.rawValue)
    }

    /// An older chat that never chose: it takes the primary of the moment it sends, and keeps it.
    @MainActor
    func pinRouteIfUnset(_ vm: SessionVM) {
        guard vm.routeID == nil || config.usableRoute(vm.routeID) == nil else { return }
        let previous = vm.routeID
        vm.routeID = config.activeRoute
        log.setChoice(id: vm.id, route: vm.routeID, thinking: vm.thinking?.rawValue)
        if previous != nil, let route = config.activeProvider {
            vm.note("This chat's model is no longer set up (or is switched off), so it now uses \(Self.routeLabel(route)) — \(route.model).")
        }
    }

    /// Choose a chat's model: that chat only. Its project's next chats start with it too.
    @MainActor
    public func setRoute(_ routeID: String, for vm: SessionVM) {
        guard config.usableRoute(routeID) != nil, vm.routeID != routeID else { return }
        vm.routeID = routeID
        // A level the new model doesn't offer is shown (and sent) as its nearest one; keep the chat's own choice.
        log.setChoice(id: vm.id, route: routeID, thinking: vm.thinking?.rawValue)
        config.rememberChoice(ChatChoice(route: routeID, thinking: vm.thinking?.rawValue), forProject: vm.cwd)
    }

    /// Set a chat's thinking level (nil = the route's default). Remembered for its project's next chats.
    @MainActor
    public func setThinking(_ level: ThinkingLevel?, for vm: SessionVM) {
        vm.thinking = level
        log.setChoice(id: vm.id, route: vm.routeID, thinking: level?.rawValue)
        config.rememberChoice(ChatChoice(route: vm.routeID ?? config.activeRoute, thinking: level?.rawValue), forProject: vm.cwd)
    }

    /// The chat's own route as the fleet's "primary" for its subagents: when no worker is free (or there are none)
    /// a subagent falls back to the model its own chat uses, never another chat's.
    @MainActor
    func fleetHome(for vm: SessionVM, profile: ProviderProfile) -> FleetServer {
        let sessionID = vm.id
        return FleetServer(
            id: profile.routeID, label: Self.routeLabel(profile), isPrimary: true,
            maxParallel: min(max(profile.subagentParallel ?? 4, 1), 16), isPrivate: profile.isPrivateRoute,
            interactiveOnly: profile.isInteractiveOnly,
            resolve: { [weak self] in
                guard let self else { throw LLMError.noModel }
                return try await self.resolveHomeTarget(sessionID: sessionID)
            })
    }
}
