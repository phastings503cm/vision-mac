import Foundation
import Observation
import VisionHarnessCore

/// Drives agent sessions in-process: one `Engine` per conversation, its event
/// stream folded into the session's timeline, items mirrored to the
/// `ConversationLog`. This app IS the harness — no external process.
@MainActor
@Observable
public final class AppTransport {
    public let config: AppConfig
    public let log: ConversationLog

    public private(set) var sessions: [SessionVM] = []
    public var selectedID: String?
    public var banner: String? {
        // A banner about something else is no longer about the AWS sign-in.
        didSet { awsSignInProfile = nil }
    }
    /// Set right after a banner that says a Bedrock route's AWS sign-in ran out: the AWS CLI profile
    /// the banner's "Sign in to AWS…" button signs in again.
    public var awsSignInProfile: String?
    /// Plugin manifests loaded for the current project, and any that failed.
    public private(set) var plugins: [PluginManifest] = []
    public private(set) var pluginErrors: [String] = []
    /// Instruction files and skills the active project contributes.
    public private(set) var projectContext: ProjectContext?
    /// AI-generated, agent-proposed and imported skills waiting for approval.
    public private(set) var pendingDrafts: [SkillDraft] = []
    /// Bumped whenever skills change on disk through the app, so open views reload.
    public private(set) var skillsRevision = 0
    @ObservationIgnored public let skillLocations: SkillLocations
    /// API keys, tokens and passwords the agent uses as `{{vault:NAME}}`.
    @ObservationIgnored public let vault: CredentialVault
    /// Bumped when the vault changes through the app, so open views reload
    /// and engines rebuild their prompt.
    public private(set) var vaultRevision = 0
    /// Per chat: credentials set to "ask first" that the user has allowed.
    @ObservationIgnored private var vaultGrants: [String: VaultGrants] = [:]
    /// Per chat: background subagents it launched.
    @ObservationIgnored var backgroundPools: [String: BackgroundAgents] = [:]
    /// The model servers subagents run on: the main route is the primary, the routes flagged "Use for
    /// subagents" are workers. One per app, shared by every chat, so two chats can't both fill the same Spark.
    @ObservationIgnored let fleet = AgentFleet()
    /// Per chat: every subagent it started — waiting for a server, working, finished.
    @ObservationIgnored var rosters: [String: AgentRoster] = [:]
    /// Worker route → what the server said it serves, and when (a Spark may have swapped models since).
    @ObservationIgnored var workerProbe: [String: (info: ModelInfo, at: Date)] = [:]
    /// Agent types by project folder, with the stamp of the files they were read from.
    @ObservationIgnored var agentCatalogs: [String: (catalog: AgentCatalog, stamp: String)] = [:]
    /// Per chat: queue tasks the agent has added (capped, so a runaway loop
    /// can't flood the queue).
    @ObservationIgnored private var agentQueuedCount: [String: Int] = [:]
    static let maxAgentQueuedTasksPerChat = 20
    /// Automatic continuations since the user last sent something, per chat.
    @ObservationIgnored var autoContinuations: [String: Int] = [:]
    /// Chats carrying on by themselves right now (after their background agents finished): unattended work.
    @ObservationIgnored var autoTurns: Set<String> = []
    static let maxAutoContinuations = 3
    /// Where the task queue is persisted.
    @ObservationIgnored private let queueFile: URL
    /// How engines retry model calls that fail transiently (tests shorten it).
    @ObservationIgnored var retryPolicy: RetryPolicy = .standard
    /// Pause before re-running a goal round that failed on an error, by how
    /// many rounds in a row have failed (tests shorten it).
    @ObservationIgnored var goalErrorBackoff: @Sendable (Int) -> TimeInterval = { RequestRetry.backoff(attempt: $0 + 1) }

    @ObservationIgnored private var engines: [String: Engine] = [:]
    /// What each session's engine was built with; a mismatch rebuilds it
    /// (provider or served model changed, window re-detected, thinking level).
    @ObservationIgnored private var engineKeys: [String: EngineKey] = [:]
    @ObservationIgnored private var transcripts: [String: [LLMMessage]] = [:]
    /// Pending permission questions, keyed by a token unique to each question
    /// (tool-call ids repeat across turns and chats: "call-0", "xml-0").
    @ObservationIgnored private var gates: [String: (cont: CheckedContinuation<Bool, Never>, sessionID: String)] = [:]
    /// Screen/computer approvals per chat, kept across engine rebuilds.
    @ObservationIgnored var computerGrants: [String: ComputerGrants] = [:]
    /// Server-reported context ceilings (from overflow errors), which a later
    /// probe of the advertised window must not raise again.
    @ObservationIgnored private var overflowCeiling: [String: Int] = [:]
    /// Outstanding "don't sleep" activities, by token.
    @ObservationIgnored private var awakeActivities: [UUID: NSObjectProtocol] = [:]
    @ObservationIgnored var runTasks: [String: Task<Void, Never>] = [:] {
        // A chat's turn ended (finished, failed or stopped): it gives the real mouse and keyboard back.
        didSet { for id in oldValue.keys where runTasks[id] == nil { machineTurnEnded(id) } }
    }
    @ObservationIgnored private let basePrompt: String
    /// Route ID → context window (tokens) learned from a server probe.
    /// Observed, so the context gauge redraws the moment a probe lands.
    private var probedContext: [String: Int] = [:]
    /// Route ID → what the server said it serves, and when we last asked.
    private var routeInfo: [String: RouteInfo] = [:]
    /// Route IDs whose probe is already in flight (avoids duplicate requests).
    @ObservationIgnored private var probingContext: Set<String> = []
    /// Chats told this turn that it ran on a backup.
    @ObservationIgnored private var failoverNoticed: Set<String> = []

    // MARK: - Turn phases (Planning → Execution → Validation → Results)

    /// The learned-ETA cache, persisted next to the queue. One per app: every
    /// chat's finished turns feed it, which is how estimates refine over time.
    @ObservationIgnored let phaseRunner: TurnPhaseRunner
    /// The validation loopback cap (nil = unlimited). Settings change it.
    @ObservationIgnored public var phaseLoopbackCap: Int?

    // MARK: - Prompts timeline and chat tasks (see AppTransport+Runs.swift)

    /// Each chat's Prompts timeline, one file per chat next to the conversations.
    @ObservationIgnored let promptStore: PromptTimelineStore
    /// Chats whose task list is paused, with the banner's reason. A paused list keeps its tasks; Resume carries on.
    public var chatTasksPaused: [String: String] = [:]
    /// What each chat's current (or last) turn ran on: the model id and the route's name.
    public var turnRoute: [String: RouteUse] = [:]
    /// The source of the next prompt record a chat opens (a chat task starting), consumed by `beginPrompt`.
    @ObservationIgnored var pendingPromptSource: [String: (source: PromptRecord.Source, taskID: String?)] = [:]
    /// The chat task each chat is running now (chat id → task id).
    @ObservationIgnored var chatTaskInFlight: [String: String] = [:]
    /// The prompt record each running chat task opened (task id → record id).
    @ObservationIgnored var chatTaskRecord: [String: String] = [:]

    public struct RouteUse: Hashable, Sendable {
        public var model: String
        public var route: String
    }

    // MARK: - The machine-in-use glow

    /// True while a computer-use tool of the selected session (any session,
    /// actually — the glow is about the machine, not a chat) is on the machine:
    /// observing it or controlling it. The glow controller watches this.
    public internal(set) var machineInUse = false {
        didSet { if oldValue != machineInUse { MachineGlowController.shared.setActive(machineInUse) } }
    }
    /// Tools that touch the machine; a running one of these lights the glow.
    static let machineTools = ["screenshot", "list_windows", "screen_watch", "ui_tree", "ui_action",
                               "inspect_process", "view_image", "mouse", "keyboard", "focus_app"]
    /// Each chat's seat at the machine (its place in line for the real mouse, its scope), kept across engine
    /// rebuilds like its computer grants. See AppTransport+Machine.swift.
    @ObservationIgnored var machineSeats: [String: MachineSeat] = [:]
    /// Machine work running right now, keyed by seat holder id (a chat id, or a chat id + "/subN" for a subagent):
    /// what the glow's pill names and what ⌃⌥⌘. stops.
    @ObservationIgnored var machineWork: [String: MachineWork] = [:]
    /// Machine tools running in each subagent seat (one subagent may run several at once), keyed by holder id.
    @ObservationIgnored var subagentMachineTools: [String: Int] = [:]
    /// The control arbiter as last seen (who has the real mouse, who waits).
    public internal(set) var controlSnapshot = ControlSnapshot.idle
    /// The status lines this file put on chats (so it only clears its own).
    @ObservationIgnored var machineStatusLines: [String: String] = [:]
    @ObservationIgnored var controlObserver: UUID?

    // MARK: - Task queue

    /// The unattended work list. One queue per app; persisted so a week-long
    /// run survives restarts.
    public var queue: TaskQueue = TaskQueue() {
        didSet { persistQueue() }
    }
    /// While `true`, the runner keeps working queued tasks one after another.
    public private(set) var queueRunning = false
    /// The task the runner is working right now (nil between tasks).
    public private(set) var queueActiveTaskID: String?
    /// Set while the runner works only these tasks (Resume on a blocked or
    /// failed task) rather than the whole queue; nil = the whole queue.
    public private(set) var queueOnlyTasks: [String]?
    /// The chat the queue last brought to the front; it only follows on to
    /// the next task while the user is still there.
    @ObservationIgnored private var queueFollowedSession: String?
    /// Per chat, the route a retry switched the engine to mid-run.
    @ObservationIgnored private var retryRoute: [String: ProviderProfile] = [:]
    /// The runner's loop, while one exists (running, or winding down after Stop).
    private var queueLoop: Task<Void, Never>?
    /// Bumped on every start, so a loop that is still winding down after a
    /// Stop can never clobber the state of the run that replaced it.
    @ObservationIgnored private var queueGeneration = 0
    /// Sessions working a queue task right now; values are the task id.
    @ObservationIgnored var queueSessions: [String: String] = [:]
    /// After this many tasks in a row fail on errors (not on the model's own
    /// verdict), the queue pauses instead of burning through the rest.
    static let queueMaxErroredTasks = 3

    struct RouteInfo: Hashable {
        var servedModel: String
        var servedModels: [String]
        var context: Int?
        var at: Date
    }

    struct EngineKey: Hashable {
        var profile: ProviderProfile
        var window: Int
        var thinking: ThinkingLevel?
        var preset: PermissionPreset
        /// Hash of the skills in the prompt and the tools they enable.
        var skills: Int
        var computerTools: Bool
        var vision: Bool
        /// The vault's names are in the prompt; a change rebuilds it.
        var vault: Int
        /// The subagent types (and the files they come from) are in the tool descriptions.
        var agents: String
        /// The backups the main model's client falls over to.
        var backups: [ProviderProfile]
        /// The subagent servers and their privacy are in the prompt and the agent tools' descriptions.
        var servers: [SubagentServers.Entry]
        /// Unattended work (a queue task, `/goal`): no backups or subagent servers that are interactive-only.
        var unattended: Bool
    }

    /// Everything about skills one turn needs: what exists, what's on, and the prompt text.
    struct SkillState {
        let all: [Skill]
        let active: [Skill]
        let result: SkillPromptResult
        let signature: Int
    }
    /// Route ID → the fully-built system prompt (base + project context +
    /// preset), cached so the context gauge's token estimate reads a string
    /// instead of re-loading project files on every keystroke.
    @ObservationIgnored private var systemPrompts: [String: String] = [:]
    /// Called when tools touch files, so the code-mode editor can reload.
    @ObservationIgnored public var onFilesChanged: (([FileChange]) -> Void)?
    /// True while the model server is switching models (Spark swapper).
    @ObservationIgnored var isServerSwitching: (() -> Bool)?
    /// Whether the box behind a route is switching models (nil: only the primary's box is known, `isServerSwitching`).
    @ObservationIgnored var isRouteSwitching: ((ProviderProfile) -> Bool)?
    /// Handles `/swap [model]`.
    @ObservationIgnored var onSwapCommand: ((String?, SessionVM) -> Void)?

    // MARK: - Chats without a project

