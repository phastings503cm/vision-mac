import Foundation
import VisionHarnessCore

/// Persisted app configuration: providers, active model, permission preset,
/// recent projects, editor and terminal preferences. API keys are kept out of
/// the plist, in the Keychain, keyed by the provider's stable identity.
@MainActor
@Observable
public final class AppConfig {
    /// The app's settings: its own settings file and the Keychain (a throwaway file and memory in an isolated run).
    public static let shared = AppConfig(defaults: IsolatedRun.defaults)
    public init(defaults: UserDefaults = .standard, secrets: any SecretStore = AppSecrets.keychain) {
        self.defaults = defaults
        self.secrets = secrets
        load()
        // Custom terms an earlier build kept in the settings file move to the Keychain now.
        persistShield()
    }

    private enum Keys {
        static let providers = "providers.v2"
        static let activeModel = "activeModel.v2"
        static let preset = "permissionPreset.v1"
        static let recentProjects = "recentProjects.v1"
        static let wizardDone = "setupWizardCompleted.v1"
        static let editorFontSize = "editor.fontSize"
        static let editorWraps = "editor.wraps"
        static let editorLineNumbers = "editor.lineNumbers"
        static let terminalFontSize = "terminal.fontSize"
        static let terminalShell = "terminal.shell"
        static let lastMode = "workspace.mode"
        static let disabledSkills = "skills.disabled.v1"
        static let skillSources = "skills.sources.v1"
        static let sessionSkills = "skills.session.v1"
        static let computerTools = "computer.tools.v1"
        static let machineControl = "computer.control.v1"
        static let queuePaused = "queue.paused.v1"
        static let queueResume = "queue.resumeOnLaunch.v1"
        static let subagentsUsePrimary = "subagents.usePrimary.v1"
        static let shield = "shield.v1"
        static let planPanelOpen = "planPanel.open.v1"
        static let planPanelWidth = "planPanel.width.v1"
        static let planPanelAutoOpen = "planPanel.autoOpen.v1"
        static let projectChoices = "routes.byProject.v1"
        static let guardianPromptSync = "guardian.promptSync.v1"
    }

    private let defaults: UserDefaults
    /// Where API keys live: the Keychain (tests use memory).
    @ObservationIgnored let secrets: any SecretStore
    /// Set while `load()` runs so the property observers don't write back.
    private var loading = false
    /// The shield's custom terms as the Keychain holds them, as far as this app knows (nil: it couldn't be read),
    /// and as they were loaded — see `loadTerms`.
    @ObservationIgnored fileprivate var keychainTerms: [String]?
    @ObservationIgnored fileprivate var loadedTerms: [String] = []

    public var providers: [ProviderProfile] = [] {
        didSet { persist(); routesChanged() }
    }
    /// Identity of the active route: `"<provider name>|<model>"`. The active
    /// route is the *main model*: the chat talks to it and it hands out subagent
    /// tasks. Routes flagged `subagentWorker` take those tasks (see `AgentFleet`).
    public var activeRoute: String? {
        didSet { persist(); routesChanged() }
    }
    /// When every subagent server is busy, let subagents use the main model's
    /// server too. False keeps it free for the main agent.
    public var subagentsUsePrimary: Bool = true {
        didSet { persist(); routesChanged() }
    }
    /// Called whenever the set of routes, the main model or the subagent
    /// settings change, so the fleet can be rebuilt. Not called while loading.
    @ObservationIgnored public var onRoutesChanged: (@MainActor () -> Void)?
    /// Signed in to Guardian: send each prompt (masked) to the Guardian prompt notebook, with how it ended.
    public var guardianPromptSync: Bool = true {
        didSet { persist() }
    }
    /// What the sensitive-data shield masks before a request goes to a model that isn't private.
    public var shield = ShieldSettings() {
        didSet {
            persist()
            if !loading { onShieldChanged?() }
        }
    }
    /// Called when the shield's settings change (not while loading).
    @ObservationIgnored public var onShieldChanged: (@MainActor () -> Void)?
    /// A `PermissionPreset` raw value: workspaceWrite | plan | fullAccess.
    public var preset: String = PermissionPreset.workspaceWrite.rawValue {
        didSet { persist() }
    }
    public var recentProjects: [String] = [] {
        didSet { persist() }
    }
    public var wizardCompleted: Bool = false {
        didSet { if !loading { defaults.set(wizardCompleted, forKey: Keys.wizardDone) } }
    }

