import Foundation
import Darwin

// MARK: - Running one turn on Claude Code
//
// `ClaudeCodeTurn.run` starts `claude -p` in the chat's folder, writes the prompt to it as one stream-json user
// message, turns every line it prints into Vision events as it arrives (`ClaudeCodeStreamParser`), and says how the
// turn ended. Stop (cancelling the task) sends the CLI SIGINT — Claude Code's own "end the turn" — then SIGTERM and
// SIGKILL if it doesn't go, so the session stays resumable and nothing it started is left running.

/// How the process ended.
public struct ClaudeCodeExit: Sendable, Equatable {
    public var exitCode: Int32
    /// The end of what it wrote to standard error.
    public var stderr: String
    /// Stopped by Vision (the person pressed Stop).
    public var interrupted: Bool

    public init(exitCode: Int32, stderr: String = "", interrupted: Bool = false) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.interrupted = interrupted
    }
}

/// Starts the CLI for one turn. Cancelling the calling task stops the CLI (`ClaudeCodeExit.interrupted`); only a
/// program that can't start throws.
public protocol ClaudeCodeLauncher: Sendable {
    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                input: Data, onLine: @escaping @Sendable (String) -> Void) async throws -> ClaudeCodeExit
}

/// The plain-language failures of a turn.
public enum ClaudeCodeError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled(String)
    case couldNotStart(String)
    case notSignedIn
    /// The Claude plan's usage limit (or billing) stopped the turn; the CLI's words.
    case usageLimit(String)
    /// `--resume` named a session Claude Code no longer has.
    case sessionNotFound
    /// `--session-id` named a session that already exists.
    case sessionInUse
    case sensitiveChat
    case failed(String)

    /// Another try can't fix it without the person (install, sign in, wait for the plan, change the chat).
    public var isPermanent: Bool {
        switch self {
        case .notInstalled, .couldNotStart, .notSignedIn, .usageLimit, .sensitiveChat: true
        case .sessionNotFound, .sessionInUse, .failed: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let why): why
        case .couldNotStart(let why): "Couldn't start Claude Code: \(why)"
        case .notSignedIn:
            "Claude Code isn't signed in on this Mac. In Terminal, run `claude auth login` (or run `claude` and type /login) and sign in with your Claude Pro or Max account, then send again. Vision never handles your Claude sign-in."
        case .usageLimit(let words):
            "Claude Code stopped: your Claude plan's usage limit is reached (\(words)). It resets on your plan's schedule — or pick another model for this chat."
        case .sessionNotFound: "Claude Code no longer has this chat's conversation."
        case .sessionInUse: "Claude Code already has a conversation with this chat's id."
        case .sensitiveChat: ClaudeCodeTurn.sensitiveRefusal
        case .failed(let why): why
        }
    }
}

/// What a finished (or stopped) turn left behind.
public struct ClaudeCodeTurnOutcome: Sendable {
    /// The Claude Code session the turn ran in (resume it next time).
    public var sessionID: String
    /// The model answered: the session exists and can be resumed.
    public var reachedModel: Bool
    public var result: ClaudeCodeResult?
    /// The final reply, or the last text written when the turn stopped early.
    public var lastReplyText: String
    public var contextTokens: Int?
    public var model: String?
    public var apiKeySource: String?
    public var interrupted: Bool
    public var denials: [ClaudeCodeDenial]
    /// Why the turn failed (nil: it finished, stopped at its step limit, or was stopped).
    public var failure: ClaudeCodeError?
    /// One line per tool call the turn made (`ClaudeCodeStreamParser.toolLog`).
    public var toolLog: [String] = []

    public var hitTurnLimit: Bool { result?.hitTurnLimit ?? false }
}

public enum ClaudeCodeTurn {
    /// Why a Sensitive chat can't use Claude Code — word for word what the sensitivity policy (item 20) says for an
    /// engine that reads files itself, so the refusal reads the same whichever check meets it first.
    public static let sensitiveRefusal = "This chat is Sensitive. Claude Code reads your files itself and sends them to its own service, so the sensitive-data shield can't mask anything on the way. Sensitive chats can't use it — choose a private model (your own hardware, Guardian, Amazon Bedrock in your AWS account), or turn Sensitive off for this chat."

