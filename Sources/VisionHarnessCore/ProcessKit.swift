import Foundation
import Darwin

// MARK: - Background processes (interact with long-running programs)
//
// `run_shell_command` is one-shot: it captures output, waits, and kills
// anything still talking to a prompt. That is the right shape for builds and
// greps, but wrong for a game engine, a dev server, a REPL, or an installer
// that waits for a yes/no. These tools keep a process alive on its own pty
// between tool calls: `process_start` launches it, `process_read` streams
// whatever it printed since the last read (with an `until` match so the model
// can wait for "Godot Engine v" or "SCRIPT ERROR" instead of polling blindly),
// `process_write` types into it, `process_stop` ends it.
//
// The output buffer is a bounded ring; each reader holds its own cursor, so a
// model turn that reads twice never sees the same bytes twice, and a crashed
// process still reports its exit code.

/// One live (or recently exited) background process.
public final class BackgroundProcess: @unchecked Sendable {
    public let id: String
    public let command: String
    public let startedAt = Date()
    private(set) var pid: pid_t = -1

    private let lock = NSLock()
    private let pty: PTY
    /// Raw pty bytes, trimmed to the last `ringLimit`.
    private var buffer = Data()
    private var ringLimit = 512_000
    private var dropped = 0            // bytes trimmed from the front of buffer
    private var exited: Int32?         // nil while running
    /// Per-reader cursors: how far into `buffer` each reader position has seen.
    /// Cursors are absolute (buffer offset + dropped).
    private var cursors: [String: Int] = [:]
    /// Total bytes ever appended (absolute end offset).
    private var written = 0

    init(id: String, command: String) {
        self.id = id
        self.command = command
        self.pty = PTY()
    }

    /// Launch on a fresh pty. `cols`/`rows` size the TTY (TUIs redraw to fit).
    func start(cwd: URL, environment: [String: String], cols: UInt16, rows: UInt16) -> Bool {
        let ok = pty.start(shell: "/bin/bash", arguments: ["-c", command], cwd: cwd,
                           cols: cols, rows: rows, environment: environment)
        if ok {
            pid = pty.pid
            pty.onOutput = { [weak self] chunk in self?.append(chunk) }
            pty.onExit = { [weak self] status in self?.lock.withLock { self?.exited = status } }
        }
        return ok
    }

    private func append(_ chunk: Data) {
        lock.withLock {
            buffer.append(chunk)
            written += chunk.count
            if buffer.count > ringLimit {
                let cut = buffer.count - ringLimit
                buffer.removeFirst(cut)
                dropped += cut
            }
        }
    }

    var isRunning: Bool { lock.withLock { exited == nil && pty.isRunning } }

    var exitStatus: Int32? { lock.withLock { exited } }

    func write(_ text: String) {
        pty.write(text)
    }

    func resize(cols: UInt16, rows: UInt16) { pty.resize(cols: cols, rows: rows) }

