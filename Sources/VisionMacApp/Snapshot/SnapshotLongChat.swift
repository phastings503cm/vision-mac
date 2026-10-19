import AppKit
import Darwin
import Foundation
import VisionHarnessCore

/// A very long chat for the screenshot mode: 2,000 transcript rows — prompts, tool cards, replies — with one prompt
/// that is a 10,000-line pasted build log. The `long-chat…` scenes open it, look at it and measure what opening it
/// costs (how long the app is busy, how much memory it takes), written to `long-chat-measurements.txt` beside the
/// pictures.
@MainActor
enum SnapshotLongChat {
    static let chatID = "7D3E9A21-4B6C-4E8F-A0B1-C2D3E4F5A6B7"
    static let title = "Ledger: a long week of work"
    /// Transcript rows in the chat.
    static let rowCount = 2_000
    /// Lines in the one huge prompt.
    static let hugeLines = 10_000
    /// The huge prompt's row: inside the newest 50 rows, so it is on screen when the chat opens.
    static let hugeRow = 1_980

    // MARK: The chat

    /// The chat's rows, oldest first, the last one four days before `now` (so the app doesn't open on it at launch
    /// and the measurement sees it opened). Deterministic: the same rows every run.
    static func entries(now: Date = Date()) -> [ChatEntry] {
        let start = now.addingTimeInterval(-Double(rowCount) * 30 - 4 * 86_400)
        var out: [ChatEntry] = []
        out.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            let at = start.addingTimeInterval(Double(index) * 30)
            let id = "long-\(index)"
            let group = index / 4 + 1
            let kind: ChatEntry.Kind
            if index == hugeRow {
                kind = .message(MessageBody(role: .user, text: hugeText))
            } else {
                switch index % 4 {
                case 0:
                    kind = .message(MessageBody(role: .user, text: prompt(group)))
                case 1:
                    kind = .tool(readTool(group))
                case 2:
                    kind = group % 25 == 0
                        ? .message(MessageBody(role: .notice, text: "Context check: \(group % 60 + 20)% of the window in use; no compaction needed yet."))
                        : .tool(editTool(group))
                default:
                    kind = .message(MessageBody(role: .assistant, text: reply(group)))
                }
            }
            out.append(ChatEntry(id: id, at: at, kind: kind))
        }
        return out
    }

    /// The 10,000-line prompt: a question and a pasted build log.
    static var hugeText: String {
        var lines = ["Here is the whole build log from last night. Why does the release build fail at the end?", ""]
        lines.reserveCapacity(hugeLines + 2)
        for line in 1...hugeLines {
            let module = ["Ledger", "LedgerCLI", "LedgerReport", "LedgerImport"][line % 4]
            lines.append(String(format: "[%02d:%02d:%02d.%03d] ", line / 3_600 % 24, line / 60 % 60, line % 60, line * 7 % 1_000)
                         + "step \(line): compiling \(module)/Source\(line % 97).swift (ok)")
        }
        lines[lines.count - 1] = "[02:46:40.000] error: release build failed: LedgerReport/Source9.swift:41: cannot find 'categoryTotals' in scope"
        return lines.joined(separator: "\n")
    }

    private static let asks = [
        "Add a `--since` option to `ledger report` that skips transactions before a date.",
        "The CSV importer chokes on quoted commas. Find out why and fix it, with a test.",
        "Rename `Amount.cents` to `Amount.minorUnits` everywhere, keeping the JSON format the same.",
        "Why is `ledger report --by-category` slower than plain `ledger report`? Measure it first.",
        "Write a short section for the README about the new monthly summary.",
        "Make `ledger import` refuse a file it already imported (same name and checksum).",
        "Add a `--json` flag to `ledger balance` so scripts can read it.",
        "Clean up the warnings the test run prints; don't change behaviour.",
    ]

    static func prompt(_ group: Int) -> String {
        let ask = asks[group % asks.count]
        return group % 3 == 0 ? "Prompt #\(group): \(ask)\nKeep the change small and run the whole suite when you are done." : "Prompt #\(group): \(ask)"
    }

    private static func readTool(_ group: Int) -> ToolActivity {
        let file = ["ledger/report.py", "ledger/cli.py", "ledger/importer.py", "tests/test_report.py"][group % 4]
        let output = (1...24).map { "\($0)\t" + ($0 % 6 == 0 ? "def step_\(group)_\($0)(rows):" : "    total += row.amount  # line \($0)") }
            .joined(separator: "\n")
        return ToolActivity(name: "read_file", preview: file, summary: "24 lines", output: output, isOk: true)
    }

    private static func editTool(_ group: Int) -> ToolActivity {
        let file = ["ledger/report.py", "ledger/cli.py", "ledger/importer.py", "README.md"][group % 4]
        return ToolActivity(name: "edit", preview: file, summary: "+\(group % 9 + 2) −\(group % 4)",
                            output: "Edited \(file): replaced 1 occurrence.", isOk: true)
    }

    static func reply(_ group: Int) -> String {
        var text = "Done with prompt #\(group). I changed the parser and kept the old output byte-for-byte:\n\n"
        text += "- `ledger/cli.py` gains the option and passes it through\n"
        text += "- `ledger/report.py` filters the rows before totalling\n"
        text += "- \(group % 5 + 3) tests cover the new path; the suite passes (\(40 + group % 30) tests)\n"
        if group % 4 == 0 {
            text += "\n```python\ndef since(rows, day):\n    return [row for row in rows if row.date >= day]\n```\n"
        }
        text += "\nAnything else for this one?"
        return text
    }

    // MARK: Writing it

    /// Store the chat in the isolated data folder (before the app reads its chats).
    static func install(now: Date = Date()) {
        let entries = entries(now: now)
        ConversationLog.shared.store(
            LogSession(id: chatID, title: title, cwd: nil, preset: PermissionPreset.workspaceWrite.rawValue,
                       updatedAt: entries.last?.at ?? now),
            items: AppTransport.logRows(for: entries, sessionID: chatID))
    }

    // MARK: Measuring

    /// This process's memory footprint (what Activity Monitor shows), in bytes.
    nonisolated static func footprint() -> UInt64 {
        var usage = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? usage.ri_phys_footprint : 0
    }

    /// How long the main thread stays busy after `start`: ticks of `tick` seconds are scheduled one after another; a
    /// tick that comes back late was held up by work on the main thread (drawing, layout). Busy until `quiet`
    /// consecutive ticks come back on time, or `limit` seconds pass.
    static func busyTime(since start: Date, tick: Double = 0.01, quiet: Int = 20, limit: Double = 120) async
        -> (untilIdle: TimeInterval, longestStall: TimeInterval) {
        var onTime = 0
        var lastBusyEnd = start
        var longest: TimeInterval = 0
        // The first tick waits out the drawing that the change before this call started.
        var previous = Date()
        while onTime < quiet, Date().timeIntervalSince(start) < limit {
            try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            let now = Date()
            let stall = now.timeIntervalSince(previous) - tick
            if stall > 0.03 {
                onTime = 0
                lastBusyEnd = now
                longest = max(longest, stall)
            } else {
                onTime += 1
            }
            previous = now
        }
        return (lastBusyEnd.timeIntervalSince(start), longest)
    }

    /// A line for `long-chat-measurements.txt`.
    static func record(_ line: String, in folder: URL) {
        let file = folder.appendingPathComponent("long-chat-measurements.txt")
        let stamped = line + "\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.0f ms", seconds * 1_000)
    }

    // MARK: Scenes

    /// Held while the scenes run: no App Nap, so a measured timer tick is late only when the app was busy.
    private static var activity: NSObjectProtocol?

    static func stage(_ scene: Snapshot.Scene, _ model: AppModel, window: NSWindow, output: URL) async {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Measuring the transcript")
        }
        // In front and key, as when a person uses it (focus and the Edit menu need a key window).
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        switch scene {
        case .longChat: await open(model, window: window, output: output)
        case .longChatTop: await scrollToTop(model, window: window, output: output)
        case .longChatEarlier: await loadEarlier(model, window: window, output: output)
        case .longChatJump: await jump(model, window: window, output: output)
        case .longChatHuge: await huge(model, window: window, output: output, open: false)
        case .longChatHugeOpen: await huge(model, window: window, output: output, open: true)
        case .longChatStream: await stream(model, window: window, output: output)
        default: break
        }
    }

    /// Open the long chat and measure: the time to read it in, how long the app is busy drawing it, the longest
    /// single stall, and the memory it took.
    static func open(_ model: AppModel, window: NSWindow, output: URL) async {
        model.mode = .chat
        model.config.planPanelOpen = false
        // Start from a small chat, settled, so the measurement is the long chat alone.
        model.select(SnapshotSeed.mainChatID)
        await Snapshot.pause(1.0)
        let before = footprint()
        let start = Date()
        model.select(chatID)
        let selected = Date()
        let busy = await busyTime(since: start)
        let after = footprint()
        let vm = model.transport.sessions.first { $0.id == chatID }
        let rows = vm?.entries.count ?? 0
        let drawn = vm.map { $0.pager.rows(of: $0.entries).entries.count }.map { ", \($0) rows drawn" } ?? ""
        record("open long chat (\(rows) rows, one \(hugeLines)-line prompt): read in \(milliseconds(selected.timeIntervalSince(start)))"
               + ", busy until idle \(milliseconds(busy.untilIdle)), longest stall \(milliseconds(busy.longestStall))"
               + ", memory \(megabytes(before)) → \(megabytes(after)) (+\(megabytes(after > before ? after - before : 0)))"
               + drawn, in: output)
    }

    /// The long chat, open at its newest row (opened again if it was open, as a person switching back to it).
    private static func reopen(_ model: AppModel) async -> SessionVM? {
        model.mode = .chat
        model.config.planPanelOpen = false
        if model.selectedSession?.id == chatID {
            model.select(SnapshotSeed.mainChatID)
            await Snapshot.pause(0.4)
        }
        model.select(chatID)
        _ = await busyTime(since: Date())
        await Snapshot.pause(0.5)
        return model.selectedSession
    }

    /// Scroll the open long chat from the bottom to its very first row as a person would — a screenful at a time —
    /// and measure: how long it takes, the longest the app froze on one step, and the memory it ends up holding.
    /// Paged, every arrival at the top loads the page above and keeps the reader's row in place.
    static func scrollToTop(_ model: AppModel, window: NSWindow, output: URL) async {
        guard let vm = await reopen(model) else { return }
        guard let scroller = transcriptScrollView(in: window) else {
            record("scroll to top: the transcript's scroll view was not found", in: output)
            return
        }
        let start = Date()
        var steps = 0
        var longest: TimeInterval = 0
        var atTopSteps = 0
        var loads = 0
        var mostDrawn = 0
        var worstDrift: CGFloat = 0
        var drifts: [Int] = []
        var lower = vm.pager.rows(of: vm.entries).hiddenBefore
        // Up a screenful at a time until the top has stayed the top for a few steps (rows above may still be on
        // their way in), or two minutes pass.
        while atTopSteps < 6, Date().timeIntervalSince(start) < 120 {
            let clip = scroller.contentView
            let top = -scroller.contentInsets.top
            let y = max(top, clip.bounds.origin.y - clip.bounds.height * 0.9)
            atTopSteps = clip.bounds.origin.y <= top + 0.5 ? atTopSteps + 1 : 0
            // The step's cost: drawing the rows it brings in happens partly inside the scroll call itself.
            let stepStart = Date()
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroller.reflectScrolledClipView(clip)
            let inCall = Date().timeIntervalSince(stepStart)
            steps += 1
            let step = await busyTime(since: Date(), quiet: 5, limit: 20)
            longest = max(longest, inCall, step.longestStall)
            let rows = vm.pager.rows(of: vm.entries)
            mostDrawn = max(mostDrawn, rows.entries.count)
            if rows.hiddenBefore < lower {
                loads += 1
                lower = rows.hiddenBefore
                // Let the restore finish, then read how far the reader's row ended up from where it was.
                for _ in 0..<40 where vm.pager.restore != nil { await Snapshot.pause(0.025) }
                if let drift = vm.pager.lastRestoreDrift {
                    worstDrift = max(worstDrift, abs(drift))
                    drifts.append(Int(drift.rounded()))
                }
                atTopSteps = 0
            }
        }
        let rows = vm.pager.rows(of: vm.entries)
        let first = rows.entries.first?.message?.text.prefix(30) ?? "?"
        record("scroll to top: \(steps) steps in \(milliseconds(Date().timeIntervalSince(start))), longest stall "
               + "\(milliseconds(longest)), memory after \(megabytes(footprint())); pages loaded by scrolling: \(loads), "
               + "most rows drawn at once: \(mostDrawn), worst reader-row drift after a load: "
               + String(format: "%.1f pt", worstDrift) + " \(drifts.filter { $0 != 0 })" + "; first row drawn: \"\(first)…\" (\(rows.hiddenBefore) above it)",
               in: output)
    }

    /// From the newest page, scroll up to the "Load earlier messages" bar (a picture of it), click it (as the button
    /// does), and measure how far the row at the top moved.
    static func loadEarlier(_ model: AppModel, window: NSWindow, output: URL) async {
        guard let vm = await reopen(model), let scroller = transcriptScrollView(in: window) else { return }
        let pager = vm.pager
        // Hold the bar still for its picture: nothing loads by itself until it is clicked.
        pager.settled = false
        let clip = scroller.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -scroller.contentInsets.top))
        scroller.reflectScrolledClipView(clip)
        await Snapshot.pause(0.8)
        await picture(window, "long-chat-earlier-bar", output)
        let rows = pager.rows(of: vm.entries)
        let anchor = rows.firstID ?? ""
        let before = pager.geometry.rows[anchor]?.minY
        let start = Date()
        pager.loadEarlier(vm.entries)
        let busy = await busyTime(since: start)
        let after = pager.rows(of: vm.entries)
        record("load earlier (button): \(rows.entries.count) → \(after.entries.count) rows drawn, \(after.hiddenBefore) still above; "
               + "busy \(milliseconds(busy.untilIdle)); the top row was at y=" + String(format: "%.1f", before ?? -1)
               + ", ended " + String(format: "%.1f pt", pager.lastRestoreDrift ?? .nan) + " from there",
               in: output)
        pager.settled = true
    }

    /// Jump to an early prompt (as the prompt history's "Jump to it" does): the page around it is drawn, it flashes.
    static func jump(_ model: AppModel, window: NSWindow, output: URL) async {
        guard let vm = await reopen(model) else { return }
        // Ids are the app's own once a stored chat is read back; the row is found by position.
        guard vm.entries.count > 32 else { return }
        let target = vm.entries[32].id
        let start = Date()
        vm.pager.jump(to: target)
        let busy = await busyTime(since: start)
        await picture(window, "long-chat-jump-flash", output)
        let rows = vm.pager.rows(of: vm.entries)
        record("jump to row 32 (prompt #9): rows \(rows.hiddenBefore)–\(rows.hiddenBefore + rows.entries.count - 1) drawn"
               + ", \(rows.hiddenAfter) below; highlighted: \(vm.pager.highlightID == target); following the end: "
               + "\(vm.pager.following); busy \(milliseconds(busy.untilIdle))", in: output)
    }

    /// The 10,000-line prompt: collapsed to its first lines, or opened in its own scrolling view.
    static func huge(_ model: AppModel, window: NSWindow, output: URL, open: Bool) async {
        guard let vm = await reopen(model) else { return }
        guard vm.entries.count > hugeRow else { return }
        let id = vm.entries[hugeRow].id
        vm.pager.jump(to: id)
        _ = await busyTime(since: Date())
        guard open else {
            record("huge prompt collapsed: shows \(LongText.lineCount(LongText.head(vm.entries[hugeRow].message?.text ?? ""))) of "
                   + "\(LongText.lineCount(vm.entries[hugeRow].message?.text ?? "")) lines", in: output)
            return
        }
        let before = footprint()
        let start = Date()
        vm.pager.expanded.insert(id)
        let busy = await busyTime(since: start)
        vm.pager.jump(to: id)
        _ = await busyTime(since: Date())
        record("huge prompt opened (Show more): busy \(milliseconds(busy.untilIdle)), longest stall "
               + "\(milliseconds(busy.longestStall)), memory +\(megabytes(footprint() > before ? footprint() - before : 0))",
               in: output)
    }

    /// A turn streaming in at the end: followed to the newest line; then, scrolled up to read, it no longer moves
    /// the transcript and "Latest" appears.
    static func stream(_ model: AppModel, window: NSWindow, output: URL) async {
        guard let vm = await reopen(model), let scroller = transcriptScrollView(in: window) else { return }
        let pager = vm.pager
        vm.appendMessage(.user, "Prompt #501: summarise the week's changes for the release notes.")
        for word in 0..<80 {
            vm.appendDelta(word % 12 == 11 ? "change \(word).\n\n" : "change \(word), ")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await Snapshot.pause(0.4)
        let followed = pager.following && (pager.geometry.bottom.map { $0.maxY - (pager.geometry.viewport ?? 0) <= 48 } ?? false)
        // The person scrolls up two screens to read while it keeps streaming.
        let clip = scroller.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, clip.bounds.origin.y - clip.bounds.height * 2)))
        scroller.reflectScrolledClipView(clip)
        await Snapshot.pause(0.4)
        let readingAt = clip.bounds.origin.y
        for word in 80..<160 {
            vm.appendDelta(word % 12 == 11 ? "change \(word).\n\n" : "change \(word), ")
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        vm.endStreaming()
        await Snapshot.pause(0.4)
        let stayed = abs(clip.bounds.origin.y - readingAt) < 1
        let moved = clip.bounds.origin.y - readingAt
        let followingWhileReading = pager.following
        await picture(window, "long-chat-stream-reading", output)
        // A new prompt goes out while they read: the transcript goes to it.
        vm.promptHistory.append(.init(text: "Prompt #502: and the README?"))
        vm.appendMessage(.user, "Prompt #502: and the README?")
        await Snapshot.pause(0.6)
        let atNewPrompt = pager.following && (pager.geometry.bottom.map { $0.maxY - (pager.geometry.viewport ?? 0) <= 48 } ?? false)
        record("streaming: followed to the newest line: \(followed); scrolled up to read, the view stayed put: \(stayed) "
               + "(moved " + String(format: "%.0f pt", moved) + "), following: \(followingWhileReading), Latest button shown: "
               + "\(!followingWhileReading); a new prompt sent then brought the view to it: \(atNewPrompt)", in: output)
    }

    /// A picture of the window now, beside the scenes'.
    private static func picture(_ window: NSWindow, _ name: String, _ output: URL) async {
        if let image = try? await Snapshot.capture(window), let data = try? Snapshot.png(image, points: window.frame.size) {
            try? data.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
        }
    }

    /// The chat's transcript: the tallest vertical scroll view in the window that isn't a text view's.
    static func transcriptScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroller = view as? NSScrollView, scroller.hasVerticalScroller, !(scroller.documentView is NSTextView) {
                found.append(scroller)
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}
