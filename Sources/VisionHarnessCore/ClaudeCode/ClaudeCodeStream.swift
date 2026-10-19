import Foundation

// MARK: - Reading `claude -p --output-format stream-json`
//
// One JSON object per line (Claude Code's headless "stream-json" output, the Agent SDK's message types):
//   {"type":"system","subtype":"init", session_id, model, permissionMode, claude_code_version, apiKeySource …}
//   {"type":"stream_event","event":{…the Messages API stream event…}, parent_tool_use_id}   (--include-partial-messages)
//   {"type":"assistant","message":{id, model, content:[one text | thinking | tool_use block], usage}, parent_tool_use_id, error?}
//   {"type":"user","message":{content:[{type:"tool_result", tool_use_id, content, is_error}]}, tool_use_result}
//   {"type":"system","subtype":"api_retry" | "compact_boundary" | "status" | "informational" | "permission_denied" …}
//   {"type":"rate_limit_event","rate_limit_info":{status, rateLimitType, utilization, resetsAt}}
//   {"type":"control_request","request_id","request":{"subtype":"can_use_tool", tool_name, input, tool_use_id …}}
//   {"type":"result","subtype":"success" | "error_max_turns" | "error_during_execution" | …, is_error, result,
//    total_cost_usd, usage, modelUsage, num_turns, session_id, permission_denials …}
// The parser turns them into the events Vision's own engine emits (`EngineEvent`), so a Claude Code turn draws exactly
// like any other: streamed text and thinking, a row per tool call with its result, files changed, the plan, retries.
// Only the main conversation becomes rows; a subagent's steps show on the working line. Permission questions and
// other control requests go back to the caller to answer. Unknown lines and fields are ignored. The same reading as
// Vision for Windows (ClaudeCodeStream.cs).

/// What a turn emits besides the engine's own events.
public enum ClaudeCodeEvent: Sendable {
    case engine(EngineEvent)
    /// A one-line note for the chat ("Claude Code compacted the conversation …").
    case notice(String)
    /// The chat's working line ("Claude Code is compacting the conversation…", a subagent's step); nil clears it.
    case activity(String?)
    /// Claude Code asks whether a tool call may run: the caller answers on stdin.
    case permission(ClaudeCodePermissionRequest)
    /// Another control request: the caller refuses it on stdin so the CLI never waits.
    case unhandledControl(requestID: String, subtype: String)
}

/// A subscription limit Claude Code reported (`rate_limit_event`).
public struct ClaudeCodeRateLimit: Sendable, Equatable {
    public var status: String
    public var type: String?
    public var utilization: Double?
    public var resetsAt: Date?

