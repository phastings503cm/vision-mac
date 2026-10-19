import Foundation

// MARK: - Long files: a budget, parts, a contents list
//
// A file's text goes to the model whole when it fits a quarter of the route's context window (shared among the
// message's files). A longer one is split into parts at line breaks (a new page / slide / sheet starts a new part
// once the current one is half full); the message carries a contents list and as many leading parts as fit, the
// full text is saved with the chat (`AttachmentStore`), and the model reads the other parts with the
// `read_attachment` tool, which the message tells it how to call.

/// How much of a file's text goes in the message, and how big its parts are. All sizes are UTF-16 code units
/// (`AttachmentText.length`), at four per token. Pinned: Vision for Windows uses the same numbers.
public struct AttachmentBudget: Sendable, Equatable {
    /// The route's context window, in tokens.
    public let window: Int
    /// Tokens of one file's text that go in the message: a quarter of the window, shared among the message's
    /// files, never under 2,000.
    public let inlineTokens: Int
    /// Tokens in one part: a sixteenth of the window, between 1,000 and 8,000 (so a part read back through
    /// `read_attachment` stays under the engine's 40,000-character tool-result cut), and at most half the inline
    /// budget (so the contents list and the first part fit together).
    public let partTokens: Int

    public static let charsPerToken = 4

    public init(window: Int, sharing count: Int = 1) {
        let window = max(window, 4_096)
        self.window = window
        inlineTokens = max(2_000, window / 4 / max(1, count))
        partTokens = min(8_000, max(1_000, window / 16), inlineTokens / 2)
    }

    public var inlineChars: Int { inlineTokens * Self.charsPerToken }
    public var partChars: Int { partTokens * Self.charsPerToken }
}

/// One part of a long text.
public struct AttachmentPart: Sendable, Equatable {
    public var text: String
    /// 1-based, inclusive.
    public var firstLine: Int
    public var lastLine: Int
    /// The page / slide / sheet in effect at the part's first and last line, when the text has markers.
    public var firstPage: Int?
    public var lastPage: Int?
}

public enum AttachmentPrep {
    /// The tool the model reads parts with.
    public static let toolName = "read_attachment"

    /// "--- Page 3 of 42 ---", "--- Slide 2 of 9 ---", "--- Sheet 1 of 3: Totals ---" → 3, 2, 1.
    static func sectionNumber(_ line: Substring) -> Int? {
        guard line.hasPrefix("--- ") else { return nil }
        for word in ["Page ", "Slide ", "Sheet "] {
            let rest = line.dropFirst(4)
            guard rest.hasPrefix(word) else { continue }
            let digits = rest.dropFirst(word.count).prefix { $0.isNumber }
            if let n = Int(digits), rest.dropFirst(word.count + digits.count).hasPrefix(" of ") { return n }
        }
        return nil
    }

    /// Split `text` into parts of at most `size` UTF-16 units (a single longer line is cut into pieces of its own).
    public static func split(_ text: String, size: Int) -> [AttachmentPart] {
        let size = max(size, 64)
        var parts: [AttachmentPart] = []
        var lines: [Substring] = []
        var length = 0
        var firstLine = 1
        var page: Int?
        var firstPage: Int?

        func flush(lastLine: Int) {
            guard !lines.isEmpty else { return }
            parts.append(AttachmentPart(text: lines.joined(separator: "\n"), firstLine: firstLine, lastLine: lastLine,
                                        firstPage: firstPage, lastPage: page))
            lines = []
            length = 0
        }

        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { all.removeLast() }
        for (index, line) in all.enumerated() {
            let number = index + 1
            let section = sectionNumber(line)
            let cost = line.utf16.count + 1
            if !lines.isEmpty, (section != nil && length >= size / 2) || length + cost > size {
                flush(lastLine: number - 1)
            }
            if let section { page = section }
            if lines.isEmpty { firstLine = number; firstPage = page }
            if cost > size {
                // One very long line: cut at character boundaries into pieces that fit.
                flush(lastLine: number - 1)
                var piece = ""
                var pieceLength = 0
                for char in line {
                    let width = char.utf16.count
                    if pieceLength + width > size - 1 {
                        parts.append(AttachmentPart(text: piece, firstLine: number, lastLine: number, firstPage: page, lastPage: page))
                        piece = ""
                        pieceLength = 0
                    }
                    piece.append(char)
                    pieceLength += width
                }
                if !piece.isEmpty {
                    lines = [Substring(piece)]
                    length = pieceLength + 1
                    firstLine = number
                    firstPage = page
                }
                continue
            }
            lines.append(line)
            length += cost
        }
        flush(lastLine: all.count)
        return parts
    }

    /// How many parts a digest's text makes under `budget` (1 = it goes whole).
    public static func partCount(_ digest: AttachmentDigest, budget: AttachmentBudget) -> Int {
        guard digest.readable, digest.textLength > budget.inlineChars, !digest.text.isEmpty else { return 1 }
        return split(digest.text, size: budget.partChars).count
    }

    /// "[Attached file: report.pdf — PDF · 42 pages]".
    public static func header(name: String, digest: AttachmentDigest) -> String {
        var summary = digest.summary
        if digest.ocr { summary += " · text read by OCR" }
        return "[Attached file: \(name) — \(summary)]"
    }

