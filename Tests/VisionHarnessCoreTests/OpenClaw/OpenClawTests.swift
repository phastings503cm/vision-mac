import XCTest
@testable import VisionHarnessCore

/// A made-up OpenClaw install in a temporary home folder, in the shapes the real one on this Mac uses
/// (openclaw.json with env.vars and models.providers, workspace/ with skills and memory, agents/main/agent,
/// secrets/*.json, cron/jobs.json, sessions).
final class OpenClawFixture {
    let root: URL
    let home: URL
    var state: URL { home.appendingPathComponent(".openclaw") }
    var workspace: URL { state.appendingPathComponent("workspace") }
    var visionSupport: URL { root.appendingPathComponent("support") }

    // Values that must be found, and must never show up in printed forms.
    static let freshdeskKey = "fd9Kq2LmX81PzT4wRn"
    static let dbPassword = "s3cret-Passw0rd"
    static let gatewayToken = "gw_tok_9f8e7d6c5b4a3210"
    static let mantleKey = "mantle-KEY-1234567890abc"
    static let anthropicKey = "sk-ant-api03-AbCdEf1234567890XyZ"
    static let lucetPassword = "Polestar!Pass2026"
    static let envFileToken = "ghp_Envfile1234567890ABCDEF"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-openclaw-test-\(UUID().uuidString.prefix(8))")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write("openclaw.json", """
        // OpenClaw config (JSON5)
        {
          gateway: { auth: { mode: 'token', token: '\(Self.gatewayToken)' }, mode: "local" },
          agents: {
            defaults: { model: { primary: "mantle/zai.glm-5", fallbacks: ["amazon-bedrock/us.anthropic.claude-opus-5-5"] } },
            entries: { main: { model: "mantle/zai.glm-5" } },
          },
          skills: { entries: { slack: { enabled: true, env: { SLACK_BOT_TOKEN: "${SLACK_BOT_TOKEN}" } } } },
          env: { vars: {
            FRESHDESK_API_KEY: "\(Self.freshdeskKey)",
            DB_PASSWORD: "\(Self.dbPassword)",
            ZZ_FRESHDESK_KEY_COPY: "\(Self.freshdeskKey)",
            APP_NAME: "Portal",
            LOG_LEVEL: "debug",
            MAIL_PASSWORD: "null",
            SESSION_LIFETIME: "120",
          } },
          models: { providers: {
            "amazon-bedrock": { baseUrl: "https://bedrock-runtime.us-west-2.amazonaws.com", api: "bedrock-converse-stream", auth: "aws-sdk",
                                models: [{ id: "us.anthropic.claude-opus-5-5", contextWindow: 1000000 }] },
            mantle: { baseUrl: "https://mantle.example.net/v1", api: "openai-completions", apiKey: "\(Self.mantleKey)",
                      models: [{ id: "zai.glm-5", contextWindow: 200000, maxTokens: 64000 }] },
            local: { baseUrl: "http://127.0.0.1:8000/v1", apiKey: "${LOCAL_KEY}", models: ["qwen3-27b"] },
          } },
          channels: { msteams: { enabled: true } },
          maxTokens: 4096, // not a secret
        }
        """)
        try write(".env", "export SLACK_BOT_TOKEN='xoxb-1234567890-ABCDEFGHIJ'\nGITHUB_TOKEN=\(Self.envFileToken) # personal\nPLAIN=hello\n")
        try write("agents/main/agent/auth-profiles.json", """
        { "profiles": {
            "anthropic:default": { "type": "api_key", "provider": "anthropic", "key": "\(Self.anthropicKey)" },
            "openai-codex:me": { "type": "oauth", "provider": "openai-codex", "access": "x" } } }
        """)
        try write("agents/main/sessions/a.jsonl", "{}\n")
        try write("agents/main/sessions/b.jsonl", "{}\n")
        try write("cron/jobs.json", #"{"jobs":[{"id":1},{"id":2},{"id":3}]}"#)
        try write("secrets/lucet.json", """
        {"polestar":{"scal":{"login_url":"https://polestar.example","username":"pat","password":"\(Self.lucetPassword)"}},
         "note":"plain text", "access_key_id":"AKIAEXAMPLE123"}
        """)
        try write("secrets/box.pem", "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n")
        // Workspace: skills, memory, persona, rules.
        try write("workspace/MEMORY.md", "# Memory\n- Patrick prefers short answers.\n")
        try write("workspace/USER.md", "Patrick runs IT for 503CM.\n")
        try write("workspace/SOUL.md", "Be direct.\n")
        try write("workspace/AGENTS.md", "Use the freshdesk skill for tickets.\n")
        try write("workspace/memory/2026-10-01.md", "Fixed the slot sync.\n")
        try write("workspace/memory/2026-10-02.md", "Shipped the TPI send.\n")
        try write("workspace/skills/freshdesk/SKILL.md", "---\nname: freshdesk\ndescription: Work Freshdesk tickets\n---\nUse the API.\n")
        try write("workspace/skills/freshdesk/scripts/fd.py", "print('hi')\n")
        try write("workspace/skills/freshdesk/.env", "FRESHDESK_API_KEY=\(Self.freshdeskKey)\n")
        try write("workspace/skills/freshdesk/notes.md", "The key is FRESHDESK_API_KEY=\(Self.freshdeskKey)\n")
        try write("workspace/skills/leaky/SKILL.md", "---\nname: leaky\ndescription: Has a key\n---\nexport OPENAI_API_KEY=sk-proj-AbCdEfGhIjKlMnOpQrStUvWx0123456789\n")
        try write("workspace/skills/group/inner/SKILL.md", "---\nname: inner-skill\ndescription: Nested one level down\n---\nBody\n")
        // Managed skills: one shadowed by the workspace's freshdesk.
        try write("skills/freshdesk/SKILL.md", "---\nname: freshdesk\ndescription: Older copy\n---\nOld.\n")
        try write("skills/weather/SKILL.md", "---\nname: weather\ndescription: Forecasts\n---\nAsk wttr.in.\n")
        try write("plugin-skills/voice-call/SKILL.md", "---\nname: voice-call\ndescription: Needs the plugin\n---\nCall.\n")
    }

    func write(_ relative: String, _ text: String) throws {
        let url = state.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var install: OpenClawInstall { OpenClawScanner.find(home: home, environment: [:]).first! }
    func bundle() -> OpenClawBundle { OpenClawReader.read(install, home: home) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class JSON5Tests: XCTestCase {
    func testParsesWhatOpenClawWrites() throws {
        let text = """
        // comment
        { unquoted: 'single', "double": "x\\ny", trailing: [1, 2, ], hex: 0x1F, dot: .5, plus: +3, inf: -Infinity,
          /* block */ nested: { ok: true, no: null }, }
        """
        guard case .success(let value) = JSON5.parse(text), let object = value as? [String: Any] else { return XCTFail() }
        XCTAssertEqual(object["unquoted"] as? String, "single")
        XCTAssertEqual(object["double"] as? String, "x\ny")
        XCTAssertEqual((object["trailing"] as? [Any])?.count, 2)
        XCTAssertEqual((object["hex"] as? NSNumber)?.intValue, 31)
        XCTAssertEqual((object["dot"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((object["plus"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(object["inf"] as? Double, -Double.infinity)
        XCTAssertEqual(OpenClawReader.at(object, "nested", "ok") as? Bool, true)
    }

    func testStrictJSONAndUnicodeEscapes() {
        guard case .success(let value) = JSON5.parse(#"{"a":"é😀","b":[{"c":-1.5e3}]}"#) else { return XCTFail() }
        XCTAssertEqual(OpenClawReader.at(value, "a") as? String, "é😀")
        XCTAssertEqual(((OpenClawReader.at(value, "b") as? [Any])?.first as? [String: Any])?["c"] as? NSNumber, -1500)
    }

    func testBadInputSaysWhere() {
        guard case .failure(let error) = JSON5.parse("{\n  a: 1,\n  b: [1 2]\n}") else { return XCTFail() }
        XCTAssertEqual(error.line, 3)
        guard case .failure = JSON5.parse("{ a: 'never closed }") else { return XCTFail() }
        guard case .failure(let deep) = JSON5.parse(String(repeating: "[", count: 5000)) else { return XCTFail() }
        XCTAssertTrue(deep.message.contains("deeply"))
    }
}

final class OpenClawReadTests: XCTestCase {
    var fx: OpenClawFixture!
    override func setUpWithError() throws { fx = try OpenClawFixture() }
    override func tearDown() { fx.remove() }

    func testFindsTheInstallAndProfiles() throws {
        try FileManager.default.createDirectory(at: fx.home.appendingPathComponent(".openclaw-work/agents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fx.home.appendingPathComponent(".openclaw-work/workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fx.home.appendingPathComponent(".config"), withIntermediateDirectories: true)
        let found = OpenClawScanner.find(home: fx.home, environment: [:])
        XCTAssertEqual(found.map(\.stateDir.lastPathComponent), [".openclaw", ".openclaw-work"])
        XCTAssertEqual(found.first?.configPath?.lastPathComponent, "openclaw.json")
        XCTAssertNil(found.last?.configPath, "a state folder without a config still counts")
        let byVariable = OpenClawScanner.find(home: fx.root, environment: ["OPENCLAW_STATE_DIR": fx.state.path])
        XCTAssertEqual(byVariable.first?.foundBy, "OPENCLAW_STATE_DIR")
        XCTAssertTrue(OpenClawScanner.find(home: fx.root.appendingPathComponent("nobody"), environment: [:]).isEmpty)
    }

    func testFindsSkillsInEveryPlaceAndMarksTheShadowedOne() {
        let skills = fx.bundle().skills
        let names = skills.map { "\($0.location):\($0.name)\($0.shadowed ? " (shadowed)" : "")" }
        XCTAssertEqual(Set(names), ["workspace:freshdesk", "workspace:leaky", "workspace:inner-skill", "managed:freshdesk (shadowed)",
                                    "managed:weather", "plugin:voice-call"])
        let freshdesk = skills.first { $0.name == "freshdesk" && !$0.shadowed }!
        XCTAssertTrue(freshdesk.hasScripts)
        XCTAssertTrue(freshdesk.files.contains("scripts/fd.py"))
        let suggested = OpenClawSelection.suggested(fx.bundle())
        XCTAssertFalse(suggested.skills.contains { $0.contains("plugin-skills") }, "plugin skills are opt-in")
        XCTAssertFalse(suggested.skills.contains(fx.state.appendingPathComponent("skills/freshdesk").path), "the shadowed copy is not ticked")
    }

    func testReadsMemoryWithSensibleDefaults() {
        let notes = fx.bundle().noteFiles
        let byName = Dictionary(uniqueKeysWithValues: notes.map { ($0.name, $0) })
        XCTAssertEqual(byName["MEMORY.md"]?.kind, .memory)
        XCTAssertEqual(byName["USER.md"]?.selectedByDefault, true)
        XCTAssertEqual(byName["SOUL.md"]?.selectedByDefault, false, "personality is opt-in")
        XCTAssertEqual(byName["AGENTS.md"]?.kind, .instructions)
        XCTAssertEqual(byName["memory/2026-10-02.md"]?.day, "2026-10-02")
        XCTAssertEqual(notes.filter { $0.kind == .daily }.map(\.name), ["memory/2026-10-02.md", "memory/2026-10-01.md"], "newest first")
    }

    func testFindsEveryKeyWorthKeepingUnderStableNames() {
        let credentials = fx.bundle().credentials
        let names = Set(credentials.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["FRESHDESK_API_KEY", "DB_PASSWORD", "OPENCLAW_GATEWAY_TOKEN", "ANTHROPIC_API_KEY",
                                            "SLACK_BOT_TOKEN", "GITHUB_TOKEN", "OPENCLAW_LUCET_POLESTAR_SCAL_PASSWORD"]), "\(names.sorted())")
        let lucet = credentials.first { $0.name == "OPENCLAW_LUCET_POLESTAR_SCAL_PASSWORD" }!
        XCTAssertEqual(lucet.username, "pat")
        XCTAssertEqual(lucet.url, "https://polestar.example")
        XCTAssertEqual(lucet.kind, .password)
        XCTAssertEqual(lucet.secret.reveal(), OpenClawFixture.lucetPassword)
        XCTAssertEqual(credentials.first { $0.name == "DB_PASSWORD" }?.kind, .password)
        XCTAssertEqual(credentials.first { $0.name == "OPENCLAW_GATEWAY_TOKEN" }?.kind, .token)
    }

    func testLeavesOutWhatIsNotASecretAndStoresAValueOnce() {
        let credentials = fx.bundle().credentials
        let names = Set(credentials.map(\.name))
        for notSecret in ["APP_NAME", "LOG_LEVEL", "MAIL_PASSWORD", "SESSION_LIFETIME", "PLAIN", "OPENCLAW_MAXTOKENS", "OPENCLAW_LUCET_ACCESS_KEY_ID"] {
            XCTAssertFalse(names.contains(notSecret), notSecret)
        }
        XCTAssertFalse(names.contains("ZZ_FRESHDESK_KEY_COPY"))
        XCTAssertEqual(credentials.first { $0.name == "FRESHDESK_API_KEY" }?.alsoNamed, ["ZZ_FRESHDESK_KEY_COPY"])
        XCTAssertFalse(names.contains { $0.contains("MANTLE") }, "a provider's key travels with its model server")
    }

    func testSecretsNeverAppearInPrintedForms() {
        let bundle = fx.bundle()
        let printed = "\(bundle.credentials) \(bundle.modelServers) \(bundle.left) \(bundle.problems) " + bundle.credentials.map(\.secret.hint).joined()
        for secret in [OpenClawFixture.freshdeskKey, OpenClawFixture.dbPassword, OpenClawFixture.gatewayToken, OpenClawFixture.mantleKey,
                       OpenClawFixture.anthropicKey, OpenClawFixture.lucetPassword] {
            XCTAssertFalse(printed.contains(secret), "printed a secret")
        }
        XCTAssertTrue(printed.contains("[secret sha256:"))
    }

    func testReadsModelServersAndFlagsWhatVisionCannotSpeak() {
        let servers = Dictionary(uniqueKeysWithValues: fx.bundle().modelServers.map { ($0.id, $0) })
        XCTAssertEqual(servers["mantle"]?.compatible, true)
        XCTAssertEqual(servers["mantle"]?.apiKey?.reveal(), OpenClawFixture.mantleKey)
        XCTAssertEqual(servers["mantle"]?.contextWindow, 200000)
        XCTAssertEqual(servers["mantle"]?.defaultModel, "zai.glm-5")
        XCTAssertEqual(servers["amazon-bedrock"]?.compatible, false)
        XCTAssertTrue(servers["amazon-bedrock"]?.note?.contains("bedrock-converse-stream") == true)
        XCTAssertNil(servers["local"]?.apiKey, "an unresolved ${LOCAL_KEY} is no key")
        XCTAssertEqual(servers["local"]?.models, ["qwen3-27b"])
    }

    func testSaysPlainlyWhatWasLeftBehind() {
        let left = fx.bundle().left.joined(separator: "\n")
        XCTAssertTrue(left.contains("1 OAuth sign-in (openai-codex)"), left)
        XCTAssertTrue(left.contains("Chat channels (msteams)"), left)
        XCTAssertTrue(left.contains("3 scheduled jobs"), left)
        XCTAssertTrue(left.contains("2 saved conversations"), left)
        XCTAssertTrue(left.contains("1 key file in secrets/"), left)
        XCTAssertTrue(left.contains("${LOCAL_KEY}"), left)
        XCTAssertTrue(left.contains("Agents main (mantle/zai.glm-5)"), left)
    }

    func testABrokenConfigStillYieldsSkillsAndMemory() throws {
        try fx.write("openclaw.json", "{ broken: ")
        let bundle = fx.bundle()
        XCTAssertFalse(bundle.problems.isEmpty)
        XCTAssertFalse(bundle.skills.isEmpty)
        XCTAssertFalse(bundle.noteFiles.isEmpty)
    }

    func testLooksLikeSecretRules() {
        XCTAssertTrue(OpenClawReader.looksLikeSecret("sk-ant-api03-AbCdEf123", kind: .apiKey))
        XCTAssertFalse(OpenClawReader.looksLikeSecret("${OPENAI_API_KEY}", kind: .apiKey))
        XCTAssertFalse(OpenClawReader.looksLikeSecret("your-api-key-here", kind: .apiKey))
        XCTAssertFalse(OpenClawReader.looksLikeSecret("ollama-local-server", kind: .apiKey), "a slug, not a key")
        XCTAssertFalse(OpenClawReader.looksLikeSecret("123456789012345", kind: .apiKey))
        XCTAssertTrue(OpenClawReader.looksLikeSecret("correct horse battery", kind: .password))
        XCTAssertFalse(OpenClawReader.looksLikeSecret("https://example.com/token", kind: .token))
        XCTAssertEqual(OpenClawReader.sanitize("models.providers/my key"), "MODELS.PROVIDERS_MY_KEY")
        XCTAssertTrue(OpenClawReader.isSecretKeyName("botToken"))
        XCTAssertTrue(OpenClawReader.isSecretKeyName("api_key"))
        XCTAssertFalse(OpenClawReader.isSecretKeyName("tokenizer"))
        XCTAssertFalse(OpenClawReader.isSecretKeyName("secretary"))
        XCTAssertFalse(OpenClawReader.isSecretKeyName("tokenFile"))
        XCTAssertFalse(OpenClawReader.isSecretKeyName("webhook_secret_arn"))
    }
}

final class OpenClawTransferTests: XCTestCase {
    var fx: OpenClawFixture!
    var vault: CredentialVault!
    var locations: SkillLocations!

    override func setUpWithError() throws {
        fx = try OpenClawFixture()
        try FileManager.default.createDirectory(at: fx.visionSupport, withIntermediateDirectories: true)
        vault = CredentialVault(directory: fx.visionSupport, store: MemoryBlobStore())
        locations = SkillLocations(home: fx.home, appSupport: fx.visionSupport)
    }

    override func tearDown() { fx.remove() }

    func importSuggested() -> OpenClawImportResult {
        let bundle = fx.bundle()
        return OpenClawImporter.apply(bundle, selection: .suggested(bundle), vault: vault, locations: locations, home: fx.home)
    }

    func testBringsInWhatWasTicked() throws {
        let result = importSuggested()
        XCTAssertEqual(Set(result.skills), ["freshdesk", "inner-skill", "weather"])
        XCTAssertNotNil(result.skillsSkipped["leaky"], "a SKILL.md with a key is refused")
        XCTAssertTrue(result.skillsSkipped["leaky"]!.contains("looks like a key"))
        // The skill came without its .env and without the notes file that holds the key.
        let landed = locations.userSkills.appendingPathComponent("freshdesk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.appendingPathComponent("scripts/fd.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: landed.appendingPathComponent("notes.md").path))
        XCTAssertTrue(result.problems.contains { $0.contains("left out .env") })
        XCTAssertTrue(result.problems.contains { $0.contains("left out notes.md") })

        // Memory into the Mac's memory files.
        let memory = try String(contentsOf: fx.home.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(memory.contains("## From OpenClaw — MEMORY.md"))
        XCTAssertTrue(memory.contains("Patrick prefers short answers."))
        XCTAssertTrue(memory.contains("## About me — from OpenClaw USER.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("memory/2026-10-02.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.home.appendingPathComponent("VISION.md").path), "personality and rules are opt-in")
        XCTAssertEqual(result.notesAdded, 4)

        // Credentials into the vault, ask-first, with their logins.
        XCTAssertTrue(result.credentials.contains("FRESHDESK_API_KEY"))
        XCTAssertEqual(vault.entry(named: "FRESHDESK_API_KEY")?.access, .ask)
        XCTAssertEqual(vault.lookup("OPENCLAW_LUCET_POLESTAR_SCAL_PASSWORD"), .value(OpenClawFixture.lucetPassword, access: .ask))
        XCTAssertEqual(vault.entry(named: "OPENCLAW_LUCET_POLESTAR_SCAL_PASSWORD")?.username, "pat")
        XCTAssertTrue(vault.entry(named: "FRESHDESK_API_KEY")!.tags.contains("openclaw"))

        // Model servers back to the app: the compatible ones.
        XCTAssertEqual(Set(result.modelServers.map(\.id)), ["mantle", "local"])
        XCTAssertTrue(result.summary.hasPrefix("3 skills, 4 memory files"), result.summary)
    }

    func testImportingTwiceDoesNotDuplicate() throws {
        _ = importSuggested()
        let again = importSuggested()
        XCTAssertEqual(again.notesAdded, 0)
        XCTAssertEqual(again.notesUnchanged, 4)
        XCTAssertTrue(again.credentials.isEmpty, "the same values are already in the vault")
        XCTAssertTrue(again.skills.isEmpty, "\(again.skills)")
        XCTAssertEqual(again.skillsSkipped["freshdesk"], "Already in Vision, unchanged since it was brought in.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.userSkills.appendingPathComponent("freshdesk-2").path))
        XCTAssertTrue(again.credentialsSkipped["FRESHDESK_API_KEY"]?.contains("already in the vault") == true)
        let memory = try String(contentsOf: fx.home.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertEqual(memory.components(separatedBy: "From OpenClaw — MEMORY.md").count, 2, "one block, not two")
        // A changed source replaces its block in place.
        try fx.write("workspace/MEMORY.md", "# Memory\n- Patrick prefers bullet points.\n")
        let changed = importSuggested()
        XCTAssertEqual(changed.notesUpdated, 1)
        let updated = try String(contentsOf: fx.home.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(updated.contains("bullet points"))
        XCTAssertFalse(updated.contains("short answers"))
    }

    func testCredentialConflictsFollowThePolicy() throws {
        try vault.add(name: "FRESHDESK_API_KEY", value: "a-different-Value-123456")
        let bundle = fx.bundle()
        var selection = OpenClawSelection()
        selection.credentials = ["FRESHDESK_API_KEY": .ask]

        selection.credentialConflict = .skip
        var result = OpenClawImporter.apply(bundle, selection: selection, vault: vault, locations: nil, home: nil)
        XCTAssertTrue(result.credentials.isEmpty)
        XCTAssertEqual(vault.lookup("FRESHDESK_API_KEY"), .value("a-different-Value-123456", access: .allowed))

        selection.credentialConflict = .keepBoth
        result = OpenClawImporter.apply(bundle, selection: selection, vault: vault, locations: nil, home: nil)
        XCTAssertEqual(result.credentials, ["FRESHDESK_API_KEY_OPENCLAW"])

        selection.credentialConflict = .replace
        let otherVault = CredentialVault(directory: fx.root, store: MemoryBlobStore())
        try otherVault.add(name: "FRESHDESK_API_KEY", value: "a-different-Value-123456")
        result = OpenClawImporter.apply(bundle, selection: selection, vault: otherVault, locations: nil, home: nil)
        XCTAssertEqual(result.credentials, ["FRESHDESK_API_KEY"])
        XCTAssertEqual(otherVault.lookup("FRESHDESK_API_KEY"), .value(OpenClawFixture.freshdeskKey, access: .allowed))
    }

    func testSkillsCanWaitForApprovalOrBeSkipped() throws {
        let bundle = fx.bundle()
        var selection = OpenClawSelection()
        selection.skills = [fx.state.appendingPathComponent("skills/weather").path]
        selection.skillsAsDrafts = true
        let drafted = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: locations, home: nil)
        XCTAssertEqual(drafted.skillDrafts, ["weather"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.userSkills.appendingPathComponent("weather").path))

        selection.skillsAsDrafts = false
        _ = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: locations, home: nil)
        selection.skillConflict = .skip
        let skipped = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: locations, home: nil)
        XCTAssertTrue(skipped.skillsSkipped["weather"]?.contains("already has a skill") == true)
        selection.skillConflict = .keepBoth
        let unchanged = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: locations, home: nil)
        XCTAssertEqual(unchanged.skillsSkipped["weather"], "Already in Vision, unchanged since it was brought in.")
        // Changed at its source: it comes in again, beside the first copy.
        try fx.write("skills/weather/SKILL.md", "---\nname: weather\ndescription: Forecasts, now hourly\n---\nAsk wttr.in.\n")
        let both = OpenClawImporter.apply(fx.bundle(), selection: selection, vault: nil, locations: locations, home: nil)
        XCTAssertEqual(both.skills, ["weather"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.userSkills.appendingPathComponent("weather-2/SKILL.md").path))
        let ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: fx.visionSupport.appendingPathComponent("openclaw-imports.json"))) as? [String: [String: String]]
        XCTAssertEqual(ledger?["This Mac|" + fx.state.appendingPathComponent("skills/weather").path]?["Slug"], "weather-2")
    }

    func testOptInPersonaAndRulesGoToVisionMD() throws {
        let bundle = fx.bundle()
        var selection = OpenClawSelection()
        selection.noteFiles = Set(bundle.noteFiles.filter { $0.kind == .persona || $0.kind == .instructions }.map(\.path.path))
        _ = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: nil, home: fx.home)
        let text = try String(contentsOf: fx.home.appendingPathComponent("VISION.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("## Personality — from OpenClaw SOUL.md"))
        XCTAssertTrue(text.contains("## Rules — from OpenClaw AGENTS.md"))
    }

    func testNotesThatHoldAKeyAreLeftOut() throws {
        try fx.write("workspace/memory/2026-10-03.md", "token: ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789\n")
        let bundle = fx.bundle()
        var selection = OpenClawSelection()
        selection.noteFiles = [bundle.noteFiles.first { $0.day == "2026-10-03" }!.path.path]
        let result = OpenClawImporter.apply(bundle, selection: selection, vault: nil, locations: nil, home: fx.home)
        XCTAssertEqual(result.notesAdded, 0)
        XCTAssertTrue(result.problems.first?.contains("looks like a key") == true)
    }

    func testCredentialFileNames() {
        XCTAssertTrue(OpenClawImporter.isCredentialFile(".env"))
        XCTAssertTrue(OpenClawImporter.isCredentialFile("keys/server.pem"))
        XCTAssertTrue(OpenClawImporter.isCredentialFile("credentials.json"))
        XCTAssertFalse(OpenClawImporter.isCredentialFile(".env.example"))
        XCTAssertFalse(OpenClawImporter.isCredentialFile("SKILL.md"))
    }

    func testMarkdownBlocksUpsertInPlace() {
        let (first, added) = MarkdownBlocks.upsert(tag: "t", name: "a.md", title: "A", body: "one", into: "# Mine\n")
        XCTAssertEqual(added, .added)
        XCTAssertTrue(first.hasPrefix("# Mine\n\n<!-- t:begin a.md sha256:"))
        let (same, unchanged) = MarkdownBlocks.upsert(tag: "t", name: "a.md", title: "A", body: "one", into: first + "after\n")
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(same, first + "after\n")
        let (replaced, updated) = MarkdownBlocks.upsert(tag: "t", name: "a.md", title: "A", body: "two", into: first + "after\n")
        XCTAssertEqual(updated, .updated)
        XCTAssertTrue(replaced.contains("two"))
        XCTAssertFalse(replaced.contains("\none\n"))
        XCTAssertTrue(replaced.hasSuffix("after\n"), "text around the block is kept")
    }

    // MARK: Export

    func testExportsSkillsMemoryAndOnlyConfirmedSecrets() throws {
        // Vision's own things.
        let skillDir = locations.userSkills.appendingPathComponent("release-notes")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: release-notes\ndescription: Draft release notes\n---\nWrite them.\n".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Vision memory\n- Ship on Fridays.\n".write(to: fx.home.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try vault.add(name: "SPARK_TOKEN", value: "spark-Token-ABC123456789", kind: .token)
        let catalog = SkillCatalog.loadAll(project: nil, locations: locations).filter { $0.origin == .vision && $0.scope == .user }
        XCTAssertEqual(catalog.map(\.name), ["release-notes"])

        var selection = OpenClawExportSelection()
        selection.skills = Set(catalog.map(\.id))
        selection.memory = true
        selection.vault = ["SPARK_TOKEN"]
        // Not confirmed: no secret is written.
        var result = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: catalog, vault: vault)
        XCTAssertEqual(result.skills, ["release-notes"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.state.appendingPathComponent("skills/release-notes/SKILL.md").path))
        let workspaceMemory = try String(contentsOf: fx.workspace.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertTrue(workspaceMemory.hasPrefix("# Memory\n- Patrick prefers short answers.\n"), "OpenClaw's own memory is kept")
        XCTAssertTrue(workspaceMemory.contains("## From Vision — MEMORY.md"))
        XCTAssertTrue(workspaceMemory.contains("Ship on Fridays."))
        XCTAssertTrue(result.secrets.isEmpty)
        XCTAssertTrue(result.secretsSkipped["SPARK_TOKEN"]?.contains("Not confirmed") == true)
        let envBefore = try String(contentsOf: fx.state.appendingPathComponent(".env"), encoding: .utf8)
        XCTAssertFalse(envBefore.contains("SPARK_TOKEN"))

        // Confirmed: written to .env, readable only by the user, and read back the same by the importer.
        selection.vaultConfirmed = true
        result = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: catalog, vault: vault)
        XCTAssertEqual(result.secrets, ["SPARK_TOKEN"])
        XCTAssertTrue(result.skillsSkipped["release-notes"]?.contains("already has a skill") == true, "skip is the export default")
        XCTAssertEqual(result.memoryUnchanged, 1)
        let envFile = fx.state.appendingPathComponent(".env")
        let env = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertTrue(env.contains("SPARK_TOKEN=\"spark-Token-ABC123456789\""))
        XCTAssertTrue(env.hasPrefix("export SLACK_BOT_TOKEN="), "existing lines are kept")
        let mode = try FileManager.default.attributesOfItem(atPath: envFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(fx.bundle().credentials.contains { $0.name == "SPARK_TOKEN" && $0.secret.reveal() == "spark-Token-ABC123456789" })
        XCTAssertFalse("\(result)".contains("spark-Token-ABC123456789"), "the result never carries a value")

        // Again: nothing to do.
        let again = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: catalog, vault: vault)
        XCTAssertTrue(again.secrets.isEmpty)
        XCTAssertTrue(again.secretsSkipped["SPARK_TOKEN"]?.contains("already has") == true)
    }

    func testExportLeavesOutWhatCameFromOpenClaw() throws {
        _ = importSuggested()
        var selection = OpenClawExportSelection()
        selection.memory = true
        let result = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: [], vault: nil)
        let workspaceMemory = try String(contentsOf: fx.workspace.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        XCTAssertFalse(workspaceMemory.contains("vision-export"), "Vision's MEMORY.md held only OpenClaw's own blocks: nothing goes back")
        XCTAssertEqual(result.memoryAdded, 0)
    }

    /// A Guardian secret held for this run only (memory) never reaches OpenClaw's .env, even when it is asked for.
    func testSessionOnlySecretsAreNeverExported() throws {
        try vault.add(name: "SPARK_TOKEN", value: "spark-Token-ABC123456789", kind: .token)
        try vault.addSessionOnly(name: "FRESHDESK_API_KEY", value: "fd-secret-123456", kind: .apiKey,
                                 description: "From Guardian — this run of Vision only.", tags: ["guardian"], access: .ask)
        XCTAssertEqual(vault.all.filter { !vault.isSessionOnly($0) }.map(\.name), ["SPARK_TOKEN"], "what the export offers")
        var selection = OpenClawExportSelection()
        selection.vault = ["SPARK_TOKEN", "FRESHDESK_API_KEY"]
        selection.vaultConfirmed = true
        let result = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: [], vault: vault)
        XCTAssertEqual(result.secrets, ["SPARK_TOKEN"])
        XCTAssertEqual(result.secretsSkipped["FRESHDESK_API_KEY"], "It came from Guardian for this run only, so it stays in memory.")
        let env = try String(contentsOf: fx.state.appendingPathComponent(".env"), encoding: .utf8)
        XCTAssertTrue(env.contains("SPARK_TOKEN="))
        XCTAssertFalse(env.contains("fd-secret-123456"))
        XCTAssertFalse(env.contains("FRESHDESK_API_KEY"))
    }

    func testSecretValuesWithQuotesRoundTripThroughTheEnvFile() throws {
        try vault.add(name: "ODD_PASSWORD", value: "pa\"ss\\wo rd#1", kind: .password)
        var selection = OpenClawExportSelection()
        selection.vault = ["ODD_PASSWORD"]
        selection.vaultConfirmed = true
        _ = OpenClawExporter.export(selection, to: fx.install, home: fx.home, skills: [], vault: vault)
        let parsed = OpenClawReader.parseEnv(try String(contentsOf: fx.state.appendingPathComponent(".env"), encoding: .utf8))
        XCTAssertEqual(parsed.first { $0.0 == "ODD_PASSWORD" }?.1, "pa\"ss\\wo rd#1")
    }
}

/// Reads the real ~/.openclaw on this Mac, read-only, when VISION_REAL_OPENCLAW=1 — counts only, never a value.
final class OpenClawRealInstallTests: XCTestCase {
    func testReadsTheRealInstallWithoutPrintingASecret() throws {
        guard ProcessInfo.processInfo.environment["VISION_REAL_OPENCLAW"] == "1" else { throw XCTSkip("set VISION_REAL_OPENCLAW=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installs = OpenClawScanner.find(home: home)
        let install = try XCTUnwrap(installs.first)
        let started = Date()
        let bundle = OpenClawReader.read(install, home: home)
        let printed = "\(bundle.credentials) \(bundle.modelServers) \(bundle.left) \(bundle.problems) \(bundle.skills.map(\.name)) "
            + bundle.credentials.map(\.secret.hint).joined()
        for credential in bundle.credentials where printed.contains(credential.secret.reveal()) {
            XCTFail("a secret was printed (\(credential.name))")
        }
        let kinds = Dictionary(grouping: bundle.credentials, by: \.kind).mapValues(\.count)
        print("REAL-OPENCLAW installs=\(installs.count) workspaces=\(bundle.workspaces.count) skills=\(bundle.skills.count) "
              + "shadowed=\(bundle.skills.filter(\.shadowed).count) withScripts=\(bundle.skills.filter(\.hasScripts).count) "
              + "notes=\(bundle.noteFiles.count) (daily \(bundle.noteFiles.filter { $0.kind == .daily }.count)) "
              + "credentials=\(bundle.credentials.count) \(kinds.map { "\($0.key.rawValue):\($0.value)" }.sorted()) "
              + "servers=\(bundle.modelServers.map { "\($0.id)\($0.compatible ? "" : "(no)")" }) agents=\(bundle.agents.map(\.id)) "
              + "left=\(bundle.left.count) problems=\(bundle.problems) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        for line in bundle.left { print("REAL-OPENCLAW left: \(line)") }
    }
}
