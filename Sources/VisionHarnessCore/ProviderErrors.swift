import Foundation

// MARK: - Provider errors in plain words
//
// Z.ai answers with HTTP status + a business code (docs.z.ai/api-reference/api-code):
//   {"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}
// Several of its 429s are not "slow down" at all: 1113 (no balance — what a GLM Coding Plan key gets on the general
// endpoint), 1309 (the Coding Plan expired), 1311 (the plan doesn't include the model). Retrying those for ever is
// what "it would try to work and just straight up did not work" looked like. They now fail at once, in plain words,
// naming the fix. Rate limits (1302) and overload (1305) are still waited out.

public struct ProviderErrorExplanation: Equatable, Sendable {
    /// What to tell the person.
    public var message: String
    /// Retrying can't fix it.
    public var permanent: Bool
    /// For Z.ai: the endpoint that may suit the key better ("coding", "general"); nil = none to suggest.
    public var suggestedEndpoint: String?
}

public enum ZAIErrors {
    /// The Z.ai endpoint kinds, by address.
    public enum Endpoint: String, Sendable, CaseIterable {
        case coding, general, chinaCoding, chinaGeneral

        public var baseURL: String {
            switch self {
            case .coding: "https://api.z.ai/api/coding/paas/v4"
            case .general: "https://api.z.ai/api/paas/v4"
            case .chinaCoding: "https://open.bigmodel.cn/api/coding/paas/v4"
            case .chinaGeneral: "https://open.bigmodel.cn/api/paas/v4"
            }
        }

        /// "Coding Plan", "General API", "China — Coding Plan", "China — General API".
        public var name: String {
            switch self {
            case .coding: "Coding Plan"
            case .general: "General API"
            case .chinaCoding: "China — Coding Plan"
            case .chinaGeneral: "China — General API"
            }
        }

        public var isCoding: Bool { self == .coding || self == .chinaCoding }
        public var isChina: Bool { self == .chinaCoding || self == .chinaGeneral }

        /// The same kind of endpoint in the other region, and the other kind in the same region.
        public var otherKind: Endpoint {
            switch self {
            case .coding: .general
            case .general: .coding
            case .chinaCoding: .chinaGeneral
            case .chinaGeneral: .chinaCoding
            }
        }
        public var otherRegion: Endpoint {
            switch self {
            case .coding: .chinaCoding
            case .general: .chinaGeneral
            case .chinaCoding: .coding
            case .chinaGeneral: .general
            }
        }

        public static func of(baseURL: String) -> Endpoint? {
            guard let url = URL(string: baseURL), let host = url.host?.lowercased() else { return nil }
            let china = host == "bigmodel.cn" || host.hasSuffix(".bigmodel.cn")
            guard china || host == "z.ai" || host.hasSuffix(".z.ai") else { return nil }
            let coding = url.path.lowercased().contains("/coding")
            switch (china, coding) {
            case (false, true): return .coding
            case (false, false): return .general
            case (true, true): return .chinaCoding
            case (true, false): return .chinaGeneral
            }
        }
    }

