import Foundation

// MARK: - The sensitive-data shield
//
// A transparent wrapper around the client of a route that isn't private. The engine, the UI and the saved chats
// never see anything different — placeholders exist only on the wire:
//  1. Outbound, two passes over the request in transcript order (the system prompt, then for each message its
//     text, its tool calls' arguments — the raw JSON and the string values in it — and its attached text files):
//     a. collect: every distinct value the detectors find gets a placeholder, numbered per kind in order of first
//        appearance: ⟦EMAIL_1⟧, ⟦SECRET_1⟧ …;
//     b. replace: every occurrence of every collected value, anywhere in the request, becomes its placeholder.
//     A value is often recognised only by its surroundings (`password: …`, `Bearer …`, `user:…@host`), and once the
//     model has used its placeholder the app puts the real value back in the transcript, bare — the second pass is
//     what keeps it masked there on the next turn. The same value always gets the same placeholder, and because
//     the transcript only grows, from one turn to the next as well (which keeps the provider's prompt cache
//     working) — so no mapping is stored anywhere.
//  2. A note at the end of the system prompt tells the model what the placeholders are.
//  3. Inbound, placeholders in text, reasoning and tool-call arguments become the real values again before
//     anything leaves the wrapper — inside JSON string values, with proper escaping.
//  4. Afterwards it reports how many values of each kind were masked (never the values themselves).

/// What was masked in one request.
public struct ShieldReport: Sendable, Equatable {
    /// The route it went to.
    public var route: String
    /// Distinct values masked, by kind.
    public var counts: [SensitiveCategory: Int]
    /// The request carried pictures, or files that aren't plain text (a PDF), which can't be checked.
    public var unchecked: Bool

    public init(route: String, counts: [SensitiveCategory: Int], unchecked: Bool = false) {
        self.route = route
        self.counts = counts
        self.unchecked = unchecked
    }

    public var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }

    /// "Masked 2 emails and 1 key before sending to Kimi Code"
    public var summary: String? {
        let parts = SensitiveCategory.allCases.compactMap { category in
            counts[category].flatMap { $0 > 0 ? category.counted($0) : nil }
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Masked \(list) before sending to \(route)"
    }

    /// The kinds masked, for the chip's details ("Email addresses, Secrets and keys") — never the values.
    public var categories: String {
        var names: [String] = []
        for category in SensitiveCategory.allCases where (counts[category] ?? 0) > 0 {
            let name = category.settingName
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: ", ")
    }
}

/// The placeholders of one request: each distinct value has one, numbered per kind in order of first appearance.
public struct ShieldMap: Sendable, Equatable {
    private(set) var byValue: [String: String] = [:]
    private(set) var byPlaceholder: [String: String] = [:]
    private var next: [SensitiveCategory: Int] = [:]
    /// Distinct values, by kind.
    public private(set) var counts: [SensitiveCategory: Int] = [:]
    /// The values, in the order they were found.
    public private(set) var values: [String] = []

    public init() {}

    public var isEmpty: Bool { byValue.isEmpty }

    /// The placeholder for `value`, made the first time it is found.
    @discardableResult
    mutating func collect(_ value: String, _ category: SensitiveCategory) -> String {
        if let known = byValue[value] { return known }
        let n = (next[category] ?? 0) + 1
        next[category] = n
        counts[category, default: 0] += 1
        let placeholder = "⟦\(category.tag)_\(n)⟧"
        byValue[value] = placeholder
        byPlaceholder[placeholder] = value
        values.append(value)
        return placeholder
    }

    /// The placeholder of a value found earlier.
    public func placeholder(for value: String) -> String? { byValue[value] }

    /// The real value behind a placeholder.
    public func value(of placeholder: String) -> String? { byPlaceholder[placeholder] }

    /// `text` with every known placeholder back to its value (unknown ones stay as they are).
    public func restore(_ text: String) -> String {
        guard !byPlaceholder.isEmpty, text.contains("⟦") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in SensitiveDetector.placeholderRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            guard let value = byPlaceholder[token] else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + value
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return text }
        return out + ns.substring(from: last)
    }
}

/// Puts placeholders back in streamed text. Text arrives in pieces, so a trailing partial placeholder (`⟦EMA`) is
/// held back — at most 32 characters — until it completes or clearly isn't one; `flush` lets go of the rest.
public struct PlaceholderRestorer: Sendable {
    let map: ShieldMap
    private var pending = ""
    static let longest = 32

