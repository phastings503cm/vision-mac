import Foundation

// MARK: - Learning what a server refuses
//
// The rules table (`ModelRequestRules`) gets the known providers right. For the rest — a new model id, a proxy, a
// provider that changed its mind — the server's own 400 says what it didn't like: "invalid temperature: only 1 is
// allowed for this model", "Unsupported parameter: 'max_tokens' … Use 'max_completion_tokens' instead", vLLM's
// "Extra inputs are not permitted" on `chat_template_kwargs`, Z.ai's "Invalid API parameter". The client then
// retries once without that parameter, remembers the lesson for that server and model (on disk, so the next launch
// starts right), and tells the chat in one line instead of failing the turn.

/// One lesson: what to change in requests to a server and model.
public enum RequestChange: Equatable, Sendable, Hashable {
    /// Leave this body key out ("temperature", "thinking", "chat_template_kwargs.enable_thinking", …).
    case drop(String)
    /// Send this key under another name ("max_tokens" → "max_completion_tokens").
    case rename(from: String, to: String)
    /// The server refused a parameter without naming it: send only the basics (model, messages, stream, tools).
    case minimal
    /// The server wants the model's reasoning back on assistant messages that called tools (`reasoning_content`).
    case echoReasoning
}

/// What was learned for one server and model.
public struct RequestAdaptation: Codable, Equatable, Sendable {
    public var dropped: [String] = []
    public var renamed: [String: String] = [:]
    public var minimal = false
    public var echoReasoning = false
    public var learnedAt = Date()

    public init() {}

    public var isEmpty: Bool { dropped.isEmpty && renamed.isEmpty && !minimal && !echoReasoning }

    /// Whether this lesson is already part of it.
    public func contains(_ change: RequestChange) -> Bool {
        switch change {
        case .drop(let key): dropped.contains(key) || (minimal && RequestBody.optionalKeys.contains(key))
        case .rename(let from, let to): renamed[from] == to
        case .minimal: minimal
        case .echoReasoning: echoReasoning
        }
    }

    mutating func apply(_ change: RequestChange) {
        switch change {
        case .drop(let key): if !dropped.contains(key) { dropped.append(key) }
        case .rename(let from, let to): renamed[from] = to
        case .minimal: minimal = true
        case .echoReasoning: echoReasoning = true
        }
        learnedAt = Date()
    }

    /// In a line, for Settings: "no temperature, thinking; max_completion_tokens instead of max_tokens".
    public var summary: String {
        var parts: [String] = []
        if minimal { parts.append("only the basic settings") }
        if !dropped.isEmpty { parts.append("no " + dropped.joined(separator: ", ")) }
        for (from, to) in renamed.sorted(by: { $0.key < $1.key }) { parts.append("\(to) instead of \(from)") }
        if echoReasoning { parts.append("its reasoning sent back with tool calls") }
        return parts.joined(separator: "; ")
    }
}

/// Edits on the request body (a JSON object as `[String: Any]`).
public enum RequestBody {
    /// The optional parameters `minimal` leaves out.
    public static let optionalKeys: Set<String> = [
        "temperature", "top_p", "reasoning_effort", "thinking", "chat_template_kwargs", "stream_options",
        "tool_choice", "parallel_tool_calls", "response_format", "presence_penalty", "frequency_penalty",
        "max_tokens", "max_completion_tokens", "seed", "stop",
    ]

    /// The body's parameter names, nested ones as "parent.child" (only the nested ones we ever set).
    public static func keys(_ body: [String: Any]) -> Set<String> {
        var keys = Set(body.keys)
        if let kwargs = body["chat_template_kwargs"] as? [String: Any] {
            for key in kwargs.keys { keys.insert("chat_template_kwargs.\(key)") }
        }
        return keys
    }

    /// Apply what was learned.
    public static func apply(_ adaptation: RequestAdaptation, to body: inout [String: Any]) {
        if adaptation.minimal {
            for key in optionalKeys { body.removeValue(forKey: key) }
        }
        for key in adaptation.dropped { remove(key, from: &body) }
        for (from, to) in adaptation.renamed {
            if let value = body.removeValue(forKey: from) { body[to] = value }
        }
    }

    /// Remove a key; "parent.child" removes inside the parent object (and the parent when it is left empty).
    public static func remove(_ key: String, from body: inout [String: Any]) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { body.removeValue(forKey: key); return }
        guard var inner = body[parts[0]] as? [String: Any] else { return }
        inner.removeValue(forKey: parts[1])
        body[parts[0]] = inner.isEmpty ? nil : inner
    }
}

// MARK: - Reading a refusal

