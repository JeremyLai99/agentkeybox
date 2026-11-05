import Foundation

/// An isolated native-acceptance profile. Release builds cannot select this profile.
/// Storage is isolated. The optional DEBUG recovery fixture pins its own loopback certificate;
/// native authentication and production browser policy are unchanged.
public struct DevelopmentProfile: Sendable {
  public let id: UUID
  public var directory: URL {
    URL(fileURLWithPath: "/private/tmp/akb-qa-\(id.uuidString)", isDirectory: true)
  }
  public var keychainService: String { "dev.agentkeybox.qa.\(id.uuidString)" }
  public var preferencesDomain: String { "dev.agentkeybox.qa.\(id.uuidString)" }
  public func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

  #if DEBUG
    enum ConfigurationError: Error {
      case invalidProfile
    }

    /// Launch Services can reopen a QA app without the runner's environment. A QA bundle
    /// must never fall back to the production vault or replace the installed helper.
    static func selectedID(value: String?, bundleIdentifier: String?) throws -> UUID? {
      let prefix = "dev.agentkeybox.qa."
      let bundledID: UUID?
      if let bundleIdentifier, bundleIdentifier.hasPrefix(prefix) {
        guard let id = UUID(uuidString: String(bundleIdentifier.dropFirst(prefix.count))) else {
          throw ConfigurationError.invalidProfile
        }
        bundledID = id
      } else {
        bundledID = nil
      }
      guard let value else {
        guard bundledID == nil else { throw ConfigurationError.invalidProfile }
        return nil
      }
      guard let id = UUID(uuidString: value), bundledID == nil || bundledID == id else {
        throw ConfigurationError.invalidProfile
      }
      return id
    }

    /// Stable fixture accounts, so the runner can remove exactly this run's Keychain items.
    public func fixtureID(_ offset: UInt8) -> UUID {
      var bytes = id.uuid
      bytes.15 ^= offset
      return UUID(uuid: bytes)
    }
  #endif

  public static let current: DevelopmentProfile? = {
    #if DEBUG
      do {
        guard
          let id = try selectedID(
            value: ProcessInfo.processInfo.environment["AGENTKEYBOX_QA_ID"],
            bundleIdentifier: Bundle.main.bundleIdentifier)
        else { return nil }
        return DevelopmentProfile(id: id)
      } catch {
        fatalError("Invalid AgentKeyBox QA profile ID")
      }
    #else
      return nil
    #endif
  }()
}
