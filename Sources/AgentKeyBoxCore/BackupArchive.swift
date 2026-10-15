import Foundation

/// Everything needed to rebuild AgentKeyBox on another Mac: projects, key metadata, and the keys.
public struct BackupContents: Codable, Equatable, Sendable {
  public var createdAt: Date
  public var appVersion: String
  public var projects: [Project]
  public var credentials: [CredentialMetadata]
  /// Key bytes by credential ID (UUID string).
  public var secrets: [String: Data]

  public init(
    createdAt: Date = Date(), appVersion: String = AgentKeyBoxVersion.current,
    projects: [Project], credentials: [CredentialMetadata], secrets: [String: Data]
  ) {
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.projects = projects
    self.credentials = credentials
    self.secrets = secrets
  }
}

public enum BackupError: Error, LocalizedError, Equatable {
  case passwordTooShort
  case notABackup
  case unsupportedVersion
  case wrongPasswordOrDamaged
  case alreadyOpen
  case diskImageFailed(String)

  public var errorDescription: String? {
    switch self {
    case .passwordTooShort:
      return L("Use a password of at least %@ characters.", "\(BackupArchive.minimumPasswordLength)")
    case .notABackup:
      return L("This file is not an AgentKeyBox backup.")
    case .unsupportedVersion:
      return L("This backup was made by a newer AgentKeyBox. Update AgentKeyBox and try again.")
    case .wrongPasswordOrDamaged:
      return L("Wrong password, or the backup file is damaged.")
    case .alreadyOpen:
      return L("This backup is open in Finder. Eject the AgentKeyBox Backup disk, then try again.")
    case .diskImageFailed(let detail):
      return L("macOS could not create or open the disk image: %@", detail)
    }
  }
}

/// A backup is an AES-256 encrypted macOS disk image (`.dmg`). Double-clicking it asks for the
/// password and opens a folder per project with that project's `.env` and key files (`.p8`,
/// `.pem`, `.json`) and a README, so the keys can be recovered without AgentKeyBox. A hidden
/// `.agentkeybox-backup.json` beside them holds the same projects and keys for **Import…**.
///
/// The plaintext is written only inside the encrypted image, which is mounted privately
/// (`-nobrowse`, under an owner-only folder) while it is filled and unmounted afterwards. The
/// format is described in docs/BACKUP_FORMAT.md.
public enum BackupArchive {
  public static let fileExtension = "dmg"
  public static let minimumPasswordLength = 12
  public static let volumeName = "AgentKeyBox Backup"
  static let dataFileName = ".agentkeybox-backup.json"
  static let readmeFileName = "README.txt"
  /// A visible copy of each folder's `.env`, which Finder hides.
  static let visibleEnvFileName = "env.txt"
  static let version = 1

  /// The hidden data file: the backup contents plus a format version.
  struct DataFile: Codable {
    var format = "agentkeybox-backup"
    var version: Int
    var contents: BackupContents
  }

  /// One file the image holds, by its path inside the volume.
  struct Entry: Equatable {
    var path: String
    var data: Data
  }

  // MARK: - Layout

