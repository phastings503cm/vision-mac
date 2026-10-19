import Foundation

// MARK: - The life of one turn: Planning → Execution → Validation → Results
//
// Every harness (this Mac app, Guardian's chat, the Windows harness) runs the same four phases
// around a turn:
//
//   PLANNING   the model drafts its approach (streaming, live) and states an ETA. The estimate is
//              learned per task *kind* — the kind is one of a small catalog — refined by the scope
//              signals in the ask (steps in the plan, files, words) and by what similar turns took
//              before. Guardian is multiuser/multitenant and caches those durations across users;
//              a single-machine harness keeps its own small cache and starts from the catalog's
//              defaults.
//   EXECUTION  the work itself: tool calls, streamed text, everything a turn already does. A green,
//              semi-animated working badge shows the runtime against the estimate.
//   VALIDATION the turn is done working: the model checks its own work against the plan it put out
//              and produces evidence — a screenshot, a run log, the files it changed. Evidence the
//              turn can already show (screenshot tool output) is picked up automatically; if
//              validation fails the turn loops back to Execution. The loopback is unlimited by
//              default but capped (3 by default) so a hopeless turn says so instead of spinning.
//   RESULTS    the turn's summary: a green "completed with results" banner, the evidence, and how
//              the final state matches the plan it began with.
//
// Everything here is plain values and pure functions so any harness can drive it and every part is
// testable headlessly. What this module does not do: talk to a model, run tools, or draw anything.

