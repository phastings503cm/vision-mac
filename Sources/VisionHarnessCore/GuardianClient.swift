import Foundation

// MARK: - Guardian as a model proxy
//
// Guardian (guardian.503cm.com) is the multiuser, multitenant side of the
// family: it fronts the models the account is allowed to use behind one
// OpenAI-compatible endpoint, and carries the shared things — the prompt
// history, skills, the vault. A Vision harness signs in with its Guardian
// login (email + password → a session token), then:
//
//   • talks to models through  POST /api/harness/v1/chat/completions
//   • lists what it may use     GET  /api/harness/v1/models
//   • syncs prompts             POST /api/harness/prompts        (item 4)
//   • deposits / takes skills   GET/PUT /api/harness/skills/...
//   • imports & exports chats   GET/PUT /api/harness/chats/...
//
// Everything is plain HTTPS + JSON with a bearer token, so the same client
// shape works from any Vision harness (this Mac app, the Windows one). Auth
// is the one Guardian-specific wrinkle: a login call exchanges the password
// for a long-lived token that this app keeps in the Keychain.

public struct GuardianSession: Codable, Hashable, Sendable {
    /// The signed-in user, as Guardian reports them.
    public var userID: String
    public var email: String
    public var name: String?
    /// The bearer token for harness calls.
    public var token: String
    /// When the token was issued; Guardian says how long it lasts.
    public var issuedAt: Date

    public init(userID: String, email: String, name: String?, token: String, issuedAt: Date = .now) {
        self.userID = userID
        self.email = email
        self.name = name
        self.token = token
        self.issuedAt = issuedAt
    }
}

/// One model the Guardian account may use.
public struct GuardianModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String?
    public var contextWindow: Int?
    /// Whether the plan this account is on allows unattended work (the queue,
    /// /goal) on this model — Guardian marks interactive-only plans.
    public var interactiveOnly: Bool?

    public init(id: String, label: String? = nil, contextWindow: Int? = nil, interactiveOnly: Bool? = nil) {
        self.id = id
        self.label = label
        self.contextWindow = contextWindow
        self.interactiveOnly = interactiveOnly
    }
}

/// One synced prompt-history entry (item 4: the notebook Guardian keeps).
public struct GuardianPrompt: Codable, Hashable, Sendable {
    /// Guardian's row id (on prompts read back; nil on the way up).
    public var id: String?
    public var text: String
    public var at: Date
    /// How the turn it came from ended, in Guardian's own words.
    public var outcome: String?
    /// Where it came from: "vision-mac" for this app.
    public var source: String?
    public var chatID: String?
    public var chatTitle: String?
    public var project: String?
    public var model: String?
    public var durationSeconds: Double?
    public var runID: String?

    public init(id: String? = nil, text: String, at: Date = .now, outcome: String? = nil, source: String? = nil,
                chatID: String? = nil, chatTitle: String? = nil, project: String? = nil, model: String? = nil,
                durationSeconds: Double? = nil, runID: String? = nil) {
        self.id = id
        self.text = text
        self.at = at
        self.outcome = outcome
        self.source = source
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.project = project
        self.model = model
        self.durationSeconds = durationSeconds
        self.runID = runID
    }

    enum CodingKeys: String, CodingKey {
        case id, text, at, outcome, source, chatTitle, project, model, durationSeconds
        case chatID = "chatId", runID = "runId"
    }
}

/// One HTTP response from Guardian.
public struct GuardianHTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]

    public init(data: Data, status: Int, headers: [String: String]) {
        self.data = data
        self.status = status
        self.headers = headers
    }
}

