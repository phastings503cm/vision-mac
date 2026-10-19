import Foundation

// MARK: - Wire shapes (OpenAI-compatible chat completion, our internal currency)

/// A chat message in provider-neutral form.
public struct LLMMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String?
    /// Assistant tool calls, emitted after the message completes.
    public var toolCalls: [ToolCall]?
    /// For `role == .tool`: the call this result answers.
    public var toolCallID: String?
    /// For `role == .tool`: the tool that produced it.
    public var name: String?
    /// User-attached files/images sent alongside the text.
    public var attachments: [MessageAttachment]?
    /// Set on the synthetic user message that carries images a tool produced
    /// (names of the tools). Such messages are pruned to the newest few so a
    /// long debugging session doesn't fill the window with old screenshots.
    public var imageSource: String?
    /// For assistant messages: opaque provider data that must be sent back
    /// verbatim with this message (copied from `LLMStreamEvent.done`'s
    /// `providerState`) — e.g. Claude's signed reasoning on Bedrock, which
    /// Claude insists on seeing again while it works through the tool calls of
    /// that turn. Only the client that wrote it reads it; the others ignore
    /// it. Lost when a transcript is rebuilt from text (compaction, replay),
    /// which every reader must tolerate.
    public var providerState: String?

    public init(role: Role,
                content: String? = nil,
                toolCalls: [ToolCall]? = nil,
                toolCallID: String? = nil,
                name: String? = nil,
                attachments: [MessageAttachment]? = nil,
                imageSource: String? = nil,
                providerState: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.attachments = attachments
        self.imageSource = imageSource
        self.providerState = providerState
    }

    public static func user(_ text: String, attachments: [MessageAttachment]? = nil) -> LLMMessage {
        .init(role: .user, content: text, attachments: attachments)
    }
    public static func system(_ text: String) -> LLMMessage {
        .init(role: .system, content: text)
    }
    public static func assistant(_ text: String, calls: [ToolCall] = []) -> LLMMessage {
        .init(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls)
    }
    public static func toolResult(id: String, name: String, output: String) -> LLMMessage {
        .init(role: .tool, content: output, toolCallID: id, name: name)
    }
}

/// A file or image the user attaches to a message.
public struct MessageAttachment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
        case file
    }
    public var kind: Kind
    public var name: String
    /// Raw content (base64-encoded on the wire for images, and for a PDF sent as a native document).
    public var data: Data
    /// What Vision read out of the file when it was attached (`AttachmentReader`); nil for one nobody read.
    public var digest: AttachmentDigest?
    /// The text sent in its place on a route that doesn't take the file itself: a header and the file's text, or —
    /// for a long one — its contents list and first parts (`AttachmentPrep`). For an image, what a model that can't
    /// take images gets (the OCR text). Nil until the message is prepared.
    public var text: String?
    /// How many parts the file's text was split into (1 = sent whole); nil until the message is prepared.
    public var parts: Int?

    public init(kind: Kind, name: String, data: Data, digest: AttachmentDigest? = nil, text: String? = nil,
                parts: Int? = nil) {
        self.kind = kind
        self.name = name
        self.data = data
        self.digest = digest
        self.text = text
        self.parts = parts
    }

    /// The MIME type: a picture's own bytes decide (the composer re-encodes pictures to PNG under their original
    /// name), else the filename extension.
    public var mime: String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if head.count >= 12, head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }
}

/// One tool call requested by the model.
public struct ToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// JSON-encoded arguments, as sent by the model.
    public let arguments: JSONString

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = JSONString(arguments)
    }
}

/// A string we pass around as raw JSON.
public struct JSONString: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { self.init(value) }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// MARK: - Tool specifications (what we tell the model)

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for arguments, as an object.
    public let parameters: String
}

// MARK: - Provider profiles

