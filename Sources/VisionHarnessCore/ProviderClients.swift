import Foundation

// MARK: - Provider clients
//
// Every configured route is served by one of three clients: Bedrock routes by `BedrockClient` (the
// Converse API, signed with SigV4 or authorised with a Bedrock API key), "Anthropic API (key)" routes by
// `AnthropicClient` (the Messages API), everything else by `OpenAIClient` (chat completions). The app asks for a client here instead of choosing one itself —
// which is also where a route that isn't private gets the sensitive-data shield (`ShieldClient`) and the
// main model gets its backups (`FailoverClient`), each backup with its own shield.

/// A streaming client bound to one provider profile, with the model probe the
/// app uses to size the context gauge and to follow a server that swapped models.
public protocol ProviderClient: LLMClient {
    var profile: ProviderProfile { get }

    /// The route's model metadata (context window, the id actually served, …);
    /// nil when nothing answered.
    func modelInfo(_ model: String?) async -> ModelInfo?
}

extension OpenAIClient: ProviderClient {}

/// What the app hears from the clients it asks for: a turn that ran on a backup, what was masked, and a line when
/// a client adapted to a parameter the server refused.
public struct ClientEvents: Sendable {
    public var failover: (@Sendable (FailoverNotice) -> Void)?
    public var shield: (@Sendable (ShieldReport) -> Void)?
    public var notice: (@Sendable (String) -> Void)?

    public init(failover: (@Sendable (FailoverNotice) -> Void)? = nil, shield: (@Sendable (ShieldReport) -> Void)? = nil,
                notice: (@Sendable (String) -> Void)? = nil) {
        self.failover = failover
        self.shield = shield
        self.notice = notice
    }
}

public enum ProviderClients {
    /// Where Bedrock routes signed with AWS credentials get them; the app sets
    /// this at startup to its AWS-CLI-backed source. Nil (or a route with
    /// neither an AWS profile nor an API key) leaves Bedrock clients without
    /// credentials: their calls fail with a request to sign in.
    nonisolated(unsafe) public static var awsCredentials: (@Sendable (ProviderProfile) -> (any AWSCredentialSource)?)?

    /// What the sensitive-data shield masks for routes that aren't private; the app sets this at startup. Nil
    /// leaves every client unwrapped.
    nonisolated(unsafe) public static var shield: ShieldPolicy?

    /// The client for `profile`.
    public static func make(_ profile: ProviderProfile) -> any ProviderClient {
        make(profile, backups: [])
    }

    /// The client for `profile`; with `backups`, a request it fails before answering is tried on each of them in
    /// turn (see `FailoverClient`).
    public static func make(_ profile: ProviderProfile, backups: [ProviderProfile], events: ClientEvents = ClientEvents()) -> any ProviderClient {
        let main = single(profile, events)
        guard !backups.isEmpty else { return main }
        return FailoverClient(primary: main, backups: backups.map { single($0, events) },
                              onFailover: events.failover ?? { _ in })
    }

    /// One route's client — behind the shield when the route isn't private and there is something to mask.
    private static func single(_ profile: ProviderProfile, _ events: ClientEvents) -> any ProviderClient {
        let client: any ProviderClient
        switch profile.kind {
        case .bedrock:
            let usesAPIKey = profile.awsProfile == nil && !(profile.apiKey ?? "").isEmpty
            client = BedrockClient(profile: profile, credentials: usesAPIKey ? nil : awsCredentials?(profile))
        case .anthropic:
            client = AnthropicClient(profile: profile, onNotice: events.notice)
        default:
            client = OpenAIClient(profile: profile, onNotice: events.notice)
        }
        guard !profile.isPrivateRoute, let detector = shield?.detector() else { return client }
        return ShieldClient(inner: client, detector: detector, onReport: events.shield)
    }
}

