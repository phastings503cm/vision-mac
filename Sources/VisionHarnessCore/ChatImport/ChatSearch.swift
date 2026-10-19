import Foundation

// MARK: - One search across every chat on this Mac
//
// Titles and what was said — prompts, answers, notices, and each tool card's name, arguments, result line and the start
// of its output — in chats made here and chats imported from anywhere. Every word of the query must appear
// somewhere in a chat (a "quoted phrase" counts as one word); case and accents don't matter. A chat whose title holds
// every word comes first, then the most recent.

public struct ChatSearchDocument: Sendable {
    public struct Row: Sendable {
        public var seq: Int
        public var kind: String
        public var text: String
        /// More to search that isn't the row's own line: a tool's output (the first `outputLimit` characters).
        public var more: String
        public var at: Date
        /// `text` and `more` case- and accent-folded, made once when the index is built.
        let folded: String
        let foldedMore: String

        public init(seq: Int, kind: String, text: String, more: String = "", at: Date) {
            self.seq = seq
            self.kind = kind
            self.text = text
            self.more = more
            self.at = at
            self.folded = ChatSearch.fold(text)
            self.foldedMore = more.isEmpty ? "" : ChatSearch.fold(more)
        }

        func holds(_ word: String) -> Bool { folded.contains(word) || (!foldedMore.isEmpty && foldedMore.contains(word)) }
    }

    /// How much of a tool's output the index keeps.
    public static let outputLimit = 4_000

    public var chatID: String
    public var title: String
    /// Where it came from; nil for a chat made in Vision.
    public var source: ChatSource?
    public var updatedAt: Date
    public var rows: [Row]
    let foldedTitle: String

    public init(chatID: String, title: String, source: ChatSource?, updatedAt: Date, rows: [Row]) {
        self.chatID = chatID
        self.title = title
        self.source = source
        self.updatedAt = updatedAt
        self.rows = rows
        self.foldedTitle = ChatSearch.fold(title)
    }

    /// The searchable text of a stored row (nil: not searched).
    public static func searchText(kind: String, text: String?, toolName: String?, argSummary: String?) -> String? {
        switch kind {
        case "user", "assistant", "notice", "error", "compaction":
            return text
        case "tool":
            return [toolName, argSummary, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        default:
            return nil
        }
    }

    /// A stored row as an index row (nil: not searched): its line, and a tool's output as more to search.
    public static func row(seq: Int, kind: String, text: String?, toolName: String?, argSummary: String?, output: String?,
                           at: Date) -> Row? {
        guard let line = searchText(kind: kind, text: text, toolName: toolName, argSummary: argSummary) else { return nil }
        let more = kind == "tool" ? String((output ?? "").prefix(outputLimit)) : ""
        return Row(seq: seq, kind: kind, text: line, more: more, at: at)
    }
}

/// Which chats a search looks in.
public enum ChatSearchScope: Hashable, Sendable {
    case all
    /// Chats made in Vision (not imported).
    case madeHere
    case source(ChatSource)

    func admits(_ source: ChatSource?) -> Bool {
        switch self {
        case .all: return true
        case .madeHere: return source == nil
        case .source(let wanted): return source == wanted
        }
    }
}

public struct ChatSearchHit: Sendable, Identifiable, Hashable {
    public var chatID: String
    public var title: String
    public var source: ChatSource?
    public var updatedAt: Date
    /// The row the snippet comes from (nil: only the title matched).
    public var seq: Int?
    public var kind: String?
    public var at: Date?
    public var snippet: String
    /// How many rows hold a word of the query.
    public var matches: Int
    public var titleMatch: Bool

    public var id: String { chatID }
}

public enum ChatSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The query's words: whitespace-separated, a "quoted phrase" kept whole, folded.
    public static func terms(_ query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                if !current.isEmpty { terms.append(current) }
                current = ""
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { terms.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { terms.append(current) }
        return terms.map(fold).filter { !$0.isEmpty }
    }

    public static func search(_ query: String, in documents: [ChatSearchDocument], scope: ChatSearchScope = .all,
                              limit: Int = 200) -> [ChatSearchHit] {
        let words = terms(query)
        guard !words.isEmpty else { return [] }
        var hits: [ChatSearchHit] = []
        for document in documents where scope.admits(document.source) {
            var missing = Set(words.filter { !document.foldedTitle.contains($0) })
            let titleMatch = missing.isEmpty
            var matches = 0
            var best: (row: ChatSearchDocument.Row, count: Int)?
            for row in document.rows {
                let found = words.filter { row.holds($0) }
                guard !found.isEmpty else { continue }
                matches += 1
                missing.subtract(found)
                if best == nil || found.count > best!.count { best = (row, found.count) }
            }
            guard missing.isEmpty else { continue }
            let snippet: String
            if let best {
                // From the row's own line when a word is there, else from the output that matched.
                if let word = words.first(where: { best.row.folded.contains($0) }) {
                    snippet = Self.snippet(best.row.text, word: word)
                } else {
                    snippet = Self.snippet(best.row.more, word: words.first { best.row.foldedMore.contains($0) } ?? words[0])
                }
            } else {
                snippet = ""
            }
            hits.append(ChatSearchHit(chatID: document.chatID, title: document.title, source: document.source,
                                      updatedAt: document.updatedAt, seq: best?.row.seq, kind: best?.row.kind,
                                      at: best?.row.at, snippet: snippet, matches: matches, titleMatch: titleMatch))
        }
        hits.sort {
            if $0.titleMatch != $1.titleMatch { return $0.titleMatch }
            return $0.updatedAt > $1.updatedAt
        }
        return Array(hits.prefix(limit))
    }

    /// One line of `text` around the first place `word` appears: about `radius` characters each side, ellipses where cut.
    public static func snippet(_ text: String, word: String, radius: Int = 60) -> String {
        guard let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return ImportText.oneLine(text, radius * 2)
        }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var piece = ImportText.oneLine(String(text[start..<end]), radius * 3)
        if start > text.startIndex { piece = "…" + piece }
        if end < text.endIndex { piece += "…" }
        return piece
    }
}
