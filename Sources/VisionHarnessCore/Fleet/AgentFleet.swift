import Foundation

// MARK: - The fleet
//
// With more than one model server (say two DGX Sparks), one is the *primary*: the main agent talks to
// it. The others are *workers*: subagents run on them, so a fan-out of tasks spreads across machines
// instead of queueing on one. The fleet hands out leases on servers — the least loaded worker first, the
// primary only as overflow — and steers away from a server that has just failed. With a single server
// the fleet is just a concurrency limit on it.

/// Where one subagent runs: the server's client and model, its context window, and — when they differ
/// from the parent's — the settings of that server's route (nil = inherit the parent's). Resolved when a
/// lease is granted, not when the fleet is configured: a Spark may have swapped models since.
public struct FleetTarget: Sendable {
    public var client: any LLMClient
    public var model: String
    public var contextWindow: Int?
    public var vision: Bool?
    public var temperature: Double?
    public var maxOutputTokens: Int?
    /// The target is another route's server, with settings of its own: its temperature, output limit and thinking
    /// level are the route's (nil = that provider's default) and never the parent chat's. A Kimi or GLM worker must
    /// not be sent the temperature, max_tokens or reasoning effort the main model's route was set up with — a server
    /// that rejects them answers 400, and the subagent quietly ends up somewhere else. False (the primary, or no
    /// fleet): the parent's settings, as before.
    public var ownSettings: Bool
    /// The thinking level for this target when it has `ownSettings` (nil = the route's own default).
    public var thinking: ThinkingLevel?

    public init(client: any LLMClient, model: String, contextWindow: Int? = nil,
                vision: Bool? = nil, temperature: Double? = nil, maxOutputTokens: Int? = nil,
                ownSettings: Bool = false, thinking: ThinkingLevel? = nil) {
        self.client = client
        self.model = model
        self.contextWindow = contextWindow
        self.vision = vision
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.ownSettings = ownSettings
        self.thinking = thinking
    }
}

/// One model server as the fleet sees it.
public struct FleetServer: Sendable, Identifiable {
    /// Stable identity (the route id).
    public var id: String
    /// What the user calls it ("spark-2"); shown next to a subagent that ran on it.
    public var label: String
    /// The server the main agent talks to.
    public var isPrimary: Bool
    /// How many subagents may work on it at once.
    public var maxParallel: Int
    /// May see sensitive data (your own hardware — see `RoutePrivacy`): only such a server takes a task marked
    /// sensitive.
    public var isPrivate: Bool
    /// The plan behind it allows interactive use only: it takes no unattended work (the queue, `/goal`).
    public var interactiveOnly: Bool
    /// Probe the server and return its live client and model. Throws if it can't be reached — a server
    /// that answers no model list at all counts as unreachable. Cancelled with the task that is leasing.
    public var resolve: @Sendable () async throws -> FleetTarget

    public init(id: String, label: String, isPrimary: Bool = false, maxParallel: Int = 2, isPrivate: Bool = true,
                interactiveOnly: Bool = false, resolve: @escaping @Sendable () async throws -> FleetTarget) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.maxParallel = maxParallel
        self.isPrivate = isPrivate
        self.interactiveOnly = interactiveOnly
        self.resolve = resolve
    }
}

/// A server's standing, for the UI ("spark-2 — 1/2 busy, 14 done").
public struct FleetStatus: Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var isPrimary: Bool
    public var inFlight: Int
    public var maxParallel: Int
    public var healthy: Bool
    /// When a server that just failed is trusted again; nil while it is healthy.
    public var unhealthyUntil: Date?
    public var completed: Int
    public var failed: Int

    public init(id: String, label: String, isPrimary: Bool, inFlight: Int, maxParallel: Int,
                healthy: Bool, unhealthyUntil: Date? = nil, completed: Int, failed: Int) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.inFlight = inFlight
        self.maxParallel = maxParallel
        self.healthy = healthy
        self.unhealthyUntil = unhealthyUntil
        self.completed = completed
        self.failed = failed
    }
}