    /// The business code and message of a Z.ai error body.
    public static func parse(_ body: String) -> (code: String, message: String)? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        let code = (err["code"] as? String) ?? (err["code"] as? Int).map(String.init)
        guard let code else { return nil }
        return (code, (err["message"] as? String) ?? "")
    }

    /// A Z.ai error in plain words; nil when it is one to leave to the generic handling (rate limits, overload,
    /// server errors, and parameter refusals — those the client adapts to).
    public static func explain(status: Int, body: String, endpoint: Endpoint?, model: String) -> ProviderErrorExplanation? {
        let parsed = parse(body)
        let code = parsed?.code ?? ""
        let said = parsed?.message ?? ""
        let place = endpoint?.name ?? "this endpoint"
        let reset = resetTime(in: said).map { " It resets at \($0)." } ?? ""
        switch code {
        case "1000", "1001", "1002", "1003", "1004", "401":
            var text = "Z.ai didn't accept the key (\(code): \(said.isEmpty ? "authentication failed" : said))."
            if let endpoint {
                text += endpoint.isChina
                    ? " Keys made at open.bigmodel.cn work on the China endpoints; a key from z.ai needs the international ones."
                    : " Keys made at z.ai work on the international endpoints; a key from open.bigmodel.cn needs the China ones."
            }
            return .init(message: text, permanent: true, suggestedEndpoint: endpoint.map { $0.otherRegion.rawValue })
        case "1113":
            if let endpoint, !endpoint.isCoding {
                return .init(message: "Z.ai says this account has no balance on the General API (1113). If this is a GLM Coding Plan key, switch the endpoint to Coding Plan — Coding Plan keys work only there. A General API key needs credit at z.ai.",
                             permanent: true, suggestedEndpoint: endpoint.otherKind.rawValue)
            }
            return .init(message: "Z.ai says there's no balance or plan for this key on \(place) (1113). Check that the GLM Coding Plan is active on this account, or use a General API key with credit.",
                         permanent: true, suggestedEndpoint: endpoint.map { $0.otherKind.rawValue })
        case "1211":
            return .init(message: "Z.ai doesn't know the model `\(model)` (1211). Pick one of its models — glm-5.3 is the current one.",
                         permanent: true, suggestedEndpoint: nil)
        case "1212", "1220", "1221", "1222":
            return .init(message: "Z.ai refused the request (\(code): \(said)).", permanent: true, suggestedEndpoint: nil)
        case "1301":
            return .init(message: "Z.ai's content filter turned this request down (1301). Rephrase the request, or use another model for it.",
                         permanent: true, suggestedEndpoint: nil)
        case "1308", "1310", "1316", "1317", "1318", "1319", "1320", "1321":
            return .init(message: "The Z.ai plan's usage limit is used up (\(code)).\(reset) Wait for it, or switch this chat to another model.",
                         permanent: true, suggestedEndpoint: nil)
        case "1309":
            return .init(message: "The GLM Coding Plan on this key has expired (1309). Renew it at z.ai/subscribe, or use a General API key.",
                         permanent: true, suggestedEndpoint: nil)
        case "1311":
            return .init(message: "The plan on this key doesn't include `\(model)` (1311). Pick a model the plan has — glm-5.3 is on every GLM Coding Plan.",
                         permanent: true, suggestedEndpoint: nil)
        case "1313":
            return .init(message: "Z.ai limited this key under its Fair Usage Policy (1313). Ask Z.ai to restore access.",
                         permanent: true, suggestedEndpoint: nil)
        case "1314", "1315":
            return .init(message: "Z.ai says this key is for a different product (\(code): \(said)). Use a key made for the endpoint this route calls.",
                         permanent: true, suggestedEndpoint: nil)
        default:
            if status == 401 {
                return .init(message: "Z.ai didn't accept the key (HTTP 401\(said.isEmpty ? "" : ": \(said)")).",
                             permanent: true, suggestedEndpoint: endpoint.map { $0.otherRegion.rawValue })
            }
            if status == 404 {
                return .init(message: "\(endpoint?.baseURL ?? "Z.ai") doesn't know that request (404). Check the endpoint — Vision calls <endpoint>/chat/completions.",
                             permanent: true, suggestedEndpoint: nil)
            }
            return nil
        }
    }

    /// "Your limit will reset at 2026-10-19 03:00:00" → "2026-10-19 03:00:00".
    static func resetTime(in message: String) -> String? {
        for marker in ["reset at ", "resets at ", "Resets at "] {
            if let r = message.range(of: marker) {
                let tail = message[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " .`"))
                let value = tail.components(separatedBy: CharacterSet(charactersIn: ".\n")).first ?? tail
                return value.isEmpty ? nil : value.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

public enum KimiErrors {
    /// A Kimi / Moonshot error in plain words (nil = leave it to the generic handling). Kimi Code's error reference:
    /// kimi.com/code/docs/en/kimi-code/error-reference.html.
    public static func explain(status: Int, body: String, provider: KnownProvider, model: String) -> ProviderErrorExplanation? {
        let lower = ParameterRejection.text(of: body).lowercased()
        switch (provider, status) {
        case (.kimiCode, 401) where lower.contains("invalid authentication"):
            return .init(message: "Kimi Code didn't accept the key. A Moonshot platform key (or address) doesn't work with Kimi Code — use a key from the Kimi Code console, or set this route up as “Moonshot (Kimi) — pay-as-you-go API”.",
                         permanent: true, suggestedEndpoint: nil)
        case (.kimiCode, 401) where lower.contains("does not have access"):
            return .init(message: "Your Kimi Code membership doesn't include `\(model)`. Use kimi-for-coding, or upgrade the membership.",
                         permanent: true, suggestedEndpoint: nil)
        case (.kimiCode, 403) where lower.contains("usage limit"):
            return .init(message: "The Kimi Code usage limit for this window is used up. Wait for it to reset, or switch this chat to another model.",
                         permanent: true, suggestedEndpoint: nil)
        case (.moonshot, 401):
            return .init(message: "Moonshot didn't accept the key. A key works only in the region it was made in (platform.moonshot.ai or platform.moonshot.cn), and a Kimi Code key doesn't work here.",
                         permanent: true, suggestedEndpoint: nil)
        case (.moonshot, 404) where lower.contains("model"):
            return .init(message: "Moonshot doesn't serve `\(model)` — older Kimi models were retired. kimi-k3 or kimi-k2.7-code are the current ones.",
                         permanent: true, suggestedEndpoint: nil)
        default:
            return nil
        }
    }
}

// MARK: - Testing a Z.ai key

/// The Test button for a Z.ai route: a one-token reply on the chosen endpoint; when that fails because of the key
/// or the account (wrong key type, wrong region, no balance), the same key is tried on the endpoints it may belong
/// to, so the answer can say "This looks like a GLM Coding Plan key — switch the endpoint to Coding Plan".
public enum ZAIDiagnosis {
    public struct Result: Equatable, Sendable {
        public var ok: Bool
        public var message: String
        /// The endpoint the key worked on instead (offer to switch to it).
        public var worksOn: ZAIErrors.Endpoint?
    }

    /// Codes (and HTTP statuses) that say the key or account doesn't fit the endpoint — worth trying elsewhere.
    static let keyProblems: Set<String> = ["1000", "1001", "1002", "1003", "1004", "401", "1113", "1309", "1314", "1315"]

    /// `ping` sends a one-token request to an endpoint and throws what the server said. It runs on the caller's
    /// actor (the guide's is the main actor), one endpoint at a time.
    public static func run(endpoint: ZAIErrors.Endpoint, model: String,
                           isolation: isolated (any Actor)? = #isolation,
                           ping: (ZAIErrors.Endpoint) async throws -> Void) async -> Result {
        do {
            try await ping(endpoint)
            return Result(ok: true, message: "✔ The key works on \(endpoint.name) with \(model).", worksOn: nil)
        } catch {
            let (status, body) = statusAndBody(error)
            let explained = status.flatMap { ZAIErrors.explain(status: $0, body: body, endpoint: endpoint, model: model) }
            let code = ZAIErrors.parse(body)?.code ?? status.map(String.init) ?? ""
            let first = explained?.message ?? plain(error)
            guard keyProblems.contains(code) || status == 401 else {
                return Result(ok: false, message: first, worksOn: nil)
            }
            var candidates: [ZAIErrors.Endpoint] = []
            if let s = explained?.suggestedEndpoint.flatMap(ZAIErrors.Endpoint.init(rawValue:)) { candidates.append(s) }
            for c in [endpoint.otherKind, endpoint.otherRegion] where !candidates.contains(c) { candidates.append(c) }
            for candidate in candidates {
                if (try? await ping(candidate)) != nil {
                    return Result(ok: false, message: switchAdvice(from: endpoint, to: candidate), worksOn: candidate)
                }
            }
            return Result(ok: false, message: first, worksOn: nil)
        }
    }

    /// What to say when the key works on another endpoint.
    public static func switchAdvice(from: ZAIErrors.Endpoint, to: ZAIErrors.Endpoint) -> String {
        if to.isCoding && !from.isCoding {
            return "This looks like a GLM Coding Plan key — switch the endpoint to \(to.name). (It answers there; on \(from.name) Z.ai says the account has no balance.)"
        }
        if !to.isCoding && from.isCoding {
            return "This looks like a General API key, not a GLM Coding Plan one — switch the endpoint to \(to.name)."
        }
        return to.isChina
            ? "This key is from open.bigmodel.cn — switch the endpoint to \(to.name)."
            : "This key is from z.ai — switch the endpoint to \(to.name)."
    }

    static func statusAndBody(_ error: Error) -> (Int?, String) {
        guard let llm = error as? LLMError else { return (nil, "") }
        switch llm {
        case .http(let status, let body), .rejected(let status, _, let body, _): return (status, body)
        default: return (nil, "")
        }
    }

    static func plain(_ error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .connection, .sse: return "Couldn't reach Z.ai. Check the internet connection, then try again."
            default: return llm.localizedDescription
            }
        }
        if error is URLError { return "Couldn't reach Z.ai. Check the internet connection, then try again." }
        return error.localizedDescription
    }
}