    /// The folder a chat without a project works in: its own scratch folder under the app's data folder (made on
    /// first use), or the one it was lent.
    func scratchFolder(for vm: SessionVM, create: Bool = false) -> URL {
        let folder = vm.workFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ChatPrompt.scratchFolder(chatID: vm.id, appSupport: skillLocations.appSupport)
        if create { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder
    }

    /// The start of a chat's system prompt: with a project, the coding agent's prompt and the project's
    /// instructions; without one, a regular conversation's, with the user's own instruction files (and memory) from
    /// their home folder as before, and no project context.
    static func basePrompt(for vm: SessionVM, workspace: URL, coding: String, model: String,
                           projectContext: ProjectContext?, home: URL) -> String {
        if let project = vm.workspaceURL {
            // Project instructions + skills + plugin tools are what make this a
            // harness rather than a chat window.
            let context = projectContext?.root == project ? projectContext! : ProjectContext.load(root: project)
            let environment = ProjectContext.environmentBlock(workspace: project, model: model, preset: vm.preset)
            return coding + "\n\n" + context.promptSupplement(environment: environment, includeSkills: false)
        }
        var prompt = ChatPrompt.base(project: nil, scratch: workspace, codingPrompt: coding)
        prompt += "\n\n" + ChatPrompt.environment(scratch: workspace, model: model, preset: vm.preset)
        if let own = ChatPrompt.userInstructions(ProjectContext.instructionFiles(root: home)) {
            prompt += "\n\n" + own
        }
        return prompt
    }

    /// Post a notice into the chat the user is looking at.
    func broadcast(_ text: String, error: Bool = false) {
        guard let vm = selected else { banner = text; return }
        vm.note(text, role: error ? .error : .notice)
        log.recordItem(vm.id, kind: error ? "error" : "notice", text: text, toolName: nil,
                       argSummary: nil, output: nil, isError: error)
    }

    public init(config: AppConfig, log: ConversationLog = .shared, systemPrompt: String? = nil,
                queueFile: URL? = nil, skillLocations: SkillLocations = .standard,
                vault: CredentialVault? = nil) {
        self.config = config
        self.log = log
        self.basePrompt = systemPrompt ?? Self.defaultSystemPrompt
        self.skillLocations = skillLocations
        self.vault = vault ?? CredentialVault(directory: skillLocations.appSupport)
        self.queueFile = queueFile ?? Self.defaultQueueFile
        self.phaseRunner = TurnPhaseRunner(
            fileURL: skillLocations.appSupport.appendingPathComponent("eta-cache.json"))
        self.phaseLoopbackCap = nil   // unlimited by default; Settings can cap it at 3
        self.promptStore = PromptTimelineStore(
            directory: skillLocations.appSupport.appendingPathComponent("prompt-timeline", isDirectory: true))
        // Ship-with-the-app skills (godot-debugging, …) refresh on every launch.
        try? SkillBuiltin.install(into: skillLocations.builtinSkills)
        reload()
        refreshDrafts()
        loadQueue()
        // Chat tasks never start by themselves when the app opens: each chat with some waiting says so and waits for
        // Resume.
        for chatID in queue.chatsWithQueuedTasks { chatTasksPaused[chatID] = ChatTaskRules.pausedAtLaunch }
        config.onRoutesChanged = { [weak self] in self?.refreshFleet() }
        refreshFleet()
        observeControlArbiter()
    }

    public var selected: SessionVM? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    public var runningSessions: [SessionVM] { sessions.filter(\.running) }

    public static let defaultSystemPrompt = """
    You are a capable coding agent running inside a native macOS app, working in the user's project folder.

    Use the tools to read, write, and search files and to run shell commands. Prefer small, verifiable steps:
    read before you edit, and check your work after you change something. When a task needs more than a
    couple of steps, track it with `todo_write` so the user can see the plan.

    Parallel and background work: for a well-scoped side task, launch a subagent with `agent` — pick an \
    `agent_type` (explore: read-only research; plan; review; worker: makes changes). To fan several \
    independent tasks out at once use `delegate`; with several model servers configured they run on \
    different machines. With run_in_background: true a subagent works while you continue (several can run \
    at once); you're told when each finishes, and agent_status / agent_stop manage them. Long-running \
    programs go in `process_start`. Follow-up work that can happen later, unattended, goes on the task \
    queue with `queue_task`.

    Rules that matter:
    - Never claim a command succeeded unless you ran it and saw the output.
    - Prefer `edit` over `write_file` for changes to an existing file; rewriting a whole file loses work.
    - Paths are resolved against the project folder. Stay inside it unless the user asks otherwise.
    - When you finish, summarize what changed in a few lines. Reference files as `path:line`.
    """

    // MARK: - Project

    /// Adopt a project folder: reload its plugins, instructions, and skills.
    public func adoptProject(_ url: URL?) {
        guard let url else {
            projectContext = nil
            plugins = []
            pluginErrors = []
            return
        }
        projectContext = ProjectContext.load(root: url)
        let loaded = PluginLoader.load(project: url)
        plugins = loaded.plugins
        pluginErrors = loaded.errors
        // Sessions pick the new context up on their next turn.
        engines.removeAll()
        systemPrompts.removeAll()
    }

    /// Re-read instructions, skills, and plugins from disk.
    public func refreshProjectContext() {
        adoptProject(projectContext?.root)
    }

    // MARK: - Sessions

    @discardableResult
    public func newSession(cwd: String?, preset: PermissionPreset? = nil, select: Bool = true,
                           workFolder: String? = nil) -> SessionVM {
        let id = UUID().uuidString
        let resolved = preset ?? config.asPreset
        let vm = SessionVM(id: id, title: "New chat", cwd: cwd, preset: resolved)
        if cwd == nil { vm.workFolder = workFolder }
        sessions.insert(vm, at: 0)
        log.upsert(id: id, cwd: cwd, title: "New chat", preset: resolved.rawValue, scratch: vm.workFolder)
        // Its own model: what its project's chats last chose, else the primary.
        assignInitialChoice(vm)
        if select { selectedID = id }
        return vm
    }

    public func deleteSession(_ id: String) {
        // A chat without a project takes its own scratch folder with it — unless tasks it queued still work there:
        // then the folder goes when the last of them is done (`releaseBorrowedFolder`).
        if let vm = sessions.first(where: { $0.id == id }), vm.isPlain {
            let own = ChatPrompt.scratchFolder(chatID: id, appSupport: skillLocations.appSupport)
            if !queue.tasks.contains(where: { $0.workFolder == own.path && Self.mayStillRun($0.status) }) {
                try? FileManager.default.removeItem(at: own)
            }
        }
        resolveAllGates(for: id, with: false)
        runTasks[id]?.cancel()
        runTasks[id] = nil
        engines[id] = nil
        engineKeys[id] = nil
        computerGrants[id] = nil
        machineSeats[id] = nil
        vaultGrants[id] = nil
        backgroundPools.removeValue(forKey: id)?.stopAll()
        agentQueuedCount[id] = nil
        config.sessionSkills[id] = nil
        transcripts[id] = nil
        systemPrompts[id] = nil
        attachmentStore(for: id).removeAll()
        log.delete(id)
        sessions.removeAll { $0.id == id }
        // Its own tasks and its Prompts timeline go with it.
        queue.removeChatTasks(id)
        chatTasksPaused[id] = nil
        chatTaskInFlight[id] = nil
        turnRoute[id] = nil
        promptStore.delete(id)
        // Tasks that used this chat start a fresh one next time.
        queue.detachSession(id)
        if selectedID == id {
            selectedID = sessions.first?.id
            // The next chat may be an archived one whose timeline was released.
            if let next = selected { hydrate(next) }
        }
    }

    // MARK: - Task queue

    /// The queue's home for persistence: one JSON file under the app-support
    /// folder, next to the conversations.
    private static var defaultQueueFile: URL { AppPaths.taskQueueFile }

    public var queueRunningNow: Bool { queueRunning }

    /// Stop was pressed and the in-flight task is still winding down (a tool
    /// finishing, a request being cancelled); it goes back in line when done.
    public var queueStopping: Bool { !queueRunning && queueLoop != nil }

    private func loadQueue() {
        guard let data = try? Data(contentsOf: queueFile) else { return }   // none yet
        let q: TaskQueue
        do {
            q = try JSONDecoder().decode(TaskQueue.self, from: data)
        } catch {
            // Never overwrite a queue we can't read: set the file aside so the
            // tasks can be recovered, and start empty.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = queueFile.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: queueFile, to: aside)
            banner = "The task queue file couldn't be read, so the queue starts empty. The old file was kept as \(aside.lastPathComponent)."
            return
        }
        self.queue = q
        // A restart mid-task can't leave a task "running" in the file: the
        // work in flight is lost, so it goes back in line (in place — it was
        // first in line when it started) and resumes in the same chat.
        for t in q.tasks where t.status == .running {
            queue.markStopped(t.id, note: "Was running when the app quit — back in the queue; it resumes in the same chat.")
        }
    }

    private func persistQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            try FileManager.default.createDirectory(at: queueFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: queueFile, options: .atomic)
        } catch {
            // Non-fatal; the in-memory queue keeps working for this session.
        }
    }

    // MARK: Queue CRUD

    @discardableResult
    public func queueAdd(_ title: String, details: String = "", atFront: Bool = false) -> QueueTask {
        // The task runs in the project it was queued in, even if the app has
        // moved on to another project by the time its turn comes — or, with
        // no project open, in the scratch folder of the chat without one.
        let cwd = projectContext?.root.path ?? selected?.cwd
        let folder = cwd == nil ? selected.map { scratchFolder(for: $0).path } : nil
        let t = queue.add(title, details: details, atFront: atFront, cwd: cwd, workFolder: folder)
        return queue[t.id] ?? t
    }

    public func queueUpdate(id: String, title: String?, details: String?) {
        queue.update(id: id, title: title, details: details)
    }

    public func queueRemove(id: String) {
        // If a session is currently working this task, stop it first. The
        // store marks a running task skipped (keeping its record), so the
        // runner moves on to the next task rather than pausing.
        let sessionID = queueSessions.first(where: { $0.value == id })?.key
        let borrowed = queue.task(id)?.workFolder
        queue.remove(id: id)
        if let sessionID { stopSession(sessionID) }
        releaseBorrowedFolder(borrowed)
    }

    /// A task may still work in its folder: it is waiting, running, or could be resumed.
    static func mayStillRun(_ status: QueueTaskStatus) -> Bool {
        [.queued, .running, .blocked, .failed].contains(status)
    }

    /// The scratch folder a chat without a project lent its queued tasks outlives the chat while one of them may
    /// still work there; once none may, and the chat is gone, the folder goes too. (Only ever a folder under the
    /// app's own Chats folder.)
    func releaseBorrowedFolder(_ path: String?) {
        guard let path else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let chats = skillLocations.appSupport.appendingPathComponent("Chats", isDirectory: true).standardizedFileURL
        guard folder.deletingLastPathComponent().path == chats.path,
              !sessions.contains(where: { $0.id == folder.lastPathComponent }),
              !queue.tasks.contains(where: { $0.workFolder == path && Self.mayStillRun($0.status) }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Put a blocked, failed or skipped task back in line — at the front, so
    /// it is worked next — keeping its chat so it resumes with its context.
    public func queueRequeue(id: String) {
        guard let t = queue.task(id), t.status != .running, t.status != .queued else { return }
        queue.requeue(id, toFront: true)
    }

    public func queueMove(id: String, by offset: Int) { queue.move(id: id, by: offset) }
    public func queueMove(id: String, before target: String?) { queue.move(id: id, before: target) }
    public func queueMove(id: String, onto target: String) { queue.move(id: id, onto: target) }

    /// Archive a finished task's session so a long queue doesn't pile up in
    /// RAM: persist the (possibly auto-compacted) timeline to disk, then drop
    /// the in-memory model transcript and engine — both of which `turn()` and
    /// `engine(for:)` rebuild on demand. The session stays in the sidebar with
    /// its timeline, so the chat is still openable; if we clear the display
    /// (for non-selected sessions) it re-hydrates from disk on open.
    public func queueEvict(_ sessionID: String, taskID: String?) {
        guard let taskID,
              let task = queue.task(taskID),
              task.status == .complete || task.status == .failed,
              let vm = sessions.first(where: { $0.id == sessionID }),
              !vm.running else { return }
        // Save the current display timeline (compaction dividers included) so
        // a later re-open / resume starts from the compacted summary. Only a
        // fully loaded timeline may replace what's on disk.
        if vm.loaded {
            log.resync(sessionID, rows: Self.logRows(for: vm.entries, sessionID: sessionID))
        }
        transcripts[sessionID] = nil
        engines[sessionID] = nil
        engineKeys[sessionID] = nil
        systemPrompts[sessionID] = nil
        // Release the display entries too unless the user is looking at it —
        // the next task will select a fresh session, so this rarely fires for
        // the visible one, and it keeps 100 finished chats from holding 100
        // full timelines in memory at once.
        if selectedID != sessionID {
            vm.entries = []
            vm.loaded = false
            vm.contextUsed = nil
            log.release(sessionID)
        }
    }

    // MARK: Runner

    /// Start the queue: work tasks one at a time, top to bottom, until none
    /// remain or the user stops it. With `only`, work just that task (Resume
    /// on a blocked/failed task) and stop afterwards. Idempotent: while a run
    /// is going, Resume adds its task to that run and a plain Start widens a
    /// Resume-only run to the whole queue.
    public func startQueue(only taskID: String? = nil) {
        guard config.isConfigured else {
            broadcast("No model is configured — run the setup wizard, then start the queue.", error: true)
            return
        }
        // A plan whose terms allow only interactive use never works unattended.
        if let route = config.interactiveOnlyMain {
            broadcast(Self.interactiveOnlyQueueMessage(route), error: true)
            return
        }
        // A chat's own task runs in that chat, as its next prompt — never unattended.
        if let taskID, queue.task(taskID)?.isChatTask == true { return }
        if queueRunning {
            if let taskID, let t = queue.task(taskID), t.status != .running {
                queue.requeue(taskID, toFront: true)
                if queueOnlyTasks != nil, !(queueOnlyTasks?.contains(taskID) ?? false) {
                    queueOnlyTasks?.append(taskID)
                }
                broadcast("“\(t.title)” is next in line — the queue is already running.")
            } else if taskID == nil, queueOnlyTasks != nil {
                queueOnlyTasks = nil
                config.queuePaused = false
                config.queueResumeOnLaunch = true
                broadcast("The whole queue will run after the current task.")
            }
            return
        }
        if let taskID {
            guard let t = queue.task(taskID), t.status != .running else { return }
            if t.status != .queued { queue.requeue(taskID, toFront: true) }
        } else {
            // A task still winding down from a Stop goes back in line, so a
            // queue that is stopping is not empty.
            guard queue.nextTask != nil || queueStopping else {
                broadcast("The queue is empty — add a task first.")
                return
            }
            config.queuePaused = false
            config.queueResumeOnLaunch = true
        }
        queueRunning = true
        queueOnlyTasks = taskID.map { [$0] }
        queueGeneration += 1
        let generation = queueGeneration
        let previous = queueLoop
        queueLoop = Task { [weak self] in
            // A loop still winding down from a Stop finishes its cleanup first,
            // so two loops never work the queue at once.
            await previous?.value
            await self?.queueRunLoop(generation: generation)
        }
    }

    /// Stop the queue: cancel the in-flight task and return it to the queue.
    /// A deliberate stop is remembered, so a relaunch doesn't auto-resume.
    public func stopQueue() {
        guard queueRunning else { return }
        queueRunning = false
        config.queuePaused = true
        config.queueResumeOnLaunch = false
        if let taskID = queueActiveTaskID,
           let sessionID = queueSessions.first(where: { $0.value == taskID })?.key {
            stopSession(sessionID)
        }
    }

    /// True while the run started as `generation` is still the one in charge.
    private func queueActive(_ generation: Int) -> Bool {
        queueRunning && generation == queueGeneration
    }

    /// The next task this run should work: the head of the queue, or — in a
    /// Resume-only run — the first of its tasks still waiting.
    private func nextQueueTask() -> QueueTask? {
        if let only = queueOnlyTasks {
            return only.lazy.compactMap { self.queue.task($0) }.first { $0.status == .queued }
        }
        return queue.nextTask
    }

    private func queueRunLoop(generation: Int) async {
        // An unattended run must not stall because the Mac went to sleep.
        let awake = keepAwake("Working the task queue")
        defer {
            endKeepAwake(awake)
            if generation == queueGeneration {
                queueRunning = false
                queueActiveTaskID = nil
                queueOnlyTasks = nil
                queueLoop = nil
                // Ran dry, paused or stopped: nothing to pick up on relaunch.
                config.queueResumeOnLaunch = false
            }
        }
        var erroredInARow = 0
        var first = true
        while queueActive(generation), !Task.isCancelled {
            guard let task = nextQueueTask() else { break }
            // The primary was changed to an interactive-only plan while the queue ran: pause before the next task.
            if let route = config.interactiveOnlyMain {
                config.queuePaused = true
                broadcast(Self.interactiveOnlyQueueMessage(route), error: true)
                return
            }
            let outcome = await work(taskID: task.id, generation: generation, first: first)
            first = false
            switch outcome {
            case .stopped:
                if queueActive(generation) {
                    // Stopped from its chat (or the chat was deleted) rather
                    // than with the queue's Stop: pause the queue the same way.
                    config.queuePaused = true
                    broadcast("Queue paused — “\(task.title)” was stopped and is back in line. Press Start to continue.")
                }
                return
            case .errored:
                erroredInARow += 1
                if erroredInARow >= Self.queueMaxErroredTasks, queueOnlyTasks == nil, queueActive(generation) {
                    config.queuePaused = true
                    broadcast("Queue paused — \(erroredInARow) tasks in a row failed on errors. "
                              + "Check the failed tasks' chats, then press Start to continue.", error: true)
                    return
                }
            case .finished:
                erroredInARow = 0
            }
        }
        if queueOnlyTasks == nil, queueActive(generation), queue.unattended.stats().finished {
            let s = queue.unattended.stats()
            broadcast("Queue finished: \(s.completed) complete, \(s.failed) failed, \(s.blocked) blocked.")
        }
    }

    private enum WorkOutcome { case finished, errored, stopped }

    /// Something else is using this chat (a turn the user started, a
    /// command): the queue waits rather than run two things in one chat.
    private func isBusy(_ vm: SessionVM) -> Bool {
        vm.running || runTasks[vm.id] != nil
    }

    /// Take the next task and run its unattended goal loop to a conclusion.
    private func work(taskID: String, generation: Int, first: Bool) async -> WorkOutcome {
        // Pick a session: the one this task already used (resume where it
        // stopped, with its context), or a fresh chat in the task's project.
        // The preset follows the app's current setting — an unattended week
        // of work needs the autonomy the user already chose.
        var vm: SessionVM
        while true {
            guard let task = queue.task(taskID), task.status == .queued else { return .finished }
            if let existing = task.sessionID.flatMap({ id in sessions.first(where: { $0.id == id }) }) {
                vm = existing
            } else if task.cwd == nil, let folder = task.workFolder {
                // Queued from a chat without a project: a chat without one, working in that chat's folder.
                vm = newSession(cwd: nil, select: false, workFolder: folder)
                if task.routeID != nil { assignInitialChoice(vm, routeID: task.routeID, thinking: task.thinking) }
                renameSession(vm.id, to: "🚀 \(task.title)")
                queue.attachSession(taskID, vm.id)
            } else {
                let cwd = task.cwd ?? projectContext?.root.path ?? sessions.first?.cwd
                vm = newSession(cwd: cwd, select: false)
                if task.routeID != nil { assignInitialChoice(vm, routeID: task.routeID, thinking: task.thinking) }
                renameSession(vm.id, to: "🚀 \(task.title)")
                queue.attachSession(taskID, vm.id)
            }
            // The user may be mid-turn in that chat (answering a blocked
            // task): let their turn finish first.
            while isBusy(vm), sessions.contains(where: { $0 === vm }) {
                guard queueActive(generation) else { return .stopped }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard queueActive(generation) else { return .stopped }
            // Deleted while we waited: pick again (a fresh chat this time).
            if sessions.contains(where: { $0 === vm }) { break }
        }
        guard queue.task(taskID)?.status == .queued else { return .finished }

        let sessionID = vm.id
        // Follow the queue: for its first task unless the user is busy in
        // another chat, then only while the user is still on the chat the
        // queue itself last showed — never pull them out of their own work.
        let follow: Bool
        if first {
            follow = !(selected?.running ?? false) || selectedID == sessionID
        } else {
            follow = selectedID == nil
                || (selectedID == queueFollowedSession && !(selected?.running ?? false))
        }

        queue.start(taskID, sessionID: sessionID)
        queueSessions[sessionID] = taskID
        queueActiveTaskID = taskID
        // An archived task's compacted timeline lives on disk: replay it.
        hydrate(vm)
        let resuming = vm.entries.contains { $0.message?.role == .user }

        vm.running = true
        vm.stopping = false
        let runner = Task { [weak self] in
            guard let self else { return }
            await self.runTaskGoal(vm: vm, taskID: taskID, resuming: resuming)
        }
        runTasks[sessionID] = runner
        if follow {
            let previous = selectedID
            selectedID = sessionID
            queueFollowedSession = sessionID
            if let previous, previous != sessionID { releaseArchivedDisplay(previous) }
        }
        _ = await runner.value

        let status = queue.task(taskID)?.status
        finishTaskSession(vm, taskID: taskID)
        // A folder borrowed from a chat that has since been deleted goes once its last task is done.
        if status == .complete { releaseBorrowedFolder(queue.task(taskID)?.workFolder) }
        // Archive finished tasks: the transcript stays on disk (auto-compaction
        // kept it small), the in-memory transcript + engine go — so 100 tasks
        // over a week don't pile up in RAM. Blocked tasks keep their session
        // intact so the model resumes with full context.
        if status == .complete || status == .failed {
            queueEvict(sessionID, taskID: taskID)
        }
        switch status {
        case .running?: return .stopped     // cancelled mid-way; finishTaskSession requeued it
        case .failed?: return .errored
        default: return .finished
        }
    }

    /// Drop the in-memory timeline of a finished (archived) queue chat the
    /// user has moved away from; it re-hydrates from disk when opened.
    private func releaseArchivedDisplay(_ sessionID: String) {
        guard selectedID != sessionID,
              let vm = sessions.first(where: { $0.id == sessionID }), !vm.running,
              let task = queue.tasks.first(where: { $0.sessionID == sessionID }),
              task.status == .complete || task.status == .failed,
              transcripts[sessionID] == nil else { return }
        vm.entries = []
        vm.loaded = false
        vm.contextUsed = nil
        log.release(sessionID)
    }

    // MARK: Keeping the Mac awake

    /// Hold off idle sleep while unattended work runs. Returns a token for `endKeepAwake`.
    func keepAwake(_ reason: String) -> UUID {
        let token = UUID()
        awakeActivities[token] = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
        return token
    }

    func endKeepAwake(_ token: UUID) {
        if let activity = awakeActivities.removeValue(forKey: token) {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    /// Post-goal cleanup: reset the session's live state and, if the task was
    /// cancelled mid-way, put it back in the queue exactly once.
    private func finishTaskSession(_ vm: SessionVM, taskID: String) {
        vm.running = false
        vm.stopping = false
        vm.goal = nil
        vm.activity = nil
        vm.retry = nil
        vm.clearReasoning()
        vm.endStreaming()
        runTasks[vm.id] = nil
        queueSessions[vm.id] = nil
        // The task is over: nothing it started in the background keeps going.
        backgroundPools[vm.id]?.stopAll()
        if queueActiveTaskID == taskID { queueActiveTaskID = nil }
        log.touch(vm.id)
        vm.updatedAt = .now
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if queue.task(taskID)?.status == .running {
            queue.markStopped(taskID)
        }
        // The chat was deleted mid-run: the task starts a fresh one next time.
        if !sessions.contains(where: { $0 === vm }) { queue.detachSession(vm.id) }
        // Its prompt record ends with the task; then the chat's own tasks may follow.
        let outcome: PromptRecord.Outcome
        switch queue.task(taskID)?.status {
        case .complete?: outcome = .completed
        case .blocked?: outcome = .needsYou
        case .failed?: outcome = .failed
        default: outcome = .stopped
        }
        finishPrompt(vm, outcome: outcome, reason: queue.task(taskID)?.log.last?.text)
        afterWork(vm, outcome: outcome)
    }

    /// Runs the unattended goal loop for a queue task and records the outcome.
    private func runTaskGoal(vm: SessionVM, taskID: String, resuming: Bool) async {
        guard let task = queue.task(taskID) else { return }
        // Queue tasks run the same phases as an interactive turn: the task
        // text is the prompt (unless this is a resume, which keeps its turn).
        if !resuming {
            phasesBegin(vm, prompt: task.goalText)
        }
        beginPrompt(vm, text: task.goalText, source: .queue)
        do {
            let outcome = try await goalLoop(vm, goal: task.goalText, auto: true, resuming: resuming)
            // Deleted (skipped) while the last round finished: keep that verdict.
            guard queue.task(taskID)?.status == .running else { return }
            switch outcome {
            case .complete:
                phasesAbandon(vm, reason: "The task completed.", completed: true)
                queue.finish(taskID, status: .complete, sessionID: vm.id)
            case .blocked(let why):
                phasesAbandon(vm, reason: "Paused — the agent needs you: \(why)", completed: false)
                queue.finish(taskID, status: .blocked, reason: why, sessionID: vm.id)
            case .stopped:
                return  // cancelled; finishTaskSession puts it back in the queue
            }
            settle(taskID: taskID, sessionID: vm.id)
        } catch {
            // Stopped by the user (or the chat was deleted): nothing to record.
            if error is CancellationError || Task.isCancelled { return }
            guard queue.task(taskID)?.status == .running else { return }
            let why = Self.describe(error)
            phasesAbandon(vm, reason: why, completed: false)
            queue.finish(taskID, status: .failed, reason: why, sessionID: vm.id)
            vm.note(why, role: .error)
            log.recordItem(vm.id, kind: "error", text: why, toolName: nil, argSummary: nil, output: nil, isError: true)
            settle(taskID: taskID, sessionID: vm.id)
        }
    }

    private func settle(taskID: String, sessionID: String) {
        guard let task = queue.task(taskID) else { return }
        switch task.status {
        case .complete, .blocked, .failed, .skipped:
            break
        default:
            return
        }
        if let vm = sessions.first(where: { $0.id == sessionID }) {
            let text: String?
            switch task.status {
            case .complete:
                let d = task.duration?.formattedDuration ?? "?"
                let rate = task.avgTokensPerSecond.map { "\(Int($0.rounded())) tokens/s avg" } ?? ""
                text = "✅ Task complete — \(task.rounds) round\(task.rounds == 1 ? "" : "s"), \(d)\(rate.isEmpty ? "" : " · \(rate)")."
            case .blocked:
                text = "⏸ Task blocked — the queue moved on. Answer here, then press Resume on the task (Task Queue panel) to pick it back up."
            case .failed:
                text = "Task failed. Fix what's needed in this chat, then press Resume on the task (Task Queue panel) to retry it."
            default:
                text = nil
            }
            if let text {
                vm.note(text, role: task.status == .failed ? .error : .notice)
                log.recordItem(vm.id, kind: task.status == .failed ? "error" : "notice", text: text,
                               toolName: nil, argSummary: nil, output: nil, isError: task.status == .failed)
            }
        }
    }

    public func renameSession(_ id: String, to title: String) {
        guard let vm = sessions.first(where: { $0.id == id }) else { return }
        vm.title = title
        log.touch(id, title: title)
    }

    public func reload() {
        let stored = log.list().compactMap { row -> SessionVM? in
            guard !sessions.contains(where: { $0.id == row.id }) else { return nil }
            let cwd = (row.cwd?.isEmpty ?? true) ? nil : row.cwd
            let vm = SessionVM(id: row.id, title: row.title, cwd: cwd,
                               preset: PermissionPreset(rawValue: row.preset ?? "") ?? .workspaceWrite)
            if cwd == nil { vm.workFolder = row.scratch }
            vm.routeID = row.route
            vm.thinking = row.thinking.flatMap(ThinkingLevel.init(rawValue:))
            vm.updatedAt = row.updatedAt
            vm.loaded = false
            return vm
        }
        sessions = stored + sessions
        sessions.sort { $0.updatedAt > $1.updatedAt }
        if selectedID == nil { selectedID = sessions.first?.id }
        if let selected { hydrate(selected) }
    }

    /// Replay a stored transcript into a session's timeline. Called lazily, so
    /// a long session list stays cheap to open.
    public func hydrate(_ vm: SessionVM) {
        if !vm.loaded {
            // Anything added while the timeline was unloaded (a notice) goes after it.
            let added = vm.entries
            vm.entries = []
            replayLog(into: vm)
            vm.entries.append(contentsOf: added)
            vm.loaded = true
        }
        // A hydrated (or evicted) session has no live transcript; rebuild it
        // so a follow-up turn keeps the conversation rather than starting over.
        if transcripts[vm.id] == nil, !vm.entries.isEmpty {
            transcripts[vm.id] = Self.replayMessages(vm.entries)
        }
        loadPromptHistory(vm)
    }

    private func replayLog(into vm: SessionVM) {
        for row in log.loadItems(vm.id) {
            switch row.kind {
            case "user": vm.appendMessage(.user, row.text ?? "", at: row.at, attachments: row.attachments ?? [])
            case "assistant": vm.appendMessage(.assistant, row.text ?? "", at: row.at)
            case "notice": vm.appendMessage(.notice, row.text ?? "", at: row.at)
            case "error": vm.appendMessage(.error, row.text ?? "", at: row.at)
            case "tool":
                vm.addFinishedTool(id: "log-\(row.seq)", name: row.toolName ?? "tool",
                                   preview: row.argSummary ?? "", summary: row.text,
                                   output: row.output, ok: !row.isError, at: row.at)
            case "compaction":
                let removed = Int(row.argSummary ?? "") ?? 0
                vm.entries.append(ChatEntry(at: row.at, kind: .compaction(
                    .init(removed: removed, summary: row.text ?? "", at: row.at))))
            default: break
            }
        }
    }

    /// Reconstruct a model-facing transcript from a rendered one. Tool calls
    /// are folded into the assistant text: replaying their exact call ids is
    /// not worth persisting, and the model only needs to know what happened.
    static func replayMessages(_ entries: [ChatEntry]) -> [LLMMessage] {
        var out: [LLMMessage] = []
        var pendingTools: [String] = []

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            out.append(.assistant("[earlier tool activity]\n" + pendingTools.joined(separator: "\n")))
            pendingTools = []
        }

        for entry in entries {
            switch entry.kind {
            case .message(let body):
                switch body.role {
                case .user:
                    flushTools()
                    // What it carried: the files' content isn't in the display rows, but where it is saved is.
                    let text = ([body.text] + body.attachments.map(\.replayNote))
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                    // Back-to-back user messages (a message that never got an
                    // answer) upset strict chat templates: fold them together.
                    if let last = out.last, last.role == .user, last.attachments == nil {
                        out[out.count - 1].content = (last.content ?? "") + "\n\n" + text
                    } else {
                        out.append(.user(text))
                    }
                case .assistant:
                    flushTools()
                    out.append(.assistant(body.text))
                case .notice, .error:
                    continue
                }
            case .tool(let activity):
                let head = "\(activity.name)(\(activity.preview))"
                pendingTools.append("- \(head) → \(activity.summary ?? (activity.isOk == false ? "failed" : "ok"))")
            case .todos:
                continue
            case .compaction(let note):
                // A compacted transcript starts from its summary: everything
                // above the divider is already folded into it.
                pendingTools = []
                out = [.system(Compaction.summaryHeader + note.summary)]
            }
        }
        flushTools()
        return out
    }

    // MARK: - Engine

    private func engine(for sessionID: String, vm: SessionVM, client: any LLMClient,
                        window: Int, thinking: ThinkingLevel?, skillState: SkillState, unattended: Bool,
                        home: FleetServer? = nil) -> Engine {
        // A chat without a project works in its own scratch folder, which the permission preset then confines it to
        // exactly as a project folder would.
        let workspace = vm.workspaceURL ?? scratchFolder(for: vm, create: true)
        let policy = PermissionPolicy(preset: vm.preset, workspaceRoot: workspace)
        let model = (client as? any ProviderClient)?.profile.model ?? "model"

        var prompt = Self.basePrompt(for: vm, workspace: workspace, coding: basePrompt, model: model,
                                     projectContext: projectContext, home: skillLocations.home)
        // Skills: always-on rules, the ones the user selected for this chat,
        // and a catalog the model can load from with `use_skill`.
        if !skillState.result.text.isEmpty { prompt += "\n\n" + skillState.result.text }
        prompt += "\n\n" + Self.vaultPrompt(vault.all)
        // Which subagent servers may see sensitive data.
        let servers = subagentServerEntries
        if let note = SubagentServers.note(servers) { prompt += "\n\n--- Subagent servers ---\n" + note }
        if vm.preset == .plan {
            prompt += """


            --- Plan mode ---
            Do not modify anything. Research and produce a plan, then call `exit_plan_mode` with it and stop.
            """
        }
        systemPrompts[sessionID] = prompt

        let builtins = ToolRegistry.standard(agents: agentCatalog(for: vm), servers: servers.isEmpty ? nil : servers)
        var extra: [any ToolExecutor] = PluginLoader.tools(from: plugins, reserved: Set(builtins.names))
        if !skillState.active.isEmpty { extra.append(UseSkillTool(skills: skillState.active)) }
        extra.append(VaultSearchTool(vault: vault))
        // Long attachments are read in parts; any attachment again after a restart.
        extra.append(ReadAttachmentTool(store: attachmentStore(for: sessionID)))
        extra.append(contentsOf: ToolRegistry.backgroundAgentTools())
        if vm.preset != .plan {
            extra.append(QueueAddTool(add: { [weak self] title, details, front, start in
                await self?.agentQueueTask(title: title, details: details, front: front, start: start,
                                           from: sessionID) ?? "Error: the app is closing."
            }))
        }
        if vm.preset != .plan {
            extra.append(ProposeSkillTool(projectRoot: vm.workspaceURL, locations: skillLocations))
        }
        // Background processes: the model's own long-running programs (game
        // engines, dev servers, REPLs) that keep running between tool calls.
        extra.append(contentsOf: ToolRegistry.processes())
        // Seeing/steering the machine — screenshots, windows, a11y trees,
        // clicks, keystrokes. Off with the computerToolsEnabled kill switch;
        // each first use in a chat still asks (Engine.computerGate).
        if config.computerToolsEnabled {
            extra.append(contentsOf: ToolRegistry.machineTools())
        }
        let registry = builtins.adding(extra)

        var engineConfig = EngineConfig(model: model,
                                        temperature: (client as? any ProviderClient)?.profile.temperature,
                                        maxOutputTokens: (client as? any ProviderClient)?.profile.maxOutputTokens,
                                        contextWindow: window,
                                        thinking: thinking,
                                        visionEnabled: visionOn(for: (client as? any ProviderClient)?.profile),
                                        retry: retryPolicy)
        // Subagents of a queue task or a /goal keep off servers that are for interactive use only.
        engineConfig.unattended = unattended
        let engine = Engine(
            client: client,
            registry: registry,
            systemPrompt: prompt,
            config: engineConfig,
            workspace: workspace,
            policy: policy,
            permissionGate: { [weak self] id, name, detail in
                guard let self else { return false }
                return await self.askGate(sessionID: sessionID, gateID: id, name: name, detail: detail)
            },
            onTodos: { [weak self] todos in
                Task { @MainActor [weak self] in
                    guard let self, let vm = self.sessions.first(where: { $0.id == sessionID }) else { return }
                    vm.setTodos(todos)
                    if !todos.isEmpty { self.planAppeared(in: vm) }
                }
            },
            compaction: { [weak self] used, messages in
                await self?.compactTranscript(sessionID: sessionID, used: used, messages: messages)
                    ?? messages
            },
            computerGrants: grants(for: sessionID),
            reroute: { [weak self] in
                await self?.rerouteForRetry(sessionID: sessionID)
            },
            vault: vault,
            vaultGrants: vaultGrants(for: sessionID),
            backgroundAgents: backgroundPool(for: sessionID),
            fleet: fleet,
            roster: roster(for: sessionID),
            agentTypes: agentCatalog(for: vm),
            fleetHome: home,
            machineSeat: machineSeat(for: sessionID, vm: vm)
        )
        engines[sessionID] = engine
        return engine
    }

    // MARK: - Background agents & tasks

    private func backgroundPool(for sessionID: String) -> BackgroundAgents {
        if let existing = backgroundPools[sessionID] { return existing }
        let pool = BackgroundAgents()
        pool.onChange = { [weak self] job in
            Task { @MainActor [weak self] in self?.backgroundJobChanged(job, sessionID: sessionID) }
        }
        backgroundPools[sessionID] = pool
        return pool
    }

    private func backgroundJobChanged(_ job: BackgroundAgents.Job, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        if let i = vm.backgroundJobs.firstIndex(where: { $0.id == job.id }) {
            vm.backgroundJobs[i] = job
        } else {
            vm.backgroundJobs.append(job)
        }
        guard job.status != .running else { return }
        let verb = job.status == .done ? "finished" : job.status.rawValue
        defer {
            // A Stop never wakes the chat back up.
            if job.status != .stopped { continueAfterBackgroundAgents(vm) }
            // Its last agent done and nothing carried on: the chat's next task may start.
            schedulePump(vm)
        }
        let text = "🤖 Background agent \(job.id) “\(job.description)” \(verb) after \(job.elapsed.formattedDuration)."
        vm.note(text)
        log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
    }

    /// An idle chat whose background agents have all finished picks the work
    /// back up by itself: the main agent gets their reports and carries on.
    private func continueAfterBackgroundAgents(_ vm: SessionVM) {
        guard !vm.running, runTasks[vm.id] == nil, queueSessions[vm.id] == nil,
              vm.runningBackgroundJobs.isEmpty,
              let pool = backgroundPools[vm.id], pool.all.contains(where: { $0.status == .done || $0.status == .failed }),
              !chatServerSwitching(vm) else { return }
        // Carrying on by itself is unattended work, which an interactive-only plan doesn't allow.
        if chatRoute(vm)?.isInteractiveOnly == true {
            vm.note("Background agents finished — reply to continue.")
            return
        }
        // At most a few automatic continuations in a row: a model that keeps
        // relaunching agents must not loop unattended forever.
        guard autoContinuations[vm.id, default: 0] < Self.maxAutoContinuations else {
            vm.note("Background agents finished — reply to continue.")
            return
        }
        // Only when there's something the agent hasn't seen yet.
        let unseen = pool.takeUnreported()
        guard !unseen.isEmpty else { return }
        autoContinuations[vm.id, default: 0] += 1
        let modelText = "(Automatic — not from the user.) Your background agents finished:\n\n"
            + BackgroundAgents.notice(for: unseen) + "\n\nContinue the task with their results."
        runTasks[vm.id] = Task {
            autoTurns.insert(vm.id)
            defer { autoTurns.remove(vm.id) }
            await runTurn(vm, text: "🤖 Background agents finished — continuing", modelText: modelText)
        }
    }

    public func stopBackgroundAgent(sessionID: String, id: String) {
        backgroundPools[sessionID]?.stop(id)
    }

    public func stopBackgroundAgents(sessionID: String) {
        backgroundPools[sessionID]?.stopAll()
    }

    /// `queue_task`: the agent adds a background task to the queue.
    private func agentQueueTask(title: String, details: String, front: Bool, start: Bool, from sessionID: String) -> String {
        let count = agentQueuedCount[sessionID, default: 0]
        guard count < Self.maxAgentQueuedTasksPerChat else {
            return "Error: this chat has already queued \(count) tasks — the limit. Ask the user before queuing more."
        }
        agentQueuedCount[sessionID] = count + 1
        let vm = sessions.first { $0.id == sessionID }
        // From a chat without a project, the task works in that chat's own folder.
        let plain = vm?.isPlain ?? false
        let cwd = plain ? nil : (vm?.cwd ?? projectContext?.root.path)
        let task = queue.add(title, details: details, atFront: front, cwd: cwd,
                             workFolder: plain ? vm.map { scratchFolder(for: $0).path } : nil)
        queue.note(task.id, "Queued by the agent in “\(vm?.title ?? "a chat")”.")
        // The task's chat runs on the model of the chat that queued it.
        if let vm { queue.setRoute(id: task.id, routeID: chatRouteID(vm), thinking: vm.thinking?.rawValue) }
        let position = queue.position(of: task.id) ?? 0
        var out = "Queued “\(task.title)” at #\(position) (\(queue.queuedCount) waiting)."
        if queueRunning {
            out += " The queue is running; it will get to it in order."
        } else if start {
            startQueue()
            out += queueRunning ? " Started the queue." : " The queue couldn't start (no model configured?)."
        } else {
            out += " The queue isn't running — it starts when the user presses Start (or call queue_task with start: true)."
        }
        vm?.note("📋 The agent queued a task: “\(task.title)” (#\(position)).")
        return out
    }

    private func vaultGrants(for sessionID: String) -> VaultGrants {
        if let existing = vaultGrants[sessionID] { return existing }
        let fresh = VaultGrants()
        vaultGrants[sessionID] = fresh
        return fresh
    }

    // MARK: - Credential vault

    /// What the model is told about the vault: which credentials exist (by
    /// name — never a value) and how to use one.
    static func vaultPrompt(_ entries: [VaultEntry]) -> String {
        guard !entries.isEmpty else {
            return """
            --- Credential vault ---
            The user keeps API keys, tokens and passwords in a credential vault (empty right now). If a task needs one, \
            ask them to add it in the Credentials Vault (⌘⇧K) — never ask them to paste a secret into the chat.
            """
        }
        let usable = entries.filter { $0.access != .never }
        let listed = usable.prefix(30).map { e -> String in
            var s = "- \(e.placeholder) (\(e.kind.label)"
            if !e.description.isEmpty { s += ": \(String(e.description.prefix(80)))" }
            if e.access == .ask { s += "; asks the user first" }
            return s + ")"
        }
        var text = """
        --- Credential vault ---
        The user's credentials are in a vault. You never see their values. To use one, write its placeholder where \
        the value goes in any tool call — a shell command (`export OPENAI_API_KEY={{vault:OPENAI_API_KEY}}; …`), a \
        file you write (.env), a URL or header. The harness substitutes the real value when the tool runs and shows \
        [vault:NAME] in results — that text holds the real value, so write {{vault:NAME}} to refer to it (in an edit, \
        for instance). Use vault_search to look credentials up; never ask the user to paste a secret.
        """
        if listed.isEmpty {
            text += "\nNo credential is currently available to you."
        } else {
            text += "\nAvailable:\n" + listed.joined(separator: "\n")
            if usable.count > 30 { text += "\n… and \(usable.count - 30) more (vault_search)." }
        }
        return text
    }

    /// The vault changed (added, edited, deleted in the UI): reload views and
    /// let each chat's next turn pick up the new list.
    public func vaultDidChange() {
        vaultRevision += 1
    }

    private func grants(for sessionID: String) -> ComputerGrants {
        if let existing = computerGrants[sessionID] { return existing }
        let fresh = ComputerGrants()
        computerGrants[sessionID] = fresh
        return fresh
    }

    /// Bridge `Engine.permissionGate` to the UI: publish the gate on the
    /// session and await the user's answer.
    ///
    /// Queue tasks run unattended — a gate nobody answers would stall the
    /// whole queue. So for queue sessions the decision times out (auto-deny)
    /// after a few minutes, and the stall is surfaced in the chat.
    private func askGate(sessionID: String, gateID callID: String, name: String, detail: String) async -> Bool {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return false }
        if Task.isCancelled { return false }
        // Tool-call ids repeat ("call-0" every turn, in every chat): key the
        // question by a token of its own, so two chats can't overwrite each
        // other's continuation and an old timer can't answer a newer question.
        let gateID = "\(callID)#\(UUID().uuidString)"
        vm.pendingGates.append(.init(id: gateID, name: name, detail: detail))
        let isQueue = queueSessions[sessionID] != nil
        let decision: Bool = await withCheckedContinuation { continuation in
            gates[gateID] = (continuation, sessionID)
            if isQueue {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    guard let entry = self.gates[gateID] else { return } // answered or cancelled
                    self.gates[gateID] = nil
                    self.sessions.first { $0.id == sessionID }?.pendingGates.removeAll { $0.id == gateID }
                    if let v = self.sessions.first(where: { $0.id == sessionID }) {
                        v.note("Permission for \(name) auto-denied after 5 minutes — queue tasks run unattended. "
                               + "To allow it, change the permission preset (or the command allowlist) in Settings, "
                               + "then Resume the task.", role: .error)
                    }
                    entry.cont.resume(returning: false)
                }
            }
        }
        gates[gateID] = nil
        vm.pendingGates.removeAll { $0.id == gateID }
        return decision
    }

    /// Answer a pending gate from the UI.
    public func answerGate(sessionID: String, gateID: String, allow: Bool) {
        guard let entry = gates[gateID] else { return }
        gates[gateID] = nil
        entry.cont.resume(returning: allow)
        sessions.first { $0.id == sessionID }?.pendingGates.removeAll { $0.id == gateID }
    }

    private func resolveAllGates(for sessionID: String, with allow: Bool) {
        for (gateID, entry) in gates where entry.sessionID == sessionID {
            gates[gateID] = nil
            entry.cont.resume(returning: allow)
        }
    }

    // MARK: - Sending

    /// Where prompt submissions go when the user is signed into Guardian
    /// (item 4): each sent prompt lands in Guardian's prompt history. Nil in
    /// tests and when not signed in.
    @ObservationIgnored public var guardianSync: (@Sendable (PromptRecord, String) -> Void)?

    public func send(_ text: String, sessionID: String,
                     attachments: [MessageAttachment] = []) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        guard !vm.running, runTasks[sessionID] == nil else {
            vm.note("The agent is still working; send again when it is done.")
            return
        }
        autoContinuations[sessionID] = 0
        dispatch(text, vm: vm, attachments: attachments)
    }

    /// Run what was sent (or what a chat task sends when its turn comes): a command, a skill by name, or a turn.
    func dispatch(_ text: String, vm: SessionVM, attachments: [MessageAttachment] = []) {
        let sessionID = vm.id
        if let command = SlashCommand.parse(text) {
            // A `/goal` takes what is attached (a 10,000-line paste, files) into its first round. No other command
            // takes attachments: say so rather than send the command's words to the model as a prompt.
            if !attachments.isEmpty, let why = Self.commandAttachmentRefusal(text) {
                vm.note(why, role: .error)
                return
            }
            runCommand(command, vm: vm, attachments: attachments)
            return
        }
        // "/deploy staging": a skill or command invoked by name (what is attached goes with it).
        if let (skill, args) = matchSkillCommand(text, vm: vm),
           let expanded = invocationText(skill, arguments: args) {
            if chatServerSwitching(vm) {
                vm.note(Self.switchingNote)
                return
            }
            let display = "/\(skill.slug)" + (args.isEmpty ? "" : " \(args)")
            runTasks[sessionID] = Task { await runTurn(vm, text: display, attachments: attachments, modelText: expanded) }
            return
        }
        if chatServerSwitching(vm) {
            vm.note(Self.switchingNote + " (usually a few minutes)")
            return
        }
        runTasks[sessionID] = Task { await runTurn(vm, text: text, attachments: attachments) }
    }

    // MARK: - Slash commands

    /// Why a command that came with attachments isn't run (nil: it takes them — `/goal`, or not a command at all).
    /// Checked before anything is sent or queued, so the composer keeps the draft and its chips.
    static func commandAttachmentRefusal(_ text: String) -> String? {
        guard let command = SlashCommand.parse(text) else { return nil }
        if case .goal = command { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace }
        return "\(name) doesn't take attachments, so nothing was sent. Send the attachments with a message or a /goal, "
            + "or the command on its own."
    }

    /// The goal a bare `/goal` with attachments states: what is attached is the goal (a pasted prompt, a spec).
    static func attachedGoalText(_ attachments: [MessageAttachment]) -> String {
        let names = attachments.map { "“\($0.name)”" }
        let list = names.count <= 1 ? (names.first ?? "attachment")
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Do what the attached \(list) ask\(attachments.count == 1 ? "s" : "") for."
    }

    private func runCommand(_ command: SlashCommand, vm: SessionVM, attachments: [MessageAttachment] = []) {
        switch command {
        case .help:
            let lines = SlashCommand.catalog.map { "`\($0.usage)` — \($0.summary)" }
            vm.note("Commands:\n" + lines.joined(separator: "\n"))

        case .think(let arg):
            let fallback = chatRoute(vm)?.thinking
            guard let arg else {
                let current = vm.thinking ?? fallback
                vm.note("Thinking: **\(current?.label ?? "server default")**"
                        + (vm.thinking == nil ? " (from the provider setting)" : " (this chat)")
                        + ". Change it with `/think off|low|medium|high|max|default`.")
                return
            }
            if ["default", "reset", "auto"].contains(arg.lowercased()) {
                setThinking(nil, for: vm)
                vm.note("Thinking back to the provider default (\(fallback?.label ?? "server default")).")
            } else if let level = ThinkingLevel(userInput: arg) {
                setThinking(level, for: vm)
                vm.note("Thinking set to **\(level.label)** for this chat — \(level.blurb.lowercased())."
                        + Self.thinkingCaveat(level, rules: requestRules(for: vm)))
            } else {
                vm.note("Unknown level “\(arg)”. Use off, low, medium, high, max, or default.", role: .error)
            }

        case .context:
            runTasks[vm.id] = Task {
                _ = await resolveRoute(vm, force: true)
                let limit = contextLimit(for: vm)
                let used = contextUsed(for: vm.id, draft: "")
                let source = contextSource(for: vm)
                let model = modelID(for: vm) ?? "?"
                vm.note("Context: \(used.formatted()) of \(limit.formatted()) tokens used "
                        + "(\(Int(Double(used) / Double(max(limit, 1)) * 100))%). Model `\(model)`; window \(source). "
                        + "Auto-compaction starts at \(Int(Compaction.triggerFraction * 100))%.")
                runTasks[vm.id] = nil
            }

        case .swap(let arg):
            if let onSwapCommand {
                onSwapCommand(arg, vm)
            } else {
                vm.note("Model switching isn't available.", role: .error)
            }

        case .skills:
            vm.note(skillsSummary(for: vm))

        case .skill(let arg):
            handleSkillCommand(arg, vm: vm)

        case .compact(let focus):
            runTasks[vm.id] = Task { await compactNow(vm, focus: focus) }

        case .queue:
            if queueRunningNow {
                let s = queue.unattended.stats()
                vm.note("Queue is running — \(s.queued) waiting, \(s.completed) done so far. ⌘⇧Q shows the panel; Stop there (or ⌘.) halts it.")
            } else {
                let s = queue.unattended.stats()
                if s.queued > 0 {
                    vm.note("Starting the queue: \(s.queued) task\(s.queued == 1 ? "" : "s") to go, one at a time, unattended.")
                    startQueue()
                } else {
                    vm.note("The queue is empty. Add tasks from the Task Queue panel (⌘⇧Q), then press Start — or /queue again.")
                }
            }

        case .agents:
            agentsCommand(vm)

        case .control(let arg):
            vm.note(setControlScope(vm, argument: arg))

        case .goal(let goal):
            pinRouteIfUnset(vm)
            if let route = chatRoute(vm), route.isInteractiveOnly {
                vm.note(Self.interactiveOnlyGoalMessage(route), role: .error)
                return
            }
            if chatServerSwitching(vm) {
                vm.note(Self.switchingNote)
                return
            }
            // A bare `/goal` picks the chat's unfinished goal back up (after a
            // Stop, a block the user has since answered, or a failure) — unless it came with attachments: then they
            // are the goal ("/goal" and a pasted 10,000-line prompt).
            if goal.isEmpty, attachments.isEmpty {
                guard let previous = vm.lastGoal ?? Self.lastGoal(in: vm.entries) else {
                    vm.note("Usage: `/goal <what you want done>` — the agent keeps working, round after round, "
                            + "until it declares the goal complete (or needs you). Stop it any time with ⌘.")
                    return
                }
                runTasks[vm.id] = Task { await runTurn(vm, text: previous, attachments: [], goal: previous, resumingGoal: true) }
                return
            }
            let stated = goal.isEmpty ? Self.attachedGoalText(attachments) : goal
            runTasks[vm.id] = Task { await runTurn(vm, text: stated, attachments: attachments, goal: stated) }
        }
    }

    /// `/compact`: fold the conversation into a summary now, whatever its size.
    private func compactNow(_ vm: SessionVM, focus: String?) async {
        let sessionID = vm.id
        vm.running = true
        defer {
            vm.running = false
            vm.activity = nil
            runTasks[sessionID] = nil
        }
        switch await compactSession(vm, focus: focus) {
        case .nothingYet:
            vm.note("Nothing to compact yet.")
        case .noModel:
            vm.note(LLMError.noModel.errorDescription ?? "No model configured.", role: .error)
        case .alreadyCompact(let tokens):
            vm.note("The conversation is already as compact as it gets (~\(tokens.formatted()) tokens).")
        case .failed:
            vm.note("Compaction failed: the model did not return a summary. Nothing was changed.", role: .error)
        case .compacted(let removed, let before, let after):
            let text = "Compacted \(removed) messages: ~\(before.formatted()) → ~\(after.formatted()) tokens."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
    }

    enum CompactOutcome {
        case nothingYet, noModel, alreadyCompact(Int), failed
        case compacted(removed: Int, before: Int, after: Int)
    }

    /// Fold the older part of a session's conversation into a summary now,
    /// whatever its size. Shared by `/compact` and a goal round that overflowed.
    /// Leaves the session's running state alone.
    private func compactSession(_ vm: SessionVM, focus: String?) async -> CompactOutcome {
        let sessionID = vm.id
        if transcripts[sessionID] == nil { hydrate(vm) }
        let messages = transcripts[sessionID] ?? []
        guard messages.contains(where: { $0.role == .user }) else { return .nothingYet }
        guard let profile = await resolveRoute(vm) else { return .noModel }
        let prompt = systemPrompts[sessionID] ?? basePrompt
        let before = TokenEstimate.request(systemPrompt: prompt, messages: messages)
        guard let plan = Compaction.plan(usedTokens: before, limit: contextLimit(for: vm),
                                         transcript: messages, force: true) else {
            return .alreadyCompact(before)
        }
        vm.activity = "Compacting conversation…"
        defer { vm.activity = nil }
        let client = ProviderClients.make(profile)
        guard let summary = await Compaction.summarize(client: client, plan: plan,
                                                       model: profile.model, focus: focus),
              !Task.isCancelled else {
            return .failed
        }
        let newMessages = [LLMMessage(role: .system, content: Compaction.summaryHeader + summary)] + plan.toKeep
        applyCompaction(sessionID: sessionID, plan: plan, summary: summary, newMessages: newMessages)
        let after = TokenEstimate.request(systemPrompt: prompt, messages: newMessages)
        return .compacted(removed: plan.toSummarize.count, before: before, after: after)
    }

    /// The most recent `/goal` text in a timeline (display form "🎯 /goal …"),
    /// so a bare `/goal` can resume it even after a relaunch.
    static func lastGoal(in entries: [ChatEntry]) -> String? {
        for entry in entries.reversed() {
            guard case .message(let body) = entry.kind else { continue }
            // The latest goal already finished: nothing to resume.
            if body.role == .notice, body.text.hasPrefix("✅ Goal complete") { return nil }
            guard body.role == .user else { continue }
            for prefix in ["🎯 /goal (resuming) ", "🎯 /goal "] where body.text.hasPrefix(prefix) {
                let goal = String(body.text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return goal.isEmpty ? nil : goal
            }
        }
        return nil
    }

    // MARK: - Turns

    /// Resume a blocked/failed (or skipped) queue task in its own chat. When
    /// the queue is idle this works just that task, unattended, and stops;
    /// when the queue is running it goes next in line. Either way it runs
    /// through the one queue runner, so two tasks never run at once.
    public func resumeTask(_ taskID: String) {
        guard let task = queue.task(taskID), task.status != .running else { return }
        if let sid = task.sessionID, let vm = sessions.first(where: { $0.id == sid }) {
            // An archived chat's timeline was released: load it before anything
            // (a notice, the next turn) lands in it.
            hydrate(vm)
            selectedID = sid
            queueFollowedSession = sid
        }
        startQueue(only: taskID)
    }

    // MARK: - Driving the phases

    /// A turn began: open the planning phase. `prompt` is what the model is
    /// asked (the raw text; a goal's kickoff), so the estimator classifies the
    /// same thing the model sees.
    private func phasesBegin(_ vm: SessionVM, prompt: String) {
        guard vm.phasesEnabled else { return }
        var state = TurnPhaseState(loopbackCap: phaseLoopbackCap)
        let files = projectContext.map { Self.countProjectFiles($0.root) } ?? 0
        phaseRunner.begin(&state, prompt: prompt, projectFiles: files)
        vm.turnPhase = state
    }

    /// The plan settled: first todo list of the turn, or the first paragraph
    /// when the answer has none. Estimates from scope-so-far + history, moves
    /// to execution with the green working badge.
    private func phasesPlanSettled(_ vm: SessionVM) {
        guard var state = vm.turnPhase, state.phase == .planning else { return }
        // What settles a plan, in order of preference: the todo list the
        // model wrote, its proposed plan, or the first paragraph it streamed.
        let plan: String?
        if !vm.todos.isEmpty {
            plan = vm.todos.map { "• \($0.content)" }.joined(separator: "\n")
        } else if let proposed = vm.proposedPlan {
            plan = proposed
        } else {
            plan = nil
        }
        let draftText: String
        if let plan {
            draftText = plan
        } else {
            // First paragraph of the streamed answer, as the de-facto plan.
            let first = vm.entries.reversed().compactMap { $0.message }.first { $0.role == .assistant }
            draftText = first.map { String($0.text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "") } ?? ""
        }
        phaseRunner.planSettled(&state, plan: draftText, stepsPlanned: max(vm.todos.count, 1))
        vm.turnPhase = state
        promptPlanned(vm, state: state)
        if let eta = state.etaSeconds {
            vm.activity = "Planning done — estimated \(TurnPhaseState.phrase(eta)). Executing…"
        }
    }

    /// The answer's first paragraph settled the plan (no todo list this turn).
    private func phasesPlanFromProse(_ vm: SessionVM) {
        guard vm.turnPhase?.phase == .planning, vm.todos.isEmpty else { return }
        phasesPlanSettled(vm)
    }

    /// A step landed (a tool finished): stamped into the working badge's log.
    private func phasesStep(_ vm: SessionVM, text: String) {
        guard var state = vm.turnPhase, state.phase == .execution || state.phase == .planning else { return }
        state.addStep(text)
        vm.turnPhase = state
    }

    /// Files changed: the scope grew a little; keep the count for evidence.
    private func phasesFilesChanged(_ vm: SessionVM, count: Int) {
        guard var state = vm.turnPhase, count > state.filesChanged else { return }
        state.filesChanged = count
        vm.turnPhase = state
    }

    /// The plan grew mid-execution (more todo items appeared): nudge the
    /// estimate up, gently.
    private func phasesRefineIfGrew(_ vm: SessionVM) {
        guard var state = vm.turnPhase, state.phase == .execution, !vm.todos.isEmpty else { return }
        let before = state.etaSeconds
        phaseRunner.refine(&state, stepsPlanned: vm.todos.count)
        vm.turnPhase = state
        if let before, let after = state.etaSeconds, after > before * 1.15 {
            vm.activity = "The plan grew to \(vm.todos.count) steps — estimate now \(TurnPhaseState.phrase(after))."
        }
    }

    /// Validation: check the outcome against the plan the turn set out with,
    /// gather evidence from what the turn already produced, and pass or loop
    /// back. Called when the engine run ends.
    private func phasesValidate(_ vm: SessionVM, result: RunResult?) {
        guard var state = vm.turnPhase, state.phase == .execution else { return }
        // The turn's closing words: the run's last reply, or the newest
        // assistant message in the timeline (the run result isn't always in
        // hand here — a queued task's loop reports through the timeline).
        let reply = result?.lastReplyText
            ?? vm.entries.reversed().compactMap { $0.message }.first { $0.role == .assistant }?.text
            ?? ""
        let failures = Self.validationFailures(state: state, reply: reply)
        if let failure = failures.first {
            // Nothing re-runs a plain turn here, so the card must not claim it does: the turn ends as "Finished with
            // issues", with what validation found — the person decides what to do next.
            state.lastValidationFailure = failure
            gatherEvidence(vm, into: &state, reply: reply)
            state.addEvidence(.init(kind: .note, title: "Validation found an issue", detail: failure))
            state.beginResults(summary: "Finished with issues: \(failure)")
            vm.turnPhase = state
            phasesFinish(vm, completed: false)
            return
        }
        // Passed: evidence from the turn's own work.
        gatherEvidence(vm, into: &state, reply: reply)
        let stepSummary = vm.todos.isEmpty
            ? "Validated: the reply matches what was asked."
            : "Validated against the plan: \(vm.todos.filter { $0.status == .completed }.count) of \(vm.todos.count) steps done."
        state.beginResults(summary: stepSummary)
        vm.turnPhase = state
        phasesFinish(vm, completed: true)
    }

    /// What the turn's own timeline can already prove, so validation has
    /// something to show even when the model wrote no summary: screenshots it
    /// took, files it changed, checks it ran.
    private func gatherEvidence(_ vm: SessionVM, into state: inout TurnPhaseState, reply: String) {
        // Screenshots the turn took are the best evidence there is.
        for entry in vm.entries.reversed().prefix(80) {
            guard let tool = entry.tool, tool.isFinished, tool.isOk == true else { continue }
            if tool.name == "screenshot", !tool.images.isEmpty {
                state.addEvidence(.init(kind: .screenshot, title: "Screenshot of the result",
                                        detail: "captured during validation — see the screenshot card above"))
                break
            }
        }
        if state.filesChanged > 0 {
            let names = vm.changedFiles.prefix(5).map { $0.url.lastPathComponent }.joined(separator: ", ")
            state.addEvidence(.init(kind: .file, title: "\(state.filesChanged) file\(state.filesChanged == 1 ? "" : "s") changed",
                                    detail: names))
        }
        // A reply that lists what it did doubles as a check note.
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            state.addEvidence(.init(kind: .check, title: "The model's closing summary",
                                    detail: String(trimmed.prefix(600))))
        }
    }

    /// A turn ended without reaching validation (cancelled, or an error the
    /// phases never saw): close the phases out honestly.
    private func phasesAbandon(_ vm: SessionVM, reason: String, completed: Bool) {
        guard var state = vm.turnPhase, state.phase != .results else {
            vm.turnPhase = nil
            return
        }
        if completed {
            gatherEvidence(vm, into: &state, reply: "")
            state.beginResults(summary: reason)
        } else {
            state.end(reason: reason)
        }
        vm.turnPhase = state
        phasesFinish(vm, completed: completed)
    }

    /// The turn is over: record the duration in the cache, stamp the prompt
    /// history row, and keep the results card until the next turn begins.
    private func phasesFinish(_ vm: SessionVM, completed: Bool) {
        guard let state = vm.turnPhase else { return }
        phaseRunner.recordCompletion(state)
        // The multitenant cache: the duration goes up to Guardian when the
        // user is signed in (silent on failure — the local cache has it).
        if let kind = state.taskKind, let start = state.startedAt,
           state.phase == .results || state.lastValidationFailure != nil {
            let seconds = (state.finishedAt ?? Date()).timeIntervalSince(start)
            guardianEtaPush?(kind.rawValue, state.scopeScale, seconds)
        }
        // The next turn starts fresh; keep this one's card visible until then.
        vm.turnPhase = state
    }

    /// Set by AppModel: pushes finished-turn durations to Guardian's shared
    /// ETA cache when signed in.
    @ObservationIgnored public var guardianEtaPush: (@Sendable (String, Double, Double) -> Void)?

    static func countProjectFiles(_ root: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        guard let enumerator else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            var skipped = false
            for part in ["node_modules", ".git", ".build", "dist", ".venv", "__pycache__"] where url.path.contains(part) {
                skipped = true
                break
            }
            if !skipped { count += 1 }
            if count > 2_000 { break }
        }
        return count
    }

    /// Should validation fail this turn? Pure so tests can drive it. Checks
    /// what the harness can see on its own — the plan's steps against what
    /// happened — never the model's word alone.
    static func validationFailures(state: TurnPhaseState, reply: String) -> [String] {
        TurnValidation.failures(state: state, reply: reply)
    }

    /// A /goal (or a queue task's goal) the model declared complete: validate before accepting it. Nil when it passes
    /// (the turn moves to results); otherwise the failure, and either the turn is back in execution for another round
    /// (`accept` false) or — at the cap, or after the no-progress check — it finishes with issues (`accept` true).
    private func phasesValidateGoal(_ vm: SessionVM, reply: String, last: inout GoalValidation, accept: inout Bool) -> String? {
        accept = true
        guard var state = vm.turnPhase, !state.isOver else { return nil }
        if state.phase == .planning {
            phasesPlanSettled(vm)
            state = vm.turnPhase ?? state
        }
        let done = vm.todos.filter { $0.status == .completed }.count
        // Only what the harness can see: an error the closing words report.
        guard let marker = TurnValidation.reportedError(reply) else {
            last = GoalValidation(failure: nil, done: done, streak: 0)
            // An earlier attempt's failure is fixed now: the card and the record say it passed.
            state.lastValidationFailure = nil
            gatherEvidence(vm, into: &state, reply: reply)
            state.beginResults(summary: vm.todos.isEmpty
                ? "Validated: the reply matches what was asked."
                : "Validated against the plan: \(done) of \(vm.todos.count) steps done.")
            vm.turnPhase = state
            phasesFinish(vm, completed: true)
            return nil
        }
        let failure = "the reply reports an error (\(marker.trimmingCharacters(in: .whitespaces)))"
        let streak = TurnValidation.madeNoProgress(previousFailure: last.failure, failure: failure,
                                                   stepsDoneBefore: last.done, stepsDoneNow: done) ? last.streak + 1 : 0
        last = GoalValidation(failure: failure, done: done, streak: streak)
        if streak < TurnValidation.noProgressLimit, state.loopBack(reason: failure) {
            accept = false
            vm.turnPhase = state
            return failure
        }
        // Capped, or going nowhere: finish with what was achieved, and say what didn't pass.
        state.lastValidationFailure = failure
        gatherEvidence(vm, into: &state, reply: reply)
        state.addEvidence(.init(kind: .note,
                                title: streak >= TurnValidation.noProgressLimit
                                    ? "Validation stopped: no progress in two attempts" : "Validation hit the retry cap",
                                detail: "Last failure: " + failure))
        state.beginResults(summary: "Finished with issues: \(failure)")
        vm.turnPhase = state
        phasesFinish(vm, completed: false)
        return failure
    }

    /// The last goal validation: its failure, the plan steps done then, and how many attempts in a row made no progress.
    struct GoalValidation {
        var failure: String?
        var done = 0
        var streak = 0
    }

    private func runTurn(_ vm: SessionVM, text: String, attachments: [MessageAttachment] = [],
                         goal: String? = nil, modelText: String? = nil, resumingGoal: Bool = false) async {
        let sessionID = vm.id
        vm.running = true
        vm.stopping = false
        // A new prompt begins a new turn: fresh phases. A resumed goal (a blocked queue task picked back up) continues
        // the same turn. Either way the prompt gets its row in the Prompts timeline.
        if !resumingGoal {
            phasesBegin(vm, prompt: modelText ?? goal ?? text)
        }
        let source: PromptRecord.Source = goal != nil ? .goal : (modelText != nil && text.hasPrefix("/") ? .skill : .typed)
        let isAutomatic = autoTurns.contains(sessionID)
        if !isAutomatic { beginPrompt(vm, text: text, source: source) }
        // How it ended, for its timeline row and the chat's task list.
        var outcome: PromptRecord.Outcome = .completed
        var reason: String?
        defer {
            vm.running = false
            vm.stopping = false
            vm.goal = nil
            vm.activity = nil
            vm.retry = nil
            vm.clearReasoning()
            vm.endStreaming()
            runTasks[sessionID] = nil
            log.touch(sessionID)
            vm.updatedAt = .now
            sessions.sort { $0.updatedAt > $1.updatedAt }
            if !isAutomatic { finishPrompt(vm, outcome: outcome, reason: reason) }
            afterWork(vm, outcome: outcome)
        }

        do {
            if let goal {
                let ending = try await runGoal(vm, goal: goal, attachments: attachments, resuming: resumingGoal)
                if case .blocked(let why) = ending {
                    outcome = .needsYou
                    reason = why
                }
            } else {
                _ = try await turn(vm, modelText: modelText ?? text, displayText: text, attachments: attachments)
            }
            // The engine run ended: validate what happened. Only a turn that
            // got as far as executing validates; a stopped one is closed out.
            if outcome == .needsYou {
                phasesAbandon(vm, reason: "Paused — the agent needs you: \(reason ?? "")", completed: false)
            } else if vm.turnPhase?.phase == .execution {
                phasesValidate(vm, result: nil)
            } else if let state = vm.turnPhase, state.phase == .planning {
                // Never got a plan (the model only asked a question): the
                // prose is its plan; go straight to results.
                phasesPlanFromProse(vm)
                phasesValidate(vm, result: nil)
            }
            if outcome != .needsYou, let failure = vm.turnPhase?.lastValidationFailure, vm.turnPhase?.phase == .results {
                outcome = .issues
                reason = failure
            }
        } catch is CancellationError {
            outcome = .stopped
            reason = "Stopped before it finished."
            phasesAbandon(vm, reason: "Stopped before finishing.", completed: false)
            vm.endStreaming()
            let text = goal != nil ? "Stopped. The goal was not finished — send `/goal` to pick it back up." : "Stopped."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        } catch {
            if Task.isCancelled {
                outcome = .stopped
                reason = "Stopped before it finished."
                phasesAbandon(vm, reason: "Stopped before finishing.", completed: false)
                vm.endStreaming()
                vm.note("Stopped.")
                log.recordItem(sessionID, kind: "notice", text: "Stopped.", toolName: nil, argSummary: nil, output: nil, isError: false)
                return
            }
            let message = PlanCatalog.explainChatError(error, route: chatRoute(vm)) ?? Self.describe(error)
            outcome = .failed
            reason = message
            phasesAbandon(vm, reason: message, completed: false)
            vm.endStreaming()
            vm.note(message, role: .error)
            log.recordItem(sessionID, kind: "error", text: message, toolName: nil, argSummary: nil, output: nil, isError: true)
            banner = message
            awsSignInProfile = Self.expiredAWSProfile(for: error, route: chatRoute(vm))
        }
    }

    /// Why the queue won't start on the main model.
    static func interactiveOnlyQueueMessage(_ route: ProviderProfile) -> String {
        "\(routeLabel(route)) is for interactive use only under its plan's terms, so the queue won't run on it. Make another model primary for unattended work."
    }

    /// Why `/goal` won't start on the chat's model (a goal keeps working without the user).
    static func interactiveOnlyGoalMessage(_ route: ProviderProfile) -> String {
        "\(routeLabel(route)) is for interactive use only under its plan's terms, so /goal — which keeps working without you — won't run on it. Choose another model for this chat (the model menu under the message box) for unattended work."
    }

    /// The AWS CLI profile to sign in again when `error` means a Bedrock route's sign-in ran out or was
    /// refused; nil for anything else. A Bedrock client marks exactly those refusals permanent with a
    /// 401/403 (a missing model or a busy service are not), so on a route that signs in with an AWS
    /// profile the remedy is always "sign in again" — and one click, not a cryptic error.
    static func expiredAWSProfile(for error: Error, route: ProviderProfile?) -> String? {
        guard let route, route.kind == .bedrock, let profile = route.awsProfile, !profile.isEmpty,
              case LLMError.rejected(let status, _, _, let permanent) = error,
              permanent, status == 401 || status == 403 else { return nil }
        return profile
    }

    /// How a goal loop ends. There is no round cap: only the model's verdict,
    /// the user's Stop, or an error retrying can't fix (thrown) end it.
    public enum GoalOutcome: Equatable, Sendable {
        case complete
        case blocked(String)
        case stopped   // cancelled by the user
    }

    /// `/goal`: run rounds until the model writes GOAL_COMPLETE (or GOAL_BLOCKED),
    /// re-stating the goal every round so it survives compaction.
    @discardableResult
    private func runGoal(_ vm: SessionVM, goal: String, attachments: [MessageAttachment] = [],
                         resuming: Bool) async throws -> GoalOutcome {
        vm.lastGoal = goal
        let outcome = try await goalLoop(vm, goal: goal, auto: false, resuming: resuming, attachments: attachments)
        if outcome == .complete { vm.lastGoal = nil }
        // Stopped between rounds: report it like a Stop mid-round.
        if outcome == .stopped { throw CancellationError() }
        return outcome
    }

    /// The goal loop, interactive (`/goal`) or unattended (`auto`, the task
    /// queue: "decide and move on" wording, and every round reports its
    /// tokens so the queue can log average speed).
    ///
    /// It keeps going round after round until the model declares the goal
    /// complete or blocked. Model outages never end it — the engine retries
    /// those until the server answers. Other errors (a request the server
    /// rejects, an overflow compaction couldn't fix) are retried as a fresh
    /// round after a pause; only `GoalProtocol.maxConsecutiveErrors` of them
    /// in a row end the goal (thrown). Cancellation throws `CancellationError`
    /// or returns `.stopped`.
    /// `attachments` go with the kickoff only (the goal's first round): the goal is re-stated every round, what was
    /// attached is not — it stays in the conversation, and a long one is read back with read_attachment.
    private func goalLoop(_ vm: SessionVM, goal: String, auto: Bool, resuming: Bool = false,
                          attachments: [MessageAttachment] = []) async throws -> GoalOutcome {
        var state = SessionVM.GoalState(text: goal, round: 1)
        vm.goal = state
        let awake = keepAwake("Working a goal")
        // Queue turns run outside runTurn, so clean up the same flags it does.
        defer {
            endKeepAwake(awake)
            vm.goal = nil
            vm.activity = nil
            vm.retry = nil
            vm.clearReasoning()
            vm.endStreaming()
        }

        func report(_ r: Int, _ usage: LLMUsage?) {
            if auto, let taskID = queueSessions[vm.id] {
                queue.recordRound(taskID, round: r, prompt: usage?.promptTokens ?? 0,
                                  completion: usage?.completionTokens ?? 0)
            }
        }
        func notice(_ text: String, error: Bool = false) {
            vm.note(text, role: error ? .error : .notice)
            log.recordItem(vm.id, kind: error ? "error" : "notice", text: text, toolName: nil,
                           argSummary: nil, output: nil, isError: error)
        }

        var round = 1
        var kickedOff = false        // the kickoff reached the model's transcript
        var hitLimit = false
        var lastError: String? = nil
        var errorsInARow = 0
        var emptyInARow = 0          // rounds with no reply at all
        var markerMisplaced = false
        var validation = GoalValidation()
        var validationFailure: String?   // sends the next round back to fix what validation found
        while true {
            if Task.isCancelled { return .stopped }
            // The primary became an interactive-only plan while the goal ran (the user switched it): no more
            // unattended rounds on it.
            if let route = chatRoute(vm), route.isInteractiveOnly {
                let why = auto ? Self.interactiveOnlyQueueMessage(route) : Self.interactiveOnlyGoalMessage(route)
                notice(why, error: true)
                return .blocked(why)
            }
            let modelText: String
            let displayText: String
            if !kickedOff {
                if auto {
                    modelText = resuming ? GoalProtocol.resumeAuto(goal) : GoalProtocol.kickoffAuto(goal)
                    displayText = resuming ? "🚀 queue (resuming): \(goal)" : "🚀 queue: \(goal)"
                } else {
                    modelText = resuming ? GoalProtocol.resume(goal) : GoalProtocol.kickoff(goal)
                    displayText = resuming ? "🎯 /goal (resuming) \(goal)" : "🎯 /goal \(goal)"
                }
            } else if let failure = validationFailure {
                let attempt = (vm.turnPhase?.loopbacks ?? 0) + 1
                modelText = TurnValidation.loopBackMessage(failure, attempt: attempt)
                displayText = TurnValidation.loopBackDisplay(attempt: attempt)
            } else {
                modelText = auto
                    ? GoalProtocol.continuationAuto(goal, round: round, hitIterationLimit: hitLimit, error: lastError,
                                                    markerMisplaced: markerMisplaced)
                    : GoalProtocol.continuation(goal, round: round, hitIterationLimit: hitLimit, error: lastError,
                                                markerMisplaced: markerMisplaced)
                displayText = lastError == nil ? "↻ round \(round): keep going" : "↻ round \(round): recover and keep going"
            }
            validationFailure = nil

            do {
                let result = try await turn(vm, modelText: modelText, displayText: displayText,
                                            attachments: kickedOff ? [] : attachments)
                report(round, result.usage)
                kickedOff = true
                errorsInARow = 0
                lastError = nil
                hitLimit = result.hitIterationLimit
                // A run cut off by the step limit is mid-work whatever it said.
                if !result.hitIterationLimit {
                    switch GoalProtocol.status(of: result.lastReplyText) {
                    case .complete:
                        // Validation first: an error the closing words report sends it back to work (unlimited by
                        // default, cappable, and stopped by the no-progress check).
                        var accept = true
                        let failed = phasesValidateGoal(vm, reply: result.lastReplyText, last: &validation, accept: &accept)
                        if let failed, !accept {
                            validationFailure = failed
                            notice("⚠️ Validation failed: \(failed) — working on it again"
                                   + (vm.turnPhase?.loopbackCap.map { " (capped at \($0) retries)." } ?? "."))
                            if let taskID = queueSessions[vm.id] { queue.note(taskID, "Validation failed (\(failed)) — another round.") }
                            break
                        }
                        if !auto {
                            notice("✅ Goal complete after \(round) round\(round == 1 ? "" : "s")"
                                   + (failed.map { " — but validation still found a problem: \($0)." } ?? "."))
                        }
                        return .complete
                    case .blocked(let why):
                        if !auto {
                            notice("⏸ Goal paused — the agent needs you: \(why)\nReply, then send `/goal` to pick it back up.")
                        }
                        return .blocked(why)
                    case .working:
                        break
                    }
                }
                // Named the marker but not where it counts: ask for it plainly.
                markerMisplaced = !result.hitIterationLimit && GoalProtocol.mentionsMarker(result.lastReplyText)
                // A model that keeps answering with nothing gets a growing
                // pause between rounds instead of a hot loop.
                if result.lastReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !result.hitIterationLimit {
                    emptyInARow += 1
                    if emptyInARow >= 2 {
                        try await Task.sleep(nanoseconds: UInt64(max(0, goalErrorBackoff(emptyInARow - 1)) * 1_000_000_000))
                    }
                } else {
                    emptyInARow = 0
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // The failed kickoff may still have reached the transcript
                // (work was salvaged): carry on with continuations, not a restart.
                if !kickedOff, transcripts[vm.id]?.contains(where: { $0.role == .user && $0.content == modelText }) == true {
                    kickedOff = true
                }
                markerMisplaced = false
                errorsInARow += 1
                let why = Self.describe(error)
                if errorsInARow >= GoalProtocol.maxConsecutiveErrors { throw error }
                let wait = max(0, goalErrorBackoff(errorsInARow))
                notice("Round \(round) failed: \(why)\nThe goal carries on — trying again in \(Int(wait))s "
                       + "(\(errorsInARow) of \(GoalProtocol.maxConsecutiveErrors - 1) retries).", error: true)
                if let taskID = queueSessions[vm.id] {
                    queue.note(taskID, "Round \(round) failed (\(why.prefix(160))) — retrying.")
                }
                // Too long for the window even after in-run compaction: fold
                // the conversation now so the next round fits.
                if case LLMError.overflow = error { _ = await compactSession(vm, focus: nil) }
                lastError = why
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            round += 1
            state.round = round
            vm.goal = state
            promptRound(vm, round: round)
        }
    }

    /// One user message → one engine run (which may take many tool steps).
    private func turn(_ vm: SessionVM, modelText: String, displayText: String,
                      attachments: [MessageAttachment]) async throws -> RunResult {
        let sessionID = vm.id
        // A chat whose timeline was released (archived queue chat) or never
        // loaded: bring it back first, so the model keeps its history and a
        // later log resync can't overwrite what's on disk.
        hydrate(vm)
        // Prime the transcript from the display timeline when it's missing: a
        // brand-new session (no entries → empty) or an *archived* queue task
        // whose in-memory transcript was evicted but whose compacted timeline
        // still lives on disk. This happens before the user entry is appended
        // so the current turn's text is not sent twice.
        if transcripts[sessionID] == nil {
            transcripts[sessionID] = vm.entries.isEmpty ? [] : Self.replayMessages(vm.entries)
        }
        let firstBadges = attachments.map { AttachmentBadge($0) }
        let userEntryID = vm.appendMessage(.user, displayText, attachments: firstBadges)
        log.recordItem(sessionID, kind: "user", text: displayText, toolName: nil, argSummary: nil, output: nil, isError: false,
                       attachments: firstBadges.isEmpty ? nil : firstBadges)
        promptEntryLanded(vm, entryID: userEntryID, displayText: displayText)
        if vm.title == "New chat" {
            let first = displayText.split(separator: "\n").first.map(String.init) ?? displayText
            let title = String(first.prefix(48))
            if !title.isEmpty { renameSession(sessionID, to: title) }
        }

        // This chat's own model — never the one another chat picked. Re-read what its server serves right now: the
        // Spark can swap models between turns, and the window/model id must follow.
        pinRouteIfUnset(vm)
        guard let profile = await resolveRoute(vm) else { throw LLMError.noModel }
        turnRoute[sessionID] = RouteUse(model: profile.model, route: Self.routeLabel(profile))
        let window = contextLimit(for: vm)
        let thinking = vm.thinking
        let skillState = self.skillState(for: vm)
        let unattended = isUnattended(vm)
        let backups = backupProfiles(unattended: unattended, excluding: profile.routeID)
        let key = EngineKey(profile: profile, window: window, thinking: thinking, preset: vm.preset,
                            skills: skillState.signature, computerTools: config.computerToolsEnabled,
                            vision: visionOn(for: profile), vault: vault.revision, agents: agentsStamp(for: vm),
                            backups: backups, servers: subagentServerEntries, unattended: unattended)
        if let previous = engineKeys[sessionID], previous.profile.model != profile.model {
            vm.note("The server is now serving `\(profile.model)` (was `\(previous.profile.model)`) — switched to it, \(window.formatted())-token window.")
        }
        let engine: Engine
        if let existing = engines[sessionID], engineKeys[sessionID] == key {
            engine = existing
        } else {
            engine = self.engine(for: sessionID, vm: vm, client: mainClient(profile, backups: backups, sessionID: sessionID),
                                 window: window, thinking: thinking, skillState: skillState, unattended: unattended,
                                 home: fleetHome(for: vm, profile: profile))
            engineKeys[sessionID] = key
        }
        retryRoute[sessionID] = nil
        failoverNoticed.remove(sessionID)
        let input = transcripts[sessionID] ?? []
        // Attachments go as what this route takes: text read out of every file (a long one in parts the model
        // reads with read_attachment), pictures only to a model that takes them.
        let outgoing = attachments.isEmpty ? attachments
            : await prepareAttachments(attachments, vm: vm, entryID: userEntryID, profile: profile, window: window)

        // Engine events arrive on a pool thread; hop to main so the
        // timeline is only ever mutated from one place.
        let sink = self
        let progress = RunProgress()
        let result: RunResult
        do {
            result = try await engine.run(messages: input, userText: modelText,
                                          userAttachments: outgoing, progress: progress) { event in
                Task { @MainActor in
                    sink.apply(event, sessionID: sessionID)
                }
            }
        } catch {
            // Keep what the run already did — tool calls that ran and their
            // results — so the model's memory matches the files on disk and
            // the timeline, instead of rolling back to before the run.
            if let salvaged = progress.salvaged {
                transcripts[sessionID] = salvaged
            } else {
                // The model never saw this message: say so, and keep it out of
                // the replayed conversation (and compaction's counting).
                markUndelivered(vm, entryID: userEntryID)
                // Nor the finished background agents' reports that rode on it: announce them with the next message.
                backgroundPools[sessionID]?.requeue(progress.takenReports)
            }
            vm.endStreaming()
            // A server overflow that still surfaced tells us the real window is
            // smaller than we budgeted — learn it so the gauge and future
            // compaction use the true number.
            if case LLMError.overflow(let limit, _) = error, limit > 0,
               let provider = chatRoute(vm) {
                overflowCeiling[provider.routeID] = min(limit, overflowCeiling[provider.routeID] ?? limit)
            }
            vm.retry = nil
            throw error
        }
        vm.retry = nil
        transcripts[sessionID] = result.messages
        vm.lastUsage = result.usage
        if let usage = result.usage {
            vm.turnPromptTokens += usage.promptTokens
            vm.turnCompletionTokens += usage.completionTokens
        }
        // A mask report still waiting for an answer to sit on goes on the turn's last answer.
        if let pending = vm.pendingMask, let answer = vm.currentAnswerID {
            vm.masked[answer] = pending
            vm.pendingMask = nil
        }
        // How full the context is now: server-reported prompt tokens when
        // available, otherwise a character-based estimate of the whole
        // request (system prompt + transcript).
        let systemPrompt = engines[sessionID]?.systemPrompt ?? basePrompt
        vm.contextUsed = result.lastPromptTokens
            ?? Self.estimateTokens(systemPrompt: systemPrompt, messages: result.messages)
        if result.deniedCount > 0 {
            vm.note("\(result.deniedCount) tool call(s) were denied.")
        }
        if result.hitIterationLimit, vm.goal == nil {
            vm.note("Paused after \(engine.config.maxIterations) steps. Say “continue” to keep going, or use `/goal` for long tasks.")
        }
        return result
    }

    // MARK: - Attachments

    /// Where a chat's attachments are saved (their full text, for `read_attachment`).
    func attachmentStore(for sessionID: String) -> AttachmentStore {
        AttachmentStore.forChat(sessionID, root: skillLocations.appSupport.appendingPathComponent("attachments", isDirectory: true))
    }

    /// What a route takes besides text — what the composer's chips describe (pass the chat's own route; nil = the primary).
    func attachmentRoute(for profile: ProviderProfile? = nil) -> AttachmentRoute {
        guard let profile = profile ?? config.activeProvider else { return .textOnly }
        var route = AttachmentRoute.of(effective(profile))
        route.vision = route.vision && visionOn(for: profile)
        return route
    }

    /// Read (if the composer hadn't), budget, split and save a message's attachments off the main thread, and put
    /// the final badges — how each one went — under the user's message.
    private func prepareAttachments(_ attachments: [MessageAttachment], vm: SessionVM, entryID: String,
                                    profile: ProviderProfile, window: Int) async -> [MessageAttachment] {
        let store = attachmentStore(for: vm.id)
        let route = attachmentRoute(for: profile)
        let previous = vm.activity
        if attachments.contains(where: { $0.digest == nil }) { vm.activity = "Reading attachments…" }
        let prepared = await Task.detached(priority: .userInitiated) {
            AttachmentPrep.prepare(attachments, window: window, store: store)
        }.value
        vm.activity = previous
        let badges = zip(prepared.badges, prepared.attachments).map { badge, attachment in
            var badge = badge
            badge.label += " · " + AttachmentWire.delivery(attachment, route: route).label
            return badge
        }
        vm.setAttachments(entryID: entryID, badges)
        log.setAttachments(vm.id, onLastUser: badges)
        return prepared.attachments
    }

    /// Turn a user entry the model never received into a notice.
    private func markUndelivered(_ vm: SessionVM, entryID: String) {
        guard let index = vm.entries.lastIndex(where: { $0.id == entryID }),
              case .message(let body) = vm.entries[index].kind, body.role == .user else { return }
        vm.entries[index].kind = .message(.init(role: .notice, text: "Not delivered to the model: \(body.text)"))
        if vm.loaded { log.resync(vm.id, rows: Self.logRows(for: vm.entries, sessionID: vm.id)) }
    }

    private func apply(_ event: EngineEvent, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        switch event {
        case .textDelta(let chunk):
            if vm.retry != nil { vm.retry = nil }
            vm.clearReasoning()
            vm.appendDelta(chunk)
            // The planning draft streams live: the first chunk of a turn's
            // answer is the plan being written in real time.
            if var state = vm.turnPhase, state.phase == .planning {
                state.draft += chunk
                if state.draft.count > 8_000 { state.draft = String(state.draft.suffix(6_000)) }
                vm.turnPhase = state
            }

        case .reasoningDelta(let chunk):
            if vm.retry != nil { vm.retry = nil }
            vm.appendReasoning(chunk)

        case .retrying(let attempt, let delay, let reason):
            // The failed attempt's partial reply is void — the retry streams
            // the whole reply again — so drop its bubble.
            if let streaming = vm.streamingID,
               let index = vm.entries.lastIndex(where: { $0.id == streaming }) {
                vm.entries.remove(at: index)
            }
            vm.streamingID = nil
            vm.clearReasoning()
            vm.retry = .init(attempt: attempt, reason: reason, nextAttempt: Date().addingTimeInterval(delay))
            if attempt == 1 {
                let text = "⚠️ The model didn't answer (\(reason)). Retrying automatically until it's available — press Stop to give up."
                vm.note(text)
                log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
                if let taskID = queueSessions[sessionID] {
                    queue.note(taskID, "Model unavailable (\(reason)) — retrying until it answers.")
                }
            }

        case .recovered(let attempts):
            vm.retry = nil
            let text = "✓ The model is answering again (after \(attempts) retr\(attempts == 1 ? "y" : "ies"))."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
            if let taskID = queueSessions[sessionID] { queue.note(taskID, text) }

        case .assistantMessage(_, let text, let calls):
            // A plan-mode run's proposed plan goes to the plan panel.
            if let plan = calls.last(where: { $0.name == ExitPlanModeTool.name }).flatMap({ JSONArgs.string($0.arguments, "plan") }),
               !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.proposedPlan = plan
                planAppeared(in: vm)
            }
            // Fold a turn's complete text if deltas never arrived, then close
            // the bubble so any tool calls render after it.
            if vm.streamingID == nil, !text.isEmpty {
                vm.appendMessage(.assistant, text)
            }
            if !text.isEmpty {
                log.recordItem(sessionID, kind: "assistant", text: text,
                               toolName: nil, argSummary: nil, output: nil, isError: false)
            }
            vm.endStreaming()

        case .toolStarted(let id, let name, let preview):
            if vm.retry != nil { vm.retry = nil }
            vm.clearReasoning()
            vm.startTool(id: id, name: name, preview: preview)
            // A computer-use tool is on the machine: light the glow and name the chat in it.
            if Self.machineTools.contains(name) { machineToolStarted(name, in: vm) }
            // A tool call means the plan is settled (the model has moved to
            // work); a question-only turn settles on its prose instead.
            phasesPlanSettled(vm)

        case .toolFinished(let id, let name, let ok, let summary, let output):
            vm.finishTool(id: id, ok: ok, summary: summary, output: output)
            phasesStep(vm, text: "\(Theme.toolLabel(name)) \(vm.entries.last(where: { $0.id == id })?.tool?.preview ?? summary)"
                           + (ok ? "" : " — failed"))
            // The machine tool ended: if no other one is running, dim the glow.
            if Self.machineTools.contains(name) { machineToolFinished(in: vm) }
            if name == "propose_skill", ok, output.contains("Saved draft") {
                refreshDrafts()
                vm.note("📝 The agent drafted a skill. It is not active until you approve it — open **Skills** under the composer (or Settings ▸ Skills) to review it.")
            }
            log.recordItem(sessionID, kind: "tool", text: summary, toolName: name,
                           argSummary: vm.entries.last(where: { $0.id == id })?.tool?.preview,
                           output: output, isError: !ok)

        case .toolImages(let id, let images):
            vm.attachImages(id: id, images.compactMap { ImageThumbnails.make(from: $0.data) ?? $0.data })

        case .filesChanged(let changes):
            vm.recordFileChanges(changes)
            phasesFilesChanged(vm, count: vm.changedFiles.count)
            onFilesChanged?(changes)

        case .finished(let usage):
            vm.lastUsage = usage
            vm.endStreaming()
            // A question-only turn settles its plan on the prose it streamed.
            phasesPlanFromProse(vm)

        case .permissionQuestion(let id, let name, let detail):
            if !vm.pendingGates.contains(where: { $0.id == id }) {
                vm.pendingGates.append(.init(id: id, name: name, detail: detail))
            }

        case .todos(let todos):
            vm.setTodos(todos)
            // The todo list is the plan: settle (or refine) the estimate on it.
            if vm.turnPhase?.phase == .planning {
                phasesPlanSettled(vm)
            } else if vm.turnPhase?.phase == .execution {
                phasesRefineIfGrew(vm)
            }

        case .failed(let message):
            vm.note(message, role: .error)
            banner = message
        }
    }

    // MARK: - The plan panel

    /// The agent wrote a todo list or proposed a plan: the first time in the chat the user is looking at, the
    /// plan panel opens by itself (when they want that).
    private func planAppeared(in vm: SessionVM) {
        guard !vm.planAutoOpened else { return }
        vm.planAutoOpened = true
        if vm.id == selectedID, config.planPanelAutoOpen, !config.planPanelOpen {
            config.planPanelOpen = true
        }
    }

    // MARK: - Images

    /// Routes whose server rejected an image (learned at runtime).
    @ObservationIgnored private var noVisionRoutes: Set<String> = []

    func visionOn(for profile: ProviderProfile?) -> Bool {
        guard let profile else { return true }
        if noVisionRoutes.contains(profile.routeID) { return false }
        // What the user set, else what the model is known to take (Z.ai's text models read no images).
        return profile.vision ?? ModelRequestRules.for(profile, model: profile.model).acceptsImages ?? true
    }

    // MARK: - Skills

    /// Reload the approval queue (and tell open views to reload).
    public func refreshDrafts() {
        pendingDrafts = SkillDrafts.list(locations: skillLocations)
        skillsRevision += 1
    }

    /// Every skill visible from a chat's project (shadowed ones included). A chat without a project has the user's
    /// own and the built-in skills — no project's. (With no chat, the open project's.)
    public func skills(for vm: SessionVM?) -> [Skill] {
        SkillCatalog.loadAll(project: vm.map(\.workspaceURL) ?? projectContext?.root,
                             locations: skillLocations, sources: config.skillSources)
    }

    public func selection(for sessionID: String) -> SkillSelection {
        let chosen = config.sessionSkills[sessionID]
        return SkillSelection(pinned: Set(chosen?.pinned ?? []), auto: chosen?.auto ?? true,
                              disabled: config.disabledSkills)
    }

    fileprivate func skillState(for vm: SessionVM) -> SkillState {
        let all = skills(for: vm)
        let selection = selection(for: vm.id)
        let result = SkillPrompt.build(skills: all, selection: selection)
        let active = SkillPrompt.active(all, selection)
        var hasher = Hasher()
        hasher.combine(result.text)
        hasher.combine(active.map(\.id))
        return SkillState(all: all, active: active, result: result, signature: hasher.finalize())
    }

    public func isPinned(_ skill: Skill, in vm: SessionVM) -> Bool {
        config.sessionSkills[vm.id]?.pinned.contains(skill.id) ?? false
    }

    public func setPinned(_ skill: Skill, _ on: Bool, in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.pinned.removeAll { $0 == skill.id }
        if on { chosen.pinned.append(skill.id) }
        config.sessionSkills[vm.id] = chosen
    }

    public func setAutoSkills(_ on: Bool, in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.auto = on
        config.sessionSkills[vm.id] = chosen
    }

    public func clearPinnedSkills(in vm: SessionVM) {
        var chosen = config.sessionSkills[vm.id] ?? SessionSkillSelection()
        chosen.pinned = []
        config.sessionSkills[vm.id] = chosen
    }

    /// `/skills`: what exists and what this chat uses.
    private func skillsSummary(for vm: SessionVM) -> String {
        let all = skills(for: vm).filter { !$0.shadowed }
        guard !all.isEmpty else {
            return "No skills yet. Create one in Settings ▸ Skills, import from Claude/Cursor, or try `/skill new <what it should do>`."
        }
        let sel = selection(for: vm.id)
        let lines = all.prefix(40).map { s -> String in
            let mark = sel.pinned.contains(s.id) ? "📌" : (sel.disabled.contains(s.id) ? "○ off" : "•")
            let tags = [s.origin.label, s.kind == .skill ? nil : s.kind.label.lowercased(), s.alwaysApply ? "always" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return "\(mark) **\(s.name)** (\(tags)) — \(String(s.description.prefix(90)))"
        }
        var text = "Skills (\(all.count)):\n" + lines.joined(separator: "\n")
        if all.count > 40 { text += "\n… and \(all.count - 40) more (see the Skills button)." }
        text += "\n\nAuto-pick by the model: **\(sel.auto ? "on" : "off")**. `/skill <name>` selects one for this chat, `/<name>` runs it, `/skill new <what>` writes a new one."
        if !pendingDrafts.isEmpty { text += "\n📝 \(pendingDrafts.count) draft\(pendingDrafts.count == 1 ? "" : "s") awaiting your approval." }
        return text
    }

    private func handleSkillCommand(_ arg: String?, vm: SessionVM) {
        guard let arg, !arg.isEmpty else {
            vm.note(skillsSummary(for: vm))
            return
        }
        let lower = arg.lowercased()
        for verb in ["new ", "generate ", "create "] where lower.hasPrefix(verb) {
            let goal = String(arg.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
            guard !goal.isEmpty else { break }
            runTasks[vm.id] = Task { await generateSkillFromChat(vm, goal: goal) }
            return
        }
        if ["off", "clear", "none"].contains(lower) {
            clearPinnedSkills(in: vm)
            vm.note("Cleared the skills selected for this chat.")
            return
        }
        if lower == "auto on" || lower == "auto off" {
            setAutoSkills(lower == "auto on", in: vm)
            vm.note("The model \(lower == "auto on" ? "can" : "can no longer") choose skills on its own in this chat.")
            return
        }
        let live = SkillPrompt.active(skills(for: vm), selection(for: vm.id))
        let key = SkillNaming.slug(arg)
        guard let skill = live.first(where: { $0.slug == key }) ?? live.first(where: { $0.slug.contains(key) && !key.isEmpty }) else {
            vm.note("No active skill matches “\(arg)”. `/skills` lists them.", role: .error)
            return
        }
        let now = !isPinned(skill, in: vm)
        setPinned(skill, now, in: vm)
        vm.note(now ? "📌 **\(skill.name)** is selected for this chat — its instructions are included from the next message."
                    : "**\(skill.name)** is no longer selected for this chat.")
    }

    /// `/name args`: the skill or command being run, if the text names one.
    private func matchSkillCommand(_ text: String, vm: SessionVM) -> (Skill, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let head = trimmed.prefix { !$0.isWhitespace }
        let word = String(head.dropFirst())
        guard !word.isEmpty else { return nil }
        let args = trimmed.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SkillNaming.slug(word)
        let live = SkillPrompt.active(skills(for: vm), selection(for: vm.id))
        guard let skill = live.first(where: { $0.userInvocable && ($0.slug == key || $0.name.lowercased() == word.lowercased()) })
        else { return nil }
        return (skill, args)
    }

    /// The message the model sees when the user runs a skill.
    private func invocationText(_ skill: Skill, arguments: String) -> String? {
        guard let doc = skill.document() else { return nil }
        var body = SkillArguments.expand(doc.body, arguments: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > SkillPrompt.perSkillCap { body = String(body.prefix(SkillPrompt.perSkillCap)) + "\n[… truncated]" }
        let withArgs = arguments.isEmpty ? "" : " with: \(arguments)"
        return """
        The user ran the skill “\(skill.name)”\(withArgs). Follow it now.

        <skill name="\(skill.name)" directory="\(skill.directory.path)">
        \(body)
        </skill>
        """
    }

    /// Ask the model to write a skill (optionally from a chat, or improving one).
    public func generateSkill(goal: String, from vm: SessionVM?, improving: String? = nil) async throws -> GeneratedSkill {
        guard let profile = await resolveRoute(vm) else { throw LLMError.noModel }
        if let vm, transcripts[vm.id] == nil { hydrate(vm) }
        let conversation = vm.flatMap { transcripts[$0.id] } ?? []
        let request = SkillGenerationRequest(goal: goal, conversation: conversation,
                                             existingNames: skills(for: vm).map(\.name), improving: improving)
        return try await SkillGenerator.generate(client: ProviderClients.make(profile),
                                                 model: profile.model, request: request)
    }

    /// `/skill new …`: write a skill from this chat and queue it for approval.
    private func generateSkillFromChat(_ vm: SessionVM, goal: String) async {
        vm.running = true
        vm.activity = "Writing a skill…"
        defer { vm.running = false; vm.activity = nil; runTasks[vm.id] = nil }
        do {
            let generated = try await generateSkill(goal: goal, from: vm)
            if Task.isCancelled { return }
            let scope: SkillScope = vm.workspaceURL != nil ? .project : .user
            let draft = try SkillDrafts.create(text: generated.text, scope: scope, projectRoot: vm.workspaceURL,
                                               source: "chat", locations: skillLocations)
            refreshDrafts()
            let warn = generated.issues.filter { $0.severity >= .warning }.map(\.message)
            vm.note("📝 Drafted skill **\(draft.name)** — \(draft.description)\nIt is not active yet: open **Skills** under the composer to review, edit and approve it."
                    + (warn.isEmpty ? "" : "\nNotes: " + warn.joined(separator: " ")))
        } catch {
            vm.note("Couldn't write the skill: \(Self.describe(error))", role: .error)
        }
    }

    // MARK: - Stopping

    public func stopSession(_ id: String, pauseTasks: Bool = true) {
        if let vm = sessions.first(where: { $0.id == id }), vm.running { vm.stopping = true }
        // Stop means "stop": what the chat has queued waits until Resume.
        if pauseTasks, queue.queuedChatTaskCount(id) > 0, chatTasksPaused[id] == nil {
            chatTasksPaused[id] = ChatTaskRules.pauseReason(for: .stopped)
        }
        resolveAllGates(for: id, with: false)
        // Out of line for the real mouse, and the controls back, for the chat and its subagents.
        Task { await ControlArbiter.shared.release(chatID: id) }
        runTasks[id]?.cancel()
        // Stop means everything the agent is doing in this chat.
        backgroundPools[id]?.stopAll()
    }

    public func stopAll() {
        stopQueue()
        for id in runTasks.keys { stopSession(id) }
        for pool in backgroundPools.values { pool.stopAll() }
    }

    /// Anything working — a turn, a queue task, or a background agent.
    public var anythingRunning: Bool {
        !runningSessions.isEmpty || sessions.contains { !$0.runningBackgroundJobs.isEmpty }
    }

    public func note(_ message: String) { banner = message }

    // MARK: - The fleet's routes

    /// How a route is named next to a subagent: the route's own name (e.g. "Spark 2").
    public static func routeLabel(_ route: ProviderProfile) -> String { AppConfig.routeLabel(route) }

    /// The routes subagents currently run on (see `AppConfig.workerRoutes`).
    public var workerRoutes: [ProviderProfile] { config.workerRoutes }

    // MARK: - Context window

    /// The active model's context budget, in tokens.
    ///
    /// Precedence: a user-set override in the provider config wins, then a
    /// value learned by probing the server, then the well-known model tables,
    /// then a conservative default. Read-only — the view calls this; side
    /// effects (the probe) live in `ensureContextProbe`, called from the
    /// session lifecycle, so evaluating a SwiftUI body never fires a request.
    @MainActor
    public func contextLimit() -> Int { contextLimit(for: selected) }

    /// The window of the model a chat uses.
    @MainActor
    public func contextLimit(for vm: SessionVM?) -> Int { contextLimit(route: chatRoute(vm)) }

    @MainActor
    public func contextLimit(route: ProviderProfile?) -> Int {
        guard let provider = route else { return FallbackContextWindow.defaultLimit }
        if let override = provider.contextWindow, override > 0 { return override }
        let learned: Int
        if let probed = probedContext[provider.routeID] {
            learned = probed
        } else {
            let model = effective(provider).model
            learned = FallbackContextWindow.limit(for: model) ?? FallbackContextWindow.defaultLimit
        }
        // The server said "too long" below the advertised window: believe it.
        if let ceiling = overflowCeiling[provider.routeID] { return min(learned, ceiling) }
        return learned
    }

    /// Where the current window figure came from, for `/context` and the gauge tooltip.
    @MainActor
    public func contextSource() -> String { contextSource(for: selected) }

    @MainActor
    public func contextSource(for vm: SessionVM?) -> String {
        guard let provider = chatRoute(vm) else { return "default" }
        if let override = provider.contextWindow, override > 0 { return "set manually in Settings" }
        if probedContext[provider.routeID] != nil { return "detected from the server" }
        if FallbackContextWindow.limit(for: effective(provider).model) != nil { return "from the built-in model table (server did not report one)" }
        return "a conservative default (server did not report one — set it in Settings)"
    }

    /// The model id actually in use for the selected chat's route (follows a swap).
    @MainActor
    public var activeModelID: String? { modelID(for: selected) }

    /// The profile with the model the server actually serves.
    @MainActor
    func effective(_ provider: ProviderProfile) -> ProviderProfile {
        var p = provider
        if let served = routeInfo[provider.routeID]?.servedModel, !served.isEmpty { p.model = served }
        return p
    }

    /// Ask the server what it serves and how big its window is, then return the
    /// profile to use. Cached for a few seconds so `/goal` rounds don't re-ask;
    /// a failed probe keeps whatever we knew.
    /// `vm` = the chat whose route to resolve; nil = the primary (the fleet's main server).
    @MainActor
    @discardableResult
    func resolveRoute(_ vm: SessionVM? = nil, force: Bool = false) async -> ProviderProfile? {
        guard let provider = vm.map({ chatRoute($0) }) ?? config.activeProvider else { return nil }
        let routeID = provider.routeID
        let fresh = routeInfo[routeID].map { Date().timeIntervalSince($0.at) < 15 } ?? false
        if force || !fresh {
            if let info = await ProviderClients.make(provider).modelInfo(nil), !info.servedModels.isEmpty {
                routeInfo[routeID] = RouteInfo(servedModel: info.id, servedModels: info.servedModels,
                                               context: info.contextWindow, at: .now)
                if let limit = info.contextWindow, limit > 0, probedContext[routeID] != limit {
                    probedContext[routeID] = limit
                }
            }
        }
        return effective(provider)
    }

    /// Between retries of a failed model call: ask the server again what it
    /// serves (a Spark swap changes the model id; the user may have fixed the
    /// provider in Settings). Returns a client for the new route when it
    /// differs from the one the session's engine was built with.
    @MainActor
    func rerouteForRetry(sessionID: String) async -> (client: any LLMClient, model: String)? {
        // The chat's own route: a retry never moves a chat onto the model another chat picked.
        let vm = sessions.first { $0.id == sessionID }
        guard let profile = await resolveRoute(vm, force: true) else { return nil }
        // Compare with the route the run is on now (a retry may have moved it).
        guard profile != (retryRoute[sessionID] ?? engineKeys[sessionID]?.profile) else { return nil }
        retryRoute[sessionID] = profile
        let unattended = vm.map(isUnattended) ?? false
        return (mainClient(profile, backups: backupProfiles(unattended: unattended, excluding: profile.routeID), sessionID: sessionID),
                profile.model)
    }

    // MARK: - Backups

    /// The routes that take over when the main model fails before answering, with their keys. Unattended work
    /// leaves out the ones whose plans allow interactive use only.
    func backupProfiles(unattended: Bool = false, excluding routeID: String? = nil) -> [ProviderProfile] {
        config.backupRoutes.filter { (!unattended || !$0.isInteractiveOnly) && $0.routeID != routeID }.map { route in
            var profile = route
            let key = config.apiKey(for: route)
            profile.apiKey = key.isEmpty ? nil : key
            return profile
        }
    }

    /// Whether a chat is doing unattended work: a queue task, a `/goal` that keeps going without the user, or
    /// carrying on by itself after its background agents finished.
    func isUnattended(_ vm: SessionVM) -> Bool {
        vm.goal != nil || queueSessions[vm.id] != nil || autoTurns.contains(vm.id)
    }

    /// A chat's client for the main model: with the backups, which take over a request the main model fails
    /// before it answers. A turn that ran on a backup says so in the chat (once per turn).
    func mainClient(_ profile: ProviderProfile, backups: [ProviderProfile], sessionID: String) -> any ProviderClient {
        ProviderClients.make(profile, backups: backups, events: ClientEvents(failover: { [weak self] notice in
            Task { @MainActor [weak self] in self?.noteFailover(notice, sessionID: sessionID) }
        }, shield: { [weak self] report in
            Task { @MainActor [weak self] in self?.noteMasked(report, sessionID: sessionID) }
        }, notice: { [weak self] text in
            Task { @MainActor [weak self] in self?.noteAdapted(text, sessionID: sessionID) }
        }))
    }

    /// A parameter the server refused was dropped (and remembered): one line in the chat, not an error.
    private func noteAdapted(_ text: String, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        vm.note(text)
        log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
    }

    /// For `/think`: what the chat's model makes of a level it doesn't offer ("" when it offers it).
    static func thinkingCaveat(_ level: ThinkingLevel, rules: ModelRequestRules?) -> String {
        guard let rules else { return "" }
        if rules.thinkingLevels.isEmpty {
            return rules.alwaysThinks ? " This model always thinks and takes no setting, so it changes nothing here." : " This model has no thinking setting."
        }
        guard let nearest = rules.nearestLevel(level), nearest != level else { return "" }
        return " This model offers \(rules.thinkingLevels.map { rules.label($0) }.joined(separator: ", ")), so it gets \(rules.label(nearest))."
    }

    /// The fleet's stand-in primary for a chat's subagents: that chat's own route, as its turns resolve it.
    @MainActor
    func resolveHomeTarget(sessionID: String) async throws -> FleetTarget {
        let vm = sessions.first { $0.id == sessionID }
        guard let profile = await resolveRoute(vm) else { throw LLMError.noModel }
        return FleetTarget(client: ProviderClients.make(profile), model: profile.model, contextWindow: contextLimit(route: profile),
                           vision: visionOn(for: profile), temperature: profile.temperature,
                           maxOutputTokens: profile.maxOutputTokens)
    }

    /// What the shield masked for a request in this chat: a chip on the turn's answer (and, the first time a
    /// picture or a file that isn't plain text goes to a model that isn't private, a word that those can't be
    /// checked).
    private func noteMasked(_ report: ShieldReport, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        if report.unchecked, !vm.toldAboutUnchecked {
            vm.toldAboutUnchecked = true
            let text = Self.uncheckedNotice
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        guard !report.isEmpty else { return }
        // Each request masks the whole conversation, so the newest report covers the earlier ones.
        if let answer = vm.currentAnswerID {
            vm.masked[answer] = report
            vm.pendingMask = nil
        } else {
            vm.pendingMask = report
        }
    }

    static let uncheckedNotice =
        "Pictures and files that aren't plain text are sent as they are — Vision can't check them for sensitive details."

    private func noteFailover(_ notice: FailoverNotice, sessionID: String) {
        guard !failoverNoticed.contains(sessionID), let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        failoverNoticed.insert(sessionID)
        vm.note(notice.text)
        log.recordItem(sessionID, kind: "notice", text: notice.text, toolName: nil, argSummary: nil, output: nil, isError: false)
    }

    /// Fire the server probe for the active route so `contextLimit` fills in a
    /// learned value. Safe to call repeatedly: one in flight at a time, and a
    /// recent answer is reused.
    @MainActor
    public func ensureContextProbe() {
        let vm = selected
        guard let provider = chatRoute(vm) else { return }
        let routeID = provider.routeID
        guard !probingContext.contains(routeID) else { return }
        if let info = routeInfo[routeID], Date().timeIntervalSince(info.at) < 60 { return }
        probingContext.insert(routeID)
        Task { [weak self] in
            await self?.resolveRoute(vm, force: true)
            self?.probingContext.remove(routeID)
        }
    }

    /// Forget cached probes (Settings changed the route, or the user asked).
    @MainActor
    public func resetRouteCache() {
        routeInfo.removeAll()
        resetWorkerProbes()
        probedContext.removeAll()
        overflowCeiling.removeAll()
        engines.removeAll()
        engineKeys.removeAll()
        ensureContextProbe()
    }

    /// How much of the context a session is using right now, in tokens.
    ///
    /// After any real turn this is the figure recorded at the end of that turn
    /// (server-reported prompt tokens when the model gives them, otherwise the
    /// character estimate of system prompt + transcript). The live draft adds
    /// on top, so the gauge tracks typing before the next send.
    @MainActor
    public func contextUsed(for sessionID: String, draft: String) -> Int {
        let recorded = sessions.first { $0.id == sessionID }?.contextUsed
        var used: Int
        if let recorded {
            used = recorded
        } else {
            // Fresh session: no turn has run, so estimate from the (empty)
            // transcript plus whatever the user is about to send. Use the
            // cached system prompt when the engine has been built; otherwise
            // the base prompt (project context is added at first turn).
            let prompt = systemPrompts[sessionID] ?? basePrompt
            used = Self.estimateTokens(systemPrompt: prompt,
                                       messages: transcripts[sessionID] ?? [])
        }
        // UTF-16 length, not `count`: this runs on every keystroke, and counting characters walks the whole draft.
        if draft.contains(where: { !$0.isWhitespace }) {
            used += max(1, draft.utf16.count / 4)
        }
        return used
    }

    /// Rough token count for a system prompt + message list.
    ///
    /// Character-based (≈ 4 chars/token) is the standard heuristic when the
    /// server won't report prompt tokens. It's a lower-ish bound for code and
    /// a good enough gauge for "how full is the context", which is all the UI
    /// needs — the exact figure arrives the moment a real turn runs.
    nonisolated static func estimateTokens(systemPrompt: String, messages: [LLMMessage]) -> Int {
        TokenEstimate.request(systemPrompt: systemPrompt, messages: messages)
    }

    // MARK: - Compaction
    //
    // When the model transcript grows toward the context window, the older
    // messages are replaced by a summary the model writes, and the recent tail
    // is kept verbatim. The engine calls this on every model call (in-loop), so
    // it also fires mid-run when tool output accumulates, and again on a server
    // overflow as a second line of defence.

    /// The engine's compaction hook: given the current request size and the full
    /// transcript, return a smaller transcript (older part summarized). No-op
    /// when under the trigger or when there's nothing old enough to fold.
    @MainActor
    public func compactTranscript(sessionID: String, used: Int, messages: [LLMMessage]) async -> [LLMMessage] {
        let limit = engineKeys[sessionID]?.window ?? contextLimit(for: sessions.first { $0.id == sessionID })
        guard let plan = Compaction.plan(usedTokens: used, limit: limit, transcript: messages) else {
            return messages
        }
        let vm = sessions.first { $0.id == sessionID }
        vm?.activity = "Compacting conversation to fit the context window…"
        defer { vm?.activity = nil }
        guard let summary = await summarize(sessionID: sessionID, plan: plan), !Task.isCancelled else {
            // No summarizer available (no client, or it failed): keep the
            // transcript as-is; the server may still accept it, and an overflow
            // is surfaced rather than silently dropped.
            return messages
        }
        let newMessages = [LLMMessage(role: .system, content: Compaction.summaryHeader + summary)] + plan.toKeep
        applyCompaction(sessionID: sessionID, plan: plan, summary: summary, newMessages: newMessages)
        return newMessages
    }

    /// Ask the model for a continuity summary of the older part of the conversation.
    ///
    /// The summary request must fit comfortably inside the same window it is
    /// meant to protect — `Compaction.summarize` budgets it at ~40% of the
    /// limit so the input (clipped transcript) + the summary output stay well
    /// under the trigger.
    @MainActor
    private func summarize(sessionID: String, plan: Compaction.Plan) async -> String? {
        let vm = sessions.first { $0.id == sessionID }
        await resolveRoute(vm)
        guard let profile = engineKeys[sessionID]?.profile ?? chatRoute(vm).map(effective) else { return nil }
        return await Compaction.summarize(client: ProviderClients.make(profile), plan: plan, model: profile.model)
    }

    /// Rewrite the session's display + persisted log so the summarized part is
    /// replaced by a compaction divider, and point the model transcript at the
    /// new (shorter) list.
    @MainActor
    private func applyCompaction(sessionID: String, plan: Compaction.Plan,
                                 summary: String, newMessages: [LLMMessage]) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        hydrate(vm)
        transcripts[sessionID] = newMessages
        // Reset the gauge: the model now carries a small context.
        let prompt = systemPrompts[sessionID] ?? basePrompt
        vm.contextUsed = TokenEstimate.request(systemPrompt: prompt, messages: newMessages)

        // The transcript's user messages map 1:1 onto the display's user
        // entries *since the last divider* (the transcript starts from that
        // divider's summary), so the cut is "the Nth+1 user entry after the
        // last divider", N = user messages summarized. The engine's own
        // "[Automatic message: images]" user messages have no display entry
        // and don't count. Counting (instead of matching text) keeps repeats
        // like "hi" from cutting at the wrong spot.
        let summarizedUsers = plan.toSummarize.count(where: { $0.role == .user && $0.imageSource == nil })
        let note = CompactionNote(removed: plan.toSummarize.count, summary: summary)
        let start = (vm.entries.lastIndex { $0.compaction != nil }).map { $0 + 1 } ?? 0
        var seenUsers = 0
        var cut: Int? = nil
        for i in start..<vm.entries.count {
            if case .message(let body) = vm.entries[i].kind, body.role == .user {
                if seenUsers == summarizedUsers { cut = i; break }
                seenUsers += 1
            }
        }
        // Earlier messages stay visible above the divider (replay starts from
        // the divider, so they are not sent to the model again). A cut inside
        // one long turn has no later user entry: the divider goes at the end.
        let marker = ChatEntry(kind: .compaction(note))
        vm.entries.insert(marker, at: cut ?? vm.entries.count)
        // Re-sync the persisted log so a restart reloads the compacted conversation.
        if vm.loaded { log.resync(sessionID, rows: Self.logRows(for: vm.entries, sessionID: sessionID)) }
    }

    /// Rebuild persisted log rows from the current display entries. This is the
    /// single place that turns a (possibly compacted) session into storage.
    static func logRows(for entries: [ChatEntry], sessionID: String) -> [LogItemRow] {
        var out: [LogItemRow] = []
        var seq = 0
        for entry in entries {
            let (kind, text, toolName, argSummary, output, isError) = logRowFields(for: entry)
            let badges = entry.message?.attachments ?? []
            out.append(LogItemRow(sessionID: sessionID, seq: seq, kind: kind, text: text,
                                  toolName: toolName, argSummary: argSummary, output: output,
                                  isError: isError, at: entry.at, attachments: badges.isEmpty ? nil : badges))
            seq += 1
        }
        return out
    }

    /// Map one display entry to its persisted-row fields.
    private static func logRowFields(for entry: ChatEntry)
        -> (kind: String, text: String?, toolName: String?, argSummary: String?, output: String?, isError: Bool) {
        switch entry.kind {
        case .message(let body):
            switch body.role {
            case .user: return ("user", body.text, nil, nil, nil, false)
            case .assistant: return ("assistant", body.text, nil, nil, nil, false)
            case .notice: return ("notice", body.text, nil, nil, nil, false)
            case .error: return ("error", body.text, nil, nil, nil, true)
            }
        case .tool(let a):
            return ("tool", a.summary, a.name, a.preview, a.output, a.isOk == false)
        case .todos:
            return ("todos", nil, nil, nil, nil, false)
        case .compaction(let note):
            // The removed count rides in argSummary so a reloaded divider still
            // says how much was folded away.
            return ("compaction", note.summary, "compaction", String(note.removed), nil, false)
        }
    }

    public static func describe(_ error: Error) -> String {
        if let llm = error as? LLMError {
            return llm.errorDescription ?? "\(llm)"
        }
        return error.localizedDescription
    }
}