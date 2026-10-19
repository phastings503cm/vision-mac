import Foundation

// MARK: - The Prompts timeline
//
// Every prompt a chat has sent, with how it ended: Completed with results, failed, stopped, still running, queued.
// One record per prompt the person sent (typed, a /goal, a skill, a chat task, a queue task) — never the harness's
// own rows ("↻ round 3: keep going", "🤖 Background agents finished"). Records are kept per chat in
// `prompt-timeline/<chatID>.json` next to the conversations, so the history survives a relaunch; a chat from before
// the timeline existed is backfilled once from its transcript.
//
// Pure values and functions: the Mac app, the Windows harness and the tests drive the same rules (labels, grouping,
// search, the quote a prompt becomes in the composer, matching a record to its row in the transcript).

public struct PromptRecord: Codable, Hashable, Sendable, Identifiable {
    /// Where the prompt came from.
    public enum Source: String, Codable, Hashable, Sendable {
        /// Typed and sent in the chat.
        case typed
        /// `/goal <objective>`.
        case goal
        /// A chat task: queued with "Add to tasks" and started when the chat was free.
        case task
        /// A task of the unattended queue, worked in this chat.
        case queue
        /// `/name args`: a skill run by name.
        case skill

        public var label: String {
            switch self {
            case .typed: "Prompt"
            case .goal: "Goal"
            case .task: "Task"
            case .queue: "Queue task"
            case .skill: "Skill"
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Source(rawValue: raw) ?? .typed
        }
    }

    /// How it ended (or where it is now).
    public enum Outcome: String, Codable, Hashable, Sendable {
        case queued, running, completed
        /// Finished, but validation still found something wrong (the retry cap was reached).
        case issues
        /// A goal or task paused because the agent needs the person.
        case needsYou
        case failed, stopped
        /// A prompt from before the timeline existed whose ending the transcript doesn't say.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Outcome(rawValue: raw) ?? .unknown
        }

        /// Still going (or waiting to): no finish time, no duration yet.
        public var isOpen: Bool { self == .queued || self == .running }
    }

    public var id: String
    public var chatID: String
    /// What the person asked (a goal's objective, a task's prompt — without the harness's display prefixes).
    public var text: String
    public var source: Source
    /// When it was sent (for a queued task: when it was added).
    public var at: Date
    public var outcome: Outcome
    public var finishedAt: Date?
    /// The estimate the planning phase stated, seconds.
    public var etaSeconds: Double?
    /// Validation attempts: 1 = it passed the first time; each loop-back adds one.
    public var attempts: Int
    /// Goal rounds, for a goal or a queue task.
    public var rounds: Int?
    /// The task kind the estimator classified it as (`TurnPhaseState.TaskKind` raw value).
    public var taskKind: String?
    /// The model id and the route (server) name the main agent ran it on.
    public var model: String?
    public var route: String?
    public var promptTokens: Int
    public var completionTokens: Int
    /// What validation gathered (screenshots, files changed, checks, the closing summary).
    public var evidence: [TurnPhaseState.Evidence]
    /// The results line ("Validated against the plan: 6 of 6 steps done.") and the model's closing summary.
    public var completionNote: String?
    /// Why it failed, stopped or needs the person.
    public var reason: String?
    /// The turn-phase turn it ran as.
    public var turnID: String?
    /// The transcript row it produced, exactly as displayed ("🎯 /goal …") and when — how "Jump" finds it again.
    public var entryText: String?
    public var entryAt: Date?
    /// Reconstructed from a transcript written before the timeline existed (outcome inferred, no ETA/evidence).
    public var backfilled: Bool

    public init(id: String = UUID().uuidString, chatID: String, text: String, source: Source = .typed,
                at: Date = Date(), outcome: Outcome = .running, finishedAt: Date? = nil, etaSeconds: Double? = nil,
                attempts: Int = 1, rounds: Int? = nil, taskKind: String? = nil, model: String? = nil,
                route: String? = nil, promptTokens: Int = 0, completionTokens: Int = 0,
                evidence: [TurnPhaseState.Evidence] = [], completionNote: String? = nil, reason: String? = nil,
                turnID: String? = nil, entryText: String? = nil, entryAt: Date? = nil, backfilled: Bool = false) {
        self.id = id
        self.chatID = chatID
        self.text = text
        self.source = source
        self.at = at
        self.outcome = outcome
        self.finishedAt = finishedAt
        self.etaSeconds = etaSeconds
        self.attempts = attempts
        self.rounds = rounds
        self.taskKind = taskKind
        self.model = model
        self.route = route
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.evidence = evidence
        self.completionNote = completionNote
        self.reason = reason
        self.turnID = turnID
        self.entryText = entryText
        self.entryAt = entryAt
        self.backfilled = backfilled
    }

