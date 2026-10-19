import Foundation

// MARK: - Sensitive chats: which models may see them
//
// A chat (or every chat of a project, by default) can be marked **Sensitive**. A Sensitive chat talks only to
// routes that may see its data as it is — or, for every other route, only through the sensitive-data shield, which
// masks what it detects before a request leaves the Mac and puts the real values back in the answer:
//
//   * private routes — the model runs on hardware you control (a Spark, a Strix Halo box, Ollama, LM Studio: the
//     route's Private switch, by default decided by its address — see `RoutePrivacy`), your organisation's own
//     Guardian, or Amazon Bedrock in your own AWS account. (A route whose Private switch is off still goes through
//     the shield as it does in every chat — Bedrock does by default.)
//   * masked routes — every other online service, but only while the shield is switched on;
//   * refused — engines that read the project's files themselves and send them to their service (the Claude Code
//     CLI): the shield never sees what they send, so no masking can stand between them and the data. And every
//     route that isn't private while the shield is switched off.
//
// Pure values and functions: the Mac app, the Windows harness and the tests decide the same way, with the same words.

/// How a Sensitive chat may use a route.
public enum RouteAdmission: Equatable, Sendable {
    /// The route may see the chat as it is. `why` names what makes it private ("your own hardware").
    case privateRoute(why: String)
    /// Allowed only behind the sensitive-data shield: masked before sending, unmasked after.
    case masked
    /// Not allowed in a Sensitive chat; `reason` says why in a plain sentence.
    case refused(reason: String)

    /// Whether a Sensitive chat may send to the route at all.
    public var isAllowed: Bool {
        if case .refused = self { return false }
        return true
    }

    /// The reason a route is refused (nil when it is allowed).
    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }

    /// Stable machine word for logs, tests and the Windows twin: "private", "masked", "refused".
    public var code: String {
        switch self {
        case .privateRoute: "private"
        case .masked: "masked"
        case .refused: "refused"
        }
    }
}

public enum SensitivityPolicy {
    /// Route kinds (by raw value) whose engine reads the project's files itself and sends them to its own service —
    /// the Claude Code CLI, the Codex CLI. Kept as raw values so a kind added later is covered without a change here.
    public static let directFileEngineKinds: Set<String> = [
        "claudeCode", "claude_code", "claude-code", "claudeCodeCLI", "codex", "codexCLI", "codex_cli",
    ]

    /// How a route is named in the policy's sentences: its name, else its model (as the model menu names it).
    public static func label(_ route: ProviderProfile) -> String {
        route.name.isEmpty ? route.model : route.name
    }

    /// Whether a route's engine reads files directly (see `directFileEngineKinds`).
    public static func readsFilesDirectly(_ route: ProviderProfile) -> Bool {
        directFileEngineKinds.contains(route.kind.rawValue)
    }

    /// How a Sensitive chat may use `route`, with the shield switched on or off (Settings ▸ AI Models ▸ Sensitive
    /// data). A chat that isn't Sensitive may use every route — this is only asked for Sensitive ones.
    public static func admission(for route: ProviderProfile, shieldOn: Bool) -> RouteAdmission {
        admission(kind: route.kind.rawValue, name: label(route), isPrivate: route.isPrivateRoute, shieldOn: shieldOn)
    }

    /// The rule itself, on a route's kind (raw value), name and Private switch — so the Windows twin and the tests
    /// can ask about kinds this build doesn't have.
    public static func admission(kind: String, name: String, isPrivate: Bool, shieldOn: Bool) -> RouteAdmission {
        if directFileEngineKinds.contains(kind) {
            return .refused(reason: "\(name) reads your files itself and sends them to its own service, so the "
                + "sensitive-data shield can't mask anything on the way. Sensitive chats can't use it — choose a "
                + "private model (your own hardware, Guardian, Amazon Bedrock in your AWS account), or turn Sensitive "
                + "off for this chat.")
        }
        switch kind {
        case ProviderProfile.Kind.guardian.rawValue:
            return .privateRoute(why: "Guardian, your organisation's own server")
        case ProviderProfile.Kind.bedrock.rawValue:
            return .privateRoute(why: "Amazon Bedrock in your own AWS account")
        default:
            break
        }
        if isPrivate {
            return .privateRoute(why: "your own hardware")
        }
        guard shieldOn else {
            return .refused(reason: "\(name) is an online service and the sensitive-data shield is switched off, so "
                + "nothing would be masked before sending. Turn the shield on (Settings ▸ AI Models ▸ Sensitive data), "
                + "choose a private model, or turn Sensitive off for this chat.")
        }
        return .masked
    }

    /// The error a Sensitive chat shows when its model is refused (also what a turn throws).
    public static func refusalMessage(for route: ProviderProfile, shieldOn: Bool) -> String? {
        guard let reason = admission(for: route, shieldOn: shieldOn).refusal else { return nil }
        return "This chat is Sensitive. " + reason
    }

    /// The line the chat header shows for a Sensitive chat on `route`.
    public static func headerLine(for route: ProviderProfile?, shieldOn: Bool) -> String {
        guard let route else { return "Sensitive — only private models, or others through the shield." }
        switch admission(for: route, shieldOn: shieldOn) {
        case .privateRoute(let why):
            return "Sensitive — \(label(route)) is private (\(why))."
        case .masked:
            return "Sensitive — \(label(route)) isn't private: what the shield detects is masked before sending."
        case .refused:
            return "Sensitive — \(label(route)) can't be used in this chat. Choose a private model."
        }
    }

    /// What the chat header's help (and the toggle's explanation) says the policy is.
    public static let explanation =
        "A Sensitive chat uses only private models — your own hardware (Spark, Strix Halo, Ollama, LM Studio), "
        + "Guardian, or Amazon Bedrock in your AWS account — or other models only through the sensitive-data shield, "
        + "which masks what it detects before sending and puts it back in the answer. Engines that read your files "
        + "themselves, like Claude Code, are refused."

    /// The backups a Sensitive chat may fall over to: only routes it may use.
    public static func admittedBackups(_ routes: [ProviderProfile], shieldOn: Bool) -> [ProviderProfile] {
        routes.filter { admission(for: $0, shieldOn: shieldOn).isAllowed }
    }

    /// Whether a route may see a Sensitive chat as it is, whatever the shield: your own hardware, Guardian, Bedrock in
    /// your AWS account (never an engine that reads files itself). A chat's own route that is private this way takes
    /// its subagents' sensitive tasks — it already sees the chat.
    public static func isPrivate(_ route: ProviderProfile) -> Bool {
        if case .privateRoute = admission(for: route, shieldOn: false) { return true }
        return false
    }

    /// Whether a Sensitive chat's subagents must stay on private servers: when the shield is off, a server that
    /// isn't private would get the data as it is. (With the shield on, a subagent on such a server is masked like
    /// any request to it.)
    public static func subagentsPrivateOnly(shieldOn: Bool) -> Bool { !shieldOn }
}

/// A turn refused because the chat is Sensitive and its model may not see it.
public struct SensitivityRefusal: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
