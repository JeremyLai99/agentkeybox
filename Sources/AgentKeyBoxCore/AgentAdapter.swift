import Foundation

public enum AgentIntegrationError: Error, LocalizedError, Equatable {
  case executableNotFound(String)
  case helperNotFound
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let name):
      return "\(name) is not installed or could not be found."
    case .helperNotFound:
      return
        "agentkeybox-mcp could not be found next to the AgentKeyBox app or in a standard local bin directory."
    case .commandFailed(let message):
      return message
    }
  }
}

public enum AgentIntegrationStatus: String, Codable, Sendable {
  case notInstalled
  case notConfigured
  case configured
  case error
}

public protocol AgentAdapter: Sendable {
  var id: String { get }
  var displayName: String { get }

  func detectInstallation() async -> Bool
  func installIntegration(mcpExecutablePath: String) async throws
  func integrationStatus() async -> AgentIntegrationStatus
}

public struct ClaudeCodeAdapter: AgentAdapter {
  public let id = "claude-code"
  public let displayName = "Claude Code"

  public init() {}

  public func detectInstallation() async -> Bool {
    executablePath(named: "claude") != nil
  }

  public func installIntegration(mcpExecutablePath: String) async throws {
    guard let claude = executablePath(named: "claude") else {
      throw AgentIntegrationError.executableNotFound("Claude Code")
    }
    _ = try? runExecutable(claude, arguments: ["mcp", "remove", "--scope", "user", "agentkeybox"])
    try runExecutable(
      claude,
      arguments: [
        "mcp", "add",
        "--scope", "user",
        "--env", "AGENTKEYBOX_AGENT_ID=claude-code",
        "--env", "AGENTKEYBOX_AGENT_NAME=Claude Code",
        "--transport", "stdio",
        "agentkeybox", "--", mcpExecutablePath,
      ])
  }

  public func integrationStatus() async -> AgentIntegrationStatus {
    guard let claude = executablePath(named: "claude") else { return .notInstalled }
    do {
      let output = try runExecutable(claude, arguments: ["mcp", "get", "agentkeybox"])
      return output.localizedCaseInsensitiveContains("agentkeybox") ? .configured : .notConfigured
    } catch {
      return .notConfigured
    }
  }
}

public struct CodexAdapter: AgentAdapter {
  public let id = "codex"
  public let displayName = "Codex"

  public init() {}

  public func detectInstallation() async -> Bool {
    executablePath(named: "codex") != nil
  }

  public func installIntegration(mcpExecutablePath: String) async throws {
    guard let codex = executablePath(named: "codex") else {
      throw AgentIntegrationError.executableNotFound("Codex")
    }
    _ = try? runExecutable(codex, arguments: ["mcp", "remove", "agentkeybox"])
    try runExecutable(
      codex,
      arguments: [
        "mcp", "add", "agentkeybox",
        "--env", "AGENTKEYBOX_AGENT_ID=codex",
        "--env", "AGENTKEYBOX_AGENT_NAME=Codex",
        "--", mcpExecutablePath,
      ])
  }

  public func integrationStatus() async -> AgentIntegrationStatus {
    guard let codex = executablePath(named: "codex") else { return .notInstalled }
    do {
      let output = try runExecutable(codex, arguments: ["mcp", "get", "agentkeybox", "--json"])
      return output.localizedCaseInsensitiveContains("agentkeybox") ? .configured : .notConfigured
    } catch {
      return .notConfigured
    }
  }
}

public enum MCPExecutableLocator {
  public static func locate(
    bundleURL: URL? = Bundle.main.bundleURL,
    executableURL: URL? = Bundle.main.executableURL
  ) -> String? {
    var candidates: [URL] = []
    if let bundleURL {
      candidates.append(bundleURL.appendingPathComponent("Contents/Helpers/agentkeybox-mcp"))
    }
    if let executableURL {
      candidates.append(
        executableURL.deletingLastPathComponent().appendingPathComponent("agentkeybox-mcp"))
    }
    candidates.append(
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".local/bin/agentkeybox-mcp"))
    candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/agentkeybox-mcp"))
    candidates.append(URL(fileURLWithPath: "/usr/local/bin/agentkeybox-mcp"))

    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?.path
  }
}

public func executablePath(named name: String) -> String? {
  var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
    .split(separator: ":")
    .map(String.init)
  directories.append(contentsOf: [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
  ])

  for directory in Array(Set(directories)) {
    let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
  }
  return nil
}

@discardableResult
public func runExecutable(_ path: String, arguments: [String]) throws -> String {
  let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentKeyBox-cli-\(UUID().uuidString)")
  _ = FileManager.default.createFile(
    atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
  defer { try? FileManager.default.removeItem(at: outputURL) }

  let handle = try FileHandle(forWritingTo: outputURL)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  process.standardOutput = handle
  process.standardError = handle

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    try? handle.close()
    throw error
  }
  try? handle.synchronize()
  try? handle.close()

  let data = (try? Data(contentsOf: outputURL)) ?? Data()
  let output = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
  guard process.terminationStatus == 0 else {
    let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
    throw AgentIntegrationError.commandFailed(
      message.isEmpty
        ? "Agent integration command failed with exit code \(process.terminationStatus)." : message
    )
  }
  return output
}
