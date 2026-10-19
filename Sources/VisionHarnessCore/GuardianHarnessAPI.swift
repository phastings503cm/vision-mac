import Foundation
import CryptoKit
import Security
import Darwin

// MARK: - The rest of the Guardian ⇄ Vision contract (v1)
//
// harness-api-contract.md, beyond the password sign-in and the syncs GuardianClient.swift has had since 0.15:
//   • browser sign-in for Entra-SSO / passwordless accounts: loopback redirect + PKCE (S256)
//   • GET /api/harness/me — who, which organizations (x-guardian-org picks one), modules, permissions, limits
//   • GET /api/harness/limits — the allowance left, per kind and window
//   • GET /api/harness/vault + POST /api/harness/vault/:id/reveal — secrets the person marked "Usable in Vision"
//   • GET /api/harness/projects (+ /:id) — the person's uploaded code projects

/// One organization the account belongs to.
public struct GuardianOrg: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The account's active/default organization.
    public var active: Bool?

    public init(id: String, name: String, active: Bool? = nil) {
        self.id = id
        self.name = name
        self.active = active
    }
}

/// GET /api/harness/me.
public struct GuardianAccount: Hashable, Sendable {
    public var userID: String
    public var email: String
    public var name: String?
    public var orgs: [GuardianOrg]
    public var modules: [String]
    public var permissions: [String]
    public var limits: [GuardianLimit]

    /// The organization calls go to when none is picked.
    public var activeOrg: GuardianOrg? { orgs.first { $0.active == true } ?? orgs.first }

    public init(userID: String, email: String, name: String?, orgs: [GuardianOrg], modules: [String], permissions: [String],
                limits: [GuardianLimit]) {
        self.userID = userID
        self.email = email
        self.name = name
        self.orgs = orgs
        self.modules = modules
        self.permissions = permissions
        self.limits = limits
    }
}

/// A secret in the person's Guardian vault marked "Usable in Vision" (names only until revealed).
public struct GuardianVaultSecret: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The environment-variable name Guardian keeps it under (FRESHDESK_API_KEY): the name it is used by here too.
    public var envKey: String?
    /// The service it belongs to ("freshdesk").
    public var service: String?
    /// Guardian's item type ("api_key", "password", "login", "token"…).
    public var itemType: String?
    public var kind: String?
    public var description: String?
    public var hasValue: Bool?
    public var updatedAt: Date?

    public init(id: String, name: String, envKey: String? = nil, service: String? = nil, itemType: String? = nil,
                kind: String? = nil, description: String? = nil, hasValue: Bool? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.envKey = envKey
        self.service = service
        self.itemType = itemType
        self.kind = kind
        self.description = description
        self.hasValue = hasValue
        self.updatedAt = updatedAt
    }
}

/// One code project uploaded to Guardian.
public struct GuardianProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var updatedAt: Date?
    public var fileCount: Int?
    /// Mirrored to a private repo for AI Coders.
    public var aiCoders: Bool?
}

/// A PKCE pair (RFC 7636, S256) and the `state` that ties the browser's answer to this sign-in.
public struct GuardianPKCE: Sendable, Equatable {
    public var verifier: String
    public var challenge: String
    public var state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.state = state
    }

    /// 32 random bytes → a 43-character base64url verifier; 16 more for the state.
    public static func make() -> GuardianPKCE {
        GuardianPKCE(verifier: base64URL(randomBytes(32)), state: base64URL(randomBytes(16)))
    }

    /// BASE64URL(SHA256(ASCII(verifier))), no padding.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        return Data(bytes)
    }
}

/// What the browser sign-in can end in, besides a session.
public enum GuardianBrowserSignInError: LocalizedError, Equatable {
    case cancelled(String)
    case stateMismatch
    case timedOut
    case listener(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled(let why): "The Guardian sign-in was cancelled in the browser (\(why))."
        case .stateMismatch: "The browser's answer didn't match this sign-in, so it was ignored. Start the sign-in again."
        case .timedOut: "No answer came back from the browser. Start the sign-in again, and finish it in the browser window that opens."
        case .listener(let why): "Vision couldn't wait for the browser's answer: \(why)."
        }
    }
}

// MARK: - The loopback redirect