public extension ZAIDiagnosis {
    /// Test a Z.ai route as it is set up — its key, model and endpoint (nil for a route that isn't Z.ai's).
    static func test(_ route: ProviderProfile) async -> Result? {
        guard let endpoint = ZAIErrors.Endpoint.of(baseURL: route.baseURL) else { return nil }
        return await run(endpoint: endpoint, model: route.model) { candidate in
            var probe = route
            probe.baseURL = candidate.baseURL
            try await ping(probe)
        }
    }

    /// A one-token reply from the route (listing models proves nothing on Z.ai: any valid key lists them anywhere).
    static func ping(_ route: ProviderProfile) async throws {
        let client = ProviderClients.make(route)
        let request = LLMRequest(systemPrompt: "", messages: [.user("Hi")], tools: [], model: route.model, maxTokens: 1)
        for try await _ in client.stream(request) {}
    }
}

// MARK: - DeepSeek

/// DeepSeek's errors in plain words (api-docs.deepseek.com/quick_start/error_codes, 2026-10-19): 400 invalid format,
/// 401 wrong key, 402 no balance, 422 invalid parameters, 429 rate limit, 500 server error, 503 overloaded. A real
/// 401 body: {"error":{"message":"Authentication Fails, Your api key: ****abcd is invalid (request_id: …)",
/// "type":"authentication_error","param":null,"code":"invalid_request_error"}}.
public enum DeepSeekErrors {
    /// Where a DeepSeek key is made, and where its balance is topped up.
    public static let keyPage = "platform.deepseek.com/api_keys"
    public static let topUpPage = "platform.deepseek.com/top_up"

