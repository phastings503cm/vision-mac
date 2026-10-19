import SwiftUI
import AppKit
import VisionHarnessCore

/// The entry point: what the app kept under its old name comes over before anything reads it. The screenshot mode
/// (`--snapshot <folder>`) instead moves everything into a throwaway folder first and touches nothing of the user's.
@main
enum VisionLauncher {
    @MainActor static func main() {
        if let snapshot = Snapshot.options(arguments: CommandLine.arguments,
                                           environment: ProcessInfo.processInfo.environment) {
            Snapshot.prepare(snapshot)
        } else {
            LaunchMigration.run()
        }
        VisionMacApp.main()
    }
}

struct VisionMacApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    if Snapshot.isActive { await Snapshot.drive(model); return }
                    // ⌃⌥⌘. from any app: stop all AI control of the Mac.
                    let transport = model.transport
                    GlobalStopHotKey.shared.register { transport.stopMachineControl() }
                }
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }
    }
}

/// Keeps the app's lifetime tied to its window and stops agents on the way out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Background processes the agent started (game engines, servers) must
        // not outlive the app that owns their ptys.
        ProcessManager.shared.stopAll()
        // Conversation writes are coalesced; get the last ones on disk.
        MainActor.assumeIsolated {
            ConversationLog.shared.flush(wait: true)
            Snapshot.cleanUp()
        }
    }
}

