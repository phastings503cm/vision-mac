import Foundation
import VisionHarnessCore

// MARK: - Prompts timeline, chat tasks, background activity
//
// Three things the person asked to see and steer:
//  * the Prompts timeline — every prompt a chat sent and how it ended, kept on disk per chat
//  * the chat's tasks — what it is doing now (the running turn's or /goal's plan, always first) and the prompts queued
//    after it with "Add to tasks", which start by themselves, in order, as the chat comes free
//  * background activity — everything working right now, on which model and server, assigned to what

extension AppTransport {
    // MARK: Prompts timeline

    /// Read a chat's timeline from disk once (or backfill it from the transcript for a chat from before the
    /// timeline). A prompt a previous launch left "running" didn't finish.
    func loadPromptHistory(_ vm: SessionVM) {
        guard !vm.promptHistoryLoaded, vm.loaded else { return }
        vm.promptHistoryLoaded = true
        let begunEarlier = vm.promptHistory
        var records: [PromptRecord]
        if let stored = promptStore.load(vm.id) {
            records = stored
        } else {
            records = PromptTimeline.backfill(chatID: vm.id, rows: Self.timelineRows(vm.entries))
            if !records.isEmpty { promptStore.save(vm.id, records) }
        }
        var repaired = false
        for index in records.indices where records[index].outcome == .running && records[index].id != vm.currentPromptID {
            records[index].outcome = .stopped
            records[index].reason = "\(AppIdentity.name) quit before it finished."
            repaired = true
        }
        for record in begunEarlier where !records.contains(where: { $0.id == record.id }) { records.append(record) }
        vm.promptHistory = records.sorted { $0.at < $1.at }
        if repaired { savePrompts(vm) }
    }

    /// The transcript as the backfill reads it.
    static func timelineRows(_ entries: [ChatEntry]) -> [PromptTimeline.Row] {
        entries.compactMap { entry in
            switch entry.kind {
            case .message(let body):
                return PromptTimeline.Row(kind: body.role.rawValue, text: body.text, at: entry.at)
            case .tool(let tool):
                return PromptTimeline.Row(kind: "tool", text: tool.summary ?? tool.name, at: entry.at)
            case .compaction(let note):
                return PromptTimeline.Row(kind: "compaction", text: note.summary, at: entry.at)
            case .todos:
                return nil
            }
        }
    }

    func savePrompts(_ vm: SessionVM) {
        promptStore.save(vm.id, vm.promptHistory)
    }

    /// A prompt started working: its row goes in the timeline as Running.
    @discardableResult
    func beginPrompt(_ vm: SessionVM, text: String, source: PromptRecord.Source) -> String {
        if !vm.loaded { hydrate(vm) } else { loadPromptHistory(vm) }
        var source = source
        var taskID: String?
        if let pending = pendingPromptSource.removeValue(forKey: vm.id) {
            taskID = pending.taskID
            if source != .goal { source = pending.source }
        }
        // A prompt still open (the app was busy elsewhere when it ended) can't stay Running behind a new one.
        if let open = vm.currentPromptID, vm.promptHistory.contains(where: { $0.id == open && $0.outcome == .running }) {
            finishPrompt(vm, outcome: .unknown, reason: nil)
        }
        vm.turnPromptTokens = 0
        vm.turnCompletionTokens = 0
        var record = PromptRecord(chatID: vm.id, text: text, source: source, at: Date(), outcome: .running,
                                  taskKind: vm.turnPhase?.taskKind?.rawValue, turnID: vm.turnPhase?.turnID)
        // The chat's own model (each chat keeps its own), not whatever is primary right now.
        if let route = chatRoute(vm) {
            record.route = Self.routeLabel(route)
            record.model = effective(route).model
        }
        vm.promptHistory.append(record)
        vm.currentPromptID = record.id
        if let taskID { chatTaskRecord[taskID] = record.id }
        savePrompts(vm)
        guardianSync?(record, vm.id)
        return record.id
    }

