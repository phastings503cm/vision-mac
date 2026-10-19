import Foundation
import Observation
import VisionHarnessCore

/// A chat message in the transcript.
public struct MessageBody: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case user, assistant, notice, error }
    public var role: Role
    public var text: String
    /// What a user message carried (files, pictures, large pastes), shown as badges under it.
    public var attachments: [AttachmentBadge]

    public init(role: Role, text: String, attachments: [AttachmentBadge] = []) {
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}

/// One tool call, from "started" through to its result.
public struct ToolActivity: Hashable, Sendable {
    public var name: String
    /// The interesting argument — a path, a command, a pattern.
    public var preview: String
    /// One-line headline of the result.
    public var summary: String?
    /// The full result, revealed on demand.
    public var output: String?
    /// nil while the call is still running.
    public var isOk: Bool?
    /// What the tool captured (screenshots, frames), as encoded images. Kept
    /// in memory for the live session only — logs store just the text.
    public var images: [Data]

    public var isFinished: Bool { isOk != nil }

    public init(name: String, preview: String, summary: String? = nil,
                output: String? = nil, isOk: Bool? = nil, images: [Data] = []) {
        self.name = name
        self.preview = preview
        self.summary = summary
        self.output = output
        self.isOk = isOk
        self.images = images
    }
}

/// A record that the older part of a conversation was summarized to fit the
/// model's context window. Rendered as a divider in the transcript.
public struct CompactionNote: Hashable, Sendable {
    /// How many earlier messages were folded into this summary.
    public var removed: Int
    /// The summary the model now carries in place of those messages.
    public var summary: String
    public var at: Date

    public init(removed: Int, summary: String, at: Date = .now) {
        self.removed = removed
        self.summary = summary
        self.at = at
    }
}

/// One row of the transcript.
///
/// Messages, tool calls, todo snapshots, and compaction markers share one
/// ordered list so a tool call renders exactly where it happened — between the
/// assistant text that preceded it and the text that followed.
public struct ChatEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case message(MessageBody)
        case tool(ToolActivity)
        case todos([TodoItem])
        case compaction(CompactionNote)
    }

    public let id: String
    public var at: Date
    public var kind: Kind

    public init(id: String = UUID().uuidString, at: Date = .now, kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }

    public var message: MessageBody? {
        if case .message(let body) = kind { return body }
        return nil
    }

    public var tool: ToolActivity? {
        if case .tool(let activity) = kind { return activity }
        return nil
    }

    public var compaction: CompactionNote? {
        if case .compaction(let note) = kind { return note }
        return nil
    }
}

/// A pending permission question surfaced by the engine.
public struct GateVM: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// Observable state for one agent session, driven by `AppTransport`.
@MainActor
@Observable
public final class SessionVM: Identifiable {
    public let id: String
    public var title: String
    public var cwd: String?
    public var updatedAt: Date
    /// Pinned when the session is created, like the preset a chat runs under.
    public var preset: PermissionPreset

    public var entries: [ChatEntry] = []
    /// False while the stored timeline hasn't been read into `entries` (a chat
    /// from a previous launch, or an archived queue chat whose timeline was
    /// released). `AppTransport.hydrate` loads it; nothing may resync a chat
    /// to disk until it is loaded.
    public var loaded = true
    public var pendingGates: [GateVM] = []
    public var todos: [TodoItem] = []
    public var lastUsage: LLMUsage?
    /// Best-known size of the current context, in tokens. Server-reported when
    /// the model gives prompt tokens, otherwise a character-based estimate.
    public var contextUsed: Int?
    /// Files this session's tools touched, newest first — shown as chips.
    public var changedFiles: [FileChange] = []

    public var running: Bool = false
    public var stopping: Bool = false

    /// This chat's thinking level; nil = the provider's default.
    public var thinking: ThinkingLevel?
    /// The route (`ProviderProfile.routeID`) this chat talks to — its own, stored with the conversation (see
    /// `ChatRoutes.swift`). Nil = not chosen yet: it takes the primary when it next sends.
    public var routeID: String?
    /// The model's live reasoning for the current step (not persisted).
    public var reasoning: String = ""
    public var reasoningStarted: Date?
    /// A transient status line ("Compacting conversation…") shown while busy.
    public var activity: String?
    /// The active `/goal`, while its loop runs.
    public var goal: GoalState?
    /// Set while a model call is being retried (server down, timed out, busy).
    public var retry: RetryState?
    /// Background subagents this chat launched (running and finished).
    public var backgroundJobs: [BackgroundAgents.Job] = []
    /// Every subagent this chat started — waiting for a server, working, finished — and which model
    /// server each runs on, so the bar above the composer can show who is doing what, and where.
    public var agentRuns: [AgentRun] = []
    public var runningAgentRuns: [AgentRun] { agentRuns.filter(\.isRunning) }

