import Foundation
import Observation
import VisionHarnessCore

/// One box running a Spark Swapper — a DGX Spark or a Strix Halo: how to reach it, what it is serving now, and
/// whether it is switching.
@MainActor
@Observable
final class SwapperBox: Identifiable {
    let id: String
    fileprivate(set) var connection: SwapperConnection
    fileprivate(set) var status: SwapperStatus?
    fileprivate(set) var lastError: String?
    /// A certificate the user hasn't approved yet (shown in Settings ▸ Model Servers).
    var untrustedFingerprint: String?
    fileprivate(set) var refreshing = false
    /// The install running on the box (or the last one Vision watched).
    fileprivate(set) var installJob: SwapperStatus.Job?
    fileprivate(set) var installError: String?
    /// Models installed while Vision watched: each is offered "Switch to It".
    fileprivate(set) var justInstalled: Set<String> = []

    @ObservationIgnored fileprivate var client: SparkSwapperClient?
    @ObservationIgnored fileprivate var watchedJob: String?
    @ObservationIgnored fileprivate var installWatch: Task<Void, Never>?

    init(connection: SwapperConnection) {
        self.id = connection.id
        self.connection = connection
    }

    var name: String { connection.name }
    var isOnline: Bool { status != nil && lastError == nil }
    var isSwitching: Bool { status?.isSwitching ?? false }

    /// "DGX Spark · Swapper 2.0.0"
    var summary: String {
        let version = (status?.version ?? connection.version).map { " · Swapper \($0)" } ?? ""
        return SwapperPlatform.displayName(status?.platform ?? connection.platform) + version
    }

    /// "Serving Qwen3.8 27B (1M context)", "Nothing is serving right now", or why it can't be reached.
    var servingLine: String {
        if let lastError { return lastError }
        guard let status else { return refreshing ? "Connecting…" : "Not checked yet" }
        guard let model = status.activeModel else { return "Nothing is serving right now" }
        return "Serving \(model.title) (\(ModelSizes.short(model.window)) context)"
    }

