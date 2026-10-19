import Foundation

// MARK: - The MCP servers in use, and their tools as the model's tools
//
// The manager keeps one session per enabled server: started when the list changes (or at launch), restarted once
// when a call finds it gone, stopped when the server is switched off or removed. Its tools become `MCPTool`s in every
// chat's tool list — `mcp__<server>__<tool>` — and a server with resources adds `mcp__<server>__resources`.

public final class MCPManager: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case off
        case connecting
        case ready
        case failed(String)

        public var label: String {
            switch self {
            case .off: "Off"
            case .connecting: "Connecting…"
            case .ready: "Connected"
            case .failed(let why): "Failed: \(why)"
            }
        }
    }

    /// One server as the settings show it.
    public struct ServerState: Sendable, Equatable, Identifiable {
        public var config: MCPServerConfig
        public var status: Status
        public var tools: [MCPToolInfo]
        public var hasResources: Bool
        public var id: String { config.id }
    }

    /// Makes the link to a server (the app's starts programs and opens URLs; tests use fakes). Nil = it can't.
    public typealias Connector = @Sendable (MCPServerConfig) -> (any MCPConnection)?

    private let lock = NSLock()
    private let connector: Connector
    private var configs: [String: MCPServerConfig] = [:]
    private var sessions: [String: MCPServerSession] = [:]
    private var states: [String: ServerState] = [:]
    private var starting: [String: Task<Void, Never>] = [:]
    private var _revision = 0
    private var _onChange: (@Sendable () -> Void)?

    public init(connector: @escaping Connector) {
        self.connector = connector
    }

    /// Called (off the main thread) when a server's status or tools change.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }

    /// Bumped on every change, so a chat rebuilds its tool list when it moves.
    public var revision: Int { lock.withLock { _revision } }

    public var serverStates: [ServerState] {
        lock.withLock { Array(states.values) }.sorted { $0.config.name.lowercased() < $1.config.name.lowercased() }
    }

    public func state(_ id: String) -> ServerState? { lock.withLock { states[id] } }

    private func changed() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            _revision += 1
            return _onChange
        }
        callback?()
    }

    // MARK: The list

    /// Use this list: start what is new or changed, stop what is gone or switched off.
    public func apply(_ servers: [MCPServerConfig]) {
        let wanted = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var toStart: [MCPServerConfig] = []
        var toStop: [String] = []
        lock.withLock {
            for (id, old) in configs where wanted[id] == nil || !wanted[id]!.enabled || wanted[id]!.problem != nil
                || Self.needsRestart(old, wanted[id]!) {
                toStop.append(id)
            }
            for server in servers {
                let previous = configs[server.id]
                configs[server.id] = server
                if !server.enabled || server.problem != nil {
                    states[server.id] = ServerState(config: server, status: server.problem.map { .failed($0) } ?? .off,
                                                    tools: [], hasResources: false)
                } else if previous == nil || toStop.contains(server.id) || !previous!.enabled || states[server.id]?.status == .off {
                    toStart.append(server)
                } else if var state = states[server.id] {
                    state.config = server   // trust, disabled tools, note: no restart needed
                    states[server.id] = state
                }
            }
            for id in configs.keys where wanted[id] == nil {
                configs[id] = nil
                states[id] = nil
            }
        }
        for id in toStop { stop(id) }
        for server in toStart { start(server) }
        changed()
    }

    /// A change that needs the server started again (how it runs, not how it is used).
    public static func needsRestart(_ old: MCPServerConfig, _ new: MCPServerConfig) -> Bool {
        old.transport != new.transport || old.command != new.command || old.args != new.args || old.cwd != new.cwd
            || old.url != new.url || old.envNames != new.envNames || old.headerNames != new.headerNames
    }

    /// Start a server again (after its secrets changed, or from Reconnect).
    public func reconnect(_ id: String) {
        guard let config = lock.withLock({ configs[id] }), config.enabled, config.problem == nil else { return }
        stop(id)
        start(config)
        changed()
    }

    public func stopAll() {
        for id in lock.withLock({ Array(sessions.keys) }) { stop(id) }
    }

    private func stop(_ id: String) {
        let (task, session): (Task<Void, Never>?, MCPServerSession?) = lock.withLock {
            defer {
                starting[id] = nil
                sessions[id] = nil
            }
            return (starting[id], sessions[id])
        }
        task?.cancel()
        if let session { Task { await session.close() } }
    }

    private func start(_ config: MCPServerConfig) {
        lock.withLock {
            states[config.id] = ServerState(config: config, status: .connecting, tools: [], hasResources: false)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            _ = await self.connectNow(config)
        }
        lock.withLock { starting[config.id] = task }
    }

    /// Connect and shake hands; the session, or nil (the status says why).
    @discardableResult
    private func connectNow(_ config: MCPServerConfig) async -> MCPServerSession? {
        guard let connection = connector(config) else {
            setStatus(config.id, .failed("it can't be started"), tools: [], resources: false)
            return nil
        }
        let session = MCPServerSession(connection: connection)
        let id = config.id
        connection.onNotification = { [weak self, weak session] method, _ in
            guard method == "notifications/tools/list_changed", let session else { return }
            Task { [weak self] in
                try? await session.refreshTools()
                self?.setStatus(id, .ready, tools: session.tools, resources: session.hasResources)
            }
        }
        do {
            try await session.start()
            if Task.isCancelled { await session.close(); return nil }
            lock.withLock {
                sessions[id] = session
                starting[id] = nil
            }
            setStatus(id, .ready, tools: session.tools, resources: session.hasResources)
            return session
        } catch {
            await session.close()
            if Task.isCancelled { return nil }
            var why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let tail = connection.diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty, !why.contains(String(tail.suffix(60))) { why += " — " + String(tail.suffix(300)) }
            lock.withLock { starting[id] = nil }
            setStatus(id, .failed(why), tools: [], resources: false)
            return nil
        }
    }

    private func setStatus(_ id: String, _ status: Status, tools: [MCPToolInfo], resources: Bool) {
        let updated: Bool = lock.withLock {
            guard let config = configs[id] else { return false }
            states[id] = ServerState(config: config, status: status, tools: tools, hasResources: resources)
            return true
        }
        if updated { changed() }
    }

    // MARK: Calls

    /// The live session for a server: the running one, else started again (once).
    func session(_ id: String) async throws -> MCPServerSession {
        if let session = lock.withLock({ sessions[id] }), session.connection.isAlive { return session }
        guard let config = lock.withLock({ configs[id] }), config.enabled else {
            throw MCPError.notStarted("the server is switched off")
        }
        // A start already under way: wait for it.
        if let task = lock.withLock({ starting[id] }) {
            await task.value
            if let session = lock.withLock({ sessions[id] }), session.connection.isAlive { return session }
        }
        lock.withLock { sessions[id] = nil }
        setStatus(id, .connecting, tools: lock.withLock { states[id]?.tools ?? [] }, resources: false)
        guard let session = await connectNow(config) else {
            if case .failed(let why) = state(id)?.status { throw MCPError.notStarted(why) }
            throw MCPError.notStarted("it didn't connect")
        }
        return session
    }

    /// Call a tool; a server that went away (or forgot the session) is started again and asked once more.
    public func call(serverID: String, tool: String, arguments: JSONValue) async throws -> MCPCallResult {
        let first = try await session(serverID)
        do {
            return try await first.call(tool, arguments: arguments)
        } catch let error as MCPError {
            switch error {
            case .exited, .sessionExpired:
                lock.withLock { if sessions[serverID] === first { sessions[serverID] = nil } }
                await first.close()
                return try await session(serverID).call(tool, arguments: arguments)
            default:
                throw error
            }
        }
    }

    public func resources(serverID: String, uri: String?) async throws -> String {
        try await session(serverID).resources(uri: uri)
    }

    // MARK: Tools for the model

    /// Every ready server's tools as the model's tools, skipping names already taken.
    public func tools(reserved: Set<String>) -> [any ToolExecutor] {
        var taken = reserved
        var out: [any ToolExecutor] = []
        for state in serverStates where state.status == .ready && state.config.enabled {
            for tool in state.tools where !state.config.disabledTools.contains(tool.name) {
                let name = MCPNames.toolName(server: state.config.name, tool: tool.name)
                guard taken.insert(name).inserted else { continue }
                out.append(MCPTool(manager: self, server: state.config, info: tool, exposedName: name))
            }
            if state.hasResources {
                let name = MCPNames.toolName(server: state.config.name, tool: "resources")
                if taken.insert(name).inserted {
                    out.append(MCPTool(manager: self, server: state.config, info: nil, exposedName: name))
                }
            }
        }
        return out
    }

    /// For the system prompt: which MCP servers are connected (nil when none).
    public var promptNote: String? {
        let ready = serverStates.filter { $0.status == .ready && $0.config.enabled }
        guard !ready.isEmpty else { return nil }
        return "MCP servers connected (their tools are named mcp__<server>__<tool>): "
            + ready.map { "\($0.config.name) (\($0.tools.count) tool\($0.tools.count == 1 ? "" : "s"))" }.joined(separator: ", ")
            + ". Each call asks the user first unless they allowed that server."
    }

    // MARK: The app's connector

    /// Starts programs through the login shell and opens URLs, with the server's secrets from `store` and `${VAR}`
    /// filled in from the environment. `projectFolder` is where a program starts when the server names no folder.
    public static func connector(store: MCPServerStore, projectFolder: @escaping @Sendable () -> URL?) -> Connector {
        { config in
            let environment = ProcessInfo.processInfo.environment
            func expand(_ text: String) -> String { MCPImport.expand(text, environment: environment) }
            switch config.transport {
            case .stdio:
                guard let command = config.command.map(expand), !command.isEmpty else { return nil }
                let env = store.environment(for: config).mapValues(expand)
                let folder = config.cwd.map { URL(fileURLWithPath: (expand($0) as NSString).expandingTildeInPath) }
                    ?? projectFolder() ?? FileManager.default.homeDirectoryForCurrentUser
                return MCPStdioConnection(command: command, args: config.args.map(expand), environment: env,
                                          workingDirectory: folder)
            case .http:
                guard let raw = config.url.map(expand), let url = URL(string: raw) else { return nil }
                return MCPHTTPConnection(url: url, headers: store.headers(for: config).mapValues(expand))
            }
        }
    }
}