    /// The prompt's row landed in the transcript: remember it, so "Jump" finds it after a relaunch too.
    func promptEntryLanded(_ vm: SessionVM, entryID: String, displayText: String) {
        guard let id = vm.currentPromptID, let index = vm.promptHistory.lastIndex(where: { $0.id == id }),
              vm.promptHistory[index].entryText == nil else { return }
        vm.promptHistory[index].entryText = displayText
        vm.promptHistory[index].entryAt = vm.entries.last(where: { $0.id == entryID })?.at ?? Date()
        savePrompts(vm)
    }

    /// Planning settled: the estimate and the kind go on the row.
    func promptPlanned(_ vm: SessionVM, state: TurnPhaseState) {
        guard let id = vm.currentPromptID, let index = vm.promptHistory.lastIndex(where: { $0.id == id }) else { return }
        vm.promptHistory[index].etaSeconds = state.etaSeconds
        vm.promptHistory[index].taskKind = state.taskKind?.rawValue
        if vm.promptHistory[index].turnID == nil { vm.promptHistory[index].turnID = state.turnID }
    }

    /// A goal moved on to its next round.
    func promptRound(_ vm: SessionVM, round: Int) {
        guard let id = vm.currentPromptID, let index = vm.promptHistory.lastIndex(where: { $0.id == id }) else { return }
        vm.promptHistory[index].rounds = round
    }

    /// The prompt is over: how it ended, how long it took against the estimate, the attempts, the evidence and the
    /// results note, what it ran on and what it used. Idempotent.
    func finishPrompt(_ vm: SessionVM, outcome: PromptRecord.Outcome, reason: String?) {
        guard let id = vm.currentPromptID else { return }
        vm.currentPromptID = nil
        guard let index = vm.promptHistory.lastIndex(where: { $0.id == id }),
              vm.promptHistory[index].outcome == .running else { return }
        var record = vm.promptHistory[index]
        record.outcome = outcome
        record.finishedAt = Date()
        if let reason, outcome != .completed { record.reason = String(reason.prefix(600)) }
        if let state = vm.turnPhase, record.turnID == nil || record.turnID == state.turnID {
            record.turnID = state.turnID
            record.etaSeconds = state.etaSeconds ?? record.etaSeconds
            record.taskKind = state.taskKind?.rawValue ?? record.taskKind
            record.attempts = state.loopbacks + 1
            // The timeline keeps the gist of the evidence (the turn's card has it all): a long chat's file stays small.
            record.evidence = state.evidence.suffix(8).map { item in
                var item = item
                if item.detail.count > 400 { item.detail = String(item.detail.prefix(399)) + "…" }
                return item
            }
        }
        var notes: [String] = []
        if let state = vm.turnPhase, state.turnID == record.turnID, state.phase == .results,
           let line = state.steps.last?.text { notes.append(line) }
        if let closing = closingSummary(vm, after: record) { notes.append(closing) }
        if !notes.isEmpty { record.completionNote = notes.joined(separator: "\n\n") }
        record.promptTokens = vm.turnPromptTokens
        record.completionTokens = vm.turnCompletionTokens
        if let use = turnRoute[vm.id] {
            record.model = use.model
            record.route = use.route
        }
        vm.promptHistory[index] = record
        savePrompts(vm)
        guardianSync?(record, vm.id)
    }

    /// The model's last answer after the prompt's row — its closing summary.
    private func closingSummary(_ vm: SessionVM, after record: PromptRecord) -> String? {
        let start = record.entryAt ?? record.at
        guard let answer = vm.entries.last(where: { $0.message?.role == .assistant && $0.at >= start.addingTimeInterval(-1) })?
            .message?.text.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
        return String(answer.prefix(600))
    }