    public init(map: ShieldMap) { self.map = map }

    /// The text that can go out now.
    public mutating func feed(_ chunk: String) -> String {
        pending += chunk
        if let open = pending.lastIndex(of: "⟦") {
            let tail = pending[open...]
            if !tail.contains("⟧"), tail.count <= Self.longest, Self.couldBePlaceholder(tail) {
                let ready = String(pending[..<open])
                pending = String(tail)
                return map.restore(ready)
            }
        }
        let ready = pending
        pending = ""
        return map.restore(ready)
    }

    /// Whatever is still held back.
    public mutating func flush() -> String {
        let rest = pending
        pending = ""
        return map.restore(rest)
    }

    /// `⟦`, `⟦EM`, `⟦EMAIL_`, `⟦EMAIL_1` — the start of a placeholder.
    static func couldBePlaceholder(_ tail: Substring) -> Bool {
        var sawUnderscore = false
        for ch in tail.dropFirst() {
            if ch == "_" {
                if sawUnderscore { return false }
                sawUnderscore = true
            } else if sawUnderscore {
                guard ch.isASCII, ch.isNumber else { return false }
            } else {
                guard ch.isASCII, ch.isUppercase else { return false }
            }
        }
        return true
    }
}

public enum Shield {
    /// What the model is told about the placeholders.
    public static let note = "Privacy: some values in this conversation were replaced with placeholders such as ⟦EMAIL_1⟧ or ⟦SECRET_1⟧ before they reached you. Use a placeholder exactly as written wherever you need that value — in replies, code or tool calls — and the app puts the real value back on the user's computer. Don't ask for the real values and don't guess them."

    /// Values shorter than this are replaced only where a detector found them: anywhere, they would hit too much
    /// (a custom term "Al" in "Also").
    static let minimumLiteral = 4

