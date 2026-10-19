import Foundation

// MARK: - Subscription and API plans
//
// The plans the "Connect a subscription plan" guide knows: Z.ai's GLM Coding Plan and API, Kimi Code and the
// Moonshot API, OpenAI's API, and Alibaba Cloud's Qwen Coding Plan and Model Studio API — where each lives, where
// its key comes from, which models it offers, and what its terms ask of Vision. (Researched October 2026.)

/// One plan.
public struct SubscriptionPlan: Sendable, Equatable, Identifiable {
    /// A region the plan is sold in, with its own address and key page.
    public struct Region: Sendable, Equatable, Identifiable {
        public var id: String
        /// "International", "China"
        public var name: String
        public var baseURL: String
        public var keyPage: URL
        /// What to open on the key page when it isn't obvious ("Coding Plan", "API Keys").
        public var keyPlace: String?
        /// The saved route's name, when this region (endpoint) names it differently ("GLM Coding Plan").
        public var routeName: String?
        /// One line under the picker ("Coding Plan keys work only here").
        public var detail: String?
        /// A subscription here, when it differs from the plan's own (Z.ai: Coding Plan vs the per-token API).
        public var isSubscription: Bool?

        public init(id: String, name: String, baseURL: String, keyPage: URL, keyPlace: String? = nil,
                    routeName: String? = nil, detail: String? = nil, isSubscription: Bool? = nil) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.keyPage = keyPage
            self.keyPlace = keyPlace
            self.routeName = routeName
            self.detail = detail
            self.isSubscription = isSubscription
        }
    }

    /// A model the plan offers.
    public struct Model: Sendable, Equatable, Identifiable {
        public var id: String
        /// "K2.8, up to 1M"
        public var note: String?
        public var contextWindow: Int?

        public init(_ id: String, note: String? = nil, contextWindow: Int? = nil) {
            self.id = id
            self.note = note
            self.contextWindow = contextWindow
        }
    }

    public var id: String
    /// "Z.ai", "Kimi", "OpenAI", "Alibaba Cloud"
    public var provider: String
    /// "Z.ai — GLM Coding Plan"
    public var name: String
    /// The route's name once saved ("GLM Coding Plan").
    public var routeName: String
    /// One line for the guide's card.
    public var summary: String
    public var regions: [Region]
    /// A monthly subscription (as opposed to paying per token).
    public var isSubscription: Bool
    /// Where to subscribe, when the plan says.
    public var subscribeURL: URL?
    /// What the key looks like.
    public var keyHint: String
    /// The plan's own models, recommended first (the fallback when `/models` doesn't list them).
    public var models: [Model]
    /// Whether `GET /models` is expected to answer with the plan's models.
    public var listsModels: Bool
    /// What the plan's terms ask, in a sentence.
    public var terms: String
    /// The terms allow only interactive use: the route is made `interactiveOnly`.
    public var interactiveOnly: Bool
    /// What the guide calls the choice between regions: "Region", or "Endpoint" (Z.ai).
    public var regionLabel = "Region"
    /// Checking the key takes a one-token reply even when `/models` answers (Z.ai lists models for any valid key,
    /// on any endpoint, while only the right endpoint can chat).
    public var checksWithChat = false

    public var recommended: Model? { models.first }

    public func region(_ id: String?) -> Region {
        regions.first { $0.id == id } ?? regions[0]
    }

    /// The numbered steps to get a key, for the guide.
    public func keySteps(region: Region) -> [String] {
        let site = region.keyPage.host ?? region.keyPage.absoluteString
        var steps = ["Sign in at **\(site)** (or create an account)."]
        if region.isSubscription ?? isSubscription {
            let where_ = subscribeURL.map { " at **\($0.host ?? $0.absoluteString)\($0.path)**" } ?? ""
            steps.append("Subscribe to the plan\(where_) if you haven't yet.")
        } else {
            steps.append("Add a payment method or credit if the account has none.")
        }
        steps.append("Open the key page" + (region.keyPlace.map { " — **\($0)**" } ?? "") + ".")
        steps.append("Create a key and copy it. It's shown only once.")
        return steps
    }
}

