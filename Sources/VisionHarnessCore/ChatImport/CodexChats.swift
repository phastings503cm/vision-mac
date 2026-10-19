import Foundation

// MARK: - Codex CLI sessions (~/.codex/sessions)
//
// One "rollout" JSONL per session under `sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl` (archived ones under
// `archived_sessions/`). Each line is `{timestamp, type, payload}`:
//   session_meta {id, timestamp, cwd, originator, source}        — the first line
//   turn_context {model, cwd}                                    — per turn
//   event_msg {type:"user_message", message, images}             — what the person typed
//   response_item {type:"message", role:"assistant", content:[{type:"output_text", text}]}
//   response_item {type:"function_call", name, arguments, call_id} / {type:"function_call_output", call_id, output}
//   response_item {type:"custom_tool_call", name, input, call_id} / {type:"custom_tool_call_output", call_id, output}
//   response_item {type:"web_search_call", action:{query}} · {type:"local_shell_call", action:{command}}
//   event_msg {type:"thread_name_updated", thread_name} · {type:"turn_aborted"}
// Reasoning (encrypted) and token counts are skipped; environment and instruction messages (role user/developer
// response items) are not the person's words. Older rollouts had no wrapper — `{type:"message", role…}` at the top
// level — and no user_message events; their user messages are taken from the response items instead. Titles come from
// `session_index.jsonl` ({id, thread_name}) when Codex named the thread.

public enum CodexChats {
    /// `$CODEX_HOME` when set, else `~/.codex`.
    public static func home(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func sessionFiles(codexHome: URL) -> [URL] {
        var out: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder, isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Thread names Codex gave its sessions, by session id (the newest name wins).
    public static func threadNames(codexHome: URL) -> [String: String] {
        var names: [String: String] = [:]
        try? JSONLines.forEach(codexHome.appendingPathComponent("session_index.jsonl")) { line in
            if let id = line["id"] as? String, let name = line["thread_name"] as? String, !name.isEmpty { names[id] = name }
            return true
        }
        return names
    }

    public static func read(_ file: URL, names: [String: String] = [:]) throws -> ImportedChat? {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .alwaysMapped)
        } catch {
            throw ChatImportError.unreadable("\(file.lastPathComponent): \(error.localizedDescription)")
        }
        return parse(data, fallbackID: idFromFileName(file), names: names)
    }

    /// "rollout-2026-03-26T20-24-56-019d2d52-…-936aefd65446.jsonl" → the uuid at its end.
    static func idFromFileName(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        if parts.count >= 5 { return parts.suffix(5).joined(separator: "-") }
        return stem
    }

