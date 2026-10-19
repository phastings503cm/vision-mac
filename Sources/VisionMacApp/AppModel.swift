import SwiftUI
import Observation
import VisionHarnessCore

/// Which half of the app the window is showing.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case chat, code
    var id: String { rawValue }

    var label: String { self == .chat ? "Chat" : "Code" }
    var icon: String { self == .chat ? "bubble.left.and.bubble.right" : "chevron.left.forwardslash.chevron.right" }
}

enum SettingsTab: Hashable { case general, models, spark, guardian, skills, computer, plugins, editor }
enum SkillsAction: Equatable { case generate, importSkills, newManual }

/// Root-level state: the config, the transport that drives sessions, the
/// current project folder, and the code-mode workspace.
@MainActor
@Observable
final class AppModel {
    let config = AppConfig.shared
    let transport: AppTransport
    /// The DGX Spark's model switcher.
    let spark: SparkController
    /// File tree, open editors, and terminals for the current project.
    let code = CodeWorkspace()

    var mode: WorkspaceMode = .chat {
        didSet { config.lastMode = mode.rawValue }
    }
    /// Presented over everything on first run, and on demand afterwards.
    var showWizard = false
    var showSettings = false
    var showMemoryAndSkills = false
    /// The task-queue side panel.
    var showQueuePanel = false
    /// The credential vault window.
    var showVault = false
    /// The Amazon Bedrock guide, when it is open (nil = closed).
    var bedrockGuide: BedrockGuideRequest?
    /// The "Connect my Spark Swapper" guide, when it is open.
    var swapperGuide: SwapperGuideRequest?
    /// The "Connect a subscription plan" guide, when it is open.
    var planGuide: PlanGuideRequest?
    /// Which Settings tab is showing; set before `showSettings` to deep-link.
    var settingsTab: SettingsTab = .general
    /// A skills action a caller wants the Skills tab to start with.
    var skillsAction: SkillsAction?
    /// Text a caller wants dropped into the selected chat's composer (the
    /// prompt timeline's "Reuse in composer"). ChatView picks it up in
    /// `onChange`, like `code.pendingMention`.
    var pendingComposerText: String?
    /// The Guardian connection: sign-in state, prompt sync, skills, chats.
    let guardian = GuardianService(appSupport: AppPaths.support)
    /// The folder both modes operate in.
    private(set) var project: URL?
    /// The one-time "DSH is now Vision" notice, until the user dismisses it.
    private(set) var renameNotice: String?

    init() {
        // Bedrock routes sign their requests with credentials the AWS CLI exports for their profile.
        AWSAccounts.install()
        // What model servers refused before (a temperature Kimi fixes, …) is remembered across launches.
        RequestAdaptationStore.shared.fileURL = AppPaths.requestAdaptationsFile
        transport = AppTransport(config: config)
        spark = SparkController(config: config, transport: transport)
        // Guardian's shared state: prompts on submit, turn durations for the
        // multitenant ETA cache, and the transport back-reference for the
        // sign-in-time ETA blend.
        let guardian = guardian
        guardian.transport = transport
        transport.guardianEtaPush = { kind, scope, seconds in
            guardian.pushEta(kindRawValue: kind, scope: scope, seconds: seconds)
        }
        // A prompt sent while signed into Guardian lands in the account's
        // prompt history (the service deduplicates).
        transport.guardianSync = { record, chatID in
            let outcome: String? = {
                switch record.outcome {
                case .none: return nil
                case .completed: return "completed"
                case .blocked: return "needs you"
                case .failed: return "failed"
                case .stopped: return "stopped"
                }
            }()
            Task { await guardian.syncPrompts([
                .init(id: record.id, text: record.text, at: record.at, outcome: outcome, chatID: chatID),
            ]) }
        }
        // Requests to models that aren't private go through the sensitive-data shield: the user's settings, and
        // every secret in the Credentials Vault.
        let vault = transport.vault
        let policy = ShieldPolicy(settings: config.shield, vaultValues: { vault.valuesForRedaction().map(\.value) })
        ProviderClients.shield = policy
        mode = WorkspaceMode(rawValue: config.lastMode) ?? .chat
        showWizard = !config.wizardCompleted || !config.isConfigured
        if IsolatedRun.defaults.bool(forKey: LegacySettingsImport.noticePendingKey) {
            renameNotice = LaunchMigration.renameNotice
        }
        if let failure = LaunchMigration.failure {
            transport.banner = "\(AppIdentity.name) couldn't move its data to its own folder yet (\(failure)), so it is "
                + "working where \(AppIdentity.Legacy.name) kept it. It tries again the next time it opens."
        }

        let spark = spark
        let config = config, transport = transport
        config.onShieldChanged = {
            policy.current = config.shield
            // Clients are made with the engines: the next turn makes them again.
            transport.resetRouteCache()
        }
        transport.isServerSwitching = { spark.isSwitchingMainModel }
        transport.onSwapCommand = { arg, vm in
            Task { @MainActor in await spark.handleCommand(arg, in: vm) }
        }
        spark.startMonitoring()

        // The agent's file writes drive the editor's live reload.
        transport.onFilesChanged = { [weak self] changes in
            self?.code.applyExternalChanges(changes)
        }

        // Reopen the most recent project so the app comes back where it left off.
        if let recent = config.liveRecentProjects.first {
            openProject(recent, activateSession: false)
        }

        // An interrupted task queue (crash, restart, quit) resumes automatically;
        // one the user deliberately stopped does not.
        resumeQueueIfNeeded()
    }

