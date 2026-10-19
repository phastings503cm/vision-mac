import Foundation

// MARK: - Bringing in the MCP servers other apps already have
//
// The servers configured for Claude Code (`~/.claude.json`: its own `mcpServers` and the project's under
// `projects[<folder>]`; a project's `.mcp.json`), Claude Desktop (`claude_desktop_config.json`) and Cursor
// (`~/.cursor/mcp.json`, a project's `.cursor/mcp.json`). Each file has the same shape:
//
//   { "mcpServers": { "github": { "command": "npx", "args": ["-y", "…"], "env": { "GITHUB_TOKEN": "…" } },
//                     "docs":   { "type": "http", "url": "https://…/mcp", "headers": { "Authorization": "Bearer …" } } } }
//
// Nothing is started while looking. Importing copies a server into Vision's list; its environment and header values
// go to the Keychain. A value like `${GITHUB_TOKEN}` is kept as written and filled in from the environment when the
// server starts, as Claude Code does.

public struct MCPImportCandidate: Sendable, Identifiable, Hashable {
    /// The server as it would be added (its secrets' names only).
    public var config: MCPServerConfig
    /// Its environment variables' and headers' values (they go to the Keychain on import).
    public var environment: [String: String]
    public var headers: [String: String]
    /// The file it was read from.
    public var origin: String
    /// Why it may not work in Vision (an SSE server); nil = fine.
    public var caveat: String?

    public var id: String { (config.source ?? "") + "/" + config.name + "/" + origin }

    /// What makes two servers the same one: how it starts or where it is.
    public var fingerprint: String { config.transport.rawValue + "|" + config.summary }
}

public enum MCPImport {
    /// The files looked at, with the label each import is marked with.
    public static func sources(home: URL, project: URL?) -> [(label: String, file: URL, projectKey: String?)] {
        var out: [(String, URL, String?)] = [
            ("Claude Code", home.appendingPathComponent(".claude.json"), project?.standardizedFileURL.path),
            ("Claude Desktop", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), nil),
            ("Cursor", home.appendingPathComponent(".cursor/mcp.json"), nil),
        ]
        if let project {
            out.append(("Claude Code (this project)", project.appendingPathComponent(".mcp.json"), nil))
            out.append(("Cursor (this project)", project.appendingPathComponent(".cursor/mcp.json"), nil))
        }
        return out
    }

    /// Every server those files configure (none is started).
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                project: URL?) -> [MCPImportCandidate] {
        var out: [MCPImportCandidate] = []
        for source in sources(home: home, project: project) {
            guard let data = try? Data(contentsOf: source.file), let json = JSONValue(parsing: data) else { continue }
            out += candidates(in: json["mcpServers"], source: source.label, origin: source.file.path)
            // Claude Code keeps a project's own servers inside ~/.claude.json, under its folder.
            if let key = source.projectKey, let projects = json["projects"]?.object {
                for (path, entry) in projects where URL(fileURLWithPath: path).standardizedFileURL.path == key {
                    out += candidates(in: entry["mcpServers"], source: source.label + " (this project)",
                                      origin: source.file.path)
                }
            }
        }
        return out
    }

    /// The servers in one `mcpServers` object.
    public static func candidates(in servers: JSONValue?, source: String, origin: String) -> [MCPImportCandidate] {
        guard let servers = servers?.object else { return [] }
        return servers.sorted { $0.key < $1.key }.compactMap { name, entry in
            candidate(name: name, entry: entry, source: source, origin: origin)
        }
    }

    static func stringMap(_ value: JSONValue?) -> [String: String] {
        var out: [String: String] = [:]
        for (key, item) in value?.object ?? [:] {
            switch item {
            case .string(let text): out[key] = text
            case .number, .bool: out[key] = item.serialized()
            default: continue
            }
        }
        return out
    }

    static func candidate(name: String, entry: JSONValue, source: String, origin: String) -> MCPImportCandidate? {
        guard entry.object != nil else { return nil }
        let type = entry["type"]?.string?.lowercased() ?? entry["transport"]?.string?.lowercased()
        let url = entry["url"]?.string ?? entry["serverUrl"]?.string
        let command = entry["command"]?.string
        let enabled = !(entry["disabled"]?.bool ?? false) && (entry["enabled"]?.bool ?? true)
        var caveat: String?
        var config: MCPServerConfig
        var environment: [String: String] = [:], headers: [String: String] = [:]
        if let url, type != "stdio", command == nil || type != nil {
            if type == "sse" {
                caveat = "It uses the older SSE transport; Vision speaks Streamable HTTP, which many such servers also "
                    + "offer at the same address (or at /mcp)."
            }
            headers = stringMap(entry["headers"])
            config = MCPServerConfig(name: name, transport: .http, url: url, headerNames: headers.keys.sorted(),
                                     enabled: enabled, source: source, note: caveat)
        } else if let command, !command.isEmpty {
            environment = stringMap(entry["env"])
            let args = (entry["args"]?.array ?? []).compactMap { item -> String? in
                if case .string(let text) = item { return text }
                if case .number = item { return item.serialized() }
                return nil
            }
            config = MCPServerConfig(name: name, transport: .stdio, command: command, args: args,
                                     cwd: entry["cwd"]?.string, envNames: environment.keys.sorted(),
                                     enabled: enabled, source: source)
        } else {
            return nil
        }
        return MCPImportCandidate(config: config, environment: environment, headers: headers, origin: origin,
                                  caveat: caveat)
    }

    /// Whether a candidate is a server Vision already has (it starts the same way, or is at the same address).
    public static func isKnown(_ candidate: MCPImportCandidate, among existing: [MCPServerConfig]) -> Bool {
        existing.contains { $0.transport == candidate.config.transport && $0.summary == candidate.config.summary }
    }

    /// A name for an imported server that doesn't clash with one already there ("github", "github-2", …).
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let base = MCPNames.sanitize(name).isEmpty ? "server" : MCPNames.sanitize(name)
        var candidate = base
        var n = 2
        let lowered = Set(taken.map { $0.lowercased() })
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// `${VAR}` and `${VAR:-default}` filled in from `environment` (unknown ones become empty, or the default).
    public static func expand(_ text: String, environment: [String: String]) -> String {
        guard text.contains("${") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let body = String(rest[open.upperBound..<close])
            if let dash = body.range(of: ":-") {
                let name = String(body[..<dash.lowerBound])
                let fallback = String(body[dash.upperBound...])
                let value = environment[name] ?? ""
                out += value.isEmpty ? fallback : value
            } else {
                out += environment[body] ?? ""
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
