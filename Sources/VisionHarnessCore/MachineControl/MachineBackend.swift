import Foundation
import CoreGraphics
import ApplicationServices
import Darwin

// MARK: - The machine, behind one protocol
//
// Everything the control tools need from macOS: who is running, which window
// is under a point, the Accessibility tree, and the two ways to send input
// (to one process, or through the HID tap as the real mouse/keyboard). The
// live implementation below is the only code that calls those APIs; tests use
// a scripted backend and check which of them a tool used.

/// Long input — typing, a run of key presses — goes out a piece at a time, and stops between pieces once the
/// tool is cancelled (the chat's Stop, ⌘.) or its chat no longer holds the mouse and keyboard (⌃⌥⌘.). Before, a
/// cancelled sleep was swallowed and the rest of the text went out back to back — into whatever app was in front.
public enum MachineInputPacing {
    /// Set by `MachineActions.withControls` while a tool holds the controls: true while it still does (and keeps its
    /// lease alive — a long type outlasts the idle release). Nil outside it (background input to one app).
    @TaskLocal public static var stillHeld: (@Sendable () async -> Bool)?

    /// Whether input may go on: not cancelled, and the seat (if any) still held.
    public static func mayContinue() async -> Bool {
        if Task.isCancelled { return false }
        if let stillHeld, !(await stillHeld()) { return false }
        return true
    }

    /// `post` each item, pausing `pause` nanoseconds between them; stops before the next item once input may not go
    /// on. Returns how many were posted.
    @discardableResult
    public static func paced<T>(_ items: [T], pause: UInt64, _ post: (T) -> Void) async -> Int {
        var posted = 0
        for item in items {
            guard await mayContinue() else { break }
            post(item)
            posted += 1
            do { try await Task.sleep(nanoseconds: pause) } catch { break }
        }
        return posted
    }
}

/// A mouse action through the real pointer.
public enum MouseGesture: Sendable, Equatable {
    case click(CGPoint, button: String, clicks: Int)
    case drag(from: CGPoint, to: CGPoint)
}

public protocol MachineBackend: Sendable {
    /// Accessibility permission is granted to this app (AX calls work).
    var accessibilityTrusted: Bool { get }
    /// This app's own process id (never a control target).
    var ownPID: pid_t { get }

    // Processes and windows
    func app(named name: String) -> ControlTarget?
    func target(pid: pid_t) -> ControlTarget
    func parentPID(_ pid: pid_t) -> pid_t?
    /// The app whose window is under `point` (this app's own click-through overlays skipped).
    func windowOwner(at point: CGPoint) -> ControlTarget?
    func frontmostApp() async -> ControlTarget?
    /// Typing into this process is refused (a terminal, or this harness).
    func isBlockedForTyping(_ pid: pid_t) -> Bool

    // Accessibility
    func windows(app pid: pid_t) -> [UIElementHandle]
    func menuBar(app pid: pid_t) -> UIElementHandle?
    func children(_ element: UIElementHandle) -> [UIElementHandle]
    func parent(_ element: UIElementHandle) -> UIElementHandle?
    func info(_ element: UIElementHandle) -> ElementInfo
    /// The element of `pid`'s UI at a screen point (an app-scoped hit test: overlays of other apps don't count).
    func element(at point: CGPoint, app pid: pid_t) -> UIElementHandle?
    func focusedElement(app pid: pid_t) -> UIElementHandle?
    /// Perform an AX action; nil on success, else why not.
    func perform(_ action: String, on element: UIElementHandle) -> String?
    func setFocused(_ element: UIElementHandle) -> String?
    func setValue(_ value: String, on element: UIElementHandle) -> String?
    /// Insert text at the element's caret (replacing its selection).
    func insertText(_ text: String, into element: UIElementHandle) -> String?
    /// A text element's length and selection (nil when it doesn't say).
    func textState(of element: UIElementHandle) -> TextState?

