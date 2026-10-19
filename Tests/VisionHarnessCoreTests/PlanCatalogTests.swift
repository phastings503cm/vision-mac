import XCTest
@testable import VisionHarnessCore

/// The subscription and API plans: where each lives, its key, its models, its terms — and GLM-5.3's thinking.
final class PlanCatalogTests: XCTestCase {
    private func plan(_ id: String) -> SubscriptionPlan { PlanCatalog.plan(id)! }

    func testTheCatalogHasEveryPlanWithItsAddresses() {
        XCTAssertEqual(PlanCatalog.plans.map(\.id), ["zai", "kimi-code", "moonshot-api", "openai", "qwen-coding", "qwen-api"])
        // Z.ai is one provider with four endpoints (the Coding Plan's keys work only on its own).
        XCTAssertEqual(plan("zai").regions.map(\.baseURL),
                       ["https://api.z.ai/api/coding/paas/v4", "https://api.z.ai/api/paas/v4",
                        "https://open.bigmodel.cn/api/coding/paas/v4", "https://open.bigmodel.cn/api/paas/v4"])
        XCTAssertEqual(plan("zai").regions.map(\.name), ["Coding Plan", "General API", "China — Coding Plan", "China — General API"])
        XCTAssertEqual(plan("zai").regionLabel, "Endpoint")
        XCTAssertEqual(PlanCatalog.plan("zai-coding")?.id, "zai", "the old ids still find it")
        XCTAssertEqual(PlanCatalog.plan("zai-api")?.id, "zai")
        let expected: [String: [String]] = [
            "kimi-code": ["https://api.kimi.ai/coding/v1", "https://api.kimi.com/coding/v1"],
            "moonshot-api": ["https://api.moonshot.ai/v1", "https://api.moonshot.cn/v1"],
            "openai": ["https://api.openai.com/v1"],
            "qwen-coding": ["https://coding-intl.dashscope.aliyuncs.com/v1", "https://coding.dashscope.aliyuncs.com/v1"],
            "qwen-api": ["https://dashscope-intl.aliyuncs.com/compatible-mode/v1", "https://dashscope.aliyuncs.com/compatible-mode/v1"],
        ]
        for (id, urls) in expected {
            XCTAssertEqual(plan(id).regions.map(\.baseURL), urls, id)
            XCTAssertEqual(plan(id).regions.first?.name, "International", id)
        }
        XCTAssertEqual(plan("zai").name, "Z.ai (GLM)")
        XCTAssertEqual(plan("kimi-code").name, "Kimi Code (subscription)")
        XCTAssertEqual(plan("moonshot-api").name, "Moonshot (Kimi) — pay-as-you-go API")
        XCTAssertEqual(plan("openai").name, "OpenAI API")
        XCTAssertEqual(plan("qwen-coding").name, "Qwen — Alibaba Cloud Coding Plan")
        XCTAssertEqual(plan("qwen-api").name, "Qwen — Model Studio pay-as-you-go")
    }

    func testWhereEachKeyComesFrom() {
        XCTAssertEqual(plan("zai").regions.map(\.keyPage.absoluteString),
                       ["https://z.ai/manage-apikey/apikey-list", "https://z.ai/manage-apikey/apikey-list",
                        "https://open.bigmodel.cn/usercenter/apikeys", "https://open.bigmodel.cn/usercenter/apikeys"])
        XCTAssertEqual(plan("zai").subscribeURL?.absoluteString, "https://z.ai/subscribe")
        // Subscribing is a step only on the Coding Plan endpoints.
        XCTAssertTrue(plan("zai").keySteps(region: plan("zai").regions[0]).contains { $0.hasPrefix("Subscribe") })
        XCTAssertFalse(plan("zai").keySteps(region: plan("zai").regions[1]).contains { $0.hasPrefix("Subscribe") })
        XCTAssertEqual(plan("kimi-code").regions.first?.keyPage.absoluteString, "https://www.kimi.com/code/console")
        XCTAssertEqual(plan("moonshot-api").regions.map(\.keyPage.absoluteString),
                       ["https://platform.moonshot.ai/console/api-keys", "https://platform.moonshot.cn/console/api-keys"])
        XCTAssertEqual(plan("openai").regions.first?.keyPage.absoluteString, "https://platform.openai.com/api-keys")
        XCTAssertEqual(plan("qwen-coding").regions.map(\.keyPage.absoluteString),
                       ["https://modelstudio.console.alibabacloud.com/", "https://bailian.console.aliyun.com/cn-beijing/subscription/coding-plan"])
        XCTAssertEqual(plan("qwen-api").regions.map(\.keyPage.absoluteString),
                       ["https://modelstudio.console.alibabacloud.com/", "https://bailian.console.aliyun.com/"])
        for p in PlanCatalog.plans {
            let steps = p.keySteps(region: p.regions[0])
            XCTAssertTrue(steps.last?.contains("shown only once") == true, p.id)
            XCTAssertTrue(steps.first?.hasPrefix("Sign in") == true, p.id)
        }
    }

