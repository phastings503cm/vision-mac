import Foundation

// MARK: - Reading `claude -p --output-format stream-json`
//
// One JSON object per line (Claude Code's headless "stream-json" output, the Agent SDK's message types):
//   {"type":"system","subtype":"init", session_id, model, tools, permissionMode, claude_code_version, apiKeySource …}
//   {"type":"stream_event","event":{…the Messages API stream event…}, parent_tool_use_id}   (--include-partial-messages)
//   {"type":"assistant","message":{id, model, content:[one text | thinking | tool_use block], usage}, parent_tool_use_id, error?}
//   {"type":"user","message":{content:[{type:"tool_result", tool_use_id, content, is_error}]}, tool_use_result, parent_tool_use_id}
//   {"type":"system","subtype":"api_retry" | "compact_boundary" | "permission_denied" | "informational" …}
//   {"type":"result","subtype":"success" | "error_max_turns" | "error_during_execution" | …, is_error, result,
//    total_cost_usd, usage, num_turns, session_id, permission_denials …}
// The parser turns them into the events Vision's own engine emits (`EngineEvent`), so a Claude Code turn draws
// exactly like any other: streamed text and thinking, a row per tool call with its result, files changed, todos,
// retries. Messages from Claude Code's subagents (a non-null `parent_tool_use_id`) show as tool rows named after
// the subagent's task; their text stays inside the subagent, as it does in Claude Code. Unknown lines and
// unknown fields are ignored, so a newer CLI never breaks a turn.

/// What a turn emits besides the engine's own events.
public enum ClaudeCodeEvent: Sendable {
    case engine(EngineEvent)
    /// A one-line note for the chat ("Claude Code compacted its conversation …").
    case notice(String)
}

/// A tool call Claude Code was refused (the permission setting, or nobody to ask).
public struct ClaudeCodeDenial: Sendable, Equatable {
    public var toolName: String
    public var toolUseID: String
    public var detail: String

    public init(toolName: String, toolUseID: String, detail: String) {
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.detail = detail
    }
}

/// The `result` line: how the turn ended, what it cost, what it used.
public struct ClaudeCodeResult: Sendable, Equatable {
    public var subtype: String
    public var isError: Bool
    /// The final reply's text (for an error: what went wrong).
    public var text: String
    public var sessionID: String?
    public var numTurns: Int
    public var durationMs: Int?
    /// Claude Code's own estimate at API prices; on a resumed session (Claude Code 2.1.277+) the session's
    /// running total, earlier turns included.
    public var totalCostUSD: Double?
    /// This turn's tokens (the main loop's: input + cache reads + cache writes as prompt, output as completion).
    public var usage: LLMUsage?
    public var denials: [ClaudeCodeDenial]
    /// An error result's messages.
    public var errors: [String]
    public var terminalReason: String?

    public init(subtype: String, isError: Bool, text: String, sessionID: String? = nil, numTurns: Int = 0,
                durationMs: Int? = nil, totalCostUSD: Double? = nil, usage: LLMUsage? = nil,
                denials: [ClaudeCodeDenial] = [], errors: [String] = [], terminalReason: String? = nil) {
        self.subtype = subtype
        self.isError = isError
        self.text = text
        self.sessionID = sessionID
        self.numTurns = numTurns
        self.durationMs = durationMs
        self.totalCostUSD = totalCostUSD
        self.usage = usage
        self.denials = denials
        self.errors = errors
        self.terminalReason = terminalReason
    }

    /// The turn stopped at its step limit while Claude still had work to do.
    public var hitTurnLimit: Bool { subtype == "error_max_turns" }
}

