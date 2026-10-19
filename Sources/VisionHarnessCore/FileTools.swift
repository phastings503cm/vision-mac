import Foundation

// MARK: - Text files (line endings, BOM, one writer at a time)

/// How a text file was stored, so an edit can write it back the same way. A one-line
/// edit must not turn a CRLF file into LF, or drop a BOM.
struct TextFileFormat: Equatable, Sendable {
    var hasBOM: Bool
    var usesCRLF: Bool
    static let `default` = TextFileFormat(hasBOM: false, usesCRLF: false)
}

/// UTF-8 text on disk. Writers of one path take turns, so two subagents editing the
/// same file cannot both start from the same text and lose one of the edits.
enum FileText {
    /// A fixed set of locks, hashed by path, so the number of locks does not grow with
    /// the files a long session touches. Two files that share one merely take turns.
    /// Re-entrant: `write` takes the lock, and `edit` already holds it.
    private final class Stripes: @unchecked Sendable {
        let locks: [NSRecursiveLock] = (0..<64).map { _ in NSRecursiveLock() }
    }
    private static let stripes = Stripes()

    static func lock(for path: String) -> NSRecursiveLock {
        stripes.locks[stripeIndex(path)]
    }

    static func withLock<T>(_ path: String, _ body: () throws -> T) rethrows -> T {
        let stripe = lock(for: path)
        stripe.lock()
        defer { stripe.unlock() }
        return try body()
    }

    /// Read a file as UTF-8. Nil when it can't be read or isn't valid UTF-8 (binary).
    /// The text has any BOM removed and keeps its original line endings.
    static func read(_ url: URL) -> (text: String, format: TextFileFormat)? {
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return decode(bytes)
    }

    static func decode(_ bytes: Data) -> (text: String, format: TextFileFormat)? {
        let bom = bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
        let body = bom ? bytes.dropFirst(3) : bytes[...]
        if body.contains(0) { return nil }
        guard let text = String(data: Data(body), encoding: .utf8) else { return nil }
        return (text, TextFileFormat(hasBOM: bom, usesCRLF: text.contains("\r\n")))
    }

    /// Write `text` in `format`: LF breaks become CRLF for a CRLF file, and the BOM is
    /// kept when there was one. The swap uses one temp name per path (`*.vision-tmp`), so a
    /// write that dies halfway is replaced by the next write instead of leaving orphans.
    /// (A build from before the rename used `*.dsh-tmp`: one it left behind goes with the next write too.)
    static func write(to url: URL, text: String, format: TextFileFormat) throws {
        var body = text
        if format.usesCRLF {
            body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        }
        var data = Data(body.utf8)
        if format.hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        let directory = url.deletingLastPathComponent()
        if !directory.path.isEmpty {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let temp = URL(fileURLWithPath: url.path + tempSuffix)
        // The turn being recorded (if any) keeps what the file held before, and what this leaves (see `CheckpointStore`).
        let checkpoint = TurnCheckpoint.current
        try withLock(url.path) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError, userInfo: [
                    NSLocalizedDescriptionKey: "\(url.lastPathComponent) is a directory.",
                ])
            }
            checkpoint?.willChange(url)
            do {
                try data.write(to: temp)
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: url)
                }
                checkpoint?.didChange(url, data: data)
                try? FileManager.default.removeItem(atPath: url.path + legacyTempSuffix)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        }
    }

    /// The temp name's suffix for a write in progress.
    static let tempSuffix = ".vision-tmp"
    /// Legacy: the suffix a build from before the rename used; its leftovers are cleaned up, never written.
    static let legacyTempSuffix = ".dsh-tmp"

    /// Non-overlapping count. An empty needle matches nothing.
    static func countOccurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while let range = text.range(of: needle, range: start..<text.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    private static func stripeIndex(_ path: String) -> Int {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        var hash: UInt32 = 2166136261
        for byte in full.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return Int(hash % 64)
    }
}

// MARK: - read_file

public struct ReadFileTool: ToolExecutor {
    public static let name = "read_file"
    public static let spec = ToolSpec(
        name: name,
        description: "Read a text file. Returns contents with 1-based line numbers. Use start_line/end_line for large files (defaults to the first 1000 lines). Paths may be relative to the project folder.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string","description":"Path of the file to read"},"start_line":{"type":"integer","description":"First line to read (1-based, inclusive)"},"end_line":{"type":"integer","description":"Last line to read (inclusive)"},"description":{"type":"string","description":"Short reason for reading"}},"required":["file_path"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"), !raw.isEmpty else {
            return .init(output: "Error: file_path is required.")
        }
        let (url, _) = context.policy.resolve(raw)
        // CRLF and lone CR become LF so line math is sane, and so an edit copied
        // from this output matches a CRLF file (the edit writes CRLF back).
        guard let read = FileText.read(url) else {
            return .init(output: "Error: cannot read \(url.lastPathComponent): not a readable text file (binary or missing).")
        }
        let text = read.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let total = lines.count
        let start = max(1, Self.int(args, "start_line", default: 1))
        let end = min(total, max(start, Self.int(args, "end_line", default: min(total, start + 999))))
        guard start <= end, start <= total else {
            return .init(output: "Error: no such line range (file has \(total) lines).")
        }
        let out = lines[(start - 1)..<end].enumerated().map { i, line in
            String(format: "%d | %@", i + start, line)
        }.joined(separator: "\n")
        let more = end < total ? "\n\n(File has \(total) lines total; showing \(start)-\(end).)" : ""
        return .init(output: out + more)
    }
}

// MARK: - write_file

