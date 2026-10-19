import Foundation
import Darwin

// MARK: - Running one turn on Claude Code
//
// `ClaudeCodeTurn.run` starts `claude -p` in the chat's folder, writes the prompt as one stream-json user message and
// keeps standard input open: every line Claude Code prints becomes Vision events as it arrives
// (`ClaudeCodeStreamParser`), each permission question is answered on stdin (`decide`, which may ask the person), and
// once the turn's result is in, stdin is closed so Claude Code finishes (and any background work it waits for) and
// exits. Stop (cancelling the task) sends Claude Code's own `interrupt` control request, then kills the process if it
// hasn't ended after 8 seconds. The same flow as Vision for Windows (ClaudeCodeRunner.cs).

/// The running CLI's standard input, for the turn to write to while it runs.
public protocol ClaudeCodeChannel: AnyObject, Sendable {
    /// Write one JSON line (the newline is added). Ignored once input is closed.
    func send(_ line: String)
    /// Close standard input: Claude Code finishes what it is doing and exits.
    func closeInput()
    var inputClosed: Bool { get }
}

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

/// Starts the CLI for one turn: `input` is written first and stdin stays open; every stdout line goes to `onLine` with
/// the channel to answer on. Cancelling the calling task stops the turn — `interrupt()`'s line while stdin is open,
/// then the process is killed after the grace period — and returns with `interrupted`. Only a program that can't start
/// throws.
public protocol ClaudeCodeLauncher: Sendable {
    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                input: String, interrupt: @escaping @Sendable () -> String,
                onLine: @escaping @Sendable (String, any ClaudeCodeChannel) -> Void) async throws -> ClaudeCodeExit
}

/// The plain-language failures of a turn (the same words as Vision for Windows).
public enum ClaudeCodeError: Error, LocalizedError, Equatable, Sendable {
    /// Not found (the status summary and where to look).
    case notInstalled(String)
    case couldNotStart(String)
    case notSignedIn
    /// The Claude plan's limit is used up for now (the whole sentence).
    case rateLimited(String)
    /// `--resume` named a session Claude Code no longer has.
    case sessionNotFound
    /// `--session-id` named a session that already exists.
    case sessionInUse
    case sensitiveChat
    /// The folder has Claude Code settings of its own that this CLI can't leave out (the whole sentence).
    case untrustedFolder(String)
    case failed(String)

    /// Another try can't fix it without the person (install, sign in, wait for the plan, change the chat).
    public var isPermanent: Bool {
        switch self {
        case .notInstalled, .couldNotStart, .notSignedIn, .rateLimited, .sensitiveChat, .untrustedFolder: true
        case .sessionNotFound, .sessionInUse, .failed: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let why): why
        case .couldNotStart(let why): "Couldn't start Claude Code: \(why)"
        case .notSignedIn:
            "Claude Code isn't signed in on this computer. Open a terminal, run  claude auth login  (choose your Claude account), then send again."
        case .rateLimited(let sentence): sentence
        case .sessionNotFound: "Claude Code no longer has this chat's session."
        case .sessionInUse: "Claude Code already has a session with this chat's id."
        case .sensitiveChat: ClaudeCodeTurn.sensitiveRefusal
        case .untrustedFolder(let why): why
        case .failed(let why): why
        }
    }
}

/// What a finished (or stopped) turn left behind.
public struct ClaudeCodeTurnOutcome: Sendable {
    /// The Claude Code session the turn ran in (carry it on next time); nil when the CLI never said.
    public var sessionID: String?
    /// Something happened beyond the prompt: a reply, a tool call.
    public var progressed: Bool
    /// The last result line.
    public var result: ClaudeCodeResult?
    /// Every result's tokens (background work can add turns after the first result).
    public var usage: LLMUsage?
    /// The last thing the main conversation said.
    public var lastReplyText: String
    public var contextTokens: Int?
    /// The model the alias resolved to ("claude-sonnet-5-5").
    public var model: String?
    public var apiKeySource: String?
    public var interrupted: Bool
    /// Why the turn failed (nil: it finished, or was stopped).
    public var failure: ClaudeCodeError?
    /// The plan's usage limit, when Claude Code reported one (its reset time keeps a subagent server paused).
    public var rateLimit: ClaudeCodeRateLimit? = nil
}

