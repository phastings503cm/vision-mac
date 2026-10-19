import SwiftUI
import AppKit
import VisionHarnessCore

/// First-run configuration, re-runnable from Settings or the Help menu.
///
/// The job is narrow: find a model server, prove we can reach it, and pin a
/// permission preset. Everything else in the app assumes those three are done.
struct SetupWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    @State private var kind: ProviderProfile.Kind = .openAICompat
    @State private var host = ""
    @State private var port = ""
    @State private var apiKey = ""
    /// Guardian sign-in (kind == .guardian): exchanged for a session token
    /// during the connection test, stored in the Keychain as the route's key.
    @State private var guardianEmail = ""
    @State private var guardianPassword = ""
    /// Shown when the account answers the password with a 2FA challenge: the
    /// challenge is held here while the user types the authenticator code.
    @State private var guardianChallenge: String?
    @State private var guardianTwoFactorCode = ""
    @State private var modelID = ""
    @State private var discovered: [String] = []
    @State private var probe: ProbeState = .idle
    @State private var preset: PermissionPreset = .workspaceWrite
    /// Context window choice: nil = auto-detect from the server.
    @State private var contextChoice: Int? = nil
    @State private var customContext: String = ""
    @State private var detectedContext: Int? = nil
    @State private var detectedModel: String? = nil
    @State private var detecting = false
    /// Default thinking level ("" = server default).
    @State private var thinkingChoice: String = ""
    /// The profile being edited when the wizard is re-run, so fields the
    /// wizard doesn't show (headers, temperature, …) survive.
    @State private var existing: ProviderProfile? = nil

    enum Step: Int, CaseIterable {
        case welcome, backend, connection, models, tuning, permissions, project, done

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .backend: "Backend"
            case .connection: "Connection"
            case .models: "Model"
            case .tuning: "Context & thinking"
            case .permissions: "Permissions"
            case .project: "Project"
            case .done: "Ready"
            }
        }
    }

    enum ProbeState: Equatable {
        case idle, running, ok(Int), failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            progressHeader
            Divider()
            ScrollView {
                content
                    .padding(28)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 580)
        .onAppear(perform: seedFromConfig)
    }

    // MARK: Header

    /// Seven labels do not fit across a sheet, so the steps are a segmented
    /// bar and only the current one is named.
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                ForEach(Step.allCases, id: \.rawValue) { entry in
                    Capsule()
                        .fill(entry.rawValue <= step.rawValue ? Color.accentColor : Theme.hairline)
                        .frame(height: 3)
                }
            }
            HStack {
                Text(step.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .backend: backendStep
        case .connection: connectionStep
        case .models: modelStep
        case .tuning: tuningStep
        case .permissions: permissionStep
        case .project: projectStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Set up Vision")
                .font(.largeTitle.weight(.semibold))
            Text("""
            This app is the agent harness — it runs the tool loop itself and talks straight to a \
            model server. Nothing else has to be installed or kept running.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                bullet("server.rack", "Point it at a model",
                       "A DGX Spark or any OpenAI-compatible server on your network, a local Ollama or LM Studio, or a cloud provider.")
                bullet("wrench.and.screwdriver", "Give it tools",
                       "Read, write, edit, glob, grep, shell, and web fetch — the Qwen Code tool set, so prompts and skills written for it work here.")
                bullet("chevron.left.forwardslash.chevron.right", "Work in a project",
                       "Open a folder to get a file tree, an editor, and a terminal beside the chat.")
            }
            .padding(.top, 4)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where does the model run?").font(.title2.weight(.semibold))
            Text("You can change this later, and keep more than one configured.")
                .font(.callout).foregroundStyle(.secondary)

            // A Spark Swapper box sets itself up from one code: a guide of its own.
            guideChoice(icon: "server.rack", title: "My Spark Swapper (DGX Spark or Strix Halo)",
                        detail: "Paste the connection code from the Swapper's Connect tab. Sets up the model, switching, and the security certificate in one go.") {
                model.showSwapperGuide(closing: true)
            }
            guideChoice(icon: "sparkles", title: "Z.ai (GLM) — GLM Coding Plan or API key",
                        detail: "GLM-5.3 and the other GLM models. Pick the endpoint your key is for (Coding Plan, General API, or China); the check tells you if another one fits.") {
                model.showPlanGuide(closing: true, plan: "zai")
            }
            guideChoice(icon: "terminal", title: "Claude Code — your Claude Pro or Max plan",
                        detail: "Runs the claude command on this Mac, signed in with your own Claude plan. Vision shows its work, tools and cost, and never touches your sign-in.") {
                model.showClaudeCodeGuide(closing: true)
            }
            guideChoice(icon: "creditcard", title: "A subscription or API plan — Kimi, Qwen, OpenAI, GLM",
                        detail: "Use your Kimi, Alibaba Cloud, OpenAI or Z.ai plan. A guide shows where to get the key.") {
                model.showPlanGuide(closing: true)
            }

            ForEach(ProviderProfile.Kind.manual, id: \.self) { candidate in
                Button {
                    kind = candidate
                    applyDefaults(for: candidate)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(kind == candidate ? Color.accentColor : .secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: candidate)).font(.callout.weight(.medium))
                            Text(detail(for: candidate)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if kind == candidate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(kind == candidate ? Color.accentColor.opacity(0.10) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(kind == candidate ? Color.accentColor.opacity(0.5) : Theme.hairline)
                    )
                }
                .buttonStyle(.plain)
            }

            // Guardian: one wizard flow (sign in with the Guardian login, pick
            // a model from the account's list). Not in `manual` — it has its
            // own fields, so it gets its own choice button.
            Button {
                kind = .guardian
                applyDefaults(for: .guardian)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ProviderProfile.Kind.guardian.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(kind == .guardian ? Color.accentColor : .secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Guardian account — models, prompts and skills in one place").font(.callout.weight(.medium))
                        Text("Sign in with your guardian.503cm.com login. Your account's models are the proxy; prompts, skills, chats and code projects sync with Guardian too.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if kind == .guardian {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(kind == .guardian ? Color.accentColor.opacity(0.10) : Theme.surface,
                            in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .strokeBorder(kind == .guardian ? Color.accentColor.opacity(0.5) : Theme.hairline)
                )
            }
            .buttonStyle(.plain)

            // Bedrock has its own step-by-step guide (AWS CLI, sign-in, model, access), so it is not a
            // "kind" to fill a form for: choosing it hands over to the guide.
            Button {
                dismiss()
                Task { @MainActor in
                    // Let this sheet finish closing before the next one opens.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    model.showBedrockGuide()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ProviderProfile.Kind.bedrock.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Amazon Bedrock with my AWS account (guided)").font(.callout.weight(.medium))
                        Text("Claude, Amazon Nova, Llama and more from your own AWS account. A guide installs what's needed, signs you in and helps you pick and enable a model.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
            }
            .buttonStyle(.plain)
        }
    }

    /// A choice that hands over to a guide of its own (the wizard closes and the guide opens).
    private func guideChoice(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func label(for kind: ProviderProfile.Kind) -> String {
        switch kind {
        case .openAICompat: "DGX Spark or another server on your network"
        default: kind.label
        }
    }

    private func detail(for kind: ProviderProfile.Kind) -> String {
        switch kind {
        case .openAICompat:
            "An OpenAI-compatible endpoint — vLLM, SGLang, llama.cpp, or the serving stack on a DGX Spark. Reached over your LAN."
        case .ollama: "Models running locally through Ollama on this Mac."
        case .lmStudio: "Models running locally through LM Studio on this Mac."
        case .openAI: "OpenAI's hosted API. Needs an API key."
        case .openRouter: "Many hosted models behind one API. Needs an API key."
        case .bedrock: "Claude, Amazon Nova, Llama and more through your AWS account. Set up by its own guide."
        case .guardian: "Your Guardian account is the proxy: sign in with your guardian.503cm.com login and use the models your plan allows. Your prompts, skills, chats and code projects sync with Guardian too."
        case .claudeCode: "The claude command on this Mac, signed in with your Claude Pro or Max plan. Set up by its own card."
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection").font(.title2.weight(.semibold))
            Text(connectionHint)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Address").frame(width: 70, alignment: .trailing)
                    TextField(addressPlaceholder, text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                if usesPort {
                    GridRow {
                        Text("Port").frame(width: 70, alignment: .trailing)
                        TextField("8002", text: $port)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
                if kind == .guardian {
                    GridRow {
                        Text("Email").frame(width: 70, alignment: .trailing)
                        TextField("you@503cm.com", text: $guardianEmail)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                    }
                    GridRow {
                        Text("Password").frame(width: 70, alignment: .trailing)
                        SecureField("Your Guardian password", text: $guardianPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                    if guardianChallenge != nil {
                        GridRow {
                            Text("2FA code").frame(width: 70, alignment: .trailing)
                            TextField("6-digit code from your authenticator app", text: $guardianTwoFactorCode)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }
                    }
                    GridRow {
                        Text("").frame(width: 70)
                        HStack(spacing: 8) {
                            Button {
                                Task { await runBrowserSignIn() }
                            } label: {
                                Label("Sign in with the browser instead", systemImage: "safari")
                            }
                            .disabled(probe == .running)
                            Text("Microsoft (Entra) or passwordless accounts").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if allowsKey {
                    GridRow {
                        Text("API key").frame(width: 70, alignment: .trailing)
                        SecureField(needsKey ? "sk-…" : "optional — e.g. vllm-local", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("URL").frame(width: 70, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(baseURL)
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button("Test Connection") { Task { await runProbe() } }
                    .disabled(probe == .running || host.isEmpty)
                probeIndicator
            }
            .padding(.top, 4)

            if case .failed(let reason) = probe {
                Card(fill: Theme.errorTint.opacity(0.10)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reason).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(troubleshooting)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var connectionHint: String {
        switch kind {
        case .openAICompat:
            "Enter the address of the machine serving the model and the port its OpenAI-compatible API listens on. On a DGX Spark following the setup guide that is port 8002, and the address is the box's hostname or LAN IP."
        case .ollama:
            "Ollama serves an OpenAI-compatible API on this Mac. The defaults are usually right — start it with `ollama serve` if it is not already running."
        case .lmStudio:
            "Start LM Studio's local server (Developer ▸ Start Server) and load a model, then test the connection."
        case .openAI, .openRouter:
            "Paste an API key. It is stored in your login keychain, never in the app's preferences file."
        case .bedrock:
            "Amazon Bedrock is set up by its own guide: Settings ▸ Models ▸ Add Amazon Bedrock…"
        case .guardian:
            "Sign in with your Guardian login (the email and password you use at guardian.503cm.com). Vision exchanges it for a session token that is kept in your Keychain — the password never is."
        case .claudeCode:
            "Claude Code is set up by its own card: Settings ▸ Models ▸ Add ▸ Claude Code…"
        }
    }

    private var addressPlaceholder: String {
        switch kind {
        case .openAICompat: "spark.local or 192.168.1.50"
        case .ollama, .lmStudio: "127.0.0.1"
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .bedrock: "https://bedrock-runtime.us-east-1.amazonaws.com"
        case .guardian: "https://guardian.503cm.com"
        case .claudeCode: ProviderProfile.claudeCodeBaseURL
        }
    }

    private var usesPort: Bool {
        kind == .openAICompat || kind == .ollama || kind == .lmStudio
    }

    private var needsKey: Bool { kind == .openAI || kind == .openRouter }
    /// Your own server may sit behind a key (vLLM/SGLang `--api-key`, an nginx front).
    private var allowsKey: Bool { needsKey || kind == .openAICompat }

    /// The endpoint we will actually call.
    private var baseURL: String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            // A full URL: keep its scheme and path; fill in the port field if the URL has none.
            var comps = URLComponents(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            let portPart = port.trimmingCharacters(in: .whitespaces)
            if comps?.port == nil, let p = Int(portPart), usesPort { comps?.port = p }
            if (comps?.path ?? "").isEmpty { comps?.path = "/v1" }
            return comps?.string ?? trimmed
        }
        let portPart = port.trimmingCharacters(in: .whitespaces)
        let hostPart = portPart.isEmpty ? trimmed : "\(trimmed):\(portPart)"
        return "http://\(hostPart)/v1"
    }

    private var troubleshooting: String {
        switch kind {
        case .openAICompat:
            "Check the server is bound to 0.0.0.0 rather than 127.0.0.1 — a server listening only on loopback is unreachable from another machine. Then confirm the port and that no firewall is in the way."
        case .ollama:
            "Run `ollama serve` in a terminal, then `ollama list` to confirm a model is installed."
        case .lmStudio:
            "In LM Studio, open the Developer tab, load a model, and press Start Server."
        case .openAI, .openRouter:
            "Check the key is current and has credit or quota on the account."
        case .bedrock:
            "Sign in to AWS again and check that your account is allowed to use the model."
        case .guardian:
            "Check your Guardian email and password, and that your plan covers the model you picked. If the sign-in has expired, sign in again."
        case .claudeCode:
            "Open the Claude Code card (Settings ▸ Models ▸ Add ▸ Claude Code…) and press Check Again: it says whether the claude command is installed and signed in."
        }
    }

    @ViewBuilder
    private var probeIndicator: some View {
        switch probe {
        case .idle: EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let count):
            Label(count == 0 ? "Reached the server" : "Reached the server — \(count) model(s)",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.successTint)
        case .failed:
            Label("Could not connect", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.errorTint)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a model").font(.title2.weight(.semibold))
            if discovered.isEmpty {
                Text("The server did not return a model list, so type the model id it expects. On a vLLM or SGLang server that is the name it was launched with.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("model id", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            } else {
                Text("These are the models \(baseURL) reports.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(discovered, id: \.self) { candidate in
                            Button {
                                modelID = candidate
                            } label: {
                                HStack {
                                    Image(systemName: modelID == candidate ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(modelID == candidate ? Color.accentColor : .secondary)
                                    Text(candidate).font(Theme.mono(12))
                                    Spacer()
                                    if isToolCapable(candidate) {
                                        Text("tools")
                                            .font(.system(size: 9, weight: .semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Theme.successTint.opacity(0.18), in: Capsule())
                                    }
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .background(modelID == candidate ? Color.accentColor.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 240)

                TextField("or type a model id", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(12))
            }

            Card {
                Label {
                    Text("An agent needs a model that can call tools. Qwen3, Qwen2.5-Coder, and DeepSeek-V3-class models work well; very small models will struggle.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    private static let contextPresets: [(String, Int)] = [
        ("32K", 32_768), ("128K", 131_072), ("256K", 262_144), ("512K", 524_288), ("1M", 1_000_000),
    ]

    private var tuningStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Context & thinking").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Context window").font(.headline)
                HStack(spacing: 8) {
                    if detecting {
                        ProgressView().controlSize(.small)
                        Text("Asking the server…").font(.caption).foregroundStyle(.secondary)
                    } else if let detectedContext {
                        Label("The server reports \(detectedContext.formatted()) tokens"
                              + (detectedModel.map { $0 != modelID ? " for \($0)" : "" } ?? ""),
                              systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.successTint)
                    } else {
                        Label("The server didn't report a window — pick one below.",
                              systemImage: "questionmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Detect again") { Task { await detectContext() } }.disabled(detecting)
                }
                Picker("Window", selection: $contextChoice) {
                    Text(detectedContext.map { "Auto (\(Self.short($0)), follows the server)" } ?? "Auto-detect").tag(Int?.none)
                    ForEach(Self.contextPresets, id: \.1) { preset in
                        Text(preset.0).tag(Int?.some(preset.1))
                    }
                    Text("Custom…").tag(Int?.some(-1))
                }
                .pickerStyle(.radioGroup)
                if contextChoice == -1 {
                    TextField("tokens, e.g. 400000", text: $customContext)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                }
                Text("Auto is best: it re-reads the window every turn, so a model swap on the server (1M ⇄ 512K) is picked up by itself. Choose a fixed size only to cap it lower. Long chats are summarized automatically at 75%, or any time with /compact.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Default thinking").font(.headline)
                Picker("Thinking", selection: $thinkingChoice) {
                    Text("Server default").tag("")
                    ForEach(ThinkingLevel.allCases, id: \.self) { level in
                        Text("\(level.label) — \(level.blurb)").tag(level.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("For reasoning models (Qwen3.x, DeepSeek, GLM, gpt-oss). Off skips thinking entirely for the fastest replies; Max thinks longest. Qwen3.8's own default is its maximum, which is slow for everyday work — Medium is a good start. Change it per chat from the composer or with /think.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if detectedContext == nil { await detectContext() } }
    }

    private static func short(_ n: Int) -> String {
        n >= 1_000_000
            ? String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : "\(n / 1024)K"
    }

    private func detectContext() async {
        detecting = true
        defer { detecting = false }
        let info = await ProviderClients.make(draftProfile).modelInfo(nil)
        detectedContext = info?.contextWindow
        detectedModel = info?.id
    }

    /// A hint, not a guarantee — the families that reliably emit tool calls.
    private func isToolCapable(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return ["qwen", "deepseek", "gpt-4", "gpt-5", "llama-3", "llama3", "mistral", "command-r"]
            .contains { lowered.contains($0) }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How much can the agent do?").font(.title2.weight(.semibold))
            Text("This is the preset new chats start with. Each chat keeps the preset it was created with.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(PermissionPreset.allCases, id: \.self) { candidate in
                Button {
                    preset = candidate
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(preset == candidate ? candidate.tint : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.label).font(.callout.weight(.medium))
                            Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if preset == candidate {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(candidate.tint)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(preset == candidate ? candidate.tint.opacity(0.10) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(preset == candidate ? candidate.tint.opacity(0.5) : Theme.hairline)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a project").font(.title2.weight(.semibold))
            Text("""
            The project folder is the agent's working directory and its permission boundary. \
            You can skip this and open one whenever you like.
            """)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let project = model.project {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.lastPathComponent).font(.callout.weight(.medium))
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Button("Change…") { model.chooseProject() }
                    }
                }
            } else {
                Button {
                    model.chooseProject()
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.successTint)
            Text("You're set up").font(.largeTitle.weight(.semibold))

            Card {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Server").foregroundStyle(.secondary)
                        Text(baseURL).font(Theme.mono(11)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(modelID.isEmpty ? "—" : modelID).font(Theme.mono(11))
                    }
                    GridRow {
                        Text("Permissions").foregroundStyle(.secondary)
                        Text(preset.label)
                    }
                    GridRow {
                        Text("Project").foregroundStyle(.secondary)
                        Text(model.project?.path ?? "none yet")
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.callout)
            }

            Text("Run this wizard again any time from Settings, or the Help menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
            }
            Spacer()
            if step == .project {
                Button("Skip") { step = .done }
            }
            Button(step == .done ? "Start Working" : "Continue") { advance() }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    private var canAdvance: Bool {
        switch step {
        case .connection: !host.trimmingCharacters(in: .whitespaces).isEmpty
        case .models: !modelID.trimmingCharacters(in: .whitespaces).isEmpty
        case .tuning: contextChoice != -1 || (Int(customContext.filter(\.isNumber)) ?? 0) > 0
        default: true
        }
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func advance() {
        switch step {
        case .connection:
            // Discover models on the way through, so the next step is useful
            // even if the user never pressed Test.
            Task {
                if case .ok = probe {} else { await runProbe() }
                step = .models
            }
        case .models:
            saveProvider()
            step = .tuning
        case .tuning:
            saveProvider()
            step = .permissions
        case .permissions:
            model.config.preset = preset.rawValue
            step = .project
        case .done:
            finish()
        default:
            step = Step(rawValue: step.rawValue + 1) ?? .done
        }
    }

    private func finish() {
        saveProvider()
        model.config.preset = preset.rawValue
        model.config.wizardCompleted = true
        if model.transport.sessions.isEmpty { model.newChat() }
        dismiss()
    }

    // MARK: Actions

    private func seedFromConfig() {
        if let active = model.config.activeProvider {
            existing = active
            kind = active.kind
            modelID = active.model
            preset = model.config.asPreset
            apiKey = active.apiKey ?? ""
            thinkingChoice = active.thinking?.rawValue ?? ""
            if let window = active.contextWindow {
                if Self.contextPresets.contains(where: { $0.1 == window }) {
                    contextChoice = window
                } else {
                    contextChoice = -1
                    customContext = String(window)
                }
            }
            let components = URLComponents(string: active.baseURL)
            if let host_ = components?.host, components?.scheme == "http",
               (components?.path ?? "") == "/v1" || (components?.path ?? "").isEmpty {
                host = host_
                port = components?.port.map(String.init) ?? ""
            } else {
                // https, or a non-default path (a proxy): keep the URL whole.
                host = active.baseURL
                port = ""
            }
        } else {
            applyDefaults(for: kind)
        }
    }

    private func applyDefaults(for kind: ProviderProfile.Kind) {
        probe = .idle
        discovered = []
        switch kind {
        case .ollama:
            host = "127.0.0.1"; port = "11434"; modelID = "qwen3:8b"
        case .lmStudio:
            host = "127.0.0.1"; port = "1234"; modelID = ""
        case .openAICompat:
            host = ""; port = "8002"; modelID = ""
        case .openAI:
            host = "https://api.openai.com/v1"; port = ""; modelID = "gpt-4o"
        case .openRouter:
            host = "https://openrouter.ai/api/v1"; port = ""; modelID = "qwen/qwen3-32b"
        case .bedrock:
            host = "https://bedrock-runtime.us-east-1.amazonaws.com"; port = ""; modelID = ""
        case .guardian:
            host = "https://guardian.503cm.com"; port = ""; modelID = ""
        case .claudeCode:
            host = ProviderProfile.claudeCodeBaseURL; port = ""; modelID = "sonnet"
        }
    }

    private var draftProfile: ProviderProfile {
        // Re-running the wizard edits the existing route in place, so settings
        // it doesn't show (headers, temperature, max tokens) are kept.
        var p = (existing?.kind == kind ? existing : nil)
            ?? ProviderProfile(kind: kind,
                               name: kind == .openAICompat ? "DGX Spark / server" : kind.label,
                               baseURL: baseURL, model: modelID)
        p.baseURL = baseURL
        p.apiKey = apiKey.isEmpty ? nil : apiKey
        p.model = modelID.isEmpty ? (detectedModel ?? "model") : modelID
        switch contextChoice {
        case .none: p.contextWindow = nil
        case .some(-1): p.contextWindow = Int(customContext.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
        case .some(let n): p.contextWindow = n
        }
        p.reasoningEffort = thinkingChoice.isEmpty ? nil : thinkingChoice
        return p
    }

    private func runProbe() async {
        probe = .running
        // Guardian: the connection test is the sign-in. The password is
        // exchanged for a session token once; afterwards the route talks to
        // the model proxy with the token, like any OpenAI-compatible server.
        // A TOTP account answers with a challenge instead — the code field
        // appears and the next Test finishes the sign-in with it.
        if kind == .guardian {
            do {
                let guardian = try GuardianClient(baseURL: host.isEmpty ? "https://guardian.503cm.com" : host)
                let session: GuardianSession
                if let challenge = guardianChallenge {
                    session = try await guardian.verifyTwoFactor(challenge: challenge, code: guardianTwoFactorCode)
                } else {
                    do {
                        session = try await guardian.signIn(email: guardianEmail, password: guardianPassword)
                    } catch GuardianError.twoFactorRequired(let challenge) {
                        guardianChallenge = challenge
                        guardianTwoFactorCode = ""
                        probe = .failed("2FA is on for this account — enter the 6-digit code from your authenticator app, then Test again.")
                        return
                    }
                }
                guardianChallenge = nil
                let models = try await guardian.models().map(\.id)
                discovered = models.sorted()
                apiKey = session.token          // saved to the Keychain by saveProvider()
                probe = .ok(models.count)
                if modelID.isEmpty, let first = models.first { modelID = first }
                // One sign-in serves both: the model route and the Guardian connection (prompts, limits, vault).
                model.guardian.adopt(session, address: guardian.baseURL.absoluteString)
            } catch {
                discovered = []
                probe = .failed(AppTransport.describe(error))
            }
            return
        }
        let client = ProviderClients.make(draftProfile)
        do {
            let models = try await client.listModels()
            discovered = models.sorted()
            probe = .ok(models.count)
            if modelID.isEmpty, let first = models.first { modelID = first }
        } catch {
            discovered = []
            probe = .failed(AppTransport.describe(error))
        }
    }

    /// Guardian through the browser (Entra SSO, passwordless): the consent page, a loopback redirect, PKCE.
    private func runBrowserSignIn() async {
        probe = .running
        do {
            let guardian = try GuardianClient(baseURL: host.isEmpty ? GuardianService.defaultURL : host)
            let device = Host.current().localizedName ?? "Mac"
            let (session, org) = try await guardian.signInWithBrowser(device: "\(AppIdentity.name) on \(device)") { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            guardianChallenge = nil
            let models = try await guardian.models().map(\.id)
            discovered = models.sorted()
            apiKey = session.token
            probe = .ok(models.count)
            if modelID.isEmpty, let first = models.first { modelID = first }
            model.guardian.adopt(session, address: guardian.baseURL.absoluteString, orgID: org)
        } catch {
            discovered = []
            probe = .failed((error as? LocalizedError)?.errorDescription ?? AppTransport.describe(error))
        }
    }

    private func saveProvider() {
        var profile = draftProfile
        let key = apiKey
        profile.apiKey = nil                      // the key lives in the keychain
        if let existing {
            profile.isPrivate = AppConfig.privacy(after: profile, was: existing)
            // In place: a renamed route keeps its position (and nothing else is handed the lead meanwhile).
            model.config.replace(existing, with: profile)
        }
        model.config.activate(profile)
        existing = profile
        if !key.isEmpty { model.config.setAPIKey(key, for: profile) }
        model.transport.resetRouteCache()
    }
}