    /// The contents-list line for one part: `3. pages 7–9 · lines 611–902 · "Revenue by region"`.
    public static func contentsLine(_ index: Int, _ part: AttachmentPart, unit: (one: String, many: String)?) -> String {
        var fields: [String] = []
        if let unit, let first = part.firstPage {
            let last = part.lastPage ?? first
            fields.append(first == last ? "\(unit.one) \(first)" : "\(unit.many) \(first)–\(last)")
        }
        fields.append(part.firstLine == part.lastLine ? "line \(AttachmentText.grouped(part.firstLine))"
                      : "lines \(AttachmentText.grouped(part.firstLine))–\(AttachmentText.grouped(part.lastLine))")
        if let opening = openingWords(part.text) { fields.append("\"\(opening)\"") }
        return "\(index). " + fields.joined(separator: " · ")
    }

    /// The first line with words in it (not a page marker), white space collapsed, at most 60 characters.
    static func openingWords(_ text: String) -> String? {
        for line in text.split(separator: "\n") where sectionNumber(line) == nil {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#-*>| "))
            guard !words.isEmpty else { continue }
            return words.count > 60 ? String(words.prefix(59)) + "…" : words
        }
        return nil
    }

    /// The message text for one file: whole, or the contents list and leading parts (`parts` > 1).
    public static func inlineText(name: String, digest: AttachmentDigest, budget: AttachmentBudget,
                                  readable storedName: String?) -> (text: String, parts: Int) {
        let head = header(name: name, digest: digest)
        guard digest.readable else {
            let why = digest.problem ?? "Vision found no text in it."
            return (head + "\n" + why, 1)
        }
        let length = AttachmentText.length(digest.text)
        if length <= budget.inlineChars {
            return (head + "\n" + digest.text + "\n[End of \(name)]", 1)
        }
        let parts = split(digest.text, size: budget.partChars)
        let total = parts.count
        var lines = [head]
        let tokens = AttachmentText.grouped((length + AttachmentBudget.charsPerToken - 1) / AttachmentBudget.charsPerToken)
        var intro = "This file is too long to send whole: about \(tokens) tokens, and this model's context window is "
            + "\(AttachmentText.grouped(budget.window)) tokens. Vision split it into \(total) parts"
        if let storedName {
            intro += " and saved them with this chat. To read another part, call the \(toolName) tool with "
                + "{\"name\": \"\(storedName)\", \"part\": N}; to find which parts mention something, call it with "
                + "{\"name\": \"\(storedName)\", \"search\": \"words to look for\"}. Read the parts you need before "
                + "answering about the rest of the file."
        } else {
            intro += "; only the first parts are below, and the rest could not be kept."
        }
        lines.append(intro)
        // The contents list: every part, or the first hundred and a count when there are more.
        lines.append("Contents (\(total) parts):")
        let listed = min(total, 100)
        for index in 0..<listed {
            lines.append(contentsLine(index + 1, parts[index], unit: digest.format.unit))
        }
        if total > listed { lines.append("… and \(total - listed) more parts (\(listed + 1)–\(total)).") }
        var text = lines.joined(separator: "\n")
        // Leading parts, as many as the budget holds — always the first.
        var room = budget.inlineChars - AttachmentText.length(text)
        var shown = 0
        for (index, part) in parts.enumerated() {
            let block = "\n--- Part \(index + 1) of \(total) ---\n" + part.text
            let cost = AttachmentText.length(block)
            if shown > 0 && cost > room { break }
            text += block
            room -= cost
            shown += 1
        }
        let more = total - shown
        text += more > 0
            ? "\n[End of part \(shown) of \(total) of \(name) — \(more) more part\(more == 1 ? "" : "s"): read \(more == 1 ? "it" : "them") with \(toolName)]"
            : "\n[End of \(name)]"
        return (text, total)
    }

    /// One outgoing message's attachments, prepared, and the badges its transcript row shows.
    public struct Prepared: Sendable {
        public var attachments: [MessageAttachment]
        public var badges: [AttachmentBadge]
    }

    /// Prepare one outgoing message's attachments for a route with this context window: every file read (if it
    /// wasn't yet), each given the text that goes in its place, and every readable file's full text saved to
    /// `store` (so a long one can be read in parts now, and any of them again after the app restarts). Reads files,
    /// so call it off the main thread.
    public static func prepare(_ attachments: [MessageAttachment], window: Int, store: AttachmentStore?) -> Prepared {
        let digested = attachments.map { AttachmentReader.digested($0) }
        let textual = digested.filter { $0.kind == .file && ($0.digest?.readable ?? false) }.count
        let budget = AttachmentBudget(window: window, sharing: max(1, textual))
        var out: [MessageAttachment] = []
        var badges: [AttachmentBadge] = []
        for attachment in digested {
            var prepared = attachment
            guard var digest = prepared.digest else {
                out.append(prepared)
                badges.append(AttachmentBadge(prepared))
                continue
            }
            if prepared.kind == .image {
                prepared.text = AttachmentReader.imageText(name: prepared.name, ocrText: digest.text)
                prepared.parts = 1
                out.append(prepared)
                badges.append(AttachmentBadge(prepared))
                continue
            }
            var storedName: String?
            if digest.readable, let store {
                storedName = try? store.save(name: prepared.name, digest: digest, partChars: budget.partChars)
            }
            let long = digest.readable && digest.textLength > budget.inlineChars
            let inline = inlineText(name: storedName ?? prepared.name, digest: digest, budget: budget,
                                    readable: long ? storedName : nil)
            prepared.text = inline.text
            prepared.parts = inline.parts
            // The full text now lives in the store (or whole in `text`); don't carry it twice.
            digest.text = ""
            prepared.digest = digest
            out.append(prepared)
            badges.append(AttachmentBadge(prepared, stored: storedName))
        }
        return Prepared(attachments: out, badges: badges)
    }
}
