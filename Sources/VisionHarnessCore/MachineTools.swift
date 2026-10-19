import Foundation
import CoreGraphics

// MARK: - Machine tools (see and steer what's on screen)
//
// The debugging loop a human uses for a GUI app — run it, look at the window,
// read the error, screenshot the wrong-looking pixel — needs the same tools
// here. Screenshots and window enumeration go through CoreGraphics
// (`CGWindowListCopyWindowInfo`, `screencapture -l<id>`), clicking and typing
// through synthesized `CGEvent`s, so there is no dependency on cliclick or a
// JavaScript bridge. Accessibility permission (granted to Vision once, in System
// Settings) gates event posting; Screen Recording gates capture — both show
// the standard macOS prompts, and failures here say which one to fix.
//
// Images come back through ToolResult.images, so the engine ships them to the
// model on an attached user message (and prunes old ones so a long debug
// session doesn't burn the window on stale frames). When the selected model
// has no vision, the engine already swaps in a "use the text tools" note.
//
// Every tool here maps to ComputerAccess.observe/.control (see Permissions),
// so the first use in a chat asks once per chat and plan mode can't drive.

// MARK: - Window services (CoreGraphics, no AppleScript needed)

/// One on-screen window, from the window server. Layer 0 is ordinary app
/// windows; menubar/HUD/overlay chrome sits above it.
public struct WindowInfo: Sendable {
    public let id: UInt32
    public let owner: String
    public let title: String
    public let bounds: (x: Int, y: Int, w: Int, h: Int)
    public let layer: Int
}

public enum WindowServices {
    /// All on-screen windows, topmost first. Cheap (~ms) and needs no special
    /// permission — window *names* only require Screen Recording on some macOS
    /// versions, which is why titles may show as "?" until that is granted.
    public static func onScreenWindows(includeChrome: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [WindowInfo] = []
        for entry in list {
            guard let number = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let title = entry[kCGWindowName as String] as? String ?? ""
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            if !includeChrome && layer != 0 { continue }
            var bounds = (x: 0, y: 0, w: 0, h: 0)
            if let dict = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                bounds = (Int(dict["X"] ?? 0), Int(dict["Y"] ?? 0), Int(dict["Width"] ?? 0), Int(dict["Height"] ?? 0))
            }
            out.append(WindowInfo(id: number, owner: owner, title: title, bounds: bounds, layer: layer))
        }
        return out
    }

    /// First window whose owner or title contains `needle` (case-insensitive),
    /// preferring ordinary windows over chrome.
    public static func match(_ needle: String) -> WindowInfo? {
        let lowered = needle.lowercased()
        let windows = onScreenWindows(includeChrome: true)
        return windows.first {
            $0.owner.lowercased().contains(lowered) || $0.title.lowercased().contains(lowered)
        }
    }
}

// MARK: - Image helpers

/// Cap what travels to the model: a 6K-px Retina window screenshot is ~1.5 MB
/// and thousands of vision tokens; 1600 px long-edge PNGs read fine and stay
/// near 200-400 KB. `sips` is the no-dependency downscaler.
enum ImagePipeline {
    static func prepare(pngAt file: URL, longEdge: Int) -> Data? {
        let scaled = file.deletingPathExtension().appendingPathExtension("s.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        task.arguments = ["-Z", "\(longEdge)", file.path, "--out", scaled.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        var chosen: Data?
        if task.terminationStatus == 0 { chosen = try? Data(contentsOf: scaled) }
        if chosen == nil { chosen = try? Data(contentsOf: file) }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: scaled)
        guard let chosen, chosen.count > 32 else { return nil }
        return chosen
    }
}

private func tempPNG(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("vision-\(tag)-\(UUID().uuidString.prefix(8)).png")
}

/// Run a short helper binary (screencapture/osascript) capturing stdout.
func runBinary(_ path: String, _ args: [String], timeout: TimeInterval) async
    -> (out: Data, err: Data, status: Int32) {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe(), errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            do { try task.run() } catch {
                continuation.resume(returning: (Data(), Data("\(error.localizedDescription)".data(using: .utf8) ?? Data()), -1))
                return
            }
            // Read to EOF on a deadline so a hung helper can't wedge the loop.
            let deadline = Date().addingTimeInterval(timeout)
            var outData = Data(), errData = Data()
            while task.isRunning || Date() < deadline {
                outData.append(outPipe.fileHandleForReading.availableData)
                errData.append(errPipe.fileHandleForReading.availableData)
                if !task.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning {
                task.terminate()
                // Drain whatever remains after the kill signal lands.
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            task.waitUntilExit()
            continuation.resume(returning: (outData, errData, task.terminationStatus))
        }
    }
}

// MARK: - screenshot

