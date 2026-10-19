import SwiftUI
import AppKit

// MARK: - The pager

/// One chat's paged transcript: which rows are drawn (`TranscriptWindow`), whether the person is following the
/// newest row, a row to jump to and the one flashing after a jump, and the long messages they opened.
///
/// Opening a chat draws its newest page. Scrolling up to the "Load earlier messages" bar (or clicking it) adds the
/// page above, and the row the person was reading stays exactly where it was on screen. Jumping to an older prompt
/// draws the page around it and flashes it. While the person follows the end, rows streaming in scroll the transcript
/// down as before; once they scroll up to read, nothing moves under them and "Jump to latest" brings them back.
@MainActor
@Observable
final class TranscriptPager {
    var window = TranscriptWindow()
    /// The person is at the newest row: rows arriving scroll the transcript down to them.
    var following = true
    /// A row to bring into view and flash (from the prompt history, a search). Set with `jump(to:)`.
    private(set) var jump: Jump?
    /// The message the person clicked: Edit ▸ Copy Message (⇧⌘C) copies all of it.
    var selectedID: String?
    /// The row drawn highlighted for a moment after a jump.
    var highlightID: String?
    /// Long messages the person opened with "Show more".
    var expanded: Set<String> = []
    /// After rows were added above or let go below: the row to keep where it was on screen.
    private(set) var restore: Restore?
    /// The transcript has scrolled to its newest row after opening; until then nothing loads by itself.
    var settled = false

    /// Where things sat on screen at the last layout. Not observed: it changes on every scroll frame.
    @ObservationIgnored var geometry = TranscriptFrames()
    /// Until then, a scroll that moves the view up is the app's own (a jump, a kept-in-place row), not the person's.
    @ObservationIgnored var programmaticUntil = Date.distantPast
    /// The bars only load by themselves after they were out of view once (no cascade when a chat opens).
    @ObservationIgnored var earlierArmed = false
    @ObservationIgnored var newerArmed = false
    /// How the last restore went, in points off where the row was (for the screenshot mode's measurements).
    @ObservationIgnored var lastRestoreDrift: CGFloat?
    @ObservationIgnored private var recheckScheduled = false

    struct Jump: Equatable {
        let id: String
        /// The same row twice still jumps twice.
        let nonce = UUID()
    }

    struct Restore: Equatable {
        let id: String
        /// The row's top, in the visible area's coordinates, before the change.
        let minY: CGFloat
        let viewport: CGFloat
        let nonce = UUID()

        /// Where on the visible area the row's (zero-height) marker goes so its top lands at `minY` again.
        var unitY: CGFloat { viewport > 1 ? min(max(minY / viewport, 0), 1) : 0 }
    }

    /// Bring `id` into view: the window moves to the page around it if needed, the transcript scrolls to it, and it
    /// flashes.
    func jump(to id: String) {
        jump = Jump(id: id)
    }

    func takeJump() -> Jump? {
        defer { jump = nil }
        return jump
    }

    /// A chat (re)opened: its newest page, following the end, nothing loading until it has scrolled down.
    func reset() {
        window.showLatest()
        if !following { following = true }
        settled = false
        selectedID = nil
        earlierArmed = false
        newerArmed = false
        restore = nil
        geometry = TranscriptFrames()
    }

    /// The scroll that follows is the app's own for a moment.
    func scrollingByItself(for seconds: TimeInterval = 0.45) {
        programmaticUntil = Date().addingTimeInterval(seconds)
    }

    // MARK: Drawn rows

    struct Rows {
        let entries: ArraySlice<ChatEntry>
        let hiddenBefore: Int
        let hiddenAfter: Int
        var firstID: String? { entries.first?.id }
        var lastID: String? { entries.last?.id }
    }

    func rows(of entries: [ChatEntry]) -> Rows {
        let range = window.range(in: entries.lazy.map(\.id))
        return Rows(entries: entries[range], hiddenBefore: range.lowerBound, hiddenAfter: entries.count - range.upperBound)
    }

    /// Rows whose place on screen is measured: the first and last drawn, one being kept in place, one jumped to.
    func isWatched(_ id: String, in rows: Rows) -> Bool {
        id == rows.firstID || id == rows.lastID || id == restore?.id || id == highlightID
    }

    // MARK: Moving

    /// Add the page above; the first row drawn now stays where it is on screen.
    func loadEarlier(_ entries: [ChatEntry]) {
        let ids = entries.lazy.map(\.id)
        let current = window.range(in: ids)
        guard current.lowerBound > 0 else { return }
        let anchor = ids[current.lowerBound]
        let minY = geometry.rows[anchor]?.minY
        guard window.loadEarlier(in: ids) else { return }
        if following { following = false }
        keep(anchor, at: minY)
    }

