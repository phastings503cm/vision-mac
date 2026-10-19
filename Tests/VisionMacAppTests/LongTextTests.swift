import XCTest
@testable import VisionMacApp

/// Very long messages in the transcript (`LongText`): when one collapses, what its first and last lines are, and
/// that it never cuts a character in half.
final class LongTextTests: XCTestCase {
    private func lines(_ count: Int, _ make: (Int) -> String = { "line \($0)" }) -> String {
        (1...count).map(make).joined(separator: "\n")
    }

    func testOrdinaryMessagesStayWhole() {
        XCTAssertFalse(LongText.isLong(""))
        XCTAssertFalse(LongText.isLong("Fix the flaky test."))
        XCTAssertFalse(LongText.isLong(lines(40)))
        XCTAssertTrue(LongText.isLong(lines(41)))
        XCTAssertTrue(LongText.isLong(String(repeating: "x", count: 8_001)), "one enormous line")
        XCTAssertFalse(LongText.isLong(String(repeating: "x", count: 8_000)))
    }

    func testTheTenThousandLinePasteCollapsesQuickly() {
        let paste = lines(10_000) { "[00:00:\($0 % 60)] step \($0): compiling Module/Source\($0).swift (ok)" }
        let start = Date()
        for _ in 0..<100 { XCTAssertTrue(LongText.isLong(paste)) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "a check per redraw must cost next to nothing")
        XCTAssertEqual(LongText.lineCount(paste), 10_000)
        XCTAssertFalse(LongText.fitsInline(paste), "opened, it gets a scrolling view of its own")
        XCTAssertTrue(LongText.fitsInline(lines(200)))
    }

    func testTheHeadIsTheFirstLines() {
        let text = lines(100)
        let head = LongText.head(text)
        XCTAssertEqual(head, lines(20))
        XCTAssertTrue(text.hasPrefix(head))
        XCTAssertEqual(LongText.head("short"), "short")
        XCTAssertEqual(LongText.head(text, lines: 1, bytes: 300), "line 1")
    }

    func testTheHeadStopsAtItsByteBudgetOnACharacterBoundary() {
        // Multi-byte characters: a cut by bytes must not split one.
        let text = String(repeating: "é😀", count: 2_000)
        let head = LongText.head(text, lines: 20, bytes: 3_001)
        XCTAssertLessThanOrEqual(head.utf8.count, 3_001)
        XCTAssertGreaterThan(head.utf8.count, 2_990)
        XCTAssertTrue(text.hasPrefix(head))
        XCTAssertFalse(head.contains("\u{FFFD}"))
    }

    func testTheTailIsTheLastLines() {
        let text = lines(100)
        XCTAssertEqual(LongText.tail(text), (81...100).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(LongText.tail(text + "\n"), (81...100).map { "line \($0)" }.joined(separator: "\n") + "\n",
                       "a final line break doesn't count as a line")
        XCTAssertEqual(LongText.tail("short"), "short")
        let wide = String(repeating: "é😀", count: 2_000)
        let tail = LongText.tail(wide, lines: 20, bytes: 3_001)
        XCTAssertLessThanOrEqual(tail.utf8.count, 3_001)
        XCTAssertTrue(wide.hasSuffix(tail))
        XCTAssertFalse(tail.contains("\u{FFFD}"))
    }
}
