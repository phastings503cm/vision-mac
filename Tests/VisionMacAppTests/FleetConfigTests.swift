import XCTest
import VisionHarnessCore
@testable import VisionMacApp

/// How routes are arranged: which one is the primary (the model new chats start with) and which are enlisted to serve
/// subagents — and that changing the primary changes no flag.
@MainActor
final class FleetConfigTests: XCTestCase {

    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
    }

    private func defaults() -> UserDefaults {
        let suite = "vision.fleet.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func config(_ routes: [ProviderProfile], main: String? = nil, defaults: UserDefaults? = nil) -> AppConfig {
        let config = AppConfig(defaults: defaults ?? self.defaults(), secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = main ?? routes.first?.routeID
        return config
    }

    private func spark(_ name: String, host: String, model: String = "qwen3.8", worker: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .openAICompat, name: name, baseURL: "http://\(host):8002/v1", model: model,
                        subagentWorker: worker ? true : nil)
    }

    private func bedrock(model: String = "us.anthropic.claude-sonnet-4-5-20250929-v1:0", worker: Bool = false) -> ProviderProfile {
        ProviderProfile(kind: .bedrock, name: "Amazon Bedrock", baseURL: "https://bedrock-runtime.us-east-1.amazonaws.com",
                        model: model, awsProfile: "vision-bedrock", awsRegion: "us-east-1", subagentWorker: worker ? true : nil)
    }

    private func names(_ routes: [ProviderProfile]) -> [String] { routes.map(\.name) }

    // MARK: Who is enlisted

    func testEnlistedRoutesAreEveryFlaggedRouteThePrimaryToo() {
        // The primary is only the default for new chats: flagged, it serves chats on other models.
        let c = config([spark("Spark 1", host: "spark1.local", worker: true), spark("Spark 2", host: "spark2.local", worker: true),
                        bedrock(worker: true), spark("Spare", host: "old.local")])
        XCTAssertEqual(names(c.enlistedRoutes), ["Spark 1", "Spark 2", "Amazon Bedrock"])
    }

    func testRoutesSwitchedOffAreNotEnlisted() {
        var off = spark("Off", host: "off.local", worker: true)
        off.enabled = false
        let c = config([spark("Spark 1", host: "spark1.local"), off, spark("On", host: "on.local", worker: true)])
        XCTAssertEqual(names(c.enlistedRoutes), ["On"])
    }

    func testAMachineIsItsBaseURLForASelfHostedServerAndItsRouteForEverythingElse() {
        XCTAssertEqual(AppConfig.machineOf(spark("Spark 2", host: "SPARK2.local")), "http://spark2.local:8002/v1")
        XCTAssertEqual(AppConfig.machineOf(bedrock()), "route:" + bedrock().routeID)
        // Each Guardian model is its own server (they all share one address).
        let haiku = AppConfig.guardianRoute(GuardianModel(id: "claude-haiku-5-5"), base: "https://guardian.503cm.com/v1", org: nil)
        let sonnet = AppConfig.guardianRoute(GuardianModel(id: "claude-sonnet-5-5"), base: "https://guardian.503cm.com/v1", org: nil)
        XCTAssertNotEqual(AppConfig.machineOf(haiku), AppConfig.machineOf(sonnet))
        // And so is each Claude Code model.
        XCTAssertEqual(AppConfig.machineOf(ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL,
                                                           model: "opus")), "route:Claude Code|opus")
    }

    func testTheRouteLabelFallsBackToTheModel() {
        XCTAssertEqual(AppConfig.routeLabel(spark("Spark 2", host: "h")), "Spark 2")
        XCTAssertEqual(AppConfig.routeLabel(ProviderProfile(kind: .ollama, name: "", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3:8b")), "qwen3:8b")
    }

    // MARK: Changing the primary

    func testMakingAnotherRouteThePrimaryChangesNoFlags() {
        // The primary is the default for new chats; no chat's pool changes, so nothing is ticked for the person.
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true), bedrock(worker: true)])
        let before = c.providers.map(\.subagentWorker)
        c.makeMain(bedrock().routeID)
        XCTAssertEqual(c.mainRoute?.name, "Amazon Bedrock")
        XCTAssertEqual(c.providers.map(\.subagentWorker), before)
        XCTAssertEqual(names(c.enlistedRoutes), ["Spark 2", "Amazon Bedrock"], "a flagged primary keeps serving other chats")
        c.makeMain(spark("Spark 1", host: "x").routeID)
        XCTAssertEqual(c.providers.map(\.subagentWorker), before)
    }

    func testMakingTheCurrentOrAnUnknownRouteMainChangesNothing() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true)])
        let before = c.providers
        c.makeMain(c.activeRoute!)
        c.makeMain("nobody|nothing")
        XCTAssertEqual(c.providers, before)
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    // MARK: Editing the arrangement

    func testTheWorkerSwitchAndTheParallelCountAreSetPerRoute() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local")])
        let two = spark("Spark 2", host: "x").routeID
        c.setSubagentWorker(two, true)
        c.setSubagentParallel(two, 4)
        XCTAssertEqual(names(c.enlistedRoutes), ["Spark 2"])
        XCTAssertEqual(c.enlistedRoutes.first?.subagentParallel, 4)
        c.setSubagentWorker(two, false)
        XCTAssertTrue(c.enlistedRoutes.isEmpty)
        XCTAssertNil(c.providers[1].subagentWorker, "off is stored as absent, so old files stay identical")
    }

    func testStoringARouteNeverChangesTheMainModel() {
        let c = config([spark("Spark 1", host: "spark1.local")])
        c.store(spark("Spark 2", host: "spark2.local", worker: true))
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
        XCTAssertEqual(c.providers.count, 2)
        var edited = spark("Spark 2", host: "spark2.local", worker: true)
        edited.temperature = 0.1
        c.store(edited)
        XCTAssertEqual(c.providers.count, 2, "same name and model = the same route, replaced")
        XCTAssertEqual(c.providers[1].temperature, 0.1)
    }

    func testAChangeToTheFleetIsAnnouncedSoItCanBeRebuilt() {
        let c = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local")])
        var calls = 0
        c.onRoutesChanged = { calls += 1 }
        c.setSubagentWorker(spark("Spark 2", host: "x").routeID, true)
        XCTAssertEqual(calls, 1)
        c.makeMain(spark("Spark 2", host: "x").routeID)
        XCTAssertGreaterThanOrEqual(calls, 2)
        let before = calls
        c.subagentsUsePrimary = false
        XCTAssertEqual(calls, before + 1)
    }

    // MARK: Replacing a route in place

    func testReplacingARouteKeepsItsPlaceAndItsRole() {
        // Change… on a Bedrock route that serves subagents: a different model, the same seat.
        let c = config([spark("Spark 1", host: "spark1.local"), bedrock(worker: true), spark("Spark 2", host: "spark2.local", worker: true)])
        var changed = bedrock(model: "us.anthropic.claude-haiku-4-5-20251001-v1:0", worker: true)
        changed.subagentParallel = 4
        c.replace(bedrock(), with: changed)
        XCTAssertEqual(c.providers.map(\.name), ["Spark 1", "Amazon Bedrock", "Spark 2"], "same position")
        XCTAssertEqual(c.providers[1].model, "us.anthropic.claude-haiku-4-5-20251001-v1:0")
        XCTAssertEqual(c.enlistedRoutes.map(\.name), ["Amazon Bedrock", "Spark 2"])
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    func testReplacingTheMainRouteKeepsItTheMainModel() {
        let c = config([bedrock(), spark("Spark 2", host: "spark2.local", worker: true)])
        XCTAssertEqual(c.mainRoute?.name, "Amazon Bedrock")
        c.replace(bedrock(), with: bedrock(model: "amazon.nova-pro-v1:0"))
        XCTAssertEqual(c.mainRoute?.model, "amazon.nova-pro-v1:0")
        XCTAssertEqual(c.activeRoute, "Amazon Bedrock|amazon.nova-pro-v1:0")
        XCTAssertEqual(c.providers.count, 2)
    }

    func testReplacingWithAModelThatIsAlreadyARouteLeavesOneOfThem() {
        let sonnet = bedrock(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
        let haiku = bedrock(model: "us.anthropic.claude-haiku-4-5-20251001-v1:0", worker: true)
        let c = config([sonnet, haiku], main: sonnet.routeID)
        // The user re-picks Haiku for the main route, which already exists as a subagent server.
        var picked = haiku
        picked.subagentWorker = nil
        c.replace(sonnet, with: picked)
        XCTAssertEqual(c.providers.count, 1, "two routes for one model would collapse into one identity anyway")
        XCTAssertEqual(c.mainRoute?.model, haiku.model)
    }

    func testReplacingAnUnknownRouteJustStoresTheNewOne() {
        let c = config([spark("Spark 1", host: "spark1.local")])
        c.replace(bedrock(), with: bedrock(model: "amazon.nova-pro-v1:0"))
        XCTAssertEqual(c.providers.count, 2)
        XCTAssertEqual(c.mainRoute?.name, "Spark 1")
    }

    // MARK: Persistence

    func testTheArrangementSurvivesARestart() {
        let store = defaults()
        let first = config([spark("Spark 1", host: "spark1.local"), spark("Spark 2", host: "spark2.local", worker: true), bedrock(worker: true)],
                           defaults: store)
        first.setSubagentParallel(bedrock().routeID, 3)
        first.subagentsUsePrimary = false

        let second = AppConfig(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(second.mainRoute?.name, "Spark 1")
        XCTAssertEqual(names(second.enlistedRoutes), ["Spark 2", "Amazon Bedrock"])
        XCTAssertEqual(second.enlistedRoutes.last?.subagentParallel, 3)
        XCTAssertFalse(second.subagentsUsePrimary)
        XCTAssertEqual(second.enlistedRoutes.last?.awsProfile, "vision-bedrock")
    }

    func testRoutesSavedByAnOlderBuildStillLoad() throws {
        let store = defaults()
        let old = #"[{"kind":"openAICompat","name":"Spark","baseURL":"http://spark:8002/v1","model":"qwen"}]"#
        store.set(Data(old.utf8), forKey: "providers.v2")
        store.set("Spark|qwen", forKey: "activeModel.v2")
        let c = AppConfig(defaults: store, secrets: MemorySecretStore())
        XCTAssertEqual(c.mainRoute?.name, "Spark")
        XCTAssertTrue(c.subagentsUsePrimary, "on by default")
        XCTAssertTrue(c.enlistedRoutes.isEmpty)
    }

    // MARK: AWS sign-in expiry

    func testAnExpiredAWSSignInOnTheMainBedrockRouteOffersASignIn() {
        let route = bedrock()
        let expired = LLMError.rejected(status: 401, message: "The AWS sign-in for profile \"vision-bedrock\" has expired.",
                                        body: "sign-in expired", permanent: true)
        XCTAssertEqual(AppTransport.expiredAWSProfile(for: expired, route: route), "vision-bedrock")
        let refused = LLMError.rejected(status: 403, message: "AWS did not accept the credentials", body: "", permanent: true)
        XCTAssertEqual(AppTransport.expiredAWSProfile(for: refused, route: route), "vision-bedrock")
    }

    func testOtherFailuresDoNotOfferASignIn() {
        let route = bedrock()
        // Access to one model being denied, throttling and a missing model are not about the sign-in.
        for error in [LLMError.rejected(status: 403, message: "no access to this model", body: "", permanent: false),
                      LLMError.rejected(status: 429, message: "throttled", body: "", permanent: false),
                      LLMError.rejected(status: 404, message: "no such model", body: "", permanent: true),
                      LLMError.http(401, "nope"), LLMError.connection("down")] as [Error] {
            XCTAssertNil(AppTransport.expiredAWSProfile(for: error, route: route), "\(error)")
        }
    }

    func testNoSignInIsOfferedForARouteWithoutAnAWSProfile() {
        let expired = LLMError.rejected(status: 401, message: "x", body: "", permanent: true)
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: spark("Spark 1", host: "h")), "not a Bedrock route")
        var apiKeyRoute = bedrock()
        apiKeyRoute.awsProfile = nil   // authenticates with a Bedrock API key: signing in again would not help
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: apiKeyRoute))
        XCTAssertNil(AppTransport.expiredAWSProfile(for: expired, route: nil))
    }

    func testTheAgentsCommandIsRecognisedWithItsAliases() {
        XCTAssertEqual(SlashCommand.parse("/agents"), .agents)
        XCTAssertEqual(SlashCommand.parse("/fleet"), .agents)
        XCTAssertTrue(SlashCommand.catalog.contains { $0.usage == "/agents" })
    }
}
