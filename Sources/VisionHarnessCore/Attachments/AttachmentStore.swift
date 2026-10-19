import Foundation
import CryptoKit

// MARK: - Long attachments, saved with their chat

/// The full text of a chat's long attachments, one folder per chat (`<Vision data>/attachments/<chat id>/`): one
/// `.txt` per file and an `index.json` naming them. `read_attachment` reads parts back out of it, split exactly as
/// the message that listed them was (the part size is kept with each file).
/// A queued prompt's attachment whose bytes are gone (`name` is the one missing).
public struct QueuedAttachmentMissing: Error, Equatable, Sendable {
    public var name: String
}

public final class AttachmentStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The name the model knows the file by (unique in the chat).
        public var name: String
        /// The text file, relative to the chat's folder.
        public var file: String
        public var summary: String
        public var format: AttachmentDigest.Format
        public var partChars: Int
        public var parts: Int
        public var sha256: String
        public var savedAt: Date
    }

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store for one chat under `root` (the app's `attachments` folder).
    public static func forChat(_ chatID: String, root: URL) -> AttachmentStore {
        let safe = chatID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return AttachmentStore(directory: root.appendingPathComponent(safe.isEmpty ? "chat" : safe, isDirectory: true))
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public func entries() -> [Entry] {
        lock.withLock { readIndex() }
    }

    private func readIndex() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private func writeIndex(_ entries: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    /// Save a file's full text; returns the name it is saved under ("report.pdf", or "report (2).pdf" when the chat
    /// already holds a different file of that name). The same text saved again keeps its entry.
    @discardableResult
    public func save(name: String, digest: AttachmentDigest, partChars: Int) throws -> String {
        let text = digest.text
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let parts = AttachmentPrep.split(text, size: partChars).count
        return try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var entries = readIndex()
            if let index = entries.firstIndex(where: { $0.sha256 == hash && Self.base($0.name, is: name) }) {
                entries[index].partChars = partChars
                entries[index].parts = parts
                entries[index].savedAt = Date()
                try writeIndex(entries)
                return entries[index].name
            }
            let unique = Self.uniqueName(name, taken: Set(entries.map(\.name)))
            let file = "\(entries.count + 1)-\(hash.prefix(12)).txt"
            try Data(text.utf8).write(to: directory.appendingPathComponent(file), options: .atomic)
            entries.append(Entry(name: unique, file: file, summary: digest.summary, format: digest.format,
                                 partChars: partChars, parts: parts, sha256: hash, savedAt: Date()))
            try writeIndex(entries)
            return unique
        }
    }

    /// The entry the model means by `name`: exact, then ignoring case, then by the name without its extension.
    public func entry(named name: String) -> Entry? {
        let all = entries()
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = all.last(where: { $0.name == wanted }) { return hit }
        if let hit = all.last(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return hit }
        let stem = (wanted as NSString).deletingPathExtension.lowercased()
        return all.last { ($0.name as NSString).deletingPathExtension.lowercased() == stem }
    }

    public func text(of entry: Entry) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(entry.file)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Remove everything saved for the chat (the chat was deleted).
    public func removeAll() {
        lock.withLock { _ = try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Attachments of queued prompts

    /// Where the bytes of queued prompts' attachments are kept, inside the chat's folder (so deleting the chat deletes
    /// them too).
    public static let queuedFolder = "queued"

    /// Keep the attachments of a prompt put on the chat's tasks ("Add to tasks"): each one's bytes under
    /// `queued/<batch>/<n>-<sha12>.bin`, so the task can send them when its turn comes — after a relaunch too.
    public func saveQueued(_ attachments: [MessageAttachment]) throws -> [QueuedAttachment] {
        guard !attachments.isEmpty else { return [] }
        let batch = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let folder = directory.appendingPathComponent(Self.queuedFolder, isDirectory: true)
            .appendingPathComponent(batch, isDirectory: true)
        return try lock.withLock {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var out: [QueuedAttachment] = []
            for (index, attachment) in attachments.enumerated() {
                let pasted = attachment.digest?.format == .pasted
                let bytes = pasted ? Data(attachment.digest!.text.utf8) : attachment.data
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(12)
                let file = "\(index + 1)-\(hash).bin"
                try bytes.write(to: folder.appendingPathComponent(file), options: .atomic)
                let kind = pasted ? QueuedAttachment.pastedKind
                    : attachment.kind == .image ? QueuedAttachment.imageKind : QueuedAttachment.fileKind
                out.append(QueuedAttachment(kind: kind, name: attachment.name, file: "\(Self.queuedFolder)/\(batch)/\(file)"))
            }
            return out
        }
    }

    /// A queued prompt's attachments, ready to send (read again as when they were attached), or the first name whose
    /// bytes are gone from the disk.
    public func loadQueued(_ queued: [QueuedAttachment]) -> Result<[MessageAttachment], QueuedAttachmentMissing> {
        var out: [MessageAttachment] = []
        for item in queued {
            guard let url = queuedURL(item), let bytes = try? Data(contentsOf: url) else {
                return .failure(QueuedAttachmentMissing(name: item.name))
            }
            switch item.kind {
            case QueuedAttachment.pastedKind:
                out.append(AttachmentReader.pasted(String(decoding: bytes, as: UTF8.self), name: item.name))
            case QueuedAttachment.imageKind:
                out.append(MessageAttachment(kind: .image, name: item.name, data: bytes))
            default:
                out.append(MessageAttachment(kind: .file, name: item.name, data: bytes))
            }
        }
        return .success(out)
    }

    /// Delete what a queued prompt kept (its task was deleted): its batch folders, never the queued folder itself.
    public func removeQueued(_ queued: [QueuedAttachment]) {
        let root = directory.appendingPathComponent(Self.queuedFolder, isDirectory: true).standardizedFileURL.path
        let folders = Set(queued.compactMap { queuedURL($0)?.deletingLastPathComponent().standardizedFileURL.path })
        lock.withLock {
            for folder in folders where folder != root {
                try? FileManager.default.removeItem(atPath: folder)
            }
        }
    }

    /// The file a queued attachment's bytes are in; only ever inside this chat's queued folder (nil otherwise).
    func queuedURL(_ item: QueuedAttachment) -> URL? {
        let root = directory.appendingPathComponent(Self.queuedFolder, isDirectory: true).standardizedFileURL.path
        let url = directory.appendingPathComponent(item.file).standardizedFileURL
        guard url.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    /// "report.pdf" taken → "report (2).pdf", then "report (3).pdf", …
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    /// Whether `stored` is `name` or a numbered copy of it.
    private static func base(_ stored: String, is name: String) -> Bool {
        if stored == name { return true }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard stored.hasPrefix(stem + " ("), ext.isEmpty || stored.hasSuffix("." + ext) else { return false }
        return true
    }
}

// MARK: - read_attachment

/// Reads the parts of a long attachment back out of the chat's store, or searches it.
public struct ReadAttachmentTool: ToolExecutor {
    public static let name = AttachmentPrep.toolName
    public static let spec = ToolSpec(
        name: name,
        description: "Read a file the user attached to this chat that was too long to send whole — the message that carried it lists its parts. Pass the attachment's name and a part number to read that part, or a search to find which parts mention something. With no name, lists the chat's saved attachments.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string","description":"The attachment's name, as the message gave it (e.g. report.pdf)."},"part":{"type":"integer","description":"Which part to read, from 1."},"search":{"type":"string","description":"Words to look for; lists the matching lines and the parts they are in."}}}"#
    )

    /// Matches listed for one search.
    static let maxMatches = 40

    public let store: AttachmentStore
    public init(store: AttachmentStore) { self.store = store }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        ToolResult(output: run(args))
    }

    func run(_ args: JSONString) -> String {
        let name = (JSONArgs.string(args, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let all = store.entries()
        guard !name.isEmpty else {
            guard !all.isEmpty else { return "No long attachments are saved with this chat." }
            return (["Attachments saved with this chat:"] + all.map { "- \($0.name) — \($0.summary) · \($0.parts) parts" })
                .joined(separator: "\n")
        }
        guard let entry = store.entry(named: name) else {
            let saved = all.map(\.name)
            return "Error: no attachment named “\(name)” is saved with this chat."
                + (saved.isEmpty ? " (None is: every file attached so far was sent whole.)" : " Saved: \(saved.joined(separator: ", ")).")
        }
        guard let text = store.text(of: entry) else { return "Error: the saved text of \(entry.name) is missing." }
        let parts = AttachmentPrep.split(text, size: entry.partChars)
        let unit = entry.format.unit
        if let search = JSONArgs.string(args, "search")?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            return Self.search(search, in: parts, name: entry.name)
        }
        let part = JSONArgs.int(args, "part", default: JSONArgs.int(args, "chunk", default: 1))
        guard (1...max(1, parts.count)).contains(part), !parts.isEmpty else {
            return "Error: \(entry.name) has \(parts.count) parts (1–\(parts.count))."
        }
        let chosen = parts[part - 1]
        var where_ = AttachmentPrep.contentsLine(part, chosen, unit: unit)
        if let dot = where_.firstIndex(of: " ") { where_ = String(where_[where_.index(after: dot)...]) }
        let next = part < parts.count ? " — next: part \(part + 1)" : " — that was the last part"
        return "[\(entry.name) — part \(part) of \(parts.count) · \(where_)]\n\(chosen.text)\n[End of part \(part) of \(parts.count)\(next)]"
    }

    static func search(_ query: String, in parts: [AttachmentPart], name: String) -> String {
        var hits: [String] = []
        var total = 0
        for (index, part) in parts.enumerated() {
            for (offset, line) in part.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                total += 1
                guard hits.count < maxMatches else { continue }
                var shown = line.trimmingCharacters(in: .whitespaces)
                if shown.count > 160 { shown = String(shown.prefix(159)) + "…" }
                hits.append("- part \(index + 1), line \(AttachmentText.grouped(part.firstLine + offset)): \(shown)")
            }
        }
        guard total > 0 else { return "“\(query)” isn't in \(name)." }
        var out = "“\(query)” in \(name): \(AttachmentText.count(total, "match", "matches"))"
        out += "\n" + hits.joined(separator: "\n")
        if total > hits.count { out += "\n… \(AttachmentText.grouped(total - hits.count)) more; search for something narrower." }
        return out
    }
}
