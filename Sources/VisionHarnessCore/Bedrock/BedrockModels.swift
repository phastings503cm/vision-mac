import Foundation

// MARK: - What Bedrock's models accept
//
// Converse is one API over many model families, but it passes through what each family refuses: a
// thinking budget on a Claude that only thinks adaptively, a temperature on one whose sampling
// parameters were removed, a cache point where the family has no cache, an output limit above the
// model's ceiling. Each is a 400 that no retry can fix, so the client shapes every request from this
// table. Ids are matched with and without a cross-Region inference-profile prefix ("us.", "eu.",
// "apac.", "global.", ...) and inside inference-profile ARNs. An application inference profile's ARN
// names no model, so it gets the conservative defaults.

/// How a Claude model is asked to think.
public enum ClaudeThinking: Sendable, Equatable {
    /// No extended thinking: Claude 3.5 and older, and every non-Claude model.
    case none
    /// `thinking {type: "enabled", budget_tokens}`: Claude 3.7 through the 4.5 generation.
    case budget
    /// `thinking {type: "adaptive"}` plus `outputConfig.effort`: Claude 4.6 and later, where
    /// `budget_tokens` is deprecated (4.6) or rejected (4.7 on).
    case adaptive
}

/// How an adaptive-thinking Claude is told not to think.
public enum ThinkingOff: Sendable, Equatable {
    /// Send no thinking field: the model then doesn't think (4.6 – 4.8, and budget models).
    case omit
    /// `thinking {type: "disabled"}` — Opus 5 and Sonnet 5 think unless told not to.
    case disabled
    /// `thinking {type: "between_tools"}` — Sonnet 5.5 rejects "disabled".
    case betweenTools
    /// Thinking can't be switched off (Opus 5.5, Fable): ask for the lowest effort instead.
    case lowEffort
}

/// The request-shaping facts about one Bedrock model.
public struct BedrockModelTraits: Sendable, Equatable {
    public var isClaude = false
    public var thinking = ClaudeThinking.none
    public var off = ThinkingOff.omit
    /// Ask for summarized thinking text: from Claude 4.7 on it is omitted unless requested,
    /// which would leave the live reasoning pane empty.
    public var summarizedThinking = false
    /// Whether temperature is accepted (Claude 4.7+ and 5.x reject sampling parameters).
    public var sampling = true
    public var contextWindow: Int?
    public var defaultMaxTokens = 4096
    /// The most output tokens the model allows, when known; larger requests are clamped.
    public var maxTokensCeiling: Int?
    /// Cache points after the system prompt and at the end of the conversation.
    public var cachePoints = false
    /// A cache point after the tool list (Claude only — Nova has no tool caching).
    public var toolCachePoint = false
    /// `toolResult.status` is only understood by Claude and Nova.
    public var toolResultStatus = false
    /// PDFs can go in as document blocks.
    public var documents = false

    public init() {}
}

public enum BedrockModels {
    /// Cross-Region inference-profile prefixes.
    private static let geographies: Set<String> = ["us", "us-gov", "eu", "apac", "jp", "au", "ca", "global"]

    /// Model providers on Bedrock (the "vendor." in "vendor.model").
    private static let vendors: Set<String> = [
        "anthropic", "amazon", "meta", "mistral", "deepseek", "openai", "qwen", "cohere", "ai21", "writer",
        "moonshot", "moonshotai", "minimax", "google", "nvidia", "twelvelabs",
    ]

    /// "us.anthropic.claude-…" or an ARN → "anthropic.claude-…" (lower-cased); nil when the
    /// id isn't a Bedrock "vendor.model" id.
    public static func baseID(_ modelID: String) -> String? {
        var id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let dot = id.firstIndex(of: "."), dot != id.startIndex,
           geographies.contains(String(id[..<dot])),
           id[id.index(after: dot)...].contains(".") {
            id = String(id[id.index(after: dot)...])
        }
        guard let dot = id.firstIndex(of: "."), dot != id.startIndex, vendors.contains(String(id[..<dot])) else {
            return nil
        }
        return id
    }

    /// The context window for a Bedrock model id, or nil when it isn't one we know.
    public static func contextWindow(_ modelID: String) -> Int? {
        baseID(modelID) == nil ? nil : traits(modelID).contextWindow
    }