/// A one-shot HTTP listener on 127.0.0.1 that waits for the browser to come back to
/// `http://127.0.0.1:<port>/callback?code=…&state=…` (RFC 8252 §7.3), answers with a short page, and hands the
/// query over. Bound to the loopback interface only; anything but GET /callback gets a 404 and the wait goes on.
public final class GuardianLoopback: @unchecked Sendable {
    public let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw GuardianBrowserSignInError.listener("no socket (\(errno))") }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else {
            close(socketFD)
            throw GuardianBrowserSignInError.listener("couldn't listen on 127.0.0.1 (\(errno))")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        fd = socketFD
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { stop() }

    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(fd)
    }

    /// Wait (off the caller's thread) for the browser's GET /callback; the query items it carried.
    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.acceptLoop(deadline: Date().addingTimeInterval(timeout)) })
            }
        }
    }

    private func acceptLoop(deadline: Date) throws -> [String: String] {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw GuardianBrowserSignInError.timedOut }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 0.5) * 1000))
            lock.lock(); let isClosed = closed; lock.unlock()
            if isClosed { throw GuardianBrowserSignInError.cancelled("stopped") }
            if ready <= 0 { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { continue }
            let request = String(decoding: buffer.prefix(count), as: UTF8.self)
            guard let query = Self.callbackQuery(request) else {
                respond(client, status: "404 Not Found", body: "Not found.")
                continue
            }
            let ok = query["code"] != nil && query["error"] == nil
            respond(client, status: "200 OK", body: ok
                ? "Signed in to \(AppIdentity.name). You can close this tab and go back to the app."
                : "The sign-in didn't finish (\(query["error"] ?? "no code")). You can close this tab and try again from \(AppIdentity.name).")
            return query
        }
    }

    /// The query of a `GET /callback?…` request line, or nil for anything else.
    static func callbackQuery(_ request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: String(parts[1])),
              components.path == "/callback" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return query
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>\(AppIdentity.name)</title>"
            + "<body style=\"font:16px -apple-system,sans-serif;margin:4em auto;max-width:32em\"><p>\(body)</p></body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
    }
}

// MARK: - The client calls

extension GuardianClient {
    /// The consent page the browser opens: Guardian's cookie-authenticated page where the person picks the org.
    public func browserSignInURL(redirectURI: String, pkce: GuardianPKCE, device: String) -> URL {
        var parts = URLComponents(url: baseURL.appendingPathComponent("app/connect/vision"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device", value: device),
            // Guardian's consent page names the app from this ("Vision for macOS") and tags the session with it.
            URLQueryItem(name: "client", value: "vision-mac"),
        ]
        return parts.url!
    }

    /// POST /api/harness/connect/token — the code from the browser plus the PKCE verifier, for a harness token.
    public func exchangeConnectCode(code: String, verifier: String, redirectURI: String) async throws -> (GuardianSession, orgID: String?) {
        struct Body: Encodable { var code: String; var code_verifier: String; var redirect_uri: String }   // swiftlint:disable:this identifier_name
        struct Response: Decodable {
            struct User: Decodable { var id: String?; var userId: String?; var email: String?; var name: String? }
            var token: String?
            var session: User?
            var user: User?
            var orgId: String?
            var error: String?
            var message: String?
        }
        let issued = Date()
        let data: Data
        do {
            data = try await post(path: "/api/harness/connect/token",
                                  body: Body(code: code, code_verifier: verifier, redirect_uri: redirectURI), token: nil)
        } catch GuardianError.unauthorized {
            throw GuardianError.invalidCredentials("Guardian didn't accept the browser's sign-in code (it may have expired). Start the sign-in again.")
        }
        let decoded = try? Self.decoder.decode(Response.self, from: data)
        guard let token = decoded?.token, !token.isEmpty else {
            throw GuardianError.invalidCredentials(decoded?.message ?? decoded?.error ?? "Guardian sent no token back.")
        }
        let user = decoded?.session ?? decoded?.user
        let email = user?.email ?? ""
        let newSession = GuardianSession(userID: user?.id ?? user?.userId ?? email, email: email, name: user?.name,
                                         token: token, issuedAt: issued)
        adopt(newSession)
        if let org = decoded?.orgId, !org.isEmpty { orgID = org }
        return (newSession, decoded?.orgId)
    }

    /// The whole browser sign-in: listen on loopback, open the consent page (`open` is the app's browser call),
    /// wait for the redirect, check `state`, exchange the code.
    public func signInWithBrowser(device: String, timeout: TimeInterval = 300,
                                  open: @Sendable (URL) async -> Void) async throws -> (GuardianSession, orgID: String?) {
        let loopback = try GuardianLoopback()
        defer { loopback.stop() }
        let pkce = GuardianPKCE.make()
        await open(browserSignInURL(redirectURI: loopback.redirectURI, pkce: pkce, device: device))
        let query = try await withTaskCancellationHandler {
            try await loopback.waitForCallback(timeout: timeout)
        } onCancel: {
            loopback.stop()
        }
        if let error = query["error"] {
            throw GuardianBrowserSignInError.cancelled(query["error_description"] ?? error)
        }
        guard query["state"] == pkce.state else { throw GuardianBrowserSignInError.stateMismatch }
        guard let code = query["code"], !code.isEmpty else { throw GuardianBrowserSignInError.cancelled("no code") }
        return try await exchangeConnectCode(code: code, verifier: pkce.verifier, redirectURI: loopback.redirectURI)
    }

    // MARK: Account

    /// GET /api/harness/me.
    public func me() async throws -> GuardianAccount {
        let data = try await get(path: "/api/harness/me")
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GuardianError.server("Guardian's account answer couldn't be read.")
        }
        let user = root["user"] as? [String: Any] ?? [:]
        let orgs: [GuardianOrg] = (root["orgs"] as? [[String: Any]] ?? []).compactMap { org in
            guard let id = (org["id"] as? String) ?? (org["id"] as? NSNumber)?.stringValue else { return nil }
            return GuardianOrg(id: id, name: org["name"] as? String ?? id, active: org["active"] as? Bool)
        }
        return GuardianAccount(
            userID: (user["id"] as? String) ?? (user["id"] as? NSNumber)?.stringValue ?? session?.userID ?? "",
            email: user["email"] as? String ?? session?.email ?? "",
            name: user["name"] as? String,
            orgs: orgs,
            modules: Self.strings(root["modules"]),
            permissions: Self.strings(root["permissions"]),
            limits: Self.limits(root["limits"]))
    }

