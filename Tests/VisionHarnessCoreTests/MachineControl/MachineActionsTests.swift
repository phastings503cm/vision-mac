import XCTest
import CoreGraphics
@testable import VisionHarnessCore

/// The control tools end to end against a scripted Mac: which route each action took (Accessibility, events to
/// one process, the real mouse in turn), and what the model was told.
final class MachineActionsTests: XCTestCase, @unchecked Sendable {
    var arbiter: ControlArbiter!
    var clock: FakeHumanClock!

    override func setUp() {
        clock = FakeHumanClock()
        arbiter = ControlArbiter(settings: .init(waitTimeout: 5, idleRelease: 0.2, humanQuiet: 1.5), clock: clock, machineLock: nil)
    }

    func seat(_ id: String = "chat-a", title: String = "Fix the build", wait: TimeInterval = 5) -> MachineSeat {
        let seat = MachineSeat(chatID: id, title: title, arbiter: arbiter)
        seat.options = MachineControlOptions(waitTimeout: wait)
        return seat
    }

    func actions(_ backend: FakeMachineBackend, _ seat: MachineSeat, approve: Bool = true,
                 asked: Recorder<String>? = nil) -> MachineActions {
        MachineActions(backend: backend, seat: seat) { _, _, detail in
            asked?.append(detail)
            return approve
        }
    }

    // MARK: Clicking

