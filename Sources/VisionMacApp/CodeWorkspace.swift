import SwiftUI
import AppKit
import Observation
import VisionHarnessCore

/// Everything code mode owns: the file tree, the open editors, the terminal
/// tabs, and the watcher that keeps all three honest about what is on disk.
@MainActor
@Observable
final class CodeWorkspace {
    private(set) var root: URL?
    private(set) var tree: FileNode?

    var buffers: [EditorBuffer] = []
    var activeBufferID: String?
    var selection: URL?

    var terminals: [TerminalSession] = []
    var activeTerminalID: String?
    var terminalVisible = false

    var showTree = true
    /// The editor in the middle. Hidden (with the terminal), the chat takes the middle and the project status sits
    /// beside it; opening a file brings the editor back.
    var editorVisible = true
    /// The agent beside the editor. Only the editor area can push it away: with the editor and terminal hidden the
    /// chat always shows.
    var chatVisible = true

    /// Nothing but the chat and the project status: no file tree, no editor, no terminal.
    var isChatFocus: Bool { !showTree && !editorVisible && !terminalVisible }
    /// The editor or the terminal is showing (the middle column).
    var editorAreaVisible: Bool { editorVisible || terminalVisible }
    /// Set when the user asks to mention a file in chat; the composer picks it
    /// up and clears it.
    var pendingMention: String?
    /// Raised when a file could not be opened, renamed, or deleted.
    var errorMessage: String?

    @ObservationIgnored private var watcher: FSWatcher?
    @ObservationIgnored private var pendingTreeRefresh: DispatchWorkItem?
    /// Set while restoring, so reopening tabs does not write the state back
    /// half-built.
    @ObservationIgnored private var restoring = false

    var activeBuffer: EditorBuffer? {
        guard let activeBufferID else { return nil }
        return buffers.first { $0.id == activeBufferID }
    }

    var activeTerminal: TerminalSession? {
        guard let activeTerminalID else { return nil }
        return terminals.first { $0.id == activeTerminalID }
    }

    var hasUnsavedChanges: Bool { buffers.contains { $0.isDirty } }

    // MARK: - Project lifecycle

    func open(root url: URL) {
        guard url != root else { return }
        close()
        root = url
        let node = FileNode(url: url, isDirectory: true)
        node.load()
        node.isExpanded = true
        tree = node
        watcher = FSWatcher(root: url) { [weak self] changed in
            Task { @MainActor in self?.filesChangedOnDisk(changed) }
        }
        restoreState(for: url)
    }

    func close() {
        for terminal in terminals { terminal.terminate() }
        terminals = []
        activeTerminalID = nil
        watcher?.stop()
        watcher = nil
        buffers = []
        activeBufferID = nil
        tree = nil
        root = nil
        selection = nil
        showTree = true
        editorVisible = true
        chatVisible = true
    }

    func relativePath(_ url: URL) -> String {
        guard let root, url.path.hasPrefix(root.path) else { return url.path }
        return String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
    }

    // MARK: - Editors

    func openFile(_ url: URL) {
        selection = url
        // A file asked for opens in the middle, even when the layout had the editor hidden.
        if !restoring, !editorVisible {
            editorVisible = true
            persistState()
        }
        if let existing = buffers.first(where: { $0.url == url }) {
            activeBufferID = existing.id
            return
        }
        guard FileFilter.isTextFile(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        guard let buffer = EditorBuffer(url: url) else {
            errorMessage = "\(url.lastPathComponent) could not be opened as text."
            return
        }
        buffers.append(buffer)
        activeBufferID = buffer.id
        persistState()
    }

    func closeBuffer(_ id: String) {
        guard let index = buffers.firstIndex(where: { $0.id == id }) else { return }
        let buffer = buffers[index]
        if buffer.isDirty, !confirmDiscard(buffer) { return }
        buffers.remove(at: index)
        if activeBufferID == id {
            activeBufferID = buffers.indices.contains(index) ? buffers[index].id : buffers.last?.id
        }
        persistState()
    }

    func closeActiveBuffer() {
        guard let activeBufferID else { return }
        closeBuffer(activeBufferID)
    }

    private func confirmDiscard(_ buffer: EditorBuffer) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(buffer.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(buffer)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func save(_ buffer: EditorBuffer) {
        do {
            try buffer.save()
        } catch {
            errorMessage = "Could not save \(buffer.name): \(error.localizedDescription)"
        }
    }

    func saveActive() {
        guard let activeBuffer else { return }
        save(activeBuffer)
    }

    func saveAll() {
        for buffer in buffers where buffer.isDirty { save(buffer) }
    }

    func isDirty(_ url: URL) -> Bool {
        buffers.first { $0.url == url }?.isDirty ?? false
    }

    /// Reveal a file in the tree and open it — used by "jump to file" from the
    /// chat's produced-file chips.
    func reveal(_ url: URL) {
        tree?.expand(toward: url)
        selection = url
        if !url.hasDirectoryPath { openFile(url) }
    }

    func selectFromTree(_ url: URL) {
        selection = url
        if buffers.contains(where: { $0.url == url }) {
            activeBufferID = buffers.first { $0.url == url }?.id
        }
    }

    func mentionInChat(_ url: URL) {
        pendingMention = relativePath(url)
    }

    // MARK: - Disk changes

    /// The agent's tool results tell us precisely which files changed; the
    /// watcher covers everything else (a build, a git checkout, another app).
    func applyExternalChanges(_ changes: [FileChange]) {
        filesChangedOnDisk(changes.map(\.url))
    }

    private func filesChangedOnDisk(_ urls: [URL]) {
        let interesting = urls.filter { !FileFilter.isNoise($0) }
        guard !interesting.isEmpty else { return }

        for url in interesting {
            if let buffer = buffers.first(where: { $0.url == url }) {
                buffer.externalChangeDetected()
            }
        }
        scheduleTreeRefresh()
    }

    /// A build touches thousands of paths; refresh the tree once things settle.
    private func scheduleTreeRefresh() {
        pendingTreeRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshTree() }
        }
        pendingTreeRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refreshTree() {
        tree?.load(force: true)
        tree?.children?.forEach { $0.refreshExpanded() }
    }

    // MARK: - Terminals

    @discardableResult
    func newTerminal(cwd: URL? = nil) -> TerminalSession? {
        guard let directory = cwd ?? root else { return nil }
        let session = TerminalSession(cwd: directory)
        terminals.append(session)
        activeTerminalID = session.id
        terminalVisible = true
        return session
    }

    func closeTerminal(_ id: String) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals[index].terminate()
        terminals.remove(at: index)
        if activeTerminalID == id {
            activeTerminalID = terminals.indices.contains(index) ? terminals[index].id : terminals.last?.id
        }
        if terminals.isEmpty { terminalVisible = false }
    }

