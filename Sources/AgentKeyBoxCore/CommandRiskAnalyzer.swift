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
  public static func assess(executablePath: String, arguments: [String]) -> CommandRiskAssessment {
    let name = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
    let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "osascript"]
    let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "php"]
    let networkTools: Set<String> = ["curl", "wget", "ssh", "scp", "sftp", "nc", "ncat", "telnet"]

    var reasons: [String] = []
    var level: CommandRiskLevel = .normal

    if shells.contains(name) || interpreters.contains(name) {
      level = .high
      reasons.append(
        "This executable can run arbitrary code, which could transmit the credential elsewhere.")
    } else if networkTools.contains(name) {
      level = .high
      reasons.append("This executable can send data over the network.")
    }

    if arguments.contains(where: { $0.contains("http://") || $0.contains("https://") }) {
      if level == .normal { level = .elevated }
      reasons.append("The command includes a network URL.")
    }

    if arguments.contains(where: { $0 == "-c" || $0 == "--eval" || $0 == "-e" }) {
      level = .high
      reasons.append("The command includes an inline code or shell execution flag.")
    }

    return CommandRiskAssessment(level: level, reasons: Array(Set(reasons)).sorted())
  }
}
