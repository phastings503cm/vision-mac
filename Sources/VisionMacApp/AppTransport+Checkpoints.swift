import Foundation
import VisionHarnessCore

// MARK: - Checkpoints and Rewind
//
// Every turn records what it changes (`TurnCheckpoint`, set around the engine run in `turn`): the file tools'
// writes, and in a git repository what each shell command changed. The turn's card shows "Files changed (N)" with
// diffs and "Rewind this turn"; `/rewind` lists the chat's recent turns that changed files.

extension AppTransport {
    /// The app's checkpoint store, under its data folder.
    var checkpointStore: CheckpointStore {
        CheckpointStore.at(skillLocations.appSupport.appendingPathComponent("checkpoints", isDirectory: true))
    }

    /// The recorder for the chat's current turn: its prompt's (every round of a goal adds to it), else one of its own.
    func turnCheckpoint(for vm: SessionVM) -> TurnCheckpoint {
        let turnID = vm.currentPromptID ?? vm.checkpoint?.id ?? ("auto-" + UUID().uuidString)
        let prompt = vm.promptHistory.last { $0.id == turnID }?.text
            ?? vm.entries.last { $0.message?.role == .user }?.message?.text ?? "Carrying on"
        let title = String((prompt.split(separator: "\n").first.map(String.init) ?? prompt).prefix(80))
        let recorder = checkpointStore.recorder(chatID: vm.id, turnID: turnID, title: title)
        recorder.onChange = { [weak self] record in
            Task { @MainActor [weak self] in self?.checkpointChanged(record) }
        }
        return recorder
    }

    /// A turn recorded a change: its chat's card follows (the newest turn wins).
    func checkpointChanged(_ record: TurnCheckpointRecord) {
        guard let vm = sessions.first(where: { $0.id == record.chatID }) else { return }
        if vm.checkpoint == nil || vm.checkpoint?.id == record.id || (vm.checkpoint?.startedAt ?? .distantPast) <= record.startedAt {
            vm.checkpoint = record
        }
    }

    /// When a chat loads: the card for its latest prompt's changes, as it was when that turn ended (not for an older
    /// turn — the card always belongs to the newest prompt).
    func restoreCheckpoint(_ vm: SessionVM) {
        guard vm.checkpoint == nil, let last = vm.promptHistory.last,
              let record = checkpointStore.record(chatID: vm.id, turnID: last.id), !record.changedFiles.isEmpty else { return }
        vm.checkpoint = record
    }

    /// What one prompt's turn changed (nil when it changed no file, or its record was pruned).
    public func checkpoint(chatID: String, turnID: String) -> TurnCheckpointRecord? {
        checkpointStore.record(chatID: chatID, turnID: turnID).flatMap { $0.changedFiles.isEmpty ? nil : $0 }
    }

    /// The chat's recent turns that changed files, newest first.
    public func checkpoints(for vm: SessionVM, limit: Int = 30) -> [TurnCheckpointRecord] {
        Array(checkpointStore.records(chatID: vm.id).prefix(limit))
    }

    /// Why a turn can't be rewound right now — it is still running and writing (rewinding under it would put files
    /// back while the agent keeps working on them) — else nil.
    public func rewindBlocked(turnID: String, in vm: SessionVM) -> String? {
        guard vm.running, turnID == vm.currentPromptID else { return nil }
        return "Wait for the turn to finish (or stop it) to rewind it."
    }

    /// What rewinding a turn would do now.
    public func rewindPlan(_ record: TurnCheckpointRecord) -> RewindPlan {
        Rewind.plan(record, store: checkpointStore)
    }

