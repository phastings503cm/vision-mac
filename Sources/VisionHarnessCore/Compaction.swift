import Foundation

// MARK: - Token estimation
//
// Character-based (≈ 4 chars/token) — the standard heuristic when the server
// won't report prompt tokens. Good enough for budgeting; the exact figure
// arrives from `usage` the moment a real turn runs.

public enum TokenEstimate {
    /// Rough token count for one message: text + tool calls + attachment payloads.
    public static func message(_ m: LLMMessage) -> Int {
        var chars = m.content?.count ?? 0
        for call in m.toolCalls ?? [] {
            chars += call.name.count + call.arguments.raw.count
        }
        var tokens = 0
        for att in m.attachments ?? [] {
            switch att.kind {
            case .image:
                // A vision model pays per patch, not per byte: a 1400x900
                // screenshot is ~1.6K tokens although its base64 is ~1M chars.
                tokens += ImageSize.tokens(for: att.data)
            case .file:
                // What goes in the file's place (see `AttachmentWire`): its prepared text, the text read out of it,
                // a scan's page images — or, for a file nobody read, its base64 payload.
                if let text = att.text {
                    chars += text.utf16.count
                } else if let digest = att.digest {
                    chars += digest.textLength
                } else {
                    chars += att.data.count * 4 / 3
                }
                for page in att.digest?.pageImages ?? [] { tokens += ImageSize.tokens(for: page) }
            }
        }
        return max(0, chars / 4) + tokens
    }

    /// Rough token count for a full request: system prompt + messages.
    public static func request(systemPrompt: String, messages: [LLMMessage]) -> Int {
        var total = systemPrompt.count / 4
        for m in messages { total += message(m) }
        return total
    }
}

// MARK: - Conversation compaction

/// When a transcript grows toward the model's context limit, the older part is
/// replaced by a summary the model writes, and the most recent messages are
/// kept verbatim. The plan and prompt builders here are pure and testable;
/// the summarizing LLM call lives in the app layer.
public enum Compaction {
    /// Compact once a request reaches this fraction of the window, so the next
    /// turn (prompt + output) still fits with headroom.
    public static let triggerFraction: Double = 0.75
    /// Keep this fraction of the window of recent conversation verbatim…
    public static let keepFraction: Double = 0.25
    /// …but never more than this: on a 1M window a quarter is 250K tokens,
    /// which would barely shrink anything and keep every turn slow.
    public static let maxKeepTokens = 96_000
    /// Even for small windows, keep at least this much recent context.
    public static let minKeepTokens = 4_000
    /// A manual `/compact` keeps only a short recent tail.
    public static let manualKeepFraction: Double = 0.08
    public static let manualMaxKeepTokens = 24_000
    public static let manualMinKeepTokens = 2_000
    /// Summarizing fewer than this many messages is not worth the round trip.
    public static let minSummarizable = 4

    /// Prepend this to a compacted transcript's summary message so the model
    /// (and a human reading it back from storage) knows what it is.
    public static let summaryHeader = "[Earlier conversation, compacted]\n"

    public struct Plan: Sendable {
        /// The older messages to summarize (a complete conversation: ends before
        /// a user turn, so no tool result is left orphaned).
        public let toSummarize: [LLMMessage]
        /// The recent tail to keep verbatim; always starts with a user message.
        public let toKeep: [LLMMessage]
        /// The request size that triggered compaction.
        public let usedTokens: Int
        /// The window limit compaction is budgeted against.
        public let limit: Int
    }

