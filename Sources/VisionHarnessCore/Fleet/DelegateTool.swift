import Foundation

// MARK: - delegate (parallel fan-out)

/// Runs several independent subtasks at once, each in its own subagent, and returns every report together.
/// With more than one model server the tasks spread across them; a task (or all of them) may name its server.
public struct DelegateTool: ToolExecutor {
    public static let name = "delegate"
    public static let spec: ToolSpec = DelegateTool.spec(for: .default)

    private static let maxTasks = 12
    private static let defaultParallel = 6
    private static let reportChars = 8_000

    /// The agent types the tool's description offers (nil = the built-in ones).
    public let catalog: AgentCatalog?

    public init(catalog: AgentCatalog? = nil) {
        self.catalog = catalog
    }

    public var spec: ToolSpec { Self.spec(for: catalog ?? .default) }

    /// The description names the agent types; the servers are listed once, in the agent tool.
    public static func spec(for catalog: AgentCatalog) -> ToolSpec {
        let description = "Run several independent subtasks at the same time, each by its own subagent, and get all their reports back together. Use it to fan work out — investigate three modules, review four files, implement three unrelated changes — instead of doing them one after another. Subtasks cannot talk to each other or see this conversation, so each prompt must be complete; make sure they don't edit the same files. "
            + "Give each an agent_type: " + catalog.describe() + ". Without a server, tasks spread across the subagent servers by load; give a task `server` (an id listed in the agent tool) to choose where it runs."
        return ToolSpec(name: name, description: description, parameters: parameters)
    }

    /// The parameters (the same on Windows; compared structurally by the shared fixture).
    public static let parameters = #"{"type":"object","properties":{"tasks":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"object","properties":{"description":{"type":"string","description":"A short name for the subtask"},"prompt":{"type":"string","description":"The complete task"},"agent_type":{"type":"string","description":"The kind of subagent (default: general)"},"server":{"type":"string","description":"#
        + AgentTool.jsonString(SubagentServers.serverParameter + " (This task only.)")
        + #"},"step":{"type":"string","description":"#
        + AgentTool.jsonString(AgentTool.stepParameter)
        + #"},"sensitive":{"type":"boolean","description":"#
        + AgentTool.jsonString(SubagentServers.sensitiveParameter + " (This task only.)")
        + #"}},"required":["description","prompt"]},"description":"The subtasks to run in parallel"},"max_parallel":{"type":"integer","description":"At most this many at once (default 6)"},"server":{"type":"string","description":"#
        + AgentTool.jsonString(SubagentServers.serverParameter + " (Every task without its own.)")
        + #"},"sensitive":{"type":"boolean","description":"#
        + AgentTool.jsonString(SubagentServers.sensitiveParameter + " (Every task.)")
        + #"}},"required":["tasks"]}"#

    private struct Subtask: Sendable {
        let description: String
        let prompt: String
        let definition: AgentDefinition
        let sensitive: Bool
        let step: String?
        let pin: SubagentPool.Entry?
    }

    public func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        guard context.depth < 1 else {
            return ToolResult(output: "Error: nested subagents are not allowed (depth limit).")
        }
        let arguments = JSONArgs.dictionary(args)
        var array = arguments["tasks"] as? [Any]
        // Some models send the list as a JSON string.
        if array == nil, let encoded = arguments["tasks"] as? String, let data = encoded.data(using: .utf8) {
            array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        }
        guard let array, !array.isEmpty else {
            return ToolResult(output: "Error: tasks must be a non-empty array of {description, prompt} objects.")
        }
        guard array.count <= Self.maxTasks else {
            return ToolResult(output: "Error: at most \(Self.maxTasks) tasks at once; split the rest into a second delegate call.")
        }

        let types = context.agentTypes ?? .default
        let allSensitive = JSONArgs.bool(args, "sensitive", default: false)
        // Where the main agent wants them: every server named is checked before any task starts.
        var allPin: SubagentPool.Entry?
        switch AgentTool.serverChoice(arguments["server"] as? String, context: context) {
        case .entry(let entry): allPin = entry
        case .error(let message): return ToolResult(output: message)
        case nil: break
        }
        var tasks: [Subtask] = []
        for (offset, node) in array.enumerated() {
            let index = offset + 1
            guard let item = node as? [String: Any] else {
                return ToolResult(output: "Error: task \(index) is not an object.")
            }
            let prompt = ((item["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                return ToolResult(output: "Error: task \(index) has no prompt.")
            }
            let typeName = item["agent_type"] as? String
            guard let definition = types.find(typeName) else {
                return ToolResult(output: "Error: task \(index) has an unknown agent_type '\(typeName ?? "")'. Available: \(types.describe()).")
            }
            var pin = allPin
            switch AgentTool.serverChoice(item["server"] as? String, context: context) {
            case .entry(let entry): pin = entry
            case .error(let message): return ToolResult(output: "Error: task \(index): " + message.dropFirst("Error: ".count))
            case nil: break
            }
            let description = ((item["description"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            tasks.append(Subtask(description: description.isEmpty ? "task \(index)" : description,
                                 prompt: prompt, definition: definition,
                                 sensitive: ((item["sensitive"] as? Bool) ?? allSensitive) || context.privateSubagentsOnly,
                                 step: AgentTool.stepArgument(item["step"]), pin: pin))
        }

        let parallel = min(max(JSONArgs.int(args, "max_parallel", default: Self.defaultParallel), 1), Self.maxTasks)
        let outcomes: [SubagentOutcome]
        do {
            outcomes = try await Self.runAll(tasks, parallel: parallel, context: context)
        } catch {
            return ToolResult(output: "Error: cancelled by user.")
        }

        let done = outcomes.filter(\.ok).count
        var text = "Delegated \(tasks.count) task\(tasks.count == 1 ? "" : "s"): \(done) finished, \(tasks.count - done) failed.\n"
        // How busy each server is now, after the header (results only: the descriptions stay stable).
        if let load = AgentTool.loadLine(context: context) { text += "\n" + load + "\n" }
        for (offset, outcome) in outcomes.enumerated() {
            let details = outcome.details()
            text += "\n## \(offset + 1). \(tasks[offset].description) — \(outcome.ok ? "finished" : "failed")\(details.isEmpty ? "" : " " + details)\n"
            if let moved = outcome.fallbackLine() { text += moved + "\n" }
            let report = outcome.report
            text += (report.count > Self.reportChars ? String(report.prefix(Self.reportChars)) + "\n[… report truncated]" : report) + "\n"
        }
        return ToolResult(output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Every subtask, at most `parallel` at a time, in the order they were given. The others wait for a
    /// slot before they so much as register with the roster.
    private static func runAll(_ tasks: [Subtask], parallel: Int, context: ToolContext) async throws -> [SubagentOutcome] {
        try await withThrowingTaskGroup(of: (Int, SubagentOutcome).self) { group in
            var outcomes = [SubagentOutcome?](repeating: nil, count: tasks.count)
            for index in tasks.indices {
                if index >= parallel, let (finished, outcome) = try await group.next() { outcomes[finished] = outcome }
                let task = tasks[index]
                group.addTask {
                    (index, try await AgentTool.runCore(prompt: task.prompt, description: task.description, definition: task.definition,
                                                        background: false, sensitive: task.sensitive, step: task.step,
                                                        pin: task.pin, context: context))
                }
            }
            while let (finished, outcome) = try await group.next() { outcomes[finished] = outcome }
            return outcomes.map { $0! }
        }
    }
}