    public static func explain(status: Int, body: String, model: String) -> ProviderErrorExplanation? {
        let said = ParameterRejection.text(of: body)
        let lower = said.lowercased()
        switch status {
        case 401:
            return .init(message: "DeepSeek didn't accept the API key. Check it's a key from \(keyPage) (it starts with sk-), copied in one piece.",
                         permanent: true, suggestedEndpoint: nil)
        case 402:
            return .init(message: "The DeepSeek account has no balance left (402 Insufficient Balance). Top it up at \(topUpPage), then try again.",
                         permanent: true, suggestedEndpoint: nil)
        case 400 where lower.contains("reasoning_content"):
            return .init(message: "DeepSeek (\(model)) wants its earlier reasoning sent back with this conversation and refused without it (400). Start a new chat, or turn thinking off for this chat.",
                         permanent: true, suggestedEndpoint: nil)
        case 400 where lower.contains("model not exist") || lower.contains("model_not_found"):
            return .init(message: "DeepSeek doesn't serve `\(model)`. The current models are deepseek-flash and deepseek-v4-pro.",
                         permanent: true, suggestedEndpoint: nil)
        case 429:
            return .init(message: "DeepSeek's rate limit was reached (429) — Vision waits and tries again.",
                         permanent: false, suggestedEndpoint: nil)
        case 503:
            return .init(message: "DeepSeek's servers are overloaded right now (503) — Vision waits and tries again.",
                         permanent: false, suggestedEndpoint: nil)
        default:
            return nil
        }
    }
}

// MARK: - Anthropic

