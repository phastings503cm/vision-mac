import Foundation

// MARK: - The shared pieces every reader uses: limits, text shaping, dates, JSON lines, and the row builder.

public enum ChatImportLimits {
    /// A tool's result is kept up to this many characters (the rest is noted, not imported).
    public static let toolOutput = 20_000
    /// One message is kept up to this many characters.
    public static let message = 1_000_000
    /// A tool card's "called with" and "result" lines.
    public static let summary = 200
}

public enum ImportText {
    /// `text` cut to `limit` characters, saying how much was left out.
    public static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let kept = text.prefix(limit)
        return kept + "\n… [\(text.count - limit) more characters not imported]"
    }

    /// One line: whitespace runs collapsed, cut to `limit` with an ellipsis.
    public static func oneLine(_ text: String, _ limit: Int = ChatImportLimits.summary) -> String {
        let collapsed = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return collapsed.prefix(max(0, limit - 1)) + "…"
    }

    /// The first non-empty line, cut to `limit`.
    public static func firstLine(_ text: String, _ limit: Int = ChatImportLimits.summary) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return oneLine(line, limit)
    }

    /// A chat title from its first prompt: the first line, without Markdown heading marks, at most 80 characters.
    public static func title(fromPrompt prompt: String) -> String? {
        var line = firstLine(stripReminders(prompt), 80)
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// `<system-reminder>…</system-reminder>` blocks a harness injects into what the person typed, removed.
    public static func stripReminders(_ text: String) -> String {
        guard text.contains("<system-reminder>") else { return text }
        var out = text
        while let open = out.range(of: "<system-reminder>") {
            guard let close = out.range(of: "</system-reminder>", range: open.upperBound..<out.endIndex) else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text between `<tag>` and `</tag>`, if present.
    public static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a tool was called with, as one line: the command, path, pattern, query or address when the arguments
    /// have one; otherwise the arguments as compact JSON.
    public static func argSummary(_ input: Any?) -> String {
        switch input {
        case nil:
            return ""
        case let text as String:
            if let data = text.data(using: .utf8), text.first == "{",
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return argSummary(object)
            }
            return firstLine(text)
        case let object as [String: Any]:
            for key in ["command", "cmd", "file_path", "filePath", "path", "notebook_path", "pattern", "query", "url",
                        "prompt", "description", "skill", "name", "title"] {
                if let value = object[key] as? String, !value.isEmpty { return oneLine(value) }
                if let list = object[key] as? [String], !list.isEmpty { return oneLine(shellCommand(list)) }
            }
            return oneLine(compactJSON(object))
        case let list as [Any]:
            return oneLine(compactJSON(list))
        default:
            return oneLine("\(input!)")
        }
    }

    /// `["/bin/zsh", "-lc", "ls -la"]` → "ls -la".
    static func shellCommand(_ list: [String]) -> String {
        if list.count == 3, ["-lc", "-c"].contains(list[1]) { return list[2] }
        return list.joined(separator: " ")
    }

    /// A tool result's one-line summary: its first non-empty line, or "done" / "failed" when it has none.
    public static func resultSummary(_ output: String, isError: Bool) -> String {
        let line = firstLine(stripReminders(output))
        if line.isEmpty { return isError ? "failed" : "done" }
        return line
    }

    public static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text out of a content value that is a string, or a list of blocks with "text" (images and files named).
    public static func blocksText(_ value: Any?) -> String {
        switch value {
        case let text as String:
            return text
        case let list as [Any]:
            return list.compactMap { item -> String? in
                if let text = item as? String { return text }
                guard let block = item as? [String: Any] else { return nil }
                let type = block["type"] as? String ?? ""
                if let text = block["text"] as? String { return text }
                if type.contains("image") { return "[image]" }
                if type == "document" || type == "file" {
                    return "[file" + ((block["name"] as? String ?? block["title"] as? String).map { ": " + $0 } ?? "") + "]"
                }
                if let content = block["content"] { return blocksText(content) }
                return nil
            }.joined(separator: "\n")
        case let object as [String: Any]:
            if let text = object["text"] as? String { return text }
            if let content = object["content"] { return blocksText(content) }
            if let output = object["output"] as? String { return output }
            return compactJSON(object)
        default:
            return ""
        }
    }
}

// MARK: - Dates

public enum ImportDates {
    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    private static let lock = NSLock()

    /// An ISO-8601 time, with any number of fraction digits (Python writes six) or none.
    public static func iso(_ raw: String) -> Date? {
        if let fast = fastISO(raw) { return fast }
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 19, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            text.replaceSubrange(text.index(text.startIndex, offsetBy: 10)...text.index(text.startIndex, offsetBy: 10), with: "T")
        }
        if let dot = text.firstIndex(of: "."), let tee = text.firstIndex(of: "T"), dot > tee {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            var digits = String(text[text.index(after: dot)..<end])
            digits = String((digits + "000").prefix(3))
            text = String(text[..<dot]) + "." + digits + String(text[end...])
        }
        if !(text.hasSuffix("Z") || text.dropFirst(19).contains("+") || text.dropFirst(19).contains("-")) {
            text += "Z"
        }
        lock.lock()
        defer { lock.unlock() }
        return isoFraction.date(from: text) ?? iso.date(from: text)
    }

    /// "YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)" read digit by digit — the shape every tool here writes, and a long
    /// history has hundreds of thousands of them (a date formatter takes microseconds each). Nil: not that shape.
    static func fastISO(_ text: String) -> Date? {
        var native = text
        native.makeContiguousUTF8()
        return native.utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            let count = bytes.count
            guard count >= 20 else { return nil }
            func digits(_ at: Int, _ length: Int) -> Int? {
                var value = 0
                for index in at..<(at + length) {
                    let byte = bytes[index]
                    guard byte >= 48, byte <= 57 else { return nil }
                    value = value * 10 + Int(byte - 48)
                }
                return value
            }
            guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 32, bytes[13] == 58, bytes[16] == 58,
                  let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
                  let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
            var index = 19
            // Milliseconds, as the formatter keeps them (further digits are dropped).
            var millis = 0
            if index < count, bytes[index] == 46 {
                index += 1
                var place = 100
                while index < count, bytes[index] >= 48, bytes[index] <= 57 {
                    millis += Int(bytes[index] - 48) * place
                    place /= 10
                    index += 1
                }
            }
            guard index < count else { return nil }
            var offset = 0
            if bytes[index] == 90 {
                guard index + 1 == count else { return nil }
            } else if bytes[index] == 43 || bytes[index] == 45, index + 6 == count, bytes[index + 3] == 58,
                      let hours = digits(index + 1, 2), let minutes = digits(index + 4, 2) {
                offset = (hours * 3600 + minutes * 60) * (bytes[index] == 43 ? 1 : -1)
            } else {
                return nil
            }
            // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: Double(seconds * 1_000 + millis) / 1_000)
        } ?? nil
    }

    /// A number as epoch seconds — or milliseconds when it's too big to be seconds.
    public static func epoch(_ value: Double) -> Date {
        value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }

    /// An ISO string, a numeric string, or a number (epoch seconds or milliseconds).
    public static func any(_ value: Any?) -> Date? {
        switch value {
        case let text as String:
            if let date = iso(text) { return date }
            if let number = Double(text) { return epoch(number) }
            return nil
        case let number as NSNumber:
            return epoch(number.doubleValue)
        default:
            return nil
        }
    }
}

