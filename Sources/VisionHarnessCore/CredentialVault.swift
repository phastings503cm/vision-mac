import Foundation
import CryptoKit
import Security

// MARK: - Credential vault
//
// API keys, tokens and passwords the agent may use without ever seeing them.
//
// - Values are encrypted at rest in the macOS Keychain (one item holds them
//   all, so a rebuilt app asks for Keychain access at most once). Everything
//   else — name, description, tags, a SHA-256 fingerprint — lives in a plain
//   JSON file, so searching the vault never touches a secret.
// - The model finds credentials with `vault_search` (names, descriptions,
//   fingerprints; never values) and writes `{{vault:NAME}}` wherever a value
//   belongs in a tool call — a shell command, a file it writes, a URL or
//   header. The engine substitutes the real value just before the tool runs
//   and scrubs every vault value out of every tool result, so a secret never
//   reaches the model, the transcript, or the logs.
// - Each credential says whether the agent may use it freely, must ask first
//   (once per chat), or may never use it.
// - The user opens the vault to browse, search, reveal ("show the value
//   behind the fingerprint"), copy, edit and delete.

public struct VaultEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case apiKey, token, password, other
        public var label: String {
            switch self {
            case .apiKey: "API key"
            case .token: "Token"
            case .password: "Password"
            case .other: "Other"
            }
        }
    }

    /// What the agent may do with the credential.
    public enum AgentAccess: String, Codable, CaseIterable, Sendable {
        /// Use it whenever a task needs it.
        case allowed
        /// Ask the user the first time a chat uses it.
        case ask
        /// Never hand it to the agent (it can still see that it exists).
        case never
        public var label: String {
            switch self {
            case .allowed: "Agent may use"
            case .ask: "Ask first"
            case .never: "Never"
            }
        }
    }

    public var id: String
    /// The handle the agent writes: `{{vault:NAME}}`. Letters, digits, `_`, `-`, `.`.
    public var name: String
    public var kind: Kind
    public var description: String
    public var tags: [String]
    /// Account / login the credential belongs to, when there is one.
    public var username: String?
    /// Where it's used ("https://api.openai.com").
    public var url: String?
    /// "sha256:1a2b3c4d5e6f" — identifies the value without revealing it.
    public var fingerprint: String
    public var access: AgentAccess
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(id: String = UUID().uuidString, name: String, kind: Kind = .apiKey, description: String = "",
                tags: [String] = [], username: String? = nil, url: String? = nil, fingerprint: String,
                access: AgentAccess = .allowed, createdAt: Date = .now, updatedAt: Date = .now,
                lastUsedAt: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.description = description
        self.tags = tags
        self.username = username
        self.url = url
        self.fingerprint = fingerprint
        self.access = access
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    /// The placeholder the agent writes to use this credential.
    public var placeholder: String { "{{vault:\(name)}}" }

    /// Every word a search can match.
    var haystack: String {
        ([name, kind.label, description, username ?? "", url ?? "", fingerprint] + tags)
            .joined(separator: " ").lowercased()
    }
}

/// Where the secret values live. The app uses the Keychain; tests use memory.
public protocol SecretBlobStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    /// Remove the stored values (none stored is not an error).
    func delete() throws
}

public enum VaultError: LocalizedError, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case emptyValue
    case notFound(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): "“\(n)” isn't a usable name — use letters, digits, _ - or . (e.g. OPENAI_API_KEY)."
        case .duplicateName(let n): "There is already a credential named \(n)."
        case .emptyValue: "The secret value is empty."
        case .notFound(let n): "No credential named \(n)."
        case .keychain(let status): "The Keychain refused the operation (\(status))."
        }
    }
}

/// The macOS Keychain, one generic-password item holding every value.
public struct KeychainBlobStore: SecretBlobStore {
    public let service: String
    public let account: String

    public init(service: String = AppIdentity.KeychainService.vault, account: String = "secrets") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return out as? Data
    }

    public func save(_ data: Data) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "\(AppIdentity.name) credential vault"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
}

/// Values in memory only (tests).
public final class MemoryBlobStore: SecretBlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func load() throws -> Data? { lock.withLock { data } }
    public func save(_ data: Data) throws { lock.withLock { self.data = data } }
    public func delete() throws { lock.withLock { data = nil } }
}

