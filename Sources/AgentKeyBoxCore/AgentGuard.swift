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
  ///
  /// `ledger` remembers every rule AgentKeyBox has written to each settings file. Every other
  /// rule, including one identical to ours that the user wrote, is the user's and is never
  /// weakened. A negation we wrote that is gone was removed by the user and is not added back;
  /// a deny rule we wrote that is gone is added back, since that only tightens access.
  public static func addClaudeDenyRules(
    _ rules: [String], root: URL, ledger: GuardRuleLedger = .shared
  ) throws {
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
    let written = ledger.rules(for: root)
    let owned = written.intersection(deny)
    // Negations only carve out of rules listed before them, so new rules go first.
    let ourPositives = rules.filter { !$0.hasPrefix("Read(!") }
    let ourNegations = rules.filter { $0.hasPrefix("Read(!") }
    // A negation lifts every deny listed before it for that file name, at any depth: the
    // user's `Read(config/.env.example)`, `Read(.env.*)`, or `Read(secrets/**)` alike. So a
    // template that any of the user's own rules could cover stays denied.
    let usersPatterns = deny.filter { !$0.hasPrefix("Read(!") && !owned.contains($0) }
      .compactMap(readPattern)
    let conflicting = Set(
      ourNegations.filter { negation in
        guard let pattern = readPattern(negation) else { return true }
        let name = String(pattern.dropFirst())
        return usersPatterns.contains { couldMatch($0, fileNamed: name) }
      })
    let positive = ourPositives.filter { !deny.contains($0) }
    let negations = ourNegations.filter {
      !deny.contains($0) && !conflicting.contains($0) && !written.contains($0)
    }
    // Only a negation AgentKeyBox wrote may be taken back; the user's own stay.
    let withdrawn = owned.intersection(conflicting)
    let kept = deny.filter { !withdrawn.contains($0) }
    guard !positive.isEmpty || !negations.isEmpty || !withdrawn.isEmpty else { return }
    deny = positive + kept + negations
    permissions["deny"] = deny
    settings["permissions"] = permissions
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    ledger.setRules(written.union(positive).union(negations), for: root)
  }

  /// Whether a `Read` pattern could match some file named `name` at any depth: its last path
  /// component (`**` read as `*`) matches the name.
  static func couldMatch(_ pattern: String, fileNamed name: String) -> Bool {
    var last = pattern.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
      ?? pattern
    if last.isEmpty { last = "*" }  // a directory rule such as `secrets/` covers everything in it
    last = last.replacingOccurrences(of: "**", with: "*")
    return fnmatch(last, name, 0) == 0
  }

  /// The path pattern inside `Read(...)`, without a leading `./`; nil for other rules.
  static func readPattern(_ rule: String) -> String? {
    guard rule.hasPrefix("Read("), rule.hasSuffix(")") else { return nil }
    var pattern = String(rule.dropFirst("Read(".count).dropLast())
    if pattern.hasPrefix("./") { pattern.removeFirst(2) }
    return pattern.isEmpty ? nil : pattern
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
  public static func protect(
    projectRoot: URL, keyFileNames: [String], ledger: GuardRuleLedger = .shared
  ) throws {
    let settingsRoot = GitIgnore.repositoryRoot(containing: projectRoot) ?? projectRoot
    try addClaudeDenyRules(
      claudeDenyRules(keyFileNames: keyFileNames), root: settingsRoot, ledger: ledger)
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

/// Every deny rule AgentKeyBox has written, per Claude Code settings file, kept in AgentKeyBox's
/// own folder (not in the user's repository). Rules stay listed after they are removed, so a
/// removal is remembered. Without a record, every rule counts as the user's.
public final class GuardRuleLedger: @unchecked Sendable {
  public static let shared = GuardRuleLedger()
  private let fileURL: URL
  private let lock = NSLock()

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentkeybox")
      self.fileURL = base.appendingPathComponent("AgentKeyBox/guard-rules.json")
    }
  }

  /// The rules AgentKeyBox has ever written to `<root>/.claude/settings.local.json`.
  public func rules(for root: URL) -> Set<String> {
    lock.withLock { Set(load()[key(root)] ?? []) }
  }

  func setRules(_ rules: Set<String>, for root: URL) {
    lock.withLock {
      var all = load()
      all[key(root)] = rules.sorted()
      let directory = fileURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) {
        try? data.write(to: fileURL, options: .atomic)
      }
    }
  }

  /// Keyed by the settings file under the resolved root folder, which exists even before the
  /// settings file does.
  private func key(_ root: URL) -> String {
    ProjectScopeResolver.normalize(root.path) + "/.claude/settings.local.json"
  }

  private func load() -> [String: [String]] {
    guard let data = try? Data(contentsOf: fileURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
    else { return [:] }
    return object
  }
}
