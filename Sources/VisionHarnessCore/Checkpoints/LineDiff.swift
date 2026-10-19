import Foundation

// MARK: - Line diffs (what a turn changed in a file)
//
// A unified diff of two texts, line by line, in hunks with a few lines of context — what "Files changed (N)" shows
// under a turn. Uses the standard library's difference (Myers), so it is fast for source files; very large files
// are summarised instead of diffed.

public struct DiffLine: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
    /// 1-based line numbers in the old and new text (nil where the line isn't in that side).
    public var oldNumber: Int?
    public var newNumber: Int?
}

public struct DiffHunk: Hashable, Sendable, Identifiable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]
    public var id: String { "\(oldStart),\(newStart)" }
    /// "@@ -12,7 +12,9 @@"
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

public struct FileDiff: Hashable, Sendable {
    public var hunks: [DiffHunk]
    public var added: Int
    public var removed: Int
    /// Why there is no line diff ("binary file", "too large to compare"); nil = `hunks` is it.
    public var note: String?

    public init(hunks: [DiffHunk], added: Int, removed: Int, note: String? = nil) {
        self.hunks = hunks
        self.added = added
        self.removed = removed
        self.note = note
    }
}

public enum LineDiff {
    /// Lines of context around each change.
    public static let context = 3
    /// More lines than this on either side and the files are only counted, not compared.
    public static let maxLines = 40_000

    /// The diff of two file contents (nil = the file didn't exist on that side).
    public static func diff(old: Data?, new: Data?) -> FileDiff {
        func text(_ data: Data?) -> String?? {
            guard let data else { return .some(nil) }
            if data.contains(0) { return .none }
            guard let string = String(data: data, encoding: .utf8) else { return .none }
            return .some(string)
        }
        guard case .some(let oldText) = text(old), case .some(let newText) = text(new) else {
            return FileDiff(hunks: [], added: 0, removed: 0,
                            note: "Binary file — \(size(old)) → \(size(new))")
        }
        return diff(old: oldText ?? "", new: newText ?? "", oldExists: oldText != nil, newExists: newText != nil)
    }

    static func size(_ data: Data?) -> String {
        guard let data else { return "none" }
        return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    public static func diff(old: String, new: String, oldExists: Bool = true, newExists: Bool = true) -> FileDiff {
        let a = lines(old), b = lines(new)
        if a.count > maxLines || b.count > maxLines {
            return FileDiff(hunks: [], added: b.count, removed: a.count,
                            note: "Too large to compare line by line (\(a.count.formatted()) → \(b.count.formatted()) lines)")
        }
        let difference = b.difference(from: a)
        var removedOffsets = Set<Int>(), insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }
        // Walk both sides in order: the whole file as context / removed / added lines.
        var all: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedOffsets.contains(i) {
                all.append(DiffLine(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else if j < b.count, insertedOffsets.contains(j) {
                all.append(DiffLine(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            } else if i < a.count, j < b.count {
                all.append(DiffLine(kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1
                j += 1
            } else if i < a.count {
                all.append(DiffLine(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            } else {
                all.append(DiffLine(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            }
        }
        let added = all.filter { $0.kind == .added }.count
        let removed = all.filter { $0.kind == .removed }.count
        return FileDiff(hunks: hunks(all), added: added, removed: removed,
                        note: added == 0 && removed == 0 && oldExists != newExists
                            ? (newExists ? "New empty file" : "Empty file removed") : nil)
    }

    /// Group the lines into hunks: each change with `context` lines around it, nearby changes merged.
    static func hunks(_ all: [DiffLine]) -> [DiffHunk] {
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(all.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { range in
            let lines = Array(all[range])
            // A side's start is its first line here; for a side with no lines in the hunk, the line before it.
            let oldNumbers = lines.compactMap(\.oldNumber), newNumbers = lines.compactMap(\.newNumber)
            let before = all[..<range.lowerBound]
            let oldStart = oldNumbers.first ?? (before.last(where: { $0.oldNumber != nil })?.oldNumber ?? 0)
            let newStart = newNumbers.first ?? (before.last(where: { $0.newNumber != nil })?.newNumber ?? 0)
            return DiffHunk(oldStart: oldStart, oldCount: oldNumbers.count, newStart: newStart,
                            newCount: newNumbers.count, lines: lines)
        }
    }
}
