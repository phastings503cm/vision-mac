import Foundation

// MARK: - Where one subagent task runs
//
// One pure decision, called by the fleet under its lock (and driven by the shared fixture placement-cases.json, so
// Vision for Windows decides the same way):
//
//   1. the servers the task may use at all — a sensitive task only private ones (the chat's own model only when it is
//      private and may take subagents, or was picked), an unattended one none that is for interactive use only;
//   2. the server the primary picked (`server`): it runs there when it has room; when it is busy it is waited for until
//      the pin's deadline (2 minutes); when it can't take the task — or the deadline passed — another server runs it,
//      and the note says why;
//   3. the server an agent file asks for, as a preference;
//   4. the least busy subagent server, then the chat's own model as overflow — else wait.

public enum SubagentPlacement {
    /// How long a busy server the primary picked is waited for before another one runs the task.
    public static let pinWait: TimeInterval = 120

    /// Why a task runs where it does (the codes both apps and their logs share).
    public enum Reason: String, Sendable, Hashable, Codable {
        case picked
        case agentFile = "agent-file"
        case leastBusy = "least-busy"
        case fallback

        /// What the activity menu and the plan say.
        public var label: String {
            switch self {
            case .picked: "picked by the primary"
            case .agentFile: "set by its agent type"
            case .leastBusy: "least busy"
            case .fallback: "fallback"
            }
        }

        /// The label of a stored code (nil for none or one this build doesn't know).
        public static func label(_ code: String?) -> String? {
            code.flatMap(Reason.init(rawValue:))?.label
        }
    }

    /// One server as the decision sees it.
    public struct Candidate: Sendable, Hashable {
        public var id: String
        /// What the model calls it ("dgx-spark", "primary").
        public var handle: String
        public var label: String
        /// The asking chat's own model.
        public var isPrimary: Bool
        public var isPrivate: Bool
        public var interactiveOnly: Bool
        public var inFlight: Int
        public var parallel: Int
        /// When a server that just failed is trusted again (nil: it is healthy).
        public var healthyAt: Date?
        /// Its last failure, for the note.
        public var error: String?

        public init(id: String, handle: String, label: String, isPrimary: Bool = false, isPrivate: Bool = true,
                    interactiveOnly: Bool = false, inFlight: Int = 0, parallel: Int = 2, healthyAt: Date? = nil,
                    error: String? = nil) {
            self.id = id
            self.handle = handle
            self.label = label
            self.isPrimary = isPrimary
            self.isPrivate = isPrivate
            self.interactiveOnly = interactiveOnly
            self.inFlight = inFlight
            self.parallel = parallel
            self.healthyAt = healthyAt
            self.error = error
        }
    }

    /// One task asking for a server.
    public struct Request: Sendable, Hashable {
        /// The candidate id the primary picked (already matched from its `server` argument).
        public var pinned: String?
        /// An agent file's soft preference (matched against names, ids and handles).
        public var agentFile: String?
        public var sensitive: Bool
        public var unattended: Bool
        /// Until when a busy pinned server is waited for.
        public var pinDeadline: Date?
        /// Servers that couldn't be reached for this task.
        public var tried: Set<String>
        /// The chat's own model takes subagents when the others are busy.
        public var overflow: Bool
        /// The last server's error, for "No model server answered: …".
        public var lastError: String?
        /// How long the pin is waited for — only for the note's words.
        public var pinWait: TimeInterval

        public init(pinned: String? = nil, agentFile: String? = nil, sensitive: Bool = false, unattended: Bool = false,
                    pinDeadline: Date? = nil, tried: Set<String> = [], overflow: Bool = true, lastError: String? = nil,
                    pinWait: TimeInterval = SubagentPlacement.pinWait) {
            self.pinned = pinned
            self.agentFile = agentFile
            self.sensitive = sensitive
            self.unattended = unattended
            self.pinDeadline = pinDeadline
            self.tried = tried
            self.overflow = overflow
            self.lastError = lastError
            self.pinWait = pinWait
        }
    }

    /// What to do.
    public enum Decision: Sendable, Hashable {
        /// Run it on this server.
        case run(id: String, reason: Reason, note: String?)
        /// Wait for a slot (a release wakes the fleet), at the latest until `until`.
        case wait(until: Date?)
        /// Nothing can take it: tell the main agent.
        case unavailable(String)
    }

    /// When nothing that may take unattended work is left (the same words on Windows).
    public static let unattendedOnly =
        "The model servers that could take this task are for interactive use only under their plans' terms, so unattended work can't run there. Do it yourself."
    /// When a sensitive task finds no private server (unchanged, the same on Windows).
    public static let noPrivateServer =
        "No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again."
    /// When there are no servers at all.
    public static let noServer = "No model server is configured."