/// No configured server answered.
public struct FleetUnavailableError: Error, LocalizedError, Sendable {
    public let message: String
    /// The last server's own error, when there was one.
    public let underlying: (any Error)?

    public init(_ message: String, underlying: (any Error)? = nil) {
        self.message = message
        self.underlying = underlying
    }

    public var errorDescription: String? { message }
}

/// A slot on one server. Call `release()` when the work is over (`defer` is the usual place) and
/// `fail(_:)` first if the server itself was the problem, so the next task goes elsewhere.
///
/// Swift has no `IDisposable`, so release is explicit and idempotent. It deliberately does not happen in
/// `deinit`: the optimizer may drop a reference right after its last use, and a slot must be held for as
/// long as the caller says, not as long as the compiler happens to keep the object.
public final class FleetLease: @unchecked Sendable {
    public let server: FleetServer
    public let target: FleetTarget
    public var label: String { server.label }
    /// Servers tried first that couldn't take the work, and why ("DGX Spark: didn't answer") — so the person can
    /// see why a subagent runs where it does.
    public let skipped: [String]

    private let fleet: AgentFleet
    private let lock = NSLock()
    private var released = false
    private var failed = false
    private var abandoned = false

    init(fleet: AgentFleet, server: FleetServer, target: FleetTarget, skipped: [String] = []) {
        self.fleet = fleet
        self.server = server
        self.target = target
        self.skipped = skipped
    }

    /// The server misbehaved (unreachable, overloaded, erroring): keep new work away from it for a while.
    /// An error that is the request's own (a malformed prompt) is counted but does not blacklist the server.
    public func fail(_ error: Error) {
        lock.withLock { failed = true }
        fleet.markFailed(server.id, error)
    }

    /// The work was stopped rather than finished or failed: free the slot without counting a success
    /// (which would also clear a blacklisting the server earned).
    public func abandon() {
        lock.withLock { abandoned = true }
    }

    /// Give the slot back. Only the first call does anything.
    public func release() {
        let outcome: (failed: Bool, counted: Bool)? = lock.withLock {
            guard !released else { return nil }
            released = true
            return (failed, !abandoned)
        }
        guard let outcome else { return }
        fleet.release(server.id, failed: outcome.failed, counted: outcome.counted)
    }
}

/// Thread-safe; one per app, shared by every chat so two chats can't both fill the same Spark.
public final class AgentFleet: @unchecked Sendable {
    private struct State {
        var inFlight = 0
        var completed = 0
        var failed = 0
        var unhealthyUntil: Date?
    }