public struct ProviderProfile: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ollama        // 127.0.0.1:11434/v1
        case lmStudio      // 127.0.0.1:1234/v1
        case openAICompat  // any OpenAI-compatible server (vLLM, DGX Spark, ...)
        case openAI
        case openRouter
        /// Amazon Bedrock: the Converse API, signed with AWS credentials (the
        /// AWS CLI's sign-in) or authorised with a Bedrock API key.
        case bedrock
        /// Guardian (guardian.503cm.com): the account's models behind one
        /// OpenAI-compatible proxy, signed in with the Guardian login. The
        /// same account also shares prompts, skills, chats and code projects
        /// with every harness on it (see `GuardianClient`).
        case guardian
        /// Anthropic's own API (api.anthropic.com/v1): Claude on the Messages API with an API key from
        /// console.anthropic.com — streaming, tools, images, PDFs, extended thinking and prompt caching
        /// (see `AnthropicClient`). Made by the plan guide ("Anthropic API (key)").
        case anthropic
        /// Claude Code: the official `claude` command on this Mac, signed in with the person's Claude Pro or
        /// Max plan. A chat on it runs each turn as `claude -p` (stream-json in and out) in the chat's folder;
        /// the CLI does all the talking to Anthropic — Vision never reads or reuses its sign-in. The model is
        /// a Claude Code alias ("opus", "sonnet", "haiku") or "default". See `ClaudeCodeTurn`.
        case claudeCode

        /// The kinds the editor offers for a route made by hand. A Bedrock
        /// route comes from its guide (profile, Region and model together);
        /// Guardian comes from its wizard page (a sign-in, not a key).
        public static var manual: [Kind] { [.openAICompat, .ollama, .lmStudio, .openAI, .openRouter] }
    }

    public var kind: Kind
    public var name: String
    public var baseURL: String
    public var apiKey: String?
    public var model: String
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// Explicit context-window override in tokens. When set, it wins over the
    /// server probe and the well-known fallback tables. Optional properties
    /// decode from saved profiles that predate this field (missing → nil).
    public var contextWindow: Int?
    /// Extra HTTP headers sent with every request (e.g. auth tokens, org IDs).
    public var customHeaders: [String: String]?
    /// Default thinking level for this route, stored as a `ThinkingLevel` raw
    /// value ("off", "low", "medium", "high", "max"); nil = the server's own
    /// default. (Older builds stored "low"/"medium"/"high" here, which decode
    /// unchanged.) Sessions can override it — see `ThinkingLevel`.
    public var reasoningEffort: String?
    /// Whether the model can take images (screenshots from the screen tools).
    /// nil = assume yes; false makes tools return text only.
    public var vision: Bool?
    /// Bedrock: the AWS CLI profile whose sign-in is used (e.g. "vision-bedrock").
    /// Nil together with an API key = authenticate with that Bedrock API key.
    public var awsProfile: String?
    /// Bedrock: the AWS Region to call (e.g. "us-east-1").
    public var awsRegion: String?
    /// Use this server for subagents while another route is the main model —
    /// a second DGX Spark takes the side tasks so they run in parallel with
    /// the main one. Kept on every route, including the main one, so swapping
    /// the main model never forgets which servers were helping; it only takes
    /// effect while the route is not the main one. Nil = not a worker.
    public var subagentWorker: Bool?
    /// How many subagents may work on this server at once (nil = 2 for a
    /// worker, 4 for the main route).
    public var subagentParallel: Int?
    /// SHA-256 fingerprint ("3A:9F:…:C2", as openssl prints it) of a
    /// self-signed certificate this server is trusted to present — a Spark
    /// Swapper's HTTPS front on :11443, say. Checked only when normal trust
    /// fails; nil = normal trust only.
    public var pinnedCertificate: String?
    /// Off = never used: not the main model, not a subagent server, not a
    /// backup — it stays in the list, greyed. Nil = on.
    public var enabled: Bool?
    /// Take over a turn when the main model stops answering (see
    /// `FailoverClient`). Nil = no.
    public var backup: Bool?
    /// May see sensitive data. Nil = decided by the address (see
    /// `RoutePrivacy`); an explicit choice is stored and wins.
    public var isPrivate: Bool?
    /// The plan's terms allow only interactive use (the Qwen Coding Plan):
    /// the task queue and other unattended runs don't start on it. Nil = no.
    public var interactiveOnly: Bool?

    public init(kind: Kind, name: String, baseURL: String, apiKey: String? = nil,
                model: String, temperature: Double? = nil, maxOutputTokens: Int? = nil,
                contextWindow: Int? = nil,
                customHeaders: [String: String]? = nil, reasoningEffort: String? = nil,
                vision: Bool? = nil,
                awsProfile: String? = nil, awsRegion: String? = nil,
                subagentWorker: Bool? = nil, subagentParallel: Int? = nil,
                pinnedCertificate: String? = nil, enabled: Bool? = nil, backup: Bool? = nil,
                isPrivate: Bool? = nil, interactiveOnly: Bool? = nil) {
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.contextWindow = contextWindow
        self.customHeaders = customHeaders
        self.reasoningEffort = reasoningEffort
        self.vision = vision
        self.awsProfile = awsProfile
        self.awsRegion = awsRegion
        self.subagentWorker = subagentWorker
        self.subagentParallel = subagentParallel
        self.pinnedCertificate = pinnedCertificate
        self.enabled = enabled
        self.backup = backup
        self.isPrivate = isPrivate
        self.interactiveOnly = interactiveOnly
    }

    /// Stable identity for a configured route: survives reordering, and two
    /// models on the same server stay distinct.
    public var routeID: String { Self.routeID(name: name, model: model) }

    /// The identity of a route with this name and model.
    public static func routeID(name: String, model: String) -> String { "\(name)|\(model)" }

    /// Whether this route is flagged to serve subagents (see `subagentWorker`).
    public var isSubagentWorker: Bool { subagentWorker ?? false }
    /// Whether the route is switched on (see `enabled`).
    public var isEnabled: Bool { enabled ?? true }
    /// Whether the route takes over when the main model fails (see `backup`).
    public var isBackup: Bool { backup ?? false }
    /// Whether the plan behind the route is for interactive use only (see `interactiveOnly`).
    public var isInteractiveOnly: Bool { interactiveOnly ?? false }
    /// Whether the route may see sensitive data: the user's explicit choice, else the default for its address
    /// (your own hardware is private; an online service is not). A route whose engine reads files itself
    /// (Claude Code) is never private, whatever was stored.
    public var isPrivateRoute: Bool { readsFilesDirectly ? false : (isPrivate ?? RoutePrivacy.isPrivateByDefault(self)) }
    /// The engine behind the route reads files and runs commands itself and sends what it reads to its own
    /// service (Claude Code), so Vision's shield can't mask it: never for a Sensitive chat.
    public var readsFilesDirectly: Bool { kind == .claudeCode }
    /// The route can run Vision's own engine (chat completions with Vision's tools), so it can serve subagents
    /// and stand in as a backup. Claude Code runs its own agent loop instead: it is only ever a chat's engine.
    public var runsVisionEngine: Bool { kind != .claudeCode }
    /// The base URL every Claude Code route carries (the CLI is found on this Mac at run time).
    public static let claudeCodeBaseURL = "claude-code://local"

    public static let presets: [ProviderProfile] = [
        .init(kind: .ollama, name: "Ollama (local)", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"),
        .init(kind: .lmStudio, name: "LM Studio (local)", baseURL: "http://127.0.0.1:1234/v1", model: "local-model"),
        .init(kind: .openAICompat, name: "DGX Spark / vLLM (LAN)", baseURL: "http://DGX-SPARK-ADDRESS:8002/v1", model: "my-ai"),
        .init(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o"),
        .init(kind: .openRouter, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "qwen/qwen3-32b"),
    ]

    public func endpoint(path: String) -> String {
        baseURL.hasSuffix("/") ? "\(baseURL)\(path)" : "\(baseURL)/\(path)"
    }

    /// The route's default thinking level (nil = leave it to the server).
    public var thinking: ThinkingLevel? {
        get { reasoningEffort.flatMap(ThinkingLevel.init(rawValue:)) }
        set { reasoningEffort = newValue?.rawValue }
    }

    /// True for a server you run yourself (vLLM, SGLang, llama.cpp, Ollama,
    /// LM Studio …) as opposed to a hosted API. Decided by host, not `kind`:
    /// a Spark behind nginx is often configured as kind "OpenAI" because it
    /// speaks the same protocol, and it still wants `chat_template_kwargs`.
    public var isSelfHosted: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return true }
        return !Self.hostedServices.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Hosted APIs, by domain (a host is one of them, or under one). Everything
    /// else is taken to be a server you run yourself.
    public static let hostedServices = [
        "openai.com", "openrouter.ai", "anthropic.com", "groq.com", "together.xyz",
        "together.ai", "fireworks.ai", "mistral.ai", "deepseek.com", "x.ai",
        "googleapis.com", "azure.com", "cerebras.ai", "perplexity.ai",
        "amazonaws.com", "api.aws",
        // The subscription plans (see `PlanCatalog`): Z.ai / BigModel, Kimi / Moonshot, Alibaba Cloud.
        "z.ai", "bigmodel.cn", "kimi.ai", "kimi.com", "moonshot.ai", "moonshot.cn",
        "aliyuncs.com", "alibabacloud.com",
    ]
}

