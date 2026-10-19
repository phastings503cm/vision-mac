import Foundation

// MARK: - Slash commands
//
// Typed into the composer. Only these exact words are commands — anything
// else starting with "/" (a path like /Users/me/x) goes to the model as-is.

public enum SlashCommand: Equatable, Sendable {
    /// Summarize the conversation now; optional focus for the summary.
    case compact(focus: String?)
    /// Work on a task in a loop until the model declares it complete.
    case goal(String)
    /// Show or set this chat's thinking level ("default" clears the override).
    case think(String?)
    /// Show the detected context window and usage.
    case context
    /// Show the Spark's models, or switch the Spark to one ("/swap flash").
    case swap(String?)
    /// List skills and what is selected for this chat.
    case skills
    /// "/skill <name>" toggles a skill for this chat; "/skill new <what it should do>" writes one.
    case skill(String?)
    /// Start (or report) the unattended task queue.
    case queue
    /// The model servers subagents run on, how busy each is, and what is running.
    case agents
    /// Show or limit which apps this chat may control ("only [apps]", "any", "default").
    case control(String?)
    case help

    public struct Info: Sendable {
        public let usage: String
        public let summary: String
        public init(usage: String, summary: String) {
            self.usage = usage
            self.summary = summary
        }
    }

    public static let catalog: [Info] = [
        .init(usage: "/goal <task>", summary: "Keep working, round after round, until the model says GOAL_COMPLETE (bare /goal resumes)"),
        .init(usage: "/compact [focus]", summary: "Summarize the conversation now to free up context"),
        .init(usage: "/think off|low|medium|high|max|default", summary: "Set how hard the model thinks in this chat"),
        .init(usage: "/context", summary: "Show the model's context window and how much is used"),
        .init(usage: "/swap [model]", summary: "Show the Spark's models, or switch what it serves (e.g. /swap flash)"),
        .init(usage: "/skills", summary: "List skills and what is selected for this chat"),
        .init(usage: "/skill <name>|new <what>", summary: "Select/deselect a skill for this chat, or have the model write a new one"),
        .init(usage: "/queue", summary: "Start the task queue — it works queued tasks one at a time, unattended"),
        .init(usage: "/agents", summary: "Show the model servers subagents run on, how busy each is, and what is running now"),
        .init(usage: "/control only [apps]|any|default", summary: "Limit this chat to controlling the apps it starts (and ones you name), or let it control any app"),
        .init(usage: "/help", summary: "List commands"),
    ]

    public static func parse(_ raw: String) -> SlashCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let head = text.prefix { !$0.isWhitespace }
        let rest = text.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let arg: String? = rest.isEmpty ? nil : rest
        switch head.lowercased() {
        case "/compact", "/compress", "/summarize": return .compact(focus: arg)
        case "/goal": return .goal(rest)
        case "/think", "/thinking", "/effort", "/reasoning": return .think(arg)
        case "/context", "/ctx": return .context
        case "/swap", "/model", "/models", "/serve": return .swap(arg)
        case "/skills": return .skills
        case "/skill": return .skill(arg)
        case "/queue": return .queue
        case "/agents", "/fleet", "/servers": return .agents
        case "/control": return .control(arg)
        case "/help", "/?", "/commands": return .help
        default: return nil
        }
    }
}

// MARK: - Goal mode

/// The protocol a `/goal` run speaks with the model: a kickoff message, a
/// continuation message each round, and two end markers the model writes on
/// a line of their own.
///
/// There is no round cap: a goal runs until the model declares it complete
/// (or blocked), the user stops it, or it fails on an error that retrying
/// cannot fix. Transient model outages are retried inside the engine and
/// never end a goal.
public enum GoalProtocol {
    public static let completeMarker = "GOAL_COMPLETE"
    public static let blockedMarker = "GOAL_BLOCKED"
    /// Rounds in a row that may end in a non-transient error (a malformed
    /// request, a context overflow compaction couldn't fix) before the goal
    /// gives up and reports it. Each failed round is retried after a pause.
    public static let maxConsecutiveErrors = 5

