import Foundation
import Observation
import VisionHarnessCore

/// The pages of the "Connect a subscription plan" guide, in order.
enum PlanPage: Int, CaseIterable, Comparable {
    case plan, key, paste, check, model, use, done

    static func < (a: PlanPage, b: PlanPage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .plan: "Which plan?"
        case .key: "Get your key"
        case .paste: "Paste your key"
        case .check: "Check it"
        case .model: "Pick the model"
        case .use: "How Vision uses it"
        case .done: "Done"
        }
    }
}

/// How a plan's model is used. Like `ModelRole`, plus leaving it in the list for later.
enum PlanRole: String, CaseIterable, Identifiable {
    case primary, subagent, backup, justAdd
    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: "Primary"
        case .subagent: "Subagent"
        case .backup: "Backup"
        case .justAdd: "Just add it"
        }
    }

    var detail: String {
        switch self {
        case .primary: "Answers you, and hands out side tasks. Whatever led before keeps helping as a subagent server."
        case .subagent: "Takes side tasks from the primary, in parallel. They count against the plan."
        case .backup: "Takes over a turn when the primary stops answering."
        case .justAdd: "Keep it in Settings ▸ AI Models, to use when you choose it."
        }
    }

    var icon: String {
        switch self {
        case .primary: "crown"
        case .subagent: "gearshape.2"
        case .backup: "arrow.triangle.branch"
        case .justAdd: "plus.circle"
        }
    }
}

struct PlanGuideRequest: Identifiable {
    let id = UUID()
    /// Open on this plan, already chosen ("zai" for the Z.ai (GLM) entry in the wizard and Settings).
    var planID: String? = nil
    /// The screenshot mode's stand-ins: a scripted backend, and what to do once the guide is up.
    var backend: (any PlanGuideBackend)? = nil
    var stage: (@MainActor (PlanGuideModel) -> Void)? = nil
}

/// What the guide does outside: the plan's API, and the browser.
@MainActor
protocol PlanGuideBackend: AnyObject {
    /// `GET <base>/models`.
    func listModels(route: ProviderProfile) async throws -> [String]
    /// A 1-token chat completion with `model` — for plans whose `/models` doesn't answer.
    func ping(route: ProviderProfile, model: String) async throws
    func sayHello(route: ProviderProfile) async throws -> String
    func open(_ url: URL)
}

/// The "Connect a subscription plan" guide: pick the plan and region, get the key (steps, the key page, the
/// plan's terms), paste it (to the Keychain), check it, pick the model, choose how Vision uses it — the route is not
/// private, so Vision masks sensitive details before sending — then save it and say hello.
@MainActor
@Observable
final class PlanGuideModel {
    @ObservationIgnored let backend: any PlanGuideBackend
    @ObservationIgnored let config: AppConfig
    @ObservationIgnored var onSaved: (ProviderProfile) -> Void = { _ in }
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onLeave: () -> Void = {}

    private(set) var page: PlanPage = .plan
    var title: String { "Connect a subscription plan · \(page.title)" }
    var stepText: String { "Step \(page.rawValue + 1) of \(PlanPage.allCases.count)" }

    // MARK: Choices

    private(set) var planID: String?
    var regionID = "international" {
        didSet { if regionID != oldValue { resetCheck() } }
    }
    var key = "" {
        didSet { if key != oldValue { resetCheck() } }
    }

    var plan: SubscriptionPlan? { planID.flatMap(PlanCatalog.plan) }
    var region: SubscriptionPlan.Region? { plan?.region(regionID) }
    var keyProblem: String? { plan.flatMap { PlanCatalog.keyProblem(key, plan: $0) } }

    // MARK: Checking

    private(set) var checking = false
    private(set) var checked = false
    private(set) var checkError: String?
    /// The region (Z.ai: endpoint) the key turned out to work on instead — offered as a one-click switch.
    private(set) var suggestedRegion: String?
    /// What `/models` listed (nil when it wasn't asked or didn't answer).
    private(set) var listed: [String]?

    // MARK: The model and how it's used

