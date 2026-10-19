import Foundation

// MARK: - Guardian's structured refusals, in plain words
//
// Every /api/harness route answers a refusal with a structured body (harness-api-contract.md, "Errors and limits"):
//   401 {error:"unauthorized", message}
//   403 {error:"forbidden", reason:"module_disabled"|"permission_missing"|"org_not_member"|"scope_missing", needed, message}
//   402/429 {error:"budget_exceeded"|"limit_reached"|"rate_limited", limit:{kind, window, used, max, unit, resetsAt}, message}
//       + x-guardian-limit-kind / -window / -remaining / -reset headers
// Vision shows them as a dialog — what is missing and who can grant it; for limits the window and when it resets —
// never as a raw HTTP code. The same parsing serves the model proxy (chat completions) and the harness API.

/// One limit on the account: spend, tokens or requests in a window.
public struct GuardianLimit: Codable, Hashable, Sendable {
    /// "spend", "tokens" or "requests" (new kinds are shown as written).
    public var kind: String
    /// "day", "week", "month" or "run".
    public var window: String
    public var used: Double?
    public var max: Double?
    /// "usd", "tokens", "requests"…
    public var unit: String?
    public var resetsAt: Date?

    public init(kind: String, window: String, used: Double? = nil, max: Double? = nil, unit: String? = nil, resetsAt: Date? = nil) {
        self.kind = kind
        self.window = window
        self.used = used
        self.max = max
        self.unit = unit
        self.resetsAt = resetsAt
    }

    /// How much is left (nil when Guardian didn't say).
    public var remaining: Double? {
        guard let used, let max else { return nil }
        return Swift.max(0, max - used)
    }

    /// 0…1 of the allowance used.
    public var fraction: Double? {
        guard let used, let max, max > 0 else { return nil }
        return Swift.min(1, used / max)
    }

    /// "Spend today", "Tokens this week", "Streams at once".
    public var title: String {
        if unit?.lowercased() == "streams" { return "Streams at once" }
        let what: String = switch kind.lowercased() {
        case "spend": "Spend"
        case "tokens": "Tokens"
        case "requests": "Requests"
        case "storage": "Storage"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
        // A limit with no window (a storage cap) is just its kind.
        let phrase = Self.windowPhrase(window)
        return phrase.isEmpty ? what : what + " " + phrase
    }

    static func windowPhrase(_ window: String) -> String {
        switch window.lowercased() {
        case "", "total": ""
        case "day": "today"
        case "week": "this week"
        case "month": "this month"
        case "run": "for this run"
        case "minute": "this minute"
        case "hour": "this hour"
        default: "per \(window)"
        }
    }

    /// "$4.80 of $5.00", "1.2M of 2M tokens", "60 of 60 requests".
    public var usage: String? {
        guard let used else { return nil }
        let max = self.max
        let unit = (self.unit ?? (kind == "spend" ? "usd" : kind == "storage" ? "bytes" : kind)).lowercased()
        func amount(_ value: Double) -> String {
            switch unit {
            case "usd", "$", "dollars": return String(format: "$%.2f", value)
            case "tokens": return Self.compact(value)
            case "bytes", "b": return Self.bytes(value)
            default: return value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
            }
        }
        let suffix: String = switch unit {
        case "usd", "$", "dollars", "bytes", "b": ""
        case "tokens": " tokens"
        case "requests": " requests"
        case "streams": " streams"
        default: " " + unit
        }
        if let max { return "\(amount(used)) of \(amount(max))\(suffix)" }
        return "\(amount(used))\(suffix) used"
    }

    /// "4 GB", "512.5 MB", "300 KB" (Windows' storage words).
    static func bytes(_ value: Double) -> String {
        let gib = 1_073_741_824.0, mib = 1_048_576.0
        if value >= gib { return trim(value / gib) + " GB" }
        if value >= mib { return trim(value / mib) + " MB" }
        return String(Int((value / 1024).rounded())) + " KB"
    }

    static func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return trim(value / 1_000_000) + "M" }
        if value >= 1_000 { return trim(value / 1_000) + "k" }
        return String(Int(value))
    }

    private static func trim(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// "resets in 3 hours (Mon 9:00 AM)".
    public func resetPhrase(now: Date = .now) -> String? {
        guard let resetsAt else { return nil }
        return "resets " + GuardianProblem.relative(resetsAt, now: now) + " (" + GuardianProblem.clock(resetsAt) + ")"
    }
}