public struct ScreenshotTool: ToolExecutor {
    public static let name = "screenshot"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Capture the screen (or one window, or one area) as a PNG and show it to \
            the model. `window` matches an app or window-title substring (e.g. "Godot") \
            — the usual way to watch a running game; `area` is x,y,w,h in points. \
            Big captures are downscaled to keep vision tokens sane. Pair with \
            process_start to debug GUI apps: start it, screenshot it, read its output, \
            fix, repeat.
            """,
        parameters: """
        {"type":"object","properties":{"window":{"type":"string","description":"Capture the window whose app or title contains this text"},"area":{"type":"string","description":"Region as x,y,width,height (points)"},"description":{"type":"string","description":"What you are looking for in the shot"}},"required":[]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        var captureArgs = ["-x", "-o", "-t", "png"]
        var what = "main display"
        if let window = Self.string(args, "window"), !window.isEmpty {
            guard let hit = WindowServices.match(window) else {
                let titles = WindowServices.onScreenWindows().prefix(12)
                    .map { "\($0.owner) — \($0.title.isEmpty ? "(untitled)" : $0.title)" }
                return .init(output: "Error: no window matching \"\(window)\". On screen now:\n"
                    + titles.joined(separator: "\n")
                    + "\n(list_windows shows everything; process_list shows what you started).")
            }
            what = "\(hit.owner) — \(hit.title.isEmpty ? "(window \(hit.id))" : hit.title)"
            captureArgs += ["-l", "\(hit.id)"]
        } else if let area = Self.string(args, "area"), !area.isEmpty {
            let clean = area.replacingOccurrences(of: " ", with: "")
            guard clean.split(separator: ",").count == 4 else {
                return .init(output: "Error: area must be x,y,width,height (e.g. \"100,200,800,600\").")
            }
            what = "region \(clean)"
            captureArgs += ["-R", clean]
        }
        let file = tempPNG("shot")
        captureArgs.append(file.path)
        let result = await runBinary("/usr/sbin/screencapture", captureArgs, timeout: 20)
        guard result.status == 0,
              let data = ImagePipeline.prepare(pngAt: file, longEdge: 1600) else {
            try? FileManager.default.removeItem(at: file)
            let why = String(decoding: result.err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = result.status == 0 ? "capture produced no image" : "screencapture exit \(result.status): \(why.prefix(200))"
            return .init(output: "Error: \(reason).\nIf nothing was captured: System Settings → Privacy & Security → Screen Recording — enable Vision, then relaunch it.")
        }
        let note = Self.string(args, "description")
        return .init(output: "Captured \(what) (\(data.count / 1024) KB)\(note.map { " — looking for: \($0)" } ?? ""). It is shown below; describe what you see before deciding the next step.",
                     images: [MessageAttachment(kind: .image, name: "screenshot-\(what.prefix(30).replacingOccurrences(of: " ", with: "-")).png", data: data)])
    }
}

// MARK: - list_windows

public struct ListWindowsTool: ToolExecutor {
    public static let name = "list_windows"
    public static let spec = ToolSpec(
        name: name,
        description: "List on-screen windows: id, app — title, size. Target of screenshot/window= and the cheap way to see what is open (no screenshot tokens spent).",
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Only windows of this app (substring)"}}}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let needle = Self.string(args, "app")
        var windows = WindowServices.onScreenWindows()
        if let needle, !needle.isEmpty {
            let lowered = needle.lowercased()
            windows = windows.filter { $0.owner.lowercased().contains(lowered) || $0.title.lowercased().contains(lowered) }
        }
        guard !windows.isEmpty else {
            return .init(output: needle.map { "No window matching \"\($0)\" is on screen." } ?? "No visible windows.")
        }
        let lines = windows.prefix(40).map { w in
            "• \(w.id)  \(w.owner) — \(w.title.isEmpty ? "(untitled)" : w.title)  [\(w.bounds.w)×\(w.bounds.h) at \(w.bounds.x),\(w.bounds.y)]"
        }
        return .init(output: "Windows (topmost first):\n" + lines.joined(separator: "\n")
            + (windows.count > 40 ? "\n… \(windows.count - 40) more" : ""))
    }
}

// MARK: - screen_watch

public struct ScreenWatchTool: ToolExecutor {
    public static let name = "screen_watch"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Watch a window: capture it every `interval` seconds for up to `duration`, \
            and return only the frames that actually changed — a freeze check for a \
            hung game ("every frame identical" = wedged), or watching an animation \
            settle. Cheaper than repeated screenshots when most frames are identical.
            """,
        parameters: """
        {"type":"object","properties":{"window":{"type":"string","description":"Window/app title substring"},"interval":{"type":"number","description":"Seconds between captures (default 1.5, min 0.5)"},"duration":{"type":"number","description":"Total seconds to watch (default 8, max 30)"}},"required":["window"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let needle = Self.string(args, "window"), !needle.isEmpty,
              let hit = WindowServices.match(needle) else {
            return .init(output: "Error: no window matching \"\(Self.string(args, "window") ?? "?")\" right now.")
        }
        let interval = min(10, max(0.5, Self.double(args, "interval", default: 1.5)))
        let duration = min(30, max(interval, Self.double(args, "duration", default: 8)))
        let shots = max(2, Int(duration / interval))

        var previous: Data?
        var changed: [MessageAttachment] = []
        var identical = 0
        for index in 0..<shots {
            let file = tempPNG("watch")
            let result = await runBinary("/usr/sbin/screencapture",
                                        ["-x", "-o", "-t", "png", "-l", "\(hit.id)", file.path],
                                        timeout: 10)
            let data = result.status == 0 ? ImagePipeline.prepare(pngAt: file, longEdge: 1280) : nil
            guard let data else {
                try? FileManager.default.removeItem(at: file)
                return .init(output: "Error: capture failed at frame \(index) for \"\(hit.owner)\" (closed? grant Screen Recording to Vision).")
            }
            if let previous, data == previous {
                identical += 1
            } else {
                changed.append(MessageAttachment(kind: .image, name: "frame-\(index).png", data: data))
            }
            previous = data
            if index < shots - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        if changed.count <= 1 {
            return .init(output: "Watched \"\(hit.owner) — \(hit.title)\" for \(Int(duration))s: \(shots) frames, essentially no pixel change — the window is not redrawing (hung, or idle by design). Its process is up if process_list/inspect_process says so; that points at the game loop, not the window.")
        }
        // First frame (context) + the most recent changes, capped so tokens stay sane.
        var picked: [MessageAttachment] = []
        if let first = changed.first { picked.append(first) }
        picked.append(contentsOf: changed.suffix(4))
        return .init(output: "Watched \"\(hit.owner) — \(hit.title)\" for \(Int(duration))s: \(changed.count) of \(shots) frames changed (\(identical) identical). Showing \(picked.count) (first + latest).")
            .withImages(picked)
    }
}

extension ToolResult {
    fileprivate func withImages(_ images: [MessageAttachment]) -> ToolResult {
        var copy = self
        copy.images = images
        return copy
    }
}

// MARK: - ui_tree

public struct UITreeTool: ToolExecutor {
    public static let name = "ui_tree"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Dump an app's accessibility tree (buttons, fields, menus, values, positions) \
            by app name — the cheap text alternative to screenshots for NATIVE apps, and \
            the map for ui_action: every row starts with an element id like [w0.3.1] that \
            ui_action acts on WITHOUT moving the user's mouse. include_menus adds the \
            menu bar. Game engines (Godot) draw their own pixels, so their tree is \
            near-empty: use screenshot for the viewport.
            """,
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Application/process name (e.g. 'TextEdit', 'Finder')"},"max_depth":{"type":"integer","description":"How deep to walk (default 4, max 10)"},"include_menus":{"type":"boolean","description":"Also list the menu bar (default false)"},"find":{"type":"string","description":"Only rows whose title/description/value contains this text"}},"required":["app"]}
        """
    )

    public let backend: any MachineBackend
    public init(backend: any MachineBackend = LiveMachineBackend()) { self.backend = backend }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let app = Self.string(args, "app"), !app.isEmpty else {
            return .init(output: "Error: app is required.")
        }
        let depth = min(10, max(1, Self.int(args, "max_depth", default: 4)))
        let includeMenus = JSONArgs.dictionary(args)["include_menus"] as? Bool ?? false
        guard backend.accessibilityTrusted else {
            return await Self.appleScriptTree(app: app, depth: min(6, depth))
        }
        guard let target = backend.app(named: app) else {
            return .init(output: "Error: no running app named '\(app)'. Check the name (list_windows / process_list / inspect_process).")
        }
        let walked = UIElementTree.walk(app: target.pid, backend: backend, maxDepth: depth, maxRows: 600,
                                        includeMenus: includeMenus)
        var rows = walked.rows
        if let needle = Self.string(args, "find")?.lowercased(), !needle.isEmpty {
            rows = rows.filter { row in
                [row.info.title, row.info.label, row.info.value, row.info.identifier, row.info.help]
                    .compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
            }
        }
        guard !rows.isEmpty else {
            if backend.windows(app: target.pid).isEmpty && !includeMenus {
                return .init(output: "'\(target.name)' has no windows to inspect (include_menus: true lists its menu bar).")
            }
            return .init(output: "'\(target.name)' exposes no UI elements\(Self.string(args, "find") != nil ? " matching that text" : "") — if it is a game engine or a canvas it draws its own pixels; use screenshot instead.")
        }
        var text = rows.map { String(repeating: "  ", count: $0.depth) + "[\($0.id)] " + $0.info.line() }
            .joined(separator: "\n")
        if text.count > 14_000 { text = String(text.prefix(14_000)) + "\n… [truncated at 14k chars — narrow with find or max_depth]" }
        else if walked.truncated { text += "\n… [more elements — narrow with find or max_depth]" }
        return .init(output: "Accessibility tree of \(target.name) (pid \(target.pid), depth \(depth)):\n\(text)\n\nAct on an element without the mouse: ui_action(app:\"\(target.name)\", element:\"<id>\", action:\"press\") — or find:\"<its title>\".")
    }

