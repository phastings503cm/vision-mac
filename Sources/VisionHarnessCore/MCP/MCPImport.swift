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
// go to the Keychain. A value like `${GITHUB_TOKEN}` is kept as written and filled in when the server starts, as
// Claude Code does — from Vision's environment, else (a program) from your login shell's (see `MCPLaunch`).
//
// A project's own files (`.mcp.json`, `.cursor/mcp.json`) come with the repository: whoever wrote it chose the program
// they run. Those servers are offered unchecked (unless you approved them in Claude Code — never when you declined
// them there: `~/.claude.json` keeps `enabledMcpjsonServers` / `disabledMcpjsonServers` per project) and are imported
// switched off, so nothing from a cloned repository runs before you have read what it runs.

public struct MCPImportCandidate: Sendable, Identifiable, Hashable {
    /// What Claude Code recorded about a project `.mcp.json` server.
    public enum Approval: String, Sendable, Hashable { case approved, declined }

    /// The server as it would be added (its secrets' names only).
    public var config: MCPServerConfig
    /// Its environment variables' and headers' values (they go to the Keychain on import).
    public var environment: [String: String]
    public var headers: [String: String]
    /// The file it was read from.
    public var origin: String
    /// Why it may not work in Vision (an SSE server); nil = fine.
    public var caveat: String?
    /// Read from a file inside the project folder (`.mcp.json`, `.cursor/mcp.json`): the repository chose it.
    public var fromRepository = false
    /// Whether you approved or declined it in Claude Code (project `.mcp.json` servers only); nil = never asked.
    public var approval: Approval?
    /// `${NAME}`s it uses that Vision's own environment doesn't have (an app opened from the Finder doesn't get the
    /// variables your shell profile sets).
    public var needs: [String] = []
    /// Its command line or address seems to hold a key, which would be kept as written, not in the Keychain.
    public var secretInPlainText = false

    public var id: String { (config.source ?? "") + "/" + config.name + "/" + origin }

    /// What makes two servers the same one: how it starts or where it is.
    public var fingerprint: String { config.transport.rawValue + "|" + config.summary }

    /// Checked when the import sheet opens: your own apps' servers, and a repository's only when you approved it in
    /// Claude Code.
    public var preselected: Bool { fromRepository ? approval == .approved : true }

    /// What the import sheet says under it (the SSE caveat, a repository's server, missing variables, keys in the
    /// command line), in that order.
    public var warnings: [String] {
        var out: [String] = []
        if let caveat { out.append(caveat) }
        if fromRepository {
            switch approval {
            case .declined?: out.append(MCPImport.declinedWarning)
            case .approved?: out.append(MCPImport.approvedWarning)
            case nil: out.append(MCPImport.repositoryWarning)
            }
        }
        if !needs.isEmpty { out.append(MCPImport.needsWarning(needs, transport: config.transport)) }
        if secretInPlainText { out.append(MCPImport.plainTextSecretWarning) }
        return out
    }
}

public enum MCPImport {
    /// The import sheet's words for a repository's server.
    public static let repositoryWarning =
        "From the project's own files: whoever wrote the repository chose what it runs. It is imported switched off — "
        + "read its command first, then turn it on."
    public static let approvedWarning =
        "From the project's own files (you approved it in Claude Code). It is imported switched off — check its "
        + "command, then turn it on."
    public static let declinedWarning =
        "From the project's own files, and you declined it in Claude Code. Import it only if you've changed your mind; "
        + "it is imported switched off."
    public static let plainTextSecretWarning =
        "Its command line or address seems to hold a key or token. Vision keeps those as written in mcp-servers.json, "
        + "not in the Keychain — after importing, move the key into an environment variable (or a header) in "
        + "Settings ▸ MCP Servers."