// MARK: - Thinking / reasoning effort

/// How hard a reasoning model should think before answering.
///
/// On the wire this becomes, for self-hosted OpenAI-compatible servers
/// (vLLM / SGLang serving Qwen3.x, GLM, DeepSeek, gpt-oss …):
///   - `chat_template_kwargs.enable_thinking` (false for `.off`), and
///   - `reasoning_effort` both top-level and inside `chat_template_kwargs`,
///     which is where Qwen3.8's template reads it.
/// For hosted APIs only the top-level `reasoning_effort` is sent.
///
/// Templates disagree on the vocabulary (Qwen3.8 accepts low/medium/xhigh,
/// gpt-oss low/medium/high). The client learns the accepted set from the
/// server's 400 and remaps automatically — see `ReasoningEffortCache`.
public enum ThinkingLevel: String, Codable, CaseIterable, Sendable, Hashable {
    case off, low, medium, high, max

    public var label: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .max: "Max"
        }
    }

    public var blurb: String {
        switch self {
        case .off: "No thinking — fastest replies"
        case .low: "Brief thinking"
        case .medium: "Balanced"
        case .high: "Careful"
        case .max: "Deepest (slowest)"
        }
    }

    public var symbol: String {
        switch self {
        case .off: "hare"
        case .low: "gauge.with.dots.needle.0percent"
        case .medium: "gauge.with.dots.needle.33percent"
        case .high: "gauge.with.dots.needle.67percent"
        case .max: "gauge.with.dots.needle.100percent"
        }
    }

    /// The effort word we try first; nil for `.off`.
    public var wireEffort: String? {
        switch self {
        case .off: nil
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "xhigh"
        }
    }

    /// Parse user input like "/think high", "fast", "none", "xhigh".
    public init?(userInput raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "off", "none", "no", "fast", "0", "false", "disable", "disabled": self = .off
        case "low", "light", "minimal", "1": self = .low
        case "medium", "med", "mid", "normal", "2": self = .medium
        case "high", "hard", "slow", "3": self = .high
        case "max", "xhigh", "maximum", "highest", "deep", "4": self = .max
        default: return nil
        }
    }
}