/// A structured refusal from Guardian.
public struct GuardianProblem: Error, Hashable, Sendable, Identifiable {
    public var id: String { "\(status)|\(error)|\(reason ?? "")|\(needed ?? "")|\(message ?? "")" }
    public var status: Int
    /// "unauthorized", "forbidden", "budget_exceeded", "limit_reached", "rate_limited".
    public var error: String
    public var reason: String?
    public var needed: String?
    public var message: String?
    public var limit: GuardianLimit?
    /// 429: how long Guardian asks to wait (its Retry-After header), in seconds.
    public var retryAfter: TimeInterval?

    public init(status: Int, error: String, reason: String? = nil, needed: String? = nil, message: String? = nil,
                limit: GuardianLimit? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.error = error
        self.reason = reason
        self.needed = needed
        self.message = message
        self.limit = limit
        self.retryAfter = retryAfter
    }

    /// The reason code in words, for the reasons the dialog's own lines don't name (the same words as Windows).
    public static func reasonPhrase(_ reason: String?) -> String? {
        switch reason {
        case "module_disabled": "that module is switched off for you"
        case "permission_missing": "your role doesn't include that permission"
        case "scope_missing": "this sign-in doesn't carry that scope"
        case "org_not_member": "you aren't a member of that organization"
        case "not_owner": "only the owner of that item can do this"
        case "model_not_allowed": "that model isn't available to you in this organization"
        default: nil
        }
    }

    public var isLimit: Bool { ["budget_exceeded", "limit_reached", "rate_limited"].contains(error) || status == 402 }
    /// Retrying soon can help (a per-minute rate limit); a spent budget or a missing permission won't change.
    public var isTransient: Bool { error == "rate_limited" }

    /// The dialog's title.
    public var title: String {
        switch error {
        case "unauthorized": return "Guardian sign-in needed"
        case "forbidden":
            return reason == "org_not_member" ? "Not a member of that Guardian organization" : "Your Guardian account doesn't allow this"
        case "rate_limited": return "Guardian is slowing this account down"
        default:
            if isLimit {
                switch limit?.kind.lowercased() {
                case "spend": return "Guardian spend limit reached"
                case "tokens": return "Guardian token limit reached"
                case "requests": return "Guardian request limit reached"
                case "storage": return "Guardian storage limit reached"
                default: return "Guardian limit reached"
                }
            }
            return "Guardian refused the request"
        }
    }

    /// The dialog's text: Guardian's own sentence, then what is missing and who can grant it, or the limit's
    /// window and reset time.
    public func detail(now: Date = .now) -> String {
        var lines: [String] = []
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty { lines.append(message) }
        switch error {
        case "unauthorized":
            lines.append("Sign in again in Settings ▸ Guardian.")
        case "forbidden":
            let what = needed.map { "“\($0)”" } ?? "access"
            switch reason {
            case "module_disabled":
                lines.append("Missing: the \(what) module is turned off for you. An admin of your Guardian organization can turn it on for you (Guardian ▸ Settings ▸ Members).")
            case "permission_missing":
                lines.append("Missing: the \(what) permission. An admin of your Guardian organization can grant it (Guardian ▸ Settings ▸ Members).")
            case "scope_missing":
                lines.append("Missing: this sign-in doesn't carry the \(what) scope. Sign out and sign in again in Settings ▸ Guardian; if it is still missing, an admin of your organization can grant it.")
            case "org_not_member":
                lines.append("You aren't a member of that organization. Pick another one in Settings ▸ Guardian, or ask its admin to add you.")
            default:
                let why = Self.reasonPhrase(reason).map { " — \($0)" } ?? reason.map { " (\($0))" } ?? ""
                lines.append("Missing: \(what)" + why + ". An admin of your Guardian organization can grant it.")
            }
        default:
            if let limit {
                var line = limit.title
                if let usage = limit.usage { line += ": " + usage }
                if let reset = limit.resetPhrase(now: now) { line += " — " + reset }
                lines.append(line + ".")
                if error == "rate_limited" {
                    lines.append("Vision tries again after the reset.")
                } else {
                    lines.append("Your Guardian organization's admin can raise the limit; otherwise it frees up when it resets.")
                }
            } else if isLimit, error != "rate_limited" {
                lines.append("Your Guardian organization's admin can raise the limit.")
            }
            if let retryAfter, retryAfter > 0 { lines.append("Try again in \(Int(retryAfter.rounded(.up))) s.") }
        }
        if lines.isEmpty { lines.append("Guardian answered HTTP \(status).") }
        return lines.joined(separator: "\n\n")
    }

