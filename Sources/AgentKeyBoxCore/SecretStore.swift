import Foundation

public protocol SecretStore: Sendable {
  func save(secret: Data, id: UUID) throws
  func read(id: UUID) throws -> Data?
  func delete(id: UUID) throws
}

public enum SecretStoreError: Error, Equatable {
  case unsupportedPlatform
  case unexpectedStatus(Int32)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: Data] = [:]

  public init() {}

  public func save(secret: Data, id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    values[id] = secret
  }

  public func read(id: UUID) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[id]
  }

  public func delete(id: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: id)
  }
}
