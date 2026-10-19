import Foundation

// MARK: - Claude Code: finding the CLI and asking whether it is signed in
//
// "Claude Code (your Claude subscription)" is an engine choice for a chat. Vision never talks to Anthropic for it
// and never reads, copies or reuses the CLI's sign-in: the official `claude` command does the talking, signed in
// with the person's Claude Pro or Max plan on this Mac, and Vision runs it headless (`claude -p`) and reads what it
// prints. This file finds the command, asks its version, reads which options it has (from `--help`, so a newer
// or older CLI only ever gets options it knows) and asks whether it is signed in (`claude auth status`, a local
// check that makes no model call). Everything runs through `ClaudeCodeCommandRunner`, so tests script it.

/// Runs a short `claude` command (version, help, auth status) and returns what it printed.
public protocol ClaudeCodeCommandRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> AWSCLIResult
}

/// The real one: the AWS CLI's child-process runner (no shell, its own process group, a time limit), with the
/// environment `ClaudeCodeEnvironment` makes.
public struct ProcessClaudeCodeCommandRunner: ClaudeCodeCommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> AWSCLIResult {
        let overrides = ClaudeCodeEnvironment.overrides(for: executable, base: ProcessInfo.processInfo.environment)
        return try await ProcessAWSCLIRunner(executable: executable)
            .run(arguments, options: AWSCLIRunOptions(environment: overrides, timeout: timeout))
    }
}

// MARK: - The environment a `claude` child gets

public enum ClaudeCodeEnvironment {
    /// Never handed to the CLI. An Anthropic API key or token in Vision's environment would make Claude Code bill
    /// that key instead of using the person's Claude plan; the rest describe *another* Claude Code session (Vision
    /// started from a Claude Code terminal) and would make the child think it is nested inside it or switch it to
    /// bare mode, which ignores the plan's sign-in. The AWS runner's own variables are for the AWS CLI only.
    public static let removed: [String] = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SIMPLE", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH", "CLAUDE_AGENT_SDK_VERSION",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_PID",
    ] + ProcessAWSCLIRunner.standardEnvironment.keys.sorted()

    /// The variables to change for one run: the removed ones gone, PATH with the folder the CLI lives in (an npm
    /// install's `claude` is a node script that needs the `node` next to it) and the usual tool folders a GUI app
    /// doesn't inherit, and SHELL set (Claude Code runs its Bash tool in the person's own shell).
    public static func overrides(for executable: String, base: [String: String],
                                 home: String = NSHomeDirectory()) -> [String: String?] {
        var out: [String: String?] = [:]
        for name in removed where base[name] != nil || ProcessAWSCLIRunner.standardEnvironment[name] != nil {
            out[name] = .some(nil)
        }
        var directories = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let own = (executable as NSString).deletingLastPathComponent
        if !own.isEmpty, !directories.contains(own) { directories.insert(own, at: 0) }
        for extra in [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/sbin"]
        where !directories.contains(extra) {
            directories.append(extra)
        }
        out["PATH"] = directories.joined(separator: ":")
        if (base["SHELL"] ?? "").isEmpty { out["SHELL"] = PTY.defaultShell }
        if (base["HOME"] ?? "").isEmpty { out["HOME"] = home }
        return out
    }

    /// `overrides` applied to `base` — the whole environment of a run.
    public static func environment(for executable: String, base: [String: String],
                                   home: String = NSHomeDirectory()) -> [String: String] {
        var env = base
        for (name, value) in overrides(for: executable, base: base, home: home) {
            if let value { env[name] = value } else { env.removeValue(forKey: name) }
        }
        return env
    }
}

// MARK: - Where it is

/// Where the CLI was found, which says how it was installed (and how to update it).
public enum ClaudeCodeSource: String, Sendable, Equatable, Codable {
    /// A path the person picked.
    case chosen
    /// On PATH, or where an installer puts it (the native installer, npm, Homebrew, bun, Volta, nvm).
    case installed
    /// The copy the Claude desktop app keeps for itself.
    case desktopApp
}

