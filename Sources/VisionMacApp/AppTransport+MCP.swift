import Foundation
import VisionHarnessCore

// MARK: - MCP servers in the app
//
// The list (Settings ▸ MCP Servers) is saved in `mcp-servers.json` in the app's data folder, its secrets in the
// Keychain; the manager keeps the enabled servers connected, and every chat's tool list carries their tools. See
// `MCPManager` for the protocol side.

/// The app's MCP list and manager, one per data folder.
@MainActor
final class MCPHub {
    let store: MCPServerStore
    let manager: MCPManager
    private(set) var servers: [MCPServerConfig]
    private var started = false

    private static var hubs: [String: MCPHub] = [:]

    static func at(_ appSupport: URL, secrets: any SecretStore) -> MCPHub {
        if let hub = hubs[appSupport.path] { return hub }
        let hub = MCPHub(store: MCPServerStore(fileURL: appSupport.appendingPathComponent("mcp-servers.json"), secrets: secrets))
        hubs[appSupport.path] = hub
        return hub
    }

    private init(store: MCPServerStore) {
        self.store = store
        self.manager = MCPManager(connector: MCPManager.connector(store: store, projectFolder: { nil }))
        self.servers = store.load()
    }

    /// Connect the enabled servers (once; later changes go through `set`).
    func startIfNeeded() {
        guard !started else { return }
        started = true
        manager.apply(servers)
    }

    func set(_ servers: [MCPServerConfig]) {
        self.servers = servers
        store.save(servers)
        started = true
        manager.apply(servers)
    }
}

extension AppTransport {
    var mcpHub: MCPHub { MCPHub.at(skillLocations.appSupport, secrets: config.secrets) }

    /// Connect the enabled MCP servers (at launch), and follow their changes.
    public func startMCP() {
        let hub = mcpHub
        hub.manager.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.mcpRevision += 1 }
        }
        hub.startIfNeeded()
    }

    /// The servers as configured, and how each is doing.
    public var mcpServers: [MCPServerConfig] { mcpHub.servers }
    public func mcpState(_ id: String) -> MCPManager.ServerState? { mcpHub.manager.state(id) }

    /// The MCP tools for a chat's tool list (names already taken are skipped).
    func mcpTools(reserved: Set<String>) -> [any ToolExecutor] {
        mcpHub.manager.tools(reserved: reserved)
    }

    /// Changes whenever a server connects, fails or changes its tools (a chat's engine is rebuilt on it).
    var mcpToolsRevision: Int { mcpHub.manager.revision }

    var mcpPromptNote: String? { mcpHub.manager.promptNote }

    /// Add a server, or save changes to one, with its environment and header values (they go to the Keychain).
    public func saveMCPServer(_ server: MCPServerConfig, environment: [String: String], headers: [String: String]) {
        var server = server
        server.envNames = environment.keys.sorted()
        server.headerNames = headers.keys.sorted()
        var list = mcpHub.servers
        let previous = list.first { $0.id == server.id }
        mcpHub.store.setSecrets(for: server, environment: environment, headers: headers, previous: previous)
        if let index = list.firstIndex(where: { $0.id == server.id }) { list[index] = server } else { list.append(server) }
        mcpHub.set(list)
        // The same command (which `set` doesn't restart) may have new secrets: start it again with them.
        if let previous, previous.enabled, server.enabled, !MCPManager.needsRestart(previous, server) {
            mcpHub.manager.reconnect(server.id)
        }
    }

    public func removeMCPServer(_ id: String) {
        guard let server = mcpHub.servers.first(where: { $0.id == id }) else { return }
        mcpHub.store.removeSecrets(for: server)
        mcpHub.set(mcpHub.servers.filter { $0.id != id })
    }

    public func setMCPServerEnabled(_ id: String, _ on: Bool) {
        var list = mcpHub.servers
        guard let index = list.firstIndex(where: { $0.id == id }), list[index].enabled != on else { return }
        list[index].enabled = on
        mcpHub.set(list)
    }

    public func setMCPServerTrust(_ id: String, _ trust: MCPServerConfig.Trust) {
        var list = mcpHub.servers
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].trust = trust
        mcpHub.set(list)
    }

    public func setMCPTool(_ tool: String, enabled: Bool, server id: String) {
        var list = mcpHub.servers
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].disabledTools.removeAll { $0 == tool }
        if !enabled { list[index].disabledTools.append(tool) }
        mcpHub.set(list)
    }

    public func reconnectMCPServer(_ id: String) { mcpHub.manager.reconnect(id) }

    public func mcpEnvironment(_ server: MCPServerConfig) -> [String: String] { mcpHub.store.environment(for: server) }
    public func mcpHeaders(_ server: MCPServerConfig) -> [String: String] { mcpHub.store.headers(for: server) }

    /// The servers Claude Code, Claude Desktop and Cursor have configured (for this project too).
    public func discoverMCPImports() -> [MCPImportCandidate] {
        MCPImport.discover(home: skillLocations.home, project: projectContext?.root)
    }

    /// Import the chosen servers: a name already in use gets a number; a project's server starts in that project.
    @discardableResult
    public func importMCP(_ candidates: [MCPImportCandidate]) -> [MCPServerConfig] {
        var list = mcpHub.servers
        var taken = Set(list.map(\.name))
        var added: [MCPServerConfig] = []
        for candidate in candidates where !MCPImport.isKnown(candidate, among: list) {
            var server = candidate.config
            server.id = UUID().uuidString
            server.name = MCPImport.uniqueName(server.name, taken: taken)
            if server.transport == .stdio, server.cwd == nil, (candidate.config.source ?? "").contains("this project") {
                server.cwd = projectContext?.root.path
            }
            taken.insert(server.name)
            mcpHub.store.setSecrets(for: server, environment: candidate.environment, headers: candidate.headers)
            list.append(server)
            added.append(server)
        }
        if !added.isEmpty { mcpHub.set(list) }
        return added
    }

    /// `/mcp`: the servers and their tools; `/mcp reload` reconnects them.
    func mcpCommand(_ arg: String?, vm: SessionVM) {
        let servers = mcpHub.servers
        if arg?.lowercased() == "reload" {
            for server in servers where server.enabled { mcpHub.manager.reconnect(server.id) }
            vm.note("Reconnecting \(servers.filter(\.enabled).count) MCP server(s)…")
            return
        }
        guard !servers.isEmpty else {
            vm.note("No MCP servers yet. Add one, or import the ones Claude Code, Claude Desktop or Cursor already have, "
                    + "in Settings ▸ MCP Servers.")
            return
        }
        let lines = servers.map { server -> String in
            let state = mcpHub.manager.state(server.id)
            let status = server.enabled ? (state?.status.label ?? "Off") : "Switched off"
            let tools = state?.tools.filter { !server.disabledTools.contains($0.name) }.map(\.name) ?? []
            return "• **\(server.name)** — \(status)" + (tools.isEmpty ? "" : " · \(tools.count) tool\(tools.count == 1 ? "" : "s"): "
                + tools.prefix(8).joined(separator: ", ") + (tools.count > 8 ? " …" : ""))
        }
        vm.note("MCP servers:\n" + lines.joined(separator: "\n") + "\n\nTheir tools are offered as `mcp__<server>__<tool>`. "
                + "Settings ▸ MCP Servers adds, imports and switches them; `/mcp reload` reconnects them.")
    }
}