public enum ClaudeCodeTurn {
    /// Why a Sensitive chat can't use Claude Code — word for word what the sensitivity policy (item 20) says for an
    /// engine that reads files itself, so the refusal reads the same whichever check meets it first.
    public static let sensitiveRefusal = "This chat is Sensitive. Claude Code reads your files itself and sends them to its own service, so the sensitive-data shield can't mask anything on the way. Sensitive chats can't use it — choose a private model (your own hardware, Guardian, Amazon Bedrock in your AWS account), or turn Sensitive off for this chat."

    /// The note every Claude Code session gets once (its system prompt is recorded on the first turn and reused, so it
    /// says only what holds for every turn).
    public static let systemNote = "You are running inside Vision, a desktop agent harness, for one of the person's chats: they see your replies, tool calls, plans and todo lists there, and answer your permission requests in Vision. When a message asks you to end with GOAL_COMPLETE or GOAL_BLOCKED, write that marker alone on the last line of your reply — Vision's goal_complete and goal_blocked tools don't exist here."

    /// What a /goal round adds to its message on Claude Code.
    public static let goalNote = "(Vision note: you are Claude Code here — the goal_complete and goal_blocked tools aren't available. When the goal is fully done and verified, end your reply with a line containing exactly GOAL_COMPLETE; if only the person can unblock you, end with a line GOAL_BLOCKED: <what you need>.)"

    /// How long a Stop waits for Claude Code to end the turn itself before the process is killed.
    public static let interruptGrace: TimeInterval = 8

