import Foundation

/// Keeps coding agents away from the key files a project still has on disk after setup.
///
/// Setup copies keys into the Keychain but leaves `.env` and key files where they are, as the
/// user's backup. An agent that reads them would bypass AgentKeyBox entirely, so setup can:
/// - add Claude Code `Read` deny rules for them to `.claude/settings.local.json`. Claude Code
///   applies these to its file tools and to file commands it recognizes in Bash (`cat`, `head`,
///   ...), though not to every indirect read; only removing the plaintext closes that gap.
/// - add a short, marked section to `AGENTS.md` and `CLAUDE.md` telling agents to use
///   AgentKeyBox's tools instead. Codex has no per-file deny setting, so this is its only guard.
public enum AgentGuard {
  static let startMarker = "<!-- agentkeybox:start -->"
  static let endMarker = "<!-- agentkeybox:end -->"

  /// The section written to `AGENTS.md` and `CLAUDE.md`. English, the language agents follow
  /// most reliably.
  public static let instructions = """
    \(startMarker)
    ## API keys (AgentKeyBox)

    This project's API keys are stored in AgentKeyBox on this Mac, not in files.

    - Use the AgentKeyBox MCP tools: `list_credentials`, then `http_request` for HTTPS APIs or `run_with_secret` for local commands. If a key is missing, call `request_credential`.
    - Do not open, print, copy, or search `.env` files or key files (`.p8`, `.pem`, service-account JSON), even if they exist.
    - Never ask the user to paste a key into the chat.
    \(endMarker)
    """

  /// Claude Code deny rules. Bare names follow gitignore rules and match at any depth below the
  /// session's directory; committed templates such as `.env.example` stay readable.
  public static func claudeDenyRules(keyFileNames: [String]) -> [String] {
    var rules = ["Read(.env)", "Read(.env.*)"]
    rules += ProjectScanner.templateSuffixes.map { "Read(!.env.\($0))" }
    rules += Set(keyFileNames).sorted().map { "Read(\($0))" }
    return rules
  }

  /// Adds the rules to `.claude/settings.local.json` under `root`, keeping everything already
  /// there. A file that is not a JSON object is left untouched and reported as an error.
  public static func addClaudeDenyRules(_ rules: [String], root: URL) throws {
    let directory = root.appendingPathComponent(".claude", isDirectory: true)
    let file = directory.appendingPathComponent("settings.local.json")
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: file), !data.isEmpty {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AgentGuardError.unreadableSettings(file.path)
      }
      settings = object
    }
    var permissions = settings["permissions"] as? [String: Any] ?? [:]
    var deny = permissions["deny"] as? [String] ?? []
    // Negations only carve out of rules listed before them, so new rules go first.
    let missing = rules.filter { !deny.contains($0) }
    guard !missing.isEmpty else { return }
    let positive = missing.filter { !$0.hasPrefix("Read(!") }
    let negations = missing.filter { $0.hasPrefix("Read(!") }
    deny = positive + deny + negations
    permissions["deny"] = deny
    settings["permissions"] = permissions
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: file, options: .atomic)
  }

  /// Adds or refreshes the marked section in a Markdown file, creating the file if needed.
  /// Text outside the markers is never changed.
  public static func writeInstructions(to file: URL) throws {
    var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    if let start = text.range(of: startMarker), let end = text.range(of: endMarker),
      start.lowerBound < end.upperBound
    {
      text.replaceSubrange(start.lowerBound..<end.upperBound, with: instructions)
    } else {
      if !text.isEmpty { text += text.hasSuffix("\n") ? "\n" : "\n\n" }
      text += instructions + "\n"
    }
    try text.write(to: file, atomically: true, encoding: .utf8)
  }

  /// Guards a set-up project: deny rules where Claude Code loads local settings (the git
  /// repository root, or the project folder outside git) and instructions in the project.
  public static func protect(projectRoot: URL, keyFileNames: [String]) throws {
    let settingsRoot = GitIgnore.repositoryRoot(containing: projectRoot) ?? projectRoot
    try addClaudeDenyRules(claudeDenyRules(keyFileNames: keyFileNames), root: settingsRoot)
    try writeInstructions(to: projectRoot.appendingPathComponent("AGENTS.md"))
    try writeInstructions(to: projectRoot.appendingPathComponent("CLAUDE.md"))
  }
}

public enum AgentGuardError: Error, LocalizedError, Equatable {
  case unreadableSettings(String)

  public var errorDescription: String? {
    switch self {
    case .unreadableSettings(let path):
      return L("%@ is not valid JSON, so it was left unchanged.", path)
    }
  }
}
