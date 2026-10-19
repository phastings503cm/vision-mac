import Foundation
import Observation
import VisionHarnessCore

/// Claude Code on this Mac, as the app sees it: where the `claude` command is, its version, whether it is signed in
/// (the card shows it), and how a turn starts it. The check is cached; a turn re-checks when the cached CLI is gone
/// or wasn't usable. Vision never reads the CLI's sign-in — `claude auth status` says whether there is one.
@MainActor
@Observable
public final class ClaudeCodeHost {
    /// The last check (nil = not checked yet).
    public private(set) var status: ClaudeCodeStatus?
    public private(set) var checking = false
    public private(set) var checkedAt: Date?

    /// Runs the short checks (`--version`, `--help`, `auth status`); tests script it.
    @ObservationIgnored var runner: any ClaudeCodeCommandRunner = ProcessClaudeCodeCommandRunner()
    /// Starts the CLI for a turn; tests replace it.
    @ObservationIgnored public var launcher: any ClaudeCodeLauncher = ProcessClaudeCodeLauncher()
    /// The path the person picked ("" = search).
    @ObservationIgnored var explicitPath: @MainActor () -> String = { "" }
    /// Tests: this install, without searching or asking it anything.
    @ObservationIgnored var installOverride: ClaudeCodeInstall?
    @ObservationIgnored private var inFlight: Task<ClaudeCodeStatus, Never>?
    /// Chats told this launch that they now use Claude Code.
    @ObservationIgnored var announced: Set<String> = []
    /// Chats told this launch that an API key pays instead of the Claude plan.
    @ObservationIgnored var keyNoted: Set<String> = []
    /// Chats told this launch that their folder's own Claude Code settings are left out.
    @ObservationIgnored var trustNoted: Set<String> = []
    /// Chats told this launch what the sensitive-data shield covers on Claude Code.
    @ObservationIgnored var shieldNoted: Set<String> = []
    /// Whether the person trusted a folder in Claude Code (its own record in ~/.claude.json); tests replace it.
    @ObservationIgnored var isTrusted: @Sendable (URL, [String: String]) -> Bool = { ClaudeCodeTrust.isTrusted($0, environment: $1) }

    public init() {}

    /// Check again now (one check at a time: a second caller waits for the one running).
    @discardableResult
    public func refresh() async -> ClaudeCodeStatus {
        if let override = installOverride {
            let status = ClaudeCodeStatus.ready(override, ClaudeCodeAuth(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty"))
            self.status = status
            checkedAt = .now
            return status
        }
        if let running = inFlight { return await running.value }
        checking = true
        let path = explicitPath()
        let runner = self.runner
        let task = Task.detached(priority: .userInitiated) {
            await ClaudeCodeDetector.check(explicitPath: path.isEmpty ? nil : path, runner: runner)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        status = result
        checking = false
        checkedAt = .now
        return result
    }

    /// The CLI a turn should run, with the status that explains a nil: the cached check while the CLI can run and
    /// the file is still there, else a fresh one. A signed-out CLI still runs: the turn says so in Claude Code's own
    /// words, and works the moment the person signs in.
    public func usableInstall() async -> (install: ClaudeCodeInstall?, status: ClaudeCodeStatus) {
        if let status, status.canRun, let install = status.install,
           installOverride != nil || FileManager.default.isExecutableFile(atPath: install.path) {
            return (install, status)
        }
        let fresh = await refresh()
        return (fresh.canRun ? fresh.install : nil, fresh)
    }

    /// Show this status without checking (the screenshot mode's scenes).
    func stage(_ status: ClaudeCodeStatus) {
        self.status = status
        checkedAt = .now
    }

    /// A turn found it signed out (or it stopped working): the card must say so next time.
    public func invalidate() {
        status = nil
    }

    /// Why a turn can't start — the words the chat shows.
    public static func notReadyMessage(_ status: ClaudeCodeStatus) -> String {
        status.summary + " The Claude Code card (Settings ▸ AI Models ▸ Add ▸ Claude Code…) shows how to install it and sign in."
    }
}

/// What adding Claude Code does to the routes — kept out of the view so it is testable.
enum ClaudeCodeRoutes {
    /// The route for one Claude Code model.
    static func route(_ alias: String) -> ProviderProfile {
        ProviderProfile(kind: .claudeCode, name: "Claude Code", baseURL: ProviderProfile.claudeCodeBaseURL, model: alias)
    }

    /// Add a route for each model that isn't there yet; with no primary model yet, the first becomes it. Returns the
    /// routes, in the order asked (existing ones included).
    @MainActor
    @discardableResult
    static func add(_ aliases: [String], to config: AppConfig) -> [ProviderProfile] {
        var routes: [ProviderProfile] = []
        for alias in aliases {
            let route = route(alias)
            if let existing = config.providers.first(where: { $0.routeID == route.routeID }) {
                if !existing.isEnabled { config.setEnabled(existing.routeID, true) }
                routes.append(existing)
            } else {
                config.store(route)
                routes.append(route)
            }
        }
        if config.activeProvider == nil, let first = routes.first { config.makeMain(first.routeID) }
        return routes
    }
}
