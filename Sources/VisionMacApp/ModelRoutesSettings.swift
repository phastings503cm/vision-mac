import SwiftUI
import VisionHarnessCore

/// Settings › AI Models: the roster. Every route — your own boxes, subscription plans, Amazon Bedrock, any
/// OpenAI-compatible server — with a switch to turn it on or off, its role (the *primary* you talk to, which hands
/// out side tasks; *subagent* servers that take them in parallel; *backups* that take over when the primary stops
/// answering) and whether it is *private* (may see sensitive data) or gets sensitive details masked.
struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ProviderProfile?
    /// The screenshot mode opens a route's editor this way.
    static var editOnAppear: ProviderProfile?
    @State private var removing: ProviderProfile?
    @State private var status: StatusLine?
    /// The last test's answer for each route, shown on its row.
    @State private var results: [String: StatusLine] = [:]

    private var config: AppConfig { model.config }

    struct StatusLine: Equatable {
        enum Tone { case neutral, success, failure }
        var text: String
        var tone: Tone = .neutral
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ProviderRoutesList(results: results,
                                   edit: { editing = $0 },
                                   remove: { removing = $0 },
                                   report: { status = $0 })
                    .padding(20)
            }
            Divider()
            footer
        }
        .onAppear {
            if let route = Self.editOnAppear {
                Self.editOnAppear = nil
                editing = route
            }
        }
        .sheet(item: Binding(get: { editing.map(EditableProvider.init) },
                             set: { editing = $0?.profile })) { wrapper in
            ProviderEditor(profile: wrapper.profile)
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "this route")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its saved API key is removed too.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Spark Swapper (connection code)…") { model.showSwapperGuide() }
                Button("Z.ai (GLM)…") { model.showPlanGuide(plan: "zai") }
                Button("DeepSeek…") { model.showPlanGuide(plan: "deepseek") }
                Button("Anthropic API (key)…") { model.showPlanGuide(plan: "anthropic") }
                Button("Subscription plan…") { model.showPlanGuide() }
                Button("Amazon Bedrock…") { model.showBedrockGuide() }
                Button("Other OpenAI-compatible server…") {
                    editing = ProviderProfile(kind: .openAICompat, name: "New server",
                                              baseURL: "http://127.0.0.1:8002/v1", model: "")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            Button("Test Primary") { Task { await testMain() } }
                .disabled(config.activeProvider == nil)
            Button("Test All") { Task { await testAll() } }
                .disabled(config.providers.isEmpty)
                .help("Ask every route whether it answers, and show the result on each row")
            if let status {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(color(for: status.tone))
                    .lineLimit(2).truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Wizard…") { model.showWizard = true }
        }
        .padding(10)
    }

    private func color(for tone: StatusLine.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .success: Theme.successTint
        case .failure: Theme.errorTint
        }
    }

    // MARK: Actions

    private func remove(_ provider: ProviderProfile) {
        config.removeProvider(provider)
        config.setAPIKey("", for: provider)
        model.transport.resetRouteCache()
    }

    private func testMain() async {
        guard let provider = config.activeProvider else {
            status = StatusLine(text: "No primary model.", tone: .failure)
            return
        }
        status = StatusLine(text: "Testing \(AppTransport.routeLabel(provider))…")
        let line = await Self.check(provider)
        results[provider.routeID] = line
        status = line
    }

    /// Ask every route at once; each row shows its own answer, so a Spark that is asleep is obvious.
    private func testAll() async {
        results = [:]
        let routes = config.providers.map { route -> ProviderProfile in
            var probe = route
            let key = config.apiKey(for: route)
            probe.apiKey = key.isEmpty ? nil : key
            return probe
        }
        status = StatusLine(text: "Testing \(routes.count) routes…")
        await withTaskGroup(of: (String, StatusLine).self) { group in
            for route in routes {
                group.addTask { (route.routeID, await Self.check(route)) }
            }
            for await (id, line) in group { results[id] = line }
        }
        let failed = results.values.filter { $0.tone == .failure }.count
        status = failed == 0
            ? StatusLine(text: "✔ All \(results.count) routes answered.", tone: .success)
            : StatusLine(text: "\(failed) of \(results.count) routes did not answer.", tone: .failure)
    }

    /// Does the route answer, and what does it serve?
    private static func check(_ provider: ProviderProfile) async -> StatusLine {
        // Z.ai: only a real reply proves the key fits the endpoint — and a failure says which endpoint it fits.
        if let result = await ZAIDiagnosis.test(provider) {
            return StatusLine(text: result.message, tone: result.ok ? .success : .failure)
        }
        let client = ProviderClients.make(provider)
        do {
            let models = try await client.listModels()
            let info = await client.modelInfo(nil)
            let window = info?.contextWindow.map { ", \($0.formatted())-token window" } ?? ""
            if provider.kind == .bedrock {
                return StatusLine(text: "✔ Connected to Amazon Bedrock — \(models.count) model(s) in \(provider.awsRegion ?? "the Region")\(window).", tone: .success)
            }
            return StatusLine(text: "✔ Connected — \(models.count) model(s) served\(window).", tone: .success)
        } catch {
            return StatusLine(text: AppTransport.describe(error), tone: .failure)
        }
    }
}

