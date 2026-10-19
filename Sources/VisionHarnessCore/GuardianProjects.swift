import Foundation

// MARK: - What a code project upload holds

/// Settings ▸ Guardian ▸ Code projects ▸ Upload: the project's text files by "/"-separated relative path (UTF-8 only,
/// under 400 KB each, at most 2,000), skipping build output, dependencies and — never uploaded, wherever they are —
/// files that hold keys or passwords. The same credential rule and limits as Vision for Windows.
public enum GuardianProjects {
    /// Folders never uploaded: build output, dependencies, version control.
    public static let skippedFolders: Set<String> = ["node_modules", ".git", ".build", "dist", ".venv", "__pycache__", ".next"]
    public static let maxFileBytes = 400_000
    public static let maxFiles = 2_000

    /// Files that hold keys or passwords.
    public static func isCredentialFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        if [".env", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "credentials.json",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(lower) { return true }
        if lower.hasPrefix(".env."), ![".env.example", ".env.sample", ".env.template"].contains(lower) { return true }
        return [".pem", ".key", ".pfx", ".p12"].contains { lower.hasSuffix($0) }
    }

    // MARK: Downloading a copy

    /// The folder name for a downloaded copy: Guardian's project name, made safe — no "/" or ":", no leading dots, no
    /// ".." — or "guardian-project" when nothing is left.
    public static func folderName(_ name: String) -> String {
        let parts = name.filter { !$0.isNewline && $0 != "\0" }
            .split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var clean = parts.joined(separator: "-")
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "guardian-project" : String(clean.prefix(120))
    }

    /// A new folder in `parent` for the copy: the project's name, or "name (2)", "name (3)", … — never one that is
    /// already there, so a download never writes over a working tree.
    public static func newFolder(for name: String, in parent: URL, fileManager: FileManager = .default) -> URL {
        let base = folderName(name)
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Where a manifest path goes under `root`, or nil when it would land outside it (absolute, "..", ".").
    public static func file(_ path: String, under root: URL) -> URL? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !segments.isEmpty,
              !segments.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." || $0.contains("\\") || $0.contains("\0") })
        else { return nil }
        let file = root.appendingPathComponent(path).standardizedFileURL
        let base = root.standardizedFileURL.path
        return file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") ? file : nil
    }

    /// What an upload holds and what it left out.
    public struct Manifest: Sendable, Equatable {
        public var files: [String: String]
        public var skippedBinary = 0
        public var skippedLarge = 0
        public var skippedSecret = 0
        public var truncated = false

        /// "Uploaded 12 files from ledger to Guardian. Left out: 1 file with keys, 2 binary." (Windows' words.)
        public func summary(project: String) -> String {
            var left: [String] = []
            if skippedSecret > 0 { left.append("\(skippedSecret) file\(skippedSecret == 1 ? "" : "s") with keys") }
            if skippedBinary > 0 { left.append("\(skippedBinary) binary") }
            if skippedLarge > 0 { left.append("\(skippedLarge) over 400 KB") }
            return "Uploaded \(files.count) file\(files.count == 1 ? "" : "s") from \(project) to Guardian."
                + (left.isEmpty ? "" : " Left out: \(left.joined(separator: ", ")).")
                + (truncated ? " (The first 2,000 files.)" : "")
        }
    }

    /// Read the project. Links are never followed (they could lead out of the project).
    public static func collect(_ root: URL) -> Manifest {
        var manifest = Manifest(files: [:])
        let base = root.standardizedFileURL.path
        var pending = [root.standardizedFileURL]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        while let folder = pending.popLast(), !manifest.truncated {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                let name = url.lastPathComponent
                if values.isDirectory == true {
                    if !skippedFolders.contains(name) { pending.append(url) }
                    continue
                }
                if isCredentialFile(name) { manifest.skippedSecret += 1; continue }
                if (values.fileSize ?? 0) >= maxFileBytes { manifest.skippedLarge += 1; continue }
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                      !text.contains("\u{0}") else { manifest.skippedBinary += 1; continue }
                guard manifest.files.count < maxFiles else { manifest.truncated = true; break }
                let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                manifest.files[path] = text
            }
        }
        return manifest
    }
}