    /// Added after Claude Code's own system prompt on every turn.
    public static let visionNote = """
        You are running inside Vision, a desktop agent harness, as the engine of one of its chats. The person reads \
        your replies and tool calls in Vision's chat window, not in a terminal. Some messages start with earlier \
        messages of this Vision chat that ran on another model; treat those as context you already have. When a \
        message asks you to end with a marker such as GOAL_COMPLETE or GOAL_BLOCKED, put it on its own line at the \
        very end of your reply.
        """

    /// Run one turn. Events arrive on the launcher's reading queue, in order. A turn that failed returns with
    /// `failure` set and a stopped one with `interrupted` — either way with what it did (the session it ran in, the
    /// text it wrote); only a CLI that can't start throws (`ClaudeCodeError.couldNotStart`).
    public static func run(install: ClaudeCodeInstall, invocation: ClaudeCodeInvocation, prompt: String,
                           images: [ClaudeCodeImage] = [], workspace: URL, environment: [String: String],
                           launcher: any ClaudeCodeLauncher,
                           onEvent: @escaping @Sendable (ClaudeCodeEvent) -> Void) async throws -> ClaudeCodeTurnOutcome {
        let parser = LockedParser(ClaudeCodeStreamParser(workspace: workspace))
        let exit: ClaudeCodeExit
        do {
            exit = try await launcher.launch(executable: install.path, arguments: invocation.arguments(for: install),
                                             environment: environment, workingDirectory: workspace,
                                             input: ClaudeCodeInput.line(text: prompt, images: images)) { line in
                for event in parser.consume(line) { onEvent(event) }
            }
        } catch {
            throw ClaudeCodeError.couldNotStart(error.localizedDescription)
        }
        for event in parser.finish() { onEvent(event) }
        let state = parser.snapshot()
        let chosen = invocation.session?.id ?? ""
        return ClaudeCodeTurnOutcome(sessionID: state.sessionID ?? chosen, reachedModel: state.reachedModel,
                                     result: state.result, lastReplyText: state.lastReplyText,
                                     contextTokens: state.contextTokens, model: state.model,
                                     apiKeySource: state.apiKeySource, interrupted: exit.interrupted,
                                     denials: state.result?.denials ?? state.denials,
                                     failure: exit.interrupted ? nil : failure(result: state.result, apiError: state.apiError, exit: exit),
                                     toolLog: state.toolLog)
    }

    /// What went wrong, or nil for a turn that ended well (or at its step limit).
    static func failure(result: ClaudeCodeResult?, apiError: (category: String, text: String)?, exit: ClaudeCodeExit) -> ClaudeCodeError? {
        let words = [result?.text ?? "", apiError?.text ?? "", exit.stderr].joined(separator: "\n")
        let lower = words.lowercased()
        if apiError?.category == "authentication_failed" || lower.contains("not logged in") || lower.contains("please run /login")
            || lower.contains("invalid api key") || lower.contains("oauth token has expired") {
            return .notSignedIn
        }
        guard let result else {
            if lower.contains("no conversation found") { return .sessionNotFound }
            if lower.contains("already in use") { return .sessionInUse }
            let tail = exit.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: " ")
            return .failed("Claude Code stopped without finishing (exit code \(exit.exitCode))" + (tail.isEmpty ? "." : ": \(tail)"))
        }
        guard result.isError, !result.hitTurnLimit else { return nil }
        if ["rate_limit", "billing_error"].contains(apiError?.category ?? "") || lower.contains("usage limit")
            || lower.contains("hit your limit") || lower.contains("limit reached") {
            let detail = (result.text.isEmpty ? apiError?.text ?? "" : result.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return .usageLimit(detail.isEmpty ? "limit reached" : String(detail.prefix(200)))
        }
        let detail = ([result.text] + result.errors + [apiError?.text ?? ""])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.first
        return .failed("Claude Code reported an error" + (detail.map { ": \(String($0.prefix(400)))" } ?? " (\(result.subtype))."))
    }

    /// The parser behind a lock: lines arrive on the launcher's queue, the snapshot is read after the run.
    final class LockedParser: @unchecked Sendable {
        private let lock = NSLock()
        private let parser: ClaudeCodeStreamParser
        init(_ parser: ClaudeCodeStreamParser) { self.parser = parser }

        func consume(_ line: String) -> [ClaudeCodeEvent] { lock.withLock { parser.consume(line) } }
        func finish() -> [ClaudeCodeEvent] { lock.withLock { parser.finish() } }

