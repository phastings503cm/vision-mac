import Foundation

// MARK: - Speaking JSON-RPC to an MCP server
//
// Two ways to reach a server, one interface: send a request and wait for its answer, or send a notification.
//  * stdio: Vision starts the program (through the login shell, so `npx`, `uvx`, `docker` are found as in Terminal)
//    and writes one JSON message per line to its stdin; its stdout carries one per line back. Lines that aren't
//    JSON (a shell profile that prints something) are ignored; stderr is kept (the last lines) to explain a failure.
//  * Streamable HTTP: every message is a POST to the server's address; the answer comes back as JSON, or as an
//    event stream that carries it. The server's `Mcp-Session-Id` goes on every later request.
// Requests the server makes of Vision are answered: `ping` with nothing, everything else with "method not found"
// (Vision offers the server no roots, sampling or elicitation).

public enum MCPError: LocalizedError, Sendable, Equatable {
    case notStarted(String)
    case exited(String)
    case timedOut(String)
    case server(code: Int, message: String)
    case http(Int, String)
    case badResponse(String)
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .notStarted(let why): "The server didn't start: \(why)"
        case .exited(let why): "The server stopped: \(why)"
        case .timedOut(let what): "The server didn't answer \(what) in time."
        case .server(let code, let message): "The server refused it (\(code)): \(message)"
        case .http(let status, let body):
            status == 401 || status == 403
                ? "The server turned Vision away (HTTP \(status)) — check its key or token in Settings ▸ MCP Servers. \(body.prefix(200))"
                : "The server answered HTTP \(status): \(body.prefix(300))"
        case .badResponse(let why): "The server's answer couldn't be read (\(why))."
        case .sessionExpired: "The server forgot the session."
        }
    }
}

/// A live link to one MCP server.
public protocol MCPConnection: AnyObject, Sendable {
    func start() async throws
    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func close() async
    /// The server announced something (`notifications/tools/list_changed`, …).
    var onNotification: (@Sendable (String, JSONValue?) -> Void)? { get set }
    /// What the server last said on stderr (stdio), for explaining a failure.
    var diagnostics: String { get }
    /// Whether it is still up.
    var isAlive: Bool { get }
}

enum JSONRPC {
    /// A message as it goes on the wire: compact, with `/` left as it is (JSONSerialization would write `\/`).
    static func encode(_ message: JSONValue) -> Data {
        (try? JSONSerialization.data(withJSONObject: message.anyValue,
                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { fields["params"] = params }
        return .object(fields)
    }

    static func notification(_ method: String, params: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { fields["params"] = params }
        return .object(fields)
    }

    /// The answer to a request the server made.
    static func reply(to message: JSONValue) -> JSONValue? {
        guard let id = message["id"], let method = message["method"]?.string else { return nil }
        if method == "ping" { return .object(["jsonrpc": "2.0", "id": id, "result": .object([:])]) }
        return .object(["jsonrpc": "2.0", "id": id,
                        "error": .object(["code": -32601, "message": .string("Method not found: \(method)")])])
    }

    /// A response's result, or the error it carries.
    static func result(of message: JSONValue) throws -> JSONValue {
        if let error = message["error"], !error.isNull {
            throw MCPError.server(code: error["code"]?.int ?? -1, message: error["message"]?.string ?? error.serialized())
        }
        return message["result"] ?? .null
    }

    /// What a message is: an answer to us (its id), a request from the server, or a notification.
    enum Kind { case response(Int), request, notification(String), other }

    static func kind(of message: JSONValue) -> Kind {
        let method = message["method"]?.string
        if let method {
            return message["id"] != nil && message["id"]?.isNull == false ? .request : .notification(method)
        }
        if let id = message["id"]?.int, message["result"] != nil || message["error"] != nil { return .response(id) }
        if let text = message["id"]?.string, let id = Int(text) { return .response(id) }
        return .other
    }
}

/// Pending requests, by id, with their continuations. Shared by both connections.
final class PendingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    func nextID() -> Int { lock.withLock { defer { next += 1 }; return next } }

    func add(_ id: Int, _ continuation: CheckedContinuation<JSONValue, Error>) {
        lock.withLock { waiting[id] = continuation }
    }

    /// Resume a waiting request (once: a later answer, timeout or failure for the same id does nothing).
    func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    func failAll(_ error: Error) {
        let all = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            defer { waiting.removeAll() }
            return Array(waiting.values)
        }
        all.forEach { $0.resume(throwing: error) }
    }
}

