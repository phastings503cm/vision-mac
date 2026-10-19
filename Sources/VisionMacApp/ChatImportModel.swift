import Foundation
import Observation
import VisionHarnessCore

/// The Import Chats sheet's state: what each source holds (looked for on open, a few files at a time, off the main
/// thread), what the person ticked, and the import itself. Chats already here are shown as imported and can't be
/// ticked, so importing again brings only the new ones.
@MainActor
@Observable
final class ChatImportModel {
    enum SourceState: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case ready(Int)
        case missing
        case signedOut
        case failed(String)
    }

    let transport: AppTransport
    @ObservationIgnored let guardian: GuardianService?
    @ObservationIgnored let scanner: ChatImportScanner

    var states: [ChatSource: SourceState] = [:]
    private(set) var candidates: [ChatImportCandidate] = []
    /// Chats read whole while scanning (export files, Vision files), by candidate id.
    @ObservationIgnored private var loaded: [String: ImportedChat] = [:]
    var picked: Set<String> = []
    private(set) var importedKeys: Set<String> = []
    /// Scheduled runs and scripted sessions are hidden unless asked for.
    var showAutomated = false
    var filter = ""
    /// Only this source's chats (nil: every source).
    var sourceFilter: ChatSource?
    private(set) var importing = false
    private(set) var progress = (done: 0, total: 0)
    var result: String?
    private(set) var problems: [String] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(transport: AppTransport, guardian: GuardianService?, scanner: ChatImportScanner? = nil) {
        self.transport = transport
        self.guardian = guardian
        self.scanner = scanner ?? ChatImportScanner(
            home: transport.skillLocations.home,
            cacheFolder: AppPaths.support.appendingPathComponent("chat-import-cache", isDirectory: true))
        importedKeys = transport.importedKeys()
    }

    // MARK: Looking

    /// Look at every source: this Mac's tools, and Guardian when signed in.
    func lookEverywhere() {
        for source in ChatSource.local { look(source) }
        lookInGuardian()
    }

    func look(_ source: ChatSource) {
        if case .scanning = states[source] { return }
        let scanner = scanner
        guard scanner.isPresent(source) else {
            states[source] = .missing
            return
        }
        states[source] = .scanning(done: 0, total: 0)
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let model = self else { return }
            Task { @MainActor in
                if case .scanning = model.states[source] { model.states[source] = .scanning(done: done, total: total) }
            }
        }
        Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) { scanner.scan(source, progress: report) }.value
            self?.take(scan, for: source)
        }
    }

    func lookInGuardian() {
        guard let guardian, guardian.isSignedIn, let client = guardian.client else {
            states[.guardian] = .signedOut
            return
        }
        if case .scanning = states[.guardian] { return }
        states[.guardian] = .scanning(done: 0, total: 0)
        Task { [weak self] in
            var scan = ChatImportScan()
            do {
                scan.candidates = try await client.guardianChats().map(\.candidate)
            } catch {
                scan.problems.append("Guardian chats: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
            // The Vision chats the account keeps in Guardian (sent from this or another harness).
            if let kept = try? await client.chats() {
                scan.candidates += kept.map { GuardianChatImport.harnessCandidate(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
            }
            self?.take(scan, for: .guardian)
        }
    }

    /// A Claude.ai or ChatGPT export, a Vision JSON file, or a folder holding one.
    func add(file url: URL) {
        let name = url.lastPathComponent
        Task { [weak self] in
            let outcome: Result<ChatImportScan, Error> = await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return Result { try ExportFileChats.read(url) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let scan):
                for (key, chat) in scan.loaded { self.loaded[key] = chat }
                self.merge(scan.candidates)
                self.problems += scan.problems
                if let source = scan.candidates.first?.source { self.states[source] = .ready(self.count(source)) }
                // What a file holds is what the person came for: tick its new chats.
                self.picked.formUnion(scan.candidates.filter { !self.isImported($0) }.map(\.id))
                self.result = "\(name): \(scan.candidates.count) chat\(scan.candidates.count == 1 ? "" : "s") found."
            case .failure(let error):
                self.result = (error as? LocalizedError)?.errorDescription ?? "\(name): \(error)"
            }
        }
    }

    private func take(_ scan: ChatImportScan, for source: ChatSource) {
        candidates.removeAll { $0.source == source || (source == .guardian && $0.location.isGuardian) }
        for (key, chat) in scan.loaded { loaded[key] = chat }
        merge(scan.candidates)
        problems += scan.problems.prefix(5)
        states[source] = scan.candidates.isEmpty && !scan.problems.isEmpty
            ? .failed(scan.problems.first ?? "") : .ready(scan.candidates.count)
    }

    private func merge(_ found: [ChatImportCandidate]) {
        var byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in found { byID[candidate.id] = candidate }
        candidates = byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func count(_ source: ChatSource) -> Int { candidates.filter { $0.source == source }.count }

    // MARK: Choosing

    func isImported(_ candidate: ChatImportCandidate) -> Bool {
        transport.isAlreadyImported(candidate, keys: importedKeys)
    }

    /// The chats the list shows: the source chosen, the filter typed, scheduled runs only when asked for.
    var visible: [ChatImportCandidate] {
        let words = ChatSearch.terms(filter)
        return candidates.filter { candidate in
            if let sourceFilter, candidate.source != sourceFilter, !(sourceFilter == .guardian && candidate.location.isGuardian) {
                return false
            }
            if candidate.automated, !showAutomated { return false }
            guard !words.isEmpty else { return true }
            let haystack = [candidate.title, candidate.detail ?? "", candidate.cwd ?? "", candidate.source.label]
                .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var automatedCount: Int { candidates.filter(\.automated).count }

    func toggle(_ candidate: ChatImportCandidate) {
        guard !isImported(candidate) else { return }
        if picked.contains(candidate.id) { picked.remove(candidate.id) } else { picked.insert(candidate.id) }
    }

    func selectAllShown() {
        picked.formUnion(visible.filter { !isImported($0) }.map(\.id))
    }

    func selectNone() { picked.removeAll() }

    var pickedCount: Int { candidates.filter { picked.contains($0.id) && !isImported($0) }.count }

    // MARK: Importing

    func importPicked() {
        let chosen = candidates.filter { picked.contains($0.id) && !isImported($0) }
        guard !chosen.isEmpty, !importing else { return }
        importing = true
        result = nil
        progress = (0, chosen.count)
        importTask = Task { [weak self] in
            await self?.run(chosen)
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func run(_ chosen: [ChatImportCandidate]) async {
        var total = ChatImportResult()
        var batch: [ImportedChat] = []
        let scanner = scanner
        let client = guardian?.client
        func flush() {
            guard !batch.isEmpty else { return }
            let done = transport.importChats(batch)
            total.imported += done.imported
            total.messages += done.messages
            total.alreadyHere += done.alreadyHere
            total.empty += done.empty
            batch.removeAll()
        }
        for candidate in chosen {
            if Task.isCancelled { break }
            do {
                let chat: ImportedChat?
                switch candidate.location {
                case .loaded:
                    chat = loaded[candidate.id]
                case .file, .openClawDatabase:
                    chat = try await Task.detached(priority: .userInitiated) { try scanner.read(candidate) }.value
                case .guardianChat:
                    guard let client else { throw GuardianError.unauthorized }
                    chat = try await client.importGuardianChat(GuardianChatSummary(
                        id: candidate.sourceID, title: candidate.title, createdAt: candidate.createdAt,
                        updatedAt: candidate.updatedAt))
                case .guardianHarnessChat(let id):
                    guard let client else { throw GuardianError.unauthorized }
                    chat = try await client.importHarnessChat(id: id, title: candidate.title, updatedAt: candidate.updatedAt)
                }
                if let chat { batch.append(chat) } else { total.empty += 1 }
            } catch {
                total.failed.append("\(candidate.title): " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
            progress.done += 1
            // A few at a time: a long session can be tens of megabytes.
            if batch.count >= 8 { flush() }
        }
        flush()
        importedKeys = transport.importedKeys()
        picked.subtract(candidates.filter(isImported).map(\.id))
        importing = false
        problems = total.failed + problems
        result = (Task.isCancelled ? "Stopped. " : "") + total.summary
    }
}

extension ChatImportLocation {
    var isGuardian: Bool {
        switch self {
        case .guardianChat, .guardianHarnessChat: true
        default: false
        }
    }
}