    // Editor / terminal preferences.
    public var editorFontSize: Double = 13 { didSet { persist() } }
    public var editorWraps: Bool = false { didSet { persist() } }
    public var editorLineNumbers: Bool = true { didSet { persist() } }
    public var terminalFontSize: Double = 12 { didSet { persist() } }
    public var terminalShell: String = "" { didSet { persist() } }
    /// "chat" or "code" — the workspace reopens where you left it.
    public var lastMode: String = "chat" { didSet { persist() } }

    // Skills.
    /// Skill ids (file paths) switched off everywhere.
    public var disabledSkills: Set<String> = [] { didSet { persist() } }
    /// Which foreign layouts are read in place (.claude, .cursor, .agents, .qwen).
    public var skillSources: SkillSources = .all { didSet { persist() } }
    /// Per-chat skill choices: what's selected by hand, and whether the model may pick.
    public var sessionSkills: [String: SessionSkillSelection] = [:] { didSet { persist() } }

    /// Screen, mouse/keyboard and background-process tools offered to the agent.
    public var computerToolsEnabled: Bool = true { didSet { persist() } }
    /// How chats act on the machine: in the background first, how long they wait for the real mouse, whether
    /// each is limited to its own apps (Settings ▸ Computer).
    public var machineControl = MachineControlOptions() { didSet { persist() } }

    /// Per project folder ("" = chats without a project): the model and thinking level its chats last chose — what
    /// a new chat there starts with (see `ChatRoutes.swift`).
    public var projectChoices: [String: ChatChoice] = [:] { didSet { persist() } }

    // The plan panel.
    /// Whether the plan panel is showing (it follows whichever chat is selected).
    public var planPanelOpen = false { didSet { persist() } }
    /// Its width, as the user last dragged it.
    public var planPanelWidth: Double = 320 { didSet { persist() } }
    /// "Show when the agent makes a plan": the panel opens by itself the first time a chat's agent writes a todo
    /// list or proposes a plan.
    public var planPanelAutoOpen = true { didSet { persist() } }

    /// The task queue is deliberately paused (the user pressed Stop). A crash
    /// or restart does *not* set this, so an interrupted queue resumes on
    /// launch — a stopped one stays stopped.
    public var queuePaused: Bool = false { didSet { persist() } }

    /// The task queue was working when the app last quit (or crashed), so it
    /// picks up again on launch. Set by Start, cleared by Stop, by a pause
    /// and when the queue runs dry — tasks merely *added* never auto-start.
    public var queueResumeOnLaunch: Bool = false { didSet { persist() } }

    // MARK: - Active route

    /// The provider/model pair the next session will use, with its API key
    /// filled in from the Keychain.
    public var activeProvider: ProviderProfile? {
        guard let activeRoute, let stored = providers.first(where: { $0.routeID == activeRoute })
        else { return nil }
        var resolved = stored
        let key = apiKey(for: stored)
        resolved.apiKey = key.isEmpty ? nil : key
        return resolved
    }

    public var isConfigured: Bool { activeProvider != nil }