/// Reads one turn's stream-json, line by line. Not thread-safe: feed it from one queue.
public final class ClaudeCodeStreamParser {
    /// The chat's folder, for showing paths short and resolving relative ones.
    public let workspace: URL

    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var version: String?
    /// "none" for a Claude plan sign-in; "ANTHROPIC_API_KEY", "apiKeyHelper" … when a key pays.
    public private(set) var apiKeySource: String?
    public private(set) var permissionMode: String?
    public private(set) var result: ClaudeCodeResult?
    /// The last non-empty text the main loop wrote.
    public private(set) var lastReplyText = ""
    /// How full the context is: the last main-loop request's input + cache tokens.
    public private(set) var contextTokens: Int?
    /// An API error Claude Code reported as a synthetic assistant message ("authentication_failed", "rate_limit" …)
    /// and its text ("Not logged in · Please run /login").
    public private(set) var apiError: (category: String, text: String)?
    /// The model actually answered (a real message, not a synthetic error): the session exists from now on.
    public private(set) var reachedModel = false
    public private(set) var denials: [ClaudeCodeDenial] = []
    /// One line per finished main-loop tool call ("Edited Sources/App.swift"), for the conversation other models
    /// are given — Claude Code's tool work itself stays in its session.
    public private(set) var toolLog: [String] = []

    private struct Tool {
        var name: String
        var visionName: String
        var input: JSONValue
        var preview: String
    }
    private var tools: [String: Tool] = [:]
    /// Subagent runs by the id of the tool call that started them: what to call their rows.
    private var subagents: [String: String] = [:]
    /// Text of the current model message not yet handed over with `.assistantMessage`.
    private var pendingText = ""
    private var pendingMessageID: String?
    /// Messages whose text arrived as deltas (their full text block must not be drawn again).
    private var streamed: Set<String> = []
    private var currentStreamID: String?
    private var streamedTextInCurrent = false
    private var countedUsage: Set<String> = []
    private var retrying = 0

    public init(workspace: URL) {
        self.workspace = workspace.standardizedFileURL
    }

    // MARK: Lines

    /// Read one line; the events it makes, in order.
    public func consume(_ line: String) -> [ClaudeCodeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let json = JSONValue(parsing: trimmed), let type = json["type"]?.string else { return [] }
        if sessionID == nil, let id = json["session_id"]?.string, !id.isEmpty { sessionID = id }
        switch type {
        case "system": return system(json)
        case "stream_event": return streamEvent(json)
        case "assistant": return assistant(json)
        case "user": return user(json)
        case "result": return resultLine(json)
        default: return []
        }
    }

    /// The stream ended: hand over the last text.
    public func finish() -> [ClaudeCodeEvent] { flushText() }

    // MARK: system

    private func system(_ json: JSONValue) -> [ClaudeCodeEvent] {
        switch json["subtype"]?.string {
        case "init":
            if let id = json["session_id"]?.string, !id.isEmpty { sessionID = id }
            model = json["model"]?.string ?? model
            version = json["claude_code_version"]?.string ?? version
            apiKeySource = json["apiKeySource"]?.string ?? apiKeySource
            permissionMode = json["permissionMode"]?.string ?? permissionMode
            return []
        case "api_retry":
            let attempt = json["attempt"]?.int ?? (retrying + 1)
            retrying = max(retrying, attempt)
            let delay = Double(json["retry_delay_ms"]?.int ?? 0) / 1000
            return [.engine(.retrying(attempt: attempt, delay: delay,
                                      reason: Self.retryReason(json["error"]?.string, status: json["error_status"]?.int)))]
        case "compact_boundary":
            let before = json["compact_metadata"]?["pre_tokens"]?.int
            return [.notice("Claude Code compacted its conversation" + (before.map { " (it was about \($0.formatted()) tokens)" } ?? "") + ".")]
        case "permission_denied":
            let id = json["tool_use_id"]?.string ?? ""
            let name = json["tool_name"]?.string ?? "a tool"
            if !denials.contains(where: { $0.toolUseID == id && !id.isEmpty }) {
                denials.append(ClaudeCodeDenial(toolName: name, toolUseID: id, detail: tools[id]?.preview ?? (json["message"]?.string ?? "")))
            }
            return []
        case "informational":
            guard let content = json["content"]?.string, !content.isEmpty,
                  ["warning", "notice"].contains(json["level"]?.string ?? "") else { return [] }
            return [.notice("Claude Code: \(content)")]
        default:
            return []
        }
    }

