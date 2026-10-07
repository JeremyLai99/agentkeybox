import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// What dropping a project folder onto AgentKeyBox finds, so setup is one confirmation instead
/// of a series of file pickers.
public struct ProjectScan: Sendable {
  public struct Secret: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public var key: String
    public var value: String
    /// Path relative to the project root, e.g. `.env.local`.
    public var sourceFile: String
    /// Preselected in the setup list; settings such as PORT start unselected.
    public var looksSecret: Bool
  }

  public struct KeyFile: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public var url: URL
    public var relativePath: String
    public var kind: CredentialKind
    public var service: String
    public var label: String
    /// App Store Connect key ID from `AuthKey_<ID>.p8`.
    public var keyID: String?
  }

  public var root: URL
  public var secrets: [Secret]
  public var keyFiles: [KeyFile]
  /// `.env` files (relative paths) that the project's git ignore rules do not cover.
  public var envFilesNotIgnored: [String]

  public var projectName: String { root.lastPathComponent }
}

public enum ProjectScanner {
  /// Dependency, build, and VCS directories that never hold the project's own keys.
  static let skippedDirectories: Set<String> = [
    "node_modules", "build", "dist", "out", "target", "vendor", "Pods", "DerivedData", "venv",
    "__pycache__", "coverage",
  ]
  /// Committed templates that contain placeholders, not secrets.
  static let templateSuffixes = ["example", "sample", "template", "dist", "defaults"]
  static let maxFileBytes = 256 * 1024

  public static func scan(_ root: URL, maxDepth: Int = 3) -> ProjectScan {
    let root = root.standardizedFileURL
    var envFiles: [URL] = []
    var keyFiles: [ProjectScan.KeyFile] = []

    walk(root, depth: 0, maxDepth: maxDepth) { file in
      let name = file.lastPathComponent
      if isEnvFile(name) {
        envFiles.append(file)
      } else if let keyFile = keyFile(at: file, root: root) {
        keyFiles.append(keyFile)
      }
    }

    // One entry per variable. Local overrides win over shared files (dotenv convention), then
    // shallower files over nested ones.
    var secrets: [String: (secret: ProjectScan.Secret, rank: (Int, Int))] = [:]
    for file in envFiles {
      guard let data = try? Data(contentsOf: file), data.count <= maxFileBytes,
        let text = String(data: data, encoding: .utf8)
      else { continue }
      let relative = relativePath(file, root: root)
      let rank = (
        file.lastPathComponent.contains("local") ? 1 : 0,
        -relative.split(separator: "/").count
      )
      for (key, value) in EnvParser.parse(text) where !value.isEmpty {
        if let existing = secrets[key], existing.rank >= rank { continue }
        secrets[key] = (
          ProjectScan.Secret(
            key: key, value: value, sourceFile: relative,
            looksSecret: EnvImportClassifier.looksSecret(key: key, value: value)),
          rank
        )
      }
    }

    let envRelative = envFiles.map { relativePath($0, root: root) }.sorted()
    return ProjectScan(
      root: root,
      secrets: secrets.values.map(\.secret).sorted { $0.key < $1.key },
      keyFiles: keyFiles.sorted { $0.relativePath < $1.relativePath },
      envFilesNotIgnored: GitIgnore.unignored(envRelative, in: root))
  }

  public static func isEnvFile(_ name: String) -> Bool {
    guard name == ".env" || name.hasPrefix(".env.") else { return false }
    let suffix = name.split(separator: ".").last.map(String.init) ?? ""
    return !templateSuffixes.contains(suffix.lowercased())
  }

  /// `AuthKey_ABC123DEF4.p8` → `ABC123DEF4`.
  public static func appStoreConnectKeyID(fromFileName name: String) -> String? {
    guard name.hasPrefix("AuthKey_"), name.lowercased().hasSuffix(".p8") else { return nil }
    let id = name.dropFirst("AuthKey_".count).dropLast(3)
    return id.isEmpty || !id.allSatisfy({ $0.isLetter || $0.isNumber }) ? nil : String(id)
  }