    /// What one client has already worked out: the matches in each text (the transcript only grows, so most of it
    /// was seen before), and the matcher for the values collected last time.
    public final class MatchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [(NSRange, SensitiveCategory)]] = [:]
        private var lastMatcher: LiteralMatcher?
        private let limit: Int

        public init(limit: Int = 20_000) { self.limit = limit }

        func matches(_ text: String, _ detector: SensitiveDetector) -> [(NSRange, SensitiveCategory)] {
            if let hit = lock.withLock({ entries[text] }) { return hit }
            let found = detector.matches(in: text).map { (NSRange($0.range, in: text), $0.category) }
            lock.withLock {
                if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
                entries[text] = found
            }
            return found
        }

        /// One matcher for all of `values` (built again only when they change).
        func matcher(for values: [String]) -> LiteralMatcher {
            if let last = lock.withLock({ lastMatcher }), last.patterns == values { return last }
            let matcher = LiteralMatcher(values)
            lock.withLock { lastMatcher = matcher }
            return matcher
        }
    }

    /// A value found in raw JSON text, as it reads once decoded (`a\"b` → `a"b`).
    static func jsonUnescaped(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        return decodeLiteral("\"" + raw + "\"") ?? raw
    }

    /// Tool-call arguments with the placeholders back, inside JSON string values and escaped as JSON (quotes,
    /// backslashes, control characters). Arguments that aren't JSON get the values put back as text.
    public static func restoreArguments(_ json: String, _ map: ShieldMap) -> String {
        guard !map.isEmpty, json.contains("⟦") || json.contains("\\u27e6") || json.contains("\\u27E6") else { return json }
        return rewriteStringValues(json) { map.restore($0) } ?? map.restore(json)
    }

    /// Rewrite the decoded value of every JSON string that isn't an object key with `transform`, re-encoding the
    /// ones that changed; everything else is kept exactly. Nil when `json` isn't JSON.
    static func rewriteStringValues(_ json: String, _ transform: (String) -> String) -> String? {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        let scalars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\"" else {
                out.append(scalar)
                i += 1
                continue
            }
            // A string literal, to its closing quote.
            var j = i + 1
            while j < scalars.count {
                if scalars[j] == "\\" { j += 2; continue }
                if scalars[j] == "\"" { break }
                j += 1
            }
            let end = min(j, scalars.count - 1)
            let literal = String(String.UnicodeScalarView(scalars[i...end]))
            // A key is followed by a colon.
            var k = end + 1
            while k < scalars.count, scalars[k] == " " || scalars[k] == "\t" || scalars[k] == "\n" || scalars[k] == "\r" { k += 1 }
            let isKey = k < scalars.count && scalars[k] == ":"
            if !isKey, let decoded = decodeLiteral(literal) {
                let changed = transform(decoded)
                if changed != decoded {
                    out.append(contentsOf: ("\"" + VaultPlaceholders.jsonEscaped(changed) + "\"").unicodeScalars)
                    i = end + 1
                    continue
                }
            }
            out.append(contentsOf: literal.unicodeScalars)
            i = end + 1
        }
        return String(out)
    }

    private static func decodeLiteral(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    /// A request with its sensitive values replaced and the note added — and the placeholders it used, and
    /// whether it carries pictures or files that aren't plain text (which can't be checked).
    ///
    /// `route` is what the request's route takes besides text (`AttachmentRoute`): an attachment that goes as text
    /// there (a PDF or Word file Vision read, a picture's OCR text) is checked like any text; one whose bytes go
    /// (a picture to a vision model, a PDF document to Bedrock) can't be. Nil = assume the bytes of every picture and
    /// PDF go.
    public static func mask(_ request: LLMRequest, detector: SensitiveDetector,
                            cache: MatchCache = MatchCache(),
                            route: AttachmentRoute? = nil) -> (request: LLMRequest, map: ShieldMap, unchecked: Bool) {
        var map = ShieldMap()
        var unchecked = false

        // Pass 1: collect what the detectors find, in transcript order.
        func collect(_ text: String) {
            guard !text.isEmpty else { return }
            let ns = text as NSString
            for (range, category) in cache.matches(text, detector) { map.collect(ns.substring(with: range), category) }
        }
        collect(request.systemPrompt)
        var files: [[TextAttachment?]] = []
        files.reserveCapacity(request.messages.count)
        for message in request.messages {
            if let content = message.content { collect(content) }
            for call in message.toolCalls ?? [] {
                // The raw JSON first: there a key and its value ("password":"…") read as an assignment.
                let raw = call.arguments.raw
                let ns = raw as NSString
                for (range, category) in cache.matches(raw, detector) {
                    map.collect(jsonUnescaped(ns.substring(with: range)), category)
                }
                _ = rewriteStringValues(raw) { collect($0); return $0 }
            }
            var texts: [TextAttachment?] = []
            for attachment in message.attachments ?? [] {
                let text = TextAttachment(attachment)
                if let text { collect(text.text) }
                if text == nil || TextAttachment.bytesGo(attachment, route: route) { unchecked = true }
                texts.append(text)
            }
            files.append(texts)
        }

        // Pass 2: every occurrence of every collected value becomes its placeholder — the longest at each place, never
        // inside a placeholder already there. One matcher for all the values, so a file with thousands of them takes
        // one pass, not one per value. (Values shorter than `minimumLiteral` only where they were found.)
        let values = map.values
        let literal = values.filter { $0.count >= minimumLiteral }
        let short = values.count - literal.count
        let matcher = literal.isEmpty ? nil : cache.matcher(for: literal)
        func spans(_ text: String, _ ns: NSString) -> [(location: Int, length: Int, value: String)] {
            var spans: [(location: Int, length: Int, value: String)] = []
            if let matcher {
                for found in matcher.occurrences(in: ns) {
                    spans.append((found.location, found.length, matcher.patterns[found.pattern]))
                }
            }
            if short > 0 {
                for (range, _) in cache.matches(text, detector) {
                    let value = ns.substring(with: range)
                    if value.count < minimumLiteral { spans.append((range.location, range.length, value)) }
                }
            }
            return spans
        }
        func replace(_ text: String) -> String {
            guard !values.isEmpty, !text.isEmpty else { return text }
            let ns = text as NSString
            var found = spans(text, ns)
            guard !found.isEmpty else { return text }
            found.sort { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
            let taken = SensitiveDetector.placeholderRanges(in: ns)
            var out = ""
            var last = 0, nextTaken = 0
            for span in found where span.location >= last {
                let end = span.location + span.length
                while nextTaken < taken.count, taken[nextTaken].location + taken[nextTaken].length <= span.location { nextTaken += 1 }
                if nextTaken < taken.count, taken[nextTaken].location < end { continue }
                guard let placeholder = map.placeholder(for: span.value) else { continue }
                out += ns.substring(with: NSRange(location: last, length: span.location - last)) + placeholder
                last = end
            }
            return last == 0 ? text : out + ns.substring(from: last)
        }
        /// Whether a text holds any collected value — as it is, or inside its JSON strings.
        func mentions(_ text: String) -> Bool {
            guard !values.isEmpty else { return false }
            func holds(_ text: String) -> Bool {
                let ns = text as NSString
                if let matcher, !matcher.occurrences(in: ns).isEmpty { return true }
                return short > 0 && values.contains { $0.count < minimumLiteral && ns.range(of: $0).location != NSNotFound }
            }
            if holds(text) { return true }
            var inside = false
            _ = rewriteStringValues(text) { value in
                if !inside, holds(value) { inside = true }
                return value
            }
            return inside
        }

        let system = replace(request.systemPrompt)
        var messages: [LLMMessage] = []
        messages.reserveCapacity(request.messages.count)
        for (index, original) in request.messages.enumerated() {
            var message = original
            if let content = message.content { message.content = replace(content) }
            if let calls = message.toolCalls {
                message.toolCalls = calls.map { call in
                    // Inside the JSON's string values (keys and everything else stay as they are); as text otherwise.
                    let raw = call.arguments.raw
                    return ToolCall(id: call.id, name: call.name, arguments: rewriteStringValues(raw) { replace($0) } ?? replace(raw))
                }
            }
            if let attachments = message.attachments {
                message.attachments = attachments.enumerated().map { position, attachment in
                    guard let text = files[index][position] else { return attachment }
                    return text.with(replace(text.text))
                }
            }
            // Claude's own record of a turn on Bedrock (`providerState`) is sent back verbatim: it is signed, so it
            // can't be masked. A turn that came through the shield holds placeholders and may go back as it is; one
            // written before — while the route was private, or by a model that is — can hold real values. Then it
            // stays behind: privacy before continuity. (If Bedrock then turns the request down for want of its
            // signed reasoning, that error is what the user sees, not the values sent.)
            if let state = message.providerState, mentions(state) { message.providerState = nil }
            messages.append(message)
        }
        // The note, once, at the end of the first system message.
        var prompt = system
        if !prompt.contains(note) {
            if !prompt.isEmpty {
                prompt += "\n\n" + note
            } else if let first = messages.firstIndex(where: { $0.role == .system }) {
                if !(messages[first].content ?? "").contains(note) {
                    messages[first].content = (messages[first].content ?? "") + "\n\n" + note
                }
            } else {
                prompt = note
            }
        }
        let masked = LLMRequest(systemPrompt: prompt, messages: messages, tools: request.tools, model: request.model,
                                temperature: request.temperature, maxTokens: request.maxTokens, thinking: request.thinking)
        return (masked, map, unchecked)
    }
}

/// The text an attachment goes to the model as, and how to put a masked version back: the text Vision prepared for
/// it (`MessageAttachment.text`), else what it read out of it (`AttachmentDigest.text`), else — a file nobody read —
/// its own bytes when they are plain text (UTF-8, or UTF-16 with a byte-order mark). Nil for anything else (a picture
/// or PDF nobody read, any binary file), which can't be checked.
struct TextAttachment {
    private enum Source {
        case prepared
        case digest
        case bytes(encoding: String.Encoding, mark: Data)
    }

    let attachment: MessageAttachment
    let text: String
    private let source: Source

    init?(_ attachment: MessageAttachment) {
        self.attachment = attachment
        if let prepared = attachment.text {
            text = prepared
            source = .prepared
            return
        }
        if let digest = attachment.digest, !digest.text.isEmpty {
            text = digest.text
            source = .digest
            return
        }
        guard attachment.kind == .file, attachment.mime != "application/pdf" else { return nil }
        let data = attachment.data
        let start = [UInt8](data.prefix(3))
        let mark: Data, encoding: String.Encoding
        if start.starts(with: [0xFF, 0xFE]) {
            (mark, encoding) = (Data([0xFF, 0xFE]), .utf16LittleEndian)
        } else if start.starts(with: [0xFE, 0xFF]) {
            (mark, encoding) = (Data([0xFE, 0xFF]), .utf16BigEndian)
        } else if start.starts(with: [0xEF, 0xBB, 0xBF]) {
            (mark, encoding) = (Data([0xEF, 0xBB, 0xBF]), .utf8)
        } else {
            // Text has no NUL bytes; binary formats do.
            guard !data.contains(0) else { return nil }
            (mark, encoding) = (Data(), .utf8)
        }
        guard let text = String(data: data.dropFirst(mark.count), encoding: encoding) else { return nil }
        self.text = text
        source = .bytes(encoding: encoding, mark: mark)
    }

    /// The attachment with `text` in place of its own.
    func with(_ text: String) -> MessageAttachment {
        guard text != self.text else { return attachment }
        var out = attachment
        switch source {
        case .prepared:
            out.text = text
        case .digest:
            out.digest?.text = text
        case .bytes(let encoding, let mark):
            guard let body = text.data(using: encoding) else { return attachment }
            out.data = mark + body
        }
        return out
    }

    /// Whether the attachment's own bytes go to the model (which the shield can't look into).
    static func bytesGo(_ attachment: MessageAttachment, route: AttachmentRoute?) -> Bool {
        guard let route else { return attachment.kind == .image || attachment.mime == "application/pdf" }
        switch AttachmentWire.delivery(attachment, route: route) {
        case .image, .document, .pageImages: return true
        case .ocrText, .text, .textInParts, .nameOnly: return false
        }
    }
}

/// Who decides about masking: the user's settings and the vault's secrets, read when a client is made. The app
/// keeps it current; nil (`ProviderClients.shield` unset) means no masking at all (the engine's own tests).
public final class ShieldPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: ShieldSettings
    private let vaultValues: @Sendable () -> [String]

    public init(settings: ShieldSettings = ShieldSettings(), vaultValues: @escaping @Sendable () -> [String] = { [] }) {
        self.settings = settings
        self.vaultValues = vaultValues
    }

    public var current: ShieldSettings {
        get { lock.withLock { settings } }
        set { lock.withLock { settings = newValue } }
    }

    /// What to look for now; nil when there is nothing (the switch is off and the vault is empty).
    public func detector() -> SensitiveDetector? {
        let detector = SensitiveDetector(settings: current, vaultValues: vaultValues())
        return detector.isActive ? detector : nil
    }
}

