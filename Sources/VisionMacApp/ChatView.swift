import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VisionHarnessCore

/// The conversation: transcript, permission prompts, and the composer.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    @State private var draft = ""
    /// Grows with the draft, between one line and a sensible ceiling.
    @State private var composerHeight: CGFloat = 32
    /// Attachments queued to go out with the next message (read in the background as they are added).
    @State private var staged: [StagedAttachment] = []
    /// The attachment whose content is open in the preview sheet.
    @State private var previewing: StagedAttachment?
    /// Skills offered in the "/" autocomplete, loaded when the user starts typing a command.
    @State private var slashSkills: [Skill] = []
    @State private var slashSkillsRevision = -1

    private var transport: AppTransport { model.transport }

    private var sparkConfirmShown: Binding<Bool> {
        Binding(get: { model.spark.confirmTarget != nil },
                set: { if !$0 { model.spark.confirmTarget = nil } })
    }
    private var sparkConfirmTitle: String {
        guard let t = model.spark.confirmTarget else { return "" }
        return "Switch \(t.box.name) to \(t.model.title)?"
    }
    private var sparkConfirmMessage: String {
        guard let t = model.spark.confirmTarget else { return "" }
        let current = t.box.status?.activeModel?.title
        return (current.map { "\($0) stops, then " } ?? "")
            + "\(t.model.title) loads (\(t.duration), \(t.model.window.formatted())-token context). Every chat using \(t.box.name) follows it automatically (and OpenClaw, if the box runs it); "
            + "if it fails to load, the previous model comes back."
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            gates
            composer
        }
        .background(.background)
        .onChange(of: draft) { _, text in
            guard text.hasPrefix("/"), slashSkillsRevision != transport.skillsRevision || slashSkills.isEmpty else { return }
            slashSkillsRevision = transport.skillsRevision
            slashSkills = transport.skills(for: session)
        }
        .alert(sparkConfirmTitle, isPresented: sparkConfirmShown) {
            Button("Switch") {
                if let target = model.spark.confirmTarget {
                    Task { await model.spark.swap(target.box, to: target.model.key) }
                }
                model.spark.confirmTarget = nil
            }
            Button("Cancel", role: .cancel) { model.spark.confirmTarget = nil }
        } message: {
            Text(sparkConfirmMessage)
        }
        .onChange(of: model.code.pendingMention) { _, mention in
            guard let mention else { return }
            insertMention(mention)
            model.code.pendingMention = nil
        }
        .onChange(of: model.pendingComposerText) { _, text in
            guard let text else { return }
            if PastedText.isLarge(text) {
                // A re-sent prompt as long as a big paste goes the same way: as an attachment (a `/goal` keeps its
                // command in the box, so it runs as a goal again).
                draft = ""
                pasteLarge(text)
            } else {
                draft = text
                composerHeight = min(max(ComposerField.minHeight, 90), ComposerField.maxHeight)
            }
            model.pendingComposerText = nil
        }
        .onChange(of: model.pendingComposerAttachments == nil) { _, none in
            guard !none, let pending = model.pendingComposerAttachments else { return }
            for attachment in pending { add(attachment) }
            model.pendingComposerAttachments = nil
        }
        // The chips say how each file goes to the chat's own model: a new model, a new answer (and a new window).
        .onChange(of: session.routeID) { _, _ in refreshParts() }
        // Each chat keeps its own draft and attachments: the composer is shared by the window, its contents are not.
        .onChange(of: session.id) { old, new in
            if draft.isEmpty, staged.isEmpty {
                model.composerDrafts[old] = nil
            } else {
                model.composerDrafts[old] = ComposerDraft(text: draft, staged: staged)
            }
            let next = model.composerDrafts.removeValue(forKey: new)
            previewing = nil
            draft = next?.text ?? ""
            staged = next?.staged ?? []
            composerHeight = ComposerField.minHeight
            refreshParts()
        }
        .onChange(of: model.pendingAttachmentPreview) { _, name in
            guard let name else { return }
            previewing = staged.first { $0.attachment.name == name }
            model.pendingAttachmentPreview = nil
        }
        .sheet(item: $previewing) { item in
            AttachmentPreviewSheet(
                item: item, route: transport.attachmentRoute(for: transport.chatRoute(session)),
                onSave: item.isPasted ? { text in replacePasted(item.id, with: text) } : nil,
                onRemove: { staged.removeAll { $0.id == item.id }; refreshParts() })
        }
    }

    // MARK: - Transcript

    /// The transcript draws a window of rows (`TranscriptPager`): the newest page, with earlier pages loaded as
    /// the person scrolls up. The window bounds the rows, so the stack is eager — every drawn row is measured and
    /// scrolling to one lands exactly.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    TranscriptTopMarker()
                    if session.entries.isEmpty {
                        ChatStarterView(session: session) { text in
                            model.send(text, in: session)
                        }
                        .padding(.top, 40)
                    }
                    let pager = session.pager
                    let rows = pager.rows(of: session.entries)
                    if rows.hiddenBefore > 0 {
                        EarlierMessagesBar(hidden: rows.hiddenBefore, pageSize: pager.window.pageSize) {
                            pager.loadEarlier(session.entries)
                        }
                    }
                    ForEach(rows.entries) { entry in
                        EntryRow(entry: entry, session: session)
                            .modifier(TranscriptRowFrame(id: entry.id, watched: pager.isWatched(entry.id, in: rows),
                                                         highlighted: pager.highlightID == entry.id))
                    }
                    if rows.hiddenAfter > 0 {
                        NewerMessagesBar(hidden: rows.hiddenAfter, pageSize: pager.window.pageSize,
                                         action: { pager.loadLater(session.entries) },
                                         latest: { pager.showLatest() })
                    } else {
                        transcriptEnd
                    }
                    TranscriptBottomMarker(id: bottomAnchor)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 20)
                .frame(maxWidth: Theme.maxTranscriptWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .transcriptPaging(session: session, proxy: proxy, bottomAnchor: bottomAnchor)
            // "Jump" from the Prompts timeline, here or from another chat (which opens this one first).
            .onChange(of: model.promptJump) { _, jump in handleJump(jump) }
            .onChange(of: session.id) { _, _ in handleJump(model.promptJump) }
            .onAppear { handleJump(model.promptJump) }
        }
    }

    /// What follows the newest row: the turn's phase card, the way to Prompts, the thinking line, changed files.
    @ViewBuilder
    private var transcriptEnd: some View {
        // The live turn-phase card sits under the newest entry
        // while a turn runs; the finished one stays until the
        // next turn replaces it.
        if let phase = session.turnPhase {
            PhaseCard(state: phase)
                .padding(.leading, Theme.gutter)
                .id("phase-\(phase.turnID)")
        }
        if !session.running, session.promptHistory.count > 1 {
            PromptsLink(session: session)
                .padding(.leading, Theme.gutter)
        }
        if session.running, session.entries.last?.tool?.isFinished ?? true {
            ThinkingRow(session: session)
        }
        if !session.changedFiles.isEmpty {
            ProducedFilesRow(session: session)
        }
    }

    private let bottomAnchor = "transcript-bottom"

    /// "Jump" from the Prompts timeline: the transcript draws the page around the prompt's row, scrolls to it and
    /// flashes it (`TranscriptPager.jump(to:)`).
    private func handleJump(_ jump: PromptJump?) {
        guard let jump, jump.sessionID == session.id else { return }
        model.promptJump = nil
        guard let record = session.promptHistory.first(where: { $0.id == jump.recordID }) else { return }
        guard let entryID = transport.entryID(for: record, in: session) else {
            transport.broadcast("That prompt is no longer in the transcript — the conversation was compacted since. Its text and results are still in Prompts.")
            return
        }
        session.pager.jump(to: entryID)
    }

    // MARK: - Gates

    @ViewBuilder
    private var gates: some View {
        if let gate = session.pendingGates.last {
            GateCard(gate: gate, session: session)
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 10)
                .frame(maxWidth: Theme.maxTranscriptWidth)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            SparkSwapBanner()
            if let goal = session.goal {
                GoalBanner(goal: goal, session: session)
            }
            if !session.runningBackgroundJobs.isEmpty || !session.runningAgentRuns.isEmpty {
                SubagentsBar(session: session)
            }
            if !slashMatches.isEmpty {
                SlashHints(matches: slashMatches) { usage in
                    let word = usage.split(separator: " ").first.map(String.init) ?? usage
                    draft = word + " "
                }
            }
            if let tool = session.runningTool {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(Theme.toolLabel(tool.name).lowercased()) \(tool.preview)")
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }

            if !staged.isEmpty {
                AttachmentChips(items: $staged, route: transport.attachmentRoute(for: transport.chatRoute(session))) { previewing = $0 }
                    .onChange(of: staged.count) { _, _ in refreshParts() }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Attach Image…") { attachImage() }
                    Button("Attach File…") { attachFile() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                // Open while the agent works too: what is attached then goes with the prompt onto the chat's tasks.
                .help(session.running ? "Attach an image or file — it goes with the prompt onto this chat's tasks"
                                      : "Attach an image or file")

                ComposerField(text: $draft, height: $composerHeight,
                              isEnabled: true, onSubmit: send, onAddToTasks: addToTasks,
                              onLargePaste: { pasteLarge($0) })
                    .frame(height: composerHeight)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )

                if session.running {
                    Button(action: addToTasks) {
                        Image(systemName: "text.badge.plus")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && staged.isEmpty)
                              || staged.contains(where: \.reading))
                    .help("Add to this chat's tasks (↩), with its attachments — it starts by itself when the current work finishes")
                    Button {
                        transport.stopSession(session.id)
                    } label: {
                        Image(systemName: session.stopping ? "hourglass" : "stop.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(session.stopping)
                    .help(session.stopping ? "Stopping…" : "Stop the agent (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && staged.isEmpty)
                              || staged.contains(where: \.reading))
                    .help(staged.contains(where: \.reading) ? "Reading the attachments…" : "Send (↩)")
                }
            }

            HStack(spacing: 10) {
                // The controls scroll rather than truncate when the window is narrow.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Label(session.preset.label, systemImage: session.preset.icon)
                            .foregroundStyle(session.preset == .fullAccess ? Theme.errorTint : .secondary)
                        ModelMenu(session: session)
                        ThinkingMenu(session: session)
                        SkillsButton(session: session)
                        if let name = session.projectName {
                            Label(name, systemImage: "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                // Narrow (code mode's chat pane): the last turn's usage gives way, and the gauge stays on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ContextGaugeView(session: session, draft: draft)
                        if let usage = session.lastUsage {
                            // A Claude Code chat also shows Claude Code's estimate of the last turn at API prices.
                            let cost = model.transport.chatRoute(session)?.kind == .claudeCode
                                ? session.lastCostUSD.map { " · " + ClaudeCodeTurn.costWords($0) } ?? "" : ""
                            Text("\(usage.promptTokens.formatted()) in · \(usage.completionTokens.formatted()) out" + cost)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .help(cost.isEmpty ? "The last turn's tokens"
                                      : "The last turn's tokens, and Claude Code's own estimate of its cost at API prices — your Claude plan covers it.")
                        }
                    }
                    .fixedSize()
                    ContextGaugeView(session: session, draft: draft)
                        .fixedSize()
                }
                .layoutPriority(1)
            }
            .font(Theme.metaFont)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: Theme.maxTranscriptWidth)
        .frame(maxWidth: .infinity)
        // Files dropped on the composer are attached like ones picked with +.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { stage(url, kind: .file) }
            return !files.isEmpty
        }
    }

    /// Commands and skills matching what's typed, while the draft is a bare "/word".
    private var slashMatches: [SlashCommand.Info] {
        let t = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("/"), !t.contains(" "), !t.contains("\n"), t.count < 24 else { return [] }
        let builtin = SlashCommand.catalog.filter { $0.usage.hasPrefix(t) }
        let disabled = model.config.disabledSkills
        let named = slashSkills
            .filter { $0.userInvocable && !$0.shadowed && !disabled.contains($0.id) && "/\($0.slug)".hasPrefix(t) }
            .prefix(8)
            .map { SlashCommand.Info(usage: "/\($0.slug)" + ($0.argumentHint.map { " \($0)" } ?? ""),
                                     summary: "\($0.kind == .skill ? "Skill" : $0.kind.label): \(String($0.description.prefix(70)))") }
        return builtin + named
    }

    private func send() {
        // While the agent works, ↩ queues the prompt as the chat's next task instead of refusing it.
        if session.running || model.transport.runTasks[session.id] != nil {
            addToTasks()
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty, !staged.contains(where: \.reading) else { return }
        // Only /goal takes attachments: a command with chips is refused here, and the box keeps both.
        if !staged.isEmpty, let why = AppTransport.commandAttachmentRefusal(text) {
            session.note(why, role: .error)
            return
        }
        let payload = staged.map(\.attachment)
        draft = ""
        staged = []
        model.send(text, in: session, attachments: payload)
    }

    /// Queue the draft as this chat's next task (⌘↩, or ↩ while the agent works): it runs after what is running and
    /// what is already queued, by itself.
    private func addToTasks() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty, !staged.contains(where: \.reading) else { return }
        if !staged.isEmpty, let why = AppTransport.commandAttachmentRefusal(text) {
            session.note(why, role: .error)
            return
        }
        // The files, pictures and large pastes in the box go with it (kept until the task is deleted).
        guard transport.addChatTask(text, sessionID: session.id, attachments: staged.map(\.attachment)) != nil else { return }
        staged = []
        draft = ""
        composerHeight = ComposerField.minHeight
    }

    /// A paste too large for the message box: a "Pasted text" attachment. One that starts with `/goal` into an empty
    /// box leaves the command (and a short first line) in the box, so it still runs as a goal.
    private func pasteLarge(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let split = PastedText.splitGoal(text) {
            draft = split.command
            if !split.rest.isEmpty { addPasted(split.rest) }
        } else {
            addPasted(text)
        }
    }

    /// A paste too large for the message box becomes a "Pasted text" attachment.
    private func addPasted(_ text: String) {
        let names = staged.map(\.attachment.name) + session.entries.flatMap { $0.message?.attachments.map(\.name) ?? [] }
        add(PastedText.attachment(text, existing: names))
    }

    /// An edited paste: the same chip, new text (the paste stays an attachment even if it got short).
    private func replacePasted(_ id: UUID, with text: String) {
        guard let index = staged.firstIndex(where: { $0.id == id }) else { return }
        staged[index].attachment = AttachmentReader.pasted(text, name: staged[index].attachment.name)
        refreshParts()
    }

    /// Queue an attachment; one nobody read yet is read in the background (PDF text, OCR, Office XML) while its chip
    /// says "reading…".
    private func add(_ attachment: MessageAttachment) {
        // The same file twice is one attachment.
        guard !staged.contains(where: { $0.attachment.name == attachment.name && $0.attachment.data == attachment.data }) else { return }
        let item = StagedAttachment(attachment: attachment, reading: attachment.digest == nil)
        staged.append(item)
        guard item.reading else { refreshParts(); return }
        let id = item.id
        Task {
            let read = await Task.detached(priority: .userInitiated) { AttachmentReader.digested(attachment) }.value
            guard let index = staged.firstIndex(where: { $0.id == id }) else {
                // Its chat was switched away while it was read: finish it where that chat's draft waits.
                for (chatID, var saved) in model.composerDrafts {
                    guard let at = saved.staged.firstIndex(where: { $0.id == id }) else { continue }
                    saved.staged[at].attachment = read
                    saved.staged[at].reading = false
                    model.composerDrafts[chatID] = saved
                }
                return
            }
            staged[index].attachment = read
            staged[index].reading = false
            refreshParts()
        }
    }

    /// How many parts each staged file's text makes for the current route's window, shared among the readable
    /// files as the message will share it (`AttachmentBudget`).
    private func refreshParts() {
        let readable = staged.filter { !$0.reading && $0.attachment.kind == .file && ($0.attachment.digest?.readable ?? false) }.count
        let budget = AttachmentBudget(window: transport.contextLimit(for: session), sharing: max(1, readable))
        for index in staged.indices where !staged[index].reading {
            guard let digest = staged[index].attachment.digest else { continue }
            staged[index].parts = AttachmentPrep.partCount(digest, budget: budget)
        }
    }

    /// Pick an image from disk and stage it as an attachment.
    private func attachImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { stage(url, kind: .image) }
    }

    /// Pick a file (or folder) from disk and stage it as an attachment.
    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { stage(url, kind: .file) }
    }

    /// Read the file and queue it; a picture is re-encoded to a PNG any model server takes (and scaled down when
    /// it is huge), whichever menu item attached it.
    private func stage(_ url: URL, kind: MessageAttachment.Kind) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        if kind == .image || AttachmentReader.isImage(name: name, data: data) {
            add(MessageAttachment(kind: .image, name: name, data: ImageData.normalized(data) ?? data))
        } else {
            add(MessageAttachment(kind: kind, name: name, data: data))
        }
    }

    private func insertMention(_ path: String) {
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(path) "
    }
}