    public enum Status: Equatable, Sendable {
        case working
        case complete
        case blocked(String)
    }

    public static func kickoff(_ goal: String) -> String {
        """
        GOAL: \(goal)

        Work on this goal autonomously until it is completely done. Use your tools; plan with `todo_write` \
        for multi-step work; verify results (build, run, test, re-read files) instead of assuming.
        You will be prompted to continue after every reply, so it is fine to stop and resume in steps — \
        but do not stop to ask for confirmation of things you can decide or check yourself.

        When — and only when — the goal is fully achieved and verified, finish your reply with a line \
        containing exactly:
        \(completeMarker)
        If you genuinely cannot proceed without the user (missing credentials, a decision only they can make, \
        or an external blocker), finish with a line:
        \(blockedMarker): <what you need from the user>
        Never write either marker in any other situation. The loop only ends on one of these lines.
        """
    }

    /// The unattended variant (task queue): the user is not at the keyboard,
    /// so "blocked" is reserved for true external walls — anything that can
    /// be decided by reading code, running a build, or checking a state gets
    /// decided and worked through instead.
    public static func kickoffAuto(_ goal: String) -> String {
        kickoff(goal) + unattendedNote
    }

    /// Kickoff for a `/goal` picked back up in the same chat (a bare `/goal`
    /// after a stop, a block, or a failure).
    public static func resume(_ goal: String) -> String {
        resumePreface + kickoff(goal)
    }

    private static let resumePreface = """
    [Resuming] You worked on this goal earlier in this conversation and were interrupted \
    (a restart, a stop, or a block the user may have answered above). Do not start over: check the \
    current state — files, builds, tests, and any replies from the user — and continue from where you left off.


    """

    /// Kickoff for a queue task picked back up in its own chat — after an app
    /// restart, a Stop, or a block the user has since answered. The model sees
    /// its earlier work above and continues rather than starting over.
    public static func resumeAuto(_ goal: String) -> String {
        resumePreface + kickoffAuto(goal)
    }

    private static let unattendedNote = """


    This goal is running unattended in the task queue. The user will not see this \
    conversation until it finishes, so never stop to ask a question you can answer \
    yourself: read the code, run the build, test it, and make the call. If something \
    truly cannot proceed without them, finish with `\(blockedMarker): <exactly what you \
    need>` and stop — it will be picked back up later.
    """

    public static func continuationAuto(_ goal: String, round: Int, hitIterationLimit: Bool,
                                        error: String? = nil, markerMisplaced: Bool = false) -> String {
        continuation(goal, round: round, hitIterationLimit: hitIterationLimit, error: error,
                     markerMisplaced: markerMisplaced) +
        """

        Reminder: unattended run — decide and move on; only `\(blockedMarker)` stops it.
        """
    }

    public static func continuation(_ goal: String, round: Int, hitIterationLimit: Bool,
                                    error: String? = nil, markerMisplaced: Bool = false) -> String {
        let why: String
        if markerMisplaced {
            why = "Your last reply mentioned \(completeMarker)/\(blockedMarker) but not as its final line, so it did not count. "
                + "If the goal is done, reply with a short summary ending in a line that contains only \(completeMarker)."
        } else if let error {
            why = "The previous round was cut short by an error (\(error.prefix(300))). Check what state things are in and carry on."
        } else if hitIterationLimit {
            why = "You were cut off mid-work by the per-turn step limit. Pick up exactly where you left off."
        } else {
            why = "You have not declared the goal complete yet."
        }
        return """
        [Goal round \(round)] \(why)
        GOAL (unchanged): \(goal)

        Check what remains against the goal and continue. If everything is done, verify it one last time and \
        finish with a line containing exactly `\(completeMarker)` — the loop keeps going until you write that line. \
        If you are blocked on the user, finish with `\(blockedMarker): <what you need>`.
        """
    }

