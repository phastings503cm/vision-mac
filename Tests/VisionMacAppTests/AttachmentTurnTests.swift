import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A model server that keeps every request body whole (content arrays, tools and all), so a test can look at
/// exactly what went on the wire. `/models` reports a 32K window, like a Qwen on a small server.
final class RawModelServer: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case text(String)
        case toolCall(name: String, arguments: String)
    }

    nonisolated(unsafe) static var script: @Sendable (Int) -> Reply = { _ in .text("ok") }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bodies: [[String: Any]] = []
    static var bodies: [[String: Any]] { lock.withLock { _bodies } }
    static func reset(_ script: @escaping @Sendable (Int) -> Reply) {
        lock.withLock { _bodies = [] }
        self.script = script
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/models") {
            respond(#"{"data":[{"id":"qwen-small","max_model_len":32768}]}"#, type: "application/json")
            return
        }
        let raw = HostFixtures.bodyText(request)
        let body = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        let index = Self.lock.withLock { () -> Int in
            Self._bodies.append(body.merging(["_raw": raw]) { a, _ in a })
            return Self._bodies.count
        }
        switch Self.script(index) {
        case .text(let text):
            let delta = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
            respond("data: \(String(decoding: delta, as: UTF8.self))\n\n"
                    + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        case .toolCall(let name, let arguments):
            let call: [String: Any] = ["index": 0, "id": "call_\(index)", "type": "function",
                                       "function": ["name": name, "arguments": arguments]]
            let delta = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [call]]]]])
            respond("data: \(String(decoding: delta, as: UTF8.self))\n\n"
                    + #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"# + "\n\ndata: [DONE]\n\n")
        }
    }

    override func stopLoading() {}

    private func respond(_ body: String, type: String = "text/event-stream") {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Attachments through the whole harness: the composer's files and a 10,000-line paste go out as text the server
/// takes, a long one in parts the model reads back with read_attachment, and the chat remembers what it carried.
@MainActor
final class AttachmentTurnTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-attach-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [RawModelServer.self]
        RawModelServer.reset { _ in .text("Got it.") }
        defaultsSuite = "vision-attach-tests-\(UUID().uuidString)"
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "Qwen on the Spark", baseURL: "http://spark.test/v1", model: "qwen-small"))
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: logDir),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    private var logDir: URL { dir.appendingPathComponent("log", isDirectory: true) }

    struct NoReply: Error {}

    /// Waits for the turn to end with `replies` answers; a timeout fails the test and stops it there (it throws), so a
    /// slow run (Apple's OCR under load) fails one test instead of crashing the bundle on an empty request list.
    private func waitForIdle(_ vm: SessionVM, replies: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(30)
        while vm.running || vm.entries.filter({ $0.message?.role == .assistant }).count < replies {
            if Date() > deadline {
                XCTFail("no reply; entries: \(vm.entries.map { $0.message?.text ?? $0.tool?.name ?? "?" })")
                throw NoReply()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func userContent(_ body: [String: Any]) -> String {
        let messages = body["messages"] as? [[String: Any]] ?? []
        return messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? "(not a string)"
    }

    func testAPasteAndAPDFGoAsTextAndTheLongOneInParts() async throws {
        let vm = transport.newSession(cwd: dir.path)
        let paste = PastedText.attachment(HostFixtures.lines(10_214, width: 40))
        let pdf = MessageAttachment(kind: .file, name: "report.pdf",
                                    data: HostFixtures.textPDF(["Revenue grew in the West.", "Appendix: invoices."]))
        transport.send("Summarise these", sessionID: vm.id, attachments: [paste, pdf])
        try await waitForIdle(vm)

        let body = try XCTUnwrap(RawModelServer.bodies.first)
        let raw = body["_raw"] as? String ?? ""
        XCTAssertFalse(raw.contains(#""type":"file""#), "no file part ever reaches the server")
        let user = Self.userContent(body)
        XCTAssertTrue(user.hasPrefix("Summarise these\n\n[Attached file: pasted-text.txt — Pasted text · 10,214 lines · 409 KB]\nThis file is too long to send whole"), user)
        XCTAssertTrue(user.contains(#"call the read_attachment tool with {"name": "pasted-text.txt", "part": N}"#))
        XCTAssertTrue(user.contains("[Attached file: report.pdf — PDF · 2 pages]\n--- Page 1 of 2 ---\nRevenue grew in the West."), user)
        // Two files share the quarter of the 32K window the message may use.
        XCTAssertLessThan(user.utf16.count, 32_768 + 2_000)
        let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(tools.contains("read_attachment"))

        // The transcript shows what went, the log keeps it, the store holds the text.
        let entry = try XCTUnwrap(vm.entries.first { $0.message?.role == .user })
        XCTAssertEqual(entry.message?.text, "Summarise these")
        let parts = AttachmentPrep.split(HostFixtures.lines(10_214, width: 40),
                                         size: AttachmentBudget(window: 32_768, sharing: 2).partChars).count
        XCTAssertEqual(entry.message?.attachments.map(\.label),
                       ["Pasted text · 10,214 lines · 409 KB · sent as text in \(parts) parts", "PDF · 2 pages · sent as text"])
        XCTAssertEqual(entry.message?.attachments.map(\.stored), ["pasted-text.txt", "report.pdf"])
        let store = transport.attachmentStore(for: vm.id)
        XCTAssertEqual(store.entries().map(\.name), ["pasted-text.txt", "report.pdf"])

        transport.log.flush(wait: true)
        let reopened = ConversationLog(dir: logDir).loadItems(vm.id)
        XCTAssertEqual(reopened.first { $0.kind == "user" }?.attachments?.map(\.stored), ["pasted-text.txt", "report.pdf"])

        // After a restart the rebuilt conversation tells the model where the files are.
        let replayed = AppTransport.replayMessages(vm.entries)
        let note = try XCTUnwrap(replayed.first { $0.role == .user }?.content)
        XCTAssertTrue(note.hasPrefix("Summarise these\n\n[Attached: pasted-text.txt — Pasted text · 10,214 lines · 409 KB · sent as text in \(parts) parts. Its text is saved with this chat: read it with read_attachment {\"name\": \"pasted-text.txt\"}"), note)
    }

    func testTheModelReadsTheNextPartWithReadAttachment() async throws {
        RawModelServer.reset { index in
            index == 1 ? .toolCall(name: "read_attachment", arguments: #"{"name":"pasted-text.txt","part":2}"#) : .text("Read part 2.")
        }
        let vm = transport.newSession(cwd: dir.path)
        transport.send("What is in part 2?", sessionID: vm.id,
                       attachments: [PastedText.attachment(HostFixtures.lines(3_000, width: 40))])
        try await waitForIdle(vm)
        XCTAssertEqual(RawModelServer.bodies.count, 2)
        let messages = try XCTUnwrap(RawModelServer.bodies.dropFirst().first)["messages"] as? [[String: Any]] ?? []
        let result = messages.last { $0["role"] as? String == "tool" }?["content"] as? String ?? ""
        let partSize = AttachmentBudget(window: 32_768).partChars
        let parts = AttachmentPrep.split(HostFixtures.lines(3_000, width: 40), size: partSize)
        XCTAssertTrue(result.hasPrefix("[pasted-text.txt — part 2 of \(parts.count) · lines \(parts[1].firstLine)–\(parts[1].lastLine)"), result)
        XCTAssertTrue(result.contains(parts[1].text))
        XCTAssertEqual(vm.entries.last?.message?.text, "Read part 2.")
    }

    func testAPictureGoesToAVisionModelAndItsTextToOneWithout() async throws {
        let vm = transport.newSession(cwd: dir.path)
        let picture = MessageAttachment(kind: .image, name: "shot.png", data: HostFixtures.png(of: "TOTAL 42"))
        transport.send("read it", sessionID: vm.id, attachments: [picture])
        try await waitForIdle(vm)
        let first = try XCTUnwrap(RawModelServer.bodies.first)["_raw"] as? String ?? ""
        XCTAssertTrue(first.contains("image_url"))

        let old = try XCTUnwrap(transport.config.activeProvider)
        var route = old
        route.vision = false
        transport.config.replace(old, with: route)
        transport.send("again", sessionID: vm.id, attachments: [picture])
        try await waitForIdle(vm, replies: 2)
        let second = RawModelServer.bodies.last ?? [:]
        XCTAssertFalse((second["_raw"] as? String ?? "").contains("image_url"))
        let user = Self.userContent(second)
        XCTAssertTrue(user.contains("[Image: shot.png — this model can't take images; the text in it, read by OCR:]"), user)
        XCTAssertEqual(vm.entries.last { $0.message?.role == .user }?.message?.attachments.first?.label, "Image · sent as text (OCR)")
    }

    /// "Paste 10,000 lines while it works and press Enter": the paste goes onto the chat's tasks with the prompt (bytes
    /// kept on disk, listed in task-queue.json), and when its turn comes it is sent exactly as a fresh send — in parts,
    /// with read_attachment. Deleting the task deletes the bytes. (Windows does the same, review finding 3.)
    func testAQueuedPromptCarriesItsPasteAndSendsItWhenItsTurnComes() async throws {
        let vm = transport.newSession(cwd: dir.path)
        let paste = PastedText.attachment(HostFixtures.lines(10_000, width: 40))
        let task = try XCTUnwrap(transport.addChatTask("", sessionID: vm.id, attachments: [paste]))
        XCTAssertEqual(task.title, "📎 Pasted text")
        let kept = try XCTUnwrap(task.attachments)
        XCTAssertEqual(kept.map(\.kind), ["pasted"])
        XCTAssertTrue(kept[0].file.hasPrefix("queued/"), kept[0].file)
        XCTAssertTrue(vm.entries.contains { $0.message?.text.hasSuffix("Its attachment goes with it.") == true })
        let file = try String(contentsOf: dir.appendingPathComponent("task-queue.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(#""attachments""#) && file.contains(#""kind" : "pasted""#) || file.contains(#""kind":"pasted""#), file)

        try await waitForIdle(vm)
        let deadline = Date().addingTimeInterval(10)
        while transport.queue.task(task.id)?.status != .complete, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(transport.queue.task(task.id)?.status, .complete)
        let user = Self.userContent(try XCTUnwrap(RawModelServer.bodies.first))
        XCTAssertTrue(user.hasPrefix("[Attached file: pasted-text.txt — Pasted text · 10,000 lines · "), user)
        XCTAssertTrue(user.contains("This file is too long to send whole"), user)
        let badge = try XCTUnwrap(vm.entries.first { $0.message?.role == .user }?.message?.attachments.first?.label)
        XCTAssertTrue(badge.hasPrefix("Pasted text · 10,000 lines · ") && badge.contains("· sent as text in "), badge)

        let bytes = try XCTUnwrap(transport.attachmentStore(for: vm.id).queuedURL(kept[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bytes.path))
        transport.removeChatTask(task.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bytes.path), "deleting the task deletes what it kept")
    }

    /// A kept attachment that vanished: the task fails with the reason, and the list pauses.
    func testAQueuedPromptWhoseAttachmentIsGoneFailsAndPausesTheList() async throws {
        let vm = transport.newSession(cwd: dir.path)
        transport.chatTasksPaused[vm.id] = "Paused — nothing new starts until you resume."
        let first = try XCTUnwrap(transport.addChatTask("see the notes", sessionID: vm.id,
                                                        attachments: [MessageAttachment(kind: .file, name: "notes.md", data: Data("# N".utf8))]))
        _ = try XCTUnwrap(transport.addChatTask("then this", sessionID: vm.id))
        let folder = try XCTUnwrap(transport.attachmentStore(for: vm.id).queuedURL(try XCTUnwrap(first.attachments?.first)))
            .deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        transport.chatTasksPaused[vm.id] = nil
        transport.pumpChatTasks(vm)
        XCTAssertEqual(transport.queue.task(first.id)?.status, .failed)
        XCTAssertEqual(transport.chatTasksPaused[vm.id], "Paused — the last task failed.")
        XCTAssertTrue(transport.queue.task(first.id)?.log.contains { $0.text.contains("its attachment “notes.md” is no longer on this Mac") } == true)
        XCTAssertTrue(RawModelServer.bodies.isEmpty, "nothing was sent")
    }

    func testDeletingAChatDeletesItsSavedAttachments() async throws {
        let vm = transport.newSession(cwd: dir.path)
        transport.send("keep", sessionID: vm.id,
                       attachments: [MessageAttachment(kind: .file, name: "a.md", data: Data("# A".utf8))])
        try await waitForIdle(vm)
        let folder = transport.attachmentStore(for: vm.id).directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        transport.deleteSession(vm.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
