import Foundation

// MARK: - Background subagents
//
// `agent` with run_in_background: true starts a subagent that works while
// the main agent carries on (several can run in parallel — "explore the API
// layer" + "audit the tests" at once). Each chat owns one pool. The main
// agent checks on them with `agent_status` (optionally waiting), stops one
// with `agent_stop`, and is told automatically — as an automatic message in
// its next step — when one finishes. Stopping the chat stops its background
// agents too.

public final class BackgroundAgents: @unchecked Sendable {
    public enum Status: String, Sendable {
        case running, done, failed, stopped
    }

    public struct Job: Identifiable, Sendable, Hashable {
        public let id: String
        public let description: String
        public let startedAt: Date
        public var finishedAt: Date?
        public var status: Status
        /// The subagent's final report (or the failure).
        public var report: String?

        public var elapsed: TimeInterval { (finishedAt ?? .now).timeIntervalSince(startedAt) }
    }

    /// How many may run at once — a local model server has finite throughput.
    public let maxConcurrent: Int
    /// Called (on any thread, never with the pool's lock held) whenever a job starts, finishes or is
    /// stopped. A job's "started" always arrives before its "finished", however quickly it ends.
    public var onChange: (@Sendable (Job) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    /// What `stop` needs to reach a job's task, registered together with the job — the task itself
    /// only exists a moment later, and a stop in that moment must still take effect.
    private final class Handle: @unchecked Sendable {
        var task: Task<Void, Never>?
        var stopRequested = false
    }

    private let lock = NSLock()
    private var _onChange: (@Sendable (Job) -> Void)?
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var handles: [String: Handle] = [:]
    /// Finished jobs whose result the main agent hasn't been given yet.
    private var unreported: [String] = []
    private var counter = 0

    public init(maxConcurrent: Int = 4) {
        self.maxConcurrent = maxConcurrent
    }

    public var all: [Job] { lock.withLock { order.compactMap { jobs[$0] } } }
    public var running: [Job] { all.filter { $0.status == .running } }
    public func job(_ id: String) -> Job? { lock.withLock { jobs[id] } }

    /// Start `work` in the background. Returns the job, or an error message when too many are already
    /// running. `work` may throw: a job that throws is reported as failed with the error's message, and
    /// one that was stopped as stopped.
    public func launch(description: String,
                       work: @escaping @Sendable () async throws -> (ok: Bool, report: String)) -> Result<Job, BackgroundAgentsError> {
        let handle = Handle()
        // The limit is checked and the id taken in one step, so a refused launch doesn't use up an id.
        let registered: Job? = lock.withLock {
            guard jobs.values.count(where: { $0.status == .running }) < maxConcurrent else { return nil }
            counter += 1
            let job = Job(id: "bg-\(counter)", description: description, startedAt: .now, status: .running)
            jobs[job.id] = job
            order.append(job.id)
            handles[job.id] = handle
            return job
        }
        guard let job = registered else { return .failure(.tooMany(maxConcurrent)) }
        // Told before the work starts, so a job that ends at once can't be announced finished first.
        onChange?(job)
        let task = Task { [weak self] in
            let outcome: (ok: Bool, report: String)
            do {
                outcome = try await work()
            } catch {
                outcome = (false, Task.isCancelled ? "Stopped before it finished." : error.localizedDescription)
            }
            self?.finish(job.id, status: Task.isCancelled ? .stopped : (outcome.ok ? .done : .failed), report: outcome.report)
        }
        let stopMeanwhile: Bool = lock.withLock {
            handle.task = task
            return handle.stopRequested
        }
        if stopMeanwhile { task.cancel() }
        return .success(job)
    }

    /// Stop one job. Returns false when there is no such running job.
    @discardableResult
    public func stop(_ id: String) -> Bool {
        let found: (task: Task<Void, Never>?, running: Bool) = lock.withLock {
            guard jobs[id]?.status == .running else { return (nil, false) }
            guard let handle = handles[id] else { return (nil, true) }
            handle.stopRequested = true
            return (handle.task, true)
        }
        guard found.running else { return false }
        found.task?.cancel()
        finish(id, status: .stopped, report: "Stopped before it finished.")
        return true
    }

    public func stopAll() {
        for job in running { stop(job.id) }
    }

    /// Wait until the job finishes or `timeout` passes (cancellable).
    public func wait(_ id: String, timeout: TimeInterval) async -> Job? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while let current = job(id), current.status == .running, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return job(id)
    }

    /// Finished jobs the main agent hasn't seen yet (marks them seen).
    public func takeUnreported() -> [Job] {
        lock.withLock {
            let list = unreported.compactMap { jobs[$0] }
            unreported = []
            return list
        }
    }

    /// Jobs that were taken for the main agent but never reached it (the request failed before the model
    /// saw them): announce them again with the next message. A stopped job is never announced, and a job
    /// is never queued twice.
    public func requeue(_ jobs: [Job]) {
        lock.withLock {
            for job in jobs {
                guard let current = self.jobs[job.id], current.status != .running, current.status != .stopped else { continue }
                if !unreported.contains(job.id) { unreported.append(job.id) }
            }
        }
    }

    /// True when finished jobs are waiting to be handed to the main agent.
    public var hasUnreported: Bool { lock.withLock { !unreported.isEmpty } }

    /// The main agent read this job's result (agent_status): don't announce it again.
    public func markReported(_ id: String) {
        lock.withLock { unreported.removeAll { $0 == id } }
    }

