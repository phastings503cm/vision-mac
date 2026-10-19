import Foundation

// MARK: - Task queue
//
// A durable, ordered list of autonomous work items. Each task is run exactly
// like a `/goal`: the harness works it round after round until the model
// declares it complete (or blocked / failed). Items are persisted as one
// JSON file so a week-long queue survives restarts, and every transition
// appends a timestamped log line so the whole run can be read afterwards.
//
// This type is pure Foundation — no UI, no transport — so the store logic
// (ordering, statuses, stats, persistence) is verifiable in tests.

public enum QueueTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case complete
    case blocked
    case failed
    case skipped

    public var label: String { rawValue.capitalized }

    /// A status this build doesn't know (written by a newer one) reads as
    /// blocked — it needs a person to look, and must never be re-run
    /// unattended — rather than failing the whole file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QueueTaskStatus(rawValue: raw) ?? .blocked
    }
}

/// One line of a task's history.
public struct QueueLogLine: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String

    public enum Kind: String, Codable, Sendable {
        case entered      // added to the queue
        case reordered    // moved in the queue
        case started      // work began
        case round        // a goal round finished
        case complete
        case blocked
        case failed
        case skipped
        case note         // free-form (edited, archived, …)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .note
        }
    }

    public init(id: UUID = UUID(), at: Date = .now, kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.kind = kind
        self.text = text
    }
}

public struct QueueTask: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    /// Short human title ("Fix the login crash").
    public var title: String
    /// Full instructions; the goal text run with.
    public var details: String
    public var status: QueueTaskStatus
    public var enteredAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// How many goal rounds this task took.
    public var rounds: Int = 0
    /// Token totals for the whole task.
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    /// The session working / that worked this task (to jump to its
    /// transcript, and so an interrupted task resumes in the same chat).
    public var sessionID: String?
    /// The project folder the task was queued in; it runs there even if the
    /// app has since switched to another project. Nil for tasks queued before
    /// this was recorded (they run in the current project).
    public var cwd: String?
    /// For a task queued from a chat without a project: that chat's scratch folder, which the task works in.
    public var workFolder: String?
    /// The route and thinking level of the chat that queued it: the task's chat runs on them (nil = the project's
    /// last choice).
    public var routeID: String?
    public var thinking: String?
    /// A chat task: queued with "Add to tasks" in this chat, it runs there as the chat's next prompt once the chat is
    /// free — interactively, in order, after whatever the chat is doing. Nil = a task of the unattended queue, which
    /// the queue runner works as a goal. The queue runner never takes a chat task.
    public var chatID: String?
    public var log: [QueueLogLine]

    public init(id: String = UUID().uuidString,
                title: String,
                details: String = "",
                status: QueueTaskStatus = .queued,
                enteredAt: Date = .now,
                cwd: String? = nil,
                log: [QueueLogLine] = []) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.enteredAt = enteredAt
        self.cwd = cwd
        self.log = log
    }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date.now
        return max(0, end.timeIntervalSince(startedAt))
    }

    public var totalTokens: Int { promptTokens + completionTokens }

    /// Average tokens/second over the task's runtime (both directions, as the
    /// model server served them). Nil until the task has runtime.
    public var avgTokensPerSecond: Double? {
        guard let d = duration, d > 0, totalTokens > 0 else { return nil }
        return Double(totalTokens) / d
    }

    /// The text a goal loop runs for this task.
    public var goalText: String {
        details.isEmpty ? title : "\(title)\n\n\(details)"
    }

    /// What a chat task sends when its turn comes: the prompt exactly as it was written (kept in `details`; the
    /// title is its first line).
    public var promptText: String {
        details.isEmpty ? title : details
    }

    /// A chat task (see `chatID`).
    public var isChatTask: Bool { chatID != nil }

    public mutating func appendLog(_ kind: QueueLogLine.Kind, _ text: String, at: Date = .now) {
        log.append(QueueLogLine(at: at, kind: kind, text: text))
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, details, status, enteredAt, startedAt, finishedAt, rounds
        case promptTokens, completionTokens, sessionID, cwd, workFolder, routeID, thinking, chatID, log
    }

    /// Tolerant decoding: a missing field (a file from an older or newer
    /// build) takes its default instead of failing — and a failed decode
    /// would otherwise cost the user their whole queue.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled task"
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        status = try c.decodeIfPresent(QueueTaskStatus.self, forKey: .status) ?? .queued
        enteredAt = try c.decodeIfPresent(Date.self, forKey: .enteredAt) ?? .now
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens) ?? 0
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens) ?? 0
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        workFolder = try c.decodeIfPresent(String.self, forKey: .workFolder)
        routeID = try? c.decodeIfPresent(String.self, forKey: .routeID)
        thinking = try? c.decodeIfPresent(String.self, forKey: .thinking)
        chatID = try? c.decodeIfPresent(String.self, forKey: .chatID)
        log = (try? c.decodeIfPresent([QueueLogLine].self, forKey: .log)) ?? []
    }
}

