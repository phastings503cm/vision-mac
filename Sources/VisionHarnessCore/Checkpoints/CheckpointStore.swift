import Foundation
import CryptoKit

// MARK: - Checkpoints: what each turn changed, so it can be undone
//
// Before the agent changes a file in a turn, the file's content is kept: once per file per turn, the first time the
// turn touches it. When the change is done, what the turn left is kept too. A turn's record lists every file it
// changed with both — so the turn's results can show "Files changed (N)" with diffs, and "Rewind this turn" can put
// each file back (after checking nobody changed it since).
//
// On disk, under the app's data folder:
//   checkpoints/objects/<2 hex>/<sha-256 hex>     the contents, by hash (one copy however many turns keep it)
//   checkpoints/turns/<chat id>/<turn id>.json    one record per turn that changed something
// Old records go after 30 days, then the oldest while the contents take more than 1 GB; contents no record
// mentions go with them (`prune`).
//
// The Mac app and the Windows harness keep the same layout and the same JSON.

/// One file a turn changed.
public struct CheckpointFile: Codable, Hashable, Sendable, Identifiable {
    /// The file's absolute path.
    public var path: String
    /// The hash of its content before the turn first changed it; nil = it didn't exist.
    public var before: String?
    /// The hash of what the turn left; nil = the turn deleted it.
    public var after: String?
    /// What changed it: the tool ("edit", "write_file", "run_shell_command", an MCP tool, …).
    public var by: String
    /// Why it can't be rewound (its content wasn't kept — too large, unreadable); nil = it can.
    public var skipped: String?

    public var id: String { path }

    public init(path: String, before: String?, after: String?, by: String, skipped: String? = nil) {
        self.path = path
        self.before = before
        self.after = after
        self.by = by
        self.skipped = skipped
    }

    /// How the turn changed it.
    public var change: FileChange.Kind {
        switch (before, after) {
        case (nil, _): .created
        case (_, nil): .deleted
        default: .modified
        }
    }
}

/// Everything one turn changed.
public struct TurnCheckpointRecord: Codable, Hashable, Sendable, Identifiable {
    public var version = 1
    /// The turn: the prompt's id in the Prompts timeline (all of a `/goal`'s rounds are one turn).
    public var id: String
    public var chatID: String
    /// What was asked, short ("Fix the failing build").
    public var title: String
    public var startedAt: Date
    public var updatedAt: Date
    public var files: [CheckpointFile]
    /// When it was rewound (nil = not).
    public var rewoundAt: Date?

    public init(id: String, chatID: String, title: String, startedAt: Date = Date(), files: [CheckpointFile] = []) {
        self.id = id
        self.chatID = chatID
        self.title = title
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.files = files
    }

    /// The files that changed and didn't end up as they started (a file edited and then put back is no change).
    public var changedFiles: [CheckpointFile] { files.filter { $0.before != $0.after } }
}