    /// The tree through System Events, when Accessibility isn't granted to this app (it may be to osascript).
    static func appleScriptTree(app: String, depth: Int) async -> ToolResult {
        let escaped = app.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        // One osascript call walks the front window. Two AppleScript rules
        // learned the hard way: System Events terminology only parses inside a
        // `tell` block (so even the handlers wrap their access in one), and
        // there is no \" string escape (quotes are built with character id 34).
        let script = """
        on walk(elems, level, maxLevel)
            set out to ""
            set pad to ""
            repeat level times
                set pad to pad & "  "
            end repeat
            repeat with e in elems
                set out to out & my describe(e, pad) & linefeed
                if level < maxLevel then
                    set kids to my childrenOf(e)
                    if kids is not {} then set out to out & my walk(kids, level + 1, maxLevel)
                end if
            end repeat
            return out
        end walk

        on childrenOf(e)
            tell application "System Events"
                try
                    return UI elements of e
                on error
                    return {}
                end try
            end tell
        end childrenOf

        on describe(e, pad)
            tell application "System Events"
                set Q to character id 34
                set s to pad
                try
                    set s to s & (role of e as text)
                end try
                try
                    set d to description of e
                    if d is not missing value then
                        set d to d as text
                        if d is not "" then set s to s & " " & Q & d & Q
                    end if
                end try
                try
                    set v to value of e
                    if v is not missing value then
                        set v to v as text
                        if (count of v) > 80 then set v to (text 1 thru 80 of v) & "…"
                        if v is not "" then set s to s & " = " & v
                    end if
                end try
                try
                    set pp to position of e
                    set ss to size of e
                    set s to s & " [" & (item 1 of pp) & "," & (item 2 of pp) & " " & (item 1 of ss) & "x" & (item 2 of ss) & "]"
                end try
                return s
            end tell
        end describe

        tell application "System Events"
            if not (exists process "\(escaped)") then return "ERROR_NO_PROCESS"
            tell process "\(escaped)"
                if (count of windows) is 0 then return "ERROR_NO_WINDOWS"
                set elems to UI elements of front window
            end tell
            return my walk(elems, 0, \(depth))
        end tell
        """
        let result = await runBinary("/usr/bin/osascript", ["-e", script], timeout: 25)
        let out = String(decoding: result.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: result.err, as: UTF8.self)
        if result.status != 0 || out.hasPrefix("ERROR_") {
            switch out {
            case "ERROR_NO_PROCESS":
                return .init(output: "Error: no running process named '\(app)'. Check the name (list_windows / process_list / inspect_process).")
            case "ERROR_NO_WINDOWS":
                return .init(output: "Error: '\(app)' is running but has no windows to inspect.")
            default:
                return .init(output: "Error: could not read the accessibility tree of '\(app)': \(errText.prefix(200)). Grant Accessibility permission: System Settings → Privacy & Security → Accessibility → \(AppIdentity.name).")
            }
        }
        guard !out.isEmpty else {
            return .init(output: "'\(app)' exposes no UI elements — it almost certainly draws its own pixels (a game engine window). Use screenshot instead.")
        }
        let capped = out.count > 12_000 ? String(out.prefix(12_000)) + "\n… [truncated at 12k chars]" : out
        return .init(output: "Accessibility tree of '\(app)' (front window, depth \(depth); read through System Events because Accessibility isn't granted to \(AppIdentity.name) — without it ui_action can't act on these elements):\n\(capped)")
    }
}

// MARK: - ui_action

public struct UIActionTool: ToolExecutor {
    public static let name = "ui_action"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Act on a control in an app WITHOUT taking the user's mouse or keyboard \
            (Accessibility): press a button, tick a checkbox, pick a menu item, fill a \
            text field, focus or raise a window — the app can stay behind other windows \
            and several chats can do this at once. Find the element with `element` (an \
            id from ui_tree, e.g. "w0.3.1"), or `find` (its title/description/value) plus \
            optional `role` ("button", "text field", "checkbox", "menu item"…), or `menu` \
            ("File > Save As…") for a menu command. Actions: press (default), confirm, \
            focus, raise, show_menu, set_value (replace a field's text with `value`), type \
            (insert `value` at the caret), increment, decrement, open, cancel, pick. Prefer \
            this over mouse/keyboard whenever the app is native.
            """,
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"The app's name (e.g. 'TextEdit')"},"element":{"type":"string","description":"An element id from ui_tree, e.g. 'w0.3.1'"},"find":{"type":"string","description":"Text the element shows: its title, description or value"},"role":{"type":"string","description":"Narrow find to a kind: button, text field, checkbox, menu item, link, popup button…"},"menu":{"type":"string","description":"A menu command path, e.g. 'File > Save As…'"},"action":{"type":"string","enum":["press","confirm","focus","raise","show_menu","set_value","type","increment","decrement","open","cancel","pick"],"description":"Default press"},"value":{"type":"string","description":"Text for set_value / type"}},"required":["app"]}
        """
    )

    public let backend: any MachineBackend
    public init(backend: any MachineBackend = LiveMachineBackend()) { self.backend = backend }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let appName = Self.string(args, "app"), !appName.isEmpty else {
            return .init(output: "Error: app is required.")
        }
        let rawAction = (Self.string(args, "action") ?? "press").lowercased().replacingOccurrences(of: " ", with: "_")
        guard let verb = ActionVerb(rawValue: rawAction == "menu" ? "show_menu" : rawAction) else {
            return .init(output: "Error: unknown action '\(rawAction)'. Use press, confirm, focus, raise, show_menu, set_value, type, increment, decrement, open, cancel or pick.")
        }
        guard backend.accessibilityTrusted else {
            return .init(output: "Error: Accessibility permission isn't granted to \(AppIdentity.name), so it can't act on controls directly. Ask the user to allow it in System Settings → Privacy & Security → Accessibility, or use mouse/keyboard (they wait their turn for the real mouse).")
        }
        guard let target = backend.app(named: appName) else {
            return .init(output: "Error: no running app named '\(appName)'. list_windows shows what is open.")
        }
        let seat = context.machine ?? .detached()
        let actions = MachineActions(backend: backend, seat: seat, ask: context.requestPermission)
        let typing = verb == .setValue || verb == .typeText
        if let refusal = await actions.admit(target, typing: typing, tool: Self.name) { return .init(output: refusal) }
        let value = Self.string(args, "value")
        if typing, value == nil { return .init(output: "Error: \(verb.rawValue) needs `value` (the text).") }

        // Find the element.
        var located: (handle: UIElementHandle, id: String)?
        var alsoMatched: [String] = []
        if let menu = Self.string(args, "menu"), !menu.isEmpty {
            switch UIElementTree.menuItem(menu, app: target.pid, backend: backend) {
            case .success(let handle): located = (handle, "menu \"\(menu)\"")
            case .failure(let error): return .init(output: "Error: in \(target.name), \(error.message)")
            }
        } else if let id = Self.string(args, "element"), !id.isEmpty {
            guard let path = UIElementTree.Path(id) else {
                return .init(output: "Error: '\(id)' is not an element id — ids look like w0.3.1 (from ui_tree).")
            }
            guard let handle = UIElementTree.resolve(path, app: target.pid, backend: backend) else {
                return .init(output: "Error: element \(id) isn't in \(target.name) any more (the window changed). Run ui_tree again.")
            }
            located = (handle, path.id)
        } else if Self.string(args, "find") != nil || Self.string(args, "role") != nil {
            let walked = UIElementTree.walk(app: target.pid, backend: backend, maxDepth: 12, maxRows: 3000, includeMenus: false)
            let hits = UIElementTree.find(Self.string(args, "find"), role: Self.string(args, "role"),
                                          action: verb.rawValue, in: walked.rows)
            guard let best = hits.first else {
                return .init(output: "Error: nothing in \(target.name)'s windows matches\(Self.string(args, "find").map { " \"\($0)\"" } ?? "")\(Self.string(args, "role").map { " (role \($0))" } ?? ""). ui_tree shows what is there; for a menu command use menu: \"File > …\".")
            }
            guard let handle = UIElementTree.Path(best.id).flatMap({ UIElementTree.resolve($0, app: target.pid, backend: backend) }) else {
                return .init(output: "Error: the element moved while looking for it. Try again.")
            }
            located = (handle, best.id)
            alsoMatched = hits.dropFirst().prefix(3).map { "[\($0.id)] \($0.info.line(includeFrame: false))" }
        } else if verb == .raise || verb == .focus {
            guard let window = backend.windows(app: target.pid).first else {
                return .init(output: "Error: \(target.name) has no window to \(verb.rawValue).")
            }
            located = (window, "w0")
        } else {
            return .init(output: "Error: say which element: element (an id from ui_tree), find (its text, with an optional role) or menu (\"File > Save\").")
        }
        guard let (handle, id) = located else { return .init(output: "Error: no element.") }
        let info = backend.info(handle)
        if info.pid == backend.ownPID {
            return .init(output: "Error: not acting on \(AppIdentity.name) itself — its windows hold the user's approvals and composer.")
        }

        seat.setActivity(.background(app: target.name))
        defer { seat.setActivity(.idle) }
        let failure: String?
        switch verb {
        case .focus:
            failure = info.role == "AXWindow" ? backend.perform("AXRaise", on: handle) : backend.setFocused(handle)
        case .setValue:
            failure = backend.setValue(value ?? "", on: handle)
        case .typeText:
            if !info.focused { _ = backend.setFocused(handle) }
            let before = backend.textState(of: handle)
            let inserted = backend.insertText(value ?? "", into: handle)
            if inserted == nil, MachineActions.insertionDidNothing(before: before, after: backend.textState(of: handle), inserted: value ?? "") {
                failure = "the app ignored the text (use set_value to replace the whole field, or keyboard to type it)"
            } else {
                failure = inserted
            }
        case .raise:
            // Raise the element's window (an element inside a window raises the window).
            var window: UIElementHandle? = handle
            var hops = 0
            while let current = window, backend.info(current).role != "AXWindow", hops < 40 {
                window = backend.parent(current)
                hops += 1
            }
            failure = backend.perform("AXRaise", on: window ?? handle)
        default:
            if let action = verb.axAction, !info.actions.contains(action), !info.actions.isEmpty || verb != .press {
                let offered = info.actions.compactMap(ElementInfo.verb)
                return .init(output: "Error: \(ControlPlanner.describe(info)) [\(id)] in \(target.name) can't \(verb.rawValue)" + (offered.isEmpty ? "." : " — it can: " + offered.joined(separator: ", ") + "."))
            }
            failure = backend.perform(verb.axAction ?? "AXPress", on: handle)
        }
        if let failure {
            return .init(output: "Error: couldn't \(verb.rawValue) \(ControlPlanner.describe(info)) [\(id)] in \(target.name): \(failure).")
        }
        var out = "\(MachineActions.pastTense(verb)) \(ControlPlanner.describe(info)) [\(id)] in \(target.name) through Accessibility — \(MachineActions.mouseFreeNote)."
        if verb == .setValue || verb == .typeText { out += " (\(value?.count ?? 0) characters.)" }
        if !alsoMatched.isEmpty { out += "\nAlso matched (use element: to pick one): " + alsoMatched.joined(separator: "; ") }
        return .init(output: out + " Screenshot or ui_tree to check the result.")
    }
}

