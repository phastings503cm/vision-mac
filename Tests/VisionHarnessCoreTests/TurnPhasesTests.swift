import XCTest
@testable import VisionHarnessCore

final class TurnPhasesTests: XCTestCase {
    // MARK: Classification

    func testKindClassification() {
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Take a screenshot of the settings window and click Save"),
                       .screenWork)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Fix the flaky CSV import test"), .codeEdit)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Run the test suite and tell me what fails"), .buildRun)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Draft release notes for 0.3.0"), .writing)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Find every place we hardcode the API URL"), .research)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Explain how compaction works"), .research)
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "Do the thing"), .openEnded)
    }

    func testQuickQuestionClassificationWinsForShortPrompts() {
        // A short ask with no tool words is a question, not open-ended work.
        XCTAssertEqual(TurnPhaseState.kind(ofPrompt: "what is a context window?"), .research)
    }

    // MARK: Scope

    func testScopeGrowsWithWordsAndSteps() {
        let short = TurnPhaseState.scope(ofPrompt: "fix the bug")
        let wordy = TurnPhaseState.scope(ofPrompt: String(repeating: "please also fix the parser and then run everything and also update the readme then deploy it after that ", count: 3))
        XCTAssertGreaterThan(wordy, short * 1.5)

        let withSteps = TurnPhaseState.scope(ofPrompt: "fix the bug", plannedSteps: 8)
        XCTAssertGreaterThan(withSteps, short * 1.5)
    }

    func testScopeIsBounded() {
        let huge = TurnPhaseState.scope(ofPrompt: String(repeating: "word ", count: 5000), plannedSteps: 40, projectFiles: 5000)
        XCTAssertLessThanOrEqual(huge, 4.0)
        let tiny = TurnPhaseState.scope(ofPrompt: "hi")
        XCTAssertGreaterThanOrEqual(tiny, 0.35)
    }

    // MARK: Estimates

    func testFirstEstimateIsTheCatalogPrior() {
        let (seconds, basis) = TurnPhaseState.estimate(kind: .codeEdit, scope: 1.0, samples: .init())
        XCTAssertEqual(seconds, TurnPhaseState.TaskKind.codeEdit.defaultSeconds)
        XCTAssertTrue(basis.contains("first estimate"))
    }

    func testEstimateLearnsFromSamples() {
        // Six code edits averaged 100s at scope 1. A new scope-1 ask should sit near 100s, not the 210s prior.
        let samples = TurnPhaseState.record(kind: .codeEdit, seconds: 100, scope: 1.0,
                                            into: TurnPhaseState.record(kind: .codeEdit, seconds: 100, scope: 1.0,
                                                                        into: TurnPhaseState.record(kind: .codeEdit, seconds: 100, scope: 1.0,
                                                                                                    into: .init(count: 3, meanSeconds: 100, meanScope: 1))))
        let (seconds, basis) = TurnPhaseState.estimate(kind: .codeEdit, scope: 1.0, samples: samples)
        // With 6 samples the blend is 128 (weight 0.75 of scope-corrected 100 toward the 210 prior).
        XCTAssertEqual(seconds, 128, accuracy: 20)
        XCTAssertTrue(basis.contains("learned from"))
    }

    func testEstimateScalesWithScopeAgainstLearnedMean() {
        var samples = TurnPhaseState.DurationSample()
        for _ in 0..<6 { samples = TurnPhaseState.record(kind: .writing, seconds: 60, scope: 1.0, into: samples) }
        let (seconds, _) = TurnPhaseState.estimate(kind: .writing, scope: 2.0, samples: samples)
        XCTAssertGreaterThan(seconds, 100)   // twice the scope ≈ twice the time
        XCTAssertLessThan(seconds, 200)
    }

    func testRecordIgnoresJunkDurations() {
        var samples = TurnPhaseState.DurationSample(count: 2, meanSeconds: 120, meanScope: 1)
        samples = TurnPhaseState.record(kind: .research, seconds: 0.1, scope: 1, into: samples)
        samples = TurnPhaseState.record(kind: .research, seconds: 100_000, scope: 1, into: samples)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples.meanSeconds, 120, accuracy: 0.001)
    }

    // MARK: Phrasing

    func testPhrase() {
        XCTAssertEqual(TurnPhaseState.phrase(20), "about 20s")
        XCTAssertEqual(TurnPhaseState.phrase(60), "about a minute")
        XCTAssertEqual(TurnPhaseState.phrase(240), "about 4 min")
        XCTAssertEqual(TurnPhaseState.phrase(4200), "about 1h 10m")
        XCTAssertEqual(TurnPhaseState.phrase(3600), "about 1h")
    }

    // MARK: Transitions

    func testPlanningToExecutionToResults() async {
        var state = TurnPhaseState()
        state.beginPlanning(prompt: "fix the bug", kind: .codeEdit, scope: 1.2)
        XCTAssertEqual(state.phase, .planning)
        XCTAssertNotNil(state.startedAt)

        try? await Task.sleep(nanoseconds: 50_000_000)
        state.beginExecution(plan: "1. fix\n2. test", etaSeconds: 120, basis: "learned from 3 similar tasks")
        XCTAssertEqual(state.phase, .execution)
        XCTAssertEqual(state.etaSeconds, 120)
        XCTAssertEqual(state.executionRuntime, 0.05, accuracy: 0.1)

        state.addStep("edited report.py")
        XCTAssertEqual(state.steps.last?.text, "edited report.py")

        state.addEvidence(.init(kind: .check, title: "All 14 tests pass", detail: "python3 -m pytest"))
        state.beginResults(summary: "Validated against the plan: 2 of 2 steps done")
        XCTAssertEqual(state.phase, .results)
        XCTAssertNotNil(state.finishedAt)
        XCTAssertEqual(state.evidence.count, 1)
        XCTAssertEqual(state.runtime, 0.05, accuracy: 0.3)
    }

    func testLoopbackUnlimitedByDefault() {
        var state = TurnPhaseState()
        state.beginExecution(plan: "p", etaSeconds: 10, basis: "b")
        for i in 0..<7 {
            XCTAssertTrue(state.loopBack(reason: "test still fails"))
            XCTAssertEqual(state.phase, .execution)
            XCTAssertEqual(state.loopbacks, i + 1)
        }
    }

    func testLoopbackCap() {
        var state = TurnPhaseState(loopbackCap: 3)
        state.beginExecution(plan: "p", etaSeconds: 10, basis: "b")
        XCTAssertTrue(state.loopBack(reason: "x"))
        XCTAssertTrue(state.loopBack(reason: "x"))
        XCTAssertTrue(state.loopBack(reason: "x"))
        XCTAssertFalse(state.loopBack(reason: "x"))   // capped
        XCTAssertEqual(state.loopbacks, 3)
        XCTAssertEqual(state.lastValidationFailure, "x")
    }

    func testStepsAreStampedAndBounded() {
        var state = TurnPhaseState()
        for i in 0..<450 { state.addStep("step \(i)") }
        XCTAssertEqual(state.steps.count, 400)
        XCTAssertEqual(state.steps.last?.text, "step 449")
    }

    func testEvidenceBounded() {
        var state = TurnPhaseState()
        for i in 0..<30 { state.addEvidence(.init(kind: .note, title: "e\(i)", detail: "")) }
        XCTAssertEqual(state.evidence.count, 24)
        XCTAssertEqual(state.evidence.first?.title, "e6")
    }

    // MARK: The runner and its cache

    func testRunnerRefinesEstimateUpwardOnlyWhenPlanGrows() {
        let runner = TurnPhaseRunner()
        var state = TurnPhaseState()
        runner.begin(&state, prompt: "fix the bug and write tests")
        runner.planSettled(&state, plan: "a plan", stepsPlanned: 3)
        let first = state.etaSeconds
        runner.refine(&state, stepsPlanned: 9)
        XCTAssertGreaterThan(state.etaSeconds ?? 0, first ?? 0)
        // Refinement moves at most a third of the gap.
        let scope9 = TurnPhaseState.scope(ofPrompt: "a plan", plannedSteps: 9)
        let fresh = TurnPhaseState.estimate(kind: state.taskKind!, scope: scope9, samples: runner.sample(for: state.taskKind!)).seconds
        XCTAssertLessThanOrEqual(state.etaSeconds!, min(first! + (fresh - first!) * 0.34 + 0.5, fresh + 0.5))
    }

    func testRunnerRecordsCompletionAndPersists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("phases-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("eta-cache.json")
        let runner = TurnPhaseRunner(fileURL: file)
        var state = TurnPhaseState()
        runner.begin(&state, prompt: "fix the flaky test")
        state.beginExecution(plan: "p", etaSeconds: 10, basis: "b")
        // A believable wall-clock: the cache ignores sub-second runs as junk.
        state.startedAt = Date().addingTimeInterval(-90)
        state.beginResults(summary: "done")
        let after = runner.recordCompletion(state)
        XCTAssertEqual(after?.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A fresh runner reads the same cache.
        let second = TurnPhaseRunner(fileURL: file)
        XCTAssertEqual(second.sample(for: .codeEdit).count, 1)
        try? FileManager.default.removeItem(at: dir)
    }

    func testRunnerBeginClassifiesAndScopes() {
        let runner = TurnPhaseRunner()
        var state = TurnPhaseState()
        runner.begin(&state, prompt: "take a screenshot of the dashboard")
        XCTAssertEqual(state.taskKind, .screenWork)
        XCTAssertEqual(state.phase, .planning)
        XCTAssertGreaterThan(state.scopeScale, 0)
        XCTAssertFalse(state.steps.isEmpty)
    }
}