public struct WriteFileTool: ToolExecutor {
    public static let name = "write_file"
    public static let spec = ToolSpec(
        name: name,
        description: "Create or overwrite a file with the given contents. Parent directories are created as needed.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string","description":"Full file contents"},"description":{"type":"string"}},"required":["file_path","content"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"), let content = Self.string(args, "content") else {
            return .init(output: "Error: file_path and content are required.")
        }
        let (url, _) = context.policy.resolve(raw)
        var isDir: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        do {
            // Rewriting an existing file keeps its BOM and line endings. Content that
            // already uses CRLF is stored as written, so it is not converted twice.
            var format = TextFileFormat.default
            if existed, let previous = FileText.read(url) { format = previous.format }
            if content.contains("\r\n") { format.usesCRLF = false }
            try FileText.write(to: url, text: content, format: format)
            let change = FileChange(url, existed ? .modified : .created)
            return .init(output: "Wrote \(content.count) characters to \(url.lastPathComponent).", files: [change])
        } catch {
            return .init(output: "Error: write failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - edit (old_string/new_string)

public struct EditTool: ToolExecutor {
    public static let name = "edit"
    public static let spec = ToolSpec(
        name: name,
        description: "Replace an exact block of text in a file. old_string must match exactly (including whitespace) and must be unique in the file unless replace_all is true. Creates the file with just new_string when the file does not exist.",
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string","description":"Exact text to find"},"new_string":{"type":"string","description":"Replacement text"},"replace_all":{"type":"boolean","description":"Replace every occurrence"},"description":{"type":"string"}},"required":["file_path","old_string","new_string"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path"),
              let old = Self.string(args, "old_string"),
              let new = Self.string(args, "new_string") else {
            return .init(output: "Error: file_path, old_string and new_string are required.")
        }
        let replaceAll = Self.bool(args, "replace_all", default: false)
        let (url, _) = context.policy.resolve(raw)

        // Read, change and write back as one step: another agent editing this file
        // waits its turn and then starts from what this edit left.
        return FileText.withLock(url.path) {
            var isDir: ObjCBool = false
            let isFile = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            if !isFile {
                do {
                    try FileText.write(to: url, text: new, format: .default)
                    return .init(output: "Created \(url.lastPathComponent) with the new block.",
                                 files: [FileChange(url, .created)])
                } catch {
                    return .init(output: "Error: \(error.localizedDescription)")
                }
            }
            guard let read = FileText.read(url) else {
                return .init(output: "Error: cannot edit \(url.lastPathComponent): it is not a UTF-8 text file.")
            }
            // The model sees files with LF line endings (read_file normalizes them), so a
            // CRLF file is matched and edited in LF form and written back as CRLF.
            let crlf = read.format.usesCRLF
            let existing = crlf ? read.text.replacingOccurrences(of: "\r\n", with: "\n") : read.text
            let needle = crlf ? old.replacingOccurrences(of: "\r\n", with: "\n") : old
            let replacement = crlf ? new.replacingOccurrences(of: "\r\n", with: "\n") : new

            let occurrences = FileText.countOccurrences(of: needle, in: existing)
            guard occurrences >= 1 else {
                return .init(output: "Error: old_string not found in \(url.lastPathComponent). Read the file and copy the exact text (whitespace matters).")
            }
            if occurrences > 1 && !replaceAll {
                return .init(output: "Error: old_string matches \(occurrences) times. Include more surrounding lines to make it unique, or set replace_all=true.")
            }

            let updated: String
            if replaceAll {
                updated = existing.replacingOccurrences(of: needle, with: replacement)
            } else if let range = existing.range(of: needle) {
                updated = existing.replacingCharacters(in: range, with: replacement)
            } else {
                return .init(output: "Error: old_string not found.")
            }
            do {
                try FileText.write(to: url, text: updated, format: read.format)
                let n = replaceAll ? occurrences : 1
                return .init(output: "Edited \(url.lastPathComponent): replaced \(n) occurrence\(n == 1 ? "" : "s").",
                             files: [FileChange(url, .modified)])
            } catch {
                return .init(output: "Error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - list_directory

public struct ListDirectoryTool: ToolExecutor {
    public static let name = "list_directory"
    public static let spec = ToolSpec(
        name: name,
        description: "List files and directories. Non-recursive by default; pass recursive=true for a full tree.",
        parameters: """
        {"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: project folder)"},"recursive":{"type":"boolean"}},"required":[]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let raw = Self.string(args, "path") ?? "."
        let (url, _) = context.policy.resolve(raw)
        let recursive = Self.bool(args, "recursive", default: false)

        do {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return .init(output: "Error: \(url.path) is not a directory.")
            }
            let lines: [String]
            if recursive {
                lines = Self.walk(url)
            } else {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
                lines = entries.sorted { lhs, rhs in
                    let lDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let rDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return lDir == rDir ? lhs.lastPathComponent < rhs.lastPathComponent : lDir
                }.map { e in
                    let isDirectory = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return (isDirectory ? "📁 " : "  ") + e.lastPathComponent
                }
            }
            return .init(output: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"))
        } catch {
            return .init(output: "Error: \(error.localizedDescription)")
        }
    }

    private static func walk(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else {
            return []
        }
        var out: [String] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - root.pathComponents.count
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let indent = String(repeating: "  ", count: max(0, depth - 1))
            out.append(indent + (isDir ? "📁 " : "  ") + url.lastPathComponent)
            if out.count >= 500 {
                out.append("… (truncated at 500 entries)")
                break
            }
        }
        return out
    }
}