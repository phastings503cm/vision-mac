import Foundation

// MARK: - Claude Code sessions (~/.claude/projects)
//
// One JSONL file per session, `<projects>/<folder-as-dashes>/<session-id>.jsonl`. Subagents and workflow agents keep
// their own files under `<session-id>/subagents/` and `<session-id>/workflows/`; those are not imported as chats (their
// final reports are already the results of the session's Agent tool calls) — the import notes how many there were.
//
// Lines that matter (everything else — attachments, hook summaries, file snapshots, cost and mode records — is
// skipped):
//   {type:"user", message:{content: "text" | [blocks]}, timestamp, cwd, isMeta?, isSidechain?, isCompactSummary?}
//     blocks: text · image · tool_result {tool_use_id, content, is_error}
//   {type:"assistant", message:{content:[text | tool_use {id,name,input} | thinking], model}, isApiErrorMessage?}
//     (one reply arrives as several lines, one block each; consecutive text joins)
//   {type:"attachment", attachment:{type:"queued_command", prompt}} — a prompt typed while a turn ran
//   {type:"custom-title", customTitle} · {type:"ai-title", aiTitle} · {type:"summary", summary} (older builds)
// Text the harness wraps in tags is shown as what it was: `<command-name>` a slash command, `<task-notification>` a
// background task's result, `<local-command-stdout>` a command's output — notices, which the model isn't sent again.

