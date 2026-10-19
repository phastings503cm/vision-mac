import SwiftUI
import AppKit
import VisionHarnessCore

/// Projects and chats. Anything running sorts to the top and stays reachable
/// without opening its chat.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var renameText = ""

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(spacing: 0) {
            if model.anythingRunning { runningBar }
            ChatSearchField(search: model.chatSearch)

            List(selection: Binding(
                get: { transport.selectedID },
                set: { model.select($0) }
            )) {
                if model.chatSearch.isActive {
                    searchResults
                } else {
                    projectSection
                    chatSection
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) { footer }
    }

    // MARK: Running bar

    private var runningBar: some View {
        let running = transport.runningSessions
        return Button {
            if let first = running.first { model.select(first.id) }
        } label: {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(running.count == 1 ? "1 agent running" : "\(running.count) agents running")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Stop All") { model.stopAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.errorTint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.accentColor.opacity(0.12))
    }

    // MARK: Search

    @ViewBuilder
    private var searchResults: some View {
        let search = model.chatSearch
        Section(search.searching && search.hits.isEmpty ? "Searching…"
                : "\(search.hits.count) chat\(search.hits.count == 1 ? "" : "s")") {
            if !search.searching, search.hits.isEmpty {
                Text("No chat holds every word.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(search.hits) { hit in
                Button {
                    model.open(hit)
                } label: {
                    SearchHitRow(hit: hit)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Projects

    @ViewBuilder
    private var projectSection: some View {
        Section("Project") {
            if let project = model.project {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let branch = ProjectContext.gitBranch(at: project) {
                            Text(branch)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contextMenu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(project.path, forType: .string)
                    }
                    Divider()
                    Button("Close Project") { model.closeProject() }
                }
            }

            Button {
                model.chooseProject()
            } label: {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            let recents = model.config.liveRecentProjects.filter { $0 != model.project }
            if !recents.isEmpty {
                DisclosureGroup("Recent") {
                    ForEach(recents, id: \.self) { url in
                        Button {
                            model.openProject(url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                        .contextMenu {
                            Button("Remove from Recents") { model.forgetProject(url) }
                        }
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    // MARK: Chats

    @ViewBuilder
    private var chatSection: some View {
        let sessions = orderedSessions
        Section("Chats") {
            if sessions.isEmpty {
                Text("No chats yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                SessionRow(session: session,
                           isRenaming: renaming == session.id,
                           renameText: $renameText,
                           commitRename: { commitRename(session) })
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename…") {
                            renameText = session.title
                            renaming = session.id
                        }
                        if session.running {
                            Button("Stop Agent") { transport.stopSession(session.id) }
                        }
                        if let cwd = session.workspaceURL {
                            Button("Reveal Project in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([cwd])
                            }
                        } else {
                            Button("Reveal Chat Folder in Finder") {
                                let folder = transport.scratchFolder(for: session, create: true)
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            }
                        }
                        Divider()
                        Button("Export as Markdown…") { ChatExportActions.save(.markdown, sessionID: session.id, transport: transport) }
                        Button("Export as JSON…") { ChatExportActions.save(.json, sessionID: session.id, transport: transport) }
                        Button("Send to Guardian") {
                            ChatExportActions.sendToGuardian(sessionID: session.id, transport: transport, guardian: model.guardian)
                        }
                        .disabled(!model.guardian.isSignedIn)
                        Divider()
                        Button("Delete", role: .destructive) { transport.deleteSession(session.id) }
                    }
            }
        }
    }

    /// Running chats first, then most recent.
    private var orderedSessions: [SessionVM] {
        transport.sessions.sorted {
            if $0.running != $1.running { return $0.running }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func commitRename(_ session: SessionVM) {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { transport.renameSession(session.id, to: title) }
        renaming = nil
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(model.project == nil ? "New chat (⌘N)" : "New chat in \(model.project?.lastPathComponent ?? "the project") (⌘N)")

                if model.project != nil {
                    Button {
                        model.newPlainChat()
                    } label: {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("New chat without a project (⇧⌘N)")
                }

                Spacer()

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let isRenaming: Bool
    @Binding var renameText: String
    let commitRename: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if session.running {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
            } else {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Title", text: $renameText, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    Text(session.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 4) {
                    if let source = session.importSource, source != .vision {
                        Image(systemName: source.icon)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Imported from \(source.label)")
                    }
                    if let project = session.projectName, project != model.project?.lastPathComponent {
                        Text(project)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(session.updatedAt.relativeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if session.running {
                Button {
                    model.transport.stopSession(session.id)
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.errorTint)
                .help("Stop this agent")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Searching every chat

/// The chat list's search field: every chat's title and what was said, with a menu to look in one source only.
struct ChatSearchField: View {
    @Bindable var search: ChatSearchModel
    @FocusState private var focused: Bool

    private static let scopes: [(String, ChatSearchScope)] = [("All chats", .all), ("Made in Vision", .madeHere)]
        + [ChatSource.claudeCode, .codex, .openClaw, .claudeAI, .chatGPT, .guardian, .vision].map { ("From \($0.label)", .source($0)) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search all chats", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onExitCommand { search.clear() }
            if search.isActive {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
            }
            Menu {
                Picker("Look in", selection: $search.scope) {
                    ForEach(Self.scopes, id: \.0) { scope in
                        Text(scope.0).tag(scope.1)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: search.scope == .all ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Look in every chat, or only those from one place")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: search.focusRequest) { _, _ in focused = true }
    }
}

private struct SearchHitRow: View {
    let hit: ChatSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let source = hit.source {
                    Image(systemName: source.icon).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(hit.title)
                    .font(.system(size: 12, weight: hit.titleMatch ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(hit.updatedAt.relativeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(hit.matches > 1 ? "\(hit.matches) places in this chat match" : hit.title)
    }
}
