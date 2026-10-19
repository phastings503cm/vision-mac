import XCTest
@testable import VisionHarnessCore

final class ControlArbiterTests: XCTestCase, @unchecked Sendable {
    let a = ControlHolder(id: "chat-a", chatID: "chat-a", label: "Fix the build")
    let b = ControlHolder(id: "chat-b", chatID: "chat-b", label: "Book a flight")
    let c = ControlHolder(id: "chat-c", chatID: "chat-c", label: "Third")

    func arbiter(idle: TimeInterval = 5, wait: TimeInterval = 5, clock: any HumanInputClock = FakeHumanClock(),
                 lock: (any MachineLock)? = nil) -> ControlArbiter {
        ControlArbiter(settings: .init(waitTimeout: wait, idleRelease: idle, humanQuiet: 1.5), clock: clock, machineLock: lock)
    }

    func testFirstComerGetsTheControlsAtOnceAndAgainWhileHolding() async {
        let arb = arbiter()
        let first = await arb.acquire(a)
        XCTAssertEqual(first, .granted)
        let again = await arb.acquire(a)
        XCTAssertEqual(again, .granted, "a holder asking again is not put in line behind itself")
        let snapshot = await arb.snapshot()
        XCTAssertEqual(snapshot.holder, a)
        XCTAssertTrue(snapshot.waiting.isEmpty)
    }

    func testSecondChatWaitsInLineAndGetsTheControlsOnRelease() async throws {
        let arb = arbiter()
        _ = await arb.acquire(a)
        let waiter = Task { await arb.acquire(b) }
        let bHolder = b
        try await waitUntil { await arb.snapshot().waiting == [bHolder] }
        let holder = await arb.snapshot().holder
        XCTAssertEqual(holder, a, "B waits while A holds")
        await arb.release(a)
        let result = await waiter.value
        XCTAssertEqual(result, .granted)
        let now = await arb.snapshot()
        XCTAssertEqual(now.holder, b)
        XCTAssertTrue(now.waiting.isEmpty)
    }

    func testLineIsFirstComeFirstServed() async throws {
        let arb = arbiter()
        _ = await arb.acquire(a)
        let bLocal = b
        let bTask = Task { await arb.acquire(bLocal) }
        try await waitUntil { await arb.snapshot().waiting.count == 1 }
        let cLocal = c
        let cTask = Task { await arb.acquire(cLocal) }
        try await waitUntil { await arb.snapshot().waiting.count == 2 }
        let line = await arb.snapshot().waiting
        XCTAssertEqual(line, [b, c])
        await arb.release(a)
        let bResult = await bTask.value
        XCTAssertEqual(bResult, .granted)
        let holderAfterA = await arb.snapshot().holder
        XCTAssertEqual(holderAfterA, b)
        await arb.release(b)
        let cResult = await cTask.value
        XCTAssertEqual(cResult, .granted)
    }

