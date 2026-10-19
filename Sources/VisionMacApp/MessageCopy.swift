import SwiftUI
import AppKit
import VisionHarnessCore

/// Copying what is in a chat: a prompt exactly as the person sent it, a reply, a tool's output — and the brief
/// "Copied" that says it worked.
@MainActor
enum MessageCopy {
    /// Where copies go: the general pasteboard. Tests and the screenshot mode put a private one here so a run never
    /// touches the person's clipboard.
    static var pasteboard: NSPasteboard = .general

    /// The text a copy of this row gives: a message's exact text (a prompt as it was sent; a goal's or queued task's
    /// first round gives the goal the person wrote, without the "🎯 /goal " or "🚀 queue: " it shows with), a tool's
    /// full output (or what it ran, while it has none), the plan as a checklist, a compaction's summary.
    nonisolated static func text(for entry: ChatEntry) -> String? {
        switch entry.kind {
        case .message(let body):
            if body.role == .user, let goal = GoalTranscript.goal(inKickoff: body.text) { return goal }
            return body.text
        case .tool(let activity):
            if let output = activity.output, !output.isEmpty { return output }
            return activity.preview.isEmpty ? nil : activity.preview
        case .todos(let items):
            guard !items.isEmpty else { return nil }
            return items.map { "- [\($0.status == .completed ? "x" : " ")] \($0.content)" }.joined(separator: "\n")
        case .compaction(let note):
            return note.summary.isEmpty ? nil : note.summary
        }
    }

    /// The text a copy of this row gives, with the whole of each pasted-text chip its prompt carried after what was
    /// typed — a prompt copies exactly as it was sent. `pasted` reads a chip's saved text (nil: not a paste, or gone).
    nonisolated static func text(for entry: ChatEntry, pasted: (AttachmentBadge) -> String?) -> String? {
        let typed = text(for: entry)
        guard case .message(let body) = entry.kind, body.role == .user, !body.attachments.isEmpty else { return typed }
        let pastes = body.attachments.compactMap(pasted)
        guard !pastes.isEmpty else { return typed }
        return ([typed ?? ""].filter { !$0.isEmpty } + pastes).joined(separator: "\n\n")
    }

    /// A chip's saved text when it is a paste (a file or a picture isn't part of what the person wrote).
    nonisolated static func pastedText(_ badge: AttachmentBadge, store: AttachmentStore) -> String? {
        guard let name = badge.stored, let saved = store.entry(named: name), saved.format == .pasted else { return nil }
        return store.text(of: saved)
    }

    /// What Copy gives for a row of `session`: its text, and its prompt's pastes from the chat's saved attachments.
    static func text(for entry: ChatEntry, in session: SessionVM, transport: AppTransport) -> String? {
        let store = transport.attachmentStore(for: session.id)
        return text(for: entry, pasted: { pastedText($0, store: store) })
    }

    /// What Copy gives for a prompt in the Prompts timeline: what was asked, and — while its chat is loaded and its
    /// row is still in the transcript — the pastes that went with it.
    static func text(for record: PromptRecord, transport: AppTransport) -> String {
        guard let vm = transport.sessions.first(where: { $0.id == record.chatID }),
              let id = transport.entryID(for: record, in: vm),
              let entry = vm.entries.last(where: { $0.id == id }),
              let body = entry.message, body.text == (record.entryText ?? record.text), !body.attachments.isEmpty else {
            return record.text
        }
        let store = transport.attachmentStore(for: vm.id)
        let pastes = body.attachments.compactMap { pastedText($0, store: store) }
        return ([record.text].filter { !$0.isEmpty } + pastes).joined(separator: "\n\n")
    }

    /// The "Copied" key for a prompt in the Prompts timeline.
    nonisolated static func promptFeedbackID(_ recordID: String) -> String { "prompt:\(recordID)" }

    /// Put `text` on the pasteboard and say "Copied" on whatever shows `feedbackID`.
    @discardableResult
    static func copy(_ text: String, feedbackID: String) -> Bool {
        pasteboard.clearContents()
        let done = pasteboard.setString(text, forType: .string)
        if done { CopyFeedback.shared.show(feedbackID) }
        return done
    }

    /// The "Copied" key for a transcript row.
    nonisolated static func feedbackID(_ entryID: String) -> String { "entry:\(entryID)" }

    /// What Copy Message copies: the selected row, or the last prompt sent (a goal's "↻ round 3: keep going" rounds
    /// are the app's, not the person's). `pasted` reads a pasted-text chip's saved text.
    static func menuTarget(in session: SessionVM?,
                           pasted: (AttachmentBadge) -> String? = { _ in nil }) -> (id: String, text: String)? {
        guard let session else { return nil }
        if let id = session.pager.selectedID, let entry = session.entries.last(where: { $0.id == id }),
           let text = text(for: entry, pasted: pasted) {
            return (id, text)
        }
        guard let last = session.entries.last(where: { entry in
            guard let body = entry.message, body.role == .user else { return false }
            return !GoalTranscript.isRound(body.text)
        }), let text = text(for: last, pasted: pasted) else {
            return nil
        }
        return (last.id, text)
    }

