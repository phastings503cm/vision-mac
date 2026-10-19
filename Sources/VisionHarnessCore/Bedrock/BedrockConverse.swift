import Foundation

// MARK: - Bedrock Converse: request bodies and streamed replies
//
// Converse is stricter than chat completions, and every rule below is a 400 when broken:
//   - one system list (the prompt, then any system-role notes such as compaction summaries);
//   - turns alternate user/assistant and start with a user turn, so neighbours of the same role are
//     merged and a transcript that starts mid-conversation gets a stub user turn;
//   - tool results are toolResult blocks inside a user turn, right after the assistant turn that
//     asked, answering every toolUse of it; the engine's automatic image message joins that turn;
//   - no text block may be blank;
//   - a transcript that holds tool blocks needs toolConfig even when no tools are offered.
//
// Claude's extended thinking adds one more: while it works through a turn's tool calls it must get
// back that turn's signed reasoning, verbatim. The reply records its content blocks, in order, in
// `.done`'s `providerState`; the engine stores that on the assistant message and the next request
// replays it. A transcript rebuilt from text (compaction, a restored chat) has no state; a
// budget-thinking Claude would then reject the request, so for such a request thinking is left off
// (adaptive thinking allows a turn without reasoning, so those models need no fallback).

public enum BedrockConverse {
    /// Output tokens kept for the answer on top of a thinking budget.
    public static let replyTokens = 8192

    /// Claude's smallest thinking budget.
    public static let minThinkingBudget = 1024

    /// The thinking budget for a level (Claude 3.7 – 4.5), and the thinking room adaptive models get
    /// on top of their reply.
    public static func thinkingBudget(_ level: ThinkingLevel) -> Int {
        switch level {
        case .off: 0
        case .low: 2048
        case .medium: 8192
        case .high: 16_000
        case .max: 32_000
        }
    }

    /// `outputConfig.effort` for a level (adaptive Claude).
    public static func effort(_ level: ThinkingLevel) -> String {
        switch level {
        case .off, .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "max"
        }
    }

    public static func modelID(_ request: LLMRequest, _ profile: ProviderProfile) -> String {
        request.model.isEmpty ? profile.model : request.model
    }

    /// What this request asks of the model's thinking. `active`: the model may think (so signed
    /// reasoning is replayed and temperature is not sent); `room`: output tokens the thinking may use.
    private struct ThinkingPlan {
        var config: [String: JSONValue]?
        var effort: String?
        var active: Bool
        var room: Int

        static let none = ThinkingPlan(config: nil, effort: nil, active: false, room: 0)
    }

    /// The ConverseStream request body (the model id goes in the URL). With `replayReasoning` false,
    /// stored reasoning is not sent back — the retry after Claude refused it (a changed prefix
    /// invalidates the signature).
    public static func request(_ request: LLMRequest, profile: ProviderProfile, replayReasoning: Bool = true) -> JSONValue {
        let traits = BedrockModels.traits(modelID(request, profile))
        let plan = thinkingPlan(traits, level: request.thinking ?? profile.thinking, messages: request.messages,
                                replayReasoning: replayReasoning)
        let replay = replayReasoning && traits.isClaude && plan.active

        var system: [JSONValue] = []
        func addSystem(_ text: String?) {
            if let text, !isBlank(text) { system.append(textBlock(text)) }
        }
        addSystem(request.systemPrompt)
        for m in request.messages where m.role == .system { addSystem(m.content) }
        if !system.isEmpty && traits.cachePoints { system.append(cachePointBlock()) }

        var turns = makeTurns(request.messages, traits: traits, replay: replay,
                              attachments: AttachmentRoute.bedrock(profile, traits: traits))
        if traits.cachePoints { turns[turns.count - 1].content.append(cachePointBlock()) }
        let messages = turns.map { turn in
            JSONValue.object(["role": .string(turn.role), "content": .array(turn.content)])
        }

        var body: [String: JSONValue] = ["messages": .array(messages)]
        if !system.isEmpty { body["system"] = .array(system) }

        var maxTokens = max(request.maxTokens ?? profile.maxOutputTokens ?? traits.defaultMaxTokens, plan.room)
        if let ceiling = traits.maxTokensCeiling { maxTokens = min(maxTokens, ceiling) }
        var inference: [String: JSONValue] = ["maxTokens": .number(Double(maxTokens))]
        if traits.sampling, !plan.active, let temperature = request.temperature ?? profile.temperature {
            inference["temperature"] = .number(temperature)
        }
        body["inferenceConfig"] = .object(inference)

        if let tools = toolConfig(request.tools, turns: turns, traits: traits) {
            body["toolConfig"] = .object(["tools": .array(tools)])
        }

        if var thinking = plan.config {
            // budget_tokens must stay below maxTokens, which the model's ceiling may have capped.
            if thinking["budget_tokens"] != nil {
                let budget = max(minThinkingBudget, min(plan.room - replyTokens, maxTokens - replyTokens))
                thinking["budget_tokens"] = .number(Double(budget))
            }
            body["additionalModelRequestFields"] = .object(["thinking": .object(thinking)])
        }
        if let effort = plan.effort { body["outputConfig"] = .object(["effort": .string(effort)]) }
        return .object(body)
    }

