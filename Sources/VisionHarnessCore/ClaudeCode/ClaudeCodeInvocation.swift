import Foundation

// MARK: - One `claude -p` turn: its command line and what goes into it
//
// Each Vision turn on Claude Code is one headless run in the chat's folder:
//
//   claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
//          --model <alias> [--effort <level>] <permissions> (--session-id <uuid> | --resume <id>)
//          --append-system-prompt <Vision's note> [--add-dir <attachments>] [--permission-prompts none]
//
// The prompt goes in on standard input as one stream-json user message (no argument-length limit, pictures as
// image blocks), and the session id carries the conversation from turn to turn. Only options the installed CLI's
// own help lists are passed (`ClaudeCodeInstall.flags`).

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

/// The models a Claude Code route offers: Claude Code's own aliases, which it maps to the newest of each.
public enum ClaudeCodeModels {
    public struct Choice: Sendable, Equatable, Hashable {
        public var alias: String
        public var name: String
        public var detail: String
    }

    public static let choices: [Choice] = [
        Choice(alias: "opus", name: "Opus", detail: "The most capable — best for hard, long work. Uses your plan's limits fastest."),
        Choice(alias: "sonnet", name: "Sonnet", detail: "Fast and strong — the everyday choice."),
        Choice(alias: "haiku", name: "Haiku", detail: "The quickest and lightest on your plan's limits."),
        Choice(alias: "default", name: "Claude Code's default", detail: "Whatever Claude Code itself picks for your plan."),
    ]

    /// How a route's model is named in menus ("Opus"); an id Vision doesn't know is shown as it is.
    public static func name(_ alias: String) -> String {
        choices.first { $0.alias == alias.lowercased() }?.name ?? alias
    }

    /// The context window Vision budgets for a Claude Code model: 1M for a "[1m]" model, else 200K.
    public static func contextWindow(_ model: String) -> Int {
        model.lowercased().contains("[1m]") ? 1_000_000 : 200_000
    }
}

public struct ClaudeCodeInvocation: Sendable, Equatable {
    /// A Claude Code model alias or id; nil or "default" = let Claude Code choose.
    public var model: String?
    /// `--effort` (low, medium, high, max); nil = Claude Code's default.
    public var effort: String?
    public var preset: PermissionPreset
    public var session: ClaudeCodeSessionChoice?
    /// Added after Claude Code's own system prompt.
    public var appendSystemPrompt: String?
    /// Folders besides the working directory that Claude Code may read (a turn's attachments).
    public var addDirs: [String]
    /// Most agentic steps in this turn (nil = no cap). Passed only when the CLI lists `--max-turns`.
    public var maxTurns: Int?
    /// One-shot side tasks (a summary, a skill draft): Claude Code's system prompt replaced by this, no tools, and
    /// nothing saved as a session.
    public var oneShotSystemPrompt: String?

    public init(model: String? = nil, effort: String? = nil, preset: PermissionPreset = .workspaceWrite,
                session: ClaudeCodeSessionChoice? = nil, appendSystemPrompt: String? = nil, addDirs: [String] = [],
                maxTurns: Int? = nil, oneShotSystemPrompt: String? = nil) {
        self.model = model
        self.effort = effort
        self.preset = preset
        self.session = session
        self.appendSystemPrompt = appendSystemPrompt
        self.addDirs = addDirs
        self.maxTurns = maxTurns
        self.oneShotSystemPrompt = oneShotSystemPrompt
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
            if install.supports("--system-prompt") { args += ["--system-prompt", system] }
            if install.supports("--tools") { args += ["--tools", ""] }
            if install.supports("--no-session-persistence") { args.append("--no-session-persistence") }
            return args
        }
        args += Self.permissionArguments(preset)
        // Nobody can answer a permission question in a headless run; this tells Claude so, and not to retry.
        if install.supports("--permission-prompts") { args += ["--permission-prompts", "none"] }
        switch session {
        case .new(let id) where install.supports("--session-id"): args += ["--session-id", id]
        case .resume(let id): args += ["--resume", id]
        default: break
        }
        if let note = appendSystemPrompt, !note.isEmpty, install.supports("--append-system-prompt") {
            args += ["--append-system-prompt", note]
        }
        for dir in addDirs where install.supports("--add-dir") { args += ["--add-dir", dir] }
        if let maxTurns, maxTurns > 0, install.supports("--max-turns") { args += ["--max-turns", String(maxTurns)] }
        return args
    }

    // MARK: Permissions

    /// Shell commands that change things, as Claude Code deny rules — the same list Vision's own engine asks
    /// about under "Workspace write" (`PermissionPolicy.checkShell`). A headless run can't ask, so they are
    /// refused, and Claude reports what it couldn't do.
    public static let askingCommands = ["rm", "sudo", "mv", "cp", "mkdir", "chmod", "chown", "dd", "git push",
                                        "git commit", "git checkout", "git reset", "git rebase", "git merge",
                                        "git branch -d", "brew install", "pip install", "npm install"]

    /// Vision's permission preset as Claude Code's permission mode and tool rules:
    /// - Plan only → `plan` mode: Claude reads and plans, changes nothing, runs nothing that changes anything.
    /// - Workspace write → `acceptEdits` (file edits inside the chat's folder go through, outside it they are
    ///   refused), shell commands and web fetches allowed, except the commands Vision would ask about.
    /// - Full access → `acceptEdits` with every shell command and web fetch allowed (file edits still stay in
    ///   the chat's folder, as with Vision's own engine).
    public static func permissionArguments(_ preset: PermissionPreset) -> [String] {
        switch preset {
        case .plan:
            return ["--permission-mode", "plan"]
        case .workspaceWrite:
            return ["--permission-mode", "acceptEdits",
                    "--allowedTools", "Bash,WebFetch,WebSearch",
                    "--disallowedTools", askingCommands.map { "Bash(\($0) *)" }.joined(separator: ",")]
        case .fullAccess:
            return ["--permission-mode", "acceptEdits", "--allowedTools", "Bash,WebFetch,WebSearch"]
        }
    }
}