    /// TERM, then KILL. The pty's whole process group goes down together.
    func stop(kill: Bool) {
        if pid > 0 {
            kill_tree(kill ? SIGKILL : SIGTERM)
            if !kill {
                // Give handlers a beat, then make it final.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.kill_tree(SIGKILL)
                }
            }
        }
        pty.terminate()
    }

    private func kill_tree(_ signal: Int32) {
        guard pid > 0 else { return }
        Darwin.kill(-pid, signal)
        Darwin.kill(pid, signal)
    }

    /// Bytes a reader has not seen yet, advancing its cursor. `reader` is the
    /// tool-call id, so each call reads the stream exactly once. An unknown
    /// reader starts from "everything available now" if `fromEnd`, else from
    /// the oldest retained byte.
    func drain(reader: String, fromEnd: Bool = false) -> (text: String, status: Int32?, running: Bool) {
        lock.withLock {
            let end = dropped + buffer.count
            let start: Int
            if let cursor = cursors[reader] {
                start = min(max(cursor, dropped), end)
            } else {
                start = fromEnd ? end : dropped
            }
            cursors[reader] = end
            let skip = start - dropped
            let slice = buffer.dropFirst(skip)
            return (String(decoding: Data(slice), as: UTF8.self), exited, exited == nil && pty.isRunning)
        }
    }

    /// Whether output arrived since an absolute offset (for `until` polling).
    func tailSince(_ offset: Int) -> (text: String, end: Int, running: Bool) {
        lock.withLock {
            let end = dropped + buffer.count
            let start = min(max(offset, dropped), end)
            let slice = buffer.dropFirst(start - dropped)
            return (String(decoding: Data(slice), as: UTF8.self), end, exited == nil && pty.isRunning)
        }
    }

    /// Everything retained, without touching any cursor (`all: true`).
    func peekAll() -> String {
        lock.withLock { String(decoding: buffer, as: UTF8.self) }
    }

    /// Advance a reader's cursor without returning bytes (an `until` wait
    /// already reported what it saw; a later plain read must not repeat it).
    func consume(reader: String, to offset: Int) {
        lock.withLock {
            let end = dropped + buffer.count
            cursors[reader] = max(cursors[reader] ?? 0, min(offset, end))
        }
    }

    /// Absolute end offset right now (before a first read, use it to skip noise).
    var endOffset: Int { lock.withLock { dropped + buffer.count } }

    /// Where a reader's cursor currently sits (absolute), if it has read before.
    /// The `until` poll starts here so bytes printed *before* the call are not
    /// skipped and then silently consumed.
    func cursor(_ reader: String) -> Int? { lock.withLock { cursors[reader] } }

    func summaryLine() -> String {
        let age = Int(Date().timeIntervalSince(startedAt))
        if let status = exitStatus {
            return "\(id)  exited(\(status))  \(age)s ago  \(command.prefix(90))"
        }
        return "\(id)  running(pid \(pid))  \(age)s  \(command.prefix(90))"
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}

// MARK: - The registry of live processes

/// Shared across engines and subagents: a process started by the main agent is
// readable by a subagent, and survives engine rebuilds between turns.
public final class ProcessManager: @unchecked Sendable {
    public static let shared = ProcessManager()

    private let lock = NSLock()
    private var processes: [String: BackgroundProcess] = [:]
    private var nextID = 1
    /// Exited processes stay listed (readable) for this long, then are dropped.
    private let retention: TimeInterval = 30 * 60

    public init() {}

    public func start(command: String, cwd: URL, environment: [String: String] = [:],
                      cols: UInt16 = 160, rows: UInt16 = 50) -> BackgroundProcess? {
        let id: String = lock.withLock {
            let newID = "p\(nextID)"
            nextID += 1
            return newID
        }
        let process = BackgroundProcess(id: id, command: command)
        guard process.start(cwd: cwd, environment: environment, cols: cols, rows: rows) else {
            return nil
        }
        lock.withLock {
            pruneLocked()
            processes[id] = process
        }
        return process
    }

    public func get(_ id: String) -> BackgroundProcess? {
        lock.withLock { processes[id] }
    }

    public func all() -> [BackgroundProcess] {
        lock.withLock {
            pruneLocked()
            return processes.values.sorted { $0.startedAt < $1.startedAt }
        }
    }

    public func stop(_ id: String, kill: Bool) -> Bool {
        guard let process = get(id) else { return false }
        process.stop(kill: kill)
        return true
    }

    public func stopAll() {
        for process in all() { process.stop(kill: true) }
    }

    private func pruneLocked() {
        let now = Date()
        for (id, process) in processes {
            if let _ = process.exitStatus,
               now.timeIntervalSince(process.startedAt) > retention + 600 {
                processes.removeValue(forKey: id)
            }
        }
    }
}

// MARK: - Output hygiene

