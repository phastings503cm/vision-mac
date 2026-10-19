import Foundation

// MARK: - Claude Code's tools, as Vision shows them
//
// The same names, previews and headlines as Vision for Windows (ClaudeCodeTools in ClaudeCodeStream.cs), so a Claude
// Code turn reads the same on both.

public enum ClaudeCodeTools {
    /// The Vision tool a Claude Code tool matches, so its row gets the same icon and label (unknown ones — MCP tools,
    /// WebSearch — keep their own name).
    public static func visionName(_ tool: String) -> String {
        switch tool {
        case "Read": "read_file"
        case "Write": "write_file"
        case "Edit", "MultiEdit", "NotebookEdit": "edit"
        case "Bash", "PowerShell": "run_shell_command"
        case "Glob": "glob"
        case "Grep": "grep"
        case "LS": "list_directory"
        case "WebFetch": "web_fetch"
        case "TodoWrite", "TaskCreate", "TaskUpdate": "todo_write"
        case "Task", "Agent": "agent"
        case "ExitPlanMode": ExitPlanModeTool.name
        case "Skill": "use_skill"
        default: tool
        }
    }

    /// A person's word for a tool ("Run", "Edit"), for permission questions and the subagent line.
    public static func label(_ tool: String) -> String {
        switch tool {
        case "Read": return "Read"
        case "Write": return "Write"
        case "Edit", "MultiEdit": return "Edit"
        case "NotebookEdit": return "Edit notebook"
        case "Bash", "PowerShell": return "Run"
        case "Glob": return "Find files"
        case "Grep": return "Search"
        case "WebFetch": return "Fetch"
        case "WebSearch": return "Web search"
        case "Task", "Agent": return "Subagent"
        case "ExitPlanMode": return "Present plan"
        case "AskUserQuestion": return "Ask you"
        default:
            if tool.hasPrefix("mcp__") {
                return "MCP " + tool.components(separatedBy: "__").dropFirst().joined(separator: " · ")
            }
            return tool
        }
    }

    /// One line saying what a call does: the file (relative to the chat's folder), the command, the pattern, the URL.
    public static func preview(_ tool: String, _ input: JSONValue?, workspace: URL? = nil) -> String {
        func str(_ key: String) -> String? { input?[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        func path(_ raw: String?) -> String {
            guard let raw else { return "" }
            if let workspace {
                let root = workspace.standardizedFileURL.path
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if raw.hasPrefix(prefix) { return String(raw.dropFirst(prefix.count)) }
            }
            return raw
        }
        let text: String
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit": text = path(str("file_path"))
        case "NotebookEdit": text = path(str("notebook_path"))
        case "Bash", "PowerShell": text = str("command") ?? ""
        case "Glob": text = str("pattern") ?? ""
        case "Grep": text = (str("pattern") ?? "") + (str("path").map { "  in \(path($0))" } ?? "")
        case "LS": text = path(str("path"))
        case "WebFetch": text = str("url") ?? ""
        case "WebSearch": text = str("query") ?? ""
        case "Task", "Agent": text = str("description") ?? str("prompt") ?? ""
        case "Skill": text = str("skill") ?? str("name") ?? ""
        case "TodoWrite":
            if let todos = input?["todos"]?.array { text = "\(todos.count) step\(todos.count == 1 ? "" : "s")" } else { text = "" }
        case "TaskCreate": text = str("subject") ?? ""
        case "TaskUpdate":
            text = (str("subject") ?? "task \(str("taskId") ?? "")")
                + (str("status").map { " → " + $0.replacingOccurrences(of: "_", with: " ") } ?? "")
        case "ExitPlanMode": text = "the plan"
        default: text = input.map { $0.serialized() } ?? ""
        }
        return prefix(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), 240)
    }

