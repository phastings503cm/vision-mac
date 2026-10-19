import SwiftUI
import AppKit
import VisionHarnessCore

/// Code mode: the agent is the main view. Around it, each on its own toggle (toolbar, View menu, shortcuts):
/// the project's file tree (⌘B), the tabbed editor (⌥⌘E) and the terminal (⌃`). With the editor and terminal hidden
/// the chat takes the middle and the project status — run phases, the plan and tasks, agents, git — sits beside it;
/// ⌥⌘↩ hides everything but those two. Opening a file brings the editor back in the middle. The layout is
/// remembered per project.
struct CodeModeView: View {
    @Environment(AppModel.self) private var model

    private var code: CodeWorkspace { model.code }

    var body: some View {
        // Split views size children to their ideal height unless told to
        // fill, which otherwise leaves the panes floating in a band.
        HSplitView {
            if code.showTree {
                // Beside the chat (no editor) the tree stays a narrow navigator; the chat is the main view.
                FileTreeView()
                    .frame(minWidth: 180, idealWidth: 250, maxWidth: code.editorAreaVisible ? 460 : 300,
                           maxHeight: .infinity)
            }

            if code.editorAreaVisible {
                VSplitView {
                    if code.editorVisible {
                        EditorArea()
                            .frame(minHeight: 140, maxHeight: .infinity)
                    }
                    if code.terminalVisible {
                        TerminalPanel()
                            .frame(minHeight: 100, idealHeight: 240, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                if code.chatVisible {
                    chatPane
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 640,
                               maxHeight: .infinity)
                }
            } else {
                // The chat is the main view; the project status beside it.
                chatPane
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                ProjectStatusPanel()
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 460, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                CodeLayoutToggle(on: code.showTree, icon: "sidebar.squares.left",
                                 help: "File tree (⌘B)") { code.toggleTree() }
                CodeLayoutToggle(on: code.editorVisible, icon: "doc.text",
                                 help: "Editor (⌥⌘E)") { code.toggleEditor() }
                CodeLayoutToggle(on: code.terminalVisible, icon: "apple.terminal",
                                 help: "Terminal (⌃`)") { code.toggleTerminal() }
                if code.editorAreaVisible {
                    CodeLayoutToggle(on: code.chatVisible, icon: "bubble.left.and.bubble.right",
                                     help: "The agent beside the editor") { code.toggleChat() }
                }
                CodeLayoutToggle(on: code.isChatFocus, icon: "rectangle.and.text.magnifyingglass",
                                 help: code.isChatFocus ? "Show the files and the editor again (⌥⌘↩)"
                                                        : "Chat and project status only, full window (⌥⌘↩)") {
                    code.toggleChatFocus()
                }
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { code.errorMessage != nil },
                                    set: { if !$0 { code.errorMessage = nil } })) {
            Button("OK") { code.errorMessage = nil }
        } message: {
            Text(code.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var chatPane: some View {
        if let session = model.selectedSession {
            ChatView(session: session)
        } else {
            EmptyStateView(icon: "bubble.left.and.bubble.right",
                           title: "No chat open",
                           message: "Start a chat to work on this project with the agent.") {
                Button("New Chat") { model.newChat() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// A layout button that shows whether its pane is on.
private struct CodeLayoutToggle: View {
    let on: Bool
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .help(help + (on ? " — showing" : " — hidden"))
    }
}

// MARK: - Editor

/// Tab bar plus the active buffer.
struct EditorArea: View {
    @Environment(AppModel.self) private var model

    private var code: CodeWorkspace { model.code }

    var body: some View {
        VStack(spacing: 0) {
            if !code.buffers.isEmpty {
                tabBar
                Divider()
            }
            if let buffer = code.activeBuffer {
                if buffer.diskConflict { conflictBar(buffer) }
                CodeEditorView(buffer: buffer,
                               fontSize: model.config.editorFontSize,
                               wraps: model.config.editorWraps,
                               showsLineNumbers: model.config.editorLineNumbers)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                statusBar(buffer)
            } else {
                EmptyStateView(icon: "doc.text",
                               title: "No file open",
                               message: model.project == nil
                                   ? "Open a project folder, then pick a file from the tree."
                                   : "Pick a file from the tree to start editing.") {
                    if model.project == nil {
                        Button("Open Folder…") { model.chooseProject() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(code.buffers) { buffer in
                    EditorTab(buffer: buffer,
                              isActive: buffer.id == code.activeBufferID,
                              select: { code.activeBufferID = buffer.id },
                              close: { code.closeBuffer(buffer.id) })
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    /// The agent (or anything else) rewrote a file that has unsaved edits.
    private func conflictBar(_ buffer: EditorBuffer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.noticeTint)
            Text("\(buffer.name) changed on disk while you had unsaved edits.")
                .font(.system(size: 11))
            Spacer()
            Button("Keep Mine") { buffer.keepMine() }
                .controlSize(.small)
            Button("Reload from Disk") { buffer.reloadFromDisk() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.noticeTint.opacity(0.14))
    }

    private func statusBar(_ buffer: EditorBuffer) -> some View {
        HStack(spacing: 12) {
            Text(code.relativePath(buffer.url))
                .lineLimit(1)
                .truncationMode(.head)
                .help(buffer.url.path)
            Spacer()
            if buffer.isDirty {
                Button("Save") { code.save(buffer) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            Text(buffer.language.name)
            Text("\(buffer.text.count.formatted()) chars").monospacedDigit()
        }
        .font(Theme.metaFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

private struct EditorTab: View {
    @Bindable var buffer: EditorBuffer
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(buffer.name)
                .font(.system(size: 11))
                .lineLimit(1)
            Group {
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                } else if buffer.isDirty {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                } else {
                    Color.clear.frame(width: 6, height: 6)
                }
            }
            .frame(width: 12)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(buffer.url.path)
    }
}

// MARK: - Terminal panel

struct TerminalPanel: View {
    @Environment(AppModel.self) private var model

    private var code: CodeWorkspace { model.code }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let terminal = code.activeTerminal {
                TerminalScreen(session: terminal, fontSize: model.config.terminalFontSize)
                    .id(terminal.id)
            } else {
                EmptyStateView(icon: "apple.terminal",
                               title: "No terminal",
                               message: "Open a shell in the project folder.") {
                    Button("New Terminal") { code.newTerminal() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(code.terminals) { terminal in
                        TerminalTab(terminal: terminal,
                                    isActive: terminal.id == code.activeTerminalID,
                                    select: { code.activeTerminalID = terminal.id },
                                    close: { code.closeTerminal(terminal.id) })
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Button { code.newTerminal() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New terminal")
            Button { code.activeTerminal?.clear() } label: { Image(systemName: "clear") }
                .buttonStyle(.plain)
                .help("Clear (⌘K)")
                .disabled(code.activeTerminal == nil)
            Button { code.terminalVisible = false } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .help("Hide the terminal")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

private struct TerminalTab: View {
    let terminal: TerminalSession
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: terminal.isRunning ? "apple.terminal.fill" : "apple.terminal")
                .font(.system(size: 9))
            Text(terminal.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Theme.surfaceStrong : .clear, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(terminal.cwd.path)
    }
}