    /// Run one turn. Events arrive on the launcher's reading queue, in order; `decide` answers each permission
    /// question (it may wait for the person). A turn that failed returns with `failure` set and a stopped one with
    /// `interrupted` — either way with what it did; only a CLI that can't start throws (`couldNotStart`).
    public static func run(install: ClaudeCodeInstall, invocation: ClaudeCodeInvocation, message: String,
                           workspace: URL, environment: [String: String], launcher: any ClaudeCodeLauncher,
                           decide: @escaping @Sendable (ClaudeCodePermissionRequest) async -> ClaudeCodePermissionDecision,
                           onEvent: @escaping @Sendable (ClaudeCodeEvent) -> Void) async throws -> ClaudeCodeTurnOutcome {
        let parser = LockedParser(ClaudeCodeStreamParser(workspace: workspace))
        // Questions still waiting for an answer (the person's card): cancelled — and so answered no, card gone — once
        // their answer can no longer reach Claude Code.
        let pending = PendingDecisions()
        let exit: ClaudeCodeExit
        do {
            exit = try await launcher.launch(
                executable: install.path, arguments: invocation.arguments(for: install), environment: environment,
                workingDirectory: workspace, input: message,
                interrupt: { ClaudeCodeInput.interrupt(requestID: "vision-stop-" + String(UUID().uuidString.lowercased().prefix(8))) }
            ) { line, channel in
                let (events, firstResult) = parser.consume(line)
                for event in events {
                    switch event {
                    case .permission(let request):
                        // Standard input is closed (the reply is in): no answer could reach it, so nobody is asked.
                        guard !channel.inputClosed, !pending.isClosed else { continue }
                        pending.start {
                            let decision = await decide(request)
                            switch decision {
                            case .allow:
                                channel.send(ClaudeCodeInput.allow(requestID: request.requestID, input: request.input, toolUseID: request.toolUseID))
                            case .deny(let message):
                                channel.send(ClaudeCodeInput.deny(requestID: request.requestID, message: message, toolUseID: request.toolUseID))
                            case .ask:
                                channel.send(ClaudeCodeInput.deny(requestID: request.requestID, message: ClaudeCodePermissions.declined,
                                                                  toolUseID: request.toolUseID))
                            }
                        }
                    case .unhandledControl(let requestID, let subtype):
                        channel.send(ClaudeCodeInput.unhandled(requestID: requestID, subtype: subtype))
                    default:
                        onEvent(event)
                    }
                }
                // The reply is in: let it finish (and wait for any background work it started) and exit.
                if firstResult {
                    channel.closeInput()
                    pending.cancelAll()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if !parser.ended { onEvent(.activity("Claude Code is finishing work it started in the background…")) }
                    }
                }
            }
        } catch {
            await pending.finish()
            throw ClaudeCodeError.couldNotStart(error.localizedDescription)
        }
        // The process is gone: a question still up can never be answered — take its card down before returning.
        await pending.finish()
        parser.end()
        for event in parser.finish() { onEvent(event) }
        for event in parser.closeDangling(exit.interrupted ? "Stopped before it finished" : "Not finished — Claude Code ended the turn first") {
            onEvent(event)
        }
        let state = parser.snapshot()
        return ClaudeCodeTurnOutcome(sessionID: state.sessionID, progressed: state.progressed, result: state.result,
                                     usage: state.usage, lastReplyText: state.lastReplyText, contextTokens: state.contextTokens,
                                     model: state.model, apiKeySource: state.apiKeySource, interrupted: exit.interrupted,
                                     failure: exit.interrupted ? nil : failure(state, exit: exit), rateLimit: state.rateLimit)
    }

    /// Why a turn failed, in plain words — or nil when it finished.
    static func failure(_ state: LockedParser.Snapshot, exit: ClaudeCodeExit) -> ClaudeCodeError? {
        let result = state.result
        if let result, !result.isError { return nil }
        let said = ([state.apiError?.text, result?.text] + (result?.errors ?? []).map { Optional($0) })
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        let everything = (said + "\n" + exit.stderr + "\n" + state.unparsed).lowercased()
        if state.apiError?.category == "authentication_failed" || everything.contains("not logged in")
            || everything.contains("please run /login") {
            return .notSignedIn
        }
        if everything.contains("no conversation found with session id") { return .sessionNotFound }
        if everything.contains("is already in use") { return .sessionInUse }
        if state.rateLimit != nil || (state.apiError?.category == "rate_limit" && said.lowercased().contains("limit")) {
            let words = state.rateLimit.map { "your Claude plan's \($0.typeWords) limit\($0.resetWords())" } ?? "your Claude plan's usage limit"
            return .rateLimited("You've reached \(words). Pick another model for this chat from the model menu, or send again once it resets.")
        }
        guard let result else {
            let why = firstLines(exit.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? state.unparsed : exit.stderr)
            return .failed(why.isEmpty ? "Claude Code stopped without answering (exit code \(exit.exitCode))."
                                       : "Claude Code stopped without answering: \(why)")
        }
        switch result.subtype {
        case "error_max_turns":
            return .failed("Claude Code stopped: it reached its limit of steps for one turn. Send “keep going” to carry on.")
        case "error_max_budget_usd":
            return .failed("Claude Code stopped: it reached the spending cap for this turn.")
        default:
            return .failed(said.isEmpty ? "Claude Code ended the turn with an error." : "Claude Code: \(firstLines(said))")
        }
    }

    static func firstLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
        return ClaudeCodeTools.prefix(lines.joined(separator: " "), 400)
    }

    /// The permission questions of one turn being decided (each may wait for the person). Once their answers can't
    /// be delivered — standard input closed, the process gone — they are cancelled, which answers a waiting card no.
    final class PendingDecisions: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var closed = false

        func start(_ work: @escaping @Sendable () async -> Void) {
            let task = Task { await work() }
            let late: Bool = lock.withLock {
                if closed { return true }
                tasks.append(task)
                return false
            }
            if late { task.cancel() }
        }

        /// No more answers can be delivered.
        var isClosed: Bool { lock.withLock { closed } }

        func cancelAll() {
            let all: [Task<Void, Never>] = lock.withLock {
                closed = true
                return tasks
            }
            all.forEach { $0.cancel() }
        }

        /// Cancel what is left and wait until each has answered.
        func finish() async {
            cancelAll()
            for task in lock.withLock({ tasks }) { await task.value }
        }
    }

    /// The parser behind a lock: lines arrive on the launcher's queue, the snapshot is read after the run.
    final class LockedParser: @unchecked Sendable {
        private let lock = NSLock()
        private let parser: ClaudeCodeStreamParser
        private var isEnded = false
        init(_ parser: ClaudeCodeStreamParser) { self.parser = parser }

        /// The line's events, and whether it was the turn's first result.
        func consume(_ line: String) -> ([ClaudeCodeEvent], Bool) {
            lock.withLock {
                let before = parser.results
                let events = parser.consume(line)
                return (events, before == 0 && parser.results == 1)
            }
        }
        func finish() -> [ClaudeCodeEvent] { lock.withLock { parser.finish() } }
        func closeDangling(_ why: String) -> [ClaudeCodeEvent] { lock.withLock { parser.closeDangling(why) } }
        func end() { lock.withLock { isEnded = true } }
        var ended: Bool { lock.withLock { isEnded } }

        struct Snapshot: Sendable {
            var sessionID: String?
            var progressed: Bool
            var result: ClaudeCodeResult?
            var usage: LLMUsage?
            var lastReplyText: String
            var contextTokens: Int?
            var model: String?
            var apiKeySource: String?
            var apiError: (category: String, text: String)?
            var rateLimit: ClaudeCodeRateLimit?
            var unparsed: String
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(sessionID: parser.sessionID, progressed: parser.progressed, result: parser.result, usage: parser.usage,
                         lastReplyText: parser.lastReplyText, contextTokens: parser.contextTokens, model: parser.model,
                         apiKeySource: parser.apiKeySource, apiError: parser.apiError, rateLimit: parser.rateLimit,
                         unparsed: parser.unparsed)
            }
        }
    }

    // MARK: The line under a turn

    /// "Claude Code: 3 steps · 12,400 tokens in (8,000 cached) · 84 out · about $0.01 at API prices — covered by your
    /// Claude plan." The CLI's cost adds up over the session, so a turn's share is the difference from the last total.
    public static func usageLine(result: ClaudeCodeResult, usage: LLMUsage?, previousTotal: Double?, apiKeySource: String?) -> String? {
        var parts: [String] = []
        if result.numTurns > 0 { parts.append("\(result.numTurns) step\(result.numTurns == 1 ? "" : "s")") }
        if let usage {
            parts.append("\(grouped(usage.promptTokens)) tokens in" + ((usage.cachedTokens ?? 0) > 0 ? " (\(grouped(usage.cachedTokens!)) cached)" : ""))
            parts.append("\(grouped(usage.completionTokens)) out")
        }
        if let total = result.totalCostUSD {
            let who = (apiKeySource.map { !$0.isEmpty && $0 != "none" } ?? false) ? "billed to the API key" : "covered by your Claude plan"
            parts.append("\(costWords(turnCost(total: total, previousTotal: previousTotal))) at API prices — \(who)")
        }
        return parts.isEmpty ? nil : "Claude Code: " + parts.joined(separator: " · ") + "."
    }

    /// This turn's share of the session's running total (a smaller total means the session started over).
    public static func turnCost(total: Double, previousTotal: Double?) -> Double {
        if let previousTotal, total >= previousTotal { return total - previousTotal }
        return total
    }

    /// "under $0.01", "about $0.42", "about $1.5".
    public static func costWords(_ usd: Double) -> String {
        if usd < 0.01 { return "under $0.01" }
        return "about $" + String(format: usd < 1 ? "%.2f" : "%.1f", usd)
    }

    /// 12400 → "12,400" (the same on every Mac, whatever its region).
    static func grouped(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}