    func testTheModelsRecommendedFirst() {
        XCTAssertEqual(plan("zai").models.map(\.id), ["glm-5.3", "glm-5.2", "glm-5.1", "glm-5", "glm-4.7", "glm-4.6", "glm-5.3-flash"])
        XCTAssertEqual(plan("zai").recommended?.contextWindow, 1_000_000)
        // What Z.ai's /models lists is filtered to its chat models, glm-5.3 first.
        XCTAssertEqual(PlanCatalog.models(for: plan("zai"), listed: ["embedding-3", "glm-4.7", "cogview-4", "glm-5.3", "glm-asr"]).map(\.id),
                       ["glm-5.3", "glm-4.7"])
        XCTAssertEqual(plan("kimi-code").models.map(\.id), ["kimi-for-coding", "k3", "k3-256k", "kimi-for-coding-highspeed"])
        XCTAssertEqual(plan("moonshot-api").models.map(\.id), ["kimi-k2.7-code"])
        XCTAssertEqual(plan("qwen-coding").models.map(\.id),
                       ["qwen3.7-plus", "qwen3.6-plus", "qwen3-coder-plus", "qwen3-coder-next", "qwen3.5-plus", "kimi-k2.5", "glm-5", "MiniMax-M2.5"])
        XCTAssertEqual(plan("qwen-api").models.map(\.id), ["qwen3.7-plus"])
        XCTAssertTrue(plan("openai").models.isEmpty, "OpenAI's come from /models")
        XCTAssertEqual(FallbackContextWindow.limit(for: "glm-5.3"), 1_000_000)
    }

    func testOnlyTheQwenCodingPlanIsInteractiveOnly() {
        XCTAssertEqual(PlanCatalog.plans.filter(\.interactiveOnly).map(\.id), ["qwen-coding"])
        XCTAssertTrue(plan("qwen-coding").terms.contains("interactive"))
        XCTAssertEqual(plan("openai").terms,
                       "A ChatGPT Plus or Pro subscription doesn't include API access — the API is billed separately at platform.openai.com.")
        XCTAssertEqual(plan("zai").terms, "Z.ai offers the GLM Coding Plan for use in coding tools; the General API is billed per token.")
    }

    func testEveryPlanRouteIsAnOnlineServiceAndNotPrivate() {
        for p in PlanCatalog.plans {
            for region in p.regions {
                let route = ProviderProfile(kind: .openAICompat, name: p.routeName, baseURL: region.baseURL, model: "m")
                XCTAssertFalse(route.isPrivateRoute, region.baseURL)
                XCTAssertFalse(route.isSelfHosted, region.baseURL)
                XCTAssertEqual(PlanCatalog.plan(for: route)?.id, p.id)
            }
        }
    }

    // MARK: Keys

    func testRecognisableKeyMistakesGetAHint() {
        XCTAssertTrue(PlanCatalog.keyProblem("sk-abc123def456", plan: plan("qwen-coding"))?.contains("sk-sp-") == true)
        XCTAssertNil(PlanCatalog.keyProblem("sk-sp-abc123def456", plan: plan("qwen-coding")))
        XCTAssertTrue(PlanCatalog.keyProblem("sk-sp-abc123", plan: plan("qwen-api"))?.contains("Coding Plan") == true)
        XCTAssertNil(PlanCatalog.keyProblem("sk-abc123", plan: plan("qwen-api")))
        XCTAssertNotNil(PlanCatalog.keyProblem("abc123", plan: plan("openai")))
        XCTAssertNil(PlanCatalog.keyProblem("sk-proj-abc", plan: plan("openai")))
        XCTAssertNotNil(PlanCatalog.keyProblem("sk-ab c", plan: plan("openai")), "a key broken by a space")
        XCTAssertNotNil(PlanCatalog.keyProblem("Bearer sk-abc", plan: plan("kimi-code")))
        XCTAssertNil(PlanCatalog.keyProblem("", plan: plan("kimi-code")))
        XCTAssertNil(PlanCatalog.keyProblem("  sk-kimi-abc \n", plan: plan("kimi-code")), "spaces around it are fine")
    }

    // MARK: Checking

