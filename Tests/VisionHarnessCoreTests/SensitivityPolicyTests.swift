import XCTest
@testable import VisionHarnessCore

/// Which routes a Sensitive chat may use: private ones as they are, online ones only through the shield, engines that
/// read files themselves never.
final class SensitivityPolicyTests: XCTestCase {
    private func route(_ kind: ProviderProfile.Kind, _ name: String, _ url: String, isPrivate: Bool? = nil) -> ProviderProfile {
        ProviderProfile(kind: kind, name: name, baseURL: url, model: "m", isPrivate: isPrivate)
    }

    func testYourOwnHardwareIsPrivate() {
        for url in ["http://spark.local:8002/v1", "http://127.0.0.1:11434/v1", "http://192.168.1.50:8002/v1", "http://halo:8080/v1"] {
            XCTAssertEqual(SensitivityPolicy.admission(for: route(.openAICompat, "Spark", url), shieldOn: false),
                           .privateRoute(why: "your own hardware"), url)
        }
        XCTAssertEqual(SensitivityPolicy.admission(for: route(.ollama, "Ollama", "http://127.0.0.1:11434/v1"), shieldOn: true).code,
                       "private")
    }

    func testGuardianAndBedrockInYourAccountArePrivate() {
        XCTAssertEqual(SensitivityPolicy.admission(for: route(.guardian, "Guardian", "https://guardian.503cm.com/api/v1"), shieldOn: false),
                       .privateRoute(why: "Guardian, your organisation's own server"))
        // Bedrock isn't "private" for the shield (it still masks), but it is the person's own AWS account.
        let bedrock = route(.bedrock, "Amazon Bedrock", "https://bedrock-runtime.us-east-1.amazonaws.com")
        XCTAssertFalse(bedrock.isPrivateRoute)
        XCTAssertEqual(SensitivityPolicy.admission(for: bedrock, shieldOn: false),
                       .privateRoute(why: "Amazon Bedrock in your own AWS account"))
    }

    func testAnOnlineServiceIsAllowedOnlyThroughTheShield() {
        let kimi = route(.openAICompat, "Kimi Code", "https://api.kimi.com/coding/v1")
        XCTAssertEqual(SensitivityPolicy.admission(for: kimi, shieldOn: true), .masked)
        let off = SensitivityPolicy.admission(for: kimi, shieldOn: false)
        XCTAssertFalse(off.isAllowed)
        XCTAssertEqual(off.code, "refused")
        XCTAssertTrue(off.refusal?.contains("the sensitive-data shield is switched off") == true)
        XCTAssertTrue(off.refusal?.contains("Settings ▸ AI Models ▸ Sensitive data") == true)
    }

    func testTheUsersPrivateSwitchWinsBothWays() {
        // An online address the person marked private (their own cloud box behind a public name).
        XCTAssertEqual(SensitivityPolicy.admission(for: route(.openAICompat, "My box", "https://box.example.com/v1", isPrivate: true),
                                                   shieldOn: false).code, "private")
        // A LAN address marked not private.
        XCTAssertEqual(SensitivityPolicy.admission(for: route(.openAICompat, "Shared", "http://10.0.0.5:8000/v1", isPrivate: false),
                                                   shieldOn: true), .masked)
    }

    func testEnginesThatReadFilesThemselvesAreRefusedWhateverTheShield() {
        for kind in ["claudeCode", "codex"] {
            for shield in [true, false] {
                let admission = SensitivityPolicy.admission(kind: kind, name: "Claude Code", isPrivate: false, shieldOn: shield)
                XCTAssertFalse(admission.isAllowed, kind)
                XCTAssertTrue(admission.refusal?.hasPrefix("Claude Code reads your files itself") == true, kind)
            }
            // Even marked private: what it reads goes to its own service.
            XCTAssertFalse(SensitivityPolicy.admission(kind: kind, name: "Claude Code", isPrivate: true, shieldOn: true).isAllowed)
        }
        XCTAssertFalse(SensitivityPolicy.readsFilesDirectly(route(.openAI, "OpenAI", "https://api.openai.com/v1")))
    }

    func testTheRefusalTheChatShowsAndTheHeaderLine() {
        let kimi = route(.openAICompat, "Kimi Code", "https://api.kimi.com/coding/v1")
        XCTAssertNil(SensitivityPolicy.refusalMessage(for: kimi, shieldOn: true))
        XCTAssertTrue(SensitivityPolicy.refusalMessage(for: kimi, shieldOn: false)?.hasPrefix("This chat is Sensitive. Kimi Code is an online service") == true)
        XCTAssertEqual(SensitivityPolicy.headerLine(for: kimi, shieldOn: true),
                       "Sensitive — Kimi Code isn't private: what the shield detects is masked before sending.")
        XCTAssertEqual(SensitivityPolicy.headerLine(for: kimi, shieldOn: false),
                       "Sensitive — Kimi Code can't be used in this chat. Choose a private model.")
        XCTAssertEqual(SensitivityPolicy.headerLine(for: route(.openAICompat, "Spark", "http://spark.local/v1"), shieldOn: false),
                       "Sensitive — Spark is private (your own hardware).")
        XCTAssertEqual(SensitivityPolicy.headerLine(for: nil, shieldOn: true),
                       "Sensitive — only private models, or others through the shield.")
        // A route with no name is named by its model.
        XCTAssertEqual(SensitivityPolicy.label(ProviderProfile(kind: .openAI, name: "", baseURL: "https://api.openai.com/v1", model: "gpt-5")), "gpt-5")
    }

    func testBackupsAndSubagentsFollowThePolicy() {
        let spark = route(.openAICompat, "Spark", "http://spark.local/v1")
        let kimi = route(.openAICompat, "Kimi Code", "https://api.kimi.com/coding/v1")
        let bedrock = route(.bedrock, "Bedrock", "")
        XCTAssertEqual(SensitivityPolicy.admittedBackups([spark, kimi, bedrock], shieldOn: false).map(\.name), ["Spark", "Bedrock"])
        XCTAssertEqual(SensitivityPolicy.admittedBackups([spark, kimi, bedrock], shieldOn: true).map(\.name), ["Spark", "Kimi Code", "Bedrock"])
        XCTAssertTrue(SensitivityPolicy.subagentsPrivateOnly(shieldOn: false))
        XCTAssertFalse(SensitivityPolicy.subagentsPrivateOnly(shieldOn: true))
    }
}
