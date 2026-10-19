import SwiftUI
import AppKit
import VisionHarnessCore

/// Opens the Claude Code card (`AppModel.claudeCodeGuide`).
struct ClaudeCodeGuideRequest: Identifiable {
    let id = UUID()
}

// MARK: - The card

/// "Claude Code — your Claude Pro or Max plan": whether the claude command is on this Mac and signed in, how to
/// install it or sign in when it isn't, and which Claude Code models to add to the model menu.
struct ClaudeCodeGuideView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = ["sonnet", "opus"]
    @State private var useInChat = true
    @State private var added: String?

    private var host: ClaudeCodeHost { appModel.transport.claudeCode }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GuideIcon(systemName: "terminal")
                    GuideHeading("Claude Code — your Claude Pro or Max plan")
                    GuideLead("Chats you put on Claude Code run the official claude command on this Mac, signed in with your own Claude plan. Vision shows its replies, thinking, tool calls, files changed and cost, keeps the chat's conversation going from turn to turn, and runs /goal and the task queue on it. Vision never sees or touches your Claude sign-in — the claude command does the talking.")
                    statusSection
                    if host.status?.isUsable == true { modelsSection }
                    GuideNote(.info, "Claude Code reads your files and runs commands itself and sends what it reads to Anthropic, so Vision's shield can't mask it: Sensitive chats can't use Claude Code. Your plan's usage limits apply; each turn shows Claude Code's own estimate of what it would cost at API prices.",
                              title: "Good to know")
                    GuideAside("Permissions follow the chat's setting: Plan only → Claude Code's plan mode (reads, changes nothing); Workspace write → file edits in the chat's folder and commands, except ones that delete, move, install or commit; Full access → every command. Nobody can approve a request mid-turn, so anything else is refused and Claude says so.")
                }
                .padding(28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .task { if host.status == nil { await host.refresh() } }
    }

    @ViewBuilder
    private var statusSection: some View {
        if host.checking {
            GuideBusy("Looking for the claude command and asking whether it is signed in…")
        } else if let status = host.status {
            GuideNote(status.isUsable ? .success : (status.install == nil ? .warning : .error), status.summary,
                      title: status.isUsable ? "Ready" : "Not ready yet") {
                if let install = status.install {
                    Text(Self.whereText(install))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if !status.steps.isEmpty {
                ForEach(status.steps, id: \.self) { step in
                    if let command = step.command {
                        GuideCopyable(text: command, caption: step.text)
                    } else {
                        GuideParagraph(step.text, secondary: true)
                    }
                }
                Button("Open Terminal") { Self.openTerminal() }
                    .controlSize(.small)
            }
        }
        HStack(spacing: 8) {
            Button("Use a Different claude…") { choosePath() }
                .controlSize(.small)
            if !appModel.config.claudeCodePath.isEmpty {
                Button("Find It Automatically") {
                    appModel.config.claudeCodePath = ""
                    Task { await host.refresh() }
                }
                .controlSize(.small)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GuideSubheading("Models to add")
            ForEach(ClaudeCodeModels.choices, id: \.alias) { choice in
                GuideChoice(systemImage: "sparkle", title: choice.name, detail: choice.detail,
                            selected: chosen.contains(choice.alias)) {
                    if chosen.contains(choice.alias) { chosen.remove(choice.alias) } else { chosen.insert(choice.alias) }
                }
            }
            if appModel.transport.selected != nil {
                Toggle("Switch the chat I'm in to Claude Code", isOn: $useInChat)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            if let added {
                GuideNote(.success, added)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Check Again") { Task { await host.refresh() } }
                .disabled(host.checking)
            Button("Add to Vision") { add() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(host.status?.isUsable != true || chosen.isEmpty)
        }
        .padding(14)
    }

    private func add() {
        let order = ClaudeCodeModels.choices.map(\.alias).filter { chosen.contains($0) }
        let routes = ClaudeCodeRoutes.add(order, to: appModel.config)
        appModel.transport.resetRouteCache()
        appModel.config.wizardCompleted = true
        if useInChat, let vm = appModel.transport.selected, let first = routes.first {
            appModel.transport.setRoute(first.routeID, for: vm)
        }
        added = "Added " + routes.map { ClaudeCodeModels.name($0.model) }.joined(separator: ", ")
            + " to the model menu (under the message box)."
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the claude command (for example ~/.local/bin/claude)."
        panel.prompt = "Use This"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appModel.config.claudeCodePath = url.path
        Task { await host.refresh() }
    }

    /// Why a Claude Code route is never private (the roster's lock and the model menu).
    static let notPrivateHelp = "Not private: Claude Code reads your files and runs commands itself and sends what it reads to Anthropic, so the shield can't mask it. Sensitive chats can't use it."

    static func whereText(_ install: ClaudeCodeInstall) -> String {
        let path = (install.path as NSString).abbreviatingWithTildeInPath
        switch install.source {
        case .chosen: return "The claude you chose: \(path)"
        case .installed: return "Found at \(path)"
        case .desktopApp: return "Using the Claude desktop app's copy at \(path) — it updates with the desktop app."
        }
    }

    static func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

// MARK: - Editing a Claude Code route

/// Settings ▸ Models ▸ Edit… on a Claude Code route: its name, model and default thinking, and the CLI's status.
struct ClaudeCodeRouteEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderProfile
    @State private var reasoning: String
    @State private var status: String?
    private let original: ProviderProfile

    init(profile: ProviderProfile) {
        _draft = State(initialValue: profile)
        _reasoning = State(initialValue: profile.reasoningEffort ?? "")
        original = profile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Claude Code") {
                    TextField("Name", text: $draft.name)
                    Picker("Model", selection: $draft.model) {
                        ForEach(ClaudeCodeModels.choices, id: \.alias) { Text($0.name).tag($0.alias) }
                        if !ClaudeCodeModels.choices.contains(where: { $0.alias == draft.model }) {
                            Text(draft.model).tag(draft.model)
                        }
                    }
                    TextField("Or a model name Claude Code knows", text: $draft.model)
                        .font(Theme.mono(11))
                    let rules = ModelRequestRules.for(draft, model: draft.model)
                    Picker("Default effort", selection: $reasoning) {
                        Text("Claude Code's default").tag("")
                        ForEach(rules.thinkingLevels, id: \.self) { level in
                            Text("\(rules.label(level)) — \(level.blurb)").tag(level.rawValue)
                        }
                    }
                    Text(model.transport.claudeCode.status?.summary ?? "Not checked yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Check") { Task { await check() } }
                Button("Claude Code Card…") {
                    dismiss()
                    model.showClaudeCodeGuide(closing: true)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.model.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
    }

    private func check() async {
        status = "Checking…"
        status = await model.transport.claudeCode.refresh().summary
    }

    private func save() {
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.model = profile.model.trimmingCharacters(in: .whitespaces)
        profile.baseURL = ProviderProfile.claudeCodeBaseURL
        profile.reasoningEffort = reasoning.isEmpty ? nil : reasoning
        if profile.routeID != original.routeID, let clash = model.config.providers.first(where: { $0.routeID == profile.routeID }) {
            status = "“\(clash.name)” already uses \(clash.model)."
            return
        }
        model.config.replace(original, with: profile)
        model.transport.resetRouteCache()
        dismiss()
    }
}
