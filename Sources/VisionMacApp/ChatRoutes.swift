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

    /// A configured route that is switched on, with its API key from the Keychain — or one of Guardian's models while
    /// signed in to Guardian (nil when it is gone, off, or a Guardian model while signed out).
    public func usableRoute(_ routeID: String?) -> ProviderProfile? {
        guard let routeID else { return nil }
        guard let stored = providers.first(where: { $0.routeID == routeID }) else {
            return guardianModelRoute(routeID).flatMap { $0.apiKey == nil ? nil : $0 }
        }
        guard stored.isEnabled else { return nil }
        var resolved = stored
        let key = apiKey(for: stored)
        resolved.apiKey = key.isEmpty ? nil : key
        return resolved
    }

    // MARK: Guardian's models

    /// The name every Guardian model route goes by: its identity is "Guardian|<model id>".
    public nonisolated static let guardianRouteName = "Guardian"

    /// Whether a route identity names one of Guardian's models (and no configured route has that identity — a route
    /// the setup wizard saved is an ordinary route).
    public func isGuardianModel(_ routeID: String?) -> Bool {
        guard let routeID, routeID.hasPrefix(Self.guardianRouteName + "|"),
              routeID.count > Self.guardianRouteName.count + 1 else { return false }
        return !providers.contains { $0.routeID == routeID }
    }

    /// One Guardian model as a route: the proxy's address, the organization header, the window and plan terms
    /// Guardian reports, and the sign-in's token — none while signed out, when a chat on it says
    /// "Sign in to Guardian to use this model." (`GuardianSignInNeeded`). Nil for any other identity.
    public func guardianModelRoute(_ routeID: String?) -> ProviderProfile? {
        guard isGuardianModel(routeID), let routeID else { return nil }
        let id = String(routeID.dropFirst(Self.guardianRouteName.count + 1))
        var route = Self.guardianRoute(guardianModels.first { $0.id == id } ?? GuardianModel(id: id),
                                       base: guardianModelBase, org: guardianOrgID)
        let token = guardianToken ?? ""
        route.apiKey = token.isEmpty ? nil : token
        return route
    }

    /// Guardian's models as routes, for the menus (no token on them).
    public var guardianModelRoutes: [ProviderProfile] {
        let stored = Set(providers.map(\.routeID))
        return guardianModels.map { Self.guardianRoute($0, base: guardianModelBase, org: guardianOrgID) }
            .filter { !stored.contains($0.routeID) }
    }

    /// The route for one of Guardian's models.
    static func guardianRoute(_ model: GuardianModel, base: String?, org: String?) -> ProviderProfile {
        var route = ProviderProfile(kind: .guardian, name: guardianRouteName,
                                    baseURL: base ?? GuardianService.modelRouteURL(URL(string: GuardianService.defaultURL)!),
                                    model: model.id)
        if let window = model.contextWindow, window > 0 { route.contextWindow = window }
        if model.interactiveOnly == true { route.interactiveOnly = true }
        if let org, !org.isEmpty { route.customHeaders = ["x-guardian-org": org] }
        return route
    }

    /// How a Guardian model is named in the menu: Guardian's label, with the id when they differ.
    public func guardianMenuLabel(_ routeID: String) -> String {
        let id = String(routeID.dropFirst(Self.guardianRouteName.count + 1))
        guard let label = guardianModels.first(where: { $0.id == id })?.label, !label.isEmpty, label != id else { return id }
        return "\(label) (\(id))"
    }
}

extension AppTransport {
    /// The route a chat talks to: its own while that is configured and on — a Guardian model stays the chat's even
    /// while signed out (it then asks for the sign-in) — else the primary.
    @MainActor
    func chatRoute(_ vm: SessionVM?) -> ProviderProfile? {
        config.usableRoute(vm?.routeID) ?? config.guardianModelRoute(vm?.routeID) ?? config.activeProvider
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
        // A chat on a Guardian model keeps it while signed out: sending says "Sign in to Guardian to use this model."
        guard !config.isGuardianModel(vm.routeID) else { return }
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
