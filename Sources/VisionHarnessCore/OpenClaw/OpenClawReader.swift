import Foundation

// MARK: - Finding and reading OpenClaw on this Mac
//
// OpenClaw (earlier Clawdbot, then Moltbot) keeps its state in one folder — usually ~/.openclaw — holding
// openclaw.json (JSON5), the agent workspace (skills/, MEMORY.md, memory/, SOUL.md…), per-agent auth profiles,
// an .env file and, on many installs, a secrets/ folder of JSON files the skills read. Everything is read,
// nothing is changed, nothing is run. The rules follow Vision for Windows (OpenClawReader.cs) so both apps find
// the same keys under the same names; the Mac also reads secrets/*.json and plugin-skills/ (see the behaviour
// notes in the night report).

public enum OpenClawScanner {
    public static let configNames = ["openclaw.json", "clawdbot.json", "moltbot.json", "openclaw.json5"]
    static let homeNames = [".openclaw", ".clawdbot", ".moltbot", "openclaw", "clawdbot", "moltbot", "clawd",
                            ".config/openclaw", ".local/share/openclaw", "OpenClaw"]

    /// OpenClaw installs on this Mac, best match first: an environment variable, then the home folder's usual
    /// names and profile folders (~/.openclaw-work). The home folder isn't searched deeply (that would walk
    /// Documents and Desktop and set off privacy prompts); an install anywhere else is picked with Choose Folder.
    public static func find(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [OpenClawInstall] {
        var candidates: [(URL, String)] = []
        for variable in ["OPENCLAW_STATE_DIR", "CLAWDBOT_STATE_DIR", "MOLTBOT_STATE_DIR"] {
            if let value = environment[variable], !value.isEmpty { candidates.append((expand(value, home: home), variable)) }
        }
        for variable in ["OPENCLAW_CONFIG_PATH", "CLAWDBOT_CONFIG_PATH", "MOLTBOT_CONFIG_PATH"] {
            if let value = environment[variable], !value.isEmpty {
                candidates.append((expand(value, home: home).deletingLastPathComponent(), variable))
            }
        }
        if let value = environment["OPENCLAW_HOME"], !value.isEmpty {
            candidates.append((expand(value, home: home).appendingPathComponent(".openclaw"), "OPENCLAW_HOME"))
        }
        for name in homeNames { candidates.append((home.appendingPathComponent(name), "~/" + name)) }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in entries.sorted() {
            let lower = name.lowercased()
            if lower.hasPrefix(".openclaw-") || lower.hasPrefix(".clawdbot-") || lower.hasPrefix(".moltbot-") {
                candidates.append((home.appendingPathComponent(name), "~/" + name))
            }
        }
        var seen = Set<String>()
        var installs: [OpenClawInstall] = []
        for (url, foundBy) in candidates {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            guard seen.insert(key).inserted else { continue }
            if let install = inspect(url, foundBy: foundBy) { installs.append(install) }
        }
        return installs
    }

    /// Whether a folder is an OpenClaw state folder (or a bare workspace), and its install if so.
    public static func inspect(_ url: URL, foundBy: String) -> OpenClawInstall? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        let lowered = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let config = configNames.compactMap { lowered[$0.lowercased()] }
            .map { url.appendingPathComponent($0) }
            .first { !isDirectory($0) }
        let has: (String) -> Bool = { lowered[$0.lowercased()] != nil }
        let looksLikeState = has("agents") && (has("workspace") || has("skills") || has("credentials"))
        let looksLikeWorkspace = has("skills") && (has("MEMORY.md") || has("SOUL.md") || has("AGENTS.md"))
        guard config != nil || looksLikeState || looksLikeWorkspace else { return nil }
        let lower = (config?.lastPathComponent ?? url.path).lowercased()
        let flavor = lower.contains("clawdbot") || url.path.lowercased().contains("clawd") ? "clawdbot"
            : lower.contains("moltbot") ? "moltbot" : "openclaw"
        return OpenClawInstall(stateDir: url, configPath: config, flavor: flavor, foundBy: foundBy)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// "~/x" → the home folder, "$HOME/x" too; anything else as written.
    static func expand(_ raw: String, home: URL) -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("$HOME/") { return home.appendingPathComponent(String(path.dropFirst(6))) }
        return URL(fileURLWithPath: path)
    }
}

public enum OpenClawReader {
    static let maxConfigBytes = 2_000_000
    static let maxNoteBytes = 512_000
    static let maxSmallFileBytes = 1_000_000
    static let maxDailyFiles = 200
    static let defaultDailyFiles = 45

