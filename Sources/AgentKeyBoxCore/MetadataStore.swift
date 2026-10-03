import Foundation

public struct MetadataSnapshot: Codable, Sendable {
  public var projects: [Project]
  public var credentials: [CredentialMetadata]

  public init(projects: [Project] = [], credentials: [CredentialMetadata] = []) {
    self.projects = projects
    self.credentials = credentials
  }
}

public final class MetadataStore: @unchecked Sendable {
  private let fileURL: URL
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder = JSONDecoder()

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentkeybox")
      self.fileURL =
        base
        .appendingPathComponent("AgentKeyBox", isDirectory: true)
        .appendingPathComponent("metadata.json")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder = encoder
  }

  public func load() -> MetadataSnapshot {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try? Data(contentsOf: fileURL),
      let snapshot = try? decoder.decode(MetadataSnapshot.self, from: data)
    else {
      return MetadataSnapshot()
    }
    return snapshot
  }

  public func save(_ snapshot: MetadataSnapshot) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}