// MARK: - The chat so far, for a Claude Code session that hasn't seen it

/// A chat that moves onto Claude Code part-way (or whose Claude Code session was lost) already has a conversation
/// Claude Code never saw. Its first Claude Code turn carries a recap of it — the most recent exchanges that fit, oldest
/// first — so the work continues instead of starting over. (The same text as Vision for Windows' ClaudeCodeRecap.)
public enum ClaudeCodeRecap {
    /// Roughly 8K tokens of history.
    public static let defaultBudget = 32_000

    public static let header = "[Earlier in this chat — before this Claude Code session. Another model (or an earlier session) answered these; carry on from here rather than starting over.]"
    public static let footer = "[End of the earlier conversation. The person's new message follows.]"

    /// The recap, or nil when there is nothing before the new message.
    public static func build(_ history: [LLMMessage], budget: Int = defaultBudget) -> String? {
        var parts: [String] = []
        var used = 0
        for message in history.reversed() {
            var text = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let who: String
            switch message.role {
            case .user: who = "Person"
            case .assistant: who = "Assistant"
            default: who = "Summary"
            }
            let room = budget - used
            if room < 200 { break }
            if text.count > room - 20 { text = "…" + String(text.suffix(room - 21)) }
            parts.append("\(who): \(text)")
            used += text.count + who.count + 4
        }
        guard !parts.isEmpty else { return nil }
        return header + "\n\n" + parts.reversed().joined(separator: "\n\n") + "\n\n" + footer
    }
}

