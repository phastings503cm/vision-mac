import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionHarnessCore

// MARK: - File ▸ Import Chats… (also Settings ▸ Import & Export)
//
// Every source at the top with what it holds; the chats below, newest first, with where they came from, when, and how
// many messages; tick some or all; Import. Chats already here show "Imported" and can't be ticked twice.

extension ChatSource {
    var icon: String {
        switch self {
        case .claudeCode: "terminal"
        case .codex: "curlybraces"
        case .openClaw: "pawprint"
        case .claudeAI: "bubble.left.and.text.bubble.right"
        case .chatGPT: "bubble.left.and.bubble.right"
        case .guardian: "shield.lefthalf.filled"
        case .vision: "eye"
        }
    }
}

struct ChatImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: ChatImportModel
    /// Open with this source's chats only (Settings ▸ Guardian's "Import chats from Guardian…").
    var focus: ChatSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sources
            Divider()
            filterBar
            list
            Divider()
            footer
        }
        .frame(width: 880, height: 620)
        .onAppear {
            if model.states.isEmpty { model.lookEverywhere() }
            if let focus { model.sourceFilter = focus }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Chats").font(.title3.weight(.semibold))
            Text("Bring conversations from other AI tools into \(AppIdentity.name) as chats you can carry on with any model. Reading them changes nothing, and nothing leaves this Mac except calls to your signed-in Guardian.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: Sources

    private var sources: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil)
                ForEach([ChatSource.claudeCode, .codex, .openClaw, .guardian], id: \.self) { chip($0) }
                ForEach([ChatSource.claudeAI, .chatGPT, .vision], id: \.self) { source in
                    if model.count(source) > 0 { chip(source) }
                }
                Button {
                    chooseFile()
                } label: {
                    Label("Add Export File…", systemImage: "doc.badge.plus")
                }
                .help("A Claude.ai or ChatGPT data export (.zip, its folder, or conversations.json), or a Vision chat (.json)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ source: ChatSource?) -> some View {
        let selected = model.sourceFilter == source
        return Button {
            model.sourceFilter = source
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source?.icon ?? "tray.full")
                Text(source?.label ?? "All")
                stateText(source)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
        .help(source.map(help) ?? "Every source")
    }

    @ViewBuilder
    private func stateText(_ source: ChatSource?) -> some View {
        if let source {
            switch model.states[source] ?? .idle {
            case .scanning(let done, let total):
                ProgressView().controlSize(.mini)
                if total > 0 { Text("\(done)/\(total)").foregroundStyle(.secondary).monospacedDigit() }
            case .ready(let count):
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            case .missing:
                Text("not found").foregroundStyle(.tertiary)
            case .signedOut:
                Text("sign in first").foregroundStyle(.tertiary)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
        } else {
            Text("\(model.candidates.count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func help(_ source: ChatSource) -> String {
        switch model.states[source] ?? .idle {
        case .missing:
            switch source {
            case .claudeCode: return "No Claude Code sessions on this Mac (~/.claude/projects)."
            case .codex: return "No Codex sessions on this Mac (~/.codex/sessions)."
            case .openClaw: return "No OpenClaw on this Mac (~/.openclaw)."
            default: return "Nothing found."
            }
        case .signedOut: return "Sign in to Guardian (Settings ▸ Guardian) to bring in your Guardian chats."
        case .failed(let why): return why
        default:
            switch source {
            case .claudeCode: return "Claude Code sessions in ~/.claude/projects (subagents' own transcripts are left out)."
            case .codex: return "Codex sessions in ~/.codex/sessions."
            case .openClaw: return "OpenClaw sessions: its session store and older transcript files."
            case .guardian: return "Your Guardian chats, and the Vision chats your account keeps in Guardian."
            default: return source.label
            }
        }
    }

    // MARK: Filter

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter by title, folder or source", text: $model.filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 320)
            if model.automatedCount > 0 {
                Toggle("Show scheduled and scripted runs (\(model.automatedCount))", isOn: $model.showAutomated)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            Spacer()
            Text("\(model.visible.count) shown · \(model.pickedCount) ticked")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: The chats

    private var list: some View {
        let shown = model.visible
        return Group {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    if model.states.values.contains(where: { if case .scanning = $0 { return true } else { return false } }) {
                        ProgressView()
                        Text("Looking for chats…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(model.candidates.isEmpty ? "No chats found yet. Add an export file, or sign in to Guardian."
                             : "No chats match.").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(shown) { candidate in
                    ChatImportRow(candidate: candidate, model: model)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Select All Shown") { model.selectAllShown() }
                .disabled(model.importing)
            Button("Select None") { model.selectNone() }
                .disabled(model.importing || model.picked.isEmpty)
            Button("Look Again") { model.lookEverywhere() }
                .disabled(model.importing)
                .help("Look in every source again for chats added since")
            if model.importing {
                ProgressView(value: Double(model.progress.done), total: Double(max(model.progress.total, 1)))
                    .frame(width: 140)
                Text("\(model.progress.done) of \(model.progress.total)").font(.callout).monospacedDigit()
                Button("Stop") { model.cancelImport() }
            } else if let result = model.result {
                Text(result).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(result)
            } else if let problem = model.problems.first {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .help(model.problems.joined(separator: "\n"))
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import \(model.pickedCount) Chat\(model.pickedCount == 1 ? "" : "s")") { model.importPicked() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.pickedCount == 0 || model.importing)
        }
        .padding(16)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a chat export"
        panel.message = "A Claude.ai or ChatGPT data export (.zip, its folder, or conversations.json), or a Vision chat (.json)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .json, .folder]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.add(file: url) }
    }
}

private struct ChatImportRow: View {
    let candidate: ChatImportCandidate
    let model: ChatImportModel

    var body: some View {
        let imported = model.isImported(candidate)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { imported || model.picked.contains(candidate.id) },
                                     set: { _ in model.toggle(candidate) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(imported)
            Image(systemName: candidate.source.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if imported {
                Text("Imported")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
            } else if candidate.automated {
                Text("Scheduled").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(candidate) }
        .help(candidate.cwd ?? candidate.title)
    }

    private var subtitle: String {
        var parts = [candidate.source.label, candidate.updatedAt.formatted(date: .abbreviated, time: .shortened)]
        if let count = candidate.messageCount { parts.append("\(count) message\(count == 1 ? "" : "s")") }
        if let detail = candidate.detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}