    /// GET /api/harness/limits.
    public func limits() async throws -> [GuardianLimit] {
        let data = try await get(path: "/api/harness/limits")
        let root = try? JSONSerialization.jsonObject(with: data)
        return Self.limits((root as? [String: Any])?["limits"] ?? root)
    }

    /// Modules or permissions as names: ["insights", …] or [{key|id|name: …}, …].
    static func strings(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else {
            if let map = value as? [String: Any] { return map.filter { ($0.value as? Bool) != false }.map(\.key).sorted() }
            return []
        }
        return list.compactMap { item in
            if let text = item as? String { return text }
            if let object = item as? [String: Any] { return (object["key"] ?? object["id"] ?? object["name"]) as? String }
            return nil
        }
    }

    /// Limits as Guardian sends them: an array, an object holding `limits`, or an object of limit objects.
    static func limits(_ value: Any?) -> [GuardianLimit] {
        var raw: [[String: Any]] = []
        if let list = value as? [[String: Any]] {
            raw = list
        } else if let object = value as? [String: Any] {
            if let list = object["limits"] as? [[String: Any]] {
                raw = list
            } else {
                raw = object.keys.sorted().compactMap { key in
                    guard var item = object[key] as? [String: Any] else { return nil }
                    if item["kind"] == nil { item["kind"] = key }
                    return item
                }
            }
        }
        return raw.map { item in
            GuardianLimit(kind: item["kind"] as? String ?? "spend", window: item["window"] as? String ?? "",
                          used: GuardianProblem.number(item["used"]), max: GuardianProblem.number(item["max"]),
                          unit: item["unit"] as? String, resetsAt: item["resetsAt"].flatMap(GuardianProblem.date))
        }
    }

    // MARK: Vault (opt-in per secret)

    /// GET /api/harness/vault — names only.
    public func vaultSecrets() async throws -> [GuardianVaultSecret] {
        struct Response: Decodable { var secrets: [GuardianVaultSecret]? }
        let data = try await get(path: "/api/harness/vault")
        if let decoded = try? Self.decoder.decode(Response.self, from: data), let secrets = decoded.secrets { return secrets }
        return (try? Self.decoder.decode([GuardianVaultSecret].self, from: data)) ?? []
    }

    /// POST /api/harness/vault/:id/reveal — the value (Guardian audits every hand-out).
    public func revealSecret(id: String) async throws -> String {
        struct Empty: Encodable {}
        struct Response: Decodable { var value: String?; var secret: String? }
        let path = "/api/harness/vault/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id)/reveal"
        let data = try await post(path: path, body: Empty(), token: session?.token)
        guard let decoded = try? Self.decoder.decode(Response.self, from: data), let value = decoded.value ?? decoded.secret, !value.isEmpty else {
            throw GuardianError.server("Guardian sent no value for that secret.")
        }
        return value
    }

    // MARK: Projects

    /// GET /api/harness/projects.
    public func projects() async throws -> [GuardianProject] {
        struct Response: Decodable { var projects: [GuardianProject]? }
        let data = try await get(path: "/api/harness/projects")
        if let decoded = try? Self.decoder.decode(Response.self, from: data), let projects = decoded.projects { return projects }
        return (try? Self.decoder.decode([GuardianProject].self, from: data)) ?? []
    }

    /// GET /api/harness/projects/:id — the manifest: path → text.
    public func project(id: String) async throws -> (name: String, files: [String: String]) {
        struct Response: Decodable { var name: String?; var files: [String: String]? }
        let data = try await get(path: "/api/harness/projects/\(id)")
        let decoded = try Self.decoder.decode(Response.self, from: data)
        return (decoded.name ?? id, decoded.files ?? [:])
    }
}
