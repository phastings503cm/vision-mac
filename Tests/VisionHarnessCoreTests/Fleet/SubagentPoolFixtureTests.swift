import XCTest
import CryptoKit
@testable import VisionHarnessCore

/// The subagent pool's decisions, driven by the fixtures Vision for Windows shares byte for byte
/// (Fixtures/SubagentPool, with its MANIFEST.sha256): the same routes give the same pool, the same servers the same
/// placement, the same tools the same words.
final class SubagentPoolFixtureTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/SubagentPool", isDirectory: true)

    private func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], name)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    // MARK: The files are the shared ones

    func testTheFixturesMatchTheirManifest() throws {
        let manifest = try String(contentsOf: Self.folder.appendingPathComponent("MANIFEST.sha256"), encoding: .utf8)
        var listed: [String: String] = [:]
        for line in manifest.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2, String(line))
            listed[String(parts[1])] = String(parts[0])
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0 != "MANIFEST.sha256" && !$0.hasPrefix(".") }
        XCTAssertEqual(Set(files), Set(listed.keys), "every fixture is in the manifest, and nothing else")
        for file in files {
            let data = try Data(contentsOf: Self.folder.appendingPathComponent(file))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, listed[file], "\(file) changed: change it in both apps and update MANIFEST.sha256")
        }
    }

    // MARK: labels.json

    func testHandlesAndLabels() throws {
        let labels = try json("labels.json")
        for item in try XCTUnwrap(labels["handles"] as? [[String: Any]]) {
            let routes = try XCTUnwrap(item["routes"] as? [[String: String]]).map {
                SubagentPool.RouteFacts(name: $0["name"]!, model: $0["model"]!, kind: .openAICompatible)
            }
            XCTAssertEqual(SubagentPool.handles(for: routes), item["expect"] as? [String], item["name"] as? String ?? "")
        }
        for item in try XCTUnwrap(labels["context"] as? [[String: Any]]) {
            XCTAssertEqual(SubagentPool.contextLabel(item["tokens"] as! Int), item["expect"] as? String, "\(item)")
        }
        for item in try XCTUnwrap(labels["speed"] as? [[String: Any]]) {
            XCTAssertEqual(SubagentPool.speed(item["model"] as! String).rawValue, item["expect"] as? String, "\(item)")
        }
        for item in try XCTUnwrap(labels["tier"] as? [[String: Any]]) {
            let kind = try XCTUnwrap(SubagentPool.Kind(rawValue: item["kind"] as! String))
            XCTAssertEqual(SubagentPool.tier(kind: kind, planSubscription: item["planSubscription"] as? Bool,
                                             privateAddress: item["privateAddress"] as! Bool).rawValue,
                           item["expect"] as? String, "\(item)")
        }
        for item in try XCTUnwrap(labels["provider"] as? [[String: Any]]) {
            let kind = try XCTUnwrap(SubagentPool.Kind(rawValue: item["kind"] as! String))
            XCTAssertEqual(SubagentPool.provider(kind: kind, planProvider: item["planProvider"] as? String),
                           item["expect"] as? String, "\(item)")
        }
        for item in try XCTUnwrap(labels["machine"] as? [[String: Any]]) {
            let kind = try XCTUnwrap(SubagentPool.Kind(rawValue: item["kind"] as! String))
            XCTAssertEqual(SubagentPool.machine(kind: kind, baseURL: item["baseURL"] as! String, routeID: item["routeID"] as! String,
                                                selfHosted: item["selfHosted"] as! Bool),
                           item["expect"] as? String, "\(item)")
        }
        for item in try XCTUnwrap(labels["retry"] as? [[String: Any]]) {
            XCTAssertEqual(SubagentPool.retryWords((item["seconds"] as! NSNumber).doubleValue), item["expect"] as? String, "\(item)")
        }
    }

    // MARK: pool-cases.json

    func testPools() throws {
        for item in try XCTUnwrap(try json("pool-cases.json")["cases"] as? [[String: Any]]) {
            let name = item["name"] as? String ?? ""
            let routes = try decode([SubagentPool.RouteFacts].self, item["routes"]!)
            let chat = try decode(SubagentPool.RouteFacts.self, item["chat"]!)
            let pool = SubagentPool.build(routes: routes, chat: chat, guardianSignedIn: item["guardianSignedIn"] as! Bool,
                                          sensitive: item["sensitive"] as! Bool, shieldOn: item["shieldOn"] as! Bool,
                                          unattended: item["unattended"] as! Bool, overflow: item["overflow"] as! Bool)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any])
            XCTAssertEqual(pool.chatOwnAgent, expect["chatOwnAgent"] as? Bool, name)
            let entries = try XCTUnwrap(expect["entries"] as? [[String: Any]])
            XCTAssertEqual(pool.entries.map(\.id), entries.map { $0["id"] as! String }, name)
            for (got, want) in zip(pool.entries, entries) {
                XCTAssertEqual(Self.entryJSON(got) as NSDictionary, want as NSDictionary, "\(name): \(got.id)")
            }
            let dropped = try XCTUnwrap(expect["dropped"] as? [[String: String]])
            XCTAssertEqual(pool.dropped.map { ["id": $0.id, "reason": $0.reason] }, dropped, name)
        }
    }

    /// An entry as the fixtures write it.
    static func entryJSON(_ entry: SubagentPool.Entry) -> [String: Any] {
        ["id": entry.id, "routeID": entry.routeID, "label": entry.label, "provider": entry.provider, "model": entry.model,
         "context": entry.context as Any? ?? NSNull(), "private": entry.isPrivate, "tier": entry.tier.rawValue,
         "speed": entry.speed.rawValue, "images": entry.images, "ownAgent": entry.ownAgent, "parallel": entry.parallel,
         "machine": entry.machine, "primary": entry.isPrimary]
    }

    /// A pool written the way the fixtures write one (tool-specs.json, server-arg-cases.json).
    static func pool(_ value: Any) throws -> SubagentPool {
        let object = try XCTUnwrap(value as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]]).map { e in
            SubagentPool.Entry(id: e["id"] as! String, routeID: e["routeID"] as! String, label: e["label"] as! String,
                               provider: e["provider"] as! String, model: e["model"] as! String, context: e["context"] as? String,
                               isPrivate: e["private"] as! Bool, tier: SubagentPool.Tier(rawValue: e["tier"] as! String)!,
                               speed: SubagentPool.Speed(rawValue: e["speed"] as! String)!, images: e["images"] as! Bool,
                               ownAgent: e["ownAgent"] as! Bool, parallel: e["parallel"] as! Int,
                               machine: e["machine"] as? String ?? "route:" + (e["routeID"] as! String),
                               kind: (e["ownAgent"] as! Bool) ? .claudeCode : .openAICompatible, interactiveOnly: false,
                               isPrimary: e["primary"] as! Bool)
        }
        let dropped = (object["dropped"] as? [[String: String]] ?? []).map {
            SubagentPool.Dropped(id: $0["id"]!, routeID: $0["routeID"] ?? "", label: $0["label"] ?? "", reason: $0["reason"]!)
        }
        return SubagentPool(entries: entries, dropped: dropped, overflow: object["overflow"] as? Bool ?? true)
    }

    // MARK: placement-cases.json

    func testPlacement() throws {
        let file = try json("placement-cases.json")
        let pinWait = (file["pinWait"] as! NSNumber).doubleValue
        func date(_ value: Any?) -> Date? { (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        for item in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let name = item["name"] as? String ?? ""
            let r = try XCTUnwrap(item["request"] as? [String: Any])
            let request = SubagentPlacement.Request(
                pinned: r["pinned"] as? String, agentFile: r["agentFile"] as? String, sensitive: r["sensitive"] as? Bool ?? false,
                unattended: r["unattended"] as? Bool ?? false, pinDeadline: date(r["pinDeadline"]),
                tried: Set(r["tried"] as? [String] ?? []), overflow: r["overflow"] as? Bool ?? true,
                lastError: r["lastError"] as? String, pinWait: (r["pinWait"] as? NSNumber)?.doubleValue ?? pinWait)
            let candidates = try XCTUnwrap(item["candidates"] as? [[String: Any]]).map { c in
                SubagentPlacement.Candidate(id: c["id"] as! String, handle: c["handle"] as! String, label: c["label"] as! String,
                                            isPrimary: c["primary"] as? Bool ?? false, isPrivate: c["private"] as? Bool ?? true,
                                            interactiveOnly: c["interactiveOnly"] as? Bool ?? false,
                                            inFlight: c["inFlight"] as? Int ?? 0, parallel: c["parallel"] as? Int ?? 2,
                                            healthyAt: date(c["healthyAt"]), error: c["error"] as? String)
            }
            let decision = SubagentPlacement.choose(request, candidates, now: date(item["now"])!)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any])
            if let run = expect["run"] as? String {
                XCTAssertEqual(decision, .run(id: run, reason: SubagentPlacement.Reason(rawValue: expect["reason"] as! String)!,
                                              note: expect["note"] as? String), name)
            } else if let message = expect["unavailable"] as? String {
                XCTAssertEqual(decision, .unavailable(message), name)
            } else {
                XCTAssertTrue(expect.keys.contains("wait"), name)
                XCTAssertEqual(decision, .wait(until: date(expect["wait"])), name)
            }
        }
    }

    // MARK: tool-specs.json

    func testToolSpecs() throws {
        let file = try json("tool-specs.json")
        let types = AgentCatalog.default.describe()
        let agentDescription = (file["agentDescription"] as! String).replacingOccurrences(of: "{types}", with: types)
        let parsed = { (text: String) throws -> NSDictionary in
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        }
        XCTAssertEqual(try parsed(AgentTool.spec(for: .default).parameters), file["agentParameters"] as? NSDictionary)
        XCTAssertEqual(try parsed(DelegateTool.spec(for: .default).parameters), file["delegateParameters"] as? NSDictionary)
        XCTAssertEqual(DelegateTool.spec(for: .default).description,
                       (file["delegateDescription"] as! String).replacingOccurrences(of: "{types}", with: types))
        XCTAssertEqual(AgentStatusTool.spec.description, file["agentStatusDescription"] as? String)
        XCTAssertEqual(AgentTool.spec(for: .default).description, agentDescription, "no pool: no catalogue")

        for item in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let name = item["name"] as? String ?? ""
            let pool = try Self.pool(item["pool"]!)
            let catalogue = item["catalogue"] as? String
            XCTAssertEqual(SubagentPool.describe(pool), catalogue, name)
            let spec = AgentTool.spec(for: .default, pool: pool)
            XCTAssertEqual(spec.description, agentDescription + (catalogue.map { "\n\n" + $0 } ?? ""), name)
            for load in try XCTUnwrap(item["loads"] as? [[String: Any]]) {
                let loads = (load["loads"] as? [String: [String: Any]] ?? [:]).mapValues { l in
                    SubagentPool.Load(inFlight: l["inFlight"] as? Int ?? 0, healthy: l["healthy"] as? Bool ?? true,
                                      retryIn: (l["retryIn"] as? NSNumber)?.doubleValue)
                }
                XCTAssertEqual(SubagentPool.loadLine(pool, loads: loads), load["expect"] as? String, name)
                // How busy the servers are never reaches the description (it stays cached).
                XCTAssertEqual(AgentTool.spec(for: .default, pool: pool).description, spec.description, name)
            }
        }
    }

    // MARK: server-arg-cases.json

    func testServerArgument() throws {
        let file = try json("server-arg-cases.json")
        let pools = try XCTUnwrap(file["pools"] as? [String: Any]).mapValues { try Self.pool($0) }
        for item in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let value = item["value"] as! String
            let pool = try XCTUnwrap(pools[item["pool"] as! String])
            let expect = try XCTUnwrap(item["expect"] as? [String: String])
            switch SubagentPool.match(value, in: pool) {
            case .entry(let entry): XCTAssertEqual(entry.id, expect["id"], value)
            case .error(let message): XCTAssertEqual(message, expect["error"], value)
            }
        }
    }

    // MARK: claude-code-report.json

    func testClaudeCodeReport() async throws {
        let file = try json("claude-code-report.json")
        for item in try XCTUnwrap(file["reportCases"] as? [[String: Any]]) {
            XCTAssertEqual(ClaudeCodeSubagent.report(reply: item["reply"] as! String, toolLog: item["toolLog"] as! [String],
                                                     hitTurnLimit: item["hitTurnLimit"] as! Bool),
                           item["expect"] as? String)
        }
        // The real capture, through a job: the report, the changes, the tokens.
        let stream = try String(contentsOf: Self.folder.appendingPathComponent(file["stream"] as! String), encoding: .utf8)
        let launcher = ReplayLauncher(lines: stream.split(separator: "\n").map(String.init))
        let subagent = ClaudeCodeSubagent(install: ClaudeCodeInstall(path: "/usr/local/bin/claude", version: "2.1.299",
                                                                     flags: ["--no-session-persistence", "--append-system-prompt"]),
                                          launcher: launcher, environment: [:], model: "haiku")
        let steps = FleetLog<String>()
        let result = try await subagent.run(ExternalSubagentJob(
            prompt: "Change hi to hello there in hello.txt", systemNote: ClaudeCodeSubagent.note,
            workspace: URL(fileURLWithPath: file["workspace"] as! String), preset: .workspaceWrite, readOnly: false, maxSteps: 30,
            activity: { text, step in if step { steps.append(text) } }))
        let expect = try XCTUnwrap(file["expect"] as? [String: Any])
        XCTAssertEqual(result.ok, expect["ok"] as? Bool)
        XCTAssertEqual(result.report, expect["report"] as? String)
        XCTAssertEqual(result.mutated, expect["mutated"] as? Bool)
        XCTAssertEqual(result.promptTokens, expect["promptTokens"] as? Int)
        XCTAssertEqual(result.completionTokens, expect["completionTokens"] as? Int)
        XCTAssertEqual(steps.all, ["read_file: hello.txt", "edit: hello.txt"], "each tool call is a step on the roster")
        let args = try XCTUnwrap(launcher.arguments)
        XCTAssertTrue(args.starts(with: ["-p"]), "\(args)")
        XCTAssertTrue(args.contains("--no-session-persistence"), "\(args)")
        XCTAssertEqual(args.firstIndex(of: "--max-turns").map { args[$0 + 1] }, "30")
        XCTAssertEqual(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }, "default")
        XCTAssertFalse(args.contains("--session-id"), "no session to keep")
        XCTAssertEqual(launcher.workingDirectory?.path, "/work/proj2", "it works in the chat's folder")
    }
}

