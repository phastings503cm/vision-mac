import Foundation

// MARK: - Chats from a file the person picks
//
// A Claude.ai data export and a ChatGPT data export are both a ZIP with a `conversations.json` at its top; either the
// ZIP, the unzipped folder or the conversations.json itself can be chosen. A Vision chat (Export as JSON, or the
// payload a Vision harness keeps in Guardian) is a .json file. The format is told from the content, not the name.
//
// Claude.ai: [{uuid, name, created_at, updated_at, chat_messages:[{sender:"human"|"assistant", created_at, text,
//   content:[text | thinking | tool_use {name, input} | tool_result {name, content, is_error}],
//   attachments:[{file_name, extracted_content}], files:[{file_name}]}]}]
// ChatGPT: [{id | conversation_id, title, create_time, update_time (epoch seconds), current_node,
//   mapping:{<node>:{message:{author:{role, name}, create_time, content:{content_type, parts | text | …}, recipient,
//   metadata}, parent, children}}}] — a tree (every edit or regenerate branches it); the branch imported is the one
//   ending at current_node, which is the one ChatGPT showed.
// Vision: {id, title, cwd, rows:[{kind, text, toolName, argSummary, output, isError, at}]} — `at` in Apple
//   reference-date seconds (what Vision for macOS 0.15 writes, and what Guardian keeps) or ISO-8601 text (a JSON
//   export, `"format":"vision-chat"`).

public enum ExportFileChats {
    /// The biggest conversations.json read out of a ZIP.
    public static let maxConversationsBytes = 1_024 * 1_024 * 1_024

    /// Everything a picked file (or folder) holds.
    public static func read(_ url: URL) throws -> ChatImportScan {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ChatImportError.unreadable("\(name) is gone.")
        }
        if isDirectory.boolValue {
            for candidate in [url.appendingPathComponent("conversations.json")] + subfolderJSON(url) {
                if FileManager.default.fileExists(atPath: candidate.path) { return try read(candidate) }
            }
            throw ChatImportError.unknownFormat(name)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw ChatImportError.unreadable("\(name): \(error.localizedDescription)")
        }
        if ZipArchive.looksLikeZip(data) {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(data)
            } catch ZipArchive.ZipError.unsupported(let what) {
                throw ChatImportError.unreadable("\(name) uses \(what), which Vision can't open — unzip it and choose the folder.")
            } catch {
                throw ChatImportError.unreadable("\(name) isn't a ZIP Vision can open — unzip it and choose the folder.")
            }
            guard let entry = archive.entries
                .filter({ $0.name == "conversations.json" || $0.name.hasSuffix("/conversations.json") })
                .min(by: { $0.name.count < $1.name.count }) else {
                throw ChatImportError.unknownFormat(name)
            }
            let json: Data
            do {
                json = try archive.read(entry, limit: maxConversationsBytes)
            } catch {
                throw ChatImportError.unreadable("\(name)'s conversations.json couldn't be read out (\(error)) — unzip it and choose the folder.")
            }
            return try parse(json, name: name)
        }
        return try parse(data, name: name)
    }

    private static func subfolderJSON(_ url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.appendingPathComponent("conversations.json") }
    }

    /// A JSON document's chats, whichever format it is.
    public static func parse(_ data: Data, name: String) throws -> ChatImportScan {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ChatImportError.unknownFormat(name)
        }
        var list: [[String: Any]]?
        if let array = root as? [[String: Any]] {
            list = array
        } else if let object = root as? [String: Any] {
            if object["rows"] is [Any] {
                guard let chat = VisionChatFile.chat(from: object) else { throw ChatImportError.empty(name) }
                return ChatImportScan(chats: [chat])
            }
            if let chats = object["chats"] as? [[String: Any]], chats.first?["rows"] != nil {
                let read = chats.compactMap { VisionChatFile.chat(from: $0) }
                guard !read.isEmpty else { throw ChatImportError.empty(name) }
                return ChatImportScan(chats: read)
            }
            list = object["conversations"] as? [[String: Any]]
        }
        guard let list else { throw ChatImportError.unknownFormat(name) }
        guard let sample = list.first else { throw ChatImportError.empty(name) }
        let chats: [ImportedChat]
        if sample["mapping"] != nil {
            chats = list.compactMap(ChatGPTExport.chat(from:))
        } else if sample["chat_messages"] != nil {
            chats = list.compactMap(ClaudeAIExport.chat(from:))
        } else if sample["rows"] != nil {
            chats = list.compactMap { VisionChatFile.chat(from: $0) }
        } else {
            throw ChatImportError.unknownFormat(name)
        }
        guard !chats.isEmpty else { throw ChatImportError.empty(name) }
        let skipped = list.count - chats.count
        return ChatImportScan(chats: chats, problems: skipped > 0
                              ? ["\(skipped) conversation\(skipped == 1 ? "" : "s") in \(name) had no messages and \(skipped == 1 ? "was" : "were") left out."] : [])
    }
}