    /// The transcript row a timeline record points at, in a loaded chat.
    func entryID(for record: PromptRecord, in vm: SessionVM) -> String? {
        let candidates = vm.entries.compactMap { entry -> PromptTimeline.EntryRef? in
            guard case .message(let body) = entry.kind, body.role == .user else { return nil }
            return PromptTimeline.EntryRef(id: entry.id, text: body.text, at: entry.at)
        }
        return PromptTimeline.matchEntry(record, in: candidates)
    }

    /// Every chat's timeline, for the All Prompts view: the loaded ones as they are, the others read from disk —
    /// and a chat that has never had a timeline file is backfilled from its stored transcript (once; the file is
    /// written so it never has to be again).
    func allPromptRecords() -> [PromptRecord] {
        var out: [PromptRecord] = []
        for vm in sessions {
            if vm.promptHistoryLoaded {
                out += vm.promptHistory
            } else if let stored = promptStore.load(vm.id) {
                out += stored
            } else {
                let rows = log.peekItems(vm.id).map { PromptTimeline.Row(kind: $0.kind, text: $0.text ?? "", at: $0.at) }
                let records = PromptTimeline.backfill(chatID: vm.id, rows: rows)
                if !records.isEmpty { promptStore.save(vm.id, records) }
                out += records
            }
        }
        return out
    }

    // MARK: Chat tasks

