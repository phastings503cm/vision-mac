import XCTest
@testable import VisionHarnessCore

/// DeepSeek as a first-class provider: what each model takes on the wire (api-docs.deepseek.com, 2026-10-19), the
/// reasoning it wants back with tools, its errors in plain words (the 401 body is DeepSeek's own, recorded 2026-10-19
/// with a made-up key), and the plan guide's entry. Plus the Anthropic plan's key checks.
final class DeepSeekTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReasoningEffortCache.shared.reset()
        RequestAdaptationStore.shared.forget()
        RequestAdaptationStore.shared.fileURL = nil
        VisionRejections.shared.reset()
    }

    override func tearDown() {
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        RequestAdaptationStore.shared.forget()
        super.tearDown()
    }

    private func route(_ model: String, temperature: Double? = nil, maxTokens: Int? = nil) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: "DeepSeek", baseURL: "https://api.deepseek.com", apiKey: "sk-test",
                        model: model, temperature: temperature, maxOutputTokens: maxTokens)
    }

    private let tool = ToolSpec(name: "read_file", description: "Read a file", parameters: #"{"type":"object","properties":{}}"#)

    private func body(_ profile: ProviderProfile, thinking: ThinkingLevel? = nil, messages: [LLMMessage] = [.user("hi")],
                      tools: [ToolSpec] = []) throws -> [String: Any] {
        let request = LLMRequest(systemPrompt: "", messages: messages, tools: tools, model: profile.model, thinking: thinking)
        return try JSONSerialization.jsonObject(with: OpenAIClient(profile: profile).makeBody(request)) as! [String: Any]
    }

    // MARK: Rules

    /// reasoning_effort none / low / high / max (medium is high, as DeepSeek maps it); never a `thinking` toggle
    /// beside it, and no chat-template fields (a hosted API).
    func testThinkingLevelsBecomeDeepSeeksEffortWords() throws {
        let expected: [ThinkingLevel: String] = [.off: "none", .low: "low", .medium: "high", .high: "high", .max: "max"]
        for (level, word) in expected {
            let b = try body(route("deepseek-v4-pro"), thinking: level)
            XCTAssertEqual(b["reasoning_effort"] as? String, word, "\(level)")
            XCTAssertNil(b["thinking"])
            XCTAssertNil(b["chat_template_kwargs"])
        }
        XCTAssertNil(try body(route("deepseek-v4-pro"))["reasoning_effort"], "no level: DeepSeek's default (thinking, high)")
        let rules = ModelRequestRules.for(route("deepseek-flash"), model: "deepseek-flash")
        XCTAssertEqual(rules.provider, .deepseek)
        XCTAssertEqual(rules.thinkingLevels, [.off, .low, .high, .max])
        XCTAssertFalse(rules.forcedToolChoice, "tool_choice required / named is a 400 in thinking mode")
    }

    /// max_tokens at most 393216; temperature within 0…2.
    func testOutputAndTemperatureStayInDeepSeeksRanges() throws {
        let b = try body(route("deepseek-v4-pro", temperature: 3, maxTokens: 1_000_000))
        XCTAssertEqual(b["max_tokens"] as? Int, 393_216)
        XCTAssertEqual(b["temperature"] as? Double, 2)
        XCTAssertNotNil(b["stream_options"])
    }

    /// With tools, every assistant message carries its reasoning — the kept one, or the stand-in — while thinking is
    /// on; with thinking off none is needed; without tools only tool-call turns would.
    func testEveryAssistantMessageCarriesReasoningWhenToolsAreOffered() throws {
        var kept = LLMMessage.assistant("Earlier answer.")
        kept.providerState = ReasoningEcho.state("I thought about it.")
        let messages: [LLMMessage] = [.user("one"), kept, .user("two"), .assistant("A plain answer, rebuilt from text."), .user("three")]
        func assistants(_ b: [String: Any]) -> [[String: Any]] {
            (b["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "assistant" }
        }
        let on = assistants(try body(route("deepseek-v4-pro"), thinking: .high, messages: messages, tools: [tool]))
        XCTAssertEqual(on.map { $0["reasoning_content"] as? String }, ["I thought about it.", ReasoningEcho.placeholder])
        let off = assistants(try body(route("deepseek-v4-pro"), thinking: .off, messages: messages, tools: [tool]))
        XCTAssertNil(off[1]["reasoning_content"], "thinking off: no stand-in")
        let noTools = assistants(try body(route("deepseek-v4-pro"), thinking: .high, messages: messages))
        XCTAssertNil(noTools[1]["reasoning_content"])
    }

    /// deepseek-flash reads images; deepseek-v4-pro doesn't.
    func testOnlyFlashGetsPictures() {
        XCTAssertTrue(AttachmentRoute.openAI(route("deepseek-flash")).vision)
        XCTAssertFalse(AttachmentRoute.openAI(route("deepseek-v4-pro")).vision)
        XCTAssertEqual(FallbackContextWindow.limit(for: "deepseek-flash"), 1_048_576)
        XCTAssertEqual(FallbackContextWindow.limit(for: "deepseek-v4-pro"), 1_048_576)
    }

    // MARK: Errors

    func testDeepSeeksErrorsInPlainWords() {
        let real401 = #"{"error":{"message":"Authentication Fails, Your api key: ****hape is invalid (request_id: d7b13612-fb2b-4c86-9a7a-26eedb470143)","type":"authentication_error","param":null,"code":"invalid_request_error"}}"#
        let auth = DeepSeekErrors.explain(status: 401, body: real401, model: "deepseek-v4-pro")
        XCTAssertEqual(auth?.permanent, true)
        XCTAssertTrue(auth?.message.contains("platform.deepseek.com/api_keys") ?? false)
        let broke = DeepSeekErrors.explain(status: 402, body: #"{"error":{"message":"Insufficient Balance","type":"unknown_error","param":null,"code":"invalid_request_error"}}"#, model: "deepseek-flash")
        XCTAssertEqual(broke?.permanent, true)
        XCTAssertTrue(broke?.message.contains("platform.deepseek.com/top_up") ?? false)
        XCTAssertEqual(DeepSeekErrors.explain(status: 429, body: "{}", model: "m")?.permanent, false)
        XCTAssertEqual(DeepSeekErrors.explain(status: 503, body: "{}", model: "m")?.permanent, false)
        XCTAssertNil(DeepSeekErrors.explain(status: 500, body: "{}", model: "m"), "left to the generic retry")
    }

    /// End to end: a 402 surfaces at once in plain words (no retrying an empty balance).
    func testAnEmptyBalanceSurfacesAtOnce() async throws {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        StubServer.reset { _ in .init(status: 402, body: #"{"error":{"message":"Insufficient Balance","type":"unknown_error","param":null,"code":"invalid_request_error"}}"#,
                                      contentType: "application/json") }
        do {
            for try await _ in OpenAIClient(profile: route("deepseek-v4-pro")).stream(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: "deepseek-v4-pro")) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no balance left"), error.localizedDescription)
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
        }
    }

    /// Cache hits are read from the usage chunk; a reply cut short for lack of capacity is waited out.
    func testCacheHitsAndCapacityCutOffs() async throws {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        StubServer.reset { _ in .init(body: #"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{"content":"Hi."},"finish_reason":"stop"}]}"# + "\n\n"
            + #"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":3,"prompt_cache_hit_tokens":64,"prompt_cache_miss_tokens":36}}"# + "\n\n"
            + "data: [DONE]\n\n") }
        var usage: LLMUsage?
        var state: String?
        for try await event in OpenAIClient(profile: route("deepseek-v4-pro")).stream(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [tool], model: "deepseek-v4-pro")) {
            if case .done(_, _, let u, let s) = event { usage = u; state = s }
        }
        XCTAssertEqual(usage, LLMUsage(promptTokens: 100, completionTokens: 3, cachedTokens: 64))
        XCTAssertEqual(ReasoningEcho.reasoning(from: state), "hmm", "kept to send back")

        StubServer.reset { _ in .init(body: #"data: {"choices":[{"delta":{"content":"Hal"},"finish_reason":"insufficient_system_resource"}]}"# + "\n\ndata: [DONE]\n\n") }
        do {
            for try await _ in OpenAIClient(profile: route("deepseek-v4-pro")).stream(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: "deepseek-v4-pro")) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .untilAvailable)
        }
    }

    // MARK: The plan guide's entries

    func testThePlansAndTheirKeyChecks() throws {
        let deepseek = try XCTUnwrap(PlanCatalog.plan("deepseek"))
        XCTAssertEqual(deepseek.regions.first?.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(deepseek.recommended?.id, "deepseek-v4-pro")
        XCTAssertEqual(PlanCatalog.plan(for: route("deepseek-flash"))?.id, "deepseek")
        XCTAssertNil(PlanCatalog.keyProblem("sk-0123456789abcdef", plan: deepseek))
        XCTAssertNotNil(PlanCatalog.keyProblem("abc123", plan: deepseek))
        XCTAssertTrue(PlanCatalog.keyProblem("sk-ant-api03-x", plan: deepseek)?.contains("Anthropic key") ?? false)

        let anthropic = try XCTUnwrap(PlanCatalog.plan("anthropic"))
        XCTAssertEqual(anthropic.recommended?.id, "claude-opus-5-5")
        XCTAssertNil(PlanCatalog.keyProblem("sk-ant-api03-abcdef", plan: anthropic))
        XCTAssertTrue(PlanCatalog.keyProblem("sk-ant-oat01-abcdef", plan: anthropic)?.contains("subscription sign-in token") ?? false,
                      "a subscription's token is never used as an API key")
        XCTAssertTrue(PlanCatalog.keyProblem("sk-ant-admin01-x", plan: anthropic)?.contains("Admin key") ?? false)
        XCTAssertNotNil(PlanCatalog.keyProblem("sk-proj-123", plan: anthropic))
        XCTAssertEqual(PlanCatalog.models(for: anthropic, listed: ["claude-haiku-5-5", "claude-opus-5-5", "not-claude"]).map(\.id),
                       ["claude-opus-5-5", "claude-haiku-5-5"])

        let region = anthropic.regions[0]
        let real401 = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CgC5k4fa6y4tibGjzyYCN"}"#
        XCTAssertTrue(PlanCatalog.explain(status: 401, body: real401, plan: anthropic, region: region).contains("sk-ant-"))
        XCTAssertTrue(PlanCatalog.explain(status: 402, body: "{}", plan: deepseek, region: deepseek.regions[0]).contains("top_up"))
    }
}
