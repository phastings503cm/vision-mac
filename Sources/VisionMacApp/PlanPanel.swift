import SwiftUI
import AppKit
import VisionHarnessCore

/// The plan panel (right side, ⇧⌘P, or the checklist button in the toolbar): the selected chat's plan — its goal,
/// the steps the agent is working through, a plan a planning run proposed, and the subagents working for it, and
/// where. It always shows the chat that is selected.
struct PlanPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.selectedSession
        VStack(spacing: 0) {
            header(session)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let session, session.hasPlan {
                        content(session)
                    } else {
                        empty(session)
                    }
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
        .background(.background)
    }

    // MARK: Header

    private func header(_ session: SessionVM?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan").font(.headline)
                    Text(session?.title ?? "No chat open")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                Button {
                    model.config.planPanelOpen = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide the plan (⇧⌘P)")
            }
            if let todos = session?.todos, !todos.isEmpty {
                let done = todos.filter { $0.status == .completed }.count
                ProgressView(value: Double(done), total: Double(todos.count))
                    .progressViewStyle(.linear)
                Text("\(done) of \(todos.count) done")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ session: SessionVM) -> some View {
        if let goal = session.goal {
            section("Goal") {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Working until done", systemImage: "target").font(.callout.weight(.semibold))
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("round \(goal.round) · \(context.date.timeIntervalSince(goal.started).formattedDuration)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(goal.text).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
        } else if let unfinished = session.lastGoal {
            section("Goal") {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Not finished — send /goal to pick it back up", systemImage: "pause.circle")
                            .font(.callout.weight(.semibold))
                        Text(unfinished).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
        }

        if !session.todos.isEmpty {
            section("Steps") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.todos) { item in
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
                    }
                }
            }
        }

        if let plan = session.proposedPlan {
            section("Proposed plan") {
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownView(source: plan)
                        Text("Proposed in plan mode, which changes nothing. To carry it out, start a new chat with another permission preset.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        let running = session.runningAgentRuns
        if !running.isEmpty {
            section("Subagents") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(running) { run in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(run.agentType)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.surfaceStrong, in: Capsule())
                                Text(run.description).font(.callout).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(run.elapsed(at: context.date).formattedDuration)
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            Text([run.server ?? (model.transport.fleet.servers.isEmpty ? nil : "waiting for a server"), run.activity]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    private func empty(_ session: SessionVM?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(session == nil
                 ? "Open or start a chat, and its plan shows up here."
                 : "No plan in this chat yet. When the agent breaks work into steps or proposes a plan, it shows up here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
    }
}

/// The right column (Tasks · Prompts, see `RunPanel`) beside the window's content, with a handle on its edge to make
/// it wider or narrower (the width is remembered).
struct PlanPanelColumn: View {
    @Environment(AppModel.self) private var model
    @State private var dragStart: Double?

    static let widths: ClosedRange<Double> = 240...560

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
                .overlay(
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? model.config.planPanelWidth
                                if dragStart == nil { dragStart = start }
                                let width = start - Double(value.translation.width)
                                model.config.planPanelWidth = min(max(width, Self.widths.lowerBound), Self.widths.upperBound)
                            }
                            .onEnded { _ in dragStart = nil })
                )
                .help("Drag to resize the plan")
            RunPanel()
                .frame(width: CGFloat(model.config.planPanelWidth))
        }
    }
}