    /// Queue `text` as this chat's next task: it runs here, as the chat's next prompt, once everything before it is
    /// done — right away when the chat is free and its list isn't paused.
    @discardableResult
    /// `attachments`: the composer's chips (files, pictures, a large paste) — kept with the task in the chat's
    /// attachments folder and sent with the prompt when its turn comes, read and split exactly as a fresh send.
    public func addChatTask(_ text: String, sessionID: String, atFront: Bool = false,
                            attachments: [MessageAttachment] = []) -> QueueTask? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, let vm = sessions.first(where: { $0.id == sessionID }) else { return nil }
        // Only a /goal takes attachments (it carries them into its first round); any other command is refused now,
        // not when its turn comes.
        if !attachments.isEmpty, let why = Self.commandAttachmentRefusal(trimmed) {
            vm.note(why, role: .error)
            return nil
        }
        let kept: [QueuedAttachment]
        do {
            kept = try attachmentStore(for: sessionID).saveQueued(attachments)
        } catch {
            vm.note("Couldn't keep the attachments for the task list: \(error.localizedDescription)", role: .error)
            return nil
        }
        let folder = vm.isPlain ? scratchFolder(for: vm).path : nil
        let task = queue.addChatTask(trimmed, chatID: sessionID, atFront: atFront, cwd: vm.cwd, workFolder: folder,
                                     attachments: kept)
        if !kept.isEmpty {
            vm.note("📋 Added to this chat's tasks — it starts by itself when the work before it is done. "
                    + ChatTaskRules.carriesNotice(kept.count))
        }
        schedulePump(vm)
        return queue.task(task.id) ?? task
    }

    /// Take a chat task off the list. The one running is stopped, and the next one starts (removing it is not a
    /// Stop of the whole list).
    public func removeChatTask(_ id: String) {
        guard let task = queue.task(id), let chatID = task.chatID else { return }
        let running = task.status == .running
        queue.remove(id: id)
        // What a deleted task kept goes with it (a running one stays as a skipped record, and keeps them until then).
        if queue.task(id) == nil, let kept = task.attachments, !kept.isEmpty {
            attachmentStore(for: chatID).removeQueued(kept)
        }
        if running { stopSession(chatID, pauseTasks: false) }
    }

    /// Move a waiting chat task up (negative) or down.
    public func moveChatTask(_ id: String, by offset: Int) { queue.moveWithinChat(id: id, by: offset) }

    /// Drop a waiting chat task in another's place (drag and drop within one chat).
    public func moveChatTask(_ id: String, onto target: String) {
        guard let a = queue.task(id), let b = queue.task(target), a.chatID != nil, a.chatID == b.chatID else { return }
        queue.move(id: id, onto: target)
    }

    /// Make a waiting chat task the next to run.
    public func queueMoveChatTaskToFront(_ id: String) {
        guard let task = queue.task(id), let chatID = task.chatID,
              let first = queue.chatTasks(chatID).first(where: { $0.status == .queued }), first.id != id else { return }
        queue.move(id: id, onto: first.id)
    }

    /// Change a waiting chat task's prompt.
    public func editChatTask(_ id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, queue.task(id)?.status == .queued else { return }
        let first = trimmed.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        queue.update(id: id, title: String(first.prefix(80)), details: trimmed)
    }

    /// Run a finished (failed, stopped, needs-you) chat task again: back to the front of the chat's list.
    public func retryChatTask(_ id: String) {
        guard let task = queue.task(id), let chatID = task.chatID, task.status != .running, task.status != .queued else { return }
        queue.requeue(id, toFront: true)
        chatTasksPaused[chatID] = nil
        if let vm = sessions.first(where: { $0.id == chatID }) { schedulePump(vm) }
    }

    /// Carry on with a paused list.
    public func resumeChatTasks(_ sessionID: String) {
        chatTasksPaused[sessionID] = nil
        if let vm = sessions.first(where: { $0.id == sessionID }) { schedulePump(vm) }
    }

    /// Hold the list: the current work finishes, nothing new starts until Resume.
    public func pauseChatTasks(_ sessionID: String) {
        chatTasksPaused[sessionID] = "Paused — nothing new starts until you resume."
    }

    /// Clear the chat's finished tasks from its list.
    public func clearFinishedChatTasks(_ sessionID: String) {
        for task in queue.chatTasks(sessionID) where task.status != .queued && task.status != .running {
            queue.remove(id: task.id)
            // What it kept (a 10,000-line paste) goes with it.
            if queue.task(task.id) == nil, let kept = task.attachments, !kept.isEmpty {
                attachmentStore(for: sessionID).removeQueued(kept)
            }
        }
    }

    /// Some work in a chat ended (a turn, a goal, a queue task): what the chat has queued may start, or — after a
    /// Stop, a failure, a goal that needs the person — wait.
    func afterWork(_ vm: SessionVM, outcome: PromptRecord.Outcome) {
        // A chat task's own turn: the task's watcher settles it (and starts the next).
        if chatTaskInFlight[vm.id] != nil { return }
        if !ChatTaskRules.continuesAfter(outcome) {
            if queue.queuedChatTaskCount(vm.id) > 0, chatTasksPaused[vm.id] == nil {
                chatTasksPaused[vm.id] = ChatTaskRules.pauseReason(for: outcome)
            }
            return
        }
        schedulePump(vm)
    }

    /// Look for the chat's next task once the current change has settled.
    func schedulePump(_ vm: SessionVM) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.pumpChatTasks(vm)
        }
    }

    /// Whether the chat is free to start its next task.
    func chatIsFreeForTask(_ vm: SessionVM) -> Bool {
        sessions.contains(where: { $0 === vm }) && !vm.running && runTasks[vm.id] == nil
            && queueSessions[vm.id] == nil && chatTaskInFlight[vm.id] == nil && chatTasksPaused[vm.id] == nil
            && vm.runningBackgroundJobs.isEmpty && vm.pendingGates.isEmpty
            && !chatServerSwitching(vm) && config.isConfigured
    }

    /// What a send says while the chat's model server switches models.
    static let switchingNote = "This chat's model server is switching models right now — send again once it says it's ready."

    /// Whether the box behind this chat's own model is switching models (each chat has its own model, so another
    /// chat's box switching doesn't hold this one up).
    func chatServerSwitching(_ vm: SessionVM) -> Bool {
        if let route = chatRoute(vm), let isRouteSwitching { return isRouteSwitching(route) }
        return isServerSwitching?() == true
    }

    /// A model server finished switching: chats with tasks waiting start the next one (each waits on its own box).
    func serverSwitchFinished() {
        for vm in sessions where queue.queuedChatTaskCount(vm.id) > 0 { schedulePump(vm) }
    }

    /// Start the chat's next waiting task, if it is free: sent exactly as if the person sent it now (a `/goal`, a
    /// skill or a plain prompt), with its own row in the Prompts timeline.
    func pumpChatTasks(_ vm: SessionVM) {
        guard chatIsFreeForTask(vm), let next = queue.nextChatTask(vm.id) else { return }
        // What it was queued with goes with it, read again as when it was attached.
        var attachments: [MessageAttachment] = []
        if let kept = next.attachments, !kept.isEmpty {
            switch attachmentStore(for: vm.id).loadQueued(kept) {
            case .success(let loaded):
                attachments = loaded
            case .failure(let missing):
                queue.start(next.id, sessionID: vm.id)
                queue.finish(next.id, status: .failed, reason: ChatTaskRules.missingAttachmentReason(missing.name), sessionID: vm.id)
                if queue.queuedChatTaskCount(vm.id) > 0, chatTasksPaused[vm.id] == nil {
                    chatTasksPaused[vm.id] = ChatTaskRules.pauseReason(for: .failed)
                }
                vm.note("The task “\(next.title)” can't run: \(ChatTaskRules.missingAttachmentReason(missing.name)).", role: .error)
                return
            }
        }
        queue.start(next.id, sessionID: vm.id)
        chatTaskInFlight[vm.id] = next.id
        pendingPromptSource[vm.id] = (.task, next.id)
        autoContinuations[vm.id] = 0
        dispatch(next.promptText, vm: vm, attachments: attachments)
        let started = runTasks[vm.id]
        let taskID = next.id
        Task { @MainActor [weak self] in
            await started?.value
            self?.settleChatTask(vm, taskID: taskID)
        }
    }

    /// A chat task's work is over: mark it from how its prompt ended, then start the next one or pause.
    func settleChatTask(_ vm: SessionVM, taskID: String) {
        chatTaskInFlight[vm.id] = nil
        pendingPromptSource[vm.id] = nil
        let record = chatTaskRecord.removeValue(forKey: taskID).flatMap { id in vm.promptHistory.last { $0.id == id } }
        // A command (`/help`, `/think high`) has no prompt row: it simply ran.
        let outcome = record?.outcome ?? .completed
        if queue.task(taskID)?.status == .running {
            queue.finish(taskID, status: ChatTaskRules.status(for: outcome), reason: record?.reason, sessionID: vm.id)
        } else if queue.task(taskID) == nil || queue.task(taskID)?.status == .skipped {
            // Taken off the list while it ran: the next one goes.
            schedulePump(vm)
            return
        }
        if ChatTaskRules.continuesAfter(outcome) {
            schedulePump(vm)
        } else if queue.queuedChatTaskCount(vm.id) > 0, chatTasksPaused[vm.id] == nil {
            chatTasksPaused[vm.id] = ChatTaskRules.pauseReason(for: outcome)
        }
    }

    // MARK: What the chat is doing now (its first task)

    /// The chat's current work, shown as the first task: the running goal, chat task, queue task or prompt, with its
    /// plan steps. Nil when the chat is idle.
    func currentWork(for vm: SessionVM) -> CurrentWork? {
        guard vm.running || runTasks[vm.id] != nil || queueSessions[vm.id] != nil else { return nil }
        let record = vm.currentPrompt
        let title: String
        let kind: String
        if let goal = vm.goal, record?.source != .queue, queueSessions[vm.id] == nil {
            title = goal.text
            kind = record?.source == .task ? "Task · goal" : "Goal"
        } else if let taskID = queueSessions[vm.id], let task = queue.task(taskID) {
            title = task.title
            kind = "Queue task"
        } else if let taskID = chatTaskInFlight[vm.id], let task = queue.task(taskID) {
            title = task.promptText
            kind = "Task"
        } else if let record {
            title = record.text
            kind = record.source.label
        } else {
            title = vm.activity ?? "Working…"
            kind = "Working"
        }
        return CurrentWork(title: title, kind: kind, startedAt: record?.at ?? vm.goal?.started ?? Date(),
                           round: vm.goal?.round, phase: vm.turnPhase, steps: vm.todos)
    }

    // MARK: Background activity

    /// Everything working right now, across chats: each chat's main agent, its subagents (foreground and
    /// background), the unattended queue, and the chats with tasks waiting — each with the model and server it runs
    /// on, what it was given, how long it has run, and what it used.
    func activityItems(now: Date = Date()) -> [ActivityItem] {
        var items: [ActivityItem] = []
        for vm in sessions {
            let chatTitle = vm.title
            if vm.running {
                let use = turnRoute[vm.id]
                let work = currentWork(for: vm)
                items.append(ActivityItem(
                    id: "main-\(vm.id)", kind: .mainAgent, chatID: vm.id, chatTitle: chatTitle,
                    title: "Main agent", assignment: work.map { "\($0.kind): \($0.title)" },
                    placement: use.map { "\($0.model) on \($0.route)" } ?? chatRoute(vm).map { "\(effective($0).model) on \(Self.routeLabel($0))" },
                    status: vm.stopping ? "Stopping…" : (vm.turnPhase.map { $0.isOver ? "Finishing" : $0.phase.label } ?? "Working")
                        + (vm.goal.map { " · round \($0.round)" } ?? ""),
                    activity: vm.runningTool.map { "\(Theme.toolLabel($0.name).lowercased()) \($0.preview)" } ?? vm.activity,
                    startedAt: work?.startedAt, running: true,
                    tokens: vm.turnPromptTokens + vm.turnCompletionTokens, steps: vm.turnPhase?.steps.count))
            }
            for run in vm.agentRuns where run.isRunning {
                items.append(ActivityItem(
                    id: "agent-\(vm.id)-\(run.id)", kind: run.isBackground ? .backgroundAgent : .subagent,
                    chatID: vm.id, chatTitle: chatTitle, title: "\(run.description) (\(run.agentType))",
                    assignment: run.assignment.map { "Plan step: \($0)" },
                    placement: run.placementLabel ?? "waiting for a model server",
                    status: Self.runStatus(run),
                    activity: run.activity, startedAt: run.startedAt, running: true,
                    tokens: run.promptTokens + run.completionTokens, steps: run.steps, agentRunID: run.id))
            }
            // A background job the roster doesn't know (shouldn't happen, but never hide work).
            for job in vm.runningBackgroundJobs where !vm.agentRuns.contains(where: { $0.isRunning && $0.isBackground && $0.description == job.description }) {
                items.append(ActivityItem(id: "job-\(vm.id)-\(job.id)", kind: .backgroundAgent, chatID: vm.id,
                                          chatTitle: chatTitle, title: job.description, assignment: nil, placement: nil,
                                          status: "Running", activity: nil, startedAt: job.startedAt, running: true,
                                          backgroundJobID: job.id))
            }
            let waiting = queue.queuedChatTaskCount(vm.id)
            if waiting > 0 {
                let next = queue.nextChatTask(vm.id)
                items.append(ActivityItem(
                    id: "tasks-\(vm.id)", kind: .chatTasks, chatID: vm.id, chatTitle: chatTitle,
                    title: "\(waiting) task\(waiting == 1 ? "" : "s") up next", assignment: next.map { "Next: \($0.title)" },
                    placement: nil, status: chatTasksPaused[vm.id] ?? "Starts when the current work finishes",
                    activity: nil, startedAt: nil, running: false))
            }
        }
        if queueRunning || queueStopping {
            let active = queueActiveTaskID.flatMap { queue.task($0) }
            items.append(ActivityItem(
                id: "queue", kind: .queueRunner, chatID: active?.sessionID, chatTitle: "Task queue",
                title: "Unattended task queue", assignment: active.map { "Working: \($0.title)" },
                placement: (active?.routeID.flatMap { config.usableRoute($0) } ?? config.activeProvider)
                    .map { "\(effective($0).model) on \(Self.routeLabel($0))" },
                status: queueStopping ? "Stopping…" : "\(queue.queuedCount) waiting", activity: nil,
                startedAt: active?.startedAt, running: true, tokens: active.map(\.totalTokens), steps: active?.rounds))
        }
        return items
    }

    /// A subagent's status line: how its server was chosen ("Running · picked by the primary", "Running · least busy",
    /// "Running · fallback — spark-2 stayed busy for 2 minutes").
    static func runStatus(_ run: AgentRun) -> String {
        if let label = SubagentPlacement.Reason.label(run.placementReason) {
            return "Running · " + label + (run.placement.map { " — \($0)" } ?? "")
        }
        return run.placement.map { "Running · \($0)" } ?? "Running"
    }

    /// How many things are working now (the toolbar's count): main agents, subagents and the queue runner.
    var activityCount: Int {
        var count = 0
        for vm in sessions {
            if vm.running { count += 1 }
            count += vm.agentRuns.count(where: \.isRunning)
        }
        if queueRunning { count += 1 }
        return count
    }

    /// Stop one item of the activity list.
    func stopActivity(_ item: ActivityItem) {
        switch item.kind {
        case .mainAgent:
            if let chatID = item.chatID { stopSession(chatID) }
        case .backgroundAgent:
            guard let chatID = item.chatID else { return }
            if let jobID = item.backgroundJobID {
                stopBackgroundAgent(sessionID: chatID, id: jobID)
            } else if let vm = sessions.first(where: { $0.id == chatID }),
                      let run = vm.agentRuns.first(where: { $0.id == item.agentRunID }),
                      let job = vm.runningBackgroundJobs.first(where: { $0.description == run.description }) {
                stopBackgroundAgent(sessionID: chatID, id: job.id)
            }
        case .subagent:
            // A foreground subagent belongs to its parent's tool call: stopping it stops the turn.
            if let chatID = item.chatID { stopSession(chatID) }
        case .queueRunner:
            stopQueue()
        case .chatTasks:
            if let chatID = item.chatID { pauseChatTasks(chatID) }
        }
    }
}

