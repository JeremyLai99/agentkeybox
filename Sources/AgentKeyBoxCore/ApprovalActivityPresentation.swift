import Foundation

/// UI state only: hiding an approved prompt does not finish the request or free its broker slot.
public struct ApprovalActivityPresentation: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle, awaitingApproval, authenticating, executing
  }

  public let phase: Phase
  public let statusText: String?

  public var showsApprovalPrompt: Bool {
    phase == .awaitingApproval || phase == .authenticating
  }

  public var isExecuting: Bool { phase == .executing }

  public init(
    pendingRequest: AgentRequest?, executingRequestID: UUID?, decisionInProgress: Bool,
    credentialLabel: String?
  ) {
    guard let request = pendingRequest else {
      phase = .idle
      statusText = nil
      return
    }
    let agent = ApprovalPresentation.agentText(request.agentDisplayName, limit: 40)
    if executingRequestID == request.id {
      phase = .executing
      // Never derive progress from the command, URL, purpose, variables, or operation output.
      if request.kind == .environment {
        statusText = L(
          "Running: %@ using %@ key(s)…", agent, "\(request.environmentVariables.count)")
      } else {
        let item = ApprovalPresentation.agentText(credentialLabel ?? L("credential"), limit: 60)
        statusText = L("Running: %@ using %@…", agent, item)
      }
    } else {
      phase = decisionInProgress ? .authenticating : .awaitingApproval
      statusText = L("%@ wants access", agent)
    }
  }
}
