import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit
import VisionHarnessCore

// MARK: - Screenshot mode
//
// `Vision --snapshot <folder>` opens the real app over a made-up workspace — a demo project, a few chats, a set of
// model routes — and saves each scene as a PNG at 2x: the chat with an agent's work, code mode, the setup wizard and
// Settings ▸ AI Models. The README's pictures come from here.
//
// It never touches the user's own things. Before anything reads a setting or a path, the launcher points
// `IsolatedRun` at a new throwaway folder: the settings file, the data folder and the home folder the app reads are
// inside it, Keychain items stay in memory, and the old-name migration doesn't run. Shells it starts get that folder
// as HOME. The folder is deleted when the app quits.
//
// Pictures are taken with ScreenCaptureKit's own-process capture (macOS 14.4+), which needs no Screen Recording
// permission, and fall back to drawing the window's views (`cacheDisplay`).
//
//   --snapshot <folder>         where the PNGs go (or VISION_SNAPSHOT_DIR)
//   --snapshot-scenes a,b       only these scenes (by default the README's: chat, code, setup, settings-models,
//                               prompts, tasks, activity, all-prompts, code-focus, code-chat; and, only when named,
//                               zai-guide, chat-kimi, settings-zai-route, chat-attachments, attachment-preview,
//                               settings-computer, settings-import, settings-guardian-signin, settings-guardian, glow)
//   --snapshot-live <profile>   run the chat for real first, on Amazon Bedrock with this AWS profile, and save what
//                               happened as chat-transcript.json (the seeded chat is made from such a run)
//   --snapshot-region <region>  the live run's Region (default us-west-2)
//   --snapshot-model <id>       the live run's model (default global.anthropic.claude-sonnet-5-5)

@MainActor
enum Snapshot {
    enum Scene: String, CaseIterable, Sendable {
        case chat, code, setup
        case models = "settings-models"
        /// The Z.ai (GLM) guide's check, with a Coding Plan key on the General API endpoint (scripted, no network).
        case zaiGuide = "zai-guide"
        /// The chat on Kimi K2.7 Code: its own model in the composer, thinking "always on".
        case chatKimi = "chat-kimi"
        /// A Z.ai route in Settings ▸ AI Models' editor: the endpoint picker, Test, what was learned.
        case zaiRoute = "settings-zai-route"
        /// The right column on the chat's Prompts timeline.
        case prompts
        /// The right column on the chat's tasks: a /goal at work, its plan with subagents on steps, three queued.
        case tasks
        /// The background activity popover over that busy chat.
        case activity
        /// Every chat's prompts.
        case allPrompts = "all-prompts"
        /// Code mode with the file tree, editor and terminal hidden: the chat and the project status.
        case codeFocus = "code-focus"
        /// Code mode as a project first opens: the file tree, the chat in the middle, the project status.
        case codeChat = "code-chat"
        /// A chat whose messages carried files and a large paste, with more waiting in the composer as chips.
        case attachments = "chat-attachments"
        /// The pasted-text chip opened: what the model will get, editable.
        case attachmentPreview = "attachment-preview"
        /// Settings ▸ Computer: screen control in the background first, the waiting line, the global stop.
        case computer = "settings-computer"
        /// Settings ▸ Import & Export over a made-up OpenClaw in the throwaway home folder.
        case importExport = "settings-import"
        /// Settings ▸ Guardian signed out (the browser sign-in) and signed in (org, limits, vault).
        case guardianSignIn = "settings-guardian-signin"
        case guardian = "settings-guardian"
        /// The machine-in-use glow's border and pill, with two chats sharing the Mac.
        case glow
        /// A long chat (over the eager-stack limit: the lazy transcript) whose last answer is very tall, opened at the
        /// end — it must not draw blank.
        case longChat = "chat-long"

        /// What a plain `--snapshot` run takes (the README's pictures).
        static let standard: [Scene] = [.chat, .code, .setup, .models, .prompts, .tasks, .activity, .allPrompts,
                                        .codeFocus, .codeChat]
    }

