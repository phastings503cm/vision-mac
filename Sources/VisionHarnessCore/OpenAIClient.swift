import Foundation

// MARK: - OpenAI-compatible streaming client
//
// Talks to any server that speaks the OpenAI chat-completions API
// (OpenAI, OpenRouter, Ollama `/v1`, LM Studio, vLLM/SGLang on a DGX Spark,
// llama.cpp server, ...). The engine stays provider-agnostic through the
// `LLMClient` protocol; this is the only real-network implementation.
//
// Two tool-call shapes are understood:
//   1. native `tool_calls` deltas (OpenAI, vLLM, OpenRouter, LM Studio), and
//   2. the Qwen/DeepSeek XML convention emitted inside plain text, for
//      backends that lack function-calling (see `XMLToolCalls`).

public struct OpenAIClient: LLMClient {
    public let profile: ProviderProfile
    private let session: URLSession
    /// The session's certificate handling: the route's pin, and which certificate each host showed.
    private let trust: PinningDelegate
    /// What servers refused before, per server and model (see `RequestAdaptations`).
    let adaptations: RequestAdaptationStore
    /// One line for the chat when the client adapted to a refusal ("… doesn't take `temperature` …").
    let onNotice: (@Sendable (String) -> Void)?

    public init(profile: ProviderProfile, session: URLSession = .shared,
                adaptations: RequestAdaptationStore = .shared, onNotice: (@Sendable (String) -> Void)? = nil) {
        self.profile = profile
        self.adaptations = adaptations
        self.onNotice = onNotice
        var cfg = URLSessionConfiguration.default
        // Idle timeout between bytes. Generous: a local server prefilling a
        // few hundred thousand tokens sends nothing until the first token, and
        // a timeout here only means a retry (see RequestRetry) that starts the
        // prefill over.
        cfg.timeoutIntervalForRequest = Self.idleTimeout
        // A whole streamed reply may legitimately run for hours on a slow box.
        cfg.timeoutIntervalForResource = 24 * 3_600
        cfg.waitsForConnectivity = true
        if let stubs = Self.protocolClassesForTesting {
            cfg.protocolClasses = stubs + (cfg.protocolClasses ?? [])
            cfg.waitsForConnectivity = false
        }
        (self.session, self.trust) = Self.sharedSession(cfg, pinned: profile.pinnedCertificate)
    }

    /// Seconds without a byte before a request times out (and is retried).
    public static let idleTimeout: TimeInterval = 600

    /// Test hook: URLProtocol stubs every new client's session routes through.
    nonisolated(unsafe) static var protocolClassesForTesting: [AnyClass]?

