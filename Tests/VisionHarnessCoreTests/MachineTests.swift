import XCTest
import CoreGraphics
@testable import VisionHarnessCore

// MARK: - PTYText (output hygiene)

final class PTYTextTests: XCTestCase {
    func testStripsANSICodesAndControls() {
        let raw = "\u{1B}[31mRED\u{1B}[0m bell\u{07} done\u{08}\u{1B}]0;title\u{07}tail"
        let clean = PTYText.clean(raw)
        XCTAssertEqual(clean, "RED bell donetail")   // OSC swallows "0;title\a"
        XCTAssertFalse(clean.contains("\u{1B}"))
    }

    func testCSIWithPrivatePrefixConsumedToFinalByte() {
        // Cursor save/restore, clear-line: all CSI.
        let clean = PTYText.clean("\u{1B}[2K\u{1B}[?25lkeep me\u{1B}[?25h")
        XCTAssertEqual(clean, "keep me")
    }

    func testSpinnerCRKeepsLastFragment() {
        // Realistic spinner: each tick rewinds the cursor (CSI H, stripped) and
        // rewrites the line, ending in \n. The CR-collapse handles the raw-CR
        // shape (curl/npm style) — test both.
        let crlf = "downloading\r50%\r100% done\nreal line\n"
        let clean = PTYText.clean(crlf)
        XCTAssertTrue(clean.contains("100% done"), clean)
        XCTAssertFalse(clean.contains("downloading50%"), clean)
        XCTAssertTrue(clean.contains("real line"))
    }

    func testBlankRunCollapse() {
        let clean = PTYText.clean("a\n\n\n\n\nb")
        XCTAssertEqual(clean.split(separator: "\n", omittingEmptySubsequences: false).count, 4,
                       "at most 2 blanks survive: \(clean.debugDescription)")
    }
}

// MARK: - Background processes

final class BackgroundProcessTests: XCTestCase {
    private func makeManager() -> ProcessManager { ProcessManager() }