    public static func parse(_ data: Data, fallbackID: String, names: [String: String] = [:]) -> ImportedChat? {
        var builder = ImportTranscriptBuilder()
        var sessionID: String?
        var cwd: String?
        var model: String?
        var threadName: String?
        var first: Date?
        var last: Date?
        var scripted = false
        var sawUserEvents = false
        var lastAt = Date(timeIntervalSince1970: 0)
        // Everything in order; older rollouts carry the person's words only as response items, used when no
        // user_message event turns up.
        var items: [([String: Any], Date)] = []

        JSONLines.forEach(data) { line in
            let at = (line["timestamp"] as? String).flatMap(ImportDates.iso(_:)) ?? lastAt
            if at > Date(timeIntervalSince1970: 0) {
                first = first.map { min($0, at) } ?? at
                last = last.map { max($0, at) } ?? at
                lastAt = at
            }
            let kind = line["type"] as? String ?? ""
            let payload = line["payload"] as? [String: Any]
            switch kind {
            case "session_meta":
                if let meta = payload {
                    if sessionID == nil, let id = meta["id"] as? String { sessionID = id }
                    if cwd == nil, let folder = meta["cwd"] as? String, !folder.isEmpty { cwd = folder }
                    let originator = (meta["originator"] as? String ?? "").lowercased()
                    let source = (meta["source"] as? String ?? "").lowercased()
                    if originator.contains("exec") || source == "exec" { scripted = true }
                }
            case "turn_context":
                if let name = payload?["model"] as? String, !name.isEmpty { model = name }
                if cwd == nil, let folder = payload?["cwd"] as? String, !folder.isEmpty { cwd = folder }
            case "event_msg":
                guard let event = payload else { break }
                switch event["type"] as? String {
                case "user_message":
                    sawUserEvents = true
                    var text = event["message"] as? String ?? ""
                    let images = (event["images"] as? [Any])?.count ?? 0
                    if images > 0 { text += "\n[\(images) image\(images == 1 ? "" : "s")]" }
                    items.append((["__user": text], at))
                case "thread_name_updated":
                    if let name = event["thread_name"] as? String, !name.isEmpty { threadName = name }
                case "turn_aborted":
                    items.append((["__notice": "The turn was interrupted in Codex."], at))
                default:
                    break
                }
            case "response_item":
                if let item = payload { items.append((item, at)) }
            case "compacted":
                if let summary = payload?["message"] as? String, !summary.isEmpty { items.append((["__compaction": summary], at)) }
            case "message", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output",
                 "web_search_call", "local_shell_call":
                // An older rollout: response items at the top level.
                items.append((line, at))
            default:
                if sessionID == nil, let id = line["id"] as? String, line["instructions"] != nil || line["timestamp"] != nil,
                   kind.isEmpty {
                    sessionID = id   // an older rollout's first line: {id, timestamp, instructions}
                }
            }
            return true
        }

        for (item, at) in items {
            if let text = item["__user"] as? String { builder.user(text, at: at); continue }
            if let text = item["__notice"] as? String { builder.notice(text, at: at); continue }
            if let text = item["__compaction"] as? String { builder.compaction(text, at: at); continue }
            switch item["type"] as? String {
            case "message":
                let role = item["role"] as? String ?? ""
                let text = ImportText.blocksText(item["content"])
                if role == "assistant" {
                    builder.assistant(text, at: at)
                } else if role == "user", !sawUserEvents, !isInjected(text) {
                    builder.user(text, at: at)
                }
            case "function_call":
                builder.toolCall(id: item["call_id"] as? String, name: item["name"] as? String ?? "tool",
                                 input: item["arguments"], at: at)
            case "custom_tool_call":
                let name = item["name"] as? String ?? "tool"
                builder.toolCall(id: item["call_id"] as? String, name: name, input: patchSummary(item["input"]) ?? item["input"], at: at)
            case "function_call_output", "custom_tool_call_output":
                let (output, failed) = toolOutput(item["output"])
                builder.toolResult(id: item["call_id"] as? String, name: nil, output: output, isError: failed, at: at)
            case "web_search_call":
                let action = item["action"] as? [String: Any]
                builder.toolCall(id: nil, name: "web_search", input: action?["query"] ?? action, at: at)
                builder.toolResult(id: nil, name: "web_search", output: item["status"] as? String ?? "done", isError: false, at: at)
            case "local_shell_call":
                let action = item["action"] as? [String: Any]
                builder.toolCall(id: item["call_id"] as? String, name: "shell", input: ["command": action?["command"] ?? ""], at: at)
            default:
                break   // reasoning
            }
        }

        let rows = builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        let id = sessionID ?? fallbackID
        let title = names[id] ?? threadName ?? builder.firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "Codex session"
        let created = first ?? .now
        return ImportedChat(source: .codex, sourceID: id, title: title, createdAt: created, updatedAt: last ?? created,
                            cwd: cwd, model: model, rows: rows, automated: scripted)
    }

    /// Text Codex adds to a conversation that the person didn't type.
    static func isInjected(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("<environment_context>") || head.hasPrefix("<user_instructions>")
            || head.hasPrefix("<permissions") || head.hasPrefix("# AGENTS.md instructions") || head.hasPrefix("<INSTRUCTIONS>")
            || head.isEmpty
    }

    /// An apply_patch input as the files it touches ("Add File: a.sh, Update File: b.py").
    static func patchSummary(_ input: Any?) -> String? {
        guard let text = input as? String, text.contains("*** Begin Patch") else { return nil }
        let files = text.split(separator: "\n").compactMap { line -> String? in
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(4))
            }
            return nil
        }
        return files.isEmpty ? nil : files.joined(separator: ", ")
    }

    /// A tool output (a string, often JSON {output, metadata:{exit_code}}) and whether it failed.
    static func toolOutput(_ value: Any?) -> (String, Bool) {
        var text = ImportText.blocksText(value)
        var failed = false
        if let data = text.data(using: .utf8), text.first == "{",
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let output = object["output"] as? String { text = output }
            if let meta = object["metadata"] as? [String: Any], let code = meta["exit_code"] as? Int { failed = code != 0 }
        }
        if let range = text.range(of: "Process exited with code ") {
            let digits = text[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
            if let code = Int(digits) { failed = code != 0 }
        }
        return (text, failed)
    }
}
