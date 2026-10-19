import XCTest
@testable import VisionHarnessCore

/// The primary picks where a subagent runs (`server`): a busy pick is waited for, then another server runs it and the
/// report says so; an unknown pick is an error before anything starts; Claude Code works a task as one `claude -p` job.
final class SubagentPinTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() async throws { root = FleetTestDirectory("vision-pins") }
    override func tearDown() async throws { root.remove() }

    private func server(_ name: String, handle: String, max: Int = 1, isPrivate: Bool = true, client: (any LLMClient)? = nil,
                        resolve: (@Sendable () async throws -> FleetTarget)? = nil) -> FleetServer {
        let client = client ?? FleetReportsClient("report from \(handle)")
        return FleetServer(id: "\(name)|m", label: name, maxParallel: max, isPrivate: isPrivate, handle: handle,
                           resolve: resolve ?? { FleetTarget(client: client, model: "model-" + handle, contextWindow: 8_000) })
    }

    private func home(max: Int = 4) -> FleetServer {
        FleetServer(id: "Spark A|q", label: "Spark A", isPrimary: true, maxParallel: max, handle: "primary", isHome: true) {
            FleetTarget(client: FleetReportsClient("report from primary"), model: "model-primary", contextWindow: 8_000)
        }
    }

    private func entry(_ server: FleetServer, primary: Bool = false) -> SubagentPool.Entry {
        SubagentPool.Entry(id: server.handle ?? server.label, routeID: server.id, label: server.label, provider: "p", model: "m",
                           context: nil, isPrivate: server.isPrivate, tier: .local, speed: .standard, images: true,
                           ownAgent: false, parallel: server.maxParallel, machine: "route:" + server.id,
                           kind: .openAICompatible, interactiveOnly: false, isPrimary: primary)
    }

    private func pool(_ servers: [FleetServer], home: FleetServer) -> SubagentPool {
        SubagentPool(entries: servers.map { entry($0) } + [entry(home, primary: true)])
    }

    private func context(fleet: AgentFleet, pool: SubagentPool, home: FleetServer, roster: AgentRoster? = nil,
                         client: any LLMClient = FleetReportsClient("parent")) -> ToolContext {
        var context = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                                  client: client, registry: ToolRegistry.standard(), model: "parent",
                                  fleet: fleet, roster: roster, retry: fleetFastRetry, fleetHome: home)
        context.fleetPool = pool
        return context
    }

    // MARK: The fleet's wait

    func testAPinReleasedInsideTheWaitRunsThere() async throws {
        let fleet = AgentFleet()
        fleet.pinWait = 10
        let spark = server("Spark 2", handle: "spark-2"), bedrock = server("Amazon Bedrock", handle: "bedrock", max: 4)
        fleet.configure([spark, bedrock])
        let own = home()
        let held = try await fleet.acquire(FleetRequest(pinned: spark.id, home: own))
        let waiting = FleetPending { try await fleet.acquire(FleetRequest(pinned: spark.id, home: own)) }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(waiting.isDone, "the primary picked spark-2: it waits rather than go to bedrock")
        held.release()
        let lease = try await waiting.value()
        XCTAssertEqual(lease.handle, "spark-2")
        XCTAssertEqual(lease.reason, .picked)
        XCTAssertNil(lease.note)
        lease.release()
    }

    func testAPinThatStaysBusyFallsBackWithTheNote() async throws {
        let fleet = AgentFleet()
        fleet.pinWait = 0.2
        let spark = server("Spark 2", handle: "spark-2"), bedrock = server("Amazon Bedrock", handle: "bedrock", max: 4)
        fleet.configure([spark, bedrock])
        let own = home()
        let held = try await fleet.acquire(FleetRequest(pinned: spark.id, home: own))
        let lease = try await fleetBounded(5) { try await fleet.acquire(FleetRequest(pinned: spark.id, home: own)) }
        XCTAssertEqual(lease.handle, "bedrock")
        XCTAssertEqual(lease.reason, .fallback)
        XCTAssertTrue(lease.note?.hasPrefix("spark-2 stayed busy for") == true, lease.note ?? "")
        lease.release()
        held.release()
    }

    func testCancellingDuringAPinWaitLeaksNoSlot() async throws {
        let fleet = AgentFleet()
        fleet.pinWait = 30
        let spark = server("Spark 2", handle: "spark-2")
        fleet.configure([spark, server("Amazon Bedrock", handle: "bedrock")])
        let own = home()
        let held = try await fleet.acquire(FleetRequest(pinned: spark.id, home: own))
        let waiting = FleetPending { try await fleet.acquire(FleetRequest(pinned: spark.id, home: own)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value()
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError || error is FleetTestTimeout, "\(error)")
        }
        XCTAssertEqual(fleet.snapshot().map(\.inFlight).reduce(0, +), 1, "only the held slot")
        held.release()
        XCTAssertEqual(fleet.snapshot().map(\.inFlight).reduce(0, +), 0)
    }

    func testAChatsOwnModelThatServesAnotherChatSharesOneCount() async throws {
        let fleet = AgentFleet()
        // Route R is chat A's own model, and a subagent server for chat B (on S).
        let r = server("R", handle: "r", max: 1)
        fleet.configure([r])
        let chatB = FleetServer(id: "S|m", label: "S", isPrimary: true, maxParallel: 4, handle: "primary", isHome: true) {
            FleetTarget(client: FleetReportsClient("s"), model: "s")
        }
        let chatA = FleetServer(id: r.id, label: "R", isPrimary: true, maxParallel: 1, handle: "primary", isHome: true) {
            FleetTarget(client: FleetReportsClient("r"), model: "r")
        }
        let forB = try await fleet.acquire(FleetRequest(home: chatB, pool: [r.id]))
        XCTAssertEqual(forB.label, "R")
        let forA = FleetPending { try await fleet.acquire(FleetRequest(home: chatA, pool: [])) }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertFalse(forA.isDone, "R is busy with chat B's subagent: one count, not one per chat")
        forB.release()
        let lease = try await forA.value()
        XCTAssertEqual(lease.label, "R")
        XCTAssertEqual(fleet.snapshot().first { $0.id == r.id }?.inFlight, 1)
        lease.release()
    }

    func testAChatsOwnModelIsListedWhileItsSubagentsRunOnIt() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("Spark 2", handle: "spark-2")])
        let own = home()
        let first = try await fleet.acquire(FleetRequest(home: own))
        let second = try await fleet.acquire(FleetRequest(home: own))
        XCTAssertEqual(second.handle, "primary")
        let listed = fleet.snapshot()
        XCTAssertEqual(listed.map(\.role), ["worker", "home"])
        XCTAssertEqual(listed.last?.label, "Spark A")
        first.release(); second.release()
        XCTAssertEqual(fleet.snapshot().map(\.role), ["worker"], "gone once its subagents are done")
    }

    func testAUsageLimitKeepsAServerOffUntilItResets() async throws {
        let clock = FleetTestClock()
        let fleet = AgentFleet(now: { clock.now })
        let claude = server("Claude Code", handle: "claude-code-sonnet", max: 2)
        fleet.configure([claude])
        let reset = clock.now.addingTimeInterval(3_600)
        var lease = try await fleet.acquire()
        lease.fail(SubagentServerPaused(message: "You've reached your Claude plan's limit.", until: reset))
        lease.release()
        XCTAssertEqual(fleet.snapshot().first?.unhealthyUntil, reset)
        clock.advance(seconds: 3_601)
        lease = try await fleet.acquire()
        lease.release()
        lease = try await fleet.acquire()
        lease.fail(ClaudeCodeError.rateLimited("limit"))
        lease.release()
        XCTAssertEqual(fleet.snapshot().first?.unhealthyUntil, clock.now.addingTimeInterval(15 * 60), "no reset time: 15 minutes")
        XCTAssertTrue(AgentFleet.isServerFault(ClaudeCodeError.notSignedIn))
        XCTAssertTrue(AgentFleet.isServerFault(ClaudeCodeError.notInstalled("no claude")))
        XCTAssertFalse(AgentFleet.isServerFault(ClaudeCodeError.failed("the task broke")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.rejected(status: 401, message: GuardianSignInNeeded.message, body: "", permanent: true)))
    }

    // MARK: The tools

    func testAnUnknownServerIsAnErrorAndNothingStarts() async throws {
        let fleet = AgentFleet()
        let spark = server("Spark 2", handle: "spark-2")
        fleet.configure([spark])
        let own = home(), roster = AgentRoster()
        let ctx = context(fleet: fleet, pool: pool([spark], home: own), home: own, roster: roster)
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p","server":"kimi"}"#, in: ctx)
        XCTAssertEqual(result.output, "Error: “kimi” isn't one of this chat's subagent servers. Use one of: spark-2, primary — or leave server out.")
        XCTAssertTrue(roster.all.isEmpty, "no subagent was started")
    }

    func testDelegateChecksEveryServerBeforeAnyTaskRuns() async throws {
        let fleet = AgentFleet()
        let client = FleetReportsClient("ran")
        let spark = server("Spark 2", handle: "spark-2", max: 4, client: client)
        fleet.configure([spark])
        let own = home(), roster = AgentRoster()
        let ctx = context(fleet: fleet, pool: pool([spark], home: own), home: own, roster: roster)
        let result = await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"p","server":"spark-2"},{"description":"b","prompt":"p"},{"description":"c","prompt":"p","server":"nope"}]}"#, in: ctx)
        XCTAssertEqual(result.output, "Error: task 3: “nope” isn't one of this chat's subagent servers. Use one of: spark-2, primary — or leave server out.")
        XCTAssertTrue(roster.all.isEmpty)
        XCTAssertTrue(client.requests.isEmpty, "task 1 never ran")
    }

    func testResultsSayWhereItRanAndHowBusyTheServersAre() async throws {
        let fleet = AgentFleet()
        let spark = server("Spark 2", handle: "spark-2"), bedrock = server("Amazon Bedrock", handle: "bedrock", max: 4)
        fleet.configure([spark, bedrock])
        let own = home(), roster = AgentRoster()
        let ctx = context(fleet: fleet, pool: pool([spark, bedrock], home: own), home: own, roster: roster)
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p","server":"bedrock"}"#, in: ctx)
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' finished.\n(on bedrock · "), result.output)
        XCTAssertTrue(result.output.hasSuffix("\n\nSubagent servers now: spark-2 0/1 busy · bedrock 0/4 busy · primary 0/4 busy."), result.output)
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.placementReason, "picked")
        XCTAssertTrue(run.log.contains { $0.text == "Running on model-bedrock · Amazon Bedrock — picked by the primary" }, "\(run.log.map(\.text))")

        let delegated = await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"p"}]}"#, in: ctx)
        XCTAssertTrue(delegated.output.hasPrefix("Delegated 1 task: 1 finished, 0 failed.\n\nSubagent servers now: "), delegated.output)
        XCTAssertTrue(delegated.output.contains("## 1. a — finished (on spark-2 · "), delegated.output)

        let status = await AgentStatusTool().execute(args: "{}", in: ctx)
        XCTAssertEqual(status.output, "Error: background agents aren't available here.", "no pool of background agents here")
    }

    func testAPickThatCantTakeTheTaskIsReportedToTheParent() async throws {
        let fleet = AgentFleet()
        let dead = server("Spark 2", handle: "spark-2", resolve: { throw LLMError.connection("no route to host") })
        let bedrock = server("Amazon Bedrock", handle: "bedrock", max: 4)
        fleet.configure([dead, bedrock])
        let own = home(), roster = AgentRoster()
        let ctx = context(fleet: fleet, pool: pool([dead, bedrock], home: own), home: own, roster: roster)
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p","server":"spark-2"}"#, in: ctx)
        XCTAssertTrue(result.output.contains("(on bedrock · "), result.output)
        XCTAssertTrue(result.output.contains("\nRan on bedrock instead of spark-2: spark-2 isn't answering ("), result.output)
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.placementReason, "fallback")
        XCTAssertTrue(run.placement?.hasPrefix("spark-2 isn't answering") == true, run.placement ?? "")
    }

    // MARK: Claude Code as a subagent server

    private func claudeServer(_ launcher: ReplayLauncher) -> FleetServer {
        let install = ClaudeCodeInstall(path: "/usr/local/bin/claude", version: "2.1.299",
                                        flags: ["--no-session-persistence", "--append-system-prompt"])
        return FleetServer(id: "Claude Code|sonnet", label: "Claude Code", maxParallel: 2, isPrivate: false,
                           handle: "claude-code-sonnet", kind: "claude-code") {
            FleetTarget(client: FleetReportsClient("never"), model: "sonnet", contextWindow: 200_000, vision: false,
                        ownSettings: true, external: ClaudeCodeSubagent(install: install, launcher: launcher, environment: [:],
                                                                        model: "sonnet"))
        }
    }

    func testAClaudeCodeJobRunsInTheChatsFolderAndReportsBack() async throws {
        let capture = try String(contentsOf: SubagentPoolFixtureTests.folder.appendingPathComponent("read-edit.jsonl"), encoding: .utf8)
        let launcher = ReplayLauncher(lines: capture.split(separator: "\n").map(String.init))
        let fleet = AgentFleet()
        let claude = claudeServer(launcher)
        fleet.configure([claude])
        let own = home(), roster = AgentRoster()
        let ctx = context(fleet: fleet, pool: pool([claude], home: own), home: own, roster: roster)
        let result = await AgentTool().execute(args: #"{"description":"look","prompt":"read hello.txt","agent_type":"explore","server":"claude-code-sonnet"}"#, in: ctx)
        XCTAssertTrue(result.output.contains("(explore agent · on claude-code-sonnet · "), result.output)
        XCTAssertTrue(result.output.contains("Edited hello.txt.\n\nClaude Code's tool calls: read_file /work/proj2/hello.txt; edit /work/proj2/hello.txt."), result.output)
        let args = try XCTUnwrap(launcher.arguments)
        XCTAssertEqual(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }, "plan", "a read-only type works in Plan only")
        XCTAssertEqual(args.firstIndex(of: "--max-turns").map { args[$0 + 1] }, "40", "the explore type's step budget")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        let note = try XCTUnwrap(args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] })
        XCTAssertTrue(note.hasPrefix(ClaudeCodeSubagent.note + "\n\nYou are a read-only investigator."), note)
        XCTAssertEqual(launcher.workingDirectory?.standardizedFileURL.path, root.url.standardizedFileURL.path)
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.steps, 2)
        XCTAssertEqual(run.promptTokens, 16_500)
        XCTAssertTrue(run.log.contains { $0.text.contains("at API prices (paid by your Claude plan)") }, "\(run.log.map(\.text))")
    }

    func testClaudeCodeSignedOutHandsTheTaskOnWithTheNote() async throws {
        let launcher = ReplayLauncher(lines: ClaudeCodeFixtures.notLoggedIn.split(separator: "\n").map(String.init), exitCode: 1)
        let fleet = AgentFleet()
        let claude = claudeServer(launcher), bedrock = server("Amazon Bedrock", handle: "bedrock", max: 4)
        fleet.configure([claude, bedrock])
        let own = home()
        let ctx = context(fleet: fleet, pool: pool([claude, bedrock], home: own), home: own)
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p","server":"claude-code-sonnet"}"#, in: ctx)
        XCTAssertTrue(result.output.contains("(on bedrock · after 1 server failure · "), result.output)
        XCTAssertTrue(result.output.contains("Ran on bedrock instead of claude-code-sonnet: claude-code-sonnet failed (Claude Code isn't signed in"),
                      result.output)
        XCTAssertEqual(fleet.snapshot().first { $0.id == claude.id }?.healthy, false, "kept off for a while")
    }

    func testStoppingAClaudeCodeJobStopsTheCLI() async throws {
        let launcher = ReplayLauncher(lines: [], waitForCancel: true)
        let subagent = ClaudeCodeSubagent(install: ClaudeCodeInstall(path: "/usr/local/bin/claude", version: "2.1.299",
                                                                     flags: ["--session-id"]),
                                          launcher: launcher, environment: [:], model: "sonnet")
        let workspace = root.url
        let job = FleetPending {
            try await subagent.run(ExternalSubagentJob(prompt: "p", systemNote: "n", workspace: workspace, preset: .workspaceWrite,
                                                       readOnly: false, maxSteps: 30))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        job.cancel()
        do {
            _ = try await job.value()
            XCTFail("stopped")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let args = try XCTUnwrap(launcher.arguments)
        XCTAssertTrue(args.contains("--session-id"), "without --no-session-persistence a fresh session id keeps it apart")
    }
}
