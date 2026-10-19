import XCTest
import CoreGraphics
@testable import VisionHarnessCore

final class ControlPlannerTests: XCTestCase {
    let button = ElementInfo(role: "AXButton", title: "Save", actions: ["AXPress"])
    let text = ElementInfo(role: "AXStaticText", title: "Save")
    let field = ElementInfo(role: "AXTextField", title: "Name", valueSettable: true, selectedTextSettable: true)
    let area = ElementInfo(role: "AXTextArea", valueSettable: true, selectedTextSettable: true)
    let canvas = ElementInfo(role: "AXGroup")
    let window = ElementInfo(role: "AXWindow", title: "Doc", actions: ["AXRaise", "AXPress"])
    let finderIcon = ElementInfo(role: "AXImage", title: "report.pdf", actions: ["AXOpen", "AXShowMenu"])

    func plan(_ chain: [ElementInfo], button b: String = "left", clicks: Int = 1, drag: Bool = false,
              real: Bool = false, background: Bool = true, trusted: Bool = true) -> ControlPlanner.ClickPlan {
        ControlPlanner.planClick(button: b, clicks: clicks, isDrag: drag, forceReal: real, preferBackground: background,
                                 accessibilityTrusted: trusted, chain: chain)
    }

    func testAButtonIsPressedNotClicked() {
        XCTAssertEqual(plan([button]), .accessibility(.press, index: 0))
    }

    func testTheLabelInsideAButtonPressesTheButton() {
        XCTAssertEqual(plan([text, button]), .accessibility(.press, index: 1))
    }

    func testASingleLineFieldIsFocusedAndATextAreaGetsARealClick() {
        XCTAssertEqual(plan([field]), .accessibility(.focus, index: 0))
        guard case .realMouse = plan([area]) else { return XCTFail("caret placement in a text area needs a real click") }
    }

    func testContainersAreNeverPressed() {
        // A canvas inside a window: the window's AXPress must not stand in for a click on the canvas.
        guard case .realMouse(let why) = plan([canvas, window]) else { return XCTFail() }
        XCTAssertTrue(why.contains("no press action"), why)
    }

    func testDoubleClickOpensAndRightClickShowsTheMenu() {
        XCTAssertEqual(plan([finderIcon], clicks: 2), .accessibility(.open, index: 0))
        XCTAssertEqual(plan([finderIcon], button: "right"), .accessibility(.menu, index: 0))
        guard case .realMouse = plan([button], button: "right") else { return XCTFail("no AXShowMenu → real right-click") }
    }

    func testTheRealMouseWhenAskedOrNeeded() {
        guard case .realMouse(let forced) = plan([button], real: true) else { return XCTFail() }
        XCTAssertTrue(forced.contains("asked for"))
        guard case .realMouse(let drag) = plan([button], drag: true) else { return XCTFail() }
        XCTAssertTrue(drag.contains("drag"))
        guard case .realMouse(let off) = plan([button], background: false) else { return XCTFail() }
        XCTAssertTrue(off.contains("Settings ▸ Computer"))
        guard case .realMouse(let untrusted) = plan([button], trusted: false) else { return XCTFail() }
        XCTAssertTrue(untrusted.contains("Accessibility permission"))
        guard case .realMouse(let nothing) = plan([]) else { return XCTFail() }
        XCTAssertTrue(nothing.contains("nothing accessible"))
        guard case .realMouse = plan([button], button: "middle") else { return XCTFail() }
    }

    func testTextGoesInAtTheCaretWhenTheFieldAllowsIt() {
        XCTAssertEqual(ControlPlanner.planText(foreground: false, preferBackground: true, accessibilityTrusted: true, focused: field),
                       .insertAtCaret)
        // A password field, an element that isn't text, or no focus at all: key events to the app.
        let secure = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", selectedTextSettable: true)
        XCTAssertEqual(ControlPlanner.planText(foreground: false, preferBackground: true, accessibilityTrusted: true, focused: secure),
                       .postToProcess)
        XCTAssertEqual(ControlPlanner.planText(foreground: false, preferBackground: true, accessibilityTrusted: true, focused: canvas),
                       .postToProcess)
        XCTAssertEqual(ControlPlanner.planText(foreground: false, preferBackground: true, accessibilityTrusted: false, focused: field),
                       .postToProcess)
        guard case .realKeyboard = ControlPlanner.planText(foreground: true, preferBackground: true, accessibilityTrusted: true, focused: field)
        else { return XCTFail() }
        guard case .realKeyboard = ControlPlanner.planText(foreground: false, preferBackground: false, accessibilityTrusted: true, focused: field)
        else { return XCTFail() }
    }

