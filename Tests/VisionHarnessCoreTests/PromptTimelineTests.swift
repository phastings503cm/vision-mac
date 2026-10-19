import XCTest
@testable import VisionHarnessCore

/// The Prompts timeline's rules: the words each outcome is shown with, timing against the estimate, day groups,
/// search, the quote "Add to composer" writes, finding a prompt's row again, backfilling old chats, and the file.
final class PromptTimelineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    /// Monday 19 Oct 2026, 09:30 Pacific.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9, minute: 30))!
    }

    // MARK: Words

    func testEachOutcomeHasItsOwnWords() {
        func headline(_ outcome: PromptRecord.Outcome, evidence: Int = 0) -> String {
            var record = PromptRecord(chatID: "c", text: "t", outcome: outcome)
            record.evidence = (0..<evidence).map { _ in .init(kind: .check, title: "e", detail: "") }
            return record.headline
        }
        XCTAssertEqual(headline(.completed, evidence: 2), "Completed with results")
        XCTAssertEqual(headline(.completed), "Completed")
        XCTAssertEqual(headline(.issues), "Finished with issues")
        XCTAssertEqual(headline(.needsYou), "Needs you")
        XCTAssertEqual(headline(.failed), "Failed")
        XCTAssertEqual(headline(.stopped), "Stopped")
        XCTAssertEqual(headline(.running), "Running")
        XCTAssertEqual(headline(.queued), "Queued")
        XCTAssertEqual(headline(.unknown), "Outcome not recorded")
        XCTAssertTrue(PromptRecord.Outcome.running.isOpen)
        XCTAssertTrue(PromptRecord.Outcome.queued.isOpen)
        XCTAssertFalse(PromptRecord.Outcome.failed.isOpen)
    }

    func testTimingSaysDurationAgainstTheEstimateAttemptsAndEvidence() {
        var record = PromptRecord(chatID: "c", text: "t", at: now, outcome: .completed,
                                  finishedAt: now.addingTimeInterval(312), etaSeconds: 240, attempts: 2, rounds: 3)
        record.evidence = [.init(kind: .file, title: "2 files changed", detail: "")]
        XCTAssertEqual(PromptTimeline.timing(record), "5m 12s · est. about 4 min · 2 attempts · 3 rounds · 1 evidence item")
        XCTAssertEqual(PromptTimeline.versusEstimate(record), "1m 12s over the estimate")

        record.finishedAt = now.addingTimeInterval(250)
        XCTAssertEqual(PromptTimeline.versusEstimate(record), "on time")

        let running = PromptRecord(chatID: "c", text: "t", at: now, outcome: .running, etaSeconds: 60)
        XCTAssertEqual(PromptTimeline.timing(running, now: now.addingTimeInterval(100)), "running 1m 40s · est. about a minute")
        XCTAssertNil(running.durationSeconds)
    }

    // MARK: Days and search

    func testRecordsGroupByDayNewestFirst() {
        let records = [
            PromptRecord(id: "a", chatID: "c", text: "today early", at: now.addingTimeInterval(-3 * 3_600)),
            PromptRecord(id: "b", chatID: "c", text: "today late", at: now.addingTimeInterval(-60)),
            PromptRecord(id: "c", chatID: "c", text: "yesterday", at: now.addingTimeInterval(-86_400)),
            PromptRecord(id: "d", chatID: "c", text: "thursday", at: now.addingTimeInterval(-4 * 86_400)),
            PromptRecord(id: "e", chatID: "c", text: "weeks ago", at: now.addingTimeInterval(-20 * 86_400)),
            PromptRecord(id: "f", chatID: "c", text: "last year", at: now.addingTimeInterval(-400 * 86_400)),
        ]
        let groups = PromptTimeline.grouped(records, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Thursday", "Sep 29", "Sep 14, 2025"])
        XCTAssertEqual(groups[0].records.map(\.id), ["b", "a"])
    }

    func testSearchMatchesEveryWordInTextNotesOutcomeOrChatTitle() {
        var a = PromptRecord(id: "a", chatID: "c1", text: "Fix the login crash", outcome: .failed)
        a.reason = "Xcode refused the signing identity"
        let b = PromptRecord(id: "b", chatID: "c2", text: "Write release notes", outcome: .completed)
        let titles = ["c2": "Ledger 0.3.0"]
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "LOGIN crash").map(\.id), ["a"])
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "signing").map(\.id), ["a"])
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "failed").map(\.id), ["a"])
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "ledger notes", chatTitles: titles).map(\.id), ["b"])
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "  ").map(\.id), ["a", "b"])
        XCTAssertEqual(PromptTimeline.filter([a, b], query: "login notes").map(\.id), [])
    }

    // MARK: Talking about an earlier prompt

    func testTheQuoteCarriesWhenItRanHowItEndedAndTheResults() {
        var record = PromptRecord(chatID: "c", text: "Pull Q3 revenue by clinic\nand chart it", at: now,
                                  outcome: .completed, finishedAt: now.addingTimeInterval(312))
        record.evidence = [.init(kind: .runOutput, title: "Query ran — 14 clinics", detail: "")]
        record.completionNote = "Validated against the plan: 3 of 3 steps done.\n\nThe chart is in q3.png."
        let quote = PromptTimeline.quote(record, calendar: calendar)
        XCTAssertEqual(quote, """
            About my earlier prompt (sent Oct 19 at 09:30 — Completed with results, 5m 12s):
            > Pull Q3 revenue by clinic
            > and chart it
            Outcome: Query ran — 14 clinics · Validated against the plan: 3 of 3 steps done.


            """)
    }

    func testALongPromptIsQuotedInPartAndAFailureSaysWhy() {
        let text = (1...30).map { "line \($0)" }.joined(separator: "\n")
        var record = PromptRecord(chatID: "c", text: text, source: .goal, at: now, outcome: .failed)
        record.reason = "the build broke"
        let quote = PromptTimeline.quote(record, calendar: calendar)
        XCTAssertTrue(quote.hasPrefix("About my earlier goal (sent Oct 19 at 09:30 — Failed):"), quote)
        XCTAssertTrue(quote.contains("> line 12\n> …"), quote)
        XCTAssertFalse(quote.contains("line 13"))
        XCTAssertTrue(quote.contains("Outcome: the build broke"), quote)
    }

    // MARK: Jump

    func testARecordFindsItsRowByTextAndTime() {
        let record = PromptRecord(chatID: "c", text: "do it", at: now, entryText: "🎯 /goal do it", entryAt: now)
        let rows = [
            PromptTimeline.EntryRef(id: "old", text: "🎯 /goal do it", at: now.addingTimeInterval(-3_600)),
            PromptTimeline.EntryRef(id: "this", text: "🎯 /goal do it", at: now.addingTimeInterval(0.004)),
            PromptTimeline.EntryRef(id: "other", text: "something else", at: now),
        ]
        XCTAssertEqual(PromptTimeline.matchEntry(record, in: rows), "this")

        // From before the row text was recorded: the first line inside a longer row.
        let legacy = PromptRecord(chatID: "c", text: "Ship it\nwith notes", at: now)
        XCTAssertEqual(PromptTimeline.matchEntry(legacy, in: [
            PromptTimeline.EntryRef(id: "x", text: "Ship it\nwith notes", at: now.addingTimeInterval(1)),
        ]), "x")
        XCTAssertNil(PromptTimeline.matchEntry(legacy, in: [PromptTimeline.EntryRef(id: "y", text: "nope", at: now)]))
    }

    // MARK: Backfill

    func testAnOldTranscriptBecomesOneRecordPerPromptWithItsEnding() {
        let t0 = now
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
        let rows: [PromptTimeline.Row] = [
            .init(kind: "user", text: "What does this do?", at: at(0)),
            .init(kind: "assistant", text: "It parses CSV.", at: at(20)),
            .init(kind: "user", text: "🎯 /goal Make the tests pass", at: at(60)),
            .init(kind: "tool", text: "ran tests", at: at(90)),
            .init(kind: "user", text: "↻ round 2: keep going", at: at(120)),
            .init(kind: "assistant", text: "All green.\nGOAL_COMPLETE", at: at(200)),
            .init(kind: "notice", text: "✅ Goal complete after 2 rounds.", at: at(201)),
            .init(kind: "user", text: "Refactor the parser", at: at(300)),
            .init(kind: "notice", text: "Stopped.", at: at(330)),
            .init(kind: "user", text: "🤖 Background agents finished — continuing", at: at(340)),
            .init(kind: "user", text: "🚀 queue: Nightly cleanup", at: at(400)),
            .init(kind: "error", text: "The server refused the request (400).", at: at(410)),
            .init(kind: "user", text: "/deploy staging", at: at(500)),
            .init(kind: "notice", text: "⏸ Goal paused — the agent needs you: which region?", at: at(520)),
            .init(kind: "user", text: "No answer yet", at: at(600)),
        ]
        let records = PromptTimeline.backfill(chatID: "chat", rows: rows)
        XCTAssertEqual(records.map(\.text), ["What does this do?", "Make the tests pass", "Refactor the parser",
                                             "Nightly cleanup", "/deploy staging", "No answer yet"])
        XCTAssertEqual(records.map(\.source), [.typed, .goal, .typed, .queue, .skill, .typed])
        XCTAssertEqual(records.map(\.outcome), [.completed, .completed, .stopped, .failed, .needsYou, .unknown])
        XCTAssertEqual(records[0].durationSeconds, 20)
        XCTAssertEqual(records[1].durationSeconds, 141)
        XCTAssertEqual(records[1].rounds, 2)
        XCTAssertEqual(records[1].completionNote, "All green.\nGOAL_COMPLETE")
        XCTAssertEqual(records[3].reason, "The server refused the request (400).")
        XCTAssertNil(records[5].finishedAt)
        XCTAssertTrue(records.allSatisfy { $0.backfilled && $0.chatID == "chat" })
        XCTAssertEqual(records[1].entryText, "🎯 /goal Make the tests pass")
    }

    // MARK: The file

    func testTheStoreRoundTripsWithISODatesAndSetsAsideWhatItCannotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptTimelineStore(directory: dir)
        XCTAssertNil(store.load("chat-1"), "no file yet: backfill it")

        let at = Date(timeIntervalSince1970: 1_792_000_000.5)
        var record = PromptRecord(id: "r1", chatID: "chat-1", text: "hello", source: .task, at: at, outcome: .completed,
                                  finishedAt: at.addingTimeInterval(61), etaSeconds: 75, attempts: 2, model: "m", route: "r")
        record.evidence = [.init(id: "e1", kind: .screenshot, title: "shot", detail: "d", at: at)]
        store.save("chat-1", [record])

        let raw = try String(contentsOf: store.fileURL("chat-1"), encoding: .utf8)
        XCTAssertTrue(raw.contains(#""schema":"vision.prompts\/1""#) || raw.contains(#""schema":"vision.prompts/1""#), raw)
        XCTAssertTrue(raw.contains(#""at":"2026-10-14T17:46:40.500Z""#), "ISO-8601 dates with milliseconds: \(raw)")
        let back = try XCTUnwrap(store.load("chat-1"))
        XCTAssertEqual(back, [record])
        XCTAssertEqual(store.chatIDs(), ["chat-1"])

        try Data("not json".utf8).write(to: store.fileURL("chat-2"))
        XCTAssertNil(store.load("chat-2"))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("chat-2.unreadable-") }, "\(names)")
        XCTAssertEqual(store.chatIDs(), ["chat-1"])

        store.delete("chat-1")
        XCTAssertNil(store.load("chat-1"))
    }

    func testAFileFromAnotherBuildStillReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"""
        {"schema":"vision.prompts/1","chatID":"w","prompts":[
          {"id":"a","chatID":"w","text":"from Windows","source":"brandNewSource","at":"2026-10-18T22:01:02.500Z",
           "outcome":"somethingNew","finishedAt":1792000000,"futureField":true}
        ]}
        """#
        try Data(json.utf8).write(to: dir.appendingPathComponent("w.json"))
        let record = try XCTUnwrap(PromptTimelineStore(directory: dir).load("w")?.first)
        XCTAssertEqual(record.text, "from Windows")
        XCTAssertEqual(record.source, .typed)
        XCTAssertEqual(record.outcome, .unknown)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(record.finishedAt, Date(timeIntervalSince1970: 1_792_000_000))
    }

    func testAChatKeepsItsNewestFiveHundred() {
        let records = (0..<520).map { PromptRecord(id: "\($0)", chatID: "c", text: "p", at: Date(timeIntervalSince1970: Double($0))) }
        let kept = PromptTimeline.capped(records.shuffled())
        XCTAssertEqual(kept.count, 500)
        XCTAssertEqual(kept.first?.id, "20")
        XCTAssertEqual(kept.last?.id, "519")
    }

    func testAChatIDBecomesASafeFileName() {
        XCTAssertEqual(PromptTimelineStore.safeName("5A1C0E8B-6D4F"), "5A1C0E8B-6D4F")
        XCTAssertEqual(PromptTimelineStore.safeName("../../etc/passwd"), "______etc_passwd")
        XCTAssertEqual(PromptTimelineStore.safeName(""), "_")
    }
}
