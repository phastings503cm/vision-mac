import Foundation

// MARK: - run_shell_command (async, pty-backed output capture)

public struct RunShellCommandTool: ToolExecutor {
    public static let name = "run_shell_command"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Run a shell command in the project folder on a real terminal (pty), so tty-aware \
            programs (ssh, sudo, vim, pagers) behave normally. Long-running commands get a \
            timeout (default 120s, max 600s). A command that prints a prompt and then waits \
            for interactive input is stopped after ~45s of silence, and its output includes \
            the prompt it was stuck on. Quiet long-running builds run to the full timeout. \
            Output is captured and returned (truncated to ~16 KB).
            """,
        parameters: """
        {"type":"object","properties":{"command":{"type":"string","description":"The command to run"},"timeout":{"type":"integer","description":"Timeout in seconds (default 120)"},"description":{"type":"string","description":"Short summary of what the command does"}},"required":["command"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let command = Self.string(args, "command"), !command.isEmpty else {
            return .init(output: "Error: command is required.")
        }
        let timeoutSec = min(600, max(5, Self.int(args, "timeout", default: 120)))

        // In a git repository, the turn's checkpoint works out which files the command changed (see GitChanges.swift).
        let checkpoint = TurnCheckpoint.current
        let tool = TurnCheckpoint.activeTool ?? Self.name
        let baseline = await Self.offPool { checkpoint?.gitBaseline(in: context.workspace) }

        // The pty is the controlling terminal; output streams straight into a
        // bounded tail. A prompt-block (no output for ~45s) or the total
        // deadline stops the run and `timedOut` is set.
        let result = await PTY.runCommand(command, cwd: context.workspace,
                                          timeout: TimeInterval(timeoutSec))
        if let checkpoint, let baseline {
            await Self.offPool { checkpoint.recordGitChanges(since: baseline, by: tool) }
        }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.timedOut {
            let idle = Int(PTY.idleLimit(TimeInterval(timeoutSec)))
            let note: String
            if text.isEmpty {
                note = "Command timed out after \(timeoutSec)s (it produced no output)."
            } else {
                note = "Stopped after \(timeoutSec)s limit — the command appears to be waiting for interactive input (silent for ~\(idle)s). Rerun with flags that answer the prompt, or tell the user what input it needs."
            }
            return .init(output: "\(note)\n\(Self.terminalText(text))")
        }
        if result.exitStatus == -1 {
            return .init(output: "Error: could not start the shell.")
        }
        if result.exitStatus == 0 {
            return .init(output: text.isEmpty ? "(no output)" : Self.terminalText(text))
        }
        return .init(output: "Command exited with code \(result.exitStatus).\n\(Self.terminalText(text))")
    }

    /// Blocking work (git) on a utility queue, not on the async pool's threads.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    /// Keep the tail of long output, capped like before (~16 KB).
    private static func terminalText(_ s: String, limit: Int = 16_000) -> String {
        guard s.count > limit else { return s }
        return "… [truncated \(s.count - limit) chars] …\n" + String(s.suffix(limit))
    }
}

// MARK: - web_fetch

public struct WebFetchTool: ToolExecutor {
    public static let name = "web_fetch"
    public static let spec = ToolSpec(
        name: name,
        description: "Fetch a URL and return its content as text. HTML is converted to readable text (scripts/styles stripped, tags removed). Useful for reading docs or API responses.",
        parameters: """
        {"type":"object","properties":{"url":{"type":"string","description":"Absolute http(s) URL"},"description":{"type":"string"}},"required":["url"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "url"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .init(output: "Error: a valid http(s) url is required.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) \(AppIdentity.name).app", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .init(output: "Error: HTTP \(http.statusCode) for \(url.absoluteString).")
            }
            let ct = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let text: String
            if ct.contains("html") || ct.contains("xml") {
                text = Self.htmlToText(String(decoding: data, as: UTF8.self))
            } else {
                text = String(decoding: data, as: UTF8.self)
            }
            let cut = text.count > 24_000 ? String(text.prefix(24_000)) + "\n\n… [truncated]" : text
            return .init(output: "URL: \(url.absoluteString)\n\n" + cut)
        } catch {
            return .init(output: "Error: fetch failed: \(error.localizedDescription)")
        }
    }

    /// A quick-and-dirty HTML → text converter: strip script/style/head,
    /// block-level tags become newlines, all other tags are removed.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for junk in ["<script.*?</script>", "<style.*?</style>", "<head.*?</head>", "<nav.*?</nav>",
                     "<footer.*?</footer>", "<!--.*?-->"] {
            s = s.replacingOccurrences(of: junk, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "(?i)<(br|/p|/div|/h[1-6]|/li|/tr|/pre)[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|tr|pre)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let amp = String(UnicodeScalar(38)!) // &
        let entities: [(String, String)] = [
            (amp + "nbsp;", " "),
            (amp + "amp;", String(UnicodeScalar(38)!)),
            (amp + "lt;", String(UnicodeScalar(60)!)),
            (amp + "gt;", String(UnicodeScalar(62)!)),
            (amp + "quot;", String(UnicodeScalar(34)!)),
            (amp + "#39;", String(UnicodeScalar(39)!)),
        ]
        var decoded = s
        for (from, to) in entities where from != to {
            decoded = decoded.replacingOccurrences(of: from, with: to)
        }
        s = decoded
        // Collapse runs of spaces and blank lines.
        s = s.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - todo_write

public struct TodoWriteTool: ToolExecutor {
    public static let name = "todo_write"
    public static let spec = ToolSpec(
        name: name,
        description: "Create or replace the structured task list for the current session. Items: {content, status: pending|in_progress|completed}. Use for multi-step work so progress is visible to the user.",
        parameters: """
        {"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]},"description":"The complete updated task list"}},"required":["todos"]}
        """
    )

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let data = args.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let items = dict["todos"] as? [[String: Any]] else {
            return .init(output: "Error: 'todos' array required.")
        }
        let parsed: [TodoItem] = items.enumerated().compactMap { i, it in
            guard let content = it["content"] as? String, !content.isEmpty else { return nil }
            let status: TodoItem.Status
            switch (it["status"] as? String)?.lowercased() {
            case "in_progress", "inprogress": status = .inProgress
            case "completed", "done": status = .completed
            default: status = .pending
            }
            return TodoItem(id: "\(i + 1)", content: content, status: status)
        }
        let summary = parsed.map {
            let mark: String
            switch $0.status {
            case .pending: mark = "☐"
            case .inProgress: mark = "◐"
            case .completed: mark = "✓"
            }
            return "\(mark) \($0.content)"
        }.joined(separator: "\n")
        return .init(output: summary.isEmpty ? "Task list cleared." : "Task list updated:\n\(summary)",
                     todos: parsed.isEmpty ? [] : parsed)
    }
}