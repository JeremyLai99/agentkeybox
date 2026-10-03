import Foundation

public actor ApprovalEngine {
  private struct GrantKey: Hashable, Sendable {
    var agentID: String
    var projectPath: String
    var credentialIdentifier: String
    var executablePath: String
    var arguments: [String]
    var environmentVariable: String
    var deliveryMode: SecretDeliveryMode
  }

  private struct SessionGrantKey: Hashable, Sendable {
    var grant: GrantKey
    var sessionID: String
  }

  private var sessionApprovals: Set<SessionGrantKey> = []
  private var projectApprovals: Set<GrantKey> = []
  private var events: [AccessEvent] = []

  public init() {}

  public func preauthorizedDecision(for request: AgentRequest) -> ApprovalDecision? {
    if let sessionID = request.sessionID,
      sessionApprovals.contains(SessionGrantKey(grant: grantKey(request), sessionID: sessionID))
    {
      return .allowSession
    }

    if projectApprovals.contains(grantKey(request)) {
      return .allowProject
    }

    return nil
  }

  public func record(
    decision: ApprovalDecision,
    request: AgentRequest,
    credentialLabel: String
  ) {
    switch decision {
    case .allowSession:
      if let sessionID = request.sessionID {
        sessionApprovals.insert(SessionGrantKey(grant: grantKey(request), sessionID: sessionID))
      }
    case .allowProject:
      projectApprovals.insert(grantKey(request))
    case .allowOnce, .deny:
      break
    }

    events.append(
      AccessEvent(
        requestID: request.id,
        agentDisplayName: request.agentDisplayName,
        credentialLabel: credentialLabel,
        projectPath: request.projectPath,
        decision: decision
      )
    )
  }

  public func history() -> [AccessEvent] {
    events.sorted { $0.timestamp > $1.timestamp }
  }

  public func clearSessionApprovals() {
    sessionApprovals.removeAll()
  }

  private func grantKey(_ request: AgentRequest) -> GrantKey {
    GrantKey(
      agentID: request.agentID,
      projectPath: request.projectPath,
      credentialIdentifier: request.credentialIdentifier,
      executablePath: request.executablePath ?? "",
      arguments: request.arguments,
      environmentVariable: request.environmentVariable ?? "",
      deliveryMode: request.deliveryMode
    )
  }
}