/// Errors the client translates into what a user can act on.
public enum GuardianError: LocalizedError, Equatable {
    case badURL
    case invalidCredentials(String)
    /// The account has TOTP 2FA on. The attached challenge is a short-lived
    /// JWT from Guardian — complete the sign-in with `verifyTwoFactor`.
    case twoFactorRequired(String)
    case unauthorized          // token expired or revoked
    /// A structured refusal (403 forbidden, 402/429 limits): what is missing, or which limit, in plain words.
    case problem(GuardianProblem)
    case server(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badURL:
            "That doesn't look like a Guardian address — it should be https://guardian.503cm.com (or your own deployment)."
        case .invalidCredentials(let detail):
            "Guardian didn't accept that sign-in. \(detail)"
        case .twoFactorRequired:
            "This Guardian account uses two-factor sign-in. Enter the 6-digit code from your authenticator app."
        case .unauthorized:
            "The Guardian sign-in has expired — sign in again to keep using it."
        case .problem(let problem):
            problem.oneLine()
        case .server(let detail):
            "Guardian had a problem: \(detail)"
        case .network(let detail):
            "Couldn't reach Guardian: \(detail)"
        }
    }
}

/// The Guardian harness API client. Synchronous-on-demand via a pluggable
/// transport (URLSession by default) so tests can script the responses.
public final class GuardianClient: @unchecked Sendable {
    /// The deployment's base address, e.g. https://guardian.503cm.com
    public let baseURL: URL
    /// The session once signed in (also carried by a restored client).
    public private(set) var session: GuardianSession?

    /// The HTTP layer.
    public typealias Transport = @Sendable (URLRequest) async throws -> GuardianHTTPResponse
    let transport: Transport

