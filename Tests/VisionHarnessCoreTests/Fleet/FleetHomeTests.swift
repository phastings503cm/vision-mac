import XCTest
@testable import VisionHarnessCore

/// A chat's own server stands in for the fleet's primary: its subagents use the shared workers first and then the
/// model *that chat* uses — never the one another chat picked.
final class FleetHomeTests: XCTestCase {
    func testAChatsHomeReplacesThePrimaryForItsRequestsOnly() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("spark", FleetReportsClient("spark"), primary: true, max: 2)])
        let kimi = fleetServer("kimi", FleetReportsClient("kimi"), primary: false, max: 2)

        let own = try await fleet.acquire(home: kimi)
        XCTAssertEqual(own.label, "kimi", "no workers: the chat's own server, not the configured primary")
        XCTAssertTrue(own.server.isPrimary)
        let other = try await fleet.acquire()
        XCTAssertEqual(other.label, "spark", "a chat without a home of its own gets the primary")
        own.release()
        other.release()
        XCTAssertEqual(fleet.snapshot().map(\.id), ["spark"], "the home isn't added to the configured servers")
    }

    func testWorkersAreStillSharedAndAHomeThatIsAWorkerIsntCountedTwice() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("spark", FleetReportsClient("spark"), primary: true, max: 2),
                         fleetServer("worker", FleetReportsClient("worker"), primary: false, max: 1)])
        let kimi = fleetServer("kimi", FleetReportsClient("kimi"), primary: false, max: 2)
        let first = try await fleet.acquire(home: kimi)
        XCTAssertEqual(first.label, "worker", "workers first")
        let second = try await fleet.acquire(home: kimi)
        XCTAssertEqual(second.label, "kimi", "then the chat's own server as overflow")
        first.release(); second.release()

        // The chat's own server is also flagged as a worker: it is the chat's primary, once.
        let both = fleetServer("worker", FleetReportsClient("worker"), primary: false, max: 1)
        let a = try await fleet.acquire(home: both)
        XCTAssertEqual(a.label, "worker")
        let waiting = FleetPending { try await fleet.acquire(home: both) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(waiting.isDone, "one slot, not two: the server isn't both worker and primary")
        a.release()
        let b = try await waiting.value()
        XCTAssertEqual(b.label, "worker")
        b.release()
    }
}