    /// Make this provider the active route.
    public func activate(_ provider: ProviderProfile) {
        if let index = providers.firstIndex(where: { $0.routeID == provider.routeID }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        activeRoute = provider.routeID
    }

    /// Save a route without changing which one is the main model: a new route is
    /// added, an existing one (same identity) replaced.
    public func store(_ provider: ProviderProfile) {
        if let index = providers.firstIndex(where: { $0.routeID == provider.routeID }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    /// Save a route a guide made without trampling one the user already has.
    ///
    /// When a route of the same name and model exists and `isSame` says it is this one (the same box; the same
    /// plan with the same key), it is updated with what the guide knows — its address, certificate and key, and its
    /// privacy when `privacyChosen` — and keeps everything else the user set on it: context window, thinking,
    /// temperature, headers, subagents at a time, interactive-only, roles. One that isn't the same is left alone,
    /// and the new route gets a name of its own ("Strix Halo (evo-x2) 2"). The key goes to the Keychain.
    @discardableResult
    public func saveGuided(_ route: ProviderProfile, key: String, privacyChosen: Bool,
                           isSame: (ProviderProfile) -> Bool) -> (route: ProviderProfile, isNew: Bool) {
        var route = route
        route.apiKey = nil
        if let index = providers.firstIndex(where: { $0.routeID == route.routeID }) {
            if isSame(providers[index]) {
                var merged = providers[index]
                merged.baseURL = route.baseURL
                merged.pinnedCertificate = route.pinnedCertificate
                if let vision = route.vision { merged.vision = vision }
                if route.interactiveOnly == true { merged.interactiveOnly = true }
                if privacyChosen { merged.isPrivate = Self.privacy(route.isPrivateRoute, for: merged) }
                providers[index] = merged
                setAPIKey(key, for: merged)
                return (merged, false)
            }
            let base = route.name
            var n = 2
            while providers.contains(where: { $0.routeID == ProviderProfile.routeID(name: "\(base) \(n)", model: route.model) }) {
                n += 1
            }
            route.name = "\(base) \(n)"
        }
        providers.append(route)
        setAPIKey(key, for: route)
        return (route, true)
    }

    /// The stored value for a privacy choice: nil when it is what the route's address gives anyway, so the route
    /// keeps following its address.
    public nonisolated static func privacy(_ on: Bool, for route: ProviderProfile) -> Bool? {
        on == RoutePrivacy.isPrivateByDefault(route) ? nil : on
    }

    /// Swap one route for an edited or re-picked one *in place*: it keeps its position and, if it was the
    /// main model, stays the main model — the guide uses this to change a Bedrock route's model without
    /// disturbing the arrangement (a route serving subagents keeps serving them, because the new route
    /// carries the old one's flags). If `new` has the identity of a different existing route, that
    /// route is the one that remains, updated.
    public func replace(_ old: ProviderProfile, with new: ProviderProfile) {
        let wasMain = activeRoute == old.routeID
        guard let index = providers.firstIndex(where: { $0.routeID == old.routeID }) else {
            store(new)
            return
        }
        if new.routeID != old.routeID, let clash = providers.firstIndex(where: { $0.routeID == new.routeID }) {
            // The wanted route already exists: drop the old one and update the other.
            providers[clash] = new
            providers.remove(at: index)
        } else {
            providers[index] = new
        }
        if wasMain { activeRoute = new.routeID }
    }

    public func removeProvider(_ provider: ProviderProfile) {
        providers.removeAll { $0.routeID == provider.routeID }
        if activeRoute == provider.routeID {
            // The lead goes to a route that is switched on — or, with none on, to the first one, switched on: the
            // main model is always on.
            guard let next = providers.firstIndex(where: \.isEnabled) ?? providers.indices.first else {
                activeRoute = nil
                return
            }
            if !providers[next].isEnabled { providers[next].enabled = nil }
            activeRoute = providers[next].routeID
        }
    }

    // MARK: - The fleet

    /// The routes as the user arranged them: which is the main model and which
    /// serve subagents. Read by the settings and the model menu.
    public var mainRoute: ProviderProfile? { providers.first { $0.routeID == activeRoute } }

    /// Routes flagged to serve subagents, the main model excluded (it cannot
    /// be its own worker) and so are routes that are switched off. The fleet
    /// may still collapse machines that are the same server — see
    /// `AppTransport.workerRoutes`.
    public var flaggedWorkers: [ProviderProfile] {
        providers.filter { $0.isEnabled && $0.isSubagentWorker && $0.runsVisionEngine && $0.routeID != activeRoute }
    }

    /// The routes that take over, in order, when the main model stops answering: switched on, marked
    /// "Use if the primary fails", and not the main model itself.
    public var backupRoutes: [ProviderProfile] {
        providers.filter { $0.isEnabled && $0.isBackup && $0.runsVisionEngine && $0.routeID != activeRoute }
    }

    /// Switch a route on or off. The main model can't be switched off (pick another one first): returns false.
    @discardableResult
    public func setEnabled(_ routeID: String, _ on: Bool) -> Bool {
        guard let index = providers.firstIndex(where: { $0.routeID == routeID }) else { return false }
        if !on, routeID == activeRoute { return false }
        guard providers[index].isEnabled != on else { return true }
        providers[index].enabled = on ? nil : false
        return true
    }

    /// Tick or untick "Use if the primary fails" on a route.
    public func setBackup(_ routeID: String, _ on: Bool) {
        guard let index = providers.firstIndex(where: { $0.routeID == routeID }),
              providers[index].isBackup != on else { return }
        providers[index].backup = on ? true : nil
    }

    /// The user's own choice of whether a route may see sensitive data. A choice that differs from what the
    /// route's address gives is stored and wins; one that equals it is stored as nil, so the route keeps following
    /// its address.
    public func setPrivate(_ routeID: String, _ on: Bool) {
        guard let index = providers.firstIndex(where: { $0.routeID == routeID }) else { return }
        let value = Self.privacy(on, for: providers[index])
        guard providers[index].isPrivate != value else { return }
        providers[index].isPrivate = value
    }

    /// A route's stored privacy after it was edited: a choice that only said what the old address gave anyway is
    /// dropped when the address moves to another host (the new host decides), and one that equals the new default
    /// is nil.
    public nonisolated static func privacy(after edited: ProviderProfile, was old: ProviderProfile) -> Bool? {
        guard let choice = edited.isPrivate else { return nil }
        let oldHost = URL(string: old.baseURL)?.host?.lowercased(), newHost = URL(string: edited.baseURL)?.host?.lowercased()
        if oldHost != newHost, choice == RoutePrivacy.isPrivateByDefault(old) { return nil }
        return privacy(choice, for: edited)
    }

    /// The main model's route when the plan behind it is for interactive use only; nil otherwise.
    public var interactiveOnlyMain: ProviderProfile? {
        mainRoute.flatMap { $0.isInteractiveOnly ? $0 : nil }
    }

    /// How a route is named next to a subagent: the route's own name (e.g. "Spark 2").
    public nonisolated static func routeLabel(_ route: ProviderProfile) -> String {
        route.name.isEmpty ? route.model : route.name
    }

    /// The routes subagents currently run on (workers). One self-hosted machine is one worker however
    /// many models it is listed with (a Spark serves one at a time, so a second route there would only
    /// queue behind the first), and the main route's own machine is never its own worker. A hosted
    /// service (Bedrock, OpenAI …) serves every model at once: those are told apart by route, so a
    /// cheaper model in the same Region can take the side tasks while a stronger one is the main model.
    public var workerRoutes: [ProviderProfile] {
        var seen = Set<String>()
        if let main = mainRoute { seen.insert(Self.machineOf(main)) }
        return flaggedWorkers.filter { seen.insert(Self.machineOf($0)).inserted }
    }

    /// What counts as "the same server": a self-hosted route is its base URL; a hosted service
    /// (Bedrock, OpenAI, …) is its own route.
    public nonisolated static func machineOf(_ route: ProviderProfile) -> String {
        route.kind != .bedrock && route.isSelfHosted
            ? route.baseURL.trimmingCharacters(in: .whitespaces).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : "route:" + route.routeID
    }

    /// Make another route the main model — the *conductor*.
    ///
    /// When a fleet is running (some other route serves subagents) the previous
    /// main model stays in it as a subagent server, so swapping who leads never
    /// drops a machine: three servers before, three servers after. Its own
    /// settings are untouched, and a route that was a subagent server keeps
    /// that flag for when it steps down again.
    public func makeMain(_ routeID: String) {
        guard routeID != activeRoute, let index = providers.firstIndex(where: { $0.routeID == routeID }) else { return }
        // The main model is always switched on.
        if !providers[index].isEnabled { providers[index].enabled = nil }
        if let old = providers.firstIndex(where: { $0.routeID == activeRoute }),
           !providers[old].isSubagentWorker,
           // A fleet exists when some route besides the current main serves subagents — the route
           // about to become main included: {A main, B worker} must stay two servers after B leads.
           providers.contains(where: { $0.isEnabled && $0.isSubagentWorker && $0.routeID != activeRoute }) {
            providers[old].subagentWorker = true
        }
        activeRoute = routeID
    }

    /// Tick or untick "use for subagents" on a route.
    public func setSubagentWorker(_ routeID: String, _ on: Bool) {
        guard let index = providers.firstIndex(where: { $0.routeID == routeID }),
              providers[index].isSubagentWorker != on else { return }
        providers[index].subagentWorker = on ? true : nil
    }

    /// How many subagents may work on a route at once (nil = the default).
    public func setSubagentParallel(_ routeID: String, _ count: Int?) {
        guard let index = providers.firstIndex(where: { $0.routeID == routeID }),
              providers[index].subagentParallel != count else { return }
        providers[index].subagentParallel = count
    }

    private func routesChanged() {
        guard !loading else { return }
        onRoutesChanged?()
    }

    /// The client to drive sessions with.
    /// Throws `LLMError.noModel` when nothing is configured, which the UI uses
    /// to route back to the setup wizard.
    public func makeClient() throws -> any ProviderClient {
        guard let provider = activeProvider else { throw LLMError.noModel }
        return ProviderClients.make(provider)
    }

    public var asPreset: PermissionPreset {
        PermissionPreset(rawValue: preset) ?? .workspaceWrite
    }

    // MARK: - Keychain
    //
    // Keyed by the provider's stable identity rather than its position, so
    // reordering or deleting a provider never hands its key to another one.

    private static let keychainService = AppIdentity.KeychainService.provider

    public func setAPIKey(_ key: String, for provider: ProviderProfile) {
        secrets.write(key, service: Self.keychainService, account: provider.routeID)
    }

    public func apiKey(for provider: ProviderProfile) -> String {
        secrets.read(service: Self.keychainService, account: provider.routeID) ?? ""
    }

    // MARK: - Projects

    /// Record a folder as recently opened (newest first, capped).
    public func touchProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        if recentProjects.count > 12 { recentProjects = Array(recentProjects.prefix(12)) }
    }

    public func forgetProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
    }

    /// Recent projects that still exist on disk.
    public var liveRecentProjects: [URL] {
        recentProjects
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Persistence

    private func load() {
        loading = true
        defer { loading = false }
        if let data = defaults.data(forKey: Keys.providers),
           let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data),
           !decoded.isEmpty {
            providers = decoded
        } else {
            providers = ProviderProfile.presets
        }
        activeRoute = defaults.string(forKey: Keys.activeModel)
        // The main model can't be switched off: a settings file that says otherwise has it on.
        if let main = providers.firstIndex(where: { $0.routeID == activeRoute }), !providers[main].isEnabled {
            providers[main].enabled = nil
        }
        preset = defaults.string(forKey: Keys.preset) ?? PermissionPreset.workspaceWrite.rawValue
        recentProjects = defaults.stringArray(forKey: Keys.recentProjects) ?? []
        wizardCompleted = defaults.bool(forKey: Keys.wizardDone)
        editorFontSize = defaults.object(forKey: Keys.editorFontSize) as? Double ?? 13
        editorWraps = defaults.object(forKey: Keys.editorWraps) as? Bool ?? false
        editorLineNumbers = defaults.object(forKey: Keys.editorLineNumbers) as? Bool ?? true
        terminalFontSize = defaults.object(forKey: Keys.terminalFontSize) as? Double ?? 12
        terminalShell = defaults.string(forKey: Keys.terminalShell) ?? ""
        lastMode = defaults.string(forKey: Keys.lastMode) ?? "chat"
        disabledSkills = Set(defaults.stringArray(forKey: Keys.disabledSkills) ?? [])
        skillSources = SkillSources(rawValue: defaults.object(forKey: Keys.skillSources) as? Int ?? SkillSources.all.rawValue)
        if let data = defaults.data(forKey: Keys.sessionSkills),
           let decoded = try? JSONDecoder().decode([String: SessionSkillSelection].self, from: data) {
            sessionSkills = decoded
        }
        computerToolsEnabled = defaults.object(forKey: Keys.computerTools) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.machineControl),
           let decoded = try? JSONDecoder().decode(MachineControlOptions.self, from: data) {
            machineControl = decoded
        }
        queuePaused = defaults.bool(forKey: Keys.queuePaused)
        queueResumeOnLaunch = defaults.bool(forKey: Keys.queueResume)
        subagentsUsePrimary = defaults.object(forKey: Keys.subagentsUsePrimary) as? Bool ?? true
        guardianPromptSync = defaults.object(forKey: Keys.guardianPromptSync) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.shield), let decoded = try? JSONDecoder().decode(ShieldSettings.self, from: data) {
            shield = decoded
        }
        loadTerms()
        planPanelOpen = defaults.bool(forKey: Keys.planPanelOpen)
        planPanelWidth = defaults.object(forKey: Keys.planPanelWidth) as? Double ?? 320
        planPanelAutoOpen = defaults.object(forKey: Keys.planPanelAutoOpen) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.projectChoices),
           let decoded = try? JSONDecoder().decode([String: ChatChoice].self, from: data) {
            projectChoices = decoded
        }
    }

    private func persist() {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.providers)
        }
        defaults.set(activeRoute, forKey: Keys.activeModel)
        defaults.set(preset, forKey: Keys.preset)
        defaults.set(recentProjects, forKey: Keys.recentProjects)
        defaults.set(editorFontSize, forKey: Keys.editorFontSize)
        defaults.set(editorWraps, forKey: Keys.editorWraps)
        defaults.set(editorLineNumbers, forKey: Keys.editorLineNumbers)
        defaults.set(terminalFontSize, forKey: Keys.terminalFontSize)
        defaults.set(terminalShell, forKey: Keys.terminalShell)
        defaults.set(lastMode, forKey: Keys.lastMode)
        defaults.set(Array(disabledSkills).sorted(), forKey: Keys.disabledSkills)
        defaults.set(skillSources.rawValue, forKey: Keys.skillSources)
        if let data = try? JSONEncoder().encode(sessionSkills) { defaults.set(data, forKey: Keys.sessionSkills) }
        defaults.set(computerToolsEnabled, forKey: Keys.computerTools)
        if let data = try? JSONEncoder().encode(machineControl) { defaults.set(data, forKey: Keys.machineControl) }
        defaults.set(queuePaused, forKey: Keys.queuePaused)
        defaults.set(queueResumeOnLaunch, forKey: Keys.queueResume)
        defaults.set(subagentsUsePrimary, forKey: Keys.subagentsUsePrimary)
        // Stored only when switched off, so the default can change later.
        if guardianPromptSync { defaults.removeObject(forKey: Keys.guardianPromptSync) }
        else { defaults.set(false, forKey: Keys.guardianPromptSync) }
        persistShield()
        defaults.set(planPanelOpen, forKey: Keys.planPanelOpen)
        defaults.set(planPanelWidth, forKey: Keys.planPanelWidth)
        defaults.set(planPanelAutoOpen, forKey: Keys.planPanelAutoOpen)
        if let data = try? JSONEncoder().encode(projectChoices) { defaults.set(data, forKey: Keys.projectChoices) }
    }
}

