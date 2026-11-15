import Foundation

/// Errors deliberately contain no input values, code fragments, or decoding diagnostics.
public enum SensitiveDataError: Error, LocalizedError, Equatable {
  case invalidCard, invalidCodes, invalidPayload, unsupportedVersion
  case noAvailableCode, invalidDestination, invalidFields, controlledUseRequired
  case invalidLogin
  case browserRecoveryOnly

  public var errorDescription: String? {
    switch self {
    case .browserRecoveryOnly:
      return L(
        "These recovery codes can only be used with browser_recover for their linked website login."
      )
    case .invalidLogin:
      return L("Enter a username and password for this website login.")
    case .invalidCard:
      return L("Check the card number, cardholder, and expiration date.")
    case .invalidCodes:
      return L("Enter one recovery code per line, without duplicates or headings.")
    case .invalidPayload:
      return L("This protected item is damaged or has the wrong type.")
    case .unsupportedVersion:
      return L("Update AgentKeyBox to use this protected item.")
    case .noAvailableCode:
      return L("No recovery code is available. Review its status in AgentKeyBox.")
    case .invalidDestination:
      return L("Set an exact HTTPS submission URL without a query, fragment, or login details.")
    case .invalidFields:
      return L("Use supported field placeholders and bounded field names and values.")
    case .controlledUseRequired:
      return L("This item requires its controlled-use tool, not commands or generic HTTP.")
    }
  }
}

public struct StoredLogin: Codable, Equatable, Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) throws {
    guard !username.isEmpty, username.utf8.count <= 512,
      !password.isEmpty, password.utf8.count <= 4096,
      !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw SensitiveDataError.invalidLogin }
    self.username = username
    self.password = password
  }
}

public struct StoredCard: Codable, Equatable, Sendable {
  public let number: String
  public let cardholder: String
  public let expirationMonth: Int
  public let expirationYear: Int

  public init(number: String, cardholder: String, expirationMonth: Int, expirationYear: Int) throws
  {
    let normalized = number.filter { $0 != " " && $0 != "-" }
    guard (12...19).contains(normalized.count),
      normalized.utf8.allSatisfy({ (48...57).contains($0) }),
      !cardholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      cardholder.utf8.count <= 200,
      !cardholder.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      (1...12).contains(expirationMonth), (2000...2199).contains(expirationYear)
    else { throw SensitiveDataError.invalidCard }
    let sum = normalized.utf8.reversed().enumerated().reduce(0) { sum, pair in
      let digit = Int(pair.element - 48)
      let value = pair.offset.isMultiple(of: 2) ? digit : digit * 2
      return sum + (value > 9 ? value - 9 : value)
    }
    guard sum % 10 == 0, Set(normalized).count > 1 else { throw SensitiveDataError.invalidCard }
    self.number = normalized
    self.cardholder = cardholder.trimmingCharacters(in: .whitespacesAndNewlines)
    self.expirationMonth = expirationMonth
    self.expirationYear = expirationYear
  }
}

public struct RecoveryCodeSet: Codable, Equatable, Sendable {
  public enum Status: String, Codable, CaseIterable, Sendable {
    case available
    /// Persisted before network use. A crash, rejection, or lost response must not reissue it.
    case issued
    case used
    /// Restored snapshots cannot establish current remote validity.
    case needsReview
  }