    struct Live: Equatable, Sendable {
        var profile: String
        var region = "us-west-2"
        var model = "global.anthropic.claude-sonnet-5-5"
    }

    struct Options: Equatable, Sendable {
        var output: URL
        var scenes: [Scene] = Scene.standard
        var live: Live?
    }

    /// The window's content size, in points; the PNGs are twice that.
    static let windowSize = NSSize(width: 1440, height: 900)

    private(set) static var options: Options?
    private(set) static var root: URL?
    /// The chat the live run made (nil: the seeded one).
    private static var liveChatID: String?
    private static var driving = false
    private static var inputBlocker: Any?
    private static var notes: [String] = []
    /// The app's own settings domain, and the keys it held before this run (AppKit writes a window frame or two
    /// there; they are taken out again on the way out). Nil when the domain didn't exist.
    private static var standardDomain = ""
    private static var standardKeysBefore: Set<String>?

    static var isActive: Bool { options != nil }

    // MARK: Command line

    /// What the command line asks for; nil for a normal launch.
    nonisolated static func options(arguments: [String], environment: [String: String]) -> Options? {
        var output = environment["VISION_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        var scenes: [Scene]?
        var live: Live?
        var region: String?
        var model: String?
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--snapshot": output = value()
            case "--snapshot-scenes":
                scenes = value()?.split(separator: ",").compactMap { Scene(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            case "--snapshot-live": live = value().map { Live(profile: $0) }
            case "--snapshot-region": region = value()
            case "--snapshot-model": model = value()
            default: break
            }
            index += 1
        }
        guard let output, !output.isEmpty else { return nil }
        if let region, live != nil { live?.region = region }
        if let model, live != nil { live?.model = model }
        let folder = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true)
        return Options(output: folder.standardizedFileURL, scenes: scenes?.isEmpty == false ? scenes! : Scene.standard,
                       live: live)
    }

    // MARK: Before the app starts

    /// Move every setting, path and secret the app uses into a new throwaway folder, then fill it with the demo
    /// workspace. Runs before anything else reads one; stops the app if the move didn't take.
    static func prepare(_ options: Options) {
        let fileManager = FileManager.default
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            fail("\(AppIdentity.name) is open; quit it first (both would share its window settings)")
        }
        // The real path (/private/var/…, not the /var link): paths read back from the disk then start with it.
        let temporary = fileManager.temporaryDirectory
        let real = temporary.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let root = URL(fileURLWithPath: real ?? temporary.path, isDirectory: true)
            .appendingPathComponent("vision-snapshot-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: options.output, withIntermediateDirectories: true)
        } catch {
            fail("could not make the folders: \(error.localizedDescription)")
        }
        setenv(IsolatedRun.environmentVariable, root.path, 1)
        // The first read settles it for the whole run: it must be the throwaway folder, or nothing goes ahead.
        guard IsolatedRun.root?.path == root.standardized.path,
              let home = IsolatedRun.home,
              AppPaths.support.path.hasPrefix(root.standardized.path + "/") else {
            fail("the isolated folder did not take; nothing of the user's was touched")
        }
        Self.root = root
        Self.options = options