    func testClickingAButtonPressesItWithoutTheMouseOrTheControls() async {
        let backend = FakeMachineBackend.standard()
        let result = await actions(backend, seat()).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log, [.axAction("AXPress", "Save")])
        XCTAssertTrue(result.output.contains("Pressed the button \"Save\" in TextEdit through Accessibility"), result.output)
        XCTAssertTrue(result.output.contains("your mouse and keyboard weren't used"))
        let holder = await arbiter.snapshot().holder
        XCTAssertNil(holder, "a background press never takes the controls")
        XCTAssertEqual(backend.pointer, CGPoint(x: 5, y: 5))
    }

    func testClickingALabelPressesItsButtonAndRightClickShowsItsMenu() async {
        let backend = FakeMachineBackend.standard()
        _ = await actions(backend, seat()).click(at: CGPoint(x: 90, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        _ = await actions(backend, seat()).click(at: CGPoint(x: 90, y: 20), button: "right", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log, [.axAction("AXPress", "Share"), .axAction("AXShowMenu", "Share")])
    }

    func testClickingATextFieldFocusesIt() async {
        let backend = FakeMachineBackend.standard()
        _ = await actions(backend, seat()).click(at: CGPoint(x: 50, y: 70), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log, [.focus("Name")])
    }

    func testACanvasClickUsesTheRealMouseInTurnAndGivesThePointerBack() async {
        let backend = FakeMachineBackend.standard()
        let result = await actions(backend, seat()).click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log, [.realMouse(.click(CGPoint(x: 1000, y: 300), button: "left", clicks: 1)),
                                     .warp(CGPoint(x: 5, y: 5))])
        XCTAssertTrue(result.output.contains("in Godot with the real mouse (the group there has no press action)"), result.output)
        XCTAssertTrue(result.output.contains("pointer was put back"))
        let holder = await arbiter.snapshot().holder
        XCTAssertEqual(holder?.chatID, "chat-a", "it holds the controls until it idles")
    }

    func testAFailedPressFallsBackToTheRealMouseAndSaysWhy() async {
        let backend = FakeMachineBackend.standard()
        backend.apps[501]!.windows[0].children[0].children[0].failure = "the app didn't answer (busy, or it went away)"
        let result = await actions(backend, seat()).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log.first, .realMouse(.click(CGPoint(x: 20, y: 20), button: "left", clicks: 1)))
        XCTAssertTrue(result.output.contains("Accessibility couldn't: the app didn't answer"), result.output)
    }

    func testWithoutAccessibilityEveryClickIsReal() async {
        let backend = FakeMachineBackend.standard()
        backend.trusted = false
        let result = await actions(backend, seat()).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log.first, .realMouse(.click(CGPoint(x: 20, y: 20), button: "left", clicks: 1)))
        XCTAssertTrue(result.output.contains("Accessibility permission is not granted"), result.output)
    }

    func testNeverClicksIntoVisionItself() async {
        let backend = FakeMachineBackend.standard()
        backend.addApp(pid: 99, name: "Vision", frame: CGRect(x: 2000, y: 0, width: 400, height: 400))
        let result = await actions(backend, seat()).click(at: CGPoint(x: 2100, y: 100), button: "left", clicks: 1, dragTo: nil, forceReal: true)
        XCTAssertTrue(backend.log.isEmpty)
        XCTAssertTrue(result.output.hasPrefix("Error: not acting on Vision itself"), result.output)
    }

    // MARK: One chat at a time

    func testASecondChatWaitsItsTurnForTheRealMouse() async throws {
        let backend = FakeMachineBackend.standard()
        backend.mouseDelay = 0.3
        let first = seat("chat-a", title: "Fix the build")
        let second = seat("chat-b", title: "Book a flight")
        let activities = Recorder<SeatActivity>()
        second.onActivity = { activities.append($0) }
        let firstActions = actions(backend, first)
        let firstClick = Task { await firstActions.click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false) }
        let arb: ControlArbiter = arbiter
        try await waitUntil { await arb.snapshot().holder?.chatID == "chat-a" }
        let secondClick = await actions(backend, second).click(at: CGPoint(x: 1100, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        _ = await firstClick.value
        XCTAssertTrue(activities.values.contains(.waitingForControls(holder: "Fix the build")), "\(activities.values)")
        XCTAssertTrue(secondClick.output.contains("with the real mouse"), secondClick.output)
        let clicks = backend.log.compactMap { event -> CGPoint? in
            if case .realMouse(.click(let at, _, _)) = event { return at }
            return nil
        }
        XCTAssertEqual(clicks, [CGPoint(x: 1000, y: 300), CGPoint(x: 1100, y: 300)], "never interleaved")
    }

    func testAWaitThatRunsOutNamesTheChatWithTheMouse() async throws {
        let backend = FakeMachineBackend.standard()
        let holder = ControlHolder(id: "chat-a", chatID: "chat-a", label: "Fix the build")
        let slowArbiter = ControlArbiter(settings: .init(waitTimeout: 5, idleRelease: 30, humanQuiet: 1.5), clock: clock, machineLock: nil)
        _ = await slowArbiter.acquire(holder)
        let waiting = MachineSeat(chatID: "chat-b", title: "Book a flight", arbiter: slowArbiter)
        waiting.options = MachineControlOptions(waitTimeout: 0.3)
        let result = await actions(backend, waiting).click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertTrue(backend.log.isEmpty)
        XCTAssertTrue(result.output.contains("the chat “Fix the build” is still using them"), result.output)
        XCTAssertTrue(result.output.contains("ui_action"), "points the model at the background route")
    }

    func testBackgroundPressesFromTwoChatsDontWaitForEachOther() async throws {
        let backend = FakeMachineBackend.standard()
        let holder = ControlHolder(id: "chat-z", chatID: "chat-z", label: "Someone else")
        _ = await arbiter.acquire(holder)   // another chat holds the real mouse
        let result = await actions(backend, seat()).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(backend.log, [.axAction("AXPress", "Save")], "an Accessibility press needs no turn")
        XCTAssertFalse(result.output.hasPrefix("Error"))
    }

    func testTheRealMouseWaitsWhileThePersonIsUsingIt() async throws {
        let backend = FakeMachineBackend.standard()
        clock.busy(until: Date().addingTimeInterval(0.4))
        let s = seat()
        let activities = Recorder<SeatActivity>()
        s.onActivity = { activities.append($0) }
        let started = Date()
        _ = await actions(backend, s).click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(activities.values.contains(.waitingForPerson))
        XCTAssertEqual(backend.log.first, .realMouse(.click(CGPoint(x: 1000, y: 300), button: "left", clicks: 1)))
    }

    func testThePersonBusyTooLongMeansNothingIsClicked() async {
        let backend = FakeMachineBackend.standard()
        clock.busy(until: Date().addingTimeInterval(30))
        let result = await actions(backend, seat(wait: 0.4)).click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertTrue(backend.log.isEmpty)
        XCTAssertTrue(result.output.contains("the user kept using the mouse/keyboard"), result.output)
    }

    func testStopAllWhileWaitingStopsTheAction() async throws {
        let backend = FakeMachineBackend.standard()
        let slowArbiter = ControlArbiter(settings: .init(waitTimeout: 5, idleRelease: 30, humanQuiet: 1.5), clock: clock, machineLock: nil)
        _ = await slowArbiter.acquire(ControlHolder(id: "z", chatID: "z", label: "Other"))
        let waiting = MachineSeat(chatID: "chat-b", title: "B", arbiter: slowArbiter)
        let waitingActions = actions(backend, waiting)
        let task = Task { await waitingActions.click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false) }
        try await waitUntil { await slowArbiter.snapshot().waiting.count == 1 }
        await slowArbiter.stopAll()
        let result = await task.value
        XCTAssertTrue(result.output.hasPrefix("Error: stopped"), result.output)
        XCTAssertTrue(backend.log.isEmpty)
    }

    // MARK: Scope

    func testALimitedChatAsksBeforeAnotherAppAndRemembersTheAnswer() async {
        let backend = FakeMachineBackend.standard()
        let s = seat()
        s.setRestricted(true)
        let asked = Recorder<String>()
        let first = await actions(backend, s, asked: asked).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertFalse(first.output.hasPrefix("Error"), first.output)
        XCTAssertEqual(asked.values.count, 1)
        XCTAssertTrue(asked.values[0].contains("It wants to control TextEdit"), asked.values[0])
        _ = await actions(backend, s, asked: asked).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertEqual(asked.values.count, 1, "asked once per app per chat")
    }

    func testALimitedChatThatIsDeclinedDoesNothing() async {
        let backend = FakeMachineBackend.standard()
        let s = seat()
        s.setRestricted(true)
        let result = await actions(backend, s, approve: false).click(at: CGPoint(x: 20, y: 20), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertTrue(backend.log.isEmpty)
        XCTAssertTrue(result.output.contains("the user declined TextEdit"), result.output)
    }

    func testALimitedChatControlsWhatItStartedWithoutAsking() async {
        let backend = FakeMachineBackend.standard()
        backend.parents[777] = 600
        let s = seat()
        s.setRestricted(true)
        s.noteSpawned(pid: 600)   // the shell that launched Godot
        let asked = Recorder<String>()
        _ = await actions(backend, s, asked: asked).click(at: CGPoint(x: 1000, y: 300), button: "left", clicks: 1, dragTo: nil, forceReal: false)
        XCTAssertTrue(asked.values.isEmpty)
        XCTAssertEqual(backend.log.first, .realMouse(.click(CGPoint(x: 1000, y: 300), button: "left", clicks: 1)))
    }

    // MARK: Typing

    func testTypingIntoABackgroundAppInsertsAtTheCaretAndSendsKeysToThatAppOnly() async throws {
        let backend = FakeMachineBackend.standard()
        backend.front = 777                                  // the person is in Godot
        let field = backend.textField
        backend.apps[501]?.focused = field
        let combo = try KeyboardTool.resolve("cmd+s").get()
        let result = await actions(backend, seat()).type(text: " v2", combos: [combo], appName: "TextEdit", foreground: false)
        XCTAssertEqual(backend.log, [.insert(" v2", "Name"), .keys(1, 501)])
        XCTAssertEqual(backend.textField.info.value, "draft v2")
        XCTAssertTrue(result.output.contains("through Accessibility"), result.output)
        XCTAssertTrue(result.output.contains("sent 1 key combo(s) to TextEdit only"), result.output)
        XCTAssertTrue(result.output.contains("stayed behind the user's windows"), result.output)
        let holder = await arbiter.snapshot().holder
        XCTAssertNil(holder, "background typing never takes the controls")
    }

    func testTypingIntoTheAppThePersonIsInWaitsForThemToStop() async {
        let backend = FakeMachineBackend.standard()
        backend.front = 501                                  // the person is typing in TextEdit
        let field = backend.textField
        backend.apps[501]?.focused = field
        clock.busy(until: Date().addingTimeInterval(0.4))
        let s = seat()
        let activities = Recorder<SeatActivity>()
        s.onActivity = { activities.append($0) }
        let started = Date()
        _ = await actions(backend, s).type(text: "!", combos: [], appName: "TextEdit", foreground: false)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(activities.values.contains(.waitingForPerson))
        XCTAssertEqual(backend.log, [.insert("!", "Name")])
    }

    func testAnInsertTheAppIgnoresFallsBackToKeyEventsForThatApp() async {
        let backend = FakeMachineBackend.standard()
        backend.front = 777
        backend.textField.ignoresInsert = true
        let field = backend.textField
        backend.apps[501]?.focused = field
        _ = await actions(backend, seat()).type(text: "abc", combos: [], appName: "TextEdit", foreground: false)
        XCTAssertEqual(backend.log, [.insert("abc", "Name"), .text("abc", 501)])
    }

    func testTypingWithNoFocusedFieldPostsToTheProcess() async {
        let backend = FakeMachineBackend.standard()
        backend.front = 501
        let result = await actions(backend, seat()).type(text: "hello", combos: [], appName: "Godot", foreground: false)
        XCTAssertEqual(backend.log, [.text("hello", 777)])
        XCTAssertTrue(result.output.contains("foreground: true"), "says how to retry if the app ignores background keys")
    }

    func testKeysForTheAppThePersonIsInWaitForTheControls() async throws {
        let backend = FakeMachineBackend.standard()
        backend.front = 777
        let other = ControlHolder(id: "z", chatID: "z", label: "Other chat")
        let slowArbiter = ControlArbiter(settings: .init(waitTimeout: 5, idleRelease: 30, humanQuiet: 1.5), clock: clock, machineLock: nil)
        _ = await slowArbiter.acquire(other)
        let s = MachineSeat(chatID: "chat-a", title: "A", arbiter: slowArbiter)
        s.options = MachineControlOptions(waitTimeout: 0.3)
        let combo = try KeyboardTool.resolve("f5").get()
        let result = await actions(backend, s).type(text: nil, combos: [combo], appName: "Godot", foreground: false)
        XCTAssertTrue(backend.log.isEmpty, "keys into the app in front wait their turn")
        XCTAssertTrue(result.output.contains("“Other chat” is still using them"), result.output)
    }

    func testForegroundBringsTheAppForwardAndUsesTheRealKeyboard() async throws {
        let backend = FakeMachineBackend.standard()
        backend.front = 501
        let combo = try KeyboardTool.resolve("f5").get()
        let result = await actions(backend, seat()).type(text: nil, combos: [combo], appName: "Godot", foreground: true)
        XCTAssertEqual(backend.log, [.activate("Godot"), .keys(1, nil)])
        XCTAssertTrue(result.output.contains("with the real keyboard"), result.output)
    }

    func testTypingIntoATerminalOrVisionIsRefused() async {
        let backend = FakeMachineBackend.standard()
        backend.addApp(pid: 321, name: "Terminal")
        backend.blockedForTyping = [321]
        let terminal = await actions(backend, seat()).type(text: "rm -rf ~", combos: [], appName: "Terminal", foreground: false)
        XCTAssertTrue(terminal.output.hasPrefix("Error: not typing into Terminal"), terminal.output)
        backend.front = 99
        let own = await actions(backend, seat()).type(text: "yes", combos: [], appName: nil, foreground: false)
        XCTAssertTrue(own.output.hasPrefix("Error: not typing into"), own.output)
        XCTAssertTrue(backend.log.isEmpty)
    }

    func testFocusAppWaitsForTheControls() async {
        let backend = FakeMachineBackend.standard()
        let result = await actions(backend, seat()).focus(appName: "Godot")
        XCTAssertEqual(backend.log, [.activate("Godot")])
        XCTAssertTrue(result.output.hasPrefix("Focused Godot"), result.output)
        let missing = await actions(backend, seat()).focus(appName: "Nope")
        XCTAssertTrue(missing.output.hasPrefix("Error: 'Nope' is not running"))
    }

    // MARK: ui_action

    func context(_ seat: MachineSeat) -> ToolContext {
        let dir = FileManager.default.temporaryDirectory
        return ToolContext(workspace: dir, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: dir),
                           client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []), machine: seat)
    }

    func uiAction(_ backend: FakeMachineBackend, _ json: String) async -> String {
        await UIActionTool(backend: backend).execute(args: JSONString(json), in: context(seat())).output
    }

    func testUIActionPressesByTextAndRole() async {
        let backend = FakeMachineBackend.standard()
        let out = await uiAction(backend, #"{"app":"TextEdit","find":"Wrap lines","role":"checkbox"}"#)
        XCTAssertEqual(backend.log, [.axAction("AXPress", "Wrap lines")])
        XCTAssertTrue(out.hasPrefix("Pressed the checkbox \"Wrap lines\" [w0.3] in TextEdit through Accessibility"), out)
    }

    func testUIActionPicksAMenuCommand() async {
        let backend = FakeMachineBackend.standard()
        let out = await uiAction(backend, #"{"app":"TextEdit","menu":"File > Save As…"}"#)
        XCTAssertEqual(backend.log, [.axAction("AXPress", "Save As…")])
        XCTAssertFalse(out.hasPrefix("Error"), out)
    }

    func testUIActionByElementIdSetsAValue() async {
        let backend = FakeMachineBackend.standard()
        let out = await uiAction(backend, #"{"app":"TextEdit","element":"w0.1","action":"set_value","value":"Report"}"#)
        XCTAssertEqual(backend.log, [.setValue("Report", "Name")])
        XCTAssertTrue(out.contains("(6 characters.)"), out)
    }

    func testUIActionSaysWhatAnElementCanDoInstead() async {
        let backend = FakeMachineBackend.standard()
        let out = await uiAction(backend, #"{"app":"TextEdit","element":"w0.0.1","action":"increment"}"#)
        XCTAssertTrue(out.hasPrefix("Error: the button \"Share\" [w0.0.1] in TextEdit can't increment — it can: press, menu."), out)
        XCTAssertTrue(backend.log.isEmpty)
    }

    func testUIActionReportsAStaleIdAndAMissingApp() async {
        let backend = FakeMachineBackend.standard()
        let stale = await uiAction(backend, #"{"app":"TextEdit","element":"w0.9.9"}"#)
        XCTAssertTrue(stale.contains("isn't in TextEdit any more"), stale)
        let missing = await uiAction(backend, #"{"app":"Pages","find":"Save"}"#)
        XCTAssertTrue(missing.hasPrefix("Error: no running app named 'Pages'"), missing)
        let untrusted = FakeMachineBackend.standard()
        untrusted.trusted = false
        let denied = await uiAction(untrusted, #"{"app":"TextEdit","find":"Save"}"#)
        XCTAssertTrue(denied.contains("Accessibility permission isn't granted"), denied)
    }

    func testUIActionTypeInsertsAtTheCaret() async {
        let backend = FakeMachineBackend.standard()
        let out = await uiAction(backend, #"{"app":"TextEdit","find":"Name","role":"text field","action":"type","value":"!"}"#)
        XCTAssertEqual(backend.log, [.focus("Name"), .insert("!", "Name")])
        XCTAssertEqual(backend.textField.info.value, "draft!")
        XCTAssertTrue(out.hasPrefix("Typed into the text field \"Name\" [w0.1] in TextEdit through Accessibility"), out)
    }

    func testToolsRegisterUIActionAsControl() {
        XCTAssertTrue(ToolRegistry.machineTools().map(\.name).contains("ui_action"))
        XCTAssertEqual(ComputerAccess.forTool("ui_action"), .control)
    }

    // MARK: Helpers

    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @Sendable () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}
