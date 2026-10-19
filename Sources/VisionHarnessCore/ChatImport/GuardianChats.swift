import Foundation

// MARK: - Guardian chats
//
// Two kinds, both only when signed in:
//   • the person's Guardian chats — GET /api/chats (an array; also accepted as {chats:[…]}) for the list, then the
//     transcript a page at a time: GET /api/chats/:id?messages=latest&limit=200 (newest page + `paging`) and
//     GET /api/chats/:id/messages?before=<oldest id>&limit=200 until `hasMore` is false. A Guardian older than the
//     paging (no `paging` in the answer) returns the whole transcript in the first call.
//     Message: {id, role: USER | ASSISTANT | TOOL | SYSTEM, content, createdAt, modelId, origin,
//               toolCalls:[{id, name, args, output, status}]}
//   • the Vision chats the account keeps in Guardian — GET /api/harness/chats ({chats:[{id, title, updatedAt}]}) and
//     GET /api/harness/chats/:id → {payload} in Vision's chat shape (VisionChatFile).

/// One Guardian chat in the list.
public struct GuardianChatSummary: Sendable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: Date?
    public var updatedAt: Date
    public var model: String?
    /// Someone else's chat shared with this person (their name or email).
    public var sharedBy: String?
    /// A chat with one of the org's AI staff.
    public var person: String?

    public init(id: String, title: String, createdAt: Date? = nil, updatedAt: Date, model: String? = nil,
                sharedBy: String? = nil, person: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.model = model
        self.sharedBy = sharedBy
        self.person = person
    }

    public var candidate: ChatImportCandidate {
        let detail: String? = sharedBy.map { "Shared with you by \($0)" } ?? person.map { "With \($0)" }
        return ChatImportCandidate(source: .guardian, sourceID: id, title: title, createdAt: createdAt,
                                   updatedAt: updatedAt, messageCount: nil, detail: detail,
                                   location: .guardianChat(id))
    }
}

public enum GuardianChatImport {
    /// GET /api/chats's answer as summaries.
    public static func summaries(_ data: Data) -> [GuardianChatSummary] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let list = root as? [[String: Any]] ?? (root as? [String: Any])?["chats"] as? [[String: Any]] ?? []
        return list.compactMap { chat in
            guard let id = chat["id"] as? String else { return nil }
            let owner = chat["owner"] as? [String: Any]
            let person = chat["person"] as? [String: Any]
            let shared = chat["sharedWithMe"] as? Bool == true
            return GuardianChatSummary(
                id: id, title: (chat["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Guardian chat",
                createdAt: ImportDates.any(chat["createdAt"]), updatedAt: ImportDates.any(chat["updatedAt"]) ?? .now,
                model: chat["modelId"] as? String,
                sharedBy: shared ? (owner?["name"] as? String ?? owner?["email"] as? String ?? "someone") : nil,
                person: person?["displayName"] as? String)
        }
    }

    /// A Guardian chat's messages (oldest first) as a Vision chat.
    public static func chat(summary: GuardianChatSummary, messages: [[String: Any]]) -> ImportedChat? {
        var builder = ImportTranscriptBuilder()
        var last = summary.createdAt ?? summary.updatedAt
        for message in messages {
            let at = ImportDates.any(message["createdAt"]) ?? last
            last = max(last, at)
            let content = message["content"] as? String ?? ""
            switch (message["role"] as? String ?? "").uppercased() {
            case "USER":
                let origin = message["origin"] as? String
                if origin == "system" {
                    builder.notice(content, at: at)
                } else {
                    builder.user(content, at: at)
                }
            case "ASSISTANT":
                // The tools a turn ran came before its final words.
                for call in message["toolCalls"] as? [[String: Any]] ?? [] {
                    let name = call["name"] as? String ?? "tool"
                    builder.toolCall(id: call["id"] as? String, name: name, input: call["args"] ?? call["input"], at: at)
                    if let output = call["output"] {
                        let status = (call["status"] as? String ?? "").lowercased()
                        builder.toolResult(id: call["id"] as? String, name: name, output: ImportText.blocksText(output),
                                           isError: status == "error" || status == "failed", at: at)
                    }
                }
                builder.assistant(content, at: at, join: false)
            case "TOOL":
                builder.toolResult(id: nil, name: message["name"] as? String, output: content, isError: false, at: at)
            default:
                continue   // SYSTEM rows are Guardian's own instructions
            }
        }
        let rows = builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        return ImportedChat(source: .guardian, sourceID: summary.id, title: summary.title,
                            createdAt: summary.createdAt ?? rows.first?.at ?? summary.updatedAt,
                            updatedAt: max(summary.updatedAt, last), model: summary.model, rows: rows)
    }

    /// A Vision chat kept in Guardian, from its stored payload.
    public static func harnessChat(id: String, title: String, updatedAt: Date, payload: Data) -> ImportedChat? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        guard var chat = VisionChatFile.chat(from: object, fallbackID: id, fallbackTitle: title, fallbackUpdated: updatedAt) else {
            return nil
        }
        if chat.source == .vision { chat.sourceID = id }
        return chat
    }