    public static func read(_ install: OpenClawInstall, home: URL) -> OpenClawBundle {
        var bundle = OpenClawBundle(install: install)
        let state = install.stateDir

        var config: [String: Any]?
        if let path = install.configPath {
            if let text = readText(path, limit: maxConfigBytes) {
                switch JSON5.parse(text) {
                case .success(let value):
                    config = value as? [String: Any]
                    if config == nil { bundle.problems.append("\(path.lastPathComponent) isn't a settings object.") }
                case .failure(let error):
                    bundle.problems.append("Couldn't make sense of \(path.lastPathComponent) (\(error)). Skills and memory can still be brought in; the keys inside it can't.")
                }
            } else {
                bundle.problems.append("Couldn't read \(path.path).")
            }
        }

        bundle.workspaces = workspaces(install, config: config, home: home)
        bundle.agents = agents(config)

        var roots: [(URL, String)] = bundle.workspaces.map { ($0.appendingPathComponent("skills"), "workspace") }
        roots.append((state.appendingPathComponent("skills"), "managed"))
        roots.append((state.appendingPathComponent("plugin-skills"), "plugin"))
        if let extra = at(config, "skills", "load", "extraDirs") as? [Any] {
            for case let dir as String in extra where !dir.isEmpty {
                roots.append((expandPath(dir, home: home, state: state), "extra"))
            }
        }
        bundle.skills = scanSkills(roots)
        bundle.noteFiles = scanNotes(bundle.workspaces)

        var env: [String: String] = [:]
        let collector = CredentialCollector()
        readEnvFiles(state: state, workspaces: bundle.workspaces, into: &env)
        bundle.modelServers = modelServers(config, collector: collector, env: env)
        let oauth = readAuthProfiles(state: state, collector: collector)
        sweepConfig(config, env: &env, collector: collector, servers: bundle.modelServers)
        for (name, value) in env.sorted(by: { $0.key < $1.key }) where isSecretEnvName(name) {
            collector.add(name, value, kind: kindOf(name), origin: ".env", description: "From OpenClaw's environment file (\(name)).")
        }
        let secretFiles = readSecretsFolder(state: state, collector: collector)
        bundle.credentials = collector.result

        if !oauth.isEmpty {
            let providers = Array(NSOrderedSet(array: oauth)).compactMap { $0 as? String }.prefix(5).joined(separator: ", ")
            bundle.left.append("\(oauth.count) OAuth sign-in\(oauth.count == 1 ? "" : "s") (\(providers)) — they belong to OpenClaw's own session, so Vision can't reuse them.")
        }
        if let channels = at(config, "channels") as? [String: Any], !channels.isEmpty {
            bundle.left.append("Chat channels (\(channels.keys.sorted().prefix(8).joined(separator: ", "))) — they belong to OpenClaw's gateway.")
        }
        let cron = countCronJobs(state)
        if cron > 0 { bundle.left.append("\(cron) scheduled job\(cron == 1 ? "" : "s") (cron) — Vision has the task queue instead; recreate any you still want.") }
        let sessions = countSessions(state)
        if sessions > 0 { bundle.left.append("\(sessions) saved conversation\(sessions == 1 ? "" : "s") — chat history isn't brought over.") }
        if secretFiles.keyFiles > 0 {
            bundle.left.append("\(secretFiles.keyFiles) key file\(secretFiles.keyFiles == 1 ? "" : "s") in secrets/ (.pem, .key) — add them to the vault yourself if a task needs them.")
        }
        if !bundle.agents.isEmpty {
            let names = bundle.agents.map { agent in agent.id + (agent.model.map { " (\($0))" } ?? "") }.prefix(6).joined(separator: ", ")
            bundle.left.append("Agents \(names) — Vision's chats choose their own model; each agent's workspace skills and memory are listed above.")
        }
        for unresolved in Array(NSOrderedSet(array: collector.unresolved)).compactMap({ $0 as? String }).prefix(6) {
            bundle.left.append("A setting refers to ${\(unresolved)} but no value for it was found.")
        }
        return bundle
    }

    // MARK: Files

    static func readText(_ url: URL, limit: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? Int, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(data: bytes, encoding: .utf8)
    }

