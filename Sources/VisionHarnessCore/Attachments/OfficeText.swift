import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Text out of Office Open XML files (.docx, .pptx, .xlsx)
//
// Each is a zip of XML parts; the text is in a handful of them. Word: `word/document.xml` (paragraphs, headings as
// "#", list items as "- ", table rows as "a | b | c"). PowerPoint: one "--- Slide N of M ---" section per slide in
// presentation order. Excel: one "--- Sheet N of M: Name ---" section per sheet, each row's cells separated by tabs.

public enum OfficeText {
    public struct Result: Sendable, Equatable {
        public var text: String
        /// Slides (PowerPoint) or sheets (Excel); nil for Word.
        public var pages: Int?
    }

    public enum Kind: Sendable { case word, powerpoint, excel }

    public static func extract(_ data: Data, kind: Kind) throws -> Result {
        let zip = try ZipArchive(data)
        switch kind {
        case .word: return Result(text: try word(zip), pages: nil)
        case .powerpoint: return try powerpoint(zip)
        case .excel: return try excel(zip)
        }
    }

    // MARK: Word

    static func word(_ zip: ZipArchive) throws -> String {
        guard let xml = try zip.read("word/document.xml") else {
            throw ZipArchive.ZipError.damaged("no word/document.xml")
        }
        var lines: [String] = []
        var paragraph = ""
        var inText = false
        var inRun = false
        var heading = 0
        var listItem = false
        // Tables: cells of the row being read, the cell's own text.
        var tableDepth = 0
        var row: [String] = []
        var cell = ""

        func finishParagraph() {
            var line = paragraph.trimmingCharacters(in: .whitespaces)
            paragraph = ""
            defer { heading = 0; listItem = false }
            if tableDepth > 0 {
                if !line.isEmpty { cell += cell.isEmpty ? line : " " + line }
                return
            }
            if !line.isEmpty {
                if heading > 0 { line = String(repeating: "#", count: heading) + " " + line }
                else if listItem { line = "- " + line }
            }
            lines.append(line)
        }

        XMLWalker.walk(xml, start: { name, attributes in
            switch name {
            case "r": inRun = true
            case "t": inText = inRun
            // Tab stops (`w:tabs/w:tab` in the paragraph's properties) are not text; a tab in a run is.
            case "tab": if inRun { paragraph += "\t" }
            case "br", "cr": if inRun { paragraph += tableDepth > 0 ? " " : "\n" }
            case "pStyle":
                let style = (attributes["val"] ?? "").lowercased()
                if style == "title" { heading = 1 }
                else if style.hasPrefix("heading"), let n = Int(style.dropFirst("heading".count)), (1...6).contains(n) { heading = n }
            case "numPr": listItem = true
            case "tbl": tableDepth += 1
            case "tr": if tableDepth == 1 { row = [] }
            case "tc": if tableDepth == 1 { cell = "" }
            default: break
            }
        }, end: { name in
            switch name {
            case "r": inRun = false
            case "t": inText = false
            case "p": finishParagraph()
            case "tc": if tableDepth == 1 { row.append(cell.trimmingCharacters(in: .whitespaces)) }
            case "tr": if tableDepth == 1, row.contains(where: { !$0.isEmpty }) { lines.append(row.joined(separator: " | ")) }
            case "tbl": tableDepth = max(0, tableDepth - 1)
            default: break
            }
        }, text: { string in
            if inText { paragraph += string }
        })
        return tidy(lines)
    }

    // MARK: PowerPoint

    static func powerpoint(_ zip: ZipArchive) throws -> Result {
        let slides = slideOrder(zip)
        guard !slides.isEmpty else { throw ZipArchive.ZipError.damaged("no slides") }
        var sections: [String] = []
        for (index, path) in slides.enumerated() {
            guard let xml = try zip.read(path) else { continue }
            var lines: [String] = []
            var paragraph = ""
            var inText = false
            XMLWalker.walk(xml, start: { name, _ in
                switch name {
                case "t": inText = true
                case "br": paragraph += "\n"
                case "tab": paragraph += "\t"
                default: break
                }
            }, end: { name in
                switch name {
                case "t": inText = false
                case "p":
                    let line = paragraph.trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { lines.append(line) }
                    paragraph = ""
                default: break
                }
            }, text: { string in
                if inText { paragraph += string }
            })
            sections.append("--- Slide \(index + 1) of \(slides.count) ---\n" + lines.joined(separator: "\n"))
        }
        return Result(text: sections.joined(separator: "\n\n"), pages: slides.count)
    }

    /// Slide parts in presentation order (`p:sldIdLst` through the relationships), else by number.
    static func slideOrder(_ zip: ZipArchive) -> [String] {
        let numbered = zip.entries.map(\.name)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        guard let xml = try? zip.read("ppt/presentation.xml"),
              let rels = try? zip.read("ppt/_rels/presentation.xml.rels") else { return numbered }
        let targets = relationships(rels, base: "ppt/")
        var ordered: [String] = []
        XMLWalker.walk(xml, start: { name, attributes in
            if name == "sldId", let id = attributes["id:r"] ?? attributes["r:id"], let target = targets[id] {
                ordered.append(target)
            }
        })
        let present = Set(numbered)
        let inOrder = ordered.filter { present.contains($0) }
        return inOrder.isEmpty ? numbered : inOrder
    }

    // MARK: Excel

