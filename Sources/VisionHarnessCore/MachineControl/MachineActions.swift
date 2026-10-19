import Foundation
import CoreGraphics

// MARK: - Carrying out a control action
//
// The mouse, keyboard, focus_app and ui_action tools all come through here:
// check the target (never this app; never typing into a terminal; inside the
// chat's scope when it is limited), pick the route with `ControlPlanner`, and
// do it — in the background when the route allows, otherwise holding the
// machine's controls from the arbiter, after the person has left the mouse
// alone, giving the pointer back afterwards.

public struct MachineActions: Sendable {
    public let backend: any MachineBackend
    public let seat: MachineSeat
    /// Asks the person (the chat's permission prompt).
    public let ask: @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool

    public init(backend: any MachineBackend, seat: MachineSeat,
                ask: @escaping @Sendable (_ id: String, _ name: String, _ detail: String) async -> Bool) {
        self.backend = backend
        self.seat = seat
        self.ask = ask
    }

    /// Said whenever the real mouse was not used.
    public static let mouseFreeNote = "your mouse and keyboard weren't used"

    // MARK: Admission

    /// Why acting on `target` is refused, or nil to go ahead. Asks the person when a limited chat reaches for an
    /// app outside its scope.
    public func admit(_ target: ControlTarget, typing: Bool, tool: String) async -> String? {
        if target.pid == backend.ownPID {
            return "Error: not acting on \(AppIdentity.name) itself — its windows hold the user's approvals and composer. Ask the user instead."
        }
        if typing, backend.isBlockedForTyping(target.pid) {
            return TerminalGuard.refusal(appName: target.name)
        }
        switch seat.decide(target, parentOf: { backend.parentPID($0) }) {
        case .allowed:
            return nil
        case .needsApproval(let app):
            let approved = await ask("scope-\(target.approvalKey)", tool, MachineSeat.approvalPrompt(chat: seat.title, app: app))
            if approved {
                seat.approve(target)
                return nil
            }
            return MachineSeat.declinedMessage(app: app)
        }
    }

    // MARK: Holding the controls

    /// Run `body` holding the real mouse/keyboard: wait in line for them, then (when `touchesPerson`) for the
    /// person to leave the mouse and keyboard alone. `.failure` carries the tool's error text.
    public func withControls<T: Sendable>(app: String, touchesPerson: Bool = true,
                                          _ body: @Sendable () async -> T) async -> Result<T, ControlRefusal> {
        let arbiter = seat.arbiter
        let me = seat.holder
        let before = await arbiter.snapshot()
        if let holder = before.holder, holder.id != me.id {
            seat.setActivity(.waitingForControls(holder: holder.label))
        }
        let timeout = seat.options.waitTimeout
        let started = Date()
        switch await arbiter.acquire(me, timeout: timeout) {
        case .granted:
            break
        case .timedOut(let holder):
            seat.setActivity(.idle)
            return .failure(.timedOut(holder: holder, seconds: Self.wholeSeconds(since: started)))
        case .stopped:
            seat.setActivity(.idle)
            return .failure(.stopped)
        }
        if touchesPerson, await arbiter.personIsActive() {
            seat.setActivity(.waitingForPerson)
            let clear = await arbiter.waitForPerson(me, timeout: max(0.1, timeout - Date().timeIntervalSince(started)))
            if !clear {
                seat.setActivity(.idle)
                return .failure(await arbiter.holds(me) ? .personBusy(seconds: Self.wholeSeconds(since: started)) : .stopped)
            }
        }
        seat.setActivity(.controlling(app: app))
        // Long input checks between pieces that this seat still has the controls (⌃⌥⌘. or a Stop takes them), and
        // keeps the lease alive while it types.
        let value = await MachineInputPacing.$stillHeld.withValue({
            guard await arbiter.holds(me) else { return false }
            await arbiter.notePosted()
            await arbiter.touch(me)
            return true
        }) {
            await body()
        }
        await arbiter.notePosted()
        await arbiter.touch(me)
        seat.setActivity(.idle)
        return .success(value)
    }

