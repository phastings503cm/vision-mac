import SwiftUI
import VisionHarnessCore

// MARK: - Settings ▸ MCP Servers

struct MCPSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: MCPEditRequest?
    @State private var importing = false
    @State private var removing: MCPServerConfig?

    var body: some View {
        let transport = model.transport
        let _ = transport.mcpRevision   // redraw when a server connects, fails or lists new tools
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP servers give the agent more tools — GitHub, a database, your docs, a browser. Each server's "
                         + "tools are offered as mcp__<server>__<tool>, and every call asks you first unless you trust "
                         + "that server. Keys and tokens go to your Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Import…") { importing = true }
                    .help("Bring in the servers Claude Code, Claude Desktop or Cursor already have")
                Button("Add Server…") { editing = MCPEditRequest(server: nil) }
                    .buttonStyle(.borderedProminent)
            }
            if transport.mcpServers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No MCP servers yet").font(.headline)
                    Text("Add one, or import the servers you already set up for Claude Code, Claude Desktop or Cursor.")
                        .foregroundStyle(.secondary)
                    Button("Import…") { importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(transport.mcpServers) { server in
                        MCPServerRow(server: server, state: transport.mcpState(server.id),
                                     onEdit: { editing = MCPEditRequest(server: server) },
                                     onRemove: { removing = server })
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .sheet(item: $editing) { request in
            MCPServerEditor(server: request.server).environment(model)
        }
        .sheet(isPresented: $importing) {
            MCPImportSheet().environment(model)
        }
        .alert("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { transport.removeMCPServer(removing.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its tools leave every chat, and its keys are removed from your Keychain.")
        }
    }
}

struct MCPEditRequest: Identifiable {
    let id = UUID()
    var server: MCPServerConfig?
}