    /// "Needs GITHUB_TOKEN: …" — where a `${NAME}` Vision can't see will come from.
    public static func needsWarning(_ names: [String], transport: MCPServerConfig.Transport) -> String {
        let list = names.joined(separator: ", ")
        switch transport {
        case .stdio:
            return "Needs \(list): Vision doesn't have \(names.count == 1 ? "it" : "them"), so \(names.count == 1 ? "it comes" : "they come") "
                + "from your login shell (~/.zprofile) when the server starts — or put the value in the server's "
                + "environment in Settings ▸ MCP Servers."
        case .http:
            return "Needs \(list): Vision doesn't have \(names.count == 1 ? "it" : "them") — put the value in the server's "
                + "header in Settings ▸ MCP Servers."
        }
    }

    /// The files looked at, with the label each import is marked with, and whether the file is the project's own
    /// (it comes with the repository).
    public static func sources(home: URL, project: URL?)
        -> [(label: String, file: URL, projectKey: String?, inRepository: Bool)] {
        var out: [(String, URL, String?, Bool)] = [
            ("Claude Code", home.appendingPathComponent(".claude.json"), project?.standardizedFileURL.path, false),
            ("Claude Desktop", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), nil, false),
            ("Cursor", home.appendingPathComponent(".cursor/mcp.json"), nil, false),
        ]
        if let project {
            out.append(("Claude Code (this project)", project.appendingPathComponent(".mcp.json"), nil, true))
            out.append(("Cursor (this project)", project.appendingPathComponent(".cursor/mcp.json"), nil, true))
        }
        return out
    }

    /// Which of a project's `.mcp.json` servers you approved and declined in Claude Code (`~/.claude.json`,
    /// `projects[<folder>].enabledMcpjsonServers` / `disabledMcpjsonServers`).
    public static func claudeCodeApprovals(home: URL, project: URL?) -> (approved: Set<String>, declined: Set<String>) {
        guard let project, let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let projects = JSONValue(parsing: data)?["projects"]?.object else { return ([], []) }
        let key = project.standardizedFileURL.path
        var approved = Set<String>(), declined = Set<String>()
        for (path, entry) in projects where URL(fileURLWithPath: path).standardizedFileURL.path == key {
            approved.formUnion((entry["enabledMcpjsonServers"]?.array ?? []).compactMap(\.string))
            declined.formUnion((entry["disabledMcpjsonServers"]?.array ?? []).compactMap(\.string))
        }
        return (approved, declined)
    }

    /// Every server those files configure (none is started). `environment` is Vision's own, for the `${NAME}`s it
    /// lacks.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                project: URL?,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [MCPImportCandidate] {
        var out: [MCPImportCandidate] = []
        let approvals = claudeCodeApprovals(home: home, project: project)
        for source in sources(home: home, project: project) {
            guard let data = try? Data(contentsOf: source.file), let json = JSONValue(parsing: data) else { continue }
            var found = candidates(in: json["mcpServers"], source: source.label, origin: source.file.path)
            if source.inRepository {
                for index in found.indices {
                    found[index].fromRepository = true
                    // Claude Code asks about `.mcp.json` servers only (Cursor keeps no such record).
                    guard source.file.lastPathComponent == ".mcp.json" else { continue }
                    let name = found[index].config.name
                    found[index].approval = approvals.declined.contains(name) ? .declined
                        : approvals.approved.contains(name) ? .approved : nil
                }
            }
            out += found
            // Claude Code keeps a project's own servers inside ~/.claude.json, under its folder (you added them).
            if let key = source.projectKey, let projects = json["projects"]?.object {
                for (path, entry) in projects where URL(fileURLWithPath: path).standardizedFileURL.path == key {
                    out += candidates(in: entry["mcpServers"], source: source.label + " (this project)",
                                      origin: source.file.path)
                }
            }
        }
        for index in out.indices {
            out[index].needs = missingVariables(out[index], environment: environment)
            out[index].secretInPlainText = holdsSecretInPlainText(out[index].config)
        }
        return out
    }

    // MARK: Placeholders and keys

    /// The `${NAME}` / `${NAME:-default}` references in a text, in order (name, and whether it has a default).
    public static func placeholders(in text: String) -> [(name: String, hasDefault: Bool)] {
        var out: [(String, Bool)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "${") {
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { break }
            let body = rest[open.upperBound..<close]
            if let dash = body.range(of: ":-") {
                out.append((String(body[..<dash.lowerBound]), true))
            } else {
                out.append((String(body), false))
            }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// The names a candidate refers to (without a default) that `environment` lacks or has empty.
    static func missingVariables(_ candidate: MCPImportCandidate, environment: [String: String]) -> [String] {
        let config = candidate.config
        let texts = [config.command, config.url, config.cwd].compactMap { $0 } + config.args
            + candidate.environment.values.sorted() + candidate.headers.values.sorted()
        var seen = Set<String>(), out: [String] = []
        for text in texts {
            for ref in placeholders(in: text) where !ref.hasDefault && (environment[ref.name] ?? "").isEmpty {
                if seen.insert(ref.name).inserted { out.append(ref.name) }
            }
        }
        return out
    }

    /// Words that mark an option or a query parameter as holding a key (as a whole word of its name, split at
    /// `-`, `_` and `.`), and the ones that count anywhere in it.
    static let secretWords: Set<String> = ["key", "auth", "authorization", "token", "secret", "password", "passwd",
                                           "apikey", "credential", "credentials", "pat", "bearer", "sig", "signature"]
    static let secretInfixes = ["token", "secret", "password", "apikey"]
    /// …unless the name says it is where the key is, not the key (`--key-file`).
    static let notSecretWords: Set<String> = ["file", "path", "dir", "env", "name", "id"]
    /// How well-known keys start.
    static let secretPrefixes = ["ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "glpat-", "sk-", "sk_live_", "rk_live_",
                                 "xoxb-", "xoxp-", "xapp-", "AKIA", "ASIA", "AIza", "ya29.", "hf_", "npm_"]

    /// Whether a server's command line or address seems to hold a key: an option named like one (`--api-key X`,
    /// `--token=X`), a value shaped like a well-known key, or an address with a key in its query or a long random
    /// part in its path. `${NAME}` references don't count — those are filled in at start.
    public static func holdsSecretInPlainText(_ config: MCPServerConfig) -> Bool {
        func isLiteral(_ value: String) -> Bool { !value.isEmpty && !value.contains("${") }
        func secretName(_ name: String) -> Bool {
            let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let words = Set(lower.split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init))
            guard words.isDisjoint(with: notSecretWords) else { return false }
            return !words.isDisjoint(with: secretWords) || secretInfixes.contains { lower.contains($0) }
        }
        func looksLikeKey(_ value: String) -> Bool {
            isLiteral(value) && secretPrefixes.contains { value.hasPrefix($0) && value.count >= $0.count + 12 }
        }
        func randomish(_ part: String) -> Bool {
            guard part.count >= 24, isLiteral(part) else { return false }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard part.unicodeScalars.allSatisfy(allowed.contains) else { return false }
            return part.contains { $0.isNumber } && part.contains { $0.isLetter }
        }
        switch config.transport {
        case .stdio:
            let args = config.args
            for (index, arg) in args.enumerated() {
                if looksLikeKey(arg) { return true }
                guard arg.hasPrefix("-") else { continue }
                if let equals = arg.firstIndex(of: "=") {
                    if secretName(String(arg[..<equals])), isLiteral(String(arg[arg.index(after: equals)...])) { return true }
                } else if secretName(arg), index + 1 < args.count, !args[index + 1].hasPrefix("-"),
                          isLiteral(args[index + 1]) {
                    return true
                }
            }
            return false
        case .http:
            guard let raw = config.url, let url = URLComponents(string: raw) else { return false }
            if let password = url.password, isLiteral(password) { return true }
            for item in url.queryItems ?? [] where secretName(item.name) && isLiteral(item.value ?? "") { return true }
            return url.path.split(separator: "/").contains { randomish(String($0)) || looksLikeKey(String($0)) }
        }
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