/// Terminal noise removal for text headed to the model: strip CSI/OSC/Osc
/// sequences and C0 controls except newline/tab. Cheap regex-free scanner —
/// this runs on every read of a chatty process.
public enum PTYText {
    public static func clean(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var iterator = raw.utf16.makeIterator()
        while let unit = iterator.next() {
            switch unit {
            case 0x1B: // ESC
                skipEscape(&iterator)
            case 0x07, 0x08: // bell, backspace
                break
            case 0x0D: // CR: keep raw — a line full of CRs is a spinner, collapsed below
                out.append("\r")
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
                break
            default:
                if let scalar = Unicode.Scalar(unit) { out.append(Character(scalar)) }
                // Surrogate pair: combine with the next unit.
                if (0xD800...0xDBFF).contains(unit), let low = iterator.next() {
                    let combined = (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00) + 0x10000
                    if let scalar = Unicode.Scalar(combined) { out.append(Character(scalar)) }
                }
            }
        }
        // Collapse progress-bar spam: many \r-split fragments per line.
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = lines.map { line in
            // Keep only the last fragment of CR-overwritten lines (spinners).
            if line.contains("\r") { return String(line.split(separator: "\r").last ?? "") }
            return line
        }
        // Collapse >2 blank runs.
        var collapsed: [String] = []
        var blanks = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blanks += 1
                if blanks > 2 { continue }
            } else {
                blanks = 0
            }
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n")
    }

    private static func skipEscape(_ iterator: inout String.UTF16View.Iterator) {
        guard let first = iterator.next() else { return }
        switch first {
        case 0x5B: // '[' — CSI: consume until a final byte @..~
            while let unit = iterator.next() {
                if (0x40...0x7E).contains(unit) { return }
            }
        case 0x5D: // ']' — OSC: consume until BEL or ST (ESC \)
            var previous: UInt16 = 0
            while let unit = iterator.next() {
                if unit == 0x07 { return }
                if previous == 0x1B && unit == 0x5C { return }
                previous = unit
            }
        case 0x50, 0x58, 0x1B: // D-, X-, nested ESC: consume to ST
            var previous: UInt16 = 0
            while let unit = iterator.next() {
                if previous == 0x1B && unit == 0x5C { return }
                previous = unit
            }
        default:
            return // two-char escapes like ESC=, ESCc end here
        }
    }
}

// MARK: - Tools

