import SwiftUI
import AppKit
import VisionHarnessCore

// MARK: - Attachments waiting in the composer

/// One attachment waiting in the composer: read in the background, then shown as a chip saying what will be sent
/// ("report.pdf · PDF · 42 pages · sent as text").
struct StagedAttachment: Identifiable {
    let id = UUID()
    var attachment: MessageAttachment
    /// Still being read (PDF text, OCR, Office XML).
    var reading: Bool
    /// How many parts its text makes for the current route (1 = sent whole).
    var parts = 1

    var isPasted: Bool { attachment.digest?.format == .pasted }

    /// The chip's text after the name: summary and delivery. A large paste shows its own summary only
    /// ("Pasted text · 10,214 lines · 412 KB") — what it is, rather than a file name.
    func label(route: AttachmentRoute) -> String {
        guard !reading else { return "reading…" }
        guard let digest = attachment.digest else { return AttachmentWire.delivery(attachment, route: route).label }
        if digest.format == .pasted { return digest.summary }
        return digest.summary + " · " + AttachmentWire.delivery(attachment, route: route, parts: parts).label
    }

    /// The chip's tooltip: what will happen to it, in a sentence.
    func help(route: AttachmentRoute) -> String {
        guard let digest = attachment.digest else { return attachment.name }
        if let problem = digest.problem { return "\(attachment.name): \(problem)" }
        let delivery = AttachmentWire.delivery(attachment, route: route, parts: parts)
        var out = "\(attachment.name) — \(digest.summary), \(delivery.label)."
        if case .textInParts = delivery {
            out += " The model gets a contents list and the first parts, and reads the rest with read_attachment."
        }
        return out + " Click to see what the model will get."
    }
}

/// The removable chips above the composer.
struct AttachmentChips: View {
    @Binding var items: [StagedAttachment]
    let route: AttachmentRoute
    var onOpen: (StagedAttachment) -> Void

    var body: some View {
        // Wrapped onto as many lines as they need: every chip says what will be sent, so none hides off the edge.
        FlowLayout(spacing: 6) {
            ForEach(items) { item in
                chip(item)
            }
        }
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ item: StagedAttachment) -> some View {
        HStack(spacing: 5) {
            Button { onOpen(item) } label: {
                HStack(spacing: 5) {
                    if item.reading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: Self.icon(item.attachment))
                            .font(.caption2)
                            .foregroundStyle(item.attachment.digest?.problem == nil ? Color.secondary : Theme.noticeTint)
                    }
                    if !item.isPasted {
                        Text(item.attachment.name)
                            .font(Theme.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(item.label(route: route))
                        .font(.system(size: 11))
                        .foregroundStyle(item.isPasted ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(item.reading)
            Button {
                items.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .help(item.help(route: route))
    }

    static func icon(_ attachment: MessageAttachment) -> String {
        if attachment.kind == .image { return "photo" }
        switch attachment.digest?.format {
        case .pasted: return "doc.on.clipboard"
        case .pdf: return "doc.richtext"
        case .word, .rtf: return "doc.text"
        case .powerpoint: return "rectangle.on.rectangle"
        case .excel, .csv, .tsv: return "tablecells"
        case .code, .json, .yaml, .xml, .html: return "chevron.left.forwardslash.chevron.right"
        case .binary: return "questionmark.square.dashed"
        default: return "doc"
        }
    }
}

// MARK: - Seeing (and for a paste, editing) what the model will get

struct AttachmentPreviewSheet: View {
    let item: StagedAttachment
    let route: AttachmentRoute
    /// Save an edited paste; nil for files (read-only).
    var onSave: ((String) -> Void)?
    var onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var handle = LargeTextView.Handle()

    private var digest: AttachmentDigest? { item.attachment.digest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: AttachmentChips.icon(item.attachment))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isPasted ? "Pasted text" : item.attachment.name)
                        .font(.headline)
                    Text(item.label(route: route) + (item.isPasted ? " · " + AttachmentWire.delivery(item.attachment, route: route, parts: item.parts).label : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let problem = digest?.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.noticeTint)
            }
            if item.attachment.kind == .image, let image = NSImage(data: item.attachment.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                Text(route.vision ? "Sent as the picture. If the model couldn't take pictures, it would get the text below (read by OCR)."
                                  : "This model can't take pictures, so it gets the text below (read by OCR).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(onSave != nil ? "Edit the pasted text; it is sent as an attachment, not in the message box."
                                   : "The text Vision read out of the file — what a model that can't take the file itself gets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LargeTextView(text: digest?.text ?? "", editable: onSave != nil, handle: handle)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline, lineWidth: 1))
            HStack {
                Button("Remove", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                Spacer()
                if let onSave {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        onSave(handle.string)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
    }
}

/// A plain-text view for very long text (hundreds of thousands of characters): AppKit's text system with
/// non-contiguous layout, so only what is on screen is laid out. The text is read back through `handle` on demand
/// rather than on every keystroke.
struct LargeTextView: NSViewRepresentable {
    @MainActor
    final class Handle {
        weak var textView: NSTextView?
        var string: String { textView?.string ?? "" }
    }

    let text: String
    let editable: Bool
    let handle: Handle

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text
        textView.isEditable = editable
        handle.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? NSTextView)?.isEditable = editable
    }
}

// MARK: - In the transcript

/// The attachments a sent message carried, as small badges under it ("report.pdf · PDF · 42 pages · sent as text").
struct AttachmentBadges: View {
    let badges: [AttachmentBadge]

    var body: some View {
        // Wraps rather than scrolls: a message rarely carries more than a few.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                HStack(spacing: 5) {
                    Image(systemName: badge.image ? "photo" : badge.label.hasPrefix("Pasted text") ? "doc.on.clipboard" : "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !badge.label.hasPrefix("Pasted text") {
                        Text(badge.name)
                            .font(Theme.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(badge.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.surfaceStrong, in: Capsule())
                .help(badge.stored.map { "Saved with this chat as \($0); the model can read it again with read_attachment." } ?? badge.name)
            }
        }
    }
}

/// A user message too long to lay out whole in the transcript (a paste from before pastes became attachments): its
/// first lines, and a button that opens all of it in a text view built for long text.
struct CollapsedUserText: View {
    let text: String
    let preview: String
    let lines: Int
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showing = true
            } label: {
                Label("Show all \(AttachmentText.count(lines, "line", "lines")) · \(AttachmentText.bytes(text.utf8.count))",
                      systemImage: "text.alignleft")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.link)
        }
        .sheet(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your message · \(AttachmentText.count(lines, "line", "lines"))").font(.headline)
                LargeTextView(text: text, editable: false, handle: LargeTextView.Handle())
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Spacer()
                    Button("Done") { showing = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 620, idealWidth: 720, minHeight: 440, idealHeight: 560)
        }
    }
}
