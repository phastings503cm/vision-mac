import Foundation

// MARK: - What Vision read out of an attached file
//
// A model server only takes the content types it was built for: an OpenAI-compatible server (vLLM, SGLang,
// llama.cpp, Ollama, a Spark Swapper) takes text and — on a vision model — `image_url`; none of them takes the
// `file` part Vision used to send for a PDF or a Markdown file ("Unsupported chat content part type: 'file'",
// "unsupported content[].type"). So the harness reads every attachment itself when it is attached: text files as
// they are, PDFs page by page, Office files from their XML, pictures and scans with OCR. What goes on the wire is
// then text, or an image on a route that takes images, or a native document block where the provider has one
// (Bedrock). See `AttachmentWire` for the per-route choice and `AttachmentPrep` for long files.

/// What Vision read out of an attached file, worked out once when the file is attached.
public struct AttachmentDigest: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Sendable, CaseIterable {
        case text, markdown, csv, tsv, json, yaml, xml, html, log, code
        case pdf, word, powerpoint, excel, rtf
        case image, pasted, binary

        /// The word the composer chip and the model's header use (the same on every platform).
        public var label: String {
            switch self {
            case .text: "Text"
            case .markdown: "Markdown"
            case .csv: "CSV"
            case .tsv: "TSV"
            case .json: "JSON"
            case .yaml: "YAML"
            case .xml: "XML"
            case .html: "HTML"
            case .log: "Log"
            case .code: "Code"
            case .pdf: "PDF"
            case .word: "Word"
            case .powerpoint: "PowerPoint"
            case .excel: "Excel"
            case .rtf: "Rich text"
            case .image: "Image"
            case .pasted: "Pasted text"
            case .binary: "File"
            }
        }

        /// What `pages` counts for this format.
        var unit: (one: String, many: String)? {
            switch self {
            case .pdf: ("page", "pages")
            case .powerpoint: ("slide", "slides")
            case .excel: ("sheet", "sheets")
            default: nil
            }
        }
    }

    public var format: Format
    /// Pages (PDF), slides (PowerPoint) or sheets (Excel); nil for the rest.
    public var pages: Int?
    /// Lines in `text` (see `AttachmentText.lineCount`).
    public var lines: Int
    /// The file's own size in bytes.
    public var bytes: Int
    /// Everything readable in the file, as text, with page / slide / sheet markers. Empty for a picture with no
    /// text in it or a file Vision can't read. Cleared once the message is prepared (the full text then lives in the
    /// chat's attachment store and the message carries `MessageAttachment.text`).
    public var text: String
    /// `text`'s length in UTF-16 units, kept when `text` itself is cleared after the message is prepared.
    public var textLength: Int
    /// Some or all of `text` was read off pictures (OCR).
    public var ocr: Bool
    /// A PDF with no text layer (a scan).
    public var scanned: Bool
    /// A scanned PDF's first pages as PNGs, for models that take images (at most `PDFText.maxPageImages`).
    public var pageImages: [Data]
    /// Why the file couldn't be read, when it couldn't (damaged, password-protected, an unknown binary type).
    public var problem: String?

    public init(format: Format, pages: Int? = nil, lines: Int, bytes: Int, text: String,
                ocr: Bool = false, scanned: Bool = false, pageImages: [Data] = [], problem: String? = nil) {
        self.format = format
        self.pages = pages
        self.lines = lines
        self.bytes = bytes
        self.text = text
        self.textLength = AttachmentText.length(text)
        self.ocr = ocr
        self.scanned = scanned
        self.pageImages = pageImages
        self.problem = problem
    }

    /// Whether there is any text to send.
    public var readable: Bool { problem == nil && textLength > 0 }

    /// "PDF · 42 pages", "Markdown · 1,204 lines", "Pasted text · 10,214 lines · 412 KB", "Image", "File · 2.1 MB".
    /// The chip shows it followed by how the file will be sent (`AttachmentDelivery.label`).
    public var summary: String {
        var parts = [format.label]
        switch format {
        case .pasted:
            parts.append(AttachmentText.count(lines, "line", "lines"))
            parts.append(AttachmentText.bytes(bytes))
        case .image:
            break
        case .binary:
            parts.append(AttachmentText.bytes(bytes))
        default:
            if let pages, let unit = format.unit {
                parts.append(AttachmentText.count(pages, unit.one, unit.many))
            } else {
                parts.append(AttachmentText.count(lines, "line", "lines"))
            }
        }
        if scanned { parts.append("scanned") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Counting and formatting (pinned: Vision for Windows prints the same)

public enum AttachmentText {
    /// Lines in a text: one per line break, plus one for a last line without a break. "" → 0, "a" → 1,
    /// "a\nb" → 2, "a\nb\n" → 2. (Text is normalised to "\n" line breaks before it is counted.)
    public static func lineCount(_ text: String) -> Int {
        var breaks = 0
        var last: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A { breaks += 1 }
            last = byte
        }
        if text.utf8.isEmpty { return 0 }
        return last == 0x0A ? breaks : breaks + 1
    }

    /// The length chunking and thresholds use: UTF-16 code units, as a Windows string counts them.
    public static func length(_ text: String) -> Int { text.utf16.count }

    /// "\r\n" and lone "\r" become "\n".
    public static func normalizeNewlines(_ text: String) -> String {
        // Bytes, not `contains("\r")`: "\r\n" is one Character, so a character search never finds its "\r".
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// 10214 → "10,214" — always a comma every three digits, whatever the locale.
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (index, char) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return n < 0 ? "-" + out : out
    }

    /// "1 line", "10,214 lines".
    public static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(grouped(n)) \(n == 1 ? one : many)"
    }

    /// "1 byte", "900 bytes", "412 KB" (bytes / 1024, rounded), "2.1 MB" (bytes / 1,048,576, one decimal).
    public static func bytes(_ n: Int) -> String {
        if n < 1024 { return n == 1 ? "1 byte" : "\(grouped(n)) bytes" }
        if n < 1024 * 1024 { return "\(grouped(Int((Double(n) / 1024).rounded()))) KB" }
        let mb = (Double(n) / 1_048_576 * 10).rounded() / 10
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - What a sent message says it carried

/// One attachment as the transcript shows it under the user's message, and as the chat's log keeps it — the file's
/// name and summary, not its content. `stored` is the name its text is saved under with the chat
/// (`AttachmentStore`), so a reopened chat can tell the model how to read it again.
public struct AttachmentBadge: Codable, Hashable, Sendable {
    public var name: String
    public var label: String
    public var image: Bool
    public var stored: String?

    public init(name: String, label: String, image: Bool = false, stored: String? = nil) {
        self.name = name
        self.label = label
        self.image = image
        self.stored = stored
    }

    /// The badge for an attachment (prepared or not).
    public init(_ attachment: MessageAttachment, stored: String? = nil) {
        self.init(name: attachment.name,
                  label: attachment.digest?.summary ?? (attachment.kind == .image ? "Image" : "File"),
                  image: attachment.kind == .image, stored: stored)
    }

    /// What a rebuilt conversation (after the app restarts) tells the model about the attachment.
    public var replayNote: String {
        if let stored {
            return "[Attached: \(name) — \(label). Its text is saved with this chat: read it with \(AttachmentPrep.toolName) {\"name\": \"\(stored)\"} if you need it again.]"
        }
        return "[Attached: \(name) — \(label). Its content was sent with this message and isn't kept.]"
    }
}
