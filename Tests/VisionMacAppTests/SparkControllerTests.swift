import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The Swapper boxes as the app drives them: trusting a box's certificate, and following an install.
@MainActor
final class SparkControllerTests: XCTestCase {
    private var dir: URL!
    private var suites: [String] = []
    private var transport: AppTransport!
    private let fingerprint = (1...32).map { String(format: "%02X", $0) }.joined(separator: ":")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-spark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Nothing here reaches a real box: every Swapper request gets the fake server's 404.
        SparkSwapperClient.protocolClassesForTesting = [FakeModelServer.self]
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("ok") }
    }

    override func tearDown() async throws {
        transport?.stopAll()
        transport = nil
        SparkSwapperClient.protocolClassesForTesting = nil
        OpenAIClient.protocolClassesForTesting = nil
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func defaults() -> UserDefaults {
        let suite = "vision.spark.test.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func controller(_ routes: [ProviderProfile]) -> (SparkController, AppConfig) {
        let config = AppConfig(defaults: defaults(), secrets: MemorySecretStore())
        config.providers = routes
        config.activeRoute = routes.first?.routeID
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: dir.appendingPathComponent("support")),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        return (SparkController(config: config, transport: transport, defaults: defaults(), secrets: MemorySecretStore()), config)
    }

    /// A bare `/swap <model>` switches the box behind the chat's own model, not the primary's (each chat has its own).
    func testSwapInAChatTargetsTheBoxBehindThatChatsModel() {
        let a = ProviderProfile(kind: .openAICompat, name: "DGX Spark", baseURL: "https://10.0.0.1:11443/v1", model: "qwen")
        let b = ProviderProfile(kind: .openAICompat, name: "Strix Halo", baseURL: "https://10.0.0.2:11443/v1", model: "glm")
        let (spark, _) = controller([a, b])
        let boxA = spark.add(SwapperConnection(name: "DGX Spark", url: "https://10.0.0.1:8999", auth: .token,
                                               apiBase: "https://10.0.0.1:11443/v1"), secret: "sst_a")
        let boxB = spark.add(SwapperConnection(name: "Strix Halo", url: "https://10.0.0.2:8999", auth: .token,
                                               apiBase: "https://10.0.0.2:11443/v1"), secret: "sst_b")
        let onA = transport.newSession(cwd: dir.path)
        let onB = transport.newSession(cwd: dir.path)
        transport.setRoute(b.routeID, for: onB)
        transport.setRoute(a.routeID, for: onA)
        XCTAssertEqual(spark.swapHome(for: onB)?.id, boxB.id)
        XCTAssertEqual(spark.swapHome(for: onA)?.id, boxA.id)
        XCTAssertEqual(spark.primaryBox?.id, boxA.id)
    }

    func testTrustingABoxsCertificatePinsItsRoutesToo() {
        let onBox = ProviderProfile(kind: .openAICompat, name: "DGX Spark (spark-3f2a)", baseURL: "https://192.168.1.42:11443/v1",
                                    model: "Qwen3.8-27B")
        let elsewhere = ProviderProfile(kind: .openAICompat, name: "Other", baseURL: "https://10.0.0.9:11443/v1", model: "x")
        let (spark, config) = controller([onBox, elsewhere])
        let box = spark.add(SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://192.168.1.42:8999", auth: .token,
                                              apiBase: "https://192.168.1.42:11443/v1"), secret: "sst_x")
        box.untrustedFingerprint = fingerprint
        spark.trustPresentedCertificate(box)
        XCTAssertEqual(box.connection.pinnedFingerprint, fingerprint)
        XCTAssertEqual(config.providers.first { $0.routeID == onBox.routeID }?.pinnedCertificate, fingerprint,
                       "the box's model front presents the same certificate")
        XCTAssertNil(config.providers.first { $0.routeID == elsewhere.routeID }?.pinnedCertificate)
    }

    func testAnInstallThatGoesQuietIsNoLongerFollowed() async throws {
        let (spark, _) = controller([])
        spark.installPollInterval = 0.02
        spark.installSilenceLimit = 0.2
        let box = spark.add(SwapperConnection(name: "DGX Spark (spark-3f2a)", url: "https://box.test:8999", auth: .token),
                            secret: "sst_x")
        spark.watchInstall(box)
        let deadline = Date().addingTimeInterval(5)
        while box.installError == nil {
            if Date() > deadline { return XCTFail("still following an install nobody answers about") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(box.installError?.hasPrefix("DGX Spark (spark-3f2a) hasn't answered about the install") == true,
                      box.installError ?? "")
        XCTAssertNil(box.installingKey)
    }
}