    /// A run started, moved or ended: add it or replace it (the roster keeps them in start order).
    public func upsertAgent(_ run: AgentRun) {
        if let index = agentRuns.firstIndex(where: { $0.id == run.id }) {
            agentRuns[index] = merged(run, over: agentRuns[index])
        } else if !run.id.isEmpty {
            agentRuns.append(run)
        }
        // Bounded: the oldest finished runs go first.
        if agentRuns.count > 60, let old = agentRuns.firstIndex(where: { !$0.isRunning }) { agentRuns.remove(at: old) }
    }
    public var runningBackgroundJobs: [BackgroundAgents.Job] { backgroundJobs.filter { $0.status == .running } }
    /// The last `/goal` started in this chat and not yet completed; a bare
    /// `/goal` resumes it.
    public var lastGoal: String?
    /// What the sensitive-data shield masked before sending, by the assistant entry it belongs to (a chip on that
    /// turn). Counts only — never the values.
    public var masked: [String: ShieldReport] = [:]
    /// A report that came before the turn's answer did (a request that only called tools).
    public var pendingMask: ShieldReport?
    /// The chat was told that pictures and files that aren't plain text can't be checked.
    public var toldAboutUnchecked = false
    /// The plan a plan-mode run handed to `exit_plan_mode` (shown in the plan panel).
    public var proposedPlan: String?
    /// The plan panel already opened by itself for this chat (it does that only the first time).
    public var planAutoOpened = false

    /// The turn-phase machinery: Planning → Execution → Validation → Results, with the live draft,
    /// the ETA and the evidence. Reset per turn; kept for the last turn so the results card stays.
    public var turnPhase: TurnPhaseState?
    /// Whether the phases run at all for this chat (off: a plain question gets no ceremony).
    public var phasesEnabled = true

    /// The prompts sent in this chat, oldest first, with how each ended — the Prompts timeline. Read from (and saved
    /// to) the chat's timeline file by `AppTransport` (`loadPromptHistory`); a chat from before the timeline existed
    /// is backfilled from its transcript once.
    public var promptHistory: [PromptRecord] = []
    /// `promptHistory` has been read from disk (or backfilled).
    public var promptHistoryLoaded = false
    /// The record of the prompt the chat is working on now.
    public var currentPromptID: String?
    /// Tokens the current (or last) prompt has used, across its rounds.
    public var turnPromptTokens = 0
    public var turnCompletionTokens = 0

    /// The record of the prompt in progress.
    public var currentPrompt: PromptRecord? {
        guard let currentPromptID else { return nil }
        return promptHistory.last { $0.id == currentPromptID }
    }

    /// Keep a run's plan step when an update from the roster arrives without one.
    private func merged(_ incoming: AgentRun, over existing: AgentRun?) -> AgentRun {
        guard let existing else { return incoming }
        var run = incoming
        if run.assignment == nil { run.assignment = existing.assignment }
        return run
    }

    /// Whether the chat has anything for the plan panel.
    public var hasPlan: Bool { !todos.isEmpty || proposedPlan != nil || goal != nil || lastGoal != nil || !agentRuns.isEmpty }

    /// The last turn finished with a results card to show.
    public var hasResults: Bool { turnPhase?.phase == .results }

    /// The assistant entry of the turn in progress: the newest one after the last user message.
    public var currentAnswerID: String? {
        for entry in entries.reversed() {
            guard case .message(let body) = entry.kind else { continue }
            if body.role == .user { return nil }
            if body.role == .assistant { return entry.id }
        }
        return nil
    }

    public struct GoalState: Hashable, Sendable {
        public var text: String
        public var round: Int
        public var started: Date = .now
    }

    public struct RetryState: Hashable, Sendable {
        /// How many attempts have failed in a row.
        public var attempt: Int
        /// Why the last attempt failed ("the request timed out").
        public var reason: String
        /// When the next attempt goes out.
        public var nextAttempt: Date
    }

    /// Append a reasoning delta, keeping only the recent tail for display.
    public func appendReasoning(_ chunk: String) {
        if reasoning.isEmpty { reasoningStarted = .now }
        reasoning += chunk
        if reasoning.count > 6_000 { reasoning = String(reasoning.suffix(4_000)) }
    }

    public func clearReasoning() {
        if !reasoning.isEmpty { reasoning = "" }
        reasoningStarted = nil
    }
    /// Id of the assistant entry currently receiving streamed deltas.
    public var streamingID: String?
    /// Which rows of the transcript are drawn, and where the person is in it (`TranscriptPaging`).
    let pager = TranscriptPager()