public enum PlanCatalog {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    public static let plans: [SubscriptionPlan] = [
        zai,
        SubscriptionPlan(
            id: "kimi-code", provider: "Kimi", name: "Kimi Code (subscription)", routeName: "Kimi Code",
            summary: "Kimi's coding subscription: K2.8 with up to 1M context, and K3.",
            regions: [
                .init(id: "international", name: "International", baseURL: "https://api.kimi.ai/coding/v1",
                      keyPage: url("https://www.kimi.com/code/console"), keyPlace: "API Keys (up to 5)"),
                .init(id: "china", name: "China", baseURL: "https://api.kimi.com/coding/v1",
                      keyPage: url("https://www.kimi.com/code/console"), keyPlace: "API Keys (up to 5)"),
            ],
            isSubscription: true, subscribeURL: nil,
            keyHint: "Starts with sk-.",
            models: [.init("kimi-for-coding", note: "K2.8, up to 1M", contextWindow: 1_000_000), .init("k3"),
                     .init("k3-256k", contextWindow: 262_144), .init("kimi-for-coding-highspeed")],
            listsModels: false,
            terms: "Kimi Code is for coding apps that call it as themselves: Vision tells Kimi it is Vision, and never imitates another tool.",
            interactiveOnly: false),
        SubscriptionPlan(
            id: "moonshot-api", provider: "Moonshot", name: "Moonshot (Kimi) — pay-as-you-go API", routeName: "Moonshot",
            summary: "Kimi models on Moonshot's own platform, paid from prepaid credit.",
            regions: [
                .init(id: "international", name: "International", baseURL: "https://api.moonshot.ai/v1",
                      keyPage: url("https://platform.moonshot.ai/console/api-keys")),
                .init(id: "china", name: "China", baseURL: "https://api.moonshot.cn/v1",
                      keyPage: url("https://platform.moonshot.cn/console/api-keys")),
            ],
            isSubscription: false, subscribeURL: nil,
            keyHint: "Starts with sk-. A key works only in the region it was made in.",
            models: [.init("kimi-k2.7-code")],
            listsModels: true,
            terms: "Prepaid credit; keys are region-specific.",
            interactiveOnly: false),
        SubscriptionPlan(
            id: "openai", provider: "OpenAI", name: "OpenAI API", routeName: "OpenAI",
            summary: "GPT models through OpenAI's API, billed per token.",
            regions: [
                .init(id: "international", name: "International", baseURL: "https://api.openai.com/v1",
                      keyPage: url("https://platform.openai.com/api-keys")),
            ],
            isSubscription: false, subscribeURL: nil,
            keyHint: "Starts with sk- (often sk-proj-).",
            models: [],
            listsModels: true,
            terms: "A ChatGPT Plus or Pro subscription doesn't include API access — the API is billed separately at platform.openai.com.",
            interactiveOnly: false),
        SubscriptionPlan(
            id: "qwen-coding", provider: "Alibaba Cloud", name: "Qwen — Alibaba Cloud Coding Plan", routeName: "Qwen Coding Plan",
            summary: "A monthly plan for Qwen3.7, Qwen3 Coder and more, for working in coding tools yourself.",
            regions: [
                .init(id: "international", name: "International", baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1",
                      keyPage: url("https://modelstudio.console.alibabacloud.com/"), keyPlace: "Coding Plan"),
                .init(id: "china", name: "China", baseURL: "https://coding.dashscope.aliyuncs.com/v1",
                      keyPage: url("https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan"), keyPlace: "Coding Plan"),
            ],
            isSubscription: true, subscribeURL: nil,
            keyHint: "Starts with sk-sp-. (A plain sk- key is a pay-as-you-go key.)",
            models: [.init("qwen3.7-plus"), .init("qwen3.6-plus"), .init("qwen3-coder-plus"), .init("qwen3-coder-next"),
                     .init("qwen3.5-plus"), .init("kimi-k2.5"), .init("glm-5"), .init("MiniMax-M2.5")],
            listsModels: false,
            terms: "Alibaba allows the Coding Plan only for interactive use in coding tools — not for automated scripts or unattended work. Vision won't run the task queue on it.",
            interactiveOnly: true),
        SubscriptionPlan(
            id: "qwen-api", provider: "Alibaba Cloud", name: "Qwen — Model Studio pay-as-you-go", routeName: "Qwen (Model Studio)",
            summary: "Qwen models through Alibaba Cloud Model Studio, billed per token.",
            regions: [
                .init(id: "international", name: "International", baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                      keyPage: url("https://modelstudio.console.alibabacloud.com/"), keyPlace: "API Keys"),
                .init(id: "china", name: "China", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                      keyPage: url("https://bailian.console.aliyun.com/"), keyPlace: "API-KEY"),
            ],
            isSubscription: false, subscribeURL: nil,
            keyHint: "Starts with sk-.",
            models: [.init("qwen3.7-plus")],
            listsModels: true,
            terms: "Billed per token.",
            interactiveOnly: false),
    ]