// MARK: - Composer field

/// Multi-line field where Return sends and Shift-Return inserts a newline.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var onSubmit: () -> Void
    /// ⌘↩: add the draft to the chat's tasks.
    var onAddToTasks: (() -> Void)?
    /// A paste (or drop) over `PastedText`'s thresholds goes here instead of into the field.
    var onLargePaste: ((String) -> Void)? = nil

    static let minHeight: CGFloat = 32
    /// The field grows to this and then scrolls inside itself, so the transcript above keeps its room.
    static let maxHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if textView.string != text { textView.string = text }
        textView.isEditable = isEnabled
        textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        context.coordinator.reportHeight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: NSTextView?

        init(_ parent: ComposerField) { self.parent = parent }

        /// A very large paste never lands in the field: it becomes an attachment chip.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacement = replacementString, let onLargePaste = parent.onLargePaste,
                  PastedText.isLarge(replacement) else { return true }
            onLargePaste(replacement)
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(textView)
        }

        /// An NSViewRepresentable has no intrinsic size in SwiftUI, so without
        /// this the field expands to swallow the whole pane.
        func reportHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let target: CGFloat
            if textView.string.utf16.count > 4_000 {
                // Long text is past the ceiling for sure: don't lay all of it out on every keystroke to find out.
                target = ComposerField.maxHeight
            } else {
                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container).height
                target = min(max(ComposerField.minHeight,
                                 (used + textView.textContainerInset.height * 2).rounded(.up)),
                             ComposerField.maxHeight)
            }
            guard abs(target - parent.height) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = target }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Shift-Return (and Option-Return) insert a line break instead.
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if flags.contains(.command), let add = parent.onAddToTasks {
                add()
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}