  private static func keyFile(at file: URL, root: URL) -> ProjectScan.KeyFile? {
    let name = file.lastPathComponent
    let ext = file.pathExtension.lowercased()
    guard ["p8", "pem", "json"].contains(ext),
      let data = try? Data(contentsOf: file), data.count <= maxFileBytes
    else { return nil }
    let relative = relativePath(file, root: root)
    let text = String(decoding: data, as: UTF8.self)

    switch ext {
    case "p8":
      guard text.contains("PRIVATE KEY") else { return nil }
      let keyID = appStoreConnectKeyID(fromFileName: name)
      return ProjectScan.KeyFile(
        url: file, relativePath: relative, kind: .p8,
        service: keyID != nil ? "Apple App Store Connect" : "Apple",
        label: keyID.map { "App Store Connect key \($0)" } ?? name, keyID: keyID)
    case "pem":
      // Certificates and public keys are not secrets; only private keys are worth storing.
      guard text.contains("PRIVATE KEY") else { return nil }
      return ProjectScan.KeyFile(
        url: file, relativePath: relative, kind: .pem, service: "Private key", label: name,
        keyID: nil)
    default:
      guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["type"] as? String == "service_account", object["private_key"] != nil
      else { return nil }
      let project = object["project_id"] as? String
      return ProjectScan.KeyFile(
        url: file, relativePath: relative, kind: .json, service: "Google service account",
        label: project.map { "\($0) service account" } ?? name, keyID: nil)
    }
  }

  private static func walk(
    _ directory: URL, depth: Int, maxDepth: Int, visit: (URL) -> Void
  ) {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true { continue }
      let name = entry.lastPathComponent
      if values?.isDirectory == true {
        // Hidden directories (.git, .next, .venv) and dependency/build output are skipped.
        guard depth < maxDepth, !name.hasPrefix("."), !skippedDirectories.contains(name) else {
          continue
        }
        walk(entry, depth: depth + 1, maxDepth: maxDepth, visit: visit)
      } else {
        visit(entry)
      }
    }
  }

  static func relativePath(_ file: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = file.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return file.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }
}

/// The subset of `.gitignore` semantics needed to tell whether `.env` files are ignored:
/// basename patterns, root-anchored patterns, `*`/`?` globs, and `!` negation. Rules come from
/// the project's own `.gitignore` and, for a project inside a larger repository, the repository
/// root's `.gitignore`.
public enum GitIgnore {
  public static func unignored(_ relativePaths: [String], in projectRoot: URL) -> [String] {
    guard let repositoryRoot = repositoryRoot(containing: projectRoot) else { return [] }
    var sources: [(base: URL, rules: [String])] = []
    for base in Set([repositoryRoot.path, projectRoot.path]).sorted().map({
      URL(fileURLWithPath: $0)
    }) {
      if let text = try? String(
        contentsOf: base.appendingPathComponent(".gitignore"), encoding: .utf8)
      {
        sources.append((base, rules(from: text)))
      }
    }
    return relativePaths.filter { relative in
      let absolute = projectRoot.appendingPathComponent(relative).path
      var ignored = false
      for source in sources {
        let pathFromBase = String(absolute.dropFirst(source.base.path.count + 1))
        for rule in source.rules {
          let negated = rule.hasPrefix("!")
          let pattern = negated ? String(rule.dropFirst()) : rule
          if matches(pattern, path: pathFromBase) { ignored = !negated }
        }
      }
      return !ignored
    }
  }

  static func rules(from text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }

  static func matches(_ rawPattern: String, path: String) -> Bool {
    var pattern = rawPattern
    if pattern.hasSuffix("/") { return false }  // directory-only rules never match these files
    if pattern.hasPrefix("**/") { pattern.removeFirst(3) }
    if pattern.hasPrefix("/") {
      return fnmatch(String(pattern.dropFirst()), path, 0) == 0
    }
    if pattern.contains("/") {
      return fnmatch(pattern, path, 0) == 0
    }
    let name = path.split(separator: "/").last.map(String.init) ?? path
    return fnmatch(pattern, name, 0) == 0
  }

  /// Appends the given file names to the project's `.gitignore`, creating it if needed.
  public static func addEntries(_ names: [String], to projectRoot: URL) throws {
    guard !names.isEmpty else { return }
    let url = projectRoot.appendingPathComponent(".gitignore")
    var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
    if !text.isEmpty { text += "\n" }
    text += "# Local secrets (stored in AgentKeyBox)\n"
    text += names.map { "/\($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Walks up to the nearest directory containing `.git`, stopping at the home directory or the
  /// filesystem root. (`URL("/").deletingLastPathComponent()` yields `/..`, so the root must be
  /// checked explicitly or the walk never ends.)
  static func repositoryRoot(containing directory: URL) -> URL? {
    var current = directory.standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    while true {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
        return current
      }
      if current.path == "/" || current.path == home { return nil }
      current = current.deletingLastPathComponent().standardizedFileURL
    }
  }
}
