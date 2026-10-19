import XCTest
@testable import VisionHarnessCore

final class AgentToolTests: XCTestCase {

    private func testRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vision-agenttool-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Compaction.plan: the assistant-boundary escape hatch

    /// One user message, then many assistant(+tool call)/tool-result rounds —
    /// exactly the shape of a subagent's entire run (it never gets a second
    /// `.user` message).
    private func toolMarathon(rounds: Int) -> [LLMMessage] {
        var out: [LLMMessage] = [.user("start " + String(repeating: "a", count: 4_000))]
        for i in 0..<rounds {
            let call = ToolCall(id: "c\(i)", name: "read_file", arguments: "{\"path\":\"f\(i)\"}")
            out.append(.assistant("round \(i) " + String(repeating: "b", count: 4_000), calls: [call]))
            out.append(.toolResult(id: "c\(i)", name: "read_file", output: "result \(i)"))
        }
        return out
    }

    func testPlanWithoutFlagFallsBackToAssistantBoundaryForASingleTurnToolMarathon() {
        // With only one `.user` message in the whole transcript the user-only
        // rule has no boundary to cut at; rather than run into the server's
        // hard limit, the plan falls back to an assistant boundary.
        let msgs = toolMarathon(rounds: 20)
        let used = TokenEstimate.request(systemPrompt: "", messages: msgs)
        let plan = Compaction.plan(usedTokens: used, limit: 8_000, transcript: msgs)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.toKeep.first?.role, .assistant)
    }

    func testPlanWithAssistantBoundaryCompactsASingleTurnToolMarathon() {
        let msgs = toolMarathon(rounds: 20)
        let used = TokenEstimate.request(systemPrompt: "", messages: msgs)
        guard let plan = Compaction.plan(usedTokens: used, limit: 8_000, transcript: msgs,
                                         allowAssistantBoundary: true) else {
            return XCTFail("expected a plan once assistant boundaries are allowed")
        }
        // The kept tail must start at a complete round: the assistant's call
        // together with its own result, never split from it.
        XCTAssertEqual(plan.toKeep.first?.role, .assistant)
        guard let call = plan.toKeep.first?.toolCalls?.first else {
            return XCTFail("expected the boundary assistant message to carry its tool call")
        }
        XCTAssertEqual(plan.toKeep.dropFirst().first?.toolCallID, call.id,
                       "the kept assistant's own tool result must follow it, never left behind")
        XCTAssertEqual(plan.toSummarize.count + plan.toKeep.count, msgs.count)
        XCTAssertGreaterThanOrEqual(plan.toSummarize.count, Compaction.minSummarizable)
    }

    // MARK: - Compaction.summarize (generic over any LLMClient)

    func testCompactionSummarizeReturnsTrimmedModelText() async throws {
        let client = ScriptedClient(turns: [.init(text: "  a continuity note  ")])
        let plan = Compaction.Plan(toSummarize: [.user("old"), .assistant("a"), .user("more"), .assistant("b")],
                                   toKeep: [.user("recent")], usedTokens: 1_000, limit: 10_000)
        let summary = await Compaction.summarize(client: client, plan: plan)
        XCTAssertEqual(summary, "a continuity note")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(client.requests[0].tools.isEmpty)
        XCTAssertEqual(client.requests[0].thinking, .off, "summaries are written with thinking off")
    }

    func testCompactionSummarizeReturnsNilOnClientFailure() async throws {
        final class ThrowingClient: LLMClient, @unchecked Sendable {
            func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: LLMError.sse("boom"))
                }
            }
            func listModels() async throws -> [String] { [] }
        }
        let plan = Compaction.Plan(toSummarize: [.user("old"), .assistant("a"), .user("more"), .assistant("b")],
                                   toKeep: [.user("recent")], usedTokens: 1_000, limit: 10_000)
        let summary = await Compaction.summarize(client: ThrowingClient(), plan: plan)
        XCTAssertNil(summary)
    }

    // MARK: - Engine → ToolContext wiring

    /// Records the `ToolContext` it was handed, so a test can inspect what
    /// the engine threaded through to a tool (and, transitively, to any
    /// subagent that tool spawns).
    private final class CapturingTool: ToolExecutor, @unchecked Sendable {
        static let name = "capture"
        static let spec = ToolSpec(name: name, description: "capture", parameters: "{}")
        private(set) var captured: ToolContext?
        func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
            captured = context
            return ToolResult(output: "ok")
        }
    }

    func testToolContextCarriesTheEnginesContextWindow() async throws {
        let call = ToolCall(id: "c1", name: "capture", arguments: "{}")
        let client = ScriptedClient(turns: [
            .init(text: "checking", calls: [call]),
            .init(text: "done"),
        ])
        let tool = CapturingTool()
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine(client: client,
                            registry: ToolRegistry(tools: [tool]),
                            systemPrompt: "system",
                            config: .init(model: "test", contextWindow: 12_345),
                            workspace: root,
                            policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                            permissionGate: { _, _, _ in true })
        _ = try await engine.run(messages: [], userText: "go", sink: { _ in })

        XCTAssertEqual(tool.captured?.contextWindow, 12_345,
                       "a tool (and any subagent it spawns) must see the engine's resolved window")
    }

    // MARK: - AgentTool: subagents actually auto-compact

    /// Serves both a subagent's ordinary turns and its internal
    /// summarization calls from one client (as a real `OpenAIClient` would),
    /// distinguishing them by shape (a summarization request has no tools,
    /// thinking off, and exactly one user message) rather than by
    /// call order.
    private final class SubagentClient: LLMClient, @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [ScriptedClient.Turn]
        private(set) var requests: [LLMRequest] = []
        init(turns: [ScriptedClient.Turn]) { self.turns = turns }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            lock.lock()
            requests.append(request)
            let isSummaryRequest = request.tools.isEmpty && request.thinking == .off
                && request.messages.count == 1 && request.messages[0].role == .user
            let turn: ScriptedClient.Turn
            if isSummaryRequest {
                turn = .init(text: "SUMMARY")
            } else {
                turn = turns.isEmpty ? .init(text: "done") : turns.removeFirst()
            }
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for chunk in turn.text.map(String.init) { continuation.yield(.text(chunk)) }
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: turn.usage))
                continuation.finish()
            }
        }
        func listModels() async throws -> [String] { ["x"] }
    }

    func testAgentToolAutoCompactsALongSubagentRun() async throws {
        // Each round: a large assistant text + a todo_write call, so the
        // subagent's own transcript grows across its internal iterations
        // exactly like the top-level session's does — but a subagent never
        // gets a second `.user` message (see the Compaction.plan tests
        // above), which used to mean it could never compact at all.
        let bigText = String(repeating: "a", count: 4_000)
        var turns: [ScriptedClient.Turn] = []
        for i in 0..<12 {
            // (A different list each round: the same list sent over and over is a loop, which an engine may end.)
            let call = ToolCall(id: "t\(i)", name: "todo_write",
                                arguments: #"{"todos":[{"content":"step \#(i)","status":"pending"}]}"#)
            turns.append(.init(text: bigText, calls: [call]))
        }
        turns.append(.init(text: "final report"))
        let client = SubagentClient(turns: turns)

        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(workspace: root,
                                  policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root),
                                  client: client, registry: ToolRegistry.standard(),
                                  depth: 0, model: "test", contextWindow: 8_000,
                                  requestPermission: { _, _, _ in true })

        let result = await AgentTool().execute(
            args: #"{"description":"scan","prompt":"go look at things"}"#,
            in: context)

        XCTAssertTrue(result.output.contains("final report"),
                      "the subagent must finish despite a tiny window: \(result.output)")

        // Real turns always carry the tool specs; the interleaved
        // summarization calls never do, so filtering isolates them.
        let mainRequestSizes = client.requests.filter { !$0.tools.isEmpty }.map { $0.messages.count }
        let shrank = zip(mainRequestSizes, mainRequestSizes.dropFirst()).contains { prev, next in next < prev }
        XCTAssertTrue(shrank, "expected at least one request to shrink after compaction fired; sizes=\(mainRequestSizes)")
    }
}