public struct ProcessStartTool: ToolExecutor {
    public static let name = "process_start"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Start a long-running process on its own pty and keep it alive between tool \
            calls — game engines, dev servers, REPLs, watchers, installers that ask \
            questions. Returns immediately with a process id; read its output with \
            process_read (which can wait for a line matching `until`), type into it with \
            process_write, end it with process_stop. Use this instead of run_shell_command \
            whenever the program must keep running while you work, or must respond to input.
            """,
        parameters: """
        {"type":"object","properties":{"command":{"type":"string","description":"The command to start"},"cwd":{"type":"string","description":"Working directory (default: project folder)"},"env":{"type":"object","additionalProperties":{"type":"string"},"description":"Extra environment variables"},"cols":{"type":"integer","description":"Terminal width (default 160)"},"rows":{"type":"integer","description":"Terminal height (default 50)"},"description":{"type":"string","description":"Short summary of what this process is for"}},"required":["command"]}
        """
    )

    public let manager: ProcessManager
    public init(manager: ProcessManager = .shared) { self.manager = manager }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let command = Self.string(args, "command"), !command.isEmpty else {
            return .init(output: "Error: command is required.")
        }
        var environment: [String: String] = [:]
        if let env = JSONArgs.dictionary(args)["env"] as? [String: Any] {
            for (key, value) in env { environment[key] = "\(value)" }
        }
        let cwdRaw = Self.string(args, "cwd")
        let cwd = context.policy.resolve(cwdRaw ?? ".").url
        let cols = UInt16(clamping: min(400, max(20, Self.int(args, "cols", default: 160))))
        let rows = UInt16(clamping: min(200, max(8, Self.int(args, "rows", default: 50))))

        guard let process = manager.start(command: command, cwd: cwd, environment: environment,
                                          cols: cols, rows: rows) else {
            return .init(output: "Error: could not start the process (forkpty failed).")
        }
        // What this chat starts is its own to control (a chat limited to its own apps may drive it).
        context.machine?.noteSpawned(pid: process.pid)
        // One shared "tool" cursor for the agent loop: whatever a read (or this
        // first-output peek) reported is consumed, so no bytes are ever sent
        // to the model twice — the token budget for a chatty process stays
        // proportional to what it newly prints.
        let reader = context.policy.preset == .plan ? "plan" : "tool"
        try? await Task.sleep(nanoseconds: 700_000_000)
        let (text, status, running) = process.drain(reader: reader)
        let cleaned = PTYText.clean(text)
        var out = "Started \(process.id) (pid \(process.pid)): \(command)"
        if running {
            out += "\nStill running. Read output with process_read(id:\"\(process.id)\") — use `until` to wait for a specific line — and send input with process_write."
        } else if let status {
            out += "\nIt already exited with code \(status)."
        }
        if !cleaned.isEmpty {
            let head = String(cleaned.prefix(2000))
            out += "\nFirst output:\n\(head)"
        }
        return .init(output: out)
    }
}

public struct ProcessReadTool: ToolExecutor {
    public static let name = "process_read"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Read everything a background process printed since your last read (per-call \
            cursor — you never see the same bytes twice). With `until`, poll for up to \
            `timeout` seconds until the new output contains that substring — the \
            efficient way to wait for "Godot Engine v", "ready to accept connections", \
            or a "SCRIPT ERROR" line instead of blindly re-reading. Reports exit status \
            when the process has ended.
            """,
        parameters: """
        {"type":"object","properties":{"id":{"type":"string","description":"Process id from process_start"},"until":{"type":"string","description":"Wait until the new output contains this text"},"timeout":{"type":"integer","description":"Max seconds to wait for `until` (default 20, max 120)"},"all":{"type":"boolean","description":"Also include output other readers already consumed"}},"required":["id"]}
        """
    )

    public let manager: ProcessManager
    public init(manager: ProcessManager = .shared) { self.manager = manager }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let id = Self.string(args, "id"),
              let process = manager.get(id) else {
            let listed = manager.all().map { "- \($0.summaryLine())" }.joined(separator: "\n")
            return .init(output: "Error: no such process\(listed.isEmpty ? "" : ". Live processes:\n\(listed)")")
        }
        let reader = context.policy.preset == .plan ? "plan" : "tool"

        if let until = Self.string(args, "until"), !until.isEmpty {
            let timeout = Double(min(120, max(1, Self.int(args, "timeout", default: 20))))
            let deadline = Date().addingTimeInterval(timeout)
            var baseline = process.cursor(reader) ?? process.tailSince(process.endOffset).end
            var collected = ""
            while Date() < deadline {
                let (chunk, end, running) = process.tailSince(baseline)
                baseline = end
                collected += chunk
                if PTYText.clean(collected).contains(until) {
                    process.consume(reader: reader, to: baseline)
                    return finish(process: process, id: id, raw: collected, matched: until)
                }
                if !running {
                    process.consume(reader: reader, to: baseline)
                    return finish(process: process, id: id, raw: collected, matched: nil)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let cleaned = PTYText.clean(collected)
            process.consume(reader: reader, to: baseline)
            return .init(output: """
                No line matching "\(until)" within \(Int(timeout))s of \(id).
                Output seen while waiting:
                \(Self.cap(cleaned))
                \(process.isRunning ? "It is still running — keep waiting with a longer timeout, or check whether it is stuck at a prompt (process_write may unblock it)." : "The process has exited.")
                """)
        }

        let raw: String
        if Self.bool(args, "all", default: false) {
            raw = process.peekAll()
        } else {
            raw = process.drain(reader: reader).text
        }
        return finish(process: process, id: id, raw: raw, matched: nil)
    }

    private func finish(process: BackgroundProcess, id: String, raw: String, matched: String?,
                        status: Int32? = nil, running: Bool? = nil) -> ToolResult {
        let cleaned = PTYText.clean(raw)
        let exit = status ?? process.exitStatus
        var head: [String] = []
        if let matched { head.append("Matched \"\(matched)\" from \(id).") }
        if let exit { head.append("\(id) exited with code \(exit).") }
        else if running == false || !process.isRunning { head.append("\(id) exited.") }
        let body = cleaned.isEmpty ? "(no new output)" : Self.cap(cleaned)
        return .init(output: (head.isEmpty ? "" : head.joined(separator: " ") + "\n") + body)
    }

    static func cap(_ s: String, limit: Int = 16_000) -> String {
        s.count > limit ? "… [truncated \(s.count - limit) chars] …\n" + String(s.suffix(limit)) : s
    }
}

