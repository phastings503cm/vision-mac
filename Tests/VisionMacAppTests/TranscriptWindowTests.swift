import XCTest
@testable import VisionMacApp

/// Which transcript rows are drawn (`TranscriptWindow`): the newest page on opening, pages added above and below,
/// never more than `maxRows`, jumps, and rows arriving while the person follows the end or reads further up.
final class TranscriptWindowTests: XCTestCase {
    private func ids(_ count: Int, prefix: String = "r") -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    func testAnEmptyChatDrawsNothing() {
        let window = TranscriptWindow()
        XCTAssertEqual(window.range(in: [String]()), 0..<0)
        XCTAssertEqual(window.hiddenBefore(in: [String]()), 0)
        XCTAssertEqual(window.hiddenAfter(in: [String]()), 0)
    }

    func testAChatOpensOnItsNewestPage() {
        let window = TranscriptWindow()
        let rows = ids(2_000)
        XCTAssertEqual(window.range(in: rows), 1_950..<2_000)
        XCTAssertEqual(window.hiddenBefore(in: rows), 1_950)
        XCTAssertEqual(window.hiddenAfter(in: rows), 0)
        XCTAssertTrue(window.reachesEnd)
        XCTAssertTrue(window.isLatestPage)
        // A short chat is drawn whole.
        XCTAssertEqual(window.range(in: ids(12)), 0..<12)
    }

    func testTheNewestPageMovesAlongAsRowsArriveWhileFollowed() {
        let window = TranscriptWindow(pageSize: 10, maxRows: 30)
        XCTAssertEqual(window.range(in: ids(25)), 15..<25)
        XCTAssertEqual(window.range(in: ids(26)), 16..<26, "the newest row is drawn, the window stays one page")
    }

    func testPinnedRowsStayPutWhileRowsArrive() {
        var window = TranscriptWindow(pageSize: 10, maxRows: 30)
        var rows = ids(25)
        window.pin(in: rows)
        rows += ids(5, prefix: "new")
        XCTAssertEqual(window.range(in: rows), 15..<30, "the first drawn row stays; the new rows join below")
        XCTAssertFalse(window.isLatestPage)
        XCTAssertTrue(window.reachesEnd)
    }

    func testLoadingEarlierAddsAPageAboveAndNeverDrawsMoreThanMaxRows() {
        var window = TranscriptWindow(pageSize: 50, maxRows: 150)
        let rows = ids(2_000)
        XCTAssertTrue(window.loadEarlier(in: rows))
        XCTAssertEqual(window.range(in: rows), 1_900..<2_000)
        XCTAssertTrue(window.loadEarlier(in: rows))
        XCTAssertEqual(window.range(in: rows), 1_850..<2_000)
        XCTAssertTrue(window.reachesEnd)
        XCTAssertTrue(window.loadEarlier(in: rows))
        XCTAssertEqual(window.range(in: rows), 1_800..<1_950, "the bottom page is let go")
        XCTAssertFalse(window.reachesEnd)
        XCTAssertEqual(window.hiddenAfter(in: rows), 50)
        // All the way up.
        while window.loadEarlier(in: rows) {}
        XCTAssertEqual(window.range(in: rows), 0..<150)
        XCTAssertFalse(window.loadEarlier(in: rows), "nothing above the first row")
    }

    func testLoadingLaterComesBackDownToTheEnd() {
        var window = TranscriptWindow(pageSize: 50, maxRows: 150)
        let rows = ids(2_000)
        while window.loadEarlier(in: rows) {}
        XCTAssertTrue(window.loadLater(in: rows))
        XCTAssertEqual(window.range(in: rows), 50..<200, "a page below, the top page let go")
        while window.loadLater(in: rows) {}
        XCTAssertEqual(window.range(in: rows), 1_850..<2_000)
        XCTAssertTrue(window.reachesEnd, "back at the end it takes in new rows again")
        XCTAssertFalse(window.loadLater(in: rows))
    }

