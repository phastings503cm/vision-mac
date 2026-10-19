import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - The right column: Tasks and Prompts
//
// Tasks (⇧⌘P): what the chat is doing now — the running prompt's or /goal's plan, always the first task, with the
// steps and which subagent (name and model) works each — then the prompts queued after it ("Add to tasks"), which
// start by themselves as the chat comes free. Prompts (⇧⌘H): every prompt the chat has sent, with how it ended.

struct RunPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.selectedSession
        VStack(spacing: 0) {
            RunPanelHeader(session: session)
            Divider()
            switch model.runPanelTab {
            case .tasks:
                if let session {
                    TasksTab(session: session)
                } else {
                    RunPanelEmpty(text: "Open or start a chat, and its tasks show up here.")
                }
            case .prompts:
                if let session {
                    PromptsTab(session: session)
                } else {
                    RunPanelEmpty(text: "Open a chat to see the prompts it has sent — or open All Prompts (⌥⇧⌘H).")
                }
            }
        }
        .background(.background)
    }
}

private struct RunPanelHeader: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { model.runPanelTab }, set: { model.runPanelTab = $0 })) {
                    ForEach(RunPanelTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Tasks (⇧⌘P) — what this chat is doing and what is queued. Prompts (⇧⌘H) — what it has been asked.")
                Spacer()
                Button {
                    model.config.planPanelOpen = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide this column")
            }
            Text(session?.title ?? "No chat open")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RunPanelEmpty: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - Pieces shared by the tabs

struct RunSection<Content: View, Accessory: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surfaceStrong, in: Capsule())
                }
                Spacer()
                accessory()
            }
            content()
        }
    }
}

extension RunSection where Accessory == EmptyView {
    init(title: String, count: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self.accessory = { EmptyView() }
        self.content = content
    }
}

struct RunCard<Content: View>: View {
    var outline: Color = Theme.hairline
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(outline))
    }
}

/// A prompt's outcome, as a chip: the same words everywhere ("Completed with results", "Failed", "Queued"…).
struct OutcomeChip: View {
    let record: PromptRecord

    var body: some View {
        Label(record.headline, systemImage: record.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Self.tint(record.outcome))
            .lineLimit(1)
    }

    static func tint(_ outcome: PromptRecord.Outcome) -> Color {
        switch outcome {
        case .completed: Theme.successTint
        case .issues, .needsYou: Theme.noticeTint
        case .failed: Theme.errorTint
        case .running: Color.accentColor
        case .queued, .stopped, .unknown: .secondary
        }
    }
}

/// "explore · Qwen3-Coder on DGX Spark" — a subagent working a plan step.
struct AgentChip: View {
    let run: AgentRun

