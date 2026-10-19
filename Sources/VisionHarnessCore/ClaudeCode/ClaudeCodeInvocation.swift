import Foundation

// MARK: - One `claude -p` turn: its command line and what goes down stdin
//
// Each Vision turn on Claude Code is one headless run in the chat's folder:
//
//   claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
//          --model <alias> [--effort <level>] --permission-mode <plan|default|acceptEdits> --permission-prompt-tool stdio
//          [--setting-sources user] (--resume <id> | --session-id <uuid>) --append-system-prompt <Vision's note>
//          [--add-dir <attachments>]
//
// `--setting-sources user` unless the person trusted the folder in Claude Code (`ClaudeCodeTrust`): headless, the CLI
// would otherwise run a folder's own hooks and MCP servers without asking anyone.
//
// The prompt goes in on standard input as one stream-json user message (pictures and PDFs as content blocks), and
// standard input stays open: Claude Code asks Vision before each tool call that needs permission (`can_use_tool`
// control requests — see `ClaudeCodePermissions`), and a Stop is an `interrupt` control request. It is closed once the
// turn's result arrives. Optional options are passed only when the installed CLI's help lists them. Vision for
// Windows sends the same (ClaudeCodeCommand.cs).

/// Which Claude Code conversation a turn continues.
public enum ClaudeCodeSessionChoice: Sendable, Equatable {
    /// Start one under this id (`--session-id`, a UUID Vision makes so it knows the id before anything prints).
    case new(String)
    /// Continue this one (`--resume`).
    case resume(String)

    public var id: String {
        switch self {
        case .new(let id), .resume(let id): id
        }
    }
}

/// The models a Claude Code route offers: Claude Code's own aliases, which always mean the newest of each family.
public enum ClaudeCodeModels {
    public struct Choice: Sendable, Equatable, Hashable {
        public var alias: String
        public var name: String
        public var detail: String
    }

    /// Most capable first (the same titles and words as Vision for Windows).
    public static let choices: [Choice] = [
        Choice(alias: "opus", name: "Opus", detail: "the most capable — long, hard work"),
        Choice(alias: "sonnet", name: "Sonnet", detail: "fast and capable — the everyday choice"),
        Choice(alias: "haiku", name: "Haiku", detail: "the quickest — small jobs"),
    ]

    /// The model a new Claude Code chat starts on.
    public static let defaultModel = "sonnet"

    /// How a route's model is named in menus ("Sonnet"); an id Vision doesn't know is shown as it is.
    public static func name(_ alias: String) -> String {
        choices.first { $0.alias == alias.lowercased() }?.name ?? alias
    }

    /// The context window Vision budgets for a Claude Code model until a turn's result says (1M for a "[1m]" model).
    public static func contextWindow(_ model: String) -> Int {
        if let learned = learnedWindow(model) { return learned }
        return model.lowercased().contains("[1m]") ? 1_000_000 : 200_000
    }

    nonisolated(unsafe) private static var learned: [String: Int] = [:]
    private static let lock = NSLock()

    /// The window a turn's result reported for the model behind `alias` (`modelUsage.<model>.contextWindow`).
    public static func learnedWindow(_ alias: String) -> Int? { lock.withLock { learned[alias.lowercased()] } }

    public static func learnWindow(_ alias: String, _ window: Int) {
        guard window > 0 else { return }
        lock.withLock { learned[alias.lowercased()] = window }
    }
}

public struct ClaudeCodeInvocation: Sendable, Equatable {
    /// A Claude Code model alias or id; empty or "default" = let Claude Code choose.
    public var model: String?
    /// `--effort` (low, medium, high, max); nil = Claude Code's default.
    public var effort: String?
    public var preset: PermissionPreset
    public var session: ClaudeCodeSessionChoice?
    /// Added after Claude Code's own system prompt.
    public var appendSystemPrompt: String?
    /// Folders besides the working directory that Claude Code may read (where a long attachment's text is saved).
    public var addDirs: [String]
    /// One-shot side tasks (a summary, a skill draft): Claude Code's system prompt replaced by this, no tools, no MCP
    /// servers, only the person's own settings, and nothing saved as a session.
    public var oneShotSystemPrompt: String?
    /// The folder's own Claude Code settings load too (the person trusted it in Claude Code — `ClaudeCodeTrust`);
    /// false = only the person's own (`--setting-sources user`).
    public var projectSettings: Bool

    public init(model: String? = nil, effort: String? = nil, preset: PermissionPreset = .workspaceWrite,
                session: ClaudeCodeSessionChoice? = nil, appendSystemPrompt: String? = nil, addDirs: [String] = [],
                oneShotSystemPrompt: String? = nil, projectSettings: Bool = false) {
        self.model = model
        self.effort = effort
        self.preset = preset
        self.session = session
        self.appendSystemPrompt = appendSystemPrompt
        self.addDirs = addDirs
        self.oneShotSystemPrompt = oneShotSystemPrompt
        self.projectSettings = projectSettings
    }

