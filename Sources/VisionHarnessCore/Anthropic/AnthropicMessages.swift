import Foundation

// MARK: - Anthropic Messages API: request bodies and streamed replies
//
// The direct "Anthropic API (key)" route (api.anthropic.com/v1/messages). The rules are the ones
// Converse enforces for Claude on Bedrock (see `BedrockConverse`), in the Messages API's own shapes:
//   - one system list (the prompt, then any system-role notes such as compaction summaries);
//   - turns alternate user/assistant, start with a user turn and end with one (no prefill on
//     Claude 4.6 and later), neighbours of the same role merged;
//   - every tool_use is answered by a tool_result in the very next user turn, results first in it;
//     calls nobody answered (an interrupted turn) get a stub result;
//   - no text block may be blank; a transcript that holds tool blocks needs `tools` even when none
//     are offered.
// Per-model facts (thinking style, sampling, ceilings, caching) come from `BedrockModels.traits`,
// which knows Anthropic's own ids too. Claude's signed thinking goes back verbatim while it works
// through a turn's tool calls: the reply records its content blocks in `.done`'s providerState
// (prefixed, so Bedrock's reader never mistakes them for its own) and the next request replays them.
// Prompt caching: breakpoints after the system prompt, after the tool list and on the last block of
// the conversation (3 of the 4 allowed). Researched against Anthropic's API docs, 2026-10-19.

public enum AnthropicMessages {
    /// The `anthropic-version` header.
    public static let version = "2023-06-01"
    /// Where the API lives (the route's base URL).
    public static let defaultBaseURL = "https://api.anthropic.com/v1"
    /// The beta that turns on `fallbacks: "default"` (a declined request re-runs on the model Anthropic
    /// recommends for that refusal category, inside the same call).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// What marks this client's replay state on an assistant message.
    static let statePrefix = "anthropic.content:"

    public static func modelID(_ request: LLMRequest, _ profile: ProviderProfile) -> String {
        request.model.isEmpty ? profile.model : request.model
    }

    /// The models that take `fallbacks: "default"` on Anthropic's own API: Claude Fable 5.1, Opus 5.5,
    /// Opus 5 and Sonnet 5.5.
    public static func takesFallbacks(_ model: String) -> Bool {
        guard let (family, version) = BedrockModels.claudeVersion(model) else { return false }
        switch family {
        case "fable": return version == 5.1
        case "opus": return version == 5.5 || version == 5
        case "sonnet": return version == 5.5
        default: return false
        }
    }

    /// What this request asks of the model's thinking. `active`: the model may think (signed reasoning
    /// is replayed, temperature is not sent); `room`: output tokens the thinking may use.
    struct ThinkingPlan {
        var config: [String: JSONValue]?
        var effort: String?
        var active: Bool
        var room: Int

        static let none = ThinkingPlan(config: nil, effort: nil, active: false, room: 0)

        /// Sonnet 5.5's "thinking off": no other thinking field beside it, and no server-side fallback.
        var isBetweenTools: Bool { config?["type"]?.string == "between_tools" }
    }