    /// Clients are made per request and per retry; they share one session
    /// per pinned certificate (all use the same settings) instead of leaking
    /// one URLSession each — a multi-day outage retries thousands of times.
    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: (URLSession, PinningDelegate)] = [:]
    private static func sharedSession(_ cfg: URLSessionConfiguration, pinned: String?) -> (URLSession, PinningDelegate) {
        let pin = CertificatePin.normalized(pinned) ?? ""
        let key = (cfg.protocolClasses ?? []).map { NSStringFromClass($0) }.joined(separator: ",") + "|" + pin
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let cached = sessions[key] { return cached }
        let delegate = PinningDelegate(pinned: pin.isEmpty ? nil : pin)
        let made = (URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil), delegate)
        sessions[key] = made
        return made
    }

    /// How many sessions exist (one per pin), for tests.
    static var sessionCount: Int { sessionLock.withLock { sessions.count } }

    /// A certificate the system doesn't trust, and that isn't this route's pin, in plain words: it fails at
    /// once (retrying can't fix it) and says which certificate it was, so the user can compare it.
    private func certificateError(_ error: Error, url: URL) -> Error {
        Self.certificateError(error, host: url.host, trust: trust)
    }

    /// Only a host whose certificate was turned down counts: a TLS connection that failed for any other reason
    /// (a dropped network mid-handshake also reads -1200) stays an ordinary error and is retried.
    static func certificateError(_ error: Error, host: String?, trust: PinningDelegate) -> Error {
        guard let failure = error as? URLError, PinningDelegate.certificateFailures.contains(failure.code),
              trust.refused(host: host), let seen = trust.fingerprint(host: host) else { return error }
        return LLMError.rejected(status: untrustedCertificateStatus,
                                 message: "The server's certificate isn't trusted (SHA-256 \(seen)).",
                                 body: "certificate not trusted", permanent: true)
    }

    /// The status an untrusted certificate is reported with (nginx's "SSL certificate error").
    public static let untrustedCertificateStatus = 495

    // MARK: LLMClient

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await client.runTurn(request, onText: { delta in
                        continuation.yield(.text(delta))
                    }, onReasoning: { delta in
                        continuation.yield(.reasoning(delta))
                    })
                    continuation.yield(.done(calls: result.calls,
                                             finish: result.finish,
                                             usage: result.usage,
                                             providerState: result.providerState))
                    continuation.finish()
                } catch let e as URLError where e.code == .cancelled {
                    // Our Stop, or the system dropping the request (which is
                    // worth retrying, not a reason to halt a queue).
                    continuation.finish(throwing: Task.isCancelled
                        ? CancellationError()
                        : LLMError.connection("the request was cancelled by the system"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        guard let url = URL(string: profile.endpoint(path: "models")) else {
            throw LLMError.unsupported("bad base URL: \(profile.baseURL)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        applyHeaders(&req)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw certificateError(error, url: url)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            throw LLMError.sse("unexpected /models payload")
        }
        return arr.compactMap { $0["id"] as? String }
    }

    /// Probe the server for the active model's metadata (context window, the
    /// id it really serves, etc.).
    ///
    /// `contextWindow` is `nil` when no live source answered — deliberately:
    /// the caller applies the static fallback tables fresh each time, so a
    /// transient miss never locks a guessed window in as "learned".
    ///
    /// Sources, in order:
    ///  1. `GET /v1/models` — vLLM and SGLang both report `max_model_len` here
    ///     (1000000 for the Spark's YaRN 1M serve, 524288 for Flash at 512K).
    ///     If the configured id isn't listed but the server serves exactly one
    ///     model, that one is used (and reported as `id`): a box whose model
    ///     was swapped keeps working instead of 404ing.
    ///  2. SGLang's `/get_model_info` / `/get_server_info` (`context_len` /
    ///     `context_length`), at `/v1/…` and at the server root.
    public func modelInfo(_ model: String? = nil) async -> ModelInfo? {
        let id = model?.isEmpty == false ? model! : profile.model
        var limit: Int? = nil
        var maxOut: Int? = nil
        var resolved = id
        var served: [String] = []

        if let url = URL(string: profile.endpoint(path: "models")) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            applyHeaders(&req)
            if let (data, response) = try? await session.data(for: req),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] {
                served = arr.compactMap { $0["id"] as? String }
                var hit = arr.first { ($0["id"] as? String) == id }
                    ?? arr.first { Self.matchesModel(($0["id"] as? String) ?? "", id) }
                if hit == nil, arr.count == 1 { hit = arr[0] }
                if let hit {
                    resolved = (hit["id"] as? String) ?? id
                    limit = Self.contextWindow(from: hit)
                    maxOut = hit["max_tokens"] as? Int
                }
            }
        }
        if limit == nil { limit = await sglangContextLength() }
        return ModelInfo(id: resolved, contextWindow: limit, maxTokens: maxOut, servedModels: served)
    }

    /// SGLang-specific metadata routes. They live at the server root, but the
    /// base URL usually ends in `/v1` (and behind a proxy the root may belong
    /// to something else entirely, which answers HTML — ignored), so try both.
    private func sglangContextLength() async -> Int? {
        let root = Self.strippingV1(profile.baseURL)
        let candidates: [String] = [
            profile.endpoint(path: "get_model_info"), root + "/get_model_info",
            profile.endpoint(path: "get_server_info"), root + "/get_server_info",
        ]
        for url in candidates.compactMap(URL.init) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            applyHeaders(&req)
            guard let (data, response) = try? await session.data(for: req),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let v = obj["context_len"] as? Int, v > 0 { return v }
            if let v = obj["context_length"] as? Int, v > 0 { return v }
        }
        return nil
    }

    /// A base URL with a trailing "/v1" removed, so we can hit root-level SGLang
    /// routes even when the provider was configured with the OpenAI path.
    static func strippingV1(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }

    /// Match the active model name against a `/models` entry id, tolerating the
    /// common shapes: exact, "vendor/model" vs "model", and Ollama tags.
    static func matchesModel(_ entryID: String, _ requested: String) -> Bool {
        if entryID == requested { return true }
        let base = requested.components(separatedBy: "/").last ?? requested
        let entryBase = entryID.components(separatedBy: "/").last ?? entryID
        return entryID == base || entryBase == base
    }

    /// Parse the real context limit out of an overflow error body, e.g. SGLang's
    /// "This model's maximum context length is 262144 tokens; however, you
    /// requested 270000 tokens". Returns nil when the body carries no limit.
    static func overflowLimit(in body: String) -> Int? {
        let patterns = [
            // SGLang: "The input (270000 tokens) is longer than the model's context length (262144 tokens)."
            "context length \\((\\d+) tokens\\)",
            "maximum context length of (\\d+)",
            "context length of (\\d+)",
            "maximum context length is (\\d+)",
            "context length is (\\d+)",
            "exceed the maximum context length of (\\d+)",
            "max context length of (\\d+)",
            "maximum context tokens: (\\d+)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(body.startIndex..., in: body)
            if let m = regex.firstMatch(in: body, options: [], range: range),
               let r = Range(m.range(at: 1), in: body),
               let n = Int(body[r]), n > 0 {
                return n
            }
        }
        return nil
    }

    /// Pull a context-window figure out of the assorted field names servers use.
    static func contextWindow(from entry: [String: Any]) -> Int? {
        if let v = entry["context"] as? Int, v > 0 { return v }                 // Ollama
        if let v = entry["context_length"] as? Int, v > 0 { return v }          // some vLLM
        if let v = entry["max_context_length"] as? Int, v > 0 { return v }      // LM Studio
        if let v = entry["context_window"] as? Int, v > 0 { return v }          // OpenRouter
        if let v = entry["context_len"] as? Int, v > 0 { return v }             // SGLang (echoed on /models)
        if let v = entry["max_context_len"] as? Int, v > 0 { return v }         // SGLang
        if let v = entry["max_model_len"] as? Int, v > 0 { return v }           // vLLM / SGLang / llama.cpp
        // Not `max_total_tokens`: that is SGLang's KV-pool size, not a window.
        return nil
    }

    // MARK: One streaming turn

    struct TurnResult: Sendable {
        let text: String
        let calls: [ToolCall]
        let finish: String?
        let usage: LLMUsage?
        /// The reasoning to send back with this message, for a model that wants it (see `ReasoningEcho`).
        var providerState: String? = nil
    }

    /// How many refused parameters one request adapts to before the refusal is reported.
    static let maxAdaptations = 3

    private func runTurn(_ request: LLMRequest,
                         onText: @escaping @Sendable (String) -> Void,
                         onReasoning: @escaping @Sendable (String) -> Void = { _ in },
                         isRetry: Bool = false,
                         adapted: Int = 0) async throws -> TurnResult {
        guard let url = URL(string: profile.endpoint(path: "chat/completions")) else {
            throw LLMError.unsupported("bad base URL: \(profile.baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(&req)
        let bodyObject = makeBodyObject(request)
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys])

        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw certificateError(error, url: url)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errData = Data()
            for try await chunk in bytes {
                errData.append(chunk)
                if errData.count > 8_000 { break }
            }
            let body = String(decoding: errData, as: UTF8.self)
            // A chat template that rejects our effort word ("Unexpected
            // reasoning effort high. Supported types are xhigh (default),
            // medium, and low.") — learn the nearest accepted word and retry.
            if !isRetry, http.statusCode == 400,
               let requested = effortWord(for: request),
               let fix = Self.effortCorrection(requested: requested, errorBody: body) {
                ReasoningEffortCache.shared.learn(route: effortRoute(request), requested: requested, accepted: fix)
                return try await runTurn(request, onText: onText, onReasoning: onReasoning, isRetry: true)
            }
            // A model that takes no images, answering one ("image input is not supported", "requires a multimodal
            // processor"): remember it for this route and send the picture's OCR text instead.
            if !isRetry, [400, 422, 500].contains(http.statusCode), VisionRejections.saysNoImages(body),
               carriesImages(request) {
                VisionRejections.shared.learn(VisionRejections.key(profile, model: requestModel(request)))
                return try await runTurn(request, onText: onText, onReasoning: onReasoning, isRetry: true)
            }
            // SGLang / vLLM report a context-overflow 400 as
            // "This model's maximum context length is N tokens; however, you requested M ...".
            if let limit = Self.overflowLimit(in: body) {
                throw LLMError.overflow(limit: limit, detail: body)
            }
            // A parameter this server or model refuses ("invalid temperature: only 1 is allowed for this model"):
            // leave it out from now on, say so in one line, and try again — once per parameter.
            let key = adaptationKey(request)
            if adapted < Self.maxAdaptations,
               let change = ParameterRejection.change(status: http.statusCode, body: body, sent: RequestBody.keys(bodyObject)),
               !(adaptations.adaptation(for: key)?.contains(change) ?? false) {
                adaptations.learn(change, for: key)
                let rules = ModelRequestRules.for(profile, model: requestModel(request))
                let who = rules.provider == .other ? (profile.name.isEmpty ? "The model server" : profile.name) : rules.provider.label
                onNotice?(ParameterRejection.notice(change, provider: who, model: requestModel(request)))
                return try await runTurn(request, onText: onText, onReasoning: onReasoning, isRetry: isRetry,
                                         adapted: adapted + 1)
            }
            // A proxy in front of the model (nginx's client_max_body_size)
            // refusing the body: the conversation must shrink, like an overflow.
            if http.statusCode == 413 {
                throw LLMError.overflow(limit: 0, detail: "request too large for the server (HTTP 413)")
            }
            // Z.ai's prompt-too-long business code.
            if ParameterRejection.businessCode(in: body) == "1261", KnownProvider.of(profile) == .zai {
                throw LLMError.overflow(limit: 0, detail: "Z.ai: prompt too long (1261)")
            }
            // A provider error that means something specific (Z.ai's "no balance" 429 is not a rate limit).
            if let explained = providerExplanation(status: http.statusCode, body: body, model: requestModel(request)) {
                throw LLMError.rejected(status: http.statusCode, message: explained.message, body: body,
                                        permanent: explained.permanent)
            }
            throw LLMError.http(http.statusCode, body)
        }

        var stream = StreamState()

        // Assemble complete lines from raw bytes so UTF-8 sequences that
        // span chunk boundaries never break.
        var raw = Data()
        for try await byte in bytes {
            raw.append(byte)
            guard byte == 0x0A else { continue }
            let line = String(decoding: raw.dropLast(), as: UTF8.self) // strip the newline
            raw.removeAll(keepingCapacity: true)
            try parseLine(line, into: &stream, onText: onText, onReasoning: onReasoning)
        }
        // A server may omit the final newline.
        if !raw.isEmpty {
            try parseLine(String(decoding: raw, as: UTF8.self), into: &stream,
                          onText: onText, onReasoning: onReasoning)
        }

        // Not SSE at all: some servers ignore `stream: true` and answer with
        // one JSON completion (or a JSON error).
        if !stream.sawData, !stream.otherBody.isEmpty {
            try parsePlainBody(stream.otherBody, into: &stream, status: (response as? HTTPURLResponse)?.statusCode,
                               onText: onText)
            if stream.finish == nil {
                // Something answered, but not a model (a proxy's HTML page,
                // a wrong base URL): retrying can't fix that.
                let snippet = stream.otherBody.replacingOccurrences(of: "\n", with: " ").prefix(200)
                throw LLMError.http((response as? HTTPURLResponse)?.statusCode ?? 200,
                                    "unrecognised reply (is the base URL an OpenAI-compatible /v1?): \(snippet)")
            }
        }
        if stream.finish == "error" {
            throw LLMError.http(500, "the server ended the reply with an error")
        }
        // Every OpenAI-compatible server ends a reply with a finish_reason
        // and/or `data: [DONE]`. Neither means the connection closed mid-reply
        // (server restarted, proxy dropped it) — a failure worth retrying, not
        // a short answer.
        if !stream.sawDone && stream.finish == nil {
            throw LLMError.sse(stream.sawData ? "the reply was cut off before it finished"
                                              : "the server closed the connection without replying")
        }

        var calls = stream.pending
            .sorted { $0.key < $1.key }
            .map { entry -> ToolCall in
                ToolCall(id: entry.value.id.isEmpty ? "call-\(entry.key)" : entry.value.id,
                         name: entry.value.name,
                         arguments: entry.value.args.isEmpty ? "{}" : entry.value.args)
            }

        // XML tool-call fallback: some backends (Qwen on Ollama without
        // function-calling, older vLLM) emit tool blocks in the text instead.
        if calls.isEmpty, XMLToolCalls.containsBlock(stream.text) {
            let parsed = XMLToolCalls.parse(stream.text)
            for (i, p) in parsed.enumerated() {
                calls.append(ToolCall(id: "xml-\(i)", name: p.name,
                                      arguments: p.argumentsJSON.raw))
            }
        }

        var result = TurnResult(text: stream.text, calls: calls, finish: stream.finish, usage: stream.usage)
        if echoesReasoning(request), !stream.reasoning.isEmpty {
            result.providerState = ReasoningEcho.state(stream.reasoning)
        }
        return result
    }

    /// The key lessons are kept under for this request's server and model.
    func adaptationKey(_ request: LLMRequest) -> String {
        RequestAdaptationStore.key(baseURL: profile.baseURL, model: requestModel(request))
    }

    /// Whether this request's model wants its reasoning back on assistant tool-call messages.
    func echoesReasoning(_ request: LLMRequest) -> Bool {
        ModelRequestRules.for(profile, model: requestModel(request)).echoReasoning
            || (adaptations.adaptation(for: adaptationKey(request))?.echoReasoning ?? false)
    }

    /// A provider's error in plain words, when Vision knows what it means.
    func providerExplanation(status: Int, body: String, model: String) -> ProviderErrorExplanation? {
        let provider = KnownProvider.of(profile)
        switch provider {
        case .zai:
            return ZAIErrors.explain(status: status, body: body, endpoint: ZAIErrors.Endpoint.of(baseURL: profile.baseURL),
                                     model: model)
        case .moonshot, .kimiCode:
            return KimiErrors.explain(status: status, body: body, provider: provider, model: model)
        default:
            return nil
        }
    }

    /// Everything one streamed reply accumulates.
    struct StreamState {
        var text = ""
        /// The reasoning that streamed (kept only for models that want it back).
        var reasoning = ""
        var usage: LLMUsage?
        var finish: String?
        var pending: [Int: (id: String, name: String, args: String)] = [:]
        /// Saw `data: [DONE]`.
        var sawDone = false
        /// Saw at least one `data:` line.
        var sawData = false
        /// Non-SSE lines (capped), for servers that answer in plain JSON.
        var otherBody = ""
    }

    func parseLine(_ rawLine: String,
                   into state: inout StreamState,
                   onText: @escaping @Sendable (String) -> Void,
                   onReasoning: @escaping @Sendable (String) -> Void) throws {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        // SSE: only "data:" lines matter (ignore event:, id:, keepalives).
        guard line.hasPrefix("data:") else {
            if !state.sawData, !line.isEmpty, !line.hasPrefix(":"), state.otherBody.utf8.count < 2_000_000 {
                state.otherBody += line + "\n"
            }
            return
        }
        state.sawData = true
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            state.sawDone = true
            return
        }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return // ignore undecodable lines (keepalive pings etc.)
        }

        // An error reported mid-stream (vLLM: {"object":"error",…}; others:
        // {"error":{…}}) — surface it instead of ending with an empty reply.
        if obj["error"] != nil || obj["choices"] == nil, let (code, message) = Self.streamError(in: obj) {
            if let limit = Self.overflowLimit(in: message) {
                throw LLMError.overflow(limit: limit, detail: message)
            }
            throw LLMError.http(code, message)
        }

        if let u = obj["usage"] as? [String: Any],
           let p = u["prompt_tokens"] as? Int,
           let c = u["completion_tokens"] as? Int, p > 0 || c > 0 {
            state.usage = LLMUsage(promptTokens: p, completionTokens: c)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        if let delta = first["delta"] as? [String: Any] {
            if let r = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !r.isEmpty {
                if state.reasoning.utf8.count < 400_000 { state.reasoning += r }
                onReasoning(r)
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                state.text += content
                onText(content)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let index = (tc["index"] as? Int) ?? 0
                    var entry = state.pending[index] ?? (id: "", name: "", args: "")
                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { entry.name = name }
                        if let args = fn["arguments"] as? String { entry.args += args }
                    }
                    state.pending[index] = entry
                }
            }
        }
        if let fr = first["finish_reason"] as? String { state.finish = fr }
    }

    /// A plain (non-streamed) JSON reply: a completion, or an error.
    func parsePlainBody(_ body: String, into state: inout StreamState, status: Int?,
                        onText: @Sendable (String) -> Void) throws {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["choices"] == nil, let (code, message) = Self.streamError(in: obj) {
            if let limit = Self.overflowLimit(in: message) { throw LLMError.overflow(limit: limit, detail: message) }
            throw LLMError.http(code == 500 ? (status ?? 500) : code, message)
        }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else { return }
        if let content = message["content"] as? String, !content.isEmpty {
            state.text += content
            onText(content)
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (i, tc) in calls.enumerated() {
                let fn = tc["function"] as? [String: Any]
                state.pending[i] = (id: (tc["id"] as? String) ?? "",
                                    name: (fn?["name"] as? String) ?? "",
                                    args: (fn?["arguments"] as? String) ?? "")
            }
        }
        state.finish = (first["finish_reason"] as? String) ?? "stop"
        if let u = obj["usage"] as? [String: Any],
           let p = u["prompt_tokens"] as? Int, let c = u["completion_tokens"] as? Int {
            state.usage = LLMUsage(promptTokens: p, completionTokens: c)
        }
    }

    /// The status code and message of an error object, if `obj` is one.
    static func streamError(in obj: [String: Any]) -> (code: Int, message: String)? {
        func code(_ any: Any?) -> Int? {
            if let n = any as? Int { return n }
            if let s = any as? String { return Int(s) }
            return nil
        }
        if let err = obj["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? "\(err)"
            return (code(err["code"]) ?? code(err["status"]) ?? 500, message)
        }
        if let err = obj["error"] as? String {
            return (code(obj["code"]) ?? code(obj["status"]) ?? 500, err)
        }
        if (obj["object"] as? String) == "error" {
            return (code(obj["code"]) ?? 500, (obj["message"] as? String) ?? "server error")
        }
        return nil
    }

    // MARK: Request body

    /// Inserted when compaction has cut the user's own turn out of a long tool run.
    /// Qwen chat templates refuse a request that has no user message.
    static let noUserTurnNote = "(Earlier work in this conversation was summarised above. Carry on with the task.)"

    /// A tool call's arguments as the wire wants them: a JSON object. Empty or broken
    /// text (a call the model cut off or mangled) becomes `{}`. Servers that hand the
    /// arguments to a chat template as a parsed object (vLLM) fail the whole request
    /// on anything else, and would keep failing for the rest of the conversation.
    static func safeArguments(_ arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = JSONValue(parsing: trimmed), parsed.object != nil else { return "{}" }
        return arguments
    }

    func makeBody(_ request: LLMRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: makeBodyObject(request), options: [.sortedKeys])
    }

    /// The request body: the messages, then only the parameters this model takes (`ModelRequestRules`), minus
    /// what the server refused before (`RequestAdaptationStore`).
    func makeBodyObject(_ request: LLMRequest) -> [String: Any] {
        let rules = ModelRequestRules.for(profile, model: requestModel(request))
        let learned = adaptations.adaptation(for: adaptationKey(request))
        let echo = rules.echoReasoning || (learned?.echoReasoning ?? false)
        // A stand-in is only needed while the model thinks (K2.6 with thinking switched off wants none).
        let thinkingOff: Bool = {
            if case .toggle = rules.thinking { return thinkingLevel(for: request) == .off }
            return false
        }()
        var messages: [[String: Any]] = []
        // Some OpenAI-compatible servers (SGLang on the DGX Spark, notably)
        // reject any request with more than one system message, or with one
        // anywhere but index 0 — e.g. after compaction inserts a "[Earlier
        // conversation, compacted]" note into the transcript as `.system`.
        // Collect every system-role message (the engine's own prompt plus
        // any the transcript carries) and merge them into a single leading
        // message so the wire request always has at most one, always first.
        var systemParts: [String] = []
        if !request.systemPrompt.isEmpty { systemParts.append(request.systemPrompt) }
        for m in request.messages {
            switch m.role {
            case .system:
                if let c = m.content, !c.isEmpty { systemParts.append(c) }
            case .user:
                // A text-only model (Z.ai's GLM text models) gets no image parts from `attachmentRoute`, so its
                // content is always one plain string.
                messages.append(["role": "user", "content": userContent(for: m, request: request)])
            case .assistant:
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = m.content ?? ""
                if let calls = m.toolCalls, !calls.isEmpty {
                    msg["tool_calls"] = calls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function",
                         "function": ["name": c.name, "arguments": Self.safeArguments(c.arguments.raw)]]
                    }
                }
                // Kimi (thinking): an assistant message that called tools must carry its reasoning. One rebuilt
                // from text (a relaunch, compaction) no longer has it: a short stand-in keeps the request valid.
                if echo {
                    if let reasoning = ReasoningEcho.reasoning(from: m.providerState) {
                        msg["reasoning_content"] = reasoning
                    } else if m.toolCalls?.isEmpty == false, !thinkingOff {
                        msg["reasoning_content"] = ReasoningEcho.placeholder
                    }
                }
                messages.append(msg)
            case .tool:
                messages.append(["role": "tool",
                                 "tool_call_id": m.toolCallID ?? "",
                                 "content": m.content ?? ""])
            }
        }
        // Chat templates that look for the user's question (Qwen's, among others) refuse a
        // request that has none — and that is what a long run looks like after compaction
        // cuts inside it: the summary, then assistant and tool turns.
        if !messages.isEmpty && !messages.contains(where: { ($0["role"] as? String) == "user" }) {
            messages.insert(["role": "user", "content": Self.noUserTurnNote], at: 0)
        }
        if !systemParts.isEmpty {
            messages.insert(["role": "system", "content": systemParts.joined(separator: "\n\n")], at: 0)
        }

        var body: [String: Any] = [
            "model": request.model.isEmpty ? profile.model : request.model,
            "messages": messages,
            "stream": true,
        ]
        // `include_usage` is an OpenAI/OpenRouter/vLLM extension; Ollama and
        // some older servers 400 on unknown fields, so only send it for
        // OpenAI-family endpoints.
        if profile.kind == .openAI || profile.kind == .openRouter || profile.kind == .openAICompat {
            body["stream_options"] = ["include_usage": true]
        }
        if rules.sendsTemperature, var t = request.temperature ?? profile.temperature {
            if let range = rules.temperatureRange { t = min(max(t, range.lowerBound), range.upperBound) }
            body["temperature"] = t
        }
        if var mt = request.maxTokens ?? profile.maxOutputTokens {
            if let cap = rules.maxOutputTokens { mt = min(mt, cap) }
            body[rules.maxTokensField] = mt
        }
        applyThinking(request, rules: rules, to: &body)
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { spec -> [String: Any] in
                // SGLang (Pydantic) rejects a bare "{}" string here — it must be
                // a real schema object, even for parameterless tools.
                var params: Any = ["type": "object", "properties": [String: Any]()]
                if let d = spec.parameters.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d),
                   let schema = o as? [String: Any] {
                    params = schema
                }
                return ["type": "function",
                        "function": ["name": spec.name,
                                     "description": spec.description,
                                     "parameters": params]]
            }
        }
        if let learned { RequestBody.apply(learned, to: &body) }
        return body
    }

    // MARK: Thinking

    /// The level in force for a request: the request's own, else the route's.
    func thinkingLevel(for request: LLMRequest) -> ThinkingLevel? {
        request.thinking ?? profile.thinking
    }

    private func effortRoute(_ request: LLMRequest) -> String {
        "\(profile.baseURL)|\(requestModel(request))"
    }

    /// The model a request is for.
    private func requestModel(_ request: LLMRequest) -> String {
        request.model.isEmpty ? profile.model : request.model
    }

    /// The effort word that will go on the wire (after any learned remap), or
    /// nil when none is sent.
    func effortWord(for request: LLMRequest) -> String? {
        guard let level = thinkingLevel(for: request) else { return nil }
        let rules = ModelRequestRules.for(profile, model: requestModel(request))
        let word: String?
        switch rules.thinking {
        // A fixed vocabulary (GLM-5.3: low/high/max; Kimi Code: none/low/high/max): the nearest offered level's word.
        case .effort: word = rules.effortWord(level)
        case .template, .effortField: word = level.wireEffort
        case .toggle, .alwaysOn, .none: word = nil
        }
        guard let word else { return nil }
        if let learned = ReasoningEffortCache.shared.accepted(route: effortRoute(request), requested: word) {
            return learned.isEmpty ? nil : learned
        }
        return word
    }

    /// Put the thinking controls on the request body.
    ///
    /// Self-hosted servers get `chat_template_kwargs` — that is how Qwen3.x,
    /// GLM and DeepSeek templates switch thinking on/off and read the effort —
    /// plus the top-level `reasoning_effort` (SGLang forwards it to the
    /// template too; vLLM's gpt-oss path reads it there). Hosted APIs only
    /// understand the top-level field, and only when thinking is on.
    func applyThinking(_ request: LLMRequest, rules: ModelRequestRules, to body: inout [String: Any]) {
        guard let level = thinkingLevel(for: request) else { return }
        let effort = effortWord(for: request)
        switch rules.thinking {
        case .template:
            if profile.kind == .openAICompat || profile.kind == .openAI || profile.kind == .openRouter {
                var kwargs: [String: Any] = ["enable_thinking": level != .off]
                if let effort {
                    kwargs["reasoning_effort"] = effort
                    body["reasoning_effort"] = effort
                }
                body["chat_template_kwargs"] = kwargs
            } else if profile.kind == .ollama || profile.kind == .lmStudio {
                if level == .off { body["chat_template_kwargs"] = ["enable_thinking": false] }
                if let effort { body["reasoning_effort"] = effort }
            } else if let effort {
                body["reasoning_effort"] = effort
            }
        case .effortField:
            if let effort { body["reasoning_effort"] = effort }
        case .effort(_, let inTemplate):
            // A model that always thinks is never told not to (that fails the request): only how hard.
            if let effort {
                body["reasoning_effort"] = effort
                if inTemplate { body["chat_template_kwargs"] = ["reasoning_effort": effort] }
            }
        case .toggle:
            body["thinking"] = ["type": level == .off ? "disabled" : "enabled"]
        case .alwaysOn, .none:
            break
        }
    }

    /// Effort vocabulary, weakest → strongest, for picking the nearest word a
    /// template accepts.
    static let effortRank: [String: Int] = [
        "none": 0, "minimal": 1, "low": 2, "medium": 3, "high": 4, "xhigh": 5, "max": 6,
    ]

    /// If `errorBody` is a template rejecting `requested`, the nearest effort
    /// it accepts ("" = send none). Nil when the error is about something else.
    static func effortCorrection(requested: String, errorBody: String) -> String? {
        let lower = errorBody.lowercased()
        guard lower.contains("reasoning effort") || lower.contains("reasoning_effort") else { return nil }
        guard lower.contains(requested.lowercased()) || lower.contains("supported") || lower.contains("invalid") else { return nil }
        // Pull the accepted words from the tail ("Supported types are xhigh (default), medium, and low").
        var tail = lower
        for marker in ["supported types are", "supported values are", "supported:", "must be one of", "expected one of", "supported"] {
            if let r = lower.range(of: marker) { tail = String(lower[r.upperBound...]); break }
        }
        let words = tail.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let accepted = Set(words.filter { effortRank[$0] != nil && $0 != requested.lowercased() })
        guard !accepted.isEmpty, let want = effortRank[requested.lowercased()] else { return "" }
        return accepted.min { a, b in
            let da = abs(effortRank[a]! - want), db = abs(effortRank[b]! - want)
            return da != db ? da < db : effortRank[a]! > effortRank[b]!   // tie → the stronger one
        }
    }

    /// Build the OpenAI `content` value for a user message. Plain text when it carries no attachments, or only ones
    /// that go as text; otherwise a multi-part array of `text` and `image_url` parts (images inline as base64 data
    /// URLs). Never a `file` part: no self-hosted server takes one (vLLM: "Unsupported chat content part type:
    /// 'file'"; llama.cpp: "unsupported content[].type"; SGLang's schema has no such part) — a file goes as the text
    /// Vision read out of it (see `AttachmentWire`).
    private func userContent(for m: LLMMessage, request: LLMRequest) -> Any {
        guard let attachments = m.attachments, !attachments.isEmpty else {
            return m.content ?? ""
        }
        let wire = AttachmentWire.parts(for: attachments, route: attachmentRoute(request))
        var texts: [String] = []
        if let text = m.content, !text.isEmpty { texts.append(text) }
        guard wire.contains(where: { if case .image = $0 { return true } else { return false } }) else {
            // All text: one string, which every server and chat template takes.
            for part in wire { if case .text(let text) = part { texts.append(text) } }
            return texts.joined(separator: "\n\n")
        }
        var parts: [[String: Any]] = texts.map { ["type": "text", "text": $0] }
        for part in wire {
            switch part {
            case .text(let text):
                parts.append(["type": "text", "text": text])
            case .image(let mime, let data):
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"],
                ])
            case .document(_, let data):
                // No OpenAI-compatible route takes documents (`AttachmentRoute.openAI`); never reached.
                parts.append(["type": "text", "text": "[document of \(data.count) bytes]"])
            }
        }
        return parts
    }

    /// What this route takes besides text, for this request's model.
    func attachmentRoute(_ request: LLMRequest) -> AttachmentRoute {
        AttachmentRoute.openAI(profile, model: requestModel(request))
    }

    /// Whether a request carries any image (a picture, a scanned PDF's pages) that would go as an `image_url`.
    func carriesImages(_ request: LLMRequest) -> Bool {
        let route = attachmentRoute(request)
        return request.messages.contains { m in
            m.role == .user && AttachmentWire.parts(for: m.attachments ?? [], route: route)
                .contains { if case .image = $0 { return true } else { return false } }
        }
    }

    /// Who is calling, authorization + user-supplied custom headers on every request.
    private func applyHeaders(_ req: inout URLRequest) {
        // Vision names itself honestly (a plan like Kimi Code checks which app is calling).
        req.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let key = profile.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let headers = profile.customHeaders {
            for (k, v) in headers where !k.isEmpty {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
    }
}

// MARK: - Fallback context windows
//
// Servers that don't expose their limits (most vLLM/llama.cpp builds, older
// Ollama) fall back to these tables. Keyed on the last path component of the
// model name, so "meta-llama/Llama-3.3-70B-Instruct" and "Llama-3.3-70B-Instruct"
// both match, and an Ollama "qwen3:8b" tag resolves through its base name.

public enum FallbackContextWindow {
    /// Default when nothing else matches: 32k keeps the gauge honest without
    /// promising more than the model actually has.
    public static let defaultLimit = 32_768

    /// Exact id (last path component, Ollama tag stripped).
    private static let exact: [String: Int] = [
        "gpt-4o": 128_000, "gpt-4o-mini": 128_000, "gpt-4.1": 1_048_576,
        "gpt-4.1-mini": 1_048_576, "gpt-4.1-nano": 1_048_576, "o1": 200_000,
        "o3": 200_000, "o4-mini": 200_000, "o3-mini": 200_000,
        "qwen3:8b": 32_768, "qwen3:14b": 32_768, "qwen3:32b": 32_768,
        "qwen2.5:7b": 32_768, "qwen2.5:14b": 32_768, "qwen2.5:32b": 32_768,
        "qwen2.5-coder:7b": 32_768, "qwen2.5-coder:32b": 32_768,
        "llama3.1:8b": 131_072, "llama3.1:70b": 131_072, "llama3.2:8b": 131_072,
        "deepseek-r1:14b": 65_536, "deepseek-r1:32b": 65_536,
        "deepseek-r1:70b": 131_072, "mistral:7b": 32_768, "mixtral:8x7b": 32_768,
        // SGLang on a DGX Spark typically serves these (native windows; the
        // live /get_model_info probe corrects them when YaRN or an extended
        // context_len is configured).
        "qwen3-30b-a3b": 32_768, "qwen3-32b": 32_768, "qwen3-235b-a22b": 32_768,
        "llama3.3-70b-instruct": 131_072, "llama3.1-8b-instruct": 131_072,
        "glm-4.5": 131_072, "glm-4.5-air": 131_072, "glm-4.6": 131_072,
        // The subscription plans' models (see `PlanCatalog`).
        "glm-5.3": 1_000_000, "kimi-for-coding": 1_000_000, "k3-256k": 262_144, "k3": 1_000_000,
        // Moonshot's platform (platform.kimi.ai/docs/models, 2026-10-18).
        "kimi-k3": 1_000_000, "kimi-k2.7-code": 262_144, "kimi-k2.7-code-highspeed": 262_144, "kimi-k2.6": 262_144,
    ]

    /// Prefix rules on the base name, checked after the exact table.
    private static let prefixes: [(String, Int)] = [
        ("llama-3.3-", 131_072), ("llama-3.1-", 131_072), ("llama-3.2-", 131_072),
        ("llama-4-", 1_048_576), ("llama4-", 1_048_576),
        // Qwen3.5 and later ship a 256K native window (262144); the probe
        // replaces this with the served figure (e.g. 1M under YaRN).
        ("qwen3.5", 262_144), ("qwen3.6", 262_144), ("qwen3.7", 262_144), ("qwen3.8", 262_144),
        ("qwen3.9", 262_144), ("qwen3-next", 262_144), ("qwen3-coder", 262_144),
        ("qwen3", 32_768), ("qwen2.5", 32_768), ("qwen2-72b", 131_072),
        ("deepseek-r1", 65_536), ("deepseek-v3", 131_072), ("deepseek", 65_536),
        ("gpt-4o", 128_000), ("gpt-4.1", 1_048_576), ("gpt-4", 128_000),
        ("claude-3.5", 200_000), ("claude-3", 100_000), ("claude-", 200_000),
        ("mistral-large", 131_072), ("mistral-small", 131_072),
        ("mixtral", 32_768), ("llama", 131_072), ("smollm", 131_072),
        ("glm-4.5", 131_072), ("glm-4.6", 131_072), ("glm-4", 131_072),
        ("kimi-k3", 1_000_000), ("kimi-k2.", 262_144),
    ]

    /// Look up a context window for a model name, or nil if unknown.
    public static func limit(for modelID: String) -> Int? {
        // Bedrock ids ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", inference-profile ARNs) carry vendor
        // and Region prefixes the tables below don't expect.
        if let bedrock = BedrockModels.contextWindow(modelID) { return bedrock }
        // "meta-llama/Llama-3.3-70B-Instruct" → "Llama-3.3-70B-Instruct" → "llama-3.3-70b-instruct"
        let base = (modelID.components(separatedBy: "/").last ?? modelID).lowercased()
        if let hit = exact[base] { return hit }
        // Ollama tags: "qwen3:8b" → try "qwen3" prefix rules, base name "qwen3".
        let noTag = (base.components(separatedBy: ":").first ?? base)
        for (prefix, limit) in prefixes where noTag.hasPrefix(prefix) { return limit }
        // Bare base without the family prefix, e.g. "8b" models already caught above;
        // last resort: the full id in the exact table.
        return exact[modelID.lowercased()]
    }
}

// MARK: - Learned reasoning-effort vocabulary

/// Per route (base URL + model), which effort word the server's template
/// actually accepts for each word we asked for — learned from its 400s so
/// the retry happens once, not on every request.
public final class ReasoningEffortCache: @unchecked Sendable {
    public static let shared = ReasoningEffortCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()

    public func accepted(route: String, requested: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map["\(route)|\(requested)"]
    }

    public func learn(route: String, requested: String, accepted: String) {
        lock.lock(); defer { lock.unlock() }
        map["\(route)|\(requested)"] = accepted
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}

// MARK: - Reasoning sent back

/// Kimi's thinking models want each assistant message that called tools to carry the reasoning that led to it
/// (`reasoning_content`), or they answer 400 "thinking is enabled but reasoning_content is missing". The client keeps
/// a reply's reasoning in the message's `providerState` and sends it back from there.
public enum ReasoningEcho {
    private static let prefix = "openai.reasoning_content:"

    /// What a message would be sent back with when its reasoning wasn't kept (the transcript was rebuilt from text).
    public static let placeholder = "(Earlier reasoning was not kept.)"

    static func state(_ reasoning: String) -> String { prefix + reasoning }

    /// The reasoning in a `providerState` this client wrote (nil for another client's state, e.g. Bedrock's).
    static func reasoning(from state: String?) -> String? {
        guard let state, state.hasPrefix(prefix) else { return nil }
        let text = String(state.dropFirst(prefix.count))
        return text.isEmpty ? nil : text
    }
}