    func testRevealDrawsThePageAroundARow() {
        var window = TranscriptWindow(pageSize: 50, maxRows: 150)
        let rows = ids(2_000)
        XCTAssertTrue(window.reveal("r600", in: rows))
        XCTAssertEqual(window.range(in: rows), 575..<625)
        XCTAssertTrue(window.contains("r600", in: rows))
        XCTAssertFalse(window.reachesEnd)
        XCTAssertFalse(window.reveal("r610", in: rows), "already drawn: nothing moves")
        XCTAssertFalse(window.reveal("missing", in: rows))

        XCTAssertTrue(window.reveal("r3", in: rows))
        XCTAssertEqual(window.range(in: rows), 0..<50, "near the start: the first page")
        XCTAssertTrue(window.reveal("r1990", in: rows))
        XCTAssertEqual(window.range(in: rows), 1_950..<2_000, "near the end: the last page")
        XCTAssertTrue(window.reachesEnd)
    }

    func testShowLatestGoesBackToTheNewestPage() {
        var window = TranscriptWindow()
        let rows = ids(2_000)
        window.reveal("r10", in: rows)
        window.showLatest()
        XCTAssertEqual(window.range(in: rows), 1_950..<2_000)
        XCTAssertTrue(window.isLatestPage)
    }

    func testRowsArrivingPastMaxRows() {
        // Following the end: back to the newest page.
        var following = TranscriptWindow(pageSize: 10, maxRows: 30)
        var rows = ids(25)
        following.pin(in: rows)
        rows += ids(25, prefix: "new")
        XCTAssertEqual(following.range(in: rows).count, 35)
        XCTAssertTrue(following.settleAfterRowsArrived(in: rows, following: true))
        XCTAssertEqual(following.range(in: rows), 40..<50)

        // Reading further up: the window stops where it is; the new rows wait below.
        var reading = TranscriptWindow(pageSize: 10, maxRows: 30)
        rows = ids(25)
        reading.pin(in: rows)
        rows += ids(25, prefix: "new")
        XCTAssertTrue(reading.settleAfterRowsArrived(in: rows, following: false))
        XCTAssertEqual(reading.range(in: rows), 15..<45)
        XCTAssertFalse(reading.reachesEnd)
        rows += ids(5, prefix: "more")
        XCTAssertEqual(reading.range(in: rows), 15..<45, "nothing moves while they read")
        XCTAssertFalse(reading.settleAfterRowsArrived(in: rows, following: false))
    }

    func testARemovedRowIsStoodInForByItsPosition() {
        var window = TranscriptWindow(pageSize: 10, maxRows: 30)
        var rows = ids(100)
        window.reveal("r50", in: rows)
        XCTAssertEqual(window.range(in: rows), 45..<55)
        rows.remove(at: 45)   // the first drawn row goes (a plan card moved to the end)
        let range = window.range(in: rows)
        XCTAssertEqual(range.lowerBound, 45, "its last known position")
        XCTAssertEqual(range.upperBound, 54, "the last drawn row is still found by its id")
    }

    /// Any sequence of moves and arrivals leaves a sensible window: inside the rows, never empty when there are
    /// rows, at most `maxRows` after loads and jumps.
    func testRandomMovesKeepTheWindowSound() {
        var generator = SplitMix(seed: 42)
        for _ in 0..<200 {
            var window = TranscriptWindow(pageSize: 1 + Int(generator.next() % 20), maxRows: 40 + Int(generator.next() % 40))
            var rows = ids(Int(generator.next() % 300))
            var serial = 0
            for _ in 0..<60 {
                switch generator.next() % 8 {
                case 0: window.loadEarlier(in: rows)
                case 1: window.loadLater(in: rows)
                case 2: if !rows.isEmpty { window.reveal(rows[Int(generator.next() % UInt64(rows.count))], in: rows) }
                case 3: window.showLatest()
                case 4: window.pin(in: rows)
                case 5:
                    rows += (0..<Int(generator.next() % 30)).map { _ in serial += 1; return "n\(serial)" }
                    window.settleAfterRowsArrived(in: rows, following: generator.next() % 2 == 0)
                case 6: if !rows.isEmpty { rows.remove(at: Int(generator.next() % UInt64(rows.count))) }
                default: window.settleAfterRowsArrived(in: rows, following: true)
                }
                let range = window.range(in: rows)
                XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
                XCTAssertLessThanOrEqual(range.upperBound, rows.count)
                if !rows.isEmpty { XCTAssertFalse(range.isEmpty, "rows exist but none drawn") }
            }
            window.settleAfterRowsArrived(in: rows, following: true)
            XCTAssertLessThanOrEqual(window.range(in: rows).count, window.maxRows)
        }
    }
}

/// A small seeded generator, so the random test is the same every run.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
