import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - Settings ▸ Import & Export (OpenClaw on this Mac)
//
// Import: find OpenClaw (~/.openclaw, a profile folder, or a folder the person picks), preview what it holds with
// counts, tick what to bring, choose what happens on a clash, and bring it in. Export: Vision's skills, memory and —
// only after an explicit confirmation — vault secrets, into that OpenClaw. Secret values are never shown: names,
// a short hint and where each was found.

struct ImportExportSettings: View {
    @Environment(AppModel.self) private var model

    /// Snapshot mode opens the tab with the preview already read.
    static var previewOnAppear = false

    @State private var installs: [OpenClawInstall] = []
    @State private var chosen: OpenClawInstall?
    @State private var bundle: OpenClawBundle?
    @State private var selection = OpenClawSelection()
    @State private var reading = false
    @State private var working = false
    @State private var importResult: OpenClawImportResult?
    @State private var addedRoutes: [String] = []
    /// Which lists are open (snapshot mode opens the keys, to show that values never appear).
    @State private var expanded: Set<String> = []

    @State private var exportSkills = true
    @State private var exportMemory = true
    @State private var exportVault = false
    @State private var exportConflict: OpenClawConflict = .skip
    @State private var confirmVault = false
    @State private var exportResult: OpenClawExportResult?
    @State private var showChatImport = false

    private var home: URL { model.transport.skillLocations.home }