  /// Every file the backup volume holds, in order: per-project folders with `.env` and key
  /// files, the README, the hidden data file, and a marker that keeps Spotlight from indexing
  /// the open volume. Pure, so the layout is testable without making a disk image.
  static func layout(_ contents: BackupContents) throws -> [Entry] {
    let projectsByID = Dictionary(
      contents.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var groups: [UUID?: [CredentialMetadata]] = [:]
    for credential in contents.credentials {
      let projectID = credential.projectID.flatMap { projectsByID[$0] == nil ? nil : $0 }
      groups[projectID, default: []].append(credential)
    }
    // Projects by name (ties in backup order), then keys without a project.
    let order: [UUID?] =
      contents.projects.enumerated()
      .sorted {
        let order = $0.element.name.localizedStandardCompare($1.element.name)
        return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
      }
      .map { Optional($0.element.id) }
      .filter { groups[$0] != nil }
      .reduce(into: [UUID?]()) { if !$0.contains($1) { $0.append($1) } }
      + (groups[nil] == nil ? [] : [nil])

    var entries: [Entry] = []
    var readme = [
      L("AgentKeyBox backup"),
      "",
      L("Created: %@", contents.createdAt.formatted(date: .long, time: .shortened)),
      "",
      L("Each folder is one project. Its .env file holds the project's keys; key files (.p8, .pem, .json) are the original files."),
      L("Finder hides .env because its name starts with a dot, so each folder also has env.txt with the same contents. To use it in a project, copy env.txt into the project folder and rename it to .env."),
      L("To restore everything into AgentKeyBox, choose Settings › Backup › Import… and pick this .dmg file."),
      L("Copies you take out of this disk image are not encrypted. Delete them when you no longer need them."),
      "",
    ]
    var folders: Set<String> = [readmeFileName.lowercased(), dataFileName.lowercased()]
    var restored = 0
    for projectID in order {
      let project = projectID.flatMap { projectsByID[$0] }
      let folder = unique(
        project.map { safeName($0.name, fallback: L("Project")) } ?? L("No project"),
        in: &folders)
      readme.append("\(folder)/")
      if let project { readme.append("  " + L("Folder on the original Mac: %@", project.rootPath)) }

      var envLines: [String] = []
      var files: Set<String> = [".env", visibleEnvFileName]
      let credentials = groups[projectID, default: []].sorted {
        $0.label.localizedStandardCompare($1.label) == .orderedAscending
      }
      for credential in credentials {
        let name = "\(credential.label) (\(credential.service))"
        guard let secret = contents.secrets[credential.id.uuidString] else {
          readme.append("  - " + L("%@: no key value, not included", name))
          continue
        }
        let variable = credential.injectionVariableName
        if !credential.isFileCredential, let variable,
          let text = String(data: secret, encoding: .utf8)
        {
          envLines.append(envLine(variable, text))
          readme.append("  - " + L("%@: in .env as %@", name, variable))
        } else {
          let file = unique(fileName(for: credential), in: &files)
          entries.append(Entry(path: "\(folder)/\(file)", data: secret))
          readme.append("  - " + L("%@: file %@", name, file))
        }
        for (key, value) in (credential.settings ?? [:]).sorted(by: { $0.key < $1.key })
        where ApprovedCommandRunner.isValidEnvironmentVariable(key) {
          envLines.append(envLine(key, value))
        }
        if let hosts = credential.allowedHosts, !hosts.isEmpty {
          readme.append("    " + L("Allowed hosts: %@", hosts.joined(separator: ", ")))
        }
        restored += 1
      }
      if !envLines.isEmpty {
        let env = Data(envLines.joined().utf8)
        entries.append(Entry(path: "\(folder)/.env", data: env))
        // The same contents under a name Finder shows, for people who don't know Command-Shift-.
        entries.append(Entry(path: "\(folder)/\(visibleEnvFileName)", data: env))
      }
      readme.append("")
    }
    readme.append(L("%@ key(s) in total.", "\(restored)"))

    entries.append(Entry(path: readmeFileName, data: Data((readme.joined(separator: "\n") + "\n").utf8)))
    // Default date and data encodings: lossless dates, keys as Base64.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(DataFile(version: version, contents: contents))
    entries.append(Entry(path: dataFileName, data: data))
    entries.append(Entry(path: ".metadata_never_index", data: Data()))
    return entries
  }

  /// The contents from a backup volume's hidden data file.
  static func contents(fromDataFile data: Data) throws -> BackupContents {
    struct Header: Decodable {
      var format: String
      var version: Int
    }
    guard let header = try? JSONDecoder().decode(Header.self, from: data),
      header.format == "agentkeybox-backup"
    else { throw BackupError.notABackup }
    guard header.version == version else { throw BackupError.unsupportedVersion }
    guard let file = try? JSONDecoder().decode(DataFile.self, from: data) else {
      throw BackupError.wrongPasswordOrDamaged
    }
    return file.contents
  }

  /// A `KEY=value` line that `EnvParser` and common dotenv loaders read back unchanged.
  static func envLine(_ key: String, _ value: String) -> String {
    let plain = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@+,=")
    if value.unicodeScalars.allSatisfy(plain.contains) { return "\(key)=\(value)\n" }
    var escaped = ""
    // By scalar: "\r\n" is one Character, which would slip past the cases below.
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      case "\n": escaped += "\\n"
      case "\r": escaped += "\\r"
      case "\t": escaped += "\\t"
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "\(key)=\"\(escaped)\"\n"
  }

  /// The original Apple name for App Store Connect keys, so tools that expect
  /// `AuthKey_<ID>.p8` find it; otherwise the label with the kind's extension.
  static func fileName(for credential: CredentialMetadata) -> String {
    let prefix = "App Store Connect key "
    if credential.kind == .p8, credential.label.hasPrefix(prefix) {
      let id = String(credential.label.dropFirst(prefix.count))
      if ProjectScanner.appStoreConnectKeyID(fromFileName: "AuthKey_\(id).p8") != nil {
        return "AuthKey_\(id).p8"
      }
    }
    let ext: String
    switch credential.kind {
    case .p8: ext = ".p8"
    case .pem: ext = ".pem"
    case .json: ext = ".json"
    default: ext = ".txt"
    }
    let base = safeName(credential.label, fallback: "key")
    return base.lowercased().hasSuffix(ext) ? base : base + ext
  }

  /// One path component: no separators, no leading dot, no control characters.
  static func safeName(_ text: String, fallback: String) -> String {
    var name = String(
      text.unicodeScalars.map { scalar -> Character in
        "/\\:".unicodeScalars.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
          ? "_" : Character(scalar)
      })
    name = name.trimmingCharacters(in: .whitespaces)
    while name.hasPrefix(".") { name.removeFirst() }
    name = String(name.prefix(100))
    return name.isEmpty ? fallback : name
  }

  /// The name, or `name 2`, `name 3`…; names are compared case-insensitively, as on APFS.
  static func unique(_ name: String, in taken: inout Set<String>) -> String {
    var candidate = name
    var number = 2
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    while taken.contains(candidate.lowercased()) {
      candidate = ext.isEmpty || stem.isEmpty ? "\(name) \(number)" : "\(stem) \(number).\(ext)"
      number += 1
    }
    taken.insert(candidate.lowercased())
    return candidate
  }

  /// Whether a backup taken at `backupSnapshot` (when its keys were read, not when the file
  /// was finished) holds every one of `keys` as it is now.
  public static func covers(_ keys: [CredentialMetadata], backupSnapshot: Date?) -> Bool {
    guard let backupSnapshot, !keys.isEmpty else { return false }
    return keys.allSatisfy { max($0.createdAt, $0.updatedAt) <= backupSnapshot }
  }

  /// What importing `contents` adds next to what is already here. Projects already here (same
  /// ID or same folder) are reused and never count as added, so undoing a failed import can
  /// remove exactly `newProjects` without touching projects that existed before.
  public struct ImportPlan: Equatable, Sendable {
    public var newProjects: [Project]
    /// Backup project ID → the project the keys join here.
    public var projectIDs: [UUID: UUID]
    /// Keys not already here, moved to their project here. Their values are in the backup.
    public var newCredentials: [CredentialMetadata]
  }

  public static func importPlan(
    _ contents: BackupContents, existingProjects: [Project],
    existingCredentialIDs: Set<UUID>
  ) -> ImportPlan {
    var known = existingProjects
    var newProjects: [Project] = []
    var projectIDs: [UUID: UUID] = [:]
    for project in contents.projects {
      if let existing = known.first(where: {
        $0.id == project.id
          || ProjectScopeResolver.normalize($0.rootPath)
            == ProjectScopeResolver.normalize(project.rootPath)
      }) {
        projectIDs[project.id] = existing.id
      } else {
        known.append(project)
        newProjects.append(project)
        projectIDs[project.id] = project.id
      }
    }
    var newCredentials: [CredentialMetadata] = []
    for var credential in contents.credentials
    where !existingCredentialIDs.contains(credential.id)
      && contents.secrets[credential.id.uuidString] != nil
    {
      credential.projectID = credential.projectID.flatMap { projectIDs[$0] ?? $0 }
      newCredentials.append(credential)
    }
    return ImportPlan(
      newProjects: newProjects, projectIDs: projectIDs, newCredentials: newCredentials)
  }

  // MARK: - Disk image

  /// Writes the backup to `url` as an encrypted disk image, replacing any file there only once
  /// the new image is complete.
  public static func write(_ contents: BackupContents, password: String, to url: URL) throws {
    guard password.count >= minimumPasswordLength else { throw BackupError.passwordTooShort }
    let entries = try layout(contents)
    let fileManager = FileManager.default
    // On the destination's volume, so the finished image can be swapped in place.
    let work = try fileManager.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
    defer { try? fileManager.removeItem(at: work) }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
    let image = work.appendingPathComponent("backup.dmg")

    let payload = entries.reduce(0) { $0 + $1.data.count }
    let megabytes = max(4, payload * 2 / 1_000_000 + 4)
    try hdiutil(
      [
        "create", "-quiet", "-size", "\(megabytes)m", "-fs", "APFS", "-encryption", "AES-256",
        "-stdinpass", "-volname", volumeName, "-type", "UDIF", image.path,
      ], password: password)

    try withMountedImage(image, password: password, readOnly: false) { volume in
      for entry in entries {
        let file = volume.appendingPathComponent(entry.path)
        let folder = file.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: folder.path) {
          try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        }
        guard
          fileManager.createFile(
            atPath: file.path, contents: entry.data, attributes: [.posixPermissions: 0o600])
        else { throw BackupError.diskImageFailed(entry.path) }
      }
    }
    // The finished backup is a compressed, read-only copy. Finder opens a read-only image's
    // window by itself after the password, while a read-write image mounts silently (easy to
    // miss with Stage Manager or a hidden desktop). It is made from the encrypted image's
    // device, so the files never exist outside encryption.
    let finished = work.appendingPathComponent("AgentKeyBox Backup.dmg")
    try withAttachedDevice(image, password: password) { device -> Void in
      _ = try hdiutil(
        [
          "create", "-quiet", "-srcdevice", device, "-format", "UDZO", "-encryption", "AES-256",
          "-stdinpass", finished.path,
        ], password: password)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finished.path)
    if fileManager.fileExists(atPath: url.path) {
      _ = try fileManager.replaceItemAt(url, withItemAt: finished)
    } else {
      try fileManager.moveItem(at: finished, to: url)
    }
  }