public enum ClaudeCodeLocator {
    /// Where the installers put `claude`, most likely first. The native installer: `~/.local/bin/claude` (older
    /// ones: `~/.claude/local/claude`); Homebrew: `/opt/homebrew/bin` (Apple silicon) or `/usr/local/bin`; npm's
    /// global folder when it was moved to the home folder; bun; Volta; pnpm.
    public static func knownLocations(home: String) -> [String] {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         home + "/.npm-global/bin/claude", home + "/.bun/bin/claude", home + "/.volta/bin/claude",
         home + "/Library/pnpm/claude"]
    }

    /// The newest `claude` under nvm's node versions (`~/.nvm/versions/node/v22.1.0/bin/claude`), if any.
    public static func nvmLocations(home: String, fileManager: FileManager = .default) -> [String] {
        let root = home + "/.nvm/versions/node"
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return versions.sorted { compareVersions($0, $1) == .orderedDescending }
            .map { "\(root)/\($0)/bin/claude" }
    }

    /// The Claude desktop app's own copy (`~/Library/Application Support/Claude/claude-code/<version>/<build>/
    /// claude.app/Contents/MacOS/claude`), newest version first. It is the same official CLI with the same
    /// sign-in; it is offered last because the desktop app replaces it on its own schedule.
    public static func desktopAppLocations(home: String, fileManager: FileManager = .default) -> [String] {
        let root = home + "/Library/Application Support/Claude/claude-code"
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for version in versions.sorted(by: { compareVersions($0, $1) == .orderedDescending }) {
            let folder = root + "/" + version
            for build in ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted() {
                out.append("\(folder)/\(build)/claude.app/Contents/MacOS/claude")
            }
        }
        return out
    }

    /// The search for this Mac: the chosen path, PATH, the installers' folders, nvm, then the desktop app's copy.
    public static func search(explicitPath: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory()) -> AWSCLISearch {
        var search = AWSCLISearch.forThisMachine(explicitPath: explicitPath, environment: environment, home: home)
        search.fileName = "claude"
        search.knownLocations = knownLocations(home: home) + nvmLocations(home: home) + desktopAppLocations(home: home)
        return search
    }

    /// How a found path was installed.
    public static func source(of path: String, explicitPath: String?, home: String = NSHomeDirectory()) -> ClaudeCodeSource {
        if let explicitPath, !explicitPath.isEmpty, AWSCLI.absolutePath(explicitPath) == path { return .chosen }
        return path.hasPrefix(home + "/Library/Application Support/Claude/") ? .desktopApp : .installed
    }

    /// "2.1.299" vs "2.1.30" by number, part by part ("v22.1.0" works too); non-numbers compare as text.
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? -1 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return a.compare(b)
    }
}

// MARK: - What it is

/// One working `claude`: where, which version, and which options and commands it has.
public struct ClaudeCodeInstall: Sendable, Equatable {
    public var path: String
    public var version: String?
    public var source: ClaudeCodeSource
    /// Every `--option` its help lists.
    public var flags: Set<String>
    /// Its subcommands ("auth", "mcp", "update", …).
    public var commands: Set<String>

    public init(path: String, version: String?, source: ClaudeCodeSource = .installed,
                flags: Set<String> = [], commands: Set<String> = []) {
        self.path = path
        self.version = version
        self.source = source
        self.flags = flags
        self.commands = commands
    }

    /// Whether this CLI takes `--name` (the help lists it).
    public func supports(_ flag: String) -> Bool { flags.contains(flag) }

    /// What headless chat needs: print mode with stream-json in and out.
    public var canRunHeadless: Bool {
        supports("--print") && supports("--output-format") && supports("--input-format")
    }

    /// The version is at least `minimum` (unknown counts as no).
    public func isAtLeast(_ minimum: String) -> Bool {
        guard let version else { return false }
        return ClaudeCodeLocator.compareVersions(version, minimum) != .orderedAscending
    }