/// The agent tool's argument checks, its depth limit and how it reports a failure.
final class AgentToolGuardTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        root = FleetTestDirectory("vision-agentguard")
    }

    override func tearDown() {
        root.remove()
        super.tearDown()
    }

    private func context(_ client: any LLMClient, depth: Int = 0) -> ToolContext {
        ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                    client: client, registry: ToolRegistry.standard(depth: depth), depth: depth, model: "test")
    }

    func testDepthOneRefusesNestedAgents() async {
        let client = ScriptedClient(turns: [])
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: context(client, depth: 1))
        XCTAssertEqual(result.output, "Error: nested subagents are not allowed (depth limit).")
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testPromptIsRequired() async {
        let result = await AgentTool().execute(args: #"{"description":"d"}"#, in: context(ScriptedClient(turns: [])))
        XCTAssertEqual(result.output, "Error: prompt is required.")
    }

    func testClientFailureIsReportedNotThrown() async {
        // A permanent error: transient ones (a cut-off stream) are retried until the server answers.
        let client = FlakyClient(failures: Int.max, error: LLMError.http(401, "boom"), turns: [])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#, in: context(client))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' failed: "), result.output)
        XCTAssertTrue(result.output.contains("boom"), result.output)
    }

    func testEmptyFinalTextStillProducesAReport() async {
        let result = await AgentTool().execute(args: #"{"prompt":"p"}"#, in: context(ScriptedClient(turns: [.init(text: "")])))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'subagent' finished."), result.output)
        XCTAssertTrue(result.output.contains("without a final report"), result.output)
    }

    func testRunIsTheGeneralForegroundEntryPoint() async {
        let client = FleetReportsClient("the answer")
        let outcome = await AgentTool.run(desc: "scan", prompt: "p", context: context(client))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.report, "the answer")
        let failed = await AgentTool.run(desc: "scan", prompt: "p",
                                         context: context(FlakyClient(failures: Int.max, error: LLMError.http(401, "no key"), turns: [])))
        XCTAssertFalse(failed.ok)
        XCTAssertTrue(failed.report.contains("no key"), failed.report)
    }

    func testRegistryOnlyOffersTheAgentToolAtTheTopLevel() {
        XCTAssertTrue(ToolRegistry.standard(depth: 0).names.contains(AgentTool.name))
        XCTAssertFalse(ToolRegistry.standard(depth: 1).names.contains(AgentTool.name))
    }

    func testSubagentPromptStatesWorkspaceAndPreset() {
        let prompt = AgentTool.subagentPrompt(workspace: root.url, permissionPreset: .plan)
        XCTAssertTrue(prompt.hasPrefix("You are a focused subagent."))
        XCTAssertTrue(prompt.contains("Workspace: \(root.url.path)"))
        XCTAssertTrue(prompt.contains("Permission preset: plan"))
        // An agent type adds its own instructions after the standard ones.
        let typed = AgentTool.subagentPrompt(workspace: root.url, permissionPreset: .plan,
                                             definition: AgentDefinition(name: "x", prompt: "Be brief."))
        XCTAssertTrue(typed.hasPrefix(prompt))
        XCTAssertTrue(typed.hasSuffix("\n\nBe brief."))
    }

    func testAnOutcomeDescribesWhereAndHowLongItRan() {
        XCTAssertEqual(SubagentOutcome(ok: true, report: "r", agentType: "general").details(), "")
        XCTAssertEqual(SubagentOutcome(ok: true, report: "r", agentType: "General", elapsed: 34).details(), "")
        XCTAssertEqual(SubagentOutcome(ok: true, report: "r", agentType: "explore", elapsed: 34).details(),
                       "(explore agent · 34s)")
        XCTAssertEqual(SubagentOutcome(ok: true, report: "r", agentType: "general", server: "spark-2", elapsed: 162).details(),
                       "(on spark-2 · 2m 42s)")
        XCTAssertEqual(SubagentOutcome(ok: true, report: "r", agentType: "review", server: "spark-2", elapsed: 3, failovers: 1).details(),
                       "(review agent · on spark-2 · after 1 server failure · 3s)")
        XCTAssertEqual(SubagentOutcome(ok: false, report: "r", agentType: "general", elapsed: 3, failovers: 2).details(),
                       "(after 2 server failures · 3s)")
    }

    func testTheReportKeepsAFixedFirstLine() {
        let done = SubagentOutcome(ok: true, report: "the report", agentType: "explore", server: "s", elapsed: 5)
        XCTAssertEqual(AgentTool.present(description: "scan", outcome: done),
                       "Subagent 'scan' finished.\n(explore agent · on s · 5s)\n\nthe report")
        let failed = SubagentOutcome(ok: false, report: "no key", agentType: "general")
        XCTAssertEqual(AgentTool.present(description: "scan", outcome: failed), "Subagent 'scan' failed: no key")
    }
}

