import Foundation
import Observation
import VisionHarnessCore

/// How a Bedrock model is used once it is set up: the model you talk to (and that hands out subagent
/// tasks), or a subagent server that takes the side tasks the main model hands out.
enum RouteRole: String, CaseIterable, Identifiable {
    case main, subagents
    var id: String { rawValue }
}

/// The Amazon Bedrock guide: from "I have an AWS account" to chatting with a Bedrock model, for someone
/// who has never used the AWS CLI. It installs the CLI when it's missing (Amazon's signed installer, per
/// user — no admin prompt), signs in through the browser with `aws login` (or an existing SSO/CLI
/// profile), lists the Region's models with what each needs, does what a model needs before it can be
/// used (Anthropic's one-time use-case form, a Marketplace model's terms — shown with price and licence
/// first), waits for AWS to finish, saves the route and says hello.
///
/// The model is the state machine; `BedrockGuideBackend` is everything it does to the outside world, so
/// the flow is testable with a scripted backend. Pages are rebuilt from this state.
@MainActor
@Observable
final class BedrockGuideModel {
    @ObservationIgnored let backend: any BedrockGuideBackend
    @ObservationIgnored let config: AppConfig
    /// The route being changed ("Change…", "Sign in"): choosing a model replaces it in place, keeping its
    /// seat and role. Nil = a new route is added.
    let editing: ProviderProfile?

    /// The route was saved (or its role changed): the host resets its caches.
    @ObservationIgnored var onSaved: (ProviderProfile) -> Void = { _ in }
    /// The user finished the guide ("Start chatting").
    @ObservationIgnored var onFinish: () -> Void = {}
    /// The user left the guide from its first page.
    @ObservationIgnored var onLeave: () -> Void = {}

    // MARK: Navigation

    private(set) var page: BedrockPage
    var sectionCount: Int { BedrockPage.allCases.count }
    var sectionIndex: Int { page.rawValue }
    var title: String { "Amazon Bedrock guide · \(page.title)" }
    var stepText: String { "Step \(sectionIndex + 1) of \(sectionCount)" }

    // MARK: The AWS CLI

    private(set) var cliStatus: AWSCLIStatus?
    private(set) var checkingCLI = false
    private(set) var installing = false
    private(set) var installProgress: CLIInstallProgress?
    private(set) var installOutcome: CLIInstallOutcome?

    // MARK: Signing in

    var region: String
    private(set) var useExisting = false
    private(set) var existingProfile: String?
    var remote = false
    private(set) var signingIn = false
    private(set) var verifying = false
    private(set) var signInLink: AWSSignInLink?
    private(set) var signInError: String?
    private(set) var signInDetails: String?
    private(set) var identity: AWSCallerIdentity?
    private(set) var signInLog = ""
    /// The CLI's remote mode is waiting for the code AWS shows after signing in on another device.
    private(set) var awaitingCode = false
    var authorizationCode = ""

    // MARK: Models

    private(set) var models: [BedrockModel]?
    private(set) var loadingModels = false
    private(set) var modelsError: String?
    var search = ""
    var showAll = false
    private(set) var selected: BedrockModel?
    private(set) var access: ModelAccess?
    private(set) var checking = false
    /// What is already known about models' readiness (checked in the background for the recommended ones),
    /// so the list can say "Ready" before you pick.
    private(set) var readiness: [String: ModelAccess] = [:]
    /// The chosen model needed nothing: Back from Connect returns to the model list.
    private var skippedAccess = false

    // MARK: Enabling a model

    private(set) var working = false
    private(set) var workStatus: String?
    private(set) var workError: String?
    var acceptTerms = false
    var answers = UseCaseAnswers()

    // MARK: Connecting

    private(set) var connecting = false
    private(set) var connected = false
    private(set) var hello: String?
    private(set) var connectError: String?
    /// How the saved route is used. Changing it after connecting re-arranges the fleet at once.
    var role: RouteRole {
        didSet { if oldValue != role, connected { applyRole() } }
    }
    private var savedRoute: ProviderProfile?
    /// Who led before this route was saved, so choosing "subagent server" hands the lead back.
    private var previousMainRoute: String?

    // MARK: Done

    private(set) var apiKey: String?
    private(set) var apiKeyError: String?
    private(set) var mintingKey = false
    private(set) var savedKeyToVault = false

    // MARK: Tasks