    func testAnIdleHolderLosesTheControlsToTheNextInLine() async throws {
        let arb = arbiter(idle: 0.15)
        _ = await arb.acquire(a)
        let started = Date()
        let result = await arb.acquire(b)
        XCTAssertEqual(result, .granted)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.1, "B got them only after A idled")
        let holder = await arb.snapshot().holder
        XCTAssertEqual(holder, b)
    }

    func testTouchingKeepsTheLease() async throws {
        let arb = arbiter(idle: 0.3)
        _ = await arb.acquire(a)
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 120_000_000)
            await arb.touch(a)
        }
        let holder = await arb.snapshot().holder
        XCTAssertEqual(holder, a, "an acting holder keeps the controls past the idle time")
    }

    func testTheWaitTimesOutNamingWhoHasTheControls() async {
        let arb = arbiter(idle: 30)
        _ = await arb.acquire(a)
        let result = await arb.acquire(b, timeout: 0.2)
        XCTAssertEqual(result, .timedOut(holder: "Fix the build"))
        let waiting = await arb.snapshot().waiting
        XCTAssertTrue(waiting.isEmpty, "a timed-out waiter leaves the line")
    }

    func testStopAllTurnsEveryoneAway() async throws {
        let arb = arbiter(idle: 30)
        _ = await arb.acquire(a)
        let bLocal = b
        let bTask = Task { await arb.acquire(bLocal) }
        let cLocal = c
        let cTask = Task { await arb.acquire(cLocal) }
        try await waitUntil { await arb.snapshot().waiting.count == 2 }
        await arb.stopAll()
        let bResult = await bTask.value
        let cResult = await cTask.value
        XCTAssertEqual(bResult, .stopped)
        XCTAssertEqual(cResult, .stopped)
        let snapshot = await arb.snapshot()
        XCTAssertNil(snapshot.holder)
        XCTAssertTrue(snapshot.waiting.isEmpty)
    }

    func testReleasingAChatTakesItsSubagentsOutOfLineAndNeverHandsToTheSameChat() async throws {
        let arb = arbiter(idle: 30)
        let aSub = ControlHolder(id: "chat-a/sub1", chatID: "chat-a", label: "Fix the build")
        _ = await arb.acquire(a)
        let subTask = Task { await arb.acquire(aSub) }
        try await waitUntil { await arb.snapshot().waiting.count == 1 }
        let bLocal = b
        let bTask = Task { await arb.acquire(bLocal) }
        try await waitUntil { await arb.snapshot().waiting.count == 2 }
        await arb.release(chatID: "chat-a")
        let subResult = await subTask.value
        XCTAssertEqual(subResult, .stopped)
        let bResult = await bTask.value
        XCTAssertEqual(bResult, .granted, "the controls skip the stopped chat's subagent")
    }

    func testACancelledWaiterLeavesTheLine() async throws {
        let arb = arbiter(idle: 30)
        _ = await arb.acquire(a)
        let bLocal = b
        let bTask = Task { await arb.acquire(bLocal) }
        try await waitUntil { await arb.snapshot().waiting.count == 1 }
        bTask.cancel()
        let result = await bTask.value
        XCTAssertEqual(result, .stopped)
        try await waitUntil { await arb.snapshot().waiting.isEmpty }
    }

    func testObserversSeeTheLine() async throws {
        let arb = arbiter(idle: 30)
        let seen = Recorder<ControlSnapshot>()
        await arb.observe { seen.append($0) }
        _ = await arb.acquire(a)
        let bLocal = b
        let bTask = Task { await arb.acquire(bLocal, timeout: 0.2) }
        _ = await bTask.value
        let snapshots = seen.values
        XCTAssertEqual(snapshots.first, .idle)
        XCTAssertTrue(snapshots.contains { $0.holder == a && $0.waiting == [b] }, "the waiting chat was published")
        XCTAssertEqual(snapshots.last?.waiting, [])
    }

    // MARK: The person comes first

    func testPersonIsActiveRule() {
        // Recent input, nothing of ours: the person.
        XCTAssertTrue(ControlArbiter.personIsActive(sinceInput: 0.2, sinceOwnPost: nil, quiet: 1.5))
        // Quiet for longer than the threshold: not active.
        XCTAssertFalse(ControlArbiter.personIsActive(sinceInput: 2, sinceOwnPost: nil, quiet: 1.5))
        // The latest input is (about) our own post: not the person.
        XCTAssertFalse(ControlArbiter.personIsActive(sinceInput: 0.2, sinceOwnPost: 0.25, quiet: 1.5))
        // Input well after our last post: the person.
        XCTAssertTrue(ControlArbiter.personIsActive(sinceInput: 0.2, sinceOwnPost: 1.0, quiet: 1.5))
    }

    func testHolderWaitsForThePersonThenProceeds() async throws {
        let clock = FakeHumanClock()
        let arb = arbiter(clock: clock)
        _ = await arb.acquire(a)
        clock.busy(until: Date().addingTimeInterval(0.4))
        let busy = await arb.personIsActive()
        XCTAssertTrue(busy)
        let flag = Recorder<Bool>()
        await arb.observe { flag.append($0.waitingForPerson) }
        let started = Date()
        let clear = await arb.waitForPerson(a, timeout: 3)
        XCTAssertTrue(clear)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(flag.values.contains(true), "the wait for the person was shown")
        let after = await arb.snapshot()
        XCTAssertFalse(after.waitingForPerson)
        XCTAssertEqual(after.holder, a, "the holder kept its seat while it waited")
    }

    func testWaitingForThePersonTimesOut() async {
        let clock = FakeHumanClock()
        let arb = arbiter(clock: clock)
        _ = await arb.acquire(a)
        clock.busy(until: Date().addingTimeInterval(30))
        let clear = await arb.waitForPerson(a, timeout: 0.3)
        XCTAssertFalse(clear)
    }

    // MARK: Machine-wide

    func testAnotherProcessHoldingTheMachineLockMakesUsWait() async throws {
        let shared = FakeMachineLock()
        XCTAssertTrue(shared.tryLock(label: "Other window chat"))
        let arb = arbiter(lock: shared)
        let aLocal = a
        let task = Task { await arb.acquire(aLocal, timeout: 3) }
        try await waitUntil { await arb.snapshot().otherProcessHolder == "Other window chat" }
        shared.unlock()
        let result = await task.value
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(shared.holderLabel(), "Fix the build", "we hold the machine lock now")
        await arb.release(a)
        XCTAssertNil(shared.holderLabel(), "released with the last holder")
    }

    func testMachineLockTimeoutNamesTheOtherProcess() async {
        let shared = FakeMachineLock()
        _ = shared.tryLock(label: "Other window chat")
        let arb = arbiter(lock: shared)
        let result = await arb.acquire(a, timeout: 0.3)
        XCTAssertEqual(result, .timedOut(holder: "Other window chat"))
        let holder = await arb.snapshot().holder
        XCTAssertNil(holder)
    }

    func testFileLockIsExclusiveAcrossOpenFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("control.lock")
        let one = FileMachineLock(url: url), two = FileMachineLock(url: url)
        XCTAssertTrue(one.tryLock(label: "Chat one"))
        XCTAssertFalse(two.tryLock(label: "Chat two"), "flock is per open file: a second open contends like another process")
        XCTAssertEqual(two.holderLabel(), "Chat one")
        one.unlock()
        XCTAssertTrue(two.tryLock(label: "Chat two"))
        XCTAssertEqual(one.holderLabel(), "Chat two")
        two.unlock()
    }

    // MARK: Helpers

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @Sendable () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

/// Collects values from @Sendable callbacks.
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
