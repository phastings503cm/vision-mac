import SwiftUI
import AppKit
import VisionHarnessCore

/// Settings ▸ Guardian: sign in with the guardian.503cm.com login — in the browser (Entra SSO, passwordless) or
/// with email, password and 2FA — pick the organization, see the limits, and the syncs that follow: prompts
/// (automatic on submit), skills both ways, chats exported and picked back, the vault's "Usable in Vision"
/// secrets, code projects.
struct GuardianSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GuardianSettingsForm(guardian: model.guardian)
    }
}

struct GuardianSettingsForm: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var guardian: GuardianService

    @State private var address = GuardianService.defaultURL
    @State private var email = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var signingIn = false
    @State private var status: String?
    @State private var isSyncingSkills = false
    @State private var isExporting = false
    @State private var showChatImport = false
    @State private var showPassword = false

    var body: some View {
        Form {
            accountSection
            if guardian.isSignedIn {
                limitsSection
                vaultSection
                notebookSection
            }

            Section("Skills") {
                HStack {
                    Button {
                        isSyncingSkills = true
                        Task {
                            await syncSkillsDown()
                            isSyncingSkills = false
                        }
                    } label: {
                        if isSyncingSkills { ProgressView().controlSize(.small) } else { Text("Import skills from Guardian") }
                    }
                    .disabled(!guardian.isSignedIn || isSyncingSkills)
                    Button("Deposit this project's skills") {
                        Task { await depositSkills() }
                    }
                    .disabled(!guardian.isSignedIn)
                }
                Text("A skill imported here is a copy; depositing publishes the project's .vision/skills to the account, where any Vision harness can take it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Chats") {
                HStack {
                    Button {
                        isExporting = true
                        Task { await exportChats() }
                    } label: {
                        if isExporting { ProgressView().controlSize(.small) } else { Text("Export all chats to Guardian") }
                    }
                    .disabled(!guardian.isSignedIn || isExporting)
                    Button("Import chats from Guardian…") { showChatImport = true }
                        .disabled(!guardian.isSignedIn)
                }
                Text("Exported chats appear in Guardian under your account. Import brings back those and your Guardian chats, as chats you can carry on here with any model.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            projectsSection

            if let status {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChatImport) {
            ChatImportSheet(model: ChatImportModel(transport: model.transport, guardian: guardian), focus: .guardian)
        }
        .guardianProblemAlert(guardian)
        .task {
            if guardian.isSignedIn, guardian.account == nil { await guardian.refreshAccount() }
        }
    }

    // MARK: Prompt notebook

    /// Guardian's prompt notebook: on by default; what goes up is masked (the same words as Windows).
    @ViewBuilder
    private var notebookSection: some View {
        @Bindable var config = model.config
        Section("Prompt notebook") {
            Text("Every prompt you send in a chat goes to your Guardian notebook, with how the turn ended — completed, needs you, failed or stopped.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Before a prompt goes up, the keys and passwords in your vault are masked, and — with the sensitive-data shield on (Settings ▸ AI Models ▸ Sensitive data) — whatever it masks for models that aren't private.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Send my prompts to the notebook", isOn: $config.guardianPromptSync)
        }
    }

    // MARK: Account

    /// Signed in, and no model route uses this Guardian.
    private var hasNoModelRoute: Bool {
        _ = model.config.providers.count
        return guardian.modelRoutes.isEmpty
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if guardian.isSignedIn {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.successTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in as \(guardian.account?.name.map { "\($0) (\(guardian.accountEmail ?? ""))" } ?? guardian.accountEmail ?? "")")
                        Text(model.config.guardianPromptSync
                             ? "Prompts you send in chats go to your Guardian notebook automatically, with how each turn ended."
                             : "Your prompts stay on this Mac (Prompt notebook below).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await guardian.refreshAccount() } }
                    Button("Sign Out", role: .destructive) { guardian.signOut() }
                }
                if let account = guardian.account, !account.orgs.isEmpty {
                    Picker("Organization", selection: Binding(
                        get: { guardian.orgID ?? account.activeOrg?.id ?? "" },
                        set: { guardian.setOrg($0 == account.activeOrg?.id && guardian.orgID == nil ? nil : $0) })) {
                        ForEach(account.orgs) { org in
                            Text(org.name + (org.active == true ? " (default)" : "")).tag(org.id)
                        }
                    }
                    Text("Vision works in this organization: its models, its limits, your access there. "
                         + (account.modules.isEmpty ? "" : "Modules you have: \(account.modules.joined(separator: ", "))."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Signed in here (the browser path, or after the wizard's route was deleted) with no Guardian model
                // route: one click adds it, on this sign-in's token.
                if hasNoModelRoute {
                    HStack {
                        Text("Guardian's models aren't in your model list yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Guardian's Models") { Task { status = await guardian.addModelRoute() } }
                    }
                }
                if let error = guardian.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } else if guardian.pendingTwoFactorChallenge != nil {
                // A sign-in is waiting on the authenticator code.
                TextField("Email", text: $email)
                    .autocorrectionDisabled()
                HStack {
                    TextField("6-digit code", text: $twoFactorCode)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await submitTwoFactor() } }
                    Button {
                        Task { await submitTwoFactor() }
                    } label: {
                        if signingIn { ProgressView().controlSize(.small) } else { Text("Verify") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(signingIn || twoFactorCode.count != 6)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Enter the 6-digit code from your authenticator app. Codes rotate every 30 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Start over") {
                    guardian.cancelTwoFactor()
                    twoFactorCode = ""
                    status = nil
                }
                .font(.caption)
            } else {
                TextField("Guardian address", text: $address)
                    .autocorrectionDisabled()
                HStack {
                    if guardian.browserSignInRunning {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in the browser window that opened…").font(.callout)
                        Spacer()
                        Button("Cancel") { guardian.cancelBrowserSignIn() }
                    } else {
                        Button {
                            status = nil
                            guardian.startBrowserSignIn(address: address)
                        } label: {
                            Label("Sign In with Guardian in the Browser", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
                Text("For Microsoft (Entra) sign-in and passwordless accounts: Guardian opens in your browser, you pick the organization there, and it hands this Mac a revocable token. Nothing is typed into \(AppIdentity.name).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = guardian.lastError, !guardian.browserSignInRunning {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Or sign in with your email and password", isExpanded: $showPassword) {
                    TextField("Email", text: $email)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    HStack {
                        Button {
                            signingIn = true
                            status = nil
                            Task {
                                let ok = await guardian.signIn(address: address, email: email, password: password)
                                signingIn = false
                                status = ok ? "Signed in." : (guardian.pendingTwoFactorChallenge != nil ? nil : (guardian.lastError ?? "Sign-in failed."))
                                if ok || guardian.pendingTwoFactorChallenge != nil { password = "" }
                            }
                        } label: {
                            if signingIn { ProgressView().controlSize(.small) } else { Text("Sign In") }
                        }
                        .disabled(signingIn || email.isEmpty || password.isEmpty)
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Your password is exchanged for a session token and never stored — the token lives in your Keychain. Accounts with two-factor sign-in are asked for the code next.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Limits

    private var limitsSection: some View {
        Section("Limits") {
            if guardian.limits.isEmpty {
                Text("No spend or token limits are set for your account in this organization.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(guardian.limits, id: \.self) { limit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(limit.title)
                            Spacer()
                            Text(limit.usage ?? "—").foregroundStyle(.secondary)
                        }
                        if let fraction = limit.fraction {
                            ProgressView(value: fraction)
                                .tint(fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .accentColor)
                        }
                        if let reset = limit.resetPhrase() {
                            Text(reset.prefix(1).uppercased() + reset.dropFirst()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("Set by your Guardian organization. When one runs out, chats stop with a message saying which limit and when it resets.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Vault

    private var vaultSection: some View {
        Section("Guardian vault") {
            if guardian.remoteSecrets.isEmpty {
                HStack {
                    Text("Secrets you mark “Usable in Vision” in Guardian can be used here, one at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show My Secrets") { Task { await guardian.loadSecrets() } }
                }
            } else {
                ForEach(guardian.remoteSecrets) { secret in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(secret.name)
                            Text("{{vault:\(GuardianService.vaultName(secret))}}" + (secret.description.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if guardian.secretsInUse.contains(secret.id) {
                            Button("Stop Using") { guardian.stopUsingSecret(secret) }
                        } else {
                            Button("Use in Vision") { Task { await guardian.useSecret(secret) } }
                        }
                    }
                }
            }
            Text("Using a secret fetches its value from Guardian (which records each hand-out) and keeps it in memory for this run only — never on disk. Chats ask before their first use.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Projects

    private var projectsSection: some View {
        Section("Code projects") {
            HStack {
                Button("Upload the open project to Guardian") {
                    Task { await uploadProject() }
                }
                .disabled(!guardian.isSignedIn || model.project == nil)
                Button("Show My Projects") { Task { await guardian.loadProjects() } }
                    .disabled(!guardian.isSignedIn)
            }
            ForEach(guardian.remoteProjects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                        Text([project.fileCount.map { "\($0) files" }, project.updatedAt.map { "updated \($0.formatted(date: .abbreviated, time: .shortened))" },
                              project.aiCoders == true ? "in AI Coders" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download a Copy…") { Task { await download(project) } }
                }
            }
            Text("The project's text files go to your account's private repo store, from where the AI Coders module can be pointed at it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func download(_ project: GuardianProject) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Choose where to put a copy of \(project.name)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if let root = await guardian.downloadProject(project, into: folder) {
            status = "Downloaded \(project.name) to \((root.path as NSString).abbreviatingWithTildeInPath)."
        }
    }

    // MARK: Actions

    /// The second half of a 2FA sign-in: verify the authenticator code.
    private func submitTwoFactor() async {
        guard !twoFactorCode.isEmpty else { return }
        signingIn = true
        status = nil
        let ok = await guardian.verifyTwoFactor(code: twoFactorCode)
        signingIn = false
        if ok {
            twoFactorCode = ""
            status = "Signed in."
        } else {
            status = guardian.lastError ?? "That code didn't take — codes rotate every 30 seconds."
        }
    }

    private func syncSkillsDown() async {
        guard let client = guardian.client else { return }
        do {
            let remote = try await client.skills()
            let locations = model.transport.skillLocations
            var imported = 0
            for skill in remote where !skill.name.isEmpty {
                let folder = locations.userSkills.appendingPathComponent(skill.name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (path, text) in skill.files {
                    let file = folder.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
                imported += 1
            }
            model.transport.refreshDrafts()
            status = "Imported \(imported) skill\(imported == 1 ? "" : "s") from Guardian."
        } catch {
            status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func depositSkills() async {
        guard let client = guardian.client, let project = model.project else { return }
        let folder = AppPaths.projectFolder(project, "skills")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            status = "This project has no .vision/skills to deposit."
            return
        }
        var deposited = 0
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let skillID = entry.lastPathComponent
            var files: [String: String] = [:]
            if let enumerator = fileManager.enumerator(at: entry, includingPropertiesForKeys: nil) {
                while let next = enumerator.nextObject() {
                    guard let file = next as? URL,
                          let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    files[String(file.path.dropFirst(entry.path.count + 1))] = text
                }
            }
            let description = (try? String(contentsOf: entry.appendingPathComponent("SKILL.md"), encoding: .utf8))?
                .split(separator: "\n").filter { $0.contains("description:") }.first.map { String($0) } ?? skillID
            do {
                try await client.putSkill(name: skillID, description: description, files: files)
                deposited += 1
            } catch {
                status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
                return
            }
        }
        status = "Deposited \(deposited) skill\(deposited == 1 ? "" : "s") to Guardian."
    }

    private func exportChats() async {
        status = await guardian.sendAllChats(from: model.transport)
        isExporting = false
    }

    private func uploadProject() async {
        guard let client = guardian.client, let project = model.project else { return }
        status = "Reading the project's files…"
        // Never the files that hold keys or passwords (.env, *.pem, id_rsa …), build output or dependencies.
        let manifest = await Task.detached(priority: .userInitiated) { GuardianProjects.collect(project) }.value
        guard !manifest.files.isEmpty else {
            status = "That folder has no text files to upload."
            return
        }
        do {
            try await client.putProject(name: project.lastPathComponent, files: manifest.files)
            status = manifest.summary(project: project.lastPathComponent)
        } catch {
            status = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - The dialog for Guardian's refusals

extension View {
    /// Show Guardian's structured refusals (a missing module or permission, a spent budget) as a dialog naming what
    /// is missing and who can grant it, or which limit and when it resets.
    func guardianProblemAlert(_ guardian: GuardianService) -> some View {
        modifier(GuardianProblemAlert(guardian: guardian))
    }
}

private struct GuardianProblemAlert: ViewModifier {
    @ObservedObject var guardian: GuardianService

    func body(content: Content) -> some View {
        content.alert(guardian.problem?.title ?? "Guardian", isPresented: Binding(
            get: { guardian.problem != nil }, set: { if !$0 { guardian.problem = nil } })) {
            Button("OK") { guardian.problem = nil }
        } message: {
            Text(guardian.problem?.detail() ?? "")
        }
    }
}

