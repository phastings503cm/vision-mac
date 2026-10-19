import XCTest
@testable import VisionHarnessCore

/// MCP: importing the servers other apps configured, talking to a stdio server and a Streamable HTTP one, and their
/// tools as the model's tools behind the permission prompt.
final class MCPTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Import

    func testImportsClaudeCodeClaudeDesktopAndCursor() throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let project = dir.appendingPathComponent("work/app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write("home/.claude.json", """
        {"numStartups": 3,
         "mcpServers": {"github": {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                                   "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_secret"}}},
         "projects": {"\(project.path)": {"mcpServers": {"db": {"command": "uvx", "args": ["mcp-db", "--port", 5432]}}},
                      "/somewhere/else": {"mcpServers": {"other": {"command": "x"}}}}}
        """)
        try write("work/app/.mcp.json", """
        {"mcpServers": {"docs": {"type": "http", "url": "https://docs.example.com/mcp", "headers": {"Authorization": "Bearer ${DOCS_TOKEN}"}}}}
        """)
        try write("home/Library/Application Support/Claude/claude_desktop_config.json", """
        {"mcpServers": {"filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me"]},
                        "off": {"command": "y", "disabled": true}}}
        """)
        try write("home/.cursor/mcp.json", """
        {"mcpServers": {"linear": {"url": "https://mcp.linear.app/sse", "type": "sse"},
                        "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"]}}}
        """)

        let found = MCPImport.discover(home: home, project: project)
        let names = found.map { "\($0.config.source ?? "")/\($0.config.name)" }
        XCTAssertEqual(names, ["Claude Code/github", "Claude Code (this project)/db", "Claude Desktop/filesystem",
                               "Claude Desktop/off", "Cursor/github", "Cursor/linear", "Claude Code (this project)/docs"])
        XCTAssertFalse(names.contains { $0.hasSuffix("/other") }, "another project's servers stay out")

        let github = try XCTUnwrap(found.first { $0.config.name == "github" })
        XCTAssertEqual(github.config.transport, .stdio)
        XCTAssertEqual(github.config.summary, "npx -y @modelcontextprotocol/server-github")
        XCTAssertEqual(github.config.envNames, ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertEqual(github.environment["GITHUB_PERSONAL_ACCESS_TOKEN"], "ghp_secret")
        XCTAssertEqual(found.first { $0.config.name == "db" }?.config.args, ["mcp-db", "--port", "5432"])
        XCTAssertEqual(found.first { $0.config.name == "off" }?.config.enabled, false)
        let docs = try XCTUnwrap(found.first { $0.config.name == "docs" })
        XCTAssertEqual(docs.config.transport, .http)
        XCTAssertEqual(docs.headers["Authorization"], "Bearer ${DOCS_TOKEN}", "expanded when it starts, not on import")
        XCTAssertNotNil(found.first { $0.config.name == "linear" }?.caveat, "an SSE server is flagged")
        // The same server in two apps is the same server.
        let githubs = found.filter { $0.config.name == "github" }
        XCTAssertEqual(Set(githubs.map(\.fingerprint)).count, 1)
        XCTAssertTrue(MCPImport.isKnown(githubs[1], among: [githubs[0].config]))
    }

    func testNamesExpansionAndUniqueness() {
        XCTAssertEqual(MCPNames.toolName(server: "my server", tool: "create.issue"), "mcp__my_server__create_issue")
        let long = MCPNames.toolName(server: "a-very-long-server-name-indeed", tool: String(repeating: "tool", count: 20))
        XCTAssertEqual(long.count, 64)
        XCTAssertEqual(long, MCPNames.toolName(server: "a-very-long-server-name-indeed", tool: String(repeating: "tool", count: 20)))
        XCTAssertEqual(MCPImport.expand("Bearer ${TOKEN}", environment: ["TOKEN": "abc"]), "Bearer abc")
        XCTAssertEqual(MCPImport.expand("${MISSING:-fallback}/x", environment: [:]), "fallback/x")
        XCTAssertEqual(MCPImport.expand("${A}${B}", environment: ["A": "1", "B": "2"]), "12")
        XCTAssertEqual(MCPImport.uniqueName("github", taken: ["github", "GitHub-2"]), "github-3")
        XCTAssertEqual(MCPServerConfig(name: "x", transport: .http, url: "ftp://nope").problem, "It needs an http(s) address.")
        XCTAssertNil(MCPServerConfig(name: "x", transport: .stdio, command: "npx").problem)
    }

    func testSecretsLiveInTheKeychainNotTheFile() throws {
        let secrets = MemorySecretStore()
        let store = MCPServerStore(fileURL: dir.appendingPathComponent("mcp-servers.json"), secrets: secrets)
        var server = MCPServerConfig(name: "github", transport: .stdio, command: "npx", envNames: ["TOKEN"])
        store.setSecrets(for: server, environment: ["TOKEN": "ghp_123"], headers: [:])
        store.save([server])
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("ghp_123"))
        XCTAssertEqual(store.load().first?.name, "github")
        XCTAssertEqual(store.environment(for: server), ["TOKEN": "ghp_123"])
        let previous = server
        server.envNames = ["OTHER"]
        store.setSecrets(for: server, environment: ["OTHER": "v"], headers: [:], previous: previous)
        XCTAssertNil(secrets.read(service: MCPServerStore.keychainService, account: "\(server.id)/env/TOKEN"), "a dropped name's value goes")
    }

    func testAToolResultReadsTextPicturesAndResources() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let result = MCPCallResult(JSONValue(parsing: """
        {"content":[{"type":"text","text":"hello"},{"type":"image","data":"\(png)","mimeType":"image/png"},
                    {"type":"resource","resource":{"uri":"file:///a.txt","text":"inside"}}],"isError":false}
        """)!)
        XCTAssertEqual(result.text, "hello\n[image 1]\nResource file:///a.txt:\ninside")
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(MCPCallResult(JSONValue(parsing: #"{"content":[],"structuredContent":{"n":1}}"#)!).text, "{\n  \"n\" : 1\n}")
        XCTAssertTrue(MCPCallResult(JSONValue(parsing: #"{"content":[{"type":"text","text":"bad"}],"isError":true}"#)!).isError)
    }

    // MARK: stdio

    /// A tiny MCP server in sh: answers initialize, tools/list and tools/call (echoing its "text" argument), and
    /// prints a line that isn't JSON and some stderr on the way.
    private func fakeServer() throws -> URL {
        let script = dir.appendingPathComponent("fake-mcp.sh")
        try Data(#"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9]*\),.*/\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
            *'"method":"tools/list"'*)
              printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo text","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"write.note","description":"Writes a note"}]}}\n' "$id" ;;
            *'"method":"tools/call"'*)
              text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
              printf 'not json noise\n'
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"echo: %s"}]}}\n' "$id" "$text" ;;
          esac
          echo "fake server log" >&2
        done
        """#.utf8).write(to: script)
        return script
    }

    private func waitUntil(_ condition: () -> Bool, _ what: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func context(_ preset: PermissionPreset, asked: AskLog) -> ToolContext {
        ToolContext(workspace: dir, policy: PermissionPolicy(preset: preset, workspaceRoot: dir),
                    client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []),
                    requestPermission: { _, name, detail in asked.add(name + ": " + detail); return asked.answer })
    }

    final class AskLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func add(_ item: String) { lock.withLock { items.append(item) } }
        var all: [String] { lock.withLock { items } }
    }

    func testAStdioServersToolsBecomeTheModelsToolsBehindThePrompt() async throws {
        let script = try fakeServer()
        let manager = MCPManager(connector: { _ in
            MCPStdioConnection(command: "/bin/sh", args: [script.path], environment: [:], workingDirectory: nil,
                               viaLoginShell: false)
        })
        var server = MCPServerConfig(name: "fake", transport: .stdio, command: "/bin/sh")
        manager.apply([server])
        try await waitUntil({ manager.state(server.id)?.status == .ready }, "the server to connect")
        XCTAssertEqual(manager.state(server.id)?.tools.map(\.name), ["echo", "write.note"])

        let tools = manager.tools(reserved: ["mcp__fake__echo_taken_elsewhere"])
        XCTAssertEqual(tools.map(\.name), ["mcp__fake__echo", "mcp__fake__write_note"])
        let echo = try XCTUnwrap(tools.first as? MCPTool)
        XCTAssertTrue(echo.spec.description.hasPrefix("[MCP server “fake”] Echo text"))
        XCTAssertEqual(JSONValue(parsing: tools[1].spec.parameters)?["type"], "object", "a missing schema becomes an object")

        // Asked first, and declined: nothing runs.
        let declined = AskLog(answer: false)
        let refused = await echo.execute(args: #"{"text":"hi"}"#, in: context(.workspaceWrite, asked: declined))
        XCTAssertTrue(refused.output.hasPrefix("Error: the user declined"))
        XCTAssertEqual(declined.all.count, 1)
        XCTAssertTrue(declined.all[0].contains("MCP server “fake” wants to run its tool “echo”"))

        // Allowed: the server answers (the noise line in between is ignored).
        let allowed = AskLog(answer: true)
        let answer = await echo.execute(args: #"{"text":"hi"}"#, in: context(.workspaceWrite, asked: allowed))
        XCTAssertEqual(answer.output, "echo: hi")

        // Trusted with read-only tools: the read-only one runs without asking; the other still asks.
        server.trust = .readOnly
        manager.apply([server])
        let trusted = AskLog(answer: true)
        let free = try XCTUnwrap(manager.tools(reserved: []).first as? MCPTool)
        _ = await free.execute(args: #"{"text":"x"}"#, in: context(.workspaceWrite, asked: trusted))
        XCTAssertTrue(trusted.all.isEmpty)
        XCTAssertTrue((manager.tools(reserved: [])[1] as? MCPTool)?.needsApproval(context(.workspaceWrite, asked: trusted)) == true)
        XCTAssertFalse((manager.tools(reserved: [])[1] as? MCPTool)?.needsApproval(context(.fullAccess, asked: trusted)) == true)

        // Switched off: its tools leave.
        server.enabled = false
        manager.apply([server])
        XCTAssertTrue(manager.tools(reserved: []).isEmpty)
        manager.stopAll()
    }

    func testAServerThatFailsToStartSaysWhy() async throws {
        let script = dir.appendingPathComponent("broken.sh")
        try Data("#!/bin/sh\necho 'missing API key' >&2\nexit 3\n".utf8).write(to: script)
        let manager = MCPManager(connector: { _ in
            MCPStdioConnection(command: "/bin/sh", args: [script.path], environment: [:], workingDirectory: nil,
                               viaLoginShell: false)
        })
        let server = MCPServerConfig(name: "broken", transport: .stdio, command: "/bin/sh")
        manager.apply([server])
        try await waitUntil({ if case .failed = manager.state(server.id)?.status { return true }; return false }, "the failure")
        guard case .failed(let why) = manager.state(server.id)?.status else { return XCTFail() }
        XCTAssertTrue(why.contains("missing API key"), why)
        XCTAssertTrue(manager.tools(reserved: []).isEmpty)
    }

    // MARK: Streamable HTTP

    func testAStreamableHTTPServerWithASessionAndAnEventStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeMCPHTTP.self]
        FakeMCPHTTP.reset()
        let connection = MCPHTTPConnection(url: URL(string: "https://mcp.test/mcp")!, headers: ["Authorization": "Bearer t0k"],
                                           session: URLSession(configuration: configuration))
        let session = MCPServerSession(connection: connection)
        try await session.start()
        XCTAssertEqual(session.tools.map(\.name), ["search"])
        XCTAssertEqual(session.serverName, "fake-http")
        let result = try await session.call("search", arguments: ["q": "swift"])
        XCTAssertEqual(result.text, "found: swift")

        let seen = FakeMCPHTTP.seen
        XCTAssertEqual(seen.map(\.method), ["initialize", "notifications/initialized", "tools/list", "tools/call"])
        XCTAssertNil(seen[0].sessionID, "no session before the handshake")
        XCTAssertTrue(seen.dropFirst().allSatisfy { $0.sessionID == "sess-1" }, "the server's session id on every later request")
        XCTAssertTrue(seen.dropFirst().allSatisfy { $0.protocolVersion == "2025-06-18" })
        XCTAssertTrue(seen.allSatisfy { $0.authorization == "Bearer t0k" })
    }
}

