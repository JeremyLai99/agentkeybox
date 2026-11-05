import Foundation

/// Compute before closing browsers: their callbacks can clear the pending approval.
public struct ProtectedAccessRevocation {
  public let cancelSubmission: Bool
  public let cancelBrowserApproval: Bool
  public let browserIDs: Set<UUID>

  public init(
    credentialID: UUID, pending: AgentRequest?, broker: BrokerRequest?,
    executingSubmissionID: UUID?, browserCredentials: [UUID: UUID]
  ) {
    let matches = pending?.credentialIdentifier == credentialID.uuidString
    cancelSubmission =
      matches && pending?.kind == .sensitiveSubmission
      && executingSubmissionID != pending?.id
    cancelBrowserApproval =
      matches
      && [.browserLogin, .browserFollow, .browserRecovery].contains(pending?.kind)
    let pendingBrowser =
      broker?.credentialIdentifier == credentialID.uuidString ? broker?.browser?.sessionID : nil
    browserIDs = Set(
      browserCredentials.compactMap { browserID, loginID in
        loginID == credentialID || browserID == pendingBrowser ? browserID : nil
      })
  }
}
