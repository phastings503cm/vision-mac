import Foundation

// MARK: - Git status, for the coding mode's project status

/// `git status --porcelain=v1 --branch`, read.
public struct GitStatusSummary: Hashable, Sendable {
    public struct File: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public var path: String
        /// The two status letters ("M ", " M", "??", "A ", "R ", "UU" …).
        public var code: String
        /// One word: modified, added, deleted, renamed, untracked, conflicted.
        public var label: String {
            if code == "??" { return "untracked" }
            if code.contains("U") || code == "AA" || code == "DD" { return "conflicted" }
            if code.contains("R") { return "renamed" }
            if code.contains("A") { return "added" }
            if code.contains("D") { return "deleted" }
            return "modified"
        }
        /// The letter shown beside it.
        public var letter: String {
            switch label {
            case "untracked": "U"
            case "conflicted": "!"
            case "renamed": "R"
            case "added": "A"
            case "deleted": "D"
            default: "M"
            }
        }
        /// Something staged for the next commit.
        public var staged: Bool { code.first.map { $0 != " " && $0 != "?" } ?? false }
    }

    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var files: [File]

    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, files: [File] = []) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public var isClean: Bool { files.isEmpty }

    /// "main · 3 changed · ↑1" — one line for a header.
    public var summary: String {
        var parts = [branch ?? "detached"]
        parts.append(files.isEmpty ? "clean" : "\(files.count) changed")
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " · ")
    }

    public static func parse(porcelain: String) -> GitStatusSummary {
        var summary = GitStatusSummary()
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("## ") {
                parseBranch(String(line.dropFirst(3)), into: &summary)
                continue
            }
            guard line.count >= 4 else { continue }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            summary.files.append(File(path: path, code: code))
        }
        return summary
    }

    private static func parseBranch(_ text: String, into summary: inout GitStatusSummary) {
        // "main...origin/main [ahead 1, behind 2]" · "No commits yet on main" · "HEAD (no branch)"
        var head = text
        if let bracket = head.range(of: " [") {
            let counts = head[bracket.upperBound...].dropLast(head.hasSuffix("]") ? 1 : 0)
            for part in counts.split(separator: ",") {
                let bits = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard bits.count == 2, let n = Int(bits[1]) else { continue }
                if bits[0] == "ahead" { summary.ahead = n }
                if bits[0] == "behind" { summary.behind = n }
            }
            head = String(head[..<bracket.lowerBound])
        }
        if head.hasPrefix("No commits yet on ") {
            summary.branch = String(head.dropFirst("No commits yet on ".count))
            return
        }
        if head.hasPrefix("HEAD (no branch)") { summary.branch = nil; return }
        let pieces = head.components(separatedBy: "...")
        summary.branch = pieces.first.flatMap { $0.isEmpty ? nil : $0 }
        if pieces.count > 1 { summary.upstream = pieces[1] }
    }
}