    func testKeysGoToTheProcessUnlessForeground() {
        XCTAssertEqual(ControlPlanner.planKeys(foreground: false, preferBackground: true), .postToProcess)
        guard case .realKeyboard = ControlPlanner.planKeys(foreground: true, preferBackground: true) else { return XCTFail() }
    }

    func testWhichKeyboardRoutesWaitForTheControls() {
        // Background app: no wait.
        XCTAssertFalse(ControlPlanner.keyboardNeedsControls(text: .postToProcess, keys: .postToProcess, targetIsFront: false))
        XCTAssertFalse(ControlPlanner.keyboardNeedsControls(text: .insertAtCaret, keys: nil, targetIsFront: false))
        XCTAssertTrue(ControlPlanner.keyboardNeedsControls(text: .insertAtCaret, keys: nil, targetIsFront: true),
                      "an insert into the field the person is typing in waits for them too")
        // The app the person is in: events would land in their typing.
        XCTAssertTrue(ControlPlanner.keyboardNeedsControls(text: .postToProcess, keys: nil, targetIsFront: true))
        XCTAssertTrue(ControlPlanner.keyboardNeedsControls(text: nil, keys: .postToProcess, targetIsFront: true))
        XCTAssertTrue(ControlPlanner.keyboardNeedsControls(text: nil, keys: .realKeyboard(why: "x"), targetIsFront: false))
    }
}

final class UIElementTreeTests: XCTestCase {
    func testPathsParseAndRoundTrip() {
        XCTAssertEqual(UIElementTree.Path("w0.3.1"), UIElementTree.Path(root: .window(0), children: [3, 1]))
        XCTAssertEqual(UIElementTree.Path("#w2"), UIElementTree.Path(root: .window(2), children: []))
        XCTAssertEqual(UIElementTree.Path("m.1.0")?.root, .menuBar)
        XCTAssertEqual(UIElementTree.Path("w0.3.1")?.id, "w0.3.1")
        XCTAssertNil(UIElementTree.Path("x1"))
        XCTAssertNil(UIElementTree.Path("w0.a"))
        XCTAssertNil(UIElementTree.Path(""))
    }

    func testWalkListsWhatMattersWithStableIds() {
        let backend = FakeMachineBackend.standard()
        let walked = UIElementTree.walk(app: 501, backend: backend, maxDepth: 4)
        let ids = walked.rows.map(\.id)
        XCTAssertEqual(ids, ["w0", "w0.0.0", "w0.0.1", "w0.0.1.0", "w0.1", "w0.3"],
                       "the unnamed toolbar and canvas are walked through but not listed")
        XCTAssertEqual(walked.rows.first(where: { $0.id == "w0.0.0" })?.info.title, "Save")
        // A path from the walk resolves to the same element.
        let handle = UIElementTree.resolve(UIElementTree.Path("w0.3")!, app: 501, backend: backend)
        XCTAssertEqual(handle.map { backend.info($0).title }, "Wrap lines")
        XCTAssertNil(UIElementTree.resolve(UIElementTree.Path("w0.9")!, app: 501, backend: backend))
    }

    func testWalkStopsAtTheRowCap() {
        let backend = FakeMachineBackend.standard()
        let walked = UIElementTree.walk(app: 501, backend: backend, maxDepth: 4, maxRows: 2)
        XCTAssertEqual(walked.rows.count, 2)
        XCTAssertTrue(walked.truncated)
    }

    func testFindPrefersAnExactNameAndTheRightRole() {
        let backend = FakeMachineBackend.standard()
        let rows = UIElementTree.walk(app: 501, backend: backend, maxDepth: 6).rows
        XCTAssertEqual(UIElementTree.find("save", role: nil, action: "press", in: rows).first?.id, "w0.0.0")
        XCTAssertEqual(UIElementTree.find("share", role: "button", action: "press", in: rows).first?.id, "w0.0.1",
                       "the button, not its label")
        XCTAssertEqual(UIElementTree.find("wrap", role: "checkbox", action: nil, in: rows).first?.id, "w0.3")
        XCTAssertEqual(UIElementTree.find("name", role: "text field", action: "set_value", in: rows).first?.id, "w0.1")
        XCTAssertTrue(UIElementTree.find("nothing like this", role: nil, action: nil, in: rows).isEmpty)
    }