    /// "2.1.299 (Claude Code)" → "2.1.299".
    public static func parseVersion(_ text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "v()"))
            let parts = t.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return t }
        }
        return nil
    }

    /// The options (`--print`, `--allowed-tools` …) and the subcommands a `claude --help` lists.
    public static func parseHelp(_ text: String) -> (flags: Set<String>, commands: Set<String>) {
        var flags = Set<String>()
        var commands = Set<String>()
        var inCommands = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("commands:") { inCommands = true; continue }
            if trimmed.lowercased().hasPrefix("options:") || trimmed.lowercased().hasPrefix("arguments:") { inCommands = false }
            if inCommands {
                // "  auth    Manage authentication" / "  plugin|plugins   Manage …" / "  mcp [options]"
                // A command starts two spaces in; a wrapped description is indented much further.
                guard line.hasPrefix("  "), !line.hasPrefix("   "), let first = trimmed.split(separator: " ").first,
                      let char = first.first, char.isLetter else { continue }
                for name in first.split(separator: "|") { commands.insert(String(name)) }
                continue
            }
            // Every --long-option on an option line ("--allowedTools, --allowed-tools <tools...>").
            guard trimmed.hasPrefix("-") else { continue }
            var index = trimmed.startIndex
            while let range = trimmed.range(of: "--", range: index..<trimmed.endIndex) {
                var end = range.upperBound
                while end < trimmed.endIndex, trimmed[end].isLetter || trimmed[end].isNumber || trimmed[end] == "-" {
                    end = trimmed.index(after: end)
                }
                if end > range.upperBound { flags.insert(String(trimmed[range.lowerBound..<end])) }
                index = end
                // Only the option names at the start of the line, not ones quoted in its description.
                if end < trimmed.endIndex, trimmed[end] != "," { break }
            }
        }
        return (flags, commands)
    }
}

// MARK: - Whether it is signed in

