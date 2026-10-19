import Foundation

// MARK: - What each model takes on the wire
//
// Hosted APIs disagree about the optional parts of a chat request, and they refuse the whole request (HTTP 400)
// when one is wrong: Moonshot's Kimi K2.6/K2.7/K3 fix the temperature ("invalid temperature: only 1 is allowed for
// this model"), K2.7 Code can't stop thinking, Z.ai's GLM-5.3 can't either and takes only low/high/max, Z.ai text
// models take plain-string content only and `tool_choice: "auto"` only, OpenAI's reasoning models want
// `max_completion_tokens` and no temperature. This table says, per provider and model, which sampling and thinking
// parameters to send, so the request is right the first time. What the table doesn't know, the server's own 400
// teaches (see `RequestAdaptations`). Researched from the providers' docs on 2026-10-18:
//   - Moonshot: platform.kimi.ai/docs/api/models-overview, /docs/guide/use-thinking-models, /docs/models
//   - Kimi Code: kimi.com/code/docs (models, error reference)
//   - Z.ai: docs.z.ai/api-reference/llm/chat-completion, /guides/llm/glm-5.3, /api-reference/api-code
// Vision for Windows carries the same table (same ids, same rules).

/// The services whose rules Vision knows, recognised by address.
public enum KnownProvider: String, Sendable, Equatable {
    /// Moonshot's open platform (api.moonshot.ai / api.moonshot.cn): kimi-k3, kimi-k2.7-code, kimi-k2.6, …
    case moonshot
    /// The Kimi Code membership API (api.kimi.com/coding, api.kimi.ai/coding): k3, kimi-for-coding, …
    case kimiCode
    /// Z.ai / BigModel (api.z.ai, open.bigmodel.cn): GLM models, general and Coding Plan endpoints.
    case zai
    case openAI
    case other

    /// How the provider is named in a notice ("Moonshot", "Z.ai").
    public var label: String {
        switch self {
        case .moonshot: "Moonshot"
        case .kimiCode: "Kimi Code"
        case .zai: "Z.ai"
        case .openAI: "OpenAI"
        case .other: "The model server"
        }
    }

    public static func of(_ profile: ProviderProfile) -> KnownProvider { of(baseURL: profile.baseURL) }

    public static func of(baseURL: String) -> KnownProvider {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased() else { return .other }
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if under("moonshot.ai") || under("moonshot.cn") { return .moonshot }
        if under("kimi.com") || under("kimi.ai") {
            return url.path.lowercased().contains("/coding") ? .kimiCode : .moonshot
        }
        if under("z.ai") || under("bigmodel.cn") { return .zai }
        if under("openai.com") { return .openAI }
        return .other
    }
}

/// How a model's thinking is switched and sized on the wire.
public enum ThinkingControl: Equatable, Sendable {
    /// A chat template on a server you run (vLLM, SGLang, llama.cpp, Ollama, LM Studio):
    /// `chat_template_kwargs.enable_thinking` + `reasoning_effort`, as before. Every level is offered.
    case template
    /// A hosted API's top-level `reasoning_effort`, sent only while thinking is on. Every level is offered.
    case effortField
    /// `reasoning_effort` from a fixed vocabulary: each offered level and the word it sends. A model with no
    /// `.off` entry always thinks. `inTemplate` also puts the word in `chat_template_kwargs` (a GLM-5 on vLLM).
    case effort(words: [ThinkingLevel: String], inTemplate: Bool)
    /// `thinking: {"type": "enabled" | "disabled"}` — on or off, no depth (Kimi K2.6, GLM-4.6 … GLM-5.1).
    case toggle
    /// Always thinks and takes no setting (Kimi K2.7 Code): nothing is sent.
    case alwaysOn
    /// No thinking control at all (moonshot-v1, the retired Kimi K2 previews): nothing is sent.
    case none
}

/// What one model accepts. `ModelRequestRules.for(_:model:)` looks it up.
public struct ModelRequestRules: Equatable, Sendable {
    public var provider: KnownProvider
    public var thinking: ThinkingControl
    /// False: never send `temperature` (the model fixes it and refuses any other value).
    public var sendsTemperature = true
    /// Clamp a configured temperature into this range.
    public var temperatureRange: ClosedRange<Double>?
    /// False: never send `top_p`.
    public var sendsTopP = true
    /// The most output tokens the model takes; a larger `max_tokens` is lowered to it.
    public var maxOutputTokens: Int?
    /// "max_tokens", or "max_completion_tokens" (OpenAI's reasoning models).
    public var maxTokensField = "max_tokens"
    /// Whether `tool_choice: "required"` (or a named tool) is accepted. Vision doesn't send it today; Guardian's
    /// proxy and future callers read this.
    public var forcedToolChoice = true
    /// The API takes `content` as a plain string only (Z.ai's text models): attachments are folded into the text.
    public var textOnlyContent = false
    /// Whether the model reads images. Nil = assume so (a server that refuses them switches them off at runtime).
    public var acceptsImages: Bool?
    /// The model's reasoning must go back on the assistant messages that made tool calls (`reasoning_content`) —
    /// Kimi answers 400 "thinking is enabled but reasoning_content is missing" otherwise.
    public var echoReasoning = false

