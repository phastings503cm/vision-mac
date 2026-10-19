import Foundation

// MARK: - Chat tasks: the rules
//
// A chat's task list is what it is doing now — the plan of the running turn or /goal, always the first task — and the
// prompts queued after it with "Add to tasks". When the current work finishes, the next waiting task starts by itself,
// as if the person had sent it then; the list keeps taking new tasks while it moves. These are the decisions, as pure
// functions both harnesses share (same words, same thresholds).

public enum ChatTaskRules {
    /// What a chat task becomes once its turn is over.
    public static func status(for outcome: PromptRecord.Outcome) -> QueueTaskStatus {
        switch outcome {
        case .completed, .issues, .unknown: .complete
        case .needsYou: .blocked
        case .failed: .failed
        case .stopped: .skipped
        case .queued: .queued
        case .running: .running
        }
    }

    /// Whether the next waiting task may start by itself after the current work ended this way. A Stop, a failure or
    /// a goal that needs the person pauses the list: the next prompt may depend on what didn't happen.
    public static func continuesAfter(_ outcome: PromptRecord.Outcome) -> Bool {
        switch outcome {
        case .completed, .issues, .unknown: true
        case .needsYou, .failed, .stopped, .queued, .running: false
        }
    }

    /// The paused list's banner.
    public static func pauseReason(for outcome: PromptRecord.Outcome) -> String {
        switch outcome {
        case .stopped: "Paused — you stopped the current work."
        case .failed: "Paused — the last task failed."
        case .needsYou: "Paused — the agent needs you."
        default: "Paused."
        }
    }

    /// A task's title from its prompt: the first non-empty line, at most 80 characters; for one queued with only
    /// attachments (a large paste, a PDF), from what it carries: "📎 Pasted text, report.pdf". As on Windows.
    public static func title(for prompt: String, attachmentNames: [String] = []) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, !attachmentNames.isEmpty {
            return title(for: "📎 " + attachmentNames.joined(separator: ", "))
        }
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        var title = first.trimmingCharacters(in: .whitespaces)
        if title.count > 80 { title = String(title.prefix(79)) + "…" }
        return title.isEmpty ? "Untitled task" : title
    }

    /// What the chat says when a prompt with attachments goes on its list.
    public static func carriesNotice(_ count: Int) -> String {
        count == 1 ? "Its attachment goes with it." : "Its \(count) attachments go with it."
    }

    /// A queued task whose kept attachment is gone from the disk fails with this reason.
    public static func missingAttachmentReason(_ name: String) -> String {
        "its attachment “\(name)” is no longer on this Mac"
    }

    /// The banner after a relaunch: waiting tasks never start on their own when Vision opens.
    public static let pausedAtLaunch = "Paused — Vision was restarted. Resume to carry on."
}

// MARK: - Which plan step a subagent works

/// A plan's step for a subagent: so the plan can show who is working each step (name and model), and the background
/// activity menu what each subagent was assigned.
public enum PlanAssignment {
    /// The step a subagent named `description` (asked to do `prompt`) is working: the open step its words match best;
    /// with no match, the step in progress when it started (when exactly one is); else none.
    public static func step(description: String, prompt: String = "", todos: [TodoItem]) -> String? {
        let open = todos.filter { $0.status != .completed }
        guard !open.isEmpty else { return nil }
        let mine = significantWords(description + " " + prompt.prefix(400))
        let words = open.map { significantWords($0.content) }
        let scores = words.map { $0.intersection(mine).count }
        let bestScore = scores.max() ?? 0
        if bestScore > 0 {
            let tied = open.indices.filter { scores[$0] == bestScore }
            if tied.count == 1 { return open[tied[0]].content }
            // A tie ("Write the parser" and "Add tests for the parser" for "Write tests for the parser"): what only that
            // step says decides; still tied, no step is shown rather than a wrong one (the agent tool's step argument
            // says it).
            let distinctive = tied.map { i in
                words[i].filter { word in !words.indices.contains { j in j != i && words[j].contains(word) } }
                    .intersection(mine).count
            }
            let top = distinctive.max() ?? 0
            guard top > 0, distinctive.filter({ $0 == top }).count == 1, let at = distinctive.firstIndex(of: top) else { return nil }
            return open[tied[at]].content
        }
        let inProgress = open.filter { $0.status == .inProgress }
        return inProgress.count == 1 ? inProgress[0].content : nil
    }

    /// The step a subagent was started on: the one its `step` argument names — the step's number in the plan (1 = the
    /// first) or its text, whole or a part only that step has — else the best guess from its words.
    public static func step(requested: String?, description: String, prompt: String = "", todos: [TodoItem]) -> String? {
        named(requested, todos: todos) ?? step(description: description, prompt: prompt, todos: todos)
    }

    /// The step `requested` names, or nil when it names none (or more than one).
    public static func named(_ requested: String?, todos: [TodoItem]) -> String? {
        guard var text = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !todos.isEmpty else { return nil }
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let number = Int(text), number >= 1, number <= todos.count else { return nil }
            return todos[number - 1].content
        }
        if let exact = todos.first(where: {
            $0.content.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(text) == .orderedSame
        }) {
            return exact.content
        }
        let containing = todos.filter { $0.content.range(of: text, options: .caseInsensitive) != nil }
        return containing.count == 1 ? containing[0].content : nil
    }

    static func significantWords(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "into", "each", "every", "then",
                                 "file", "files", "code", "make", "sure", "about", "their", "there", "where", "which"]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
        return Set(words.map(String.init).filter { $0.count >= 4 && !stop.contains($0) }.map(stem))
    }

    /// Crude stem so "tests"/"test", "parsing"/"parser"/"parse" meet.
    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ers", "er", "es", "s", "ed", "e"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }
}
