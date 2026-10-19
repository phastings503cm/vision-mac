import Foundation
import VisionHarnessCore

// MARK: - Chats at the machine
//
// Each chat gets a `MachineSeat` (its place in line for the real mouse and
// keyboard, its preferences, its scope). The transport follows the control
// arbiter and the running machine tools, and turns both into what the person
// sees: the glow and its pill ("“Fix the build” has the mouse · 1 waiting"),
// and a status line in a chat that is waiting its turn.

extension AppTransport {
    /// The chat's seat, made on first use and refreshed with the chat's title and the current settings.
    func machineSeat(for sessionID: String, vm: SessionVM) -> MachineSeat {
        let seat: MachineSeat
        if let existing = machineSeats[sessionID] {
            seat = existing
        } else {
            seat = MachineSeat(chatID: sessionID, title: vm.title)
            let box = WeakTransportBox(self)
            seat.onActivity = { activity in
                Task { @MainActor in box.transport?.seatActivityChanged(sessionID, activity) }
            }
            machineSeats[sessionID] = seat
        }
        seat.title = vm.title
        seat.options = config.machineControl
        return seat
    }

    /// Settings ▸ Computer changed: every chat's seat follows at once (not only on its next engine build).
    public func machineControlSettingsChanged() {
        for seat in machineSeats.values { seat.options = config.machineControl }
    }

    /// `/control` in a chat: limit it to its own apps (`only`, optionally naming apps it may also control), let
    /// it control any app (`any`), or go back to the setting (`default`). Returns what to tell the user.
    public func setControlScope(_ vm: SessionVM, argument: String?) -> String {
        let seat = machineSeat(for: vm.id, vm: vm)
        let words = (argument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = words.lowercased()
        if lowered.isEmpty {
            return Self.controlScopeSummary(seat)
        }
        if lowered == "any" || lowered == "all" || lowered == "off" {
            seat.setRestricted(false)
            return "This chat may control any app (after you allow computer control once). " + Self.controlScopeHint
        }
        if lowered == "default" || lowered == "reset" {
            seat.setRestricted(nil)
            return Self.controlScopeSummary(seat)
        }
        if lowered.hasPrefix("only") {
            seat.setRestricted(true)
            let names = words.dropFirst(4).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty { seat.approve(names: names) }
            return Self.controlScopeSummary(seat)
        }
        return "Use /control only [App, App…], /control any, or /control default. " + Self.controlScopeHint
    }

    static let controlScopeHint = "⌃⌥⌘. stops all AI control from any app."

    static func controlScopeSummary(_ seat: MachineSeat) -> String {
        if seat.isRestricted {
            let approved = seat.approvedNames
            let spawned = seat.spawnedPIDs.count
            var line = "This chat may control only the apps it starts"
            if !approved.isEmpty { line += " and " + approved.joined(separator: ", ") }
            line += ". Anything else asks you first."
            if spawned > 0 { line += " (\(spawned) process\(spawned == 1 ? "" : "es") started here so far.)" }
            return line + " " + controlScopeHint
        }
        return "This chat may control any app (after you allow computer control once). /control only limits it to the apps it starts. " + controlScopeHint
    }

    // MARK: Following the arbiter

    func observeControlArbiter() {
        guard controlObserver == nil else { return }
        let arbiter = ControlArbiter.shared
        // The shared arbiter outlives any one transport (tests make many): it holds this one weakly.
        let box = WeakTransportBox(self)
        Task { @MainActor in
            let token = await arbiter.observe { snapshot in
                Task { @MainActor in box.transport?.controlChanged(snapshot) }
            }
            if let transport = box.transport {
                transport.controlObserver = token
            } else {
                await arbiter.removeObserver(token)
            }
        }
    }

    func controlChanged(_ snapshot: ControlSnapshot) {
        controlSnapshot = snapshot
        // A chat in line (or holding the controls while the person is busy) says so.
        var lines: [String: String] = [:]
        for chatID in Set(snapshot.waiting.map(\.chatID) + [snapshot.holder?.chatID].compactMap { $0 }) {
            if let line = GlowStatus.waitingLine(chatID: chatID, control: snapshot) { lines[chatID] = line }
        }
        for vm in sessions {
            let previous = machineStatusLines[vm.id]
            let next = lines[vm.id]
            guard previous != next else { continue }
            if let next {
                if vm.running { vm.activity = next }
            } else if let previous, vm.activity == previous {
                vm.activity = nil
            }
        }
        machineStatusLines = lines
        refreshGlow()
    }

    // MARK: Machine tools starting and ending

    func machineToolStarted(_ name: String, in vm: SessionVM) {
        machineSeats[vm.id]?.title = vm.title
        let observing = ComputerAccess.forTool(name) == .observe
        machineWork[vm.id] = MachineWork(chatID: vm.id, chatTitle: vm.title, app: nil, observing: observing)
        refreshGlow()
    }

    /// The seat says which app it is acting on (and whether with the real mouse): the pill names it.
    func seatActivityChanged(_ sessionID: String, _ activity: SeatActivity) {
        guard var work = machineWork[sessionID] else { return }
        switch activity {
        case .controlling(let app), .background(let app):
            work.app = app
            work.observing = false
        default:
            return
        }
        machineWork[sessionID] = work
        refreshGlow()
    }

    func machineToolFinished(in vm: SessionVM) {
        if vm.runningTool.map({ Self.machineTools.contains($0.name) }) != true {
            machineWork[vm.id] = nil
        }
        refreshGlow()
    }

    /// The chat's turn ended: its own seat leaves the line and gives the controls back. (Its background
    /// subagents keep their own places; their leases lapse when they stop acting.)
    func machineTurnEnded(_ sessionID: String) {
        machineWork[sessionID] = nil
        if let seat = machineSeats[sessionID] {
            let holder = seat.holder
            Task { await ControlArbiter.shared.release(holder) }
        }
        refreshGlow()
    }

    func refreshGlow() {
        let work = Array(machineWork.values).sorted { $0.chatTitle < $1.chatTitle }
        let active = GlowStatus.isActive(control: controlSnapshot, work: work)
        MachineGlowController.shared.setText(GlowStatus.pill(control: controlSnapshot, work: work))
        machineInUse = active
    }

    // MARK: The global stop (⌃⌥⌘.)

    /// Stop every chat that is using or waiting for the machine, give the controls back, and make each of them
    /// ask again before it controls the machine. Returns how many chats were stopped.
    @discardableResult
    public func stopMachineControl() -> Int {
        let snapshot = controlSnapshot
        var chats = Set(machineWork.keys)
        chats.formUnion(snapshot.waiting.map(\.chatID))
        if let holder = snapshot.holder { chats.insert(holder.chatID) }
        Task { await ControlArbiter.shared.stopAll() }
        for id in chats {
            stopSession(id)
            computerGrants[id]?.revokeAll()
        }
        machineWork.removeAll()
        refreshGlow()
        note(chats.isEmpty
             ? "Nothing was controlling the Mac. (⌃⌥⌘. stops all AI control from any app.)"
             : "Stopped AI control of the Mac in \(chats.count) chat\(chats.count == 1 ? "" : "s"). Each asks again before it controls anything.")
        return chats.count
    }
}

/// A weak reference to a transport that closures on other actors may carry.
final class WeakTransportBox: @unchecked Sendable {
    weak var transport: AppTransport?
    init(_ transport: AppTransport) { self.transport = transport }
}