    static func wholeSeconds(since start: Date) -> Int { max(1, Int(Date().timeIntervalSince(start).rounded(.up))) }

    public enum ControlRefusal: Error, Equatable, Sendable {
        case timedOut(holder: String?, seconds: Int)
        case stopped
        case personBusy(seconds: Int)

        public var message: String {
            switch self {
            case .timedOut(let holder, let seconds):
                let who = holder.map { "the chat “\($0)”" } ?? "another copy of \(AppIdentity.name)"
                return "Error: waited \(seconds)s for the mouse and keyboard, but \(who) is still using them. Act without them instead (ui_action presses buttons, fills fields and opens menus in the background; keyboard sends keys to an app in the background), or try again shortly."
            case .stopped:
                return "Error: stopped — machine control was stopped (the chat's Stop or ⌃⌥⌘.). Don't retry unless the user asks."
            case .personBusy(let seconds):
                return "Error: the user kept using the mouse/keyboard for \(seconds)s, so nothing was clicked or typed. Act in the background (ui_action, or keyboard without foreground) or try again later."
            }
        }
    }

    // MARK: Clicking

    public func click(at point: CGPoint, button: String, clicks: Int, dragTo: CGPoint?, forceReal: Bool) async -> ToolResult {
        let owner = backend.windowOwner(at: point)
        if let owner {
            if let refusal = await admit(owner, typing: false, tool: "mouse") { return .init(output: refusal) }
        } else if seat.isRestricted {
            return .init(output: "Error: can't tell which app is under (\(Int(point.x)),\(Int(point.y))), and this chat may only control its own apps. Use list_windows for coordinates inside an app's window.")
        }
        if let dragTo, let endOwner = backend.windowOwner(at: dragTo), endOwner.pid != owner?.pid {
            if let refusal = await admit(endOwner, typing: false, tool: "mouse") { return .init(output: refusal) }
        }

        var chain: [UIElementHandle] = []
        if backend.accessibilityTrusted, let owner, let hit = backend.element(at: point, app: owner.pid) {
            chain.append(hit)
            var current = hit
            for _ in 0..<2 {
                guard let up = backend.parent(current) else { break }
                chain.append(up)
                current = up
            }
        }
        let infos = chain.map { backend.info($0) }
        let plan = ControlPlanner.planClick(button: button, clicks: clicks, isDrag: dragTo != nil, forceReal: forceReal,
                                            preferBackground: seat.options.preferBackground,
                                            accessibilityTrusted: backend.accessibilityTrusted, chain: infos)
        let appName = owner?.name ?? "the screen"
        var fallbackNote = ""
        switch plan {
        case .accessibility(let verb, let index):
            let element = chain[index], info = infos[index]
            seat.setActivity(.background(app: appName))
            defer { seat.setActivity(.idle) }
            let failure: String? = verb == .focus ? backend.setFocused(element) : backend.perform(verb.axAction ?? "AXPress", on: element)
            if failure == nil {
                return .init(output: "\(Self.pastTense(verb)) \(ControlPlanner.describe(info)) in \(appName) through Accessibility at (\(Int(point.x)),\(Int(point.y))) — \(Self.mouseFreeNote). Screenshot or ui_tree to check the result.")
            }
            fallbackNote = " (Accessibility couldn't: \(failure ?? "unknown") — used the real mouse)"
        case .realMouse(let why):
            fallbackNote = " (\(why))"
        }

        let gesture: MouseGesture = dragTo.map { .drag(from: point, to: $0) } ?? .click(point, button: button, clicks: clicks)
        let outcome = await withControls(app: appName) { () -> Bool in
            let saved = backend.pointerLocation()
            await backend.postMouse(gesture)
            if let saved, hypot(saved.x - point.x, saved.y - point.y) > 1 {
                try? await Task.sleep(nanoseconds: 30_000_000)
                backend.warpPointer(to: saved)
                return true
            }
            return false
        }
        switch outcome {
        case .failure(let refusal):
            return .init(output: refusal.message)
        case .success(let restored):
            let what: String
            if let dragTo {
                what = "Dragged (\(Int(point.x)),\(Int(point.y))) → (\(Int(dragTo.x)),\(Int(dragTo.y)))"
            } else {
                what = "Clicked \(button)\(clicks > 1 ? " ×\(clicks)" : "") at (\(Int(point.x)),\(Int(point.y)))"
            }
            return .init(output: "\(what) in \(appName) with the real mouse\(fallbackNote)\(restored ? "; the user's pointer was put back" : ""). Screenshot to verify.")
        }
    }

    static func pastTense(_ verb: ActionVerb) -> String {
        switch verb {
        case .press: "Pressed"
        case .confirm: "Confirmed"
        case .focus: "Focused"
        case .raise: "Raised"
        case .menu: "Opened the context menu of"
        case .setValue: "Set"
        case .increment: "Incremented"
        case .decrement: "Decremented"
        case .open: "Opened"
        case .cancel: "Cancelled"
        case .pick: "Picked"
        case .typeText: "Typed into"
        }
    }

    // MARK: Typing

    /// Type `text` and/or press `combos` in `appName` (nil = the app in front).
    public func type(text: String?, combos: [KeyboardTool.ResolvedCombo], appName: String?, foreground: Bool) async -> ToolResult {
        let text = text?.isEmpty == true ? nil : text
        guard text != nil || !combos.isEmpty else { return .init(output: "Error: give text and/or keys.") }
        let front = await backend.frontmostApp()
        let target: ControlTarget
        if let appName, !appName.isEmpty {
            guard let found = backend.app(named: appName) else {
                return .init(output: "Error: '\(appName)' is not running. list_windows shows what is open; process_start or `open -a` launches it.")
            }
            target = found
        } else {
            guard let front else { return .init(output: TerminalGuard.unknownFrontmostRefusal()) }
            target = front
        }
        if target.pid == backend.ownPID || backend.isBlockedForTyping(target.pid) {
            return .init(output: TerminalGuard.refusal(appName: appName ?? target.name))
        }
        if let refusal = await admit(target, typing: true, tool: "keyboard") { return .init(output: refusal) }

        let trusted = backend.accessibilityTrusted
        let focusedHandle = (text != nil && trusted) ? backend.focusedElement(app: target.pid) : nil
        let focused = focusedHandle.map { backend.info($0) }
        let textPlan = text.map { _ in
            ControlPlanner.planText(foreground: foreground, preferBackground: seat.options.preferBackground,
                                    accessibilityTrusted: trusted, focused: focused)
        }
        let keysPlan = combos.isEmpty ? nil
            : ControlPlanner.planKeys(foreground: foreground, preferBackground: seat.options.preferBackground)
        let targetIsFront = front?.pid == target.pid
        let realKeyboard: Bool = {
            if case .realKeyboard = textPlan { return true }
            if case .realKeyboard = keysPlan { return true }
            return false
        }()

        if realKeyboard {
            let outcome = await withControls(app: target.name) { () -> String? in
                if !targetIsFront {
                    if let failure = await backend.activate(app: target.name) { return "Error: \(failure)" }
                }
                // The keys go to whatever is in front now: check it is still the app meant.
                guard let now = await backend.frontmostApp() else { return TerminalGuard.unknownFrontmostRefusal() }
                if now.pid != target.pid {
                    return "Error: \(target.name) didn't come to the front (\(now.name) is in front), so nothing was typed."
                }
                if now.pid == backend.ownPID || backend.isBlockedForTyping(now.pid) {
                    return TerminalGuard.refusal(appName: now.name)
                }
                if let text { await backend.postText(text, to: nil) }
                if !combos.isEmpty { await backend.postKeys(combos, to: nil) }
                return nil
            }
            switch outcome {
            case .failure(let refusal): return .init(output: refusal.message)
            case .success(let error?): return .init(output: error)
            case .success(nil):
                let why: String = {
                    if case .realKeyboard(let why) = textPlan { return why }
                    if case .realKeyboard(let why) = keysPlan { return why }
                    return ""
                }()
                return .init(output: "Typed \(text?.count ?? 0) characters and \(combos.count) key combo(s) into \(target.name) with the real keyboard, the app in front (\(why)). Screenshot to verify.")
            }
        }

        // In the background: Accessibility first for text, then events posted to the process only.
        let deliver: @Sendable () async -> [String] = {
            var notes: [String] = []
            if let text {
                if textPlan == .insertAtCaret, let focusedHandle {
                    let before = backend.textState(of: focusedHandle)
                    let failure = backend.insertText(text, into: focusedHandle)
                    let after = backend.textState(of: focusedHandle)
                    let unchanged = failure == nil && Self.insertionDidNothing(before: before, after: after, inserted: text)
                    if failure == nil && !unchanged {
                        notes.append("typed \(text.count) characters at the caret of \(ControlPlanner.describe(focused ?? ElementInfo(role: "AXTextField"))) in \(target.name) through Accessibility")
                    } else {
                        await backend.postText(text, to: target.pid)
                        notes.append("typed \(text.count) characters into \(target.name) as key events sent to that app only")
                    }
                } else {
                    await backend.postText(text, to: target.pid)
                    notes.append("typed \(text.count) characters into \(target.name) as key events sent to that app only")
                }
            }
            if !combos.isEmpty {
                await backend.postKeys(combos, to: target.pid)
                notes.append("sent \(combos.count) key combo(s) to \(target.name) only")
            }
            return notes
        }
        let notes: [String]
        if ControlPlanner.keyboardNeedsControls(text: textPlan, keys: keysPlan, targetIsFront: targetIsFront) {
            // The app is the one the person is in: wait for the controls and for the person.
            switch await withControls(app: target.name, deliver) {
            case .failure(let refusal): return .init(output: refusal.message)
            case .success(let done): notes = done
            }
        } else {
            seat.setActivity(.background(app: target.name))
            notes = await deliver()
            seat.setActivity(.idle)
        }
        let where_ = targetIsFront ? "" : " It stayed behind the user's windows."
        let hint = keysPlan == .postToProcess || textPlan == .postToProcess
            ? " If nothing happened, the app may only take keys while in front: call keyboard again with foreground: true (that waits its turn for the real keyboard)."
            : ""
        return .init(output: notes.joined(separator: "; ").capitalizedFirst + " — " + Self.mouseFreeNote + "." + where_ + hint + " Screenshot or ui_tree to verify.")
    }

    /// An Accessibility insert that reported success but changed nothing (some apps accept the call and ignore
    /// it): the length didn't move and there was no selection it could have replaced.
    static func insertionDidNothing(before: TextState?, after: TextState?, inserted: String) -> Bool {
        guard let before, let after, !inserted.isEmpty else { return false }
        return before.selectionLength == 0 && after.length == before.length
    }

    // MARK: Bringing an app forward

    public func focus(appName: String) async -> ToolResult {
        guard let target = backend.app(named: appName) else {
            return .init(output: "Error: '\(appName)' is not running or not focusable. process_list/inspect_process to check; process_start or `open -a \"\(appName)\"` to launch it.")
        }
        if let refusal = await admit(target, typing: false, tool: "focus_app") { return .init(output: refusal) }
        switch await withControls(app: target.name, { await backend.activate(app: target.name) }) {
        case .failure(let refusal): return .init(output: refusal.message)
        case .success(let error?): return .init(output: "Error: \(error)")
        case .success(nil):
            return .init(output: "Focused \(target.name) (it is in front of the user's windows now). To act on an app without bringing it forward, use ui_action or keyboard without foreground.")
        }
    }
}

/// A text element's length and selection, to tell an insert that worked from one that was ignored.
public struct TextState: Sendable, Equatable {
    public var length: Int
    public var selectionLength: Int
    public init(length: Int, selectionLength: Int) {
        self.length = length
        self.selectionLength = selectionLength
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