/// What the engine learns when it looks a credential up.
public enum VaultLookup: Equatable, Sendable {
    case value(String, access: VaultEntry.AgentAccess)
    case missing
}

/// The credential vault. Thread-safe; shared by the UI and every engine.
public final class CredentialVault: @unchecked Sendable {
    private let lock = NSLock()
    private let metadataURL: URL
    private let store: any SecretBlobStore
    private var entries: [VaultEntry] = []
    /// Decrypted values by entry id, loaded from the store on first need.
    private var values: [String: String]?
    /// Secrets held for this run of the app only — never written to vault.json or the Keychain (Guardian's
    /// "Usable in Vision" secrets: memory-only on the device). They read like any other entry.
    private var sessionEntries: [VaultEntry] = []
    private var sessionValues: [String: String] = [:]
    /// Bumped on every change (the UI and the system prompt follow it).
    public private(set) var revision = 0

    public init(directory: URL, store: any SecretBlobStore = AppSecrets.vault) {
        self.metadataURL = directory.appendingPathComponent("vault.json")
        self.store = store
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) {
            entries = decoded
        }
    }

    // MARK: Reading

    public var all: [VaultEntry] {
        lock.withLock { (entries + sessionEntries).sorted { $0.name.lowercased() < $1.name.lowercased() } }
    }
    public var isEmpty: Bool { lock.withLock { entries.isEmpty && sessionEntries.isEmpty } }

    public func entry(named name: String) -> VaultEntry? {
        lock.withLock {
            entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                ?? sessionEntries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Whether an entry lives only for this run of the app (see `addSessionOnly`).
    public func isSessionOnly(_ entry: VaultEntry) -> Bool {
        lock.withLock { sessionEntries.contains { $0.id == entry.id } }
    }

    /// Hold a secret for this run of the app only: usable as `{{vault:NAME}}` and scrubbed from tool output like
    /// any other, but never written to disk or the Keychain. Adding the same name again replaces the value. A name
    /// a stored credential already has is refused.
    @discardableResult
    public func addSessionOnly(name: String, value: String, kind: VaultEntry.Kind = .apiKey, description: String = "",
                               tags: [String] = [], username: String? = nil, url: String? = nil,
                               access: VaultEntry.AgentAccess = .ask) throws -> VaultEntry {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw VaultError.invalidName(name) }
        guard !value.isEmpty else { throw VaultError.emptyValue }
        return try lock.withLock {
            guard !entries.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw VaultError.duplicateName(name)
            }
            sessionEntries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let entry = VaultEntry(name: name, kind: kind, description: description, tags: Self.clean(tags),
                                   username: username?.nilIfBlank, url: url?.nilIfBlank,
                                   fingerprint: Self.fingerprint(value), access: access)
            sessionEntries.append(entry)
            sessionValues[entry.id] = value
            revision += 1
            return entry
        }
    }

    /// Forget a session-only secret (or all of them, e.g. on signing out of Guardian).
    public func removeSessionOnly(named name: String? = nil) {
        lock.withLock {
            let gone = sessionEntries.filter { name == nil || $0.name.caseInsensitiveCompare(name!) == .orderedSame }
            for entry in gone { sessionValues[entry.id] = nil }
            sessionEntries.removeAll { entry in gone.contains { $0.id == entry.id } }
            if !gone.isEmpty { revision += 1 }
        }
    }

    /// Entries matching every word of `query` (name, kind, description, tags,
    /// username, URL, fingerprint). An empty query matches everything.
    public func search(_ query: String) -> [VaultEntry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        return all.filter { entry in words.allSatisfy { entry.haystack.contains($0) } }
    }

    /// The secret value (for the engine's substitution and the UI's reveal).
    public func value(for id: String) throws -> String? {
        try lock.withLock {
            if let session = sessionValues[id] { return session }
            try loadValuesLocked()
            return values?[id]
        }
    }

    /// Look a credential up by the name the agent wrote.
    public func lookup(_ name: String) -> VaultLookup {
        guard let entry = entry(named: name), let value = try? value(for: entry.id), !value.isEmpty else { return .missing }
        return .value(value, access: entry.access)
    }

    /// Every (name, value) pair, longest value first — for scrubbing tool
    /// output. Empty (without touching the Keychain) when the vault is empty.
    public func valuesForRedaction() -> [(name: String, value: String)] {
        lock.withLock {
            let session = sessionEntries.compactMap { e in sessionValues[e.id].map { (e.name, $0) } }
            var stored: [(String, String)] = []
            if !entries.isEmpty, (try? loadValuesLocked()) != nil, let values {
                stored = entries.compactMap { e in values[e.id].map { (e.name, $0) } }
            }
            return (stored + session).map { (name: $0.0, value: $0.1) }
                .filter { $0.value.count >= 4 }
                .sorted { $0.value.count > $1.value.count }
        }
    }

    // MARK: Writing

    @discardableResult
    public func add(name: String, value: String, kind: VaultEntry.Kind = .apiKey, description: String = "",
                    tags: [String] = [], username: String? = nil, url: String? = nil,
                    access: VaultEntry.AgentAccess = .allowed) throws -> VaultEntry {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw VaultError.invalidName(name) }
        guard !value.isEmpty else { throw VaultError.emptyValue }
        return try lock.withLock {
            guard !entries.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw VaultError.duplicateName(name)
            }
            try loadValuesLocked()
            let entry = VaultEntry(name: name, kind: kind, description: description, tags: Self.clean(tags),
                                   username: username?.nilIfBlank, url: url?.nilIfBlank,
                                   fingerprint: Self.fingerprint(value), access: access)
            var newValues = values ?? [:]
            newValues[entry.id] = value
            try saveValuesLocked(newValues)
            entries.append(entry)
            try persistLocked()
            return entry
        }
    }

    /// Update a credential's details, and its value when `value` is given.
    public func update(_ updated: VaultEntry, value: String? = nil) throws {
        let name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw VaultError.invalidName(name) }
        if let value, value.isEmpty { throw VaultError.emptyValue }
        try lock.withLock {
            guard let i = entries.firstIndex(where: { $0.id == updated.id }) else { throw VaultError.notFound(updated.name) }
            guard !entries.contains(where: { $0.id != updated.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw VaultError.duplicateName(name)
            }
            var e = updated
            e.name = name
            e.tags = Self.clean(e.tags)
            e.username = e.username?.nilIfBlank
            e.url = e.url?.nilIfBlank
            e.updatedAt = .now
            if let value {
                try loadValuesLocked()
                var newValues = values ?? [:]
                newValues[e.id] = value
                try saveValuesLocked(newValues)
                e.fingerprint = Self.fingerprint(value)
            }
            entries[i] = e
            try persistLocked()
        }
    }

    public func delete(id: String) throws {
        try lock.withLock {
            if let j = sessionEntries.firstIndex(where: { $0.id == id }) {
                sessionEntries.remove(at: j)
                sessionValues[id] = nil
                revision += 1
                return
            }
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            try loadValuesLocked()
            var newValues = values ?? [:]
            newValues[id] = nil
            try saveValuesLocked(newValues)
            entries.remove(at: i)
            try persistLocked()
        }
    }

    /// Record that the agent used a credential.
    public func noteUse(_ name: String) {
        lock.withLock {
            if let j = sessionEntries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                sessionEntries[j].lastUsedAt = .now
                sessionEntries[j].useCount += 1
                return
            }
            guard let i = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            entries[i].lastUsedAt = .now
            entries[i].useCount += 1
            try? persistLocked()
        }
    }

    // MARK: Helpers

    /// "sha256:" + the first 12 hex digits of the value's SHA-256.
    public static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) }
    }

    private static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func loadValuesLocked() throws {
        guard values == nil else { return }
        if let data = try store.load() {
            values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else {
            values = [:]
        }
    }

    private func saveValuesLocked(_ newValues: [String: String]) throws {
        let data = try JSONEncoder().encode(newValues)
        try store.save(data)
        values = newValues
    }

    private func persistLocked() throws {
        revision += 1
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: metadataURL, options: .atomic)
    }
}

