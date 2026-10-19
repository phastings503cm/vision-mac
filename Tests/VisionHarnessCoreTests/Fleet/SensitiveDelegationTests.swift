import XCTest
@testable import VisionHarnessCore

/// A subagent task marked `sensitive` runs only on a private server — and the main agent is told which servers are
/// private.
final class SensitiveDelegationTests: XCTestCase {
    private var dir: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        dir = FleetTestDirectory("vision-sensitive")
    }

    override func tearDown() {
        dir.remove()
        super.tearDown()
    }

    private func server(_ id: String, primary: Bool = false, max: Int = 2, private isPrivate: Bool) -> FleetServer {
        FleetServer(id: id, label: id, isPrimary: primary, maxParallel: max, isPrivate: isPrivate) {
            FleetTarget(client: FleetReportsClient("report from \(id)"), model: "model-" + id, contextWindow: 8_000)
        }
    }

    // MARK: The fleet

    func testASensitiveTaskGoesToAPrivateWorkerEvenWhenAnotherIsFreer() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("primary", primary: true, private: false), server("kimi", max: 4, private: false),
                         server("spark-2", max: 1, private: true)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark-2")
        // An ordinary task still goes where there is room.
        let ordinary = try await fleet.acquire()
        XCTAssertEqual(ordinary.label, "kimi")
        lease.release()
        ordinary.release()
    }

    func testWithoutAPrivateWorkerItRunsOnAPrivatePrimaryThatMayTakeSubagents() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("spark", primary: true, private: true), server("kimi", private: false)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark")
        lease.release()
    }

    func testOtherwiseTheModelIsToldToDoItItself() async {
        let notAllowed = AgentFleet()
        notAllowed.usePrimaryWhenWorkersBusy = false
        notAllowed.configure([server("spark", primary: true, private: true), server("kimi", private: false)])
        let notPrivate = AgentFleet()
        notPrivate.configure([server("openai", primary: true, private: false), server("kimi", private: false)])
        for fleet in [notAllowed, notPrivate] {
            do {
                _ = try await fleet.acquire(sensitive: true)
                XCTFail("nothing private may take it")
            } catch let error as FleetUnavailableError {
                XCTAssertEqual(error.message, "No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again.")
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testAPrivateServerOnItsOwnTakesSensitiveTasks() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("spark", primary: true, private: true)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark", "with no workers at all, the one server is the subagent server")
        lease.release()
    }

    func testABusyPrivateWorkerIsWaitedForOrOverflowsToAPrivatePrimary() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("primary", primary: true, private: true), server("kimi", private: false),
                         server("spark-2", max: 1, private: true)])
        let held = try await fleet.acquire(sensitive: true)
        let waiting = FleetPending { try await fleet.acquire(sensitive: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(waiting.isDone, "it waits for the private worker rather than going to kimi")
        held.release()
        let lease = try await waiting.value()
        XCTAssertEqual(lease.label, "spark-2")
        // With the primary allowed, the overflow goes there instead of waiting.
        fleet.usePrimaryWhenWorkersBusy = true
        let overflow = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(overflow.label, "primary")
        lease.release()
        overflow.release()
    }

    func testThePrivateWorkerBeingDownEndsInAnAnswerNotAWait() async throws {
        // A private primary that may not take subagents, and the only private worker offline.
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("spark", primary: true, max: 4, private: true),
                         FleetServer(id: "spark-2", label: "spark-2", isPrimary: false, maxParallel: 2, isPrivate: true) {
                             throw LLMError.connection("offline")
                         }])
        do {
            _ = try await FleetPending { try await fleet.acquire(sensitive: true) }.value(within: 3)
            XCTFail("nothing private may take it")
        } catch let error as FleetUnavailableError {
            XCTAssertEqual(error.message, AgentFleet.noPrivateServer)
        }
        // An ordinary task still runs, on the primary.
        let ordinary = try await fleet.acquire()
        XCTAssertEqual(ordinary.label, "spark")
        ordinary.release()
        // With the primary allowed to take subagents, the sensitive task goes there instead.
        fleet.usePrimaryWhenWorkersBusy = true
        let lease = try await FleetPending { try await fleet.acquire(sensitive: true) }.value(within: 3)
        XCTAssertEqual(lease.label, "spark")
        lease.release()
    }

    func testUnattendedWorkKeepsOffInteractiveOnlyServers() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("spark", primary: true, private: true),
                         FleetServer(id: "qwen", label: "qwen", maxParallel: 2, isPrivate: false, interactiveOnly: true) {
                             FleetTarget(client: FleetReportsClient("from qwen"), model: "qwen", contextWindow: 8_000)
                         }])
        let ordinary = try await fleet.acquire()
        XCTAssertEqual(ordinary.label, "qwen")
        ordinary.release()
        let unattended = try await fleet.acquire(unattended: true)
        XCTAssertEqual(unattended.label, "spark", "the primary, as if there were no workers")
        unattended.release()
        // Nothing but interactive-only servers: said plainly.
        let only = AgentFleet()
        only.configure([FleetServer(id: "qwen", label: "qwen", isPrimary: true, interactiveOnly: true) {
            FleetTarget(client: FleetReportsClient("x"), model: "qwen", contextWindow: 8_000)
        }])
        do {
            _ = try await only.acquire(unattended: true)
            XCTFail("nothing may take it")
        } catch let error as FleetUnavailableError {
            XCTAssertTrue(error.message.contains("interactive use only"), error.message)
        }
    }

    // MARK: The tools

    func testWithoutAFleetASensitiveTaskRunsOnlyOnAPrivateModel() async throws {
        let notPrivate = fleetContext(FleetReportsClient("parent"), root: dir.url, retry: fleetFastRetry)
        let refused = await AgentTool().execute(args: #"{"description":"payroll","prompt":"p","sensitive":true}"#, in: notPrivate)
        XCTAssertTrue(refused.output.contains(AgentFleet.noPrivateServer), refused.output)

        let spark = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "https://192.168.1.42:11443/v1", model: "q")
        let onPrivate = fleetContext(PrivateModel(profile: spark), root: dir.url, retry: fleetFastRetry)
        let ran = await AgentTool().execute(args: #"{"description":"payroll","prompt":"p","sensitive":true}"#, in: onPrivate)
        XCTAssertTrue(ran.output.contains("finished"), ran.output)

        // Guardian and Bedrock in your account are private as a Sensitive chat counts them: a chat on one of them
        // (shield off, so every subagent task is sensitive) still has subagents.
        for profile in [ProviderProfile(kind: .bedrock, name: "Bedrock", baseURL: "", model: "claude"),
                        ProviderProfile(kind: .guardian, name: "Guardian", baseURL: "https://guardian.example.com/api/v1", model: "g")] {
            var context = fleetContext(PrivateModel(profile: profile), root: dir.url, retry: fleetFastRetry)
            context.privateSubagentsOnly = true
            let result = await AgentTool().execute(args: #"{"description":"notes","prompt":"p"}"#, in: context)
            XCTAssertTrue(result.output.contains("finished"), "\(profile.name): \(result.output)")
        }
    }

    func testTheAgentToolSaysWhenNothingPrivateCanTakeIt() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("openai", primary: true, private: false), server("kimi", private: false)])
        let context = fleetContext(FleetReportsClient("parent"), root: dir.url, fleet: fleet, retry: fleetFastRetry)
        let result = await AgentTool().execute(args: #"{"description":"payroll","prompt":"p","sensitive":true}"#, in: context)
        XCTAssertTrue(result.output.contains("No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again."),
                      result.output)
        // Without the flag it runs.
        let ordinary = await AgentTool().execute(args: #"{"description":"docs","prompt":"p"}"#, in: context)
        XCTAssertTrue(ordinary.output.contains("finished"), ordinary.output)
    }

    func testDelegateMarksTasksOneByOneOrAllAtOnce() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("openai", primary: true, private: false), server("spark-2", private: true), server("kimi", private: false)])
        let context = fleetContext(FleetReportsClient("parent"), root: dir.url, fleet: fleet, retry: fleetFastRetry)
        let result = await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"p","sensitive":true},{"description":"b","prompt":"p"}]}"#,
                                                  in: context)
        XCTAssertTrue(result.output.contains("2 finished"), result.output)
        XCTAssertTrue(result.output.contains("## 1. a — finished (on spark-2"), result.output)
    }

    func testTheModelIsToldWhichServersArePrivate() throws {
        func entry(_ id: String, _ isPrivate: Bool, primary: Bool = false) -> SubagentPool.Entry {
            SubagentPool.Entry(id: id, routeID: id + "|m", label: id, provider: "p", model: "m", context: nil, isPrivate: isPrivate,
                               tier: .local, speed: .standard, images: true, ownAgent: false, parallel: 2, machine: "route:" + id,
                               kind: .openAICompatible, interactiveOnly: false, isPrimary: primary)
        }
        let pool = SubagentPool(entries: [entry("spark-2", true), entry("kimi-code", false), entry("primary", true, primary: true)])
        let note = try XCTUnwrap(SubagentPool.describe(pool))
        XCTAssertTrue(note.contains("- spark-2: p · m · private · local · standard · images · 2 at a time"), note)
        XCTAssertTrue(note.contains("- kimi-code: p · m · not private ·"), note)
        XCTAssertTrue(note.contains("Servers that aren't private must not receive sensitive data. Describe their tasks in general terms — no names, credentials, personal or client details; the app also masks what it detects."))
        XCTAssertNil(SubagentPool.describe(SubagentPool(entries: [entry("primary", true, primary: true)])))
        XCTAssertFalse(SubagentPool.describe(SubagentPool(entries: [entry("spark-2", true), entry("primary", true, primary: true)]))!
            .contains("must not receive"))

        let registry = ToolRegistry.standard(agents: nil, pool: pool)
        for spec in registry.specs {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(spec.parameters.utf8)), spec.name)
        }
        XCTAssertTrue(try XCTUnwrap(registry.specs.first { $0.name == "agent" }).description.hasSuffix(note), "listed once, in the agent tool")
        XCTAssertFalse(try XCTUnwrap(registry.specs.first { $0.name == "delegate" }).description.contains("spark-2"))
        for name in ["agent", "delegate"] {
            let spec = try XCTUnwrap(registry.specs.first { $0.name == name })
            XCTAssertTrue(spec.parameters.contains(#""sensitive":{"type":"boolean","description":"Set true when the task needs sensitive data (personal data, credentials, client details). It then runs only on a private server."#), name)
            XCTAssertTrue(spec.parameters.contains(#""server":{"type":"string","description":"Where this task runs:"#), name)
        }
    }
}

/// A model on the user's own network, answering with a report.
private struct PrivateModel: ProviderClient {
    let profile: ProviderProfile

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("report"))
            continuation.yield(.done(calls: [], finish: "stop", usage: nil))
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { [profile.model] }
    func modelInfo(_ model: String?) async -> ModelInfo? { nil }
}
