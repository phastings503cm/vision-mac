import Foundation
import CoreGraphics
@testable import VisionHarnessCore

/// One element of a made-up app UI.
final class FakeNode {
    var info: ElementInfo
    var children: [FakeNode] = []
    weak var parent: FakeNode?
    /// What performing an action / setting an attribute on it returns (nil = success).
    var failure: String?
    /// Accepts an insert but changes nothing (some apps do that).
    var ignoresInsert = false

    init(_ role: String, _ title: String? = nil, actions: [String] = [], frame: CGRect? = nil, pid: pid_t,
         value: String? = nil, valueSettable: Bool = false, selectedTextSettable: Bool = false,
         subrole: String? = nil, label: String? = nil, enabled: Bool = true) {
        info = ElementInfo(role: role, subrole: subrole, title: title, label: label, value: value, enabled: enabled,
                           frame: frame, actions: actions, valueSettable: valueSettable,
                           selectedTextSettable: selectedTextSettable, pid: pid)
    }

    @discardableResult
    func add(_ child: FakeNode) -> FakeNode {
        child.parent = self
        children.append(child)
        return child
    }
}

/// A scripted Mac: apps with windows and menus, a frontmost app, a pointer — and a log of what was done.
final class FakeMachineBackend: MachineBackend, @unchecked Sendable {
    struct App {
        var target: ControlTarget
        var windows: [FakeNode] = []
        var menuBar: FakeNode?
        var focused: FakeNode?
        var parent: pid_t?
        var frame: CGRect = .zero
    }

    enum Event: Equatable {
        case axAction(String, String?)          // action, element title
        case focus(String?)
        case setValue(String, String?)
        case insert(String, String?)
        case realMouse(MouseGesture)
        case warp(CGPoint)
        case keys(Int, pid_t?)                  // combo count, pid (nil = HID)
        case text(String, pid_t?)
        case activate(String)
    }

    private let lock = NSLock()
    var apps: [pid_t: App] = [:]
    var front: pid_t?
    var trusted = true
    var own: pid_t = 99
    var pointer = CGPoint(x: 5, y: 5)
    var blockedForTyping: Set<pid_t> = []
    var parents: [pid_t: pid_t] = [:]
    /// When set, the real mouse gesture runs this first (to simulate a slow action holding the controls).
    var mouseDelay: TimeInterval = 0
    private(set) var events: [Event] = []

    func record(_ event: Event) { lock.lock(); events.append(event); lock.unlock() }
    var log: [Event] { lock.lock(); defer { lock.unlock() }; return events }

    func addApp(pid: pid_t, name: String, bundle: String? = nil, frame: CGRect = .zero) {
        apps[pid] = App(target: ControlTarget(pid: pid, name: name, bundleIdentifier: bundle), frame: frame)
    }

    var accessibilityTrusted: Bool { trusted }
    var ownPID: pid_t { own }

    func app(named name: String) -> ControlTarget? {
        apps.values.first { $0.target.name.lowercased() == name.lowercased() }?.target
    }
    func target(pid: pid_t) -> ControlTarget { apps[pid]?.target ?? ControlTarget(pid: pid, name: "process \(pid)") }
    func parentPID(_ pid: pid_t) -> pid_t? { parents[pid] }
    func windowOwner(at point: CGPoint) -> ControlTarget? {
        apps.values.sorted { $0.target.pid < $1.target.pid }.first { $0.frame.contains(point) }?.target
    }
    func frontmostApp() async -> ControlTarget? { front.map { target(pid: $0) } }
    func isBlockedForTyping(_ pid: pid_t) -> Bool { blockedForTyping.contains(pid) || pid == own }

    private func node(_ handle: UIElementHandle) -> FakeNode { handle.ref as! FakeNode }   // swiftlint:disable:this force_cast

    func windows(app pid: pid_t) -> [UIElementHandle] { (apps[pid]?.windows ?? []).map(UIElementHandle.init) }
    func menuBar(app pid: pid_t) -> UIElementHandle? { apps[pid]?.menuBar.map(UIElementHandle.init) }
    func children(_ element: UIElementHandle) -> [UIElementHandle] { node(element).children.map(UIElementHandle.init) }
    func parent(_ element: UIElementHandle) -> UIElementHandle? { node(element).parent.map(UIElementHandle.init) }
    func info(_ element: UIElementHandle) -> ElementInfo { node(element).info }

    func element(at point: CGPoint, app pid: pid_t) -> UIElementHandle? {
        // Deepest node whose frame contains the point.
        func deepest(_ node: FakeNode) -> FakeNode? {
            guard let frame = node.info.frame, frame.contains(point) else { return nil }
            for child in node.children.reversed() { if let hit = deepest(child) { return hit } }
            return node
        }
        for window in apps[pid]?.windows ?? [] { if let hit = deepest(window) { return UIElementHandle(hit) } }
        return nil
    }
    func focusedElement(app pid: pid_t) -> UIElementHandle? { apps[pid]?.focused.map(UIElementHandle.init) }

