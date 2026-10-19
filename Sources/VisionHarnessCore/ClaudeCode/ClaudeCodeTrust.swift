import Foundation
import Darwin

// MARK: - Whose settings a Claude Code turn loads
//
// Headless `claude -p` shows no workspace-trust question and no per-server approval: started in a folder as it is,
// it runs the hooks, `env` and `apiKeyHelper` of the folder's own .claude/settings(.local).json and starts every
// server in its .mcp.json — so a cloned repository could run code on this Mac the moment a chat sent a message.
// Vision therefore loads only the person's own settings (`--setting-sources user`: their ~/.claude settings and
// user-scope MCP servers), unless the person has trusted the folder in Claude Code itself — its trust question,
// recorded as `projects[<folder>].hasTrustDialogAccepted` in ~/.claude.json, for the folder or a folder above it
// (never inherited from the home folder or /). Checked against the real CLI 2.1.299 in a folder with a SessionStart
// hook in .claude/settings.json and .claude/settings.local.json, a server in .mcp.json, a local-scope server and a
// CLAUDE.md: plain `-p` ran all of them; with `--setting-sources user` none ran (and CLAUDE.md wasn't read), while
// the person's own hook and user-scope server still did. Vision for Windows does the same.

/// What a turn in a folder loads of the folder's own Claude Code settings.
public enum ClaudeCodeFolderSettings: Sendable, Equatable {
    /// Trusted in Claude Code: the folder's own settings load, as they would in a terminal.
    case trusted
    /// Not trusted: only the person's own settings load. `skipped` = the folder's own files left out (none: nothing to say).
    case userOnly(skipped: [String])
    /// Not trusted, the folder has settings of its own, and this CLI can't be told to leave them out.
    case cantSkip(skipped: [String])

    /// Pass the folder's own settings (no `--setting-sources`).
    public var loadsProjectSettings: Bool { self == .trusted }
}

public enum ClaudeCodeTrust {
    /// The folder's own files a turn would otherwise load, as the notice names them.
    public static let projectFiles = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", ".claude/settings.json",
                                      ".claude/settings.local.json", ".mcp.json"]

    /// Claude Code's own config file: `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json` (with the turn's environment).
    public static func configFile(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
        }
        let base = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home
        return URL(fileURLWithPath: base).appendingPathComponent(".claude.json")
    }

    /// Whether the person trusted `folder` in Claude Code: the config at `configFile(environment:)` says so for it, or
    /// for a folder above it other than the home folder and /.
    public static func isTrusted(_ folder: URL, environment: [String: String], home: String = NSHomeDirectory()) -> Bool {
        let data = try? Data(contentsOf: configFile(environment: environment, home: home))
        return isTrusted(folder, config: data, home: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home)
    }

    /// `isTrusted` on the config's bytes (nil or unreadable: nothing is trusted).
    public static func isTrusted(_ folder: URL, config: Data?, home: String) -> Bool {
        guard let config, let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return false }
        func accepted(_ path: String) -> Bool {
            ((projects[path] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool) == true
        }
        let homes: Set<String> = [standardized(home), realPath(home)]
        // The folder as Vision names it and as Claude Code does (its working directory is the real path: /private/tmp).
        for start in Set([standardized(folder.path), realPath(folder.path)]) {
            if accepted(start) { return true }
            var path = start
            while true {
                let parent = (path as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != path, parent != "/", !homes.contains(parent) else { break }
                if accepted(parent) { return true }
                path = parent
            }
        }
        return false
    }

    /// The folder's own Claude Code files that exist (relative paths, in `projectFiles` order).
    public static func present(in folder: URL) -> [String] {
        projectFiles.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// What a turn in `folder` loads, for this CLI.
    public static func settings(for folder: URL, install: ClaudeCodeInstall, trusted: Bool) -> ClaudeCodeFolderSettings {
        if trusted { return .trusted }
        let found = present(in: folder)
        if install.supports("--setting-sources") || found.isEmpty { return .userOnly(skipped: found) }
        return .cantSkip(skipped: found)
    }

    /// Said once per chat per launch when a folder's own files are left out.
    public static func skippedNotice(_ files: [String]) -> String {
        "Claude Code isn't using this folder's own settings (\(files.joined(separator: ", "))): you haven't trusted the folder in Claude Code, so its hooks and MCP servers stay off. To use them, run  claude  once in this folder in a terminal and accept its trust question."
    }

    /// Why a turn can't start on a CLI that can't leave the folder's own settings out.
    public static func cantSkipMessage(version: String?, files: [String]) -> String {
        let named = version.map { "Claude Code \($0)" } ?? "This Claude Code"
        return "This folder has Claude Code settings of its own (\(files.joined(separator: ", "))), and \(named) can't be told to leave them out — their hooks and MCP servers would run without asking. Update it in a terminal (claude update), or trust the folder: run  claude  once in it and accept its trust question."
    }

    // MARK: Paths

    static func standardized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    /// The path with every symbolic link resolved (realpath(3) on the part that exists, the rest appended), so /tmp
    /// and /private/tmp — or a link inside the project that points out of it — compare as what they really are.
    public static func realPath(_ path: String) -> String {
        var existing = standardized(path)
        var rest: [String] = []
        while existing != "/", !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        var resolved = existing
        if let real = Darwin.realpath(existing, nil) {
            resolved = String(cString: real)
            free(real)
        }
        guard !rest.isEmpty else { return resolved }
        return (resolved == "/" ? "" : resolved) + "/" + rest.joined(separator: "/")
    }

    /// `path` is `root` or inside it (both real paths).
    static func contains(_ root: String, _ path: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }
}