    /// The text a tool_result carries (a string, or its text blocks).
    public static func contentText(_ content: JSONValue?) -> String {
        if let text = content?.string { return text }
        return (content?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }

    /// The pictures a tool_result carries.
    public static func images(_ content: JSONValue?) -> [MessageAttachment] {
        (content?.array ?? []).compactMap { block in
            guard block["type"]?.string == "image", let data = block["source"]?["data"]?.string.flatMap({ Data(base64Encoded: $0) })
            else { return nil }
            let mime = block["source"]?["media_type"]?.string ?? "image/png"
            return MessageAttachment(kind: .image, name: "image." + (mime.split(separator: "/").last.map(String.init) ?? "png"), data: data)
        }
    }

    /// The row's one-line headline once the call is done (`result` = the message's `tool_use_result`).
    public static func summary(_ tool: String, input: JSONValue?, result: JSONValue?, content: String, isError: Bool) -> String {
        func firstLine(_ text: String) -> String {
            prefix(text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces) ?? "", 160)
        }
        if isError {
            let line = firstLine(content.replacingOccurrences(of: "<tool_use_error>", with: "").replacingOccurrences(of: "</tool_use_error>", with: ""))
            return line.isEmpty ? "Failed" : line
        }
        let name = ((input?["file_path"]?.string ?? input?["notebook_path"]?.string ?? "") as NSString).lastPathComponent
        switch tool {
        case "Read":
            if let lines = result?["file"]?["numLines"]?.int { return "Read \(lines) line\(lines == 1 ? "" : "s") of \(name)" }
            return "Read \(name)"
        case "Write":
            return result?["type"]?.string == "update" ? "Updated \(name)" : "Created \(name)"
        case "Edit", "MultiEdit":
            let (added, removed) = patchCounts(result?["structuredPatch"])
            return added + removed > 0 ? "Edited \(name) (+\(added) −\(removed))" : "Edited \(name)"
        case "NotebookEdit":
            return "Edited \(name)"
        case "Bash", "PowerShell":
            if result?["interrupted"]?.bool == true { return "Interrupted" }
            let first = firstLine(result?["stdout"]?.string ?? content)
            return first.isEmpty || first == "(Bash completed with no output)" ? "Done (no output)" : first
        case "Glob":
            if let files = result?["numFiles"]?.int { return "\(files) file\(files == 1 ? "" : "s")" }
            return firstLine(content)
        case "Grep":
            if let matches = result?["numMatches"]?.int { return "\(matches) match\(matches == 1 ? "" : "es")" }
            if let files = result?["numFiles"]?.int { return "\(files) file\(files == 1 ? "" : "s")" }
            return firstLine(content)
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Plan updated"
        case "ExitPlanMode":
            return "Plan presented"
        default:
            let line = firstLine(content)
            return line.isEmpty ? "Done" : line
        }
    }

    static func patchCounts(_ patch: JSONValue?) -> (Int, Int) {
        var added = 0, removed = 0
        for hunk in patch?.array ?? [] {
            for line in hunk["lines"]?.array ?? [] {
                guard let text = line.string else { continue }
                if text.hasPrefix("+") { added += 1 } else if text.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    /// The file a finished call created or changed. `Write` says in its result whether it created the file.
    public static func change(_ tool: String, input: JSONValue?, result: JSONValue?, workspace: URL) -> FileChange? {
        let raw: String?
        switch tool {
        case "Write", "Edit", "MultiEdit": raw = result?["filePath"]?.string ?? input?["file_path"]?.string
        case "NotebookEdit": raw = result?["notebook_path"]?.string ?? input?["notebook_path"]?.string
        default: return nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        let kind: FileChange.Kind = tool == "Write" && result?["type"]?.string == "create" ? .created : .modified
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : workspace.appendingPathComponent(raw)
        return FileChange(url.standardizedFileURL, kind)
    }

    /// `TodoWrite`'s list as Vision's plan steps.
    public static func todos(_ input: JSONValue?) -> [TodoItem]? {
        guard let items = input?["todos"]?.array else { return nil }
        var out: [TodoItem] = []
        for (index, item) in items.enumerated() {
            guard let content = item["content"]?.string ?? item["subject"]?.string, !content.isEmpty else { continue }
            out.append(TodoItem(id: item["id"]?.string ?? "\(index + 1)", content: content, status: status(item["status"]?.string)))
        }
        return out
    }

    static func status(_ raw: String?) -> TodoItem.Status {
        switch raw {
        case "in_progress": .inProgress
        case "completed": .completed
        default: .pending
        }
    }

    /// At most `limit` characters, cut plainly (as Vision for Windows' TextUtil.Prefix).
    static func prefix(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }
}

// MARK: - Words

/// What the card and the wizard say about Claude Code (Vision for Windows' ClaudeCodeRoutes words).
public enum ClaudeCodeWords {
    /// The engine choice's one-line description (wizard card, Settings).
    public static let summary = "Your Claude Pro or Max plan, through the official Claude Code app on this computer — it signs in and does the talking."

    /// How it works.
    public static let explanation = "Vision runs the official Claude Code command-line app (claude) on this computer for chats you put on it, using the Claude sign-in you made there — your Pro or Max plan. Vision never sees or stores that sign-in: Claude Code talks to Anthropic itself. Claude Code works in the chat's project folder with its own tools; Vision shows each step, asks you before anything your permission setting doesn't allow, and keeps the conversation going turn after turn."

    /// Why a Sensitive chat can't use it (the policy's own sentence).
    public static let sensitiveReason = "Claude Code reads your files itself and sends them to its own service, so the sensitive-data shield can't mask anything on the way."
}