    /// Z.ai (GLM): one provider, four endpoints. A GLM Coding Plan key works only on the Coding Plan endpoint (on
    /// the General API it gets 1113 "Insufficient balance"); a key made at open.bigmodel.cn works only on the China
    /// endpoints. Models from docs.z.ai (2026-10-18): glm-5.3 (1M, always thinks: low/high/max), glm-5.2, glm-5.1,
    /// glm-5, glm-4.7, glm-4.6 (text), glm-5.3-flash / -flashx (vision).
    static let zai = configured(SubscriptionPlan(
        id: "zai", provider: "Z.ai", name: "Z.ai (GLM)", routeName: "Z.ai",
        summary: "GLM-5.3 and the other GLM models — with a GLM Coding Plan, or pay-as-you-go.",
        regions: [
            .init(id: ZAIErrors.Endpoint.coding.rawValue, name: "Coding Plan", baseURL: ZAIErrors.Endpoint.coding.baseURL,
                  keyPage: url("https://z.ai/manage-apikey/apikey-list"), keyPlace: "API Keys", routeName: "GLM Coding Plan",
                  detail: "For a GLM Coding Plan subscription — Coding Plan keys work only here.", isSubscription: true),
            .init(id: ZAIErrors.Endpoint.general.rawValue, name: "General API", baseURL: ZAIErrors.Endpoint.general.baseURL,
                  keyPage: url("https://z.ai/manage-apikey/apikey-list"), keyPlace: "API Keys", routeName: "Z.ai API",
                  detail: "Pay-as-you-go: billed per token from the account's balance.", isSubscription: false),
            .init(id: ZAIErrors.Endpoint.chinaCoding.rawValue, name: "China — Coding Plan", baseURL: ZAIErrors.Endpoint.chinaCoding.baseURL,
                  keyPage: url("https://open.bigmodel.cn/usercenter/apikeys"), keyPlace: "API Keys", routeName: "GLM Coding Plan (China)",
                  detail: "A Coding Plan bought at open.bigmodel.cn.", isSubscription: true),
            .init(id: ZAIErrors.Endpoint.chinaGeneral.rawValue, name: "China — General API", baseURL: ZAIErrors.Endpoint.chinaGeneral.baseURL,
                  keyPage: url("https://open.bigmodel.cn/usercenter/apikeys"), keyPlace: "API Keys", routeName: "Z.ai API (China)",
                  detail: "Pay-as-you-go at open.bigmodel.cn.", isSubscription: false),
        ],
        isSubscription: true, subscribeURL: url("https://z.ai/subscribe"),
        keyHint: "A long string of letters and digits with a dot in the middle (not sk-…). A Coding Plan key works only on the Coding Plan endpoint.",
        models: [.init("glm-5.3", note: "1M context · always thinks", contextWindow: 1_000_000),
                 .init("glm-5.2"), .init("glm-5.1"), .init("glm-5"), .init("glm-4.7"), .init("glm-4.6"),
                 .init("glm-5.3-flash", note: "reads images")],
        listsModels: true,
        terms: "Z.ai offers the GLM Coding Plan for use in coding tools; the General API is billed per token.",
        interactiveOnly: false)) {
            $0.regionLabel = "Endpoint"
            $0.checksWithChat = true
        }

    private static func configured(_ plan: SubscriptionPlan, _ edit: (inout SubscriptionPlan) -> Void) -> SubscriptionPlan {
        var plan = plan
        edit(&plan)
        return plan
    }

    /// Plan ids from earlier builds, still understood.
    static let renamed = ["zai-coding": "zai", "zai-api": "zai"]

