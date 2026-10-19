import SwiftUI
import AppKit

/// Text too long to draw whole in the transcript — a 10,000-line paste, a huge tool output, a runaway reply.
///
/// One such message laid out in full is taller than a hundred screens: scrolling past it takes minutes and laying it
/// out can stall the app. In the transcript it shows its first lines and "Show more"; opened, a moderately long one
/// joins the transcript's flow and a very long one sits in a scrolling text view of its own, so it never decides how
/// the transcript scrolls.
enum LongText {
    /// Longer than this many lines (or `maxBytes`), a message is drawn collapsed.
    static let maxLines = 40
    static let maxBytes = 8_000
    /// What a collapsed message shows: its first lines, up to this many bytes.
    static let previewLines = 20
    static let previewBytes = 3_000
    /// Opened, text up to this size joins the transcript's flow; anything longer gets a scrolling view of its own.
    static let inlineLines = 400
    static let inlineBytes = 40_000
    /// The height of that scrolling view.
    static let viewerHeight: CGFloat = 420

    /// Whether `text` is drawn collapsed. Stops reading as soon as it knows.
    static func isLong(_ text: String) -> Bool {
        let utf8 = text.utf8
        if utf8.count > maxBytes { return true }
        var lines = 1
        for byte in utf8 where byte == 0x0A {
            lines += 1
            if lines > maxLines { return true }
        }
        return false
    }

    /// Whether opened `text` still joins the transcript's flow.
    static func fitsInline(_ text: String) -> Bool {
        let utf8 = text.utf8
        if utf8.count > inlineBytes { return false }
        return lineCount(text) <= inlineLines
    }

    static func lineCount(_ text: String) -> Int {
        var lines = 1
        for byte in text.utf8 where byte == 0x0A { lines += 1 }
        return lines
    }

    /// The first `lines` lines of `text`, at most `bytes` long (cut on a character boundary).
    static func head(_ text: String, lines: Int = previewLines, bytes: Int = previewBytes) -> String {
        let utf8 = text.utf8
        var seen = 0
        var newlines = 0
        var end = utf8.endIndex
        for index in utf8.indices {
            if seen >= bytes { end = index; break }
            if utf8[index] == 0x0A {
                newlines += 1
                if newlines >= lines { end = index; break }
            }
            seen += 1
        }
        return String(text[..<boundary(end, in: text)])
    }

    /// The last `lines` lines of `text`, at most `bytes` long (cut on a character boundary).
    static func tail(_ text: String, lines: Int = previewLines, bytes: Int = previewBytes) -> String {
        let utf8 = text.utf8
        var index = utf8.endIndex
        var seen = 0
        var newlines = 0
        while index > utf8.startIndex {
            let previous = utf8.index(before: index)
            // A line break before the line `index` starts (one ending the whole text doesn't count).
            if utf8[previous] == 0x0A, index != utf8.endIndex {
                newlines += 1
                if newlines >= lines { break }
            }
            if seen >= bytes { break }
            seen += 1
            index = previous
        }
        // Forward to a character's start, so the tail never grows past its budget.
        while index < utf8.endIndex, String.Index(index, within: text) == nil { index = utf8.index(after: index) }
        return String(text[index...])
    }

    /// `index` moved back to the start of the character it falls in.
    private static func boundary(_ index: String.Index, in text: String) -> String.Index {
        var index = index
        while index > text.startIndex, String.Index(index, within: text) == nil {
            index = text.utf8.index(before: index)
        }
        return index
    }
}

// MARK: - In the transcript

/// A message's text in the transcript: whole when it is ordinary; when very long, its first lines and "Show more"
/// (and while it is still streaming in, its last lines).
struct TranscriptText: View {
    let text: String
    /// Replies and notices are markdown; a prompt is shown as typed.
    let markdown: Bool
    var streaming = false
    @Binding var expanded: Bool

    var body: some View {
        if !LongText.isLong(text) {
            Self.plain(text, markdown: markdown)
        } else if streaming {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(max(0, LongText.lineCount(text) - LongText.previewLines).formatted()) lines above — the newest as they arrive")
                    .font(Theme.metaFont)
                    .foregroundStyle(.secondary)
                Self.plain(LongText.tail(text), markdown: false)
            }
        } else if expanded {
            VStack(alignment: .leading, spacing: 6) {
                if LongText.fitsInline(text) {
                    Self.plain(text, markdown: markdown)
                } else {
                    LongTextView(text: text, monospaced: false)
                        .frame(height: LongText.viewerHeight)
                        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                toggle
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Self.plain(LongText.head(text), markdown: markdown)
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                               .init(color: .black.opacity(0.25), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                toggle
            }
        }
    }

    private var toggle: some View {
        HStack(spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                Label(expanded ? "Show less" : "Show more", systemImage: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Text(summary)
                .font(Theme.metaFont)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// "10,002 lines · 712 KB" (whole), "· 9,982 more lines" (collapsed).
    private var summary: String {
        let lines = LongText.lineCount(text)
        let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        if expanded { return "\(lines.formatted()) lines · \(size)" }
        let shown = LongText.lineCount(LongText.head(text))
        return "\(max(0, lines - shown).formatted()) more lines · \(size)"
    }

    @ViewBuilder
    static func plain(_ text: String, markdown: Bool) -> some View {
        if markdown {
            MarkdownView(source: text)
        } else {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Very long text in a scrolling, selectable text view of its own (AppKit lays out only what is on screen).
struct LongTextView: NSViewRepresentable {
    let text: String
    var monospaced: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Cheap test first: a long text is compared in full only when its length matches.
        if textView.string.utf8.count != text.utf8.count || textView.string != text {
            textView.string = text
        }
    }
}