// MARK: - stdio

public final class MCPStdioConnection: MCPConnection, @unchecked Sendable {
    public let command: String
    public let args: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    /// Run through the login shell (so the user's PATH applies); tests start the program directly.
    let viaLoginShell: Bool

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let pending = PendingRequests()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var exited: String?
    private var _onNotification: (@Sendable (String, JSONValue?) -> Void)?
    private let writeQueue = DispatchQueue(label: "vision.mcp.stdio.write")

    public init(command: String, args: [String], environment: [String: String], workingDirectory: URL?,
                viaLoginShell: Bool = true) {
        self.command = command
        self.args = args
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.viaLoginShell = viaLoginShell
    }

    public var onNotification: (@Sendable (String, JSONValue?) -> Void)? {
        get { lock.withLock { _onNotification } }
        set { lock.withLock { _onNotification = newValue } }
    }

    public var diagnostics: String { lock.withLock { stderrTail } }
    public var isAlive: Bool { lock.withLock { exited == nil } && process.isRunning }

    public func start() async throws {
        if viaLoginShell {
            process.executableURL = URL(fileURLWithPath: PTY.defaultShell)
            // `exec "$@"` runs the program with its arguments exactly as given — no quoting to get wrong.
            process.arguments = ["-l", "-c", "exec \"$@\"", "vision-mcp", command] + args
        } else {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.received(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.receivedError(data) }
        }
        process.terminationHandler = { [weak self] finished in
            self?.terminated(status: finished.terminationStatus)
        }
        // A write to a server that already exited must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
        } catch {
            throw MCPError.notStarted(error.localizedDescription)
        }
    }

    public func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        if let why = lock.withLock({ exited }) { throw MCPError.exited(why) }
        let id = pending.nextID()
        let message = JSONRPC.request(id: id, method: method, params: params)
        let pending = self.pending
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.add(id, continuation)
                write(message)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    pending.resolve(id, with: .failure(MCPError.timedOut("“\(method)”")))
                }
            }
        } onCancel: { [weak self] in
            pending.resolve(id, with: .failure(CancellationError()))
            self?.write(JSONRPC.notification("notifications/cancelled", params: ["requestId": .number(Double(id))]))
        }
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        write(JSONRPC.notification(method, params: params))
    }

    public func close() async {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // A server that ignores SIGTERM is killed shortly after.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
        }
        pending.failAll(MCPError.exited("closed"))
    }

    private func write(_ message: JSONValue) {
        var line = JSONRPC.encode(message)
        line.append(0x0A)
        let data = line
        let handle = input.fileHandleForWriting
        writeQueue.async { [weak self] in
            do { try handle.write(contentsOf: data) } catch { self?.terminated(status: -1) }
        }
    }

    private func received(_ data: Data) {
        let lines: [Data] = lock.withLock {
            buffer.append(data)
            var out: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                out.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            // A runaway line without an end is dropped rather than held forever.
            if buffer.count > 64 * 1024 * 1024 { buffer.removeAll() }
            return out
        }
        for line in lines {
            let trimmed = line.drop { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }
            guard trimmed.first == UInt8(ascii: "{") || trimmed.first == UInt8(ascii: "["),
                  let message = JSONValue(parsing: Data(trimmed)) else { continue }
            if case .array(let batch) = message { batch.forEach(handle) } else { handle(message) }
        }
    }

    private func handle(_ message: JSONValue) {
        switch JSONRPC.kind(of: message) {
        case .response(let id):
            pending.resolve(id, with: Result { try JSONRPC.result(of: message) })
        case .request:
            if let reply = JSONRPC.reply(to: message) { write(reply) }
        case .notification(let method):
            onNotification?(method, message["params"])
        case .other:
            break
        }
    }

    private func receivedError(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            stderrTail += text
            if stderrTail.count > 4_000 { stderrTail = String(stderrTail.suffix(3_000)) }
        }
    }

    private func terminated(status: Int32) {
        let first: Bool = lock.withLock {
            guard exited == nil else { return false }
            exited = "exit code \(status)"
            return true
        }
        guard first else { return }
        // What it said on stderr as it went is the explanation: give the last of it a moment to arrive.
        let pending = self.pending
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let tail = (self?.diagnostics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let why = "exit code \(status)" + (tail.isEmpty ? "" : " — " + String(tail.suffix(400)))
            if let self { self.lock.withLock { self.exited = why } }
            pending.failAll(MCPError.exited(why))
        }
    }
}

