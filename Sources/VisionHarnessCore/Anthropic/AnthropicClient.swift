import Foundation

// MARK: - Anthropic API client (Messages API, an API key)
//
// POST <base>/messages with `x-api-key` and `anthropic-version`, streamed as server-sent events; GET
// <base>/models for the key's models (context window and output ceiling included). Request shaping
// lives in `AnthropicMessages`, error wording in `AnthropicErrors`. Two refusals are adapted to once
// per request: Claude turning down replayed reasoning (an edited history invalidates its signature),
// and a key that isn't enabled for the server-side-fallback beta.

public struct AnthropicClient: ProviderClient {
    public let profile: ProviderProfile
    private let session: URLSession
    let onNotice: (@Sendable (String) -> Void)?

    public init(profile: ProviderProfile, onNotice: (@Sendable (String) -> Void)? = nil) {
        self.profile = profile
        self.onNotice = onNotice
        if let stubs = OpenAIClient.protocolClassesForTesting {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = stubs + (cfg.protocolClasses ?? [])
            session = URLSession(configuration: cfg)
        } else {
            session = Self.sharedSession
        }
    }

    /// One session for every client (they are made per request and per retry), built for long streams:
    /// Claude may think for minutes before the first visible byte.
    private static let sharedSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = OpenAIClient.idleTimeout
        cfg.timeoutIntervalForResource = 24 * 3_600
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    // MARK: Endpoints