// MARK: - A server's tool, as one of the model's

public struct MCPTool: ToolExecutor {
    public static let name = "mcp"
    public static let spec = ToolSpec(name: "mcp", description: "", parameters: "{}")

    public let manager: MCPManager
    public let server: MCPServerConfig
    /// The tool; nil = the server's resources (list them, or read one by `uri`).
    public let info: MCPToolInfo?
    public let exposedName: String

    public var name: String { exposedName }

    public var spec: ToolSpec {
        let prefix = "[MCP server “\(server.name)”] "
        guard let info else {
            return ToolSpec(name: exposedName,
                            description: prefix + "List the server's resources, or read one by its uri.",
                            parameters: #"{"type":"object","properties":{"uri":{"type":"string","description":"The resource to read; leave out to list them"}}}"#)
        }
        let text = (info.description ?? info.title ?? info.name)
        return ToolSpec(name: exposedName, description: prefix + String(text.prefix(2_000)),
                        parameters: info.inputSchema.serialized())
    }

    /// Whether a call asks first: always, unless the chat has full access, the server is trusted, or the tool is
    /// read-only on a server trusted with read-only tools.
    public func needsApproval(_ context: ToolContext) -> Bool {
        if context.policy.preset == .fullAccess { return false }
        switch server.trust {
        case .always: return false
        case .readOnly: return !(info?.readOnly ?? true)
        case .ask: return true
        }
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let arguments = JSONValue(parsing: args.raw) ?? .object([:])
        if needsApproval(context) {
            var shown = arguments.serialized()
            if shown.count > 400 { shown = String(shown.prefix(400)) + "…" }
            let what = info.map { "its tool “\($0.name)”" } ?? "its resources"
            let approved = await context.requestPermission(
                "mcp-\(UUID().uuidString)", exposedName,
                "MCP server “\(server.name)” wants to run \(what) with \(shown)")
            guard approved else {
                return ToolResult(output: "Error: the user declined this MCP call. Don't retry it; say what you wanted it for.")
            }
        }
        // A local server's tool that isn't read-only may change files: in a git repository, the turn's checkpoint
        // works out which.
        let checkpoint = server.transport == .stdio && !(info?.readOnly ?? true) ? TurnCheckpoint.current : nil
        let baseline = await RunShellCommandTool.offPool { checkpoint?.gitBaseline(in: context.workspace) }
        let result = await run(args: args, arguments: arguments)
        if let checkpoint, let baseline {
            let tool = exposedName
            await RunShellCommandTool.offPool { checkpoint.recordGitChanges(since: baseline, by: tool) }
        }
        return result
    }

    private func run(args: JSONString, arguments: JSONValue) async -> ToolResult {
        do {
            guard let info else {
                let text = try await manager.resources(serverID: server.id, uri: JSONArgs.string(args, "uri"))
                return ToolResult(output: text)
            }
            let result = try await manager.call(serverID: server.id, tool: info.name, arguments: arguments)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isError { return ToolResult(output: "Error: " + (text.isEmpty ? "the tool reported an error." : text)) }
            return ToolResult(output: text.isEmpty ? "(no output)" : text, images: result.images)
        } catch is CancellationError {
            return ToolResult(output: "Error: cancelled by user.")
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ToolResult(output: "Error: MCP server “\(server.name)”: \(why)")
        }
    }
}
