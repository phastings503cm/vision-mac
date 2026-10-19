import Foundation
import CoreGraphics
import Darwin

// MARK: - The machine-wide control arbiter
//
// There is one real mouse pointer and one keyboard focus on a Mac. Most of what
// a chat does to another app no longer needs either: pressing a button,
// filling a text field and posting keys to one process all go through
// Accessibility or a process-addressed event (see `ControlPlanner`). What is
// left — a real click at a point, a drag, typing into the app in front,
// bringing an app forward — takes the pointer or the focus away from the
// person, so only one chat may do it at a time.
//
// The arbiter hands that "seat at the controls" to one chat at a time:
//
// * A chat that wants the real mouse or keyboard `acquire`s it. If another chat
//   holds it, the caller waits in line (first come, first served) and its seat
//   says "waiting for the mouse — <other chat> has it" until it gets it or its
//   wait times out (the tool then tells the model to try a background action
//   or try later).
// * A holder keeps the seat while it keeps acting: every action `touch`es the
//   lease, and the lease lapses after `idleRelease` seconds of no actions, so a
//   burst of clicks from one chat is never interleaved with another chat's.
// * The person comes first: before an action that would move the pointer or
//   type into the app in front, the holder waits until the person has left
//   the mouse and keyboard alone for `humanQuiet` seconds.
// * `stopAll` (the global stop hotkey) ends every lease and turns every waiter
//   away at once.
//
// Across processes (two copies of Vision, or an old DSH build next to Vision) a
// lock file stands in for the in-process seat, so the arbiter is machine-wide:
// the holder's chat name is written into it for the other copy to show.

/// Who holds, or waits for, the real mouse and keyboard.
public struct ControlHolder: Sendable, Hashable {
    /// Unique per acting engine: a chat's id, or the chat id plus a subagent suffix.
    public var id: String
    /// The chat it belongs to (for "stop this chat").
    public var chatID: String
    /// The chat's name, as the glow and the waiting chats show it.
    public var label: String

    public init(id: String, chatID: String, label: String) {
        self.id = id
        self.chatID = chatID
        self.label = label
    }
}

/// What the arbiter looks like right now (for the glow, the chats' status lines and tests).
public struct ControlSnapshot: Sendable, Equatable {
    /// Who has the real mouse and keyboard (nil = nobody).
    public var holder: ControlHolder?
    /// Who is waiting for them, in line order.
    public var waiting: [ControlHolder]
    /// The holder is waiting for the person to finish with the mouse/keyboard.
    public var waitingForPerson: Bool
    /// Another copy of the app holds the machine lock (its chat's name, when it wrote one).
    public var otherProcessHolder: String?

    public init(holder: ControlHolder? = nil, waiting: [ControlHolder] = [], waitingForPerson: Bool = false,
                otherProcessHolder: String? = nil) {
        self.holder = holder
        self.waiting = waiting
        self.waitingForPerson = waitingForPerson
        self.otherProcessHolder = otherProcessHolder
    }

    public static let idle = ControlSnapshot()
}

/// How a request for the controls ended.
public enum ControlAcquireResult: Sendable, Equatable {
    case granted
    /// The wait ran out; `holder` is who still had the controls (nil: another copy of the app, or the person).
    case timedOut(holder: String?)
    /// The global stop, or the chat was stopped while it waited.
    case stopped
}

/// The person's own input, as the arbiter sees it.
public protocol HumanInputClock: Sendable {
    /// Seconds since the last hardware mouse/keyboard event.
    func secondsSinceLastInput() -> TimeInterval
}

/// The live clock: the HID system's idle time (hardware events).
public struct HIDInputClock: HumanInputClock {
    public init() {}
    public func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType (~0): any event type.
        let any = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }
}

/// A cross-process lock: held by at most one process on the machine.
public protocol MachineLock: Sendable {
    /// Take the lock without blocking; true when this process now holds it.
    func tryLock(label: String) -> Bool
    func unlock()
    /// The label the current holder wrote (another process's chat name), if any.
    func holderLabel() -> String?
}

