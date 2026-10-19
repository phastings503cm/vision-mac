import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - Project status (code mode, beside the chat)
//
// What code mode shows next to the chat when the editor and terminal are hidden: the project and its git state, the
// selected chat's run (phase, runtime against the estimate), its plan and tasks, the agents working and on which
// models, and the files changed — any of which opens in the editor, in the middle, on a click.

struct ProjectStatusPanel: View {
    @Environment(AppModel.self) private var model
    @State private var git: GitStatusSummary?
    @State private var gitError: String?

    var body: some View {
        let session = model.selectedSession
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session {
                        RunStatusSection(session: session)
                        if !session.todos.isEmpty || model.transport.currentWork(for: session) != nil {
                            RunSection(title: "Plan") {
                                if session.todos.isEmpty {
                                    Text("No steps yet — the plan appears as the agent writes it.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    PlanSteps(session: session, steps: session.todos)
                                }
                            }
                        }
                        TasksSummarySection(session: session)
                        AgentsSection(session: session)
                    }
                    GitSection(git: git, error: gitError, root: model.project)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
        .task(id: model.project) { await refreshLoop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.project?.lastPathComponent ?? "No project").font(.headline).lineLimit(1)
                Text(git?.summary ?? (model.project == nil ? "Open a folder to work on it" : "Reading git status…"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                model.code.toggleTree()
            } label: {
                Image(systemName: "sidebar.squares.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Browse the project's files (⌘B)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// git status now, then every few seconds while this panel is up (and the moment the agent changes files).
    private func refreshLoop() async {
        while !Task.isCancelled {
            if let root = model.project {
                let result = await GitStatusReader.read(root)
                git = result.status
                gitError = result.error
            } else {
                git = nil
                gitError = nil
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }
}

/// The selected chat's run: the phase it is in, how long against the estimate, and its last outcome.
private struct RunStatusSection: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        RunSection(title: "Run") {
            RunCard(outline: session.running ? Theme.successTint.opacity(0.45) : Theme.hairline) {
                VStack(alignment: .leading, spacing: 6) {
                    if let work = model.transport.currentWork(for: session) {
                        HStack(spacing: 6) {
                            PhaseStrip(phase: work.phase)
                            Spacer()
                        }
                        Text(work.title).font(.callout.weight(.semibold)).lineLimit(3)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(statusLine(work, at: context.date))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else if let last = session.promptHistory.last(where: { !$0.outcome.isOpen }) {
                        HStack(spacing: 6) {
                            OutcomeChip(record: last)
                            Spacer()
                            Button("Results") { model.resultsRecord = last }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        }
                        Text(last.firstLine).font(.callout).lineLimit(2)
                        Text(PromptTimeline.timing(last)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Idle — ask the agent something in the chat.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let use = model.transport.turnRoute[session.id] {
                        Label("\(use.model) on \(use.route)", systemImage: "cpu")
                            .font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }
            }
        }
    }

    private func statusLine(_ work: CurrentWork, at now: Date) -> String {
        var parts = [work.kind]
        if let round = work.round { parts.append("round \(round)") }
        parts.append("running \(now.timeIntervalSince(work.startedAt).formattedDuration)")
        if let eta = work.phase?.etaSeconds { parts.append("est. \(TurnPhaseState.phrase(eta))") }
        return parts.joined(separator: " · ")
    }
}

/// Planning › Execution › Validation › Results, the live one marked.
struct PhaseStrip: View {
    let phase: TurnPhaseState?

    var body: some View {
        HStack(spacing: 4) {
            ForEach([TurnPhaseState.Phase.planning, .execution, .validation, .results], id: \.self) { item in
                let live = phase?.phase == item && !(phase?.isOver ?? false)
                let done = phase.map { order($0.phase) > order(item) || ($0.phase == .results && item == .results) } ?? false
                Text(item.label)
                    .font(.system(size: 9.5, weight: live ? .bold : .regular))
                    .foregroundStyle(live ? Theme.successTint : done ? Theme.successTint.opacity(0.7) : Color.secondary)
                if item != .results {
                    Image(systemName: "chevron.right").font(.system(size: 6, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func order(_ phase: TurnPhaseState.Phase) -> Int {
        switch phase {
        case .planning: 0
        case .execution: 1
        case .validation: 2
        case .results: 3
        }
    }
}

/// The chat's tasks in short: what is up next.
private struct TasksSummarySection: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let queued = model.transport.queue.chatTasks(session.id).filter { $0.status == .queued }
        RunSection(title: "Up next", count: queued.count, accessory: {
            Button("Tasks") {
                model.runPanelTab = .tasks
                model.config.planPanelOpen = true
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
            .help("Open the chat's tasks (⇧⌘P)")
        }) {
            if queued.isEmpty {
                Text("Nothing queued — type the next prompt while it works and press ↩ to add it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let paused = model.transport.chatTasksPaused[session.id] {
                    Label(paused, systemImage: "pause.circle.fill").font(.caption).foregroundStyle(Theme.noticeTint)
                }
                ForEach(Array(queued.prefix(5).enumerated()), id: \.element.id) { index, task in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 2)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 14)
                        Text(task.title).font(.callout).lineLimit(2)
                    }
                }
                if queued.count > 5 {
                    Text("and \(queued.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Subagents working for the chat, with the model and server each runs on.
private struct AgentsSection: View {
    let session: SessionVM

    var body: some View {
        let running = session.agentRuns.filter(\.isRunning)
        if !running.isEmpty {
            RunSection(title: "Agents", count: running.count) {
                ForEach(running) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        AgentChip(run: run)
                        Text("“\(run.description)” — \(run.activity)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }
}

/// git: the branch, ahead/behind, and the changed files — each opens in the editor.
private struct GitSection: View {
    @Environment(AppModel.self) private var model
    let git: GitStatusSummary?
    let error: String?
    let root: URL?

    var body: some View {
        RunSection(title: "Changes", count: git?.files.count) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let git {
                if git.files.isEmpty {
                    Text("Working tree clean on \(git.branch ?? "a detached HEAD").").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(git.files.prefix(40)) { file in
                        Button {
                            if let root, file.label != "deleted" { model.code.reveal(root.appendingPathComponent(file.path)) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(file.letter)
                                    .font(Theme.mono(10).weight(.bold))
                                    .foregroundStyle(tint(file))
                                    .frame(width: 12)
                                Text(file.path).font(Theme.mono(11)).lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(file.path) — \(file.label)\(file.staged ? ", staged" : ""). Click to open it in the editor.")
                    }
                    if git.files.count > 40 {
                        Text("and \(git.files.count - 40) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if root != nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func tint(_ file: GitStatusSummary.File) -> Color {
        switch file.label {
        case "added", "untracked": Theme.successTint
        case "deleted", "conflicted": Theme.errorTint
        default: Theme.noticeTint
        }
    }
}

/// Reads `git status` off the main thread. Not a repository, or no git: says so.
@MainActor
enum GitStatusReader {
    static func read(_ root: URL) async -> (status: GitStatusSummary?, error: String?) {
        // Not a repository: nothing to run. (A `.git` file is a worktree.)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return (nil, "Not a git repository.")
        }
        guard await developerToolsInstalled() else {
            return (nil, "git needs the Command Line Tools (xcode-select --install).")
        }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "status", "--porcelain=v1", "--branch"]
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_OPTIONAL_LOCKS"] = "0"   // never take the index lock from a status poll
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                return (nil, "git isn't available on this Mac.")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return (nil, "Not a git repository.") }
            return (GitStatusSummary.parse(porcelain: String(decoding: data, as: UTF8.self)), nil)
        }.value
    }

    /// `/usr/bin/git` is a shim that pops the "install developer tools" dialog when they are missing — never from a
    /// background poll. `xcode-select -p` answers without asking anything.
    private static func developerToolsInstalled() async -> Bool {
        if let known = Cache.toolsInstalled { return known }
        let installed = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["-p"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return false }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !path.isEmpty && FileManager.default.fileExists(atPath: path)
        }.value
        Cache.toolsInstalled = installed
        return installed
    }

    @MainActor private enum Cache {
        static var toolsInstalled: Bool?
    }
}
