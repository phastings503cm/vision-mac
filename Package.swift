// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisionMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisionHarnessCore", targets: ["VisionHarnessCore"]),
        .executable(name: "Vision", targets: ["VisionMacApp"]),
    ],
    targets: [
        // Agent engine: LLM clients, tool execution, permissions, sessions.
        // No UI, no AppKit — verifiable headlessly.
        .target(name: "VisionHarnessCore"),
        // The native SwiftUI app — it IS the harness.
        .executableTarget(name: "VisionMacApp", dependencies: ["VisionHarnessCore"]),
        // Engine tests (tools, permissions, Qwen XML parser, loop). Fixtures/ holds files shared with Vision for
        // Windows; the tests read them from the source tree.
        .testTarget(name: "VisionHarnessCoreTests", dependencies: ["VisionHarnessCore"], exclude: ["Fixtures"]),
        // The harness end to end: the task queue runner, /goal, retries —
        // driven against a fake model server.
        .testTarget(name: "VisionMacAppTests", dependencies: ["VisionMacApp", "VisionHarnessCore"]),
    ]
)