    /// Toggle the panel, creating the first terminal on demand.
    func toggleTerminal() {
        if terminals.isEmpty {
            newTerminal()
        } else {
            terminalVisible.toggle()
        }
        persistState()
    }

    func toggleTree() {
        showTree.toggle()
        persistState()
    }

    func toggleEditor() {
        editorVisible.toggle()
        persistState()
    }

    func toggleChat() {
        chatVisible.toggle()
        persistState()
    }

    /// The chat and the project status alone, full window — or, from there, back to the files and the editor.
    func toggleChatFocus() {
        if isChatFocus {
            showTree = true
            editorVisible = true
        } else {
            showTree = false
            editorVisible = false
            terminalVisible = false
        }
        chatVisible = true
        persistState()
    }

    // MARK: - Restore

    /// What code mode reopens with. Terminals are not restored as processes —
    /// only whether the panel was showing — because a shell's state is not
    /// ours to fake.
    private struct SavedState: Codable {
        var files: [String] = []
        var active: String?
        var terminal = false
        var tree = true
        /// Older builds didn't save these: the editor shows when files were open, the chat always.
        var editor: Bool?
        var chat: Bool?
    }

    private func stateKey(_ root: URL) -> String { "code.state.\(root.path)" }

    private func persistState() {
        guard !restoring, let root else { return }
        let state = SavedState(files: buffers.map(\.url.path),
                               active: activeBuffer?.url.path,
                               terminal: terminalVisible,
                               tree: showTree,
                               editor: editorVisible,
                               chat: chatVisible)
        guard let data = try? JSONEncoder().encode(state) else { return }
        IsolatedRun.defaults.set(data, forKey: stateKey(root))
    }

    private func restoreState(for root: URL) {
        guard let data = IsolatedRun.defaults.data(forKey: stateKey(root)),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            // A project opened for the first time starts with the chat as the main view: the files are a click
            // (or ⌘B / ⌥⌘E) away.
            showTree = true
            editorVisible = false
            chatVisible = true
            return
        }
        restoring = true
        defer { restoring = false }

        showTree = state.tree
        editorVisible = state.editor ?? !state.files.isEmpty
        chatVisible = state.chat ?? true
        for path in state.files where FileManager.default.fileExists(atPath: path) {
            openFile(URL(fileURLWithPath: path))
        }
        if let active = state.active, buffers.contains(where: { $0.url.path == active }) {
            activeBufferID = active
        }
        if state.terminal { newTerminal() }
        if let first = buffers.first(where: { $0.url.path == state.active })?.url {
            tree?.expand(toward: first)
        }
    }

    // MARK: - File operations

    func promptNewFile(in directory: URL) {
        guard let name = prompt(title: "New File", message: "Name for the new file in \(directory.lastPathComponent):")
        else { return }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "\(name) already exists."
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
            refreshTree()
            tree?.expand(toward: url)
            openFile(url)
        } catch {
            errorMessage = "Could not create \(name): \(error.localizedDescription)"
        }
    }

    func promptNewFolder(in directory: URL) {
        guard let name = prompt(title: "New Folder", message: "Name for the new folder in \(directory.lastPathComponent):")
        else { return }
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
            refreshTree()
        } catch {
            errorMessage = "Could not create \(name): \(error.localizedDescription)"
        }
    }

    func promptRename(_ url: URL) {
        guard let name = prompt(title: "Rename", message: "New name for \(url.lastPathComponent):",
                                initial: url.lastPathComponent) else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            if let buffer = buffers.firstIndex(where: { $0.url == url }) {
                // A buffer's url is immutable; reopen at the new path.
                let wasActive = activeBufferID == buffers[buffer].id
                buffers.remove(at: buffer)
                openFile(destination)
                if !wasActive { activeBufferID = buffers.last?.id }
            }
            refreshTree()
        } catch {
            errorMessage = "Could not rename: \(error.localizedDescription)"
        }
    }

    func trash(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move \(url.lastPathComponent) to the Trash?"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            buffers.removeAll { $0.url == url }
            if activeBuffer == nil { activeBufferID = buffers.last?.id }
            refreshTree()
        } catch {
            errorMessage = "Could not delete: \(error.localizedDescription)"
        }
    }

    private func prompt(title: String, message: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