extension AppConfig {
    // MARK: - The shield's custom terms
    //
    // Custom terms are client and patient names, so they live in the Keychain (one item), not in the settings
    // file. An earlier build kept them in the file: they move over once, and leave the file only when the Keychain
    // has them. A Keychain that can't be read never costs terms — the file keeps its copy, and nothing is written
    // over what the Keychain may still hold unless the user changes the terms.

    static let termsService = AppIdentity.KeychainService.shield
    static let termsAccount = "terms"

    /// Read the terms: the Keychain's — unless the settings file still has a list, which is then the newer one (the
    /// file keeps terms only while the Keychain couldn't take them).
    fileprivate func loadTerms() {
        let inFile = shield.customTerms
        loadedTerms = inFile
        switch secrets.lookup(service: Self.termsService, account: Self.termsAccount) {
        case .found(let stored):
            let saved = Self.decodeTerms(stored)
            keychainTerms = saved
            if inFile.isEmpty {
                shield.customTerms = saved
                loadedTerms = saved
            }
        case .missing:
            keychainTerms = []
        case .unavailable:
            keychainTerms = nil
        }
    }

    /// The shield's settings to the file, its terms to the Keychain.
    fileprivate func persistShield() {
        let terms = shield.customTerms
        if keychainTerms != terms, keychainTerms != nil || terms != loadedTerms, writeTerms(terms) {
            keychainTerms = terms
        }
        var file = shield
        if keychainTerms == terms { file.customTerms = [] }
        if let data = try? JSONEncoder().encode(file) { defaults.set(data, forKey: Keys.shield) }
    }