    // Input
    func pointerLocation() -> CGPoint?
    /// Put the pointer somewhere without an event (to give the person's pointer back).
    func warpPointer(to point: CGPoint)
    func postMouse(_ gesture: MouseGesture) async
    /// Press combos: to one process (`pid`), or through the HID tap (nil).
    func postKeys(_ combos: [KeyboardTool.ResolvedCombo], to pid: pid_t?) async
    /// Type literal text as unicode key events: to one process, or through the HID tap (nil).
    func postText(_ text: String, to pid: pid_t?) async
    /// Bring a running app to the front; nil on success, else why not.
    func activate(app name: String) async -> String?
}

// MARK: - The live backend

public struct LiveMachineBackend: MachineBackend {
    public init() {
        // Bound every AX call: an app that is hung must not wedge the agent's loop.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2.0)
    }

    public var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    // MARK: Processes and windows

    private struct WindowRow {
        var pid: pid_t
        var owner: String
        var layer: Int
        var bounds: CGRect
        var alpha: Double
    }

    private func windowRows(onScreenOnly: Bool) -> [WindowRow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: dict) ?? .zero
            }
            return WindowRow(pid: pid, owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                             layer: entry[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                             alpha: entry[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    public func app(named name: String) -> ControlTarget? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ".app", with: "")
        guard !wanted.isEmpty else { return nil }
        if let pid = pid_t(wanted), pid > 0 { return target(pid: pid) }
        let owners = windowRows(onScreenOnly: false).filter { $0.layer == 0 && $0.pid != ownPID }
        var seen: [pid_t: String] = [:]
        for row in owners where seen[row.pid] == nil { seen[row.pid] = row.owner }
        let candidates = seen.map { (pid: $0.key, name: $0.value) }.sorted { $0.pid < $1.pid }
        if let hit = candidates.first(where: { $0.name.lowercased() == wanted })
            ?? candidates.first(where: { $0.name.lowercased().hasPrefix(wanted) })
            ?? candidates.first(where: { $0.name.lowercased().contains(wanted) }) {
            return target(pid: hit.pid)
        }
        // A process without windows (or whose windows are on another Space): look at every process.
        for pid in Self.allPIDs() where pid != ownPID {
            let candidate = target(pid: pid)
            if candidate.name.lowercased() == wanted { return candidate }
        }
        return nil
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    public func target(pid: pid_t) -> ControlTarget {
        let path = TerminalGuard.executablePath(pid: pid)
        var name = ""
        if let path {
            let parts = path.split(separator: "/")
            if let app = parts.last(where: { $0.lowercased().hasSuffix(".app") }) {
                name = String(app.dropLast(4))
            } else {
                name = String(parts.last ?? "")
            }
        }
        if name.isEmpty {
            var buffer = [CChar](repeating: 0, count: 256)
            if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { name = String(cString: buffer) }
        }
        return ControlTarget(pid: pid, name: name.isEmpty ? "process \(pid)" : name,
                             bundleIdentifier: path.flatMap(TerminalGuard.bundleIdentifier(executablePath:)))
    }

    public func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 0 ? parent : nil
    }

    public func windowOwner(at point: CGPoint) -> ControlTarget? {
        for row in windowRows(onScreenOnly: true) {
            // This app's own overlays (the machine-in-use glow) are click-through: skip them.
            if row.pid == ownPID && row.layer != 0 { continue }
            if row.alpha <= 0.01 || row.layer >= 1000 { continue }
            if row.bounds.contains(point) { return target(pid: row.pid) }
        }
        return nil
    }

    public func frontmostApp() async -> ControlTarget? {
        if accessibilityTrusted {
            let system = AXUIElementCreateSystemWide()
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                var pid: pid_t = 0
                // swiftlint:disable:next force_cast
                if AXUIElementGetPid(value as! AXUIElement, &pid) == .success, pid > 0 { return target(pid: pid) }
            }
        }
        guard let front = await KeyboardTool.frontmostProcess() else { return nil }
        var found = target(pid: front.pid)
        if found.name.isEmpty { found.name = front.name }
        return found
    }

    public func isBlockedForTyping(_ pid: pid_t) -> Bool { TerminalGuard.isBlocked(pid: pid) }

    // MARK: Accessibility

    private func ax(_ handle: UIElementHandle) -> AXUIElement {
        // swiftlint:disable:next force_cast
        handle.ref as! AXUIElement
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func elements(_ value: CFTypeRef?) -> [UIElementHandle] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? UIElementHandle(item) : nil
        }
    }

    public func windows(app pid: pid_t) -> [UIElementHandle] {
        elements(attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute))
    }

    public func menuBar(app pid: pid_t) -> UIElementHandle? {
        guard let bar = attribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return UIElementHandle(bar)
    }

    public func children(_ element: UIElementHandle) -> [UIElementHandle] {
        elements(attribute(ax(element), kAXChildrenAttribute))
    }

    public func parent(_ element: UIElementHandle) -> UIElementHandle? {
        guard let value = attribute(ax(element), kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return UIElementHandle(value)
    }

    private func string(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    public func info(_ handle: UIElementHandle) -> ElementInfo {
        let element = ax(handle)
        var actionNames: CFArray?
        let actions = AXUIElementCopyActionNames(element, &actionNames) == .success
            ? (actionNames as? [String] ?? []) : []
        var frame: CGRect?
        if let positionValue = attribute(element, kAXPositionAttribute), let sizeValue = attribute(element, kAXSizeAttribute),
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var point = CGPoint.zero, size = CGSize.zero
            // swiftlint:disable force_cast
            if AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
               AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            }
            // swiftlint:enable force_cast
        }
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        let role = string(attribute(element, kAXRoleAttribute)) ?? "AXUnknown"
        return ElementInfo(
            role: role,
            subrole: string(attribute(element, kAXSubroleAttribute)),
            title: string(attribute(element, kAXTitleAttribute)),
            label: string(attribute(element, kAXDescriptionAttribute)),
            value: string(attribute(element, kAXValueAttribute)).map { ElementInfo.clip($0, 400) },
            identifier: string(attribute(element, kAXIdentifierAttribute)),
            help: string(attribute(element, kAXHelpAttribute)),
            enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
            focused: (attribute(element, kAXFocusedAttribute) as? Bool) ?? false,
            frame: frame,
            actions: actions,
            valueSettable: settable(element, kAXValueAttribute),
            selectedTextSettable: settable(element, kAXSelectedTextAttribute),
            pid: pid)
    }

    public func element(at point: CGPoint, app pid: pid_t) -> UIElementHandle? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        return UIElementHandle(hit)
    }

    public func focusedElement(app pid: pid_t) -> UIElementHandle? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return UIElementHandle(value)
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success: "ok"
        case .apiDisabled: "Accessibility permission is not granted to \(AppIdentity.name)"
        case .actionUnsupported: "the element doesn't support that action"
        case .attributeUnsupported: "the element doesn't have that attribute"
        case .cannotComplete: "the app didn't answer (busy, or it went away)"
        case .invalidUIElement: "the element is gone (the window changed)"
        case .notImplemented: "the app doesn't implement that"
        case .illegalArgument: "the app refused the value"
        default: "Accessibility error \(error.rawValue)"
        }
    }

    public func perform(_ action: String, on element: UIElementHandle) -> String? {
        let result = AXUIElementPerformAction(ax(element), action as CFString)
        return result == .success ? nil : describe(result)
    }

    public func setFocused(_ element: UIElementHandle) -> String? {
        let result = AXUIElementSetAttributeValue(ax(element), kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return result == .success ? nil : describe(result)
    }

    public func setValue(_ value: String, on element: UIElementHandle) -> String? {
        let result = AXUIElementSetAttributeValue(ax(element), kAXValueAttribute as CFString, value as CFString)
        return result == .success ? nil : describe(result)
    }

    public func insertText(_ text: String, into element: UIElementHandle) -> String? {
        let result = AXUIElementSetAttributeValue(ax(element), kAXSelectedTextAttribute as CFString, text as CFString)
        return result == .success ? nil : describe(result)
    }

    public func textState(of handle: UIElementHandle) -> TextState? {
        let element = ax(handle)
        var length: Int?
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber {
            length = count.intValue
        } else if let text = attribute(element, kAXValueAttribute) as? String {
            length = (text as NSString).length
        }
        guard let length else { return nil }
        var selection = 0
        if let range = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var cfRange = CFRange(location: 0, length: 0)
            // swiftlint:disable:next force_cast
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) { selection = cfRange.length }
        }
        return TextState(length: length, selectionLength: selection)
    }

    // MARK: Input

    public func pointerLocation() -> CGPoint? { CGEvent(source: nil)?.location }

    public func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // A warp briefly freezes the pointer; hand it straight back to the person.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func postMouse(_ gesture: MouseGesture) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        func post(_ type: CGEventType, _ at: CGPoint, _ button: CGMouseButton, clickState: Int64 = 1) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            event.post(tap: .cghidEventTap)
        }
        switch gesture {
        case .click(let point, let button, let clicks):
            let cgButton: CGMouseButton = button == "right" ? .right : button == "middle" ? .center : .left
            let (down, up): (CGEventType, CGEventType) = button == "right"
                ? (.rightMouseDown, .rightMouseUp)
                : button == "middle" ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp)
            post(.mouseMoved, point, cgButton)
            try? await Task.sleep(nanoseconds: 40_000_000)
            for click in 0..<max(1, clicks) {
                post(down, point, cgButton, clickState: Int64(click + 1))
                post(up, point, cgButton, clickState: Int64(click + 1))
                if click < clicks - 1 { try? await Task.sleep(nanoseconds: 60_000_000) }
            }
        case .drag(let from, let to):
            post(.mouseMoved, from, .left)
            post(.leftMouseDown, from, .left)
            let steps = 6
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), .left)
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            post(.leftMouseUp, to, .left)
        }
    }

    public func postKeys(_ combos: [KeyboardTool.ResolvedCombo], to pid: pid_t?) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // A combo goes down and up whole; a Stop takes effect before the next one.
        await MachineInputPacing.paced(combos, pause: 20_000_000) { combo in
            var flags = CGEventFlags(rawValue: 0)
            if combo.cmd { flags.insert(.maskCommand) }
            if combo.ctrl { flags.insert(.maskControl) }
            if combo.alt { flags.insert(.maskAlternate) }
            if combo.shift { flags.insert(.maskShift) }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.code, keyDown: down) else { continue }
                event.flags = flags
                if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
            }
        }
    }

    public func postText(_ text: String, to pid: pid_t?) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // 20 characters at a time; a Stop (or the controls taken back) ends the typing before the next piece.
        await MachineInputPacing.paced(text.unicodeChunks(size: 20), pause: 8_000_000) { chunk in
            var utf16 = Array(chunk.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                if let pid { down.postToPid(pid) } else { down.post(tap: .cghidEventTap) }
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                var empty = [UInt16]()
                up.keyboardSetUnicodeString(stringLength: 0, unicodeString: &empty)
                if let pid { up.postToPid(pid) } else { up.post(tap: .cghidEventTap) }
            }
        }
    }

    public func activate(app name: String) async -> String? {
        let quoted = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runBinary("/usr/bin/osascript", [
            "-e", "tell application \"System Events\" to set frontmost of process \"\(quoted)\" to true",
        ], timeout: 10)
        guard result.status == 0 else {
            return "'\(name)' is not running or cannot be focused: \(String(decoding: result.err, as: UTF8.self).prefix(200))"
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return nil
    }
}

extension String {
    /// Chunks for unicode keyboard injection (one event carries ~20 UTF-16 units reliably).
    func unicodeChunks(size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var count = 0
        for character in self {
            current.append(character)
            count += String(character).utf16.count
            if count >= size { chunks.append(current); current = ""; count = 0 }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
