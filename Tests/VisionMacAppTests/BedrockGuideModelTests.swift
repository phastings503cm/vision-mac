import XCTest
import VisionHarnessCore
@testable import VisionMacApp

// MARK: - A scripted backend

/// Everything the guide asks of AWS and the machine, answered from a script, recording what was asked.
@MainActor
final class FakeBedrockBackend: BedrockGuideBackend {
    var cli: AWSCLIStatus = .ready(version: SemanticVersion(2, 33, 4), path: "/usr/local/bin/aws")
    var installResult = CLIInstallOutcome(succeeded: true, message: "Installed.",
                                          status: .ready(version: SemanticVersion(2, 33, 4), path: "/Users/me/.local/bin/aws"))
    var installProblem: String?
    var homebrewAvailable = false
    var profiles: [AWSProfile] = []
    var region: String?
    var identity = AWSCallerIdentity(account: "123456789012", arn: "arn:aws:iam::123456789012:user/alice", userID: "AIDAEXAMPLE")
    var signedIn = false
    var loginResult = AWSSignInResult(outcome: .signedIn, message: "Signed in to AWS.")
    var ssoResult = AWSSignInResult(outcome: .signedIn, message: "Signed in to AWS IAM Identity Center.")
    var models: [BedrockModel] = []
    var listError: Error?
    var access: [String: ModelAccess] = [:]
    var accessError: Error?
    var useCaseOutcome: UseCaseOutcome = .submitted
    var useCaseError: Error?
    var agreementError: Error?
    /// What `waitUntilReady` returns, in order (the last one repeats).
    var waitResults: [ModelAccess] = []
    var helloText = "Hello! I'm running on Amazon Bedrock."
    var helloError: Error?
    var apiKey = "bedrock-api-key-abc"
    var vaultError: Error?
    private(set) var calls: [String] = []
    private(set) var savedKeys: [String] = []
    private(set) var opened: [URL] = []
    private(set) var hellos: [ProviderProfile] = []
    /// When set, `login` suspends here until the test resumes it.
    var loginGate: (@Sendable () async -> Void)?

    func checkCLI() async -> AWSCLIStatus { calls.append("checkCLI"); return cli }

    func installCLI(scope: CLIInstallScope, current: AWSCLIStatus?,
                    progress: @escaping @Sendable (CLIInstallProgress) -> Void) async -> CLIInstallOutcome {
        calls.append("install:\(scope)")
        progress(CLIInstallProgress(stage: "Downloading", fraction: 0.5, detail: nil))
        return installResult
    }

    func awsProfiles() -> [AWSProfile] { profiles }
    func defaultRegion() -> String? { region }

    func verify(profile: String, region: String) async throws -> AWSCallerIdentity {
        calls.append("verify:\(profile):\(region)")
        if signedIn { return identity }
        throw AWSSignInRequiredError(profile: profile, message: "Not signed in.")
    }

    func login(profile: String, region: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        calls.append("login:\(profile):\(region)\(remote ? ":remote" : "")")
        callbacks.onOutput("Attempting to open your default browser.")
        if let loginGate { await loginGate() }
        try Task.checkCancellation()
        if remote {
            let link = AWSSignInLink(url: URL(string: "https://signin.aws.amazon.com/authorize?x=1")!, userCode: nil)
            callbacks.onLink(link)
            guard let code = await callbacks.requestCode(link) else {
                return AWSSignInResult(outcome: .cancelled, message: "Stopped.")
            }
            calls.append("code:\(code)")
        }
        if loginResult.succeeded { signedIn = true }
        return loginResult
    }

    func ssoLogin(profile: String, remote: Bool, callbacks: SignInCallbacks) async throws -> AWSSignInResult {
        calls.append("sso:\(profile)")
        if ssoResult.succeeded { signedIn = true }
        return ssoResult
    }

    func invalidateCredentials(profile: String) { calls.append("invalidate:\(profile)") }

    func listModels(profile: String, region: String) async throws -> [BedrockModel] {
        calls.append("list:\(profile):\(region)")
        if let listError { throw listError }
        return models
    }

    func checkAccess(profile: String, region: String, model: BedrockModel) async throws -> ModelAccess {
        calls.append("access:\(model.modelID)")
        if let accessError { throw accessError }
        return access[model.modelID] ?? ModelAccess(state: .ready, modelID: model.modelID, message: "Your account can use this model.")
    }

    func submitUseCase(profile: String, region: String, answers: UseCaseAnswers) async throws -> UseCaseOutcome {
        calls.append("usecase:\(answers.company)")
        if let useCaseError { throw useCaseError }
        return useCaseOutcome
    }

    func acceptAgreement(profile: String, region: String, modelID: String, offerToken: String) async throws {
        calls.append("accept:\(modelID):\(offerToken)")
        if let agreementError { throw agreementError }
    }