    /// Write the terms and read them back: only a Keychain that has them lets the file's copy go.
    private func writeTerms(_ terms: [String]) -> Bool {
        let value = terms.isEmpty ? nil : (try? JSONEncoder().encode(terms)).map { String(decoding: $0, as: UTF8.self) }
        secrets.write(value, service: Self.termsService, account: Self.termsAccount)
        switch secrets.lookup(service: Self.termsService, account: Self.termsAccount) {
        case .found(let stored): return Self.decodeTerms(stored) == terms
        case .missing: return terms.isEmpty
        case .unavailable: return false
        }
    }

    nonisolated static func decodeTerms(_ stored: String) -> [String] {
        if let list = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)) { return list }
        return stored.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// What the user chose for one chat: skills selected by hand, and whether the
/// model may also pick skills itself.
public struct SessionSkillSelection: Codable, Hashable, Sendable {
    public var pinned: [String] = []
    public var auto: Bool = true
    public init(pinned: [String] = [], auto: Bool = true) {
        self.pinned = pinned
        self.auto = auto
    }
}

public extension ProviderProfile {
    /// A local server needs no key and should not be nagged for one.
    var needsAPIKey: Bool {
        switch kind {
        case .ollama, .lmStudio: return false
        case .openAICompat: return !isLoopbackOrLAN
        case .openAI, .openRouter: return true
        // A Bedrock route signs with an AWS sign-in; only one without a profile uses a Bedrock API key.
        case .bedrock: return awsProfile == nil
        // Guardian signs in with the account login; the session token is stored like a key.
        case .guardian: return false
        // Claude Code signs in with the person's Claude plan, inside the CLI — Vision holds nothing.
        case .claudeCode: return false
        }
    }

    var isLoopbackOrLAN: Bool {
        guard let host = URL(string: baseURL)?.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        // 172.16.0.0 – 172.31.255.255
        if host.hasPrefix("172.") {
            let second = host.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 0
            return (16...31).contains(second)
        }
        return false
    }

    var displayName: String { "\(name) · \(model)" }
}
