// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentKeyBox",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AgentKeyBoxCore", targets: ["AgentKeyBoxCore"]),
    .executable(name: "AgentKeyBox", targets: ["AgentKeyBoxApp"]),
    .executable(name: "agentkeybox-mcp", targets: ["AgentKeyBoxMCP"]),
    .executable(name: "akb", targets: ["AgentKeyBoxCLI"]),
  ],
  targets: [
    .target(name: "AgentKeyBoxCore"),
    .executableTarget(
      name: "AgentKeyBoxApp",
      dependencies: ["AgentKeyBoxCore"]
    ),
    .executableTarget(
      name: "AgentKeyBoxMCP",
      dependencies: ["AgentKeyBoxCore"]
    ),
    .executableTarget(
      name: "AgentKeyBoxCLI",
      dependencies: ["AgentKeyBoxCore"]
    ),
    .testTarget(
      name: "AgentKeyBoxCoreTests",
      dependencies: ["AgentKeyBoxCore"]
    ),
  ]
)
