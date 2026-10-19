import Foundation

// MARK: - What an OpenClaw install holds, as Vision shows it
//
// The same shapes as Vision for Windows (Vision.Core/OpenClaw/OpenClawModels.cs): skills, memory files,
// keys and passwords, model servers — plus what was found but isn't imported, said plainly. Secrets are held
// in `OpenClawSecret`, which prints only a fingerprint.

/// A secret held in memory. Printing it, logging it or interpolating it shows only a fingerprint; the value comes
/// out through `reveal()` and nowhere else.
public struct OpenClawSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) { self.value = value }

    /// The secret itself. Call it only where it is being stored.
    public func reveal() -> String { value }

    public var count: Int { value.count }

    /// "sha256:1a2b3c4d5e6f" — enough to tell two values apart, not enough to recover one.
    public var fingerprint: String { CredentialVault.fingerprint(value) }

    /// A hint for the import sheet: the first characters of a long key, never the rest.
    public var hint: String {
        if value.count < 16 { return String(repeating: "•", count: min(value.count, 12)) }
        return String(value.prefix(3)) + String(repeating: "•", count: 8) + " (\(value.count) characters)"
    }

    public var description: String { "[secret \(fingerprint)]" }
    public var debugDescription: String { description }
}

/// One OpenClaw state folder found on this Mac.
public struct OpenClawInstall: Sendable, Equatable, Hashable {
    /// The state folder (e.g. ~/.openclaw).
    public var stateDir: URL
    /// The config file inside it, when there is one.
    public var configPath: URL?
    /// "openclaw", "clawdbot" or "moltbot".
    public var flavor: String
    /// How it was found ("~/.openclaw", "OPENCLAW_STATE_DIR", "chosen").
    public var foundBy: String

    public init(stateDir: URL, configPath: URL?, flavor: String = "openclaw", foundBy: String = "") {
        self.stateDir = stateDir
        self.configPath = configPath
        self.flavor = flavor
        self.foundBy = foundBy
    }

    public var title: String {
        let path = (stateDir.path as NSString).abbreviatingWithTildeInPath
        return flavor == "openclaw" ? path : "\(path) (\(flavor))"
    }
}

/// A skill found in an OpenClaw workspace or its managed-skills folder.
public struct OpenClawSkill: Sendable, Equatable, Identifiable {
    public var id: String { directory.path }
    public var name: String
    public var description: String
    public var directory: URL
    /// "workspace", "managed" (~/.openclaw/skills), "plugin" or "extra" (a configured extra folder).
    public var location: String
    /// Files inside it, relative, "/"-separated.
    public var files: [String]
    public var hasScripts: Bool
    /// Another skill of the same name in a higher-priority place hides this one.
    public var shadowed: Bool
}

public enum OpenClawNoteKind: String, Sendable, Equatable {
    /// MEMORY.md — the curated long-term memory.
    case memory
    /// memory/YYYY-MM-DD.md — the daily log.
    case daily
    /// USER.md — what the agent knows about its user.
    case about
    /// SOUL.md / IDENTITY.md — the agent's personality.
    case persona
    /// AGENTS.md / TOOLS.md — operating instructions written for OpenClaw's own tools (its "rules").
    case instructions

    public var label: String {
        switch self {
        case .memory: "Memory"
        case .daily: "Daily log"
        case .about: "About you"
        case .persona: "Personality"
        case .instructions: "Rules and instructions"
        }
    }
}

/// One markdown file of memory.
public struct OpenClawNoteFile: Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public var path: URL
    /// "MEMORY.md", "memory/2026-10-01.md" (prefixed with the workspace when there are several).
    public var name: String
    public var kind: OpenClawNoteKind
    public var text: String
    /// Ticked when the sheet opens: memory, recent daily logs and USER.md are; personality and rules are opt-in.
    public var selectedByDefault: Bool
    /// The day of a daily log ("2026-10-01").
    public var day: String?

    public var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
}

/// A key, token or password from an OpenClaw install.
public struct OpenClawCredential: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// A vault-legal name (letters, digits, _ - .).
    public var name: String
    public var secret: OpenClawSecret
    public var kind: VaultEntry.Kind
    public var description: String
    /// Where it was found: "auth-profiles.json (anthropic:default)", "openclaw.json env.vars.FRESHDESK_API_KEY".
    public var origin: String
    public var provider: String?
    public var username: String?
    public var url: String?
    /// Other names the same value had (it is stored once).
    public var alsoNamed: [String]
}

/// A model server OpenClaw is configured to use.
public struct OpenClawModelServer: Sendable, Equatable, Identifiable {
    public var id: String
    public var baseURL: String
    public var api: String?
    public var models: [String]
    public var contextWindow: Int?
    public var apiKey: OpenClawSecret?
    /// Vision can talk to it (an OpenAI-style chat completions endpoint).
    public var compatible: Bool
    public var note: String?
    /// The model OpenClaw's agents use by default, when it belongs to this server.
    public var defaultModel: String?
}

/// An agent defined in the config (OpenClaw runs one or more, each with a model and a workspace).
public struct OpenClawAgent: Sendable, Equatable {
    public var id: String
    public var model: String?
    public var workspace: String?
}

/// Everything read from one install, ready to be shown and then imported.
public struct OpenClawBundle: Sendable {
    public var install: OpenClawInstall
    public var workspaces: [URL] = []
    public var skills: [OpenClawSkill] = []
    public var noteFiles: [OpenClawNoteFile] = []
    public var credentials: [OpenClawCredential] = []
    public var modelServers: [OpenClawModelServer] = []
    public var agents: [OpenClawAgent] = []
    /// Found but not something Vision imports (channels, cron jobs, sessions…), said plainly.
    public var left: [String] = []
    /// Things that couldn't be read.
    public var problems: [String] = []

    public var isEmpty: Bool { skills.isEmpty && noteFiles.isEmpty && credentials.isEmpty && modelServers.isEmpty }
}
