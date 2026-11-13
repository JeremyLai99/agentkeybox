import Foundation

/// Approval history and "don't ask again this session" grants.
///
/// A session is one coding-agent session: the MCP helper creates a random session ID when the
/// agent starts it, so a new agent session, or restarting AgentKeyBox, asks again. Grants are
/// deliberately narrow:
/// - HTTP: the same agent, project, and key, sent to the same host, and only for hosts on the
///   key's list. A host outside the list always asks.
/// - Commands: the exact same executable, arguments, variable, and delivery. Changing anything
///   asks again, so a granted `npm test` cannot become a different command.
/// - `akb run` hands secrets to a terminal process and is never granted for a session.
/// Every grant also expires after `maxSessionAge`.
public actor ApprovalEngine {
  private enum Scope: Hashable, Sendable {
    case command(
      executable: String, arguments: [String], variable: String, delivery: SecretDeliveryMode)
    case http(host: String)
  }

  private struct SessionKey: Hashable, Sendable {
    var sessionID: String
    var agentID: String
    var projectPath: String
    var credentialIdentifier: String
    var scope: Scope
  }

  private struct SessionGrant: Sendable {
    var authentication: AuthenticationGrant?
    var expiresAt: Date
  }

  /// A live grant. `authentication` is the Touch ID evaluation from when the user granted it,
  /// reused so later reads of the key do not prompt again.
  public struct SessionApproval: Sendable {
    public var authentication: AuthenticationGrant?
  }

  /// Opaque snapshot taken before authentication. Either kind of revocation makes it stale.
  public struct SessionGeneration: Equatable, Sendable {
    fileprivate var all: UUID
    fileprivate var credentialIdentifier: String
    fileprivate var credential: UUID?
  }

  public static let maxSessionAge: TimeInterval = 8 * 60 * 60

  private var sessionGrants: [SessionKey: SessionGrant] = [:]
  private var generation = UUID()
  private var credentialGenerations: [String: UUID] = [:]
  private var events: [AccessEvent] = []

  public init() {}

  /// Whether the prompt may offer "don't ask again this session" for this request.
  public nonisolated static func canGrantSession(for request: AgentRequest) -> Bool {
    request.sessionID != nil && scope(for: request) != nil
  }

  public func sessionGeneration(for request: AgentRequest) -> SessionGeneration {
    SessionGeneration(
      all: generation, credentialIdentifier: request.credentialIdentifier,
      credential: credentialGenerations[request.credentialIdentifier])
  }

  /// No suspension between the generation check and insertion: revocation either prevents
  /// this grant or removes it afterwards. Callers must not record allowSession on false.
  @discardableResult
  public func grantSession(
    for request: AgentRequest, authentication: AuthenticationGrant?,
    generation expected: SessionGeneration, now: Date = Date()
  ) -> Bool {
    guard expected == sessionGeneration(for: request), let key = Self.key(for: request) else {
      return false
    }
    if let previous = sessionGrants[key], previous.authentication !== authentication {
      previous.authentication?.invalidate()
    }
    sessionGrants[key] = SessionGrant(
      authentication: authentication, expiresAt: now.addingTimeInterval(Self.maxSessionAge))
    return true
  }

  public func sessionApproval(for request: AgentRequest, now: Date = Date()) -> SessionApproval? {
    guard let key = Self.key(for: request), let grant = sessionGrants[key] else { return nil }
    guard grant.expiresAt > now else {
      grant.authentication?.invalidate()
      sessionGrants[key] = nil
      return nil
    }
    return SessionApproval(authentication: grant.authentication)
  }

  /// Agent sessions that currently have at least one live grant.
  public func activeSessionCount(now: Date = Date()) -> Int {
    Set(sessionGrants.filter { $0.value.expiresAt > now }.map(\.key.sessionID)).count
  }

  /// "Ask every time again": drops every grant and invalidates the saved authentications.
  public func revokeAllSessions() {
    generation = UUID()
    credentialGenerations.removeAll()
    for grant in sessionGrants.values { grant.authentication?.invalidate() }
    sessionGrants.removeAll()
  }

  /// Also prevents approvals already waiting for authentication from recreating these grants.
  public func revokeSessions(for credentialIdentifier: String) {
    credentialGenerations[credentialIdentifier] = UUID()
    for (key, grant) in sessionGrants where key.credentialIdentifier == credentialIdentifier {
      grant.authentication?.invalidate()
      sessionGrants[key] = nil
    }
  }

  @discardableResult
  public func record(
    decision: ApprovalDecision,
    request: AgentRequest,
    credentialLabel: String,
    credentialIDs: [UUID] = []
  ) -> AccessEvent {
    let event = AccessEvent(
      requestID: request.id,
      agentDisplayName: request.agentDisplayName,
      credentialLabel: credentialLabel,
      projectPath: request.projectPath,
      decision: decision,
      credentialIDs: credentialIDs
    )
    events.append(event)
    return event
  }

  public func history() -> [AccessEvent] {
    events.sorted { $0.timestamp > $1.timestamp }
  }

  private static func key(for request: AgentRequest) -> SessionKey? {
    guard let sessionID = request.sessionID, let scope = scope(for: request) else { return nil }
    return SessionKey(
      sessionID: sessionID, agentID: request.agentID, projectPath: request.projectPath,
      credentialIdentifier: request.credentialIdentifier, scope: scope)
  }

  private static func scope(for request: AgentRequest) -> Scope? {
    switch request.kind {
    case .command:
      guard let executable = request.executablePath else { return nil }
      return .command(
        executable: executable, arguments: request.arguments,
        variable: request.environmentVariable ?? "", delivery: request.deliveryMode)
    case .httpRequest:
      guard request.hostStatus == .listed,
        let host = request.url.flatMap({ URLComponents(string: $0)?.host?.lowercased() })
      else { return nil }
      return .http(host: host)
    case .environment, .sensitiveSubmission, .browserLogin, .browserFollow, .browserRecovery:
      return nil
    }
  }
}
