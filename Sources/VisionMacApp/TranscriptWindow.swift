import Foundation

/// Which rows of a chat's transcript are drawn.
///
/// A chat can hold thousands of rows. Drawing all of them makes opening it slow and heavy (2,000 rows: four seconds
/// frozen and over a gigabyte), and a lazy stack that only estimates the rows it hasn't drawn can open on a blank
/// transcript. So the transcript draws a window of rows: the newest page when a chat opens; older pages added above
/// as the person scrolls up to them (or clicks "Load earlier messages"); newer ones added below on the way back down.
/// The window never holds more than `maxRows`: rows furthest from where the person is reading are let go.
///
/// The window is kept by row ids, not positions, so rows arriving at the end (a turn streaming in) don't move it.
/// When an id is gone (the row was removed) its last known position stands in.
struct TranscriptWindow: Equatable, Sendable {
    /// Rows added per "Load earlier"/"Load newer", and the size of the window a chat opens with.
    static let defaultPageSize = 50
    /// The most rows drawn at once.
    static let defaultMaxRows = 150

    let pageSize: Int
    let maxRows: Int

    /// The first drawn row; nil = one page before the last drawn row, which follows the end as rows arrive.
    private(set) var firstID: String?
    private var firstHint = 0
    /// The last drawn row; nil = the newest row (the window reaches the end and takes in rows as they arrive).
    private(set) var lastID: String?
    private var lastHint = 0

    init(pageSize: Int = Self.defaultPageSize, maxRows: Int = Self.defaultMaxRows) {
        self.pageSize = max(1, pageSize)
        self.maxRows = max(self.pageSize, maxRows)
    }

    /// The window reaches the newest row.
    var reachesEnd: Bool { lastID == nil }
    /// The window is the newest page and moves along as rows arrive (nothing pinned).
    var isLatestPage: Bool { firstID == nil && lastID == nil }

    // MARK: Reading

    /// The drawn rows' positions in `ids` (the transcript's row ids, oldest first).
    func range<C: RandomAccessCollection>(in ids: C) -> Range<Int> where C.Element == String, C.Index == Int {
        let count = ids.count
        guard count > 0 else { return 0..<0 }
        let upper: Int
        if let lastID {
            upper = (Self.position(of: lastID, in: ids).map { $0 + 1 } ?? lastHint + 1).clamped(1, count)
        } else {
            upper = count
        }
        let lower: Int
        if let firstID {
            lower = (Self.position(of: firstID, in: ids) ?? firstHint).clamped(0, upper - 1)
        } else {
            lower = max(0, upper - pageSize)
        }
        return lower..<upper
    }

    /// Rows above the window.
    func hiddenBefore<C: RandomAccessCollection>(in ids: C) -> Int where C.Element == String, C.Index == Int {
        range(in: ids).lowerBound
    }

    /// Rows below the window.
    func hiddenAfter<C: RandomAccessCollection>(in ids: C) -> Int where C.Element == String, C.Index == Int {
        ids.count - range(in: ids).upperBound
    }

    func contains<C: RandomAccessCollection>(_ id: String, in ids: C) -> Bool where C.Element == String, C.Index == Int {
        guard let index = Self.position(of: id, in: ids) else { return false }
        return range(in: ids).contains(index)
    }

    // MARK: Moving

    /// Add a page above. Rows past `maxRows` are let go at the bottom (the window then stops at a row instead of
    /// reaching the end). False when there was nothing above.
    @discardableResult
    mutating func loadEarlier<C: RandomAccessCollection>(in ids: C) -> Bool where C.Element == String, C.Index == Int {
        let current = range(in: ids)
        guard current.lowerBound > 0 else { return false }
        let lower = max(0, current.lowerBound - pageSize)
        var upper = current.upperBound
        if upper - lower > maxRows { upper = lower + maxRows }
        set(lower..<upper, in: ids)
        return true
    }

    /// Add a page below. Rows past `maxRows` are let go at the top. False when the window already reaches the end.
    @discardableResult
    mutating func loadLater<C: RandomAccessCollection>(in ids: C) -> Bool where C.Element == String, C.Index == Int {
        let current = range(in: ids)
        guard current.upperBound < ids.count else {
            if lastID != nil { lastID = nil; return true }
            return false
        }
        let upper = min(ids.count, current.upperBound + pageSize)
        var lower = current.lowerBound
        if upper - lower > maxRows { lower = upper - maxRows }
        set(lower..<upper, in: ids)
        return true
    }

    /// Make sure the row `id` is drawn: when it is outside the window, the window becomes the page around it. False
    /// when it already was drawn, or there is no such row.
    @discardableResult
    mutating func reveal<C: RandomAccessCollection>(_ id: String, in ids: C) -> Bool where C.Element == String, C.Index == Int {
        guard let index = Self.position(of: id, in: ids) else { return false }
        guard !range(in: ids).contains(index) else { return false }
        let lower = max(0, index - pageSize / 2)
        let upper = min(ids.count, lower + pageSize)
        set(max(0, upper - pageSize)..<upper, in: ids)
        return true
    }

    /// Back to the newest page, following the end.
    mutating func showLatest() {
        firstID = nil
        lastID = nil
    }

    /// Keep the rows drawn now where they are while rows keep arriving (the person scrolled away from the end and
    /// is reading): the first drawn row stops moving along with the end.
    mutating func pin<C: RandomAccessCollection>(in ids: C) where C.Element == String, C.Index == Int {
        guard firstID == nil, !ids.isEmpty else { return }
        let current = range(in: ids)
        firstID = ids[current.lowerBound]
        firstHint = current.lowerBound
    }

    /// While the window reaches the end, rows arriving make it longer. Past `maxRows`: when the person follows the
    /// end, go back to the newest page (the top rows they scrolled past are let go); when they are reading further up,
    /// the window stops at its last row so nothing above them moves. True when the window changed.
    @discardableResult
    mutating func settleAfterRowsArrived<C: RandomAccessCollection>(in ids: C, following: Bool) -> Bool
        where C.Element == String, C.Index == Int {
        guard reachesEnd else { return false }
        let current = range(in: ids)
        guard current.count > maxRows else { return false }
        if following {
            showLatest()
        } else {
            set(current.lowerBound..<(current.lowerBound + maxRows), in: ids)
        }
        return true
    }

    // MARK: Helpers

    private mutating func set<C: RandomAccessCollection>(_ rows: Range<Int>, in ids: C) where C.Element == String, C.Index == Int {
        guard !rows.isEmpty else { showLatest(); return }
        firstID = ids[rows.lowerBound]
        firstHint = rows.lowerBound
        if rows.upperBound >= ids.count {
            lastID = nil
        } else {
            lastID = ids[rows.upperBound - 1]
            lastHint = rows.upperBound - 1
        }
    }

    /// Where `id` is. Searched from the end: the window is usually near it.
    static func position<C: RandomAccessCollection>(of id: String, in ids: C) -> Int? where C.Element == String, C.Index == Int {
        var index = ids.endIndex
        while index > ids.startIndex {
            index -= 1
            if ids[index] == id { return index }
        }
        return nil
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), Swift.max(low, high)) }
}