    static func retryReason(_ category: String?, status: Int?) -> String {
        let words: String
        switch category {
        case "rate_limit": words = "rate limited"
        case "overloaded": words = "overloaded"
        case "server_error": words = "server error"
        case "authentication_failed": words = "sign-in refused"
        case "billing_error": words = "billing problem"
        case .some(let other) where !other.isEmpty && other != "unknown": words = other.replacingOccurrences(of: "_", with: " ")
        default: words = status == nil ? "no response" : "error"
        }
        return "Claude Code: " + words + (status.map { " (\($0))" } ?? "")
    }

    // MARK: stream_event (partial messages)

    private func streamEvent(_ json: JSONValue) -> [ClaudeCodeEvent] {
        guard json["parent_tool_use_id"]?.isNull ?? true, let event = json["event"] else { return [] }
        var out: [ClaudeCodeEvent] = []
        switch event["type"]?.string {
        case "message_start":
            let id = event["message"]?["id"]?.string
            if let id, id != pendingMessageID { out += flushText() }
            currentStreamID = id
            streamedTextInCurrent = false
            out += recovered()
        case "content_block_start":
            if event["content_block"]?["type"]?.string == "text", streamedTextInCurrent {
                out.append(.engine(.textDelta("\n\n")))
            }
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.string {
            case "text_delta":
                if let text = delta?["text"]?.string, !text.isEmpty {
                    if let id = currentStreamID { streamed.insert(id) }
                    streamedTextInCurrent = true
                    reachedModel = true
                    out.append(.engine(.textDelta(text)))
                }
            case "thinking_delta":
                if let thinking = delta?["thinking"]?.string, !thinking.isEmpty {
                    if let id = currentStreamID { streamed.insert(id) }
                    reachedModel = true
                    out.append(.engine(.reasoningDelta(thinking)))
                }
            default: break
            }
        default: break
        }
        return out
    }

    private func recovered() -> [ClaudeCodeEvent] {
        guard retrying > 0 else { return [] }
        defer { retrying = 0 }
        return [.engine(.recovered(attempts: retrying))]
    }

    // MARK: assistant

    private func assistant(_ json: JSONValue) -> [ClaudeCodeEvent] {
        guard let message = json["message"] else { return [] }
        let parent = json["parent_tool_use_id"]?.string
        let blocks = message["content"]?.array ?? []
        // An API failure arrives as a synthetic message with `error` set ("Not logged in · Please run /login").
        let category = json["error"]?.string ?? ""
        if !category.isEmpty || json["is_api_error_message"]?.bool == true {
            if parent == nil {
                let text = blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
                apiError = (category.isEmpty ? "unknown" : category, text)
            }
            return []
        }
        // Other synthetic messages (Claude Code's own stand-ins) are not the model speaking.
        if message["model"]?.string == "<synthetic>" { return [] }
        guard parent == nil else { return subagentAssistant(blocks, parent: parent!) }

        var out: [ClaudeCodeEvent] = []
        let id = message["id"]?.string ?? json["uuid"]?.string ?? UUID().uuidString
        if id != pendingMessageID {
            out += flushText()
            pendingMessageID = id
        }
        if currentStreamID != id { out += recovered() }
        reachedModel = true
        if !countedUsage.contains(id), let usage = message["usage"] {
            countedUsage.insert(id)
            contextTokens = (usage["input_tokens"]?.int ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
                + (usage["cache_read_input_tokens"]?.int ?? 0)
        }
        for block in blocks {
            switch block["type"]?.string {
            case "text":
                guard let text = block["text"]?.string, !text.isEmpty else { continue }
                if !streamed.contains(id) {
                    out.append(.engine(.textDelta(pendingText.isEmpty ? text : "\n\n" + text)))
                }
                pendingText += pendingText.isEmpty ? text : "\n\n" + text
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastReplyText = text }
            case "thinking":
                if !streamed.contains(id), let thinking = block["thinking"]?.string, !thinking.isEmpty {
                    out.append(.engine(.reasoningDelta(thinking)))
                }
            case "tool_use":
                guard let callID = block["id"]?.string, let name = block["name"]?.string else { continue }
                let input = block["input"] ?? [:]
                let tool = Tool(name: name, visionName: Self.visionName(name), input: input,
                                preview: Self.preview(name, input, workspace: workspace))
                tools[callID] = tool
                if Self.isSubagentTool(name) {
                    subagents[callID] = input["description"]?.string ?? input["subagent_type"]?.string ?? "Subagent"
                }
                let call = ToolCall(id: callID, name: tool.visionName, arguments: input.serialized())
                out.append(.engine(.assistantMessage(id: id, text: pendingText, calls: [call])))
                pendingText = ""
                out.append(.engine(.toolStarted(id: callID, name: tool.visionName, preview: tool.preview)))
                if name == "TodoWrite", let todos = Self.todos(input) { out.append(.engine(.todos(todos))) }
            default:
                break
            }
        }
        return out
    }