// MARK: - inspect_process

public struct InspectProcessTool: ToolExecutor {
    public static let name = "inspect_process"
    public static let spec = ToolSpec(
        name: name,
        description: """
            System-level process inspection via ps/lsof: pid, CPU, memory, elapsed, \
            command — filter by name substring or inspect one pid (adds open files/ \
            sockets). Was Godot really started? Is it pegging CPU (render loop) or at \
            0% (wedged)? For processes YOU started with process_start, prefer \
            process_read — this one sees everything, including what the user launched.
            """,
        parameters: """
        {"type":"object","properties":{"match":{"type":"string","description":"Substring to match against the command (e.g. 'Godot')"},"pid":{"type":"integer","description":"Inspect one pid instead (adds lsof summary)"}},"required":[]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let pid = Self.int(args, "pid", default: 0)
        if pid > 0 {
            let out = await PTY.runCommand(
                "ps -p \(pid) -o pid,%cpu,%mem,etime,state,comm; echo '--- files ---'; lsof -p \(pid) 2>/dev/null | awk '$4 ~ /^[0-9]+[ru]?$/ || $5 == \"IPv4\" || $5 == \"IPv6\" {print $4, $5, $8, $9}' | head -25",
                cwd: context.policy.workspaceRoot, timeout: 15)
            let text = String(decoding: out.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(output: text.isEmpty ? "No process with pid \(pid)." : text)
        }
        guard let match = Self.string(args, "match"), !match.isEmpty else {
            return .init(output: "Error: give a match string or a pid.")
        }
        let safe = match.replacingOccurrences(of: "'", with: "'\\''")
        let out = await PTY.runCommand(
            "ps axo pid,%cpu,%mem,etime,state,command | grep -i '\(safe)' | grep -v grep | head -20",
            cwd: context.policy.workspaceRoot, timeout: 15)
        let text = String(decoding: out.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(output: text.isEmpty ? "No process command-line matching \"\(match)\"." : text)
    }
}

// MARK: - mouse / keyboard / focus_app (control: background first, the real mouse in turn)

public struct MouseTool: ToolExecutor {
    public static let name = "mouse"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Click at screen coordinates (points, top-left origin): button=left/right/ \
            middle, clicks=1 or 2 (double), or drag with to_x/to_y. When the thing \
            under the point is a native control (a button, checkbox, link, text field), \
            the click is done through Accessibility and the user's pointer never moves; \
            otherwise (a canvas, a game, a drag) it waits its turn for the real mouse — \
            one chat at a time — and puts the user's pointer back. real_mouse: true \
            forces the real pointer. Coordinates come from screenshot/list_windows/ \
            ui_tree. Prefer ui_action for native controls. Screenshot to verify.
            """,
        parameters: """
        {"type":"object","properties":{"x":{"type":"integer","description":"Screen x (points)"},"y":{"type":"integer","description":"Screen y (points)"},"button":{"type":"string","enum":["left","right","middle"],"description":"Default left"},"clicks":{"type":"integer","description":"1 default, 2 for double-click"},"to_x":{"type":"integer","description":"Drag release x"},"to_y":{"type":"integer","description":"Drag release y"},"real_mouse":{"type":"boolean","description":"Use the real pointer even when the control could be pressed directly (default false)"}},"required":["x","y"]}
        """
    )

