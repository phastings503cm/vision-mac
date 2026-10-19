import Foundation

// MARK: - The roster
//
// Every subagent a chat has started — waiting for a server, working, or finished — so a side panel can
// show who is doing what, and where. Foreground and background runs both land here.

public enum AgentRunStatus: String, Sendable, Hashable {
    case running, done, failed, stopped
}

/// One subagent run, as the UI lists it.
public struct AgentRun: Identifiable, Sendable, Hashable {
    public let id: String
    public let description: String
    public let agentType: String
    public let isBackground: Bool
    public let startedAt: Date
    /// The model server it is (or was) running on, once it has one. Only set when there was a choice of servers.
    public var server: String?
    public var status: AgentRunStatus
    /// What it is doing right now ("grep: TODO", "waiting for a free server").
    public var activity: String
    /// Tool calls made so far.
    public var steps: Int
    public var finishedAt: Date?
    /// Its final report (or the failure), once it is over.
    public var report: String?
    /// The task it was given (the start of it), for its log.
    public var prompt: String?
    /// The route (model server) it actually runs on — always set once it has one, even when there was no choice —
    /// and the model id it sends its requests to. What the background-activity menu shows, so "is the subagent really
    /// on the model I configured?" has an answer.
    public var route: String?
    public var model: String?
    /// Why it runs where it does when that isn't where it was asked to ("asked for spark-2 — not a subagent server").
    public var placement: String?
    /// How its server was chosen: a `SubagentPlacement.Reason` code ("picked", "agent-file", "least-busy",
    /// "fallback"); nil when there was no choice.
    public var placementReason: String?
    /// The plan step it is working (see `PlanAssignment`).
    public var assignment: String?
    /// The plan step the agent tool's `step` argument named (a number or the step's text), as given.
    public var requestedStep: String?
    /// Tokens its model calls used (known when it finishes).
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    /// What it did, stamped: started, where it runs, each tool call, how it ended. Bounded.
    public var log: [AgentRunLine] = []

    public init(id: String, description: String, agentType: String, isBackground: Bool, startedAt: Date,
                server: String? = nil, status: AgentRunStatus = .running, activity: String = "starting",
                steps: Int = 0, finishedAt: Date? = nil, report: String? = nil, prompt: String? = nil) {
        self.id = id
        self.description = description
        self.agentType = agentType
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.server = server
        self.status = status
        self.activity = activity
        self.steps = steps
        self.finishedAt = finishedAt
        self.report = report
        self.prompt = prompt
    }

    /// "Qwen3-Coder-30B on DGX Spark" — the model and where; nil until it has a server.
    public var placementLabel: String? {
        switch (model, route ?? server) {
        case let (model?, route?): "\(model) on \(route)"
        case let (nil, route?): route
        case let (model?, nil): model
        default: nil
        }
    }