// MARK: - The shield on what Vision hands Claude Code

/// Claude Code reads files and runs commands itself, so the sensitive-data shield can't stand between it and Anthropic
/// the way it does for Vision's own engine. What Vision itself hands over is shielded: the recap of the chat so far
/// is masked like any request to a model that isn't private (it is history, so nothing has to come back — and earlier
/// turns may have been answered by a private model, unmasked); the new message and the text of its attachments have
/// their secrets masked (and the vault's values), the other kinds left as the person wrote them, because Claude Code
/// would write a placeholder into a file as it is — nothing can put the real value back for it. The same rules as
/// Vision for Windows.
public enum ClaudeCodeShield {
    public struct Masked: Sendable, Equatable {
        public var recap: String?
        public var message: String
        public var parts: [AttachmentWirePart]
        /// Distinct values masked, by kind.
        public var counts: [SensitiveCategory: Int]
        /// Pictures or PDFs go as they are (the shield can't look into them).
        public var unchecked: Bool
    }

    /// Put after the recap's header when something in it was masked.
    public static let recapNote = "[Vision's sensitive-data shield replaced some values in this recap with placeholders such as ⟦EMAIL_1⟧. The real values aren't available here — ask the person if you need one.]"

    /// Said once per chat per launch when a chat with history moves onto Claude Code while the shield is on.
    public static let notice = "The sensitive-data shield covers what Vision hands Claude Code — the chat so far, and secrets in your messages — but not what Claude Code reads or runs itself: that goes to Anthropic as it is."

