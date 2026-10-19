import Foundation

// MARK: - What a shell command changed, from git
//
// A shell command can change any file, and the harness can't see which ones from the command. In a git repository it
// can: before the command, `git status` lists the files that differ from the index (changed, deleted, new and not
// ignored) and their contents are kept; after it, `git status` again. A file that is on either list and isn't what it
// was is a change the command made: its "before" is what was kept — or, for a file that was clean, the index's copy
// as checked out (`git cat-file --filters`: what the working tree held) — and its "after" is what is there now. A file
// git can't answer about is marked as one that can't be rewound, never as one the command created. Ignored files (build output) are
// never looked at. Outside a git repository a shell command's changes aren't recorded.

/// Running git without surprises.
public enum GitProbe {
    /// A git that runs without asking to install anything: Homebrew's, or Apple's when its developer tools are
    /// installed (`/usr/bin/git` without them pops an installer dialog instead).
    public static let executable: String? = {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let developerTools = ["/Library/Developer/CommandLineTools/usr/bin/git",
                              "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        if developerTools.contains(where: { fm.isExecutableFile(atPath: $0) }), fm.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }
        return nil
    }()

    /// The repository a folder is in: the nearest folder at or above it with a `.git` (a folder, or a file for a
    /// worktree). Nil outside one.
    public static func repositoryRoot(containing folder: URL) -> URL? {
        var current = folder.standardizedFileURL
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path || current.path == "/" { return nil }
            current = parent
        }
    }

    /// Run git in `folder`; nil when it can't run, fails, or takes longer than `timeout`.
    public static func run(_ arguments: [String], in folder: URL, timeout: TimeInterval = 15) -> Data? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        // Reading must not take the index lock another git (the user's, the agent's) may need.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A git that hangs (a network filesystem, a lock) is stopped at the deadline; reading then ends.
        let box = ProcessBox(process)
        let watchdog = DispatchWorkItem { if box.process.isRunning { box.process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// NUL-separated paths (`git ls-files -z`).
    static func splitNul(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The paths `git status --porcelain -z` lists (relative to the repository), without the status letters.
    static func parseStatus(_ data: Data) -> [String] {
        // "XY path\0" per entry (renames are turned off, so there is never a second path).
        data.split(separator: 0).compactMap { field in
            guard field.count > 3 else { return nil }
            return String(decoding: field.dropFirst(3), as: UTF8.self)
        }
    }
}

/// The repository's changed files before a shell command, with their contents kept.
public struct GitBaseline: Sendable {
    public let root: URL
    /// Repository-relative path → the kept content's hash (nil = the file wasn't there).
    let dirty: [String: String?]
    /// Paths whose content couldn't be kept, and why.
    let unkept: [String: String]
}

extension TurnCheckpoint {
    /// More changed files than this and a shell command's changes aren't worked out (a huge untracked tree).
    static let maxGitEntries = 3_000

    static func gitStatus(_ root: URL) -> [String]? {
        GitProbe.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"], in: root)
            .map(GitProbe.parseStatus)
    }

    /// Before a shell command in `folder`: note what differs from the index now (nil outside a git repository, or
    /// when git can't say).
    public func gitBaseline(in folder: URL) -> GitBaseline? {
        guard let root = GitProbe.repositoryRoot(containing: folder), let paths = Self.gitStatus(root),
              paths.count <= Self.maxGitEntries else { return nil }
        var dirty: [String: String?] = [:]
        var unkept: [String: String] = [:]
        for path in paths {
            let kept = keep(path: root.appendingPathComponent(path).path)
            if let why = kept.skipped { unkept[path] = why }
            dirty[path] = kept.hash
        }
        return GitBaseline(root: root, dirty: dirty, unkept: unkept)
    }

    /// Why a clean file's earlier content is unknown: git didn't answer (a timeout, an odd path).
    static let gitCouldntSay = "git couldn't say what it held before"

    /// Which of `paths` the index has (nil when git can't say). Paths are taken literally, not as patterns.
    static func indexed(_ paths: [String], root: URL) -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        return GitProbe.run(["--literal-pathspecs", "ls-files", "-z", "--"] + paths, in: root)
            .map { Set(GitProbe.splitNul($0)) }
    }

    /// The index's copy of a clean file as the working tree holds it: with the checkout filters applied (Git LFS's
    /// smudge, `eol=crlf` / `core.autocrlf` line endings), so a rewind writes back the bytes that were on disk.
    static func checkedOutCopy(_ path: String, root: URL) -> Data? {
        GitProbe.run(["cat-file", "--filters", ":" + path], in: root)
    }

    /// After the command: record each file it changed (see the top of this file).
    public func recordGitChanges(since baseline: GitBaseline, by tool: String) {
        guard let paths = Self.gitStatus(baseline.root), paths.count <= Self.maxGitEntries else { return }
        let candidates = Set(paths).union(baseline.dirty.keys)
        // The files that were clean before the command: in the index (the working tree held its copy), or not (the
        // command made them). Asked once for all of them.
        let wereClean = candidates.filter { baseline.dirty[$0] == nil }.sorted()
        let inIndex = Self.indexed(wereClean, root: baseline.root)
        for path in candidates.sorted() {
            let absolute = baseline.root.appendingPathComponent(path).standardizedFileURL.path
            let before: String?
            var skipped: String? = baseline.unkept[path]
            if let kept = baseline.dirty[path] {
                before = kept
            } else if let inIndex, !inIndex.contains(path) {
                // Not in the index and not listed before: the command made it.
                before = nil
            } else if inIndex != nil, let data = Self.checkedOutCopy(path, root: baseline.root) {
                // It was clean: the working tree held the index's copy, as checked out.
                if data.count > CheckpointStore.maxFileBytes {
                    before = nil
                    skipped = "too large to keep"
                } else {
                    before = try? store.put(data)
                }
            } else {
                // Git didn't answer: what it held is unknown, so it is never treated as made by the command (a
                // rewind would delete it) — it can't be rewound.
                before = nil
                skipped = skipped ?? Self.gitCouldntSay
            }
            let after = keep(path: absolute)
            if skipped == nil, let why = after.skipped { skipped = why }
            // Unchanged by the command (it was changed before, and still holds the same).
            if skipped == nil, before == after.hash { continue }
            if skipped != nil, baseline.dirty[path] != nil, baseline.unkept[path] != nil, after.skipped != nil { continue }
            recordObserved(path: absolute, before: before, after: after.hash, skipped: skipped, by: tool)
        }
    }
}