        struct Snapshot: Sendable {
            var sessionID: String?
            var reachedModel: Bool
            var result: ClaudeCodeResult?
            var lastReplyText: String
            var contextTokens: Int?
            var model: String?
            var apiKeySource: String?
            var apiError: (category: String, text: String)?
            var denials: [ClaudeCodeDenial]
            var toolLog: [String]
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(sessionID: parser.sessionID, reachedModel: parser.reachedModel, result: parser.result,
                         lastReplyText: parser.lastReplyText, contextTokens: parser.contextTokens, model: parser.model,
                         apiKeySource: parser.apiKeySource, apiError: parser.apiError, denials: parser.denials,
                         toolLog: parser.toolLog)
            }
        }
    }

    // MARK: Cost

    /// This turn's cost at API prices. From Claude Code 2.1.277 a resumed session's `total_cost_usd` is the
    /// session's running total, so the turn's share is the difference from the last one seen.
    public static func turnCost(total: Double?, previousTotal: Double?, resumed: Bool, version: String?) -> Double? {
        guard let total else { return nil }
        let cumulative = resumed && version.map { ClaudeCodeLocator.compareVersions($0, "2.1.277") != .orderedAscending } == true
        guard cumulative, let previousTotal, total >= previousTotal else { return total }
        return total - previousTotal
    }

    /// "≈ $0.42" (more digits under a cent).
    public static func formatCost(_ usd: Double) -> String {
        usd >= 0.01 || usd == 0 ? String(format: "≈ $%.2f", usd) : String(format: "≈ $%.4f", usd)
    }

    /// The line under a finished turn: model, steps, tokens and the cost at API prices — and who pays.
    public static func usageLine(model: String?, result: ClaudeCodeResult, cost: Double?, apiKeySource: String?) -> String {
        var parts = ["Claude Code" + (model.map { " · \($0)" } ?? "")]
        if result.numTurns > 0 { parts.append("\(result.numTurns) step\(result.numTurns == 1 ? "" : "s")") }
        if let usage = result.usage {
            parts.append("\(usage.promptTokens.formatted()) in · \(usage.completionTokens.formatted()) out")
        }
        if let durationMs = result.durationMs, durationMs > 0 {
            let seconds = Double(durationMs) / 1000
            parts.append(seconds < 60 ? String(format: "%.0fs", seconds) : String(format: "%.1f min", seconds / 60))
        }
        var line = parts.joined(separator: " · ")
        if let cost {
            let paysWithKey = !(apiKeySource ?? "none").isEmpty && (apiKeySource ?? "none") != "none"
            line += " · \(formatCost(cost)) at API prices" + (paysWithKey ? " (billed to your API key)" : " (your Claude plan covers it)")
        }
        return line
    }

    /// The reply as other models are given it: Claude Code's text, then a short account of its tool work (capped),
    /// so a chat that moves to another model knows what changed.
    public static func transcriptReply(_ reply: String, toolLog: [String], limit: Int = 1_500) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(Claude Code worked on this without a written reply.)" : reply
        guard !toolLog.isEmpty else { return text }
        var lines: [String] = []
        var used = 0
        for line in toolLog {
            if used + line.count > limit { lines.append("… and \(toolLog.count - lines.count) more"); break }
            lines.append(line)
            used += line.count
        }
        return text + "\n\n[Claude Code's tool work this turn: " + lines.joined(separator: "; ") + "]"
    }

    /// The note about tool calls the chat's permission setting refused ("Bash ×2"), or nil.
    public static func denialNote(_ denials: [ClaudeCodeDenial], preset: PermissionPreset) -> String? {
        guard !denials.isEmpty else { return nil }
        var counts: [(String, Int)] = []
        for denial in denials {
            if let index = counts.firstIndex(where: { $0.0 == denial.toolName }) { counts[index].1 += 1 }
            else { counts.append((denial.toolName, 1)) }
        }
        let list = counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
        let n = denials.count
        let head = "Claude Code was refused \(n) tool call\(n == 1 ? "" : "s") (\(list)) — "
        switch preset {
        case .plan: return head + "this chat is Plan only, so it can read and plan but not change anything."
        case .workspaceWrite: return head + "this chat's permission setting doesn't let it run that unattended. Switch the chat to Full access to let it."
        case .fullAccess: return head + "edits outside the chat's folder and tools that need a person's approval stay off in Vision."
        }
    }
}

