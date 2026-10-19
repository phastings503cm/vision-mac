import XCTest
@testable import VisionHarnessCore

/// What each kind of route is sent for attachments. The rule under test: no model server ever gets a content part
/// it can't take — no `file` part anywhere, pictures only to models that take them, native documents only on Bedrock.
final class AttachmentWireTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VisionRejections.shared.reset()
    }

    override func tearDown() {
        VisionRejections.shared.reset()
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    // MARK: Routes

    static let openAIRoutes: [ProviderProfile] = [
        .init(kind: .openAICompat, name: "vLLM on the Spark", baseURL: "http://spark.local:8002/v1", model: "Qwen/Qwen3.8-27B"),
        .init(kind: .openAICompat, name: "SGLang", baseURL: "http://spark.local:30000/v1", model: "qwen3.8-27b"),
        .init(kind: .openAICompat, name: "llama.cpp", baseURL: "http://127.0.0.1:8080/v1", model: "qwen3-8b-q4"),
        .init(kind: .openAICompat, name: "Spark Swapper", baseURL: "https://spark.local:11443/v1", model: "my-ai"),
        .init(kind: .ollama, name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b"),
        .init(kind: .lmStudio, name: "LM Studio", baseURL: "http://127.0.0.1:1234/v1", model: "local-model"),
        .init(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1"),
        .init(kind: .openRouter, name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "qwen/qwen3-32b"),
        .init(kind: .openAICompat, name: "Kimi Code", baseURL: "https://api.kimi.com/coding/v1", model: "kimi-for-coding"),
        .init(kind: .guardian, name: "Guardian", baseURL: "https://guardian.503cm.com/api/harness/v1", model: "guardian/default"),
    ]

    static let claude = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    static let llama = "meta.llama3-1-70b-instruct-v1:0"

    private static let fixtures: [MessageAttachment] = {
        let pdf = MessageAttachment(kind: .file, name: "report.pdf",
                                    data: AttachmentFixtures.textPDF(["Revenue grew in the West.", "Contact ann@example.com for invoices."]))
        let md = MessageAttachment(kind: .file, name: "notes.md", data: Data("# Notes\nShip it.".utf8))
        let docx = MessageAttachment(kind: .file, name: "plan.docx", data: try! AttachmentFixtures.docx())
        let png = MessageAttachment(kind: .image, name: "shot.png", data: AttachmentFixtures.png(of: "TOTAL 42"))
        return [pdf, md, docx, png]
    }()

    private func prepared(_ attachments: [MessageAttachment], window: Int = 262_144) -> [MessageAttachment] {
        AttachmentPrep.prepare(attachments, window: window, store: nil).attachments
    }

    private func openAIBody(_ profile: ProviderProfile, _ attachments: [MessageAttachment], text: String = "see these") throws -> (json: String, user: Any) {
        let request = LLMRequest(systemPrompt: "s", messages: [.user(text, attachments: attachments)], tools: [], model: profile.model)
        let data = try OpenAIClient(profile: profile).makeBody(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        return (String(decoding: data, as: UTF8.self), messages.last!["content"]!)
    }

    // MARK: OpenAI-compatible routes

    func testNoOpenAICompatibleRouteEverGetsAFilePart() throws {
        let attachments = prepared(Self.fixtures)
        for profile in Self.openAIRoutes {
            let (json, user) = try openAIBody(profile, attachments)
            XCTAssertFalse(json.contains(#""type":"file""#), profile.name)
            XCTAssertFalse(json.contains("file_data"), profile.name)
            let parts = try XCTUnwrap(user as? [[String: Any]], profile.name)
            let types = parts.compactMap { $0["type"] as? String }
            XCTAssertEqual(Set(types), ["text", "image_url"], profile.name)
            XCTAssertEqual(types.filter { $0 == "image_url" }.count, 1, profile.name)
            let texts = parts.compactMap { $0["text"] as? String }
            XCTAssertEqual(texts.first, "see these")
            XCTAssertTrue(texts.contains { $0.hasPrefix("[Attached file: report.pdf — PDF · 2 pages]\n--- Page 1 of 2 ---\nRevenue grew in the West.") }, "\(profile.name): \(texts)")
            XCTAssertTrue(texts.contains { $0.contains("--- Page 2 of 2 ---\nContact ann@example.com for invoices.") }, profile.name)
            XCTAssertTrue(texts.contains("[Attached file: notes.md — Markdown · 2 lines]\n# Notes\nShip it.\n[End of notes.md]"), profile.name)
            XCTAssertTrue(texts.contains { $0.hasPrefix("[Attached file: plan.docx — Word · 8 lines]\n# Quarterly Plan\n## Goals") }, profile.name)
            let url = (parts.first { $0["type"] as? String == "image_url" }?["image_url"] as? [String: Any])?["url"] as? String
            XCTAssertTrue(url?.hasPrefix("data:image/png;base64,") ?? false, profile.name)
        }
    }

    func testFilesAloneGoAsOnePlainString() throws {
        // A text-only message is a string — what every server and chat template takes.
        let attachments = prepared(Array(Self.fixtures.prefix(3)))
        for profile in Self.openAIRoutes {
            let (_, user) = try openAIBody(profile, attachments)
            let text = try XCTUnwrap(user as? String, profile.name)
            XCTAssertTrue(text.hasPrefix("see these\n\n[Attached file: report.pdf — PDF · 2 pages]\n"), profile.name)
            XCTAssertTrue(text.contains("\n\n[Attached file: notes.md — Markdown · 2 lines]\n"), profile.name)
        }
    }

    func testAModelWithoutVisionGetsTheOCRText() throws {
        var profile = Self.openAIRoutes[0]
        profile.vision = false
        let (json, user) = try openAIBody(profile, prepared([Self.fixtures[3]]))
        XCTAssertFalse(json.contains("image_url"))
        let text = try XCTUnwrap(user as? String)
        XCTAssertTrue(text.hasPrefix("see these\n\n[Image: shot.png — this model can't take images; the text in it, read by OCR:]\n"), text)
        XCTAssertTrue(text.uppercased().contains("TOTAL 42"), text)
    }

    func testAScannedPDFGoesAsPageImagesToVisionModelsAndAsOCRTextOtherwise() throws {
        let scan = MessageAttachment(kind: .file, name: "scan.pdf", data: AttachmentFixtures.scannedPDF(["INVOICE 4471", "SIGNED"]))
        let ready = prepared([scan])
        var profile = Self.openAIRoutes[0]
        let (_, user) = try openAIBody(profile, ready)
        let parts = try XCTUnwrap(user as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "text", "image_url", "image_url"])
        XCTAssertEqual(parts[1]["text"] as? String, "[Attached file: scan.pdf — PDF · 2 pages · scanned — it has no text layer, so its pages follow as images]")
        profile.vision = false
        let (_, plain) = try openAIBody(profile, ready)
        let text = try XCTUnwrap(plain as? String)
        XCTAssertTrue(text.contains("[Attached file: scan.pdf — PDF · 2 pages · scanned · text read by OCR]\n--- Page 1 of 2 ---\n"), text)
        XCTAssertTrue(text.uppercased().contains("INVOICE 4471"), text)
    }

    func testAnUnreadFileStillNeverGoesAsAFilePart() throws {
        // A caller that skipped preparing (older code paths): text bytes go as text, anything else as a note.
        let raw = [MessageAttachment(kind: .file, name: "a.md", data: Data("hi".utf8)),
                   MessageAttachment(kind: .file, name: "b.pdf", data: Data("%PDF-1.7 bytes".utf8)),
                   MessageAttachment(kind: .file, name: "c.bin", data: Data([0, 1, 2]))]
        let (json, user) = try openAIBody(Self.openAIRoutes[0], raw)
        XCTAssertFalse(json.contains(#""type":"file""#))
        XCTAssertEqual(user as? String, "see these\n\n[Attached file: a.md]\nhi\n\n[Attached file: b.pdf (14 bytes of binary data, not shown)]\n\n[Attached file: c.bin (3 bytes of binary data, not shown)]")
    }

    func testDeliveryLabelsForTheComposer() {
        let route = AttachmentRoute.openAI(Self.openAIRoutes[0])
        let ready = Self.fixtures.map { AttachmentReader.digested($0) }
        XCTAssertEqual(ready.map { AttachmentWire.delivery($0, route: route).label },
                       ["sent as text", "sent as text", "sent as text", "sent as image"])
        XCTAssertEqual(AttachmentWire.delivery(ready[0], route: route, parts: 13).label, "sent as text in 13 parts")
        XCTAssertEqual(AttachmentWire.delivery(ready[3], route: .textOnly).label, "sent as text (OCR)")
        let claude = AttachmentRoute.bedrock(.init(kind: .bedrock, name: "b", baseURL: "", model: Self.claude), traits: BedrockModels.traits(Self.claude))
        XCTAssertEqual(AttachmentWire.delivery(ready[0], route: claude).label, "sent as PDF document")
        XCTAssertEqual(AttachmentWire.delivery(ready[0], route: claude, parts: 3).label, "sent as text in 3 parts")
        let blob = AttachmentReader.digested(MessageAttachment(kind: .file, name: "x.bin", data: Data([0, 1])))
        XCTAssertEqual(AttachmentWire.delivery(blob, route: route).label, "can't be read — name only")
        XCTAssertEqual(AttachmentDelivery.pageImages(1).label, "sent as 1 page image")
        XCTAssertEqual(AttachmentDelivery.pageImages(20).label, "sent as 20 page images")
    }

    // MARK: Bedrock

    private func bedrockContent(_ model: String, _ attachments: [MessageAttachment]) -> [JSONValue] {
        let profile = ProviderProfile(kind: .bedrock, name: "bedrock", baseURL: "", model: model, awsRegion: "us-east-1")
        let request = LLMRequest(systemPrompt: "s", messages: [.user("see these", attachments: attachments)], tools: [], model: model)
        let body = BedrockConverse.request(request, profile: profile)
        return body["messages"]?.array?.first?["content"]?.array ?? []
    }

    func testBedrockClaudeKeepsNativePDFDocuments() {
        let content = bedrockContent(Self.claude, prepared(Self.fixtures))
        XCTAssertEqual(content.compactMap { $0.object?.keys.first }, ["text", "document", "text", "text", "image", "cachePoint"])
        XCTAssertEqual(content[1]["document"]?["format"]?.string, "pdf")
        XCTAssertEqual(content[1]["document"]?["name"]?.string, "report")
        XCTAssertEqual(content[2]["text"]?.string, "[Attached file: notes.md — Markdown · 2 lines]\n# Notes\nShip it.\n[End of notes.md]")
        XCTAssertTrue(content[3]["text"]?.string?.hasPrefix("[Attached file: plan.docx — Word · 8 lines]") ?? false)
        XCTAssertEqual(content[4]["image"]?["format"]?.string, "png")
    }

    func testBedrockSendsALongPDFAsTextInParts() {
        let pages = (1...40).map { page in (1...30).map { "Page \(page) line \($0) with enough words to fill it." }.joined(separator: "\n") }
        let pdf = MessageAttachment(kind: .file, name: "big.pdf", data: AttachmentFixtures.textPDF(pages))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-wire-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = AttachmentPrep.prepare([pdf], window: 32_768, store: AttachmentStore.forChat("t", root: root))
        XCTAssertGreaterThan(ready.attachments[0].parts ?? 0, 1)
        let content = bedrockContent(Self.claude, ready.attachments)
        XCTAssertFalse(content.contains { $0["document"] != nil })
        XCTAssertTrue(content[1]["text"]?.string?.contains("Vision split it into") ?? false)
    }

    func testBedrockModelsWithoutDocumentsGetThePDFText() {
        let content = bedrockContent(Self.llama, prepared([Self.fixtures[0]]))
        XCTAssertEqual(content.compactMap { $0.object?.keys.first }, ["text", "text"])
        XCTAssertTrue(content[1]["text"]?.string?.hasPrefix("[Attached file: report.pdf — PDF · 2 pages]\n--- Page 1 of 2 ---") ?? false)
    }

    func testBedrockScansGoAsPageImagesWithinItsTwentyImageLimit() {
        let scan = MessageAttachment(kind: .file, name: "scan.pdf", data: AttachmentFixtures.scannedPDF(["ONE", "TWO"]))
        let pictures = (1...19).map { MessageAttachment(kind: .image, name: "p\($0).png", data: AttachmentFixtures.png(of: "P\($0)")) }
        let content = bedrockContent(Self.claude, prepared([scan] + pictures))
        let images = content.filter { $0["image"] != nil }.count
        XCTAssertEqual(images, 20, "Converse takes at most 20 images in a message")
        // The last picture past the limit goes as its OCR text.
        XCTAssertTrue(content.contains { $0["text"]?.string?.hasPrefix("[Image: p19.png — ") ?? false })
    }

    // MARK: The shield checks what is actually sent

    func testTheShieldMasksTheTextReadOutOfAFile() {
        let detector = SensitiveDetector(settings: ShieldSettings())
        let ready = prepared([Self.fixtures[0]])
        let request = LLMRequest(systemPrompt: "s", messages: [.user("read it", attachments: ready)], tools: [], model: "m")
        let route = AttachmentRoute.openAI(Self.openAIRoutes[6])
        let (masked, map, unchecked) = Shield.mask(request, detector: detector, route: route)
        XCTAssertFalse(unchecked, "the PDF goes as text here, and that text was checked")
        XCTAssertEqual(map.counts[.email], 1)
        let sent = masked.messages[0].attachments?[0].text ?? ""
        XCTAssertFalse(sent.contains("ann@example.com"))
        XCTAssertTrue(sent.contains("⟦EMAIL_1⟧"), sent)
        // Where the PDF's own bytes go (a Bedrock document), it can't be checked.
        let claude = AttachmentRoute.bedrock(.init(kind: .bedrock, name: "b", baseURL: "", model: Self.claude), traits: BedrockModels.traits(Self.claude))
        XCTAssertTrue(Shield.mask(request, detector: detector, route: claude).unchecked)
    }

    // MARK: A server that turns pictures down

    func testAServerThatTakesNoImagesIsLearnedAndAnsweredWithOCRText() async throws {
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
        let bodies = BodyLog()
        StubServer.reset { request in
            let body = StubServer.bodyText(request)
            bodies.append(body)
            if body.contains("image_url") {
                // llama.cpp without an mmproj, verbatim.
                return .init(status: 500, body: #"{"error":{"code":500,"message":"image input is not supported - hint: if this is unexpected, you may need to provide the mmproj","type":"server_error"}}"#, contentType: "application/json")
            }
            return .init(body: StubServer.sse("I read: TOTAL 42"))
        }
        let profile = ProviderProfile(kind: .openAICompat, name: "llama.cpp", baseURL: "http://stub.test/v1", model: "text-only")
        let client = OpenAIClient(profile: profile)
        let request = LLMRequest(systemPrompt: "s", messages: [.user("what does it say?", attachments: prepared([Self.fixtures[3]]))],
                                 tools: [], model: "text-only")
        var text = ""
        for try await event in client.stream(request) { if case .text(let d) = event { text += d } }
        XCTAssertEqual(text, "I read: TOTAL 42")
        XCTAssertEqual(bodies.all.count, 2)
        XCTAssertTrue(bodies.all[0].contains("image_url"))
        XCTAssertFalse(bodies.all[1].contains("image_url"))
        XCTAssertTrue(bodies.all[1].contains("read by OCR"))
        XCTAssertTrue(VisionRejections.shared.rejected(VisionRejections.key(profile, model: "text-only")))
        // From now on the route goes straight to text.
        for try await _ in client.stream(request) {}
        XCTAssertEqual(bodies.all.count, 3)
        XCTAssertFalse(bodies.all[2].contains("image_url"))
    }

    func testRejectionWordingFromRealServers() {
        XCTAssertTrue(VisionRejections.saysNoImages("image input is not supported - hint: if this is unexpected, you may need to provide the mmproj"))
        XCTAssertTrue(VisionRejections.saysNoImages("Resolving modality {'image'} requires a multimodal processor but none is available."))
        XCTAssertTrue(VisionRejections.saysNoImages("At most 0 image(s) may be provided in one prompt."))
        XCTAssertFalse(VisionRejections.saysNoImages("Unsupported chat content part type: 'file'. Supported types: audio_url, image_url, text."))
        XCTAssertFalse(VisionRejections.saysNoImages("This model's maximum context length is 32768 tokens"))
    }
}

/// Request bodies a stub server saw, in order.
final class BodyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    func append(_ body: String) { lock.withLock { bodies.append(body) } }
    var all: [String] { lock.withLock { bodies } }
}

extension StubServer {
    /// A request's body as text (URLSession hands it to a URLProtocol as a stream).
    static func bodyText(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