    public static func plan(_ id: String) -> SubscriptionPlan? {
        let id = renamed[id] ?? id
        return plans.first { $0.id == id }
    }

    /// The plan a route was made from, recognised by its address (nil for anything else).
    public static func plan(for route: ProviderProfile) -> SubscriptionPlan? {
        let base = route.baseURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return plans.first { plan in
            plan.regions.contains { base == $0.baseURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        }
    }

    // MARK: The key

    /// A hint for a pasted key that is recognisably the wrong one (nil when nothing stands out).
    public static func keyProblem(_ raw: String, plan: SubscriptionPlan) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key.contains(where: \.isWhitespace) { return "The key has spaces or line breaks in it. Copy it again, in one piece." }
        if key.hasPrefix("Bearer ") || key.lowercased().hasPrefix("bearer ") { return "Paste the key alone, without “Bearer”." }
        switch plan.id {
        case "qwen-coding":
            if key.hasPrefix("sk-") && !key.hasPrefix("sk-sp-") {
                return "That looks like a pay-as-you-go Model Studio key (sk-…). A Coding Plan key starts with sk-sp- — it's on the Coding Plan page. Or choose “Qwen — Model Studio pay-as-you-go” for this key."
            }
        case "qwen-api":
            if key.hasPrefix("sk-sp-") {
                return "That's a Coding Plan key (sk-sp-…). Choose “Qwen — Alibaba Cloud Coding Plan” for it."
            }
        case "openai":
            if !key.hasPrefix("sk-") { return "OpenAI keys start with sk-. Copy the key from platform.openai.com/api-keys." }
        case "kimi-code", "moonshot-api":
            if !key.hasPrefix("sk-") { return "Kimi and Moonshot keys start with sk-." }
        case "zai":
            if key.hasPrefix("sk-") { return "That looks like another service's key. Z.ai keys come from z.ai (or open.bigmodel.cn) and don't start with sk-." }
        default:
            break
        }
        return nil
    }

    // MARK: Checking it