/// Metadata about a model, used to size the context gauge in the UI.
///
/// `contextWindow` is the model's total input+output token budget. Servers that
/// expose it (Ollama, LM Studio, OpenRouter, some vLLM builds) report it on
/// `GET /v1/models`; for the rest we fall back to the well-known tables below
/// or a conservative default.
public struct ModelInfo: Codable, Hashable, Sendable {
    /// The id the server actually serves for this route. Usually the
    /// configured model; when that isn't served but the server serves exactly
    /// one model (a box that swaps models, e.g. the Spark swapper), it is that
    /// one — the app follows it instead of failing with "model not found".
    public var id: String
    public var contextWindow: Int?
    public var maxTokens: Int?
    /// Every model id the server listed (empty when `/models` didn't answer).
    public var servedModels: [String]

    public init(id: String, contextWindow: Int? = nil, maxTokens: Int? = nil,
                servedModels: [String] = []) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.servedModels = servedModels
    }
}

// MARK: - Requests / responses

public struct LLMRequest: Sendable {
    public let systemPrompt: String
    public let messages: [LLMMessage]
    public let tools: [ToolSpec]
    public let model: String
    public let temperature: Double?
    public let maxTokens: Int?
    /// Thinking level for this request; nil = the provider profile's default.
    public let thinking: ThinkingLevel?

