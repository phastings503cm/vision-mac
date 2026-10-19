import Foundation

// MARK: - MCP servers: what is configured
//
// An MCP server (Model Context Protocol) offers tools — and sometimes resources — to the model. Vision talks to two
// kinds: a program it starts and speaks to over stdin/stdout (stdio), and a server at a URL (Streamable HTTP). Each
// server's tools are offered to the model as `mcp__<server>__<tool>`, behind the usual permission prompt.
//
// The list lives in `mcp-servers.json` in the app's data folder; the values of a server's environment variables and
// HTTP headers (API keys, tokens) live in the Keychain, one item each, never in the file. The Windows harness keeps
// the same file (its secrets in the Credential Manager).

public struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable, CaseIterable {
        /// A program Vision starts, spoken to over stdin/stdout.
        case stdio
        /// A server at a URL (Streamable HTTP).
        case http

        public var label: String { self == .stdio ? "Program (stdio)" : "URL (Streamable HTTP)" }
    }

    /// When its tools may run without asking.
    public enum Trust: String, Codable, Sendable, CaseIterable {
        /// Every call asks first (the default).
        case ask
        /// Tools the server marks read-only run without asking; the others ask.
        case readOnly
        /// Every tool runs without asking.
        case always

        public var label: String {
            switch self {
            case .ask: "Ask before every tool call"
            case .readOnly: "Read-only tools without asking"
            case .always: "All tools without asking"
            }
        }
    }

    public var id: String
    /// The name the model sees in front of its tools (`mcp__<name>__<tool>`).
    public var name: String
    public var transport: Transport
    /// stdio: the program and its arguments, and the folder it starts in (nil = the project's, else the home folder).
    public var command: String?
    public var args: [String]
    public var cwd: String?
    /// http: the server's address.
    public var url: String?
    /// The names of its environment variables (stdio) and HTTP headers (http); their values are in the Keychain.
    public var envNames: [String]
    public var headerNames: [String]
    public var enabled: Bool
    public var trust: Trust
    /// Where it was imported from ("Claude Code", "Cursor", …); nil = added in Vision.
    public var source: String?
    /// A word about it the settings show (an SSE server imported as Streamable HTTP, …).
    public var note: String?
    /// Tools it offers that aren't given to the model.
    public var disabledTools: [String]

    public init(id: String = UUID().uuidString, name: String, transport: Transport, command: String? = nil,
                args: [String] = [], cwd: String? = nil, url: String? = nil, envNames: [String] = [],
                headerNames: [String] = [], enabled: Bool = true, trust: Trust = .ask, source: String? = nil,
                note: String? = nil, disabledTools: [String] = []) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.cwd = cwd
        self.url = url
        self.envNames = envNames
        self.headerNames = headerNames
        self.enabled = enabled
        self.trust = trust
        self.source = source
        self.note = note
        self.disabledTools = disabledTools
    }

    public init(from decoder: Decoder) throws {
        // Every field but the essentials optional, so a file from another build still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        transport = try c.decodeIfPresent(Transport.self, forKey: .transport) ?? .stdio
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        envNames = try c.decodeIfPresent([String].self, forKey: .envNames) ?? []
        headerNames = try c.decodeIfPresent([String].self, forKey: .headerNames) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trust = try c.decodeIfPresent(Trust.self, forKey: .trust) ?? .ask
        source = try c.decodeIfPresent(String.self, forKey: .source)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        disabledTools = try c.decodeIfPresent([String].self, forKey: .disabledTools) ?? []
    }

    /// One line about where it runs: "npx -y @modelcontextprotocol/server-github" or the URL.
    public var summary: String {
        switch transport {
        case .stdio: ([command ?? ""] + args).filter { !$0.isEmpty }.joined(separator: " ")
        case .http: url ?? ""
        }
    }

    /// What is missing for it to start (nil = nothing).
    public var problem: String? {
        if MCPNames.sanitize(name).isEmpty { return "It needs a name." }
        switch transport {
        case .stdio:
            if (command ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return "It needs a program to run." }
        case .http:
            guard let url, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host != nil else { return "It needs an http(s) address." }
        }
        return nil
    }
}

/// Tool names as the model sees them.
public enum MCPNames {
    /// Tool names may hold letters, digits, `_` and `-`, up to 64 characters (OpenAI, Bedrock).
    public static let maxLength = 64

    public static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = String(raw.map { allowed.contains($0) ? $0 : "_" })
        return mapped.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// `mcp__<server>__<tool>`, shortened (with a stable tag) when longer than the limit.
    public static func toolName(server: String, tool: String) -> String {
        let name = "mcp__\(sanitize(server))__\(sanitize(tool))"
        guard name.count > maxLength else { return name }
        let tag = String(CheckpointStore.hash(Data(name.utf8)).prefix(6))
        return String(name.prefix(maxLength - 7)) + "_" + tag
    }
}

// MARK: - Saving the list, and its secrets

public struct MCPServerStore: Sendable {
    public let fileURL: URL
    public let secrets: any SecretStore
    /// Keychain service for the values of servers' environment variables and headers.
    public static let keychainService = "Vision.mcp"

    public init(fileURL: URL, secrets: any SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    private struct File: Codable {
        var version = 1
        var servers: [MCPServerConfig]
    }

    public func load() -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.servers
    }

    public func save(_ servers: [MCPServerConfig]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(servers: servers)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func account(_ server: String, _ kind: String, _ name: String) -> String { "\(server)/\(kind)/\(name)" }

    /// A server's environment variables, with their values.
    public func environment(for server: MCPServerConfig) -> [String: String] {
        var out: [String: String] = [:]
        for name in server.envNames {
            out[name] = secrets.read(service: Self.keychainService, account: Self.account(server.id, "env", name)) ?? ""
        }
        return out
    }

    /// A server's HTTP headers, with their values.
    public func headers(for server: MCPServerConfig) -> [String: String] {
        var out: [String: String] = [:]
        for name in server.headerNames {
            out[name] = secrets.read(service: Self.keychainService, account: Self.account(server.id, "header", name)) ?? ""
        }
        return out
    }

    /// Store a server's values (and forget those of names it no longer has).
    public func setSecrets(for server: MCPServerConfig, environment: [String: String], headers: [String: String],
                           previous: MCPServerConfig? = nil) {
        for name in previous?.envNames ?? [] where environment[name] == nil {
            secrets.write(nil, service: Self.keychainService, account: Self.account(server.id, "env", name))
        }
        for name in previous?.headerNames ?? [] where headers[name] == nil {
            secrets.write(nil, service: Self.keychainService, account: Self.account(server.id, "header", name))
        }
        for (name, value) in environment {
            secrets.write(value, service: Self.keychainService, account: Self.account(server.id, "env", name))
        }
        for (name, value) in headers {
            secrets.write(value, service: Self.keychainService, account: Self.account(server.id, "header", name))
        }
    }

    /// A removed server's values go too.
    public func removeSecrets(for server: MCPServerConfig) {
        for name in server.envNames {
            secrets.write(nil, service: Self.keychainService, account: Self.account(server.id, "env", name))
        }
        for name in server.headerNames {
            secrets.write(nil, service: Self.keychainService, account: Self.account(server.id, "header", name))
        }
    }
}
