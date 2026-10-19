import XCTest
import AppKit
import SwiftUI
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The composer's paste rule, through AppKit's own paste path: a paste over the thresholds never lands in the text
/// field (it becomes an attachment chip); an ordinary one does. Pastes come from a private pasteboard, never the
/// user's clipboard.
@MainActor
final class ComposerPasteTests: XCTestCase {
    private final class Captured { var pasted: [String] = [] }

    private func field(_ captured: Captured) -> (NSTextView, ComposerField.Coordinator) {
        let composer = ComposerField(text: .constant(""), height: .constant(32), isEnabled: true, onSubmit: {},
                                     onLargePaste: { captured.pasted.append($0) })
        let coordinator = ComposerField.Coordinator(composer)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        textView.isRichText = false
        textView.delegate = coordinator
        return (textView, coordinator)
    }

    private func paste(_ text: String, into textView: NSTextView) {
        let board = NSPasteboard(name: NSPasteboard.Name("vision-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString(text, forType: .string)
        _ = textView.readSelection(from: board, type: .string)
    }

    func testAHugePasteBecomesAnAttachmentInsteadOfText() {
        let captured = Captured()
        let (textView, coordinator) = field(captured)
        let big = (1...10_214).map { "line \($0)" }.joined(separator: "\n")
        paste(big, into: textView)
        XCTAssertEqual(textView.string, "", "the field stays empty")
        XCTAssertEqual(captured.pasted, [big])
        withExtendedLifetime(coordinator) {}
    }

    func testAnOrdinaryPasteGoesIntoTheField() {
        let captured = Captured()
        let (textView, coordinator) = field(captured)
        let small = (1...400).map { "l\($0)" }.joined(separator: "\n")
        paste(small, into: textView)
        XCTAssertEqual(textView.string, small)
        XCTAssertTrue(captured.pasted.isEmpty)
        // Typing is never intercepted, however long the draft grows.
        textView.insertText("x", replacementRange: textView.selectedRange())
        XCTAssertTrue(textView.string.hasSuffix("x"))
        withExtendedLifetime(coordinator) {}
    }

    func testOneCharacterOverTheLimitIsEnough() {
        let captured = Captured()
        let (textView, coordinator) = field(captured)
        paste(String(repeating: "a", count: 20_001), into: textView)
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(captured.pasted.first?.count, 20_001)
        withExtendedLifetime(coordinator) {}
    }
}