    /// One line for a chat's error row.
    public func oneLine(now: Date = .now) -> String {
        "\(title). " + detail(now: now).replacingOccurrences(of: "\n\n", with: " ")
    }

    /// The structured problem in a response, or nil when the body isn't one of Guardian's (another server's error).
    public static func parse(status: Int, body: Data, headers: [String: String] = [:]) -> GuardianProblem? {
        guard !(200...299).contains(status) else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        // OpenAI-style wrapping: {error:{code, message, …}}.
        let root: [String: Any]? = {
            if let inner = object?["error"] as? [String: Any], inner["code"] is String || inner["reason"] != nil || inner["limit"] != nil {
                var merged = inner
                if let code = inner["code"] as? String { merged["error"] = code }
                return merged
            }
            return object
        }()
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        // Retry-After: seconds, or an HTTP date.
        let retryAfter: TimeInterval? = lowered["retry-after"].flatMap { value -> TimeInterval? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if let seconds = Double(trimmed) { return seconds > 0 ? seconds : nil }
            let http = DateFormatter()
            http.locale = Locale(identifier: "en_US_POSIX")
            http.timeZone = TimeZone(identifier: "GMT")
            http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = http.date(from: trimmed) else { return nil }
            let wait = date.timeIntervalSinceNow
            return wait > 0 ? wait : nil
        }
        let headerLimit: GuardianLimit? = lowered["x-guardian-limit-kind"].map { kind in
            GuardianLimit(kind: kind, window: lowered["x-guardian-limit-window"] ?? "day",
                          resetsAt: lowered["x-guardian-limit-reset"].flatMap(Self.date))
        }
        guard let error = root?["error"] as? String else {
            // A bare 402/429 with Guardian's headers is still a limit.
            if let headerLimit, status == 402 || status == 429 {
                return GuardianProblem(status: status, error: status == 429 ? "rate_limited" : "limit_reached", limit: headerLimit,
                                       retryAfter: retryAfter)
            }
            return nil
        }
        let known = ["unauthorized", "forbidden", "budget_exceeded", "limit_reached", "rate_limited"]
        guard known.contains(error) else { return nil }
        var limit: GuardianLimit?
        if let raw = root?["limit"] as? [String: Any] {
            limit = GuardianLimit(kind: raw["kind"] as? String ?? headerLimit?.kind ?? "spend",
                                  window: raw["window"] as? String ?? headerLimit?.window ?? "",
                                  used: number(raw["used"]), max: number(raw["max"]), unit: raw["unit"] as? String,
                                  resetsAt: (raw["resetsAt"]).flatMap(date) ?? headerLimit?.resetsAt)
        } else {
            limit = headerLimit
        }
        return GuardianProblem(status: status, error: error, reason: root?["reason"] as? String, needed: root?["needed"] as? String,
                               message: root?["message"] as? String, limit: limit,
                               retryAfter: error == "rate_limited" || status == 429 ? retryAfter : nil)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !(value is Bool) { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// ISO-8601 (with or without fractions), or epoch seconds/milliseconds.
    static func date(_ value: Any) -> Date? {
        if let text = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return d }
            if let seconds = Double(text) { return epoch(seconds) }
            return nil
        }
        if let n = value as? NSNumber { return epoch(n.doubleValue) }
        return nil
    }

    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }

    /// "in 3 hours", "in 12 minutes", "in 2 days", "now".
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 30 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "in \(max(1, minutes)) minute\(minutes == 1 ? "" : "s")" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "in \(hours) hour\(hours == 1 ? "" : "s")" }
        let days = Int((seconds / 86400).rounded())
        return "in \(days) days"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}

/// Where structured refusals are reported so the app can show its dialog, whichever call met them (a chat's model
/// call through the proxy, a settings action).
public enum GuardianProblems {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (GuardianProblem) -> Void)?

    public static func setHandler(_ handler: (@Sendable (GuardianProblem) -> Void)?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    public static func report(_ problem: GuardianProblem) {
        lock.lock(); let handler = self.handler; lock.unlock()
        handler?(problem)
    }
}