    /// If the last session left work in the queue and the user didn't explicitly
    /// stop it, start processing it again. Requires a configured model — we never
    /// want to auto-fail a whole queue because the Spark is down at launch.
    func resumeQueueIfNeeded() {
        guard config.isConfigured,
              config.queueResumeOnLaunch,
              !config.queuePaused,
              transport.queue.nextTask != nil else { return }
        transport.startQueue()
    }

    var selectedSession: SessionVM? { transport.selected }

    func dismissRenameNotice() {
        renameNotice = nil
        IsolatedRun.defaults.removeObject(forKey: LegacySettingsImport.noticePendingKey)
    }

    /// Show or hide the plan panel.
    func togglePlan() {
        withAnimation(.easeInOut(duration: 0.18)) { config.planPanelOpen.toggle() }
    }

    /// Open the Amazon Bedrock guide — from the start, or on one page for an existing route
    /// (change its model, sign in again).
    func showBedrockGuide(page: BedrockPage = .welcome, route: ProviderProfile? = nil) {
        bedrockGuide = BedrockGuideRequest(page: page, route: route)
    }

    /// Open the "Connect my Spark Swapper" guide (a connection code, or an address and login).
    func showSwapperGuide(closing sheet: Bool = false) {
        openGuide(closing: sheet) { $0.swapperGuide = SwapperGuideRequest() }
    }

    /// Open the "Connect a subscription plan" guide (GLM, Kimi, Qwen, OpenAI) — on one plan when `plan` names it
    /// (the Z.ai (GLM) entries open it on "zai").
    func showPlanGuide(closing sheet: Bool = false, plan: String? = nil) {
        openGuide(closing: sheet) { $0.planGuide = PlanGuideRequest(planID: plan) }
    }

    /// Open a guide's sheet. From another sheet (the wizard, Settings), that one closes first so this one can open.
    private func openGuide(closing sheet: Bool, _ open: @escaping @MainActor (AppModel) -> Void) {
        guard sheet || showSettings || showWizard else {
            open(self)
            return
        }
        showSettings = false
        showWizard = false
        Task { @MainActor in
            // Let the sheet finish closing before the next one opens.
            try? await Task.sleep(nanoseconds: 400_000_000)
            open(self)
        }
    }

    // MARK: - Projects

    /// Ask for a folder and adopt it.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder the agent should work in."
        if let project { panel.directoryURL = project }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    /// Adopt `url` as the project: it becomes the agent's working directory,
    /// the permission boundary, and the root of the file tree.
    func openProject(_ url: URL, activateSession: Bool = true) {
        project = url
        config.touchProject(url.path)
        transport.adoptProject(url)
        code.open(root: url)

        guard activateSession else { return }
        // Return to this project's most recent chat rather than piling up
        // empty ones.
        if let existing = transport.sessions.first(where: { $0.cwd == url.path }) {
            select(existing.id)
        } else {
            _ = newChat()
        }
    }

    func closeProject() {
        project = nil
        transport.adoptProject(nil)
        code.close()
    }

    func forgetProject(_ url: URL) {
        config.forgetProject(url.path)
        if project == url { closeProject() }
    }

    // MARK: - Sessions

    func select(_ id: String?) {
        transport.selectedID = id
        if let session = transport.selected {
            transport.hydrate(session)
            // Make sure the context gauge has a number before the user asks.
            transport.ensureContextProbe()
            // Following a chat into its project keeps both modes in step.
            if let cwd = session.cwd, cwd != project?.path {
                openProject(URL(fileURLWithPath: cwd), activateSession: false)
            }
        }
    }

    @discardableResult
    func newChat() -> SessionVM {
        let session = transport.newSession(cwd: project?.path)
        transport.ensureContextProbe()
        return session
    }

    /// A regular conversation — no project, even while one is open.
    @discardableResult
    func newPlainChat() -> SessionVM {
        mode = .chat
        let session = transport.newSession(cwd: nil)
        transport.ensureContextProbe()
        return session
    }

    func send(_ text: String, in session: SessionVM, attachments: [MessageAttachment] = []) {
        transport.send(text, sessionID: session.id, attachments: attachments)
    }

    // MARK: - Stopping

    func stopSelected() {
        guard let session = selectedSession, session.running else { return }
        transport.stopSession(session.id)
    }

    func stopAll() { transport.stopAll() }

    /// Jump to a chat by id (used by the queue's "Open chat").
    func openSession(_ id: String) {
        mode = .chat
        select(id)
    }

    var anythingRunning: Bool { transport.anythingRunning }
}
