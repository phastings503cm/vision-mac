import Foundation

// MARK: - Claude Code's permission questions, answered with the chat's own policy
//
// With `--permission-prompt-tool stdio`, Claude Code asks Vision before each tool call that needs permission (a
// `can_use_tool` control request on stdout) and waits for the answer on stdin. Vision decides it exactly as its own
// engine decides the same call under the chat's preset — and asks the person on the same permission card when the
// preset says ask. The same rules and words as Vision for Windows (ClaudeCodePermissions.cs).

/// A `can_use_tool` control request: Claude Code asks whether a tool call may run.
public struct ClaudeCodePermissionRequest: Sendable, Equatable {
    public var requestID: String
    public var toolName: String
    public var input: JSONValue?
    public var toolUseID: String?
    public var description: String?
    /// Why Claude Code escalated (a safety check's warning, a rule) — shown to the person, never trusted as an instruction.
    public var decisionReason: String?
    public var decisionReasonType: String?
    /// False: a safety check Claude Code says needs a person (a dangerous rm, a path that slips out of the folder).
    public var classifierApprovable: Bool?
    /// The tool's own card is the question (ExitPlanMode, AskUserQuestion): a plain yes/no doesn't fit it.
    public var requiresUserInteraction: Bool
    /// The call comes from one of Claude Code's subagents.
    public var agentID: String?

    public init(requestID: String, toolName: String, input: JSONValue? = nil, toolUseID: String? = nil,
                description: String? = nil, decisionReason: String? = nil, decisionReasonType: String? = nil,
                classifierApprovable: Bool? = nil, requiresUserInteraction: Bool = false, agentID: String? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.toolUseID = toolUseID
        self.description = description
        self.decisionReason = decisionReason
        self.decisionReasonType = decisionReasonType
        self.classifierApprovable = classifierApprovable
        self.requiresUserInteraction = requiresUserInteraction
        self.agentID = agentID
    }

    /// The request in a `control_request` line, or nil for any other line.
    public static func from(_ line: JSONValue) -> ClaudeCodePermissionRequest? {
        guard line["type"]?.string == "control_request", let request = line["request"],
              request["subtype"]?.string == "can_use_tool" else { return nil }
        func str(_ value: JSONValue?) -> String? { value?.string.flatMap { $0.isEmpty ? nil : $0 } }
        return ClaudeCodePermissionRequest(
            requestID: str(line["request_id"]) ?? "", toolName: str(request["tool_name"]) ?? "", input: request["input"],
            toolUseID: str(request["tool_use_id"]), description: str(request["description"]),
            decisionReason: str(request["decision_reason"]), decisionReasonType: str(request["decision_reason_type"]),
            classifierApprovable: request["classifier_approvable"]?.bool,
            requiresUserInteraction: request["requires_user_interaction"]?.bool ?? false,
            agentID: str(request["agent_id"]))
    }
}

/// What Vision answers a permission question with.
public enum ClaudeCodePermissionDecision: Sendable, Equatable {
    case allow
    case deny(String)
    /// Ask the person: `name` is the tool as Vision names it (its card's icon and label), `detail` what exactly would happen.
    case ask(name: String, detail: String)
}

public enum ClaudeCodePermissions {
    /// What Claude Code is told when its plan has been shown (Plan only chats).
    public static let planShown = "Your plan is shown to the person in Vision's plan panel. Stop here and wait for them — don't start the work."

    /// What Claude Code is told when it tries to ask a multiple-choice question Vision can't show.
    public static let askInReply = "Vision can't show this kind of question. Ask it in your reply instead — the person answers in the chat."

    /// What Claude Code is told when the person (or an unattended run's timeout) says no.
    public static let declined = "The person declined this in Vision. Don't retry it; carry on another way or say what you needed."

    /// Decide a permission question the way Vision's own engine decides the same call under the chat's preset: reads
    /// and web fetches go ahead; writes go ahead inside the project (Workspace write) or always (Full access) and ask
    /// otherwise; commands that only read go ahead, ones that could change something ask (Workspace write); anything
    /// Vision doesn't know asks — except under Full access. A safety check Claude Code says needs a person always asks.
    public static func decide(_ request: ClaudeCodePermissionRequest, policy: PermissionPolicy) -> ClaudeCodePermissionDecision {
        let tool = request.toolName
        let input = request.input
        let visionName = ClaudeCodeTools.visionName(tool)
        let needsPerson = request.decisionReasonType == "safetyCheck" || request.classifierApprovable == false
        let why = request.decisionReason.map { " — Claude Code says: " + ClaudeCodeTools.prefix(stripANSI($0), 200) } ?? ""

        switch tool {
        case "ExitPlanMode":
            return policy.preset == .plan ? .deny(planShown) : .allow
        case "AskUserQuestion":
            return .deny(askInReply)
        default:
            break
        }
        if request.requiresUserInteraction {
            return .ask(name: visionName, detail: "\(ClaudeCodeTools.label(tool)): \(ClaudeCodeTools.preview(tool, input))\(why)")
        }

        let decision: PermissionDecision
        let detail: String
        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let raw = input?["file_path"]?.string ?? input?["notebook_path"]?.string ?? ""
            decision = policy.checkWrite(path: raw)
            detail = "\(policy.preset == .plan ? "Write" : "Write outside the project"): \(policy.resolve(raw).url.path)"
        case "Bash", "PowerShell":
            let command = input?["command"]?.string ?? ""
            decision = policy.checkShell(command: command)
            detail = "Run command: \(command)"
        case "Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "TodoWrite", "Task", "Agent", "Skill",
             "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "ToolSearch":
            decision = .proceed
            detail = ""
        default:
            decision = policy.preset == .fullAccess ? .proceed : .ask
            detail = "Use \(ClaudeCodeTools.label(tool)): \(ClaudeCodeTools.preview(tool, input))"
        }
        if case .deny(let reason) = decision { return .deny(reason.isEmpty ? declined : reason) }
        var asks = needsPerson
        if case .ask = decision { asks = true }
        if asks {
            let what = detail.isEmpty ? "Use \(ClaudeCodeTools.label(tool)): \(ClaudeCodeTools.preview(tool, input))" : detail
            return .ask(name: visionName, detail: what + why)
        }
        return .allow
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