    func waitUntilReady(profile: String, region: String, model: BedrockModel,
                        progress: @escaping @Sendable (ModelAccess) -> Void) async throws -> ModelAccess {
        calls.append("wait:\(model.modelID)")
        let results = waitResults.isEmpty ? [ModelAccess(state: .ready, modelID: model.modelID, message: "Ready.")] : waitResults
        for step in results.dropLast() { progress(step) }
        return results.last!
    }

    func sayHello(route: ProviderProfile) async throws -> String {
        calls.append("hello:\(route.model)")
        hellos.append(route)
        if let helloError { throw helloError }
        return helloText
    }

    func createAPIKey(profile: String, region: String) async throws -> String { calls.append("apikey:\(region)"); return apiKey }

    func saveKeyToVault(_ key: String, region: String) throws {
        if let vaultError { throw vaultError }
        savedKeys.append(key)
    }

    func open(_ url: URL) { opened.append(url) }
}

// MARK: - Fixtures

func bedrockModel(_ id: String, _ name: String, provider: String = "Anthropic", recommended: Bool = false,
                  invoke: String? = nil, images: Bool = true) -> BedrockModel {
    BedrockModel(modelID: id, name: name, provider: provider, inputModalities: images ? ["TEXT", "IMAGE"] : ["TEXT"],
                 streaming: true, lifecycle: "ACTIVE", inferenceTypes: ["INFERENCE_PROFILE"],
                 invokeID: invoke ?? "us.\(id)", recommended: recommended)
}

