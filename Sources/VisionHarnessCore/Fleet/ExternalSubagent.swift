import Foundation

// MARK: - A subagent server with an engine of its own
//
// Most subagent servers are models Vision's own engine talks to. Some run their own agent instead — Claude Code works a
// task as one `claude -p` job in the chat's folder. Such a server's `FleetTarget` carries an `ExternalSubagent`, and
// the agent tool hands it the task instead of starting an engine; the rest of a subagent's life (its lease, the
// roster, failover, cancellation, its report) stays the same.

/// An engine that works one subagent task by itself.
public protocol ExternalSubagent: Sendable {
    /// Work the task. Throws `CancellationError` when stopped, a server fault (see `AgentFleet.isServerFault`) when
    /// it can't take the task, and anything else when the task itself failed.
    func run(_ job: ExternalSubagentJob) async throws -> ExternalSubagentResult
}

/// One task for an external engine.
public struct ExternalSubagentJob: Sendable {
    /// The task, as the main agent wrote it.
    public var prompt: String
    /// Added to the engine's own instructions: what it is (a subagent) and the agent type's prompt.
    public var systemNote: String
    /// The chat's folder (its scratch folder when it has no project).
    public var workspace: URL
    /// The permissions it works under: the chat's, or Plan only for a read-only agent type.
    public var preset: PermissionPreset
    public var readOnly: Bool
    /// Its step budget.
    public var maxSteps: Int
    /// What it is doing now; `true` counts it as a step (a tool call).
    public var activity: @Sendable (String, Bool) -> Void
    /// It started something that changes the workspace (a retry elsewhere must look before it repeats a step).
    public var noteMutation: @Sendable () -> Void
    /// Ask the person (the chat's own permission card); false = no.
    public var requestPermission: @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool

    public init(prompt: String, systemNote: String, workspace: URL, preset: PermissionPreset, readOnly: Bool,
                maxSteps: Int, activity: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
                noteMutation: @escaping @Sendable () -> Void = {},
                requestPermission: @escaping @Sendable (String, String, String) async -> Bool = { _, _, _ in false }) {
        self.prompt = prompt
        self.systemNote = systemNote
        self.workspace = workspace
        self.preset = preset
        self.readOnly = readOnly
        self.maxSteps = maxSteps
        self.activity = activity
        self.noteMutation = noteMutation
        self.requestPermission = requestPermission
    }
}

/// How an external engine's task ended.
public struct ExternalSubagentResult: Sendable, Equatable {
    public var ok: Bool
    /// What goes back to the main agent.
    public var report: String
    /// It changed the workspace.
    public var mutated: Bool
    public var promptTokens: Int
    public var completionTokens: Int
    /// What it would have cost at API prices, when the engine says.
    public var costUSD: Double?

    public init(ok: Bool, report: String, mutated: Bool = false, promptTokens: Int = 0, completionTokens: Int = 0,
                costUSD: Double? = nil) {
        self.ok = ok
        self.report = report
        self.mutated = mutated
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.costUSD = costUSD
    }
}

/// A subagent server that can't take work until a known time (a Claude plan's usage limit): a server fault, and the
/// fleet keeps work off it until `until` (else 15 minutes).
public struct SubagentServerPaused: Error, LocalizedError, Sendable {
    public let message: String
    public let until: Date?

    public init(message: String, until: Date?) {
        self.message = message
        self.until = until
    }

    public var errorDescription: String? { message }
}