    /// Add the page below; the last row drawn now stays where it is on screen.
    func loadLater(_ entries: [ChatEntry]) {
        let ids = entries.lazy.map(\.id)
        let current = window.range(in: ids)
        guard !current.isEmpty else { return }
        let anchor = ids[current.upperBound - 1]
        let minY = geometry.rows[anchor]?.minY
        guard window.loadLater(in: ids) else { return }
        keep(anchor, at: minY)
    }

    /// Back to the newest page, following it.
    func showLatest() {
        window.showLatest()
        if !following { following = true }
        scrollingByItself()
    }

    private func keep(_ id: String, at minY: CGFloat?) {
        earlierArmed = false
        newerArmed = false
        scrollingByItself(for: 0.35)
        guard let minY, let viewport = geometry.viewport, viewport > 1 else { return }
        restore = Restore(id: id, minY: minY, viewport: viewport)
    }

    func restoreDone(_ restore: Restore) {
        if self.restore == restore { self.restore = nil }
    }

    // MARK: Following what the person does

    /// The layout's measurements came in: follow the person (scrolled up to read, or back at the end) and load a
    /// page when they reach a bar.
    func observe(_ frames: TranscriptFrames, entries: @escaping @MainActor () -> [ChatEntry]) {
        let previous = geometry
        geometry = frames
        if geometry.viewport == nil { geometry.viewport = previous.viewport }
        guard let viewport = geometry.viewport, viewport > 1, let bottom = geometry.bottom, let top = geometry.top else { return }

        // Following: at the end — or until the person scrolls up. Scrolling up moves the content's top down the
        // screen; rows arriving below, or rows let go above, don't move it, and the app's own scroll to the end only
        // moves it up. (A jump or a kept-in-place row may move it down: those mark themselves `scrollingByItself`.)
        let atEnd = window.reachesEnd && bottom.maxY - viewport <= 48
        let movedUp = previous.top.map { top.minY > $0.minY + 2 } ?? false
        if atEnd {
            if !following { following = true }
        } else if movedUp, Date() >= programmaticUntil, settled {
            if following { following = false }
            // Nothing above them moves while they read: the window stops following the end.
            if window.isLatestPage { window.pin(in: entries().lazy.map(\.id)) }
        }

        checkBars(entries)
    }

    /// A bar that is in view loads its page — once it was out of view since the last load, so opening a chat or a
    /// load never sets off the next one by itself. Reached while the app's own scroll or a restore is still going
    /// on (a fast scroll up), it loads as soon as that is over, without waiting for another scroll.
    private func checkBars(_ entries: @escaping @MainActor () -> [ChatEntry]) {
        guard let viewport = geometry.viewport, viewport > 1 else { return }
        let canLoad = settled && Date() >= programmaticUntil && restore == nil
        var waiting = false
        if let bar = geometry.earlierBar {
            let visible = bar.maxY > 0 && bar.minY < viewport
            if !visible { earlierArmed = true } else if earlierArmed {
                if canLoad {
                    earlierArmed = false
                    DispatchQueue.main.async { [weak self] in self?.loadEarlier(entries()) }
                } else {
                    waiting = true
                }
            }
        }
        if let bar = geometry.newerBar {
            let visible = bar.maxY > 0 && bar.minY < viewport
            if !visible { newerArmed = true } else if newerArmed {
                if canLoad {
                    newerArmed = false
                    DispatchQueue.main.async { [weak self] in self?.loadLater(entries()) }
                } else {
                    waiting = true
                }
            }
        }
        guard waiting, !recheckScheduled else { return }
        recheckScheduled = true
        let delay = max(0.05, programmaticUntil.timeIntervalSinceNow + 0.02)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            recheckScheduled = false
            checkBars(entries)
        }
    }

    // MARK: Ids

    static let coordinateSpace = "vision.transcript"
    /// A zero-height view at the top of each drawn row: what a restore scrolls to.
    static func markerID(_ id: String) -> String { "top-of-\(id)" }

    /// The transcript row of a prompt the person sent: the user message with that text (or a goal's first round with
    /// it as the goal), the one nearest `at`.
    static func entryID(forPrompt text: String, at: Date?, in entries: [ChatEntry]) -> String? {
        var best: (id: String, distance: TimeInterval)?
        for entry in entries {
            guard let body = entry.message, body.role == .user,
                  body.text == text || GoalTranscript.goal(inKickoff: body.text) == text else { continue }
            let distance = at.map { abs(entry.at.timeIntervalSince($0)) } ?? 0
            if best == nil || distance < best!.distance { best = (entry.id, distance) }
        }
        return best?.id
    }
}

// MARK: - Geometry

