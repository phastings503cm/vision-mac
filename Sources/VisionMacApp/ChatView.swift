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
    /// Attachments queued to go out with the next message.
    @State private var attachments: [MessageAttachment] = []
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
            draft = text
            composerHeight = min(max(ComposerField.minHeight, 90), ComposerField.maxHeight)
            model.pendingComposerText = nil
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
        }
    }

    /// What follows the newest row: the turn's phase card, the prompt history, the thinking line, changed files.
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
            PromptHistoryView(session: session)
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

            if !attachments.isEmpty {
                attachChips
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
                .help("Attach an image or file")
                .disabled(session.running)

                ComposerField(text: $draft, height: $composerHeight,
                              isEnabled: !session.running, onSubmit: send)
                    .frame(height: composerHeight)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )

                if session.running {
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
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .help("Send (↩)")
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
                            Text("\(usage.promptTokens.formatted()) in · \(usage.completionTokens.formatted()) out")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !session.running else { return }
        let payload = attachments
        draft = ""
        attachments = []
        model.send(text, in: session, attachments: payload)
    }

    /// The queued attachments as removable chips.
    private var attachChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(attachment.name)
                            .font(Theme.mono(11))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    .help(attachment.name)
                    Button {
                        attachments.removeAll { $0 == attachment }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove attachment")
                }
            }
            .padding(.bottom, 2)
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

    /// Read the file and, for images, re-encode to PNG so any model can see it.
    private func stage(_ url: URL, kind: MessageAttachment.Kind) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        guard !attachments.contains(where: { $0.name == name && $0.data == data }) else { return }
        if kind == .image,
           let image = NSImage(data: data),
           let png = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: png),
           let out = rep.representation(using: .png, properties: [:]) {
            attachments.append(MessageAttachment(kind: .image, name: name, data: out))
        } else {
            attachments.append(MessageAttachment(kind: kind, name: name, data: data))
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

    static let minHeight: CGFloat = 32
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
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let target = min(max(ComposerField.minHeight,
                                 (used + textView.textContainerInset.height * 2).rounded(.up)),
                             ComposerField.maxHeight)
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
                .modifier(MessageCopyActions(entry: entry, pager: session.pager))
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
                TranscriptText(text: body_.text, markdown: body_.role != .user, streaming: streaming,
                               expanded: $expanded)
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
                if state.phase != .results { runtime }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(outline, lineWidth: 1)
        )
        .task(id: state.phase) {
            // One timer per phase: the runtime line and the pulsing badge.
            while !Task.isCancelled, state.phase != .results {
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
        let isLive = phase == state.phase
        let isDone = state.phase == .results ||
            (state.phase == .validation && phase == .planning) ||
            (state.phase == .validation && phase == .execution && false) ||
            (state.phase == .results && phase != .results)
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
        }
    }

    private var runtime: some View {
        Group {
            if let start = state.startedAt {
                let elapsed = Int(Date().timeIntervalSince(start))
                Text("runtime \(elapsed)m\(elapsed % 60 < 10 ? "0" : "")\(elapsed % 60)s")
                    .font(Theme.mono(10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var outline: Color {
        switch state.phase {
        case .planning: Color.accentColor.opacity(0.35)
        case .execution, .validation: Theme.successTint.opacity(0.4)
        case .results: Theme.successTint.opacity(0.55)
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

    private var resultsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.successTint)
                Text("Completed with results")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.successTint)
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

/// A chat's prompts so far, with their outcomes and a way to reuse one: the
/// prompt timeline. Click a row to expand it; copy it (exactly as sent), drop it
/// back into the composer to talk about it, or jump to it in the transcript.
struct PromptHistoryView: View {
    @Environment(AppModel.self) private var model
    let session: SessionVM
    @State private var expandedID: String?
    @State private var hoveredID: String?
    /// A prompt "Jump" couldn't find in the transcript (compacted away since).
    @State private var missingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Prompt history — \(session.promptHistory.count) prompt\(session.promptHistory.count == 1 ? "" : "s") in this chat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(session.promptHistory) { record in
                row(record)
            }
        }
    }

    @ViewBuilder
    private func row(_ record: SessionVM.PromptRecord) -> some View {
        let isExpanded = expandedID == record.id
        let long = LongText.isLong(record.text)
        let copyID = "prompt:\(record.id)"
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { expandedID = isExpanded ? nil : record.id }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.userTint)
                        // A 10,000-line prompt is one line here; the row never lays out all of it.
                        Text(long ? LongText.head(record.text, lines: 1, bytes: 300) : record.text)
                            .font(.system(size: 11.5))
                            .lineLimit(isExpanded && !long ? nil : 1)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        CopiedBadge(id: copyID)
                        outcomeChip(record)
                        Text(record.at, style: .time)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                CopyButton(id: copyID, help: "Copy this prompt, exactly as sent") { record.text }
                    .opacity(hoveredID == record.id || isExpanded ? 1 : 0)
            }
            .onHover { inside in
                if inside { hoveredID = record.id } else if hoveredID == record.id { hoveredID = nil }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(long ? LongText.head(record.text) : record.text)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    if long {
                        Text("First lines of \(LongText.lineCount(record.text).formatted()) — Copy gives all of it")
                            .font(Theme.metaFont)
                            .foregroundStyle(.secondary)
                    }
                    if missingID == record.id {
                        Text("That prompt is no longer in the transcript — the conversation was compacted since.")
                            .font(Theme.metaFont)
                            .foregroundStyle(Theme.noticeTint)
                    }
                    HStack(spacing: 10) {
                        Button("Copy") { MessageCopy.copy(record.text, feedbackID: copyID) }
                        Button("Reuse in composer") {
                            model.pendingComposerText = record.text
                        }
                        Button("Jump to it") { jump(to: record) }
                        Spacer()
                    }
                    .font(Theme.metaFont)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.leading, 24)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .background(isExpanded ? Theme.surface.opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Copy Prompt") { MessageCopy.copy(record.text, feedbackID: copyID) }
            Button("Reuse in Composer") { model.pendingComposerText = record.text }
            Button("Jump to Prompt") { jump(to: record) }
        }
    }

    /// Scroll the transcript to the prompt's own message (loading the page around it) and flash it.
    private func jump(to record: SessionVM.PromptRecord) {
        guard let id = TranscriptPager.entryID(forPrompt: record.text, at: record.at, in: session.entries) else {
            expandedID = record.id
            missingID = record.id
            return
        }
        missingID = nil
        session.pager.jump(to: id)
    }

    @ViewBuilder
    private func outcomeChip(_ record: SessionVM.PromptRecord) -> some View {
        switch record.outcome {
        case .none:
            Label("working", systemImage: "hourglass")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        case .completed(let evidence):
            Label(evidence > 0 ? "completed · \(evidence) evidence" : "completed",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.successTint)
        case .blocked:
            Label("needs you", systemImage: "pause.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.noticeTint)
        case .failed:
            Label("failed", systemImage: "xmark.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.errorTint)
        case .stopped:
            Label("stopped", systemImage: "stop.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
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
        let limit = model.transport.contextLimit()
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
        .help("Context window in use for \(model.transport.activeModelID ?? "this model"): \(used.formatted()) of \(limit.formatted()) tokens — window \(model.transport.contextSource()). Type /compact to free space.")
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
        let fallback = model.config.activeProvider?.thinking
        let current = session.thinking ?? fallback
        Menu {
            Button {
                session.thinking = nil
            } label: {
                Label("Provider default (\(fallback?.label ?? "server default"))",
                      systemImage: session.thinking == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                Button {
                    session.thinking = level
                } label: {
                    Label("\(level.label) — \(level.blurb)",
                          systemImage: session.thinking == level ? "checkmark" : level.symbol)
                }
            }
        } label: {
            Label("Thinking: \(current?.label ?? "Default")", systemImage: current?.symbol ?? "brain")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(session.running)
        .help("How hard the model thinks before answering (sent as reasoning_effort / enable_thinking). Also: /think <level>")
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
                    Text(model.config.activeProvider.map { "Running on \($0.displayName)" }
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
        let current = model.transport.activeModelID ?? model.config.activeProvider?.model ?? "No model"
        let limit = model.transport.contextLimit()
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
            RouteMenuSections()
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