// MARK: - JSON lines

public enum JSONLines {
    /// Each line of `url` that is a JSON object, in order, until `body` returns false. The file is memory-mapped, so a
    /// 50 MB session costs pages, not a copy.
    public static func forEach(_ url: URL, _ body: ([String: Any]) -> Bool) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ChatImportError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        forEach(data, body)
    }

    public static func forEach(_ data: Data, _ body: ([String: Any]) -> Bool) {
        forEachLine(data) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
            return body(object)
        }
    }

    /// Each non-empty line's bytes (no copy: valid only inside `body`), until `body` returns false.
    public static func forEachLine(_ data: Data, _ body: (Data) -> Bool) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let hit = memchr(base + start, 0x0A, count - start)
                let end = hit.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                if end > start {
                    let keepGoing: Bool = autoreleasepool {
                        body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start,
                                  deallocator: .none))
                    }
                    if !keepGoing { return }
                }
                start = end + 1
            }
        }
    }

    /// Whether `bytes` holds `mark` (memmem: a scan, not a decode).
    public static func contains(_ bytes: Data, _ mark: Data) -> Bool {
        bytes.withUnsafeBytes { (haystack: UnsafeRawBufferPointer) in
            mark.withUnsafeBytes { (needle: UnsafeRawBufferPointer) in
                guard let h = haystack.baseAddress, let n = needle.baseAddress, needle.count > 0 else { return false }
                return memmem(h, haystack.count, n, needle.count) != nil
            }
        }
    }

    /// The ISO time after `"timestamp":"` in `bytes`, if there is one.
    public static func timestamp(in bytes: Data) -> Date? {
        let mark = Data(#""timestamp":""#.utf8)
        let offset: Int? = bytes.withUnsafeBytes { (haystack: UnsafeRawBufferPointer) in
            mark.withUnsafeBytes { (needle: UnsafeRawBufferPointer) -> Int? in
                guard let h = haystack.baseAddress, let n = needle.baseAddress,
                      let hit = memmem(h, haystack.count, n, needle.count) else { return nil }
                return h.distance(to: UnsafeRawPointer(hit)) + needle.count
            }
        }
        guard let offset else { return nil }
        let rest = bytes[(bytes.startIndex + offset)...].prefix(64)
        guard let close = rest.firstIndex(of: 0x22) else { return nil }
        return ImportDates.iso(String(decoding: rest[rest.startIndex..<close], as: UTF8.self))
    }

    /// The JSON objects of a text that holds one per line.
    public static func objects(_ text: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        forEach(Data(text.utf8)) { out.append($0); return true }
        return out
    }
}