// MARK: - Streamable HTTP

public final class MCPHTTPConnection: MCPConnection, @unchecked Sendable {
    public let url: URL
    public let headers: [String: String]
    private let session: URLSession
    private let pending = PendingRequests()
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?
    private var closed = false
    private var _onNotification: (@Sendable (String, JSONValue?) -> Void)?

    public init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public var onNotification: (@Sendable (String, JSONValue?) -> Void)? {
        get { lock.withLock { _onNotification } }
        set { lock.withLock { _onNotification = newValue } }
    }

    public var diagnostics: String { "" }
    public var isAlive: Bool { lock.withLock { !closed } }

    /// The negotiated protocol version, sent on every request after the handshake.
    func setProtocolVersion(_ version: String?) { lock.withLock { protocolVersion = version } }

    public func start() async throws {}

    private func makeRequest(body: Data, method: String = "POST") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = method == "POST" ? body : nil
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers where !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
        let (session, version) = lock.withLock { (sessionID, protocolVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        return request
    }

    public func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let id = pending.nextID()
        let body = JSONRPC.encode(JSONRPC.request(id: id, method: method, params: params))
        var request = makeRequest(body: body)
        request.timeoutInterval = max(timeout, 10)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse("not HTTP") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            lock.withLock { sessionID = session }
        }
        if http.statusCode == 404, lock.withLock({ sessionID != nil }), method != "initialize" {
            throw MCPError.sessionExpired
        }
        guard (200...299).contains(http.statusCode) else {
            var text = ""
            for try await line in bytes.lines {
                text += line + "\n"
                if text.count > 2_000 { break }
            }
            throw MCPError.http(http.statusCode, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("text/event-stream") {
            // Events until the one that answers this request; the server may send others first.
            var data: [String] = []
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                    // `lines` drops blank lines, so an event ends where its JSON is whole.
                    if let message = JSONValue(parsing: data.joined(separator: "\n")) {
                        data = []
                        if let answer = try await handle(message, waitingFor: id) { return answer }
                    }
                } else if line.isEmpty {
                    data = []
                }
            }
            throw MCPError.badResponse("the event stream ended without an answer")
        }
        var reply = Data()
        for try await byte in bytes { reply.append(byte) }
        guard let message = JSONValue(parsing: reply) else {
            throw MCPError.badResponse(String(decoding: reply.prefix(200), as: UTF8.self))
        }
        let messages = message.array ?? [message]
        for item in messages {
            if let answer = try await handle(item, waitingFor: id) { return answer }
        }
        throw MCPError.badResponse("no answer to the request in the reply")
    }

    /// Handle one message from the server; the result when it answers `id`.
    private func handle(_ message: JSONValue, waitingFor id: Int) async throws -> JSONValue? {
        switch JSONRPC.kind(of: message) {
        case .response(let answered) where answered == id:
            return try JSONRPC.result(of: message)
        case .request:
            if let reply = JSONRPC.reply(to: message) { try? await post(reply) }
        case .notification(let method):
            onNotification?(method, message["params"])
        default:
            break
        }
        return nil
    }

    private func post(_ message: JSONValue) async throws {
        let request = makeRequest(body: JSONRPC.encode(message))
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MCPError.http(http.statusCode, "")
        }
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        try await post(JSONRPC.notification(method, params: params))
    }

    public func close() async {
        let session: String? = lock.withLock {
            closed = true
            return sessionID
        }
        // Tell the server the session is over (best effort).
        guard session != nil else { return }
        let request = makeRequest(body: Data(), method: "DELETE")
        _ = try? await self.session.data(for: request)
    }
}