    // "claude-opus-4-1-…", "claude-sonnet-4-20250514-…" (4.0: the date is not a minor version),
    // "claude-3-7-sonnet-…", "claude-3-haiku-…".
    private static let claudeNew = try! NSRegularExpression(
        pattern: #"claude-(?<family>opus|sonnet|haiku|fable|mythos)-(?<major>\d+)(?:-(?<minor>\d)(?!\d))?"#)
    private static let claudeOld = try! NSRegularExpression(
        pattern: #"claude-(?<major>\d)-(?:(?<minor>\d)-)?(?<family>opus|sonnet|haiku)"#)

    public static func traits(_ modelID: String) -> BedrockModelTraits {
        let id = baseID(modelID) ?? modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.contains("anthropic.claude") || id.hasPrefix("claude") { return claude(id) }

        var traits = BedrockModelTraits()
        if id.contains("amazon.nova") {
            traits.contextWindow = id.contains("nova-micro") ? 128_000 : id.contains("nova-premier") ? 1_000_000 : 300_000
            traits.cachePoints = true
            traits.toolResultStatus = true
            traits.documents = true
            return traits
        }
        if id.hasPrefix("meta.llama") {
            traits.contextWindow = 128_000
        } else if id.contains("mistral-large-2402") {
            traits.contextWindow = 32_000
        } else if id.contains("mistral-large") || id.contains("pixtral-large") {
            traits.contextWindow = 128_000
        } else if id.hasPrefix("mistral.") {
            traits.contextWindow = 32_000
        } else if id.hasPrefix("deepseek.") || id.contains("gpt-oss") || id.hasPrefix("qwen.") {
            traits.contextWindow = 128_000
        }
        // Llama on Bedrock caps a reply at 2048 tokens; reasoning models need room to think.
        if id.hasPrefix("meta.llama") {
            traits.defaultMaxTokens = 2048
        } else if id.hasPrefix("deepseek.r1") {
            traits.defaultMaxTokens = 16_384
        } else if id.hasPrefix("deepseek.") || id.contains("gpt-oss") || id.hasPrefix("qwen.") {
            traits.defaultMaxTokens = 8192
        }
        return traits
    }

    private static func claude(_ id: String) -> BedrockModelTraits {
        let family: String
        let version: Double
        if let (found, number) = placeClaude(id) {
            family = found
            version = number
        } else if id.contains("claude-v2") || id.contains("claude-instant") {
            family = "legacy"
            version = 2
        } else {
            // A Claude we can't place is newer than this table: assume the current generation.
            family = "unknown"
            version = 99
        }

        // Prompt caching on Bedrock starts with Claude 3.5 Haiku and 3.7 Sonnet.
        let caches = version >= 3.7 || (family == "haiku" && version >= 3.5)
        var claude = BedrockModelTraits()
        claude.isClaude = true
        claude.toolResultStatus = true
        claude.documents = true
        claude.contextWindow = 200_000
        claude.cachePoints = caches
        claude.toolCachePoint = caches
        if version < 3.7 {
            claude.defaultMaxTokens = version >= 3.5 ? 8192 : 4096
            claude.maxTokensCeiling = version >= 3.5 ? 8192 : 4096
            return claude
        }
        if version < 4.6 {
            // 3.7 – 4.5 think with a budget. Opus 4 and 4.1 stop at 32K output, the rest at 64K.
            claude.thinking = .budget
            claude.defaultMaxTokens = 16_000
            claude.maxTokensCeiling = family == "opus" && version < 4.5 ? 32_000 : 64_000
            return claude
        }
        claude.thinking = .adaptive
        claude.contextWindow = 1_000_000
        claude.defaultMaxTokens = 16_000
        claude.maxTokensCeiling = 128_000
        if version < 4.7 { return claude } // 4.6: sampling allowed, summaries by default, no thinking unless asked
        claude.sampling = false
        claude.summarizedThinking = true
        if version < 5 { return claude }   // 4.7, 4.8
        if family == "sonnet" && version >= 5.5 && version < 6 {
            claude.off = .betweenTools
        } else if (family == "opus" || family == "sonnet") && version < 5.5 {
            claude.off = .disabled
        } else {
            claude.off = .lowEffort
        }
        return claude
    }

    /// The family and version ("opus", 5.5) a Claude id names — a Bedrock id or Anthropic's own
    /// ("claude-opus-5-5") — if it names one.
    public static func claudeVersion(_ modelID: String) -> (family: String, version: Double)? {
        let id = baseID(modelID) ?? modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let (family, version) = placeClaude(id) else { return nil }
        return (family, version)
    }

    /// The family and version ("sonnet", 4.5) a Claude id names, if it names one.
    private static func placeClaude(_ id: String) -> (String, Double)? {
        let whole = NSRange(id.startIndex..., in: id)
        for regex in [claudeNew, claudeOld] {
            guard let match = regex.firstMatch(in: id, range: whole) else { continue }
            func group(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : Range(range, in: id).map { String(id[$0]) }
            }
            guard let family = group("family"), let major = group("major").flatMap({ Int($0) }) else { continue }
            let minor = group("minor").flatMap { Int($0) }
            // Double arithmetic, so the comparisons above see exactly the literals they name (4 + 6/10.0 == 4.6).
            return (family, Double(major) + (minor.map { Double($0) / 10.0 } ?? 0))
        }
        return nil
    }
}
