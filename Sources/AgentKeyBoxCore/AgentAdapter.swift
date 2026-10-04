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

/// Directories searched for agent CLIs, in priority order.
///
/// Apps launched from Finder inherit only `/usr/bin:/bin:/usr/sbin:/sbin`, so CLIs installed by
/// npm, Homebrew, or installers under the home directory are invisible unless we also consult the
/// user's login-shell PATH and common install locations.
public enum ExecutableSearchPath {
  public static func directories(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let fallbacks = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.local/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.claude/local",
      "\(home)/.bun/bin",
      "\(home)/.volta/bin",
      "/usr/bin",
      "/bin",
    ]
    let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)

    var seen: Set<String> = []
    return (inherited + loginShellPath + fallbacks).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }

  /// PATH for child processes, so `#!/usr/bin/env node` style CLIs can find their runtime.
  public static func joined() -> String {
    directories().joined(separator: ":")
  }

  /// Resolved once per process; a login shell can take a moment to start.
  private static let loginShellPath: [String] = {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: shell) else { return [] }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }
    do {
      try process.run()
    } catch {
      return []
    }
    // Never let a slow or misbehaving shell profile block agent detection.
    guard semaphore.wait(timeout: .now() + 3) == .success else {
      process.terminate()
      return []
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
  }()
}

public func executablePath(named name: String) -> String? {
  for directory in ExecutableSearchPath.directories() {
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
  var environment = ProcessInfo.processInfo.environment
  environment["PATH"] = ExecutableSearchPath.joined()
  process.environment = environment
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
