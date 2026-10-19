import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// One chat's paged transcript (`TranscriptPager`): the drawn rows, loading a page keeps the reader's row in place,
/// following the end until the person scrolls up, pages loading when a bar scrolls into view, jumps.
@MainActor
final class TranscriptPagerTests: XCTestCase {
    private func chat(_ count: Int) -> [ChatEntry] {
        (0..<count).map { index in
            ChatEntry(id: "e\(index)", at: Date(timeIntervalSinceReferenceDate: Double(index) * 30),
                      kind: .message(MessageBody(role: index % 2 == 0 ? .user : .assistant, text: "message \(index)")))
        }
    }

    private func frames(viewport: CGFloat = 800, top: CGFloat, bottom: CGFloat, earlier: CGRect? = nil,
                        rows: [String: CGFloat] = [:]) -> TranscriptFrames {
        var frames = TranscriptFrames(viewport: viewport)
        frames.top = CGRect(x: 0, y: top, width: 700, height: 0)
        frames.bottom = CGRect(x: 0, y: bottom - 1, width: 700, height: 1)
        frames.earlierBar = earlier
        for (id, y) in rows { frames.rows[id] = CGRect(x: 0, y: y, width: 700, height: 0) }
        return frames
    }

    func testEachChatHasItsOwnPager() {
        let one = SessionVM(id: "a", title: "A", cwd: nil)
        let two = SessionVM(id: "b", title: "B", cwd: nil)
        XCTAssertFalse(one.pager === two.pager)
    }

    func testTheDrawnRowsAndTheOnesMeasured() {
        let pager = TranscriptPager()
        let entries = chat(2_000)
        let rows = pager.rows(of: entries)
        XCTAssertEqual(rows.entries.count, 50)
        XCTAssertEqual(rows.hiddenBefore, 1_950)
        XCTAssertEqual(rows.hiddenAfter, 0)
        XCTAssertEqual(rows.firstID, "e1950")
        XCTAssertTrue(pager.isWatched("e1950", in: rows))
        XCTAssertTrue(pager.isWatched("e1999", in: rows))
        XCTAssertFalse(pager.isWatched("e1975", in: rows))
    }

