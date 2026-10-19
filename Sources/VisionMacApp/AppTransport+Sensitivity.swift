import Foundation
import VisionHarnessCore

// MARK: - Sensitive chats
//
// A chat marked Sensitive talks only to models that may see it: private ones (your own hardware, Guardian, Amazon
// Bedrock in your AWS account), or others only through the sensitive-data shield. Engines that read files themselves
// (Claude Code) are refused. The rules are `SensitivityPolicy`'s; this file applies them to chats: the per-project
// default a new chat starts with, the per-chat toggle, and the checks before anything is sent.

extension AppTransport {
    /// Whether the shield is switched on (Settings ▸ AI Models ▸ Sensitive data).
    @MainActor
    var shieldOn: Bool { config.shield.enabled }

    /// A new chat starts Sensitive when its project (or, without one, plain chats) is set to.
    @MainActor
    func assignInitialSensitivity(_ vm: SessionVM) {
        vm.sensitive = config.projectSensitive[AppConfig.projectKey(vm.cwd)] ?? false
        log.setSensitive(id: vm.id, vm.sensitive)
    }

    /// Make a chat Sensitive without a note (a queue task's chat, queued from a Sensitive chat).
    @MainActor
    func markSensitive(_ vm: SessionVM) {
        vm.sensitive = true
        log.setSensitive(id: vm.id, true)
    }

    /// Store a chat that comes from elsewhere (downloaded from Guardian, imported): it is Sensitive when it was, or
    /// when its project starts its chats Sensitive — the same default `newSession` gives. Every path that writes a
    /// chat into the log without `newSession` goes through here.
    @MainActor
    public func storeImportedChat(_ session: LogSession, items: [LogItemRow]) {
        var session = session
        session.sensitive = (session.sensitive == true || projectStartsSensitive(session.cwd)) ? true : nil
        log.store(session, items: items)
    }

    /// Mark a chat Sensitive or not. Its engine is rebuilt on the next turn (the prompt and subagent rules change).
    @MainActor
    public func setSensitive(_ on: Bool, for vm: SessionVM) {
        guard vm.sensitive != on else { return }
        vm.sensitive = on
        log.setSensitive(id: vm.id, on)
        let text: String
        if on {
            text = "🔒 This chat is now Sensitive. " + SensitivityPolicy.explanation
                + (sensitivityRefusal(for: vm).map { "\n\n" + $0 } ?? "")
        } else {
            text = "This chat is no longer Sensitive: every model may be used, with the usual masking for models that aren't private."
        }
        vm.note(text)
        log.recordItem(vm.id, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
    }

    /// Whether new chats in a project start Sensitive ("" or nil = chats without a project).
    @MainActor
    public func projectStartsSensitive(_ path: String?) -> Bool {
        config.projectSensitive[AppConfig.projectKey(path)] ?? false
    }

    @MainActor
    public func setProjectStartsSensitive(_ on: Bool, path: String?) {
        let key = AppConfig.projectKey(path)
        if on { config.projectSensitive[key] = true } else { config.projectSensitive[key] = nil }
    }

    /// How the chat's model may be used in it (nil: the chat isn't Sensitive, or it has no model).
    @MainActor
    public func sensitivityAdmission(for vm: SessionVM) -> RouteAdmission? {
        guard vm.sensitive, let route = chatRoute(vm) else { return nil }
        return SensitivityPolicy.admission(for: route, shieldOn: shieldOn)
    }

    /// Why the chat can't send right now (a Sensitive chat on a model it may not use), else nil.
    @MainActor
    public func sensitivityRefusal(for vm: SessionVM) -> String? {
        guard vm.sensitive, let route = chatRoute(vm) else { return nil }
        return SensitivityPolicy.refusalMessage(for: route, shieldOn: shieldOn)
    }

    /// Whether a Sensitive chat may switch to `route` (true for every route when the chat isn't Sensitive).
    @MainActor
    public func sensitivityAllows(_ route: ProviderProfile, in vm: SessionVM?) -> Bool {
        guard let vm, vm.sensitive else { return true }
        return SensitivityPolicy.admission(for: route, shieldOn: shieldOn).isAllowed
    }

    /// The chat header's line for a Sensitive chat (nil when it isn't).
    @MainActor
    public func sensitivityHeader(for vm: SessionVM) -> String? {
        guard vm.sensitive else { return nil }
        return SensitivityPolicy.headerLine(for: chatRoute(vm), shieldOn: shieldOn)
    }

    /// The client for a request that sends a chat's conversation somewhere other than a turn — `/compact`, the
    /// automatic summary, a skill written from the chat. It goes only where the chat's turns may go: a Sensitive chat
    /// on a model it may not use gets the same refusal a turn gets, and nothing is sent. `vm` nil = no chat's words go.
    @MainActor
    func conversationClient(for vm: SessionVM?, profile: ProviderProfile) throws -> any ProviderClient {
        if let vm, vm.sensitive,
           let why = sensitivityRefusal(for: vm) ?? SensitivityPolicy.refusalMessage(for: profile, shieldOn: shieldOn) {
            throw SensitivityRefusal(why)
        }
        return ProviderClients.make(profile)
    }

    /// Subagents of a Sensitive chat stay on private servers while the shield is off.
    @MainActor
    func privateSubagentsOnly(_ vm: SessionVM) -> Bool {
        vm.sensitive && SensitivityPolicy.subagentsPrivateOnly(shieldOn: shieldOn)
    }

    /// Pictures (attached, or captured by the screen tools) aren't sent from a Sensitive chat to a model that only
    /// gets it masked: the shield can't check what is in a picture.
    @MainActor
    func sensitiveWithholdsPictures(_ vm: SessionVM?, route: ProviderProfile?) -> Bool {
        guard let vm, vm.sensitive, let route else { return false }
        return SensitivityPolicy.admission(for: route, shieldOn: shieldOn) == .masked
    }

    /// `/sensitive [on|off]`.
    @MainActor
    func sensitiveCommand(_ arg: String?, vm: SessionVM) {
        switch arg?.lowercased() {
        case "on", "yes", "true":
            if vm.sensitive { vm.note("This chat is already Sensitive. " + (sensitivityHeader(for: vm) ?? "")) }
            setSensitive(true, for: vm)
        case "off", "no", "false":
            if !vm.sensitive { vm.note("This chat isn't Sensitive.") }
            setSensitive(false, for: vm)
        case nil:
            if vm.sensitive {
                vm.note((sensitivityHeader(for: vm) ?? "Sensitive.") + "\n\n" + SensitivityPolicy.explanation
                        + "\n\nTurn it off with `/sensitive off`.")
            } else {
                vm.note("This chat isn't Sensitive: every model may be used, with what the shield detects masked for "
                        + "models that aren't private. `/sensitive on` limits it to private models (or masked ones).")
            }
        default:
            vm.note("Use `/sensitive`, `/sensitive on` or `/sensitive off`.", role: .error)
        }
    }

    /// What the system prompt adds for a Sensitive chat.
    static let sensitivePrompt = """
    --- Sensitive chat ---
    The user marked this chat Sensitive: treat what you read here as confidential. Don't put it into web addresses \
    (web_fetch), queue tasks, skills or anything that leaves this chat unless the user asks; give subagents only what \
    their task needs.
    """
}