  public struct Entry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let value: String
    public var status: Status
  }

  public let generation: UUID
  public private(set) var entries: [Entry]

  public init(text: String) throws {
    guard text.utf8.count <= 64 * 1024 else { throw SensitiveDataError.invalidCodes }
    let codes = text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    guard !codes.isEmpty, codes.count <= 100,
      Set(codes).count == codes.count,
      codes.allSatisfy({ (4...128).contains($0.count) && $0.allSatisfy { allowed.contains($0) } })
    else { throw SensitiveDataError.invalidCodes }
    self.generation = UUID()
    self.entries = codes.map { Entry(id: UUID(), value: $0, status: .available) }
  }

  /// The caller must save the updated set before using the returned code. Never log the value.
  public mutating func reserveNext() throws -> String {
    guard let index = entries.firstIndex(where: { $0.status == .available }) else {
      throw SensitiveDataError.noAvailableCode
    }
    entries[index].status = .issued
    return entries[index].value
  }

  /// Only a local authenticated user may correct status; the MCP has no such operation.
  public mutating func setStatus(_ status: Status, for id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].status = status
  }

  public mutating func requireReviewAfterRestore() {
    for index in entries.indices where entries[index].status != .used {
      entries[index].status = .needsReview
    }
  }

  /// Replacing a set must not silently make a previously issued code reusable.
  public mutating func preserveHistory(from previous: RecoveryCodeSet) {
    let prior = Dictionary(
      previous.entries.map { ($0.value, $0.status) }, uniquingKeysWith: { a, _ in a })
    for index in entries.indices {
      if let status = prior[entries[index].value] { entries[index].status = status }
    }
  }
}

/// Only encoded inside SecretStore / encrypted backups. Never put this in metadata or MCP results.
public struct SensitivePayload: Codable, Equatable, Sendable {
  public let version: Int
  public var revision: UUID
  public let card: StoredCard?
  public var recoveryCodes: RecoveryCodeSet?
  public let login: StoredLogin?

  public init(card: StoredCard) {
    version = 1
    revision = UUID()
    self.card = card
    recoveryCodes = nil
    login = nil
  }

  public init(recoveryCodes: RecoveryCodeSet) {
    version = 1
    revision = UUID()
    card = nil
    self.recoveryCodes = recoveryCodes
    login = nil
  }

  public init(login: StoredLogin) {
    version = 1
    revision = UUID()
    card = nil
    recoveryCodes = nil
    self.login = login
  }

  public var kind: CredentialKind {
    login != nil ? .login : card != nil ? .creditCard : .recoveryCodes
  }

  /// Recognize exported envelopes before a generic JSON import can misclassify them. This
  /// deliberately recognizes malformed/future envelopes too, so validation fails closed.
  public static func importedKind(_ data: Data, filename: String = "") -> CredentialKind? {
    if filename.lowercased().hasSuffix(".card.json") { return .creditCard }
    if filename.lowercased().hasSuffix(".recovery-codes.json") { return .recoveryCodes }
    if filename.lowercased().hasSuffix(".login.json") { return .login }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["version"] != nil
    else { return nil }
    if object["card"] != nil { return .creditCard }
    if object["recoveryCodes"] != nil { return .recoveryCodes }
    if object["login"] != nil { return .login }
    return nil
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data, kind: CredentialKind) throws -> SensitivePayload {
    guard data.count <= 128 * 1024,
      let payload = try? JSONDecoder().decode(Self.self, from: data)
    else { throw SensitiveDataError.invalidPayload }
    guard payload.version == 1 else { throw SensitiveDataError.unsupportedVersion }
    guard
      [payload.card != nil, payload.recoveryCodes != nil, payload.login != nil]
        .filter({ $0 }).count == 1, payload.kind == kind
    else {
      throw SensitiveDataError.invalidPayload
    }
    if let login = payload.login {
      _ = try StoredLogin(username: login.username, password: login.password)
    }
    if let card = payload.card {
      let validated = try StoredCard(
        number: card.number, cardholder: card.cardholder,
        expirationMonth: card.expirationMonth, expirationYear: card.expirationYear)
      guard validated == card else { throw SensitiveDataError.invalidPayload }
    }
    if let codes = payload.recoveryCodes {
      let validated = try RecoveryCodeSet(text: codes.entries.map(\.value).joined(separator: "\n"))
      guard validated.entries.map(\.value) == codes.entries.map(\.value),
        Set(codes.entries.map(\.id)).count == codes.entries.count
      else {
        throw SensitiveDataError.invalidPayload
      }
    }
    return payload
  }

  public static func restored(_ data: Data, kind: CredentialKind) throws -> Data {
    var payload = try decode(data, kind: kind)
    payload.recoveryCodes?.requireReviewAfterRestore()
    return try payload.encoded()
  }
}
