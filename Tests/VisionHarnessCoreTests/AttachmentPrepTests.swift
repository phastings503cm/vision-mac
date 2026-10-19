import XCTest
@testable import VisionHarnessCore

/// Long files: the budget, the parts, the contents list, the store and `read_attachment`.
final class AttachmentPrepTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-attach-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store() -> AttachmentStore { AttachmentStore.forChat("chat-1", root: dir) }

    // MARK: Budget (pinned for Vision for Windows)

    func testTheBudgetIsAQuarterOfTheWindow() {
        let small = AttachmentBudget(window: 32_768)
        XCTAssertEqual(small.inlineTokens, 8_192)
        XCTAssertEqual(small.partTokens, 2_048)
        XCTAssertEqual(small.inlineChars, 32_768)
        XCTAssertEqual(small.partChars, 8_192)
        let qwen = AttachmentBudget(window: 262_144)
        XCTAssertEqual(qwen.inlineTokens, 65_536)
        XCTAssertEqual(qwen.partTokens, 8_000, "parts stay under the engine's 40,000-character tool-result cut")
        XCTAssertLessThan(qwen.partChars, 40_000)
        let shared = AttachmentBudget(window: 262_144, sharing: 4)
        XCTAssertEqual(shared.inlineTokens, 16_384)
        XCTAssertEqual(shared.partTokens, 8_000)
        let crowded = AttachmentBudget(window: 32_768, sharing: 10)
        XCTAssertEqual(crowded.inlineTokens, 2_000, "never under 2,000")
        XCTAssertEqual(crowded.partTokens, 1_000, "at most half the inline budget")
        XCTAssertEqual(AttachmentBudget(window: 100).window, 4_096)
    }

    // MARK: Splitting

    func testPartsBreakAtLinesAndRebuildTheText() {
        let text = AttachmentFixtures.lines(100, width: 40)   // 41 units a line with its break
        let parts = AttachmentPrep.split(text, size: 410)
        XCTAssertEqual(parts.count, 10)
        XCTAssertEqual(parts[1].firstLine, 11)
        XCTAssertEqual(parts[1].lastLine, 20)
        XCTAssertTrue(parts[1].text.hasPrefix("line 11: "))
        XCTAssertEqual(parts.map(\.text).joined(separator: "\n"), text)
        XCTAssertTrue(parts.allSatisfy { AttachmentText.length($0.text) <= 410 })
        XCTAssertEqual(AttachmentPrep.split("a\nb\nc\n", size: 1_000).map(\.lastLine), [3])
    }

    func testANewPageStartsANewPartOnceThePartIsHalfFull() {
        var pages: [String] = []
        for page in 1...3 {
            pages.append("--- Page \(page) of 3 ---\n" + (1...6).map { "page \(page) text \($0) padding padding" }.joined(separator: "\n"))
        }
        let text = pages.joined(separator: "\n\n")
        let parts = AttachmentPrep.split(text, size: 400)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.text.hasPrefix("--- Page") })
        XCTAssertEqual(parts.map(\.firstPage), [1, 2, 3])
        XCTAssertEqual(parts.map(\.lastPage), [1, 2, 3])
        XCTAssertEqual(AttachmentPrep.contentsLine(2, parts[1], unit: ("page", "pages")),
                       #"2. page 2 · lines 9–16 · "page 2 text 1 padding padding""#)
    }

    func testAVeryLongLineIsCutIntoPieces() {
        let line = String(repeating: "z", count: 1_000)
        let parts = AttachmentPrep.split("before\n" + line + "\nafter", size: 300)
        XCTAssertEqual(parts.first?.text, "before")
        XCTAssertTrue(parts.allSatisfy { AttachmentText.length($0.text) <= 300 })
        XCTAssertEqual(parts.dropFirst().filter { $0.firstLine == 2 }.map(\.text).joined().filter { $0 == "z" }.count, 1_000)
        XCTAssertTrue(parts.last?.text.hasSuffix("after") ?? false)
    }

    func testContentsLines() {
        let part = AttachmentPart(text: "\n## Revenue by region\nmore", firstLine: 611, lastLine: 902, firstPage: 7, lastPage: 9)
        XCTAssertEqual(AttachmentPrep.contentsLine(3, part, unit: ("page", "pages")), #"3. pages 7–9 · lines 611–902 · "Revenue by region""#)
        XCTAssertEqual(AttachmentPrep.contentsLine(1, part, unit: nil), #"1. lines 611–902 · "Revenue by region""#)
        let long = AttachmentPart(text: String(repeating: "word ", count: 30), firstLine: 1, lastLine: 1)
        XCTAssertEqual(AttachmentPrep.contentsLine(1, long, unit: nil), "1. line 1 · \"" + String(String(repeating: "word ", count: 12).prefix(59)) + "…\"")
    }

    // MARK: The message text

    func testAShortFileGoesWhole() {
        let digest = AttachmentReader.read(name: "notes.md", data: Data("hello\nworld".utf8), kind: .file)
        let inline = AttachmentPrep.inlineText(name: "notes.md", digest: digest, budget: AttachmentBudget(window: 32_768), readable: nil)
        XCTAssertEqual(inline.parts, 1)
        XCTAssertEqual(inline.text, "[Attached file: notes.md — Markdown · 2 lines]\nhello\nworld\n[End of notes.md]")
    }

    func testALongFileGoesAsContentsAndLeadingParts() {
        let text = AttachmentFixtures.lines(10_214, width: 40)
        let digest = PastedText.attachment(text).digest!
        let budget = AttachmentBudget(window: 32_768)
        let inline = AttachmentPrep.inlineText(name: "pasted-text.txt", digest: digest, budget: budget, readable: "pasted-text.txt")
        let expectedParts = AttachmentPrep.split(text, size: budget.partChars).count
        XCTAssertEqual(inline.parts, expectedParts)
        XCTAssertEqual(expectedParts, 52)
        let t = inline.text
        XCTAssertTrue(t.hasPrefix("[Attached file: pasted-text.txt — Pasted text · 10,214 lines · 409 KB]\nThis file is too long to send whole: about 104,694 tokens, and this model's context window is 32,768 tokens. Vision split it into 52 parts and saved them with this chat."), t)
        XCTAssertTrue(t.contains(#"call the read_attachment tool with {"name": "pasted-text.txt", "part": N}"#))
        XCTAssertTrue(t.contains(#"{"name": "pasted-text.txt", "search": "words to look for"}"#))
        XCTAssertTrue(t.contains("Contents (52 parts):\n1. lines 1–199 · \"line 1: \(String(repeating: "x", count: 32))\"\n2. lines 200–398"), t)
        XCTAssertTrue(t.contains("\n--- Part 1 of 52 ---\nline 1: "))
        XCTAssertFalse(t.contains("--- Part 52 of 52 ---"))
        XCTAssertLessThanOrEqual(AttachmentText.length(t), budget.inlineChars + 200)
        XCTAssertTrue(t.hasSuffix("more parts: read them with read_attachment]"), String(t.suffix(200)))
        // A big window takes it whole.
        let whole = AttachmentPrep.inlineText(name: "pasted-text.txt", digest: digest, budget: AttachmentBudget(window: 1_000_000), readable: nil)
        XCTAssertEqual(whole.parts, 1)
        XCTAssertTrue(whole.text.hasSuffix("line 10214: \(String(repeating: "x", count: 28))\n[End of pasted-text.txt]"))
    }

    func testAnUnreadableFileSaysWhy() {
        let digest = AttachmentReader.read(name: "blob.bin", data: Data([0, 1, 2, 3]), kind: .file)
        let inline = AttachmentPrep.inlineText(name: "blob.bin", digest: digest, budget: AttachmentBudget(window: 32_768), readable: nil)
        XCTAssertEqual(inline.text, "[Attached file: blob.bin — File · 4 bytes]\nVision can't read this kind of file, so only its name is sent.")
    }

    // MARK: Preparing a message

    func testPreparingSavesEveryReadableFileAndSplitsLongOnes() throws {
        let store = store()
        let md = MessageAttachment(kind: .file, name: "notes.md", data: Data("# Notes\nshort".utf8))
        let paste = PastedText.attachment(AttachmentFixtures.lines(5_000, width: 40))
        let prepared = AttachmentPrep.prepare([md, paste], window: 32_768, store: store)
        XCTAssertEqual(prepared.attachments.map(\.parts), [1, AttachmentPrep.split(AttachmentFixtures.lines(5_000, width: 40), size: AttachmentBudget(window: 32_768, sharing: 2).partChars).count])
        XCTAssertTrue(prepared.attachments.allSatisfy { $0.digest?.text.isEmpty ?? false }, "the full text isn't carried twice")
        XCTAssertTrue(prepared.attachments[0].text?.hasPrefix("[Attached file: notes.md — Markdown · 2 lines]\n# Notes\nshort") ?? false)
        XCTAssertTrue(prepared.attachments[1].text?.contains("Contents (") ?? false)
        XCTAssertEqual(prepared.badges.map(\.stored), ["notes.md", "pasted-text.txt"])
        XCTAssertEqual(prepared.badges.map(\.label), ["Markdown · 2 lines", "Pasted text · 5,000 lines · 200 KB"])
        XCTAssertEqual(store.entries().map(\.name), ["notes.md", "pasted-text.txt"])
        XCTAssertEqual(store.entry(named: "PASTED-TEXT.TXT")?.name, "pasted-text.txt")
        XCTAssertEqual(store.entry(named: "pasted-text")?.name, "pasted-text.txt")

        // The same file again keeps its entry; a different one under the same name gets its own.
        _ = AttachmentPrep.prepare([md], window: 32_768, store: store)
        let other = MessageAttachment(kind: .file, name: "notes.md", data: Data("# Other notes".utf8))
        let again = AttachmentPrep.prepare([other], window: 32_768, store: store)
        XCTAssertEqual(again.badges.first?.stored, "notes (2).md")
        XCTAssertTrue(again.attachments[0].text?.hasPrefix("[Attached file: notes (2).md — ") ?? false)
        XCTAssertEqual(store.entries().count, 3)
        let reread = try XCTUnwrap(store.text(of: XCTUnwrap(store.entry(named: "notes (2).md"))))
        XCTAssertEqual(reread, "# Other notes")
    }

    func testPicturesKeepTheirBytesAndCarryTheirOCRText() {
        let png = AttachmentFixtures.png(of: "HELLO 123")
        let prepared = AttachmentPrep.prepare([MessageAttachment(kind: .image, name: "a.png", data: png)], window: 32_768, store: store())
        let image = prepared.attachments[0]
        XCTAssertEqual(image.data, png)
        XCTAssertTrue(image.text?.hasPrefix("[Image: a.png — this model can't take images; the text in it, read by OCR:]\n") ?? false, image.text ?? "")
        XCTAssertNil(prepared.badges[0].stored)
        XCTAssertTrue(store().entries().isEmpty)
    }

    func testReplayNotesTellTheModelWhereTheTextIs() {
        XCTAssertEqual(AttachmentBadge(name: "report.pdf", label: "PDF · 42 pages", stored: "report.pdf").replayNote,
                       #"[Attached: report.pdf — PDF · 42 pages. Its text is saved with this chat: read it with read_attachment {"name": "report.pdf"} if you need it again.]"#)
        XCTAssertEqual(AttachmentBadge(name: "a.png", label: "Image", image: true).replayNote,
                       "[Attached: a.png — Image. Its content was sent with this message and isn't kept.]")
    }

    // MARK: read_attachment

    private func tool(_ store: AttachmentStore) -> ReadAttachmentTool { ReadAttachmentTool(store: store) }

    func testReadAttachmentReadsPartsAndSearches() throws {
        let store = store()
        let text = AttachmentFixtures.lines(5_000, width: 40)
        _ = AttachmentPrep.prepare([PastedText.attachment(text)], window: 32_768, store: store)
        let parts = AttachmentPrep.split(text, size: AttachmentBudget(window: 32_768).partChars)
        let reader = tool(store)

        XCTAssertEqual(reader.run(#"{}"#), "Attachments saved with this chat:\n- pasted-text.txt — Pasted text · 5,000 lines · 200 KB · \(parts.count) parts")
        let second = reader.run(#"{"name":"pasted-text.txt","part":2}"#)
        XCTAssertEqual(second, "[pasted-text.txt — part 2 of \(parts.count) · lines \(parts[1].firstLine)–\(parts[1].lastLine) · \"\(AttachmentPrep.openingWords(parts[1].text)!)\"]\n\(parts[1].text)\n[End of part 2 of \(parts.count) — next: part 3]")
        XCTAssertLessThan(second.count, 40_000)
        XCTAssertTrue(reader.run(JSONString(#"{"name":"pasted-text.txt","chunk":\#(parts.count)}"#)).hasSuffix("that was the last part]"))
        XCTAssertEqual(reader.run(#"{"name":"pasted-text.txt","part":999}"#), "Error: pasted-text.txt has \(parts.count) parts (1–\(parts.count)).")
        let search = reader.run(#"{"name":"pasted-text","search":"LINE 4321:"}"#)
        let holder = parts.firstIndex { $0.firstLine <= 4321 && $0.lastLine >= 4321 }! + 1
        XCTAssertEqual(search, "“LINE 4321:” in pasted-text.txt: 1 match\n- part \(holder), line 4,321: line 4321: \(String(repeating: "x", count: 29))")
        XCTAssertEqual(reader.run(#"{"name":"pasted-text.txt","search":"nowhere"}"#), "“nowhere” isn't in pasted-text.txt.")
        XCTAssertEqual(reader.run(#"{"name":"missing.pdf"}"#), "Error: no attachment named “missing.pdf” is saved with this chat. Saved: pasted-text.txt.")
        let many = reader.run(#"{"name":"pasted-text.txt","search":"line 1"}"#)
        XCTAssertTrue(many.hasPrefix("“line 1” in pasted-text.txt: 1,111 matches"), many)
        XCTAssertTrue(many.hasSuffix("… 1,071 more; search for something narrower."), many)
        XCTAssertEqual(tool(AttachmentStore.forChat("empty", root: dir)).run("{}"), "No long attachments are saved with this chat.")
    }

    func testAStoreIsOneFolderPerChatAndGoesWithIt() throws {
        let a = AttachmentStore.forChat("A1B2-c3/../x", root: dir)
        XCTAssertEqual(a.directory.lastPathComponent, "A1B2-c3____x")
        try a.save(name: "x.txt", digest: AttachmentReader.read(name: "x.txt", data: Data("x".utf8), kind: .file), partChars: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.directory.appendingPathComponent("index.json").path))
        a.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
    }
}
