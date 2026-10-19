import Foundation

// MARK: - Reading an attachment

/// Works out what an attached file is and reads its text: done once, off the main thread, when the file is
/// attached (and again when a message is sent with an attachment nobody read yet).
public enum AttachmentReader {
    /// Extensions read as text, by the format they are labelled with.
    static let textExtensions: [String: AttachmentDigest.Format] = {
        var map: [String: AttachmentDigest.Format] = [:]
        for ext in ["md", "markdown", "mdx", "mdc"] { map[ext] = .markdown }
        map["csv"] = .csv
        for ext in ["tsv", "tab"] { map[ext] = .tsv }
        for ext in ["json", "jsonl", "ndjson", "geojson", "ipynb", "jsonc"] { map[ext] = .json }
        for ext in ["yaml", "yml"] { map[ext] = .yaml }
        for ext in ["xml", "plist", "xsd", "xsl", "xslt", "svg", "rss", "atom", "csproj", "props", "targets", "resx", "xaml"] { map[ext] = .xml }
        for ext in ["html", "htm", "xhtml"] { map[ext] = .html }
        for ext in ["log", "out", "err"] { map[ext] = .log }
        for ext in ["txt", "text", "rst", "adoc", "asciidoc", "org", "tex", "ini", "cfg", "conf", "env", "properties",
                    "toml", "srt", "vtt", "license", "readme", "gitignore", "gitattributes", "editorconfig"] { map[ext] = .text }
        for ext in ["swift", "py", "pyi", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "kts", "c", "h", "cc",
                    "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "cs", "fs", "fsx", "vb", "go", "rs", "rb", "php", "pl",
                    "pm", "lua", "r", "scala", "sh", "bash", "zsh", "fish", "ps1", "psm1", "psd1", "bat", "cmd", "sql",
                    "graphql", "gql", "proto", "css", "scss", "sass", "less", "vue", "svelte", "dart", "ex", "exs",
                    "erl", "hrl", "hs", "clj", "cljs", "groovy", "gradle", "tf", "hcl", "nix", "zig", "nim", "jl",
                    "cmake", "mk", "make", "dockerfile", "diff", "patch", "asm", "s", "v", "sv", "vhd", "sol", "razor",
                    "cshtml", "astro", "elm", "ml", "mli", "pas", "f90", "cob", "ada", "d", "cr", "rkt", "lisp", "el",
                    "scm", "vim", "awk", "sed", "bicep", "ino"] { map[ext] = .code }
        return map
    }()