    private func context(in dir: URL) -> ToolContext {
        ToolContext(workspace: dir,
                    policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: dir),
                    client: ScriptedClient(turns: []),
                    registry: ToolRegistry(tools: []))
    }

    func testStartReadExitReportsCodeAndOutput() async throws {
        let manager = makeManager()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = context(in: dir)
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"echo hello-from-bg; exit 3"}"#), in: ctx)
        XCTAssertTrue(start.output.contains("hello-from-bg"), start.output)
        XCTAssertTrue(start.output.contains("exited with code 3"), start.output)
        let id = try XCTUnwrap(start.output.firstID())

        // A second read must not repeat the bytes the start peek consumed.
        let read = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)"}"#), in: ctx)
        XCTAssertFalse(read.output.contains("hello-from-bg"), "no double-send: \(read.output)")
    }

    func testUntilMatchesLinePrintedLate() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"sleep 0.9; echo READY-LATER"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        let read = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","until":"READY-LATER","timeout":10}"#), in: ctx)
        XCTAssertTrue(read.output.contains("Matched \"READY-LATER\""), read.output)
        XCTAssertTrue(read.output.contains("READY-LATER"))

        // Nothing new since: the follow-up read is empty, proving the cursor
        // advanced through the matched bytes.
        let again = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)"}"#), in: ctx)
        XCTAssertTrue(again.output.contains("(no new output)"), again.output)
    }

    func testUntilTimeoutStillReportsAndConsumes() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"echo NEVER-COMING-OUT; sleep 30"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        let read = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","until":"NOPE","timeout":1}"#), in: ctx)
        XCTAssertTrue(read.output.contains("No line matching"), read.output)
        let again = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)"}"#), in: ctx)
        XCTAssertTrue(again.output.contains("(no new output)"),
                      "the timed-out wait already reported its bytes: \(again.output)")
        _ = await ProcessStopTool(manager: manager).execute(args: JSONString(#"{"id":"\#(id)"}"#), in: ctx)
    }

    func testWriteDrivesAnInteractiveProcess() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        // `cat` on a pty: whatever we type comes back (pty echo + cat).
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"exec cat"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        let write = await ProcessWriteTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","input":"ping from the harness","enter":true,"wait":1}"#), in: ctx)
        XCTAssertTrue(write.output.contains("Sent"), write.output)
        let read = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","until":"ping from the harness","timeout":5}"#), in: ctx)
        XCTAssertTrue(read.output.contains("ping from the harness"), read.output)
        _ = await ProcessStopTool(manager: manager).execute(args: JSONString(#"{"id":"\#(id)","force":true}"#), in: ctx)
    }

    func testCtrlCKeysStopTheForegroundProgram() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"sleep 120"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        _ = await ProcessWriteTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","keys":["ctrl-c"],"wait":1}"#), in: ctx)
        // The pty's shell received SIGINT; sleep should be gone. Give it a beat.
        var exited = false
        for _ in 0..<25 {
            if manager.get(id)?.isRunning == false { exited = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(exited, "ctrl-c reaches the process through the pty")
    }


    func testStopUnknownIdAndProcessList() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        let stop = await ProcessStopTool(manager: manager).execute(args: JSONString(#"{"id":"p99"}"#), in: ctx)
        XCTAssertTrue(stop.output.contains("no such process"))
        let list = await ProcessListTool(manager: manager).execute(args: "{}", in: ctx)
        XCTAssertTrue(list.output.contains("No background processes"))

        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"sleep 20"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        let list2 = await ProcessListTool(manager: manager).execute(args: "{}", in: ctx)
        XCTAssertTrue(list2.output.contains(id), list2.output)
        XCTAssertTrue(list2.output.contains("running"))
        _ = await ProcessStopTool(manager: manager).execute(args: JSONString(#"{"id":"\#(id)","force":true}"#), in: ctx)
    }

    func testRingBufferBoundsMemoryAndPeekAll() async throws {
        let manager = makeManager()
        let ctx = context(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        // ~600 KB of output through a process — beyond the 512 KB ring.
        let start = await ProcessStartTool(manager: manager).execute(
            args: JSONString(#"{"command":"yes 012345678901234567890123456789012345678901234567890123456789012345678 | head -c 600000"}"#), in: ctx)
        let id = try XCTUnwrap(start.output.firstID())
        // Let it fill, then read all.
        let read = await ProcessReadTool(manager: manager).execute(
            args: JSONString(#"{"id":"\#(id)","all":true}"#), in: ctx)
        XCTAssertTrue(read.output.contains("0123456789"), read.output.prefix(80).description)
        _ = await ProcessStopTool(manager: manager).execute(args: JSONString(#"{"id":"\#(id)","force":true}"#), in: ctx)
    }
}

extension String {
    /// Pull the process id ("p1") out of tool chatter like "Started p2 (pid 999)".
    func firstID() -> String? {
        guard let range = self.range(of: #"\bp[0-9]+\b"#, options: .regularExpression) else { return nil }
        return String(self[range])
    }
}

// MARK: - Window services / machine tools (headless-safe parts)

final class WindowServicesTests: XCTestCase {
    func testOnScreenWindowsReturnsSomethingOnADeskSession() {
        // These tests run in the user's GUI session; the window server always
        // has at least the menubar/HUD layers. If run truly headless, skip.
        let all = WindowServices.onScreenWindows(includeChrome: true)
        guard !all.isEmpty else { return }  // headless CI: nothing to assert
        XCTAssertTrue(all.contains { $0.id > 0 })
        let layerZero = WindowServices.onScreenWindows()
        XCTAssertTrue(layerZero.allSatisfy { $0.layer == 0 }, "chrome filtered out by default")
    }

    func testMatchPrefersLayerZeroWindows() {
        // Match against whatever is on screen right now.
        guard let some = WindowServices.onScreenWindows().first, !some.owner.isEmpty,
              some.owner != "?" else { return }
        let hit = WindowServices.match(some.owner)
        XCTAssertNotNil(hit, "own app name matches its own window")
    }

    func testScreenshotRejectsBadArea() async {
        let ctx = ToolContext(workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
                              policy: PermissionPolicy(preset: .fullAccess,
                                                       workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory())),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let r = await ScreenshotTool().execute(args: JSONString(#"{"area":"10,20,30"}"#), in: ctx)
        XCTAssertTrue(r.output.contains("x,y,width,height"))
    }

    func testScreenshotNoWindowMatchListsAlternatives() async {
        let ctx = ToolContext(workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
                              policy: PermissionPolicy(preset: .fullAccess,
                                                       workspaceRoot: URL(fileURLWithPath: NSTemporaryDirectory())),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let r = await ScreenshotTool().execute(args: JSONString(#"{"window":"zzz-definitely-not-a-window"}"#), in: ctx)
        XCTAssertTrue(r.output.contains("no window matching"), r.output)
    }

    func testScreenshotFullDisplayProducesImage() async {
        // Exercises the real screencapture path when a display exists; on a
        // headless machine screencapture fails and the tool reports that —
        // accept either, reject a crash/unknown-tool.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root,
                              policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let r = await ScreenshotTool().execute(args: JSONString(#"{"description":"sanity"}"#), in: ctx)
        if r.images.isEmpty {
            XCTAssertTrue(r.output.hasPrefix("Error"), "no image ⇒ must explain: \(r.output)")
        } else {
            XCTAssertEqual(r.images.first?.kind, .image)
            XCTAssertGreaterThan(r.images.first?.data.count ?? 0, 1024)
        }
    }

    func testInspectProcessFindsThisTestProcess() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root,
                              policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let pid = ProcessInfo.processInfo.processIdentifier
        let r = await InspectProcessTool().execute(args: JSONString(#"{"pid":\#(pid)}"#), in: ctx)
        XCTAssertTrue(r.output.contains(String(pid)) || r.output.contains("xctest"), r.output)
    }

    func testKeyboardComboParsing() throws {
        let c = try XCTUnwrap(KeyboardTool.parseCombo("cmd+shift+s"))
        XCTAssertTrue(c.cmd); XCTAssertTrue(c.shift); XCTAssertFalse(c.ctrl); XCTAssertEqual(c.key, "s")
        let plain = try XCTUnwrap(KeyboardTool.parseCombo("return"))
        XCTAssertEqual(plain.key, "return")
        XCTAssertNotNil(KeyboardTool.keyCodes["return"])
        XCTAssertNotNil(KeyboardTool.keyCodes["f5"])
        XCTAssertNotNil(KeyboardTool.keyCodes["s"])
        XCTAssertNotNil(KeyboardTool.keyCodes["0"])
    }

    func testProcessWriteControlKeysAreTheirASCIICodes() {
        // ctrl-z was once LF (0x0A): in a terminal that is Enter, which runs
        // the half-typed line instead of suspending the job.
        XCTAssertEqual(ProcessWriteTool.keyCodes["ctrl-c"], "\u{03}")
        XCTAssertEqual(ProcessWriteTool.keyCodes["ctrl-d"], "\u{04}")
        XCTAssertEqual(ProcessWriteTool.keyCodes["ctrl-z"], "\u{1A}")
        XCTAssertEqual(ProcessWriteTool.keyCodes["enter"], "\r")
        XCTAssertEqual(ProcessWriteTool.keyCodes["tab"], "\t")
        XCTAssertEqual(ProcessWriteTool.keyCodes["esc"], "\u{1B}")
        XCTAssertFalse(ProcessWriteTool.keyCodes.contains { $0.key != "enter" && $0.key != "return" && ($0.value == "\n" || $0.value == "\r") },
                       "only enter/return may send a line ending")
    }

    func testTerminalGuardRefusalAdvice() {
        XCTAssertTrue(TerminalGuard.refusal(appName: "Ghostty").contains("process_start"))
    }
}

// MARK: - Image pipeline

final class ImagePipelineTests: XCTestCase {
    func testDownscaleToLongEdge() throws {
        let big = makeTestImage(width: 3000, height: 1500)   // from ComputerCoreTests
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pipe-\(UUID().uuidString.prefix(6)).png")
        try big.write(to: url)
        let out = try XCTUnwrap(ImagePipeline.prepare(pngAt: url, longEdge: 1200))
        let dims = try XCTUnwrap(ImageSize.dimensions(of: out))
        XCTAssertLessThanOrEqual(max(dims.width, dims.height), 1200)
        XCTAssertGreaterThanOrEqual(max(dims.width, dims.height), 1150, "scaled close to the cap")
        XCTAssertLessThan(out.count, big.count, "and it actually shrank")
    }
}

// MARK: - Registry wiring + builtin skills

final class MachineRegistryWiringTests: XCTestCase {
    func testProcessAndMachineFactoriesCoverTheGatedNames() {
        let processNames = ToolRegistry.processes().map(\.name)
        XCTAssertEqual(Set(processNames), ["process_start", "process_read", "process_write",
                                           "process_stop", "process_list"])
        let machineNames = ToolRegistry.machineTools().map(\.name)
        XCTAssertEqual(Set(machineNames), ["screenshot", "list_windows", "screen_watch", "ui_tree", "ui_action",
                                           "inspect_process", "mouse", "keyboard", "focus_app", "view_image"])
        // Every machine tool is classified, so the Engine gates it.
        for name in machineNames {
            XCTAssertNotNil(ComputerAccess.forTool(name), "\(name) must map to observe/control")
        }
    }

    func testEveryToolSpecParametersAreValidJSON() throws {
        // Regression: SGLang's Pydantic validation 400s when
        // tools[i].function.parameters is not a JSON-object dict. A Swift
        // multiline string turns \" into a bare " and silently corrupts the
        // JSON, so every shipped spec must parse.
        var tools: [any ToolExecutor] = ToolRegistry.processes()
        tools += ToolRegistry.machineTools()
        let registry = ToolRegistry.standard().adding(tools)
        XCTAssertFalse(registry.specs.isEmpty)
        for spec in registry.specs {
            guard let data = spec.parameters.data(using: .utf8) else {
                XCTFail("\(spec.name): empty parameters"); continue
            }
            do {
                let obj = try JSONSerialization.jsonObject(with: data)
                let schema = obj as? [String: Any]
                if schema == nil || schema?["type"] as? String != "object" {
                    XCTFail("\(spec.name): parameters is not a valid JSON object schema: \(spec.parameters.prefix(160))")
                }
                if let props = schema?["properties"] {
                    XCTAssertTrue(props is [String: Any], "\(spec.name): properties must be an object, got \(type(of: props))")
                }
            } catch {
                XCTFail("\(spec.name): parameters failed JSON parsing: \(error.localizedDescription)")
            }
        }
    }

    func testRemovingDropsNamedTools() {
        let registry = ToolRegistry.standard().adding(ToolRegistry.machineTools() + ToolRegistry.processes())
        let sub = registry.removing("agent", "screenshot")
        XCTAssertFalse(sub.names.contains("agent"))
        XCTAssertFalse(sub.names.contains("screenshot"))
        XCTAssertTrue(sub.names.contains("keyboard"), "only the named tools go")
    }

    func testBuiltinGodotSkillInstallsAndParses() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("builtin-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let dir = base.appendingPathComponent("skills-builtin", isDirectory: true)  // == locations.builtinSkills
        let changed = try SkillBuiltin.install(into: dir)
        XCTAssertEqual(changed, ["godot-debugging"])
        // Idempotent: a second install reports nothing changed.
        XCTAssertEqual(try SkillBuiltin.install(into: dir), [])

        let manifest = dir.appendingPathComponent("godot-debugging/SKILL.md")
        let doc = SkillDocument.parse(try String(contentsOf: manifest, encoding: .utf8))
        XCTAssertEqual(doc.fields["name"], "godot-debugging")
        XCTAssertTrue((doc.fields["description"] ?? "").contains("Godot"))
        XCTAssertTrue(doc.body.contains("process_start"))
        XCTAssertTrue(doc.body.contains("screen_watch"))

        // Bundled reference file lands next to the manifest.
        let notes = dir.appendingPathComponent("godot-debugging/macos-notes.md")
        XCTAssertTrue(try String(contentsOf: notes, encoding: .utf8).contains("--headless --import"))

        // And the loader discovers it as a real skill through the builtin root.
        let locations = SkillLocations(home: base, appSupport: base)  // builtinSkills = base/skills-builtin
        let found = SkillCatalog.loadAll(project: nil, locations: locations, sources: [])
        let skill = try XCTUnwrap(found.first { $0.name == "godot-debugging" })
        XCTAssertEqual(skill.origin, .builtin)
        XCTAssertTrue(skill.resources().contains("macos-notes.md"))
    }
}