public enum ParameterRejection {
    /// Parameters a server may refuse, longest names first so "max_tokens" never matches inside
    /// "max_completion_tokens".
    /// The whole `chat_template_kwargs` comes before its parts: a server that refuses the field refuses all of it.
    static let candidates = [
        "max_completion_tokens", "chat_template_kwargs", "parallel_tool_calls", "frequency_penalty",
        "presence_penalty", "response_format", "reasoning_effort", "enable_thinking", "stream_options",
        "include_usage", "tool_choice", "temperature", "max_tokens", "thinking", "top_p", "seed",
    ]

    /// Words that say a named parameter is the problem (not merely mentioned).
    static let refusalCues = [
        "unsupported", "not supported", "does not support", "doesn't support", "not support", "invalid",
        "unknown", "unrecognized", "unrecognised", "not allowed", "not permitted", "extra inputs", "extra_forbidden",
        "extra fields", "unexpected", "only", "cannot", "can not", "can't", "must be", "not available",
        "not a valid", "is deprecated", "no longer supported", "out of range", "should be", "disabled",
    ]

    /// What `body` (a refusal: HTTP 400/422) asks to change, given the parameters the request carried. Nil when
    /// the refusal isn't about one of them.
    public static func change(status: Int, body: String, sent: Set<String>) -> RequestChange? {
        guard status == 400 || status == 422 else { return nil }
        let message = text(of: body)
        let lower = message.lowercased()

        // Kimi: "thinking is enabled but reasoning_content is missing" (an assistant tool-call message without it).
        if lower.contains("reasoning_content") && (lower.contains("missing") || lower.contains("required")) {
            return .echoReasoning
        }
        // Structured errors name the parameter: OpenAI's {"error":{"param":"max_tokens"}}, FastAPI/vLLM's
        // {"detail":[{"loc":["body","chat_template_kwargs"]}]}.
        for named in namedParameters(in: body) {
            guard let key = match(named, sent: sent) else { continue }
            return decide(key, lower: lower)
        }
        // Otherwise, a sent parameter the message names next to a refusal word.
        guard refusalCues.contains(where: { lower.contains($0) }) else { return nil }
        for key in candidates where sent.contains(key) || (key == "enable_thinking" && sent.contains("chat_template_kwargs.enable_thinking")) {
            let name = key.components(separatedBy: ".").last ?? key
            guard mentions(lower, name) else { continue }
            let resolved = key == "enable_thinking" ? "chat_template_kwargs.enable_thinking" : key
            if resolved == "include_usage" { return .drop("stream_options") }
            return decide(resolved, lower: lower)
        }
        // A refusal of "a parameter" that names none (Z.ai's 1210 "Invalid API parameter, please check the
        // documentation."): fall back to the basics, if there is anything optional to leave out.
        let nameless = lower.contains("invalid api parameter") || lower.contains("invalid parameter")
            || lower.contains("parameter is invalid") || lower.contains("parameters are invalid")
            || lower.contains("invalid request parameter") || businessCode(in: body) == "1210"
        if nameless, !sent.isDisjoint(with: RequestBody.optionalKeys) { return .minimal }
        return nil
    }

    private static func decide(_ key: String, lower: String) -> RequestChange {
        if key == "max_tokens", lower.contains("max_completion_tokens") {
            return .rename(from: "max_tokens", to: "max_completion_tokens")
        }
        if key == "max_completion_tokens", lower.contains("max_tokens") && !lower.contains("use 'max_completion_tokens'") {
            return .rename(from: "max_completion_tokens", to: "max_tokens")
        }
        return .drop(key)
    }

    /// The sent key a structured error's parameter name refers to.
    private static func match(_ named: String, sent: Set<String>) -> String? {
        let name = named.lowercased()
        if sent.contains(name) { return name }
        if name == "enable_thinking", sent.contains("chat_template_kwargs.enable_thinking") { return "chat_template_kwargs.enable_thinking" }
        if name.hasPrefix("thinking"), sent.contains("thinking") { return "thinking" }
        if name.hasPrefix("stream_options"), sent.contains("stream_options") { return "stream_options" }
        return nil
    }

    /// `name` appears as a word of its own ("temperature", not "temperatures"; "thinking" only as a parameter).
    static func mentions(_ lower: String, _ name: String) -> Bool {
        if name == "thinking" {
            // "thinking is enabled but …" is about thinking, not the `thinking` parameter.
            let shapes = ["thinking.type", "thinking type", "'thinking'", "\"thinking\"", "`thinking`",
                          "parameter thinking", "invalid thinking", "thinking parameter", "thinking is not supported",
                          "thinking: ", "thinking.keep", "thinking cannot", "thinking can not", "thinking must"]
            return shapes.contains { lower.contains($0) }
        }
        let pattern = "(?<![a-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![a-z0-9_])"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// The human-readable part of an error body.
    static func text(of body: String) -> String {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return body }
        var parts: [String] = []
        if let err = obj["error"] as? [String: Any] {
            if let m = err["message"] as? String { parts.append(m) }
            if let p = err["param"] as? String { parts.append("param \(p)") }
        } else if let err = obj["error"] as? String { parts.append(err) }
        if let m = obj["message"] as? String { parts.append(m) }
        if let detail = obj["detail"] as? String { parts.append(detail) }
        if let details = obj["detail"] as? [[String: Any]] {
            for d in details { if let m = d["msg"] as? String { parts.append(m) } }
        }
        return parts.isEmpty ? body : parts.joined(separator: " — ")
    }

