import Foundation

// MARK: - A chat's subagent pool
//
// The model a chat uses is that chat's *primary*: it leads, and it may hand side tasks to every other route the person
// enlisted ("Use for subagents" in Settings ▸ AI Models) — a second Spark, Amazon Bedrock, a plan, a Guardian model,
// Claude Code — except what runs on the chat's own machine, what a Sensitive chat may not use, and what an unattended
// run may not use. `build` works that out from plain facts about each route (so Vision for Windows and the shared
// fixtures decide exactly the same way); `describe` is the stable catalogue the agent tool's description carries (no
// load, so the prompt cache holds); `loadLine` is how busy each server is now, which goes in tool results instead.
//
// Pure values and functions, the same words on both apps (Tests/…/Fixtures/SubagentPool).

public struct SubagentPool: Hashable, Sendable {
    /// What kind of route, in words both Vision apps share (the fixtures use them).
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case openAICompatible = "openai-compatible"
        case ollama
        case lmStudio = "lmstudio"
        case openAI = "openai"
        case openRouter = "openrouter"
        case bedrock
        case guardian
        case anthropic
        case claudeCode = "claude-code"

        /// The kind `SensitivityPolicy.admission(kind:…)` understands ("guardian", "bedrock", "claude-code", …).
        var policyKind: String { rawValue }
    }

    /// What a server costs: your own box, a subscription, per token, or your organisation's Guardian account.
    public enum Tier: String, Codable, Sendable, Hashable {
        case local, subscription, api, org
    }

    /// A name-based hint at how quick a model is (not measured).
    public enum Speed: String, Codable, Sendable, Hashable {
        case fast, standard, thorough
    }

    /// One route as the pool sees it: every fact the decision needs, already worked out by the app.
    public struct RouteFacts: Hashable, Sendable, Codable {
        /// The route's identity ("Name|model" — its configured model, not the one a server serves now).
        public var routeID: String
        public var name: String
        /// The model it serves: the route's, or the last one its server reported (sticky).
        public var model: String
        public var kind: Kind
        public var baseURL: String
        /// Switched on and flagged "Use for subagents" (a Guardian model: ticked in the Guardian map).
        public var enlisted: Bool
        /// The route's Private switch (else its address): your own hardware. Guardian and Bedrock count as private
        /// whatever this says; Claude Code never does.
        public var privateSwitch: Bool
        /// Its plan allows interactive use only.
        public var interactiveOnly: Bool
        /// Subagents at a time (nil = the default: 2 for a subagent server, 4 for the chat's own model).
        public var parallel: Int?
        /// Its context window in tokens (override, else probed, else the built-in table), nil when unknown.
        public var contextWindow: Int?
        /// It takes pictures.
        public var images: Bool
        /// The subscription plan's provider when the base URL is a known plan's ("Kimi", "Z.ai", "DeepSeek" …).
        public var planProvider: String?
        /// That plan (its region, else the plan itself) is a monthly subscription; nil when no plan is recognised.
        public var planSubscription: Bool?
        /// The base URL's host is your own (LAN, loopback, Tailscale …).
        public var privateAddress: Bool
        /// The host is not a known hosted API (a server you run yourself).
        public var selfHosted: Bool

        public init(routeID: String? = nil, name: String, model: String, kind: Kind, baseURL: String = "",
                    enlisted: Bool = true, privateSwitch: Bool = false, interactiveOnly: Bool = false, parallel: Int? = nil,
                    contextWindow: Int? = nil, images: Bool = true, planProvider: String? = nil, planSubscription: Bool? = nil,
                    privateAddress: Bool = false, selfHosted: Bool = false) {
            self.routeID = routeID ?? name + "|" + model
            self.name = name
            self.model = model
            self.kind = kind
            self.baseURL = baseURL
            self.enlisted = enlisted
            self.privateSwitch = privateSwitch
            self.interactiveOnly = interactiveOnly
            self.parallel = parallel
            self.contextWindow = contextWindow
            self.images = images
            self.planProvider = planProvider
            self.planSubscription = planSubscription
            self.privateAddress = privateAddress
            self.selfHosted = selfHosted
        }

        /// The configured model (the part of the identity after the name).
        public var configuredModel: String {
            guard let bar = routeID.firstIndex(of: "|") else { return model }
            return String(routeID[routeID.index(after: bar)...])
        }

        /// How the route is named: its name, else its configured model.
        public var label: String { name.isEmpty ? configuredModel : name }

        private enum CodingKeys: String, CodingKey {
            case routeID, name, model, kind, baseURL, enlisted
            case privateSwitch = "private"
            case interactiveOnly, parallel
            case contextWindow = "context"
            case images, planProvider, planSubscription, privateAddress, selfHosted
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .name)
            let model = try c.decode(String.self, forKey: .model)
            self.init(routeID: try c.decodeIfPresent(String.self, forKey: .routeID), name: name, model: model,
                      kind: try c.decode(Kind.self, forKey: .kind),
                      baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "",
                      enlisted: try c.decodeIfPresent(Bool.self, forKey: .enlisted) ?? true,
                      privateSwitch: try c.decodeIfPresent(Bool.self, forKey: .privateSwitch) ?? false,
                      interactiveOnly: try c.decodeIfPresent(Bool.self, forKey: .interactiveOnly) ?? false,
                      parallel: try c.decodeIfPresent(Int.self, forKey: .parallel),
                      contextWindow: try c.decodeIfPresent(Int.self, forKey: .contextWindow),
                      images: try c.decodeIfPresent(Bool.self, forKey: .images) ?? true,
                      planProvider: try c.decodeIfPresent(String.self, forKey: .planProvider),
                      planSubscription: try c.decodeIfPresent(Bool.self, forKey: .planSubscription),
                      privateAddress: try c.decodeIfPresent(Bool.self, forKey: .privateAddress) ?? false,
                      selfHosted: try c.decodeIfPresent(Bool.self, forKey: .selfHosted) ?? false)
        }
    }

    /// One server a chat's model may hand a task to — what the catalogue says about it. No load numbers: those change
    /// all the time and would break the prompt cache (see `loadLine`).
    public struct Entry: Hashable, Sendable {
        /// What the model calls it: the handle ("dgx-spark"), or "primary" for the chat's own model.
        public var id: String
        public var routeID: String
        /// The route's name ("DGX Spark").
        public var label: String
        public var provider: String
        public var model: String
        /// "256K", "1M"; nil when unknown.
        public var context: String?
        public var isPrivate: Bool
        public var tier: Tier
        public var speed: Speed
        public var images: Bool
        /// It runs its own agent (Claude Code: one `claude -p` job in the chat's folder).
        public var ownAgent: Bool
        public var parallel: Int
        public var machine: String
        public var kind: Kind
        public var interactiveOnly: Bool
        public var isPrimary: Bool

        public var isGuardian: Bool { kind == .guardian }
        public var isClaudeCode: Bool { kind == .claudeCode }

        public init(id: String, routeID: String, label: String, provider: String, model: String, context: String?,
                    isPrivate: Bool, tier: Tier, speed: Speed, images: Bool, ownAgent: Bool, parallel: Int,
                    machine: String, kind: Kind, interactiveOnly: Bool, isPrimary: Bool) {
            self.id = id
            self.routeID = routeID
            self.label = label
            self.provider = provider
            self.model = model
            self.context = context
            self.isPrivate = isPrivate
            self.tier = tier
            self.speed = speed
            self.images = images
            self.ownAgent = ownAgent
            self.parallel = parallel
            self.machine = machine
            self.kind = kind
            self.interactiveOnly = interactiveOnly
            self.isPrimary = isPrimary
        }
    }

    /// An enlisted route this chat can't use, and why ("this chat's own machine").
    public struct Dropped: Hashable, Sendable {
        public var id: String
        public var routeID: String
        public var label: String
        public var reason: String

        public init(id: String, routeID: String, label: String, reason: String) {
            self.id = id
            self.routeID = routeID
            self.label = label
            self.reason = reason
        }
    }

    /// The servers, in Settings order, then the chat's own model ("primary") last.
    public var entries: [Entry]
    /// Enlisted routes left out of this chat's pool.
    public var dropped: [Dropped]
    /// Subagents may use the chat's own model when the others are busy.
    public var overflow: Bool
    /// The chat runs on Claude Code, which uses its own subagents: no pool.
    public var chatOwnAgent: Bool

    public init(entries: [Entry] = [], dropped: [Dropped] = [], overflow: Bool = true, chatOwnAgent: Bool = false) {
        self.entries = entries
        self.dropped = dropped
        self.overflow = overflow
        self.chatOwnAgent = chatOwnAgent
    }

    public var workers: [Entry] { entries.filter { !$0.isPrimary } }
    public var primary: Entry? { entries.first(where: \.isPrimary) }
    public var hasWorkers: Bool { entries.contains { !$0.isPrimary } }

    /// The route ids of the servers besides the chat's own (what the fleet may lease for this chat).
    public var workerRouteIDs: Set<String> { Set(workers.map(\.routeID)) }

    // MARK: Building a chat's pool

    /// Why an enlisted route is left out (the same words on both apps; "<handle> is <reason>" reads as a sentence).
    public enum Reason {
        public static let ownMachine = "this chat's own machine"
        public static let guardianSignedOut = "on Guardian, which is signed out"
        public static let sensitive = "not available in a Sensitive chat"
        public static let unattended = "for interactive use only, and this run is unattended"
        public static func sameMachine(_ handle: String) -> String { "the same machine as \(handle)" }
    }

    /// The handle of the chat's own model.
    public static let primaryID = "primary"

    /// The pool of a chat on `chat`: the enlisted `routes` (every route in Settings order, then Guardian's live models
    /// in Guardian's order — handles are worked out over all of them, so a handle is the same in every chat) that this
    /// chat may use, then its own model as "primary". A chat on Claude Code has none (it runs Claude Code's own agent).
    public static func build(routes: [RouteFacts], chat: RouteFacts?, guardianSignedIn: Bool, sensitive: Bool,
                             shieldOn: Bool, unattended: Bool, overflow: Bool) -> SubagentPool {
        guard let chat else { return SubagentPool(overflow: overflow) }
        if chat.kind == .claudeCode { return SubagentPool(overflow: overflow, chatOwnAgent: true) }
        let handles = self.handles(for: routes)
        let chatMachine = machine(chat)
        var kept: [Entry] = []
        var dropped: [Dropped] = []
        var machines: [String: String] = [:]
        for (index, route) in routes.enumerated() where route.enlisted {
            let handle = handles[index]
            let where_ = machine(route)
            let reason: String?
            if where_ == chatMachine {
                reason = Reason.ownMachine
            } else if route.kind == .guardian, !guardianSignedIn {
                reason = Reason.guardianSignedOut
            } else if sensitive, !admission(route, shieldOn: shieldOn).isAllowed {
                reason = Reason.sensitive
            } else if unattended, route.interactiveOnly {
                reason = Reason.unattended
            } else if let first = machines[where_] {
                reason = Reason.sameMachine(first)
            } else {
                reason = nil
            }
            if let reason {
                dropped.append(Dropped(id: handle, routeID: route.routeID, label: route.label, reason: reason))
            } else {
                machines[where_] = handle
                kept.append(entry(route, id: handle, primary: false))
            }
        }
        if !(unattended && chat.interactiveOnly) {
            kept.append(entry(chat, id: primaryID, primary: true))
        }
        return SubagentPool(entries: kept, dropped: dropped, overflow: overflow)
    }

    /// One pool entry for a route.
    public static func entry(_ route: RouteFacts, id: String, primary: Bool) -> Entry {
        Entry(id: id, routeID: route.routeID, label: route.label,
              provider: provider(kind: route.kind, planProvider: route.planProvider), model: route.model,
              context: route.contextWindow.flatMap(contextLabel),
              isPrivate: admission(route, shieldOn: false).code == "private",
              tier: tier(kind: route.kind, planSubscription: route.planSubscription, privateAddress: route.privateAddress),
              speed: speed(route.model),
              images: route.kind == .claudeCode ? false : route.images,
              ownAgent: route.kind == .claudeCode,
              parallel: min(max(route.parallel ?? (primary ? 4 : 2), 1), 16),
              machine: machine(route), kind: route.kind, interactiveOnly: route.interactiveOnly, isPrimary: primary)
    }

    /// How a Sensitive chat may use the route (the sensitivity policy's own rule).
    public static func admission(_ route: RouteFacts, shieldOn: Bool) -> RouteAdmission {
        SensitivityPolicy.admission(kind: route.kind.policyKind, name: route.label, isPrivate: route.privateSwitch,
                                    shieldOn: shieldOn)
    }

    // MARK: Labels

    /// "Ollama", "Amazon Bedrock", "Kimi" (a recognised plan), "OpenAI-compatible server".
    public static func provider(kind: Kind, planProvider: String?) -> String {
        switch kind {
        case .guardian: return "Guardian"
        case .claudeCode: return "Claude Code"
        case .bedrock: return "Amazon Bedrock"
        case .anthropic: return "Anthropic API"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openRouter: return "OpenRouter"
        case .openAI, .openAICompatible:
            if let planProvider, !planProvider.isEmpty { return planProvider }
            return kind == .openAI ? "OpenAI" : "OpenAI-compatible server"
        }
    }

    /// local / subscription / api / org.
    public static func tier(kind: Kind, planSubscription: Bool?, privateAddress: Bool) -> Tier {
        if kind == .claudeCode { return .subscription }
        if kind == .guardian { return .org }
        if planSubscription == true { return .subscription }
        if kind != .bedrock, privateAddress { return .local }
        return .api
    }

    static let fastTokens = ["haiku", "flash", "mini", "nano", "lite", "air", "turbo", "instant", "fast", "small",
                             "1.5b", "3b", "4b", "7b", "8b"]
    static let thoroughTokens = ["opus", "fable", "-pro", "pro-", "-max", "reasoner", "thinking"]

    /// fast / standard / thorough, from the model id's name.
    public static func speed(_ model: String) -> Speed {
        let id = model.lowercased()
        if fastTokens.contains(where: { id.contains($0) }) { return .fast }
        if thoroughTokens.contains(where: { id.contains($0) }) { return .thorough }
        return .standard
    }

    /// 262144 → "256K", 200000 → "200K", 1048576 → "1M"; nil for nothing.
    public static func contextLabel(_ tokens: Int) -> String? {
        guard tokens > 0 else { return nil }
        if tokens >= 1_000_000 { return "1M" }
        if tokens % 1024 == 0 { return "\(tokens / 1024)K" }
        return "\(tokens / 1000)K"
    }

    /// What counts as one machine: a self-hosted OpenAI-style server is its base URL (a Spark serves one model at a
    /// time); everything else — Bedrock, Guardian, the Anthropic API, Claude Code, any hosted API — is its own route.
    public static func machine(_ route: RouteFacts) -> String {
        machine(kind: route.kind, baseURL: route.baseURL, routeID: route.routeID, selfHosted: route.selfHosted)
    }

    public static func machine(kind: Kind, baseURL: String, routeID: String, selfHosted: Bool) -> String {
        switch kind {
        case .openAICompatible, .ollama, .lmStudio, .openAI, .openRouter:
            if selfHosted {
                return baseURL.trimmingCharacters(in: .whitespaces).lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        case .bedrock, .guardian, .anthropic, .claudeCode:
            break
        }
        return "route:" + routeID
    }

    // MARK: Handles

    /// Lower case a–z and 0–9, every other run one "-", trimmed, at most `limit` characters.
    public static func slug(_ text: String, limit: Int = 32) -> String {
        var out = ""
        var gap = false
        for scalar in text.lowercased().unicodeScalars {
            let ascii = scalar.isASCII ? scalar.value : 0
            if (ascii >= 97 && ascii <= 122) || (ascii >= 48 && ascii <= 57) {
                if gap, !out.isEmpty { out.append("-") }
                gap = false
                out.unicodeScalars.append(scalar)
            } else {
                gap = true
            }
        }
        var capped = String(out.prefix(limit))
        while capped.hasSuffix("-") { capped.removeLast() }
        return capped
    }

    /// The handle of every route, in order: its name as a slug ("dgx-spark"); routes whose slugs clash all take the
    /// long form, name and model ("guardian-claude-sonnet-5-5"); a clash left after that gets "-2", "-3" in order.
    /// "primary" is the chat's own model, so a route that would be called that is "primary-route".
    public static func handles(for routes: [RouteFacts]) -> [String] {
        func tidy(_ slug: String) -> String {
            if slug.isEmpty { return "route" }
            return slug == primaryID ? "primary-route" : slug
        }
        let bases = routes.map { tidy(slug($0.label)) }
        var counts: [String: Int] = [:]
        for base in bases { counts[base, default: 0] += 1 }
        let candidates = routes.enumerated().map { index, route in
            counts[bases[index], default: 0] > 1 ? tidy(slug(route.label + " " + route.configuredModel, limit: 48)) : bases[index]
        }
        var used = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            var handle = candidate
            var n = 2
            while used.contains(handle) {
                handle = "\(candidate)-\(n)"
                n += 1
            }
            used.insert(handle)
            out.append(handle)
        }
        return out
    }

    // MARK: What the model is told

    /// The heading of the catalogue in the agent tool's description.
    public static let catalogueHeader =
        "Subagent servers — set `server` to one of these ids to choose where a task runs, or leave it out and Vision picks the least busy:"
    /// Its last sentence.
    public static let loadNote =
        "How busy each server is comes back with every agent and delegate result, and from agent_status."

    /// The catalogue: one line per server, then the privacy guidance. Stable — no load, health or counts — so the tool
    /// description (and the prompt cache) only changes when the pool really does. Nil when there is no server besides
    /// the chat's own model.
    public static func describe(_ pool: SubagentPool) -> String? {
        guard pool.hasWorkers else { return nil }
        var lines = [catalogueHeader]
        for entry in pool.entries { lines.append(line(entry, overflow: pool.overflow)) }
        if pool.entries.contains(where: { !$0.isPrivate }) {
            lines.append(SubagentServers.guidance
                         + " A task that needs sensitive data gets sensitive: true, so it runs only on a private server. " + loadNote)
        } else {
            lines.append("All of them are private. " + loadNote)
        }
        return lines.joined(separator: "\n")
    }

    /// "- dgx-spark: OpenAI-compatible server · qwen3-coder-30b · 256K context · private · local · fast · 2 at a time"
    public static func line(_ entry: Entry, overflow: Bool) -> String {
        if entry.isPrimary {
            return "- \(primaryID): this chat's own model (\(entry.model) on \(entry.label)) · "
                + (overflow ? "used when the others are busy" : "used only when you choose it")
        }
        var text = "- \(entry.id): \(entry.provider) · \(entry.model)"
        if let context = entry.context { text += " · \(context) context" }
        text += " · " + (entry.isPrivate ? "private" : "not private")
        text += " · \(entry.tier.rawValue) · \(entry.speed.rawValue)"
        if entry.images { text += " · images" }
        if entry.ownAgent { text += " · runs its own agent in this chat's folder" }
        text += " · \(entry.parallel) at a time"
        return text
    }

    /// How busy one server is now.
    public struct Load: Hashable, Sendable {
        public var inFlight: Int
        public var healthy: Bool
        /// Seconds until a server that isn't answering is tried again.
        public var retryIn: TimeInterval?

        public init(inFlight: Int, healthy: Bool = true, retryIn: TimeInterval? = nil) {
            self.inFlight = inFlight
            self.healthy = healthy
            self.retryIn = retryIn
        }
    }

    /// "Subagent servers now: dgx-spark 1/2 busy · claude-code-sonnet 0/2 busy, not answering (back in 45s) · primary
    /// 0/4 busy." — for tool results, never descriptions. `loads` is keyed by entry id; nil without servers besides the
    /// chat's own model.
    public static func loadLine(_ pool: SubagentPool, loads: [String: Load]) -> String? {
        guard pool.hasWorkers else { return nil }
        let parts = pool.entries.map { entry -> String in
            let load = loads[entry.id] ?? Load(inFlight: 0)
            var part = "\(entry.id) \(load.inFlight)/\(entry.parallel) busy"
            if !load.healthy {
                part += ", not answering"
                if let retry = load.retryIn, retry > 0 { part += " (back in \(retryWords(retry)))" }
            }
            return part
        }
        return "Subagent servers now: " + parts.joined(separator: " · ") + "."
    }

    /// 45 → "45s", 900 → "15m", 7200 → "2h" (rounded up).
    public static func retryWords(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 120 { return "\(s)s" }
        let m = (s + 59) / 60
        if m < 120 { return "\(m)m" }
        return "\((m + 59) / 60)h"
    }

    // MARK: The `server` argument

    /// What a `server` argument names: one of the pool's entries, or the error the model gets back.
    public enum Choice: Equatable, Sendable {
        case entry(Entry)
        case error(String)
    }

    /// Match a `server` argument: a handle (any case), then an exact route id, then "primary", then a part of one
    /// handle or name that fits only one server. Anything else is an error that says what there is — before anything
    /// runs.
    public static func match(_ raw: String, in pool: SubagentPool) -> Choice {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let workers = pool.workers
        if let hit = workers.first(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame }) { return .entry(hit) }
        if let hit = pool.entries.first(where: { $0.routeID == value }) { return .entry(hit) }
        if value.caseInsensitiveCompare(primaryID) == .orderedSame, let primary = pool.primary { return .entry(primary) }
        let wanted = value.lowercased()
        if !wanted.isEmpty {
            let hits = workers.filter { $0.id.contains(wanted) || $0.label.lowercased().contains(wanted) }
            if hits.count == 1 { return .entry(hits[0]) }
        }
        return .error(unknownServer(value, in: pool))
    }

    /// "Error: “kimi” isn't one of this chat's subagent servers. Use one of: dgx-spark, bedrock, primary — or leave
    /// server out." — and, when it names an enlisted route this chat can't use, why.
    public static func unknownServer(_ value: String, in pool: SubagentPool) -> String {
        let ids = pool.workers.map(\.id) + (pool.primary == nil ? [] : [primaryID])
        var text = "Error: “\(value)” isn't one of this chat's subagent servers. "
        text += ids.isEmpty ? "This chat has none to choose from — leave server out."
            : "Use one of: \(ids.joined(separator: ", ")) — or leave server out."
        if let gone = pool.dropped.first(where: { $0.id.caseInsensitiveCompare(value) == .orderedSame || $0.routeID == value }) {
            text += " (\(value) is \(gone.reason).)"
        }
        return text
    }

    /// A pool made from a fleet's configured servers, for a context the app didn't give one (tests, a fleet with no
    /// chat): each server by its handle (else its name as a slug), the configured primary as "primary".
    public static func from(servers: [FleetServer]) -> SubagentPool {
        let entries = servers.map { server in
            Entry(id: server.isPrimary ? primaryID : (server.handle ?? slug(server.label)), routeID: server.id,
                  label: server.label, provider: "", model: "", context: nil, isPrivate: server.isPrivate, tier: .api,
                  speed: .standard, images: true, ownAgent: false, parallel: server.maxParallel,
                  machine: server.machine ?? "route:" + server.id, kind: .openAICompatible,
                  interactiveOnly: server.interactiveOnly, isPrimary: server.isPrimary)
        }
        return SubagentPool(entries: entries.filter { !$0.isPrimary } + entries.filter(\.isPrimary))
    }
}