/// `sheet(item:)` needs Identifiable; `ProviderProfile` deliberately is not.
struct EditableProvider: Identifiable {
    let profile: ProviderProfile
    var id: String { profile.routeID }
    init(_ profile: ProviderProfile) { self.profile = profile }
}

// MARK: - The roster

/// Column widths, shared by the header and the rows.
private enum RosterColumn {
    static let on: CGFloat = 40
    static let role: CGFloat = 62
    static let privacy: CGFloat = 70
    static let status: CGFloat = 14
    static let actions: CGFloat = 96
}

/// The intro, the fleet card, the table of routes, and what the roles mean: everything that scrolls on the page.
struct ProviderRoutesList: View {
    @Environment(AppModel.self) private var model
    var results: [String: ProviderSettings.StatusLine] = [:]
    let edit: (ProviderProfile) -> Void
    let remove: (ProviderProfile) -> Void
    let report: (ProviderSettings.StatusLine) -> Void

    var body: some View {
        let config = model.config
        VStack(alignment: .leading, spacing: 14) {
            Text("Add as many models as you like — your own boxes, subscription plans, Amazon Bedrock, any OpenAI-compatible server — and decide what each one does.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FleetCard()
            if config.providers.isEmpty {
                Text("No models yet. Use Add below, or run the setup wizard.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            } else {
                VStack(spacing: 6) {
                    header
                    ForEach(config.providers, id: \.routeID) { provider in
                        RouteRow(provider: provider,
                                 result: results[provider.routeID],
                                 edit: { edit(provider) },
                                 remove: { remove(provider) },
                                 report: report)
                    }
                }
            }
            Text("Primary answers you. Subagents take side tasks in parallel. Backups take over if the primary stops answering. Private models may see sensitive data; the others get it masked.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SensitiveDataSection()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("On").frame(width: RosterColumn.on)
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Primary").frame(width: RosterColumn.role)
            Text("Subagent").frame(width: RosterColumn.role)
            Text("Backup").frame(width: RosterColumn.role)
            Text("Private").frame(width: RosterColumn.privacy)
            Color.clear.frame(width: RosterColumn.status + RosterColumn.actions, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }
}

// MARK: - The fleet at a glance

/// Who leads and who helps, drawn as a line of chips, with the one switch that applies to the whole
/// fleet. Hidden with a single route (there is nothing to arrange).
struct FleetCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        if let main = config.mainRoute, config.providers.count > 1 {
            let workers = model.transport.workerRoutes
            let backups = config.backupRoutes
            VStack(alignment: .leading, spacing: 10) {
                if workers.isEmpty {
                    Label("Several models? Put them all to work", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.semibold))
                    Text("\(AppTransport.routeLabel(main)) is the primary. Tick “Subagent” for another model — a second DGX Spark, or Amazon Bedrock — and the primary hands side tasks to it, so they run in parallel instead of queueing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("\(AppTransport.routeLabel(main)) leads · subagents run on \(workers.count == 1 ? "1 other model" : "\(workers.count) other models")",
                          systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.callout.weight(.semibold))
                    HStack(alignment: .center, spacing: 8) {
                        chip(AppTransport.routeLabel(main), systemImage: "crown.fill", filled: true)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        ForEach(workers, id: \.routeID) { worker in
                            chip("\(AppTransport.routeLabel(worker)) · \(worker.subagentParallel ?? 2) at a time",
                                 systemImage: "gearshape.2", filled: false)
                        }
                    }
                    Toggle("When those are all busy, let subagents use the primary too",
                           isOn: Binding(get: { config.subagentsUsePrimary },
                                         set: { config.subagentsUsePrimary = $0 }))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    if workers.contains(where: { $0.kind == .bedrock }) {
                        Label("Subagent tasks sent to Amazon Bedrock are billed to your AWS account.", systemImage: "creditcard")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !backups.isEmpty {
                    Label("If \(AppTransport.routeLabel(main)) stops answering: " + backups.map(AppTransport.routeLabel).joined(separator: ", then "),
                          systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        }
    }

    private func chip(_ text: String, systemImage: String, filled: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(filled ? Color.accentColor.opacity(0.18) : Theme.surfaceStrong, in: Capsule())
            .lineLimit(1)
    }
}

// MARK: - One route

struct RouteRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderProfile
    var result: ProviderSettings.StatusLine?
    let edit: () -> Void
    let remove: () -> Void
    let report: (ProviderSettings.StatusLine) -> Void
    @State private var primaryCantBeOff = false

    private var config: AppConfig { model.config }
    private var isMain: Bool { config.activeRoute == provider.routeID }
    /// Effective worker: flagged, not the main model, and not the same machine as one already counted.
    private var isEffectiveWorker: Bool { model.transport.workerRoutes.contains { $0.routeID == provider.routeID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Toggle("On", isOn: Binding(get: { provider.isEnabled }, set: { setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(width: RosterColumn.on)
                    .help(provider.isEnabled ? "On — Vision may use this model" : "Off — never used; kept in the list")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: provider.kind.icon)
                            .foregroundStyle(isMain ? Color.accentColor : .secondary)
                        Text(provider.name).font(.callout.weight(.semibold)).lineLimit(1)
                        if isMain { badge("Primary", filled: true) }
                        if provider.isInteractiveOnly { badge("Interactive only", filled: false) }
                    }
                    ForEach(detailLines, id: \.self) { line in
                        Text(line)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { makeMain() } label: {
                    Image(systemName: isMain ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isMain ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: RosterColumn.role)
                .help(isMain ? "The primary: it answers you" : "Make this the primary. The current one keeps helping as a subagent when a fleet is running.")

                Toggle("Subagent", isOn: Binding(get: { provider.isSubagentWorker },
                                                 set: { config.setSubagentWorker(provider.routeID, $0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(isMain)
                    .frame(width: RosterColumn.role)
                    .help(isMain ? "Takes effect when another model is the primary." : "Take side tasks from the primary, in parallel.")

                Toggle("Backup", isOn: Binding(get: { provider.isBackup },
                                               set: { config.setBackup(provider.routeID, $0); model.transport.resetRouteCache() }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(isMain)
                    .frame(width: RosterColumn.role)
                    .help(isMain ? "Takes effect when another model is the primary." : "Use if the primary fails: a turn the primary can't answer runs here.")

                HStack(spacing: 4) {
                    Image(systemName: provider.isPrivateRoute ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                        .foregroundStyle(provider.isPrivateRoute ? Theme.successTint : .secondary)
                    Toggle("Private", isOn: Binding(get: { provider.isPrivateRoute },
                                                    set: { config.setPrivate(provider.routeID, $0); model.transport.resetRouteCache() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                .frame(width: RosterColumn.privacy)
                .help(provider.isPrivateRoute ? "Private: may see sensitive data (your own hardware)." : "Not private: sensitive details are masked before they're sent.")

                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .frame(width: RosterColumn.status)
                    .help(result?.text ?? "Not tested yet — Test All asks every model")

                HStack(spacing: 6) {
                    Button("Edit…", action: edit).controlSize(.small)
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .controlSize(.small)
                        .help("Remove this model")
                }
                .frame(width: RosterColumn.actions, alignment: .trailing)
            }
            if let result, result.tone == .failure {
                Text(result.text)
                    .font(.caption)
                    .foregroundStyle(Theme.errorTint)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, RosterColumn.on + 10)
            }
            extras.padding(.leading, RosterColumn.on + 10)
        }
        .padding(10)
        .opacity(provider.isEnabled ? 1 : 0.5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(isMain ? Color.accentColor.opacity(0.6) : Theme.hairline)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .alert("\(provider.name) is the primary", isPresented: $primaryCantBeOff) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose another model as the primary first, then switch this one off.")
        }
    }

    /// What the route points at, one fact per line so a long model id never hides the rest.
    private var detailLines: [String] {
        if provider.kind == .bedrock {
            let auth = provider.awsProfile.map { "AWS profile \($0)" } ?? "Bedrock API key"
            return [provider.model, "Amazon Bedrock · \(provider.awsRegion ?? "no Region") · \(auth)"]
        }
        var address = provider.baseURL
        if let window = provider.contextWindow { address += " · \(window.formatted()) ctx" }
        return [provider.model, address]
    }

    /// Per-route settings below the row: how many subagents at once (and why a flagged route may not count), and
    /// Bedrock's model and sign-in.
    @ViewBuilder
    private var extras: some View {
        let showsWorker = provider.isSubagentWorker && !isMain && provider.isEnabled
        if showsWorker || provider.kind == .bedrock {
            HStack(spacing: 8) {
                if showsWorker {
                    Text("Subagents at a time:").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { min(max(provider.subagentParallel ?? 2, 1), 8) },
                        set: { config.setSubagentParallel(provider.routeID, $0) })) {
                        ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 56)
                    .controlSize(.small)
                    .help("How many subagents may work on this server at the same time")
                    if !isEffectiveWorker {
                        Text("· the same server as another subagent route, so not used")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("A self-hosted server runs one model at a time (a Spark swaps them); a second route on it would only queue behind the first.")
                    }
                }
                if provider.kind == .bedrock {
                    Button("Change…") { model.showBedrockGuide(page: .model, route: provider) }
                        .controlSize(.small)
                        .help("Pick another Amazon Bedrock model or Region, or sign in with another AWS account.")
                    Button("Sign in") { model.showBedrockGuide(page: .signIn, route: provider) }
                        .controlSize(.small)
                        .help("Sign in to AWS again — for when the sign-in has run out.")
                }
            }
        }
    }

    private var statusColor: Color {
        switch result?.tone {
        case .success?: Theme.successTint
        case .failure?: Theme.errorTint
        default: Theme.hairline
        }
    }

    private func badge(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(filled ? Color.accentColor.opacity(0.18) : Theme.surfaceStrong, in: Capsule())
    }

    private func setEnabled(_ on: Bool) {
        if !config.setEnabled(provider.routeID, on) {
            primaryCantBeOff = true
            return
        }
        model.transport.resetRouteCache()
    }

    private func makeMain() {
        guard !isMain else { return }
        config.makeMain(provider.routeID)
        model.transport.resetRouteCache()
        report(.init(text: "\(AppTransport.routeLabel(provider)) is now the primary."))
    }
}