    var body: some View {
        Form {
            chatsSection
            sourceSection
            if let bundle {
                previewSections(bundle)
            }
            exportSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChatImport) {
            ChatImportSheet(model: ChatImportModel(transport: model.transport, guardian: model.guardian))
        }
        .onAppear {
            if installs.isEmpty { look() }
            if Self.previewOnAppear, bundle == nil, chosen != nil {
                expanded = ["keys"]
                preview()
            }
        }
        .alert("Export keys and passwords to OpenClaw?", isPresented: $confirmVault) {
            Button("Export \(vaultNames.count) Keys and Passwords", role: .destructive) { runExport(withVault: true) }
            Button("Export Without Them") { runExport(withVault: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are written in plain text to \(envPath), readable by your user account — OpenClaw and every skill it runs can read them. \(AppIdentity.name) never shows or logs the values.")
        }
    }

    // MARK: Chats

    private var chatsSection: some View {
        Section {
            HStack {
                Button("Import Chats…") { showChatImport = true }
                Spacer()
                Menu("Export This Chat") {
                    Button("Markdown…") { ChatExportActions.save(.markdown, sessionID: model.transport.selectedID, transport: model.transport) }
                    Button("JSON…") { ChatExportActions.save(.json, sessionID: model.transport.selectedID, transport: model.transport) }
                }
                .fixedSize()
                .disabled(model.transport.selectedID == nil)
                Button("Send to Guardian") {
                    ChatExportActions.sendToGuardian(sessionID: model.transport.selectedID, transport: model.transport,
                                                     guardian: model.guardian)
                }
                .disabled(model.transport.selectedID == nil || !model.guardian.isSignedIn)
            }
        } header: {
            Text("Chats")
        } footer: {
            Text("Import brings Claude Code, Codex and OpenClaw sessions on this Mac, Claude.ai and ChatGPT data exports, Vision chat files and your Guardian chats in as chats you can carry on with any model. Export works on the chat that is open: Markdown to read anywhere, JSON to import into Vision on another computer, or Guardian to keep it with your account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Where OpenClaw is

    private var sourceSection: some View {
        Section {
            if installs.isEmpty {
                Text("No OpenClaw found in your home folder (~/.openclaw or a profile like ~/.openclaw-work). If it lives somewhere else, choose its folder.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("OpenClaw", selection: Binding(get: { chosen }, set: { chosen = $0; bundle = nil; importResult = nil; exportResult = nil })) {
                    ForEach(installs, id: \.self) { install in
                        Text(install.title + (install.configPath == nil ? " (no config file)" : "")).tag(Optional(install))
                    }
                }
            }
            HStack {
                Button("Choose Folder…") { chooseFolder() }
                Button("Look Again") { look() }
                Spacer()
                if reading { ProgressView().controlSize(.small) }
                Button(bundle == nil ? "Preview Import…" : "Read Again") { preview() }
                    .disabled(chosen == nil || reading)
            }
        } header: {
            Text("OpenClaw on this Mac")
        } footer: {
            Text("Nothing in OpenClaw is changed by reading it, and nothing is run. Import brings skills, memory, keys and passwords, and model servers into \(AppIdentity.name); export sends your skills, memory and (if you confirm) keys back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: The preview

    @ViewBuilder
    private func previewSections(_ bundle: OpenClawBundle) -> some View {
        Section {
            Text(counts(bundle)).font(.callout.weight(.medium))
            if !bundle.problems.isEmpty {
                ForEach(bundle.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Import from OpenClaw")
        }

        if !bundle.skills.isEmpty {
            Section {
                DisclosureGroup("Skills — \(selection.skills.count) of \(bundle.skills.count) ticked", isExpanded: isOpen("skills")) {
                    allOrNone(all: { selection.skills = Set(bundle.skills.filter { !$0.shadowed }.map(\.directory.path)) },
                              none: { selection.skills = [] })
                    ForEach(bundle.skills) { skill in
                        Toggle(isOn: binding(skill.directory.path, in: \.skills)) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(skill.name)
                                    tag(skill.location)
                                    if skill.hasScripts { tag("scripts") }
                                    if skill.shadowed { tag("hidden by another of this name") }
                                }
                                if !skill.description.isEmpty {
                                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                Picker("If Vision already has a skill of that name", selection: $selection.skillConflict) {
                    ForEach(OpenClawConflict.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Hold the skills for my approval (Settings ▸ Skills)", isOn: $selection.skillsAsDrafts)
                Text("Scripts in a skill are copied, never run. Credential files and files with a key inside are left out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        if !bundle.noteFiles.isEmpty {
            Section {
                DisclosureGroup("Memory — \(selection.noteFiles.count) of \(bundle.noteFiles.count) files ticked", isExpanded: isOpen("memory")) {
                    allOrNone(all: { selection.noteFiles = Set(bundle.noteFiles.map(\.path.path)) }, none: { selection.noteFiles = [] })
                    ForEach(bundle.noteFiles) { file in
                        Toggle(isOn: binding(file.path.path, in: \.noteFiles)) {
                            HStack(spacing: 6) {
                                Text(file.name)
                                tag(file.kind.label)
                                Text("\(file.lineCount) lines").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("MEMORY.md and USER.md go into your ~/MEMORY.md, daily logs into ~/memory, personality and rules into ~/\(AppIdentity.projectInstructionsFileName) — each as its own marked block, so importing again updates it instead of adding a copy.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !bundle.credentials.isEmpty {
            Section {
                DisclosureGroup("Keys and passwords — \(selection.credentials.count) of \(bundle.credentials.count) ticked", isExpanded: isOpen("keys")) {
                    allOrNone(all: { selection.credentials = Dictionary(uniqueKeysWithValues: bundle.credentials.map { ($0.name, .ask) }) },
                              none: { selection.credentials = [:] })
                    ForEach(bundle.credentials) { credential in
                        HStack(alignment: .top) {
                            Toggle(isOn: Binding(
                                get: { selection.credentials[credential.name] != nil },
                                set: { selection.credentials[credential.name] = $0 ? .ask : nil })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(credential.name).font(Theme.mono(11))
                                    Text("\(credential.kind.label) · \(credential.secret.hint) · \(credential.origin)"
                                         + (credential.alsoNamed.isEmpty ? "" : " · also \(credential.alsoNamed.joined(separator: ", "))"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let access = selection.credentials[credential.name] {
                                Picker("", selection: Binding(get: { access }, set: { selection.credentials[credential.name] = $0 })) {
                                    ForEach(VaultEntry.AgentAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }
                        }
                    }
                }
                Picker("If the vault already has that name", selection: $selection.credentialConflict) {
                    ForEach(OpenClawConflict.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Values go straight into the Credentials Vault (the Keychain); they are never shown or logged. “Ask first” means a chat asks you before its first use.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !bundle.modelServers.isEmpty {
            Section {
                DisclosureGroup("Model servers — \(selection.modelServers.count) of \(bundle.modelServers.count) ticked", isExpanded: isOpen("servers")) {
                    ForEach(bundle.modelServers) { server in
                        Toggle(isOn: binding(server.id, in: \.modelServers)) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(server.id)
                                    if let model = server.defaultModel ?? server.models.first { tag(model) }
                                    if server.apiKey != nil { tag("key") }
                                }
                                Text(server.baseURL + (server.note.map { " — " + $0 } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .disabled(!server.compatible)
                    }
                }
            }
        }

        if !bundle.left.isEmpty {
            Section("Not brought over") {
                ForEach(bundle.left, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        Section {
            HStack {
                if let importResult {
                    Label("Brought in \(importResult.summary).", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Import Selected") { runImport(bundle) }
                    .disabled(working || nothingSelected)
            }
            if let importResult { resultDetails(importResult) }
        }
    }

    @ViewBuilder
    private func resultDetails(_ result: OpenClawImportResult) -> some View {
        let skipped = result.skillsSkipped.map { "Skill \($0.key): \($0.value)" }.sorted()
            + result.credentialsSkipped.map { "\($0.key): \($0.value)" }.sorted()
        if !addedRoutes.isEmpty {
            Text("Added model routes: \(addedRoutes.joined(separator: ", ")) — pick one under AI Models.").font(.caption)
        }
        if result.notesUnchanged > 0 {
            Text("\(result.notesUnchanged) memory file\(result.notesUnchanged == 1 ? " was" : "s were") already up to date.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array((skipped + result.problems).prefix(30)), id: \.self) { line in
            Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Export

    private var userSkills: [Skill] {
        _ = model.transport.skillsRevision
        return SkillCatalog.loadAll(project: nil, locations: model.transport.skillLocations)
            .filter { $0.origin == .vision && $0.scope == .user && !$0.shadowed }
    }

    private var dailyLogCount: Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("memory").path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".md") }.count
    }

    private var vaultNames: [String] {
        _ = model.transport.vaultRevision
        // Guardian's "Usable in Vision" secrets are held for this run only (memory, never disk): they never go out.
        let vault = model.transport.vault
        return vault.all.filter { !vault.isSessionOnly($0) }.map(\.name)
    }

    private var envPath: String {
        ((chosen?.stateDir.appendingPathComponent(".env").path ?? "~/.openclaw/.env") as NSString).abbreviatingWithTildeInPath
    }

    private var exportSection: some View {
        Section {
            Toggle("Skills — your \(userSkills.count) skill\(userSkills.count == 1 ? "" : "s"), into OpenClaw's skills folder", isOn: $exportSkills)
            Toggle("Memory — ~/MEMORY.md and \(dailyLogCount) daily log\(dailyLogCount == 1 ? "" : "s"), into its workspace", isOn: $exportMemory)
            Toggle("Keys and passwords — the \(vaultNames.count) in the vault, into OpenClaw's .env (asks first)", isOn: $exportVault)
                .disabled(vaultNames.isEmpty)
            Picker("If OpenClaw already has it", selection: $exportConflict) {
                ForEach(OpenClawConflict.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            HStack {
                if let exportResult {
                    Label("Sent \(exportResult.summary).", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Export to OpenClaw…") {
                    if exportVault, !vaultNames.isEmpty { confirmVault = true } else { runExport(withVault: false) }
                }
                .disabled(chosen == nil || working || !(exportSkills || exportMemory || exportVault))
            }
            if let exportResult {
                let lines = exportResult.skillsSkipped.map { "Skill \($0.key): \($0.value)" }.sorted()
                    + exportResult.secretsSkipped.map { "\($0.key): \($0.value)" }.sorted() + exportResult.problems
                ForEach(Array(lines.prefix(30)), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Export to OpenClaw")
        } footer: {
            Text("Memory goes in as a marked “From Vision” block, so exporting again updates it; what \(AppIdentity.name) brought in from OpenClaw isn't sent back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) }, set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }

    private var nothingSelected: Bool {
        selection.skills.isEmpty && selection.noteFiles.isEmpty && selection.credentials.isEmpty && selection.modelServers.isEmpty
    }

    private func counts(_ bundle: OpenClawBundle) -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        return [n(bundle.skills.count, "skill", "skills"), n(bundle.noteFiles.count, "memory file", "memory files"),
                n(bundle.credentials.count, "key or password", "keys and passwords"),
                n(bundle.modelServers.filter(\.compatible).count, "model server", "model servers")]
            .joined(separator: " · ") + " found in \(bundle.install.title)"
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func allOrNone(all: @escaping () -> Void, none: @escaping () -> Void) -> some View {
        HStack {
            Button("Tick All", action: all).buttonStyle(.link)
            Button("Untick All", action: none).buttonStyle(.link)
            Spacer()
        }
        .font(.caption)
    }

    private func binding(_ key: String, in path: WritableKeyPath<OpenClawSelection, Set<String>>) -> Binding<Bool> {
        Binding(get: { selection[keyPath: path].contains(key) },
                set: { on in
                    if on { selection[keyPath: path].insert(key) } else { selection[keyPath: path].remove(key) }
                })
    }

    // MARK: Actions

    private func look() {
        installs = OpenClawScanner.find(home: home)
        if chosen == nil || !installs.contains(where: { $0 == chosen }) { chosen = installs.first }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose OpenClaw's state folder (the one holding openclaw.json), or a workspace."
        panel.directoryURL = home
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let install = OpenClawScanner.inspect(url, foundBy: "chosen") else {
            model.transport.note("That folder doesn't look like OpenClaw: no openclaw.json, and no agents/, workspace/ or skills/ with memory.")
            return
        }
        if !installs.contains(install) { installs.append(install) }
        chosen = install
        bundle = nil
    }

    private func preview() {
        guard let install = chosen else { return }
        reading = true
        importResult = nil
        let home = self.home
        Task {
            let read = await Task.detached(priority: .userInitiated) { OpenClawReader.read(install, home: home) }.value
            bundle = read
            selection = .suggested(read)
            reading = false
        }
    }

    private func runImport(_ bundle: OpenClawBundle) {
        working = true
        let selection = self.selection
        let transport = model.transport
        let vault = transport.vault, locations = transport.skillLocations, home = self.home
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                OpenClawImporter.apply(bundle, selection: selection, vault: vault, locations: locations, home: home)
            }.value
            addedRoutes = addRoutes(result.modelServers)
            transport.vaultDidChange()
            transport.refreshDrafts()
            transport.refreshProjectContext()
            importResult = result
            working = false
        }
    }

    /// The chosen model servers become routes (OpenAI-compatible), keys in the Keychain.
    private func addRoutes(_ servers: [OpenClawModelServer]) -> [String] {
        var added: [String] = []
        for server in servers {
            let route = ProviderProfile(kind: .openAICompat, name: "OpenClaw \(server.id)", baseURL: server.baseURL,
                                        model: server.defaultModel ?? server.models.first ?? "", contextWindow: server.contextWindow)
            let saved = model.config.saveGuided(route, key: server.apiKey?.reveal() ?? "", privacyChosen: false,
                                                isSame: { $0.baseURL == route.baseURL })
            added.append(saved.route.name)
        }
        return added
    }

    private func runExport(withVault: Bool) {
        guard let install = chosen else { return }
        working = true
        var selection = OpenClawExportSelection()
        let skills = exportSkills ? userSkills : []
        selection.skills = Set(skills.map(\.id))
        selection.memory = exportMemory
        if withVault, exportVault {
            selection.vault = Set(vaultNames)
            selection.vaultConfirmed = true
        }
        selection.conflict = exportConflict
        let chosenSelection = selection
        let vault = model.transport.vault, home = self.home
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                OpenClawExporter.export(chosenSelection, to: install, home: home, skills: skills, vault: vault)
            }.value
            exportResult = result
            working = false
        }
    }
}