    /// What the turn sends, masked with `detector` (the shield's, nil = off: everything as it is). One set of
    /// placeholders across the recap, the message and the attachments' text, so a value is the same placeholder in each.
    public static func mask(recap: String?, message: String, parts: [AttachmentWirePart], detector: SensitiveDetector?) -> Masked {
        let unchecked = parts.contains { if case .text = $0 { false } else { true } }
        guard let detector else {
            return Masked(recap: recap, message: message, parts: parts, counts: [:], unchecked: unchecked)
        }
        // Secrets everywhere first (one numbering), then everything else in the recap only.
        var texts = [recap ?? "", message]
        var textIndexes: [Int] = []
        for (index, part) in parts.enumerated() {
            if case .text(let text) = part {
                textIndexes.append(index)
                texts.append(text)
            }
        }
        let (secretsMasked, secretCounts) = maskAll(texts, secretsOnly(detector))
        var counts = secretCounts
        var maskedRecap: String?
        if let recap {
            let (full, more) = maskAll([secretsMasked[0]], detector)
            for (category, n) in more { counts[category, default: 0] += n }
            maskedRecap = full[0]
            if full[0] != recap {
                maskedRecap = full[0].hasPrefix(ClaudeCodeRecap.header)
                    ? ClaudeCodeRecap.header + "\n" + recapNote + full[0].dropFirst(ClaudeCodeRecap.header.count)
                    : recapNote + "\n\n" + full[0]
            }
        }
        var maskedParts = parts
        for (offset, index) in textIndexes.enumerated() { maskedParts[index] = .text(secretsMasked[2 + offset]) }
        return Masked(recap: maskedRecap, message: secretsMasked[1], parts: maskedParts, counts: counts.filter { $0.value > 0 },
                      unchecked: unchecked)
    }

    /// The same detector looking for secrets only (and the vault's values, always).
    static func secretsOnly(_ detector: SensitiveDetector) -> SensitiveDetector {
        var settings = ShieldSettings()
        settings.enabled = detector.settings.enabled && detector.settings.secrets
        settings.secrets = true
        settings.emails = false
        settings.phones = false
        settings.ids = false
        settings.ips = false
        settings.terms = false
        settings.customTerms = []
        return SensitiveDetector(settings: settings, vaultValues: detector.vaultValues)
    }

    private static func maskAll(_ texts: [String], _ detector: SensitiveDetector) -> ([String], [SensitiveCategory: Int]) {
        guard detector.isActive else { return (texts, [:]) }
        let request = LLMRequest(systemPrompt: "", messages: texts.map { LLMMessage.user($0) }, tools: [], model: "")
        let result = Shield.mask(request, detector: detector)
        return (result.request.messages.map { $0.content ?? "" }, result.map.counts)
    }
}

// MARK: - The real launcher

/// Starts the real `claude` with pipes for standard input, output and error. No shell: the arguments go to the program
/// as they are.
public struct ProcessClaudeCodeLauncher: ClaudeCodeLauncher {
    /// Interrupt request → SIGTERM, and SIGTERM → SIGKILL, in seconds.
    public var interruptGrace: TimeInterval
    public var killGrace: TimeInterval

    public init(interruptGrace: TimeInterval = ClaudeCodeTurn.interruptGrace, killGrace: TimeInterval = 3) {
        self.interruptGrace = interruptGrace
        self.killGrace = killGrace
    }

    public func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                       input: String, interrupt: @escaping @Sendable () -> String,
                       onLine: @escaping @Sendable (String, any ClaudeCodeChannel) -> Void) async throws -> ClaudeCodeExit {
        let run = ClaudeCodeProcessRun(executable: executable, arguments: arguments, environment: environment,
                                       workingDirectory: workingDirectory, input: input, interrupt: interrupt, onLine: onLine,
                                       interruptGrace: interruptGrace, killGrace: killGrace)
        return try await withTaskCancellationHandler {
            try await run.execute()
        } onCancel: {
            run.stop()
        }
    }
}