// MARK: - Claude.ai

public enum ClaudeAIExport {
    public static func chat(from conversation: [String: Any]) -> ImportedChat? {
        guard let id = conversation["uuid"] as? String ?? conversation["id"] as? String,
              let messages = conversation["chat_messages"] as? [[String: Any]] else { return nil }
        let created = ImportDates.any(conversation["created_at"]) ?? .now
        var builder = ImportTranscriptBuilder()
        var last = created
        for message in messages {
            let at = ImportDates.any(message["created_at"]) ?? last
            last = max(last, at)
            let human = (message["sender"] as? String ?? "") == "human"
            var parts: [String] = []
            if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        let text = block["text"] as? String ?? ""
                        if human { parts.append(text) } else { builder.assistant(text, at: at) }
                    case "tool_use":
                        builder.toolCall(id: block["id"] as? String, name: block["name"] as? String ?? "tool",
                                         input: block["input"], at: at)
                    case "tool_result":
                        builder.toolResult(id: block["tool_use_id"] as? String, name: block["name"] as? String,
                                           output: ImportText.blocksText(block["content"]),
                                           isError: block["is_error"] as? Bool ?? false, at: at)
                    default:
                        break   // thinking, token budgets, voice notes
                    }
                }
            } else if let text = message["text"] as? String {
                if human { parts.append(text) } else { builder.assistant(text, at: at) }
            }
            guard human else { continue }
            for attachment in message["attachments"] as? [[String: Any]] ?? [] {
                let file = attachment["file_name"] as? String ?? "file"
                if let content = attachment["extracted_content"] as? String, !content.isEmpty {
                    parts.append("[Attached: \(file)]\n" + ImportText.clip(content, ChatImportLimits.toolOutput))
                } else {
                    parts.append("[Attached: \(file)]")
                }
            }
            for file in message["files"] as? [[String: Any]] ?? [] {
                parts.append("[Attached: \(file["file_name"] as? String ?? "file")]")
            }
            builder.user(parts.joined(separator: "\n\n"), at: at)
        }
        let rows = builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        let name = (conversation["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? builder.firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "Claude.ai chat" : name
        return ImportedChat(source: .claudeAI, sourceID: id, title: title, createdAt: created,
                            updatedAt: ImportDates.any(conversation["updated_at"]) ?? last, rows: rows)
    }
}

// MARK: - ChatGPT

public enum ChatGPTExport {
    /// The nodes on the branch ChatGPT showed, oldest first.
    static func branch(_ mapping: [String: [String: Any]], current: String?) -> [[String: Any]] {
        var node: String? = current
        if node == nil || mapping[node!] == nil {
            // No current node: from the root, follow the newest child down.
            node = mapping.first { ($0.value["parent"] as? String) == nil }?.key
            while let id = node, let children = mapping[id]?["children"] as? [String], let next = children.last {
                node = next
            }
        }
        var chain: [[String: Any]] = []
        var seen = Set<String>()
        while let id = node, let entry = mapping[id], seen.insert(id).inserted {
            chain.append(entry)
            node = entry["parent"] as? String
        }
        return chain.reversed()
    }

