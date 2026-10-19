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
        var best: (step: TodoItem, score: Int)?
        for step in open {
            let score = significantWords(step.content).intersection(mine).count
            if score > 0, score > (best?.score ?? 0) { best = (step, score) }
        }
        if let best { return best.step.content }
        let inProgress = open.filter { $0.status == .inProgress }
        return inProgress.count == 1 ? inProgress[0].content : nil
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