    /// Whether a server is the one a preference names: its name, route id or handle contains it (any case).
    public static func matches(_ candidate: Candidate, _ wanted: String) -> Bool {
        let wanted = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return false }
        return [candidate.label, candidate.id, candidate.handle].contains { $0.range(of: wanted, options: .caseInsensitive) != nil }
    }

    /// The agent file's notes (the words the roster used before).
    public static func agentFileBusy(_ wanted: String) -> String {
        "its agent file asks for “\(wanted)”, which was busy or not answering"
    }
    public static func agentFileMissing(_ wanted: String) -> String {
        "its agent file asks for “\(wanted)”, but no model server by that name is set up (Settings ▸ AI Models: turn on “Use for subagents” for that route)"
    }

    /// "2 minutes", "30 seconds".
    public static func waitWords(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 60, s % 60 == 0 { return s == 60 ? "1 minute" : "\(s / 60) minutes" }
        return s == 1 ? "1 second" : "\(s) seconds"
    }

    /// The note when a task moves after its server failed mid-way.
    public static func movedNote(from handle: String, error: String) -> String {
        "\(handle) failed (\(String(error.prefix(140)))) — moved here"
    }

    public static func choose(_ request: Request, _ candidates: [Candidate], now: Date) -> Decision {
        guard !candidates.isEmpty else { return .unavailable(noServer) }
        let workersExist = candidates.contains { !$0.isPrimary }
        func eligible(_ c: Candidate) -> Bool {
            if request.unattended, c.interactiveOnly { return false }
            guard request.sensitive else { return true }
            guard c.isPrivate else { return false }
            if c.isPrimary { return request.overflow || !workersExist || request.pinned == c.id }
            return true
        }
        let allowed = candidates.filter(eligible)
        if allowed.isEmpty {
            return .unavailable(request.sensitive ? noPrivateServer : unattendedOnly)
        }
        let open = allowed.filter { !request.tried.contains($0.id) }
        if open.isEmpty {
            if request.sensitive { return .unavailable(noPrivateServer) }
            return .unavailable("No model server answered" + (request.lastError.map { ": \($0)" } ?? "."))
        }
        func healthy(_ c: Candidate) -> Bool { c.healthyAt.map { $0 <= now } ?? true }
        func hasRoom(_ c: Candidate) -> Bool { c.inFlight < max(1, c.parallel) }
        var order: [String: Int] = [:]
        for (index, c) in candidates.enumerated() where order[c.id] == nil { order[c.id] = index }
        func leastBusy(_ list: [Candidate]) -> Candidate? {
            var best: (c: Candidate, load: Double, index: Int)?
            for c in list where hasRoom(c) {
                let load = Double(c.inFlight) / Double(max(1, c.parallel))
                let index = order[c.id] ?? Int.max
                if let current = best, (current.load, current.index) <= (load, index) { continue }
                best = (c, load, index)
            }
            return best?.c
        }
        // A blacklisted server comes back by itself when its time is up, with nothing else to wake the waiter.
        let recovery = open.compactMap { c -> Date? in
            guard let at = c.healthyAt, at > now else { return nil }
            return at
        }.min()

        var forced: Reason?
        var note: String?

        // 2. The server the primary picked.
        if let pinned = request.pinned, let pin = candidates.first(where: { $0.id == pinned }) {
            if eligible(pin), healthy(pin), !request.tried.contains(pin.id) {
                if hasRoom(pin) { return .run(id: pin.id, reason: .picked, note: nil) }
                if let deadline = request.pinDeadline, now < deadline {
                    return .wait(until: [deadline, recovery].compactMap { $0 }.min())
                }
                note = "\(pin.handle) stayed busy for \(waitWords(request.pinWait))"
            } else if request.sensitive, !pin.isPrivate {
                note = "\(pin.handle) isn't private and this task is sensitive"
            } else if request.unattended, pin.interactiveOnly {
                note = "\(pin.handle) is for interactive use only and this run is unattended"
            } else {
                note = "\(pin.handle) isn't answering" + (pin.error.map { " (\(String($0.prefix(140))))" } ?? "")
            }
            forced = .fallback
        }

        // Skip servers that just failed — unless that would leave none.
        let fit = open.filter(healthy)
        let usable = fit.isEmpty ? open : fit
        func finish(_ chosen: Candidate, _ reason: Reason) -> Decision {
            if chosen.id == request.pinned { return .run(id: chosen.id, reason: .picked, note: nil) }
            if let forced { return .run(id: chosen.id, reason: forced, note: note) }
            return .run(id: chosen.id, reason: reason, note: reason == .fallback ? note : nil)
        }

        // 3. The agent file's preference.
        var fallbackReason = Reason.leastBusy
        if let wanted = request.agentFile?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty {
            let favourites = usable.filter { matches($0, wanted) }
            if let favourite = leastBusy(favourites) { return finish(favourite, .agentFile) }
            if forced == nil {
                note = candidates.contains(where: { matches($0, wanted) }) ? agentFileBusy(wanted) : agentFileMissing(wanted)
                fallbackReason = .fallback
            }
        }

        // 4. The least busy subagent server, then the chat's own model as overflow.
        let workers = usable.filter { !$0.isPrimary }
        if let worker = leastBusy(workers) { return finish(worker, fallbackReason) }
        let primaries = usable.filter(\.isPrimary)
        if request.sensitive || workers.isEmpty || request.overflow, let primary = leastBusy(primaries) {
            return finish(primary, fallbackReason)
        }
        return .wait(until: recovery)
    }
}