// MARK: - Menus

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { model.newChat() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Chat Without a Project") { model.newPlainChat() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Project Folder…") { model.chooseProject() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Import Chats…") { model.showChatImport = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Menu("Export Chat") {
                Button("Markdown…") { ChatExportActions.save(.markdown, sessionID: model.transport.selectedID, transport: model.transport) }
                Button("JSON…") { ChatExportActions.save(.json, sessionID: model.transport.selectedID, transport: model.transport) }
            }
            .disabled(model.transport.selectedID == nil)
            Button("Send Chat to Guardian") {
                ChatExportActions.sendToGuardian(sessionID: model.transport.selectedID, transport: model.transport,
                                                 guardian: model.guardian)
            }
            .disabled(model.transport.selectedID == nil)
            Divider()
            Button("New Terminal") {
                model.mode = .code
                model.code.newTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.project == nil)
        }

        // Nothing here prints; leaving Page Setup out keeps ⇧⌘P for the plan.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.code.saveActive() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.code.activeBuffer == nil)
            Button("Save All") { model.code.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.code.hasUnsavedChanges)
            Button("Close Editor") { model.code.closeActiveBuffer() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.code.activeBuffer == nil)
        }

        MessageCopyCommands(model: model)

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Stop Turn") { model.stopSelected() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!(model.selectedSession?.running ?? false))
            Button("Stop All Agents") { model.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!model.anythingRunning)
            // The same as ⌃⌥⌘., which works from any app (GlobalStopHotKey).
            Button("Stop All Computer Control (\(GlobalStopHotKey.display) from any app)") {
                model.transport.stopMachineControl()
            }
            Divider()
            Button("Memory & Skills…") { model.showMemoryAndSkills = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Credentials Vault…") { model.showVault = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("MCP Servers…") {
                model.settingsTab = .mcp
                model.showSettings = true
            }
            Button("Reload Project Context") { model.transport.refreshProjectContext() }
                .disabled(model.project == nil)
            Divider()
            Button("Rewind…") {
                if let session = model.selectedSession {
                    model.transport.rewindRequest = RewindRequest(chatID: session.id, turnID: nil)
                }
            }
            .disabled(model.selectedSession == nil)
            // Sensitive: only private models, or others through the shield (see SensitivityPolicy).
            Toggle("Sensitive Chat", isOn: Binding(
                get: { model.selectedSession?.sensitive ?? false },
                set: { on in if let session = model.selectedSession { model.transport.setSensitive(on, for: session) } }))
                .disabled(model.selectedSession == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Chat Mode") { model.mode = .chat }
                .keyboardShortcut("1", modifiers: .command)
            Button("Code Mode") { model.mode = .code }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button(model.config.planPanelOpen && model.runPanelTab == .tasks ? "Hide Tasks" : "Show Tasks") {
                model.toggleRunPanel(.tasks)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(model.config.planPanelOpen && model.runPanelTab == .prompts ? "Hide Prompts" : "Show Prompts") {
                model.toggleRunPanel(.prompts)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Search All Chats") {
                model.mode = .chat
                model.chatSearch.focusRequest += 1
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("All Prompts…") { model.showAllPrompts = true }
                .keyboardShortcut("h", modifiers: [.command, .shift, .option])
            Button("Background Activity") { model.showActivity.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button(model.code.showTree ? "Hide File Tree" : "Show File Tree") {
                model.mode = .code
                model.code.toggleTree()
            }
            .keyboardShortcut("b", modifiers: .command)
            Button(model.code.editorVisible ? "Hide Editor" : "Show Editor") {
                model.mode = .code
                model.code.toggleEditor()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.project == nil)
            Button(model.code.terminalVisible ? "Hide Terminal" : "Show Terminal") {
                model.mode = .code
                model.code.toggleTerminal()
            }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(model.project == nil)
            Button(model.code.isChatFocus ? "Show Files and Editor" : "Chat and Project Status Only") {
                model.mode = .code
                model.code.toggleChatFocus()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(model.project == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Run Setup Wizard…") { model.showWizard = true }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The banner's "Sign in to AWS…" is running (the browser is open).
    @State private var signingInToAWS = false

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.config.planPanelOpen {
                    PlanPanelColumn()
                        .transition(.move(edge: .trailing))
                }
            }
            .toolbar { toolbar }
        }
        // Guardian's refusals met in a chat (a spent budget, a module that's off) as a dialog.
        .guardianProblemAlert(model.guardian)
        .inspector(isPresented: $model.showQueuePanel) {
            QueueView()
                .environment(model)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .sheet(isPresented: $model.showWizard) {
            SetupWizard().environment(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environment(model)
        }
        .sheet(isPresented: $model.showMemoryAndSkills) {
            MemorySkillsView().environment(model)
        }
        .sheet(isPresented: $model.showVault) {
            VaultView().environment(model)
        }
        .sheet(isPresented: $model.showAllPrompts) {
            AllPromptsView().environment(model)
        }
        .sheet(item: Binding(get: { model.transport.rewindRequest }, set: { model.transport.rewindRequest = $0 })) { request in
            RewindSheet(request: request).environment(model)
        }
        .sheet(isPresented: $model.showChatImport) {
            ChatImportSheet(model: ChatImportModel(transport: model.transport, guardian: model.guardian))
                .environment(model)
        }
        .sheet(item: $model.resultsRecord) { record in
            PromptResultsView(record: record).environment(model)
        }
        .sheet(item: $model.bedrockGuide) { request in
            BedrockGuideView(request: request, appModel: model).environment(model)
        }
        .sheet(item: $model.swapperGuide) { request in
            SwapperGuideView(request: request, appModel: model).environment(model)
        }
        .sheet(item: $model.planGuide) { request in
            PlanGuideView(request: request, appModel: model).environment(model)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                renameNotice
                banner
            }
        }
    }

    /// Once, after the move from the app's old name: what came along, and what macOS will ask again.
    @ViewBuilder
    private var renameNotice: some View {
        if let notice = model.renameNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Got It") { model.dismissRenameNotice() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Color.accentColor.opacity(0.35)))
            .shadow(radius: 8, y: 2)
            .padding(12)
            .frame(maxWidth: 620)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mode {
        case .chat:
            if let session = model.selectedSession {
                ChatView(session: session)
            } else {
                EmptyStateView(icon: "sparkles",
                               title: "Vision",
                               message: "Chat with your AI, or open a folder to work on code.") {
                    HStack {
                        Button("Open Folder…") { model.chooseProject() }
                        Button("New Chat") { model.newChat() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case .code:
            CodeModeView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Chat (⌘1) or Code (⌘2)")
        }

        ToolbarItem(placement: .principal) {
            Button {
                model.chooseProject()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(model.project?.lastPathComponent ?? "No project")
                        .lineLimit(1)
                }
            }
            .help(model.project?.path ?? "Open a project folder (⌘O)")
        }

        ToolbarItem {
            ModelMenu()
        }

        ToolbarItem {
            PresetMenu()
        }

        ToolbarItem {
            Button {
                model.showVault = true
            } label: {
                Label("Credentials Vault", systemImage: "key.horizontal")
            }
            .help("Credentials vault (⌘⇧K) — API keys and passwords the agent can use without seeing them")
        }

        ToolbarItem {
            Button {
                model.toggleRunPanel(.tasks)
            } label: {
                Label("Tasks", systemImage: "checklist")
            }
            .help("This chat's tasks (⇧⌘P): what it is doing now — the plan, its steps and who works each — then what is queued after it")
        }

        ToolbarItem {
            Button {
                model.toggleRunPanel(.prompts)
            } label: {
                Label("Prompts", systemImage: "clock.arrow.circlepath")
            }
            .help("Prompts (⇧⌘H): every prompt this chat has sent and how it ended — copy, quote, jump to it, see its results. All chats: ⌥⇧⌘H")
        }

        ToolbarItem {
            ActivityToolbarButton()
        }

        ToolbarItem {
            Button {
                model.showQueuePanel.toggle()
            } label: {
                Label("Task Queue", systemImage: model.transport.queueRunningNow
                      ? "play.circle.fill" : "list.bullet.rectangle")
            }
            .help("Task queue (⌘⇧Q) — queue up work and let the harness run it unattended")
            .keyboardShortcut("q", modifiers: [.command, .shift])
        }

        ToolbarItem {
            if let session = model.selectedSession, session.running {
                Button {
                    model.transport.stopSession(session.id)
                } label: {
                    Label(session.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .disabled(session.stopping)
                .help("Stop the agent (⌘.)")
            }
        }
    }

    /// The banner's "Sign in to AWS…": the AWS sign-in behind a Bedrock route ran out. Sign the same
    /// profile in again (the browser opens), then the next message just works.
    private func signInToAWS(_ profile: String) {
        guard !signingInToAWS else { return }
        let region = model.config.providers.first { $0.kind == .bedrock && ($0.awsProfile ?? AWSSignIn.defaultProfile) == profile }?.awsRegion
        signingInToAWS = true
        model.transport.banner = "Finish signing in to AWS in the browser window that just opened…"
        model.transport.awsSignInProfile = profile
        Task {
            let result = await AWSAccounts.signInAgain(profile: profile, region: region)
            signingInToAWS = false
            if result.succeeded {
                model.transport.banner = nil
                model.transport.broadcast("Signed in to AWS again (profile “\(profile)”). Send your message again to carry on.")
            } else {
                model.transport.banner = result.message
                model.transport.awsSignInProfile = profile
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let message = model.transport.banner {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
                if !model.config.isConfigured {
                    Button("Set Up…") {
                        model.transport.banner = nil
                        model.showWizard = true
                    }
                    .controlSize(.small)
                }
                if let profile = model.transport.awsSignInProfile {
                    Button(signingInToAWS ? "Signing in…" : "Sign in to AWS…") { signInToAWS(profile) }
                        .controlSize(.small)
                        .disabled(signingInToAWS)
                        .help("Opens your browser to sign in to AWS again; your next message then goes through.")
                }
                Button {
                    model.transport.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.errorTint.opacity(0.4)))
            .shadow(radius: 8, y: 2)
            .padding(12)
            .frame(maxWidth: 620)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Toolbar menus

private struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The selected chat's own model (each chat has one; choosing here changes that chat only).
        let session = model.transport.selected
        let route = model.transport.chatRoute(session)
        Menu {
            RouteMenuSections(session: session)
            Divider()
            Button("Configure…") {
                model.settingsTab = .models
                model.showSettings = true
            }
            Button("Run Setup Wizard…") { model.showWizard = true }
        } label: {
            Label(model.transport.modelID(for: session) ?? route?.model ?? "No model", systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(route.map { session == nil ? "Primary: \($0.displayName)" : "This chat: \($0.displayName)" } ?? "No model configured")
    }
}

private struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingFullAccess = false

    var body: some View {
        Menu {
            Section("New chats start with") {
                ForEach(PermissionPreset.allCases, id: \.self) { preset in
                    Button {
                        if preset == .fullAccess {
                            confirmingFullAccess = true
                        } else {
                            model.config.preset = preset.rawValue
                        }
                    } label: {
                        if model.config.asPreset == preset {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            }
            if let session = model.selectedSession {
                Divider()
                Text("This chat: \(session.preset.label)")
            }
        } label: {
            Label(current.label, systemImage: current.icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(current == .fullAccess ? .red : nil)
        .help(current.detail)
        .alert("Turn on full access?", isPresented: $confirmingFullAccess) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Full Access", role: .destructive) {
                model.config.preset = PermissionPreset.fullAccess.rawValue
            }
        } message: {
            Text("""
            New chats will write files and run shell commands without asking, anywhere your user \
            account can reach. Existing chats keep the preset they were created with.
            """)
        }
    }

    /// The open chat's preset when there is one — that is what is actually in
    /// force — otherwise the default for new chats.
    private var current: PermissionPreset {
        model.selectedSession?.preset ?? model.config.asPreset
    }
}