/// Where checkpoints are kept (see the top of this file). Thread-safe.
public final class CheckpointStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    /// The recorders of turns still in memory, so a goal's later rounds add to the same record.
    private var recorders: [String: TurnCheckpoint] = [:]

    /// A file larger than this isn't kept: a turn that changes it can't rewind it.
    public static let maxFileBytes = 16 * 1024 * 1024
    /// Records older than this go when the store is pruned.
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    /// The contents kept may take this much space; the oldest records go first beyond it.
    public static let maxBytes = 1024 * 1024 * 1024

    public init(root: URL) {
        self.root = root
    }

    private nonisolated(unsafe) static var shared: [String: CheckpointStore] = [:]
    private static let sharedLock = NSLock()

    /// The one store for a folder in this process (so every chat shares its lock). The first time, old records are
    /// pruned in the background.
    public static func at(_ root: URL) -> CheckpointStore {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let existing = shared[root.path] { return existing }
        let store = CheckpointStore(root: root)
        shared[root.path] = store
        Task.detached(priority: .utility) { _ = store.prune() }
        return store
    }

    var objects: URL { root.appendingPathComponent("objects", isDirectory: true) }
    var turns: URL { root.appendingPathComponent("turns", isDirectory: true) }

    // MARK: Contents

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func objectURL(_ hash: String) -> URL {
        objects.appendingPathComponent(String(hash.prefix(2)), isDirectory: true).appendingPathComponent(hash)
    }

    /// Keep `data`; returns its hash. Written once: the same content is never stored twice.
    @discardableResult
    public func put(_ data: Data) throws -> String {
        let hash = Self.hash(data)
        let url = objectURL(hash)
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return hash
    }

    /// The content kept under `hash` (nil when it is gone).
    public func data(_ hash: String) -> Data? {
        try? Data(contentsOf: objectURL(hash))
    }

    // MARK: Records

    private func folder(chatID: String) -> URL {
        turns.appendingPathComponent(Self.safeName(chatID), isDirectory: true)
    }

    private func recordURL(chatID: String, turnID: String) -> URL {
        folder(chatID: chatID).appendingPathComponent(Self.safeName(turnID) + ".json")
    }

    /// A file name for an id (ids are UUIDs; anything else is reduced to safe characters).
    static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    public func save(_ record: TurnCheckpointRecord) {
        let url = recordURL(chatID: record.chatID, turnID: record.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func record(chatID: String, turnID: String) -> TurnCheckpointRecord? {
        Self.read(recordURL(chatID: chatID, turnID: turnID))
    }

    static func read(_ url: URL) -> TurnCheckpointRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TurnCheckpointRecord.self, from: data)
    }

    /// A chat's turns that changed files, newest first.
    public func records(chatID: String) -> [TurnCheckpointRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(chatID: chatID), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap(Self.read)
            .filter { !$0.changedFiles.isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Every record (for pruning).
    func allRecords() -> [(url: URL, record: TurnCheckpointRecord)] {
        let fm = FileManager.default
        let chats = (try? fm.contentsOfDirectory(at: turns, includingPropertiesForKeys: nil)) ?? []
        var out: [(URL, TurnCheckpointRecord)] = []
        for chat in chats {
            for url in (try? fm.contentsOfDirectory(at: chat, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
                if let record = Self.read(url) { out.append((url, record)) }
            }
        }
        return out
    }

    /// A deleted chat's records go with it (their contents go at the next prune).
    public func deleteChat(_ chatID: String) {
        lock.lock(); defer { lock.unlock() }
        recorders = recorders.filter { $0.value.chatID != chatID }
        try? FileManager.default.removeItem(at: folder(chatID: chatID))
    }

    // MARK: Recorders

    /// The recorder for a turn: the one already in memory, else a new one that carries on from its saved record.
    public func recorder(chatID: String, turnID: String, title: String) -> TurnCheckpoint {
        let key = chatID + "/" + turnID
        lock.lock(); defer { lock.unlock() }
        if let existing = recorders[key] { return existing }
        let recorder = TurnCheckpoint(store: self, record: record(chatID: chatID, turnID: turnID)
                                      ?? TurnCheckpointRecord(id: turnID, chatID: chatID, title: title))
        recorders[key] = recorder
        // Only the recent turns stay in memory.
        if recorders.count > 64, let oldest = recorders.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
            recorders[oldest] = nil
        }
        return recorder
    }

    // MARK: Pruning

    public struct PruneReport: Equatable, Sendable {
        public var recordsRemoved = 0
        public var objectsRemoved = 0
        public var bytesKept = 0
    }

    /// Remove records older than `maxAge`, then the oldest while the contents they keep take more than `maxBytes`,
    /// then every content no record mentions.
    @discardableResult
    public func prune(maxAge: TimeInterval = CheckpointStore.maxAge, maxBytes: Int = CheckpointStore.maxBytes,
                      now: Date = Date()) -> PruneReport {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var report = PruneReport()
        var kept: [(url: URL, record: TurnCheckpointRecord)] = []
        for item in allRecords() {
            if now.timeIntervalSince(item.record.updatedAt) > maxAge || item.record.changedFiles.isEmpty
                && now.timeIntervalSince(item.record.updatedAt) > 3600 {
                try? fm.removeItem(at: item.url)
                report.recordsRemoved += 1
            } else {
                kept.append(item)
            }
        }
        // Sizes of the contents on disk.
        var sizes: [String: Int] = [:]
        // Contents written in the last hour may belong to a turn whose record isn't saved yet: never removed.
        var recent = Set<String>()
        let buckets = (try? fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? []
        for bucket in buckets {
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            for url in (try? fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: Array(keys))) ?? [] {
                let values = try? url.resourceValues(forKeys: keys)
                sizes[url.lastPathComponent] = values?.fileSize ?? 0
                if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < 3600 {
                    recent.insert(url.lastPathComponent)
                }
            }
        }
        // And the turns still in memory keep theirs.
        let inMemory = recorders.values.map(\.record)
        func referenced(_ records: [(url: URL, record: TurnCheckpointRecord)]) -> Set<String> {
            var set = Set<String>()
            for record in records.map(\.record) + inMemory {
                for file in record.files {
                    if let before = file.before { set.insert(before) }
                    if let after = file.after { set.insert(after) }
                }
            }
            return set
        }
        // Newest first; drop the oldest while over budget.
        kept.sort { $0.record.updatedAt > $1.record.updatedAt }
        var live = referenced(kept)
        var total = live.reduce(0) { $0 + (sizes[$1] ?? 0) }
        while total > maxBytes, kept.count > 1, let oldest = kept.popLast() {
            try? fm.removeItem(at: oldest.url)
            report.recordsRemoved += 1
            live = referenced(kept)
            total = live.reduce(0) { $0 + (sizes[$1] ?? 0) }
        }
        // Contents nobody mentions any more.
        for (hash, _) in sizes where !live.contains(hash) && !recent.contains(hash) {
            try? fm.removeItem(at: objectURL(hash))
            report.objectsRemoved += 1
        }
        report.bytesKept = total
        return report
    }
}
