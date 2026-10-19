import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The harness end to end, against the fake model server: every prompt lands in the chat's Prompts timeline with how
/// it ended (and stays there across a relaunch); prompts added to a chat's tasks run after the current work, in order,
/// by themselves; a Stop or a failure pauses the rest; and the chat's current work and the background activity list
/// say what runs where.
@MainActor
final class RunsHostTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var transport: AppTransport!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-runs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Done.") }
        defaultsSuite = "vision-runs-tests-\(UUID().uuidString)"
        transport = makeTransport()
        transport.adoptProject(project)
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 80_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
    }

    /// A transport over this test's folders (a second one is "the app opened again").
    private func makeTransport() -> AppTransport {
        let config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        let t = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                             queueFile: dir.appendingPathComponent("task-queue.json"),
                             skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                             vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        t.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        t.goalErrorBackoff = { _ in 0.02 }
        return t
    }

    private var project: URL {
        let url = dir.appendingPathComponent("proj", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for: \(what)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func idle(_ vm: SessionVM) -> Bool {
        !vm.running && transport.runTasks[vm.id] == nil && transport.chatTaskInFlight[vm.id] == nil
    }

    private var userTexts: [String] {
        FakeModelServer.seen.filter(\.fresh).map(\.lastUser)
    }

    // MARK: The Prompts timeline

    func testAPromptIsRecordedWithHowItEndedAndSurvivesARelaunch() async throws {
        let vm = transport.newSession(cwd: project.path)
        transport.send("What does the parser do?", sessionID: vm.id)
        try await waitUntil("answered") { vm.promptHistory.last?.outcome == .completed && idle(vm) }

        let record = try XCTUnwrap(vm.promptHistory.last)
        XCTAssertEqual(record.text, "What does the parser do?")
        XCTAssertEqual(record.source, .typed)
        XCTAssertEqual(record.headline, "Completed with results", "the closing summary is its evidence")
        XCTAssertNotNil(record.finishedAt)
        XCTAssertNotNil(record.etaSeconds, "planning stated an estimate")
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.model, "stub-model")
        XCTAssertEqual(record.route, "stub")
        XCTAssertEqual(record.promptTokens, 100)
        XCTAssertEqual(record.completionTokens, 20)
        XCTAssertEqual(record.entryText, "What does the parser do?")
        XCTAssertTrue(record.completionNote?.contains("Done.") ?? false, record.completionNote ?? "")
        XCTAssertNil(vm.currentPromptID)
        XCTAssertNotNil(transport.entryID(for: record, in: vm), "Jump finds its row")
        transport.log.flush(wait: true)

        // The app opens again: the chat's timeline is read back, not rebuilt.
        let again = makeTransport()
        let reopened = try XCTUnwrap(again.sessions.first { $0.id == vm.id })
        again.hydrate(reopened)
        XCTAssertEqual(reopened.promptHistory.map(\.id), vm.promptHistory.map(\.id))
        XCTAssertEqual(reopened.promptHistory.map(\.outcome), [.completed])
        XCTAssertEqual(reopened.promptHistory.first?.evidence.count, record.evidence.count)
        XCTAssertEqual(reopened.promptHistory.first?.durationSeconds ?? 0, record.durationSeconds ?? -1, accuracy: 0.002)
        XCTAssertNotNil(again.entryID(for: record, in: reopened), "Jump finds the replayed row by its text and time")
    }

    func testAStoppedPromptIsRecordedStoppedAndItsCardStopsAnimating() async throws {
        FakeModelServer.reset { _, _ in .slow(5, "late") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("Take your time", sessionID: vm.id)
        try await waitUntil("running") { vm.running && !FakeModelServer.seen.isEmpty }
        transport.stopSession(vm.id)
        try await waitUntil("stopped") { idle(vm) }
        let record = try XCTUnwrap(vm.promptHistory.last)
        XCTAssertEqual(record.outcome, .stopped)
        XCTAssertEqual(record.reason, "Stopped before it finished.")
        XCTAssertNotNil(vm.turnPhase?.endedReason)
        XCTAssertTrue(vm.turnPhase?.isOver ?? false)
    }

    func testAFailedPromptIsRecordedWithTheReason() async throws {
        FakeModelServer.reset { _, _ in .http(400, #"{"error":{"message":"temperature is not supported for this model"}}"#) }
        let vm = transport.newSession(cwd: project.path)
        transport.send("Hello", sessionID: vm.id)
        try await waitUntil("failed") { vm.promptHistory.last?.outcome == .failed && idle(vm) }
        let reason = try XCTUnwrap(vm.promptHistory.last?.reason)
        XCTAssertTrue(reason.contains("temperature"), reason)
    }

    func testAGoalIsRecordedAsAGoalWithItsRounds() async throws {
        FakeModelServer.reset { _, index in index < 2 ? .text("Working on it.") : .text("All done.\nGOAL_COMPLETE") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("/goal Make it work", sessionID: vm.id)
        try await waitUntil("goal done") { vm.promptHistory.last?.outcome == .completed && idle(vm) }
        let record = try XCTUnwrap(vm.promptHistory.last)
        XCTAssertEqual(record.source, .goal)
        XCTAssertEqual(record.text, "Make it work")
        XCTAssertEqual(record.rounds, 2)
        XCTAssertEqual(record.entryText, "🎯 /goal Make it work")
    }

    func testAChatFromBeforeTheTimelineIsBackfilledOnce() async throws {
        let id = UUID().uuidString
        let t0 = Date().addingTimeInterval(-3_600)
        let rows = [
            LogItemRow(sessionID: id, seq: 0, kind: "user", text: "Old question", toolName: nil, argSummary: nil,
                       output: nil, isError: false, at: t0),
            LogItemRow(sessionID: id, seq: 1, kind: "assistant", text: "Old answer", toolName: nil, argSummary: nil,
                       output: nil, isError: false, at: t0.addingTimeInterval(30)),
            LogItemRow(sessionID: id, seq: 2, kind: "user", text: "Then this", toolName: nil, argSummary: nil,
                       output: nil, isError: false, at: t0.addingTimeInterval(60)),
            LogItemRow(sessionID: id, seq: 3, kind: "notice", text: "Stopped.", toolName: nil, argSummary: nil,
                       output: nil, isError: false, at: t0.addingTimeInterval(75)),
        ]
        transport.log.store(LogSession(id: id, title: "Old chat", cwd: project.path, preset: nil, updatedAt: t0), items: rows)

        let again = makeTransport()
        // All Prompts reads a chat nobody opened, and writes its file so it is never rebuilt.
        let all = again.allPromptRecords()
        XCTAssertEqual(all.filter { $0.chatID == id }.map(\.text), ["Old question", "Then this"])
        XCTAssertNotNil(again.promptStore.load(id))

        let vm = try XCTUnwrap(again.sessions.first { $0.id == id })
        again.hydrate(vm)
        XCTAssertEqual(vm.promptHistory.map(\.outcome), [.completed, .stopped])
        XCTAssertEqual(vm.promptHistory.first?.durationSeconds, 30)
        XCTAssertTrue(vm.promptHistory.allSatisfy(\.backfilled))
    }

    func testDeletingAChatTakesItsTimelineAndTasks() async throws {
        let vm = transport.newSession(cwd: project.path)
        transport.send("hi", sessionID: vm.id)
        try await waitUntil("answered") { idle(vm) && vm.promptHistory.count == 1 }
        transport.pauseChatTasks(vm.id)
        transport.addChatTask("later", sessionID: vm.id)
        XCTAssertNotNil(transport.promptStore.load(vm.id))
        transport.deleteSession(vm.id)
        XCTAssertNil(transport.promptStore.load(vm.id))
        XCTAssertTrue(transport.queue.chatTasks(vm.id).isEmpty)
    }

    // MARK: The chat's tasks

    func testTasksAddedWhileItWorksRunAfterItInOrderByThemselves() async throws {
        FakeModelServer.reset { seen, _ in seen.lastUser.contains("first") ? .slow(0.6, "First done.") : .text("Done: \(seen.lastUser)") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("the first prompt", sessionID: vm.id)
        try await waitUntil("running") { vm.running }
        let second = try XCTUnwrap(transport.addChatTask("the second prompt", sessionID: vm.id))
        let third = try XCTUnwrap(transport.addChatTask("the third prompt", sessionID: vm.id))
        XCTAssertEqual(transport.queue.task(second.id)?.status, .queued, "it waits for the current work")
        XCTAssertEqual(transport.currentWork(for: vm)?.title, "the first prompt", "the current work is the first task")

        try await waitUntil("all three done", timeout: 20) {
            transport.queue.task(third.id)?.status == .complete && idle(vm)
        }
        XCTAssertEqual(userTexts.filter { $0.contains("prompt") }, ["the first prompt", "the second prompt", "the third prompt"])
        XCTAssertEqual(transport.queue.task(second.id)?.status, .complete)
        XCTAssertEqual(vm.promptHistory.map(\.source), [.typed, .task, .task])
        XCTAssertEqual(vm.promptHistory.map(\.outcome), [.completed, .completed, .completed])
        XCTAssertNil(transport.queue.nextTask, "never the unattended queue's")
        XCTAssertFalse(transport.queueRunning)
    }

    func testATaskAddedToAFreeChatStartsAtOnce() async throws {
        let vm = transport.newSession(cwd: project.path)
        let task = try XCTUnwrap(transport.addChatTask("go now", sessionID: vm.id))
        try await waitUntil("done") { transport.queue.task(task.id)?.status == .complete && idle(vm) }
        XCTAssertEqual(vm.promptHistory.last?.source, .task)
    }

    /// A waiting task waits on the box behind its chat's own model (not the primary's), and starts by itself when that
    /// box finishes switching — never marked done early (Windows review finding 2, the Mac's shape of it).
    func testATaskWaitsWhileItsChatsOwnServerSwitchesAndStartsAfter() async throws {
        let other = ProviderProfile(kind: .openAICompat, name: "spark-2", baseURL: "http://spark2.test/v1", model: "qwen-b")
        transport.config.providers.append(other)
        final class Box: @unchecked Sendable { var switching = true }
        let box = Box()
        transport.isServerSwitching = { false }   // the primary's box is free
        transport.isRouteSwitching = { route in route.routeID == other.routeID && box.switching }
        let vm = transport.newSession(cwd: project.path)
        transport.setRoute(other.routeID, for: vm)
        let task = try XCTUnwrap(transport.addChatTask("after the swap", sessionID: vm.id))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.queue.task(task.id)?.status, .queued, "waits while its own box switches")
        XCTAssertTrue(userTexts.isEmpty, "nothing was sent to a box mid-swap")
        // Another chat on the primary is not held up by spark-2 (a new chat in the project starts on spark-2, its
        // project's last choice, so it is moved back).
        let free = transport.newSession(cwd: project.path)
        transport.setRoute(try XCTUnwrap(transport.config.activeRoute), for: free)
        let quick = try XCTUnwrap(transport.addChatTask("on the primary", sessionID: free.id))
        try await waitUntil("the primary's chat ran") { transport.queue.task(quick.id)?.status == .complete && idle(free) }
        box.switching = false
        transport.serverSwitchFinished()
        try await waitUntil("ran after the swap") { transport.queue.task(task.id)?.status == .complete && idle(vm) }
        XCTAssertTrue(userTexts.contains { $0.contains("after the swap") })
    }

    func testStopPausesTheListAndResumeCarriesOn() async throws {
        FakeModelServer.reset { seen, _ in seen.lastUser.contains("long") ? .slow(5, "late") : .text("ok") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("a long job", sessionID: vm.id)
        try await waitUntil("running") { vm.running && !FakeModelServer.seen.isEmpty }
        let next = try XCTUnwrap(transport.addChatTask("next one", sessionID: vm.id))
        transport.stopSession(vm.id)
        try await waitUntil("stopped") { idle(vm) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.chatTasksPaused[vm.id], "Paused — you stopped the current work.")
        XCTAssertEqual(transport.queue.task(next.id)?.status, .queued, "nothing new starts after a Stop")

        transport.resumeChatTasks(vm.id)
        try await waitUntil("resumed and done") { transport.queue.task(next.id)?.status == .complete && idle(vm) }
        XCTAssertNil(transport.chatTasksPaused[vm.id])
    }

    func testAFailedTaskPausesTheRestAndCanRunAgain() async throws {
        FakeModelServer.reset { seen, _ in seen.lastUser.contains("bad") ? .http(400, #"{"error":"no"}"#) : .text("fine") }
        let vm = transport.newSession(cwd: project.path)
        transport.pauseChatTasks(vm.id)
        let bad = try XCTUnwrap(transport.addChatTask("a bad one", sessionID: vm.id))
        let after = try XCTUnwrap(transport.addChatTask("after it", sessionID: vm.id))
        transport.resumeChatTasks(vm.id)
        try await waitUntil("failed") { transport.queue.task(bad.id)?.status == .failed && idle(vm) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.chatTasksPaused[vm.id], "Paused — the last task failed.")
        XCTAssertEqual(transport.queue.task(after.id)?.status, .queued)

        FakeModelServer.reset { _, _ in .text("fine now") }
        transport.retryChatTask(bad.id)
        try await waitUntil("both done") {
            transport.queue.task(bad.id)?.status == .complete && transport.queue.task(after.id)?.status == .complete && idle(vm)
        }
    }

    func testRemovingTheRunningTaskStartsTheNextOne() async throws {
        FakeModelServer.reset { seen, _ in seen.lastUser.contains("slow") ? .slow(5, "late") : .text("ok") }
        let vm = transport.newSession(cwd: project.path)
        let slow = try XCTUnwrap(transport.addChatTask("slow task", sessionID: vm.id))
        let next = try XCTUnwrap(transport.addChatTask("quick task", sessionID: vm.id))
        try await waitUntil("slow running") { transport.queue.task(slow.id)?.status == .running && vm.running }
        transport.removeChatTask(slow.id)
        try await waitUntil("next done") { transport.queue.task(next.id)?.status == .complete && idle(vm) }
        XCTAssertEqual(transport.queue.task(slow.id)?.status, .skipped)
        XCTAssertNil(transport.chatTasksPaused[vm.id])
    }

    func testAGoalTaskRunsAsAGoalAndCommandsJustRun() async throws {
        FakeModelServer.reset { _, _ in .text("Did it.\nGOAL_COMPLETE") }
        let vm = transport.newSession(cwd: project.path)
        transport.pauseChatTasks(vm.id)
        let think = try XCTUnwrap(transport.addChatTask("/think high", sessionID: vm.id))
        let goal = try XCTUnwrap(transport.addChatTask("/goal Ship the thing", sessionID: vm.id))
        transport.resumeChatTasks(vm.id)
        try await waitUntil("goal done") { transport.queue.task(goal.id)?.status == .complete && idle(vm) }
        XCTAssertEqual(transport.queue.task(think.id)?.status, .complete)
        XCTAssertEqual(vm.thinking, .high)
        let record = try XCTUnwrap(vm.promptHistory.last)
        XCTAssertEqual(record.source, .goal, "a goal stays a goal")
        XCTAssertEqual(record.text, "Ship the thing")
    }

    func testWaitingTasksArePausedWhenTheAppOpensAgain() async throws {
        FakeModelServer.reset { _, _ in .slow(5, "late") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("long", sessionID: vm.id)
        try await waitUntil("running") { vm.running }
        let waiting = try XCTUnwrap(transport.addChatTask("waits", sessionID: vm.id))
        transport.log.flush(wait: true)

        let again = makeTransport()
        XCTAssertEqual(again.chatTasksPaused[vm.id], ChatTaskRules.pausedAtLaunch)
        XCTAssertEqual(again.queue.task(waiting.id)?.status, .queued)
        XCTAssertNil(again.queue.nextTask, "the unattended queue never takes it")
    }

    // MARK: Current work and background activity

    func testTheCurrentWorkAndTheActivityListSayWhatRunsWhere() async throws {
        FakeModelServer.reset { _, _ in .slow(5, "late") }
        let vm = transport.newSession(cwd: project.path)
        transport.send("/goal Build the importer", sessionID: vm.id)
        try await waitUntil("running") { vm.running && vm.goal != nil && transport.turnRoute[vm.id] != nil }
        let work = try XCTUnwrap(transport.currentWork(for: vm))
        XCTAssertEqual(work.kind, "Goal")
        XCTAssertEqual(work.title, "Build the importer")
        transport.pauseChatTasks(vm.id)
        transport.addChatTask("then the exporter", sessionID: vm.id)

        let items = transport.activityItems()
        let main = try XCTUnwrap(items.first { $0.kind == .mainAgent })
        XCTAssertEqual(main.placement, "stub-model on stub")
        XCTAssertEqual(main.assignment, "Goal: Build the importer")
        let waiting = try XCTUnwrap(items.first { $0.kind == .chatTasks })
        XCTAssertEqual(waiting.title, "1 task up next")
        XCTAssertEqual(waiting.assignment, "Next: then the exporter")
        XCTAssertEqual(transport.activityCount, 1)

        transport.stopActivity(main)
        try await waitUntil("stopped") { idle(vm) }
        XCTAssertNil(transport.currentWork(for: vm))
    }
}