    /// Rewind a turn: put its files back (and, with `includeConflicts`, also the ones changed since). The chat says
    /// what happened, and the model hears it with the next message.
    @discardableResult
    public func rewind(_ plan: RewindPlan, includeConflicts: Bool, in vm: SessionVM) -> RewindResult {
        if let why = rewindBlocked(turnID: plan.turn.id, in: vm) {
            vm.note(why, role: .error)
            return RewindResult()
        }
        let recorder = checkpointStore.recorder(chatID: vm.id, turnID: "rewind-" + UUID().uuidString,
                                                title: "Rewind of “\(plan.turn.title)”")
        let result = Rewind.apply(plan, store: checkpointStore, includeConflicts: includeConflicts, recorder: recorder)
        let root = vm.workspaceURL?.path
        let text = Rewind.summary(result, title: plan.turn.title, root: root)
        vm.note(text, role: result.failed.isEmpty ? .notice : .error)
        log.recordItem(vm.id, kind: result.failed.isEmpty ? "notice" : "error", text: text, toolName: nil,
                       argSummary: nil, output: nil, isError: !result.failed.isEmpty)
        if result.changedCount > 0 {
            vm.pendingModelNotes.append(Rewind.modelNote(result, title: plan.turn.title, root: root))
            // The editor reloads what went back; the turn's card shows it rewound.
            let changes = result.restored.map { FileChange(URL(fileURLWithPath: $0), .modified) }
                + result.removed.map { FileChange(URL(fileURLWithPath: $0), .deleted) }
            onFilesChanged?(changes)
        }
        if let updated = checkpointStore.record(chatID: vm.id, turnID: plan.turn.id), vm.checkpoint?.id == updated.id {
            vm.checkpoint = updated
        }
        return result
    }

    /// The diff of one file a turn changed: before the turn → what the turn left.
    public func diff(_ file: CheckpointFile) -> FileDiff {
        Self.diff(file, store: checkpointStore)
    }

    /// The same, off the main actor (the views compute it in the background).
    public nonisolated static func diff(_ file: CheckpointFile, store: CheckpointStore) -> FileDiff {
        if let skipped = file.skipped, file.before == nil || file.after == nil {
            return FileDiff(hunks: [], added: 0, removed: 0, note: "No diff: \(skipped).")
        }
        let old = file.before.flatMap(store.data), new = file.after.flatMap(store.data)
        if file.before != nil, old == nil { return FileDiff(hunks: [], added: 0, removed: 0, note: "The earlier content is no longer kept.") }
        if file.after != nil, new == nil { return FileDiff(hunks: [], added: 0, removed: 0, note: "The turn's content is no longer kept.") }
        return LineDiff.diff(old: old, new: new)
    }

    /// `/rewind`: the recent turns that changed files (and the Rewind sheet); `/rewind n` asks to rewind turn n.
    func rewindCommand(_ arg: String?, vm: SessionVM) {
        let records = checkpoints(for: vm)
        guard !records.isEmpty else {
            vm.note("No turn in this chat has changed files yet — nothing to rewind. (Changes made by shell commands are "
                    + "tracked in git repositories only.)")
            return
        }
        let root = vm.workspaceURL?.path
        if let arg, let n = Int(arg.trimmingCharacters(in: .whitespaces)) {
            guard (1...records.count).contains(n) else {
                vm.note("There is no turn \(n) — `/rewind` lists \(records.count).", role: .error)
                return
            }
            if let why = rewindBlocked(turnID: records[n - 1].id, in: vm) {
                vm.note(why, role: .error)
                return
            }
            rewindRequest = RewindRequest(chatID: vm.id, turnID: records[n - 1].id)
            return
        }
        let lines = records.prefix(10).enumerated().map { index, record in
            let files = record.changedFiles
            let names = files.prefix(3).map { URL(fileURLWithPath: Rewind.display($0.path, root: root)).lastPathComponent }
                .joined(separator: ", ") + (files.count > 3 ? " +\(files.count - 3)" : "")
            let when = record.startedAt.formatted(date: .omitted, time: .shortened)
            return "\(index + 1). \(when) “\(record.title)” — \(files.count) file\(files.count == 1 ? "" : "s") (\(names))"
                + (record.rewoundAt != nil ? " · rewound" : "")
        }
        vm.note("Recent turns that changed files (newest first):\n" + lines.joined(separator: "\n")
                + "\n\n`/rewind <n>` undoes turn n's file changes (you confirm first).")
        rewindRequest = RewindRequest(chatID: vm.id, turnID: nil)
    }
}

/// The Rewind sheet's request: a chat, and the turn to confirm (nil = the list).
public struct RewindRequest: Identifiable, Hashable, Sendable {
    public var chatID: String
    public var turnID: String?
    public var id: String { chatID + "/" + (turnID ?? "") }
}