    public var isRunning: Bool { status == .running }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// One stamped line of a subagent's log.
public struct AgentRunLine: Sendable, Hashable {
    public var at: Date
    public var text: String
    public init(at: Date, text: String) {
        self.at = at
        self.text = text
    }
}

/// Every subagent a chat has started. Thread-safe: runs report from whatever thread they are on.
public final class AgentRoster: @unchecked Sendable {
    /// How many runs are kept; the oldest finished ones go first.
    private static let retained = 60

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var runs: [AgentRun] = []
    private var counter = 0
    private var changeHandler: (@Sendable (AgentRun) -> Void)?

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Called (on any thread, never with the roster's lock held) whenever a run starts, moves or ends.
    /// A run with an empty `id` means the finished runs were cleared (see `clearFinished()`).
    public var onChange: (@Sendable (AgentRun) -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public var all: [AgentRun] { lock.withLock { runs } }

    public var running: [AgentRun] { all.filter(\.isRunning) }

    public func run(_ id: String) -> AgentRun? {
        lock.withLock { runs.first { $0.id == id } }
    }

    /// Register a new run; its id.
    @discardableResult
    public func begin(description: String, agentType: String, background: Bool, prompt: String? = nil,
                      step: String? = nil) -> String {
        let run: AgentRun = lock.withLock {
            counter += 1
            let at = now()
            var run = AgentRun(id: "a\(counter)", description: description, agentType: agentType,
                               isBackground: background, startedAt: at, prompt: prompt.map { String($0.prefix(2_000)) })
            let requested = step?.trimmingCharacters(in: .whitespacesAndNewlines)
            run.requestedStep = (requested?.isEmpty ?? true) ? nil : requested
            run.log.append(AgentRunLine(at: at, text: "Started (\(agentType)\(background ? ", in the background" : ""))"))
            runs.append(run)
            // Keep the list bounded: the oldest finished runs go first.
            while runs.count > Self.retained, let old = runs.firstIndex(where: { !$0.isRunning }) {
                runs.remove(at: old)
            }
            return run
        }
        onChange?(run)
        return run.id
    }

    public func update(_ id: String, _ change: (AgentRun) -> AgentRun) {
        let updated: AgentRun? = lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
            let updated = change(runs[index])
            runs[index] = updated
            return updated
        }
        if let updated { onChange?(updated) }
    }

    public func setServer(_ id: String, _ label: String) {
        update(id) { var run = $0; run.server = label; return run }
    }

    /// Where it runs now: the route, the model, how it was chosen (a `SubagentPlacement.Reason` code) and — when that
    /// isn't where it was asked to run — why.
    public func setPlacement(_ id: String, route: String, model: String, reason: String? = nil, note: String? = nil) {
        let at = now()
        update(id) { run in
            var run = run
            let moved = run.route != nil && run.route != route
            run.route = route
            run.model = model
            if let reason {
                run.placementReason = reason
                run.placement = note
            } else if let note {
                run.placement = note
            }
            run.log.append(AgentRunLine(at: at, text: (moved ? "Moved to " : "Running on ") + "\(model) · \(route)"
                                        + (SubagentPlacement.Reason.label(reason).map { " — \($0)" } ?? "")
                                        + (note.map { " — \($0)" } ?? "")))
            Self.trim(&run)
            return run
        }
    }

    /// The plan step it works (set by the host when it starts).
    public func setAssignment(_ id: String, _ step: String?) {
        guard let step, !step.isEmpty else { return }
        update(id) { var run = $0; run.assignment = step; return run }
    }

    /// Tokens a finished model run used.
    public func addTokens(_ id: String, prompt: Int, completion: Int) {
        guard prompt > 0 || completion > 0 else { return }
        update(id) { run in
            var run = run
            run.promptTokens += prompt
            run.completionTokens += completion
            return run
        }
    }

    /// What the run is doing now; `step` counts it as a tool call (and writes it to the run's log).
    public func note(_ id: String, _ activity: String, step: Bool = false) {
        let at = now()
        update(id) { run in
            guard run.isRunning else { return run }
            var run = run
            run.activity = activity
            if step { run.steps += 1 }
            if step || run.log.last?.text != activity { run.log.append(AgentRunLine(at: at, text: activity)) }
            Self.trim(&run)
            return run
        }
    }

    private static func trim(_ run: inout AgentRun) {
        if run.log.count > 200 { run.log.removeFirst(run.log.count - 200) }
    }

    public func finish(_ id: String, status: AgentRunStatus, report: String) {
        let finishedAt = now()
        update(id) { run in
            guard run.isRunning else { return run }
            var run = run
            run.status = status
            run.finishedAt = finishedAt
            run.report = report
            switch status {
            case .done: run.activity = "done"
            case .stopped: run.activity = "stopped"
            default: run.activity = "failed"
            }
            run.log.append(AgentRunLine(at: finishedAt, text: status == .done ? "Finished — report delivered"
                                        : status == .stopped ? "Stopped" : "Failed: \(String(report.prefix(200)))"))
            Self.trim(&run)
            return run
        }
    }

    /// Forget the runs that are over.
    public func clearFinished() {
        lock.withLock { runs.removeAll { !$0.isRunning } }
        onChange?(AgentRun(id: "", description: "", agentType: "", isBackground: false, startedAt: now(), status: .done))
    }
}

// MARK: - Which servers may see what

/// The words the main agent is told about subagent servers, in the `agent` and `delegate` tools (the same on Windows).
public enum SubagentServers {
    /// What to do about servers that aren't private.
    public static let guidance =
        "Servers that aren't private must not receive sensitive data. Describe their tasks in general terms — no names, credentials, personal or client details; the app also masks what it detects."

    /// What `sensitive` does.
    public static let sensitiveParameter =
        "Set true when the task needs sensitive data (personal data, credentials, client details). It then runs only on a private server."

    /// What `server` does.
    public static let serverParameter =
        "Where this task runs: an id from the subagent servers listed in the agent tool, or \"primary\" for this chat's own model. Leave it out to let Vision pick the least busy. A chosen server that is busy is waited for up to 2 minutes; after that, or if it can't take the task, another server runs it and the report says so."
}
