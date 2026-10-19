import XCTest
@testable import VisionHarnessCore

/// A chat's own tasks live in the same store as the unattended queue but never run there; they keep their order
/// within their chat, survive a round trip through the file, and end the way their prompt ended.
final class ChatTasksTests: XCTestCase {
    // MARK: The store

    func testChatTasksQueueInOrderPerChatAndStayOutOfTheUnattendedQueue() {
        var q = TaskQueue()
        let unattended = q.add("Nightly cleanup")
        let a1 = q.addChatTask("Run the suite\nand paste the summary", chatID: "A")
        let b1 = q.addChatTask("Write the notes", chatID: "B")
        let a2 = q.addChatTask("Bump the version", chatID: "A")

        XCTAssertEqual(a1.title, "Run the suite")
        XCTAssertEqual(a1.promptText, "Run the suite\nand paste the summary")
        XCTAssertEqual(a1.chatID, "A")
        XCTAssertEqual(a1.sessionID, "A", "it runs in its own chat")
        XCTAssertTrue(a1.isChatTask)

        XCTAssertEqual(q.nextTask?.id, unattended.id, "the queue runner sees only its own tasks")
        XCTAssertEqual(q.queuedCount, 1)
        XCTAssertEqual(q.unattended.tasks.map(\.id), [unattended.id])
        XCTAssertEqual(q.nextChatTask("A")?.id, a1.id)
        XCTAssertEqual(q.nextChatTask("B")?.id, b1.id)
        XCTAssertEqual(q.queuedChatTaskCount("A"), 2)
        XCTAssertEqual(q.chatsWithQueuedTasks, ["A", "B"])
        XCTAssertEqual(q.position(of: a2.id), 2, "positions count within the chat")
        XCTAssertEqual(q.position(of: unattended.id), 1)
        XCTAssertEqual(a2.log.first?.text, "Added to the chat's tasks at #2")
    }

    func testAChatTaskWithTheQueueEmptyIsNotWorkedByTheRunner() {
        var q = TaskQueue()
        q.addChatTask("Only in a chat", chatID: "A")
        XCTAssertNil(q.nextTask)
        XCTAssertNil(q.runningTask)
        XCTAssertFalse(q.hasRunning)
        XCTAssertEqual(q.unattended.stats().queued, 0)
    }

    func testFrontMovesAndRemovalStayWithinTheChat() {
        var q = TaskQueue()
        let a1 = q.addChatTask("one", chatID: "A")
        let b1 = q.addChatTask("b one", chatID: "B")
        let a2 = q.addChatTask("two", chatID: "A")
        let a3 = q.addChatTask("three", chatID: "A")
        let front = q.addChatTask("urgent", chatID: "A", atFront: true)
        XCTAssertEqual(q.chatTasks("A").map(\.id), [front.id, a1.id, a2.id, a3.id])

        q.moveWithinChat(id: a3.id, by: -2)
        XCTAssertEqual(q.chatTasks("A").map(\.id), [front.id, a3.id, a1.id, a2.id])
        q.moveWithinChat(id: front.id, by: 10)
        XCTAssertEqual(q.chatTasks("A").map(\.id), [a3.id, a1.id, a2.id, front.id])
        q.moveWithinChat(id: a3.id, by: -1)
        XCTAssertEqual(q.chatTasks("A").map(\.id), [a3.id, a1.id, a2.id, front.id], "already first")
        XCTAssertEqual(q.chatTasks("B").map(\.id), [b1.id], "the other chat is untouched")

        q.start(a3.id, sessionID: "A")
        XCTAssertEqual(q.runningChatTask("A")?.id, a3.id)
        XCTAssertEqual(q.nextChatTask("A")?.id, a1.id)
        q.removeChatTasks("A")
        XCTAssertEqual(q.chatTasks("A").map(\.status), [.skipped], "the running one keeps its record")
        XCTAssertEqual(q.chatTasks("B").count, 1)
    }

    func testTheListShowsRunningThenWaitingThenFinishedNewestFirst() {
        var q = TaskQueue()
        let a = q.addChatTask("a", chatID: "A")
        let b = q.addChatTask("b", chatID: "A")
        let c = q.addChatTask("c", chatID: "A")
        let d = q.addChatTask("d", chatID: "A")
        q.start(a.id, sessionID: "A")
        q.finish(a.id, status: .complete)
        q.start(b.id, sessionID: "A")
        q.finish(b.id, status: .failed, reason: "boom")
        q.start(c.id, sessionID: "A")
        XCTAssertEqual(q.chatTasks("A").map(\.id), [c.id, d.id, b.id, a.id])
    }

    func testChatTasksSurviveTheFileAndOldFilesStillRead() throws {
        var q = TaskQueue()
        q.add("unattended")
        q.addChatTask("chat one", chatID: "A")
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(TaskQueue.self, from: data)
        XCTAssertEqual(back, q)
        XCTAssertEqual(back.chatTasks("A").first?.promptText, "chat one")

        // A file written before chat tasks existed: no chatID key, every task is the unattended queue's.
        let old = #"{"tasks":[{"id":"x","title":"old task","status":"queued","enteredAt":0,"log":[]}]}"#
        let decoded = try JSONDecoder().decode(TaskQueue.self, from: Data(old.utf8))
        XCTAssertNil(decoded.tasks.first?.chatID)
        XCTAssertEqual(decoded.nextTask?.id, "x")
    }

