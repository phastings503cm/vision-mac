import XCTest
@testable import VisionHarnessCore

/// The "Anthropic API (key)" route: request bodies per Claude model (thinking, effort, sampling, caching, fallbacks),
/// turns that the Messages API accepts, the streamed reply (text, signed thinking, tool calls, usage with cache reads,
/// refusals, server-side fallback), and errors in plain words. The 401 bodies are Anthropic's own (recorded
/// 2026-10-19 with a made-up key); the others are the documented shapes.
final class AnthropicClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AnthropicClient.resetLearned()
    }

    override func tearDown() {
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        AnthropicClient.resetLearned()
        super.tearDown()
    }

    // MARK: Fixtures

    private func route(_ model: String, temperature: Double? = nil, thinking: ThinkingLevel? = nil) -> ProviderProfile {
        var route = ProviderProfile(kind: .anthropic, name: "Anthropic", baseURL: AnthropicMessages.defaultBaseURL,
                                    apiKey: "sk-ant-api03-test", model: model, temperature: temperature)
        route.thinking = thinking
        return route
    }

    private let readFile = ToolSpec(name: "read_file", description: "Read a file",
                                    parameters: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#)

    private func body(_ profile: ProviderProfile, thinking: ThinkingLevel? = nil, messages: [LLMMessage] = [.user("hi")],
                      tools: [ToolSpec] = [], replay: Bool = true) -> JSONValue {
        AnthropicMessages.request(LLMRequest(systemPrompt: "You are Vision.", messages: messages, tools: tools,
                                             model: profile.model, thinking: thinking),
                                  profile: profile, replayReasoning: replay)
    }

    /// An SSE body of Messages API events.
    static func events(_ list: [[String: Any]]) -> String {
        list.map { event in
            let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return "event: \(event["type"] as! String)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
    }

    static func textReply(_ text: String, stop: String = "end_turn") -> String {
        events([
            ["type": "message_start", "message": ["id": "msg_1", "model": "claude-opus-5-5",
                                                  "usage": ["input_tokens": 12, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ])
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(headers: [String: String], body: [String: Any], path: String)] = []
        func add(_ r: URLRequest) {
            var data = r.httpBody ?? Data()
            if data.isEmpty, let stream = r.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buf = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            lock.withLock { items.append((r.allHTTPHeaderFields ?? [:], body, r.url?.path ?? "")) }
        }
        var all: [(headers: [String: String], body: [String: Any], path: String)] { lock.withLock { items } }
    }

    private func serve(_ replies: [StubServer.Reply]) -> Seen {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        let seen = Seen()
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let counter = Counter()
        StubServer.reset { request in
            seen.add(request)
            let index = counter.lock.withLock { () -> Int in counter.n += 1; return counter.n - 1 }
            return index < replies.count ? replies[index] : replies[replies.count - 1]
        }
        return seen
    }

    final class Notices: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    private func run(_ profile: ProviderProfile, messages: [LLMMessage] = [.user("hi")], tools: [ToolSpec] = [],
                     notices: Notices = Notices()) async throws -> (text: String, reasoning: String, done: LLMStreamEvent?) {
        let client = AnthropicClient(profile: profile, onNotice: { notices.add($0) })
        var text = "", reasoning = ""
        var done: LLMStreamEvent?
        for try await event in client.stream(LLMRequest(systemPrompt: "sys", messages: messages, tools: tools, model: profile.model)) {
            switch event {
            case .text(let t): text += t
            case .reasoning(let r): reasoning += r
            case .done: done = event
            }
        }
        return (text, reasoning, done)
    }

    // MARK: Request bodies per model

    /// Opus 5.5 can't turn thinking off (`thinking.type.disabled` is a 400): Off is the lowest effort, no thinking
    /// field, no temperature (sampling parameters are removed), and server-side fallback is asked for.
    func testOpus55OffIsTheLowestEffortWithoutSamplingAndWithFallbacks() {
        let b = body(route("claude-opus-5-5", temperature: 0.7), thinking: .off)
        XCTAssertNil(b["thinking"])
        XCTAssertEqual(b["output_config"]?["effort"]?.string, "low")
        XCTAssertNil(b["temperature"])
        XCTAssertEqual(b["fallbacks"]?.string, "default")
        XCTAssertEqual(b["stream"]?.bool, true)
        XCTAssertEqual(b["model"]?.string, "claude-opus-5-5")
    }

    /// Sonnet 5.5 turns thinking off with `between_tools` (no other thinking field, no fallback with it).
    func testSonnet55OffIsBetweenToolsWithoutFallbacks() {
        let b = body(route("claude-sonnet-5-5"), thinking: .off)
        XCTAssertEqual(b["thinking"], .object(["type": "between_tools"]))
        XCTAssertNil(b["output_config"])
        XCTAssertNil(b["fallbacks"], "a fallback re-sends the body, and only Sonnet 5.5 takes between_tools")
        XCTAssertEqual(body(route("claude-sonnet-5-5"), thinking: .high)["fallbacks"]?.string, "default")
    }

    /// A level asks for adaptive thinking with summarized text (so the reasoning pane shows something) and the
    /// effort; output room grows with it.
    func testALevelIsAdaptiveSummarizedThinkingWithItsEffort() {
        let b = body(route("claude-opus-5-5"), thinking: .high)
        XCTAssertEqual(b["thinking"], .object(["type": "adaptive", "display": "summarized"]))
        XCTAssertEqual(b["output_config"]?["effort"]?.string, "high")
        XCTAssertEqual(b["max_tokens"]?.int, 16_000 + BedrockConverse.replyTokens)
        XCTAssertEqual(body(route("claude-opus-5-5"), thinking: .max)["output_config"]?["effort"]?.string, "max")
    }

    /// No level: Claude 5 thinks by default (asked for summaries); Opus 4.8 doesn't think unless asked.
    func testNoLevelFollowsTheModelsDefault() {
        XCTAssertEqual(body(route("claude-opus-5-5"))["thinking"]?["type"]?.string, "adaptive")
        XCTAssertNil(body(route("claude-opus-4-8"))["thinking"])
        XCTAssertNil(body(route("claude-opus-4-8"))["fallbacks"])
    }

    /// Haiku 4.5 thinks with a budget below max_tokens, and takes a temperature only while not thinking.
    func testHaiku45UsesABudgetAndATemperatureOnlyWithoutThinking() {
        let on = body(route("claude-haiku-4-5", temperature: 0.3), thinking: .high)
        XCTAssertEqual(on["thinking"]?["type"]?.string, "enabled")
        let budget = on["thinking"]?["budget_tokens"]?.int ?? 0
        XCTAssertLessThan(budget, on["max_tokens"]?.int ?? 0)
        XCTAssertNil(on["temperature"])
        let off = body(route("claude-haiku-4-5", temperature: 0.3), thinking: .off)
        XCTAssertNil(off["thinking"])
        XCTAssertEqual(off["temperature"]?.double, 0.3)
    }

    /// Prompt caching: a breakpoint after the system prompt, after the tool list and on the conversation's last block.
    func testCacheBreakpointsSitOnTheSystemPromptTheToolsAndTheLastBlock() {
        let b = body(route("claude-sonnet-5-5"), messages: [.user("first"), .assistant("ok"), .user("second")], tools: [readFile])
        XCTAssertEqual(b["system"]?[0]?["cache_control"], .object(["type": "ephemeral"]))
        XCTAssertEqual(b["system"]?[0]?["text"]?.string, "You are Vision.")
        let tools = b["tools"]?.array ?? []
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["input_schema"]?["required"], .array(["path"]))
        XCTAssertEqual(tools[0]["cache_control"], .object(["type": "ephemeral"]))
        let messages = b["messages"]?.array ?? []
        XCTAssertEqual(messages.map { $0["role"]?.string ?? "" }, ["user", "assistant", "user"])
        XCTAssertNil(messages[0]["content"]?[0]?["cache_control"])
        XCTAssertEqual(messages[2]["content"]?[0]?["cache_control"], .object(["type": "ephemeral"]))
    }

    /// Tool results go back first in their user turn, a call nobody answered gets a stub, ids the Messages API
    /// would refuse are mapped the same way for the call and its result, and a tool-only transcript still has tools.
    func testToolTurnsAreShapedTheWayTheMessagesAPIWantsThem() {
        let call = ToolCall(id: "call:1.two", name: "read_file", arguments: #"{"path":"a.txt"}"#)
        let lost = ToolCall(id: "call_lost", name: "read_file", arguments: "not json")
        let messages: [LLMMessage] = [
            .user("read it"),
            .assistant("Reading.", calls: [call, lost]),
            .toolResult(id: "call:1.two", name: "read_file", output: "hello"),
            .user("and?"),
        ]
        let b = body(route("claude-opus-5-5"), messages: messages)
        let turns = b["messages"]?.array ?? []
        XCTAssertEqual(turns.map { $0["role"]?.string ?? "" }, ["user", "assistant", "user"])
        let assistant = turns[1]["content"]?.array ?? []
        XCTAssertEqual(assistant[1]["id"]?.string, "call_1_two")
        XCTAssertEqual(assistant[2]["input"], .object([:]), "broken arguments become {}")
        let user = turns[2]["content"]?.array ?? []
        XCTAssertEqual(user.map { $0["type"]?.string ?? "" }, ["tool_result", "tool_result", "text"])
        XCTAssertEqual(user[0]["tool_use_id"]?.string, "call_1_two")
        XCTAssertEqual(user[1]["content"]?[0]?["text"]?.string, AnthropicMessages.interruptedCall)
        XCTAssertNotNil(b["tools"], "a transcript with tool blocks describes its tools even when none are offered")
    }

    /// Pictures go as base64 image blocks and a PDF as a document block.
    func testPicturesAndPDFsGoAsImageAndDocumentBlocks() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 1, count: 32))
        let pdf = Data("%PDF-1.4 tiny".utf8)
        let message = LLMMessage.user("look", attachments: [
            MessageAttachment(kind: .image, name: "shot.png", data: png),
            MessageAttachment(kind: .file, name: "spec.pdf", data: pdf),
        ])
        let content = body(route("claude-opus-5-5"), messages: [message])["messages"]?[0]?["content"]?.array ?? []
        XCTAssertEqual(content.map { $0["type"]?.string ?? "" }, ["text", "image", "document"])
        XCTAssertEqual(content[1]["source"]?["media_type"]?.string, "image/png")
        XCTAssertEqual(content[1]["source"]?["data"]?.string, png.base64EncodedString())
        XCTAssertEqual(content[2]["source"]?["media_type"]?.string, "application/pdf")
    }

    /// Signed thinking goes back verbatim with the turn whose tool calls are being answered; without replay (the
    /// retry after a refused signature) the turn is rebuilt from its text and calls.
    func testSignedThinkingIsReplayedWithItsTurn() {
        let state = AnthropicMessages.statePrefix + JSONValue.array([
            .object(["type": "thinking", "thinking": "plan it", "signature": "sig=="]),
            .object(["type": "tool_use", "id": "toolu_1", "name": "read_file", "input": .object(["path": "a"])]),
        ]).serialized()
        var assistant = LLMMessage.assistant("", calls: [ToolCall(id: "toolu_1", name: "read_file", arguments: #"{"path":"a"}"#)])
        assistant.providerState = state
        let messages: [LLMMessage] = [.user("go"), assistant, .toolResult(id: "toolu_1", name: "read_file", output: "x")]
        let replayed = body(route("claude-opus-5-5"), thinking: .high, messages: messages)["messages"]?[1]?["content"]?.array ?? []
        XCTAssertEqual(replayed.first?["type"]?.string, "thinking")
        XCTAssertEqual(replayed.first?["signature"]?.string, "sig==")
        let rebuilt = body(route("claude-opus-5-5"), thinking: .high, messages: messages, replay: false)["messages"]?[1]?["content"]?.array ?? []
        XCTAssertEqual(rebuilt.map { $0["type"]?.string ?? "" }, ["tool_use"])
        // Bedrock's state is never read as this client's.
        var bedrock = assistant
        bedrock.providerState = #"[{"reasoningContent":{"reasoningText":{"text":"x","signature":"s"}}}]"#
        XCTAssertNil(AnthropicMessages.replayBlocks(bedrock))
    }

    func testFallbackModels() {
        XCTAssertTrue(AnthropicMessages.takesFallbacks("claude-fable-5-1"))
        XCTAssertTrue(AnthropicMessages.takesFallbacks("claude-opus-5"))
        XCTAssertTrue(AnthropicMessages.takesFallbacks("claude-opus-5-5"))
        XCTAssertTrue(AnthropicMessages.takesFallbacks("claude-sonnet-5-5"))
        XCTAssertFalse(AnthropicMessages.takesFallbacks("claude-haiku-5-5"), "no server-side fallback for Haiku 5.5")
        XCTAssertFalse(AnthropicMessages.takesFallbacks("claude-fable-5"))
        XCTAssertFalse(AnthropicMessages.takesFallbacks("claude-sonnet-5"))
    }

    // MARK: The stream

    /// Text, summarized thinking with its signature, a tool call in pieces, usage with a cache read, and the replay
    /// state for the next request.
    func testAStreamedTurnWithThinkingAndAToolCall() async throws {
        let seen = serve([.init(status: 200, body: Self.events([
            ["type": "message_start", "message": ["model": "claude-opus-5-5",
                                                  "usage": ["input_tokens": 10, "cache_read_input_tokens": 90, "cache_creation_input_tokens": 0, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Need the file."]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "EqQB"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Reading it."]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_9", "name": "read_file", "input": [String: Any]()]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": #"{"path":"#]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": #""a.txt"}"#]],
            ["type": "content_block_stop", "index": 2],
            ["type": "ping"],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 42]],
            ["type": "message_stop"],
        ]))])
        let result = try await run(route("claude-opus-5-5"), tools: [readFile])
        XCTAssertEqual(result.text, "Reading it.")
        XCTAssertEqual(result.reasoning, "Need the file.")
        guard case .done(let calls, let finish, let usage, let state)? = result.done else { return XCTFail("no done") }
        XCTAssertEqual(calls, [ToolCall(id: "toolu_9", name: "read_file", arguments: #"{"path":"a.txt"}"#)])
        XCTAssertEqual(finish, "tool_calls")
        XCTAssertEqual(usage, LLMUsage(promptTokens: 100, completionTokens: 42, cachedTokens: 90))
        let blocks = JSONValue(parsing: String(state?.dropFirst(AnthropicMessages.statePrefix.count) ?? ""))?.array ?? []
        XCTAssertEqual(blocks.map { $0["type"]?.string ?? "" }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(blocks[0]["signature"]?.string, "EqQB")

        let request = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(request.path, "/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant-api03-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["anthropic-beta"], AnthropicMessages.fallbackBeta)
        XCTAssertNil(request.headers["Authorization"])
    }

    /// A declined request (HTTP 200, stop_reason "refusal") is a plain sentence, not retried.
    func testARefusalSaysSoAndIsNotRetried() async throws {
        _ = serve([.init(status: 200, body: Self.events([
            ["type": "message_start", "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 5, "output_tokens": 0]]],
            ["type": "message_delta", "delta": ["stop_reason": "refusal", "stop_details": ["type": "refusal", "category": "cyber"]],
             "usage": ["output_tokens": 0]],
            ["type": "message_stop"],
        ]))])
        do {
            _ = try await run(route("claude-opus-5-5"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("declined this request (its safety check: cyber)"), error.localizedDescription)
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
        }
    }

    /// Server-side fallback mid-reply: the declined model's tool call before the hand-over never ran and is dropped;
    /// the chat gets one line saying who carried on.
    func testAFallbackHandOverDropsTheDeclinedModelsCallsAndSaysWhoCarriedOn() async throws {
        _ = serve([.init(status: 200, body: Self.events([
            ["type": "message_start", "message": ["model": "claude-opus-5", "usage": ["input_tokens": 5, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "toolu_a", "name": "read_file", "input": ["path": "x"]]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "Here you go."]],
            ["type": "content_block_stop", "index": 2],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 4]],
            ["type": "message_stop"],
        ]))])
        let notices = Notices()
        let result = try await run(route("claude-opus-5-5"), notices: notices)
        guard case .done(let calls, let finish, _, _)? = result.done else { return XCTFail("no done") }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(finish, "stop")
        XCTAssertEqual(result.text, "Here you go.")
        XCTAssertEqual(notices.all, ["claude-opus-5-5 declined this request — claude-opus-5 carried on (Anthropic's server-side fallback)."])
    }

    /// An `error` event mid-stream (overloaded) is waited out like a 529.
    func testAnOverloadedErrorMidStreamIsRetried() async throws {
        _ = serve([.init(status: 200, body: Self.events([
            ["type": "message_start", "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 5, "output_tokens": 0]]],
            ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]],
        ]))])
        do {
            _ = try await run(route("claude-opus-5-5"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .untilAvailable)
            XCTAssertTrue(error.localizedDescription.contains("overloaded"), error.localizedDescription)
        }
    }

    /// A stream that stops before message_stop was cut off (retried), not a short answer.
    func testAStreamCutOffIsRetried() async throws {
        _ = serve([.init(status: 200, body: Self.events([
            ["type": "message_start", "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 5]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hal"]],
        ]))])
        do {
            _ = try await run(route("claude-opus-5-5"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .untilAvailable)
        }
    }

    // MARK: Errors and adaptations

    /// Anthropic's real 401 for a wrong key, in plain words, not retried.
    func testAWrongKeyIsExplained() async throws {
        let real = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CgC5k4fa6y4tibGjzyYCN"}"#
        _ = serve([.init(status: 401, body: real, contentType: "application/json")])
        do {
            _ = try await run(route("claude-opus-5-5"))
            XCTFail("expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Anthropic didn't accept the API key (“invalid x-api-key”)"), text)
            XCTAssertTrue(text.contains("console.anthropic.com/settings/keys"), text)
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
        }
        let missing = #"{"type":"error","error":{"type":"authentication_error","message":"x-api-key header is required"},"request_id":"req_011CgC5k6AbZT9fGKeSdBLxt"}"#
        XCTAssertTrue(AnthropicErrors.error(status: 401, body: missing, model: "m").localizedDescription.contains("x-api-key header is required"))
    }

    func testStatusesMapToRetriesOrPlainWords() {
        func error(_ status: Int, _ type: String, _ message: String) -> LLMError {
            AnthropicErrors.error(status: status, body: #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#, model: "claude-opus-5-5")
        }
        XCTAssertEqual(RequestRetry.disposition(for: error(429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit")), .untilAvailable)
        XCTAssertEqual(RequestRetry.disposition(for: error(529, "overloaded_error", "Overloaded")), .untilAvailable)
        XCTAssertEqual(RequestRetry.disposition(for: error(500, "api_error", "Internal server error")), .limited(RequestRetry.serverErrorRetries))
        let notFound = error(404, "not_found_error", "model: claude-opus-9")
        XCTAssertEqual(RequestRetry.disposition(for: notFound), .fail)
        XCTAssertTrue(notFound.localizedDescription.contains("doesn't offer `claude-opus-5-5`"))
        XCTAssertTrue(error(402, "billing_error", "Your credit balance is too low").localizedDescription.contains("Billing"))
        guard case .overflow(let limit, _) = error(400, "invalid_request_error", "prompt is too long: 250123 tokens > 200000 maximum") else {
            return XCTFail("a long prompt is an overflow")
        }
        XCTAssertEqual(limit, 200_000)
    }

    /// A key the fallback beta isn't enabled for: once more without it, and one line saying so — asked once a run.
    func testAKeyWithoutTheFallbackBetaCarriesOnWithoutIt() async throws {
        let refusal = #"{"type":"error","error":{"type":"invalid_request_error","message":"Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header. Please consult our documentation at docs.anthropic.com or try again without the header."}}"#
        let seen = serve([.init(status: 400, body: refusal, contentType: "application/json"), .init(status: 200, body: Self.textReply("Hi."))])
        let notices = Notices()
        let result = try await run(route("claude-opus-5-5"), notices: notices)
        XCTAssertEqual(result.text, "Hi.")
        XCTAssertEqual(seen.all.count, 2)
        XCTAssertNotNil(seen.all[0].body["fallbacks"])
        XCTAssertNil(seen.all[1].body["fallbacks"])
        XCTAssertNil(seen.all[1].headers["anthropic-beta"])
        XCTAssertEqual(notices.all.count, 1)
        _ = try await run(route("claude-opus-5-5"))
        XCTAssertNil(seen.all[2].body["fallbacks"], "remembered for the run")
    }

    /// Replayed reasoning refused (an edited history): once more without it.
    func testARefusedSignatureIsRetriedWithoutReplay() async throws {
        let refusal = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation."}}"#
        let seen = serve([.init(status: 400, body: refusal, contentType: "application/json"), .init(status: 200, body: Self.textReply("Done."))])
        var assistant = LLMMessage.assistant("", calls: [ToolCall(id: "toolu_1", name: "read_file", arguments: "{}")])
        assistant.providerState = AnthropicMessages.statePrefix + #"[{"signature":"old","thinking":"t","type":"thinking"},{"id":"toolu_1","input":{},"name":"read_file","type":"tool_use"}]"#
        let result = try await run(route("claude-opus-5-5", thinking: .high),
                                   messages: [.user("go"), assistant, .toolResult(id: "toolu_1", name: "read_file", output: "x")],
                                   tools: [readFile])
        XCTAssertEqual(result.text, "Done.")
        let first = (seen.all[0].body["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        let second = (seen.all[1].body["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]]
        XCTAssertEqual(first?.first?["type"] as? String, "thinking")
        XCTAssertEqual(second?.first?["type"] as? String, "tool_use")
    }

    /// The key's models, every page.
    func testListingModelsReadsEveryPage() async throws {
        let seen = serve([
            .init(status: 200, body: #"{"data":[{"id":"claude-opus-5-5","max_input_tokens":1000000,"max_tokens":128000}],"has_more":true,"last_id":"claude-opus-5-5"}"#, contentType: "application/json"),
            .init(status: 200, body: #"{"data":[{"id":"claude-haiku-4-5"}],"has_more":false,"last_id":"claude-haiku-4-5"}"#, contentType: "application/json"),
        ])
        let ids = try await AnthropicClient(profile: route("claude-opus-5-5")).listModels()
        XCTAssertEqual(ids, ["claude-opus-5-5", "claude-haiku-4-5"])
        XCTAssertEqual(seen.all.map(\.path), ["/v1/models", "/v1/models"])
        XCTAssertEqual(seen.all[1].headers["x-api-key"], "sk-ant-api03-test")
    }

    /// The address may name only the host: "/v1" is added.
    func testABareHostGetsV1() {
        var profile = route("claude-opus-5-5")
        profile.baseURL = "https://api.anthropic.com/"
        XCTAssertEqual(AnthropicClient(profile: profile).base, "https://api.anthropic.com/v1")
    }

    /// The factory hands an Anthropic route to this client, and the Claude ids get their real windows.
    func testRoutingAndContextWindows() {
        XCTAssertTrue(ProviderClients.make(route("claude-opus-5-5")) is AnthropicClient
                      || ProviderClients.make(route("claude-opus-5-5")) is ShieldClient)
        XCTAssertEqual(FallbackContextWindow.limit(for: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(FallbackContextWindow.limit(for: "claude-haiku-4-5"), 200_000)
        XCTAssertTrue(AttachmentRoute.of(route("claude-opus-5-5")).documents)
    }
}