    public init(provider: KnownProvider, thinking: ThinkingControl) {
        self.provider = provider
        self.thinking = thinking
    }

    // MARK: Thinking levels

    /// The levels a thinking picker offers for this model, weakest first (empty = no choice to make).
    public var thinkingLevels: [ThinkingLevel] {
        switch thinking {
        case .template, .effortField: ThinkingLevel.allCases
        case .effort(let words, _): ThinkingLevel.allCases.filter { words[$0] != nil }
        case .toggle: [.off, .high]
        case .alwaysOn, .none: []
        }
    }

    /// The model always thinks (there is no Off).
    public var alwaysThinks: Bool {
        switch thinking {
        case .alwaysOn: true
        case .effort(let words, _): !words.isEmpty && words[.off] == nil
        default: false
        }
    }

    /// How a level is called in the picker for this model: a toggle's "on" is "On", not "High".
    public func label(_ level: ThinkingLevel) -> String {
        if case .toggle = thinking { return level == .off ? "Off" : "On" }
        return level.label
    }

    /// The offered level nearest to `level` (an exact match, else the closest, the stronger on a tie — and never
    /// Off for a level that asks for thinking); nil when the model offers none.
    public func nearestLevel(_ level: ThinkingLevel) -> ThinkingLevel? {
        var offered = thinkingLevels
        if offered.contains(level) { return level }
        if case .toggle = thinking { return level == .off ? .off : .high }
        // Asking for some thinking never turns it off (GLM-5.2: Low → high, as Z.ai maps it itself).
        if level != .off, offered.contains(where: { $0 != .off }) { offered.removeAll { $0 == .off } }
        let rank = { (l: ThinkingLevel) in ThinkingLevel.allCases.firstIndex(of: l) ?? 0 }
        return offered.min { a, b in
            let da = abs(rank(a) - rank(level)), db = abs(rank(b) - rank(level))
            return da != db ? da < db : rank(a) > rank(b)
        }
    }

    /// The `reasoning_effort` word for `level` under an `.effort` vocabulary (nil otherwise).
    public func effortWord(_ level: ThinkingLevel) -> String? {
        guard case .effort(let words, _) = thinking, let nearest = nearestLevel(level) else { return nil }
        return words[nearest]
    }

    // MARK: The table

    /// The rules for `model` on `profile`'s server.
    public static func `for`(_ profile: ProviderProfile, model: String) -> ModelRequestRules {
        let id = normalized(model.isEmpty ? profile.model : model)
        let provider = KnownProvider.of(profile)
        switch provider {
        case .moonshot: return moonshot(id)
        case .kimiCode: return kimiCode(id)
        case .zai: return zai(id)
        case .openAI: return openAI(id)
        case .other: return other(profile, id)
        }
    }

    /// "moonshotai/Kimi-K2.6" → "kimi-k2.6"; "glm-5.3:latest" → "glm-5.3".
    static func normalized(_ model: String) -> String {
        let last = (model.components(separatedBy: "/").last ?? model).lowercased()
        return last.components(separatedBy: ":").first ?? last
    }

    /// low / high / max, no Off: GLM-5.3, Kimi K3 (and GLM-5 elsewhere, as before).
    static let lowHighMax: [ThinkingLevel: String] = [.low: "low", .high: "high", .max: "max"]