    /// File names without a useful extension that are text.
    static let textNames: Set<String> = ["makefile", "dockerfile", "gemfile", "rakefile", "procfile", "license",
                                         "readme", "changelog", "authors", "notice", "copying", "podfile", "brewfile",
                                         "vagrantfile", "jenkinsfile", "cmakelists.txt"]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff",
                                              "bmp", "ico", "jp2"]

    /// Extensions macOS's `textutil` turns into text (Rich Text, old binary Word, OpenDocument, …).
    static let textutilExtensions: [String: AttachmentDigest.Format] = [
        "rtf": .rtf, "rtfd": .rtf, "doc": .word, "odt": .word, "wordml": .word, "webarchive": .html,
    ]

    /// Whether a file attached as a "file" is really a picture (attach-file of a PNG): it then goes as an image.
    public static func isImage(name: String, data: Data) -> Bool {
        imageExtensions.contains(ext(name)) && ImageData.cgImage(data) != nil
    }

    /// The attachment with its digest filled in (a picture attached as a file becomes an image attachment).
    public static func digested(_ attachment: MessageAttachment, ocr: Bool = true) -> MessageAttachment {
        guard attachment.digest == nil else { return attachment }
        var out = attachment
        if out.kind == .file, isImage(name: out.name, data: out.data) { out.kind = .image }
        out.digest = read(name: out.name, data: out.data, kind: out.kind, ocr: ocr)
        if out.kind == .image, let text = out.digest?.text {
            out.text = imageText(name: out.name, ocrText: text)
        }
        return out
    }

    /// A pasted block of text as an attachment ("Pasted text · 10,214 lines · 412 KB").
    public static func pasted(_ text: String, name: String = "pasted-text.txt") -> MessageAttachment {
        let normalized = AttachmentText.normalizeNewlines(text)
        let data = Data(normalized.utf8)
        var attachment = MessageAttachment(kind: .file, name: name, data: data)
        attachment.digest = AttachmentDigest(format: .pasted, lines: AttachmentText.lineCount(normalized),
                                             bytes: data.count, text: normalized)
        return attachment
    }

    /// Read a file's text. Never throws: what can't be read says why in `problem`.
    public static func read(name: String, data: Data, kind: MessageAttachment.Kind, ocr: Bool = true) -> AttachmentDigest {
        let bytes = data.count
        let ext = ext(name)
        if kind == .image || imageExtensions.contains(ext) {
            let text = ocr ? AttachmentText.normalizeNewlines(OCR.text(inImageData: data)) : ""
            return AttachmentDigest(format: .image, lines: AttachmentText.lineCount(text), bytes: bytes, text: text,
                                    ocr: !text.isEmpty)
        }
        if ext == "pdf" || data.starts(with: Array("%PDF".utf8)) {
            let pdf = PDFText.extract(data, ocr: ocr)
            return AttachmentDigest(format: .pdf, pages: pdf.pages, lines: AttachmentText.lineCount(pdf.text),
                                    bytes: bytes, text: pdf.text, ocr: pdf.ocr, scanned: pdf.scanned,
                                    pageImages: pdf.pageImages, problem: pdf.problem)
        }
        if let office = officeKind(ext), ZipArchive.looksLikeZip(data) {
            let format: AttachmentDigest.Format = office == .word ? .word : office == .powerpoint ? .powerpoint : .excel
            do {
                let result = try OfficeText.extract(data, kind: office)
                let text = AttachmentText.normalizeNewlines(result.text)
                return AttachmentDigest(format: format, pages: result.pages, lines: AttachmentText.lineCount(text),
                                        bytes: bytes, text: text)
            } catch {
                return AttachmentDigest(format: format, lines: 0, bytes: bytes, text: "",
                                        problem: "Vision couldn't read this \(format.label) file (it may be damaged).")
            }
        }
        if let format = textutilExtensions[ext] {
            if let text = textutil(data, ext: ext) {
                return AttachmentDigest(format: format, lines: AttachmentText.lineCount(text), bytes: bytes, text: text)
            }
            return AttachmentDigest(format: format, lines: 0, bytes: bytes, text: "",
                                    problem: "Vision couldn't read this \(format.label) file.")
        }
        let base = (name as NSString).lastPathComponent.lowercased()
        let format = textExtensions[ext] ?? (textNames.contains(base) ? .text : nil)
        if let text = decodeText(data, lenient: format != nil) {
            let text = AttachmentText.normalizeNewlines(text)
            return AttachmentDigest(format: format ?? .text, lines: AttachmentText.lineCount(text), bytes: bytes, text: text)
        }
        return AttachmentDigest(format: .binary, lines: 0, bytes: bytes, text: "",
                                problem: "Vision can't read this kind of file, so only its name is sent.")
    }

    /// What a model that can't take images is sent for one: the text OCR found in it.
    public static func imageText(name: String, ocrText: String) -> String {
        ocrText.isEmpty
            ? "[Image: \(name) — this model can't take images, and no text was found in it]"
            : "[Image: \(name) — this model can't take images; the text in it, read by OCR:]\n\(ocrText)"
    }

    // MARK: Helpers

    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    static func officeKind(_ ext: String) -> OfficeText.Kind? {
        switch ext {
        case "docx", "docm", "dotx", "dotm": .word
        case "pptx", "pptm", "potx", "ppsx": .powerpoint
        case "xlsx", "xlsm", "xltx", "xltm": .excel
        default: nil
        }
    }

    /// Text in UTF-8 (with or without a byte-order mark) or UTF-16 with one. A file named as text whose bytes aren't
    /// valid UTF-8 but hold no NULs is read as Windows-1252 (old Windows text files); an unknown file is text only
    /// when it decodes cleanly.
    public static func decodeText(_ data: Data, lenient: Bool = true) -> String? {
        let start = [UInt8](data.prefix(3))
        var text: String?
        if start.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if start.starts(with: [0xFF, 0xFE]) {
            guard data.count % 2 == 0 else { return nil }
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if start.starts(with: [0xFE, 0xFF]) {
            guard data.count % 2 == 0 else { return nil }
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            guard !data.contains(0) else { return nil }
            text = String(data: data, encoding: .utf8)
            if text == nil, lenient { text = String(data: data, encoding: .windowsCP1252) }
        }
        guard var text else { return nil }
        while text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        if text.unicodeScalars.contains("\u{0}") { return nil }
        return text
    }

    /// Rich Text, old Word and OpenDocument through macOS's `textutil`.
    static func textutil(_ data: Data, ext: String) -> String? {
        let tool = "/usr/bin/textutil"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-textutil-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("attachment.\(ext)")
            try data.write(to: file)
            let result = try SkillProcess.run(tool, ["-convert", "txt", "-stdout", "-encoding", "UTF-8", file.path], timeout: 60)
            guard result.status == 0 else { return nil }
            return AttachmentText.normalizeNewlines(result.out).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
