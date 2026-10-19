import XCTest
import AppKit
@testable import VisionMacApp
@testable import VisionHarnessCore

/// Copying from a chat (`MessageCopy`): a prompt exactly as sent, a reply as written, a tool's output; the pasteboard
/// and the "Copied" that follows; and what Edit ▸ Copy Message (⇧⌘C) takes.
@MainActor
final class MessageCopyTests: XCTestCase {
    func testACopyIsTheMessageExactly() {
        let prompt = "  Fix the importer:\n\tquoted, commas \"here\"\n\n— and émoji 😀 \n"
        let entry = ChatEntry(kind: .message(MessageBody(role: .user, text: prompt)))
        XCTAssertEqual(MessageCopy.text(for: entry), prompt, "whitespace, tabs, quotes and the last line break kept")
        XCTAssertEqual(MessageCopy.noun(for: entry), "Prompt")
        let reply = ChatEntry(kind: .message(MessageBody(role: .assistant, text: "**Done.**")))
        XCTAssertEqual(MessageCopy.text(for: reply), "**Done.**", "a reply copies as written (markdown)")
        XCTAssertEqual(MessageCopy.noun(for: reply), "Reply")

        let tool = ChatEntry(kind: .tool(ToolActivity(name: "run_command", preview: "make test", output: "ok\n", isOk: true)))
        XCTAssertEqual(MessageCopy.text(for: tool), "ok\n")
        let running = ChatEntry(kind: .tool(ToolActivity(name: "run_command", preview: "make test")))
        XCTAssertEqual(MessageCopy.text(for: running), "make test")
        let plan = ChatEntry(kind: .todos([TodoItem(id: "1", content: "Read", status: .completed),
                                           TodoItem(id: "2", content: "Write", status: .pending)]))
        XCTAssertEqual(MessageCopy.text(for: plan), "- [x] Read\n- [ ] Write")
        XCTAssertEqual(MessageCopy.text(for: ChatEntry(kind: .compaction(CompactionNote(removed: 3, summary: "")))), nil)
    }