// MARK: - Rows

/// One transcript row, dispatched on its kind.
private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: ChatEntry
    let session: SessionVM

    var body: some View {
        switch entry.kind {
        case .message(let body):
            MessageRow(body: body, at: entry.at, masked: session.masked[entry.id],
                       streaming: session.streamingID == entry.id,
                       expanded: Binding(get: { session.pager.expanded.contains(entry.id) },
                                         set: { open in
                                             if open { session.pager.expanded.insert(entry.id) } else { session.pager.expanded.remove(entry.id) }
                                         }))
                .modifier(MessageCopyActions(entry: entry, pager: session.pager,
                                             copyText: { MessageCopy.text(for: entry, in: session, transport: model.transport) }))
        case .tool(let activity):
            if activity.name == UseSkillTool.name {
                SkillCard(activity: activity)
            } else {
                ToolCard(activity: activity, session: session)
            }
        case .todos(let items):
            // With the plan panel open the plan is there; the transcript keeps just a line.
            if model.config.planPanelOpen {
                CollapsedTodoCard(items: items)
            } else {
                TodoCard(items: items)
            }
        case .compaction(let note):
            CompactionCard(note: note)
        }
    }
}

private struct MessageRow: View {
    let body_: MessageBody
    let at: Date
    /// What the shield masked before this answer's request went out.
    let masked: ShieldReport?
    /// Still streaming in (a very long one shows its newest lines).
    var streaming = false
    /// A very long message the person opened ("Show more").
    @Binding var expanded: Bool