public struct ProcessWriteTool: ToolExecutor {
    public static let name = "process_write"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Type into a background process: answer its prompts, drive a REPL, press keys \
            in a running game. `input` is sent verbatim (add your own \\n or use enter), \
            or send a named key with `keys`: enter, ctrl-c, ctrl-d, tab, esc, up, down, \
            left, right, pgup, pgdn. Reading what it printed back is a separate \
            process_read — pass `wait` to get a short settle before returning.
            """,
        parameters: """
        {"type":"object","properties":{"id":{"type":"string","description":"Process id"},"input":{"type":"string","description":"Text to type"},"keys":{"type":"array","items":{"type":"string"},"description":"Named keys/controls, e.g. ['ctrl-c'] or ['down','enter']"},"enter":{"type":"boolean","description":"Press Enter after input"},"wait":{"type":"integer","description":"Seconds to let it react before returning (default 1)"}},"required":["id"]}
        """
    )

    public let manager: ProcessManager
    public init(manager: ProcessManager = .shared) { self.manager = manager }

    /// The bytes a terminal sends for each key. Control keys are the ASCII
    /// control codes (ctrl-<letter> = letter & 0x1F): ^C 0x03, ^D 0x04, ^Z 0x1A.
    static let keyCodes: [String: String] = [
        "enter": "\u{0D}", "return": "\u{0D}", "ctrl-c": "\u{03}", "ctrl-d": "\u{04}",
        "ctrl-z": "\u{1A}", "tab": "\u{09}", "esc": "\u{1B}", "escape": "\u{1B}",
        "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
        "pgup": "\u{1B}[5~", "pgdn": "\u{1B}[6~", "home": "\u{1B}[H", "end": "\u{1B}[F",
    ]

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let id = Self.string(args, "id"),
              let process = manager.get(id) else {
            return .init(output: "Error: no such process '\(Self.string(args, "id") ?? "?")' — check process_list.")
        }
        guard process.isRunning else {
            return .init(output: "Error: \(id) already exited (code \(process.exitStatus ?? -1)). Start it again with process_start.")
        }
        let text = Self.string(args, "input") ?? ""
        var payload = text
        if Self.bool(args, "enter", default: false) { payload += "\u{0D}" }
        if let keys = JSONArgs.dictionary(args)["keys"] as? [Any] {
            for case let key as String in keys {
                guard let code = Self.keyCodes[key.lowercased()] else {
                    return .init(output: "Error: unknown key '\(key)'. Known: \(Self.keyCodes.keys.sorted().joined(separator: ", "))")
                }
                payload += code
            }
        }
        if payload.isEmpty { return .init(output: "Error: nothing to send — give input and/or keys.") }
        process.write(payload)

        let wait = Double(min(30, max(0, Self.int(args, "wait", default: 1))))
        // A short settle so the model's next process_read usually sees the
        // reaction. Deliberately does NOT touch the read cursor: the output
        // this input caused belongs to the read, not to this call.
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        let state = process.isRunning ? "running" : "exited(\(process.exitStatus ?? -1))"
        let sent = text.isEmpty ? keysDescription(args) : "\"\(text.prefix(80))\""
        return .init(output: "Sent \(sent) to \(id); it is \(state). Next: process_read(id:\"\(id)\") — with `until` if you are waiting for a specific line.")
    }

    private func keysDescription(_ args: JSONString) -> String {
        guard let keys = JSONArgs.dictionary(args)["keys"] as? [String] else { return "input" }
        return keys.joined(separator: "+")
    }
}

public struct ProcessStopTool: ToolExecutor {
    public static let name = "process_stop"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Stop a background process: SIGTERM, then SIGKILL if it ignores it (`force`). \
            The whole process group dies, so a game engine takes its helper processes too.
            """,
        parameters: """
        {"type":"object","properties":{"id":{"type":"string","description":"Process id"},"force":{"type":"boolean","description":"SIGKILL immediately instead of SIGTERM first"}},"required":["id"]}
        """
    )

    public let manager: ProcessManager
    public init(manager: ProcessManager = .shared) { self.manager = manager }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let id = Self.string(args, "id") else {
            return .init(output: "Error: id is required.")
        }
        guard manager.stop(id, kill: Self.bool(args, "force", default: false)) else {
            return .init(output: "Error: no such process '\(id)'.")
        }
        return .init(output: "Stopped \(id).")
    }
}

public struct ProcessListTool: ToolExecutor {
    public static let name = "process_list"
    public static let spec = ToolSpec(
        name: name,
        description: "List background processes: id, state, pid, age, command. Use it to recover ids after a break or in a subagent.",
        parameters: """
        {"type":"object","properties":{}}
        """
    )

    public let manager: ProcessManager
    public init(manager: ProcessManager = .shared) { self.manager = manager }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let all = manager.all()
        if all.isEmpty { return .init(output: "No background processes.") }
        let lines = all.map { "- \($0.summaryLine())" }.joined(separator: "\n")
        return .init(output: "Background processes:\n\(lines)")
    }
}
