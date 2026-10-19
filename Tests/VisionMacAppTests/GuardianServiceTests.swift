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