  /// Attaches the image without mounting any volume, runs `body` with its whole-disk device
  /// (such as `/dev/disk12`), and always detaches it.
  static func withAttachedDevice<T>(
    _ image: URL, password: String, _ body: (String) throws -> T
  ) throws -> T {
    let plist = try hdiutil(
      ["attach", "-plist", "-stdinpass", "-nomount", "-noverify", image.path], password: password)
    guard
      let info = try? PropertyListSerialization.propertyList(from: plist, format: nil)
        as? [String: Any],
      let entities = info["system-entities"] as? [[String: Any]],
      let device = entities.compactMap({ $0["dev-entry"] as? String })
        .min(by: { $0.count < $1.count })
    else { throw BackupError.diskImageFailed("hdiutil attach") }
    defer {
      if (try? hdiutil(["detach", "-quiet", device], password: nil)) == nil {
        _ = try? hdiutil(["detach", "-quiet", "-force", device], password: nil)
      }
    }
    return try body(device)
  }

  /// Opens a backup disk image with its password and reads its contents.
  public static func read(from url: URL, password: String) throws -> BackupContents {
    // An unencrypted image is not something AgentKeyBox made; refuse before asking for it.
    guard let plist = try? hdiutil(["isencrypted", "-plist", url.path], password: nil),
      let info = try? PropertyListSerialization.propertyList(from: plist, format: nil)
        as? [String: Any],
      info["encrypted"] as? Bool == true
    else { throw BackupError.notABackup }
    // macOS will not attach the same image twice, which would otherwise look like a wrong
    // password. Reading the disk Finder opened would skip the password, so ask to eject it.
    if isAttached(url) { throw BackupError.alreadyOpen }
    do {
      return try withMountedImage(url, password: password, readOnly: true) { volume in
        let file = volume.appendingPathComponent(dataFileName)
        guard let data = try? Data(contentsOf: file) else { throw BackupError.notABackup }
        return try contents(fromDataFile: data)
      }
    } catch BackupError.diskImageFailed {
      throw BackupError.wrongPasswordOrDamaged
    }
  }

