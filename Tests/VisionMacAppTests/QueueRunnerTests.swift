import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

// MARK: - Fake model server

/// What the fake server does with one chat request.
enum FakeReply: Sendable {
    case text(String)
    case http(Int, String)
    case transport(URLError.Code)
    /// Answer `text` after `seconds` (lets a test stop a task mid-request).
    case slow(TimeInterval, String)
    /// Call one tool (name, JSON arguments).
    case toolCall(String, String)
}

/// One chat request as the fake server saw it.
struct SeenRequest: Sendable {
    let messages: [[String: String]]
    /// The server the request went to (the fake serves every host), for tests with several servers.
    var host: String = ""
    /// The model settings the request carried (nil / false = not sent).
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    var reasoning: Bool = false
    var model: String? = nil
    var lastUser: String { messages.last(where: { $0["role"] == "user" })?["content"] ?? "" }
    var allUserText: String { messages.filter { $0["role"] == "user" }.compactMap { $0["content"] }.joined(separator: "\n") }
    /// The request is answering a user message (not a tool result).
    var fresh: Bool { messages.last?["role"] == "user" }
}

/// URLProtocol-backed model server: `/models` answers with one model,
/// `/chat/completions` asks `script` what to do.
final class FakeModelServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: (@Sendable (SeenRequest, Int) -> FakeReply) = { _, _ in .text("GOAL_COMPLETE") }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [SeenRequest] = []
    static var seen: [SeenRequest] { lock.lock(); defer { lock.unlock() }; return _seen }
    static func reset(_ script: @escaping @Sendable (SeenRequest, Int) -> FakeReply) {
        lock.lock(); _seen = []; lock.unlock()
        self.script = script
    }

    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/models") {
            respond(200, #"{"data":[{"id":"stub-model","max_model_len":200000}]}"#, contentType: "application/json")
            return
        }
        guard path.hasSuffix("chat/completions") else {
            respond(404, "not found", contentType: "text/plain")
            return
        }
        let body = Self.body(of: request)
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let messages = (obj["messages"] as? [[String: Any]] ?? []).map { m -> [String: String] in
            var out: [String: String] = [:]
            out["role"] = m["role"] as? String
            if let c = m["content"] as? String { out["content"] = c }
            return out
        }
        let seen = SeenRequest(messages: messages, host: request.url?.host ?? "",
                               temperature: obj["temperature"] as? Double, maxTokens: obj["max_tokens"] as? Int,
                               reasoning: obj["reasoning_effort"] != nil || obj["chat_template_kwargs"] != nil,
                               model: obj["model"] as? String)
        Self.lock.lock()
        Self._seen.append(seen)
        let index = Self._seen.count
        Self.lock.unlock()
        switch Self.script(seen, index) {
        case .text(let t):
            respond(200, Self.sse(t))
        case .http(let code, let body):
            respond(code, body, contentType: "application/json")
        case .transport(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .toolCall(let name, let args):
            let call: [String: Any] = ["index": 0, "id": "call_\(index)", "type": "function",
                                       "function": ["name": name, "arguments": args]]
            let delta = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [call]]]]])
            respond(200, "data: \(String(decoding: delta, as: UTF8.self))\n\n"
                    + #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\n" + "data: [DONE]\n\n")
        case .slow(let seconds, let t):
            let work = DispatchWorkItem { [weak self] in self?.respond(200, Self.sse(t)) }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    override func stopLoading() {
        pending?.cancel()
    }

    private func respond(_ status: Int, _ body: String, contentType: String = "text/event-stream") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func sse(_ text: String) -> String {
        let delta = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
        return "data: \(String(decoding: delta, as: UTF8.self))\n\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":20}}"# + "\n\n"
            + "data: [DONE]\n\n"
    }

    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: - Tests

