import Foundation
import AppKit
import VisionHarnessCore

// MARK: - The harness's Guardian connection
//
// One per app. Holds the client and the session, persists the session token
// in the Keychain (under the app's own service, like every other secret),
// and does the work the harness needs: sign in/out, sync prompts up, and the
// settings page's actions (pull skills, export/import chats, upload projects).

@MainActor
public final class GuardianService: ObservableObject {
    /// Where the deployment lives (the wizard's address field).
    public static let defaultURL = "https://guardian.503cm.com"

    @Published public private(set) var client: GuardianClient?
    /// The signed-in user for the UI ("Signed in as …").
    @Published public private(set) var accountEmail: String?
    @Published public private(set) var lastError: String?
    /// Set when a sign-in stopped at the 2FA step: the challenge from
    /// Guardian is held here until `verifyTwoFactor(code:)` completes (or
    /// another sign-in replaces it). The settings UI shows the code field.
    @Published public private(set) var pendingTwoFactorChallenge: String?
    /// The email of the sign-in waiting on its 2FA code.
    @Published public private(set) var pendingTwoFactorEmail: String?
    /// The transport whose ETA cache Guardian's shared samples blend into, and whose Guardian model routes use this
    /// connection's token. Set by AppModel after both are constructed.
    public weak var transport: AppTransport? {
        didSet {
            // A connection signed in from an earlier run: its model routes carry its token (it is never older than
            // theirs — every sign-in, the wizard's too, ends here).
            if let token = client?.session?.token, !token.isEmpty, let client {
                routesFollow(token: token, address: client.baseURL.absoluteString)
                // Guardian's models are in every chat's menu at once (the list this Mac last saw — none after an
                // update from 0.16.2), then read now and every 15 minutes.
                publishModels()
                startModelRefresh()
            }
        }
    }

    /// The models Guardian offers this account in this organization (what every chat's model menu lists under
    /// "Guardian"); empty while signed out.
    @Published public private(set) var models: [GuardianModel] = []
    /// Reads the list again every `modelRefreshInterval` while signed in.
    private var modelRefresh: Task<Void, Never>?
    public static let modelRefreshInterval: TimeInterval = 15 * 60
    /// The list as last read, so the menus have it at launch before Guardian answers (no token in it).
    private let modelsFile: URL

    /// GET /api/harness/me: the account, its organizations, modules, permissions and limits.
    @Published public private(set) var account: GuardianAccount?
    /// GET /api/harness/limits.
    @Published public private(set) var limits: [GuardianLimit] = []
    /// The organization calls act in (x-guardian-org); nil = the account's active one.
    @Published public private(set) var orgID: String?
    /// A browser sign-in is waiting for the person to finish it in the browser.
    @Published public private(set) var browserSignInRunning = false
    /// Secrets the person marked "Usable in Vision" in Guardian (names only), and which are in use this run.
    @Published public private(set) var remoteSecrets: [GuardianVaultSecret] = []
    @Published public private(set) var secretsInUse: Set<String> = []
    /// The person's code projects in Guardian.
    @Published public private(set) var remoteProjects: [GuardianProject] = []
    /// The dialog to show: a structured refusal (what is missing, or which limit and when it resets).
    @Published public var problem: GuardianProblem?
    private var lastShown: (id: String, at: Date)?
    private var browserTask: Task<Void, Never>?
    private let secrets: any SecretStore

    /// Prompts already pushed, so a prompt is never synced twice.
    private var pushedPromptIDs: Set<String> = []
    private let pushedFile: URL

    /// Makes the HTTP client (tests hand in a scripted transport).
    let transportOverride: GuardianClient.Transport?

    func makeClient(_ address: String, session: GuardianSession? = nil) throws -> GuardianClient {
        try GuardianClient(baseURL: address.isEmpty ? Self.defaultURL : address, session: session, transport: transportOverride)
    }