    public init(status: String, type: String?, utilization: Double?, resetsAt: Date?) {
        self.status = status
        self.type = type
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var typeWords: String {
        switch type {
        case "five_hour": "five-hour"
        case "seven_day": "weekly"
        case "seven_day_opus": "weekly Opus"
        case "seven_day_sonnet": "weekly Sonnet"
        case "overage": "extra-usage"
        default: "usage"
        }
    }

    /// " — it resets at 16:40" (today), " — it resets Tue 21 Oct, 09:00" (later), "" (unknown).
    public func resetWords(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let resetsAt else { return "" }
        let today = calendar.isDate(resetsAt, inSameDayAs: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = today ? "HH:mm" : "EEE d MMM, HH:mm"
        return today ? " — it resets at \(formatter.string(from: resetsAt))" : " — it resets \(formatter.string(from: resetsAt))"
    }

    public var percent: Int? { utilization.map { Int(($0 <= 1 ? $0 * 100 : $0).rounded()) } }
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
    /// Claude Code's own estimate at API prices for the whole conversation so far (it adds up across --resume).
    public var totalCostUSD: Double?
    /// This turn's tokens (the main loop's: input + cache reads + cache writes as prompt, output as completion).
    public var usage: LLMUsage?
    public var denials: Int
    /// An error result's messages.
    public var errors: [String]
    public var terminalReason: String?
    /// The model's context window, as `modelUsage` reports it.
    public var contextWindow: Int?
    /// A command the CLI ran itself (/compact) instead of a model turn.
    public var localCommand: String?

    public init(subtype: String, isError: Bool, text: String, sessionID: String? = nil, numTurns: Int = 0,
                durationMs: Int? = nil, totalCostUSD: Double? = nil, usage: LLMUsage? = nil, denials: Int = 0,
                errors: [String] = [], terminalReason: String? = nil, contextWindow: Int? = nil, localCommand: String? = nil) {
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
        self.contextWindow = contextWindow
        self.localCommand = localCommand
    }
}

/// Reads one turn's stream-json, line by line. Not thread-safe: feed it from one queue.
public final class ClaudeCodeStreamParser {
    /// The chat's folder, for showing paths short and resolving relative ones.
    public let workspace: URL

    public private(set) var sessionID: String?
    /// The model the alias resolved to ("claude-sonnet-5-5").
    public private(set) var model: String?
    public private(set) var version: String?
    /// Where the CLI's credential came from: "none" for a claude.ai sign-in, "ANTHROPIC_API_KEY" for a key in the
    /// environment (billed to that key, not the subscription).
    public private(set) var apiKeySource: String?
    public private(set) var permissionMode: String?
    /// The last result (background work can bring more than one; `usage` adds them up).
    public private(set) var result: ClaudeCodeResult?
    public private(set) var results = 0
    /// Every result's tokens, added up.
    public private(set) var usage: LLMUsage?
    /// The last thing the main conversation said (what /goal reads its end marker from).
    public private(set) var lastReplyText = ""
    /// How full the context was on the last model call (its input, cached and new).
    public private(set) var contextTokens: Int?
    /// An API error Claude Code reported as a synthetic assistant message ("authentication_failed", "rate_limit" …)
    /// and its text ("Not logged in · Please run /login").
    public private(set) var apiError: (category: String, text: String)?
    public private(set) var rateLimit: ClaudeCodeRateLimit?
    /// Something happened beyond the prompt: a reply, a tool call (the session holds this turn now).
    public private(set) var progressed = false
    /// Lines that weren't JSON (a crash's stack trace on stdout) — kept for the error message.
    public private(set) var unparsed = ""

    private struct Tool {
        var name: String
        var input: JSONValue?
    }
    private var tools: [String: Tool] = [:]
    private var toolOrder: [String] = []
    private var finished: Set<String> = []
    private var tasks: [TodoItem] = []
    private var taskCreates: [String: String] = [:]
    private var limitWarnings: Set<String> = []
    /// Text of the current model message not yet handed over with `.assistantMessage`.
    private var pendingText = ""
    private var pendingMessageID: String?
    /// Messages whose text or thinking arrived as deltas (their whole blocks must not be drawn again).
    private var streamed: Set<String> = []
    private var currentStreamID: String?
    private var streamedTextInCurrent = false
    private var retries = 0

    public init(workspace: URL) {
        self.workspace = workspace.standardizedFileURL
    }

    // MARK: Lines

    /// Read one line; the events it makes, in order.
    public func consume(_ line: String) -> [ClaudeCodeEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = JSONValue(parsing: trimmed), json.object != nil else {
            if unparsed.count < 4_000 { unparsed += trimmed + "\n" }
            return []
        }
        let parent = json["parent_tool_use_id"]?.string
        switch json["type"]?.string {
        case "system": return system(json)
        case "stream_event": return parent == nil ? streamEvent(json["event"]) : []
        case "assistant": return parent == nil ? assistant(json) : subagent(json)
        case "user": return parent == nil ? user(json) : []
        case "rate_limit_event": return rateLimitEvent(json["rate_limit_info"])
        case "result": return resultLine(json)
        case "control_request":
            if let request = ClaudeCodePermissionRequest.from(json) { return [.permission(request)] }
            return [.unhandledControl(requestID: json["request_id"]?.string ?? "",
                                      subtype: json["request"]?["subtype"]?.string ?? "unknown")]
        default: return []
        }
    }

    /// The stream ended: hand over the last text.
    public func finish() -> [ClaudeCodeEvent] { flushText() }

    /// Tool calls that never got a result (the turn was stopped, or the CLI died): close their rows.
    public func closeDangling(_ why: String) -> [ClaudeCodeEvent] {
        var out: [ClaudeCodeEvent] = []
        for id in toolOrder where !finished.contains(id) {
            finished.insert(id)
            out.append(.engine(.toolFinished(id: id, name: ClaudeCodeTools.visionName(tools[id]?.name ?? "tool"), ok: false,
                                             summary: why, output: why)))
        }
        return out
    }

    // MARK: system

    private func system(_ json: JSONValue) -> [ClaudeCodeEvent] {
        switch json["subtype"]?.string {
        case "init":
            sessionID = json["session_id"]?.string ?? sessionID
            model = json["model"]?.string ?? model
            version = json["claude_code_version"]?.string ?? version
            apiKeySource = json["apiKeySource"]?.string ?? apiKeySource
            permissionMode = json["permissionMode"]?.string ?? permissionMode
            return []
        case "status":
            switch json["status"]?.string {
            case "compacting": return [.activity("Claude Code is compacting the conversation…")]
            case "requesting": return [.activity("Waiting for Claude…")]
            default: return [.activity(nil)]
            }
        case "api_retry":
            retries += 1
            let attempt = json["attempt"]?.int ?? retries
            let delay = Double(max(0, json["retry_delay_ms"]?.int ?? 0)) / 1000
            let reason = (json["error"]?.string ?? "error").replacingOccurrences(of: "_", with: " ")
                + (json["error_status"]?.int.map { ", HTTP \($0)" } ?? "")
            return [.engine(.retrying(attempt: attempt, delay: delay, reason: "Claude Code: \(reason)"))]
        case "compact_boundary":
            let meta = json["compact_metadata"]
            let how = meta?["trigger"]?.string == "auto"
                ? "Claude Code compacted the conversation to make room" : "Claude Code compacted the conversation"
            if let before = meta?["pre_tokens"]?.int, let after = meta?["post_tokens"]?.int {
                return [.notice("\(how): ~\(before.formatted()) → ~\(after.formatted()) tokens.")]
            }
            return [.notice(how + ".")]
        case "informational":
            guard ["warning", "error"].contains(json["level"]?.string ?? ""), let content = json["content"]?.string else { return [] }
            return [.notice("Claude Code: " + ClaudeCodeTools.prefix(content, 400))]
        default:
            return []
        }
    }

    private func recovered() -> [ClaudeCodeEvent] {
        guard retries > 0 else { return [] }
        defer { retries = 0 }
        return [.engine(.recovered(attempts: retries))]
    }

    // MARK: stream_event (partial messages)

    private func streamEvent(_ event: JSONValue?) -> [ClaudeCodeEvent] {
        guard let event else { return [] }
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
                    out.append(.engine(.textDelta(text)))
                }
            case "thinking_delta":
                if let thinking = delta?["thinking"]?.string, !thinking.isEmpty {
                    if let id = currentStreamID { streamed.insert(id) }
                    out.append(.engine(.reasoningDelta(thinking)))
                }
            default: break
            }
        default: break
        }
        return out
    }

    // MARK: assistant

    private func assistant(_ json: JSONValue) -> [ClaudeCodeEvent] {
        guard let message = json["message"] else { return [] }
        let blocks = message["content"]?.array ?? []
        // Not the model speaking: the CLI telling us its call failed ("Not logged in · Please run /login").
        if let error = json["error"]?.string, !error.isEmpty,
           json["is_api_error_message"]?.bool == true || message["model"]?.string == "<synthetic>" {
            apiError = (error, ClaudeCodeTools.contentText(message["content"]))
            return []
        }
        if message["model"]?.string == "<synthetic>" { return [] }

        var out: [ClaudeCodeEvent] = []
        let id = message["id"]?.string ?? json["uuid"]?.string ?? UUID().uuidString
        if id != pendingMessageID {
            out += flushText()
            pendingMessageID = id
        }
        out += recovered()
        if let usage = message["usage"], let input = usage["input_tokens"]?.int {
            contextTokens = input + (usage["cache_read_input_tokens"]?.int ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
        }
        for block in blocks {
            switch block["type"]?.string {
            case "text":
                guard let text = block["text"]?.string, !text.isEmpty else { continue }
                progressed = true
                if !streamed.contains(id) {
                    out.append(.engine(.textDelta(pendingText.isEmpty ? text : "\n\n" + text)))
                }
                pendingText += pendingText.isEmpty ? text : "\n\n" + text
                lastReplyText = text
            case "thinking":
                if !streamed.contains(id), let thinking = block["thinking"]?.string, !thinking.isEmpty {
                    out.append(.engine(.reasoningDelta(thinking)))
                }
            case "tool_use":
                guard let callID = block["id"]?.string else { continue }
                out += toolUse(callID, name: block["name"]?.string ?? "tool", input: block["input"], messageID: id)
            default:
                break
            }
        }
        return out
    }

    private func toolUse(_ callID: String, name: String, input: JSONValue?, messageID: String) -> [ClaudeCodeEvent] {
        progressed = true
        tools[callID] = Tool(name: name, input: input)
        toolOrder.append(callID)
        let visionName = ClaudeCodeTools.visionName(name)
        // The text written before the call closes with it (an ExitPlanMode call carries its plan to the plan panel).
        var out: [ClaudeCodeEvent] = [
            .engine(.assistantMessage(id: messageID, text: pendingText,
                                      calls: [ToolCall(id: callID, name: visionName, arguments: (input ?? [:]).serialized())])),
            .engine(.toolStarted(id: callID, name: visionName, preview: ClaudeCodeTools.preview(name, input, workspace: workspace))),
        ]
        pendingText = ""
        switch name {
        case "TodoWrite":
            if let todos = ClaudeCodeTools.todos(input) { out.append(.engine(.todos(todos))) }
        case "TaskCreate":
            taskCreates[callID] = input?["subject"]?.string ?? input?["description"]?.string ?? "Task"
        case "TaskUpdate":
            guard let taskID = input?["taskId"]?.string else { break }
            let status = input?["status"]?.string
            if let index = tasks.firstIndex(where: { $0.id == taskID }) {
                if status == "deleted" {
                    tasks.remove(at: index)
                } else {
                    if let subject = input?["subject"]?.string { tasks[index].content = subject }
                    if let status { tasks[index].status = ClaudeCodeTools.status(status) }
                }
            } else if status != "deleted" {
                tasks.append(TodoItem(id: taskID, content: input?["subject"]?.string ?? "Task \(taskID)",
                                      status: ClaudeCodeTools.status(status)))
            }
            out.append(.engine(.todos(tasks)))
        default:
            break
        }
        return out
    }

    /// A subagent's step: the working line, not a row.
    private func subagent(_ json: JSONValue) -> [ClaudeCodeEvent] {
        (json["message"]?["content"]?.array ?? []).compactMap { block -> ClaudeCodeEvent? in
            guard block["type"]?.string == "tool_use" else { return nil }
            let name = block["name"]?.string ?? "tool"
            let line = "Subagent: \(ClaudeCodeTools.label(name)) \(ClaudeCodeTools.preview(name, block["input"], workspace: workspace))"
            return .activity(line.trimmingCharacters(in: .whitespaces))
        }
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
        let structured: JSONValue? = json["tool_use_result"]?.object != nil ? json["tool_use_result"] : nil
        var out: [ClaudeCodeEvent] = []
        for block in blocks where block["type"]?.string == "tool_result" {
            let id = block["tool_use_id"]?.string ?? ""
            let tool = tools[id] ?? Tool(name: "tool", input: nil)
            let isError = block["is_error"]?.bool ?? false
            let content = ClaudeCodeTools.contentText(block["content"])
            if !isError, tool.name == "TaskCreate", let taskID = structured?["task"]?["id"]?.string {
                tasks.append(TodoItem(id: taskID, content: structured?["task"]?["subject"]?.string ?? taskCreates[id] ?? "Task"))
                out.append(.engine(.todos(tasks)))
            }
            guard finished.insert(id).inserted else { continue }
            out.append(.engine(.toolFinished(id: id, name: ClaudeCodeTools.visionName(tool.name), ok: !isError,
                                             summary: ClaudeCodeTools.summary(tool.name, input: tool.input, result: structured,
                                                                              content: content, isError: isError),
                                             output: ClaudeCodeTools.prefix(content, 20_000))))
            let images = ClaudeCodeTools.images(block["content"])
            if !images.isEmpty { out.append(.engine(.toolImages(id: id, images: images))) }
            if !isError, let change = ClaudeCodeTools.change(tool.name, input: tool.input, result: structured, workspace: workspace) {
                out.append(.engine(.filesChanged([change])))
            }
        }
        return out
    }

    // MARK: rate limits

    private func rateLimitEvent(_ info: JSONValue?) -> [ClaudeCodeEvent] {
        guard let status = info?["status"]?.string, status != "allowed" else { return [] }
        let resets = info?["resetsAt"]?.double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let limit = ClaudeCodeRateLimit(status: status, type: info?["rateLimitType"]?.string,
                                        utilization: info?["utilization"]?.double, resetsAt: resets)
        if status == "rejected" {
            rateLimit = limit
            return []
        }
        guard limitWarnings.insert(limit.typeWords).inserted else { return [] }
        let used = limit.percent.map { "\($0)% of" } ?? "close to"
        return [.notice("Your Claude plan: \(used) your \(limit.typeWords) limit used\(limit.resetWords()).")]
    }

    // MARK: result

    private func resultLine(_ json: JSONValue) -> [ClaudeCodeEvent] {
        var out = flushText()
        sessionID = json["session_id"]?.string ?? sessionID
        var turnUsage: LLMUsage?
        if let u = json["usage"], let input = u["input_tokens"]?.int {
            let cacheRead = u["cache_read_input_tokens"]?.int ?? 0
            let cacheWrite = u["cache_creation_input_tokens"]?.int ?? 0
            turnUsage = LLMUsage(promptTokens: input + cacheRead + cacheWrite, completionTokens: u["output_tokens"]?.int ?? 0,
                                 cachedTokens: cacheRead)
        }
        var window: Int?
        if let models = json["modelUsage"]?.object {
            if let model, let own = models[model]?["contextWindow"]?.int { window = own }
            else { window = models.values.compactMap { $0["contextWindow"]?.int }.max() }
            if let w = window, w <= 0 { window = nil }
        }
        let parsed = ClaudeCodeResult(
            subtype: json["subtype"]?.string ?? "", isError: json["is_error"]?.bool ?? false, text: json["result"]?.string ?? "",
            sessionID: json["session_id"]?.string, numTurns: json["num_turns"]?.int ?? 0, durationMs: json["duration_ms"]?.int,
            totalCostUSD: json["total_cost_usd"]?.double, usage: turnUsage, denials: json["permission_denials"]?.array?.count ?? 0,
            errors: (json["errors"]?.array ?? []).compactMap { $0.string.flatMap { $0.isEmpty ? nil : $0 } },
            terminalReason: json["terminal_reason"]?.string, contextWindow: window, localCommand: json["local_command"]?.string)
        result = parsed
        results += 1
        usage = LLMUsage.sum(usage, turnUsage)
        if !parsed.isError, !parsed.text.isEmpty, lastReplyText.isEmpty { lastReplyText = parsed.text }
        out.append(.activity(nil))
        if !parsed.isError { out.append(.engine(.finished(usage: turnUsage))) }
        return out
    }
}
