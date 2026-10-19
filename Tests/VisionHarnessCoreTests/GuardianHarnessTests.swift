import XCTest
@testable import VisionHarnessCore

/// The rest of the Guardian ⇄ Vision contract against a scripted transport: browser sign-in (loopback + PKCE),
/// /me with the org picker header, limits, structured refusals, the vault's opt-in secrets, projects, prompt fields.
final class GuardianHarnessTests: XCTestCase {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ r: URLRequest) { lock.lock(); requests.append(r); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        func last(_ path: String) -> URLRequest? { all.last { $0.url?.path == path } }
    }

    func client(_ routes: [String: (status: Int, body: String, headers: [String: String])], seen: Seen = Seen(),
                session: GuardianSession? = GuardianSession(userID: "u1", email: "pat@503cm.com", name: "Pat", token: "tok")) throws -> GuardianClient {
        try GuardianClient(baseURL: "https://guardian.503cm.com", session: session) { request in
            seen.add(request)
            let path = request.url?.path ?? ""
            let key = (request.httpMethod ?? "GET") + " " + path
            guard let route = routes[key] else {
                return GuardianHTTPResponse(data: Data(#"{"error":"not found"}"#.utf8), status: 404, headers: [:])
            }
            return GuardianHTTPResponse(data: Data(route.body.utf8), status: route.status, headers: route.headers)
        }
    }

    func ok(_ body: String, _ status: Int = 200, headers: [String: String] = [:]) -> (status: Int, body: String, headers: [String: String]) {
        (status, body, headers)
    }

    override func tearDown() { GuardianProblems.setHandler(nil) }

    // MARK: PKCE + loopback

    func testPKCEMatchesTheRFC7636Example() {
        // RFC 7636 Appendix B.
        XCTAssertEqual(GuardianPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let made = GuardianPKCE.make()
        XCTAssertEqual(made.verifier.count, 43)
        XCTAssertTrue(made.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertNotEqual(made.state, GuardianPKCE.make().state)
    }

    func testTheConsentURLCarriesTheContractParameters() throws {
        let c = try client([:])
        let pkce = GuardianPKCE(verifier: "v", state: "s1")
        let url = c.browserSignInURL(redirectURI: "http://127.0.0.1:5555/callback", pkce: pkce, device: "Vision on Pat's Mac")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.path, "/app/connect/vision")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:5555/callback")
        XCTAssertEqual(query["state"], "s1")
        XCTAssertEqual(query["code_challenge"], GuardianPKCE.challenge(for: "v"))
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["device"], "Vision on Pat's Mac")
        XCTAssertEqual(query["client"], "vision-mac", "the consent page says Vision for macOS")
    }

    func testBrowserSignInEndToEndThroughTheLoopback() async throws {
        let seen = Seen()
        let c = try client(["POST /api/harness/connect/token": ok(#"{"ok":true,"token":"harness-tok","session":{"userId":"u9","email":"sso@503cm.com","name":"Sam"},"orgId":"org-cyti"}"#)],
                           seen: seen, session: nil)
        let opened = Seen()
        let (session, org) = try await c.signInWithBrowser(device: "Vision on test", timeout: 10) { url in
            // The "browser": Guardian's consent page redirects back with a code and the same state.
            opened.add(URLRequest(url: url))
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            var back = URLComponents(string: query["redirect_uri"]!)!
            back.queryItems = [URLQueryItem(name: "code", value: "code-123"), URLQueryItem(name: "state", value: query["state"])]
            let target = back.url!
            Task.detached {
                try? await Task.sleep(nanoseconds: 100_000_000)
                _ = try? await URLSession.shared.data(from: target)
            }
        }
        XCTAssertEqual(session.token, "harness-tok")
        XCTAssertEqual(session.email, "sso@503cm.com")
        XCTAssertEqual(org, "org-cyti")
        XCTAssertEqual(c.orgID, "org-cyti", "calls go to the org the person picked on the consent page")
        XCTAssertEqual(c.session?.token, "harness-tok")
        // The token exchange proved possession of the verifier behind the challenge the browser saw.
        let body = try JSONSerialization.jsonObject(with: seen.last("/api/harness/connect/token")!.httpBody!) as! [String: String]
        let consent = URLComponents(url: opened.all[0].url!, resolvingAgainstBaseURL: false)!
        let challenge = consent.queryItems!.first { $0.name == "code_challenge" }!.value!
        XCTAssertEqual(GuardianPKCE.challenge(for: body["code_verifier"]!), challenge)
        XCTAssertEqual(body["code"], "code-123")
        XCTAssertTrue(body["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(body["redirect_uri"]!.hasSuffix("/callback"))
    }

    func testABrowserAnswerWithTheWrongStateIsRefused() async throws {
        let c = try client(["POST /api/harness/connect/token": ok(#"{"token":"t"}"#)], session: nil)
        do {
            _ = try await c.signInWithBrowser(device: "d", timeout: 10) { url in
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
                let target = URL(string: redirect + "?code=x&state=forged")!
                Task.detached { _ = try? await URLSession.shared.data(from: target) }
            }
            XCTFail("a forged state must not sign in")
        } catch let error as GuardianBrowserSignInError {
            XCTAssertEqual(error, .stateMismatch)
        }
        XCTAssertNil(c.session)
    }

    func testDenyingInTheBrowserIsACancel() async throws {
        let c = try client([:], session: nil)
        do {
            _ = try await c.signInWithBrowser(device: "d", timeout: 10) { url in
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
                let target = URL(string: redirect + "?error=access_denied&error_description=The%20user%20said%20no")!
                Task.detached { _ = try? await URLSession.shared.data(from: target) }
            }
            XCTFail("expected a cancel")
        } catch let error as GuardianBrowserSignInError {
            XCTAssertEqual(error, .cancelled("The user said no"))
        }
    }

    func testTheLoopbackIgnoresOtherPathsAndTimesOut() async throws {
        let loopback = try GuardianLoopback()
        defer { loopback.stop() }
        let port = loopback.port
        Task.detached {
            _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
            _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=c1&state=s1")!)
        }
        let query = try await loopback.waitForCallback(timeout: 10)
        XCTAssertEqual(query["code"], "c1")
        let quiet = try GuardianLoopback()
        do {
            _ = try await quiet.waitForCallback(timeout: 0.3)
            XCTFail("no browser came back")
        } catch let error as GuardianBrowserSignInError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertNil(GuardianLoopback.callbackQuery("POST /callback?code=1 HTTP/1.1\r\n"))
        XCTAssertEqual(GuardianLoopback.callbackQuery("GET /callback?code=1&state=2 HTTP/1.1\r\nHost: x\r\n")?["state"], "2")
    }

    func testAnExpiredConnectCodeSaysSo() async throws {
        let c = try client(["POST /api/harness/connect/token": ok(#"{"error":"unauthorized","message":"code expired"}"#, 401)], session: nil)
        do {
            _ = try await c.exchangeConnectCode(code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1/callback")
            XCTFail()
        } catch let error as GuardianError {
            XCTAssertTrue(error.errorDescription?.contains("may have expired") == true)
        }
    }

    // MARK: /me, the org picker, limits

    func testMeReadsTheAccountAndTheOrgHeaderFollowsThePicker() async throws {
        let seen = Seen()
        let c = try client(["GET /api/harness/me": ok("""
            {"user":{"id":"u1","email":"pat@503cm.com","name":"Pat"},
             "orgs":[{"id":"o1","name":"503CM","active":true},{"id":"o2","name":"Cyticorp","active":false}],
             "modules":["insights",{"key":"automations"}],"permissions":["chat.use"],
             "limits":{"limits":[{"kind":"spend","window":"week","used":12.4,"max":50,"unit":"usd","resetsAt":"2026-10-20T16:00:00Z"}]}}
            """)], seen: seen)
        let me = try await c.me()
        XCTAssertEqual(me.email, "pat@503cm.com")
        XCTAssertEqual(me.orgs.map(\.name), ["503CM", "Cyticorp"])
        XCTAssertEqual(me.activeOrg?.id, "o1")
        XCTAssertEqual(me.modules, ["insights", "automations"])
        XCTAssertEqual(me.permissions, ["chat.use"])
        XCTAssertEqual(me.limits.first?.usage, "$12.40 of $50.00")
        XCTAssertEqual(me.limits.first?.title, "Spend this week")
        XCTAssertNil(seen.last("/api/harness/me")?.value(forHTTPHeaderField: "x-guardian-org"), "no org picked: the account's default")
        XCTAssertEqual(seen.last("/api/harness/me")?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        c.orgID = "o2"
        _ = try await c.me()
        XCTAssertEqual(seen.last("/api/harness/me")?.value(forHTTPHeaderField: "x-guardian-org"), "o2")
    }

    func testLimitsInEveryShape() async throws {
        let c = try client(["GET /api/harness/limits": ok(#"{"limits":[{"kind":"tokens","window":"day","used":1200000,"max":2000000,"unit":"tokens","resetsAt":1792000000}]}"#)])
        let limits = try await c.limits()
        XCTAssertEqual(limits.first?.usage, "1.2M of 2M tokens")
        XCTAssertEqual(limits.first?.title, "Tokens today")
        XCTAssertEqual(limits.first?.resetsAt, Date(timeIntervalSince1970: 1792000000))
        XCTAssertEqual(GuardianClient.limits(["spend": ["window": "month", "used": 3, "max": 10]]).first?.title, "Spend this month")
        XCTAssertEqual(GuardianLimit(kind: "requests", window: "run", used: 60, max: 60).usage, "60 of 60 requests")
        XCTAssertEqual(GuardianLimit(kind: "spend", window: "day", used: 4.8, max: 5).fraction ?? 0, 0.96, accuracy: 0.001)
    }

    // MARK: Structured refusals

    func testForbiddenNamesWhatIsMissingAndWhoCanGrantIt() async throws {
        let reported = Recorder<GuardianProblem>()
        GuardianProblems.setHandler { reported.append($0) }
        let c = try client(["GET /api/harness/projects": ok(#"{"error":"forbidden","reason":"module_disabled","needed":"AI Coders","message":"AI Coders is turned off for your account in 503CM."}"#, 403)])
        do {
            _ = try await c.projects()
            XCTFail()
        } catch GuardianError.problem(let problem) {
            XCTAssertEqual(problem.title, "Your Guardian account doesn't allow this")
            let detail = problem.detail()
            XCTAssertTrue(detail.hasPrefix("AI Coders is turned off for your account in 503CM."), detail)
            XCTAssertTrue(detail.contains("the “AI Coders” module is turned off for you"), detail)
            XCTAssertTrue(detail.contains("An admin of your Guardian organization can turn it on"), detail)
            XCTAssertFalse(detail.contains("403"), "never a raw HTTP code")
        }
        XCTAssertEqual(reported.values.map(\.reason), ["module_disabled"], "reported once for the dialog")
    }

    func testASpentBudgetSaysWhichLimitAndWhenItResets() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resets = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))
        let body = #"{"error":"budget_exceeded","limit":{"kind":"spend","window":"day","used":4.8,"max":5,"unit":"usd","resetsAt":"\#(resets)"},"message":"You've used today's Vision allowance."}"#
        let problem = try XCTUnwrap(GuardianProblem.parse(status: 402, body: Data(body.utf8)))
        XCTAssertEqual(problem.title, "Guardian spend limit reached")
        let detail = problem.detail(now: now)
        XCTAssertTrue(detail.contains("You've used today's Vision allowance."), detail)
        XCTAssertTrue(detail.contains("Spend today: $4.80 of $5.00 — resets in 3 hours ("), detail)
        XCTAssertTrue(detail.contains("admin can raise the limit"), detail)
        XCTAssertFalse(problem.isTransient)
    }

    func testRateLimitsFromTheBodyOrOnlyTheHeaders() throws {
        let headers = ["X-Guardian-Limit-Kind": "requests", "x-guardian-limit-window": "minute", "x-guardian-limit-reset": "1800000060"]
        let bare = try XCTUnwrap(GuardianProblem.parse(status: 429, body: Data("Too Many Requests".utf8), headers: headers))
        XCTAssertEqual(bare.error, "rate_limited")
        XCTAssertTrue(bare.isTransient)
        XCTAssertEqual(bare.limit?.window, "minute")
        XCTAssertEqual(bare.detail(now: Date(timeIntervalSince1970: 1_800_000_000)).contains("Requests this minute — resets in 1 minute"), true)
        // Another server's error is not Guardian's.
        XCTAssertNil(GuardianProblem.parse(status: 429, body: Data(#"{"error":{"message":"slow down"}}"#.utf8)))
        XCTAssertNil(GuardianProblem.parse(status: 400, body: Data(#"{"error":"temperature not supported"}"#.utf8)))
        // OpenAI-style wrapping of Guardian's codes still parses.
        let wrapped = GuardianProblem.parse(status: 403, body: Data(#"{"error":{"code":"forbidden","reason":"scope_missing","needed":"vision.chat","message":"m"}}"#.utf8))
        XCTAssertEqual(wrapped?.reason, "scope_missing")
        XCTAssertTrue(wrapped?.detail().contains("Sign out and sign in again") == true)
    }

    func testTheModelProxyTurnsRefusalsIntoErrorsThatAreNotRetried() throws {
        let url = URL(string: "https://guardian.503cm.com/api/harness/v1/chat/completions")!
        let spent = HTTPURLResponse(url: url, statusCode: 402, httpVersion: nil, headerFields: [:])!
        let error = OpenAIClient.guardianRefusal(spent, body: Data(#"{"error":"limit_reached","limit":{"kind":"tokens","window":"week","used":5000000,"max":5000000},"message":"Weekly tokens used up."}"#.utf8))
        guard case .rejected(let status, let message, _, let permanent)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(status, 402)
        XCTAssertTrue(permanent)
        XCTAssertTrue(message.hasPrefix("Guardian token limit reached. Weekly tokens used up."), message)
        let busy = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:])!
        guard case .rejected(_, _, _, let transient)? = OpenAIClient.guardianRefusal(busy, body: Data(#"{"error":"rate_limited","message":"m"}"#.utf8)) else { return XCTFail() }
        XCTAssertFalse(transient, "a short rate limit is retried")
        XCTAssertNil(OpenAIClient.guardianRefusal(busy, body: Data(#"{"error":{"message":"vLLM busy"}}"#.utf8)))
    }

    func testUnauthorizedStaysUnauthorized() async throws {
        let c = try client(["GET /api/harness/limits": ok(#"{"error":"unauthorized","message":"token revoked"}"#, 401)])
        do {
            _ = try await c.limits()
            XCTFail()
        } catch let error as GuardianError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: Vault, projects, prompts

    func testVaultListsNamesAndRevealsOnePerAsk() async throws {
        let seen = Seen()
        let c = try client([
            "GET /api/harness/vault": ok(#"{"secrets":[{"id":"s1","name":"Freshdesk API key","envKey":"FRESHDESK_API_KEY","service":"freshdesk","itemType":"api_key","hasValue":true,"updatedAt":"2026-10-18T10:00:00.000Z"},{"id":"s/2","name":"Polestar","itemType":"login"}]}"#),
            "POST /api/harness/vault/s1/reveal": ok(#"{"id":"s1","envKey":"FRESHDESK_API_KEY","field":"value","value":"fd-secret-123"}"#),
        ], seen: seen)
        let secrets = try await c.vaultSecrets()
        XCTAssertEqual(secrets.map(\.name), ["Freshdesk API key", "Polestar"])
        XCTAssertEqual(secrets.first?.envKey, "FRESHDESK_API_KEY", "Guardian's own shape (GuardianProject harness.controller listVault)")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(secrets), as: UTF8.self).contains("fd-secret"), "names only until revealed")
        let value = try await c.revealSecret(id: "s1")
        XCTAssertEqual(value, "fd-secret-123")
        XCTAssertEqual(seen.all.filter { $0.url?.path.hasSuffix("/reveal") == true }.count, 1)
    }

    func testProjectsListAndManifest() async throws {
        let c = try client([
            "GET /api/harness/projects": ok(#"{"projects":[{"id":"p1","name":"ledger","updatedAt":"2026-10-18T10:00:00Z","fileCount":42,"aiCoders":true}]}"#),
            "GET /api/harness/projects/p1": ok(##"{"name":"ledger","files":{"README.md":"# ledger","src/main.swift":"print(1)"}}"##),
        ])
        let projects = try await c.projects()
        XCTAssertEqual(projects.first?.fileCount, 42)
        XCTAssertEqual(projects.first?.aiCoders, true)
        let manifest = try await c.project(id: "p1")
        XCTAssertEqual(manifest.files["src/main.swift"], "print(1)")
    }

    func testPromptsCarryTheContractFields() async throws {
        let seen = Seen()
        let c = try client([
            "POST /api/harness/prompts": ok(#"{"accepted":1}"#),
            "GET /api/harness/prompts": ok(#"{"prompts":[{"id":"r1","text":"fix it","at":"2026-10-18T10:00:00Z","outcome":"completed","source":"vision-mac","chatTitle":"Build","project":"ledger","model":"glm"}]}"#),
        ], seen: seen)
        _ = try await c.pushPrompts([GuardianPrompt(text: "fix it", at: Date(timeIntervalSince1970: 1_800_000_000), outcome: "completed",
                                                    source: "vision-mac", chatID: "c1", chatTitle: "Build", project: "ledger",
                                                    model: "glm", durationSeconds: 42, runID: "turn-1")])
        let body = try JSONSerialization.jsonObject(with: seen.last("/api/harness/prompts")!.httpBody!) as! [String: Any]
        let prompt = (body["prompts"] as! [[String: Any]])[0]
        XCTAssertEqual(prompt["chatId"] as? String, "c1")
        XCTAssertEqual(prompt["chatTitle"] as? String, "Build")
        XCTAssertEqual(prompt["runId"] as? String, "turn-1")
        XCTAssertEqual(prompt["durationSeconds"] as? Double, 42)
        XCTAssertEqual(prompt["at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertNil(prompt["id"])
        let back = try await c.prompts(limit: 50, before: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(back.first?.id, "r1")
        XCTAssertEqual(back.first?.chatTitle, "Build")
        let query = URLComponents(url: seen.all.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
        XCTAssertEqual(query.first { $0.name == "before" }?.value, "2027-01-15T08:00:00Z")
    }

    // MARK: Session-only vault entries

    func testSessionOnlySecretsAreUsableButNeverStored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-vault-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryBlobStore()
        let vault = CredentialVault(directory: dir, store: store)
        try vault.add(name: "STORED_KEY", value: "stored-value-1")
        let entry = try vault.addSessionOnly(name: "GUARDIAN_FD", value: "fd-secret-123", kind: .apiKey, tags: ["guardian"])
        XCTAssertEqual(vault.lookup("GUARDIAN_FD"), .value("fd-secret-123", access: .ask))
        XCTAssertTrue(vault.isSessionOnly(entry))
        XCTAssertTrue(vault.valuesForRedaction().contains { $0.value == "fd-secret-123" }, "scrubbed from tool output like any secret")
        XCTAssertEqual(vault.all.map(\.name), ["GUARDIAN_FD", "STORED_KEY"])
        // Not on disk, not in the Keychain blob.
        let reopened = CredentialVault(directory: dir, store: store)
        XCTAssertNil(reopened.entry(named: "GUARDIAN_FD"))
        XCTAssertFalse(String(decoding: try store.load() ?? Data(), as: UTF8.self).contains("fd-secret"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: dir.appendingPathComponent("vault.json")), as: UTF8.self).contains("GUARDIAN_FD"))
        // A stored name can't be shadowed; removing forgets it.
        XCTAssertThrowsError(try vault.addSessionOnly(name: "STORED_KEY", value: "x-value-123"))
        vault.removeSessionOnly(named: "GUARDIAN_FD")
        XCTAssertEqual(vault.lookup("GUARDIAN_FD"), .missing)
    }
}

extension GuardianHarnessTests {
    /// The contract's login answer is `{ok, token, session:{userId, email, name}}` (no `id`): the token must not be
    /// lost because the session object has a different shape than `user`.
    func testPasswordSignInReadsGuardiansSessionShape() async throws {
        let c = try client(["POST /api/auth/login": ok(#"{"ok":true,"token":"sess-1","session":{"userId":"u1","email":"pat@503cm.com","name":"Pat"}}"#)],
                           session: nil)
        let session = try await c.signIn(email: "pat@503cm.com", password: "pw")
        XCTAssertEqual(session.token, "sess-1")
        XCTAssertEqual(session.userID, "u1")
        XCTAssertEqual(session.name, "Pat")
    }
}

extension GuardianHarnessTests {
    /// Guardian can refuse inside a stream (`status` rides in the body there): the same plain words, not retried.
    func testARefusalInsideAStreamIsTheSameRefusal() {
        let body = #"{"error":"limit_reached","status":402,"limit":{"kind":"spend","window":"week","used":50,"max":50,"unit":"usd"},"message":"This week's Vision budget is spent."}"#
        let object = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        guard case .rejected(let status, let message, _, let permanent)? = OpenAIClient.guardianRefusal(inBody: object, data: Data(body.utf8)) else {
            return XCTFail()
        }
        XCTAssertEqual(status, 402)
        XCTAssertTrue(permanent)
        XCTAssertTrue(message.contains("Spend this week: $50.00 of $50.00"), message)
        XCTAssertEqual(GuardianLimit(kind: "requests", window: "run", used: 2, max: 2, unit: "streams").title, "Streams at once")
        XCTAssertEqual(GuardianLimit(kind: "requests", window: "run", used: 2, max: 2, unit: "streams").usage, "2 of 2 streams")
    }
}