    /// The request body. `replayReasoning` false leaves stored reasoning out (the retry after Claude
    /// refused it: an edited history invalidates the signature); `fallbacks` false leaves out the
    /// server-side fallback (the retry after the key turned the beta down).
    public static func request(_ request: LLMRequest, profile: ProviderProfile, replayReasoning: Bool = true,
                               fallbacks: Bool = true) -> JSONValue {
        let model = modelID(request, profile)
        let traits = BedrockModels.traits(model)
        let plan = thinkingPlan(traits, level: request.thinking ?? profile.thinking, messages: request.messages,
                                replayReasoning: replayReasoning)
        let replay = replayReasoning && plan.active

        var system: [JSONValue] = []
        func addSystem(_ text: String?) {
            if let text, !BedrockConverse.isBlank(text) { system.append(textBlock(text)) }
        }
        addSystem(request.systemPrompt)
        for m in request.messages where m.role == .system { addSystem(m.content) }
        if traits.cachePoints, !system.isEmpty { system[system.count - 1] = cached(system[system.count - 1]) }

        var turns = makeTurns(request.messages, replay: replay, route: AttachmentRoute.anthropic(profile, traits: traits))
        if traits.cachePoints, let last = turns.indices.last, let block = turns[last].content.indices.last {
            turns[last].content[block] = cached(turns[last].content[block])
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(turns.map { .object(["role": .string($0.role), "content": .array($0.content)]) }),
            "stream": true,
        ]
        if !system.isEmpty { body["system"] = .array(system) }

        var maxTokens = max(request.maxTokens ?? profile.maxOutputTokens ?? traits.defaultMaxTokens, plan.room)
        if let ceiling = traits.maxTokensCeiling { maxTokens = min(maxTokens, ceiling) }
        body["max_tokens"] = .number(Double(maxTokens))
        if traits.sampling, !plan.active, let temperature = request.temperature ?? profile.temperature {
            body["temperature"] = .number(min(max(temperature, 0), 1))
        }
        if let tools = tools(request.tools, turns: turns, cache: traits.toolCachePoint) {
            body["tools"] = .array(tools)
        }
        if var thinking = plan.config {
            // budget_tokens must stay below max_tokens, which the model's ceiling may have capped.
            if thinking["budget_tokens"] != nil {
                let budget = max(BedrockConverse.minThinkingBudget,
                                 min(plan.room - BedrockConverse.replyTokens, maxTokens - BedrockConverse.replyTokens))
                thinking["budget_tokens"] = .number(Double(budget))
            }
            body["thinking"] = .object(thinking)
        }
        if let effort = plan.effort { body["output_config"] = .object(["effort": .string(effort)]) }
        if fallbacks, takesFallbacks(model), !plan.isBetweenTools { body["fallbacks"] = .string("default") }
        return .object(body)
    }

    static func thinkingPlan(_ traits: BedrockModelTraits, level: ThinkingLevel?, messages: [LLMMessage],
                             replayReasoning: Bool) -> ThinkingPlan {
        switch traits.thinking {
        case .budget:
            guard let level, level != .off else { return .none }
            // The assistant turn whose tool calls this request answers must start with its signed
            // thinking; without it on hand, this request goes without thinking.
            if let last = messages.last(where: { $0.role == .assistant }),
               !(last.toolCalls ?? []).isEmpty, !replayReasoning || replayBlocks(last) == nil {
                return .none
            }
            let budget = BedrockConverse.thinkingBudget(level)
            return ThinkingPlan(config: ["type": .string("enabled"), "budget_tokens": .number(Double(budget))],
                                effort: nil, active: true, room: budget + BedrockConverse.replyTokens)
        case .adaptive:
            var adaptive: [String: JSONValue] = ["type": .string("adaptive")]
            // From Claude 4.7 on the thinking text is omitted unless asked for: ask, so the live reasoning
            // pane has something to show.
            if traits.summarizedThinking { adaptive["display"] = .string("summarized") }
            guard let level else {
                // No level: the model's default — no thinking on 4.6 – 4.8, adaptive from Claude 5 on.
                guard traits.off != .omit else { return .none }
                return ThinkingPlan(config: adaptive, effort: nil, active: true,
                                    room: BedrockConverse.thinkingBudget(.high) + BedrockConverse.replyTokens)
            }
            if level == .off {
                switch traits.off {
                case .disabled:
                    return ThinkingPlan(config: ["type": .string("disabled")], effort: nil, active: false, room: 0)
                case .betweenTools:
                    return ThinkingPlan(config: ["type": .string("between_tools")], effort: nil, active: true, room: 0)
                case .lowEffort:
                    return ThinkingPlan(config: nil, effort: BedrockConverse.effort(.low), active: true, room: 0)
                case .omit:
                    return .none
                }
            }
            return ThinkingPlan(config: adaptive, effort: BedrockConverse.effort(level), active: true,
                                room: BedrockConverse.thinkingBudget(level) + BedrockConverse.replyTokens)
        case .none:
            return .none
        }
    }

    // MARK: Turns

    struct Turn {
        var role: String
        var content: [JSONValue]
    }

    static let interruptedCall = "Not run — the turn was interrupted before this call executed."