/// Frames reported by the transcript's views, in the visible area's coordinates (y = 0 is its top edge).
struct TranscriptFrames: Equatable {
    var viewport: CGFloat?
    var top: CGRect?
    var bottom: CGRect?
    var earlierBar: CGRect?
    var newerBar: CGRect?
    var rows: [String: CGRect] = [:]

    mutating func merge(_ other: TranscriptFrames) {
        viewport = other.viewport ?? viewport
        top = other.top ?? top
        bottom = other.bottom ?? bottom
        earlierBar = other.earlierBar ?? earlierBar
        newerBar = other.newerBar ?? newerBar
        rows.merge(other.rows) { _, new in new }
    }
}

struct TranscriptFramesKey: PreferenceKey {
    static let defaultValue = TranscriptFrames()
    static func reduce(value: inout TranscriptFrames, nextValue: () -> TranscriptFrames) {
        value.merge(nextValue())
    }
}

private extension View {
    /// Report this view's frame in the transcript's visible area.
    func reportFrame(_ fill: @escaping (inout TranscriptFrames, CGRect) -> Void) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TranscriptFramesKey.self, value: {
                    var frames = TranscriptFrames()
                    fill(&frames, proxy.frame(in: .named(TranscriptPager.coordinateSpace)))
                    return frames
                }())
            }
        }
    }
}

// MARK: - The transcript's pieces

/// The top of the transcript's content (where the scroll offset is read).
struct TranscriptTopMarker: View {
    var body: some View {
        Color.clear.frame(height: 0).reportFrame { $0.top = $1 }
    }
}

/// The bottom of the transcript's content: what following the end scrolls to.
struct TranscriptBottomMarker: View {
    let id: String
    var body: some View {
        Color.clear.frame(height: 1).id(id).reportFrame { $0.bottom = $1 }
    }
}

/// One drawn row: a zero-height marker on top (what keeping it in place scrolls to), measured when watched, and the
/// flash after a jump.
struct TranscriptRowFrame: ViewModifier {
    let id: String
    let watched: Bool
    let highlighted: Bool

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            marker
            content
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .fill(Color.accentColor.opacity(highlighted ? 0.16 : 0))
                        .padding(-5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .strokeBorder(Color.accentColor.opacity(highlighted ? 0.7 : 0), lineWidth: 1.5)
                        .padding(-5)
                )
                .animation(.easeOut(duration: 0.35), value: highlighted)
        }
        .id(id)
    }

    @ViewBuilder
    private var marker: some View {
        if watched {
            Color.clear.frame(height: 0).id(TranscriptPager.markerID(id)).reportFrame { $0.rows[id] = $1 }
        } else {
            Color.clear.frame(height: 0).id(TranscriptPager.markerID(id))
        }
    }
}

/// "Load earlier messages · 1,950 more" above the drawn rows. Scrolling up to it loads the page too.
struct EarlierMessagesBar: View {
    let hidden: Int
    let pageSize: Int
    let action: () -> Void

    var body: some View {
        PageBar(symbol: "arrow.up", title: "Load earlier messages",
                detail: "\(hidden.formatted()) more above",
                help: "Show the \(min(hidden, pageSize)) messages before these (scrolling up to here does it too)",
                action: action)
            .reportFrame { $0.earlierBar = $1 }
    }
}

/// "Load newer messages · 120 more" below the drawn rows when the window stops before the end, and the way back to
/// the newest.
struct NewerMessagesBar: View {
    let hidden: Int
    let pageSize: Int
    let action: () -> Void
    let latest: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PageBar(symbol: "arrow.down", title: "Load newer messages",
                    detail: "\(hidden.formatted()) more below",
                    help: "Show the \(min(hidden, pageSize)) messages after these (scrolling down to here does it too)",
                    action: action)
            Button("Jump to latest", action: latest)
                .buttonStyle(.plain)
                .font(Theme.metaFont)
                .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity)
        .reportFrame { $0.newerBar = $1 }
    }
}

private struct PageBar: View {
    let symbol: String
    let title: String
    let detail: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text("·").foregroundStyle(.tertiary)
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .frame(maxWidth: .infinity)
    }
}

/// "↓ Latest" over the transcript's corner while the person reads further up.
struct JumpToLatestButton: View {
    let newer: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                Text(newer > 0 ? "Latest · \(newer.formatted()) newer" : "Latest")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("Scroll to the newest message")
    }
}

// MARK: - Behaviour

extension View {
    /// The paged transcript's behaviour, on the transcript's scroll view inside its `ScrollViewReader`: measuring,
    /// following the end as rows arrive, loading pages by scrolling, keeping the reader's row in place, jumps.
    func transcriptPaging(session: SessionVM, proxy: ScrollViewProxy, bottomAnchor: String) -> some View {
        modifier(TranscriptPagingBehavior(session: session, proxy: proxy, bottomAnchor: bottomAnchor))
    }
}