    private func subagentAssistant(_ blocks: [JSONValue], parent: String) -> [ClaudeCodeEvent] {
        var out: [ClaudeCodeEvent] = []
        let owner = subagents[parent] ?? "Subagent"
        for block in blocks where block["type"]?.string == "tool_use" {
            guard let callID = block["id"]?.string, let name = block["name"]?.string else { continue }
            let input = block["input"] ?? [:]
            let preview = "\(owner) › " + Self.preview(name, input, workspace: workspace)
            tools[callID] = Tool(name: name, visionName: Self.visionName(name), input: input, preview: preview)
            if Self.isSubagentTool(name) {
                subagents[callID] = input["description"]?.string ?? input["subagent_type"]?.string ?? "Subagent"
            }
            out.append(.engine(.toolStarted(id: callID, name: Self.visionName(name), preview: preview)))
        }
        return out
    }

    /// Hand over the text written since the last tool call (it closes the bubble and goes into the log).
    private func flushText() -> [ClaudeCodeEvent] {
        guard let id = pendingMessageID, !pendingText.isEmpty else { return [] }
        defer { pendingText = "" }
        return [.engine(.assistantMessage(id: id, text: pendingText, calls: []))]
    }

    // MARK: user (tool results)

    private func user(_ json: JSONValue) -> [ClaudeCodeEvent] {
        guard let blocks = json["message"]?["content"]?.array else { return [] }
        var out: [ClaudeCodeEvent] = []
        let detail = json["tool_use_result"] ?? json["toolUseResult"]
        for block in blocks where block["type"]?.string == "tool_result" {
            guard let callID = block["tool_use_id"]?.string else { continue }
            let tool = tools[callID]
            let name = tool?.name ?? "tool"
            let visionName = tool?.visionName ?? name
            let ok = !(block["is_error"]?.bool ?? false)
            let (text, images) = Self.resultContent(block["content"])
            if !images.isEmpty { out.append(.engine(.toolImages(id: callID, images: images))) }
            let output = Self.cap(text)
            out.append(.engine(.toolFinished(id: callID, name: visionName, ok: ok,
                                             summary: Self.summary(name, tool?.input ?? [:], ok: ok, output: text, workspace: workspace),
                                             output: output)))
            if ok, let tool, let change = Self.fileChange(tool.name, tool.input, detail: detail, workspace: workspace) {
                out.append(.engine(.filesChanged([change])))
            }
            if json["parent_tool_use_id"]?.isNull ?? true, let tool {
                toolLog.append("\(tool.name) \(tool.preview)".trimmingCharacters(in: .whitespaces) + (ok ? "" : " (failed)"))
            }
        }
        return out
    }