    public init(systemPrompt: String, messages: [LLMMessage], tools: [ToolSpec],
                model: String, temperature: Double? = nil, maxTokens: Int? = nil,
                thinking: ThinkingLevel? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
    }
}

public struct LLMUsage: Codable, Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    /// How much of the prompt the server served from its prompt cache, when it
    /// says so (nil = unknown).
    public var cachedTokens: Int?
    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
    }

    /// This usage plus `other` (nil-safe on either side).
    public static func sum(_ a: LLMUsage?, _ b: LLMUsage?) -> LLMUsage? {
        guard let a else { return b }
        guard let b else { return a }
        let cached = (a.cachedTokens == nil && b.cachedTokens == nil) ? nil : (a.cachedTokens ?? 0) + (b.cachedTokens ?? 0)
        return LLMUsage(promptTokens: a.promptTokens + b.promptTokens,
                        completionTokens: a.completionTokens + b.completionTokens,
                        cachedTokens: cached)
    }
}

/// What the engine consumes from a streaming client.
///
/// The client accumulates partial `tool_calls` internally and hands the engine
/// complete calls at the end, so the engine never deals in fragments.
public enum LLMStreamEvent: Sendable {
    /// A text delta to append to the assistant message.
    case text(String)
    /// A reasoning ("thinking") delta — `reasoning_content` from a vLLM/SGLang
    /// reasoning parser, or OpenRouter's `reasoning`. Shown live, never sent back.
    case reasoning(String)
    /// The stream finished: complete tool calls (may be empty) + metadata.
    /// `providerState` is opaque data the caller must store on the assistant
    /// message this turn becomes (`LLMMessage.providerState`) so it is sent
    /// back verbatim — e.g. signed reasoning. Nil for providers that need nothing.
    case done(calls: [ToolCall], finish: String?, usage: LLMUsage?, providerState: String? = nil)
}

/// Transport errors with user-actionable guidance (wizard smoke test uses this).
public enum LLMError: LocalizedError, Sendable {
    case noModel
    case connection(String)
    case http(Int, String)
    /// The server refused the request because it would exceed the model's
    /// context window, and told us the limit in the error body (SGLang/vLLM do:
    /// "maximum context length is 262144 tokens"). The caller should compact
    /// the transcript and retry once.
    case overflow(limit: Int, detail: String)
    case sse(String)
    case unsupported(String)
    /// An HTTP-class refusal the provider client has already put into plain
    /// words (Bedrock's AccessDenied → "enable access to the model"; an AWS
    /// sign-in that ran out). Retried by `status` like `.http` unless
    /// `permanent`; `body` is the server's own wording, for the retry status line.
    case rejected(status: Int, message: String, body: String, permanent: Bool)

    public var errorDescription: String? {
        switch self {
        case .noModel: "No model is configured. Run the setup wizard or pick a model in Settings."
        case .connection(let why):
            "Could not reach the model server (\(why)). Is it running and is the address right?"
        case .http(let code, let body): "The model server replied \(code): \(String(body.prefix(300)))"
        case .rejected(_, let message, _, _): message
        case .overflow(let limit, let detail):
            limit > 0
                ? "Conversation is too long for the \(limit.formatted())-token window (\(detail.prefix(120)))."
                : "Conversation is too long for the server (\(detail.prefix(120)))."
        case .sse(let why): "The model stream ended unexpectedly (\(why))."
        case .unsupported(let what): "\(what) is not supported yet."
        }
    }
}

/// A streaming chat client — the seam the engine tests against mocks.
/// Must be `@Sendable`-friendly: implementations may outlive the engine turn.
public protocol LLMClient: Sendable {
    /// Stream one model turn. Emits `.text` deltas then exactly one `.done`.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// Liveness + capability probe: returns the server's model list.
    func listModels() async throws -> [String]
}