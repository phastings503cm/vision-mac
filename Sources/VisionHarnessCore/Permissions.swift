import Foundation

// MARK: - Permission policy (workspace-write by default, like the DGX guide's presets)

/// How much of the machine the agent may touch without asking.
public enum PermissionPreset: String, Codable, CaseIterable, Sendable {
    /// Reads anywhere; writes and commands stay inside the project folder.
    case workspaceWrite
    /// Same, but shell commands also require approval even inside the project.
    case plan
    /// Writes and commands allowed without asking (still confined to the project
    /// for file tools; the model is trusted for the rest).
    case fullAccess
}

/// Outcome of asking a tool call's permission gate.
public enum PermissionDecision: Sendable {
    case proceed
    case deny(reason: String)
    case ask
}

public struct PermissionPolicy: Sendable {
    public var preset: PermissionPreset
    /// Root the write shell is confined to. Everything relative to this.
    public var workspaceRoot: URL

    public init(preset: PermissionPreset, workspaceRoot: URL) {
        self.preset = preset
        self.workspaceRoot = workspaceRoot.standardizedFileURL
    }

    // MARK: - Path containment

    /// Resolve a model-supplied path (may be relative, `~/…`, or absolute)
    /// against the workspace root and check it stays inside it.
    public func resolve(_ raw: String) -> (url: URL, inside: Bool) {
        let expanded = expand(raw)
        let resolved = URL(fileURLWithPath: expanded).standardizedFileURL
        let inside = path(resolved)
        return (resolved, inside)
    }

    private func path(_ other: URL) -> Bool {
        other.path == workspaceRoot.path || other.path.hasPrefix(workspaceRoot.path + "/")
    }

    /// Expand `~` and make relative paths absolute against the workspace.
    public func expand(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t == "~" { return NSHomeDirectory() }
        if t.hasPrefix("~/") {
            return NSHomeDirectory() + String(t.dropFirst(1))
        }
        if t.hasPrefix("/") { return t }
        return URL(fileURLWithPath: workspaceRoot.path).appendingPathComponent(t).path
    }

    // MARK: - Gates

    /// File-write tools.
    public func checkWrite(path raw: String) -> PermissionDecision {
        if preset == .fullAccess { return .proceed }
        // Plan mode promises the user nothing gets modified, so a write asks
        // wherever it lands rather than only outside the project.
        if preset == .plan { return .ask }
        let (_, inside) = resolve(raw)
        return inside ? .proceed : .ask
    }

    /// Shell commands. We never inspect the command string deeply; the rule is
    /// positional: workspaceWrite lets reads through implicitly (commands that
    /// only read are fine), but any *potentially mutating* command asks.
    public func checkShell(command: String) -> PermissionDecision {
        switch preset {
        case .plan:
            return .ask
        case .fullAccess:
            return .proceed
        case .workspaceWrite:
            // Heuristic: treat the command as safe to run without asking when
            // it does not contain obvious mutation operators.
            let mutating = ["rm ", "sudo", "> ", ">>", "mv ", "cp ", "mkdir", "chmod",
                            "chown", "dd ", "git push", "git commit", "git checkout",
                            "git reset", "brew install", "pip install", "npm install",
                            "git branch -d", "git rebase", "git merge"]
            for m in mutating where command.contains(m) {
                return .ask
            }
            return .proceed
        }
    }

    /// Web fetch: read-only; only `fullAccess` restrictions matter (none).
    public func checkFetch() -> PermissionDecision { .proceed }

    /// Seeing or driving the rest of the machine. Screenshots can capture
    /// anything on screen (and are sent to the model), and mouse/keyboard
    /// control acts as the user in any app, so neither is implicit: the first
    /// use in a chat asks, and an approval holds for that chat (see
    /// `ComputerGrants`). Plan mode never drives the machine.
    public func checkComputer(_ access: ComputerAccess) -> PermissionDecision {
        switch preset {
        case .fullAccess: return .proceed
        case .plan:
            return access == .control
                ? .deny(reason: "Plan mode is read-only: no mouse or keyboard control.")
                : .ask
        case .workspaceWrite: return .ask
        }
    }
}

/// What a computer-use tool needs from the machine.
public enum ComputerAccess: String, Sendable, Hashable, CaseIterable {
    /// Read-only: screenshots, window lists, accessibility trees, inspecting processes.
    case observe
    /// Acts as the user: mouse, keyboard, bringing apps to the front.
    case control

    /// The access a tool needs, or nil for tools that don't touch the machine
    /// outside the project.
    public static func forTool(_ name: String) -> ComputerAccess? {
        switch name {
        case "screenshot", "list_windows", "screen_watch", "ui_tree", "inspect_process", "view_image": .observe
        case "mouse", "keyboard", "focus_app", "ui_action": .control
        default: nil
        }
    }

    public var prompt: String {
        switch self {
        case .observe:
            "Screen access — the agent wants to look at your screen: screenshots of apps and windows, window titles, and process details. What it captures is sent to the model. Allowing covers the rest of this chat."
        case .control:
            "Computer control — the agent wants to press buttons, type, click and bring apps to the front, acting as you. It works in the background when it can and waits its turn for your mouse otherwise. Allowing covers the rest of this chat. Press ⌘. to stop this chat, or ⌃⌥⌘. in any app to stop all control."
        }
    }
}

/// Approvals the user has given in one chat. A class so it survives the
/// engine being rebuilt between turns.
public final class ComputerGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Set<ComputerAccess> = []
    public init() {}

    public func has(_ access: ComputerAccess) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Control implies the ability to see what you are controlling.
        return granted.contains(access) || (access == .observe && granted.contains(.control))
    }

    public func grant(_ access: ComputerAccess) {
        lock.lock(); granted.insert(access); lock.unlock()
    }

    public func revokeAll() {
        lock.lock(); granted.removeAll(); lock.unlock()
    }
}