// MARK: - Earlier messages for a Claude Code session that hasn't seen them

/// One message of the chat as plain text, for the recap.
public struct ClaudeCodeRecapItem: Sendable, Equatable {
    public enum Role: String, Sendable { case person, assistant, tool }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public enum ClaudeCodeRecap {
    /// The longest recap, in characters (the newest messages are kept).
    public static let maxCharacters = 24_000
    static let maxPerMessage = 4_000

    /// Messages of this Vision chat that Claude Code's session hasn't seen (they ran on another model, or before
    /// this chat moved to Claude Code), as a preface to the new message; nil when there are none.
    public static func preface(_ items: [ClaudeCodeRecapItem]) -> String? {
        var lines: [String] = []
        var used = 0
        var dropped = 0
        for item in items.reversed() {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let body = text.count > maxPerMessage ? String(text.prefix(maxPerMessage)) + " …(cut)" : text
            let label: String
            switch item.role {
            case .person: label = "Person"
            case .assistant: label = "Assistant"
            case .tool: label = "Tool activity"
            }
            let line = "\(label): \(body)"
            if used + line.count > maxCharacters, !lines.isEmpty { dropped += 1; continue }
            lines.append(line)
            used += line.count
        }
        guard !lines.isEmpty else { return nil }
        let head = "[Earlier in this Vision chat — messages you haven't seen (they ran on another model). Read them as context, then answer the new message below."
            + (dropped > 0 ? " \(dropped) older message\(dropped == 1 ? " was" : "s were") left out." : "") + "]"
        return head + "\n\n" + lines.reversed().joined(separator: "\n\n") + "\n\n[End of earlier messages. The new message:]\n\n"
    }
}

// MARK: - The real launcher

/// Starts the real `claude` with pipes for standard input, output and error. No shell: the arguments go to the
/// program as they are.
public struct ProcessClaudeCodeLauncher: ClaudeCodeLauncher {
    /// SIGINT → SIGTERM, and SIGTERM → SIGKILL, in seconds.
    public var interruptGrace: TimeInterval
    public var killGrace: TimeInterval

    public init(interruptGrace: TimeInterval = 5, killGrace: TimeInterval = 3) {
        self.interruptGrace = interruptGrace
        self.killGrace = killGrace
    }

    public func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                       input: Data, onLine: @escaping @Sendable (String) -> Void) async throws -> ClaudeCodeExit {
        let run = ClaudeCodeProcessRun(executable: executable, arguments: arguments, environment: environment,
                                       workingDirectory: workingDirectory, input: input, onLine: onLine,
                                       interruptGrace: interruptGrace, killGrace: killGrace)
        return try await withTaskCancellationHandler {
            try await run.execute()
        } onCancel: {
            run.interrupt()
        }
    }
}