/// Validation's own checks, the same as Windows': a marker counts at the start of a line outside code fences, and the
/// no-progress rule stops an unlimited loop-back.
final class TurnValidationTests: XCTestCase {
    func testAnErrorCountsOnlyAtTheStartOfALineOutsideFences() {
        XCTAssertEqual(TurnValidation.reportedError("Done.\nError: the build failed"), "Error:")
        XCTAssertEqual(TurnValidation.reportedError("  - Traceback (most recent call last):"), "Traceback (most recent call last)")
        XCTAssertEqual(TurnValidation.reportedError("> Build FAILED in 3s"), "Build FAILED")
        XCTAssertNil(TurnValidation.reportedError("The old code printed Error: x, which I fixed."), "quoted mid-line")
        XCTAssertNil(TurnValidation.reportedError("Before:\n```\nError: boom\n```\nNow it passes."), "inside a fence")
        XCTAssertNil(TurnValidation.reportedError("errors: none"))
        var state = TurnPhaseState()
        XCTAssertTrue(TurnValidation.failures(state: state, reply: "").isEmpty, "no plan, no files: an empty reply is fine")
        state.filesChanged = 2
        XCTAssertEqual(TurnValidation.failures(state: state, reply: " "), ["the turn ended without a summary"])
    }

    func testTheNoProgressRuleAndTheLoopBackWords() {
        XCTAssertFalse(TurnValidation.madeNoProgress(previousFailure: nil, failure: "x", stepsDoneBefore: 0, stepsDoneNow: 0))
        XCTAssertTrue(TurnValidation.madeNoProgress(previousFailure: "x", failure: "x", stepsDoneBefore: 2, stepsDoneNow: 2))
        XCTAssertFalse(TurnValidation.madeNoProgress(previousFailure: "x", failure: "x", stepsDoneBefore: 2, stepsDoneNow: 3), "a step got done")
        XCTAssertFalse(TurnValidation.madeNoProgress(previousFailure: "x", failure: "y", stepsDoneBefore: 2, stepsDoneNow: 2), "a new failure")
        XCTAssertEqual(TurnValidation.noProgressLimit, 2)
        XCTAssertEqual(TurnValidation.loopBackDisplay(attempt: 2), "↻ validation: fix and check again (attempt 2)")
        XCTAssertTrue(TurnValidation.loopBackMessage("the reply reports an error (Error:)", attempt: 2)
            .hasPrefix("(Automatic — not from the user.) Validation of your work found a problem: the reply reports an error (Error:). This is attempt 2."))
        var capped = TurnPhaseState(loopbackCap: 1)
        XCTAssertTrue(capped.loopBack(reason: "x"))
        XCTAssertFalse(capped.loopBack(reason: "x"), "the optional cap")
    }
}