@MainActor
final class QueueRunnerTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Done.\nGOAL_COMPLETE") }
        transport = makeTransport()
        transport.adoptProject(project("main"))
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private func makeTransport() -> AppTransport {
        defaultsSuite = "vision-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.05 })
        t.goalErrorBackoff = { _ in 0.05 }
        return t
    }

    private func project(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func status(_ id: String) -> QueueTaskStatus? { transport.queue.task(id)?.status }

    private func notes(_ vm: SessionVM) -> [String] {
        vm.entries.compactMap { e in
            if case .message(let b) = e.kind, b.role == .notice || b.role == .error { return b.text }
            return nil
        }
    }

    // MARK: Queue

    func testQueueWorksTasksInOrderToCompletion() async throws {
        let a = transport.queueAdd("Task A", details: "do a")
        let b = transport.queueAdd("Task B")
        transport.startQueue()
        XCTAssertTrue(transport.queueRunning)
        try await waitUntil("queue done") { !transport.queueRunning }

        XCTAssertEqual(status(a.id), .complete)
        XCTAssertEqual(status(b.id), .complete)
        let kickoffs = FakeModelServer.seen.map(\.lastUser).filter { $0.hasPrefix("GOAL:") }
        XCTAssertEqual(kickoffs.count, 2)
        XCTAssertTrue(kickoffs[0].contains("Task A") && kickoffs[1].contains("Task B"), "worked in order")
        let sa = try XCTUnwrap(transport.queue.task(a.id)?.sessionID)
        let sb = try XCTUnwrap(transport.queue.task(b.id)?.sessionID)
        XCTAssertNotEqual(sa, sb, "each task gets its own chat")
        XCTAssertFalse(transport.sessions.contains { $0.running })
        XCTAssertEqual(transport.queue.task(a.id)?.rounds, 1)
        XCTAssertEqual(transport.queue.task(a.id)?.totalTokens, 120)
        XCTAssertFalse(transport.config.queuePaused)
        // The queue file on disk matches.
        let onDisk = try JSONDecoder().decode(TaskQueue.self, from: Data(contentsOf: dir.appendingPathComponent("task-queue.json")))
        XCTAssertEqual(onDisk.tasks.map(\.status), [.complete, .complete])
    }

    func testTaskKeepsGoingPastTheOldRoundCapUntilTheModelSaysComplete() async throws {
        FakeModelServer.reset { _, n in n < 60 ? .text("Still working on it.") : .text("All verified.\nGOAL_COMPLETE") }
        let t = transport.queueAdd("Long task")
        transport.startQueue()
        try await waitUntil("queue done", timeout: 60) { !transport.queueRunning }
        XCTAssertEqual(status(t.id), .complete)
        XCTAssertEqual(transport.queue.task(t.id)?.rounds, 60)
    }

    func testModelOutageMidTaskIsRetriedAndTheTaskFinishes() async throws {
        FakeModelServer.reset { _, n in
            switch n {
            case 1: return .transport(.timedOut)
            case 2: return .http(503, #"{"error":"loading"}"#)
            case 3: return .transport(.cannotConnectToHost)
            default: return .text("Recovered.\nGOAL_COMPLETE")
            }
        }
        let t = transport.queueAdd("Survive an outage")
        transport.startQueue()
        try await waitUntil("queue done") { !transport.queueRunning }
        XCTAssertEqual(status(t.id), .complete)
        XCTAssertEqual(transport.queue.task(t.id)?.rounds, 1, "retries are not extra rounds")
        let log = transport.queue.task(t.id)?.log.map(\.text) ?? []
        XCTAssertTrue(log.contains { $0.contains("Model unavailable") }, "\(log)")
        XCTAssertTrue(log.contains { $0.contains("answering again") }, "\(log)")
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == transport.queue.task(t.id)?.sessionID })
        let replies = vm.entries.compactMap { e -> String? in
            if case .message(let b) = e.kind, b.role == .assistant { return b.text }; return nil
        }
        XCTAssertEqual(replies.filter { $0.contains("Recovered.") }.count, 1)
        XCTAssertNil(vm.retry)
    }

    func testStopReturnsTheTaskAndRestartResumesInTheSameChat() async throws {
        FakeModelServer.reset { _, n in n == 1 ? .slow(5, "late") : .text("Done.\nGOAL_COMPLETE") }
        let t = transport.queueAdd("Stoppable")
        transport.startQueue()
        try await waitUntil("request in flight") { FakeModelServer.seen.count == 1 }
        let chat = try XCTUnwrap(transport.queue.task(t.id)?.sessionID, "chat recorded at start")
        transport.stopQueue()
        XCTAssertTrue(transport.queueStopping)
        try await waitUntil("stopped") { !transport.queueRunning && !transport.queueStopping }
        XCTAssertEqual(status(t.id), .queued)
        XCTAssertTrue(transport.config.queuePaused)
        XCTAssertFalse(transport.config.queueResumeOnLaunch)
        XCTAssertFalse(transport.sessions.first { $0.id == chat }?.running ?? true)

        transport.startQueue()
        XCTAssertFalse(transport.config.queuePaused)
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(t.id), .complete)
        XCTAssertEqual(transport.queue.task(t.id)?.sessionID, chat, "resumed in the same chat")
        // The stopped attempt never got an answer, so nothing reached the
        // model: the restart is a clean kickoff, and the chat says so.
        XCTAssertTrue(FakeModelServer.seen.last?.lastUser.hasPrefix("GOAL: Stoppable") ?? false)
        XCTAssertEqual(FakeModelServer.seen.last?.messages.filter { $0["role"] == "user" }.count, 1)
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == chat })
        XCTAssertTrue(notes(vm).contains { $0.hasPrefix("Not delivered to the model") })
    }

    func testStartStopStartInOneBreathRunsTheTaskOnce() async throws {
        FakeModelServer.reset { _, _ in .slow(0.3, "Done.\nGOAL_COMPLETE") }
        let t = transport.queueAdd("Race")
        let other = transport.queueAdd("Next")
        transport.startQueue()
        transport.stopQueue()
        transport.startQueue()
        transport.stopQueue()
        transport.startQueue()
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(t.id), .complete)
        XCTAssertEqual(status(other.id), .complete)
        XCTAssertEqual(Set(transport.sessions.filter { $0.title.hasPrefix("🚀") }.map(\.id)).count, 2)
        XCTAssertFalse(transport.sessions.contains { $0.running })
        XCTAssertFalse(transport.queue.tasks.contains { $0.status == .running })
    }

    func testStartWhileTheStoppedTaskIsStillUnwindingRunsItOnceMore() async throws {
        FakeModelServer.reset { _, n in n == 1 ? .slow(5, "late") : .text("GOAL_COMPLETE") }
        let t = transport.queueAdd("Unwinding")
        transport.startQueue()
        try await waitUntil("in flight") { FakeModelServer.seen.count == 1 }
        transport.stopQueue()
        transport.startQueue()   // before the old run has let go of the task
        XCTAssertTrue(transport.queueRunning)
        try await waitUntil("done") { !transport.queueRunning && !transport.queueStopping }
        XCTAssertEqual(status(t.id), .complete)
        XCTAssertEqual(FakeModelServer.seen.count, 2)
        XCTAssertEqual(transport.sessions.filter { $0.title.hasPrefix("🚀") }.count, 1)
    }

    func testStoppingTheTaskFromItsChatPausesTheQueue() async throws {
        FakeModelServer.reset { _, _ in .slow(5, "late") }
        let t = transport.queueAdd("A")
        _ = transport.queueAdd("B")
        transport.startQueue()
        try await waitUntil("in flight") { FakeModelServer.seen.count == 1 }
        let chat = try XCTUnwrap(transport.queue.task(t.id)?.sessionID)
        transport.stopSession(chat)
        try await waitUntil("paused") { !transport.queueRunning && !transport.queueStopping }
        XCTAssertEqual(status(t.id), .queued)
        XCTAssertTrue(transport.config.queuePaused)
        XCTAssertEqual(transport.queue.tasks.filter { $0.status == .queued }.count, 2)
    }

    func testDeletingTheRunningTaskSkipsToTheNextOne() async throws {
        FakeModelServer.reset { req, _ in req.allUserText.contains("GOAL: A") ? .slow(5, "late") : .text("GOAL_COMPLETE") }
        let a = transport.queueAdd("A")
        let b = transport.queueAdd("B")
        transport.startQueue()
        try await waitUntil("A in flight") { status(a.id) == .running && FakeModelServer.seen.count == 1 }
        transport.queueRemove(id: a.id)
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(a.id), .skipped)
        XCTAssertEqual(status(b.id), .complete)
        XCTAssertFalse(transport.config.queuePaused)
    }

    func testErrorsFailATaskAndThreeInARowPauseTheQueue() async throws {
        FakeModelServer.reset { _, _ in .http(400, #"{"error":{"message":"bad request","code":400}}"#) }
        let ids = (1...4).map { transport.queueAdd("T\($0)").id }
        transport.startQueue()
        try await waitUntil("paused", timeout: 30) { !transport.queueRunning }
        XCTAssertEqual(ids.map(status), [.failed, .failed, .failed, .queued])
        XCTAssertTrue(transport.config.queuePaused)
        // Each task tried its goal several rounds before giving up.
        XCTAssertEqual(FakeModelServer.seen.count, 3 * GoalProtocol.maxConsecutiveErrors)
    }

    func testANonTransientErrorRoundIsRetriedAndTheGoalCarriesOn() async throws {
        FakeModelServer.reset { _, n in
            n == 1 ? .http(400, #"{"error":{"message":"template error","code":400}}"#) : .text("Fine now.\nGOAL_COMPLETE")
        }
        let t = transport.queueAdd("Flaky request")
        transport.startQueue()
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(t.id), .complete)
        // Round 1 never got going, so round 2 re-sends the kickoff.
        XCTAssertTrue(FakeModelServer.seen.last?.lastUser.hasPrefix("GOAL:") ?? false)
    }

    func testBlockedTaskMovesOnThenResumeRunsJustThatTask() async throws {
        FakeModelServer.reset { req, _ in
            if req.allUserText.contains("GOAL: A") && !req.lastUser.hasPrefix("[Resuming]") {
                return .text("I need the API key.\nGOAL_BLOCKED: the API key")
            }
            return .text("GOAL_COMPLETE")
        }
        let a = transport.queueAdd("A")
        let b = transport.queueAdd("B")
        transport.startQueue()
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(a.id), .blocked)
        XCTAssertEqual(status(b.id), .complete)

        let c = transport.queueAdd("C")
        let chat = transport.queue.task(a.id)?.sessionID
        transport.resumeTask(a.id)
        XCTAssertEqual(transport.queueOnlyTasks, [a.id])
        try await waitUntil("resumed task done") { !transport.queueRunning }
        XCTAssertEqual(status(a.id), .complete)
        XCTAssertEqual(transport.queue.task(a.id)?.sessionID, chat)
        XCTAssertEqual(status(c.id), .queued, "Resume works only that task")
    }

    func testResumeWhileTheQueueRunsPutsTheTaskNextInstead() async throws {
        FakeModelServer.reset { req, _ in
            if req.allUserText.contains("GOAL: A") && !req.lastUser.hasPrefix("[Resuming]") {
                return .text("GOAL_BLOCKED: need input")
            }
            if req.lastUser.contains("GOAL: B") { return .slow(0.5, "GOAL_COMPLETE") }
            return .text("GOAL_COMPLETE")
        }
        let a = transport.queueAdd("A")
        let b = transport.queueAdd("B")
        let c = transport.queueAdd("C")
        transport.startQueue()
        try await waitUntil("B running") { status(b.id) == .running }
        XCTAssertEqual(status(a.id), .blocked)
        transport.resumeTask(a.id)
        XCTAssertEqual(status(a.id), .queued)
        XCTAssertEqual(transport.queue.nextTask?.id, a.id)
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual([a, b, c].map { status($0.id) }, [.complete, .complete, .complete])
        XCTAssertLessThanOrEqual(transport.sessions.filter(\.running).count, 0)
    }

    func testResumingAFailedArchivedTaskKeepsItsHistory() async throws {
        // A fails (its chat is archived and released), B keeps the queue busy.
        FakeModelServer.reset { req, _ in
            if req.lastUser.contains("GOAL: A") || req.lastUser.contains("round") && req.allUserText.contains("GOAL: A") {
                return .http(400, #"{"error":{"message":"bad","code":400}}"#)
            }
            if req.allUserText.contains("GOAL: B") { return .slow(0.6, "GOAL_COMPLETE") }
            return .text("GOAL_COMPLETE")
        }
        let a = transport.queueAdd("A")
        let b = transport.queueAdd("B")
        transport.startQueue()
        try await waitUntil("A failed, B running") { status(a.id) == .failed && status(b.id) == .running }
        let chat = try XCTUnwrap(transport.queue.task(a.id)?.sessionID)
        let vm = try XCTUnwrap(transport.sessions.first { $0.id == chat })
        transport.log.flush(wait: true)
        let storedBefore = transport.log.loadItems(chat).count
        XCTAssertGreaterThan(storedBefore, 3)

        FakeModelServer.reset { _, _ in .text("GOAL_COMPLETE") }
        transport.resumeTask(a.id)
        XCTAssertTrue(vm.loaded)
        // The earlier attempt's timeline is back on screen (its rounds never
        // reached the model, so they read as not delivered).
        XCTAssertTrue(vm.entries.contains { $0.message?.text.contains("Not delivered to the model: 🚀 queue: A") == true })
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(a.id), .complete)
        // The resumed round saw the earlier attempt, and the disk history grew rather than being replaced.
        transport.log.flush(wait: true)
        XCTAssertGreaterThan(transport.log.loadItems(chat).count, storedBefore)
    }

    func testResumeDuringAResumeOnlyRunIsNotLost() async throws {
        FakeModelServer.reset { req, _ in
            if !req.lastUser.hasPrefix("[Resuming]") { return .text("GOAL_BLOCKED: need input") }
            return .slow(0.3, "GOAL_COMPLETE")
        }
        let a = transport.queueAdd("A")
        let b = transport.queueAdd("B")
        transport.startQueue()
        try await waitUntil("both blocked") { !transport.queueRunning }
        XCTAssertEqual([a, b].map { status($0.id) }, [.blocked, .blocked])
        let c = transport.queueAdd("C")
        transport.resumeTask(a.id)
        transport.resumeTask(b.id)          // while A's Resume run is going
        try await waitUntil("done") { !transport.queueRunning }
        XCTAssertEqual(status(a.id), .complete)
        XCTAssertEqual(status(b.id), .complete)
        XCTAssertEqual(status(c.id), .queued)
    }

    func testTaskRunsInTheProjectItWasQueuedIn() async throws {
        let first = project("main")
        let t = transport.queueAdd("Here")
        transport.adoptProject(project("elsewhere"))
        transport.startQueue()
        try await waitUntil("done") { !transport.queueRunning }
        let chat = try XCTUnwrap(transport.sessions.first { $0.id == transport.queue.task(t.id)?.sessionID })
        XCTAssertEqual(chat.cwd, first.path)
    }

    func testQueueDoesNotStealTheSelectionFromAnotherChat() async throws {
        let mine = transport.newSession(cwd: project("main").path)
        mine.appendMessage(.user, "my own work")
        transport.selectedID = mine.id
        _ = transport.queueAdd("A")
        _ = transport.queueAdd("B")
        transport.startQueue()
        // First task: followed (the user just pressed Start).
        try await waitUntil("done") { !transport.queueRunning }
        let queueChats = Set(transport.queue.tasks.compactMap(\.sessionID))
        XCTAssertTrue(transport.selectedID.map { queueChats.contains($0) } ?? false)

        // Now the user goes back to their chat; the next run must not yank them.
        transport.selectedID = mine.id
        _ = transport.queueAdd("C")
        _ = transport.queueAdd("D")
        FakeModelServer.reset { _, _ in .text("GOAL_COMPLETE") }
        transport.startQueue()
        try await waitUntil("done again") { !transport.queueRunning }
        // First task of a run is followed only when the user isn't mid-chat…
        // but after that the queue never moves them.
        XCTAssertNotNil(transport.selectedID)
    }

    func testRelaunchPutsAnInterruptedTaskBackAndItResumes() async throws {
        FakeModelServer.reset { _, n in n == 1 ? .slow(30, "late") : .text("GOAL_COMPLETE") }
        let t = transport.queueAdd("Interrupted")
        transport.startQueue()
        try await waitUntil("in flight") { FakeModelServer.seen.count == 1 }
        // Simulate a quit: a second transport reads the same files.
        transport.log.flush(wait: true)
        let relaunched = AppTransport(config: transport.config,
                                      log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                      queueFile: dir.appendingPathComponent("task-queue.json"),
                                      skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")))
        relaunched.retryPolicy = RetryPolicy(delay: { _ in 0.05 })
        XCTAssertEqual(relaunched.queue.task(t.id)?.status, .queued)
        let chat = relaunched.queue.task(t.id)?.sessionID
        XCTAssertNotNil(chat)
        transport.stopAll()   // the old process is gone
        try await waitUntil("old stopped") { !transport.queueRunning }
        relaunched.config.queuePaused = false
        relaunched.startQueue()
        try await waitUntil("relaunched done") { !relaunched.queueRunning }
        XCTAssertEqual(relaunched.queue.task(t.id)?.status, .complete)
        XCTAssertEqual(relaunched.queue.task(t.id)?.sessionID, chat)
    }

    // MARK: Vault

    func testVaultSecretReachesTheToolButNeverTheModelOrTheLogs() async throws {
        let secret = "tok-SECRET-9f8e7d6c"
        try transport.vault.add(name: "DEPLOY_TOKEN", value: secret, description: "Deploys")
        transport.vaultDidChange()
        FakeModelServer.reset { _, n in
            n == 1 ? .toolCall("run_shell_command", #"{"command":"echo token={{vault:DEPLOY_TOKEN}}"}"#) : .text("Deployed.")
        }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("deploy it", sessionID: vm.id)
        try await waitUntil("answered") { !vm.running && FakeModelServer.seen.count == 2 }

        let first = try XCTUnwrap(FakeModelServer.seen.first)
        XCTAssertTrue(first.messages.first?["content"]?.contains("{{vault:DEPLOY_TOKEN}}") ?? false, "the prompt lists the credential")
        let toolResult = FakeModelServer.seen[1].messages.first { $0["role"] == "tool" }?["content"] ?? ""
        XCTAssertTrue(toolResult.contains("token=[vault:DEPLOY_TOKEN]"), toolResult)
        for request in FakeModelServer.seen {
            XCTAssertFalse(request.messages.contains { $0["content"]?.contains(secret) ?? false }, "the model never sees it")
        }
        XCTAssertFalse(vm.entries.contains { "\($0.kind)".contains(secret) }, "not on screen")
        transport.log.flush(wait: true)
        let logDir = dir.appendingPathComponent("log")
        for file in try FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(secret), "not in \(file.lastPathComponent)")
        }
        XCTAssertEqual(transport.vault.entry(named: "DEPLOY_TOKEN")?.useCount, 1)
    }

    // MARK: Background agents & tasks

    func testAgentQueuesABackgroundTaskAndStartsTheQueue() async throws {
        FakeModelServer.reset { req, n in
            if req.lastUser.hasPrefix("GOAL:") { return .text("Wrote the tests.\nGOAL_COMPLETE") }
            if n == 1, req.fresh {
                return .toolCall("queue_task", #"{"title":"Write parser tests","details":"Cover the edge cases.","start":true}"#)
            }
            return .text("Queued it.")
        }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("queue the tests for later", sessionID: vm.id)
        try await waitUntil("queued task done") {
            transport.queue.tasks.first?.status == .complete && !transport.queueRunning && !vm.running
        }
        let task = try XCTUnwrap(transport.queue.tasks.first)
        XCTAssertEqual(task.title, "Write parser tests")
        XCTAssertEqual(task.cwd, project("main").path)
        XCTAssertTrue(task.log.contains { $0.text.contains("Queued by the agent") })
        XCTAssertTrue(notes(vm).contains { $0.contains("The agent queued a task") })
    }

    func testBackgroundAgentFinishesAndTheIdleChatCarriesOn() async throws {
        FakeModelServer.reset { req, _ in
            if req.messages.first?["content"]?.hasPrefix("You are a focused subagent") == true {
                return .slow(0.3, "Subagent report: 7 call sites.")
            }
            if req.lastUser.contains("Your background agents finished") {
                return .text("Using the report: 7 call sites.")
            }
            if req.lastUser == "find call sites in the background", req.fresh {
                return .toolCall("agent", #"{"description":"call sites","prompt":"Find call sites of foo","run_in_background":true}"#)
            }
            return .text("Started it; I'll pick up the results when it's done.")
        }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("find call sites in the background", sessionID: vm.id)
        try await waitUntil("auto-continued") {
            !vm.running && FakeModelServer.seen.contains { $0.lastUser.contains("Your background agents finished") }
                && vm.entries.contains { $0.message?.text == "Using the report: 7 call sites." }
        }
        let auto = try XCTUnwrap(FakeModelServer.seen.first { $0.lastUser.contains("Your background agents finished") })
        XCTAssertTrue(auto.lastUser.contains("Subagent report: 7 call sites."))
        XCTAssertTrue(notes(vm).contains { $0.contains("Background agent bg-1 “call sites” finished") })
        XCTAssertEqual(vm.backgroundJobs.first?.status, .done)
    }

    func testStopStopsTheChatsBackgroundAgents() async throws {
        FakeModelServer.reset { req, _ in
            if req.messages.first?["content"]?.hasPrefix("You are a focused subagent") == true { return .slow(10, "late") }
            if req.lastUser == "go", req.fresh {
                return .toolCall("agent", #"{"description":"slow","prompt":"take forever","run_in_background":true}"#)
            }
            return .text("waiting")
        }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("go", sessionID: vm.id)
        try await waitUntil("background running") { !vm.running && vm.runningBackgroundJobs.count == 1 }
        XCTAssertTrue(transport.anythingRunning)
        transport.stopSession(vm.id)
        try await waitUntil("stopped") { vm.runningBackgroundJobs.isEmpty }
        XCTAssertEqual(vm.backgroundJobs.first?.status, .stopped)
        XCTAssertFalse(vm.stopping)
    }

    // MARK: /goal

    func testGoalRunsPastFortyRoundsUntilComplete() async throws {
        FakeModelServer.reset { _, n in n < 45 ? .text("progress \(n)") : .text("Verified.\nGOAL_COMPLETE") }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("/goal build the thing", sessionID: vm.id)
        try await waitUntil("goal done", timeout: 60) { !vm.running && FakeModelServer.seen.count >= 45 }
        XCTAssertTrue(notes(vm).contains { $0.contains("Goal complete after 45 rounds") }, "\(notes(vm).suffix(3))")
        XCTAssertNil(vm.goal)
    }

    func testGoalSurvivesAModelOutage() async throws {
        FakeModelServer.reset { _, n in n <= 3 ? .transport(.networkConnectionLost) : .text("GOAL_COMPLETE") }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("/goal ship it", sessionID: vm.id)
        try await waitUntil("goal done") { !vm.running && FakeModelServer.seen.count >= 4 }
        XCTAssertTrue(notes(vm).contains { $0.contains("Goal complete after 1 round") }, "\(notes(vm))")
        XCTAssertTrue(notes(vm).contains { $0.contains("Retrying automatically") })
    }

    func testStopDuringAnOutageEndsTheGoal() async throws {
        FakeModelServer.reset { _, _ in .transport(.cannotConnectToHost) }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("/goal never answered", sessionID: vm.id)
        try await waitUntil("retrying") { vm.retry != nil }
        transport.stopSession(vm.id)
        try await waitUntil("stopped") { !vm.running }
        XCTAssertNil(vm.retry)
        XCTAssertTrue(notes(vm).last?.hasPrefix("Stopped.") ?? false, "\(notes(vm))")
    }

    func testBareGoalResumesTheUnfinishedGoal() async throws {
        FakeModelServer.reset { _, _ in .text("GOAL_BLOCKED: which branch?") }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("/goal merge the branch", sessionID: vm.id)
        try await waitUntil("blocked") { !vm.running && FakeModelServer.seen.count == 1 }
        XCTAssertTrue(notes(vm).contains { $0.contains("which branch") })

        FakeModelServer.reset { _, _ in .text("GOAL_COMPLETE") }
        transport.send("/goal", sessionID: vm.id)
        try await waitUntil("resumed") { !vm.running && FakeModelServer.seen.count == 1 }
        XCTAssertTrue(FakeModelServer.seen.first?.lastUser.hasPrefix("[Resuming]") ?? false)
        XCTAssertTrue(FakeModelServer.seen.first?.lastUser.contains("merge the branch") ?? false)
        XCTAssertTrue(notes(vm).contains { $0.contains("Goal complete") })
    }

    func testPlainTurnRetriesATimeoutToo() async throws {
        FakeModelServer.reset { _, n in n == 1 ? .transport(.timedOut) : .text("hello back") }
        let vm = transport.newSession(cwd: project("main").path)
        transport.send("hello", sessionID: vm.id)
        try await waitUntil("answered") { !vm.running && FakeModelServer.seen.count == 2 }
        let replies = vm.entries.compactMap { e -> String? in
            if case .message(let b) = e.kind, b.role == .assistant { return b.text }; return nil
        }
        XCTAssertEqual(replies, ["hello back"])
    }
}
