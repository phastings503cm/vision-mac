import Foundation

// MARK: - Very large pastes become an attachment
//
// Pasting a 10,000-line log into the composer used to put all of it in the text field — and then, sent, all of it
// in one transcript row that every layout pass had to measure. A paste over either threshold becomes a
// "Pasted text · 10,214 lines · 412 KB" chip instead (view, edit, remove), sent through the same path as an attached
// file, so a long one goes in parts the model reads on demand. Pinned: Vision for Windows uses the same numbers.

public enum PastedText {
    /// A paste with more lines than this becomes an attachment.
    public static let maxLines = 400
    /// A paste with more characters (UTF-16 units) than this becomes an attachment.
    public static let maxCharacters = 20_000

    /// Whether `text` is too large to paste into the composer as it is.
    public static func isLarge(_ text: String) -> Bool {
        // Cheap first: the character count settles most pastes without counting lines.
        if text.utf16.count > maxCharacters { return true }
        return AttachmentText.lineCount(AttachmentText.normalizeNewlines(text)) > maxLines
    }

    /// The attachment for a large paste, named so several in one chat stay apart ("pasted-text.txt",
    /// "pasted-text-2.txt", …) given the names already staged or sent.
    public static func attachment(_ text: String, existing: [String] = []) -> MessageAttachment {
        AttachmentReader.pasted(text, name: name(existing: existing))
    }

    public static func name(existing: [String]) -> String {
        let taken = Set(existing)
        if !taken.contains("pasted-text.txt") { return "pasted-text.txt" }
        var n = 2
        while taken.contains("pasted-text-\(n).txt") { n += 1 }
        return "pasted-text-\(n).txt"
    }

    /// A user message's text shown collapsed in the transcript when it is longer than this many lines or
    /// characters (older chats hold pastes from before the chip).
    public static let collapseLines = 24
    public static let collapseCharacters = 3_000
    /// How much of a collapsed message its row shows.
    public static let previewLines = 16
    public static let previewCharacters = 2_000

    /// The first lines of a long message, for its collapsed transcript row; nil when it is short enough to show.
    public static func collapsed(_ text: String) -> (preview: String, lines: Int)? {
        let utf16 = text.utf16.count
        // Count lines only up to what decides it, so a huge message costs one pass at most.
        var lines = 0
        var cut: String.Index?
        let bytes = text.utf8
        for index in bytes.indices where bytes[index] == 0x0A {
            lines += 1
            if lines == previewLines { cut = index }
        }
        let total = text.isEmpty ? 0 : (text.hasSuffix("\n") ? lines : lines + 1)
        guard total > collapseLines || utf16 > collapseCharacters else { return nil }
        var preview = String(text[..<(cut ?? text.endIndex)])
        if preview.utf16.count > previewCharacters {
            preview = String(preview.utf16.prefix(previewCharacters)) ?? String(preview.prefix(previewCharacters))
        }
        return (preview, total)
    }
}
