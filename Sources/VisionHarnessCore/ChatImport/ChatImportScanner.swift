import Foundation

// MARK: - Finding chats on this Mac, and reading one whole
//
// A scan reads every session of a source once to fill the preview (title, dates, message count) and remembers the
// answer per file (path, size, modification time) in a small cache, so the next look only reads what changed: a
// re-import costs the new sessions, not the 6 GB a long Claude Code history can reach. Files are read a few at a time.

/// The preview answers already worked out, per file.
public struct ChatImportPreviewCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var size: Int
        public var modified: Double
        /// Nil: the file holds no conversation (nothing to offer).
        public var candidate: ChatImportCandidate?
    }

    public var version = 1
    public var entries: [String: Entry] = [:]

    public init() {}

    public static func load(_ url: URL?) -> ChatImportPreviewCache {
        guard let url, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ChatImportPreviewCache.self, from: data), cache.version == 1 else {
            return ChatImportPreviewCache()
        }
        return cache
    }

    public func save(_ url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func stamp(_ url: URL) -> (size: Int, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return (size, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
}

public struct ChatImportScanner: Sendable {
    public var home: URL
    public var environment: [String: String]
    /// The folder where preview answers are remembered between scans, one file per source (nil: not remembered).
    public var cacheFolder: URL?
    /// Files read side by side.
    public var parallel = 4

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment, cacheFolder: URL? = nil) {
        self.home = home
        self.environment = environment
        self.cacheFolder = cacheFolder
    }

    func cacheURL(_ source: ChatSource) -> URL? {
        cacheFolder?.appendingPathComponent("\(source.rawValue).json")
    }

    /// Whether a source has anything to look at on this Mac (cheap: folders only).
    public func isPresent(_ source: ChatSource) -> Bool {
        let fileManager = FileManager.default
        switch source {
        case .claudeCode: return fileManager.fileExists(atPath: ClaudeCodeChats.root(home: home, environment: environment).path)
        case .codex: return fileManager.fileExists(atPath: CodexChats.home(home: home, environment: environment)
            .appendingPathComponent("sessions").path)
        case .openClaw: return !OpenClawScanner.find(home: home, environment: environment).isEmpty
        default: return false
        }
    }

    /// The preview of one local source (Claude Code, Codex or OpenClaw). Reads files: call it off the main thread.
    public func scan(_ source: ChatSource, progress: (@Sendable (Int, Int) -> Void)? = nil) -> ChatImportScan {
        var cache = ChatImportPreviewCache.load(cacheURL(source))
        var seen = Set<String>()
        defer {
            // Files that are gone leave the cache.
            cache.entries = cache.entries.filter { seen.contains($0.key) }
            cache.save(cacheURL(source))
        }
        switch source {
        case .claudeCode:
            let files = ClaudeCodeChats.sessionFiles(root: ClaudeCodeChats.root(home: home, environment: environment))
            var scan = previewFiles(files, cache: &cache, seen: &seen, progress: progress) { file in
                guard let chat = try ClaudeCodeChats.read(file, preview: true) else { return nil }
                return ChatImportCandidate(chat, location: .file(file), detail: Self.claudeCodeDetail(chat))
            }
            // A session continued in a worktree is copied into the worktree's project folder too: one session id,
            // two files. Offer the fuller one (the other would block it, sharing its key, once imported).
            scan.candidates = ChatImportCandidate.onePerID(scan.candidates)
            return scan
        case .codex:
            let codexHome = CodexChats.home(home: home, environment: environment)
            let names = CodexChats.threadNames(codexHome: codexHome)
            var scan = previewFiles(CodexChats.sessionFiles(codexHome: codexHome), cache: &cache, seen: &seen, progress: progress) { file in
                guard let chat = try CodexChats.read(file, names: names) else { return nil }
                return ChatImportCandidate(chat, location: .file(file), detail: chat.cwd.map { ($0 as NSString).lastPathComponent })
            }
            // A thread renamed in Codex after the cache was filled shows its new name.
            for index in scan.candidates.indices {
                if let name = names[scan.candidates[index].sourceID] { scan.candidates[index].title = name }
            }
            // A rollout in both sessions/ and archived_sessions/ is offered once.
            scan.candidates = ChatImportCandidate.onePerID(scan.candidates)
            return scan
        case .openClaw:
            return scanOpenClaw(cache: &cache, seen: &seen, progress: progress)
        default:
            return ChatImportScan()
        }
    }

    static func claudeCodeDetail(_ chat: ImportedChat) -> String? {
        var parts: [String] = []
        if let cwd = chat.cwd { parts.append((cwd as NSString).lastPathComponent) }
        if chat.subagents > 0 { parts.append("\(chat.subagents) subagent\(chat.subagents == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func scanOpenClaw(cache: inout ChatImportPreviewCache, seen: inout Set<String>, progress: (@Sendable (Int, Int) -> Void)?) -> ChatImportScan {
        var scan = ChatImportScan()
        var byID: [String: ChatImportCandidate] = [:]
        for install in OpenClawScanner.find(home: home, environment: environment) {
            for agentFolder in OpenClawChats.agentFolders(stateDir: install.stateDir) {
                let agent = agentFolder.lastPathComponent
                if let database = OpenClawChats.database(agentFolder: agentFolder) {
                    do {
                        for candidate in try OpenClawChats.previews(database: database, agent: agent) {
                            byID[candidate.sourceID] = candidate
                        }
                    } catch {
                        scan.problems.append((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    }
                }
                let files = OpenClawChats.transcriptFiles(agentFolder: agentFolder)
                let fromFiles = previewFiles(files, cache: &cache, seen: &seen, progress: progress) { file in
                    OpenClawChats.preview(file: file, agent: agent)
                }
                scan.problems += fromFiles.problems
                for candidate in fromFiles.candidates {
                    // The database is the live copy: a session in both is read from there.
                    if let held = byID[candidate.sourceID] {
                        if case .openClawDatabase = held.location { continue }
                        if held.updatedAt >= candidate.updatedAt { continue }
                    }
                    byID[candidate.sourceID] = candidate
                }
            }
        }
        scan.candidates = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        return scan
    }

    /// Each file's preview: from the cache when the file hasn't changed, else read (a few at a time).
    private func previewFiles(_ files: [URL], cache: inout ChatImportPreviewCache, seen: inout Set<String>,
                              progress: (@Sendable (Int, Int) -> Void)?,
                              read: @escaping @Sendable (URL) throws -> ChatImportCandidate?) -> ChatImportScan {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var found: [String: ChatImportCandidate?] = [:]
            var problems: [String] = []
            var done = 0
        }
        var scan = ChatImportScan()
        var toRead: [(URL, (size: Int, modified: Double))] = []
        for file in files {
            seen.insert(file.path)
            guard let stamp = ChatImportPreviewCache.stamp(file) else { continue }
            if let entry = cache.entries[file.path], entry.size == stamp.size, entry.modified == stamp.modified {
                if let candidate = entry.candidate { scan.candidates.append(candidate) }
            } else {
                toRead.append((file, stamp))
            }
        }
        let results = Results()
        let total = files.count
        let cached = total - toRead.count
        progress?(cached, total)
        let work = toRead
        let stripes = max(1, min(parallel, work.count))
        DispatchQueue.concurrentPerform(iterations: stripes) { stripe in
            var index = stripe
            while index < work.count {
                let (file, _) = work[index]
                var candidate: ChatImportCandidate?
                var problem: String?
                do {
                    candidate = try autoreleasepool { try read(file) }
                } catch {
                    problem = (error as? LocalizedError)?.errorDescription ?? "\(file.lastPathComponent): \(error)"
                }
                results.lock.lock()
                results.found[file.path] = .some(candidate)
                if let problem, results.problems.count < 5 { results.problems.append(problem) }
                results.done += 1
                let done = results.done
                results.lock.unlock()
                progress?(cached + done, total)
                index += stripes
            }
        }
        for (file, stamp) in toRead {
            guard let found = results.found[file.path] else { continue }
            cache.entries[file.path] = .init(size: stamp.size, modified: stamp.modified, candidate: found)
            if let candidate = found { scan.candidates.append(candidate) }
        }
        scan.problems = results.problems
        scan.candidates.sort { $0.updatedAt > $1.updatedAt }
        return scan
    }

    /// One local chat read whole for import.
    public func read(_ candidate: ChatImportCandidate) throws -> ImportedChat? {
        switch candidate.location {
        case .file(let file):
            switch candidate.source {
            case .claudeCode: return try ClaudeCodeChats.read(file)
            case .codex:
                let names = CodexChats.threadNames(codexHome: CodexChats.home(home: home, environment: environment))
                return try CodexChats.read(file, names: names)
            case .openClaw: return try OpenClawChats.read(file: file)
            default: return nil
            }
        case .openClawDatabase(let database, let sessionID):
            return try OpenClawChats.read(database: database, sessionID: sessionID)
        default:
            return nil
        }
    }
}

// MARK: - The words an imported chat opens with

public enum ChatImportText {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// The notice at the top of an imported chat (Vision for Windows writes the same words).
    public static func notice(_ chat: ImportedChat, importedAt: Date, folderOnThisMac: Bool) -> String {
        let messages = chat.messageCount
        let first = chat.rows.first?.at ?? chat.createdAt
        let last = chat.rows.last?.at ?? chat.updatedAt
        let span = day(first) == day(last) ? day(first) : "\(day(first)) – \(day(last))"
        var text = "Imported from \(chat.source.label) on \(day(importedAt)): \(messages) message\(messages == 1 ? "" : "s"), \(span)"
        if let cwd = chat.cwd, !cwd.isEmpty {
            text += folderOnThisMac ? ", in \(cwd)" : ", in \(cwd) (not on this computer, so it continues without a project)"
        }
        text += "."
        if chat.subagents > 0 {
            text += " It ran \(chat.subagents) subagent\(chat.subagents == 1 ? "" : "s") whose own transcripts stayed in \(chat.source.label)."
        }
        text += " Any model can carry on from here: earlier tool calls are shown as cards and reach the model as a written summary."
        return text
    }
}
