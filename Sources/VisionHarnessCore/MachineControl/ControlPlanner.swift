import Foundation
import CoreGraphics

// MARK: - Choosing how to act without taking the person's mouse
//
// The order of preference, for every control action:
//
// 1. An Accessibility action on the element itself — AXPress on a button,
//    AXShowMenu for a right-click, AXOpen for a double-click, focusing a
//    text field, inserting text at a field's caret. Nothing moves: the
//    pointer stays where the person left it and the app stays behind.
// 2. Events posted to the target process only (CGEvent.postToPid) — keys
//    and typed text reach that app even while it is in the background.
// 3. The real mouse and keyboard (events through the HID tap, the app
//    brought forward). Only when nothing above can do it — a drag, a click
//    on something with no accessible action (a game canvas, a table cell),
//    the model asking for it — and only while this chat holds the controls
//    from `ControlArbiter`, after the person has left the mouse alone.
//
// These functions only decide; `MachineActions` carries the decision out.

public enum ControlPlanner {
    public enum ClickPlan: Equatable, Sendable {
        /// Do `verb` on `chain[index]` (0 = the element under the point, 1+ = its ancestors).
        case accessibility(ActionVerb, index: Int)
        /// Use the real mouse; `why` is said in the tool result.
        case realMouse(why: String)
    }

    /// Roles that are containers, never "the thing clicked" (pressing one would mean something else).
    static let containerRoles: Set<String> = ["AXWindow", "AXApplication", "AXScrollArea", "AXWebArea", "AXSplitGroup",
                                              "AXSheet", "AXDrawer", "AXBrowser", "AXLayoutArea"]

    /// How a click at a point should be done. `chain` is the element under the point followed by up to two of
    /// its ancestors (what the click would land on, innermost first).
    public static func planClick(button: String, clicks: Int, isDrag: Bool, forceReal: Bool, preferBackground: Bool,
                                 accessibilityTrusted: Bool, chain: [ElementInfo]) -> ClickPlan {
        if forceReal { return .realMouse(why: "the real mouse was asked for") }
        if isDrag { return .realMouse(why: "a drag needs the real mouse") }
        if !preferBackground { return .realMouse(why: "background actions are off (Settings ▸ Computer)") }
        if button == "middle" { return .realMouse(why: "a middle click needs the real mouse") }
        if !accessibilityTrusted {
            return .realMouse(why: "Accessibility permission is not granted to \(AppIdentity.name), so it can't press controls directly")
        }
        guard let target = chain.first else { return .realMouse(why: "nothing accessible is under that point") }
        let candidates = chain.prefix(3).enumerated().filter { !containerRoles.contains($0.element.role) }
        switch (button, clicks) {
        case ("left", 1):
            if ElementInfo.singleLineTextRoles.contains(target.role) { return .accessibility(.focus, index: 0) }
            if let hit = candidates.first(where: { supports($0.element, .press) }) {
                return .accessibility(.press, index: hit.offset)
            }
            return .realMouse(why: "\(describe(target)) has no press action")
        case ("left", _):
            if let hit = candidates.first(where: { supports($0.element, .open) }) {
                return .accessibility(.open, index: hit.offset)
            }
            return .realMouse(why: "a double-click on \(describe(target)) needs the real mouse")
        case ("right", _):
            if let hit = candidates.first(where: { supports($0.element, .menu) }) {
                return .accessibility(.menu, index: hit.offset)
            }
            return .realMouse(why: "\(describe(target)) has no context-menu action")
        default:
            return .realMouse(why: "that click needs the real mouse")
        }
    }

    public enum TextPlan: Equatable, Sendable {
        /// Insert at the focused field's caret through Accessibility (no events at all).
        case insertAtCaret
        /// Unicode key events posted to the target process only.
        case postToProcess
        /// The real keyboard, with the app in front.
        case realKeyboard(why: String)
    }

    /// How literal text should be typed into an app. `focused` is the app's focused element, when known.
    public static func planText(foreground: Bool, preferBackground: Bool, accessibilityTrusted: Bool,
                                focused: ElementInfo?) -> TextPlan {
        if foreground { return .realKeyboard(why: "typing with the app in front was asked for") }
        if !preferBackground { return .realKeyboard(why: "background actions are off (Settings ▸ Computer)") }
        if accessibilityTrusted, let focused, focused.isText, focused.selectedTextSettable, !focused.isSecure, focused.enabled {
            return .insertAtCaret
        }
        return .postToProcess
    }

    public enum KeysPlan: Equatable, Sendable {
        case postToProcess
        case realKeyboard(why: String)
    }

    /// How key combos should be pressed.
    public static func planKeys(foreground: Bool, preferBackground: Bool) -> KeysPlan {
        if foreground { return .realKeyboard(why: "pressing keys with the app in front was asked for") }
        if !preferBackground { return .realKeyboard(why: "background actions are off (Settings ▸ Computer)") }
        return .postToProcess
    }

    /// Whether a keyboard route needs the machine's controls from the arbiter: the real keyboard always does,
    /// and so does anything typed into the app the person is in — key events or an insert at its caret would land
    /// in the middle of the person's own typing. An app in the background needs neither.
    public static func keyboardNeedsControls(text: TextPlan?, keys: KeysPlan?, targetIsFront: Bool) -> Bool {
        if case .realKeyboard = text { return true }
        if case .realKeyboard = keys { return true }
        return targetIsFront && (text != nil || keys != nil)
    }

    /// Whether the element can do `verb` (focus and set_value/type go through attributes).
    public static func supports(_ info: ElementInfo, _ verb: ActionVerb) -> Bool {
        switch verb {
        case .focus: return true
        case .setValue: return info.valueSettable
        case .typeText: return info.selectedTextSettable || info.valueSettable
        default:
            guard let action = verb.axAction else { return false }
            return info.actions.contains(action)
        }
    }

    /// "the button \"Save\"", "the text field there".
    static func describe(_ info: ElementInfo) -> String {
        let role = roleName(info.role)
        if let name = info.name { return "the \(role) \"\(ElementInfo.clip(name, 40))\"" }
        return "the \(role) there"
    }

    /// A role in plain words.
    static func roleName(_ role: String) -> String {
        let names: [String: String] = [
            "AXTextField": "text field", "AXTextArea": "text area", "AXCheckBox": "checkbox",
            "AXRadioButton": "radio button", "AXPopUpButton": "pop-up button", "AXMenuItem": "menu item",
            "AXMenuBarItem": "menu", "AXMenuButton": "menu button", "AXStaticText": "text", "AXComboBox": "combo box",
            "AXSearchField": "search field", "AXScrollArea": "scroll area", "AXWebArea": "web page",
            "AXDisclosureTriangle": "disclosure triangle", "AXSplitGroup": "split view", "AXTabGroup": "tab group",
        ]
        if let name = names[role] { return name }
        return (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }
}