    var body: some View {
        HStack(spacing: 4) {
            if run.isRunning {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            } else {
                Image(systemName: run.status == .done ? "checkmark" : "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(run.status == .done ? Theme.successTint : Theme.errorTint)
            }
            Text(run.agentType)
                .font(.system(size: 9.5, weight: .semibold))
            if let placement = run.placementLabel {
                Text(placement)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Theme.surfaceStrong, in: Capsule())
        .help("\(run.description) — \(run.activity)" + (run.placement.map { "\n\($0)" } ?? ""))
    }
}

// MARK: - Tasks

struct TasksTab: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NowSection(session: session)
                    UpNextSection(session: session)
                    AddTaskField(session: session)
                    DoneTasksSection(session: session)
                    UnattendedQueueLink()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Toggle("Show when the agent makes a plan", isOn: Binding(
                get: { model.config.planPanelAutoOpen },
                set: { model.config.planPanelAutoOpen = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The first task: what the chat is doing right now.
struct NowSection: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        RunSection(title: "Now") {
            if let work = model.transport.currentWork(for: session) {
                NowCard(session: session, work: work)
            } else {
                IdleCard(session: session)
            }
            if let plan = session.proposedPlan {
                RunCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Proposed plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        MarkdownView(source: plan)
                        Text("Proposed in plan mode, which changes nothing. To carry it out, start a new chat with another permission preset.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct NowCard: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let work: CurrentWork

    var body: some View {
        RunCard(outline: Theme.successTint.opacity(0.45)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("1")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .frame(width: 16, height: 16)
                        .background(Theme.successTint.opacity(0.25), in: Circle())
                    Text(work.kind)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surfaceStrong, in: Capsule())
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(statusLine(at: context.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        model.transport.stopSession(session.id)
                    } label: {
                        Image(systemName: session.stopping ? "hourglass" : "stop.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.errorTint)
                    .disabled(session.stopping)
                    .help("Stop it (⌘.) — what is queued after it waits until you resume")
                }
                Text(work.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !work.steps.isEmpty {
                    let done = work.steps.filter { $0.status == .completed }.count
                    ProgressView(value: Double(done), total: Double(work.steps.count))
                        .progressViewStyle(.linear)
                    PlanSteps(session: session, steps: work.steps)
                } else if let phase = work.phase, !phase.draft.isEmpty, phase.phase == .planning {
                    Text(phase.draft)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                UnassignedAgents(session: session, steps: work.steps)
            }
        }
    }

    private func statusLine(at now: Date) -> String {
        var parts: [String] = []
        if let phase = work.phase, !phase.isOver { parts.append(phase.phase.label) }
        if let round = work.round { parts.append("round \(round)") }
        parts.append(now.timeIntervalSince(work.startedAt).formattedDuration)
        if let eta = work.phase?.etaSeconds { parts.append("est. \(TurnPhaseState.phrase(eta))") }
        return parts.joined(separator: " · ")
    }
}

/// The plan's steps, each with the subagents working it (name and model).
struct PlanSteps: View {
    let session: SessionVM
    let steps: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if item.status == .inProgress && session.running {
                            ProgressView().controlSize(.mini)
                                .frame(width: 14)
                        } else {
                            Image(systemName: item.status.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(item.status.tint)
                                .frame(width: 14)
                        }
                        Text(item.content)
                            .font(.callout.weight(item.status == .inProgress ? .semibold : .regular))
                            .strikethrough(item.status == .completed, color: .secondary)
                            .foregroundStyle(item.status == .completed ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let agents = session.agentRuns.filter { $0.assignment == item.content }
                    if !agents.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(agents) { AgentChip(run: $0) }
                        }
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }
}

/// Subagents working that no step names.
private struct UnassignedAgents: View {
    let session: SessionVM
    let steps: [TodoItem]

    var body: some View {
        let names = Set(steps.map(\.content))
        let others = session.agentRuns.filter { $0.isRunning && !names.contains($0.assignment ?? "\u{0}") }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Subagents").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(others) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            AgentChip(run: run)
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(run.elapsed(at: context.date).formattedDuration)
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text("“\(run.description)” — \(run.activity)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct IdleCard: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        RunCard {
            VStack(alignment: .leading, spacing: 6) {
                if let unfinished = session.lastGoal {
                    Label("Goal not finished", systemImage: "pause.circle")
                        .font(.callout.weight(.semibold))
                    Text(unfinished).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    Button("Pick the goal back up") { model.send("/goal", in: session) }
                        .controlSize(.small)
                } else if let last = session.promptHistory.last(where: { !$0.outcome.isOpen }) {
                    Text("Nothing running.").font(.callout.weight(.semibold))
                    HStack(spacing: 6) {
                        OutcomeChip(record: last)
                        Text(last.finishedAt.map { $0.relativeLabel } ?? "")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(last.firstLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("Nothing running.").font(.callout.weight(.semibold))
                    Text("When the agent works on a prompt or a /goal, its plan shows here as the first task, with each step and the subagents working it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The plan the last work left, so its steps (and who worked them) stay in view.
                if !session.todos.isEmpty {
                    let done = session.todos.filter { $0.status == .completed }.count
                    Divider().padding(.vertical, 2)
                    Text("Last plan — \(done) of \(session.todos.count) done")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    PlanSteps(session: session, steps: session.todos)
                }
            }
        }
    }
}

/// The prompts queued after the current work.
struct UpNextSection: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let transport = model.transport
        let queued = transport.queue.chatTasks(session.id).filter { $0.status == .queued }
        let paused = transport.chatTasksPaused[session.id]
        RunSection(title: "Up next", count: queued.count, accessory: {
            if !queued.isEmpty {
                if paused != nil {
                    Button("Resume") { transport.resumeChatTasks(session.id) }
                        .controlSize(.small)
                        .help("Carry on: the next task starts as soon as the chat is free")
                } else {
                    Button("Pause") { transport.pauseChatTasks(session.id) }
                        .controlSize(.small)
                        .help("Let the current work finish and start nothing new until you resume")
                }
            }
        }) {
            if let paused, !queued.isEmpty {
                Label(paused, systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.noticeTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if queued.isEmpty {
                Text("Nothing queued. While the agent works, type the next prompt and press ↩ (or ⌘↩ any time): it is added here and starts by itself when the work before it finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(queued.enumerated()), id: \.element.id) { index, task in
                        ChatTaskRow(task: task, position: index + 2, isFirst: index == 0, isLast: index == queued.count - 1)
                    }
                }
            }
        }
    }
}

private struct ChatTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: QueueTask
    let position: Int
    let isFirst: Bool
    let isLast: Bool
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false

    var body: some View {
        let transport = model.transport
        HStack(alignment: .top, spacing: 8) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold)).monospacedDigit()
                .frame(width: 16, height: 16)
                .background(Theme.surfaceStrong, in: Circle())
            Text(task.promptText)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.promptText)
            HStack(spacing: 2) {
                Button { transport.moveChatTask(task.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst).help("Move up")
                Button { transport.moveChatTask(task.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast).help("Move down")
                Button { transport.removeChatTask(task.id) } label: { Image(systemName: "xmark") }
                    .help("Remove from the list")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .draggable(task.id) { Text(task.title).lineLimit(1) }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != task.id else { return false }
            transport.moveChatTask(dragged, onto: task.id)
            return true
        }
        .contextMenu {
            Button("Run Next") { transport.queueMoveChatTaskToFront(task.id) }
            Button("Edit…") { text = task.promptText; editing = true }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.promptText, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) { transport.removeChatTask(task.id) }
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit task").font(.headline)
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minWidth: 420, minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        transport.editChatTask(task.id, text: text)
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
    }
}

/// A quick way to queue a task from the panel itself.
private struct AddTaskField: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var text = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Add a task for this chat…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(add)
            Button(action: add) { Image(systemName: "plus") }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add to this chat's tasks — it starts when the work before it finishes")
        }
    }

    private func add() {
        guard model.transport.addChatTask(text, sessionID: session.id) != nil else { return }
        text = ""
    }
}

/// The chat's finished tasks.
private struct DoneTasksSection: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let transport = model.transport
        let done = transport.queue.chatTasks(session.id).filter { $0.status != .queued && $0.status != .running }
        if !done.isEmpty {
            RunSection(title: "Done", count: done.count, accessory: {
                Button("Clear") { transport.clearFinishedChatTasks(session.id) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
            }) {
                VStack(spacing: 4) {
                    ForEach(done.prefix(10)) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: Self.icon(task.status))
                                .font(.system(size: 10))
                                .foregroundStyle(Self.tint(task.status))
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title).font(.callout).lineLimit(2)
                                Text(Self.line(task)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if task.status != .complete {
                                Button("Run again") { transport.retryChatTask(task.id) }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
    }

    static func icon(_ status: QueueTaskStatus) -> String {
        switch status {
        case .complete: "checkmark.circle.fill"
        case .failed: "xmark.circle"
        case .blocked: "pause.circle"
        case .skipped: "stop.circle"
        default: "circle"
        }
    }

    static func tint(_ status: QueueTaskStatus) -> Color {
        switch status {
        case .complete: Theme.successTint
        case .failed: Theme.errorTint
        case .blocked: Theme.noticeTint
        default: .secondary
        }
    }

    static func line(_ task: QueueTask) -> String {
        let word: String
        switch task.status {
        case .complete: word = "Completed"
        case .failed: word = "Failed"
        case .blocked: word = "Needs you"
        case .skipped: word = "Stopped"
        default: word = task.status.label
        }
        let duration = task.duration.map { " · \($0.formattedDuration)" } ?? ""
        return word + duration
    }
}

private struct UnattendedQueueLink: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.transport.queue.queuedCount
        Button {
            model.showQueuePanel = true
        } label: {
            Label(model.transport.queueRunningNow ? "The unattended queue is running — \(waiting) waiting"
                  : waiting > 0 ? "Unattended queue: \(waiting) waiting" : "Unattended queue (runs tasks as goals, one after another)",
                  systemImage: "list.bullet.rectangle")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("The Task Queue (⌘⇧Q): work that runs unattended across projects, each task as a goal in its own chat")
    }
}

// MARK: - Prompts

struct PromptsTab: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var query = ""

    var body: some View {
        let expanded = model.expandedPromptID
        let records = PromptTimeline.filter(session.promptHistory, query: query)
        let groups = PromptTimeline.grouped(records)
        let queued = model.transport.queue.chatTasks(session.id).filter { $0.status == .queued }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Search this chat's prompts", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("All Chats…") { model.showAllPrompts = true }
                    .controlSize(.small)
                    .help("Every chat's prompts on this Mac (⌥⇧⌘H)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if !queued.isEmpty, query.isEmpty {
                        Section {
                            ForEach(Array(queued.enumerated()), id: \.element.id) { index, task in
                                QueuedPromptRow(task: task, position: index + 1)
                            }
                        } header: {
                            DayHeader(title: "Up next")
                        }
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                PromptRow(record: record, chatTitle: nil, expanded: expanded == record.id) {
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        model.expandedPromptID = expanded == record.id ? nil : record.id
                                    }
                                }
                            }
                        } header: {
                            DayHeader(title: group.title)
                        }
                    }
                    if records.isEmpty {
                        Text(query.isEmpty ? "No prompts in this chat yet. Each one you send shows up here with how it ended."
                                           : "No prompt matches “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 30)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }
}

struct DayHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
    }
}

private struct QueuedPromptRow: View {
    let task: QueueTask
    let position: Int
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label("Queued · #\(position)", systemImage: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(task.promptText).font(.callout).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(6)
    }
}

/// One prompt: when, what, how it ended, how long against the estimate — and, opened, the actions: copy it, quote it
/// into the composer, jump to it in the chat, open its results.
struct PromptRow: View {
    @Environment(AppModel.self) private var model
    let record: PromptRecord
    /// Shown in the All Prompts view, where rows come from many chats.
    let chatTitle: String?
    let expanded: Bool
    var onJump: (() -> Void)?
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let copyID = MessageCopy.promptFeedbackID(record.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.at, style: .time)
                    .font(Theme.mono(10)).foregroundStyle(.tertiary)
                if record.source != .typed {
                    Text(record.source.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surfaceStrong, in: Capsule())
                }
                if let chatTitle {
                    Text(chatTitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                CopiedBadge(id: copyID)
                if hovering || expanded {
                    CopyButton(id: copyID, help: "Copy this prompt, exactly as sent") {
                        MessageCopy.text(for: record, transport: model.transport)
                    }
                }
                OutcomeChip(record: record)
            }
            // A prompt of thousands of lines is laid out only as far as it shows (Copy still gives all of it).
            Text(LongText.isLong(record.text) ? LongText.head(record.text, lines: 14) : record.text)
                .font(.callout)
                .lineLimit(expanded ? 14 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: record.outcome == .running ? 1 : 3600)) { context in
                let timing = PromptTimeline.timing(record, now: context.date)
                if !timing.isEmpty {
                    Text(timing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if expanded {
                if let reason = record.reason, record.outcome != .completed {
                    Text(reason).font(.caption).foregroundStyle(OutcomeChip.tint(record.outcome))
                        .lineLimit(4)
                }
                HStack(spacing: 12) {
                    Button { model.copyPrompt(record) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    Button { model.addToComposer(record) } label: { Label("Add to composer", systemImage: "text.quote") }
                        .help("Quote it in the composer with how it ended, to talk about it")
                    Button { jump() } label: { Label("Jump", systemImage: "arrow.up.forward.square") }
                        .help("Scroll the chat to it")
                    Button { model.resultsRecord = record } label: { Label("Results", systemImage: "checkmark.seal") }
                        .help("Its results, evidence and completion notes")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .labelStyle(.titleAndIcon)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(expanded ? Theme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { jump() }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Copy Prompt") { model.copyPrompt(record) }
            Button("Add to Composer") { model.addToComposer(record) }
            Button("Jump to It") { jump() }
            Button("Results and Notes…") { model.resultsRecord = record }
        }
    }

    private func jump() {
        if let onJump { onJump() } else { model.jump(to: record) }
    }
}

// MARK: - Results

/// A prompt's results and completion notes: how it ended, its timing against the estimate, attempts, what it ran on,
/// the evidence, and the closing notes.
struct PromptResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: PromptRecord
    /// What the prompt's turn changed (its checkpoint record; the turn id is the prompt's id).
    @State private var changes: TurnCheckpointRecord?
    @State private var rewinding: RewindRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: record.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(OutcomeChip.tint(record.outcome))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.headline).font(.headline).foregroundStyle(OutcomeChip.tint(record.outcome))
                    Text("\(record.source.label) · \(chatTitle)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(record.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    facts
                    if !record.evidence.isEmpty {
                        RunSection(title: "Evidence", count: record.evidence.count) {
                            ForEach(record.evidence) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: item.kind.symbol).font(.system(size: 10)).frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(item.title).font(.system(size: 11.5, weight: .medium))
                                            Text(item.at, style: .time).font(Theme.mono(9.5)).foregroundStyle(.tertiary)
                                        }
                                        if !item.detail.isEmpty {
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(6).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let changes, let session = model.transport.sessions.first(where: { $0.id == record.chatID }) {
                        RunSection(title: "Files changed", count: changes.changedFiles.count) {
                            if changes.rewoundAt != nil {
                                Text("Rewound").font(Theme.metaFont).foregroundStyle(Theme.noticeTint)
                            }
                            ForEach(changes.changedFiles) { file in
                                ChangedFileRow(file: file, root: session.workspaceURL?.path)
                            }
                            let blocked = model.transport.rewindBlocked(turnID: changes.id, in: session)
                            Button("Rewind this turn…") { rewinding = RewindRequest(chatID: session.id, turnID: changes.id) }
                                .controlSize(.small)
                                .disabled(blocked != nil)
                                .help(blocked ?? "Put these files back to how they were before this turn (you confirm first)")
                        }
                    }
                    if let note = record.completionNote, !note.isEmpty {
                        RunSection(title: "Completion notes") {
                            Text(note).font(.callout).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let reason = record.reason, record.outcome != .completed {
                        RunSection(title: record.outcome == .failed ? "Why it failed" : "Why") {
                            Text(reason).font(.callout).foregroundStyle(OutcomeChip.tint(record.outcome))
                                .textSelection(.enabled)
                        }
                    }
                    if record.backfilled {
                        Text("This prompt was sent before Vision kept a timeline; its ending was read from the chat.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Copy Prompt") { model.copyPrompt(record) }
                Button("Add to Composer") { model.addToComposer(record); dismiss() }
                Button("Jump to It") { model.jump(to: record); dismiss() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 560)
        .onAppear { changes = model.transport.checkpoint(chatID: record.chatID, turnID: record.id) }
        .sheet(item: $rewinding, onDismiss: {
            changes = model.transport.checkpoint(chatID: record.chatID, turnID: record.id)
        }) { request in
            RewindSheet(request: request).environment(model)
        }
    }

    private var chatTitle: String {
        model.transport.sessions.first { $0.id == record.chatID }?.title ?? "a deleted chat"
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            fact("Sent", record.at.formatted(date: .abbreviated, time: .shortened))
            if let finished = record.finishedAt {
                fact("Finished", finished.formatted(date: .abbreviated, time: .shortened))
            }
            if let duration = record.durationSeconds {
                fact("Took", duration.formattedDuration
                     + (record.etaSeconds.map { " · estimated \(TurnPhaseState.phrase($0))" } ?? "")
                     + (PromptTimeline.versusEstimate(record).map { " (\($0))" } ?? ""))
            } else if let eta = record.etaSeconds {
                fact("Estimate", TurnPhaseState.phrase(eta))
            }
            if !record.backfilled { fact("Attempts", "\(record.attempts)") }
            if let rounds = record.rounds { fact("Rounds", "\(rounds)") }
            if let kind = record.taskKind.flatMap(TurnPhaseState.TaskKind.init(rawValue:)) { fact("Kind", kind.label) }
            if let model = record.model {
                fact("Ran on", model + (record.route.map { " · \($0)" } ?? ""))
            }
            if record.promptTokens + record.completionTokens > 0 {
                fact("Tokens", "\(record.promptTokens.formatted()) in · \(record.completionTokens.formatted()) out")
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - All prompts

/// Every chat's prompts on this Mac, by day, searchable — open one to jump to it in its chat.
struct AllPromptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PromptRecord] = []
    @State private var query = ""
    @State private var outcome: OutcomeFilter = .all
    @State private var expanded: String?

    enum OutcomeFilter: String, CaseIterable, Identifiable {
        case all = "All", completed = "Completed", failed = "Failed", stopped = "Stopped",
             running = "Running or queued", needsYou = "Needs you"
        var id: String { rawValue }
        func keeps(_ record: PromptRecord) -> Bool {
            switch self {
            case .all: true
            case .completed: record.outcome == .completed || record.outcome == .issues
            case .failed: record.outcome == .failed
            case .stopped: record.outcome == .stopped
            case .running: record.outcome.isOpen
            case .needsYou: record.outcome == .needsYou
            }
        }
    }

    var body: some View {
        let titles = Dictionary(model.transport.sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let shown = PromptTimeline.filter(records, query: query, chatTitles: titles).filter(outcome.keeps)
        let groups = PromptTimeline.grouped(shown)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("All prompts").font(.headline)
                    Text("\(records.count) prompt\(records.count == 1 ? "" : "s") across \(Set(records.map(\.chatID)).count) chats on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Outcome", selection: $outcome) {
                    ForEach(OutcomeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                TextField("Search prompts, notes, chats", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.records) { record in
                                PromptRow(record: record, chatTitle: titles[record.chatID] ?? "Deleted chat",
                                          expanded: expanded == record.id,
                                          onJump: { open(record) }) {
                                    expanded = expanded == record.id ? nil : record.id
                                }
                            }
                        } header: {
                            DayHeader(title: group.title)
                        }
                    }
                    if shown.isEmpty {
                        Text(records.isEmpty ? "No prompts yet." : "Nothing matches.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Text("Double-click a prompt to open it in its chat.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .onAppear { records = model.transport.allPromptRecords() }
    }

    private func open(_ record: PromptRecord) {
        guard model.transport.sessions.contains(where: { $0.id == record.chatID }) else { return }
        dismiss()
        model.jump(to: record)
    }
}