    static func list(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: JSON helpers

    static func at(_ node: Any?, _ path: String...) -> Any? {
        var current = node
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double > 0, double < Double(Int32.max) else { return nil }
        return Int(double)
    }

    // MARK: Workspaces and agents

    static func workspaces(_ install: OpenClawInstall, config: [String: Any]?, home: URL) -> [URL] {
        let state = install.stateDir
        var candidates: [URL] = []
        func add(_ value: Any?) {
            if let path = value as? String, !path.isEmpty { candidates.append(expandPath(path, home: home, state: state)) }
        }
        add(at(config, "agents", "defaults", "workspace"))
        if let list = at(config, "agents", "list") as? [Any] { for agent in list { add(at(agent, "workspace")) } }
        if let entries = at(config, "agents", "entries") as? [String: Any] {
            for key in entries.keys.sorted() { add(at(entries[key], "workspace")) }
        }
        add(at(config, "agent", "workspace"))
        add(at(config, "workspace"))
        let names = list(state)
        // The state folder's own workspace(s), including per-agent ones (workspace-work) — but only folders that hold
        // what a workspace holds (workspace-attestations and the like are OpenClaw's bookkeeping, not workspaces).
        for name in names where name.lowercased().hasPrefix("workspace") {
            let url = state.appendingPathComponent(name)
            if OpenClawScanner.isDirectory(url), looksLikeWorkspace(url) { candidates.append(url) }
        }
        if install.flavor == "clawdbot" { candidates.append(home.appendingPathComponent("clawd")) }
        let lowered = Set(names.map { $0.lowercased() })
        if lowered.contains("skills"), lowered.contains("memory.md") || lowered.contains("soul.md") { candidates.append(state) }
        var seen = Set<String>()
        return candidates.filter { url in
            OpenClawScanner.isDirectory(url) && seen.insert(url.standardizedFileURL.path.lowercased()).inserted
        }
    }

    static func looksLikeWorkspace(_ url: URL) -> Bool {
        let names = Set(list(url).map { $0.lowercased() })
        return !names.isDisjoint(with: ["skills", "memory.md", "memory", "soul.md", "agents.md", "user.md", "identity.md", "tools.md"])
    }

    static func agents(_ config: [String: Any]?) -> [OpenClawAgent] {
        var result: [OpenClawAgent] = []
        func model(_ value: Any?) -> String? {
            if let text = value as? String { return text }
            return at(value, "primary") as? String
        }
        if let list = at(config, "agents", "list") as? [Any] {
            for agent in list {
                guard let id = (at(agent, "id") as? String) ?? (at(agent, "name") as? String) else { continue }
                result.append(OpenClawAgent(id: id, model: model(at(agent, "model")), workspace: at(agent, "workspace") as? String))
            }
        }
        if let entries = at(config, "agents", "entries") as? [String: Any] {
            for id in entries.keys.sorted() where !result.contains(where: { $0.id == id }) {
                result.append(OpenClawAgent(id: id, model: model(at(entries[id], "model")), workspace: at(entries[id], "workspace") as? String))
            }
        }
        return result
    }

    /// "~/x" → the home folder, a relative path → beside the state folder, an absolute one as is.
    static func expandPath(_ raw: String, home: URL, state: URL) -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("$HOME/") { return home.appendingPathComponent(String(path.dropFirst(6))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return state.appendingPathComponent(path)
    }

    // MARK: Skills

    static func scanSkills(_ roots: [(URL, String)]) -> [OpenClawSkill] {
        var found: [OpenClawSkill] = []
        var seenFolders = Set<String>()
        for (directory, location) in roots {
            for name in list(directory).prefix(300) where !name.hasPrefix(".") {
                let folder = directory.appendingPathComponent(name)
                guard OpenClawScanner.isDirectory(folder), seenFolders.insert(folder.standardizedFileURL.path).inserted else { continue }
                if let skill = skill(at: folder, location: location) {
                    found.append(skill)
                    continue
                }
                // A folder without a manifest may group skills a level down.
                for inner in list(folder).prefix(100) where !inner.hasPrefix(".") {
                    let nested = folder.appendingPathComponent(inner)
                    if OpenClawScanner.isDirectory(nested), let skill = skill(at: nested, location: location) { found.append(skill) }
                }
            }
        }
        // OpenClaw's precedence: workspace, then managed, then plugin and extra folders. The first of a name wins.
        var names = Set<String>()
        return found.map { skill in
            var copy = skill
            copy.shadowed = !names.insert(skill.name.lowercased()).inserted
            return copy
        }
    }

    static func skill(at folder: URL, location: String) -> OpenClawSkill? {
        let manifest = folder.appendingPathComponent("SKILL.md")
        // The manifest must be a file of its own: a link could point at a dotfile with keys in it.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let text = readText(manifest, limit: 256_000) else { return nil }
        let document = SkillDocument.parse(text)
        var name = (document["name"] ?? folder.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = folder.lastPathComponent }
        let files = listFiles(folder, maxDepth: 4, limit: 300)
        let scripts = files.contains { SkillImporter.scriptExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        return OpenClawSkill(name: name, description: (document["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             directory: folder, location: location, files: files, hasScripts: scripts, shadowed: false)
    }

    /// Regular files under a folder, relative, "/"-separated; links, VCS and dependency folders skipped.
    static func listFiles(_ root: URL, maxDepth: Int, limit: Int) -> [String] {
        var out: [String] = []
        func walk(_ dir: URL, prefix: String, depth: Int) {
            guard depth <= maxDepth else { return }
            for name in list(dir) {
                if out.count >= limit { return }
                if SkillImporter.skipDirectories.contains(name) || name == ".DS_Store" { continue }
                let url = dir.appendingPathComponent(name)
                guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    walk(url, prefix: prefix + name + "/", depth: depth + 1)
                } else if type == .typeRegular {
                    out.append(prefix + name)
                }
            }
        }
        walk(root, prefix: "", depth: 0)
        return out
    }

    // MARK: Memory

    static func scanNotes(_ workspaces: [URL]) -> [OpenClawNoteFile] {
        var result: [OpenClawNoteFile] = []
        for workspace in workspaces {
            let label = workspaces.count > 1 ? workspace.lastPathComponent + "/" : ""
            var wanted: [(URL, String, OpenClawNoteKind, Bool, String?)] = []
            for name in list(workspace) {
                let kind: OpenClawNoteKind?
                switch name.lowercased() {
                case "memory.md": kind = .memory
                case "user.md": kind = .about
                case "soul.md", "identity.md": kind = .persona
                case "agents.md", "tools.md": kind = .instructions
                default: kind = nil
                }
                if let kind {
                    wanted.append((workspace.appendingPathComponent(name), label + name, kind, kind == .memory || kind == .about, nil))
                }
            }
            if let memoryName = list(workspace).first(where: { $0.lowercased() == "memory" }) {
                let folder = workspace.appendingPathComponent(memoryName)
                let daily = list(folder).filter { $0.lowercased().hasSuffix(".md") }
                    .sorted { (dayOf($0) ?? "", $0) > (dayOf($1) ?? "", $1) }
                    .prefix(maxDailyFiles)
                for (index, name) in daily.enumerated() {
                    wanted.append((folder.appendingPathComponent(name), label + "memory/" + name, .daily, index < defaultDailyFiles, dayOf(name)))
                }
            }
            for (url, name, kind, selected, day) in wanted {
                guard let text = readText(url, limit: maxNoteBytes), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(OpenClawNoteFile(path: url, name: name, kind: kind, text: text, selectedByDefault: selected, day: day))
            }
        }
        return result
    }

    /// "2026-10-01" from "2026-10-01.md" or "2026-10-01-standup.md".
    static func dayOf(_ name: String) -> String? {
        let head = String(name.prefix(10))
        let parts = head.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return head
    }

    // MARK: Credentials

    /// Gathers secrets, one entry per distinct value, with vault-legal unique names.
    final class CredentialCollector {
        private var byValue: [String: OpenClawCredential] = [:]
        private var order: [String] = []
        private var names = Set<String>()
        var unresolved: [String] = []

        var result: [OpenClawCredential] {
            order.compactMap { byValue[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }

        func add(_ rawName: String, _ value: String, kind: VaultEntry.Kind, origin: String, description: String,
                 provider: String? = nil, username: String? = nil, url: String? = nil) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard OpenClawReader.looksLikeSecret(trimmed, kind: kind) else { return }
            let wanted = OpenClawReader.sanitize(rawName)
            if var existing = byValue[trimmed] {
                if existing.name.caseInsensitiveCompare(wanted) != .orderedSame, !existing.alsoNamed.contains(wanted) {
                    existing.alsoNamed.append(wanted)
                    byValue[trimmed] = existing
                }
                return
            }
            var name = wanted
            var n = 2
            while !names.insert(name.lowercased()).inserted {
                // The suffix goes on a name cut short enough to hold it.
                let suffix = "_\(n)"
                let head = wanted.count + suffix.count > maxNameLength ? String(wanted.prefix(maxNameLength - suffix.count)) : wanted
                name = OpenClawReader.sanitize(head + suffix)
                n += 1
            }
            byValue[trimmed] = OpenClawCredential(name: name, secret: OpenClawSecret(trimmed), kind: kind, description: description,
                                                  origin: origin, provider: provider, username: username, url: url, alsoNamed: [])
            order.append(trimmed)
        }
    }

    static let maxNameLength = 80

    static let notSecretNames: Set<String> = [
        "maxtokens", "max_tokens", "tokenlimit", "token_limit", "contexttokens", "tokens", "reservetokens", "tokenizer",
        "tokencount", "maxtokencount", "tokenfile", "keyfile", "passwordfile", "secretfile", "tokenenv", "apikeyenv", "tokenpath",
    ]

    /// An environment variable's name that says it holds a secret.
    static func isSecretEnvName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASS", "PWD", "CREDENTIAL", "BEARER", "PRIVATE"]
            .contains { upper.contains($0) }
    }

    /// Words in a settings key: "botToken" → bot, token; "api_key" → api, key.
    static func keyWords(_ key: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for c in key {
            if !(c.isLetter || c.isNumber) {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                previous = c
                continue
            }
            if c.isUppercase, let previous, previous.isLowercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(c)
            previous = c
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    static let secretWords: Set<String> = ["secret", "token", "password", "passwd", "passphrase", "pwd", "bearer", "credential",
                                           "credentials", "apikey"]

    /// A settings key that holds a secret: whole words only, so "secretary" and "tokenizer" don't count.
    static func isSecretKeyName(_ key: String) -> Bool {
        if notSecretNames.contains(key.lowercased()) { return false }
        let words = keyWords(key)
        guard let last = words.last else { return false }
        if ["file", "path", "env", "limit", "count", "tokens", "ttl", "url", "id", "arn", "name", "mode", "user", "username"].contains(last) {
            return false
        }
        if words.contains(where: secretWords.contains) { return true }
        for index in 0..<(words.count - 1) where ["api", "private", "access", "auth", "secret", "signing", "license"].contains(words[index]) && words[index + 1] == "key" {
            return true
        }
        return false
    }

    static func kindOf(_ name: String) -> VaultEntry.Kind {
        let lower = name.lowercased()
        if lower.contains("passw") || lower.contains("passphrase") || lower.hasSuffix("pwd") { return .password }
        if lower.contains("token") || lower.contains("bearer") || lower.contains("secret") { return .token }
        return .apiKey
    }

    /// A real secret, not a placeholder, a sentence, a number or a reference to somewhere else.
    public static func looksLikeSecret(_ value: String, kind: VaultEntry.Kind) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count < (kind == .password ? 6 : 12) { return false }
        if kind != .password, v.contains(where: \.isWhitespace) { return false }
        if v.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        if v.hasPrefix("${") || v.hasPrefix("$(") { return false }
        let lower = v.lowercased()
        for prefix in ["env:", "file:", "secret:", "exec:", "op://", "vault:", "keychain:", "http://", "https://", "/", "~"]
            where lower.hasPrefix(prefix) { return false }
        for placeholder in ["changeme", "change-me", "your-", "your_", "yourkey", "<", "xxxx", "****", "redacted", "placeholder",
                            "example", "todo", "undefined", "not-needed", "notneeded", "sk-..."] where lower.contains(placeholder) {
            return false
        }
        if Set(v).count <= 3 { return false }
        // A name or slug ("ollama-local"), not a key: real ones mix in digits or capitals.
        if kind != .password, v.count < 40, !v.contains(where: \.isNumber), !(v.contains(where: \.isUppercase) && v.contains(where: \.isLowercase)) {
            return false
        }
        return true
    }

    /// A name the vault accepts: upper-case letters, digits, _ - . only.
    public static func sanitize(_ raw: String) -> String {
        var text = ""
        for c in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c.isASCII, c.isLetter || c.isNumber || c == "-" || c == "." {
                text.append(Character(c.uppercased()))
            } else if !text.isEmpty, text.last != "_" {
                text.append("_")
            }
        }
        var name = text.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { name = "OPENCLAW_SECRET" }
        return name.count > maxNameLength ? String(name.prefix(maxNameLength)) : name
    }

    /// "${VAR}" / "$VAR" → the value from the env files; anything else is itself. Nil when the reference has no value.
    static func resolve(_ value: String, env: [String: String], collector: CredentialCollector) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        if trimmed.hasPrefix("${"), trimmed.hasSuffix("}") {
            let inner = trimmed.dropFirst(2).dropLast()
            name = String(inner.split(separator: ":", maxSplits: 1).first ?? "")
        } else if trimmed.hasPrefix("$"), trimmed.count > 1, trimmed.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            name = String(trimmed.dropFirst())
        }
        guard let name, !name.isEmpty, name.first.map({ $0.isLetter || $0 == "_" }) == true else { return value }
        if let resolved = env[name] { return resolved }
        collector.unresolved.append(name)
        return nil
    }

    static let conventionalNames: [String: String] = [
        "anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY", "openrouter": "OPENROUTER_API_KEY",
        "google": "GEMINI_API_KEY", "gemini": "GEMINI_API_KEY", "groq": "GROQ_API_KEY", "mistral": "MISTRAL_API_KEY",
        "xai": "XAI_API_KEY", "deepseek": "DEEPSEEK_API_KEY", "together": "TOGETHER_API_KEY", "fireworks": "FIREWORKS_API_KEY",
        "cerebras": "CEREBRAS_API_KEY", "perplexity": "PERPLEXITY_API_KEY", "moonshot": "MOONSHOT_API_KEY", "zai": "ZAI_API_KEY",
        "minimax": "MINIMAX_API_KEY", "huggingface": "HF_TOKEN", "github": "GITHUB_TOKEN", "brave": "BRAVE_API_KEY",
    ]

    /// auth-profiles.json files (one per agent). Returns the OAuth sign-ins it skipped, by provider.
    static func readAuthProfiles(state: URL, collector: CredentialCollector) -> [String] {
        var files = [state.appendingPathComponent("auth-profiles.json"), state.appendingPathComponent("agent/auth-profiles.json")]
        for agent in list(state.appendingPathComponent("agents")).prefix(40) {
            files.append(state.appendingPathComponent("agents/\(agent)/agent/auth-profiles.json"))
        }
        var oauth: [String] = []
        for file in files {
            guard let text = readText(file, limit: maxSmallFileBytes), case .success(let root) = JSON5.parse(text) else { continue }
            var profiles: [(String, [String: Any])] = []
            let container = at(root, "profiles") ?? root
            if let map = container as? [String: Any] {
                for id in map.keys.sorted() {
                    if let profile = map[id] as? [String: Any],
                       profile["type"] != nil || profile["provider"] != nil || profile["key"] != nil || profile["token"] != nil {
                        profiles.append((id, profile))
                    }
                }
            } else if let list = container as? [Any] {
                for case let profile as [String: Any] in list {
                    profiles.append(((profile["id"] as? String) ?? (profile["profileId"] as? String) ?? "profile", profile))
                }
            }
            for (id, profile) in profiles {
                let provider = (profile["provider"] as? String) ?? String(id.split(separator: ":").first ?? "")
                let profileName = id.contains(":") ? String(id[id.index(after: id.firstIndex(of: ":")!)...]) : ""
                let type = ((profile["type"] as? String) ?? (profile["token"] != nil ? "token" : "api_key")).lowercased()
                if type.contains("oauth") { oauth.append(provider); continue }
                let secret = type == "token"
                    ? (profile["token"] as? String) ?? (profile["key"] as? String)
                    : (profile["key"] as? String) ?? (profile["apiKey"] as? String) ?? (profile["api_key"] as? String) ?? (profile["token"] as? String)
                guard let secret else { continue }
                let isDefault = profileName.isEmpty || profileName.lowercased() == "default"
                let suffix = type == "token" ? "TOKEN" : "API_KEY"
                let name = isDefault && type != "token" && conventionalNames[provider.lowercased()] != nil
                    ? conventionalNames[provider.lowercased()]!
                    : "OPENCLAW_\(sanitize(provider))\(isDefault ? "" : "_" + sanitize(profileName))_\(suffix)"
                collector.add(name, secret, kind: type == "token" ? .token : .apiKey, origin: "auth-profiles.json (\(id))",
                              description: "OpenClaw auth profile “\(id)” for \(provider).", provider: provider)
            }
        }
        return oauth
    }

    /// KEY=value lines from OpenClaw's own .env files; also fills `env` so ${VAR} references resolve.
    static func readEnvFiles(state: URL, workspaces: [URL], into env: inout [String: String]) {
        var files = [state.appendingPathComponent(".env")]
        files.append(contentsOf: workspaces.map { $0.appendingPathComponent(".env") })
        var seen = Set<String>()
        for file in files where seen.insert(file.standardizedFileURL.path).inserted {
            guard let text = readText(file, limit: 256_000) else { continue }
            for (name, value) in parseEnv(text) { env[name] = value }
        }
    }

    /// The assignments in a .env file, in order.
    public static func parseEnv(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="), equals != line.startIndex else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
                // Double quotes take escapes, as dotenv reads them (and as Vision's export writes them).
                if first == "\"" { value = unescapeDoubleQuoted(value) }
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty, name.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }), !value.isEmpty {
                out.append((name, value))
            }
        }
        return out
    }