    // MARK: result

    private func resultLine(_ json: JSONValue) -> [ClaudeCodeEvent] {
        var out = flushText()
        let usage = json["usage"].map { u -> LLMUsage in
            let cacheRead = u["cache_read_input_tokens"]?.int ?? 0
            let prompt = (u["input_tokens"]?.int ?? 0) + (u["cache_creation_input_tokens"]?.int ?? 0) + cacheRead
            return LLMUsage(promptTokens: prompt, completionTokens: u["output_tokens"]?.int ?? 0,
                            cachedTokens: cacheRead > 0 ? cacheRead : nil)
        }
        var resultDenials = denials
        for denial in json["permission_denials"]?.array ?? [] {
            let id = denial["tool_use_id"]?.string ?? ""
            guard !resultDenials.contains(where: { $0.toolUseID == id && !id.isEmpty }) else { continue }
            let name = denial["tool_name"]?.string ?? "tool"
            resultDenials.append(ClaudeCodeDenial(toolName: name, toolUseID: id,
                                                  detail: Self.preview(name, denial["tool_input"] ?? [:], workspace: workspace)))
        }
        denials = resultDenials
        let subtype = json["subtype"]?.string ?? "success"
        let isError = json["is_error"]?.bool ?? (subtype != "success")
        let text = json["result"]?.string ?? ""
        result = ClaudeCodeResult(subtype: subtype, isError: isError, text: text,
                                  sessionID: json["session_id"]?.string, numTurns: json["num_turns"]?.int ?? 0,
                                  durationMs: json["duration_ms"]?.int, totalCostUSD: json["total_cost_usd"]?.double,
                                  usage: usage, denials: resultDenials,
                                  errors: (json["errors"]?.array ?? []).compactMap(\.string),
                                  terminalReason: json["terminal_reason"]?.string)
        if let id = json["session_id"]?.string, !id.isEmpty { sessionID = id }
        if !isError, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastReplyText = text }
        if !isError || subtype == "error_max_turns" { out.append(.engine(.finished(usage: usage))) }
        return out
    }

    // MARK: Claude Code's tools, the way Vision draws them

    /// Claude Code's tool names as the Vision tools that do the same (their labels and icons); others as they are.
    public static func visionName(_ name: String) -> String {
        switch name {
        case "Read": "read_file"
        case "Write": "write_file"
        case "Edit", "MultiEdit", "NotebookEdit": "edit"
        case "Bash": "run_shell_command"
        case "Glob": "glob"
        case "Grep": "grep"
        case "LS": "list_directory"
        case "WebFetch": "web_fetch"
        case "TodoWrite": "todo_write"
        case "Agent", "Task": "agent"
        case "ExitPlanMode": ExitPlanModeTool.name
        case "Skill": "use_skill"
        default: name
        }
    }

    static func isSubagentTool(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    /// One line saying what a call does ("swift build", "Sources/App.swift", "TODO in *.swift").
    public static func preview(_ name: String, _ input: JSONValue, workspace: URL) -> String {
        func path(_ key: String) -> String? { input[key]?.string.map { shortPath($0, workspace: workspace) } }
        func line(_ text: String?) -> String {
            let first = (text ?? "").split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return first.count > 200 ? String(first.prefix(199)) + "…" : first
        }
        switch name {
        case "Bash": return line(input["command"]?.string)
        case "Read", "Write", "Edit", "MultiEdit": return path("file_path") ?? ""
        case "NotebookEdit": return path("notebook_path") ?? path("file_path") ?? ""
        case "Glob", "Grep":
            let pattern = input["pattern"]?.string ?? ""
            return path("path").map { "\(pattern) in \($0)" } ?? pattern
        case "LS": return path("path") ?? ""
        case "WebFetch": return input["url"]?.string ?? ""
        case "WebSearch": return input["query"]?.string ?? ""
        case "Agent", "Task": return input["description"]?.string ?? input["subagent_type"]?.string ?? ""
        case "TodoWrite":
            let count = input["todos"]?.array?.count ?? 0
            return "\(count) item\(count == 1 ? "" : "s")"
        case "ExitPlanMode": return "plan"
        case "Skill": return input["skill"]?.string ?? ""
        default:
            for key in ["file_path", "path", "command", "query", "url", "description", "name"] {
                if let value = input[key]?.string, !value.isEmpty { return line(value) }
            }
            let json = input.serialized()
            return json == "{}" ? "" : (json.count > 120 ? String(json.prefix(119)) + "…" : json)
        }
    }

    /// A path inside the chat's folder relative to it; others as they are.
    static func shortPath(_ raw: String, workspace: URL) -> String {
        let root = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        return raw.hasPrefix(root) ? String(raw.dropFirst(root.count)) : raw
    }

    /// A tool result's text (string content, or its text blocks) and its pictures.
    static func resultContent(_ content: JSONValue?) -> (String, [MessageAttachment]) {
        if let text = content?.string { return (text, []) }
        var texts: [String] = []
        var images: [MessageAttachment] = []
        for block in content?.array ?? [] {
            switch block["type"]?.string {
            case "text": if let text = block["text"]?.string { texts.append(text) }
            case "image":
                if let data = block["source"]?["data"]?.string.flatMap({ Data(base64Encoded: $0) }) {
                    images.append(MessageAttachment(kind: .image, name: "image-\(images.count + 1)", data: data))
                }
            default: break
            }
        }
        return (texts.joined(separator: "\n"), images)
    }

    static func cap(_ text: String, limit: Int = 16_000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters)" : text
    }

    /// The row's one-line headline.
    static func summary(_ name: String, _ input: JSONValue, ok: Bool, output: String, workspace: URL) -> String {
        func firstLine(_ text: String) -> String {
            let cleaned = text.replacingOccurrences(of: "<tool_use_error>", with: "")
                .replacingOccurrences(of: "</tool_use_error>", with: "")
            let first = cleaned.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 160 ? String(trimmed.prefix(159)) + "…" : trimmed
        }
        guard ok else { return firstLine(output).isEmpty ? "Failed" : firstLine(output) }
        let file = input["file_path"]?.string.map { shortPath($0, workspace: workspace) }
        switch name {
        case "Edit", "MultiEdit", "NotebookEdit": return "Edited \(file ?? "the file")"
        case "Write": return "Wrote \(file ?? "the file")"
        case "Read": return "Read \(file ?? "the file")"
        case "TodoWrite": return "Updated the plan"
        default:
            let line = firstLine(output)
            return line.isEmpty ? "Done" : line
        }
    }

    /// The file a successful edit tool touched. `Write` says in its result whether it created the file.
    static func fileChange(_ name: String, _ input: JSONValue, detail: JSONValue?, workspace: URL) -> FileChange? {
        let kind: FileChange.Kind
        switch name {
        case "Write": kind = detail?["type"]?.string == "create" ? .created : .modified
        case "Edit", "MultiEdit", "NotebookEdit": kind = .modified
        default: return nil
        }
        guard let raw = input["file_path"]?.string ?? input["notebook_path"]?.string, !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : workspace.appendingPathComponent(raw)
        return FileChange(url.standardizedFileURL, kind)
    }

    /// `TodoWrite`'s list as Vision's todos.
    static func todos(_ input: JSONValue) -> [TodoItem]? {
        guard let items = input["todos"]?.array else { return nil }
        return items.enumerated().compactMap { index, item in
            guard let content = item["content"]?.string ?? item["activeForm"]?.string else { return nil }
            let status: TodoItem.Status
            switch item["status"]?.string {
            case "in_progress": status = .inProgress
            case "completed": status = .completed
            default: status = .pending
            }
            return TodoItem(id: item["id"]?.string ?? "\(index + 1)", content: content, status: status)
        }
    }
}