    @ObservationIgnored private var cliTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var modelsTask: Task<Void, Never>?
    @ObservationIgnored private var precheckTask: Task<Void, Never>?
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var codeContinuation: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var disposed = false

    // MARK: - Setup

    init(backend: any BedrockGuideBackend, config: AppConfig, start: BedrockPage = .welcome, route: ProviderProfile? = nil) {
        self.backend = backend
        self.config = config
        self.editing = route.flatMap { $0.kind == .bedrock ? $0 : nil }
        page = start
        let suggested = backend.defaultRegion()
        region = suggested.flatMap { code in BedrockRegions.common.contains { $0.code == code } ? code : nil }
            ?? BedrockRegions.defaultRegion
        // Re-running the guide for a Bedrock route (or with one already active) starts from its profile and Region.
        let known = route.flatMap { $0.kind == .bedrock ? $0 : nil }
            ?? config.mainRoute.flatMap { $0.kind == .bedrock ? $0 : nil }
        if let known {
            if let code = known.awsRegion, !code.isEmpty { region = code }
            if let profile = known.awsProfile, !profile.isEmpty, profile != AWSSignIn.defaultProfile {
                useExisting = true
                existingProfile = profile
            }
        }
        role = Self.initialRole(editing: editing, config: config)
    }

    /// A new route leads when nothing does yet; otherwise it starts as a helper (one click to change). A route
    /// being changed keeps the role it has.
    static func initialRole(editing: ProviderProfile?, config: AppConfig) -> RouteRole {
        if let editing {
            return editing.routeID == config.activeRoute || !editing.isSubagentWorker ? .main : .subagents
        }
        return config.mainRoute == nil ? .main : .subagents
    }

    /// How to run the CLI from Terminal: its full path when it isn't one Terminal finds by itself (a
    /// per-user install lands in ~/aws-cli), else just "aws".
    var cliCommand: String {
        guard let path = cliStatus?.path else { return "aws" }
        return ["/usr/local/bin/aws", "/opt/homebrew/bin/aws", "/usr/bin/aws"].contains(path) ? "aws" : path
    }

    /// The AWS CLI profile this guide signs in with and saves on the route.
    var profileName: String {
        useExisting ? (existingProfile.flatMap { $0.isEmpty ? nil : $0 } ?? AWSSignIn.defaultProfile) : AWSSignIn.defaultProfile
    }

    /// Shown when the guide opens: opened past the CLI page (Settings ▸ Models: change the model, sign in
    /// again), it finds the CLI and checks the sign-in first; if either is missing, that page comes first.
    func activate() {
        if page > .cli, cliStatus == nil {
            Task { await resume(at: page) }
        } else {
            onShown()
        }
    }

    private func resume(at start: BedrockPage) async {
        await checkCLI()
        guard !disposed, page == start else { return }
        guard cliStatus?.isReady == true else { go(.cli); return }
        // Past the sign-in page: make sure the sign-in still works before showing what depends on it.
        if start > .signIn, identity == nil {
            verifying = true
            defer { verifying = false }
            do {
                identity = try await backend.verify(profile: profileName, region: region)
            } catch {
                guard !disposed, page == start else { return }
                signInError = "Your AWS sign-in has ended. Sign in again to carry on."
                go(.signIn)
                return
            }
        }
        onShown()
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        for task in [cliTask, installTask, verifyTask, signInTask, modelsTask, precheckTask, accessTask, waitTask, connectTask] {
            task?.cancel()
        }
        codeContinuation?.resume(returning: nil)
        codeContinuation = nil
    }

    // MARK: - Navigation

    var nextLabel: String {
        switch page {
        case .welcome: "Let's start"
        case .model: access?.isReady == true ? "Use this model" : "Next"
        case .done: "Start chatting"
        default: "Next"
        }
    }

    var canAdvance: Bool {
        switch page {
        case .cli:
            return cliStatus?.isReady == true && !installing && !checkingCLI
        case .signIn:
            return identity != nil && !signingIn
        case .model:
            guard let access, selected != nil, !checking else { return false }
            switch access.state {
            case .ready, .needsUseCaseForm, .needsAgreement, .pending: return true
            default: return false
            }
        case .access:
            return access?.isReady == true && !working
        case .connect:
            return connected && !connecting
        default:
            return true
        }
    }

