import Foundation
import SQLite3

// MARK: - OpenClaw sessions (~/.openclaw)
//
// OpenClaw (2026.8+) keeps each agent's sessions in SQLite, `agents/<agent>/agent/openclaw-agent.sqlite`:
//   session_windows (session_id, session_key, display_name, created_at, updated_at [epoch ms], model, channel)
//   session_nodes   (session_key, label, display_name, created_via: operator | cron | spawn | run | …)
//   transcript_events (session_id, seq, event_json, created_at)
// Before the move to SQLite, and for sessions that were reset, the same events sit in JSONL files:
//   agents/<agent>/sessions/<id>.jsonl[.reset.<time>] and
//   agents/<agent>/session-sqlite-import-archive/archive-tier.<id>.jsonl.imported-<ms>
// (trajectory, checkpoint and zstd-compressed ".deleted" files are not conversations and are skipped).
//
// An event is the agent session format, version 3: {type:"session", id, timestamp, cwd} first, then
//   {type:"message", id, parentId, timestamp, message:{role:"user"|"assistant"|"toolResult"|"bashExecution", content}}
//     assistant content: text · thinking · toolCall {id, name, arguments}; toolResult {toolCallId, toolName, content,
//     isError}
//   {type:"compaction", summary} · {type:"custom_message", content, display} · {type:"leaf", targetId} (a rewind)
// Entries form a tree (a rewind branches it); the chat imported is the branch the session ended on.
// Session keys say what kind of session it was: agent:<a>:dashboard:… (a chat), agent:<a>:cron:… (a scheduled run),
// agent:<a>:subagent:… (spawned by another session). The database is opened read-only; nothing is written.

public enum OpenClawChats {
    /// The agents' folders in an OpenClaw state folder.
    public static func agentFolders(stateDir: URL) -> [URL] {
        let agents = stateDir.appendingPathComponent("agents", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.path < $1.path }
    }