    /// What a "Copy" control calls a row's text.
    nonisolated static func noun(for entry: ChatEntry) -> String {
        switch entry.kind {
        case .message(let body):
            switch body.role {
            case .user: "Prompt"
            case .assistant: "Reply"
            case .notice, .error: "Message"
            }
        case .tool: "Output"
        case .todos: "Plan"
        case .compaction: "Summary"
        }
    }
}

/// The user rows a goal adds to the transcript (`AppTransport.goalLoop`): its first round shows the goal after a
/// marker ("🎯 /goal …", "🚀 queue: …"), and each later round is the app's own "↻ round N: keep going". Copy and
/// Jump read them back through here, so a goal's prompt copies and is found as the person wrote it.
enum GoalTranscript {
    /// Longest first: "🎯 /goal (resuming) " also starts with "🎯 /goal ".
    nonisolated static let goalMarkers = ["🎯 /goal (resuming) ", "🎯 /goal "]
    nonisolated static let queueMarkers = ["🚀 queue (resuming): ", "🚀 queue: "]

    /// How a goal's (or, `queued`, a queued task's) first round shows in the transcript.
    nonisolated static func kickoff(_ goal: String, queued: Bool, resuming: Bool) -> String {
        let markers = queued ? queueMarkers : goalMarkers
        return (resuming ? markers[0] : markers[1]) + goal
    }

    /// The goal in a first round's text; nil for any other message.
    nonisolated static func goal(inKickoff text: String) -> String? {
        for marker in goalMarkers + queueMarkers where text.hasPrefix(marker) {
            return String(text.dropFirst(marker.count))
        }
        return nil
    }

    /// A later round's text.
    nonisolated static func round(_ round: Int, recovering: Bool) -> String {
        recovering ? "↻ round \(round): recover and keep going" : "↻ round \(round): keep going"
    }

    /// A later round, or a validation loop-back ("↻ validation: fix and check again") — the app's rows, not the person's.
    nonisolated static func isRound(_ text: String) -> Bool { text.hasPrefix("↻ ") }
}

/// Which copy control just worked, for a moment.
@MainActor
@Observable
final class CopyFeedback {
    static let shared = CopyFeedback()
    private(set) var copiedID: String?
    private var generation = 0

    func show(_ id: String) {
        copiedID = id
        generation += 1
        let mine = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if generation == mine { copiedID = nil }
        }
    }
}

/// "✓ Copied", while `id` was just copied.
struct CopiedBadge: View {
    let id: String

    var body: some View {
        if CopyFeedback.shared.copiedID == id {
            Label("Copied", systemImage: "checkmark")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.successTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
        }
    }
}

/// A small copy button; it turns into a check for a moment once it copied.
struct CopyButton: View {
    let id: String
    let help: String
    let text: () -> String?

    var body: some View {
        let copied = CopyFeedback.shared.copiedID == id
        Button {
            if let text = text() { MessageCopy.copy(text, feedbackID: id) }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(copied ? Theme.successTint : .secondary)
                .frame(width: 22, height: 20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Copy on a transcript message: a button on hover (and while it is selected), "Copy Prompt/Reply" in its context
/// menu, and Edit ▸ Copy Message (⇧⌘C) once it is clicked — a click selects it (a ring shows). Text selected inside
/// it still copies just that with ⌘C.
struct MessageCopyActions: ViewModifier {
    let entry: ChatEntry
    let pager: TranscriptPager
    /// The text Copy gives (`MessageCopy.text(for:in:transport:)`: the pastes a prompt carried included).
    let copyText: () -> String?
    @State private var hovering = false

    private var copyID: String { MessageCopy.feedbackID(entry.id) }
    private var noun: String { MessageCopy.noun(for: entry) }

    func body(content: Content) -> some View {
        let selected = pager.selectedID == entry.id
        content
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    CopiedBadge(id: copyID)
                    if hovering || selected {
                        CopyButton(id: copyID, help: "Copy the \(noun.lowercased()) — all of it, exactly as it is (or click it, then ⇧⌘C)",
                                   text: copyText)
                    }
                }
                .padding(4)
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy \(noun)") { copy() }
            }
            // A click anywhere on the message selects it (alongside starting a text selection in it).
            .simultaneousGesture(TapGesture().onEnded { pager.selectedID = entry.id })
    }

    private func copy() {
        guard let text = copyText() else { return }
        MessageCopy.copy(text, feedbackID: copyID)
    }
}

/// Edit ▸ Copy Message (⇧⌘C): the message selected in the chat, or — with none selected — the last prompt sent.
struct MessageCopyCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            // The title doesn't read the transcript: a menu that did would be rebuilt on every streamed word.
            Button("Copy Message") {
                let session = model.selectedSession
                let store = session.map { model.transport.attachmentStore(for: $0.id) }
                guard let target = MessageCopy.menuTarget(in: session, pasted: { badge in
                    store.flatMap { MessageCopy.pastedText(badge, store: $0) }
                }) else { NSSound.beep(); return }
                MessageCopy.copy(target.text, feedbackID: MessageCopy.feedbackID(target.id))
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.selectedSession == nil)
        }
    }
}