    /// Parameter names a structured error points at.
    static func namedParameters(in body: String) -> [String] {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var names: [String] = []
        if let err = obj["error"] as? [String: Any], let p = err["param"] as? String, !p.isEmpty { names.append(p) }
        if let details = obj["detail"] as? [[String: Any]] {
            for d in details {
                guard let loc = d["loc"] as? [Any] else { continue }
                let path = loc.compactMap { $0 as? String }.filter { $0 != "body" }
                if path.count >= 2, path[0] == "chat_template_kwargs" { names.append("chat_template_kwargs.\(path[1])") }
                if let first = path.first { names.append(first) }
            }
        }
        return names
    }

    /// A Z.ai-style business code (`{"error":{"code":"1210"}}`), as text.
    public static func businessCode(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any] else { return nil }
        if let s = err["code"] as? String { return s }
        if let n = err["code"] as? Int { return String(n) }
        return nil
    }

    /// The one line the chat shows after a lesson.
    public static func notice(_ change: RequestChange, provider: String, model: String) -> String {
        let who = "\(provider) (\(model))"
        switch change {
        case .drop(let key):
            let name = key.components(separatedBy: ".").last ?? key
            return "\(who) doesn't take `\(name)` — Vision stopped sending it for this model and carried on."
        case .rename(let from, let to):
            return "\(who) wants `\(to)` instead of `\(from)` — Vision switched and carried on."
        case .minimal:
            return "\(who) refused one of Vision's optional settings without saying which — Vision now sends only the basics to this model."
        case .echoReasoning:
            return "\(who) wants the model's reasoning sent back with its tool calls — Vision now does that for this model."
        }
    }
}

// MARK: - The memory

/// Per server and model, what was learned — kept in a small JSON file (the app sets `fileURL`), shared by every
/// chat and subagent, so a lesson is learned once.
public final class RequestAdaptationStore: @unchecked Sendable {
    public static let shared = RequestAdaptationStore()

    private let lock = NSLock()
    private var map: [String: RequestAdaptation] = [:]
    private var url: URL?

    public init(fileURL: URL? = nil) {
        if let fileURL { load(fileURL) }
    }

    /// Where the lessons live; setting it reads what is there.
    public var fileURL: URL? {
        get { lock.withLock { url } }
        set { if let newValue { load(newValue) } else { lock.withLock { url = nil } } }
    }

    /// The key for a server and model: the base URL (lower-cased, no trailing slash) and the model id.
    public static func key(baseURL: String, model: String) -> String {
        let base = baseURL.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)|\(model)"
    }

    public func adaptation(for key: String) -> RequestAdaptation? {
        lock.withLock { map[key] }
    }

    /// Everything learned, by key (for Settings).
    public var all: [String: RequestAdaptation] { lock.withLock { map } }

    /// Remember a lesson. Returns false when it was already known.
    @discardableResult
    public func learn(_ change: RequestChange, for key: String) -> Bool {
        let (changed, snapshot, target): (Bool, [String: RequestAdaptation], URL?) = lock.withLock {
            var entry = map[key] ?? RequestAdaptation()
            if entry.contains(change) { return (false, map, url) }
            entry.apply(change)
            map[key] = entry
            return (true, map, url)
        }
        if changed, let target { Self.write(snapshot, to: target) }
        return changed
    }

    /// Forget what was learned for keys starting with `prefix` (a server's base URL), or everything.
    public func forget(prefix: String? = nil) {
        let (snapshot, target): ([String: RequestAdaptation], URL?) = lock.withLock {
            if let prefix {
                let p = prefix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                map = map.filter { !$0.key.hasPrefix(p) }
            } else {
                map.removeAll()
            }
            return (map, url)
        }
        if let target { Self.write(snapshot, to: target) }
    }

    private func load(_ fileURL: URL) {
        let loaded: [String: RequestAdaptation]
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([String: RequestAdaptation].self, from: data)) ?? [:]
        } else {
            loaded = [:]
        }
        lock.withLock {
            url = fileURL
            map = loaded
        }
    }

    private static func write(_ map: [String: RequestAdaptation], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