    /// Moonshot's open platform. K3: effort low/high/max (default max), temperature/top_p fixed. K2.7 Code: always
    /// thinks, takes no thinking setting and no `reasoning_effort`, no `tool_choice: "required"`. K2.6 (and K2.5):
    /// thinking on or off, temperature fixed (1.0 thinking, 0.6 not). The retired K2 previews and moonshot-v1 take
    /// a temperature in 0…1 and no thinking setting.
    static func moonshot(_ id: String) -> ModelRequestRules {
        if id.hasPrefix("kimi-k3") {
            var r = ModelRequestRules(provider: .moonshot, thinking: .effort(words: lowHighMax, inTemplate: false))
            r.sendsTemperature = false; r.sendsTopP = false; r.echoReasoning = true
            return r
        }
        if id.hasPrefix("kimi-k2.7") || id.hasPrefix("kimi-k2-thinking") || id.hasPrefix("kimi-thinking") {
            var r = ModelRequestRules(provider: .moonshot, thinking: .alwaysOn)
            r.sendsTemperature = false; r.sendsTopP = false; r.forcedToolChoice = false; r.echoReasoning = true
            return r
        }
        if id.hasPrefix("kimi-k2.6") || id.hasPrefix("kimi-k2.5") {
            var r = ModelRequestRules(provider: .moonshot, thinking: .toggle)
            r.sendsTemperature = false; r.sendsTopP = false; r.forcedToolChoice = false; r.echoReasoning = true
            return r
        }
        var r = ModelRequestRules(provider: .moonshot, thinking: .none)
        r.temperatureRange = 0...1
        return r
    }

    /// The Kimi Code membership API. k3, k3-256k and kimi-for-coding take `reasoning_effort` low/high/max, and
    /// "none" turns thinking off (served by K2.8 Preview without thinking); the HighSpeed model always thinks.
    /// The temperature isn't documented: like the platform's Kimi models, it isn't sent.
    static func kimiCode(_ id: String) -> ModelRequestRules {
        if id.contains("highspeed") {
            var r = ModelRequestRules(provider: .kimiCode, thinking: .alwaysOn)
            r.sendsTemperature = false; r.sendsTopP = false; r.forcedToolChoice = false; r.echoReasoning = true
            return r
        }
        var words = lowHighMax
        words[.off] = "none"
        var r = ModelRequestRules(provider: .kimiCode, thinking: .effort(words: words, inTemplate: false))
        r.sendsTemperature = false; r.sendsTopP = false; r.forcedToolChoice = false; r.echoReasoning = true
        return r
    }

    /// Z.ai / BigModel. GLM-5.3 always thinks, effort low/high/max. GLM-5.2: "none" skips thinking, effort
    /// high/max. GLM-4.6 … GLM-5.1: thinking on or off. Every GLM: temperature 0…1, at most 131072 output tokens,
    /// `tool_choice` "auto" only; the text models take plain-string content only and no images (the -flash and
    /// "v" models are the vision ones).
    static func zai(_ id: String) -> ModelRequestRules {
        var r: ModelRequestRules
        if id.hasPrefix("glm-5.3") {
            r = ModelRequestRules(provider: .zai, thinking: .effort(words: lowHighMax, inTemplate: false))
        } else if id.hasPrefix("glm-5.2") {
            r = ModelRequestRules(provider: .zai, thinking: .effort(words: [.off: "none", .high: "high", .max: "max"],
                                                                     inTemplate: false))
        } else {
            r = ModelRequestRules(provider: .zai, thinking: .toggle)
        }
        r.temperatureRange = 0...1
        r.maxOutputTokens = 131_072
        r.forcedToolChoice = false
        let vision = id.contains("flash") || id.range(of: #"^glm-[0-9.]+v"#, options: .regularExpression) != nil
        r.textOnlyContent = !vision
        r.acceptsImages = vision
        return r
    }

    /// OpenAI: the reasoning models (o1, o3, o4, gpt-5…) take no temperature and want `max_completion_tokens`.
    static func openAI(_ id: String) -> ModelRequestRules {
        var r = ModelRequestRules(provider: .openAI, thinking: .effortField)
        let reasoning = ["o1", "o3", "o4"].contains { id == $0 || id.hasPrefix($0 + "-") } || id.hasPrefix("gpt-5")
        if reasoning {
            r.sendsTemperature = false
            r.sendsTopP = false
            r.maxTokensField = "max_completion_tokens"
        }
        return r
    }

    /// Anything else: a server you run gets the chat-template controls, a hosted one the top-level effort. A GLM-5
    /// model anywhere always thinks and has its own words for how hard (the Qwen Coding Plan serves `glm-5`; a
    /// vLLM box may serve GLM-5.3) — the rule Vision for Windows shares.
    static func other(_ profile: ProviderProfile, _ id: String) -> ModelRequestRules {
        let selfHosted = profile.isSelfHosted
        if id.hasPrefix("glm-5") {
            let template = selfHosted && profile.kind != .ollama && profile.kind != .lmStudio
            return ModelRequestRules(provider: .other, thinking: .effort(words: lowHighMax, inTemplate: template))
        }
        return ModelRequestRules(provider: .other, thinking: selfHosted ? .template : .effortField)
    }
}