    static func makeTurns(_ messages: [LLMMessage], replay: Bool, route: AttachmentRoute) -> [Turn] {
        var turns: [Turn] = []
        // tool_use ids of the latest assistant turn still waiting for their results.
        var open: [String] = []

        func add(_ role: String, _ blocks: [JSONValue]) {
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].content.append(contentsOf: blocks)
            } else {
                if role == "assistant" && turns.isEmpty {
                    turns.append(Turn(role: "user", content: [textBlock("(continuing the conversation)")]))
                }
                turns.append(Turn(role: role, content: blocks))
            }
        }

        func closeOpenCalls() {
            guard !open.isEmpty else { return }
            let stubs = open.map { toolResult($0, interruptedCall) }
            open.removeAll()
            add("user", stubs)
        }

        // Pictures and documents share the request's total (32 MB on the wire), the newest message first: the one
        // being sent keeps its attachments, older ones past the total go back as their text.
        var mediaRoom = route.maxRequestMediaBytes ?? .max
        var userContent: [Int: [JSONValue]] = [:]
        for index in messages.indices.reversed() where messages[index].role == .user {
            userContent[index] = userBlocks(messages[index], route: route, mediaRoom: &mediaRoom)
        }

        for (index, m) in messages.enumerated() {
            switch m.role {
            case .user:
                closeOpenCalls()
                add("user", userContent[index] ?? [])
            case .tool:
                let id = toolUseID(m.toolCallID ?? "")
                if let index = open.firstIndex(of: id) {
                    open.remove(at: index)
                    add("user", [toolResult(id, m.content)])
                } else {
                    // A result whose call is gone (trimmed history): keep what it said, as text.
                    let output = BedrockConverse.isBlank(m.content) ? "(no output)" : (m.content ?? "")
                    add("user", [textBlock("[Result of \(m.name ?? "a tool")]\n\(output)")])
                }
            case .assistant:
                closeOpenCalls()
                let blocks = assistantBlocks(m, replay: replay)
                open.append(contentsOf: blocks.compactMap { $0["type"]?.string == "tool_use" ? $0["id"]?.string : nil })
                add("assistant", blocks)
            case .system:
                break
            }
        }
        closeOpenCalls()
        if turns.isEmpty { turns.append(Turn(role: "user", content: [textBlock("(continuing the conversation)")])) }
        // Claude answers a user turn; from 4.6 on a prefilled assistant turn is refused.
        if turns[turns.count - 1].role == "assistant" {
            turns.append(Turn(role: "user", content: [textBlock("Continue.")]))
        }
        for index in turns.indices where turns[index].role == "user" {
            if turns[index].content.isEmpty { turns[index].content.append(textBlock("(empty message)")) }
            // Tool results come first in their user turn (the engine's image message and a prompt sent
            // after an interrupted turn join it).
            let results = turns[index].content.filter { $0["type"]?.string == "tool_result" }
            if !results.isEmpty {
                turns[index].content = results + turns[index].content.filter { $0["type"]?.string != "tool_result" }
            }
        }
        return turns
    }

    /// The user's text, then each attachment as `AttachmentWire` sends it on this route: images as
    /// base64 image blocks, PDFs as document blocks, everything else as the text Vision read out of it.
    static func userBlocks(_ m: LLMMessage, route: AttachmentRoute) -> [JSONValue] {
        var room = route.maxRequestMediaBytes ?? .max
        return userBlocks(m, route: route, mediaRoom: &room)
    }

    /// The same, drawing pictures and documents from what the request has left (`mediaRoom`).
    static func userBlocks(_ m: LLMMessage, route: AttachmentRoute, mediaRoom: inout Int) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if let content = m.content, !BedrockConverse.isBlank(content) { blocks.append(textBlock(content)) }
        for part in AttachmentWire.parts(for: m.attachments ?? [], route: route, mediaRoom: &mediaRoom) {
            switch part {
            case .text(let text):
                if !BedrockConverse.isBlank(text) { blocks.append(textBlock(text)) }
            case .image(let mime, let data):
                guard route.imageTypes?.contains(mime) ?? true else {
                    blocks.append(textBlock("[image of \(data.count) bytes, not shown]"))
                    continue
                }
                blocks.append(.object([
                    "type": "image",
                    "source": .object(["type": "base64", "media_type": .string(mime),
                                       "data": .string(data.base64EncodedString())]),
                ]))
            case .document(_, let data):
                blocks.append(.object([
                    "type": "document",
                    "source": .object(["type": "base64", "media_type": "application/pdf",
                                       "data": .string(data.base64EncodedString())]),
                ]))
            }
        }
        return blocks
    }

    static func assistantBlocks(_ m: LLMMessage, replay: Bool) -> [JSONValue] {
        if replay, let replayed = replayBlocks(m) { return replayed }
        var blocks: [JSONValue] = []
        if let content = m.content, !BedrockConverse.isBlank(content) { blocks.append(textBlock(content)) }
        for call in m.toolCalls ?? [] {
            blocks.append(.object([
                "type": "tool_use",
                "id": .string(toolUseID(call.id)),
                "name": .string(call.name),
                "input": inputObject(call.arguments.raw),
            ]))
        }
        if blocks.isEmpty { blocks.append(textBlock("(no reply)")) }
        return blocks
    }

    /// The assistant turn as the model produced it — thinking, text and tool calls in their original
    /// order — from its `providerState`. Nil when there is no usable state: none, another client's,
    /// unreadable, no signed reasoning in it, or tool calls that no longer match the message's.
    static func replayBlocks(_ m: LLMMessage) -> [JSONValue]? {
        guard let state = m.providerState, state.hasPrefix(statePrefix),
              let stored = JSONValue(parsing: String(state.dropFirst(statePrefix.count)))?.array else { return nil }
        var blocks: [JSONValue] = []
        var ids = Set<String>()
        var reasoning = false
        for block in stored {
            switch block["type"]?.string {
            case "thinking", "redacted_thinking":
                reasoning = true
            case "tool_use":
                guard let id = block["id"]?.string else { return nil }
                ids.insert(id)
            case "text":
                if BedrockConverse.isBlank(block["text"]?.string) { continue }
            default:
                return nil
            }
            blocks.append(block)
        }
        let expected = Set((m.toolCalls ?? []).map { toolUseID($0.id) })
        return reasoning && ids == expected ? blocks : nil
    }

    static func tools(_ specs: [ToolSpec], turns: [Turn], cache: Bool) -> [JSONValue]? {
        var offered = specs
        if offered.isEmpty {
            // A transcript with tool blocks must describe its tools: the ones it used.
            var seen = Set<String>()
            for turn in turns {
                for block in turn.content where block["type"]?.string == "tool_use" {
                    guard let name = block["name"]?.string, seen.insert(name).inserted else { continue }
                    offered.append(ToolSpec(name: name, description: "A tool used earlier in this conversation (no longer offered).",
                                            parameters: ""))
                }
            }
            if offered.isEmpty { return nil }
        }
        var tools: [JSONValue] = offered.map { spec in
            var tool: [String: JSONValue] = ["name": .string(spec.name), "input_schema": schema(spec.parameters)]
            if !BedrockConverse.isBlank(spec.description) { tool["description"] = .string(spec.description) }
            return .object(tool)
        }
        if cache, let last = tools.indices.last { tools[last] = cached(tools[last]) }
        return tools
    }

    // MARK: Blocks

    static func textBlock(_ text: String) -> JSONValue { .object(["type": "text", "text": .string(text)]) }

    /// The block with a cache breakpoint on it.
    static func cached(_ block: JSONValue) -> JSONValue {
        guard var fields = block.object else { return block }
        fields["cache_control"] = .object(["type": "ephemeral"])
        return .object(fields)
    }

    static func toolResult(_ id: String, _ output: String?) -> JSONValue {
        let text = BedrockConverse.isBlank(output) ? "(no output)" : (output ?? "")
        var result: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id),
                                           "content": .array([textBlock(text)])]
        if BedrockConverse.isError(text) { result["is_error"] = true }
        return .object(result)
    }

    /// tool_use ids allow [a-zA-Z0-9_-]; ids from another provider's transcript are mapped the same
    /// way for the call and its result.
    static func toolUseID(_ id: String) -> String {
        var clean: [UInt8] = []
        for unit in id.utf16 {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D: // 0-9 A-Z a-z _ -
                clean.append(UInt8(unit))
            default:
                clean.append(UInt8(ascii: "_"))
            }
        }
        if clean.count > 64 { clean.removeSubrange(64...) }
        return clean.isEmpty ? "call" : String(decoding: clean, as: UTF8.self)
    }

    /// Tool input as a JSON object: a non-object value is wrapped, unparseable text becomes {}.
    static func inputObject(_ arguments: String) -> JSONValue {
        guard let parsed = JSONValue(parsing: arguments) else { return .object([:]) }
        switch parsed {
        case .object: return parsed
        case .null: return .object([:])
        default: return .object(["value": parsed])
        }
    }

    static func schema(_ parameters: String) -> JSONValue {
        if let parsed = JSONValue(parsing: parameters), parsed.object != nil { return parsed }
        return .object(["type": "object", "properties": .object([:])])
    }
}

