import Foundation

// MARK: - Chats from other AI tools, as Vision chats
//
// The "mixing bowl" (item 19): conversations kept by Claude Code (~/.claude/projects), Codex CLI (~/.codex/sessions),
// OpenClaw (~/.openclaw), a Claude.ai or ChatGPT data export, Guardian, and Vision's own JSON come in as REAL Vision
// chats — the same rows Vision writes for its own turns (user, assistant, tool, notice, error, compaction) with the
// times they were said, so any model can carry on from them. Vision never replays a tool call: the transcript it
// rebuilds for the model folds tool cards into a written "[earlier tool activity]" summary, so a chat started on one
// engine continues on any other.
//
// Reading is read-only and local; only the Guardian source makes network calls (to the signed-in Guardian).

/// Where a chat came from.
public enum ChatSource: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case openClaw = "openclaw"
    case claudeAI = "claude-ai"
    case chatGPT = "chatgpt"
    case guardian
    /// A Vision chat: a JSON export, or one a Vision harness kept in Guardian.
    case vision

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openClaw: "OpenClaw"
        case .claudeAI: "Claude.ai"
        case .chatGPT: "ChatGPT"
        case .guardian: "Guardian"
        case .vision: "Vision"
        }
    }

    /// The sources found by looking on this Mac (the others come from a file the person picks, or Guardian).
    public static let local: [ChatSource] = [.claudeCode, .codex, .openClaw]
}

/// One transcript row, in the shape Vision stores (`ConversationLog`): `kind` is user | assistant | tool | notice |
/// error | compaction. A tool row's `text` is its one-line result, `argSummary` what it was called with, `output`
/// the result itself.
public struct ImportedRow: Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case user, assistant, tool, notice, error, compaction
    }

    public var kind: Kind
    public var text: String?
    public var toolName: String?
    public var argSummary: String?
    public var output: String?
    public var isError: Bool
    public var at: Date

    public init(kind: Kind, text: String? = nil, toolName: String? = nil, argSummary: String? = nil,
                output: String? = nil, isError: Bool = false, at: Date) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.argSummary = argSummary
        self.output = output
        self.isError = isError
        self.at = at
    }

    /// A message the person or the model said (what the preview counts).
    public var isMessage: Bool { kind == .user || kind == .assistant }
}

/// One whole chat read from a source.
public struct ImportedChat: Sendable, Hashable {
    public var source: ChatSource
    /// The source's own id for the conversation (a session id, a conversation uuid…): the dedupe key with `source`.
    public var sourceID: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// The folder it worked in at the source (Claude Code, Codex), when it said.
    public var cwd: String?
    /// The model it last talked to, when the source said.
    public var model: String?
    public var rows: [ImportedRow]
    /// A Vision chat keeps its own id when it comes back (a round trip through Guardian is the same chat).
    public var preferredID: String?
    /// Work nobody typed: a cron run, a scripted (headless) session, a subagent.
    public var automated: Bool
    /// Subagent transcripts the source kept beside this chat (not imported; their results are in the tool rows).
    public var subagents: Int

    public init(source: ChatSource, sourceID: String, title: String, createdAt: Date, updatedAt: Date,
                cwd: String? = nil, model: String? = nil, rows: [ImportedRow], preferredID: String? = nil,
                automated: Bool = false, subagents: Int = 0) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.model = model
        self.rows = rows
        self.preferredID = preferredID
        self.automated = automated
        self.subagents = subagents
    }

    public var key: String { ChatImportKey.make(source, sourceID) }
    public var messageCount: Int { rows.filter(\.isMessage).count }
}

/// "<source>:<id>" — how an imported chat remembers where it came from, and how a second import knows it already
/// has it.
public enum ChatImportKey {
    public static func make(_ source: ChatSource, _ sourceID: String) -> String { source.rawValue + ":" + sourceID }
    public static func make(_ source: String, _ sourceID: String) -> String { source + ":" + sourceID }
}

/// Where a previewed chat's full transcript is read from at import time.
public enum ChatImportLocation: Hashable, Sendable, Codable {
    /// A Claude Code, Codex or OpenClaw JSONL file.
    case file(URL)
    /// An OpenClaw session in its SQLite store.
    case openClawDatabase(URL, sessionID: String)
    /// Already read whole (a Claude.ai / ChatGPT export, a Vision JSON file): the scan holds it.
    case loaded
    /// A Guardian chat (`GET /api/chats/:id`, paged).
    case guardianChat(String)
    /// A Vision chat kept in Guardian (`GET /api/harness/chats/:id`).
    case guardianHarnessChat(String)
}

/// One line of the import preview: enough to choose by, without reading every transcript whole.
public struct ChatImportCandidate: Identifiable, Hashable, Sendable, Codable {
    public var source: ChatSource
    public var sourceID: String
    public var title: String
    public var createdAt: Date?
    public var updatedAt: Date
    /// Messages said (user + assistant); nil when the source can't say without reading the chat whole (Guardian).
    public var messageCount: Int?
    public var cwd: String?
    public var automated: Bool
    /// A short extra line: "Cron run", "Shared with you by …", the project's folder name.
    public var detail: String?
    public var location: ChatImportLocation
    /// A Vision chat's own id (it keeps it on import).
    public var preferredID: String?

    public init(source: ChatSource, sourceID: String, title: String, createdAt: Date? = nil, updatedAt: Date,
                messageCount: Int?, cwd: String? = nil, automated: Bool = false, detail: String? = nil,
                location: ChatImportLocation, preferredID: String? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.cwd = cwd
        self.automated = automated
        self.detail = detail
        self.location = location
        self.preferredID = preferredID
    }

    public var id: String { ChatImportKey.make(source, sourceID) }

    public init(_ chat: ImportedChat, location: ChatImportLocation, detail: String? = nil) {
        self.init(source: chat.source, sourceID: chat.sourceID, title: chat.title, createdAt: chat.createdAt,
                  updatedAt: chat.updatedAt, messageCount: chat.messageCount, cwd: chat.cwd,
                  automated: chat.automated, detail: detail, location: location, preferredID: chat.preferredID)
    }
}

/// What a scan of one source found.
public struct ChatImportScan: Sendable {
    public var candidates: [ChatImportCandidate]
    /// Chats read whole during the scan (exports, Vision files), by candidate id.
    public var loaded: [String: ImportedChat]
    /// Things that couldn't be read, in plain words (one file per line, at most a few).
    public var problems: [String]

    public init(candidates: [ChatImportCandidate] = [], loaded: [String: ImportedChat] = [:], problems: [String] = []) {
        self.candidates = candidates
        self.loaded = loaded
        self.problems = problems
    }

    public init(chats: [ImportedChat], problems: [String] = []) {
        self.candidates = chats.map { ChatImportCandidate($0, location: .loaded) }
        self.loaded = Dictionary(chats.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        self.problems = problems
    }
}

public enum ChatImportError: LocalizedError, Equatable {
    case unreadable(String)
    case unknownFormat(String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "Couldn't read that file: \(detail)"
        case .unknownFormat(let name): "\(name) isn't a chat export Vision knows — choose a Claude.ai or ChatGPT export (.zip or conversations.json), or a Vision chat (.json)."
        case .empty(let name): "\(name) holds no conversations."
        }
    }
}