    /// Read the end marker from the model's reply. A marker counts only on a
    /// line of its own (markdown like `**…**`, backticks, bullets, emoji and
    /// trailing punctuation is ignored, as is a short label such as
    /// "**Status:**"), so the model explaining the protocol ("I'll write
    /// GOAL_COMPLETE when…") doesn't end the loop. Only the reply's closing
    /// lines (the protocol asks for the marker last) and its very first line
    /// (models that lead with the verdict) are read, so a recap of an earlier
    /// marker mid-reply doesn't count; the last of those wins. Code fences
    /// and `<think>` blocks are ignored.
    public static func status(of reply: String) -> Status {
        let lines = candidateLines(reply)
        guard !lines.isEmpty else { return .working }
        var considered = Array(lines.suffix(3))
        if lines.count > 3 { considered.insert(lines[0], at: 0) }
        for line in considered.reversed() {
            if let status = marker(in: line) { return status }
        }
        return .working
    }

    /// True when the reply names an end marker somewhere without it counting
    /// (buried mid-reply, inline in prose): the next round asks for it plainly.
    public static func mentionsMarker(_ reply: String) -> Bool {
        let upper = stripThinking(reply).uppercased()
        return upper.contains(completeMarker) || upper.contains(blockedMarker)
    }

    /// Non-empty lines outside code fences and thinking, decoration trimmed.
    private static func candidateLines(_ reply: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for raw in stripThinking(reply).components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
                // "```swift build```" opens and closes on one line.
                if trimmed.components(separatedBy: fence).count - 1 < 2 { inFence.toggle() }
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || inFence { continue }
            let line = trimmed.replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: decoration)
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    /// Drop `<think>…</think>` blocks (servers without a reasoning parser
    /// leave them inline), including an unterminated leading one.
    static func stripThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        if let close = s.range(of: "</think>") { s = String(s[close.upperBound...]) }
        return s
    }

    /// Characters stripped from both ends of a line before matching.
    private static let decoration: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.formUnion(.punctuationCharacters)
        set.formUnion(.symbols)
        set.formUnion(.nonBaseCharacters)   // emoji variation selectors
        set.formUnion(CharacterSet(charactersIn: "\u{200B}\u{200D}"))
        return set
    }()

    /// Markup that may sit between a label and the marker ("Status: __GOAL_COMPLETE").
    private static let markup = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`~\"'[](){}<>"))

    private static func marker(in line: String) -> Status? {
        let upper = line.uppercased()
        // "GOAL COMPLETE" / "GOAL-COMPLETE" read as the complete marker too.
        let canonical = upper.replacingOccurrences(of: "GOAL COMPLETE", with: completeMarker)
            .replacingOccurrences(of: "GOAL-COMPLETE", with: completeMarker)
        if canonical == completeMarker { return .complete }
        if canonical.hasSuffix(completeMarker) {
            let prefix = String(canonical.dropLast(completeMarker.count))
            if isLabel(prefix) { return .complete }
        }
        // Blocked: the exact token only, alone or followed by its reason.
        guard let range = upper.range(of: blockedMarker) else { return nil }
        let prefix = String(upper[..<range.lowerBound])
        guard prefix.isEmpty || isLabel(prefix) else { return nil }
        let offset = upper.distance(from: upper.startIndex, to: range.upperBound)
        let rest = line.count >= offset ? String(line.dropFirst(offset)) : ""
        let trimmedRest = rest.trimmingCharacters(in: markup)
        if let first = trimmedRest.first, !":-—–=".contains(first) { return nil }   // "GOAL_BLOCKED on the …" is prose
        let reason = trimmedRest.trimmingCharacters(in: CharacterSet(charactersIn: ":-—–= \t").union(markup))
        let negative = ["no", "none", "n/a", "na", "false", "nothing", "not blocked", "-"]
        if negative.contains(reason.lowercased()) { return nil }
        return .blocked(reason.isEmpty ? "The agent needs your input." : reason)
    }

    private static func isLabel(_ prefix: String) -> Bool {
        let t = prefix.trimmingCharacters(in: markup)
        guard let last = t.last, last == ":" || last == "-" || last == "—" || last == "=" else { return false }
        let words = t.dropLast().split(whereSeparator: { $0.isWhitespace })
        return t.count <= 24 && words.count <= 3
    }
}