// MARK: - One streamed reply

/// Accumulates a Messages API stream from its server-sent events: text and reasoning deltas are passed
/// on as they come; tool calls and the reply's content blocks are kept until the end. A `fallback`
/// block (server-side fallback) marks where a declined model handed over: the tool calls and
/// reasoning before it were never run and are dropped — only its text stays.
struct MessagesReply {
    private enum Kind { case text, thinking, redacted, toolUse, fallback, other }

    private struct Block {
        var kind = Kind.other
        var text = ""
        var id: String?
        var name: String?
        var signature: String?
        var data: String?
        /// A tool call's input as content_block_start gave it (used when no partial JSON follows).
        var initial: String?

        /// A tool call's arguments: the streamed JSON, else the starting input, else {}.
        var arguments: String { !text.isEmpty ? text : (initial ?? "{}") }
    }

    private var blocks: [Int: Block] = [:]
    private var stopped = false
    private(set) var stopReason: String?
    private var stopDetails: JSONValue?
    private var input = 0, cacheRead: Int?, cacheWrite = 0, output = 0
    private var sawUsage = false
    /// The model that answered (the fallback model when one took over).
    private(set) var model: String?
    /// Each hand-over, for a line in the chat: (declined model, model that carried on).
    private(set) var handovers: [(from: String, to: String)] = []

