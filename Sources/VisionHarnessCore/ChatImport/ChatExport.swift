import Foundation

// MARK: - A Vision chat going out: Markdown, JSON, and the payload Guardian keeps
//
// JSON export ("format":"vision-chat", version 1) is Vision's chat shape — {id, title, cwd, rows:[{kind, text,
// toolName, argSummary, output, isError, at}]} — with ISO-8601 times and where an imported chat came from
// (source, sourceId). Import reads it back on either harness.
//
// The Guardian payload is the same shape with `at` in Apple reference-date seconds, because that is what Vision for
// macOS 0.15 sends and reads back (Guardian keeps it opaquely, so installed apps keep working); Vision for Windows and
// this importer read either form.

public struct ChatExportDocument: Sendable {
    public var id: String
    public var title: String
    public var cwd: String?
    /// Where the chat came from, when it was imported.
    public var source: ChatSource?
    public var sourceID: String?
    public var createdAt: Date?
    public var updatedAt: Date
    public var rows: [ImportedRow]

    public init(id: String, title: String, cwd: String? = nil, source: ChatSource? = nil, sourceID: String? = nil,
                createdAt: Date? = nil, updatedAt: Date, rows: [ImportedRow]) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.source = source
        self.sourceID = sourceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rows = rows
    }

    /// The copy that leaves the Mac for Guardian: masked like a request to a model that isn't private — the vault's
    /// secrets always, and what the sensitive-data shield finds when it is on (`detector` nil: nothing to mask). The
    /// title, the folder and every row's text, arguments and output are masked together, so one value is one
    /// placeholder (⟦SECRET_1⟧) all through the chat. The same rule as the prompts Guardian's notebook gets.
    public func masked(by detector: SensitiveDetector?) -> ChatExportDocument {
        guard let detector else { return self }
        var texts: [String?] = [title, cwd]
        texts.reserveCapacity(2 + rows.count * 3)
        for row in rows { texts += [row.text, row.argSummary, row.output] }
        let out = Shield.maskTexts(texts, detector: detector)
        var copy = self
        copy.title = out[0] ?? title
        copy.cwd = out[1]
        for index in copy.rows.indices {
            let base = 2 + index * 3
            copy.rows[index].text = out[base]
            copy.rows[index].argSummary = out[base + 1]
            copy.rows[index].output = out[base + 2]
        }
        return copy
    }
}

public enum ChatExport {
    /// Guardian keeps one chat's payload up to this size.
    public static let maxGuardianPayloadBytes = 25_000_000

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A file name from a chat title: no path separators or characters Finder and Windows refuse, at most 80 long.
    public static func fileName(_ title: String, ext: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var name = title.components(separatedBy: banned).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = "Chat" }
        return name + "." + ext
    }

    /// A fence that no run of backticks in `text` closes early.
    static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// The chat as Markdown, for reading anywhere.
    public static func markdown(_ doc: ChatExportDocument, exportedAt: Date = .now) -> String {
        var lines: [String] = ["# \(doc.title)", ""]
        lines.append("- Exported from Vision on \(stamp(exportedAt))")
        if let source = doc.source {
            lines.append("- Imported from \(source.label)" + (doc.sourceID.map { " (\($0))" } ?? ""))
        }
        if let cwd = doc.cwd, !cwd.isEmpty { lines.append("- Folder: \(cwd)") }
        let messages = doc.rows.filter(\.isMessage).count
        if let first = doc.rows.first?.at, let last = doc.rows.last?.at {
            lines.append("- \(messages) message\(messages == 1 ? "" : "s"), \(stamp(first)) – \(stamp(last))")
        }
        lines += ["", "---", ""]
        for row in doc.rows {
            switch row.kind {
            case .user:
                lines += ["**You** · \(stamp(row.at))", "", row.text ?? "", ""]
            case .assistant:
                lines += ["**Assistant** · \(stamp(row.at))", "", row.text ?? "", ""]
            case .tool:
                let args = (row.argSummary ?? "").isEmpty ? "" : " `\(row.argSummary!.replacingOccurrences(of: "`", with: "'"))`"
                let result = row.text.map { " → \($0)" } ?? ""
                lines += ["**Tool: \(row.toolName ?? "tool")**\(args)\(result)\(row.isError ? " (failed)" : "")", ""]
                if let output = row.output, !output.isEmpty {
                    let clipped = ImportText.clip(output, ChatImportLimits.toolOutput)
                    let fence = fence(for: clipped)
                    lines += ["<details><summary>Output</summary>", "", fence + "text", clipped, fence, "", "</details>", ""]
                }
            case .notice:
                lines += (row.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 } + [""]
            case .error:
                lines += ["**Error** · \(stamp(row.at))", "", row.text ?? "", ""]
            case .compaction:
                lines += ["**Earlier conversation, summarized** · \(stamp(row.at))", "", row.text ?? "", ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    struct FileRow: Codable {
        var kind: String
        var text: String?
        var toolName: String?
        var argSummary: String?
        var output: String?
        var isError: Bool
        var at: String
    }

    struct FileChat: Codable {
        var format = "vision-chat"
        var version = 1
        var id: String
        var title: String
        var cwd: String?
        var source: String?
        var sourceId: String?   // swiftlint:disable:this identifier_name
        var createdAt: String?
        var updatedAt: String
        var exportedAt: String
        var harness: String
        var rows: [FileRow]
    }

    /// The chat as a Vision JSON file (ISO-8601 times), which Import reads back on either harness.
    public static func json(_ doc: ChatExportDocument, exportedAt: Date = .now, harness: String = "vision-mac") -> Data {
        let file = FileChat(id: doc.id, title: doc.title, cwd: doc.cwd, source: doc.source?.rawValue, sourceId: doc.sourceID,
                            createdAt: doc.createdAt.map(iso), updatedAt: iso(doc.updatedAt), exportedAt: iso(exportedAt),
                            harness: harness,
                            rows: doc.rows.map { FileRow(kind: $0.kind.rawValue, text: $0.text, toolName: $0.toolName,
                                                         argSummary: $0.argSummary, output: $0.output, isError: $0.isError,
                                                         at: iso($0.at)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(file)) ?? Data()
    }

    struct PayloadRow: Codable {
        var kind: String
        var text: String?
        var toolName: String?
        var argSummary: String?
        var output: String?
        var isError: Bool
        var at: Date
    }

    struct Payload: Codable {
        var id: String
        var title: String
        var cwd: String?
        var rows: [PayloadRow]
        var harness: String
        var source: String?
        var sourceId: String?   // swiftlint:disable:this identifier_name
    }

    /// The transcript Guardian keeps for "Send to Guardian" (`POST /api/harness/chats/:id`).
    public static func guardianPayload(_ doc: ChatExportDocument, harness: String = "vision-mac") -> Data {
        let payload = Payload(id: doc.id, title: doc.title, cwd: doc.cwd,
                              rows: doc.rows.map { PayloadRow(kind: $0.kind.rawValue, text: $0.text, toolName: $0.toolName,
                                                              argSummary: $0.argSummary, output: $0.output,
                                                              isError: $0.isError, at: $0.at) },
                              harness: harness, source: doc.source?.rawValue, sourceId: doc.sourceID)
        // Dates as Apple reference-date seconds: JSONEncoder's default, which Vision for macOS 0.15 decodes.
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }
}