    /// The command line for `install` (after the executable).
    public func arguments(for install: ClaudeCodeInstall) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if install.supports("--include-partial-messages") { args.append("--include-partial-messages") }
        if let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty, model.lowercased() != "default" {
            args += ["--model", model]
        }
        if let effort, install.supports("--effort") { args += ["--effort", effort] }
        if let system = oneShotSystemPrompt {
            if install.supports("--setting-sources") { args += ["--setting-sources", "user"] }
            if install.supports("--strict-mcp-config") { args.append("--strict-mcp-config") }
            if install.supports("--system-prompt") { args += ["--system-prompt", system] }
            if install.supports("--tools") { args += ["--tools", ""] }
            if install.supports("--no-session-persistence") { args.append("--no-session-persistence") }
            return args
        }
        // Permission questions come to Vision over the control protocol (a hidden option, so not in the help).
        args += ["--permission-mode", Self.permissionMode(preset), "--permission-prompt-tool", "stdio"]
        if !projectSettings, install.supports("--setting-sources") { args += ["--setting-sources", "user"] }
        switch session {
        case .resume(let id): args += ["--resume", id]
        case .new(let id) where install.supports("--session-id"): args += ["--session-id", id]
        default: break
        }
        if let note = appendSystemPrompt, !note.isEmpty, install.supports("--append-system-prompt") {
            args += ["--append-system-prompt", note]
        }
        for dir in addDirs where !dir.isEmpty && install.supports("--add-dir") { args += ["--add-dir", dir] }
        return args
    }

    /// Claude Code's permission mode for a chat's preset. Plan only → plan (Claude Code itself changes nothing);
    /// Workspace write → default (every tool call that needs permission is asked of Vision, which decides with the
    /// chat's own policy — `ClaudeCodePermissions.decide`); Full access → acceptEdits (edits go ahead without a round
    /// trip; Vision answers the rest, all yes).
    public static func permissionMode(_ preset: PermissionPreset) -> String {
        switch preset {
        case .plan: "plan"
        case .workspaceWrite: "default"
        case .fullAccess: "acceptEdits"
        }
    }
}

// MARK: - What goes down stdin

public enum ClaudeCodeInput {
    /// How Claude Code takes attachments, within what the Messages API accepts in one request (32 MB, base64
    /// included; an image's 5 MB is counted on its base64) and what was checked through the CLI: up to 20 pictures
    /// (PNG, JPEG, GIF, WebP) of at most 3.75 MB and up to 5 PDFs of 100 pages in all, at most 12 MB of pictures
    /// and PDFs per message, as themselves; past that — and everything else — as the text Vision read out of it.
    /// (Claude Code 2.1.299 passed a 12 MB PDF — a 16.8 MB stream-json line — straight through to the API; larger
    /// lines weren't tried, and a resumed session sends its earlier attachments again with every request.)
    public static let attachmentRoute = AttachmentRoute(vision: true, documents: true,
                                                        imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"],
                                                        maxImages: 20, maxImageBytes: 3_750_000,
                                                        maxDocuments: 5, maxDocumentBytes: maxAttachmentBytes,
                                                        maxDocumentPages: 100, maxTotalBytes: maxAttachmentBytes)
    /// Pictures and PDFs in one message, all together, before base64 (12 MB).
    public static let maxAttachmentBytes = 12 * 1024 * 1024

    /// The user message that starts a turn, as one stream-json line: its text, then pictures and PDFs as content
    /// blocks — `{"type":"user","message":{"role":"user","content":[…]},"parent_tool_use_id":null,"session_id":""}`.
    public static func line(text: String, parts: [AttachmentWirePart] = []) -> String {
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        for part in parts {
            switch part {
            case .text(let value):
                content.append(["type": "text", "text": .string(value)])
            case .image(let mime, let data):
                content.append(["type": "image",
                                "source": ["type": "base64", "media_type": .string(mime), "data": .string(data.base64EncodedString())]])
            case .document(let name, let data):
                content.append(["type": "document",
                                "source": ["type": "base64", "media_type": "application/pdf", "data": .string(data.base64EncodedString())],
                                "title": .string(name)])
            }
        }
        if content.isEmpty { content.append(["type": "text", "text": "(empty message)"]) }
        let message: JSONValue = ["type": "user",
                                  "message": ["role": "user", "content": .array(content)],
                                  "parent_tool_use_id": nil,
                                  "session_id": ""]
        return message.serialized()
    }

    /// Stop the turn: Claude Code ends it cleanly, keeping what was done, and says so in its result.
    public static func interrupt(requestID: String) -> String {
        JSONValue(["type": "control_request", "request_id": .string(requestID), "request": ["subtype": "interrupt"]]).serialized()
    }

    /// Yes to a permission question: the tool runs with its input as asked.
    public static func allow(requestID: String, input: JSONValue?, toolUseID: String?) -> String {
        var payload: [String: JSONValue] = ["behavior": "allow", "updatedInput": input ?? [:]]
        if let toolUseID { payload["toolUseID"] = .string(toolUseID) }
        return response(requestID, payload)
    }

    /// No to a permission question: Claude Code tells the model `message` instead of running it.
    public static func deny(requestID: String, message: String, toolUseID: String?) -> String {
        var payload: [String: JSONValue] = ["behavior": "deny", "message": .string(message)]
        if let toolUseID { payload["toolUseID"] = .string(toolUseID) }
        return response(requestID, payload)
    }

    /// A control request Vision doesn't handle: an error answer, so the CLI never waits on it.
    public static func unhandled(requestID: String, subtype: String) -> String {
        JSONValue(["type": "control_response",
                   "response": ["subtype": "error", "request_id": .string(requestID),
                                "error": .string("Vision doesn't handle \(subtype) requests.")]]).serialized()
    }

    private static func response(_ requestID: String, _ payload: [String: JSONValue]) -> String {
        JSONValue(["type": "control_response",
                   "response": ["subtype": "success", "request_id": .string(requestID), "response": .object(payload)]]).serialized()
    }
}

private extension JSONValue {
    init(_ object: [String: JSONValue]) { self = .object(object) }
}