    func next() {
        guard canAdvance else { return }
        switch page {
        case .model:
            skippedAccess = access?.isReady == true
            go(skippedAccess ? .connect : .access)
        case .done:
            onFinish()
        default:
            if let following = BedrockPage(rawValue: page.rawValue + 1) { go(following) }
        }
    }

    func back() {
        if page == .welcome {
            onLeave()
            return
        }
        let previous = (page == .connect && skippedAccess) ? BedrockPage.model : BedrockPage(rawValue: page.rawValue - 1)
        go(previous ?? .welcome)
    }

    func go(_ target: BedrockPage) {
        onHidden()
        page = target
        onShown()
    }

    private func onShown() {
        switch page {
        case .cli:
            if cliStatus == nil, !checkingCLI { cliTask = Task { await checkCLI() } }
        case .signIn:
            if identity == nil, !signingIn, !verifying { verifyTask = Task { await verifyExisting() } }
        case .model:
            if models == nil, !loadingModels { loadModels() }
        case .access:
            if access?.state == .pending, !working { waitForAccess() }
        case .connect:
            if !connected, !connecting { connect() }
        default:
            break
        }
    }

    private func onHidden() {
        // Leaving a page doesn't stop a sign-in in progress (the browser may be mid-way); it does stop waiting.
        waitTask?.cancel()
        waitTask = nil
    }

    // MARK: - The AWS CLI

    func checkCLI() async {
        checkingCLI = true
        defer { checkingCLI = false }
        cliStatus = await backend.checkCLI()
    }

    func recheckCLI() { cliTask = Task { await checkCLI() } }

    /// Install (or update) the CLI. `scope` chooses per-user, everyone or Homebrew.
    func installCLI(scope: CLIInstallScope = .currentUser) {
        guard !installing else { return }
        installing = true
        installOutcome = nil
        installProgress = CLIInstallProgress(stage: "Starting…")
        installTask = Task {
            let outcome = await backend.installCLI(scope: scope, current: cliStatus) { [weak self] progress in
                Task { @MainActor in self?.installProgress = progress }
            }
            installOutcome = outcome
            if let status = outcome.status { cliStatus = status }
            else if outcome.succeeded { cliStatus = await backend.checkCLI() }
            installing = false
            installTask = nil
        }
    }

    func stopInstalling() { installTask?.cancel() }

    // MARK: - Signing in

    private func resetSignIn() {
        identity = nil
        signInError = nil
        signInDetails = nil
        signInLink = nil
        resetModels()
    }

    private func resetModels() {
        modelsTask?.cancel()
        precheckTask?.cancel()
        accessTask?.cancel()
        models = nil
        selected = nil
        access = nil
        modelsError = nil
        readiness = [:]
        connected = false
        hello = nil
        savedRoute = nil
        skippedAccess = false
    }

    /// Choose the browser sign-in (the app's own `vision-bedrock` profile) or a profile that already exists.
    func setUseExisting(_ on: Bool) {
        guard on != useExisting else { return }
        if on {
            guard let first = backend.awsProfiles().first else { return }
            existingProfile = existingProfile ?? first.name
        }
        useExisting = on
        resetSignIn()
    }

    func setExistingProfile(_ name: String) {
        guard name != existingProfile else { return }
        existingProfile = name
        resetSignIn()
    }

    /// A new Region shows that Region's models; the sign-in stays (it isn't tied to a Region).
    func setRegion(_ code: String) {
        guard code != region else { return }
        region = code
        resetModels()
        if page == .model { loadModels() }
    }

    /// Already signed in (re-running the guide, or a CLI profile that works)? Then there's nothing to do
    /// on the sign-in page.
    func verifyExisting() async {
        guard cliStatus?.isReady == true else { return }
        let profile = profileName
        let kind = backend.awsProfiles().first { $0.name == profile }?.kind
        if !useExisting, kind != .loginSession { return }
        verifying = true
        defer { verifying = false }
        do {
            let found = try await backend.verify(profile: profile, region: region)
            if profile == profileName { identity = found }
        } catch {
            // Not signed in (or expired): the page offers to sign in.
        }
    }