    func testALongFirstLineMakesAShortTitle() {
        var q = TaskQueue()
        let long = String(repeating: "word ", count: 40)
        let task = q.addChatTask("  \n" + long + "\nsecond line", chatID: "A")
        XCTAssertEqual(task.title.count, 80)
        XCTAssertTrue(task.title.hasSuffix("…"))
        XCTAssertTrue(task.promptText.hasSuffix("second line"))
    }

    // MARK: Rules

    func testHowAFinishedPromptLeavesItsTaskAndTheList() {
        XCTAssertEqual(ChatTaskRules.status(for: .completed), .complete)
        XCTAssertEqual(ChatTaskRules.status(for: .issues), .complete)
        XCTAssertEqual(ChatTaskRules.status(for: .needsYou), .blocked)
        XCTAssertEqual(ChatTaskRules.status(for: .failed), .failed)
        XCTAssertEqual(ChatTaskRules.status(for: .stopped), .skipped)

        XCTAssertTrue(ChatTaskRules.continuesAfter(.completed))
        XCTAssertTrue(ChatTaskRules.continuesAfter(.issues))
        XCTAssertFalse(ChatTaskRules.continuesAfter(.stopped))
        XCTAssertFalse(ChatTaskRules.continuesAfter(.failed))
        XCTAssertFalse(ChatTaskRules.continuesAfter(.needsYou))

        XCTAssertEqual(ChatTaskRules.pauseReason(for: .stopped), "Paused — you stopped the current work.")
        XCTAssertEqual(ChatTaskRules.pauseReason(for: .failed), "Paused — the last task failed.")
        XCTAssertEqual(ChatTaskRules.pauseReason(for: .needsYou), "Paused — the agent needs you.")
    }

    // MARK: Which step a subagent works

    func testASubagentIsMatchedToTheStepItsWordsName() {
        let todos = [
            TodoItem(id: "1", content: "Read how report rows are built", status: .completed),
            TodoItem(id: "2", content: "Wire --format csv into the CLI", status: .inProgress),
            TodoItem(id: "3", content: "Write tests for the CSV output", status: .inProgress),
            TodoItem(id: "4", content: "Update the README", status: .pending),
        ]
        XCTAssertEqual(PlanAssignment.step(description: "CSV tests", prompt: "Add unit tests covering the csv writer", todos: todos),
                       "Write tests for the CSV output")
        XCTAssertEqual(PlanAssignment.step(description: "readme", todos: todos), "Update the README")
        XCTAssertEqual(PlanAssignment.step(description: "Wire the CLI flag", todos: todos), "Wire --format csv into the CLI")
        // Words that match a finished step only: no open step named, two in progress — no guess.
        XCTAssertNil(PlanAssignment.step(description: "report rows", todos: todos))
        // One step in progress: that one.
        let single = [TodoItem(id: "1", content: "Fix the importer", status: .inProgress),
                      TodoItem(id: "2", content: "Ship", status: .pending)]
        XCTAssertEqual(PlanAssignment.step(description: "look around", todos: single), "Fix the importer")
        XCTAssertNil(PlanAssignment.step(description: "anything", todos: []))
    }

    // MARK: git status

    func testGitStatusIsRead() {
        let porcelain = """
        ## main...origin/main [ahead 2, behind 1]
         M ledger/report.py
        M  ledger/cli.py
        A  tests/test_csv.py
         D old.txt
        R  a.py -> b.py
        ?? notes/todo.md
        UU merge.txt
        ?? "with space.txt"
        """
        let status = GitStatusSummary.parse(porcelain: porcelain)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.files.map(\.path), ["ledger/report.py", "ledger/cli.py", "tests/test_csv.py", "old.txt",
                                                  "b.py", "notes/todo.md", "merge.txt", "with space.txt"])
        XCTAssertEqual(status.files.map(\.label), ["modified", "modified", "added", "deleted", "renamed", "untracked",
                                                   "conflicted", "untracked"])
        XCTAssertEqual(status.files.map(\.letter), ["M", "M", "A", "D", "R", "U", "!", "U"])
        XCTAssertEqual(status.files.map(\.staged), [false, true, true, false, true, false, true, false])
        XCTAssertEqual(status.summary, "main · 8 changed · ↑2 · ↓1")
    }

    func testGitStatusBranchShapes() {
        XCTAssertEqual(GitStatusSummary.parse(porcelain: "## main\n").summary, "main · clean")
        XCTAssertEqual(GitStatusSummary.parse(porcelain: "## No commits yet on trunk\n?? a\n").branch, "trunk")
        let detached = GitStatusSummary.parse(porcelain: "## HEAD (no branch)\n")
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.summary, "detached · clean")
        XCTAssertTrue(GitStatusSummary.parse(porcelain: "## feature...origin/feature [behind 3]\n").behind == 3)
    }
}
