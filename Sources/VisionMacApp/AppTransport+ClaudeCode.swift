import Foundation
import VisionHarnessCore

// MARK: - A chat turn on Claude Code
//
// A chat whose model is a Claude Code route runs each turn as `claude -p` in the chat's folder (see
// `ClaudeCodeTurn`), resuming the chat's own Claude Code session. Everything around the turn is Vision's as for any
// model — the run phases, the ETA cache, the Prompts timeline, `/goal` (one `claude -p` per round), the task queue,
// Stop — because this replaces only the engine run inside `turn()`: the same events come back (`EngineEvent`) and
// the same `RunResult` goes out. Messages the session hasn't seen (earlier turns on another model) go along as a
// recap, so a chat can move between Claude Code and any other model and keep its conversation.

extension AppTransport {
    /// One user message → one Claude Code run. Called by `turn()` after the user's message is in the timeline.
    func claudeCodeTurn(_ vm: SessionVM, profile: ProviderProfile, modelText: String, attachments: [MessageAttachment],
                        userEntryID: String) async throws -> RunResult {
        let sessionID = vm.id
        // A Sensitive chat never runs on an engine that reads files itself: the shield can't anonymise them.
        if isSensitiveChat(vm) {
            markUndelivered(vm, entryID: userEntryID)
            throw ClaudeCodeError.sensitiveChat
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
        let workspace = vm.workspaceURL ?? scratchFolder(for: vm, create: true)
        let input = transcripts[sessionID] ?? []
        let thinking = vm.thinking ?? profile.thinking
        let rules = ModelRequestRules.for(profile, model: profile.model)
        let environment = ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment)

        var link = vm.claudeCode
        var attempt = 0
        while true {
            attempt += 1
            let choice = ClaudeCodeLink.choice(for: link)
            if case .new(let id) = choice { link = ClaudeCodeLink(sessionID: id, lastTotalCostUSD: nil) }
            // A new session knows nothing of this chat: it gets the whole conversation so far. A resumed one gets
            // what happened since it last spoke (turns on other models).
            let since: Date? = {
                if case .resume = choice { return vm.claudeCode?.syncedAt ?? .distantFuture }
                return nil
            }()
            var prompt = ClaudeCodeRecap.preface(Self.claudeCodeRecapItems(vm.entries, since: since, excluding: userEntryID)) ?? ""
            var images: [ClaudeCodeImage] = []
            var addDirs: [String] = []
            if !attachments.isEmpty {
                let folder = claudeCodeAttachmentFolder(for: vm)
                let prepared = ClaudeCodeInput.prepare(attachments, folder: folder)
                if !prepared.text.isEmpty { prompt += prepared.text + "\n\n" }
                images = prepared.images
                if prepared.saved, !folder.path.hasPrefix(workspace.path + "/") { addDirs.append(folder.path) }
            }
            prompt += modelText
            let invocation = ClaudeCodeInvocation(model: profile.model, effort: thinking.flatMap { rules.effortWord($0) },
                                                  preset: vm.preset, session: choice,
                                                  appendSystemPrompt: ClaudeCodeTurn.visionNote, addDirs: addDirs)

            // Events are applied on the main actor, in order, and all of them before the turn is wrapped up.
            let (events, sink) = AsyncStream<ClaudeCodeEvent>.makeStream()
            let consumer = Task { @MainActor [weak self] in
                for await event in events { self?.applyClaudeCode(event, sessionID: sessionID) }
            }
            let outcome: ClaudeCodeTurnOutcome
            do {
                outcome = try await ClaudeCodeTurn.run(install: install, invocation: invocation, prompt: prompt,
                                                       images: images, workspace: workspace, environment: environment,
                                                       launcher: claudeCode.launcher) { sink.yield($0) }
            } catch {
                sink.finish()
                await consumer.value
                markUndelivered(vm, entryID: userEntryID)
                vm.endStreaming()
                throw error
            }
            sink.finish()
            await consumer.value

            // A session Claude Code doesn't have (its files were removed) or already has: once, start over or resume.
            if attempt == 1, !outcome.reachedModel, let failure = outcome.failure {
                if failure == .sessionNotFound {
                    let text = "Claude Code no longer has this chat's conversation — started a new one, with this chat so far as context."
                    vm.note(text)
                    log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
                    link = nil
                    vm.claudeCode = nil
                    continue
                }
                if failure == .sessionInUse {
                    link = ClaudeCodeLink(sessionID: choice.id, started: true, syncedAt: vm.claudeCode?.syncedAt)
                    continue
                }
            }
            return try finishClaudeCodeTurn(vm, outcome: outcome, link: link ?? ClaudeCodeLink(sessionID: outcome.sessionID),
                                            resumed: { if case .resume = choice { return true } else { return false } }(),
                                            version: install.version, input: input, modelText: modelText, userEntryID: userEntryID)
        }
    }