/// The wrapper itself (see the top of this file).
public struct ShieldClient: ProviderClient {
    public let inner: any ProviderClient
    public let detector: SensitiveDetector
    private let onReport: (@Sendable (ShieldReport) -> Void)?
    private let cache: Shield.MatchCache

    public init(inner: any ProviderClient, detector: SensitiveDetector,
                onReport: (@Sendable (ShieldReport) -> Void)? = nil) {
        self.inner = inner
        self.detector = detector
        self.onReport = onReport
        self.cache = Shield.MatchCache()
    }

    public var profile: ProviderProfile { inner.profile }

    public func listModels() async throws -> [String] { try await inner.listModels() }

    public func modelInfo(_ model: String?) async -> ModelInfo? { await inner.modelInfo(model) }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let (masked, map, unchecked) = Shield.mask(request, detector: detector, cache: cache,
                                                   route: AttachmentRoute.of(inner.profile))
        let inner = self.inner, report = self.onReport
        let route = inner.profile.name.isEmpty ? inner.profile.model : inner.profile.name
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = PlaceholderRestorer(map: map)
                var reasoning = PlaceholderRestorer(map: map)
                func flushHeld() {
                    let t = text.flush()
                    if !t.isEmpty { continuation.yield(.text(t)) }
                    let r = reasoning.flush()
                    if !r.isEmpty { continuation.yield(.reasoning(r)) }
                }
                do {
                    for try await event in inner.stream(masked) {
                        switch event {
                        case .text(let delta):
                            let out = text.feed(delta)
                            if !out.isEmpty { continuation.yield(.text(out)) }
                        case .reasoning(let delta):
                            let out = reasoning.feed(delta)
                            if !out.isEmpty { continuation.yield(.reasoning(out)) }
                        case .done(let calls, let finish, let usage, let state):
                            flushHeld()
                            let restored = calls.map { call in
                                ToolCall(id: call.id, name: call.name, arguments: Shield.restoreArguments(call.arguments.raw, map))
                            }
                            if !map.isEmpty || unchecked {
                                report?(ShieldReport(route: route, counts: map.counts, unchecked: unchecked))
                            }
                            continuation.yield(.done(calls: restored, finish: finish, usage: usage, providerState: state))
                        }
                    }
                    flushHeld()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
