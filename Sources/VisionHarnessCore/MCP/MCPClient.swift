import Foundation

// MARK: - One MCP server's session: handshake, tools, calls

/// A tool an MCP server offers.
public struct MCPToolInfo: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String?
    /// The JSON Schema of its arguments.
    public var inputSchema: JSONValue
    /// The server says it only reads (`annotations.readOnlyHint`).
    public var readOnly: Bool
    /// The server says it may destroy something (`annotations.destructiveHint`).
    public var destructive: Bool

    public init(name: String, title: String? = nil, description: String? = nil,
                inputSchema: JSONValue = ["type": "object"], readOnly: Bool = false, destructive: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
    }

    init?(_ json: JSONValue) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        title = json["title"]?.string ?? json["annotations"]?["title"]?.string
        description = json["description"]?.string
        var schema = json["inputSchema"] ?? ["type": "object"]
        // A schema must be an object with a type for every provider; servers sometimes leave the type out.
        if case .object(var fields) = schema {
            if fields["type"] == nil { fields["type"] = "object" }
            if fields["properties"] == nil { fields["properties"] = .object([:]) }
            schema = .object(fields)
        } else {
            schema = ["type": "object", "properties": .object([:])]
        }
        inputSchema = schema
        readOnly = json["annotations"]?["readOnlyHint"]?.bool ?? false
        destructive = json["annotations"]?["destructiveHint"]?.bool ?? false
    }
}

/// What a tool call returned.
public struct MCPCallResult: Sendable, Equatable {
    public var text: String
    public var images: [MessageAttachment]
    public var isError: Bool

    public init(text: String, images: [MessageAttachment] = [], isError: Bool = false) {
        self.text = text
        self.images = images
        self.isError = isError
    }

    /// Read a `tools/call` result: its content blocks in order (text, pictures, resources), else its structured
    /// content as JSON.
    public init(_ result: JSONValue) {
        var parts: [String] = []
        var images: [MessageAttachment] = []
        for (index, block) in (result["content"]?.array ?? []).enumerated() {
            switch block["type"]?.string {
            case "text":
                parts.append(block["text"]?.string ?? "")
            case "image":
                if let base64 = block["data"]?.string, let data = Data(base64Encoded: base64) {
                    let ext = (block["mimeType"]?.string ?? "image/png").split(separator: "/").last.map(String.init) ?? "png"
                    images.append(MessageAttachment(kind: .image, name: "mcp-image-\(index + 1).\(ext)", data: data))
                    parts.append("[image \(images.count)]")
                }
            case "audio":
                parts.append("[audio (\(block["mimeType"]?.string ?? "audio")) — not shown]")
            case "resource_link":
                parts.append("[resource: \(block["name"]?.string ?? "") \(block["uri"]?.string ?? "")]")
            case "resource":
                let resource = block["resource"]
                let uri = resource?["uri"]?.string ?? ""
                if let text = resource?["text"]?.string {
                    parts.append("Resource \(uri):\n\(text)")
                } else {
                    parts.append("[binary resource \(uri) (\(resource?["mimeType"]?.string ?? "unknown type"))]")
                }
            default:
                parts.append(block.serialized())
            }
        }
        if parts.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           let structured = result["structuredContent"], !structured.isNull {
            parts = [structured.serialized(pretty: true)]
        }
        self.text = parts.joined(separator: "\n")
        self.images = images
        self.isError = result["isError"]?.bool ?? false
    }
}

/// A server's session: the handshake, then its tools (and resources, when it has them).
public final class MCPServerSession: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    public static let handshakeTimeout: TimeInterval = 60
    public static let callTimeout: TimeInterval = 600

    public let connection: any MCPConnection
    private let lock = NSLock()
    private var _tools: [MCPToolInfo] = []
    private var _serverName: String?
    private var _instructions: String?
    private var _hasResources = false

    public init(connection: any MCPConnection) {
        self.connection = connection
    }

    public var tools: [MCPToolInfo] { lock.withLock { _tools } }
    public var serverName: String? { lock.withLock { _serverName } }
    public var instructions: String? { lock.withLock { _instructions } }
    public var hasResources: Bool { lock.withLock { _hasResources } }

    /// Start it, shake hands, and read its tools.
    public func start() async throws {
        try await connection.start()
        let result = try await connection.request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": ["name": .string(AppIdentity.name), "version": .string(AppIdentity.version)],
        ], timeout: Self.handshakeTimeout)
        let version = result["protocolVersion"]?.string
        (connection as? MCPHTTPConnection)?.setProtocolVersion(version ?? Self.protocolVersion)
        lock.withLock {
            _serverName = result["serverInfo"]?["name"]?.string
            _instructions = result["instructions"]?.string
            _hasResources = result["capabilities"]?["resources"].map { !$0.isNull } ?? false
        }
        try await connection.notify("notifications/initialized", params: nil)
        try await refreshTools()
    }

    /// Read the tool list again (all pages).
    public func refreshTools() async throws {
        var all: [MCPToolInfo] = []
        var cursor: String?
        var pages = 0
        repeat {
            let params: JSONValue? = cursor.map { ["cursor": .string($0)] }
            let result: JSONValue
            do {
                result = try await connection.request("tools/list", params: params, timeout: Self.handshakeTimeout)
            } catch MCPError.server(let code, _) where code == -32601 {
                break   // a server with no tools
            }
            all += (result["tools"]?.array ?? []).compactMap(MCPToolInfo.init)
            cursor = result["nextCursor"]?.string
            pages += 1
        } while cursor != nil && pages < 50
        lock.withLock { _tools = all }
    }

    public func call(_ tool: String, arguments: JSONValue) async throws -> MCPCallResult {
        let result = try await connection.request("tools/call", params: [
            "name": .string(tool), "arguments": arguments.object != nil ? arguments : .object([:]),
        ], timeout: Self.callTimeout)
        return MCPCallResult(result)
    }

    /// The server's resources: a list (no `uri`), or one read.
    public func resources(uri: String?) async throws -> String {
        if let uri, !uri.isEmpty {
            let result = try await connection.request("resources/read", params: ["uri": .string(uri)],
                                                      timeout: Self.handshakeTimeout)
            return (result["contents"]?.array ?? []).map { item in
                if let text = item["text"]?.string { return "\(item["uri"]?.string ?? uri):\n\(text)" }
                return "[binary \(item["uri"]?.string ?? uri) (\(item["mimeType"]?.string ?? "unknown type"))]"
            }.joined(separator: "\n\n")
        }
        let result = try await connection.request("resources/list", params: nil, timeout: Self.handshakeTimeout)
        let items = result["resources"]?.array ?? []
        guard !items.isEmpty else { return "The server lists no resources." }
        return items.prefix(200).map { item in
            "- \(item["uri"]?.string ?? "") — \(item["name"]?.string ?? "")"
                + (item["description"]?.string.map { ": \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    public func close() async { await connection.close() }
}