// MARK: - Building rows

/// Builds Vision rows as a reader walks a transcript: assistant text said in pieces is joined, a tool result finds
/// the card its call made (by call id, else the latest open card of that tool), and long text is clipped.
public struct ImportTranscriptBuilder {
    public private(set) var rows: [ImportedRow] = []
    private var openCalls: [String: Int] = [:]
    /// The last row is assistant text that the next assistant text joins.
    private var assistantOpen = false

    public init() {}

    public var isEmpty: Bool { rows.isEmpty }
    public var firstPrompt: String? { rows.first { $0.kind == .user }?.text }

    public mutating func user(_ text: String, at: Date) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rows.append(ImportedRow(kind: .user, text: ImportText.clip(clean, ChatImportLimits.message), at: at))
        assistantOpen = false
    }

    /// Assistant text; `join` (the default) adds it to the assistant text just before it, when nothing came between.
    public mutating func assistant(_ text: String, at: Date, join: Bool = true) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if join, assistantOpen, let last = rows.indices.last {
            rows[last].text = ImportText.clip((rows[last].text ?? "") + "\n\n" + clean, ChatImportLimits.message)
            return
        }
        rows.append(ImportedRow(kind: .assistant, text: ImportText.clip(clean, ChatImportLimits.message), at: at))
        assistantOpen = true
    }

    public mutating func toolCall(id: String?, name: String, input: Any?, at: Date) {
        rows.append(ImportedRow(kind: .tool, text: nil, toolName: name.isEmpty ? "tool" : name,
                                argSummary: ImportText.argSummary(input), output: nil, isError: false, at: at))
        if let id, !id.isEmpty { openCalls[id] = rows.count - 1 }
        assistantOpen = false
    }

    public mutating func toolResult(id: String?, name: String?, output: String, isError: Bool, at: Date) {
        let index: Int? = {
            if let id, let found = openCalls.removeValue(forKey: id) { return found }
            // No id to match: the newest card of that tool still waiting for a result.
            return rows.indices.reversed().first {
                rows[$0].kind == .tool && rows[$0].output == nil && rows[$0].text == nil
                    && (name == nil || rows[$0].toolName == name)
            }
        }()
        let clipped = ImportText.clip(ImportText.stripReminders(output), ChatImportLimits.toolOutput)
        if let index {
            rows[index].output = clipped
            rows[index].text = ImportText.resultSummary(output, isError: isError)
            rows[index].isError = isError
        } else {
            rows.append(ImportedRow(kind: .tool, text: ImportText.resultSummary(output, isError: isError),
                                    toolName: name ?? "tool", argSummary: "", output: clipped, isError: isError, at: at))
        }
        assistantOpen = false
    }

    public mutating func notice(_ text: String, at: Date) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rows.append(ImportedRow(kind: .notice, text: ImportText.clip(clean, 4_000), at: at))
        assistantOpen = false
    }

    public mutating func error(_ text: String, at: Date) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        rows.append(ImportedRow(kind: .error, text: ImportText.clip(clean, 4_000), isError: true, at: at))
        assistantOpen = false
    }

    /// Something happened that isn't kept as a row (a quick preview skipping a tool line): the next assistant text
    /// starts a message of its own.
    public mutating func separate() { assistantOpen = false }

    /// A summary the source continued from after its context filled up: the model resumes from it (rows above
    /// stay on screen).
    public mutating func compaction(_ summary: String, at: Date) {
        let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let removed = rows.filter(\.isMessage).count
        rows.append(ImportedRow(kind: .compaction, text: ImportText.clip(clean, ChatImportLimits.message),
                                toolName: "compaction", argSummary: String(removed), at: at))
        assistantOpen = false
    }

    /// The rows, with any tool card that never got a result saying so.
    public func finish() -> [ImportedRow] {
        rows.map { row in
            guard row.kind == .tool, row.text == nil else { return row }
            var done = row
            done.text = "no result recorded"
            return done
        }
    }
}