    /// Human-readable progress line for the banner while it switches.
    var progressLine: String? {
        guard let job = status?.job, job.isRunning else { return nil }
        let title = status?.models[job.target]?.title ?? job.target
        let step = job.currentStep?.label ?? "Working"
        let elapsed = Int(Date().timeIntervalSince1970 - job.started)
        return "Switching \(name) to \(title) · \(step) · \(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }

    /// The Swapper's web page.
    var webPage: URL? { URL(string: connection.url) }

    /// The model being installed right now.
    var installingKey: String? { installJob?.isRunning == true ? installJob?.installingModel : nil }

    /// "Installing Qwen3.8 Flash on DGX Spark (spark-3f2a) · Downloading weights · 3m 12s"
    var installProgressLine: String? {
        guard let job = installJob, job.isRunning, let key = job.installingModel else { return nil }
        let title = status?.models[key]?.title ?? key
        let step = job.currentStep?.label ?? "Working"
        let elapsed = Int(Date().timeIntervalSince1970 - job.started)
        return "Installing \(title) on \(name) · \(step) · \(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }
}

/// Drives the Spark Swappers from the app: which model each box serves, switching it, and following the switch
/// in every chat — every route whose address is the box's model API follows the newly served model.
///
/// The connections live in UserDefaults; their secrets (an app token, or a login's password) in the Keychain.
@MainActor
@Observable
final class SparkController {
    private let defaults: UserDefaults
    private let secrets: any SecretStore
    private weak var transport: AppTransport?
    private let config: AppConfig

    private(set) var boxes: [SwapperBox] = []
    /// The model the user picked in a menu, waiting for "Switch".
    var confirmTarget: SwitchRequest?

    struct SwitchRequest: Identifiable {
        let box: SwapperBox
        let model: SwapperStatus.Model
        var id: String { box.id + "|" + model.key }

        /// "takes about 11 minutes"
        var duration: String { model.switchDuration }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// How often an install is checked on, and how long a box may go without answering before Vision stops
    /// following it (tests shorten both).
    @ObservationIgnored var installPollInterval: TimeInterval = 2
    @ObservationIgnored var installSilenceLimit: TimeInterval = 300

    init(config: AppConfig, transport: AppTransport, defaults: UserDefaults = IsolatedRun.defaults,
         secrets: any SecretStore = AppSecrets.keychain) {
        self.config = config
        self.transport = transport
        self.defaults = defaults
        self.secrets = secrets
        boxes = SwapperConnectionStore.load(defaults: defaults, secrets: secrets, routes: config.providers).map(SwapperBox.init)
    }

    // MARK: Boxes

    var isConfigured: Bool { !boxes.isEmpty }

    func box(id: String) -> SwapperBox? { boxes.first { $0.id == id } }

    /// The box serving `route`, if one does.
    func box(serving route: ProviderProfile?) -> SwapperBox? {
        guard let route else { return nil }
        return boxes.first { $0.connection.serves(route) }
    }

    /// The box behind the main model.
    var primaryBox: SwapperBox? { box(serving: config.mainRoute) }

    /// The box a bare `/swap <model>` switches in a chat: the one behind that chat's own model (each chat has its own,
    /// as on Windows), else the primary's.
    func swapHome(for vm: SessionVM) -> SwapperBox? {
        transport.flatMap { box(serving: $0.chatRoute(vm)) } ?? primaryBox
    }

    /// True while the box behind the main model switches models: sending waits for it.
    var isSwitchingMainModel: Bool { primaryBox?.isSwitching ?? false }

    var switchingBoxes: [SwapperBox] { boxes.filter(\.isSwitching) }

    /// Add a box, or update the one already known at the same address. `secret` is its token or password
    /// (to the Keychain).
    @discardableResult
    func add(_ connection: SwapperConnection, secret: String?) -> SwapperBox {
        var connection = connection
        if let existing = boxes.first(where: { SwapperConnection.sameAddress($0.connection.url, connection.url) }) {
            // Keep its identity (and its links) — it is the same box.
            connection.id = existing.id
            connection.linkedRoutes = Array(Set(existing.connection.linkedRoutes + connection.linkedRoutes)).sorted()
            existing.connection = connection
            existing.client = nil
            existing.lastError = nil
            existing.untrustedFingerprint = nil
            SwapperConnectionStore.setSecret(secret, for: connection, secrets: secrets)
            persist()
            return existing
        }
        SwapperConnectionStore.setSecret(secret, for: connection, secrets: secrets)
        let box = SwapperBox(connection: connection)
        boxes.append(box)
        persist()
        return box
    }

    func remove(_ box: SwapperBox) {
        SwapperConnectionStore.setSecret(nil, for: box.connection, secrets: secrets)
        boxes.removeAll { $0.id == box.id }
        persist()
    }

    func rename(_ box: SwapperBox, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        box.connection.name = trimmed
        persist()
    }

    /// Remember that `route` was made for `box` — and for no other box, so a route is never followed by two.
    func link(_ route: ProviderProfile, to box: SwapperBox) {
        for other in boxes where other.id != box.id && other.connection.linkedRoutes.contains(route.routeID) {
            other.connection.linkedRoutes.removeAll { $0 == route.routeID }
        }
        if !box.connection.linkedRoutes.contains(route.routeID) { box.connection.linkedRoutes.append(route.routeID) }
        persist()
    }

    /// Trust the certificate a box presented (the user compared the fingerprint) — for the Swapper and for the
    /// box's routes on it, whose model front (:11443) presents the same certificate.
    func trustPresentedCertificate(_ box: SwapperBox) {
        guard let fp = box.untrustedFingerprint else { return }
        box.connection.pinnedFingerprint = fp
        box.untrustedFingerprint = nil
        box.lastError = nil
        box.client = nil
        persist()
        let host = box.connection.host
        for index in config.providers.indices {
            let route = config.providers[index]
            guard box.connection.serves(route), let url = URL(string: route.baseURL), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == host, route.pinnedCertificate != fp else { continue }
            config.providers[index].pinnedCertificate = fp
        }
        Task { await refresh(box) }
    }

    func forgetCertificate(_ box: SwapperBox) {
        box.connection.pinnedFingerprint = nil
        box.client = nil
        persist()
    }

    private func persist() {
        SwapperConnectionStore.save(boxes.map(\.connection), defaults: defaults)
    }

    private func client(_ box: SwapperBox) throws -> SparkSwapperClient {
        if let client = box.client { return client }
        guard let made = SwapperConnectionStore.client(for: box.connection, secrets: secrets) else {
            throw SwapperError.notConfigured
        }
        box.client = made
        return made
    }

    // MARK: Status

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for box in boxes {
                group.addTask { await self.refresh(box) }
            }
        }
    }

    func refresh(_ box: SwapperBox) async {
        box.refreshing = true
        defer { box.refreshing = false }
        do {
            let s = try await client(box).status()
            let wasRunning = box.status?.job?.isRunning ?? false
            let wasSwitching = box.status?.isSwitching ?? false
            box.status = s
            box.lastError = nil
            box.untrustedFingerprint = nil
            noteFacts(s, of: box)
            // An install started elsewhere (the web page, before a relaunch): follow it too.
            if let install = s.install_job, install.isRunning, box.installWatch == nil {
                box.installJob = install
                watchInstall(box)
            }
            if let job = s.job, !job.isRunning, wasRunning || box.watchedJob == job.id {
                finished(job, on: box, status: s)
            }
            if s.isSwitching { startMonitoring() }
            // Chats whose tasks waited on this box start them now (any box: each chat has its own model).
            if wasSwitching, !s.isSwitching { transport?.serverSwitchFinished() }
        } catch let e as SwapperError {
            if case .untrustedCertificate(let fp) = e { box.untrustedFingerprint = fp }
            box.lastError = e.errorDescription
        } catch {
            box.lastError = error.localizedDescription
        }
    }

    /// A Swapper 2.0 says what it is: keep the connection's details current.
    private func noteFacts(_ s: SwapperStatus, of box: SwapperBox) {
        var changed = box.connection
        if let version = s.version { changed.version = version }
        if let platform = s.platform { changed.platform = platform }
        if let hostname = s.hostname { changed.hostname = hostname }
        if changed != box.connection {
            box.connection = changed
            persist()
        }
    }

    /// Poll quickly while a box switches, slowly otherwise.
    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                let fast = !self.switchingBoxes.isEmpty
                try? await Task.sleep(nanoseconds: (fast ? 2 : 30) * 1_000_000_000)
            }
        }
    }

    // MARK: Switching

    /// Ask to switch (the UI confirms via `confirmTarget`).
    func request(_ model: SwapperStatus.Model, on box: SwapperBox) {
        guard model.key != box.status?.active, model.isInstalled else { return }
        confirmTarget = SwitchRequest(box: box, model: model)
    }

    /// Switch now. Returns an error message, or nil when the swap started.
    @discardableResult
    func swap(_ box: SwapperBox, to key: String) async -> String? {
        do {
            try await client(box).swap(to: key)
            box.justInstalled.remove(key)
            await refresh(box)
            box.watchedJob = box.status?.job?.id
            startMonitoring()
            let title = box.status?.models[key]?.title ?? key
            transport?.broadcast("Switching \(box.name) to **\(title)**… chats will pick it up automatically when it is ready.")
            return nil
        } catch SwapperError.notInstalled {
            // Not the box's fault: say so on the request, not as the box's state.
            return Self.notInstalledMessage(box)
        } catch let e as SwapperError {
            box.lastError = e.errorDescription
            return e.errorDescription
        } catch {
            box.lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    static func notInstalledMessage(_ box: SwapperBox) -> String {
        "That model isn't installed on \(box.name) yet — install it from Settings ▸ Model Servers."
    }

    // MARK: Installing

    /// Install a model the box doesn't have yet (POST /api/models/install) and follow it until it finishes.
    func install(_ key: String, on box: SwapperBox) async {
        box.installError = nil
        do {
            let job = try await client(box).installModel(key)
            box.installJob = job ?? SwapperStatus.Job(id: "starting", target: "install:model:\(key)", state: "running",
                                                      started: Date().timeIntervalSince1970)
            watchInstall(box)
        } catch SwapperError.installBusy {
            box.installError = "Another install is already running on \(box.name). Wait for it to finish, then try again."
        } catch let e as SwapperError {
            box.installError = e.errorDescription
        } catch {
            box.installError = error.localizedDescription
        }
    }

    /// Poll the install (GET /api/provisioning/job) until it is over, then re-read what the box has. A box that
    /// stops answering about it for `installSilenceLimit` is no longer followed, and Settings says so.
    func watchInstall(_ box: SwapperBox) {
        guard box.installWatch == nil else { return }
        box.installWatch = Task { [weak self] in
            defer { box.installWatch = nil }
            var silentSince: Date?
            while !Task.isCancelled {
                guard let interval = self?.installPollInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let job = try? await self.client(box).provisioningJob() else {
                    let since = silentSince ?? Date()
                    silentSince = since
                    if Date().timeIntervalSince(since) >= self.installSilenceLimit {
                        let minutes = max(1, Int((self.installSilenceLimit / 60).rounded()))
                        box.installError = "\(box.name) hasn't answered about the install for \(minutes) minute\(minutes == 1 ? "" : "s"), so Vision stopped following it. It may still be installing — check its web page."
                        box.installJob = nil
                        return
                    }
                    continue
                }
                silentSince = nil
                box.installJob = job
                guard !job.isRunning else { continue }
                if job.state == "done", let key = job.installingModel {
                    box.justInstalled.insert(key)
                    let title = box.status?.models[key]?.title ?? key
                    self.transport?.broadcast("📦 \(title) is installed on \(box.name). Switch to it from the model menu or Settings ▸ Model Servers.")
                } else if job.state == "failed" {
                    box.installError = "The install failed: \(job.error ?? "unknown error")."
                }
                await self.refresh(box)
                return
            }
        }
    }

    private func finished(_ job: SwapperStatus.Job, on box: SwapperBox, status s: SwapperStatus) {
        box.watchedJob = nil
        // Every route on this box re-reads what it serves (and its window), so chats and subagents follow.
        transport?.resetRouteCache()
        let title = s.models[job.target]?.title ?? job.target
        if job.state == "done", let m = s.models[job.target] {
            transport?.broadcast("✅ \(box.name) is now serving **\(title)** (`\(m.served_id)`, \(m.window.formatted())-token context).")
        } else if job.state == "failed" {
            transport?.broadcast("⚠️ Switching \(box.name) to \(title) failed: \(job.error ?? "unknown error"). \(job.note ?? "")", error: true)
        }
    }

    /// `/swap`: every box's models; `/swap <model>` on the box behind this chat's own model (else the primary's, else
    /// the only box); `/swap <box> <model>` names the box.
    func handleCommand(_ arg: String?, in vm: SessionVM) async {
        let command = SwapCommand.parse(arg, boxes: boxes.map(\.connection), primaryBox: swapHome(for: vm)?.id)
        switch command {
        case .noBoxes:
            vm.note(SwapperError.notConfigured.errorDescription ?? "", role: .error)
        case .list:
            await refreshAll()
            vm.note(listing())
        case .whichBox(let model):
            let names = boxes.map { "**\($0.name)**" }.joined(separator: ", ")
            vm.note("Which box should switch to “\(model)”? You have several: \(names). Name it first, e.g. `/swap \(Self.shortName(boxes[0])) \(model)`.")
        case .switchModel(let id, let query):
            guard let box = box(id: id) else { return }
            await refresh(box)
            guard let s = box.status else {
                vm.note(box.lastError ?? "Couldn't read \(box.name)'s status.", role: .error)
                return
            }
            guard let key = s.resolve(query), let target = s.models[key] else {
                vm.note("No model on \(box.name) matches “\(query)”. Options: \(s.installedModels.map(\.key).joined(separator: ", ")).", role: .error)
                return
            }
            guard target.isInstalled else {
                vm.note(Self.notInstalledMessage(box), role: .error)
                return
            }
            if key == s.active {
                vm.note("\(box.name) is already serving \(target.title).")
                return
            }
            if s.isSwitching {
                vm.note("\(box.name) is already switching models; wait for it to finish.", role: .error)
                return
            }
            if let err = await swap(box, to: key) { vm.note(err, role: .error) }
        }
    }

    /// The first word of a box's name, for an example command ("dgx", "strix").
    private static func shortName(_ box: SwapperBox) -> String {
        (box.name.split(separator: " ").first.map(String.init) ?? box.name).lowercased()
    }

    /// `/swap`'s answer: each box and what it can serve.
    private func listing() -> String {
        var lines: [String] = []
        for box in boxes {
            lines.append("**\(box.name)** — \(box.summary)")
            guard let s = box.status else {
                lines.append("  \(box.lastError ?? "Not reachable right now.")")
                continue
            }
            for m in s.ordered {
                let mark = m.key == s.active ? "● serving" : (m.running ? "◌ loading" : "○")
                var line = "\(mark)  **\(m.title)** — `\(m.key)` · \(ModelSizes.short(m.window)) ctx"
                if let speed = m.speedText(roomForEstimate: true) { line += " · \(speed)" }
                if !m.isInstalled { line += " · Not installed" }
                lines.append(line)
            }
        }
        lines.append(boxes.count > 1
                     ? "Switch with `/swap <model>` (the box behind the main model), `/swap <box> <model>`, or the model menu under the composer."
                     : "Switch with `/swap <name>` or the model menu under the composer.")
        return lines.joined(separator: "\n")
    }

    /// The banner's lines while boxes switch (or install).
    var progressLines: [String] { boxes.compactMap(\.progressLine) + boxes.compactMap(\.installProgressLine) }
}

/// "1M", "512K" — a context window in a few characters.
enum ModelSizes {
    static func short(_ n: Int) -> String {
        n >= 1_000_000
            ? String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
            : "\(n / 1024)K"
    }
}