    /// The API's base: the route's address, with "/v1" added when it names only the host.
    var base: String {
        var text = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = AnthropicMessages.defaultBaseURL }
        while text.hasSuffix("/") { text.removeLast() }
        if let url = URL(string: text), url.path.isEmpty || url.path == "/" { text += "/v1" }
        return text
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: "\(base)/\(path)") else {
            throw LLMError.rejected(status: 400, message: "The Anthropic address “\(profile.baseURL)” isn't a valid URL — check it in Settings ▸ AI Models.",
                                    body: "bad base URL", permanent: true)
        }
        return url
    }

    private func headers(_ request: inout URLRequest, beta: [String] = []) {
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(AnthropicMessages.version, forHTTPHeaderField: "anthropic-version")
        if let key = profile.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        if !beta.isEmpty { request.setValue(beta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        for (name, value) in profile.customHeaders ?? [:] where !name.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
    }

    // MARK: LLMClient

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let client = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await client.streamTurn(request) { _ = continuation.yield($0) }
                    continuation.finish()
                } catch let e as URLError where e.code == .cancelled {
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

    /// Keys that turned the server-side-fallback beta down, per address and model: asked once a run.
    private static let noFallbacks = LockedSet()

    private func streamTurn(_ request: LLMRequest, emit: (LLMStreamEvent) -> Void) async throws {
        let model = AnthropicMessages.modelID(request, profile)
        if BedrockConverse.isBlank(model) { throw LLMError.noModel }
        let fallbackKey = "\(base.lowercased())|\(model)"
        var replay = true
        var fallbacks = !Self.noFallbacks.contains(fallbackKey)
        var attempts = 0
        while true {
            attempts += 1
            let body = AnthropicMessages.request(request, profile: profile, replayReasoning: replay, fallbacks: fallbacks)
            let sendsFallbacks = body["fallbacks"] != nil
            var http = URLRequest(url: try url("messages"))
            http.httpMethod = "POST"
            http.httpBody = body.serializedData()
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            headers(&http, beta: sendsFallbacks ? [AnthropicMessages.fallbackBeta] : [])

            let (bytes, response) = try await open(http)
            defer { bytes.task.cancel() }
            guard (200...299).contains(response.statusCode) else {
                let text = await Self.readBody(bytes)
                try Task.checkCancellation()
                let lower = text.lowercased()
                if attempts < 3, response.statusCode == 400 {
                    // The key isn't enabled for the fallback beta: carry on without it, and say so once.
                    if sendsFallbacks, lower.contains("anthropic-beta") || lower.contains("fallback") {
                        Self.noFallbacks.insert(fallbackKey)
                        fallbacks = false
                        onNotice?("Anthropic doesn't offer server-side fallback to this key — Vision carries on without it (a declined request then stops instead of moving to another Claude model).")
                        continue
                    }
                    // Replayed reasoning refused (an edited history invalidates its signature): once more without it.
                    if replay, lower.contains("signature") || (lower.contains("thinking") && lower.contains("block")),
                       request.messages.contains(where: { $0.providerState != nil }) {
                        replay = false
                        continue
                    }
                }
                throw AnthropicErrors.error(status: response.statusCode, body: text, model: model)
            }
            try await read(bytes, emit: emit)
            return
        }
    }

    private func open(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes, response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            if error.code == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw LLMError.connection("the request was cancelled by the system")
            }
            if RequestRetry.disposition(for: error) == .fail {
                throw LLMError.rejected(status: 0, message: "Could not reach Anthropic's API: \(error.localizedDescription)",
                                        body: error.localizedDescription, permanent: true)
            }
            throw LLMError.connection(error.code == .timedOut ? "the request timed out" : error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw LLMError.connection("the reply was not an HTTP response")
        }
        return (bytes, http)
    }

    /// Read the event stream into deltas and the final `.done`.
    private func read(_ bytes: URLSession.AsyncBytes, emit: (LLMStreamEvent) -> Void) async throws {
        var reply = MessagesReply()
        var event: String?
        var data = ""
        var raw = Data()
        var sawEvent = false
        var other = ""

        func dispatch() throws {
            defer { event = nil; data = "" }
            guard !data.isEmpty else { return }
            guard let json = JSONValue(parsing: data), json.object != nil else { return }
            sawEvent = true
            if let delta = try reply.handle(event: event, data: json) { emit(delta) }
        }

        func line(_ text: String) throws {
            var text = text
            if text.hasSuffix("\r") { text.removeLast() }
            if text.isEmpty { try dispatch(); return }
            if text.hasPrefix(":") { return }
            if text.hasPrefix("event:") {
                event = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("data:") {
                var payload = String(text.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                data += data.isEmpty ? payload : "\n" + payload
            } else if !sawEvent, other.utf8.count < 4_000 {
                other += text + "\n"
            }
        }

        do {
            for try await byte in bytes {
                raw.append(byte)
                guard byte == 0x0A else { continue }
                try line(String(decoding: raw.dropLast(), as: UTF8.self))
                raw.removeAll(keepingCapacity: true)
            }
            if !raw.isEmpty { try line(String(decoding: raw, as: UTF8.self)) }
            try dispatch()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw LLMError.sse(error.code == .timedOut ? "no data from Anthropic for \(Int(OpenAIClient.idleTimeout)) s"
                                                       : error.localizedDescription)
        }
        try Task.checkCancellation()
        if !sawEvent, !other.isEmpty {
            // Something answered, but not the Messages API (a proxy's page, a wrong address).
            let flat = other.replacingOccurrences(of: "\n", with: " ")
            throw LLMError.http(200, "unrecognised reply (is the address Anthropic's API, ending in /v1?): \(flat.prefix(200))")
        }
        for handover in reply.handovers {
            onNotice?("\(handover.from) declined this request — \(handover.to) carried on (Anthropic's server-side fallback).")
        }
        emit(try reply.finish())
    }

    /// The first 8 KB of an error reply.
    private static func readBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8_000 { break }
            }
        } catch {}
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Models

    /// The key's models (`GET /models`, every page).
    public func listModels() async throws -> [String] {
        try await models().map(\.id)
    }

    struct ListedModel: Sendable {
        var id: String
        var contextWindow: Int?
        var maxTokens: Int?
    }

    func models() async throws -> [ListedModel] {
        var out: [ListedModel] = []
        var after: String?
        for _ in 0..<10 {
            var path = "models?limit=1000"
            if let after { path += "&after_id=" + (after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? after) }
            let page = try await getJSON(path)
            for entry in page["data"]?.array ?? [] {
                guard let id = entry["id"]?.string, !id.isEmpty else { continue }
                out.append(ListedModel(id: id, contextWindow: entry["max_input_tokens"]?.int, maxTokens: entry["max_tokens"]?.int))
            }
            guard page["has_more"]?.bool == true, let last = page["last_id"]?.string else { break }
            after = last
        }
        return out
    }

    private func getJSON(_ path: String) async throws -> JSONValue {
        var request = URLRequest(url: try url(path))
        request.timeoutInterval = 15
        headers(&request)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw LLMError.connection(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        guard (200...299).contains(status) else { throw AnthropicErrors.error(status: status, body: text, model: profile.model) }
        guard let object = JSONValue(parsing: data), object.object != nil else {
            throw LLMError.sse("unexpected /models reply from Anthropic")
        }
        return object
    }

    /// What the API says about a model (its window and output ceiling), asked once a run per address and model;
    /// the built-in table answers when it can't be asked.
    public func modelInfo(_ model: String?) async -> ModelInfo? {
        let id = model.flatMap { $0.isEmpty ? nil : $0 } ?? profile.model
        let traits = BedrockModels.traits(id)
        let key = "\(base.lowercased())|\(id)"
        if let known = Self.infoCache.value(key) { return known }
        var info = ModelInfo(id: id, contextWindow: traits.contextWindow, maxTokens: traits.maxTokensCeiling, servedModels: [id])
        if let entry = try? await getJSON("models/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)) {
            if let window = entry["max_input_tokens"]?.int, window > 0 { info.contextWindow = window }
            if let ceiling = entry["max_tokens"]?.int, ceiling > 0 { info.maxTokens = ceiling }
        }
        // Kept either way: the table is right for every current Claude, and this runs before every turn.
        Self.infoCache.set(key, info)
        return info
    }

    private static let infoCache = InfoCache()

    private final class InfoCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: ModelInfo] = [:]
        func value(_ key: String) -> ModelInfo? { lock.withLock { items[key] } }
        func set(_ key: String, _ info: ModelInfo) { lock.withLock { items[key] = info } }
    }

    final class LockedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var items: Set<String> = []
        func contains(_ key: String) -> Bool { lock.withLock { items.contains(key) } }
        func insert(_ key: String) { lock.withLock { _ = items.insert(key) } }
        func removeAll() { lock.withLock { items.removeAll() } }
    }

    /// Forget what keys taught this run (tests).
    static func resetLearned() { noFallbacks.removeAll() }
}
