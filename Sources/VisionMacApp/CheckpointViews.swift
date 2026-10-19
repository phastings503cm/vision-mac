import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - "Files changed (N)" under a turn, with diffs and Rewind

/// What the turn changed: each file with its diff (on demand), and "Rewind this turn…".
struct TurnChangesCard: View {
    @Environment(AppModel.self) private var model
    let record: TurnCheckpointRecord
    let session: SessionVM
    @State private var expanded = false

    var body: some View {
        let files = record.changedFiles
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Files changed (\(files.count))")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("What this turn changed — click a file for its diff")
                if record.rewoundAt != nil {
                    Text("Rewound").font(Theme.metaFont).foregroundStyle(Theme.noticeTint)
                }
                Spacer()
                let blocked = model.transport.rewindBlocked(turnID: record.id, in: session)
                Button("Rewind this turn…") {
                    model.transport.rewindRequest = RewindRequest(chatID: session.id, turnID: record.id)
                }
                .controlSize(.small)
                .disabled(blocked != nil)
                .help(blocked ?? "Put these files back to how they were before this turn (you confirm first)")
            }
            if expanded {
                ForEach(files) { file in
                    ChangedFileRow(file: file, root: session.workspaceURL?.path)
                }
            } else {
                Text(files.prefix(4).map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")
                     + (files.count > 4 ? " and \(files.count - 4) more" : ""))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}

/// One changed file: its name and +/- counts; expanded, its diff.
struct ChangedFileRow: View {
    @Environment(AppModel.self) private var model
    let file: CheckpointFile
    let root: String?
    @State private var open = false
    @State private var diff: FileDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                open.toggle()
                if open, diff == nil { load() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(file.change.tint).frame(width: 6, height: 6)
                    Text(Rewind.display(file.path, root: root))
                        .font(Theme.mono(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.change.label).font(Theme.metaFont).foregroundStyle(.secondary)
                    if let diff, diff.note == nil {
                        Text("+\(diff.added)").font(Theme.mono(10)).foregroundStyle(Theme.successTint)
                        Text("−\(diff.removed)").font(Theme.mono(10)).foregroundStyle(Theme.errorTint)
                    }
                    if let skipped = file.skipped {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.noticeTint)
                            .help("Can't be rewound: \(skipped)")
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if file.after != nil {
                    Button("Open in Editor") {
                        model.mode = .code
                        model.code.reveal(URL(fileURLWithPath: file.path))
                    }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            if open {
                if let diff {
                    DiffView(diff: diff)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// Only when the row is opened, and off the main thread: a large rewritten file can take a while to compare.
    private func load() {
        let store = model.transport.checkpointStore
        let file = self.file
        Task {
            diff = await Task.detached(priority: .userInitiated) { AppTransport.diff(file, store: store) }.value
        }
    }
}

/// A unified diff: hunk headers, then the lines — added in green, removed in red.
struct DiffView: View {
    let diff: FileDiff
    @State private var showAll = false
    static let previewLines = 300

    var body: some View {
        if let note = diff.note {
            Text(note).font(Theme.metaFont).foregroundStyle(.secondary)
        } else if diff.hunks.isEmpty {
            Text("No line changes.").font(Theme.metaFont).foregroundStyle(.secondary)
        } else {
            let total = diff.hunks.reduce(0) { $0 + $1.lines.count + 1 }
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .header(let text):
                            Text(text)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                        case .line(let line):
                            HStack(spacing: 0) {
                                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                    .frame(width: 14, alignment: .leading)
                                Text(line.text.isEmpty ? " " : line.text)
                            }
                            .font(Theme.mono(10.5))
                            .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .added ? Theme.successTint.opacity(0.12)
                                        : line.kind == .removed ? Theme.errorTint.opacity(0.12) : Color.clear)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .padding(6)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            if total > Self.previewLines, !showAll {
                Button("Show all \(total.formatted()) lines") { showAll = true }
                    .buttonStyle(.plain).font(Theme.metaFont).foregroundStyle(.tint)
            }
        }
    }

    private enum Row { case header(String), line(DiffLine) }

    private var rows: [Row] {
        var out: [Row] = []
        for hunk in diff.hunks {
            out.append(.header(hunk.header))
            out.append(contentsOf: hunk.lines.map(Row.line))
            if !showAll, out.count >= Self.previewLines { break }
        }
        return showAll ? out : Array(out.prefix(Self.previewLines))
    }
}

// MARK: - The Rewind sheet (/rewind, "Rewind this turn…")

struct RewindSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RewindRequest
    @State private var records: [TurnCheckpointRecord] = []
    @State private var selected: String?
    @State private var plan: RewindPlan?
    @State private var nothingToDo = false

    private var session: SessionVM? { model.transport.sessions.first { $0.id == request.chatID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rewind").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Each turn below changed files. Rewinding one puts its files back to how they were before it — a file it "
                 + "created is removed. You're asked first when a file changed again since. A rewind can itself be rewound.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if records.isEmpty {
                Text("No turn in this chat has changed files yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(selection: $selected) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1).").font(Theme.mono(11)).foregroundStyle(.secondary)
                                Text(record.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if record.rewoundAt != nil {
                                    Text("rewound").font(Theme.metaFont).foregroundStyle(Theme.noticeTint)
                                }
                                Spacer()
                                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(Theme.metaFont).foregroundStyle(.secondary)
                                let blocked = session.flatMap { model.transport.rewindBlocked(turnID: record.id, in: $0) }
                                Button("Rewind…") { ask(record) }
                                    .controlSize(.small)
                                    .disabled(blocked != nil)
                                    .help(blocked ?? "Put this turn's files back to how they were before it (you confirm first)")
                            }
                            if selected == record.id {
                                ForEach(record.changedFiles) { file in
                                    ChangedFileRow(file: file, root: session?.workspaceURL?.path)
                                }
                            } else {
                                Text("\(record.changedFiles.count) file\(record.changedFiles.count == 1 ? "" : "s"): "
                                     + record.changedFiles.prefix(4).map { URL(fileURLWithPath: $0.path).lastPathComponent }
                                        .joined(separator: ", "))
                                    .font(Theme.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(record.id)
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .padding(18)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420)
        .onAppear(perform: reload)
        .alert(alertTitle, isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }), presenting: plan) { plan in
            if plan.conflicts.isEmpty {
                Button("Rewind") { run(plan, includeConflicts: false) }
            } else {
                Button("Rewind All", role: .destructive) { run(plan, includeConflicts: true) }
                if !plan.safe.isEmpty {
                    Button("Rewind Only the Others") { run(plan, includeConflicts: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(Self.confirmation(plan, root: session?.workspaceURL?.path))
        }
        .alert("Nothing to rewind", isPresented: $nothingToDo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Every file this turn changed already holds what it held before it (or can't be rewound).")
        }
    }

    private var alertTitle: String {
        plan.map { "Rewind “\($0.turn.title)”?" } ?? "Rewind?"
    }

    private func reload() {
        guard let session else { return }
        records = model.transport.checkpoints(for: session)
        if let turnID = request.turnID {
            selected = turnID
            if let record = records.first(where: { $0.id == turnID })
                ?? session.checkpoint.flatMap({ $0.id == turnID ? $0 : nil }) {
                ask(record)
            }
        }
    }

    private func ask(_ record: TurnCheckpointRecord) {
        // The turn still running can't be rewound under the agent (the card and the list disable it too).
        if let session, model.transport.rewindBlocked(turnID: record.id, in: session) != nil { return }
        let plan = model.transport.rewindPlan(record)
        if plan.isEmpty { nothingToDo = true } else { self.plan = plan }
    }

    private func run(_ plan: RewindPlan, includeConflicts: Bool) {
        guard let session else { return }
        model.transport.rewind(plan, includeConflicts: includeConflicts, in: session)
        reload()
        if request.turnID != nil { dismiss() }
    }

    /// The confirmation's words: what goes back, what was created and goes, what changed since.
    static func confirmation(_ plan: RewindPlan, root: String?) -> String {
        func names(_ items: [RewindPlan.Item]) -> String {
            items.prefix(5).map { Rewind.display($0.path, root: root) }.joined(separator: ", ")
                + (items.count > 5 ? " and \(items.count - 5) more" : "")
        }
        var parts: [String] = []
        let restore = plan.safe.filter { $0.restore != nil }, remove = plan.safe.filter { $0.restore == nil }
        if !restore.isEmpty { parts.append("\(restore.count) file\(restore.count == 1 ? "" : "s") go back to how they were before this turn (\(names(restore))).") }
        if !remove.isEmpty { parts.append("\(remove.count) file\(remove.count == 1 ? "" : "s") it created \(remove.count == 1 ? "is" : "are") removed (\(names(remove))).") }
        if !plan.conflicts.isEmpty {
            parts.append("\(plan.conflicts.count) file\(plan.conflicts.count == 1 ? "" : "s") changed since this turn (\(names(plan.conflicts))): rewinding \(plan.conflicts.count == 1 ? "it" : "them") throws those later changes away.")
        }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) can't be rewound (\(names(plan.skipped))).") }
        return parts.joined(separator: "\n\n")
    }
}