private struct MCPServerRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPServerConfig
    let state: MCPManager.ServerState?
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var showTools = false

    var body: some View {
        let transport = model.transport
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { server.enabled }, set: { transport.setMCPServerEnabled(server.id, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.name).font(.system(size: 13, weight: .semibold))
                        if let source = server.source {
                            Text(source).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.surfaceStrong, in: Capsule())
                        }
                    }
                    Text(server.summary).font(Theme.mono(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                statusView
                Menu {
                    Button("Edit…", action: onEdit)
                    Button("Reconnect") { transport.reconnectMCPServer(server.id) }.disabled(!server.enabled)
                    Divider()
                    Button("Remove…", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack(spacing: 12) {
                Picker("Calls", selection: Binding(get: { server.trust }, set: { transport.setMCPServerTrust(server.id, $0) })) {
                    ForEach(MCPServerConfig.Trust.allCases, id: \.self) { trust in Text(trust.label).tag(trust) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                if let tools = state?.tools, !tools.isEmpty {
                    Button(showTools ? "Hide tools" : "\(tools.count) tool\(tools.count == 1 ? "" : "s")") { showTools.toggle() }
                        .buttonStyle(.plain).font(Theme.metaFont).foregroundStyle(.tint)
                }
            }
            .padding(.leading, 44)
            if let note = server.note {
                Text(note).font(.caption).foregroundStyle(Theme.noticeTint).padding(.leading, 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showTools, let tools = state?.tools {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tools, id: \.name) { tool in
                        Toggle(isOn: Binding(get: { !server.disabledTools.contains(tool.name) },
                                             set: { transport.setMCPTool(tool.name, enabled: $0, server: server.id) })) {
                            HStack(spacing: 6) {
                                Text(tool.name).font(Theme.mono(11))
                                if tool.readOnly { Text("read-only").font(.caption2).foregroundStyle(.secondary) }
                                if tool.destructive { Text("destructive").font(.caption2).foregroundStyle(Theme.errorTint) }
                                Text(tool.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusView: some View {
        let status = server.enabled ? (state?.status ?? .off) : .off
        HStack(spacing: 5) {
            switch status {
            case .ready:
                Circle().fill(Theme.successTint).frame(width: 7, height: 7)
                Text("Connected").font(Theme.metaFont)
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting…").font(Theme.metaFont)
            case .failed(let why):
                Circle().fill(Theme.errorTint).frame(width: 7, height: 7)
                Text("Failed").font(Theme.metaFont).foregroundStyle(Theme.errorTint).help(why)
            case .off:
                Circle().strokeBorder(.tertiary).frame(width: 7, height: 7)
                Text("Off").font(Theme.metaFont).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help({ if case .failed(let why) = status { return why } else { return status.label } }())
    }
}

// MARK: - Adding or editing a server

private struct MCPServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: MCPServerConfig?

    @State private var draft = MCPServerConfig(name: "", transport: .stdio)
    @State private var argumentsText = ""
    @State private var environment: [KeyValue] = []
    @State private var headers: [KeyValue] = []
    @State private var loaded = false

    struct KeyValue: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(server == nil ? "Add an MCP Server" : "Edit “\(server!.name)”").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $draft.name, prompt: Text("github"))
                Picker("Runs as", selection: $draft.transport) {
                    ForEach(MCPServerConfig.Transport.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if draft.transport == .stdio {
                    TextField("Program", text: Binding(get: { draft.command ?? "" }, set: { draft.command = $0 }),
                              prompt: Text("npx"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments — one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $argumentsText)
                            .font(Theme.mono(11.5))
                            .frame(height: 70)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
                    }
                    TextField("Starts in (optional)", text: Binding(get: { draft.cwd ?? "" },
                                                                    set: { draft.cwd = $0.isEmpty ? nil : $0 }),
                              prompt: Text("your home folder"))
                    pairs("Environment variables", $environment, placeholder: "GITHUB_TOKEN")
                } else {
                    TextField("Address", text: Binding(get: { draft.url ?? "" }, set: { draft.url = $0 }),
                              prompt: Text("https://example.com/mcp"))
                    pairs("HTTP headers", $headers, placeholder: "Authorization")
                }
                Picker("Tool calls", selection: $draft.trust) {
                    ForEach(MCPServerConfig.Trust.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            if let problem = currentDraft.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.noticeTint)
            }
            HStack {
                Text("Values go to your Keychain, never into the settings file. ${NAME} is filled in from your environment.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(currentDraft.problem != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear(perform: load)
    }

    private func pairs(_ title: String, _ items: Binding<[KeyValue]>, placeholder: String) -> some View {
        Section(title) {
            ForEach(items) { $item in
                HStack {
                    TextField("Name", text: $item.key, prompt: Text(placeholder)).font(Theme.mono(11.5))
                    SecureField("Value", text: $item.value).font(Theme.mono(11.5))
                    Button { items.wrappedValue.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
            }
            Button("Add") { items.wrappedValue.append(KeyValue(key: "", value: "")) }
        }
    }

    private var currentDraft: MCPServerConfig {
        var config = draft
        config.args = argumentsText.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return config
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let server else { return }
        draft = server
        argumentsText = server.args.joined(separator: "\n")
        environment = model.transport.mcpEnvironment(server).sorted { $0.key < $1.key }.map { KeyValue(key: $0.key, value: $0.value) }
        headers = model.transport.mcpHeaders(server).sorted { $0.key < $1.key }.map { KeyValue(key: $0.key, value: $0.value) }
    }

    private func save() {
        var config = currentDraft
        config.name = MCPNames.sanitize(config.name)
        let env = draft.transport == .stdio ? Dictionary(environment.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
                                                          uniquingKeysWith: { _, last in last }) : [:]
        let head = draft.transport == .http ? Dictionary(headers.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) },
                                                          uniquingKeysWith: { _, last in last }) : [:]
        model.transport.saveMCPServer(config, environment: env, headers: head)
        dismiss()
    }
}

// MARK: - Importing from Claude Code, Claude Desktop and Cursor

private struct MCPImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MCPImportCandidate] = []
    @State private var chosen: Set<String> = []
    @State private var done: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import MCP Servers").font(.title3.weight(.semibold))
            Text("The servers Claude Code (~/.claude.json and this project's .mcp.json), Claude Desktop and Cursor "
                 + "(~/.cursor/mcp.json) have configured. Nothing is started until you import; their keys go to your "
                 + "Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text("None found — Claude Code, Claude Desktop and Cursor have no MCP servers set up on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(groups, id: \.0) { source, items in
                        Section(source) {
                            ForEach(items) { candidate in row(candidate) }
                        }
                    }
                }
                .frame(minHeight: 280)
            }
            if let done { Text(done).font(.callout).foregroundStyle(Theme.successTint) }
            HStack {
                Spacer()
                Button(done == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen.count)") { importChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear(perform: reload)
    }

    private var groups: [(String, [MCPImportCandidate])] {
        var order: [String] = []
        var map: [String: [MCPImportCandidate]] = [:]
        for candidate in candidates {
            let source = candidate.config.source ?? "Other"
            if map[source] == nil { order.append(source) }
            map[source, default: []].append(candidate)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private func row(_ candidate: MCPImportCandidate) -> some View {
        let known = MCPImport.isKnown(candidate, among: model.transport.mcpServers)
        return Toggle(isOn: Binding(get: { chosen.contains(candidate.id) },
                                    set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.config.name).font(.system(size: 12.5, weight: .medium))
                    Text(candidate.config.transport == .stdio ? "program" : "URL").font(.caption2).foregroundStyle(.secondary)
                    if known { Text("already in Vision").font(.caption2).foregroundStyle(.secondary) }
                    let secrets = candidate.environment.count + candidate.headers.count
                    if secrets > 0 { Text("\(secrets) value\(secrets == 1 ? "" : "s") → Keychain").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(candidate.config.summary).font(Theme.mono(10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let caveat = candidate.caveat {
                    Text(caveat).font(.caption).foregroundStyle(Theme.noticeTint).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(known)
    }

    private func reload() {
        candidates = model.transport.discoverMCPImports()
        // Preselect each server once (the same one in two apps is offered twice) and none Vision already has.
        var seen = Set<String>()
        chosen = []
        for candidate in candidates where !MCPImport.isKnown(candidate, among: model.transport.mcpServers) {
            if seen.insert(candidate.fingerprint).inserted { chosen.insert(candidate.id) }
        }
    }

    private func importChosen() {
        let picked = candidates.filter { chosen.contains($0.id) }
        let added = model.transport.importMCP(picked)
        done = added.isEmpty ? "Nothing new to import." : "Imported \(added.map(\.name).joined(separator: ", ")) — connecting now."
        chosen = []
    }
}
