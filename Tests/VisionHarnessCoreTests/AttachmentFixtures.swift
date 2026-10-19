import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import VisionHarnessCore

/// Real files made on the spot: PDFs with a text layer (drawn with Core Text), scanned PDFs (text drawn into a
/// picture, the picture into the page), Office files zipped by /usr/bin/zip, PNGs with words in them.
enum AttachmentFixtures {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// A PDF whose pages carry `pages` as real text.
    static func textPDF(_ pages: [String]) -> Data {
        let data = NSMutableData()
        var box = page
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            draw(text, in: context, rect: box.insetBy(dx: 54, dy: 54), size: 13)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PDF with no text layer: each page is a picture of `pages[i]`.
    static func scannedPDF(_ pages: [String]) -> Data {
        let data = NSMutableData()
        var box = page
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            context.draw(picture(of: text, width: 1224, height: 1584, size: 56), in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PNG of `text` in large black letters on white.
    static func png(of text: String) -> Data {
        ImageData.png(picture(of: text, width: 1200, height: 400, size: 64))!
    }

    static func picture(of text: String, width: Int, height: Int, size: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, in: context, rect: CGRect(x: 60, y: 60, width: width - 120, height: height - 120), size: size)
        return context.makeImage()!
    }

    static func draw(_ text: String, in context: CGContext, rect: CGRect, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): black,
        ])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    /// A zip of `files` (path → content) made by /usr/bin/zip — deflated, as Office writes them, or stored.
    static func zip(_ files: [String: String], stored: Bool = false) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-zip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let out = dir.appendingPathComponent("out.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-r", "-X"] + (stored ? ["-0"] : ["-9"]) + ["out.zip"] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip failed")
        return try Data(contentsOf: out)
    }

    static let wordNS = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    /// A .docx: a title, a heading, a paragraph with a tab stop and a tab, a list item, a table, a deleted run.
    static func docx() throws -> Data {
        let body = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(wordNS)><w:body>
        <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Quarterly Plan</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Goals</w:t></w:r></w:p>
        <w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr><w:r><w:t xml:space="preserve">Ship the </w:t></w:r><w:r><w:t>harness</w:t><w:tab/><w:t>tonight</w:t></w:r><w:del><w:r><w:delText>never</w:delText></w:r></w:del></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Read PDFs</w:t></w:r></w:p>
        <w:p/>
        <w:p/>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Owner</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Due</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:p><w:r><w:t>Patrick</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Monday</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:t>Ünïcode &amp; done</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return try zip(["[Content_Types].xml": #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
                        "word/document.xml": body])
    }

    /// A .pptx whose presentation order (slide2, then slide1) differs from its file names.
    static func pptx() throws -> Data {
        let a = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        func slide(_ lines: [String]) -> String {
            "<p:sld \(a)><p:cSld><p:spTree><p:sp><p:txBody>" + lines.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
                + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        return try zip([
            "ppt/presentation.xml": "<p:presentation \(a)><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId3\"/><p:sldId id=\"257\" r:id=\"rId2\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="slide" Target="slides/slide1.xml"/><Relationship Id="rId3" Type="slide" Target="slides/slide2.xml"/></Relationships>"#,
            "ppt/slides/slide1.xml": slide(["Thanks", "Questions?"]),
            "ppt/slides/slide2.xml": slide(["Roadmap", "Q4: Vision"]),
        ])
    }

    /// A .xlsx with two sheets: shared strings, an inline string, a boolean, a number, and a gap at column B.
    static func xlsx() throws -> Data {
        let main = #"xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        return try zip([
            "xl/workbook.xml": "<workbook \(main)><sheets><sheet name=\"Totals\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Notes\" sheetId=\"2\" r:id=\"rId2\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="worksheet" Target="/xl/worksheets/sheet2.xml"/></Relationships>"#,
            "xl/sharedStrings.xml": "<sst \(main)><si><t>Region</t></si><si><t>Revenue</t></si><si><r><t>West</t></r><r><t> Coast</t></r></si></sst>",
            "xl/worksheets/sheet1.xml": """
            <worksheet \(main)><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="b"><v>1</v></c><c r="C2"><v>1250.5</v></c></row>
            </sheetData></worksheet>
            """,
            "xl/worksheets/sheet2.xml": "<worksheet \(main)><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Checked</t></is></c></row></sheetData></worksheet>",
        ])
    }

    /// `count` numbered lines of about `width` characters.
    static func lines(_ count: Int, width: Int = 40) -> String {
        (1...count).map { n in
            let head = "line \(n): "
            return head + String(repeating: "x", count: max(0, width - head.count))
        }.joined(separator: "\n")
    }
}