    /// Remember the session, keep the transcript in step, show what the turn used — then hand back the turn's result,
    /// or its failure, or the Stop.
    private func finishClaudeCodeTurn(_ vm: SessionVM, outcome: ClaudeCodeTurnOutcome, link: ClaudeCodeLink, resumed: Bool,
                                      version: String?, input: [LLMMessage], modelText: String,
                                      userEntryID: String) throws -> RunResult {
        let sessionID = vm.id
        vm.retry = nil
        var updated = link
        if !outcome.sessionID.isEmpty { updated.sessionID = outcome.sessionID }
        let cost = ClaudeCodeTurn.turnCost(total: outcome.result?.totalCostUSD, previousTotal: link.lastTotalCostUSD,
                                           resumed: resumed, version: version)
        if outcome.reachedModel {
            updated.started = true
            updated.syncedAt = Date()
            if let total = outcome.result?.totalCostUSD { updated.lastTotalCostUSD = total }
        }
        vm.claudeCode = updated
        log.setClaudeCode(id: sessionID, link: updated)

        guard outcome.reachedModel else {
            // Claude never saw the message (not signed in, a refused session): say so, and keep it out of the
            // conversation every model is given.
            markUndelivered(vm, entryID: userEntryID)
            vm.endStreaming()
            if outcome.failure == .notSignedIn { claudeCode.invalidate() }
            if let failure = outcome.failure { throw failure }
            if outcome.interrupted { throw CancellationError() }
            throw ClaudeCodeError.failed("Claude Code finished without answering.")
        }

        // The conversation every other model is given: the message and Claude Code's reply (its tool work stays in
        // Claude Code's session and in the timeline).
        transcripts[sessionID] = input + [.user(modelText),
                                          .assistant(ClaudeCodeTurn.transcriptReply(outcome.lastReplyText, toolLog: outcome.toolLog))]
        vm.endStreaming()

        if let result = outcome.result {
            vm.lastUsage = result.usage
            if let usage = result.usage {
                vm.turnPromptTokens += usage.promptTokens
                vm.turnCompletionTokens += usage.completionTokens
            }
            vm.lastCostUSD = cost
            let line = ClaudeCodeTurn.usageLine(model: outcome.model ?? ClaudeCodeModels.name(vm.claudeCodeModelHint ?? ""),
                                                result: result, cost: cost, apiKeySource: outcome.apiKeySource)
            vm.note(line)
            log.recordItem(sessionID, kind: "notice", text: line, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        if let note = ClaudeCodeTurn.denialNote(outcome.denials, preset: vm.preset) {
            vm.note(note)
            log.recordItem(sessionID, kind: "notice", text: note, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
        vm.contextUsed = outcome.contextTokens ?? vm.contextUsed
        if outcome.interrupted { throw CancellationError() }
        if let failure = outcome.failure { throw failure }
        return RunResult(messages: transcripts[sessionID] ?? input, usage: outcome.result?.usage,
                         deniedCount: outcome.denials.count, finalText: outcome.result?.text ?? outcome.lastReplyText,
                         lastPromptTokens: outcome.contextTokens, hitIterationLimit: outcome.hitTurnLimit,
                         lastReplyText: outcome.lastReplyText)
    }

    /// `/compact` in a Claude Code chat: Claude Code's own /compact on the chat's session (it keeps the conversation).
    func claudeCodeCompact(_ vm: SessionVM, profile: ProviderProfile, focus: String?) async {
        let sessionID = vm.id
        guard let link = vm.claudeCode, link.started else {
            vm.note("Nothing to compact yet.")
            return
        }
        let (found, status) = await claudeCode.usableInstall()
        guard let install = found else {
            vm.note(ClaudeCodeHost.notReadyMessage(status), role: .error)
            return
        }
        vm.activity = "Claude Code is compacting its conversation…"
        let workspace = vm.workspaceURL ?? scratchFolder(for: vm, create: true)
        let focusText = focus.map { " " + $0 } ?? ""
        let invocation = ClaudeCodeInvocation(model: profile.model, preset: vm.preset, session: .resume(link.sessionID),
                                              appendSystemPrompt: ClaudeCodeTurn.visionNote)
        let (events, sink) = AsyncStream<ClaudeCodeEvent>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            var noted = false
            for await event in events {
                // Only its notes ("Claude Code compacted its conversation …"); the command prints no reply worth a bubble.
                if case .notice = event {
                    noted = true
                    self?.applyClaudeCode(event, sessionID: sessionID)
                }
            }
            return noted
        }
        let outcome = try? await ClaudeCodeTurn.run(
            install: install, invocation: invocation, prompt: "/compact" + focusText, workspace: workspace,
            environment: ClaudeCodeEnvironment.environment(for: install.path, base: ProcessInfo.processInfo.environment),
            launcher: claudeCode.launcher) { sink.yield($0) }
        sink.finish()
        let noted = await consumer.value
        if let failure = outcome?.failure {
            vm.note("Compaction failed: \(failure.errorDescription ?? "Claude Code reported an error.")", role: .error)
            return
        }
        if var updated = vm.claudeCode, let total = outcome?.result?.totalCostUSD {
            updated.lastTotalCostUSD = total
            vm.claudeCode = updated
            log.setClaudeCode(id: sessionID, link: updated)
        }
        if !noted, outcome?.interrupted == false {
            let text = "Claude Code compacted its conversation."
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
    }

    /// One event of a Claude Code turn, on the main actor.
    func applyClaudeCode(_ event: ClaudeCodeEvent, sessionID: String) {
        switch event {
        case .engine(let engineEvent):
            apply(engineEvent, sessionID: sessionID)
        case .notice(let text):
            guard let vm = sessions.first(where: { $0.id == sessionID }) else { return }
            vm.note(text)
            log.recordItem(sessionID, kind: "notice", text: text, toolName: nil, argSummary: nil, output: nil, isError: false)
        }
    }

    /// Where a Claude Code turn's attachments are saved for Claude to read (under the chat's attachment folder).
    func claudeCodeAttachmentFolder(for vm: SessionVM) -> URL {
        skillLocations.appSupport.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(vm.id, isDirectory: true)
            .appendingPathComponent("claude-code", isDirectory: true)
            .appendingPathComponent(String(Int(Date().timeIntervalSince1970 * 1000)), isDirectory: true)
    }

    /// The chat's messages a Claude Code session hasn't seen: after `since` (nil = all), without the new message.
    /// What the person and the assistants said, tool work as one line each, a folded summary as what it says.
    nonisolated static func claudeCodeRecapItems(_ entries: [ChatEntry], since: Date?, excluding entryID: String) -> [ClaudeCodeRecapItem] {
        var items: [ClaudeCodeRecapItem] = []
        for entry in entries where entry.id != entryID {
            if let since, entry.at <= since { continue }
            switch entry.kind {
            case .message(let body):
                switch body.role {
                case .user: items.append(ClaudeCodeRecapItem(role: .person, text: body.text))
                case .assistant: items.append(ClaudeCodeRecapItem(role: .assistant, text: body.text))
                case .notice, .error: break
                }
            case .tool(let tool):
                let line = "\(Theme.toolLabel(tool.name)) \(tool.preview)".trimmingCharacters(in: .whitespaces)
                    + (tool.summary.map { " — \($0)" } ?? "")
                items.append(ClaudeCodeRecapItem(role: .tool, text: line))
            case .compaction(let note):
                items.append(ClaudeCodeRecapItem(role: .assistant, text: "Summary of the conversation before this point: \(note.summary)"))
            case .todos:
                break
            }
        }
        return items
    }
}

extension SessionVM {
    /// The Claude Code model this chat's route names (for the usage line when the CLI didn't say).
    var claudeCodeModelHint: String? { routeID?.split(separator: "|").last.map(String.init) }
}