/// A Streamable HTTP MCP server: initialize answers with a session id, tools/list answers on an event stream (after
/// a notification), tools/call with plain JSON.
final class FakeMCPHTTP: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var sessionID: String?
        var protocolVersion: String?
        var authorization: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _seen: [Seen] = []
    static var seen: [Seen] { lock.withLock { _seen } }
    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let message = JSONValue(parsing: body) ?? .null
        let method = message["method"]?.string ?? request.httpMethod ?? "?"
        Self.lock.withLock {
            Self._seen.append(Seen(method: method, sessionID: request.value(forHTTPHeaderField: "Mcp-Session-Id"),
                                   protocolVersion: request.value(forHTTPHeaderField: "MCP-Protocol-Version"),
                                   authorization: request.value(forHTTPHeaderField: "Authorization")))
        }
        let id = message["id"]?.int ?? 0
        switch method {
        case "initialize":
            respond(200, ["Content-Type": "application/json", "Mcp-Session-Id": "sess-1"],
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake-http"}}}"#)
        case "notifications/initialized":
            respond(202, [:], "")
        case "tools/list":
            respond(200, ["Content-Type": "text/event-stream"],
                    "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{\"level\":\"info\"}}\n\n"
                    + "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}\n\n")
        case "tools/call":
            let q = message["params"]?["arguments"]?["q"]?.string ?? ""
            respond(200, ["Content-Type": "application/json"],
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"found: \#(q)"}]}}"#)
        default:
            respond(404, ["Content-Type": "text/plain"], "no")
        }
    }

    private func respond(_ status: Int, _ headers: [String: String], _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