    init(body: MessageBody, at: Date, masked: ShieldReport? = nil, streaming: Bool = false,
         expanded: Binding<Bool> = .constant(false)) {
        self.body_ = body
        self.at = at
        self.masked = masked
        self.streaming = streaming
        self._expanded = expanded
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
            VStack(alignment: .leading, spacing: 4) {
                if body_.role == .user {
                    // One collapse for every long message (`TranscriptText`): its first lines and "Show more".
                    if !body_.text.isEmpty || body_.attachments.isEmpty {
                        TranscriptText(text: body_.text, markdown: false, streaming: streaming, expanded: $expanded)
                    }
                    if !body_.attachments.isEmpty {
                        AttachmentBadges(badges: body_.attachments)
                    }
                } else {
                    TranscriptText(text: body_.text, markdown: true, streaming: streaming, expanded: $expanded)
                }
                if let masked, let summary = masked.summary {
                    MaskedChip(summary: summary, categories: masked.categories)
                }
            }
            .padding(.vertical, body_.role == .user ? 8 : 0)
            .padding(.horizontal, body_.role == .user ? 12 : 0)
            .background(background)
            .foregroundStyle(foreground)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch body_.role {
        case .user:
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(Theme.userTint)
                .frame(width: 18)
                .padding(.top, 8)
        case .assistant:
            Image(systemName: "sparkle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
        case .notice:
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.noticeTint)
                .frame(width: 18)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorTint)
                .frame(width: 18)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch body_.role {
        case .user:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface)
        case .notice:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.noticeTint.opacity(0.10))
        case .error:
            RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.errorTint.opacity(0.10))
        case .assistant:
            Color.clear
        }
    }

    private var foreground: Color {
        switch body_.role {
        case .notice: .primary
        case .error: Theme.errorTint
        default: .primary
        }
    }
}

