import XCTest
@testable import VisionHarnessCore

/// Checkpoints: what a turn changes is kept (before and after), shown as diffs, and can be rewound — with a conflict
/// check when a file changed again since.
final class CheckpointTests: XCTestCase {
    private var dir: URL!
    private var workspace: URL!
    private var store: CheckpointStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-checkpoints-\(UUID().uuidString)")
        workspace = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = CheckpointStore(root: dir.appendingPathComponent("checkpoints", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: workspace.appendingPathComponent(name))
    }

    private func read(_ name: String) -> String? {
        (try? Data(contentsOf: workspace.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func engine(_ turns: [ScriptedClient.Turn]) -> Engine {
        Engine.autoApproving(client: ScriptedClient(turns: turns), registry: .standard(), systemPrompt: "",
                             config: EngineConfig(model: "scripted"), workspace: workspace,
                             policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: workspace))
    }

    private func call(_ id: String, _ name: String, _ args: [String: Any]) -> ToolCall {
        let data = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return ToolCall(id: id, name: name, arguments: String(decoding: data, as: UTF8.self))
    }

    func testTheFileToolsRecordWhatEachFileHeldBeforeAndAfter() async throws {
        try write("a.txt", "one\ntwo\nthree\n")
        let recorder = store.recorder(chatID: "chat", turnID: "turn-1", title: "Change things")
        let turns: [ScriptedClient.Turn] = [
            .init(calls: [call("1", "edit", ["file_path": "a.txt", "old_string": "two", "new_string": "TWO"])]),
            .init(calls: [call("2", "write_file", ["file_path": "new/b.txt", "content": "fresh\n"])]),
            // A second edit of the same file keeps the first "before".
            .init(calls: [call("3", "edit", ["file_path": "a.txt", "old_string": "three", "new_string": "3"])]),
            .init(text: "done"),
        ]
        _ = try await TurnCheckpoint.$current.withValue(recorder) {
            try await engine(turns).run(messages: [], userText: "go") { _ in }
        }
        let record = try XCTUnwrap(store.record(chatID: "chat", turnID: "turn-1"))
        XCTAssertEqual(record.title, "Change things")
        XCTAssertEqual(record.changedFiles.count, 2)
        let a = try XCTUnwrap(record.files.first { $0.path.hasSuffix("/a.txt") })
        XCTAssertEqual(a.by, "edit")
        XCTAssertEqual(a.change, .modified)
        XCTAssertEqual(store.data(a.before!).map { String(decoding: $0, as: UTF8.self) }, "one\ntwo\nthree\n")
        XCTAssertEqual(store.data(a.after!).map { String(decoding: $0, as: UTF8.self) }, "one\nTWO\n3\n")
        let b = try XCTUnwrap(record.files.first { $0.path.hasSuffix("/new/b.txt") })
        XCTAssertNil(b.before, "it didn't exist before the turn")
        XCTAssertEqual(b.change, .created)
        XCTAssertEqual(b.by, "write_file")
    }

    func testRewindPutsFilesBackAndRemovesWhatTheTurnCreated() async throws {
        try write("a.txt", "original\n")
        let recorder = store.recorder(chatID: "chat", turnID: "turn-1", title: "Edit")
        let turns: [ScriptedClient.Turn] = [
            .init(calls: [call("1", "write_file", ["file_path": "a.txt", "content": "changed\n"])]),
            .init(calls: [call("2", "write_file", ["file_path": "made.txt", "content": "new\n"])]),
            .init(text: "done"),
        ]
        _ = try await TurnCheckpoint.$current.withValue(recorder) {
            try await engine(turns).run(messages: [], userText: "go") { _ in }
        }
        let record = try XCTUnwrap(store.record(chatID: "chat", turnID: "turn-1"))
        let plan = Rewind.plan(record, store: store)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.safe.count, 2)

        let undo = store.recorder(chatID: "chat", turnID: "rewind-1", title: "Rewind of “Edit”")
        let result = Rewind.apply(plan, store: store, includeConflicts: false, recorder: undo)
        XCTAssertEqual(read("a.txt"), "original\n")
        XCTAssertNil(read("made.txt"))
        XCTAssertEqual(result.restored.count, 1)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertNotNil(store.record(chatID: "chat", turnID: "turn-1")?.rewoundAt)
        XCTAssertEqual(Rewind.summary(result, title: "Edit", root: workspace.path),
                       "↺ Rewound “Edit”: put back 1 file (a.txt) and removed 1 file it created (made.txt).")

        // The rewind is a turn of its own: rewinding it brings the turn's work back.
        let rewindRecord = try XCTUnwrap(store.record(chatID: "chat", turnID: "rewind-1"))
        Rewind.apply(Rewind.plan(rewindRecord, store: store), store: store, includeConflicts: false)
        XCTAssertEqual(read("a.txt"), "changed\n")
        XCTAssertEqual(read("made.txt"), "new\n")
    }

    func testAFileChangedSinceTheTurnIsAConflictTheRewindLeavesAloneUnlessAsked() async throws {
        try write("a.txt", "v1\n")
        try write("b.txt", "b1\n")
        let recorder = store.recorder(chatID: "chat", turnID: "turn-1", title: "Edit both")
        let turns: [ScriptedClient.Turn] = [
            .init(calls: [call("1", "write_file", ["file_path": "a.txt", "content": "v2\n"])]),
            .init(calls: [call("2", "write_file", ["file_path": "b.txt", "content": "b2\n"])]),
            .init(text: "done"),
        ]
        _ = try await TurnCheckpoint.$current.withValue(recorder) {
            try await engine(turns).run(messages: [], userText: "go") { _ in }
        }
        try write("a.txt", "v3 — the person's own edit\n")
        let record = try XCTUnwrap(store.record(chatID: "chat", turnID: "turn-1"))
        let plan = Rewind.plan(record, store: store)
        XCTAssertEqual(plan.conflicts.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["a.txt"])
        XCTAssertEqual(plan.conflicts.first?.conflict, "changed since this turn")
        XCTAssertEqual(plan.safe.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["b.txt"])

        let result = Rewind.apply(plan, store: store, includeConflicts: false)
        XCTAssertEqual(read("a.txt"), "v3 — the person's own edit\n", "left alone")
        XCTAssertEqual(read("b.txt"), "b1\n")
        XCTAssertEqual(result.left.count, 1)

        // Asked to rewind everything, the conflicting file goes back too.
        Rewind.apply(Rewind.plan(record, store: store), store: store, includeConflicts: true)
        XCTAssertEqual(read("a.txt"), "v1\n")
        // Already as before: nothing left to do.
        XCTAssertTrue(Rewind.plan(record, store: store).isEmpty)
    }

    func testWithoutACheckpointNothingIsRecorded() async throws {
        let turns: [ScriptedClient.Turn] = [
            .init(calls: [call("1", "write_file", ["file_path": "x.txt", "content": "x"])]),
            .init(text: "done"),
        ]
        _ = try await engine(turns).run(messages: [], userText: "go") { _ in }
        XCTAssertTrue(store.records(chatID: "chat").isEmpty)
        XCTAssertEqual(read("x.txt"), "x")
    }

    func testAShellCommandsChangesAreWorkedOutFromGit() async throws {
        guard GitProbe.executable != nil else { throw XCTSkip("no git on this machine") }
        func git(_ args: String...) {
            // No signing or hooks from the machine's own git settings.
            _ = GitProbe.run(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args, in: workspace)
        }
        git("init", "-q")
        git("config", "user.email", "t@example.com")
        git("config", "user.name", "Test")
        try write("tracked.txt", "clean\n")
        try write("dirty.txt", "committed\n")
        try write("gone.txt", "will be deleted\n")
        git("add", ".")
        git("commit", "-qm", "init")
        try write("dirty.txt", "edited before the turn\n")
        try write("ignored.log", "x")
        try write(".gitignore", "*.log\n")

        let recorder = store.recorder(chatID: "chat", turnID: "turn-1", title: "Run a script")
        let command = "printf 'by shell\\n' > tracked.txt; printf 'more\\n' >> dirty.txt; rm gone.txt; printf 'n' > created.txt; printf 'y' > ignored.log"
        let turns: [ScriptedClient.Turn] = [
            .init(calls: [call("1", "run_shell_command", ["command": command])]),
            .init(text: "done"),
        ]
        _ = try await TurnCheckpoint.$current.withValue(recorder) {
            try await engine(turns).run(messages: [], userText: "go") { _ in }
        }
        let record = try XCTUnwrap(store.record(chatID: "chat", turnID: "turn-1"))
        let byName = Dictionary(uniqueKeysWithValues: record.changedFiles.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        XCTAssertEqual(Set(byName.keys), ["tracked.txt", "dirty.txt", "gone.txt", "created.txt"], "ignored files aren't looked at")
        XCTAssertEqual(byName["tracked.txt"]?.by, "run_shell_command")
        XCTAssertEqual(byName["tracked.txt"]?.before.flatMap(store.data).map { String(decoding: $0, as: UTF8.self) }, "clean\n")
        XCTAssertEqual(byName["dirty.txt"]?.before.flatMap(store.data).map { String(decoding: $0, as: UTF8.self) },
                       "edited before the turn\n", "what it held before the command, not what was committed")
        XCTAssertEqual(byName["gone.txt"]?.change, .deleted)
        XCTAssertEqual(byName["created.txt"]?.change, .created)

        Rewind.apply(Rewind.plan(record, store: store), store: store, includeConflicts: false)
        XCTAssertEqual(read("tracked.txt"), "clean\n")
        XCTAssertEqual(read("dirty.txt"), "edited before the turn\n")
        XCTAssertEqual(read("gone.txt"), "will be deleted\n")
        XCTAssertNil(read("created.txt"))
        XCTAssertEqual(read("ignored.log"), "y", "never touched")
    }

    func testContentsAreKeptOnceAndOldRecordsArePruned() throws {
        let h1 = try store.put(Data("same".utf8))
        let h2 = try store.put(Data("same".utf8))
        XCTAssertEqual(h1, h2)
        var old = TurnCheckpointRecord(id: "old", chatID: "c", title: "old",
                                       startedAt: Date(timeIntervalSinceNow: -40 * 24 * 3600),
                                       files: [CheckpointFile(path: "/x", before: h1, after: try store.put(Data("other".utf8)), by: "edit")])
        old.updatedAt = old.startedAt
        store.save(old)
        let recent = TurnCheckpointRecord(id: "new", chatID: "c", title: "new",
                                          files: [CheckpointFile(path: "/y", before: nil, after: h1, by: "edit")])
        store.save(recent)
        // Objects written just now are protected for an hour; prune as if it were later.
        let report = store.prune(now: Date(timeIntervalSinceNow: 2 * 3600))
        XCTAssertEqual(report.recordsRemoved, 1)
        XCTAssertEqual(report.objectsRemoved, 1, "only the content no record mentions")
        XCTAssertNotNil(store.data(h1))
        XCTAssertEqual(store.records(chatID: "c").map(\.id), ["new"])
        store.deleteChat("c")
        XCTAssertTrue(store.records(chatID: "c").isEmpty)
    }

    func testTheDiffShowsHunksWithContext() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var newLines = (1...20).map { "line \($0)" }
        newLines[4] = "line five"
        newLines.insert("inserted", at: 15)
        let diff = LineDiff.diff(old: old, new: newLines.joined(separator: "\n") + "\n")
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks[0].header, "@@ -2,7 +2,7 @@")
        XCTAssertEqual(diff.hunks[0].lines.filter { $0.kind == .removed }.map(\.text), ["line 5"])
        XCTAssertEqual(diff.hunks[0].lines.filter { $0.kind == .added }.map(\.text), ["line five"])
        XCTAssertEqual(diff.hunks[1].lines.filter { $0.kind == .added }.map(\.text), ["inserted"])
        XCTAssertNotNil(LineDiff.diff(old: Data([0, 1, 2]), new: Data([3])).note, "binary files are only sized")
        XCTAssertEqual(LineDiff.diff(old: nil, new: Data("a\nb\n".utf8)).added, 2)
    }
}
