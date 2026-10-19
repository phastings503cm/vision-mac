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
}
