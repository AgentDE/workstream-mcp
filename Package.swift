// swift-tools-version:5.10
import PackageDescription

// The workstream MCP server: a shared record of each piece of agent work (overview, rules, memory, questions,
// progress, files, tickets) that agents keep current and an app can show beside the chat. See README.md.
let package = Package(
    name: "workstream-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkstreamKit", targets: ["WorkstreamKit"]),
        .executable(name: "workstream-mcp", targets: ["workstream-mcp"]),
    ],
    targets: [
        // The workstream file format, store, MCP tools and transcript reading. No AppKit.
        .target(name: "WorkstreamKit", path: "Sources/WorkstreamKit"),
        // The MCP server (stdio), Claude Code hooks and the status line wrapper.
        .executableTarget(name: "workstream-mcp", dependencies: ["WorkstreamKit"], path: "Sources/workstream-mcp"),
        .testTarget(name: "WorkstreamKitTests", dependencies: ["WorkstreamKit", "workstream-mcp"], path: "Tests/WorkstreamKitTests"),
    ]
)