/// One run of the CLI. `stop()` may come from any thread at any time, before the child exists too.
final class ClaudeCodeProcessRun: ClaudeCodeChannel, @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let workingDirectory: URL
    private let input: String
    private let interruptLine: @Sendable () -> String
    private let onLine: @Sendable (String, any ClaudeCodeChannel) -> Void
    private let interruptGrace: TimeInterval
    private let killGrace: TimeInterval

    private let lock = NSLock()
    /// Writes to stdin happen here, in order; the descriptor is only touched on this queue.
    private let writer = DispatchQueue(label: "vision.claude-code.stdin")
    private var stdinHandle: FileHandle?
    private var closed = false
    private var pid: pid_t = 0
    /// The CLI leads its own process group (what Foundation's Process does), so the group can be killed.
    private var leadsGroup = false
    private var started = false
    private var exited = false
    private var exitCode: Int32 = 0
    private var stopRequested = false
    private var lineBuffer = Data()
    private var stderrTail = Data()
    private let exitGate = AWSCLIGate()
    private let outClosed = AWSCLIGate()
    private let errClosed = AWSCLIGate()

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL, input: String,
         interrupt: @escaping @Sendable () -> String, onLine: @escaping @Sendable (String, any ClaudeCodeChannel) -> Void,
         interruptGrace: TimeInterval, killGrace: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.input = input
        self.interruptLine = interrupt
        self.onLine = onLine
        self.interruptGrace = interruptGrace
        self.killGrace = killGrace
    }

    // MARK: The channel

    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        writer.async { [self] in
            guard let handle = lock.withLock({ closed ? nil : stdinHandle }) else { return }
            // EPIPE (it exited before reading) is an error here, not a SIGPIPE: its output says why.
            try? handle.write(contentsOf: data)
        }
    }

    func closeInput() {
        writer.async { [self] in
            let handle: FileHandle? = lock.withLock {
                guard !closed else { return nil }
                closed = true
                return stdinHandle
            }
            try? handle?.close()
        }
    }

    var inputClosed: Bool { lock.withLock { closed } }

    // MARK: Running

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
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        lock.withLock { stdinHandle = stdin.fileHandleForWriting }
        do {
            try await Self.spawn(child)
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ClaudeCodeError.couldNotStart(error.localizedDescription)
        }
        let childPID = child.processIdentifier
        let ownGroup = getpgid(childPID) == childPID
        let stopNow: Bool = lock.withLock {
            pid = childPID
            leadsGroup = ownGroup
            started = true
            return stopRequested
        }
        // The prompt; stdin stays open for the permission answers.
        send(input)
        if stopNow { beginStop() }

        await exitGate.wait()
        // The last lines may still be in the pipe; a grandchild holding it open is only waited for briefly.
        await outClosed.wait(upTo: 5)
        await errClosed.wait(upTo: 1)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        flushLine()
        closeInput()
        return lock.withLock {
            ClaudeCodeExit(exitCode: exitCode, stderr: String(decoding: stderrTail, as: UTF8.self), interrupted: stopRequested)
        }
    }

    // MARK: Output

    private func consume(_ chunk: Data) {
        var lines: [String] = []
        lock.withLock {
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<newline], as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            }
        }
        for line in lines { onLine(line, self) }
    }

    private func flushLine() {
        let last: String? = lock.withLock {
            guard !lineBuffer.isEmpty else { return nil }
            defer { lineBuffer.removeAll() }
            return String(decoding: lineBuffer, as: UTF8.self)
        }
        if let last { onLine(last, self) }
    }

    // MARK: Stopping

    /// Stop the turn: the interrupt control request while stdin is open (Claude Code ends the turn and keeps the
    /// session), SIGINT when it's already closed, SIGTERM after the grace period, then SIGKILL for the CLI and anything
    /// left in its process group.
    func stop() {
        let running: Bool = lock.withLock {
            guard !stopRequested else { return false }
            stopRequested = true
            return started && !exited
        }
        if running { beginStop() }
    }

    private func beginStop() {
        let (target, group, inputOpen): (pid_t, Bool, Bool) = lock.withLock { (pid, leadsGroup, !closed) }
        guard target > 1 else { return }
        if inputOpen { send(interruptLine()) } else { kill(target, SIGINT) }
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