public struct TurnPhaseState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case planning, execution, validation, results

        public var label: String {
            switch self {
            case .planning: "Planning"
            case .execution: "Execution"
            case .validation: "Validation"
            case .results: "Results"
            }
        }

        /// The symbol a harness shows on the phase badge.
        public var symbol: String {
            switch self {
            case .planning: "text.badge.checkmark"
            case .execution: "hammer"
            case .validation: "checkmark.seal"
            case .results: "checkmark.circle.fill"
            }
        }
    }

    /// What the ask is *like* — the axis an ETA is learned along. Deliberately coarse: a handful of
    /// kinds is enough for an estimate that beats "always 2 minutes", and every catalog entry has a
    /// default so the first turn of its kind is already sane.
    public enum TaskKind: String, Codable, Hashable, Sendable, CaseIterable {
        case quickQuestion      // answer only, no tools
        case research           // read/look things up, no writes
        case codeEdit           // change code, prove it with the project's own tests
        case buildRun           // build, run, or verify something on the machine
        case writing            // prose: docs, README, an email, a report
        case screenWork         // drive an app on the desktop
        case openEnded          // anything else; also the fallback

        public var label: String {
            switch self {
            case .quickQuestion: "Quick question"
            case .research: "Research"
            case .codeEdit: "Code change"
            case .buildRun: "Build or run"
            case .writing: "Writing"
            case .screenWork: "Screen control"
            case .openEnded: "Open-ended task"
            }
        }

        /// The median seconds a turn of this kind takes, before anything is learned. Deliberately
        /// conservative — better to beat an estimate than to sit under a "4s left" that won't move.
        public var defaultSeconds: Double {
            switch self {
            case .quickQuestion: 20
            case .research: 75
            case .codeEdit: 210
            case .buildRun: 180
            case .writing: 120
            case .screenWork: 150
            case .openEnded: 240
            }
        }

        /// How widely turns of this kind vary, as a fraction of the estimate. A quick question is
        /// tight; open-ended work varies several-fold.
        public var spread: Double {
            switch self {
            case .quickQuestion: 0.6
            case .research: 0.8
            case .codeEdit: 1.0
            case .buildRun: 0.9
            case .writing: 0.7
            case .screenWork: 0.9
            case .openEnded: 1.4
            }
        }
    }

    /// One entry in the ETA cache: the running mean of finished turns of one kind.
    public struct DurationSample: Codable, Hashable, Sendable {
        public var count: Int
        public var meanSeconds: Double
        /// Mean of the scope scale (see `scopeScale`) of the turns behind the mean, so a scope
        /// multiplier for a *new* ask is relative to what was averaged.
        public var meanScope: Double

        public init(count: Int = 0, meanSeconds: Double = 0, meanScope: Double = 1) {
            self.count = count
            self.meanSeconds = meanSeconds
            self.meanScope = meanScope
        }
    }

    // MARK: Identity

    /// The turn these phases belong to. A new prompt starts a new turn id; a /goal round keeps
    /// working inside the same turn until the goal ends.
    public var turnID: String
    public var phase: Phase

    // MARK: Planning

    /// What the ask looked like to the estimator.
    public var taskKind: TaskKind?
    /// Scope of the ask: the scale its duration should scale with (words in the prompt, planned
    /// steps, files in a project…). 1.0 is an ordinary ask.
    public var scopeScale: Double
    /// The plan as it is being drafted — streamed deltas accumulate here live.
    public var draft: String
    /// The settled plan: what the model committed to (its first todo list, or the first paragraph
    /// of its answer). Validation checks the result against this.
    public var plan: String?
    /// The estimate, seconds, once stated. Nil until then.
    public var etaSeconds: Double?
    /// How the estimate was made, for the UI's tooltip ("learned from 6 similar tasks").
    public var etaBasis: String?
    /// When planning began — the runtime clock starts here.
    public var startedAt: Date?

    // MARK: Execution

    /// When execution began (planning handed over).
    public var executionStartedAt: Date?
    /// One line per step, stamped — what drilling into the working badge shows.
    public var steps: [Step]
    /// Count of files this turn changed (scope + evidence).
    public var filesChanged: Int

    // MARK: Validation

    /// How many times validation sent the turn back to execution.
    public var loopbacks: Int
    /// The cap on loopbacks (nil = unlimited). The default: unlimited, user-cappable at 3.
    public var loopbackCap: Int?
    /// Evidence gathered for the results page.
    public var evidence: [Evidence]
    /// Why the last validation failed (shown on the loopback banner).
    public var lastValidationFailure: String?
    /// When validation finished and results began — or when the turn ended early (see `endedReason`).
    public var finishedAt: Date?
    /// The turn ended before results: stopped, failed, or the goal needs the person. The card stops animating and
    /// says why instead of showing a phase that is no longer running.
    public var endedReason: String?

    public struct Step: Codable, Hashable, Sendable {
        public var at: Date
        public var text: String
        public init(at: Date = .now, text: String) {
            self.at = at
            self.text = text
        }
    }

    /// Proof the work is done: something on disk, a picture, a run's output — collected during
    /// validation and shown on the results page.
    public struct Evidence: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Hashable, Sendable {
            case screenshot, file, runOutput, check, note

            public var label: String {
                switch self {
                case .screenshot: "Screenshot"
                case .file: "File"
                case .runOutput: "Run output"
                case .check: "Check"
                case .note: "Note"
                }
            }
            public var symbol: String {
                switch self {
                case .screenshot: "camera"
                case .file: "doc"
                case .runOutput: "terminal"
                case .check: "checkmark.seal"
                case .note: "note.text"
                }
            }
        }
        public var id: String
        public var kind: Kind
        public var title: String
        /// The evidence itself: file contents, a run's output, the validator's note. For a
        /// screenshot this names the tool card it rides on (the picture lives in the timeline).
        public var detail: String
        public var at: Date

        public init(id: String = UUID().uuidString, kind: Kind, title: String, detail: String, at: Date = .now) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.at = at
        }
    }

    // MARK: - Starting

    public init(turnID: String = UUID().uuidString, loopbackCap: Int? = nil) {
        self.turnID = turnID
        self.phase = .planning
        self.scopeScale = 1
        self.draft = ""
        self.steps = []
        self.filesChanged = 0
        self.loopbacks = 0
        self.loopbackCap = loopbackCap
        self.evidence = []
    }

    // MARK: - The estimator

    /// How big this ask is, from the signals a harness has before answering: the ask itself (words,
    /// imperative verbs), how many steps its plan eventually named, and how big the workspace is.
    /// All weights are heuristics — the point is a stable relative scale, learned against.
    public static func scope(ofPrompt prompt: String, plannedSteps: Int = 0, projectFiles: Int = 0) -> Double {
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).count
        // Words: 8 words ≈ a nudge, 80+ words ≈ a spec. Saturating log scale around ~24 words.
        var scale = 0.55 + 0.45 * log2(Double(max(words, 1)) / 12.0)
        scale = min(max(scale, 0.4), 2.2)
        // Verbs that widen the ask: "also", "and then", commas between imperatives.
        let widening = [" and ", " then ", " also ", " plus ", " after that"]
        let widenHits = widening.filter { prompt.lowercased().contains($0) }.count
        scale *= 1 + 0.12 * Double(min(widenHits, 4))
        // Planned steps: a todo list is the model's own measure of the work (1.5 min/step weight).
        if plannedSteps > 0 { scale *= 1 + 0.18 * Double(min(plannedSteps - 1, 8)) }
        // A big project takes longer to explore; 300 files is a lot.
        if projectFiles > 40 { scale *= 1 + min(log2(Double(projectFiles) / 40.0), 1.5) * 0.25 }
        return min(max(scale, 0.35), 4.0)
    }

    /// Classify an ask into the catalog — from the prompt alone. Good enough to pick a prior;
    /// the learned cache does the rest.
    public static func kind(ofPrompt prompt: String) -> TaskKind {
        let p = prompt.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { p.contains($0) } }
        if has(["screenshot", "click", "the screen", "desktop", "keyboard", "type into", "open the app",
                "focus ", "mouse", "drag the"]) { return .screenWork }
        if has(["build ", "run ", "launch", "compile", "start the server", "restart", "deploy", "install "])
            && !has(["explain", "what does"]) { return .buildRun }
        if has(["fix", "refactor", "implement", "add ", "write a test", "tests", "bug", "compile error",
                "typescript", "swift", "function", "the build is broken"]) { return .codeEdit }
        if has(["write", "draft", "rewrite", "summarize", "summarise", "email", "readme", "document",
                "blog", "post", "changelog", "notes for"]) { return .writing }
        if has(["find", "research", "look up", "look into", "compare", "explain", "how does", "why does",
                "what is", "tour", "review", "search"]) { return .research }
        return .openEnded
    }

    /// The estimate for an ask of `kind` at `scope`, given what similar turns took.
    /// With no samples: the catalog default, scaled. With samples: the learned mean, moved toward
    /// the scaled default by how little evidence there is (so early estimates stay sane) and by how
    /// far the new ask's scope sits from the mean scope behind the samples.
    public static func estimate(kind: TaskKind, scope: Double, samples: DurationSample) -> (seconds: Double, basis: String) {
        let prior = kind.defaultSeconds * scope
        guard samples.count > 0, samples.meanSeconds > 0 else {
            return (prior.rounded(), "first estimate for a \(kind.label.lowercased()) — it refines as these complete")
        }
        // Scope correction: the samples were taken at `meanScope`; this ask sits at `scope`.
        let scopeCorrected = samples.meanSeconds * (scope / max(samples.meanScope, 0.2))
        // Shrink toward the prior while there is little evidence (k counts whole turns).
        let weight = Double(samples.count) / (Double(samples.count) + 2.0)
        let blended = weight * scopeCorrected + (1 - weight) * prior
        let seconds = min(max(blended, 3), 45 * 60).rounded()
        var basis = "learned from \(samples.count) similar task\(samples.count == 1 ? "" : "s")"
        if abs(scope - samples.meanScope) > 0.25 {
            basis += scope > samples.meanScope ? " · this one is bigger than usual" : " · this one is smaller than usual"
        }
        return (seconds, basis)
    }

    /// Fold a finished turn's wall-clock into the cache for its kind.
    public static func record(kind: TaskKind, seconds: Double, scope: Double, into samples: DurationSample) -> DurationSample {
        var out = samples
        guard seconds > 0.5, seconds < 4 * 3600 else { return out }   // ignore junk (a stalled run, a paused one)
        let total = out.meanSeconds * Double(out.count) + seconds
        out.count += 1
        out.meanSeconds = total / Double(out.count)
        let scopeTotal = out.meanScope * Double(out.count - 1) + scope
        out.meanScope = scopeTotal / Double(out.count)
        return out
    }

    /// Human phrasing of an estimate ("~2 min", "~1h 10m").
    public static func phrase(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 45 { return "about \(max(s, 5))s" }
        if s < 90 { return "about a minute" }
        if s < 3600 { return "about \(Int((Double(s) / 60.0).rounded())) min" }
        let hours = s / 3600
        let minutes = Int(((Double(s % 3600)) / 60.0).rounded())
        return minutes >= 5 ? "about \(hours)h \(minutes)m" : "about \(hours)h"
    }

    // MARK: - Transitions (pure; the caller assigns the result back)

    public mutating func beginPlanning(prompt: String, kind: TaskKind, scope: Double, at: Date = .now) {
        self.taskKind = kind
        self.scopeScale = scope
        self.draft = ""
        self.plan = nil
        self.phase = .planning
        self.startedAt = at
        steps.append(Step(at: at, text: "Planning started — assessing the ask"))
    }

    /// The plan settled (first todo list, or first paragraph of the answer) and the estimate is in:
    /// execution begins.
    public mutating func beginExecution(plan: String, etaSeconds: Double, basis: String, at: Date = .now) {
        self.plan = plan
        self.etaSeconds = etaSeconds
        self.etaBasis = basis
        self.phase = .execution
        self.executionStartedAt = at
        steps.append(Step(at: at, text: "Execution started — estimated \(Self.phrase(etaSeconds)) (\(basis))"))
    }

    public mutating func addStep(_ text: String, at: Date = .now) {
        steps.append(Step(at: at, text: text))
        if steps.count > 400 { steps.removeFirst(steps.count - 400) }
    }

    /// Validation failed: back to execution. Returns false when the cap is reached — the caller
    /// finishes as-is instead (the loopback is unlimited by default; cap it to bound a hopeless turn).
    public mutating func loopBack(reason: String, at: Date = .now) -> Bool {
        if let cap = loopbackCap, loopbacks >= cap { return false }
        loopbacks += 1
        lastValidationFailure = reason
        phase = .execution
        steps.append(Step(at: at, text: "Validation failed (\(reason)) — back to execution, attempt \(loopbacks + 1)"))
        return true
    }

    public mutating func addEvidence(_ item: Evidence, at: Date = .now) {
        evidence.append(item)
        if evidence.count > 24 { evidence.removeFirst(evidence.count - 24) }
    }

    /// The turn ended without reaching results (stopped, an error, a goal that needs the person).
    public mutating func end(reason: String, at: Date = .now) {
        endedReason = reason
        finishedAt = at
        steps.append(Step(at: at, text: reason))
    }

    /// The turn is over, one way or the other.
    public var isOver: Bool { phase == .results || endedReason != nil }

    /// Validation passed: the results phase. `againstPlan` is the closing note — how the outcome
    /// matches the plan the turn started with.
    public mutating func beginResults(summary: String, at: Date = .now) {
        phase = .results
        finishedAt = at
        steps.append(Step(at: at, text: summary))
    }

    /// The whole turn's wall clock so far (planning through now).
    public var runtime: TimeInterval {
        guard let start = startedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    /// Seconds spent executing (validation loopbacks included).
    public var executionRuntime: TimeInterval {
        guard let start = executionStartedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(start)
    }
}