    static func excel(_ zip: ZipArchive) throws -> Result {
        let shared = sharedStrings(zip)
        var sheets: [(name: String, path: String)] = []
        if let workbook = try zip.read("xl/workbook.xml") {
            let targets = (try? zip.read("xl/_rels/workbook.xml.rels")).map { relationships($0, base: "xl/") } ?? [:]
            XMLWalker.walk(workbook, start: { name, attributes in
                guard name == "sheet" else { return }
                let rid = attributes["id:r"] ?? attributes["r:id"] ?? ""
                if let path = targets[rid] { sheets.append((attributes["name"] ?? "Sheet\(sheets.count + 1)", path)) }
            })
        }
        if sheets.isEmpty {
            sheets = zip.entries.map(\.name)
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { number(in: $0) < number(in: $1) }
                .enumerated().map { ("Sheet\($0.offset + 1)", $0.element) }
        }
        guard !sheets.isEmpty else { throw ZipArchive.ZipError.damaged("no sheets") }
        var sections: [String] = []
        for (index, sheet) in sheets.enumerated() {
            guard let xml = try zip.read(sheet.path) else { continue }
            var rows: [String] = []
            var cells: [Int: String] = [:]
            var column = 0
            var type = ""
            var value = ""
            var inValue = false
            var inInline = false
            XMLWalker.walk(xml, start: { name, attributes in
                switch name {
                case "row": cells = [:]; column = 0
                case "c":
                    type = attributes["t"] ?? ""
                    value = ""
                    if let ref = attributes["r"], let col = columnIndex(ref) { column = col } else { column += 1 }
                case "v": inValue = true
                case "is": inInline = true
                case "t": if inInline { inValue = true }
                default: break
                }
            }, end: { name in
                switch name {
                case "v": inValue = false
                case "t": if inInline { inValue = false }
                case "is": inInline = false
                case "c":
                    var shown = value
                    switch type {
                    case "s": shown = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                    case "b": shown = value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
                    default: break
                    }
                    shown = shown.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                    if !shown.isEmpty { cells[column] = shown }
                case "row":
                    guard let last = cells.keys.max() else { return }
                    let first = 1
                    rows.append((first...max(first, last)).map { cells[$0] ?? "" }.joined(separator: "\t"))
                default: break
                }
            }, text: { string in
                if inValue { value += string }
            })
            sections.append("--- Sheet \(index + 1) of \(sheets.count): \(sheet.name) ---\n" + rows.joined(separator: "\n"))
        }
        return Result(text: sections.joined(separator: "\n\n"), pages: sheets.count)
    }

    static func sharedStrings(_ zip: ZipArchive) -> [String] {
        guard let xml = try? zip.read("xl/sharedStrings.xml") else { return [] }
        var strings: [String] = []
        var current = ""
        var inText = false
        var phonetic = false
        XMLWalker.walk(xml, start: { name, _ in
            switch name {
            case "si": current = ""
            case "rPh": phonetic = true
            case "t": inText = !phonetic
            default: break
            }
        }, end: { name in
            switch name {
            case "si": strings.append(current)
            case "rPh": phonetic = false
            case "t": inText = false
            default: break
            }
        }, text: { string in
            if inText { current += string }
        })
        return strings
    }

    /// "C12" → 3 (A = 1).
    static func columnIndex(_ reference: String) -> Int? {
        var index = 0
        var any = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            index = index * 26 + Int((scalar.value & 0xDF) - 64)
            any = true
        }
        return any ? index : nil
    }

    // MARK: Shared

    /// Relationship id → part path, resolved against `base` ("ppt/", "xl/").
    static func relationships(_ xml: Data, base: String) -> [String: String] {
        var map: [String: String] = [:]
        XMLWalker.walk(xml, start: { name, attributes in
            guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
            if target.hasPrefix("/") {
                map[id] = String(target.dropFirst())
            } else {
                var parts = base.split(separator: "/").map(String.init)
                for piece in target.split(separator: "/") {
                    if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(String(piece)) }
                }
                map[id] = parts.joined(separator: "/")
            }
        })
        return map
    }

    private static func number(in path: String) -> Int {
        Int(path.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
    }

    /// Lines joined, runs of blank lines collapsed to one, no blank lines at either end.
    static func tidy(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

// MARK: - A small streaming XML walker

/// Calls back for every element start (local name, attributes keyed by local name — a prefixed attribute such as
/// `r:id` also appears as "id:r" so it can't be confused with a plain `id`), element end and run of text.
final class XMLWalker: NSObject, XMLParserDelegate {
    typealias Start = (String, [String: String]) -> Void
    typealias End = (String) -> Void
    typealias Text = (String) -> Void

    private let start: Start
    private let end: End
    private let text: Text

    private init(start: @escaping Start, end: @escaping End, text: @escaping Text) {
        self.start = start
        self.end = end
        self.text = text
    }

    static func walk(_ data: Data, start: @escaping Start = { _, _ in }, end: @escaping End = { _ in },
                     text: @escaping Text = { _ in }) {
        let walker = XMLWalker(start: start, end: end, text: text)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = walker
        parser.parse()
    }

    private static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict {
            if let colon = key.firstIndex(of: ":") {
                let prefix = key[..<colon], name = key[key.index(after: colon)...]
                attributes["\(name):\(prefix)"] = value
                if attributes[String(name)] == nil { attributes[String(name)] = value }
            } else {
                attributes[key] = value
            }
        }
        start(Self.local(elementName), attributes)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        end(Self.local(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text(string)
    }
}