    func perform(_ action: String, on element: UIElementHandle) -> String? {
        let n = node(element)
        if let failure = n.failure { return failure }
        guard n.info.actions.contains(action) else { return "the element doesn't support that action" }
        record(.axAction(action, n.info.title))
        return nil
    }
    func setFocused(_ element: UIElementHandle) -> String? {
        let n = node(element)
        if let failure = n.failure { return failure }
        n.info.focused = true
        if let pid = Optional(n.info.pid), apps[pid] != nil { apps[pid]?.focused = n }
        record(.focus(n.info.title))
        return nil
    }
    func setValue(_ value: String, on element: UIElementHandle) -> String? {
        let n = node(element)
        if let failure = n.failure { return failure }
        guard n.info.valueSettable else { return "the app refused the value" }
        n.info.value = value
        record(.setValue(value, n.info.title))
        return nil
    }
    func insertText(_ text: String, into element: UIElementHandle) -> String? {
        let n = node(element)
        if let failure = n.failure { return failure }
        guard n.info.selectedTextSettable else { return "the element doesn't have that attribute" }
        if !n.ignoresInsert { n.info.value = (n.info.value ?? "") + text }
        record(.insert(text, n.info.title))
        return nil
    }
    func textState(of element: UIElementHandle) -> TextState? {
        let n = node(element)
        guard n.info.isText else { return nil }
        return TextState(length: (n.info.value ?? "").count, selectionLength: 0)
    }

    func pointerLocation() -> CGPoint? { pointer }
    func warpPointer(to point: CGPoint) { pointer = point; record(.warp(point)) }
    func postMouse(_ gesture: MouseGesture) async {
        if mouseDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(mouseDelay * 1_000_000_000)) }
        record(.realMouse(gesture))
        if case .click(let at, _, _) = gesture { pointer = at }
        if case .drag(_, let to) = gesture { pointer = to }
    }
    func postKeys(_ combos: [KeyboardTool.ResolvedCombo], to pid: pid_t?) async { record(.keys(combos.count, pid)) }
    func postText(_ text: String, to pid: pid_t?) async { record(.text(text, pid)) }
    func activate(app name: String) async -> String? {
        guard let app = app(named: name) else { return "'\(name)' is not running" }
        front = app.pid
        record(.activate(name))
        return nil
    }
}

/// A person who is, or isn't, touching the mouse.
final class FakeHumanClock: HumanInputClock, @unchecked Sendable {
    private let lock = NSLock()
    private var activeUntil: Date?
    /// The person keeps using the mouse until `until`.
    func busy(until: Date) { lock.lock(); activeUntil = until; lock.unlock() }
    func secondsSinceLastInput() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        if let activeUntil, Date() < activeUntil { return 0.05 }
        return 600
    }
}

/// A cross-process lock held in memory, so two arbiters can contend in one test.
final class FakeMachineLock: MachineLock, @unchecked Sendable {
    let lock = NSLock()
    var holder: String?
    func tryLock(label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if holder == nil || holder == label { holder = label; return true }
        return false
    }
    func unlock() { lock.lock(); holder = nil; lock.unlock() }
    func holderLabel() -> String? { lock.lock(); defer { lock.unlock() }; return holder }
}

extension FakeMachineBackend {
    /// TextEdit-like app at pid 501: a window with a Save button, a name field, a canvas without actions, and a
    /// File menu with Save As…; Godot-like app at pid 777 with a canvas only.
    static func standard() -> FakeMachineBackend {
        let backend = FakeMachineBackend()
        backend.addApp(pid: 501, name: "TextEdit", bundle: "com.apple.TextEdit", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = FakeNode("AXWindow", "Untitled", actions: ["AXRaise"], frame: CGRect(x: 0, y: 0, width: 800, height: 600), pid: 501)
        let toolbar = window.add(FakeNode("AXToolbar", frame: CGRect(x: 0, y: 0, width: 800, height: 50), pid: 501))
        toolbar.add(FakeNode("AXButton", "Save", actions: ["AXPress"], frame: CGRect(x: 10, y: 10, width: 60, height: 30), pid: 501))
        let label = toolbar.add(FakeNode("AXButton", "Share", actions: ["AXPress", "AXShowMenu"], frame: CGRect(x: 80, y: 10, width: 60, height: 30), pid: 501))
        label.add(FakeNode("AXStaticText", "Share", frame: CGRect(x: 85, y: 15, width: 40, height: 20), pid: 501))
        window.add(FakeNode("AXTextField", "Name", frame: CGRect(x: 10, y: 60, width: 300, height: 24), pid: 501,
                            value: "draft", valueSettable: true, selectedTextSettable: true))
        window.add(FakeNode("AXGroup", frame: CGRect(x: 0, y: 100, width: 800, height: 500), pid: 501))
        let check = window.add(FakeNode("AXCheckBox", "Wrap lines", actions: ["AXPress"], frame: CGRect(x: 400, y: 60, width: 100, height: 20), pid: 501))
        _ = check
        let bar = FakeNode("AXMenuBar", pid: 501)
        let file = bar.add(FakeNode("AXMenuBarItem", "File", actions: ["AXPress"], pid: 501))
        let menu = file.add(FakeNode("AXMenu", pid: 501))
        menu.add(FakeNode("AXMenuItem", "Save As…", actions: ["AXPress"], pid: 501))
        menu.add(FakeNode("AXMenuItem", "Save", actions: ["AXPress"], pid: 501))
        menu.add(FakeNode("AXMenuItem", "Print…", actions: ["AXPress"], pid: 501))
        backend.apps[501]?.windows = [window]
        backend.apps[501]?.menuBar = bar

        backend.addApp(pid: 777, name: "Godot", frame: CGRect(x: 900, y: 0, width: 600, height: 600))
        let game = FakeNode("AXWindow", "Godot", actions: ["AXRaise"], frame: CGRect(x: 900, y: 0, width: 600, height: 600), pid: 777)
        game.add(FakeNode("AXGroup", frame: CGRect(x: 900, y: 20, width: 600, height: 580), pid: 777))
        backend.apps[777]?.windows = [game]
        backend.front = 501
        return backend
    }

    var textField: FakeNode { apps[501]!.windows[0].children[1] }
}