// MARK: - The runner's side: what to do at each phase

/// Drives the phases around one turn's steps. The harness (AppTransport, the queue, Guardian's
/// worker) owns the actual model calls; this tells it *when* to do what, and decides the
/// validation loopback. The default loopback is unlimited; pass a cap to bound it.
///
/// Not actor-isolated: it is plain mutable state the harness owns (one per app, used from the
/// main actor; tests use it directly). Sendable only by discipline.
public final class TurnPhaseRunner: @unchecked Sendable {
    /// The ETA cache, by task kind. Loaded from disk, saved on every update.
    /// Written by the runner itself and by `GuardianClient.syncEtas` (the
    /// multitenant blend); read anywhere.
    public private(set) var samples: [TurnPhaseState.TaskKind: TurnPhaseState.DurationSample]

    /// Merge one kind's learned entry in (the Guardian sync's write path).
    public func mergeSample(kind: TurnPhaseState.TaskKind, _ sample: TurnPhaseState.DurationSample) {
        samples[kind] = sample
    }
    private let fileURL: URL?
    /// How many loopbacks a turn may take by default (nil = unlimited, per the spec).
    public var loopbackCapDefault: Int?

    public init(fileURL: URL? = nil, loopbackCapDefault: Int? = nil) {
        self.fileURL = fileURL
        self.loopbackCapDefault = loopbackCapDefault
        self.samples = Self.load(from: fileURL)
    }

