import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// The screenshot mode's long chat (`SnapshotLongChat`): the chat the transcript's paging is measured and looked at
/// with.
@MainActor
final class LongChatSnapshotTests: XCTestCase {
    func testTheLongChatHas2000RowsAndOne10000LinePrompt() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries = SnapshotLongChat.entries(now: now)
        XCTAssertEqual(entries.count, 2_000)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2_000, "ids are unique")
        XCTAssertEqual(entries.map(\.at), entries.map(\.at).sorted(), "rows in time order")
        XCTAssertLessThan(entries.last?.at ?? now, now)

        let huge = try XCTUnwrap(entries[SnapshotLongChat.hugeRow].message)
        XCTAssertEqual(huge.role, .user)
        XCTAssertEqual(huge.text.split(separator: "\n", omittingEmptySubsequences: false).count, 10_002)
        XCTAssertGreaterThanOrEqual(SnapshotLongChat.hugeRow, entries.count - 50, "on screen when the chat opens")

        let kinds = Set(entries.map { entry -> String in
            switch entry.kind {
            case .message(let body): body.role.rawValue
            case .tool: "tool"
            case .todos: "todos"
            case .compaction: "compaction"
            }
        })
        XCTAssertEqual(kinds, ["user", "assistant", "notice", "tool"])
        // The same rows every run.
        XCTAssertEqual(SnapshotLongChat.entries(now: now).map(\.kind), entries.map(\.kind))
    }

    func testTheLongChatIsStoredAsLogRows() {
        let entries = SnapshotLongChat.entries()
        let rows = AppTransport.logRows(for: entries, sessionID: SnapshotLongChat.chatID)
        XCTAssertEqual(rows.count, entries.count)
        XCTAssertEqual(rows[SnapshotLongChat.hugeRow].kind, "user")
        XCTAssertEqual(rows[SnapshotLongChat.hugeRow].text, SnapshotLongChat.hugeText)
    }

    func testTheMemoryFootprintReadsBack() {
        XCTAssertGreaterThan(SnapshotLongChat.footprint(), 1_000_000)
    }
}
