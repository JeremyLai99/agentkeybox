import Foundation

/// Approval decisions persisted across launches, so the app can show "Used by Claude Code ·
/// 2 min ago" per key. Holds metadata only (agent, key label and IDs, project path, decision,
/// time) — never secret values. Kept to the most recent `limit` events in an owner-only file.
public final class AccessLogStore: @unchecked Sendable {
  private let fileURL: URL
  private let limit: Int
  private let lock = NSLock()
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  public init(fileURL: URL? = nil, limit: Int = 500) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentkeybox")
      self.fileURL =
        base
        .appendingPathComponent("AgentKeyBox", isDirectory: true)
        .appendingPathComponent("access-log.json")
    }
    self.limit = limit
  }

  /// Newest first. A missing or unreadable log is treated as empty; it is only history.
  public func load() -> [AccessEvent] {
    lock.withLock {
      guard let data = try? Data(contentsOf: fileURL),
        let events = try? decoder.decode([AccessEvent].self, from: data)
      else { return [] }
      return events.sorted { $0.timestamp > $1.timestamp }
    }
  }

  /// Appends an event and returns the updated log, newest first.
  @discardableResult
  public func append(_ event: AccessEvent) throws -> [AccessEvent] {
    var events = load()
    events.insert(event, at: 0)
    events = Array(events.prefix(limit))
    try lock.withLock {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try encoder.encode(events).write(to: fileURL, options: [.atomic])
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    return events
  }
}

extension Array where Element == AccessEvent {
  /// The most recent time this key was actually used (allowed), if ever.
  public func lastUse(of credentialID: UUID) -> AccessEvent? {
    first { $0.decision != .deny && ($0.credentialIDs ?? []).contains(credentialID) }
  }
}
