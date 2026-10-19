import SwiftUI
import VisionHarnessCore

/// The routes as menu sections, shared by the toolbar and the composer: the chat's own model, the subagent
/// servers, the backups and the others, each marked private (a lock) or masked (a shield). With a chat, choosing one
/// switches *that chat* (and what its project's next chats start with) — another chat keeps its own model. Without
/// one, choosing makes it the primary. Routes that are switched off don't appear. A new primary keeps the previous
/// one working as a subagent server when a fleet is running — see `AppConfig.makeMain`.
struct RouteMenuSections: View {
    @Environment(AppModel.self) private var model
    /// The chat the choice is for (nil = the app's primary).
    var session: SessionVM? = nil

    var body: some View {
        let config = model.config
        let usable = config.providers.filter(\.isEnabled)
        let current = session.flatMap { model.transport.chatRouteID($0) } ?? config.activeRoute
        let workers = Set(model.transport.workerRoutes.map(\.routeID))
        let backups = Set(config.backupRoutes.map(\.routeID))
        let main = usable.filter { $0.routeID == current }
        let helping = usable.filter { workers.contains($0.routeID) && $0.routeID != current }
        let standingBy = usable.filter { backups.contains($0.routeID) && !workers.contains($0.routeID) && $0.routeID != current }
        let others = usable.filter { $0.routeID != current && !workers.contains($0.routeID) && !backups.contains($0.routeID) }

        section(session == nil ? "Primary — answers you" : "This chat", main, current: current)
        section("Subagents — take side tasks in parallel", helping, current: current)
        section("Backups — take over if the primary fails", standingBy, current: current)
        section("Other models", others, current: current)
        guardianSection(config, current: current)
        if session != nil, let current, current != config.activeRoute, usable.contains(where: { $0.routeID == current }) {
            Button("Make This the Primary (for new projects and the fleet)") {
                config.makeMain(current)
                model.transport.resetRouteCache()
            }
        }
        if usable.count > 1 {
            Menu("Use for Subagents") {
                ForEach(usable.filter { $0.routeID != config.activeRoute }, id: \.routeID) { provider in
                    Toggle(isOn: Binding(get: { provider.isSubagentWorker },
                                         set: { config.setSubagentWorker(provider.routeID, $0) })) {
                        Text(provider.displayName)
                    }
                }
            }
        }
        bedrockSection(config)
    }

    @ViewBuilder
    private func section(_ title: String, _ routes: [ProviderProfile], current: String?) -> some View {
        if !routes.isEmpty {
            Section(title) {
                ForEach(routes, id: \.routeID) { provider in
                    Button {
                        guard provider.routeID != current else { return }
                        if let session {
                            model.transport.setRoute(provider.routeID, for: session)
                        } else {
                            model.config.makeMain(provider.routeID)
                            model.transport.resetRouteCache()
                        }
                    } label: {
                        Label(provider.displayName,
                              systemImage: provider.routeID == current ? "checkmark"
                                  : provider.isPrivateRoute ? "lock.fill" : "shield.lefthalf.filled")
                    }
                    .help(provider.isPrivateRoute ? "Private: may see sensitive data" : "Not private: sensitive details are masked before sending")
                }
            }
        }
    }

    /// Guardian's models, while signed in to Guardian — there by themselves, no button to press. Signed out, a chat
    /// on one of them shows it here with what to do.
    @ViewBuilder
    private func guardianSection(_ config: AppConfig, current: String?) -> some View {
        let routes = config.guardianModelRoutes
        if !routes.isEmpty {
            Section("Guardian") {
                ForEach(routes, id: \.routeID) { route in
                    Button {
                        guard route.routeID != current else { return }
                        if let session {
                            model.transport.setRoute(route.routeID, for: session)
                        } else {
                            // The primary is a configured route: keep this one, on the sign-in's token.
                            config.store(route)
                            config.setAPIKey(config.guardianToken ?? "", for: route)
                            config.makeMain(route.routeID)
                            model.transport.resetRouteCache()
                        }
                    } label: {
                        Label(config.guardianMenuLabel(route.routeID),
                              systemImage: route.routeID == current ? "checkmark" : ProviderProfile.Kind.guardian.icon)
                    }
                    .help("Guardian (\(route.model)): sensitive details are masked before sending")
                }
            }
        } else if let current, config.isGuardianModel(current), config.guardianToken == nil {
            Section("Guardian") {
                Button("\(config.guardianMenuLabel(current)) — \(GuardianSignInNeeded.message)") {
                    model.settingsTab = .guardian
                    model.showSettings = true
                }
            }
        }
    }

    @ViewBuilder
    private func bedrockSection(_ config: AppConfig) -> some View {
        let routes = config.providers.filter { $0.kind == .bedrock }
        Section("Amazon Bedrock") {
            if routes.isEmpty {
                Button("Add Amazon Bedrock…") { model.showBedrockGuide() }
            } else {
                // The main model's route when it is a Bedrock one, else the first — the picker
                // replaces that route's model, so the fleet keeps its shape.
                let target = config.mainRoute.flatMap { $0.kind == .bedrock ? $0 : nil } ?? routes[0]
                Button("Choose a Bedrock Model…") { model.showBedrockGuide(page: .model, route: target) }
                Button("Add Another Bedrock Model…") { model.showBedrockGuide() }
            }
        }
    }
}