/// A persistent, ordered queue of tasks.
public struct TaskQueue: Codable, Hashable, Sendable {
    public private(set) var tasks: [QueueTask]

    public init(tasks: [QueueTask] = []) {
        self.tasks = tasks
    }

    public subscript(id: String) -> QueueTask? {
        get { tasks.first { $0.id == id } }
        set {
            guard let task = newValue, let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i] = task
        }
    }

    // MARK: Querying

    /// Append a fully-formed task (used by tests and restoration; the normal
    /// path is `add`, which logs the entry).
    public mutating func appendTask(_ task: QueueTask) { tasks.append(task) }

    public func task(_ id: String) -> QueueTask? { tasks.first { $0.id == id } }
    public func index(of id: String) -> Int? { tasks.firstIndex { $0.id == id } }

    /// The next task the queue runner works: the first `.queued` item of the unattended queue (chat tasks run in
    /// their chats, never here).
    public var nextTask: QueueTask? { tasks.first { $0.status == .queued && $0.chatID == nil } }

    public var runningTask: QueueTask? { tasks.first { $0.status == .running && $0.chatID == nil } }
    public var hasRunning: Bool { tasks.contains { $0.status == .running && $0.chatID == nil } }
    /// Tasks waiting in the unattended queue.
    public var queuedCount: Int { tasks.count(where: { $0.status == .queued && $0.chatID == nil }) }

    /// Just the unattended queue (what the Task Queue panel and its runner see).
    public var unattended: TaskQueue { TaskQueue(tasks: tasks.filter { $0.chatID == nil }) }

    // MARK: Chat tasks

    /// A chat's tasks in order: running first, then the queued ones as they will run, then the finished ones
    /// (newest first).
    public func chatTasks(_ chatID: String) -> [QueueTask] {
        let mine = tasks.filter { $0.chatID == chatID }
        let running = mine.filter { $0.status == .running }
        let queued = mine.filter { $0.status == .queued }
        let done = mine.filter { $0.status != .running && $0.status != .queued }
            .sorted { ($0.finishedAt ?? $0.enteredAt) > ($1.finishedAt ?? $1.enteredAt) }
        return running + queued + done
    }

    /// The chat task to start next in `chatID`, if any is waiting.
    public func nextChatTask(_ chatID: String) -> QueueTask? {
        tasks.first { $0.chatID == chatID && $0.status == .queued }
    }

    /// The chat task running in `chatID`, if one is.
    public func runningChatTask(_ chatID: String) -> QueueTask? {
        tasks.first { $0.chatID == chatID && $0.status == .running }
    }

    /// Chat tasks waiting in `chatID`.
    public func queuedChatTaskCount(_ chatID: String) -> Int {
        tasks.count(where: { $0.chatID == chatID && $0.status == .queued })
    }

    /// Every chat that has chat tasks waiting.
    public var chatsWithQueuedTasks: Set<String> {
        Set(tasks.compactMap { $0.status == .queued ? $0.chatID : nil })
    }
    public var completeCount: Int { tasks.count(where: { $0.status == .complete }) }

    /// All log lines across all tasks, oldest first — the queue's global log.
    public var allLogLines: [QueueLogLine] {
        tasks.flatMap { $0.log }.sorted { $0.at < $1.at }
    }
}

// MARK: - Stats

public struct QueueStats: Hashable, Sendable {
    public var total: Int
    public var completed: Int
    public var failed: Int
    public var blocked: Int
    public var running: Int
    public var queued: Int
    public var skipped: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalDuration: TimeInterval

    public var tokensPerSecond: Double? {
        totalDuration > 0 ? Double(completionTokens + promptTokens) / totalDuration : nil
    }

    public var finished: Bool { total > 0 && queued == 0 && running == 0 }
}

public extension TaskQueue {
    func stats() -> QueueStats {
        var s = QueueStats(total: tasks.count, completed: 0, failed: 0, blocked: 0,
                           running: 0, queued: 0, skipped: 0,
                           promptTokens: 0, completionTokens: 0, totalDuration: 0)
        for t in tasks {
            switch t.status {
            case .complete: s.completed += 1
            case .failed: s.failed += 1
            case .blocked: s.blocked += 1
            case .running: s.running += 1
            case .queued: s.queued += 1
            case .skipped: s.skipped += 1
            }
            s.promptTokens += t.promptTokens
            s.completionTokens += t.completionTokens
            if t.finishedAt != nil, let d = t.duration { s.totalDuration += d }
        }
        return s
    }
}

// MARK: - Mutations (used by the transport; keep the log consistent)

