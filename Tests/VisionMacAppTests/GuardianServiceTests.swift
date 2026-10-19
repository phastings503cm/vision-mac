import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The Guardian connection in the app, against a scripted Guardian: sign-in fills the account and limits, the org
/// picker reaches the model routes, "Usable in Vision" secrets live in memory only, prompts go up on submit and
/// again with their outcome, and a refusal is shown once.
@MainActor
final class GuardianServiceTests: XCTestCase {
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        var routes: [String: (Int, String)] = [:]
        func add(_ r: URLRequest) { lock.lock(); log.append(r); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }
        func count(_ key: String) -> Int {
            requests.filter { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") == key }.count
        }
    }

    private var dir: URL!
    private var suite: String!
    private var transport: AppTransport!
    private var wire: Wire!
    private var service: GuardianService!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-guardian-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "vision-guardian-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .guardian, name: "Guardian", baseURL: "https://guardian.503cm.com/api/harness/v1", model: "guardian/default"))
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        wire = Wire()
        wire.routes = [
            "POST /api/auth/login": (200, #"{"ok":true,"token":"sess-1","session":{"userId":"u1","email":"pat@503cm.com","name":"Pat"}}"#),
            "GET /api/harness/me": (200, #"{"user":{"id":"u1","email":"pat@503cm.com","name":"Pat"},"orgs":[{"id":"o1","name":"503CM","active":true},{"id":"o2","name":"Cyticorp"}],"modules":["vision"],"permissions":[],"limits":[]}"#),
            "GET /api/harness/limits": (200, #"{"limits":[{"kind":"spend","window":"week","used":10,"max":40,"unit":"usd","resetsAt":"2026-10-26T00:00:00Z"}]}"#),
            "GET /api/harness/vault": (200, #"{"secrets":[{"id":"s1","name":"Freshdesk","envKey":"FRESHDESK_API_KEY","service":"freshdesk","itemType":"api_key","hasValue":true}]}"#),
            "POST /api/harness/vault/s1/reveal": (200, #"{"value":"fd-secret-123456"}"#),
            "POST /api/harness/prompts": (200, #"{"accepted":1}"#),
            "GET /api/harness/eta": (200, #"{"byKind":{}}"#),
        ]
        let wire = self.wire!
        service = GuardianService(appSupport: dir, secrets: MemorySecretStore()) { request in
            wire.add(request)
            let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
            let (status, body) = wire.routes[key] ?? (404, #"{"error":"not found"}"#)
            return GuardianHTTPResponse(data: Data(body.utf8), status: status, headers: [:])
        }
        service.transport = transport
    }

    override func tearDown() async throws {
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: dir)
        service = nil
        transport = nil
    }

    private func signIn() async throws {
        let ok = await service.signIn(address: GuardianService.defaultURL, email: "pat@503cm.com", password: "pw")
        XCTAssertTrue(ok, service.lastError ?? "")
        try await waitUntil { self.service.account != nil && !self.service.limits.isEmpty }
    }

    func testSigningInReadsTheAccountAndLimits() async throws {
        try await signIn()
        XCTAssertEqual(service.accountEmail, "pat@503cm.com")
        XCTAssertEqual(service.account?.orgs.map(\.name), ["503CM", "Cyticorp"])
        XCTAssertEqual(service.limits.first?.usage, "$10.00 of $40.00")
    }

    func testPickingAnOrgSendsItEverywhereIncludingTheModelRoute() async throws {
        try await signIn()
        service.setOrg("o2")
        try await waitUntil { self.wire.requests.last { $0.url?.path == "/api/harness/me" }?.value(forHTTPHeaderField: "x-guardian-org") == "o2" }
        XCTAssertEqual(transport.config.providers.first { $0.kind == .guardian }?.customHeaders?["x-guardian-org"], "o2",
                       "chats on the Guardian proxy work in the same organization")
        service.setOrg(nil, refresh: false)
        XCTAssertNil(transport.config.providers.first { $0.kind == .guardian }?.customHeaders?["x-guardian-org"])
    }

    func testUsableInVisionSecretsLiveInMemoryAndGoWithTheSignIn() async throws {
        try await signIn()
        await service.loadSecrets()
        let secret = try XCTUnwrap(service.remoteSecrets.first)
        await service.useSecret(secret)
        XCTAssertEqual(transport.vault.lookup("FRESHDESK_API_KEY"), .value("fd-secret-123456", access: .ask))
        XCTAssertTrue(service.secretsInUse.contains("s1"))
        XCTAssertNil(CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()).entry(named: "FRESHDESK_API_KEY"),
                     "never written to the vault's file")
        service.signOut()
        XCTAssertEqual(transport.vault.lookup("FRESHDESK_API_KEY"), .missing)
    }

    func testPromptsGoUpOnSubmitAndAgainWithTheirOutcomeOnce() async throws {
        try await signIn()
        let at = Date()
        let submitted = GuardianService.SessionVMPrompt(id: "p1", text: "fix the build", at: at, outcome: nil, chatID: "c1", chatTitle: "Build")
        let finished = GuardianService.SessionVMPrompt(id: "p1", text: "fix the build", at: at, outcome: "completed", chatID: "c1",
                                                       chatTitle: "Build", durationSeconds: 12)
        await service.syncPrompts([submitted])
        await service.syncPrompts([finished])
        await service.syncPrompts([submitted, finished])
        XCTAssertEqual(wire.count("POST /api/harness/prompts"), 2)
        let last = wire.requests.last { $0.url?.path == "/api/harness/prompts" }!
        let prompt = ((try JSONSerialization.jsonObject(with: last.httpBody!) as! [String: Any])["prompts"] as! [[String: Any]])[0]
        XCTAssertEqual(prompt["outcome"] as? String, "completed")
        XCTAssertEqual(prompt["source"] as? String, "vision-mac")
        XCTAssertEqual(prompt["chatTitle"] as? String, "Build")
    }

    /// Guardian isn't a private model: the notebook copy is masked (the vault's secrets always, the shield's kinds
    /// when it is on), the same way at the start and the end so Guardian keeps one row — the same rule as Windows.
    func testTheNotebookCopyIsMaskedTheSameWayEachTime() async throws {
        try await signIn()
        var off = ShieldSettings()
        off.enabled = false
        let vaultOnly = SensitiveDetector(settings: off, vaultValues: ["rk-9f8e7d6c5b4a"])
        let at = Date()
        let start = GuardianService.SessionVMPrompt(id: "p9", text: "Rotate rk-9f8e7d6c5b4a in the billing service, mail ops@example.com",
                                                    at: at, outcome: nil, chatID: "c1", chatTitle: "rk-9f8e7d6c5b4a rotation",
                                                    project: "billing")
        var end = start
        end.outcome = "completed"
        let a = start.masked(by: vaultOnly), b = end.masked(by: vaultOnly)
        XCTAssertEqual(a.text, "Rotate ⟦SECRET_1⟧ in the billing service, mail ops@example.com", "with the shield off only the vault's values go")
        XCTAssertEqual(a.text, b.text)
        XCTAssertEqual(a.chatTitle, "⟦SECRET_1⟧ rotation", "one placeholder across the text, title and project")
        XCTAssertEqual(a.project, "billing")
        let shield = SensitiveDetector(settings: ShieldSettings(), vaultValues: ["rk-9f8e7d6c5b4a"])
        XCTAssertFalse(start.masked(by: shield).text.contains("ops@example.com"), "the shield's kinds when it is on")
        XCTAssertEqual(start.masked(by: nil).text, start.text, "nothing to mask")
        await service.syncPrompts([a])
        await service.syncPrompts([b])
        let bodies = wire.requests.filter { $0.url?.path == "/api/harness/prompts" }.compactMap { $0.httpBody }
        XCTAssertEqual(bodies.count, 2)
        for body in bodies {
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(text.contains("rk-9f8e7d6c5b4a"), text)
            XCTAssertTrue(text.contains("SECRET_1"), text)
        }
    }

    func testTheNotebookSwitchIsKeptOnlyWhenOff() {
        let defaults = UserDefaults(suiteName: suite + "-sync")!
        defer { defaults.removePersistentDomain(forName: suite + "-sync") }
        let config = AppConfig(defaults: defaults, secrets: MemorySecretStore())
        XCTAssertTrue(config.guardianPromptSync, "on by default")
        config.guardianPromptSync = false
        XCTAssertFalse(AppConfig(defaults: defaults, secrets: MemorySecretStore()).guardianPromptSync)
        config.guardianPromptSync = true
        XCTAssertNil(defaults.object(forKey: "guardian.promptSync.v1"))
    }

    // MARK: The model routes follow the sign-in (review: signing in again in Settings left the route's old token)

    /// A Guardian route set up with token A gets a 401; signing in again in Settings ▸ Guardian (what the 401 dialog
    /// asks for) gives the connection token B — and the next chat request carries `Bearer B`. Signing out takes it away.
    func testSigningInAgainRenewsTheModelRoutesTokenAndSigningOutTakesItAway() async throws {
        OpenAIClient.protocolClassesForTesting = [GuardianProxyServer.self]
        GuardianProxyServer.reset()
        defer { OpenAIClient.protocolClassesForTesting = nil }
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport.config.computerToolsEnabled = false
        let route = try XCTUnwrap(transport.config.activeProvider)
        transport.config.setAPIKey("tok-A", for: route)

        let vm = transport.newSession(cwd: dir.path)
        transport.send("hello", sessionID: vm.id)
        try await waitUntil(timeout: 20) { !vm.running && vm.entries.contains { $0.message?.role == .error } }
        XCTAssertEqual(Set(GuardianProxyServer.chatAuthorizations), ["Bearer tok-A"], "the stale token, refused")
        let before = GuardianProxyServer.chatAuthorizations.count

        try await signIn()   // the login answers with token "sess-1"
        XCTAssertEqual(transport.config.apiKey(for: route), "sess-1")
        transport.send("hello again", sessionID: vm.id)
        try await waitUntil(timeout: 20) { !vm.running && vm.entries.contains { $0.message?.role == .assistant } }
        XCTAssertEqual(Set(GuardianProxyServer.chatAuthorizations.dropFirst(before)), ["Bearer sess-1"])

        // The wizard's path (adopt) and a sign-out reach the route the same way.
        service.adopt(GuardianSession(userID: "u1", email: "pat@503cm.com", name: nil, token: "sess-2"),
                      address: GuardianService.defaultURL)
        XCTAssertEqual(transport.config.apiKey(for: route), "sess-2")
        service.signOut()
        XCTAssertEqual(transport.config.apiKey(for: route), "", "signed out: the models stop using the token too")

        // A route on another Guardian is left alone.
        let other = ProviderProfile(kind: .guardian, name: "Staging", baseURL: "https://staging.guardian.test/v1", model: "m")
        XCTAssertFalse(GuardianService.servesSameGuardian(other, address: GuardianService.defaultURL))
        XCTAssertTrue(GuardianService.servesSameGuardian(route, address: "https://GUARDIAN.503cm.com"))
    }

    /// Signed in from Settings with no Guardian model route: "Use Guardian's Models" adds one on this sign-in's token.
    func testUseGuardiansModelsAddsTheRouteOnTheSignInsToken() async throws {
        let existing = try XCTUnwrap(transport.config.activeProvider)
        transport.config.removeProvider(existing)
        XCTAssertTrue(service.modelRoutes.isEmpty)
        wire.routes["GET /api/harness/v1/models"] = (200, #"{"models":[{"id":"guardian/sonnet"},{"id":"guardian/opus"}]}"#)
        try await signIn()
        service.setOrg("o2", refresh: false)
        let said = await service.addModelRoute()
        XCTAssertEqual(said, "Added Guardian's models (2) — pick one for a chat in the model menu under the message box.")
        let route = try XCTUnwrap(service.modelRoutes.first)
        XCTAssertEqual(route.baseURL, "https://guardian.503cm.com/v1")
        XCTAssertEqual(route.model, "guardian/opus")
        XCTAssertEqual(route.customHeaders?["x-guardian-org"], "o2")
        XCTAssertEqual(transport.config.apiKey(for: route), "sess-1")
        XCTAssertEqual(GuardianService.modelRouteURL(URL(string: "https://g.example.com/")!), "https://g.example.com/v1")
    }

    /// Download a Copy into the folder that holds the project's working tree: a new "ledger (2)", the tree untouched.
    func testDownloadingACopyNeverWritesOverTheFolderThatIsThere() async throws {
        wire.routes["GET /api/harness/projects/p1"] = (200, ##"{"name":"../ledger","files":{"README.md":"# From Guardian","../outside.txt":"x","Sources/a.swift":"let a = 1"}}"##)
        try await signIn()
        let parent = dir.appendingPathComponent("code", isDirectory: true)
        let tree = parent.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try "# My uncommitted edits".write(to: tree.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let downloaded = await service.downloadProject(GuardianProject(id: "p1", name: "ledger"), into: parent)
        let root = try XCTUnwrap(downloaded)
        XCTAssertEqual(root.lastPathComponent, "ledger (2)")
        XCTAssertEqual(try String(contentsOf: tree.appendingPathComponent("README.md"), encoding: .utf8), "# My uncommitted edits")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8), "# From Guardian")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/a.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("outside.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("outside.txt").path))
    }

    func testAnExpiredSignInIsDroppedWithAPlainMessage() async throws {
        try await signIn()
        wire.routes["GET /api/harness/me"] = (401, #"{"error":"unauthorized","message":"revoked"}"#)
        await service.refreshAccount()
        XCTAssertFalse(service.isSignedIn)
        XCTAssertEqual(service.lastError, GuardianError.unauthorized.errorDescription)
    }

    func testARefusalIsShownOnceNotOverAndOver() {
        let problem = GuardianProblem(status: 402, error: "budget_exceeded", message: "Spent.",
                                      limit: GuardianLimit(kind: "spend", window: "day", used: 5, max: 5))
        service.show(problem)
        XCTAssertEqual(service.problem, problem)
        service.problem = nil
        service.show(problem)
        XCTAssertNil(service.problem, "the same refusal within half a minute isn't shown again")
    }

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

/// Guardian's model proxy for the route tests: remembers each chat request's Authorization, refuses token A with a
/// 401, answers anything else.
final class GuardianProxyServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _auth: [String] = []
    static var chatAuthorizations: [String] { lock.withLock { _auth } }
    static func reset() { lock.withLock { _auth = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/models") {
            respond(200, #"{"data":[{"id":"guardian/default"}]}"#, type: "application/json")
            return
        }
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.lock.withLock { Self._auth.append(auth) }
        if auth == "Bearer tok-A" {
            respond(401, #"{"error":"unauthorized","message":"Your sign-in has expired."}"#, type: "application/json")
        } else {
            respond(200, #"data: {"choices":[{"delta":{"content":"Hi."}}]}"# + "\n\n"
                    + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        }
    }

    private func respond(_ status: Int, _ body: String, type: String = "text/event-stream") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
