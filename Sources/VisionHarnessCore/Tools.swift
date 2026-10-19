import Foundation

// MARK: - Tool context / results

/// What a tool may touch while executing. Value-type, Sendable, no closures:
/// tools report side effects via `ToolResult` instead of callbacks.
public struct ToolContext: Sendable {
    public let workspace: URL
    public let policy: PermissionPolicy
    /// The live model client, so the `agent` tool can spawn a subagent.
    public let client: any LLMClient
    /// The registry, so the subagent gets the same capabilities.
    public let registry: ToolRegistry
    /// 0 = top-level session. Bounded to keep recursion sane.
    public let depth: Int
    /// Model id subagents should use (same as the parent session).
    public let model: String
    /// The parent's resolved context window (server probe, override, or
    /// fallback), so a subagent budgets auto-compaction against the real
    /// window instead of running uncompacted until it hits a hard wall.
    public let contextWindow: Int?
    /// The parent's thinking level, so subagents think as hard as it does.
    public let thinking: ThinkingLevel?
    /// Asks the user for permission; subagents inherit the parent's hook.
    public let requestPermission: @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool
    /// The credential vault and this chat's "ask first" approvals, so a
    /// subagent can use `{{vault:NAME}}` exactly like its parent.
    public let vault: CredentialVault?
    public let vaultGrants: VaultGrants
    /// Background subagents this chat has launched (`agent` with
    /// run_in_background, `agent_status`, `agent_stop`). Nil for subagents.
    public let backgroundAgents: BackgroundAgents?
    /// The model servers subagents run on (workers first, the primary as
    /// overflow). Nil = a subagent uses this run's own client.
    public let fleet: AgentFleet?
    /// This chat's own server, which stands in for the fleet's primary (see `AgentFleet.acquire`). Nil = the
    /// configured primary.
    public let fleetHome: FleetServer?
    /// Every subagent this chat has started, for the UI. Nil = not tracked.
    public let roster: AgentRoster?
    /// The kinds of subagent available (nil = the built-in ones).
    public let agentTypes: AgentCatalog?
    /// How the parent retries a model that doesn't answer; subagents follow it
    /// (nil = the standard policy).
    public let retry: RetryPolicy?
    /// The parent's model settings, which a subagent on the same server shares
    /// (a subagent on another server uses that server's — see `FleetTarget`).
    public let visionEnabled: Bool
    public let temperature: Double?
    public let maxOutputTokens: Int?
    /// The run is unattended work (a queue task, `/goal`): subagents keep off servers whose plans allow
    /// interactive use only.
    public let unattended: Bool

    public init(workspace: URL, policy: PermissionPolicy,
                client: any LLMClient, registry: ToolRegistry, depth: Int = 0,
                model: String = "", contextWindow: Int? = nil, thinking: ThinkingLevel? = nil,
                requestPermission: @escaping @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool = { _, _, _ in true },
                vault: CredentialVault? = nil, vaultGrants: VaultGrants = VaultGrants(),
                backgroundAgents: BackgroundAgents? = nil,
                fleet: AgentFleet? = nil, roster: AgentRoster? = nil, agentTypes: AgentCatalog? = nil,
                retry: RetryPolicy? = nil, visionEnabled: Bool = true,
                temperature: Double? = nil, maxOutputTokens: Int? = nil, unattended: Bool = false,
                fleetHome: FleetServer? = nil) {
        self.workspace = workspace
        self.fleetHome = fleetHome
        self.policy = policy
        self.client = client
        self.registry = registry
        self.depth = depth
        self.model = model
        self.contextWindow = contextWindow
        self.thinking = thinking
        self.requestPermission = requestPermission
        self.vault = vault
        self.vaultGrants = vaultGrants
        self.backgroundAgents = backgroundAgents
        self.fleet = fleet
        self.roster = roster
        self.agentTypes = agentTypes
        self.retry = retry
        self.visionEnabled = visionEnabled
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.unattended = unattended
    }
}

/// A side effect the UI can observe (editor auto-reload, "produced files" chips).
public struct FileChange: Hashable, Sendable {
    public enum Kind: String, Sendable { case created, modified, deleted }
    public let url: URL
    public let kind: Kind

    public init(_ url: URL, _ kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// One structured todo, as the `todo_write` tool manages them.
public struct TodoItem: Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress = "in_progress", completed
    }
    public let id: String
    public var content: String
    public var status: Status

    public init(id: String, content: String, status: Status = .pending) {
        self.id = id
        self.content = content
        self.status = status
    }
}

/// The outcome of executing one tool call.
public struct ToolResult: Sendable {
    public let output: String
    public var files: [FileChange]
    public var todos: [TodoItem]?   // nil = this call did not manage todos
    /// Images the tool produced (screenshots, frames, viewed files). The engine
    /// hands them to the model in a follow-up message: chat-completion tool
    /// messages are text-only, so images ride on an attached user message.
    public var images: [MessageAttachment]

    public init(output: String, files: [FileChange] = [], todos: [TodoItem]? = nil,
                images: [MessageAttachment] = []) {
        self.output = output
        self.files = files
        self.todos = todos
        self.images = images
    }
}

// MARK: - Executor protocol

