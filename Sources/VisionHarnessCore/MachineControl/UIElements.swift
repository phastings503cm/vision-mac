import Foundation
import CoreGraphics

// MARK: - Accessibility elements, as plain values
//
// The tools work on `ElementInfo` values and `UIElementHandle`s from a
// `MachineBackend`, never on AXUIElement directly, so the decisions (which
// element a query means, whether a click can be an Accessibility press) are
// tested against a fake tree, and the live backend is the only code that
// talks to the Accessibility API.

/// An element on the other side of the backend (an AXUIElement live, a node in tests).
public final class UIElementHandle: @unchecked Sendable {
    public let ref: AnyObject
    public init(_ ref: AnyObject) { self.ref = ref }
}

/// What an element is and what it can do.
public struct ElementInfo: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var label: String?        // AXDescription
    public var value: String?
    public var identifier: String?
    public var help: String?
    public var enabled: Bool
    public var focused: Bool
    public var frame: CGRect?
    /// Accessibility actions it supports ("AXPress", "AXShowMenu", …).
    public var actions: [String]
    /// Its value can be set (a text field, a checkbox on some apps, a slider).
    public var valueSettable: Bool
    /// Text can be inserted at its caret (AXSelectedText is settable).
    public var selectedTextSettable: Bool
    /// The process it belongs to.
    public var pid: pid_t

    public init(role: String, subrole: String? = nil, title: String? = nil, label: String? = nil, value: String? = nil,
                identifier: String? = nil, help: String? = nil, enabled: Bool = true, focused: Bool = false,
                frame: CGRect? = nil, actions: [String] = [], valueSettable: Bool = false,
                selectedTextSettable: Bool = false, pid: pid_t = 0) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.identifier = identifier
        self.help = help
        self.enabled = enabled
        self.focused = focused
        self.frame = frame
        self.actions = actions
        self.valueSettable = valueSettable
        self.selectedTextSettable = selectedTextSettable
        self.pid = pid
    }

    /// The name a person would call it: its title, else its description, else its help or identifier.
    public var name: String? {
        for candidate in [title, label, help, identifier] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Single-line text: a click there means "put the caret in it", which focusing does.
    public static let singleLineTextRoles: Set<String> = ["AXTextField", "AXComboBox", "AXSearchField"]

    public var isText: Bool { Self.textRoles.contains(role) || subrole == "AXSearchField" || subrole == "AXSecureTextField" }
    public var isSecure: Bool { subrole == "AXSecureTextField" }

    /// One line for `ui_tree` / tool results: `AXButton "Save" (press) [x,y w×h]`.
    public func line(includeFrame: Bool = true) -> String {
        var out = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        if let subrole, !subrole.isEmpty, subrole != role { out += "(" + (subrole.hasPrefix("AX") ? String(subrole.dropFirst(2)) : subrole) + ")" }
        if let name { out += " \"" + Self.clip(name, 60) + "\"" }
        if let value, !value.isEmpty, value != name, !isSecure { out += " = " + Self.clip(value, 80) }
        if isSecure, value?.isEmpty == false { out += " = ••••" }
        let verbs = actions.compactMap(Self.verb)
        if !verbs.isEmpty { out += " (" + verbs.joined(separator: ", ") + ")" }
        if valueSettable && isText { out += " (editable)" }
        if !enabled { out += " [disabled]" }
        if focused { out += " [focused]" }
        if includeFrame, let frame {
            out += " [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
        }
        return out
    }

    /// The `ui_action` verb an AX action is offered as (nil: not offered).
    static func verb(_ action: String) -> String? {
        switch action {
        case "AXPress": "press"
        case "AXConfirm": "confirm"
        case "AXShowMenu": "menu"
        case "AXIncrement": "increment"
        case "AXDecrement": "decrement"
        case "AXOpen": "open"
        case "AXPick": "pick"
        case "AXCancel": "cancel"
        case "AXRaise": "raise"
        default: nil
        }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// One row of a walked tree: where it is (a path of child indexes from the app) and what it is.
public struct ElementRow: Sendable, Equatable {
    /// "w0.3.1" — window 0, its child 3, that one's child 1; "m.2" — the menu bar's child 2.
    public var id: String
    public var depth: Int
    public var info: ElementInfo
}

/// Walks a backend's elements and finds the one a query means.
public enum UIElementTree {
    /// An element path from its id ("w0.3.1" → window 0, then children 3 and 1; "m.2" → menu bar child 2).
    public struct Path: Sendable, Equatable {
        public enum Root: Sendable, Equatable { case window(Int), menuBar }
        public var root: Root
        public var children: [Int]

        public init(root: Root, children: [Int]) {
            self.root = root
            self.children = children
        }

        public init?(_ id: String) {
            var text = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.hasPrefix("#") { text.removeFirst() }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard let head = parts.first, !head.isEmpty else { return nil }
            if head == "m" {
                root = .menuBar
            } else if head.hasPrefix("w"), let index = Int(head.dropFirst()), index >= 0 {
                root = .window(index)
            } else {
                return nil
            }
            var kids: [Int] = []
            for part in parts.dropFirst() {
                guard let index = Int(part), index >= 0 else { return nil }
                kids.append(index)
            }
            children = kids
        }

        public var id: String {
            let head: String
            switch root {
            case .window(let i): head = "w\(i)"
            case .menuBar: head = "m"
            }
            return ([head] + children.map(String.init)).joined(separator: ".")
        }
    }

    /// Walk an app's windows (and its menu bar when asked), depth-first, up to `maxDepth` levels below each
    /// root and `maxRows` rows in all. Rows with nothing to say (unnamed groups with no actions) are still
    /// walked through but not listed, so the output stays readable.
    public static func walk(app pid: pid_t, backend: any MachineBackend, maxDepth: Int, maxRows: Int = 400,
                            includeMenus: Bool = false) -> (rows: [ElementRow], truncated: Bool) {
        var rows: [ElementRow] = []
        var truncated = false
        func visit(_ handle: UIElementHandle, id: String, depth: Int) {
            guard rows.count < maxRows else { truncated = true; return }
            let info = backend.info(handle)
            if depth == 0 || isWorthListing(info) {
                rows.append(ElementRow(id: id, depth: depth, info: info))
            }
            guard depth < maxDepth else { return }
            for (index, child) in backend.children(handle).enumerated() {
                visit(child, id: "\(id).\(index)", depth: depth + 1)
                if rows.count >= maxRows { truncated = true; return }
            }
        }
        for (index, window) in backend.windows(app: pid).enumerated() {
            visit(window, id: "w\(index)", depth: 0)
        }
        if includeMenus, let bar = backend.menuBar(app: pid) {
            visit(bar, id: "m", depth: 0)
        }
        return (rows, truncated)
    }

    static func isWorthListing(_ info: ElementInfo) -> Bool {
        if info.name != nil { return true }
        if let value = info.value, !value.isEmpty { return true }
        if info.actions.contains(where: { ElementInfo.verb($0) != nil }) { return true }
        if info.isText { return true }
        return false
    }

    /// Follow a path from an app's windows or menu bar.
    public static func resolve(_ path: Path, app pid: pid_t, backend: any MachineBackend) -> UIElementHandle? {
        var current: UIElementHandle?
        switch path.root {
        case .window(let index):
            let windows = backend.windows(app: pid)
            current = index < windows.count ? windows[index] : nil
        case .menuBar:
            current = backend.menuBar(app: pid)
        }
        for index in path.children {
            guard let node = current else { return nil }
            let kids = backend.children(node)
            current = index < kids.count ? kids[index] : nil
        }
        return current
    }

    /// Follow a menu path ("File > Save As…") from the menu bar: each step matches a menu bar item or menu
    /// item by title (exact, case-insensitive, an ellipsis and trailing dots optional; else a unique prefix).
    public static func menuItem(_ menuPath: String, app pid: pid_t, backend: any MachineBackend)
        -> Result<UIElementHandle, MenuError> {
        let steps = menuPath.split(whereSeparator: { $0 == ">" || $0 == "›" || $0 == "→" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steps.isEmpty else { return .failure(.empty) }
        guard var current = backend.menuBar(app: pid) else { return .failure(.noMenuBar) }
        for (offset, step) in steps.enumerated() {
            // Menu bar items hold a menu (AXMenu) holding the items: look through one level of menus.
            var candidates: [UIElementHandle] = []
            for child in backend.children(current) {
                let info = backend.info(child)
                if info.role == "AXMenu" {
                    candidates.append(contentsOf: backend.children(child))
                } else {
                    candidates.append(child)
                }
            }
            let titled = candidates.map { ($0, backend.info($0).title ?? "") }
            let wanted = normalizeMenuTitle(step)
            if let exact = titled.first(where: { normalizeMenuTitle($0.1) == wanted }) {
                current = exact.0
            } else {
                let prefixed = titled.filter { normalizeMenuTitle($0.1).hasPrefix(wanted) }
                guard prefixed.count == 1 else {
                    let names = titled.map(\.1).filter { !$0.isEmpty }
                    return .failure(.notFound(step: step, at: offset, choices: Array(names.prefix(30))))
                }
                current = prefixed[0].0
            }
        }
        return .success(current)
    }

    public enum MenuError: Error, Equatable {
        case empty, noMenuBar
        case notFound(step: String, at: Int, choices: [String])

        public var message: String {
            switch self {
            case .empty: "menu path is empty — write it like \"File > Save As…\"."
            case .noMenuBar: "this app has no menu bar to use."
            case .notFound(let step, _, let choices):
                "no menu item \"\(step)\"" + (choices.isEmpty ? "." : ". There: " + choices.joined(separator: ", "))
            }
        }
    }

    static func normalizeMenuTitle(_ title: String) -> String {
        var text = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("…") || text.hasSuffix(".") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Finding an element by what it says

    /// Roles a person names in plain words ("button", "text field", "checkbox").
    public static func normalizeRole(_ role: String) -> String {
        let flat = role.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        let known: [String: String] = [
            "button": "AXButton", "checkbox": "AXCheckBox", "radiobutton": "AXRadioButton", "radio": "AXRadioButton",
            "textfield": "AXTextField", "field": "AXTextField", "textarea": "AXTextArea", "text": "AXStaticText",
            "statictext": "AXStaticText", "label": "AXStaticText", "link": "AXLink", "menuitem": "AXMenuItem",
            "menu": "AXMenu", "menubutton": "AXMenuButton", "popupbutton": "AXPopUpButton", "popup": "AXPopUpButton",
            "combobox": "AXComboBox", "tab": "AXRadioButton", "slider": "AXSlider", "row": "AXRow", "cell": "AXCell",
            "image": "AXImage", "window": "AXWindow", "searchfield": "AXTextField", "list": "AXList",
            "table": "AXTable", "outline": "AXOutline", "toolbar": "AXToolbar", "group": "AXGroup",
        ]
        if let mapped = known[flat] { return mapped }
        if role.hasPrefix("AX") { return role }
        return "AX" + role.prefix(1).uppercased() + role.dropFirst()
    }

    /// The rows matching `query` (title, description, value, identifier or help) and `role`, best first:
    /// an exact name beats a prefix beats a substring; an enabled element that can do `action` beats one that
    /// can't; on a tie, the earlier (higher, frontmost) row wins.
    public static func find(_ query: String?, role: String?, action: String?, in rows: [ElementRow]) -> [ElementRow] {
        let wanted = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let wantedRole = role.map(normalizeRole)
        var scored: [(row: ElementRow, score: Int, order: Int)] = []
        for (order, row) in rows.enumerated() {
            let info = row.info
            if let wantedRole, info.role != wantedRole, info.subrole != wantedRole { continue }
            var score = 0
            if !wanted.isEmpty {
                let fields = [info.title, info.label, info.identifier, info.help, info.isSecure ? nil : info.value]
                    .compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if fields.contains(wanted) {
                    score = 300
                } else if fields.contains(where: { $0.hasPrefix(wanted) }) {
                    score = 200
                } else if fields.contains(where: { $0.contains(wanted) }) {
                    score = 100
                } else {
                    continue
                }
            } else if wantedRole == nil {
                continue
            }
            if info.enabled { score += 20 }
            if let action, ActionVerb(rawValue: action).map({ ControlPlanner.supports(info, $0) }) == true { score += 40 }
            scored.append((row, score, order))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.row)
    }
}

/// What `ui_action` can do to an element.
public enum ActionVerb: String, Sendable, CaseIterable {
    case press, confirm, focus, raise, menu = "show_menu", setValue = "set_value", increment, decrement, open, cancel, pick
    case typeText = "type"

    /// The AX action it performs (nil: done with an attribute instead).
    public var axAction: String? {
        switch self {
        case .press: "AXPress"
        case .confirm: "AXConfirm"
        case .raise: "AXRaise"
        case .menu: "AXShowMenu"
        case .increment: "AXIncrement"
        case .decrement: "AXDecrement"
        case .open: "AXOpen"
        case .cancel: "AXCancel"
        case .pick: "AXPick"
        case .focus, .setValue, .typeText: nil
        }
    }
}