    static func unescapeDoubleQuoted(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var escaping = false
        for c in text {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    /// Walk the config for anything that looks like a key, token or password.
    static func sweepConfig(_ config: [String: Any]?, env: inout [String: String], collector: CredentialCollector,
                            servers: [OpenClawModelServer]) {
        guard let config else { return }
        func envBlock(_ node: Any?, origin: String, env: inout [String: String]) {
            guard let block = node as? [String: Any] else { return }
            for name in block.keys.sorted() {
                let value = block[name]
                if name == "vars", value is [String: Any] { envBlock(value, origin: origin + ".vars", env: &env); continue }
                if let text = value as? String, let resolved = resolve(text, env: env, collector: collector) {
                    if env[name] == nil { env[name] = resolved }
                    if isSecretEnvName(name) {
                        collector.add(name, resolved, kind: kindOf(name), origin: "\(origin).\(name)",
                                      description: "OpenClaw environment setting \(name).")
                    }
                }
            }
        }
        envBlock(config["env"], origin: "openclaw.json env", env: &env)
        if let entries = at(config, "skills", "entries") as? [String: Any] {
            for skill in entries.keys.sorted() {
                envBlock(at(entries[skill], "env"), origin: "openclaw.json skills.entries.\(skill).env", env: &env)
            }
        }
        let handled = Set(servers.filter(\.compatible).map { $0.id.lowercased() })
        let snapshotEnv = env
        var path: [String] = []
        func walk(_ node: Any?) {
            guard path.count <= 12 else { return }
            if let object = node as? [String: Any] {
                // A reference to a secret kept elsewhere ({ source: "env", id: "…" }), not a secret.
                if let source = object["source"] as? String, ["env", "file", "exec"].contains(source), object["id"] != nil { return }
                for key in object.keys.sorted() {
                    path.append(key)
                    defer { path.removeLast() }
                    let inEnv = path.first == "env" || (path.count >= 4 && path[0] == "skills" && path[1] == "entries" && path[3] == "env")
                    let providerKey = path.count == 4 && path[0] == "models" && path[1] == "providers"
                        && handled.contains(path[2].lowercased()) && key == "apiKey"
                    if inEnv || providerKey { continue }
                    let child = object[key]
                    if let text = child as? String, isSecretKeyName(key) {
                        addFromConfig(path, key: key, text: text, env: snapshotEnv)
                    } else if child is [String: Any] || child is [Any] {
                        walk(child)
                    }
                }
            } else if let array = node as? [Any] {
                for (index, item) in array.prefix(100).enumerated() {
                    path.append(String(index))
                    walk(item)
                    path.removeLast()
                }
            }
        }
        func addFromConfig(_ whereFound: [String], key: String, text: String, env: [String: String]) {
            guard let resolved = resolve(text, env: env, collector: collector) else { return }
            let provider: String? = whereFound.count >= 3 && whereFound[0] == "models" && whereFound[1] == "providers" ? whereFound[2]
                : whereFound.count >= 2 && whereFound[0] == "channels" ? whereFound[1]
                : whereFound.count >= 3 && whereFound[0] == "skills" && whereFound[1] == "entries" ? whereFound[2] : nil
            let dotted = whereFound.joined(separator: ".")
            let name = dotted.lowercased() == "gateway.auth.token" ? "OPENCLAW_GATEWAY_TOKEN"
                : dotted.lowercased() == "gateway.auth.password" ? "OPENCLAW_GATEWAY_PASSWORD"
                : "OPENCLAW_" + whereFound.joined(separator: "_")
            collector.add(name, resolved, kind: kindOf(key), origin: "openclaw.json \(dotted)",
                          description: "OpenClaw setting \(dotted).", provider: provider)
        }
        walk(config)
    }

    /// secrets/*.json and secrets/*.env — the folder many installs keep their skills' logins in. Every value
    /// under a secret-looking key becomes a vault entry named after the file and its path
    /// (OPENCLAW_LUCET_POLESTAR_SCAL_PASSWORD); a username or url beside it is kept with it. Key files are counted,
    /// never read.
    static func readSecretsFolder(state: URL, collector: CredentialCollector) -> (files: Int, keyFiles: Int) {
        let folder = state.appendingPathComponent("secrets")
        var files = 0, keyFiles = 0
        for name in list(folder).prefix(200) where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            let ext = url.pathExtension.lowercased()
            if ["pem", "key", "p12", "pfx", "ppk", "jks", "keystore"].contains(ext) { keyFiles += 1; continue }
            let stem = url.deletingPathExtension().lastPathComponent
            if ext == "json", let text = readText(url, limit: maxSmallFileBytes), case .success(let root) = JSON5.parse(text) {
                files += 1
                walkSecrets(root, path: [stem], file: name, collector: collector)
            } else if ext == "env", let text = readText(url, limit: 256_000) {
                files += 1
                for (key, value) in parseEnv(text) where isSecretEnvName(key) {
                    collector.add(key, value, kind: kindOf(key), origin: "secrets/\(name)", description: "From OpenClaw's secrets/\(name) (\(key)).")
                }
            }
        }
        return (files, keyFiles)
    }

    static func walkSecrets(_ node: Any?, path: [String], file: String, collector: CredentialCollector) {
        guard path.count <= 8, let object = node as? [String: Any] else { return }
        let username = ["username", "user", "email", "login", "client_id", "clientId", "key_id", "access_key_id", "smtp_user", "upn"]
            .lazy.compactMap { object[$0] as? String }.first
        let url = ["url", "base_url", "baseUrl", "login_url", "host", "api_base", "endpoint"].lazy.compactMap { object[$0] as? String }.first
        for key in object.keys.sorted() {
            let value = object[key]
            if let text = value as? String, isSecretKeyName(key) || ["key", "apikey", "secret"].contains(key.lowercased()) {
                let dotted = (path.dropFirst() + [key]).joined(separator: ".")
                collector.add("OPENCLAW_" + (path + [key]).joined(separator: "_"), text, kind: kindOf(key), origin: "secrets/\(file) \(dotted)",
                              description: "From OpenClaw's secrets/\(file) (\(dotted)).", provider: path.first,
                              username: username, url: url)
            } else if value is [String: Any] {
                walkSecrets(value, path: path + [key], file: file, collector: collector)
            }
        }
    }

    // MARK: Model servers

    static func modelServers(_ config: [String: Any]?, collector: CredentialCollector, env: [String: String]) -> [OpenClawModelServer] {
        guard let providers = at(config, "models", "providers") as? [String: Any] else { return [] }
        let primary = (at(config, "agents", "defaults", "model", "primary") as? String) ?? (at(config, "agents", "defaults", "model") as? String)
        var primaryProvider: String?, primaryModel: String?
        if let primary, let slash = primary.firstIndex(of: "/") {
            primaryProvider = String(primary[..<slash])
            primaryModel = String(primary[primary.index(after: slash)...])
        }
        var result: [OpenClawModelServer] = []
        for id in providers.keys.sorted() {
            guard let provider = providers[id] as? [String: Any],
                  let baseURL = (provider["baseUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !baseURL.isEmpty else { continue }
            let api = (provider["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let compatible = api == nil || ["openai-completions", "openai"].contains(api!.lowercased())
            var note: String? = compatible ? nil : "speaks the “\(api!)” protocol, which Vision doesn't"
            if let components = URLComponents(string: baseURL), components.user != nil || (components.query?.isEmpty == false) {
                note = (note.map { $0 + "; " } ?? "") + "its address carries a sign-in or token — check it before bringing it in"
            }
            var models: [String] = []
            var window: Int?
            if let list = provider["models"] as? [Any] {
                for item in list {
                    guard let modelID = (item as? String) ?? (at(item, "id") as? String), !modelID.isEmpty else { continue }
                    models.append(modelID)
                    if window == nil { window = positiveInt(at(item, "contextWindow")) }
                }
            }
            var key: OpenClawSecret?
            if let raw = provider["apiKey"] as? String, !raw.isEmpty, let resolved = resolve(raw, env: env, collector: collector),
               !resolved.isEmpty, !resolved.hasPrefix("${") {
                key = OpenClawSecret(resolved)
            }
            result.append(OpenClawModelServer(id: id, baseURL: baseURL, api: api, models: models, contextWindow: window, apiKey: key,
                                              compatible: compatible, note: note,
                                              defaultModel: primaryProvider?.lowercased() == id.lowercased() ? primaryModel : nil))
        }
        return result
    }

    // MARK: What isn't imported

    static func countCronJobs(_ state: URL) -> Int {
        guard let text = readText(state.appendingPathComponent("cron/jobs.json"), limit: maxSmallFileBytes),
              case .success(let root) = JSON5.parse(text) else { return 0 }
        if let array = root as? [Any] { return array.count }
        if let jobs = at(root, "jobs") as? [Any] { return jobs.count }
        if let object = root as? [String: Any] { return object.values.filter { $0 is [String: Any] }.count }
        return 0
    }

    static func countSessions(_ state: URL) -> Int {
        var total = 0
        for agent in list(state.appendingPathComponent("agents")).prefix(40) {
            total += list(state.appendingPathComponent("agents/\(agent)/sessions")).filter { $0.lowercased().hasSuffix(".jsonl") }.count
        }
        return total
    }
}