    public static func database(agentFolder: URL) -> URL? {
        let url = agentFolder.appendingPathComponent("agent/openclaw-agent.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The JSONL transcripts of an agent: legacy sessions, reset generations and the pre-SQLite archive.
    public static func transcriptFiles(agentFolder: URL) -> [URL] {
        var out: [URL] = []
        for folder in ["sessions", "session-sqlite-import-archive"] {
            let dir = agentFolder.appendingPathComponent(folder, isDirectory: true)
            for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if isTranscriptFile(url.lastPathComponent) { out.append(url) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    static func isTranscriptFile(_ name: String) -> Bool {
        guard name.contains(".jsonl") else { return false }
        for skip in [".trajectory.", ".checkpoint.", ".deleted.", ".zst", ".bak", "trajectory-path"] where name.contains(skip) {
            return false
        }
        return name.hasSuffix(".jsonl") || name.contains(".jsonl.reset.") || name.contains(".jsonl.imported-")
    }

    /// "archive-tier.<uuid>.jsonl.imported-…" or "<uuid>.jsonl.reset.…" → the session id in the name.
    static func idFromFileName(_ name: String) -> String {
        var stem = name
        if stem.hasPrefix("archive-tier.") { stem.removeFirst("archive-tier.".count) }
        if let range = stem.range(of: ".jsonl") { stem = String(stem[..<range.lowerBound]) }
        return stem
    }

    // MARK: Reading events into a chat

    /// The events on the branch the session ended on, in order (a rewind's abandoned branch dropped).
    static func activeBranch(_ events: [[String: Any]]) -> [[String: Any]] {
        var parent: [String: String] = [:]
        var current: String?
        var hasTree = false
        for event in events {
            if event["type"] as? String == "leaf" {
                current = event["targetId"] as? String
                hasTree = true
                continue
            }
            guard let id = event["id"] as? String, event["type"] as? String != "session" else { continue }
            if let up = event["parentId"] as? String { parent[id] = up; hasTree = true }
            current = id
        }
        guard hasTree, var node = current else { return events }
        var keep: Set<String> = [node]
        var guardCount = 0
        while let up = parent[node], guardCount < 1_000_000 {
            keep.insert(up)
            node = up
            guardCount += 1
        }
        return events.filter { event in
            guard let id = event["id"] as? String, event["type"] as? String != "session" else {
                return event["type"] as? String == "session"
            }
            return keep.contains(id)
        }
    }

    /// The state a reading builds besides rows.
    struct Reading {
        var builder = ImportTranscriptBuilder()
        var sessionID: String?
        var cwd: String?
        var model: String?
        var first: Date?
        var last: Date?
        var cronName: String?
    }

    static func apply(_ event: [String: Any], fallbackAt: Date?, to reading: inout Reading) {
        let at = (event["timestamp"] as? String).flatMap(ImportDates.iso(_:)) ?? fallbackAt ?? reading.last ?? .now
        switch event["type"] as? String {
        case "session":
            if let id = event["id"] as? String { reading.sessionID = id }
            if let folder = event["cwd"] as? String, !folder.isEmpty { reading.cwd = folder }
            return
        case "model_change":
            if let id = event["modelId"] as? String { reading.model = id }
            return
        case "compaction":
            reading.builder.compaction(event["summary"] as? String ?? "", at: at)
        case "custom_message":
            if event["display"] as? Bool == true { reading.builder.notice(ImportText.blocksText(event["content"]), at: at) }
        case "message":
            guard let message = event["message"] as? [String: Any] else { return }
            reading.first = reading.first.map { min($0, at) } ?? at
            reading.last = reading.last.map { max($0, at) } ?? at
            switch message["role"] as? String {
            case "user":
                let text = ImportText.blocksText(message["content"])
                if reading.cronName == nil, let name = cronName(text) { reading.cronName = name }
                reading.builder.user(text, at: at)
            case "assistant":
                if let name = message["model"] as? String, !name.isEmpty { reading.model = name }
                if let blocks = message["content"] as? [Any] {
                    for case let block as [String: Any] in blocks {
                        switch block["type"] as? String {
                        case "text": reading.builder.assistant(block["text"] as? String ?? "", at: at)
                        case "toolCall":
                            reading.builder.toolCall(id: block["id"] as? String, name: block["name"] as? String ?? "tool",
                                                     input: block["arguments"], at: at)
                        default: break
                        }
                    }
                } else if let text = message["content"] as? String {
                    reading.builder.assistant(text, at: at)
                }
                if message["stopReason"] as? String == "error", let error = message["errorMessage"] as? String {
                    reading.builder.error(error, at: at)
                }
            case "toolResult":
                reading.builder.toolResult(id: message["toolCallId"] as? String, name: message["toolName"] as? String,
                                           output: ImportText.blocksText(message["content"]),
                                           isError: message["isError"] as? Bool ?? false, at: at)
            case "bashExecution":
                reading.builder.toolCall(id: nil, name: "bash", input: ["command": message["command"] as? String ?? ""], at: at)
                let code = message["exitCode"] as? Int ?? 0
                reading.builder.toolResult(id: nil, name: "bash", output: message["output"] as? String ?? "",
                                           isError: code != 0, at: at)
            default:
                break
            }
        default:
            break
        }
    }

    /// "[cron:<id> <name>] …" → the cron job's name.
    static func cronName(_ text: String) -> String? {
        guard text.hasPrefix("[cron:"), let close = text.firstIndex(of: "]") else { return nil }
        let inside = text[text.index(text.startIndex, offsetBy: 6)..<close]
        let parts = inside.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    static func chat(from reading: Reading, fallbackID: String, label: String?, key: String?, automatedHint: Bool,
                     created: Date?, updated: Date?) -> ImportedChat? {
        let rows = reading.builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        let automated = automatedHint || reading.cronName != nil || isAutomatedKey(key)
        let title: String = {
            if let label, !label.isEmpty { return label }
            if let name = reading.cronName { return "Cron: \(name)" }
            return reading.builder.firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "OpenClaw session"
        }()
        let createdAt = reading.first ?? created ?? .now
        return ImportedChat(source: .openClaw, sourceID: reading.sessionID ?? fallbackID, title: title,
                            createdAt: createdAt, updatedAt: reading.last ?? updated ?? createdAt,
                            cwd: reading.cwd, model: reading.model, rows: rows, automated: automated)
    }

    static func isAutomatedKey(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.contains(":cron:") || key.contains(":subagent:") || key.contains(":spawn:") || key.contains(":run:")
    }

    /// The kind of session a key names, for the preview's detail line.
    static func detail(key: String?, agent: String, via: String?) -> String {
        let kind: String = {
            guard let key else { return "Session" }
            if key.contains(":cron:") { return "Cron run" }
            if key.contains(":subagent:") || via == "spawn" { return "Subagent" }
            if key.contains(":dashboard:") { return "Chat" }
            return "Session"
        }()
        return agent == "main" ? kind : "\(kind) · agent \(agent)"
    }

    // MARK: JSONL files

    public static func read(file: URL) throws -> ImportedChat? {
        var events: [[String: Any]] = []
        try JSONLines.forEach(file) { events.append($0); return true }
        var reading = Reading()
        for event in activeBranch(events) { apply(event, fallbackAt: nil, to: &reading) }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return chat(from: reading, fallbackID: idFromFileName(file.lastPathComponent), label: nil, key: nil,
                    automatedHint: false, created: nil, updated: modified)
    }

    /// A quick look at a JSONL transcript for the preview: its id, first prompt, times and message count, reading only
    /// the lines that matter (most bytes are tool results, which are counted, not decoded).
    public static func preview(file: URL, agent: String) -> ChatImportCandidate? {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        var sessionID: String?
        var cwd: String?
        var firstPrompt: String?
        var first: Date?
        var last: Date?
        var messages = 0
        let messagePrefix = Data(#"{"type":"message""#.utf8)
        let userMark = Data(#""role":"user""#.utf8)
        let assistantMark = Data(#""role":"assistant""#.utf8)
        // An assistant line is a message when it says something (one that only calls tools makes tool cards).
        let textMark = Data(#""type":"text","text":""#.utf8)
        JSONLines.forEachLine(data) { line in
            if line.starts(with: messagePrefix) {
                let head = line.prefix(300)
                let isUser = JSONLines.contains(head, userMark)
                let says = !isUser && JSONLines.contains(head, assistantMark) && JSONLines.contains(line, textMark)
                guard isUser || says else { return true }
                messages += 1
                if let at = JSONLines.timestamp(in: head) {
                    first = first.map { min($0, at) } ?? at
                    last = last.map { max($0, at) } ?? at
                }
                if isUser, firstPrompt == nil,
                   let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let message = object["message"] as? [String: Any] {
                    firstPrompt = ImportText.blocksText(message["content"])
                }
            } else if sessionID == nil, line.count < 4_000,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "session" {
                sessionID = object["id"] as? String
                cwd = object["cwd"] as? String
            }
            return true
        }
        guard messages > 0 else { return nil }
        let id = sessionID ?? idFromFileName(file.lastPathComponent)
        let cron = firstPrompt.flatMap(cronName)
        let title = cron.map { "Cron: \($0)" } ?? firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "OpenClaw session"
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let detail = file.lastPathComponent.contains(".reset.") ? "Before a reset" : (cron != nil ? "Cron run" : "Session")
        return ChatImportCandidate(source: .openClaw, sourceID: id, title: title, createdAt: first,
                                   updatedAt: last ?? modified ?? .now, messageCount: messages, cwd: cwd,
                                   automated: cron != nil, detail: agent == "main" ? detail : "\(detail) · agent \(agent)",
                                   location: .file(file))
    }

    // MARK: The SQLite store

    /// The sessions in an agent's database that hold a conversation.
    public static func previews(database: URL, agent: String) throws -> [ChatImportCandidate] {
        let db = try SQLiteReader(database)
        // User lines, and assistant lines that say something (one that only calls tools makes tool cards).
        let messageFilter = #"substr(event_json,1,17)='{"type":"message"' AND (instr(substr(event_json,1,300),'"role":"user"')>0 OR (instr(substr(event_json,1,300),'"role":"assistant"')>0 AND instr(event_json,'"type":"text","text":"')>0))"#
        var counts: [String: Int] = [:]
        try db.each("SELECT session_id, COUNT(*) FROM transcript_events WHERE \(messageFilter) GROUP BY session_id") { row in
            counts[row.text(0) ?? ""] = row.int(1)
        }
        var prompts: [String: String] = [:]
        try db.each(#"SELECT session_id, event_json FROM transcript_events WHERE (session_id, seq) IN (SELECT session_id, MIN(seq) FROM transcript_events WHERE substr(event_json,1,17)='{"type":"message"' AND instr(substr(event_json,1,300),'"role":"user"')>0 GROUP BY session_id)"#) { row in
            guard let id = row.text(0), let json = row.text(1), let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = event["message"] as? [String: Any] else { return }
            prompts[id] = ImportText.blocksText(message["content"])
        }
        var cwds: [String: String] = [:]
        try db.each(#"SELECT session_id, event_json FROM transcript_events WHERE substr(event_json,1,17)='{"type":"session"'"#) { row in
            guard let id = row.text(0), let json = row.text(1), let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = event["cwd"] as? String else { return }
            cwds[id] = cwd
        }
        var out: [ChatImportCandidate] = []
        try db.each("""
            SELECT w.session_id, w.session_key, COALESCE(NULLIF(n.label,''), NULLIF(n.display_name,''), NULLIF(w.display_name,'')),
                   w.created_at, w.updated_at, n.created_via
            FROM session_windows w LEFT JOIN session_nodes n ON n.session_key = w.session_key
            """) { row in
            guard let id = row.text(0), let messages = counts[id], messages > 0 else { return }
            let key = row.text(1)
            let via = row.text(5)
            let prompt = prompts[id]
            let cron = prompt.flatMap(cronName)
            let title = row.text(2) ?? cron.map { "Cron: \($0)" } ?? prompt.flatMap(ImportText.title(fromPrompt:)) ?? "OpenClaw session"
            let automated = isAutomatedKey(key) || ["cron", "spawn", "run"].contains(via ?? "") || cron != nil
            out.append(ChatImportCandidate(
                source: .openClaw, sourceID: id, title: title, createdAt: row.millis(3), updatedAt: row.millis(4) ?? .now,
                messageCount: messages, cwd: cwds[id], automated: automated, detail: detail(key: key, agent: agent, via: via),
                location: .openClawDatabase(database, sessionID: id)))
        }
        return out
    }

    /// One session from the database, on the branch it ended on.
    public static func read(database: URL, sessionID: String) throws -> ImportedChat? {
        let db = try SQLiteReader(database)
        var label: String?
        var key: String?
        var via: String?
        var created: Date?
        var updated: Date?
        try db.each("""
            SELECT w.session_key, COALESCE(NULLIF(n.label,''), NULLIF(n.display_name,''), NULLIF(w.display_name,'')),
                   w.created_at, w.updated_at, n.created_via
            FROM session_windows w LEFT JOIN session_nodes n ON n.session_key = w.session_key WHERE w.session_id = ?
            """, bind: [sessionID]) { row in
            key = row.text(0)
            label = row.text(1)
            created = row.millis(2)
            updated = row.millis(3)
            via = row.text(4)
        }
        var events: [([String: Any], Date?)] = []
        try db.each("SELECT event_json, created_at FROM transcript_events WHERE session_id = ? ORDER BY seq", bind: [sessionID]) { row in
            guard let json = row.text(0), let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            events.append((event, row.millis(1)))
        }
        let branch = activeBranch(events.map(\.0))
        let times = Dictionary(events.compactMap { pair in (pair.0["id"] as? String).map { ($0, pair.1) } },
                               uniquingKeysWith: { first, _ in first })
        var reading = Reading()
        reading.sessionID = sessionID
        for event in branch {
            let fallback = (event["id"] as? String).flatMap { times[$0] ?? nil }
            apply(event, fallbackAt: fallback, to: &reading)
        }
        reading.sessionID = sessionID
        return chat(from: reading, fallbackID: sessionID, label: label, key: key,
                    automatedHint: ["cron", "spawn", "run"].contains(via ?? ""), created: created, updated: updated)
    }
}

// MARK: - A read-only SQLite connection

/// The few calls the OpenClaw reader needs from SQLite: open read-only (another app keeps writing it), run a
/// query, read columns.
final class SQLiteReader {
    private var db: OpaquePointer?

    init(_ url: URL) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = components.string ?? "file:\(url.path)?mode=ro"
        let status = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, db != nil else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            if let db { sqlite3_close(db) }
            db = nil
            throw ChatImportError.unreadable("\(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else {
                return nil
            }
            return String(cString: raw)
        }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        /// An epoch-milliseconds column as a date.
        func millis(_ column: Int32) -> Date? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let value = sqlite3_column_int64(statement, column)
            return value > 0 ? ImportDates.epoch(Double(value)) : nil
        }
    }

    func each(_ sql: String, bind: [String] = [], _ body: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatImportError.unreadable("OpenClaw's session store: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                body(Row(statement: statement))
            } else if step == SQLITE_DONE {
                return
            } else {
                throw ChatImportError.unreadable("OpenClaw's session store: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }
}