    func testFailuresAreExplainedInPlainWords() {
        let kimi = plan("kimi-code"), intl = kimi.regions[0]
        XCTAssertEqual(PlanCatalog.explain(LLMError.http(401, "invalid key"), plan: kimi, region: intl),
                       "The key wasn't accepted — check it's a Kimi Code (subscription) key for the International region.")
        XCTAssertEqual(PlanCatalog.explain(LLMError.http(403, "only available for Coding Agents"), plan: kimi, region: intl),
                       PlanCatalog.kimiRestriction)
        XCTAssertTrue(PlanCatalog.kimiRestriction.contains("Moonshot"))
        XCTAssertTrue(PlanCatalog.explain(LLMError.http(429, "{}"), plan: kimi, region: intl)
            .hasPrefix("The plan's usage limit is used up for now"))
        XCTAssertTrue(PlanCatalog.explain(LLMError.connection("offline"), plan: kimi, region: intl)
            .contains("https://api.kimi.ai/coding/v1"))
        let zai = plan("zai")
        // The real 401 body api.z.ai sends for a wrong key (recorded 2026-10-18).
        XCTAssertEqual(PlanCatalog.explain(LLMError.http(401, #"{"error":{"code":"401","message":"token expired or incorrect"}}"#),
                                           plan: zai, region: zai.regions[2]),
                       "Z.ai didn't accept the key (401: token expired or incorrect). Keys made at open.bigmodel.cn work on the China endpoints; a key from z.ai needs the international ones.")
        XCTAssertTrue(PlanCatalog.explain(LLMError.http(429, #"{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}"#),
                                          plan: zai, region: zai.regions[1]).contains("switch the endpoint to Coding Plan"))
        let openai = plan("openai")
        XCTAssertEqual(PlanCatalog.explain(LLMError.http(500, #"{"error":{"message":"server melted"}}"#), plan: openai, region: openai.regions[0]),
                       "OpenAI API replied 500: server melted")
    }

    func testAKimiRefusalInAChatIsExplainedToo() {
        let kimi = ProviderProfile(kind: .openAICompat, name: "Kimi Code", baseURL: "https://api.kimi.ai/coding/v1", model: "kimi-for-coding")
        XCTAssertEqual(PlanCatalog.explainChatError(LLMError.http(403, "nope"), route: kimi), PlanCatalog.kimiRestriction)
        XCTAssertNil(PlanCatalog.explainChatError(LLMError.http(429, "slow down"), route: kimi))
        let other = ProviderProfile(kind: .openAI, name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt")
        XCTAssertNil(PlanCatalog.explainChatError(LLMError.http(403, "nope"), route: other))
    }

    // MARK: Models

    func testOpenAIRecommendsItsNewestChatModel() {
        let ids = ["gpt-4o", "gpt-5", "gpt-5.2-mini", "gpt-5.2-2025-12-11", "gpt-5.2", "gpt-realtime", "gpt-4o-audio-preview",
                   "o3", "text-embedding-3-large", "gpt-image-1", "gpt-4.1"]
        XCTAssertEqual(PlanCatalog.recommendedOpenAIModel(ids), "gpt-5.2")
        let offered = PlanCatalog.models(for: plan("openai"), listed: ids).map(\.id)
        XCTAssertEqual(offered.first, "gpt-5.2")
        XCTAssertFalse(offered.contains("gpt-realtime"))
        XCTAssertFalse(offered.contains("text-embedding-3-large"))
        XCTAssertFalse(offered.contains("o3"), "only gpt-* chat models")
    }

    func testAListedPlanPutsItsRecommendedModelFirstAndAnUnlistedOneKeepsItsOwn() {
        XCTAssertEqual(PlanCatalog.models(for: plan("moonshot-api"), listed: ["moonshot-v1", "kimi-k2.7-code"]).map(\.id),
                       ["kimi-k2.7-code", "moonshot-v1"])
        XCTAssertEqual(PlanCatalog.models(for: plan("kimi-code"), listed: ["whatever"]).map(\.id).first, "kimi-for-coding",
                       "a plan whose /models isn't reliable offers its own list")
        XCTAssertEqual(PlanCatalog.models(for: plan("qwen-api"), listed: nil).map(\.id), ["qwen3.7-plus"])
    }

    // MARK: GLM-5.3 thinking

    private func body(_ route: ProviderProfile, _ level: ThinkingLevel) throws -> [String: Any] {
        let data = try OpenAIClient(profile: route).makeBody(
            LLMRequest(systemPrompt: "", messages: [.user("hi")], tools: [], model: route.model, thinking: level))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testGLMIsNeverToldNotToThinkAndGetsItsOwnWords() throws {
        let zai = ProviderProfile(kind: .openAICompat, name: "GLM Coding Plan", baseURL: "https://api.z.ai/api/coding/paas/v4", model: "glm-5.3")
        let expected: [ThinkingLevel: String] = [.off: "low", .low: "low", .medium: "high", .high: "high", .max: "max"]
        for (level, word) in expected {
            let b = try body(zai, level)
            XCTAssertEqual(b["reasoning_effort"] as? String, word, "\(level)")
            XCTAssertNil(b["chat_template_kwargs"], "a hosted API gets only the top-level effort")
            XCTAssertNil(b["thinking"])
            XCTAssertNil(b["enable_thinking"])
        }
        // GLM-5.3 on your own server: still never thinking-off.
        let local = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "glm-5.3-fp8")
        let b = try body(local, .off)
        XCTAssertEqual(b["reasoning_effort"] as? String, "low")
        XCTAssertNil((b["chat_template_kwargs"] as? [String: Any])?["enable_thinking"])
        // Another model is unchanged.
        let qwen = ProviderProfile(kind: .openAICompat, name: "Spark", baseURL: "http://spark.local:8002/v1", model: "qwen3.8")
        XCTAssertEqual((try body(qwen, .off)["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
    }
}