    private func finish(_ id: String, status: Status, report: String) {
        let job: Job? = lock.withLock {
            guard var job = jobs[id], job.status == .running else { return nil }
            job.status = status
            job.finishedAt = .now
            job.report = report
            jobs[id] = job
            handles[id] = nil
            if status != .stopped { unreported.append(id) }
            return job
        }
        if let job { onChange?(job) }
    }

    /// The automatic message the main agent gets when jobs finish.
    public static func notice(for finished: [Job]) -> String {
        var lines = ["[Automatic message: \(finished.count == 1 ? "a background agent" : "\(finished.count) background agents") finished. Not from the user.]"]
        for job in finished {
            let report = job.report ?? ""
            let clipped = report.count > 6_000 ? String(report.prefix(6_000)) + "\n[… report truncated]" : report
            lines.append("\n## \(job.id) “\(job.description)” — \(job.status.rawValue) after \(job.elapsed.formattedDuration)\n\(clipped)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum BackgroundAgentsError: Error, Equatable, LocalizedError {
    case tooMany(Int)
    public var errorDescription: String? {
        switch self {
        case .tooMany(let n): "\(n) background agents are already running — wait for one (agent_status with wait_seconds) or stop one first."
        }
    }
}

// MARK: - Tools

public struct AgentStatusTool: ToolExecutor {
    public static let name = "agent_status"
    public static let spec = ToolSpec(
        name: name,
        description: "Check on background subagents started with agent(run_in_background: true). Without an id, lists them all and how busy each subagent server is. With an id, returns that agent's full report when it has finished; pass wait_seconds to wait for it (up to 600) instead of polling.",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"A background agent id, e.g. bg-1"},"wait_seconds":{"type":"integer","description":"Wait up to this many seconds for it to finish (max 600)"}}}"#
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pool = context.backgroundAgents else {
            return ToolResult(output: "Error: background agents aren't available here.")
        }
        let id = (Self.string(args, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            let jobs = pool.all
            guard !jobs.isEmpty else {
                return ToolResult(output: AgentTool.withLoad("No background agents have been started in this chat.", context: context))
            }
            let lines = jobs.map { j -> String in
                var line = "- \(j.id) “\(j.description)”: \(j.status.rawValue), \(j.elapsed.formattedDuration)"
                if j.status != .running, let r = j.report { line += " — " + String((r.components(separatedBy: "\n").first ?? "").prefix(120)) }
                return line
            }
            return ToolResult(output: AgentTool.withLoad("Background agents:\n" + lines.joined(separator: "\n")
                              + "\nPass an id for a full report (and wait_seconds to wait for a running one).", context: context))
        }
        let wait = min(max(JSONArgs.int(args, "wait_seconds", default: 0), 0), 600)
        guard let job = await pool.wait(id, timeout: TimeInterval(wait)) else {
            return ToolResult(output: "Error: no background agent \(id). agent_status without an id lists them.")
        }
        switch job.status {
        case .running:
            return ToolResult(output: "\(job.id) “\(job.description)” is still running (\(job.elapsed.formattedDuration)). Carry on with other work, or wait with wait_seconds.")
        case .done, .failed, .stopped:
            pool.markReported(job.id)
            return ToolResult(output: "\(job.id) “\(job.description)” \(job.status.rawValue) after \(job.elapsed.formattedDuration).\n\n\(job.report ?? "(no report)")")
        }
    }
}

public struct AgentStopTool: ToolExecutor {
    public static let name = "agent_stop"
    public static let spec = ToolSpec(
        name: name,
        description: "Stop a running background subagent (e.g. it's no longer needed, or it's going the wrong way).",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"The background agent id, e.g. bg-2"}},"required":["id"]}"#
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let pool = context.backgroundAgents else {
            return ToolResult(output: "Error: background agents aren't available here.")
        }
        let id = (Self.string(args, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(output: pool.stop(id) ? "Stopped \(id)." : "Error: \(id) isn't a running background agent.")
    }
}

/// Adds work to the app's task queue — background tasks that run unattended,
/// one at a time, each in its own chat, after (or alongside) this one.
public struct QueueAddTool: ToolExecutor {
    public static let name = "queue_task"
    public static let spec = ToolSpec(
        name: name,
        description: "Add a background task to the user's task queue. Queued tasks run unattended, one at a time, each in its own chat, until the model declares them complete — use it for follow-up work that can happen after (or independently of) this conversation, e.g. 'write tests for the parser'. Give full instructions: the task's chat won't see this conversation. Set start to true to start the queue if it isn't running.",
        parameters: #"{"type":"object","properties":{"title":{"type":"string","description":"Short title"},"details":{"type":"string","description":"Complete, self-contained instructions"},"front":{"type":"boolean","description":"Put it at the front of the queue"},"start":{"type":"boolean","description":"Start the queue if it isn't running"}},"required":["title","details"]}"#
    )

    /// (title, details, front, start) → a message for the model.
    public let add: @Sendable (String, String, Bool, Bool) async -> String

    public init(add: @escaping @Sendable (String, String, Bool, Bool) async -> String) {
        self.add = add
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let title = (Self.string(args, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (Self.string(args, "details") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ToolResult(output: "Error: title is required.") }
        let out = await add(title, details, JSONArgs.bool(args, "front", default: false), JSONArgs.bool(args, "start", default: false))
        return ToolResult(output: out)
    }
}
