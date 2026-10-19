import Foundation
import Observation
import VisionHarnessCore

/// One stored transcript row.
public struct LogItemRow: Identifiable, Hashable, Sendable {
    public let sessionID: String
    public var seq: Int
    public var id: String { "\(sessionID):\(seq)" }
    /// user | assistant | tool | toolResult | notice | error
    public var kind: String
    public var text: String?
    public var toolName: String?
    public var argSummary: String?
    public var output: String?
    public var isError: Bool
    public var at: Date
    /// A user row's attachments (names and summaries, not content).
    public var attachments: [AttachmentBadge]?

    public init(sessionID: String, seq: Int, kind: String, text: String?,
                toolName: String?, argSummary: String?, output: String?,
                isError: Bool, at: Date, attachments: [AttachmentBadge]? = nil) {
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.argSummary = argSummary
        self.output = output
        self.isError = isError
        self.at = at
        self.attachments = attachments
    }
}

/// Stored session metadata.
public struct LogSession: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var cwd: String?
    public var preset: String?
    public var updatedAt: Date
    /// A chat without a project working in a folder other than its own scratch folder (a queue task from a chat
    /// without a project works in that chat's folder). Nil = its own.
    public var scratch: String?
    /// The route (`ProviderProfile.routeID`) this chat talks to, and its thinking level — each chat's own, so two
    /// chats in two projects never share a model by accident. Nil = not chosen yet (an older chat: it takes the
    /// primary when it next sends).
    public var route: String?
    public var thinking: String?
    /// The chat's Claude Code session (once a turn has run on Claude Code): carried on with --resume. Absent until then.
    public var claudeSession: String?
    /// Claude Code's running cost total for that session at its last turn (it adds up across --resume).
    public var claudeCost: Double?
    /// When the session last spoke: messages after this (turns on other models) go to it as a recap.
    public var claudeSyncedAt: Date?
    /// The chat is Sensitive (see `SensitivityPolicy`). Nil = no (an older chat).
    public var sensitive: Bool?
    /// An imported chat: where it came from (`ChatSource` raw value), the source's own id for it, and when it was
    /// brought in. A second import skips a chat whose (source, sourceID) is already here. Nil for chats made here.
    public var source: String?
    public var sourceID: String?
    public var importedAt: Date?

    public var importKey: String? {
        guard let source, let sourceID else { return nil }
        return ChatImportKey.make(source, sourceID)
    }
}

private struct StoredItem: Codable {
    var seq: Int
    var kind: String
    var text: String?
    var toolName: String?
    var argSummary: String?
    var output: String?
    var isError: Bool
    var at: Date
    var attachments: [AttachmentBadge]?
}

/// Per-session conversation store. One JSON file per session under
/// ~/Library/Application Support/Vision/conversations/ (`AppPaths.conversations`).
@MainActor
public final class ConversationLog {
    public static let shared = ConversationLog()

    private let dir: URL
    private var rows: [String: LogSession] = [:]
    /// Loaded timelines. A released session (an archived queue chat) is
    /// dropped from memory and read back from disk when next needed.
    private var items: [String: [LogItemRow]] = [:]
    /// Sessions with changes not yet written. Writes are coalesced: a long
    /// unattended run logs thousands of rows, and rewriting the whole file
    /// for every one of them grows quadratically.
    private var dirty: Set<String> = []
    private var flushScheduled = false
    /// How long a burst of changes is coalesced before it is written.
    public var writeDelay: TimeInterval = 0.75
    /// File writes happen here, in order, off the main thread.
    private let io = DispatchQueue(label: "vision.ConversationLog.io", qos: .utility)