/// "Masked 2 emails and 1 key before sending to Kimi Code" — under an answer from a model that isn't private.
private struct MaskedChip: View {
    let summary: String
    let categories: String
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label(summary, systemImage: "eye.slash")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Masked before sending: \(categories). The real values stayed on this Mac.")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Masked before sending").font(.callout.weight(.semibold))
                Text(categories).font(.callout)
                Text("The model saw placeholders such as ⟦EMAIL_1⟧ instead; Vision put the real values back in what you see here. Change what is masked in Settings ▸ AI Models ▸ Sensitive data.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 300)
        }
    }
}

/// A tool call: one compact line, expandable to the full result.
private struct ToolCard: View {
    @Environment(AppModel.self) private var model
    let activity: ToolActivity
    let session: SessionVM
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard activity.output?.isEmpty == false else { return }
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if !activity.images.isEmpty {
                ToolImageStrip(images: activity.images)
            }

            if expanded, let output = activity.output, !output.isEmpty {
                Divider().padding(.vertical, 6)
                if LongText.isLong(output) {
                    // Thousands of lines: a text view that lays out only what is on screen.
                    LongTextView(text: output, monospaced: true)
                        .frame(height: 260)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(output)
                            .font(Theme.mono(11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .padding(.bottom, 2)
                }
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(activity.isOk == false ? Theme.errorTint.opacity(0.4) : Theme.hairline, lineWidth: 1)
        )
        .padding(.leading, Theme.gutter)
        .contextMenu {
            if let output = activity.output {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
            }
            if isFilePath, let url = resolvedURL {
                Button("Open in Editor") {
                    model.mode = .code
                    model.code.reveal(url)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: Theme.toolIcon(activity.name))
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(Theme.toolLabel(activity.name))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(activity.preview)
                .font(Theme.mono(11))
                .lineLimit(1)
                // Head-truncate: the tail of a path or command is the part
                // that identifies it.
                .truncationMode(.head)
            Spacer(minLength: 4)
            if activity.isFinished {
                if let summary = activity.summary, !summary.isEmpty {
                    Text(summary)
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
                if activity.output?.isEmpty == false {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .contentShape(Rectangle())
    }

    private var tint: Color {
        guard let ok = activity.isOk else { return .secondary }
        return ok ? Theme.successTint : Theme.errorTint
    }

    private var isFilePath: Bool {
        ["read_file", "write_file", "edit"].contains(activity.name)
    }

    private var resolvedURL: URL? {
        guard isFilePath, !activity.preview.isEmpty else { return nil }
        if activity.preview.hasPrefix("/") { return URL(fileURLWithPath: activity.preview) }
        guard let root = session.workspaceURL else { return nil }
        return root.appendingPathComponent(activity.preview)
    }
}

/// The model using one of the user's skills: "Using the deploy skill", expandable to the instructions it read.
private struct SkillCard: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard activity.output?.isEmpty == false else { return }
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(activity.isOk == false ? Theme.errorTint : Color.accentColor)
                        .frame(width: 14)
                    (Text("Using the ") + Text(activity.preview).fontWeight(.semibold) + Text(" skill"))
                        .font(.system(size: 12))
                    Spacer(minLength: 4)
                    if !activity.isFinished {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if activity.isOk == false, let summary = activity.summary {
                        Text(summary).font(Theme.metaFont).foregroundStyle(Theme.errorTint).lineLimit(1)
                    } else if activity.output?.isEmpty == false {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let output = activity.output, !output.isEmpty {
                Divider().padding(.vertical, 6)
                ScrollView {
                    Text(output)
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        .padding(.leading, Theme.gutter)
    }
}

/// The agent's task list.
private struct TodoCard: View {
    let items: [TodoItem]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 11))
                    Text("Plan")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(items.filter { $0.status == .completed }.count)/\(items.count)")
                        .font(Theme.metaFont)
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)

                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.status.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(item.status.tint)
                        Text(item.content)
                            .font(.callout)
                            .strikethrough(item.status == .completed, color: .secondary)
                            .foregroundStyle(item.status == .completed ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.leading, Theme.gutter)
    }
}

/// The plan as one line while the plan panel shows it in full: "Plan updated — 3 of 7 done · Show".
private struct CollapsedTodoCard: View {
    let items: [TodoItem]
    @State private var expanded = false

    var body: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 4) {
                TodoCard(items: items)
                Button("Hide") { expanded = false }
                    .buttonStyle(.plain).font(Theme.metaFont).foregroundStyle(.tint)
                    .padding(.leading, Theme.gutter)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11))
                Text("Plan updated — \(items.filter { $0.status == .completed }.count) of \(items.count) done")
                    .font(Theme.metaFont)
                Text("·").font(Theme.metaFont)
                Button("Show") { expanded = true }
                    .buttonStyle(.plain).font(Theme.metaFont).foregroundStyle(.tint)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, Theme.gutter)
        }
    }
}

/// A divider showing the conversation was compacted to fit the context window.
/// Expands to reveal the summary the model now carries in place of older turns.
private struct CompactionCard: View {
    let note: CompactionNote
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Rectangle().fill(Theme.hairline).frame(width: 16, height: 1)
                    Image(systemName: "scissors")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.noticeTint)
                    Text("Compacted \(note.removed.formatted()) earlier messages to fit the context window")
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, !note.summary.isEmpty {
                Divider().padding(.vertical, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(note.summary)
                        .font(Theme.mono(11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .padding(.bottom, 2)
            }
        }
        .padding(8)
        .background(Theme.noticeTint.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Summary") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.summary, forType: .string)
            }
        }
    }
}