    /// A compaction plan when the request is over budget and the transcript can
    /// actually be split; `nil` otherwise (under the trigger, or nothing old
    /// enough to summarize).
    ///
    /// The split lands on a user-message boundary: everything before it is a
    /// finished conversation (each assistant tool-call answered by its tool
    /// result), and the kept tail begins where the user spoke again.
    ///
    /// Pass `allowAssistantBoundary: true` to also allow the cut to land on an
    /// assistant message (kept together with whatever tool results follow it,
    /// which are always contiguous — never orphaned). A subagent's entire run
    /// is one `.user` message followed by many tool round-trips, so the
    /// default (user-only) rule can never compact it at all; the app's own
    /// session compaction keeps the default so a compacted transcript still
    /// starts exactly where the display's "Compacted N messages" divider goes.
    ///
    /// `force` (a manual `/compact`) skips the trigger threshold, keeps a much
    /// shorter tail, and accepts as few as two messages to fold.
    ///
    /// When the whole budget is taken by one long turn (a user message then
    /// dozens of tool round-trips) no user boundary exists inside the keep
    /// window; rather than give up and run into the server's hard limit, the
    /// cut then falls back to an assistant boundary.
    public static func plan(usedTokens: Int, limit: Int, transcript: [LLMMessage],
                            allowAssistantBoundary: Bool = false,
                            force: Bool = false) -> Plan? {
        guard limit > 0, !transcript.isEmpty else { return nil }
        if !force {
            let threshold = Int(Double(limit) * triggerFraction)
            guard usedTokens >= threshold else { return nil }
        }
        let keepBudget = force
            ? min(max(Int(Double(limit) * manualKeepFraction), manualMinKeepTokens), manualMaxKeepTokens)
            : min(max(Int(Double(limit) * keepFraction), minKeepTokens), maxKeepTokens)
        let minimum = force ? 2 : minSummarizable

        func split(assistantToo: Bool) -> Plan? {
            var tokens = 0
            var boundary: Int? = nil
            var i = transcript.count - 1
            while i >= 0 {
                let m = transcript[i]
                tokens += TokenEstimate.message(m)
                if m.role == .user || (assistantToo && m.role == .assistant) { boundary = i }
                if tokens >= keepBudget { break }
                i -= 1
            }
            // A forced compaction of a short chat: keep just the last exchange.
            if force, boundary == nil || boundary == 0 {
                boundary = transcript.lastIndex { $0.role == .user || (assistantToo && $0.role == .assistant) }
            }
            guard let boundary, boundary > 0 else { return nil }
            let toSummarize = Array(transcript[0..<boundary])
            let toKeep = Array(transcript[boundary...])
            // Only a summary so far and nothing new to fold: not worth a call.
            let substantive = toSummarize.filter { !isSummary($0) }
            guard toSummarize.count >= minimum, !substantive.isEmpty else { return nil }
            return Plan(toSummarize: toSummarize, toKeep: toKeep, usedTokens: usedTokens, limit: limit)
        }
        return split(assistantToo: allowAssistantBoundary) ?? (allowAssistantBoundary ? nil : split(assistantToo: true))
    }

    /// Whether a message is an earlier compaction summary.
    public static func isSummary(_ m: LLMMessage) -> Bool {
        m.role == .system && (m.content ?? "").hasPrefix(summaryHeader)
    }

    /// The prompt that turns `messages` into a continuity summary.
    ///
    /// Each message is capped at a share of `budgetTokens` (in characters) so
    /// the summarizing request itself fits comfortably inside the window even
    /// when it is asking about a transcript that nearly filled it.
    public static func summaryPrompt(for messages: [LLMMessage], budgetTokens: Int,
                                     focus: String? = nil) -> String {
        // Earlier summaries are carried forward whole (they are already
        // dense); everything else shares what is left of the budget.
        let previous = messages.filter(isSummary).map { String(($0.content ?? "").dropFirst(summaryHeader.count)) }
        let rest = messages.filter { !isSummary($0) }
        let previousChars = previous.reduce(0) { $0 + $1.count }
        let perMessage = max(300, (budgetTokens * 4 - previousChars) / max(1, rest.count))
        var body = ""
        for m in rest {
            switch m.role {
            case .system:
                body += "System: \(clip(m.content ?? "", perMessage / 4))\n"
            case .user:
                body += "User: \(clip(m.content ?? "", perMessage))\n"
            case .assistant:
                body += "Assistant: \(clip(m.content ?? "", perMessage))"
                for call in m.toolCalls ?? [] {
                    body += " [tool call: \(call.name) \(clip(call.arguments.raw, perMessage / 3))]"
                }
                body += "\n"
            case .tool:
                body += "Tool result (\(m.name ?? "unknown")): \(clip(m.content ?? "", perMessage / 2))\n"
            }
        }
        let prior = previous.isEmpty ? "" : """

        The conversation was already compacted before. Merge this earlier summary in — keep every fact from it that still matters:
        <earlier-summary>
        \(previous.joined(separator: "\n\n"))
        </earlier-summary>

        """
        let focusLine = (focus?.isEmpty == false) ? "\nThe user asked this summary to focus on: \(focus!)\n" : ""
        return """
        The earlier part of this agent conversation is being compacted to fit the context window. \
        Write a continuity note the agent can pick up from and keep working without asking the user to repeat anything. \
        Use at most ~800 words, with these sections:

        - Task: what the user asked for and the current goal (quote the user's key requirements verbatim)
        - Decisions: important choices, constraints, and why
        - Work done: files created/edited (with paths), commands run, key results
        - Open items: unfinished steps, unresolved errors, pending questions
        - State: exactly where the conversation stands now and the very next step
        \(focusLine)\(prior)
        Be factual and specific (paths, commands, versions, error messages). Omit small talk. \
        Output only the note.

        <conversation>
        \(body)
        </conversation>
        """
    }