    /// One task parked in `acquire`, woken by a release, a reconfiguration, a blacklisted server's
    /// recovery, or its own cancellation. `wake()` may come before `wait()` (the wake is remembered) and
    /// may come twice (the second is a no-op), which is what lets all three race safely.
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var woken = false

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyWoken: Bool = lock.withLock {
                    if woken { return true }
                    self.continuation = continuation
                    return false
                }
                if alreadyWoken { continuation.resume() }
            }
        }

        func wake() {
            let parked: CheckedContinuation<Void, Never>? = lock.withLock {
                woken = true
                defer { continuation = nil }
                return continuation
            }
            parked?.resume()
        }
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var configured: [FleetServer] = []
    private var states: [String: State] = [:]
    private var waiters: [Waiter] = []
    private var unhealthyForSeconds: TimeInterval = 60
    private var primaryTakesOverflow = true
    private var changeHandler: (@Sendable () -> Void)?

    /// `now` is injectable so a test can move past a blacklisting without waiting a minute.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// A server that just failed is left alone this long (unless every server is down).
    public var unhealthyFor: TimeInterval {
        get { lock.withLock { unhealthyForSeconds } }
        set { lock.withLock { unhealthyForSeconds = newValue } }
    }

    /// When every worker is busy, let subagents run on the primary too (a vLLM server batches requests,
    /// so this is usually a gain). False keeps the primary free for the main agent.
    public var usePrimaryWhenWorkersBusy: Bool {
        get { lock.withLock { primaryTakesOverflow } }
        set { lock.withLock { primaryTakesOverflow = newValue } }
    }

    /// Called (on any thread, never with the fleet's lock held — a handler may call `snapshot()`) when a
    /// lease is granted or released, a server fails, or the set changes.
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }

    public var servers: [FleetServer] { lock.withLock { configured } }

    public var hasWorkers: Bool { lock.withLock { configured.contains { !$0.isPrimary } } }

    /// Replace the set of servers (Settings changed, the route was switched). Work already leased carries
    /// on; counters of servers that stay are kept.
    public func configure(_ servers: [FleetServer]) {
        let wake: [Waiter] = lock.withLock {
            configured = servers
            for server in servers where states[server.id] == nil { states[server.id] = State() }
            for gone in Array(states.keys) where !servers.contains(where: { $0.id == gone }) {
                if states[gone]?.inFlight == 0 { states[gone] = nil }
            }
            return takeWaitersLocked()
        }
        wake.forEach { $0.wake() }
        raiseChanged()
    }

    public func snapshot() -> [FleetStatus] {
        lock.withLock {
            let at = now()
            return configured.map { server in
                let state = states[server.id] ?? State()
                let pending = state.unhealthyUntil.flatMap { $0 > at ? $0 : nil }
                return FleetStatus(id: server.id, label: server.label, isPrimary: server.isPrimary,
                                   inFlight: state.inFlight, maxParallel: server.maxParallel,
                                   healthy: isHealthyLocked(state, at), unhealthyUntil: pending,
                                   completed: state.completed, failed: state.failed)
            }
        }
    }

    // MARK: Leasing

    private enum Step {
        case chosen(FleetServer)
        case wait(Waiter, recovery: TimeInterval?)
    }

    /// What a task marked sensitive is told when nothing private can take it.
    public static let noPrivateServer =
        "No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again."

    /// Wait for a free slot on a suitable server and lease it. `preferred` names a server the caller would
    /// like (matched against the label and id); it is a preference, not a demand. A `sensitive` task runs only on
    /// a private server: a private worker, else the primary when it is private and may take subagents. An
    /// `unattended` one (for the queue or `/goal`) never runs on a server whose plan allows interactive use only.
    /// Throws `FleetUnavailableError` when no server can be reached (or, for a sensitive task, none is private), and
    /// `CancellationError` when the task is cancelled while it waits (a lease already being resolved is given back).
    /// `home` is the asking chat's own server: it stands in for the configured primary, so a chat's subagents fall
    /// back to the model that chat uses — never to the one another chat picked (the workers are shared).
    public func acquire(preferred: String? = nil, sensitive: Bool = false, unattended: Bool = false,
                        home: FleetServer? = nil) async throws -> FleetLease {
        var tried = Set<String>()
        var lastError: (any Error)?
        var skipped: [String] = []
        while true {
            try Task.checkCancellation()
            let step: Step = try lock.withLock {
                let servers = serversLocked(home: home)
                if servers.isEmpty { throw FleetUnavailableError("No model server is configured.") }
                let eligible = eligibleLocked(sensitive: sensitive, unattended: unattended, among: servers)
                if eligible.isEmpty, !sensitive {
                    throw FleetUnavailableError("No model server here may take unattended work: each one is for interactive use only under its plan's terms.")
                }
                // Every server that may take it was tried and failed (or, for a sensitive task, there is none):
                // say so rather than wait for something that can't come.
                if eligible.allSatisfy({ tried.contains($0.id) }) {
                    if sensitive { throw FleetUnavailableError(Self.noPrivateServer, underlying: lastError) }
                    throw FleetUnavailableError("No model server answered"
                                                + (lastError.map { ": \($0.localizedDescription)" } ?? "."),
                                                underlying: lastError)
                }
                if let chosen = chooseLocked(preferred: preferred, tried: tried, among: eligible, sensitive: sensitive,
                                             servers: servers) {
                    states[chosen.id, default: State()].inFlight += 1
                    return .chosen(chosen)
                }
                let waiter = Waiter()
                waiters.append(waiter)
                return .wait(waiter, recovery: nextRecoveryLocked(among: eligible, tried: tried))
            }

            switch step {
            case .wait(let waiter, let recovery):
                // A blacklisted server comes back by itself when its time is up, with nothing else to wake us.
                let timer: Task<Void, Never>? = recovery.map { seconds in
                    Task {
                        if (try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))) != nil {
                            waiter.wake()
                        }
                    }
                }
                await withTaskCancellationHandler {
                    await waiter.wait()
                } onCancel: {
                    waiter.wake()
                }
                timer?.cancel()
                lock.withLock { waiters.removeAll { $0 === waiter } }

            case .chosen(let server):
                raiseChanged()
                do {
                    let target = try await server.resolve()
                    return FleetLease(fleet: self, server: server, target: target, skipped: skipped)
                } catch {
                    if Task.isCancelled {
                        release(server.id, failed: false, counted: false)
                        throw CancellationError()
                    }
                    // Couldn't reach it: note that, free the slot, and try the next server.
                    lastError = error
                    skipped.append("\(server.label): \(error.localizedDescription)")
                    tried.insert(server.id)
                    markFailed(server.id, error)
                    release(server.id, failed: true, counted: true)
                }
            }
        }
    }

    /// Whether `server` is the one a preference names (its label or route id contains it, any case) — how an agent
    /// file's `server:`/`model:` line picks a server.
    public static func matches(_ server: FleetServer, preferred: String) -> Bool {
        let wanted = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return server.label.range(of: wanted, options: .caseInsensitive) != nil
            || server.id.range(of: wanted, options: .caseInsensitive) != nil
    }

    /// Whether `error` is the server's fault rather than the request's — the kind of failure another
    /// server might not have.
    public static func isServerFault(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // Credentials that one server rejects may be fine on another (a worker with a stale key, a
        // Bedrock sign-in that expired), and so may a certificate this Mac doesn't trust.
        if let llm = error as? LLMError {
            switch llm {
            case .http(let status, _), .rejected(let status, _, _, _):
                if status == 401 || status == 403 || status == OpenAIClient.untrustedCertificateStatus { return true }
            default:
                break
            }
        }
        // Whatever the retry policy would wait out — unreachable, overloaded, restarting, swapping models,
        // "still loading" — is that server's problem, and another server may not have it. What it would give
        // up on at once is the request's.
        return RequestRetry.disposition(for: error) != .fail
    }

    func markFailed(_ id: String, _ error: Error) {
        guard Self.isServerFault(error) || error is FleetUnavailableError else { return }
        lock.withLock {
            if states[id] != nil { states[id]?.unhealthyUntil = now().addingTimeInterval(unhealthyForSeconds) }
        }
        raiseChanged()
    }

    func release(_ id: String, failed: Bool, counted: Bool) {
        let wake: [Waiter] = lock.withLock {
            if var state = states[id] {
                state.inFlight = max(0, state.inFlight - 1)
                if failed {
                    state.failed += 1
                } else if counted {
                    state.completed += 1
                    state.unhealthyUntil = nil   // it just did real work
                }
                if state.inFlight == 0, !configured.contains(where: { $0.id == id }) {
                    states[id] = nil
                } else {
                    states[id] = state
                }
            }
            return takeWaitersLocked()
        }
        wake.forEach { $0.wake() }
        raiseChanged()
    }

    // MARK: Choosing

    /// The servers a task may run on: any, or for a sensitive task the private workers — and the primary when it is
    /// private and may take subagents (it always may when there are no workers at all). Unattended work leaves out
    /// the servers that are for interactive use only.
    private func eligibleLocked(sensitive: Bool, unattended: Bool, among servers: [FleetServer]) -> [FleetServer] {
        let allowed = unattended ? servers.filter { !$0.interactiveOnly } : servers
        guard sensitive else { return allowed }
        let primaryMay = primaryTakesSensitiveLocked(servers)
        return allowed.filter { $0.isPrivate && (!$0.isPrimary || primaryMay) }
    }

    /// The servers one request may use: the configured ones, with the asking chat's own server as the primary.
    private func serversLocked(home: FleetServer?) -> [FleetServer] {
        guard var home else { return configured }
        home.isPrimary = true
        return configured.filter { !$0.isPrimary && $0.id != home.id } + [home]
    }

    private func primaryTakesSensitiveLocked(_ servers: [FleetServer]) -> Bool {
        guard servers.contains(where: { $0.isPrimary && $0.isPrivate }) else { return false }
        return primaryTakesOverflow || !servers.contains(where: { !$0.isPrimary })
    }

    private func chooseLocked(preferred: String?, tried: Set<String>, among eligible: [FleetServer],
                              sensitive: Bool, servers: [FleetServer]) -> FleetServer? {
        let at = now()
        let candidates = eligible.filter { !tried.contains($0.id) }
        if candidates.isEmpty { return nil }
        // Skip servers that just failed — unless that would leave none.
        var healthy = candidates.filter { isHealthyLocked(states[$0.id], at) }
        if healthy.isEmpty { healthy = candidates }

        func pick(from pool: [FleetServer]) -> FleetServer? {
            var best: (server: FleetServer, load: Double, index: Int)?
            for server in pool where hasCapacityLocked(server) {
                let load = Double(states[server.id]?.inFlight ?? 0) / Double(max(1, server.maxParallel))
                let index = servers.firstIndex { $0.id == server.id } ?? Int.max
                if let current = best, (current.load, current.index) <= (load, index) { continue }
                best = (server, load, index)
            }
            return best?.server
        }

        if let wanted = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            let matches = healthy.filter { Self.matches($0, preferred: wanted) }
            if let favourite = pick(from: matches) { return favourite }
        }
        let workers = healthy.filter { !$0.isPrimary }
        if let worker = pick(from: workers) { return worker }
        let primaries = healthy.filter(\.isPrimary)
        // For a sensitive task the primary is eligible only when it is private and may take subagents.
        if sensitive { return pick(from: primaries) }
        // No workers at all, or the primary may take overflow: use it. Otherwise wait for a worker.
        if workers.isEmpty || primaryTakesOverflow { return pick(from: primaries) }
        return nil
    }

    /// How long until the first blacklisted server (an eligible one not yet tried) is trusted again; nil if none
    /// is waiting out a ban.
    private func nextRecoveryLocked(among eligible: [FleetServer], tried: Set<String>) -> TimeInterval? {
        let at = now()
        var soonest: TimeInterval?
        for server in eligible where !tried.contains(server.id) {
            guard let until = states[server.id]?.unhealthyUntil, until > at else { continue }
            let left = until.timeIntervalSince(at) + 0.05
            if soonest == nil || left < soonest! { soonest = left }
        }
        return soonest
    }

    private func hasCapacityLocked(_ server: FleetServer) -> Bool {
        (states[server.id]?.inFlight ?? 0) < max(1, server.maxParallel)
    }

    private func isHealthyLocked(_ state: State?, _ at: Date) -> Bool {
        guard let until = state?.unhealthyUntil else { return true }
        return until <= at
    }

    private func takeWaitersLocked() -> [Waiter] {
        defer { waiters.removeAll() }
        return waiters
    }

    /// Outside the lock, always: the state is settled before anyone is told, so a listener can look at the
    /// fleet (or even lease from it) without deadlocking or losing a slot.
    private func raiseChanged() {
        onChange?()
    }
}
