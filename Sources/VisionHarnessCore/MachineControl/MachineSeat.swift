import Foundation

// MARK: - A chat's seat at the machine
//
// Every chat that may see or steer the Mac has one `MachineSeat`: who it is to
// the arbiter (its id and title), how it prefers to act (in the background
// first), what it is doing right now (for the glow and the chat's status
// line), and — when the person asks for it — which apps it may control: the
// processes it started itself (and their children) and the apps the person
// allowed for this chat. Subagents get a child seat: their own place in line,
// the same scope, the same chat name.

/// An app or process on the receiving end of a control action.
public struct ControlTarget: Sendable, Equatable, Hashable {
    public var pid: pid_t
    /// The app's name ("TextEdit", "Godot") or the process name for a bare binary.
    public var name: String
    public var bundleIdentifier: String?

    public init(pid: pid_t, name: String, bundleIdentifier: String? = nil) {
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    /// The key a per-chat approval is stored under: the bundle id when there is one, else the name.
    public var approvalKey: String { (bundleIdentifier ?? name).lowercased() }
}

/// How a chat may act on the machine. Set from Settings ▸ Computer and per chat with `/control`.
public struct MachineControlOptions: Sendable, Equatable, Codable {
    /// Act through Accessibility and process-addressed events first; the real mouse/keyboard only when needed.
    public var preferBackground: Bool
    /// Only control what this chat started, and apps the person allowed for it.
    public var restrictToOwnApps: Bool
    /// How long to wait for the real mouse/keyboard (another chat or the person has them).
    public var waitTimeout: TimeInterval

    public init(preferBackground: Bool = true, restrictToOwnApps: Bool = false,
                waitTimeout: TimeInterval = ControlArbiter.defaultWaitTimeout) {
        self.preferBackground = preferBackground
        self.restrictToOwnApps = restrictToOwnApps
        self.waitTimeout = waitTimeout
    }

    // Decoding tolerates a missing field (a settings file from another version): the default stands in.
    private enum CodingKeys: String, CodingKey { case preferBackground, restrictToOwnApps, waitTimeout }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferBackground = try c.decodeIfPresent(Bool.self, forKey: .preferBackground) ?? true
        restrictToOwnApps = try c.decodeIfPresent(Bool.self, forKey: .restrictToOwnApps) ?? false
        waitTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .waitTimeout) ?? ControlArbiter.defaultWaitTimeout
    }

    /// The waits Settings ▸ Computer offers, in seconds.
    public static let waitChoices: [TimeInterval] = [30, 60, 90, 180, 300]
}

/// What a seat is doing, for the chat's status line and the glow.
public enum SeatActivity: Sendable, Equatable {
    case idle
    /// In line for the real mouse and keyboard; `holder` has them (nil: another copy of the app).
    case waitingForControls(holder: String?)
    /// Holding the controls, waiting for the person to finish with the mouse/keyboard.
    case waitingForPerson
    /// Using the real mouse/keyboard in this app.
    case controlling(app: String)
    /// Acting on this app without the mouse (Accessibility, events posted to the process).
    case background(app: String)

    /// The line a chat shows while its tool waits (nil when nothing is worth saying).
    public var statusLine: String? {
        switch self {
        case .idle, .controlling, .background: nil
        case .waitingForControls(let holder):
            "Waiting for the mouse — " + (holder.map { "“\($0)” is using it" } ?? "another copy of \(AppIdentity.name) is using it")
                + ". It goes to the next chat when that one is done; ⌃⌥⌘. stops all control."
        case .waitingForPerson:
            "Waiting for you to finish with the mouse and keyboard…"
        }
    }
}

/// The scope a chat's control is limited to (shared by the chat and its subagents).
final class SeatScope: @unchecked Sendable {
    let lock = NSLock()
    var spawned: Set<pid_t> = []
    var approved: Set<String> = []
    var options = MachineControlOptions()
    /// Set per chat with `/control only …` / `/control any`; nil = the setting.
    var restrictOverride: Bool?
}

public final class MachineSeat: @unchecked Sendable {
    public let chatID: String
    /// This engine's id in the arbiter's line (the chat id, or the chat id + a subagent suffix).
    public let holderID: String
    public let arbiter: ControlArbiter
    let scope: SeatScope
    private let lock = NSLock()
    private var _title: String
    private var _activity: SeatActivity = .idle
    private var children = 0
    /// Told about every activity change (the app shows it in the chat and the glow).
    public var onActivity: (@Sendable (SeatActivity) -> Void)? {
        get { lock.guarded { _onActivity } }
        set { lock.guarded { _onActivity = newValue } }
    }
    private var _onActivity: (@Sendable (SeatActivity) -> Void)?