    static func text(_ content: [String: Any]) -> String {
        switch content["content_type"] as? String {
        case "text", "multimodal_text":
            return (content["parts"] as? [Any] ?? []).compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let object = part as? [String: Any] else { return nil }
                if let text = object["text"] as? String { return text }
                let type = object["content_type"] as? String ?? ""
                if type.contains("image") { return "[image]" }
                if type.contains("audio") { return "[audio]" }
                return nil
            }.joined(separator: "\n")
        case "code", "execution_output", "system_error":
            return content["text"] as? String ?? ""
        case "tether_quote":
            return [content["title"] as? String, content["url"] as? String, content["text"] as? String]
                .compactMap { $0 }.joined(separator: "\n")
        case "tether_browsing_display":
            return content["result"] as? String ?? content["summary"] as? String ?? ""
        default:
            return content["text"] as? String ?? ""
        }
    }

    public static func chat(from conversation: [String: Any]) -> ImportedChat? {
        guard let mapping = conversation["mapping"] as? [String: [String: Any]],
              let id = conversation["conversation_id"] as? String ?? conversation["id"] as? String else { return nil }
        let created = ImportDates.any(conversation["create_time"]) ?? .now
        var builder = ImportTranscriptBuilder()
        var last = created
        var model: String?
        for node in branch(mapping, current: conversation["current_node"] as? String) {
            guard let message = node["message"] as? [String: Any],
                  let content = message["content"] as? [String: Any] else { continue }
            let metadata = message["metadata"] as? [String: Any] ?? [:]
            if metadata["is_visually_hidden_from_conversation"] as? Bool == true { continue }
            let author = message["author"] as? [String: Any] ?? [:]
            let role = author["role"] as? String ?? ""
            let type = content["content_type"] as? String ?? ""
            let at = ImportDates.any(message["create_time"]) ?? last
            last = max(last, at)
            if let slug = metadata["model_slug"] as? String, !slug.isEmpty { model = slug }
            let body = text(content)
            switch role {
            case "user":
                guard type == "text" || type == "multimodal_text" else { continue }
                builder.user(body, at: at)
            case "assistant":
                if ["thoughts", "reasoning_recap", "model_editable_context"].contains(type) { continue }
                let recipient = message["recipient"] as? String ?? "all"
                if recipient != "all" {
                    builder.toolCall(id: nil, name: recipient, input: body, at: at)
                } else if type == "text" || type == "multimodal_text" || type == "code" {
                    builder.assistant(body, at: at)
                }
            case "tool":
                let name = author["name"] as? String
                builder.toolResult(id: nil, name: name, output: body, isError: type == "system_error", at: at)
            default:
                continue   // system: custom instructions and the like
            }
        }
        let rows = builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        let title = (conversation["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? builder.firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "ChatGPT chat"
        return ImportedChat(source: .chatGPT, sourceID: id, title: title, createdAt: created,
                            updatedAt: ImportDates.any(conversation["update_time"]) ?? last,
                            model: model ?? conversation["default_model_slug"] as? String, rows: rows)
    }
}

// MARK: - Vision's own chat files

public enum VisionChatFile {
    /// 2001-01-01T00:00:00Z — Foundation's reference date, the zero of the dates Vision for macOS 0.15 writes.
    static let appleEpoch = Date(timeIntervalSinceReferenceDate: 0)
    static let kinds: Set<String> = ["user", "assistant", "tool", "notice", "error", "compaction"]

    /// A number is Apple reference-date seconds unless it's too big to be (then epoch milliseconds); text is ISO-8601.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is String) {
            let seconds = number.doubleValue
            return seconds > 100_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000)
                : Date(timeIntervalSinceReferenceDate: seconds)
        }
        if let text = value as? String { return ImportDates.iso(text) }
        return nil
    }

    /// A chat id fit to be a file name in the conversations folder.
    public static func isSafeID(_ id: String) -> Bool {
        (1...120).contains(id.count) && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }

    public static func chat(from object: [String: Any], fallbackID: String? = nil, fallbackTitle: String? = nil,
                            fallbackUpdated: Date? = nil) -> ImportedChat? {
        guard let list = object["rows"] as? [[String: Any]] else { return nil }
        let id = object["id"] as? String ?? fallbackID ?? UUID().uuidString
        var rows: [ImportedRow] = []
        for item in list {
            var kind = item["kind"] as? String ?? ""
            var text = item["text"] as? String
            if kind == "todos" {
                kind = "notice"
                text = "Plan:\n" + (text ?? "")
            }
            guard kinds.contains(kind), let rowKind = ImportedRow.Kind(rawValue: kind) else { continue }
            rows.append(ImportedRow(kind: rowKind, text: text, toolName: item["toolName"] as? String,
                                    argSummary: item["argSummary"] as? String, output: item["output"] as? String,
                                    isError: item["isError"] as? Bool ?? false,
                                    at: date(item["at"]) ?? rows.last?.at ?? fallbackUpdated ?? .now))
        }
        guard !rows.isEmpty else { return nil }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle ?? "Vision chat"
        // A chat Vision itself imported keeps where it really came from, so the same Claude Code session imported on
        // two Macs is one chat.
        let origin = (object["source"] as? String).flatMap(ChatSource.init(rawValue:))
        let originID = object["sourceId"] as? String
        let source = (origin != nil && originID != nil) ? origin! : .vision
        let created = date(object["createdAt"]) ?? rows.first?.at ?? .now
        let updated = date(object["updatedAt"]) ?? fallbackUpdated ?? rows.last?.at ?? created
        return ImportedChat(source: source, sourceID: source == .vision ? id : originID!, title: title,
                            createdAt: created, updatedAt: updated, cwd: object["cwd"] as? String, rows: rows,
                            preferredID: isSafeID(id) ? id : nil)
    }
}