public extension TaskQueue {
    @discardableResult
    mutating func add(_ title: String, details: String = "", atFront: Bool = false,
                      cwd: String? = nil, workFolder: String? = nil) -> QueueTask {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var task = QueueTask(title: title, details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                             cwd: (cwd?.isEmpty ?? true) ? nil : cwd)
        if task.cwd == nil, let workFolder, !workFolder.isEmpty { task.workFolder = workFolder }
        task.appendLog(.entered, "Entered the queue at #\(atFront ? 1 : queuedCount + 1)")
        if atFront { tasks.insert(task, at: tasks.firstIndex { $0.status == .queued } ?? tasks.endIndex) }
        else { tasks.append(task) }
        return task
    }

    /// The model the task's chat runs on (the queuing chat's).
    mutating func setRoute(id: String, routeID: String?, thinking: String?) {
        guard var t = task(id) else { return }
        t.routeID = routeID
        t.thinking = thinking
        self[t.id] = t
    }

    /// Queue a prompt as a chat task: it runs in `chatID` as that chat's next prompt once everything before it is
    /// done (at the front: before the chat's other waiting tasks). The title is the prompt's first line.
    @discardableResult
    mutating func addChatTask(_ prompt: String, chatID: String, atFront: Bool = false,
                              cwd: String? = nil, workFolder: String? = nil) -> QueueTask {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        var title = first.trimmingCharacters(in: .whitespaces)
        if title.count > 80 { title = String(title.prefix(79)) + "…" }
        if title.isEmpty { title = "Untitled task" }
        var task = QueueTask(title: title, details: text, cwd: (cwd?.isEmpty ?? true) ? nil : cwd)
        if task.cwd == nil, let workFolder, !workFolder.isEmpty { task.workFolder = workFolder }
        task.chatID = chatID
        task.sessionID = chatID
        let ahead = queuedChatTaskCount(chatID)
        task.appendLog(.entered, "Added to the chat's tasks at #\(atFront ? 1 : ahead + 1)")
        if atFront, let first = tasks.firstIndex(where: { $0.chatID == chatID && $0.status == .queued }) {
            tasks.insert(task, at: first)
        } else {
            tasks.append(task)
        }
        return task
    }

    /// Move a chat task up (negative) or down among its chat's waiting tasks.
    mutating func moveWithinChat(id: String, by offset: Int) {
        guard offset != 0, let task = task(id), task.status == .queued, let chatID = task.chatID else { return }
        let siblings = tasks.filter { $0.chatID == chatID && $0.status == .queued }.map(\.id)
        guard let from = siblings.firstIndex(of: id) else { return }
        let to = min(max(from + offset, 0), siblings.count - 1)
        guard to != from else { return }
        move(id: id, onto: siblings[to])
    }

    /// A chat was deleted: its waiting chat tasks go (a running one is marked skipped, as `remove` does).
    mutating func removeChatTasks(_ chatID: String) {
        for task in tasks where task.chatID == chatID { remove(id: task.id) }
    }

    mutating func update(id: String, title: String?, details: String?) {
        guard var t = task(id) else { return }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { t.title = title }
        if let details { t.details = details.trimmingCharacters(in: .whitespacesAndNewlines) }
        t.appendLog(.note, "Details updated.")
        self[t.id] = t
    }

    mutating func remove(id: String) {
        guard let t = task(id) else { return }
        switch t.status {
        case .running:
            // Never lose the in-flight task's record; mark it instead.
            var marked = t
            marked.status = .skipped
            marked.finishedAt = .now
            marked.appendLog(.skipped, "Deleted while running — skipped.")
            self[t.id] = marked
        default:
            tasks.removeAll { $0.id == id }
        }
    }

    mutating func move(id: String, by offset: Int) {
        guard let from = index(of: id), tasks[from].status == .queued else { return }
        var to = from + offset
        // Keep the move inside the queued region.
        while to > 0 && tasks[to - 1].status != .queued { to -= 1 }
        while to < tasks.count - 1 && tasks[to + 1].status != .queued { to += 1 }
        guard to != from else { return }
        let t = tasks.remove(at: from)
        tasks.insert(t, at: to)
        logMove(t.id)
    }

    /// Move a queued task so it sits just before `targetID` (nil = the end).
    mutating func move(id: String, before targetID: String?) {
        guard let from = index(of: id), tasks[from].status == .queued, targetID != id else { return }
        var to = targetID.flatMap(index(of:)) ?? tasks.count
        if to > from { to -= 1 }
        guard to != from else { return }
        let t = tasks.remove(at: from)
        tasks.insert(t, at: to)
        logMove(t.id)
    }