    public init(appSupport: URL, secrets: any SecretStore = AppSecrets.keychain, transport: GuardianClient.Transport? = nil) {
        self.secrets = secrets
        self.transportOverride = transport
        pushedFile = appSupport.appendingPathComponent("guardian-pushed-prompts.json")
        modelsFile = appSupport.appendingPathComponent("guardian-models.json")
        let address = secrets.read(service: AppIdentity.KeychainService.guardian, account: "address")
            ?? Self.defaultURL
        if let token = secrets.read(service: AppIdentity.KeychainService.guardian, account: "token"), !token.isEmpty {
            let email = secrets.read(service: AppIdentity.KeychainService.guardian, account: "email") ?? ""
            client = try? makeClient(address, session: GuardianSession(userID: email, email: email, name: nil, token: token))
            accountEmail = email.isEmpty ? nil : email
            let org = secrets.read(service: AppIdentity.KeychainService.guardian, account: "org")
            orgID = org?.isEmpty == false ? org : nil
            client?.orgID = orgID
        }
        if let data = try? Data(contentsOf: pushedFile),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            pushedPromptIDs = Set(ids)
        }
        if let client, let cached = Self.readModelsCache(modelsFile), cached.address == client.baseURL.absoluteString,
           cached.org == orgID {
            models = cached.models
        }
    }

    public var isSignedIn: Bool { client != nil && accountEmail != nil }

    /// Sign in with the Guardian login and remember the session.
    public func signIn(address: String, email: String, password: String,
                       secrets: (any SecretStore)? = nil) async -> Bool {
        // The service's own store (the Keychain in the app, memory in tests): never the real Keychain behind a test.
        let secrets = secrets ?? self.secrets
        lastError = nil
        pendingTwoFactorChallenge = nil
        pendingTwoFactorEmail = nil
        do {
            let guardian = try makeClient(address)
            let session: GuardianSession
            do {
                session = try await guardian.signIn(email: email, password: password)
            } catch GuardianError.twoFactorRequired(let challenge) {
                // The account has TOTP on: hold the challenge and let the UI
                // collect the authenticator code.
                pendingTwoFactorChallenge = challenge
                pendingTwoFactorEmail = email
                lastError = nil
                return false
            }
            try completeSignIn(guardian, session: session, address: address, secrets: secrets)
            return true
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Finish a sign-in that stopped at the 2FA step. On success the session
    /// is stored exactly like a password-only sign-in.
    @discardableResult
    public func verifyTwoFactor(code: String,
                                secrets: (any SecretStore)? = nil) async -> Bool {
        let secrets = secrets ?? self.secrets
        lastError = nil
        guard let challenge = pendingTwoFactorChallenge, let guardian = client else {
            lastError = "No 2FA sign-in is waiting for a code — sign in again."
            return false
        }
        do {
            let session = try await guardian.verifyTwoFactor(challenge: challenge, code: code)
            pendingTwoFactorChallenge = nil
            pendingTwoFactorEmail = nil
            try completeSignIn(guardian, session: session,
                               address: guardian.baseURL.absoluteString, secrets: secrets)
            return true
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// The shared tail of both sign-in paths: keep the token, name the account.
    private func completeSignIn(_ guardian: GuardianClient, session: GuardianSession,
                                address: String, secrets: any SecretStore) throws {
        secrets.write(session.token, service: AppIdentity.KeychainService.guardian, account: "token")
        secrets.write(session.email, service: AppIdentity.KeychainService.guardian, account: "email")
        secrets.write(address, service: AppIdentity.KeychainService.guardian, account: "address")
        client = guardian
        accountEmail = session.email.isEmpty ? nil : session.email
        guardian.orgID = orgID
        // The model routes on this Guardian use the new token too: signing in again here (what a 401 asks for) renews
        // the models as well as prompts, limits and the vault.
        routesFollow(token: session.token, address: guardian.baseURL.absoluteString)
        // Guardian's models: in every chat's model menu, on this sign-in's token (read now, then every 15 minutes).
        publishModels()
        startModelRefresh()
        // The shared ETA cache: what the org's harnesses learned blends
        // into this Mac's cache, so its first estimates start smart.
        Task { [weak self] in
            guard let transport = self?.transport else { return }
            try? await GuardianProblems.$quiet.withValue(true) { try await guardian.syncEtas(into: transport.phaseRunner) }
        }
        Task { [weak self] in await self?.refreshAccount() }
    }

    /// A sign-in finished elsewhere (the setup wizard's Guardian page): the connection uses it too, so prompts,
    /// limits and the vault work without signing in twice.
    public func adopt(_ session: GuardianSession, address: String, orgID org: String? = nil) {
        guard let guardian = try? makeClient(address, session: session) else { return }
        if let org { setOrg(org, refresh: false) }
        try? completeSignIn(guardian, session: session, address: guardian.baseURL.absoluteString, secrets: secrets)
    }

    // MARK: Browser sign-in (Entra SSO, passwordless)

    /// Sign in through the browser: Guardian's consent page (the person picks the org there), back to a loopback
    /// address on this Mac, the code exchanged with PKCE. Returns true once signed in.
    @discardableResult
    public func signInWithBrowser(address: String) async -> Bool {
        lastError = nil
        pendingTwoFactorChallenge = nil
        browserSignInRunning = true
        defer { browserSignInRunning = false }
        do {
            let guardian = try makeClient(address)
            let device = Host.current().localizedName ?? "Mac"
            let (session, org) = try await guardian.signInWithBrowser(device: "\(AppIdentity.name) on \(device)") { url in
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            if let org { setOrg(org, refresh: false) }
            try completeSignIn(guardian, session: session, address: guardian.baseURL.absoluteString, secrets: secrets)
            if session.email.isEmpty {
                // The token exchange may not name the person: /me does.
                if let me = try? await guardian.me() {
                    accountEmail = me.email
                    secrets.write(me.email, service: AppIdentity.KeychainService.guardian, account: "email")
                }
            }
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Start the browser sign-in without waiting (the settings button); `cancelBrowserSignIn` stops waiting.
    public func startBrowserSignIn(address: String) {
        browserTask?.cancel()
        browserTask = Task { [weak self] in _ = await self?.signInWithBrowser(address: address) }
    }

    public func cancelBrowserSignIn() {
        browserTask?.cancel()
        browserTask = nil
        browserSignInRunning = false
    }

    // MARK: Account, organization, limits

    /// Read /me and /limits again. A sign-in Guardian no longer accepts is dropped with a plain message.
    public func refreshAccount() async {
        guard let client else { return }
        do {
            let me = try await client.me()
            account = me
            if !me.email.isEmpty, accountEmail != me.email {
                accountEmail = me.email
                secrets.write(me.email, service: AppIdentity.KeychainService.guardian, account: "email")
            }
            if !me.limits.isEmpty { limits = me.limits }
            if let fetched = try? await client.limits() { limits = fetched }
            // An org that isn't the account's any more falls back to the default one.
            if let orgID, !me.orgs.isEmpty, !me.orgs.contains(where: { $0.id == orgID }) { setOrg(nil, refresh: false) }
        } catch GuardianError.unauthorized {
            lastError = GuardianError.unauthorized.errorDescription
            signOut(secrets: secrets)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Act in another organization (x-guardian-org on every call), and read the account again.
    public func setOrg(_ id: String?, refresh: Bool = true) {
        orgID = id?.isEmpty == true ? nil : id
        client?.orgID = orgID
        secrets.write(orgID, service: AppIdentity.KeychainService.guardian, account: "org")
        // The model proxy works in the same organization: Guardian routes carry the header too.
        if let config = transport?.config {
            for index in config.providers.indices where config.providers[index].kind == .guardian {
                var headers = config.providers[index].customHeaders ?? [:]
                headers["x-guardian-org"] = orgID
                if config.providers[index].customHeaders ?? [:] != headers {
                    config.providers[index].customHeaders = headers.isEmpty ? nil : headers
                }
            }
        }
        remoteSecrets = []
        remoteProjects = []
        // Guardian's models in the menus work in that organization too, and it may offer others.
        publishModels()
        if refresh { Task { [weak self] in await self?.refresh() } }
    }

    /// Read the account, its limits and Guardian's models again (Settings ▸ Guardian ▸ Refresh, another organization).
    public func refresh() async {
        await refreshAccount()
        await refreshModels()
    }

    // MARK: Guardian's models in every chat's menu

    /// Read the account's models (GET /api/harness/v1/models) and put them in every chat's model menu. A failure
    /// keeps the list it had (the dialog for a refusal is left to the person's own actions).
    public func refreshModels() async {
        guard let client, let token = client.session?.token, !token.isEmpty else { return }
        do {
            let listed = try await GuardianProblems.$quiet.withValue(true) { try await client.models() }
            // Signed out, or signed in elsewhere, while it was asked: that answer is stale.
            guard self.client === client else { return }
            models = listed
            publishModels()
            Self.writeModelsCache(modelsFile, ModelsCache(address: client.baseURL.absoluteString, org: orgID, models: listed))
        } catch GuardianError.unauthorized {
            lastError = GuardianError.unauthorized.errorDescription
        } catch {
            // Offline or busy: the list from before stays.
        }
    }

    /// Hand the list, the proxy's address, the organization and the sign-in's token to the routes (all empty while
    /// signed out). The routes read the token when a request is made, so a new sign-in renews every chat on them.
    private func publishModels() {
        guard let config = transport?.config else { return }
        let raw = client?.session?.token
        let token = (raw?.isEmpty ?? true) ? nil : raw
        let base = client.map { Self.modelRouteURL($0.baseURL) }
        let shown = client == nil ? [] : models
        guard config.guardianToken != token || config.guardianModelBase != base || config.guardianOrgID != orgID
                || config.guardianModels != shown else { return }
        config.guardianToken = token
        config.guardianModelBase = base
        config.guardianOrgID = orgID
        if config.guardianModels != shown { config.guardianModels = shown }
        // Chats on these models build their client again with what changed (a new token, another organization).
        transport?.resetRouteCache()
        // Guardian models ticked "Use for subagents" come and go with the sign-in and the list.
        transport?.refreshFleet()
    }

    /// Read the list now — a launch already signed in has only the list kept from last time, if any — and again every
    /// `modelRefreshInterval` while signed in.
    private func startModelRefresh() {
        modelRefresh?.cancel()
        modelRefresh = Task { [weak self] in
            // Cancelled (signed out), or the connection is gone: stop. (No strong hold on the service across the sleep.)
            while !Task.isCancelled, self != nil {
                await self?.refreshModels()
                try? await Task.sleep(nanoseconds: UInt64(Self.modelRefreshInterval * 1_000_000_000))
            }
        }
    }

    struct ModelsCache: Codable {
        var address: String
        var org: String?
        var models: [GuardianModel]
    }

    static func readModelsCache(_ file: URL) -> ModelsCache? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ModelsCache.self, from: data)
    }

    static func writeModelsCache(_ file: URL, _ cache: ModelsCache?) {
        guard let cache else { try? FileManager.default.removeItem(at: file); return }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: The model routes follow the connection

    /// Whether `route` is a Guardian model route on the Guardian at `address` (same host and port).
    static func servesSameGuardian(_ route: ProviderProfile, address: String) -> Bool {
        guard route.kind == .guardian,
              let a = URL(string: route.baseURL), let b = URL(string: address.isEmpty ? defaultURL : address),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return false }
        return hostA == hostB && a.port == b.port
    }

    /// The Guardian model routes on this connection's Guardian.
    public var modelRoutes: [ProviderProfile] {
        guard let config = transport?.config else { return [] }
        let address = client?.baseURL.absoluteString ?? Self.defaultURL
        return config.providers.filter { Self.servesSameGuardian($0, address: address) }
    }

    /// Give every Guardian model route on `address` the connection's token (nil: take it away), so the models never
    /// keep a token the connection has replaced or dropped.
    private func routesFollow(token: String?, address: String) {
        guard let transport else { return }
        let config = transport.config
        var changed = false
        for route in config.providers where Self.servesSameGuardian(route, address: address) {
            let next = token ?? ""
            if config.apiKey(for: route) != next {
                config.setAPIKey(next, for: route)
                changed = true
            }
        }
        if changed { transport.resetRouteCache() }
    }

    /// The model proxy's address for a Guardian deployment: its OpenAI-compatible `/v1`, as the setup wizard writes it.
    static func modelRouteURL(_ base: URL) -> String {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let path = parts?.path ?? ""
        parts?.path = path.isEmpty || path == "/" ? "/v1" : path
        parts?.query = nil
        return parts?.string ?? base.absoluteString
    }

    /// Show a structured refusal as a dialog (the same one twice within half a minute shows once).
    public func show(_ problem: GuardianProblem) {
        if let lastShown, lastShown.id == problem.id, Date().timeIntervalSince(lastShown.at) < 30 { return }
        lastShown = (problem.id, Date())
        self.problem = problem
    }

    // MARK: Vault (opt-in per secret, memory-only)

    public func loadSecrets() async {
        guard let client else { return }
        do { remoteSecrets = try await client.vaultSecrets() } catch { report(error) }
    }

    /// The vault name a Guardian secret is used under here.
    static func vaultName(_ secret: GuardianVaultSecret) -> String {
        let cleaned = OpenClawReader.sanitize(secret.envKey?.isEmpty == false ? secret.envKey! : secret.name)
        return cleaned == "OPENCLAW_SECRET" ? "GUARDIAN_SECRET" : cleaned
    }

    /// Reveal one secret (Guardian audits it) and hold it for this run only: usable as {{vault:NAME}}, ask-first,
    /// never written to disk or the Keychain.
    public func useSecret(_ secret: GuardianVaultSecret) async {
        guard let client, let vault = transport?.vault else { return }
        do {
            let value = try await client.revealSecret(id: secret.id)
            let kind: VaultEntry.Kind = switch (secret.itemType ?? secret.kind)?.lowercased() {
            case "password", "login": .password
            case "token", "oauth": .token
            case "api_key", "apikey", "key": .apiKey
            default: .other
            }
            try vault.addSessionOnly(name: Self.vaultName(secret), value: value, kind: kind,
                                     description: (secret.description.map { $0 + " " } ?? "") + "From Guardian — this run of \(AppIdentity.name) only.",
                                     tags: ["guardian"] + (secret.service.map { [$0] } ?? []), access: .ask)
            secretsInUse.insert(secret.id)
            transport?.vaultDidChange()
        } catch {
            report(error)
        }
    }

    public func stopUsingSecret(_ secret: GuardianVaultSecret) {
        transport?.vault.removeSessionOnly(named: Self.vaultName(secret))
        secretsInUse.remove(secret.id)
        transport?.vaultDidChange()
    }

    // MARK: Projects

    public func loadProjects() async {
        guard let client else { return }
        do { remoteProjects = try await client.projects() } catch { report(error) }
    }

    /// Write a project's files from Guardian into `folder`, in a new subfolder named after it ("name (2)" when that
    /// name is taken — a copy never writes over a folder that is there, such as the working tree it came from).
    /// Returns the folder.
    public func downloadProject(_ project: GuardianProject, into folder: URL) async -> URL? {
        guard let client else { return nil }
        do {
            let manifest = try await client.project(id: project.id)
            let root = GuardianProjects.newFolder(for: manifest.name, in: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (path, text) in manifest.files {
                // Every file stays inside the new folder.
                guard let file = GuardianProjects.file(path, under: root) else { continue }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            return root
        } catch {
            report(error)
            return nil
        }
    }

    private func report(_ error: Error) {
        if case GuardianError.problem = error { return }   // the dialog says it
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Abandon a sign-in that's waiting on its 2FA code.
    public func cancelTwoFactor() {
        pendingTwoFactorChallenge = nil
        pendingTwoFactorEmail = nil
        lastError = nil
    }

    public func signOut(secrets: (any SecretStore)? = nil) {
        let secrets = secrets ?? self.secrets
        let address = client?.baseURL.absoluteString
            ?? secrets.read(service: AppIdentity.KeychainService.guardian, account: "address") ?? Self.defaultURL
        secrets.write(nil, service: AppIdentity.KeychainService.guardian, account: "token")
        secrets.write(nil, service: AppIdentity.KeychainService.guardian, account: "email")
        // Signed out means signed out: the Guardian model routes stop using the token too, and Guardian's models leave
        // the menus (a chat on one says "Sign in to Guardian to use this model." until the next sign-in).
        routesFollow(token: nil, address: address)
        modelRefresh?.cancel()
        modelRefresh = nil
        models = []
        Self.writeModelsCache(modelsFile, nil)
        client = nil
        publishModels()
        accountEmail = nil
        account = nil
        limits = []
        remoteSecrets = []
        remoteProjects = []
        // Secrets revealed for this run go with the sign-in.
        if !secretsInUse.isEmpty {
            transport?.vault.removeSessionOnly(named: nil)
            secretsInUse = []
            transport?.vaultDidChange()
        }
    }

    // MARK: Snapshot mode

    /// A made-up signed-in account for the README pictures (no network: every call answers 503).
    func seedSnapshotAccount() {
        let offline: GuardianClient.Transport = { _ in GuardianHTTPResponse(data: Data(#"{"error":"offline"}"#.utf8), status: 503, headers: [:]) }
        client = try? GuardianClient(baseURL: Self.defaultURL,
                                     session: GuardianSession(userID: "u1", email: "sam@503cm.com", name: "Sam Rivera", token: "snapshot"),
                                     transport: offline)
        accountEmail = "sam@503cm.com"
        let week = Date().addingTimeInterval(4 * 86_400 + 3_600)
        account = GuardianAccount(userID: "u1", email: "sam@503cm.com", name: "Sam Rivera",
                                  orgs: [GuardianOrg(id: "o1", name: "503CM", active: true), GuardianOrg(id: "o2", name: "Cyticorp")],
                                  modules: ["chat", "insights", "automations", "ai-coders"], permissions: ["chat.use"], limits: [])
        limits = [GuardianLimit(kind: "spend", window: "week", used: 31.4, max: 50, unit: "usd", resetsAt: week),
                  GuardianLimit(kind: "tokens", window: "day", used: 1_640_000, max: 2_000_000, unit: "tokens",
                                resetsAt: Date().addingTimeInterval(5 * 3_600)),
                  GuardianLimit(kind: "requests", window: "run", used: 1, max: 3, unit: "streams")]
        remoteSecrets = [GuardianVaultSecret(id: "s1", name: "Freshdesk", envKey: "FRESHDESK_API_KEY", service: "freshdesk", itemType: "api_key"),
                         GuardianVaultSecret(id: "s2", name: "Ledger API", envKey: "LEDGER_API_KEY", itemType: "api_key")]
        secretsInUse = ["s1"]
    }

    // MARK: Prompt sync (item 4)

    /// Push the chat's prompt history up to Guardian's notebook. Idempotent:
    /// each prompt text+time pair is pushed once. Called after a send when
    /// the user is signed in, and from Settings ("Sync now").
    /// - Returns: how many prompts went up on this call.
    /// `background` (the sync on every prompt's start and end): a refusal is kept in `lastError`, not shown as a
    /// dialog. Settings' "Sync now" is the person's own action and shows it.
    @discardableResult
    public func syncPrompts(_ records: [SessionVMPrompt], background: Bool = false) async -> Int {
        guard let client else { return 0 }
        // A prompt goes up on submit, and again once its outcome is known (Guardian dedupes on text and time and
        // keeps the outcome); each (prompt, outcome) pair is sent once.
        let pending = records.filter { !pushedPromptIDs.contains($0.pushKey) }
        guard !pending.isEmpty else { return 0 }
        let prompts = pending.map {
            GuardianPrompt(text: $0.text, at: $0.at, outcome: $0.outcome, source: "vision-mac", chatID: $0.chatID,
                           chatTitle: $0.chatTitle, project: $0.project, model: $0.model,
                           durationSeconds: $0.durationSeconds, runID: $0.runID)
        }
        do {
            let accepted = background
                ? try await GuardianProblems.$quiet.withValue(true) { try await client.pushPrompts(prompts) }
                : try await client.pushPrompts(prompts)
            for record in pending { pushedPromptIDs.insert(record.pushKey) }
            persistPushed()
            return accepted
        } catch {
            lastError = (error as? GuardianError)?.errorDescription ?? error.localizedDescription
            return 0
        }
    }

    /// The prompt rows the harness hands the service (decoded from the
    /// SessionVM's own type, which VisionHarnessCore cannot see).
    public struct SessionVMPrompt: Sendable {
        public var id: String
        public var text: String
        public var at: Date
        public var outcome: String?
        public var chatID: String
        public var chatTitle: String?
        public var project: String?
        public var model: String?
        public var durationSeconds: Double?
        public var runID: String?
        public init(id: String, text: String, at: Date, outcome: String?, chatID: String, chatTitle: String? = nil,
                    project: String? = nil, model: String? = nil, durationSeconds: Double? = nil, runID: String? = nil) {
            self.id = id
            self.text = text
            self.at = at
            self.outcome = outcome
            self.chatID = chatID
            self.chatTitle = chatTitle
            self.project = project
            self.model = model
            self.durationSeconds = durationSeconds
            self.runID = runID
        }

        /// What "already sent" is keyed on: the prompt, and the outcome it was sent with (a bare id = on submit,
        /// the key earlier builds wrote).
        var pushKey: String { outcome.map { "\(id)|\($0)" } ?? id }

        /// The copy that goes up: Guardian isn't a private model, so the text, the chat's title and the project are
        /// masked like a request to a model that isn't private — the vault's secrets always, and what the
        /// sensitive-data shield masks when it is on (`detector` nil: nothing to mask). The same text masks the same
        /// way each time, so the start and the end still land on one notebook row. The same rule as Windows.
        public func masked(by detector: SensitiveDetector?) -> SessionVMPrompt {
            guard let detector else { return self }
            let out = Shield.maskTexts([text, chatTitle, project], detector: detector)
            var copy = self
            copy.text = out[0] ?? text
            copy.chatTitle = out[1]
            copy.project = out[2]
            return copy
        }
    }

    private func persistPushed() {
        if let data = try? JSONEncoder().encode(Array(pushedPromptIDs)) {
            try? data.write(to: pushedFile, options: .atomic)
        }
    }

    // MARK: ETA samples up (the multitenant cache)

    /// Push a finished turn's duration to Guardian's shared cache. Called by
    /// the transport when a turn's phases finish; failures are silent (the
    /// local cache already has the sample).
    nonisolated func pushEta(kindRawValue: String, scope: Double, seconds: Double) {
        let kind = TurnPhaseState.TaskKind(rawValue: kindRawValue)
        Task { @MainActor [kind] in
            guard let kind, let client = self.client else { return }
            try? await GuardianProblems.$quiet.withValue(true) { try await client.pushEtaSamples([(kind, scope, seconds)]) }
        }
    }
}
