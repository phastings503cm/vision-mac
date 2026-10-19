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

    /// The CLI a turn should run, with the status that explains a nil: the cached check while it is usable and the
    /// file is still there, else a fresh one.
    public func usableInstall() async -> (install: ClaudeCodeInstall?, status: ClaudeCodeStatus) {
        if let status, status.isUsable, let install = status.install,
           installOverride != nil || FileManager.default.isExecutableFile(atPath: install.path) {
            return (install, status)
        }
        let fresh = await refresh()
        return (fresh.isUsable ? fresh.install : nil, fresh)
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

    /// Why a turn can't start, with the steps — the words the chat shows.
    public static func notReadyMessage(_ status: ClaudeCodeStatus) -> String {
        var lines = [status.summary]
        for step in status.steps {
            lines.append(step.command.map { "\(step.text) `\($0)`" } ?? step.text)
        }
        lines.append("Settings ▸ Models ▸ Add ▸ Claude Code… shows this and checks again.")
        return lines.joined(separator: "\n")
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