    public func sample(for kind: TurnPhaseState.TaskKind) -> TurnPhaseState.DurationSample {
        samples[kind] ?? TurnPhaseState.DurationSample()
    }

    /// Begin a turn: classify, scope, and state the estimate from what's known now.
    public func begin(_ state: inout TurnPhaseState, prompt: String, projectFiles: Int = 0) {
        let kind = TurnPhaseState.kind(ofPrompt: prompt)
        let scope = TurnPhaseState.scope(ofPrompt: prompt, projectFiles: projectFiles)
        state.beginPlanning(prompt: prompt, kind: kind, scope: scope)
    }

    /// The plan settled (the model wrote its first todo list / laid out its approach): move to
    /// execution with an estimate that blends the scope-so-far (now including planned steps) with
    /// what similar turns took.
    public func planSettled(_ state: inout TurnPhaseState, plan: String, stepsPlanned: Int) {
        let scope = TurnPhaseState.scope(ofPrompt: state.draft.isEmpty ? (state.plan ?? plan) : state.draft,
                                         plannedSteps: stepsPlanned, projectFiles: 0)
        state.scopeScale = max(state.scopeScale, scope)
        guard let kind = state.taskKind else { return }
        let (seconds, basis) = TurnPhaseState.estimate(kind: kind, scope: state.scopeScale, samples: sample(for: kind))
        state.beginExecution(plan: plan, etaSeconds: seconds, basis: basis)
    }