    public init(chatID: String, title: String, arbiter: ControlArbiter = .shared) {
        self.chatID = chatID
        self.holderID = chatID
        self.arbiter = arbiter
        self.scope = SeatScope()
        self._title = title
    }

    private init(parent: MachineSeat, suffix: String) {
        self.chatID = parent.chatID
        self.holderID = parent.holderID + "/" + suffix
        self.arbiter = parent.arbiter
        self.scope = parent.scope
        self._title = parent.title
        self._onActivity = parent.onActivity
    }

    /// A seat for a subagent of this chat: its own place in line, the chat's scope and name.
    public func child() -> MachineSeat {
        let n: Int = lock.guarded { children += 1; return children }
        return MachineSeat(parent: self, suffix: "sub\(n)")
    }

    /// A seat for tools run outside any chat (tests, scripts).
    public static func detached() -> MachineSeat {
        MachineSeat(chatID: "detached-\(UUID().uuidString.prefix(8))", title: "a background run")
    }

    public var title: String {
        get { lock.guarded { _title } }
        set { lock.guarded { _title = newValue } }
    }

    public var holder: ControlHolder { ControlHolder(id: holderID, chatID: chatID, label: title) }

    public var activity: SeatActivity { lock.guarded { _activity } }

    public func setActivity(_ activity: SeatActivity) {
        let (changed, observer): (Bool, (@Sendable (SeatActivity) -> Void)?) = lock.guarded {
            let changed = _activity != activity
            _activity = activity
            return (changed, _onActivity)
        }
        if changed { observer?(activity) }
    }

    // MARK: Options and scope

    public var options: MachineControlOptions {
        get { scope.lock.guarded { scope.options } }
        set { scope.lock.guarded { scope.options = newValue } }
    }

    /// Whether this chat's control is limited to its own apps right now (the `/control` override, else the setting).
    public var isRestricted: Bool {
        scope.lock.guarded { scope.restrictOverride ?? scope.options.restrictToOwnApps }
    }

    /// `/control only` (true), `/control any` (false), or back to the setting (nil).
    public func setRestricted(_ restricted: Bool?) {
        scope.lock.guarded { scope.restrictOverride = restricted }
    }

    /// A process this chat started (process_start): it and its children are in scope.
    public func noteSpawned(pid: pid_t) {
        guard pid > 0 else { return }
        _ = scope.lock.guarded { scope.spawned.insert(pid) }
    }

    /// The person allowed this chat to control the app.
    public func approve(_ target: ControlTarget) {
        _ = scope.lock.guarded { scope.approved.insert(target.approvalKey) }
    }

    /// Allow apps by name (`/control only Safari, Godot`).
    public func approve(names: [String]) {
        scope.lock.guarded {
            for name in names {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !clean.isEmpty { scope.approved.insert(clean) }
            }
        }
    }

    public var approvedNames: [String] { scope.lock.guarded { scope.approved.sorted() } }
    public var spawnedPIDs: Set<pid_t> { scope.lock.guarded { scope.spawned } }

    public enum ScopeDecision: Sendable, Equatable {
        case allowed
        /// Out of this chat's scope: ask the person (approving adds the app to the scope).
        case needsApproval(String)
    }

    /// Whether this chat may act on `target`. Unrestricted chats may act on any app (the per-chat control
    /// grant still applies); restricted ones on what they started (or its descendants) and approved apps.
    public func decide(_ target: ControlTarget, parentOf: (pid_t) -> pid_t?) -> ScopeDecision {
        guard isRestricted else { return .allowed }
        let (spawned, approved) = scope.lock.guarded { (scope.spawned, scope.approved) }
        if approved.contains(target.approvalKey) || approved.contains(target.name.lowercased()) { return .allowed }
        // The process or one of its ancestors was started by this chat.
        var pid: pid_t? = target.pid
        var hops = 0
        while let current = pid, current > 1, hops < 64 {
            if spawned.contains(current) { return .allowed }
            pid = parentOf(current)
            hops += 1
        }
        return .needsApproval(target.name)
    }

    /// The question the person is asked when a restricted chat reaches for another app.
    public static func approvalPrompt(chat: String, app: String) -> String {
        "“\(chat)” is limited to the apps it opened and the ones you allow. It wants to control \(app). Allowing covers \(app) for the rest of this chat."
    }

    /// What the tool says when the person declined.
    public static func declinedMessage(app: String) -> String {
        "Error: not allowed to control \(app) — this chat is limited to the apps it started and the ones the user allows, and the user declined \(app). Work in an app you started (process_start), or ask the user."
    }
}

extension NSLock {
    /// Run `body` holding the lock (named apart from Foundation's `withLock`, which a file here shadows).
    func guarded<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
