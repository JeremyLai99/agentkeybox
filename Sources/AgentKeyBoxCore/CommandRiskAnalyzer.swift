import Foundation

public enum CommandRiskLevel: String, Codable, Sendable {
  case normal
  case elevated
  case high
}

public struct CommandRiskAssessment: Codable, Hashable, Sendable {
  public var level: CommandRiskLevel
  public var reasons: [String]

  public init(level: CommandRiskLevel, reasons: [String] = []) {
    self.level = level
    self.reasons = reasons
  }
}

public enum CommandRiskAnalyzer {
  static let shells: Set<String> = [
    "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "pwsh", "osascript",
  ]
  static let interpreters: Set<String> = [
    "python", "node", "ruby", "perl", "php", "deno", "bun", "lua",
  ]
  /// Run whatever program their arguments name.
  static let launchers: Set<String> = ["env", "xargs", "sudo", "nohup", "time", "exec", "open"]
  /// Execute code defined in project files (package.json scripts, Makefile, build files).
  static let projectRunners: Set<String> = [
    "npm", "npx", "pnpm", "pnpx", "yarn", "make", "just", "cargo", "go", "gradle", "gradlew",
    "mvn", "rake", "bundle", "poetry", "uv", "pipenv", "tox", "swift", "docker",
  ]
  static let networkTools: Set<String> = [
    "curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "telnet", "socat", "rsync", "ftp",
    "http", "xh", "aria2c", "openssl",
  ]
  static let inlineCodeFlags: Set<String> = ["-c", "-e", "--eval", "--command", "-Command"]

  public static func assess(
    executablePath: String, arguments: [String], projectPath: String? = nil
  ) -> CommandRiskAssessment {
    let name = baseName(URL(fileURLWithPath: executablePath).lastPathComponent)

    var reasons: [String] = []
    var level: CommandRiskLevel = .normal
    func raise(_ newLevel: CommandRiskLevel, _ reason: String) {
      if newLevel == .high || level == .normal { level = newLevel }
      reasons.append(reason)
    }

    if shells.contains(name) || interpreters.contains(name) {
      raise(.high, "This executable can run arbitrary code, which could transmit the credential elsewhere.")
    } else if launchers.contains(name) {
      raise(.high, "This executable launches another program named in its arguments.")
    } else if networkTools.contains(name) {
      raise(.high, "This executable can send data over the network.")
    } else if projectRunners.contains(name) {
      raise(
        .elevated,
        "This tool runs scripts defined in the project (package.json, Makefile, …), which the agent can edit before asking."
      )
    }

    if let projectPath,
      ProjectScopeResolver.contains(projectRoot: projectPath, requestPath: executablePath)
    {
      raise(.elevated, "The executable is a file inside the project, which the agent can edit.")
    }

    if arguments.contains(where: { $0.contains("http://") || $0.contains("https://") }) {
      raise(.elevated, "The command includes a network URL.")
    }

    if arguments.contains(where: { inlineCodeFlags.contains($0) }) {
      raise(.high, "The command includes an inline code or shell execution flag.")
    }

    return CommandRiskAssessment(level: level, reasons: Array(Set(reasons)).sorted())
  }

  /// `python3.12` → `python`, `node22` → `node`, `Bash` → `bash`.
  static func baseName(_ fileName: String) -> String {
    let lower = fileName.lowercased()
    let trimmed = lower.reversed().drop(while: { $0.isNumber || $0 == "." })
    let base = String(trimmed.reversed())
    return base.isEmpty ? lower : base
  }
}