        // AppKit keeps window frames and restorable state in the app's own settings domain; ask it not to, and note
        // what is there now so anything it adds anyway can be taken out when the app quits.
        standardDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        standardKeysBefore = UserDefaults.standard.persistentDomain(forName: standardDomain).map { Set($0.keys) }
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false,
                                                  "ApplePersistenceIgnoreState": true])

        // Shells the app starts (the terminal, the agent's commands) get the throwaway home and a plain zsh.
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let zshrc = """
            PROMPT='%F{green}%1~%f %# '
            path=(/opt/homebrew/bin(N) /usr/local/bin(N) $path)

            """
        try? zshrc.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        if options.live != nil {
            // The live run signs in with the user's AWS CLI profile: point the CLI at their files (read only).
            let aws = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aws", isDirectory: true)
            setenv("AWS_CONFIG_FILE", aws.appendingPathComponent("config").path, 1)
            setenv("AWS_SHARED_CREDENTIALS_FILE", aws.appendingPathComponent("credentials").path, 1)
        }
        setenv("HOME", home.path, 1)
        setenv("ZDOTDIR", home.path, 1)
        setenv("SHELL", "/bin/zsh", 1)
        // An app opened from Finder has no Homebrew on its PATH; the demo's `python3` may live there.
        let path = ["/opt/homebrew/bin", "/usr/local/bin"].filter { fileManager.fileExists(atPath: $0) }
            + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        setenv("PATH", path.filter { seen.insert($0).inserted }.joined(separator: ":"), 1)
        unsetenv("HISTFILE")

        SnapshotSeed.install(home: home, live: options.live)
    }

    /// The run is over (or the app is quitting early): the throwaway folder goes, and so does anything AppKit added
    /// to the app's own settings domain.
    static func cleanUp() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
        Self.root = nil
        let after = UserDefaults.standard.persistentDomain(forName: standardDomain) ?? [:]
        if let before = standardKeysBefore, !before.isEmpty {
            for key in after.keys where !before.contains(key) { UserDefaults.standard.removeObject(forKey: key) }
        } else {
            // Nothing was there before this run: the whole domain goes. (The preferences daemon may still leave an
            // empty settings file behind; it holds no keys.)
            UserDefaults.standard.removePersistentDomain(forName: standardDomain)
        }
        UserDefaults.standard.synchronize()
    }

    // MARK: Scenes

    /// Show each scene, save its picture, quit. Called once the main window is up.
    static func drive(_ model: AppModel) async {
        guard let options, !driving else { return }
        driving = true
        // Unattended (CI): a run that hangs ends instead of holding the machine.
        let limit: TimeInterval = options.live == nil ? 180 : 25 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            MainActor.assumeIsolated {
                cleanUp()
                fail("gave up after \(Int(limit)) s")
            }
        }
        // Nobody works in this window: keys and clicks meant for another app while it is in front go nowhere (the
        // terminal it opens must never take someone's typing).
        inputBlocker = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]) { _ in nil }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        guard let window = await mainWindow() else { fail("the main window never appeared") }
        window.isRestorable = false
        stopAutosaving(window)
        window.setContentSize(windowSize)
        window.center()
        await pause(1.5)

        if let live = options.live {
            await runLive(model, live, output: options.output)
        }

        for scene in options.scenes {
            await stage(scene, model, window: window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            await pause(scene == .code ? 3.0 : 1.5)
            let file = options.output.appendingPathComponent("\(scene.rawValue).png")
            let shot = scene == .glow ? (glowWindow ?? window) : window
            do {
                let image = try await capture(shot)
                try png(image, points: shot.frame.size).write(to: file, options: .atomic)
                note("\(scene.rawValue): \(image.width)x\(image.height) → \(file.path)")
            } catch {
                note("\(scene.rawValue): FAILED — \(error.localizedDescription)")
            }
            await unstage(scene, model, window: window)
            await pause(0.8)
        }

        let summary = notes.joined(separator: "\n") + "\n"
        try? summary.write(to: options.output.appendingPathComponent("snapshot.log"), atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(summary.utf8))
        // Quit without AppKit's goodbye: it would save the window's frame and split widths in the app's own settings
        // domain after anything here could take them out again. Nothing of this run needs saving.
        for terminal in model.code.terminals { terminal.terminate() }
        ProcessManager.shared.stopAll()
        // AppKit saves frames a moment after they change, and settings reach the preferences daemon asynchronously:
        // put the window away, let its last saves land, take them out, and let that land too.
        stopAutosaving(window)
        window.orderOut(nil)
        await pause(1.5)
        cleanUp()
        await pause(1.0)
        exit(0)
    }

    private static func stage(_ scene: Scene, _ model: AppModel, window: NSWindow) async {
        let chatID = liveChatID ?? SnapshotSeed.mainChatID
        switch scene {
        case .chat:
            model.mode = .chat
            showMainChat(chatID, model)
            model.config.planPanelOpen = true
        case .code:
            model.config.planPanelOpen = false
            showMainChat(chatID, model)
            model.mode = .code
            // The file tree stands in for the chat list here.
            setSidebarCollapsed(true, in: window)
            if let project = model.project {
                for file in SnapshotSeed.codeSceneFiles {
                    model.code.reveal(project.appendingPathComponent(file))
                }
                await pause(1.0)
                // Again, now that the tree has loaded: the open file's folder unfolds.
                if let last = SnapshotSeed.codeSceneFiles.last { model.code.reveal(project.appendingPathComponent(last)) }
                arrangeCodeSplits(in: window)
                if model.code.terminals.isEmpty, model.code.newTerminal() != nil {
                    await pause(0.5)
                    arrangeCodeSplits(in: window)
                    await pause(1.0)
                    model.code.activeTerminal?.send("\u{0C}")
                    await pause(0.3)
                    model.code.activeTerminal?.send(SnapshotSeed.terminalCommand + "\r")
                }
                scrollEditor(in: window, toLineContaining: SnapshotSeed.codeSceneAnchor)
            }
        case .setup:
            model.mode = .chat
            model.config.planPanelOpen = false
            model.showWizard = true
        case .models:
            model.mode = .chat
            model.settingsTab = .models
            model.showSettings = true
        case .zaiGuide:
            model.mode = .chat
            model.config.planPanelOpen = false
            model.planGuide = PlanGuideRequest(planID: "zai", backend: SnapshotPlanBackend(), stage: { guide in
                guide.regionID = ZAIErrors.Endpoint.general.rawValue
                guide.key = "0a1b2c3d4e5f.demoKeyForScreenshots"
                guide.go(.check)
            })
        case .chatKimi:
            model.mode = .chat
            model.config.planPanelOpen = false
            showMainChat(chatID, model)
            let kimi = SnapshotSeed.kimiRoute
            if !model.config.providers.contains(where: { $0.routeID == kimi.routeID }) { model.config.providers.append(kimi) }
            if let vm = model.transport.sessions.first(where: { $0.id == chatID }) {
                model.transport.setRoute(kimi.routeID, for: vm)
                model.transport.setThinking(.high, for: vm)
            }
        case .zaiRoute:
            model.mode = .chat
            let zai = SnapshotSeed.zaiRoute
            if !model.config.providers.contains(where: { $0.routeID == zai.routeID }) { model.config.providers.append(zai) }
            RequestAdaptationStore.shared.learn(.drop("stream_options"),
                                                for: RequestAdaptationStore.key(baseURL: zai.baseURL, model: zai.model))
            ProviderSettings.editOnAppear = zai
            model.settingsTab = .models
            model.showSettings = true
        case .prompts:
            model.mode = .chat
            showMainChat(chatID, model)
            model.config.planPanelWidth = 380
            model.runPanelTab = .prompts
            model.config.planPanelOpen = true
            if let vm = model.selectedSession, let last = vm.promptHistory.last {
                model.expandedPromptID = last.id
                // "Jump": the chat scrolls to the prompt's row and flashes it.
                await pause(0.8)
                model.promptJump = PromptJump(sessionID: vm.id, recordID: last.id)
            }
        case .tasks, .activity:
            model.mode = .chat
            showMainChat(chatID, model)
            if let vm = model.selectedSession { SnapshotSeed.stageBusy(vm, transport: model.transport) }
            model.config.planPanelWidth = 380
            model.runPanelTab = .tasks
            model.config.planPanelOpen = true
            if scene == .activity {
                await pause(0.6)
                model.showActivity = true
            }
        case .allPrompts:
            model.mode = .chat
            showMainChat(chatID, model)
            model.config.planPanelOpen = false
            model.showAllPrompts = true
        case .codeChat:
            model.config.planPanelOpen = false
            showMainChat(chatID, model)
            model.mode = .code
            setSidebarCollapsed(true, in: window)
            model.code.showTree = true
            model.code.editorVisible = false
            model.code.terminalVisible = false
        case .codeFocus:
            model.config.planPanelOpen = false
            showMainChat(chatID, model)
            if let vm = model.selectedSession { SnapshotSeed.stageBusy(vm, transport: model.transport) }
            model.mode = .code
            setSidebarCollapsed(true, in: window)
            if !model.code.isChatFocus { model.code.toggleChatFocus() }
        case .longChat:
            model.mode = .chat
            model.config.planPanelOpen = false
            model.select(SnapshotSeed.longChatID)
            await pause(1.0)
        case .attachments, .attachmentPreview:
            model.mode = .chat
            model.config.planPanelOpen = false
            model.select(SnapshotSeed.attachmentsChatID)
            await pause(0.5)
            model.pendingComposerAttachments = SnapshotSeed.composerAttachments()
            if scene == .attachmentPreview {
                await pause(2.0)
                model.pendingAttachmentPreview = "pasted-text.txt"
            }
        case .computer:
            model.mode = .chat
            model.settingsTab = .computer
            model.showSettings = true
        case .glow:
            glowWindow = showGlowPreview()
        case .guardianSignIn:
            model.mode = .chat
            model.settingsTab = .guardian
            model.showSettings = true
        case .guardian:
            model.guardian.seedSnapshotAccount()
            model.mode = .chat
            model.settingsTab = .guardian
            model.showSettings = true
        case .importExport:
            SnapshotSeed.writeOpenClaw(home: model.transport.skillLocations.home)
            ImportExportSettings.previewOnAppear = true
            model.mode = .chat
            model.settingsTab = .importExport
            model.showSettings = true
            await pause(2.0)
        }
    }

    /// The glow drawn in a window of its own (the real one is a click-through panel over the whole screen, which a
    /// window capture can't take): a dark desk, the border, and the pill as two chats sharing the Mac see it.
    private static var glowWindow: NSWindow?

    private static func showGlowPreview() -> NSWindow {
        let size = NSSize(width: 1100, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        let model = MachineGlowModel()
        model.text = GlowStatus.pill(
            control: ControlSnapshot(holder: ControlHolder(id: "a", chatID: "a", label: "Fix the Godot build"),
                                     waiting: [ControlHolder(id: "b", chatID: "b", label: "File the expense report")]),
            work: [])
        window.contentView = NSHostingView(rootView: MachineGlowView(model: model)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13)))
        window.center()
        window.orderFrontRegardless()
        return window
    }

    /// Open the chat the pictures are about; the seeded one gets back what a stored chat doesn't keep.
    private static func showMainChat(_ chatID: String, _ model: AppModel) {
        model.select(chatID)
        if liveChatID == nil, let vm = model.transport.sessions.first(where: { $0.id == chatID }) {
            SnapshotSeed.restoreLiveState(of: vm)
        }
    }

    private static func unstage(_ scene: Scene, _ model: AppModel, window: NSWindow) async {
        switch scene {
        case .setup: model.showWizard = false
        case .models, .zaiRoute: model.showSettings = false
        case .zaiGuide:
            model.planGuide = nil
            await pause(0.8)
        case .chatKimi:
            if let vm = model.transport.sessions.first(where: { $0.id == (liveChatID ?? SnapshotSeed.mainChatID) }),
               let main = model.config.activeRoute {
                model.transport.setRoute(main, for: vm)
            }
        case .computer, .importExport, .guardianSignIn: model.showSettings = false
        case .guardian:
            model.showSettings = false
            model.guardian.signOut()
        case .glow:
            glowWindow?.orderOut(nil)
            glowWindow = nil
        case .code:
            model.mode = .chat
            setSidebarCollapsed(false, in: window)
        case .chat, .attachments, .longChat: break
        case .attachmentPreview:
            // A name no chip has closes the preview (the sheet is SwiftUI's, so ending the window's sheet isn't
            // enough), and the next scene starts without it.
            model.pendingAttachmentPreview = ""
            window.attachedSheet.map { window.endSheet($0) }
            await pause(0.8)
        case .prompts:
            model.expandedPromptID = nil
        case .tasks, .activity:
            model.showActivity = false
            if let vm = model.selectedSession { SnapshotSeed.unstageBusy(vm, transport: model.transport) }
        case .allPrompts:
            model.showAllPrompts = false
        case .codeFocus:
            if let vm = model.selectedSession { SnapshotSeed.unstageBusy(vm, transport: model.transport) }
            model.code.toggleChatFocus()
            model.mode = .chat
            setSidebarCollapsed(false, in: window)
        case .codeChat:
            model.code.editorVisible = true
            model.mode = .chat
            setSidebarCollapsed(false, in: window)
        }
    }

    // MARK: The live run

    /// Ask the agent for real, in the demo project, and keep what happened (the seeded chat is made from it).
    private static func runLive(_ model: AppModel, _ live: Live, output: URL) async {
        guard let project = model.project else { note("live: no project open"); return }
        copyProject(project, to: output.appendingPathComponent("project-before", isDirectory: true))
        let vm = model.newChat()
        liveChatID = vm.id
        let started = Date()
        model.send(SnapshotSeed.prompt, in: vm)
        var sawRunning = false
        while Date().timeIntervalSince(started) < 20 * 60 {
            // Answered as a careful person would: yes to work inside the demo project, no to anything else.
            for gate in vm.pendingGates {
                let allow = mayAllow(gate.detail, project: project)
                note("live: \(allow ? "allowed" : "refused") \(gate.name) — \(gate.detail)")
                model.transport.answerGate(sessionID: vm.id, gateID: gate.id, allow: allow)
            }
            if vm.running { sawRunning = true }
            if sawRunning, !vm.running { break }
            if !sawRunning, Date().timeIntervalSince(started) > 30 { break }
            await pause(0.5)
        }
        note("live: finished in \(Int(Date().timeIntervalSince(started))) s, \(vm.entries.count) rows, running: \(vm.running)")
        let transcript = SnapshotTranscript(from: vm, started: started)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(transcript) {
            try? data.write(to: output.appendingPathComponent("chat-transcript.json"), options: .atomic)
        }
        // The project as the agent left it, for the seeded code scene (assets/screenshots/seed-from-live-run.py).
        copyProject(project, to: output.appendingPathComponent("project-after", isDirectory: true))
    }

    private static func copyProject(_ project: URL, to copy: URL) {
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: project, to: copy)
        try? FileManager.default.removeItem(at: copy.appendingPathComponent(".git"))
    }

    /// Whether the live run says yes to a permission question: only when every path it names is inside the
    /// project or the system's scratch folder (/tmp, /dev/null), and it doesn't reach for the network, a remote or
    /// root.
    nonisolated static func mayAllow(_ detail: String, project: URL) -> Bool {
        let lowered = detail.lowercased()
        for word in ["sudo", "git push", "curl ", "wget ", "ssh ", "scp ", "open "] where lowered.contains(word) {
            return false
        }
        let root = project.standardizedFileURL.path
        let tokens = detail.split { " \t\n'\"=;|&()<>`".contains($0) }.map(String.init)
        for token in tokens where token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("$")
            || token.split(separator: "/").contains("..") {
            let scratch = ["/tmp/", "/private/tmp/"].contains { token.hasPrefix($0) } && !token.contains("..")
                || ["/dev/null", "/dev/stdout", "/dev/stderr"].contains(token)
            guard scratch || token == root || token.hasPrefix(root + "/") else { return false }
        }
        return true
    }

    // MARK: Pictures

    enum CaptureError: LocalizedError {
        case noWindow, noImage
        var errorDescription: String? {
            switch self {
            case .noWindow: "the window is not in the list of this app's windows"
            case .noImage: "the window could not be drawn"
            }
        }
    }

    /// The window as it is on screen, with an attached sheet over it.
    static func capture(_ window: NSWindow) async throws -> CGImage {
        if #available(macOS 14.4, *) {
            do {
                // The capture includes the window's sheet.
                return try await screenCapture(window)
            } catch {
                note("ScreenCaptureKit could not take the window (\(error.localizedDescription)); drawing it instead")
            }
        }
        let base = try drawn(window)
        guard let sheet = window.attachedSheet else { return base }
        return composite(base, frame: window.frame, sheet: try drawn(sheet), sheetFrame: sheet.frame) ?? base
    }

    /// ScreenCaptureKit's capture of one of this app's own windows: what is on screen, materials and all. Needs no
    /// Screen Recording permission.
    @available(macOS 14.4, *)
    private static func screenCapture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError.noWindow
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The window's views drawn into a bitmap at 2x (no compositor: materials come out flat).
    private static func drawn(_ window: NSWindow) throws -> CGImage {
        guard let view = window.contentView?.superview ?? window.contentView else { throw CaptureError.noImage }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw CaptureError.noImage }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureError.noImage }
        return image
    }

    /// The sheet drawn over its window where it sits, with a shadow.
    static func composite(_ base: CGImage, frame: NSRect, sheet: CGImage, sheetFrame: NSRect) -> CGImage? {
        guard frame.width > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(base.width) / frame.width
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let rect = CGRect(x: (sheetFrame.minX - frame.minX) * scale, y: (sheetFrame.minY - frame.minY) * scale,
                          width: sheetFrame.width * scale, height: sheetFrame.height * scale)
        context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale,
                          color: NSColor.black.withAlphaComponent(0.55).cgColor)
        context.draw(sheet, in: rect)
        return context.makeImage()
    }

    /// PNG bytes, marked with the window's size in points (so it opens at its real size).
    static func png(_ image: CGImage, points: NSSize) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = points
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CaptureError.noImage }
        return data
    }

    /// Code mode's panes at the widths a person would drag them to: a narrow file tree, the editor, the agent; the
    /// terminal under the editor.
    private static func arrangeCodeSplits(in window: NSWindow) {
        // Code mode's own split views, not the window's (the one whose controller holds the sidebar).
        let splits = splitViews(in: window).filter { split in
            !((split.delegate as? NSSplitViewController)?.splitViewItems.contains { $0.behavior == .sidebar } ?? false)
        }
        for split in splits where split.isVertical && split.arrangedSubviews.count == 3 {
            split.setPosition(190, ofDividerAt: 0)
            split.setPosition(split.bounds.width - 430, ofDividerAt: 1)
        }
        for split in splits where !split.isVertical && split.arrangedSubviews.count == 2 {
            split.setPosition((split.bounds.height * 0.52).rounded(), ofDividerAt: 0)
        }
    }

    /// AppKit keeps a window's frame and its split views' widths in the app's own settings; not for this window.
    private static func stopAutosaving(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        for split in splitViews(in: window) { split.autosaveName = nil }
    }

    /// Scroll the editor so the line holding `text` (what the agent added) is near the top.
    private static func scrollEditor(in window: NSWindow, toLineContaining text: String) {
        var views: [NSTextView] = []
        func walk(_ view: NSView) {
            if let textView = view as? NSTextView, textView.isEditable { views.append(textView) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        for textView in views {
            let string = textView.string as NSString
            let found = string.range(of: text)
            guard found.location != NSNotFound, let layout = textView.layoutManager,
                  let container = textView.textContainer, let clip = textView.enclosingScrollView?.contentView else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
            let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
            clip.scroll(to: NSPoint(x: 0, y: max(0, line.minY + textView.textContainerOrigin.y - line.height * 1.5)))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Fold the window's sidebar (the chat list) away, or bring it back.
    private static func setSidebarCollapsed(_ collapsed: Bool, in window: NSWindow) {
        for split in splitViews(in: window) {
            guard let controller = split.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else { continue }
            item.isCollapsed = collapsed
            return
        }
    }

    private static func splitViews(in window: NSWindow) -> [NSSplitView] {
        var splits: [NSSplitView] = []
        func walk(_ view: NSView) {
            if let split = view as? NSSplitView { splits.append(split) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview ?? window.contentView { walk(root) }
        return splits
    }

    // MARK: Helpers

    private static func mainWindow() async -> NSWindow? {
        for _ in 0..<100 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil
                && $0.frame.width > 400 }) {
                return window
            }
            await pause(0.1)
        }
        return nil
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func note(_ line: String) {
        notes.append(line)
    }

    private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("\(AppIdentity.name) --snapshot: \(reason)\n".utf8))
        exit(2)
    }
}
