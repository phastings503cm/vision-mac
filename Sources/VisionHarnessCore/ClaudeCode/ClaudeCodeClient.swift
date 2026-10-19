import Foundation

// MARK: - Claude Code as a plain client, for side tasks
//
// A chat on Claude Code runs its turns through `ClaudeCodeTurn` (Claude Code's own agent, tools and session). The
// few places where Vision asks a chat's model for a one-off piece of text — a summary when the conversation is
// folded, a skill drafted from the chat — get this client: one `claude -p` with Claude Code's system prompt
// replaced by Vision's, no tools and no saved session, streaming the reply back as text.

public struct ClaudeCodeClient: ProviderClient {
    public let profile: ProviderProfile

    /// Where the client finds the CLI (the app sets its cached check); nil = look on this Mac each time.
    nonisolated(unsafe) public static var installLookup: (@Sendable () async -> ClaudeCodeInstall?)?
    /// How it starts the CLI (tests replace it).
    nonisolated(unsafe) public static var launcher: any ClaudeCodeLauncher = ProcessClaudeCodeLauncher()

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    public func listModels() async throws -> [String] {
        guard await Self.install() != nil else {
            throw LLMError.connection("Claude Code isn't installed on this Mac (or Vision can't find the claude command).")
        }
        return ClaudeCodeModels.choices.map(\.alias)
    }

    /// No request: the window is Claude Code's (200K, or 1M for a "[1m]" model).
    public func modelInfo(_ model: String?) async -> ModelInfo? {
        let id = model ?? profile.model
        return ModelInfo(id: id, contextWindow: ClaudeCodeModels.contextWindow(id), servedModels: [id])
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let profile = self.profile
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let install = await Self.install(), install.canRunHeadless else {
                        throw LLMError.connection("Claude Code isn't installed on this Mac (or Vision can't find the claude command).")
                    }
                    let model = request.model.isEmpty ? profile.model : request.model
                    let invocation = ClaudeCodeInvocation(
                        model: model,
                        effort: request.thinking.flatMap { ModelRequestRules.for(profile, model: model).effortWord($0) },
                        oneShotSystemPrompt: request.systemPrompt.isEmpty ? "You are a helpful assistant." : request.systemPrompt)
                    let workspace = FileManager.default.temporaryDirectory
                    let outcome = try await ClaudeCodeTurn.run(
                        install: install, invocation: invocation, message: ClaudeCodeInput.line(text: Self.prompt(request.messages)),
                        workspace: workspace,
                        environment: ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment),
                        launcher: Self.launcher,
                        // No tools, so nothing should ask; anything that does is refused.
                        decide: { _ in .deny(ClaudeCodePermissions.declined) }) { event in
                        switch event {
                        case .engine(.textDelta(let text)): continuation.yield(.text(text))
                        case .engine(.reasoningDelta(let text)): continuation.yield(.reasoning(text))
                        default: break
                        }
                    }
                    if outcome.interrupted { throw CancellationError() }
                    if let failure = outcome.failure { throw failure }
                    continuation.yield(.done(calls: [], finish: "stop", usage: outcome.result?.usage))
                    continuation.finish()
                } catch let error as ClaudeCodeError {
                    let permanent = error.isPermanent
                    continuation.finish(throwing: LLMError.rejected(status: error == .notSignedIn ? 401 : 500,
                                                                    message: error.errorDescription ?? "Claude Code failed.",
                                                                    body: "", permanent: permanent))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func install() async -> ClaudeCodeInstall? {
        if let lookup = installLookup { return await lookup() }
        return await ClaudeCodeDetector.check().install
    }

    /// The request's messages as one prompt: a single message as it is, a conversation as labelled turns.
    static func prompt(_ messages: [LLMMessage]) -> String {
        let spoken = messages.filter { $0.role != .system && !($0.content ?? "").isEmpty }
        if spoken.count == 1, spoken[0].role == .user { return spoken[0].content ?? "" }
        let lines = spoken.map { message -> String in
            let label: String
            switch message.role {
            case .user: label = "Person"
            case .assistant: label = "Assistant"
            case .tool: label = "Tool result" + (message.name.map { " (\($0))" } ?? "")
            case .system: label = "System"
            }
            return "\(label): \(message.content ?? "")"
        }
        return lines.joined(separator: "\n\n") + "\n\n(Reply to the last Person message.)"
    }
}