private struct TranscriptPagingBehavior: ViewModifier {
    let session: SessionVM
    let proxy: ScrollViewProxy
    let bottomAnchor: String

    private var pager: TranscriptPager { session.pager }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(TranscriptPager.coordinateSpace))
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptFramesKey.self,
                                           value: TranscriptFrames(viewport: geometry.size.height))
                }
            }
            .onPreferenceChange(TranscriptFramesKey.self) { frames in
                MainActor.assumeIsolated {
                    pager.observe(frames) { session.entries }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if pager.settled, !session.entries.isEmpty, !pager.following || !pager.window.reachesEnd {
                    JumpToLatestButton(newer: pager.window.hiddenAfter(in: session.entries.lazy.map(\.id))) {
                        showLatest()
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .onChange(of: session.entries.count) { _, _ in rowsArrived() }
            .onChange(of: session.promptHistory.count) { old, new in
                if new > old { promptSent() }
            }
            .onChange(of: lastEntryLength) { _, _ in
                if pager.following, pager.window.reachesEnd { scrollToEnd(animated: true) }
            }
            .onChange(of: pager.restore) { _, restore in
                guard let restore else { return }
                keepInPlace(restore)
            }
            .onChange(of: pager.jump) { _, jump in
                guard jump != nil else { return }
                performJump()
            }
            .onChange(of: session.id) { _, _ in opened() }
            .onAppear { opened() }
    }

    /// Streaming text changes the last row without changing the count (UTF-8 length: constant time).
    private var lastEntryLength: Int {
        session.entries.last?.message?.text.utf8.count ?? 0
    }

    private func scrollToEnd(animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    /// A chat opened: its newest page, scrolled to the end — again once the run loop has caught up, since the
    /// first pass runs before the transcript has laid out.
    private func opened() {
        pager.reset()
        scrollToEnd(animated: false)
        let id = session.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard session.id == id else { return }
            scrollToEnd(animated: false)
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard session.id == id else { return }
            pager.settled = true
            if pager.jump != nil { performJump() }
        }
    }

    private func rowsArrived() {
        let ids = session.entries.lazy.map(\.id)
        if session.entries.isEmpty { pager.reset(); pager.settled = true; return }
        let changed = pager.window.settleAfterRowsArrived(in: ids, following: pager.following)
        // Rows let go above make the content shorter: the scroll that follows can move its top down.
        if changed { pager.scrollingByItself() }
        if pager.following, pager.window.reachesEnd { scrollToEnd(animated: !changed) }
    }

    /// A new prompt went out: its turn is what the person wants to see, wherever they were reading.
    private func promptSent() {
        guard pager.settled, !pager.following || !pager.window.reachesEnd else { return }
        showLatest()
    }

    private func showLatest() {
        pager.showLatest()
        Task { @MainActor in
            scrollToEnd(animated: false)
            try? await Task.sleep(nanoseconds: 60_000_000)
            scrollToEnd(animated: true)
        }
    }

    /// Rows were added above (or let go below): put the row the person was reading back where it was. Once now —
    /// the new rows may not be laid out yet — and again after the layout, measured, until it sits within a point
    /// (for a quarter of a second at most, so a person scrolling on is not pulled back).
    private func keepInPlace(_ restore: TranscriptPager.Restore) {
        let marker = TranscriptPager.markerID(restore.id)
        let anchor = UnitPoint(x: 0.5, y: restore.unitY)
        proxy.scrollTo(marker, anchor: anchor)
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 25_000_000)
                guard let now = pager.geometry.rows[restore.id] else { continue }
                let drift = now.minY - restore.minY
                pager.lastRestoreDrift = drift
                if abs(drift) < 1 { break }
                pager.scrollingByItself(for: 0.3)
                proxy.scrollTo(marker, anchor: anchor)
            }
            pager.restoreDone(restore)
        }
    }

    /// Bring the jumped-to row into view, centred, and flash it.
    private func performJump() {
        guard pager.settled, let jump = pager.takeJump() else { return }
        let ids = session.entries.lazy.map(\.id)
        guard TranscriptWindow.position(of: jump.id, in: ids) != nil else { return }
        if pager.following { pager.following = false }
        pager.window.reveal(jump.id, in: ids)
        if pager.window.isLatestPage { pager.window.pin(in: ids) }
        pager.scrollingByItself(for: 0.8)
        pager.earlierArmed = false
        pager.newerArmed = false
        pager.highlightID = jump.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(jump.id, anchor: .center) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            proxy.scrollTo(jump.id, anchor: .center)
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            if pager.highlightID == jump.id { pager.highlightID = nil }
        }
    }
}
