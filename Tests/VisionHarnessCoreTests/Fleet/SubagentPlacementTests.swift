import XCTest
@testable import VisionHarnessCore

/// "I can't tell what models/agents are working on what, or if they're even being used properly": every subagent's
/// roster entry says the model and the route it really runs on, why it runs there when that isn't where its agent
/// file asked, its tokens and a stamped log — and a subagent on another route sends that route's settings, never the
/// main chat's.
final class SubagentPlacementTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() async throws { root = FleetTestDirectory("vision-placement") }
    override func tearDown() async throws { root.remove() }

    func testTheRosterSaysTheModelAndRouteEvenWithOneServer() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("only", FleetReportsClient("report"), primary: true)])
        let roster = AgentRoster()
        _ = await AgentTool().execute(args: #"{"description":"scan","prompt":"count the files"}"#,
                                      in: fleetContext(ScriptedClient(turns: []), root: root.url, fleet: fleet, roster: roster))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertNil(run.server, "the report and the old field still leave a lone server unnamed")
        XCTAssertEqual(run.route, "only")
        XCTAssertEqual(run.model, "model-only")
        XCTAssertEqual(run.placementLabel, "model-only on only")
        XCTAssertNil(run.placement)
        XCTAssertEqual(run.prompt, "count the files")
        XCTAssertEqual(run.log.map(\.text), ["Started (general)", "waiting for a free server", "Running on model-only · only",
                                             "writing the report", "Finished — report delivered"])
    }

    func testWithoutAFleetItRunsOnTheChatsOwnModel() async throws {
        let roster = AgentRoster()
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#,
                                      in: fleetContext(FleetReportsClient("ok"), root: root.url, roster: roster))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.placementLabel, "parent on this chat's model")
    }

    func testAnAgentFileAskingForAServerThatIsNotSetUpIsSaidOutLoud() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("main", FleetReportsClient("main"), primary: true),
                         fleetServer("spark-2", FleetReportsClient("spark-2"))])
        let catalog = AgentCatalog(AgentDefinition.builtIn + [AgentDefinition(name: "big", description: "d", server: "kimi")])
        let roster = AgentRoster()
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p","agent_type":"big"}"#,
                                      in: fleetContext(ScriptedClient(turns: []), root: root.url, fleet: fleet, roster: roster,
                                                       catalog: catalog))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.route, "spark-2")
        XCTAssertEqual(run.placement, "its agent file asks for “kimi”, but no model server by that name is set up (Settings ▸ AI Models: turn on “Use for subagents” for that route)")
    }

    func testAServerSkippedOnTheWayIsNamedWithItsReason() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("main", FleetReportsClient("main"), primary: true),
                         fleetDeadServer("spark-1", error: LLMError.connection("no route to host"))])
        let roster = AgentRoster()
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#,
                                      in: fleetContext(ScriptedClient(turns: []), root: root.url, fleet: fleet, roster: roster))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.route, "main")
        let note = try XCTUnwrap(run.placement)
        XCTAssertTrue(note.hasPrefix("tried first: spark-1: "), note)
        XCTAssertTrue(note.contains("no route to host"), note)
    }

    func testABusyPreferredServerIsNotBlamedOnTheSetup() {
        let fleet = AgentFleet()
        let spark = fleetServer("spark-2", FleetReportsClient("s"))
        let main = fleetServer("main", FleetReportsClient("m"), primary: true)
        fleet.configure([main, spark])
        let lease = FleetLease(fleet: fleet, server: main, target: FleetTarget(client: FleetReportsClient("m"), model: "m"))
        let note = AgentTool.placementNote(definition: AgentDefinition(name: "x", server: "spark-2"), lease: lease, fleet: fleet)
        XCTAssertEqual(note, "its agent file asks for “spark-2”, which was busy or not answering")
        let fine = FleetLease(fleet: fleet, server: spark, target: FleetTarget(client: FleetReportsClient("s"), model: "s"))
        XCTAssertNil(AgentTool.placementNote(definition: AgentDefinition(name: "x", server: "Spark-2"), lease: fine, fleet: fleet))
        XCTAssertTrue(AgentFleet.matches(spark, preferred: " SPARK "))
        XCTAssertFalse(AgentFleet.matches(spark, preferred: ""))
    }

    func testTokensAreCounted() async throws {
        let client = UsageClient()
        let roster = AgentRoster()
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#,
                                      in: fleetContext(client, root: root.url, roster: roster))
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(run.promptTokens, 1_200)
        XCTAssertEqual(run.completionTokens, 80)
    }

    // MARK: Settings: the route's own, never the main chat's

    /// A Kimi or GLM worker must not be sent the main route's temperature, max_tokens or reasoning effort.
    func testAWorkerOnAnotherRouteSendsItsOwnSettingsNotTheParents() async {
        let worker = FleetReportsClient("ok")
        let fleet = AgentFleet()
        fleet.configure([FleetServer(id: "kimi", label: "Kimi Code", isPrimary: false, maxParallel: 1, resolve: {
            FleetTarget(client: worker, model: "kimi-for-coding", contextWindow: 8_000, ownSettings: true)
        })])
        let ctx = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                              client: ScriptedClient(turns: []), registry: ToolRegistry.standard(), model: "qwen",
                              contextWindow: 8_000, thinking: .high, fleet: fleet, temperature: 0.7, maxOutputTokens: 32_000)
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: ctx)
        let request = worker.requests.first
        XCTAssertEqual(request?.model, "kimi-for-coding")
        XCTAssertNil(request?.temperature, "the route's default, not the main chat's 0.7")
        XCTAssertNil(request?.maxTokens, "the route's default, not the main chat's 32k")
        XCTAssertNil(request?.thinking, "the route's own thinking level, not the chat's 'high'")
    }

    func testAWorkerWithItsOwnValuesSendsThem() {
        let ctx = fleetContext(FleetReportsClient("p"), root: root.url)
        let target = FleetTarget(client: FleetReportsClient("w"), model: "w", temperature: 1.0, maxOutputTokens: 4_096,
                                 ownSettings: true, thinking: .low)
        let settings = AgentTool.settings(for: target, context: ctx)
        XCTAssertEqual(settings.temperature, 1.0)
        XCTAssertEqual(settings.maxOutputTokens, 4_096)
        XCTAssertEqual(settings.thinking, .low)
    }

    func testThePrimaryStillSharesTheChatsSettings() {
        let ctx = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                              client: FleetReportsClient("p"), registry: ToolRegistry.standard(), model: "qwen",
                              thinking: .high, temperature: 0.7, maxOutputTokens: 1_000)
        let primary = FleetTarget(client: FleetReportsClient("p"), model: "qwen")
        let settings = AgentTool.settings(for: primary, context: ctx)
        XCTAssertEqual(settings.temperature, 0.7)
        XCTAssertEqual(settings.maxOutputTokens, 1_000)
        XCTAssertEqual(settings.thinking, .high)
    }

    // MARK: The roster's own bookkeeping

    func testTheRosterKeepsAStampedBoundedLog() {
        let clock = FleetTestClock()
        let roster = AgentRoster(now: { clock.now })
        let id = roster.begin(description: "d", agentType: "explore", background: true, prompt: String(repeating: "x", count: 5_000))
        XCTAssertEqual(roster.run(id)?.prompt?.count, 2_000)
        roster.setPlacement(id, route: "Spark", model: "qwen")
        roster.setPlacement(id, route: "Bedrock", model: "haiku", note: "Spark failed")
        roster.setAssignment(id, "Step one")
        roster.setAssignment(id, "")
        for n in 0..<250 { roster.note(id, "step \(n)", step: true) }
        roster.note(id, "same")
        roster.note(id, "same")
        roster.addTokens(id, prompt: 10, completion: 2)
        roster.addTokens(id, prompt: 0, completion: 0)
        roster.finish(id, status: .failed, report: "it broke")
        let run = roster.run(id)!
        XCTAssertEqual(run.assignment, "Step one")
        XCTAssertEqual(run.route, "Bedrock")
        XCTAssertEqual(run.placement, "Spark failed")
        XCTAssertEqual(run.steps, 250)
        XCTAssertEqual(run.log.count, 200)
        XCTAssertEqual(run.log.last?.text, "Failed: it broke")
        XCTAssertEqual(run.log.filter { $0.text == "same" }.count, 1, "a repeated activity is logged once")
        XCTAssertEqual(run.promptTokens, 10)
        XCTAssertEqual(run.log.first?.at, clock.now)
    }
}

/// Answers with a report and a usage line.
private final class UsageClient: LLMClient, @unchecked Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("done"))
            continuation.yield(.done(calls: [], finish: "stop", usage: LLMUsage(promptTokens: 1_200, completionTokens: 80)))
            continuation.finish()
        }
    }
    func listModels() async throws -> [String] { ["m"] }
}