    /// What a failed check means, in plain words.
    public static func explain(_ error: Error, plan: SubscriptionPlan, region: SubscriptionPlan.Region) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .http(let status, let body), .rejected(let status, _, let body, _):
                return explain(status: status, body: body, plan: plan, region: region)
            case .connection, .sse:
                return "Couldn't reach \(region.baseURL). Check your internet connection, then try again."
            default:
                break
            }
        }
        if error is URLError {
            return "Couldn't reach \(region.baseURL). Check your internet connection, then try again."
        }
        return error.localizedDescription
    }

    static func explain(status: Int, body: String, plan: SubscriptionPlan, region: SubscriptionPlan.Region) -> String {
        let regionName = region.name.components(separatedBy: " (").first ?? region.name
        if plan.id == "zai", let explained = ZAIErrors.explain(status: status, body: body,
                                                                endpoint: ZAIErrors.Endpoint(rawValue: region.id),
                                                                model: plan.recommended?.id ?? "glm-5.3") {
            return explained.message
        }
        if plan.id == "kimi-code" || plan.id == "moonshot-api",
           let explained = KimiErrors.explain(status: status, body: body, provider: plan.id == "kimi-code" ? .kimiCode : .moonshot,
                                              model: plan.recommended?.id ?? "") {
            return explained.message
        }
        switch status {
        case 401:
            return "The key wasn't accepted — check it's a \(plan.name) key for the \(regionName) region."
        case 403:
            if plan.id == "kimi-code" { return kimiRestriction }
            return "\(plan.name) refused the request (403): \(snippet(body)). The plan may not include this model, or this kind of app."
        case 429:
            return "The plan's usage limit is used up for now. Try again later, or check the plan's usage page."
        case 404:
            return "\(region.baseURL) doesn't know that request (404). Check the region, and that the model is in the plan."
        default:
            return "\(plan.name) replied \(status): \(snippet(body))"
        }
    }

    /// Kimi Code turning Vision away because it is not one of the coding agents the plan names.
    public static let kimiRestriction =
        "Kimi Code answered that it is only for certain coding agents. Vision tells Kimi honestly that it is Vision and won't pretend to be another app. Use the Moonshot platform API instead — “Moonshot (Kimi) — pay-as-you-go API” in this guide — which works with any app."

    /// A chat error from a route that is a Kimi Code plan, explained (nil when it's something else).
    public static func explainChatError(_ error: Error, route: ProviderProfile?) -> String? {
        guard let route, plan(for: route)?.id == "kimi-code", let llm = error as? LLMError else { return nil }
        switch llm {
        case .http(403, _), .rejected(403, _, _, _): return kimiRestriction
        default: return nil
        }
    }

    private static func snippet(_ body: String) -> String {
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = obj["error"] as? [String: Any], let message = error["message"] as? String { return String(message.prefix(200)) }
            if let message = obj["message"] as? String { return String(message.prefix(200)) }
            if let error = obj["error"] as? String { return String(error.prefix(200)) }
        }
        let flat = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? "no details" : String(flat.prefix(200))
    }

    // MARK: Models

    /// The models to offer once the key works: what `/models` listed (for a plan that lists them), else the plan's
    /// own; the recommended one first.
    public static func models(for plan: SubscriptionPlan, listed: [String]?) -> [SubscriptionPlan.Model] {
        guard let listed, !listed.isEmpty, plan.listsModels else { return plan.models }
        var ids = listed
        // Z.ai's list carries other kinds of model (images, speech, embeddings): the chat ones are glm-*.
        if plan.id == "zai" {
            ids = listed.filter { id in
                let lower = id.lowercased()
                return lower.hasPrefix("glm-") && !["embedding", "image", "video", "voice", "asr", "tts", "realtime", "ocr"]
                    .contains { lower.contains($0) }
            }
            if ids.isEmpty { return plan.models }
        }
        if plan.id == "openai" {
            ids = listed.filter(isOpenAIChatModel)
            if let best = recommendedOpenAIModel(listed) { ids = [best] + ids.filter { $0 != best } }
        } else if let recommended = plan.recommended?.id, let at = ids.firstIndex(of: recommended) {
            ids.insert(ids.remove(at: at), at: 0)
        }
        return ids.map { id in plan.models.first { $0.id == id } ?? SubscriptionPlan.Model(id) }
    }

    /// The newest `gpt-*` chat model OpenAI's list has ("gpt-5.2" over "gpt-5" over "gpt-4.1"; a full model over
    /// its mini or nano; the plain alias over a dated snapshot).
    public static func recommendedOpenAIModel(_ ids: [String]) -> String? {
        let chat = ids.filter(isOpenAIChatModel)
        func rank(_ id: String) -> (Double, Int, Int, Int) {
            let rest = id.dropFirst(4)   // after "gpt-"
            let number = rest.prefix { $0.isNumber || $0 == "." }
            let version = Double(number) ?? 0
            let lower = id.lowercased()
            let size = lower.contains("nano") ? 0 : lower.contains("mini") ? 1 : 2
            let dated = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? 0 : 1
            return (version, size, dated, -id.count)
        }
        return chat.max { rank($0) < rank($1) }
    }

    /// A `gpt-*` model that chats (not audio, realtime, speech, images or search).
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        guard lower.hasPrefix("gpt-"), lower.dropFirst(4).first?.isNumber == true else { return false }
        let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search", "instruct", "embedding", "moderation"]
        return !excluded.contains { lower.contains($0) }
    }
}

// MARK: - GLM's thinking

/// GLM-5.3 always thinks: a request that turns thinking off (`enable_thinking: false`, `thinking.type: disabled`)
/// fails, and its `reasoning_effort` words are `low`, `high` and `max`.
public enum GLMThinking {
    /// Whether a route's model follows these rules: anything on Z.ai / BigModel, and any GLM-5 model wherever it
    /// runs (the Qwen Coding Plan serves `glm-5`) — the same scope as Vision for Windows.
    public static func applies(to profile: ProviderProfile, model: String) -> Bool {
        if model.lowercased().hasPrefix("glm-5") { return true }
        guard let host = URL(string: profile.baseURL)?.host?.lowercased() else { return false }
        return ["z.ai", "bigmodel.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Off → low, Low → low, Medium → high, High → high, Max → max.
    public static func effort(_ level: ThinkingLevel) -> String {
        switch level {
        case .off, .low: "low"
        case .medium, .high: "high"
        case .max: "max"
        }
    }
}
