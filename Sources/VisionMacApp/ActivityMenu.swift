import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - Background activity (toolbar button with a live count, ⌥⌘A)
//
// Everything working right now, in every chat: the main agent of each running chat, each subagent and background
// agent, the unattended queue, and chats with tasks waiting — each with the model it runs on and the server, what it
// was assigned (the plan step, the prompt, the task), how long it has run, its tokens and steps; open its log, stop it.
// The model servers' load is at the bottom.

struct ActivityToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let count = model.transport.activityCount
        Button {
            model.showActivity.toggle()
        } label: {
            Label {
                Text("Activity")
            } icon: {
                Image(systemName: count > 0 ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 8.5, weight: .bold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5).padding(.vertical, 0.5)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
            }
        }
        .help(count == 0 ? "Background activity (⌥⌘A) — nothing is working right now"
                         : "Background activity (⌥⌘A) — \(count) working: which models and agents, on what")
        .popover(isPresented: $model.showActivity, arrowEdge: .bottom) {
            ActivityList().environment(model)
        }
    }
}

struct ActivityList: View {
    @Environment(AppModel.self) private var model
    @State private var logRun: AgentLogRequest?

    var body: some View {
        let items = model.transport.activityItems()
        let working = items.filter(\.running).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Background activity").font(.headline)
                    Text(working == 0 ? "Nothing is working right now" : "\(working) working")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if working > 0 {
                    Button("Stop All") { model.stopAll() }
                        .controlSize(.small)
                        .tint(.red)
                        .help("Stop every agent and the queue (⇧⌘.)")
                }
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                Text("When the agent works — a prompt, a /goal, subagents, the task queue — each piece shows here with the model and server it runs on and what it is doing.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups(items), id: \.title) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.title)
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ForEach(group.items) { item in
                                    ActivityRow(item: item, openLog: { open(item) })
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 460)
            }
            Divider()
            ServersFooter()
                .padding(12)
        }
        .frame(width: 440)
        .sheet(item: $logRun) { request in
            AgentLogView(request: request).environment(model)
        }
    }

    private struct Group { var title: String; var items: [ActivityItem] }

    private func groups(_ items: [ActivityItem]) -> [Group] {
        var out: [Group] = []
        for item in items {
            let title = item.kind == .queueRunner ? "Task queue" : item.chatTitle
            if let index = out.firstIndex(where: { $0.title == title }) {
                out[index].items.append(item)
            } else {
                out.append(Group(title: title, items: [item]))
            }
        }
        return out
    }

    private func open(_ item: ActivityItem) {
        switch item.kind {
        case .subagent, .backgroundAgent:
            if let chatID = item.chatID, let runID = item.agentRunID {
                logRun = AgentLogRequest(chatID: chatID, runID: runID)
            } else if let chatID = item.chatID {
                model.openSession(chatID)
            }
        case .mainAgent, .chatTasks:
            if let chatID = item.chatID {
                model.openSession(chatID)
                model.runPanelTab = .tasks
                model.config.planPanelOpen = true
            }
            model.showActivity = false
        case .queueRunner:
            model.showQueuePanel = true
            model.showActivity = false
        }
    }
}

private struct ActivityRow: View {
    @Environment(AppModel.self) private var model
    let item: ActivityItem
    let openLog: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 12))
                .foregroundStyle(item.running ? Color.accentColor : .secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let started = item.startedAt, item.running {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(max(0, context.date.timeIntervalSince(started)).formattedDuration)
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if let placement = item.placement {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu").foregroundStyle(Color.accentColor)
                        Text(placement).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .help("The model and the model server (route) it runs on")
                }
                if let assignment = item.assignment {
                    Text(assignment).font(.system(size: 11)).lineLimit(2)
                }
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            VStack(spacing: 6) {
                Button(action: openLog) { Image(systemName: item.kind == .subagent || item.kind == .backgroundAgent ? "doc.text.magnifyingglass" : "arrow.up.forward.square") }
                    .help(item.kind == .subagent || item.kind == .backgroundAgent ? "Open its log" : "Open")
                if item.canStop {
                    Button { model.transport.stopActivity(item) } label: { Image(systemName: "stop.circle") }
                        .foregroundStyle(Theme.errorTint)
                        .help(stopHelp)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusLine: String {
        var parts = [item.status]
        if let activity = item.activity, !activity.isEmpty { parts.append(activity) }
        if let steps = item.steps, steps > 0 { parts.append("\(steps) step\(steps == 1 ? "" : "s")") }
        if let tokens = item.tokens, tokens > 0 { parts.append("\(tokens.formatted()) tokens") }
        return parts.joined(separator: " · ")
    }

    private var stopHelp: String {
        switch item.kind {
        case .subagent: "Stop the turn this subagent works for"
        case .backgroundAgent: "Stop this background agent"
        case .mainAgent: "Stop this chat's agent"
        case .queueRunner: "Stop the queue; its task goes back in line"
        case .chatTasks: "Pause this chat's tasks"
        }
    }
}

/// The model servers and how busy each is.
private struct ServersFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let servers = model.transport.fleet.snapshot()
        VStack(alignment: .leading, spacing: 4) {
            Text("Model servers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if servers.isEmpty {
                Text("None configured.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                HStack(spacing: 6) {
                    Circle().fill(server.healthy ? Theme.successTint : Theme.errorTint).frame(width: 6, height: 6)
                    Text(server.label).font(.caption.weight(.medium))
                    Text(server.isPrimary ? "main model" : "subagents")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(server.inFlight)/\(server.maxParallel) busy · \(server.completed) done"
                         + (server.failed > 0 ? " · \(server.failed) failed" : "")
                         + (server.healthy ? "" : " · not answering"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if servers.count == 1 {
                Text("Subagents share the main model. Turn on “Use for subagents” for another route in Settings ▸ AI Models to run them on other servers.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AgentLogRequest: Identifiable, Hashable {
    var chatID: String
    var runID: String
    var id: String { chatID + "/" + runID }
}

/// A subagent's log: where it ran (model and server) and why, the plan step it worked, the task it was given, every
/// stamped step, and its report.
struct AgentLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AgentLogRequest

    var body: some View {
        let run = model.transport.sessions.first { $0.id == request.chatID }?.agentRuns.first { $0.id == request.runID }
        VStack(alignment: .leading, spacing: 0) {
            if let run {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(run.description)").font(.headline)
                    Text("\(run.agentType) agent\(run.isBackground ? " · background" : "") · \(run.status.rawValue) · \(run.elapsed().formattedDuration)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let placement = run.placementLabel {
                        Label(placement, systemImage: "cpu").font(.callout).foregroundStyle(Color.accentColor)
                    }
                    if let note = run.placement {
                        Text(note).font(.caption).foregroundStyle(Theme.noticeTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let step = run.assignment {
                        Text("Plan step: \(step)").font(.caption)
                    }
                    if run.promptTokens + run.completionTokens > 0 {
                        Text("\(run.promptTokens.formatted()) tokens in · \(run.completionTokens.formatted()) out")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let prompt = run.prompt {
                            RunSection(title: "Task it was given") {
                                Text(prompt).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        RunSection(title: "Log", count: run.log.count) {
                            ForEach(Array(run.log.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(line.at, style: .time).font(Theme.mono(10)).foregroundStyle(.tertiary)
                                    Text(line.text).font(.caption).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if let report = run.report {
                            RunSection(title: "Report") {
                                Text(report).font(.callout).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(14)
                }
            } else {
                Text("That subagent is no longer listed.").padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
    }
}