    private static func clip(_ s: String, _ maxChars: Int) -> String {
        s.count <= maxChars ? s : String(s.suffix(maxChars)) + " …[truncated]"
    }

    /// Ask any `LLMClient` for a continuity summary of a compaction plan's
    /// older half. Generic over the protocol (no app-layer transport needed),
    /// so this is what both the main session and subagents compact with.
    ///
    /// The request is budgeted at a fraction of the plan's window so the
    /// summarization call itself — clipped transcript in, summary out — stays
    /// well clear of the very limit it exists to protect. Returns `nil` on any
    /// failure (network, empty result) so the caller can keep the transcript
    /// as-is rather than lose it.
    ///
    /// Thinking is switched off for the summary call: it is a writing task,
    /// and a reasoning model at max effort would otherwise spend minutes (and
    /// the whole output budget) thinking before writing a word.
    public static func summarize(client: any LLMClient, plan: Plan,
                                 budgetFraction: Double = 0.4,
                                 maxOutputTokens: Int = 4096,
                                 model: String = "",
                                 focus: String? = nil) async -> String? {
        // Big windows don't need a huge summary input: cap it so the call stays quick.
        let budget = min(Int(Double(plan.limit) * budgetFraction), 200_000)
        let prompt = summaryPrompt(for: plan.toSummarize, budgetTokens: budget, focus: focus)
        let request = LLMRequest(systemPrompt: "You write concise, factual continuity notes for a coding agent.",
                                 messages: [.user(prompt)], tools: [],
                                 model: model, temperature: nil, maxTokens: maxOutputTokens,
                                 thinking: .off)
        var text = ""
        var finished = false
        do {
            for try await event in client.stream(request) {
                if case .text(let delta) = event { text += delta }
                if case .done = event { finished = true }
            }
        } catch {
            return nil
        }
        // Stopped mid-summary: a cut-off summary must never replace history.
        guard finished, !Task.isCancelled else { return nil }
        let trimmed = stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drop an inline `<think>…</think>` block (servers without a reasoning
    /// parser leave it in the content).
    public static func stripThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text }
        return String(text[close.upperBound...])
    }
}

// MARK: - Image size

/// Dimensions of an encoded image, read from its header (no decoding), and the
/// vision-token cost that implies.
public enum ImageSize {
    /// Pixels per side of one vision patch after merging (Qwen-VL family: 28).
    public static let patch = 28

    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(64 * 1024))
        // PNG: 8-byte signature, IHDR width/height at 16..23 (big endian).
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            return w > 0 && h > 0 ? (w, h) : nil
        }
        // GIF: "GIF8", little-endian width/height at 6..9.
        if b.count >= 10, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 {
            let w = Int(b[6]) | Int(b[7]) << 8
            let h = Int(b[8]) | Int(b[9]) << 8
            return w > 0 && h > 0 ? (w, h) : nil
        }
        // JPEG: walk segments to the first start-of-frame marker.
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 {
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let marker = b[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return w > 0 && h > 0 ? (w, h) : nil
                }
                i += 2 + max(2, length)
            }
            return nil
        }
        // WebP: RIFF....WEBP then VP8X / VP8L / VP8 chunk.
        if b.count >= 30, b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 {
            let fourCC = String(decoding: b[12..<16], as: UTF8.self)
            if fourCC == "VP8X" {
                let w = 1 + (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16)
                let h = 1 + (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16)
                return (w, h)
            }
            if fourCC == "VP8L" {
                let bits = UInt32(b[21]) | UInt32(b[22]) << 8 | UInt32(b[23]) << 16 | UInt32(b[24]) << 24
                return (Int(bits & 0x3FFF) + 1, Int((bits >> 14) & 0x3FFF) + 1)
            }
            if fourCC == "VP8 ", b.count >= 30 {
                return (Int(b[26]) | Int(b[27]) << 8) & 0x3FFF > 0
                    ? ((Int(b[26]) | Int(b[27]) << 8) & 0x3FFF, (Int(b[28]) | Int(b[29]) << 8) & 0x3FFF) : nil
            }
        }
        return nil
    }

    /// Estimated vision tokens for an encoded image (1,500 when the header
    /// can't be read).
    public static func tokens(for data: Data) -> Int {
        guard let (w, h) = dimensions(of: data) else { return 1_500 }
        let cost = ((w + patch - 1) / patch) * ((h + patch - 1) / patch)
        return min(8_192, max(64, cost))
    }
}