    func testMenuPathsFindItemsThroughTheMenus() {
        let backend = FakeMachineBackend.standard()
        guard case .success(let item) = UIElementTree.menuItem("File > Save As", app: 501, backend: backend) else {
            return XCTFail("the ellipsis is optional")
        }
        XCTAssertEqual(backend.info(item).title, "Save As…")
        guard case .success(let exact) = UIElementTree.menuItem("file › save", app: 501, backend: backend) else { return XCTFail() }
        XCTAssertEqual(backend.info(exact).title, "Save", "an exact title beats a prefix")
        guard case .failure(let error) = UIElementTree.menuItem("File > Export", app: 501, backend: backend) else { return XCTFail() }
        XCTAssertTrue(error.message.contains("Save As…"), "says what is there: \(error.message)")
    }

    func testElementLinesSayWhatTheyCanDoAndHidePasswords() {
        XCTAssertEqual(ElementInfo(role: "AXButton", title: "Save", frame: CGRect(x: 1, y: 2, width: 3, height: 4), actions: ["AXPress"]).line(),
                       "Button \"Save\" (press) [1,2 3x4]")
        let secret = ElementInfo(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "hunter2")
        XCTAssertFalse(secret.line().contains("hunter2"))
        XCTAssertTrue(secret.line().contains("••••"))
    }
}

final class MachineSeatTests: XCTestCase {
    func testUnrestrictedChatsMayControlAnyApp() {
        let seat = MachineSeat(chatID: "c1", title: "Chat", arbiter: ControlArbiter(machineLock: nil))
        XCTAssertEqual(seat.decide(ControlTarget(pid: 42, name: "Safari"), parentOf: { _ in nil }), .allowed)
    }

    func testRestrictedChatsMayControlWhatTheyStartedAndItsChildren() {
        let seat = MachineSeat(chatID: "c1", title: "Chat", arbiter: ControlArbiter(machineLock: nil))
        seat.options = MachineControlOptions(restrictToOwnApps: true)
        seat.noteSpawned(pid: 300)
        let parents: [pid_t: pid_t] = [301: 300, 302: 301, 400: 1]
        XCTAssertEqual(seat.decide(ControlTarget(pid: 300, name: "sh"), parentOf: { parents[$0] }), .allowed)
        XCTAssertEqual(seat.decide(ControlTarget(pid: 302, name: "Godot"), parentOf: { parents[$0] }), .allowed,
                       "a grandchild of a process this chat started")
        XCTAssertEqual(seat.decide(ControlTarget(pid: 400, name: "Safari"), parentOf: { parents[$0] }), .needsApproval("Safari"))
        seat.approve(ControlTarget(pid: 400, name: "Safari", bundleIdentifier: "com.apple.Safari"))
        XCTAssertEqual(seat.decide(ControlTarget(pid: 401, name: "Safari", bundleIdentifier: "com.apple.Safari"), parentOf: { _ in nil }),
                       .allowed, "an approval holds for the app, not the one process")
    }

    func testControlOverrideBeatsTheSetting() {
        let seat = MachineSeat(chatID: "c1", title: "Chat", arbiter: ControlArbiter(machineLock: nil))
        XCTAssertFalse(seat.isRestricted)
        seat.setRestricted(true)
        XCTAssertTrue(seat.isRestricted)
        seat.approve(names: ["TextEdit"])
        XCTAssertEqual(seat.decide(ControlTarget(pid: 9, name: "TextEdit"), parentOf: { _ in nil }), .allowed)
        seat.options = MachineControlOptions(restrictToOwnApps: true)
        seat.setRestricted(false)
        XCTAssertFalse(seat.isRestricted, "/control any wins over the setting")
        seat.setRestricted(nil)
        XCTAssertTrue(seat.isRestricted, "/control default goes back to the setting")
    }