/// What a chat is doing now — its first task.
struct CurrentWork: Hashable {
    var title: String
    /// "Goal", "Task", "Queue task", "Prompt", "Skill".
    var kind: String
    var startedAt: Date
    var round: Int?
    var phase: TurnPhaseState?
    var steps: [TodoItem]
}

/// One line of the background activity menu.
struct ActivityItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case mainAgent, subagent, backgroundAgent, queueRunner, chatTasks
    }
    var id: String
    var kind: Kind
    var chatID: String?
    var chatTitle: String
    var title: String
    /// What it was given: the plan step, the prompt, the task.
    var assignment: String?
    /// "Qwen3-Coder-30B on DGX Spark".
    var placement: String?
    var status: String
    /// What it is doing this moment ("grep: TODO").
    var activity: String?
    var startedAt: Date?
    var running: Bool
    var tokens: Int?
    var steps: Int?
    var agentRunID: String?
    var backgroundJobID: String?

    var symbol: String {
        switch kind {
        case .mainAgent: "sparkle"
        case .subagent: "person.2"
        case .backgroundAgent: "moon.stars"
        case .queueRunner: "list.bullet.rectangle"
        case .chatTasks: "text.badge.plus"
        }
    }

    var canStop: Bool { kind != .chatTasks || running }
}
