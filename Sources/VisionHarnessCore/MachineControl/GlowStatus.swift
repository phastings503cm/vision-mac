import Foundation

// MARK: - What the machine-in-use glow says
//
// The pill at the bottom of the glow names who is at the controls, so the
// person can tell at a glance whether their mouse is taken, and by which
// chat, or whether the AI is only working in the background.

/// One chat working on the machine right now (a machine tool is running in it).
public struct MachineWork: Sendable, Equatable {
    public var chatID: String
    public var chatTitle: String
    /// The app it is acting on, when known.
    public var app: String?
    /// Only looking (screenshots, windows, trees), not acting.
    public var observing: Bool

    public init(chatID: String, chatTitle: String, app: String? = nil, observing: Bool = false) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.app = app
        self.observing = observing
    }
}

public enum GlowStatus {
    /// The global stop shortcut, as the pill and the prompts write it.
    public static let stopShortcut = "⌃⌥⌘."

    /// The pill's text. `control` is the arbiter; `work` the chats with a machine tool running.
    public static func pill(control: ControlSnapshot, work: [MachineWork]) -> String {
        var parts: [String] = []
        if let holder = control.holder {
            let name = quoted(holder.label)
            parts.append(control.waitingForPerson
                         ? "\(name) is waiting for you to finish with the mouse"
                         : "\(name) has the mouse and keyboard")
            let waiting = control.waiting.count
            if waiting > 0 { parts.append("\(waiting) waiting") }
        } else if let other = control.otherProcessHolder {
            parts.append("\(quoted(other)) (another \(AppIdentity.name) window) has the mouse")
        } else {
            let acting = work.filter { !$0.observing }
            let chats = Set(work.map(\.chatID))
            if chats.count > 1 {
                parts.append(acting.isEmpty ? "\(chats.count) chats are looking at the screen"
                                            : "\(chats.count) chats are working — your mouse is free")
            } else if let first = acting.first {
                parts.append("\(quoted(first.chatTitle)) is working\(first.app.map { " in \($0)" } ?? "") — your mouse is free")
            } else if let first = work.first {
                parts.append("\(quoted(first.chatTitle)) is looking at the screen")
            } else {
                parts.append("machine in use")
            }
        }
        return "Vision AI · " + parts.joined(separator: " · ") + " · \(stopShortcut) stops"
    }

    /// Whether the glow is on: something is using the machine or waiting for it.
    public static func isActive(control: ControlSnapshot, work: [MachineWork]) -> Bool {
        control.holder != nil || !control.waiting.isEmpty || !work.isEmpty
    }

    /// The status line of a chat that waits for the controls (nil when it isn't waiting).
    public static func waitingLine(chatID: String, control: ControlSnapshot) -> String? {
        guard control.waiting.contains(where: { $0.chatID == chatID }) else {
            if control.holder?.chatID == chatID, control.waitingForPerson {
                return SeatActivity.waitingForPerson.statusLine
            }
            return nil
        }
        if let holder = control.holder, holder.chatID != chatID {
            return SeatActivity.waitingForControls(holder: holder.label).statusLine
        }
        if let holder = control.holder, holder.chatID == chatID {
            return "Waiting for the mouse — another task in this chat is using it."
        }
        return SeatActivity.waitingForControls(holder: control.otherProcessHolder).statusLine
    }

    static func quoted(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = clean.count > 40 ? String(clean.prefix(39)) + "…" : clean
        return "“" + (short.isEmpty ? "A chat" : short) + "”"
    }
}
