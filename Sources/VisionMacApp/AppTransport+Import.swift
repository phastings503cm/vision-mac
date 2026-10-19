import Foundation
import VisionHarnessCore

// MARK: - Chats from other AI tools become Vision chats; Vision chats go out as Markdown, JSON or to Guardian
//
// An imported chat is an ordinary chat file (`ConversationLog`) whose session remembers where it came from
// (`LogSession.source`, `.sourceID`, `.importedAt`) and whose rows keep the times they were said. It opens with a
// notice saying where it came from; its route is unset, so it takes the primary model until the person picks another
// — any model can carry on, because the transcript sent to a model is rebuilt from the rows with tool cards folded into
// "[earlier tool activity]" text (`replayMessages`). A chat whose original folder exists on this Mac opens in that
// folder as a project chat; otherwise it is a chat without a project.

/// What one import did, in words for the sheet.
public struct ChatImportResult: Equatable, Sendable {
    public var imported: [String] = []
    public var messages = 0
    public var alreadyHere = 0
    public var empty = 0
    public var failed: [String] = []

    public init() {}

    public var summary: String {
        var parts: [String] = []
        let count = imported.count
        parts.append(count == 0 ? "No chats imported."
                     : "Imported \(count) chat\(count == 1 ? "" : "s") (\(messages) message\(messages == 1 ? "" : "s")).")
        if alreadyHere > 0 { parts.append("\(alreadyHere) \(alreadyHere == 1 ? "was" : "were") already here.") }
        if empty > 0 { parts.append("\(empty) had no messages.") }
        if !failed.isEmpty {
            parts.append("\(failed.count) couldn't be read: \(failed.prefix(3).joined(separator: "; "))\(failed.count > 3 ? "…" : "")")
        }
        return parts.joined(separator: " ")
    }
}

extension AppTransport {
    /// The (source, id) keys of the chats imported here.
    func importedKeys() -> Set<String> { log.importedKeys() }

    /// Whether a previewed chat is already here: imported before, or a Vision chat with this id.
    func isAlreadyImported(_ candidate: ChatImportCandidate, keys: Set<String>? = nil) -> Bool {
        if (keys ?? importedKeys()).contains(candidate.id) { return true }
        if let id = candidate.preferredID, sessions.contains(where: { $0.id == id }) { return true }
        return false
    }

    /// Store chats read from other tools as Vision chats; one already here (same source and id) is skipped.
    @discardableResult
    func importChats(_ chats: [ImportedChat], now: Date = .now) -> ChatImportResult {
        var result = ChatImportResult()
        var keys = importedKeys()
        var taken = Set(sessions.map(\.id))
        for chat in chats {
            if keys.contains(chat.key) || chat.preferredID.map(taken.contains) == true {
                result.alreadyHere += 1
                continue
            }
            guard chat.rows.contains(where: \.isMessage) else {
                result.empty += 1
                continue
            }
            let id: String = {
                if let preferred = chat.preferredID, VisionChatFile.isSafeID(preferred), !taken.contains(preferred) {
                    return preferred
                }
                return UUID().uuidString
            }()
            let folderHere: Bool = {
                guard let cwd = chat.cwd, !cwd.isEmpty else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
            }()
            // OpenClaw's working folder is its own workspace, not a project the person opened.
            let projectFolder = folderHere && chat.source != .openClaw ? chat.cwd : nil
            var session = LogSession(id: id, title: chat.title, cwd: projectFolder, preset: config.asPreset.rawValue,
                                     updatedAt: chat.updatedAt)
            if chat.source != .vision || chat.preferredID == nil {
                session.source = chat.source.rawValue
                session.sourceID = chat.sourceID
            }
            session.importedAt = now
            let rows = Self.importRows(chat, sessionID: id, importedAt: now, folderOnThisMac: folderHere)
            log.store(session, items: rows)
            keys.insert(chat.key)
            taken.insert(id)
            result.imported.append(id)
            result.messages += chat.messageCount
        }
        if !result.imported.isEmpty { reload() }
        return result
    }