    public let backend: any MachineBackend
    public init(backend: any MachineBackend = LiveMachineBackend()) { self.backend = backend }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let x = Self.double(args, "x", default: -1), y = Self.double(args, "y", default: -1)
        guard x >= 0, y >= 0 else { return .init(output: "Error: x and y are required (points from screenshot/list_windows).") }
        let button = (Self.string(args, "button") ?? "left").lowercased()
        guard ["left", "right", "middle"].contains(button) else {
            return .init(output: "Error: button must be left, right or middle.")
        }
        let clicks = max(1, min(2, Self.int(args, "clicks", default: 1)))
        let toX = Self.double(args, "to_x", default: -1), toY = Self.double(args, "to_y", default: -1)
        let dragTo: CGPoint? = toX >= 0 && toY >= 0 ? CGPoint(x: toX, y: toY) : nil
        let forceReal = JSONArgs.dictionary(args)["real_mouse"] as? Bool ?? false
        let actions = MachineActions(backend: backend, seat: context.machine ?? .detached(), ask: context.requestPermission)
        return await actions.click(at: CGPoint(x: x, y: y), button: button, clicks: clicks, dragTo: dragTo, forceReal: forceReal)
    }
}

public struct KeyboardTool: ToolExecutor {
    public static let name = "keyboard"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Type and press keys in an app: text=literal string, and/or keys like \
            ["cmd+s"] ["return"] ["ctrl+c"] ["esc"] ["up","down"] ["cmd+shift+t"] \
            ["cmd+,"] with modifiers cmd/ctrl/alt/shift joined by + (a comma works \
            too). Keys are a–z, 0–9, punctuation, enter/tab/esc/space/delete, arrows, \
            home/end/pgup/pgdn, f1–f20. With `app`, the text and keys go to that app \
            IN THE BACKGROUND — it stays behind the user's windows and the user's \
            keyboard is not used (text goes into its focused field). Without `app`, \
            they go to the app in front. foreground: true brings the app forward and \
            uses the real keyboard (it waits its turn — one chat at a time) for apps \
            that only take keys in front. Refused into terminal emulators and Vision \
            itself — that route would bypass the shell permission gate.
            """,
        parameters: """
        {"type":"object","properties":{"text":{"type":"string","description":"Literal text to type"},"keys":{"type":"array","items":{"type":"string"},"description":"Key combos, e.g. ['cmd+s','return']"},"app":{"type":"string","description":"The app to type into (name); default the app in front"},"foreground":{"type":"boolean","description":"Bring the app forward and use the real keyboard (default false)"}},"required":[]}
        """
    )

    public let backend: any MachineBackend
    public init(backend: any MachineBackend = LiveMachineBackend()) { self.backend = backend }

    /// Ask System Events for the frontmost GUI process: (name, pid). A plain
    /// osascript call keeps VisionHarnessCore AppKit-free; costs ~50 ms.
    static func frontmostProcess() async -> (name: String, pid: pid_t)? {
        let result = await runBinary("/usr/bin/osascript", [
            "-e", "tell application \"System Events\" to get name of first process whose frontmost is true",
            "-e", "tell application \"System Events\" to get unix id of first process whose frontmost is true",
        ], timeout: 10)
        guard result.status == 0 else { return nil }
        let lines = String(decoding: result.out, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (lines[0].trimmingCharacters(in: .whitespaces), pid)
    }

    /// Why typing into the frontmost process is refused, or nil to go ahead.
    /// An unidentified front app is refused too: blind keys could land in a
    /// terminal or in this harness.
    static func guardRefusal(front: (name: String, pid: pid_t)?, requested: String?,
                             isBlocked: (pid_t) -> Bool = { TerminalGuard.isBlocked(pid: $0) }) -> String? {
        guard let front else { return TerminalGuard.unknownFrontmostRefusal() }
        guard isBlocked(front.pid) else { return nil }
        return TerminalGuard.refusal(appName: requested ?? front.name)
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        // Resolve every combo before anything is typed: a bad one fails the
        // whole call instead of leaving the keys before it pressed.
        var combos: [ResolvedCombo] = []
        if let raw = JSONArgs.dictionary(args)["keys"] as? [Any] {
            for case let combo as String in raw {
                switch Self.resolve(combo) {
                case .success(let resolved): combos.append(resolved)
                case .failure(let error): return .init(output: "Error: \(error.message)")
                }
            }
        }
        let foreground = JSONArgs.dictionary(args)["foreground"] as? Bool ?? false
        let actions = MachineActions(backend: backend, seat: context.machine ?? .detached(), ask: context.requestPermission)
        return await actions.type(text: Self.string(args, "text"), combos: combos, appName: Self.string(args, "app"),
                                  foreground: foreground)
    }

    // MARK: key mapping

    /// Virtual key codes: the `kVK_*` constants from Carbon's
    /// HIToolbox/Events.h. They name physical key positions on a US ANSI
    /// keyboard (an app reads ⌘ shortcuts through the active layout). Written
    /// as literals so VisionHarnessCore does not link Carbon; `KeyboardKeyCodeTests`
    /// checks every entry against the real constants.
    static let keyCodes: [String: CGKeyCode] = [
        // Letters: kVK_ANSI_A … kVK_ANSI_Z.
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
        "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
        "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E,
        // Digits: kVK_ANSI_0 … kVK_ANSI_9.
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        // Punctuation keys, by character and by name.
        "=": 0x18, "equal": 0x18, "equals": 0x18,                // kVK_ANSI_Equal
        "-": 0x1B, "minus": 0x1B,                                // kVK_ANSI_Minus
        "]": 0x1E, "rightbracket": 0x1E,                         // kVK_ANSI_RightBracket
        "[": 0x21, "leftbracket": 0x21,                          // kVK_ANSI_LeftBracket
        "'": 0x27, "quote": 0x27,                                // kVK_ANSI_Quote
        ";": 0x29, "semicolon": 0x29,                            // kVK_ANSI_Semicolon
        "\\": 0x2A, "backslash": 0x2A,                           // kVK_ANSI_Backslash
        ",": 0x2B, "comma": 0x2B,                                // kVK_ANSI_Comma
        "/": 0x2C, "slash": 0x2C,                                // kVK_ANSI_Slash
        ".": 0x2F, "period": 0x2F,                               // kVK_ANSI_Period
        "`": 0x32, "grave": 0x32, "backtick": 0x32,              // kVK_ANSI_Grave
        // Named keys.
        "enter": 0x24, "return": 0x24,                           // kVK_Return
        "tab": 0x30,                                             // kVK_Tab
        "space": 0x31,                                           // kVK_Space
        "delete": 0x33, "backspace": 0x33,                       // kVK_Delete (⌫)
        "esc": 0x35, "escape": 0x35,                             // kVK_Escape
        "forwarddelete": 0x75,                                   // kVK_ForwardDelete (⌦)
        "help": 0x72,                                            // kVK_Help
        "home": 0x73, "end": 0x77,                               // kVK_Home, kVK_End
        "pgup": 0x74, "pageup": 0x74,                            // kVK_PageUp
        "pgdn": 0x79, "pagedown": 0x79,                          // kVK_PageDown
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,   // kVK_*Arrow
        // Function keys: kVK_F1 … kVK_F20.
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F,
        "f19": 0x50, "f20": 0x5A,
    ]

    struct Combo: Equatable { var key: String; var cmd = false, ctrl = false, alt = false, shift = false }

    public struct ResolvedCombo: Equatable, Sendable {
        public var code: CGKeyCode
        public var cmd = false, ctrl = false, alt = false, shift = false

        public init(code: CGKeyCode, cmd: Bool = false, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
            self.code = code
            self.cmd = cmd
            self.ctrl = ctrl
            self.alt = alt
            self.shift = shift
        }
    }

    struct ComboError: Error, Equatable { var message: String }

    /// Modifiers and key joined by "+" ("cmd+shift+s"). A comma separates as
    /// well ("cmd,s"), because models write both. A literal "+" or "," key
    /// follows a separator: "cmd+," and "cmd,," are both ⌘-comma. Returns nil
    /// for an empty combo, a missing key ("cmd+") or an unknown modifier, so a
    /// typo never presses a bare key.
    static func parseCombo(_ combo: String) -> Combo? {
        let separators: Set<Character> = ["+", ","]
        let text = combo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let last = text.last else { return nil }
        let key: String
        let modifiers: Substring
        if text.count == 1 {
            return Combo(key: text)
        } else if separators.contains(last) {
            // The separator character is itself the key only right after
            // another separator ("cmd+,"); "cmd+" alone names no key.
            var rest = text.dropLast()
            while rest.last == " " { rest = rest.dropLast() }
            guard let previous = rest.last, separators.contains(previous) else { return nil }
            key = String(last)
            modifiers = rest.dropLast()
        } else if let split = text.lastIndex(where: { separators.contains($0) }) {
            key = text[text.index(after: split)...].trimmingCharacters(in: .whitespaces)
            modifiers = text[..<split]
        } else {
            key = text
            modifiers = ""
        }
        guard !key.isEmpty else { return nil }
        var parsed = Combo(key: key)
        for raw in modifiers.split(whereSeparator: { separators.contains($0) }) {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "": continue
            case "cmd", "command", "⌘": parsed.cmd = true
            case "ctrl", "control", "⌃": parsed.ctrl = true
            case "alt", "option", "opt", "⌥": parsed.alt = true
            case "shift", "⇧": parsed.shift = true
            default: return nil
            }
        }
        return parsed
    }

    /// A combo string to the key code and modifiers it presses, or why not.
    static func resolve(_ combo: String) -> Result<ResolvedCombo, ComboError> {
        guard let parsed = parseCombo(combo) else {
            return .failure(ComboError(message: "can't read key combo '\(combo)'. Write modifiers and one key joined by +, e.g. 'cmd+s', 'cmd+shift+t', 'cmd+,', 'return'. Modifiers: cmd, ctrl, alt (option), shift."))
        }
        guard let code = keyCodes[parsed.key] else {
            return .failure(ComboError(message: "unknown key '\(parsed.key)' in '\(combo)'. Known: enter, tab, esc, space, delete, forwarddelete, up/down/left/right, home, end, pgup, pgdn, f1–f20, a–z, 0–9 and the punctuation keys - = [ ] \\ ; ' , . / `."))
        }
        return .success(ResolvedCombo(code: code, cmd: parsed.cmd, ctrl: parsed.ctrl, alt: parsed.alt, shift: parsed.shift))
    }
}

public struct FocusAppTool: ToolExecutor {
    public static let name = "focus_app"
    public static let spec = ToolSpec(
        name: name,
        description: "Bring an application to the front by name — it takes the user's focus, so it waits its turn for the controls (one chat at a time). Usually not needed: screenshot(window:) captures a window behind others, keyboard(app:) and ui_action work on apps in the background, and ui_action(action:\"raise\") raises a window without activating the app.",
        parameters: """
        {"type":"object","properties":{"app":{"type":"string","description":"Application name (e.g. 'Godot')"}},"required":["app"]}
        """
    )

    public let backend: any MachineBackend
    public init(backend: any MachineBackend = LiveMachineBackend()) { self.backend = backend }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let app = Self.string(args, "app"), !app.isEmpty else {
            return .init(output: "Error: app is required.")
        }
        let actions = MachineActions(backend: backend, seat: context.machine ?? .detached(), ask: context.requestPermission)
        return await actions.focus(appName: app)
    }
}

// MARK: - view_image

public struct ViewImageTool: ToolExecutor {
    public static let name = "view_image"
    public static let spec = ToolSpec(
        name: name,
        description: """
            Show an image FILE to the model — a screenshot the user dropped in, a \
            frame a process saved, an art asset under review. Downscaled to ~1600 px \
            long edge so vision tokens stay sane.
            """,
        parameters: """
        {"type":"object","properties":{"file_path":{"type":"string","description":"Image path (png/jpg/gif/webp; may be relative to the project)"}},"required":["file_path"]}
        """
    )

    public init() {}

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard let raw = Self.string(args, "file_path") else {
            return .init(output: "Error: file_path is required.")
        }
        let (url, _) = context.policy.resolve(raw)
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) else {
            return .init(output: "Error: \(url.lastPathComponent) doesn't look like an image (\(ext.isEmpty ? "no extension" : ext)).")
        }
        // Downscale through a temp copy so the user's file is untouched.
        let tmp = tempPNG("view")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/cp")
        task.arguments = [url.path, tmp.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0, let data = ImagePipeline.prepare(pngAt: tmp, longEdge: 1600) else {
            try? FileManager.default.removeItem(at: tmp)
            return .init(output: "Error: cannot read \(url.path).")
        }
        return .init(output: "Loaded \(url.lastPathComponent) (\(data.count / 1024) KB).",
                     images: [MessageAttachment(kind: .image, name: url.lastPathComponent, data: data)])
    }
}

// MARK: - arg helpers

extension ToolExecutor {
    fileprivate static func double(_ json: JSONString, _ key: String, default def: Double) -> Double {
        guard let data = json.raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return def }
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        return def
    }
}