/// A concrete tool implementation. Stateless value types keep Swift 6 happy.
public protocol ToolExecutor: Sendable {
    /// Stable name — matches the Qwen Code tool names.
    static var name: String { get }
    /// The OpenAI-shape tool spec sent to the model.
    static var spec: ToolSpec { get }
    /// Instance-level identity. Built-ins inherit it from the statics; tools
    /// whose name is data rather than a type (plugins) override it.
    var name: String { get }
    var spec: ToolSpec { get }
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult
}

extension ToolExecutor {
    public var name: String { Self.name }
    public var spec: ToolSpec { Self.spec }
}

extension ToolExecutor {
    /// Decode arguments into a `[String: String]`-ish bag.
    /// Concrete-type access only; use `JSONArgs` at dynamic call sites.
    internal static func string(_ json: JSONString, _ key: String) -> String? {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict[key] as? String
    }
    internal static func int(_ json: JSONString, _ key: String, default def: Int) -> Int {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let n = dict[key] as? Int { return n }
        if let d = dict[key] as? Double { return Int(d) }
        return def
    }
    internal static func bool(_ json: JSONString, _ key: String, default def: Bool) -> Bool {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        return (dict[key] as? Bool) ?? def
    }
    internal static func dict(_ json: JSONString) -> [String: Any] {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return (obj as? [String: Any]) ?? [:]
    }
}

/// Argument-reader namespace. Callers holding an `any ToolExecutor` (or a
/// protocol metatype) can't reach the `ToolExecutor` extension's statics,
/// so these equivalents live on a concrete enum.
public enum JSONArgs {
    public static func string(_ json: JSONString, _ key: String) -> String? {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict[key] as? String
    }
    public static func int(_ json: JSONString, _ key: String, default def: Int) -> Int {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let n = dict[key] as? Int { return n }
        if let d = dict[key] as? Double { return Int(d) }
        return def
    }
    public static func bool(_ json: JSONString, _ key: String, default def: Bool) -> Bool {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        return (dict[key] as? Bool) ?? def
    }
    public static func dictionary(_ json: JSONString) -> [String: Any] {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return (obj as? [String: Any]) ?? [:]
    }
}

// MARK: - Registry

public struct ToolRegistry: Sendable {
    private let tools: [any ToolExecutor]

    public init(tools: [any ToolExecutor]) {
        self.tools = tools
    }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public var names: [String] { tools.map(\.name) }

    public func tool(named name: String) -> (any ToolExecutor)? {
        tools.first { $0.name == name }
    }

    /// A copy of this registry with extra tools appended (plugin contributions).
    public func adding(_ extra: [any ToolExecutor]) -> ToolRegistry {
        ToolRegistry(tools: tools + extra)
    }

    /// A copy without the named tools (subagents lose `agent`).
    public func removing(_ names: String...) -> ToolRegistry {
        removing(names)
    }

    /// A copy without the named tools.
    public func removing(_ names: [String]) -> ToolRegistry {
        ToolRegistry(tools: tools.filter { !names.contains($0.name) })
    }

    /// A copy with only the named tools (an agent type's allow list).
    public func only(_ names: [String]) -> ToolRegistry {
        ToolRegistry(tools: tools.filter { names.contains($0.name) })
    }

    /// A copy with every tool replaced by `transform` of it.
    func mapping(_ transform: (any ToolExecutor) -> any ToolExecutor) -> ToolRegistry {
        ToolRegistry(tools: tools.map(transform))
    }

    /// The built-in tool set. `agents` are the agent types the `agent` and `delegate` tools offer in their
    /// descriptions (nil = the built-in ones); `servers`, the subagent servers and their privacy, which they name.
    public static func standard(depth: Int = 0, agents: AgentCatalog? = nil,
                                servers: [SubagentServers.Entry]? = nil) -> ToolRegistry {
        // `agent` and `delegate` are only offered at the top level: subagents don't spawn
        // subagents (keeps the permission surface and cost predictable).
        var tools: [any ToolExecutor] = [
            ReadFileTool(), WriteFileTool(), EditTool(), ListDirectoryTool(),
            ReadManyFilesTool(), GlobTool(), GrepTool(),
            RunShellCommandTool(), WebFetchTool(), TodoWriteTool(), ExitPlanModeTool(),
        ]
        if depth == 0 {
            tools.append(AgentTool(catalog: agents, servers: servers))
            tools.append(DelegateTool(catalog: agents, servers: servers))
        }
        return ToolRegistry(tools: tools)
    }

    /// Tools for background subagents (the `agent` tool starts them with
    /// run_in_background). Added by the app next to a `BackgroundAgents` pool.
    public static func backgroundAgentTools() -> [any ToolExecutor] {
        [AgentStatusTool(), AgentStopTool()]
    }

    /// Background-process tools. Separate from `standard()` so existing test
    /// registries stay deterministic and the app decides policy; permissions
    /// ride through Engine.checkPermission (shell gate) and ComputerGrants.
    public static func processes() -> [any ToolExecutor] {
        [ProcessStartTool(), ProcessReadTool(), ProcessWriteTool(), ProcessStopTool(), ProcessListTool()]
    }

    /// See/steer-the-machine tools (screenshots, windows, events). Gated by
    /// the computerToolsEnabled setting in the app and by the per-chat
    /// observe/control grants inside the engine.
    public static func machineTools() -> [any ToolExecutor] {
        [ScreenshotTool(), ListWindowsTool(), ScreenWatchTool(), UITreeTool(),
         InspectProcessTool(), MouseTool(), KeyboardTool(), FocusAppTool(), ViewImageTool()]
    }
}