    private static func thinkingPlan(_ traits: BedrockModelTraits, level: ThinkingLevel?, messages: [LLMMessage],
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
            let budget = thinkingBudget(level)
            return ThinkingPlan(config: ["type": .string("enabled"), "budget_tokens": .number(Double(budget))],
                                effort: nil, active: true, room: budget + replyTokens)
        case .adaptive:
            // No level: the model's own default, which is thinking for Claude 5 and later.
            guard let level else {
                var plan = ThinkingPlan.none
                plan.active = traits.off != .omit
                return plan
            }
            if level == .off {
                switch traits.off {
                case .disabled:
                    return ThinkingPlan(config: ["type": .string("disabled")], effort: nil, active: false, room: 0)
                case .betweenTools:
                    return ThinkingPlan(config: ["type": .string("between_tools")], effort: nil, active: true, room: 0)
                case .lowEffort:
                    return ThinkingPlan(config: nil, effort: effort(.low), active: true, room: 0)
                case .omit:
                    return .none
                }
            }
            var config: [String: JSONValue] = ["type": .string("adaptive")]
            if traits.summarizedThinking { config["display"] = .string("summarized") }
            return ThinkingPlan(config: config, effort: effort(level), active: true, room: thinkingBudget(level) + replyTokens)
        case .none:
            return .none
        }
    }

    // MARK: Turns

    private struct Turn {
        var role: String
        var content: [JSONValue]
    }

    private static let interruptedCall = "Not run — the turn was interrupted before this call executed."

    private static func makeTurns(_ messages: [LLMMessage], traits: BedrockModelTraits, replay: Bool,
                                  attachments route: AttachmentRoute) -> [Turn] {
        var turns: [Turn] = []
        // toolUse ids of the latest assistant turn still waiting for their results.
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

        // Calls nobody answered (an interrupted turn) get a stub result, as Converse demands one each.
        func closeOpenCalls() {
            guard !open.isEmpty else { return }
            let stubs = open.map { toolResult($0, interruptedCall, traits: traits) }
            open.removeAll()
            add("user", stubs)
        }

        for m in messages {
            switch m.role {
            case .user:
                closeOpenCalls()
                add("user", userBlocks(m, route: route))
            case .tool:
                let id = toolUseID(m.toolCallID ?? "")
                if let index = open.firstIndex(of: id) {
                    open.remove(at: index)
                    add("user", [toolResult(id, m.content, traits: traits)])
                } else {
                    // A result whose call is gone (trimmed history): keep what it said, as text.
                    let output = isBlank(m.content) ? "(no output)" : (m.content ?? "")
                    add("user", [textBlock("[Result of \(m.name ?? "a tool")]\n\(output)")])
                }
            case .assistant:
                closeOpenCalls()
                let blocks = assistantBlocks(m, replay: replay)
                open.append(contentsOf: blocks.compactMap { $0["toolUse"]?["toolUseId"]?.string })
                add("assistant", blocks)
            case .system:
                break
            }
        }
        closeOpenCalls()
        if turns.isEmpty { turns.append(Turn(role: "user", content: [textBlock("(continuing the conversation)")])) }
        // Converse wants the model to answer a user turn, and newer Claude models refuse a prefilled
        // assistant turn.
        if turns[turns.count - 1].role == "assistant" {
            turns.append(Turn(role: "user", content: [textBlock("Continue.")]))
        }
        for index in turns.indices where turns[index].role == "user" {
            if turns[index].content.isEmpty { turns[index].content.append(textBlock("(empty message)")) }
            // A document must travel with some text.
            let kinds = Set(turns[index].content.flatMap { $0.object.map { Array($0.keys) } ?? [] })
            if kinds.contains("document") && !kinds.contains("text") {
                turns[index].content.append(textBlock("(see the attached document)"))
            }
        }
        return turns
    }

    /// The user's text, then each attachment as `AttachmentWire` sends it on this route: images in Converse's four
    /// formats, PDFs as documents where the model reads them, everything else as the text Vision read out of it.
    private static func userBlocks(_ m: LLMMessage, route: AttachmentRoute) -> [JSONValue] {
        var blocks: [JSONValue] = []
        if let content = m.content, !isBlank(content) { blocks.append(textBlock(content)) }
        for part in AttachmentWire.parts(for: m.attachments ?? [], route: route) {
            switch part {
            case .text(let text):
                blocks.append(textBlock(text))
            case .image(let mime, let data):
                guard let format = imageFormat(mime) else { blocks.append(textBlock("[image of \(data.count) bytes, not shown]")); continue }
                blocks.append(.object([
                    "image": .object([
                        "format": .string(format),
                        "source": .object(["bytes": .string(data.base64EncodedString())]),
                    ]),
                ]))
            case .document(let name, let data):
                blocks.append(.object([
                    "document": .object([
                        "format": .string("pdf"),
                        "name": .string(documentName(name)),
                        "source": .object(["bytes": .string(data.base64EncodedString())]),
                    ]),
                ]))
            }
        }
        return blocks
    }

    private static func assistantBlocks(_ m: LLMMessage, replay: Bool) -> [JSONValue] {
        if replay, let replayed = replayBlocks(m) { return replayed }
        var blocks: [JSONValue] = []
        if let content = m.content, !isBlank(content) { blocks.append(textBlock(content)) }
        for call in m.toolCalls ?? [] {
            blocks.append(.object([
                "toolUse": .object([
                    "toolUseId": .string(toolUseID(call.id)),
                    "name": .string(call.name),
                    "input": inputObject(call.arguments.raw),
                ]),
            ]))
        }
        if blocks.isEmpty { blocks.append(textBlock("(no reply)")) }
        return blocks
    }

    /// The assistant turn as the model produced it, from its `providerState` — reasoning, text and
    /// tool calls in their original order, which the signatures depend on. Nil when there is no
    /// usable state: none, unreadable, no reasoning in it, or tool calls that no longer match the
    /// message's.
    static func replayBlocks(_ m: LLMMessage) -> [JSONValue]? {
        guard let state = m.providerState, !state.isEmpty else { return nil }
        guard let stored = JSONValue(parsing: state)?.array else { return nil }
        var blocks: [JSONValue] = []
        var ids = Set<String>()
        var reasoning = false
        for block in stored {
            guard block.object != nil else { return nil }
            if block["reasoningContent"]?.object != nil {
                reasoning = true
            } else if block["toolUse"]?.object != nil, let id = block["toolUse"]?["toolUseId"]?.string {
                ids.insert(id)
            } else if let text = block["text"]?.string {
                if isBlank(text) { continue }
            } else {
                return nil
            }
            blocks.append(block)
        }
        let expected = Set((m.toolCalls ?? []).map { toolUseID($0.id) })
        return reasoning && ids == expected ? blocks : nil
    }

    private static func toolConfig(_ specs: [ToolSpec], turns: [Turn], traits: BedrockModelTraits) -> [JSONValue]? {
        var offered = specs
        if offered.isEmpty {
            // Converse refuses tool blocks without a toolConfig: describe the tools the transcript used
            // (every toolResult answers one of these toolUse blocks, orphans having become text).
            var seen = Set<String>()
            for turn in turns {
                for block in turn.content {
                    guard let name = block["toolUse"]?["name"]?.string, seen.insert(name).inserted else { continue }
                    offered.append(ToolSpec(name: name, description: "A tool used earlier in this conversation (no longer offered).",
                                            parameters: ""))
                }
            }
            if offered.isEmpty { return nil }
        }
        var tools: [JSONValue] = []
        for spec in offered {
            var toolSpec: [String: JSONValue] = ["name": .string(spec.name)]
            if !isBlank(spec.description) { toolSpec["description"] = .string(spec.description) }
            toolSpec["inputSchema"] = .object(["json": schema(spec.parameters)])
            tools.append(.object(["toolSpec": .object(toolSpec)]))
        }
        if traits.toolCachePoint { tools.append(cachePointBlock()) }
        return tools
    }

    // MARK: Blocks

    private static func textBlock(_ text: String) -> JSONValue { .object(["text": .string(text)]) }

    private static func cachePointBlock() -> JSONValue { .object(["cachePoint": .object(["type": .string("default")])]) }

    private static func toolResult(_ id: String, _ output: String?, traits: BedrockModelTraits) -> JSONValue {
        let text = isBlank(output) ? "(no output)" : (output ?? "")
        var result: [String: JSONValue] = ["toolUseId": .string(id), "content": .array([textBlock(text)])]
        if traits.toolResultStatus && isError(text) { result["status"] = .string("error") }
        return .object(["toolResult": .object(result)])
    }

    /// The engine's failure wording: "Error: …" from tools, "Permission denied: …" when the user
    /// refused the call.
    static func isError(_ output: String) -> Bool {
        // Byte-wise, like an ordinal comparison: `hasPrefix` works on grapheme clusters, so "Error"
        // followed by a combining mark would not match.
        output.utf8.starts(with: "Error".utf8) || output.utf8.starts(with: "Permission denied".utf8)
    }

    /// Converse tool-use ids allow [a-zA-Z0-9_.:-], at most 64 characters; ids from another
    /// provider's transcript are mapped the same way for the call and its result.
    static func toolUseID(_ id: String) -> String {
        var clean: [UInt8] = []
        for unit in id.utf16 {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2E, 0x3A, 0x2D: // 0-9 A-Z a-z _ . : -
                clean.append(UInt8(unit))
            default:
                clean.append(UInt8(ascii: "_"))
            }
        }
        if clean.count > 64 { clean.removeSubrange(64...) }
        return clean.isEmpty ? "call" : String(decoding: clean, as: UTF8.self)
    }

    /// Tool input as a JSON object: a non-object value is wrapped, unparseable text becomes {}.
    private static func inputObject(_ arguments: String) -> JSONValue {
        guard let parsed = JSONValue(parsing: arguments) else { return .object([:]) }
        switch parsed {
        case .object: return parsed
        case .null: return .object([:])
        default: return .object(["value": parsed])
        }
    }

    /// A JSON object from text, or `{}` when it isn't one (a tool call cut off mid-way).
    static func jsonObject(_ text: String) -> JSONValue {
        if let parsed = JSONValue(parsing: text), parsed.object != nil { return parsed }
        return .object([:])
    }

    /// A tool's parameter schema, or an empty object schema when it isn't one.
    private static func schema(_ parameters: String) -> JSONValue {
        if let parsed = JSONValue(parsing: parameters), parsed.object != nil { return parsed }
        return .object(["type": .string("object"), "properties": .object([:])])
    }

    private static func imageFormat(_ mime: String) -> String? {
        switch mime {
        case "image/png": "png"
        case "image/jpeg": "jpeg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: nil
        }
    }

    /// Document names allow letters, digits, single spaces, hyphens, parentheses and square
    /// brackets.
    private static func documentName(_ fileName: String) -> String {
        // The file name without directory or extension (Path.GetFileNameWithoutExtension).
        var stem = Substring(fileName)
        if let separator = stem.lastIndex(where: { $0 == "/" || $0 == "\\" }) { stem = stem[stem.index(after: separator)...] }
        if let dot = stem.lastIndex(of: ".") { stem = stem[..<dot] }
        // One hyphen per UTF-16 unit, so an emoji (two units) becomes two.
        let cleaned = stem.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x20, 0x2D, 0x28, 0x29, 0x5B, 0x5D: // 0-9 A-Z a-z space - ( ) [ ]
                return Character(Unicode.Scalar(UInt8(unit)))
            default:
                return "-"
            }
        }
        let name = String(cleaned).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return name.isEmpty ? "document" : name
    }

    // MARK: Text

    /// Nil, empty or all white space (`string.IsNullOrWhiteSpace`).
    static func isBlank(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

// MARK: - One streamed reply

/// Accumulates a ConverseStream reply from its event frames: text and reasoning deltas are passed
/// on as they come, tool calls and the reply's content blocks are kept until the end.
struct ConverseReply {
    private enum Kind { case text, toolUse, reasoning }

    private struct Block {
        var kind = Kind.text
        var text = ""
        var toolUseID: String?
        var name: String?
        var signature: String?
        var redacted: [Data]?
    }

    private var blocks: [Int: Block] = [:]
    private var stopped = false
    private var stopReason: String?
    private var usage: LLMUsage?
    /// Turns an exception frame's type and message into the error to throw.
    private let exceptionFrame: (_ type: String, _ message: String) -> Error

    init(exceptionFrame: @escaping (_ type: String, _ message: String) -> Error) {
        self.exceptionFrame = exceptionFrame
    }

    /// Take one frame; the delta to show, if it carried one. Exception frames throw.
    mutating func handle(_ message: AWSEventMessage) throws -> LLMStreamEvent? {
        switch message.messageType {
        case "exception":
            throw exceptionFrame(message.exceptionType ?? "", Self.messageOf(message.payloadText))
        case "error":
            throw exceptionFrame(message.headers[":error-code"] ?? "",
                                 message.headers[":error-message"] ?? message.payloadText)
        case "event", nil:
            break
        default:
            return nil
        }
        guard let payload = JSONValue(parsing: message.payload), payload.object != nil else { return nil }
        let index = Self.int32(payload["contentBlockIndex"]) ?? 0
        switch message.eventType {
        case "contentBlockStart":
            if let use = payload["start"]?["toolUse"], use.object != nil {
                var block = blocks[index] ?? Block()
                block.kind = .toolUse
                block.toolUseID = use["toolUseId"]?.string
                block.name = use["name"]?.string
                blocks[index] = block
            }
            return nil
        case "contentBlockDelta":
            guard let delta = payload["delta"], delta.object != nil else { return nil }
            if let text = delta["text"]?.string {
                blocks[index, default: Block()].text += text
                return text.isEmpty ? nil : .text(text)
            }
            if let toolUse = delta["toolUse"], toolUse.object != nil {
                var block = blocks[index] ?? Block()
                block.kind = .toolUse
                block.text += toolUse["input"]?.string ?? ""
                blocks[index] = block
                return nil
            }
            if let reasoning = delta["reasoningContent"], reasoning.object != nil {
                var block = blocks[index] ?? Block()
                block.kind = .reasoning
                if let signature = reasoning["signature"]?.string { block.signature = (block.signature ?? "") + signature }
                if let redacted = reasoning["redactedContent"]?.string {
                    // A piece that isn't base64 still leaves an (empty) redacted block behind.
                    var pieces = block.redacted ?? []
                    if let bytes = Data(base64Encoded: redacted) { pieces.append(bytes) }
                    block.redacted = pieces
                }
                var event: LLMStreamEvent?
                if let thought = reasoning["text"]?.string, !thought.isEmpty {
                    block.text += thought
                    event = .reasoning(thought)
                }
                blocks[index] = block
                return event
            }
            return nil
        case "messageStop":
            stopped = true
            stopReason = payload["stopReason"]?.string
            return nil
        case "metadata":
            if let u = payload["usage"], u.object != nil {
                func count(_ key: String) -> Int { Self.int32(u[key]) ?? 0 }
                let cacheRead = u["cacheReadInputTokens"]
                // Cached input is still input: the gauge wants the whole prompt.
                usage = LLMUsage(
                    promptTokens: count("inputTokens") + count("cacheReadInputTokens") + count("cacheWriteInputTokens"),
                    completionTokens: count("outputTokens"),
                    cachedTokens: (cacheRead == nil || cacheRead?.isNull == true) ? nil : count("cacheReadInputTokens"))
            }
            return nil
        default:
            return nil
        }
    }

    /// The reply is over: its calls, finish reason, usage and replay state. A stream that never
    /// reached messageStop was cut off.
    func finish() throws -> LLMStreamEvent {
        guard stopped else {
            throw LLMError.sse(blocks.isEmpty ? "the server closed the connection without replying"
                                              : "the reply was cut off before it finished")
        }
        if stopReason == "model_context_window_exceeded" {
            throw LLMError.overflow(limit: 0, detail: "the model ran out of context window (model_context_window_exceeded)")
        }
        let calls = blocks.keys.sorted().compactMap { index -> ToolCall? in
            guard let block = blocks[index], block.kind == .toolUse else { return nil }
            let id = block.toolUseID.flatMap { $0.isEmpty ? nil : $0 } ?? "call-\(index)"
            return ToolCall(id: id, name: block.name ?? "", arguments: block.text.isEmpty ? "{}" : block.text)
        }
        let finish: String? = switch stopReason {
        case nil, "end_turn", "stop_sequence": "stop"
        case "tool_use": "tool_calls"
        case "max_tokens": "length"
        default: stopReason
        }
        return .done(calls: calls, finish: finish, usage: usage, providerState: state())
    }

    /// The reply's content blocks in order, when it holds signed (or redacted) reasoning that must go
    /// back with it; nil otherwise (unsigned reasoning, as from DeepSeek, is never replayed).
    private func state() -> String? {
        guard blocks.values.contains(where: { $0.kind == .reasoning && ($0.signature != nil || $0.redacted != nil) }) else {
            return nil
        }
        var out: [JSONValue] = []
        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block.kind {
            case .reasoning:
                if let redacted = block.redacted {
                    let joined = redacted.reduce(into: Data()) { $0.append($1) }
                    out.append(.object(["reasoningContent": .object(["redactedContent": .string(joined.base64EncodedString())])]))
                } else if let signature = block.signature {
                    out.append(.object(["reasoningContent": .object([
                        "reasoningText": .object(["text": .string(block.text), "signature": .string(signature)]),
                    ])]))
                }
            case .toolUse:
                out.append(.object(["toolUse": .object([
                    "toolUseId": .string(block.toolUseID ?? ""),
                    "name": .string(block.name ?? ""),
                    "input": BedrockConverse.jsonObject(block.text.isEmpty ? "{}" : block.text),
                ])]))
            case .text:
                if !BedrockConverse.isBlank(block.text) { out.append(.object(["text": .string(block.text)])) }
            }
        }
        return JSONValue.array(out).serialized()
    }

    /// The "message" of an exception payload ({"message": "..."}), or the payload itself.
    static func messageOf(_ payload: String) -> String {
        if let object = JSONValue(parsing: payload), object.object != nil {
            return object["message"]?.string ?? object["Message"]?.string ?? payload
        }
        return payload
    }

    /// An integral JSON number that fits an Int32, else nil: a count beyond that is not a token count.
    static func int32(_ value: JSONValue?) -> Int? {
        guard let number = value?.int, let narrowed = Int32(exactly: number) else { return nil }
        return Int(narrowed)
    }
}
