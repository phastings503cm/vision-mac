import Foundation

// MARK: - Rewinding a turn
//
// Every file the turn changed goes back to what it held before the turn (a file the turn created is removed). A file
// that changed again since the turn — by you, by a later turn — is a conflict: rewinding it would throw that change
// away, so the person decides (rewind it anyway, or leave it). A file whose content wasn't kept can't be rewound and
// is left alone. The rewind is itself recorded as a turn of its own, so it can be rewound in turn.

public struct RewindPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var path: String
        /// The content to put back (nil = remove the file: the turn created it).
        public var restore: String?
        /// Why it would throw away a later change ("changed since this turn"); nil = safe.
        public var conflict: String?
        /// Why it can't be rewound at all; nil = it can.
        public var skipped: String?
        /// It already holds what it held before the turn: nothing to do.
        public var alreadyThere: Bool
        /// What the file held on disk when the plan was made (nil = no file). A file that no longer holds it when the
        /// rewind runs changed while the person was deciding, and is left alone unless they chose Rewind All.
        public var seen: String?
        public var id: String { path }
    }

    public var turn: TurnCheckpointRecord
    public var items: [Item]

    /// The files a rewind would change without a question.
    public var safe: [Item] { items.filter { $0.conflict == nil && $0.skipped == nil && !$0.alreadyThere } }
    /// The files that changed since the turn.
    public var conflicts: [Item] { items.filter { $0.conflict != nil && $0.skipped == nil && !$0.alreadyThere } }
    /// The files that can't be rewound.
    public var skipped: [Item] { items.filter { $0.skipped != nil } }
    /// Nothing left to put back.
    public var isEmpty: Bool { safe.isEmpty && conflicts.isEmpty }
}

public struct RewindResult: Sendable, Equatable {
    /// Files put back to their earlier content.
    public var restored: [String] = []
    /// Files the turn created, removed.
    public var removed: [String] = []
    /// Files left as they are (changed since, and the person chose to keep them; or not rewindable).
    public var left: [String] = []
    /// Files that couldn't be written, and why.
    public var failed: [String: String] = [:]

    public var changedCount: Int { restored.count + removed.count }

    public init() {}
}

public enum Rewind {
    /// The hash of what is on disk at `path` now (nil = no file), or nil-with-error when it can't be read.
    static func current(_ path: String) -> (hash: String?, readable: Bool) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return (nil, true) }
        guard !isDirectory.boolValue, let data = fm.contents(atPath: path) else { return (nil, false) }
        return (CheckpointStore.hash(data), true)
    }

    /// What rewinding `turn` would do, file by file.
    public static func plan(_ turn: TurnCheckpointRecord, store: CheckpointStore) -> RewindPlan {
        var items: [RewindPlan.Item] = []
        for file in turn.changedFiles {
            let now = current(file.path)
            var item = RewindPlan.Item(path: file.path, restore: file.before, conflict: nil, skipped: file.skipped,
                                       alreadyThere: false, seen: now.hash)
            if item.skipped == nil, let before = file.before, store.data(before) == nil {
                item.skipped = "its earlier content is no longer kept"
            }
            if !now.readable {
                item.skipped = item.skipped ?? "it can't be read now"
            } else if now.hash == file.before {
                item.alreadyThere = true
            } else if now.hash != file.after {
                item.conflict = now.hash == nil ? "deleted since this turn" : "changed since this turn"
            }
            items.append(item)
        }
        return RewindPlan(turn: turn, items: items)
    }

    /// Why a file the plan called safe is left alone: it changed between the confirmation and the rewind.
    public static let changedWhileDeciding = "it changed after you confirmed — left as it is"

    /// Put the files back. Conflicting files are rewound only with `includeConflicts`. Every file is looked at again
    /// just before it is written: one that no longer holds what the plan saw (an editor saved it, another chat or a
    /// running turn wrote it while the confirmation was up) is left alone — unless it was a conflict the person chose
    /// to throw away with Rewind All. `recorder`, when given, records the rewind as a turn of its own.
    @discardableResult
    public static func apply(_ plan: RewindPlan, store: CheckpointStore, includeConflicts: Bool,
                             recorder: TurnCheckpoint? = nil) -> RewindResult {
        var result = RewindResult()
        let fm = FileManager.default
        for item in plan.items {
            if item.alreadyThere { continue }
            if item.skipped != nil || (item.conflict != nil && !includeConflicts) {
                result.left.append(item.path)
                continue
            }
            // Looked at again now, not when the confirmation opened (a conflict here is one the person chose to
            // throw away: it is written whatever the file holds).
            let now = current(item.path)
            if now.readable, now.hash == item.restore { continue }
            if !now.readable || (item.conflict == nil && now.hash != item.seen) {
                result.failed[item.path] = now.readable ? changedWhileDeciding : "it can't be read now"
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            recorder?.willChange(url, by: "rewind")
            do {
                if let hash = item.restore {
                    guard let data = store.data(hash) else {
                        result.failed[item.path] = "its earlier content is no longer kept"
                        continue
                    }
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    result.restored.append(item.path)
                } else {
                    if fm.fileExists(atPath: item.path) { try fm.removeItem(at: url) }
                    result.removed.append(item.path)
                }
                recorder?.didChange(url)
            } catch {
                result.failed[item.path] = error.localizedDescription
            }
        }
        // The turn is marked rewound (its record stays, for the diff and for the rewind's own undo).
        store.recorder(chatID: plan.turn.chatID, turnID: plan.turn.id, title: plan.turn.title).markRewound()
        return result
    }

    /// What the chat says after a rewind: "Rewound “Fix the build”: put back 2 files (a.swift, b.swift) and removed 1
    /// it created (c.swift). Left 1 that changed since (d.swift)."
    public static func summary(_ result: RewindResult, title: String, root: String?) -> String {
        func names(_ paths: [String]) -> String {
            let shown = paths.prefix(4).map { display($0, root: root) }
            return shown.joined(separator: ", ") + (paths.count > 4 ? " and \(paths.count - 4) more" : "")
        }
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
        var parts: [String] = []
        if !result.restored.isEmpty { parts.append("put back \(files(result.restored.count)) (\(names(result.restored)))") }
        if !result.removed.isEmpty {
            parts.append("removed \(result.removed.count == 1 ? "1 file" : "\(result.removed.count) files") it created (\(names(result.removed)))")
        }
        var text = "↺ Rewound “\(title)”: " + (parts.isEmpty ? "nothing needed changing" : parts.joined(separator: " and ")) + "."
        if !result.left.isEmpty { text += " Left \(files(result.left.count)) as they are (\(names(result.left)))." }
        if !result.failed.isEmpty {
            text += " Couldn't rewind " + result.failed.sorted { $0.key < $1.key }.prefix(3)
                .map { "\(display($0.key, root: root)) (\($0.value))" }.joined(separator: ", ") + "."
        }
        return text
    }

    /// What the model is told with the next message, so it doesn't trust what it remembers of those files.
    public static func modelNote(_ result: RewindResult, title: String, root: String?) -> String {
        let paths = (result.restored + result.removed).map { display($0, root: root) }
        return "[Automatic message: the user rewound the file changes of an earlier turn (“\(title)”). "
            + "These files are back to how they were before it: \(paths.joined(separator: ", ")). "
            + "Re-read them before relying on what you remember of their contents.]"
    }

    /// A path shown relative to the project when it is inside it.
    public static func display(_ path: String, root: String?) -> String {
        guard let root, !root.isEmpty, path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return path }
        return String(path.dropFirst(root.count).drop { $0 == "/" })
    }
}
