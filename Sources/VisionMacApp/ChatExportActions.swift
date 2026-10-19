import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionHarnessCore

// MARK: - A chat going out: Export as Markdown / JSON, Send to Guardian
//
// From File ▸ Export Chat, the chat list's context menu, and Settings ▸ Import & Export. The result is said in the
// banner at the top of the window.

@MainActor
enum ChatExportActions {
    enum Format {
        case markdown, json

        var ext: String { self == .markdown ? "md" : "json" }
        var type: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json }
        var label: String { self == .markdown ? "Markdown" : "JSON" }
    }

    /// The file's bytes for a chat (tests use this; the menu goes through `save`).
    static func data(_ format: Format, for doc: ChatExportDocument, exportedAt: Date = .now) -> Data {
        switch format {
        case .markdown: Data(ChatExport.markdown(doc, exportedAt: exportedAt).utf8)
        case .json: ChatExport.json(doc, exportedAt: exportedAt)
        }
    }

    /// Ask where, then write the chat there.
    static func save(_ format: Format, sessionID: String?, transport: AppTransport) {
        guard let sessionID, let doc = transport.exportDocument(sessionID) else {
            transport.note("Pick a chat to export first.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Chat as \(format.label)"
        panel.nameFieldStringValue = ChatExport.fileName(doc.title, ext: format.ext)
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data(format, for: doc).write(to: url, options: .atomic)
            transport.note("Saved “\(doc.title)” as \(url.lastPathComponent).")
        } catch {
            transport.note("Couldn't save the chat: \(error.localizedDescription)")
        }
    }

    static func sendToGuardian(sessionID: String?, transport: AppTransport, guardian: GuardianService) {
        guard let sessionID, let doc = transport.exportDocument(sessionID) else {
            transport.note("Pick a chat to send first.")
            return
        }
        Task { @MainActor in
            transport.note(await guardian.sendChat(doc))
        }
    }
}

extension GuardianService {
    /// What a chat going to Guardian is masked with: the vault's secrets always, the shield's finds when it is on
    /// (nil: nothing to mask — the vault is empty and the shield is off).
    nonisolated static func chatMask() -> SensitiveDetector? { ProviderClients.shield?.detector() }

    /// A chat as it goes up: masked (off the main thread — a long chat is megabytes), then encoded.
    nonisolated static func upload(_ doc: ChatExportDocument, mask: SensitiveDetector?) async -> (title: String, payload: Data) {
        await Task.detached(priority: .userInitiated) {
            let out = doc.masked(by: mask)
            return (out.title, ChatExport.guardianPayload(out))
        }.value
    }

    /// Keep one chat in the account's Guardian (`POST /api/harness/chats/:id`), where any Vision harness on the
    /// account can import it. Secrets are masked first (`chatMask`). Returns what happened, in words.
    func sendChat(_ doc: ChatExportDocument, mask: SensitiveDetector? = GuardianService.chatMask()) async -> String {
        guard isSignedIn, let client else { return "Sign in to Guardian first (Settings ▸ Guardian)." }
        let (title, payload) = await Self.upload(doc, mask: mask)
        guard payload.count <= ChatExport.maxGuardianPayloadBytes else {
            return "“\(doc.title)” is over 25 MB, the most Guardian keeps for one chat — export it as JSON instead."
        }
        do {
            try await client.putChat(id: doc.id, title: title, updatedAt: doc.updatedAt, payload: payload)
            return "Sent “\(doc.title)” to Guardian."
        } catch {
            return "Couldn't send “\(doc.title)” to Guardian: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Every chat on this Mac to Guardian (Settings ▸ Guardian ▸ Export all chats), masked like one chat. Chats over
    /// 25 MB stay here.
    func sendAllChats(from transport: AppTransport, mask: SensitiveDetector? = GuardianService.chatMask(),
                      progress: ((Int, Int) -> Void)? = nil) async -> String {
        guard isSignedIn, let client else { return "Sign in to Guardian first (Settings ▸ Guardian)." }
        let ids = transport.sessions.map(\.id)
        var sent = 0
        var tooBig = 0
        for (index, id) in ids.enumerated() {
            guard let doc = transport.exportDocument(id), !doc.rows.isEmpty else { continue }
            let (title, payload) = await Self.upload(doc, mask: mask)
            if payload.count > ChatExport.maxGuardianPayloadBytes {
                tooBig += 1
                continue
            }
            do {
                try await client.putChat(id: doc.id, title: title, updatedAt: doc.updatedAt, payload: payload)
                sent += 1
            } catch {
                return "Exported \(sent) chat\(sent == 1 ? "" : "s") to Guardian, then: "
                    + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            progress?(index + 1, ids.count)
        }
        return "Exported \(sent) chat\(sent == 1 ? "" : "s") to Guardian." + (tooBig > 0 ? " \(tooBig) over 25 MB stayed here." : "")
    }
}