    private(set) var selectedModel: String?
    var role: PlanRole {
        didSet { roleChosen = true }
    }
    var isPrivate = false {
        didSet { privacyChosen = true }
    }
    /// The user picked a role / set the privacy (when the route exists already, only what they picked changes).
    private(set) var roleChosen = false
    private(set) var privacyChosen = false

    // MARK: Saving

    private(set) var saving = false
    private(set) var saved: ProviderProfile?
    private(set) var hello: String?
    private(set) var helloError: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(backend: any PlanGuideBackend, config: AppConfig, planID: String? = nil) {
        self.backend = backend
        self.config = config
        role = config.mainRoute == nil ? .primary : .justAdd
        if let planID { choose(planID) }
    }

    func dispose() { task?.cancel() }

    func choose(_ id: String) {
        guard id != planID, let chosen = PlanCatalog.plan(id) else { return }
        planID = id
        if !chosen.regions.contains(where: { $0.id == regionID }) { regionID = chosen.regions[0].id }
        resetCheck()
        // Every plan is an online service: not private unless the user says so.
        isPrivate = RoutePrivacy.isPrivateAddress(chosen.region(regionID).baseURL)
        privacyChosen = false
    }

    private func resetCheck() {
        checked = false
        checkError = nil
        suggestedRegion = nil
        listed = nil
        selectedModel = nil
        saved = nil
        hello = nil
        helloError = nil
    }

    // MARK: Navigation

    var nextLabel: String {
        switch page {
        case .use: "Save and Say Hello"
        case .done: "Start Chatting"
        default: "Next"
        }
    }

    var canAdvance: Bool {
        switch page {
        case .plan: return plan != nil
        case .key: return true
        case .paste: return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .check: return checked && !checking
        case .model: return selectedModel != nil
        case .use: return true
        case .done: return saved != nil && !saving
        }
    }

    func next() {
        guard canAdvance else { return }
        if page == .done { onFinish(); return }
        if let following = PlanPage(rawValue: page.rawValue + 1) { go(following) }
    }

    func back() {
        if page == .plan { onLeave(); return }
        go(PlanPage(rawValue: page.rawValue - 1) ?? .plan)
    }

    func go(_ target: PlanPage) {
        page = target
        switch target {
        case .check where !checked && !checking: runCheck()
        case .model where selectedModel == nil: selectedModel = models.first?.id
        case .done where saved == nil && !saving: saveAndSayHello()
        default: break
        }
    }

    // MARK: The route