    func signIn() {
        guard cliStatus?.isReady == true, !signingIn else { return }
        let profile = profileName
        signingIn = true
        signInError = nil
        signInDetails = nil
        signInLink = nil
        signInLog = ""
        awaitingCode = false
        let callbacks = SignInCallbacks(
            onOutput: { [weak self] line in Task { @MainActor in self?.signInLog += line + "\n" } },
            onLink: { [weak self] link in Task { @MainActor in self?.signInLink = link } },
            requestCode: { [weak self] link in await self?.requestCode(link) })
        signInTask = Task {
            defer {
                signingIn = false
                awaitingCode = false
                signInTask = nil
            }
            do {
                let result = try await performSignIn(profile: profile, callbacks: callbacks)
                if result.succeeded {
                    backend.invalidateCredentials(profile: profile)
                    identity = try await backend.verify(profile: profile, region: region)
                } else {
                    signInError = result.message
                    signInDetails = result.details
                }
            } catch is CancellationError {
                signInError = "Stopped. You can sign in again whenever you're ready."
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    /// The right kind of sign-in for the profile: IAM Identity Center for an SSO profile, nothing to do
    /// for one that signs in by itself (keys, a role, a program), the browser sign-in otherwise.
    private func performSignIn(profile: String, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        let kind = backend.awsProfiles().first { $0.name == profile }?.kind
        var result: AWSSignInResult
        switch kind {
        case .sso:
            result = try await backend.ssoLogin(profile: profile, remote: remote, callbacks: callbacks)
        case .accessKeys, .assumeRole, .credentialProcess, .webIdentity:
            result = AWSSignInResult(outcome: .signedIn, message: "This profile signs in by itself.")
        default:
            result = try await backend.login(profile: profile, region: region, remote: remote, callbacks: callbacks)
        }
        if result.outcome == .useSSOLogin {
            result = try await backend.ssoLogin(profile: profile, remote: remote, callbacks: callbacks)
        }
        return result
    }

    private func requestCode(_ link: AWSSignInLink) async -> String? {
        signInLink = link
        awaitingCode = true
        return await withCheckedContinuation { continuation in
            codeContinuation = continuation
        }
    }

    /// The user pasted the code AWS showed them.
    func submitCode() {
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let continuation = codeContinuation else { return }
        codeContinuation = nil
        awaitingCode = false
        authorizationCode = ""
        continuation.resume(returning: code)
    }

    func stopSignIn() {
        codeContinuation?.resume(returning: nil)
        codeContinuation = nil
        awaitingCode = false
        signInTask?.cancel()
    }

    // MARK: - Models

    func loadModels() {
        guard cliStatus?.isReady == true, !loadingModels else { return }
        loadingModels = true
        modelsError = nil
        let profile = profileName, code = region
        modelsTask?.cancel()
        modelsTask = Task {
            defer { loadingModels = false }
            do {
                let found = try await backend.listModels(profile: profile, region: code)
                guard !Task.isCancelled, code == region, profile == profileName else { return }
                models = found
                // Coming back to a Region that has the model chosen before keeps it.
                if let previous = selected {
                    selected = found.first { $0.modelID == previous.modelID }
                    if selected == nil { access = nil }
                }
                precheckRecommended(found, profile: profile, region: code)
            } catch is CancellationError {
            } catch let expired as AWSSignInRequiredError {
                guard !Task.isCancelled, code == region else { return }
                identity = nil
                signInError = expired.localizedDescription
                go(.signIn)
            } catch {
                guard !Task.isCancelled, code == region else { return }
                modelsError = Self.explain(error)
            }
        }
    }

    /// The models worth showing first: the recommended ones (or, failing that, the first few).
    var recommendedModels: [BedrockModel] {
        let callable = (models ?? []).filter(\.canInvoke)
        let recommended = callable.filter(\.recommended)
        return recommended.isEmpty ? Array(callable.prefix(6)) : recommended
    }

    /// Every model matching the search box, recommended ones first.
    var visibleModels: [BedrockModel] {
        let callable = (models ?? []).filter(\.canInvoke)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return callable }
        let matches = callable.filter {
            $0.name.lowercased().contains(needle) || $0.provider.lowercased().contains(needle)
                || $0.modelID.lowercased().contains(needle)
        }
        return matches.filter(\.recommended) + matches.filter { !$0.recommended }
    }

    var otherModels: [BedrockModel] {
        let first = Set(recommendedModels.map(\.modelID))
        return (models ?? []).filter { $0.canInvoke && !first.contains($0.modelID) }
    }

    /// Check the recommended models' readiness in the background (three at a time), so the list can show
    /// which are ready to use before anything is picked. Failures are silent: picking a model checks it.
    private func precheckRecommended(_ found: [BedrockModel], profile: String, region code: String) {
        precheckTask?.cancel()
        let targets = recommendedModels.filter { readiness[$0.modelID] == nil }
        guard !targets.isEmpty else { return }
        precheckTask = Task {
            await withTaskGroup(of: (String, ModelAccess?).self) { group in
                var index = 0
                while index < targets.count && index < 3 {
                    let model = targets[index]
                    index += 1
                    group.addTask { await self.precheck(model, profile: profile, region: code) }
                }
                for await (id, result) in group {
                    if !Task.isCancelled, code == region, let result { readiness[id] = result }
                    if index < targets.count {
                        let model = targets[index]
                        index += 1
                        group.addTask { await self.precheck(model, profile: profile, region: code) }
                    }
                }
            }
        }
    }

    private func precheck(_ model: BedrockModel, profile: String, region code: String) async -> (String, ModelAccess?) {
        (model.modelID, try? await backend.checkAccess(profile: profile, region: code, model: model))
    }

    func choose(_ model: BedrockModel) {
        guard !checking || selected?.modelID != model.modelID else { return }
        selected = model
        access = nil
        connected = false
        hello = nil
        savedRoute = nil
        workError = nil
        acceptTerms = false
        accessTask?.cancel()
        guard model.canInvoke else { return }
        // A model already known to be ready needs no second look.
        if let known = readiness[model.modelID], known.isReady {
            access = known
            return
        }
        checkAccess(of: model)
    }

    func recheckSelected() { if let selected { checkAccess(of: selected) } }

    private func checkAccess(of model: BedrockModel) {
        let profile = profileName, code = region
        checking = true
        accessTask?.cancel()
        accessTask = Task {
            defer { if selected?.modelID == model.modelID { checking = false } }
            do {
                let found = try await backend.checkAccess(profile: profile, region: code, model: model)
                guard selected?.modelID == model.modelID, !Task.isCancelled else { return }
                access = found
                readiness[model.modelID] = found
            } catch is CancellationError {
            } catch {
                guard selected?.modelID == model.modelID, !Task.isCancelled else { return }
                access = ModelAccess(state: .error, modelID: model.modelID, message: Self.explain(error))
            }
        }
    }

    /// A sentence for an error, with the permission it needs when AWS said which.
    static func explain(_ error: Error) -> String {
        if let cli = error as? AWSCLIException {
            if let permission = cli.error.permission { return "\(cli.error.message) (It needs the \(permission) permission.)" }
            return cli.error.message
        }
        return AppTransport.describe(error)
    }

    // MARK: - Enabling a model

    func submitUseCase() {
        guard let model = selected else { return }
        if let problem = answers.problem {
            workError = problem
            return
        }
        working = true
        workError = nil
        workStatus = "Sending the form to AWS…"
        let profile = profileName, code = region, form = answers
        waitTask?.cancel()
        waitTask = Task {
            defer { working = false }
            do {
                let outcome = try await backend.submitUseCase(profile: profile, region: code, answers: form)
                workStatus = outcome == .alreadyOnFile
                    ? "Your account already has this form on file. Checking the model…"
                    : "Sent. Checking the model…"
                try await waitCore(model: model, profile: profile, region: code)
            } catch is CancellationError {
            } catch {
                workError = Self.explain(error)
            }
        }
    }

    func acceptAgreement() {
        guard let model = selected, let offer = access?.offer, acceptTerms else { return }
        working = true
        workError = nil
        workStatus = "Accepting the terms for your AWS account…"
        let profile = profileName, code = region
        waitTask?.cancel()
        waitTask = Task {
            defer { working = false }
            do {
                try await backend.acceptAgreement(profile: profile, region: code, modelID: model.modelID, offerToken: offer.offerToken)
                workStatus = "Accepted. AWS is setting the model up — this can take up to 15 minutes…"
                try await waitCore(model: model, profile: profile, region: code)
            } catch is CancellationError {
            } catch {
                workError = Self.explain(error)
            }
        }
    }

    func waitForAccess() {
        guard let model = selected else { return }
        working = true
        workError = nil
        workStatus = "AWS is finishing setting this model up for your account — up to 15 minutes. You can leave this page open."
        let profile = profileName, code = region
        waitTask?.cancel()
        waitTask = Task {
            defer { working = false }
            do {
                try await waitCore(model: model, profile: profile, region: code)
            } catch is CancellationError {
            } catch {
                workError = Self.explain(error)
            }
        }
    }

    private func waitCore(model: BedrockModel, profile: String, region code: String) async throws {
        let result = try await backend.waitUntilReady(profile: profile, region: code, model: model) { [weak self] found in
            Task { @MainActor in
                guard let self, self.selected?.modelID == model.modelID else { return }
                self.access = found
                if !found.isReady { self.workStatus = found.message }
            }
        }
        try Task.checkCancellation()
        access = result
        readiness[model.modelID] = result
        if result.isReady {
            workError = nil
        } else if result.state == .pending {
            workError = "AWS hasn't finished yet. That can happen with a first subscription — press Check again in a few minutes."
        } else {
            workError = result.message
        }
    }

    // MARK: - Connecting

    /// The route this guide saves for the chosen model.
    func profile(for model: BedrockModel) -> ProviderProfile {
        var route = ProviderProfile(kind: .bedrock, name: routeName(for: model),
                                    baseURL: "https://bedrock-runtime.\(region).amazonaws.com",
                                    model: model.invokeID ?? model.modelID,
                                    vision: model.acceptsImages,
                                    awsProfile: profileName, awsRegion: region)
        if let old = editing {
            // Changing a route's model must not undo how the user set it up.
            route.temperature = old.temperature
            route.maxOutputTokens = old.maxOutputTokens
            route.contextWindow = old.contextWindow
            route.reasoningEffort = old.reasoningEffort
            route.customHeaders = old.customHeaders
            route.subagentWorker = old.subagentWorker
            route.subagentParallel = old.subagentParallel
        }
        return route
    }

    /// "Bedrock · Claude Sonnet 4.5" — told apart from another Bedrock route in the model menu and next
    /// to a subagent. A route the user renamed keeps its name.
    private func routeName(for model: BedrockModel) -> String {
        if let old = editing, !(old.name.hasPrefix("Bedrock") || old.name.hasPrefix("Amazon Bedrock")) { return old.name }
        return "Bedrock · \(model.name)"
    }

    func connect() {
        guard let model = selected, !connecting else { return }
        connecting = true
        connectError = nil
        let route = profile(for: model)
        connectTask = Task {
            defer { connecting = false }
            do {
                hello = try await backend.sayHello(route: route)
                save(route)
                connected = true
            } catch is CancellationError {
            } catch {
                connectError = Self.explain(error)
            }
        }
    }

    /// Save the route where it belongs in the arrangement: in place of the route being changed, or as a new
    /// route in the role the user chose.
    private func save(_ route: ProviderProfile) {
        var saved = route
        if let old = editing {
            config.replace(old, with: saved)
        } else {
            previousMainRoute = config.activeRoute
            saved.subagentWorker = role == .subagents ? true : saved.subagentWorker
            config.store(saved)
            if role == .main || config.mainRoute == nil { config.makeMain(saved.routeID) }
        }
        savedRoute = saved
        onSaved(saved)
    }

    /// The role picker changed after the route was saved: re-arrange the fleet at once.
    private func applyRole() {
        guard let route = savedRoute, editing == nil else { return }
        switch role {
        case .main:
            // Only the default for new chats changes: no route's "Use for subagents" tick does.
            config.makeMain(route.routeID)
        case .subagents:
            config.setSubagentWorker(route.routeID, true)
            if config.activeRoute == route.routeID {
                // Hand the lead back to whoever had it, or to any other route.
                let successor = previousMainRoute.flatMap { id in config.providers.first { $0.routeID == id } }
                    ?? config.providers.first { $0.routeID != route.routeID }
                if let successor { config.makeMain(successor.routeID) }
            }
        }
        onSaved(route)
    }

    /// Whether the role choice is meaningful: there is another route to lead or to help.
    var hasOtherRoutes: Bool { config.providers.contains { $0.routeID != savedRoute?.routeID } }

    // MARK: - Done

    func createAPIKey() {
        guard !mintingKey else { return }
        mintingKey = true
        apiKeyError = nil
        let profile = profileName, code = region
        Task {
            defer { mintingKey = false }
            do {
                apiKey = try await backend.createAPIKey(profile: profile, region: code)
            } catch {
                apiKeyError = Self.explain(error)
            }
        }
    }

    func saveKeyToVault() {
        guard let key = apiKey else { return }
        do {
            try backend.saveKeyToVault(key, region: region)
            apiKey = nil
            apiKeyError = nil
            savedKeyToVault = true
        } catch {
            apiKeyError = error.localizedDescription
        }
    }
}