public enum ClaudeCodeChats {
    /// `$CLAUDE_CONFIG_DIR/projects` when set, else `~/.claude/projects`.
    public static func root(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The sessions under `root`: the JSONL files directly in each project folder (not subagents').
    public static func sessionFiles(root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out: [URL] = []
        for project in projects where (try? project.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fileManager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? []
            out += files.filter { $0.pathExtension == "jsonl" }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// How many subagent / workflow-agent transcripts a session kept beside it.
    public static func subagentCount(for file: URL) -> Int {
        let folder = file.deletingPathExtension()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" && !url.path.contains("/tool-results/") {
            count += 1
        }
        return count
    }

    /// One session read whole. `preview` decodes only the lines the preview needs (text, prompts, titles) and takes
    /// just the time from the rest — tool calls and results hold most of a session's bytes — so a first look at a
    /// long history takes seconds.
    public static func read(_ file: URL, preview: Bool = false) throws -> ImportedChat? {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .alwaysMapped)
        } catch {
            throw ChatImportError.unreadable("\(file.lastPathComponent): \(error.localizedDescription)")
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return parse(data, fallbackID: file.deletingPathExtension().lastPathComponent,
                     folderName: file.deletingLastPathComponent().lastPathComponent,
                     subagents: subagentCount(for: file), modified: modified, preview: preview)
    }

    /// One session's lines as a chat (nil when it holds no conversation at all).
    public static func parse(_ data: Data, fallbackID: String, folderName: String? = nil, subagents: Int = 0,
                             modified: Date? = nil, preview: Bool = false) -> ImportedChat? {
        var builder = ImportTranscriptBuilder()
        var sessionID: String?
        var cwd: String?
        var customTitle: String?
        var aiTitle: String?
        var agentName: String?
        var summaryTitle: String?
        var model: String?
        var first: Date?
        var last: Date?
        var scripted = false
        var lastAt = Date(timeIntervalSince1970: 0)
        // The preview decodes only lines that can change what it shows (most bytes are tool calls, tool results,
        // thinking and attachments): one with text in it, a typed prompt, a queued prompt, a title. A skipped line
        // gives only its time — its first "timestamp" key (one inside a string value has its quotes escaped).
        let toolResultMark = Data(#""tool_use_id""#.utf8)
        let textMark = Data(#""type":"text""#.utf8)
        let toolUseMark = Data(#""type":"tool_use""#.utf8)
        let serverToolMark = Data(#""type":"server_tool_use""#.utf8)
        let typedMark = Data(#""role":"user","content":""#.utf8)
        let queuedMark = Data(#""queued_command""#.utf8)
        let titleMarks = [#""type":"custom-title""#, #""type":"ai-title""#, #""type":"agent-name""#, #""type":"summary""#]
            .map { Data($0.utf8) }

        let offBranch = preview ? [] : offBranchLines(data)
        var lineIndex = -1

        JSONLines.forEachLine(data) { raw in
            lineIndex += 1
            if offBranch.contains(lineIndex) { return true }
            if preview {
                let head = raw.prefix(600)
                let wanted = !JSONLines.contains(head, toolResultMark)
                    && (JSONLines.contains(raw, textMark) || JSONLines.contains(head, typedMark)
                        || JSONLines.contains(head, queuedMark) || titleMarks.contains { JSONLines.contains(head, $0) })
                if !wanted {
                    // A tool call or result between two answers keeps them two messages, as the full read does.
                    if JSONLines.contains(head, toolResultMark) || JSONLines.contains(raw, toolUseMark)
                        || JSONLines.contains(raw, serverToolMark) {
                        builder.separate()
                    }
                    if let at = JSONLines.timestamp(in: raw) {
                        first = first.map { min($0, at) } ?? at
                        last = last.map { max($0, at) } ?? at
                        lastAt = max(lastAt, at)
                    }
                    return true
                }
            }
            guard let line = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return true }
            let type = line["type"] as? String ?? ""
            switch type {
            case "custom-title":
                if let title = line["customTitle"] as? String, !title.isEmpty { customTitle = title }
                return true
            case "ai-title":
                if let title = line["aiTitle"] as? String, !title.isEmpty { aiTitle = title }
                return true
            case "agent-name":
                if let title = line["agentName"] as? String, !title.isEmpty { agentName = title }
                return true
            case "summary":
                if let title = line["summary"] as? String, !title.isEmpty { summaryTitle = title }
                return true
            default:
                break
            }
            guard line["isSidechain"] as? Bool != true else { return true }
            let at = (line["timestamp"] as? String).flatMap(ImportDates.iso(_:)) ?? lastAt
            if type == "user" || type == "assistant" || type == "attachment" {
                if at > Date(timeIntervalSince1970: 0) {
                    first = first.map { min($0, at) } ?? at
                    last = last.map { max($0, at) } ?? at
                    lastAt = at
                }
                if sessionID == nil, let id = line["sessionId"] as? String, !id.isEmpty { sessionID = id }
                if cwd == nil, let folder = line["cwd"] as? String, !folder.isEmpty { cwd = folder }
                if let entry = line["entrypoint"] as? String, entry.hasPrefix("sdk") { scripted = true }
            }
            switch type {
            case "user":
                user(line, at: at, into: &builder)
            case "assistant":
                assistant(line, at: at, model: &model, into: &builder)
            case "attachment":
                if let attachment = line["attachment"] as? [String: Any],
                   attachment["type"] as? String == "queued_command" {
                    let prompt = ImportText.blocksText(attachment["prompt"])
                    // Queued task notifications also arrive as their own user line; only typed prompts are new here.
                    if !prompt.trimmingCharacters(in: .whitespaces).hasPrefix("<") {
                        builder.user(ImportText.stripReminders(prompt), at: at)
                    }
                }
            default:
                break
            }
            return true
        }

        let rows = builder.finish()
        guard rows.contains(where: \.isMessage) else { return nil }
        let created = first ?? modified ?? .now
        let title = customTitle ?? aiTitle ?? agentName ?? summaryTitle
            ?? builder.firstPrompt.flatMap(ImportText.title(fromPrompt:)) ?? "Claude Code session"
        return ImportedChat(source: .claudeCode, sourceID: sessionID ?? fallbackID, title: title, createdAt: created,
                            updatedAt: last ?? modified ?? created, cwd: cwd, model: model, rows: rows,
                            automated: scripted, subagents: subagents)
    }

    /// The lines (by position among non-empty lines) off the branch the session ended on. Claude Code keeps a tree:
    /// each entry names its parent (`parentUuid`; across a compaction, the boundary's `logicalParentUuid`), and a rewind
    /// leaves the abandoned branch in the file. The branch is walked up from the last user or assistant entry; a tool
    /// result whose call is on the branch stays (parallel calls' results are siblings of each other). A walk that
    /// reaches a parent the file doesn't hold drops nothing.
    static func offBranchLines(_ data: Data) -> Set<Int> {
        struct Entry {
            var line: Int
            var uuid: String
            var parent: String?
            var resultsFor: [String]
            var calls: [String]
            var message: Bool
        }
        var entries: [Entry] = []
        var index = -1
        JSONLines.forEachLine(data) { raw in
            index += 1
            guard let line = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let uuid = line["uuid"] as? String, line["isSidechain"] as? Bool != true else { return true }
            let type = line["type"] as? String ?? ""
            let parent = line["parentUuid"] as? String ?? line["logicalParentUuid"] as? String
            var results: [String] = []
            var calls: [String] = []
            if let blocks = (line["message"] as? [String: Any])?["content"] as? [Any] {
                for case let block as [String: Any] in blocks {
                    if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String { results.append(id) }
                    if block["type"] as? String == "tool_use", let id = block["id"] as? String { calls.append(id) }
                }
            }
            entries.append(Entry(line: index, uuid: uuid, parent: parent, resultsFor: results, calls: calls,
                                 message: type == "user" || type == "assistant"))
            return true
        }
        guard let leaf = entries.last(where: \.message) else { return [] }
        let byID = Dictionary(entries.map { ($0.uuid, $0) }, uniquingKeysWith: { _, last in last })
        var branch: Set<String> = [leaf.uuid]
        var node = leaf
        while let up = node.parent {
            guard let next = byID[up], !branch.contains(up) else {
                if byID[up] == nil { return [] }
                break
            }
            branch.insert(up)
            node = next
        }
        let callsOnBranch = Set(entries.filter { branch.contains($0.uuid) }.flatMap(\.calls))
        var off = Set<Int>()
        for entry in entries where !branch.contains(entry.uuid) {
            if !entry.resultsFor.isEmpty, entry.resultsFor.allSatisfy(callsOnBranch.contains) { continue }
            off.insert(entry.line)
        }
        return off
    }

    private static func user(_ line: [String: Any], at: Date, into builder: inout ImportTranscriptBuilder) {
        guard line["isMeta"] as? Bool != true, let message = line["message"] as? [String: Any] else { return }
        if line["isCompactSummary"] as? Bool == true {
            builder.compaction(ImportText.blocksText(message["content"]), at: at)
            return
        }
        let origin = (line["origin"] as? [String: Any])?["kind"] as? String
        switch message["content"] {
        case let text as String:
            typed(text, origin: origin, at: at, into: &builder)
        case let blocks as [Any]:
            var typedText: [String] = []
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    let output = ImportText.blocksText(block["content"])
                    builder.toolResult(id: block["tool_use_id"] as? String, name: nil, output: output,
                                       isError: block["is_error"] as? Bool ?? false, at: at)
                case "text":
                    if let text = block["text"] as? String { typedText.append(text) }
                case "image":
                    typedText.append("[image]")
                case "document":
                    typedText.append("[document]")
                default:
                    break
                }
            }
            if !typedText.isEmpty { typed(typedText.joined(separator: "\n\n"), origin: origin, at: at, into: &builder) }
        default:
            break
        }
    }

    /// Something the person's side sent: a prompt, or one of the harness's tagged messages — a slash command and its
    /// output, a `!` shell command and its output, a background task's result, another session's message, an
    /// interruption. Only prompts go to a model again; the rest are notices.
    private static func typed(_ raw: String, origin: String? = nil, at: Date, into builder: inout ImportTranscriptBuilder) {
        let text = ImportText.stripReminders(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return }
        if text.hasPrefix("[Request interrupted by user") {
            builder.notice("Interrupted by the user.", at: at)
        } else if origin == "task-notification" || origin == "peer" || text.hasPrefix("<task-notification>") {
            if let summary = ImportText.tag("summary", in: text), !summary.isEmpty {
                let status = ImportText.tag("status", in: text) ?? ""
                builder.notice(status.isEmpty ? "Background task: \(summary)" : "Background task \(status): \(summary)", at: at)
            } else {
                builder.notice(origin == "peer" ? "Message from another session: \(text)" : text, at: at)
            }
        } else if let output = ImportText.tag("local-command-stdout", in: text) {
            builder.notice(output, at: at)
        } else if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
            let name = ImportText.tag("command-name", in: text) ?? ImportText.tag("command-message", in: text).map { "/" + $0 } ?? ""
            let args = ImportText.tag("command-args", in: text) ?? ""
            builder.notice("Ran \(name)\(args.isEmpty ? "" : " " + args) in Claude Code.", at: at)
        } else if let command = ImportText.tag("bash-input", in: text) {
            builder.user("! " + command, at: at)
        } else if let output = ImportText.tag("bash-stdout", in: text) {
            let error = ImportText.tag("bash-stderr", in: text) ?? ""
            builder.notice(error.isEmpty ? output : output + "\n" + error, at: at)
        } else if text.hasPrefix("<local-command-caveat>") || text.hasPrefix("<local-command-stderr>") {
            return
        } else {
            builder.user(text, at: at)
        }
    }

    private static func assistant(_ line: [String: Any], at: Date, model: inout String?,
                                  into builder: inout ImportTranscriptBuilder) {
        guard let message = line["message"] as? [String: Any] else { return }
        if let name = message["model"] as? String, !name.isEmpty, name != "<synthetic>" { model = name }
        if line["isApiErrorMessage"] as? Bool == true || message["model"] as? String == "<synthetic>" {
            builder.error(ImportText.blocksText(message["content"]), at: at)
            return
        }
        guard let blocks = message["content"] as? [Any] else {
            if let text = message["content"] as? String { builder.assistant(text, at: at) }
            return
        }
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "text":
                builder.assistant(block["text"] as? String ?? "", at: at)
            case "tool_use", "server_tool_use":
                builder.toolCall(id: block["id"] as? String, name: block["name"] as? String ?? "tool",
                                 input: block["input"], at: at)
            case let type? where type.hasSuffix("_tool_result"):
                builder.toolResult(id: block["tool_use_id"] as? String, name: nil,
                                   output: ImportText.blocksText(block["content"]), isError: false, at: at)
            default:
                break   // thinking, redacted thinking
            }
        }
    }
}