    /// An imported chat's stored rows: the notice saying where it came from, then its rows with their own times.
    /// A Vision chat coming back (from a JSON file or Guardian, `preferredID` set) is its rows as they were.
    static func importRows(_ chat: ImportedChat, sessionID: String, importedAt: Date, folderOnThisMac: Bool) -> [LogItemRow] {
        var out: [LogItemRow] = []
        if chat.preferredID == nil {
            let first = chat.rows.first?.at ?? chat.createdAt
            out.append(LogItemRow(sessionID: sessionID, seq: 0, kind: "notice",
                                  text: ChatImportText.notice(chat, importedAt: importedAt, folderOnThisMac: folderOnThisMac),
                                  toolName: nil, argSummary: nil, output: nil, isError: false, at: first))
        }
        for row in chat.rows {
            out.append(LogItemRow(sessionID: sessionID, seq: out.count, kind: row.kind.rawValue, text: row.text,
                                  toolName: row.toolName, argSummary: row.argSummary, output: row.output,
                                  isError: row.isError, at: row.at))
        }
        return out
    }

    // MARK: Export

    /// Stored rows as export rows (plan rows, which carry no text in the log, are left out).
    static func exportRows(_ rows: [LogItemRow]) -> [ImportedRow] {
        rows.compactMap { row in
            guard let kind = ImportedRow.Kind(rawValue: row.kind) else { return nil }
            return ImportedRow(kind: kind, text: row.text, toolName: row.toolName, argSummary: row.argSummary,
                               output: row.output, isError: row.isError, at: row.at)
        }
    }

    /// A chat as it stands, ready to export: the open transcript when it is loaded, else its file.
    func exportDocument(_ sessionID: String) -> ChatExportDocument? {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return nil }
        let rows = vm.loaded ? Self.logRows(for: vm.entries, sessionID: sessionID) : log.peekItems(sessionID)
        let stored = log.session(sessionID)
        return ChatExportDocument(id: vm.id, title: vm.title, cwd: vm.cwd,
                                  source: stored?.source.flatMap(ChatSource.init(rawValue:)), sourceID: stored?.sourceID,
                                  createdAt: rows.first?.at, updatedAt: vm.updatedAt, rows: Self.exportRows(rows))
    }

    // MARK: Search

    /// What the search index needs from each chat: its file, the rows already in memory, and its stamp.
    func searchSources() -> [(id: String, title: String, source: ChatSource?, updatedAt: Date, file: URL, loaded: [LogItemRow]?)] {
        log.flush(wait: true)
        return sessions.map { vm in
            let where_ = log.searchSource(vm.id)
            let loaded = vm.loaded && !vm.entries.isEmpty ? Self.logRows(for: vm.entries, sessionID: vm.id) : where_.loaded
            return (vm.id, vm.title, vm.importSource, vm.updatedAt, where_.file, loaded)
        }
    }

    /// The transcript row a search hit points at, in a chat's current entries: the row with the same time and kind,
    /// else the one at the same position.
    func entryID(forSearchHit hit: ChatSearchHit, in vm: SessionVM) -> String? {
        guard let seq = hit.seq else { return nil }
        if let at = hit.at {
            let kind = hit.kind ?? ""
            if let match = vm.entries.first(where: { abs($0.at.timeIntervalSince(at)) < 0.001 && Self.kindName($0) == kind }) {
                return match.id
            }
        }
        return seq < vm.entries.count ? vm.entries[seq].id : vm.entries.last?.id
    }

    static func kindName(_ entry: ChatEntry) -> String {
        switch entry.kind {
        case .message(let body): body.role.rawValue
        case .tool: "tool"
        case .todos: "todos"
        case .compaction: "compaction"
        }
    }
}