    /// Drag-and-drop: dropping a queued task onto another puts it in that
    /// task's place — after it when dragged down, before it when dragged up —
    /// so every position, first and last included, is reachable.
    mutating func move(id: String, onto targetID: String) {
        guard let from = index(of: id), let to = index(of: targetID), from != to,
              tasks[from].status == .queued, tasks[to].status == .queued else { return }
        let t = tasks.remove(at: from)
        tasks.insert(t, at: to)
        logMove(t.id)
    }

    private mutating func logMove(_ id: String) {
        if var moved = self[id] {
            moved.appendLog(.reordered, "Moved to position #\(position(of: id) ?? 1)")
            self[id] = moved
        }
    }

    /// 1-based position among queued tasks (the "long view" number).
    /// Counted among the tasks of the same list: a chat task's position in its chat, an unattended task's in the queue.
    public func position(of id: String) -> Int? {
        guard let idx = index(of: id) else { return nil }
        let binding = tasks[idx].chatID
        return tasks[0..<idx].count(where: { $0.status == .queued && $0.chatID == binding }) + 1
    }

    mutating func start(_ id: String, sessionID: String? = nil) {
        // Queued, or a blocked/failed task being retried. Fresh stats each run.
        guard var t = task(id), t.status != .running else { return }
        t.status = .running
        t.startedAt = .now
        t.finishedAt = nil
        t.rounds = 0
        t.promptTokens = 0
        t.completionTokens = 0
        // Record the chat now, not at the end: a task stopped or interrupted
        // mid-way resumes in the same conversation, with its context.
        if let sessionID { t.sessionID = sessionID }
        t.appendLog(.started, "Work started — \(t.title)")
        self[t.id] = t
    }

    /// Record the chat a task will run in (before it starts).
    mutating func attachSession(_ id: String, _ sessionID: String) {
        guard var t = task(id) else { return }
        t.sessionID = sessionID
        self[t.id] = t
    }

    /// Forget a deleted chat: tasks that pointed at it get a fresh one next time.
    mutating func detachSession(_ sessionID: String) {
        for i in tasks.indices where tasks[i].sessionID == sessionID && tasks[i].status != .running {
            tasks[i].sessionID = nil
        }
    }

    /// A free-form line in a task's history (model outages, recoveries, …).
    mutating func note(_ id: String, _ text: String) {
        guard var t = task(id) else { return }
        t.appendLog(.note, text)
        self[t.id] = t
    }

    /// Return a running task to the queue (the user stopped the run mid-way).
    mutating func markStopped(_ id: String, note: String = "Stopped by the user — back in the queue.") {
        guard var t = task(id), t.status == .running else { return }
        t.status = .queued
        t.startedAt = nil
        t.appendLog(.note, note)
        self[t.id] = t
    }

    /// Put a blocked/failed task back in line (optionally to the front so it's
    /// retried next), keeping its transcript link so work resumes in the same chat.
    mutating func requeue(_ id: String, toFront: Bool = true) {
        guard var t = task(id), t.status != .running else { return }
        let wasFinished = t.status != .queued
        guard let at = index(of: id) else { return }
        t.status = .queued
        t.startedAt = nil
        t.finishedAt = nil
        if wasFinished { t.appendLog(.note, "Re-queued to retry.") }
        _ = tasks.remove(at: at)
        if toFront {
            let front = tasks.firstIndex { $0.status == .queued } ?? tasks.endIndex
            tasks.insert(t, at: front)
        } else {
            tasks.append(t)
        }
        self[id] = t
    }

    mutating func recordRound(_ id: String, round: Int, prompt: Int, completion: Int) {
        guard var t = task(id), t.status == .running else { return }
        t.rounds = round
        t.promptTokens += prompt
        t.completionTokens += completion
        self[t.id] = t
    }

    mutating func finish(_ id: String, status: QueueTaskStatus,
                         reason: String? = nil, sessionID: String? = nil) {
        guard var t = task(id) else { return }
        t.status = status
        t.finishedAt = .now
        if let sessionID { t.sessionID = sessionID }
        switch status {
        case .complete:
            let d = t.duration.map { "\($0.formattedDuration)" } ?? "?"
            let rate = t.avgTokensPerSecond.map { " · \(Int($0.rounded())) tokens/s avg" } ?? ""
            t.appendLog(.complete, "Complete after \(t.rounds) round\(t.rounds == 1 ? "" : "s"), \(d)\(rate).")
        case .blocked:
            t.appendLog(.blocked, "Blocked — \(reason ?? "needs the user").")
        case .failed:
            t.appendLog(.failed, "Failed — \(reason ?? "unknown error").")
        case .skipped:
            t.appendLog(.skipped, "Skipped.")
        default:
            break
        }
        self[t.id] = t
    }
}

public extension Double {
    /// 162.0 → "2m 42s"; 3600 → "1h 0m".
    var formattedDuration: String {
        let secs = Int(self.rounded())
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }
}