// MARK: - From a configured route

extension SubagentPool.Kind {
    /// The pool's word for a route kind.
    public init(_ kind: ProviderProfile.Kind) {
        switch kind {
        case .openAICompat: self = .openAICompatible
        case .ollama: self = .ollama
        case .lmStudio: self = .lmStudio
        case .openAI: self = .openAI
        case .openRouter: self = .openRouter
        case .bedrock: self = .bedrock
        case .guardian: self = .guardian
        case .anthropic: self = .anthropic
        case .claudeCode: self = .claudeCode
        }
    }
}

extension SubagentPool.RouteFacts {
    /// The facts about a configured route (or one of Guardian's live models). `model`, `contextWindow` and `images`
    /// are what the app knows now: the model its server last reported, the window it settled on, whether it takes
    /// pictures.
    public init(route: ProviderProfile, enlisted: Bool, model: String? = nil, contextWindow: Int?, images: Bool) {
        let plan = PlanCatalog.plan(for: route)
        self.init(routeID: route.routeID, name: route.name, model: model ?? route.model, kind: SubagentPool.Kind(route.kind),
                  baseURL: route.baseURL, enlisted: enlisted, privateSwitch: route.isPrivateRoute,
                  interactiveOnly: route.isInteractiveOnly, parallel: route.subagentParallel, contextWindow: contextWindow,
                  images: route.kind == .claudeCode ? false : images, planProvider: plan?.provider,
                  planSubscription: PlanCatalog.isSubscription(route), privateAddress: RoutePrivacy.isPrivateAddress(route.baseURL),
                  selfHosted: route.isSelfHosted)
    }
}