// MARK: - Turn phases

/// The live phase card: Planning (draft streaming in) → Execution (green
/// working badge, runtime vs estimate, stamped steps) → Results. Validation
/// happens between execution and results; when it loops back, the card says
/// so and returns to the execution badge.
struct PhaseCard: View {
    let state: TurnPhaseState
    /// Keeps the runtime ticking and the badge animating.
    @State private var tick = Date()
    @State private var pulse = false
    @State private var showSteps = false
    @State private var showDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The phase strip: done phases tick, the live one animates.
            HStack(spacing: 10) {
                phaseChip(.planning)
                chevron
                phaseChip(.execution)
                chevron
                phaseChip(.validation)
                chevron
                phaseChip(.results)
                Spacer()
                if !state.isOver { runtime }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if let reason = state.endedReason {
                endedBody(reason)
            } else {
                switch state.phase {
                case .planning:
                    planningBody
                case .execution:
                    executionBody
                case .validation:
                    validationBody
                case .results:
                    resultsBody
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(outline, lineWidth: 1)
        )
        .task(id: state.phase) {
            // One timer per phase: the runtime line and the pulsing badge.
            while !Task.isCancelled, !state.isOver {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                tick = Date()
                pulse.toggle()
            }
        }
    }

    // MARK: Pieces

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func phaseChip(_ phase: TurnPhaseState.Phase) -> some View {
        let isLive = phase == state.phase && state.endedReason == nil
        let order: [TurnPhaseState.Phase] = [.planning, .execution, .validation, .results]
        let isDone = state.phase == .results
            || (order.firstIndex(of: phase) ?? 0) < (order.firstIndex(of: state.phase) ?? 0)
        return HStack(spacing: 4) {
            if isLive, state.phase != .planning {
                Circle()
                    .fill(Theme.successTint)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? 1.25 : 0.9)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            } else if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.successTint)
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 7, height: 7)
            }
            Text(phase.label)
                .font(.system(size: 10.5, weight: isLive ? .semibold : .regular))
                .foregroundStyle(isLive ? .primary : (isDone ? Theme.successTint : .secondary))
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var runtime: some View {
        Group {
            if let start = state.startedAt {
                Text("runtime \(Date().timeIntervalSince(start).formattedDuration)")
                    .font(Theme.mono(10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var outline: Color {
        if state.endedReason != nil { return Theme.hairline }
        if state.phase == .results, state.lastValidationFailure != nil { return Theme.noticeTint.opacity(0.5) }
        switch state.phase {
        case .planning: return Color.accentColor.opacity(0.35)
        case .execution, .validation: return Theme.successTint.opacity(0.4)
        case .results: return Theme.successTint.opacity(0.55)
        }
    }

    // MARK: Planning

    private var planningBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Drafting the plan")
                    .font(.system(size: 11, weight: .semibold))
                ProgressView().controlSize(.small).scaleEffect(0.6)
                if let kind = state.taskKind {
                    Text(kind.label).font(Theme.metaFont).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if state.draft.isEmpty {
                Text("Reading the ask…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            } else {
                // The live draft: the plan being written right now.
                Text(state.draft)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(showDraft ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                Button(showDraft ? "Show less" : "Show the draft") { showDraft.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.metaFont)
                    .foregroundStyle(.tint)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: Execution (the green working badge)

    private var executionBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                // The green, semi-animated working badge.
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.successTint)
                    .opacity(pulse ? 1 : 0.55)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                Text("Executing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.successTint)
                if let eta = state.etaSeconds {
                    Text("· est. \(TurnPhaseState.phrase(eta))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button(showSteps ? "Hide what it's doing" : "What it's doing") { showSteps.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.metaFont)
                    .foregroundStyle(.tint)
            }
            if let failure = state.lastValidationFailure, state.loopbacks > 0 {
                Text("Validation sent it back (\(state.loopbacks)\(state.loopbackCap.map { " of \($0)" } ?? "") retries): \(failure)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.noticeTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showSteps {
                // Timestamped steps, newest last — what drilling into the badge shows.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.steps.suffix(40).enumerated().reversed()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(step.at, style: .time)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(.tertiary)
                            Text(step.text)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: Validation

    private var validationBody: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.successTint)
            Text("Validating the work against the plan…")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: Results

    /// Stopped, failed, or waiting on the person: the card says so and stops animating.
    private func endedBody(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: reason.hasPrefix("Paused") ? "pause.circle" : reason.hasPrefix("Stopped") ? "stop.circle" : "xmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(reason.hasPrefix("Stopped") ? Color.secondary : Theme.noticeTint)
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let finished = state.finishedAt {
                Text(finished, style: .time).font(Theme.mono(10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var resultsBody: some View {
        let issues = state.lastValidationFailure != nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: issues ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(issues ? Theme.noticeTint : Theme.successTint)
                Text(issues ? "Finished with issues" : state.evidence.isEmpty ? "Completed" : "Completed with results")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(issues ? Theme.noticeTint : Theme.successTint)
                Spacer()
                if let finished = state.finishedAt {
                    Text(finished, style: .time)
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                }
            }
            if !state.evidence.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(state.evidence) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.title)
                                    .font(.system(size: 11, weight: .medium))
                                Text(item.at, style: .time)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(.tertiary)
                            }
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

/// Under the last result: how many prompts this chat has sent, and the way to the Prompts timeline.
private struct PromptsLink: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let count = session.promptHistory.count
        let failed = session.promptHistory.filter { $0.outcome == .failed || $0.outcome == .stopped }.count
        Button {
            model.runPanelTab = .prompts
            model.config.planPanelOpen = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("\(count) prompts in this chat" + (failed > 0 ? " · \(failed) didn't finish" : "") + " — open Prompts (⇧⌘H)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Every prompt this chat has sent, how each ended, its results — copy, quote, jump to it")
    }
}

/// Files this session's tools touched.
private struct ProducedFilesRow: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files changed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(session.changedFiles, id: \.url) { change in
                    Button {
                        model.mode = .code
                        model.code.reveal(change.url)
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(change.kind.tint).frame(width: 6, height: 6)
                            Text(name(change.url))
                                .font(Theme.mono(11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(change.url.path) — \(change.kind.label)")
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([change.url])
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(change.url.path, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.leading, Theme.gutter)
    }

    private func name(_ url: URL) -> String {
        guard let root = session.workspaceURL, url.path.hasPrefix(root.path) else {
            return url.lastPathComponent
        }
        return String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
    }
}

/// A live gauge of how much of the model's context window the conversation
/// is using. The limit comes from the active provider (user override → server
/// probe → well-known tables → default); the used figure is the server's
/// prompt-token count after the last turn, with the in-flight draft added on,
/// or a character estimate when the server hasn't reported yet.
private struct ContextGaugeView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let draft: String

    var body: some View {
        let limit = model.transport.contextLimit(for: session)
        let used = model.transport.contextUsed(for: session.id, draft: draft)
        let fraction = limit > 0 ? Double(used) / Double(limit) : 0
        return HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 11))
                .foregroundStyle(tint(fraction))
            Gauge(value: min(fraction, 1.0), in: 0...1) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(tint(fraction))
            .frame(width: 64)
            Text("\(used.formatted()) / \(limit.formatted()) ctx")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Context window in use for \(model.transport.modelID(for: session) ?? "this model"): \(used.formatted()) of \(limit.formatted()) tokens — window \(model.transport.contextSource(for: session)). Type /compact to free space.")
    }

    private func tint(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return Theme.errorTint }
        if fraction >= 0.7 { return Theme.noticeTint }
        return .secondary
    }
}

/// Shown while the agent is busy: what it's doing, and — for reasoning
/// models — a live tail of its thinking.
private struct ThinkingRow: View {
    let session: SessionVM
    @State private var phase = 0.0
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: session.reasoning.isEmpty ? "sparkle" : "brain")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .opacity(0.4 + 0.6 * abs(sin(phase)))
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !session.reasoning.isEmpty {
                Text(tail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .padding(.leading, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000)
                phase += 0.2
                now = Date()
            }
        }
    }

    private var headline: String {
        if session.stopping { return "Stopping…" }
        if let retry = session.retry {
            let wait = Int(retry.nextAttempt.timeIntervalSince(now).rounded(.up))
            let when = wait > 0 ? "retrying in \(wait)s" : "retrying now"
            return "Model unavailable (\(retry.reason)) — \(when) · attempt \(retry.attempt + 1). Stop to give up."
        }
        if let activity = session.activity { return activity }
        if !session.reasoning.isEmpty, let start = session.reasoningStarted {
            return "Thinking… \(Int(now.timeIntervalSince(start)))s"
        }
        return "Working…"
    }

    /// The last few lines of reasoning, flattened.
    private var tail: String {
        let flat = session.reasoning.suffix(400).replacingOccurrences(of: "\n", with: " ")
        return String(flat).trimmingCharacters(in: .whitespaces)
    }
}

/// The active `/goal`, above the composer.
private struct GoalBanner: View {
    let goal: SessionVM.GoalState
    let session: SessionVM

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .foregroundStyle(Color.accentColor)
            Text("Goal · round \(goal.round)")
                .font(.system(size: 11, weight: .semibold))
            Text(goal.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("⌘. to stop")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Matching slash commands while typing "/…".
private struct SlashHints: View {
    let matches: [SlashCommand.Info]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(matches, id: \.usage) { info in
                Button {
                    pick(info.usage)
                } label: {
                    HStack(spacing: 10) {
                        Text(info.usage).font(Theme.mono(11))
                        Text(info.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Per-chat thinking level, next to the permission preset.
private struct ThinkingMenu: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let fallback = model.transport.chatRoute(session)?.thinking
        // Only the levels this chat's model takes (Kimi K2.7 Code always thinks; GLM-5.3 has Low, High and Max).
        let rules = model.transport.requestRules(for: session)
        let offered = rules?.thinkingLevels ?? ThinkingLevel.allCases
        let chosen = session.thinking ?? fallback
        let current = chosen.flatMap { rules?.nearestLevel($0) ?? $0 }
        let name = { (level: ThinkingLevel) in rules?.label(level) ?? level.label }
        if offered.isEmpty {
            Label(rules?.alwaysThinks == true ? "Always thinks" : "No thinking setting", systemImage: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
                .help(rules?.alwaysThinks == true
                      ? "This model always thinks and takes no thinking setting."
                      : "This model has no thinking setting.")
        } else {
            Menu {
                Button {
                    model.transport.setThinking(nil, for: session)
                } label: {
                    Label("Provider default (\(fallback.map { rules?.nearestLevel($0).map(name) ?? $0.label } ?? "server default"))",
                          systemImage: session.thinking == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(offered, id: \.self) { level in
                    Button {
                        model.transport.setThinking(level, for: session)
                    } label: {
                        Label("\(name(level)) — \(level.blurb)",
                              systemImage: current == level && session.thinking != nil ? "checkmark" : level.symbol)
                    }
                }
            } label: {
                Label("Thinking: \(current.map(name) ?? "Default")", systemImage: current?.symbol ?? "brain")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .disabled(session.running)
            .help("How hard this chat's model thinks before answering — only the levels it takes are offered. Also: /think <level>")
        }
    }
}

/// The permission question, answered inline above the composer.
private struct GateCard: View {
    @Environment(AppModel.self) private var model
    let gate: GateVM
    let session: SessionVM

    var body: some View {
        Card(fill: Theme.noticeTint.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 8) {
                Label("The agent needs permission", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.noticeTint)
                Text(gate.detail)
                    .font(Theme.mono(11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Theme.toolLabel(gate.name))
                        .font(Theme.metaFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Deny") {
                        model.transport.answerGate(sessionID: session.id, gateID: gate.id, allow: false)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button("Allow Once") {
                        model.transport.answerGate(sessionID: session.id, gateID: gate.id, allow: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
    }
}

/// First-run content for an empty chat: what this is, and a few openers. A chat without a project is a regular
/// conversation: general openers (and a couple of the user's skills), with a small link to open a folder for code.
private struct ChatStarterView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    let send: (String) -> Void
    @State private var skills: [Skill] = []

    private var suggestions: [(String, String)] {
        if session.isPlain {
            var openers = [
                ("lightbulb", "Explain something simply"),
                ("pencil.line", "Help me write or rewrite something"),
                ("globe", "Summarise a web page"),
                ("list.bullet.clipboard", "Plan something with me"),
            ]
            for skill in skills.prefix(2) { openers.append(("graduationcap", "Use the \(skill.name) skill")) }
            return openers
        }
        return [
            ("map", "Give me a tour of this codebase — the entry points and how it fits together"),
            ("ant", "Find and fix any bugs you can verify with the tests"),
            ("doc.text", "Write a README section describing how to build and run this"),
            ("checklist", "What would you improve first in this project, and why?"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.projectName ?? session.title)
                        .font(.title3.weight(.semibold))
                    Text(model.transport.chatRoute(session).map { "Running on \($0.displayName)" }
                         ?? "No model configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ForEach(suggestions, id: \.1) { icon, text in
                Button {
                    send(text)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(text)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                }
                .buttonStyle(.plain)
            }

            if session.isPlain {
                Button("Open a folder to work on code") { model.chooseProject() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .task(id: session.id) {
            guard session.isPlain else { return }
            let disabled = model.config.disabledSkills
            skills = model.transport.skills(for: session)
                .filter { !$0.shadowed && !disabled.contains($0.id) && $0.kind == .skill && $0.origin != .builtin }
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// MARK: - Model switching

/// The model in use, and one click to change it: what each Spark Swapper box serves (switching it), and the
/// routes configured in Settings.
private struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM

    var body: some View {
        let spark = model.spark
        let current = model.transport.modelID(for: session) ?? model.transport.chatRoute(session)?.model ?? "No model"
        let limit = model.transport.contextLimit(for: session)
        Menu {
            if spark.isConfigured {
                ForEach(spark.boxes) { box in
                    Section("\(box.name) — what it serves") {
                        if let status = box.status {
                            ForEach(status.ordered) { m in
                                Button {
                                    spark.request(m, on: box)
                                } label: {
                                    Label(Self.line(m, status: status),
                                          systemImage: m.key == status.active ? "checkmark.circle.fill"
                                              : !m.isInstalled ? "arrow.down.circle"
                                              : m.running ? "hourglass" : "arrow.triangle.2.circlepath")
                                }
                                // Installing happens in Settings ▸ Model Servers, not from here.
                                .disabled(m.key == status.active || status.isSwitching || !m.isInstalled)
                            }
                        } else {
                            Text(box.lastError ?? "Connecting to \(box.name)…")
                        }
                    }
                }
                Button("Refresh") { Task { await spark.refreshAll() } }
            } else {
                Button("Connect a Spark Swapper…") { model.showSwapperGuide() }
            }
            RouteMenuSections(session: session)
        } label: {
            Label("\(current) · \(ModelSizes.short(limit))", systemImage: spark.isSwitchingMainModel ? "hourglass" : "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(session.running)
        .help("Model in use and its context window. Pick a model a Spark Swapper box serves to switch it (also /swap), or another configured route.")
        .task { if spark.boxes.contains(where: { $0.status == nil }) { await spark.refreshAll() } }
    }

    /// "Qwen3.8 27B — 1M · 27 tok/s measured here  (serving)"
    static func line(_ m: SwapperStatus.Model, status: SwapperStatus) -> String {
        var text = "\(m.title) — \(ModelSizes.short(m.window))"
        if let speed = m.speedText() { text += " · \(speed)" }
        if !m.isInstalled { text += " · Not installed" }
        else if m.key == status.active { text += "  (serving)" } else if m.running { text += "  (loading)" }
        return text
    }

    static func short(_ n: Int) -> String { ModelSizes.short(n) }
}

/// Live progress while a box switches models, above the composer.
private struct SparkSwapBanner: View {
    @Environment(AppModel.self) private var model
    @State private var tick = Date()

    var body: some View {
        let lines = model.spark.progressLines
        if !lines.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(tick, style: .time).hidden()   // keeps the timer line redrawing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.noticeTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    tick = Date()
                }
            }
        }
    }
}