/// Plays a recorded stream-json run back as the CLI would print it; remembers how it was started.
final class ReplayLauncher: ClaudeCodeLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private let lines: [String]
    private let waitForCancel: Bool
    private let exitCode: Int32
    private var startedWith: [String]?
    private var folder: URL?

    init(lines: [String], waitForCancel: Bool = false, exitCode: Int32 = 0) {
        self.lines = lines
        self.waitForCancel = waitForCancel
        self.exitCode = exitCode
    }

    var arguments: [String]? { lock.withLock { startedWith } }
    var workingDirectory: URL? { lock.withLock { folder } }

    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                input: String, interrupt: @escaping @Sendable () -> String,
                onLine: @escaping @Sendable (String, any ClaudeCodeChannel) -> Void) async throws -> ClaudeCodeExit {
        lock.withLock {
            startedWith = arguments
            folder = workingDirectory
        }
        let channel = ReplayChannel()
        for line in lines { onLine(line, channel) }
        if waitForCancel {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return ClaudeCodeExit(exitCode: 130, interrupted: true)
        }
        return ClaudeCodeExit(exitCode: exitCode)
    }
}

final class ReplayChannel: ClaudeCodeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private(set) var sent: [String] = []
    func send(_ line: String) { lock.withLock { if !closed { sent.append(line) } } }
    func closeInput() { lock.withLock { closed = true } }
    var inputClosed: Bool { lock.withLock { closed } }
}