/// Anthropic API errors (`{"type":"error","error":{"type":…,"message":…},"request_id":…}`) in plain words. Real 401
/// bodies (recorded 2026-10-19): "invalid x-api-key", "x-api-key header is required".
public enum AnthropicErrors {
    public static let keyPage = "console.anthropic.com/settings/keys"

    /// The error's type and message, when the body is Anthropic's error shape.
    public static func parse(_ body: String) -> (type: String, message: String)? {
        guard let object = JSONValue(parsing: body), let error = object["error"], error.object != nil else { return nil }
        return (error["type"]?.string ?? "", error["message"]?.string ?? "")
    }

    /// "prompt is too long: 250123 tokens > 200000 maximum" → 200000.
    public static func overflowLimit(_ message: String) -> Int? {
        guard message.lowercased().contains("prompt is too long") else { return nil }
        let pattern = #"(\d+)\s*maximum"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else { return 0 }
        return Int(message[range]) ?? 0
    }

    /// An HTTP error reply as the error to throw.
    public static func error(status: Int, body: String, model: String) -> LLMError {
        let parsed = parse(body)
        let said = parsed?.message ?? ParameterRejection.text(of: body)
        let type = parsed?.type ?? ""
        if status == 413 || type == "request_too_large" {
            return .overflow(limit: 0, detail: "request too large for Anthropic's API (HTTP 413)")
        }
        if status == 400, let limit = overflowLimit(said) { return .overflow(limit: limit, detail: said) }
        let snippet = said.isEmpty ? "no details" : String(said.prefix(300))
        switch (status, type) {
        case (401, _):
            return .rejected(status: 401, message: "Anthropic didn't accept the API key (“\(snippet)”). Use a key from \(keyPage) — it starts with sk-ant-. A Claude Pro or Max subscription doesn't include API access; for that, use Claude Code.",
                             body: body, permanent: true)
        case (402, _):
            return .rejected(status: 402, message: "The Anthropic account needs credit or a payment method (402: \(snippet)). Add it at console.anthropic.com ▸ Billing.",
                             body: body, permanent: true)
        case (403, _):
            return .rejected(status: 403, message: "Anthropic refused this key for `\(model)` (403): \(snippet)", body: body, permanent: true)
        case (404, _):
            return .rejected(status: 404, message: "Anthropic doesn't offer `\(model)` to this key (404). Pick another model — the route's model list shows the ones the key can use.",
                             body: body, permanent: true)
        case (429, _):
            return .rejected(status: 429, message: "Anthropic's rate limit for this key was reached (429) — Vision waits and tries again.",
                             body: body, permanent: false)
        case (529, _), (_, "overloaded_error"):
            return .rejected(status: 529, message: "Anthropic's API is overloaded right now (529) — Vision waits and tries again.",
                             body: body, permanent: false)
        case (400, _):
            return .rejected(status: 400, message: "Anthropic refused the request (400): \(snippet)", body: body, permanent: true)
        default:
            return .http(status, body)
        }
    }

    /// An `error` event in the middle of a stream (overloaded, api_error): retried like its HTTP twin.
    static func streamError(type: String, message: String) -> LLMError {
        let status: Int = switch type {
        case "overloaded_error": 529
        case "rate_limit_error": 429
        case "invalid_request_error": 400
        case "authentication_error": 401
        case "permission_error": 403
        case "not_found_error": 404
        default: 500
        }
        let body = JSONValue.object(["type": "error", "error": .object(["type": .string(type), "message": .string(message)])]).serialized()
        return error(status: status, body: body, model: "")
    }

    /// Claude's safety check declined the request (`stop_reason: "refusal"`): nothing to retry.
    static func refusal(category: String?, explanation: String?, model: String?) -> LLMError {
        var text = "\(model.map { "\($0) " } ?? "Claude ")declined this request"
        if let category, !category.isEmpty { text += " (its safety check: \(category))" }
        text += "."
        if let explanation, !explanation.isEmpty { text += " \(explanation)" }
        text += " Rephrase it, or pick another model for this chat."
        return .rejected(status: 400, message: text, body: "stop_reason: refusal", permanent: true)
    }
}