/// A subagent at the machine (review: its work never lit the glow, ⌃⌥⌘. didn't reach it, and it had approvals of its
/// own): its machine tools are reported on its seat, and it uses — and loses — the chat's computer approvals.
final class SubagentMachineWorkTests: XCTestCase {
    struct FakeScreenshot: ToolExecutor {
        static let name = "screenshot"
        static let spec = ToolSpec(name: name, description: "a fake screenshot", parameters: "{}")
        func execute(args: JSONString, in context: ToolContext) async -> ToolResult { ToolResult(output: "a picture") }
    }

    private var root: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        root = FleetTestDirectory("vision-submachine")
    }

    override func tearDown() {
        root.remove()
        super.tearDown()
    }

    private func run(seat: MachineSeat, grants: ComputerGrants, asked: Recorder<String>) async -> ToolResult {
        let client = ScriptedClient(turns: [.init(calls: [ToolCall(id: "c1", name: "screenshot", arguments: "{}")]),
                                            .init(text: "saw it")])
        let context = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                                  client: client, registry: ToolRegistry(tools: [FakeScreenshot()]), model: "test",
                                  requestPermission: { _, _, detail in asked.append(detail); return false },
                                  machine: seat, computerGrants: grants)
        return await AgentTool().execute(args: #"{"description":"look","prompt":"take a screenshot"}"#, in: context)
    }

    func testASubagentsMachineToolsAreReportedOnItsSeatAndUseTheChatsApprovals() async throws {
        let seat = MachineSeat.detached()
        let holders = Recorder<String>()
        let work = Recorder<MachineToolWork>()
        seat.onToolWork = { holder, item in holders.append(holder); work.append(item) }
        let grants = ComputerGrants()
        grants.grant(.control)
        let asked = Recorder<String>()

        let result = await run(seat: seat, grants: grants, asked: asked)
        XCTAssertTrue(result.output.contains("saw it"), result.output)
        XCTAssertTrue(asked.values.isEmpty, "the chat allowed control: its subagent doesn't ask again")
        XCTAssertEqual(work.values, [.started(tool: "screenshot"), .finished, .ended])
        XCTAssertEqual(Set(holders.values).count, 1)
        XCTAssertTrue(holders.values.allSatisfy { $0.hasPrefix(seat.holderID + "/sub") }, "\(holders.values)")

        // ⌃⌥⌘. revokes the chat's approvals: the next subagent asks before it looks at the screen.
        grants.revokeAll()
        _ = await run(seat: seat, grants: grants, asked: asked)
        XCTAssertEqual(asked.values.count, 1)
    }
}
