import XCTest
@testable import VisionHarnessCore

/// Reading attachments the way the composer does: real PDFs, scans, Office files, pictures, text in odd encodings.
final class AttachmentReaderTests: XCTestCase {

    // MARK: Counting and labels (pinned for Vision for Windows)

    func testCountsAndSizesPrintTheSameEverywhere() {
        XCTAssertEqual(AttachmentText.grouped(0), "0")
        XCTAssertEqual(AttachmentText.grouped(999), "999")
        XCTAssertEqual(AttachmentText.grouped(10_214), "10,214")
        XCTAssertEqual(AttachmentText.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(AttachmentText.bytes(1), "1 byte")
        XCTAssertEqual(AttachmentText.bytes(900), "900 bytes")
        XCTAssertEqual(AttachmentText.bytes(1023), "1,023 bytes")
        XCTAssertEqual(AttachmentText.bytes(1024), "1 KB")
        XCTAssertEqual(AttachmentText.bytes(421_888), "412 KB")
        XCTAssertEqual(AttachmentText.bytes(1536), "2 KB", "rounds half up")
        XCTAssertEqual(AttachmentText.bytes(2_202_010), "2.1 MB")
        XCTAssertEqual(AttachmentText.count(1, "line", "lines"), "1 line")
        XCTAssertEqual(AttachmentText.count(10_214, "line", "lines"), "10,214 lines")
    }

    func testLineCounting() {
        XCTAssertEqual(AttachmentText.lineCount(""), 0)
        XCTAssertEqual(AttachmentText.lineCount("a"), 1)
        XCTAssertEqual(AttachmentText.lineCount("a\nb"), 2)
        XCTAssertEqual(AttachmentText.lineCount("a\nb\n"), 2)
        XCTAssertEqual(AttachmentText.lineCount("\n"), 1)
        XCTAssertEqual(AttachmentText.lineCount(AttachmentText.normalizeNewlines("a\r\nb\rc")), 3)
    }

    // MARK: Pastes

    func testAPasteBecomesAnAttachmentPastEitherThreshold() {
        XCTAssertFalse(PastedText.isLarge(AttachmentFixtures.lines(400, width: 10)))
        XCTAssertTrue(PastedText.isLarge(AttachmentFixtures.lines(401, width: 10)))
        XCTAssertFalse(PastedText.isLarge(String(repeating: "a", count: 20_000)))
        XCTAssertTrue(PastedText.isLarge(String(repeating: "a", count: 20_001)))
        // Windows line breaks count once.
        XCTAssertFalse(PastedText.isLarge(Array(repeating: "x", count: 400).joined(separator: "\r\n")))
        XCTAssertTrue(PastedText.isLarge(Array(repeating: "x", count: 401).joined(separator: "\r\n")))
    }

    func testAPastedChipSaysLinesAndSize() {
        let text = AttachmentFixtures.lines(10_214, width: 40)   // 41 bytes a line with its break
        let pasted = PastedText.attachment(text)
        XCTAssertEqual(pasted.name, "pasted-text.txt")
        XCTAssertEqual(pasted.kind, .file)
        XCTAssertEqual(pasted.digest?.format, .pasted)
        XCTAssertEqual(pasted.digest?.summary, "Pasted text · 10,214 lines · \(AttachmentText.bytes(text.utf8.count))")
        XCTAssertEqual(pasted.digest?.summary, "Pasted text · 10,214 lines · 409 KB")
        XCTAssertEqual(PastedText.name(existing: ["pasted-text.txt"]), "pasted-text-2.txt")
        XCTAssertEqual(PastedText.name(existing: ["pasted-text.txt", "pasted-text-2.txt"]), "pasted-text-3.txt")
    }

    /// A big paste that starts with /goal keeps the command (and a short first line) in the box; the rest is the chip.
    func testABigGoalPasteKeepsItsCommandInTheBox() throws {
        let body = AttachmentFixtures.lines(10_000, width: 40)
        let stated = try XCTUnwrap(PastedText.splitGoal("/goal Fix the build\r\n" + body))
        XCTAssertEqual(stated.command, "/goal Fix the build")
        XCTAssertEqual(stated.rest, AttachmentText.normalizeNewlines(body))
        let bare = try XCTUnwrap(PastedText.splitGoal("  /GOAL\n\n" + body))
        XCTAssertEqual(bare.command, "/goal")
        XCTAssertEqual(bare.rest, body)
        // A first line too long for the box goes into the attachment with the rest.
        let longLine = String(repeating: "x", count: PastedText.goalLineCharacters + 1)
        let long = try XCTUnwrap(PastedText.splitGoal("/goal " + longLine + "\n" + body))
        XCTAssertEqual(long.command, "/goal")
        XCTAssertEqual(long.rest, longLine + "\n" + body)
        XCTAssertNil(PastedText.splitGoal(body))
        XCTAssertNil(PastedText.splitGoal("/goals are good\n" + body))
        XCTAssertNil(PastedText.splitGoal("/Users/pat/log.txt\n" + body))
    }

    func testLongUserMessagesCollapseInTheTranscript() {
        XCTAssertNil(PastedText.collapsed("short"))
        XCTAssertNil(PastedText.collapsed(AttachmentFixtures.lines(24, width: 10)))
        XCTAssertEqual(PastedText.collapsed(AttachmentFixtures.lines(25, width: 10))?.lines, 25)
        let long = AttachmentFixtures.lines(10_000, width: 30)
        let collapsed = PastedText.collapsed(long)
        XCTAssertEqual(collapsed?.lines, 10_000)
        XCTAssertEqual(collapsed.map { AttachmentText.lineCount($0.preview) }, 16)
        XCTAssertNil(PastedText.collapsed(String(repeating: "y", count: 3_000)))
        let wide = String(repeating: "y", count: 9_000)
        XCTAssertEqual(PastedText.collapsed(wide)?.preview.count, 2_000)
    }

    // MARK: Text files

    func testTextFilesAreReadAsTheirFormat() {
        let cases: [(String, AttachmentDigest.Format)] = [
            ("notes.md", .markdown), ("data.csv", .csv), ("data.tsv", .tsv), ("a.json", .json), ("c.yaml", .yaml),
            ("feed.xml", .xml), ("page.html", .html), ("server.log", .log), ("main.swift", .code), ("app.py", .code),
            ("README", .text), ("Makefile", .text), ("notes.txt", .text), ("unknown.zzz", .text),
        ]
        for (name, format) in cases {
            let digest = AttachmentReader.read(name: name, data: Data("hello\nworld\n".utf8), kind: .file)
            XCTAssertEqual(digest.format, format, name)
            XCTAssertEqual(digest.text, "hello\nworld\n", name)
            XCTAssertEqual(digest.lines, 2, name)
            XCTAssertNil(digest.problem, name)
        }
    }

    func testEncodings() {
        let utf16 = Data([0xFF, 0xFE]) + "Grüße\r\nzwei".data(using: .utf16LittleEndian)!
        XCTAssertEqual(AttachmentReader.read(name: "a.txt", data: utf16, kind: .file).text, "Grüße\nzwei")
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("# Title".utf8)
        XCTAssertEqual(AttachmentReader.read(name: "a.md", data: bom, kind: .file).text, "# Title")
        // Windows-1252 "café" in a file named as text.
        let cp1252 = Data([0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(AttachmentReader.read(name: "old.txt", data: cp1252, kind: .file).text, "café")
        // The same bytes under an unknown name aren't guessed at.
        XCTAssertEqual(AttachmentReader.read(name: "blob.bin", data: cp1252, kind: .file).format, .binary)
        let binary = AttachmentReader.read(name: "blob.bin", data: Data([0x00, 0x01, 0x02]), kind: .file)
        XCTAssertEqual(binary.format, .binary)
        XCTAssertNotNil(binary.problem)
        XCTAssertEqual(binary.summary, "File · 3 bytes")
    }

    // MARK: PDFs

    func testAPDFIsReadPageByPage() {
        let pdf = AttachmentFixtures.textPDF([
            "Executive summary. Revenue grew in the West region.",
            "Appendix A lists every invoice.",
            "Final page: contact the finance team.",
        ])
        let digest = AttachmentReader.read(name: "report.pdf", data: pdf, kind: .file)
        XCTAssertEqual(digest.format, .pdf)
        XCTAssertEqual(digest.pages, 3)
        XCTAssertFalse(digest.scanned)
        XCTAssertFalse(digest.ocr)
        XCTAssertTrue(digest.pageImages.isEmpty)
        XCTAssertTrue(digest.text.hasPrefix("--- Page 1 of 3 ---\nExecutive summary."), digest.text)
        XCTAssertTrue(digest.text.contains("--- Page 2 of 3 ---\nAppendix A lists every invoice."), digest.text)
        XCTAssertTrue(digest.text.contains("--- Page 3 of 3 ---\nFinal page"), digest.text)
        XCTAssertEqual(digest.summary, "PDF · 3 pages")
    }

    func testAScannedPDFIsReadWithOCRAndRenderedForVisionModels() {
        let pdf = AttachmentFixtures.scannedPDF(["INVOICE 4471\nTotal due 980 dollars", "Second page SIGNED"])
        let digest = AttachmentReader.read(name: "scan.pdf", data: pdf, kind: .file)
        XCTAssertEqual(digest.pages, 2)
        XCTAssertTrue(digest.scanned)
        XCTAssertTrue(digest.ocr)
        XCTAssertEqual(digest.pageImages.count, 2)
        XCTAssertNotNil(ImageData.cgImage(digest.pageImages[0]), "pages are real PNGs")
        let upper = digest.text.uppercased()
        XCTAssertTrue(upper.contains("INVOICE 4471"), digest.text)
        XCTAssertTrue(upper.contains("SIGNED"), digest.text)
        XCTAssertTrue(digest.text.contains("--- Page 2 of 2 ---"))
        XCTAssertEqual(digest.summary, "PDF · 2 pages · scanned")
        // Rendered at 1600 px on the long side.
        XCTAssertEqual(ImageData.pixelSize(digest.pageImages[0])?.height, 1600)
    }

    func testADamagedPDFSaysSo() {
        let digest = AttachmentReader.read(name: "broken.pdf", data: Data("%PDF-1.7 garbage".utf8), kind: .file)
        XCTAssertEqual(digest.format, .pdf)
        XCTAssertNotNil(digest.problem)
        XCTAssertFalse(digest.readable)
    }

    // MARK: Office

    func testWordDocumentsBecomeMarkdownishText() throws {
        let digest = AttachmentReader.read(name: "plan.docx", data: try AttachmentFixtures.docx(), kind: .file)
        XCTAssertEqual(digest.format, .word)
        XCTAssertNil(digest.problem)
        XCTAssertEqual(digest.text, "# Quarterly Plan\n## Goals\nShip the harness\ttonight\n- Read PDFs\n\nOwner | Due\nPatrick | Monday\nÜnïcode & done")
        XCTAssertEqual(digest.summary, "Word · 8 lines")
    }

    func testPowerPointSlidesFollowThePresentationOrder() throws {
        let digest = AttachmentReader.read(name: "deck.pptx", data: try AttachmentFixtures.pptx(), kind: .file)
        XCTAssertEqual(digest.format, .powerpoint)
        XCTAssertEqual(digest.pages, 2)
        XCTAssertEqual(digest.text, "--- Slide 1 of 2 ---\nRoadmap\nQ4: Vision\n\n--- Slide 2 of 2 ---\nThanks\nQuestions?")
        XCTAssertEqual(digest.summary, "PowerPoint · 2 slides")
    }

    func testExcelSheetsBecomeTabSeparatedRows() throws {
        let digest = AttachmentReader.read(name: "totals.xlsx", data: try AttachmentFixtures.xlsx(), kind: .file)
        XCTAssertEqual(digest.format, .excel)
        XCTAssertEqual(digest.pages, 2)
        XCTAssertEqual(digest.text, "--- Sheet 1 of 2: Totals ---\nRegion\t\tRevenue\nWest Coast\tTRUE\t1250.5\n\n--- Sheet 2 of 2: Notes ---\nChecked")
        XCTAssertEqual(digest.summary, "Excel · 2 sheets")
    }

    func testStoredZipEntriesAndDamagedOfficeFiles() throws {
        let stored = try AttachmentFixtures.zip(["word/document.xml": "<w:document \(AttachmentFixtures.wordNS)><w:body><w:p><w:r><w:t>stored</w:t></w:r></w:p></w:body></w:document>"], stored: true)
        XCTAssertEqual(AttachmentReader.read(name: "s.docx", data: stored, kind: .file).text, "stored")
        let zip = try ZipArchive(stored)
        XCTAssertEqual(zip.entries.map(\.name), ["word/document.xml"])
        // Not a zip at all, under an Office name: read as text (it is text) — and a cut-off zip says it is damaged.
        var cut = try AttachmentFixtures.docx()
        cut = cut.prefix(cut.count / 2)
        let damaged = AttachmentReader.read(name: "cut.docx", data: cut, kind: .file)
        XCTAssertEqual(damaged.format, .word)
        XCTAssertNotNil(damaged.problem)
        XCTAssertThrowsError(try ZipArchive(Data("not a zip".utf8)))
    }

    func testRichTextGoesThroughTextutil() {
        let rtf = #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0\pard Hello {\b bold} world.\par Second line.}"#
        let digest = AttachmentReader.read(name: "memo.rtf", data: Data(rtf.utf8), kind: .file)
        XCTAssertEqual(digest.format, .rtf)
        XCTAssertEqual(digest.text, "Hello bold world.\nSecond line.")
        XCTAssertEqual(digest.summary, "Rich text · 2 lines")
    }

    // MARK: Pictures

    func testPicturesAreReadWithOCR() {
        let png = AttachmentFixtures.png(of: "QUARTERLY TOTAL 42")
        let digest = AttachmentReader.read(name: "shot.png", data: png, kind: .image)
        XCTAssertEqual(digest.format, .image)
        XCTAssertTrue(digest.ocr)
        XCTAssertTrue(digest.text.uppercased().contains("QUARTERLY TOTAL 42"), digest.text)
        XCTAssertEqual(digest.summary, "Image")
        // A picture attached as a file is treated as a picture.
        let digested = AttachmentReader.digested(MessageAttachment(kind: .file, name: "shot.png", data: png))
        XCTAssertEqual(digested.kind, .image)
        XCTAssertTrue(digested.text?.contains("read by OCR") ?? false)
    }

    func testPicturesAreNormalisedToPNGsServersTake() throws {
        let big = AttachmentFixtures.picture(of: "BIG", width: 5000, height: 3000, size: 300)
        let png = ImageData.png(big)!
        let normalized = try XCTUnwrap(ImageData.normalized(png))
        XCTAssertEqual(ImageData.pixelSize(normalized)?.width, 2048)
        XCTAssertLessThanOrEqual(normalized.count, 3_750_000)
        XCTAssertEqual(MessageAttachment(kind: .image, name: "photo.jpg", data: normalized).mime, "image/png",
                       "the bytes decide the type, not a stale extension")
        XCTAssertNil(ImageData.normalized(Data("not a picture".utf8)))
    }
}