    private let stateLock = NSLock()
    private var _orgID: String?
    /// The organization calls act in (`x-guardian-org`); nil = the account's active/default org.
    public var orgID: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _orgID }
        set { stateLock.lock(); _orgID = newValue?.isEmpty == true ? nil : newValue; stateLock.unlock() }
    }

    public init(baseURL: String, session: GuardianSession? = nil, transport: Transport? = nil) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw GuardianError.badURL
        }
        self.baseURL = url
        self.session = session
        self.transport = transport ?? Self.urlSessionTransport()
    }

    /// The real HTTP layer: a plain URLSession call, headers flattened to strings.
    private static func urlSessionTransport() -> Transport {
        let closure: Transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var headers: [String: String] = [:]
            for (key, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                headers["\(key)"] = "\(value)"
            }
            return GuardianHTTPResponse(data: data, status: status, headers: headers)
        }
        return closure
    }

    public var isSignedIn: Bool { session != nil }

    // MARK: Auth

    /// Sign in with the Guardian login. Guardian's own login endpoint issues
    /// a session; the harness endpoint accepts the same credentials and
    /// scopes the session to harness work.
    public func signIn(email: String, password: String) async throws -> GuardianSession {
        struct Body: Encodable { var email: String; var password: String; var client: String }
        let issued = Date()
        let data = try await post(path: "/api/auth/login", body: Body(email: email, password: password, client: "vision-harness"),
                                  token: nil)
        struct Response: Decodable {
            /// `{id, email, name}` or Guardian's session shape `{userId, email, name}` — every field optional, so
            /// one shape missing a field never loses the token beside it.
            struct User: Decodable { var id: String?; var userId: String?; var email: String?; var name: String? }
            var token: String?
            var user: User?
            /// Guardian's own login shape: `{ok, session:{userId, email}, token}`.
            var session: User?
            // A few shapes Guardian has used; the client accepts them all.
            var accessToken: String?
            var sessionToken: String?
            var id: String?
            var email: String?
            var name: String?
            var error: String?
            var message: String?
            /// 2FA on the account: `{ok, twoFactorRequired: true, challenge: jwt}`.
            var twoFactorRequired: Bool?
            var challenge: String?
        }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        // A TOTP account gets no token on the first call — Guardian hands back
        // a short-lived challenge to finish with `verifyTwoFactor(code:)`.
        if decoded?.twoFactorRequired == true, let challenge = decoded?.challenge, !challenge.isEmpty {
            throw GuardianError.twoFactorRequired(challenge)
        }
        let token = decoded?.token ?? decoded?.accessToken ?? decoded?.sessionToken
        guard let token, !token.isEmpty else {
            if let statusDetail = decoded?.error ?? decoded?.message {
                throw GuardianError.invalidCredentials(statusDetail)
            }
            throw GuardianError.invalidCredentials("Check the email and password.")
        }
        let user = decoded?.user ?? decoded?.session
        let email = user?.email ?? decoded?.email ?? email
        let newSession = GuardianSession(
            userID: user?.id ?? user?.userId ?? decoded?.id ?? email,
            email: email,
            name: user?.name ?? decoded?.name,
            token: token, issuedAt: issued)
        session = newSession
        return newSession
    }

    /// Finish a 2FA sign-in: exchange the challenge from
    /// `GuardianError.twoFactorRequired` plus the 6-digit authenticator code
    /// for the real session (Guardian's `POST /auth/login/2fa`).
    public func verifyTwoFactor(challenge: String, code: String) async throws -> GuardianSession {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            throw GuardianError.invalidCredentials("The 2FA code is the 6-digit number from your authenticator app.")
        }
        struct Body: Encodable { var challenge: String; var code: String }
        let issued = Date()
        let data: Data
        do {
            data = try await post(path: "/api/auth/login/2fa", body: Body(challenge: challenge, code: trimmed),
                                  token: nil)
        } catch GuardianError.unauthorized {
            // Guardian 401s a wrong or rotated code; to the user that's a
            // retryable credentials problem, not an expired session.
            throw GuardianError.invalidCredentials("Guardian didn't accept that code — it may have rotated. Codes refresh every 30 seconds; enter the current one.")
        }
        struct Response: Decodable {
            struct User: Decodable {
                var id: String?
                /// Guardian's session shape: `{userId, email, name}`.
                var userId: String?
                var email: String?
                var name: String?
                var uid: String?
            }
            var token: String?
            var session: User?
            var error: String?
            var message: String?
        }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        guard let token = decoded?.token, !token.isEmpty else {
            let detail = decoded?.error ?? decoded?.message ?? "Check the code and try again — codes rotate every 30 seconds."
            throw GuardianError.invalidCredentials(detail)
        }
        let user = decoded?.session
        let newSession = GuardianSession(
            userID: user?.id ?? user?.userId ?? user?.uid ?? session?.email ?? "",
            email: user?.email ?? session?.email ?? "",
            name: user?.name ?? session?.name,
            token: token, issuedAt: issued)
        session = newSession
        return newSession
    }

    public func signOut() { session = nil }

    /// Take a session obtained another way (the browser sign-in's token exchange).
    public func adopt(_ newSession: GuardianSession) { session = newSession }

    // MARK: Models (the proxy)

    /// What the Guardian account may run, through the proxy.
    public func models() async throws -> [GuardianModel] {
        struct Response: Decodable {
            struct Model: Decodable {
                var id: String
                var label: String?
                var contextWindow: Int?
                var interactiveOnly: Bool?
            }
            var models: [Model]?
            // An OpenAI-style list also works.
            struct Data_: Decodable { var id: String }
            var `data`: [Data_]?
        }
        let data = try await get(path: "/api/harness/v1/models")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        if let models = decoded.models {
            return models.map { GuardianModel(id: $0.id, label: $0.label, contextWindow: $0.contextWindow,
                                              interactiveOnly: $0.interactiveOnly) }
        }
        return (decoded.data ?? []).map { GuardianModel(id: $0.id) }
    }

    // MARK: Prompt history sync (item 4)

    /// Push prompts used locally up to Guardian's prompt history. Signed in
    /// or not, the caller decides when: the app syncs on submit when signed in.
    @discardableResult
    public func pushPrompts(_ prompts: [GuardianPrompt]) async throws -> Int {
        struct Body: Encodable { var prompts: [GuardianPrompt] }
        let body = Body(prompts: prompts.map { prompt in
            var up = prompt
            up.id = nil
            return up
        })
        let data = try await post(path: "/api/harness/prompts", body: body, token: session?.token)
        struct Response: Decodable { var accepted: Int? }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        return decoded?.accepted ?? prompts.count
    }

    /// The prompt history Guardian holds for this account — the notebook,
    /// browsable in Guardian and from the harness.
    public func prompts(limit: Int = 200, before: Date? = nil) async throws -> [GuardianPrompt] {
        struct Response: Decodable { var prompts: [GuardianPrompt]? }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: ISO8601DateFormatter().string(from: before))) }
        let data = try await get(path: "/api/harness/prompts", query: query)
        let decoded = try Self.decoder.decode(Response.self, from: data)
        return decoded.prompts ?? []
    }

    // MARK: Skills

    /// Deposit a skill (its SKILL.md text and any bundled files) into
    /// Guardian, so any harness on the account can run it.
    public func putSkill(name: String, description: String, files: [String: String]) async throws {
        struct Body: Encodable { var name: String; var description: String; var files: [String: String] }
        struct Response: Decodable { var error: String? }
        let data = try await post(path: "/api/harness/skills", body: Body(name: name, description: description, files: files),
                                  token: session?.token)
        _ = data   // 2xx is enough; a body is optional
    }

    /// Take the account's skills down to this harness.
    public func skills() async throws -> [(name: String, description: String, files: [String: String])] {
        struct Response: Decodable {
            struct Skill: Decodable { var name: String; var description: String?; var files: [String: String]? }
            var skills: [Skill]?
        }
        let data = try await get(path: "/api/harness/skills")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        return (decoded.skills ?? []).map { ($0.name, $0.description ?? "", $0.files ?? [:]) }
    }

    // MARK: Chats (import/export)

    /// Export one local chat's transcript to Guardian. `payload` is the
    /// harness's own JSON transcript — Guardian stores it opaquely and lists
    /// it under the account, so an import round-trips faithfully.
    public func putChat(id: String, title: String, updatedAt: Date, payload: Data) async throws {
        struct Body: Encodable { var title: String; var updatedAt: Date; var payload: String }
        let body = Body(title: title, updatedAt: updatedAt, payload: String(decoding: payload, as: UTF8.self))
        _ = try await post(path: "/api/harness/chats/\(id)", body: body, token: session?.token)
    }

    /// Import a chat's transcript back from Guardian.
    public func chat(id: String) async throws -> Data {
        let data = try await get(path: "/api/harness/chats/\(id)")
        struct Response: Decodable { var payload: String? }
        if let decoded = try? Self.decoder.decode(Response.self, from: data), let payload = decoded.payload {
            return Data(payload.utf8)
        }
        return data
    }

    /// The chats the account holds, for the import picker.
    public func chats() async throws -> [(id: String, title: String, updatedAt: Date)] {
        struct Response: Decodable {
            struct Chat: Decodable { var id: String; var title: String; var updatedAt: Date }
            var chats: [Chat]?
        }
        let data = try await get(path: "/api/harness/chats")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        return (decoded.chats ?? []).map { ($0.id, $0.title, $0.updatedAt) }
    }

    // MARK: Code projects (the repo drop)

    /// Upload a code folder's manifest to Guardian's repo store — the
    /// github-like place a user's projects live, from where the AI Coders
    /// module can work on them. Files arrive as text + relative paths;
    /// binaries ride in a later chunked upload (out of scope here).
    public func putProject(name: String, files: [String: String]) async throws {
        struct Body: Encodable { var name: String; var files: [String: String] }
        _ = try await post(path: "/api/harness/projects", body: Body(name: name, files: files), token: session?.token)
    }

    // MARK: The shared ETA cache

    /// Push finished-turn durations up to Guardian's shared cache. Guardian
    /// is multitenant: every harness on the org teaches every other, which
    /// is the whole reason to keep the samples server-side.
    public func pushEtaSamples(_ samples: [(kind: TurnPhaseState.TaskKind, scope: Double, seconds: Double)]) async throws {
        struct Body: Encodable {
            struct Sample: Encodable { var kind: String; var scope: Double; var seconds: Double; var harness: String }
            var samples: [Sample]
        }
        let body = Body(samples: samples.map {
            .init(kind: $0.kind.rawValue, scope: $0.scope, seconds: $0.seconds, harness: "vision-mac")
        })
        _ = try await post(path: "/api/harness/eta", body: body, token: session?.token)
    }

    /// Pull the org's learned durations per kind — the multitenant cache —
    /// in the same shape the local `TurnPhaseRunner` keeps.
    public func etaSummary() async throws -> [TurnPhaseState.TaskKind: TurnPhaseState.DurationSample] {
        struct Response: Decodable {
            struct Entry: Decodable { var count: Int; var meanSeconds: Double; var meanScope: Double }
            var byKind: [String: Entry]
        }
        let data = try await get(path: "/api/harness/eta")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        var out: [TurnPhaseState.TaskKind: TurnPhaseState.DurationSample] = [:]
        for (key, entry) in decoded.byKind {
            if let kind = TurnPhaseState.TaskKind(rawValue: key) {
                out[kind] = TurnPhaseState.DurationSample(count: entry.count,
                                                          meanSeconds: entry.meanSeconds,
                                                          meanScope: entry.meanScope)
            }
        }
        return out
    }

    /// Blend the org's learned durations into the local runner: each kind's
    /// local mean moves halfway toward Guardian's when Guardian has more
    /// evidence than this Mac does. Called on sign-in and after pushes.
    public func syncEtas(into runner: TurnPhaseRunner) async throws {
        let shared = try await etaSummary()
        for (kind, entry) in shared where entry.count > 0 {
            let local = runner.sample(for: kind)
            if local.count == 0 {
                runner.mergeSample(kind: kind, entry)
            } else if entry.count > local.count {
                let merged = TurnPhaseState.DurationSample(
                    count: max(local.count, 1) + entry.count,
                    meanSeconds: (local.meanSeconds * Double(local.count) + entry.meanSeconds * Double(entry.count))
                        / Double(local.count + entry.count),
                    meanScope: (local.meanScope * Double(local.count) + entry.meanScope * Double(entry.count))
                        / Double(local.count + entry.count))
                runner.mergeSample(kind: kind, merged)
            }
        }
    }

    // MARK: Wire helpers

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            // ISO8601 with or without fractions; then epoch seconds as a fallback.
            let iso = ISO8601DateFormatter()
            let isoFractions = ISO8601DateFormatter()
            isoFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFractions.date(from: raw) ?? iso.date(from: raw) { return date }
            if let seconds = TimeInterval(raw) { return Date(timeIntervalSince1970: seconds) }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unreadable date \(raw)")
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        decorate(&request, token: session?.token)
        let response = try await transport(request)
        try Self.check(response.status, data: response.data, headers: response.headers)
        return response.data
    }

    func post<B: Encodable>(path: String, body: B, token: String?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        decorate(&request, token: token)
        request.httpBody = try Self.encoder.encode(body)
        let response = try await transport(request)
        try Self.check(response.status, data: response.data, headers: response.headers)
        return response.data
    }

    /// The bearer token and the chosen organization, on every call that has them.
    func decorate(_ request: inout URLRequest, token: String?) {
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let orgID { request.setValue(orgID, forHTTPHeaderField: "x-guardian-org") }
    }

    /// Status → error, with the body's message when Guardian sent one. Structured refusals (403, 402, 429) become
    /// `.problem` and are reported for the app's dialog.
    static func check(_ status: Int, data: Data, headers: [String: String] = [:]) throws {
        guard !(200...299).contains(status) else { return }
        struct Body: Decodable { var error: String?; var message: String? }
        let detail = (try? JSONDecoder().decode(Body.self, from: data))
            .flatMap { $0.message ?? $0.error }
        if status != 401, let problem = GuardianProblem.parse(status: status, body: data, headers: headers) {
            GuardianProblems.report(problem)
            throw GuardianError.problem(problem)
        }
        switch status {
        case 401: throw GuardianError.unauthorized
        case 403:
            let problem = GuardianProblem(status: 403, error: "forbidden", message: detail)
            GuardianProblems.report(problem)
            throw GuardianError.problem(problem)
        case 400, 422: throw GuardianError.invalidCredentials(detail ?? "The request was refused.")
        default: throw GuardianError.server(detail ?? "HTTP \(status)")
        }
    }
}