    public init(id: String, title: String, cwd: String?, preset: PermissionPreset = .workspaceWrite) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.preset = preset
        self.updatedAt = .now
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var workspaceURL: URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd)
    }

    /// A chat without a project (a regular conversation).
    public var isPlain: Bool { workspaceURL == nil }

    /// For a chat without a project: a folder it works in other than its own scratch folder (a queue task from a
    /// chat without a project works in that chat's folder). Nil = its own.
    public var workFolder: String?

    public var projectName: String? {
        workspaceURL?.lastPathComponent
    }

    /// Tool calls still in flight — the composer shows what is happening.
    public var runningTool: ToolActivity? {
        for entry in entries.reversed() {
            if let tool = entry.tool, !tool.isFinished { return tool }
        }
        return nil
    }

    // MARK: - Mutation

    @discardableResult
    public func appendMessage(_ role: MessageBody.Role, _ text: String, at: Date = .now,
                              attachments: [AttachmentBadge] = []) -> String {
        let entry = ChatEntry(at: at, kind: .message(.init(role: role, text: text, attachments: attachments)))
        entries.append(entry)
        updatedAt = .now
        return entry.id
    }

    /// Replace the badges under a user message (once its attachments are prepared and saved).
    public func setAttachments(entryID: String, _ badges: [AttachmentBadge]) {
        guard let index = entries.lastIndex(where: { $0.id == entryID }),
              case .message(var body) = entries[index].kind else { return }
        body.attachments = badges
        entries[index].kind = .message(body)
    }

    public func note(_ text: String, role: MessageBody.Role = .notice) {
        appendMessage(role, text)
    }

    /// Append streamed assistant text, opening a new bubble if none is live.
    public func appendDelta(_ chunk: String) {
        if let streamingID,
           let index = entries.lastIndex(where: { $0.id == streamingID }),
           case .message(var body) = entries[index].kind, body.role == .assistant {
            body.text += chunk
            entries[index].kind = .message(body)
        } else {
            streamingID = appendMessage(.assistant, chunk)
        }
        updatedAt = .now
    }

    /// Close the streaming bubble so the next text starts a fresh one (a tool
    /// call in between is what makes this matter).
    public func endStreaming() {
        if let streamingID,
           let index = entries.lastIndex(where: { $0.id == streamingID }),
           case .message(let body) = entries[index].kind,
           body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.remove(at: index)  // drop an empty bubble left by a tool-only turn
        }
        self.streamingID = nil
    }

    public func startTool(id: String, name: String, preview: String, at: Date = .now) {
        endStreaming()
        entries.append(ChatEntry(id: id, at: at, kind: .tool(.init(name: name, preview: preview))))
        updatedAt = .now
    }

    public func finishTool(id: String, ok: Bool, summary: String, output: String?) {
        guard let index = entries.lastIndex(where: { $0.id == id }),
              case .tool(var activity) = entries[index].kind else { return }
        activity.isOk = ok
        activity.summary = summary
        activity.output = output
        entries[index].kind = .tool(activity)
        updatedAt = .now
    }

    /// Show what a tool captured on its card.
    public func attachImages(id: String, _ images: [Data]) {
        guard let index = entries.lastIndex(where: { $0.id == id }),
              case .tool(var activity) = entries[index].kind else { return }
        activity.images = images
        entries[index].kind = .tool(activity)
        // Bound memory: only the newest cards keep their pictures.
        var kept = 0
        for i in entries.indices.reversed() {
            guard case .tool(var a) = entries[i].kind, !a.images.isEmpty else { continue }
            kept += 1
            if kept > 30 { a.images = []; entries[i].kind = .tool(a) }
        }
        updatedAt = .now
    }

    /// Record a completed tool in one step (used when replaying a stored log).
    public func addFinishedTool(id: String, name: String, preview: String,
                                summary: String?, output: String?, ok: Bool, at: Date) {
        entries.append(ChatEntry(id: id, at: at, kind: .tool(
            .init(name: name, preview: preview, summary: summary, output: output, isOk: ok)
        )))
    }

    public func setTodos(_ items: [TodoItem]) {
        todos = items
        // Keep one todo card, at the point the list last changed.
        entries.removeAll { if case .todos = $0.kind { return true } else { return false } }
        guard !items.isEmpty else { return }
        endStreaming()
        entries.append(ChatEntry(kind: .todos(items)))
        updatedAt = .now
    }

    public func recordFileChanges(_ changes: [FileChange]) {
        for change in changes {
            changedFiles.removeAll { $0.url == change.url }
            changedFiles.insert(change, at: 0)
        }
        if changedFiles.count > 40 { changedFiles = Array(changedFiles.prefix(40)) }
    }
}
