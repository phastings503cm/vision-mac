import SwiftUI
import VisionHarnessCore

/// Subagents working in this chat, above the composer: how many, on which model servers, and — expanded —
/// what each is doing right now. With two DGX Sparks and Amazon Bedrock in the fleet this is where the
/// hardware interleaving is visible: "Spark 2 ×2 · Amazon Bedrock". A count is printed only
/// when two or more subagents share a server.
struct SubagentsBar: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var expanded = false

    var body: some View {
        let runs = session.runningAgentRuns
        let jobs = session.runningBackgroundJobs
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(headline(runs: runs, jobs: jobs))
                    .font(.system(size: 11, weight: .semibold))
                Text(summary(runs))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if !runs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide what each subagent is doing" : "Show what each subagent is doing")
                }
                if !jobs.isEmpty { stopMenu(jobs) }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(runs) { run in
                        HStack(spacing: 6) {
                            Text(run.agentType)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.surfaceStrong, in: Capsule())
                            Text(run.placementLabel ?? "waiting for a server")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(run.placementLabel == nil ? Color.secondary : Color.accentColor)
                                .lineLimit(1).truncationMode(.middle)
                                .help((run.placementLabel ?? "waiting for a server")
                                      + (SubagentPlacement.Reason.label(run.placementReason).map { " · \($0)" } ?? "")
                                      + (run.placement.map { "\n\($0)" } ?? ""))
                            Text("“\(run.description)” — \(run.activity)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(run.elapsed(at: context.date).formattedDuration)
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func headline(runs: [AgentRun], jobs: [BackgroundAgents.Job]) -> String {
        let count = max(runs.count, jobs.count)
        let kind = jobs.count == count && runs.isEmpty ? "background agent" : "subagent"
        return "\(count) \(kind)\(count == 1 ? "" : "s")"
    }

    /// "Spark 2 ×2 · Amazon Bedrock" — where the running subagents are, busiest first.
    /// A count appears only when two or more subagents share a server.
    private func summary(_ runs: [AgentRun]) -> String {
        guard !runs.isEmpty else { return "" }
        var counts: [String: Int] = [:]
        for run in runs { counts[run.route ?? run.server ?? "waiting for a server", default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            .joined(separator: " · ")
    }

    private func stopMenu(_ jobs: [BackgroundAgents.Job]) -> some View {
        Menu {
            ForEach(jobs) { job in
                Button("Stop \(job.id) “\(job.description)”") {
                    model.transport.stopBackgroundAgent(sessionID: session.id, id: job.id)
                }
            }
            Divider()
            Button("Stop all") { model.transport.stopBackgroundAgents(sessionID: session.id) }
        } label: {
            Image(systemName: "stop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Stop background agents")
    }
}
