import Foundation
import Observation
import VisionHarnessCore

/// The search across every chat (the chat list's search field, ⇧⌘F): an index of each chat's title and what was
/// said, built off the main thread the first time the person searches and refreshed for chats that changed since;
/// each search runs off the main thread a moment after the typing stops.
@MainActor
@Observable
final class ChatSearchModel {
    var query = "" { didSet { if query != oldValue { schedule() } } }
    var scope: ChatSearchScope = .all { didSet { if scope != oldValue { schedule() } } }
    private(set) var hits: [ChatSearchHit] = []
    private(set) var searching = false
    /// Bumped by ⇧⌘F so the field takes focus.
    var focusRequest = 0

    @ObservationIgnored weak var transport: AppTransport?
    @ObservationIgnored private var documents: [String: ChatSearchDocument] = [:]
    @ObservationIgnored private var stamps: [String: Date] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Wait this long after the last keystroke.
    @ObservationIgnored var debounce: TimeInterval = 0.25

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func clear() {
        query = ""
        hits = []
    }

    private func schedule() {
        pending?.cancel()
        guard isActive else {
            hits = []
            searching = false
            return
        }
        searching = true
        let delay = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// Search now (tests call this directly).
    func run() async {
        await refreshIndex()
        let query = query
        let scope = scope
        let docs = Array(documents.values)
        let found = await Task.detached(priority: .userInitiated) {
            ChatSearch.search(query, in: docs, scope: scope)
        }.value
        guard query == self.query, scope == self.scope else { return }
        hits = found
        searching = false
    }

    /// Bring the index up to date: chats added or changed since it was built are read again, deleted ones dropped.
    func refreshIndex() async {
        guard let transport else { return }
        let sources = transport.searchSources()
        let present = Set(sources.map(\.id))
        for id in documents.keys where !present.contains(id) {
            documents[id] = nil
            stamps[id] = nil
        }
        let changed = sources.filter { stamps[$0.id] != $0.updatedAt || documents[$0.id]?.title != $0.title }
        guard !changed.isEmpty else { return }
        let jobs = changed.map { ($0.id, $0.title, $0.source, $0.updatedAt, $0.file, $0.loaded) }
        let built: [ChatSearchDocument] = await Task.detached(priority: .userInitiated) {
            jobs.map { job in
                let (id, title, source, updatedAt, file, loaded) = job
                let rows = loaded ?? ConversationLog.readRows(at: file, sessionID: id) ?? []
                return ChatSearchDocument(chatID: id, title: title, source: source, updatedAt: updatedAt,
                                          rows: rows.compactMap { row in
                    ChatSearchDocument.row(seq: row.seq, kind: row.kind, text: row.text, toolName: row.toolName,
                                           argSummary: row.argSummary, output: row.output, at: row.at)
                })
            }
        }.value
        for document in built {
            documents[document.chatID] = document
            stamps[document.chatID] = document.updatedAt
        }
    }
}
