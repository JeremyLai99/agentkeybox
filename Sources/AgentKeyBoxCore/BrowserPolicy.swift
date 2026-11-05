import Foundation

/// Fixed diagnostics only. WebKit errors, scripts, cookies and response URLs never cross MCP.
public enum ControlledBrowserError: Error, LocalizedError, Equatable {
  case invalidWebsite, unsupportedForm, unavailable, busy, failed, expired, invalidLink

  public var errorDescription: String? {
    switch self {
    case .invalidWebsite: return L("Set an HTTPS sign-in page without a query or fragment.")
    case .unsupportedForm:
      return L("This page needs a sign-in method that the controlled browser does not support yet.")
    case .unavailable: return L("This browser session is unavailable. Request a new sign-in.")
    case .busy:
      return L("The browser is handling a protected operation. Try again after it finishes.")
    case .failed:
      return L("The browser could not complete this operation. Its private session was closed.")
    case .expired: return L("This browser session expired. Request a new sign-in.")
    case .invalidLink: return L("This link is no longer available. Read the page again.")
    }
  }
}

public struct BrowserOwner: Hashable, Sendable {
  public let agentID: String
  public let projectPath: String
  public let sessionID: String

  public init(agentID: String, projectPath: String, sessionID: String) throws {
    guard !agentID.isEmpty, !projectPath.isEmpty, !sessionID.isEmpty,
      agentID.utf8.count <= 256, projectPath.utf8.count <= 4096,
      sessionID.utf8.count <= 256
    else { throw ControlledBrowserError.unavailable }
    self.agentID = agentID
    self.projectPath = projectPath
    self.sessionID = sessionID
  }
}

/// The browser ID is only useful to its original helper session/project/agent.
public struct BrowserCommand: Codable, Sendable {
  public var sessionID: UUID
  public var linkID: UUID?

  public init(sessionID: UUID, linkID: UUID? = nil) {
    self.sessionID = sessionID
    self.linkID = linkID
  }
}

public struct BrowserPage: Codable, Equatable, Sendable {
  public struct Link: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
  }

  public let sessionID: UUID
  /// A controlled page is ready; this is NOT an assertion that the website authenticated it.
  public let status: String
  public let origin: String
  public let title: String
  public let text: String
  public let links: [Link]
}

public enum BrowserPolicy {
  public static let lifetime: TimeInterval = 15 * 60

  public static func loginURL(_ raw: String?) throws -> URL {
    guard let url = try? SensitiveSubmissionPolicy.destination(raw),
      let origin = origin(url), !origin.isEmpty
    else { throw ControlledBrowserError.invalidWebsite }
    return url
  }

  public static func origin(_ url: URL) -> String? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "https", let host = c.host?.lowercased(), !host.isEmpty,
      c.user == nil, c.password == nil,
      !host.contains("%"), !host.contains("\\"),
      c.port == nil || (1...65535).contains(c.port!)
    else { return nil }
    return "https://\(host)" + ((c.port == nil || c.port == 443) ? "" : ":\(c.port!)")
  }

  public static func permits(_ url: URL, origin expected: String) -> Bool {
    url.absoluteString.utf8.count <= 4096 && origin(url) == expected
      && !url.absoluteString.contains("\\")
  }

  public static func containsSecret(_ text: String, login: StoredLogin) -> Bool {
    containsSecret(text, values: [login.username, login.password])
  }

  static func containsSecret(_ text: String, values: [String]) -> Bool {
    values.flatMap { SecretRedactor.candidates(for: Data($0.utf8)) }
      .contains { text.contains($0) }
  }

  /// Defense in depth for the trusted destination's text, not a malicious-site containment
  /// guarantee. The actual boundary is a private browser with no arbitrary script/DOM access.
  public static func redact(_ text: String, login: StoredLogin, captureWasCut: Bool = false)
    -> String
  {
    redact(text, values: [login.username, login.password], captureWasCut: captureWasCut)
  }

  static func redact(_ text: String, values: [String], captureWasCut: Bool = false) -> String {
    let variants = Set(
      values.flatMap {
        SecretRedactor.candidates(for: Data($0.utf8))
      }
    ).sorted { $0.count > $1.count }
    let capture = captureWasCut && text.hasSuffix("\u{FFFD}") ? String(text.dropLast()) : text
    let captured =
      captureWasCut ? SecretRedactor.removingTrailingFragment(of: variants, from: capture) : capture
    let redacted = variants.reduce(captured) {
      $0.replacingOccurrences(of: $1, with: "[protected]")
    }
    // Script observations are bounded; do not expose a secret prefix at a capture boundary.
    return redacted
  }
}

/// Synchronous state transitions prevent an actor re-entry from observing a fill or an old
/// snapshot. Closing/revoking wins over in-flight callbacks; a closed lease cannot reopen.
public struct BrowserLease: Sendable {
  public enum Phase: Sendable {
    case preparing, awaitingApproval, authenticating, recoveryRequired, awaitingRecoveryApproval
    case ready, reading, navigating, closed
  }
  public let owner: BrowserOwner
  public let expiresAt: Date
  public private(set) var phase: Phase = .preparing

  public init(owner: BrowserOwner, now: Date = Date()) {
    self.owner = owner
    expiresAt = now.addingTimeInterval(BrowserPolicy.lifetime)
  }

  public func authorize(_ owner: BrowserOwner, now: Date = Date()) throws {
    guard self.owner == owner, phase != .closed else { throw ControlledBrowserError.unavailable }
    guard now < expiresAt else { throw ControlledBrowserError.expired }
  }

  public mutating func transition(from expected: Phase, to next: Phase, now: Date = Date()) throws {
    guard now < expiresAt else {
      phase = .closed
      throw ControlledBrowserError.expired
    }
    guard phase == expected, phase != .closed else { throw ControlledBrowserError.busy }
    phase = next
  }

  public mutating func close() { phase = .closed }
}