    public static func harnessCandidate(id: String, title: String, updatedAt: Date) -> ChatImportCandidate {
        ChatImportCandidate(source: .vision, sourceID: id, title: title.isEmpty ? "Vision chat" : title, updatedAt: updatedAt,
                            messageCount: nil, detail: "Kept in Guardian", location: .guardianHarnessChat(id),
                            preferredID: VisionChatFile.isSafeID(id) ? id : nil)
    }
}

extension GuardianClient {
    /// The person's Guardian chats (theirs and those shared with them), newest first.
    public func guardianChats() async throws -> [GuardianChatSummary] {
        GuardianChatImport.summaries(try await get(path: "/api/chats"))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// One Guardian chat, read whole, as a Vision chat (nil when it holds no messages).
    public func importGuardianChat(_ summary: GuardianChatSummary) async throws -> ImportedChat? {
        GuardianChatImport.chat(summary: summary, messages: try await guardianChatMessages(id: summary.id))
    }

    /// A Vision chat the account keeps in Guardian, as a chat to import.
    public func importHarnessChat(id: String, title: String, updatedAt: Date) async throws -> ImportedChat? {
        GuardianChatImport.harnessChat(id: id, title: title, updatedAt: updatedAt, payload: try await chat(id: id))
    }

    /// One Guardian chat's whole transcript, oldest first, read a page at a time.
    func guardianChatMessages(id: String, pageSize: Int = 200, maxPages: Int = 500) async throws -> [[String: Any]] {
        let first = try await get(path: "/api/chats/\(id)",
                                  query: [URLQueryItem(name: "messages", value: "latest"),
                                          URLQueryItem(name: "limit", value: String(pageSize))])
        guard let root = try JSONSerialization.jsonObject(with: first) as? [String: Any] else {
            throw GuardianError.server("Guardian's answer for that chat wasn't readable.")
        }
        var messages = root["messages"] as? [[String: Any]] ?? []
        // No paging: an older Guardian sent the whole transcript.
        guard let paging = root["paging"] as? [String: Any] else { return messages }
        var hasMore = paging["hasMore"] as? Bool ?? false
        var before = paging["before"] as? String ?? (messages.first?["id"] as? String)
        var pages = 1
        while hasMore, let cursor = before, pages < maxPages {
            let data = try await get(path: "/api/chats/\(id)/messages",
                                     query: [URLQueryItem(name: "before", value: cursor),
                                             URLQueryItem(name: "limit", value: String(pageSize))])
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
            let older = page["messages"] as? [[String: Any]] ?? []
            if older.isEmpty { break }
            messages = older + messages
            let nested = page["paging"] as? [String: Any]
            hasMore = page["hasMore"] as? Bool ?? nested?["hasMore"] as? Bool ?? false
            before = page["before"] as? String ?? nested?["before"] as? String ?? (older.first?["id"] as? String)
            pages += 1
        }
        return messages
    }
}