    public init(dir: URL? = nil) {
        let base = dir ?? Self.defaultDir
        self.dir = base
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let fileManager = FileManager.default
            for url in (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
                where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let file = try? JSONDecoder().decode(SessionFile.self, from: data) {
                    // Timelines load on demand (loadItems): holding every
                    // chat's full history in memory doesn't scale to a long queue.
                    rows[file.session.id] = file.session
                }
            }
        } catch {}
    }

    static var defaultDir: URL { AppPaths.conversations }

    private func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    public func upsert(id: String, cwd: String?, title: String, preset: String?, scratch: String? = nil) {
        var row = rows[id] ?? LogSession(id: id, title: title, cwd: cwd, preset: preset, updatedAt: .now)
        row.title = title
        row.updatedAt = .now
        if let cwd, !cwd.isEmpty { row.cwd = cwd }
        if let preset { row.preset = preset }
        if let scratch, !scratch.isEmpty { row.scratch = scratch }
        rows[id] = row
        persist(id)
    }

    public func list() -> [LogSession] {
        rows.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadItems(_ id: String) -> [LogItemRow] {
        if let loaded = items[id] { return loaded }
        let loaded = readItems(id) ?? []
        if rows[id] != nil { items[id] = loaded }
        return loaded
    }

    /// A session's rows without keeping them in memory (the loaded copy when there is one): for one-off reads such
    /// as backfilling the Prompts timeline of a chat nobody has opened.
    public func peekItems(_ id: String) -> [LogItemRow] {
        items[id] ?? readItems(id) ?? []
    }

    /// Write this session's pending changes now and drop its timeline from
    /// memory; `loadItems` reads it back from disk on demand.
    public func release(_ id: String) {
        if dirty.remove(id) != nil { write(id) }
        items[id] = nil
    }

    /// Write every pending change. `wait` blocks until the bytes are on disk
    /// (app termination, tests).
    public func flush(wait: Bool = false) {
        flushScheduled = false
        let ids = dirty
        dirty = []
        for id in ids { write(id) }
        if wait { io.sync {} }
    }

    private func readItems(_ id: String) -> [LogItemRow]? {
        io.sync {}   // a write for this file may still be in flight
        guard let data = try? Data(contentsOf: fileURL(id)),
              let file = try? JSONDecoder().decode(SessionFile.self, from: data) else { return nil }
        return file.items.map {
            LogItemRow(sessionID: id, seq: $0.seq, kind: $0.kind, text: $0.text, toolName: $0.toolName,
                       argSummary: $0.argSummary, output: $0.output, isError: $0.isError, at: $0.at,
                       attachments: $0.attachments)
        }
    }

    public func recordItem(_ id: String, kind: String, text: String?,
                           toolName: String?, argSummary: String?, output: String?,
                           isError: Bool, attachments: [AttachmentBadge]? = nil) {
        var list = items[id] ?? (rows[id] != nil ? readItems(id) ?? [] : [])
        let row = LogItemRow(sessionID: id, seq: list.count, kind: kind, text: text,
                             toolName: toolName, argSummary: argSummary, output: output,
                             isError: isError, at: .now, attachments: attachments)
        list.append(row)
        items[id] = list
        persist(id)
    }

    /// Set the attachments of a session's last user row (they are known for sure once the message is prepared).
    public func setAttachments(_ id: String, onLastUser badges: [AttachmentBadge]) {
        guard var list = items[id], let index = list.lastIndex(where: { $0.kind == "user" }) else { return }
        list[index].attachments = badges.isEmpty ? nil : badges
        items[id] = list
        persist(id)
    }

    public func delete(_ id: String) {
        rows[id] = nil
        items[id] = nil
        dirty.remove(id)
        let url = fileURL(id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Replace a session's stored items wholesale. Used after a turn so the
    /// persisted log tracks the (possibly compacted) model transcript exactly
    /// — summarized messages are dropped, and a "compaction" row stands in.
    public func resync(_ id: String, rows newRows: [LogItemRow]) {
        items[id] = newRows
        persist(id)
    }

    /// The (source, id) keys of the imported chats here.
    public func importedKeys() -> Set<String> {
        Set(rows.values.compactMap(\.importKey))
    }

    public func session(_ id: String) -> LogSession? { rows[id] }

    /// A session's rows read straight from its file, off the main thread (the search index). Nil when unreadable.
    nonisolated static func readRows(at url: URL, sessionID: String) -> [LogItemRow]? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(SessionFile.self, from: data) else { return nil }
        return file.items.map {
            LogItemRow(sessionID: sessionID, seq: $0.seq, kind: $0.kind, text: $0.text, toolName: $0.toolName,
                       argSummary: $0.argSummary, output: $0.output, isError: $0.isError, at: $0.at,
                       attachments: $0.attachments)
        }
    }

    /// Where a session's file is, and its rows when they are in memory (the search index reads the rest from disk).
    func searchSource(_ id: String) -> (file: URL, loaded: [LogItemRow]?) {
        (fileURL(id), items[id])
    }

    /// Store a whole chat at once, with the dates it carries, and write it now (the screenshot mode's chats).
    func store(_ session: LogSession, items newItems: [LogItemRow]) {
        rows[session.id] = session
        items[session.id] = newItems
        dirty.insert(session.id)
        flush(wait: true)
    }

    /// Store the chat's own model choice.
    public func setChoice(id: String, route: String?, thinking: String?) {
        guard var row = rows[id], row.route != route || row.thinking != thinking else { return }
        row.route = route
        row.thinking = thinking
        rows[id] = row
        persist(id)
    }

    /// Store the chat's Claude Code session, its cost total, and (when the turn got somewhere) when it spoke.
    public func setClaudeSession(id: String, session: String?, cost: Double?, syncedAt: Date? = nil) {
        guard var row = rows[id] else { return }
        let synced = syncedAt ?? (session == row.claudeSession ? row.claudeSyncedAt : nil)
        guard row.claudeSession != session || row.claudeCost != cost || row.claudeSyncedAt != synced else { return }
        row.claudeSession = session
        row.claudeCost = cost
        row.claudeSyncedAt = synced
        rows[id] = row
        persist(id)
    }

    /// The chat's stored Claude Code session.
    public func claudeSession(_ id: String) -> (session: String?, cost: Double?, syncedAt: Date?) {
        (rows[id]?.claudeSession, rows[id]?.claudeCost, rows[id]?.claudeSyncedAt)
    }

    /// Store whether the chat is Sensitive.
    public func setSensitive(id: String, _ sensitive: Bool) {
        let stored: Bool? = sensitive ? true : nil
        guard var row = rows[id], row.sensitive != stored else { return }
        row.sensitive = stored
        rows[id] = row
        persist(id)
    }

    public func touch(_ id: String) {
        guard var row = rows[id] else { return }
        row.updatedAt = .now
        rows[id] = row
        persist(id)
    }

    public func touch(_ id: String, title: String) {
        guard var row = rows[id] else { return }
        row.title = title
        row.updatedAt = .now
        rows[id] = row
        persist(id)
    }

    private func persist(_ id: String) {
        guard rows[id] != nil else { return }
        dirty.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        let delay = writeDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            self?.flush()
        }
    }

    private func write(_ id: String) {
        guard let row = rows[id] else { return }
        let stored = items[id] ?? readItems(id) ?? []
        let file = SessionFile(session: row, items: stored.map {
            StoredItem(seq: $0.seq, kind: $0.kind, text: $0.text, toolName: $0.toolName,
                       argSummary: $0.argSummary, output: $0.output, isError: $0.isError, at: $0.at,
                       attachments: ($0.attachments?.isEmpty ?? true) ? nil : $0.attachments)
        })
        guard let data = try? JSONEncoder().encode(file) else { return }
        let url = fileURL(id)
        io.async { try? data.write(to: url, options: .atomic) }
    }

    private struct SessionFile: Codable {
        var session: LogSession
        var items: [StoredItem]
    }
}