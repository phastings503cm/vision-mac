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
    /// An engine of its own works the task instead of Vision's (Claude Code: one `claude -p` job in the chat's
    /// folder); nil = Vision's engine on `client`.
    public var external: (any ExternalSubagent)?

    public init(client: any LLMClient, model: String, contextWindow: Int? = nil,
                vision: Bool? = nil, temperature: Double? = nil, maxOutputTokens: Int? = nil,
                ownSettings: Bool = false, thinking: ThinkingLevel? = nil, external: (any ExternalSubagent)? = nil) {
        self.client = client
        self.model = model
        self.contextWindow = contextWindow
        self.vision = vision
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.ownSettings = ownSettings
        self.thinking = thinking
        self.external = external
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
    /// What the main agent calls it in the `server` argument ("dgx-spark"; "primary" for a chat's own model).
    public var handle: String?
    /// What counts as its machine (see `SubagentPool.machine`).
    public var machine: String?
    /// Its route kind, in the pool's words ("openai-compatible", "claude-code", …).
    public var kind: String?
    /// A chat's own model, standing in as the primary for that chat's subagents.
    public var isHome: Bool
    /// Probe the server and return its live client and model. Throws if it can't be reached — a server
    /// that answers no model list at all counts as unreachable. Cancelled with the task that is leasing.
    public var resolve: @Sendable () async throws -> FleetTarget

    public init(id: String, label: String, isPrimary: Bool = false, maxParallel: Int = 2, isPrivate: Bool = true,
                interactiveOnly: Bool = false, handle: String? = nil, machine: String? = nil, kind: String? = nil,
                isHome: Bool = false, resolve: @escaping @Sendable () async throws -> FleetTarget) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.maxParallel = maxParallel
        self.isPrivate = isPrivate
        self.interactiveOnly = interactiveOnly
        self.handle = handle
        self.machine = machine
        self.kind = kind
        self.isHome = isHome
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
    /// "primary" (a configured primary), "worker" (a subagent server) or "home" (a chat's own model, listed while its
    /// subagents run on it).
    public var role: String
    /// What the main agent calls it ("dgx-spark", "primary").
    public var handle: String?

    public init(id: String, label: String, isPrimary: Bool, inFlight: Int, maxParallel: Int,
                healthy: Bool, unhealthyUntil: Date? = nil, completed: Int, failed: Int, role: String? = nil,
                handle: String? = nil) {
        self.id = id
        self.label = label
        self.isPrimary = isPrimary
        self.inFlight = inFlight
        self.maxParallel = maxParallel
        self.healthy = healthy
        self.unhealthyUntil = unhealthyUntil
        self.completed = completed
        self.failed = failed
        self.role = role ?? (isPrimary ? "primary" : "worker")
        self.handle = handle
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

/// One task asking the fleet for a server.
public struct FleetRequest: Sendable {
    /// The server the main agent picked with `server` (its id — the home's for "primary"); waited for up to
    /// `AgentFleet.pinWait` when busy, then only a preference.
    public var pinned: String?
    /// An agent file's soft preference (matched against names, ids and handles).
    public var preferred: String?
    /// It needs sensitive data: private servers only.
    public var sensitive: Bool
    /// A queue task or a `/goal`: no server whose plan allows interactive use only.
    public var unattended: Bool
    /// The asking chat's own server, which stands in for the primary.
    public var home: FleetServer?
    /// The ids of the configured servers this chat may use besides its home (nil = every one).
    public var pool: Set<String>?
    /// The asking chat is Sensitive: a server that only sees it masked gets no pictures.
    public var sensitiveChat: Bool

    public init(pinned: String? = nil, preferred: String? = nil, sensitive: Bool = false, unattended: Bool = false,
                home: FleetServer? = nil, pool: Set<String>? = nil, sensitiveChat: Bool = false) {
        self.pinned = pinned
        self.preferred = preferred
        self.sensitive = sensitive
        self.unattended = unattended
        self.home = home
        self.pool = pool
        self.sensitiveChat = sensitiveChat
    }
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
    /// What the main agent calls the server ("dgx-spark", "primary").
    public var handle: String { server.handle ?? server.label }
    /// Servers tried first that couldn't take the work, and why ("DGX Spark: didn't answer") — so the person can
    /// see why a subagent runs where it does.
    public let skipped: [String]
    /// Why it runs here (nil when the lease was made by hand).
    public let reason: SubagentPlacement.Reason?
    /// What a fallback is about ("spark-2 stayed busy for 2 minutes").
    public let note: String?

    private let fleet: AgentFleet
    private let lock = NSLock()
    private var released = false
    private var failed = false
    private var abandoned = false

    init(fleet: AgentFleet, server: FleetServer, target: FleetTarget, skipped: [String] = [],
         reason: SubagentPlacement.Reason? = nil, note: String? = nil) {
        self.fleet = fleet
        self.server = server
        self.target = target
        self.skipped = skipped
        self.reason = reason
        self.note = note
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
        var lastError: String?
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
    /// Chats' own servers with subagents on them right now (for the status list).
    private var homes: [String: FleetServer] = [:]
    private var waiters: [Waiter] = []
    private var unhealthyForSeconds: TimeInterval = 60
    private var pinWaitSeconds: TimeInterval = SubagentPlacement.pinWait
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

    /// How long a busy server the main agent picked is waited for (2 minutes; tests shorten it).
    public var pinWait: TimeInterval {
        get { lock.withLock { pinWaitSeconds } }
        set { lock.withLock { pinWaitSeconds = newValue } }
    }

    /// A Claude plan's usage limit with no reset time keeps Claude Code off this long.
    public static let usageLimitPause: TimeInterval = 15 * 60

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
                if states[gone]?.inFlight == 0 {
                    states[gone] = nil
                    homes[gone] = nil
                }
            }
            return takeWaitersLocked()
        }
        wake.forEach { $0.wake() }
        raiseChanged()
    }

    /// Every configured server, then each chat's own server that has subagents on it now (role "home").
    public func snapshot() -> [FleetStatus] {
        lock.withLock {
            let at = now()
            func status(_ server: FleetServer, role: String?) -> FleetStatus {
                let state = states[server.id] ?? State()
                let pending = state.unhealthyUntil.flatMap { $0 > at ? $0 : nil }
                return FleetStatus(id: server.id, label: server.label, isPrimary: server.isPrimary,
                                   inFlight: state.inFlight, maxParallel: server.maxParallel,
                                   healthy: isHealthyLocked(state, at), unhealthyUntil: pending,
                                   completed: state.completed, failed: state.failed, role: role, handle: server.handle)
            }
            var out = configured.map { status($0, role: nil) }
            for home in homes.values.sorted(by: { $0.label < $1.label })
            where !configured.contains(where: { $0.id == home.id }) && (states[home.id]?.inFlight ?? 0) > 0 {
                out.append(status(home, role: "home"))
            }
            return out
        }
    }

    /// How busy each of a chat's pool entries is now, keyed by entry id — for `SubagentPool.loadLine`. The chat's own
    /// model is `home` (its state is shared with the same route serving other chats as a subagent server).
    public func loads(for pool: SubagentPool, home: FleetServer?) -> [String: SubagentPool.Load] {
        lock.withLock {
            let at = now()
            var out: [String: SubagentPool.Load] = [:]
            for entry in pool.entries {
                let id = entry.isPrimary ? (home?.id ?? entry.routeID) : entry.routeID
                let state = states[id] ?? State()
                let until = state.unhealthyUntil.flatMap { $0 > at ? $0 : nil }
                out[entry.id] = SubagentPool.Load(inFlight: state.inFlight, healthy: until == nil,
                                                  retryIn: until.map { $0.timeIntervalSince(at) })
            }
            return out
        }
    }

    /// How many servers one request may choose between (its home included).
    public func choiceCount(home: FleetServer?, pool: Set<String>?) -> Int {
        lock.withLock { serversLocked(home: home, pool: pool).count }
    }

    // MARK: Leasing

    private enum Step {
        case chosen(FleetServer, SubagentPlacement.Reason, String?)
        case wait(Waiter, until: Date?)
    }

    /// What a task marked sensitive is told when nothing private can take it.
    public static let noPrivateServer = SubagentPlacement.noPrivateServer

    /// Wait for a free slot on a suitable server and lease it. `preferred` names a server the caller would
    /// like (matched against the label and id); it is a preference, not a demand. A `sensitive` task runs only on
    /// a private server: a private worker, else the primary when it is private and may take subagents. An
    /// `unattended` one (for the queue or `/goal`) never runs on a server whose plan allows interactive use only.
    /// `home` is the asking chat's own server: it stands in for the configured primary, so a chat's subagents fall
    /// back to the model that chat uses — never to the one another chat picked (the workers are shared).
    public func acquire(preferred: String? = nil, sensitive: Bool = false, unattended: Bool = false,
                        home: FleetServer? = nil) async throws -> FleetLease {
        try await acquire(FleetRequest(preferred: preferred, sensitive: sensitive, unattended: unattended, home: home))
    }

    /// Lease a server for one task (see `SubagentPlacement` for the order). A server the main agent picked
    /// (`pinned`) is waited for up to `pinWait` when busy; after that, or when it can't take the task, another server
    /// runs it and the lease's `note` says why. Throws `FleetUnavailableError` when no server can take it, and
    /// `CancellationError` when the task is cancelled while it waits (a lease already being resolved is given back).
    public func acquire(_ request: FleetRequest) async throws -> FleetLease {
        var tried = Set<String>()
        var lastError: (any Error)?
        var skipped: [String] = []
        let deadline: Date? = request.pinned == nil ? nil : lock.withLock { now().addingTimeInterval(pinWaitSeconds) }
        while true {
            try Task.checkCancellation()
            let step: Step = try lock.withLock {
                let servers = serversLocked(home: request.home, pool: request.pool)
                if servers.isEmpty { throw FleetUnavailableError(SubagentPlacement.noServer) }
                let at = now()
                let candidates = servers.map { server -> SubagentPlacement.Candidate in
                    let state = states[server.id] ?? State()
                    return SubagentPlacement.Candidate(
                        id: server.id, handle: server.handle ?? server.label, label: server.label, isPrimary: server.isPrimary,
                        isPrivate: server.isPrivate, interactiveOnly: server.interactiveOnly, inFlight: state.inFlight,
                        parallel: server.maxParallel, healthyAt: state.unhealthyUntil, error: state.lastError)
                }
                let decision = SubagentPlacement.choose(
                    SubagentPlacement.Request(pinned: request.pinned, agentFile: request.preferred, sensitive: request.sensitive,
                                              unattended: request.unattended, pinDeadline: deadline, tried: tried,
                                              overflow: primaryTakesOverflow, lastError: lastError?.localizedDescription,
                                              pinWait: pinWaitSeconds),
                    candidates, now: at)
                switch decision {
                case .run(let id, let reason, let note):
                    guard let chosen = servers.first(where: { $0.id == id }) else { throw FleetUnavailableError(SubagentPlacement.noServer) }
                    states[chosen.id, default: State()].inFlight += 1
                    if chosen.isHome || chosen.id == request.home?.id { homes[chosen.id] = chosen }
                    return .chosen(chosen, reason, note)
                case .wait(let until):
                    let waiter = Waiter()
                    waiters.append(waiter)
                    return .wait(waiter, until: until)
                case .unavailable(let message):
                    throw FleetUnavailableError(message, underlying: lastError)
                }
            }

            switch step {
            case .wait(let waiter, let until):
                // A blacklisted server comes back by itself when its time is up, and a pin's wait ends at its
                // deadline — with nothing else to wake us.
                let seconds = until.map { $0.timeIntervalSince(now()) + 0.05 }
                let timer: Task<Void, Never>? = seconds.map { seconds in
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

            case .chosen(let server, let reason, let note):
                raiseChanged()
                do {
                    var target = try await server.resolve()
                    // A Sensitive chat sends a server that only sees it masked no pictures: the shield can't check them.
                    if request.sensitiveChat, !server.isPrivate { target.vision = false }
                    return FleetLease(fleet: self, server: server, target: target, skipped: skipped, reason: reason, note: note)
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

    /// Whether `server` is the one a preference names (its label, route id or handle contains it, any case) — how an
    /// agent file's `server:`/`model:` line picks a server.
    public static func matches(_ server: FleetServer, preferred: String) -> Bool {
        let wanted = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return server.label.range(of: wanted, options: .caseInsensitive) != nil
            || server.id.range(of: wanted, options: .caseInsensitive) != nil
            || (server.handle?.range(of: wanted, options: .caseInsensitive) != nil)
    }

    /// Whether `error` is the server's fault rather than the request's — the kind of failure another
    /// server might not have.
    public static func isServerFault(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        // A worker that can't take work for now (a Claude plan's usage limit).
        if error is SubagentServerPaused { return true }
        // Claude Code that isn't there, isn't signed in, is out of its plan's usage or won't start in this folder:
        // another server can do the task. A task that failed on its own (`.failed`) would fail anywhere.
        if let claude = error as? ClaudeCodeError {
            switch claude {
            case .notInstalled, .couldNotStart, .notSignedIn, .rateLimited, .untrustedFolder: return true
            case .sessionNotFound, .sessionInUse, .sensitiveChat, .failed: return false
            }
        }
        // Credentials that one server rejects may be fine on another (a worker with a stale key, a
        // Bedrock sign-in that expired, Guardian signed out), and so may a certificate this Mac doesn't trust.
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

    /// Keep new work off a server that failed: for `until` when given, until a usage limit resets (else 15 minutes)
    /// for a paused one, else for `unhealthyFor`.
    func markFailed(_ id: String, _ error: Error, until: Date? = nil) {
        guard Self.isServerFault(error) || error is FleetUnavailableError else { return }
        lock.withLock {
            guard states[id] != nil else { return }
            let at = now()
            states[id]?.unhealthyUntil = until ?? Self.pause(for: error, at: at) ?? at.addingTimeInterval(unhealthyForSeconds)
            states[id]?.lastError = error.localizedDescription
        }
        raiseChanged()
    }

    /// How long a server that hit a usage limit stays out.
    static func pause(for error: Error, at: Date) -> Date? {
        if let paused = error as? SubagentServerPaused { return paused.until ?? at.addingTimeInterval(usageLimitPause) }
        if case ClaudeCodeError.rateLimited = error { return at.addingTimeInterval(usageLimitPause) }
        return nil
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
                    state.lastError = nil
                }
                if state.inFlight == 0, !configured.contains(where: { $0.id == id }) {
                    states[id] = nil
                    homes[id] = nil
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

    /// The servers one request may use: the configured ones (only those in the chat's pool, when it has one), with the
    /// asking chat's own server as the primary.
    private func serversLocked(home: FleetServer?, pool: Set<String>?) -> [FleetServer] {
        let allowed = pool.map { ids in configured.filter { ids.contains($0.id) } } ?? configured
        guard var home else { return allowed }
        home.isPrimary = true
        return allowed.filter { !$0.isPrimary && $0.id != home.id } + [home]
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