// MARK: - Placeholders

/// `{{vault:NAME}}` in tool arguments: found, substituted, and scrubbed back.
public enum VaultPlaceholders {
    static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*vault:([A-Za-z0-9_.\-]+)\s*\}\}"#)

    /// The credential names a tool call refers to, in order, without repeats.
    public static func names(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return pattern.matches(in: text, range: range).compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            let name = String(text[r])
            return seen.insert(name.lowercased()).inserted ? name : nil
        }
    }

    /// Replace each placeholder in a JSON-encoded argument string with its
    /// value, escaped so the JSON stays valid.
    public static func substitute(in json: String, values: [String: String]) -> String {
        let range = NSRange(json.startIndex..., in: json)
        var out = json
        for m in pattern.matches(in: json, range: range).reversed() {
            guard let whole = Range(m.range, in: out), let nameRange = Range(m.range(at: 1), in: json) else { continue }
            let name = String(json[nameRange])
            guard let value = values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else { continue }
            out.replaceSubrange(whole, with: jsonEscaped(value))
        }
        return out
    }

    /// Replace every vault value in `text` with `[vault:NAME]`.
    public static func redact(_ text: String, values: [(name: String, value: String)]) -> String {
        var out = text
        for (name, value) in values where out.contains(value) {
            out = out.replacingOccurrences(of: value, with: "[vault:\(name)]")
        }
        return out
    }

    /// A string's contents as they appear inside a JSON string literal.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return value }
        // ["…"] → …
        return String(s.dropFirst(2).dropLast(2))
    }
}

