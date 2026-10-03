import Foundation

public enum BrokerTokenError: Error, LocalizedError, Equatable {
  case invalidTokenFile

  public var errorDescription: String? {
    switch self {
    case .invalidTokenFile:
      return
        "AgentKeyBox broker authentication token is unavailable. Open AgentKeyBox once and try again."
    }
  }
}

public final class BrokerTokenStore: @unchecked Sendable {
  public let fileURL: URL
  private let lock = NSLock()

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
        .appendingPathComponent("broker-token")
    }
  }

  public func load() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    return try loadUnlocked()
  }

  public func loadOrCreate() throws -> String {
    lock.lock()
    defer { lock.unlock() }

    if let token = try? loadUnlocked(), !token.isEmpty {
      return token
    }

    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let token = Self.generateToken()
    let data = Data((token + "\n").utf8)
    _ = FileManager.default.createFile(
      atPath: fileURL.path,
      contents: data,
      attributes: [.posixPermissions: 0o600]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return token
  }

  private func loadUnlocked() throws -> String {
    let data = try Data(contentsOf: fileURL)
    guard
      let token = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      token.count >= 32
    else {
      throw BrokerTokenError.invalidTokenFile
    }
    return token
  }

  private static func generateToken() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    return Data(bytes).base64EncodedString()
  }
}