    func testLoadingEarlierKeepsTheTopRowWhereItWas() {
        let pager = TranscriptPager()
        let entries = chat(2_000)
        pager.observe(frames(top: -4_000, bottom: 810, rows: ["e1950": 82])) { entries }
        pager.loadEarlier(entries)
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_900)
        XCTAssertFalse(pager.following, "reading further up")
        let restore = try? XCTUnwrap(pager.restore)
        XCTAssertEqual(restore?.id, "e1950", "the row that was on top")
        XCTAssertEqual(restore?.minY, 82)
        XCTAssertEqual(restore?.unitY ?? 0, 82.0 / 800.0, accuracy: 0.0001)
        XCTAssertTrue(pager.isWatched("e1950", in: pager.rows(of: entries)), "measured until it is back in place")
        if let restore { pager.restoreDone(restore) }
        XCTAssertNil(pager.restore)
    }

    func testFollowingTheEndUntilThePersonScrollsUp() {
        let pager = TranscriptPager()
        let entries = chat(200)
        pager.settled = true
        pager.observe(frames(top: -3_000, bottom: 820)) { entries }
        XCTAssertTrue(pager.following)
        // Rows arrive below: the bottom moves down, the top doesn't — still following.
        pager.observe(frames(top: -3_000, bottom: 1_100)) { entries }
        XCTAssertTrue(pager.following)
        // The person scrolls up: the content's top moves down the screen.
        pager.observe(frames(top: -2_400, bottom: 1_700)) { entries }
        XCTAssertFalse(pager.following)
        XCTAssertFalse(pager.window.isLatestPage, "the drawn rows are pinned while they read")
        // Back at the end.
        pager.observe(frames(top: -3_300, bottom: 805)) { entries }
        XCTAssertTrue(pager.following)
    }

    func testTheAppsOwnScrollIsNotThePersons() {
        let pager = TranscriptPager()
        let entries = chat(200)
        pager.settled = true
        pager.observe(frames(top: -3_000, bottom: 820)) { entries }
        pager.scrollingByItself(for: 5)
        pager.observe(frames(top: -2_000, bottom: 1_820)) { entries }
        XCTAssertTrue(pager.following, "a jump or a kept row moving the view is not the person scrolling up")
    }

    func testTheEarlierBarLoadsItsPageWhenScrolledIntoView() {
        let pager = TranscriptPager()
        let entries = chat(2_000)
        pager.settled = true
        // Visible on opening: it doesn't load by itself (not out of view yet).
        pager.observe(frames(top: -10, bottom: 4_000, earlier: CGRect(x: 0, y: 20, width: 300, height: 28))) { entries }
        drainMainQueue()
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_950)
        // Out of view, then back in: it loads.
        pager.observe(frames(top: -2_000, bottom: 2_000, earlier: CGRect(x: 0, y: -1_990, width: 300, height: 28),
                             rows: ["e1950": -1_950])) { entries }
        pager.observe(frames(top: -10, bottom: 4_000, earlier: CGRect(x: 0, y: 20, width: 300, height: 28),
                             rows: ["e1950": 60])) { entries }
        drainMainQueue()
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_900)
        XCTAssertEqual(pager.restore?.id, "e1950")
    }

    /// Scrolled up fast: the bar came into view while the last page's restore was still going on. It loads once
    /// that is over, with no further scrolling.
    func testABarReachedDuringARestoreLoadsWhenItEnds() {
        let pager = TranscriptPager()
        let entries = chat(2_000)
        pager.settled = true
        pager.observe(frames(top: -10, bottom: 4_000, rows: ["e1950": 60])) { entries }
        pager.loadEarlier(entries)
        let restore = pager.restore
        XCTAssertNotNil(restore)
        pager.observe(frames(top: -2_000, bottom: 2_000, earlier: CGRect(x: 0, y: -1_990, width: 300, height: 28),
                             rows: ["e1950": 60])) { entries }
        pager.observe(frames(top: -10, bottom: 4_000, earlier: CGRect(x: 0, y: 20, width: 300, height: 28),
                             rows: ["e1950": 60])) { entries }
        drainMainQueue()
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_900, "not while the restore runs")
        if let restore { pager.restoreDone(restore) }
        let loaded = expectation(description: "the waiting bar loads")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_850)
    }

    func testNothingLoadsBeforeTheChatHasSettledAtItsEnd() {
        let pager = TranscriptPager()
        let entries = chat(2_000)
        pager.observe(frames(top: -2_000, bottom: 2_000, earlier: CGRect(x: 0, y: -1_990, width: 300, height: 28))) { entries }
        pager.observe(frames(top: -10, bottom: 4_000, earlier: CGRect(x: 0, y: 20, width: 300, height: 28))) { entries }
        drainMainQueue()
        XCTAssertEqual(pager.rows(of: entries).hiddenBefore, 1_950)
    }

    func testAJumpIsTakenOnce() {
        let pager = TranscriptPager()
        pager.jump(to: "e3")
        let first = pager.jump
        pager.jump(to: "e3")
        XCTAssertNotEqual(first, pager.jump, "the same row twice still jumps twice")
        XCTAssertEqual(pager.takeJump()?.id, "e3")
        XCTAssertNil(pager.jump)
    }

    func testResetGoesBackToTheNewestPage() {
        let pager = TranscriptPager()
        let entries = chat(500)
        pager.window.reveal("e10", in: entries.map(\.id))
        pager.following = false
        pager.selectedID = "e10"
        pager.settled = true
        pager.reset()
        XCTAssertTrue(pager.window.isLatestPage)
        XCTAssertTrue(pager.following)
        XCTAssertFalse(pager.settled)
        XCTAssertNil(pager.selectedID)
    }

    func testJumpFindsAGoalsAndAQueuedTasksPromptBehindTheirMarkers() {
        // The Prompts timeline's Jump goes through `PromptTimeline.matchEntry`: a goal and a queued task show their
        // prompt after a marker, and a record read back from an old transcript has no displayed text of its own.
        let at = Date(timeIntervalSinceReferenceDate: 100)
        let rows = [
            PromptTimeline.EntryRef(id: "goal", text: GoalTranscript.kickoff("ship it", queued: false, resuming: false), at: at),
            PromptTimeline.EntryRef(id: "task", text: GoalTranscript.kickoff("Fix login\n\nThe 2FA step", queued: true, resuming: false), at: at),
            PromptTimeline.EntryRef(id: "typed", text: "ship it later", at: at.addingTimeInterval(600)),
        ]
        let goal = PromptRecord(chatID: "c", text: "ship it", source: .goal, at: at,
                                entryText: GoalTranscript.kickoff("ship it", queued: false, resuming: false))
        XCTAssertEqual(PromptTimeline.matchEntry(goal, in: rows), "goal")
        let task = PromptRecord(chatID: "c", text: "Fix login\n\nThe 2FA step", source: .queue, at: at, backfilled: true)
        XCTAssertEqual(PromptTimeline.matchEntry(task, in: rows), "task")
    }

    private func drainMainQueue() {
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
