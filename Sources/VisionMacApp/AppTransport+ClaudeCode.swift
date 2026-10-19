import Foundation
import VisionHarnessCore

// MARK: - Chats on Claude Code (your Claude subscription)
//
// A chat whose route is a Claude Code route hands each turn to the official claude CLI in headless mode instead of
// Vision's own engine: one `claude -p` per turn (per /goal round, per task), stream-json in and out, in the chat's
// folder, carrying on the same Claude Code session with --resume. Its events become the chat's rows through the same
// `apply` as every engine event, so run phases, the ETA, the Prompts timeline, /goal and the task queue all work on it
// unchanged; Claude Code's permission questions are answered with the chat's preset (asking the person on the same card
// Vision's own engine uses); Stop interrupts the turn. The CLI does all the talking with the person's own sign-in —
// Vision never reads it. Vision for Windows does the same (AgentHost.ClaudeCode.cs).

extension AppTransport {
    /// One turn on Claude Code. The user's row is already in the chat; this runs `claude -p` and returns what the goal
    /// loop and the queue read (the reply, the usage).
    func claudeCodeTurn(_ vm: SessionVM, profile: ProviderProfile, modelText: String, attachments: [MessageAttachment],
                        userEntryID: String) async throws -> RunResult {
        let sessionID = vm.id
        // A Sensitive chat never runs on an engine that reads files itself: the shield can't mask what it reads.
        if isSensitiveChat(vm) {
            markUndelivered(vm, entryID: userEntryID)
            throw ClaudeCodeError.sensitiveChat
        }
        let workspace = vm.workspaceURL ?? scratchFolder(for: vm, create: true)
        // A chat that was on one of Vision's own models this launch says it moved.
        if dropEngine(sessionID), claudeCode.announced.insert(sessionID).inserted {
            let text = "This chat now uses \(Self.routeLabel(profile)) — \(ClaudeCodeModels.name(profile.model)), on your Claude plan through the claude app on this computer."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        let (found, status) = await claudeCode.usableInstall()
        guard let install = found else {
            markUndelivered(vm, entryID: userEntryID)
            throw ClaudeCodeError.notInstalled(ClaudeCodeHost.notReadyMessage(status))
        }
        // Stopped while Vision was still looking for the CLI: nothing was sent.
        if Task.isCancelled {
            markUndelivered(vm, entryID: userEntryID)
            throw CancellationError()
        }

        // Attachments: pictures and PDFs go as themselves; a long file goes in parts, and Claude Code reads the rest of it
        // from where Vision saved it (it has no read_attachment tool).
        var addDirs: [String] = []
        var notes: [String] = []
        var parts: [AttachmentWirePart] = []
        if !attachments.isEmpty {
            let prepared = await prepareAttachments(attachments, vm: vm, entryID: userEntryID, profile: profile,
                                                    window: contextLimit(for: vm))
            let store = attachmentStore(for: sessionID)
            for attachment in prepared where (attachment.parts ?? 1) > 1 {
                guard let entry = store.entries().last(where: { $0.name == attachment.name }) else { continue }
                notes.append("(The full text of \(attachment.name) is saved at \(store.directory.appendingPathComponent(entry.file).path) — read the rest of it there with your Read tool; there is no read_attachment tool.)")
                if !addDirs.contains(store.directory.path) { addDirs.append(store.directory.path) }
            }
            parts = AttachmentWire.parts(for: prepared, route: ClaudeCodeInput.attachmentRoute)
        }

        // The Claude Code session this chat carries on — or a new one, which first hears what the chat said before it.
        let stored = log.claudeSession(sessionID)
        var session = stored.session
        var lastCost = stored.cost
        var message = modelText
        if vm.goal != nil { message += "\n\n" + ClaudeCodeTurn.goalNote }
        if !notes.isEmpty { message += "\n\n" + notes.joined(separator: "\n") }
        let body = message
        /// The chat before the new message (all of it, or only after `since`), as a recap in front of `text`.
        func seeded(_ text: String, since: Date?) -> String {
            var before = Array(vm.entries.prefix { $0.id != userEntryID })
            if let since { before = before.filter { $0.at > since } }
            return ClaudeCodeRecap.build(Self.replayMessages(before)).map { $0 + "\n\n" + text } ?? text
        }
        var choice: ClaudeCodeSessionChoice
        if let session {
            choice = .resume(session)
            // Turns on other models since it last spoke go along first (none when nothing happened in between).
            message = seeded(body, since: stored.syncedAt ?? .distantPast)
        } else {
            choice = .new(UUID().uuidString.lowercased())
            message = seeded(body, since: nil)
        }
        let policy = PermissionPolicy(preset: vm.preset, workspaceRoot: workspace)
        let environment = ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment)
        let rules = ModelRequestRules.for(profile, model: profile.model)
        let effort = (vm.thinking ?? profile.thinking).flatMap { rules.effortWord($0) }
        let decide: @Sendable (ClaudeCodePermissionRequest) async -> ClaudeCodePermissionDecision = { [weak self] request in
            let decision = ClaudeCodePermissions.decide(request, policy: policy)
            guard case .ask(let name, let detail) = decision else { return decision }
            let allowed = await self?.askGate(sessionID: sessionID, gateID: request.toolUseID ?? request.requestID,
                                              name: name, detail: detail) ?? false
            return allowed ? .allow : .deny(ClaudeCodePermissions.declined)
        }

        var outcome: ClaudeCodeTurnOutcome
        var attempts = 0
        while true {
            attempts += 1
            let invocation = ClaudeCodeInvocation(model: profile.model, effort: effort, preset: vm.preset, session: choice,
                                                  appendSystemPrompt: ClaudeCodeTurn.systemNote, addDirs: addDirs)
            // Events are applied on the main actor, in order, and all of them before the turn is wrapped up.
            let (events, sink) = AsyncStream<ClaudeCodeEvent>.makeStream()
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.applyClaudeCode(event, sessionID: sessionID) }
            }
            do {
                outcome = try await ClaudeCodeTurn.run(install: install, invocation: invocation,
                                                       message: ClaudeCodeInput.line(text: message, parts: parts),
                                                       workspace: workspace, environment: environment,
                                                       launcher: claudeCode.launcher, decide: decide) { sink.yield($0) }
            } catch {
                sink.finish()
                await consumer.value
                markUndelivered(vm, entryID: userEntryID)
                vm.endStreaming()
                throw error
            }
            sink.finish()
            await consumer.value
            // Whatever happened, the session it opened is the one to carry on (a lost one is replaced on the next turn).
            if let opened = outcome.sessionID {
                log.setClaudeSession(id: sessionID, session: opened,
                                     cost: outcome.result?.totalCostUSD ?? (opened == session ? lastCost : nil),
                                     syncedAt: outcome.progressed ? Date() : nil)
            }
            guard let failure = outcome.failure, !outcome.progressed, attempts < 4,
                  failure == .sessionNotFound || failure == .sessionInUse else { break }
            let text = "Claude Code no longer had this chat's session, so a new one starts here, with a recap of the chat so far."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
            session = nil
            lastCost = nil
            choice = .new(UUID().uuidString.lowercased())
            message = seeded(body, since: nil)
        }
        // Switching this chat to another model later: it rebuilds its transcript from the rows, Claude Code's turns included.
        transcripts[sessionID] = nil
        vm.retry = nil
        vm.endStreaming()

        if let resolved = outcome.model { turnRoute[sessionID] = RouteUse(model: resolved, route: Self.routeLabel(profile)) }
        if let source = outcome.apiKeySource, source != "none", claudeCode.keyNoted.insert(sessionID).inserted {
            let text = source == "ANTHROPIC_API_KEY"
                ? "Claude Code is using the ANTHROPIC_API_KEY set on this computer — what it does is billed to that key, not your Claude plan."
                : "Claude Code is signed in with an API key (\(source)) — billed to that key, not your Claude plan."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        if let window = outcome.result?.contextWindow {
            ClaudeCodeModels.learnWindow(profile.model, window)
            learnContextWindow(routeID: profile.routeID, window)
        }
        if outcome.interrupted {
            if !outcome.progressed { markUndelivered(vm, entryID: userEntryID) }
            throw CancellationError()
        }
        if let failure = outcome.failure {
            if !outcome.progressed { markUndelivered(vm, entryID: userEntryID) }
            if failure == .notSignedIn { claudeCode.invalidate() }
            throw failure
        }

        let usage = outcome.usage ?? outcome.result?.usage
        vm.lastUsage = usage
        if let usage {
            vm.turnPromptTokens += usage.promptTokens
            vm.turnCompletionTokens += usage.completionTokens
        }
        if let filled = outcome.contextTokens { vm.contextUsed = filled }
        let denied = outcome.result?.denials ?? 0
        if denied > 0 { vm.note("\(denied) tool call(s) were denied.") }
        if let result = outcome.result, result.localCommand == nil,
           let line = ClaudeCodeTurn.usageLine(result: result, usage: usage, previousTotal: lastCost, apiKeySource: outcome.apiKeySource) {
            vm.lastCostUSD = result.totalCostUSD.map { ClaudeCodeTurn.turnCost(total: $0, previousTotal: lastCost) }
            vm.note(line)
            log.recordItem(sessionID, kind: "notice", text: line, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        return RunResult(messages: [], usage: usage, deniedCount: denied, finalText: outcome.lastReplyText,
                         lastPromptTokens: outcome.contextTokens, lastReplyText: outcome.lastReplyText)
    }

    /// `/compact` on a Claude Code chat: Claude Code compacts its own session.
    func claudeCodeCompact(_ vm: SessionVM, profile: ProviderProfile, focus: String?) async {
        let sessionID = vm.id
        guard let session = log.claudeSession(sessionID).session else {
            vm.note("Nothing to compact yet — this chat hasn't talked to Claude Code.")
            return
        }
        let (found, status) = await claudeCode.usableInstall()
        guard let install = found else {
            vm.note(ClaudeCodeHost.notReadyMessage(status), role: .error)
            return
        }
        let workspace = vm.workspaceURL ?? scratchFolder(for: vm, create: true)
        let command = "/compact" + ((focus ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "" : " " + focus!.trimmingCharacters(in: .whitespaces))
        let (events, sink) = AsyncStream<ClaudeCodeEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            // Only its notes ("Claude Code compacted the conversation …") and the working line: the command prints no reply.
            for await event in events {
                switch event {
                case .notice, .activity: self?.applyClaudeCode(event, sessionID: sessionID)
                default: break
                }
            }
        }
        let outcome = try? await ClaudeCodeTurn.run(
            install: install, invocation: ClaudeCodeInvocation(model: profile.model, preset: vm.preset, session: .resume(session)),
            message: ClaudeCodeInput.line(text: command), workspace: workspace,
            environment: ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment),
            launcher: claudeCode.launcher, decide: { _ in .deny(ClaudeCodePermissions.declined) }) { sink.yield($0) }
        sink.finish()
        await consumer.value
        if let failure = outcome?.failure {
            vm.note(failure.errorDescription ?? "Claude Code ended the turn with an error.", role: .error)
            return
        }
        if let id = outcome?.sessionID {
            log.setClaudeSession(id: sessionID, session: id, cost: outcome?.result?.totalCostUSD ?? log.claudeSession(sessionID).cost)
        }
    }

    /// One event of a Claude Code turn, on the main actor.
    func applyClaudeCode(_ event: ClaudeCodeEvent, sessionID: String) {
        guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
        switch event {
        case .engine(let engineEvent):
            apply(engineEvent, sessionID: sessionID)
        case .notice(let text):
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        case .activity(let text):
            if vm.running { vm.activity = text }
        case .permission, .unhandledControl:
            break // answered by ClaudeCodeTurn
        }
    }
}