// MARK: - The prompt on standard input

/// A picture sent with the prompt as an image block.
public struct ClaudeCodeImage: Sendable, Equatable {
    public var mediaType: String
    public var data: Data

    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}

public enum ClaudeCodeInput {
    /// The user message as one stream-json line: `{"type":"user","message":{"role":"user","content":[…]},
    /// "parent_tool_use_id":null}` followed by a newline.
    public static func line(text: String, images: [ClaudeCodeImage] = []) -> Data {
        var content: [JSONValue] = []
        for image in images {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": .string(image.mediaType),
                                       "data": .string(image.data.base64EncodedString())]])
        }
        content.append(["type": "text", "text": .string(text)])
        let message: JSONValue = ["type": "user",
                                  "message": ["role": "user", "content": .array(content)],
                                  "parent_tool_use_id": nil]
        return Data((message.serialized() + "\n").utf8)
    }

    /// Pictures Claude takes inline (the API's limit is 5 MB per picture, after base64).
    static let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    static let maxInlineImageBytes = 3_700_000
    /// Text up to this many characters goes in the prompt; a longer file is saved for Claude to Read.
    static let maxInlineTextCharacters = 40_000

    /// A turn's attachments, the way Claude Code takes them best: small text files inline in the prompt, small
    /// pictures as image blocks, and everything else (a PDF, a long file, a big picture) saved in `folder` for
    /// Claude to open with its Read tool, which reads PDFs and pictures itself.
    public static func prepare(_ attachments: [MessageAttachment], folder: URL) -> (text: String, images: [ClaudeCodeImage], saved: Bool) {
        var lines: [String] = []
        var images: [ClaudeCodeImage] = []
        var saved = false
        var usedNames = Set<String>()
        for attachment in attachments {
            if attachment.kind == .image, inlineImageTypes.contains(attachment.mime), attachment.data.count <= maxInlineImageBytes {
                images.append(ClaudeCodeImage(mediaType: attachment.mime, data: attachment.data))
                lines.append("[Picture attached: \(attachment.name)]")
                continue
            }
            if attachment.kind == .file, attachment.mime != "application/pdf",
               let text = String(data: attachment.data, encoding: .utf8), !text.contains("\u{0}"),
               text.count <= maxInlineTextCharacters {
                lines.append("--- \(attachment.name) ---\n\(text)\n--- end of \(attachment.name) ---")
                continue
            }
            var name = safeName(attachment.name)
            var n = 2
            while usedNames.contains(name) {
                name = "\(n)-" + safeName(attachment.name)
                n += 1
            }
            usedNames.insert(name)
            let url = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try attachment.data.write(to: url, options: .atomic)
                saved = true
                lines.append("[Attached file \(attachment.name) is saved at \(url.path) — open it with your Read tool.]")
            } catch {
                lines.append("[Attached file \(attachment.name) could not be saved for you: \(error.localizedDescription)]")
            }
        }
        return (lines.joined(separator: "\n\n"), images, saved)
    }

    /// A file name with no folders, no leading dot and nothing odd ("../x" → "x"; "" → "attachment").
    static func safeName(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        let cleaned = String(last.map { $0 == "/" || $0 == ":" || $0.isNewline ? "_" : $0 })
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(120))
    }
}