  /// Whether macOS has this image file attached right now (for example opened in Finder).
  static func isAttached(_ url: URL) -> Bool {
    guard let plist = try? hdiutil(["info", "-plist"], password: nil),
      let info = try? PropertyListSerialization.propertyList(from: plist, format: nil)
        as? [String: Any],
      let images = info["images"] as? [[String: Any]]
    else { return false }
    return images.compactMap { $0["image-path"] as? String }.contains {
      sameFile($0, url.path)
    }
  }

  static func sameFile(_ a: String, _ b: String) -> Bool {
    let fileManager = FileManager.default
    guard let first = try? fileManager.attributesOfItem(atPath: a),
      let second = try? fileManager.attributesOfItem(atPath: b)
    else { return false }
    return (first[.systemFileNumber] as? NSNumber) == (second[.systemFileNumber] as? NSNumber)
      && (first[.systemNumber] as? NSNumber) == (second[.systemNumber] as? NSNumber)
  }

  /// Mounts the image under a fresh owner-only folder, hidden from Finder, runs `body`, and
  /// always unmounts it.
  static func withMountedImage<T>(
    _ image: URL, password: String, readOnly: Bool, _ body: (URL) throws -> T
  ) throws -> T {
    let fileManager = FileManager.default
    let mountPoint = fileManager.temporaryDirectory
      .appendingPathComponent("AgentKeyBox-backup-\(UUID().uuidString)")
    try fileManager.createDirectory(
      at: mountPoint, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fileManager.removeItem(at: mountPoint) }
    var arguments = [
      "attach", "-quiet", "-stdinpass", "-nobrowse", "-noautoopen", "-noverify",
      "-mountpoint", mountPoint.path,
    ]
    if readOnly { arguments.append("-readonly") }
    try hdiutil(arguments + [image.path], password: password)
    defer {
      if (try? hdiutil(["detach", "-quiet", mountPoint.path], password: nil)) == nil {
        _ = try? hdiutil(["detach", "-quiet", "-force", mountPoint.path], password: nil)
      }
    }
    return try body(mountPoint)
  }

  /// Runs `/usr/bin/hdiutil`, giving it the password on standard input (never as an argument,
  /// where other processes could see it). Returns standard output.
  @discardableResult
  static func hdiutil(_ arguments: [String], password: String?) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
    } catch {
      throw BackupError.diskImageFailed(error.localizedDescription)
    }
    if let password { input.fileHandleForWriting.write(Data(password.utf8)) }
    try? input.fileHandleForWriting.close()
    let result = output.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: message, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw BackupError.diskImageFailed(text.isEmpty ? "hdiutil \(arguments[0])" : text)
    }
    return result
  }
}