    func testSubagentsShareTheScopeButNotThePlaceInLine() {
        let seat = MachineSeat(chatID: "c1", title: "Chat", arbiter: ControlArbiter(machineLock: nil))
        seat.setRestricted(true)
        let sub = seat.child()
        XCTAssertNotEqual(sub.holderID, seat.holderID)
        XCTAssertEqual(sub.chatID, "c1")
        sub.noteSpawned(pid: 77)
        XCTAssertTrue(seat.spawnedPIDs.contains(77), "what a subagent starts is the chat's")
        XCTAssertTrue(sub.isRestricted)
        XCTAssertNotEqual(seat.child().holderID, sub.holderID)
    }

    func testOptionsDecodeWithMissingFields() throws {
        let decoded = try JSONDecoder().decode(MachineControlOptions.self, from: Data(#"{"restrictToOwnApps":true}"#.utf8))
        XCTAssertEqual(decoded, MachineControlOptions(preferBackground: true, restrictToOwnApps: true, waitTimeout: 90))
    }
}

final class GlowStatusTests: XCTestCase {
    let a = ControlHolder(id: "a", chatID: "a", label: "Fix the build")
    let b = ControlHolder(id: "b", chatID: "b", label: "Book a flight")

    func testThePillNamesTheChatWithTheMouse() {
        let pill = GlowStatus.pill(control: ControlSnapshot(holder: a, waiting: [b]), work: [])
        XCTAssertEqual(pill, "Vision AI · “Fix the build” has the mouse and keyboard · 1 waiting · ⌃⌥⌘. stops")
    }

    func testThePillSaysTheMouseIsFreeForBackgroundWork() {
        let one = GlowStatus.pill(control: .idle, work: [MachineWork(chatID: "a", chatTitle: "Fix the build", app: "TextEdit")])
        XCTAssertEqual(one, "Vision AI · “Fix the build” is working in TextEdit — your mouse is free · ⌃⌥⌘. stops")
        let two = GlowStatus.pill(control: .idle, work: [MachineWork(chatID: "a", chatTitle: "A"), MachineWork(chatID: "b", chatTitle: "B")])
        XCTAssertEqual(two, "Vision AI · 2 chats are working — your mouse is free · ⌃⌥⌘. stops")
        let looking = GlowStatus.pill(control: .idle, work: [MachineWork(chatID: "a", chatTitle: "A", observing: true)])
        XCTAssertEqual(looking, "Vision AI · “A” is looking at the screen · ⌃⌥⌘. stops")
    }

    func testThePillWhenWaitingForThePersonOrAnotherWindow() {
        XCTAssertEqual(GlowStatus.pill(control: ControlSnapshot(holder: a, waitingForPerson: true), work: []),
                       "Vision AI · “Fix the build” is waiting for you to finish with the mouse · ⌃⌥⌘. stops")
        XCTAssertEqual(GlowStatus.pill(control: ControlSnapshot(otherProcessHolder: "Elsewhere"), work: []),
                       "Vision AI · “Elsewhere” (another Vision window) has the mouse · ⌃⌥⌘. stops")
    }

    func testLongTitlesAreShortened() {
        let long = ControlHolder(id: "x", chatID: "x", label: String(repeating: "word ", count: 20))
        let pill = GlowStatus.pill(control: ControlSnapshot(holder: long), work: [])
        XCTAssertLessThan(pill.count, 110)
        XCTAssertTrue(pill.contains("…”"))
    }

    func testWaitingLines() {
        let snapshot = ControlSnapshot(holder: a, waiting: [b])
        XCTAssertEqual(GlowStatus.waitingLine(chatID: "b", control: snapshot),
                       "Waiting for the mouse — “Fix the build” is using it. It goes to the next chat when that one is done; ⌃⌥⌘. stops all control.")
        XCTAssertNil(GlowStatus.waitingLine(chatID: "a", control: snapshot))
        XCTAssertEqual(GlowStatus.waitingLine(chatID: "a", control: ControlSnapshot(holder: a, waitingForPerson: true)),
                       "Waiting for you to finish with the mouse and keyboard…")
        XCTAssertTrue(GlowStatus.isActive(control: snapshot, work: []))
        XCTAssertFalse(GlowStatus.isActive(control: .idle, work: []))
    }

    func testControlSlashCommandParses() {
        XCTAssertEqual(SlashCommand.parse("/control only Safari, Godot"), .control("only Safari, Godot"))
        XCTAssertEqual(SlashCommand.parse("/control"), .control(nil))
        XCTAssertTrue(SlashCommand.catalog.contains { $0.usage.hasPrefix("/control") })
    }
}