// MARK: - The vault_search tool

public struct VaultSearchTool: ToolExecutor {
    public static let name = "vault_search"
    public static let spec = ToolSpec(
        name: name,
        description: "Search the user's credential vault (API keys, tokens, passwords) by name, service, tag or description. Returns names, descriptions and fingerprints — never values. To use a credential, write {{vault:NAME}} where the value goes in any tool call (a shell command, a file you write, a URL or header); the harness substitutes the real value when the tool runs and hides it from results. Never ask the user to paste a secret that is in the vault.",
        parameters: #"{"type":"object","properties":{"query":{"type":"string","description":"Words to match, e.g. 'openai' or 'stripe test'. Empty lists everything."}}}"#
    )

    public let vault: CredentialVault
    public init(vault: CredentialVault) { self.vault = vault }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let query = (Self.string(args, "query") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = vault.search(query)
        guard !hits.isEmpty else {
            let total = vault.all.count
            return ToolResult(output: total == 0
                ? "The vault is empty. Ask the user to add the credential in the Credentials Vault (⌘⇧K) — never ask them to paste it into chat."
                : "No credential matches “\(query)” (\(total) in the vault). Try a broader word, or an empty query to list them all.")
        }
        var lines = ["\(hits.count) credential\(hits.count == 1 ? "" : "s"):"]
        for e in hits.prefix(50) {
            var line = "- \(e.placeholder) — \(e.kind.label)"
            if !e.description.isEmpty { line += ": \(e.description)" }
            var details: [String] = []
            if let u = e.username { details.append("user \(u)") }
            if let url = e.url { details.append(url) }
            if !e.tags.isEmpty { details.append("tags " + e.tags.joined(separator: ", ")) }
            details.append(e.fingerprint)
            switch e.access {
            case .allowed: break
            case .ask: details.append("asks the user before first use")
            case .never: details.append("NOT available to the agent")
            }
            line += " (" + details.joined(separator: "; ") + ")"
            lines.append(line)
        }
        if hits.count > 50 { lines.append("… \(hits.count - 50) more; narrow the query.") }
        lines.append("Use one by writing its placeholder, e.g. export API_KEY={{vault:\(hits[0].name)}} in a shell command.")
        return ToolResult(output: lines.joined(separator: "\n"))
    }
}

/// Which credentials this chat has been allowed to use (for "ask first").
public final class VaultGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<String> = []
    public init() {}
    public func has(_ name: String) -> Bool { lock.withLock { granted.contains(name.lowercased()) } }
    public func grant(_ name: String) { lock.withLock { _ = granted.insert(name.lowercased()) } }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
