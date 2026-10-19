import SwiftUI
import VisionHarnessCore

/// Shared visual tokens. Everything the app draws pulls its colours, metrics,
/// and fonts from here so the chat, the editor, and the terminal read as one
/// tool rather than three.
enum Theme {
    // MARK: Metrics

    static let corner: CGFloat = 8
    static let rowSpacing: CGFloat = 18
    static let gutter: CGFloat = 26      // role marker column in the transcript
    static let contentPadding: CGFloat = 20
    static let maxTranscriptWidth: CGFloat = 780

    // MARK: Colours

    static let userTint = Color.accentColor
    static let assistantTint = Color.secondary
    static let noticeTint = Color.orange
    static let errorTint = Color.red
    static let successTint = Color.green

    /// Card fill that stays legible on both appearances.
    static var surface: Color { Color.primary.opacity(0.045) }
    static var surfaceStrong: Color { Color.primary.opacity(0.075) }
    static var hairline: Color { Color.primary.opacity(0.10) }

    // MARK: Fonts

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
    static var codeFont: Font { .system(.callout, design: .monospaced) }
    static var metaFont: Font { .system(size: 11) }

    // MARK: Tool vocabulary

    /// SF Symbol for a tool call, so a transcript is scannable at a glance.
    static func toolIcon(_ name: String) -> String {
        switch name {
        case "read_file", "read_many_files": return "doc.text"
        case "write_file": return "square.and.pencil"
        case "edit": return "pencil.line"
        case "list_directory": return "folder"
        case "glob": return "doc.text.magnifyingglass"
        case "grep": return "text.magnifyingglass"
        case "run_shell_command": return "terminal"
        case "web_fetch": return "globe"
        case "todo_write": return "checklist"
        case "agent": return "person.2"
        case "delegate": return "person.3"
        case "exit_plan_mode": return "list.clipboard"
        case "use_skill": return "graduationcap"
        case "propose_skill": return "graduationcap.fill"
        case "screenshot": return "camera.viewfinder"
        case "list_windows": return "macwindow.on.rectangle"
        case "screen_watch": return "video"
        case "ui_tree": return "list.bullet.indent"
        case "mouse": return "cursorarrow.click"
        case "keyboard": return "keyboard"
        case "focus_app": return "macwindow"
        case "view_image": return "photo"
        case "inspect_process": return "stethoscope"
        case "process_start", "process_read", "process_write", "process_stop", "process_list": return "gearshape.2"
        default: return "wrench.and.screwdriver"
        }
    }

    /// Human label for a tool call.
    static func toolLabel(_ name: String) -> String {
        switch name {
        case "read_file": return "Read"
        case "read_many_files": return "Read files"
        case "write_file": return "Write"
        case "edit": return "Edit"
        case "list_directory": return "List"
        case "glob": return "Find files"
        case "grep": return "Search"
        case "run_shell_command": return "Run"
        case "web_fetch": return "Fetch"
        case "todo_write": return "Plan"
        case "agent": return "Subagent"
        case "delegate": return "Subagents"
        case "exit_plan_mode": return "Present plan"
        case "use_skill": return "Skill"
        case "propose_skill": return "Propose skill"
        case "screenshot": return "Screenshot"
        case "list_windows": return "Windows"
        case "screen_watch": return "Watch screen"
        case "ui_tree": return "UI tree"
        case "mouse": return "Mouse"
        case "keyboard": return "Keyboard"
        case "focus_app": return "Focus app"
        case "view_image": return "View image"
        case "inspect_process": return "Inspect process"
        case "process_start": return "Start process"
        case "process_read": return "Read output"
        case "process_write": return "Send input"
        case "process_stop": return "Stop process"
        case "process_list": return "Processes"
        default: return name
        }
    }
}

extension PermissionPreset {
    var label: String {
        switch self {
        case .workspaceWrite: "Workspace write"
        case .plan: "Plan only"
        case .fullAccess: "Full access"
        }
    }

    var detail: String {
        switch self {
        case .workspaceWrite:
            "Reads anywhere. Writes and commands inside the project run without asking; outside it, the agent asks."
        case .plan:
            "Research only. Every write and every shell command asks first, and the agent is told to produce a plan instead of changing things."
        case .fullAccess:
            "Writes and runs commands without asking. Only use this for a project you would hand the keys to."
        }
    }

    var icon: String {
        switch self {
        case .workspaceWrite: "shield.lefthalf.filled"
        case .plan: "list.clipboard"
        case .fullAccess: "exclamationmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .workspaceWrite: .accentColor
        case .plan: .purple
        case .fullAccess: .red
        }
    }
}

extension ProviderProfile.Kind {
    var label: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAICompat: "OpenAI-compatible server"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .bedrock: "Amazon Bedrock"
        case .guardian: "Guardian"
        case .anthropic: "Anthropic API"
        case .claudeCode: "Claude Code"
        }
    }

    var icon: String {
        switch self {
        case .ollama, .lmStudio: "desktopcomputer"
        case .openAICompat: "server.rack"
        case .openAI, .openRouter: "cloud"
        case .bedrock: "cloud.bolt"
        case .guardian: "shield.lefthalf.filled"
        case .anthropic: "sparkle"
        case .claudeCode: "terminal"
        }
    }
}

extension TodoItem.Status {
    var icon: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: .accentColor
        case .completed: .green
        }
    }
}

extension FileChange.Kind {
    var label: String {
        switch self {
        case .created: "new"
        case .modified: "changed"
        case .deleted: "deleted"
        }
    }

    var tint: Color {
        switch self {
        case .created: .green
        case .modified: .accentColor
        case .deleted: .red
        }
    }
}

// MARK: - Small shared views

/// A rounded card with the app's standard fill.
struct Card<Content: View>: View {
    var fill: Color = Theme.surface
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Centred "nothing here yet" state with an optional action.
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

extension View {
    /// Copy-to-pasteboard helper used by code blocks, chips, and tool output.
    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension Date {
    /// "14:32" — used for transcript timestamps.
    var clockLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: self)
    }

    /// "2m ago", "yesterday" — used in the sidebar.
    var relativeLabel: String {
        let seconds = Date.now.timeIntervalSince(self)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 172_800 { return "yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: self)
    }
}
