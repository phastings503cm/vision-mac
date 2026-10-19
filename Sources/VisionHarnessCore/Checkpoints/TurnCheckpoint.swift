import Foundation

/// Records what one turn changes (see `CheckpointStore`). The host sets `TurnCheckpoint.current` around a turn's
/// engine run; every file write of the agent's file tools (and its subagents', background ones included — they run in
/// child tasks) and every shell command it runs in a git repository is recorded into it.
public final class TurnCheckpoint: @unchecked Sendable {
    /// The turn being recorded, for the code running inside it.
    @TaskLocal public static var current: TurnCheckpoint?
    /// The tool running now (set by the engine around each call), so a record says what changed a file.
    @TaskLocal public static var activeTool: String?

    public let store: CheckpointStore
    private let lock = NSLock()
    private var _record: TurnCheckpointRecord
    /// Called (off the main thread) after each change is recorded, with the record as it stands.
    public var onChange: (@Sendable (TurnCheckpointRecord) -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    private var _onChange: (@Sendable (TurnCheckpointRecord) -> Void)?

    init(store: CheckpointStore, record: TurnCheckpointRecord) {
        self.store = store
        self._record = record
    }

    public var record: TurnCheckpointRecord { lock.withLock { _record } }
    public var chatID: String { lock.withLock { _record.chatID } }
    public var turnID: String { lock.withLock { _record.id } }
    var startedAt: Date { lock.withLock { _record.startedAt } }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// What is on disk at `path` now: (hash, nil) once kept, (nil, nil) when there is no file, (nil, why) when it
    /// can't be kept (too large, not a regular file, unreadable).
    func keep(path: String) -> (hash: String?, skipped: String?) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return (nil, nil) }
        if isDirectory.boolValue { return (nil, "it is a folder") }
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > CheckpointStore.maxFileBytes {
            return (nil, "too large to keep (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        }
        guard let data = fm.contents(atPath: path) else { return (nil, "it couldn't be read") }
        do { return (try store.put(data), nil) } catch { return (nil, "it couldn't be kept (\(error.localizedDescription))") }
    }

    /// Before a file is changed: keep what it holds now, the first time this turn touches it.
    public func willChange(_ url: URL, by tool: String? = nil) {
        let path = Self.key(url)
        if lock.withLock({ _record.files.contains { $0.path == path } }) { return }
        let before = keep(path: path)
        lock.withLock {
            guard !_record.files.contains(where: { $0.path == path }) else { return }
            _record.files.append(CheckpointFile(path: path, before: before.hash, after: before.hash,
                                                by: tool ?? Self.activeTool ?? "a tool", skipped: before.skipped))
        }
    }

    /// After a file was changed: keep what the turn left (`data` when the caller has it, else what is on disk now).
    public func didChange(_ url: URL, data: Data? = nil) {
        let path = Self.key(url)
        var after: (hash: String?, skipped: String?)
        if let data {
            after = data.count > CheckpointStore.maxFileBytes ? (nil, "too large to keep")
                : ((try? store.put(data)), nil)
        } else {
            after = keep(path: path)
        }
        if after.hash == nil, after.skipped == nil, data != nil { after.skipped = "it couldn't be kept" }
        let snapshot: TurnCheckpointRecord? = lock.withLock {
            guard let index = _record.files.firstIndex(where: { $0.path == path }) else { return nil }
            _record.files[index].after = after.hash
            if let skipped = after.skipped, _record.files[index].skipped == nil {
                // What the turn left can't be compared later, so the file can't be rewound safely.
                _record.files[index].skipped = skipped
            }
            _record.updatedAt = Date()
            return _record
        }
        if let snapshot { persist(snapshot) }
    }

    /// A change worked out afterwards (a shell command, from git): the content before and after, by hash.
    func recordObserved(path: String, before: String?, after: String?, skipped: String?, by tool: String) {
        let snapshot: TurnCheckpointRecord = lock.withLock {
            if let index = _record.files.firstIndex(where: { $0.path == path }) {
                // The turn touched it before: the first "before" stands, the newest "after" wins.
                _record.files[index].after = after
                if let skipped, _record.files[index].skipped == nil { _record.files[index].skipped = skipped }
            } else {
                _record.files.append(CheckpointFile(path: path, before: before, after: after, by: tool, skipped: skipped))
            }
            _record.updatedAt = Date()
            return _record
        }
        persist(snapshot)
    }

    /// Mark the turn rewound.
    func markRewound(at date: Date = Date()) {
        let snapshot: TurnCheckpointRecord = lock.withLock {
            _record.rewoundAt = date
            _record.updatedAt = date
            return _record
        }
        persist(snapshot)
    }

    private func persist(_ snapshot: TurnCheckpointRecord) {
        store.save(snapshot)
        onChange?(snapshot)
    }
}