    /// Refine the estimate as the plan grows (more steps appeared mid-execution): a heavier ask than
    /// first thought. Called when a todo list changes during execution.
    public func refine(_ state: inout TurnPhaseState, stepsPlanned: Int) {
        guard state.phase == .execution, let kind = state.taskKind, let eta = state.etaSeconds else { return }
        let scope = TurnPhaseState.scope(ofPrompt: state.plan ?? "", plannedSteps: stepsPlanned)
        let fresh = TurnPhaseState.estimate(kind: kind, scope: scope, samples: sample(for: kind)).seconds
        // Move at most a third of the way: a plan growing from 3 to 9 steps shouldn't whipsaw.
        state.etaSeconds = max(eta, eta + (fresh - eta) * 0.34)
    }

    /// A turn finished (any outcome): record its wall-clock for the kind, if the turn got far
    /// enough to classify. Returns the updated cache entry.
    @discardableResult
    public func recordCompletion(_ state: TurnPhaseState) -> TurnPhaseState.DurationSample? {
        guard let kind = state.taskKind, let start = state.startedAt else { return nil }
        let end = state.finishedAt ?? Date()
        let seconds = end.timeIntervalSince(start)
        let before = sample(for: kind)
        let after = TurnPhaseState.record(kind: kind, seconds: seconds, scope: state.scopeScale, into: before)
        samples[kind] = after
        save()
        return after
    }