    private enum CodingKeys: String, CodingKey {
        case id, chatID, text, source, at, outcome, finishedAt, etaSeconds, attempts, rounds, taskKind, model, route
        case promptTokens, completionTokens, evidence, completionNote, reason, turnID, entryText, entryAt, backfilled
    }

    /// Tolerant: a field a newer or older build wrote differently takes its default rather than losing the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        chatID = try c.decodeIfPresent(String.self, forKey: .chatID) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .typed
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        outcome = (try? c.decodeIfPresent(Outcome.self, forKey: .outcome)) ?? .unknown
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        etaSeconds = try? c.decodeIfPresent(Double.self, forKey: .etaSeconds)
        attempts = (try? c.decodeIfPresent(Int.self, forKey: .attempts)) ?? 1
        rounds = try? c.decodeIfPresent(Int.self, forKey: .rounds)
        taskKind = try? c.decodeIfPresent(String.self, forKey: .taskKind)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        route = try? c.decodeIfPresent(String.self, forKey: .route)
        promptTokens = (try? c.decodeIfPresent(Int.self, forKey: .promptTokens)) ?? 0
        completionTokens = (try? c.decodeIfPresent(Int.self, forKey: .completionTokens)) ?? 0
        evidence = (try? c.decodeIfPresent([TurnPhaseState.Evidence].self, forKey: .evidence)) ?? []
        completionNote = try? c.decodeIfPresent(String.self, forKey: .completionNote)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        turnID = try? c.decodeIfPresent(String.self, forKey: .turnID)
        entryText = try? c.decodeIfPresent(String.self, forKey: .entryText)
        entryAt = try? c.decodeIfPresent(Date.self, forKey: .entryAt)
        backfilled = (try? c.decodeIfPresent(Bool.self, forKey: .backfilled)) ?? false
    }

    // MARK: Derived

    /// Wall clock from sending to the end (nil while it is still going).
    public var durationSeconds: Double? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(at))
    }

    /// The outcome as the timeline says it — the same words on every harness.
    public var headline: String {
        switch outcome {
        case .queued: "Queued"
        case .running: "Running"
        case .completed: evidence.isEmpty ? "Completed" : "Completed with results"
        case .issues: "Finished with issues"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Outcome not recorded"
        }
    }

    /// SF Symbol for the outcome chip.
    public var symbol: String {
        switch outcome {
        case .queued: "clock"
        case .running: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        case .issues: "exclamationmark.circle"
        case .needsYou: "pause.circle"
        case .failed: "xmark.circle"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// The first line, for a one-line row.
    public var firstLine: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Rules

public enum PromptTimeline {
    /// The most records a chat keeps (the oldest go first). A chat that sent more is a very long chat.
    public static let maxRecordsPerChat = 500

    // MARK: Timing

    /// "5m 12s · est. about 4 min" — the duration against the estimate; "running 1m 40s · est. …" while it runs.
    public static func timing(_ record: PromptRecord, now: Date = Date()) -> String {
        var parts: [String] = []
        if let duration = record.durationSeconds {
            parts.append(duration.formattedDuration)
        } else if record.outcome == .running {
            parts.append("running \(max(0, now.timeIntervalSince(record.at)).formattedDuration)")
        }
        if let eta = record.etaSeconds { parts.append("est. \(TurnPhaseState.phrase(eta))") }
        if record.attempts > 1 { parts.append("\(record.attempts) attempts") }
        if let rounds = record.rounds, rounds > 1 { parts.append("\(rounds) rounds") }
        if !record.evidence.isEmpty {
            parts.append("\(record.evidence.count) evidence item\(record.evidence.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// How the duration compares with the estimate, for the results view ("on time", "2m over the estimate").
    public static func versusEstimate(_ record: PromptRecord) -> String? {
        guard let duration = record.durationSeconds, let eta = record.etaSeconds, eta > 0 else { return nil }
        let delta = duration - eta
        if abs(delta) <= max(10, eta * 0.15) { return "on time" }
        return delta > 0 ? "\(delta.formattedDuration) over the estimate" : "\((-delta).formattedDuration) under the estimate"
    }

    // MARK: Grouping and search

    public struct DayGroup: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public var title: String
        public var records: [PromptRecord]
    }

    /// "Today", "Yesterday", a weekday within the last week, else "Oct 12" (with the year when it isn't this year).
    public static func dayTitle(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if days < 7 {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Newest first, under day headings.
    public static func grouped(_ records: [PromptRecord], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        let sorted = records.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        var groups: [DayGroup] = []
        for record in sorted {
            let title = dayTitle(for: record.at, now: now, calendar: calendar)
            if groups.last?.title == title {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(DayGroup(title: title, records: [record]))
            }
        }
        return groups
    }

    /// The records whose text, notes, outcome or chat title contain every word of `query` (any case, any order).
    public static func filter(_ records: [PromptRecord], query: String, chatTitles: [String: String] = [:]) -> [PromptRecord] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return records }
        return records.filter { record in
            let haystack = [record.text, record.completionNote ?? "", record.reason ?? "", record.headline,
                            record.source.label, chatTitles[record.chatID] ?? "", record.model ?? ""]
                .joined(separator: "\n").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: Talking about an earlier prompt

    /// What "Add to composer" drops into the composer: the prompt as a quote with when it ran and how it ended, so the
    /// model can be asked about it with its results in view.
    public static func quote(_ record: PromptRecord, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d 'at' HH:mm"
        var head = "About my earlier \(record.source == .typed ? "prompt" : record.source.label.lowercased()) (sent \(formatter.string(from: record.at)) — \(record.headline)"
        if let duration = record.durationSeconds { head += ", \(duration.formattedDuration)" }
        head += "):"
        let maxLines = 12, maxChars = 1_200
        var lines = record.text.components(separatedBy: "\n")
        var truncated = false
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); truncated = true }
        var body = lines.joined(separator: "\n")
        if body.count > maxChars { body = String(body.prefix(maxChars)); truncated = true }
        var quoted = body.components(separatedBy: "\n").map { "> " + $0 }
        if truncated { quoted.append("> …") }
        var out = head + "\n" + quoted.joined(separator: "\n")
        var outcome: [String] = []
        if !record.evidence.isEmpty {
            outcome.append(record.evidence.prefix(4).map(\.title).joined(separator: "; "))
        }
        if let note = record.completionNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            outcome.append(String(String(note.split(separator: "\n").first ?? Substring(note)).prefix(240)))
        }
        if let reason = record.reason, !reason.isEmpty, record.outcome != .completed { outcome.append(reason) }
        if !outcome.isEmpty { out += "\nOutcome: " + outcome.joined(separator: " · ") }
        return out + "\n\n"
    }

    // MARK: Finding its row in the transcript

    /// A transcript row a record may point at.
    public struct EntryRef: Hashable, Sendable {
        public var id: String
        public var text: String
        public var at: Date
        public init(id: String, text: String, at: Date) {
            self.id = id
            self.text = text
            self.at = at
        }
    }

    /// The transcript row this prompt produced: the user row with the same displayed text closest in time (rows read
    /// back from disk carry the time they were logged, a moment after they were shown), else the closest user row that
    /// contains the prompt's first line. Nil when the chat no longer has it (compacted away).
    public static func matchEntry(_ record: PromptRecord, in candidates: [EntryRef]) -> String? {
        let anchor = record.entryAt ?? record.at
        let exact = candidates.filter { $0.text == (record.entryText ?? record.text) }
        if let best = exact.min(by: { abs($0.at.timeIntervalSince(anchor)) < abs($1.at.timeIntervalSince(anchor)) }) {
            return best.id
        }
        let first = record.firstLine
        guard !first.isEmpty else { return nil }
        let loose = candidates.filter { $0.text.contains(first) }
        return loose.min(by: { abs($0.at.timeIntervalSince(anchor)) < abs($1.at.timeIntervalSince(anchor)) })?.id
    }

    // MARK: Backfill from a transcript

    /// One stored transcript row, as the backfill reads it.
    public struct Row: Hashable, Sendable {
        /// user | assistant | notice | error | tool | compaction
        public var kind: String
        public var text: String
        public var at: Date
        public init(kind: String, text: String, at: Date) {
            self.kind = kind
            self.text = text
            self.at = at
        }
    }

    /// What a user row in the transcript is: a prompt the person sent (and its source and text), or one of the
    /// harness's own rows that belongs to the prompt before it. The display strings are the harness's own — they are
    /// matched, never changed.
    public static func classify(_ userRow: String) -> (source: PromptRecord.Source, text: String)? {
        let continuations = ["↻ round", "🤖 Background agents finished", "🚀 queue (resuming)", "🎯 /goal (resuming)"]
        if continuations.contains(where: { userRow.hasPrefix($0) }) { return nil }
        if userRow.hasPrefix("🚀 queue: ") { return (.queue, String(userRow.dropFirst("🚀 queue: ".count))) }
        if userRow.hasPrefix("🎯 /goal ") { return (.goal, String(userRow.dropFirst("🎯 /goal ".count))) }
        if userRow.hasPrefix("/") { return (.skill, userRow) }
        return (.typed, userRow)
    }

    /// Records for a chat whose prompts were sent before the timeline existed: one per prompt row, its ending read
    /// from what followed it (a Stop notice, an error, a goal's ✅/⏸ line, an answer).
    public static func backfill(chatID: String, rows: [Row]) -> [PromptRecord] {
        var records: [PromptRecord] = []
        var spans: [[Row]] = []
        for row in rows {
            if row.kind == "user", let (source, text) = classify(row.text) {
                records.append(PromptRecord(chatID: chatID, text: text, source: source, at: row.at, outcome: .unknown,
                                            entryText: row.text, entryAt: row.at, backfilled: true))
                spans.append([])
            } else if !spans.isEmpty {
                spans[spans.count - 1].append(row)
            }
        }
        for index in records.indices {
            let span = spans[index]
            var record = records[index]
            if let last = span.last { record.finishedAt = max(last.at, record.at) }
            let notices = span.filter { $0.kind == "notice" }.map(\.text)
            let lastAnswer = span.last { $0.kind == "assistant" }?.text
            if notices.contains(where: { $0.hasPrefix("Stopped") }) {
                record.outcome = .stopped
            } else if notices.contains(where: { $0.hasPrefix("✅ Goal complete") || $0.hasPrefix("✅ Task complete") }) {
                record.outcome = .completed
            } else if let paused = notices.first(where: { $0.hasPrefix("⏸ Goal paused") || $0.hasPrefix("⏸ Task blocked") }) {
                record.outcome = .needsYou
                record.reason = String(paused.prefix(300))
            } else if let last = span.last(where: { $0.kind != "notice" }), last.kind == "error" {
                record.outcome = .failed
                record.reason = String(last.text.prefix(300))
            } else if lastAnswer != nil {
                record.outcome = .completed
            }
            if let lastAnswer, !lastAnswer.isEmpty { record.completionNote = String(lastAnswer.prefix(600)) }
            record.rounds = span.filter { $0.kind == "user" && $0.text.hasPrefix("↻ round") }.count + 1
            if record.rounds == 1 { record.rounds = nil }
            records[index] = record
        }
        return records
    }

    /// Keep the newest `maxRecordsPerChat`.
    public static func capped(_ records: [PromptRecord]) -> [PromptRecord] {
        guard records.count > maxRecordsPerChat else { return records }
        return Array(records.sorted { $0.at < $1.at }.suffix(maxRecordsPerChat))
    }
}

// MARK: - Storage

/// The timeline files: `<directory>/<chatID>.json` = `{schema, chatID, prompts}` with ISO-8601 dates (milliseconds).
/// Written atomically; an unreadable file is set aside rather than overwritten.
public final class PromptTimelineStore: @unchecked Sendable {
    public static let schema = "vision.prompts/1"

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private struct File: Codable {
        var schema: String
        var chatID: String
        var prompts: [PromptRecord]
    }

    public func fileURL(_ chatID: String) -> URL {
        directory.appendingPathComponent(Self.safeName(chatID) + ".json")
    }

    /// A chat id as a file name: letters, digits, dash and underscore only.
    static func safeName(_ chatID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(chatID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter().string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = isoFormatter().date(from: text) { return date }
                let plain = ISO8601DateFormatter()
                if let date = plain.date(from: text) { return date }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO-8601 date: \(text)")
            }
            // Seconds since 1970, as another harness might write.
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }
        return decoder
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// The chat's records, oldest first; nil when it has no timeline file yet (backfill it).
    public func load(_ chatID: String) -> [PromptRecord]? {
        lock.withLock {
            let url = fileURL(chatID)
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let file = try? Self.decoder().decode(File.self, from: data) else {
                // Never overwrite what can't be read: keep it beside the new one.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                return nil
            }
            return file.prompts.sorted { $0.at < $1.at }
        }
    }

    public func save(_ chatID: String, _ records: [PromptRecord]) {
        lock.withLock {
            let file = File(schema: Self.schema, chatID: chatID, prompts: PromptTimeline.capped(records))
            guard let data = try? Self.encoder().encode(file) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(chatID), options: .atomic)
        }
    }

    public func delete(_ chatID: String) {
        lock.withLock { try? FileManager.default.removeItem(at: fileURL(chatID)) }
    }

    /// Every chat that has a timeline file.
    public func chatIDs() -> [String] {
        lock.withLock {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasSuffix(".json") && !$0.contains(".unreadable-") }.map { String($0.dropLast(5)) }
        }
    }
}