/// A lock file under the user's temporary folder, held with `flock`. The lock goes with the process (a crash
/// or a kill releases it), so a stale file never blocks anyone.
public final class FileMachineLock: MachineLock, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var fd: Int32 = -1

    public init(url: URL) { self.url = url }

    /// The shared lock every copy of the app uses (one per user).
    public static let shared = FileMachineLock(url: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vision-machine-control.lock"))

    public func tryLock(label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return true }
        let opened = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard opened >= 0 else { return true }   // can't make the file: don't block on it
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        // Who holds it, for the other copy's "waiting for …" line. Never anything secret: a chat title.
        _ = ftruncate(opened, 0)
        let bytes = Array(String(label.prefix(120)).utf8)
        _ = bytes.withUnsafeBufferPointer { pwrite(opened, $0.baseAddress, $0.count, 0) }
        fd = opened
        return true
    }

    public func unlock() {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        _ = ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    public func holderLabel() -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public actor ControlArbiter {
    /// The one arbiter of this app. Tests make their own.
    public static let shared = ControlArbiter()

    public struct Settings: Sendable, Equatable {
        /// How long a chat waits for the controls before giving up (the tool then says who had them).
        public var waitTimeout: TimeInterval
        /// A holder that hasn't acted for this long gives the controls up.
        public var idleRelease: TimeInterval
        /// The person counts as busy until they have left the mouse and keyboard alone this long.
        public var humanQuiet: TimeInterval

        public init(waitTimeout: TimeInterval = ControlArbiter.defaultWaitTimeout, idleRelease: TimeInterval = 4,
                    humanQuiet: TimeInterval = 1.5) {
            self.waitTimeout = waitTimeout
            self.idleRelease = idleRelease
            self.humanQuiet = humanQuiet
        }
    }

    /// The default wait for the controls: 90 seconds (Settings ▸ Computer changes it).
    public static let defaultWaitTimeout: TimeInterval = 90

    public private(set) var settings: Settings
    private let clock: any HumanInputClock
    private let machineLock: (any MachineLock)?

    private var holder: ControlHolder?
    private var lastTouch = Date.distantPast
    private var idleTask: Task<Void, Never>?
    private var waitingForPerson = false
    private var otherProcessHolder: String?
    /// When this process last posted a synthesized event (so its own events are not mistaken for the person's).
    private var lastOwnPost: Date?

    private struct Waiter {
        let token: UUID
        let holder: ControlHolder
        let continuation: CheckedContinuation<ControlAcquireResult, Never>
    }
    private var waiters: [Waiter] = []

    private var observers: [UUID: @Sendable (ControlSnapshot) -> Void] = [:]

    public init(settings: Settings = Settings(), clock: any HumanInputClock = HIDInputClock(),
                machineLock: (any MachineLock)? = FileMachineLock.shared) {
        self.settings = settings
        self.clock = clock
        self.machineLock = machineLock
    }

    // MARK: Settings & observing

    public func update(_ settings: Settings) {
        self.settings = settings
    }

    /// Follow every change (called on the arbiter's executor; hop to the main actor to touch UI).
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (ControlSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot())
        return id
    }

    public func removeObserver(_ id: UUID) { observers[id] = nil }

    public func snapshot() -> ControlSnapshot {
        ControlSnapshot(holder: holder, waiting: waiters.map(\.holder), waitingForPerson: waitingForPerson,
                        otherProcessHolder: otherProcessHolder)
    }

    private func publish() {
        let current = snapshot()
        for observer in observers.values { observer(current) }
    }

    // MARK: Acquire / touch / release

    /// Ask for the real mouse and keyboard. Returns at once when `who` holds them already or nobody does;
    /// otherwise waits its turn (first come, first served) up to `timeout` (default: the settings' wait).
    public func acquire(_ who: ControlHolder, timeout: TimeInterval? = nil) async -> ControlAcquireResult {
        let limit = timeout ?? settings.waitTimeout
        let deadline = Date().addingTimeInterval(limit)
        if holder?.id == who.id {
            touch(who)
            return .granted
        }
        if holder == nil && waiters.isEmpty {
            holder = who
            lastTouch = Date()
            scheduleIdleRelease()
            publish()
        } else {
            let token = UUID()
            let result: ControlAcquireResult = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiters.append(Waiter(token: token, holder: who, continuation: continuation))
                    publish()
                    scheduleTimeout(token: token, after: limit)
                }
            } onCancel: {
                Task { await self.cancelWaiter(token) }
            }
            guard result == .granted else { return result }
        }
        // In-process seat taken; the machine-wide lock comes next (another copy of the app may hold it).
        return await takeMachineLock(for: who, until: deadline)
    }

    private func takeMachineLock(for who: ControlHolder, until deadline: Date) async -> ControlAcquireResult {
        guard let machineLock else { return .granted }
        while !machineLock.tryLock(label: who.label) {
            otherProcessHolder = machineLock.holderLabel() ?? "another copy of \(AppIdentity.name)"
            publish()
            if Task.isCancelled || holder?.id != who.id {
                otherProcessHolder = nil
                giveUp(who)
                return .stopped
            }
            if Date() >= deadline {
                let other = otherProcessHolder
                otherProcessHolder = nil
                giveUp(who)
                return .timedOut(holder: other)
            }
            // Keep the in-process lease alive while waiting on the other process.
            lastTouch = Date()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if otherProcessHolder != nil {
            otherProcessHolder = nil
            publish()
        }
        guard holder?.id == who.id else {
            // Stopped while waiting for the lock.
            machineLock.unlock()
            return .stopped
        }
        lastTouch = Date()
        return .granted
    }

    /// The holder acted: keep the lease for another `idleRelease` seconds.
    public func touch(_ who: ControlHolder) {
        guard holder?.id == who.id else { return }
        lastTouch = Date()
        scheduleIdleRelease()
    }

    /// Give the controls back now (the chat's turn ended, or it was stopped).
    public func release(_ who: ControlHolder) {
        // A release also takes the caller out of line (a stopped chat must not get the controls later).
        removeWaiters { $0.id == who.id }
        if holder?.id == who.id { handOff() }
    }

    /// Everything a chat holds or waits for, including its subagents. Out of line first, so the seat never
    /// passes to another engine of the same chat.
    public func release(chatID: String) {
        removeWaiters { $0.chatID == chatID }
        if holder?.chatID == chatID { handOff() }
    }

    /// The global stop: nobody holds the controls, and everyone waiting is turned away.
    public func stopAll() {
        let turnedAway = waiters
        waiters.removeAll()
        for waiter in turnedAway { waiter.continuation.resume(returning: .stopped) }
        holder = nil
        waitingForPerson = false
        idleTask?.cancel()
        idleTask = nil
        machineLock?.unlock()
        publish()
    }

    /// Whether `who` holds the controls right now (an action checks before it moves anything).
    public func holds(_ who: ControlHolder) -> Bool { holder?.id == who.id }

    private func giveUp(_ who: ControlHolder) {
        if holder?.id == who.id { handOff() }
    }

    private func handOff() {
        idleTask?.cancel()
        idleTask = nil
        waitingForPerson = false
        if waiters.isEmpty {
            holder = nil
            machineLock?.unlock()
            publish()
            return
        }
        // The next in line takes over; the machine lock stays with this process.
        let next = waiters.removeFirst()
        holder = next.holder
        lastTouch = Date()
        scheduleIdleRelease()
        publish()
        next.continuation.resume(returning: .granted)
    }

    private func removeWaiters(where match: (ControlHolder) -> Bool) {
        let gone = waiters.filter { match($0.holder) }
        guard !gone.isEmpty else { return }
        waiters.removeAll { match($0.holder) }
        for waiter in gone { waiter.continuation.resume(returning: .stopped) }
        publish()
    }

    private func cancelWaiter(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .stopped)
        publish()
    }

    private func scheduleTimeout(token: UUID, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            await self?.timeOut(token)
        }
    }

    private func timeOut(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: .timedOut(holder: holder?.label ?? otherProcessHolder))
        publish()
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        let idle = settings.idleRelease
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, idle) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle()
        }
    }

    private func releaseIfIdle() {
        guard holder != nil else { return }
        if waitingForPerson {
            // Waiting for the person is not idling: keep the seat.
            scheduleIdleRelease()
            return
        }
        if Date().timeIntervalSince(lastTouch) + 0.005 >= settings.idleRelease {
            handOff()
        } else {
            scheduleIdleRelease()
        }
    }

    // MARK: The person comes first

    /// Note that this process just posted synthesized input (so it isn't taken for the person's).
    public func notePosted() {
        lastOwnPost = Date()
    }

    /// Whether the person is using the mouse or keyboard right now.
    public func personIsActive() -> Bool {
        Self.personIsActive(sinceInput: clock.secondsSinceLastInput(),
                            sinceOwnPost: lastOwnPost.map { Date().timeIntervalSince($0) },
                            quiet: settings.humanQuiet)
    }

    /// The rule behind `personIsActive`: input within the last `quiet` seconds that came noticeably after this
    /// process's own last synthesized event. (Synthesized events can count as input on some systems; one that
    /// lands within a quarter second of our own post is taken to be ours.)
    public static func personIsActive(sinceInput: TimeInterval, sinceOwnPost: TimeInterval?, quiet: TimeInterval) -> Bool {
        guard sinceInput < quiet else { return false }
        guard let sinceOwnPost else { return true }
        return sinceOwnPost > sinceInput + 0.25
    }

    /// Before moving the pointer or typing into the app in front: wait (holding the seat) until the person has
    /// left the mouse and keyboard alone. True when it is clear; false when `timeout` ran out or `who` lost the
    /// seat (stopped).
    public func waitForPerson(_ who: ControlHolder, timeout: TimeInterval? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? settings.waitTimeout)
        guard holder?.id == who.id else { return false }
        if !personIsActive() { return true }
        waitingForPerson = true
        publish()
        defer {
            if holder?.id == who.id {
                waitingForPerson = false
                lastTouch = Date()
                scheduleIdleRelease()
                publish()
            }
        }
        while personIsActive() {
            if Task.isCancelled || holder?.id != who.id || Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return holder?.id == who.id
    }
}