    // MARK: Persistence

    private struct CacheFile: Codable {
        var entries: [String: TurnPhaseState.DurationSample]
    }

    private static func load(from url: URL?) -> [TurnPhaseState.TaskKind: TurnPhaseState.DurationSample] {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return [:] }
        var out: [TurnPhaseState.TaskKind: TurnPhaseState.DurationSample] = [:]
        for (key, value) in file.entries {
            if let kind = TurnPhaseState.TaskKind(rawValue: key) { out[kind] = value }
        }
        return out
    }

    private func save() {
        guard let fileURL else { return }
        var entries: [String: TurnPhaseState.DurationSample] = [:]
        for (kind, value) in samples { entries[kind.rawValue] = value }
        guard let data = try? JSONEncoder().encode(CacheFile(entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Validation

/// What the harness checks at the end of a turn on its own — what it can see, never the model's word alone — and the
/// no-progress rule that stops an unlimited loop-back (Patrick's answer to Q1: no retry cap by default; the person's
/// budget and this check are the only always-on stops). The same rules and words as Vision for Windows.
public enum TurnValidation {
    /// A line that begins with one of these reports a failure.
    static let markers = ["Error:", "error: ", "Traceback (most recent call last)", "Build FAILED"]

    /// Why validation fails this turn (empty: it passes). `reply` is the turn's closing words.
    public static func failures(state: TurnPhaseState, reply: String) -> [String] {
        var failures: [String] = []
        if let marker = reportedError(reply) {
            failures.append("the reply reports an error (\(marker.trimmingCharacters(in: .whitespaces)))")
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.plan != nil || state.filesChanged > 0 {
            failures.append("the turn ended without a summary")
        }
        return failures
    }

    /// The first failure marker the reply reports, or nil. A marker counts only at the start of a line (after
    /// indentation or a list marker) and outside code fences, so a reply that quotes an error while explaining it
    /// doesn't fail.
    public static func reportedError(_ reply: String) -> String? {
        var inFence = false
        for raw in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(raw.hasSuffix("\r") ? raw.dropLast() : raw)
            line = line.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            while line.count > 1, let first = line.first, "-*>•".contains(first),
                  let second = line.dropFirst().first, second.isWhitespace {
                line = line.dropFirst(2).drop { $0 == " " || $0 == "\t" }
            }
            if let marker = markers.first(where: { line.hasPrefix($0) }) { return marker }
        }
        return nil
    }

    /// The no-progress check (always on): after a failed validation, this attempt made no progress when it fails the
    /// same way as the attempt before it and finished no new plan step.
    public static func madeNoProgress(previousFailure: String?, failure: String, stepsDoneBefore: Int, stepsDoneNow: Int) -> Bool {
        previousFailure != nil && previousFailure == failure && stepsDoneNow <= stepsDoneBefore
    }

    /// How many attempts in a row may make no progress before the loop-back stops: two.
    public static let noProgressLimit = 2

    /// What a goal round is told after validation sends it back.
    public static func loopBackMessage(_ failure: String, attempt: Int) -> String {
        "(Automatic — not from the user.) Validation of your work found a problem: \(failure). This is attempt \(attempt). "
            + "Fix it — run what proves it works — and only then declare the goal complete, with a closing summary of what you did and how you checked it."
    }

    /// The transcript row of a loop-back (one of the harness's own rows, never a prompt of the person's).
    public static func loopBackDisplay(attempt: Int) -> String {
        "↻ validation: fix and check again (attempt \(attempt))"
    }
}
