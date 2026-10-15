import Foundation

#if canImport(CryptoKit) && canImport(CommonCrypto)
  import CommonCrypto
  import CryptoKit
  import Security
#endif

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
  case cryptoUnavailable

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
    case .cryptoUnavailable:
      return L("Encrypted backups need macOS.")
    }
  }
}

/// The `.akbbackup` file format: a small JSON envelope around an AES-256-GCM sealed box.
///
/// The key comes from the user's password through PBKDF2-HMAC-SHA256 with a random 16-byte
/// salt. The envelope's parameters are bound to the ciphertext as additional authenticated data,
/// so changing any of them, or any byte of the ciphertext, makes decryption fail instead of
/// producing altered contents. Without the password the file reveals only that it is a backup.
public enum BackupArchive {
  public static let fileExtension = "akbbackup"
  public static let minimumPasswordLength = 12
  /// OWASP's 2023 recommendation for PBKDF2-HMAC-SHA256.
  public static let defaultIterations = 600_000
  static let format = "agentkeybox-backup"
  static let version = 1
  /// Bounds on a file's iteration count: low enough not to hang on a hostile file, high enough
  /// that a file cannot ask for a trivially weak key.
  static let iterationRange = 10_000...10_000_000

  struct Envelope: Codable {
    var format: String
    var version: Int
    var kdf: String
    var iterations: Int
    var salt: Data
    var cipher: String
    var sealed: Data

    var authenticatedData: Data {
      Data("\(format)|\(version)|\(kdf)|\(iterations)|\(salt.base64EncodedString())|\(cipher)".utf8)
    }
  }

  public static func encrypt(
    _ contents: BackupContents, password: String, iterations: Int = defaultIterations
  ) throws -> Data {
    guard password.count >= minimumPasswordLength else { throw BackupError.passwordTooShort }
    #if canImport(CryptoKit) && canImport(CommonCrypto)
      var salt = Data(count: 16)
      let status = salt.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
      }
      guard status == errSecSuccess else { throw BackupError.cryptoUnavailable }
      var envelope = Envelope(
        format: format, version: version, kdf: "PBKDF2-HMAC-SHA256", iterations: iterations,
        salt: salt, cipher: "AES-256-GCM", sealed: Data())
      // Default date encoding: lossless, unlike ISO 8601, which drops fractions of a second.
      let plaintext = try JSONEncoder().encode(contents)
      let key = try deriveKey(password: password, salt: salt, iterations: iterations)
      let box = try AES.GCM.seal(plaintext, using: key, authenticating: envelope.authenticatedData)
      guard let combined = box.combined else { throw BackupError.cryptoUnavailable }
      envelope.sealed = combined
      let output = JSONEncoder()
      output.outputFormatting = [.prettyPrinted, .sortedKeys]
      return try output.encode(envelope)
    #else
      throw BackupError.cryptoUnavailable
    #endif
  }

  public static func decrypt(_ data: Data, password: String) throws -> BackupContents {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      envelope.format == format
    else { throw BackupError.notABackup }
    guard envelope.version == version else { throw BackupError.unsupportedVersion }
    guard envelope.kdf == "PBKDF2-HMAC-SHA256", envelope.cipher == "AES-256-GCM",
      iterationRange.contains(envelope.iterations), envelope.salt.count >= 16
    else { throw BackupError.notABackup }
    #if canImport(CryptoKit) && canImport(CommonCrypto)
      let key = try deriveKey(
        password: password, salt: envelope.salt, iterations: envelope.iterations)
      let plaintext: Data
      do {
        let box = try AES.GCM.SealedBox(combined: envelope.sealed)
        plaintext = try AES.GCM.open(box, using: key, authenticating: envelope.authenticatedData)
      } catch {
        throw BackupError.wrongPasswordOrDamaged
      }
      guard let contents = try? JSONDecoder().decode(BackupContents.self, from: plaintext) else {
        throw BackupError.wrongPasswordOrDamaged
      }
      return contents
    #else
      throw BackupError.cryptoUnavailable
    #endif
  }

  #if canImport(CryptoKit) && canImport(CommonCrypto)
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
      let passwordBytes = Array(password.utf8)
      var derived = [UInt8](repeating: 0, count: 32)
      let status = salt.withUnsafeBytes { saltBytes in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.map { Int8(bitPattern: $0) },
          passwordBytes.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, 32)
      }
      guard status == kCCSuccess else { throw BackupError.cryptoUnavailable }
      defer { derived.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, 32, 0, 32) } }
      return SymmetricKey(data: derived)
    }
  #endif
}