/// What `claude auth status` said (a local check: no model call, nothing leaves the Mac).
public struct ClaudeCodeAuth: Sendable, Equatable {
    public var loggedIn: Bool
    /// "claude.ai", "oauth_token", "api_key", "none" … as the CLI names it.
    public var authMethod: String?
    /// "firstParty" (Anthropic), "bedrock", "vertex", "foundry" …
    public var apiProvider: String?
    public var email: String?
    /// "pro", "max", "team", "enterprise" … when the CLI says.
    public var subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil, email: String? = nil,
                subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.email = email
        self.subscriptionType = subscriptionType
    }

    /// Read `claude auth status`: its JSON (the default), or the plain words an older one printed; nil when it
    /// printed neither.
    public static func parse(_ text: String) -> ClaudeCodeAuth? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = JSONValue(parsing: String(text[start...end])), let loggedIn = json["loggedIn"]?.bool else {
            let words = text.lowercased()
            if words.contains("not logged in") || words.contains("not signed in") { return ClaudeCodeAuth(loggedIn: false) }
            if words.contains("logged in") || words.contains("signed in") { return ClaudeCodeAuth(loggedIn: true) }
            return nil
        }
        func field(_ names: String...) -> String? {
            for name in names { if let value = json[name]?.string, !value.isEmpty { return value } }
            return nil
        }
        return ClaudeCodeAuth(loggedIn: loggedIn, authMethod: field("authMethod"), apiProvider: field("apiProvider"),
                              email: field("email", "emailAddress", "accountEmail"),
                              subscriptionType: field("subscriptionType", "subscription", "plan"))
    }

    /// Signed in, and the CLI talks to Anthropic with something other than an API key: a Claude plan.
    public var usesSubscription: Bool {
        guard loggedIn, isAnthropic else { return false }
        return !usesAPIKey
    }

    public var usesAPIKey: Bool { (authMethod ?? "").lowercased().contains("api") && !(authMethod ?? "").lowercased().contains("oauth") }

    public var isAnthropic: Bool {
        guard let provider = apiProvider?.lowercased(), !provider.isEmpty else { return true }
        return provider == "firstparty" || provider == "anthropic"
    }

    /// One line for the card ("Signed in with your Claude Max plan as pat@example.com").
    public var summary: String {
        guard loggedIn else { return "Not signed in." }
        if !isAnthropic {
            let name: String
            switch apiProvider?.lowercased() {
            case "bedrock": name = "Amazon Bedrock"
            case "vertex": name = "Google Vertex AI"
            case "foundry": name = "Microsoft Foundry"
            default: name = apiProvider ?? "another provider"
            }
            return "Signed in, but Claude Code is set to use \(name) — it bills that account, not a Claude plan."
        }
        if usesAPIKey {
            return "Signed in with an Anthropic API key — Claude Code bills that key's account, not a Claude plan."
        }
        let plan = subscriptionType.map { " \(Self.planName($0))" } ?? ""
        return "Signed in with your Claude\(plan) plan" + (email.map { " as \($0)" } ?? "") + "."
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": "Max"
        case "pro": "Pro"
        case "team": "Team"
        case "enterprise": "Enterprise"
        default: raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

// MARK: - The whole check

/// Where Claude Code stands on this Mac, for the card and before a turn.
public enum ClaudeCodeStatus: Sendable, Equatable {
    /// No `claude` anywhere Vision looks.
    case missing
    /// Found, but it didn't run or didn't say which version it is.
    case broken(path: String, problem: String)
    /// Found and runs, but it has no headless stream-json mode: too old.
    case tooOld(ClaudeCodeInstall)
    /// Found, not signed in.
    case signedOut(ClaudeCodeInstall)
    /// Found; this version can't say whether it is signed in (no `auth status`) — the first turn will tell.
    case unknownSignIn(ClaudeCodeInstall)
    case ready(ClaudeCodeInstall, ClaudeCodeAuth)

    public var install: ClaudeCodeInstall? {
        switch self {
        case .missing, .broken: nil
        case .tooOld(let i), .signedOut(let i), .unknownSignIn(let i), .ready(let i, _): i
        }
    }

    /// A chat can run on it (signed in, or a version that can't say).
    public var isUsable: Bool {
        switch self {
        case .ready, .unknownSignIn: true
        default: false
        }
    }

    public var auth: ClaudeCodeAuth? { if case .ready(_, let auth) = self { auth } else { nil } }

    /// The card's headline.
    public var summary: String {
        switch self {
        case .missing:
            return "Claude Code isn't installed on this Mac."
        case .broken(let path, let problem):
            return "The claude command at \(path) didn't start properly (\(problem))."
        case .tooOld(let install):
            return "Claude Code \(install.version ?? "") is too old for Vision (no headless stream mode). Update it: run `claude update` in Terminal."
        case .signedOut(let install):
            return "Claude Code \(install.version ?? "") is installed but not signed in."
        case .unknownSignIn(let install):
            return "Claude Code \(install.version ?? "") is installed. This version can't say whether it is signed in — the first message will tell."
        case .ready(let install, let auth):
            return "Claude Code \(install.version ?? "") — \(auth.summary)"
        }
    }

    /// What to do next, as steps with a command to copy; empty when nothing is needed.
    public var steps: [ClaudeCodeStep] {
        switch self {
        case .missing, .broken:
            return ClaudeCodeStep.install + ClaudeCodeStep.signIn
        case .tooOld:
            return [ClaudeCodeStep(text: "Update Claude Code in Terminal:", command: "claude update")]
        case .signedOut:
            return ClaudeCodeStep.signIn
        case .unknownSignIn, .ready:
            return []
        }
    }
}

/// One step on the card: what to do, and the Terminal command for it.
public struct ClaudeCodeStep: Sendable, Equatable, Hashable {
    public var text: String
    public var command: String?

    public init(text: String, command: String? = nil) {
        self.text = text
        self.command = command
    }

    /// Anthropic's installers, the recommended one first.
    public static let install: [ClaudeCodeStep] = [
        ClaudeCodeStep(text: "Install Claude Code — in Terminal, run Anthropic's installer:", command: "curl -fsSL https://claude.ai/install.sh | bash"),
        ClaudeCodeStep(text: "Or with Homebrew:", command: "brew install --cask claude-code"),
        ClaudeCodeStep(text: "Or with npm (Node.js 18 or newer):", command: "npm install -g @anthropic-ai/claude-code"),
    ]

    /// Signing in happens in the CLI, with the person's own Claude account — Vision never sees it.
    public static let signIn: [ClaudeCodeStep] = [
        ClaudeCodeStep(text: "Sign in with your Claude Pro or Max account — in Terminal, run this and follow the browser sign-in:", command: "claude auth login"),
        ClaudeCodeStep(text: "Then come back and press Check Again."),
    ]
}

public enum ClaudeCodeDetector {
    /// Find Claude Code and check it: the first candidate that runs wins (later ones are only tried while earlier
    /// ones fail). `claude --version`, then `claude --help` (its options), then — only when the help lists the
    /// `auth` command — `claude auth status`. An old CLI without `auth` is never sent "auth status", which it
    /// would take as a prompt for the model.
    public static func check(search: AWSCLISearch? = nil, explicitPath: String? = nil,
                             runner: any ClaudeCodeCommandRunner = ProcessClaudeCodeCommandRunner(),
                             home: String = NSHomeDirectory()) async -> ClaudeCodeStatus {
        let search = search ?? ClaudeCodeLocator.search(explicitPath: explicitPath, home: home)
        var best = ClaudeCodeStatus.missing
        for path in AWSCLI.candidates(search) {
            if Task.isCancelled { break }
            let status = await check(path: path, source: ClaudeCodeLocator.source(of: path, explicitPath: search.explicitPath, home: home),
                                     runner: runner)
            if status.isUsable || { if case .signedOut = status { return true } else { return false } }() { return status }
            if case .missing = best { best = status }
            if case .broken = best, case .tooOld = status { best = status }
        }
        return best
    }

    /// Check the `claude` at one path.
    public static func check(path: String, source: ClaudeCodeSource = .installed,
                             runner: any ClaudeCodeCommandRunner) async -> ClaudeCodeStatus {
        func problem(_ result: AWSCLIResult) -> String {
            let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut { return "it didn't answer" }
            return text.isEmpty ? "exit code \(result.exitCode)" : String(String(text.split(separator: "\n").first ?? "").prefix(200))
        }
        let versionResult: AWSCLIResult
        do {
            versionResult = try await runner.run(executable: path, arguments: ["--version"], timeout: 30)
        } catch {
            return .broken(path: path, problem: error.localizedDescription)
        }
        guard versionResult.succeeded, let version = ClaudeCodeInstall.parseVersion(versionResult.stdout) else {
            return .broken(path: path, problem: problem(versionResult))
        }
        var install = ClaudeCodeInstall(path: path, version: version, source: source)
        if let help = try? await runner.run(executable: path, arguments: ["--help"], timeout: 30), help.succeeded {
            let parsed = ClaudeCodeInstall.parseHelp(help.stdout)
            install.flags = parsed.flags
            install.commands = parsed.commands
        }
        guard install.canRunHeadless else { return .tooOld(install) }
        guard install.commands.contains("auth") else { return .unknownSignIn(install) }
        guard let result = try? await runner.run(executable: path, arguments: ["auth", "status"], timeout: 30),
              let auth = ClaudeCodeAuth.parse(result.stdout) ?? ClaudeCodeAuth.parse(result.stderr) else {
            return .unknownSignIn(install)
        }
        return auth.loggedIn ? .ready(install, auth) : .signedOut(install)
    }
}
