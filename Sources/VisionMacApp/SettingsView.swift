import SwiftUI
import AppKit
import VisionHarnessCore

/// Settings: model routes, permissions, editor and terminal, and the plugin
/// catalog. The wizard is the guided path; this is the direct one.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ProviderSettings()
                .tabItem { Label("AI Models", systemImage: "cpu") }
                .tag(SettingsTab.models)
            SwapperSettings()
                .tabItem { Label("Model Servers", systemImage: "server.rack") }
                .tag(SettingsTab.spark)
            GuardianSettings()
                .tabItem { Label("Guardian", systemImage: "shield.lefthalf.filled") }
                .tag(SettingsTab.guardian)
            SkillsManagerView()
                .tabItem { Label("Skills", systemImage: "graduationcap") }
                .tag(SettingsTab.skills)
            ComputerSettings()
                .tabItem { Label("Computer", systemImage: "cursorarrow.click.2") }
                .tag(SettingsTab.computer)
            MCPSettings()
                .tabItem { Label("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.mcp)
            ImportExportSettings()
                .tabItem { Label("Import & Export", systemImage: "arrow.left.arrow.right.square") }
                .tag(SettingsTab.importExport)
            PluginSettings()
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.plugins)
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "text.cursor") }
                .tag(SettingsTab.editor)
        }
        .frame(width: 860, height: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Permissions for new chats") {
                ForEach(PermissionPreset.allCases, id: \.self) { preset in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            model.config.preset = preset.rawValue
                        } label: {
                            Image(systemName: model.config.asPreset == preset
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.config.asPreset == preset ? preset.tint : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.label)
                            Text(preset.detail)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Setup") {
                LabeledContent("Configuration wizard") {
                    Button("Run Again…") { model.showWizard = true }
                }
                LabeledContent("Project") {
                    HStack {
                        Text(model.project?.path ?? "none open")
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        Button("Change…") { model.chooseProject() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Provider editor

struct ProviderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderProfile
    @State private var apiKey: String = ""
    @State private var status: String?
    @State private var models: [String] = []
    @State private var headerRows: [HeaderRow] = []
    @State private var reasoning: String = ""
    @State private var detected: String?
    /// A certificate the server presented that this Mac doesn't trust (offered for pinning).
    @State private var untrusted: String?
    /// Z.ai: the endpoint the key worked on instead, after Test.
    @State private var betterEndpoint: ZAIErrors.Endpoint?
    /// Bumped by Forget, so the learned line redraws.
    @State private var forgotten = 0
    private let original: ProviderProfile

    init(profile: ProviderProfile) {
        _draft = State(initialValue: profile)
        original = profile
        _headerRows = State(initialValue:
            (profile.customHeaders ?? [:]).map { HeaderRow(key: $0.key, value: $0.value) })
        _reasoning = State(initialValue: profile.reasoningEffort ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("API") {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(draft.kind == .bedrock ? [ProviderProfile.Kind.bedrock]
                                    : ProviderProfile.Kind.manual + (draft.kind == .anthropic ? [.anthropic] : []), id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .disabled(draft.kind == .bedrock)
                    TextField("Name", text: $draft.name)
                    TextField("Base URL", text: $draft.baseURL)
                        .font(Theme.mono(11))
                        .disabled(draft.kind == .bedrock)
                    if let endpoint = ZAIErrors.Endpoint.of(baseURL: draft.baseURL) {
                        Picker("Z.ai endpoint", selection: Binding(get: { endpoint }, set: {
                            draft.baseURL = $0.baseURL
                            betterEndpoint = nil
                        })) {
                            ForEach(ZAIErrors.Endpoint.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        Text("A GLM Coding Plan key works only on Coding Plan; a key made at open.bigmodel.cn only on the China endpoints. Test says which one fits.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.kind == .bedrock {
                        Text("Bedrock's endpoint for the Region. To change the Region, model or AWS sign-in, use Change… on the Models page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.needsAPIKey {
                        SecureField("API key", text: $apiKey)
                        Text("Stored locally and only used to make API requests from this app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if draft.kind != .bedrock, draft.pinnedCertificate != nil || untrusted != nil {
                    certificateSection
                }
                Section("Model") {
                    TextField("Model", text: $draft.model)
                        .font(Theme.mono(11))
                    if !models.isEmpty {
                        Picker("Discovered", selection: $draft.model) {
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    LabeledContent("Temperature") {
                        TextField("default", value: $draft.temperature, format: .number)
                            .frame(width: 80)
                    }
                    LabeledContent("Max output tokens") {
                        TextField("default", value: $draft.maxOutputTokens, format: .number)
                            .frame(width: 100)
                    }
                    LabeledContent("Context window") {
                        HStack {
                            TextField("auto", value: $draft.contextWindow, format: .number)
                                .frame(width: 100)
                            Button("Detect") { Task { await detect() } }
                        }
                    }
                    Text(detected ?? "Leave blank to auto-detect from the server (vLLM/SGLang report max_model_len). Only set it to force a smaller window.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let rules = ModelRequestRules.for(draft, model: draft.model)
                    if rules.thinkingLevels.isEmpty {
                        LabeledContent("Default thinking") {
                            Text(rules.alwaysThinks ? "Always on — this model takes no setting" : "None — this model has no thinking setting")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Default thinking", selection: $reasoning) {
                            Text("Server default").tag("")
                            ForEach(rules.thinkingLevels, id: \.self) { level in
                                Text("\(rules.label(level)) — \(level.blurb)").tag(level.rawValue)
                            }
                        }
                    }
                    Text("Only the levels this model takes. Each chat can override it from the composer or with /think.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    learnedRow
                    Toggle("Interactive use only (plan terms)", isOn: Binding(
                        get: { draft.interactiveOnly ?? false },
                        set: { draft.interactiveOnly = $0 ? true : nil }))
                    Text("Some plans (Alibaba's Qwen Coding Plan) allow only interactive use: the task queue, /goal and other unattended work won't run on this route while it's the primary.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Custom Headers") {
                    ForEach($headerRows) { $row in
                        HStack(spacing: 8) {
                            TextField("name", text: $row.key)
                                .font(Theme.mono(11))
                            TextField("value", text: $row.value)
                                .font(Theme.mono(11))
                        }
                    }
                    .onDelete { headerRows.remove(atOffsets: $0) }
                    Button("Add Header") { headerRows.append(HeaderRow()) }
                    if !headerRows.isEmpty {
                        Text("Extra HTTP headers sent with every request.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Discover Models") { Task { await discover() } }
                Button("Test") { Task { await test() } }
                    .help("Send the model a one-word message with these settings")
                if let better = betterEndpoint {
                    Button("Switch to \(better.name)") {
                        draft.baseURL = better.baseURL
                        betterEndpoint = nil
                        status = "Switched to \(better.name) — Save to keep it."
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480)
        .onAppear { apiKey = model.config.apiKey(for: original) }
    }

    /// The self-signed certificate this route trusts, with a way to forget it — or, when the server showed one
    /// this Mac doesn't trust, the fingerprint and a way to trust it.
    @ViewBuilder
    private var certificateSection: some View {
        Section("Security certificate") {
            if let pin = draft.pinnedCertificate {
                LabeledContent("Trusted (SHA-256)") {
                    HStack(alignment: .top) {
                        Text(pin).font(Theme.mono(10)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Forget") { draft.pinnedCertificate = nil }
                    }
                }
                Text("The server uses its own (self-signed) certificate, trusted by this fingerprint. Forget it to trust only certificates your Mac trusts.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let fingerprint = untrusted {
                Text("The server showed a certificate your Mac doesn't trust. Trust it only if this fingerprint matches the server's own:")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Text(fingerprint).font(Theme.mono(10)).textSelection(.enabled)
                Button("Trust This Certificate") {
                    draft.pinnedCertificate = fingerprint
                    untrusted = nil
                    status = nil
                }
            }
        }
    }

    private func discover() async {
        status = "Connecting…"
        untrusted = nil
        var probe = draft
        probe.apiKey = apiKey.isEmpty ? nil : apiKey
        do {
            models = try await ProviderClients.make(probe).listModels().sorted()
            status = "Found \(models.count) model(s)"
            if draft.model.isEmpty, let first = models.first { draft.model = first }
        } catch {
            models = []
            status = AppTransport.describe(error)
            if case LLMError.rejected(OpenAIClient.untrustedCertificateStatus, _, _, _) = error,
               let url = URL(string: probe.endpoint(path: "models")) {
                untrusted = await CertificatePin.probe(url)
            }
        }
    }

    /// What servers refused before for this route's model, with a way to start over.
    @ViewBuilder
    private var learnedRow: some View {
        let key = RequestAdaptationStore.key(baseURL: draft.baseURL, model: draft.model)
        if forgotten >= 0, let learned = RequestAdaptationStore.shared.adaptation(for: key), !learned.isEmpty {
            LabeledContent("Learned from the server") {
                HStack(alignment: .top) {
                    Text(learned.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Forget") {
                        RequestAdaptationStore.shared.forget(prefix: key)
                        forgotten += 1
                    }
                }
            }
        }
    }

    /// A one-word message with the draft's settings; for Z.ai, which endpoint the key fits when it doesn't.
    private func test() async {
        status = "Testing…"
        betterEndpoint = nil
        var probe = draft
        probe.apiKey = apiKey.isEmpty ? nil : apiKey
        if let result = await ZAIDiagnosis.test(probe) {
            status = result.message
            betterEndpoint = result.worksOn
            return
        }
        do {
            try await ZAIDiagnosis.ping(probe)
            status = "✔ \(probe.model) answered."
        } catch {
            status = PlanCatalog.explainChatError(error, route: probe) ?? AppTransport.describe(error)
        }
    }

    private func detect() async {
        detected = "Asking the server…"
        var probe = draft
        probe.apiKey = apiKey.isEmpty ? nil : apiKey
        let info = await ProviderClients.make(probe).modelInfo(nil)
        if let limit = info?.contextWindow {
            let follow = (info?.id).flatMap { $0 != draft.model ? " (serving `\($0)`)" : nil } ?? ""
            detected = "Detected \(limit.formatted()) tokens\(follow). Leave the field blank to always use the live value."
        } else if let served = info?.servedModels, !served.isEmpty {
            detected = "The server answered but reports no window for \(draft.model); set one here."
        } else {
            detected = "Could not reach the server to detect the window."
        }
    }

    private func save() {
        var profile = draft
        profile.apiKey = nil
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.model = profile.model.trimmingCharacters(in: .whitespaces)
        profile.baseURL = profile.baseURL.trimmingCharacters(in: .whitespaces)
        let config = model.config

        if profile.name.isEmpty || profile.model.isEmpty || profile.baseURL.isEmpty {
            status = "A name, a base URL and a model are required."
            return
        }
        guard let url = URL(string: profile.baseURL), ["http", "https"].contains(url.scheme?.lowercased()) else {
            status = "The base URL must start with http:// or https://."
            return
        }
        // A route is identified by its name and model: two Sparks both called "DGX Spark" serving
        // the same model would silently become one. Say so instead of overwriting the other.
        let existed = config.providers.contains { $0.routeID == original.routeID }
        if profile.routeID != original.routeID || !existed,
           let clash = config.providers.first(where: { $0.routeID == profile.routeID }) {
            status = "“\(clash.name)” already serves \(clash.model). Give this route a different name (for example “Spark 2”)."
            return
        }
        let headers = headerRows
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .reduce(into: [String: String]()) { $0[$1.key] = $1.value }
        profile.customHeaders = headers.isEmpty ? nil : headers
        profile.reasoningEffort = reasoning.isEmpty ? nil : reasoning
        // A new address may change what "private" means for this route (see `AppConfig.privacy(after:was:)`).
        profile.isPrivate = AppConfig.privacy(after: profile, was: original)

        // A new route becomes the main model; editing an existing one leaves it what it was — the
        // main model, a spare, or a subagent server — in its place in the list.
        if existed {
            config.replace(original, with: profile)
            if profile.routeID != original.routeID { config.setAPIKey("", for: original) }
        } else {
            config.activate(profile)
        }
        config.setAPIKey(apiKey, for: profile)
        model.transport.resetRouteCache()
        dismiss()
    }
}

/// One editable custom HTTP header.
private struct HeaderRow: Identifiable {
    var id = UUID()
    var key: String
    var value: String
    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

// MARK: - Plugins

private struct PluginSettings: View {
    @Environment(AppModel.self) private var model

    private var transport: AppTransport { model.transport }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Loaded") {
                    if transport.plugins.isEmpty {
                        Text("No plugins loaded.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(transport.plugins) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundStyle(.tint)
                                Text(plugin.name).font(.callout.weight(.medium))
                                if let version = plugin.version {
                                    Text("v\(version)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(plugin.tools.count) tool(s)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let description = plugin.description {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(plugin.tools, id: \.name) { tool in
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    Text(tool.name).font(Theme.mono(10))
                                    Text(tool.description)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 6)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                if !transport.pluginErrors.isEmpty {
                    Section("Could not load") {
                        ForEach(transport.pluginErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(Theme.errorTint)
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("A plugin is a JSON manifest declaring tools backed by shell commands. Drop one in either folder and reload.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Plugins Folder") {
                        try? FileManager.default.createDirectory(at: PluginLoader.userDirectory,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.open(PluginLoader.userDirectory)
                    }
                    Button("Add Example") {
                        _ = try? PluginLoader.installExample()
                        transport.refreshProjectContext()
                    }
                    Spacer()
                    Button("Reload") { transport.refreshProjectContext() }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Editor

private struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var config = model.config
        Form {
            Section("Editor") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $config.editorFontSize, in: 9...24, step: 1)
                        Text("\(Int(config.editorFontSize))pt")
                            .font(Theme.metaFont).monospacedDigit().frame(width: 34)
                    }
                }
                Toggle("Wrap long lines", isOn: $config.editorWraps)
                Toggle("Show line numbers", isOn: $config.editorLineNumbers)
            }
            Section("Terminal") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $config.terminalFontSize, in: 9...24, step: 1)
                        Text("\(Int(config.terminalFontSize))pt")
                            .font(Theme.metaFont).monospacedDigit().frame(width: 34)
                    }
                }
                LabeledContent("Shell") {
                    TextField(PTY.defaultShell, text: $config.terminalShell)
                        .font(Theme.mono(11))
                }
                Text("Leave the shell blank to use your login shell (\(PTY.defaultShell)). New terminals pick this up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