    /// Take one event (its `event:` name and `data:` JSON); the delta to show, if it carried one.
    /// An error event throws.
    mutating func handle(event: String?, data: JSONValue) throws -> LLMStreamEvent? {
        let type = data["type"]?.string ?? event ?? ""
        let index = data["index"]?.int ?? 0
        switch type {
        case "message_start":
            let message = data["message"]
            model = message?["model"]?.string ?? model
            readUsage(message?["usage"])
            return nil
        case "content_block_start":
            guard let start = data["content_block"], start.object != nil else { return nil }
            var block = Block()
            switch start["type"]?.string {
            case "text":
                block.kind = .text
                block.text = start["text"]?.string ?? ""
            case "thinking":
                block.kind = .thinking
                block.text = start["thinking"]?.string ?? ""
                block.signature = start["signature"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            case "redacted_thinking":
                block.kind = .redacted
                block.data = start["data"]?.string
            case "tool_use":
                block.kind = .toolUse
                block.id = start["id"]?.string
                block.name = start["name"]?.string
                // The input arrives as input_json_delta pieces; a non-empty starting input stands in when
                // none follow.
                if let initial = start["input"], initial.object?.isEmpty == false { block.initial = initial.serialized() }
            case "fallback":
                block.kind = .fallback
                let from = start["from"]?["model"]?.string ?? "the model"
                let to = start["to"]?["model"]?.string ?? "another model"
                handovers.append((from, to))
            default:
                block.kind = .other
            }
            blocks[index] = block
            return block.kind == .text && !block.text.isEmpty ? .text(block.text) : nil
        case "content_block_delta":
            guard let delta = data["delta"], delta.object != nil else { return nil }
            var block = blocks[index] ?? Block()
            defer { blocks[index] = block }
            switch delta["type"]?.string {
            case "text_delta":
                let text = delta["text"]?.string ?? ""
                if block.kind == .other { block.kind = .text }
                block.text += text
                return text.isEmpty ? nil : .text(text)
            case "input_json_delta":
                if block.kind == .other { block.kind = .toolUse }
                block.text += delta["partial_json"]?.string ?? ""
                return nil
            case "thinking_delta":
                let thought = delta["thinking"]?.string ?? ""
                if block.kind == .other { block.kind = .thinking }
                block.text += thought
                return thought.isEmpty ? nil : .reasoning(thought)
            case "signature_delta":
                if block.kind == .other { block.kind = .thinking }
                block.signature = (block.signature ?? "") + (delta["signature"]?.string ?? "")
                return nil
            default:
                return nil
            }
        case "message_delta":
            if let reason = data["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let details = data["delta"]?["stop_details"], details.object != nil { stopDetails = details }
            readUsage(data["usage"])
            return nil
        case "message_stop":
            stopped = true
            return nil
        case "error":
            let error = data["error"]
            throw AnthropicErrors.streamError(type: error?["type"]?.string ?? "", message: error?["message"]?.string ?? data.serialized())
        default:
            // ping, and whatever event a later API version adds.
            return nil
        }
    }

    /// Usage arrives on message_start (input and cache counts) and message_delta (running output, and
    /// on newer API versions the input counts again): the latest non-zero figure wins.
    private mutating func readUsage(_ usage: JSONValue?) {
        guard let usage, usage.object != nil else { return }
        func count(_ key: String) -> Int? { usage[key]?.int }
        if let n = count("input_tokens"), n > 0 || !sawUsage { input = n }
        if let n = count("cache_creation_input_tokens"), n > 0 { cacheWrite = n }
        if let value = usage["cache_read_input_tokens"], !value.isNull, let n = value.int {
            cacheRead = max(n, cacheRead ?? 0)
        }
        if let n = count("output_tokens") { output = max(output, n) }
        sawUsage = true
    }

    /// Index of the last hand-over block (nil when none).
    private var boundary: Int? {
        blocks.filter { $0.value.kind == .fallback }.map(\.key).max()
    }

    /// The reply is over: its calls, finish reason, usage and replay state. A stream that never reached
    /// message_stop was cut off.
    func finish() throws -> LLMStreamEvent {
        guard stopped else {
            throw LLMError.sse(blocks.isEmpty ? "the server closed the connection without replying"
                                              : "the reply was cut off before it finished")
        }
        switch stopReason {
        case "refusal":
            throw AnthropicErrors.refusal(category: stopDetails?["category"]?.string,
                                          explanation: stopDetails?["explanation"]?.string, model: model)
        case "model_context_window_exceeded":
            throw LLMError.overflow(limit: 0, detail: "the model ran out of context window (model_context_window_exceeded)")
        default:
            break
        }
        let from = (boundary ?? -1) + 1
        let calls = blocks.keys.sorted().filter { $0 >= from }.compactMap { index -> ToolCall? in
            guard let block = blocks[index], block.kind == .toolUse else { return nil }
            let id = block.id.flatMap { $0.isEmpty ? nil : $0 } ?? "call-\(index)"
            return ToolCall(id: id, name: block.name ?? "", arguments: block.arguments)
        }
        let finish: String? = switch stopReason {
        case nil, "end_turn", "stop_sequence", "pause_turn": "stop"
        case "tool_use": "tool_calls"
        case "max_tokens": "length"
        default: stopReason
        }
        let usage: LLMUsage? = sawUsage
            ? LLMUsage(promptTokens: input + (cacheRead ?? 0) + cacheWrite, completionTokens: output, cachedTokens: cacheRead)
            : nil
        return .done(calls: calls, finish: finish, usage: usage, providerState: state(from: from))
    }

    /// The reply's content blocks, in order, when they hold signed (or redacted) thinking that must go back with
    /// it; nil otherwise. Before the last hand-over (`from`) only the text stays — the declined model's thinking and
    /// tool calls are left out, as Anthropic's rules for echoing a fallback turn say; text echoes normally.
    private func state(from: Int) -> String? {
        let kept = blocks.keys.sorted().compactMap { index -> Block? in
            guard let block = blocks[index] else { return nil }
            return index >= from || block.kind == .text ? block : nil
        }
        guard kept.contains(where: { ($0.kind == .thinking && $0.signature != nil) || $0.kind == .redacted }) else {
            return nil
        }
        var out: [JSONValue] = []
        for block in kept {
            switch block.kind {
            case .thinking:
                guard let signature = block.signature else { continue }
                out.append(.object(["type": "thinking", "thinking": .string(block.text), "signature": .string(signature)]))
            case .redacted:
                guard let data = block.data else { continue }
                out.append(.object(["type": "redacted_thinking", "data": .string(data)]))
            case .toolUse:
                out.append(.object([
                    "type": "tool_use",
                    "id": .string(block.id ?? ""),
                    "name": .string(block.name ?? ""),
                    "input": BedrockConverse.jsonObject(block.arguments),
                ]))
            case .text:
                if !BedrockConverse.isBlank(block.text) { out.append(.object(["type": "text", "text": .string(block.text)])) }
            case .fallback, .other:
                continue
            }
        }
        return AnthropicMessages.statePrefix + JSONValue.array(out).serialized()
    }
}
