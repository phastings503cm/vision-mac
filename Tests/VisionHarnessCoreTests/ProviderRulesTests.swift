import XCTest
@testable import VisionHarnessCore

/// What each model takes on the wire (Kimi, Z.ai, OpenAI), the safety net that learns from a server's 400, and
/// Z.ai's errors in plain words. Error bodies are the providers' own (recorded, or quoted from their docs).
final class ProviderRulesTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReasoningEffortCache.shared.reset()
        RequestAdaptationStore.shared.forget()
        RequestAdaptationStore.shared.fileURL = nil
    }

    override func tearDown() {
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        RequestAdaptationStore.shared.forget()
        super.tearDown()
    }

    // MARK: Fixtures

    private let moonshot = "https://api.moonshot.ai/v1"
    private let kimiCode = "https://api.kimi.com/coding/v1"
    private let zaiCoding = "https://api.z.ai/api/coding/paas/v4"
    private let zaiGeneral = "https://api.z.ai/api/paas/v4"

    private func route(_ base: String, _ model: String, temperature: Double? = nil, maxTokens: Int? = nil) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: "Route", baseURL: base, model: model,
                        temperature: temperature, maxOutputTokens: maxTokens)
    }

    private func body(_ profile: ProviderProfile, thinking: ThinkingLevel? = nil, messages: [LLMMessage] = [.user("hi")],
                      store: RequestAdaptationStore = .shared) throws -> [String: Any] {
        let request = LLMRequest(systemPrompt: "", messages: messages, tools: [], model: profile.model, thinking: thinking)
        let data = try OpenAIClient(profile: profile, adaptations: store).makeBody(request)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func thinking(_ b: [String: Any]) -> String? { (b["thinking"] as? [String: Any])?["type"] as? String }

    // MARK: Kimi

    /// Moonshot's K2.6 fixes the temperature (1.0 thinking, 0.6 not) and switches thinking with `thinking.type`;
    /// it takes no `reasoning_effort`.
    func testKimiK26GetsNoTemperatureAndAThinkingToggle() throws {
        let k26 = route(moonshot, "kimi-k2.6", temperature: 0.7)
        let off = try body(k26, thinking: .off)
        XCTAssertNil(off["temperature"], "the cause of the 400: 'invalid temperature: only 1 is allowed for this model'")
        XCTAssertEqual(thinking(off), "disabled")
        XCTAssertNil(off["reasoning_effort"])
        XCTAssertNil(off["chat_template_kwargs"])
        let on = try body(k26, thinking: .medium)
        XCTAssertEqual(thinking(on), "enabled")
        XCTAssertNil(on["reasoning_effort"])
        XCTAssertNil(try body(k26)["thinking"], "no level chosen: the server's default")
    }

    /// K2.7 Code always thinks: no thinking setting, no effort, no temperature — whatever the chat asks.
    func testKimiK27CodeIsSentNoThinkingSettingAtAll() throws {
        for level in ThinkingLevel.allCases {
            let b = try body(route(moonshot, "kimi-k2.7-code", temperature: 0.2), thinking: level)
            XCTAssertNil(b["thinking"], "\(level)")
            XCTAssertNil(b["reasoning_effort"], "\(level)")
            XCTAssertNil(b["temperature"], "\(level)")
        }
        let rules = ModelRequestRules.for(route(moonshot, "kimi-k2.7-code-highspeed"), model: "kimi-k2.7-code-highspeed")
        XCTAssertTrue(rules.thinkingLevels.isEmpty, "the picker offers nothing to choose")
        XCTAssertTrue(rules.alwaysThinks)
        XCTAssertFalse(rules.forcedToolChoice, "tool_choice: required is refused")
    }

    /// K3: effort low/high/max (default max), never off.
    func testKimiK3TakesLowHighMax() throws {
        let k3 = route(moonshot, "kimi-k3")
        let expected: [ThinkingLevel: String] = [.off: "low", .low: "low", .medium: "high", .high: "high", .max: "max"]
        for (level, word) in expected {
            let b = try body(k3, thinking: level)
            XCTAssertEqual(b["reasoning_effort"] as? String, word, "\(level)")
            XCTAssertNil(b["thinking"])
        }
        XCTAssertEqual(ModelRequestRules.for(k3, model: "kimi-k3").thinkingLevels, [.low, .high, .max])
    }

    /// Kimi Code: low/high/max, and "none" turns thinking off (served by K2.8 Preview without it).
    func testKimiCodeOffIsNone() throws {
        let kfc = route(kimiCode, "kimi-for-coding", temperature: 0.5)
        XCTAssertEqual(try body(kfc, thinking: .off)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try body(kfc, thinking: .max)["reasoning_effort"] as? String, "max")
        XCTAssertNil(try body(kfc, thinking: .off)["temperature"])
        XCTAssertEqual(ModelRequestRules.for(kfc, model: "k3").thinkingLevels, [.off, .low, .high, .max])
        XCTAssertEqual(KnownProvider.of(baseURL: "https://api.kimi.ai/coding/v1"), .kimiCode)
        XCTAssertEqual(KnownProvider.of(baseURL: "https://api.moonshot.cn/v1"), .moonshot)
    }

    func testKimiContextWindowsFromMoonshotsModelList() {
        XCTAssertEqual(FallbackContextWindow.limit(for: "kimi-k3"), 1_000_000)
        XCTAssertEqual(FallbackContextWindow.limit(for: "kimi-k2.7-code"), 262_144)
        XCTAssertEqual(FallbackContextWindow.limit(for: "kimi-k2.6"), 262_144)
        XCTAssertEqual(FallbackContextWindow.limit(for: "moonshotai/kimi-k2.5"), 262_144)
        var learned = RequestAdaptation()
        learned.apply(.drop("temperature"))
        learned.apply(.rename(from: "max_tokens", to: "max_completion_tokens"))
        XCTAssertEqual(learned.summary, "no temperature; max_completion_tokens instead of max_tokens")
    }

    /// The retired K2 previews and moonshot-v1 take a temperature (0…1) and no thinking setting.
    func testOlderMoonshotModelsKeepATemperatureInRange() throws {
        let b = try body(route(moonshot, "moonshot-v1-128k", temperature: 1.6), thinking: .high)
        XCTAssertEqual(b["temperature"] as? Double, 1.0)
        XCTAssertNil(b["reasoning_effort"])
        XCTAssertNil(b["thinking"])
    }

    /// Kimi's thinking models want each tool-calling assistant message to carry its reasoning.
    func testKimiReasoningGoesBackWithToolCalls() throws {
        let k26 = route(moonshot, "kimi-k2.6")
        var kept = LLMMessage.assistant("", calls: [ToolCall(id: "c1", name: "read_file", arguments: "{}")])
        kept.providerState = ReasoningEcho.state("I should read the file first.")
        let lost = LLMMessage.assistant("", calls: [ToolCall(id: "c2", name: "read_file", arguments: "{}")])
        let plain = LLMMessage.assistant("All done.")
        let b = try body(k26, messages: [.user("go"), kept, .toolResult(id: "c1", name: "read_file", output: "x"),
                                         lost, .toolResult(id: "c2", name: "read_file", output: "y"), plain, .user("thanks")])
        let assistants = (b["messages"] as! [[String: Any]]).filter { $0["role"] as? String == "assistant" }
        XCTAssertEqual(assistants[0]["reasoning_content"] as? String, "I should read the file first.")
        XCTAssertEqual(assistants[1]["reasoning_content"] as? String, ReasoningEcho.placeholder,
                       "a message rebuilt from text gets a stand-in, not a 400")
        XCTAssertNil(assistants[2]["reasoning_content"])
        // With thinking switched off there's no reasoning to stand in for.
        let off = try body(k26, thinking: .off, messages: [.user("go"), lost, .toolResult(id: "c2", name: "read_file", output: "y")])
        XCTAssertNil((off["messages"] as! [[String: Any]])[1]["reasoning_content"])
        // Other servers never see it.
        let other = try body(route("https://api.openai.com/v1", "gpt-4.1"), messages: [.user("go"), kept])
        XCTAssertNil((other["messages"] as! [[String: Any]])[1]["reasoning_content"])
    }

    // MARK: Z.ai

    /// GLM-5.3: always thinks (low/high/max), temperature 0…1, at most 131072 output tokens, plain-string content.
    func testGLM53OnZaiGetsWhatZaiTakes() throws {
        let glm = route(zaiCoding, "glm-5.3", temperature: 1.4, maxTokens: 200_000)
        let image = MessageAttachment(kind: .image, name: "shot.png", data: Data([0x89, 0x50]))
        let notes = MessageAttachment(kind: .file, name: "notes.md", data: Data("# Notes\nhello".utf8))
        let b = try body(glm, thinking: .off, messages: [.user("look", attachments: [image, notes])])
        XCTAssertEqual(b["reasoning_effort"] as? String, "low", "never off")
        XCTAssertNil(b["thinking"])
        XCTAssertEqual(b["temperature"] as? Double, 1.0)
        XCTAssertEqual(b["max_tokens"] as? Int, 131_072)
        XCTAssertNil(b["chat_template_kwargs"], "a hosted API never gets template kwargs")
        let content = (b["messages"] as! [[String: Any]])[0]["content"]
        let text = try XCTUnwrap(content as? String, "Z.ai's text models take a string, not parts")
        XCTAssertTrue(text.hasPrefix("look"))
        // The harness's attachment text (night/files): never a part the model can't take.
        XCTAssertTrue(text.contains("[Attached file: notes.md]\n# Notes\nhello"), text)
        // A picture nobody read goes as a line naming it (the app reads every picture first: OCR text, see
        // AttachmentWireTests), never as an image part.
        XCTAssertTrue(text.contains("[Attached file: shot.png"), text)
        XCTAssertFalse(text.contains("base64"), text)
        let rules = ModelRequestRules.for(glm, model: "glm-5.3")
        XCTAssertEqual(rules.thinkingLevels, [.low, .high, .max])
        XCTAssertEqual(rules.acceptsImages, false)
        XCTAssertFalse(rules.forcedToolChoice, "tool_choice: only auto")
    }

    /// The attachment wire (night/files) asks the model's rules whether it takes images: a GLM text model gets a
    /// picture's OCR text in its one string, the vision model gets the picture — and the chip says which.
    func testGLMTextModelsGetAPicturesTextAndTheVisionModelThePicture() throws {
        var photo = MessageAttachment(kind: .image, name: "page.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        photo.digest = AttachmentDigest(format: .image, lines: 1, bytes: 4, text: "INVOICE 4471", ocr: true)
        XCTAssertFalse(AttachmentRoute.openAI(route(zaiCoding, "glm-5.3")).vision)
        XCTAssertTrue(AttachmentRoute.openAI(route(zaiGeneral, "glm-5.3-flash")).vision)
        XCTAssertEqual(AttachmentWire.delivery(photo, route: .openAI(route(zaiCoding, "glm-5.3"))), .ocrText)
        let b = try body(route(zaiCoding, "glm-5.3"), messages: [.user("read it", attachments: [photo])])
        let text = try XCTUnwrap((b["messages"] as! [[String: Any]])[0]["content"] as? String)
        XCTAssertTrue(text.contains("[Image: page.png — this model can't take images; the text in it, read by OCR:]\nINVOICE 4471"), text)
    }

    func testOlderGLMsToggleAndGLM52SkipsWithNone() throws {
        XCTAssertEqual(thinking(try body(route(zaiGeneral, "glm-4.7"), thinking: .off)), "disabled")
        XCTAssertEqual(thinking(try body(route(zaiGeneral, "glm-5.1"), thinking: .high)), "enabled")
        XCTAssertEqual(ModelRequestRules.for(route(zaiGeneral, "glm-4.7"), model: "glm-4.7").label(.high), "On")
        XCTAssertEqual(try body(route(zaiGeneral, "glm-5.2"), thinking: .off)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(try body(route(zaiGeneral, "glm-5.2"), thinking: .low)["reasoning_effort"] as? String, "high")
        // The vision model takes parts.
        let flash = try body(route(zaiGeneral, "glm-5.3-flash"),
                             messages: [.user("see", attachments: [MessageAttachment(kind: .image, name: "a.png", data: Data([1]))])])
        XCTAssertTrue((flash["messages"] as! [[String: Any]])[0]["content"] is [Any])
    }

    // MARK: OpenAI

    func testOpenAIReasoningModelsWantMaxCompletionTokensAndNoTemperature() throws {
        let b = try body(route("https://api.openai.com/v1", "gpt-5.2", temperature: 0.3, maxTokens: 4000), thinking: .high)
        XCTAssertNil(b["temperature"])
        XCTAssertNil(b["max_tokens"])
        XCTAssertEqual(b["max_completion_tokens"] as? Int, 4000)
        XCTAssertEqual(b["reasoning_effort"] as? String, "high")
        let classic = try body(route("https://api.openai.com/v1", "gpt-4.1", temperature: 0.3, maxTokens: 4000))
        XCTAssertEqual(classic["temperature"] as? Double, 0.3)
        XCTAssertEqual(classic["max_tokens"] as? Int, 4000)
    }

    // MARK: Reading a 400

    private func change(_ body: String, sent: Set<String>, status: Int = 400) -> RequestChange? {
        ParameterRejection.change(status: status, body: body, sent: sent)
    }

    private let sentAll: Set<String> = ["model", "messages", "stream", "stream_options", "temperature", "max_tokens",
                                         "reasoning_effort", "thinking", "tools"]

    func testRefusalsThatNameAParameter() {
        // Moonshot (quoted in cline/cline#10544 and microsoft/vscode#321514).
        XCTAssertEqual(change(#"{"error":{"message":"invalid temperature: only 1 is allowed for this model","type":"invalid_request_error"}}"#,
                              sent: sentAll), .drop("temperature"))
        // OpenAI's reasoning models.
        XCTAssertEqual(change(#"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.","type":"invalid_request_error","param":"max_tokens","code":"unsupported_parameter"}}"#,
                              sent: sentAll), .rename(from: "max_tokens", to: "max_completion_tokens"))
        XCTAssertEqual(change(#"{"error":{"message":"Unsupported value: 'temperature' does not support 0.7 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#,
                              sent: sentAll), .drop("temperature"))
        // vLLM refusing a field it doesn't know.
        XCTAssertEqual(change(#"{"object":"error","message":"[{'type': 'extra_forbidden', 'loc': ('body', 'chat_template_kwargs'), 'msg': 'Extra inputs are not permitted', 'input': {'enable_thinking': False}}]","type":"BadRequestError","param":null,"code":400}"#,
                              sent: ["model", "messages", "chat_template_kwargs", "chat_template_kwargs.enable_thinking"]),
                       .drop("chat_template_kwargs"))
        // FastAPI-style detail list.
        XCTAssertEqual(change(#"{"detail":[{"loc":["body","stream_options"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#,
                              sent: sentAll, status: 422), .drop("stream_options"))
        // Z.ai 1214 names its field.
        XCTAssertEqual(change(#"{"error":{"code":"1214","message":"Parameter `max_tokens` is invalid. Please check the documentation."}}"#,
                              sent: sentAll), .drop("max_tokens"))
        // A model that can't stop thinking, refusing the toggle.
        XCTAssertEqual(change(#"{"error":{"message":"invalid thinking type: only enabled is allowed for this model","type":"invalid_request_error"}}"#,
                              sent: sentAll), .drop("thinking"))
        XCTAssertEqual(change(#"{"error":{"message":"reasoning_effort is not supported for this model","type":"invalid_request_error"}}"#,
                              sent: sentAll), .drop("reasoning_effort"))
    }

    func testKimiMissingReasoningAsksForTheEcho() {
        // Kimi Code's error reference.
        XCTAssertEqual(change(#"{"error":{"message":"thinking is enabled but reasoning_content is missing in assistant tool call message at index 2","type":"invalid_request_error"}}"#,
                              sent: sentAll), .echoReasoning)
    }

    func testAnUnnamedParameterRefusalFallsBackToTheBasics() {
        XCTAssertEqual(change(#"{"error":{"code":"1210","message":"Invalid API parameter, please check the documentation."}}"#,
                              sent: sentAll), .minimal)
        XCTAssertNil(change(#"{"error":{"code":"1210","message":"Invalid API parameter, please check the documentation."}}"#,
                            sent: ["model", "messages", "stream"]), "nothing optional to leave out")
    }

    func testRefusalsThatAreNotAboutParameters() {
        XCTAssertNil(change(#"{"error":{"code":"1211","message":"Unknown Model, please check the model code."}}"#, sent: sentAll))
        XCTAssertNil(change(#"{"error":{"message":"Invalid 'messages[1].content': string too long.","type":"invalid_request_error"}}"#, sent: sentAll))
        XCTAssertNil(change(#"{"error":{"message":"invalid temperature: only 1 is allowed for this model"}}"#, sent: sentAll, status: 500))
        XCTAssertNil(change(#"{"error":{"message":"invalid temperature: only 1 is allowed"}}"#, sent: ["model", "messages"]),
                     "a parameter that wasn't sent isn't the problem")
    }

    /// The same bodies Windows pins (night/integrate review finding 1): a refusal pointing at the messages, tools,
    /// model or stream is about what was in them — learning "drop messages" would strip them from every later request.
    func testARefusalAboutTheMessagesToolsOrModelIsNeverADrop() {
        let sent: Set<String> = ["model", "messages", "tools", "stream", "temperature"]
        XCTAssertNil(change(#"{"detail":[{"loc":["body","messages",1,"content"],"msg":"Field required","type":"missing"}]}"#, sent: sent, status: 422))
        XCTAssertNil(change(#"{"detail":[{"loc":["body","tools",0,"function","parameters"],"msg":"Input should be a valid dictionary","type":"dict_type"}]}"#, sent: sent, status: 422))
        XCTAssertNil(change(#"{"error":{"message":"Invalid value for 'content': expected a string, got null.","type":"invalid_request_error","param":"messages","code":null}}"#, sent: sent))
        XCTAssertNil(change(#"{"error":{"param":"messages"}}"#, sent: sent))
        XCTAssertNil(change(#"{"error":{"message":"The model `qwen9` does not exist","type":"invalid_request_error","param":"model","code":"model_not_found"}}"#, sent: sent))
        XCTAssertNil(change(#"{"error":{"param":"model"}}"#, sent: sent))
        XCTAssertNil(change(#"{"error":{"param":"stream","message":"stream is not supported"}}"#, sent: sent))
        // An optional parameter named the same way is still learned.
        XCTAssertEqual(change(#"{"detail":[{"loc":["body","temperature"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#, sent: sent, status: 422),
                       .drop("temperature"))
        XCTAssertTrue(RequestBody.learnable("chat_template_kwargs.enable_thinking"))
        XCTAssertFalse(RequestBody.learnable("messages"))
        XCTAssertFalse(RequestBody.learnable("tools"))
        XCTAssertFalse(RequestBody.learnable("some_new_field"))
    }

    func testTheStoreNeverLearnsOrKeepsADropOfWhatARequestNeeds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-adapt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("request-adaptations.json")
        // A file written by the earlier build, after a 422 about a message's content: messages and tools dropped.
        try Data(#"""
        {
          "http://spark:8000/v1|qwen": {"dropped": ["messages", "tools", "temperature"], "renamed": {"model": "x"},
                                        "minimal": false, "echoReasoning": false, "learnedAt": "2026-10-18T10:00:00Z"},
          "http://spark:8000/v1|other": {"dropped": ["model"], "renamed": {}, "minimal": false, "echoReasoning": false,
                                         "learnedAt": "2026-10-18T10:00:00Z"}
        }
        """#.utf8).write(to: file)
        let store = RequestAdaptationStore(fileURL: file)
        let kept = try XCTUnwrap(store.adaptation(for: "http://spark:8000/v1|qwen"))
        XCTAssertEqual(kept.dropped, ["temperature"])
        XCTAssertTrue(kept.renamed.isEmpty)
        XCTAssertNil(store.adaptation(for: "http://spark:8000/v1|other"), "nothing left of it")
        XCTAssertFalse(store.learn(.drop("messages"), for: "http://spark:8000/v1|qwen"))
        XCTAssertFalse(store.learn(.drop("tools"), for: "http://spark:8000/v1|qwen"))
        XCTAssertFalse(store.learn(.rename(from: "model", to: "model_id"), for: "http://spark:8000/v1|qwen"))
        var body: [String: Any] = ["model": "qwen", "messages": [Any](), "tools": [Any](), "temperature": 0.6]
        RequestBody.apply(kept, to: &body)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "tools"])
    }

    // MARK: The safety net, end to end

    private func stubbed(_ replies: [(Int, String)]) -> @Sendable () -> [[String: Any]] {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        final class Box: @unchecked Sendable { var bodies: [[String: Any]] = []; let lock = NSLock() }
        let box = Box()
        StubServer.reset { request in
            let data: Data = {
                if let b = request.httpBody { return b }
                guard let stream = request.httpBodyStream else { return Data() }
                stream.open(); defer { stream.close() }
                var out = Data(); var buf = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; out.append(buf, count: n) }
                return out
            }()
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let index: Int = box.lock.withLock { box.bodies.append(obj); return box.bodies.count - 1 }
            let reply = index < replies.count ? replies[index] : (200, StubServer.sse("ok"))
            return .init(status: reply.0, body: reply.1, contentType: reply.0 == 200 ? "text/event-stream" : "application/json")
        }
        return { box.lock.withLock { box.bodies } }
    }

    private func run(_ profile: ProviderProfile, store: RequestAdaptationStore, notices: NoticeBox) async throws -> String {
        let client = OpenAIClient(profile: profile, adaptations: store, onNotice: { notices.add($0) })
        var text = ""
        for try await event in client.stream(LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: profile.model)) {
            if case .text(let t) = event { text += t }
        }
        return text
    }

    final class NoticeBox: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }

    /// A model the table doesn't know refuses the temperature: one retry without it, one line in the chat, and the
    /// lesson is kept on disk — the next launch sends it right the first time.
    func testARefusedTemperatureIsDroppedRememberedAndAnnounced() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("adapt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = RequestAdaptationStore(fileURL: file)
        let bodies = stubbed([(400, #"{"error":{"message":"invalid temperature: only 1 is allowed for this model","type":"invalid_request_error"}}"#)])
        let profile = route(moonshot, "kimi-k9-preview", temperature: 0.7)
        let notices = NoticeBox()

        let reply = try await run(profile, store: store, notices: notices)
        XCTAssertEqual(reply, "ok")
        XCTAssertEqual(bodies().count, 2, "one retry")
        XCTAssertEqual(bodies()[0]["temperature"] as? Double, 0.7)
        XCTAssertNil(bodies()[1]["temperature"])
        XCTAssertEqual(notices.all, ["Moonshot (kimi-k9-preview) doesn't take `temperature` — Vision stopped sending it for this model and carried on."])

        // Remembered across a relaunch, per server and model.
        let reloaded = RequestAdaptationStore(fileURL: file)
        let key = RequestAdaptationStore.key(baseURL: moonshot, model: "kimi-k9-preview")
        XCTAssertEqual(reloaded.adaptation(for: key)?.dropped, ["temperature"])
        XCTAssertNil(reloaded.adaptation(for: RequestAdaptationStore.key(baseURL: moonshot, model: "kimi-k10")))
        _ = stubbed([])
        _ = try await run(profile, store: reloaded, notices: notices)
        XCTAssertEqual(notices.all.count, 1, "nothing new to say")
    }

    /// Two refused parameters in a row are each dropped once; a third refusal of something already dropped is
    /// reported, not looped on.
    func testEachParameterIsRetriedOnceAndThenTheRefusalSurfaces() async throws {
        let store = RequestAdaptationStore()
        let temperature = #"{"error":{"message":"invalid temperature: only 1 is allowed for this model","type":"invalid_request_error"}}"#
        let usage = #"{"error":{"message":"stream_options is not supported","type":"invalid_request_error"}}"#
        let profile = route("https://llm.example.com/v1", "mystery", temperature: 0.4)
        let bodies = stubbed([(400, temperature), (400, usage), (400, temperature)])
        let notices = NoticeBox()
        do {
            _ = try await run(profile, store: store, notices: notices)
            XCTFail("a refusal of a parameter already dropped surfaces")
        } catch LLMError.http(let status, _) {
            XCTAssertEqual(status, 400)
        }
        XCTAssertEqual(bodies().count, 3)
        XCTAssertEqual(notices.all.count, 2)
        XCTAssertNil(bodies()[2]["stream_options"])
        XCTAssertNil(bodies()[2]["temperature"])
    }

    /// Z.ai's "no balance" is HTTP 429 but not a rate limit: it fails at once with the fix, instead of retrying for
    /// ever. A real rate limit (1302) is still waited out.
    func testZaiNoBalanceFailsAtOnceAndRateLimitsAreStillRetried() async throws {
        _ = stubbed([(429, #"{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}"#)])
        do {
            _ = try await run(route(zaiGeneral, "glm-5.3"), store: RequestAdaptationStore(), notices: NoticeBox())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail)
            XCTAssertTrue(error.localizedDescription.contains("switch the endpoint to Coding Plan"), error.localizedDescription)
        }
        _ = stubbed([(429, #"{"error":{"code":"1302","message":"Rate limit reached for requests"}}"#)])
        do {
            _ = try await run(route(zaiCoding, "glm-5.3"), store: RequestAdaptationStore(), notices: NoticeBox())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .untilAvailable)
        }
    }

    func testZaiErrorsInPlainWords() {
        let expired = ZAIErrors.explain(status: 429, body: #"{"error":{"code":"1309","message":"Your GLM Coding Plan package has expired"}}"#,
                                        endpoint: .coding, model: "glm-5.3")
        XCTAssertEqual(expired?.permanent, true)
        XCTAssertTrue(expired?.message.contains("z.ai/subscribe") == true)
        let limit = ZAIErrors.explain(status: 429, body: #"{"error":{"code":"1308","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-10-19 03:00:00"}}"#,
                                      endpoint: .coding, model: "glm-5.3")
        XCTAssertEqual(limit?.message, "The Z.ai plan's usage limit is used up (1308). It resets at 2026-10-19 03:00:00. Wait for it, or switch this chat to another model.")
        let unknown = ZAIErrors.explain(status: 400, body: #"{"error":{"code":"1211","message":"Unknown Model, please check the model code."}}"#,
                                        endpoint: .general, model: "glm-5.4")
        XCTAssertEqual(unknown?.message, "Z.ai doesn't know the model `glm-5.4` (1211). Pick one of its models — glm-5.3 is the current one.")
        XCTAssertNil(ZAIErrors.explain(status: 429, body: #"{"error":{"code":"1305","message":"The service may be temporarily overloaded"}}"#,
                                       endpoint: .coding, model: "glm-5.3"), "overload is waited out")
        // The real body api.z.ai sends without a key (recorded 2026-10-18).
        XCTAssertEqual(ZAIErrors.explain(status: 401, body: #"{"error":{"code":"1001","message":"Authentication parameter not received in Header, unable to authenticate"}}"#,
                                         endpoint: .general, model: "glm-5.3")?.permanent, true)
        XCTAssertEqual(ZAIErrors.Endpoint.of(baseURL: "https://open.bigmodel.cn/api/coding/paas/v4/"), .chinaCoding)
        XCTAssertNil(ZAIErrors.Endpoint.of(baseURL: "https://api.openai.com/v1"))
    }

    // MARK: Testing a Z.ai key

    func testACodingPlanKeyOnTheGeneralEndpointIsRecognised() async {
        let noBalance = LLMError.rejected(status: 429, message: "x",
                                          body: #"{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}"#,
                                          permanent: true)
        let result = await ZAIDiagnosis.run(endpoint: .general, model: "glm-5.3") { endpoint in
            if endpoint != .coding { throw noBalance }
        }
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.worksOn, .coding)
        XCTAssertTrue(result.message.hasPrefix("This looks like a GLM Coding Plan key — switch the endpoint to Coding Plan."), result.message)
    }

    func testAChinaKeyOnTheInternationalEndpointIsRecognised() async {
        let refused = LLMError.http(401, #"{"error":{"code":"401","message":"token expired or incorrect"}}"#)
        let result = await ZAIDiagnosis.run(endpoint: .coding, model: "glm-5.3") { endpoint in
            if endpoint != .chinaCoding { throw refused }
        }
        XCTAssertEqual(result.worksOn, .chinaCoding)
        XCTAssertEqual(result.message, "This key is from open.bigmodel.cn — switch the endpoint to China — Coding Plan.")
    }

    func testAKeyThatWorksNowhereGetsTheFirstExplanation() async {
        let refused = LLMError.http(401, #"{"error":{"code":"401","message":"token expired or incorrect"}}"#)
        let result = await ZAIDiagnosis.run(endpoint: .coding, model: "glm-5.3") { _ in throw refused }
        XCTAssertNil(result.worksOn)
        XCTAssertTrue(result.message.hasPrefix("Z.ai didn't accept the key (401: token expired or incorrect)."), result.message)
        let ok = await ZAIDiagnosis.run(endpoint: .coding, model: "glm-5.3") { _ in }
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.message, "✔ The key works on Coding Plan with glm-5.3.")
        // A wrong model isn't a key problem: no other endpoint is tried.
        let tried = NoticeBox()
        let model = await ZAIDiagnosis.run(endpoint: .coding, model: "glm-9") { endpoint in
            tried.add(endpoint.rawValue)
            throw LLMError.http(400, #"{"error":{"code":"1211","message":"Unknown Model, please check the model code."}}"#)
        }
        XCTAssertEqual(tried.all, ["coding"])
        XCTAssertTrue(model.message.contains("1211"))
    }
}