@MainActor
final class BedrockGuideModelTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private let sonnet = bedrockModel("anthropic.claude-sonnet-4-5-20250929-v1:0", "Claude Sonnet 4.5", recommended: true)
    private let opus = bedrockModel("anthropic.claude-opus-4-1-20250805-v1:0", "Claude Opus 4.1", recommended: true)
    private let nova = bedrockModel("amazon.nova-pro-v1:0", "Nova Pro", provider: "Amazon", recommended: true, invoke: "amazon.nova-pro-v1:0")
    private let mistral = bedrockModel("mistral.mistral-large-2407-v1:0", "Mistral Large (24.07)", provider: "Mistral AI",
                                       invoke: "mistral.mistral-large-2407-v1:0", images: false)

    private func config(_ routes: [ProviderProfile] = [], main: String? = nil) -> AppConfig {
        let suite = "vision.guide.test.\(UUID().uuidString)"
        suites.append(suite)
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = main ?? routes.first?.routeID
        return config
    }

    private func spark(_ name: String = "Spark 1") -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(name.lowercased().replacingOccurrences(of: " ", with: "")).local:8002/v1", model: "qwen3.8")
    }

    private func make(_ backend: FakeBedrockBackend, config: AppConfig? = nil, start: BedrockPage = .welcome,
                      route: ProviderProfile? = nil) -> BedrockGuideModel {
        backend.models = backend.models.isEmpty ? [sonnet, opus, nova, mistral] : backend.models
        return BedrockGuideModel(backend: backend, config: config ?? self.config(), start: start, route: route)
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Walk a fresh guide to the model page, signed in.
    private func onModelPage(_ backend: FakeBedrockBackend, config: AppConfig? = nil) async throws -> BedrockGuideModel {
        backend.signedIn = true
        backend.profiles = [AWSProfile(name: "vision-bedrock", kind: .loginSession, region: "us-east-1", settings: [:])]
        let guide = make(backend, config: config)
        guide.activate()
        guide.next()                                    // welcome → cli
        try await until("cli checked") { guide.cliStatus != nil }
        guide.next()                                    // cli → sign in
        try await until("verified") { guide.identity != nil }
        guide.next()                                    // sign in → model
        XCTAssertEqual(guide.page, .model)
        try await until("models loaded") { guide.models != nil }
        return guide
    }

    // MARK: Starting up

    func testARegionFromTheUsersAWSConfigIsUsedIfBedrockOffersItElseTheDefault() {
        let backend = FakeBedrockBackend()
        backend.region = "eu-west-1"
        XCTAssertEqual(make(backend).region, "eu-west-1")
        backend.region = "mars-north-1"
        XCTAssertEqual(make(backend).region, BedrockRegions.defaultRegion)
    }

    func testTheGuideStartsFromTheProfileAndRegionOfAnExistingBedrockRoute() {
        let route = ProviderProfile(kind: .bedrock, name: "Bedrock · Claude", baseURL: "https://x", model: "m",
                                    awsProfile: "work-sso", awsRegion: "eu-central-1")
        let guide = make(FakeBedrockBackend(), config: config([route]), route: route)
        XCTAssertEqual(guide.region, "eu-central-1")
        XCTAssertTrue(guide.useExisting)
        XCTAssertEqual(guide.profileName, "work-sso")
        XCTAssertEqual(make(FakeBedrockBackend()).profileName, AWSSignIn.defaultProfile)
    }

    /// Legacy: a route set up before the rename names the old app profile (`dsh-bedrock`). It keeps it — the
    /// sign-in is already there — while a new setup signs in as `vision-bedrock`.
    func testARouteSetUpBeforeTheRenameKeepsItsProfile() {
        let route = ProviderProfile(kind: .bedrock, name: "Bedrock · Claude", baseURL: "https://x", model: "m",
                                    awsProfile: AppIdentity.Legacy.awsProfile, awsRegion: "us-west-2")
        let guide = make(FakeBedrockBackend(), config: config([route]), route: route)
        XCTAssertTrue(guide.useExisting)
        XCTAssertEqual(guide.profileName, "dsh-bedrock")
        XCTAssertEqual(make(FakeBedrockBackend()).profileName, "vision-bedrock")
    }

    // MARK: The AWS CLI

    func testTheCLIPageWaitsForAWorkingCLI() async throws {
        let backend = FakeBedrockBackend()
        backend.cli = .missing
        let guide = make(backend)
        guide.activate()
        guide.next()
        XCTAssertEqual(guide.page, .cli)
        try await until("checked") { guide.cliStatus != nil }
        XCTAssertFalse(guide.canAdvance)
        guide.next()
        XCTAssertEqual(guide.page, .cli, "cannot move on without the CLI")

        guide.installCLI()
        try await until("installed") { !guide.installing }
        XCTAssertEqual(guide.cliStatus?.isReady, true)
        XCTAssertTrue(guide.canAdvance)
        XCTAssertTrue(backend.calls.contains("install:currentUser"))
    }

    func testAFailedInstallOffersHomebrewOnlyWhenItCanHelp() async throws {
        let backend = FakeBedrockBackend()
        backend.cli = .missing
        backend.installResult = CLIInstallOutcome(succeeded: false, message: "The installer failed.", canTryHomebrew: true)
        let guide = make(backend)
        guide.go(.cli)
        try await until("checked") { guide.cliStatus != nil }
        guide.installCLI()
        try await until("failed") { !guide.installing }
        XCTAssertEqual(guide.installOutcome?.canTryHomebrew, true)
        XCTAssertNotEqual(guide.cliStatus?.isReady, true)
        XCTAssertFalse(guide.canAdvance)
    }

    // MARK: Signing in

    func testSigningInWithTheBrowserSignsInAndThenChecksWhoItIs() async throws {
        let backend = FakeBedrockBackend()
        let guide = make(backend)
        guide.go(.cli)
        try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        XCTAssertFalse(guide.canAdvance)
        guide.signIn()
        try await until("signed in") { guide.identity != nil }
        XCTAssertEqual(backend.calls.filter { $0.hasPrefix("login") || $0.hasPrefix("invalidate") || $0.hasPrefix("verify") },
                       ["login:vision-bedrock:us-east-1", "invalidate:vision-bedrock", "verify:vision-bedrock:us-east-1"],
                       "signs in, forgets the cached credentials, then asks who it is")
        XCTAssertTrue(guide.canAdvance)
        XCTAssertTrue(guide.signInLog.contains("Attempting to open your default browser"))
    }

    func testAnAlreadySignedInProfileNeedsNoSignIn() async throws {
        let backend = FakeBedrockBackend()
        backend.signedIn = true
        backend.profiles = [AWSProfile(name: "vision-bedrock", kind: .loginSession, region: "us-east-1", settings: [:])]
        let guide = make(backend)
        guide.go(.cli)
        try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        try await until("recognised") { guide.identity != nil }
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("login") }, "nothing to sign in")
    }

    func testAnSSOProfileSignsInThroughIdentityCenter() async throws {
        let backend = FakeBedrockBackend()
        backend.profiles = [AWSProfile(name: "corp", kind: .sso, region: "us-west-2", settings: [:])]
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.setUseExisting(true)
        XCTAssertEqual(guide.profileName, "corp")
        guide.go(.signIn)
        guide.signIn()
        try await until("signed in") { guide.identity != nil }
        XCTAssertTrue(backend.calls.contains("sso:corp"))
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("login:") })
    }

    func testAProfileWithKeysOrARoleIsJustChecked() async throws {
        let backend = FakeBedrockBackend()
        backend.signedIn = true
        backend.profiles = [AWSProfile(name: "keys", kind: .accessKeys, region: "us-east-1", settings: [:])]
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.setUseExisting(true)
        guide.go(.signIn)
        try await until("verified on arrival") { guide.identity != nil }
        guide.signIn()
        try await until("still fine") { !guide.signingIn }
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("login:") || $0.hasPrefix("sso:") })
    }

    func testABrowserSignInThatTurnsOutToBeSSOFallsBackToIdentityCenter() async throws {
        let backend = FakeBedrockBackend()
        backend.loginResult = AWSSignInResult(outcome: .useSSOLogin, message: "Use SSO.")
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        guide.signIn()
        try await until("signed in") { guide.identity != nil }
        XCTAssertTrue(backend.calls.contains("sso:vision-bedrock"))
    }

    func testAFailedSignInShowsWhyAndStaysOnThePage() async throws {
        let backend = FakeBedrockBackend()
        backend.loginResult = AWSSignInResult(outcome: .notAllowed, message: "Your identity may not create CLI sessions.", details: "signin:CreateOAuth2Token")
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        guide.signIn()
        try await until("finished") { !guide.signingIn }
        XCTAssertNil(guide.identity)
        XCTAssertEqual(guide.signInError, "Your identity may not create CLI sessions.")
        XCTAssertEqual(guide.signInDetails, "signin:CreateOAuth2Token")
        XCTAssertFalse(guide.canAdvance)
    }

    func testRemoteSignInAsksForTheCodeAndContinuesWhenItIsPasted() async throws {
        let backend = FakeBedrockBackend()
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        guide.remote = true
        guide.signIn()
        try await until("waiting for the code") { guide.awaitingCode }
        XCTAssertNotNil(guide.signInLink)
        guide.authorizationCode = "  ABCD-1234 \n"
        guide.submitCode()
        try await until("signed in") { guide.identity != nil }
        XCTAssertTrue(backend.calls.contains("code:ABCD-1234"), "the code is trimmed")
        XCTAssertFalse(guide.awaitingCode)
    }

    func testStoppingWhileTheCodeIsAwaitedEndsTheSignInQuietly() async throws {
        let backend = FakeBedrockBackend()
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.go(.signIn)
        guide.remote = true
        guide.signIn()
        try await until("waiting for the code") { guide.awaitingCode }
        guide.stopSignIn()
        try await until("stopped") { !guide.signingIn }
        XCTAssertNil(guide.identity)
    }

    func testChangingTheProfileOrTheSignInMethodForgetsTheOldIdentityAndModels() async throws {
        let backend = FakeBedrockBackend()
        backend.profiles = [AWSProfile(name: "corp", kind: .sso, region: nil, settings: [:])]
        let guide = try await onModelPage(backend)
        XCTAssertNotNil(guide.identity)
        XCTAssertNotNil(guide.models)
        guide.setUseExisting(true)
        XCTAssertNil(guide.identity)
        XCTAssertNil(guide.models)
        XCTAssertNil(guide.selected)
    }

    // MARK: Picking a model

    func testTheRecommendedModelsComeFirstAndTheRestAreOneClickAway() async throws {
        let guide = try await onModelPage(FakeBedrockBackend())
        XCTAssertEqual(guide.recommendedModels.map(\.name), ["Claude Sonnet 4.5", "Claude Opus 4.1", "Nova Pro"])
        XCTAssertEqual(guide.otherModels.map(\.name), ["Mistral Large (24.07)"])
    }

    func testWithNothingRecommendedTheFirstFewAreShown() async throws {
        let backend = FakeBedrockBackend()
        backend.models = (1...9).map { bedrockModel("vendor.model-\($0)", "Model \($0)", provider: "Vendor") }
        let guide = try await onModelPage(backend)
        XCTAssertEqual(guide.recommendedModels.count, 6)
        XCTAssertEqual(guide.otherModels.count, 3)
    }

    func testAModelWithNoWayToBeCalledIsNotOffered() async throws {
        let backend = FakeBedrockBackend()
        var uncallable = bedrockModel("vendor.legacy", "Legacy", provider: "Vendor")
        uncallable.invokeID = nil
        backend.models = [sonnet, uncallable]
        let guide = try await onModelPage(backend)
        XCTAssertEqual((guide.recommendedModels + guide.otherModels).map(\.name), ["Claude Sonnet 4.5"])
    }

    func testTheRecommendedModelsAreCheckedInTheBackgroundSoTheListCanSayWhichAreReady() async throws {
        let backend = FakeBedrockBackend()
        backend.access[opus.modelID] = ModelAccess(state: .needsUseCaseForm, modelID: opus.modelID, message: "Anthropic needs the form.")
        let guide = try await onModelPage(backend)
        try await until("prechecked") { guide.readiness.count == 3 }
        XCTAssertEqual(guide.readiness[sonnet.modelID]?.state, .ready)
        XCTAssertEqual(guide.readiness[opus.modelID]?.state, .needsUseCaseForm)
        XCTAssertNil(guide.readiness[mistral.modelID], "only the recommended ones are checked ahead of time")
    }

    func testPickingAModelAlreadyKnownToBeReadyDoesNotCheckItAgain() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await onModelPage(backend)
        try await until("prechecked") { guide.readiness[sonnet.modelID] != nil }
        let before = backend.calls.filter { $0 == "access:\(sonnet.modelID)" }.count
        guide.choose(sonnet)
        XCTAssertEqual(guide.access?.state, .ready, "instant")
        XCTAssertEqual(backend.calls.filter { $0 == "access:\(sonnet.modelID)" }.count, before)
        XCTAssertTrue(guide.canAdvance)
        XCTAssertEqual(guide.nextLabel, "Use this model")
    }

    func testPickingAModelThatWasNotReadyChecksItFresh() async throws {
        let backend = FakeBedrockBackend()
        backend.access[mistral.modelID] = ModelAccess(state: .needsAgreement, modelID: mistral.modelID, message: "Terms.",
                                                      offer: ModelOffer(offerToken: "tok"))
        let guide = try await onModelPage(backend)
        guide.choose(mistral)
        XCTAssertTrue(guide.checking)
        XCTAssertFalse(guide.canAdvance, "not while it is being checked")
        try await until("checked") { !guide.checking }
        XCTAssertEqual(guide.access?.state, .needsAgreement)
        XCTAssertTrue(guide.canAdvance, "there is a next step: accept the terms")
        XCTAssertEqual(guide.nextLabel, "Next")
    }

    func testAModelThisAccountIsNotAllowedToUseCannotBeAdvancedWith() async throws {
        let backend = FakeBedrockBackend()
        backend.access[sonnet.modelID] = ModelAccess(state: .notAuthorized, modelID: sonnet.modelID, message: "Denied.",
                                                     missingPermissions: ["bedrock:InvokeModel"])
        let guide = try await onModelPage(backend)
        try await until("prechecked") { guide.readiness[sonnet.modelID] != nil }
        guide.choose(sonnet)
        try await until("checked") { !guide.checking && guide.access != nil }
        XCTAssertFalse(guide.canAdvance)
    }

    func testAFailedCheckShowsTheErrorAndCanBeRetried() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await onModelPage(backend)
        backend.accessError = AWSCLIException(AWSCLIError(kind: .network, message: "Vision couldn't reach AWS."))
        guide.choose(mistral)
        try await until("failed") { !guide.checking && guide.access != nil }
        XCTAssertEqual(guide.access?.state, .error)
        XCTAssertEqual(guide.access?.message, "Vision couldn't reach AWS.")
        backend.accessError = nil
        guide.recheckSelected()
        try await until("recovered") { guide.access?.state == .ready }
    }

    func testTheSearchBoxFiltersByNameMakerAndIdWithRecommendedFirst() async throws {
        let guide = try await onModelPage(FakeBedrockBackend())
        guide.search = "claude"
        XCTAssertEqual(guide.visibleModels.map(\.name), ["Claude Sonnet 4.5", "Claude Opus 4.1"])
        guide.search = "  MISTRAL "
        XCTAssertEqual(guide.visibleModels.map(\.name), ["Mistral Large (24.07)"])
        guide.search = "amazon"
        XCTAssertEqual(guide.visibleModels.map(\.name), ["Nova Pro"])
        guide.search = "nothing like this"
        XCTAssertTrue(guide.visibleModels.isEmpty)
        guide.search = ""
        XCTAssertEqual(guide.visibleModels.count, 4)
    }

    func testChangingTheRegionOnTheModelPageReloadsThatRegionsModels() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await onModelPage(backend)
        guide.choose(sonnet)
        guide.setRegion("eu-west-1")
        XCTAssertEqual(guide.region, "eu-west-1")
        XCTAssertNil(guide.selected, "the choice belonged to the old Region")
        XCTAssertTrue(guide.readiness.isEmpty)
        try await until("reloaded") { guide.models != nil && backend.calls.contains("list:vision-bedrock:eu-west-1") }
    }

    func testAnExpiredSignInWhileListingSendsYouBackToSignIn() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await onModelPage(backend)
        // The session ended: listing fails, and so would asking who is signed in.
        backend.signedIn = false
        backend.listError = AWSSignInRequiredError(profile: "vision-bedrock", message: "Your AWS sign-in has expired. Sign in again.")
        guide.loadModels()
        try await until("sent back") { guide.page == .signIn }
        XCTAssertNil(guide.identity)
        XCTAssertEqual(guide.signInError, "Your AWS sign-in has expired. Sign in again.")
    }

    func testOtherListingErrorsAreShownOnTheModelPage() async throws {
        let backend = FakeBedrockBackend()
        backend.signedIn = true
        backend.profiles = [AWSProfile(name: "vision-bedrock", kind: .loginSession, region: nil, settings: [:])]
        backend.listError = AWSCLIException(AWSCLIError(kind: .accessDenied, message: "Your AWS permissions don't allow bedrock:ListFoundationModels.",
                                                        permission: "bedrock:ListFoundationModels"))
        let guide = make(backend)
        guide.go(.cli); try await until("cli") { guide.cliStatus != nil }
        guide.go(.model)
        try await until("error shown") { guide.modelsError != nil }
        XCTAssertTrue(guide.modelsError!.contains("It needs the bedrock:ListFoundationModels permission."))
        XCTAssertNil(guide.models)
    }

    // MARK: Enabling a model

    private func enable(_ backend: FakeBedrockBackend, _ model: BedrockModel, _ access: ModelAccess) async throws -> BedrockGuideModel {
        backend.access[model.modelID] = access
        let guide = try await onModelPage(backend)
        guide.choose(model)
        try await until("checked") { !guide.checking && guide.access != nil }
        guide.next()
        XCTAssertEqual(guide.page, .access)
        return guide
    }

    func testTheUseCaseFormIsValidatedThenSentThenTheModelIsAwaited() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await enable(backend, sonnet, ModelAccess(state: .needsUseCaseForm, modelID: sonnet.modelID, message: "Form needed."))
        guide.submitUseCase()
        XCTAssertEqual(guide.workError, "Enter your company, or your own name.", "nothing sent while it is incomplete")
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("usecase") })

        guide.answers.company = "Acme"
        guide.answers.website = "acme.example"
        guide.submitUseCase()
        try await until("ready") { guide.access?.isReady == true }
        XCTAssertTrue(backend.calls.contains("usecase:Acme"))
        XCTAssertTrue(backend.calls.contains("wait:\(sonnet.modelID)"))
        try await until("done working") { !guide.working }
        XCTAssertTrue(guide.canAdvance)
        XCTAssertNil(guide.workError)
    }

    func testAnAccountThatAlreadyHasTheFormOnFileSaysSo() async throws {
        let backend = FakeBedrockBackend()
        backend.useCaseOutcome = .alreadyOnFile
        let guide = try await enable(backend, sonnet, ModelAccess(state: .needsUseCaseForm, modelID: sonnet.modelID, message: "Form needed."))
        guide.answers.company = "Acme"; guide.answers.website = "acme.example"
        guide.submitUseCase()
        try await until("ready") { guide.access?.isReady == true }
        XCTAssertTrue(backend.calls.contains("usecase:Acme"))
    }

    func testTermsAreOnlyAcceptedAfterTheBoxIsTicked() async throws {
        let backend = FakeBedrockBackend()
        let offer = ModelOffer(offerToken: "offer-123", prices: [ModelPrice(dimension: "Input tokens", price: "0.00024", unit: "1K tokens")])
        let guide = try await enable(backend, mistral, ModelAccess(state: .needsAgreement, modelID: mistral.modelID, message: "Terms.", offer: offer))
        guide.acceptAgreement()
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("accept:") }, "not without the tick")
        guide.acceptTerms = true
        guide.acceptAgreement()
        try await until("ready") { guide.access?.isReady == true }
        XCTAssertTrue(backend.calls.contains("accept:\(mistral.modelID):offer-123"))
    }

    func testAFailedAcceptanceShowsTheReasonAndDoesNotAdvance() async throws {
        let backend = FakeBedrockBackend()
        backend.agreementError = AWSCLIException(AWSCLIError(kind: .accessDenied, message: "You can't subscribe.",
                                                             permission: "aws-marketplace:Subscribe"))
        let guide = try await enable(backend, mistral, ModelAccess(state: .needsAgreement, modelID: mistral.modelID, message: "Terms.",
                                                                    offer: ModelOffer(offerToken: "t")))
        guide.acceptTerms = true
        guide.acceptAgreement()
        try await until("failed") { !guide.working && guide.workError != nil }
        XCTAssertTrue(guide.workError!.contains("aws-marketplace:Subscribe"))
        XCTAssertFalse(guide.canAdvance)
    }

    func testAPendingSubscriptionIsWaitedForAndExplainedIfItIsStillPending() async throws {
        let backend = FakeBedrockBackend()
        backend.waitResults = [ModelAccess(state: .pending, modelID: sonnet.modelID, message: "AWS is setting it up.")]
        let guide = try await enable(backend, sonnet, ModelAccess(state: .pending, modelID: sonnet.modelID, message: "AWS is setting it up."))
        try await until("waited") { backend.calls.contains("wait:\(sonnet.modelID)") && !guide.working }
        XCTAssertEqual(guide.access?.state, .pending)
        XCTAssertTrue(guide.workError?.contains("hasn't finished yet") == true)
        XCTAssertFalse(guide.canAdvance)

        backend.waitResults = [ModelAccess(state: .ready, modelID: sonnet.modelID, message: "Ready.")]
        guide.waitForAccess()
        try await until("ready") { guide.access?.isReady == true && !guide.working }
        XCTAssertTrue(guide.canAdvance)
    }

    // MARK: Navigation

    func testAReadyModelSkipsTheEnablePageAndBackReturnsToTheList() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await onModelPage(backend)
        guide.choose(sonnet)
        try await until("ready") { guide.access?.isReady == true }
        guide.next()
        XCTAssertEqual(guide.page, .connect)
        guide.back()
        XCTAssertEqual(guide.page, .model, "there was nothing to enable, so back goes to the list")
    }

    func testTheEnablePageIsPartOfTheWayBackWhenItWasNeeded() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await enable(backend, sonnet, ModelAccess(state: .needsUseCaseForm, modelID: sonnet.modelID, message: "Form."))
        guide.answers.company = "Acme"; guide.answers.website = "acme.example"
        guide.submitUseCase()
        try await until("ready") { guide.access?.isReady == true && !guide.working }
        guide.next()
        XCTAssertEqual(guide.page, .connect)
        guide.back()
        XCTAssertEqual(guide.page, .access)
    }

    func testBackFromTheFirstPageLeavesTheGuide() {
        let guide = make(FakeBedrockBackend())
        var left = false
        guide.onLeave = { left = true }
        guide.back()
        XCTAssertTrue(left)
    }

    func testOpeningPastTheCLIPageChecksTheCLIAndTheSignInFirst() async throws {
        // "Change…" on a route: the model page, but only once the CLI and the sign-in are fine.
        let backend = FakeBedrockBackend()
        backend.signedIn = true
        let guide = make(backend, start: .model)
        guide.activate()
        try await until("models") { guide.models != nil }
        XCTAssertEqual(guide.page, .model)
        XCTAssertNotNil(guide.identity)

        let expired = FakeBedrockBackend()          // signed out
        let other = make(expired, start: .model)
        other.activate()
        try await until("sent to sign in") { other.page == .signIn }
        XCTAssertNotNil(other.signInError)
        XCTAssertNil(other.models, "no models are asked for while signed out")

        let noCLI = FakeBedrockBackend()
        noCLI.cli = .missing
        let third = make(noCLI, start: .model)
        third.activate()
        try await until("sent to the CLI page") { third.page == .cli }
    }

    // MARK: Connecting and the fleet

    private func connectedGuide(_ backend: FakeBedrockBackend, config: AppConfig?, route: ProviderProfile? = nil,
                                model: BedrockModel? = nil) async throws -> BedrockGuideModel {
        backend.signedIn = true
        let guide = make(backend, config: config, start: .model, route: route)
        guide.activate()
        try await until("models") { guide.models != nil }
        guide.choose(model ?? sonnet)
        try await until("checked") { guide.access != nil && !guide.checking }
        guide.next()
        XCTAssertEqual(guide.page, .connect)
        try await until("connected") { guide.connected || guide.connectError != nil }
        return guide
    }

    func testTheFirstRouteEverAddedBecomesTheMainModel() async throws {
        let config = config()
        let guide = try await connectedGuide(FakeBedrockBackend(), config: config)
        XCTAssertEqual(guide.role, .main)
        XCTAssertEqual(config.mainRoute?.name, "Bedrock · Claude Sonnet 4.5")
        XCTAssertEqual(config.mainRoute?.model, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        XCTAssertEqual(config.mainRoute?.awsProfile, "vision-bedrock")
        XCTAssertEqual(config.mainRoute?.awsRegion, "us-east-1")
        XCTAssertEqual(config.mainRoute?.baseURL, "https://bedrock-runtime.us-east-1.amazonaws.com")
        XCTAssertEqual(config.mainRoute?.vision, true, "Claude reads images")
    }

    func testBedrockAddedNextToASparkStartsAsASubagentServerAndDoesNotTakeTheLead() async throws {
        let config = config([spark("Spark 1"), spark("Spark 2")])
        let guide = try await connectedGuide(FakeBedrockBackend(), config: config)
        XCTAssertEqual(guide.role, .subagents)
        XCTAssertEqual(config.mainRoute?.name, "Spark 1", "the working setup is not disturbed")
        XCTAssertEqual(config.enlistedRoutes.map(\.name), ["Bedrock · Claude Sonnet 4.5"], "Spark 2 is a spare until ticked")
        XCTAssertTrue(guide.hasOtherRoutes)
    }

    func testChoosingTheMainRoleAfterConnectingPutsBedrockInChargeAndKeepsTheSparkWorking() async throws {
        let config = config([spark("Spark 1"), spark("Spark 2")])
        config.setSubagentWorker(spark("Spark 2").routeID, true)
        let guide = try await connectedGuide(FakeBedrockBackend(), config: config)
        var saved = 0
        guide.onSaved = { _ in saved += 1 }
        guide.role = .main
        XCTAssertEqual(config.mainRoute?.name, "Bedrock · Claude Sonnet 4.5")
        XCTAssertEqual(Set(config.enlistedRoutes.map(\.name)), ["Spark 2", "Bedrock · Claude Sonnet 4.5"],
                       "the lead moving ticks nothing: Bedrock and Spark 2 still serve other chats' subagents")
        XCTAssertEqual(saved, 1)

        guide.role = .subagents
        XCTAssertEqual(config.mainRoute?.name, "Spark 1", "the lead goes back to whoever had it")
        XCTAssertTrue(config.enlistedRoutes.map(\.name).contains("Bedrock · Claude Sonnet 4.5"))
    }

    func testAFailedHelloSavesNothing() async throws {
        let backend = FakeBedrockBackend()
        backend.helloError = LLMError.rejected(status: 403, message: "Bedrock refused access to the model.", body: "", permanent: false)
        let config = config([spark()])
        let guide = try await connectedGuide(backend, config: config)
        XCTAssertFalse(guide.connected)
        XCTAssertEqual(guide.connectError, "Bedrock refused access to the model.")
        XCTAssertEqual(config.providers.count, 1, "no half-made route")
        XCTAssertFalse(guide.canAdvance)

        backend.helloError = nil
        guide.connect()
        try await until("connected") { guide.connected }
        XCTAssertEqual(config.providers.count, 2)
    }

    func testChangingARoutesModelReplacesItInPlaceAndKeepsItsRole() async throws {
        let old = ProviderProfile(kind: .bedrock, name: "Bedrock · Claude Opus 4.1", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                  model: "us.anthropic.claude-opus-4-1-20250805-v1:0", temperature: 0.2, reasoningEffort: "high",
                                  awsProfile: "vision-bedrock", awsRegion: "us-east-1", subagentWorker: true, subagentParallel: 4)
        let config = config([spark("Spark 1"), old, spark("Spark 2")])
        let guide = try await connectedGuide(FakeBedrockBackend(), config: config, route: old, model: nova)
        XCTAssertTrue(guide.connected)
        XCTAssertEqual(config.providers.map(\.name), ["Spark 1", "Bedrock · Nova Pro", "Spark 2"], "same seat, renamed with its model")
        let changed = config.providers[1]
        XCTAssertEqual(changed.model, "amazon.nova-pro-v1:0")
        XCTAssertEqual(changed.temperature, 0.2, "its tuning survives")
        XCTAssertEqual(changed.reasoningEffort, "high")
        XCTAssertTrue(changed.isSubagentWorker)
        XCTAssertEqual(changed.subagentParallel, 4)
        XCTAssertEqual(config.mainRoute?.name, "Spark 1")
        XCTAssertFalse(guide.hasOtherRoutes && guide.editing == nil, "no role question when changing a route")
    }

    func testARouteTheUserRenamedKeepsItsNameWhenItsModelChanges() async throws {
        let old = ProviderProfile(kind: .bedrock, name: "Reviewer", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                                  model: "us.anthropic.claude-opus-4-1-20250805-v1:0", awsProfile: "vision-bedrock", awsRegion: "us-east-1")
        let config = config([old])
        _ = try await connectedGuide(FakeBedrockBackend(), config: config, route: old, model: sonnet)
        XCTAssertEqual(config.providers.map(\.name), ["Reviewer"])
        XCTAssertEqual(config.providers[0].model, "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        XCTAssertEqual(config.mainRoute?.name, "Reviewer", "it was the main model and still is")
    }

    func testTwoBedrockModelsCanLiveSideBySideWhenAddedNotChanged() async throws {
        let config = config()
        _ = try await connectedGuide(FakeBedrockBackend(), config: config, model: opus)
        _ = try await connectedGuide(FakeBedrockBackend(), config: config, model: sonnet)
        XCTAssertEqual(config.providers.map(\.name), ["Bedrock · Claude Opus 4.1", "Bedrock · Claude Sonnet 4.5"],
                       "adding a model does not delete the other one")
        XCTAssertEqual(config.mainRoute?.name, "Bedrock · Claude Opus 4.1")
        XCTAssertEqual(config.enlistedRoutes.map(\.name), ["Bedrock · Claude Sonnet 4.5"])
    }

    // MARK: Done

    func testABedrockAPIKeyCanBeCreatedAndSavedToTheVault() async throws {
        let backend = FakeBedrockBackend()
        let guide = try await connectedGuide(backend, config: config())
        guide.next()
        XCTAssertEqual(guide.page, .done)
        guide.createAPIKey()
        try await until("key") { guide.apiKey != nil }
        XCTAssertEqual(guide.apiKey, "bedrock-api-key-abc")
        guide.saveKeyToVault()
        XCTAssertEqual(backend.savedKeys, ["bedrock-api-key-abc"])
        XCTAssertNil(guide.apiKey, "the key is not kept on screen once it is in the vault")
        XCTAssertTrue(guide.savedKeyToVault)
    }

    func testAVaultProblemIsReportedAndTheKeyIsKept() async throws {
        let backend = FakeBedrockBackend()
        backend.vaultError = VaultError.duplicateName("AWS_BEARER_TOKEN_BEDROCK")
        let guide = try await connectedGuide(backend, config: config())
        guide.createAPIKey()
        try await until("key") { guide.apiKey != nil }
        guide.saveKeyToVault()
        XCTAssertNotNil(guide.apiKeyError)
        XCTAssertNotNil(guide.apiKey, "still there to copy")
        XCTAssertFalse(guide.savedKeyToVault)
    }

    func testFinishingCallsBackAndDisposingStopsEverythingQuietly() async throws {
        let guide = try await connectedGuide(FakeBedrockBackend(), config: config())
        var finished = false
        guide.onFinish = { finished = true }
        guide.next()                                     // connect → done
        guide.next()                                     // done → finish
        XCTAssertTrue(finished)
        guide.dispose()
        guide.dispose()
    }
}