    func testCopyingPutsItOnThePasteboardAndSaysCopied() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vision.tests.copy.\(UUID().uuidString)"))
        let general = MessageCopy.pasteboard
        MessageCopy.pasteboard = pasteboard
        defer {
            MessageCopy.pasteboard = general
            pasteboard.releaseGlobally()
        }
        let huge = (1...10_000).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(MessageCopy.copy(huge, feedbackID: "entry:x"))
        XCTAssertEqual(pasteboard.string(forType: .string), huge)
        XCTAssertEqual(CopyFeedback.shared.copiedID, "entry:x")
        let cleared = expectation(description: "Copied goes away")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            XCTAssertNil(CopyFeedback.shared.copiedID)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 5)
    }

    func testCopyMessageTakesTheSelectedRowOrTheLastPrompt() {
        let vm = SessionVM(id: "s", title: "S", cwd: nil)
        XCTAssertNil(MessageCopy.menuTarget(in: vm), "nothing to copy yet")
        XCTAssertNil(MessageCopy.menuTarget(in: nil))
        let first = vm.appendMessage(.user, "first prompt")
        vm.appendMessage(.assistant, "first reply")
        let second = vm.appendMessage(.user, "second prompt")
        let reply = vm.appendMessage(.assistant, "second reply")
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.id, second)
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.text, "second prompt")
        vm.pager.selectedID = reply
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.text, "second reply")
        vm.pager.selectedID = first
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.text, "first prompt")
        vm.pager.selectedID = "gone"
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.text, "second prompt", "a selection that's gone falls back")
    }

    /// A goal's first round copies as the goal the person wrote; its later rounds are the app's, so Copy Message
    /// with nothing selected skips them to the goal.
    func testAGoalCopiesAsWrittenAndItsRoundsAreSkipped() {
        let goal = "Make the importer pass\n\nall of tests/import"
        for (queued, resuming) in [(false, false), (false, true), (true, false), (true, true)] {
            let shown = GoalTranscript.kickoff(goal, queued: queued, resuming: resuming)
            XCTAssertNotEqual(shown, goal)
            XCTAssertEqual(GoalTranscript.goal(inKickoff: shown), goal, "queued \(queued), resuming \(resuming)")
            let entry = ChatEntry(kind: .message(MessageBody(role: .user, text: shown)))
            XCTAssertEqual(MessageCopy.text(for: entry), goal)
        }
        XCTAssertEqual(GoalTranscript.kickoff("x", queued: false, resuming: false), "🎯 /goal x")
        XCTAssertEqual(GoalTranscript.kickoff("x", queued: true, resuming: true), "🚀 queue (resuming): x")
        XCTAssertNil(GoalTranscript.goal(inKickoff: "an ordinary prompt"))
        let reply = ChatEntry(kind: .message(MessageBody(role: .assistant, text: "🎯 /goal quoted in a reply")))
        XCTAssertEqual(MessageCopy.text(for: reply), "🎯 /goal quoted in a reply", "only a prompt is read as a goal")

        let vm = SessionVM(id: "g", title: "G", cwd: nil)
        let kickoff = vm.appendMessage(.user, GoalTranscript.kickoff(goal, queued: false, resuming: false))
        vm.appendMessage(.assistant, "working")
        vm.appendMessage(.user, GoalTranscript.round(2, recovering: false))
        vm.appendMessage(.user, GoalTranscript.round(3, recovering: true))
        XCTAssertTrue(GoalTranscript.isRound(GoalTranscript.round(3, recovering: true)))
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.id, kickoff)
        XCTAssertEqual(MessageCopy.menuTarget(in: vm)?.text, goal)
        XCTAssertEqual(AppTransport.lastGoal(in: vm.entries), goal.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A prompt that carried a big paste (a "Pasted text" chip) copies with all of the paste after what was typed —
    /// exactly what was sent; a file's chip isn't part of what the person wrote, so it stays out.
    func testAPromptWithAPastedTextChipCopiesThePasteToo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AttachmentStore(directory: folder)
        let paste = (1...5_000).map { "log line \($0)" }.joined(separator: "\n")
        let pastedName = try store.save(name: "pasted-text.txt", digest: XCTUnwrap(AttachmentReader.pasted(paste).digest),
                                        partChars: 20_000)
        let fileName = try store.save(name: "notes.txt", digest: AttachmentDigest(format: .text, lines: 1, bytes: 5, text: "notes"),
                                      partChars: 20_000)
        let pasteChip = AttachmentBadge(name: "pasted-text.txt", label: "Pasted text · 5,000 lines", stored: pastedName)
        let fileChip = AttachmentBadge(name: "notes.txt", label: "Text · 1 line", stored: fileName)
        let read: (AttachmentBadge) -> String? = { MessageCopy.pastedText($0, store: store) }

        let prompt = ChatEntry(kind: .message(MessageBody(role: .user, text: "Why does this fail?", attachments: [pasteChip, fileChip])))
        XCTAssertEqual(MessageCopy.text(for: prompt, pasted: read), "Why does this fail?\n\n" + paste)
        XCTAssertEqual(MessageCopy.text(for: prompt), "Why does this fail?", "without the store: what was typed")
        let pasteOnly = ChatEntry(kind: .message(MessageBody(role: .user, text: "", attachments: [pasteChip])))
        XCTAssertEqual(MessageCopy.text(for: pasteOnly, pasted: read), paste)
        let goal = ChatEntry(kind: .message(MessageBody(
            role: .user, text: GoalTranscript.kickoff("Make the build pass", queued: false, resuming: false), attachments: [pasteChip])))
        XCTAssertEqual(MessageCopy.text(for: goal, pasted: read), "Make the build pass\n\n" + paste)
        let unsaved = ChatEntry(kind: .message(MessageBody(
            role: .user, text: "still reading", attachments: [AttachmentBadge(name: "pasted-text.txt", label: "Pasted text")])))
        XCTAssertEqual(MessageCopy.text(for: unsaved, pasted: read), "still reading", "a chip not saved yet adds nothing")

        // Edit ▸ Copy Message gives the same.
        let vm = SessionVM(id: "p", title: "P", cwd: nil)
        vm.appendMessage(.user, "Why does this fail?", attachments: [pasteChip, fileChip])
        vm.appendMessage(.assistant, "The linker step.")
        vm.appendMessage(.user, TurnValidation.loopBackDisplay(attempt: 2))
        XCTAssertEqual(MessageCopy.menuTarget(in: vm, pasted: read)?.text, "Why does this fail?\n\n" + paste,
                       "a validation loop-back is the app's row, skipped like a goal's round")
    }
}