    /// The key as pasted, minus the spaces around it.
    private var cleanKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The route this guide makes: OpenAI-compatible (OpenAI's own for OpenAI, the Messages API for Anthropic), at the region's address, the
    /// privacy the user chose (stored only when it differs from the default), interactive-only when the plan says.
    func route(model: String) -> ProviderProfile? {
        guard let plan, let region else { return nil }
        let name = region.routeName
            ?? (plan.regions.count > 1 && region.id != "international" ? "\(plan.routeName) (\(region.name.components(separatedBy: " (").first ?? region.name))" : plan.routeName)
        let defaultPrivacy = RoutePrivacy.isPrivateAddress(region.baseURL)
        let kind: ProviderProfile.Kind = switch plan.id {
        case "openai": .openAI
        case "anthropic": .anthropic
        default: .openAICompat
        }
        return ProviderProfile(kind: kind, name: name, baseURL: region.baseURL,
                               apiKey: cleanKey.isEmpty ? nil : cleanKey, model: model,
                               isPrivate: isPrivate == defaultPrivacy ? nil : isPrivate,
                               interactiveOnly: plan.interactiveOnly ? true : nil)
    }

    // MARK: Checking

    /// `GET /models` for a plan that lists them (a 404 or 405 falls back to a 1-token reply), else a 1-token
    /// reply from the recommended model.
    func runCheck() {
        guard let plan, let region, let probe = route(model: plan.recommended?.id ?? "") else { return }
        checking = true
        checkError = nil
        suggestedRegion = nil
        task?.cancel()
        if plan.checksWithChat, let endpoint = ZAIErrors.Endpoint(rawValue: region.id), let model = plan.recommended?.id {
            task = Task { await checkZai(probe: probe, endpoint: endpoint, model: model) }
            return
        }
        task = Task {
            defer { checking = false }
            do {
                if plan.listsModels {
                    do {
                        listed = try await backend.listModels(route: probe)
                    } catch let error where Self.notListed(error) {
                        guard let model = plan.recommended?.id else { throw error }
                        try await backend.ping(route: probe, model: model)
                    }
                } else if let model = plan.recommended?.id {
                    try await backend.ping(route: probe, model: model)
                }
                checked = true
                selectedModel = models.first?.id
            } catch is CancellationError {
            } catch {
                checkError = PlanCatalog.explain(error, plan: plan, region: region)
            }
        }
    }

    /// Z.ai: a one-token reply on the chosen endpoint (listing models proves nothing — any valid key lists them, on
    /// any endpoint). When the key doesn't fit, it is tried on the endpoints it may belong to, and the guide says
    /// which one it works on ("This looks like a GLM Coding Plan key — switch the endpoint to Coding Plan").
    private func checkZai(probe: ProviderProfile, endpoint: ZAIErrors.Endpoint, model: String) async {
        defer { checking = false }
        let backend = self.backend
        let result = await ZAIDiagnosis.run(endpoint: endpoint, model: model) { candidate in
            var route = probe
            route.baseURL = candidate.baseURL
            try await backend.ping(route: route, model: model)
        }
        if Task.isCancelled { return }
        guard result.ok else {
            checkError = result.message
            suggestedRegion = result.worksOn?.rawValue
            return
        }
        listed = try? await backend.listModels(route: probe)
        checked = true
        selectedModel = models.first?.id
    }

    /// Switch to the region (endpoint) the key worked on, and check again there.
    func switchToSuggested() {
        guard let suggested = suggestedRegion else { return }
        regionID = suggested
        runCheck()
    }

    /// `/models` isn't there (404, 405): the key may still be fine.
    private static func notListed(_ error: Error) -> Bool {
        if case LLMError.http(let status, _) = error { return status == 404 || status == 405 }
        return false
    }

    // MARK: Models

    /// What `/models` listed (for a plan that lists them), else the plan's own; recommended first.
    var models: [SubscriptionPlan.Model] {
        guard let plan else { return [] }
        return PlanCatalog.models(for: plan, listed: listed)
    }

    func pick(_ id: String) { selectedModel = id }

    /// The context window, when known ("1M context").
    func contextText(_ model: SubscriptionPlan.Model) -> String? {
        let window = model.contextWindow ?? FallbackContextWindow.limit(for: model.id)
        return window.map { "\(ModelSizes.short($0)) context" }
    }

    // MARK: Saving

    private func saveAndSayHello() {
        guard let model = selectedModel, let route = route(model: model) else { return }
        saving = true
        let key = route.apiKey ?? ""
        // The same plan with the same key is this route again: it keeps the user's settings. Another key (a second
        // subscription) is another route, with a name of its own.
        let config = self.config
        let (saved, isNew) = config.saveGuided(route, key: key, privacyChosen: privacyChosen) { existing in
            SwapperConnection.sameBase(existing.baseURL, route.baseURL) && config.apiKey(for: existing) == key
        }
        if isNew || roleChosen {
            switch role {
            case .primary: config.makeMain(saved.routeID)
            case .subagent: config.setSubagentWorker(saved.routeID, true)
            case .backup: config.setBackup(saved.routeID, true)
            case .justAdd: break
            }
        }
        if config.mainRoute == nil { config.makeMain(saved.routeID) }
        self.saved = saved
        onSaved(saved)
        sayHello()
    }

    func sayHello() {
        guard var route = saved else { return }
        route.apiKey = cleanKey
        saving = true
        helloError = nil
        task?.cancel()
        task = Task {
            defer { saving = false }
            do {
                hello = try await backend.sayHello(route: route)
            } catch is CancellationError {
            } catch {
                if let plan, let region {
                    helloError = PlanCatalog.explain(error, plan: plan, region: region)
                } else {
                    helloError = error.localizedDescription
                }
            }
        }
    }

    func openKeyPage() {
        if let region { backend.open(region.keyPage) }
    }
}