/// One run of the CLI. `interrupt()` may come from any thread at any time, before the child exists too.
final class ClaudeCodeProcessRun: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let input: Data
    private let onLine: @Sendable (String) -> Void
    private let interruptGrace: TimeInterval
    private let killGrace: TimeInterval

    private let lock = NSLock()
    private var pid: pid_t = 0
    /// The CLI leads its own process group (what Foundation's Process does), so the group can be killed.
    private var leadsGroup = false
    private var started = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var interrupted = false
    private var lineBuffer = Data()
    private var stderrTail = Data()
    private let exitGate = AWSCLIGate()
    private let outClosed = AWSCLIGate()
    private let errClosed = AWSCLIGate()

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL, input: Data,
         onLine: @escaping @Sendable (String) -> Void, interruptGrace: TimeInterval, killGrace: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
        self.onLine = onLine
        self.interruptGrace = interruptGrace
        self.killGrace = killGrace
    }

    func execute() async throws -> ClaudeCodeExit {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClaudeCodeError.couldNotStart("\(executable) isn't an executable file.")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = workingDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let code = finished.terminationReason == .uncaughtSignal ? 128 + finished.terminationStatus : finished.terminationStatus
            self.lock.withLock {
                self.exited = true
                self.exitCode = code
            }
            self.exitGate.open()
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.flushLine()
                self.outClosed.open()
            } else {
                self.consume(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.errClosed.open()
            } else {
                self.lock.withLock {
                    self.stderrTail.append(chunk)
                    if self.stderrTail.count > 65_536 { self.stderrTail = self.stderrTail.suffix(32_768) }
                }
            }
        }
        do {
            try await Self.spawn(child)
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ClaudeCodeError.couldNotStart(error.localizedDescription)
        }
        let childPID = child.processIdentifier
        let ownGroup = getpgid(childPID) == childPID
        let interruptNow: Bool = lock.withLock {
            pid = childPID
            leadsGroup = ownGroup
            started = true
            return interrupted
        }
        if interruptNow { signalInterrupt() }

        // The prompt, then end of input (off this thread: a big paste fills the pipe until the CLI reads it).
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let payload = input
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: payload)
            try? writer.close()
        }

        await exitGate.wait()
        // The last lines may still be in the pipe; a grandchild holding it open is only waited for briefly.
        await outClosed.wait(upTo: 5)
        await errClosed.wait(upTo: 1)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        flushLine()
        return lock.withLock {
            ClaudeCodeExit(exitCode: exitCode, stderr: String(decoding: stderrTail, as: UTF8.self), interrupted: interrupted)
        }
    }

    // MARK: Output

    private func consume(_ chunk: Data) {
        var lines: [String] = []
        lock.withLock {
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<newline]
                lines.append(String(decoding: line, as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            }
        }
        for line in lines { onLine(line) }
    }

    private func flushLine() {
        let last: String? = lock.withLock {
            guard !lineBuffer.isEmpty else { return nil }
            defer { lineBuffer.removeAll() }
            return String(decoding: lineBuffer, as: UTF8.self)
        }
        if let last { onLine(last) }
    }

    // MARK: Stopping

    /// Stop the turn: SIGINT (Claude Code ends the turn and keeps the session), SIGTERM after the grace period,
    /// then SIGKILL for the CLI and anything left in its process group.
    func interrupt() {
        let running: Bool = lock.withLock {
            guard !interrupted else { return false }
            interrupted = true
            return started && !exited
        }
        if running { signalInterrupt() }
    }

    private func signalInterrupt() {
        let (target, group): (pid_t, Bool) = lock.withLock { (pid, leadsGroup) }
        guard target > 1 else { return }
        kill(target, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptGrace) { [weak self] in
            guard let self, self.lock.withLock({ !self.exited }) else { return }
            kill(target, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + self.killGrace) { [weak self] in
                guard let self else { return }
                if self.lock.withLock({ !self.exited }) { kill(target, SIGKILL) }
                // Only a group the CLI leads itself: kill(-0) would be Vision's own group.
                if group { kill(-target, SIGKILL) }
            }
        }
    }

    private struct Spawned: @unchecked Sendable { let process: Process }

    /// Start it on a dispatch thread: the first launch of a big, freshly installed executable can take a moment.
    private static func spawn(_ child: Process) async throws {
        let spawned = Spawned(process: child)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global().async {
                do {
                    try spawned.process.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - A chat's link to its Claude Code session

/// What a Vision chat remembers about its Claude Code conversation (stored with the chat as `claudeCode`).
public struct ClaudeCodeLink: Codable, Hashable, Sendable {
    /// The Claude Code session id (a UUID).
    public var sessionID: String
    /// The session exists in Claude Code (a turn reached the model): the next turn resumes it.
    public var started: Bool
    /// When the session last caught up with the chat: messages after this (on other models) go to it as a recap.
    public var syncedAt: Date?
    /// The session's running cost total at the last turn (Claude Code 2.1.277+ reports totals per session).
    public var lastTotalCostUSD: Double?

    public init(sessionID: String, started: Bool = false, syncedAt: Date? = nil, lastTotalCostUSD: Double? = nil) {
        self.sessionID = sessionID
        self.started = started
        self.syncedAt = syncedAt
        self.lastTotalCostUSD = lastTotalCostUSD
    }

    /// The session a turn uses: resume one that exists, else start one under a new id.
    public static func choice(for link: ClaudeCodeLink?, newID: () -> String = { UUID().uuidString.lowercased() }) -> ClaudeCodeSessionChoice {
        if let link, link.started, !link.sessionID.isEmpty { return .resume(link.sessionID) }
        return .new(newID())
    }
}
